# #254 PR-P2 `batman-provd` 設計 v1 — 對抗式審查 B

審查對象:`scratchpad/254-p2-impl.md` v1(全文 §0–§12)。審查方式:從現場情境出發(手機認領、10 台一隊、路人、被攻陷的 provd、root 操作員),每個假設對原始碼或 04 唯讀實查。04 只做了 `cat / ls / ps / logread / which / ujail -h`,**沒有**註冊任何廣播、沒有重啟服務。

## 0. 我自己查到的事實(設計未列或與設計不同)

| # | 事實 | 證據 |
|---|---|---|
| RB1 | `flynn/noise` v1.1.0:`HandshakeState` 全部欄位未匯出、無 Clone;`e` 在 **WriteMessage** 裡才產生(`GenerateKeypair`);NXpsk0 的 msg1 = `psk, e, payload`:`MixKeyAndHash(psk)` 後 `hasK=true` → payload 經 **AEAD**(`DecryptAndHash`→`Decrypt`),所以回應方在 msg1 就能判 PSK 錯;讀 msg1 **沒有任何 DH**。psk0 必須在 `Config.PresharedKey` 給值(`state.go:337-346`),否則 `willPsk=false` | `state.go:256-268, 317-360, 391-470, 503-615`;`patterns.go:39-45` |
| RB2 | NX 的 msg1 payload 是**明文**(`!hasK` → `MixHash` + 原樣回傳):一則 48 B 的 NXpsk0 msg1 丟給 NX 回應方,`ReadMessage` **成功**(16 B 當 payload),不會失敗 | `state.go:184-195, 598` |
| RB3 | 向量:`noise_nx.msg1` 32 B、`noise_nxpsk0_*.msg1` 48 B、三組 `msg2` 皆 **711 B** = e 32 + AEAD(s) 48 + node_cert 615 + tag 16;`fake_msg2_rule.length_equals_real_msg2 = 711` | `vectors.json`(python 計長) |
| RB4 | helper health tick 是 **15 s** 一次(`NewTicker(15*time.Second)`);`Node.Handle` 全程持 `n.mu`;`dispatch` 在 switch 前對**每個**動詞 `LoadOverlay`,無紀錄時只放行 `info.cert / info.ecdh_pub / info.boot_id / nonce`;`BootFinish` 先 `n.mu.Lock()` 再開 goroutine(Listen 照常進行,請求排隊) | `health.go:160-166`;`node.go:157-160, 207-212`;`wtxn.go:413-426`;`main.go:607-614` |
| RB5 | helper socket:每次 `Read` 前 `SetReadDeadline(now+30 s)`,到期 `return` 關連線;處理中無 deadline | `sock.go:146-170` |
| RB6 | dbus-daemon 1.14.10 啟動時 **unlink 既有 socket 再 bind**(`stat … S_ISSOCK → unlink(path)`) | `dbus-1.14.10/dbus/dbus-sysdeps-unix.c:1210-1212` |
| RB7 | 04 `/usr/bin` **沒有 `btmgmt`**(只有 bluetoothctl / bluetoothd);無 dbus-send、busctl | 04 `ls /usr/bin \| grep -i bt` |
| RB8 | BlueZ `dbus_error_to_att_ecode`:`org.bluez.Error.Failed` **沒帶數字訊息 → ATT 0x80**;帶 0x80–0x9f → 該碼;其他名稱 → `BT_ATT_ERROR_UNLIKELY`(0x0E) | `gatt-database.c:2214-2253` |
| RB9 | `AcquireWrite` / `AcquireNotify` / `ReadValue` options 都帶 `device`(物件路徑)、`link`、`mtu`(`bt_gatt_server_get_mtu`);ATT 斷線 → `att_disconnect_cb` → `io_shutdown` → provd 的 fd 收到 HUP;provd 關 fd → `sock_hup` 清 client_io | `gatt-database.c:2334-2370, 2570-2660` |
| RB10 | `Device1.Disconnect`(`dev_disconnect`→`device_request_disconnect`)**不會**把 device 設為非 temporary(設 temporary=false 的是 `device_block`,不是這條) | `device.c:2049-2064, 1839-1869, 1774` |
| RB11 | kernel:legacy 廣播在連線建立時由控制器停掉(`HCI_LE_ADV` 清掉,`hci_event.c:5640`),**斷線後 kernel 自己 `hci_enable_advertising`**(`hci_event.c:3421-3424`);RPA 只在 `rpa_valid()` 不成立(已過期)時才重算(`hci_sync.c hci_update_random_address_sync`:「Check if RPA is valid → return 0」);與 stage1 F28 一致 | 原始碼 |
| RB12 | system.conf 的 default policy 已放行 `send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus"`(Hello/RequestName/AddMatch 全在這個介面),並 **deny** `UpdateActivationEnvironment`、`Debug.Stats`、`systemd1.Activator`;既有 root policy 的 `<allow send_interface="org.bluez.GattCharacteristic1"/>` 等**沒有 destination 限制** | 04 `/usr/share/dbus-1/system.conf`;`bluetooth.conf` |
| RB13 | godbus v5.2.4:unix fd 在 auth 時自動 `NEGOTIATE_UNIX_FD`(`auth.go:96-107`),收 `UnixFD` / 送 `UnixFD` 都支援(`decoder.go:245`、`transport_unix.go:258-285`);`RequestName` / `AddMatchSignal` 走 `conn.busObj`(`org.freedesktop.DBus`);`prop.Export` 匯出 Properties;預設 handler 自帶 `Introspectable` | 原始碼 |
| RB14 | `ownerOpVerb`:`verb == "net.apply" && typ == "network/update"` → `netUpdate`(設計 §4.3 的 ⚠️ 成立) | `node.go:731-733` |
| RB15 | 04 現況:`/tmp/run/batman-prov` `drwxr-x--- root provd`、`helper.sock` `srw-rw---- root provd`;health 行 `adv_registered_once=0`;`/etc/batman-build` 0644;`/etc/capabilities/` 只有 ntpd / wpad 的 json | 04 `ls -la`、`cat` |

