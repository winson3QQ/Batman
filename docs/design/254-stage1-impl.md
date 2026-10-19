# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v14(自足版)**

**狀態**:v14。第 13 輪 A:**APPROVE-WITH-CHANGES**(0 BLOCKER / 0 MAJOR / 11 MINOR);B:REJECT(窄)0 BLOCKER / 1 MAJOR / 9 MINOR(`254-reviews/review-v13-{A,B}.md`)。兩位各自重做了 v13 的掃描,F21–F24 成立、shim 與 99zz 順序成立。B 的 MAJOR(A 列為 m8):**轉賣沒有處理接在節點上的 RAK4631(Meshtastic)**,它自己的 flash 留著前任隊伍的 LoRa 頻道 PSK 與隊友位置——我的掃描只看了 image 與 EEPROM,漏了周邊;v14 補上周邊盤點(F25)與賣方 / 買方步驟,並修兩位列的 MINOR。使用者決定 U8 不變。

**本文件完全自足**:不再引用前版的任何小節。v1–v13 全文與 25 份審查報告在 `254-reviews/`,只當歷史紀錄。§13 列 v13 審查發現的去向。

上層:`219-field-provisioning.md` v2.8、`219-protocol.md` v0.6;本文件要求的改動見 §1.3,成為 v0.7 / v2.9。
基準:Batman `main` f2f2bf6(= 出貨 1.5.12-wsl.2);firmware `build-3aplus` 527303e8 + `feat/254-ble` a5e181b7。節點:02(10.41.1.1,slot B,1.5.12-wsl.2,無乙太網 carrier、無 BLE build)、04(10.41.1.3,slot B,1.5.12-wsl.3 spike build,OTS,乙太網在這台,2026-10-19 起有 lab 公鑰)。03(3A+)故障,階段 1 只做 Pi 4。

## 0. 一句話

加 **BLE**(自建 `kmod-batman-bt` + 精簡 BlueZ,只開 LE、不配對、dbus root-only;04 spike 已驗)、一支**非 root 的 `batman-provd`**(Go,ujail)與一支 **root 的 `batman-provhelper`**。helper 自己重算 / 驗證每個改變節點的請求的授權物件(provd 被攻陷 ≠ 能改網、換擁有者、讀私鑰)。私鑰與 PSK 導出只經 helper 的 **keystore 介面**(階段 1 `file` 後端,之後 `se`)。**p5 是擁有權的 SoT**:p5 的 prov 檔(`prov.cbor`、最後寫的 commit 紀錄 `prov.meta`、一次寫入的 `identity/prov/`)只有 `batman-config-save --prov-only` 一個寫入路徑,其他模式不寫、不刪、不比對 prov。**狀態只由 `prov.cbor.state` 決定**。鎖定欄位:fresh overlay 由 96 寫(claimed/member 一律上鎖),執行期轉換由 helper 寫。既有 fleet(02/04)升級後是 `legacy`:OTA 的 mesh 閘與今天完全相同,AP/dropbear/lock 不動。`member` 的 OTA 閘看「arm 前本次開機是否曾入網」,綁 arm 那次開機的 boot_id。**轉賣 = 重燒卡**。

## 1. 決策、範圍、事實

### 1.1 使用者決策

| # | 決策 | 日期 | 後果 |
|---|---|---|---|
| U1 | 開發期 608B 留空;焊上 608B / 換 HAT 時 provd 與 app 不重工 | 10-18 | keystore `file`/`se` 兩後端,`node_cert` 形狀相同 |
| U2 | 節點 Go、手機 Flutter + Rust、GATT 走 BlueZ D-Bus | 10-18 | 向量 + `verify.py` 當裁判 |
| U3 | 擁有權與 SSH 脫鉤 | 10-18 | 認領不碰 `authorized_keys`;dropbear 照跑(只關密碼);上鎖後 key 登入仍可用(dropbear `svr-authpasswd.c:94` 的 locked 檢查只在密碼路徑) |
| U4 | 階段 1 轉賣 = 全清含身分 | 10-18 | 全清後機身 QR 失效;hostname/SSID 依 MAC 產生、跨擁有者不變(殘項) |
| **U8** | **要支援轉賣;階段 1 的全清 = 用 Batman 轉賣工具重燒 SD 卡(全卡清零後寫 image);app 不做恢復出廠** | **10-20** | §4.5;app 只顯示賣方 / 買方說明;現場要讀卡機 + 電腦;#255(608B)再設計 app 端重置 |
| U5 | 改名探針待使用者手動跑 | 10-18 | §6.6 ⚠️ |
| U6 | 3A+ 等新板 | 10-18 | 兩板共用檔(`batman-slot`、`platform-ab.sh`、config-save、96、halow-setkey、autocommit、joinwatch)bcm2710 ❌ 未測 |
| U7 | distroconfig 的 `uart_enable=1` typo 不動 | 10-18 | |
| Q6 | 04 改用 lab 公鑰登入 | 10-19 | 已做:04 `authorized_keys` = 02 同一把 ed25519(sha256 5bda8113…),key-only 登入驗過,lock-status 仍 UNPROVISIONED,已進 p5 |

### 1.2 仍被本設計引用的事實(全部唯讀實測或原始碼)

| # | 事實 | 證據 |
|---|---|---|
| F1 | dropbear 無 ECDSA,只有 ed25519 / rsa | `.config` `# CONFIG_DROPBEAR_ECC is not set`;04 `strings /usr/sbin/dropbear` |
| F2 | `batman-config-save`:`seed_key_ok()` 只在 `--seed` 用;`mark_mesh_expected()` 在 `--seed`/`--on-join` 寫 p6 `mesh-expected`;每個寫入模式最後寫 `.seeded`;`--save` 是 first-seed 路徑;rc 6 = 「a live value could not be persisted — the rest was written」;鎖接管:持有者 cmdline 不含 `batman-config-save` 就當 stale 接管;`--on-join` 對未 seed 的 p5 照寫 | 原始碼 `:21,115-122,151,287-288,356-362,389-408` |
| F3 | `batman-autocommit`:`expected_in_mesh()`(`:388-396`)p6 `mesh-joined`/`mesh-expected` → 1,否則 p5 `.seeded`,讀不到 → 1;`health_ok()`(`:421-456`);`autocommit-hold-once`(`:97-100`)消耗一次 = 不 revert | 原始碼 |
| F4 | `96`:早退點 `:64` bypass(exit 1 留著)、`:67` 無 p5、`:71` 非 ext4、`:89-91` mount 失敗、`:93` 未 seed(exit 0 → 被刪);4b(`:161-176`)`has_key && has_pw` → LOCKED,否則 UNPROVISIONED;dev-open → DEV-OPEN;p5 以 `ro,noload` 掛 | 原始碼 |
| F5 | `halow-setkey`:旗標 `--mesh/--ap/--mesh-id/--channel/--status`(`:25`);拒絕 placeholder(`:55`);reload 前無條件 `uci commit wireless`(`:99`);等 `mesh_netdev` ≤ 20 s(`:134`);成功後無條件 `batman-config-save --save`(`:147`) | 原始碼 |
| F6 | `joinwatch`:`$RUNDIR/joinwatch.state` 即時寫 JOINED/NOT_JOINED(`:130,149`);p6 `mesh-joined` 只寫一次;JOINED 時每 tick `--on-join`(`:145`) | 原始碼 |
| F7 | `meshjoin_reachable` = joined 且 br-ahwlan 有 IPv4 且 dropbear running(`meshjoin.sh:23-27`);`meshjoin_joined` = plink ESTAB ≥ 1 且 batman 鄰居 ≥ 1 | 原始碼 |
| F8 | sysupgrade:`sysupgrade:370` 在 `:403` 的 TEST exit 之前就呼叫 validate → `-T` 時父程序也是 sysupgrade;真的升級在 install 後由 procd 再 validate 一次,這時 sysupgrade 卡在 `ubus call system sysupgrade` 等它。04 `/opt/batdata/log/ota-trace.log` 第 1514–1515 行:先 `S1 CHECK … caller=/bin/sh /sbin/sysupgrade … upg=n`,約 14 s 後 `S1 CHECK … caller=/sbin/procd … upg=y`;`-F` 那次 procd validate rc=1 | firmware `package/base-files/files/sbin/sysupgrade:370,403`;04 ota-trace 原始行 |
| F9 | stage 2 ramfs:`RAMFS_COPY_BIN` 只有 `batman-slot batman-reboot vcmailbox hexdump tr sha256sum head tail cut cmp mktemp`(無 iw/batctl/ip);`/opt/batdata` 不在 | `platform-ab.sh:37,212-233` |
| F10 | payload `metadata version=` 是組包時的 `date +%Y%m%d-%H%M%S`,≠ rootfs `BATMAN_VERSION` | `build-ab-payload.sh:69`;04 實測 |
| F11 | `boot-reasons.log` 只有 batdata-mount 一個寫者,有 once-per-boot 閂;每次開機一行 `boot_id=<8hex>`;fresh trial 上 S10 就寫,早於 autocommit S99 | `95:632,708,753`;04 實測 |
| F12 | #202 的 OTA 閘:p5 是 ext4 而無 `.seeded` → `precheck-node` 與 stage 2 都 die | `batman-slot:534-547` |
| F13 | 99-batman-chanfix:fresh slot 背景從 p5 overrides 讀頻道,最多 6 次 `wifi reload`;morse 在 regdomain 未穩時回寫硬體預設頻道 | `99-batman-chanfix:4-9,22-57` |
| F14 | 02/04 **沒有** `tune2fs`、`timeout`、`stat`;**有** `blkid`(支援 `-p`)、`sgdisk`、`hexdump`、`mountpoint`、`flock`(flock(2))、`pgrep`、`fsync`、`mkfs.ext4`、`readlink -f`;image 預設 root shadow = `root:::0`、dropbear `PasswordAuth=on`、`RootPasswordAuth=on`;run dir `/tmp/run/batman` = root 0700 tmpfs | 02/04 實測 |
| F15 | 協定 §3.4:已認領節點對第 1 則以常數時間固定試 N 次 PSK;全部失敗 → 送格式正確的假第 2 則、等到逾時才斷;§8 全域交握每分鐘 20 次 | `219-protocol.md:77-82` |
| F16 | BLE spike(04):serdev `serial0-0`、無 ttyS0、BT 模組恰好 bluetooth/btbcm/hci_uart、`CONFIG_SERIAL_DEV_CTRL_TTYPORT=y`;policy plugin 必須留著(AutoEnable);bluetoothctl 會自己註冊 agent → 它在跑時 Pairable 變 yes;無 agent 時 Pairable no / Discoverable no;iPad 連線讀 GATT 不跳配對;dbus 非 root 被拒 | #254 留言 6251617876 |
| F17 | `/boot` 永遠掛 p1;slot B 時韌體讀 p3 的 `distroconfig.txt`;`batman-slot apply` 不抄它 → 改 `[pi4] core_freq_min=500` 要改 p1 與 p3 兩份;04 兩份都改了、40/40 取樣 500 MHz;02 沒改 | #254 留言 6255818833 |
| F18 | RSSI:iPad 與 04 室內 5–10 m −82 ~ −95 dBm | #254 留言 6255842632 |
| F19(更正) | **重燒卡不會清掉整張卡**:發行 A/B image 由 `scripts/build-ab-image.sh` 產生,總長 `4016 + P6_MB(200) + 2` = **4218 MiB**(`:121`),p5/p6 在建 image 時 mkfs(`:198-199`),p6 第一次開機才由 #201 長到滿卡。寫 image 只覆寫卡的前 4218 MiB;**舊 p6 尾端**(04:p6 起於磁區 8224768、到卡尾 62333952,已用 5.2 G / 25.4 G)不會被覆寫,長滿後成為新 ext4 的空閒區塊,**root 用原始讀取(`dd \| strings`)讀得回**;04 這段範圍有 OTS CA 私鑰、`opentakserver.key`、goatak `db.sqlite`。`flash-card.ps1`(桌面)不在 repo;它的 `Clear-Disk -RemoveData` 推論不會寫零(⚠️ 未實測)。repo 裡的 `scripts/flash-card.sh` 寫的是上游 OpenMANET 1.8.0 **單槽** image(舊 p5 整個留著)。v11 寫「舊資料不被任何程式讀到」、引 `build-gpt-ab-card.sh`(那是 bench 就地轉卡腳本)都是錯的 | 原始碼;A11/B11 在 04 唯讀實測;我本次讀 `build-ab-image.sh:121,198-199` |
| F20 | `/etc/uci-defaults/*` 在 S10 由 `etc/init.d/boot` 執行,exit 0 就刪 → 96 在每個槽 overlay 的第一次開機跑一次 | firmware `etc/init.d/boot` |
| **F21(完整掃描)** | image 內所有讀 Pi EEPROM persistent vars(`/sbin/persistent_vars_storage.sh` → `vcgencmd bootloader_config`)的程式,共 9 個讀者:`31_dropbear_persistent_storage`(`dropbear_authorized_keys` → 寫 `authorized_keys`、key-only)、`31_password`(`device_password` → root 密碼)、`95-morse-wireless-defaults` → `/morse/scripts/morse-wireless-defaults:19-24`(`default_wifi_key` → 新卡 2.4 GHz AP 的 PSK;`mm_region` → 國家)、`/lib/netifd/wireless/morse.sh:136,471-472`(`mm_sku` → 選 BCF;`mm_region`/`mm_region_unlocked` → 鎖區域,不符時拒絕設 country)、`/etc/diag_override.sh:18` 與 `/usr/share/rpcd/ucode/morse-mode:223`(`mm_mode`)、LuCI `header.htm:82`(`mm_virtual_wire`)、`luci-i18n-base-zz-lang-autodetect`(`mm_region` → 語言)、`/etc/boot-defaults/01-region-restriction`(`mm_region` → 刪其他區域韌體;**image 裡找不到執行它的程式** ⚠️)。寫者只有 `/morse/scripts/save_dropbear_setup.sh`(`WRITE` 在 bcm2711 未實作 → 失敗)。EEPROM 可由有實體接觸的人用 Raspberry Pi 的 recovery 卡改寫;**節點上的 root 也能改**:在 boot 分割放 `recovery.bin` + `pieeprom.upd` 讓 bootloader 下次開機自我更新,或以 vcmailbox 寫 OTP / 上 secure-boot 鎖(⚠️ 依 Raspberry Pi 文件,未實測)→ **都撐過重燒 SD 卡**。另:`95-batman-storage:418` 讀 `bootloader_config` 只為記錄 `BOOT_ORDER`/`PARTITION_WALK`,不是 persistent var 讀者 | 我本次在 WSL build 樹 `root-bcm27xx` `grep -rIl persistent_vars_storage` + 逐檔讀;recovery 卡寫入自訂 key ⚠️ 未實機驗證 |
| **F23** | **新卡的 AP 預設是開的**:94 呼叫 `meshpoint-1.8.0`,只把 **mesh** key 設成 `CHANGE-ME-NOW`(`meshpoint-1.8.0:28,60`),不碰 AP key;接著 95 的 `morse-wireless-defaults` 對還在預設狀態(ssid `OpenWrt`、encryption none)的 2.4 GHz AP 設 `psk2`、key = `default_wifi_key`(EEPROM 有就用,沒有就隨機 8 字元)並刪掉 `disabled`(`:140-158`)→ AP 開啟、key 不是 placeholder → `halow-keyguard` 不擋。發行 image 沒有內建 `/etc/config/wireless`(首次開機由 hotplug 產生) | 原始碼;⚠️ 沒有新燒的卡可實證 |
| **F24** | EEPROM 實際內容:04 = `BOOT_UART=0 WAKE_ON_GPIO=1 POWER_OFF_ON_HALT=0 NET_INSTALL_AT_POWER_ON=1`;02 = 前三項,無 `NET_INSTALL`;**兩台都沒有任何 persistent var**、沒有 `BOOT_ORDER` 自訂;bootloader 2026/09/23;04 沒有 HAT ID EEPROM(`/proc/device-tree/hat` 不存在)。→ 對 02/04,把 persistent var 讀取一律改成「空」**不改變現有行為**(讀者今天就讀到空) | 我本次 02/04 `vcgencmd bootloader_config` / `bootloader_version` |
| **F25(周邊)** | 接在節點上、自己有持久記憶體、重燒 SD 卡碰不到的周邊:**RAK4631(Meshtastic,USB `239a:8029`,02 與 04 都有;04 為 `/dev/ttyACM0`)**——它的 flash 存 LoRa 頻道設定與 PSK、節點資料庫、最後位置;**GPS 模組**(04 `/dev/ttyAMA0`,gpsd)——備份記憶體可能存最後位置與設定(⚠️ 型號未查);**HaLow MM6108**(spi0.0)——出廠 OTP(04 `board_type=0`),使用者無法寫入;04 沒有 RTC、沒有 HAT ID EEPROM、Pi 的 customer OTP 全為 0 | 我本次 04/02 `/sys/bus/usb/devices/*`、`/dev/tty*`、`uci show gpsd`、`/sys/class/ieee80211/*/device/board_type`;A13 讀 OTP |
| **F22** | 04 有 `firstboot`(= `jffs2reset`)、LuCI「reset」、`/etc/rc.button/reset`:都只清本槽 overlay;下一次開機 96 從 p5 把設定、身分、prov 還原 → **不是重置**;02/04 沒有 `blkdiscard`、`fstrim` | A11 在 04 唯讀實測 |

