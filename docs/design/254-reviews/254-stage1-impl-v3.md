# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v3**

狀態:v2 兩位 REJECT(A:3 BLOCKER / 9 MAJOR / 16 MINOR;B:3 BLOCKER / 10 MAJOR / 16 MINOR;報告 `254-reviews/review-v2-{A,B}.md`,v2 全文 `254-reviews/254-stage1-impl-v2.md`)。v3 整份重寫 §4.1、§4.3–§4.6、§5 L6/L16/L17、§2/§3 的 hook 模式;§13 列 v2 每條的收法。**PR-F BLE spike 已在 04 真機跑過**(#254 留言 6251617876 / 6255818833 / 6255842632),§4.6 與 D1 從推測改為實測。
上層設計:`219-field-provisioning.md`(v2.8)、`219-protocol.md`(v0.6;本文件要求的改動列在 §1.3,成為 v0.7)。本文件只定**實作層介面**;與上層衝突處在 §1.3 明列,以本文件為準。
基準:Batman `main` f2f2bf6(= 出貨 1.5.12-wsl.2),firmware `build-3aplus` 527303e8 + spike 分支 `feat/254-ble` a5e181b7;節點 02(10.41.1.1,slot B,1.5.12-wsl.2)、04(10.41.1.3,slot B,**1.5.12-wsl.3 spike build**,OTS)皆 Pi 4B Rev 1.5。03(3A+)故障,階段 1 只做 Pi 4,3A+ 等新板。

## 0. 一句話

加 **BLE(自建 `kmod-batman-bt` + 精簡 BlueZ,只開 LE、不配對、dbus 預設拒絕;spike 已驗)**、一支**非 root 的 `batman-provd`(Go,ujail)** 與一支 **root 的 `batman-provhelper`**;helper **自己重算/驗證每個改變節點的請求的授權物件**(provd 被攻陷 ≠ 能改網、能重置、**能換擁有者**);私鑰與 PSK 導出只經 helper 的 **keystore 介面**(階段 1 `file` 後端,之後 `se`);**p5 是擁有權的 SoT,overlay 只是快取**,p5 上是單檔 `prov.cbor`(+ 文字 sidecar `prov.meta`)與一次寫入的 `identity/prov/`,p5 的唯一寫者仍是 `batman-config-save`(helper 用**明示參數**交檔,config-save 永不自己去讀 `.stage/`);**狀態只由 `prov.cbor.state` 決定**(`legacy|unclaimed|claimed|member`),helper 每次開機**自己經 config-save 看 p5**,96 的 marker 只是「這次 fresh 開機 96 做了什麼」的回報;**擁有權與 SSH 脫鉤**;既有 fleet 節點(02/04)升級後是 `legacy`:**OTA 的 mesh 閘門與今天完全相同**、AP/dropbear/lock 不動;**恢復出廠 = 依 219 §7 的順序與範圍清 p6 → p5 → 另一槽 → 本槽 overlay**,用現成工具(`payload-teardown --zeroize`、`jffs2reset -y`、`batman-slot` 既有的 `invalidate_slot`+`clear_root`)組合成新動詞,重開後是真正的 `unclaimed`、新身分、新 QR。

## 1. 決策、範圍、事實

### 1.1 使用者決策(2026-10-18,不變)

| # | 決策 | 後果 |
|---|---|---|
| U1 | 開發期 608B 留空;app 與節點同步開發;焊上 608B / 換 HAT 時 provd 與 app **不重工** | keystore 介面 + `file`/`se` 後端(§4.2);`node_cert` 形狀兩後端相同 |
| U2 | 節點端 Go、手機 Flutter + Rust(flutter_rust_bridge)、GATT 走 BlueZ D-Bus | 協定兩份實作,以 `tests/vectors/219-protocol` + `verify.py` 當裁判(§9) |
| U3 | **擁有權與 SSH 脫鉤** | 認領不碰 `authorized_keys`、不改 dropbear 套件;SSH 公鑰由 app 另裝(§6.2);**legacy 認領多一道門(§6.1,B-M9)** |
| U4 | 階段 1 恢復出廠 = **全清**(含身分 → 新 QR) | §4.5 整段重寫;明寫為無 608B 的限制 |
| U5 | 改名探針(02)授權,但執行被 harness 分類器擋 | §6.6 以「會換 IP + 重開」設計,**⚠️ 待使用者手動跑 `probe` 定案** |
| U6 | 3A+ 等新板 | L13 ❌;**兩板共用檔(`batman-slot`、`batman-config-save`、`96`、`halow-setkey`、`batman-autocommit`、`joinwatch`)的改動在 bcm2710 上未測,列殘項** |
| U7 | `distroconfig` 的 `uart_enable=1` typo **不動**(記憶 2026-10-18) | §4.6 |

### 1.2 Reality check(全部唯讀;v1 R1–R17、v2 R18–R37 之外新增 / 修正;2026-10-19)

| # | 事實 | 證據 |
|---|---|---|
| R38 | **spike build 在 04:serdev 綁定** `/sys/bus/serial/devices/serial0`、`serial0-0`;`/sys/class/tty` 只有 `ttyAMA0`、`ttyAMA5`(**無 ttyS0**);`lsmod` BT 子集恰好 `bluetooth`、`btbcm`、`hci_uart`;`/proc/config.gz`:`CONFIG_BT=m`、`# CONFIG_BT_BREDR is not set`、`CONFIG_BT_LE=y`、`CONFIG_BT_HCIUART_BCM=y`、**`CONFIG_SERIAL_DEV_CTRL_TTYPORT=y`** | 04 本次 session(B2-B1 已收) |
| R39 | spike 套件:`opkg` 只有 `batman-ble 0.1.0-r1`、`bluez-daemon 5.72-r3`、`bluez-libs 5.72-r3`、`brcm-bt-firmware-4345c0`、`kmod-batman-bt`;無 `bluez-utils*`、無 `kmod-bluetooth`;`/etc/dbus-1/system.d/` = `avahi-dbus.conf`、`bluetooth.conf`(自己的,root-only policy,含 `send_interface` 白名單 Agent1/GattCharacteristic1/GattDescriptor1/LEAdvertisement1/ObjectManager/Properties);init `START=61 STOP=20`、`respawn 3600 5 0`、plugin 清單 `hostname,autopair,battery,neard,sap`(a5e181b7,**policy 留著**,未重 build 的 build 仍關 policy) | 04 + firmware `feat/254-ble`(B2-M7、A2-m1、B2-m6 已收) |
| R40 | **spike 抓到:`--noplugin=policy` 殺掉 `AutoEnable`**(AutoEnable 是 policy plugin 實作);**bluetoothctl 自己註冊 agent → 它在跑時 `Pairable` 變 yes**;無 agent 時 `Pairable: no / Discoverable: no`;iPad(nRF Connect)連線讀 GATT 不跳配對、`Paired: no / Bonded: no`;dbus 負測試:uid 65534 `bluetoothctl list` → `No default controller available` + dbus-daemon `Rejected send message` | #254 留言 6251617876 |
| R41 | **`/boot` 永遠掛 p1;slot B 時韌體讀 p3 的 `distroconfig.txt`**。04 的 p1 與 p3 現在都有 `[pi4] core_freq_min=500` + `dtoverlay=miniuart-bt`;10 分鐘閒置 40/40 取樣 core = 500 MHz、`throttled=0x0`;iPad 連線 6 分鐘不斷。**02 的 p1/p3 都沒加、02 未升級到 BLE build**。04 p1 是舊版 distroconfig(`arm_boost`=0) | #254 留言 6255818833;04 本次 `mount -o ro /dev/mmcblk0p3` 比對(A2-M7/B2-M4/B2-m13) |
| R42 | RSSI:iPad 與 04 室內 5–10 m 看到 −82 ~ −95 dBm(一般 BLE 裝置同距離約 −60 ~ −75),仍可連線;Pi 4 內建天線被 WM1302 HAT 蓋住 | 使用者回報,#254 留言 6255842632 |
| R43 | **本槽 overlay 版面**:`/dev/loop0 /overlay f2fs`(loop 在 rootfs 分割 p4 的 squashfs 之後)、`overlayfs:/overlay / overlay`;`/overlay/.fs_state -> 2`。fstools `2024.07.14~408c2cc4-r1`;`/sbin/jffs2reset`、`/sbin/firstboot`(= `jffs2reset $@`)、`/sbin/mount_root` 都在;`jffs2reset </dev/null` 在 04 **走到提示** `This will erase all settings … [N/y]` 後 rc=255(找得到 `rootfs_data` volume;字串 `%s is mounted as %s, only erasing files` / `overlay_delete`) | 04 本次(B2-B2 的「先探針」) |
| R44 | **`batman-slot` 既有函式**:`invalidate_slot()`(`:381-386`,cmdline 指向不存在的 PARTUUID + `BATMAN-BAD` 標記)、`clear_root()`(`:614`,把目標 rootfs 分割前 `ZERO_MB` MiB 清零 = 殺掉 squashfs 與 overlay 的 f2fs superblock)、`tboot_open/close()`(`:409-417`,p1 時重用 `/boot` 掛載)、`is_trial()`(`:711-717`);**沒有** `invalidate-other` 動詞(usage `:809`) | 原始碼(A2-B1 步 5 / B2-M10) |
| R45 | **`halow-setkey` 只有 `--mesh/--ap/--mesh-id/--channel/--status`**(`:25`);`:55` 拒絕 placeholder 當 key;`:101` `wifi reload`;`:134` 等 `mesh_netdev` ≤ 20 s;`:147` 成功後**無條件** `batman-config-save --save` | 原始碼(A2-B1 步 2 / A2-M9 / B2-M8 / B2-M10) |
| R46 | `batman-config-save`:`--save` 是 first-seed 路徑(`:287-288`,未 seed 的 ext4 p5 也寫、寫 `.seeded`);`:351-352` STAGE 永遠是自己 `$MNT/.stage.$$`,**沒有任何讀 `/etc/batman-prov/.stage/` 的程式**(v2 §4.4 步驟 3 是新增要求,v3 撤回);鎖接管規則 `:115-122`(持有者 cmdline 不含 `batman-config-save` 就接管 → helper 持鎖無效);`--check` rc:0 fresh / 5 stale / 7 unseeded / 8 lock-busy / 3 bypass / 1 mount;`mark_mesh_expected()` `:356-362` 只在 `--seed`/`--on-join` | 原始�碼(A2-M1 / B2-M1 / A2-m8) |
| R47 | `96`:5 個早退點 `:63`(bypass,exit 1 留著)、`:67`(無 p5)、`:71`(非 ext4 magic)、`:89-91`(mount 失敗)、`:93`(未 seed)都 `exit 0` → `uci_apply_defaults` 刪檔,**之後 fresh 開機前不再跑**;4b `:161-176` 以 `has_key && has_pw` 推導 LOCKED/UNPROVISIONED、`/etc/batman-dev-open` → DEV-OPEN;`:159` 註解把「factory-reset」定義為 overlay wipe | 原始碼(B2-M3 / A2-M3 / A2-m2) |
| R48 | `batman-autocommit`:`expected_in_mesh()` `:388-396`(p6 `mesh-joined`/`mesh-expected` → 1;否則 p5 `.seeded`;讀不到 → 1 fail-closed);`health_ok()` `:421-456`(p6 掛載、mesh11sd/openmanetd/wpad、undervoltage、`/etc/batman-build`、docker canary、payload drift);`autocommit-hold-once` `:97-100`(p6,消耗一次 = 不 revert);poll 迴圈 `:460-470`(NEED_MESH=1 時 `meshjoin_reachable` ≥ JOIN_NEED 筆) | 原始碼(A2-B2 / B2-B3 / B2-M4 / B2-M5) |
| R49 | 04 p6 `state/`:`lock-status`(0644,UNPROVISIONED)、`mesh-expected`(`seeded --on-join`)、`mesh-joined`、`slot-A.protected`、`slot-B.protected`;`/opt/batdata/apps/` = `goatak-rc`、`opentakserver`;`/etc/init.d/batman-payload-opentakserver`(guardian stub `START=99 STOP=09`)、`/etc/init.d/dockerd`;`payload-teardown <tenant> [--zeroize]` 存在(停 guardian、刪容器/fw4/網路/arbiter;`--zeroize` 連 volume 與 tenant dir);`/opt/batdata/docker` 是 p6 的 bind mount(docker data-root) | 04 本次 + 原始碼(A2-B1 步 4 / B2-B2) |
| R50 | 04:`/etc/dropbear/` 只有兩把 host key、**無 `authorized_keys`**、`PasswordAuth=on`、無 `/etc/batman-dev-open`;02:一行 lab `ssh-ed25519`、無 dev-open。兩台 `date` 皆假(04 = 2025-07-15,#174) | 兩台本次(B2-M9) |
| R51 | 節點**無 `dbus-send`**;`bluetoothctl` 有 `--timeout`(非互動)但會註冊 agent(R40)→ root 的健康探測不能用 bluetoothctl | 04 本次(A2-M7(c) / B2-m15) |
| R52 | `joinwatch:48` `MESHMARK=/opt/batdata/state/mesh-joined`;`:145` JOINED 時每 tick `batman-config-save --on-join` | 原始碼 |
| R53 | fstools `jffs2reset` 的訊息走 ulog → syslog(`logread` 有 `daemon.warn jffs2reset: This will erase …`) | 04 本次 |

### 1.3 與上層設計不同處(以本文件為準;→ `219-protocol.md` v0.7 / `219-field-provisioning.md` v2.9)

| 上層 | 本文件 | 理由 |
|---|---|---|
| 219 §6.1 步驟 5:認領寫 `authorized_keys` | **不寫**。認領只關密碔登入、設隨機 root 密碼、`lock-status=LOCKED`;SSH 公鑰由 `settings/ssh_keys` 另裝(ed25519) | U3 + R18 |
| 219 §6.3「p5 schema 升到 2」 | `schema_version` 維持 1;prov 狀態在 `prov.cbor`(自帶 `v`)+ sidecar `prov.meta` | `96:131` schema>1 丟 overrides 改 lkg |
| 219 §7 恢復出廠保留出廠身分、重置後要按鍵才開窗 | 階段 1 **全清**(新身分、新 QR);從未認領 = 窗口每次開機開 | U4;無 608B 做不到計數器 |
| 219 §6.9 autocommit 加 BLE 健康檢查放 S4 | 階段 1 就加,**但只在 p6 `ble-ok` 標記存在時 gating**(§6.4) | BLE 是唯一管理面;BT 壞的機台不能永遠不能 OTA(B2-M4) |
| 協定 §3.5 `auth/owner` 的標籤 `batman-owner-auth-v1` | 保留給 session 升級;**per-verb 授權用新標籤 `batman-owner-op-v1`**(`-dev` 版加後綴):`ES256_owner("batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ verb ‖ args_hash)` → 進 v0.7 §3.6 + CDDL + 向量 | 一個標籤一種格式(A2-M4) |
| 協定 §7.1「第 1 版由建立者自簽,節點記下」 | 節點「記下」第 1 版 = **需要擁有者的 `batman-owner-op-v1(verb=network/join, args_hash=H(net_config‖net_secrets))`** | A2-M5 |
| 協定 §5.4 `ClientChal` | 不變;但**由 helper 自己重算**(nonce 是 helper 發的、DAC 在 helper、`owner_pub` 用即將寫入的那把) | A2-B3 / B2-m2 |
| 協定 §3.3 `device_id` 未定公式 | **`device_id` = `sn`(9 B)的小寫 hex,18 字元**;adv 帶末 4 字元;進 `-dev` 向量 | B2-m9 |
| 協定 §10 共用 Rust 函式庫 | 節點 Go、app Rust,向量 + 對手實作當裁判 | U2 |
| v1 Q1 內建開發 CA | **自簽** `node.cert`(dev CN 前綴、效期 2020→2120)+ app 認領時 **TOFU pin**;release app 拒 dev 前綴 | 公開 repo 的 CA 私鑰 = 假信任根;時鐘差 15 個月 |

### 1.4 狀態機(節點)

**狀態只由 `/etc/batman-prov/prov.cbor` 的 `state` 欄決定**(persist 在 p5);`unknown` 不是狀態,是 helper 這次開機讀不到可信 prov 的**判決**。

```
            (升級後第一次開機:p5 seeded 無 prov → helper 建 prov{state=legacy} 並 persist)
legacy ──(claim;需 CheckMac + legacy 門 §6.1)──▶ claimed ──(network/create|join;需 owner-op)──▶ member ──(network/leave;owner-op)──▶ claimed
                                                    │                                                 │
unclaimed ─(claim)─▶ claimed                         └──────────(factory reset §4.5)───────────────────┴──▶ [重開] unclaimed(新身分)
  ▲ (新卡:p5 可讀、無 identity/prov → helper 建身分 + prov{state=unclaimed} 並 persist)
unknown(判決):p5 這次開機讀不到 / prov.cbor 與 p5 都壞 / bypass → 只開 status/public + factory reset(SD 標記);不產生身分;AP 關;下次開機再試
```

| 狀態 | 定義(prov.cbor.state) | hook / helper 對 AP、dropbear、lock-status | autocommit NEED_MESH(§6.4) | 認領窗口 |
|---|---|---|---|---|
| `legacy` | 升級前已 seeded 的 fleet 節點(02/04) | **全部不動**(今天的 96 4b 規則照跑) | **今天的規則**(p6 marker / `.seeded`) | 開(需 legacy 門) |
| `unclaimed` | 新卡 | AP 關(placeholder);dropbear image 預設;LuCI 不開 | 0 | 每次開機開 |
| `claimed` | 有擁有者、無網路 | AP 關;鎖定(§6.2) | live mesh key ≠ placeholder(legacy 認領後)→ 今天的規則;否則 0 | 關 |
| `member` | 有網路 | AP 由網路設定決定;鎖定 | `radio`(wlh0 mesh point + mesh_id 對)**一律**;`joined`(看到鄰居)**只在更新前那次開機本來就 JOINED 時**(§6.4) | 關 |

## 2. 元件

```
手機 app ──BLE GATT── bluetoothd(精簡 BlueZ 5.72,LE only,無 agent,dbus root-only policy)──D-Bus── batman-provd(uid provd,ujail)
                                                                                                   │ /tmp/run/batman-prov/helper.sock(SEQPACKET,SO_PEERCRED)
                                                                                                   ▼
                                                                                           batman-provhelper(root,procd S89)
                                                                                             ├─ keystore:file(階段 1)| se(#255)
                                                                                             ├─ 授權:owner-op / admins 鏈 / CheckMac(helper 重算 ClientChal)(§4.1)
                                                                                             ├─ 交易式 state.apply(§4.4)
                                                                                             ├─ 開機:--boot(讀 p5 → 建/還原身分 → 判狀態 → 續做 factory reset)
                                                                                             ├─ 每 15 s:寫 $RUN/batman-prov.health(給 autocommit)
                                                                                             └─ 既有工具:halow-setkey(新 --ap-off/--mesh-off/--no-persist/--firstboot)
                                                                                                        batman-config-save(新 --prov-file/--prov-identity/--prov-get/--wipe-all)
                                                                                                        batman-slot(新 invalidate-other;apply 記 ota-armed.mesh)
                                                                                                        payload-teardown --zeroize、jffs2reset -y
p5:prov.cbor + prov.meta + identity/prov/  ←(唯一寫者 batman-config-save,檔由 helper 明示參數交付)←  /etc/batman-prov/(root 0700)
99zz-batman-prov-state(uci-defaults,S10):fresh overlay 時 `batman-provhelper --apply-state --boot`(只 uci set + MARK + lock-status + prov-state;不 reload、不 persist)
```

同一個 Go 二進位,argv[0] 決定模式;協定核心(Noise `flynn/noise`、CBOR `fxamacker/cbor` core-deterministic、COSE 自寫最小集合 ES256/HKDF/AES-GCM/ChaCha20-Poly1305)只有一份。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| `hci0` 存在、BR/EDR off、Bondable off | kernel + bluetoothd(`main.conf`:`ControllerMode=le`、`AlwaysPairable=false`、無 agent) | provd 斷言 `Adapter1.Pairable==false`;helper 讀 `Powered` | R38/R40 |
| `hci0 Powered` | **bluetoothd `[Policy] AutoEnable=true`(policy plugin 必須留著)** | helper(D-Bus `Properties.Get`,不經 bluetoothctl) | R40/R51 |
| `/etc/bluetooth/main.conf`、`/etc/dbus-1/system.d/bluetooth.conf`、`/etc/init.d/bluetoothd` | image(`batman-ble`) | dbus-daemon、bluetoothd | R39 |
| `/etc/bluetooth/keys/`(IRK) | bluetoothd(init 建 0700,`/var/lib/bluetooth` symlink) | — | 在 overlay → 恢復出廠隨 overlay 一起清 |
| BLE 廣播、GATT 服務 | provd(D-Bus 註冊;**不註冊 agent**) | — | adv 不帶 Local Name;GAP Name 固定 `Batman` |
| `/dev/ttyS0` → serdev `serial0-0` | kernel `hci_uart`+`btbcm` | — | **無 tty 節點 = 無 userland 能碰** |
| `/tmp/run/batman-prov/`(root:provd 0750)、`helper.sock`(0660) | helper(`mkdirat`+`O_NOFOLLOW`、owner root、非 symlink) | provd | R30 |
| `$RUN/batman-prov.health`(root 0600;`<uptime> bluetoothd=<0|1> hci0_powered=<0|1> provd=<0|1> adv=<0|1>`) | helper 每 15 s | `batman-autocommit health_ok` | A2-M7(c)/B2-m15:不用 bluetoothctl |
| `/etc/batman-prov/identity/`:`node.key`、`ecdh.key`、`node.cert`、`claim.secret`、`backend`、`sn`、`sha256`(7 檔) | **helper 只在「p5 可讀 且 p5 無 `identity/prov/` 且非 bypass」時產生一次**(先產在 `.identity.tmp/` 再 `rename` 目錄);其他情況由 helper 從 p5 **還原**(fresh 時 96 也抄,見下) | — | §4.2;A2-M8/B2-M3 |
| `/etc/batman-prov/prov.cbor` + `prov.meta`(`<state> <generation> <sha256(prov.cbor)>`) | helper(tmp + rename + fsync,**只在 persist 成功後**;§4.4);fresh overlay 時 96 從 p5 抄(驗 meta);非 fresh 時 helper 依 §4.4 步驟 6 從 p5 重建 | hook(經 helper)、`96` 4b(讀 meta 的 state)、`--probe` | 單檔 → 無撕裂;`claimed_counter` 在 prov.cbor 內(A2-m6) |
| `/etc/batman-prov/.stage/` | helper | **只有 helper**;config-save 永不讀它 | A2-M1/B2-M1 |
| `/etc/.batman-prov-restore`(root 0600;`<verdict> <seeded=0|1> <prov=0|1>`,verdict ∈ `restored|unseeded|raw|p5-unavailable|too-new|bypass|no-p5`) | **96**(每個出口都寫,早退點也寫);helper 讀後**不刪**(只用來 log 與區分「96 這次跑過沒」) | helper | B2-M2/M3:**不是永久判決** |
| p5 `prov.cbor`、`prov.meta`、`identity/prov/*`、`.seeded`、`overrides.uci`、`lkg/` | `batman-config-save`(持鎖、驗 rw) | 96、`--check`、`--prov-get`、autocommit | `prov.cbor` 整檔換;`identity/prov/` 只在 p5 尚無時複製且 7 檔 + sha 齊全才抄;`--wipe-all` 唯一刪者 |
| `$ST/prov-state`(p6,root 0600;`<boot_id> <state> <members_n> <mesh_expect>`,`mesh_expect` ∈ `legacy|0|1|radio`) | helper(`--boot` 與每次 state 變更) | `batman-autocommit`、`halow-status` | boot_id 不符 = 當作無檔(B2-m4) |
| `$ST/ble-ok`(p6,`<boot_id> <uptime>`) | helper:**committed 槽**(`batman-slot is-trial` rc 1)第一次看到 `hci0 Powered` 時寫 | autocommit(有它才檢查 BLE) | B2-M4 |
| `$ST/ota-armed.mesh`(p6,`joined|radio|none`) | `batman-slot apply`(arm 成功時,以 `meshjoin.sh` 的 `meshjoin_reachable` 現場判定) | autocommit(member 時決定要不要看鄰居) | B2-M5;兩板共用檔,bcm2710 ❌ |
| `$ST/mesh-expected` | `batman-config-save`(`--seed`/`--on-join`,**不改**:legacy 照寫);helper 只在 `network/leave` 與恢復出廠**刪** | autocommit | A2-B2/B2-B3:不再「prov-state 存在就不寫」 |
| `$ST/mesh-joined` | joinwatch(不改);helper 只在 `network/leave` 與恢復出廠刪 | autocommit | A2-m12 |
| `$ST/factory-reset.inprogress`(p6,`<step> <device_id> <uptime>`) | helper(開始寫、每步更新、最後一步刪;每次 `--boot` 看到就續做) | — | §4.5;p6 清除時**唯一保留**的檔 |
| `lock-status`、`dropbear.PasswordAuth/RootPasswordAuth`、`system.ttylogin`、root shadow | **state ∈ {claimed, member}:helper 唯一寫者**(96 4b 看 `prov.meta` state 跳過);**legacy/unclaimed/無 prov:96 4b 今天的規則**,helper 不碰 | `halow-status` | A2-M3/B2-m16 |
| `/etc/dropbear/authorized_keys` | 操作員 / `settings/ssh_keys`(helper,只動行尾 `batman-prov:<key_id>` 的行);認領不碰 | 96、config-save | U3 |
| live uci `wireless.*`(mesh/AP key、channel、mesh_id、country) | 執行期:**只經 `halow-setkey`**(新 `--ap-off/--mesh-off/--no-persist`);**firstboot(S10)只經 `halow-setkey --firstboot`**(uci set + MARK,不 reload、不 persist) | provd | A2-M9/B2-M8 |
| `/etc/halow-keyguard.blocked`(MARK) | keyguard(S18)、halow-setkey | — | 不改邏輯 |
| `hostname`、`ahwlan.ipaddr` | 改名:helper(先 persist 再 `uci set` + `system reload`);openmanetd 之後重保留 IP 並重開(⚠️ U5) | | §6.6 |
| 另一槽(rootfs + boot FAT) | `batman-slot`(`apply`、新 `invalidate-other`) | — | §4.5 |
| 本槽 overlay(`/overlay` f2fs on loop0) | `jffs2reset -y`(fstools)只在恢復出廠步驟 7 | — | R43 |
| p6 `apps/`、`docker/`、容器 | payload guardian / dockerd(#274);恢復出廠時 `payload-teardown --zeroize` + `dockerd stop` 後 helper 清 | — | §4.5 |
| SD 標記檔 `batman-factory-reset`(**當前開機槽的 FAT** = `batman-slot fw-part $(batman-slot active)`,p1 或 p3) | 實體(root / 讀卡機)寫;helper 步驟 8 刪 | helper `--boot` | R41:不能用 `/boot` |
| 認領窗口、失敗計數、冪等鍵、session、`s_node` | provd 記憶體 | — | respawn 後消失 |
| `boot_id`、`nonce_node`、`nonce_helper` | helper 產生 | provd | 一次性,綁 session `h` |

## 4. 契約

### 4.1 helper socket 與授權模型

- `SOCK_SEQPACKET`,一包一則 CBOR map;`SO_PEERCRED` uid == provd 否則關;單連線序列化;請求 ≤ 64 KiB;逾時 30 s。
- **每個會改變節點的動詞都帶 helper 自己能驗、且 helper 自己重組被驗內容的授權物件;provd 只是搬運工,provd 給的任何「已算好的雜湊/挑戰」都不接受。**
- **trial 槽(`batman-slot is-trial` rc 0)**:所有改狀態的動詞回 `E_BUSY(updating)`;唯讀照常;身分產生照常(B2-m11)。

| 動詞 | 授權(helper 驗) | 效果 |
|---|---|---|
| `info.cert` / `info.ecdh_pub` / `info.counter` / `info.boot_id` / `info.state` | 無 | 唯讀 |
| `nonce(h)` | 無 | 發一次性 `nonce_node`(給 claim)或 `nonce_helper`(給 owner-op),綁 `h`,60 s |
| `sign.static(s_node_pub)`、`sign.ecdh_proof()`、`sign.peer(peer_nonce, peer_fields…)` | purpose 固定;**helper 依協定 §3.3/§3.6 自己組被簽內容,放入自己的 `boot_id`/`nonce_node`**,只接受對方欄位;全域 2/s | DAC 簽章(B2-m1) |
| `psks.get()` | 無 | 回 `{psk_owner[≤4], psk_member, adv_owner, adv_member}`(**只回 HKDF 導出值**,不回 `owner_tag_key`/`net_root`);prov.cbor 變更後 provd 重拉。**誠實界線**(協定 §6):provd 持有這些 = 能對這台冒充擁有者候選/成員 session;net_root 本體不出 helper |
| `claim.verify(h, client_resp, owner_pub, owner_enc_pub, sig_enc)` | helper 以**自己發給此 `h` 的 `nonce_node`**、自己的 DAC、**即將寫入的 `owner_pub`** 重算 `ClientChal`(協定 §5.4),`CheckMac` 常數時間;`sig_enc` 用同一把 `owner_pub` 驗;`legacy` 另需 §6.1 的門 | 原子:owner → `claimed_counter+1` → **persist** → rename → 鎖定(§6.2)→ `prov-state`;`legacy\|unclaimed → claimed` |
| `net.apply(net_config, net_secrets[, owner_op])` | `prov.cbor.net` **為空** → 必須帶 `owner_op(verb=network/join, args_hash=H(net_config‖net_secrets))`;否則用上一版 `admins` 驗鏈(版本 +1、不跳號);helper 用 `ecdh.key` 解 `net_secrets`(**明文 SAE key / net_root 不出 helper**) | `halow-setkey --mesh … --no-persist` → persist → `prov-state` |
| `owner_op(obj)` | `ES256_owner("batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ verb ‖ args_hash)`;`nonce_helper` 一次性、60 s、綁 `h`;verb ∈ `network/join`、`network/leave`、`owner/*`、`settings/*`、`ssh_keys`、`root_password`、`diag`、`reset` | 授權物件 |
| `state.apply(verb, args, owner_op)` | 依上表 | 交易式(§4.4) |
| `factory_reset(owner_op)` | owner-op **或** SD 標記檔(helper `--boot` 已讀到且 `device_id` 相符);committed 槽;**冷卻 60 s、期間可取消** | §4.5 |
| `root_password.reset(owner_op)` | owner-op | 新隨機 24 字元寫 shadow + persist,回傳一次(A2-m11) |
| `diag.bundle(owner_op)` | owner-op | helper 的 `batman_tmp` 檔,O_RDONLY fd,讀完刪 |
| `ssh_keys.set(list, owner_op)` | owner-op;每行 `^ssh-ed25519 [A-Za-z0-9+/=]+( [^\n]*)?$`、單行、≤ 256 B、≤ 8 行 | 只動帶 `batman-prov:` 標記的行 |

- **刪除**(相對 v2):`keystore.ecdh`(A2-M6/B2-M6:解密 oracle、無合法消費者)、`persist`(A2-m7/B2-m3:lkg 升級只由 helper 內部在 `meshjoin_joined` 後做)、`keystore.sign(purpose,msg)`(整段 msg 由 provd 給)。
- 不認得的動詞 / 多餘欄位 / 長度超限 → `E_SCHEMA`;授權失敗 → `E_FORBIDDEN`;trial → `E_BUSY`。
- **負測試**(每條都要「關掉檢查就過」的對照):provd uid 直接送 `factory_reset` 無 auth → `E_FORBIDDEN`;`net.apply` 帶錯簽章 → `E_FORBIDDEN`;`net.apply` 第 1 版自簽無 owner_op → `E_FORBIDDEN`;**`claim.verify` 送 `(h, resp_買家, owner_pub_攻擊者)` → `E_FORBIDDEN`(v2 介面會寫入攻擊者)**;`keystore.ecdh`/`persist` → `E_SCHEMA`;trial 槽上 `claim.verify` → `E_BUSY`。

### 4.2 keystore 介面與 `file` 後端

```go
type Keystore interface {
    SN() [9]byte; DeviceID() string            // file: sn = SHA-256(node_pub)[:9]; device_id = hex(sn) 18 chars; se: 晶片序號
    Cert() []byte                               // node_cert DER,鏈 [leaf](file 自簽) / [leaf, mfr-CA](se)
    SignPurpose(purpose string, nodeNonce, peerFields []byte) ([]byte, error) // helper 組訊息;不簽裸值
    ECDHPub() []byte; ECDH(peerPub []byte) ([]byte, error) // 只在 helper 內部 net.apply 用
    CheckMac(clientChal, clientResp [32]byte) error        // 常數時間;秘密不出 keystore
    Backend() string                                       // "file" | "se"
}
```
`claimed_counter` 不在 keystore(file 後端做不到跨 wipe 單調;608B 才有)→ 放 `prov.cbor`,恢復出廠歸零(U4 誠實限制)。

| `file` 後端檔(`/etc/batman-prov/identity/`,目錄 0700) | 格式 | 權限 |
|---|---|---|
| `node.key` / `ecdh.key` | P-256 PKCS#8 DER | 0600 |
| `node.cert` | 自簽 X.509:`CN=dev:<device_id>`、`serialNumber=<sn hex>`、2020-01-01 → 2120-01-01、EKU 自訂 OID(dev) | 0644 |
| `claim.secret` | 32 B | 0600 |
| `backend` | `file` | 0644 |
| `sn` | 9 B | 0644 |
| `sha256` | 上面 6 檔的 `sha256sum` 清單 | 0644 |

- **產生條件(唯一)**:`--boot` 時 `batman-config-save --prov-get <dir>` 回 rc 0(p5 可讀、已 seed)或 rc 7(未 seed)**且** p5 無 `identity/prov/` **且**非 bypass。先產在 `.identity.tmp/` 寫滿 7 檔 → `rename` 成 `identity/` → `--save --prov-identity identity/ --prov-file prov.cbor`(config-save 驗 7 檔 + sha 才抄)。
- p5 有 `identity/prov/` 而 overlay 沒有(非 fresh 開機、overlay 被清/壞)→ helper 從 `--prov-get` 的副本**還原**(A2-m4)。
- p5 不可讀(rc 1/8 三次)→ `unknown`:不產生、不還原、`halow-status` 紅字 `prov: p5 unreadable`;**下次開機再試**(B2-M3)。
- bypass → `unknown`;`persist` 一律拒。
- `se` 後端(#255):同介面;`backend=se` 而 608B 不回應 → helper 拒絕啟動。**焊上 608B = 新身分、新 QR、重新認領**。
- app:鏈長 1 且 CN `dev:` → TOFU pin,畫面標「開發機」;release build 拒絕。
- 開發期 QR:`batman-provhelper qr`(root;印 `device_id` + `claim.secret`);**`claimed|member` 拒絕;`legacy` 只在 `/etc/batman-dev-open` 存在或 stdin 是 tty 時執行**(B2-M9);stdout 不進任何 log(B2-m12)。

### 4.3 p5 版面與 `batman-config-save` 改動(PR-P1,兩板共用檔)

```
p5/
  schema_version = 1            (不變)
  .seeded, overrides.uci, lkg/   (不變)
  identity/dropbear/*, shadow-root (不變)
  identity/prov/{node.key,ecdh.key,node.cert,claim.secret,backend,sn,sha256}   (一次寫入;7 檔 + sha 齊全才抄)
  prov.cbor                     ({v:1, generation:n, state, claimed_counter, owner{pub,enc_pub,tag_key,adv_key}, admins[], net{config COSE, secrets COSE}, members COSE, ssh_keys[]})
  prov.meta                     ("<state> <generation> <sha256(prov.cbor)>" 文字;給 96/shell 用)
```

| 新/改 | 內容 |
|---|---|
| `--save --prov-file <f> --prov-meta <m> [--prov-identity <dir>]` | **只有這個明示參數**會把 prov 檔寫進 p5(stage 到 `$MNT/.stage.$$` → `mv`);驗 `<m>` 的 sha == sha256(`<f>`)、regular file、≤ 64 KiB、0600;`--prov-identity` 只在 p5 尚無 `identity/prov/` 時抄,驗 7 檔 + `sha256` 清單。**`--on-join`/`--check`/`--seed`/操作員 `--save` 永遠只看已提交的 `/etc/batman-prov/prov.cbor`+`prov.meta`**(納入 fp / same_identity / `--check`),從不讀 `.stage/`(A2-M1/B2-M1) |
| `--prov-get <dir>` | 新唯讀模式(ro,noload 掛載;鎖等待同 `--check`):把 p5 的 `prov.cbor`、`prov.meta`、`identity/prov/` 抄到 `<dir>`(root 0700);rc 0 有 prov / 7 未 seed / 9 seeded 無 prov / 1 mount / 8 lock-busy / 3 bypass;抄前驗 meta sha 與 identity sha,不符 → rc 10 `prov-corrupt`(不抄) |
| `--wipe-all` | 刪 `prov.cbor`、`prov.meta`、`identity/`(含 dropbear、prov)、`shadow-root`、`overrides.uci`、`lkg/`、`schema_version`、`.seeded`;**不 mkfs**;只有 helper 呼叫 |
| `onjoin_fp()`、`same_identity()`、`--check` | 納入 `prov.cbor`、`prov.meta`、`identity/prov/` 的 sha(已提交的那份) |
| `mark_mesh_expected()` | **不改**(legacy 必須照今天寫,A2-B2/B2-B3) |
| `seed_key_ok()` | **不改**;helper 只用 `--save`(從不 `--seed`,A2-m8) |
| `--seed` 旋轉 lkg | 不改(v2 B-M10 的「不再旋轉」撤回:`--seed` 是基線,`:385-388` 註解已是契約) |
| 互斥 | helper **不持鎖**(接管規則 R46);互斥 = helper 的 persist 本身就是一次 config-save 取鎖;`--on-join` 任一時刻讀到的 prov 是舊或新完整檔(單檔 rename) |

`96` 改動(PR-P1):
- 每個出口寫 `/etc/.batman-prov-restore`(R47 五個早退點各自 verdict:`bypass`、`no-p5`、`raw`(前 4 KiB 全零)/`p5-unavailable`(非 ext4 magic 且非全零,A2-m5)、`p5-unavailable`(mount 失敗)、`unseeded`;正常 → `restored`)。
- Lane A 之後:p5 有 `prov.meta` 且 sha 對、`prov.cbor` regular ≤ 64 KiB → 抄 `prov.cbor`+`prov.meta`(0600)、抄 `identity/prov/`(驗 sha 清單;只 regular file、0600/0644)。`v` 太新(meta 第一欄之後加 `v`)→ 不抄、verdict `too-new`。
- 4b:**`prov.meta` state ∈ {claimed, member} → 跳過 4b**(log `lockdown: deferred to batman-provhelper (state=…)`),helper 的 `--apply-state --boot` 是唯一寫者;否則今天的規則(A2-M3)。
- 單元測試:96 對 7 種 verdict × 有/無 prov × 4 種 state 的輸出(marker、抄了什麼、lock-status 寫沒寫)。

### 4.4 交易式 `state.apply`

1. helper 在 `/etc/batman-prov/.stage/` 組新 `prov.cbor`(generation+1)+ `prov.meta`。
2. 套用**可失敗的**副作用:`halow-setkey … --no-persist`(wifi reload、讀回)。失敗 → 回滾(反向 setkey `--no-persist`)、刪 stage、`E_APPLY`。
3. `batman-config-save --save --prov-file .stage/prov.cbor --prov-meta .stage/prov.meta`。rc ≠ 0 → 回滾步驟 2、刪 stage、`E_PERSIST(rc)`;app「存不進卡」。**此刻 p5 = generation n+1,overlay 仍 n。**
4. `rename(.stage/prov.cbor → prov.cbor)`、`rename(prov.meta)`、fsync。
5. **不可失敗的**副作用(dropbear uci / ttylogin / lock-status / shadow)**在 persist 之後**才做(A2-M2),接著 `--save`(無 prov 參數,只為把 shadow-root 帶到 p5)、寫 `$ST/prov-state`。
6. 開機 `--boot`(每次,不只 fresh):`--prov-get` → 比 p5 `prov.meta.generation` 與 overlay 的:p5 新 **或** overlay 的 prov 壞/缺 → 以 p5 副本重建 overlay(prov.cbor、prov.meta、identity/prov、dropbear identity、shadow-root 由 96 既有 Lane A 負責)→ `--apply-state`;相等 → 不動;overlay 新(不可能,除非 p5 被外力回退)→ log + 以 p5 為準。`.stage/` 殘留 → 一律丟棄(交易沒走到步驟 3 就等於沒發生;走到了則 p5 較新,上面已涵蓋)。
7. `--apply-state` 冪等:依 `prov.cbor.state` 重設 AP(經 `halow-setkey --ap-off/--ap …`)、dropbear/ttylogin/lock-status、shadow(**只在 state ∈ {claimed,member} 且 shadow 無 hash 時**設一把新隨機密碼並 log `root password regenerated — owner must reset it via app`;legacy/unclaimed **不碰 shadow**,PasswordAuth 回 image 預設)。`--boot` 變體(S10 用):只 uci set + MARK、不 reload、不 persist(A2-M9/B2-M8)。
8. 非 fresh 開機 p5 掛不起(`--prov-get` rc 1/8 三次):**沿用 overlay 的 prov**(可用性),`persist` 一律 `E_PERSIST`,`halow-status` 紅字;下次開機再試(B2-m14)。

### 4.5 `halow-setkey` 新旗標、恢復出廠、SD 標記檔

**`halow-setkey`(兩板共用檔)**:
- `--ap-off`:AP key = placeholder + `disabled=1` + MARK 加入該 iface;`--mesh-off`:mesh key = placeholder + radio `disabled=1` + MARK(兩者**繞過** `:55` 的 placeholder 拒絕,因為是明示的 off 動詞);`--ap <key>` / `--mesh <key>` 反向(既有)。
- `--no-persist`:成功後**不**跑 `batman-config-save --save`(只給 helper 交易用,R45 `:147`)。
- `--firstboot`:只 `uci set` + MARK + `uci commit`;不 `wifi reload`、不等讀回、不 persist(S10 hook 用)。
- `--status` 不變。

**恢復出廠(U4;219 §7 的範圍與順序)** — 前置:committed 槽(`is-trial` rc 1,否則 `E_TRIAL`,app 文案「更新完成後再試」)、非 bypass、owner-op **或** SD 標記檔。步驟寫在 p6 `$ST/factory-reset.inprogress`(`<step> <device_id> <uptime>`),每步**冪等**,`--boot` 看到就從該步續做(續做時 provd 不開 socket、不廣播,直到完成):

| 步 | 動作 | 工具(都已存在,R43/R44/R49) | 斷電後續做 |
|---|---|---|---|
| 1 | 寫 marker step=1;provd 關窗口、斷連線 | — | 從 1 |
| 2 | `halow-setkey --mesh-off --ap-off --no-persist`(radio 先下,節點離網) | R45 | 冪等 |
| 3 | 每個 `/opt/batdata/apps/<t>/` → `payload-teardown <t> --zeroize`;`/etc/init.d/dockerd stop`;`rm -rf /opt/batdata/docker/*` | R49(**#274 的擁有者規則:先停 guardian 再碰 p6**) | 冪等(無 tenant 時 no-op) |
| 4 | p6:刪 `/opt/batdata/*` **除** `state/factory-reset.inprogress` 與 `lost+found`(含 `state/lock-status`、`mesh-*`、`prov-state`、`ble-ok`、`ota-armed.mesh`、`slot-*.protected`、`autocommit-*`、`log/`、`crash/`、`apps/`、`docker/`) | — | 冪等 |
| 5 | `batman-config-save --wipe-all`(p5) | §4.3 | 冪等 |
| 6 | `batman-slot invalidate-other`(**新動詞**:`is_trial` → 拒絕;對另一槽 `tboot_open` + `invalidate_slot "$T" … "factory-reset"` + `clear_root`(清零 squashfs+overlay 視窗)+ `tboot_close`;`otalog_k SLOT INVALIDATE-OTHER`) | R44 | 冪等 |
| 7 | 寫 marker step=7 → `jffs2reset -y`(fstools `overlay_delete` 刪 `/overlay` 下全部,含 `upper/`、`work/`、`.fs_state`;**之後不得再寫 overlay**) | R43 | 若在此之後斷電:下次是 fresh overlay,從 8 續 |
| 8 | 刪 SD 標記檔(當前開機槽 FAT:`batman-slot fw-part $(batman-slot active)`;p1 = `/boot`,p3 要 rw 掛);刪不掉 → log,繼續 | R41/R44 | 冪等 |
| 9 | `sync; reboot`(走正常 shutdown;K10batdata-mount 會在 p6 `log/` 留一份 shutdown log → 由下一步清) | — | — |
| 10 | 下次開機(fresh overlay):96 看 p5 未 seed → `unseeded`;99 重新個人化(新 hostname/IP/host key);helper `--boot` 看到 marker step≥7 → 刪 p6 `log/*`、`crash/*` → **刪 marker** → 再走正常 `--boot`:p5 可讀、無 identity → 產新身分 → `prov{state=unclaimed}` persist → 窗口開 | — | 完成 |

- **結果斷言**(L16 測試):重開後 `info.state=unclaimed`、`device_id` 變了、舊 `claim.secret` 無效、`/etc/dropbear/authorized_keys` 不存在、`grep ^root: /etc/shadow` = image 預設(空)、`uci get system.@system[0].hostname` 是新的、p6 無 `prov-state`/`lock-status`/`apps/`、另一槽 `BATMAN-BAD`、`/etc/bluetooth/keys/` 空(新 IRK)、舊 SSH 金鑰 `ssh -i` 被拒。**負對照**:在 v2 的流程(只 `--wipe-all` + 清 `/etc/batman-prov` + reboot)上同一組斷言:hostname/shadow/authorized_keys/apps **都沒變**(B2-B2 要求的對照)。
- 斷電點測試:步驟 4 後(p6 清了、p5 還在)、步驟 5 後(p5 清了、overlay 還在)、步驟 7 後(overlay 清了、marker 在)。三者重開後最終斷言都要成立。
- **誠實界線**:p5/p6/overlay 明文,清除是 unlink/清零,不是安全擦除(219 §7);**恢復出廠會清掉 p6 上的 docker image 與 tenant 資料 = 出廠裸機**(#159 own-image bake 未做),04 這類 OTS 節點做破壞性測試前要先列副作用與還原步驟(記憶 feedback_destructive_test_side_effects)→ L16 在 **02** 上做,不在 04。
- **SD 標記檔契約**:檔名 `batman-factory-reset`,內容第一行 = 本機 `device_id`(QR 上的)或 `any`(只在 `batman-dev-open` 存在時接受);位置 = 當前開機槽的 FAT(**不是 `/boot`**,R41);只有 root / 實體可寫(p1 `fmask=0022`);trial 槽 → 不執行、不刪,每次開機重試直到 committed;完成後若標記仍在(FAT 刪不掉)且 p5 未 seed、state=unclaimed → 忽略並 log 一次(避免重置迴圈,B2-m5);`device_id` 不符 → 忽略並 log(卡片搬到別台)。

### 4.6 BLE 平台(**spike 實測,R38–R42**)

| 項 | 定案(= `feat/254-ble` a5e181b7,**init 修正尚未重 build**) |
|---|---|
| kernel | `kmod-batman-bt`:`CONFIG_BT=m`、`BT_BREDR=n`、`BT_LE=y`、`BT_HCIUART=m`、`BT_HCIUART_SERDEV=y`、`BT_HCIUART_BCM=y`、`BT_HCIUART_H4=y`、RFCOMM/BNEP/HIDP/btusb/btsdio 全 n;**kernel 內建 bool `CONFIG_SERIAL_DEV_CTRL_TTYPORT=y`(改 `kernel8.img`,OTA 帶得到)**;FILES = `bluetooth.ko`、`btbcm.ko`、`hci_uart.ko`;`ble_diffconfig` deselect `kmod-bluetooth`、`kmod-bluetooth-6lowpan`、`bluez-utils*`、`kmod-ath3k`、`ar3k-firmware`(B2-B1/M7 已收;04 實證 R38/R39) |
| 韌體 | `brcm-bt-firmware-4345c0`:`/lib/firmware/brcm/BCM4345C0.hcd`(63806 B,sha256 51c45e77…,RPi-Distro/bluez-firmware pios/trixie blob 007611e)+ `LICENSE.cypress` |
| BlueZ | board patch 0012:`bluez-daemon` = bluetoothd + bluetoothctl;不裝 obexd/hciattach/rfcomm/gatttool/sdptool/上游 main.conf/dbus policy/init;`bluez-libs` 依賴 `kmod-batman-bt` |
| `main.conf`(`batman-ble`) | `Name=Batman`、`ControllerMode=le`、`AlwaysPairable=false`、`PairableTimeout=0`、`DiscoverableTimeout=0`、`JustWorksRepairing=never`、`Privacy=device`、`NameResolving=false`、`[GATT] Cache=no`、`[Policy] AutoEnable=true`;**不裝 agent**(真防線,R40);provd 開機斷言 `Pairable==false && Discoverable==false` |
| dbus policy | 自己的 `bluetooth.conf`(R39):只有 `<policy user="root">`(own/send org.bluez + 6 個 `send_interface`),**無 default policy**;PR-P2 加 `<policy user="provd">` 同一組 allow(A2-m1 已含 send_interface) |
| init | `START=61 STOP=20`、`respawn 3600 5 0`、**`--noplugin=hostname,autopair,battery,neard,sap`(policy 留著)**;無 hci0 時照跑等熱插拔(B2-m7) |
| distroconfig | `[pi4] core_freq_min=500`(樹上已有);**02/04 要手動改 p1 與 p3 兩份**(04 ✅ 已改並驗;02 ❌);`uart_enable=1` typo 不動(U7);重燒用 `feat/254-ble` 的 `ekh01/distroconfig.txt`(B2-m13) |
| 耗電 | `core_freq_min=500` 固定 VPU 500 MHz → 電池機耗電待量(殘項) |
| 3A+ | `[pi3]` `disable-bt` → `miniuart-bt` + `core_freq_min=?`(待板) |
| 待量 | AP 吞吐 vs BLE 共存(`prov-coex-254`);遮蔽/外殼對 RSSI(殘項) |

### 4.7 procd / ujail

| 服務 | START / STOP | 說明 |
|---|---|---|
| dbus | 60(既有) | |
| bluetoothd | 61 / K20 | R39 |
| batman-provhelper | 89 / K15 | `--boot`:讀 restore marker(log)、`--prov-get`、factory marker 續做、身分產生/還原、§4.4 步驟 6、寫 `prov-state`、建 socket dir;之後每 15 s 寫 `batman-prov.health`、committed 槽首次 `Powered` 寫 `ble-ok` |
| batman-provd | 92 / **K10** | ujail:uid/gid `provd`、`no-new-privs`、capabilities 空、唯讀 `/`、只掛 `/tmp/run/batman-prov`、`/tmp/run/dbus/system_bus_socket`;`respawn 3600 5 0` + 自己退避(B2-m6);OTA stage-2 ramfs 時已被 K10 停掉 |

### 4.8 GATT / 廣播(對 app)

照 `219-protocol.md` §4.1;MTU 協商、分段、序號;單則 ≤ 8 KiB,上限經 `CTRL/info` 回報;未交握只 `status/public`(格式版本、能力位元、**`legacy|unclaimed` 時才帶 `device_id` 末 4 字元**);adv **不帶 Local Name**(B2-m8);同時連線 ≤ 2;未交握 10 s;失敗 3 次/連線;**trial 槽時 `status/public` 帶 `updating=1`**。

## 5. 生命週期矩陣

| # | 路徑 | 今天(1.5.12) | 階段 1 後 | 測試(負對照) |
|---|---|---|---|---|
| L1 | first boot,新卡 p5 ext4 未 seed | 96 `:93` exit;AP placeholder → keyguard 關;root 空密碼、PasswordAuth on | 96 verdict=`unseeded`;helper `--prov-get` rc 7、無 identity → 產身分 → `prov{unclaimed}` persist(`--save` 首次 seed p5)→ 窗口開;AP 關;dropbear image 預設 | `prov-firstboot-254`:`status/public` 可讀、`hci0` up、AP 關、`identity/` 0700、p5 有 `identity/prov/` 7 檔(負:verdict=`p5-unavailable` 時不得產生) |
| L2 | boot(member,非 fresh) | — | helper `--prov-get` → generation 相等 → `--apply-state`(冪等)→ `prov-state` → provd 廣播成員摘要 | `prov-boot-254` ×3:generation 不變、SSH 依 §6.2、prov-state boot_id 是本次 |
| L3 | clean shutdown | — | 無待存狀態;provd K10 先停 | boot-reasons 乾淨 |
| L4 | reboot | 同 L2 | 同 L2 | 同 L2 |
| L5 | OTA 到含本功能的 image(fresh overlay) | 96 還原 identity + overrides | + 96 抄 `prov.cbor/meta/identity/prov`(驗 sha);`--check` 含 prov → stale 擋 OTA;**前置:p1 與 p3 的 `core_freq_min`(R41)** | `prov-ota-254`:claim+join → OTA → 新槽 member、generation 同、AP 同(負:1.5.12 的 `--check` 看不到 prov 差異) |
| L6 | autocommit commit/revert | `.seeded`/marker → NEED_MESH=1;health = 服務 | §6.4 三條規則 | `prov-autocommit-254`(§6.4 四個案例) |
| L7 | 斷電 / helper 死在 `state.apply` 中途 | — | 步驟 3 前:什麼都沒變;3–4 之間:p5 新 → 開機重建(§4.4 步驟 6);步驟 5 前:鎖未做 → `--apply-state` 補做(shadow 無 hash → 新隨機 + log);**04 空密碼在認領失敗時保持可登入**(A2-M2) | `prov-powerloss-254`(fi:步驟 2 後 / 3 後 / 4 後 `reboot -f`;斷言 04 在前兩點重開後仍可空密碼登入) |
| L8 | provd crash loop | — | 無限 respawn + 退避;交握/冪等鍵丟失(app 用 generation 判) | `prov-respawn-254` |
| L9 | bluetoothd 重啟 / 無 hci0 | — | provd `NameOwnerChanged` 重註冊;無 hci0 → health 檔 `hci0_powered=0`、`halow-status` WARN | `prov-bluez-restart-254` |
| L10 | dbus 重啟 | — | 兩者 respawn | 同 L9 |
| L11 | helper 重啟 | — | provd 重連;期間 `busy` | `prov-helper-restart-254` |
| L12 | **downgrade** 到 1.5.12 | — | 舊 96:overrides + dropbear identity + shadow;LOCKED 若 authorized_keys 有行;AP 真 key 開 / placeholder 關;無 BLE。**`claimed` 未入網或 `member` 單台:舊 autocommit `.seeded` → NEED_MESH=1 → revert 回階段 1,只能 `batman-slot commit` 強制**(A2-m10);p5 多出的 prov 檔舊程式不認、不刪(`cp -a` 只加)→ 無害。升回:`prov.cbor` 仍在 → 狀態回來 | `prov-downgrade-254`:member(有鄰居)降級 → mesh 在、`ssh -i lab` 可登入(02);升回 generation 同 |
| L13 | bcm2710 | — | ❌ 等新板;**共用檔改動在 bcm2710 未測**(殘項) | — |
| L14 | bcm2711 | — | 本文件 | 全部 |
| L15 | `batman_bypass=1` | 96 exit 1 留著 | 96 verdict=`bypass`;helper `unknown`、不產生、`persist` 拒;provd 只 `status/public` | `prov-bypass-254`(fresh / 非 fresh) |
| L16 | 恢復出廠(app / SD 標記) | — | §4.5 十步;三個斷電點 | `prov-factory-reset-254`(destructive,**在 02**;含 v2 流程負對照) |
| L17 | **legacy 升級**(02/04) | — | 96 verdict=`restored`、無 prov;helper `--prov-get` rc 9 → 產身分 → `prov{legacy}` persist(`--save`,p5 已 seed → 不碰 overrides 語意);**AP/dropbear/lock-status/`mesh-expected` 全不動;autocommit 走今天的規則**;trial 上也產(revert 無害) | `prov-legacy-upgrade-254`(04):AP key、lock-status、authorized_keys、`mesh-expected` 不變、`prov-state` 第 4 欄 = `legacy`;**負對照 B**:04 OTA 到 `radio1.disabled=1` 的 trial → **必須 revert**(v2 規則下 commit) |
| L18 | legacy 認領 | — | 同 claim + §6.1 legacy 門;不清 lab key;AP/mesh 不動;之後 NEED_MESH 看 live key(≠ placeholder → 今天的規則) | `prov-legacy-claim-254`:**04 無 key 無 dev-open → `E_UNSUPPORTED(no-ssh-key)`(負);02 有 lab key → 成功、`ssh -i lab` 仍可登入** |
| L19 | `distroconfig` 改動 | — | 不隨 OTA;**p1 與 p3 兩份**手動改(04 ✅;02 待使用者) | PR-F 驗收(04 ✅ 40/40 500 MHz) |
| L20 | 96 掛不起 p5 | 96 exit 0、被刪 | 96 verdict=`p5-unavailable` → helper `unknown`、不產生;**下次開機 helper 自己再 `--prov-get`**,p5 好了就產/還原(B2-M3) | `prov-p5-mountfail-254`:96 單元測試 + helper 單元測試(白箱注入 `--prov-get` rc 1 一次 → 第二次開機有身分) |
| L21 | trial 槽上 app 操作 | — | 改狀態動詞 `E_BUSY(updating)`;只有身分產生/還原 | `prov-trial-busy-254`(負:v2 會接受 claim) |
| L22 | `network/leave` / `owner.remove` 後 OTA | — | prov.cbor 整檔換;helper 刪 p6 `mesh-expected`/`mesh-joined`;新槽 `claimed` | `prov-leave-ota-254` |
| L23 | 改名 | — | helper 先 persist → `uci set hostname` + `system reload`;**⚠️ 假設 openmanetd 重保留 IP 並重開**(#202 殘項已有兩次實證:D2/D3 改 hostname 都換了 IP);app「機台會重新啟動」;hostname `[A-Za-z0-9-]{1,32}`;SSID 不跟著改 | `prov-rename-254`(⚠️ 探針待使用者) |
| L24 | 兩支手機同時認領 | — | provd 序列化;第二個 `E_STATE` | `prov-two-phones-254` |
| L25 | 認領 / `net.apply` 進行中 OTA / `--on-join` tick | — | 互斥靠 config-save 自己的鎖(helper 不持鎖);`--on-join` 只看已提交 prov → **未提交交易永不進 p5**;`batman-slot precheck --check` 看到 stale → 擋 | `prov-netupdate-254`:步驟 2 故意失敗 + 期間 `--on-join` 跑過 → 重開後 state 不變、p5 generation 不前進(負:v2「讀 .stage」規則前進) |
| L26 | `network/update` → `wifi reload` 離網 | — | BLE 獨立介面不受影響;provd 先 ack 再套用 | 同 L25 |
| L27 | joinwatch / openmanetd / dpp-handler 重啟 | — | 既有 | 既有 |
| L28 | BLE 與 WiFi AP 同顆 CYW43455 | — | 共存由韌體仲裁;spike 已見 AP+mesh+BLE 同時在 | `prov-coex-254`(量吞吐) |
| L29 | 換手機 / 第二位擁有者 | — | S3:`owner.replace`(QR + owner-op);psk_owner ≤ 4 | 殘項列入 S3 PR |
| L30 | prov 版本太新(降到較舊的階段 1) | — | 96 verdict=`too-new`、不抄;helper `--prov-get` 也判 too-new → `unknown`、不產生 | 單元測試 |
| L31 | **單台在家更新**(member、隊友關機) | — | `ota-armed.mesh=radio`(arm 時沒鄰居)→ 只要求 radio_up → commit | §6.4 案例 3(負:v2 規則 revert) |
| L32 | fresh 開機 p5 暫時掛不起,之後每次開機 | 96 被刪、永遠 image defaults | helper 每次開機自己看 p5(§4.2)→ 恢復 | 同 L20 |
| L33 | overlay `prov.cbor` 壞、p5 好 | — | §4.4 步驟 6 以 p5 重建 | `prov-overlay-corrupt-254`(白箱:截斷 overlay 的 prov.cbor → 重開 → state 回來) |

## 6. 流程(只寫實作層差異;流程本體見 219 §6)

### 6.1 認領
`claim/start` → helper `nonce(h)` → app `claim/finish`(`client_resp`、owner pubs、`sig_enc`)→ helper `claim.verify`(§4.1:自己重算 ClientChal)→ 原子:owner 寫入 stage → `claimed_counter+1` → persist → rename → 鎖定(§6.2)→ `--save` → `prov-state=claimed`。失敗任一步回滾(鎖定在 persist 之後,所以失敗時 shadow 未動)。
**legacy 門(B2-M9)**:state=`legacy` 時 `claim.verify` 另要求 `/etc/batman-dev-open` 存在 **或** `/etc/dropbear/authorized_keys` 至少一行可用(96 `:164` 同一正規式);否則 `E_UNSUPPORTED(reason=no-ssh-key)`,app 文案「這台是舊機台:請先用 Ethernet 裝一把 SSH 公鑰(或開發標記)再認領」。理由:legacy 認領會關掉密碼登入而 U3 不裝 key → 操作員會被鎖在外;且今天任何連上 04 AP 的人都能 root → `qr` → 搶認領。

### 6.2 鎖定(U3)
- 設:`dropbear.PasswordAuth=off`、`RootPasswordAuth=off`、`system.ttylogin=1`、root 密碼 = 隨機 24 字元(經安全通道交 app;寫 shadow;丟了用 `root_password.reset`)、`lock-status=LOCKED`。
- **不動 `authorized_keys`**。沒有行 = SSH 關(民用正常態;管理走 BLE);有 lab 行 = 留著。
- `/etc/batman-dev-open` 存在 → 不鎖。**它不進任何 image(wsl 或 rel)**;bench 節點由 harness 在測試前 `touch`、測後刪;操作員要開就 SSH 進去 touch(A2-m9;Q2 定案)。
- `legacy` 認領同上(多 §6.1 的門)。

### 6.3 建網 / 加入
`net.apply`:第 1 版需 owner-op `network/join`(§4.1);helper 驗 COSE、解 `net_secrets`;`halow-setkey --mesh … --no-persist` → persist;`--save --promote-lkg` 只由 helper 在 `meshjoin_joined` 後下(provd 無此動詞)。

### 6.4 autocommit(兩板共用檔;v3 三條規則)

`expected_in_mesh()`:讀 `$ST/prov-state`;boot_id ≠ 本次 → 當作無檔。

| state / `mesh_expect` | NEED_MESH | 鄰居 | 說明 |
|---|---|---|---|
| 無檔 / `legacy` | **今天的規則**(`:388-396`) | 今天的規則 | 02/04 升級後零回歸(A2-B2/B2-B3) |
| `unclaimed` / `claimed` 且 placeholder(`0`) | 0 | — | 219 §6.3 |
| `claimed` 且 live key ≠ placeholder(`1`) | 今天的規則 | 今天的規則 | legacy 認領後 |
| `member`(`radio`) | **新 `meshjoin_radio_up`**:wlh0 存在、`iw dev wlh0 info` type mesh point、mesh_id == uci | **只在 `$ST/ota-armed.mesh=joined`**(arm 那次開機 `meshjoin_reachable` 為真)才要求 ≥ JOIN_NEED 筆 | B2-M5:單台在家更新 commit、有鄰居的壞 image revert |

`health_ok()` 加:**`$ST/ble-ok` 存在時**才檢查 `$RUN/batman-prov.health`(≤ 60 s 新鮮、`bluetoothd=1 hci0_powered=1 provd=1`);無 `ble-ok` → 只 log WARN。`ble-ok` 由 helper 在 committed 槽首次看到 Powered 時寫 → BT 壞/`.hcd` 缺/p1 未改的機台不會被永久擋 OTA;逃生口 `autocommit-hold-once`(R48)。
**負對照四件**:(1) 04 legacy OTA 到 `radio1.disabled=1` trial → revert(v2 commit);(2) unclaimed OTA → commit(1.5.12 revert);(3) member 單台無鄰居 OTA → commit(v2 revert);(4) member 有鄰居 OTA 到 `radio1.disabled=1` → revert;(5) `ble-ok` 在、`bluetoothctl power off` → UNHEALTHY;`ble-ok` 不在 → 只 WARN。

### 6.5 診斷
`diag.bundle` 走 BLE(owner-op);`/www/cgi-bin/bundle` 階段 1 **只在 `legacy|unclaimed` 且 `batman-dev-open` 時可用**,其他 403(殘項:正式驗證)。

### 6.6 改名
L23。⚠️ 探針待使用者;#202 殘項已有兩次「改 hostname → openmanetd 重保留 IP 並重開」的實證(02 D3、04 D2),設計依此。

## 7. 依賴的行為與證據

| # | 依賴 | 證據 | 狀態 |
|---|---|---|---|
| D1 | `miniuart-bt` + `SERIAL_DEV_CTRL_TTYPORT=y` → serdev 綁定、`hci_bcm` probe、patchram | R38(04 實機) | ✅ |
| D2 | 上游 `kmod-bluetooth` 不可用,自建 kmod + deselect 不衝突 | R38/R39(build 過、裝上、lsmod 三模組) | ✅ |
| D3 | `.hcd` 來源與授權 | R27、spike 套件 | ✅ |
| D4 | BlueZ 5.72 D-Bus LE adv/GATT 可由非 root 使用(policy 放行後) | spike 以 root bluetoothctl 驗 adv/GATT;**provd uid 的 policy 待 PR-P2** | ⚠️ |
| D5 | uci-defaults 全在 S10、排序 `99zz` 最後 | R31 | ✅ |
| D6 | 96 Lane A 順序、`.batman-p5-restored` 由 99 刪 | R47、`99:7` | ✅ |
| D7 | config-save 鎖/接管、stage+mv、`--check` rc 表、`--save` 首次 seed | R46 | ✅ |
| D8 | `batman-slot precheck` 擋 stale | 202 C | ✅ |
| D9 | `expected_in_mesh`、`health_ok`、`hold-once` 現行邏輯 | R48 | ✅ |
| D10 | ujail、capabilities | R11 | ✅ |
| D11 | Go 工具鏈、vendoring | #252 | ✅ |
| D12 | mini UART baud 依 core clock;`core_freq_min=500` 穩定 | R41(40/40) | ✅ |
| D13 | `halow-setkey` 現行行為與旗標 | R45 | ✅ |
| D14 | 無 agent → 不可 bond;bluetoothctl 自帶 agent | R40(iPad 實測) | ✅ |
| D15 | 改名 → openmanetd 重保留 IP 並重開 | #202 殘項兩次實證;正式探針 ⚠️ U5 | ⚠️ |
| D16 | 04 faketime 卡 2025-07-15 | R50 | ❓ → #174 |
| D17 | Go `fxamacker/cbor` core-deterministic、`flynn/noise` NXpsk0/IK 與向量一致 | 待 PR-P2 | ⚠️ |
| D18 | `jffs2reset -y` 在 f2fs-on-loop0 版面找到 `rootfs_data` 並 `overlay_delete` | R43(走到提示 = volume 找到;字串) | ✅ 工具存在 / ⚠️ 實跑待 L16(02) |
| D19 | `invalidate_slot` + `clear_root` 可對另一槽重用 | R44 | ✅ 原始碼 |
| D20 | `payload-teardown --zeroize` 完整停掉 OTS 並清 volume | R49 原始碼;#167 測試 | ✅ |
| D21 | `/boot` 永遠 p1、slot B 讀 p3 | R41 | ✅ |
| D22 | fresh overlay 時 `jffs2reset` 後下次開機 mount_root 重建 overlay(標準 firstboot 路徑) | fstools 行為(x86 rootdisk 相同);2026-09-13 事故是 dd 殘留 superblock,不是這條路 | ⚠️ 實跑待 L16 |

## 8. 安全

**資產**:節點控制(root、OTA 槽、重置)、mesh/AP 金鑰、節點身分、認領秘密、擁有者/網主金鑰、成員名單、診斷包、tenant 資料(OTS DB)、BLE 可用性(3A+ 唯一管理面)。

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| 路人(BLE) | 讀身分/追蹤 | 未交握只 `status/public`;`claimed\|member` 不帶 `device_id` 末碼;RPA;adv 無 Local Name | `prov-sec-anon-254` |
| 路人 | 暴力認領 | 256-bit;每連線 3 次即斷 | `prov-sec-claim-brute-254` |
| 路人 | 佔連線 / 大訊息 / crash provd | ≤2 連線、10 s、8 KiB;無限 respawn + 退避 | `prov-sec-hog-254`、`-oversize-254`、`prov-respawn-254` |
| 路人 | 簽章 oracle | helper 組訊息、節點 nonce、2/s | 單元 + 向量 |
| 路人 → 攻陷 provd | 重置 / 改網 / **換擁有者** / 解 `net_secrets` / 升 lkg | helper 重算 ClientChal、owner-op、admins 鏈、首版 join 需 owner-op、無 ecdh/persist 動詞 | `prov-sec-helper-auth-254`(§4.1 負測試六條) |
| 路人 | 配對/綁定 | 無 agent、`AlwaysPairable=false`、BR/EDR 不編 | `prov-sec-bond-254`(04 ✅ 已驗) |
| 路人 | kernel BT 堆疊 | 只 LE、三模組;BlueZ 進 #247 | SBOM |
| 連上 legacy 節點 AP 的人 | SSH root → `qr` → 搶認領、鎖住操作員 | `qr` 在 legacy 需 dev-open 或 tty;legacy 認領需 key/dev-open(§6.1) | `prov-legacy-claim-254`(04 負) |
| 本機非 root | 操作 `org.bluez` | dbus 無 default policy | `prov-sec-dbus-254`(04 ✅ 已驗) |
| 本機非 root | 冒用 app 對 helper | socket 0660 + PEERCRED | `prov-sec-helper-uid-254` |
| 本機非 root | 讀私鑰/秘密/health 檔 | root 0600/0700;`$RUN` root | `prov-sec-key-perms-254` |
| 本機非 root | 預建 socket 目錄 / run 檔 | `/tmp/run` root 0755;`O_NOFOLLOW` | tmp-trust 掃描 |
| 本機非 root | 讀 AP/mesh PSK | **既有缺口**(R33)→ #13 | — |
| 前任擁有者 | 恢復出廠後仍有 SSH 金鑰 / 密碼 / IRK / tenant 資料 | §4.5 清 p6 → p5 → 另一槽 → 本槽 overlay | L16 斷言 + v2 負對照 |
| 擁有 SD 卡 | 複製身分 / 改 prov.cbor / 放標記檔重置別人的機台 | **擋不住**複製(階段 1 限制;608B/LUKS);標記檔要 `device_id` 相符 | `prov-factory-reset-254` 斷言不符時忽略 |
| 任何人拿到舊 QR | 搶先認領 | 全清 = 舊 QR 無效 | L16 斷言 |
| 供應鏈 | `.hcd`、BlueZ CVE、信任根 | sha 釘死;#247;無內建 CA | SBOM |
| 我們自己 | 兩寫者、fail-open、log 洩密 | §3 單寫者;`unknown` 關 AP;`qr`/`root_password` 不進 log;trial 拒改狀態 | 96 單元測試;`logread \| grep -c <secret>` = 0 |

**既有缺口(明列)**:R33 PSK world-readable → #13;R34 LOCKED 後 login 在 GPS 口 → #105;04 root 空密碼開 AP(#137,legacy 現況)。

## 9. 測試

- **協定裁判**:Go 實作逐位元組過向量(含新增 `-dev`、`batman-owner-op-v1`、`device_id`);與 `verify.py` 做對手交握(CI)。02 當 central 只驗 GATT 框架。
- 每個 `prov-sec-*` 與每條 BLOCKER/MAJOR 修正都有「關掉就過 / 舊規則就錯」的負對照(§4.1、§4.5、§6.4、L7/L17/L18/L21/L25 已列)。
- tier A:firstboot、boot、sec-*、respawn、bluez-restart、helper-restart、bypass、legacy-upgrade、two-phones、trial-busy、overlay-corrupt。tier B(DNODE):ota、autocommit ×5、downgrade、leave-ota、legacy-claim(02 正 / 04 負)、netupdate、rename(⚠️)。destructive(**02**):powerloss ×3、factory-reset(+ v2 負對照)、p5-mountfail(白箱)。PR-F:coex。
- 破壞性測試先列副作用與還原(記憶 2026-10-18):L16 在 02 做(02 無 tenant;還原 = 重新 `halow-setkey` + 回 fleet 設定;02 的 IP 會變);04 不做 L16。
- harness 不用 bluetoothctl 當長駐 client(R40);節點端 BLE 斷言走 helper 的 health 檔。

## 10. 實作切法

1. **PR-F(firmware)**:`feat/254-ble` 現狀 + 重 build(policy plugin 修正)→ 04 OTA → `Powered: yes` 自動、`Pairable: no`、三模組、dbus 負測試、閒置 500 MHz;release note:**p1 與 p3 兩份 distroconfig 要手動改**。
2. **docs PR**:`219-protocol.md` v0.7(`batman-owner-op-v1`、首版 join 授權、`device_id` 公式、helper 重算 ClientChal)、CDDL、向量;`219-field-provisioning.md` v2.9(§6.3/§6.9/§7 對齊本文件)。
3. **PR-H1(harness)**:`prov-*` 骨架、02 central client、`verify.py` 對手模式、L16 副作用清單。
4. **PR-P1(產品,兩板共用檔)**:`batman-config-save`(`--prov-file/--prov-meta/--prov-identity/--prov-get/--wipe-all`、fp/check 納入 prov)、`96`(verdict 全出口、prov 抄、4b 跳過)、`halow-setkey`(`--ap-off/--mesh-off/--no-persist/--firstboot`)、`batman-slot`(`invalidate-other`、`apply` 記 `ota-armed.mesh`)、`batman-autocommit` v3(§6.4)、`meshjoin.sh` `meshjoin_radio_up`、`99zz-batman-prov-state`;helper + keystore `file`(socket 測試,無 BLE)。**bcm2710 ❌ 未測,寫進 PR body 與殘項。**
5. **PR-P2**:provd、GATT、協定核心、`status/public`、認領(含 legacy 門)、鎖定、`ssh_keys`、`root_password`。
6. **PR-P3**:建網/加入/邀請/狀態/診斷/離開/恢復出廠/改名。
7. S4(更新)、S5(app)addendum。

## 11. 殘項(回 #254)

3A+ 全部 + 共用檔 bcm2710 實測;04 I2C 空(R16);SSID 與 hostname 脫鉤;`/www/cgi-bin/bundle` 正式驗證;#110 能力偵測接軌;LED 不做;`halow-status:118` 文字;`owner.replace`(L29)進 S3;R33/R34 既有缺口;改名探針(U5);`core_freq_min=500` 耗電;RSSI 遮蔽/外殼;02 的 p1/p3 `core_freq_min`;恢復出廠後 OTS image 要重新放(#159);D22 實跑。

## 12. 待決

| # | 題 | 定案 / 建議 |
|---|---|---|
| Q1 | legacy 身分何時產生 | **定案:升級後第一次開機就產**(trial 上也產,revert 無害) |
| Q2 | `batman-dev-open` 進哪個 image | **定案:不進任何 image**;harness/操作員手動 touch |
| Q3 | 恢復出廠是否保留 p6 `log/` | 建議**不保留**(含 hostname/MAC);最後一步清 |
| Q4 | 恢復出廠是否保留 docker image(讓 OTS 不用重灌) | 建議**不保留**(出廠 = 裸機;#159 之後 image 在 rootfs 就不是問題) |

## 13. v2 審查 → v3 對應

| v2 發現 | 收法 |
|---|---|
| A-B1 / B-B2 恢復出廠 | §4.5 整段重寫:十步、p6→p5→另一槽→本槽 overlay、現成工具、三個斷電點、v2 負對照;`invalidate-other`/`--mesh-off` 在 PR-P1 新增 |
| A-B2 / B-B3 legacy 失去 mesh 閘 | §6.4:`legacy` 一律今天的規則;`mark_mesh_expected` 不改;負對照 L17 |
| A-B3 / B-m2 `claim.verify` 可換 owner | §4.1:helper 重算 ClientChal,介面去掉 `client_chal`;負測試 |
| B-B1 serdev | R38:`SERIAL_DEV_CTRL_TTYPORT=y` 已在 spike,04 實證;D1 ✅ |
| A-M1 / B-M1 `.stage` 兩讀者 | §4.3/§4.4:config-save 永不讀 `.stage`;`--prov-file` 明示;L25 改寫 |
| A-M2 shadow 回滾 | §4.4 步驟 5:鎖定在 persist 之後;`--apply-state` 對 legacy/unclaimed 不碰 shadow;L7 斷言 04 仍可登入 |
| A-M3 / B-m16 96 vs helper 兩寫者 | §4.3:96 4b 依 `prov.meta` state 跳過 |
| A-M4 `owner.auth` 標籤 | §1.3:新標籤 `batman-owner-op-v1`,進 v0.7 |
| A-M5 首次 join 無授權 | §4.1 `net.apply` 第 1 版需 owner-op |
| A-M6 / B-M6 `keystore.ecdh` | 刪;`psks.get` 只回導出值;誠實界線 |
| A-M7 / B-M4 `health_ok` BLE | §6.4:`ble-ok` 標記 gating;health 檔不經 bluetoothctl;hold-once 逃生口;L5 前置 p1+p3 |
| A-M8 身分產生原子 | §4.2 `.identity.tmp` + rename;config-save 驗 7 檔 + sha |
| A-M9 / B-M8 hook 走 setkey | `--firstboot` / `--apply-state --boot` 只 uci set |
| B-M2 marker 四態 vs 五態 | §1.4 狀態只由 `prov.cbor.state`;marker 改成 verdict 回報 |
| B-M3 marker 永久凍結 | §4.2 helper 每次開機 `--prov-get`;L20/L32 |
| B-M5 單台在家更新 | §6.4 `ota-armed.mesh` + `meshjoin_radio_up`;L31 |
| B-M7 套件依賴 | R39:0012 patch + ble_diffconfig,04 實證 |
| B-M9 legacy 認領鎖住操作員 | §6.1 legacy 門;`qr` 限制;L18 04 負測試 |
| B-M10 不存在的動詞 | §4.5/§10 PR-P1 新增;bcm2710 ❌ 明寫 |
| A-m1 dbus send_interface | R39 已含 |
| A-m2 / B-m10 96 還原 prov 契約 | §4.3(regular、≤ 64 KiB、0600、sha、too-new) |
| A-m3 sidecar | `prov.meta` |
| A-m4 overlay 壞 p5 好 | §4.4 步驟 6;L33 |
| A-m5 非 ext4 → absent | 96 verdict `raw` vs `p5-unavailable` |
| A-m6 counter | 進 `prov.cbor` |
| A-m7 / B-m3 persist 授權 | 動詞刪除;lkg 升級 helper 內部 |
| A-m8 seed_key_ok | 不改;helper 只用 `--save` |
| A-m9 dev-open 進 wsl | Q2:不進 image |
| A-m10 降級 | L12 |
| A-m11 root 密碼遺失 | `root_password.reset` |
| A-m12 mesh-joined | §3:leave/reset 時 helper 刪 |
| A-m13 / B-m5 SD 標記 | §4.5 契約(fw-part、device_id、trial、刪不掉) |
| A-m14 legacy 定義 | §1.4 |
| A-m15 / U7 typo | 不動 |
| A-m16 / B-m4 perms / boot 綁定 | `prov-state` 0600 + boot_id |
| B-m1 sign 訊息 | §4.1 `sign.*` helper 組訊息、2/s |
| B-m6 respawn | `3600 5 0` |
| B-m7 bluetoothd 無 hci0 | 照跑(R39 init) |
| B-m8 hostname 洩漏 | `Name=Batman`、adv 無 Local Name |
| B-m9 `device_id` 公式 | §1.3 hex(sn) |
| B-m11 trial 認領 | §4.1 `E_BUSY`;L21 |
| B-m12 `qr` 進 log | §4.2/§8 |
| B-m13 p1 版本 | R41;L19 |
| B-m14 非 fresh p5 掛不起 | §4.4 步驟 8 |
| B-m15 讀 Powered | health 檔(R51) |
