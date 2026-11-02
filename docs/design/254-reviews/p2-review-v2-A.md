# #254 PR-P2 `batman-provd` 設計 v2 — 對抗式審查 A(第 2 輪,整份重審)

審查者 A,2026-10-31。對象:`scratchpad/254-p2-impl.md` v2 全文 §0–§13。方法:從現場(認領、10 台一隊、路人、被攻陷的 provd、root 操作員)出發,逐條對原始碼核;v1 兩份報告只當線索,§13 對應表不採信、逐項重驗。

**環境誠實界線**:04(10.41.1.3)兩次 ssh 都 `Connection timed out` → 本輪**沒有任何 04 實機輸出**;凡標 F-P* 的實機事實沿用 v1 兩位審查員自己核過的輸出,我核的是原始碼(repo main `34f216d`、firmware `/home/yello/firmware-2710` 的 kernel 6.6.138 / BlueZ 5.72 / procd 2026.03.14 / dbus 1.14.10 build 樹)。

## 0. 我自己驗過的事(✅ 原始碼;⚠️ 推論;❌ 沒驗到)

| # | 事實 | 證據 |
|---|---|---|
| V1 ✅ | helper socket 伺服器**一次只服務一條連線**:`Serve` 在 `for { AcceptUnix(); s.serveConn(c,h) }` 裡同步呼叫,`serveConn` 的迴圈是 `Read → h(m) → Write` **同步**;處理中不讀下一個封包 | `sock/sock.go:107-116, 144-170`(`out, err := cbor.Encode(h(m))`) |
| V2 ✅ | `Handle` 進門就 `n.mu.Lock()`;`dispatch` 對**每個**動詞先 `LoadOverlay`,無紀錄只放行 `info.cert / info.ecdh_pub / info.boot_id / nonce` | `node/node.go:157-159, 204-209` |
| V3 ✅ | `info.state` 今天回 `{1: state, 2: Generation, 3: len(owners), 4: RadioManaged}` — **已有 generation**;每個改 record 的路徑都 `Generation+1` | `node.go:235, 548, 831, 877, 904, 1134, 1192` |
| V4 ✅ | `LoadOverlay` 讀**兩個檔**(`prov.meta` 再 `prov.cbor`),以 meta 的 sha / state / gen 對 record;`WriteOverlay` 先 rename record 再 rename meta → 無鎖讀者可見「新 record + 舊 meta」→ 回 error → `rec == nil` → `dispatch` 對 `info.state` 回 `EUnsupported("no usable provisioning record")` | `provstore/provstore.go:349-377, 391-407, 409-435` |
| V5 ✅ | `realSys.IsTrial()` = **fork/exec `batman-slot is-trial`**(每次呼叫) | `cmd/batman-provhelper/main.go:138` |
| V6 ✅ | `health.ReadInfo` 每次呼叫**開新的 mgmt socket**(AF_BLUETOOTH RAW、HCI_CHANNEL_CONTROL、index 0、2 s 逾時、最多讀 8 個事件後關)→ 並行呼叫彼此獨立、無共用狀態;`Tick` 另寫檔 + `ble-ok` | `health/health.go:55-87, 129-159` |
| V7 ✅ | kernel 有 `MGMT_OP_READ_ADV_FEATURES = 0x003D`;`read_adv_features` 回 `supported_flags(4) max_adv_data_len(1) max_scan_rsp_len(1) max_instances(1) num_instances(1) instance[]`;`num_instances = hdev->adv_instance_cnt` 再扣掉 instance 號 > `le_num_of_adv_sets` 的隱藏者;只拿 `hci_dev_lock`;`lmp_le_capable` 不成立回 REJECTED | `include/net/bluetooth/mgmt.h:543-552`;`net/bluetooth/mgmt.c:8436-8488, 9349` |
| V8 ✅ | **唯讀 bind 的 unix socket 可 connect**:`unix_find_bsd` 做 `path_permission(&path, MAY_WRITE)` → `inode_permission` → `sb_permission` 只看 **superblock** `sb_rdonly`(tmpfs 是 rw),`MNT_READONLY` 不在這條路徑(只在 `mnt_want_write`);之後是 mode bits → dbus socket `0777`(F-P4)、`helper.sock` 0660 root:provd(F-P6)都放行。設計 §3 / §6 的這個 ⚠️ 可升 ✅(原始碼) | `net/unix/af_unix.c:1105-1130`;`fs/namei.c:480-490` |
| V9 ✅ | dbus init 只 `mkdir -m 0755 -p /var/run/dbus`(不刪不重建)→ 目錄 inode 跨 dbus 重啟不變;dbus-daemon 重啟 unlink+bind socket(F-P18)→ **目錄 bind 看得到新 socket** | `feeds/packages/utils/dbus/files/dbus.init:16` |
| V10 ✅ | helper `PrepareDir` 只刪**自己的 socket 檔**,不碰目錄;`Listen` `SetUnlinkOnClose(true)` → helper 重啟後新 socket 在同一目錄 inode → 目錄 bind 成立 | `sock/sock.go:36-77, 80-89` |
| V11 ✅ | procd:`requirejail` → `in->require_jail`;ujail 缺 + `require_jail` → `ERROR("Cannot jail service…") return false`(不啟動);無 `requirejail` → `has_jail=false` 靜默照跑;ujail `-E` = `opts.require_jail`;`-r` = `add_mount_bind(optarg, 1 /*ro*/)`;jail root 是 tmpfs `/tmp/ujail-XXXXXX`,**沒有自動建 `/var` symlink** | `procd-2026.03.14/service/instance.c:142, 1458-1470`;`jail/jail.c:678, 2662, 2726-2728, 830` |
| V12 ✅ | `claim.verify` 收 5 欄 `{1:h 32, 2:response 32, 3:owner_pub 65, 4:owner_enc_pub 65, 5:sig_enc 64}`;CDDL `claim-finish-req = {1: response, 2: owner_enc_pub, 3: sig_enc, * uint => any}` → 設計 §4.3 的拆法正確(多餘 key 要忽略) | `node.go:501-520`;`219-protocol.cddl:170-175` |
| V13 ✅ | nonce:`newNonce` 回 `{1: node, 2: helper}`、同 h ≤ 4 對、60 s;`takeNodeNonce` 取最新未用 node 半;`takeHelperNonce` 以值查、**刪 entry**;`verifyOwnerOp` 對 h 的每一對**依 map 順序逐一 `takeHelperNonce`**(每試一對就刪一對);`claimReplay` 先 `takeNodeNonce` 再 `verifyOwnerOp`(註解明寫「verifyOwnerOp consumes every nonce entry it tries」) | `node.go:270-332, 686-703, 612-619` |
| V14 ✅ | 錯誤碼只有 `3 4 5 6 7 10 12 20 21 22 23`;`claim.verify` 的 3 來自四處(state 不可認領 / 無 nonce / CheckMac / sig_enc),`EUnsupported("no-ssh-key")` 在 CheckMac 之後;`netJoin/netUpdate` 回 4 / 5;`net.apply`+`network/update` 走 `netUpdate` 無 owner-op | `node.go:33-48, 526-543, 731-733, 1012-1095` |
| V15 ✅ | owner-op 的 `args_hash` 由 helper 對**解碼後的 body**(去 key 31)重新編碼算 → provd 重編整封不影響簽章;`decodeEnvelope` 只要 key 2 字串、key 3 map,忽略其餘 | `proto/proto.go:81-87`;`node.go:636-660` |
| V16 ✅ | fresh 節點:`boot.Run` 在 helper 服務前 `WriteOverlay(Unclaimed, gen 1)` → L1 「record 由 --boot 產生在服務前」成立 | `boot/boot.go:179-211`;`main.go:585-623` 順序 |
| V17 ✅ | `device_id` = hex(cert SN)= `info.cert.2` → provd 可得 | `keystore/keystore.go:46`;`node.go:218` |
| V18 ✅ | `sign()` 額度:全域每秒 ≥ 2 次才拒(第 3 次) → provd 啟動連簽 2 次**不需要**隔 2.1 s | `node.go:333-346` |
| V19 ✅ | firmware `bluetooth.conf` root policy:`send_interface` Agent1 / GattCharacteristic1 / GattDescriptor1 / LEAdvertisement1 / ObjectManager / Properties **無 destination 限制** → bluetoothd 對 provd 的回呼(ReadValue / Acquire* / Release / GetManagedObjects / GetAll)今天就放行(F-P18 成立);沒有 default policy | `package/batman/batman-ble/files/bluetooth.conf` |
| V20 ✅ | BlueZ `parse_discoverable`:`Discoverable=true` → BlueZ 自己加 Flags(0x02 GENERAL)進 `client->data`;kernel `eir_create_adv_data` 看到 instance 已有 EIR_FLAGS 就 `skip_flags`;`!HCI_BREDR_ENABLED` 時無條件 `LE_AD_NO_BREDR` → 3 B(F-P10 成立) | `advertising.c:747-778`;`eir.c:245-296` |
| V21 ✅ | h23 既有單位用 `provclient` 直連 helper socket:`prov-sock-254` `sock-as 471 -- info`;L11 判定 `provclient info.state` 成功 | `254-h23-harness.md:256, 804` |
| V22 ❌ | 04 任何現況(policy 檔、`/var` symlink、health 行、`bluetoothctl show`)— 連不上 | ssh timeout ×2 |
| V23 ⚠️ | 假 msg2 = 711、F-P20 autocommit 只 WARN、F-P17 RPA 900 s:沿用 v1 兩位核過的,本輪未重算 | v1 A/B 報告 |

