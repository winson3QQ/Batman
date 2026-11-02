# #254 PR-P2 `batman-provd` 設計 v1 — 對抗式審查 A

審查者 A,2026-10-31。範圍:整份 `254-p2-impl.md` v1,對照 `254-stage1-impl.md`、`254-h23-harness.md`、`219-protocol.md` v0.7 / CDDL、`254-wireless-txn.md` §19、helper 原始碼(main @ 34f216d)、BlueZ 5.72 / kernel 6.6.138 build 樹原始碼、`flynn/noise` v1.1.0、`godbus/dbus/v5` v5.2.4、04 唯讀探查(未碰廣播)。

## 0. 我自己驗過的事(✅ 原始碼 / 實機;設計可以把 ⚠️ 升級)

| 項 | 證據 |
|---|---|
| `network/update` 真的走 `net.apply`:helper 在 owner-op 驗證**之前**以信封 type 分流到 `netUpdate`(無 owner-op、不查 owner) | `node.go:735-736` |
| `network/leave` → `network.leave`、`ssh_keys/set` → `ssh_keys.set`、`root_password/reset` → `root_password.reset`、owner-op 動詞都收 `{1: h, 2: 原始信封}` | `node.go:716-733` `want` 表、`onlyKeys(a,1,2)` |
| `claim.replay(h, 原始信封)` 契約成立 | `node.go:570-600` |
| F-P9 panic 機制成立:`eir_create_adv_data` 在 `!HCI_BREDR_ENABLED` 無條件加 3 B Flags 再 `memcpy` 31 B,目標是 `hci_cp_le_set_adv_data.data[31]`(stack);`tlv_data_max_len` 只在 DISCOV/LIMITED/MANAGED 才扣 3;BlueZ `calc_max_adv_len` 同樣 | `eir.c:245-300`、`mgmt.c:8498-8512`、`hci_sync.c:1331-1340`、`advertising.c:780-797` |
| F-P10 成立:`client->scan` 只被 `bt_ad_add_name` 寫 | `advertising.c:833-846`;`grep client->scan` 只有 145/843/845/857/1559/1563 |
| `Discoverable=false` 的 ad 不加 Flags AD(`flags=0x00` → `set_flags`),adapter 不 discoverable → 只有 CONNECTABLE | `advertising.c:747-778, 873-883` |
| 04 控制器無 ext adv(`SupportedSecondaryChannels` 缺)、`Pairable: no`、`Discoverable: no`、`ActiveInstances 0` | 04 `bluetoothctl show` |
| `flynn/noise` 支援 `PresharedKeyPlacement: 0` + `PresharedKey`(psk0 把 PSK token 插在第 1 則最前),`Config.EphemeralKeypair` 可注入同一把 `e`,`ReadMessage` 失敗 `Rollback()`;`ChannelBinding()` = `h` | `state.go:316-357, 503-612, 617` |
| godbus **可在方法回覆帶 fd**(`UnixFD` 回傳值 → `CountFds` → `SCM_RIGHTS`),fd 協商在 auth 自動開 | `transport_unix.go:258-280`、`auth.go:96-107`、`dbus.go:335` |
| godbus **沒有 ObjectManager 實作**(只有 `prop`、`introspect`)→ provd 自己匯出 `GetManagedObjects`(GATT app 根必要;ad 物件只需 `Properties.GetAll`,GDBusClient 對 `GetManagedObjects` 錯誤容忍) | `grep -rn ObjectManager godbus` 空;`gdbus/client.c:1209-1234`、`advertising.c:1532-1550` |
| procd:`jail` + `user` → procd **不**自己 setuid,改傳 `-U/-G` 給 ujail;`capabilities` → `-C`;`no_new_privs` → `-c` | `instance.c:321-337, 541-549` |
| `bounding: []` → 全部 cap 從 bounding set 丟掉 | `capabilities.c:88, 131-141` |
| 04:`/tmp/run/batman` root 0700、health 檔 0600;`helper.sock` 目錄 0750 root:provd、socket 0660;`/etc/batman-build` 0644;`/proc/sys/kernel/random/boot_id` 0444;`procd_add_jail*` 存在;`/etc/capabilities/` 有 ntpd/wpad 範本 | 04 `ls -la`、`grep /lib/functions/procd.sh` |
| dbus `system.conf` default context:`deny own=*`、`deny send_type=method_call`、allow 收 / signal / reply、**已經 allow `send_destination=org.freedesktop.DBus` 的 `org.freedesktop.DBus` / Introspectable / Properties 介面**(並 deny Monitoring / UpdateActivationEnvironment) | 04 `/usr/share/dbus-1/system.conf:44-82` |
| autocommit 今天對 BLE health 只 WARN、不擋(P-U5) | `batman-autocommit:507-510` |

