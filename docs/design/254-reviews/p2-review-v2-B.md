# #254 PR-P2 `batman-provd` 設計 v2 — 對抗式審查 B(第 2 輪,整份重審)

審查對象:`scratchpad/254-p2-impl.md` v2 全文 §0–§13。方式:從現場(認領、10 台一隊、路人、被攻陷的 provd、root 操作員)出發,每個假設對原始碼或 04 唯讀實查;§13 的「已對應」我沒有採信,逐條自己核。04 只做了 `cat / ls / ps`(沒有註冊廣播、沒有重啟、沒有寫)。重點(B 分工):並行 / 時序、Noise 細節、GATT / D-Bus、生命週期、擁有權 / 安全、負對照、誠實界線。

## 0. 我自己核過的事實(設計未列、或與設計寫的不同)

| # | 事實 | 證據 |
|---|---|---|
| RB2-1 | **helper 的 socket 伺服器一次只服務一條連線,且連線內一次一則請求**:`Serve` 的 accept 迴圈直接呼叫 `s.serveConn(c, h)`(沒有 goroutine),`serveConn` 內 `Read → h(m) → Write` 同步迴圈;第二條連線連得上(backlog)但要等第一條 `return` 才被服務。這是 P1 契約:stage1 §4.1「單連線序列化」 | `sock.go:107-116, 136-171`;`main.go:623 srv.Serve(n.Handle)`;`254-stage1-impl.md:156` |
| RB2-2 | `LoadOverlay` 讀**兩個檔**(`meta` 再 `record`),並以 `meta.SHA` 驗 record、`State/Generation` 必須一致;`SaveOverlay` 以**兩次** `atomicWrite`(各自 rename)寫 **record 先、meta 後** → 無鎖讀者在兩次 rename 之間會得到「record 新、meta 舊」→ `provstore: overlay prov.cbor does not match its meta` 錯誤 → `dispatch` 走 `rec == nil` 路徑回 `EUnsupported` | `provstore.go:349-377, 395-405, 409-432`;`node.go:200-205` |
| RB2-3 | `BootFinish`:`n.mu.Lock()` 在 goroutine 外、`Unlock` 在 goroutine 內;期間 helper **沒有**請求在連線上進行(Listen 之後才會有)→ 不取 mutex 的動詞在這段真的能回 | `wtxn.go:413-426`;`main.go:611-623` |
| RB2-4 | health:`ReadInfo()` 每次呼叫**新開**一個 mgmt socket(無共用 fd)→ tick 與 `health.get` 並行不會互吃回應;`Tick` 會改 `e.poweredFor` 並寫檔 → `health.get` 不能直接呼叫 `Tick` | `health.go:62-93, 142-170` |
| RB2-5 | `info.state` 新 key 5 `trial` = `Sys.IsTrial()` = **exec `batman-slot is-trial`**(`run` 預設 60 s 逾時)→ provd 每 5 s 輪詢 = 每 5 s 一個子行程 | `main.go:138, 80-87` |
| RB2-6 | `flynn/noise` v1.1.0 `WriteMessage` 的 `e` **無條件重新產生**(`e, err := s.ss.cs.GenerateKeypair(s.rng); s.e = e`);`Config.EphemeralKeypair` 的註解是「provided as a **pre-message**」→ 對 NX / NXpsk0 回應方注入 `e` **沒有效果** | `state.go:303-305, 406-410` |
| RB2-7 | `ReadMessage` psk0 msg1:`MixHash(re)`、`willPsk → MixKey(re)`、payload `DecryptAndHash`,**無 DH**;長度只檢查 `len(message) < expected → ErrShortMessage`(**較長的訊息會被接受**,多的當 payload)→ 設計的 msg1 長度前置檢查是必要的 | `state.go:516-548` |
| RB2-8 | BlueZ 5.72 `write_ios / notify_ios` 是**每個特徵一個 queue、以 `bt_att` 配對**(`client_write_io_get(chrc, fd, att)`、`chrc_write_cb` 以 `match_client_att` 找 pipe)→ 多連線時各裝置的資料各走自己的 fd,session 識別可靠 | `gatt-database.c:128-129, 2677-2690, 2802-2817, 3276` |
| RB2-9 | GDBusClient **不呼叫** `Introspect`(`client.c:1065` 只是在解 managed objects 時跳過 Introspectable 介面);provd 匿名連線斷掉 → `client_disconnect_cb → client_remove` → BlueZ 自己移除廣播 | `gdbus/client.c:1058-1072`;`advertising.c:226-230` |
| RB2-10 | kernel:連線建立只清 `HCI_LE_ADV`(:5640),**不**重開;斷線(:3422-3424)與 disconnect 失敗(:2703-2706)兩處 `hci_enable_advertising(hdev)` 以 `conn->adv_instance` 重開 → 空中單連線成立(F-P17 ✅) | `hci_event.c:2703-2706, 3410-3426, 5636-5640` |
| RB2-11 | mgmt `READ_ADV_FEATURES = 0x003D`,回 `{supported_flags u32, max_adv_data_len, max_scan_rsp_len, max_instances, num_instances, instance[]}`,`num_instances = hdev->adv_instance_cnt`(**加了就算,連線中暫停也算**)→ 設計 §6 的 ⚠️ 可升 ✅ | `mgmt.h:543-552`;`mgmt.c:8454-8476` |
| RB2-12 | **唯讀 bind 的 unix socket 可 `connect()`**:`unix_find_bsd → path_permission(MAY_WRITE)`;`sb_permission` 只對 `S_ISREG / S_ISDIR / S_ISLNK` 回 `-EROFS`(且看的是 `sb_rdonly`,不是 bind mount 的 `MNT_READONLY`);socket 檔 `srwxrwxrwx` → 一般權限過 → 設計 §3 的 ⚠️ 可升 ✅(仍建議實作第一步在 04 跑一次當見證) | `fs/namei.c:480-490`;`af_unix.c:1118`;04 `ls -la /tmp/run/dbus` |
| RB2-13 | 04 現況:`dbus-daemon --system`、`bluetoothd -n --noplugin=hostname,autopair,battery,neard,sap`、`batman-provhelper` 跑著;health 行 `adv_registered_once=0 privacy=1 sc=1 sc_file=1 bondable=0`;`/etc/dbus-1/system.d/bluetooth.conf` 的 root policy = `own org.bluez`、`send_destination=org.bluez`、`send_interface` ×6(Agent1 / GattCharacteristic1 / GattDescriptor1 / LEAdvertisement1 / ObjectManager / Properties,**無 destination**);system.conf default:`allow send_type=signal`、`allow send_requested_reply method_return/error`、`allow receive_type=*`、`send_destination=org.freedesktop.DBus` 三介面 + Containers1、deny 三個 | 04 `cat` |
| RB2-14 | 現有 harness 單位**直接**以 `provclient`(`sock-as 471`)連 `helper.sock`:`prov-254.sh`(14 處)、`prov-lib-254.sh`(12)、`chain1-254.sh`(7)、`prov-sec-254.sh`、`prov-claim-254.sh`、`prov-netjoin-fleet-254.sh`、`prov-netupdate-254.sh`、`prov-leave-after-join-254.sh`、`claim-lock-254.sh`、`prov-downgrade-left-254.sh`;h23 只對 `prov-sock-254`、`prov-sec-bond-254` 寫「停 provd 才跑」;h23:804 L11 的判定用 `provclient info.state` | `grep -c provclient scripts/dv/*.sh`;`254-h23-harness.md:402, 405, 804` |
| RB2-15 | 一個改網動詞的最壞時間**沒有上界 330 s**:wireless-txn §19.4「a verb can run a Finish first(setkey ≤ 180 + save ≤ `ConfigSaveTimeout`)then its own setkey … **the client's timeout is not a bound on the node**」;`ConfigSaveTimeout = 300 s` → 單一 `net.apply` 可達 180 + 300 + 180 + 300 ≈ 960 s | `254-wireless-txn.md:627-631`;`provstore.go:458` |
| RB2-16 | 219 §3.4(MUST):假第 2 則「做與真交握**相同次數**的 DH、等到逾時才斷」;向量 `fake_msg2_rule.length_equals_real_msg2 = 711`、`fake_e_pub` 固定 | `219-protocol.md:84`;`vectors.json` |

