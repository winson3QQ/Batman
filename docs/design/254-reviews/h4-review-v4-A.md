# H4 harness 設計 v4 — 審查 A(第 4 輪)

- 對象:`docs/design/254-h4-harness.md` v4(`harness/254-h4` @ 56dcf42),整份審。
- 上層對照:P3 `254-p3-impl.md` v7.1;h23 v14;`219-protocol.md` v0.7。
- 程式:`/home/yello/Batman` main 2ecf1cb。
- 節點:只做唯讀(04 = 10.41.1.3)。沒有改任何 repo 檔案,只寫這份報告。

**結論先講**:骨架確實收斂了,v3 的大部分意見真的處理掉了。但 v4 為了解 v3-B B1 新加的「以 Noise static key 認目標」建立在錯的前提上:static key 每次 provd 啟動都重新產生;member 節點對 NX 一律回假 msg2;同一條連線也不能重新交握。結果是 BLE 載具在 S0-pre / S0 上整個不能用,現場那一趟也建不起來。另外,undo 執行器與既有 lease 鎖的語意互相矛盾,dead-man 那條路跑不起來。**判決:REJECT(1 BLOCKER / 3 MAJOR / 13 MINOR)**。不需要重寫,改 §4.2、§3.1、§5.7 三節就可以。

**更正紀錄**:v4 的 §4.2 是照 v3-B B1 的修法寫的(「做 NX、把 static key 與庫裡記下的值比對;匿名可讀 `info` key 1 當第二層」)。那個修法本身就錯了(見 B1)。這不是作者自己發明的錯,但結果一樣要改。

---

## 0. 我取得的證據(原始輸出節錄)

