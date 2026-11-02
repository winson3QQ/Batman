# H4 設計 v3 審查 — 審查者 B(第 3 輪)

**審查對象**:`docs/design/254-h4-harness.md` v3(`harness/254-h4` @ 282b48b),整份重讀。

**上層**:P3 `254-p3-impl.md` v7.1(`feat/254-p3` @ dfedd03)§2、§3、§4–§8、附錄 D;h23 v14;main 2ecf1cb;firmware `/home/yello/firmware-2710`。

**方法**:
- 先從實際使用情境走一遍:使用者多半遠端;只有一次現場(重燒 → S0-pre → 手機 → §7 探針 → E-H13);桌機 Git Bash + WSL,BLE 經 interop 用 Windows bleak;S20 常駐。
- 再逐條查證假設:
  - 讀原始碼(`file:line`);
  - 04 上的唯讀指令:`cat`、`uci show`(濾掉 `.key=`)、`ip`、`nft`、讀 `fw4` 原始碼、`/proc/sys`、用 `awk` 讀 regdb;
  - WSL 上的唯讀檢查:binfmt、qemu、firmware 的 git ancestry。
- 沒有改任何節點狀態,沒有連 BLE,只寫了這份報告。

**結論**:**REJECT**,共 **1 BLOCKER / 3 MAJOR / 17 MINOR**。

v2 的 BLOCKER 與 10 條 MAJOR 大多真的解了(見 §3)。骨架已經收斂,這一輪的問題都是局部的,不需要重寫。

但有一條新的 BLOCKER:在 S0-pre / S0 上兩台都是 member,BLE 的認目標方法因此失效。結果是所有 `--via ble` 的臂不是連錯節點,就是全部 INVALID。

另外三條 MAJOR 都落在**那一次現場**或**主機死掉時的還原**上。照現在寫的去做,現場會白跑一趟,或者還原時兩個執行者互相打架。

---

## 0. 我自己取得的證據(節錄)

**E1:STATUS 的 key 5(序號末 4 碼)只在 unclaimed / legacy 時才有**(`feed/batman-prov/src/provd/server.go:60, 562-575`)
```
var stateNum = map[string]uint64{"unclaimed": 0, "claimed": 1, "member": 2, "legacy": 3}
...
	m := cbor.M(1, []any{uint64(1), uint64(0)}, 2, []any{"halow"}, 3, n, 4, s.c.trial)
	if (n == 0 || n == 3) && len(s.c.deviceID) >= 4 {
		m = append(m, cbor.Entry{K: uint64(5), V: s.c.deviceID[len(s.c.deviceID)-4:]})
```
- 廣播也只帶服務 UUID(`cmd/batman-provd/bluez.go:269`:`"ServiceUUIDs": {Value: []string{SvcUUID}}`)。
- F-H3 的實測是在兩台都是 **legacy** 的時候做的(04 目前 `prov.meta` = `state=legacy`)。

**E2:`batman-slot apply` 遇到帶 `root.squashfs` 的 payload,會先檢查 magic**(`feed/batman-provision/files/usr/sbin/batman-slot:614-618`)
```
	SQ="$PAYLOAD/root.squashfs"
	if [ -f "$SQ" ]; then
		[ "$(hexdump -n4 -e '4/1 "%c"' "$SQ" 2>/dev/null)" = hsqs ] || die "payload rootfs is not a squashfs"
	...
	else
		SQ_BYTES=$(sed -n 's/^size=//p' "$PAYLOAD/metadata" ...)   # streamed rootfs
```
- 串流路徑(`stage-root` + 呼叫端 dd + `apply`)不檢查 magic。
- P3 的 `write` 走串流(P3 §3.7.5 第 5 步)。

**E3:claim 之後 dropbear 改成只收 key**
- `etc/init.d/batman-prov-lock:25-31`、`usr/lib/batman/prov-lock.sh:141-146`:`PasswordAuth=off`、`RootPasswordAuth=off`。
- chain1 在 claim 之前先放 lab key(`chain1-254.sh:4-8`:「claim on B (lab key first, publickey PROVEN)」)。
- P2 的擁有者動詞裡有 `ssh_keys/set`(`provd/session.go:79`)。

**E4:`network/join` 需要 COSE 的 net_config,外加加密給該節點的 net_secrets**(`node/node.go:1003-1017`)
- repo 裡**沒有** `provgen.py`(`find . -name 'provgen*'` 是空的)。
- 能產生這兩個物件的只有:
  - `tests/tools/provclient/net.go:185-269`(Go,在節點上經 helper socket 跑);
  - `tests/vectors/219-protocol/gen.py:302-330`(`sign1`、`encrypt`)。
- `peer.py`(`tests/tools/peer/*.py`)沒有任何 netcfg / secrets 的程式。