## 1. 發現

### BLOCKER

**B1. v2 用來修 B-M2 / B-M3 / A-M5 的「唯讀動詞不取 `n.mu`」沒有效果:helper 一條連線一次一則(RB2-1),provd 又只開一條常駐 FIFO 連線(§4.3)→ 任何在 helper 端跑的 `net.apply`(≤ 180 s,最壞更久 RB2-15)把 provd 的 `health.get` / `info.state` 輪詢、keepalive、第二支手機的 `psks.get` 全部排在它後面。mutex 不是瓶頸,連線才是;設計沒有改 `sock.go`,也沒有第二條連線。**
- 情境(現場):擁有者 A 在 join(`net.apply` 跑 2 分鐘)。(a) root 操作員同時開互動 `bluetoothctl`(bondable=1,L67):provd 的下一次 `health.get` 要等 `net.apply` 回完才被 helper `Read` 到 → 撤廣播最壞 ≈ 180 s(+Finish 時更久),不是 §4.4 寫的「最壞 ≈ 5 s + 一次往返」;§13 對 B-M3 的「已修」不成立。(b) 隊友 B 的手機連上讀 STATUS:快取有(≤ 5 s 舊)→ 前 60 s 可讀;但 §4.1 說「helper 不可達超過 60 s → 0x0E」,「不可達」未定義——若以「輪詢沒回」判,第 61 s 起 STATUS 回 0x0E,直到 join 結束;若以「EOF / connect 失敗」判,STATUS 會一直回 join 前的 `state`(例:`claimed`),join 結束後最多 180 s 才轉 `member`。兩種都沒寫。(c) L71 白箱「helper 持鎖期間 02 讀 STATUS、`peer.py` 交握」:交握要 `psks.get`?快取有 → 過;但 `health` 輪詢「不受影響」是錯的(排隊中)。(d) keepalive 排在後面沒關係(helper 不在 `Read`,deadline 沒跑),這點 OK。
- 唯一真的成立的是 L70(`BootFinish` 持鎖 ≤ 120 s):那時連線上沒有請求在跑(RB2-3),不取 mutex 的動詞能回。
- 證據:`sock.go:107-116`(accept 迴圈同步呼叫 `serveConn`)、`sock.go:144-170`(`h(m)` 同步);設計 §4.3「一條常駐連線、一個 client goroutine、FIFO 佇列」、§4.4「最壞 ≈ 5 s + 一次往返」、L71、§13 B-M2 / B-M3 / A-M5 列。
- 修(擇一,都要改 stage1 §4.1「單連線序列化」並回報上層):
  1. **helper 改成每條連線一個 goroutine**(`go s.serveConn(c, h)`;連線數上限例如 4,超過即關;`PeerUID` 檢查不變),provd 開**兩條**連線:「控制連線」只跑不取 mutex 的 `health.get / info.state / info.boot_id`,「工作連線」跑其餘;兩條各自 keepalive。`n.mu` 的語意才真的有用。
  2. 或 helper 在單一連線內**每則請求一個 goroutine、以 `id` 回**(provd 已帶遞增 id,回應不必有序);取 mutex 的動詞自然排隊,不取的直接回。
  - 兩者都要補負對照:Go 單元 / CI `peer-vs-provd`:helper 以 stub 讓 `net.apply` 睡 30 s,同時 `health.get` 必須 ≤ 1 s 回(沒改 → 30 s);節點 L71 加「join 進行中翻 bondable → ≤ 10 s 撤廣播」。
  - 並定義「helper 不可達」= 連線 EOF / connect 失敗 / 控制連線的請求超過 N s 沒回,三者寫清楚,STATUS 的新鮮度規則跟著寫。

