# H4 harness 設計 v5 — 審查 B(第 5 輪)

**審查對象**:`docs/design/254-h4-harness.md` v5(`harness/254-h4` @ 40a598d),整份。
**對照**:P3 `254-p3-impl.md` v7.1 §6 / §7 / §8、附錄 D;219 §3.3 + `.cddl`;main 2ecf1cb 原始碼(`feed/batman-prov/src/provd/*`、`node/wtxn.go`、`node/node.go`、`tests/tools/provclient/net.go`、`scripts/node/ble-lib-254.sh`、`scripts/node/prov-lease-254.sh`、`feed/batman-provision/files/usr/sbin/batman-slot`);04 唯讀。
**方法**:先逐條核對附錄 D(v4 意見),再從實際使用流程走整份,重點放在 v5 新加的機制。節點上只做唯讀讀取(`ls -l identity/`、`bluetoothctl show`、`batctl bl`、`ip -br link`)。WSL 上做了一次非 root 的 `unshare` + `pivot_root` 實驗,放在 `mktemp -d`,做完已刪。沒有改 repo(本報告除外)。

**結論先講**:**0 BLOCKER / 2 MAJOR / 14 MINOR → REJECT**。骨架已收斂,v4 的 BLOCKER(認目標)確實解了。兩條 MAJOR 都是 v5 新寫的機制有洞,而且都是局部修改:
- **M1**:§5.7 的「deadman 看到 host 模式還活著 → 只做段 1」,在程式碼上只會在 host 執行器卡住時才發生,結果是把段 2 交給一個卡住的行程;
- **M2**:§8.2 的 `pivot_root` 沙箱,實測可以經由 cwd 與繼承的 fd 逃出去,而設計寫的 canary 負測試偵測不到這兩條路。

---

## 0. 證據(原始輸出節錄)

```
# provd/noise.go:45-49   newResponder: Pattern = HandshakeNX, StaticKeypair = s_node;psk != nil → PresharedKeyPlacement 0(= NXpsk0)
# provd/noise.go:98      m2 := ok.WriteMessage(nil, nodeCert)   ← NX 與 NXpsk0(owner / member)的 msg2 payload 都是 node_cert
# provd/noise.go:88-95   ok == nil → fakeMsg2(長度相同的亂數)
# provd/server.go:276-291 node_cert = {1:[cert], 2:s_node_pub, 3:bid, 4:ecdh, 5:sigS(sign.static(s_node_pub)), 6:sigE, 7:sn}
# 219 §3.3:sig_static = ES256_DAC("batman-node-static-v1" ‖ s_node_pub ‖ boot_id)

# 04 唯讀
-rw-r--r-- 1 root root 385 node.cert   (首 2 bytes 30 82 = DER)
-rw------- 1 root root  32 claim.secret ;  -rw------- 1 root root 19 sn
kernel 6.6.138;bluetoothctl show:SupportedInstances 4,沒有 SupportedSecondaryChannels(= 只有 legacy 廣播)
batctl bl → enabled;eth0 UP

# 254-p2-impl.md:40 F-P17:legacy 廣播「斷線後 kernel 自己重開同一 instance;RPA 只在 900 s 過期後重算
#                    → 900 s 窗內連線前後、撤銷 / 重註冊都是同一 RPA」   ← §4.2 fake path 臂「重連同一個位址」成立

# node/wtxn.go:125-150 decryptSecrets:target = payload[3] 必須 = SHA-256(KS.DACPub());other = net_id ‖ u32be(version);
#                       cose.Decrypt(enc, LabelSecrets, dacHash, other, KS.ECDH)
# provclient/net.go:149  ctx = [24, [nil,nil,nil], [targetHash,nil,nil], [256, recProt, net_id‖ver]] → HKDF;
#                  :155  aad = ["Encrypt", bodyProt, label]      ← target 在 KDF context,不在 AAD
# 219-protocol.cddl:205-212 network-join-req = {1 netcfg, 2 members-sign1, 3 secrets, ?4, 31 owner-op}
# vectors.json owner_op.request_network_join → body keys [1, 2, 3, 31]   ← 向量帶 key 2(member_list)
# provclient/net.go:221/265  live 的 join 只送 {1, 3} + owner-op;node.go:1001-1017 netJoin 不讀 key 2

# scripts/node/ble-lib-254.sh
#  :97-101  lock(): exec 9>>$BT/lock;flock -n 重試
#  :325     held(): lock 30 + lease_valid_for,否則 die
#  :318-322 cmd_arm(= `renew` 子命令;prov-lease-254.sh 沒有 `arm` 子命令)
#  :334-336 cmd_dm_fire: sleep → 最多 20×lock 30(10 分)→ 拿不到:kill_run_groups,不拿鎖照做
#  :339-341 lease 不是這個 run、或尚未過期 → exit
#  :170     PROVD_KEYS 沒有 BATMAN_FAULT(F-H51 成立)
# scripts/node/prov-lease-254.sh:29-63 role_fire_restore($1 = run 或 "recover");cmd_recover 也呼叫 role_fire_restore recover
# scripts/dv/prov-254.sh:36,66-74 主機鎖 = mkdir $TEMP/batman-dv-04.lock(不是 fd)

# batman-slot:629-635 cmd_stage_root: slot_lock → precheck → 帶 root.squashfs 就 die → begin_write → clear_root → echo $TROOT
# batman-slot:600-626 precheck:要 boot/、SHA256SUMS(含 root.squashfs 行)、boot/kernel8.img、metadata size=;
#                     boot 檔 sha 不符 → die(在 begin_write 之前)
# batman-slot:740     apply 成功後寫 $RUNDIR/shutdown.reason = "sysupgrade-trial (slot $T)"

# WSL 非 root 實驗(mktemp -d;unshare --user --map-root-user --mount --pid --fork [--net --uts --ipc])
#  變體 1:父 shell 開著 fd 7 指向宿主 canary → bind rootfs、pivot_root、umount -l /old 之後:
#          echo pwn-fd >&7  → "wrote via fd7";宿主 canary = "pwn-fd"
#  變體 2:cwd 停在宿主目錄(不在 rootfs)→ pivot_root(子 shell)+ umount -l /old 之後:
#          pwd -P = /old/tmp/tmp.SpkD1hxiJl/host;echo pwn-cwd > secret/canary → 宿主 canary = "pwn-cwd"
#  兩條路都在「絕對路徑寫宿主 canary 失敗」的同時成功。
```