## 1. 發現

### BLOCKER

**B1. 假第 2 則長度公式錯 48 B,§3.4 MUST 的「不可分辨」直接破功。**
- 情境:路人對已認領節點送錯 PSK 的 msg1。設計 §4.2:假 msg2 = `e'_pub ‖ random(len(node_cert) + 16)` = 32 + 615 + 16 = **663 B**;真 msg2 = 32 + **48(加密的 s_node)** + 615 + 16 = **711 B**(RB3,向量 `fake_msg2_rule` 也寫 711)。路人只要比長度就知道自己 PSK 錯 vs 對,PSK 枚舉 / 「這台是不是我那隊的」探測全部回來;§8 整列「常數時間 6 把」靠的就是這條。
- 證據:設計 §4.2 原文;`vectors.json` 三組 msg2 = 711;`patterns.go:43`(msg2 含 `s`)。
- 修:假 msg2 = `e'_pub(32) ‖ random(48 + len(node_cert) + 16)`,並寫明「長度 = 以本次 node_cert 算出的真 msg2 長度」;`provd/noise_test` 的 `fake_msg2_rule` 必須斷言 `len(fake) == len(real msg2)`(真 msg2 由同一 node_cert 真跑一次取得),mutant = 拿掉 48 → FAIL。

### MAJOR

