# H4 harness 設計 v4 — 審查 B(第 4 輪)

**審查對象**:`docs/design/254-h4-harness.md` v4(`harness/254-h4` @ 56dcf42),整份。
**對照**:P3 `254-p3-impl.md` v7.1(dfedd03)§6/§7/§8、附錄 D;h23;main 2ecf1cb 原始碼;firmware-2710;04 / 02 唯讀。
**方法**:先逐條核對附錄 C(v3 意見),再從實際使用的流程走一遍整份,重點放在 v4 新加的東西,每一條都對到原始碼或真機。所有節點操作都是唯讀(cat / ls / sysctl / bridge / batctl 讀取)。WSL 上只做了一次非 root 的 `unshare` 探針,放在 `mktemp -d` 目錄裡,做完就刪了。

**結論先講**:**1 BLOCKER / 1 MAJOR / 11 MINOR → REJECT**。骨架已經收斂。兩條重大問題都是局部機制寫錯(§4.2 的認目標、§5.7 執行器在 dead-man 路徑上的鎖與 lease),不需要重寫。v5 只要改這兩段,再加上 MINOR 的文字修正。

---

## 0. 證據(原始輸出節錄)

```
# 219-protocol.md
:57   節點每次開機產生 25519 靜態金鑰 `s_node`(只在記憶體)…
:282  | `s_node`(25519) | 每次開機 | 記憶體 | Noise 靜態金鑰 |
:515  | §3.3 `s_node` | 每次 **provd 啟動**(含 respawn)重新產生;app 不得快取 `s_node_pub`,每次交握重驗 |
# provd/noise.go:29   // GenerateStatic makes this provd start's s_node (219 §3.3: per start, memory only).
# provd/server.go:104-113  NewServer: st, err := GenerateStatic(rand.Reader)  (每次 provd 啟動)
# provd/server.go:673-683  handshakeParams: case "unclaimed","legacy": return Prologue(...), nil(=NX) ; 其他狀態一律 PSK 6 候選
# provd/noise.go:58-87  psks != nil 且 len(msg1)=32(NX)→ ok==nil → fakeMsg2(隨機 bytes)
# provd/session.go:316-320  onMessage: transport 建立後每則訊息都走 ss.recv.Decrypt;失敗 → "AEAD failure" → session 結束
# provd/session.go:388-391  onMsg1: handshakeAllowed() 失敗 → "global handshake rate (20/min)" → 斷線
# tests/tools/peer/peer_core.py:93-95  device_id = self.cert[7].hex()   (msg2 payload = node_cert)
# 04: ls /etc/batman-prov/identity/ → backend claim.secret ecdh.key node.cert node.key sha256 sn

# scripts/node/ble-lib-254.sh
:97-101  lock(){ exec 9>>"$BT/lock"; while ! flock -n 9 … 30 次 → return 1 }   (每個行程自己開 OFD)
:105-108 lease_valid_for: …[ "$(up_s)" -lt "$4" ]   (過期 → false)
:306-310 cmd_arm(= renew): lock 30 || die ; lease_valid_for || die "lease is not ours or expired"
:327-345 cmd_dm_fire: 等鎖最多 10 分(拿到後一直持有)→ lease 必須「已過期」才動作 → kill_run_groups → role_fire_restore → provd_start → unlock

# batman-slot(main)
:423-427 begin_write = disarm_tryboot + invalidate_slot
:716-738 apply 結尾 arm 一次性 tryboot 並讀回
:900-917 CLI 動詞:active target layout fw-part stage-root apply commit rollback is-trial verify precheck-node verdict-gate(沒有 invalidate / disarm)
:806-846 只有 rollback 路徑會 mount 目標槽的 squashfs(wbox_gate_target、rollback_lock_gate)

# WSL 非 root 探針(unshare --user --map-root-user --mount --pid --fork --net --uts --ipc)
hostname-proc-rc=2          (/proc/sys/kernel/hostname: Permission denied — 沙箱外的 yello 也一樣會失敗)
sethostname-rc=0 now=h4x    (在新的 UTS ns 裡改得掉;宿主 hostname 仍是 DSKT-Moonlight)
mknod-rc=1                  (EPERM — 沙箱外的 yello 也一樣)
host-canary-write-rc=0      (宿主上 yello 擁有的檔案,從沙箱內寫得進去:"canary\npwn")
# kernel 6.6.114.1-microsoft-standard-WSL2;沒有 apparmor_restrict_unprivileged_userns

# 04 唯讀
br-ahwlan stp_state=0 ; batctl bridge_loop_avoidance = enabled
fs.protected_hardlinks = 1 / protected_symlinks = 1 / protected_regular = 2
# rundir.sh:44-52 batman_opf:regular、非 symlink、-O、link 1;否則記 TAMPER(shell fault 的信任邊界成立)
# 99-halow-identity:22-25 新卡的 bootstrap IP = 10.41.254.<random % 253 + 2>,之後 openmanetd 保留位址並重開
# chain1-254.sh:342  "pk_proof … || abort '8.2 publickey does not authenticate — not claiming'"(先證明 key,才認領)
# provclient/net.go:197-205  net_secrets = encryptTo(…, ep, dh …):加密對象是節點的 ECDH 金鑰(info.cert / node_cert key 4)
```