## 1. BLOCKER

無。

## 2. MAJOR

**M1. `claim/finish` → `claim.verify(h, 原始信封)` 與 helper 契約不符。**
情境:provd 照 §4.3 把整個信封塞進 `claim.verify` 的 key 2 → helper 回 `ESchema`,認領永遠失敗。
證據:`node.go:501-516` `claimVerify` 收 **5 個拆好的欄位** `{1: h(32), 2: response(32), 3: owner_pub(65), 4: owner_enc_pub(65), 5: sig_enc(64)}`,`onlyKeys(a,1,2,3,4,5)`;stage1 §4.1:163-166 也是這個簽名。`owner_pub` 來自同 session 的 `claim/begin`。
後果:§4.3「provd 不解 body」對 `claim/finish` 不成立——provd 必須解 `claim/finish` body 的 1/2/3 並附上 `claim/begin` 存的 `owner_pub`(這是 stage1 既定:helper 以「即將寫入的 owner_pub」重算 ClientChal,換 owner_pub 會 CheckMac 失敗,所以安全上無害)。
修:§4.3 表改為 `claim.verify(h, resp, owner_pub_session, owner_enc_pub, sig_enc)`;§1.3 / §4.3 的「原封不動」改成「owner-op 動詞與 `claim.replay` 原封不動;`claim.verify` 拆欄位」;Go `route_test` 加這條。

**M2. 錯誤碼對應表錯了三處,影響 app 的恢復流程。**
證據:helper 碼 `node.go:34-48`:`EForbidden 3, EBadObject 4, EStaleVersion 5, EUnsupported 6, EBusy 7, EStorage 10, ERate 12, ESchema 20, EApply 21, EState 22, ELockIncomplete 23`。協定 §5.2:`E_LOCK_INCOMPLETE = 13`。
(a) 設計寫「`13` → 13」且 claim/finish 列寫「成功(code 0 或 23)」:helper 送的是 **23**,表裡沒有 23 → 落到「其他 → 11 E_REJECTED」→ app 不會走 `claim/replay`(claim-lock fix 的整條恢復路徑斷掉)。必須 **23 → 13**。
(b) 表沒有 **4 → 4(E_BAD_OBJECT)**、**5 → 5(E_STALE_VERSION)**:`netUpdate`/`netJoin` 會回它們(`node.go:1014, 1062, 1077, 1086`),協定 §5.3 明寫「沒有網路時的 `network/update` → `E_STALE_VERSION`」;「其他 → 11」把它們吃掉。
(c) 「`9`(EClaimFailed)→ 9」:helper **沒有** 9。CheckMac 失敗回 `EForbidden 3`(`node.go:104, 107`),協定要 `E_CLAIM_FAILED 9`。provd 必須**按動詞**對應:`claim.verify` 的 3 → 9(並計入 3 次/連線);其他動詞 3 → 3。另 `claim.verify` 的 `EUnsupported("no-ssh-key")` → 協定要 `E_UNSUPPORTED(capability=claim, reason=10)`,provd 要補 body。
修:寫成 per-verb 精確表 + Go 單元(每格一個 mutant)。

