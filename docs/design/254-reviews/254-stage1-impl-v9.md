# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v9**

狀態:第 8 輪 A、B 都是 **REJECT(窄)**,0 BLOCKER / 1 MAJOR(A 12、B 12 MINOR;`254-reviews/review-v8-{A,B}.md`,v8 全文 `254-reviews/254-stage1-impl-v8.md`)。兩位**獨立**找到同一條 MAJOR:v8 把「p5 可能有意圖就不准撤銷」只套在 F3 的 rc 上,另外三個解凍入口(helper 重啟判斷、cancel、重新發起)沒套 → 使用者被告知「已取消」後 p6 仍會被清。v9 把它收斂成**一條不變量 U**(§4.5):任何解凍都要在 root-only 重置鎖內重讀 p5 = `none` 且沒有孤兒寫入程序;並修兩位列為 PR-P1 必做的 MINOR。不加新機制(`reset.lock` 取代 v8 會被接管的 `cfgsave.lock`;`p6uuid` 取代 `state/reset-p6-wiped`)。§13 逐條。

**文件結構**:本文件是完整設計;標「同 v4」「同 v5」的小節內容在 `254-reviews/254-stage1-impl-v4.md`、`-v5.md`,v6/v7 沒有改動它們。
上層:`219-field-provisioning.md` v2.8、`219-protocol.md` v0.6(本文件要求的改動見 §1.3,成為 v0.7)。
基準:Batman `main` f2f2bf6(= 1.5.12-wsl.2);firmware `build-3aplus` 527303e8 + `feat/254-ble` a5e181b7;02(10.41.1.1,slot B,wsl.2,無乙太網、無 BLE)、04(10.41.1.3,slot B,wsl.3 spike,OTS,乙太網在這台;**2026-10-19 起有 lab 公鑰,Q6**)。03 故障,階段 1 只做 Pi 4。

## 0. 一句話

BLE(spike 已驗)+ 非 root `batman-provd` + root `batman-provhelper`;helper 自己重算/驗證所有授權物件;p5 是擁有權 SoT,p5 的 prov 檔只有 `batman-config-save --prov-only` 一個寫入路徑;狀態只由 `prov.cbor.state` 決定;鎖定欄位:fresh overlay 由 96 寫(claimed/member 一律上鎖,p5 讀不到時看 p6 提示),執行期轉換由 helper 寫;legacy(02/04)升級後 OTA 閘與今天相同;member 的 OTA 閘看「arm 前本次開機是否曾入網」,綁 arm 那次開機的 boot_id,只在**真正的升級路徑**(procd 的第二次 validate)寫;**恢復出廠** = 執行期:凍結 → 停 payload、`apps/` 改名 → 作廢另一槽 → **在 p5 寫重置意圖(唯一的提交點)** → 清 overlay → 重開;下次開機:95 在任何人掛 p5/p6 之前把 p6、p5 都 mkfs(p5 最後,mkfs p5 = 完成紀錄)→ helper 產新身分。

## 1. 決策、範圍、事實

### 1.1 使用者決策(不變)

| # | 決策 | 後果 |
|---|---|---|
| U1 | 608B 留空;之後不重工 | keystore `file`/`se` |
| U2 | Go 節點 / Flutter + Rust app / BlueZ D-Bus | 向量 + `verify.py` 裁判 |
| U3 | 擁有權與 SSH 脫鉤 | 認領不碰 `authorized_keys`;dropbear 照跑(只關密碼);key 登入在上鎖後仍可用(dropbear `svr-authpasswd.c:94`) |
| U4 | 恢復出廠全清含身分 | 機身 QR 失效;新 QR 經 root 取得;hostname/SSID 依 MAC 產生、跨擁有者不變(殘項) |
| U5 | 改名探針待使用者 | ⚠️ |
| U6 | 3A+ 等新板 | 共用檔(`batman-slot`、`platform-ab.sh`、config-save、95、96、halow-setkey、autocommit、joinwatch)bcm2710 未測 |
| U7 | `uart_enable` typo 不動 | |

### 1.2 Reality check(v1–v5 R1–R71 保留;本輪新增 / 更正)

| # | 事實 | 證據 |
|---|---|---|
| R38–R42 | BLE spike 事實 | v3 §1.2;#254 留言 |
| R43 | fstools `jffs2reset`:提示在 `volume_find` 之前;掛載中走 PENDING + `overlay_delete`,下次開機再刪一次;**任何層級**的 dot 項目都不刪 | 原始碼;02/04 `.cache` |
| R62 | busybox 無 `find -delete`、無 `-exec {} +`;有 `-depth -name -exec CMD ;` | 04/02 實測;兩位 v5 reviewer 在 04 實跑 `find /overlay/upper -depth -name '.*' -exec echo {} \;` 命中 `.cache` |
| R63 | payload `metadata version=` 是組包時間戳,≠ `BATMAN_VERSION` | 04 實測 |
| **R64(更正)** | `sysupgrade:370` 在 `:403` 的 TEST exit **之前**就呼叫 `validate_firmware_image` → **`sysupgrade -T` 時父程序也是 sysupgrade**;真的升級還會在 install 之後由 **procd** 再 validate 一次(`platform-ab.sh` 註解「procd validates AFTER install_bin」;A5 在 04 的 ota-trace 看到兩次 S1 CHECK,caller 不同) | 我本次讀 firmware `package/base-files/files/sbin/sysupgrade:370,403`;A5 |
| R65 | joinwatch 在 `$RUNDIR/joinwatch.state` 即時寫 JOINED/NOT_JOINED | 原始碼 |
| R66 | `boot-reasons.log` 只有 batdata-mount 一個寫者,有 once-per-boot 閂(`95:632,708,753`);fresh trial 上 S10 就寫,早於 autocommit S99 → **D28 ✅** | A5 讀原始碼;B5 在 04 對過 |
| R67 | 95 在 fresh overlay 上以 uci-default 跑,最後 `"$INIT" boot`(`95` 尾段;「the S11 link was created after rcS enumerated it」);`boot()` 內 `[ -f "$RUNDIR/batdata-mount.booted" ] && return 0` 是 once-per-boot 閂,在 mount、resize 之後、pstore 搬移之前;pstore 搬移、boot-reasons 行、`fw_override_check`、`restore_payload_guardians` 依序在後 | 原始碼 `95-batman-storage:605-725,740-760` |
| R68 | #202 閘:p5 是 ext4 無 `.seeded` → `precheck-node`/stage 2 die(`batman-slot:534-547`) | 原始碼 |
| R70 | 04 harness 靠空密碼登入 | 實測 |
| R71 | procd 開機階段 init 無逾時;busybox 無 `timeout`;`flock` 有 | 原始碼 |
| **R72(更正)** | 02、04 **沒有 `tune2fs`**;**有** `/usr/sbin/blkid`、`/usr/bin/sgdisk`、`/usr/bin/hexdump`(v6 寫「沒有 blkid」是我照抄 v5 reviewer、沒上機查,錯);image 預設 root shadow = `root:::0`(空密碼);p5/p6 的 GPT 名稱 `PARTNAME=config` / `data`(`/sys/class/block/*/uevent`);busybox `mv -T` = 「目的地是目錄就拒絕」 | 我本次 02/04 實測 |
| **R73** | `batman-slot` 的 `slot_lock`(`:84-96`)只認 cmdline 含 `batman-slot` 的持有者,其他持有者會被接管;`invalidate-other` 的 EXIT trap 會刪鎖 → **helper 不可能「持有 slot_lock」** | A5/B5 讀原始碼 |
| **R74** | 協定 §3.4:已認領節點對第 1 則以常數時間**固定試 5 次** PSK;全部失敗 → 用真的新臨時金鑰送**格式正確的假第 2 則**、和真 session 一樣**等到逾時才斷**;協定 §8 全域交握每分鐘 20 次 | 我本次讀 `219-protocol.md:77-82` |

