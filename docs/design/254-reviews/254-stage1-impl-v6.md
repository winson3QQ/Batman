# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v6**

狀態:v5 兩位 REJECT,但都是 0 BLOCKER(A:3 MAJOR / 12 MINOR;B:5 MAJOR / 12 MINOR;`254-reviews/review-v5-{A,B}.md`,v5 全文 `254-reviews/254-stage1-impl-v5.md`)。兩位**獨立**判斷:OTA 閘、`state.apply` 交易、claim/replay、96 上鎖已收斂,只剩局部 MINOR;**恢復出廠沒有收斂**:每一輪都在它的「下次開機 mkfs」觸發契約上長出 MAJOR,根因是一個可續做的流程,狀態分散在 p5 tombstone、p6 marker 兩個媒體、四個元件,而 p6 的 mkfs 又會清掉自己的狀態檔。v6 照兩位的建議**只做刪減**:

- **執行期**只做可以撤銷的事,然後寫一個意圖;
- **破壞動作**只放在下次開機一個地方(95/batdata-mount 的 `boot()`),在任何人掛 p5/p6 之前做;
- 以 p5 被 mkfs 這件事本身當「做完」的紀錄,所以天然只做一次。

刪掉的機制:R4 的重試與取消、`step ≥ 4` 觸發、`--wipe-all` 與它的前提鏈、`--clear-tombstone`、「SD 標記在無身分時接受任何內容」、「持有 slot_lock」的說法。§13 列 v5 每條的收法。

**文件結構**:本文件是完整設計;標「同 v4」的小節(BLE 平台 §4.6、procd §4.7、GATT §4.8、診斷 §6.5、keystore 細節)內容在 `254-reviews/254-stage1-impl-v4.md`,v5 與 v6 都沒有改動它們。
上層:`219-field-provisioning.md` v2.8、`219-protocol.md` v0.6(本文件要求的改動見 §1.3,成為 v0.7)。
基準:Batman `main` f2f2bf6(= 1.5.12-wsl.2);firmware `build-3aplus` 527303e8 + `feat/254-ble` a5e181b7;02(10.41.1.1,slot B,wsl.2,無乙太網 carrier、無 BLE)、04(10.41.1.3,slot B,wsl.3 spike,OTS,乙太網在這台)。03 故障,階段 1 只做 Pi 4。

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
| **R72** | **02、04 都沒有 `tune2fs`、沒有 `blkid`**;ext4 superblock UUID 在 offset 1024+104(16 B),可用 `hexdump` 讀 | B5 實測;96 註解「blkid/od absent」 |
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
| `resetting-pending` | p6 有 `factory-reset.inprogress`、p5 **還沒**有意圖 | 不動 | precheck-node 拒絕 OTA | 無;provd 只 `status/public` + `factory_reset.cancel` |
| `resetting` | p5 有 `.factory-reset` 意圖 | 不動 | precheck-node 拒絕 OTA | 無;provd 只 `status/public` |
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
| **p5 `.factory-reset`**(重置意圖;一行 `reset v=1 nonce=<hex16> attempts=<n>`) | **寫**:config-save `--reset-intent <nonce>`(只由 helper 在 F3 呼叫,要求 p6 marker 的 nonce 相同);**更新 attempts**:95 W0;**消失**:95 W2 mkfs p5 | 95、96、config-save、helper、`precheck-node` | 唯一提交點;唯一觸發 |
| p5 其他(`.seeded`、overrides、lkg、dropbear identity、shadow-root) | config-save 既有模式 | 96 | |
| `/opt/batdata/state/prov-state`(`<boot_id> <writer> <state> <members_n> <mesh_expect>`) | fresh S10:99zz;S89 起:helper | autocommit、96(上鎖提示)、`halow-status` | |
| `/opt/batdata/state/ble-ok` | helper | autocommit | |
| `/opt/batdata/state/ota-armed.mesh`(`<arm_boot_id8> <target_slot> joined\|radio`) | `platform_check_image`:**只在 caller=`/sbin/procd` 且 `upg=y`**(真正的升級路徑,R64);p6 已掛;先 `rm` 再 tmp+rename+sync | autocommit(arm_boot_id == `boot-reasons.log` 倒數第二行、slot 相符才採用);決策後刪 | A5-m1/B5-M4/B5-m11 |
| `/opt/batdata/state/mesh-expected`、`mesh-joined` | config-save / joinwatch;helper 在 leave 刪 | autocommit | |
| `$RUNDIR/joinwatch.lastjoined` | joinwatch | stage 1 | |
| `/opt/batdata/state/factory-reset.inprogress`(`<nonce> <step> <reason>`;flock 鎖這個檔) | helper(F1 建、F5 前更新、取消時刪) | config-save(存在 → 寫入模式拒寫)、`precheck-node`、guardian 範本 / firstload / dockerd / joinwatch init(存在 → 不啟動) | 只管 F1–F3 的「可撤銷期」;**不是觸發**(p6 會被 W1 清掉) |
| `/opt/batdata/apps` ↔ `/opt/batdata/apps.reset` | helper(F2 改名、取消時改回);W1 mkfs 一併清掉 | `restore_payload_guardians`(只看 `apps/`) | 讓 p6 上的 tenant 在可撤銷期與任何意外重開後都不會被拉起(B5-M1/A5-M1) |
| 鎖定欄位 | fresh S10:96;S89 起的轉換:helper(看實際值) | `halow-status` | |
| `/etc/batman-dev-open` | 操作員 / harness | 96、helper | 對 claimed/member 不生效 |
| live uci `wireless.*` | 執行期:`halow-setkey`;fresh:96 Lane B、99-chanfix、morse 回寫 | provd | 開機不對帳(只 `.txn` 一次性) |
| 另一槽 | `batman-slot`(apply、`invalidate-other`;**各自取鎖**,helper 不持鎖,R73) | | |
| 本槽 overlay | F4(helper)、W0(95,非 fresh 時) | | |
| p6、p5 的格式化 | **只有 95 W1(p6)、W2(p5)** | | |
| SD 標記檔 | 實體;helper `--boot` 讀兩個 FAT(`batman-slot boot-devs`);F4 刪 | | |