**E5:EEPROM shim 從 1.5.12-wsl.4 起就有**(firmware 樹,唯讀)
```
5ec36f40 feat(#254): shim /sbin/persistent_vars_storage.sh so EEPROM persistent vars are never read
07f2063 has-shim   (= 1.5.12-wsl.9+f2f2bf6.fw07f2063)
9d87d02 no-shim    (= 1.5.12-wsl.2)
7049fd8 no-shim    (= 1.5.11-rel.1)
git ls-tree 07f2063 → files/sbin/persistent_vars_storage.sh
```

**E6:現有 lease dead-man 的固定順序**(`scripts/node/ble-lib-254.sh:327-345`、`prov-lease-254.sh:30-68`)
1. `kill_run_groups`;
2. `unbind-all`(lim 120);
3. `rm -rf /tmp/run/batman-prov-test`;
4. 還原 upper 裡的 helper;
5. 有 `restoring.<run>` 標記就停在這裡;
6. `provd_restart`;
7. `radio_restore`;
8. 啟動 joinwatch / openmanetd / tailscaled。

lease 鎖是每個指令各自 `lock 30` 取得,不會跨整段持有。

**E7:`fw4`**(04 `/sbin/fw4:20-70`)
- `firewall stop` = `fw4 flush` = 刪掉所有表;
- `fw4 start` 遇到已載入時會 `die "already loaded"`。

**E8:04 的其他事實**
- `fs.protected_symlinks=1`、`protected_regular=2`;
- 有 `/usr/libexec/ip-full`(含 `ip netns`);
- `wget` 的 help 是 `--timeout=N | -T N  Set connect/request timeout`;
- `CONFIG_NF_TABLES_BRIDGE=m`;
- DHCP `ahwlan`:start 100、limit 150;
- regdb:AU 有 ch 40(4 MHz、922.0 MHz,與 US 相同);DE 沒有 ch 40;
- `/etc/rc.local` 是空的;
- 04 目前 `state=legacy`。

**E9:procd 的 `respawn 3600 5 0`**:第三個值 0 = 不限重試次數。procd 只在 `respawn_retry > 0` 時才會判定 crash loop 並停止。provd 的 init 用的正是這組值(`files/batman-provd.init:14`)。

**E10:WSL**
- 已裝 `qemu-user-static 1:8.2.2+ds-0ubuntu1.18`;
- binfmt `qemu-aarch64` 的 flags = `POF`(F = 固定直譯器,chroot 內也能用);
- `/mnt/c/.../Python313/python.exe` 存在;
- `appendWindowsPath = false`。

---

## 1. BLOCKER

### B1. S0-pre / S0 上兩台都是 member,STATUS 沒有 key 5,blebridge 認不出目標 → BLE 臂不是全部 INVALID 就是連錯台

**情境**
- §4.2 認目標的流程:
  1. 掃服務 UUID;
  2. 依 RSSI 逐一連線;
  3. 讀 `STATUS` 的 key 5,不是目標就斷線。
  
  控制行是 `CONNECT <last4>`。
- E1:key 5 只在 state = 0(unclaimed)或 3(legacy)時出現。S0-pre 與 S0 的 02、04 都是 member(§3.1)。廣播只有 UUID,兩台一模一樣。
- F-H3 證明的是 legacy 狀態下認得出來。現場重燒、S0-pre 建好之後,這個前提就不成立了。

**後果**
- 實作若照寫「沒有 key 5 → 不是目標」:
  - R / RB / RD / T 上的所有 BLE 臂、`s0_assert` 的 BLE 讀取,全部 INVALID;
  - S0-pre provision 最後一步的 `s0_assert` 本身就過不了,**現場那一趟的後半段全部白做**。
- 實作若退而求其次「取 RSSI 最強的」:
  - 04(−62)通常比 02(−80)強,但不保證(手機、人、門的位置都會變);
  - H0 同時是兩台的擁有者,`auth/owner` 在兩台都會成功,所以連錯了也不會被發現;
  - 破壞性的臂(`owner/remove`、key 20、`network/update`)會打在 02 上,而判定與節點端佐證讀的卻是 04。

**修法**
- 認目標改在 **peer.py 核心(WSL)** 做,而且要經過認證:
  1. 橋只做 `SCAN`(回傳位址 + RSSI 清單)、`CONNECT <addr>`、`CLOSE`;
  2. peer.py 連上後做 Noise NX,把節點的 static key 與金鑰庫裡**每台各自記下的值**比對:
     - S0 的兩台在認領時記下;
     - F 載具與 L 載具由 HF / Hx 認領時記進 `run/`;
     - 也可以再讀匿名可用的 `info` key 1(deviceID,`server.go:532`)當第二層;
  3. 不符就 `CLOSE`,換下一個位址;全部不符 → INVALID。
- unclaimed / legacy 的節點仍可用 key 5 加速,但最後一定要通過第 2 步。
- 加一個負對照:在 S0-pre 上要求連「04」,但把庫裡 04 的 static key 換成 02 的 → 必須 INVALID,不准連上 02。
- 把這一步加進 E-H9 的剩餘項目,並在**現場之前**於 F 載具(04 的 B 新卡)上證明 member 狀態下認得出來(見 M2 的預演)。