### 1.3 與上層不同處(→ 協定 v0.7 / 219 v2.9)

| 上層 | 本文件 | 理由 |
|---|---|---|
| 219 §6.1 認領寫 `authorized_keys` | 不寫 | U3 |
| 219 §6.3 schema 2 | 維持 1;`prov.cbor` + `prov.meta` | `96:131` |
| 219 §7 保留身分 | 全清 | U4 |
| 219 §6.9 BLE 健康 S4 | 階段 1 就加,`ble-ok` gating | |
| 協定 §3.5 | per-verb 用 `batman-owner-op-v1` | 一標籤一格式 |
| 協定 §7.1 首版 | 需 owner-op `network/join` | |
| 協定 §5.4 | helper 重算 ClientChal | |
| 協定 §3.3 | `device_id = hex(sn)` | |
| **協定 §3.4 PSK 候選** | 加一把 **`psk_replay = HKDF( ECDH(node_ecdh_priv, owner_enc_pub), "batman-psk-replay-v1" ‖ device_id )`**;app 端以 `ECDH(owner_enc_priv, node_ecdh_pub)` 算(`node_ecdh_pub` 是 app 認領時 TOFU pin 下來的 `node_cert` 裡的公開值)。**固定試 6 次**(4 把 `psk_owner` + `psk_member` + `psk_replay`,不足補假 PSK);失敗行為照 §3.4 不變(假第 2 則 + 等到逾時)。用 `psk_replay` 建立的 session 角色 =「擁有者候選(replay)」,只允許 `claim/replay` | 需要**擁有者加密私鑰**才連得上 → 只看過 QR 的人無法探測存在(A5-m7);不依賴 608B 對 `claim_secret` 做 KDF(D31 不再需要,B5-m6);608B 的 ECDH 槽本來就支援 ECDH(協定 §7.3) |
| 協定 §10 共用 Rust | Go / Rust | U2 |
| v1 開發 CA | 自簽 + TOFU | |

### 1.4 狀態機

```
legacy ──(claim + 防呆門)──▶ claimed ──(network/join)──▶ member ──(network/leave)──▶ claimed
unclaimed ─(claim)─▶ claimed
任何狀態 ──(factory reset 提交)──▶ resetting ──(下次開機 95 完成)──▶ unclaimed(新身分)
```

| 狀態 / 判決 | 定義 | AP、dropbear、lock | NEED_MESH(§6.4) | 認領 |
|---|---|---|---|---|
| `legacy` | prov.state | 全不動(96 4b 今天規則) | 今天的規則 | 開(防呆門) |
| `unclaimed` | prov.state | 不動(image 預設) | 0 | 每次開機開 |
| `claimed` | prov.state | 上鎖;AP:`radio_managed=0` 不動 / `=1` 關 | live key ≠ placeholder → 今天規則;否則 0 | 只 `claim/replay` |
| `member` | prov.state | 上鎖;AP 由網路 | §6.4 | 同上 |
| `resetting-pending` | p6 有 marker、p5 讀到 `none` | 不動(執行期,狀態未變);解凍依不變量 U |
| `reset-uncertain` | marker 在、p5 `unreadable`(或 F3 結果未知且重讀不到 `none`) | 上鎖(L);不 cancel | precheck-node 拒絕 OTA | 無;provd 只 `status/public` + `factory_reset.cancel` |
| `resetting` | p5 有 `.factory-reset` 意圖(含壞意圖) | **上鎖**(fresh:96;非 fresh:batdata-mount,§4.5 L) | precheck-node 拒絕 OTA | 無;provd 只 `status/public` |
| `unknown` | helper 判決 | p6 `prov-state` 最後的 state ∈ {claimed,member} → 上鎖;否則不動 | 今天的規則 | 無 |

## 2. 元件