**M1. dbus socket 以「檔案」bind 進 jail → dbus 重啟後 provd 永遠連不回(L10 寫的恢復不成立)。**
- 情境:dbus-daemon respawn / 操作員 `/etc/init.d/dbus restart`。dbus 啟動時 unlink 舊 socket 再 bind 新的(RB6);jail 裡 `/var/run/dbus/system_bus_socket` 是舊 inode 的 bind mount → 每次 connect ECONNREFUSED,退避到 60 s 也一樣,直到 provd 被重啟(procd 不會,因為 provd 沒 crash)。節點從此無廣播、無管理面,而 health 的 `adv_registered_once` 已 latch 為 1 → autocommit 也看不出來。
- 證據:設計 §4.5 `procd_add_jail_mount … /var/run/dbus/system_bus_socket`;RB6;§5 L10「連線 EOF → 退避重連 → 同 L9」無測試。
- 修:改掛**目錄** `/var/run/dbus`(host 是 `/tmp/run/dbus` root 0755,RB15);同理 `/tmp/run/batman-prov` 已是目錄(正確,helper `PrepareDir` 在同一目錄 inode 內刪舊建新 → jail 看得到)。L10 補負對照:`/etc/init.d/dbus restart` → ≤ 60 s provd 重新註冊(無修法時永不恢復)。順帶:connect() 不需要 rw mount(VFS 的 `sb_permission` 對 socket 不檢查 RDONLY)— ⚠️ 未在 04 驗,實作時用 F-P3 的 jail 探法驗一次,能 ro 就 ro。

**M2. helper 單一 mutex + 新動詞走 `Handle` → 撤廣播 ≤ 10 s、STATUS 讀、第二條連線的 `psks.get` 在 helper 忙時全部卡死。**
- 情境 A:擁有者 A 的 `network/join` 在 helper 跑 `net.apply`(≤ 180 s + save)。此時 root 操作員開互動 bluetoothctl(bondable=1):provd 每 5 s 的 `health.get` 排在 mutex 後面 → 撤廣播要等 net.apply 結束(可達 3 分鐘),不是 ≤ 10 s。情境 B:同一期間隊友 B 的手機連上讀 `STATUS`(未交握就能讀):provd 要 `info.state` → 卡 mutex → ATT 交易 30 s 逾時 → B 的 link 被手機端斷。情境 C:B 送 msg1,provd 先 `psks.get`(設計:每條新連線交握前重拉)→ 卡住 → 10 s 交握逾時 → B 永遠連不上正在被設定的節點。情境 D:開機 `BootFinish` 持鎖 ≤ 120 s(RB4,goroutine 持鎖、Listen 照常)→ 同上,設計 L70 只寫了「無廣播」,沒寫 STATUS / 交握也死。
- 另:`dispatch` 在無可用紀錄時只放行 4 個動詞(RB4)→ `health.get` / `adv.registered` / `info.owners` 若不加進放行名單,fresh / 無紀錄節點永遠拿不到 health → 永不廣播(fail-closed 但是錯的原因)。
- 證據:`node.go:157-160, 207-212`;`wtxn.go:413-426`;設計 §4.3 連線模型(單一 FIFO 連線)、§4.4 每 5 s `health.get`、§4.1 STATUS 由 `info.state` 組。
- 修:(1) `health.get`、`adv.registered`、`info.boot_id` 在 `Handle` 內**不取 `n.mu`**(health 行本來就是另一個 goroutine 的產物,用 atomic / 自己的小鎖);(2) provd 把 STATUS 的輸入(state、trial、末 4 碼)快取並標新鮮度:交握前 `info.state` 失敗 / 逾時 ≤ 2 s 就用快取(state 只會在 helper 的狀態改變動詞後變,而那些動詞都經 provd 自己 → provd 知道何時失效);(3) `psks.get` 同樣快取,只在 provd 自己送過 `claim.*` / `net.apply` / `network.leave` / `root_password.reset`(密碼不影響 PSK,可省)後才失效,而不是每條連線重拉;(4) 新動詞加進 `dispatch` 的無紀錄放行名單;(5) L70 改寫並加測試:helper 持鎖 120 s 期間 STATUS 可讀、交握可完成(負對照 = 不做 (1)(2)(3) 時 ATT 逾時)。