---

## 2. MAJOR

### M1. E-H13(以及照現在寫法的 UD4)的壞 rootfs 會在寫入前被 `batman-slot apply` 拒收,現場那一臂做不出來

**情境**
- §8.1 的做法:「破壞 squashfs superblock 的前 4 bytes(magic),`SHA256SUMS` 用破壞後的 sha → 簽章與讀回都過」。
- §15 第 6 步:「wsl.22 沒有 update 動詞,所以 E-H13 用 ssh `batman-slot apply` 寫入壞 rootfs payload」。
- E2:payload 目錄裡有 `root.squashfs` 時,`precheck` 先看 magic,不是 `hsqs` 就 `die "payload rootfs is not a squashfs"`。
  - 這時還沒進 `begin_write`,所以什麼都沒寫、沒 arm、也不會重開。
  - E-H13 會在現場停在第一步。觀察項(panic 行、ext4 的嘗試、重開時間)一個都拿不到,要再跑一趟現場。
- P3 的 `write` 走串流;現在的程式在串流路徑不檢查 magic,所以 UD4 在 P3 rc 上可能過得去。但這只是「現在剛好沒檢查」。實作者在串流路徑補一道 magic 檢查是很合理的防禦;一旦補上,UD4 就會變成 reason 11,不再是「新版開不起來」。

**修法**
1. 壞的方式改成**保留 magic**,改破壞會讓 mount 必定失敗的欄位。例如:
   - 把 squashfs superblock 的 `s_major`(offset 28,u16,正常 = 4)改成 0xFFFF;或
   - 把 `bytes_used`(offset 40)改成遠大於分割的值。
   
   長度不變,`SHA256SUMS` 用破壞後的 sha。這樣兩條路徑(`apply` 與串流)都寫得進去,P3 日後加 magic 檢查也不受影響。
2. 或者讓 E-H13 走 sysupgrade 用的串流路徑:
   1. `batman-slot stage-root <dir>`(目錄裡不放 `root.squashfs`,`metadata` 帶 `size=`);
   2. 把壞映像 dd 到它印出的裝置;
   3. `batman-slot apply <dir>`。
3. 不論用哪一種,**現場之前**先做兩件事:
   - 在 WSL 用 loop 檔驗證:前 4 bytes 仍是 `hsqs`;`mount -t squashfs` 必定失敗,`mount -t ext4` 也失敗。
   - 在 04 上證明它會被收下:在 lease 底下真的跑 `stage-root` + `apply`,但**不重開**,之後 invalidate。
4. 補 E-H13 的還原。回到 A 之後,B 是一個「已驗證、cmdline 正確、但開不起來」的槽。之後任何 `rollback`(包括 chain1 dead-man 的 `batman-slot rollback`)都會讓 04 進入每 10 s 一次的 panic 迴圈,遠端救不回來。所以 E-H13 結束時要 brewrite B(或 `invalidate_slot`),並斷言 `BATMAN-BAD` 存在或 B = V。
5. P3 §8 寫的注入是「目標槽 kernel 壞掉」,H4 改成破壞 rootfs。把這個差異寫進附錄 A 的 UD4,片語 lint 才對得上。

### M2. S0-pre 的建立方法缺一個工具與兩個實際步驟,而且沒有在現場前預演

**情境**(現場只有一次:重燒 → S0-pre provision → 手機 → 探針 → E-H13)

1. **N0 的 net_config / net_secrets 沒有工具**。
   - §3.1 寫的是 `provgen.py` + `network/join`。但 `provgen.py` 不存在(E4),也不在 §1.2 的檔案清單裡。
   - `network/join` 要一份 owner 簽的 COSE net_config(`node.go:1007`),以及用該節點金鑰加密的 net_secrets。peer.py 目前沒有任何這方面的程式。
   - N0 的 SAE 金鑰在哪裡產生、怎麼進金鑰庫、怎麼分別加密給 04 與 02,都沒寫。
2. **claim 之後 root 被鎖成只收 key**(E3)。S0-pre 之後所有 root 動作(`halow-setkey --ap`、`s0_assert` 讀 uci 與 hostapd、lease、ethsim)都要 ssh 進得去。
   - 04:claim 之前可以用 `none` 登入先放 lab key(chain1 的做法)。
   - **02:重燒後是 placeholder 金鑰、沒有 mesh,eth0 又沒接線(F-H14),所以 claim 之前主機根本連不到 02**。唯一的路是 claim 之後經 BLE 送 `ssh_keys/set`。設計沒寫這一步;照做的結果是 02 在現場被鎖在門外。
