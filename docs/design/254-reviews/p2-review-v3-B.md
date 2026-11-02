# #254 PR-P2 `batman-provd` 設計 v3 — 對抗式審查 B(第 3 輪,整份重審)

審查對象:`scratchpad/254-p2-impl.md` v3 全文 §0–§14。方式:從現場出發(認領、10 台一隊的 join、路人、被攻陷的 provd、root 操作員跑 `provclient` / harness、provd 與 helper 各自重啟),§13 / §14 的「已對應」一律不採信,逐條對原始碼重核。分工 B:新多連線 helper 下的並行、額度 / 連線上限語意、ctl / ops 切分、Noise、假 msg2、PSK 試法時序、擠槽、GATT 快取 60 s、生命週期、dbus policy、kernel patch 範圍、負對照、誠實界線。

**環境誠實界線**:04(10.41.1.3)兩次 `ssh -o ConnectTimeout=8` 都 `Connection timed out` → **本輪沒有任何 04 實機輸出**;F-P* 的實機事實沿用 v1 / v2 兩位核過的,我核的是原始碼:repo main `34f216d`、firmware `/home/yello/firmware-2710`(kernel 6.6.138 build 樹、BlueZ 5.72 build 樹)、`flynn/noise@v1.1.0` module cache。

## 0. 我自己核過的事實(✅ 原始碼;⚠️ 推論 / 未能上機)