### 1.3 與上層設計不同處(→ 協定 v0.7 / 219 v2.9)

| 上層 | 本文件 | 理由 |
|---|---|---|
| 219 §6.1 步驟 5:認領寫 `authorized_keys` | 不寫;認領只關密碼登入、設隨機 root 密碼、`LOCKED`;SSH 公鑰由 `ssh_keys.set` 另裝(ed25519) | U3 + F1 |
| 219 §6.3 p5 schema 升到 2 | `schema_version` 維持 1;prov 在 `prov.cbor` + `prov.meta` | `96:131` schema > 1 丟 overrides 改用 lkg |
| 219 §7 恢復出廠(app、SD 標記檔、保留身分);協定的 `reset` 動詞、CDDL reset-level、`E_VERSION` 時只允許 `reset` 的逃生口、219 的任務表 / 版本協商 / daily-validation 列 | **階段 1 不做**;轉賣 = 轉賣工具重燒卡(§4.5)。provd 收到 `reset` 回 `E_UNSUPPORTED(reflash)`;`E_VERSION` 的逃生口改為 `info`/`status` + 「請重燒卡」提示;docs PR 逐處修(§10) | U8 |
| 219 §6.9 BLE 健康檢查放 S4 | 階段 1 就加,`ble-ok` gating(§6.4) | BLE 是唯一管理面 |
| 協定 §3.5 `batman-owner-auth-v1` | 保留給 session 升級;per-verb 授權用新標籤 `batman-owner-op-v1` | 一個標籤一種格式 |
| 協定 §7.1 第 1 版由建立者自簽,節點「記下」 | 節點記下第 1 版需要擁有者的 owner-op `network/join` | 首版信任起點 |
| 協定 §5.4 `ClientChal` | helper 自己重算(nonce、DAC、即將寫入的 owner_pub) | 擋「被攻陷的 provd 換擁有者」 |
| 協定 §3.3 `device_id` 未定公式 | `device_id = hex(sn)`,18 字元;adv 帶末 4 字元 | |
| **協定 §3.4 PSK 候選** | 加 `psk_replay = HKDF( ECDH(node_ecdh_priv, owner_enc_pub), "batman-psk-replay-v1" ‖ device_id )`(app 端用 `ECDH(owner_enc_priv, node_ecdh_pub)`);**固定試 6 次**;失敗行為照 §3.4;`psk_replay` session 只允許 `claim/replay` | 認領回應遺失時擁有者能取回金鑰;需要擁有者加密私鑰才連得上 → 只看過 QR 的人探測不到;608B ECDH 槽本來就支援(協定 §7.3) |
| 協定 §10 共用 Rust 函式庫 | 節點 Go、app Rust,向量 + 對手實作當裁判 | U2 |
| v1 內建開發 CA | 自簽 `node.cert`(`dev:` 前綴、2020→2120)+ app 認領時 TOFU pin;release app 拒 dev 前綴 | 公開 repo 的 CA 私鑰 = 假信任根 |

### 1.4 狀態機

```
legacy ──(claim + 防呆門 §6.1)──▶ claimed ──(network/join;owner-op)──▶ member ──(network/leave;owner-op)──▶ claimed
unclaimed ─(claim)─▶ claimed
重燒卡 ─▶ unclaimed(新身分)
```

| 狀態 / 判決 | 定義 | AP、dropbear、lock | autocommit NEED_MESH | 認領 |
|---|---|---|---|---|
| `legacy` | prov.state | 全不動(96 4b 今天規則) | 今天的規則 | 開(防呆門) |
| `unclaimed` | prov.state | AP:99zz 設 placeholder → keyguard 關(F23:image 預設的 AP 是開的,不能靠預設);dropbear image 預設 | 0 | 每次開機開 |
| `claimed` | prov.state | 上鎖;AP:`radio_managed=0` 不動 / `=1` 關 | live mesh key ≠ placeholder → 今天規則;否則 0 | 只 `claim/replay` |
| `member` | prov.state | 上鎖;AP 由網路設定 | §6.4 | 只 `claim/replay` |
| `unknown` | helper 判決(§4.2 rc 表) | p6 已掛且 `prov-state` 的 `last_known_state` ∈ {claimed, member} → 上鎖;否則不動 | 今天的規則(p5 讀不到 → 1) | 無 |

`prov.cbor.radio_managed`:unclaimed 認領 → 1;legacy 認領 → 0(保留操作員手設的 mesh/AP);`network/join` 後 1。

## 2. 元件

```
手機 app ──BLE GATT── bluetoothd(LE、無 agent、dbus root/provd-only)──D-Bus── batman-provd(uid provd,ujail)
                                                                                 │ /tmp/run/batman-prov/helper.sock(SEQPACKET,SO_PEERCRED)
                                                                                 ▼
                                                                         batman-provhelper(root,procd S89)
                                                                           ├─ keystore:file(階段 1)| se(#255)
                                                                           ├─ 授權:owner-op / admins 鏈 / CheckMac(helper 重算)
                                                                           ├─ 交易式 state.apply(§4.4)
                                                                           ├─ --boot:p5 ↔ overlay 對帳、身分產生 / 還原、完成未完的轉換、.txn
                                                                           └─ 每 15 s:$RUNDIR/batman-prov.health;ble-ok
platform_check_image(stage 1):只在真的升級時寫 p6 ota-armed.mesh(§6.4)
96(S10):prov 抄寫、claimed/member 上鎖
99zz-batman-prov-state(S10):fresh overlay 寫 prov-state(writer=99zz)
```

同一個 Go 二進位,argv[0] 決定模式;協定核心(Noise `flynn/noise`、CBOR `fxamacker/cbor` core-deterministic、COSE 最小集合)只有一份。

## 3. 擁有權