## 4. 契約

### 4.1 helper socket 與授權

同 v5(= v4 + 改動),本輪改動:
- `claim.replay` 只接受 **`psk_replay` session**(§1.3 新定義);其餘條件同 v5(state ∈ {claimed,member}、單一擁有者、`owner_pub` 相符、CheckMac + owner-op;helper 計數每 boot 每小時 10 次)。
- `psks.get()` 回 `{psk_owner[≤4], psk_member, psk_replay, adv_owner, adv_member}`;`psk_replay` 由 helper 以 `ecdh.key` 與 `prov.cbor.owner.enc_pub` 在開機與 prov 變更時算出。
- `sign.*` 額度:**每條連線**各自 0.5/s、全域 2/s;同時連線 ≤ 2(既有)→ 路人最多佔一條,買家那條的額度不被搶(A5-m8)。
- **新動詞 `factory_reset.cancel(owner_op)`**:只在 `resetting-pending`(F1–F2)可用;resetting 模式下 provd 對 `status/public` 之外**只放行這一個**(B5-M1)。root 等價:`batman-provhelper --factory-reset-cancel`。
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
     .factory-reset   ("reset v=1 nonce=<hex16> attempts=<n>"  ≤ 64 B;只在恢復出廠提交後到下次開機 W2 之間存在)
