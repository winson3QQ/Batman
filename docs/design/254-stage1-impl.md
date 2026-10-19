# Design: #254 階段 1 實作 — BLE 平台、keystore、p5 `prov`、`batman-provd` 程序模型 — **v7**

狀態:第 6 輪 A **APPROVE-WITH-CHANGES**(0 BLOCKER / 0 MAJOR / 12 MINOR,判定恢復出廠已收斂);B **REJECT(窄)**(0 BLOCKER / 2 MAJOR / 11 MINOR,「形狀已經對了,剩下都在 W 階段的失敗路徑」)。報告 `254-reviews/review-v6-{A,B}.md`,v6 全文 `254-reviews/254-stage1-impl-v6.md`。v7 **不加機制**,只修:
- **B6-M1 / A6-m2**:W0 的「非 fresh = overlay 沒清」不成立(95 跑一次就被刪,之後 `boot()` 只由 S11 init 呼叫)→ 改成**正面哨兵**:F1 在 overlay 放一個非 dot 的哨兵檔,它還在 = overlay 沒清;attempts 寫不進 p5 就停;停住時不掛舊 p6。
- **B6-M2 / A6-m6**:有重置意圖時 96 不上鎖(fail-open)→ **有意圖就上鎖**。
- A6-m1(意圖要記 slot)、A6-m3(helper 在 F3 後 crash 誰完成 F4–F5)與其餘 MINOR。§13 逐條。

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
| `resetting-pending` | p6 有 `factory-reset.inprogress`、p5 **還沒**有意圖 | 不動(執行期,狀態未變) | precheck-node 拒絕 OTA | 無;provd 只 `status/public` + `factory_reset.cancel` |
| `resetting` | p5 有 `.factory-reset` 意圖(含壞意圖) | **上鎖**(96,B6-M2) | precheck-node 拒絕 OTA | 無;provd 只 `status/public` |
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
| **`/etc/batman-reset.sentinel`**(overlay,**非 dot**,內容 = nonce) | helper F1 寫(fsync);**消失**只靠 overlay 被清(F4 的 jffs2reset 或 W0) | batdata-mount W0/W1、helper | 正面判斷「overlay 有沒有清掉」(B6-M1);非 dot → fstools 會刪 |
| `/opt/batdata/apps` ↔ `/opt/batdata/apps.reset` | helper(F2 改名、取消時改回);W1 mkfs 一併清掉 | `restore_payload_guardians`(只看 `apps/`) | 讓 p6 上的 tenant 在可撤銷期與任何意外重開後都不會被拉起(B5-M1/A5-M1) |
| 鎖定欄位 | fresh S10:96;S89 起的轉換:helper(看實際值) | `halow-status` | |
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
- `.factory-reset` 存在(含壞意圖;fresh overlay 上看到 = W1/W2 失敗或 batdata-mount 沒跑到)→ verdict `resetting`、不還原任何東西、**一律上鎖**(`PasswordAuth=off`、`RootPasswordAuth=off`、`ttylogin=1`、`root:!`、`LOCKED`),exit(B6-M2/A6-m6:前任的秘密還在 p5/p6,image 預設是空密碼 root)。
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

### 4.5 恢復出廠(v6 形狀不變;v7 修 W 階段失敗路徑與上鎖)

**前置條件**(任一不成立 → `E_PRECOND(reason)`;SD 路徑保留標記、log、下次開機再試):committed 槽;tryboot 未 arm;p6 已掛、無 `batman-storage.crit`、p6 非 LUKS、p6 `PARTNAME=data`;p5 是 ext4、非 LUKS、`PARTNAME=config`、ro 掛得起;非 bypass;`batman-slot` 不在執行。**F1 寫好 marker 之後再查一次**:`$RAM_ROOT/sbin/upgraded` 不存在且沒有 `/sbin/sysupgrade` 程序(擋「stage 1 已過、stage 2 還沒開始」的空窗,A6-m1);任一成立 → 撤銷。不宣稱持有 slot_lock;`precheck-node` 見 marker / 意圖拒絕 OTA(`-F` 例外寫明)。**p6 壞掉的節點不能用恢復出廠**(前置拒絕),只能重燒卡(B6-m11)。

