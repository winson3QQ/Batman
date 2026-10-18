# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v4**

狀態:v3 兩位 REJECT(A:1 BLOCKER / 10 MAJOR / 14 MINOR;B:1 BLOCKER / 5 MAJOR / 13 MINOR;報告 `254-reviews/review-v3-{A,B}.md`,v3 全文 `254-reviews/254-stage1-impl-v3.md`)。v4 重寫 §4.3–§4.5、§6.1、§6.4,改 §3/§5/§8;§13 列 v3 每條的收法。PR-F BLE spike 已在 04 真機跑過(#254 留言 6251617876 / 6255818833 / 6255842632)。
上層設計:`219-field-provisioning.md`(v2.8)、`219-protocol.md`(v0.6;本文件要求的改動列在 §1.3,成為 v0.7)。本文件只定**實作層介面**;與上層衝突處在 §1.3 明列,以本文件為準。
基準:Batman `main` f2f2bf6(= 出貨 1.5.12-wsl.2),firmware `build-3aplus` 527303e8 + spike 分支 `feat/254-ble` a5e181b7;節點 02(10.41.1.1,slot B,1.5.12-wsl.2,無乙太網 carrier、無 BLE build)、04(10.41.1.3,slot B,1.5.12-wsl.3 spike build,OTS,**乙太網在這台**)皆 Pi 4B Rev 1.5。03(3A+)故障,階段 1 只做 Pi 4。

## 0. 一句話

加 **BLE(自建 `kmod-batman-bt` + 精簡 BlueZ,只開 LE、不配對、dbus root-only;spike 已驗)**、一支**非 root 的 `batman-provd`(Go,ujail)** 與一支 **root 的 `batman-provhelper`**;helper **自己重算/驗證每個改變節點的請求的授權物件**;私鑰與 PSK 導出只經 helper 的 **keystore 介面**(階段 1 `file`,之後 `se`)。**p5 是擁有權的 SoT**;p5 上的 prov 檔(`prov.cbor`、`identity/prov/`、最後寫的 commit 紀錄 `prov.meta`)**只有 helper 經 `batman-config-save --prov-only` 一個寫入路徑**,其他 config-save 模式不寫、不刪、不比對 prov;helper 交易期間以 `$RUNDIR/prov-txn` 讓 `--on-join` 讓路。**狀態只由 `prov.cbor.state` 決定**;helper 每次開機自己看 p5、以 p5 與 overlay 中**較新且完整**的一份為準並補寫另一份。**鎖定欄位依階段分擁有者**:fresh overlay 上是 96(對 `claimed|member` 一律 fail-secure 上鎖),執行期轉換是 helper。既有 fleet(02/04)升級後是 `legacy`:**OTA 的 mesh 閘與今天完全相同**、AP/dropbear/lock 不動。`member` 的 OTA 閘在 **stage 1(live 系統)** 判定「更新前有沒有鄰居」並寫進 p6,讀不到一律當有鄰居(fail-closed)。**恢復出廠**依 219 §7 的範圍:凍結 p5 寫入者 → 清 p6 → `mkfs` p5 → 作廢另一槽 → 清本槽 overlay(含 dot 項目);每步有失敗政策,斷電續做在**阻塞的早期 init** 跑,失敗時節點不會全暗。

## 1. 決策、範圍、事實

### 1.1 使用者決策(不變)

| # | 決策 | 後果 |
|---|---|---|
| U1 | 開發期 608B 留空;焊上 608B / 換 HAT 時 provd 與 app **不重工** | keystore 介面 + `file`/`se` 後端 |
| U2 | 節點 Go、手機 Flutter + Rust、GATT 走 BlueZ D-Bus | 向量 + `verify.py` 當裁判 |
| U3 | **擁有權與 SSH 脫鉤** | 認領不碰 `authorized_keys`;dropbear **照跑**(只關密碼登入);legacy 認領多一道防呆門(§6.1) |
| U4 | 階段 1 恢復出廠 = **全清**(含身分 → 新 QR) | §4.5;**後果:機身 QR 失效,新 QR 只能經 root 取得(乙太網 / serial `batman-provhelper qr`)** — 階段 1 限制,#255 的 608B 解掉 |
| U5 | 改名探針待使用者手動跑 | §6.6 ⚠️ |
| U6 | 3A+ 等新板 | 兩板共用檔(`batman-slot`、`platform-ab.sh`、`batman-config-save`、`96`、`halow-setkey`、`batman-autocommit`、`joinwatch`)的改動在 bcm2710 未測,列殘項 |
| U7 | `uart_enable=1` typo 不動 | §4.6 |

### 1.2 Reality check(v1 R1–R17、v2 R18–R37、v3 R38–R53 之外新增 / 更正;2026-10-19)

| # | 事實 | 證據 |
|---|---|---|
| R38–R42 | BLE spike:serdev `serial0-0`、無 ttyS0、三模組、`SERIAL_DEV_CTRL_TTYPORT=y`;套件只有 bluez-libs/daemon、batman-ble、brcm-bt-firmware、kmod-batman-bt;policy plugin 必須留(AutoEnable);bluetoothctl 會註冊 agent;04 的 p1 **與** p3 都已 `core_freq_min=500`,40/40 取樣 500 MHz;RSSI 5–10 m −82~−95 dBm | v3 §1.2(保留原文);#254 留言 |
| **R43(更正)** | v3 寫「`jffs2reset` 走到提示 = 找得到 rootfs_data」**錯了**:`jffs2reset.c:121` 的 `ask_user()` 在 `:134` `volume_find()` 之前。可證的事實改為原始碼:有掛載的路徑 `fs_state_set(PENDING)` + `overlay_delete`(`jffs2reset.c:49-54`),下次開機 `overlay.c:444-455` 見 UNKNOWN/PENDING 會**再刪一次**;`overlay_delete` → `foreachdir` 用 `glob("%s/*")` 無 `GLOB_PERIOD`(`overlay.c:84-99`,musl `glob.c:146`)→ **dot 開頭的目錄不會被刪**。04、02 實測都有 `/overlay/upper/.cache`(含 Tailscale log);04 有 `/opt/batdata/.faketime` | 兩位 v3 reviewer 讀 fstools `build_dir/.../fstools-2024.07.14~408c2cc4`;我本次 `ls -la /overlay/upper`(02、04 都有 `.cache`) |
| R54 | sysupgrade **stage 2** 在 ramfs:`RAMFS_COPY_BIN` 只有 `batman-slot batman-reboot vcmailbox hexdump tr sha256sum head tail cut cmp mktemp`(**無 iw/batctl/ip**,`platform-ab.sh:37`);`/opt/batdata` 已不在,p6 只以背景 10 s 預算重掛到 `$RUNDIR/p6t`(`:212-233`);`batman-slot apply` 在 stage 2 跑(`:343`)。**stage 1** `platform_check_image` 在 live 系統跑 `batman-slot precheck-node`(`:150`)並讀 payload `metadata`(`board=`/`version=`,`:11,173`) | 原始碼(本次抽查) |
| R55 | `meshjoin_reachable` = joined **且** br-ahwlan 有 IPv4 **且** `/etc/init.d/dropbear running`(`meshjoin.sh:23-27`);`meshjoin_joined` = plink ESTAB ≥1 且 batman 鄰居(over wlh0)≥1 | 原始碼 |
| R56 | `halow-setkey:99` 在 reload 之前**無條件** `uci commit wireless`(與 persist 無關)| 原始碼 |
| R57 | `batman-config-save` rc 6 = 「a live value could not be persisted — **the rest was written**」(`:21`、`:389-408`);`--on-join` 對**未 seed** 的 p5 照寫並最後寫 `.seeded`(`:365-397`) | 原始碼 |
| R58 | `clear_root()` 用的 `ZERO_MB` 只在 `precheck()` 依 payload squashfs 大小算(`batman-slot:607-614`);`slot_bootdev()`(`:103`)= A→p1、B→p3;**`fw-part` 回的是韌體分割序號**:02、04 `fw-part A`=1、`fw-part B`=2 | 原始碼;兩台本次 |
| R59 | init 順序:batdata-mount S11(p6)、batman-faketime S12、halow-keyguard S18、joinwatch S98、batman-autocommit/flightrec/meshled S99、dockerd S99、guardian stub `START=99`;procd instance 是背景執行,init 不等它 | `feed/*/etc/init.d/*`;A 的 04 `ls /etc/rc.d` |
| R60 | 02:`eth0 carrier=0`、無 `/sys/class/bluetooth`、`ttylogin=0`、`PasswordAuth=on`、1 行 lab key;04:`eth0 carrier=1`、`hci0`、0 行 authorized_keys | A、B 本次探針 |
| R61 | 協定 `claim/finish` 的**回應**帶 `owner_tag_key`、`adv_owner_key`、`root_password`(`219-protocol.md:185`);已認領只接受 `NXpsk0`(`:39`);冪等鍵「跨 session 10 分鐘」(`:148`) | 原始碼(文件) |

### 1.3 與上層設計不同處(→ `219-protocol.md` v0.7 / `219-field-provisioning.md` v2.9)

| 上層 | 本文件 | 理由 |
|---|---|---|
| 219 §6.1 認領寫 `authorized_keys` | 不寫;鎖密碼登入、隨機 root 密碼、`LOCKED` | U3 |
| 219 §6.3 p5 schema 2 | `schema_version` 維持 1;prov 在 `prov.cbor` + `prov.meta` | `96:131` |
| 219 §7 恢復出廠保留身分 | 全清 | U4 |
| 219 §6.9 BLE 健康放 S4 | 階段 1 就加,`ble-ok` gating | §6.4 |
| 協定 §3.5 `batman-owner-auth-v1` | 保留給 session;per-verb 用 **`batman-owner-op-v1`** | 一標籤一格式 |
| 協定 §7.1 第 1 版節點「記下」 | 需 owner-op `network/join` | 首版信任起點 |
| 協定 §5.4 ClientChal | **helper 重算** | 換擁有者攻擊 |
| 協定 §3.3 `device_id` | `hex(sn)`,18 字元;adv 帶末 4 | 公式定案 |
| **協定 §3.5「已認領只接受 NXpsk0」** | **新增例外:已認領、擁有者只有 1 位時,匿名 `NX` session 只允許 `claim/replay`**(§6.1),需 CheckMac **且** 同一 `owner_pub` 的 owner-op → 回傳已存的 `owner_tag_key`/`adv_owner_key` 與**新**的 root 密碼 | 認領回應遺失(A-M8/B-M5) |
| 協定 §10 共用 Rust | 節點 Go、app Rust | U2 |
| v1 內建開發 CA | 自簽 + TOFU | 公開 repo |

### 1.4 狀態機

狀態只由 `/etc/batman-prov/prov.cbor` 的 `state` 決定。`unknown` 是 helper 這次開機的**判決**;`resetting` 是 `$ST/factory-reset.inprogress` 存在時的**模式**。

```
legacy ──(claim + legacy 防呆門)──▶ claimed ──(network/join;owner-op)──▶ member ──(network/leave;owner-op)──▶ claimed
unclaimed ─(claim)─▶ claimed
任何狀態 ──(factory reset:owner-op 或 SD 標記)──▶ resetting ──(完成、重開)──▶ unclaimed(新身分)
unknown(判決):p5 這次讀不到 / prov 兩份都壞 / bypass / 無 p5 → 只開 status/public + SD 標記重置;不產生身分;下次開機再試
```

| 狀態 | AP、dropbear、lock-status | autocommit NEED_MESH(§6.4) | 認領 |
|---|---|---|---|
| `legacy` | **全部不動**(96 4b 今天規則) | **今天的規則** | 開(需防呆門) |
| `unclaimed` | 不動(image 預設:AP placeholder → keyguard 關) | 0 | 每次開機開 |
| `claimed` | 鎖定(§6.2);AP:`radio_managed=0`(legacy 來源)不動,`=1` 關 | live mesh key ≠ placeholder → 今天規則;否則 0 | 只有 `claim/replay` |
| `member` | 鎖定;AP 由網路設定 | §6.4 member 規則 | 只有 `claim/replay` |

`prov.cbor.radio_managed`:unclaimed 認領 → 1;legacy 認領 → 0(保留操作員手設的 mesh/AP);`network/join` 後一律 1。

## 2. 元件

```
手機 app ──BLE GATT── bluetoothd(LE only,無 agent,dbus root/provd-only)──D-Bus── batman-provd(uid provd,ujail)
                                                                                      │ /tmp/run/batman-prov/helper.sock(SEQPACKET,SO_PEERCRED)
                                                                                      ▼
                                                                              batman-provhelper(root,procd S89)
                                                                                ├─ keystore:file | se
                                                                                ├─ 授權:owner-op / admins 鏈 / CheckMac(helper 重算)
                                                                                ├─ 交易式 state.apply(§4.4),交易期間持 $RUNDIR/prov-txn
                                                                                ├─ --boot:p5 ↔ overlay 對帳、身分產生/還原、完成未完的轉換、寫 prov-state
                                                                                ├─ 每 15 s:$RUNDIR/batman-prov.health
                                                                                └─ 工具:halow-setkey(新 --ap-off/--mesh-off/--no-persist/--firstboot)
                                                                                         batman-config-save(新 --prov-only/--prov-get/--wipe-all)
                                                                                         batman-slot(新 invalidate-other、boot-devs)
batman-factory-reset(rc.common,START=13,阻塞 start(),不是 procd):SD 標記偵測 + 斷電續做(§4.5)
platform-ab.sh platform_check_image(stage 1):寫 p6 $ST/ota-armed.mesh(§6.4)
99zz-batman-prov-state(uci-defaults,S10):fresh overlay 時 helper --apply-state --firstboot(只寫 prov-state)
```

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| `hci0` 存在、BR/EDR off、Bondable off | kernel + bluetoothd(`main.conf`,無 agent) | provd 斷言 Pairable==false | R38/R40 |
| `hci0 Powered` | bluetoothd `AutoEnable`(policy plugin) | helper(D-Bus Properties.Get) | |
| `main.conf`、`dbus-1/system.d/bluetooth.conf`、`init.d/bluetoothd` | image(`batman-ble`) | | |
| `/etc/bluetooth/keys/`(IRK) | bluetoothd | | overlay;恢復出廠隨 overlay 清 |
| BLE 廣播、GATT | provd(**不註冊 agent**) | | adv 無 Local Name |
| `/tmp/run/batman-prov/`、`helper.sock` | helper(`O_NOFOLLOW`、owner 檢查) | provd | |
| `$RUNDIR/batman-prov.health`(0600;`<uptime> bluetoothd= hci0_powered= adv_registered_once=`) | helper 每 15 s | autocommit | 變數名不與 autocommit 的 `$RUN` 撞(A-m10) |
| `$RUNDIR/prov-txn`(0600;`<helper_pid> <uptime>`) | helper(交易開始建、結束刪) | `batman-config-save` 寫入模式(存在且 pid 活著且 cmdline 含 `batman-provhelper` → `--on-join` 回 1 下 tick 再試;操作員 `--save` 等 ≤ 30 s) | 不是鎖,只是讓路;helper 死 → pid 不在 → 失效 |
| `/etc/batman-prov/identity/`(7 檔:`node.key ecdh.key node.cert claim.secret backend sn sha256`) | **helper**:只在「overlay 無完整 identity **且** p5 無 `identity/prov/`(`--prov-get` rc 7 或 9)**且**非 bypass」時產生(`.identity.tmp/` 寫滿 → rename);overlay 有完整而 p5 無 → **補 persist**,絕不重產;p5 有而 overlay 無 → 還原;fresh overlay 時 **96 也抄**(Lane A 之後) | | A-M6/B-m2 |
| `/etc/batman-prov/prov.cbor`、`prov.meta` | helper(tmp + rename + fsync,只在 p5 persist 成功後);fresh overlay 時 96 抄 | 96 4b(讀 meta.state)、`--check` | |
| `/etc/batman-prov/.stage/`、`.identity.tmp/` | helper | 只有 helper | dot 目錄 → 恢復出廠步驟 7 明確清 |
| `/etc/batman-prov/ssh_keys.added`(helper 加過的金鑰指紋清單) | helper | | `ssh_keys.set` 只動清單上的行(A-m14) |
| `/etc/.batman-prov-restore`(`<boot_id> <verdict> seeded=<0|1> prov=<0|1>`) | 96(每個出口) | helper(只用來 log「96 這次跑了沒」:boot_id ≠ 本次 = 沒跑) | B-m11 |
| p5 `prov.cbor`、`prov.meta`、`identity/prov/*` | **只有 `batman-config-save --prov-only`**(由 helper 呼叫) | 96、`--prov-get`、`--check` | 其他模式不寫不刪不比對;`--wipe-all` mkfs |
| p5 `.seeded`、`overrides.uci`、`lkg/`、`identity/dropbear/*`、`shadow-root` | `batman-config-save`(既有模式,不改語意) | 96 | |
| `$ST/prov-state`(p6 0600;`<boot_id> <state> <members_n> <mesh_expect>`) | fresh overlay:**99zz**(S10);非 fresh 與每次轉換:**helper** | autocommit、`halow-status` | 兩寫者分屬不同時段(fresh S10 只有 99zz;S89 起只有 helper) |
| `$ST/ble-ok`(0600;`<boot_id>`) | helper(§6.4 條件) | autocommit | |
| `$ST/ota-armed.mesh`(0600;`<target_slot> <payload_version> joined\|radio`) | **stage 1 `platform_check_image`**(live 系統,p6 已掛) | autocommit | autocommit 決策(commit 或 revert)後刪;不符/缺 → 當 `joined`(B-B1/A-M1) |
| `$ST/mesh-expected` | config-save(不改) ;helper 只在 leave/reset 刪 | autocommit | |
| `$ST/mesh-joined` | joinwatch(不改);helper 只在 leave/reset 刪 | autocommit | |
| `$ST/factory-reset.inprogress`(0600;`<step> <device_id> <tries> <reason>`) | helper(runtime 開始) / `batman-factory-reset`(續做) — 同一支 `batman-provhelper --factory-reset` 程式,由 p6 上的 `flock` 互斥 | config-save(存在 → 所有寫入模式拒寫,`--wipe-all` 例外)、joinwatch/dockerd/guardian init(存在 → 拒絕啟動)、provd(status 模式) | B-M2/A-M7 |
| `lock-status`、`dropbear.PasswordAuth/RootPasswordAuth`、`system.ttylogin`、root shadow | **fresh overlay(S10):96** — `legacy`/`unclaimed`/無 prov:今天的 4b;`claimed`/`member`:**一律上鎖**(`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`LOCKED`;shadow 無 hash → root 設 `!`)。**非 fresh 的轉換(認領、完成未完的認領、恢復出廠):helper**。`--apply-state` 開機只**檢查並 log 漂移**,不寫 | `halow-status` | A-M3/A-M4/A-M5/B-m6 |
| `/etc/dropbear/authorized_keys` | 96 Lane A(fresh,從 p5)、操作員、helper(`ssh_keys.set`,只動 `ssh_keys.added` 上的行) | config-save | 認領不碰 |
| live uci `wireless.*` | 執行期只經 `halow-setkey`(helper 交易與 `--apply-state` 對帳都經它);firstboot 經 96 Lane B | provd | |
| 另一槽(rootfs + boot FAT) | `batman-slot`(apply、新 `invalidate-other`,都持 `slot_lock`) | | |
| 本槽 overlay | 恢復出廠步驟 7(helper 的 `find -delete` + `jffs2reset -y`) | | |
| p6 `apps/`、`docker/`、guardian stub | guardian / dockerd(#274);恢復出廠步驟 3–4 | | |
| SD 標記檔 `batman-factory-reset` | 實體寫;**`batman-factory-reset` 讀兩個 boot FAT**(`batman-slot boot-devs`:p1 與 p3;Pi 3 另議),兩份都刪 | | B-M4/A-m5 |
| 認領窗口、失敗計數、session、`s_node` | provd 記憶體 | | |
| `claim/finish` 的結果 | **helper**(`owner_tag_key`/`adv_owner_key` 在 `prov.cbor`;root 密碼只在 helper 記憶體快取 10 分鐘) | provd | provd respawn 不丟;節點重開後走 `claim/replay` |

## 4. 契約

### 4.1 helper socket 與授權模型

- `SOCK_SEQPACKET`,一包一則 CBOR map;`SO_PEERCRED` uid == provd;單連線序列化;≤ 64 KiB;逾時 30 s。
- 每個改變節點的動詞都帶 helper 自己能驗、且 helper 自己組被驗內容的授權物件;provd 給的算好的雜湊/挑戰一律不收。
- **trial 槽**:改狀態動詞 `E_BUSY(updating)`。**resetting 模式**:除 `info.*` 外一律 `E_BUSY(resetting)`。

| 動詞 | 授權 | 效果 |
|---|---|---|
| `info.cert/ecdh_pub/counter/boot_id/state/reset` | 無 | 唯讀(`info.reset` 回 `step`、`tries`、`reason`) |
| `nonce(h)` | 無 | 一次性 `nonce_node`/`nonce_helper`,綁 `h`,60 s |
| `sign.static`、`sign.ecdh_proof`、`sign.peer` | helper 組訊息;全域 2/s | DAC 簽章 |
| `psks.get()` | 無 | `{psk_owner[≤4], psk_member, adv_owner, adv_member}` 導出值 |
| `claim.verify(h, client_resp, owner_pub, owner_enc_pub, sig_enc)` | helper 重算 ClientChal(自己的 nonce、DAC、即將寫入的 owner_pub);`sig_enc` 同把驗;legacy 另需防呆門 | §6.1 交易 |
| `claim.replay(h, client_resp, owner_pub, owner_op)` | state ∈ {claimed, member} 且擁有者只有 1 位 且 `owner_pub` == 已存;CheckMac(重算)**且** owner-op(`verb=claim/replay`) | 回 `owner_tag_key`、`adv_owner_key`;產新 root 密碼(同 `root_password.reset` 的寫法)|
| `net.apply(net_config, net_secrets[, owner_op])` | 首版需 owner-op `network/join`;之後上一版 admins 驗鏈 | §4.4 交易 |
| `owner_op(obj)` | `ES256_owner("batman-owner-op-v1" ‖ h ‖ nonce_helper ‖ verb ‖ args_hash)` | |
| `factory_reset(owner_op)` | owner-op;前置條件 §4.5 | 開始 §4.5 |
| `root_password.reset(owner_op)` | owner-op | 新 24 字元 → shadow → `--save` → 回傳一次 |
| `diag.bundle(owner_op)`、`ssh_keys.set(list, owner_op)` | owner-op | |

- 刪除(v3 已刪,維持):`keystore.ecdh`、`persist`、`keystore.sign(purpose,msg)`。
- **誠實界線(A-m7/B-m5)**:Noise 終點在 provd → **被攻陷的 provd 看得到經過它的一切明文**:`claim/finish`/`claim/replay` 回應裡的 `owner_tag_key`、`adv_owner_key`、root 密碼,以及 `psks.get` 的 `psk_member`/`adv_member`。`psk_member` 是**全網共用**(協定 §6)→ provd 被攻陷 = 能以成員身分連**整個網路每一台**的 BLE、追蹤全網廣播;換密碼(`net_version`+1)後 provd 立刻重拉新值,**趕不走持續存在的入侵**,只能重刷該台 image。helper 守住的是:改網、換擁有者、重置、解 `net_secrets`、讀私鑰。
- 負測試(關掉檢查就過):provd uid 送 `factory_reset` 無 auth → `E_FORBIDDEN`;`net.apply` 錯簽 / 首版無 owner-op → `E_FORBIDDEN`;`claim.verify(h, resp_買家, owner_pub_攻擊者)` → `E_FORBIDDEN`;`claim.replay` 用不同 `owner_pub` 或無 owner-op → `E_FORBIDDEN`;`keystore.ecdh`/`persist` → `E_SCHEMA`;trial 上 `claim.verify` → `E_BUSY`。

### 4.2 keystore 與身分

```go
type Keystore interface {
    SN() [9]byte; DeviceID() string             // file: sn = SHA-256(node_pub)[:9]; device_id = hex(sn)
    Cert() []byte
    SignPurpose(purpose string, nodeNonce, peerFields []byte) ([]byte, error)
    ECDHPub() []byte; ECDH(peerPub []byte) ([]byte, error)   // 只在 helper 內部 net.apply
    CheckMac(clientChal, clientResp [32]byte) error
    Backend() string
}
```

`file` 後端 7 檔(`identity/` 0700):`node.key`/`ecdh.key`(PKCS#8 0600)、`node.cert`(自簽 `CN=dev:<device_id>`,2020→2120,0644)、`claim.secret`(32 B 0600)、`backend`、`sn`、`sha256`(前 6 檔清單)。`claimed_counter` 在 `prov.cbor`。

**helper `--boot` 對 `--prov-get` 每個 rc 的行為**(A-M10/B-m1/B-m2):

| `--prov-get` rc | 意義 | overlay identity 完整 | overlay identity 缺 |
|---|---|---|---|
| 0 | p5 有完整 prov + identity | 比 generation(§4.4 步驟 6) | 從 p5 還原 |
| 7 | p5 ext4、未 seed、無 prov | 補 persist(`--prov-only`) | **產生** → `prov{unclaimed}` → persist |
| 9 | p5 seeded、無 prov(legacy 升級) | 補 persist | **產生** → `prov{legacy}` → persist(`--prov-only`,不碰 overrides,B-m3) |
| 10 | p5 prov 不完整 / sha 不符 / meta 缺(寫到一半) | 以 overlay 為準 → 重新 persist | `unknown(prov-corrupt)`,不產生 |
| 13 | p5 有 prov 但無 `identity/prov/` | 補 persist identity | `unknown(identity-lost)`,不產生 |
| 1 / 8(3 次) | mount 失敗 / lock busy | 沿用 overlay(非 fresh);persist 一律 `E_PERSIST` | `unknown(p5-unreadable)` |
| 3 | bypass | `unknown(bypass)` | 同左 |
| 11 | 無 p5(單槽 image) | `unknown(no-p5)` | 同左 |
| 12 | p5 非 ext4 | `unknown(p5-not-ext4)` | 同左 |
| 14 | prov `v` 太新 | `unknown(too-new)` | 同左 |

`unknown` 每次開機重算;`unknown` 時 SD 標記重置**可用**(步驟 5 是 `mkfs`,§4.5)→ 這是 p5 壞掉的機台在現場的出口(A-B1)。

- `se` 後端:`backend=se` 而 608B 不回應 → helper 拒絕啟動。焊上 608B = 新身分。
- app:鏈長 1 + `dev:` → TOFU pin;release 拒。
- 開發期 `batman-provhelper qr`:root;`claimed|member` 拒;`legacy` 只在 dev-open 存在或 stdin 是**實體 console**(`/dev/console`、`ttyAMA*`、`tty1`;**不收 `pts`**)時執行;stdout 不進 log。

### 4.3 p5 版面與 `batman-config-save`(PR-P1,兩板共用)

```
p5/
  schema_version=1, .seeded, overrides.uci, lkg/, identity/dropbear/*, shadow-root   (不變)
  identity/prov/{7 檔}                                                                (一次寫入)
  prov.cbor   ({v:1, generation, state, radio_managed, claimed_counter, owner{pub,enc_pub,tag_key,adv_key}, admins[], net{config,secrets}, members, ssh_keys[]})
  prov.meta   (一行:"v=1 state=<s> gen=<n> sha=<hex64>";≤ 256 B;字元集 [a-z0-9=_ ];未知 key 忽略;v>1 → too-new)
```

| 模式 | 內容 |
|---|---|
| **`--prov-only --prov-file <f> --prov-meta <m> [--prov-identity <dir>]`**(新,只有 helper 呼叫) | 取鎖(同 `--save`)→ `$RUNDIR/factory-reset` 檢查同其他寫入模式 → 驗 `<m>` 格式與 sha、`<f>` regular ≤ 64 KiB;`--prov-identity` 驗 7 檔 + sha,只在 p5 無 `identity/prov/` 時寫 → 寫入順序:`identity/prov/`(若有)→ `prov.cbor` → **`prov.meta` 最後**(= commit 紀錄)→ sync。**不碰** `.seeded`、overrides、lkg、dropbear identity、shadow(B-m3)。**p5 未 seed 也可寫**(新卡)。rc:0 / 1 錯誤 / 8 lock busy;沒有 rc 6(不經 PRESERVE)。rc≠0 時 helper 一律用 `--prov-get` 讀回 `gen` 決定結果(A-M3) |
| `--prov-get <dir>`(新,唯讀) | ro,noload;抄 `prov.cbor`、`prov.meta`、`identity/prov/` 到 `<dir>`;rc 表見 §4.2 |
| `--wipe-all`(新,只有恢復出廠) | **`mkfs.ext4` p5**(label batman-cfg);p5 在 `/proc/mounts` → rc 8(重試);p5 為 LUKS 標頭 → rc 1(階段 1 不存在,#111 再議);不需 `seed_key_ok`。結果 = 空 ext4、未 seed |
| `--on-join`、`--save`、`--seed`、`--if-healthy` | **不寫、不刪、不比對 prov 檔**(fp、`same_identity` 排除 `identity/prov/`、`prov.*`)(B-M1/A-m3);`$RUNDIR/prov-txn` 有效 → `--on-join` rc 1(下 tick)、`--save` 等 ≤ 30 s;`$ST/factory-reset.inprogress` 存在 → 一律 rc 1(B-M2/A-m11) |
| `--check` | 另比 overlay `prov.meta` vs p5 `prov.meta`:不同 → `p5 stale: prov`(rc 5);`batman-slot` 的 `P5_STALE_HINT` 對 `prov` 改寫成「helper 會在下一次開機/15 s 內補寫;仍 stale → `batman-provhelper --persist-now`」 |
| `mark_mesh_expected()`、`seed_key_ok()`、lkg 規則 | 不改 |

`96`(PR-P1):
- 每個出口寫 `/etc/.batman-prov-restore`(含 boot_id)。
- **prov 抄寫放在 `.seeded` 檢查(`:93`)之前**(新卡 p5 未 seed 也有 prov):p5 `prov.meta` 格式對、sha 對、`prov.cbor` regular ≤ 64 KiB → 抄 `prov.*`(0600);`identity/prov/` 驗 sha 清單後抄(0600/0644、只 regular file)。meta `v` 太新 → 不抄。
- 4b:p5 `prov.meta` 的 state ∈ {claimed, member}(**不論 prov.cbor 有沒有抄成功**)→ **一律上鎖**:`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`lock-status=LOCKED`;`/etc/shadow` root 無 hash → 設 `root:!`(serial 也進不去,擁有者用 app `root_password.reset`)。否則今天的規則(A-M5/B-m6)。
- 單元測試:96 對每個出口 × 有/無 prov × 4 種 state × meta 壞/好。

### 4.4 交易式 `state.apply`

以 `net.apply` 為例(`claim.verify` 見 §6.1):
1. helper 建 `$RUNDIR/prov-txn`;在 `.stage/` 組新 `prov.cbor`(gen n+1)+ `prov.meta`。
2. 可失敗的副作用:`halow-setkey … --no-persist`(注意:它會 `uci commit wireless`,R56)。失敗 → 反向 setkey `--no-persist`、刪 stage、刪 prov-txn、`E_APPLY`。
3. `batman-config-save --prov-only --prov-file .stage/prov.cbor --prov-meta .stage/prov.meta`。rc≠0 → `--prov-get` 讀回:gen == n+1 → 視為已提交,走步驟 4;gen == n → 回滾步驟 2、刪 stage、`E_PERSIST(rc)`。
4. `rename` overlay 的 `prov.cbor`、`prov.meta`;fsync。
5. 不可失敗的副作用(lock / shadow / AP)→ `batman-config-save --save`(帶 overrides 與 shadow-root 到 p5;rc 6 = 其餘已寫,log;rc 1 → log,下次開機 `--check` stale 會被 helper 補)→ 刪 prov-txn → 寫 `$ST/prov-state`。
6. **開機 `--boot`(每次)**:`--prov-get` 依 §4.2;rc 0 時比 gen:
   - p5 > overlay → 以 p5 重建 overlay 的 prov(dropbear identity / shadow 由 96 管,不在此);
   - overlay > p5 → **以 overlay 為準,重新 `--prov-only`**,log `p5 lost a committed prov write`(B-M1);
   - 相等 → 不動。`.stage/` 殘留一律丟棄。
7. **`--apply-state`(開機與 helper 重啟後)**:
   - **完成未完的轉換**:state ∈ {claimed, member} 而 `lock-status` ≠ LOCKED → helper 上鎖(shadow 無 hash → `root:!`,log `owner must reset root password via app`)。
   - **wireless 對帳(A-M2)**:只在 `radio_managed=1`:helper 解目前 `net_secrets` → 比 live uci 的 mesh key/mesh_id/channel/AP key → **不同才**經 `halow-setkey --no-persist`(之後 joinwatch `--on-join` 把對帳後的值寫回 p5)。`radio_managed=0`(legacy、legacy 認領後)與 `unclaimed` → **不碰 wireless**。
   - legacy / unclaimed:**不寫** dropbear、ttylogin、lock-status、shadow、AP(A-M4)。
   - 只 log 漂移,不改鎖定欄位(fresh overlay 時 96 已寫)。
   - `--firstboot` 變體(99zz,S10):只寫 `$ST/prov-state`,不 reload、不 persist、不碰 uci。
8. 非 fresh 開機 p5 讀不到:沿用 overlay;persist 一律 `E_PERSIST`;`halow-status` 紅字。

### 4.5 `halow-setkey` 新旗標、恢復出廠、SD 標記檔

**`halow-setkey`**:`--ap-off`/`--mesh-off`(placeholder + disabled + MARK;繞過 `:55` 的 placeholder 拒絕);`--no-persist`(不跑 `:147` 的 `--save`;**仍會 `uci commit`**,呼叫者自己負責);`--firstboot`(只 uci set + MARK + commit,不 reload、不讀回、不 persist)。

**`batman-slot` 新動詞**(兩板共用):
- `boot-devs`:印兩個槽的 boot FAT 裝置(包 `slot_bootdev`;Pi 4:p1 p3)。
- `invalidate-other`:`slot_lock` → `is_trial` 為真 → 拒(rc 2)→ `disarm_tryboot` → 另一槽 root 分割:讀 squashfs superblock `bytes_used`(offset 40,8 B LE),`ZERO_MB = ceil(bytes_used/1 MiB) + 64`;讀不到 / 超過分割大小 → 清整個分割 → `dd` 清零 → `tboot_open` 另一槽 FAT:成功 → `invalidate_slot` 寫 BATMAN-BAD;失敗 → log `fat-unmountable`,root 已清零即算完成(該槽開不起來,panic 回預設槽)→ `otalog_k SLOT INVALIDATE-OTHER zero_mb=… fat=ok|fail`。

**恢復出廠** — **前置條件**(任一不成立 → `E_PRECOND(reason)`,SD 路徑則保留標記、log、下次開機再試):committed 槽(`is-trial` rc 1);`slot_lock` 可取得且 tryboot 未 arm(B-m9);p6 已掛且 `$RUNDIR/batman-storage.crit` 不存在(B-m13);非 bypass。

步驟寫在 p6 `$ST/factory-reset.inprogress`(`<step> <device_id> <tries> <reason>`,0600)。執行者是 `batman-provhelper --factory-reset`(以 p6 上 `flock` 互斥):runtime 由 helper 啟動;斷電續做由 **`batman-factory-reset` init(START=13,阻塞 `start()`)**執行 —— 在 p6 掛好(S11)之後、joinwatch(S98)/dockerd(S99)/guardian(S99)之前,而那三支的 init 在 marker 存在時拒絕啟動(A-M7)。

| 步 | 動作 | 失敗政策 |
|---|---|---|
| 1 | 寫 marker step=1;provd 進 resetting 模式(只回 `info.*`,廣播 `resetting`);`/etc/init.d/joinwatch stop`;從此 config-save 除 `--wipe-all` 外全部拒寫 | — |
| 2 | `halow-setkey --mesh-off --ap-off --no-persist`(離網;p5 已凍結,沒真的離網也不會被寫回) | 失敗 → log,繼續(p5 已凍結,不影響結果) |
| 3 | dockerd 在跑 → 每個 `apps/<t>` `payload-teardown <t> --zeroize`、`/etc/init.d/dockerd stop`;dockerd 沒跑(續做)→ 只刪 guardian stub、disable;然後 `find /opt/batdata/docker -mindepth 1 -delete` | 失敗 → 記 `tries`,下次開機重試此步;3 次後 → 步驟 4 會整個清 p6 所以繼續,`reason` 記 `teardown-partial` |
| 4 | `find /opt/batdata -mindepth 1 ! -path /opt/batdata/state ! -path /opt/batdata/state/factory-reset.inprogress ! -path /opt/batdata/lost+found -delete`,`lost+found` 清內容不刪目錄(**含 dot 項目**,如 `.faketime`)(A-m2/A-m13) | 失敗 → 重試此步,3 次後 `reason=p6-partial` 並繼續 |
| 5 | `batman-config-save --wipe-all`(**mkfs p5**) | rc 8(有人掛著)→ 等 5 s 重試 10 次;仍失敗 → **停在此步**(不往下,否則下次開機 96 會還原前任),下次開機重試;provd status `reset step=5 failed=p5-busy\|mkfs`;Ethernet/serial 照常 |
| 6 | 驗證:`--prov-get` 必須 rc 7 | 不是 7 → 回到步驟 5 |
| 7 | `batman-slot invalidate-other` | rc 2(trial,理論上前置已擋)→ 停;其他失敗 → 記 `reason=other-slot-partial` 並繼續(該槽只會更早被 OTA 覆寫) |
| 8 | 寫 marker step=8 → `find /overlay/upper /overlay/work -mindepth 1 -delete`(含 dot,A-m2/B-M3)→ `rm -f /overlay/sysupgrade.tgz` → `jffs2reset -y`(設 PENDING:下次開機 fstools 再清一次,步驟 8 之後的寫入無害,R43) | 失敗 → 繼續(PENDING 下次開機仍會清非 dot 項目;dot 已刪) |
| 9 | 刪 SD 標記(**兩個 FAT 都刪**:p1 = `/boot`,p3 rw 掛到 `batman_tmp -d`);刪不掉 → log | 標記內容是舊 `device_id`,重置後新身分不同 → 下次開機被忽略,**不會重置迴圈**(B-m13 更正) |
| 10 | `sync; reboot`(正常 shutdown) | — |
| 11 | 下次開機(fresh overlay):96 `unseeded`;99 重新個人化;S13 `batman-factory-reset` 見 step ≥ 8 → 清 p6 `log/`、`crash/` 的 dot 與非 dot 內容 → **刪 marker** → 繼續開機;S89 helper `--boot`:`--prov-get` rc 7、overlay 無 identity → 產新身分 → `prov{unclaimed}` → `--prov-only` | — |

- **續做時不會全暗**:resetting 模式 provd 照廣播 `status/public`(`resetting step=N tries=T reason=R`);乙太網與 dropbear 照常(只是 p5 凍結);停在步驟 5 的機台,操作員可以用 Ethernet 看 `logread`。
- **結果斷言**(L16):重開後 `info.state=unclaimed`、`device_id` 新、舊 `claim.secret` 無效、`/etc/dropbear/authorized_keys` 不存在、root shadow = image 預設、hostname 新、p6 只剩白名單(`state/`(空)、`lost+found`(空))、`find /overlay/upper -name '.*'` 為空、`/etc/bluetooth/keys/` 空、另一槽 BATMAN-BAD 且 root 頭清零、舊 SSH 金鑰被拒。**負對照**:(a) v2 流程(只 wipe p5 + reboot)上同一組斷言 hostname/shadow/authorized_keys/apps 都沒變;(b) 只用 `jffs2reset -y`、事先在 `/overlay/upper/etc/batman-prov/.stage/` 放假檔 → 重開後還在(B-M3);(c) 步驟 1–4 後 fault-injection 讓 `--on-join` 照跑 → v3 流程 p5 被重新 seed,v4 流程 config-save 拒寫(B-M2);(d) 白箱把 p5 magic 寫壞 → SD 重置 → 一次開機內完成、新身分(v3 卡死,A-B1)。
- **斷電點**:步驟 3 中途、4 後、5 後、8 後;每個點重開後最終斷言都要成立,且 `docker ps -a` 為空、無 OTS volume。
- **誠實界線**:清除是 unlink / 清零 / mkfs,不是安全擦除;p6 的 docker image 與 tenant 資料全清 = 出廠裸機(#159 未做)。
- **SD 標記檔契約**:檔名 `batman-factory-reset`,在**任一**個 boot FAT 根目錄(使用者用 PC 讀卡機看到哪個就放哪個);內容第一行 = 本機 `device_id`,或 `any`(只在 `/etc/batman-dev-open` 存在時接受);`device_id` 不符 → 忽略 + log 一次;前置條件不成立(trial)→ 留著、每次開機重試;p1 `fmask=0022` → 非 root 不能寫。

### 4.6 BLE 平台(spike 實測;同 v3)

| 項 | 定案(`feat/254-ble` a5e181b7,init 修正未重 build) |
|---|---|
| kernel | `kmod-batman-bt`:BT=m、BR/EDR=n、LE=y、HCIUART(SERDEV/BCM/H4)、其他全 n;內建 `SERIAL_DEV_CTRL_TTYPORT=y`;FILES = bluetooth/btbcm/hci_uart;`ble_diffconfig` deselect `kmod-bluetooth*`、`bluez-utils*`、`kmod-ath3k`、`ar3k-firmware` |
| 韌體 | `brcm-bt-firmware-4345c0`(63806 B,sha256 51c45e77…)+ LICENSE |
| BlueZ | patch 0012:bluetoothd + bluetoothctl;bluez-libs 依賴 kmod-batman-bt |
| `main.conf` | `Name=Batman`、`ControllerMode=le`、`AlwaysPairable=false`、`PairableTimeout=0`、`DiscoverableTimeout=0`、`JustWorksRepairing=never`、`Privacy=device`、`NameResolving=false`、`[GATT] Cache=no`、`[Policy] AutoEnable=true`;不裝 agent |
| dbus | root-only policy + 6 個 send_interface;PR-P2 加 `<policy user="provd">` |
| init | START=61 STOP=20、`respawn 3600 5 0`、`--noplugin=hostname,autopair,battery,neard,sap` |
| distroconfig | `[pi4] core_freq_min=500`;**p1 與 p3 兩份**手動改(04 ✅、02 ❌);typo 不動 |
| 待量 | coex 吞吐、遮蔽 RSSI、500 MHz 耗電 |

### 4.7 procd / ujail

| 服務 | START / STOP | 說明 |
|---|---|---|
| batman-factory-reset | **13**(阻塞 `start()`)| SD 標記 + 續做;沒事 → 立即返回 |
| dbus | 60 | |
| bluetoothd | 61 / K20 | |
| batman-provhelper | 89 / K15 | `--boot`、health、`ble-ok` |
| batman-provd | 92 / K10 | ujail;`respawn 3600 5 0` |
| joinwatch / dockerd / guardian | 98 / 99 / 99 | **marker 存在 → 拒絕啟動**(init 補一行) |

### 4.8 GATT / 廣播

同 v3;另:resetting 時 `status/public` 帶 `resetting`;trial 時帶 `updating=1`;`claimed|member` 允許匿名 NX 只為 `claim/replay`(其他訊息 `E_FORBIDDEN`)。

## 5. 生命週期矩陣

| # | 路徑 | 今天(1.5.12) | 階段 1 後 | 測試(負對照) |
|---|---|---|---|---|
| L1 | first boot,新卡 | 96 `:93` exit | 96 verdict `unseeded`;helper rc 7 → 產身分 → `prov{unclaimed}` `--prov-only`(p5 未 seed 也寫) | `prov-firstboot-254`(負:rc 1 時不產) |
| L2 | boot(member,非 fresh) | — | gen 相等 → `--apply-state`:只 log 漂移、wireless 對帳(一致 → 無 reload) | `prov-boot-254` ×3:無 `wifi reload` log、gen 不變 |
| L3 | clean shutdown | — | provd K10 | boot-reasons |
| L4 | reboot | 同 L2 | 同 L2 | |
| L5 | OTA 到本 image | 96 還原 | + 96 抄 prov;claimed/member 96 上鎖;**前置:p1 + p3 的 core_freq_min** | `prov-ota-254`;**`prov-lock-failsecure-254`:白箱把新 image helper 換成 `exit 1` → claimed 節點 OTA 後密碼登入被拒(v3 會成功)** |
| L6 | autocommit | marker/`.seeded` | §6.4 | §6.4 負對照 |
| L7 | 斷電 / helper 死在 `state.apply` | — | 步驟 2–3 間:uci 已 commit,p5 未變(prov-txn 擋 `--on-join`)→ 開機 `--apply-state` 對帳 wireless 回 prov 的值;3–4 間:p5 新 → 重建;4–5 間:鎖未做 → 完成轉換 | `prov-powerloss-254`:三個點;斷言 `uci get wireless.*.key` 與 prov 一致、p5 `overrides.uci` mesh key 未前進(A-M2) |
| L8 | provd crash loop | — | 無限 respawn + 退避;認領結果在 helper | `prov-respawn-254` |
| L9–L11 | bluetoothd / dbus / helper 重啟 | — | 重註冊 / 重連 | 各一 |
| L12 | downgrade 到 1.5.12 | — | 同 v3;`claimed`/`member` 單台/unclaimed 會被舊 autocommit revert,要 `batman-slot commit` | `prov-downgrade-254` |
| L13 | bcm2710 | — | ❌ | — |
| L14 | bcm2711 | — | 本文件 | 全部 |
| L15 | bypass | 96 exit 1 | `unknown(bypass)` | `prov-bypass-254` |
| L16 | 恢復出廠 | — | §4.5 | `prov-factory-reset-254`(destructive;**位置與還原路徑 = Q5**);四個負對照 + 四個斷電點 |
| L17 | legacy 升級(02/04) | — | helper rc 9 → 產身分 → `prov{legacy}` `--prov-only`(**不碰 overrides**,trial 上也安全);AP/dropbear/lock/mesh-expected 不動 | `prov-legacy-upgrade-254`(04);負對照:04 OTA 到 `radio1.disabled=1` → revert |
| L18 | legacy 認領 | — | 防呆門;`radio_managed=0`;不清 lab key | 04 負(無 key)/ 02 正 |
| L19 | distroconfig | — | p1 + p3 手動 | PR-F(04 ✅) |
| L20 | 96 掛不起 p5 | 96 被刪 | helper 下次開機自己再試;**只補得回 prov/identity**,overrides(mesh key/hostname/IP)仍停在 image 預設,與今天相同(B-m11 更正) | 白箱單元測試 |
| L21 | trial 上 app 操作 | — | `E_BUSY(updating)` | `prov-trial-busy-254` |
| L22 | leave / owner.remove 後 OTA | — | prov 整檔換;helper 刪 mesh markers | `prov-leave-ota-254` |
| L23 | 改名 | — | ⚠️ U5 | `prov-rename-254` |
| L24 | 兩支手機同時認領 | — | 第二個 `E_STATE` | `prov-two-phones-254` |
| L25 | 交易進行中 `--on-join` tick / OTA | — | prov-txn 讓路;`--on-join` 從不寫 prov;`--check` 看 prov.meta → stale 擋 OTA | `prov-netupdate-254`:步驟 2 失敗 + 期間 `--on-join` → p5 gen 與 overrides 都不前進(負:v3 讀法 overrides 前進);步驟 3–4 間插 sleep + `--on-join` + `reboot -f` → state=claimed(負:B-M1 讀法回 legacy) |
| L26 | network/update → wifi reload | — | BLE 不受影響 | 同 L25 |
| L27 | joinwatch / openmanetd 重啟 | — | 既有 | 既有 |
| L28 | BLE + WiFi AP 共存 | — | 待量 | `prov-coex-254` |
| L29 | 換手機 / 第二擁有者 | — | S3 | 殘項 |
| L30 | prov 太新 | — | rc 14 → `unknown(too-new)` | 單元 |
| L31 | 單台在家更新 | — | stage 1 判 `radio` → 只要 radio_up → commit | §6.4 (3) |
| L32 | fresh p5 暫時掛不起 | 96 被刪 | 同 L20 | 同 L20 |
| L33 | overlay prov 壞、p5 好 | — | §4.4 步驟 6 | `prov-overlay-corrupt-254` |
| **L34** | **認領回應遺失**(persist 後 BLE 斷 / 節點重開) | — | app 以 `claim.replay` 重取(§6.1) | `prov-claim-replay-254`:persist 後 `reboot -f` → replay 拿到相同 `owner_tag_key`(v3:`E_STATE`,鎖在外);用別的 `owner_pub` replay → `E_FORBIDDEN` |
| **L35** | **恢復出廠撞上已 arm 的 tryboot / sysupgrade 進行中** | — | 前置條件拒絕 | `prov-reset-precond-254` |
| **L36** | **p6 沒掛 / 受損時恢復出廠** | — | 前置條件拒絕;status 顯示原因 | 同上 |
| **L37** | **恢復出廠某步每次都失敗**(p5 被掛著、FAT 壞) | — | §4.5 失敗政策;節點不全暗 | 負對照 (d) + 白箱 p5 busy → 停在 5、BLE 可答 |
| **L38** | **trial 上 helper 晚於 autocommit 啟動**(非 fresh trial 不存在;fresh trial 由 99zz 在 S10 寫好) | — | autocommit 讀到非本次 boot_id 的 prov-state → 等 ≤ 60 s;仍無 → 今天的規則 | 白箱刪 99zz 輸出 → 走今天規則 |
| **L39** | **遠端 BLE 讓 provd 一直 crash(trial 期間)** | — | health 只看 bluetoothd + hci0 + 「本次開機曾註冊廣播」→ 不 revert 好 image | `prov-provd-dos-254`(B-m12) |

## 6. 流程

### 6.1 認領 / 重取 / 防呆門

**`claim.verify` 交易**:
1. prov-txn;helper 驗(§4.1);產 `owner_tag_key`、`adv_owner_key`、**root 密碼(24 字元,只在 helper 記憶體)**、新 `prov.cbor`(state=claimed、`radio_managed`、owner、`claimed_counter+1`)。
2. `--prov-only` persist(rc≠0 → 讀回 gen 判定,§4.4 步驟 3)。
3. rename overlay prov。
4. 上鎖(§6.2):shadow 寫密碼 hash → `--save`(帶 shadow-root)。
5. 回應 `{owner_tag_key, adv_owner_key, root_password}`;helper 快取這份回應 10 分鐘(綁 boot_id;provd respawn 不丟)。
6. 刪 prov-txn、`prov-state=claimed`。

**`claim.replay`**(L34):回應遺失 + 節點重開(快取已失)時,app 以匿名 NX 連入,送 `claim/replay`(CheckMac 用 QR 秘密 + owner-op 用擁有者私鑰)→ helper 回存在 `prov.cbor` 的 `owner_tag_key`/`adv_owner_key`,並**產新 root 密碼**(同 `root_password.reset`)。只持有 QR 的人(前任、修理行)沒有擁有者私鑰 → `E_FORBIDDEN`;只持有擁有者私鑰而無 QR → CheckMac 失敗。

**legacy 防呆門**:state=`legacy` 時 `claim.verify` 另要求 `/etc/batman-dev-open` 存在**或** `authorized_keys` 至少一行可用;否則 `E_UNSUPPORTED(no-ssh-key)`。**這道門只防誠實的操作員把自己鎖在外**;legacy 節點今天 root 是開放的(#137:連上 04 AP 就能 SSH root),root 能自己加 key 或 touch dev-open → **legacy 上的 root = 可以認領**,這是既有缺口,不是本設計擋得住的(A-m6/B-m4)。

### 6.2 鎖定
`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、隨機 root 密碼、`LOCKED`;**dropbear 照跑**(`meshjoin_reachable` 依賴它,R55);不動 `authorized_keys`;`/etc/batman-dev-open` 不進任何 image(harness / 操作員手動 touch)。

### 6.3 建網 / 加入
§4.4;首版需 owner-op;成功後 `radio_managed=1`;`--save --promote-lkg` 只由 helper 在 `meshjoin_joined` 後下。

### 6.4 autocommit(兩板共用)

**stage 1 寫 `ota-armed.mesh`**(B-B1/A-M1):`platform_check_image` 在 `batman-slot precheck-node` 通過後:`. meshjoin.sh; meshjoin_sample; meshjoin_joined && m=joined || m=radio`(**用 `meshjoin_joined`,不用 `reachable`**:不依賴 dropbear/IP);寫 `$ST/ota-armed.mesh` = `<batman-slot target> <metadata version=> <m>`(0600,先寫 tmp 再 rename)。寫失敗 → 不阻擋 OTA(讀端 fail-closed)。

`expected_in_mesh()`(讀 `$ST/prov-state`;boot_id ≠ 本次 → 等 ≤ 60 s,仍無 → 今天的規則):

| state / `mesh_expect` | NEED_MESH | 鄰居要求 |
|---|---|---|
| 無檔 / `legacy` | 今天的規則(`:388-396`) | 今天的規則(`meshjoin_reachable`) |
| `unclaimed`;`claimed` 且 placeholder(`0`) | 0 | — |
| `claimed` 且 live key ≠ placeholder(`1`) | 今天的規則 | 今天的規則 |
| `member`(`radio`) | `meshjoin_radio_up` 必須成立(wlh0 存在、mesh point、mesh_id == uci) | `ota-armed.mesh` 的 slot 與 version == 本 trial **且** 值 = `radio` → 不要求;**其他(`joined`、缺、不符、壞)→ 要求 `meshjoin_reachable` ≥ JOIN_NEED** |

- autocommit 決策(commit 或 revert)後刪 `ota-armed.mesh`。
- `health_ok()` 加:`$ST/ble-ok` 存在才檢查 `$RUNDIR/batman-prov.health`(≤ 60 s;`bluetoothd=1 hci0_powered=1 adv_registered_once=1`;**不看 provd 現在是否活著**,B-m12)。
- `ble-ok` 寫入條件(A-m8/B-m7):committed 槽 **且** 兩個 boot FAT 的 `distroconfig.txt` `[pi4]` 都有 `dtoverlay=miniuart-bt` 與 `core_freq_min=500`(唯讀檢查)**且** `vcgencmd get_config core_freq_min` ≥ 500 **且** `Powered` 連續 ≥ 10 分鐘。逃生口:`autocommit-hold-once`。

**負對照**:(1) 04 legacy OTA 到 `radio1.disabled=1` → revert;(2) unclaimed OTA → commit(1.5.12 revert);(3) member 單台無鄰居 OTA → commit(v2 revert);(4) **member 有鄰居 OTA 到「mesh point 起得來但頻道不同」的 trial(image 預設 `wireless.radio1.channel` 改成鄰居不用的合法頻道)→ revert**(v3 會 commit,B-B1);(5) member 有鄰居、刪掉 `ota-armed.mesh` → 要求鄰居(fail-closed);(6) `ble-ok` 在、`bluetoothctl power off` → UNHEALTHY;不在 → 只 WARN;(7) trial 期間 provd 反覆被 kill → 不 revert。

### 6.5 診斷
同 v3。

### 6.6 改名
⚠️ U5;#202 兩次實證「改 hostname → openmanetd 重保留 IP 並重開」。

## 7. 依賴的行為與證據

| # | 依賴 | 證據 | 狀態 |
|---|---|---|---|
| D1–D3 | serdev / kmod / .hcd | R38/R39 | ✅ |
| D4 | provd uid 的 dbus policy | 待 PR-P2 | ⚠️ |
| D5–D11 | uci-defaults 順序、96 Lane A、config-save 鎖、precheck、autocommit、ujail、Go | v3 R 表 | ✅ |
| D12 | core_freq_min=500 穩定 | R41 | ✅ |
| D13 | `halow-setkey` 行為(含 `:99` 無條件 commit) | R45/R56 | ✅ |
| D14 | 無 agent 不可 bond | R40 | ✅ |
| D15 | 改名換 IP | #202 兩次 | ⚠️ U5 |
| D16 | 04 faketime | #174 | ❓ |
| D17 | Go CBOR / Noise 向量 | 待 PR-P2 | ⚠️ |
| **D18(更正)** | `jffs2reset -y` 在 f2fs-on-loop0 找得到 overlay 並設 PENDING | fstools 原始碼(`jffs2reset.c:49-54`、`rootdisk.c`);**v3 的「走到提示」證據作廢** | ⚠️ 原始碼 / 實跑待 L16 |
| D19 | `invalidate_slot`、`slot_bootdev`、`disarm_tryboot` 可重用;`clear_root` **不可**直接重用 | R44/R58 | ✅ |
| D20 | `payload-teardown --zeroize` | R49 | ✅ |
| D21 | `/boot` 永遠 p1、slot B 讀 p3 | R41 | ✅ |
| **D22** | PENDING 下次開機再清一次(步驟 8 之後的寫入無害) | `overlay.c:444-455` | ✅ 原始碼 |
| **D23** | fstools 不刪 dot 目錄 | `overlay.c:84-99` + musl `glob.c:146`;02/04 `.cache` 實測 | ✅ |
| **D24** | stage 1 live 系統可跑 `meshjoin_sample`、p6 已掛、payload metadata 有 `version=` | `platform-ab.sh:11,150,173` | ✅ 原始碼 / 實跑待 PR-P1 |
| **D25** | stage 2 無 iw/batctl/ip、無 p6 | `platform-ab.sh:37,212-233` | ✅ |
| **D26** | busybox `find -delete`、`-mindepth`、`! -path` 可用 | ⚠️ 待 PR-P1 上機 `find --help` | ⚠️ |

## 8. 安全

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| 路人(BLE) | 讀身分 / 追蹤 / 暴力 / 佔連線 / 配對 | 同 v3 | 同 v3(bond、dbus 04 ✅) |
| 路人 | 讓 provd crash 以 revert 好 image | health 不看 provd 存活 | `prov-provd-dos-254` |
| 路人 → 攻陷 provd | 改網 / 換擁有者 / 重置 / 解 net_secrets / replay 換擁有者 | helper 重算、owner-op、admins 鏈、replay 綁已存 owner_pub | §4.1 負測試 |
| 攻陷的 provd(擋不住的部分) | 看到經過的明文:`owner_tag_key`、root 密碼、**全網 `psk_member`** | **誠實界線**(§4.1):能冒充全網成員 BLE session,換密碼趕不走,只能重刷 image | — |
| 只持有 QR 的人(前任、修理行) | 在擁有者回應遺失時搶 replay | replay 需擁有者私鑰 | L34 |
| legacy 節點上的 root(連上 04 AP 的人) | 認領 | **擋不住**(既有 #137;§6.1 誠實寫明);門只防誠實操作員鎖死 | — |
| 本機非 root | 操作 org.bluez / 冒用 helper / 讀秘密 / 預建檔 | dbus、PEERCRED、0600、`O_NOFOLLOW`;新 p6 檔 0600 + `-O` + 非 symlink(A-m12) | `prov-sec-*` |
| 前任擁有者 | 恢復出廠後殘留 SSH / 密碼 / IRK / tenant / dot 檔 | §4.5 p5 凍結 + mkfs + overlay 含 dot | L16 四個負對照 |
| 擁有 SD 卡 | 複製身分 / 改 prov / 放標記重置別台 | 擋不住複製(階段 1);標記要 device_id | L16 |
| p5 被改(實體) | 4b 跳過 → fail-open | **不再跳過**:claimed/member 一律上鎖 | `prov-lock-failsecure-254` |
| 供應鏈 | .hcd / BlueZ / 信任根 | sha、#247、無內建 CA | SBOM |
| 我們自己 | 兩寫者 / fail-open / log 洩密 / 恢復出廠卡死 | §3;§4.5 失敗政策;`qr`/密碼不進 log | 96 單元;`logread \| grep -c <secret>`=0 |

既有缺口:R33 PSK world-readable(#13);R34 LOCKED login 在 GPS 口(#105);legacy root 開放(#137)。

## 9. 測試

- 協定裁判:向量(含 `-dev`、`owner-op-v1`、`device_id`、`claim/replay`);`verify.py` 對手交握。
- 每個 BLOCKER/MAJOR 的修正都有負對照(§4.1、§4.5、§6.4、L5/L7/L25/L34/L37)。
- tier A / tier B / destructive 分類同 v3;destructive 新增 L34(reboot -f)、L37。
- **破壞性測試先列副作用與還原**(記憶 2026-10-18):L16 的位置、central、還原路徑由使用者在 Q5 決定後才排;未定前 L16 不跑。
- harness 不用 bluetoothctl 當長駐 client;BLE 斷言走 helper 的 health 檔。

## 10. 實作切法

1. **PR-F(firmware)**:`feat/254-ble` + 重 build(policy plugin)→ 04 OTA 驗 `Powered` 自動;release note:p1 + p3。
2. **docs PR**:`219-protocol.md` v0.7(owner-op 標籤、首版 join、`device_id`、helper 重算、**`claim/replay` 與匿名 NX 例外**)、CDDL、向量;`219-field-provisioning.md` v2.9。
3. **PR-H1(harness)**:`prov-*` 骨架、central client、`verify.py`、L16 副作用清單。
4. **PR-P1(產品,兩板共用)**:config-save(`--prov-only/--prov-get/--wipe-all`、prov-txn 讓路、reset 凍結、`--check` prov)、96(prov 抄在 `:93` 前、4b fail-secure、verdict 帶 boot_id)、halow-setkey(4 旗標)、batman-slot(`invalidate-other`、`boot-devs`)、platform-ab.sh(stage 1 `ota-armed.mesh`)、autocommit v4、meshjoin `meshjoin_radio_up`、joinwatch/dockerd/guardian init 的 marker 檢查、`batman-factory-reset` init、99zz;helper + keystore(socket 測試)。bcm2710 ❌。
5. **PR-P2**:provd、GATT、協定核心、認領(含 replay、防呆門)、鎖定、ssh_keys、root_password。
6. **PR-P3**:建網/加入/邀請/狀態/診斷/離開/恢復出廠/改名。
7. S4、S5 addendum。

## 11. 殘項(回 #254)

3A+ 與共用檔 bcm2710 實測;04 I2C;SSID 脫鉤;`/cgi-bin/bundle`;#110;LED;`halow-status:118`;owner.replace;R33/R34/#137;U5;耗電;RSSI 遮蔽;02 的 p1/p3;OTS image 重放(#159);D18/D26 實跑;**U4 後果:恢復出廠後新 QR 只能經 root 取得**(#255 解)。

## 12. 待決

| # | 題 | 定案 / 建議 |
|---|---|---|
| Q1 | legacy 身分何時產 | 定案:升級後第一次開機(`--prov-only`,trial 安全) |
| Q2 | dev-open 進哪個 image | 定案:不進 |
| Q3 | 恢復出廠保留 p6 `log/` | 不保留 |
| Q4 | 保留 docker image | 不保留 |
| **Q5** | **L16(destructive 恢復出廠)在哪台跑、怎麼還原**:02 無乙太網、無 BLE build;乙太網在 04 = 主機進 mesh 的唯一橋 | **建議**:先把 02 升到 BLE build 並改 p1+p3,**L16 期間把乙太網線移到 02**(還原 = Ethernet `halow-setkey` 回 fleet 設定;期間主機經 02 → mesh 到 04 會斷,02 回網後恢復);04 不跑 L16(OTS)。**需使用者決定 / 動手移線** |

## 13. v3 審查 → v4 對應

| v3 發現 | 收法 |
|---|---|
| A-B1 恢復出廠無失敗政策、p5 壞時死鎖 | §4.5 每步失敗政策;步驟 5 改 mkfs(p5 壞也能清);不全暗;L37 + 負對照 (d) |
| B-B1 / A-M1 `ota-armed.mesh` stage 2 算不出 | §6.4 改 stage 1 寫、`meshjoin_joined`、綁 slot+version、缺/不符 fail-closed、決策後刪;負對照 (4)(5) |
| B-M1 p5 prov 兩寫者 | §4.3 只有 `--prov-only`;其他模式不寫不比;步驟 6 overlay 新 → 以 overlay 為準 |
| B-M2 / A-m11 reset 期間 p5 未凍結 | marker 存在 → config-save 拒寫;joinwatch stop + init 拒啟;步驟 6 驗證 rc 7 |
| B-M3 / A-m2 dot 目錄、R43 證據 | 步驟 8 `find -delete`;R43 更正;D18 ⚠️、D22/D23 ✅ |
| B-M4 / A-m5 SD 標記位置 | `boot-devs` 兩個 FAT 都讀都刪 |
| B-M5 / A-M8 認領回應遺失 | `claim.replay` + helper 快取;協定 v0.7 例外;L34 |
| A-M2 `--no-persist` 仍 commit | prov-txn 讓路 + `--apply-state` wireless 對帳(`radio_managed`) |
| A-M3 rc 6 已寫 | `--prov-only` 無 rc 6;rc≠0 讀回 gen |
| A-M4 legacy 被解鎖 | §4.4 步驟 7:legacy/unclaimed 一律不寫 |
| A-M5 / B-m6 4b fail-open | 96 對 claimed/member 一律上鎖、`root:!`;`prov-lock-failsecure-254` |
| A-M6 / B-m2 身分重產 / rc 9 | §4.2 rc 表;overlay 完整 → 補 persist |
| A-M7 續做並行 | S13 阻塞 init;joinwatch/dockerd/guardian 拒啟 |
| A-M9 L16 在 02 無路可回 | Q5 交使用者;未定不跑 |
| A-M10 / B-m1 rc 表 | §4.2 完整 rc 表;meta 最後寫 |
| A-m1 證據 | R43 更正 |
| A-m3 on-join/check 語意 | §4.3 明定 |
| A-m4 meta 格式 | §4.3 一份定義 |
| A-m6 / B-m4 legacy 門 overclaim | §6.1、§8 誠實改寫;`qr` 不收 pts |
| A-m7 / B-m5 psks 界線 | §4.1、§8 |
| A-m8 / B-m7 ble-ok | 兩個 FAT + core clock + 10 分鐘 |
| A-m9 root 密碼時機 | §6.1 步驟 1/4/5 |
| A-m10 擁有權缺寫者、`$RUN` | §3 補 96 Lane A、99zz;改 `$RUNDIR` |
| A-m12 新 p6 檔契約 | §3 / §8 |
| A-m13 lost+found | 步驟 4 清內容 |
| A-m14 ssh_keys 標記 | `ssh_keys.added` |
| B-m3 legacy persist 改 overrides | `--prov-only` |
| B-m8 clear_root 不可重用 | `invalidate-other` 自算 ZERO_MB |
| B-m9 reset 撞 tryboot | 前置條件 + disarm |
| B-m10 trial prov-state 順序 | 99zz S10 寫;autocommit 等 ≤ 60 s;L38 |
| B-m11 L20 overclaim、marker boot_id | L20 改寫;verdict 帶 boot_id |
| B-m12 provd DoS revert | health 不看 provd 存活;L39 |
| B-m13 p6 未掛、編輯錯 | 前置條件;重置迴圈守門改為 device_id;負對照數量更正 |
