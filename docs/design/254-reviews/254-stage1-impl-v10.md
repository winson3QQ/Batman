# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v10**

狀態:第 9 輪 A、B 都是 **REJECT(窄)**,0 BLOCKER / 1 MAJOR(A 10、B 12 MINOR;`254-reviews/review-v9-{A,B}.md`,v9 全文 `254-reviews/254-stage1-impl-v9.md`)。兩位確認第 8 輪 MAJOR(解凍不變量)已關;又**各自**找到同一條 v9 新引入的回歸:S11 讀不到 p5 時,不看本機有沒有重置跡象就上鎖並建鎖記號 → 從沒重置過的節點被鎖、之後被清 overlay。v10:**解析器多一種 `n/a`**、**只有重置證據 E 成立才凍結/上鎖**、鎖記號觸發只認 `none`;修重置鎖的自鎖交接;並把恢復出廠**整節改為自足**(§4.5.1 起),§3 / §4.3 只指向它,停止「同 vN」造成的矛盾。§13 逐條。

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
| R43 | fstools `jffs2reset`:`ask_user()`(`jffs2reset.c:121`)在 `volume_find()`(`:134`)之前,「走到提示」**不能**證明找得到 volume(v3 的證據作廢);掛載中走 `fs_state_set(PENDING)` + `overlay_delete`(`:49-54`),`overlay_delete` 不回報刪除失敗;下次開機 PENDING 再刪一次(`overlay.c:444-455`);`glob("%s/*")` 無 `GLOB_PERIOD` → **任何層級**的 dot 項目都不刪 | 原始碼(兩位 reviewer 與 B9 再核);02/04 `.cache` 實測 |
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
| `resetting-pending` | p6 有 marker、解析器 `none` | 不動 | precheck-node 拒絕 OTA | 無;provd 只 `status/public`、cancel(U 成立時)、重新發起 |
| `reset-uncertain` | (marker 在 或 重置證據 E 成立)且 解析器 `unreadable` | 上鎖(§4.5.7) | precheck-node 拒絕 OTA | 無;**不 cancel** |
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
| p5 `.factory-reset`(意圖) | 見 §4.5.1 | 解析器 | |
| p5 其他(`.seeded`、overrides、lkg、dropbear identity、shadow-root) | config-save 既有模式 | 96 | |
| `/opt/batdata/state/prov-state`(`<boot_id> <writer> <last_known_state> <verdict> <members_n> <mesh_expect>`) | fresh S10:99zz;S89 起:helper;**重置中的 S11:batdata-mount W1**(寫 `resetting`)。`last_known_state` 只在讀到確定的 prov(或 W1 的 `resetting`)時更新;`unknown` 只寫 `verdict` | autocommit、`halow-status` 讀 `verdict`;96 讀 `last_known_state` | 寫前 `mountpoint -q` |
| `/opt/batdata/state/ble-ok` | helper | autocommit | |
| `/opt/batdata/state/ota-armed.mesh`(`<arm_boot_id8> <target_slot> joined\|radio`) | `platform_check_image`:**只在 caller=`/sbin/procd` 且 `upg=y`**(真正的升級路徑,R64);p6 已掛;先 `rm` 再 tmp+rename+sync | autocommit(arm_boot_id == `boot-reasons.log` 倒數第二行、slot 相符才採用);決策後刪 | A5-m1/B5-M4/B5-m11 |
| `/opt/batdata/state/mesh-expected`、`mesh-joined` | config-save / joinwatch;helper 在 leave 刪 | autocommit | |
| `$RUNDIR/joinwatch.lastjoined` | joinwatch | stage 1 | |
| p6 marker `factory-reset.inprogress` | 見 §4.5.1 | | |
| 哨兵 `/etc/batman-reset.sentinel` | 見 §4.5.1 | | |
| 重置鎖 `$RUNDIR/reset.lock` | 見 §4.5.2 | | |
| 鎖記號 `/etc/batman-reset.locked` | 見 §4.5.1、§4.5.7 | | |
| `/opt/batdata/apps` ↔ `/opt/batdata/apps.reset` | helper(F2 改名、取消時改回);W1 mkfs 一併清掉 | `restore_payload_guardians`(只看 `apps/`) | 讓 p6 上的 tenant 在可撤銷期與任何意外重開後都不會被拉起(B5-M1/A5-M1) |
| 鎖定欄位 | fresh S10:96;S89 起的轉換:helper(看實際值);因意圖 / 重置證據而上鎖:§4.5.7(fresh → 96、非 fresh → batdata-mount,以 96 檔是否還在判斷) | `halow-status` | |
| `/etc/batman-dev-open` | 操作員 / harness | 96、helper | 對 claimed/member 不生效 |
| live uci `wireless.*` | 執行期:`halow-setkey`;fresh:96 Lane B、99-chanfix、morse 回寫 | provd | 開機不對帳(只 `.txn` 一次性) |
| 另一槽 | `batman-slot`(apply、`invalidate-other`;**各自取鎖**,helper 不持鎖,R73) | | |
| 本槽 overlay | F4(helper)、W0 / R-locked(batdata-mount) | | |
| p6、p5 的格式化(重置用) | 只有 batdata-mount W1(p6)、W2(p5);既有 95 首次 mkfs、config-save `--seed` 不變 | | |
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
     .factory-reset   (格式見 §4.5.1;≤ 128 B;只在恢復出廠提交後到 W2 之間存在;解析一律用 reset-intent.sh)