## 1. BLOCKER

**B1. v2 對 B-M2 / A-M5(helper 忙時 STATUS / 撤廣播 / 第二連線全卡)的修法在 socket 層到不了:helper 是「一次一條連線、連線內同步 Read→Handle→Write」,`Handle` 不取 `n.mu` 根本沒機會被呼叫。**
- 情境(現場 10 台):擁有者手機 A 送 `network/join`,provd 經**唯一的常駐連線**送 `net.apply`;helper `serveConn` 進 `h(m)` 跑 ≤ 180 s(+ save)。provd 每 5 s 的 `health.get` / `info.state` 寫進同一條 SEQPACKET → **helper 在 `h(m)` 回來前不會 `Read` 下一個封包**(V1)→ 不管 `health.get` 取不取 mutex,它排在 net.apply 後面。結果:root 操作員此時開互動 bluetoothctl(bondable=1)→ 撤廣播要等 net.apply 完(可達 3 分),§4.4 的「最壞 ≈ 5 s」不成立;STATUS 快取 60 s 後過期 → 隊友 B 讀 STATUS 得 ATT 0x0E;L71 寫的「health 輪詢不受影響」錯。開機 L70 同理:provd 啟動第一批請求含 `sign.static`(取鎖、排在 `BootFinish` ≤ 120 s 後),它後面的 `health.get` / `info.state` 全部跟著等 → 「STATUS 可讀、廣播前置照常」不成立(廣播反而要等 node_cert,設計自己也寫了,但 STATUS 一句是錯的)。
- 證據:`sock.go:107-116`(`Serve` 同步 `serveConn`)、`sock.go:144-170`(迴圈同步);設計 §3 helper `n.mu` 列、§4.3 連線模型「一條常駐連線、FIFO 佇列」、§4.3 快取「都不取 mutex,helper 忙時也回」、§4.4 撤銷「最壞 ≈ 5 s」、L70 / L71、§13 B-M2/A-M5「已修」。
- 為什麼是 BLOCKER:v1 兩位的 MAJOR 被標成已修,但修法建立在一個不存在的並行模型上;§3(擁有權「helper 的 n.mu」列)、§4.3、§4.4、L70、L71、§13 都要重寫,屬設計層而非改字。
- 修(二擇一,寫明選哪個並把 helper 改動加進 §2):
  (a) **helper `Serve` 改 `go s.serveConn(c, h)`**(並行連線;`n.mu` 本來就序列化改狀態動詞;PeerUID 檢查不變;加連線數上限如 4,超過即關,免被攻陷 provd 耗 fd)+ **provd 開兩條連線**:`ctl`(`health.get`、`info.state`、`info.boot_id` keepalive)與 `ops`(其餘);或
  (b) 單連線但 helper 對 lock-free 動詞**每請求一個 goroutine**、以 `id` 配對亂序回應 — 這改動 `serveConn` 的寫入並行性,比 (a) 難。
  負對照(Go 單元 + 節點白箱):helper 持鎖 goroutine 期間,經 provd 實際使用的連線送 `health.get` → ≤ 1 s 回;沒有 (a)/(b) 時 → 等到鎖放開才回(今天的行為)。並重寫 L70/L71 的斷言。