**執行期(helper,provd 在、節點仍在網上)**

| 步 | 動作 | 失敗 |
|---|---|---|
| F0 | 產 `nonce`(16 hex);記下 `slot=$(batman-slot active)` | — |
| F1 | 寫 p6 marker(`<nonce> 1 -`,flock);寫 overlay **哨兵** `/etc/batman-reset.sentinel`(內容 nonce,fsync 檔與目錄);provd 進 `resetting-pending`;`/etc/init.d/joinwatch stop`;config-save 寫入模式從此拒寫;再查 sysupgrade 空窗 | 任一失敗 → 撤銷 |
| F2 | 每個 `/etc/init.d/batman-payload-*` `stop`;`/etc/init.d/dockerd stop`;`mv -T /opt/batdata/apps /opt/batdata/apps.reset` | stop 失敗 → log 繼續;`mv` 失敗 → 撤銷、`E_RESET(apps-busy)` |
| F2b | `batman-slot invalidate-other` | 失敗 → 撤銷、`E_RESET(other-slot)` |
| F3 | **提交點**:marker step=3 → `batman-config-save --reset-intent <nonce> --slot <slot>`(寫 p5 意圖並 ro 讀回) | rc 8(鎖忙)→ 每 5 s 重試到 60 s,仍忙 → 撤銷、`E_RESET(p5-busy)`(可重試,**不是**「換卡」,B6-m5/A6-m9);其他 rc → 撤銷、`E_RESET(p5-unwritable)`,app「設定區寫不進去,請換卡」 |
| F4 | marker step=4;刪 SD 標記(兩個 FAT);`find /overlay/upper -depth -name '.*' -exec rm -rf {} \;`;`rm -f /overlay/sysupgrade.tgz`;`jffs2reset -y`(哨兵是非 dot 檔,會被刪) | 失敗 → log 繼續(W0 補做) |
| F5 | `sync; reboot` | — |

- **撤銷**(F3 之前任一失敗,或 `factory_reset.cancel`):`[ -d apps.reset ] && mv -T apps.reset apps`(`apps/` 已存在 → 不覆蓋、crit、保留 `apps.reset/` 給人工)→ SD 觸發的話刪兩個 FAT 的標記 → 刪哨兵 → 刪 marker → 啟動 dockerd、guardian、joinwatch → provd 回原狀態。後果:F2b 作廢的另一槽沒有回退,直到下一次 OTA。
- **可取消的時段 = F3 之前**(兩處一致,A6-m9)。F3 之後 app 顯示「已開始,請勿斷電」。
- **`resetting-pending` 放行的動詞**:`status/public`、`factory_reset.cancel(owner_op)`、`factory_reset(owner_op)`(重新發起,從 F0 冪等重來)(B6-m9)。
- **helper 在執行期 crash / respawn**(A6-m3):helper 每次啟動(開機或 procd respawn)先看 marker:
  - marker 在、p5 無意圖 → `resetting-pending`(同開機);
  - marker 在、p5 有意圖(F3 之後)、哨兵還在 → **從 F4 續做**、F5 重開;
  - 不會停在「已提交但沒人重開」。
- F1–F2b 之間斷電:同 v6(dockerd/guardian/joinwatch 見 marker 不啟動、`apps/` 已改名 → 沒有 tenant;helper → `resetting-pending`)。
- F3 之後斷電:下次開機由 batdata-mount 完成(下表)。

**下次開機(batdata-mount `boot()`,只此一處破壞)**