**M3. 「≤ 10 s 撤廣播」在 health 15 s tick + 5 s 輪詢 + 行內快取的設計下本來就做不到(即使沒有 M2)。**
- 情境:bondable 在 t=0 變 1;helper 下一次 tick 最晚 t=15;provd 下一次輪詢最晚 t=20 → 撤廣播最晚 t≈20 s;`prov-boot-254` 的「≤ 10 s」斷言在最壞情況 FAIL,平均也只有一半機率過。
- 證據:RB4 15 s;設計 §4.3 `health.get` 回「上一次 tick 的那一行…不重讀檔」;§4.4「每 5 s `health.get`;任一欄轉壞 → ≤ 10 s 內 Unregister」。
- 修:`health.get` 直接現算(READ_INFO 是一個 mgmt 往返,便宜;`Tick` 已可重用,但不要每次寫檔),或 helper tick 改 5 s,或把承諾改成 ≤ 25 s 並同步改 stage1 §8 / h23 `prov-boot-254`。三選一,但不能三者都不改。

**M4. helper 30 s 閒置關連線 + 「佇列不重送」= 每次閒置後第一個請求有系統性的假 `E_BUSY`,而且打中的是 provd 自己的 `psks.get` / `info.state`。**
- 情境:節點閒 30 s 後手機連上。provd 送 `psks.get`(交握前)或 `info.state`(STATUS)時正好 helper 的 `SetReadDeadline` 到期關連線(RB5):SEQPACKET 寫成功、讀到 EOF → 設計:`E_BUSY` 回手機、不重送 → 交握失敗或 STATUS 讀錯,使用者重試才過。這不是極端情況:30 s 閒置在現場是常態(手機連線間隔),每次連線都踩在這個邊界附近。
- 證據:`sock.go:146-152`;設計 §4.3「helper 30 s 無請求會關連線 → provd 收到 EOF 就重連…佇列中的請求不重送(非冪等…)直接以 `E_BUSY` 回手機」。
- 修:動詞分冪等 / 非冪等:`info.*`、`health.get`、`psks.get`、`adv.registered`、`sign.*`(只是重簽)在 EOF-無回應時重連後**重送一次**;只有 `nonce`、`claim.verify`、`claim.replay`、owner-op 動詞回 `E_BUSY`。另加 keepalive(閒置 ≥ 20 s 送一個 `info.boot_id`)把窗口關掉。單元測試:假時鐘在第 30 s 邊界注入 EOF → 冪等動詞成功、非冪等回 7。並定義 `HELPER_WAIT` 超時後的連線處理:**關掉重連**(不是留著等遲到的回應),或回應以 `id` 配對丟棄遲到者;設計目前兩者都沒寫。

**M5. `adv_registered_once` 由 uid 471 的 `adv.registered` 自報 → autocommit 的 BLE 判定變成信任非特權行程。**
- 情境:provd 有 bug(RegisterAdvertisement 回成功但 BlueZ 之後 `Release` 了它)或被攻陷:呼叫一次 `adv.registered` → health 行永遠 1 → trial 槽上 BLE 實際不通也 commit。stage1 §3 說 health 行是「唯一 health 契約」且寫者是 helper;本設計把其中一欄的**真值來源**搬到 471,這是 §3 擁有權表沒承認的信任邊界跨越(表上寫「唯一寫者 helper」,但值由 provd 決定)。
- 證據:設計 §3 health 列、§4.3 `adv.registered`「無授權」。
- 修:helper 自己觀測:health tick 已經打 mgmt `READ_INFO`,再打一個 `Read Advertising Features`(0x003D,回 `num_instances` 與 instance 列表)→ `adv_registered_once` = 本次開機曾看過 ≥ 1 個 instance(helper 行程內 latch;helper 重啟後下一個 tick 就重新看到,L11 不再需要 provd 配合)。刪掉 `adv.registered` 動詞。負對照:root `bluetoothctl advertise off`(撤掉 provd 的 instance 不可能;改用停 provd)→ latch 仍 1(設計意圖),但「provd 從未成功註冊」→ 0(今天的設計做不到這個區分)。