3. **順序沒寫**。04 join N0 之後就離開 fleet mesh;02 要靠 BLE join 才回得來;之後才能從 mesh ssh 進 02 做 `halow-setkey --ap C0'`。這段順序與每一步的斷言都沒有寫。
4. **沒有預演**。S0-pre provision 是全新的程式,第一次執行就在那一次現場。但其實可以先預演:§15 第 4 步本來就會在 wsl.22 上跑 `fresh-254.sh`,04 的 B 新卡就是一張 unclaimed 卡,可以在現場前完整跑一遍:claim → `ssh_keys/set` → join(單節點的 N0)→ `halow-setkey --ap` → `s0_assert`(含 B1 的認目標)。

**修法**
- §1.2 加 net 物件的產生器。直接沿用 `gen.py` 的 `sign1` / `encrypt`,或把 provclient 的 `net.go` 編成主機端的子命令。並給它 selftest:對 vectors 逐位元組重現(比照 h23 §4.6 原本的計畫)。
- §3.1 寫出 S0-pre provision 的步驟表,每台依序:
  1. claim;
  2. `ssh_keys/set`(lab key,經 BLE);
  3. 以 publickey 證明登入(沿用 chain1 的 `pk_proof`);
  4. `network/join`:04 做第一版(等同 `--first`);02 用 04 的 net_config 加上自己的 net_secrets;
  5. 等 `.txn` 消失;
  6. `halow-setkey --ap`(值的檔案經 stdin 推到 `/tmp/run/batman-dv/c0`);
  7. `s0_assert`。
  
  秘密的流向寫進 §12。
- §15 在現場之前加一步「S0-pre 預演(F 載具、04 單節點)」,並列為 H4-U7 的前提。

### M3. undo journal 與 lease dead-man、EXIT trap 之間的契約沒有定義:執行順序、並發、撐過重開

**情境**

1. **順序**。§5.7 說「EXIT trap 與 lease dead-man 都依逆序執行」。但 dead-man 本身已經有固定順序(E6),journal 插在哪一步沒寫。而臂的實際順序通常是「先開 fault / bind,再改狀態」,所以逆序會變成**先還原狀態、後關 fault**:
   - ST6 / ST8 / ST12:`setkey-apply-fail` 還在時執行 `ap-restore` → setkey 把「寫回 C0」也當成失敗並回滾 → AP 留在 ALT;
   - `setkey-pause` 還在 → 每一次 `ap-restore` 都多等 30 s;
   - ST9 的 S 臂:`halow-setkey` 仍被 bind 成「`uci set …=$AP`」的變體,`uci-argv` shim 也還在 → `ap-restore` 會經過那個洩漏用的變體寫回。
   
   結果是還原失敗(FAIL + NEVER_KNOWN),而發生的時機正好是主機死掉、使用者不在場的時候。
2. **並發**。§9 說「兩者互斥:EXIT trap 執行時持有 lease 鎖」。但 lease 鎖是每個節點端指令各自取得的(E6),主機的 EXIT trap 則是一連串 ssh 呼叫。
   - `fw-start`(含 `dockerd restart`,約 3 分)加上 `ap-restore`(setkey 等鎖 90 s + settle 30 s + 讀回 60 s),很容易跨過 lease 期限 → dead-man 會同時執行同一份 journal。
   - ssh 斷線時,節點上執行到一半的動作會收到 SIGHUP。