---

## 1. 附錄 C(v3 意見)逐條核對

| v3 意見 | v4 的處理 | 判定 |
|---|---|---|
| B-B1 member 認不出目標 | §4.2 用 Noise static key 認證 | **沒解,換了一個做不到的機制** → 本輪 **B1** |
| A-M1 / B-M2 S0-pre 的 02 與工具 | 02 網路線、claim.secret 經 stdout → stdin、netobj、等 `.txn` 與重開、F 上預演 | 方向對。殘留:步驟 2 讀不到 static key(B1);pk_proof 排在認領之後(m2);netobj 的加密對象寫錯(m3);IP / 身分的找法(m4) |
| A-M2 / B-M1 壞 rootfs | 保留 magic、改 `s_major`;loop 驗收;前置;brewrite | ✅ 我核對過:apply / arm 路徑不會 mount squashfs(只有 rollback 會,`:806-846`);offset 28 = `s_major`;kernel 會以 Major/Minor mismatch 回 EINVAL → ext4 也失敗 → panic。殘留:前置的「invalidate B」沒有 CLI(m5) |
| A-M3 EEPROM 沙箱 | H4-U12 非 root + 逃脫負測試 | 方向對。殘留:四條逃脫負測試都分辨不出結果(m6,有實測) |
| A-M4 counter | named counter;目標 = br-ahwlan IP | ✅。殘留:lo 臂的 tcpdump 介面(m7) |
| B-M3 undo 契約 | §5.7 執行器、段 1 / 段 2、done、p6 | 結構對。**dead-man 路徑做不到 renew,也拿不到鎖** → 本輪 **M1** |
| A-m1 … A-m17 | — | ✅ 抽查 m2、m4、m5、m9、m10、m11、m15、m16,都在文中 |
| B-m1 EE1 負對照 | wsl.2 + P | ✅(F-H39) |
| B-m2 pre-P3 前置 | §2 | ✅ |
| B-m3 min-serial | build tag 編進 helper | ✅ |
| B-m4 lo | 目標改成 br-ahwlan IP | ✅(另見 m7) |
| B-m5 速率 | 50/s、依 RSS 定並發、達不到就列界線 | ✅ |
| B-m6 docker0 位址 | 172.17.250.x、目標是 br-ahwlan IP | ✅ |
| B-m7 HT16c | `crash-on-start` | ✅ |
| B-m8 ST13 | A.3 | ✅ |
| B-m9 G 超出授權 | 補 S;G 只剩 UD12 / UD16 | ✅ 我逐列看過附錄 A:G 只出現在 UD12、UD16 |
| B-m10 HT14 保險 | 可取消、先檢查 | ✅(依賴 M1 修好) |
| B-m11 重開迴圈 | 預算 + 只延長一次 | 語意對,格式沒有延長次數欄位;另有兩個寫者(m8) |
| B-m12 p5 寫者 | §9、`p5-save` | ✅ |
| B-m13 UD3 的 S | §13 | ✅ |
| B-m14 set-fault 前置 | §5.1 | ✅ |
| B-m15 QR | segno(待同意) | ✅ |
| B-m16 槽字母 | §3.1 | ✅ |
| B-m17 dead-man 之後的 restore | §4.4 | ✅ |

---

## 2. BLOCKER

### B1. §4.2 的「Noise static key 認目標」做不到:`s_node` 每次 provd 啟動都重新產生、只在記憶體;member 節點不接受 NX;一條連線只能交握一次