## 2. MAJOR

**M1. 同一個事實的第二個後果:provd 常駐連線 + 20 s keepalive → helper 永遠不回到 `AcceptUnix` → 其他 client(root `provclient`、h23 既有單位)連不上。**
- 情境:provd 跑著(release 常態)。`prov-sock-254` 的 `sock-as 471 -- info`、L11 判定的 `provclient info.state`(V21)、任何將來的 root CLI → connect 成功(進 backlog)但 helper 不 accept → 卡到 provclient 自己逾時 → 單位 FAIL 或 hang;harness 不會知道是 provd 佔著。反向也成立:root 開一個 `provclient` 連著不放 → provd 全部請求卡住(只 root 能做,可接受但要寫)。
- 證據:V1;設計 §4.3「一條常駐連線」+「每 20 s 閒置送 `info.boot_id` 當 keepalive」(= 連線永不閒置關閉);§2「harness(H3,照本契約先 merge)」沒有提這個相容性;h23 §6.3 L11 / `prov-sock-254` 原文。
- 修:B1 (a) 一併解;h23 契約加一句「helper 接受多條連線;`provclient` 與 provd 並存」,`prov-sock-254` 加「provd 跑著時 `sock-as 471 -- info` 仍成功」臂(負對照 = 今天的 helper → 逾時)。