**M6. kernel patch(D3)的正向見證用 `btmgmt add-adv`,節點上沒有 `btmgmt`。**
- 情境:`prov-sec-adv-len-254` 臂 2 在 04 跑 → 命令不存在 → 單位 FAIL 或(更糟)寫成「找不到就 SKIP」。
- 證據:RB7;設計 §4.8、§9。
- 修:-wbox 變體多裝 `bluez-utils` 的 `btmgmt`(release 不裝;gate 擋),或臂 2 直接用 F-P9 的 `bluetoothctl advertise` 配方(有 patch 時應不 panic;要寫明「若 patch 無效會 panic 04,只在 bench 角色、trial 槽上做,且先確認 pstore 乾淨」),或 harness 自帶一個 root 的 mgmt-socket 小工具。不能留一個節點上跑不了的測試。

**M7. RPA 敘述不實:「所有連線結束 → 重新註冊(新 RPA)」、`reason=disconnect`;kernel 只在 RPA 過期後才換。**
- 情境:路人在 t=100 s 看到 RPA X,手機連線、斷線,t=200 s 再看 → 還是 X(RB11;stage1 F28 自己也這樣寫)。設計 §4.4 / §8 的「RPA 每次連線結束換」是假的隱私承諾;而且 kernel 在斷線後**自己**會重開同一 instance(`hci_event.c:3421-3424`),provd 「連線即撤、斷線重註冊」在沒有 B16 nonce 的階段 1 **沒有任何隱私收益**,只剩「同時只接一條 BLE」這個效果。
- 修:§4.4 / §8 改寫:RPA 只在 `rpa_timeout` 到期後的下一次(重)啟用才換;連線即撤的理由改成「單一連線 / 不讓 kernel 自動重開」;`ble-rpa-254` 三態的第二態(< 900 s 重註冊 → 同 RPA)就是這個事實的測試,保留。誠實界線加一句:同一次 900 s 窗內,連線前後的 RPA 相同。

### MINOR

**m1. NX 模式收到 48 B msg1 不會「解不開」。** 設計 §4.2「未認領 / legacy 節點收到帶 PSK 的第 1 則 → 解不開 → 假第 2 則」錯:NX msg1 payload 明文,`ReadMessage` 成功(RB2),provd 會送**真** msg2。無安全損失(node_cert 對未認領節點本就公開),但協定 §3.1「第 1 則 payload 一律為空」沒人執行。修:provd 在交握前驗 msg1 長度:NX 必須 = 32、NXpsk0 必須 = 48,否則 Disconnect(NX)/ 走假第 2 則(NXpsk0)。單元向量兩例。

**m2. 「6 把 PSK 用同一把臨時 `e` 的 HandshakeState 副本」做不到也不需要。** `HandshakeState` 無法複製(RB1),`e` 在 WriteMessage 才產生;讀 msg1 沒有 DH。正確寫法:6 次 `NewHandshakeState(Config{Pattern: HandshakeNX, PresharedKey: k_i, PresharedKeyPlacement: 0, StaticKeypair: s_node, Prologue: p})` + 6 次 `ReadMessage`,全跑完再選;成本 6×(HKDF + AEAD open),沒有 DH。改字即可;但 §9「常數時間(測計數器)」要改成計 `ReadMessage` 呼叫次數 = 6。

**m3. STATUS 回 ATT `0x0E` 的方法沒寫對。** 回 `org.bluez.Error.Failed` 不帶數字 → BlueZ 送 **0x80**(RB8);要 0x0E 得回一個不在表上的錯誤名(例如 `org.bluez.Error.Failed` 帶 `"0x0e"` 會印 `Invalid error code` 到 bluetoothd log 再回 0x0E — 每次都刷一行 error)。建議直接回 `org.freedesktop.DBus.Error.Failed`(不在表 → UNLIKELY,不刷 log),寫進契約。