```

| 模式 | 內容 |
|---|---|
| `--prov-only …` | 同 v5;`.factory-reset` 存在 → 拒寫(rc 1) |
| `--prov-get d` | 同 v5;`.factory-reset` 存在 → rc 15 |
| **`--reset-intent <nonce>`**(新,取代 `--wipe-all`) | 前提:p6 marker 存在且 nonce 相同(否則 rc 1);p5 offset 0 不是 LUKS(rc 1);未掛載(rc 8);rw 掛載(驗 rw)→ 寫 `.factory-reset`(tmp + rename)→ sync → umount → **ro 重掛讀回**內容相同才 rc 0;否則 rc 1。不 mkfs |
| `--on-join` / `--save` / `--seed` / `--if-healthy` | 同 v5;`.factory-reset`、p6 marker 或 overlay `.txn`(只 `--on-join`)存在 → rc 1 |
| `--check` | 同 v5;`.factory-reset` → `p5 resetting`(rc 5) |
| `final_rc` | `root:!` 視為已上鎖(v5) |

`96`(PR-P1):
- 每個出口寫 verdict(含 boot_id)。
- `.factory-reset` 存在(fresh overlay 上不該看到:95 W2 已 mkfs;看到 = W1–W2 失敗)→ verdict `resetting`、不還原任何東西、不上鎖、exit。
- prov 抄寫在 `.seeded` 檢查之前(v4)。
- **上鎖在每一個出口之前判斷**,出口完整清單(A5-m10/B5-m3):`:64` bypass、`:67` 無 p5、`:71` 非 ext4、`:89-91` mount 失敗、`:93` 未 seed、正常結尾:
  - 讀得到 p5 `prov.meta` 且 state ∈ {claimed,member} → 上鎖;
  - 讀不到 p5(`:64/:67/:71/:89`)而 p6 `prov-state` 第 3 欄 ∈ {claimed,member} → 上鎖。**`prov-state` 的 `unknown` 不覆寫上一次的 claimed/member**:helper 判 `unknown` 時只改第 2、1 欄(writer、boot_id),第 3 欄保留最後一次確定的 state(B5-m3);
  - 上鎖 = `PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`LOCKED`,root 無 hash → `root:!`;dev-open 不豁免;
  - 其他 → 今天的 4b。

### 4.4 交易式 `state.apply`

同 v5,本輪改動:
- 步驟 1 寫 overlay `.txn` 後 **fsync 檔與目錄**;`.txn` 內含變更前的 wireless 值(mesh key、mesh_id、channel、AP key/disabled),首次 join 與 legacy 也有定義(B5-m7)。
- 步驟 6(開機見 `.txn`):gen_from → **在 helper 背景**(不阻塞 `--boot`、不阻塞 provd 啟動)等 `meshjoin_radio_up` 或 120 s,然後以 `halow-setkey`(會 persist)**改回 `.txn` 記錄的變更前值**,刪 `.txn`;gen_to → 補步驟 4–5。期間 `--on-join` 因 `.txn` 讓路。
- 操作員在 `.txn` 存在期間(秒級)跑的 `halow-setkey` 會被對帳改回:只在交易被斷電打斷時發生,寫進 halow-setkey 的警告與殘項(A5-m9)。

### 4.5 恢復出廠(v6 重寫:執行期可撤銷 + 單一提交點 + 下次開機單點破壞)

**前置條件**(任一不成立 → `E_PRECOND(reason)`;SD 路徑保留標記、log、下次開機再試):committed 槽;tryboot 未 arm;p6 已掛、無 `batman-storage.crit`、**p6 非 LUKS**;p5 是 ext4、非 LUKS、ro 掛得起;非 bypass;**`batman-slot` 不在執行**(`slot_lock` 目錄不存在)。不宣稱持有 slot_lock(R73);改由 `precheck-node` 見 marker / 意圖時拒絕 OTA,`sysupgrade -F` 會忽略這個拒絕,寫明是操作員自己的選擇(A5-m3/B5-m2)。

**執行期(helper,provd 在、節點仍在網上)**