| 資源 | 唯一寫者(依時段) | 唯讀者 | 備註 |
|---|---|---|---|
| `hci0` 存在、BR/EDR off、Bondable off | kernel + bluetoothd(`main.conf`,無 agent) | provd 斷言 Pairable==false | F16 |
| `hci0 Powered` | bluetoothd `[Policy] AutoEnable`(policy plugin) | helper(D-Bus `Properties.Get`) | |
| `main.conf`、`dbus-1/system.d/bluetooth.conf`、`init.d/bluetoothd` | image(`batman-ble`) | | |
| `/etc/bluetooth/keys/`(IRK) | bluetoothd(init 建 0700) | | 重燒卡 = 新 IRK |
| BLE 廣播、GATT | provd(不註冊 agent) | | adv 無 Local Name;GAP Name 固定 `Batman` |
| `/tmp/run/batman-prov/`、`helper.sock`(0660) | helper(`O_NOFOLLOW`、owner 檢查) | provd | |
| `$RUNDIR/batman-prov.health`(0600) | helper 每 15 s | autocommit | `<uptime> bluetoothd= hci0_powered= adv_registered_once=` |
| `$RUNDIR/prov-txn`(`<pid> <token>`) | helper:交易步驟 1 建、步驟 4 後刪 | config-save `--on-join`(存在且 pid 活著 → rc 1);帶 `--txn <token>` 相符不讓路;操作員 `--save` 等 ≤ 10 s | |
| `/etc/batman-prov/.txn`(overlay,fsync;`<token> <gen_from> <gen_to> <verb>` + 變更前的 wireless 值) | helper:步驟 1 寫、步驟 4 後刪 | helper `--boot`;config-save `--on-join`(存在 → rc 1) | |
| `/etc/batman-prov/identity/`(7 檔)、`prov.cbor`、`prov.meta`、`.stage/`、`.identity.tmp/`、`ssh_keys.added` | helper;fresh overlay 時 96 抄 identity/prov 與 prov | 96、`--check` | |
| `/etc/.batman-prov-restore`(`<boot_id> <verdict> …`) | 96(每個出口) | helper(寫 log)、99zz(判 unclaimed) | |
| p5 `prov.cbor`、`prov.meta`、`identity/prov/` | **只有 `--prov-only`**(helper 呼叫) | 96、`--prov-get`、`--check` | identity 經 `identity/prov.tmp/` rename |
| p5 其他(`.seeded`、overrides、lkg、dropbear identity、shadow-root) | config-save 既有模式 | 96 | |
| `/opt/batdata/state/prov-state`(`<boot_id> <writer> <last_known_state> <verdict> <members_n> <mesh_expect>`,0600) | fresh S10:99zz;S89 起:helper。`last_known_state` 只在讀到確定的 prov 時更新(兩個寫者同規則);`unknown` 只寫 `verdict` | autocommit、`halow-status` 讀 `verdict`/`mesh_expect`;96 讀 `last_known_state` | 寫前 `mountpoint -q /opt/batdata` |
| `/opt/batdata/state/ble-ok`(`<boot_id>`) | helper(§6.4 條件) | autocommit | |
| `/opt/batdata/state/ota-armed.mesh`(`<arm_boot_id8> <target_slot> joined\|radio`) | `platform_check_image`(§6.4 條件) | autocommit;決策後刪 | |
| `/opt/batdata/state/mesh-expected`、`mesh-joined` | config-save / joinwatch(不改);helper 在 `network/leave` 刪 | autocommit | |
| `$RUNDIR/joinwatch.lastjoined`(`<uptime>`) | joinwatch(JOINED tick 覆寫) | stage 1 | 新 |
| 鎖定欄位(dropbear PasswordAuth/RootPasswordAuth、ttylogin、root shadow、`lock-status`) | fresh overlay(S10):96;S89 起的轉換(認領、完成未完的認領):helper,判斷「未完」看實際值 | `halow-status` | |
| `/etc/batman-dev-open` | 操作員 / harness | 96、helper | 對 claimed/member 不生效(照鎖,已有的 `authorized_keys` 保留) |
| `/etc/dropbear/authorized_keys` | 96 Lane A(fresh,從 p5)、操作員、helper `ssh_keys.set`(只動 `ssh_keys.added` 上的行) | config-save | 認領不碰 |
| live uci `wireless.*` | 執行期:`halow-setkey`(操作員、helper 交易、`.txn` 一次性對帳);fresh:94 meshpoint、95 morse-wireless-defaults(AP 預設開啟,F23)、96 Lane B、99-chanfix、morse 回寫;**fresh 且判為 unclaimed 時 99zz 把所有 `mode=ap` 的 key 設成 `CHANGE-ME-NOW`**(判斷:96 的 verdict 為 `unseeded` **且**(沒有 prov **或** `prov.meta` state=`unclaimed`)——涵蓋新卡、unclaimed 節點 OTA(L44)與清 overlay(L60)),S18 keyguard 因此關掉 AP | provd | 開機不對帳;99zz 只在 unclaimed 時寫,legacy / seeded 不碰。另有 dpp-handler(ubus `dpp push_button`)、`rc.button/wps`、`rfkill`、`reset_override` 會改 wireless,04/02 沒有按鍵硬體 → 今天不會觸發(inert);PR-P1 改 `rc.button/reset` 時一併處理 `reset_override` |
| `hostname`、`ahwlan.ipaddr` | 改名:helper(先 persist 再 `uci set` + `system reload`);openmanetd 之後重保留 IP 並重開(⚠️ U5) | | §6.6 |
| Pi EEPROM `bootloader_config` 的 persistent vars(`dropbear_authorized_keys`、`device_password`、`default_wifi_key`、`mm_region`、`mm_region_unlocked`、`mm_sku`、`mm_mode`、`mm_virtual_wire` 等) | 有實體接觸的人(recovery 卡);Batman 不寫 | **Batman image 一律讀到空**:PR-F 以 shim 取代 `/sbin/persistent_vars_storage.sh`(`READ` 一律 rc 1、無輸出、每次開機每個 key 記一次 WARN;`WRITE`/`ERASE` rc 1),F21 的 9 個讀者一次失效 | 02/04 今天就讀到空(F24),行為不變;副作用:Morse 的 EEPROM 區域鎖不再生效,國家一律由 uci / `halow-setkey` 決定 |
| `firstboot` / LuCI reset / `rc.button/reset` | 上游 | — | 只清本槽 overlay,96 會從 p5 還原(F22);**不是轉賣用的全清**;UI 文字改為「重新套用設定(不清除擁有者與資料)」,`rc.button/reset` 長按不再呼叫 firstboot(PR-P1) |
| 認領窗口、失敗計數、session、`s_node` | provd 記憶體 | | |
| `boot_id`、`nonce_node`、`nonce_helper` | helper | provd | 一次性,綁 `h` |

## 4. 契約

### 4.1 helper socket 與授權

- `SOCK_SEQPACKET`,一包一則 CBOR map;`SO_PEERCRED` uid == provd 否則關;單連線序列化;請求 ≤ 64 KiB;逾時 30 s。
- 每個改變節點的動詞都帶 helper 自己能驗、且 helper 自己組被驗內容的授權物件;provd 給的「算好的雜湊 / 挑戰」一律不收。
- **trial 槽**(`batman-slot is-trial` rc 0):改狀態動詞 `E_BUSY(updating)`;唯讀照常;身分產生照常。

| 動詞 | 授權(helper 驗) | 效果 |
|---|---|---|
| `info.cert/ecdh_pub/counter/boot_id/state` | 無 | 唯讀 |
| `nonce(h)` | 無 | 一次性 `nonce_node`/`nonce_helper`,綁 `h`,60 s |
| `sign.static`、`sign.ecdh_proof`、`sign.peer(peer_nonce, peer_fields…)` | purpose 固定;helper 依協定 §3.3/§3.6 自己組被簽內容,放入自己的 `boot_id`/`nonce_node` | DAC 簽章;額度:每條連線 0.5/s、全域 2/s |
| `psks.get()` | 無 | `{psk_owner[≤4], psk_member, psk_replay, adv_owner, adv_member}`(只回 HKDF 導出值,不回 `owner_tag_key`/`net_root`);prov 變更後 provd 重拉 |
| `claim.verify(h, client_resp, owner_pub, owner_enc_pub, sig_enc)` | helper 以自己發給此 `h` 的 `nonce_node`、自己的 DAC、即將寫入的 `owner_pub` 重算 `ClientChal`(協定 §5.4),`CheckMac` 常數時間;`sig_enc` 以同一把 `owner_pub` 驗;legacy 另需防呆門(§6.1) | §6.1 交易;`legacy\|unclaimed → claimed` |
| `claim.replay(h, client_resp, owner_pub, owner_op)` | 只接受 `psk_replay` session;state ∈ {claimed, member}、擁有者 1 位、`owner_pub` == 已存;CheckMac(重算)**且** owner-op(`verb=claim/replay`);失敗計數在 helper(每 boot 每小時 10 次) | 回存在 `prov.cbor` 的 `owner_tag_key`、`adv_owner_key`;產新 root 密碼 |
| `net.apply(net_config, net_secrets[, owner_op])` | `prov.cbor.net` 為空 → 需 owner-op `network/join`(`args_hash = H(net_config ‖ net_secrets)`);否則以上一版 `admins` 驗鏈(版本 +1、不跳號);helper 以 `ecdh.key` 解 `net_secrets`(明文 SAE key / `net_root` 不出 helper) | §4.4 交易 |
| `owner_op(obj)` | `ES256_owner("batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ verb ‖ args_hash)`;`nonce_helper` 一次性、60 s、綁 `h`;verb ∈ `network/join`、`network/leave`、`owner/*`、`settings/*`、`ssh_keys`、`root_password`、`diag`、`claim/replay` | 授權物件 |
| `root_password.reset(owner_op)` | owner-op | 新 24 字元 → shadow → `--save` → 回傳一次 |
| `diag.bundle(owner_op)` | owner-op | helper 的私有暫存檔,O_RDONLY fd,讀完刪 |
| `ssh_keys.set(list, owner_op)` | owner-op;每行 `^ssh-ed25519 [A-Za-z0-9+/=]+( [^\n]*)?$`、單行、≤ 256 B、≤ 8 行 | 只動 `ssh_keys.added` 清單上的行 |

- 不認得的動詞 / 多餘欄位 / 長度超限 → `E_SCHEMA`;授權失敗 → `E_FORBIDDEN`;trial → `E_BUSY`。
- **沒有** `keystore.ecdh`(解密 oracle)、`persist`(lkg 升級只由 helper 內部在 `meshjoin_joined` 後做)、`keystore.sign(purpose, msg)`(整段 msg 由 provd 給)、**沒有任何恢復出廠動詞**(U8)。
- **app 契約**:app 在送出 `claim/finish` **之前**,必須先持久化 `node_cert`(含 `ecdh_pub`)與 `claim-pending{device_id, owner_pub}`;否則回應遺失時算不出 `psk_replay`。進 S5 app addendum 與協定 v0.7。
- **誠實界線**:Noise 終點在 provd → 被攻陷的 provd 看得到經過它的明文:`claim/finish`/`claim/replay` 回應裡的 `owner_tag_key`、`adv_owner_key`、root 密碼,以及 `psks.get` 的 `psk_member`/`adv_member`/`psk_replay`。`psk_member` 全網共用(協定 §6)→ provd 被攻陷 = 能以成員身分連整個網路每一台的 BLE、追蹤全網廣播;換密碼後 provd 立刻重拉新值,**趕不走持續入侵,只能重燒該台**。helper 守住的是:改網、換擁有者、解 `net_secrets`、讀私鑰。同時連線 ≤ 2,兩個路人 central 可以佔滿(協定 §8 既有界線);每連線額度只保護已連上的買家那條。
- **負測試**(每條都是「關掉檢查就過」):provd uid 送 `net.apply` 錯簽 / 首版無 owner-op → `E_FORBIDDEN`;`claim.verify(h, resp_買家, owner_pub_攻擊者)` → `E_FORBIDDEN`;`claim.replay` 用不同 `owner_pub` 或無 owner-op → `E_FORBIDDEN`;`keystore.ecdh`/`persist` → `E_SCHEMA`;trial 上 `claim.verify` → `E_BUSY`;沒有正確 PSK 的 central 對已認領節點做 NXpsk0 → 收到格式正確的假第 2 則(解不出 `node_cert`)、等到交握逾時才斷,與正確 PSK 的回應時間分佈在統計上不可分(50 次)。

### 4.2 keystore 與身分