**M2. 快取失效規則漏掉「record 被別人改了」,而 `info.state` 本來就回 `Generation`。**
- 情境:(i) 任何非 provd 的寫者改了 record(root 在 ssh 上用 `provclient` 做 claim / net-apply — 這正是 H3 單位的做法;將來的 CLI;helper 自己在 `finishGated` / `resolve` 以 p5 重建 overlay),provd 的 `psks.get` / `info.owners` / `node_cert` 快取不會失效:設計只在「provd 自己送過改狀態動詞」與「helper 連線重建」時失效,而 keepalive 讓後者永不發生 → 之後每條 NXpsk0 新連線用舊 PSK 集合 → 合法擁有者/成員交握一律走假路徑,直到 provd 重啟。(ii) 無鎖讀 `LoadOverlay` 可見「新 record + 舊 meta」(V4)→ `info.state` 回 `EUnsupported` → 設計沒說 provd 怎麼對待:若把它當「無 record」就會錯切 NX 模式 / STATUS 回錯。
- 證據:V3(`node.go:235` key 2 = Generation)、V4;設計 §3 唯讀快取列「失效條件」、§4.3 快取段。
- 修:§3 / §4.3:5 s 輪詢的 `info.state` **generation 變 → 全部快取失效並重拉**(含 `node_cert` 不用重簽,只 PSK / owners / state);`info.state` 回 `EUnsupported` 或任何錯 → **暫態**:保留快取、不改模式、連續 ≥ 60 s 才算 helper 不可達(與 STATUS 規則同一個計時器);Go 單元:fake helper 先回 gen 1、再回 EUnsupported 一次、再回 gen 2 → 斷言只在 gen 2 時重拉且中間模式不變。

