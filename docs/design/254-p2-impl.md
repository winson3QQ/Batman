# #254 PR-P2:`batman-provd` — BLE 上的供裝協定行程(設計 v2)

狀態:v2,2026-10-31;v1 兩位審查 REJECT(窄):A 0/12/15、B 1/7/13,全部對應見 §13。待第 2 輪整份重審。上層:`254-stage1-impl.md`(v19)§2 / §4.1 / §4.6–4.8 / §8;協定 `219-protocol.md` v0.7 + `219-protocol.cddl`;harness 契約 `254-h23-harness.md` §4.8–4.10 / §6.3;無線交易 `254-wireless-txn.md` §19 的 P2 契約。本文件只寫 P2 新增或改變的部分;沒寫到的一律沿用上層。**與上層衝突處以 §1.3 為準;本文件內以後面的章節為準。**

## 0. 一句話

`batman-provd` 是一個 uid 471、ujail 裡的 Go 行程:向 BlueZ 註冊一個廣播與一個 GATT 服務,把每條 BLE 連線變成一條 Noise 安全通道,解出 CBOR 信封後交給 root 的 `batman-provhelper` 執行(owner-op 動詞原封轉送信封,認領動詞拆成 helper 既有的欄位),自己只持有每次啟動的 Noise 靜態金鑰、角色、計數器、逾時與一份唯讀快取;它連 helper 的 health 檔都讀不到,要什麼都經 socket 問 helper,而 helper 對它說的話(廣播有沒有註冊)一律自己向 kernel 求證。

## 1. 決策、範圍、事實

### 1.1 使用者決策(2026-10-31,#254 留言 6539606175)

| # | 決策 | 後果 |
|---|---|---|
| P-U15 | Noise 用 vendored `github.com/flynn/noise` v1.1.0 | §4.2;只依賴 `x/crypto`;build 不連網 |
| P-U16 | D-Bus 用 vendored `github.com/godbus/dbus/v5` v5.2.4 | §4.1 |
| P-U17 | P2 的 provd 同時轉送 `network/join`、`network/leave`、`network/update` 與 `info`(含 `info.net` owner-only、`unfinished`、leave ≤ 165 s / net.apply ≤ 180 s);邀請、全隊狀態、診斷、改名留 P3 | §4.3 訊息表;H3 §6.3 單位可在 P2 rc 上跑 |
| P-U18 | 設計期在 04 唯讀探查 + ≤ 2 分鐘試廣播 | 已做;第 2 段試廣播讓 04 kernel panic(F-P9),**之後不再在 04 試廣播** |

### 1.2 事實(全部 2026-10-31 唯讀實查或原始碼;`F-P*` 為本文件新增;R-* 來自 v1 兩位審查員自己核過的)