## 1. 附錄 D(v4 意見)逐條核對

| v4 意見 | v5 處理 | 核對結果 |
|---|---|---|
| A-B1 / B-B1 認目標 | §4.2 改用每一臂自己交握的 `node_cert` | ✅ 解了。`noise.go:98`:NX 與 NXpsk0 的 msg2 都帶 `node_cert`;`s_node` 就是交握的 static,`sig_static` 可驗;DAC 在 `identity/node.cert`(0644、DER 385 B)。fake path 臂「重連同一個位址」有 F-P17 的證據(legacy 廣播、04 沒有 ext adv)。殘留問題:文中仍有四處寫「static key 認證」(m1);HTTP / sock 路徑沒寫要驗(m3);SCAN 沒有以 UUID 過濾(m4)。 |
| A-M1 / B-m3 netobj | §4.1 自己實作 | ⚠️ 大致對。「AAD = target」寫錯了位置(target 在 KDF context);member_list(key 2)沒有規格,但向量裡有(m2)。逐位元組 selftest 會抓到,不會上機才發現。 |
| A-M2 / B-M1 執行器的鎖 | §5.7 host / deadman 兩種模式 | ❌ 新洞,見 **M1**。 |
| A-M3 / B-m1 p6 持久 undo | §5.7 + §13 | ⚠️ 機制對。「綁 boot_id」語意不清、p5 不屬於任何槽、P9 被寫成寫者(m7、m8)。 |
| A-m1 / B-m9 交握限速 | §4.1 | ✅ |
| A-m2 / B-m8 期限檔 | §4.4 兩個檔、各一個寫者、開機先扣 | ✅(初始狀態「`fresh-spent` 不存在」要寫明不算讀不懂,併入 m8 的文字修正) |
| A-m3 / B-m7 tcpdump 介面 | §4.5 入口介面 | ✅;VLAN 臂的 filter 要寫明(m13) |
| A-m4 / B-m6 沙箱負測試 | §8.2 `pivot_root` + canary | ❌ 只擋住絕對路徑這一條,見 **M2** |
| A-m5 claim.secret | hexdump | ✅(04 有 `hexdump`:`batman-slot:614` 也在用) |
| A-m6 ap-restore 的 C0 | tmpfs + 重開後 key 20 重送 | ✅ |
| A-m7 / B-m5 E-H13 前置 | `stage-root` | ✅ 核對 `batman-slot:600-635`:不帶 `root.squashfs`、但 SHA256SUMS 有 rootfs 行、`metadata size=` 有值的 payload,會走 begin_write(disarm + BAD)+ clear_root。殘留 `shutdown.reason`(m14) |
| A-m8 PROVD_KEYS | §5.5 | ✅(`ble-lib-254.sh:170`) |
| A-m10 OW4 | `owner/add` 加回 | ✅ |
| A-m11 journal 參數 | §5.7 封閉清單 + 負測試 | ✅ |
| A-m12 ST9 變體 | §5.5 | ✅ |
| B-m2 pk_proof 順序 | §3.1 第 3 步 | ✅ |
| B-m4 位址與身分 | §3.1 第 2 步 | ✅;onsite 後 02 的線有沒有拔,沒有斷言(m12) |
| B-m10 漏列的片語 | UD7 / UD8 / UD8b / UD8c / UD11 / HT8b | ✅ 都補了;UD8c 的鑑別力有問題(m5);另外發現 §7 漏一列(m6) |
| B-m11 接縫清單 | §1.4-2 | ✅ |