```

| 模式 | 內容 |
|---|---|
| `--prov-only …` | 同 v5;`.factory-reset` 存在 → 拒寫(rc 1) |
| `--prov-get d` | 同 v5;`.factory-reset` 存在 → rc 15 |
| **`--reset-intent <nonce> --slot <A\|B>`** | 定義見 §4.5.5(rc 0 / 10 / 11 / 12、鎖 fd 交接、tmp 檔寫法)。既有寫入模式鎖忙仍回 rc 1(不改) |
| `--on-join` / `--save` / `--seed` / `--if-healthy` | 同 v5;`.factory-reset`、p6 marker 或 overlay `.txn`(只 `--on-join`)存在 → rc 1 |
| `--check` | 同 v5;`.factory-reset` → `p5 resetting`(rc 5) |
| `final_rc` | `root:!` 視為已上鎖(v5) |

`96`(PR-P1):
- 每個出口寫 verdict(含 boot_id)。
- 解析器回 `intent` 或 `bad` → verdict `resetting`、不還原任何東西、依 §4.5.7 上鎖(並 touch 鎖記號)、exit;回 `unreadable` 而 p6 的重置證據成立 → 同樣上鎖;回 `n/a` → 照 v4 rc 表的 `unknown` 處理,不因重置上鎖。
- prov 抄寫在 `.seeded` 檢查之前(v4)。
- **上鎖在每一個出口之前判斷**,出口完整清單(A5-m10/B5-m3):`:64` bypass、`:67` 無 p5、`:71` 非 ext4、`:89-91` mount 失敗、`:93` 未 seed、正常結尾:
  - 讀得到 p5 `prov.meta` 且 state ∈ {claimed,member} → 上鎖;
  - 讀不到 p5(`:64/:67/:71/:89`)而 p6 `prov-state` 的 `last_known_state` ∈ {claimed, member, resetting} → 上鎖(`resetting` 由 §4.5.6 W1 寫入)。
  - 上鎖 = `PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`LOCKED`,root 無 hash → `root:!`;dev-open 不豁免;
  - 其他 → 今天的 4b。

### 4.4 交易式 `state.apply`