```
手機 app ──BLE── bluetoothd(LE、無 agent、dbus root/provd)──D-Bus── batman-provd(uid provd,ujail)
                                                                        │ helper.sock(SEQPACKET,PEERCRED)
                                                                        ▼
                                                              batman-provhelper(root,procd S89)
                                                                ├─ keystore / 授權 / 交易
                                                                ├─ --boot:p5↔overlay 對帳;身分;未完的轉換;SD 標記;.txn
                                                                ├─ 恢復出廠執行期(F0–F5)
                                                                └─ health 檔、ble-ok
platform-ab.sh platform_check_image:只在 caller=procd 且 upg=y 時寫 p6 ota-armed.mesh
95/batdata-mount boot():p5 有 .factory-reset 意圖 → 在 mount p6 之前執行 W0–W2(只此一處破壞)
96(S10):prov 抄寫、claimed/member 上鎖
99zz(S10):fresh overlay 寫 prov-state(writer=99zz)
```

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| BLE 相關 | 同 v4 | | |
| `$RUNDIR/batman-prov.health` | helper | autocommit | |
| `$RUNDIR/prov-txn`(`<pid> <token>`) | helper:交易步驟 1 建、步驟 4 後刪 | config-save `--on-join` 讓路;帶 `--txn <token>` 相符不讓路;操作員 `--save` 等 ≤ 10 s | |
| `/etc/batman-prov/.txn`(overlay,fsync;`<token> <gen_from> <gen_to> <verb>` + 變更前的 wireless 值) | helper:步驟 1 寫、步驟 4 後刪 | helper `--boot`;config-save `--on-join`(存在 → rc 1,B5-m7) | |
| `/etc/batman-prov/identity/`、`prov.cbor`、`prov.meta`、`.stage/`、`.identity.tmp/`、`ssh_keys.added` | helper;fresh 時 96 抄 identity/prov | 96 4b、`--check` | |
| `/etc/.batman-prov-restore` | 96 | helper | |
| p5 `prov.*`、`identity/prov/` | **只有 `--prov-only`** | 96、`--prov-get`、`--check` | identity 經 `identity/prov.tmp/` rename |
| **p5 `.factory-reset`**(重置意圖;一行 `reset v=1 nonce=<hex16> slot=<A\|B> attempts=<n>`) | 依時段分:**建立**:config-save `--reset-intent`(F3,只由 helper,要求 p6 marker nonce 相同);**attempts+1**:batdata-mount W0(下次開機起);**消失**:batdata-mount W2 mkfs p5 | 95/batdata-mount、96、config-save、helper、`precheck-node` —— **全部用同一個解析函式** `/usr/lib/batman/reset-intent.sh`(格式不符 = 「壞意圖」,所有讀者一致:凍結 + 上鎖 + crit,不是「當作沒有」,B6-m4) | 唯一提交點;唯一觸發 |
| p5 其他(`.seeded`、overrides、lkg、dropbear identity、shadow-root) | config-save 既有模式 | 96 | |
| `/opt/batdata/state/prov-state`(`<boot_id> <writer> <last_known_state> <verdict> <members_n> <mesh_expect>`) | fresh S10:99zz;S89 起:helper。**`last_known_state` 只在讀到確定的 prov 時更新(兩個寫者都一樣)**;`verdict` 是本次判決(含 `unknown`、`resetting`) | autocommit、`halow-status` 讀 `verdict`;96 讀 `last_known_state` 當上鎖提示 | A6-m4 / B6-m8;96 時 p6 沒掛 = 沒有提示 → 今天的 4b(只在 p6 壞時發生,寫明) |
| `/opt/batdata/state/ble-ok` | helper | autocommit | |
| `/opt/batdata/state/ota-armed.mesh`(`<arm_boot_id8> <target_slot> joined\|radio`) | `platform_check_image`:**只在 caller=`/sbin/procd` 且 `upg=y`**(真正的升級路徑,R64);p6 已掛;先 `rm` 再 tmp+rename+sync | autocommit(arm_boot_id == `boot-reasons.log` 倒數第二行、slot 相符才採用);決策後刪 | A5-m1/B5-M4/B5-m11 |
| `/opt/batdata/state/mesh-expected`、`mesh-joined` | config-save / joinwatch;helper 在 leave 刪 | autocommit | |
| `$RUNDIR/joinwatch.lastjoined` | joinwatch | stage 1 | |
| `/opt/batdata/state/factory-reset.inprogress`(`<nonce> <step> <reason>`;flock 鎖這個檔) | helper(F1 建、F5 前更新、取消時刪) | config-save(存在 → 寫入模式拒寫)、`precheck-node`、guardian 範本 / firstload / dockerd / joinwatch init(存在 → 不啟動) | 只管 F1–F3 的「可撤銷期」;**不是觸發**(p6 會被 W1 清掉) |
| **`/etc/batman-reset.sentinel`**(overlay,**非 dot**,內容 = nonce) | helper F1 寫(fsync);**消失**:F4/W0 的 overlay 清除;**或** F3 rc 10(確定沒寫)時的撤銷。**p5 可能有意圖時絕不刪**(A7-M1/B7-M1) | batdata-mount W0/W1、helper | 正面判斷「overlay 有沒有清掉」(B6-M1);非 dot → fstools 會刪 |
| `$RUNDIR/reset.lock`(flock,root-only run dir) | helper(F0–F5、解凍、cancel)、`--reset-intent`、batdata-mount `reset_wipe()` | — | 不變量 U 的鎖;取代 v8 的 marker flock 與 `cfgsave.lock`(A8-m4/m7) |
| `/etc/batman-reset.locked`(overlay) | 因意圖而上鎖的一方(96 或 batdata-mount)touch | batdata-mount `boot()` 開頭(無意圖但存在 → 清 overlay 重開) | §4.5 |
| `/opt/batdata/apps` ↔ `/opt/batdata/apps.reset` | helper(F2 改名、取消時改回);W1 mkfs 一併清掉 | `restore_payload_guardians`(只看 `apps/`) | 讓 p6 上的 tenant 在可撤銷期與任何意外重開後都不會被拉起(B5-M1/A5-M1) |
| 鎖定欄位 | fresh S10:96;S89 起的轉換:helper(看實際值);**有意圖且非 fresh 的開機:batdata-mount**(S11,三者時段不重疊) | `halow-status` | |
| `/etc/batman-dev-open` | 操作員 / harness | 96、helper | 對 claimed/member 不生效 |
| live uci `wireless.*` | 執行期:`halow-setkey`;fresh:96 Lane B、99-chanfix、morse 回寫 | provd | 開機不對帳(只 `.txn` 一次性) |
| 另一槽 | `batman-slot`(apply、`invalidate-other`;**各自取鎖**,helper 不持鎖,R73) | | |
| 本槽 overlay | F4(helper)、W0(batdata-mount,哨兵還在時) | | |
| p6、p5 的格式化(重置用) | **只有 batdata-mount W1(p6)、W2(p5)**;既有的 95 首次 mkfs p6(未格式化的新分割)、config-save `--seed`/`--seed --reformat` 不變(A6-m7 更正「只有」) | | |
| SD 標記檔 | 實體;helper `--boot` 讀兩個 FAT(`batman-slot boot-devs`);F4 刪 | | |

## 4. 契約

### 4.1 helper socket 與授權

同 v5(= v4 + 改動),本輪改動:
- `claim.replay` 只接受 **`psk_replay` session**(§1.3 新定義);其餘條件同 v5(state ∈ {claimed,member}、單一擁有者、`owner_pub` 相符、CheckMac + owner-op;helper 計數每 boot 每小時 10 次)。
- `psks.get()` 回 `{psk_owner[≤4], psk_member, psk_replay, adv_owner, adv_member}`;`psk_replay` 由 helper 以 `ecdh.key` 與 `prov.cbor.owner.enc_pub` 在開機與 prov 變更時算出。
- `sign.*` 額度:**每條連線**各自 0.5/s、全域 2/s;同時連線 ≤ 2(既有);兩個路人 central 可以佔滿 2 條(協定 §8 既有界線),每連線額度只保護**已連上**的買家那條不被搶(A5-m8/A6-m10)。
- **app 契約(A6-m10/B6-m7)**:app 在送出 `claim/finish` **之前**,必須先持久化 `node_cert`(含 `ecdh_pub`)與 `claim-pending{device_id, owner_pub}`;否則回應遺失時算不出 `psk_replay`,replay 不可用。進 S5 app addendum 與協定 v0.7。
- **新動詞 `factory_reset.cancel(owner_op)`**:只在 `resetting-pending` 且不變量 U(§4.5)當下成立時執行,否則 `E_BUSY(cannot-confirm)`;resetting 模式下 provd 對 `status/public` 之外只放行它與 `factory_reset`(重新發起)。root 等價:`batman-provhelper --factory-reset-cancel`(同樣受 U 約束)。
- 誠實界線(同 v4/v5)。
- **負測試(依協定 §3.4 改寫,B5-M5)**:沒有正確 PSK 的 central 對已認領節點做 NXpsk0 → 收到格式正確、可解析為 Noise 第 2 則但 payload 為隨機資料的訊息,**解不出 `node_cert`**(不含 `sn`/DAC 結構),連線在交握逾時後才斷;與正確 PSK 的時間分佈在統計上不可分(記錄 50 次的回應時間)。DoS 上限沿用協定 §8(全域 20 次/分):**路人可以吃滿全域額度,這是協定既有的界線**,測試只斷言擁有者在路人停止後 10 s 內可連,並在 §8 列明。