```
# 219-protocol.md:515(§3.3 s_node)
| §3.3 `s_node` | 每次 **provd 啟動**(含 respawn)重新產生;app 不得快取 `s_node_pub`,每次交握重驗 |

# provd/noise.go:29-30
// GenerateStatic makes this provd start's s_node (219 §3.3: per start, memory only).
# provd/server.go:105-117  NewServer: st, err := GenerateStatic(rand.Reader)

# provd/server.go:673-702 handshakeParams
case "unclaimed", "legacy": return Prologue(s.c.deviceID), nil, cert, true     # NX,prologue 綁 device_id
...其他狀態: psks = owners(≤4)+member+replay,固定 6 把 → PSK 模式

# provd/noise.go:62-96 Respond
if psks == nil { if len(msg1) == Msg1NX {...} } else { ...只收 len(msg1)==Msg1PSK... }
if ok == nil { ... fakeMsg2 ...; hs.Fake = true }      # member 上的 NX msg1(32 B)→ 一律假 msg2(隨機位元組)

# provd/session.go:300-321 onMessage
if fake { return errors.New("message on the fake path") }
if !transport { return ss.onMsg1(m) }
pt, err := ss.recv.Decrypt(nil, nil, m) ... if err != nil { return errors.New("AEAD failure") }
# → 交握完成後,同一條連線上任何新的 msg1 都會被當成 transport 訊息解密 → AEAD failure → session 結束、斷線

# provd/server.go:35, 645-660
HandshakesMin = 20      # 全域 20 次 / 分(假路徑、失敗的也算)

# 219-protocol.md:292
psk_owner  = HKDF( owner_tag_key, "batman-psk-owner-v1" ‖ device_id )     # 每台不同
# 219:437 「已認領模式沒有綁定節點身分,成員機台可冒充別台 → 手機一律比對預期的目標 DAC」

# provd/server.go:291  node_cert = {1:[DAC], 2:s_node_pub, 3:boot_id, 4:ecdh_pub, 5:sig(static), 6:sig(ecdh), 7:sn}
# provd/server.go:529-537 info():member 以外的角色只拿基本欄位;但 member 上 NX 拿不到任何 session(假路徑)

# 04 唯讀
$ ls -l /etc/batman-prov/identity
-rw-------  backend  claim.secret(32)  ecdh.key  node.key  sha256  sn
-rw-r--r--  node.cert(385)                         # 磁碟上沒有任何 Noise static key
nftables v1.1.1;tcp_syn_retries 6;kernel 6.6.138;/etc/rc.local 只有 exit 0

# node.go:911-921 openSecrets / wtxn.go:125-150 decryptSecrets
target == SHA-256(n.KS.DACPub());  cose.Decrypt(enc, LabelSecrets, dacHash, net_id‖u32be(ver), n.KS.ECDH)
# → net_secrets 是加密給節點的 P-256 ecdh 金鑰(node_cert key 4),target = SHA-256(DAC pub);跟 Noise static 無關

# 219-protocol.cddl:205-212
network-join-req = { 1 => netcfg-sign1, 2 => members-sign1, 3 => secrets-sign1, ? 4 => invite-id, 31 => owner-op, ... }

# tests/vectors/219-protocol/gen.py:314-322 encrypt()
ctx = cb([24, ..., [target_hash, None, None], [256, rec_prot, NET_ID + u32be(NET_VERSION)]])   # 用模組全域 NET_ID / NET_VERSION
# gen.py 在模組層級產生全部向量(import 就會整個跑一次)

# scripts/node/ble-lib-254.sh
97-101  lock(): exec 9>>"$BT/lock"; flock -n 9 重試         # 每次都開新的 open file description
146     dm_arm: setsid sh "$3" dm-fire ... 9>&-             # dead-man 不繼承鎖 fd
306-310 cmd_arm(renew): lock 30 || die; lease_valid_for "$RUN_ID" || die "lease is not ours or expired"
327-341 cmd_dm_fire: sleep; lock(最多 10 分,拿不到就不拿鎖照做);只在 up_s >= expiry(lease 已過期)才動作
151-155 dm_arm 會 pg_kill 舊的 dead-man 群組(dm / dm.new 記錄的 pgid)
170     PROVD_KEYS='^(SOCK_ONLY|FAST_FAKE_DELAY_MS|NO_BRUTE_LIMIT|GATT_ENCRYPT_CTRL|ADV_LEN_TEST)='   # 沒有 BATMAN_FAULT

# Linux 6.6.138 fs/squashfs(/home/yello/firmware-2710 的 build tree)
squashfs_fs.h:240-251  s_magic, inodes, mkfs_time, block_size, fragments(各 4 B)、compression, block_log, flags, no_ids, s_major(各 2 B)→ s_major 在 offset 28 ✔
super.c:158-166  major < 4 → "older ... unsupported" return NULL;major > 4 → "trying to mount newer" return NULL   ✔ 0xFFFF 會被拒

# WSL 非 root namespace 探測(唯讀,沒有改任何東西)
6.6.114.1-microsoft-standard-WSL2;沒有 apparmor_restrict_unprivileged_userns;max_user_namespaces 43781
unshare --user --map-root-user --mount --pid --fork --net --uts --ipc:
  id -u → 0;hostname h4test → 成功(namespace 內);echo x > /proc/sys/kernel/hostname → Permission denied
  mknod c 1 3 → Operation not permitted;宿主 hostname 仍是 DSKT-Moonlight
binfmt qemu-aarch64: enabled, interpreter /usr/libexec/qemu-binfmt/aarch64-binfmt-P, flags: POF
```

---

## 1. v3 意見的處理(對附錄 C 逐條核對)

| v3 意見 | v4 處理 | 我的核對 |
|---|---|---|
| B-B1 member 認不出目標 | §4.2 static key 認證 | ❌ **沒有解,而且新機制不能用** → B1 |
| A-M1 / B-M2 S0-pre 的 02 與工具 | 02 接網路線、步驟表、`netobj.py`、預演 | ⚠️ 方向對。步驟 2 要讀的「static 公鑰」不存在(B1);`netobj.py` 的加密對象寫錯、庫缺欄位(M1) |
| A-M2 / B-M1 壞 rootfs | 保留 magic、改 `s_major` | ✅ 我在 6.6.138 原始碼確認 offset 28 與拒絕邏輯。殘留 m7(前置之後 B 沒有 brewrite) |
| A-M3 EEPROM 沙箱 | 非 root `unshare` + 逃脫負測試 | ✅ 方向對,我實測 WSL 可用。殘留 m4(兩條負測試鑑別力不夠) |
| A-M4 counter | named counter、目標 br-ahwlan IP、counter + tcpdump | ✅。殘留 m3(tcpdump 的介面) |
| B-M3 undo 契約 | 單一執行器、段 1 / 段 2、`done`、p6 | ⚠️ 結構對,但與既有 lease 鎖的語意矛盾 → M2;p6 那條路缺東西 → M3 |
| A-m1 … A-m17、B-m1 … B-m17 | 附錄 C 列的位置 | ✅ 逐條看過,文字都有落地。A-m6 / B-m11(重開迴圈)只解了一半 → m2 |