同 v5,本輪改動:
- 步驟 1 寫 overlay `.txn` 後 **fsync 檔與目錄**;`.txn` 內含變更前的 wireless 值(mesh key、mesh_id、channel、AP key/disabled),首次 join 與 legacy 也有定義(B5-m7)。
- 步驟 6(開機見 `.txn`):gen_from → **在 helper 背景**(不阻塞 `--boot`、不阻塞 provd 啟動)等 `meshjoin_radio_up` 或 120 s,然後以 `halow-setkey`(會 persist)**改回 `.txn` 記錄的變更前值**,刪 `.txn`;gen_to → 補步驟 4–5。期間 `--on-join` 因 `.txn` 讓路。
- 操作員在 `.txn` 存在期間(秒級)跑的 `halow-setkey` 會被對帳改回:只在交易被斷電打斷時發生,寫進 halow-setkey 的警告與殘項(A5-m9)。

### 4.5 恢復出廠(v10:本節自足,不再引用前版;形狀同 v6–v9)

#### 4.5.1 名詞與資源(本節唯一定義;§3 的對應列只指向這裡)

| 資源 | 格式 / 位置 | 寫者(依時段) | 讀者 |
|---|---|---|---|
| **意圖** p5 `.factory-reset` | 一行,固定欄位順序 `reset v=1 nonce=<16 hex> slot=<A\|B> attempts=<1–3 位數字>[ p6uuid=<36 字元 [0-9a-f-]>]`,≤ **128 B**(含 p6uuid 實算 95 B,A9-m2) | F3:`--reset-intent`(建立);W0:attempts+1;W1:附 `p6uuid`;W2:mkfs p5 = 消失 | 解析器(所有讀者共用) |
| **解析器** `/usr/lib/batman/reset-intent.sh` | 輸出 5 種:`none`(p5 可讀、無意圖檔)/ `intent <nonce> <slot> <attempts> [<p6uuid>]` / `bad`(存在但不合格式)/ `unreadable`(p5 存在、是 ext4、非 LUKS,但掛不起或讀錯)/ **`n/a`(沒有 p5 分割、p5 非 ext4、或 LUKS,B9-M1/A9-m8)** | — | 95、batdata-mount、96、config-save、helper、`node_checks` |
| **marker** p6 `/opt/batdata/state/factory-reset.inprogress` | 0600,`<nonce> <step> <f3> <resume_n>`;`f3` ∈ `-`/`called`/`ok`/`notwritten`/`uncertain` | helper(F1 建立;每步更新;解凍時刪)。step 在**同一個 marker 的生命期內**只增不減;解凍會刪 marker,重新發起時建新 marker 從 1 開始(A9-m6/B9-m11 的矛盾消除) | helper、config-save、`node_checks`、guardian 範本 / firstload / dockerd / joinwatch init |
| **哨兵** overlay `/etc/batman-reset.sentinel` | 非 dot 檔,內容 nonce | helper F1 建立;**刪除者只有**:F4/W0 的 overlay 清除、以及 U 成立時的解凍 | batdata-mount、helper |
| **鎖記號** overlay `/etc/batman-reset.locked` | 空檔 | 依 §4.5.6 L 上鎖的一方 touch | batdata-mount |
| **重置鎖** `$RUNDIR/reset.lock` | `flock(2)`(busybox `flock` = flock(2),A9 實測);run dir 是 root 0700 tmpfs;程序死亡即釋放 | 見 §4.5.2 | — |
| **重置證據 E**(B9-M1/A9-M1) | 本機在做(或做過一半)重置的跡象:哨兵在 **或** 鎖記號在 **或** p6 marker 在 **或** p6 `prov-state` 的 `verdict`/`last_known_state` = `resetting` | — | batdata-mount、helper |

#### 4.5.2 重置鎖的持有與交接(A9-m1/B9-m1)