**m4. dbus policy 多餘且過寬的一行。** `<allow send_destination="org.freedesktop.DBus"/>`:default policy 已放行 `org.freedesktop.DBus` 介面(Hello / RequestName / AddMatch 全在這)並 deny `UpdateActivationEnvironment` 等(RB12);user policy 優先於 default,整行 allow 會把那三個 deny 翻回來。刪掉即可(godbus 只呼叫 `org.freedesktop.DBus` 介面,RB13)。`<allow receive_sender="org.bluez"/>` 多餘(default 允許所有 receive)。root policy 的 5 行回呼 allow 也多餘:既有 `<allow send_interface="org.bluez.GattCharacteristic1"/>` 等沒有 destination 限制,bluetoothd 本來就能呼叫 provd;`org.batman.provd` 的 own 若只是為了這個,可刪(少一個名字 = 少一個被攻陷 provd 能「宣稱」的東西);若留,請把理由改成真正的理由。

**m5. jail 掛載清單含不需要的檔案。** 靜態 Go 二進位不讀 `/etc/passwd` / `/etc/group`(user lookup 不會發生)、不需 `/lib/ld-musl`;每一個 `-r` 都是攻擊面(bluetoothd 的 D-Bus 回呼解析錯誤若能讀檔…)。設計已說 ld-musl 實作時拿掉;passwd / group 也拿掉,留 `/etc/batman-build`、`boot_id`、dbus 目錄、helper 目錄四項。

**m6. `HELPER_WAIT` 330 s 與 FIFO 的收尾沒定義**(見 M4 修法):超時後連線上還有一個遲到回應,下一個請求的回應會錯位;要麼以 `id` 配對、要麼關連線重連。

**m7. 生命週期矩陣缺列。** (a) `hci0` 整次開機不出現(BT 韌體缺 / serdev 沒綁):health `hci0_powered=0` → provd 永不註冊、STATUS 不存在、helper 照常 → autocommit 無 `ble-ok` 時 WARN;寫出來。(b) adapter 熱移除 / 重加(`InterfacesRemoved/Added /org/bluez/hci0`):provd 的 adv / app 物件在 BlueZ 端消失,需重 Register;設計只處理 `NameOwnerChanged`。(c) OTA 寫另一槽時 session 開著:helper `otaBusy` → `E_BUSY`;sysupgrade 重開 → 所有 session 斷,手機重連看 `unfinished`;寫一列並指向既有測試。(d) L10 無測試(見 M1)。

**m8. BLE 同時連線事實上只有 1 條。** legacy 廣播在連線時由控制器停掉、provd 又主動撤 → 第二支手機連不上;「≤ 2 連線」只有 BLE + sock(prov_test)能達到,`prov-two-phones-254`(L24)在 BLE 空中做不到,只能 sock+sock / sock+BLE。設計要誠實寫:**一個路人連上並拖 10 s(假 msg2 等逾時)、斷、再連,就能讓節點的管理面對隊友不可用**;20/分 交握上限擋不住(每分 6 次就夠)。這是 BLE 周邊角色的固有限制,但 §8「佔連線」那列現在寫得像有兩個槽。

**m9. `psks.get` 回 `adv_owner` / `adv_member`(key 4/5)給 P2 的 provd,但 B16 不在階段 1** → provd 拿到用不到的秘密。helper 加參數或 provd 收到即丟並寫在誠實界線;最好 helper 在 P2 不回 4/5(減少被攻陷 provd 的戰果)。

**m10. `auth/owner` 由 provd 驗,與 stage1 §4.1「helper 驗所有授權」字面衝突。** 實際可接受(角色只是 provd 的本地狀態,每個改變節點的請求仍帶 helper 驗的 owner-op),但要在 §1.3 明寫這個偏離與理由,並說明 `owner_key_id` 如何對應 `info.owners` 回的公鑰(SHA-256 前 N 字節?協定定義在哪)。

**m11. 簽章額度。** stage1 §4.1:`sign.*` 每條連線 0.5/s、全域 2/s;provd 啟動要連簽兩次(`sign.static` + `sign.ecdh_proof`)→ 第二次可能被額度打回。⚠️ 我沒讀 `node.go:333 sign()` 有沒有真的實作每連線額度;設計說「全域 2/s 不是問題」沒提每連線 0.5/s。實作前查,或兩次間隔 2 s。