**情境**:現場 S0-pre 第 2 步「讀 static 公鑰寫進庫」→ 第 3 步 BLE 認領 → 之後每個 BLE 臂都要先認目標。

**證據**:
1. **沒有可讀的 static key**:`s_node` 由 `NewServer` 在每次 provd 啟動時產生(`server.go:104-113`、`noise.go:29`),只存在記憶體(219 `:57`、`:282`);協定明文規定「每次 provd 啟動(含 respawn)重新產生;app 不得快取 `s_node_pub`」(219 `:515`)。節點檔案系統上沒有這把 key(04 `identity/` 只有 `claim.secret ecdh.key node.cert node.key sha256 sn`)。所以:
   - 第 2 步「經 ssh 讀 static 公鑰」沒有東西可讀;
   - 就算從某次交握學到值,下一次 provd 重啟後庫裡的值就過期了。H4 自己就會讓 provd 重啟很多次:`set-fault provd`、`push-provd`、`unbind-all`、HT16 / 16b / 16c、段 1。結果是之後所有 BLE 臂都 INVALID。
2. **member 上沒有 NX**:`handshakeParams` 只在 unclaimed / legacy 時給 NX(`server.go:673-683`);member 收到 32 B 的 NX msg1 → `ok == nil` → `fakeMsg2`(隨機 bytes,`noise.go:58-87`)。S0-pre / S0 兩台都是 member,所以「做 NX 前兩則取得 static 公鑰」只會拿到亂數,一律不符 → 全部 INVALID。
3. **同一條連線不能再交握**:交握完成後,每一則訊息都當 transport 解密(`session.go:316-320`);再送一個明文 msg1 → `AEAD failure` → session 結束、斷線。「認證後同一條連線從頭做這一臂的交握」做不出來。
4. 每次認證交握都佔用全域 20 次 / 分的額度(`session.go:388-391`、`server.go:645-660`),§4.2 沒有算進去(m9)。

**影響**:BLE 這一路(大多數單位,加上 S0-pre 的建立)照現在的寫法跑不起來。失敗方向是 INVALID(安全),不會連錯台。但 v3 B1 等於沒解。§15 的 F 預演會先撞到,所以現場不會白跑;不過設計要先改。

**修法**(機制已經存在,改動是局部的):
- **用 `node_cert` 認目標,不用 `s_node`**。msg2 的 payload 就是 `node_cert`(219 `:41`、`:63-72`),peer 已經解析了(`peer_core.py:93` `device_id = cert[7]`)。
  - 對**這一臂自己的交握**(NX / psk_owner / psk_member)驗:
    1. `sig_static` 對 DAC 成立;
    2. `sig_static` 涵蓋的 `s_node_pub` = 這次交握實際的 `s`;
    3. DAC = 庫裡記的值(節點檔 `identity/node.cert` 經 ssh 讀取,或在認領時記下),`device_id` = 庫裡的值。
  - 通過才送第一個 envelope;不符就 CLOSE,一個請求都不送。這樣不需要額外的交握,也不需要「同連線再交握」。
- **預期失敗的臂**(交握註定走 fake path:OW6 被移除的 psk、HT7 NX 被拒、錯 PSK 類):拿不到 `node_cert`。改成兩段:
  1. 先以 H0 的 psk 建一條認證過的連線,記下位址後關閉;
  2. 在 RPA 換址窗內(F-H12 約 900 s,寫死 ≤ 300 s)重連同一個位址做負向交握;
  3. 以 04 端 provd log 的 fake-path 行(或 session 計數)佐證確實打在目標上;
  4. 位址變了 → INVALID。
- 庫裡的身分改成「DAC(或其 sha)+ device_id + 序號末 4 碼」,刪掉「Noise static 公鑰」(§3.1 表、步驟 2、§4.2、§12)。
- 負對照:庫裡 04 的 DAC 換成 02 的 → 必須 INVALID,且 02 端 provd log 沒有任何 envelope(只有交握)。
- selftest 加一條:同一個節點兩次 provd 啟動之間 `s_node` 改變、DAC 不變 → 仍判定為同一台(防止有人又改回比 `s_node`)。

---

## 3. MAJOR

### M1. §5.7「dead-man 呼叫 `prov-undo-254.sh run`,先 renew 20 分、全程持有 lease 鎖」在 dead-man 路徑上做不到:lease 已經過期,鎖在 dm-fire 自己手上