---

## 2. BLOCKER

### B1. §4.2「以 Noise static key 認目標」不能用:key 每次 provd 啟動就換;member 上的 NX 只拿得到假 msg2;同一條連線不能重新交握

**情境**
- §3.1 步驟 2:用 ssh 讀 static 公鑰寫進庫。§4.2 第 3 步:做 NX 的前兩則拿到 static key,與庫比對,然後「同一條連線再從頭做這一臂要用的交握」。§4.2 的負對照:把庫裡 04 的 static key 換成 02 的。

**證據(§0)**
1. `s_node` 是**每次 provd 啟動**在記憶體裡產生的(`noise.go:29`、`server.go:113`、219 §3.3 `:515`,而且規格明文說 app **不得**快取 `s_node_pub`)。節點磁碟上沒有這把 key(04 唯讀 `ls`)。所以步驟 2 讀不到,庫裡也記不住。H4 自己就會讓它不斷改變:`set-fault provd`、`push-provd`、`unbind-all`、dead-man、HT16 系列、每次重開都會重啟 provd。
2. member / claimed 節點只走 PSK 模式;32 B 的 NX msg1 一律得到**假 msg2**(`noise.go:62-96`)。S0-pre / S0 的兩台都是 member,所以第 3 步在兩台上都拿不到 static key → 每個候選都「不符」→ **所有 BLE 臂 INVALID**,S0-pre 最後的 `s0_assert` 也過不了。這正是 v3-B B1 描述的後果。
3. 就算拿到了,也沒辦法在同一條連線上「再從頭交握」:交握完成後,下一則 msg1 會被當成 transport 訊息解密 → `AEAD failure` → session 結束、斷線(`session.go:300-321`);假路徑上任何訊息也會直接結束(`:305-306`)。只能重連。而重連那條連線**沒有被認證過**,中間的橋(Windows 端)可以把它接到別台。這樣 §12「被竄改的橋沒辦法讓 peer 把請求送到錯的節點」就不成立了。
4. v3-B 建議的第二層「匿名可讀的 `info` key 1」在 member 上也拿不到(NX → 假路徑)。
5. 每次認目標要多一次交握,而全域限速是 20 次 / 分,假路徑也算(`server.go:35, 645-660`)。

**修法**(協定本來就有綁定身分的機制,改成**在這一臂自己的交握裡認證**,不另做一次預先交握):
- 庫裡每台記:`device_id`(`sn` 的 hex)、**DAC 憑證或 DAC 公鑰**(`/etc/batman-prov/identity/node.cert` 是 0644 公開檔,步驟 2 經 ssh 讀;或者在認領時從 msg2 TOFU)、`ecdh_pub`(取自 node_cert key 4,M1 會用到)。拿掉「static 公鑰」這一欄。
- 每一臂的交握完成時,在送出**第一個請求之前**,peer 核心做這幾件事:
  1. 解出 msg2 payload 的 `node_cert`;
  2. 比對 `dac_chain[0]` = 庫裡釘選的 DAC;
  3. `sn` = 目標的 `device_id`;
  4. `sig_static` 以 DAC 驗過,而且 node_cert 的 key 2 = Noise 狀態裡實際的 `rs`;
  5. 不符 → 不送任何請求、`CLOSE`、換下一個位址。