### MAJOR

**M1. provd 常駐連線 + keepalive 20 s + helper 單連線 → 節點上任何直接 `provclient` 呼叫(root 運維、既有 10 個 harness 單位、h23 L11 的 `provclient info.state` 判定)永遠排不到 helper。**
- 情境:P2 image 上 provd 跑著;harness 跑 `prov-254.sh` 或 runbook 叫 `provclient … info`:`connect()` 成功(backlog),然後無限等(或 provclient 自己逾時 → 被誤判成 helper 壞了)。provd 永不閒置(20 s keepalive < 30 s idle),EOF 後立刻重連,窗口 ≈ 0。
- 證據:RB2-1、RB2-14;設計 §4.3 連線模型;h23 只在 `prov-sock-254` / `prov-sec-bond-254` 寫「停 provd 才跑」。
- 修:隨 B1 的修法 1 自然解掉(多連線);若選修法 2,仍是單連線 → 要在 H3 把**所有**直接 `provclient` 單位改成「停 provd 或走 `proxy`」並在 `prov-lib-254.sh` 加前置檢查(provd 跑著就 FAIL,不准 hang)。無論哪種,加負對照單位:provd 跑著 → `provclient sock-as 471 -- info.state` ≤ 2 s 回。

**M2. 無鎖 `info.state` / `info.owners` / `info.net` 會讀到「record 新、meta 舊」的撕裂狀態(RB2-2)→ 回 `EUnsupported`;設計沒說 provd 怎麼處理這個暫態。**
- 情境:provd 自己的 `net.apply` 在 helper 寫 record 的兩次 rename 之間,控制連線的 `info.state` 輪詢剛好到 → `EUnsupported "no usable provisioning record"`。若 provd 把它當「無 record = unclaimed」→ 快取 `state` 翻成 unclaimed、下一條連線用 **NX**、`claim_window` 誤報 true、STATUS 給手機看錯;若當「快取尚未填好」→ STATUS 回 0x0E 一次。兩種行為都沒寫;§3 擁有權表說「rename 寫入本來就有自己的一致性」是**錯的**(兩個檔)。同樣的撕裂也打到 `info.owners`(→ `auth/owner` 誤回 `E_FORBIDDEN`)與 `info.net`。
- 證據:`provstore.go:349-377`(讀兩檔、SHA 與 State/Gen 交叉驗)、`:395-405`(record 先、meta 後,兩次 rename);設計 §3「`provstore.LoadOverlay` 是檔案讀取,本來就有自己的一致性:rename 寫入」。
- 修:(a) helper 側:`LoadOverlay` 遇 mismatch 重讀一次(最多 3 次、各 10 ms)再回錯,或改成寫 meta 時把 record 內容也塞進同一個檔(大改,不建議 P2 做);(b) provd 側(必做):輪詢回 `EUnsupported` / 錯誤 → **保留舊快取、不改模式**,連續 ≥ 3 次(15 s)才標「不新鮮」;`info.state` 成功回應中 `Generation`(key 2)變了才讓 PSK / owners 快取失效(見 m3)。單元:假 helper 先回 EUnsupported 一次再回正常 → provd 模式不翻、STATUS 不變(負對照:v2 文字 = 翻)。