95 是一次性 uci-default(`etc/init.d/boot` 跑完 exit 0 就刪,`95:755` 一律 exit 0):**它只在每個槽 overlay 的第一次開機跑**;之後每次開機都由 S11 的 `batdata-mount boot()` 執行(B6-M1/A6-m2 更正 v6「95 再跑」的錯誤假設)。所以 W 階段放在 **INITBODY 的 `boot()` 最前面**,每次開機都會檢查;不靠 `BATMAN_FIRSTBOOT`。95 本體若看到意圖 → 略過自己的步驟 3/3b(對舊 p6 的 e2fsck/resize,B6-m1/A6-m7),直接到步驟 5 呼叫 `boot()`。

`boot()` 最前面(LUKS open 之後、mount p6 之前、once-per-boot 閂之前):用 `reset-intent.sh` 讀 p5 意圖(ro 掛 p5)。沒有 → 今天的流程。有(含壞意圖):

| 步 | 條件 / 動作 | 失敗 |
|---|---|---|
| Wa | 意圖的 `slot` ≠ 本次 `batman_slot`(EEPROM 開錯槽、或其他異常)→ **不清**,但照常開機掛 p6(`apps/` 已改名、沒有 tenant),讓 `fw_override_check` 把槽修正並重開;96 因意圖上鎖 | 修正後下次開機回到意圖槽再判斷 |
| Wb | 壞意圖(格式不符)→ crit `reset-intent-malformed`,**不清、不掛 p6**;96 上鎖;helper `resetting` 並在 status 顯示(需 bench) | — |
| W0 | **哨兵 `/etc/batman-reset.sentinel` 存在**(= overlay 沒清掉):rw 掛 p5 把 attempts+1 並讀回 → 成功且 attempts ≤ 3 → `find /overlay/upper -depth -name '.*' -exec rm -rf {} \;` → `jffs2reset -y` → `reboot` → **`boot()` 立即 `return`**(`reboot` 是非同步的,不繼續往下,照 `fw_override_check` 的做法,B6-m3/A6-m8);attempts 寫不進或 > 3 → crit `reset-stuck overlay`,**不清、不掛舊 p6**,繼續開機(無 p6;96 上鎖;helper `resetting`;需要 bench / 重燒卡) | 寫不進 attempts 就停,不會無限重開(B6-M1) |
| W1 | 哨兵不存在(overlay 已清):守門 `PARTNAME=data`、`assert_not_system`(**複製進 INITBODY,失敗 `return` 不 `exit`**,B6-m2/A6-m7)→ `mkfs.ext4 -F -b 4096 -L <同 95 的 label> -m 0` p6(預設會 discard,對抹除有幫助) | 失敗 → crit `reset p6-mkfs-failed`,**不掛舊 p6**、不做 W2;下次開機重試(意圖還在,哨兵不在 → 再到 W1) |
| W2 | 守門 `PARTNAME=config`、非 LUKS → `mkfs.ext4 -F -q -L batman-cfg -m 0` p5(與 config-save `do_mkfs` 同參數;**最後做,p5 被格式化 = 意圖消失 = 完成紀錄**) | 失敗 → crit `reset p5-mkfs-failed`;下次開機:意圖可能還在 → W1 再清 p6(冪等)→ W2 |
| W3 | 照今天的流程:mount 新 p6、閂、pstore 搬移、boot-reasons 行、在新 p6 寫 `log/factory-reset.log` 一行 `completed nonce=<nonce> boot_id=<bid>`(持久紀錄,A6-m8)、`fw_override_check`、`restore_payload_guardians`(空) | — |