**M3. 擁有者重取(replay)流程:兩次 `nonce(h)` 會讓 `claim.replay` 失敗。**
情境:app 在 `psk_replay` session 依協定 §3.5 送 `claim/begin`(provd → `nonce(h)` #A)再 `op/nonce`(provd → `nonce(h)` #B),以 A.node 算 response、B.helper 簽 owner-op。helper `claimReplay` 先 `takeNodeNonce(h)` = **最新未用的 node 半 = B.node**(`node.go:186, 309-320`)→ CheckMac 用 B.node 對 A.node 的 response → 失敗、計入 10/h。
證據:`node.go:181-192` 註解「One `nonce` call now serves both: node half → CheckMac, helper half → owner-op」;`provclient main.go:579` 同樣「one nonce gives both」。只有 app 先 `op/nonce` 再 `claim/begin` 才會碰巧過。
修:provd 對 replay 角色把 `claim/begin` 與 `op/nonce` 服務自**同一次** `nonce(h)` 回應(快取該 pair,任一半被用掉才重拉),或在 219 v0.8 明定順序與 helper 一致;`prov-ble-claim-254` / Go 單元用「begin → op/nonce → replay」順序當負對照。

**M4. 假第 2 則長度錯(協定 §3.4 MUST)。**
證據:§4.2 寫「送 `e'_pub ‖ random(len(node_cert) + 16)`」= 48 + len。真實 NXpsk0 第 2 則 = `e`(32)+ `enc(s)`(32 + 16)+ `enc(payload)`(len + 16)= **96 + len**(`patterns.go:39-45` NX 第 2 則 `E, DHEE, S, DHES`;向量 `fake_msg2_rule.length_equals_real_msg2 = len(m2p)`,`gen.py:582-587`)。短 48 B = 一眼可辨的 PSK 錯誤 oracle。
修:`random(len(real_msg2) − 32)`;`noise_test` 斷言 fake 長度 == 向量值(拿掉就 FAIL)。

**M5. helper 單一連線 + `Handle` 全程持 `n.mu` → 一個 `net.apply`(≤ 180 s)期間 provd **所有** helper 往返都被堵住;設計沒處理。**
情境(現場,10 台隊伍):擁有者手機 A 對節點送 `network/join`;隊友手機 B 同時連上同一台讀 `STATUS`(provd 在 `ReadValue` 裡同步呼 `info.state`/`info.cert`)→ 被 mutex 擋 ≥ 數十秒 → BlueZ ReadValue D-Bus 逾時 → B 端 ATT 30 s transaction timeout → **B 被斷線**;同理 B 的交握前 `psks.get` 卡住 → 10 s 交握逾時 → Disconnect;provd 每 5 s 的 `health.get` 排隊 → 「health 轉壞 ≤ 10 s 撤廣播」保證失效;`HELPER_WAIT` 330 s 沒問題但佇列裡堆 36 個 `health.get`。L70(BootFinish ≤ 120 s)同樣。
證據:`node.go:157-159` `Handle` 先 `n.mu.Lock()`;`sock.go:108-115` 一次只服務一條連線;`main.go:614` BootFinish 持 mutex。
修:(a) STATUS / CTRL 從 provd 快取回(每 5 s 隨 `health.get` 一起刷新 `info.state`;helper 不可達才 ATT 錯);(b) `psks.get` 快取 + 事件失效(認領成功 / `info.state` generation 變)而不是每連線重拉;(c) 新動詞 `health.get` / `adv.registered` 在 helper 端**不取 `n.mu`**(獨立 handler,只碰 health 的原子值);(d) 把「一則請求進行中時 `health.get` 延遲 ≤ 180 s」寫進契約與 `prov-boot-254`。

**M6. 生命週期 L6 / §8 把 autocommit 寫成會因 BLE revert,與現況與 F-P16 自相矛盾。**
證據:`batman-autocommit:507-510`:`ble-ok` 在而 health 不好 → **只 log `WARN ble:`,not blocking (P-U5)**;F-P16 也這麼寫。但 L6 寫「provd 不起 → UNHEALTHY → revert(設計意圖)」、§8「讓 provd crash → revert 好 image」、§6.4 (8) 兩臂當測試。P2 元件表(§2)沒有改 autocommit。
後果:L6 的測試會 FAIL by design;審查者/實作者會以為有一道不存在的防線。
修:L6 / §8 改為「WARN、不 revert(P-U5)」,或把「WARN → FAIL」列為 P2 範圍並改 autocommit + 寫負對照;二擇一並回報 stage1 §6.4 / h23。

**M7. RPA 不會在每次連線結束換;§4.4 / §8 的隱私主張錯,且與 h23 `ble-rpa-254` 三態矛盾。**
證據:`hci_core.h:1865` `rpa_valid(dev) = bacmp(rpa, ANY) && !HCI_RPA_EXPIRED`;`hci_sync.c:1093-1118` `hci_update_random_address_sync`:RPA 有效就 `return 0`(不產新);`HCI_RPA_EXPIRED` 只由 `rpa_expired`(900 s,`mgmt.c:1016-1029`)與 dev open(`hci_sync.c:5140`)設。重新註冊 < 900 s → 同一個 RPA;h23 §6.3 `ble-rpa-254` 寫的三態是對的。
後果:§8「RPA 每次連線結束 / 900+ s 換」→ 連線結束**不換**;「連線即撤 / 斷線重註冊」只剩「不被同一 payload 串起」的意義(現在 payload 固定,連這個都沒了)。
修:§4.4 的 `reason=disconnect` 不要寫「新 RPA」;§8 改為「RPA 只在 ≥ `rpa_timeout` 後的重新啟用換;重註冊是讓 kernel 有機會換」;log 契約與 h23 對齊。

**M8. 連線槽沒有協定 §8 的「未認證 session 可被新連線擠掉」→ 現場認領可被兩個路人長期佔滿。**
情境:未認領節點,攻擊者 2 條連線各做 NX 交握(任何人都能)、每 < 30 s 送一則 `info` 保持活著 → 擁有者第 3 條「立即 Disconnect」,永遠進不來;20/分的交握額度也被他用。協定 §8 定義「未認證 / 候選閒置 30 s,**且可被新的連線擠掉**」正是為此;stage1 §4.1:178 承認「兩個路人可佔滿」但那是對已認證額度說的。
修:第 3 條連上時若有未認證 / 候選 session → 擠掉最舊的那條(Disconnect 它),再服務新連線;只有兩條都已認證才拒新連線;`prov-sec-hog-254` 加「2 條匿名佔著,第 3 條(合法)仍能交握」的臂與負對照。

**M9. `prov-sec-adv-len-254` 臂 2 與 §4.8 白箱用 `btmgmt add-adv`,但節點沒有 `btmgmt`。**
證據:04 `/usr/bin` 只有 `bluetoothctl`、`bluetoothd`;`opkg` 只有 `bluez-daemon`、`bluez-libs`(board patch 0012 砍成最小)。h23 §6.3 `ble-rpa-254` N1 也引用 `btmgmt add-adv`。
修:(a) `-wbox` 變體加回 `btmgmt`(release gate 斷言 release 無);或 (b) 臂 2 用互動 `bluetoothctl advertise`(= F-P9 的觸發法)在 patch 後的 kernel 上重做,並把「這是刻意的第二寫者、只在 wbox」寫進 runbook 例外。設計要選一個並更新 h23。

**M10. init 沒有 `requirejail`:ujail 不在 / jail 建不起來時 procd 靜默改成不 jail 直接跑。**
證據:`instance.c:1459-1470`:`stat(/sbin/ujail)` 失敗且 `!require_jail` → `has_jail=false`、只 `P_DEBUG`;之後走 `instance.c:541-549` 的 setuid 路徑(有 `user` 所以仍是 471,但無 mount namespace、無 `-C`、無 `-c`、看得到整個 `/`、`/proc`、`/sys`)。`procd_add_jail` 有 `requirejail` 選項(`procd.sh:199`)→ `-E` 且缺 ujail 即不啟動。
修:`procd_add_jail batman-provd log requirejail`;§5 加「ujail 缺 → provd 不啟動、health 不受影響」;負對照 = 改名 ujail 後 `service start` → 不起。

**M11. `adv_registered_once` 的真值來源變成 provd 的自述。**
今天這欄是 health 契約裡唯一「BLE 真的在廣播」的證據;設計讓 provd 呼 `adv.registered` 後 helper 無條件 latch。helper 本來就有 mgmt socket(`health.ReadInfo`),可以自己讀 `MGMT_OP_READ_ADV_FEATURES` 的 `num_instances`。
情境:provd bug(RegisterAdvertisement 的回覆解析錯、或在 BlueZ 回錯誤後仍呼)→ health 寫 1 → autocommit(未來若 FAIL)或 F12 被騙;攻陷的 provd 可任意設 1。
修:`adv.registered` 改為「helper 收到後以 mgmt `READ_ADV_FEATURES` 驗 `num_instances ≥ 1` 才 latch,否則回 `EState` 並 log」;負對照:provd 不註冊只呼 `adv.registered` → health 仍 0。

**M12. 分塊請求打破「原封不動轉送」契約,設計未定義重組後送什麼。**
證據:協定 §5.1 分塊的每則信封 `3` 是 **bstr 片段**;helper `decodeEnvelope` 要求 `3` 是 **map**(`node.go:655-659`),收到片段即 `ESchema`。所以 provd 對分塊請求必須**重組出一個完整信封再編碼**(deterministic,否則 helper 拒)——不是 bytes 原封不動。`network/join` 的 `net_config + member_list + net_secrets`(10 人隊伍)可能超過 8176 B,階段 1 就會碰到。
另:`decodeEnvelope` 上限 65536、socket `MaxRequest` 65536(`sock.go:140-148`,超過**直接關連線**,不回碼):8 × 8176 = 65408 + `{1: h, 2: bstr}` 包裝 ≈ 45 B = 65453,剛好擠進去;設計要把這個算式寫下來,並在 provd 以 `len(envelope) ≤ 65408` 為硬限,超過回 `E_UNSUPPORTED` 不送 helper(否則 helper 關連線 → 所有排隊請求 E_BUSY)。
修:§4.3 寫明「分塊 → provd 重編 `{0,1,2,3,(7)}`(不含 6)deterministic 後送;`args_hash` 不受影響因為它只蓋 body」;`frame_test` 用向量 `chunking` 斷言重組後 bytes == 原始未分塊信封。

## 3. MINOR

**m1.** §4.2「NX 與 NXpsk0 的第 1 則格式相同」不對:NX 第 1 則 = `e` 32 B(明文空 payload);psk0 第 1 則 = `e` + AEAD(空)= 48 B(`state.go:349-351` PSK token 在最前 → `hasK` → payload 加密)。結論(只依 state 選模式)仍成立,改字即可。

**m2.** §2「helper 新動詞:`health.get`、`adv.registered`。其餘 helper 不改」與 §4.3 `auth/owner` 列的「新增 `info.owners()`」、D7 不一致;§4.3 表要補 `info.owners` 一列(授權、回 `{1: [owner_pub…]}`、只在 claimed/member)。

**m3.** provd policy `<allow send_destination="org.freedesktop.DBus"/>` 比 default 寬(default 已允許 `org.freedesktop.DBus` / Introspectable / Properties 三個介面並 deny Monitoring 等,`system.conf:66-80`);這條 user 規則會蓋掉 default 的 deny。刪掉它(default 已夠 Hello / RequestName / AddMatch)。`<allow receive_sender="org.bluez"/>` 也多餘(default `allow receive_type=*`)。另 root policy 既有的 `send_interface=…`(無 destination 限制)已允許 bluetoothd → provd 的全部回呼;新加的 `send_destination="org.batman.provd"` 列是文件化而非必要——寫明,免得有人以為 `RequestName` 失敗就收不到回呼。

**m4.** `claim/begin` 在重取角色:協定 §3.5 要 `owner_pub` ≠ 已存 → `E_FORBIDDEN`;設計改成只在 `claim/replay` 時由 helper 比對(`nonce` 動詞看不到 owner_pub)。可接受,但要寫進 219 v0.8 的差異清單,h23 `prov-claim-replay-254`「錯 owner_pub → 3」要指明是在 replay 那步回。

**m5.** STATUS「回 ATT `0x0E`」:BlueZ `dbus_error_to_att_ecode`(`gatt-database.c:2214-2253`):`org.bluez.Error.Failed` 無數字訊息 → **0x80**;其他錯誤名 → 0x0E。設計要指定 D-Bus 錯誤名(例如回 `org.bluez.Error.Failed` 帶 `"0x0e"` 會印一行 `Invalid error code` 再回 0x0E;乾脆用 `org.bluez.Error.NotSupported` 以外的名字或接受 0x80)。

**m6.** provd 匯出的方法對 bluetoothd 回呼要**驗 sender** = `org.bluez` 目前的 unique name(root 任何程序都能呼;default policy 已擋非 root,但多一層便宜)。godbus `Export` 每個呼叫一個 goroutine(`export.go:258`)→ `AcquireWrite` / `ReadValue` / `Release` 並行,設計要寫 provd 狀態的鎖。

**m7.** 註冊前 health 門檻的「`boot_id` = 本次(provd 讀 `/proc/sys/kernel/random/boot_id`,jail `-r`)」:`health.get` 回的是 helper **記憶體裡**上一次 tick 的行,不可能是上次開機的 → 這個檢查是空的;拿掉就不必把 procfs 單檔 bind 進 jail(ujail `-r` 對 procfs 檔與 `/var → /tmp` symlink 下的 `system_bus_socket` 的行為都 ⚠️ 未實證,F-P3 沒掛這兩個)。`-r /etc/passwd /etc/group` 也說不出用途(ujail 在 jail 外解 `-U`)。

**m8.** `HELPER_WAIT` 到期回 `E_BUSY` 後,helper 的遲到回應仍會從同一條連線送來(連線序列化)→ provd 要以 req id 丟棄遲到回應,並確保下一個請求不會錯配。寫進 §4.3 連線模型。

**m9.** `provd.env` 只在 `prov_test` 由 init 讀——init 檔如何知道自己是哪種 build(同一個 `files/batman-provd.init`)?要寫(例如 Makefile 依 `BATMAN_PROV_TEST` 安裝不同 init、或 init 檢查二進位 `--variant`)。

**m10.** `patches/ekh-bcm2711/0015-…` 是**每板**目錄;「bcm2710 同 patch,只 build」需要 `patches/ekh-bcm2710/` 也放一份(或共用機制),否則 L13 的 kernel 仍有洞。

**m11.** CVE-2026-64539 / CVE-2025-38303 的對應 upstream commit 沒給,我無法離線核對「放不下時丟 Flags / TX power」是不是 upstream 的修法。D3 要列 commit id + 貼 patch 的 `eir.c` diff,臂 2 的預期(「廣播存在」或「mgmt 拒絕」)兩種都算過不夠精確,要依 upstream 行為定一個。

**m12.** policy 檔由 firmware `batman-ble` 擁有、provd 由 Batman feed 擁有:feed pin 升、firmware 樹沒跟上 → provd `AccessDenied` → 無 BLE(fail-closed,可接受)。provd 啟動時遇 `AccessDenied` 要 log 一行可 grep 的 `provd: dbus policy missing (batman-ble too old)`,並在 release gate 加「image 的 `bluetooth.conf` 含 `policy user="provd"`」。

**m13.** `info` 的 `model` 取 `/etc/batman-build` `BATMAN_MODEL`:04 的檔沒有這個 key(只有 `BATMAN_BOARD` 等)→ 階段 1 一律 `"dev"`;寫明。

**m14.** `ADV_LEN_TEST` 負對照只證 provd 自檢;attacker 是攻陷的 provd,它不會自檢。§8 已誠實寫「只有 kernel patch 擋得住」,但表格「負測試」欄仍引 `ADV_LEN_TEST` → 改引臂 2。

**m15.** §4.5 停止順序一句有「?」,定稿前刪掉;K10 provd → K15 helper → K20 bluetoothd 與 stage1 §4.7 一致。

## 4. 生命週期矩陣缺口(未列為 finding 的補充)

- **ujail 缺 / jail 建不起**(M10)。
- **helper.sock 目錄不存在時 provd 啟動**(helper S89 失敗 → `/tmp/run/batman-prov` 不在 → ujail `-w` 失敗):寫「ujail -E 下不啟動、procd 5 s 重試」或 provd 內部退避。
- **phone 在 `net.apply` 進行中斷線**:helper 繼續做完(mutex),provd 丟棄遲到回應;app 重連讀 `info.unfinished` — 與 wireless-txn §19 一致,補一列。
- **`info.state` 在無 provisioning record 時回 `EUnsupported`**(`node.go:204-208`,只放行 `info.cert/ecdh_pub/boot_id/nonce`)→ STATUS 不可讀、不廣播?設計 L1 說 first boot 會註冊;要確認 fresh 卡 helper 第一次 tick 前 record 是否已存在,否則 L1 的「S92 provd 註冊」等 record 才能回 STATUS。

## 5. 判定

**REJECT(窄)** — 0 BLOCKER / 12 MAJOR / 15 MINOR。方向(兩個二進位、UUID-only 廣播、kernel patch、provd 不碰 keystore、helper 收原始信封)都成立且我核過原始碼;但 M1–M4 是 provd ↔ helper / provd ↔ app 的**契約本體**寫錯(claim.verify 參數、錯誤碼、replay nonce 配對、假第 2 則長度),M5 / M8 是現場 10 台隊伍一定會踩的可用性問題,M6 / M7 是把不存在的防線寫進矩陣與安全表。修完後整份再審一輪。