| # | 事實 | 證據 |
|---|---|---|
| RB3-1 ✅ | 今天的 `Serve`:`for { AcceptUnix(); s.serveConn(c, h) }` 同步;`serveConn` 每條連線一個 `buf`(64 KiB+1)、`Read` 前 `SetReadDeadline(+Idle)`、`h(m)` 同步、`Write` 前 `SetWriteDeadline(+Idle)`;**`Idle` 只在 `Read` 前武裝,`h(m)` 跑長動詞期間沒有 deadline 在跑** → 設計「HELPER_WAIT 到期不關連線」在 helper 側成立(連線不會因 30 s 被 helper 關掉);改成 `go s.serveConn` 不需要碰 `serveConn` 內部 | `sock.go:107-116, 136-170` |
| RB3-2 ✅ | `Handle` 進門就 `n.mu.Lock()`(在解 verb 之前)→ 實作「唯讀動詞不取鎖」必須把 verb 解析搬到鎖外;`dispatch` 的前置段:`IsTrial()` 只對 `stateChanging`、`otaBusy()` 只對 `net.apply / network.leave`、`finishGated` 只對非 commit-only 的 `stateChanging`、**`LoadOverlay` 對所有動詞** → 唯讀動詞在鎖外只會跑 `LoadOverlay` + 自己的 case | `node.go:157-175, 183-209` |
| RB3-3 ✅ | 唯讀動詞碰到的 `Node` 狀態:`n.P`(不變)、`n.KS`(`Keystore` 五個私有欄位,全部在 `Load` 後唯讀;`Cert()/SN()` 回 copy、`ECDHPub()/DACPub()` 現算)、`n.BootID`(不變)、`n.Log`(`syslog.Writer.Info`,內部有 mutex);**不碰** `nonces / signLog / replayF / Verdict / lastFinishFail / finishFails`。`rec` 是每次 `LoadOverlay` 的新值 → 唯讀動詞不取 `n.mu` 在資料面是安全的 | `node.go:94-110, 211-247`;`keystore.go:34-61`;`main.go:46-55` |
| RB3-4 ✅ | 新增的共享狀態只有兩個:**`IsTrial` 快取**(`dispatch` 的 `stateChanging` 檢查在鎖內用、`info.state` key 5 在鎖外用 → 要有自己的 mutex / atomic)與 **health `advOnce` latch**(設計已寫 atomic)。`health.Env.poweredFor` 只在 `Tick` 動;`ReadInfo()` 每次新開 mgmt socket,無共用 fd | `node.go:184`;`health.go:90-101, 129-159` |
| RB3-5 ✅ | `LoadOverlay`:`Lstat+ReadFile(meta)` → `ParseMeta` → `Lstat+ReadFile(record)` → SHA / State / Gen 交叉驗;`WriteOverlay` 以固定名 `<path>.tmp` + rename,record 先 meta 後 → 無鎖讀者唯一可見的壞狀態是「不符 → error」,不會讀到半截檔;`.tmp` 只有持鎖寫者碰 → 設計的「mismatch 重讀 ≤ 3 次」足夠 | `provstore.go:349-377, 391-435` |
| RB3-6 ✅ | `applyNet`:step 3 `commitTxn`(**Generation+1 落地,p5 與 overlay**)在 step 4 `SaveTxn`(≤ 300 s)**之前**;`.txn` 從 step 1 到 step 4 結束都在 → `ctl` 在 join 進行中就會看到 generation 變 + `info.net.4 unfinished=1`,而 `ops` 此時仍被同一個 `net.apply` 佔著 | `node.go:1132-1180`;`provstore.go:458` |
| RB3-7 ✅ | `verifyOwnerOp` 以 map 順序試 `h` 的每一對、**每試一對就 `takeHelperNonce` 刪一對**,第一個 `hit` 才 return → 一次 owner-op 可能把同 `h` 其他未用的對也吃掉;`claimReplay` 先 `takeNodeNonce` 再 `verifyOwnerOp`;`claimVerify` 用 `takeNodeNonce`(最新未用) → 設計 §4.3「回應後(任何碼)清掉該 session 的對」與 helper 行為一致 | `node.go:303-329, 528-531, 616-621, 684-703` |
| RB3-8 ✅ | `realSys.IsTrial()` = exec `batman-slot is-trial`(60 s 逾時);health `Committed` 每 15 s tick 也 exec 一次 | `main.go:81-90, 138, 598` |
| RB3-9 ✅ | 連線時控制器停廣播;斷線 `hci_disconn_complete_evt` 以 `conn->adv_instance` 呼叫 `hci_enable_advertising` → 若 instance 已被 Unregister 移除、`adv_instances` 空且無 `HCI_ADVERTISING` → 不重開(F-P17 / F-P35 ✅) | `hci_event.c:3405-3424`;`hci_sync.c:498, 1944` |
| RB3-10 ✅ | **有 peripheral 連線存在時,connectable 廣播由 `is_advertising_allowed` 決定**:`le_num_peripheral > 0 && connectable` 需要控制器 `le_states` bit 38 與 21,否則 `hci_enable_advertising_sync` 回 `-EINVAL`;`ADD_ADVERTISING` 路徑 `add_advertising_sync → hci_schedule_adv_instance_sync → hci_start_adv_sync → hci_enable_advertising_sync`,錯誤回到 `add_advertising_complete` → `mgmt_cmd_status(FAILED)` → BlueZ `RegisterAdvertisement` 回 `org.bluez.Error.Failed` | `hci_sync.c:1007-1040, 1850-1875, 1831-1848, 2007-2062`;`mgmt.c:8642-8670` |
| RB3-11 ⚠️ | BCM4345C0 的 `le_states` bit 38/21(peripheral 同時 connectable adv)是否支援:**04 連不上,未驗**;BT 4.1/4.2 世代控制器多半不支援 → 以「不允許」為假設寫 M2,並要求實作第一步在 04 以 `btmon` 見證 | — |
| RB3-12 ✅ | BlueZ:provd 的 bus 連線斷 → `client_disconnect_cb → app_free`,**只釋放 GATT app,不斷任何 LE 連線**;廣播側 `client_disconnect_cb → client_remove → REMOVE_ADVERTISING` | `gatt-database.c:1642-1650, 576-597`;`advertising.c:198-230` |
| RB3-13 ✅ | `flynn/noise` v1.1.0:`WriteMessage` 的 `MessagePatternE` 無條件 `GenerateKeypair(s.rng)` 覆寫 `s.e`(注入無效,F-P31 ✅);`ReadMessage` 對 `E` 只 `len < DHLen → ErrShortMessage`,多的當 payload;psk 模式 `MixKey(re)`;失敗 `Rollback()` | `state.go:400-416, 510-552` |
| RB3-14 ✅ | 219 §3.4 MUST:固定試 6 次、全部失敗 → 真臨時金鑰 + 等長隨機 payload + 同次數 DH + 等到逾時;§8:同時 BLE 連線 2、未認證可被擠、`nonce_helper` 每 session ≤ 4 | `219-protocol.md:83-84, 370-387` |
| RB3-15 ✅ | h23 §4.8.2 / §4.1 表:`gatt.sock` 在 **`/tmp/run/batman-provd-test/`(provd:provd 0700,init 以 root `mkdir + chown 471:471 + chmod 0700`,provd 以 `O_NOFOLLOW` 驗 owner=471 才 bind)**;`provd.env` 與 `killpoint` 在 **`/tmp/run/batman-prov-test/`(root 0700)**;harness 經 `provclient sock-as 471 -- proxy` 進目錄 | `254-h23-harness.md:137-139, 275-281` |
| RB3-16 ✅ | `provclient` 預設每次呼叫 30 s deadline(`PROVCLIENT_TIMEOUT_S` 1..600);`sock-as` 以 `Setuid` 換 uid;今天沒有 `proxy` 子命令、沒有 `batman-provd-test` 字串(H3 要加) | `tests/tools/provclient/main.go:355-372, 429-483, 522` |
| RB3-17 ✅ | firmware `bluetooth.conf` root policy 六條 `send_interface` 無 destination(F-P18 ✅);無 default policy;檔頭註明「provd 之後有自己的 `<policy user>`」 | `package/batman/batman-ble/files/bluetooth.conf` |
| RB3-18 ✅ | kernel 6.6.138 `eir.h` 三個 creator 都無 size 參數:`eir_create_adv_data / eir_create_scan_rsp / eir_create_per_adv_data`(F-P10 ✅,且 scan_rsp / per_adv 兩條同族路徑也在) | `net/bluetooth/eir.h:12-14`;`eir.c:224, 245, 342` |
| RB3-19 ✅ | 舊 `Serve` 單連線時,`BootFinish` 在 `Listen` 前取鎖、`Unlock` 在 goroutine 內 → L70 的「`ctl` 不取鎖的動詞能回」成立(前提是 RB3-2 的 verb 解析搬到鎖外) | `wtxn.go:413-426`;`main.go:611-623` |