## 2. BLOCKER

無。

## 3. MAJOR

### M1. §5.7 的 deadman 模式「看到 host 還活著 → 只做段 1、段 2 留給它」:照程式碼,這一支只在 host 執行器卡住時才會走到,結果是段 2 永遠沒人做

**情境**:單位結束,主機以 host 模式執行 undo:`renew 20 分` → `prov-lease-254.sh undo <run>`(在 `held` 底下,整段持有 fd 9 的鎖)。段 2 裡有一個動作卡住,例如 `bt-start` 遇到卡死的 bluetoothd(#305,HT3 本身就列了這個風險;`radio_restore` 的註解也說 bluetoothctl 會卡,所以每個都 `lim`),或 `wifi` / `ap-restore` 卡住。這時主機也斷線了(這正是設計 `trap '' HUP` 要處理的情況)。

**程式碼的實際行為**:
1. host 執行器持有鎖。lease 過了 20 分 → `dm-fire` 醒來 → `lock 30` × 20 次,也就是等 10 分(`ble-lib-254.sh:334-336`)。
2. 只要 host 執行器在這 10 分內做完,dm-fire 就會拿到鎖。這時 `undo-doing` 已經刪了 → 兩段都做,`done` 的跳過。這條路沒有問題,**也用不到 v5 的特例**。
3. 只有 host 執行器在「lease 到期 + 10 分」之後**還**拿著鎖,dm-fire 才會走「拿不到鎖、照做」(`:336`)。只有這條路會看到 `undo-doing` 的 pid 還活著。照 v5 的規則,這時只做段 1,段 2 留給那個已經超過預算 10 分以上、實際上卡住的行程。
4. 接著 `role_fire_restore` 照常往下做 `provd_restart`、`radio_restore`、啟動服務,然後 `rm -f $LEASE`。如果卡住的 host 執行器之後又動了,它就是在沒有 lease 的情況下,和 dm-fire 一起寫服務、寫 journal 的第二個寫者。journal 是「整份原子改寫」,兩個寫者會互相蓋掉對方的 `done`(lost update)。
5. 如果它一直卡著,fd 9 永遠被拿著。之後每個 `acquire` / `renew` / `held` 都會 die("BLE lock busy"),段 2 的狀態(`uci-restore`、`netns-del`、`ap-restore`、`p5-save`)一直留在節點上,只能等人重開。

**為什麼是 MAJOR**:v5 為這種重疊特別加的規則,在唯一會用到它的情況下,做出最差的選擇。§5.7 的重疊測試(「host 跑到一半時 lease 到期 → deadman 只做段 1、host 跑完段 2」)照程式碼根本做不出來:dm-fire 會先等鎖。所以這個測試會 PASS,但證明的是第 2 點,不是第 3 點。這屬於 v4 M1 想修的同一塊,v5 的修法沒有對上程式碼的實際時序。安全面上段 1 一定會做(fault、bind、HT14 保險另外處理),所以失敗方向是可用性與 bench 狀態被留下,不是暴露。

**修法**(局部):
1. 段 2 的每個動作都包 `lim <秒>`,上限寫進動作表。`renew` 的預算 = 上限總和 + 餘裕。這樣 host 執行器「還活著」就保證還在預算之內。
2. `undo-doing.<run>` 記 pid、pgid、boot_id。dm-fire 走到「拿不到鎖」那一支時:驗 cmdline → `pg_kill` 那個 pgid(鎖跟著釋放)→ 以 deadman 模式做**兩段**(`done` 與冪等保證重做是安全的)。拿到鎖的那一支照現在的做法。刪掉「只做段 1、段 2 留給它」這條規則。這樣 journal 永遠只有一個寫者。
3. undo 執行器起的子行程一律 `9>&-`(同 `dm_arm:131`),避免 fd 9 被某個長命的子行程帶走。
4. `test-h4-undo.sh` 的重疊臂改成:讓 host 執行器卡住(例如登記一個 `lim` 上限很長的假動作,或 SIGSTOP 它),超過「lease + 10 分」→ 斷言 deadman 殺掉它、兩段都完成、journal 每一項只有一個 `done`、鎖已釋放(下一個 `acquire` 成功)。**負對照**:v5 的規則(pid 活著就延後)→ 段 2 沒做 → FAIL。
5. 另加一臂「host 在 dm-fire 等鎖期間正常做完」→ dm-fire 拿到鎖、不重做 → 每項一次。這一臂證明的是第 2 點。

### M2. §8.2 的 `pivot_root` 沙箱可以經由 cwd 與繼承的 fd 逃出去;設計寫的 canary 負測試只試絕對路徑,偵測不到

**情境**:`eeprom-sbx-254.sh` 從 repo 目錄(`/home/yello/Batman`,cwd 在 `$HOME` 底下)執行。照 §8.2 的字面:`unshare … → bind rootfs → pivot_root → umount -l 舊根`,沒有寫 `cd /`,也沒有寫關掉繼承的 fd。沙箱裡以 userns root 執行 wsl.22 / 1.5.12-wsl.2 的 `/etc/uci-defaults/*` 與假 `vcgencmd`。這是我們自己 image 的程式碼,actor 是「供應鏈 / 我們自己的錯」。

**證據**(§0 的實驗,非 root):
- `pivot_root(2)` 只會把「cwd 正好是舊根」的行程改到新根。cwd 在 `$HOME/...` 的行程,`umount -l /old` 之後仍然握著舊檔案系統的 dentry:`pwd -P` = `/old/tmp/.../host`,以相對路徑寫宿主 canary 成功(`pwn-cwd`)。
- 父行程開著的 fd 在沙箱裡照樣能用:`echo >&7` 寫進了宿主的檔案(`pwn-fd`)。
- 這兩次都是「絕對路徑 `$HOME/.batman-dv/sbx-canary` 寫不進去」的同時發生的。也就是說,§8.2 的 canary 負測試在已經逃出去的設定下**照樣 PASS**。這正是使用者規則裡說的「沒有鑑別力的檢查不是測試」。

**資產**:`~/.batman-dv/bench`(H0 / H0b 金鑰)與 `~/.ssh` 的 lab key(可以 root 登入節點)。v4-B m6 已經把它們列為要保護的東西。H4-U12 是使用者明確要求的「非 root 沙箱 + 逃脫負測試」。

**修法**(局部):
1. 寫明順序:`cd "$R"` → `pivot_root . old` → **`cd /`** → `umount -l /old` → `rmdir /old` → 以 `exec` 啟動 payload 之前,**關掉 fd 3 以上的所有 fd**(例如 `for f in /proc/self/fd/*; do …; done`,或用 `setpriv` / `env -i` 加明確關 fd)。另外 `env -i` 清掉環境變數(`HOME`、`SSH_AUTH_SOCK` 等)。
2. 逃脫負測試加兩條,每條都要附「沙箱外 / 不修正的版本會成功」的對照:
   - **cwd**:進沙箱前故意 `cd` 到 `$HOME/.batman-dv`,在沙箱裡寫 `./sbx-canary` 與 `../.batman-dv/sbx-canary` → 宿主 canary 不變。對照:拿掉 `cd /` 的版本 → canary 被改(我的實驗就是這個對照)。
   - **fd**:進沙箱前開一個寫向宿主 canary 的 fd(例如 9),在沙箱裡對每一個 `/proc/self/fd/*` 試寫 → 宿主 canary 不變。對照:拿掉關 fd 的版本 → 被改。
   - 另外把 `SSH_AUTH_SOCK` 設成一個假 socket 路徑,斷言沙箱裡看不到這個環境變數。
3. canary 的判定只看「宿主上的內容不變」,不看「寫入失敗」:寫入失敗可能只是 ENOENT,不能證明擋住了。

## 4. MINOR

- **m1 「static key 認證」的舊說法還在四處**:§1.1(「BLE 認目標要經過 Noise static key 認證」)、§12 blebridge(「認目標以 static key 認證」)、§15-2 與 §17 E-H9(「static key 認證」)。這些與 §4.2 互相矛盾,實作的人可能照錯的寫。全部改成「msg2 `node_cert`:DAC 釘選 + `sig_static` + `sn`」。
- **m2 `netobj.py` 的規格**:
  - (a) §4.1 / F-H47 寫「AAD = target」。實際上 target(SHA-256(DAC pub))與 `other` 是放在 COSE KDF context(PartyV identity、SuppPubInfo),AAD 是 `["Encrypt", bodyProt, label]`(`provclient/net.go:149-155`)。
  - (b) CDDL 的 `network-join-req` 規定 key 2 `members-sign1`,向量 `request_network_join` 也帶 key 2;但 §4.1 只列 net_config / net_secrets / join。live 的 provclient 只送 {1, 3, 31},wsl.22 的 `netJoin` 也不讀 key 2(`node.go:1001-1017`)。要寫明:selftest 為了逐位元組重現向量,要能產生 member_list;N0 實際送不送 key 2、送的話內容是什麼(哪幾台的 DAC、誰簽)。
  - (c) plaintext 是 `{1: sae, 2: root}`(`net.go:198-201`),一併寫進規格。
- **m3 HTTP / sock 路徑也要驗 `node_cert`**:§4.2 只在 BLE 段落寫。§12 說「被入侵的手機可以假造正向的連線,但 Noise 是端到端」。但被入侵的 relay 可以把連線轉到 02 的 IP,而 `psk_member` 是全網共用的,02 會完成交握。要寫明 peer 核心對每一種 `--via` 都驗 DAC = 目標,不符就是 INVALID、不送請求。
- **m4 SCAN 要以 provd 的 service UUID 過濾**:§4.2 的 `SCAN` 回傳「每個位址」,然後依 RSSI 逐一 `CONNECT`。實驗室或路人的 BLE 裝置也會被連,這是對別人裝置的副作用,而且會吃掉逾時。只對廣播帶 provd UUID 的位址 CONNECT(F-H12:廣播只有 UUID,過濾依據已經存在)。
- **m5 UD8c(「上傳後改 payload」)的鑑別力與斷言**:
  - 上傳檔是 tar.gz。直接改一個 boot 成員的位元組,會先被 gzip CRC 或 tar 解析擋下(reason 11),測不到 P3 §3.7.5-7「讀回以 helper 的 `SHA256SUMS` 為準」這道防線。
  - boot 檔在 `batman-slot` 的 precheck 就會比對 sha,而且是在 begin_write **之前** die(`batman-slot:609-612`)→ 槽**不會**變 BAD。所以「槽 BAD」這個斷言,在 P3 行為正確時可能 false-FAIL。
  - 修法:mutant 用「SHA256SUMS 與 metadata 不變、重新壓縮的合法 tar.gz,只有一個成員(或 rootfs)內容不同」,以 uid 471 原地覆寫同一個 inode;斷言改成「不 arm、reason 11、沒有進試用;槽不是未動就是 BAD」;並以 helper / batman-slot log 斷言失敗發生在 sha / 讀回比對,不是在 gzip / tar 解析。P3 §3.7.5-7 說的「**中途**改寫」(串流進行中改 rootfs 的位元組)另外做一臂,由 `upd-write-mid` 的停點觸發。
  - UD8b 的 FIFO 建議以 uid 471 建立(與被入侵的 provd 情境一致)。目前的「下一個 `update.status` ≤ 5 s」分辨不出 worker 卡住(ro 只讀快取),要以「≤ N s 內 reason 11、`updating` 清掉」為準。
- **m6 附錄 A 漏了 P3 §7 的一列**:「被入侵的 provd | 偷換 pending 版本 | prepare / apply body 帶 sha,由 owner-op 綁定 | Go」。附錄 A 沒有對應的列,而 H4-U8 只准 UD12 / UD16 用 G。§6.3 的 lint 會在實作時 FAIL。二選一,並請使用者拍板:
  - 加一個 RB 黑箱臂:用 helper 的第 4 條連線扮演被入侵的 provd,送出 sha 與 owner-op 不一致的 `update.prepare` / `apply` → 被拒;W(E_U);再加一個 S 接縫(例如 `prepare-nosha`);
  - 或者請使用者把 H4-U8 擴大到這一列。
- **m7 p6 持久 undo 的綁定**:
  - §5.7 寫「綁定登記時的槽與 boot_id」。重開之後 boot_id 一定不同,而 p6 存在的理由正是重開。要寫明 boot_id 只是記錄、不是執行的條件;否則持久項永遠不會被執行。
  - `p5-save` 的對象(p5)不屬於任何一個槽。綁槽會讓 T 換過槽的情況一律變成 NEEDS-PERSON。改成只有 overlay 的項目(uci、`/etc/rc.d`)綁槽,p5 的項目不綁。
- **m8 文字與擁有權不一致**:
  - §9 寫「P9 唯讀」,但 §5.7 / §11 讓 P9 以 host 模式執行段 2 → 改成「P9 在 lease 底下是 undo 的執行者」;
  - §9 寫「只有 `prov-undo-254.sh run` 執行(持有 lease 鎖)」,與 §5.7 的 `prov-undo-lib-254.sh` + `prov-lease-254.sh undo`、以及 deadman 不拿鎖的那一支互相矛盾;§1.2 的檔名也不同;
  - §5.7 寫 `prov-lease-254.sh arm`,實際的子命令是 `renew`(`prov-lease-254.sh:99`);
  - §4.4 要寫明 `fresh-spent` 不存在(第一次開機)時當作已用 0,不算「讀不懂」;否則一開機就觸發。
- **m9 主機 EXIT trap 時 lease 已經過期**(Windows 睡眠醒來之後才跑 trap):`renew` 與 `held` 都會 die。這時 dm-fire 已經跑了或正在跑。要寫明 host 模式遇到「lease 不是我的或已過期」→ 不重試,改讀 dm 的 log 與 `undo-doing`,交給下一次 preflight 判斷。
- **m10 `ble-recover` 這條路徑**:`cmd_recover` 會呼叫 `role_fire_restore recover`(`ble-lib-254.sh:350`)。§5.7 沒有定義 `undo_run recover`(要掃所有 run 的 tmpfs 與 p6 journal)。手動恢復是生命週期的一條路,要補進 §11。
- **m11 `phy9h4` 殘留時「helper 的前提檢查不給 `http.2`」沒有證據**:P3 D-13 只加了「AP iface 是 br-ahwlan 的 port」,沒有說多出一個 `phy*` port 會被拒。殘留的 `phy9h4` 是一個繞過「只收手機 AP port」的口子(peer 那一端在 netns 裡)。要嘛把這一條列為 P3 契約(§1.4)並附測試,要嘛刪掉這句話,改成靠段 1 一律刪掉 `phy9h4`,加上 P9 斷言不存在。
- **m12 onsite 之後 02 的網路線**:§3.1 第 8 步由使用者拔線,但 `s0_assert` 沒有斷言 02 的 `eth0` carrier = 0。線忘了拔,會改變很多臂的前提:`fw-badinclude` 的暴露範圍、「02 離開 mesh 就沒有路」、eth 段上只有桌機(F-H14)。在 `s0_assert` 加上 02 carrier = 0(onsite 期間除外)。
- **m13 擷取與驗收的細節**:
  - VLAN 雙層臂在 `br-ahwlan` 上擷取時,`tcp[tcpflags]` filter 不會比對到帶標籤的 frame,要用 `vlan and vlan and tcp …`。否則「看到的 SYN 不足」會變成一律 INVALID(安全,但臂跑不起來)。寫進 E-H15。
  - §8.1 壞 rootfs 的 loop 驗收裡,`mount -t squashfs` / `mount -t ext4` 在 WSL 要真 root(squashfs 不能在 userns 掛載)。寫明用 WSL root 跑(與 ab-card 相同),或只留 `unsquashfs -s` 加上 superblock 的位元組斷言。
- **m14 E-H13 前置留下的 `shutdown.reason`**:`apply` 成功後會寫 `$RUNDIR/shutdown.reason = "sysupgrade-trial (slot B)"`(`batman-slot:740`)。`stage-root` 解除 arm 之後,這個檔還在,下一次重開的 boot-reasons 會記錯。在前置步驟登記 `rm-file`,或在 brewrite 之後斷言它不在。

## 5. 附錄 A 逐列核對摘要

- **§8 每個片語**:逐段對過 `prov-p3-routes` / `owner` / `settings`(含「`wifi reload || wifi` 退路沒觸發」→ ST4、DE → ST14、legacy 20 → RT4、HTTP 19 → RT2)/ `country-join` / `status-diag` / `bundle-gate` / `http`(v5 規則的負對照 → HT1 S、v6 → HT10 S、`healthok-2field` → HT4)/ `upload` / `update`(七種拒絕、四包 tar、FIFO、上傳後改、kill / 斷電、phase 3、回滾、升級、sysupgrade、bench)/ `autocommit` / `transfer` / `luci-reset` / `fw-boot` / `eeprom`。都對得到列。UD8c 的鑑別力見 m5。
- **§6 生命週期**:每一列都對得到(誠實界線的列照 P3)。
- **§7**:除了「偷換 pending 版本」(m6),每一列都對得到。
- **D-1…D-17**:附錄 A 的 D 對照表逐一核對過,正確。
- **G**:只有 UD12、UD16(H4-U8)。
- **「—」**:ST17、ST22、BG4 都附了理由。
- **單獨 P 的列**:HT15–HT17、HT22、UP5、UP6、UP8、UP11、UD9、UD10b、UD11、FB3、SEC1 都有前提證據。HT15 沒有 flip,沿用前幾輪的接受。

## 6. 安全(逐 actor,只寫 v5 新增或改變的)

- **遠端 / mesh 上任何人**:沒有新的入口。ethsim 的 `phy9h4` 殘留見 m11(fail-open 的口子,靠段 1 + P9 收掉)。
- **本機非 root(節點)**:fault 檔信任邊界不變(`rundir.sh:44-52`)。p6 `dv-undo/<run>/` 是 root 0700;參數驗證封閉清單成立。
- **被入侵的 provd**:UD8b / UD8c 是對這個 actor 的測試,鑑別力見 m5;漏的那一列見 m6。
- **被入侵的手機**:可以把 relay 轉到別台 → m3(DAC 檢查要涵蓋 HTTP)。
- **AP 上的其他 client**:不變。
- **成員節點(持有 `psk_member`)**:冒充別台會被 DAC 釘選擋下(§4.2)。負對照 (a)「不屬於任何節點的 DAC」與 (b)「強制先試 02」都有鑑別力。
- **實體**:不變。
- **供應鏈 / 我們自己的錯**:EEPROM 沙箱逃脫見 **M2**。undo 執行器卡住時的兩個寫者見 **M1**。
- **Windows 使用者行程**:`\\wsl.localhost` 的界線已經寫明(§3.2)。

## 7. 判決

**REJECT**(0 BLOCKER / 2 MAJOR / 14 MINOR)。

- **M1**:deadman 遇到「host 執行器還活著」就延後段 2。照 `cmd_dm_fire` 的時序,這只會在 host 卡住、超過「lease + 10 分」時發生 → 段 2 沒人做、鎖被佔住、journal 兩個寫者;設計的重疊測試做不出這個情況。改成每個動作有上限、拿不到鎖時殺掉卡住的 host 執行器再做兩段,並附負對照。
- **M2**:`pivot_root` 沙箱沒有 `cd /`、沒有關掉繼承的 fd → 實測可以經 cwd 與 fd 寫到宿主 `$HOME`;canary 負測試只試絕對路徑,在逃脫的設定下照樣 PASS。補上 `cd /`、關 fd、`env -i`,加 cwd / fd 兩條附對照的負測試。

**收斂狀態**:已收斂。v4 的 BLOCKER(認目標)經原始碼核對確實解了,`node_cert` 方案與 RPA 窗的前提都有證據。兩條 MAJOR 都只動 §5.7 與 §8.2 各一小段,加上兩組測試;MINOR 是文字與個別臂的修正。v6 修完這兩條、附上負對照的規格之後,預期可以 APPROVE。下一輪仍要審整份,但不需要重寫。