3. **重開與斷電**。journal 在 tmpfs。§5.7 的說法是「有持久變更的臂不包含重開;下一個 run 的 P9 依 dirty flag 印出殘留項目」。
   - 但非預期的重開(watchdog、#305 BT UART、斷電;這些都是生命週期矩陣要求的路徑)之後,journal 已經不在了。P9 不知道殘留的是 `auto_includes=0`、`disable batman-provd`,還是 `disable batman-provhelper`。
   - provd 被 disable 的 04 開機後**沒有 BLE 管理通道**,而 dirty flag 只會說「有個 run 沒收乾淨」。
4. **既有契約的措辭**。
   - lease dead-man 的契約是「never touches a slot or p5」(`prov-lease-254.sh:15-16`),但 `ap-restore` 經 setkey 的 `--save` 會寫 p5。
   - `restoring.<run>` 存在時(pr_restore 擁有節點、之後會重開),journal 要不要跑,沒寫。

**修法**
- EXIT trap 與 dead-man 共用**同一個節點端執行器**(`prov-undo-254.sh run`),契約分兩段:
  - **段 1(去武裝)**:刪掉所有 shell fault、`fault.*`、killpoint;`unbind-all`;helper 與 provd 換回 release 並斷言。
  - **段 2(狀態)**:journal 逆序執行。
  
  段 1 一律先做,與登記順序無關。
- 執行器在節點上以 `setsid` 跑一次,整段持有 lease 鎖(或先 `renew` 一個足夠的預算,例如 20 分)。
  - 每做完一項,原子改寫成 `done`;重入時跳過 `done` 的項目。
  - 主機的 EXIT trap 只負責「啟動它並等結果」。
- 會**撐過重開**的動作(`uci commit`、`disable`、`auto_includes`),同時登記到 p6 的 `dv-undo.<run>`(root 0600)。
  - 開機後的 P9 與下一個 run 的 preflight 依它還原;或者規定這類臂一律「先在 p6 登記,再改」。
  - §11「斷電 / 非預期重開」那一列要有測法:臂進行中 sysrq,重開後斷言殘留項被列出並還原。
- `restoring` 存在時:段 1 照做;段 2 交給 pr_restore(它會重開並還原 p5)。寫進契約。
- lease 契約改寫為「dead-man 不直接寫 slot 或 p5;經 setkey `--save` 的寫入屬於 setkey」,並在 §9 列出。

---

## 3. v2 意見的處理(只列我這邊的 B1、M1–M10、m1–m19,逐條對 v3 核對)

| v2 意見 | v3 的處理 | 核對結果 |
|---|---|---|
| B1 S0 在 pre-P3 建不起來 | S0-pre / S0、W 的判法、`upgrade`、§15 的順序 | **方向解了**。新問題:B1(認目標)、M2(工具、02 進不去、沒預演) |
| M1 工具 | uhttpd、`wget -T`、`netstat`、`ubus get_clients`;判定都在 04 端 | ✅ 我實查 E8,一致。殘留:m4(lo 的 127.0.0.1 不鑑別)、m5(50 conn/s 被並發上限壓到約 10) |
| M2 br-ots | 改成 docker0 | ✅。殘留:m6(docker0 那組 veth 的位址沒寫) |
| M3 換規則型的 S | 兩邊都 `http-nofw` + LISTEN;UP3 用 `phy9h4` | ✅。`phy9h4` 只在 `http-nofw` 時存在;萬一殘留,helper 前提檢查失敗 → 不給 `http.2`(fail-closed)。有被圍住 |
| M4 autocommit | `provd-id-pid` 改成 helper fault;先刪 `provd-stable`;AC6 的變體改正 | ✅ |
| M5 跨重開 | RB 的界線;UD16b 改在 committed 上;D-9 → G(H4-U8);ST7 / ST20 改 F + RB | ✅。殘留:m9(其他 G 列沒有使用者決策) |
| M6 主機死時的還原 | undo journal + HT14 的 60 s 保險 | **部分**:機制有了,契約不完整 → M3;保險沒有取消 → m10 |
| M7 F 的 dead-man | boot_id、LR1 排最後、重種 | ✅。殘留:m11(B 上重開迴圈時期限永遠被重設) |
| M8 廣播判定 | 04 端 `bluetoothctl show` + provd log;SD3 的 P 改成 peer 自己數 | ✅ |
| M9 漏列 | UD11 真的降級、UD3b、UD12b、UD10b、HT16b / c、UP11、HT8 的 IP + ARP、D-12 | ✅。殘留:m7(HT16c 的前提錯了:respawn 不會用完) |
| M10 未探的假設 | E-H9 部分完成;qemu;絕對路徑;bleak 依 hash | ✅ 我實查 E10。E-H16 仍未做,但 binfmt 有 F 旗標,風險低 |
| m1 ERE | 版本寫死 | ✅ |
| m2 片語 ID | §6.3 | ✅ |
| m3 手機 IP | 兩台的 leases + neigh + 廣播 ping | ✅ |
| m4 手機自己說的結果 | tcpdump + counter | ✅ |
| m5 ST11 | 改成量時間 | ✅ |
| m6 UP5 | 以 uid 471 直接寫 | ✅ |
| m7 UD19 | 走 provclient | ✅ |
| m8 壞 rootfs | 改成破壞 magic | **改出新問題** → M1 |
| m9 §7 改 AP | 手機先連上 C0 | ✅ |
| m10 庫的範圍 | `run/` | ✅ |
| m11 孤兒橋 | EOF + preflight | ✅ |
| m12 test init | lint + `upper-provd` 退路 | ✅(ujail 的 bind 仍是推論,待 E-H12) |
| m13 pending 殘留 | §1.4 第 4 點、`pending-del` | ✅ |
| m14 副作用 | §13 | ✅。殘留:m13(UD3 的 S 會真的進試用) |
| m15 hostapd conf 路徑 | 從 `network.wireless status` 取 | ✅ |
| m16 chain1 的證據 | c12567b | ✅ 我查到 commit 訊息裡有「chain1 59/0」 |
| m17 `batman_opf` | §5.4、§1.4 | ✅ |
| m18 HT3 | 改成 W | ✅ |
| m19 秘密斷言 | 原值 grep;高熵;CJ1 改由 root 設 uci | ✅。CJ1 的手法我查過可行:AU 有 ch 40(E8),wsl.22 會照樣入網,W 那一行真的會出現 |

---

## 4. MINOR

- **m1 EE1 的負對照 image 選錯了**(E5)。
  - `1.5.12-wsl.9+f2f2bf6.fw07f2063` 已經帶 shim(firmware `5ec36f40` 是 `07f2063` 的祖先)。在它上面四個 key 都不會被採用,W 做不出來。
  - 改用 `1.5.12-wsl.2+f2f2bf6.fw9d87d02` 或 `1.5.11-rel.1`(都沒有 shim),並在單位裡加一條 P:斷言負對照的 rootfs 裡沒有 shim 版的 `/sbin/persistent_vars_storage.sh`。
  - 另外補上 P3 / stage1 要求的直接斷言:「shim image 對所有 key `READ` 回 rc 1」(`254-stage1-impl.md:487`)。
- **m2 pre-P3 上的 RB 前置**。wsl.22 沒有對應的 prov_test helper(P3 才有),所以 `--pre-p3-full` 執行 `push-helper` 會失敗 → INVALID → 拿不到 W 那一行(ST3、ST16、OW6、UP1、UD5…)。寫明:pre-P3 時跳過所有需要 P3 產物的前置,直接打第一個 P3 動詞,以它的 `E_UNSUPPORTED` 當作 W 行。
- **m3 `release-min-serial = 2` 寫的是「prov_test image」**。但 RB 是 release image 加上推進去的 prov_test helper。要寫明 min-serial 在 RB 上怎麼生效(編進 prov_test helper,或 bind 那個檔);否則 UD7 的「serial < min」在 RB 上可能是 1。
- **m4 lo 臂的 `127.0.0.1:8095` 不鑑別**。provd 只 bind `http.2` 給的位址(P3 §3.8.1),所以連 127.0.0.1 不管有沒有規則都是 RST。HT9 的 S(`http-nofw` → 連得上)只能用 `<br-ahwlan IP>:8095`。127.0.0.1 那一條只當 counter 觀察,不當斷言。
- **m5 HT8b 的 50 conn/s 實際被壓到約 10 conn/s**。
  - 並發上限 20 × 每條 `wget -T 2` = 最多每秒 10 條。P3 §8 的片語是「50 conn/s、10 分鐘」。
  - 二選一:把上限提高到 ≥ 120(busybox / uclient 的行程很小,先在 E-H15 量 RSS);或在附錄 A 明寫「實際約 10 / s」,列為誠實界線,請使用者決定。
  - 現在只寫「實際速率記錄下來」,等於默默改了規格。
- **m6 docker0 那組 veth 沒寫位址與路由**。要用 172.17.0.0/16 的位址,目標是 04 的 br-ahwlan IP(或 172.17.0.1)。寫明 rp_filter 與 ARP 會怎麼走,並在 E-H15 實測一次同路徑正向:「netns → 04:80 經 docker0 = 200」。
- **m7 HT16c 的前提錯了**(E9)。`respawn 3600 5 0` 的 retry = 0 代表無限重試,procd 不會停。改成:「每 5 s 重生一次的迴圈期間,HTTP 不聽、helper 正常、上傳檔被刪」,並寫出誘發方式(主機在每次重生後 `kill -9`,或給 provd 一個 Go fault `crash-on-start`)。
- **m8 ST13 的 P 少一條**。在 wsl.22 上,`/tmp/.uci/wireless` 的暫存只會讓 `settings/set` 回 E_U(動詞層),所以標 W(E_U) + P 是對的。但 §13 寫了「臂後斷言暫存的 key 沒有被別人 commit」,附錄 A 沒有;補上。
- **m9 G 列超出 H4-U8 的範圍**。
  - H4-U8 只授權 D-9(UD16;UD12 同類)。
  - ST7(D-6)、ST19(D-5)、UD3b(B6)、UP10(D-15)、AC5 也標成 G,沒有使用者決策。
  - 二選一:補 S(例如給 UD3b 一個 helper fault `no-boot-disarm`;給 ST7 一個關掉 D-6「重新封鎖」的 setkey fault);或把這五列列進 §1.1,請使用者決定。
- **m10 HT14 的 60 s 保險沒有取消**。
  - 臂在 8 s 內就會以 `fw-start` 還原。但保險在第 60 s 仍會執行 `firewall start`(E7:已載入時 `die`,無害)與無條件的 `dockerd restart`(OTS 再中斷一次),而且可能打在下一臂(例如 HT15)的中間。
  - 正常還原後要殺掉保險的 process group,並把它列進 §9 的寫者。
  - 另外,04(DUT)上沒有防火牆 ≤ 60 s 是一個暴露,請比照 H4-U9 取得使用者同意。
- **m11 B 重開迴圈時,F 的期限永遠不會到**。
  - 現在的規則是「boot_id 不同 → 本次 uptime + 30 分」。如果 P3 rc 在新卡上每幾分鐘就重開一次(watchdog、panic),而主機同時死了,期限每次都被重設。
  - 改成把**剩餘預算**帶過重開:迴圈每 60 s 記一次 `last_seen_uptime`;boot_id 變了 → 新期限 = 本次 uptime + max(舊期限 − last_seen, 0) + 5 分。只有主機續期時才把預算加回 30 分。
  - 加一臂:B 上連續以 sysrq 重開、不續期 → 仍在預算內 restore。
- **m12 p5 的第二個寫者沒列**。
  - ST16、UD16b 要「讓 p5 只因新 key 而 stale」,做法是 root 改 p5(v2 我提的修法)。
  - §9 沒有這一列,undo journal 也沒有對應動作。S 臂(`p5-autosave-off`)結束時 p5 仍是 stale,之後的 `update.check` / OTA 會被 reason 17 擋下。
  - 加一個 `p5-save` 動作(`batman-config-save --save`,再以 `--check` 斷言 fresh),並在 §9 列為 lease 底下的例外寫者。
- **m13 UD3 的 S(`upd-after-arm`)會真的進試用**。killpoint 在 arm 之後 sysrq → tryboot 是一次性的 → 下一次開機就是另一槽的試用。§13 沒有列,還原方式也沒寫(等 autocommit 決定,或 hold 後 revert)。
- **m14 `set-fault` 沒處理前置狀態**。
  - shell fault 放在 world-writable 的 `/tmp`。04 的 `protected_symlinks=1`、`protected_regular=2`(E8)會擋下兩件事:root 跟著別人的 symlink 寫入,以及以 O_CREAT 打開別人擁有的檔。所以這裡不會被拿來覆寫系統檔。
  - 但如果本機非 root 行程先建了同名的檔,`set-fault` 會失敗。
  - 寫明:建檔前斷言檔案不存在,存在就 INVALID 並印出擁有者;建檔用 `umask 077` + 原子 rename。並把「依賴這兩個 sysctl」列進 §12 的證據。
- **m15 C0 的 QR 產生器沒指定**。
  - Python 標準庫沒有 QR。如果 HTML 從 CDN 載 JS,放著密碼的頁面就會執行第三方程式碼。
  - 寫明:用 hash 釘選的 `segno`(加進 WSL venv 的 `--require-hashes` requirements)產生 inline SVG;頁面不准載入任何外部資源;並斷言檔案裡沒有 `http`。
- **m16 `s0_assert` 的「目前槽」**。每次 T 臂 commit 後,槽字母都會換。斷言應該是「`BATMAN_VERSION` = 受測 image,且 `is-trial` = committed」,而不是比槽字母。另外,升級臂與降級臂結束時要回到哪一槽,寫進 §13。
- **m17 chain1 的 dead-man 回到 A 之後要人執行 restore**(`chain1-254.sh:16-18`)。F 載具一輪 90–150 分,主機在這段時間死掉的機率不低。寫明:下一個 run 的 preflight 看到 `ch1.fired` 或 `fresh-deadline` 已觸發時,自動跑 overlay-restore + compare + brewrite(遠端就能做),做完才 `s0_assert`。

---

## 5. 逐列對表的結果(附錄 A 對 P3 §6 / §7 / §8 / 附錄 D)

- **§6**:每一列都對得到單位或誠實界線;「換 IP」= U5,已列在範圍外。HT16c 的前提見 m7。
- **§7**:每一條負測試都有對應的列;「偷換 pending 版本」= Go,H4 不需要。
- **§8 的片語**,漏的只有兩處:
  - D11 的「fresh-overlay 檢查 / shim READ rc 1」(m1);
  - 50 conn/s 被默默降速(m5)。
  
  UD4 的注入方式與 P3 原文不同,要在附錄 A 註明(M1 第 5 點)。
- **D-1…D-17**:全部對到。D-1 / D-2 在 §7 探針裡。VLAN 雙層 VID 0 的路徑,我依 kernel 的 `check_vlan_id` 邏輯推論可行(外層 VID 0 加內層 802.1Q / 802.1AD 會被剝掉,再當成 IP 處理),仍以 §7 的實測為準。
- **W 列**:
  - BG1、HT3、HT13、FB1、CJ1、CJ2 的 W 行,都是真的會在 wsl.22 上出現的產品行為差異;
  - 其餘是動詞層的 W + P,符合 §6.2 的規則(pre-P3 的前置見 m2);
  - EE1 的 W 不成立(m1)。
- **S 列**:都是同一載具、單一變數。UD-T1 的 S(同一份 manifest,只差 release / prov_test helper)是乾淨的 flip。
- **G 列**:共 7 列,其中只有 2 列有使用者決策(m9)。

---

## 6. 安全(逐個 actor 補看)

- **本機非 root(04)**:
  - shell fault 的搶建見 m14:有 sysctl 擋著,但要寫成證據。
  - `uci-argv` 在 root 0700 目錄裡,OK。
  - S0-pre 的 `halow-setkey --ap` 經 argv 傳值(setkey 沒有 AP 的 stdin 形式,`halow-setkey:45-50`)→ 執行期間本機任何行程都讀得到 `/proc/<pid>/cmdline`。§3.1 已列為界線(C0 是測試值),P3 之後改經 key 20。OK。
- **被入侵的 provd**:push-provd 時 provd 在 jail 裡,看不到 harness 的檔。OK。
- **被入侵的手機**:Noise 是端到端,手機假造不了正向的交握;負向斷言有節點端佐證。OK。
- **其他 AP client、mesh 上任何人**:`http-nofw` 期間 8095 對 mesh 開著,已列在 §13;HT14 期間沒有防火牆 ≤ 60 s,需要使用者同意(m10)。
- **實體奪取**:手機與庫裡都是 bench 值。OK。
- **供應鏈**:pip / bleak 依 hash 釘選;qemu 是 Ubuntu 套件庫的固定版本;Termux 列為界線;QR 產生器沒指定(m15)。
- **我們自己的錯**:B1(連錯台)是這一輪最大的風險;M1 第 4 點(B 槽留在開不起來的狀態)是第二個。

---

## 7. 可行性逐項(審查指示列出的項目)

| 項目 | 結果 |
|---|---|
| S0-pre:BLE claim + `network/join`(P2 有) | 動詞存在(`session.go:59-80`)。但缺 net 物件產生器、02 的 root 進不去、沒預演 → M2;認目標 → B1 |
| root 執行 `halow-setkey --ap` | 可行:它會放開 keyguard 擋住的項目(`halow-setkey:21-22, 213-221`);`.txn` 存在時拒絕(`:135-140`),所以要排在 join 完成之後 |
| 沒有 key 20 時 AP 怎麼起來 | 同上:重燒後 99zz 把 AP key 設成 placeholder,keyguard 把 AP 關掉;claim 不會重設;`setkey --ap` 放開 MARK |
| `s0_assert` 的兩個版本 | 可行;要配合 B1 的認證式認目標;槽字母見 m16 |
| 金鑰庫 + journal + Windows 備份 ACL | 可行;界線已寫 |
| undo journal 與 dead-man | 見 M3 |
| HT14 的 60 s 保險 | 可行;要取消(m10) |
| 新卡 lib:期限 + boot_id + LR1 | 可行;重開迴圈見 m11,回到 A 後的 restore 見 m17 |
| ethsim 用 04 的真工具 | ✅(E8:有 `ip netns`;uclient 的 `-T` 就是 connect timeout;veth 已載入)。速率見 m5,docker0 位址見 m6,lo 見 m4 |
| `phy9h4` | 有被圍住:只在 `http-nofw` 期間存在,殘留時 fail-closed。`halow-setkey:187` 掃的是 `/sys/class/ieee80211/phy*`,不受 veth 影響 |
| ujail 下的 push-provd | 推論可行:init 是 rc.common 腳本,bind 在 `/etc/init.d/batman-provd` 上有效;jail 從父 namespace bind `$PROG`;provd 是靜態 Go。仍以 E-H12 為準 |
| fault 契約 | 可行。test init 的 `_provd_env` 目前只收純數字值(`batman-provd-test.init:24-33`),`BATMAN_FAULT=a,b` 要 P3 修改;已列在 §1.4 |
| pre-P3 判斷 | ✅(04 的 `BATMAN_FEATURES` 有 `provd-p2(#254)`,沒有 p3 標記) |
| §7 探針 | 可行(uhttpd、tcpdump、nft bridge = m)。它依賴手機先連上 C0 → 也就依賴 M2 |
| E-H13 經 `batman-slot apply` | **不可行**(M1) |
| WSL 上的 eeprom-hooks | 可行(`dv-sbx.sh:17-19, 43-45, 100`;binfmt 有 F 旗標);負對照的 image 選錯了(m1) |
| 成本 | 估算合理(T 臂的上傳經手機要走兩次 AP,每次 126 MB 約 1–2 分);等使用者決定 |
| §16 開發方式 | 好。建議把三個預演(B1 的認目標、M1 的壞 rootfs 在 loop 檔上驗證、M2 的 S0-pre 預演)寫成 §15 第 2 / 3 步的明確項目 |

---

## Verdict:**REJECT**

- **B1**:認目標靠 STATUS 的 key 5,但 member 節點沒有 key 5 → BLE 臂全部 INVALID,或打到錯的節點。
- **M1**:E-H13 的壞 rootfs 會被 `batman-slot apply` 的 magic 檢查拒收,現場那一臂做不出來;事後 B 槽也沒有還原。
- **M2**:S0-pre 缺 net 物件的產生器;claim 之後 02 的 root 進不去(要經 BLE `ssh_keys/set`);沒有在現場前預演。
- **M3**:undo journal 與 dead-man、EXIT trap 之間的執行順序、並發、撐過重開都沒有定義,主機死掉時會還原失敗。

**收斂狀態**:骨架已經穩定,包括載具、S0-pre / S0、W / S / P / G 的分類、undo、ethsim、接縫契約與逐列對表。v2 的問題大多真的解了。這一輪的四條都是局部修正,不需要重寫。修完之後仍依規則整份重審;我預期下一輪可以到 APPROVE-WITH-CHANGES。