## 1. BLOCKER

無。多連線模型本身成立:`sock.go` 的 `serveConn` 已是每連線自足(RB3-1),唯讀動詞在 `Node` 裡只碰不變欄位與每次新讀的 `rec`(RB3-3),撕裂讀只會以錯誤出現、不會讀到半截(RB3-5)。v2 的 BLOCKER(連線序列化)我確認已由 §1.3 / §4.3 的連線模型真的解掉,L70 / L71 的斷言在新模型下成立。

## 2. MAJOR

**M1. prov_test 的 `gatt.sock` 目錄契約自相矛盾,而且 uid 471 在設計寫的目錄裡建不了 socket;與已排在 P2 前 merge 的 H3 契約不同。**
- 情境:CI `peer-vs-provd`、節點 `prov-two-phones-254`(L24)、`prov-sec-hog-254`(L66)、`prov-ble-claim-254` 的 sock 臂、`prov-sock-254` 的並存臂——所有 sock 傳輸的單位都要 provd 在 `SOCK_ONLY=1` 時 bind `gatt.sock`。設計 §3 把 `gatt.sock` 與 `provd.env` 放在同一個 `/tmp/run/batman-provd-test/`,寫者 root、**目錄 root 0700**,又寫「`gatt.sock` 由 provd 在 `SOCK_ONLY=1` 時建(目錄須存在且 root 0700,否則不建、log)」。provd 是 uid 471、`bounding: []`、`no_new_privs` → 在 root 0700 的目錄裡 `bind()` 必得 `EACCES`,provd 會「不建、log」→ 整組 sock 單位 FAIL。harness 那邊 `provclient sock-as 471 -- proxy` 也進不了 root 0700 的目錄。
- 證據:設計 §3 `/tmp/run/batman-provd-test/` 列、§4.5 test init 行;h23 §4.1 表 `:139`「`/tmp/run/batman-provd-test/`(provd:provd 0700)…init(root)`mkdir` + `chown 471:471` + `chmod 0700`;provd `O_NOFOLLOW` 驗 owner=471、非 symlink 才 bind」、`:137`「`/tmp/run/batman-prov-test/`(root 0700)、`killpoint`、`provd.env`」(RB3-15)。§12 工作順序是「H3 harness 照 §4 契約先 merge」→ 錯的契約會先被寫進 harness。
- 修:§3 / §4.5 / §4.6 改回 h23 的兩個目錄:`provd.env`(root 0600)留在 `/tmp/run/batman-prov-test/`(root 0700,只有 test init 以 root 讀,**不**掛進 jail);`gatt.sock` 的目錄 `/tmp/run/batman-provd-test/` 由 test init 以 root 建、`chown 471:471`、`chmod 0700`,`procd_add_jail_mount_rw` 它,provd 以 `O_NOFOLLOW` + `fstat` 驗 owner==471 / 非 symlink / 0700 才 bind(h23 的寫法);tmp-trust allowlist 兩條目錄的所有權也照這個寫。負對照:白箱把目錄改成 root 0700 → provd log `gatt.sock: dir not owned by provd` 且 `sock-as 471 -- proxy` 得 EACCES(= 今天 v3 文字會發生的事)。