| 步 | 動作 | 失敗 |
|---|---|---|
| F0 | 產 `nonce`(16 hex) | — |
| F1 | 寫 p6 marker(`<nonce> 1 -`,flock);provd 進 `resetting-pending`;`/etc/init.d/joinwatch stop`;config-save 寫入模式從此拒寫 | 寫不進 p6 → 中止 |
| F2 | 每個 `/etc/init.d/batman-payload-*` `stop`;`/etc/init.d/dockerd stop`;`mv /opt/batdata/apps /opt/batdata/apps.reset`(同一 fs,原子) | stop 失敗 → log 繼續;`mv` 失敗 → **撤銷**(見下)、`E_RESET(apps-busy)` |
| F2b | `batman-slot invalidate-other`(自己取 slot_lock;自算 ZERO_MB;同 v4/v5) | 任何失敗 → **撤銷**、`E_RESET(other-slot)`(A5-m4:不再「繼續」) |
| F3 | **提交點**:marker step=3 → `batman-config-save --reset-intent <nonce>`(寫 p5 意圖並讀回) | rc≠0 → **撤銷**、`E_RESET(p5-unwritable)`,app 顯示「記憶卡設定區寫不進去,請換卡」(A5/B5 建議:p5 壞 = 停,不再宣稱「新身分可認領」) |
| F4 | 刪 SD 標記(兩個 FAT,刪不掉 log);`find /overlay/upper -depth -name '.*' -exec rm -rf {} \;`;`rm -f /overlay/sysupgrade.tgz`;`jffs2reset -y` | 失敗 → log 繼續(W0 會補做) |
| F5 | `sync; reboot` | — |

- **撤銷**(F1–F2b 任一失敗,或 `factory_reset.cancel`,只在 F3 之前可用):`mv apps.reset apps`(若已改名)→ **若由 SD 標記觸發,刪兩個 FAT 上的標記**(否則下次開機又觸發)→ 刪 marker → 啟動 dockerd、guardian、joinwatch → provd 回原狀態。**後果寫明**:F2b 若已作廢另一槽,撤銷後**沒有回退槽**,直到下一次 OTA 寫入(A5-m12)。
- F3 之後**不可取消**(app 顯示「已開始,請勿斷電」)。
- F1–F2b 之間斷電:下次開機 marker 在、`apps/` 已改名或還沒改名 → dockerd/guardian/joinwatch 見 marker 不啟動,`restore_payload_guardians` 看不到 `apps/` → 沒有 tenant 起來;helper `--boot` 見 marker 但 p5 無意圖 → `resetting-pending`,provd 開 `status/public` + cancel;擁有者可以 cancel 或重新發起(重新發起從 F0 開始,冪等:`apps.reset` 已存在就略過 mv)。
- F3 之後斷電:p5 有意圖 → 下次開機由 95 完成(下表)。

**下次開機(95/batdata-mount 的 `boot()`,只此一處破壞)**

放在 `boot()` **最前面**:LUKS open 之後、**mount p6 之前**、once-per-boot 閂、pstore 搬移、boot-reasons 行、`fw_override_check`、`restore_payload_guardians` 之前(A5-m6/B5-m8)。讀意圖:ro 掛 p5(同 `p5_never_seeded()` 寫法)讀 `.factory-reset`(regular file、`head -c 64`、格式 `reset v=1 nonce=[0-9a-f]{16} attempts=[0-9]+`,不符 → 當作沒有並 crit)。沒有意圖 → 照今天的流程。

| 步 | 條件 / 動作 | 失敗 |
|---|---|---|
| W0 | **overlay 不是 fresh**(`boot()` 不是由 95 uci-default 以 `BATMAN_FIRSTBOOT=1` 呼叫 = F4 沒完成):`attempts < 3` → rw 掛 p5 把 attempts+1 → `find /overlay/upper -depth -name '.*' -exec rm -rf {} \;` → `jffs2reset -y` → `reboot`;`attempts ≥ 3` → crit `reset-stuck overlay`,**不清 p5/p6**,繼續開機(p5 意圖仍在 → 凍結、helper `resetting`、status 顯示;需要重燒卡) | 有上限,不會無限重開(B5-m9) |
| W1 | overlay 是 fresh:`assert_not_system "$DEV"`(既有守門)→ `mkfs.ext4 -F -b 4096 -L <label> -m 0` p6 | 失敗 → crit `reset p6-mkfs-failed`,**不掛舊 p6**、不做 W2(意圖保留,下次開機重試);節點以無 p6 開機(B5-m8) |
| W2 | `mkfs.ext4` p5(**最後做;p5 被格式化 = 意圖消失 = 完成紀錄**) | 失敗 → crit `reset p5-mkfs-failed`;意圖可能還在 → 下次開機 W1 會再清一次 p6(冪等) |
| W3 | 照今天的流程繼續:mount 新 p6、閂、pstore 搬移(這次開機的 ramoops)、boot-reasons 行、`fw_override_check`、`restore_payload_guardians`(p6 是空的,沒有東西) | — |