**M3. 被攻陷的 provd 對 root helper 的 DoS 面:`info.state` 現在每次 fork/exec,`health.get` 每次開 mgmt socket + 掃 /proc,兩者不取鎖、無額度。**
- 情境:攻陷的 provd 對 helper 連打 `info.state`(設計 §4.3 要它帶 `trial` = `Sys.IsTrial()` = `batman-slot is-trial` fork/exec,V5)→ root 每秒 fork 數百次;`health.get` 同理(mgmt socket open/bind/write/read + `/proc` 掃描 + 讀 sc 檔,V6)。因為這些動詞刻意不取 `n.mu`,它們不會被其他請求節流;設計 §8「攻陷的 provd → helper DoS」列只給了 `psks.get` 1/s,說「既有額度」涵蓋其餘 — 不涵蓋。
- 證據:V5、V6;設計 §4.3 動詞表(`info.state` 加 key 5 `trial`)、§8 第 7 列。
- 修:helper 對 lock-free 動詞加**每連線**額度(例:穩態 5/s、突發 20;超過回 `ERate`,不關連線);`IsTrial()` 結果在 helper 內快取 ≤ 5 s(trial 只在 autocommit 時改);Go 單元(mutant:拿掉額度 → 1000 次呼叫全 OK → FAIL)。順帶:`health.get` 的 `advOnce` latch 由 tick goroutine 與 `health.get` 路徑共用 → 寫明是 atomic。

**M4. nonce 對快取與 helper 的「消耗」語意沒對齊:一次 `claim.replay` / `claim.verify` 之後,provd 快取的那對已經死了,設計沒寫要丟。**
- 情境(L34 恢復流程):擁有者重取 session:`claim/begin`(→ `nonce(h)`,得對 P)→ `op/nonce`(回 P.helper)→ `claim/replay` 失敗(例如 app 時鐘 / 編碼 bug 第一次簽錯)。helper 端:`takeNodeNonce` 消耗 P.node;`verifyOwnerOp` 試過並**刪除** P(V13)。app 重試:協定允許直接再送 `op/nonce` + `claim/replay`;provd 照 §4.3「重取角色的 `op/nonce` 不再呼叫 helper,直接回同一對的 `nonce_helper`」→ 回已刪的 P.helper → 第二次必敗、計入 10/h,三次後 provd 斷線。`claim/finish` 失敗後同理(node 半已消耗;需重新 `claim/begin`)。
- 證據:V13(`node.go:612-619` 註解、`686-703` 每試一對就 `takeHelperNonce` 刪一對);設計 §4.3 nonce 對段、`claim/finish` 列只寫「計失敗 1 次」。
- 修:§4.3:`claim.verify` / `claim.replay` **回應後(任何碼)清掉該 session 的快取對**;其後的 `op/nonce`(重取角色)若無快取對 → `E_FORBIDDEN{reason: 需重新 claim/begin}`(或改為此時再呼叫一次 `nonce(h)`,兩者都寫進 219 v0.8 §3.5);`prov-ble-claim-254` 加「第一次 replay 失敗 → begin → op/nonce → replay 成功」臂;負對照 = 不清快取 → 第二次 CheckMac 失敗。

## 3. MINOR

**m1. jail 內 D-Bus 位址。** jail root 是空 tmpfs、沒有 `/var → /tmp` symlink(V11),設計只掛 `/tmp/run/dbus`;godbus `SystemBus()` 預設位址 `unix:path=/var/run/dbus/system_bus_socket` 在 jail 內不存在。寫明 provd 固定撥 `unix:path=/tmp/run/dbus/system_bus_socket`(或 init `procd_set_param env DBUS_SYSTEM_BUS_ADDRESS=…`,但 release init 不該靠 env)。

**m2. §6 兩個 ⚠️ 可以有原始碼證據。** 「唯讀 bind 的 socket 可 connect」→ V8 ✅(`af_unix.c:1118` → `namei.c:480-490`,只看 sb、不看 MNT_READONLY;mode bits 放行);「目錄 bind 跨重啟」→ V9 / V10 ✅(dbus init 只 `mkdir -p`,`PrepareDir` 不碰目錄)。04 實跑仍要做(ujail 細節),但設計可以把「不行就 `-w`」拿掉。