**M3. `HELPER_WAIT = 330 s` 不是改網動詞的上界(RB2-15),設計卻以它關連線 + `E_BUSY`;而且在單連線下,provd 關掉再重連**仍要等**helper 做完那個動詞才會被服務。**
- 情境:節點有一個未完成的 `.txn`(上次 join 時斷電),擁有者連上送 `network/update`:helper 先 Finish(setkey ≤ 180 + save ≤ 300)再做本次(≤ 180 + save ≤ 300)。第 330 s provd 關連線、對手機回 `E_BUSY`、重連——重連的 `psks.get` / `info.state` 排在 helper 仍在跑的動詞後面(RB2-1),一直到它結束(最壞再 ~600 s)。期間 STATUS(60 s 後)0x0E、廣播撤不掉、第二支手機連不上。wireless-txn §19.4 明說 client timeout 不是節點上界、app 要「重讀 `info`」—— provd 也是 client,它卻把 330 s 當上界處理連線。
- 證據:`254-wireless-txn.md:627-631`;`provstore.go:458 ConfigSaveTimeout = 300 s`;設計 §4.3 `HELPER_WAIT = 330 s:超時 → 關掉連線、重連`。
- 修:HELPER_WAIT 到期**不關連線**(連線沒壞,是動詞慢):只對該 session 回 `E_BUSY`(reason `outcome unknown — re-read info`),請求留在工作連線上,回應到了以 `id` 丟棄(設計已有 id 丟棄機制);工作連線 keepalive 在請求進行中不送(helper 不在 Read);控制連線照 B1 分開所以輪詢不受影響。HELPER_WAIT 建議改成 ≥ 最壞路徑(或明寫「不是上界,只是回 app 的時間」)。假時鐘單元:請求 400 s 後回 → 被丟棄、連線仍在、下一個請求正確配對。

