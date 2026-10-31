# #254 PR-P2:`batman-provd` — BLE 上的供裝協定行程(設計 v1)

狀態:v1,2026-10-31,待兩位對抗式審查。上層:`254-stage1-impl.md`(v19)§2 / §4.1 / §4.6–4.8 / §8;協定 `219-protocol.md` v0.7 + `219-protocol.cddl`;harness 契約 `254-h23-harness.md` §4.8–4.10 / §6.3;無線交易 `254-wireless-txn.md` §19 的 P2 契約。本文件只寫 P2 新增或改變的部分;沒寫到的一律沿用上層。**與上層衝突處以 §1.3 為準。**

## 0. 一句話

`batman-provd` 是一個 uid 471、ujail 裡的 Go 行程:向 BlueZ 註冊一個廣播與一個 GATT 服務,把每條 BLE 連線變成一條 Noise 安全通道,解出 CBOR 信封後**原封不動**交給 root 的 `batman-provhelper` 執行,自己只持有每次開機的 Noise 靜態金鑰、角色、計數器與逾時;它連 helper 的 health 檔都讀不到,要什麼都經 socket 問 helper。

## 1. 決策、範圍、事實

### 1.1 使用者決策(2026-10-31,#254 留言 6539606175)

| # | 決策 | 後果 |
|---|---|---|
| P-U15 | Noise 用 vendored `github.com/flynn/noise` v1.1.0 | §7 D1;只依賴 `x/crypto`;build 不連網 |
| P-U16 | D-Bus 用 vendored `github.com/godbus/dbus/v5` v5.2.4 | §7 D2 |
| P-U17 | P2 的 provd 同時轉送 `network/join`、`network/leave`、`network/update` 與 `info`(含 `info.net` owner-only、`unfinished`、leave ≤ 165 s / net.apply ≤ 180 s);邀請、全隊狀態、診斷、改名留 P3 | §4.5 訊息表;H3 §6.3 單位可在 P2 rc 上跑 |
| P-U18 | 設計期在 04 唯讀探查 + ≤ 2 分鐘試廣播 | 已做;第 2 段試廣播讓 04 kernel panic(§1.2 F-P9),**之後不再在 04 試廣播** |

### 1.2 事實(全部 2026-10-31 唯讀實查或原始碼;`F-P*` 為本文件新增)