- **天然只做一次**(B5-M3/A5-M3):同一次開機 95 uci-default 與 S11 init 都會呼叫 `boot()`;第一次呼叫在 W2 把 p5 格式化,第二次呼叫讀不到意圖 → 不做。之後的開機也讀不到。沒有「直到 S89 helper 清掉」的窗口,也沒有 device_id 條件(與 `se` 後端的 device_id 不變無關)。
- **斷電點**:W1 中 / W1–W2 間 → 下次開機 95 uci-default(沒跑完 = 沒被刪)再跑 → 意圖還在 → W1 再清(冪等)→ W2;W2 中 → mkfs 被打斷的 p5:magic 可能不是 ext4 → 下次 95 讀意圖失敗(當作沒有)→ 96 `:71` 非 ext4 → `unknown(p5-not-ext4)`,p6 已清、overlay fresh、新身分無法 persist → 需要換卡或 bench 重做 `--seed --reformat`(極少見,寫明)。
- 之後 96(S10,95 之後):p5 空 ext4 未 seed → 今天的預設;99 重新個人化;helper(S89):rc 7、overlay 無 identity → 產新身分 → `prov{unclaimed}` → 窗口開。
- **p5 在 F3 之後、下次開機之前壞掉**:95 讀不到意圖 → 不清 p6;但 `apps/` 已在 F2 改名 → 沒有 tenant 起來;overlay 已在 F4 清掉;96 讀不到 p5 → `unknown`,p6 `prov-state` 提示 → 上鎖;**殘留**:p6 上 `apps.reset/` 與 docker 資料(前任 tenant 資料,未啟動)。雙重故障,列殘項並在 status 顯示 `reset-incomplete p5-unreadable`(helper 看到 `apps.reset` 而 p5 讀不到)。
- **95 自己的規則**:95 的「never mkfs a pre-made data partition」改寫為「…除非 p5 有恢復出廠意圖(只有 helper 的 F3 會寫,且需要 p6 marker 的 nonce 相同)」;`p5-config-partition.md`、`201-firstboot-grow.md` 同步(A5-m6/B5-m8)。#201 的 grow 在 W1 之前已完成(partition table 層),mkfs 後的 fs 本來就填滿分割,3b 的 resize 無事可做。Pi 3:`p5_never_seeded()` 的寫法兩板相同;bcm2710 ❌ 未測。
- **時間**:W1(27 GB p6,lazy init)+ W2(512 MB p5)預估 10–30 s,在 S10 阻塞(R71);⚠️ 實測待 L16。
- **結果斷言**(L16;B5-m1/A5-m2 更正):重開後 `info.state=unclaimed`、`device_id` 新、舊 `claim.secret` 無效、`authorized_keys` 不存在、root shadow = image 預設、hostname == 依 MAC 的預設、**p6 與 p5 的 ext4 UUID(`hexdump -s 1128 -n 16`)都與重置前不同**、p6 無 `apps/`、`apps.reset/`、`docker/` 內容、`find /overlay/upper -name '.*'` 為空、另一槽 BATMAN-BAD、`/etc/init.d/batman-payload-*` 不存在、`docker ps -a` 空、舊 SSH 金鑰被拒。不比時間(時鐘是假的)。
- **負對照**:(a) v2 流程上同組斷言失敗;(b) v4 的 `find -delete` → `unrecognized`(已證);(c) F1–F2b 間 `reboot -f` → 沒有 tenant 起來、cancel 後完全回原狀(v5:p6 被 mkfs、重置被忘記,B5-M1);(d) F3 白箱讓 p5 唯讀 → `E_RESET(p5-unwritable)`、撤銷後原狀(v5:p5-dead 繼續,A5-M2/B5-M2);(e) W1 後 `reboot -f` → 下次開機只再清一次、完成;同一次開機兩次 `boot()` 只格式化一次(v5:S11 會再 mkfs,B5-M3);(f) F4 前 `reboot -f` → W0 補清 overlay 後完成;W0 白箱讓 jffs2reset 失敗 → 3 次後停、不再重開。
- **SD 標記**:檔名 `batman-factory-reset`、兩個 FAT、內容第一行 = 本機 `device_id`,或 `any`(只在 `/etc/batman-dev-open` 存在時接受);**沒有身分(overlay 與 p5 都沒有)時不接受**(B5 建議;實體持有者可以重燒卡);讀檔 `head -c 64`、字元集、regular file;由 helper `--boot` 讀;觸發後走 F0–F5;F4 刪標記,刪不掉時重開後 device_id 已不同 → 忽略,不會迴圈(B5-m4/A5-m5)。