| # | 事實 | 證據 |
|---|---|---|
| F-P1 | 02/04 = `1.5.14-wsl.16+c46dfc9.fw6aa0241`,slot A committed,lock UNPROVISIONED;bluetoothd 5.72 跑著、`hci0` 在、`Powered: yes`、`Pairable: no`、`Discoverable: no`、`ActiveInstances 0`;**無 provd 二進位、無 provd 行程**;uid/gid `provd` 471 存在;`/sbin/ujail` 在(procd-ujail 2026.03.14) | 04 `bluetoothctl show`、`id provd`、`ujail -h` |
| F-P2 | 控制器(BCM4345C0)`SupportedInstances 5`、`SupportedIncludes tx-power / appearance / local-name`、**無 `SupportedSecondaryChannels`** → 無 LE extended advertising → legacy 路徑,ADV 與 scan response 各 31 B | 04 `bluetoothctl show` |
| F-P3 | ujail 以 uid 471 執行靜態 Go 二進位可行:`ujail -n p2probe -U provd -G provd -r /usr/bin/batman-provhelper -r /etc/batman-build -- /usr/bin/batman-provhelper --version` → 印版本、rc 0 | 04 實跑 |
| F-P4 | `/var/run/dbus/system_bus_socket` `srwxrwxrwx root`;`bluetooth.conf` 只有 `<policy user="root">`、無 default policy;**檔案由 firmware `package/batman/batman-ble` 擁有**;`main.conf` = stage1 §4.6;節點無 `dbus-send` / `busctl` / python / **`btmgmt`**(R-B7) | 04 `ls`、`grep -l … opkg/info/*.list`;firmware `package/batman/batman-ble/Makefile` |
| F-P5 | health 檔 `/tmp/run/batman/batman-prov.health`(root 0600)在 root `drwx------` 目錄 → uid 471 讀不到;`adv_registered_once` 由 P1 永遠寫 0(`health.go:138`);tick 15 s(`health.go:160-166`) | 04 `ls -la`;`health.go` |
| F-P6 | helper socket 契約:`SOCK_SEQPACKET` `/tmp/run/batman-prov/helper.sock`(目錄 root:provd 0750,socket 0660);請求 `{1: verb, 2: id, 3: args}` 恰好 3 key,回應 `{1: id, 2: code, 3: body}`;每次 `Read` 前 `SetReadDeadline(+30 s)`,到期**關連線**(`sock.go:146-170`);> 64 KiB 關連線;**`Node.Handle` 全程持 `n.mu`**(`node.go:157-159`),`BootFinish` 開機時先 Lock(等 radio ≤ 120 s)再服務(`main.go:611-614`);`dispatch` 無 provisioning record 時只放行 `info.cert / info.ecdh_pub / info.boot_id / nonce`(`node.go:207-212`) | 原始碼 |
| F-P7 | helper 錯誤碼(`node.go:30-48`):`3 EForbidden、4 EBadObject、5 EStaleVersion、6 EUnsupported、7 EBusy、10 EStorage、12 ERate、20 ESchema、21 EApply、22 EState、23 ELockIncomplete`;**沒有 9**;CheckMac 失敗回 `EForbidden`(`claimVerify`) | 原始碼 |
| F-P8 | `claim.verify` 收 **5 個拆好欄位** `{1: h, 2: response(32), 3: owner_pub(65), 4: owner_enc_pub(65), 5: sig_enc(64)}`(`node.go:501-520`);owner-op 動詞收 `{1: h, 2: 原始信封 bstr}`,helper `decodeEnvelope` 要信封的 key 3 是 **map**(`node.go:636-662`);`net.apply` + 信封 type `network/update` → `netUpdate`(`node.go:731-733`);`claim.replay(h, 原始信封)` | 原始碼 |
| F-P9 | **nonce 語意**:`nonce(h)` 每次回新的一對 `{1: nonce_node, 2: nonce_helper}`,同一 `h` 最多 4 對、60 s;`takeNodeNonce(h)` 取**最新未用**的 node 半;`takeHelperNonce` 以 `nonce_helper` 值查表(`node.go:270-332`)→ app 先 `claim/begin` 再 `op/nonce` 會讓 `claim/replay` 用到第二對的 node 半 → CheckMac 必敗 | 原始碼(A M3) |
| F-P10 | **F-P9(v1)→ 改編號 F-P10:註冊 31 B 的 ADV 資料讓 04 kernel panic(1/1)**:機制 = BlueZ `advertising.c:873 get_adv_flags` 不 discoverable 時只給 `CONNECTABLE`,`calc_max_adv_len`(:780)= 31;kernel `mgmt.c:8498 tlv_data_max_len` 同樣不扣;`eir.c:245 eir_create_adv_data` 在 `!HCI_BREDR_ENABLED` 無條件寫 3 B Flags(:276-296)再 `memcpy` 不檢查(:300)→ 34 B 進 `hci_sync.c:1333` 的 `hci_cp_le_set_adv_data.data[31]`。= CVE-2026-64539 + CVE-2025-38303;6.6.138 兩者都無(`eir.h:12` 無 size 參數)。兩位審查員逐行核過 | #254 留言 6539869418 / 6539887614;pstore 副本 scratchpad `crash04/` |
| F-P11 | BlueZ 5.72 把 `ServiceUUIDs / ServiceData / ManufacturerData / Data / Appearance` 全放 ADV(`advertising.c:800-830`),scan response **只放 Local Name**(:833-846);`Discoverable=false` 時 BlueZ 不加 Flags AD(:747-778) | 原始碼 |
| F-P12 | 第 1 段試廣播(UUID 列表 18 + service data 27 = 45 B)被 BlueZ 拒絕 `Advertising data too long`,無副作用 | 04 |
| F-P13 | 向量:`noise_nx.msg1` **32 B**、`noise_nxpsk0_*.msg1` **48 B**、三組 `msg2` 皆 **711 B** = e 32 + AEAD(s) 48 + node_cert 615 + tag 16;`fake_msg2_rule.length_equals_real_msg2 = 711`;`verify.py` 195 項 | `vectors.json`(R-B3) |
| F-P14 | `flynn/noise` v1.1.0:`HandshakeState` 欄位未匯出、無 Clone;`e` 在 `WriteMessage` 才產生,但 **`Config.EphemeralKeypair` 可注入**;NXpsk0 msg1 = `psk, e, payload`,`MixKeyAndHash(psk)` 後 `hasK=true` → msg1 payload 經 AEAD → 回應方 **ReadMessage msg1 就能判 PSK 錯**,且讀 msg1 **沒有 DH**;`ReadMessage` 失敗會 `Rollback()`;NX 的 msg1 payload 明文 → 48 B 的 psk0 msg1 丟給 NX 回應方 `ReadMessage` **會成功**;`ChannelBinding()` = h | `state.go:184-195, 256-268, 316-360, 391-470, 503-617`、`patterns.go:39-45`(R-B1/B2、A) |
| F-P15 | `godbus/dbus/v5` v5.2.4:unix fd 在 auth 自動 `NEGOTIATE_UNIX_FD`,方法回覆可帶 `dbus.UnixFD`;`RequestName` / `AddMatchSignal` 走 `org.freedesktop.DBus`;`prop.Export` 可用;**沒有 ObjectManager 實作** → provd 自己匯出 `GetManagedObjects`;每個方法呼叫一個 goroutine | `auth.go:96-107`、`transport_unix.go:258-285`、`export.go:423`(R-B13、A) |
| F-P16 | BlueZ GATT server:`AcquireWrite / AcquireNotify / ReadValue` 的 options 帶 `device`、`link`、`mtu`;ATT 斷線 → `att_disconnect_cb` → `io_shutdown` → provd 的 fd 收 HUP;`dbus_error_to_att_ecode`:`org.bluez.Error.Failed` 無數字訊息 → ATT **0x80**,其他名稱 → **0x0E**(`gatt-database.c:2214-2253, 2334-2370, 2570-2660`);GDBusClient 容忍廣播物件沒有 `GetManagedObjects`(`gdbus/client.c:1209-1234`、`advertising.c:1532-1550`);`Device1.Disconnect` 不改 temporary(`device.c:2049-2064`) | 原始碼(R-B8/B9/B10、A) |
| F-P17 | kernel:連線時控制器停 legacy 廣播,**斷線後 kernel 自己重開同一 instance**(`hci_event.c:3421-3424, 5640`);RPA 只在 `rpa_timeout`(900 s)過期後才重算(`hci_sync.c:1093-1118` RPA 有效就 return;`mgmt.c:1016-1029`)→ **900 s 窗內連線前後、撤銷 / 重註冊都是同一 RPA**;= stage1 F28 | 原始碼(R-B11、A M7) |
| F-P18 | dbus-daemon 1.14.10 啟動時 **unlink 既有 socket 再 bind**(`dbus-sysdeps-unix.c:1210-1212`)→ 以「檔案」bind 進 jail 的 socket 在 dbus 重啟後是死 inode;system.conf default policy 已 `allow send_destination=org.freedesktop.DBus`(三介面)並 deny `UpdateActivationEnvironment` / `Monitoring` / `Debug.Stats` / `systemd1.Activator`;既有 root policy 的 `send_interface` allow **無 destination 限制** → root(bluetoothd)對 provd 匯出介面的回呼今天就被放行 | 04 `/usr/share/dbus-1/system.conf:44-82`;`bluetooth.conf`(R-B6/B12、A) |
| F-P19 | procd:`jail` + `user` → 不自己 setuid,改傳 `-U/-G`;`capabilities` → `-C`、`no_new_privs` → `-c`;`bounding: []` 丟全部 cap;**ujail 不存在且無 `requirejail` → 靜默不 jail、只 setuid 跑**(`instance.c:321-337, 541-549, 1459-1470`;`procd.sh:199` `requirejail` → `-E`);04 `/etc/capabilities/` 有範本 | 原始碼(A M10) |
| F-P20 | autocommit 對 BLE health **只 WARN、不擋**(`batman-autocommit:507-510`,P-U5)→ 「provd 不起 → revert」今天不成立 | 原始碼(A M6);h23 F12 |
| F-P21 | Go module 只 vendor `x/crypto`、`x/sys`;自家 `cbor / cose / proto / keystore / provstore / health / sock / seam`;單一 cmd;`USERID:=provd=471:provd=471`;WSL 可取 `flynn/noise v1.1.0`、`godbus/dbus/v5 v5.2.4`;firmware golang = go1.26.4(#252) | `feed/batman-prov`;`go get` 於 /tmp/p2mod |
| F-P22 | `provclient` 已有 `info / claim / claim-attacker / replay / ssh-keys / root-reset / rename / verb / node / sign / keygen / selftest`,`unixpacket`,`sock-as <uid>`;`main.go:579` 註明 replay「one nonce call serves both」 | 原始碼 |
| F-P23 | 04 `/etc/batman-build` 0644、無 `BATMAN_MODEL`;`/proc/sys/kernel/random/boot_id` 0444;`/tmp/run/dbus` 目錄 root 0755 | 04 `ls -la`(A、B) |
| F-P24 | `sign.*` 額度:helper 內 2/s 全域(`node.go:332` 註解「0.5/s per connection is the server's」= provd 的責任) | 原始碼(B m11) |

### 1.3 與上層設計不同處(→ 回報上層 §10)

| 上層 | 本文件 | 理由 |
|---|---|---|
| stage1 §2「同一個 Go 二進位,argv[0] 決定模式」 | **兩個二進位** `batman-provhelper`(root)與 `batman-provd`(471),同一 module、同一套件 | ujail `-r` 只掛 provd;release gate 的 helper 檢查不受影響;provd 不連結 keystore / provstore / shacrypt |
| h23 §4.9「ADV = Flags + 128-bit UUID 列表 21 B;B16 service data 放 scan response」 | **ADV = Flags(kernel 加)3 + 128-bit Service UUID 列表 18 = 21 B;無 scan response、無 Local Name、無 service data** | F-P11:scan response 放不了 service data;F-P10:ADV ≤ 28 B 硬限制。`updating` 與 `device_id` 末 4 字元只在 GATT `STATUS`。B16 維持 #255 |
| stage1 §1.3「adv 帶 `device_id` 末 4 字元」 | 不帶 | 同上 |
| stage1 §8 F28「每次重新註冊換 B16 nonce」;v1 §4.4「斷線重註冊 → 新 RPA」 | 重註冊照做(讓 kernel **有機會**換 RPA),**payload 不變,且 900 s 窗內 RPA 不換**(F-P17)。誠實界線:同一 RPA 期間一台節點的連線前後可被串起;階段 1 的「連線即撤廣播」只剩**單一連線**的效果,不是隱私防線 | F-P17;B16 不在階段 1 |
| stage1 §3「provd 讀 health 檔」;「`adv_registered_once` 由 provd 註冊後設」(stage1 §4.1 的 health 列、h23 §6.3) | provd 讀不到 health 檔(F-P5)→ helper 新動詞 `health.get`(**不取 `n.mu`、現算**);**`adv_registered_once` 由 helper 自己向 kernel 求證**:health tick 多打一個 mgmt `Read Advertising Features`(0x003D)讀 `num_instances`,本次開機曾 ≥ 1 就 latch;**沒有 `adv.registered` 動詞**(uid 471 不能自報) | F-P5;A M11 / B M5:autocommit 的 BLE 判定不能信任非特權行程 |
| stage1 §4.1 helper 動詞表 | 新增 `health.get`、`info.owners`;`info.state` 加 key 5 `trial`;`info.net` 加 key 4 `unfinished`;`psks.get` **P2 不回 key 4/5(`adv_owner` / `adv_member`)**;`health.get` / `info.boot_id` / `info.owners`(唯讀)在 `Handle` **不取 `n.mu`**,且加進「無 record 也放行」名單(`health.get`、`info.boot_id`) | §4.3;B m9:B16 不在階段 1,少給被攻陷 provd 兩把秘密;A/B M5/M2:mutex |
| stage1 §4.1「所有授權由 helper 驗」 | `auth/owner`(session 角色升級,不改變節點)由 **provd** 以 helper `info.owners` 回的公鑰驗 `ES256_owner("batman-owner-auth-v1" ‖ h ‖ owner_key_id)`;每個改變節點的動詞仍帶 owner-op 由 helper 驗 | 角色是 provd 的狀態;helper 不知道 session;B m10 |
| 協定 §3.3「`s_node` 每次開機產生」 | 每次 **provd 啟動**(含 respawn)重新產生 → `node_cert` 的 `boot_id` 不變、`s_node_pub` 可能變;app 本來就每次交握重驗,不得快取 `s_node_pub` | respawn 後不能留金鑰 |
| 協定 §3.5 `auth/owner` 回「目前的 `adv_owner_key`」 | 階段 1 回空 map | B16 #255 |
| 協定 §3.5 擁有者重取角色的 `claim/begin`「`owner_pub` 必須等於已存的那把否則 `E_FORBIDDEN`」 | provd 不比(看不到已存的);helper 的 `claim.replay` 以已存的那把重算 CheckMac → 錯的 `owner_pub` 在 `claim/replay` 一步以 `E_FORBIDDEN` 回 | helper `nonce` 不收 owner_pub;A m4 |
| 協定 §8「同時 BLE 連線 2」、「未認證 session 可被新連線擠掉」 | **連線槽 2 = BLE + sock 合計**;第 3 條連上時:若有未認證 / 候選 session → **擠掉最舊的那條**(Disconnect),否則拒第 3 條。**BLE 空中實際同時只有 1 條**(連線時控制器停廣播,F-P17;provd 也撤)→ 第 2 槽實務上只有 sock 用得到;**誠實界線:一個路人連上、拖 10 s、斷、再連,就能持續佔住 BLE 管理面**,全域 20/分 擋不住(路人 6/分 就夠);階段 1 接受(擁有者可直接 ssh;#255 考慮擁有者優先的廣播) | A M8、B m8 |
| 協定 §5.1 分塊 | provd 重組後**重新編碼**成 deterministic 整封 `{0,1,2,3,(7)}` 再交 helper(helper 要 map);階段 1 上限:`max_msg` 8192 → 每塊明文 ≤ 8176、**最多 8 塊、重組後 ≤ 65 400 B**(helper `MaxRequest` 65536 − 包裝 ≤ 100 B),超過 → Disconnect | A M12 |
| h23 §4.8.3 `provd.env` 開關 | 保留 `SOCK_ONLY / FAST_FAKE_DELAY_MS / NO_BRUTE_LIMIT / GATT_ENCRYPT_CTRL`;**新增 `ADV_LEN_TEST=<n>`** | F-P10 負對照 |
| h23 §6.3 L24「兩支手機同時 `claim/finish` → 一個 0、一個 `E_BUSY`」 | 照做;成功後 provd Disconnect 其他所有 session | 協定 §3.1 |
| h23 §6.3 `ble-rpa-254` log `adv re-registered reason=… nonce=<8hex>` | log 行無 `nonce=`(§4.4) | 無 nonce |
| h23 §6.3 / §4.8 用 `btmgmt` 當節點端工具 | 節點 release 無 `btmgmt`(F-P4);**`-wbox` 變體 image 加裝 `btmgmt`**(bluez-utils 的單一工具,release gate 斷言 release rootfs 無 `/usr/bin/btmgmt`);harness 既有 `ble-periph-254.sh` 本來就是 scp 自帶 btmgmt / btmon(h1 §4.7)→ 兩種路徑都可 | A M9 / B M6 |
| stage1 §6.4 (8)、L6「provd 不起 → UNHEALTHY → revert」 | **今天只 WARN(P-U5,F-P20);P2 不改 autocommit**。L6 改寫為 WARN;把「WARN → FAIL」列為 #254 checklist 的獨立決定(要先有 `adv_registered_once` 的 kernel 求證,本設計提供) | A M6 |

## 2. 元件

```
手機 / peer.py ──BLE GATT(或 prov_test 的 gatt.sock)── batman-provd(uid 471,ujail -E -c,caps 空,唯讀 /)
   │ godbus/dbus/v5 → org.bluez:LEAdvertisingManager1.{Register,Unregister}Advertisement、GattManager1.{Register,Unregister}Application、
   │                  Device1.Disconnect、ObjectManager.GetManagedObjects、Properties.{Get,GetAll};匯出 LEAdvertisement1、
   │                  GattService1 / 4×GattCharacteristic1(RX/TX/CTRL/STATUS)、app 根的 ObjectManager
   │ flynn/noise(NX / NXpsk0)、自家 cbor、proto(HKDF / 標籤 / ES256 驗章)
   └─ /tmp/run/batman-prov/helper.sock(SEQPACKET)──▶ batman-provhelper(root;P2 改動見 §4.3)
```

- **套件 `feed/batman-prov`**:多產 `batman-provd`(`GO_PKG_BUILD_PKG` 加 `batman-prov/cmd/batman-provd`);`files/batman-provd.init`(release)與 `files/batman-provd-test.init`(只在 `BATMAN_PROV_TEST=1` 安裝,多了讀 `provd.env`);`files/batman-provd.caps.json`(`{"bounding": []}`);vendor 加 `flynn/noise v1.1.0`、`godbus/dbus/v5 v5.2.4`(`go mod vendor`;PR 列 `go.sum` 行)。
- **helper 改動**(§4.3):`health.get`、`info.owners`、`info.state` key 5、`info.net` key 4、`psks.get` 去 key 4/5、health tick 加 `Read Advertising Features`、`Handle` 對唯讀動詞不取 `n.mu`、`dispatch` 無 record 放行名單加 `health.get`。
- **firmware(同 rc 的 firmware PR)**:`package/batman/batman-ble/files/bluetooth.conf` 加 `<policy user="provd">`(§4.7);board patch `0015-bluetooth-eir-adv-flags-oob-254.patch`(兩板目錄各一份;§4.8;待決 D3);`-wbox` 變體加 `btmgmt`;pin Batman main。
- **harness(H3,照本契約先 merge)**:`peer.py`、`transport_sock.py` / `transport_ble.py`、`prov-wbox-254.sh set-provd-env`、§6.3 單位 + 本文件 §9 新增。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| BLE 廣播 instance(LEAdvertisement1 物件) | provd(一次一個) | helper(mgmt `Read Advertising Features` 的 `num_instances`,只讀) | root 手動 bluetoothctl `advertise on` 是第二寫者 = 操作失誤(runbook 禁止;F-P10 證明會 panic);provd 看到 `ActiveInstances` ≠ 預期 → log `adv: foreign instance count=<n>`,不動作 |
| GATT application(服務 + 4 特徵 + app 根 ObjectManager) | provd | bluetoothd 代理手機 | bluetoothd 重啟 → `NameOwnerChanged(org.bluez)` → 重新 Register |
| 每條連線的 Noise 狀態、角色、`h`、`id` 水位、逾時、認領失敗計數、replay 用的 nonce 對、全域交握計數、`claimInProgress` | provd 記憶體 | — | 重開 / respawn 歸零 |
| `s_node`、`node_cert` 快取 | provd(每次啟動產生;請 helper `sign.static` / `sign.ecdh_proof`,兩次呼叫間隔 ≥ 2.1 s 以符合 0.5/s) | — | §1.3 |
| **唯讀快取**:`state / trial / 末4 / device_id`(STATUS 與 `info` 的輸入)、PSK 集合、`owners` 公鑰 | provd(§4.3 快取規則) | — | 失效條件:每 5 s 的 `health.get` 輪詢順便 `info.state`(兩個都不取 mutex);provd 自己送過的任何改狀態動詞回應後;helper 連線重建後 |
| helper 的 `n.mu` | helper | — | **P2 契約:`health.get`、`info.boot_id`、`info.owners`、`info.state`、`info.cert`、`info.ecdh_pub` 不取 `n.mu`**(讀 `provstore.LoadOverlay` 是檔案讀取,本來就有自己的一致性:rename 寫入);其餘動詞照舊 |
| `/tmp/run/batman-prov/helper.sock` | helper(P1 `PrepareDir`) | provd | provd 以**目錄** bind(`-w /tmp/run/batman-prov`);helper 重啟 `PrepareDir` 在同一目錄 inode 內重建 socket → jail 內看得到新 socket(⚠️ 實作第一步在 04 的 prov_test build 驗:helper restart → provd 重連成功) |
| `/var/run/dbus/system_bus_socket` | dbus-daemon(重啟 unlink + bind,F-P18) | provd | provd 以**目錄** bind(`-r /tmp/run/dbus`),不是檔案(v1 錯誤,B M1);connect() 對唯讀 bind 的 socket 可行 ⚠️(VFS 不對 socket 檢查 RDONLY;實作第一步驗,不行就 `-w`) |
| `$RUNDIR/batman-prov.health` 全部欄位(含 `adv_registered_once`) | helper(health tick;`adv_registered_once` latch 來自 kernel mgmt 的 `num_instances ≥ 1`,本次開機) | autocommit;provd 經 `health.get` | 唯一 health 契約仍是 stage1 §3 那一行;**provd 沒有任何辦法寫它** |
| `/tmp/run/batman-provd-test/`(`gatt.sock`、`provd.env`) | root(`prov-wbox-254.sh set-provd-env`:目錄 root 0700、檔 0600、非 symlink、link 1);**只在 prov_test build** 由 `batman-provd-test.init` 讀 `provd.env` → `procd_set_param env`;`gatt.sock` 由 provd 在 `SOCK_ONLY=1` 時建(目錄須存在且 root 0700,否則不建、log) | provd-test init、provd、harness | release image:沒有 `batman-provd-test.init`、provd 無此程式碼路徑(build tag);gate §9 |
| dbus policy `bluetooth.conf` | image(firmware `batman-ble`) | dbus-daemon | 不是 conffile;gate 斷言 image 含 `policy user="provd"` |
| `hci0` 的 Powered / Pairable / Discoverable / SC / privacy / bondable | bluetoothd | provd 經 `health.get`、`Properties.Get` | provd 不呼叫 `Properties.Set`(policy 不放行) |

## 4. 契約

### 4.1 GATT(照協定 §4.1;本節定細節)

- 服務 UUID `BATMAN_SVC_UUID`:核准時 `uuidgen` 一次,寫進協定 §4.1、CDDL 註解、`provd/gatt.go`、`peer.py`、`transport_ble.py`;特徵 = base 的第 3 組 16-bit +1…+4(RX / TX / CTRL / STATUS)。待決 D4。
- 特徵旗標:RX `write-without-response`;TX `notify`;CTRL `read`;STATUS `read`;**不帶任何 `encrypt-*` / `authenticated-*` / `secure-*`**(stage1 F43);`GATT_ENCRYPT_CTRL=1`(prov_test)把 CTRL 改 `encrypt-read`。
- 資料路徑:RX `AcquireWrite`(回 fd + mtu),TX `AcquireNotify`(fd + mtu);每個 fd 一個 goroutine;fd HUP = 該連線結束(F-P16)。`AcquireWrite` 失敗 → 退回 `WriteValue`;`AcquireNotify` 失敗 → 回 `org.bluez.Error.NotSupported`、Disconnect。
- **連線識別** = `Acquire*` / `ReadValue` options 的 `device` 物件路徑(F-P16);Disconnect 用它。
- **CTRL / STATUS 由 provd 快取回答,不在 ReadValue 內呼叫 helper**(A/B M5/M2):CTRL 常數 `{1: 1, 2: 0, 3: 244, 4: 8192}`;STATUS = `{1: [1,0], 2: ["halow"], 3: state, 4: trial, 5?: 末4}` 來自 §3 的唯讀快取(≤ 5 s 舊);**快取尚未填好(啟動後第一次 `info.state` 還沒成功)或 helper 不可達超過 60 s → ReadValue 回 D-Bus 錯誤 `org.freedesktop.DBus.Error.Failed`(→ ATT 0x0E,F-P16),不回猜的內容**。`capabilities` 固定 `["halow"]`(殘項)。
- 框架:`flags(1) ‖ seq(2 BE) ‖ data`;seq 每則 Noise 訊息從 0;不連續 / 累計 > `max_msg` / 單框 > 512 B / 缺開頭旗標 / AEAD 失敗 → Disconnect;sock = 關 socket。節點 → 手機框架 `min(244, notify_mtu − 3)`。
- 連線槽(§1.3 協定 §8 列):2 槽合計;第 3 條:擠最舊的未認證 / 候選 session,否則拒第 3 條(連上即 Disconnect,無 GATT 回應)。

### 4.2 Noise 與 session(協定 §3)

- 模式由快取的 `state` 決定:{unclaimed, legacy} → `Noise_NX`;{claimed, member} → `Noise_NXpsk0`。prologue `"batman-prov/1" ‖ 0 ‖ "ble" ‖ 0 ‖ device_hint`(unclaimed / legacy = `device_id`,其餘空);sock 傳輸也用 `"ble"`(與向量一致)。
- **msg1 長度前置檢查**(B m1 / A m1):NX 期待 **32 B**、NXpsk0 期待 **48 B**(F-P13/F-P14);長度不符 → 走假第 2 則路徑(不是 Disconnect,免得長度本身成為 oracle 的旁路——兩種模式的「錯」行為相同:假 msg2 + 等逾時)。
- 第 2 則 payload = `node_cert`(CBOR,協定 §3.3):provd 啟動時組一次(`dac_chain=[info.cert.1]`、`s_node_pub`、`boot_id=info.boot_id`、`ecdh_pub`、`sig_static=sign.static(s_node_pub)`、`sig_ecdh=sign.ecdh_proof()`、`sn=info.cert.2`),兩個 `sign.*` 間隔 ≥ 2.1 s。
- **PSK 試法(§3.4;修 v1 的錯誤描述,B m2)**:NXpsk0 時,provd 事先產生一把臨時 `e`(`noise.DH25519.GenerateKeypair`),對 6 把候選 PSK 各建一個 `NewHandshakeState(Config{Pattern: HandshakeNX, Initiator: false, PresharedKey: k_i, PresharedKeyPlacement: 0, EphemeralKeypair: e, StaticKeypair: s_node, Prologue})`,**各跑一次 `ReadMessage(msg1)`**(無 DH,F-P14),6 次全部跑完才看哪一把成功(不 break);成功 → 以該 state `WriteMessage(node_cert)`;候選 = `psk_owner[0..3]`、`psk_member`、`psk_replay`,缺的以 `crypto/rand` 補到 6。
- **假第 2 則(全部失敗、或 msg1 長度錯、或 NX 節點收到 psk0 長度的 msg1)**:新臨時 `e'`;做與真 `WriteMessage` 相同的兩次 DH(`DH(e', e_手機)`、`DH(s_node, e_手機)`;真路徑是 `ee`、`se`);送 **`e'_pub(32) ‖ random(48 + len(node_cert) + 16)`** = 與真 msg2 等長(F-P13:目前 711 B;單元測試斷言 `len(fake) == len(real)`,mutant 拿掉 48 → FAIL);不關連線,等交握逾時(10 s)才 Disconnect;sock:peer 自己斷 → 立即釋放槽。`FAST_FAKE_DELAY_MS=<n>`(prov_test)讓假路徑多睡 n ms。
- NX 節點收到 **32 B** NX msg1 → 真 msg2(明文空 payload,F-P14)。
- 交握完成 → `h = ChannelBinding()`;`Split()` 兩方向;AEAD 失敗即 Disconnect;累計 2^20 則 → Disconnect。
- 角色(協定 §3.5)由成功的那把 PSK 決定:owner_i → 擁有者候選;member → 成員;replay → 擁有者重取;NX → 匿名。
- 逾時(協定 §8):交握 10 s;未認證 / 候選閒置 30 s;已認證閒置 300 s;**請求在 helper 端進行中不計閒置**;全域交握 20 / 分(滑動窗,第 21 次 Disconnect);認領失敗 3 次 / 連線 → Disconnect(`NO_BRUTE_LIMIT=1` 關)。

### 4.3 provd ↔ helper(擴充 stage1 §4.1)

**helper 新 / 改動詞**

| 動詞 | 授權 | mutex | 效果 |
|---|---|---|---|
| `health.get()`(新) | 無 | **不取** | 現算一行(mgmt `READ_INFO` + `Read Advertising Features` + bluetoothd pid + sc 檔),回 `{1: <行>}`;不寫檔 |
| `info.owners()`(新) | 無 | 不取 | `{1: [owner_pub…]}`(公鑰);無 record → `EUnsupported` |
| `info.state` | 無 | 不取 | 加 key 5 `trial: bool`(`Sys.IsTrial()`) |
| `info.net` | 無(provd 只對擁有者 / 成員角色呼叫) | 不取 | 加 key 4 `unfinished: bool`(`TxnPresent`) |
| `info.boot_id`、`info.cert`、`info.ecdh_pub` | 無 | 不取 | 不變 |
| `psks.get` | 無 | 取(讀 record 的秘密,照舊) | **去掉 key 4/5** |
| 其餘 | 不變 | 取 | |

- health tick(15 s):除 READ_INFO 外加 mgmt `Read Advertising Features`(0x003D)→ `num_instances ≥ 1` → 本次開機 latch `advOnce` → `adv_registered_once=1`。**負對照:provd 不註冊只跑著 → 永遠 0;root 手動 `advertise on` 也會讓它變 1(誠實界線:它量的是「本次開機 kernel 曾有廣播 instance」,不是「provd 的」)。**
- **連線模型**:一條常駐連線、一個 client goroutine、FIFO 佇列、每請求帶遞增 `id`;helper 30 s 無請求關連線(F-P6)→ provd **每 20 s 閒置送 `info.boot_id` 當 keepalive**;EOF 時:**冪等動詞**(`info.*`、`health.get`、`psks.get`、`sign.*`)重連後**重送一次**;非冪等(`nonce`、`claim.*`、owner-op 動詞)不重送 → 該請求回手機 `E_BUSY` 並 log。`HELPER_WAIT = 330 s`:超時 → 關掉連線、重連、對該 session 回 `E_BUSY`,**遲到的回應以 `id` 丟棄**(重連後 `id` 繼續遞增不重用)。假時鐘單元測試涵蓋 30 s 邊界、keepalive、超時丟棄。
- **快取**(§3):啟動後與每 5 s:`health.get` + `info.state`(都不取 mutex,helper 忙時也回);`psks.get`、`info.owners` 在 **每條新連線交握前**用快取,快取在「provd 自己送出的改狀態動詞回應(任何碼)之後」與「helper 連線重建後」失效並重拉;重拉卡在 mutex(helper 正在 `net.apply`)→ 最多等到交握逾時 → 這條新連線失敗(**誠實界線:同一時間另一支手機正在 join 時,新手機的 NXpsk0 交握可能逾時一次;`info` / STATUS 不受影響**)。
- **請求打包**:owner-op 動詞與 `claim.replay`:`{1: h, 2: 原始信封 bstr}`(分塊時為重組後重編的整封);**`claim.verify`:provd 拆 `claim/finish` body `{1: response, 2: owner_enc_pub, 3: sig_enc}`(CDDL `claim-finish-req`)+ 本 session `claim/begin` 存下的 `owner_pub` → `{1: h, 2: response, 3: owner_pub, 4: owner_enc_pub, 5: sig_enc}`**(F-P8);沒先 `claim/begin` → `E_FORBIDDEN`。
- **nonce 對(F-P9)**:provd 對每條 session 快取**最近一對** `{nonce_node, nonce_helper}`;`claim/begin` → 呼叫 `nonce(h)`,回 `nonce_node` 給 app,留 `nonce_helper`;**擁有者重取角色的 `op/nonce` 不再呼叫 helper**,直接回同一對的 `nonce_helper`(app 順序 begin → op/nonce → replay 才會成功;`provclient` 已如此);擁有者角色的 `op/nonce` 每次都呼叫 `nonce(h)`(helper 同 h 最多 4 對,最舊作廢 = 協定 §8)。
- **type → verb**:

| 信封 type | 角色 | helper | provd 做的事 |
|---|---|---|---|
| `info` | 全部 | 快取(`info.cert` 一次、`info.state` 5 s)+ 擁有者 / 成員角色才 `info.net` | 組 `info-resp`:1 `device_id`、2 `model`(`/etc/batman-build` `BATMAN_MODEL`,04 沒有 → `"dev"`)、3 `board`、4 `fw_version`、5 `[1,0]`、6 `["halow"]`、7 `state`、8 `claim_window`(state ∈ {0,3} 且非 trial)、9/10 owner / member 才有、**11 `unfinished`**(= `info.net.4`,owner / member 才有) |
| `claim/begin` | 匿名、擁有者重取 | `nonce(h)` | 存 `owner_pub`(body 1)與 nonce 對 |
| `claim/finish` | 匿名 | `claim.verify(5 欄)` | `claimInProgress` 互斥(另一 session 同時 → `E_BUSY`);helper 3 → **`E_CLAIM_FAILED`(9)**,計失敗 1 次;`EUnsupported` reason 含 `no-ssh-key` → `E_UNSUPPORTED{capability:"claim", reason:10}`;23 → `E_LOCK_INCOMPLETE`;0 / 23 → 本 session 升擁有者、Disconnect 其他 session、快取失效 |
| `op/nonce` | 擁有者、擁有者重取 | 擁有者:`nonce(h)`;重取:快取對 | 回 `nonce_helper` |
| `claim/replay` | 擁有者重取 | `claim.replay(h, 信封)` | 0 / 23 → 升擁有者、Disconnect 其他 session;3 → `E_FORBIDDEN`(計失敗);12 → `E_RATE` |
| `auth/owner` | 擁有者候選 | 快取 `info.owners` | provd 驗章(§1.3);通過 → 擁有者,回 `{}`;失敗 → `E_FORBIDDEN`(計失敗 3 次 / 連線同認領) |
| `network/join` | 擁有者 | `net.apply(h, 信封)` | 等 ≤ 330 s |
| `network/update` | 擁有者、成員 | `net.apply(h, 信封)`(helper 以 type 分流,F-P8) | 同上 |
| `network/leave` | 擁有者 | `network.leave(h, 信封)` | 同上 |
| `ssh_keys/set`、`root_password/reset` | 擁有者 | `ssh_keys.set` / `root_password.reset` | 回應不快取 |
| `owner/add|remove`、`settings/*`、`status`、`peers/challenge`、`diag/*`、`update/*`、`bulk/*` | — | — | **P3**:`E_UNSUPPORTED{capability: <type>}`;`reset` → `E_UNSUPPORTED{capability:"reset", reason: 9}` |

- **錯誤碼(helper → 協定),唯一的表**:`3 → 3`(**`claim.verify` 例外 → 9**);`4 → 4`;`5 → 5`;`6 → 6`(帶 helper 的 reason;`no-ssh-key` → reason 10);`7 → 7`;`10 → 10`;`12 → 12`;`20 → 2`(provd 自己的表查不到 type 時)否則 `3`;`21 / 22 → 11 E_REJECTED`(`reason` = helper reason 文字);`23 → 13`;其他未知碼 → 11。provd 自己產生:1(major ≠ 1)、2、3(角色)、7(互斥、helper 逾時、佇列丟棄、擠槽前)、6(P3 / idem)。
- 帶 `7: idem_key` 的請求:階段 1 不實作快取 → `E_UNSUPPORTED{capability:"idem"}`;帶秘密回應的 type 帶 7 → `E_FORBIDDEN`(協定)。
- 回應信封 `{1: id, 4: status, 3: body | 5: error}`;`id` 重複 / 倒退 → Disconnect。分塊:見 §1.3 協定 §5.1 列;重組後重編 `{0,1,2,3,(7)}`(deterministic;單元用向量 `chunking` 斷言重組 bytes == 原始整封)。

### 4.4 廣播(取代 h23 §4.9)

- 一個 `LEAdvertisement1`:`Type=peripheral`、`ServiceUUIDs=[BATMAN_SVC_UUID]`、`Discoverable=false`、無 `LocalName` / `Includes` / `ServiceData` / `ManufacturerData` / `Data`、`Timeout=0`。BlueZ 產 18 B,kernel 加 3 → 21 B。
- **ADV 長度自檢**:provd 註冊前算 BlueZ 會產生的長度(目前固定 18)+ 3 > 31 → 不註冊、log `adv: payload would be <n> B (max 28)`、退出碼 3(無法修復 → procd respawn 會一直退;寫明);`ADV_LEN_TEST=<n>`(prov_test)讓自檢以 n 當 payload 長度。**它只擋我們自己的程式錯;被攻陷的 provd 不受它約束 → 真正的擋法是 kernel patch(§4.8)**。
- **註冊前置(fail-closed)**:`health.get` 行 `bluetoothd=1 hci0_powered=1 privacy=1 sc=1 sc_file=1 bondable=0`(沒有 `boot_id` 檢查:現算的行永遠是本次)且 D-Bus `Adapter1.Pairable == false && Discoverable == false`;任一不成立 → 不註冊,每 5 s 重查(log 只在狀態改變時)。
- **撤銷**:每 5 s `health.get`(現算、不取 mutex)→ 任一欄轉壞 → `UnregisterAdvertisement`(**最壞 ≈ 5 s + 一次往返**,滿足 ≤ 10 s;B M3);有連線建立(`Acquire*` 到來或 `Device1.Connected`)→ 撤銷;所有連線結束 → 重新註冊。
- **RPA**:kernel 只在 900 s 過期後換(F-P17);provd 無連線時每 `900 + rand(30..120)` s 撤銷 + 重註冊,讓過期的 RPA 真的被換掉;**連線前後、斷線重註冊在 900 s 窗內是同一 RPA**(§1.3)。
- log 契約(H3 讀):`provd: adv registered reason=<start|disconnect|rpa_timeout|health|bluetoothd>`、`provd: adv withdrawn reason=<health|connect|stop|bluetoothd>`;無 `nonce=`。
- 退避 log:`provd: backoff <n>s reason=<…>`。

### 4.5 init / ujail

```
START=92 STOP=10 USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/batman-provd
  procd_set_param respawn 3600 5 0
  procd_set_param user provd ; procd_set_param group provd
  procd_add_jail batman-provd log requirejail                      # -E:ujail 缺 / 建不起 → 不啟動(F-P19)
  procd_add_jail_mount /usr/bin/batman-provd /etc/batman-build /tmp/run/dbus          # dbus 以目錄掛(F-P18)
  procd_add_jail_mount_rw /tmp/run/batman-prov                                        # helper.sock 的目錄
  [test init 另加] procd_add_jail_mount_rw /tmp/run/batman-provd-test ; 讀 provd.env → procd_set_param env K=V …
  procd_set_param capabilities /etc/capabilities/batman-provd.json   # {"bounding": []}
  procd_set_param no_new_privs 1
  procd_close_instance
}
```
- 不掛 `/etc/passwd`、`/etc/group`、`/lib/ld-musl*`、`/proc` 單檔(靜態 Go;v1 多掛的都拿掉,B m5 / A m7);實作時 `file batman-provd` 斷言 `statically linked`。
- 無法修復的錯(ADV 自檢、jail 配置)才退出;其他(bus / adapter / helper 不可達、簽章失敗)內部退避 1,2,4,…≤ 60 s 不退出。
- 停止:K10 撤廣播、Disconnect 全部連線(best effort ≤ 500 ms)→ 退出;bluetoothd K20、helper K15 在其後。
- **兩個 init 檔**:`batman-provd.init`(release)/ `batman-provd-test.init`(`BATMAN_PROV_TEST=1` 時取代前者安裝);release gate 斷言 image 的 `/etc/init.d/batman-provd` 不含 `provd.env`。

### 4.6 `provd.env`(prov_test;h23 §4.8.3)

`SOCK_ONLY=1`、`FAST_FAKE_DELAY_MS=<n>`、`NO_BRUTE_LIMIT=1`、`GATT_ENCRYPT_CTRL=1`、`ADV_LEN_TEST=<n>`。寫者 `prov-wbox-254.sh set-provd-env` → restart provd;provd 啟動 log `provd: test env <k=v…>`。release:`cmd/batman-provd/testenv_release.go` 讓這些名字不存在;gate `strings batman-provd | grep -c -e SOCK_ONLY -e ADV_LEN_TEST -e provd-test` = 0。

### 4.7 dbus policy(firmware `batman-ble/files/bluetooth.conf`)

```xml
<policy user="provd">
  <allow send_destination="org.bluez" send_interface="org.bluez.LEAdvertisingManager1" send_member="RegisterAdvertisement"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.LEAdvertisingManager1" send_member="UnregisterAdvertisement"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.GattManager1" send_member="RegisterApplication"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.GattManager1" send_member="UnregisterApplication"/>
  <allow send_destination="org.bluez" send_interface="org.freedesktop.DBus.ObjectManager" send_member="GetManagedObjects"/>
  <allow send_destination="org.bluez" send_interface="org.freedesktop.DBus.Properties" send_member="Get"/>
  <allow send_destination="org.bluez" send_interface="org.freedesktop.DBus.Properties" send_member="GetAll"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.Device1" send_member="Disconnect"/>
</policy>
```
- **沒有** `own`(provd 不要 well-known name;bluetoothd 以 unique name 回呼,root policy 既有的無 destination `send_interface` allow 已放行,F-P18)、沒有 `send_destination=org.freedesktop.DBus`(default 已放行三介面並 deny 四個危險成員;user policy 寫了會蓋掉那些 deny,B m4 / A m3)、沒有 `receive_sender`(default 已 allow 收)。
- provd 匯出的方法**驗 sender == org.bluez 的 unique name**(`GetNameOwner` 一次 + `NameOwnerChanged` 更新),其他 sender → `org.freedesktop.DBus.Error.AccessDenied`。
- 負測試:`prov-sec-dbus-254` 加 471 呼叫 `org.freedesktop.DBus.UpdateActivationEnvironment` → AccessDenied(default deny 仍在);471 `Introspect` 仍 AccessDenied(F16)。

### 4.8 kernel board patch(待決 D3)

`patches/ekh-bcm2711/0015-bluetooth-eir-adv-flags-oob-254.patch` 與 `patches/ekh-bcm2710/` 同名一份:backport 上游 CVE-2025-38303(`eir_create_adv_data` 加 Flags / TX power 前檢查空間)與 CVE-2026-64539(prepend Flags 的 stack OOB)。**上游 commit id ⚠️ 核准後在 linux-stable 查(`git log --grep`),寫進 patch 標頭**;修法語意 = 放不下時**丟 Flags,不丟使用者資料、不越界**。正向見證:`-wbox` 變體 root `btmgmt add-adv -d <31 B> 1` → 不 panic、`advinfo` 有 instance(或 mgmt 拒絕 INVALID_PARAMS,兩者都算通過,斷言寫明);負對照 = F-P10 的實跑紀錄,**不再重現**。

## 5. 生命週期矩陣(provd 相關;其餘沿用 stage1 §5、h23 §5)

| # | 路徑 | 今天(wsl.16) | P2 後 | 測試(負對照) |
|---|---|---|---|---|
| L1 | first boot / 重燒卡 | 無廣播 | S89 helper 產身分、`BootFinish` 若有 `.txn`;S92 provd:連 bus、等 `hci0` 的 `Adapter1` 物件(`InterfacesAdded`)、填快取(`info.state` 不取 mutex,fresh 節點 record 由 `--boot` 產生在 helper 服務前 → 可讀)、簽 `node_cert`(可能排在 `BootFinish` 之後 ≤ 120 s)、health 全 1 → 註冊 | `prov-firstboot-254`(B trial STATUS 可讀、`updating=1`、末 4 碼) |
| L2 | boot | 同上 | 同 L1;第一次註冊後 ≤ 15 s health `adv_registered_once=1`(helper 自量) | `prov-boot-254`(含:停 provd → 值**不**回 0,latch;負對照:provd 從未註冊 → 0) |
| L3 | clean stop | — | K10 撤廣播、Disconnect、退出 | boot-reasons 乾淨 |
| L4 | reboot | — | 同 L2;全部狀態歸零 | |
| L5 | OTA(fresh overlay) | — | provd 無持久狀態 | `prov-ota-254` + STATUS 可讀 |
| L6 | autocommit | WARN ble(F-P20) | **不變:只 WARN**;有 `ble-ok` 的節點在 trial 上 provd 註冊 → 不再 WARN;provd 不起 → WARN 行(不 revert)。WARN → FAIL 是 #254 checklist 的獨立決定 | §6.4 (8):兩臂斷言 WARN 行有 / 無 |
| L7 | 斷電 | — | provd 無狀態;手機重連重讀 `info`(`unfinished`) | 既有 powerloss 單位 |
| L8 | provd crash loop | — | procd respawn + 內部退避 log;health 不看 provd | `prov-respawn-254` |
| L9 | bluetoothd 重啟 | — | `NameOwnerChanged(org.bluez)` → 丟 D-Bus 狀態、等新 owner 與 `Adapter1` → 重新 Register ≤ 15 s;既有連線已斷 | `prov-dep-restart-254` |
| L10 | dbus 重啟 | — | provd 的 bus 連線 EOF → 退避重連(socket 目錄 bind,新 socket 看得到,F-P18)→ 同 L9 | `prov-dep-restart-254` 加 dbus 臂:restart dbus → ≤ 60 s 重註冊(**v1 以檔案 bind 時此臂必 FAIL = 負對照**) |
| L11 | helper 重啟 | — | helper.sock EOF → 重連(目錄 bind)→ 重拉 `node_cert`(簽章)、快取失效;進行中請求 `E_BUSY`;`adv_registered_once` 由 helper 重啟後第一個 tick 自己量回 | 同上加 helper 臂 |
| L12 | downgrade 到無 provd 的槽 | — | 舊槽無 provd、無 policy → 無廣播;舊 autocommit 只 WARN | `prov-downgrade-254` 斷言 WARN 行 |
| L13 | bcm2710 | — | ❌ 未測;patch / policy / init 共用 | — |
| L14 | bcm2711 | — | 本文件 | 全部 |
| L21 | trial 上 app 操作 | — | STATUS `updating=1`;改狀態動詞 helper `EBusy` → 7 | `prov-trial-busy-254` + STATUS |
| L24 | 兩支手機同時認領 | — | 一個 0、一個 7;成功後另一條 Disconnect | `prov-two-phones-254`(sock;BLE 空中單連線做不到,寫明) |
| L34 | 認領回應遺失 | — | `psk_replay` session → begin → op/nonce(同一對)→ replay | `prov-ble-claim-254`(含 begin→op/nonce→replay 順序;負對照:v1 的「op/nonce 再呼叫 nonce」→ CheckMac 失敗) |
| L39 | 遠端讓 provd crash(trial) | — | health 不看 provd;latch 在 helper 且由 kernel 量 | `prov-provd-dos-254` |
| L62 | privacy / RPA | — | 前置全 1 才廣播;900 s 後重註冊換 RPA | `ble-rpa-254`(三態;log 無 nonce) |
| L65 | bluetoothd crash | — | 同 L9 | |
| L66 | 第 3 條連線 / 大訊息 / 洪水 | — | 擠最舊未認證 / 拒;8 KiB;20/分 | `prov-sec-hog-254`(加:2 條未認證佔著 → 合法第 3 條仍能交握)、`-oversize-254` |
| L67 | health 轉壞(root 開互動 bluetoothctl) | — | ≤ 10 s 撤廣播;既有 session 不斷 | `prov-boot-254` 白箱 |
| L68 | root 手動 `advertise on` | panic 風險 | kernel patch 後不 panic;provd log foreign instance | `prov-sec-adv-len-254` 臂 2 |
| L69 | 交握中 PSK 被 helper 換掉 | — | 用舊快取完成或失敗;下一條重拉 | 單元 |
| L70 | 開機 helper `BootFinish` 持鎖 ≤ 120 s | — | `info.state` / `health.get` 不取鎖 → STATUS、廣播前置照常;`sign.*` 排隊 → `node_cert` 晚 ≤ 120 s → 期間**不廣播**(交握需要 node_cert) | `prov-boot-254`:記錄註冊時間;白箱 helper 持鎖 120 s 期間 STATUS 可讀(負對照:v1 行為 = 讀不到) |
| **L71** | helper 忙(`net.apply` 180 s)時另一支手機 | — | STATUS / CTRL 快取可讀;`info` 可答(快取);**NXpsk0 新連線的 `psks.get` 若快取失效中 → 可能交握逾時一次**;health 輪詢不受影響 | 白箱:helper 持鎖期間 02 讀 STATUS、`peer.py` 交握(預期:快取有效時成功) |
| **L72** | ujail 缺 / jail 建不起 | — | `requirejail` → 不啟動,procd log | 白箱:改名 ujail → provd 不起、無廣播(負對照:無 `requirejail` → 以 471 無 jail 跑) |
| **L73** | `hci0` 整次開機不出現(BT 韌體缺) | — | provd 等 `Adapter1` 物件;health `hci0_powered=0` → 不廣播;退避 log | `prov-dep-restart-254` 的無 hci0 臂(已有) |
| **L74** | adapter 熱移除 / 重加(`InterfacesRemoved/Added`) | — | 丟廣播 / app 狀態 → 重 Register | 白箱:`hciconfig`不在 → 以 bluetoothd restart 代理(= L9) |
| **L75** | 手機在 `net.apply` 進行中斷線 | — | helper 做完;provd 丟棄遲到回應(session 已不在);app 重連讀 `info.unfinished` / `net_version` | `prov-netjoin-254` 加臂:join 送出後立刻斷線 → 節點仍入網、重連 `info` 一致 |
| **L76** | OTA(`batman-slot` 寫另一槽)期間 session 開著 | — | helper `otaBusy` → `net.apply` / leave 回 7;`info` 照常;重開後 session 全斷 | `prov-leave-ota-254` 既有 |
| **L77** | helper.sock 目錄不存在(helper 還沒 `PrepareDir`) | — | jail mount 失敗 → `requirejail` 不啟動 → procd respawn 5 s 後再試(helper S89 早於 provd S92,正常不會發生) | 白箱:停 helper、刪目錄、restart provd → 退避 / respawn 直到 helper 回來 |

## 6. 依賴與證據

| 依賴 | 證據 | 狀態 |
|---|---|---|
| BlueZ D-Bus 廣播 / GATT 行為、ATT 錯誤碼、`Acquire*` options、斷線 HUP | F-P11、F-P16 | ✅ 原始碼 |
| kernel Flags 加法、mgmt 上限、RPA 時序、斷線後自動重開廣播 | F-P10、F-P17 | ✅ 原始碼 + 實證 |
| `flynn/noise` API(注入 e、psk0、ReadMessage 失敗偵測、無 DH) | F-P14 | ✅ 原始碼 |
| godbus fd passing、無 ObjectManager、RequestName/AddMatch 目的地 | F-P15 | ✅ 原始碼 |
| dbus-daemon 重啟 unlink socket;default policy 內容 | F-P18 | ✅ |
| procd jail 參數語意、`requirejail` | F-P19 | ✅ 原始碼 |
| helper 契約(動詞、欄位、碼、nonce、mutex、30 s) | F-P6–F-P9 | ✅ 原始碼 |
| ujail 以 471 跑靜態 Go | F-P3 | ✅ |
| **以目錄 bind 的 socket:helper 重啟後 jail 內看得到新 socket;唯讀 bind 的 dbus socket 可 connect** | — | ⚠️ 實作第一步在 04 prov_test build 驗(L10 / L11 臂就是測試) |
| `Read Advertising Features`(mgmt 0x003D)在 helper 的 mgmt socket 可用、回 `num_instances` | kernel `mgmt.c read_adv_features` | ⚠️ 讀原始碼確認回應格式後實作;節點上 provd 註冊前後各讀一次 = L2 測試 |
| ujail `-C` JSON `{"bounding": []}` 格式 | F-P19 | ✅ |
| `/etc/batman-build` 0644、無 `BATMAN_MODEL` | F-P23 | ✅ |
| iOS `scanForPeripherals(withServices:)` 以 UUID 列表比對 | Apple 文件 | ⚠️ app 階段(U9)實證 |
| 上游 CVE 修法 commit | 待查 | ⚠️ D3 核准後 |

## 7. 待決

| # | 題 | 建議 |
|---|---|---|
| D1 / D2 | 函式庫 | 定案 P-U15 / P-U16 |
| D3 | kernel board patch backport CVE-2025-38303 + CVE-2026-64539 | **做**(P2 firmware PR);正向見證 §4.8;負對照 = F-P10 紀錄 |
| D4 | 服務 UUID | 核准時 `uuidgen` |
| D5 | ADV 只放 UUID 列表 | 定案(§1.3);代價寫明 |
| D6 | 兩個二進位 | 定案 |
| D7 | 協定 v0.8 變更(`info-resp` 11、`info.net` 4、`info.state` 5、`health.get` / `info.owners`、`psks.get` 去 4/5、`s_node` 每次 provd 啟動、replay 的 begin/op-nonce 同一對、sock 計入連線數、擠槽規則、`auth/owner` 回空) | 同 PR 的 docs 部分 |
| D8 | autocommit BLE WARN → FAIL | **不在 P2**;checklist 獨立決定(前提 = 本設計的 kernel 求證 latch) |
| D9 | `-wbox` 變體加 `btmgmt` | 做(gate 斷言 release 無) |

## 8. 安全

**資產**:同 stage1 §8。P2 新增的面 = provd 行程、D-Bus policy、廣播、GATT、helper 新動詞。

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| BLE 路人 | 追蹤 | ADV 只有 UUID 列表;RPA 每 900 s 換;health 不對不廣播。**誠實界線**:900 s 窗內連線前後同 RPA;SSID / HaLow MAC 等穩定識別(stage1 F29) | `ble-rpa-254`、`ble-privacy-254` |
| BLE 路人 | 探 PSK / 「是不是我那隊」 | 假 msg2 **等長**(711)、同 DH 次數、等逾時;msg1 長度錯也走假路徑 | `prov-sec-psk-timing-254`;單元 `len(fake)==len(real)`(mutant FAIL) |
| BLE 路人 | 佔連線 | 擠最舊未認證;**誠實界線:BLE 單連線,一個路人反覆連就能佔住管理面**(§1.3);擁有者仍有 ssh | `prov-sec-hog-254` 兩臂 |
| BLE 路人 | 大訊息 / 洪水 / 暴力認領 | 8 KiB;20/分;3 次斷 | `-oversize-254`、`prov-sec-claim-brute-254` |
| BLE 路人 | 讓 provd crash → 影響 autocommit | autocommit 不看 provd;`adv_registered_once` 由 helper 向 kernel 量、latch | `prov-provd-dos-254` |
| 路人 → 攻陷 provd | 改網 / 換擁有者 / 讀秘密 | helper 驗所有 owner-op 與 CheckMac;provd 無 keystore;jail 無 caps 唯讀;policy 只放行 8 個方法。能做的:看經過的明文、停廣播、斷線、**假報 `adv.registered` ✗(動詞不存在)**、**註冊 31 B 廣播 → panic → 只有 kernel patch 擋(D3)**、對 helper 洪水(見下) | `prov-sec-dbus-254`(471 呼叫 `RegisterAgent` / `Properties.Set` / `Device1.Pair` / `UpdateActivationEnvironment` → AccessDenied);臂 2 |
| 攻陷的 provd | helper DoS:`nonce` 洪水(≤ 4 / h,便宜)、`sign.*`(2/s 全域)、`psks.get` 連打(取 mutex、讀 record) | 既有額度;`psks.get` 無額度 → **P2 加 helper 側 1/s 額度**(provd 正常用量 = 每條連線一次) | Go 單元(helper) |
| 攻陷的 provd | 得到 `adv_owner / adv_member` | `psks.get` 不回 4/5 | 單元 |
| 本機非 root | 連 provd / 偽造手機 | release 無 `gatt.sock`;prov_test 目錄 root 0700;provd 不聽網路 | `prov-sock-254`、tmp-trust |
| 本機非 root | 植入 `provd.env` | 只在 test init;驗 root 0700 / 非 symlink / 0600 link 1 | init 單元 |
| bluetoothd(root) | 壞回呼 | 視為不可信輸入;驗 sender unique name | 單元 |
| 供應鏈 | 兩個 vendored 函式庫 | `go.sum` 釘;PR 列 hash;`go mod verify` CI | CI |
| 我們自己 | 兩寫者(root 廣播)、fail-open、log 洩密、ADV 長度 | §3;health 任一欄缺不廣播;log 只印 type / code / 長度;ADV 自檢 | `logread | grep -c <psk hex>` = 0;`ADV_LEN_TEST` |

**失效模式**:前置不成立 → 不廣播;health 轉壞 → 撤;helper 不可達 → STATUS 回 ATT 0x0E、請求 `E_BUSY`;ujail 缺 → 不啟動。唯一 fail-open:`model` 缺 → `"dev"`。

## 9. 測試

- **Go 單元(CI)**:`noise_test`(三組向量逐位元組、`fake_msg2_rule` 長度 == 711、6 次 `ReadMessage` 計數、msg1 長度表)、`frame_test`(`gatt_framing`、`envelope`、`chunking` 重組 bytes == 原封、`chunk_boundary`、8 塊上限)、`status_test`(`status_public` 三例、錯誤名 → 預期 ATT 碼)、`route_test`(type → verb、`claim/finish` 拆欄位、replay 的 nonce 對、角色拒絕、**錯誤碼表全列**、`id` 倒退、擠槽、假時鐘:30 s keepalive、HELPER_WAIT 丟遲到回應)、`adv_test`(28 過 / 29 拒)。每條有 mutant 註解。helper:`health.get` 不取 mutex(測:持鎖 goroutine 期間呼叫回得來)、`adv_registered_once` latch 來自假 mgmt 回應、`psks.get` 無 4/5、額度。
- **CI `peer-vs-provd`**(runner 預置):`useradd -u 471 provd`;`mkdir -m 0700 /tmp/run/batman`、`/etc/batman-prov/`、`/opt/batdata/state`;helper root `realSys` + PATH stub(`batman-slot is-trial` rc 1、`batman-config-save --prov-get` rc 11、`halow-setkey`、`prov_apply_lock`、`uci`);無 p5 → helper `unknown(no-p5)` → 改狀態動詞 `EState` → CI 跑交握 / `info` / STATUS / 限制 / `claim/begin` + `op/nonce`,`claim/finish` 預期 11;provd `sudo -u provd` + `SOCK_ONLY=1`。負對照:`peer.py --selftest` 刪比對 → FAIL;`FAST_FAKE_DELAY_MS=20` → timing FAIL。
- **節點(H3 §6.3 + 本文件)**:§5 各列;新單位 `prov-sec-adv-len-254`(臂 1 `ADV_LEN_TEST=29` → log + `ActiveInstances=0`;臂 2 kernel patch 正向 §4.8);`prov-dep-restart-254` 加 dbus 臂;`prov-boot-254` 加 latch 兩臂與 L70/L71 白箱;`prov-ble-claim-254` 加 begin→op/nonce→replay;`prov-netjoin-254` 加 L75 臂;`prov-sec-hog-254` 加合法第 3 條臂;`prov-sec-dbus-254` 加 `UpdateActivationEnvironment`。
- **release gate**:provd 二進位無測試字串;image 無 `/usr/bin/btmgmt`;`/etc/init.d/batman-provd` 無 `provd.env`;`bluetooth.conf` 含 `policy user="provd"`;`-wbox` 變體相反。
- **手動**:iPad GATT 回歸(H3 乙部文件)。

## 10. 回報上層

1. stage1 §2 / §3 / §4.1 / §4.7 / §4.8 / §6.4 (8) / §8 F28:兩個二進位;ADV 只 UUID;health 經 `health.get`;`adv_registered_once` 由 helper 向 kernel 量;autocommit 只 WARN;RPA 900 s 誠實界線;helper 新動詞與 mutex 規則;`psks.get` 去 4/5。
2. h23 §4.9 作廢;§6.3 `ble-rpa-254` 無 nonce、新單位與新臂;§4.8.3 `ADV_LEN_TEST`;節點端 `btmgmt` 由 `-wbox` 變體提供;CI runner 預置(§9)。
3. 219 v0.8:D7 全部;§3.4 註明 msg1 長度檢查;§8 擠槽規則與 BLE 單連線誠實界線。
4. wireless-txn §19:`unfinished` 落點。
5. #254 checklist:D3 commit id、D8、B16、`Read Advertising Features` 實證、目錄 bind 實證、iOS UUID 過濾、`capabilities` 偵測、`psks.get` 額度。

## 11. 殘項(回 #254)

`capabilities` 固定;idem 快取(P3);HTTP 不做;P3 動詞;bcm2710;B16;`auth/owner` 的 `adv_owner_key`;BLE 單連線被路人佔住(#255 考慮擁有者優先);autocommit WARN→FAIL(D8)。

## 12. 工作順序

1. 本設計 v2 兩位整份重審 → 0 BLOCKER / 0 MAJOR;D4 `uuidgen`;D3 commit id。
2. docs:219 v0.8 + CDDL + 向量(`info` 11、`info.net` 4、replay 順序)。
3. H3 harness(照 §4 契約)→ PR 先 merge。
4. P2 實作:helper 改動(Go 單元 + mutant)→ provd(先 `SOCK_ONLY` 對 `peer.py`;再 04 prov_test build 驗 `Acquire*`、目錄 bind、dbus 重啟)→ firmware(policy、kernel patch、btmgmt 變體、pin)→ rc → 04 跑 §6.3 → 正式全套。

## 13. v1 審查 → v2 對應

| 發現 | 處置 |
|---|---|
| B-B1 / A-M4 假 msg2 短 48 B | §4.2:`random(48 + len + 16)`,等長 711;單元斷言(F-P13) |
| B-M1 dbus socket 檔案 bind | §3 / §4.5:掛目錄 `/tmp/run/dbus`;L10 加 dbus 臂(F-P18) |
| B-M2 / A-M5 helper 單 mutex 卡 STATUS / 撤廣播 / 第二連線 | §3 / §4.1 / §4.3:唯讀動詞不取 `n.mu`、STATUS/CTRL 快取、PSK / owners 快取 + 失效規則;L70 / L71;誠實界線(新連線可能逾時一次) |
| B-M3 ≤ 10 s 撤廣播做不到 | §4.3 `health.get` 現算 + 5 s 輪詢 → 最壞 ≈ 5 s |
| B-M4 30 s 閒置假 `E_BUSY`、HELPER_WAIT 收尾 | §4.3:keepalive 20 s、冪等重送一次、超時關連線 + id 丟棄;假時鐘單元 |
| B-M5 / A-M11 `adv_registered_once` 自報 | §1.3 / §3 / §4.3:helper 以 mgmt `Read Advertising Features` 自量 latch;刪 `adv.registered`;兩臂負對照 |
| B-M6 / A-M9 節點無 btmgmt | §1.3 / D9:`-wbox` 變體加 btmgmt;gate |
| B-M7 / A-M7 RPA 不實 | §1.3 / §4.4 / §8:900 s 誠實界線(F-P17) |
| A-M1 `claim.verify` 欄位 | §4.3:provd 拆 `claim/finish` + begin 的 owner_pub(F-P8) |
| A-M2 錯誤碼三處 | §4.3 唯一表:23→13、4→4、5→5、claim 的 3→9、reason 10 |
| A-M3 replay 兩次 nonce | §4.3 nonce 對快取;L34 負對照(F-P9) |
| A-M6 autocommit revert 不實 | §1.3 / L6 / D8(F-P20) |
| A-M8 未認證 session 擠掉 | §1.3 / §4.1 / L66 兩臂 |
| A-M10 `requirejail` | §4.5 / L72(F-P19) |
| A-M12 分塊重組轉送 | §1.3 / §4.3:重編整封、8 塊上限、單元 |
| B-m1 / A-m1 msg1 長度 | §4.2 前置檢查(走假路徑) |
| B-m2 6 把 PSK 做法 | §4.2 改為 6 個 HandshakeState + 注入 e(F-P14) |
| B-m3 / A-m5 ATT 錯誤碼 | §4.1 `org.freedesktop.DBus.Error.Failed` → 0x0E(F-P16) |
| B-m4 / A-m3 policy 多餘 / 過寬 | §4.7 拿掉 own、DBus destination、receive_sender、root 回呼列;加負測試 |
| B-m5 / A-m7 多餘掛載、空 boot_id 檢查 | §4.5 / §4.4 |
| B-m6 / A-m8 HELPER_WAIT 收尾 | §4.3 |
| B-m7 矩陣缺列 | L73–L77 |
| B-m8 BLE 單連線 | §1.3 / §8 誠實界線 |
| B-m9 `psks.get` 多給 4/5 | §1.3 / §4.3 |
| B-m10 / A-m4 `auth/owner` 由 provd 驗、replay 不比 owner_pub | §1.3 兩列 |
| B-m11 sign 額度 | §3:間隔 ≥ 2.1 s(F-P24) |
| B-m12 / A-m9 init 變體 | §4.5 兩個 init 檔 + gate |
| B-m13 / A-m15 文字 | 已清 |
| A-m2 元件表缺 `info.owners` | §2 |
| A-m6 sender 驗證、goroutine | §4.7 / provd 內部寫鎖(實作) |
| A-m10 patches 每板一份 | §2 / §4.8 |
| A-m11 CVE commit 未給 | §4.8 ⚠️ + §6 |
| A-m12 policy 在 firmware | §3 gate 斷言 + AccessDenied log |
| A-m13 `BATMAN_MODEL` | §4.3(F-P23) |
| A-m14 §8 引錯負測試 | §8 改引臂 2 |
| A §4 矩陣補充(ujail 缺、socket 目錄不存在、phone 中斷、fresh `info.state`) | L72 / L77 / L75 / L1 |