- 各角色本來就有的綁定:
  - unclaimed / legacy:prologue 帶 `device_id` → 只有目標答得出真的 msg2;
  - 擁有者:`psk_owner` 依 `device_id` 推導 → 只有目標打得開;
  - `psk_member` 是全網共用(219 的誠實界線)→ **只能靠 node_cert 的比對來分辨**。所以上面第 2–4 步一律要做,不能只靠 PSK。
- 「預期拿到假 msg2」的負向臂(例如 member 上的 NX、被移除的 psk):這些臂不送請求,無法在客戶端認目標。判定改成只在節點端做(provd log 的交握 / fake 行、04 的時間戳),並在副作用裡寫明可能短暫連到 02。
- 負對照改成:把庫裡「04」的 DAC 換成 02 的 → 對 04 交握成功,但 peer 必須拒絕送出、記一行、INVALID;再加一條:用 `psk_member` 連到 02 時,必須因為 `sn` 不符而放掉。selftest 用 `vectors.json` 的 `identity_file` 與 `noise_nxpsk0_*` 向量,另外做一組 sn 不同的變體。
- peer 依全域限速排程,並在 provd log 斷言沒有 `global handshake rate` 這一行(m1)。
- §1.3 補三條事實:s_node 每次啟動都換(`noise.go:29`、219 `:515`);member 上的 NX 只拿得到假 msg2(`noise.go:62-96`);交握完成後不能重新交握(`session.go:300-321`)。§3.1 步驟 2、§3.2、§12、§10「blebridge」那一列跟著改。
- 預演(§15-4)時,認目標要在 F 載具上以 **member 狀態 + 一次 provd 重啟之後**各做一次。

---

## 3. MAJOR

### M1. `netobj.py` 的規格錯了:net_secrets 不是加密給 static key;庫裡缺必要欄位;gen.py 不能直接拿來用;join 的 body 少了必填欄位

**情境**:S0-pre 步驟 5,以及 §4.1「net_secrets(加密給指定節點的 static key)」。

**證據**
- `decryptSecrets`(`wtxn.go:125-150`):要求 target = SHA-256(DAC pub),以節點的 **P-256 ECDH 金鑰**(node_cert key 4 = `ecdh_pub`)解密;KDF context 綁 `net_id ‖ u32be(version)`。正確的做法就是既有的 `provclient/net.go:197-205`(`nodeKeys()` 取 `ecdh_pub` 與 DAC hash)。
- `gen.py:314-322` 的 `encrypt()` 用模組全域的 `NET_ID` / `NET_VERSION`(參數改不到),而且 gen.py 在 import 時就會產生全部向量。照 §1.2「沿用 `gen.py` 的 `sign1` / `encrypt`」,不是用錯 net_id 加密,就是得改 gen.py(改 gen.py 又會碰到向量的 SoT)。
- CDDL `network-join-req`(`219-protocol.cddl:205-212`)必填 key 2 `members-sign1` 與 key 31 owner-op。P2 節點目前不讀 key 2(`node.go:1003-1017`),但 P3 或 CDDL lint 會讀;owner-op 要用同一個 session 的 `op/nonce` 與 `h`。
- N0 是「US、ch 40」;gen.py 的 net_config key 5 是 `"TW"`。P3 的 CJ1 / CJ2 會檢查國家,所以 net_config 的國家必須跟 bench 一致。

**後果**:現場的 S0-pre 第 5 步 join 會回 `E_BAD_OBJECT "net_secrets"`。預演應該會先抓到,但規格本身是錯的,庫的 schema(§3.1「每台記在庫裡的身分」)也少了 `ecdh_pub` 與 DAC。