**m12. release gate 只掃 provd 二進位;`provd.env` 的讀取在 init(shell)。** 若 init 檔兩種 build 共用,release image 也會「讀 provd.env」(只是 provd 不認那些變數)。要麼 init 也分變體,要麼 gate 對 `/etc/init.d/batman-provd` 也 grep `provd-test` = 0。

**m13. 文字錯誤。** §4.5「停止順序:provd K10 → bluetoothd K20 → helper K15?——」殘句;§4.3 錯誤碼對應段前半(「20 ESchema → E_UNKNOWN_TYPE 若 type 不在表內,否則 E_FORBIDDEN…精確表」)自相矛盾,只留精確表;§1.3「NX 與 NXpsk0 的第 1 則格式相同」→ 長度不同(32 vs 48)。

## 2. 負對照盤點(設計宣稱的防線 vs 有沒有「拿掉就 FAIL」的測試)

| 防線 | 有 | 缺 |
|---|---|---|
| 假 msg2 不可分辨 | timing 單位、`fake_msg2_rule` 單元 | **長度 = 真 msg2**(B1);msg1 長度檢查(m1) |
| health 轉壞 ≤ 10 s 撤 | `prov-boot-254` 白箱 | 在 helper 忙(net.apply / BootFinish)期間的同一斷言(M2) |
| dbus 重啟後恢復 | — | 全缺(M1) |
| 30 s 閒置邊界 | — | 假時鐘單元(M4) |
| `adv_registered_once` 真值 | `prov-provd-dos-254`(provd 死 → 仍 1) | 「provd 從未註冊成功 → 0」(M5) |
| kernel patch 正向 | 臂 2 | 節點上跑得動的工具(M6) |
| STATUS 錯誤碼 | — | 單元:helper 不可達 → 回的 D-Bus error 名稱 → 預期 ATT 碼(m3) |
| ADV 長度自檢 | `ADV_LEN_TEST` | ✅ 足夠(只保護自己,設計誠實) |
| dbus policy 收窄 | `prov-sec-dbus-254` | 加 `UpdateActivationEnvironment` → AccessDenied(m4 修後成立) |
| 第 3 條連線 Disconnect | `prov-sec-hog-254` | 只能 sock 做;寫明(m8) |

## 3. 設計有沒有誠實寫出它不處理的事

有寫:F29 穩定識別、D5(連線才知 unclaimed)、ADV 自檢只擋自己、被攻陷 provd 能讓 kernel panic、`capabilities` 固定、B16 / idem / P3 類型。
沒寫或寫錯:RPA 在同一 900 s 窗內連線前後相同(M7);BLE 實際單連線 → 一個路人就能佔住管理面(m8);health 的 BLE 欄位信任 471(M5);`psks.get` 多給 provd 兩把用不到的秘密(m9);dbus 重啟後的失效(M1)。

## 4. 核對設計請審查員確認的幾點

- godbus `RequestName` / `AddMatch` 都走 `org.freedesktop.DBus` → **是**(RB13);且 default policy 已放行,provd policy 不必再寫(m4)。
- `node.go:716 ownerOpVerb` 以信封 type 分流 `network/update` → **是**(RB14)。
- godbus unix fd passing → **支援,自動協商**(RB13);`AcquireWrite` 回 `(fd, mtu)` 需 provd 建 socketpair 回其中一端,BlueZ 端斷線會 `io_shutdown` → provd 讀到 EOF(RB9)。
- prologue sock 用 `"ble"` → 與向量一致(向量只有 `ble`)。
- `Device1.Disconnect` 對連著的 device 物件可達,且不會把 device 變永久(RB10)。

## 5. 判定

**REJECT**(窄):1 BLOCKER(B1 公式)、7 MAJOR。B1、M6、M7 是改字 + 改一個單元斷言;M1 是改一行掛載;M2–M5 要動 helper 的 `Handle` / health / 連線模型,屬設計層。全部修完後請整份再審(不是只看 diff),特別重看 §3 擁有權表(M5)與 §5 矩陣(M1、m7)。