**M4. `info.state` 每 5 s 輪詢 = 每 5 s exec `batman-slot is-trial`(RB2-5),且 `run` 逾時 60 s;`is-trial` 慢或卡(OTA 寫另一槽、`batman-slot` 持鎖)→ 控制連線的輪詢卡 ≤ 60 s → health 撤廣播 / STATUS 新鮮度跟著卡;trial 其實只在開機時決定,不必每 5 s 問。**
- 證據:`main.go:138`、`:80-87`;設計 §4.3 `info.state` 加 key 5。
- 修:helper 啟動時算一次 `trial` 存在 `Node`(或在 `health` 行多一欄 `trial=`,反正它已經有 `Committed()` 在用),`info.state` 回快取值;autocommit 之後 trial 由 1 → 0 的那次轉變要靠 health tick(15 s)更新那欄即可。負對照:stub `batman-slot is-trial` 睡 20 s → `info.state` 仍 ≤ 1 s 回。⚠️ 我沒讀 `batman-slot is-trial` 會不會真的被 OTA 鎖住——它是個觸發,不是已證明的事故;但「每 5 s 一個子行程」本身就該改。

### MINOR

**m1. F-P14 / §4.2「`Config.EphemeralKeypair` 可注入、事先產生一把臨時 `e` 給 6 個 HandshakeState」是錯的機制描述(RB2-6)。** `WriteMessage` 無條件 `GenerateKeypair` 覆寫 `s.e`;`EphemeralKeypair` 是 pre-message 用。6 個 state 各自在 WriteMessage 才產 e(只有成功那一個會 Write),功能上沒差、安全上沒差,但設計寫了一個不存在的機制。改:刪「注入 e」,寫「成功的 state `WriteMessage` 自產 e;向量單元以 `Config.Random` 餵固定 e 重現 msg2」。

**m2. 假第 2 則的「與真路徑相同的兩次 DH」在 msg1 長度錯時用什麼當 `e_手機`?** msg1 < 32 B 時沒有 32 B 可取;要寫:取前 32 B,不足以隨機補(X25519 對任意 32 B 都算得出)。另外 219 §3.4 的「同次數 DH」—— 真回應方 msg2 是 `ee` + `es` = 2 次 DH ✅(`patterns.go:43`、`state.go:424-440`),設計一致。

**m3. PSK / owners 快取只在「provd 自己送過改狀態動詞」或「連線重建」後失效 → 旁路改狀態(root `provclient` 的 `net.apply` / `owner.add`、harness)不會被看到;`psk_member` 綁 `Net.Version`(`node.go:407-411`)→ 舊快取讓隊友手機交握失敗、被誤歸因。** 便宜修法:`info.state` 回應裡已有 `Generation`(key 2),每次 Generation 變化就讓 PSK / owners 快取失效(所有改 record 的路徑都 `Generation++`,`node.go:548, 831, 877, 904, 1134, 1192`)。這也順帶解掉 M2 的「何時失效」問題。

**m4. `psks.get` helper 側 1/s 額度 vs 失效後的重拉:若 provd 失效後有兩條新連線同時交握,兩個 `psks.get` 在 1 s 內 → 第二個 `ERate` → 那條交握失敗。** 要寫 provd 的 single-flight(同一時間只有一個重拉在飛,其他等它),單元一條。

**m5. `health.get` 與 health tick 共用的 `advOnce` latch(與 tick 自己的 `poweredFor`)是兩個 goroutine 的共享狀態;`health.get` 不能呼叫 `Tick`(會寫檔 + 多算 `poweredFor`,RB2-4)。** 設計要寫:抽出 `compute()`(純算、不寫、不碰 poweredFor),latch 用 `atomic.Bool`;並把 `Read Advertising Features` 的回應解析寫進 health 套件並給假事件單元(設計 §9 有列,OK)。RB2-11 可讓 §6 那列 ⚠️ 升 ✅。

**m6. §3 擁有權表「BLE 廣播 instance 唯一寫者 provd」漏了 kernel 這個寫者:斷線時 kernel 自己 `hci_enable_advertising` 重開同一 instance(RB2-10)。** 影響的是 provd 的狀態機:手機連上又很快斷(掃描 app)→ kernel 先重開 → provd 的 `UnregisterAdvertisement` 才到 → 再「所有連線結束 → 重註冊」。順序沒錯,但表要承認第二寫者並說 provd 以 `ActiveInstances` 對回自己的預期(設計已有「foreign instance」log,把這個情境也列進去,免得它被當成 foreign)。