### 4.2 keystore 與身分

同 v4(7 檔、rc 表),v5 改動保留(rc 15 = 意圖存在、identity 寫 `prov.tmp`、`ro` 優先),本輪改動:
- rc 15 時 helper:**不補 persist、不還原、不產生**;判 `resetting`,只開 `status/public`(95 下次開機會完成)。
- 恢復出廠完成後的第一次開機:p5 是空 ext4(rc 7)、overlay fresh(無 identity)→ 照 rc 7 規則產新身分。**沒有特例**(v5 的 `--clear-tombstone` 刪除)。

### 4.3 p5 與 `batman-config-save`(PR-P1,兩板共用)

```
p5/  schema_version=1, .seeded, overrides.uci, lkg/, identity/dropbear/*, shadow-root  (不變)
     identity/prov/{7 檔}, prov.cbor, prov.meta
     .factory-reset   ("reset v=1 nonce=<hex16> slot=<A|B> attempts=<n>"  ≤ 64 B;只在恢復出廠提交後到下次開機 W2 之間存在;解析一律用 reset-intent.sh)
```

| 模式 | 內容 |
|---|---|
| `--prov-only …` | 同 v5;`.factory-reset` 存在 → 拒寫(rc 1) |
| `--prov-get d` | 同 v5;`.factory-reset` 存在 → rc 15 |
| **`--reset-intent <nonce> --slot <A\|B>`**(新,取代 `--wipe-all`) | **rc 只有 0 / 10 / 11**(§4.5「F3 三態」):寫任何 p5 位元組之前的失敗(marker nonce 不符、LUKS、已掛載、`cfgsave.lock` 忙、rw 掛載失敗)= **10**;rename 之後的任何失敗 = **11**;寫入 + `ro` 讀回相同 = 0。不 mkfs。`--on-join` 等既有寫入模式鎖忙仍回 rc 1(不改) |
| `--on-join` / `--save` / `--seed` / `--if-healthy` | 同 v5;`.factory-reset`、p6 marker 或 overlay `.txn`(只 `--on-join`)存在 → rc 1 |
| `--check` | 同 v5;`.factory-reset` → `p5 resetting`(rc 5) |
| `final_rc` | `root:!` 視為已上鎖(v5) |