**修法**
- §4.1 / §1.2:net_secrets = Sign1_admin({1: net_id, 2: ver, 3: SHA-256(DAC pub), 4: COSE_Encrypt(ECDH-ES → node_cert.ecdh_pub, ctx 綁 net_id‖ver)})。
- `netobj.py` 自己帶參數化的 `sign1` / `encrypt`(net_id、version 由參數給),selftest 以 gen.py 的固定值逐位元組比對 `vectors.json` 的 `cose.net_config` / `net_secrets`。不 import gen.py、不改 gen.py。
- 產出完整的 join body:key 1、2(members:至少一筆,本機的 DAC hash 與 ecdh)、3、31(owner-op,verb = `network/join`)。
- net_config 的 key 5 = 庫裡的國家(US),key 6 = {1: mesh_id, 2: 40, 3: 4};admins = [H0 pub]。
- §3.1 的庫欄位補上 `ecdh_pub`、DAC(見 B1)。ecdh_pub 只從**已認證過的** node_cert 取(B1),不經 ssh 讀 `ecdh.key`。
- 再加一條 selftest:對 02 的 net_secrets 用 04 的 DAC → `decryptSecrets` 等價的 Python 參考實作要拒絕。

### M2. 單一 undo 執行器與 lease 鎖 / dead-man 的語意互相矛盾:dead-man 那條路跑不起來,也擋不住兩個執行器同時跑

**情境**:§5.7「EXIT trap 與 dead-man 都只呼叫 `prov-undo-254.sh run <run>`;以 `setsid` 執行;先 `renew` lease 20 分鐘;全程持有 lease 鎖;重入時跳過已標 `done` 的項目」。

**證據**(`ble-lib-254.sh`,§0)
1. dead-man 只在 lease **已過期**時才動作(`:333-334`);`renew` = `cmd_arm`,要求 `lease_valid_for`,也就是沒過期(`:308`)。所以 dead-man 呼叫的執行器第一步 `renew` 一定 `die "lease is not ours or expired"`。
2. `dm-fire` 自己已經拿著鎖(`:330`)。`lock()` 每次都 `exec 9>>` 開一個新的 open file description(`:98`),而 flock 是以 open file description 為單位。所以 `setsid` 起來的執行器拿不到鎖,30 s 後 `die "BLE lock busy"`。dead-man 在最需要的時候(主機死了)什麼都還原不了。
3. 如果改成讓 `renew` 在 dead-man 裡成功,`dm_arm` 會 `pg_kill` 舊的 dead-man 群組(`:151-155`),也就是**正在呼叫它的那個 `dm-fire` 自己**。
4. 主機 EXIT trap 這條路:執行器 renew 20 分鐘,等於武裝了一個新的 dead-man。執行器若超過 20 分鐘(ap-restore 180 s、`p5-save`、`fw-start`、`svc-start` 加起來可能超過),新的 dead-man 等鎖 10 分鐘後會**不拿鎖照做**(`:331`),於是兩個執行器同時跑段 2。「跳過 `done` 的項目」擋不住兩邊同時執行**同一個還沒標 `done`** 的項目。
5. §5.7 沒寫執行器插在既有 `role_fire_restore`(`prov-lease-254.sh:32-65`)的哪一步。現在的 `role_fire_restore` 自己也做 unbind-all、helper 換回、provd 重啟、服務啟動,與段 1 重疊。

**修法**(契約寫清楚,不加新機制):
- 執行器兩種進入方式:
  - `run --from-deadman`:在 `dm-fire` 的 shell 裡**以 source 執行**,繼承它已經拿著的鎖;不 renew、不 `dm_arm`。`role_fire_restore` 的順序改成:`stop_judges` → 執行器段 1(取代現在的 unbind-all、helper 換回)→ `restoring` 檢查 → 段 2 → `provd_start` 與服務。
  - `run --from-host`:取鎖、`lease_valid_for`、renew 一個足夠的預算,結束時 `release`。
- 執行器在 `$BT/<run>/undo.pg` 登記自己的 pgid。dead-man 的「拿不到鎖照做」那條路,遇到這個 pgid 還活著 → 只記 log、不執行段 2(否則就是兩個寫者)。
- 每一項執行前先原子寫 `doing`,完成後寫 `done`。重入遇到 `doing` → 依該動作的冪等性重做(§5.7 已經要求冪等)。
- `test-h4-undo.sh` 加三臂:dead-man 路徑真的還原(negative control:用現在 v4 的寫法 → 會 FAIL 在 renew / lock);主機路徑超過 lease → 不會出現兩個執行器;執行器跑到一半被 kill → 重入完成。