**情境**:主機在臂進行中死掉(睡眠、Windows 更新、`wsl --shutdown`)→ lease 到期 → `dm-fire` 觸發 → 依 v4 呼叫執行器做段 2(`fw-start`、`uci-restore`、`netns-del`、`ap-restore`…)。

**證據**:
- `cmd_dm_fire` 先拿鎖(`lock 30`,最多等 10 分),而且**只有在 lease 已過期時才動作**(`ble-lib-254.sh:327-345`)。
- 執行器的第一步是 `renew` = `cmd_arm`:`lock 30 || die`,接著 `lease_valid_for || die "lease is not ours or expired"`(`:306-310`)。
- `lock()` 是每個行程 `exec 9>>"$BT/lock"` 自己開一個新的 open file description 再 `flock -n`(`:97-101`)。子行程拿不到父行程(dm-fire)手上的 flock → 30 s 後回 1 → `die`。就算繞過鎖,lease 已過期,`lease_valid_for` 也會讓它 `die`。
- 結果:dead-man 路徑上執行器在第一步就死了,段 2 一項都沒做。主機死掉時,節點會留在臂中途的狀態,例如:
  - HT18–21 的 nft / uci;
  - ethsim 的 veth / netns、docker0 UP;
  - key 20 臂的 AP 帳密(手機斷線)。
  
  HT14 的保險會在段 1 的 `kill-pg` 被殺掉。保險通常在 60 s 時已經觸發過,但只要 lease 的預算小於 60 s,就會變成連防火牆都不還原。
- 另外,主機 EXIT trap 那一路以 `setsid` 起的執行器沒有登記成這個 run 的 pg。所以 dm-fire 的 `kill_run_groups` 殺不到它;dm-fire 等鎖 10 分後不拿鎖照做,這時兩個執行器會同時寫段 2,等於兩個寫者寫同一份資源。

**修法**:
1. 執行器做成可被 source 的函式 `undo_run <run> <mode>`:
   - `mode=deadman`:由 `dm-fire` 在**已持有的 fd 9 鎖**之下、於 `role_fire_restore` 之後**同一行程內**呼叫;不 renew,因為 dm-fire 本來就是在 lease 過期後的唯一擁有者。
   - `mode=host`:由主機以 `held` + `arm 1200` 呼叫。
2. 主機路徑起的執行器,pgid 寫進 `$BT/<run>/undo.pg`,讓 dm-fire 的 `kill_run_groups` 能先收掉它,再以 deadman 模式重入。`done` 標記只在該項的斷言通過後才寫。
3. `test-h4-undo.sh` 每一類都要有「主機 EXIT trap 執行器跑到一半時讓 lease 過期」這條。負對照是 v4 的寫法(子行程 renew),必須 FAIL。
4. §1.3 F-H8 與 §5.7「lease 契約的改寫」要寫明:dm-fire 的鎖由誰持有、執行器在 deadman 模式下不拿鎖、不 renew。

---

## 4. MINOR

- **m1 p6 `dv-undo` 的開機重放只由主機做**(§5.7、§11)。節點在臂中途重開、主機又不在時,持久項會一直留到主機回來:AC 的 `disable` provd(BLE 佈建通道沒了)、HT18 的 `auto_includes=0`、ST16 / UD16b 的 p5 stale(OTA 被擋)。這些都是 fail-closed 或只影響可用性,所以列 MINOR。修法二選一:
  - 在 §13 列出這幾項,並寫明「主機不在時不重放、方向是 fail-closed」;
  - 學 chain1 的 rc.local,在 p6 放一次性的開機重放。
  
  另外:持久項用的 `uci-restore <pkg> <file>`,`<file>` 必須放在 p6;`kill-pg` 這類項目只在同一次開機有效,journal 要帶 boot_id。