**m7. 「helper 不可達超過 60 s → STATUS 0x0E」與 L10 的「dbus 重啟 → ≤ 60 s 重註冊」兩個 60 s 都沒有推導。** L10:dbus 重啟 → bluetoothd 失去 bus 會退出 → procd 重起 → 新 pid → health `sc_file` 要等 `batman-sc` 被重寫成新 pid(stage1 D27 的寫者與時序不在本文件)→ 在那之前 provd 前置不成立、不註冊。L10 的 60 s 可能被 sc 檔的重寫時間吃掉,FAIL 時會錯歸因給 provd。寫出依賴鏈,或把斷言拆成「bluetoothd 新 pid 且 sc_file=1 之後 ≤ 15 s 重註冊」。

**m8. D-Bus policy 最小集合核過,沒有缺:** provd → bluetoothd 的 8 個方法夠(provd 另外只呼叫 `org.freedesktop.DBus` 的 Hello / AddMatch / GetNameOwner,default 放行);bluetoothd(root)→ provd 的回呼靠 root policy 無 destination 的 `send_interface`(Properties / ObjectManager / GattCharacteristic1 / LEAdvertisement1,RB2-13);BlueZ 不 Introspect(RB2-9);signal 收 / 送、requested reply 都在 default。兩點要寫進 §4.7 的「為什麼夠」:(a) 廣播物件 BlueZ 走 `g_dbus_proxy_new → Properties.GetAll`,provd 的 `LEAdvertisement1` 物件**必須**有 `prop.Export`(設計有寫,但理由要是這個);(b) 若 root policy 日後加 destination 限制(例如有人「收緊」成 `send_destination="org.bluez"`),回呼會全斷 → gate 要斷言 root policy 這 4 行仍無 destination。

**m9. 「被攻陷的 provd 能做的事」少寫兩項:** (a) `sign.static(任意 pub)` → 拿到以本節點 DAC 簽的 `node_cert`,可從**另一台 radio** 冒充本節點(直到重開機換 `boot_id`;app 是否驗 boot_id 新鮮度在 219 §3.3,要指明);(b) `psks.get` 的 `psk_member` 是全隊共用 → 一台被攻陷的 provd 可對成員手機冒充**任一隊友節點**。219 §9 已有「`psk_member` 共用的誠實界線」,§8 表那列要引過來,不要只寫「看經過的明文」。

**m10. 無鎖的 `info.cert / info.ecdh_pub` 讀 `n.KS`;file 後端無妨,#255 608B 後與 `sign.*`(取鎖)並行會同時打 I2C。** 寫一行到 #254 checklist / #255:keystore 自己要有鎖。

**m11. 文字:** §4.2「對 6 把候選 PSK 各建一個 `NewHandshakeState(... EphemeralKeypair: e ...)`」隨 m1 改;§3 helper mutex 列把「rename 寫入」改成 M2 的真實情況;§6「以目錄 bind …唯讀 bind 的 dbus socket 可 connect」可引 RB2-12 升 ✅;§6「`Read Advertising Features` 回應格式」引 RB2-11 升 ✅。

## 2. 我核過、成立的(§13 說修了、我確認真的修了)