### M3. p6 的持久 undo(撐過重開)缺三件事:備份檔不在 p6、沒有綁定槽與開機、沒寫是誰在哪個 lease 底下執行

**情境**:§5.7「會撐過重開的動作先在 p6 `dv-undo.<run>` 登記才改;開機後 P9 與下一個 run 的 preflight 依它執行段 2」;§11 宣稱「臂進行中 sysrq → 重開後殘留項被列出並還原」。

**問題**
1. `uci-restore <pkg> <file>` 的 `<file>` 沒說放哪裡。如果放在 `/tmp/run/batman-dv`(其他東西都放那裡),重開後就不見了,段 2 還原不了 → FAIL + NEVER_KNOWN。§11 宣稱的那條路就失敗了。
2. 一般的 lease 單位(RB)會跟 T 的換槽交錯:UD3 的 S 會真的進另一槽(§13),而 overlay 每槽一份(F-H25)。p6 的登記項沒記槽與 boot_id;下一個 preflight 若在另一槽上執行 `uci-restore`,會把 A 的快照寫進 B 的 overlay。
3. 誰執行:P9 是 preflight,本身不持有 lease。§9 的規則是「節點狀態只有持有 lease 的單位能寫」。所以 P9 / preflight 要先取 lease 才能跑段 2,否則就是第二個寫者。這也要寫出在主機回來之前,節點停在什麼狀態:例如 HT18 的 `auto_includes = 0` 已經 commit,04 的 HTTP 備援就一直關著。其他 harness(h23 的 BLE 單位)在那之前會不會被擋下?

**修法**
- 持久項的備份檔一律放 `/opt/batdata/state/dv-undo.<run>.d/`(root 0700,檔 0600),與登記檔同一次 `sync`。
- 每一行帶 `<slot> <boot_id 前 8 碼>`。執行時槽不符 → 不動、印出、FAIL(交給人)。
- 段 2 的持久部分由 `prov-p3-254.sh preflight` 在**取得 lease 之後**執行。h23 的 P9 只負責偵測:看到 `dv-undo.*` 就 FAIL,擋住其他單位。
- §11 的 sysrq 測法分成兩臂:(a) 有持久項;(b) 臂進行中切到 T。各自要有 negative control:備份檔放 tmpfs → FAIL。

---

## 4. MINOR

1. **全域交握限速 20 / 分**(`server.go:35, 645-660`,假路徑也算):RT1 matrix、OW3「重新交握被拒」、SD 系列、認目標都會累加。peer 依 `HandshakesMin` 排程;每個單位結束時在 provd log 斷言沒有 `global handshake rate`。出現 → 該臂 INVALID,不准算 FAIL / PASS。
2. **`fresh-deadline` 有兩個寫者**(§9 自己就寫了):迴圈做「讀 → 扣 → rename」,主機的續期可能剛好夾在中間而被蓋掉(lost update)。違反「一個資源一個寫者」。修法:拆成兩個檔,主機寫 `fresh-grant`(run + 預算序號),迴圈只寫 `fresh-spent`(run + 已用秒數)。**快速重開迴圈**:每次開機都不扣重開期間,迴圈 60 s 才扣一次;開機後不到第一次 tick 就重開的迴圈,預算永遠不會減。「一定會耗盡」這句不成立。修法:迴圈一啟動就先扣「本次 uptime + 固定的每次開機成本(例如 120 s)」;或加開機次數上限。§4.4 的 sysrq 回歸測試要包含「每次開機 < 60 s 就重開」。
3. **tcpdump 的介面**:§4.5 / §7 的判定寫死 `tcpdump -i br-ahwlan`。lo 臂的 SYN 在 `lo`;docker0 臂在 docker0 / 第二組 veth;SYN-ACK 也不會出現在 br-ahwlan 上。這樣「沒有 SYN-ACK」是空洞的。每臂要在**入口介面**擷取,並且要求「看到 SYN ≥ 送出數 × 0.9」,看不到 → INVALID。另外,named counter 若因 fw reload 歸零(增量 < 0),也要 INVALID。
4. **沙箱逃脫負測試的鑑別力**(我實測,§0):
   - 在 `--uts` 的 userns 裡,`sethostname` 會成功(只在 namespace 內);`/proc/sys/kernel/hostname` 的寫入失敗是因為 /proc/sys 屬於 init userns,不是因為隔離。應該改成「沙箱內 `hostname x` 之後,宿主的 hostname 不變」。
   - `mount /dev/sd*`:chroot 裡如果沒有裝置節點,失敗是空洞的。要先斷言裝置節點存在,或是在 chroot 之前、namespace 之內試。
   - `reboot -f` 在子 pid ns 裡只會結束那個 namespace(這是正確的負測試),但要斷言沙箱的 init 真的被結束,才知道 syscall 有到。