**M2. provd 重啟(crash / respawn / `set-provd-env` restart)時手機的 LE 連線還在:BlueZ 不會斷它,kernel 不允許在 peripheral 連線存在時再開 connectable 廣播 → 新 provd 的 `RegisterAdvertisement` 失敗、節點在手機自己斷線前都連不上;矩陣 L8 沒有這條。**
- 情境(現場 + harness 每天都會踩):擁有者手機連著(或路人連著拖),provd crash → procd 5 s respawn。(a) 舊 provd 的 bus 連線斷 → BlueZ `client_disconnect_cb → app_free` 只釋放 GATT app,**LE 連線留著**(RB3-12);(b) 新 provd 起來、前置全 1 → `RegisterAdvertisement` → mgmt `ADD_ADVERTISING` → `hci_enable_advertising_sync` → `is_advertising_allowed(connectable=true)`:`le_num_peripheral > 0` 且控制器 `le_states` 缺 bit 38/21(BT 4.x 控制器常態;04 未驗 ⚠️ RB3-11)→ `-EINVAL` → `add_advertising_complete` 回 FAILED → BlueZ `org.bluez.Error.Failed`(RB3-10);(c) provd 走 §4.5 的「bus / adapter 失敗 → 退避 1,2,4…≤ 60 s 不退出」,每次都失敗,直到手機斷線;iOS 的 CoreBluetooth 連線不會自己斷。期間 STATUS 不可讀(沒有 GATT app 給那條舊連線)、新手機也連不上(沒廣播)。即使控制器允許(bit 38/21 有),provd 的槽計數也不知道這條既有連線、`Device1.Connected` 已經是 true 不會再有 `PropertiesChanged` → §4.4「有連線建立 → 撤銷;所有連線結束 → 重註冊」的狀態機從一個錯的初態開始。harness:`prov-wbox-254.sh set-provd-env` 每次都 restart provd(h23 `:254`),02 / peer 連著就踩。
- 證據:RB3-10、RB3-12;設計 §4.4 連線觸發只列 `Acquire*` 到來與 `Device1.Connected`、L1 啟動流程「連 bus、等 `Adapter1`、填快取、簽 node_cert、health 全 1 → 註冊」沒有任何「盤點既有連線」步驟;L8 只寫「procd respawn + 內部退避 log」。
- 修:啟動(與 L9 bluetoothd 重起、L74 adapter 重加後)第一步 `GetManagedObjects` 掃 `org.bluez.Device1` 的 `Connected == true` → 逐一 `Device1.Disconnect`(policy 已放行)→ 等 `Connected` 轉 false(或 ≤ 2 s)才走註冊;log `provd: disconnected <n> stale link(s) at start`。`RegisterAdvertisement` 回 `Failed` 時也要重新盤點(不是只退避)。矩陣加一列「provd 重啟時手機連著」;測試 `prov-respawn-254` 加臂:02 連著 → kill provd → ≤ 10 s 02 被斷、`ActiveInstances=1`(負對照 = 不盤點 → `RegisterAdvertisement` 持續 `Failed`,btmon 可見 `LE Set Advertising Enable` 沒送 / mgmt status Failed)。實作第一步在 04 用 `btmon` 見證 RB3-11(控制器到底允不允許),把結果寫進 §1.2。