```go
type Keystore interface {
    SN() [9]byte; DeviceID() string            // file: sn = SHA-256(node_pub)[:9]; device_id = hex(sn); se: 晶片序號
    Cert() []byte                               // node_cert DER:鏈 [leaf](file 自簽)/ [leaf, mfr-CA](se)
    SignPurpose(purpose string, nodeNonce, peerFields []byte) ([]byte, error)  // helper 組訊息;不簽裸值
    ECDHPub() []byte; ECDH(peerPub []byte) ([]byte, error) // 只在 helper 內部(net.apply、psk_replay)
    CheckMac(clientChal, clientResp [32]byte) error        // 常數時間;秘密不出 keystore
    Backend() string                                       // "file" | "se"
}
```

`file` 後端 7 檔(`/etc/batman-prov/identity/`,目錄 0700):`node.key`、`ecdh.key`(P-256 PKCS#8,0600)、`node.cert`(自簽 `CN=dev:<device_id>`、`serialNumber=<sn hex>`、2020-01-01 → 2120-01-01,0644)、`claim.secret`(32 B,0600)、`backend`、`sn`、`sha256`(前 6 檔清單)。`claimed_counter` 在 `prov.cbor`(file 後端做不到跨重燒卡單調;608B 才有)。

**身分產生**:helper 只在「overlay 沒有完整 identity **且** p5 沒有完整且 sha 對的 `identity/prov/` **且**非 bypass」時產生:先寫 `.identity.tmp/` 7 檔 → rename 成 `identity/` → `--prov-only --prov-identity`。overlay 完整而 p5 沒有 → **補 persist,絕不重產**;p5 有而 overlay 沒有 → 還原。

**helper `--boot` 對 `--prov-get` 每個 rc 的行為**:

| rc | 意義 | overlay identity 完整 | overlay identity 缺 |
|---|---|---|---|
| 0 | p5 有完整 prov + identity | 比 generation(§4.4 步驟 7) | 從 p5 還原 |
| 7 | p5 ext4、未 seed、無 prov(新卡 / 重燒卡) | 補 persist | **產生** → `prov{unclaimed}` → persist |
| 9 | p5 seeded、無 prov(legacy 升級;或操作員 `--seed`/`--seed --reformat` 的 mkfs 把 prov 清掉了) | overlay 有完整 `prov.cbor` + identity → **整份重新 persist**(不產生 legacy,A11-m5);只有 identity → 補 persist identity、`prov{legacy}` | **產生** → `prov{legacy}` → persist(`--prov-only`,不碰 overrides) |
| 10 | p5 prov 不完整 / sha 不符 / meta 缺 | 以 overlay 為準 → 重新 persist | `unknown(prov-corrupt)`,不產生 |
| 13 | p5 有 prov 但 `identity/prov/` 缺或不完整 | 補 persist identity | `unknown(identity-lost)`,不產生 |
| 1 / 8(3 次) | mount 失敗 / lock busy | 沿用 overlay(非 fresh);persist 一律 `E_PERSIST` | `unknown(p5-unreadable)`;下次開機再試 |
| 3 | bypass | `unknown(bypass)` | 同左 |
| 11 | 無 p5 | `unknown(no-p5)` | 同左 |
| 12 | p5 非 ext4 | `unknown(p5-not-ext4)` | 同左 |
| 14 | prov `v` 太新 | `unknown(too-new)` | 同左 |

`--prov-get` 以 `ro` 掛(會 replay journal);失敗才退 `ro,noload` 並標 `maybe-stale`(讀到較舊的 gen 時,§4.4 步驟 7「overlay 新 → 以 overlay 為準」會自癒)。`unknown` 每次開機重算。

- `se` 後端(#255):`backend=se` 而 608B 不回應 → helper 拒絕啟動(fail-secure)。焊上 608B = 新身分、新 QR、重新認領。
- app:鏈長 1 且 CN `dev:` → TOFU pin,畫面標「開發機」;release build 拒絕。鏈長 2 → 製造商根驗證。
- helper 的 CLI 模式:`--boot`、`--apply-state [--firstboot]`(`--firstboot` = 99zz:寫 `prov-state`,並在 unclaimed 時設 AP placeholder;不 reload、不 persist)、`--persist-now`(重新 `--prov-only` 把 overlay 的 prov 寫回 p5;`P5_STALE_HINT` 指向它,A11-m7)、`qr`。`/etc/.batman-prov-restore` 只被 helper 讀來寫 log(這次 fresh 開機 96 做了什麼),不影響判斷。
- 開發期 QR:`batman-provhelper qr`(root);`claimed|member` 拒;`legacy` 只在 dev-open 存在或 stdin 是實體 console(`/dev/console`、`ttyAMA*`、`tty1`;不收 `pts`)時執行;stdout 不進任何 log。

### 4.3 p5 與 `batman-config-save`(PR-P1,兩板共用)

```
p5/  schema_version=1, .seeded, overrides.uci, lkg/, identity/dropbear/*, shadow-root  (不變)
     identity/prov/{7 檔}   (寫到 identity/prov.tmp/ 再 rename)
     prov.cbor   ({v:1, generation, state, radio_managed, claimed_counter, owner{pub,enc_pub,tag_key,adv_key}, admins[], net{config,secrets}, members, ssh_keys[]})
     prov.meta   (一行 "v=1 state=<s> gen=<n> sha=<hex64>";≤ 256 B;字元集 [a-z0-9=_ ];未知 key 忽略;v>1 → too-new;最後寫 = commit 紀錄)
```

| 模式 | 內容 |
|---|---|
| `--prov-only --prov-file f --prov-meta m [--prov-identity d] [--txn tok]`(新,只有 helper) | 取鎖(同 `--save`)→ 驗 `m` 格式與 sha、`f` regular ≤ 64 KiB;`--prov-identity` 驗 7 檔 + sha,p5 沒有完整 identity 時才寫 → 順序:identity → `prov.cbor` → `prov.meta` 最後 → sync。不碰 `.seeded`、overrides、lkg、dropbear identity、shadow。p5 未 seed 也可寫。rc:0 / 1 錯誤 / 8 lock busy(無 rc 6)。rc ≠ 0 時 helper 一律用 `--prov-get` 讀回 `gen` 判定 |
| `--prov-get <dir>`(新,唯讀) | 抄 `prov.cbor`、`prov.meta`、`identity/prov/` 到 `<dir>`(root 0700);rc 表 §4.2 |
| `--on-join`、`--save`、`--seed`、`--if-healthy` | 不寫、不刪、不比對 prov 檔(fp、`same_identity` 排除 `identity/prov/`、`prov.*`);`$RUNDIR/prov-txn` 有效 → `--on-join` rc 1(下 tick)、`--save` 等 ≤ 10 s;overlay `.txn` 存在 → `--on-join` rc 1 |
| `--check` | 另比 overlay / p5 `prov.meta`:不同 → `p5 stale: prov`(rc 5);`batman-slot` 的 `P5_STALE_HINT` 對 `prov` 改寫成「helper 會在下一次開機補寫;仍 stale → `batman-provhelper --persist-now`」 |
| `final_rc` 的「root 有沒有密碼」 | `root:!` 視為「已上鎖」:`--on-join` 回 0 不回 4 |
| `mark_mesh_expected()`、`seed_key_ok()`、lkg 規則 | 不改 |

`96`(PR-P1):
- 每個出口寫 `/etc/.batman-prov-restore`(含 boot_id)。
- **prov 抄寫放在 `.seeded` 檢查(`:93`)之前**:p5 `prov.meta` 格式對、sha 對、`prov.cbor` regular ≤ 64 KiB → 抄 `prov.*`(0600);`identity/prov/` 驗 sha 清單後抄(只 regular file、0600/0644)。meta `v` 太新 → 不抄。
- **上鎖在每一個出口之前判斷**(`:64` bypass、`:67` 無 p5、`:71` 非 ext4、`:89-91` mount 失敗、`:93` 未 seed、正常結尾):
  - 讀得到 p5 `prov.meta` 且 state ∈ {claimed, member}(不論 `prov.cbor` 有沒有抄成功)→ 上鎖;
  - p5 掛得起但 `prov.meta` **存在而格式壞**(或 sha 不符)→ 上鎖(fail-secure:可能是 claimed/member,A11-m4);`prov.meta` 不存在 → 不因 prov 上鎖;
  - 讀不到 p5(`:64/:67/:71/:89`)而 p6 已掛且 `prov-state` 的 `last_known_state` ∈ {claimed, member} → 上鎖;
  - 上鎖 = `PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`lock-status=LOCKED`(p6 已掛時),root 無 hash → `root:!`;dev-open 不豁免;
  - 其他 → 今天的 4b。
- 單元測試:96 對每個出口 × 有 / 無 prov × 4 種 state × meta 壞 / 好。

### 4.4 交易式 `state.apply`

以 `net.apply` 為例(`claim.verify` 見 §6.1):
1. helper 產 token → `$RUNDIR/prov-txn` + overlay `.txn`(含變更前的 wireless 值;fsync 檔與目錄);在 `.stage/` 組新 `prov.cbor`(gen n+1)+ `prov.meta`。
2. 可失敗的副作用:`halow-setkey … --no-persist`(它仍會 `uci commit wireless`,F5)。失敗 → 反向 setkey `--no-persist`、清 stage / txn、`E_APPLY`。
3. `--prov-only --txn tok`;rc ≠ 0 → `--prov-get` 讀回:gen == n+1 → 已提交,走步驟 4;gen == n → 回滾步驟 2、`E_PERSIST(rc)`。
4. rename overlay 的 `prov.cbor`、`prov.meta`(fsync)→ 刪 `prov-txn` 與 `.txn`。
5. 不可失敗的副作用(鎖、shadow、AP)→ `--save`(帶 overrides 與 shadow-root;rc 6 = 其餘已寫,log;rc 1 → log,下次開機 `--check` stale 由 helper 補)→ 寫 `prov-state`。
6. **開機時 `.txn` 存在**(步驟 1–4 間被打斷):`--prov-get` 判 p5 gen:== gen_to → 已提交,補步驟 4–5;== gen_from → 未提交:在 helper 背景(不阻塞 `--boot`、不阻塞 provd)等 `meshjoin_radio_up` 或 120 s,然後以 `halow-setkey`(會 persist)改回 `.txn` 記錄的變更前值,刪 `.txn`。期間 `--on-join` 讓路。沒有 `.txn` 的開機不對帳 wireless。
7. 開機 gen 比對:p5 新 → 以 p5 重建 overlay 的 prov;overlay 新 → 以 overlay 為準重新 `--prov-only`,log `p5 lost a committed prov write`;相等 → 不動。`.stage/` 殘留一律丟棄。
8. `--apply-state`(開機與 helper 重啟後):完成未完的轉換看實際值(PasswordAuth、RootPasswordAuth、ttylogin、shadow),不看 `lock-status`;legacy / unclaimed 不寫鎖定欄位與 AP;`--firstboot`(99zz,S10)寫 `prov-state`(writer=99zz);unclaimed 時把 `mode=ap` 的 key 設 placeholder(這是 99zz 唯一的 uci 寫入);不 reload、不 persist。
9. 操作員對 `radio_managed=1` 節點跑 `halow-setkey`:照做(現場要能改),但印警告「this node is app-managed (member): the change is not in the network config — other members and the app still use the old value; change it from the app」;prov 不改、開機不改回。`.txn` 存在期間(秒級)的操作員 setkey 會被步驟 6 改回,只在交易被斷電打斷時發生(殘項)。

### 4.5 轉賣與全清(U8:階段 1 = 轉賣工具重燒卡)

**為什麼一般燒卡不夠**(F19):發行 image 只有 4218 MiB,寫 image 只覆寫卡的開頭;舊 p6 尾端(04 上約 25 GB,含 OTS CA 私鑰)留在卡上,重燒後成為新 ext4 的空閒區塊,root 用原始讀取讀得回;重燒後的 unclaimed 節點是空密碼 root,**買家自己就能讀**。另外 image 內建的兩個 uci-default 會從 Pi EEPROM 讀 SSH 公鑰與 root 密碼(F21),撐過重燒。

**轉賣工具契約**(PR-P3 收進 repo:`scripts/transfer-flash.ps1`(Windows,主要)、`scripts/transfer-flash.sh`(原生 Linux 主機);本機 WSL 看不到讀卡機(要 usbipd-win,這台沒裝),不列為支援路徑):
1. **只接受工具內建清單裡的發行 image**:每次發行時把 image 檔名、**發行出去的 `.img.gz` 檔的 sha256**(工具解壓時另算 raw 的 sha256 並記錄)、board、版本寫進工具內建的清單(PR-P3 的發行流程更新它);image 的 sha256 不在清單 → 拒絕。這同時擋掉上游 / 單槽 image、**沒有 v13 EEPROM shim 的舊 Batman image**(清單只收階段 1 起的版本,B12-M2)與被竄改的 image。board 從清單取得,寫入前與目標使用者選的機型比對;bcm2710 image 有 7 個分割(多 p7),工具不數分割。
2. **目標必須是讀卡機上的卡**:Windows:`Get-Disk` 的 `BusType=USB` **且** `Win32_DiskDrive.MediaType` 為 `Removable Media` **且** `IsBoot`/`IsSystem` 皆為 false **且** 容量 ≤ 512 GB;顯示型號、容量、目前分割;要使用者輸入確認字串。Linux:`/sys/block/<dev>/removable=1` 或裝置名是 `mmcblk*`(原生 SD 槽 `removable=0`,另外要求 `--internal-sd` 明示);容量上限同上;**目標或其任何分割已掛載 → 拒絕;是執行中系統的根所在裝置 → 拒絕**(在 Pi 上 `--internal-sd` 可能指到自己的系統卡)。
3. **全卡清零**:Windows 先 `Clear-Disk -RemoveData` 移除分割、確定沒有卷掛在這顆碟(否則原始寫入會被拒),寫入期間防止系統睡眠;再以工具自己的寫零迴圈(對 `\\.\PhysicalDrive<N>` 4 MiB 區塊寫零;Linux `dd if=/dev/zero bs=4M conv=fsync` 或 `blkdiscard -z`;dd 到卡尾的 ENOSPC 以「已寫位元組 ≥ 裝置大小」判定成功)寫到卡尾,顯示進度;任何一步中斷或失敗都**不得回報成功**;不用 `Clear-Disk -RemoveData`(⚠️ 推論不寫零)、不用 diskpart `clean all`(沒有進度)。
4. **寫 image**,讀回比對頭尾。
5. **抽樣驗證**:image 結尾之後隨機取 ≥ 64 個 1 MiB 區塊讀回,必須全為零;否則失敗、提示換卡。
6. 時間:32 GB 卡預估 20–40 分鐘(⚠️ 實測),工具顯示進度。
7. 測試模式:`--test-target-file <檔>` 只給 harness(L16 工具層)用,**只接受 regular file**(不收區塊裝置),跳過可移除裝置檢查;另有負測試「非可移除裝置被拒」「區塊裝置當 test-target 被拒」。

**節點端**:
- **PR-F 以 shim 取代 `/sbin/persistent_vars_storage.sh`**(F21 的 9 個讀者一次失效;`31_*` 不必另外刪)。shim 行為:`READ` rc 1、無輸出;`READALL` 每個 key 印 `key=`(空值)、rc 0;`WRITE`/`ERASE` rc 1;每次開機每個 key 只 `logger -p daemon.warn` 一次(標記放 root-only `$RUNDIR`,不放 `/tmp`)。firmware 的 `files/` 目前沒進 git → PR-F 要 `git add files/sbin/persistent_vars_storage.sh`;斷言放進每次 build 都跑的 `check-image-manifest.sh` 並當發行清單的閘門。Batman image 不讀 EEPROM 的任何 persistent var;EEPROM 裡若有殘值也沒有作用。**後果(待使用者決定,Q7)**:Morse 的 EEPROM 硬體區域鎖不再生效,HaLow 國家只由 uci / `halow-setkey` 決定;今天 02/04 的 EEPROM 沒有區域鎖,所以不是回歸。
- 95 已在每次開機記 `BOOT_ORDER`/`PARTITION_WALK` → 改為與 bootloader 預設比對,不同就 WARN(`halow-status` 顯示),當作「EEPROM 被改過」的訊號。shim 的放法:放在 firmware 樹的 OpenWrt `files/` overlay(`files/sbin/persistent_vars_storage.sh`),它在組 rootfs 時最後複製、蓋過 `persistent-vars-storage-bcm2711` 套件的同名檔;現有 build 已用同一個 overlay 放 `files/etc/batman-build`(`build-board.sh:23`,節點上確有 `/etc/batman-build`)。PR-F 附斷言:image 內 `persistent_vars_storage.sh READ default_wifi_key` rc 1、無輸出;`docs/upgrade-1.8.0.md` 同步。
- **unclaimed 新卡的 AP**:99zz 在 fresh overlay、p5 未 seed、無 prov 時把所有 `mode=ap` 的 key 設成 `CHANGE-ME-NOW` → S18 keyguard 關 AP(F23;219 §6.2「未認領時不開 WiFi AP」)。
- 節點端不做任何清除機制;`firstboot` / LuCI reset / reset 按鈕只清本槽 overlay,96 會從 p5 還原(F22),不是轉賣用的全清 → UI 文字改為「重新套用設定(不清除擁有者與資料)」,`rc.button/reset` 長按不再呼叫 `firstboot`(PR-P1)。
- provd 收到協定的 `reset` → `E_UNSUPPORTED(reflash)`,app 轉到說明頁。

**app 說明頁**(PR-P3):
- **賣方**:⓪**接著 LoRa 模組(RAK4631)的機台:先用 Meshtastic app 或 CLI 對模組做 factory reset**(清頻道 PSK、節點資料庫、位置;F25);①先在 app 把這台從網路移除(`network/leave`),免得網路的成員名單留著它;②需要保留 OTS 等資料時,先用讀卡機把 p6 備份到電腦(擁有者沒裝 SSH key 時沒有別的匯出路徑);③用轉賣工具重燒;④最安全是換一張新卡交給買家。
- **買家**:收到二手機,**先用 Raspberry Pi Imager 的 bootloader 還原卡重設 EEPROM(還原後以 `vcgencmd bootloader_version` 確認版本不低於本文件驗證過的 2026/09/23 版,⚠️ 其他版本未驗證 A/B 行為),再自己用轉賣工具燒一次;接著 LoRa 模組的機台再對 RAK4631 做一次 factory reset**(不能信任賣方說「已重燒」;賣方也可能動過 EEPROM 以外的東西);新機的 QR 與身分要經 root 取得(`batman-provhelper qr`,接乙太網或 serial;unclaimed 的 image 預設是空密碼)——階段 1 限制,#255 的 608B 會把身分與 QR 固定在晶片上。
- **遺失手機或擁有者金鑰**:同賣方 ②③,重燒後重新認領(L59)。
- 轉賣只能用工具清單裡的階段 1 以後的 image;舊版 image(沒有 provd、還會讀 EEPROM)工具會拒絕。

**重燒後的結果**:p1–p6 都是 image 的新內容,卡的其他區塊全為零;第一次開機 96 看到未 seed 的 p5 → image 預設;99 重新個人化(hostname 依 MAC,與重燒前相同);helper rc 7、overlay 無 identity → 產新身分 → `prov{unclaimed}`。舊 QR 的 `claim.secret` 不存在 → 無效;前任 app 的 `psk_owner` / `psk_replay` 對不上新身分;前任的 SSH key 不在新的 `authorized_keys`,EEPROM 的 key 也不會被讀進來。

**誠實界線**:
- 全卡寫零是邏輯清除,**不是安全擦除**:SD 卡控制器的磨損平均與保留區塊可能留著舊資料,鑑識工具(繞過控制器)可能讀回;219 §7 寫明最安全是換新卡。
- 用其他燒卡工具(Raspberry Pi Imager、balenaEtcher、`dd` 只寫 image)**不會**清掉舊 p6 尾端 → 說明頁明寫只認 Batman 轉賣工具。
- EEPROM 的 persistent var 殘值不清(Batman 不讀它);但 EEPROM 的**開機設定**(`BOOT_ORDER`、`NET_INSTALL_AT_POWER_ON` 等,04 現在就開著網路安裝)會影響從哪裡開機 → **買家說明:一律用 Raspberry Pi Imager 的 bootloader 還原卡把 EEPROM 重設為預設**(B12-m5)。
- 有 root 的前任在交出前能做任何事;買家自己重設 EEPROM、重燒、重設 LoRa 模組是對這點唯一的處置。
- **擋不住**:前任以 OTP 寫入或 secure-boot 鎖改變 Pi(不可逆,重設 EEPROM 也還原不了);GPS 模組的備份記憶體(最後位置與設定,F25 ⚠️ 型號未查);HAT 或硬體層的實體植入。
- hostname / SSID 依 MAC 產生,重燒後不變(前後兩任可被串連,殘項)。

**#255 之後**:身分在 608B,重燒卡不換身分;「曾被認領」由晶片單調計數器記錄;app 端的恢復出廠在 #255 重新設計。本文件不預留任何恢復出廠的資源或動詞。

### 4.6 BLE 平台(04 spike 實測)

| 項 | 定案(firmware `feat/254-ble` a5e181b7;policy plugin 修正未重 build) |
|---|---|
| kernel | `kmod-batman-bt`:`CONFIG_BT=m`、`BT_BREDR=n`、`BT_LE=y`、`BT_HCIUART=m`(SERDEV / BCM / H4)、RFCOMM/BNEP/HIDP/btusb/btsdio 全 n;內建 bool `CONFIG_SERIAL_DEV_CTRL_TTYPORT=y`(改 `kernel8.img`,OTA 帶得到);FILES = bluetooth.ko、btbcm.ko、hci_uart.ko;`ble_diffconfig` deselect `kmod-bluetooth*`、`bluez-utils*`、`kmod-ath3k`、`ar3k-firmware` |
| 韌體 | `brcm-bt-firmware-4345c0`:`BCM4345C0.hcd`(63806 B,sha256 51c45e77…,RPi-Distro/bluez-firmware pios/trixie blob 007611e)+ LICENSE.cypress |
| BlueZ | board patch 0012:`bluez-daemon` = bluetoothd + bluetoothctl;不裝 obexd/hciattach/rfcomm/gatttool/sdptool、上游 main.conf / dbus policy / init;`bluez-libs` 依賴 `kmod-batman-bt` |
| `main.conf` | `Name=Batman`、`ControllerMode=le`、`AlwaysPairable=false`、`PairableTimeout=0`、`DiscoverableTimeout=0`、`JustWorksRepairing=never`、`Privacy=device`、`NameResolving=false`、`[GATT] Cache=no`、`[Policy] AutoEnable=true`;不裝 agent;provd 開機斷言 Pairable==false && Discoverable==false |
| dbus | 自己的 `bluetooth.conf`:只有 `<policy user="root">`(own/send org.bluez + 6 個 send_interface),無 default policy;PR-P2 加 `<policy user="provd">` 同一組 |
| init | `START=61 STOP=20`、`respawn 3600 5 0`、`--noplugin=hostname,autopair,battery,neard,sap`(policy 留著);無 hci0 時照跑等熱插拔 |
| distroconfig | `[pi4] core_freq_min=500`;p1 與 p3 兩份手動改(04 ✅、02 ❌);typo 不動(U7) |
| 3A+ | `[pi3]` `disable-bt` → `miniuart-bt` + `core_freq_min=?`(待板) |
| 待量 | AP 吞吐 vs BLE 共存;遮蔽 / 外殼對 RSSI;500 MHz 耗電 |

### 4.7 procd / ujail

| 服務 | START / STOP | 說明 |
|---|---|---|
| dbus | 60 | 既有 |
| bluetoothd | 61 / K20 | §4.6 |
| batman-provhelper | 89 / K15 | `--boot`、health、`ble-ok` |
| batman-provd | 92 / K10(在 bluetoothd / dbus 之前停) | ujail:uid/gid `provd`、`no-new-privs`、capabilities 空、唯讀 `/`、只掛 `/tmp/run/batman-prov` 與 dbus socket;`respawn 3600 5 0` + 自己退避 |

### 4.8 GATT / 廣播

照 `219-protocol.md` §4.1;MTU 協商、分段、序號;單則 ≤ 8 KiB,上限經 `CTRL/info` 回報;未交握只 `status/public`(格式版本、能力位元、`legacy|unclaimed` 時才帶 `device_id` 末 4 字元);adv 不帶 Local Name;同時連線 ≤ 2;未交握 10 s;失敗 3 次 / 連線;trial 時 `status/public` 帶 `updating=1`;已認領節點沒有匿名 NX 例外(replay 走 `psk_replay`)。

## 5. 生命週期矩陣

| # | 路徑 | 今天(1.5.12) | 階段 1 後 | 測試(負對照) |
|---|---|---|---|---|
| L1 | first boot,新卡 / 重燒卡 | 96 `:93` exit;AP 由 95 以隨機 key 開啟(F23) | 96 verdict `unseeded`;99zz 把 AP key 設 placeholder → keyguard 關 AP;helper rc 7 → 產身分 → `prov{unclaimed}`(p5 未 seed 也寫);dropbear image 預設 | `prov-firstboot-254`:`status/public` 可讀、`hci0` up、**`iw dev` 沒有 AP 介面**、`identity/` 0700、p5 有 `identity/prov/` 7 檔(負:rc 1 時不產生;負對照:1.5.12 新卡開機後 AP 是開的——1.5.12 不在轉賣工具清單,負對照用 bench 的 `flash-card.ps1` 燒);L44 / L60 也斷言沒有 AP 介面 |
| L2 | boot(member,非 fresh) | — | gen 相等 → `--apply-state` 只 log 漂移、不對帳 wireless | `prov-boot-254` ×3:無 `wifi reload` log、gen 不變、prov-state boot_id 是本次 |
| L3 | clean shutdown | — | provd K10 先停 | boot-reasons 乾淨 |
| L4 | reboot | 同 L2 | 同 L2 | |
| L5 | OTA 到本 image(fresh overlay) | 96 還原 | + 96 抄 prov;claimed/member 96 上鎖;前置:p1 與 p3 的 `core_freq_min` | `prov-ota-254`:claim+join → OTA → 新槽 member、gen 同、AP 同;`prov-lock-failsecure-254`:白箱把新 image 的 helper 換成 `exit 1` → claimed 節點 OTA 後密碼登入被拒;白箱讓 96 在 `:89` exit + p6 `last_known_state=claimed` → 仍上鎖 |
| L6 | autocommit commit / revert | `.seeded` / marker → NEED_MESH=1 | §6.4 | §6.4 負對照 |
| L7 | 斷電 / helper 死在 `state.apply` | — | 步驟 2–3 間:uci 已 commit、p5 未變 → 開機 `.txn` 一次性對帳(會 persist);3–4 間:p5 新 → 重建;4–5 間:鎖未做 → `--apply-state` 補做 | `prov-powerloss-254`:三個點;斷言 wireless == prov、p5 overrides == prov、04 在前兩點後仍可用 key 登入 |
| L8 | provd crash loop | — | 無限 respawn + 退避;認領結果在 helper / p5 | `prov-respawn-254` |
| L9–L11 | bluetoothd / dbus / helper 重啟 | — | provd `NameOwnerChanged` 重註冊 / 重連;無 hci0 → health `hci0_powered=0` | 各一 |
| L12 | downgrade 到 1.5.12 | — | 舊 96 還原 overrides + dropbear identity + shadow;LOCKED 若 authorized_keys 有行;無 BLE;`claimed` 未入網 / `member` 單台 / unclaimed 會被舊 autocommit revert,要 `batman-slot commit`;claimed 節點降級後舊 96 對「無 key 有密碼」判 UNPROVISIONED、`ttylogin` 預設 0 → serial 給 root shell(fail-open,實體威脅);p5 多出的 prov 檔舊程式不認、不刪;舊 image 在 fresh overlay 會重新執行 F21 的 EEPROM 讀者(02/04 的 EEPROM 沒有這些值,F24 → 無作用;EEPROM 被動過手腳的機台則會被讀進來) | `prov-downgrade-254` |
| L13 | bcm2710 | — | ❌ 等新板;共用檔未測 | — |
| L14 | bcm2711 | — | 本文件 | 全部 |
| L15 | `batman_bypass=1` | 96 exit 1 留著 | `unknown(bypass)`;不產生;persist 拒 | `prov-bypass-254` |
| L16 | 轉賣 = 轉賣工具重燒卡 | — | §4.5 | **工具層(不用現場)**:`prov-transfer-tool-254` 在 WSL 用 loop 檔(8 GiB,在 4218 MiB 之後與舊 p5 位置寫入特徵字串)以 `--test-target-file` 跑 Linux 轉賣工具 → 原始掃描特徵字串 = 0;另測:非可移除裝置被拒、不在清單的 image 被拒;負對照:只寫 image(今天的做法)→ 特徵字串仍在;拒絕上游 / 非 A/B image。**節點層(要現場)**:已認領 + 入網的 04 → 轉賣工具重燒 → 新 `device_id`、舊 `claim.secret` 無效、前任 `psk_owner`/`psk_replay` 連不上、前任 SSH key 被拒、全卡掃不到 04 上的 OTS 金鑰特徵字串;Windows 工具路徑同樣要實卡。(v11 用「UUID 換了」當斷言無效:image 的 UUID 建置時固定,A11-m1/B11-m2) |
| L17 | legacy 升級(02/04) | — | helper rc 9 → 產身分 → `prov{legacy}`(`--prov-only`,不碰 overrides,trial 上也安全);AP/dropbear/lock/`mesh-expected` 不動;autocommit 今天的規則 | `prov-legacy-upgrade-254`(04):AP key、lock-status、authorized_keys、mesh-expected 不變;負對照:04 OTA 到 `radio1.disabled=1` 的 trial → revert |
| L18 | legacy 認領 | — | 防呆門;`radio_managed=0`;不清 lab key | 04(已有 lab key,Q6)正;02 正;另做「無 key、無 dev-open」的白箱 → `E_UNSUPPORTED(no-ssh-key)` |
| L19 | distroconfig 改動 | — | 不隨 OTA;p1 與 p3 手動改 | PR-F(04 ✅ 40/40 500 MHz) |
| L20 | 96 掛不起 p5 | 96 被刪 | helper 下次開機自己再試;只補得回 prov / identity,overrides 仍停在 image 預設(與今天相同) | 白箱單元測試 |
| L21 | trial 上 app 操作 | — | 改狀態動詞 `E_BUSY(updating)` | `prov-trial-busy-254` |
| L22 | `network/leave` / `owner.remove` 後 OTA | — | prov 整檔換;helper 刪 `mesh-expected`/`mesh-joined`;新槽 `claimed` | `prov-leave-ota-254` |
| L23 | 改名 | — | ⚠️ U5;#202 兩次實證「改 hostname → openmanetd 重保留 IP 並重開」 | `prov-rename-254`(⚠️ 探針待使用者) |
| L24 | 兩支手機同時認領 | — | provd 序列化;第二個 `E_STATE` | `prov-two-phones-254` |
| L25 | 交易進行中 `--on-join` tick / OTA | — | `prov-txn` / `.txn` 讓路;`--on-join` 從不寫 prov;`--check` 看 prov.meta → stale 擋 OTA | `prov-netupdate-254`:步驟 2 故意失敗 + 期間 `--on-join` → p5 gen 與 overrides 都不前進;步驟 3–4 間插 sleep + `--on-join` + `reboot -f` → state=claimed |
| L26 | `network/update` → wifi reload | — | BLE 不受影響;provd 先 ack 再套用 | 同 L25 |
| L27 | joinwatch / openmanetd / dropbear 重啟 | — | 既有;`meshjoin_reachable` 在 dropbear 重啟時暫時假,JOIN_NEED 取樣涵蓋 | 既有 |
| L28 | BLE + WiFi AP 同顆 CYW43455 | — | 共存由韌體仲裁 | `prov-coex-254`(量吞吐) |
| L29 | 換手機 / 第二位擁有者 | — | S3:`owner.replace`;psk_owner ≤ 4 | 殘項(S3 PR) |
| L30 | prov 版本太新 | — | rc 14 → `unknown(too-new)` | 單元 |
| L31 | 單台在家更新(member、隊友關機) | — | stage 1:本次開機沒入網過 → `radio` → 只要 radio_up → commit | §6.4 (3) |
| L32 | fresh p5 暫時掛不起 | 96 被刪 | 同 L20 | 同 L20 |
| L33 | overlay prov 壞、p5 好 | — | §4.4 步驟 7 以 p5 重建 | `prov-overlay-corrupt-254` |
| L34 | 認領回應遺失(persist 後 BLE 斷 / 節點重開 / app 被殺) | — | app 以 `psk_replay` session + `claim/replay` 重取 | `prov-claim-replay-254`:persist 後 `reboot -f` → replay 拿到相同 `owner_tag_key`;錯 `owner_pub` → `E_FORBIDDEN`;app 被殺後重開仍可 replay(app 契約) |
| L38 | fresh trial 上 helper 晚於 autocommit | — | autocommit 讀到 writer=99zz → 等 ≤ 60 s 至 writer=helper,仍無 → 用 99zz 的值;boot_id 不符 → 今天的規則 | 白箱 |
| L39 | 遠端 BLE 讓 provd 一直 crash(trial 期間) | — | health 只看 bluetoothd + hci0 + 本次開機曾註冊廣播 → 不 revert 好 image | `prov-provd-dos-254` |
| L40 | team OTA(兩台 member 依序) | — | 第二台 stage 1 看 `joinwatch.lastjoined` → `joined` → 要求鄰居 | A 在 trial 時 B 跑 stage 1,B 的 image 預設頻道改掉 → B revert |
| L41 | `sysupgrade -T` / LuCI validate | — | 不寫 `ota-armed.mesh`(§6.4 條件) | `-T` 後檔案不存在 |
| L42 | 直接 `batman-slot apply`(ab-selftest) | — | 無檔 → member 要求鄰居(fail-closed) | |
| L43 | operator `batman-slot commit` / stage 2 拒寫 | — | 殘留檔綁 arm 開機 boot_id → 下一次 trial 無效 | |
| L44 | unclaimed / 重燒卡後 OTA | #202 閘擋(p5 未 seed) | #202 閘 prov-aware:p5 `prov.meta` state=unclaimed → 不擋 | unclaimed `sysupgrade -n` 進 trial 並 commit(今天被 `not seeded` 拒) |
| L47 | 認領測試後 harness 存取 04 | — | 上鎖後 key 登入仍可用(U3);04 已有 lab key(Q6) | 認領後 `ssh -o PasswordAuthentication=no` 成功 |
| L59 | 擁有者遺失手機 / 擁有者金鑰 | — | 出口只有轉賣工具重燒;重燒會清掉 p6(OTS 資料)→ 先用讀卡機備份 p6(§4.5) | PR-P3 文件 |
| L60 | 同槽清 overlay(`firstboot`、LuCI reset、reset 按鈕) | 清 overlay → 96 還原 | 同今天:96 從 p5 還原設定 / 身分 / prov,狀態不變;不是重置(F22) | `prov-overlay-wipe-254`:清 overlay 後 state 與 `device_id` 不變 |
| L61 | p6 永久壞 | 95 crit | 95 既有 crit 路徑;`prov-state` 不可用 → 96 只靠 p5 `prov.meta` 判上鎖 | 白箱 |
| L51 | 現場入網後帶回家、沒重開就更新 | — | `lastjoined` 為真 → 要求鄰居 → revert;說明書寫「先重開再更新」或用 `autocommit-hold-once`;joinwatch 停用時退回當下 `meshjoin_joined` 單次取樣 | 白箱 |

(L35–L37、L45、L46、L48–L50、L52–L58 是恢復出廠機制的列,隨 U8 移除;編號保留不重用。)

## 6. 流程

### 6.1 認領 / 重取 / 防呆門

**`claim.verify` 交易**:
1. `prov-txn`;helper 驗(§4.1);產 `owner_tag_key`、`adv_owner_key`、root 密碼(24 字元,只在 helper 記憶體)、新 `prov.cbor`(state=claimed、`radio_managed`、owner、`claimed_counter+1`)。
2. `--prov-only` persist(rc ≠ 0 → 讀回 gen 判定)。
3. rename overlay prov → 刪 `prov-txn`。
4. 上鎖(§6.2):shadow 寫密碼 hash → `--save`(帶 shadow-root)。
5. 回應 `{owner_tag_key, adv_owner_key, root_password}`;不快取(回應遺失走 `claim/replay`,每次換新密碼)。
6. `prov-state=claimed`。

**`claim.replay`**(L34):app 以 `psk_replay` 建 session(需要擁有者加密私鑰 + 認領時存下的 `node_cert`),送 `claim/replay`(CheckMac 用 QR 秘密 + owner-op 用擁有者簽章私鑰)→ helper 回 `prov.cbor` 裡的 `owner_tag_key`/`adv_owner_key`,並產新 root 密碼。只持有 QR 的人(前任、修理行)連不上 `psk_replay` session,也沒有 owner-op。

**legacy 防呆門**:state=`legacy` 時 `claim.verify` 另要求 `/etc/batman-dev-open` 存在**或** `authorized_keys` 至少一行可用;否則 `E_UNSUPPORTED(no-ssh-key)`。**這道門只防誠實的操作員把自己鎖在外**;legacy 節點今天 root 開放(#137:連上 04 AP 就能 SSH root),root 能自己加 key 或 touch dev-open → legacy 上的 root = 可以認領,這是既有缺口,本設計擋不住。

### 6.2 鎖定
`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、隨機 root 密碼(交 app;遺失用 `root_password.reset`)、`lock-status=LOCKED`;dropbear 照跑(`meshjoin_reachable` 依賴它,F7);不動 `authorized_keys`;`/etc/batman-dev-open` 不進任何 image(harness / 操作員手動 touch),對 claimed/member 不生效。

### 6.3 建網 / 加入
§4.4;首版需 owner-op `network/join`;helper 驗 COSE、解 `net_secrets`;成功後 `radio_managed=1`;`--save --promote-lkg` 只由 helper 在 `meshjoin_joined` 後下。

### 6.4 autocommit(兩板共用)

**stage 1 寫 `ota-armed.mesh`**:`platform_check_image` 在 `precheck-node` 通過後,只在以下全部成立時寫:本次 validate rc=0、`caller` 是 `/sbin/procd`、`upg=y`(`$RAM_ROOT/sbin/upgraded` 已安裝)、有一個活著的 sysupgrade 程序(uid 0、`/proc/<pid>/ns/pid` == `/proc/1/ns/pid`、`readlink -f` 以 `/proc/<pid>/cwd` 解析 argv[1] == `/sbin/sysupgrade`;不用 `pgrep -f` 子字串)。`-T`、LuCI、sysupgrade 自己的第一次 validate 都不寫(F8)。p6 已掛;先 `rm -f` 舊檔(失敗 → 拒絕 OTA);`m=radio`;`$RUNDIR/joinwatch.lastjoined` 存在(本次開機曾 JOINED)或當下 `meshjoin_joined` → `m=joined`;寫 `<boot_id 前 8 碼> <batman-slot target> <m>`(tmp + rename + sync,0600)。⚠️ bench 上以 `-T`、真 OTA、中止後 LuCI validate 各一次實證三種 caller。

**trial 讀**:`ota-armed.mesh` 的 boot_id == `boot-reasons.log` 倒數第二行(= arm 的那次開機,F11)且 slot == 本 trial 的 slot → 採用;否則(缺、不符、壞)→ 視為 `joined`(fail-closed)。決策(commit 或 revert)後刪。#133 stale-fallback 開機:既有邏輯(非真 tryboot → 不 commit 不 revert)不變,只在真 tryboot 讀這個檔。

**`expected_in_mesh()`**:讀 `prov-state`(`verdict` 第 4 欄、`mesh_expect` 第 6 欄);fresh trial 上 writer=99zz → 等 ≤ 60 s 至 writer=helper,仍無 → 用 99zz 的值;boot_id 不符 → 今天的規則。

| state | NEED_MESH | 鄰居要求 |
|---|---|---|
| 無檔 / `legacy` / `unknown` | 今天的規則(`:388-396`) | 今天的規則 |
| `unclaimed`;`claimed` + placeholder | 0 | — |
| `claimed` + live key | 今天的規則 | 今天的規則 |
| `member` | `meshjoin_radio_up` 必須成立(wlh0 存在、mesh point、mesh_id == uci) | `ota-armed.mesh` 採用且 = `radio` → 不要求;否則 `meshjoin_reachable` ≥ JOIN_NEED |

- `health_ok()` 加:`ble-ok` 存在才檢查 `$RUNDIR/batman-prov.health`(≤ 60 s;`bluetoothd=1 hci0_powered=1 adv_registered_once=1`;不看 provd 現在是否活著);無 `ble-ok` → 只 log WARN。
- `ble-ok` 寫入條件:committed 槽 **且** 兩個 boot FAT 的 `distroconfig.txt` `[pi4]` 都有 `dtoverlay=miniuart-bt` 與 `core_freq_min=500`(唯讀檢查)**且** `vcgencmd get_config core_freq_min` ≥ 500 **且** `Powered` 連續 ≥ 10 分鐘。
- 逃生口:`autocommit-hold-once`(F3)。

**負對照**:(1) 04 legacy OTA 到 `radio1.disabled=1` → revert;(2) claimed + placeholder(unclaimed 認領後、`--save` 已 seed)OTA → commit(1.5.12 `.seeded` → NEED_MESH=1 → revert);(3) member 單台、本次開機未入網 → commit;(4) member 有鄰居 OTA 到改頻道的 trial → revert;(5) 刪掉 `ota-armed.mesh` → 要求鄰居;(6) `-T` 後直接 apply → 要求鄰居;(7) team OTA(L40);(8) `ble-ok` 在、`bluetoothctl power off` → UNHEALTHY;不在 → 只 WARN;(9) trial 期間 provd 反覆被 kill → 不 revert;(10) 非 root 程序 / 容器 root 偽造 sysupgrade cmdline、相對路徑呼叫 → 判定正確。

### 6.5 診斷
`diag.bundle` 走 BLE(owner-op);`/www/cgi-bin/bundle` 階段 1 只在 `legacy|unclaimed` 且 `batman-dev-open` 時可用,其他 403(殘項:正式驗證)。

### 6.6 改名
L23。helper 先 persist → `uci set hostname` + `system reload`;app 顯示「機台會重新啟動」;hostname `[A-Za-z0-9-]{1,32}`;SSID 不跟著改(殘項)。⚠️ 探針待使用者。

## 7. 依賴與證據

| # | 依賴 | 證據 | 狀態 |
|---|---|---|---|
| D1 | `miniuart-bt` + `SERIAL_DEV_CTRL_TTYPORT=y` → serdev 綁定、`hci_bcm` probe、patchram | F16 | ✅ |
| D2 | 自建 kmod + deselect 上游 `kmod-bluetooth` 不衝突 | F16(04 build 過、三模組) | ✅ |
| D3 | `.hcd` 來源與授權 | §4.6 | ✅ |
| D4 | BlueZ D-Bus LE adv/GATT 可由 provd uid 使用(policy 放行後) | spike 以 root 驗;provd policy 待 PR-P2 | ⚠️ |
| D5 | uci-defaults 全在 S10、`99zz` 排在所有 `9x` 之後(只有 `luci-i18n-*` 在它後面,無關 wireless)、exit 0 被刪 | F20 | ✅ |
| D6 | 96 Lane A 順序、`.batman-p5-restored` 由 99 刪 | F4 | ✅ |
| D7 | config-save 鎖 / 接管、stage + mv、`--check` rc、`--save` 首次 seed、rc 6 語意 | F2 | ✅ |
| D8 | `batman-slot precheck` 擋 stale;#202 未 seed 閘 | F12 | ✅ |
| D9 | autocommit 現行邏輯 | F3 | ✅ |
| D10 | ujail、capabilities | 既有 | ✅ |
| D11 | Go 工具鏈、vendoring | #252 | ✅ |
| D12 | `core_freq_min=500` 穩定 | F17 | ✅ |
| D13 | `halow-setkey` 行為(含 `:99` 無條件 commit) | F5 | ✅ |
| D14 | 無 agent → 不可 bond;bluetoothctl 自帶 agent | F16 | ✅ |
| D15 | 改名 → openmanetd 重保留 IP 並重開 | #202 兩次實證 | ⚠️ U5 |
| D16 | 04 faketime 卡 2025-07-15 | #174 | ❓ |
| D17 | Go CBOR / Noise 與向量一致 | 待 PR-P2 | ⚠️ |
| D18 | stage 1 live 系統可跑 `meshjoin_sample`、p6 已掛 | `platform-ab.sh:150` | ✅ 原始碼 / ⚠️ 實跑待 PR-P1 |
| D19 | stage 2 無 iw/batctl/ip、無 p6 | F9 | ✅ |
| D20 | 「rc=0 + caller=procd + upg=y + 活著的 sysupgrade 程序」→ 視為真的升級(單向蘊含) | F8 | ✅ 原始碼與 04 trace / ⚠️ bench 三種實證 |
| D21 | `boot-reasons.log` 倒數第二行 = arm 的那次開機 | F11 | ✅ |
| D22 | 608B ECDH 槽可輸出共享秘密給主機做 HKDF(`psk_replay`、`net_secrets`) | 協定 §7.3 | ✅ 文件 / ⚠️ #255 實機 |
| D23 | 重燒卡後 p5/p6 是新檔案系統 | F19 | ✅ 原始碼 / ❌ 實跑待 L16(要現場) |

## 8. 安全

**資產**:節點控制(root、OTA 槽)、mesh/AP 金鑰、節點身分、認領秘密、擁有者 / 網主金鑰、成員名單、診斷包、tenant 資料(OTS DB)、BLE 可用性。

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| BLE 路人 | 讀身分 / 追蹤 | 未交握只 `status/public`;`claimed\|member` 不帶 `device_id` 末碼;RPA(節點端以 `Privacy=device` 設定,⚠️ PR-F 要以 btmgmt / 第二台 central 驗證節點廣播位址確實輪替,spike 只看到 iPad 端用 RPA,A11-m8);adv 無 Local Name;已認領節點無匿名 NX(失敗 PSK 照協定 §3.4 送假第 2 則) | §4.1 |
| BLE 路人 | 暴力認領 | 256-bit;每連線 3 次即斷 | `prov-sec-claim-brute-254` |
| BLE 路人 | 佔連線 / 大訊息 / crash provd / 吃簽章額度 | ≤ 2 連線、10 s、8 KiB;無限 respawn + 退避;每連線簽章額度;全域交握 20/分可被吃滿是協定 §8 既有界線 | `prov-sec-hog-254`、`-oversize-254`、`prov-respawn-254` |
| BLE 路人 | 讓 provd crash 以 revert 好 image | health 不看 provd 存活 | `prov-provd-dos-254` |
| BLE 路人 | 配對 / 綁定 | 無 agent、`AlwaysPairable=false`、BR/EDR 不編 | `prov-sec-bond-254`(04 ✅) |
| BLE 路人 | kernel BT 堆疊 | 只 LE、三模組;BlueZ 進 #247 | SBOM |
| 路人 → 攻陷 provd | 改網 / 換擁有者 / 解 `net_secrets` / replay 換擁有者 / 升 lkg | helper 重算 ClientChal、owner-op、admins 鏈、首版 join 需 owner-op、replay 綁已存 owner_pub、無 ecdh/persist 動詞 | §4.1 負測試 |
| 攻陷的 provd(擋不住的部分) | 看到經過的明文、冒充全網成員 BLE session | 誠實界線(§4.1):只能重燒該台 | — |
| 只看過 QR 的人(前任、修理行) | 探測節點 / replay | `psk_replay` 需擁有者加密私鑰 | L34 |
| 連上 legacy 節點 AP 的人 | SSH root → `qr` → 搶認領 | `qr` 在 legacy 需 dev-open 或實體 console;防呆門;**legacy 上 root = 可認領,既有 #137 缺口,擋不住** | L18 白箱 |
| 本機非 root | 操作 org.bluez / 冒用 helper / 讀秘密 / 預建 socket 目錄 | dbus root-only policy、PEERCRED、0600 / 0700、`O_NOFOLLOW`、`/tmp/run` root 0755 | `prov-sec-dbus-254`(04 ✅)、`-helper-uid-254`、`-key-perms-254`、tmp-trust 掃描 |
| 本機非 root / 容器 root | 偽造 sysupgrade 程序讓 `ota-armed.mesh` 被寫 | uid 0 + 主機 pid ns + 路徑解析 | §6.4 (10) |
| 前任擁有者(轉賣) | 保留資料 | 轉賣工具全卡清零後寫 image(§4.5) | L16 工具層(WSL)+ 節點層(現場) |
| 前任擁有者(轉賣) | 經 EEPROM 預先植入 SSH key / root 密碼 / AP 金鑰 / 區域鎖,撐過重燒 | PR-F 的 `persistent_vars_storage.sh` shim(F21 全部讀者失效);unclaimed AP 由 99zz 關;買家重設 EEPROM | `prov-eeprom-hooks-254`(在 WSL 對解出的 rootfs 跑,不在節點上):shim image 的 rootfs 對所有 key `READ` rc 1;以 PATH 上的假 `vcgencmd` 回傳 `dropbear_authorized_keys`、`device_password`、`default_wifi_key`、`mm_region` → fresh overlay 後 `authorized_keys` 不含它、root 密碼不變、AP 關、country 不被鎖(負對照:1.5.12 image 會全部採用) |
| 前任擁有者(轉賣) | RAK4631 flash 留著前任隊伍的 LoRa 頻道 PSK、節點資料庫、隊友位置 | 賣方 / 買方步驟各做一次 Meshtastic factory reset(§4.5) | L16 節點層斷言:重燒並重設後,以 Meshtastic CLI 讀模組設定,頻道 PSK = 預設、節點資料庫為空(負對照:只重燒 SD 卡 → 舊頻道仍在) |
| 前任擁有者(轉賣) | 改 EEPROM 的開機順序 / 網路安裝,讓機台從別處開機 | **擋不住**(EEPROM 不在 SD 卡上);買家說明要求重設 EEPROM | 文件 |
| 買家(對賣方) | 收到被動過手腳的卡 | 買家說明:自己用轉賣工具再燒一次(§4.5) | 文件 |
| 擁有 SD 卡 | 複製身分 / 改 prov.cbor 升自己為擁有者 / 讀殘留區塊 | 擋不住(階段 1 限制;608B / LUKS);重燒不是安全擦除 | — |
| p5 被改(實體)/ helper 壞 | 96 不鎖 → fail-open | 96 對 claimed/member 一律上鎖、p5 讀不到時看 p6 提示 | `prov-lock-failsecure-254` |
| 供應鏈 | `.hcd`、BlueZ CVE、信任根 | sha 釘死;#247;無內建 CA | SBOM |
| 我們自己 | 兩寫者、fail-open、log 洩密 | §3 單寫者;`qr` / 密碼不進 log | 96 單元;`logread \| grep -c <secret>` = 0 |

既有缺口(不是本變更造成):AP/mesh PSK world-readable(`/etc/config/wireless` 0644,#13);LOCKED 後 login 在 GPS 口(`console=ttyAMA0`,#105);legacy root 開放(#137)。

## 9. 測試

- **協定裁判**:Go 實作逐位元組過向量(含新增 `-dev`、`batman-owner-op-v1`、`device_id`、`psk_replay`、固定 6 次);與 `verify.py` 做對手交握(CI)。02 當 central 只驗 GATT 框架。
- 每個 `prov-sec-*` 與 §5 / §6.4 的修正都有「關掉檢查 / 舊規則就錯」的負對照。
- tier A:firstboot、boot、sec-*、respawn、bluez-restart、helper-restart、bypass、legacy-upgrade、two-phones、trial-busy、overlay-corrupt、provd-dos。tier B(DNODE):ota、autocommit (1)–(10)、downgrade、leave-ota、legacy-claim、netupdate、claim-replay、rename(⚠️)。destructive:powerloss ×3、lock-failsecure。PR-F:coex。**L16 重燒卡驗收要現場**。
- 破壞性測試先列副作用與還原(使用者 2026-10-18 規則)。認領測試在 04 的前提是 04 有 lab key(Q6 已做)。
- harness 不用 bluetoothctl 當長駐 client(F16);節點端 BLE 斷言走 helper 的 health 檔。
- `prov-tools-254`(tier A):斷言 `flock`、`fsync`、`readlink -f`、`mountpoint` 存在;缺 → FAIL。

## 10. 實作切法

1. **PR-F(firmware)**:`feat/254-ble` 現狀 + 重 build(policy plugin 修正)+ **以 shim 取代 `/sbin/persistent_vars_storage.sh`**(F21,9 個讀者一次失效)→ 04 OTA 驗 `Powered` 自動、`Pairable: no`、三模組、dbus 負測試、閒置 500 MHz;release note:p1 與 p3 兩份 distroconfig 要手動改。
2. **docs PR**:`219-protocol.md` v0.7(`batman-owner-op-v1`、首版 join 授權、`device_id` 公式、helper 重算 ClientChal、`psk_replay` 與固定 6 次;`reset` 動詞 → `E_UNSUPPORTED(reflash)`、`E_VERSION` 逃生口、CDDL reset-level 移除)、CDDL、向量;`219-field-provisioning.md` v2.9(§6.1、§6.3、§6.9 對齊;§7 恢復出廠與任務表、版本協商、daily-validation 列改「階段 1 = 轉賣工具重燒卡,#255 重設計」)。
3. **PR-H1(harness)**:`prov-*` 骨架、02 central client、`verify.py` 對手模式。
4. **PR-P1(產品,兩板共用檔)**:99zz 對 unclaimed 新卡的 AP placeholder(F23);config-save(`--prov-only`、`--prov-get`、fp / check 納入 prov、`prov-txn` / `.txn` 讓路、`final_rc` 的 `root:!`)、96(prov 抄寫在 `:93` 前、每個出口前判上鎖、verdict 帶 boot_id)、`halow-setkey --no-persist` + 對 `radio_managed` 節點的警告、platform-ab 的 stage 1 `ota-armed.mesh`、autocommit(§6.4)、#202 閘 prov-aware、`meshjoin_radio_up`、joinwatch 寫 `lastjoined`、99zz;helper + keystore `file`(socket 測試,無 BLE)。bcm2710 ❌,寫進 PR body。
5. **PR-P2**:provd、GATT、協定核心、`status/public`、認領(含 replay、防呆門)、鎖定、`ssh_keys`、`root_password`。
6. **PR-P3**:建網 / 加入 / 邀請 / 狀態 / 診斷 / 離開 / 改名;app 的賣方 / 買方 / 遺失手機說明頁;**轉賣工具**(`scripts/transfer-flash.ps1`、`scripts/transfer-flash.sh` 收進 repo,§4.5 契約,含發行 image 清單與發行流程的更新步驟)與 `prov-transfer-tool-254`;LuCI reset 文字與 `rc.button/reset`(F22)。
7. S4(更新)、S5(app)addendum。

## 11. 殘項(回 #254)

3A+ 全部 + 共用檔 bcm2710 實測;04 I2C 空;SSID / hostname 跨擁有者可串連;`/www/cgi-bin/bundle` 正式驗證;#110 能力偵測接軌;LED 不做;`halow-status:118` 文字;`owner.replace`(L29)進 S3;既有缺口 #13 / #105 / #137;改名探針(U5);`core_freq_min=500` 耗電;RSSI 遮蔽 / 外殼;02 的 p1/p3 `core_freq_min`;`.txn` 期間操作員 setkey 會被改回;`network/update` 從 app 統一改頻道(操作員 setkey 會分歧);D4 / D17 / D20 / D22 實證;**L16 節點層與 Windows 工具要現場實卡**;**app 端恢復出廠在 #255 重新設計**(U8);GPS 模組型號與 BBR 清除方式(F25 ⚠️);RV-3028(之後的 HAT RTC)的持久資料;dpp-handler 是否停用;EEPROM 殘值不清(無讀者);轉賣工具全卡清零的時間(32 GB 約 20–40 分鐘)⚠️ 實測。

## 12. 待決

| # | 題 | 定案 |
|---|---|---|
| Q1 | legacy 身分何時產生 | 升級後第一次開機(`--prov-only`,trial 上也安全) |
| Q2 | `batman-dev-open` 進哪個 image | 不進任何 image |
| Q5 | 恢復出廠破壞性測試在哪台跑 | 不再需要(U8)。L16 工具層在 WSL 跑;節點層與 Windows 工具要現場實卡,使用者到現場時再排 |
| Q6 | 認領測試會把 04 上鎖 | 已做(§1.1) |
| **Q7** | shim 讓 Morse 的 EEPROM 硬體區域鎖失效(國家只由 uci 決定) | **待使用者決定**(法規):建議接受——02/04 今天就沒有區域鎖;民用 SKU 出廠時由 image / app 設國家(預設 TW),之後 #255 可用 608B 或 image 簽章另做區域鎖 |

## 13. v13 審查 → v14 對應

| v13 發現 | 收法 |
|---|---|
| **B13-M1 / A13-m8** 轉賣沒處理 RAK4631(Meshtastic)的 flash | F25 周邊盤點;§4.5 賣方 / 買方各一次 Meshtastic factory reset;§8 加一列 + L16 節點層斷言與負對照 |
| A13-m1 / B13-m1 99zz 只看「無 prov」→ unclaimed OTA / 清 overlay 後 AP 開 | 判斷改為 verdict=`unseeded` 且(無 prov 或 state=`unclaimed`);L44 / L60 斷言沒有 AP |
| A13-m2 / B13-m2 99zz 契約矛盾、D5 | §3 讀者加 99zz;`--firstboot` 寫明唯一的 uci 寫入;D5 改字 |
| A13-m3 / B13-m6 / B13-m7 shim 進 git、build 斷言、WARN 標記位置、READALL | §4.5 shim 行為與 PR-F 要求 |
| A13-m4 區域鎖失效是法規決定 | §12 Q7 待使用者 |
| A13-m5 root 也能改 EEPROM / OTP | F21 改字;95 比對 `BOOT_ORDER` 基準並 WARN;誠實界線列 OTP / secure-boot 鎖 |
| A13-m6 bootloader 版本沒釘 | 買家步驟寫明驗證過的版本(2026/09/23),其他版本 ⚠️ |
| A13-m7 / B13-m3 Windows 工具細節 | §4.5 第 2、3 點:Clear-Disk 後卸載、MediaType 來源、IsBoot/IsSystem、防睡眠、中斷不回報成功、sha 算 `.img.gz` |
| B13-m4 Linux 工具拒絕已掛載 / 系統碟、ENOSPC | §4.5 第 2、3 點 |
| B13-m5 `--test-target-file` 只收 regular file | §4.5 第 7 點 |
| A13-m9 其他 live wireless 寫者 | §3 列為 inert;`reset_override` 併入 PR-P1;dpp-handler 列殘項 |
| A13-m10 / B13-m8 EEPROM 測試與 L1 負對照的跑法 | `prov-eeprom-hooks-254` 改在 WSL 對解出的 rootfs 跑;L1 負對照用 bench 的 `flash-card.ps1` 燒 1.5.12 |
| A13-m11 「兩個 uci-default」、95 讀 bootloader_config | §4.5 改為 9 個讀者;F21 註明 95 只記 BOOT_ORDER |
| B13-m9 GPS BBR、HAT / 硬體植入、OTP 鎖 | 誠實界線 + 殘項 |