`96`(PR-P1):
- 每個出口寫 verdict(含 boot_id)。
- `.factory-reset` 存在(含壞意圖;fresh overlay 上看到 = W1/W2 失敗或 batdata-mount 沒跑到)→ verdict `resetting`、不還原任何東西、**一律上鎖**(`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`root:!`、`LOCKED`),exit(B6-M2/A6-m6:前任的秘密還在 p5/p6,image 預設是空密碼 root)。
- prov 抄寫在 `.seeded` 檢查之前(v4)。
- **上鎖在每一個出口之前判斷**,出口完整清單(A5-m10/B5-m3):`:64` bypass、`:67` 無 p5、`:71` 非 ext4、`:89-91` mount 失敗、`:93` 未 seed、正常結尾:
  - 讀得到 p5 `prov.meta` 且 state ∈ {claimed,member} → 上鎖;
  - 讀不到 p5(`:64/:67/:71/:89`)而 p6 `prov-state` 第 3 欄 ∈ {claimed,member} → 上鎖。**`prov-state` 的 `last_known_state`(第 3 欄)只在讀到確定的 prov 時更新,`unknown` 只寫 `verdict`(第 4 欄)**(兩個寫者同規則,v8 §3);
  - 上鎖 = `PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`LOCKED`,root 無 hash → `root:!`;dev-open 不豁免;
  - 其他 → 今天的 4b。

### 4.4 交易式 `state.apply`

同 v5,本輪改動:
- 步驟 1 寫 overlay `.txn` 後 **fsync 檔與目錄**;`.txn` 內含變更前的 wireless 值(mesh key、mesh_id、channel、AP key/disabled),首次 join 與 legacy 也有定義(B5-m7)。
- 步驟 6(開機見 `.txn`):gen_from → **在 helper 背景**(不阻塞 `--boot`、不阻塞 provd 啟動)等 `meshjoin_radio_up` 或 120 s,然後以 `halow-setkey`(會 persist)**改回 `.txn` 記錄的變更前值**,刪 `.txn`;gen_to → 補步驟 4–5。期間 `--on-join` 因 `.txn` 讓路。
- 操作員在 `.txn` 存在期間(秒級)跑的 `halow-setkey` 會被對帳改回:只在交易被斷電打斷時發生,寫進 halow-setkey 的警告與殘項(A5-m9)。

### 4.5 恢復出廠(v6 形狀不變;v9 收斂「解凍」為一條不變量)

**不變量 U(v9 的核心,A8-M1/B8-M1)**:**任何解凍**——撤銷(F 階段失敗)、`factory_reset.cancel`、以新 nonce 重新發起——**只在以下三件事同時成立時才允許**:
1. 持有重置鎖 `$RUNDIR/reset.lock`(root-only run dir 0700 裡的 `flock`;`batman-config-save --reset-intent` 自己也持這把鎖,所以孤兒 config-save 還在寫時 helper 拿不到 → 不解凍,A8 路 3);
2. 在鎖內以 `reset-intent.sh` **重讀** p5,結果是 `none`(p5 可讀且沒有意圖檔);`unreadable`、`bad`、`intent` 一律**不解凍**;
3. 沒有活著的 `batman-config-save --reset-intent` 程序(同 §4.5 程序判定的寫法:uid 0、主機 pid ns、argv 精確)。

不符合 U → 維持凍結;有意圖 → 只能往前完成(F4–F5 / W);讀不到 → `reset-uncertain`(凍結,status 顯示,等 p5 可讀或 bench)。**沒有任何路徑在「p5 可能有意圖」時刪哨兵、刪 marker、把 `apps.reset` 改回、啟動 tenant。**

**前置條件**(任一不成立 → `E_PRECOND(reason)`;SD 路徑保留標記、log、下次開機再試):committed 槽;tryboot 未 arm;p6 已掛、無 `batman-storage.crit`、p6 非 LUKS、`PARTNAME=data`;p5 ext4、非 LUKS、`PARTNAME=config`、ro 掛得起;`/overlay` **不是 tmpfs**(f2fs 或 ext4 都可,B8-m11);非 bypass;`batman-slot` 不在執行;`$RAM_ROOT/sbin/upgraded` 不存在(否則 `E_PRECOND(ota-residue)`「請先重開機」);**p5 讀到 `none`**(若已有意圖 → 走「接手既有意圖」,見下)。p6 壞的節點不能用恢復出廠,只能重燒卡。

**sysupgrade 程序判定**(F1 再查、§6.4 共用):`/proc/<pid>` uid 0、`/proc/<pid>/ns/pid` == `/proc/1/ns/pid`、腳本路徑 = `readlink -f` 解析 argv[1](相對路徑以 `/proc/<pid>/cwd` 為基準)後等於 `/sbin/sysupgrade`(B8-m7/A8-m11);負測試含「容器 root 偽造」與「相對路徑呼叫」。**§6.4 不再寫 `pgrep -f`**。

**marker**(`/opt/batdata/state/factory-reset.inprogress`,0600,`<nonce> <step> <f3> <resume_n>`):`step` **只增不減**;`f3` ∈ `-`(未呼叫)/ `called`(已呼叫,結果未知)/ `ok` / `notwritten`(rc 10)/ `uncertain`(rc 11);`resume_n` = helper 續做 F4 的次數。marker 的 flock 改為 `$RUNDIR/reset.lock`(非 root 程序碰不到,A8-m7)。

**執行期(helper)**

| 步 | 動作 | 失敗 |
|---|---|---|
| F0 | 取 `reset.lock`;產 `nonce`;`slot=$(batman-slot active)` | — |
| F1 | 寫 marker(`<nonce> 1 - 0`);寫哨兵 `/etc/batman-reset.sentinel`(fsync);`resetting-pending`;`joinwatch stop`;config-save 寫入模式拒寫;再查 sysupgrade 程序 / `upgraded` | 失敗 → 解凍(依 U;此時 p5 必為 `none`) |
| F2 | payload `stop`、`dockerd stop`、`mv -T apps apps.reset` | `mv` 失敗 → 解凍 |
| F2b | `batman-slot invalidate-other` | 失敗 → 解凍 |
| F3 | marker `step=3 f3=called`(**先寫再呼叫**)→ `batman-config-save --reset-intent <nonce> --slot <slot>` → marker `f3=<結果>` | 見 F3 三態 |
| F4 | marker step=4;刪 SD 標記;dot sweep;`rm -f /overlay/sysupgrade.tgz`;`jffs2reset -y` | 失敗 → log 繼續(W0 補做) |
| F5 | `sync; batman-slot reboot committed "factory reset"` | — |

**F3 三態**(rc 只有 0 / 10 / 11 / 12):
- **判準 = 「`rename(2)` 是否已被呼叫」**(B8-m3/A8-m1):tmp 檔與意圖**同目錄**、寫完 `fsync` tmp、`rename`、`fsync` 目錄(`/bin/fsync` 有)。rw 掛載寫 superblock 不影響判準(與「有沒有意圖檔」無關)。
- **0** = rename 完成且 `ro` 讀回內容相同;**10** = 還沒呼叫 rename 就停了(marker nonce 不符、LUKS、`reset.lock`/`cfgsave` 忙、已有 ro 讀者造成 rw 變 ro(#202 T11)、rw 掛不起、寫 tmp 失敗);**11** = rename 已呼叫之後的任何失敗;**12** = 開始時 p5 **已有**意圖(不寫、不覆蓋,B8-m3)。
- helper:**0** → F4;**11 / 逾時 / crash** → 當作已提交 → F4;**12** → 「接手既有意圖」(讀出其 nonce,改用它,F4–F5;不再寫新意圖,A8 路 2);**10** → 先**依 U 重讀**:`none` → 可重試的原因(忙、T11 的 ro 讀者)每 5 s 重試到 60 s,仍 10 → 解凍、`E_RESET(p5-busy)`(可重試,B8-m4/A8-m2);其他原因 → 解凍、`E_RESET(p5-unwritable)`「請換卡」;重讀**不是** `none` → 不解凍,依讀到的結果往前或 `reset-uncertain`。

**helper 啟動(開機或 respawn)判斷表**(解析器 4 種輸出 × marker,A8-M1/B8-M1/m5/m9):

| p6 | marker | p5(`reset-intent.sh`) | helper |
|---|---|---|---|
| 沒掛 | — | — | **不判 marker 不在**;`resetting`/`unknown` 依 p5;不寫 p6;status 顯示 `p6-unmounted`(B8-m9) |
| 掛 | 不在 | `none` | 正常 |
| 掛 | 不在 | `intent` | W1 已清過 p6、W2 未完成 → `resetting`(等下次開機 W2) |
| 掛 | 在 | `none` | `f3` ∈ {`-`,`notwritten`} → `resetting-pending`(可依 U 解凍 / cancel);`f3` ∈ {`called`,`uncertain`,`ok`} → **依 U 重讀**(鎖內、無孤兒):仍 `none` → `resetting-pending`(F3 真的沒寫成);否則照下列 |
| 掛 | 在 | `intent`(slot 相符) | 從 F4 續做,`resume_n`+1;`resume_n` > 3 → `reset-stuck resume`,停(B8-m5:S11 讀不到、S89 讀得到造成的迴圈) |
| 掛 | 在 | `intent`(slot 不符) | 不動;等 autocommit / fw_override 帶回(Wa) |
| 掛 | 任意 | `unreadable` | **`reset-uncertain`:凍結,不解凍、不 cancel**;status 顯示;等 p5 可讀(下次開機)或 bench(A8 路 1/B8-M1) |
| 掛 | 任意 | `bad` | 凍結;crit;bench |

- `factory_reset.cancel(owner_op)`:只在 `resetting-pending`,且**當下**依 U 成立才執行;否則 `E_BUSY(cannot-confirm)`。`resetting`、`reset-uncertain` 不放行 cancel(A8-m9 統一三處寫法)。
- 重新發起(`factory_reset(owner_op)`):`resetting-pending` 且 U 成立 → 從 F0;p5 有意圖 → 接手既有意圖(同 rc 12)。

**解凍**(只在 U 成立時):`mv -T apps.reset apps` → SD 觸發則刪標記 → 刪哨兵 → 刪 marker → 啟動 dockerd/guardian/joinwatch。

**下次開機(batdata-mount `reset_wipe()`,只由 `boot()` 呼叫)**

- S11 是序列執行,這時沒有 config-save / joinwatch / helper 在跑(joinwatch S98、helper S89);`reset_wipe()` 仍取 `$RUNDIR/reset.lock`(與 config-save 的 `cfgsave.lock` 無關;v8 說「取 cfgsave.lock」會被接管規則打破,刪除,A8-m4/B8-m2)。
- 解析器 `reset-intent.sh`:p5 以 `ro,nosuid,nodev,noexec` 掛(**不用 `noload`**:讓 journal replay,sync 之後、umount 之前斷電的意圖也讀得到;S11 時沒有其他人掛 p5)到 `$RUNDIR` 下的私有掛載點;檔案必須 `-f` 且非 `-L`;`head -c 65`(超過 64 B = bad);**恰好一行**;以欄位逐一檢查:`v=1`、`nonce` 長度 16 且 `case "$n" in *[!0-9a-f]*) bad`、`slot` ∈ {A,B}、`attempts` 純數字、可選 `p6uuid=<36 字元>`;**不用 `case` 的 `{16}` 量詞(ash glob 不支援,A8-m3)**、不 eval;回 `none`/`intent …`/`bad`/`unreadable`(mount 失敗或讀錯誤)。無逾時工具:SD 掛載卡住會卡住 S11,寫明為已知限制(與今天 95 掛 p6 相同等級,B8-m6)。
- 其餘讀者(96、config-save `--prov-get`/`--check`、`node_checks`)讀意圖時一律呼叫同一解析器;它們自己的 `noload` 掛載不用來判斷意圖(A8-m2)。

| 步 | 條件 / 動作 | 失敗 |
|---|---|---|
| — | `unreadable` → 今天的流程 + 上鎖(L);helper → `reset-uncertain` | — |
| Wb | `bad` → crit;不清、不掛 p6;上鎖(L) | — |
| Wa | slot 不符 → 不清;照常掛 p6;autocommit 見意圖不 commit;`node_checks` 拒 OTA | — |
| Wt | `/overlay` 是 tmpfs → crit;不清、不掛舊 p6;上鎖 | — |
| W0 | 哨兵在 → rw 掛 p5、attempts+1、fsync、讀回 → 成功且 ≤ 3 → dot sweep → `jffs2reset -y` → `batman-slot reboot committed` → `return`;否則 crit `reset-stuck overlay`、不清、不掛舊 p6、上鎖 | — |
| W1 | 哨兵不在:`blkid -s UUID -o value` p6(**不用掛載**)== 意圖的 `p6uuid` → 已清過,略過;否則守門 → mkfs p6 → 新 UUID 寫回意圖行(rw 掛 p5、tmp+fsync+rename、讀回)→ 掛新 p6 寫 `state/prov-state`(`last_known_state=resetting`,讓 W2 被打斷時 96 仍上鎖,A8-m5)→ 卸載。**前任無法預先種**:UUID 由這次 mkfs 產生(B8-m10) | mkfs 失敗 → crit、不掛舊 p6、不做 W2 |
| W2 | 守門 → mkfs p5 = 意圖消失 | 失敗 → crit;照常掛新 p6;上鎖 |
| W3 | 掛新 p6 …、寫 `log/factory-reset.log` completed;若 `/etc/batman-reset.locked` 存在 → 見下 | — |

**`/etc/batman-reset.locked` 規則(A8-m5/B8-m1,一般化)**:任何**因為意圖而上鎖**的一方(96 或 batdata-mount)都 touch 它。batdata-mount `boot()` 開頭:**沒有意圖、但 `.locked` 存在** → dot sweep + `jffs2reset -y` + `batman-slot reboot committed` + `return`(清掉「因重置而鎖、沒有 key」的 overlay,讓終態是 image 預設)。因為觸發條件是 `.locked` 本身、清 overlay 會刪掉它,所以 W2 與這次補清之間斷電也會在下次開機補做,且不會迴圈。W3 不再自己判斷。

**L(上鎖)**:fresh overlay 上 96、非 fresh 開機 batdata-mount;兩者都 touch `.locked`;值同 v8。§3 擁有權表登記鎖定欄位的第三個寫者 = batdata-mount(只在「有意圖且非 fresh」時,A8-m8/B8-m8)。

**p6 沒掛的開機**:guardian 範本、firstload、dockerd 的檢查 = 「marker 存在 **或** `/opt/batdata` 不是 mountpoint → 不啟動」;**joinwatch 只看 marker**(它原本就設計成 p6 沒掛也能跑,A8-m6);96、99zz、helper、autocommit **寫 p6 之前**先 `mountpoint -q /opt/batdata`,不是 → 不寫(B8-m9)。

- **結果斷言**(L16,在 04):同 v8。
- **負對照**:(a)–(n) 同 v8,新增:
  - (o) **rc 11 之後 F4 完成、下次開機 p5 白箱設為讀不到** → `reset-uncertain`、**cancel 被拒**;p5 恢復可讀後 W 完成(v8:可 cancel → 之後清 p6,A8-M1/B8-M1);
  - (p) p5 上已有舊意圖時重新發起 → rc 12 → 接手既有意圖(v8:rc 10 撤銷刪哨兵);
  - (q) F3 進行中 `kill -9` helper、config-save 繼續跑 → 新 helper 拿不到 `reset.lock` → 不解凍;config-save 結束後依 p5 結果決定(v8:讀到 none 就可 cancel);
  - (r) 寫 tmp 後、rename 前斷電 → 開機 p5 無意圖、tmp 殘檔被忽略(不同名)→ `resetting-pending`(f3=called)→ 依 U 重讀 `none` → 可解凍;
  - (s) W2 之後、`.locked` 補清之前斷電 → 下次開機補清一次 → 終態未上鎖的 image 預設;
  - (t) S11 讀不到、S89 讀得到的白箱 → `resume_n` 到 3 後停,不迴圈;
  - (u) 解析器:多行、65 B、symlink、FIFO、nonce 含大寫或非 hex → 全部 `bad`,不卡開機(FIFO 用 `-f` 擋)。
- **誠實界線**(A8-m12 補):重置擋不住**有 root 的前任**(他能改任何東西);卡住(W0/Wb/Wt)的節點 overlay 沒清,**前任的 SSH key 仍可登入**,直到 bench 處理。

### 4.6 BLE 平台、4.7 procd、4.8 GATT

同 v4,v5 的改動保留:無 S13 init;marker 檢查加在 `payload-guardian.sh` 的 `start_service`(image 範本)、`batman-ots-firstload` `boot()`、dockerd init(patch)、joinwatch init;§4.8 無匿名 NX 例外。

## 5. 生命週期矩陣

v4 L1–L39、v5 L40–L47 保留,以下改動:

| # | 路徑 | 階段 1 後(v6) | 測試(負對照) |
|---|---|---|---|
| L16 | 恢復出廠 | §4.5 v8 | (a)–(n);位置 = Q5(04) |
| L52 | `/overlay` 是 tmpfs ramoverlay 時恢復出廠 | 前置拒絕;W 階段 Wt 停 | (l) |
| L53 | F 各步驟中 helper respawn | §4.5 helper 啟動判斷表 | (k) |
| L54 | 執行期 `batdata-mount start/restart` | 不跑 W(只 `boot()` 跑) | 白箱 |
| L55 | 95 在寫 INIT 前 exit | W 不跑、意圖留著 → 上鎖、`resetting` | 白箱 |
| L56 | Wa 遇到 trial | autocommit 不 commit → deadline revert 回意圖槽 → W | 白箱 |
| L57 | 殺掉 app 後 `claim/replay` | app 契約(先存 `node_cert` + claim-pending)| `prov-claim-replay-254` 加 app 被殺的版本 |
| L35 | reset 前置 | 加 p6 非 LUKS、`batman-slot` 不在執行 | `prov-reset-precond-254` |
| L37 | reset 步驟失敗 | F 階段失敗 → 撤銷;W 階段失敗 → crit、下次開機重試、有上限 | (c)(d)(f) |
| L41 | `sysupgrade -T` / LuCI validate | caller ≠ procd → 不寫 `ota-armed.mesh` | `-T` 後檔案不存在(v5 會寫,B5-M4) |
| L42 | 直接 `batman-slot apply` | 無檔 → fail-closed | 同 v5 |
| L44 | unclaimed / 重置後 OTA | #202 閘 prov-aware:p5 `prov.meta` state=unclaimed → 不擋 | 同 v5 |
| L45 | reset 中 OTA | `precheck-node` 見 marker / 意圖拒絕;`-F` 例外寫明 | |
| L48 | F1–F2b 間斷電 | `resetting-pending`;tenant 不起來;可 cancel | (c) |
| L49 | F3 後、下次開機前 p5 壞掉 | §4.5 雙重故障殘項 | 白箱 |
| L50 | W0 overlay 清不掉 | attempts ≤ 3 | (f) |
| L51 | 現場入網後帶回家、沒重開就更新 | `lastjoined` 為真 → 要求鄰居 → revert;**說明書寫「先重開再更新」或用 `autocommit-hold-once`**(A5-m11/B5-m5);joinwatch 停用時退回當下 `meshjoin_joined` 單次取樣 | 白箱 |

## 6. 流程

### 6.1 認領、6.2 鎖定、6.3 建網
同 v5。

### 6.4 autocommit

同 v5,本輪改動:
- **stage 1 寫 `ota-armed.mesh` 的條件**:`platform_check_image` **rc=0** 且 `caller` 是 `/sbin/procd` 且 `upg=y`(`$RAM_ROOT/sbin/upgraded` 已安裝)**且**有一個活著的 sysupgrade 程序**(判定法見 §4.5「sysupgrade 程序判定」:uid 0、主機 pid ns、`readlink -f` 解析後的腳本路徑 = `/sbin/sysupgrade`;不用 `pgrep -f`;⚠️ bench 上以 `-T`、真 OTA、中止後 LuCI validate 各一次實證;`sysupgrade -T`、LuCI、sysupgrade 自己的第一次 validate(caller = sysupgrade)都不寫(B5-M4/A5-m1)。p6 未掛 → 不寫(讀端 fail-closed)。`rm` 舊檔失敗 → 拒絕 OTA;寫完 rename + `sync`(B5-m11)。
- D27 改為:「caller=procd 且 upg=y 且有活著的 sysupgrade 程序(uid 0、主機 pid ns、argv[1]=`/sbin/sysupgrade`)→ 視為真的升級」(單向蘊含,不宣稱等價),證據 = `platform-ab.sh` 既有的 `caller`/`upg` 欄位 + A5 在 04 ota-trace 看到的兩次 S1 CHECK;⚠️ PR-P1 在 bench 上以 `-T` 與真 OTA 各一次,記錄兩種 caller 實證。
- #133 stale-fallback 開機:autocommit 既有邏輯(非真 tryboot → 不 commit 不 revert)不變;`ota-armed.mesh` 只在真 tryboot 被讀(B5-m11)。

### 6.5 診斷、6.6 改名
同 v4。

## 7. 依賴與證據(v4 D1–D25、v5 D26–D32 保留,以下改動)

| # | 依賴 | 證據 | 狀態 |
|---|---|---|---|
| D27(更正) | 「caller=procd 且 upg=y」只在真的升級時成立 | `platform-ab.sh` caller/upg 欄位;`sysupgrade:370,403`;A5 ota-trace | ✅ 原始碼 / ⚠️ bench 兩種各一次 |
| D28 | `boot-reasons.log` 倒數第二行 = arm 的那次開機 | R66 | ✅ |
| D31 | 608B 對 claim_secret 做 KDF | **不再需要**(psk_replay 改用 ECDH) | — |
| D33 | 608B ECDH 槽可做 `ECDH(node_ecdh_priv, owner_enc_pub)` 並把共享秘密輸出給主機做 HKDF | 協定 §7.3「608B 這端:ECDH 指令可以輸出共享秘密給主機」 | ✅ 文件 / ⚠️ #255 實機 |
| D34 | W 階段只由 `boot()` 呼叫(rc 開機 + 95 首次),每次開機都檢查意圖;**不需要 `BATMAN_FIRSTBOOT`**(v6 的設計已在 v7 刪除) | 95 尾段 `"$INIT" boot`;`etc/init.d/boot` 刪 uci-default | ✅ |
| D35 | 02/04 **沒有** `tune2fs`、`timeout`、`stat`;**有** `blkid`、`sgdisk`、`hexdump`、`mountpoint`、`flock`、`pgrep`、`jffs2reset`、`mkfs.ext4` | R72 + A7/B7 實測 | ✅ |
| D36 | `mv` 同一 ext4 內目錄改名是原子的 | POSIX rename | ✅ |

## 8. 安全(v5 表保留,改動)

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| BLE 路人 | 拿 `node_cert` 追蹤 | psk_replay 需擁有者加密私鑰;失敗照 §3.4 送假第 2 則 | §4.1 |
| 只看過 QR 的人 | 探測節點是否在附近 / replay | psk_replay 不只靠 QR | §4.1 |
| BLE 路人 | 吃滿全域交握額度(20/分) | **擋不住,協定 §8 既有界線**;每連線簽章額度保護正在連的買家 | §4.1 |
| 前任擁有者 | 重置後殘留 | 95 單點 mkfs p6、p5;overlay 含 dot;`apps/` 在可撤銷期就改名 | L16 |
| 實體 SD | 放標記 / 改意圖檔 | 標記要 device_id;意圖:batdata-mount 只驗格式 + `slot`;nonce 只在 F3 寫入時與 p6 marker 比對(實體持有者本來能重燒卡,A6-m12) | |
| 我們自己 | 重置卡住、迴圈、只做一半 | F 階段可撤銷、W 階段單點且天然只做一次、W0 有上限 | (c)–(f) |

## 9. 測試

同 v5;追加 L48–L51;`prov-tools-254` 斷言 `find -depth -exec`、`mkfs.ext4`、`flock`、`jffs2reset`、`hexdump` 存在;BLE 負測試依 §4.1 改寫。

## 10. 實作切法

同 v5;PR-P1 改動:config-save `--reset-intent`(取代 `--wipe-all`);INITBODY `reset_wipe()`(只由 `boot()` 呼叫)+ `reset-intent.sh` 解析器 + 非 fresh 上鎖 + autocommit/`node_checks` 見意圖的處理 + guardian/firstload/dockerd/joinwatch 的「marker 或 p6 沒掛 → 不啟動」;helper 的 F0–F5 與撤銷;platform-ab 的 caller/upg 條件;協定 v0.7 的 `psk_replay`(ECDH)與固定 6 次。

## 11. 殘項

v5 殘項 + F3 後 p5 壞掉的雙重故障殘留(`apps.reset/`);W2 被打斷的 p5 要 bench 重做;`.txn` 期間操作員 setkey 會被改回;路人吃滿協定 §8 全域額度(協定層);D27/D30/D33 實證。

## 12. 待決

| # | 題 | 建議 |
|---|---|---|
| Q1–Q4 | 同 v4 | 定案 |
| Q5 | L16 位置與還原 | **定案(使用者 2026-10-19:遠端不能移線,選救得回來的)= 04**(有乙太網;02 重置後離網且無乙太網 = 救不回)。前置:先把 04 p6 要留的東西(OTS DB/憑證/docker image、dv289 備份)備份到主機;還原 = 經乙太網(重置後 image 預設空密碼)重裝 lab 公鑰 → `halow-setkey` 回 fleet → 重新部署 OTS。L16 等 PR-P3 實作完才排,排之前再列副作用給使用者 |。**v8 後果(A7,依「破壞性測試先列副作用」)**:恢復出廠的 F4 會清掉 04 的 lab 公鑰;若之後 W1/W2 失敗,04 會依「有意圖就上鎖」被鎖住:**沒有 key、沒有密碼 → 遠端救不回,要現場**;重置後 IP 是 image 的開機預設(10.41.254.x 隨機,之後 openmanetd 重保留),不是 10.41.1.3,要用 link-local / `.local` 找。排 L16 之前再請使用者確認
| Q6 | BLE 認領測試會把 04 上鎖 | **定案並已做(使用者同意,2026-10-19)**:04 `authorized_keys` = 02 同一把 lab ed25519(sha256 5bda8113…),key-only 登入驗過,lock-status 仍 UNPROVISIONED,已進 p5(`--check` fresh)。這也滿足 §6.1 legacy 防呆門 |

## 13. v8 審查 → v9 對應

| v8 發現 | 收法 |
|---|---|
| **A8-M1 / B8-M1** 解凍(helper 重啟判斷、cancel、重新發起)沒套「p5 可能有意圖」規則 | 不變量 U:鎖內重讀 p5 = `none` + 無孤兒 config-save 才解凍;marker step 只增、記 `f3` 結果;啟動判斷表逐格;`unreadable` → `reset-uncertain` 凍結、不 cancel;rc 12 接手既有意圖;負對照 (o)(p)(q)(r) |
| A8-m1 / B8-m3 rc 10/11 界線 | 判準 = `rename(2)` 是否已呼叫;tmp 同目錄 + fsync + rename + fsync 目錄;rc 12 = 已有意圖 |
| A8-m2 / B8-m6 noload、讀錯誤、T11 誤報 | 解析器用 `ro`(不 noload)、私有掛載點、`unreadable` 分開;其餘讀者共用解析器;T11 = rc 10 可重試;S11 掛載無逾時寫明 |
| A8-m3 `case {16}` | 逐欄檢查、`*[!0-9a-f]*`、恰好一行、≤ 64 B;負對照 (u) |
| A8-m4 / B8-m2 W0 的 cfgsave.lock | 刪;S11 序列執行 + `$RUNDIR/reset.lock` |
| A8-m5 / B8-m1 `.locked`、W3 順序、W2 中斷開放 | `.locked` 由兩個上鎖方都 touch;「無意圖但 `.locked` 在」是獨立觸發;W1 在新 p6 寫 `last_known_state=resetting`;負對照 (s) |
| A8-m6 joinwatch、寫者不查 mountpoint | joinwatch 只看 marker;96/99zz/helper/autocommit 寫 p6 前查 mountpoint |
| A8-m7 marker flock 可被非 root 搶 | 鎖改 `$RUNDIR/reset.lock`;marker 0600 |
| A8-m8 / B8-m8 §3 擁有權表 | 補 batdata-mount(第三寫者,限時段)、`.locked`、`reset.lock`、marker 新欄位、意圖 `p6uuid` |
| A8-m9 文件殘留 | §6.4 `pgrep -f` 刪;§4.3「只改第 2、1 欄」改為 `last_known_state` 規則;cancel 時段統一(只 `resetting-pending` 且 U 成立);R43 更正 |
| A8-m10 矩陣缺列 | L58 降版 / `-F` 時意圖還在:舊 image 沒有解析器 → 舊 96 照常還原前任(p5 未被清)、舊 batdata-mount 掛 p6(`apps.reset` 不會被拉起)→ 節點回前任狀態且未完成重置;寫明「重置進行中不要降版」,`node_checks` 拒絕、`-F` 為操作員責任。W0/W3 從 S11 經 procd shutdown 重開時 S12+ 不再跑(`rcS.c:197-203`)⚠️ bench 以 logread 實證 |
| A8-m11 / B8-m7 相對路徑 sysupgrade、容器 root 負測試 | `readlink -f` 以 cwd 解析 argv[1];負測試加兩項 |
| A8-m12 誠實界線 | 補 root 前任、卡住節點接受前任 key |
| B8-m4 T11 誤報換卡 | rc 10 可重試 |
| B8-m5 續做迴圈 | `resume_n` ≤ 3;負對照 (t) |
| B8-m9 p6 沒掛時寫者、helper 誤判 | 寫前查 mountpoint;啟動表第一列 |
| B8-m10 `reset-p6-wiped` 要掛舊 p6、可被預種 | 改用 `blkid` 讀 p6 UUID(不掛載)比對意圖裡的 `p6uuid` |
| B8-m11 Wt 誤擋 ext4 overlay | 條件改「是 tmpfs」 |
| B8-m12 rc 11 三種結果、app 契約 | 啟動表 + 負對照 (o)(r);app:F3 之後節點斷線 = 「已開始,請勿斷電」,重連後依 `info.reset` 顯示 |
