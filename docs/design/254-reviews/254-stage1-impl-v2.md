# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v2**

狀態:v1 兩位 REJECT(A:3 BLOCKER / 8 MAJOR / 13 MINOR;B:3 BLOCKER / 11 MAJOR / 14 MINOR;報告 `review-v1-A.md`、`review-v1-B.md`)。v2 整份重寫;§13 列 v1 每條的收法。
上層設計:`219-field-provisioning.md`(v2.8)、`219-protocol.md`(v0.6)。本文件只定**實作層介面**;與上層衝突處在 §1.3 明列,以本文件為準。
基準:Batman `main` f2f2bf6(= 出貨 1.5.12-wsl.2),firmware `build-3aplus` 527303e8;節點 02(10.41.1.1,slot B)、04(10.41.1.3,slot A,OTS)皆 Pi 4B Rev 1.5。03(3A+)故障,階段 1 只做 Pi 4,3A+ 等新板。

## 0. 一句話

加 **BLE(自建 `kmod-batman-bt` + 精簡 BlueZ,只開 LE、不配對、dbus 預設拒絕)**、一支**非 root 的 `batman-provd`(Go,ujail)** 與一支 **root 的 `batman-provhelper`**;helper **自己驗證每個改變節點的請求的授權物件**(provd 被攻陷 ≠ 能改網、能重置);私鑰操作只經 helper 的 **keystore 介面**(階段 1 `file` 後端,之後 `se`);**p5 是擁有權的 SoT,overlay 只是快取**,p5 上是單檔 `prov.cbor` + 一次寫入的 `identity/prov/`,由 `batman-config-save` 原子換;**擁有權與 SSH 脫鉤**;既有 fleet 節點升級後是 `legacy` 狀態、什麼都不動。

## 1. 決策、範圍、事實

### 1.1 使用者決策(2026-10-18)

| # | 決策 | 後果 |
|---|---|---|
| U1 | 開發期 608B 留空;app 與節點同步開發;焊上 608B / 換 HAT 時 provd 與 app **不重工** | keystore 介面 + `file`/`se` 後端(§4.2);`node_cert` 形狀兩後端相同(§4.3) |
| U2 | 節點端 Go、手機 Flutter + Rust(flutter_rust_bridge)、GATT 走 BlueZ D-Bus | 協定兩份實作,以 `tests/vectors/219-protocol`(119 項)+ `verify.py` 當裁判(§10) |
| U3 | **選正確做法,不選快速做法**:擁有權與 SSH **脫鉤** | 認領不碰 `authorized_keys`、不改 dropbear;SSH 公鑰由 app 另裝(§6.2) |
| U4 | 階段 1 恢復出廠 = **全清**(含身分 → 新 QR) | `batman-config-save --wipe-all`(§4.5);明寫為無 608B 的限制 |
| U5 | 改名探針(02)授權,但執行被 harness 分類器擋 | §6.6 改名以「會換 IP + 重開」設計,**⚠️ 待使用者手動跑 `probe` 定案** |
| U6 | 3A+ 等新板 | L13 ❌ |

### 1.2 Reality check(全部唯讀;v1 R1–R17 之外新增 / 修正)