- helper 在 F0 以一個 fd(Go `os.File`)`flock(LOCK_EX)` 取鎖,直到 F5 或解凍結束。
- F3 呼叫 `batman-config-save --reset-intent` 時,**把這個 fd 當作 ExtraFiles 傳給子程序**,並設 `BATMAN_RESET_LOCK_FD=<n>`;config-save 見到這個 env 且 `flock -n <n>` 成功(同一 open file description,自己已持有)→ 不再另取。沒有這個 env → config-save 自己 `flock -w 10` 取鎖,取不到 → rc 10(忙)。
- 子程序繼承的 fd 讓**孤兒 config-save 繼續持鎖**:helper 死了、config-save 還在寫 → 新 helper 拿不到鎖 → U 不成立 → 不解凍(這是要的)。
- helper 的其他子程序一律不繼承(Go 預設 CLOEXEC);shell 端(batdata-mount)只在子 shell 內開鎖 fd:`( flock 9; … ) 9>"$RUNDIR/reset.lock"`,子 shell 結束即釋放,不被 `setsid sleep … &` 這類背景程序帶走(A9-m1 引 `batman-slot:773`)。
- **解析器本身不取鎖**(只讀)。
- `RDOK=0`(run dir 不可用,#280)→ 不能取鎖 → 恢復出廠一律 `E_PRECOND(no-rundir)`;W 階段在 `RDOK=0` 時只做 W0 之前的判斷並停住(凍結 + 上鎖),不清任何東西。
- 孤兒卡在 D-state(永遠不死、永遠持鎖)→ U 永遠不成立 → 歸 bench(寫明,A9-m9)。

#### 4.5.3 不變量 U(解凍唯一規則)

任何解凍(撤銷、`factory_reset.cancel`、以新 nonce 重新發起)只在同時成立時才做:
1. 持有重置鎖;
2. 鎖內以解析器重讀 p5 = `none`;**p5 已被其他程序掛著(在 `/proc/mounts`)→ 不讀,視為忙**(共用 superblock 可能讀到過時內容,A9-m5);
3. 沒有活著的 `--reset-intent` 程序。

不成立 → 凍結;有意圖 → 只能往前完成;`unreadable` → `reset-uncertain`。
解凍步驟本身**冪等**:`[ -d apps.reset ] && [ ! -e apps ] && mv -T apps.reset apps`;SD 標記、哨兵、marker 用 `rm -f`;服務 start 重複無害(A9-m9/B9-m11)。

#### 4.5.4 前置條件與 sysupgrade 程序判定

前置(任一不成立 → `E_PRECOND`):committed 槽;tryboot 未 arm;p6 已掛、無 `batman-storage.crit`、非 LUKS、`PARTNAME=data`;解析器回 `none`(回 `intent` → 接手,§4.5.5 F3 rc 12;`n/a` → `E_PRECOND(no-p5)`);`/overlay` 不是 tmpfs;非 bypass;`RDOK=1`;`batman-slot` 不在執行;`$RAM_ROOT/sbin/upgraded` 不存在(否則 `ota-residue`「請先重開機」)。p6 壞的節點不能用恢復出廠,只能重燒卡。
sysupgrade 程序判定:uid 0、`/proc/<pid>/ns/pid` == `/proc/1/ns/pid`、`readlink -f`(以 `/proc/<pid>/cwd` 為基準)解析 argv[1] == `/sbin/sysupgrade`。§6.4 的 D27 用同一定義。

#### 4.5.5 執行期(helper)

| 步 | 動作 | 失敗 |
|---|---|---|
| F0 | 取重置鎖;`nonce`;`slot` | — |
| F1 | marker `<nonce> 1 - 0`;哨兵(fsync 檔與目錄);`resetting-pending`;`joinwatch stop`;config-save 寫入模式拒寫;再查 sysupgrade 程序 / `upgraded` | 解凍(此時 p5 必為 `none`,U 成立) |
| F2 | payload `stop`、`dockerd stop`、`mv -T apps apps.reset` | `mv` 失敗 → 解凍 |
| F2b | `batman-slot invalidate-other` | 失敗 → 解凍 |
| F3 | marker `step=3 f3=called` → `--reset-intent <nonce> --slot <slot>`(帶鎖 fd)→ marker `f3=<結果>` | 見下 |
| F4 | marker step=4;刪 SD 標記;dot sweep;`rm -f /overlay/sysupgrade.tgz`;`jffs2reset -y` | 失敗 → log 繼續(W0 補做) |
| F5 | `sync; batman-slot reboot committed "factory reset"` | — |

**`--reset-intent` 的 rc**(判準 = `rename(2)` 是否已被呼叫):
- 寫法:`rm -f .factory-reset.tmp` → 寫 `.factory-reset.tmp`(同目錄、固定名稱)→ `fsync` 檔 → `rename` → `fsync -d` 目錄 → umount → `ro` 重掛讀回。
- **0** = 讀回相同;**10** = rename 之前停止(marker nonce 不符、LUKS、p5 已掛、鎖忙、rw 掛不起或掛成 ro(#202 T11)、寫 tmp 失敗);**11** = rename 呼叫之後的任何失敗;**12** = 開始時已有意圖(不寫、不覆蓋)。
- 解析器忽略 `.factory-reset.tmp`;下一次 `--reset-intent` 開頭 `rm -f` 它。

**helper 對 rc 的處理**:
- **0** → F4。
- **11 / 逾時 / crash** → 當已提交 → F4。
- **12**(接手既有意圖,A9-m6/B9-m6):意圖 slot ≠ active → `E_RESET(intent-other-slot)`,維持凍結(等槽被帶回);`bad` → 凍結 + crit;否則把 marker 與哨兵的 nonce 改寫成意圖的 nonce → F4。
- **10** → 依 U 重讀:`none` 且原因是「忙 / T11」→ 每 5 s 重試到 60 s,仍 10 → 解凍、`E_RESET(p5-busy)`(可重試);`none` 且其他原因 → 解凍、`E_RESET(p5-unwritable)`「請換卡」;重讀不是 `none` → 不解凍,依結果往前或 `reset-uncertain`。

**helper 啟動判斷表**(開機與 respawn;p6 有沒有掛 × marker × 解析器 × E):

| p6 | marker | 解析器 | helper |
|---|---|---|---|
| 沒掛 | — | 任意 | 不寫 p6;依解析器:`intent`/`bad` → `resetting` 凍結;其他 → `unknown`;status `p6-unmounted` |
| 掛 | 不在 | `none` / `n/a` | 正常(`n/a` → `unknown(no-p5…)`,同 v4 rc 表) |
| 掛 | 不在 | `intent` | W1 已清 p6、W2 未完成 → `resetting` |
| 掛 | 不在 | `unreadable` | **E 不成立 → `unknown(p5-unreadable)`,不凍結**(B9-M1:從沒重置過的節點不受影響);E 成立(哨兵或鎖記號)→ `reset-uncertain` |
| 掛 | 在 | `none` | `f3` ∈ {`-`,`notwritten`} → `resetting-pending`;否則依 U 重讀,仍 `none` → `resetting-pending` |
| 掛 | 在 | `intent`(slot 相符) | 從 F4 續做,`resume_n`+1;> 3 → `reset-stuck resume` |
| 掛 | 在 | `intent`(slot 不符) | 不動,等槽帶回 |
| 掛 | 在 | `unreadable` | `reset-uncertain`:凍結、不 cancel |
| 掛 | 任意 | `bad` | 凍結;crit;bench |
| 掛 | 在 | `n/a` | 不可能由 F 階段產生(前置要求 p5 可讀);crit `reset-marker-no-p5`,解凍(U 的第 2 條改以「`n/a` = 不可能有意圖」成立) |

- cancel:只在 `resetting-pending` 且 U 當下成立。重新發起:`resetting-pending` 且 U 成立 → 刪舊 marker、從 F0;解析器回 `intent` → rc 12 接手。

#### 4.5.6 下次開機(batdata-mount `reset_wipe()`,只由 `boot()` 呼叫)

位置:`boot()` 最前面,LUKS open 之後、掛 p6 之前、閂之前。`batdata-mount start/restart` 不呼叫。95 本體見解析器 `intent`/`bad` → 略過步驟 3/3b,步驟 4(寫 INIT)照做,步驟 5 呼叫 `boot()`。95 在寫 INIT 之前就 exit → W 不跑(意圖留著 → 96 上鎖)。

**fresh 與非 fresh**(B9-m5):`/etc/uci-defaults/96-batman-config-migrate` 還在 = 本 overlay 的 96 還沒跑 = fresh(96 稍後會依意圖上鎖);不在 = 非 fresh(batdata-mount 自己上鎖)。這決定 §4.5.7 L 由誰做,三個寫者因此不重疊。

**解析器結果 → 動作**:

| 解析器 | 動作 |
|---|---|
| `none` | 若鎖記號在 → **R-locked**(下述);否則今天的流程 |
| `n/a` | 今天的流程(不凍結、不上鎖;96 依 v4 rc 表處理 `unknown`)。鎖記號在也**不**觸發 R-locked(只認 `none`,B9-M1) |
| `unreadable` | 先以 `ro` 掛 p6 到私有點讀 E 的 p6 部分(marker、prov-state),卸載 → **E 成立** → 凍結:不掛 p6、上鎖(L);**E 不成立** → 今天的流程(不上鎖、不建鎖記號,A9-M1/B9-M1) |
| `bad` | crit;不清、不掛 p6;上鎖(L) |
| `intent` | Wa → Wt → W0 → W1 → W2(下表) |

| 步 | 條件 / 動作 | 失敗 |
|---|---|---|
| Wa | slot ≠ `batman_slot` → 不清;照常掛 p6;autocommit 見意圖不 commit;`node_checks` 拒 OTA | — |
| Wt | `/overlay` 是 tmpfs → crit;不清、不掛舊 p6;上鎖 | — |
| W0 | 哨兵在 → 子 shell 取重置鎖 → rw 掛 p5、attempts+1、fsync、讀回 → 放鎖 → 成功且 ≤ 3 → dot sweep → `jffs2reset -y` → **確認 `/overlay/upper/etc/batman-reset.sentinel` 已不存在**(jffs2reset 不回報刪除失敗,B9-m3/A9-m4)→ 是 → `batman-slot reboot committed` → `return`;否則 crit `reset-stuck overlay`,不清、不掛舊 p6、上鎖、**不重開** | 不會無限重開 |
| W1 | 哨兵不在:`blkid -p -s UUID -o value` p6(`-p` 不用快取,A9/B9-m8)== 意圖 `p6uuid` → 略過;否則守門 → mkfs p6 → 取新 UUID(`blkid -p`;格式不合 → crit,不寫回)→ 子 shell 取鎖 → 寫回意圖行(tmp + fsync + rename + 讀回;失敗 → crit,下次開機 p6 會再清一次,冪等)→ 掛新 p6 寫 `state/prov-state`(`verdict=resetting last_known_state=resetting`)→ 卸載 | mkfs 失敗 → crit、不掛舊 p6、不做 W2 |
| W2 | 守門 → mkfs p5 = 意圖消失 → **若鎖記號在 → 同一次開機立刻 R-locked**(不等下次,A9-m4/B9-m2) | 失敗 → crit;照常掛新 p6;上鎖 |

**R-locked**(鎖記號在、解析器 `none`):dot sweep → `jffs2reset -y` → 確認 `/overlay/upper/etc/batman-reset.locked` 已不存在 → 是 → `batman-slot reboot committed` → `return`;否則 crit `reset-stuck locked`、**不重開**(B9-m3)。W2 與 R-locked 之間斷電 → 下次開機解析器 `none` + 鎖記號在 → 補做;清掉就不會再觸發 → 無迴圈。

#### 4.5.7 L(因意圖或重置證據而上鎖)

- 執行者:fresh overlay → 96;非 fresh → batdata-mount。
- 內容:`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、root 無 hash → `root:!`、touch 鎖記號。
- `lock-status` 只在 p6 **已掛**時寫;batdata-mount 在凍結(不掛 p6)時不寫,改寫 `$RUNDIR/lock-status.override`,`halow-status` 優先讀它(B9-m12)。
- 96 的提示集合:p5 讀不到時,p6 `prov-state` 的 `last_known_state` ∈ {claimed, member, **resetting**} → 上鎖(A9-m3/B9-m4;W1 寫的 `resetting` 因此有讀者)。

#### 4.5.8 p6 沒掛的開機

- guardian 範本、firstload、dockerd 的檢查:「marker 存在 **或** `/opt/batdata` 不是 mountpoint → 不啟動」。
- joinwatch 只看 marker。
- 96、99zz、helper、autocommit 寫 p6 前先 `mountpoint -q /opt/batdata`。

#### 4.5.9 降版與 `-F`(L58,A9-m7/B9-m10)

- 重置進行中(marker 或意圖存在)時,`node_checks` 拒絕任何 OTA,包括降版。
- 若操作員以 `-F` 降版到沒有本功能的 image:舊 96 會還原前任(p5 還沒被清),舊 batdata-mount 會掛 p6(`apps.reset` 不會被拉起)。節點回到前任狀態,重置沒有完成。**之後只要升回有本功能的 image 寫進意圖槽,W 就會在那次開機執行**——可能是幾個月後,而且沒有提示。
- 處置:新 image 的 stage 1 遇到意圖時,不是單純拒絕,而是印出 `REFUSING: a factory reset from <nonce> is pending — it will wipe this node on the next boot of slot <slot>; finish it (reboot) or cancel it first`;`-F` 仍是操作員責任。寫進 §5 矩陣 L58。

#### 4.5.10 結果斷言與負對照(L16,在 04)

- **結果斷言**:同 v8,另加 `blkid -p` 看 p5/p6 UUID 都換了、哨兵與鎖記號都不存在、p6 `log/factory-reset.log` 有 completed、終態未上鎖(image 預設)。
- **負對照**:(a)–(u) 沿用 v8/v9 的定義(定義搬入 PR-P1 的測試計畫檔),其中:(m) 改用 `p6uuid`;(n) 加「容器 root」「相對路徑」。新增:
  - (v) 從沒重置過的節點,白箱讓 p5 掛不起一次 → **不上鎖、沒有鎖記號**;p5 恢復後 overlay **沒被清**(v9:上鎖 + 之後被清,A9-M1/B9-M1);
  - (w) LUKS / 無 p5 的 image → 解析器 `n/a`、正常開機;
  - (x) F3 帶鎖 fd 的交接 → 一次成功(v9 照字面:rc 10 永遠失敗,A9-m1/B9-m1);
  - (y) jffs2reset 刪不掉鎖記號(白箱 chattr 或 bind-mount 唯讀)→ 不重開、crit;
  - (z) 意圖行含 `p6uuid`(95 B)→ 解析為 `intent`,不是 `bad`。
- **誠實界線**:同 v9。

### 4.6 BLE 平台、4.7 procd、4.8 GATT

同 v4,v5 的改動保留:無 S13 init;marker 檢查加在 `payload-guardian.sh` 的 `start_service`(image 範本)、`batman-ots-firstload` `boot()`、dockerd init(patch)、joinwatch init;§4.8 無匿名 NX 例外。

## 5. 生命週期矩陣

v4 L1–L39、v5 L40–L47 保留,以下改動:

| # | 路徑 | 階段 1 後(v6) | 測試(負對照) |
|---|---|---|---|
| L16 | 恢復出廠 | §4.5(v10) | §4.5.10 (a)–(z);位置 = Q5(04) |
| L58 | 重置進行中降版 / `-F` | §4.5.9:`node_checks` 拒絕並說明;`-F` 後回前任狀態,之後升回意圖槽時 W 執行 | 白箱 |
| L52 | `/overlay` 是 tmpfs ramoverlay 時恢復出廠 | 前置拒絕;W 階段 Wt 停 | (l) |
| L53 | F 各步驟中 helper respawn | §4.5 helper 啟動判斷表 | (k) |
| L54 | 執行期 `batdata-mount start/restart` | 不跑 W(只 `boot()` 跑) | 白箱 |
| L55 | 95 在寫 INIT 前 exit | W 不跑、意圖留著 → 上鎖、`resetting` | 白箱 |
| L56 | Wa 遇到 trial | autocommit 不 commit → deadline revert 回意圖槽 → W | 白箱 |
| L57 | 殺掉 app 後 `claim/replay` | app 契約(先存 `node_cert` + claim-pending)| `prov-claim-replay-254` 加 app 被殺的版本 |
| L35 | reset 前置 | 加 p6 非 LUKS、`batman-slot` 不在執行 | `prov-reset-precond-254` |
| L37 | reset 步驟失敗 | F 階段:依不變量 U 解凍或凍結;W 階段:crit、凍結、上鎖、不重開(§4.5.6) | (c)(d)(f)(h)(y) |
| L41 | `sysupgrade -T` / LuCI validate | caller ≠ procd → 不寫 `ota-armed.mesh` | `-T` 後檔案不存在(v5 會寫,B5-M4) |
| L42 | 直接 `batman-slot apply` | 無檔 → fail-closed | 同 v5 |
| L44 | unclaimed / 重置後 OTA | #202 閘 prov-aware:p5 `prov.meta` state=unclaimed → 不擋 | 同 v5 |
| L45 | reset 中 OTA | `precheck-node` 見 marker / 意圖拒絕;`-F` 例外寫明 | |
| L48 | F1–F2b 間斷電 | `resetting-pending`;tenant 不起來;cancel 只在 U 成立時 | (c)(r) |
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

## 13. v9 審查 → v10 對應

| v9 發現 | 收法 |
|---|---|
| **A9-M1 / B9-M1** `unreadable` 不看本機跡象就上鎖、建鎖記號 → 健康節點被鎖、之後被清 | 解析器加 `n/a`;重置證據 E(§4.5.1);`unreadable` 只在 E 成立時凍結/上鎖;鎖記號觸發只認 `none`;helper 表 `unreadable` 依 E 分列;負對照 (v)(w) |
| A9-m1 / B9-m1 重置鎖自鎖、fd 繼承、RDOK=0 | §4.5.2:鎖 fd 經 ExtraFiles 傳給 config-save;孤兒繼續持鎖;CLOEXEC;shell 端子 shell;解析器不取鎖;RDOK=0 → 前置拒絕 / W 停住;負對照 (x) |
| A9-m2 意圖行 64 B 與 p6uuid 衝突 | 上限 128 B;負對照 (z) |
| A9-m3 / B9-m4 `resetting` 沒有讀者 | 96 提示集合加 `resetting`;§3 登記 W1 為 prov-state 的重置時段寫者 |
| A9-m4 / B9-m2 / B9-m3 鎖記號:無意圖定義、同次開機、刪不掉迴圈 | 只認 `none`;W2 成功同一次開機立刻 R-locked;重開前確認檔案已消失,否則不重開;負對照 (y) |
| A9-m5 共用 superblock | U 第 2 條:p5 已被掛 → 視為忙 |
| A9-m6 / B9-m6 / B9-m11 接手、step 單調 | rc 12 三分支(slot 不符、bad、改寫 nonce);step 只在同一 marker 生命期內單調,解凍刪 marker |
| A9-m7 / B9-m10 L58 | §4.5.9 + §5 L58;stage 1 遇意圖印出 pending 的後果 |
| A9-m8 / B9-m8 / B9-m9 解析器與 tmp 細節 | `n/a`;固定欄位順序;attempts 1–3 位;`blkid -p`;`p6uuid` 字元集;寫回失敗處理;tmp 固定名、先 `rm -f`;切欄前 `set -f` |
| A9-m9 解凍冪等、D-state 孤兒 | §4.5.3 冪等寫法;D-state 歸 bench |
| A9-m10 / B9-m7 文件矛盾 | 恢復出廠整節自足(§4.5.1–§4.5.10);§3 / §4.3 各列只指向 §4.5;§1.4 兩列重寫;R43 實際更正;L16/L37/L48 重寫;(m) 改 `p6uuid` |
| B9-m5 fresh / 非 fresh 判定 | 以 `/etc/uci-defaults/96-batman-config-migrate` 是否還在判斷(§4.5.6) |
| B9-m12 凍結時 `lock-status` 舊值 | 凍結時寫 `$RUNDIR/lock-status.override`,`halow-status` 優先讀 |