**M3. 「唯讀動詞每條連線 5/s(突發 20)」用重連就能歸零:被攻陷的 provd 不必開滿 4 條,開一條、打 20 發、關、再開——accept 速率沒有上限,單元測試(單一連線 1000 次)又測不到這條路。**
- 情境(§8「攻陷的 provd → helper DoS」列):`health.get` 一次 = 2 個 mgmt socket(各自 bind / write / read,2 s 逾時)+ 掃 `/proc` 找 bluetoothd + 讀 sc 檔;連線 churn 下每秒可打到數百次,全在 root helper 上跑。`IsTrial` 快取讓 fork 被壓住(對),但 `health.get` / `info.*` 的成本不是 fork。設計 §8 把這一列標為「已擋」並給了 mutant「拿掉額度 → 1000 次全 OK → FAIL」——那個 mutant 在單連線上打,通過與否與 churn 無關。
- 證據:設計 §1.3 / §4.3「每條連線額度」、§8 第 7 列、§9 helper 單元;`sock.go:107-116` accept 迴圈無速率限制;`health.go:55-87`、`main.go:638-651` 的 `health.get` 成本。
- 修(擇一或兩者):(a) 額度桶改成 **helper 全域**(uid 471 只有一個主體;正常負載 = provd `ctl` 0.4/s + 偶發 provclient,全域 10/s 突發 40 足夠),每連線桶可留作第二層;(b) accept 速率限制(例如新連線 ≤ 5/s,超過即關、log 一行 / 60 s)。負對照改寫:mutant = 連線 churn(開 → 20 發 → 關 ×50 在 1 s 內)→ 第 N 發起 `ERate` 或連線被拒;今天的寫法 → 全部 OK → FAIL。順帶寫明:被拒 / `ERate` 的連線**不**算失敗、不關連線(provd / provclient 都要能退避重試)。

## 3. MINOR

**m1. 第 5 條連線的規則沒有為 provd 保留位子,且文字只寫「第 5 條連上即關」。** helper 分不出 provd 與 `provclient sock-as 471`(同 uid,RB3-16)。情境:harness 或 root 同時開 3 條 `provclient`(例如一條卡在 960 s 的 `net.apply`、兩條輪詢),此時 helper 重啟 → provd 重連 `ctl` / `ops` 其中一條被當第 5 條關掉 → provd 退避、手機全 `E_BUSY`,直到某條 provclient 結束。寫進 §3 連線資源列的誠實界線(root 的責任;provd 被拒時 log `helper: connection refused (cap)` 並以 1,2,4 s 退避),並在 `prov-sock-254` 並存臂加「3 條 provclient 開著時 provd 仍能重連」或明寫不保證。

**m2. `ctl` 連線沒有每則請求的逾時。** helper 若卡住但沒死(SIGSTOP、mgmt socket 讀卡在 2 s 逾時 ×2、`/proc` 掃描慢),`ctl` 的 FIFO 永遠等那一則;「不新鮮 > 60 s」靠時間判定仍會觸發,但 `ctl` 之後不再有新請求出去,helper 恢復後要等那則回來才動。寫明 `ctl` 每則 ≤ 10 s 無回應 → 關 `ctl` 重連(冪等動詞重送一次,`ops` 不動)。假時鐘單元一條。