- **天然只做一次**:W2 一格式化 p5 意圖就消失;fresh 開機時 `boot()` 只被 95 呼叫一次(rcS 只 glob 一次,B6-m10),之後每次開機讀不到意圖。
- **W2 被打斷**:p5 magic 可能不是 ext4 → 讀不到意圖 → 96 `:71` → `unknown(p5-not-ext4)` + 上鎖(prov-state 的 last_known_state)→ 需要 bench `--seed --reformat`(寫明,極少見)。
- 之後 96 → 99 → helper(rc 7、overlay 無 identity)→ 新身分 → `prov{unclaimed}`。
- **F3 之後、下次開機之前 p5 壞掉**:同 v6(雙重故障殘項;tenant 不會起來;96 依 `last_known_state` 上鎖)。
- **95 的規則與文件同步**:`95-batman-storage` 的「never mkfs a pre-made data partition」改寫為「…除非 p5 有恢復出廠意圖」;`p5-config-partition.md`、`201-firstboot-grow.md`、config-save 的「只有 `--seed` 會 format」註解同步。
- **時間**:W1 + W2 預估 10–30 s,在 S11 阻塞;⚠️ 實測待 L16。
- **結果斷言**(L16;在 **04** 跑,Q5):同 v6,另加 `blkid` 看 p5/p6 UUID 都換了、`/etc/batman-reset.sentinel` 不存在、p6 `log/factory-reset.log` 有 completed 行。
- **負對照**(v6 的 (a)–(d) 保留,(e)(f) 改寫,新增 (g)–(i)):
  - (e) **白箱**:同一次開機手動再呼叫一次 `batdata-mount boot` → 不再格式化(B6-m10:fresh 開機時不會自然呼叫兩次);
  - (f) F4 前 `reboot -f` → 哨兵在 → W0 補清後完成;白箱讓 jffs2reset 失敗 → attempts 到 3 後停、不再重開;
  - (g) **W1 失敗後的下一次開機**:哨兵不在 → 走 W1 不走 W0、**沒有 jffs2reset 也沒有重開**(v6:每次開機都被當 W0,B6-M1);
  - (h) **p5 唯讀時 W0**:attempts 寫不進 → 停、不重開、**不掛舊 p6**(v6:無限重開);
  - (i) **W1/W2 失敗的那次開機**:`ssh -o PreferredAuthentications=password root@…` 空密碼被拒、serial 要密碼(v6:96 不上鎖 → 空密碼 root,B6-M2)。
- **SD 標記**:同 v6。
- **誠實界線**(A6-m11):本槽 overlay 只 unlink(f2fs 掛 nodiscard),另一槽只清 squashfs + 64 MiB 開頭,p5/p6 是 mkfs(預設 discard);**不是安全擦除**,SD 卡上可能讀得回殘留;引用 219 §7「轉賣前恢復出廠,但最安全是換一張新 SD 卡」。

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
- **stage 1 寫 `ota-armed.mesh` 的條件**:`platform_check_image` **rc=0** 且 `caller` 是 `/sbin/procd` 且 `upg=y`(`$RAM_ROOT/sbin/upgraded` 已安裝)**且**有一個活著的 `/sbin/sysupgrade` 程序(`pgrep -f ^/bin/sh /sbin/sysupgrade` 或等價,= 這次 validate 是某個 sysupgrade 的 ubus 呼叫觸發的;擋掉「本次開機 sysupgrade 中止過、RAM_ROOT 殘留 upgraded,之後 LuCI 經 procd validate」,A6-m5/B6-m6;04 的 `-F` 那次 procd validate 是 rc=1 → 不寫);⚠️ bench 上以 `-T`、真 OTA、中止後 LuCI validate 各一次實證;`sysupgrade -T`、LuCI、sysupgrade 自己的第一次 validate(caller = sysupgrade)都不寫(B5-M4/A5-m1)。p6 未掛 → 不寫(讀端 fail-closed)。`rm` 舊檔失敗 → 拒絕 OTA;寫完 rename + `sync`(B5-m11)。
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
| Q5 | L16 位置與還原 | **定案(使用者 2026-10-19:遠端不能移線,選救得回來的)= 04**(有乙太網;02 重置後離網且無乙太網 = 救不回)。前置:先把 04 p6 要留的東西(OTS DB/憑證/docker image、dv289 備份)備份到主機;還原 = 經乙太網(重置後 image 預設空密碼)重裝 lab 公鑰 → `halow-setkey` 回 fleet → 重新部署 OTS。L16 等 PR-P3 實作完才排,排之前再列副作用給使用者 |
| Q6 | BLE 認領測試會把 04 上鎖 | **定案並已做(使用者同意,2026-10-19)**:04 `authorized_keys` = 02 同一把 lab ed25519(sha256 5bda8113…),key-only 登入驗過,lock-status 仍 UNPROVISIONED,已進 p5(`--check` fresh)。這也滿足 §6.1 legacy 防呆門 |