**m3. `Read Advertising Features` 回應格式。** V7 給了:`supported_flags(4) max_adv_data_len(1) max_scan_rsp_len(1) max_instances(1) num_instances(1) instance[]`;Command Complete 事件框架同 `ParseReadInfo`(opcode 0x0001、cmd opcode 0x003D、status 1 B)。§6 的 ⚠️ 可升 ✅。注意 `num_instances` 是「kernel 裡有的 instance 數」,**連線中 provd 已 Unregister → 0**;latch 設計已處理,但 helper 若在手機連線期間重啟 → latch 直到該連線結束、provd 重註冊、下一個 tick 才回 1(最壞 ≈ 連線時長 + 15 s);autocommit 在 trial 上若恰在此窗讀 → 多一次 WARN。寫進 L11 誠實界線。

**m4. 錯誤細節 key。** §4.3「21 / 22 → 11 E_REJECTED(`reason` = helper reason 文字)」:CDDL `error-detail` 的 `2` 是 **reason-code(數字)**,自由文字只能放 `3`(「for logs only」)。寫成「`3: <文字>`,`2` 不給」。另「`20 → 2`(provd 自己的表查不到 type 時)否則 `3`」:provd 查不到 type 時根本不呼叫 helper,這格永遠不會從 helper 來;改為「helper 回 20 = provd 自己的 bug → 11 + log CRIT」。

**m5. `sign.*` 間隔 ≥ 2.1 s 沒必要。** `sign()` 是每秒第 3 次才拒(V18),provd 啟動 / helper 重啟後連簽兩次合法;2.1 s 只是白白延後第一次廣播。改為「兩次連發,`ERate` 時退避 1 s 重送(冪等)」。

**m6. `device_id` 的來源沒寫。** `device_id` = hex(cert SN)= `info.cert.2`(V17);§4.2 prologue、§4.1 STATUS 末 4、§4.3 `info-resp.1` 都用它,寫一句免得實作者去找不存在的 `info.device_id`。

**m7. 被攻陷 provd 的廣播面(誠實界線補一句)。** policy 只擋方法,不擋 `LEAdvertisement1` 屬性:攻陷的 provd 可註冊 `Discoverable=true`(BlueZ 加 GENERAL flag,V20)+ `Includes=["local-name"]`(hostname)→ 節點對一般掃描器可見且帶穩定名字。無法以 policy 擋;寫進 §8「路人 → 攻陷 provd」列的「能做的」。

**m8. 自檢失敗的無限 respawn。** `respawn 3600 5 0`(retry 0 = 無限)+ ADV 自檢退出碼 3 → 每 5 s 一次 log,永遠;設計寫明是刻意,但建議 provd 在退出前 `sleep 60`(或 procd `respawn 3600 5 5` 讓它停、由 health 之外的 L8 單位抓),否則 `logread` 被洗掉別的 BLE 證據(F-P10 那類 pstore 以外的紀錄就靠 logread)。

**m9. 路人造成的 log 洪水。** 每次連線 / 假路徑 / 擠槽各一行 log,路人 6/分 就能持續寫;加一條「同 reason 每 60 s 最多 N 行」或只在狀態改變時 log(§4.4 已對前置檢查這樣做,連線事件沒有)。

**m10. 檔名不一致。** §2 `files/batman-provd.caps.json` vs §4.5 `/etc/capabilities/batman-provd.json`;定一個。

**m11. `psks.get` 冪等重送。** §4.3 把 `psks.get` 列為冪等重送;它做一次 ECDH(`n.KS.ECDH`,`node.go:400`)且 M3 後有 1/s 額度 → 重送若撞額度回 `ERate`,provd 要把 `ERate` 當「稍後再拉」不是「無 PSK」。寫明。

**m12. 連線槽擠最舊未認證。** BLE 空中單連線時第 2 槽只有 sock 用得到(設計已寫);但在 prov_test 的 sock+BLE 組合,**擁有者正在交握中的 BLE 連線也是「未認證」**,第 3 條 sock 連上會把它擠掉。寫一句「候選 / 交握中的 BLE 連線不被 sock 連線擠掉」或接受並寫進誠實界線(只影響 prov_test)。