**m3. 「不新鮮 > 60 s」的後果寫成「STATUS 0x0E、不廣播新連線」,但 §4.4 的撤銷理由表沒有 `stale`,也沒說「已註冊的廣播要撤」。** 前置(`privacy / sc / bondable`)的唯一證據就是 `health.get`;helper 死 60 s 後 provd 等於在沒有證據下繼續廣播。fail-closed 應是:不新鮮 → `UnregisterAdvertisement`(reason `stale`,加進 log 契約)、STATUS 0x0E;恢復新鮮 → 重註冊(reason `health`)。白箱:`kill -STOP` helper → ≤ 65 s 撤廣播;`-CONT` → ≤ 10 s 重註冊(負對照:v3 文字 → 廣播不撤)。

**m4. generation 變了之後、新 PSK 集合拉回來之前,provd 用哪一套 PSK 沒寫;§4.3 的「新手機的 NXpsk0 交握可能逾時一次」低估了。** RB3-6:join 在 step 3 就 Generation+1,`ops` 卻被同一個 `net.apply` 佔到 step 4 `SaveTxn` 結束(≤ 300 s,最壞路徑更久)→ `psks.get` 排在它後面這整段。若 provd 在失效當下就丟掉舊集合 → 這整段所有 NXpsk0 新連線(包括擁有者本人重連)都走假路徑,不是「一次」;若保留舊集合直到新集合到 → 擁有者 PSK 沒變、仍能連,只有 `psk_member`(綁 `Net.Version`)那幾分鐘是舊的。寫明採後者(保留舊集合、新集合到了才換),並把誠實界線改成「join / update 進行中到 save 結束這段,member PSK 是舊版本」。`cache_test` 加:gen 變 → `psks.get` 延遲 30 s 回 → 中間 `psk_owner` 仍可交握。

**m5. `ops` 重連 / helper 重啟後,provd 每條 session 快取的 nonce 對與 `claimInProgress` 要一起作廢。** helper 的 `nonces` 在記憶體(RB3-7),helper 重啟全沒;§3 把「`ops` 連線重建後」列為 PSK / owners 快取失效條件,但 nonce 對是 per-session 狀態,沒列。否則 L11 之後第一個 `claim/replay` 必得 `E_FORBIDDEN` 並計入 10/h。一句話 + 單元。

**m6. `IsTrial` 快取的同步沒寫。** 它同時被鎖內的 `dispatch` 前置(`stateChanging` 檢查)與鎖外的 `info.state` key 5 用(RB3-4)→ 自己的 mutex 或 `atomic.Value{val, exp}`;並寫明 trial → committed 的轉變最多晚 5 s(autocommit 後 `E_BUSY(updating)` 多撐 5 s,無害)。

**m7. `info.net` 撞額度(`ERate`)時 `info` 回什麼沒寫。** `info.net` 走 `ctl`、受 5/s 額度;peer.py / 多個 `info` 連發會撞到。寫明:`ERate` → `info-resp` 不帶 9/10/11(或整封 `E_RATE`),二選一並進 `route_test`。

**m8. `info.net.4 unfinished` 在「自己這個 join 進行中」也是 1(RB3-6:`.txn` 從 step 1 到 step 4),與「上次沒做完」分不開。** 對 L75(手機中途斷線重連讀 `info`)是對的行為,但要在 219 v0.8 / wireless-txn §19 寫明「`unfinished=1` 也涵蓋正在進行的改網;app 等它變 0 或 `net_version` 變」,否則 app 會把進行中的 join 當成要修的壞狀態。

**m9. kernel patch 範圍只寫 `eir_create_adv_data`。** 6.6.138 三個 creator 都無 size 參數(RB3-18);`eir_create_scan_rsp` 走 Local Name(我們不放,但被攻陷 provd 可 `Includes=["local-name"]` + 長 hostname),`eir_create_per_adv_data` 我們不用。§4.8 寫明 backport 涵蓋哪幾個函式、哪幾個不涵蓋與理由,正向見證加一臂 `btmgmt add-adv -s <31 B scan rsp>`。