| v1 發現 | v2 | 結果 |
|---|---|---|
| B-B1 假 msg2 短 48 | §4.2 `random(48 + len + 16)`,單元 `len(fake)==len(real)` | ✅(RB2-16;公式對任意 cert 長度都對) |
| B-M1 dbus socket 檔案 bind | 掛目錄 `/tmp/run/dbus` | ✅ 且 RO 可 connect(RB2-12) |
| B-M4 30 s 閒置假 `E_BUSY` | keepalive 20 s、冪等重送、id 丟棄 | ✅ 機制對;但 HELPER_WAIT 關連線那段見 M3 |
| B-M5 `adv_registered_once` 自報 | helper mgmt 0x003D latch | ✅(RB2-11;`num_instances` 連線中也算,latch 語意正確) |
| B-M7 RPA | 900 s 誠實界線 | ✅(RB2-10) |
| B-m1 msg1 長度 | 前置檢查走假路徑 | ✅ 必要(RB2-7 長訊息會被接受);不是新 oracle(state 本就在 STATUS 公開) |
| B-m2 6 個 HandshakeState | 改寫 | ✅ 可行;但「注入 e」是空話(m1) |
| B-m3 ATT 0x0E | `org.freedesktop.DBus.Error.Failed` | ✅ |
| B-m4 policy | 刪 own / DBus / receive | ✅(m8) |
| B-m8 BLE 單連線 | 誠實界線 | ✅(RB2-10 連線時不重開) |
| B-m9 `psks.get` 去 4/5 | — | ✅ |
| B-m11 sign 額度 | 間隔 2.1 s | ✅(`node.go:333-345` 2/s 全域) |
| session 識別 / Acquire fd | device 路徑 + per-att pipe | ✅(RB2-8) |
| B-M2 / B-M3 / A-M5 mutex | 唯讀動詞不取 `n.mu` | ❌ **只對 L70 成立,其他見 B1** |

## 3. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| helper 忙時 `health.get` ≤ 5 s 回 | L71 白箱(但機制不存在) | Go 單元 / CI:`net.apply` stub 睡 30 s 時 `health.get` ≤ 1 s(B1) |
| 節點上 `provclient` 與 provd 共存 | — | provd 跑著 → `provclient info.state` ≤ 2 s(M1) |
| 撕裂讀 | — | 假 helper 回一次 `EUnsupported` → 模式不翻(M2) |
| HELPER_WAIT 後連線 / id 配對 | 假時鐘單元 | 「不關連線」版本的單元(M3) |
| `info.state` 不被 `batman-slot` 拖住 | — | stub 睡 20 s(M4) |
| 快取旁路失效 | — | root `provclient net.apply` 後 ≤ 5 s provd 用新 PSK(m3) |
| `psks.get` 額度 vs 雙連線 | helper 單元 | provd single-flight 單元(m4) |
| 假 msg2 等長 / 同 DH / 等逾時 | 單元 + timing 單位 | ✅ 足夠 |
| dbus 重啟恢復 | L10 臂 | 依賴鏈寫明(m7) |
| RO bind connect | L10 / L11 臂 | ✅(RB2-12 補證據) |

## 4. 誠實界線

有寫且對:RPA 900 s;BLE 單連線被路人佔;ADV 自檢只擋自己;`adv_registered_once` 量的是 kernel 曾有 instance;autocommit 只 WARN;`capabilities` 固定;`model` fail-open。
寫錯或沒寫:「最壞 ≈ 5 s + 一次往返」與「helper 忙時也回」(B1);「新 NXpsk0 連線可能逾時**一次**」—— 真實情況是 helper 忙期間**控制面全部**排隊(B1),不是 psks 一次;330 s 是上界(M3);provd 常駐連線讓運維 `provclient` 失效(M1);被攻陷 provd 的冒充能力(m9);`LoadOverlay` 兩檔(M2)。

## 5. 判定

**REJECT(窄)** — 1 BLOCKER / 4 MAJOR / 11 MINOR。方向(兩個二進位、UUID-only 廣播、kernel patch、helper 向 kernel 求證 latch、快取服務 STATUS、等長假 msg2、msg1 長度檢查、policy 最小集合)都成立且我核過原始碼;Noise、GATT/D-Bus、policy 三塊沒有剩下的硬傷。要退回的只有一件事但它是地基:**v2 把 v1 的三個 MAJOR(B-M2 / B-M3 / A-M5)歸到 `n.mu`,實際瓶頸是 helper 的單連線序列化(`sock.go:107-116`,stage1 §4.1 契約),所以 §4.4 的 ≤ 10 s、§4.1 的 STATUS 可用性、L71、以及節點上 `provclient` 的可用性(M1)在 helper 跑改網動詞期間全部不成立。** 修法是 helper 多連線(或連線內並行 + id 回)+ provd 控制 / 工作兩條連線 + stage1 §4.1 契約改字;M2–M4 隨之一併定義(撕裂讀、HELPER_WAIT 不關連線、trial 不每 5 s exec)。修完後整份再審(重看 §3 擁有權表、§4.3 連線模型、§5 L70/L71、§13),並補 §3 的負對照。