5. **`claim.secret` 跨 ssh(Git Bash)→ WSL 的管道**:32 B 二進位可能含 `\r` / `\n`,repo 的慣例是到處 `tr -d '\r'`。改成在節點上 `hexdump -v -e '1/1 "%02x"'` 輸出,peer 從 stdin 讀 hex。仍然不落地、不進 argv。
6. **`ap-restore` 的 C0 從哪來**:dead-man 與重開之後的那條路都需要 C0 已經在節點上,而 §9 說 `/tmp/run/batman-dv/c0` 用完就刪。寫明:key 20 臂開始時 stage 到 tmpfs(root 0600,登記 `rm-file`);重開之後的那條路由主機從庫重送 key 20(journal),節點端不存 C0。
7. **E-H13 的前置**(§8.1):做完 `invalidate B` 之後,B 還是壞 rootfs。之後要等到 §15-4 的 F 流程才會重寫 B,中間若有任何 rollback 就是 v3-B M1 說的 panic 迴圈。前置的最後也要 brewrite B 並斷言,與現場 E-H13 一樣。
8. **`provd_check` 看不到 `BATMAN_FAULT`**:`ble-lib-254.sh:170` 的 `PROVD_KEYS` 沒有它。dead-man 與 `unbind-all` 之後的「provd 沒有測試開關」斷言因此是空洞的。H4 要把 `BATMAN_FAULT` 加進去(harness PR 內)。
9. **§13 少了降級 / 升級類**:UD11(sysupgrade 到 wsl.22)、UD12 / UD12b(先降級到 wsl.22,再升級)會改變整個 bench 的 image。還原(sysupgrade 回 V、`upgrade` / `s0_assert` S0 版)與成本都要列。
10. **OW4「快照還原」**:在 R 載具上,還原 p5 快照等於 lease 底下寫 p5、要重開(屬於 pr_restore),這與 §5.7 的 lease 契約衝突。改成:H0 以 `owner/add` 重新加入 H0b(journal 記新的 tag key),之後 `s0_assert` S0 版。
11. **p6 undo journal 的參數驗證**:root 會照 p6 檔的內容執行。§10 只說動作是封閉清單,參數沒有限制。`rm-file` 要限定在允許的路徑前綴(`/tmp/run/batman-dv/`、dev-open 旗標的固定路徑),並拒絕 `..` 與 symlink;`<pkg>` 限 `[a-z_]+`;`<dev>` 限 `h4*|phy9h4|q0*`。不符 → CRIT、跳過、FAIL。
12. **ST9 的 S 變體**(「bind 一個走 `uci set` 的 setkey 變體」)不在 §5.5 / bind 封閉清單裡。要命名並加入清單。
13. **§1.3 的事實**:補上 B1 的三條(s_node 每次啟動、member 上的 NX 是假路徑、不能重新交握),以及 M1 的「net_secrets 的 target = DAC hash、加密給 ecdh_pub」。F-H3 寫的是 legacy 狀態下的結果,要註明不代表 member 狀態。

---

## 5. 附錄 A 逐列抽查(W / S / P / G)