**m10. `health.get` 的最壞延遲要算進 ≤ 10 s。** `ReadInfo` 與 `Read Advertising Features` 各自 2 s 逾時、各開一個 socket(`health.go:74-75`);mgmt 不回時 `health.get` ≈ 4 s + `/proc` 掃描;5 s 輪詢 + 4 s + D-Bus 往返 ≈ 9–10 s,剛好貼邊。寫明兩個 mgmt 查詢**並行**(各自 socket,RB3-4 已證無共用)或把輪詢改 4 s;L67 的斷言用 9.5 s 不要用 10 s。

**m11. 擠槽「排除交握中 < 10 s」+ 假路徑「等逾時才 Disconnect」= 走假路徑的路人連線在 10 s 內永不被擠。** BLE 空中單連線所以實務無差(設計已寫誠實界線),但 prov_test 的 sock + BLE 組合會讓一條 sock 假路徑連線佔 10 s 不可擠;寫一句「假路徑 session 視為可擠(它反正要斷)」或接受並寫明只影響 prov_test。

**m12. 文字 / 一致性:** §3 唯讀快取列「`ops` 連線重建後」失效 → 補 m5;§4.4「有連線建立(`Acquire*` 到來或 `Device1.Connected`)」→ 補 M2 的啟動盤點;§6「helper 契約…**單連線**」那列在 P2 後要改成「多連線 ≤ 4」並引 RB3-1;§1.2 F-P6 保留「今天」的描述但註明 P2 改掉;§9 helper 單元「第 5 條被關」加 m1 的 provd 重連情境;h23 `:392` `prov-boot-254`「斷線後新 nonce 重註冊」與 `:404` `ble-rpa-254` 的 `nonce=<8hex>` 要隨 §1.3 改(設計 §10 第 2 點只提到 `ble-rpa`)。

## 4. 我核過、成立的(§14 說修了、我確認真的修了)

| v2 發現 | v3 | 結果 |
|---|---|---|
| B2-B1 / A2-B1 單連線序列化 | helper 每連線 goroutine ≤ 4;provd `ctl` + `ops` | ✅ RB3-1 / RB3-2 / RB3-3:`serveConn` 自足、唯讀動詞無共享可寫狀態;L70 / L71 在新模型成立(RB3-19) |
| B2-M1 / A2-M1 `provclient` 連不上 | 第 3、4 條 | ✅(m1 補邊界) |
| B2-M2 / A2-M2 撕裂讀 + generation 失效 | helper 重讀 ≤ 3、provd 保留快取、`Generation` 失效 | ✅ RB3-5 / RB3-6;m4 補「失效到重拉之間用哪套」 |
| B2-M3 HELPER_WAIT 不關連線 | §4.3 | ✅ RB3-1(helper 側 Idle 在長動詞期間不武裝,連線確實不會被 helper 關) |
| B2-M4 / A2-M3 `IsTrial` exec、額度 | 快取 ≤ 5 s、每連線 5/s | ⚠️ 快取 ✅;額度**可用重連歸零**(M3);快取同步未寫(m6) |
| A2-M4 nonce 對消耗 | 回應後清掉 | ✅ RB3-7;helper 重啟時也要清(m5) |
| B2-m1 注入 e | 刪除,改 `Config.Random` | ✅ RB3-13 |
| B2-m2 假 msg2 的 `e_手機` | 前 32 B,不足補隨機 | ✅ |
| B2-m4 single-flight | §4.2 | ✅ |
| B2-m5 `compute()` + atomic latch | §4.3 | ✅ |
| B2-m6 kernel 第二寫者 | §3 廣播列 | ✅ RB3-9 |
| B2-m7 L10 兩段斷言 | L10 | ✅ |
| B2-m8 policy 補註 | §4.7 | ✅ RB3-17;8 條方法夠(provd 另只呼叫 DBus 的 Hello / AddMatch / GetNameOwner,default 放行) |
| B2-m9 / m10 冒充、608B 鎖 | §8 / §10 | ✅ |
| 假 msg2 等長 711、同 2 次 DH、等逾時 | §4.2 | ✅ 公式 `32 + 48 + len(cert) + 16` 對任意 cert 長度都對;真路徑 `ee`+`es` = 2 次 DH(RB3-13 `patterns`);msg1 長度檢查在 6 次試之前,長度是攻擊者自選、不洩秘密 |
| PSK 試法時序 | 6 個 state 各 `ReadMessage`、不 break | ✅ 6 次成本相同(MixHash / MixKey / 一次 AEAD);成功 / 失敗分支的差只在 `WriteMessage` 的兩次 AEAD 加密(µs 級)vs `crypto/rand` 679 B,`prov-sec-psk-timing-254` 覆蓋 |

