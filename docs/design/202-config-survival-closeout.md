# Design: #202 config-survival close-out — p5 永遠跟著 live 設定走 — **v2**

狀態:v1 兩位審查者 REJECT(review-202-A.md:1 BLOCKER + 5 MAJOR + 10 MINOR;review-202-B.md:2 BLOCKER + 5 MAJOR + 7 MINOR)。v2 整份改寫,§11 列每一條怎麼收。待兩位整份重審。
基準:Batman `main` 6a049f2(= 出貨 v1.5.11),節點 02/04 = `1.5.11-rel.1+6a049f2.fw7049fd8`。真機證據來自 02(唯讀)與 2026-10-17 的 G1/G2 重現(issue #202 留言 6229383727)。

## 0. 一句話

節點上任何支援路徑改的 per-node 設定(mesh key / AP key / channel / mesh_id / hostname / 位址旗標)都要在 **≤ 15 s 內(入網中)或立即(操作員工具)** 寫進 p5,**寫不進去要大聲說**;p5 落後 live 時 **OTA 被擋(含 `-F`)**;並補上「設 config → reflash 另一槽 → 新槽 provisioned + rejoin」的回歸。關閉 #202,給 #254(app 供裝)一個可以依賴的契約。

## 1. 現場觸發(逐 actor)與今天的行為

| # | 現場 | 今天(main 6a049f2) | 證據 |
|---|---|---|---|
| T1 | **LOCKED** 節點(有 root 密碼)開機入網一次後,操作員/app 改 key / hostname / channel | `joinwatch:144` 首次 `--on-join` 回 0 就 touch `$RUNDIR/config-saved`,之後本次開機**不再呼叫 save** → p5 凍結 → OTA 新槽用舊設定 | G1 白箱重現(02:latch 注入 60 s p5 不跟、快取指紋/stamp 不動;拔 latch 35 s 跟上) |
| T2 | **建網第一台 / 換 key** 的那台:設完沒 peer | save 只在 joinwatch 的 JOINED 分支 → 不入網就不存;`batman-slot:466-471` interlock 只看 `.seeded` → **放行 OTA** → 新槽用舊 key 開機 | G2 真機重現(02:換 key 60 s p5 仍舊 key;`precheck-node` 回 ready rc 0) |
| T3 | 公開 image 新卡用 `halow-setkey --mesh … --ap … --mesh-id …` 入 fleet | 不設 channel(image 預設 ch42 = 2 MHz,fleet ch40 = 4 MHz)→ 入不了 mesh,要手動 `uci set wireless.radio1.channel=40`;**AP key 不在 PRESERVE** → 重刷後 AP 回 image 預設(公開 image = placeholder → keyguard 關 AP,手機連不上自己的節點) | #75 行 208(10-05 燒卡實測);`halow-setkey:1-70`;`batman-config-save:22-32` PRESERVE;02 `default_radio0` psk2 有 key |
| T4 | 密碼含 `` ` $ ( ) ; | & < > ' `` 任一字元(SAE 允許) | `batman-config-save:177` **只印 stderr 就 `continue`,rc 0** → p5 沒那行、工具說存好了 → 新槽用 image 預設 key = #202 原症狀 | 原始碼;`96:38` `valid_batch` 同字元集拒收(是產品契約) |
| T5 | 操作員手動 `uci set … ; uci commit`、OpenMANET UI 設保留 IP(openmanetd 翻 `dhcpconfigured/roipconfigured`、改 `ahwlan.ipaddr` 再重開) | 入網中:OPEN 15 s 內跟上;LOCKED 同 T1;未入網同 T2 | `batman-config-save:55-99`;02 p5 含 `dhcpconfigured='1'` |
| T6 | 兩個程序同時寫 p5(joinwatch 每 tick 的 `--on-join` vs 操作員 `--save`) | **無鎖**、固定掛載點 `/mnt/cfgsave`(L20)、`.stage.$$` 只隔離 staging 不隔離 publish(L219-224)→ 舊蓋新、lkg 旋轉成舊、快取記錯 | 原始碼;今天 LOCKED 只碰一次所以罕見,A 之後每 15 s 一次 |
| T7 | 刻意 `sysupgrade -F`(fleet tooling 曾例行用) | stage 1 失敗被忽略;stage 2 ramfs 重跑 precheck | `platform-ab.sh:146-150` 註解、`:299`;`docs/boards-and-builds.md:162` 說一般 OTA 不要 -F;`docs/golden-image.md:97` 卻用 `-F -n` |
| T8 | `batman_bypass=1` 救援開機(96 不還原 p5,live = image 預設) | 入網後 `--on-join` 用 image 預設**蓋掉 p5**(今天一次,A 之後每次) | `96:62-65`(bypass exit 1 不還原) |
| T9 | p5 **從未** seed 的 mesh-only 節點 reflash | interlock 擋(`.seeded` 缺)→ 不 strand | 現行,不改 |
| T10 | 新網第一台在 trial 槽上 setkey → autocommit 因沒 peer revert | 舊 overlay + p5 新 key;入網後 on-join 把 p5 寫回舊 | `batman-autocommit:388-396` `expected_in_mesh` |

**結論**:機制(join → save → 96 還原)對,壞在幾個「各自正確」的假設互相衝突:joinwatch 以為「存過一次 = 這次開機不會再變」(#265 同款);halow-setkey 以為「有人會存」且「存了就等於進了 p5」;config-save 以為「拒收一個值印個警告就好」;interlock 以為「有 `.seeded` = p5 是新的」;大家都以為「p5 只有一個寫者」。

## 2. 範圍(從現場推,不從好交付推)

**做**
- **A. 拿掉 joinwatch 的 latch**:JOINED 的每個 tick 都呼叫 `--on-join`;冪等與成本由 #263 M0 指紋快取負責(02 實測快取命中 real 0.03 s)。解 T1、T5(入網中)。
- **A2. p5 寫入互斥鎖**(`batman-config-save` 全模式含 `--check`):`$RUNDIR/cfgsave.lock`(mkdir + pid,照 `batman-slot:84-96` 範式)。解 T6。
- **A3. 寫入放大保險**:`--on-join` 本次開機實際寫入 ≥ 20 次 → syslog warn,之後兩次實際寫入最短間隔 60 s(快取路徑不受影響)。
- **B. `halow-setkey` 成為「驗證 → 套用 → 讀回 → 立即持久化」的入口**:字元集前置檢查(解 T4);新增 `--channel <n>` 以 morse `channels.csv` 依國碼驗證(解 T3 channel);設完 `batman-config-save --save`,結果明示、失敗 exit 3;允許 `--channel` 單獨使用。
- **B2. PRESERVE 加 AP key**(`wireless.default_radio0.key`;解 T3 AP)。schema 仍 1(additive `set` 行,`96` 的 `valid_batch`/ALLOWED_PKGS 已放行 wireless)。
- **B3. `batman-config-save` 對不可持久化的值 fail-loud**:`--save/--seed` rc 6 + 鍵名;`--on-join` 不把它記成 0/4;`--check` 把「live 非空但不可持久化」判 stale。解 T4。
- **B4. `--save` 補 Pi 3 factory check**(未 seed 卡,runbook G4);`--save --promote-lkg` 給「操作員/provd 已證明」的場合(219 §6.4 契約,見 C2)。
- **B5. bypass 開機保護**:`batman_bypass=1` 時所有寫入模式拒絕(rc 1),`--check` rc 3 並說明。解 T8。
- **C. interlock 改查新鮮度**:新 `batman-config-save --check`(唯讀);`batman-slot precheck-node` 在 stage 1 用它,並把結果寫 `$RUNDIR/p5-check.rc` 讓 stage 2(ramfs,無 config-save/uci)也能擋;**p5 落後 → 拒絕 OTA,`-F` 也擋**(解 T2、T5 未入網、T7)。本次開機 p5 rw 掛載失敗過(`cfgsave-mount.failed`)也擋。
- **D. 回歸進 daily-validation / fault-injection**(harness PR 先進 main,#290):D1 設定跟隨(tier A)、D2 setkey 持久化 + 字元集 + channel 驗證 + interlock 拒絕 stale(tier B,DNODE=04,節點端腳本)、D3 reflash-survives-config(fault-injection case,節點明示 = 02,使用者在場)。
- **E. 文件**:`p5-config-partition.md`(saver 契約、`.seeded` 語意、鎖)、`ab-autocommit.md` N5、`219-field-provisioning.md` L373(lkg 語意)、`golden-image.md`(setkey 用法、拿掉 `-F`)、`platform-ab.sh:299` 註解、`263-mm6108-cmd-skb-ownership.md:79`(M0 是指紋快取不是 latch)、本文件。

**不做(關單時寫回 #202 殘項清單,不開新單)**
- autocommit 在「單台建網、沒鄰居」時永遠 revert(T10):219 §6.3 指定由 #254 改 `expected_in_mesh`。本單只保證 p5 內容正確,並把 T10 列進矩陣。
- LOCKED 節點黑箱驗證(fleet 全 OPEN;D1 白箱注入涵蓋同一路徑;等新 Pi 3 或使用者決定鎖 02)。
- LUKS(#111)p5:`--check`/interlock 對非 ext4 p5 skip(fail-open,§7 承認)。
- `halow-setkey --country`(非 US 新卡仍要手動設國碼;`depersonalise.sh --country` 已有)。
- `/etc/config/wireless` 0644 → mesh key 對本機任何 uid 可讀(02 實測,既有事實)→ 一行給 #13。
- 集中推送(#14/#54)、provd(#254):遵守 §4 契約即可。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| p5 `overrides.uci` / `schema_version` / `identity/*` / `.seeded` | `batman-config-save`(所有寫入模式,**持 `cfgsave.lock`**) | `96`、`99-chanfix`、`batman-slot precheck-node`(經 `--check`)、`batman-autocommit expected_in_mesh`(ro 掛讀 `.seeded`,`:388-396`)、harness(ro,noload) | 「一支程式」≠「一個程序」:A2 的鎖把它變成真正的單一寫者 |
| p5 `lkg/overrides.uci` | `batman-config-save`(`--seed/--on-join/--if-healthy/--save --promote-lkg` 旋轉;裸 `--save` 不碰) | `96` | N-R8 保留,加一個明示的升級旗標 |
| `$RUNDIR/cfgsave.lock` | `batman-config-save`(mkdir 取得、exit trap 釋放;殘鎖 pid 不在則接管) | — | 新 |
| `$RUNDIR/config-saved`(latch) | **刪除**:A 之後無人寫、無人讀 | — | 舊 image 殘檔無害;`rundir-paths.txt:67` 條目由 PR-P 移除(「刪自己刪掉的檔案」例外) |
| `$RUNDIR/cfgsave-onjoin.state`(指紋快取)、`cfgsave-mount.failed`、`cfgsave-pi3gate.failed`、`cfgsave-writes`(A3 計數) | `batman-config-save` | `batman-slot precheck-node` 讀 `cfgsave-mount.failed`(C5) | `--check` 不寫任何一個 |
| `$RUNDIR/p5-check.rc` | `batman-slot precheck-node`(stage 1,每次重寫) | `batman-slot node_checks`(stage 2 ramfs) | 新;rundir 跨 supivot(`rundir.sh:9-11`) |
| live uci `wireless.<mesh>.key/encryption/mesh_id`、`wireless.<ap>.key`、`wireless.radio1.channel` | 執行期:`halow-setkey`、操作員、provd;fresh-slot firstboot:`96`(還原)→ morse 驅動(把 42 寫回 channel)→ `99-chanfix`(重設);`99-halow-identity`(AP ssid) | joinwatch(診斷)、`batman-config-save` | 寫者按生命週期階段互斥(firstboot 鏈 vs 執行期) |
| `system.@system[0].hostname`、`network.ahwlan.ipaddr/proto`、`openmanetd.config.dhcpconfigured/roipconfigured` | firstboot:`99-halow-identity`;執行期:**openmanetd**(兩段式定址後重開)、操作員、provd | `batman-config-save` | v1 漏列 openmanetd;其後果見矩陣「保留 IP」列 |
| `/opt/batdata/state/lock-status` | `96` | `halow-status` | 不變;`--save` 不改鎖定狀態 |
| `/opt/batdata/state/mesh-expected` | `batman-config-save`(seed/on-join) | `batman-autocommit` | 不變;裸 `--save` 不寫(新網第一台 OTA 的 autocommit 行為 = 今天,見 T10) |
| OTA 准駁 | `batman-slot precheck-node`(stage 1,`platform-ab.sh:150`)與 `node_checks`(stage 2) | `sysupgrade` | 新增兩條判定(C5) |

## 4. 契約

**C0 共通(`batman-config-save` 所有模式)**
- 開頭 `[ "$(id -u)" = 0 ] || die "root only"`(rc 1)。
- 取 `$RUNDIR/cfgsave.lock`(mkdir;`pid` 檔;pid 不存在 → 接管並 log)。**取鎖之後才讀 uci / 算指紋**。取不到:`--on-join` 靜默 rc 1(下 tick 再來);`--save/--seed` 等最多 10 s;`--check` 等最多 5 s,逾時 rc 1 + 訊息。
- 讀值一律 **已 commit 的值**(`uci -q -P <空的 batman_tmp 目錄> get`),不含 pending delta;契約寫明(m1-A:02 實證 `uci get` 會看到未 commit 的 delta)。
- `--check` 與 `--save/--seed/--on-join` 共用同一個 `stage_overrides()`(否則「會寫什麼」漂移);staging 在 `batman_tmp -d`(root 0600,含 key 明文)→ 所有 exit 路徑 `trap` 清理。
- `batman_bypass=1` 在 `/proc/cmdline` → 寫入模式 rc 1 `bypass boot: refusing to persist image defaults over p5`;`--check` rc 3 `bypass boot — not comparable`。
- 不可持久化的值(`[\`$();|&<>']`,與 `96:38` `valid_batch` 同集合):`stage_overrides()` 回傳被拒鍵名清單;見各模式。

**C1 `--on-join`**(呼叫者:joinwatch,JOINED 的每個 tick;joinwatch 不再 latch,rc 只進 log)
- rc 0 = p5 已等於 live 且有 root 密碼;4 = 已等於 live 但節點 OPEN;**6 = live 有不可持久化的值(p5 其餘已寫;不記快取 0/4,每 tick 重試 + syslog warn 一次/開機)**;1 = 錯誤(鎖忙 / mount 失敗 → 300 s 退避 / Pi 3 gate / bypass)。
- 快取路徑:指紋 + superblock stamp 命中 → 不掛載(0.03 s)。
- A3:本次開機實際寫入計數在 `$RUNDIR/cfgsave-writes`;≥ 20 → warn;之後實際寫入間隔 < 60 s → 本 tick 跳過(rc 1)。
- 失效模式:p5 rw 掛不起 → `cfgsave-mount.failed`(既有)→ **C5 擋 OTA(fail-closed)**。

**C2 `--save [--promote-lkg]`**(呼叫者:`halow-setkey`、操作員、provd #254)
- 寫 overrides + identity + schema;刪指紋快取;**裸 `--save` 不旋轉 lkg**(操作員意圖未經入網證明,N-R8);`--promote-lkg` 旋轉(呼叫者自行證明過,例如 provd 在 `meshjoin_joined` 之後,或「網主簽章設定不要求鄰居」的場合由 provd 決定)。**219 §6.4 L373 在 PR-P 同步改成這個語意**。
- 未 seed 的卡(`.seeded` 缺)且有 `mmcblk0p7` → `pi3_factory_check`(L140 條件加 `--save`)。`--save` 會寫 `.seeded`(今天就會)→ **`.seeded` 語意從「入網過/明確 seed」放寬為「有人用支援工具存過」**,T9 的保護縮到「從未 setkey 也從未入網」;寫進 p5 設計與 ab-autocommit N5。
- rc 0 寫入;**6 = 部分鍵被拒(印 `rejected: <keys>`,其餘已寫)**;1 失敗(mount / gate / 非 ext4 / bypass / 鎖逾時)。不格式化。

**C3 `--check`(新,唯讀)**(呼叫者:`batman-slot precheck-node`、harness、操作員)
- 無 p5 / p5 非 ext4 / bypass 開機 → rc 3(`SKIP: no-p5|not-ext4|bypass`);`ro,noload` 掛(已被 rw 掛著時等 1 s 重試 ≤ 3 次);無 `.seeded` → **rc 6 `unseeded`**;`stage_overrides()` 後逐位元組比對 overrides + schema + `same_identity` → 相同 rc 0 `fresh`;不同 rc 5 `stale: <keys>`(鍵名,不印值);**有被拒鍵且 live 非空 → rc 5 `stale: <keys> (unpersistable)`**;mount 失敗 / 鎖逾時 rc 1。
- stdout 一行 `batman-config-save: p5 fresh|stale (<keys>)|unseeded|SKIP <why>|error <why>`。不寫 p5、不動快取、不寫 `mesh-expected`。

**C4 `halow-setkey [--mesh <k>] [--ap <k>] [--mesh-id <id>] [--channel <n>]`**(至少一個)
1. 參數驗證(改任何東西之前):長度 ≥ 8、非 placeholder、**字元集排除 `` ` $ ( ) ; | & < > ' ``**(訊息列出禁用字元;#254 app 產生密碼時遵守);`--channel`:整數,且 `/usr/share/morse-regdb/channels.csv` 中 `country_code == wireless.<radio>.country` 的某列 `s1g_chan == n`(與 netifd `morse_set_chan_info → _get_regulatory` 同來源),印出該列的 `bw` 與 `centre_freq_mhz`(例 `channel 40 = 4 MHz @ 922.0 MHz (US)`);不在表內 → exit 2,不改。
2. 套用:uci set(key/encryption=sae/mesh_id/channel)→ 釋放 keyguard → `uci commit wireless` → `wifi reload`。
3. **讀回**(≤ 20 s):`uci get wireless.<radio>.channel == n`(morse 可能寫回 42)且 `morse_cli -i <mesh-if> channel` 的 Operating Frequency == csv `centre_freq_mhz`;失敗 → 還原 uci 到步驟 2 之前的值、`wifi reload`、exit 3 `radio rejected channel n`,**不持久化**。只改 key 時讀回 = `uci get key` 相符。
4. `batman-config-save --save` → 印 `persist: saved -> /dev/mmcblk0p5` / `persist: FAILED (<原因>) — 設定只在本槽,下次 OTA 會遺失` / `persist: n/a (no p5 on this card)`。
- exit:0 = 套用且(持久化成功或無 p5);**3 = 套用但持久化失敗或讀回失敗**(provd 顯示 219 §2.3「設定沒有存好」;不是 harness 的 skip 語意);2 = 參數錯,未改。
- 持久化範圍明示:mesh key / mesh_id / channel / country / hostname / 位址旗標 / **AP key**(B2)會進 p5;mesh `encryption`、AP ssid 不會(image 預設 sae;ssid 由 `99-halow-identity` = hostname)。
- 不迴印 key。root only。

**C5 `batman-slot` interlock**
- **stage 1(`precheck-node`,live 系統)**:既有 `.seeded` 判定(含 `allowed UNSEEDED` 覆寫)→ 只在 `seeded=1` 時跑 `--check`(未 seed 沒有新舊可比,M1-B)→ 把 rc 寫 `$RUNDIR/p5-check.rc`(`<rc> <uptime>`)→ rc 5 且 `! allowed STALE_P5` → `die "p5 (config) is STALE vs the running config (<keys>) — a reflash now would boot the fresh slot with the OLD settings. Run 'batman-config-save --save' (or halow-setkey), or wait for the mesh join to persist it; deliberate override: touch /tmp/batman-slot.allow-stale-p5 (root) / BATMAN_ALLOW_STALE_P5=1"`;另 `$RUNDIR/cfgsave-mount.failed` 存在 → die `p5 could not be mounted rw this boot — fix p5 before an OTA`(同覆寫);rc 3/6/1 → 不擋(查不了、或已由前一判定處理)。
- **stage 2(`node_checks` in ramfs,無 config-save/uci)**:讀 `p5-check.rc`;`5` 且 `! allowed STALE_P5` → die;**檔案不存在 → die `no stage-1 p5 freshness verdict — run sysupgrade without -F, or batman-slot apply from the live system`**(fail-closed;live 系統直接呼叫 `batman-slot apply` 時 `node_checks` 自己有 config-save 可跑,不走這支)。`-F` 因此**不能**繞過(T7)。
- 失效模式:fail-closed;唯一 fail-open = p5 非 ext4 / 無 p5 / bypass 開機(查不了,與現行 interlock 一致,§7 承認)。

**C6 `99-batman-chanfix`**:不變。B 讓 p5 的 channel 就是操作員驗證過、radio 接受過的值。

**C7 harness(D1–D3)**:§8。

## 5. 生命週期矩陣

| 路徑 | 今天 | 之後 | 證明 |
|---|---|---|---|
| fresh slot 首次開機(install) | 96 還原 → morse 寫回 42 → 99 重設 → 99-identity 跳過 → joinwatch JOINED → on-join(OPEN 每 tick / LOCKED 一次) | 同,LOCKED 也每 tick(快取);AP key 也被還原 | D3 |
| 一般開機 | 同上 | 同上 | D1 |
| factory reset / overlay wipe(同槽重跑 uci-defaults) | 同 fresh slot | 同 | 與 fresh slot 同路徑,D3 覆蓋 |
| clean stop / 重開 | 無持久狀態(快取、鎖、計數在 tmpfs) | 同 | — |
| joinwatch 重啟(procd) | 快取由指紋+stamp 驗證 | 同;殘鎖 pid 不在 → 接管 | D1 含一次 `/etc/init.d/joinwatch restart` |
| 兩個寫者同時(on-join vs save) | 無鎖:舊蓋新 / lkg 回退(T6) | 鎖序列化 | D1 白箱:交替 50 次 `--save` 與 `--on-join`,p5 == live 且 lkg 不回退(舊版出現錯位) |
| `wifi reload` 窗(setkey 剛 commit,plink 還 ESTAB,tick 落在此窗) | on-join 可能把未證明 key 升 lkg(≤ 15 s 洞,OPEN 今天已如此) | 同;鎖只保證不交錯,不保證「已證明」語意;承認為既有限制,provd 用 `--promote-lkg` 明示 | 文件化 |
| 保留 IP(openmanetd 兩段式定址後重開) | 下次入網 on-join 跟上;未入網則落後 | 同;**未入網 → C5 擋 OTA,訊息給 `--save` 出口**(fail-closed,刻意) | D2 步驟 2 的 raw-uci stale 路徑等價 |
| 新網第一台 / 換 key 沒 peer(T2) | 不存;OTA 放行 | setkey 已 `--save`;raw 路徑 → C5 擋 | D2 |
| trial 槽上 setkey → autocommit revert(T10) | 舊 overlay + 新 p5;入網後 on-join 寫回舊 | 同(不做,#254);C5 在 revert 後第一次 OTA 前是 stale 直到 on-join 跟上(≤ 15 s) | 文件化;既有 fault-injection R1–R4 覆蓋 revert 機制 |
| autocommit commit | commit 後 on-join 繼續(OPEN) | 同,LOCKED 也是 | D3 等 commit |
| OTA stage 1(`sysupgrade -n`) | `.seeded` 判定 | + `--check` + 寫 `p5-check.rc` | D2 步驟 2(precheck 拒絕) |
| OTA stage 2(ramfs) | 重跑 precheck(`.seeded` 可掛載判) | + 讀 `p5-check.rc`;缺 → die | D2 步驟 2b:`sysupgrade -F -n` 在 stale 下**也**被拒(節點回原槽,log 有 die 訊息) |
| `batman-slot apply` 直接呼叫(live) | node_checks | node_checks 自己跑 `--check` | 程式碼審查 |
| 升級到本版(從 1.5.11) | 舊 precheck(無 C5)跑這一次 | 之後受保護 | 文件化 |
| 回滾/降級到 1.5.11 | — | 舊 joinwatch 又 latch(T1 回來);p5 schema 1 相容;舊 setkey 對 `--channel` exit 2 不改、無 `persist:` 行 → **219 要用 `/v1/info` 版本協商分辨舊節點** | 文件化(219 一句) |
| 混版 fleet(有的節點舊 image) | — | 舊節點行為同今天;契約差異在 §4 | 文件化 |
| `batman_bypass=1` 救援開機(T8) | on-join 用 image 預設蓋 p5 | 寫入模式拒絕;`--check` rc 3 → OTA 不擋(救援路徑要能 OTA) | D1 一行:在 cmdline 模擬?不可(需重開)→ 程式碼審查 + 殘項 |
| crash / crash loop | save 原子(STAGE → mv,`.seeded` 最後) | 同;鎖殘留由 pid 檢查接管 | 既有 ab-selftest |
| 斷電 / 斷網 | 未入網不 on-join | 同;操作員工具改的靠 `--save`;其餘 C5 擋 | D2 |
| 依賴重啟 `wifi reload` | joinwatch 短暫 NOT_JOINED | 同;setkey 的 `--save` 在讀回之後、不等入網 | D2 |
| Pi 4(bcm2711) | — | 全部 | D1–D3 在 02/04 |
| Pi 3(bcm2710) | `--save` 不跑 factory check | 跑 | ❌ 無板 → 程式碼審查 + 殘項 |
| golden/MBR 單槽卡(無 p5) | 全 skip | 同(`--check` rc 3,setkey `persist: n/a`) | D1 前置 skip 路徑 |
| LUKS p5(#111) | interlock skip | `--check` rc 3 → skip(fail-open) | 不適用 |

## 6. 依賴的行為與證據(全部已核對;A/B 兩位的真機事實已併入)

| 假設 | 證據 |
|---|---|
| latch 在 `joinwatch:144`,存在理由只有寫入次數(現由 M0 快取負責)與「rc 0 = 不會再變」 | 原始碼 + p5 設計 N5/N5r2/N5r4 + `p5-onjoin-263.sh:19-23`;G1 白箱 |
| 快取命中 0.03 s、不掛載 | 02 `time batman-config-save --on-join` real 0.03 s ×2(rc 4);`s_mnt_count` 數小時只因真變更而動 |
| 無鎖、固定掛載點 | `batman-config-save:20`(MNT)、全文無 lock;`batman-slot:84-96` 鎖範式 |
| L177 靜默丟值 | `batman-config-save:177` `continue` 不改 rc;`96:38` 同字元集拒收 |
| `iw phy` 不是 S1G 頻道來源 | 02:`iw dev wlh0 info` = channel 153(5765 MHz);uci channel 40;`morse_cli -i wlh0 channel` = 922000 kHz / 4 MHz;`channels.csv` US `bw=4 s1g_chan=40 centre=922.0 map_5g_chan=155`;csv 631 列,header 含 `country_code,bw,s1g_chan,centre_freq_mhz,map_5g_chan` |
| precheck 在 stage 1 live 系統;`-F` 忽略 stage 1;ramfs 無 config-save/uci | `platform-ab.sh:146-150`、`:37` RAMFS_COPY_BIN |
| rundir 跨 supivot | `rundir.sh:9-11`(`/tmp/run/batman`,NEVER /var/run) |
| `allowed()`/`batman_opf` 覆寫機制 | `batman-slot:77`、`rundir.sh` batman_opf |
| 96 bypass 不還原且 exit 1 | `96:62-65` |
| 96 還原 hostname/channel;99 晚期重設 | `96:126-150`、`99-batman-chanfix` 全文 |
| `99-halow-identity` 寫 hostname/AP ssid/ipaddr/dhcpconfigured(firstboot,p5 還原時跳過) | 檔案 L7-27 |
| autocommit:commit 需 NEED 3×10 s + JOIN_NEED 3 樣本(可早於 MIN_WINDOW);revert 最晚 DEADLINE(bcm2711 預設 600 s uptime);讀 p5 `.seeded` | `batman-autocommit:30-35, 388-396, 458-509` |
| `uci -q get` 含未 commit delta | 02 實測(審查 A):scratch `set` 後 `get` 回新值;`-P <空 savedir>` 回已 commit 值 |
| 節點無 `su`,有 `start-stop-daemon`、`nobody` | 02 `which` |
| `/etc/config/wireless` 0644 | 02 `ls -l` |
| 02 `eth0 NO-CARRIER`;04 有乙太網 = 主機唯一橋;DNODE 慣例 = 有乙太網 | 02 `ip -br link`;`daily-validation.sh:248`;`fleet-settle.sh:5-10`(300 s) |
| fault-injection 已有 payload == 執行中 build 的 precheck(root.squashfs sha 對 /rom) | `fault-injection.sh:120-140` |
| suite() 對 rc 3 要 `SKIP-REASON:` 行;known-failures 每行 FAIL 都要匹配、拒收 CONNECTION-LOST 類 | `daily-validation.sh:84-91`;`validation-known-failures.txt` 標頭 |
| deploy/ 與 feed/ 兩份要同步 | `check-provisioning-sync.sh` PAIRS |
| 新檔名要登記 `scripts/rundir-paths.txt`(harness 檔) | 現有 `:67-71` 條目 |
| 02 當下 OTA payload = rel.1 = 執行中 | `/opt/batdata/ota.tar.gz` sha 73300d1b;**只是今天的快照,D3 前置每次比對** |

## 7. 安全

- **資產**:p5 的 mesh key / AP PSK / 身分檔(民用 tier 明文 ext4,不變)、root 控制、OTA 准駁。
- **遠端攻擊者**:無新網路輸入。
- **本機非特權程序**:新檔全在 `$RUNDIR`(02 上 drwx------ root)或 `batman_tmp`;覆寫檔走 `batman_opf`(root 擁有、非 symlink;攻擊者預建只能讓操作員的覆寫失效 + TAMPER log,不能放行);非 root 跑 config-save → C0 `root only` rc 1;C5 自己以 root 跑,不讀別人結果。`p5-check.rc` 在 rundir,只有 root 能寫。**既有事實**:`/etc/config/wireless` 0644,key 對任何本機 uid 可讀(不在本單,殘項給 #13)。
- **被攻陷的對等節點**:不能寫本機 p5;無新協定。
- **輸入驗證增量**:setkey 字元集 + 長度 + csv 白名單;config-save 被拒值 fail-loud(不再靜默)。
- **特權 / TOCTOU**:全 root;p5 掛載點改 `batman_tmp -d`(不再固定 `/mnt/cfgsave`),staging 在 rundir;鎖在 rundir。
- **秘密**:不印 key;`--check`/die 訊息只有鍵名;staging 含 key 明文 → trap 清理、0600。
- **供應鏈**:`channels.csv` 來自 morse 套件(netifd 同源)。
- **失效模式**:C5 fail-closed(含 `-F`、mount 失敗);fail-open 只有「查不了」(無 p5 / 非 ext4 / bypass)。`--save` 失敗大聲(exit 3)。
- **我們自己的錯**:T4(靜默丟值)、v1 的 `iw` 白名單、bypass 蓋 p5 —— 三者都在 v2 收掉;打錯 key 仍會持久化(與 live 一致,同工具改回)。
- **負向驗證**:D2(stale → 拒絕;`-F` → 拒絕;`ab&cd12345` → exit 2 且 uci 不變;`--channel 36`(US)→ exit 2);D1(`start-stop-daemon -c nobody` 跑 `--check` → rc 1)。

## 8. 測試(harness PR 先進 main;每條真驅動介面;FAIL 行固定字串)

**D1 `p5-follows-config-202`(tier A,MESH_NODE 與 OTS_NODE 各跑)**
前置:p5 ext4 且 `.seeded`(否則 `SKIP-REASON: p5 not seeded/not ext4`,rc 3);JOINED。
1. `touch $RUNDIR/config-saved`(白箱:模擬 LOCKED 已 latch;新 image 無讀者)。
2. `uci set hostname=<old>-dv202; uci commit system`;每 5 s `ro,noload` 讀 p5,≤ 60 s 要變 → 否則 `FAIL p5 hostname stale after 60 s`。
3. `/etc/init.d/joinwatch restart`;再改一次後綴 → ≤ 60 s 跟上(殘鎖/重啟路徑)。
4. 白箱並行:節點端迴圈 50 次交替 `batman-config-save --save`(改 hostname 後綴)與 `--on-join`,結束後 p5 == live 且 `lkg` 不是任一中間值 → 否則 `FAIL p5 lost an update under concurrent writers`。量 `s_mnt_count` 增量(≤ 寫入次數 + 5)。
5. 還原 hostname;≤ 60 s p5 回舊;刪 latch 檔;`batman-config-save --check` rc 0;`start-stop-daemon -S -c nobody -x /usr/bin/batman-config-save -- --check` rc ≠ 0。
負對照:rel.1 步驟 2 FAIL(G1)、步驟 4 可能 FAIL(無鎖)、步驟 5 `--check` 不存在 → `FAIL batman-config-save --check unsupported`。known-failures 三個固定字串掛 #202。
**D2 `setkey-persists-202`(tier B,DNODE = 04,有乙太網;D:會短暫離網)**
節點端單一腳本 `scripts/node/setkey-persists-202.sh`(`setsid`,結果寫 `/opt/batdata/log/dv202.out`,**看門狗 150 s 用 `halow-setkey --mesh <old>` 還原**);harness 送腳本 → 等 DNODE 重新 JOINED(`bchk_rejoin_245` 的 plink 等待)→ 讀回結果檔逐項斷言;**檔缺/空 = FAIL**。
1. 字元集:`halow-setkey --mesh 'ab&cd12345'` → exit 2、`uci get key` 不變 → 否則 `FAIL setkey accepted an unpersistable key`。
2. channel:`halow-setkey --channel 36`(US)→ exit 2、uci 不變;`--channel <目前值>` 單獨 → exit 0、輸出含 `= 4 MHz`。
3. 持久化:`halow-setkey --mesh <tmp-key>` → exit 0、`persist: saved`;p5 key md5 == 新;`batman-slot precheck-node` rc 0。
4. stale:`uci set key=<old>; uci commit`(不 reload 不存)→ `--check` rc 5 含 `key`;`precheck-node` rc ≠ 0 且訊息含 `STALE`;`BATMAN_ALLOW_STALE_P5=1 batman-slot precheck-node` rc 0。
4b. `-F`:`sysupgrade -F -n <任意 payload>` 在 stale 下 → 節點**不**換槽(boot_id 變但 active slot 不變、`is-trial` rc 1),logread 含 `no stage-1 p5 freshness verdict` 或 `STALE`。(這一步會重開 04 一次;OTS 在 04,重開後由 guardian 拉起;列為 D2 的子步驟,`FEATURE_MODE=--destructive` 才跑。)
5. 還原:`halow-setkey --mesh <old-key>` → p5 == 舊、precheck rc 0、JOINED ≤ 180 s。
負對照:rel.1 步驟 1/3/4 FAIL(固定字串),步驟 2 `--channel` exit 2 的「不支援」也 FAIL;掛 #202。
**D3 `fault-injection.sh` 新 case `P5`(reflash-survives-config;節點明示 `FI_NODE=10.41.24.32`,預設不選,使用者在場)**
前置:沿用 `precheck()`(payload root.squashfs sha == 執行中 /rom,否則 `SKIP-REASON: payload != running build`,**絕不刷**);`is-trial` rc 1;記 boot_id / slot / version / p5 快照(ro,noload,key 遮罩)。
1. `uci set hostname=<old>-fi202; uci commit; batman-config-save --save`;`--check` rc 0。
2. `ota_boot`(setsid `sysupgrade -n`);`waitboot 600`(CONNECTION-LOST 在 waitboot 內吸收,不進 FAIL 行)。
3. 新槽:slot 翻轉;`uci get hostname` == `<old>-fi202`;mesh key ≠ placeholder、`halow-setkey --status` 無 `blocked`;AP key 與 OTA 前相同(md5);JOINED ≤ 240 s;BATMAN_VERSION 不變。
4. 等 `committed()` ≤ 300 s(預期 60–180 s);未 commit → 繼續等到 DEADLINE 600 s + 開機(≤ 900 s)看 revert,任一 = FAIL 並附 autocommit log。
5. 還原 hostname + `--save`;`--check` rc 0;p5 快照對照。
每跑一次 02 換槽並 commit → 寫進 DUT 現況檔。D3 是 DoD 第 1 條的黑箱證明,不是 A/B/C 的負對照(負對照在 D1/D2),PR 明寫。
**CI**:`check-provisioning-sync`、shellcheck、`check-tmp-trust`(新檔名先進 `rundir-paths.txt`,PR-H)、`ab-card-invariants` 不動。

## 9. 實作切法

- **PR-H(harness,先)**:`test/202-harness` → main:D1、D2(+ 節點腳本)、D3 case、`rundir-paths.txt` 加 `cfgsave.lock` / `cfgsave-writes` / `p5-check.rc` / staging 前綴、known-failures(固定字串,#202)、rel.1 上的 FAIL log 證據。
- **PR-P(產品)**:`feat/202-config-survival`:`joinwatch`、`batman-config-save`(C0–C3、B2 PRESERVE、B3、B4、B5、A2、A3)、`halow-setkey`(C4)、`batman-slot`(C5 兩段)、`platform-ab.sh:299` 註解、文件(§2 E 清單)、`rundir-paths.txt` 移除 `config-saved`(例外)、本文件。兩份(deploy/ + feed/)同步。
- rc `1.5.12-wsl.N`(WSL build-3aplus,board diffconfig)→ OTA 02 與 04 → **把同一 rc payload 放到節點 `/opt/batdata/ota.tar.gz`** → D1/D2/D3 → 全套 → PR → 使用者 merge → firmware pin bump → 出貨產物煙霧/全套。

## 10. 殘項(關單時寫回 #202 checklist)

LOCKED 黑箱驗證;Pi 3 `--save` factory gate 實測;autocommit 單台建網(#254);LUKS `--check`(#111);`--country`;`/etc/config/wireless` 0644(→ #13);bypass 開機路徑只程式碼審查;`wifi reload` 窗內 lkg 升級的 ≤ 15 s 洞;舊 image 回滾後 T1 回來。

## 11. v1 審查發現 → v2 對應

| 發現 | 收法 |
|---|---|
| A-B1 靜默丟值 | T4、B3、C0/C1/C2/C3 rc 6 與 stale、C4 步驟 1、D2 步驟 1 |
| A-M1 `iw` 白名單錯 | C4 用 `channels.csv` 依國碼 + 讀回;§6 證據改為 csv/morse_cli;D2 步驟 2 |
| A-M2 無鎖 | A2、C0、§3、矩陣「兩個寫者」列、D1 步驟 4 |
| A-M3 / B-§1 `-F` 繞過 | C5 兩段 + `p5-check.rc` 缺檔 fail-closed;矩陣 stage 1/2 分列;D2 4b;文件三處統一 |
| A-M4 / B-B2 D3 目標、預算、payload | D3 改 fault-injection case、節點明示、`precheck()` 版本比對、commit/revert 預算、§9 放 rc payload |
| A-M5 / B-M5 矩陣與寫者 | §3 加 openmanetd/99-identity/autocommit;矩陣加 autocommit、bypass、factory reset、保留 IP、trial setkey、wifi reload 窗、混版 |
| A-M5 bypass 毀 p5 | B5、C0 |
| B-B1 D2 在 02 跑不動 | D2 改 DNODE=04 + 節點端腳本 + 結果檔 |
| B-M1 覆寫互撞 | C5 只在 seeded=1 跑 `--check`;unseeded 獨立 rc 6 |
| B-M2 AP key 假持久化 | B2 PRESERVE 加 AP key;C4 明示持久化範圍 |
| B-M3 fail-closed 假宣稱 | C1/C5:`cfgsave-mount.failed` 存在即擋 |
| B-M4 219 lkg 契約 | C2 `--promote-lkg` + PR-P 改 219 L373 |
| A-m1 uci delta | C0 已 commit 值 |
| A-m2 共用 staging/trap/rundir-paths | C0、§9 |
| A-m3 / B-m4 rc 雙義與 SKIP 翻譯 | `--check` rc 6 unseeded;setkey exit 3 註明非 skip;D1 SKIP-REASON |
| A-m4 / B-m1 非 root 負測 | C0 root only;D1 `start-stop-daemon -c nobody`;0644 事實進 §7 |
| A-m5 寫入放大 | A3 + D1 量 `s_mnt_count` |
| A-m6 / B-m6 看門狗、`.seeded` 語意 | D2 看門狗走 setkey;C2 寫明語意變更 + 文件 |
| A-m7 文件矛盾 | §2 E |
| A-m8 `--country` | 殘項 |
| A-m9 autocommit 讀者 | §3 |
| A-m10 / B-m3 讀回、phy | C4 步驟 3、csv |
| B-m2 ro/rw 競賽 | 鎖 + `--check` 重試 |
| B-m5 混版對 #254 | 矩陣回滾列 + 219 一句 |
| B-m7 payload 快照 | §6 最後一列 + D3 前置 |