| # | 事實 | 證據 |
|---|---|---|
| R18 | **dropbear 無 ECDSA**:`.config:1584 # CONFIG_DROPBEAR_ECC is not set`、`ED25519=y`;04 `strings /usr/sbin/dropbear` 只有 `ssh-ed25519`/`sk-ssh-ed25519`/`rsa-sha2-256`/`ssh-rsa` | A-B2 / B-B1 |
| R19 | `batman-config-save:151,350` `seed_key_ok()`:`--seed/--save` 無 `authorized_keys` 可用行 → exit 1;`:356-362` `mark_mesh_expected()` 在 `--seed`/`--on-join` 寫 p6 `mesh-expected`;`:397` 每個寫入模式寫 `.seeded`;`:392-394` `--seed` 旋轉 lkg;`:188-218` `onjoin_fp()` 只算 PRESERVE + 4 個 identity 檔 + shadow;`:319-327` `same_identity()` 只比 `identity/`,`:390` `cp -a` 只加不刪 | 原始碼 |
| R20 | `batman-autocommit:388-397` `expected_in_mesh()`:p6 marker 或 p5 `.seeded` → NEED_MESH=1;`:421-425` `health_ok()` 只看 mesh11sd/openmanetd/wpad;`:460-466` 未入網 → deadline revert | 原始碼 |
| R21 | `96:89-92` p5 掛不起 → `exit 0` → uci-defaults **刪掉 96**(只有 bypass 的 exit 1 留著);`96:164-172` 有 `shadow-root` + `authorized_keys` 任一 `ssh-*`/`ecdsa-sha2-`/`sk-` 行 → LOCKED(`PasswordAuth=off`、`ttylogin=1`) | 原始碼 |
| R22 | 04:`lock-status=UNPROVISIONED`、**無 `authorized_keys`**、root 空密碼、p5 seeded、AP 真 key(ssid `BCM2711-6c89`);02:一行 lab `ssh-ed25519`、root 空密碼、AP 真 key。**兩台都是「legacy」**(seeded、無 prov) | 節點 |
| R23 | 04 `date` = **2025-07-15**(faketime 卡住);02 = 2026-10-16 → ❓ #174 選項 A 的 bug,另記 #174 | 節點(A) |
| R24 | BlueZ 5.72 `src/bluetooth.conf`(套件裝到 `/etc/dbus-1/system.d/`,`bluez/Makefile:142-143`):`<policy context="default"><allow send_destination="org.bluez"/>`;節點 dbus `system.conf` `<allow user="*"/>`、`/var/run/dbus/system_bus_socket` 0777;dbus policy 檔案字母序、後蓋前 | A-M1 / B-M4 |
| R25 | BlueZ 5.72 `src/main.c:60-140` 合法鍵**無 `Pairable`、`Discoverable`**;`adapter.c:9083-9092`:`AlwaysPairable=false`(預設)且**無 agent** → BONDABLE 清掉;`ControllerMode=le` → `MGMT_OP_SET_BREDR 0`(`adapter.c:10290-10300`);`feeds/.../bluetoothd.init` START=62、無 respawn、`/var/lib/bluetooth → /etc/bluetooth/keys`(0755) | A-M6 / B-m2,m3 |
| R26 | `other.mk:30-62` `kmod-bluetooth`:`BT_BREDR=y`、RFCOMM/BNEP/HIDP/btusb 一包、`BT_HCIUART_BCM=n`、FILES **無 `btbcm.ko`**(`drivers/bluetooth/Kconfig:211-218` `BT_HCIUART_BCM select BT_BCM` → tristate);AUTOLOAD `bluetooth rfcomm bnep hidp hci_uart btusb` | B-M5 / A-M6 |
| R27 | `btbcm.c:664-678` 韌體檔名順序:`brcm/BCM4345C0.raspberrypi,4-model-b.hcd` → `brcm/BCM4345C0.hcd`;linux-firmware-20241110 無;`RPi-Distro/bluez-firmware`(pios/trixie)`debian/firmware/broadcom/BCM4345C0.hcd` 63806 B sha 007611e,同目錄 `LICENSE.cypress` | B / 本人 |
| R28 | `miniuart-bt-overlay.dts`(rpi-6.6.y):關 `&bt`、開 `&minibt`(uart1 serdev,`krnbt` 預設開 → `hci_bcm` 自動 probe),**無 clock 設定**;02/04 `vcgencmd get_config core_freq_min` = **200**、`core_freq`=500;distroconfig `[all]` `uart_enable=1` 是上游 typo(合法鍵 `enable_uart`),`[all]` 另有 `enable_uart`?❓(B 探到 `enable_uart`=1 生效) | B-M9 / A-m9 |
| R29 | `batman-slot:640-648` OTA 只抄 kernel/dtb/overlays/start*/fixup* 到 boot 分割,**不抄 `distroconfig.txt`** → 改 `[pi4]` 要重燒 p1 | B-M9 |
| R30 | `rundir.sh:9-11`:run dir NEVER `/var/run`;節點 `/var -> tmp`,`/tmp/run` root 0755 | A-m1 / B-m4 |
| R31 | uci-defaults 排序:`-`(0x2D)< `_`(0x5F)→ `99-zz-*` 在 `99_morse_radio_defaults`(channel 42 / country US)**之前**跑 | B-m1 |
| R32 | `/rom` squashfs 實際 107.5 MB(`du` 419.6 MB 是展開值) | B-m14 |
| R33 | `/var/run/hostapd-phy1.conf` 0644、`/etc/config/wireless` 0644 → AP/mesh PSK 本機任何 uid 可讀(既有,#13) | A-m5 |
| R34 | `inittab ::askconsole` + `console=ttyAMA0` = GPS 口:`ttylogin=1` 後 login 開在 NMEA 流上(既有,#105) | A-m11 |
| R35 | 04 `mesh-expected` 內容 = `seeded --on-join`;`joinwatch:48` 寫的是 `mesh-joined` | A |
| R36 | `halow-setkey:55` 拒絕 placeholder 當 key(exit 2) | B-M2 |
| R37 | 協定:`node_cert` 需 `sn`(9 B)、`serialNumber = sn hex`、`CN = device_id`;ECDH 金鑰(`ecdh_pub` + `sig_ecdh`)**與 DAC 分開**;608B `CheckMac` 輸入 = `ClientChal(32)` + `ClientResp(32)` + `OtherData`;`boot_id`/`nonce_node` 節點自產;psk_owner 最多 4 把;冪等鍵 | `219-protocol.md` §3.3/§5.4/§6 |

### 1.3 與上層設計不同處(以本文件為準)

| 上層 | 本文件 | 理由 |
|---|---|---|
| 219 §6.1 步驟 5:認領寫 `authorized_keys`(擁有者公鑰) | **不寫**。認領只關密碼登入、設隨機 root 密碼、`lock-status=LOCKED`;SSH 公鑰由 `settings/ssh_keys` 另裝(ed25519) | U3 + R18 |
| 219 §6.3「p5 schema 升到 2」 | `schema_version` 維持 1;prov 狀態在 `prov.cbor`(自帶 `v`) | `96:131` schema>1 丟 overrides 改 lkg |
| 219 §7 恢復出廠保留出廠身分、§6.1 重置後要按鍵才開窗 | 階段 1 **全清**(新身分、新 QR);從未認領 = 窗口每次開機開 | U4;無 608B 做不到計數器 |
| 219 §6.9 autocommit 加 BLE 健康檢查放 S4 | **階段 1 就加**(bluetoothd、provd、hci0 Powered) | BLE 是唯一管理面(A-M5) |
| 協定 §10 共用 Rust 函式庫 | 節點 Go、app Rust,向量 + 對手實作當裁判 | U2 |
| v1 Q1 內建開發 CA | **自簽** `node.cert`(dev CN 前綴、效期 2020→2120)+ app 認領時 **TOFU pin**;release app 拒 dev 前綴 | 公開 repo 的 CA 私鑰 = 假信任根(A-M3);時鐘差 15 個月(R23) |

### 1.4 狀態機(節點)

```
legacy ──(app:claim,需 CheckMac)──▶ claimed ──(network/create|join)──▶ member ──(network/leave)──▶ claimed
  ▲                                     │                                   │
  │ (OTA 到階段 1 image、p5 seeded 無 prov)│                                   │
unclaimed ─(claim)─▶ claimed            └──────(factory reset = wipe-all)────┴──▶ unclaimed(新身分)
unknown:prov.cbor 壞 / p5 不可用 / bypass → 只開 status/public + factory reset(需 SD 標記或 serial),不產生身分、AP 關
```

- `legacy`:p5 `.seeded` 且無 `prov.cbor`。**hook/helper 不動 AP、dropbear、lock-status**;provd 廣播「可認領(legacy)」;認領後變 `claimed`,之後規則同新機。**02/04 升級後就是這個狀態**(L17/L18)。
- `unclaimed`:新卡,p5 無 `.seeded`。AP 關(placeholder)、LuCI 不開;認領窗口每次開機開。
- `claimed`:有擁有者、無網路。AP 關;SSH 依 §6.2。
- `member`:有網路;AP 由網路設定決定;autocommit 依成員數(§6.4)。

## 2. 元件

```
手機 app ──BLE GATT── bluetoothd(精簡 BlueZ 5.72,LE only,無 agent,dbus 預設 deny)──D-Bus── batman-provd(uid provd,ujail)
                                                                                              │ /tmp/run/batman-prov/helper.sock(SEQPACKET,SO_PEERCRED)
                                                                                              ▼
                                                                                      batman-provhelper(root,procd)
                                                                                        ├─ keystore:file(階段 1)| se(#255)
                                                                                        ├─ 授權驗證:owner / admins / CheckMac(§4.1)
                                                                                        ├─ 交易式 state.apply(§4.4)
                                                                                        ├─ 既有工具:halow-setkey(含新 --ap-off)/ batman-config-save(含新 --wipe-all)
                                                                                        └─ --apply-state(給 hook)、--probe(給 autocommit / halow-status)
p5 prov.cbor + identity/prov/  ←(唯一寫者 batman-config-save)←  /etc/batman-prov/(root 0700)
99zz-batman-prov-state(uci-defaults):fresh overlay 時呼叫 helper --apply-state
```

同一個 Go 二進位,argv[0] 決定模式;協定核心(Noise `flynn/noise`、CBOR `fxamacker/cbor` core-deterministic、COSE 自寫最小集合 ES256/HKDF/AES-GCM)只有一份。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| `hci0` 存在、BR/EDR off、Bondable off | kernel + bluetoothd(`main.conf`:`ControllerMode=le`、`AlwaysPairable=false`、無 agent) | provd 斷言 `Adapter1.Pairable==false` | R25 |
| `hci0 Powered` | **bluetoothd `AutoEnable=true` 唯一**;provd 不寫 | provd 讀 | A-1.2 |
| `/etc/bluetooth/main.conf`、`/etc/dbus-1/system.d/bluetooth.conf`(**替換上游**) | image | dbus-daemon、bluetoothd | §4.6 |
| `/etc/bluetooth/keys/`(IRK;`/var/lib/bluetooth` symlink) | bluetoothd | — | 自己的 init 建 0700;fresh overlay = 新 IRK(與摘要計數器同步換,219 §3.3) |
| BLE 廣播、GATT 服務 | provd(D-Bus 註冊) | — | |
| `/dev/ttyS0` | kernel `hci_uart`+`btbcm`(serdev) | — | 無 userland |
| `/tmp/run/batman-prov/`(root:provd 0750)、`helper.sock`(0660) | helper(`mkdirat`+`O_NOFOLLOW`、owner root、非 symlink;`/tmp/run` root 0755) | provd | R30 |
| `/etc/batman-prov/identity/`:`node.key`、`ecdh.key`、`node.cert`、`claim.secret`、`claimed.counter`、`backend`、`sn` | **helper 只在 restore marker = `absent` 且非 bypass 時產生一次**;之後唯讀;96 從 p5 還原 | — | §4.2 |
| `/etc/batman-prov/prov.cbor`(state、owner、net、members、版本、sha) | helper(tmp + rename + fsync,**只在 persist 成功後**;§4.4);96(fresh overlay 還原) | hook(經 helper)、`--probe` | 單檔 → 無撕裂 |
| `/etc/.batman-prov-restore`(root 0600:`restored|absent|p5-unavailable|too-new`) | **96**(每次它跑到時寫);helper 讀後**不刪**(不借 `.batman-p5-restored`,`99-halow-identity:7` 會刪) | helper | A-B3 |
| p5 `prov.cbor`、`identity/prov/*`、`.seeded`、`overrides.uci`、`lkg/` | `batman-config-save`(持鎖、驗 rw) | 96、`--check`、autocommit | `prov.cbor` 整檔換(stage + `mv` + `sync`);`identity/prov/` 只在首次 seed 寫;`--wipe-all` 唯一刪者 |
| `$ST/prov-state`(p6,root 0600;`<state> <members_n> <generation>`) | helper(每次 state 變更;開機由 `--apply-state`) | `batman-autocommit expected_in_mesh/health_ok`、`halow-status` | 取代 v1 `mesh-solo` |
| `$ST/mesh-expected` | **`batman-config-save`**(`:356-362`,v1 寫錯)→ 改為:**`$ST/prov-state` 存在時不寫** | autocommit | A-B1 |
| `$ST/factory-reset.inprogress` | helper(開始寫、完成刪;每次開機 helper 看到就續做) | — | A-M8 |
| live uci `wireless.*`(mesh/AP key、channel、mesh_id、country) | 執行期:**只經 `halow-setkey`**(含新 `--ap-off`);firstboot:96/99 鏈 | provd | R36 → §4.5 |
| `dropbear.PasswordAuth/RootPasswordAuth`、`system.ttylogin`、root shadow、`lock-status` | 認領:helper(與 `96:167-172` 同一組值);fresh overlay:96(從 p5 identity) | — | `legacy` 不碰 |
| `/etc/dropbear/authorized_keys` | **操作員 / `settings/ssh_keys`(helper,只追加/刪除 app 自己加的行,行尾標記 `batman-prov:<key_id>`)**;認領不碰 | 96、config-save | U3 |
| `hostname`、`ahwlan.ipaddr` | 改名:helper(先 `--save` 再 `uci set` + `system reload`);openmanetd 之後重保留 IP 並重開(⚠️ U5) | | §6.6 |
| 認領窗口、失敗計數、冪等鍵、session | provd 記憶體 | — | respawn 後消失(L8) |
| LED | 既有 | — | 不碰;殘項 |
| `boot_id`、`nonce_node` | helper 產生(開機一次 / 每次挑戰) | provd | R37 |

## 4. 契約

### 4.1 helper socket 與授權模型(B-B2)

- `SOCK_SEQPACKET`,一包一則 CBOR map;`SO_PEERCRED` uid == provd 否則關;單連線序列化;請求 ≤ 64 KiB;逾時 30 s。
- **每個會改變節點的動詞都帶 helper 自己能驗的授權物件;provd 只是搬運工。** 動詞表:

| 動詞 | 授權(helper 驗) | 效果 |
|---|---|---|
| `keystore.cert` / `keystore.ecdh_pub` / `keystore.counter` / `nonce` / `boot_id` | 無 | 唯讀 |
| `keystore.sign(purpose, msg)` | `purpose` ∈ 白名單(`batman-hs-v1`、`batman-peer-v1`、…) | 簽;**不簽裸值** |
| `keystore.ecdh(peer_pub)` | 無(只回共享秘密的 HKDF 輸出,標籤固定) | |
| `claim.verify(client_chal, client_resp, owner_pub, owner_enc_pub, sig_enc, h)` | **`CheckMac` 成功**才寫;同一請求原子完成:寫 owner → `IncClaimed()` → lock → `persist` | `legacy|unclaimed → claimed` |
| `net.apply(net_config COSE, net_secrets COSE)` | helper 用 `prov.cbor.admins` 驗 `net_config` 簽章鏈(版本 +1、不跳號);用 `ecdh.key` 解 `net_secrets`(**明文 SAE key 不經 provd**) | 呼叫 `halow-setkey` |
| `owner.auth(obj)`(用於 `reset`、`owner/*`、`settings/*`、`network/leave`、`ssh_keys`) | `ES256_owner("batman-owner-auth-v1" ‖ h ‖ nonce_helper ‖ verb ‖ args_hash)`,`nonce_helper` 由 helper 剛發、一次性、60 s | |
| `state.apply(verb, args, auth)` | 依上表 | 交易式(§4.4) |
| `factory_reset(auth)` | owner auth **或** SD 標記檔已被 helper 讀到;**冷卻 60 s、期間可取消** | §4.5 |
| `persist(promote_lkg?)` | 無(冪等) | `batman-config-save --save [--promote-lkg]` |
| `diag.bundle` | owner auth | helper 的 `batman_tmp` 檔,O_RDONLY fd,讀完刪 |
| `ssh_keys.set(list, auth)` | owner auth;每行 `^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$`,≤ 8 行 | 只動帶 `batman-prov:` 標記的行 |

- 不認得的動詞 / 多餘欄位 / 長度超限 → `E_SCHEMA`;授權失敗 → `E_FORBIDDEN`。**負測試**:以 provd uid 直接對 socket 送 `factory_reset` 無 auth → `E_FORBIDDEN`;`net.apply` 帶錯簽章 → `E_FORBIDDEN`。

### 4.2 keystore 介面與 `file` 後端(B-M6)

```go
type Keystore interface {
    SN() [9]byte; DeviceID() string            // 導出:sn = SHA-256(node_pub)[:9](file);608B = 晶片序號(se)
    Cert() []byte                               // node_cert DER,鏈 [leaf](file 自簽) / [leaf, mfr-CA](se)
    Sign(purpose string, msg []byte) ([]byte, error)      // DAC 私鑰,ES256,帶標籤
    ECDHPub() []byte; ECDH(peerPub []byte) ([]byte, error) // 與 DAC 分開的 P-256 key
    CheckMac(clientChal, clientResp [32]byte) error        // 常數時間;秘密不出 keystore
    ClaimedCounter() uint32; IncClaimed() error            // 單調、持久、恢復出廠(階段 1 全清 = 隨身分一起消失)
    Backend() string                                       // "file" | "se"
}
```

| `file` 後端檔 | 格式 | 權限 |
|---|---|---|
| `node.key` / `ecdh.key` | P-256 PKCS#8 DER | 0600 |
| `node.cert` | 自簽 X.509:`CN=dev:<device_id>`、`serialNumber=<sn hex>`、effective 2020-01-01 → 2120-01-01、EKU 自訂 OID(dev) | 0644 |
| `claim.secret` | 32 B | 0600 |
| `claimed.counter` | uint32 文字 | 0600 |
| `backend` | `file` | 0644 |

- 產生時機:**只有** restore marker = `absent` 且非 bypass 且 p5 無 `identity/prov/`;其他情況缺檔 → `unknown`、不產生(A-B3)。
- `se` 後端(#255):同介面;`backend` 檔 = `se`;開機 `backend=se` 而 608B 不回應 → helper 拒絕啟動(fail-secure)。**焊上 608B = 新身分、新 QR、重新認領**(明寫在 #255)。
- app 側:`node_cert` 鏈長 1 且 CN 前綴 `dev:` → TOFU pin(認領時綁 `claim.secret`),畫面標「開發機」;release build 拒絕。鏈長 2 → 製造商根驗證。**app 零改**:只是信任策略分支。
- 開發期 QR:`batman-provhelper qr`(root;印 `device_id` + `claim.secret`;`claimed` 之後拒絕)。

### 4.3 p5 版面與 `batman-config-save` 改動

```
p5/
  schema_version = 1            (不變)
  .seeded, overrides.uci, lkg/   (不變)
  identity/dropbear/*, shadow-root (不變;認領後由 helper 的 lock 寫入 shadow-root)
  identity/prov/{node.key,ecdh.key,node.cert,claim.secret,claimed.counter,backend,sn}   (一次寫入)
  prov.cbor                     ({v:1, generation:n, state, owner{pub,enc_pub,mark_key}, admins[], net{config COSE, secrets COSE}, members COSE, ssh_keys[], sha256})
```

`batman-config-save` 改動(兩板共用,PR-P1):
- `--seed/--save/--on-join`:把 `/etc/batman-prov/prov.cbor` stage 後 **整檔 `mv`**(刪除語意 = 新檔沒有的就沒有;B-B3);`identity/prov/` 只在 p5 尚無時複製。
- `onjoin_fp()`、`same_identity()`、`--check`:**納入 `prov.cbor` 的 sha 與 `identity/prov/` 的 sha**(A-M2)。
- `seed_key_ok()`:**`$ST/prov-state` 為 `claimed|member` 時放行**(BLE 是管理面);否則照舊(U3)。
- `mark_mesh_expected()`:`$ST/prov-state` 存在時不寫(A-B1)。
- `--seed` 不再旋轉 lkg(B-M10);lkg 只由 `--on-join`/`--promote-lkg`。
- 新 `--wipe-all`:刪 `prov.cbor`、`identity/prov/`、`identity/dropbear/*`、`shadow-root`、`overrides.uci`、`lkg/`、`.seeded`;**不 mkfs**;先寫 `$ST/factory-reset.inprogress`(由 helper)。
- 互斥:helper 改 `/etc/batman-prov/prov.cbor` 是單檔 rename,`--on-join` 任一時刻讀到的是舊或新完整檔(A-M2 撕裂解);`generation` 單調,config-save 複製後比對 generation 不變才 publish。

### 4.4 交易式 `state.apply`(B-M8)

1. helper 在 `/etc/batman-prov/.stage/` 組新 `prov.cbor`(generation+1)。
2. 套用副作用(`halow-setkey`、dropbear、lock-status)。失敗 → 回滾副作用、回 `E_APPLY`。
3. `batman-config-save --save`(把 **stage 的** prov.cbor 寫 p5;config-save 讀 `.stage/prov.cbor` 若存在)。**rc ≠ 0 → 回滾副作用、刪 stage、回 `E_PERSIST`(含 rc 6 鍵名)**;app 顯示「存不進卡」(219 §2.3)。
4. `rename(.stage/prov.cbor, prov.cbor)` + fsync;寫 `$ST/prov-state`。
5. 中途 helper 死 / 斷電:開機 helper 看到 `.stage/` → 比 p5 `prov.cbor` generation:p5 新 → 以 p5 重建 overlay;否則丟 stage、回滾副作用(副作用可由 prov.cbor 重算:`--apply-state` 是冪等的「依狀態重設 AP/dropbear/lock」)。
6. **p5 是 SoT**:非 fresh overlay 開機 helper 跑 `batman-config-save --check`;p5 `prov.cbor` generation > overlay → 以 p5 重建 overlay 後 `--apply-state`(A-B3 情境 2:trial 槽認領後 revert)。

### 4.5 `halow-setkey --ap-off`、恢復出廠、SD 標記檔

- `halow-setkey --ap-off`:設 AP key = placeholder + `disabled=1` + keyguard MARK + `--save`;`--ap <key>` 反向。hook 與 helper 都只走它(B-M2)。
- 恢復出廠(U4):helper 寫 `$ST/factory-reset.inprogress` → `batman-config-save --wipe-all` → `halow-setkey --ap-off --mesh-off`(placeholder)→ 清 `/etc/batman-prov` → `batman-slot invalidate-other`(試用期拒絕 → 回 `E_TRIAL`,不開始)→ 刪 marker → `reboot`。開機看到 marker → 續做(冪等)。結果 = `unclaimed`、新身分、新 QR、窗口開。
- SD 標記檔:`/boot/batman-factory-reset`(當前開機槽 FAT;Pi 3 另有 p7),helper 開機讀到 → 走上面流程;只有 root/實體能寫。

### 4.6 BLE 平台(A-M6 / B-M4,M5,m2,m3)

| 項 | 定案 |
|---|---|
| kernel | 自建 `kmod-batman-bt`:`CONFIG_BT=m`、`BT_BREDR=n`、`BT_LE=y`、`BT_HCIUART=m`、`BT_HCIUART_BCM=y`、`BT_BCM=m`、`BT_HCIUART_H4=n`;FILES = `bluetooth.ko`、`btbcm.ko`、`hci_uart.ko`;**無** rfcomm/bnep/hidp/btusb;AUTOLOAD `bluetooth btbcm hci_uart` |
| 韌體 | 新 package `brcm-bt-firmware-4345c0`:`/lib/firmware/brcm/BCM4345C0.hcd`(sha 釘死)+ `LICENSE.cypress`;`hci_bcm` 先找 `BCM4345C0.raspberrypi,4-model-b.hcd` 再退 `BCM4345C0.hcd`(R27),裝通用名 |
| BlueZ | `bluez-daemon-min`:bluetoothd + bluetoothctl;不裝 obexd/hciattach/hcitool/rfcomm/gatttool/sdptool;`--noplugin=*`(或只留 gap/gatt) |
| `main.conf` | 只用 5.72 合法鍵:`ControllerMode=le`、`Privacy=device`、`AlwaysPairable=false`、`JustWorksRepairing=never`、`AutoEnable=true`、`DiscoverableTimeout=0`;**不裝 agent**(真防線);provd 開機斷言 `Pairable==false`、`Discoverable==false` |
| dbus policy | **替換**上游 `bluetooth.conf`:default **deny**;`<policy user="root">` 與 `<policy user="provd">` allow own/send `org.bluez`;檔名仍 `bluetooth.conf`(不靠排序) |
| init | 自己的 `/etc/init.d/bluetoothd`:START=61、respawn 3600 5 5、`/etc/bluetooth/keys` 0700、沒 `hci0` 時 log 一次並退出(procd 退避) |
| distroconfig `[pi4]` | 加 `core_freq_min=500`(R28);`[all]` `uart_enable=1` 改 `enable_uart=1`;**02/04 要重燒 p1**(R29)→ release note + 矩陣 L19 |
| 3A+ | `[pi3]` `disable-bt` → `miniuart-bt` + `core_freq_min=250`?(待板) |

### 4.7 procd / ujail

| 服務 | START / STOP | 說明 |
|---|---|---|
| dbus | 60(既有) | |
| bluetoothd | 61 / K20 | |
| batman-provhelper | 89 / K15 | 讀 restore marker、`.stage/`、factory marker;建 socket dir;寫 `$ST/prov-state` |
| batman-provd | 92 / **K10(在 bluetoothd/dbus 之前停)** | ujail:uid/gid `provd`(新增 `/etc/passwd`)、`no-new-privs`、`capabilities/provd.json` 空、唯讀 `/`、只掛 `/tmp/run/batman-prov`、`/tmp/run/dbus/system_bus_socket`;respawn 3600 5 5 |

### 4.8 GATT / 廣播(對 app)

照 `219-protocol.md` §4.1;MTU 協商、分段、序號;單則 ≤ 8 KiB,上限經 `CTRL/info` 回報;未交握只 `status/public`(格式版本、能力位元、**`legacy|unclaimed` 時才帶 `device_id` 末碼**,`claimed|member` 不帶,A/B m6);同時連線 ≤ 2(provd 自己 `Device1.Disconnect`);未交握 10 s 逾時;失敗次數每連線 **3**(對齊協定)。

## 5. 生命週期矩陣

| # | 路徑 | 今天(1.5.12) | 階段 1 後 | 測試(負對照) |
|---|---|---|---|---|
| L1 | first boot,新卡 p5 raw/未 seed | 96 no seed;AP placeholder → keyguard 關;root 空密碼、PasswordAuth on | marker=`absent` → helper 產身分 → `unclaimed`;AP 關;dropbear 仍 image 預設(開發期 `batman-dev-open`);窗口開 | `prov-firstboot-254`:`status/public` 可讀、`hci0` up、AP 關、`identity/prov` 0600(負:marker=`p5-unavailable` 時不得產生) |
| L2 | boot(member) | — | 96 還原 → marker=`restored` → hook `--apply-state` → helper 讀 prov.cbor → provd 廣播成員摘要 | `prov-boot-254` ×3 重開:generation 不變、SSH 依 §6.2 |
| L3 | clean shutdown | — | 無待存狀態;provd K10 先停 | boot-reasons 乾淨 |
| L4 | reboot | 同 L2 | 同 L2 | 同 L2 |
| L5 | OTA stage 1/2 到含本功能的 image | 96 還原 identity + overrides | + `prov.cbor`/`identity/prov` 還原;`--check` 含 prov → stale 擋 OTA | `prov-ota-254`:claim+join → OTA → 新槽 member、generation 同、AP 同(負:1.5.12 的 `--check` 看不到 prov 差異) |
| L6 | autocommit commit/revert | `.seeded` → NEED_MESH=1 | `expected_in_mesh()` v2:`$ST/prov-state` 存在 → `unclaimed|claimed|legacy`→0;`member` 且 members>1 → 1;`member` 且 members==1 → 要求 `meshjoin_radio_up`(wlh0 mesh point 且 mesh_id == uci);無檔 → 今天規則。`health_ok()` 加 bluetoothd、provd、`hci0 Powered` | `prov-autocommit-254`:claimed 未入網 OTA → commit;單台建網 + `radio1.disabled=1` trial → revert(負:1.5.12 image claimed OTA → revert) |
| L7 | 斷電 / helper 死在 `state.apply` 中途 | — | §4.4 步驟 5;dropbear 已鎖、prov.cbor 未換 → 開機 `--apply-state` 依 prov.cbor 回滾鎖(root 密碼回 image?**不**:shadow 保留,PasswordAuth 依狀態) | `prov-powerloss-254`(fi:步驟 2 後 `reboot -f`;步驟 3 後再一次) |
| L8 | provd crash loop | — | respawn;交握/冪等鍵丟失(重送可能重做,app 用 generation 判) | `prov-respawn-254` |
| L9 | bluetoothd 重啟 / 無 hci0 | — | provd `NameOwnerChanged` 重註冊;無 hci0 → provd 退避、`halow-status` WARN `ble-down` | `prov-bluez-restart-254` |
| L10 | dbus 重啟 | — | 兩者 respawn | 同 L9 |
| L11 | helper 重啟 | — | provd 重連;期間 `busy` | `prov-helper-restart-254` |
| L12 | **downgrade** 到 1.5.12 | — | 舊 96:overrides(schema 1)+ dropbear identity + shadow → **LOCKED 若 authorized_keys 有行**(R21),否則留 UNPROVISIONED;AP 真 key → 開、placeholder → 關;**無 BLE**。誠實後果:`member` 節點降級後 = mesh 在、AP 依設定、SSH 只有 lab key 或關;`claimed` 未入網 = mesh placeholder → radio 關 → **只剩 Ethernet(Pi4)/ serial**。升回:`prov.cbor` 仍在 → 狀態回來 | `prov-downgrade-254`:member 降級 → mesh 仍在、`ssh -i lab` 可登入(02);升回 generation 同 |
| L13 | bcm2710 | — | ❌ 等新板 | — |
| L14 | bcm2711 | — | 本文件 | 全部 |
| L15 | `batman_bypass=1`(fresh 或非 fresh) | 96 不還原 | 96 寫 marker=`p5-unavailable`;helper **不產生身分**、state=`unknown`;非 fresh 時 `/etc/batman-prov` 還在 → 仍 `unknown`(bypass 下 persist 必拒);provd 只 `status/public` | `prov-bypass-254` 兩種 |
| L16 | 恢復出廠(app / SD 標記) | — | §4.5;斷電續做 | `prov-factory-reset-254`(destructive;含斷電點) |
| L17 | **legacy 升級**(02/04:seeded、AP 真 key、UNPROVISIONED、無 prov) | — | 96 marker=`absent`?**不**:p5 有 `.seeded` 無 prov → marker=`legacy`;helper 不產身分?→ **產生**(legacy 可認領需身分),但 hook/helper **不動 AP/dropbear/lock**;`--on-join` 照舊 | `prov-legacy-upgrade-254`:04 OTA → AP key 不變、UNPROVISIONED 不變、SSH 不變(負:v1 設計會把 AP 換 placeholder) |
| L18 | legacy 認領 | — | 同 claim;**不清** lab authorized_keys;AP 不動(已是真 key);mesh 不動 | `prov-legacy-claim-254`(02) |
| L19 | `distroconfig` 改動(core_freq_min)| — | 不隨 OTA;02/04 手動重燒 p1(使用者) | PR-F 驗收:閒置 10 min `vcgencmd measure_clock core` 取樣 + BLE 連線不斷 |
| L20 | 96 掛不起 p5(2026-09-13 曾發生) | 96 exit 0、被刪 | 96 **先寫 marker=`p5-unavailable` 再 exit**;helper `unknown`、不產身分、AP 關 | `prov-p5-mountfail-254`(fi:暫時把 p5 superblock 弄壞?→ 改用 `batman_bypass` 模擬 + 單元測試 96) |
| L21 | trial 槽上認領/建網,然後 revert | — | 回舊槽:overlay 舊、p5 新 → helper `--check` → p5 generation 新 → 重建 overlay(§4.4 步驟 6) | `prov-trial-revert-254` |
| L22 | `network/leave` / `owner.remove` 後 OTA | — | prov.cbor 整檔換 → p5 無舊網 → 新槽 `claimed` | `prov-leave-ota-254`(負:v1 `cp -a` 語意會回來) |
| L23 | 改名 | — | helper 先 `--save` → `uci set hostname` + `system reload`;**⚠️ 假設 openmanetd 重保留 IP 並重開一次**;app 顯示「機台會重新啟動」;hostname 白名單 `[A-Za-z0-9-]{1,32}`;SSID 不跟著改(firstboot 綁定,殘項) | `prov-rename-254`(⚠️ 先由使用者手動探針定案) |
| L24 | 兩支手機同時認領 | — | provd 序列化;第二個 `claim.verify` 回 `E_STATE`(已認領) | `prov-two-phones-254` |
| L25 | 認領 / `net.apply` 進行中 OTA | — | helper 持 `cfgsave.lock` 競爭:`--save` 排隊;`batman-slot` precheck `--check` 看到 stale → 擋 | 同 L5 |
| L26 | `network/update` 觸發 `halow-setkey` → `wifi reload` 離網 | — | BLE 不受影響(獨立晶片介面);provd 先回 ack 再套用;joinwatch 15 s 內 `--on-join` | `prov-netupdate-254` |
| L27 | joinwatch / openmanetd / dpp-handler 重啟 | — | joinwatch 重跑 `--on-join`(冪等);openmanetd 不碰 prov;dpp-handler 只 LED | 既有 |
| L28 | BLE 與 WiFi AP 同顆 CYW43455 同時運作 | — | 共存由韌體仲裁;量 AP 吞吐 + BLE 丟包 | `prov-coex-254`(PR-F) |
| L29 | 第二支手機 / 換手機 / 二手機 | — | S3 後半:`owner.replace`(QR + owner auth);psk_owner ≤ 4 | 殘項列入 S3 PR |
| L30 | prov.cbor 版本太新(降級到較舊的階段 1) | — | 96 marker=`too-new`;helper `unknown`;不產身分 | 單元測試 |

## 6. 流程(只寫實作層差異;流程本體見 219 §6)

### 6.1 認領
`claim/start` → helper `nonce` → app `claim/finish`(`client_resp`、owner pubs、`sig_enc`)→ helper `claim.verify`:CheckMac → 原子:owner 寫入 stage → `IncClaimed()` → lock(§6.2)→ `persist` → rename → `$ST/prov-state=claimed`。失敗任一步回滾。

### 6.2 鎖定(U3)
- 設:`dropbear.PasswordAuth=off`、`RootPasswordAuth=off`、`system.ttylogin=1`、root 密碼 = 隨機 24 字元(經安全通道交 app;寫 shadow)、`lock-status=LOCKED`。
- **不動 `authorized_keys`**。沒有行 = SSH 關(民用正常態;管理走 BLE);有 lab 行 = 留著。
- `/etc/batman-dev-open` 存在 → 不鎖(開發機)。
- app「安裝 SSH 公鑰」→ `ssh_keys.set`(§4.1)。
- `legacy` 認領同上。

### 6.3 建網 / 加入
`net.apply` 由 helper 驗 COSE;SAE key 只在 helper 解密後交 `halow-setkey`;成功條件照 219 §6.4;`--save --promote-lkg` 只在 `meshjoin_joined` 後。

### 6.4 autocommit
見 L6。`$ST/prov-state` 的 `members_n` 由 helper 維護。

### 6.5 診斷
`diag.bundle` 走 BLE(owner auth);`/www/cgi-bin/bundle` 階段 1 **改成只在 `legacy|unclaimed` 且 `batman-dev-open` 時可用**,其他狀態回 403(殘項:正式驗證)。

### 6.6 改名
L23。⚠️ 探針待做。

## 7. 依賴的行為與證據

| # | 依賴 | 證據 | 狀態 |
|---|---|---|---|
| D1 | `miniuart-bt` → `hci_bcm` serdev 自動 probe,韌體檔名順序 | R28、R27 | ✅ 原始碼;上機待 PR-F |
| D2 | `other.mk` kmod 不可直接用 | R26 | ✅ |
| D3 | `.hcd` 來源與授權 | R27 | ✅(授權檔要跟著進 package) |
| D4 | BlueZ 5.72 D-Bus LE adv/GATT 可由非 root 使用(policy 放行後) | BlueZ doc;**上機待 PR-F** | ⚠️ |
| D5 | uci-defaults 全在 S10、排序規則 | R31 | ✅ |
| D6 | 96 Lane A 順序、`.batman-p5-restored` 由 99 刪 | 96:74-115、99:7 | ✅ |
| D7 | config-save 鎖、stage+mv、`--check` | 202 §4 | ✅ |
| D8 | `batman-slot precheck` 擋 stale | 202 C | ✅ |
| D9 | `expected_in_mesh`、`health_ok`、`mark_mesh_expected` 現行邏輯 | R19/R20 | ✅ |
| D10 | ujail、capabilities | R11 | ✅ |
| D11 | Go 工具鏈、vendoring | #252 | ✅ |
| D12 | mini UART baud 依 core clock;`core_freq_min=200` 會掉 | R28 | ✅(反證已探到 → 加 `core_freq_min=500`) |
| D13 | `halow-setkey` 行為 | #298 | ✅ |
| D14 | `AlwaysPairable=false` + 無 agent → 不可 bond | R25 | ✅ 原始碼;上機 PR-F(nRF Connect Bond 必失敗) |
| D15 | 改名 → openmanetd 重保留 IP 並重開 | `99-halow-identity:22-25` 註解;#202 殘項 | ⚠️ **待使用者探針** |
| D16 | 04 faketime 卡 2025-07-15 的原因 | R23 | ❓ → #174 |
| D17 | Go:`fxamacker/cbor` core-deterministic、`flynn/noise` NXpsk0/IK 與向量一致 | 待 PR-P2 向量全過 | ⚠️ |

## 8. 安全

**資產**:節點控制(root、OTA 槽、重置)、mesh/AP 金鑰、節點身分、認領秘密、擁有者/網主金鑰、成員名單、診斷包、BLE 可用性(3A+ 唯一管理面)。

| Actor | 攻擊 | 擋法 | 負測試(先證明不加就會過) |
|---|---|---|---|
| 路人(BLE) | 讀身分/追蹤 | 未交握只 `status/public`;`claimed|member` 不帶 `device_id` 末碼;RPA | `prov-sec-anon-254` |
| 路人 | 暴力認領 | 256-bit;每連線 3 次即斷 | `prov-sec-claim-brute-254` |
| 路人 | 佔連線 / 大訊息 | ≤2 連線、10 s、8 KiB、1 則待重組 | `prov-sec-hog-254`、`-oversize-254` |
| 路人 | 簽章 oracle | helper 標籤白名單、節點 nonce | 單元 + 向量 |
| 路人 → 攻陷 provd | 經 helper 重置/改網/改 key | **helper 驗授權物件**(§4.1);provd 無任何 root 能力 | `prov-sec-helper-auth-254`:provd uid 送無 auth 的 `factory_reset`/`net.apply` → `E_FORBIDDEN` |
| 路人 | 配對/綁定 | 無 agent、`AlwaysPairable=false`、BR/EDR off(kernel 不編) | `prov-sec-bond-254`:nRF Connect Bond 失敗、`/etc/bluetooth/keys` 無 peer |
| 路人 | kernel BT 堆疊 | 只 LE、無 RFCOMM/BNEP/HIDP/btusb;BlueZ 進 #247 | SBOM |
| 本機非 root(gpsd/avahi nobody、ubus、network、容器) | 操作 `org.bluez`(關 Powered、偽廣播) | dbus policy default deny | `prov-sec-dbus-254`:`start-stop-daemon -c nobody dbus-send … Powered` → AccessDenied |
| 本機非 root | 冒用 app 對 helper | socket root:provd 0660 + PEERCRED | `prov-sec-helper-uid-254` |
| 本機非 root | 讀私鑰/秘密 | root 0600/0700;provd 讀不到 | `prov-sec-key-perms-254`(含 `/etc/bluetooth/keys`、`/tmp/run/batman-prov`、`$ST/prov-state`) |
| 本機非 root | 預建 socket 目錄 | `/tmp/run` root 0755;`O_NOFOLLOW`、owner 檢查 | tmp-trust 掃描 |
| 本機非 root | 讀 AP/mesh PSK | **既有缺口**(R33)→ #13 | — |
| 擁有 SD 卡 | 複製身分 / 改 prov.cbor 升自己為擁有者 | **擋不住**(階段 1 限制;608B/LUKS) | — |
| 任何人拿到舊 QR(恢復出廠後) | 搶先認領 | 階段 1 全清 = 舊 QR 無效(U4);新 QR 只印在機台 | `prov-factory-reset-254` 斷言舊 secret 無效 |
| 供應鏈 | `.hcd`、BlueZ CVE、公開 repo 裡的信任根 | sha 釘死;#247;**無內建 CA**(自簽 + TOFU) | SBOM |
| 我們自己 | 兩寫者、fail-open | §3 單寫者;`unknown` 一律關 AP、不產身分;marker 由 96 唯一寫 | 單元測試 96 四種 marker |

**既有缺口(不是本變更造成,明列)**:R33 PSK world-readable → #13;R34 LOCKED 後 login 在 GPS 口 → #105。

## 9. 測試(B-M11)

- **協定裁判**:Go 實作逐位元組過 119 項向量;新增 `-dev` 向量(自簽 cert、TOFU);與 `verify.py` 做**對手交握**(socket 承載,CI 跑)。02 當 central 只驗 GATT 框架/MTU/重組/斷線,不當協定裁判。
- 每個 `prov-sec-*` 的負對照 = 以 build flag 或 env 關掉該檢查,測試必須 FAIL(「關掉就過」)。
- tier A:firstboot(fresh slot 情境)、boot、sec-*、respawn、bluez-restart、helper-restart、bypass、legacy-upgrade、two-phones。tier B(DNODE):ota、autocommit、downgrade、trial-revert、leave-ota、legacy-claim、netupdate、rename(⚠️)。destructive:powerloss、factory-reset、p5-mountfail。PR-F:coex、core clock。
- 02–04 BLE 距離:PR-F 量 RSSI 並記在 D 表。

## 10. 實作切法

1. **PR-F(firmware,spike;設計核准以它的結果為條件)**:`kmod-batman-bt`、`brcm-bt-firmware-4345c0`、`bluez-daemon-min` + `main.conf` + 替換 `bluetooth.conf` + init、distroconfig `[pi4] core_freq_min=500` / `enable_uart` → 04 重燒 p1 + OTA → `hci0` up、`Pairable: no`、`btmgmt info` 無 BR/EDR、非 root dbus-send 被拒、nRF Connect 看到廣播且 Bond 失敗、閒置 10 min core clock、AP 吞吐不掉。
2. **PR-H1(harness)**:`prov-*` 骨架、02 central client、`verify.py` 對手模式。
3. **PR-P1**:`batman-config-save`(prov.cbor、fp、seed_key、mesh-expected、`--wipe-all`)、96(marker、prov 還原、驗檔)、`halow-setkey --ap-off`、`batman-autocommit` v2、`99zz-batman-prov-state`;helper + keystore `file`(socket 測試,無 BLE)。
4. **PR-P2**:provd、GATT、協定核心(向量 + 對手)、`status/public`、認領、鎖定、`ssh_keys`。
5. **PR-P3**:建網/加入/邀請/狀態/診斷/離開/恢復出廠/改名。
6. S4(更新)、S5(app)addendum。

## 11. 殘項(回 #254)

- 3A+ 全部;04 I2C 空(R16);SSID 與 hostname 脫鉤(L23);`/www/cgi-bin/bundle` 正式驗證;#110 能力偵測接軌;LED/燈號不做;`halow-status:118` 文字;`owner.replace`/換手機(L29)進 S3 PR;R33/R34 既有缺口;改名探針(U5)。

## 12. 待決

| # | 題 | 建議 |
|---|---|---|
| Q1 | `legacy` 節點的身分何時產生(升級後開機就產,或認領時才產) | **升級後開機就產**(認領前 `status/public` 要能給 `device_id` 末碼);marker=`legacy` 時允許產生一次 |
| Q2 | 開發期 dropbear 預設(`batman-dev-open`)是否進 wsl 頻道 image | 進 wsl、不進 rel |

## 13. v1 審查 → v2 對應

| v1 發現 | 收法 |
|---|---|
| A-B1 / B-M1 autocommit | §4.3 `mark_mesh_expected` 條件化、L6 `expected_in_mesh` v2(`$ST/prov-state`)、`health_ok` 加 BLE、負對照 |
| A-B2 / B-B1 dropbear 無 ECDSA | U3:擁有權與 SSH 脫鉤(§6.2);不改 dropbear;`seed_key_ok` 依 prov-state 放行;認領不清 lab key |
| A-B3 / B-M8 overlay vs p5 | p5 = SoT、96 restore marker 四態、helper 只在 `absent` 產身分、交易式 apply(§4.4)、L15/L20/L21 |
| B-B2 helper 無授權 | §4.1 授權模型、`E_FORBIDDEN` 負測試 |
| B-B3 / A-M2 prov/ 複製語意 | 單檔 `prov.cbor` 整檔換、fp/same_identity 納入、generation |
| B-M3 legacy 升級 | §1.4 `legacy` 狀態、L17/L18 |
| A-M1 / B-M4 dbus | §4.6 替換 policy、`prov-sec-dbus-254` |
| B-M5 / A-M6 kmod & BlueZ | §4.6 自建 kmod、min daemon、合法鍵、無 agent |
| B-M6 keystore | §4.2 介面補齊(ECDH、sn、CheckMac 簽名、counter、backend) |
| A-M3 開發 CA | 自簽 + TOFU |
| A-M4 降級後果 | L12 誠實改寫 |
| B-M7 / A-M8 恢復出廠 | U4 全清、`--wipe-all`、marker 續做 |
| B-M9 / A-m9 core clock | `core_freq_min=500`、L19、PR-F 驗收 |
| B-M10 `--seed` lkg | §4.3 |
| B-M11 測試 | §9 |
| A-M5 mesh-solo | 取消;`$ST/prov-state` + `meshjoin_radio_up` |
| A-M7 改名 | L23 ⚠️ |
| MINOR(路徑 /tmp/run、`99zz-`、STOP 順序、device_id 末碼、3 次、CTRL 上限、CBOR 庫、hcd 檔名、squashfs 尺寸、LED、halow-status 文字、冪等鍵、diag fd) | 各節已收 |
