# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov/`、`batman-provd` 程序模型 — **v1**

狀態:v1 草稿,待兩位獨立審查。
上層設計:`219-field-provisioning.md`(v2.5,已審)、`219-protocol.md`(v0.6,已審)。本文件**不重講**那兩份講過的流程與協定,只把階段 1 要落地的**實作層介面**寫清楚:誰擁有什麼、契約、生命週期、依賴證據、安全。
基準:Batman `main` f2f2bf6(= 出貨 1.5.12-wsl.2),firmware `build-3aplus` 527303e8;節點 02(10.41.1.1,slot B)、04(10.41.1.3,slot A,OTS)皆 Pi 4B Rev 1.5。03(3A+)硬體故障,**階段 1 先在 Pi 4 做,3A+ 項目等新板**(使用者 2026-10-18)。
使用者決策(2026-10-18,#254 留言 6247264901):開發期 608B **留空**;app 與節點端同步開發;**焊上 608B / 換新 HAT 時 provd 與 app 不重工**。

## 0. 一句話

在既有 image 上加 **BLE(BlueZ,只開 LE)**、一支**非 root 的 `batman-provd`(Go)** 與一支**root 的 `batman-provhelper`**;所有私鑰操作(簽章、ECDH、認領 HMAC)只經 helper 的 **keystore 介面**,階段 1 用 `file` 後端、之後換 `se`(608B)後端時 provd 與 app 零改;provd 的狀態放 p5 `prov/`,**`overrides.uci` 的 schema 維持 1**(新 image 的 p5 在舊 image 上仍可還原),狀態轉換由 helper 當場套用、OTA 後由新 hook 還原。

## 1. 範圍與基準事實

### 1.1 本文件涵蓋(S0–S3)

| 步 | 內容 |
|---|---|
| S1 平台 | kernel `BT_HCIUART_BCM`、BT 韌體 `.hcd` package、`bluez-daemon` + `main.conf`、procd 服務與開機順序 |
| S2 節點核心 | `batman-provhelper`(root)+ keystore 介面(`file` 後端)、p5 `prov/` 版面、`batman-provd`(非 root,ujail)、GATT 傳輸、協定核心(過 `tests/vectors/219-protocol`) |
| S3 流程 | 認領、建網、加入、邀請 QR、狀態、診斷包;`99-zz-batman-prov-state` hook;autocommit 依成員資格 |

**不在本文件**(各自補一份 addendum,過審後才做):S4 軟體更新(`batman-slot` 拆兩步、簽章 B18、暫時 AP zone、BLE 健康檢查)、S5 app(Flutter + Rust 函式庫)、LoRa、608B `se` 後端(#255)。

### 1.2 Reality check(2026-10-18,全部唯讀,02/04 兩台一致除非註明)

| # | 事實 | 證據 |
|---|---|---|
| R1 | `[pi4]` 段已是 `dtoverlay=miniuart-bt`;`[pi3]` 段是 `disable-bt`;`8250.nr_uarts=1`;`/dev/ttyS0` 存在(root:dialout,無程序開啟) | `/boot/distroconfig.txt`、`/proc/cmdline`、`ls -la /dev/ttyS0` |
| R2 | `ttyAMA0` = gpsd(`/usr/sbin/gpsd -N -n … /dev/ttyAMA0`,uid nobody)**且** cmdline `console=ttyAMA0` | `ps w`、`/proc/cmdline` |
| R3 | kernel:`CONFIG_BT=m`、`BT_LE=y`、`BT_HCIUART=m`、`SERIAL_DEV_BUS=y`;**無 `BT_HCIUART_BCM`**;`/lib/modules/6.6.138/` 無任何 bluetooth/hci_uart/btbcm `.ko` | `zcat /proc/config.gz`、`ls /lib/modules/…` |
| R4 | 根因:OpenWrt `package/kernel/linux/modules/other.mk:30-57` `kmod-bluetooth` 的 KCONFIG 寫死 `CONFIG_BT_HCIUART_BCM=n`、`BT_HCIBTUSB_BCM=n`;`.config` 只 `CONFIG_PACKAGE_kmod-bluetooth=m`(未進 image) | firmware-2710 原始碼、`.config` |
| R5 | 節點 `/lib/firmware/brcm/` 無 `.hcd`;`cypress-firmware-43455-sdio` 只裝 WiFi `.bin`/`.clm_blob`(`package/firmware/cypress-firmware/Makefile:176-190`) | 節點 `ls`、Makefile |
| R6 | `feeds/packages/utils/bluez` = **5.72**;`bluez-daemon` DEPENDS `+bluez-libs +bluez-utils +bluez-utils-extra +glib2 +libncurses +libreadline +dbus +libical`;節點**已有 dbus 1.14.10**(avahi 用,S60 dbus / S61 avahi) | Makefile:67-72、`opkg list-installed`、`/etc/rc.d` |
| R7 | 節點無 python3;有 lua;image 已有 Go 二進位(#252 統一工具鏈);無 Rust | `which`、`/etc/batman-build`、`.config` |
| R8 | p5:`schema_version=1`;`.seeded`、`overrides.uci`、`lkg/overrides.uci`、`identity/dropbear/{ed25519,rsa}`;**04 的 p5 沒有 `identity/shadow-root`、沒有 authorized_keys**(`ls identity/` 只有 dropbear 目錄) | `mount -o ro,noload` 後 `find` |
| R9 | **`96:131`:`schema > SUPPORTED_SCHEMA` 時 `overrides.uci` 不套用,改用 `lkg/overrides.uci`** | 原始碼 |
| R10 | `batman-autocommit:388-396` `expected_in_mesh()` = `mesh-joined`/`mesh-expected` 標記 **或** p5 有 `.seeded` | 原始碼 |
| R11 | `/sbin/ujail` 存在;`/etc/capabilities/{ntpd,wpad}.json`;sysntpd 用 `procd_add_jail` + `capabilities` | 節點 |
| R12 | passwd:root/daemon/ftp/network/nobody/ntp/dnsmasq/docker/logd/ubus;無 provd 用的 uid | `/etc/passwd` |
| R13 | 防火牆 zone 只有 lan/wan;uhttpd 0.0.0.0:80/443;`/www/cgi-bin/bundle` 無驗證(串流 dmesg/logread/crash/status) | `uci show`、`/www/cgi-bin/bundle` |
| R14 | 上游 `dpp-handler`(S90,respawn)在跑,stop 時 `led reload`;`batman-faketime`(S12)已落地(#174 選項 A) | `/etc/init.d/*` |
| R15 | RAK4631 在 USB(兩台);`/usr/lib/batman/rundir.sh`(#280 root-only run dir)可沿用 | `/sys/bus/usb`、`ls /usr/lib/batman/` |
| R16 | ❓ 04 `i2cdetect -y 1` 整條空;02 有 0x2d/0x43。使用者說 04 也是 WM1302 HAT。階段 1 不用 I2C;**#255 前要查** | `i2cdetect` |
| R17 | `/rom` 419.6 MB;overlay 1.4G 用 83.6M | `du`、`df` |

### 1.3 現場觸發(逐 actor)— 階段 1 新增的部分

| # | 現場 | 今天 | 階段 1 後 |
|---|---|---|---|
| T1 | 開箱的人用手機找機台 | 看不到(無 BLE) | BLE 廣播,app 依 UUID 過濾 |
| T2 | 任何路人手機連上 GATT | — | 未交握:只能查 `status/public`;認領需 QR 秘密;已認領:先證明持有擁有者/網路金鑰 |
| T3 | 擁有者認領後重燒 SD 卡 / OTA | — | 身分在 p5 `prov/identity/`,96 還原;**重燒 SD 卡(p5 一起沒了)= 身分換新,QR 失效**(階段 1 接受,608B 才解) |
| T4 | 節點刷到**沒有本功能的舊 image**(downgrade / 另一槽是舊版) | — | p5 `overrides.uci` 仍 schema 1 → 舊 96 照常還原 mesh/AP;`prov/` 被忽略;AP/dropbear 由舊 hook 決定(見矩陣) |
| T5 | provd 被打掛 / crash loop | — | ujail 非 root,respawn 有上限;helper 不受影響;mesh 不受影響 |
| T6 | 本機非 root 程序(容器逃逸、OTS)想冒用 app | — | helper socket 只給 provd uid;keystore 秘密只在 helper(root 0600) |
| T7 | SD 卡被複製 | — | 身分可複製(軟體金鑰)— **階段 1 的正式限制,只限內部** |
| T8 | 斷電在認領寫入中途 | — | p5 寫入走 `batman-config-save`(stage + rename + sync);`prov/state` 單檔原子換 |
| T9 | 3A+(512 MB、BT 4.2、`[pi3] disable-bt`) | — | **等新板**;distroconfig `[pi3]` 改 `miniuart-bt` 需重燒 boot 分割(OTA payload 不含 p1) |

## 2. 元件

```
手機 app ──BLE GATT── bluetoothd(BlueZ 5.72, LE only, Privacy) ──D-Bus(system bus)── batman-provd(uid provd, ujail)
                                                                                          │ unix socket (CBOR 請求/回應, 固定動詞)
                                                                                          ▼
                                                                                  batman-provhelper(root, procd)
                                                                                    ├─ keystore 介面 ── file 後端(階段 1)/ se 後端(#255)
                                                                                    ├─ 呼叫既有工具:halow-setkey / batman-config-save / uci
                                                                                    └─ 狀態套用:AP、dropbear、lock-status、prov/state
p5 prov/  ←(只有 batman-config-save 寫)←  /etc/batman-prov/(root 0700, helper 寫)
99-zz-batman-prov-state(uci-defaults, fresh overlay 時由 /etc/batman-prov 重建 AP/dropbear)
```

- **provd 與 helper 同一個 Go 二進位**(`batman-provd` 與 `batman-provhelper` 為 argv[0] 兩種模式),協定核心只有一份;helper 的動詞集合固定、每個請求照 schema 驗。
- **keystore 介面**(helper 內部的 Go interface,F2 固定):`DeviceCert()`, `Sign(purpose, msg)`, `ECDH(peerPub)`, `CheckMac(nonce, mac)`, `ClaimedCounter()`, `IncClaimed()`。`file` 與 `se` 兩個實作;開機依能力選,**`se` 應在而不在 → 拒絕啟動(fail-secure),不退回 `file`**。provd 看不到後端,只看到 `node_cert` 與回呼結果。
- 用途標籤、CBOR key 表、COSE 物件、Noise 模式全部照 `219-protocol.md`;本文件不改協定。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| `hci0` 介面、adapter 屬性(Powered、Discoverable=off、Pairable=off) | bluetoothd(`main.conf` + provd 經 D-Bus 設 Powered) | provd(狀態) | `main.conf` 由 image 烤;不裝 agent |
| `/dev/ttyS0`(mini UART → CYW43455 BT) | kernel `hci_uart`/`hci_bcm`(serdev,DT 綁定) | — | 無 userland 使用者;`hciattach` 不用 |
| BLE 廣播內容(adv + scan response) | provd(`LEAdvertisingManager1.RegisterAdvertisement`) | — | bluetoothd 只傳送 |
| GATT 服務(Batman service UUID、req/resp 特徵值) | provd(`GattManager1.RegisterApplication`) | — | 同上 |
| D-Bus system bus policy `/usr/share/dbus-1/system.d/batman-provd.conf` | image | dbus-daemon | 只允許 uid provd 與 `org.bluez` 互談 |
| `/var/run/batman-prov/`(目錄 root:provd 0750)、`helper.sock`(0660) | helper 建立 | provd 連 | **不是** `$RUNDIR`(#280 root-only,provd 進不去);也不在 `/tmp` |
| `/etc/batman-prov/`(overlay,root 0700):`state.cbor`、`identity/node.key`、`identity/node.cert`、`identity/claim.secret`、`owner.pub`、`owner.mark`、`net/*.cose`、`members.cose` | **helper**(執行期)、**96**(fresh overlay 時由 p5 `prov/` 還原) | `99-zz-batman-prov-state`、`halow-status`、`batman-autocommit` | 兩個寫者按生命週期互斥:96 只在 uci-defaults 階段、helper 只在 S90 之後 |
| p5 `prov/`(= `/etc/batman-prov/` 的副本)+ p5 `prov/version` | **`batman-config-save`**(`--seed/--save/--on-join`,持 `cfgsave.lock`) | 96、`--check` | p5 的單一寫者不變(202 §3) |
| p5 `overrides.uci` / `schema_version`(**維持 1**) | `batman-config-save` | 96 等 | 不加新 uci 鍵;AP 開關仍以 placeholder key 表示(202 B2) |
| live uci `wireless.*`(mesh key、AP key、channel、mesh_id、country) | 執行期:**helper 經 `halow-setkey`**(與操作員、CLI 同一條路);firstboot:96/99 鏈 | provd(讀狀態) | provd 不直接 `uci set` |
| `dropbear` `PasswordAuth/RootPasswordAuth`、`system.ttylogin`、`/etc/dropbear/authorized_keys`、root shadow | 認領時:**helper**(照 96:165-172 的同一組值);fresh overlay:96(從 p5 identity)| — | #137 的鎖由兩個寫者在不同階段寫**同一組值**;helper 認領後呼叫 `batman-config-save --seed` 讓 p5 帶 `identity/shadow-root` + `authorized_keys` |
| `/opt/batdata/state/lock-status` | 96(fresh overlay)、helper(認領當下寫 `LOCKED`) | `halow-status` | 同上 |
| `$ST/mesh-expected`(autocommit 用) | 今天:joinwatch/meshjoin;階段 1:**helper 在 `network/join` 成功時也寫** | `batman-autocommit` | 解「已認領未入網」revert(219 §6.3);單台建網見 §5 L7 |
| 認領窗口狀態(記憶體) | provd | — | 從未認領:每次開機開;恢復出廠後:SD 標記檔或 helper CLI 開 N 分鐘 |
| 認領失敗計數 | provd(每連線、記憶體) | — | 不寫 p5(219 §6.1) |
| LED | 既有 meshled / dpp-handler | — | **階段 1 不碰 LED**(dpp-handler 會 `led reload`,搶著寫就是 #274 類 bug) |

## 4. 契約

### 4.1 helper socket(provd → helper)

- 傳輸:`SOCK_SEQPACKET`,每包一則 CBOR map;helper 用 `SO_PEERCRED` 驗 uid == provd,否則關閉。
- 動詞固定(階段 1):`keystore.cert`、`keystore.sign`、`keystore.ecdh`、`keystore.checkmac`、`keystore.counter`、`state.get`、`state.apply`(認領 / 加入 / 離開 / 恢復出廠 / 改名 / 國家)、`net.apply`(呼叫 `halow-setkey`,參數白名單:key、ap key、mesh_id、channel、country)、`persist`(`batman-config-save --save [--promote-lkg]`)、`diag.bundle`(產生診斷包到 helper 擁有的 tmp,回 fd)、`status`。
- 每個動詞有 schema(欄位、型別、長度上限);**不認得的動詞或多出的欄位 → 拒絕**。字元集:交給 `halow-setkey` 的值照 202 B 的規則前置檢查(`UNSAFE` 字元集與 96 `valid_batch` 相同)。
- 單一連線、序列化;請求 ≤ 64 KiB;helper 逾時 30 s 回錯。
- 缺檔 / 壞檔:`state.cbor` 解不開 → helper 回 `state=unknown`,provd 只開放 `status/public` 與「恢復出廠」(fail-closed)。

### 4.2 keystore `file` 後端

| 檔 | 格式 | 產生 | 權限 |
|---|---|---|---|
| `identity/node.key` | P-256 私鑰,PKCS#8 DER | helper 首次啟動且缺檔時 | root 0600 |
| `identity/node.cert` | X.509(`219-protocol.md` §3.3 的 `node_cert`),**由開發 CA 簽** | 同上(helper 內建開發 CA?見 §8 Q1) | root 0644 |
| `identity/claim.secret` | 32 bytes | 同上 | root 0600 |
| `identity/claimed.counter` | 無號整數文字 | 認領時 +1 | root 0600 |

- `CheckMac` 在 helper 內做常數時間比對;**秘密永不離開 helper**(對齊 608B 的 `NoMac=1`)。
- `Sign` 只簽**帶用途標籤**的結構(F2);helper 檢查標籤在白名單。
- 開發期 QR:`batman-provhelper qr` 印 `device_id` + 認領秘密(只在 LOCKED 之前、root 可執行)。**正式出廠流程在 §8 出廠,階段 1 不做。**

### 4.3 p5 `prov/`

- `prov/version` = `1`(獨立於 `schema_version`)。`prov/` 內容 = `/etc/batman-prov/` 逐檔複製(保留權限)。
- 96:**先還原 `prov/` 到 `/etc/batman-prov/`(Lane A,與 dropbear identity 同階段)**,再處理 `overrides.uci`。`prov/version` > 96 認得的 → 不還原 `prov/`、記 log、node 以「未認領」起來但**AP 不開**(fail-closed:寧可要重新認領,不要開著 AP)。
- `batman-config-save`:`--seed/--save/--on-join` 都把 `/etc/batman-prov/` 同步進 stage(PRESERVE 之外新增目錄複製);`--check` 把 `prov/` 的差異也算 stale。
- 為什麼 `schema_version` 不升 2:R9 — 舊 image 的 96 對 schema 2 會丟掉 `overrides.uci` 改用 `lkg`(可能是更舊的設定)→ downgrade 路徑變危險。與 #253 §6.3「schema 升到 2」**不同,以本文件為準**(證據 `96:131`)。

### 4.4 `99-zz-batman-prov-state`(uci-defaults,fresh overlay)

- 輸入:`/etc/batman-prov/state.cbor`(96 剛還原)。輸出:AP 開關(placeholder key = 關;真 key = 開)、dropbear/ttylogin(與 96 #137 段同一組值)、`lock-status`。
- 檔名排在 `99-halow-identity` 之後(SSID)、keyguard(S18)之前執行(uci-defaults 全在 S10)。
- 狀態 `unclaimed` / `unknown` → **AP 關(key = placeholder)**、LuCI 不開(uhttpd listen 只留 127.0.0.1?— 見 §8 Q2)。
- 執行期的同一套邏輯在 helper 內(`state.apply`),兩處共用一個 shell 片段或 helper 提供 `--apply-state` 子命令給 hook 呼叫(**選後者**,邏輯只有一份)。

### 4.5 BLE / GATT(對 app)

- 照 `219-protocol.md` §4.1;MTU 協商、分段、序號;單則訊息上限 8 KiB(階段 1;成員名單大時走 WiFi 備援 = S4)。
- 廣播:照 219 §3.3;`main.conf` `Privacy = device`(RPA)、`ControllerMode = le`、`Pairable = false`、`Discoverable = false`;不裝 agent;`JustWorksRepairing = never`。
- 未交握可讀的只有 `status/public`(格式版本、能力位元、`device_id` 末碼、認領窗口旗標)。

### 4.6 procd

| 服務 | START | 依賴 | 失敗行為 |
|---|---|---|---|
| `dbus` | 60(既有) | — | — |
| `bluetoothd` | 61(與 avahi 同級;bluez 套件自帶 init 要改成 `main.conf` 由我們烤、respawn) | dbus、`hci0` 出現 | 沒 `hci0`(韌體沒載)→ log 一次、不 respawn 風暴(procd respawn 參數 3600 5 5) |
| `batman-provhelper` | 89(dpp-handler 之前) | p5/overlay 已就緒(S10/S11) | 缺 keystore → 產生;壞 → 只回 `unknown` |
| `batman-provd` | 92(mesh11sd 之後、joinwatch 之前) | helper socket、`org.bluez` | ujail:uid provd、no-new-privs、caps 空、唯讀 `/`、只掛 `/var/run/batman-prov`、`/var/run/dbus/system_bus_socket`;respawn 3600 5 5 |

## 5. 生命週期矩陣

| 路徑 | 今天 | 階段 1 後 | 測試 |
|---|---|---|---|
| L1 first boot(新卡、p5 未 seed) | 96:no seed → image 預設;AP 開(placeholder → keyguard 關);root 空密碼、PasswordAuth on | 同;helper 產生 `file` 身分;provd 廣播「未認領」;**AP 由 keyguard 關(placeholder)**、dropbear 仍 image 預設(**階段 1 不改 image 預設密碼登入**,§8 Q2) | `prov-firstboot-254`:flash 04 → `status/public` 可讀、`hci0` up、AP 關 |
| L2 boot(已認領、已入網) | — | 96 還原 `prov/` → hook 套 AP/dropbear → helper 讀 state → provd 廣播成員摘要 | `prov-boot-254`:重開 3 次,摘要一致、SSH key-only |
| L3 clean shutdown | — | 無狀態要存(state 寫入時即 persist);bluetoothd 停 | `prov-shutdown-254`:`reboot` 後 `boot-reasons` 乾淨 |
| L4 reboot | 同 L2 | 同 L2 | 同 L2 |
| L5 OTA stage 1/2(同版或新版含本功能) | 96 還原 identity + overrides | + `prov/` 還原、hook 套狀態;**`--check` 含 `prov/`**,stale → OTA 被擋(202 C) | `prov-ota-254`:認領+入網 → OTA 另一槽 → 新槽 claimed/joined、SSH key-only、AP 狀態同 |
| L6 autocommit commit / revert | `expected_in_mesh` 看 `.seeded` | + 已認領未入網:helper 寫 `mesh-expected` 僅在 `network/join` 後;**單台建網**:helper 寫 `$ST/mesh-solo`,autocommit 視為 `NEED_MESH=0`(**改 autocommit,兩板共用**) | `prov-autocommit-254`:單台建網後 OTA 不 revert;負對照 = 不寫 `mesh-solo` 時 revert |
| L7 斷電(認領中途) | — | `/etc/batman-prov/state.cbor` 原子換(tmp + rename + fsync);p5 由 config-save 原子;狀態不一致時 helper 以 p5 還原的 overlay 為準;認領未完成 = 仍 unclaimed,QR 再掃一次 | `prov-powerloss-254`(fault-injection:在 `state.apply` 寫入前 `reboot -f`)|
| L8 provd 重啟 / crash loop | — | ujail respawn;重啟後重新 Register adv/GATT;交握狀態全丟(app 重連) | `prov-respawn-254`:`kill -9` provd 3 次 → 10 s 內廣播回來;第 6 次內 procd 停止 respawn → `halow-status` WARN |
| L9 bluetoothd 重啟 | — | provd 收 `NameOwnerChanged` → 重新註冊 | `prov-bluez-restart-254` |
| L10 dbus 重啟 | — | bluetoothd 與 provd 都掉 → procd respawn 兩者 | 同 L9(含 dbus) |
| L11 helper 重啟 | — | provd 重連 socket(退避);期間請求回 `busy` | `prov-helper-restart-254` |
| L12 **downgrade** 到沒有本功能的 image(另一槽舊版、或 rollback) | — | 舊 96 還原 `overrides.uci`(schema 1 不變)+ dropbear identity;**`prov/` 忽略**;AP 由舊 keyguard 規則(placeholder → 關;真 key → 開);dropbear 由 p5 `identity/shadow-root`+`authorized_keys` → 舊 96 也會 LOCKED;**升回**時 `prov/` 仍在 → 狀態回來 | `prov-downgrade-254`:1.5.12 ↔ rc 來回,兩邊 `--check` 不 stale、SSH 都 key-only |
| L13 bcm2710(3A+) | — | **未上板**(無機);`[pi3]` distroconfig 改 `miniuart-bt` + `core_freq` 固定要重燒 p1 | ❌ 等新板;PR 明寫 |
| L14 bcm2711 | — | 本文件 | 全部 |
| L15 `batman_bypass=1` 救援開機 | 96 不還原 | provd 起來看到 `unknown`(/etc/batman-prov 空)→ 只開 `status/public`;helper 拒絕 `persist`(config-save 已拒) | `prov-bypass-254` |
| L16 恢復出廠(app 或 SD 標記檔) | — | helper:先清 p5 `prov/` + identity(經 config-save 新動詞 `--wipe-prov`,§8 Q3)→ 清 overlay → 作廢另一槽(`batman-slot`,試用期拒絕)→ 重開 | `prov-factory-reset-254`(destructive tier) |

## 6. 依賴的行為與證據

| # | 依賴 | 證據 | 狀態 |
|---|---|---|---|
| D1 | Pi 4 CYW43455 BT 走 mini UART 要 `hci_uart` + `BT_HCIUART_BCM`(`hci_bcm` serdev driver),DT `miniuart-bt` 把 `&uart1` 給 BT | RPi 文件 `miniuart-bt` overlay;kernel `drivers/bluetooth/hci_bcm.c` serdev;**上機證據待 S1 第一次 build** | ⚠️ 待驗 |
| D2 | `kmod-bluetooth` 寫死 `BT_HCIUART_BCM=n` → 要 patch `other.mk` 或自建 kmod | `other.mk:30-57` | ✅ |
| D3 | BT 韌體 `BCM4345C0.hcd` 不在任何 OpenWrt package;來源 RPi `firmware-nonfree`(`/lib/firmware/brcm/BCM4345C0.hcd`),授權 = Cypress/Infineon 二進位可再散布授權(與 WiFi `.bin` 同) | 待抓 LICENCE 檔 | ⚠️ 待查(B12) |
| D4 | `bluez-daemon` 5.72 的 LE advertising / GATT D-Bus API(`LEAdvertisingManager1`、`GattManager1`)可由非 root 經 system bus 使用,只要 policy 放行 | BlueZ `doc/org.bluez.*.rst`;dbus policy | ⚠️ 待 S1 實測 |
| D5 | uci-defaults 全在 S10 `boot` 內、`wifi config` 之前後順序 | `batman-provision/Makefile` 註解(94 實測);`/etc/rc.d` 順序 | ✅ |
| D6 | 96 Lane A 在 overrides 前執行、`.batman-p5-restored` 給 99 | 96 原始碼 L74-115、99-halow-identity:7 | ✅ |
| D7 | `batman-config-save` stage+rename+sync、持鎖、`--check` 判 stale | 原始碼(202 §4) | ✅ |
| D8 | `batman-slot precheck-node` 每次寫 `p5-check.rc`,stale 擋 OTA(含 `-F`) | 202 C(已出貨 1.5.12) | ✅ |
| D9 | `expected_in_mesh()` 判定式 | `batman-autocommit:388-396` | ✅ |
| D10 | ujail 可用、capabilities json 格式 | R11 | ✅ |
| D11 | Go 工具鏈可建 arm64、vendoring 可重現 | #252 關單;image 內三個 Go 二進位 | ✅ |
| D12 | gpsd 獨佔 `ttyAMA0`,BT 用 `ttyS0` 不衝突;mini UART 需 core clock 固定(`miniuart-bt` overlay 自帶 `core_freq_min=500`?) | R1/R2;`vcgencmd measure_clock core` = 500 MHz | ⚠️ overlay 內容待讀 |
| D13 | `halow-setkey` 接受 `--channel`、立即 `--save`、字元集檢查、exit 3 | 1.5.12(#298) | ✅ |

## 7. 安全

**資產**:節點控制權(root、OTA 槽)、mesh/AP 金鑰、節點身分私鑰、認領秘密、擁有者公鑰、成員名單、診斷包(含 dmesg/logread)。

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| 路人(BLE 範圍內) | 連 GATT 讀身分/追蹤 | 未交握只給 `status/public`(無固定識別碼);RPA | `prov-sec-anon-254`:未交握要 `status/full` → 拒 |
| 路人 | 暴力認領 | 256-bit 秘密;每連線失敗 ≤ 5 即斷;無全機鎖 | `prov-sec-claim-brute-254` |
| 路人 | 佔住 BLE 連線(DoS) | 未交握 10 s 逾時、可被擠掉;同時連線 ≤ 2 | `prov-sec-hog-254` |
| 路人 | 塞大訊息吃記憶體 | 重組前上限 8 KiB、每連線 1 則待重組 | `prov-sec-oversize-254` |
| 路人 | 簽章 oracle | helper 只簽帶標籤結構、標籤白名單;挑戰混入節點 nonce | 單元測試 + 向量 |
| 本機非 root(容器、OTS、provd 被攻陷) | 用 helper 做 root 事 | socket 0660 root:provd、`SO_PEERCRED` 驗 uid;動詞固定、參數 schema;provd 攻陷 ≠ root(ujail、caps 空)| `prov-sec-helper-uid-254`:以 nobody 連 socket → 拒 |
| 本機非 root | 讀私鑰/認領秘密 | 只在 `/etc/batman-prov`(root 0700)與 p5(root);provd 本身讀不到 | `prov-sec-key-perms-254`:`find … -perm /o+r` 空 |
| 本機非 root | 預建 `/var/run/batman-prov` 或 socket 路徑 | helper 建目錄時 `O_NOFOLLOW`、檢查 owner root、非 symlink;目錄在 `/var/run`(root 0755)下、名稱固定但只有 root 能建 | `tmp-trust` 風格 |
| 擁有 SD 卡的人 | 複製身分 | **擋不住(階段 1 限制,內部)** | — |
| 擁有 SD 卡的人 | 改 p5 `prov/state` 把自己升為擁有者 | 擋不住(p5 明文,與今天 `overrides.uci` 相同信任等級);608B/LUKS 才解 | — |
| 供應鏈 | `.hcd`、BlueZ CVE | 韌體固定 sha、BlueZ 進 #247 更新清單 | SBOM gate(#45) |
| 我們自己 | 兩個寫者(96 vs helper、hook vs helper) | §3 按生命週期互斥;hook 呼叫 helper `--apply-state` 所以邏輯一份 | code review |
| 我們自己 | helper 把 `/tmp` 當可信 | 診斷包用 `batman_tmp`(#280);socket 不在 `/tmp` | tmp-trust 掃描 |

**攻擊面增量**:新輸入 = GATT req 特徵值(BLE 範圍任何人)、helper socket(uid provd)、`/etc/batman-prov/*`(root)、p5 `prov/`(root;物理)、`main.conf`/dbus policy(image)、kernel BT 堆疊(**新的 kernel 攻擊面,BLE 範圍任何人可送 HCI/L2CAP 封包**;只開 LE、不配對、關 BR/EDR 縮小)。

**秘密**:node.key / claim.secret 只在 root 0600 與 p5;不進 log(provd log 過濾);不進 URL;session key 只在記憶體。輪替:認領秘密不輪替(出廠固定);擁有者金鑰換手機時更換(219 §6.8,S3)。

**失敗模式**:state 壞/未知 → 只開 `status/public` + 恢復出廠;keystore 壞 → provd 不廣播;`se` 應在不在 → 不啟動。全部 fail-closed。

## 8. 待決(給使用者)/ 待查(reviewer 可幫忙攻)

| # | 題 | 建議 |
|---|---|---|
| Q1 | 開發 CA 放哪:helper 內建一把開發 CA 私鑰(每台自簽 node.cert)= 任何人能簽「正牌節點」,等於沒有製造商驗證;或在開發機上簽(需要工作台門) | **內建開發 CA,app 顯示「開發機」**;正式出廠(#255 608B)再換製造商 CA。階段 1 本就「只限內部」 |
| Q2 | image 預設 dropbear `PasswordAuth=off`(219 §6.2)是否在階段 1 就改?改了,**沒有乙太網 + 沒有 BLE app 的人就進不了未認領的節點**(只剩 serial) | 階段 1 **不改 image 預設**;等 app 能認領後(S3 驗收過)再改,放 S3 PR |
| Q3 | 恢復出廠要 `batman-config-save` 新動詞(`--wipe-prov` / `--wipe-all`)還是 helper 自己掛 p5 寫 | **新動詞**(p5 單一寫者不破) |
| Q4 | provd 語言:Go(使用者 2026-10-18 同意);協定庫在 Go 與 Rust(app)各一份,靠測試向量對齊 | 已定 |
| Q5 | `bluez-daemon` 拉進 glib2/libical/ncurses/readline(估 +2–3 MB);#217 瘦身要列例外 | 接受;S1 量實際大小寫進 PR |

## 9. 測試(進 daily-validation;harness PR 先進 main,#290)

- tier A(非破壞):`prov-firstboot-254`(只在 fresh slot 情境)、`prov-boot-254`、`prov-sec-*`、`prov-respawn-254`、`prov-bluez-restart-254`、`prov-helper-restart-254`、`prov-bypass-254`。
- tier B(DNODE):`prov-ota-254`、`prov-autocommit-254`、`prov-downgrade-254`。
- destructive:`prov-powerloss-254`(fault-injection case `prov`)、`prov-factory-reset-254`。
- **BLE 端到端黑箱需要一個「假手機」**:主機端用 Linux BlueZ(WSL 不行,沒 BT)→ 選項:(a) 02 當 central(02 也有 BT,bluetoothctl / Go `go-bluetooth` 當 client)對 04 的 peripheral;(b) 開發者手機 nRF Connect 手動。**選 (a) 進 harness,(b) 只在 PR 附照片**。負對照:每個 `prov-sec-*` 先證明不加該檢查時會過。

## 10. 實作切法(每個 PR 附兩板實測或「bcm2710 未上板」)

1. **PR-F(firmware)**:`other.mk` patch(`BT_HCIUART_BCM=y`)+ `bcm-bt-firmware` package(`.hcd` + LICENCE)+ `bluez-daemon` 進兩板 diffconfig + `main.conf` → 04 上 `hci0` up、`bluetoothctl advertise` 看得到(手機截圖 + 02 `bluetoothctl scan`)。
2. **PR-H1(harness)**:`prov-*` 套件骨架 + 02 當 central 的 client。
3. **PR-P1**:helper + keystore `file` + p5 `prov/` + 96/config-save 改動 + hook;無 BLE(用 socket 測)。
4. **PR-P2**:provd + GATT + 協定核心(向量)+ `status/public`、認領。
5. **PR-P3**:建網/加入/邀請/狀態/診斷 + autocommit。
6. S4/S5 另開 addendum。

## 11. 殘項(回 #254 本體)

- 3A+ 全部(R1 `[pi3]`、512 MB、BT 4.2 廣播預算 B16)。
- 04 I2C 空(R16)→ #255 前查。
- `/www/cgi-bin/bundle` 關閉或加驗證(219 §6.10)→ S3 診斷包走 BLE 後做。
- #110 能力偵測未實作 → 階段 1 provd 自己偵測 `halow/gps/lora/battery/se`,#110 落地後改接。