- **m2 S0-pre 的 `pk_proof` 排在認領之後**(§3.1 步驟 3 → 4)。chain1 是先證明 key 才認領(`chain1-254.sh:342` "not claiming")。照 v4 的順序,key 沒生效時,認領後 dropbear 只收 key(F-H37)→ 02 會被鎖在 ssh 外,只能經 BLE `ssh_keys/set` 或重燒。改成步驟 2 → pk_proof → 認領。
- **m3 `netobj.py` 的 net_secrets 加密對象**:§4.1 寫「加密給指定節點的 static key」。實際是節點的 ECDH 金鑰(`node_cert` key 4 / `identity/ecdh.key` 的公鑰;`provclient/net.go:197-205`)。照字面實作的話,join 會回 `E_BAD_OBJECT`。改字,並在 selftest 加一條「拿 `s_node` 加密 → 對向量 FAIL」。
- **m4 新卡的位址與身分**:重燒後 bootstrap IP 是 `10.41.254.<random>`,入網後 openmanetd 會再換一次,host key 也會重新產生(`99-halow-identity:22-28`)。§3.1 只寫「每一步都重讀 IP」,沒寫怎麼找。建議:
  - 沿用 chain1 的 MAC → ARP 掃描;
  - 每個 ssh 步驟都斷言 `identity/sn` 與 eth MAC;
  - 每台重燒後重新 pin host key。
  
  02 接上交換器之後,與 04 經 eth 和 mesh 兩條路同時相連。這要靠 batman 的 BLA,我在 04 唯讀確認是 enabled(`bridge_loop_avoidance enabled`,`stp_state=0`),寫進 F 表當作假設的證據。
- **m5 E-H13 前置的「invalidate B」沒有對應的 CLI**:`batman-slot` 沒有 `invalidate` / `disarm` 動詞(`:900-917`;P3 F64 也這麼寫)。`apply` 結尾會 arm tryboot(`:716-738`),所以從 apply 到 invalidate 之間任何一次重開都會進壞槽:會回到原槽,是安全的,但會擾亂 E-H13 的前置。要寫出具體做法,例如以不含 `root.squashfs` 的 payload 做 `stage-root` 觸發 `begin_write`(disarm + BAD),並斷言 tryboot GET = 0、`BATMAN-BAD` 存在。另外前置做完後 B 是 BAD,要寫明由 brewrite 收尾。
- **m6 §8.2 的四條逃脫負測試都分辨不出結果**(實測見 §0):`reboot -f`、`mount /dev/sd*`、寫 `/proc/sys/kernel/hostname`、`mknod`,以 yello 在沙箱**外**執行一樣會失敗,所以是 presence check,不是負測試。真正的資產是 yello 擁有的檔案:`~/.batman-dv/bench` 的金鑰庫,以及 `~/.ssh` 裡的 lab key(它能以 root 登入節點)。實測證明,宿主上 yello 的檔案在 userns 裡寫得進去;而 chroot 擋不住 userns 裡的 root(CAP_SYS_CHROOT)。修法:
  - 用 `pivot_root` + `umount -l` 舊根,取代 chroot;
  - 負測試改成「沙箱內寫宿主上 yello 擁有的 canary(放在 `$HOME` 下)→ 必須失敗」;
  - 負對照:同一條指令在沙箱外會成功。
  
  實際風險低:受測的是自家 uci-defaults,沒有人會刻意逃脫,所以列 MINOR。
- **m7 lo 臂(HT9、§7 步驟 5)的 tcpdump 介面**:本機連自己的 br-ahwlan IP 走 `lo`,`tcpdump -i br-ahwlan` 什麼都看不到,「沒有 SYN-ACK」就成了空斷言。lo 臂改用 `-i lo`(判定仍以 drop counter + S 對照為準)。
- **m8 `fresh-deadline`**:
  - 格式 `<run> <boot_id> <剩餘> <last_seen>` 沒有「延長次數」欄位,但 §4.4 的語意需要它。
  - 主機(續期)與 B 上的迴圈(扣時間)都對同一個檔做讀 → 改 → rename,迴圈可能用舊值蓋掉主機剛寫的續期 → 期限提早觸發。這是 fail-safe,但會讓 F 臂無故中止;而且一份資源有兩個寫者。建議主機寫另一個 `fresh-renew` 檔(只寫 run + 時間戳),迴圈是 `fresh-deadline` 的唯一寫者。