| # | 事實 | 證據 |
|---|---|---|
| F-P1 | 02/04 = `1.5.14-wsl.16+c46dfc9.fw6aa0241`,slot A committed,lock UNPROVISIONED;bluetoothd 5.72 跑著、`hci0` 在、`Powered: yes`、`Pairable: no`、`Discoverable: no`、`Roles: central / peripheral`;**無 provd 二進位、無 provd 行程**;uid/gid `provd` 471 存在;`/sbin/ujail` 在(procd-ujail 2026.03.14,支援 `-U -G -C -S -c -r -w -n -E -P`) | 04 `bluetoothctl show`、`id provd`、`ujail -h`、`ls /usr/bin/batman-prov*` |
| F-P2 | 廣播能力:`SupportedInstances 5`、`SupportedIncludes tx-power / appearance / local-name`;**沒有 `SupportedSecondaryChannels`** → 控制器(BCM4345C0)無 LE extended advertising → kernel 走 legacy 路徑,ADV 與 scan response 各 31 B | 04 `bluetoothctl show` |
| F-P3 | ujail 以 uid 471 執行 Go 二進位可行:`ujail -n p2probe -U provd -G provd -r /usr/bin/batman-provhelper -r /etc/batman-build -- /usr/bin/batman-provhelper --version` → 印版本、rc 0 | 04 實跑 |
| F-P4 | D-Bus:`/var/run/dbus/system_bus_socket` 是 `srwxrwxrwx root`(任何 uid 連得上);`/etc/dbus-1/system.d/bluetooth.conf` 只有 `<policy user="root">`、無 default policy、註解明寫 provd 的 policy 等 P2;**檔案由 firmware `package/batman/batman-ble` 擁有**(不在 Batman feed;`batman-ble` 的 Makefile 自己說「final home is the Batman feed」);`main.conf` = stage1 §4.6 的值;節點沒有 `dbus-send` / `busctl` / python | 04 `ls -la`、`cat`、`grep -l … /usr/lib/opkg/info/*.list` → `batman-ble.list`;firmware `package/batman/batman-ble/Makefile` |
| F-P5 | helper 的 health 檔在 `/tmp/run/batman/batman-prov.health`,**目錄 `/tmp/run/batman` 是 root `drwx------`** → uid 471 讀不到;欄位 `adv_registered_once` 由 P1 永遠寫 0(`health.go:138`),沒有任何介面讓別人改它 | 04 `ls -la /tmp/run/batman/`;`health.go` |
| F-P6 | helper socket 契約:`SOCK_SEQPACKET` `/tmp/run/batman-prov/helper.sock`(目錄 root 0750 gid 471,socket 0660);請求 = `{1: verb, 2: id, 3: args}` **恰好 3 個 key**,回應 `{1: id, 2: code, 3: body}`;一條連線序列化、`Idle` 30 s 讀逾時(只在等下一個請求時計)、> 64 KiB 關連線、壞封包回 `code 20` 後關;`Node.Handle` 全程持 `n.mu`(一個 `net.apply` 可長達 180 s + save);動詞表見 `node.go:183-265`:`info.{cert,ecdh_pub,boot_id,counter,state,net}`、`nonce`、`sign.{static,ecdh_proof,peer}`、`psks.get`、`claim.verify`、`claim.replay`、owner-op 動詞 `net.apply / network.leave / owner.add / owner.remove / settings.set / root_password.reset / diag.bundle / ssh_keys.set`;錯誤碼 `EBusy 7`、`EUnsupported 6`、`ESchema 20`、`EApply 21`、`EState 22`、`ELockIncomplete 23` 等 | `sock.go:136-170`;`node.go:157-265`;`main.go:579-624` |
| F-P7 | Go module `batman-prov`:`go 1.26.4`,vendor 只有 `golang.org/x/crypto v0.58.0`、`x/sys v0.49.0`;自家 `cbor`(core deterministic 編解碼、`Map`/`M`/`Without`)、`cose`、`proto`(標籤、ClientChal、CheckMac、ArgsHash、OwnerOpInput、ES256、HKDF、PSK 導出)、`keystore`、`provstore`、`health`、`sock`、`seam`;只有一個 cmd `batman-provhelper`(`GO_PKG_BUILD_PKG` 單一);`USERID:=provd=471:provd=471` 在 `batman-prov` 的 Makefile | `feed/batman-prov/{Makefile,src/go.mod,src/vendor/modules.txt}` |
| F-P8 | WSL 可取得:`flynn/noise v1.1.0`(依賴 `x/crypto`)、`godbus/dbus/v5 v5.2.4`(無依賴);WSL 的 go 是 1.22.2(需 `GOTOOLCHAIN=auto` 拉 1.26);firmware 的 golang/host 由 `GO_VERSION_MAJOR_MINOR` 決定(#252:go1.26.4) | `go get` 於 /tmp/p2mod;`feeds/packages/lang/golang/golang/Makefile:14` |
| **F-P9** | **註冊 31 B 的 ADV 資料讓 04 kernel panic(1/1)**:root bluetoothctl `agent off` → `advertise` 只放 128-bit service data、payload 13 B(AD 結構 2+16+13 = 31)、discoverable off、name off → `Kernel panic - not syncing: stack-protector: Kernel stack is corrupted in: hci_cmd_sync_status`,trace `hci_update_adv_data_sync ← hci_schedule_adv_instance_sync`,04 重開(`boot-reasons` `prev=PANIC`,pstore 80366865)。機制(原始碼):BlueZ `src/advertising.c:873 get_adv_flags` 在 adapter 不 discoverable 時只給 `CONNECTABLE`,`calc_max_adv_len`(:780)= 31;kernel `mgmt.c:8498 tlv_data_max_len` 同樣只在 `DISCOV|LIMITED_DISCOV|MANAGED_FLAGS` 才扣 3 → 31 B 通過;`eir.c:245 eir_create_adv_data` 在 `!HCI_BREDR_ENABLED`(我們 `ControllerMode=le`)**無條件**寫 3 B Flags(`LE_AD_NO_BREDR`,:276-296)再 `memcpy` 31 B(:300,無長度檢查)→ 34 B 進 `hci_sync.c:1333` 的 stack 變數 `hci_cp_le_set_adv_data.data[31]`。= **CVE-2026-64539**(「Bluetooth: eir: Fix stack OOB write when prepending the Flags AD」)+ 較早的 CVE-2025-38303;6.6.138 的 `eir_create_adv_data(hdev, instance, ptr)`(`eir.h:12`)兩者都沒有 | #254 留言 6539869418 / 6539887614;pstore 副本 scratchpad `crash04/`;firmware build 樹原始碼行號 |
| F-P10 | BlueZ 5.72 把 `ServiceUUIDs`、`ServiceData`、`ManufacturerData`、`Data`、`Appearance` 全放 ADV(`client->data`,`generate_adv_data` :800-830);**scan response 只放 Local Name**(`generate_scan_rsp` :833-846,`client->scan` 只被 `bt_ad_add_name` 寫)→ h23 §4.9「service data 放 scan response」在 BlueZ D-Bus API 上做不到 | `advertising.c` |
| F-P11 | 第 1 段試廣播(128-bit UUID 列表 18 B + 9 B service data = 45 B)被 BlueZ 自己拒絕(`Advertising data too long`),無副作用 → BlueZ 的 31 B 上限檢查有效,只是沒算 kernel 的 3 B Flags | 同上 |
| F-P12 | 向量 `tests/vectors/219-protocol/vectors.json` 已含 `noise_nx`、`noise_nxpsk0_owner`、`noise_nxpsk0_replay`、`fake_msg2_rule`、`gatt_framing`、`envelope`、`chunking`、`chunk_boundary`、`status_public`、`op_nonce`、`claim_*`、`owner_op`、`node_cert`、`identity_file`;`verify.py` 195 項;`flynn/noise` 交叉驗證尚未做(協定 §11「尚未」) | `vectors.json` keys;`README.md` |
| F-P13 | `provclient`(`tests/tools/provclient`)已有 `info / claim / claim-attacker / replay / ssh-keys / root-reset / rename / verb / node / sign / keygen / selftest`,`unixpacket` 連 helper,`sock-as <uid>` 降權 | `main.go:522-640` |
| F-P14 | 02/04 的 `/etc/batman-build` 由 root 寫;provd 要讀它(`fw_version` / `board`)須以 `-r` 掛進 jail,權限 ⚠️ 未查(F-P3 的 jail 以 471 讀到了 → 至少 0644) | F-P3 |
| F-P15 | `batman-provhelper.init`:START 89 / STOP 15,`respawn 3600 5 0`;無 jail | `files/batman-provhelper.init` |
| F-P16 | `batman-autocommit` 的 `health_ok()` 要 `adv_registered_once=1`(有 `ble-ok` 時)→ 今天有 `ble-ok` 的節點在 P2 之前永遠 WARN(F12 的 `WARN ble:` 行,不擋) | stage1 §6.4;h23 F12 |

### 1.3 與上層設計不同處(→ 回報上層 §10)

| 上層 | 本文件 | 理由 |
|---|---|---|
| stage1 §2「同一個 Go 二進位,argv[0] 決定模式」 | **兩個二進位** `batman-provhelper`(root)與 `batman-provd`(471),同一 module、同一套件 | ujail `-r` 只掛 provd 那一支;release gate 的 helper 檢查不受 provd 影響;provd 不帶 keystore / provstore / shacrypt 程式碼(連結到就是攻擊面) |
| h23 §4.9「ADV = Flags + 128-bit UUID 列表 21 B;B16 service data 放 scan response」 | **ADV = Flags(kernel 加)3 + 128-bit Service UUID 列表 18 = 21 B,其餘 10 B 不用;無 scan response;無 Local Name、無 service data** | F-P10:scan response 放不了 service data;F-P9:ADV 總長 ≤ 28 B 的硬限制。`updating` 與 `device_id` 末 4 字元只在 GATT `STATUS`。B16(擁有者 / 成員標記、nonce)維持 #255 |
| stage1 §1.3「adv 帶 `device_id` 末 4 字元」 | 不帶(見上) | 同上;stage1 §4.8 本來就把末碼放在 `status/public` |
| stage1 §8 F28「provd 每 `rpa_timeout` + 隨機 30–120 s 重新註冊廣播並換 B16 payload 的 nonce」 | 重新註冊照做(為了換 RPA),**payload 不變**(沒有 nonce 可換) | B16 不在階段 1 |
| stage1 §3「provd 讀 health 檔的 `privacy / sc / sc_file / bondable`」 | provd **讀不到** health 檔(F-P5);改為 helper 新動詞 `health.get` 回同一行;`adv_registered_once` 由 helper 新動詞 `adv.registered` 設(本次開機 latch) | F-P5 |
| h23 §4.8.3「`GATT_ENCRYPT_CTRL=1` 讓 provd 把 CTRL 宣告成 encrypt-read」 | 保留;另加 `ADV_LEN_TEST=<n>`(provd 試圖註冊 n B payload,預期被 provd 自己拒;§8 負對照) | F-P9 |
| 協定 §8「同時 BLE 連線 2」 | 2 條 BLE **或** sock 連線合計(sock 只在 `prov_test`) | h23 §4.8.2 |
| h23 §6.3 L24「兩支手機同時 `claim/finish` → 一個 0、一個 `E_BUSY`(7)」 | 照做;**認領成功後 provd 斷開其他所有 session**(它們是 unclaimed 時建的 NX session,節點已 claimed 就不該存在) | 協定 §3.1「已認領的節點一律拒絕沒有 PSK 的 NX」 |

## 2. 元件

```
手機 / peer.py ──BLE GATT(或 prov_test 的 gatt.sock)── batman-provd(uid 471,ujail,-c no-new-privs,caps 空)
   │ godbus/dbus/v5 → org.bluez:LEAdvertisingManager1.RegisterAdvertisement、GattManager1.RegisterApplication、
   │                  Device1.Disconnect、ObjectManager.GetManagedObjects、Properties.Get/GetAll;匯出 LEAdvertisement1、
   │                  GattService1/GattCharacteristic1(RX/TX/CTRL/STATUS)
   │ flynn/noise:Noise_NX / NXpsk0_25519_ChaChaPoly_SHA256;自家 cbor;proto 的導出函式(HKDF、標籤)
   └─ /tmp/run/batman-prov/helper.sock(SEQPACKET,SO_PEERCRED 471)──▶ batman-provhelper(root;P2 只加 2 個動詞)
```

- **套件**:`feed/batman-prov` 多產一支 `batman-provd`(`GO_PKG_BUILD_PKG` 加 `batman-prov/cmd/batman-provd`)、`files/batman-provd.init`(START 92 / STOP 10,ujail)、`files/provd-dbus.conf` **不在這裡**(見下)。vendor 加 `flynn/noise v1.1.0`、`godbus/dbus/v5 v5.2.4`(`go mod vendor`,`go.sum` 釘 hash;審查時列 sha)。
- **firmware**(同一個 P2 的 firmware PR):`package/batman/batman-ble/files/bluetooth.conf` 加 `<policy user="provd">` 與 root policy 的回呼放行(§4.7);board patch **`0015-bluetooth-eir-adv-flags-oob-254.patch`** backport CVE-2026-64539 + CVE-2025-38303(§4.8;待決 D3);pin Batman main。
- **helper 新動詞**(§4.3):`health.get`、`adv.registered`。其餘 helper 不改。
- **harness(H3,照本契約先 merge)**:`peer.py`、`transport_sock.py` / `transport_ble.py`、`prov-wbox-254.sh set-provd-env`、§6.3 單位。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| BLE 廣播 instance(`/org/bluez/hci0` 上的 LEAdvertisement1 物件) | provd(注冊 / 撤銷;一次只有一個) | — | root 手動 bluetoothctl `advertise on` 是第二寫者 = 操作失誤(runbook 禁止;F-P9 證明它還會讓節點 panic);provd 看到 `ActiveInstances` ≠ 自己預期 → log `adv: foreign instance` 不動作 |
| GATT application(服務 + 4 特徵) | provd | bluetoothd 代理手機的讀寫 | 一個 app 物件;bluetoothd 重啟後 `NameOwnerChanged` → 重新 Register |
| 每條連線的 Noise 狀態、角色、`h`、計數器、逾時、認領失敗計數、`claim-in-progress` 旗標、全域交握計數 | provd 記憶體 | — | 重開 / respawn 全部歸零(協定 §8「只存在記憶體」) |
| `s_node`(X25519 靜態金鑰)與 `node_cert` 快取 | provd:啟動時產生 `s_node`,請 helper `sign.static` / `sign.ecdh_proof` 簽,組 `node_cert` 快取 | — | 每次 provd 啟動(含 respawn)重新產生 → `node_cert` 的 `boot_id` 來自 helper `info.boot_id`(每次開機一個),`s_node_pub` 每次 provd 啟動不同:協定 §3.3「每次開機」放寬為「每次 provd 啟動」,**app 不得快取 `s_node_pub`**(本來就是每個交握重新驗) |
| PSK 集合(`psk_owner[≤4]`、`psk_member`、`psk_replay`) | helper(`psks.get` 導出);provd 快取 | provd | provd 在每次**新連線**的交握前重拉一次(便宜:一個 socket 往返;避免換密碼 / 認領後用到舊值);helper 回應缺某把 → 以隨機假 PSK 補足到 6 把 |
| `/tmp/run/batman-prov/helper.sock` | helper(P1) | provd | 不變 |
| `$RUNDIR/batman-prov.health` 的 `adv_registered_once` | helper(health tick);**值由 `adv.registered` 動詞 latch**(本次開機第一次成功 RegisterAdvertisement 後 provd 呼叫一次;helper 行程內 bool,helper 重啟歸零 → provd 收到 `NameOwnerChanged`(helper 不是 bus name)…helper 重啟時 provd 的 socket 斷 → provd 重連成功後**再呼叫一次** `adv.registered`(若自己仍有有效廣播)) | autocommit、provd(經 `health.get`) | 唯一的 health 契約仍是 stage1 §3 那一行 |
| `/tmp/run/batman-provd-test/`(`gatt.sock`、`provd.env`) | root(harness `prov-wbox-254.sh set-provd-env`:目錄 root 0700、檔 0600、非 symlink、link 1);**只在 `prov_test` build** 由 init 讀 `provd.env` 並以 `procd_set_param env` 傳給 provd;`gatt.sock` 由 provd 在 `SOCK_ONLY=1` 時建(目錄要先存在且是 root 0700,否則不建,log) | provd init、provd、harness(root 以 `provclient sock-as 471 -- proxy` 連) | release build:init 不讀、provd 無此程式碼路徑(build tag `prov_test`);release gate 加 `strings | grep -c provd-test` = 0 對 provd 二進位(§8) |
| dbus policy `bluetooth.conf` | image(firmware `batman-ble`) | dbus-daemon | 不是 conffile |
| `hci0` 的 Powered / Pairable / Discoverable / SC / privacy / bondable | bluetoothd(stage1 §3) | provd 經 `health.get`、`Properties.Get`(Pairable / Discoverable 斷言) | provd **不呼叫** `Properties.Set`(policy 也不放行) |
| provd 的 D-Bus bus name `org.batman.provd`(well-known,只為了 root policy 能指名回呼目標) | provd(`RequestName`) | bluetoothd(回呼) | dbus policy:只有 user provd 可 own(§4.7);被攻陷的 provd own 它本來就擁有,沒有多出權限 |

## 4. 契約

### 4.1 GATT(照協定 §4.1;本節定細節)

- 服務 UUID `BATMAN_SVC_UUID`:**核准本設計時 `uuidgen` 一次**,寫進 `219-protocol.md` §4.1、CDDL 註解、`provd/gatt.go` 常數、`peer.py`、`transport_ble.py`;特徵 = base 的第 3 組 16-bit 欄位 +1…+4(RX / TX / CTRL / STATUS)。待決 D4。
- 特徵旗標(BlueZ `GattCharacteristic1.Flags`):RX `write-without-response`;TX `notify`;CTRL `read`;STATUS `read`。**不帶任何 `encrypt-*` / `authenticated-*` / `secure-*`**(stage1 F43 的行為斷言);`GATT_ENCRYPT_CTRL=1`(prov_test)把 CTRL 改成 `encrypt-read`,只給 `prov-gatt-254` 的負對照。
- 資料路徑:RX 用 `AcquireWrite`(回 fd + MTU),TX 用 `AcquireNotify`(fd + MTU);provd 以 fd 收發,每個 fd 一個 goroutine;`AcquireWrite` 失敗(舊 BlueZ 行為)→ 退回 `WriteValue` 方法呼叫;TX 若 `AcquireNotify` 失敗 → 回 `NotSupported` 給手機、斷線(不走 D-Bus `PropertiesChanged` 的無回壓 notify;協定 §4.1)。
- `CTRL` = CDDL `ctrl`:`{1: 1, 2: 0, 3: max_frame, 4: 8192}`;`max_frame` = **244**(固定;手機以自己的 `maximumWriteValueLength` / MTU−3 為準,節點 → 手機的框架用 `min(244, notify_mtu − 3)`);手機送來的單一框架 > 512 B → 中止。
- `STATUS` = CDDL `status-public`:`{1: [1,0], 2: capabilities[], 3: state, 4: updating, 5?: 末4}`;`state` 由 helper `info.state` 對應(unclaimed 0 / claimed 1 / member 2 / legacy 3);`updating` = helper 回 `EBusy` 的 trial 狀態 → 由 provd 啟動時與每次 `info.state` 之後以 `batman-slot is-trial` **不能**由 provd 跑(jail 裡沒有)→ **helper 的 `info.state` 回應加 key 5 `trial: bool`**(helper 已有 `Sys.IsTrial()`);末 4 字元只在 state ∈ {0, 3}(`device_id` 由 helper `info.cert` 的 `sn` 導出);**helper 不可達 / 回錯 → STATUS 回 ATT error `0x0E`(Unlikely Error),不回猜的內容**。`capabilities` 階段 1 固定 `["halow"]`(04 無 gps 偵測邏輯,殘項)。
- 框架與重組:`flags(1) ‖ seq(2 BE) ‖ data`;每則 Noise 訊息 seq 從 0;序號不連續 / 累計 > `max_msg` / 單一 Noise 訊息解密失敗 / 缺開頭旗標 → **中止 = `Device1.Disconnect`**(policy 放行);sock 傳輸 = 關 socket。
- 連線數:`≤ 2`(BLE + sock 合計);第 3 條連上 → 立即 Disconnect(無任何 GATT 回應之前)。BLE 連線的識別 = `AcquireWrite` / `AcquireNotify` 的 `device` 選項(物件路徑)。

### 4.2 Noise 與 session(協定 §3)

- 模式由 helper `info.state` 決定:state ∈ {unclaimed, legacy} → `Noise_NX`;{claimed, member} → `Noise_NXpsk0`。prologue `"batman-prov/1" ‖ 0 ‖ "ble" ‖ 0 ‖ device_hint`(unclaimed / legacy = `device_id`;claimed / member = 空)。sock 傳輸的 prologue **也用 `"ble"`**(sock 是 BLE 的替身,向量相同;h23 §4.8.2)。
- 第 2 則 payload = `node_cert`(CBOR,協定 §3.3);provd 啟動時組一次:`dac_chain=[info.cert]`、`s_node_pub`、`boot_id=info.boot_id`、`ecdh_pub=info.ecdh_pub`、`sig_static = sign.static(s_node_pub)`、`sig_ecdh = sign.ecdh_proof()`、`sn=info.cert.2`。helper 的 `sign.static` 以自己的 `boot_id` 組被簽內容(stage1 §4.1)→ provd 傳 `s_node_pub`;簽章額度 2/s 全域不是問題(每次 provd 啟動 2 次)。
- **PSK 試法(§3.4)**:每條新連線交握前 `psks.get` → 候選 = `psk_owner[0..3]`、`psk_member`、`psk_replay`,缺的以 `crypto/rand` 32 B 補到 **6 把**;收到第 1 則後對 6 把**各**跑一次 `flynn/noise` `ReadMessage`(各自獨立的 HandshakeState 副本,同一把臨時 `e`),全部跑完才看哪一把成功(不提前 break);成功 → 以該 state 繼續,角色 = 擁有者候選 / 成員 / 擁有者重取(依是哪一把);**全部失敗 → 假第 2 則**:以**新**臨時金鑰 `e'` 算 `DH(e', e_手機)` 與 `DH(s_node, e_手機)`(與真交握相同次數的 DH),送 `e'_pub ‖ random(len(node_cert) + 16)`,然後**不關連線**,等到交握逾時(10 s)才 Disconnect;sock 傳輸:peer 自己斷 → 立即釋放槽(h23 §4.8.2)。`FAST_FAKE_DELAY_MS=<n>`(prov_test)讓假路徑多睡 n ms = `prov-sec-psk-timing-254` 的負對照。
- 未認領 / legacy 節點收到帶 PSK 的第 1 則(NXpsk0)→ 解不開 → 同樣走假第 2 則(不洩漏「這台未認領」以外的資訊;STATUS 本來就公開它)。
- 已認領節點收到 NX(無 PSK)第 1 則:NX 與 NXpsk0 的第 1 則格式相同(`e` + 加密 / 明文空 payload),provd **只以 state 選模式**,不嘗試另一種 → 假第 2 則。
- 交握完成 → `h`(32 B);`Split()` 兩方向 CipherState;AEAD 失敗即 Disconnect;累計 2^20 則 → Disconnect。
- 角色與允許訊息照協定 §3.5;本節補:`psk_replay` 只在 helper `psks.get` 回了它(= 恰好一位擁有者)時是真金鑰。
- 逾時(協定 §8):交握 10 s;未認證 / 擁有者候選閒置 30 s;已認證閒置 300 s;**一則請求在 helper 那邊進行中時不計閒置**(net.apply 可達 180 s + save;provd 等 helper 最多 `HELPER_WAIT = 330 s`,超過 → 回 `E_BUSY` 並 log `helper: no reply in 330 s for <verb>`,連線保留);全域交握 20 / 分(滑動窗,第 21 次直接 Disconnect 不回應);認領失敗 3 次 / 連線 → Disconnect;`NO_BRUTE_LIMIT=1`(prov_test)關掉這一條。

### 4.3 provd ↔ helper(擴充 stage1 §4.1)

| 動詞(新) | 授權 | 效果 |
|---|---|---|
| `health.get()` | 無(uid 471 本來就是唯一客戶) | 回 `{1: <health 行原文>}`(helper 上一次 tick 的那一行;helper 行程內快取,不重讀檔) |
| `adv.registered()` | 無 | helper 行程內 latch `advOnce = true`;之後 health 行寫 `adv_registered_once=1`;回 `{}`。helper 重啟歸零(health 的 `boot_id` 不變、值回 0 → autocommit 可能短暫看到 0:只影響 trial 上 provd 還沒重註冊的 ≤ 15 s;接受,trial 上 `ble-ok` 本來就不寫) |
| `info.state` | 無 | **加 key 5 `trial`**(bool,`Sys.IsTrial()`) |

- 連線模型:provd 一條常駐連線 + 一個 helper client goroutine(請求佇列,FIFO);helper 30 s 無請求會關連線 → provd 收到 EOF 就重連(退避 1 s → 2 s → … ≤ 30 s);**佇列中的請求不重送**(非冪等:`nonce`、`claim.verify`、`net.apply`),直接以 `E_BUSY` 回手機並 log。
- 信封轉送(stage1 §4.1 的「原始請求信封」):provd 解出 Noise 明文 = 完整 CBOR 請求 `{0,1,2,3,(6),(7)}`;provd **自己只讀** key 0(版本)、1(id)、2(type)、6(分塊)、7(冪等鍵,階段 1 不實作快取 → 帶 7 的請求回 `E_UNSUPPORTED(capability="idem")`,待 P3;**帶秘密的請求帶 7 → `E_FORBIDDEN`** 照協定),並把**整個原始信封 bytes** 放進 helper 請求 `args` 的 key 1(bstr)+ key 2 = `h`;helper 已有 `decodeEnvelope(raw)`(`node.go:636`)嚴格解碼。provd 不解 `body`。
- type → helper verb 對應表(provd 的唯一「協定知識」):

| 信封 type | 角色允許 | helper verb | 備註 |
|---|---|---|---|
| `info` | 全部 | `info.cert`(device_id)、`info.state`、`info.net`(**只有擁有者 / 成員角色才呼叫並附上 key 9/10**) | provd 組 `info-resp`:`device_id`、`model`(`/etc/batman-build` `BATMAN_MODEL`,缺 → `"dev"`)、`board`、`fw_version`、`proto_ver=[1,0]`、`capabilities=["halow"]`、`state`、`claim_window`(= state ∈ {0,3})、9/10 僅 owner / member;**新增 key 11 `unfinished: bool`**(wireless-txn P2 契約;`info.net` 回應的新 key 4 由 helper 加 = `TxnPresent`)。匿名 session 問 `info` → 沒有 9/10/11(負對照) |
| `claim/begin` | 匿名、擁有者重取 | `nonce(h)` | provd 記下本 session 的 `owner_pub`(重取角色:helper `claim.replay` 自己比對已存的那把,provd 不比) |
| `claim/finish` | 匿名 | `claim.verify(h, 原始信封)` | **認領互斥**:provd 全域 `claimInProgress`;另一條 session 同時送 → `E_BUSY`;成功(code 0 或 23)→ 本 session 升為擁有者、**Disconnect 其他所有 session**、`psks` 快取失效;失敗 → 本連線失敗計數 +1 |
| `op/nonce` | 擁有者、擁有者重取 | `nonce(h)` | helper 回 `nonce_helper` |
| `claim/replay` | 擁有者重取 | `claim.replay(h, 原始信封)` | 成功 → 升為擁有者、Disconnect 其他 session |
| `auth/owner` | 擁有者候選 | **provd 自己驗**:`ES256_owner("batman-owner-auth-v1" ‖ h ‖ owner_key_id)` 對 helper `info.owners`… | **helper 沒有回傳擁有者公鑰的動詞** → 新增 `info.owners()` 回 `{1: [owner_pub…]}`(公鑰非秘密;claimed / member 才有)。provd 用 `proto.VerifyES256`(已在 module)。通過 → 擁有者;回 `adv_owner_key`? 協定說回「目前的 `adv_owner_key`」→ 那是秘密,**不經 provd 讀**:階段 1 回空 map(B16 在 #255;app addendum) |
| `network/join` | 擁有者 | `net.apply(原始信封)` | 等 ≤ 330 s;helper 的 `EApply 21` / `EState 22` → 協定沒有對應碼 → 回 `E_REJECTED`(11)+ `reason` 文字 = helper 的 reason;`EBusy` → `E_BUSY`;`EPersist`/`EStorage` → `E_STORAGE` |
| `network/update` | 擁有者、成員 | `net.update`?——**helper 沒有獨立 verb**:`node.go:1060 netUpdate` 由 `net.apply` 內部依 body 分流 → provd 對 `network/update` 也送 `net.apply`(helper 以信封 type 判斷) | ⚠️ 要在實作時對 `node.go:716 ownerOpVerb` 確認 type→分流;審查請查 |
| `network/leave` | 擁有者 | `network.leave(原始信封)` | 同 join 的碼對應 |
| `ssh_keys/set` | 擁有者 | `ssh_keys.set` | |
| `root_password/reset` | 擁有者 | `root_password.reset` | 回應不快取 |
| `owner/add`、`owner/remove`、`settings/get|set`、`status`、`peers/challenge`、`diag/*`、`update/*`、`bulk/*` | — | — | **P3**:provd 回 `E_UNSUPPORTED(capability=<type>)`;`reset` → `E_UNSUPPORTED(reset, reason 9)` |

- 錯誤碼對應(helper → 協定):`20 ESchema → E_UNKNOWN_TYPE`(2)若 type 不在表內,否則 `E_FORBIDDEN`(3)… **精確表**:helper `3`(EForbidden)→ 3;`6` → 6;`7` → 7;`10` → 10;`12` → 12;`13` → 13;`20` → 2;`21/22` → 11(`E_REJECTED`,reason 文字);`9`(EClaimFailed)→ 9;其他 → 11。provd 自己產生:`E_VERSION`(1,major ≠ 1)、`E_UNKNOWN_TYPE`、`E_FORBIDDEN`(角色)、`E_BUSY`(認領互斥、helper 逾時、佇列丟棄)、`E_UNSUPPORTED`(P3 類型、idem)。
- 回應信封 `{1: id, 4: status, 3: body | 5: error}`,`id` 重複 / 倒退 → Disconnect(協定 §5.1)。分塊(§5.1):請求分塊 provd 重組(同 id、`(id,n)` 重複拒、總量 ≤ 1 MB → **階段 1 BLE `max_msg` 8192 → 單則 ≤ 8176 明文,分塊上限 8 塊即 64 KiB**,超過 → Disconnect);回應分塊只在 helper 回應 > 8176 B 時(診斷包 P3;階段 1 不會發生 → 單元測試仍涵蓋)。

### 4.4 廣播(取代 h23 §4.9)

- 一個 `LEAdvertisement1`:`Type=peripheral`、`ServiceUUIDs=[BATMAN_SVC_UUID]`、`Discoverable=false`、無 `LocalName`、無 `Includes`、無 `ServiceData` / `ManufacturerData` / `Data`、`Timeout=0`。BlueZ 產生 ADV = 18 B(128-bit UUID 列表),kernel 加 Flags 3 → 21 B。**provd 註冊前自己算 BlueZ 會產生的 ADV 長度(目前固定 18),加 3,> 31 → 不註冊、log `adv: payload would be <n> B (max 28)`、退出碼 3**(保護自己與 kernel;`ADV_LEN_TEST=<n>` 在 prov_test 下讓它假裝 payload 為 n B 走這條檢查 = 負對照)。
- **註冊時機(fail-closed)**:每次要註冊前 `health.get` → 行的 `boot_id` = 本次(provd 從 `/proc/sys/kernel/random/boot_id` 讀,jail 掛 `-r`)、`ts` 距 helper 上次 tick ≤ 60 s(provd 以 `info.boot_id` 無法知道 uptime → 改為 `health.get` 回應加 key 2 `age_s`)、`bluetoothd=1 hci0_powered=1 privacy=1 sc=1 sc_file=1 bondable=0` 全部成立,且 D-Bus `Adapter1.Pairable == false && Discoverable == false`;任一不成立 → 不註冊,每 5 s 重查(log 只在狀態改變時印一行)。
- **撤銷**:每 5 s `health.get`;任一欄轉壞 → ≤ 10 s 內 `UnregisterAdvertisement`(log `adv: withdrawn reason=health`);有連線建立(第一條 BLE 連線的 `AcquireWrite`/`AcquireNotify` 或 `Device1.Connected=true`)→ 撤銷(`reason=connect`);所有連線結束 → 重新註冊(新 RPA,`reason=disconnect`)。
- **RPA 輪替(F28)**:無連線時每 `900 + rand(30..120)` s 撤銷再註冊(`reason=rpa_timeout`)。
- log 契約(H3 `ble-rpa-254` 讀):`provd: adv registered reason=<start|disconnect|rpa_timeout|health|bluetoothd>`、`provd: adv withdrawn reason=<health|connect|stop|bluetoothd>`;**沒有 nonce 欄位**(與 h23 §6.3 的 `nonce=<8hex>` 不同 → 回報上層)。
- 連線上限由 kernel / BlueZ 控制不了「只收 2 條」:provd 以第 3 條立即 Disconnect 實作。

### 4.5 init / ujail(stage1 §4.7 細節)

```
START=92 STOP=10 USE_PROCD=1
procd_set_param command /usr/bin/batman-provd
procd_set_param respawn 3600 5 0
procd_set_param user provd ; procd_set_param group provd        # (備援;ujail 內也降權)
procd_add_jail batman-provd log                                   # -l /dev/log;無 ubus
procd_add_jail_mount /usr/bin/batman-provd /lib/ld-musl-aarch64.so.1 /etc/batman-build /etc/passwd /etc/group \
                     /proc/sys/kernel/random/boot_id /var/run/dbus/system_bus_socket
procd_add_jail_mount_rw /tmp/run/batman-prov                      # helper.sock(目錄 0750 gid 471;rw 因為 connect 要寫 socket)
[prov_test] procd_add_jail_mount_rw /tmp/run/batman-provd-test ;  讀 provd.env → procd_set_param env …
procd_set_param capabilities /etc/capabilities/batman-provd.json   # bounding set 空
procd_set_param no_new_privs 1
```
- jail 無 `/proc`(除 boot_id 一檔)、無 `/sys`、唯讀 `/`;Go 二進位靜態連結(`GO_PKG_LDFLAGS -s -w`,F-P3 證明不需額外 lib;`/lib/ld-musl` 列著以防 cgo 殘留 → 實作時 `file` 驗 static 並拿掉)。
- 退避(h23 L8):provd 啟動失敗(D-Bus 連不上 / adapter 不在 / helper 連不上 / 身分簽不到)**不退出**,內部重試 1, 2, 4, … ≤ 60 s,log `provd: backoff <n>s reason=<…>`;只有無法修復的錯(ADV 長度超限、jail 配置錯)才退出讓 procd respawn。
- 停止順序:provd K10 → bluetoothd K20 → helper K15?——stage1 §4.7:provd K10、helper K15、bluetoothd K20:provd 先停,撤廣播、Disconnect 所有連線(best effort,500 ms)。

### 4.6 `provd.env`(prov_test;h23 §4.8.3)

`SOCK_ONLY=1`(不碰 D-Bus;開 `gatt.sock`)、`FAST_FAKE_DELAY_MS=<n>`、`NO_BRUTE_LIMIT=1`、`GATT_ENCRYPT_CTRL=1`、**`ADV_LEN_TEST=<n>`**(新)。寫者 `prov-wbox-254.sh set-provd-env` → restart provd;provd 啟動時 log `provd: test env <k=v …>`(值不含秘密)。release build:`cmd/batman-provd/testenv_release.go` 讓這些名字不存在;gate `strings batman-provd | grep -c -e SOCK_ONLY -e provd-test` = 0。

### 4.7 dbus policy(firmware `batman-ble/files/bluetooth.conf`;stage1 §4.6 列的最終版)

```xml
<policy user="provd">
  <allow own="org.batman.provd"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.LEAdvertisingManager1" send_member="RegisterAdvertisement"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.LEAdvertisingManager1" send_member="UnregisterAdvertisement"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.GattManager1" send_member="RegisterApplication"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.GattManager1" send_member="UnregisterApplication"/>
  <allow send_destination="org.bluez" send_interface="org.freedesktop.DBus.ObjectManager" send_member="GetManagedObjects"/>
  <allow send_destination="org.bluez" send_interface="org.freedesktop.DBus.Properties" send_member="Get"/>
  <allow send_destination="org.bluez" send_interface="org.freedesktop.DBus.Properties" send_member="GetAll"/>
  <allow send_destination="org.bluez" send_interface="org.bluez.Device1" send_member="Disconnect"/>
  <allow send_destination="org.freedesktop.DBus"/>   <!-- Hello / RequestName / AddMatch;dbus-daemon 自己 -->
  <allow receive_sender="org.bluez"/>
</policy>
<!-- root policy 加:bluetoothd → provd 的回呼 -->
<allow send_destination="org.batman.provd" send_interface="org.bluez.LEAdvertisement1" send_member="Release"/>
<allow send_destination="org.batman.provd" send_interface="org.bluez.GattCharacteristic1"/>   <!-- ReadValue WriteValue AcquireWrite AcquireNotify StartNotify StopNotify -->
<allow send_destination="org.batman.provd" send_interface="org.bluez.GattDescriptor1"/>
<allow send_destination="org.batman.provd" send_interface="org.freedesktop.DBus.ObjectManager" send_member="GetManagedObjects"/>
<allow send_destination="org.batman.provd" send_interface="org.freedesktop.DBus.Properties"/>
```
- `Introspectable` 不放行(h23 F16);`AgentManager1.*`、`Properties.Set`、`Device1.{Pair,Connect,…}`、`Adapter1.*`(除 Get)全 deny(無 default policy)。`AddMatch`(`NameOwnerChanged`、`PropertiesChanged` of Device1.Connected)經 `org.freedesktop.DBus` → 放行該 destination。**⚠️ 審查請查 godbus 的 `RequestName` / `AddMatch` 是否都走 `org.freedesktop.DBus`(是,D-Bus 規格)**。

### 4.8 kernel board patch(待決 D3)

`patches/ekh-bcm2711/0015-bluetooth-eir-adv-flags-oob-254.patch`:backport 上游 CVE-2025-38303 與 CVE-2026-64539 的 `eir.c` / `hci_sync.c` 修法(放不下時丟 Flags / TX power,不丟使用者資料;不越界)。Witness = `eir.c` 內新增的長度檢查字串無法 `strings`;改以 **節點白箱測試**證明:root 以 `btmgmt add-adv` 註冊 31 B 資料 → 不 panic、廣播存在(或 mgmt 拒絕),`prov-sec-adv-len-254` 臂 2。bcm2710 同 patch(兩板共用 kernel 版本,只 build)。

## 5. 生命週期矩陣(provd 相關;其餘沿用 stage1 §5、h23 §5)

| # | 路徑 | 今天(wsl.16) | P2 後 | 測試(負對照) |
|---|---|---|---|---|
| L1 | first boot / 重燒卡 | bluetoothd 起、無廣播 | S10 99zz → S89 helper 產身分 → S92 provd:連 bus、等 `hci0` 物件、拉身分簽章、`health.get` 全 1 後註冊;新卡 helper 第一個 tick 在 S89+0 → provd 啟動時 health 可能還沒寫 → 5 s 重查 | `prov-firstboot-254`(provd 側:B trial `STATUS` 可讀、`updating=1`、末 4 碼) |
| L2 | boot(非 fresh) | 同上 | 同 L1;`adv_registered_once` 在本次開機第一次註冊後 =1 → autocommit 的 `ble-ok` 路徑從 WARN 變成真判定 | `prov-boot-254` |
| L3 | clean stop | — | K10 撤廣播、Disconnect;500 ms 後退出 | boot-reasons 乾淨 |
| L4 | reboot | — | 同 L2;所有 session / 計數歸零 | |
| L5 | OTA 到本 image(fresh overlay) | — | provd 無持久狀態;新槽 provd 起 → 註冊 | `prov-ota-254`(既有)+ STATUS 可讀 |
| L6 | autocommit | WARN ble(F-P16) | trial 上 helper `Committed()` 假 → 不寫 `ble-ok`;有舊 `ble-ok` 的節點:trial 上 provd 註冊 → `adv_registered_once=1` → health 真判定成立 → 不因 BLE 而 revert;provd 不起(bus 連不上)→ `adv_registered_once=0` → **UNHEALTHY → revert**(設計意圖:BLE 是唯一管理面) | §6.4 (8) 兩臂;`prov-provd-dos-254`(provd 被 kill ×10 → health 仍 1 → HELD) |
| L7 | 斷電 | — | provd 無狀態;helper 的交易由 helper 處理;手機看到連線斷 → 重連重讀 `info`(`unfinished`) | `prov-powerloss-*` 既有 |
| L8 | provd crash loop | — | procd `respawn 3600 5 0` + 內部退避 log;health 不看 provd 活著 | `prov-respawn-254` |
| L9 | bluetoothd 重啟 | — | `NameOwnerChanged(org.bluez)` → 清 D-Bus 狀態 → 等新 owner → 重新 Register(app + adv,≤ 15 s);連線全部已斷 | `prov-dep-restart-254` |
| L10 | dbus 重啟 | — | 連線 EOF → 退避重連 → 同 L9 | 同上 |
| L11 | helper 重啟 | — | helper.sock EOF → 重連 → 重拉 `node_cert`(`boot_id` 不變、簽章重做)→ `adv.registered` 再呼叫;進行中的請求以 `E_BUSY` 回手機 | 同上 |
| L12 | downgrade 到無 provd 的槽 | — | 舊槽無 provd 二進位、無 policy → 無廣播;health `adv_registered_once=0` → 舊 autocommit(wsl.16 含 `ble-ok` 判定)在 trial 上**會因 BLE 而 revert**?——wsl.16 的 autocommit 只在 `ble-ok` 存在時判;`ble-ok` 在 p6、由本 image 的 helper 寫 → 降級後舊 helper 也寫 `adv_registered_once=0` → 舊 autocommit WARN(P-U5 不擋)。**bad:** 若未來把 WARN 改成 FAIL,降級會被擋;記殘項 | `prov-downgrade-254`(既有)斷言 WARN 行 |
| L13 | bcm2710 | — | ❌ 未測(CM4 決策);policy / init 共用檔 | — |
| L14 | bcm2711 | — | 本文件 | 全部 |
| L21 | trial 上 app 操作 | — | STATUS `updating=1`;改狀態動詞 helper 回 `EBusy` → `E_BUSY` | `prov-trial-busy-254`(既有)+ STATUS |
| L24 | 兩支手機同時認領 | — | 一個 0、一個 `E_BUSY`;成功後另一條被 Disconnect | `prov-two-phones-254` |
| L34 | 認領回應遺失 | — | app `psk_replay` session → `claim/replay`;provd 不快取任何回應 | `prov-ble-claim-254` |
| L39 | 遠端讓 provd 反覆 crash(trial) | — | health 不看 provd 活著;`adv_registered_once` latch 在 helper → 第一次註冊後就不會變回 0 | `prov-provd-dos-254` |
| L62 | privacy / RPA | public 位址或 RPA 不換 | 註冊前 health 全 1 才廣播;重註冊換 RPA | `ble-rpa-254`(provd 模式) |
| L65 | bluetoothd crash | — | 同 L9 | |
| **L66** | 第 3 條連線 / 大訊息 / 交握洪水 | — | Disconnect;20/分 | `prov-sec-hog-254`、`-oversize-254` |
| **L67** | health 轉壞(root 開互動 bluetoothctl → bondable=1) | — | ≤ 10 s 撤廣播;既有連線**不**斷(已交握的 session 不受 bondable 影響;新連線進不來) | `prov-boot-254` 白箱 |
| **L68** | 操作員 root 手動 `advertise on`(第二寫者) | kernel panic 風險(F-P9) | 同今天 + kernel patch 後不 panic;provd 看到 `ActiveInstances ≠ 預期` log,不動作 | `prov-sec-adv-len-254` 臂 2 |
| **L69** | `psks.get` 回的 PSK 在交握中途被 helper 換掉(換密碼 / 認領) | — | 進行中的交握用舊值完成或失敗;下一條連線重拉;協定本來就要求 app 重連 | 單元 |
| **L70** | provd 啟動時 helper 還在 `BootFinish`(持 mutex 等 radio ≤ 120 s) | — | provd 的 `info.*` / `sign.*` 請求排隊到 Finish 結束(helper `Handle` 的 mutex);provd 啟動最多晚 120 s,期間無廣播(fail-closed) | `prov-boot-254` 記錄起始時間 |

## 6. 依賴與證據

| 依賴 | 證據 | 狀態 |
|---|---|---|
| BlueZ 5.72 D-Bus:`LEAdvertisingManager1.RegisterAdvertisement` 讀 `LEAdvertisement1` 屬性 `Type/ServiceUUIDs/Discoverable/Includes/LocalName/ServiceData/…`;service data 進 ADV、Local Name 進 scan rsp | `src/advertising.c:400-440,780-870,1226` | ✅ 原始碼 |
| BlueZ `GattCharacteristic1` `AcquireWrite` / `AcquireNotify` 回 `(fd, mtu)`;`Flags` 中 `encrypt-read` 等只在 server 端生效 | BlueZ `doc/org.bluez.GattCharacteristic.rst`;stage1 F43(`gatt-database.c:1760-1833`) | ⚠️ `Acquire*` 的 MTU 值與斷線時 fd 關閉行為未在 04 實證(無 provd);**實作第一步在 04 以 prov_test provd 驗,不另做探查** |
| kernel 在 LE-only 下對每個 instance 加 3 B Flags;mgmt 上限不扣它 | `eir.c:276-300`、`mgmt.c:8498-8520` | ✅ 原始碼 + F-P9 實證 |
| 控制器無 ext adv → legacy 31 B | F-P2 | ✅ |
| ujail `-U provd` 跑靜態 Go 二進位、`-c`、`-C` capabilities 檔格式 | F-P3;`ujail -h`;OpenWrt `procd/jail/capabilities.c`(JSON `{"bounding": [...]}`) | ✅ / ⚠️ capabilities 檔格式要在實作時以 `ujail -C` 空 bounding 實跑 |
| uid 471 能 connect 到 `system_bus_socket`(0777)並被 policy 拒絕 org.bluez(今天) | F-P4;h23 F16(04 ✅ `prov-sec-dbus-254`) | ✅ |
| helper socket 契約 | F-P6 | ✅ |
| `flynn/noise` 支援 `HandshakeNX` + psk 修飾(`PresharedKeyPlacement: 0`)、`ReadMessage` 失敗不洩漏狀態 | `noise/state.go`(v1.1.0:`Config.PresharedKey`、`PresharedKeyPlacement`) | ⚠️ 讀 vendored 原始碼確認後寫進實作 PR;向量交叉驗證(F-P12 的三組 noise 向量)是 Go 單元測試的一部分 |
| `godbus/dbus/v5` 匯出物件、`export.go` 的 `ExportMethodTable`、`prop.Properties`、unix fd passing(`AcquireWrite` 回 fd:godbus `UnixFD` 型別,連線需 `dbus.WithIncomingUnixFDs`?) | godbus README / `conn.go` | ⚠️ 同上;fd passing 是關鍵風險,實作第一週驗 |
| `/etc/batman-build` 可被 471 讀 | F-P3 | ✅(間接) |
| health 行格式 | `health.go:138` | ✅ |
| `node.go:716 ownerOpVerb` 以信封 type 分流 `network/update` | ⚠️ 未讀 | 審查 / 實作時讀 |
| iOS `scanForPeripherals(withServices:)` 以 UUID 列表比對 | Apple 文件(通識) | ⚠️ app 階段(U9)實證;本設計選 UUID 列表就是為它 |

## 7. 待決

| # | 題 | 建議 |
|---|---|---|
| D1 | Noise 函式庫 | **定案 P-U15** `flynn/noise` v1.1.0 |
| D2 | D-Bus 函式庫 | **定案 P-U16** `godbus/dbus/v5` v5.2.4 |
| D3 | kernel board patch backport CVE-2025-38303 + CVE-2026-64539 | **做**,放在 P2 的 firmware PR(與 provd 同 rc,負對照 = 無 patch 的 wsl.17 root 註冊 31 B → panic,**不再實跑**,以 F-P9 當負對照紀錄) |
| D4 | 服務 UUID | 核准時 `uuidgen`,寫進協定 §4.1 |
| D5 | ADV 內容 | **只有 UUID 列表**(§1.3);代價:app 要連線才知道 unclaimed / updating;B16 在 #255 |
| D6 | 兩個二進位 | 兩個(§1.3) |
| D7 | `info-resp` 新 key 11 `unfinished`、`info.net` key 4、`info.state` key 5 `trial`、helper 新動詞 `health.get` / `adv.registered` / `info.owners` | 進協定 v0.8 與 CDDL(同 PR 的 docs 部分) |
| D8 | `auth/owner` 回 `adv_owner_key` | 階段 1 回空(B16 #255);app addendum 註明 |

## 8. 安全

**資產**:同 stage1 §8。P2 新增的面 = provd 行程本身、D-Bus policy、廣播、GATT。

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| BLE 路人 | 追蹤 | ADV 只有 UUID 列表(= 「一台 Batman」)、無名字、無 service data;RPA 每次連線結束 / 900+ s 換;health 不對就不廣播 | `ble-rpa-254`、`ble-privacy-254` |
| BLE 路人 | 探「已認領?」 | `STATUS` 公開 state 本來就是設計(stage1 §4.8);PSK 錯 → 假第 2 則 + 等逾時;常數時間 6 把 | `prov-sec-psk-timing-254`(`FAST_FAKE_DELAY_MS` 負對照) |
| BLE 路人 | 佔連線 / 大訊息 / 交握洪水 / 暴力認領 | ≤ 2 連線;10 s;8 KiB;20/分;3 次斷 | `prov-sec-hog-254`、`-oversize-254`、`prov-sec-claim-brute-254`(`NO_BRUTE_LIMIT`) |
| BLE 路人 | 讓 provd crash → revert 好 image | health latch 在 helper;autocommit 不看 provd | `prov-provd-dos-254` |
| BLE 路人 | 透過 GATT 觸發 kernel 洞 | 路人只能讀 / 寫特徵,不能改廣播;kernel 洞需本機 CAP_NET_ADMIN 或 bluetoothd 代理(policy 限 provd) | — |
| 路人 → 攻陷 provd(Noise / CBOR 解析漏洞) | 改網 / 換擁有者 / 讀秘密 | helper 驗所有授權(stage1 §4.1);provd 不碰 keystore;jail 無 caps、唯讀;**D-Bus policy 只放行廣播 / GATT / Disconnect / Get**;provd 能做的:看經過的明文(誠實界線)、停廣播、斷線、**註冊 31 B 廣播讓 kernel panic(F-P9)→ 只有 kernel patch 擋得住(D3);provd 自己的長度檢查只擋我們自己的錯** | `prov-sec-dbus-254`(471 呼叫 `RegisterAgent` / `Properties.Set` / `Device1.Pair` → AccessDenied;正向 `Properties.Get`、`Device1.Disconnect`);`prov-sec-adv-len-254` |
| 攻陷的 provd | 以 helper 動詞 DoS(`net.apply` 塞滿 mutex、`nonce` 洪水) | helper 既有:nonce ≤ 4 / h、簽章額度、otaBusy;`net.apply` 要 owner-op 簽章 → 沒有擁有者私鑰只能被 `EForbidden` 立刻打回;**沒有授權就能卡 mutex 的只有 `BootFinish` 類內部路徑** | Go 單元(helper 既有) |
| 本機非 root | 連 provd / 偽造手機 | release 無 `gatt.sock`;prov_test 的 socket 目錄 root 0700;provd 不聽任何網路 port | `prov-sock-254`(tier B:停 provd 才跑)、tmp-trust |
| 本機非 root | 搶先建 `/tmp/run/batman-provd-test` 植入 `provd.env` | init 只在 `prov_test` 讀,且驗 root 0700 / 非 symlink / 檔 0600 link 1;release 無此路徑 | init 單元(busybox ash) |
| bluetoothd(root,已是 root) | 對 provd 回呼送壞資料 | provd 把 bluetoothd 當不可信輸入解析(長度、型別) | 單元 fuzz(小) |
| 供應鏈 | `flynn/noise`、`godbus` | vendored、`go.sum` 釘;審查記 sha;版本:noise v1.1.0(2023)、godbus v5.2.4 | `go mod verify` 在 CI |
| 我們自己 | 兩寫者(root 手動廣播)、fail-open、log 洩密 | §3 單寫者 + runbook;health 任一欄缺 → 不廣播;log 不含 PSK / `h` / 明文 body(只印 type、code、長度);**ADV 長度自檢** | `logread | grep -c <psk hex>` = 0;`ADV_LEN_TEST` |

**失效模式**:provd 任何啟動前置不成立 → 不廣播(fail-closed);health 轉壞 → 撤廣播;helper 不可達 → STATUS 回 ATT 錯誤、已交握 session 的請求回 `E_BUSY`。唯一 fail-open:`info` 的 `model` 缺 → `"dev"`(非安全欄位)。

## 9. 測試

- **Go 單元(CI,`go test ./...` + root-gated)**:`provd/noise_test`:三組 Noise 向量逐位元組(F-P12)、`fake_msg2_rule`、6 把常數時間(測「全部跑完」:計數器);`provd/frame_test`:`gatt_framing`、`envelope`、`chunking`、`chunk_boundary`;`provd/status_test`:`status_public` 三例;`provd/route_test`:type → verb 表、角色拒絕表、錯誤碼對應、`id` 倒退、第 3 條連線、閒置逾時(假時鐘)、20/分;`provd/adv_test`:長度自檢(28 過、29 拒);每個測試有 mutant 註解(拿掉檢查就 FAIL)。
- **CI `peer-vs-provd`**(h23 §4.8.3,本設計定 runner 預置):`useradd -u 471 provd`;`mkdir -m 0700 /tmp/run/batman`、`/tmp/run/batman-prov`(helper 自己建)、`/etc/batman-prov/`、`/opt/batdata/state`;helper 以 root 跑 `realSys`,PATH 前置 stub:`batman-slot`(`is-trial` rc 1、其餘 rc 0)、`batman-config-save`(`--prov-get` rc 11 = 無 p5)、`halow-setkey`、`prov_apply_lock`、`uci`(回空);**無 p5 → helper verdict `unknown(no-p5)` → 改狀態動詞 `EState`** → CI 只跑交握 / `info` / `STATUS` / 限制 / `claim/begin`+`op/nonce`、`claim/finish` 預期 `E_REJECTED`;認領成功路徑在節點 tier B(`prov-ble-claim-254`)。provd 以 `sudo -u provd` + `SOCK_ONLY=1` + `/tmp/run/batman-provd-test` root 0700。負對照:`peer.py --selftest` 刪一個比對 → FAIL;`FAST_FAKE_DELAY_MS=20` 使 timing 單位 FAIL。
- **節點(H3 §6.3 全部)**:照 h23 §6.3;本設計修正:`ble-rpa-254` 的 log 行無 `nonce=`;`prov-boot-254` 加「helper 重啟後 ≤ 15 s `adv_registered_once` 回 1」;**新 `prov-sec-adv-len-254`**:臂 1(prov_test provd,`ADV_LEN_TEST=29`)→ provd log `payload would be 32 B` 且 `ActiveInstances=0`;臂 2(kernel patch 後,root `btmgmt add-adv` 31 B 資料)→ 無 panic、boot_id 不變、`advinfo` 顯示 instance 或 mgmt 拒絕;**臂 2 的負對照 = F-P9 的實跑紀錄(不再重現)**。
- **release gate**(`check-prov-test-gate.sh` 擴充):provd 二進位 `strings | grep -c -e SOCK_ONLY -e ADV_LEN_TEST -e provd-test` = 0;`-wbox` 變體 ≠ 0。
- **手動**:iPad GATT 回歸(`docs/validation/ble-ipad.md`,H3 乙部建立)。

## 10. 回報上層

1. stage1 §2 / §4.7 / §4.8:兩個二進位;ADV 只有 UUID 列表;provd 讀 health 經 `health.get`;`adv.registered`;init 內容。
2. h23 §4.9 作廢(F-P10)、§6.3 `ble-rpa-254` log 行無 nonce、`prov-sec-adv-len-254` 新單位、§4.8.3 加 `ADV_LEN_TEST`、CI runner 預置清單(§9)。
3. 219 v0.8:§4.1 UUID 定案、`info-resp` key 11、`status/public` 不變、§3.3「每次開機」→「每次 provd 啟動」、§8 加 sock 計入連線數、`auth/owner` 階段 1 回空、`network/update` 走 `net.apply`。
4. wireless-txn §19 P2 契約:`unfinished` 落在 `info` key 11 與 `info.net` key 4。
5. #254 checklist:kernel CVE patch(D3)、B16(#255)、`capabilities` 偵測、L12 降級 WARN→FAIL 風險、`Acquire*` MTU 實證、godbus fd passing 實證、iOS UUID 過濾實證。

## 11. 殘項(回 #254)

`capabilities` 固定 `["halow"]`;idem 快取(P3);HTTP 傳輸(協定 §4.2)不做;`owner/add|remove`、`settings/*`、`status`、`peers/challenge`、`diag/*` → P3;bcm2710;B16;`auth/owner` 的 `adv_owner_key`。

## 12. 工作順序

1. 本設計兩位審查 → 0 BLOCKER / 0 MAJOR;D4 `uuidgen`。
2. docs:219 v0.8 + CDDL + 向量(`info` key 11、`unfinished`)。
3. H3 harness(照 §4 契約)→ PR 先 merge(節點單位 KNOWN 到期)。
4. P2 實作:helper 兩動詞 + `info.state`/`info.net` 新 key(Go 單元 + mutant)→ provd(先 `SOCK_ONLY` 對 `peer.py`,再 D-Bus 在 04 的 prov_test build 上驗 `Acquire*`)→ firmware(policy、kernel patch、pin)→ rc wsl.N → 04 跑 §6.3 → 正式全套。