## 5. 負對照盤點

| 防線 | 有 | 缺 |
|---|---|---|
| 多連線:長動詞期間 `health.get` ≤ 1 s | ✅ §9 helper 單元(負對照 = 今天的 Serve) | — |
| 第 5 條連線 | ✅ 被關 | provd 重連被拒 → 退避 → 恢復(m1) |
| 唯讀動詞額度 | 單連線 1000 次 mutant | **連線 churn mutant(M3)** |
| prov_test 目錄所有權 | — | 目錄 root 0700 → provd 拒 bind、`proxy` EACCES(M1) |
| provd 重啟時既有 LE 連線 | — | `prov-respawn-254` 新臂 + 04 btmon 見證 RB3-11(M2) |
| 不新鮮 → 撤廣播 | — | `kill -STOP` helper → ≤ 65 s 撤(m3) |
| `ctl` 單則逾時 | — | 假時鐘單元(m2) |
| gen 變 → 新集合到前仍用舊 PSK | — | `cache_test` 延遲臂(m4) |
| helper 重啟 → session nonce 對清掉 | — | 單元(m5) |
| kernel patch | adv 臂 | scan rsp 臂(m9) |
| ≤ 10 s 撤廣播 | L67 白箱 | 以 mgmt 2 s 逾時 ×2 的最壞情況算過(m10) |

## 6. 誠實界線

有寫且對:RPA 900 s;BLE 單連線被路人佔;ADV 自檢只擋自己;`adv_registered_once` 量 kernel;autocommit 只 WARN;被攻陷 provd 開滿 4 條、冒充、Discoverable 廣播;`model` fail-open;helper 重啟時 latch 時序。
要改:§4.3「新手機的 NXpsk0 交握可能逾時一次」→ m4 的真實情況;§8 第 7 列「唯讀動詞每連線 5/s」→ M3 之前不能寫成已擋;§4.4「最壞 ≈ 5 s + 一次往返」→ m10 加上 mgmt 逾時;L8 → M2;§3 prov_test 目錄 → M1。

## 7. 判定

**APPROVE-WITH-CHANGES** — 0 BLOCKER / 3 MAJOR / 12 MINOR。

地基這次是對的:我逐行核過 `sock.go` / `node.go` / `provstore.go` / `health.go` / `keystore.go`,多連線 helper + `ctl` / `ops` 兩條連線 + 唯讀動詞不取鎖在資料面安全(唯讀動詞只碰不變欄位與每次新讀的 record),撕裂讀只會以錯誤出現,HELPER_WAIT 不關連線在 helper 側成立,nonce 對規則與 helper 行為對齊,Noise / 假 msg2 / PSK 時序 / policy 都沒有剩下的硬傷。三個 MAJOR 都是「設計沒看到的一條路」而不是模型錯誤:prov_test 目錄所有權與 h23 相反且 471 建不了 socket(M1,會先被寫進 H3);provd 重啟時手機連線還在、kernel 不讓再開 connectable 廣播、BlueZ 不幫斷(M2,harness 每次 `set-provd-env` 都會踩);每連線額度用重連歸零(M3,負對照測不到)。依通用規則,MAJOR 開著就要改 v4 並整份再審一輪;v4 請同時把 04 的 RB3-11(控制器 le_states)補成實測,本輪 04 連不上、我沒有實機證據。