- **m9 交握額度**:全域 20 次 / 分(含 fake path)。RT1 的動詞 × 角色矩陣、OW3 / OW6 的重交握、認目標本身都會消耗。§4.1 要寫 peer 端對每個節點的交握限速(例如 ≤ 15 次 / 分),並把被限速擋下歸為 INVALID 而不是 FAIL。另外 Slots = 2 是 BLE 與 sock 共用;helper 的第 4 條連線不算在內,這點寫明。
- **m10 附錄 A 漏列 P3 §8 的三個片語**(`prov-update-254`):「上傳檔換成 FIFO」、「上傳後改 payload」、「回滾臂」;另外 HT8b 少了「poll 無 ERate」。UD7 的七種拒絕剛好是「簽章、serial、板子、降級、min_from、開機設定、版本解析」,UD8 是四包 tar,這三項都沒有對應的列。§6.3 的 lint 會抓到,但要現在補,免得實作時才改設計。
- **m11 接縫清單擴大,要明確交給 P3**。P3 §8 凍結的接縫表只有 10 個;H4 §5.1 / §5.4 新加約 25 個 Go fault 與 shell fault,其中 shell fault 會在**所有 image**(包括 release)裡,例如 `setkey-apply-fail`、`bulk-mount-fallback`、`slot-reboot-fail`。信任邊界我核對過是成立的:`batman_opf` 檢查 regular、非 symlink、root、link 1,而且 `protected_hardlinks=1`(`rundir.sh:44-52`;04 sysctl)。但 §1.4-2 只寫「名字」。要改成逐一列出完整清單,並註明 P3 第一個 commit 的程式碼審查與 `/security-review` 要涵蓋這批 release 程式路徑,這屬於凍結設計之外新增的產品程式。

---

## 5. 附錄 A 逐列核對摘要

- **§6 / §7 / §8 / D-1…D-17**:除了 m10,每個片語都對得到列。D 項的對照表我逐一核對過。
- **G 欄**:只出現在 UD12、UD16,符合 H4-U8。
- **「—」欄**:ST17(不變)、ST22(量測)、BG4,都附了理由。
- **「P」單獨出現的列**:HT15–HT17、HT22、UP5、UP6、UP8、UP11、UD9、UD10b、UD11 都有前提證據。HT15「helper 停 → 不聽」沒有 flip,沿用上一輪的接受。
- **W(E_U) 的判法**:§3.1 與 §6.1 一致;INVALID 只在 S0-pre 本身不成立時出現。
- **新 fault 名字與 P3 元件的對應**:`healthok-2field` → provd(HealthOK 在 `server.go:480-499`);`d12-take-mu` → helper(`n.mu`);`upload-nobusy` → helper(`otaBusy`,P3 `:190`);`bulk-mount-*` → provd init(P3 `:401`);`p5-autosave-off` → helper。都對得上 P3 的元件分工。
- **Go fault 檔放在 `/tmp/run/batman-prov-test/`**:與既有 seam 包的檢查(owner、mode、link 1,`seam_provtest.go`)以及 lease dead-man 的 `rm -rf`(`prov-lease-254.sh`)一致。

## 6. 安全(逐 actor)

| actor | 結論 |
|---|---|
| 遠端 / mesh 上任何人 | 沒有新的面;ethsim、`phy9h4` 只在 lease 期間存在,前提檢查是 fail-closed |
| 本機非 root 行程(節點) | shell fault 與 Go fault 的檔案檢查成立(§5 證據) |
| 被入侵的 provd | 拿不到 root 檔;H4 沒有給它新的寫入點 |
| 被入侵的手機 | Noise 是端到端,負向斷言有節點端佐證 |
| 被竄改的 BLE 橋 | **依 B1 改成 `node_cert` 認證後,才真的擋得住「把擁有者請求送到錯的節點」**;v4 的寫法因為認證永遠失敗而變成 INVALID,不是被擋 |
| 同一位 Windows / WSL 使用者 | 金鑰庫的誠實界線已寫(§3.2);EEPROM 沙箱見 m6 |
| 我們自己的錯 | M1(主機死時的還原)是主要缺口 |

## 7. 判決

**REJECT**(1 BLOCKER / 1 MAJOR / 11 MINOR)。

- **B1**:`s_node` 每次 provd 啟動都換、只在記憶體;member 不接受 NX;一條連線只能交握一次 → 改用 msg2 的 `node_cert`(DAC + device_id)在這一臂自己的交握裡認目標;fake path 的臂先認證再重連同一個位址。
- **M1**:dead-man 路徑上執行器的 renew 與拿鎖都會失敗 → 執行器要在 dm-fire 已持有的鎖下、同一行程內以 deadman 模式執行;主機路徑起的執行器要登記 pg。

**收斂狀態**:骨架已收斂。兩條都是局部機制,v5 只要改 §3.1 / §4.2 / §5.7 / F-H8,外加 MINOR 的文字修正。下一輪仍須審整份,但不需要重寫。