## 13. v6 審查 → v7 對應

| v6 發現 | 收法 |
|---|---|
| **B6-M1** W0 的「非 fresh」判斷不成立、3 次後掛舊 p6、attempts 在 p5 寫不進就無限重開 | 正面哨兵 `/etc/batman-reset.sentinel`(非 dot,overlay 清掉才消失);W 階段放在 INITBODY `boot()`,每次開機檢查;attempts 寫不進 → 停;停住不掛舊 p6;負對照 (g)(h) |
| **B6-M2** resetting 不上鎖 | 96:意圖存在(含壞意圖)一律上鎖;§1.4 resetting 列改為上鎖;負對照 (i) |
| A6-m1 trial 槽 / sysupgrade 空窗 | 意圖記 `slot`;Wa 槽不符不清;F1 後再查 `upgraded`/sysupgrade 程序 |
| A6-m2 attempts 在 p5、「95 再跑」錯 | 同 B6-M1 |
| A6-m3 helper F3 後 crash | helper 啟動時看 marker + 意圖 + 哨兵 → 從 F4 續做 |
| A6-m4 / B6-m8 prov-state 欄位語意 | 拆 `last_known_state` 與 `verdict`;兩個寫者同規則;p6 沒掛 = 沒提示寫明 |
| A6-m5 / B6-m6 procd validate 殘留 upgraded、rc | rc=0 + caller=procd + upg=y + 活著的 sysupgrade 程序;bench 三種實證 |
| A6-m6 意圖時不上鎖 | 同 B6-M2 |
| A6-m7 / B6-m1 / B6-m2 守門、3b、「只有」 | 守門複製進 INITBODY、`return`;p5/p6 `PARTNAME` 守門;mkfs 參數同 config-save;95 本體見意圖略過 3/3b;「只有」改寫 |
| A6-m8 / B6-m3 W0 reboot 非同步、沒有持久紀錄 | `reboot` 後 `return`;W3 寫 `log/factory-reset.log` |
| A6-m9 / B6-m5 `mv -T`、取消時段、鎖忙說換卡 | `mv -T`(04 busybox 實測有);取消 = F3 前;rc 8 重試 60 s、`E_RESET(p5-busy)` |
| A6-m10 / B6-m7 app 要先存 node_cert;連線佔用 | 契約:app 在送 `claim/finish` **之前**持久化 `node_cert`(含 `ecdh_pub`)與 `claim-pending{device_id, owner_pub}`,否則 replay 不可用;刪「路人最多佔一條」:兩個 central 可佔滿 2 條(協定 §8 既有界線),每連線額度只保護已連上的買家 |
| A6-m11 誠實界線 | §4.5 末段 |
| A6-m12 / R72 / §8 nonce / 意圖三寫者 | R72 更正(blkid、sgdisk 有);§8 改為「95 只驗格式 + slot;nonce 在 F3 寫入時比對」;意圖寫者依時段列在 §3 |
| B6-m4 壞意圖讀者不一致 | 共用 `reset-intent.sh`;壞意圖 = 凍結 + 上鎖 + crit(Wb) |
| B6-m9 resetting-pending 動詞 | 放行 status、cancel、重新發起 |
| B6-m10 負對照 (e) | 改白箱 |
| B6-m11 p6 壞不能重置 | 前置拒絕,寫明只能重燒卡 |
| Q5 / Q6 | 使用者定案(§12):L16 在 04;04 已裝 lab 公鑰 |