### 4.6 BLE 平台、4.7 procd、4.8 GATT

同 v4,v5 的改動保留:無 S13 init;marker 檢查加在 `payload-guardian.sh` 的 `start_service`(image 範本)、`batman-ots-firstload` `boot()`、dockerd init(patch)、joinwatch init;§4.8 無匿名 NX 例外。

## 5. 生命週期矩陣

v4 L1–L39、v5 L40–L47 保留,以下改動:

| # | 路徑 | 階段 1 後(v6) | 測試(負對照) |
|---|---|---|---|
| L16 | 恢復出廠 | §4.5 v6 | (a)–(f);位置 = Q5 |
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
- **stage 1 寫 `ota-armed.mesh` 的條件**:`platform_check_image` 的 `caller` 是 `/sbin/procd` **且** `upg=y`(`$RAM_ROOT/sbin/upgraded` 已安裝,= 真的要升級的那次 validate);`sysupgrade -T`、LuCI、sysupgrade 自己的第一次 validate(caller = sysupgrade)都不寫(B5-M4/A5-m1)。p6 未掛 → 不寫(讀端 fail-closed)。`rm` 舊檔失敗 → 拒絕 OTA;寫完 rename + `sync`(B5-m11)。
- D27 改為:「caller=procd 且 upg=y ⇔ 真的升級」,證據 = `platform-ab.sh` 既有的 `caller`/`upg` 欄位 + A5 在 04 ota-trace 看到的兩次 S1 CHECK;⚠️ PR-P1 在 bench 上以 `-T` 與真 OTA 各一次,記錄兩種 caller 實證。
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
| D34 | `boot()` 能分辨「由 95 uci-default 呼叫(fresh)」與「S11 init 呼叫」 | 95 尾段 `"$INIT" boot`;改成 `BATMAN_FIRSTBOOT=1 "$INIT" boot`(我們的程式) | ✅ 設計 |
| D35 | 02/04 無 `tune2fs`/`blkid`;UUID 用 hexdump | R72 | ✅ |
| D36 | `mv` 同一 ext4 內目錄改名是原子的 | POSIX rename | ✅ |

## 8. 安全(v5 表保留,改動)

| Actor | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| BLE 路人 | 拿 `node_cert` 追蹤 | psk_replay 需擁有者加密私鑰;失敗照 §3.4 送假第 2 則 | §4.1 |
| 只看過 QR 的人 | 探測節點是否在附近 / replay | psk_replay 不只靠 QR | §4.1 |
| BLE 路人 | 吃滿全域交握額度(20/分) | **擋不住,協定 §8 既有界線**;每連線簽章額度保護正在連的買家 | §4.1 |
| 前任擁有者 | 重置後殘留 | 95 單點 mkfs p6、p5;overlay 含 dot;`apps/` 在可撤銷期就改名 | L16 |
| 實體 SD | 放標記 / 改意圖檔 | 標記要 device_id;意圖要格式 + p6 marker nonce(實體持有者本來能重燒卡) | |
| 我們自己 | 重置卡住、迴圈、只做一半 | F 階段可撤銷、W 階段單點且天然只做一次、W0 有上限 | (c)–(f) |

## 9. 測試

同 v5;追加 L48–L51;`prov-tools-254` 斷言 `find -depth -exec`、`mkfs.ext4`、`flock`、`jffs2reset`、`hexdump` 存在;BLE 負測試依 §4.1 改寫。

## 10. 實作切法