## 4. v1 MAJOR 的實際修復狀態(逐項重驗,不看 §13)

| v1 發現 | v2 宣稱 | 我的核對 |
|---|---|---|
| B-B1 / A-M4 假 msg2 短 48 | `random(48+len+16)` = 711 | ✅ 公式對(V23 沿用 711) |
| B-M1 dbus 檔案 bind | 掛目錄 | ✅ V9 / V10 / V8;m1 位址要補 |
| B-M2 / A-M5 helper mutex 卡住 | 唯讀動詞不取 `n.mu` + 快取 | ❌ **B1**:單連線同步 serve 讓它到不了 Handle;M2 快取失效也漏 |
| B-M3 ≤ 10 s 撤廣播 | `health.get` 現算 | ⚠️ 現算本身 ✅(V6),但 B1 期間仍排在 net.apply 後面 |
| B-M4 30 s 閒置 / HELPER_WAIT | keepalive + 冪等重送 + id 丟棄 | ✅ 契約本身對;keepalive 製造了 M1 |
| B-M5 / A-M11 `adv_registered_once` 自報 | helper 以 0x003D 自量 | ✅ V7 opcode / 欄位存在;m3 補時序 |
| B-M6 / A-M9 無 btmgmt | `-wbox` 變體 | ✅(設計層) |
| B-M7 / A-M7 RPA | 900 s 誠實界線 | ✅(V23 沿用) |
| A-M1 `claim.verify` 欄位 | 拆 5 欄 | ✅ V12 |
| A-M2 錯誤碼 | 唯一表 | ✅ 數字對(V14);m4 reason key |
| A-M3 replay 兩次 nonce | 快取一對 | ⚠️ 順序對,但 **M4**:失敗後快取對已死未寫 |
| A-M6 autocommit | 只 WARN | ✅(F-P20 沿用) |
| A-M8 擠槽 | 擠最舊未認證 | ✅;m12 |
| A-M10 `requirejail` | `-E` | ✅ V11 |
| A-M12 分塊重編 | 重編 `{0,1,2,3,(7)}` | ✅ V15:`args_hash` 蓋解碼後 body、`decodeEnvelope` 只看 2/3 |

## 5. 擁有權 / 契約 / 矩陣補充(未列為 finding)

- §3 「helper 的 `n.mu`」列:修 B1 時把「連線數」也列成資源(寫者 helper `Serve`、上限、超過的行為)。
- §3 「唯讀快取」列:加 generation 來源(`info.state.2`)。
- 矩陣加一列「root 以 `provclient` 改 record(harness / 運維)而 provd 跑著」→ 今天:連不上(M1);P2 後:連得上,provd ≤ 5 s 內快取重拉(M2);測試:`prov-sock-254` 新臂 + 白箱 generation 變。
- L11 加 m3 的 latch 時序。
- 安全表「攻陷的 provd」列加 M3、m7。

## 6. 判定

**REJECT(窄)** — 1 BLOCKER / 4 MAJOR / 12 MINOR。

方向沒變、也大多核過:兩個二進位、UUID-only 廣播、kernel 自量 latch(0x003D 存在)、目錄 bind、`requirejail`、`claim.verify` 拆欄、錯誤碼、分塊重編、唯讀 bind 可 connect — 這些 v2 都對,§6 的兩個 ⚠️ 還能升級。但 v2 對 v1 最大的一組 MAJOR(helper 忙時一切卡死)的修法是在錯的並行模型上蓋的:helper socket 伺服器今天一次一條連線、連線內同步處理,「不取 mutex」在 FIFO 單連線上沒有任何效果(B1),而常駐 + keepalive 又把 harness 既有的 `provclient` 路徑鎖死(M1)。這要改 helper 的 `Serve` 與 provd 的連線數,然後 §3、§4.3、§4.4、L70、L71、h23 契約一起重寫,屬設計層。M2–M4 是契約精確度(generation 失效、lock-free 動詞的額度、nonce 對消耗後清掉),各自一段文字 + 一條單元就能收。修完請整份再審一輪(不是只看 B1 那段)。