- **W**:RT1、OW*、ST*、SD*、UD*、CJ* 的 W 行,在 `--pre-p3-full` 的規則下都產生得出來(F-H23:`owner/*`、`settings/*`、`status` 等在 `p3Types` 裡)。CJ1 / CJ2 的 W 手法沿用 v3-B 的實查。
- **S**:新增的接縫名字(`setkey-no-reblock`、`setkey-rc-legacy`、`no-boot-disarm`、`bulk-mount-fallback`、`stable-any-471`、`crash-on-start`、`helper-arm-crash`、`d7-ssid-rc6`)都在 §5.1 / §5.4 的表上,也都經 §1.4-2 回報給 P3。HT16c 依 F-H40(respawn 無限重試)也合理。ST9 的變體缺名字(m12)。
- **P**:HT15 / 16 / 16b / 16c / 17 / 22、UP5 / 6 / 8 / 11、UD9 / 10b 只有 P。它們都是「臂內的前後對比」(先 LISTEN → 後不聽、先存在 → 後消失),判定本身可以 FAIL。不過 HT 那幾列的「不聽」都依賴 m3 的擷取介面要寫對。
- **G**:只剩 UD12、UD16(H4-U8),符合使用者決策。
- **BLE 依賴**:附錄 A 裡所有經 BLE 的列(RT1、RT4、RT5、OW*、ST*、SD*、UD*)在 B1 修好之前,在 S0-pre / S0 上都會 INVALID。

---

## 6. 安全(逐個 actor)

| actor | 結論 |
|---|---|
| 被竄改的 Windows 橋 / bleak | 照 v4 的寫法,只有預先交握那條連線被認證過;重連之後的那條連線,橋可以接到 02 → §12 的宣稱不成立(B1)。改成在臂自己的交握裡認證之後才成立 |
| 本機非 root 行程(節點) | shell fault 只認 root 擁有的檔(`protected_symlinks=1` 也確認了);p6 journal 是 root 0600,但參數沒有驗證(m11) |
| 被入侵的手機 | 負向斷言都有節點端佐證;正向可以被假造(誠實界線,已寫) |
| 同一個 Windows 使用者 | 可以經 `\\wsl.localhost` 讀到庫(已寫明界線;全是測試值) |
| 沙箱裡的 rootfs 腳本 | 非 root userns + `--net`;我實測 mknod 被拒、宿主 hostname 不變。負測試的鑑別力見 m4 |
| 我們自己的錯 | M2(兩個執行器同時跑)、M3(在錯的槽上還原)屬於這一類 |

**秘密**:`claim.secret` 不落地(m5 改成 hex);setkey `--ap` 的值在 argv 只限 P2,已寫明。

---

## 7. 判決

**REJECT — 1 BLOCKER / 3 MAJOR / 13 MINOR。**

- **B1**:§4.2 的 static key 認目標不能用(key 每次 provd 啟動就換;member 上的 NX 只拿到假 msg2;不能重新交握)→ 改成在這一臂自己的交握裡驗 node_cert(DAC 釘選 + sn + sig_static)。
- **M1**:`netobj.py`:net_secrets 要加密給 node_cert 的 `ecdh_pub`,target = DAC hash;庫要記 DAC / ecdh_pub;不能直接拿 gen.py 的全域值;join body 要有 key 2 與 owner-op;國家要用 US。
- **M2**:undo 執行器與 lease 鎖 / dead-man 矛盾:dead-man 那條路會 renew 失敗或拿不到鎖;可能出現兩個執行器同時跑 → 分成 `--from-deadman`(source、繼承鎖)與 `--from-host` 兩種進入方式,加 pgid 與 `doing` 標記。
- **M3**:p6 持久 undo 的備份檔要放 p6;登記項要綁槽與 boot_id;由取得 lease 的 preflight 執行。

**收斂了嗎**:骨架(載具、S0-pre / S0、接縫契約、對表、分段驗證)已經收斂,v3 大部分意見也真的處理掉了。這一輪的問題都在 v4 新加的三個地方:§4.2、§5.7 的鎖、`netobj.py`。三個修法都是局部的,不需要重寫。建議修完之後再做一輪全份審查;那一輪的重點放在 §4.2 的新流程,要對照 `noise.go` / `session.go` 實跑 selftest(用向量的 `identity_file` 與 `noise_nxpsk0_*`)。