同 v5;PR-P1 改動:config-save `--reset-intent`(取代 `--wipe-all`);95 init body `boot()` 最前面加 W0–W2 + `BATMAN_FIRSTBOOT=1`;helper 的 F0–F5 與撤銷;platform-ab 的 caller/upg 條件;協定 v0.7 的 `psk_replay`(ECDH)與固定 6 次。

## 11. 殘項

v5 殘項 + F3 後 p5 壞掉的雙重故障殘留(`apps.reset/`);W2 被打斷的 p5 要 bench 重做;`.txn` 期間操作員 setkey 會被改回;路人吃滿協定 §8 全域額度(協定層);D27/D30/D33 實證。

## 12. 待決

| # | 題 | 建議 |
|---|---|---|
| Q1–Q4 | 同 v4 | 定案 |
| Q5 | L16 位置與還原 | 02 升 BLE build + p1/p3;L16 期間乙太網線移到 02 |
| Q6 | BLE 認領測試會把 04 上鎖 | 認領測試前在 04 裝 lab key(上鎖後 key 登入仍可用);需使用者同意 |

## 13. v5 審查 → v6 對應

| v5 發現 | 收法 |
|---|---|
| A5-M1 / B5-M1 step=4 在 mkfs 前寫 → 重開一次 p6 被清、重置被忘、取消不通 | 觸發只剩 p5 意圖(F3 寫,是唯一提交點);F3 前只做可撤銷的事;`apps/` 改名;cancel 動詞在 resetting-pending 放行 |
| A5-M2 / B5-M2 p5-dead 終點矛盾 | F3 寫不進 p5 → 撤銷 + 「請換卡」;不再宣稱新身分可認領;F3 後 p5 壞 = 雙重故障殘項 |
| A5-M3 / B5-M3 mkfs 沒有一次性閂 | 95 單點、p5 最後格式化 = 意圖消失 = 天然一次;沒有 device_id 條件 |
| B5-M4 / A5-m1 `-T` 也寫 | 只在 caller=procd 且 upg=y |
| B5-M5 BLE 負測試違反 §3.4 | 改成假第 2 則 + 逾時;固定試 6 次;DoS 上限寫明為協定 §8 界線 |
| A5-m2 / B5-m1 tune2fs、假時鐘 | hexdump 比 UUID |
| A5-m3 / B5-m2 slot_lock | 不再宣稱;前置條件 + precheck-node 拒絕 |
| A5-m4 R3 失敗繼續 | 改為撤銷 |
| A5-m5 / B5-m4 fresh 判定、SD 迴圈 | `BATMAN_FIRSTBOOT=1`;刪「無身分接受任何內容」;F4 刪標記,device_id 改變後忽略 |
| A5-m6 / B5-m8 95 放置、規則、LUKS | `boot()` 最前面;規則與文件同步;p6/p5 LUKS 前置拒絕;mkfs 失敗不掛舊 p6 |
| A5-m7 / B5-m6 psk_replay 綁 device_id、608B KDF | 改 ECDH(owner_enc) 導出;D31 刪 |
| A5-m8 簽章額度 | 每連線額度 |
| A5-m9 / B5-m7 `.txn` | fsync;存變更前值;背景對帳;`--on-join` 讓路;殘項寫明 |
| A5-m10 / B5-m3 96 出口、提示衰減 | 完整出口清單;unknown 不覆寫第 3 欄 |
| A5-m11 / B5-m5 帶回家更新 | L51 說明書 + hold-once;joinwatch 停用退回單次取樣 |
| A5-m12 取消後果 | 寫明無回退槽;SD 標記在 F4 才刪,取消時保留 → 會再觸發,寫明(取消時一併刪 SD 標記) |
| B5-m9 jffs2reset 失敗迴圈 | W0 attempts ≤ 3 |
| B5-m10 tombstone 格式、清不掉 | 一份格式;不再有 clear-tombstone(W2 mkfs 就是清) |
| B5-m11 stage 1 p6 未掛、sync、stale-fallback | §6.4 |
| B5-m12 R6 之後的 dot 檔 | app 路徑不產生;root 互動 session 的 `.ash_history` 等列殘項 |
