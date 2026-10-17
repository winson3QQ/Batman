# Design: #202 config-survival close-out — p5 永遠跟著 live 設定走 — **v3**

狀態:v1 兩位 REJECT;v2 兩位 APPROVE-WITH-CHANGES(A:5 MAJOR + 9 MINOR;B:6 MAJOR + 7 MINOR,全是 v2 新引入或只修一半,骨架不動)。v3 整份改寫,§11 列 v2 每條的收法;另加一個 v3 才用探針發現的觸發 T11。待兩位整份重審。
基準:Batman `main` 6a049f2(= 出貨 v1.5.11),節點 02/04 = `1.5.11-rel.1+6a049f2.fw7049fd8`。真機證據:02(唯讀 + 兩個無寫入探針)、2026-10-17 G1/G2 重現(issue #202 留言 6229383727)。

## 0. 一句話

節點上任何支援路徑改的 per-node 設定(mesh key / AP key / channel / mesh_id / hostname / 位址旗標)都要在 **≤ 15 s 內(入網中)或立即(操作員工具)** 寫進 p5,**寫不進去要大聲說**;p5 落後 live 時 **OTA 被擋(含 `-F`)**;並補上「設 config → reflash 另一槽 → 新槽 provisioned + rejoin」的回歸,接進常規全套。關閉 #202,給 #254(app 供裝)一個可以依賴的契約。

## 1. 現場觸發(逐 actor)與今天的行為

| # | 現場 | 今天(main 6a049f2) | 證據 |
|---|---|---|---|
| T1 | **LOCKED** 節點開機入網一次後,操作員/app 改 key / hostname / channel | `joinwatch:144` 首次 `--on-join` 回 0 就 latch,之後本次開機**不再呼叫 save** → p5 凍結 → OTA 新槽用舊設定 | G1 白箱重現(02:60 s 不跟、快取指紋/stamp 不動;拔 latch 35 s 跟上) |
| T2 | **建網第一台 / 換 key** 的那台:設完沒 peer | save 只在 JOINED 分支;`batman-slot:466-471` interlock 只看 `.seeded` → **放行 OTA** → 新槽用舊 key | G2 真機重現(02:60 s p5 仍舊 key;`precheck-node` ready rc 0) |
| T3 | 公開 image 新卡用 `halow-setkey --mesh … --ap … --mesh-id …` 入 fleet | 不設 channel(image ch42 = 2 MHz,fleet ch40 = 4 MHz)→ 入不了 mesh;**AP key 不在 PRESERVE** → 重刷後 AP 回 image 預設(公開 image = placeholder → keyguard 關 AP) | #75 行 208;`halow-setkey:1-70`;`batman-config-save:22-32`;02 `default_radio0` psk2 有 key |
| T4 | 密碼含 `` ` $ ( ) ; | & < > ' ``(SAE 允許) | `batman-config-save:177` **只印 stderr 就 `continue`,rc 0** → p5 沒那行、工具說存好了 → 新槽 image 預設 key = #202 原症狀 | 原始碼;`96:38` `valid_batch` 同字元集(產品契約) |
| T5 | 操作員 raw `uci set … ; uci commit`、OpenMANET UI 設保留 IP(openmanetd 翻 `dhcpconfigured/roipconfigured`、改 `ahwlan.ipaddr` 再重開) | 入網中:OPEN 15 s 內跟上;LOCKED 同 T1;未入網同 T2 | `batman-config-save:55-99`;02 p5 含 `dhcpconfigured='1'` |
| T6 | 兩個程序同時寫 p5(joinwatch 每 tick `--on-join` vs 操作員 `--save`) | **無鎖**、固定掛載點 `/mnt/cfgsave`、`.stage.$$` 不隔離 publish(L219-224)→ 舊蓋新、lkg 旋轉成舊、快取記錯 | 原始碼 |
| T7 | `sysupgrade -F`(fleet tooling 曾例行用) | stage 1 失敗被忽略;stage 2 ramfs 重跑 precheck | `platform-ab.sh:146-150, :299`;`boards-and-builds.md:162` vs `golden-image.md:97` |
| T8 | `batman_bypass=1` 救援開機(96 不還原,live = image 預設) | 入網後 `--on-join` 用 image 預設**蓋掉 p5** | `96:62-65` |
| T9 | p5 **從未** seed 的 mesh-only 節點 reflash | interlock 擋 → 不 strand | 現行,不改 |
| T10 | 新網第一台在 trial 槽上 setkey → autocommit 因沒 peer revert | 舊 overlay + p5 新 key;入網後 on-join 寫回舊 | `batman-autocommit:388-396` |
| **T11(v3 新)** | 任何短暫 **ro 讀者**(`99-chanfix`、`batman-autocommit expected_in_mesh`、`batman-slot` `.seeded` 判定、harness `chk_202`)與 `--on-join` 的 rw 掛載同時 | **先 ro,noload 再 rw:rw 掛載回 0 但實際是 `ro,norecovery`**(共用 superblock)→ 寫入 EROFS,腳本無 `set -e` 會印 `saved` 卻沒寫;**先 rw 再 ro:EBUSY rc 32** | 02 探針(2026-10-17):A 序 `rc_rw=0` 但 `/proc/mounts` 兩個都 `ro,relatime,norecovery`;B/C 序 `rc_ro=32` `already mounted` |
| T12 | `--on-join` rw 掛載一次暫時失敗(SD 忙) | 寫 `cfgsave-mount.failed`、300 s 退避;**全文無清除者**(`:63,86-89,108` 是全部引用) | 原始碼(A/B 兩位各自核對) |

**結論**:機制(join → save → 96 還原)對,壞在幾個「各自正確」的假設互相衝突:joinwatch 以為「存過一次 = 不會再變」;halow-setkey 以為「有人會存」且「存了 = 進了 p5」;config-save 以為「拒收一個值印個警告就好」且「mount 回 0 = 可寫」;interlock 以為「有 `.seeded` = p5 是新的」;大家都以為「p5 只有一個寫者、讀者不會干擾寫者」。

## 2. 範圍(從現場推)

**做**
- **A. 拿掉 joinwatch 的 latch**:JOINED 每 tick `--on-join`;冪等/成本由 #263 M0 指紋快取負責(02 實測命中 0.03 s)。解 T1、T5(入網中)。
- **A2. p5 寫入互斥鎖** `$RUNDIR/cfgsave.lock`(全模式含 `--check`),接管條件 = pid 不存在 **或** `/proc/<pid>/cmdline` 不含 `batman-config-save`(照 `batman-slot:95-99`)。解 T6。
- **A3. 寫入放大保險**:本次開機實際寫入 ≥ 20 次 → syslog warn 一次;之後實際寫入最短間隔 60 s(快取路徑不受影響)。
- **A4. 寫者自保(T11/T12)**:rw 掛載後驗證 `/proc/mounts` 該掛載點為 `rw`,否則 umount、sleep 1、重試 ≤ 3;三次都不行才寫 `cfgsave-mount.failed`(含原因);**rw 掛載成功即刪 marker**。
- **B. `halow-setkey` = 驗證 → 套用 → 讀回 → 立即持久化**:字元集前置檢查(T4);`--channel <n>` 以 morse `channels.csv` 依國碼驗證(T3);讀回輪詢;`--save`;結果明示、失敗 exit 3;允許 `--channel` 單獨使用。
- **B2. PRESERVE 加 AP key**(`wireless.default_radio0.key`;T3)。schema 仍 1;placeholder 值視同空(不持久化,也不算 unpersistable)。
- **B3. 不可持久化的值 fail-loud**:`--save/--seed` rc 6 + 鍵名;`--on-join` rc 6 **也進快取**(warn 一次/開機);`--check` 判 stale。解 T4。
- **B4.** `--save` 補 Pi 3 factory check;`--save --promote-lkg`(219 §6.4)。
- **B5.** `batman_bypass=1` 時寫入模式拒絕(rc 1);`--check` rc 3。解 T8。
- **C. interlock 改查新鮮度**:新 `batman-config-save --check`(唯讀);`precheck-node`(stage 1)**每次**寫生效後判定到 `$RUNDIR/p5-check.rc`;stage 2 只對 `stale` 或「缺檔 / 過期」擋 → **`-F` 也擋**(T7),覆寫與 skip 路徑不被誤擋。
- **D. 回歸接進常規全套**(harness PR 先進 main,#290):D1(tier A)、D2(tier B,DNODE=04,節點端腳本)、D3(fault-injection case `p5`,由 daily-validation destructive 區塊以 `suite … --case p5` 接進,節點 = `$MESH_NODE`)。
- **E. 文件**:`p5-config-partition.md`(saver 契約、`.seeded` 語意、鎖、T11)、`ab-autocommit.md` N5、`219-field-provisioning.md` L373、`golden-image.md`(setkey 用法、拿掉 `-F`)、`platform-ab.sh:299`、`263-mm6108-cmd-skb-ownership.md:79`、本文件。

**不做(殘項回 #202,不開新單)**:autocommit 單台建網(T10,#254);LOCKED 黑箱;LUKS(#111);`--country`;`/etc/config/wireless` 0644(→ #13);集中推送/provd 只遵守契約;外部 ro 讀者(99/autocommit/harness)改成持鎖(A4 的寫側重試已夠,讀者都是毫秒級)。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| p5 `overrides.uci` / `schema_version` / `identity/*` / `.seeded` | `batman-config-save`(寫入模式,**持 `cfgsave.lock` 且驗證 rw**) | `96`、`99-chanfix`、`batman-slot`(`.seeded`)、`batman-autocommit expected_in_mesh`(`:388-396`)、`--check`、harness(ro,noload) | 讀者不持鎖;T11 由寫側 A4 處理 |
| p5 `lkg/overrides.uci` | `batman-config-save`(`--seed/--on-join/--if-healthy/--save --promote-lkg`;裸 `--save` 不碰) | `96` | N-R8 |
| `$RUNDIR/cfgsave.lock/`(目錄,含 `pid`、`uptime`) | `batman-config-save`(mkdir 取得、trap 釋放、殘鎖接管) | `--check` 報 lock-busy 時引用 | 新;目錄而非檔(rundir-paths 規則在 PR-H 確認) |
| `$RUNDIR/cfgsave-lock.busy` | `--on-join`(連續 ≥ 8 tick 被鎖擋時寫,取到鎖時刪) | `batman-slot precheck-node` | 新 |
| `$RUNDIR/config-saved`(latch) | **刪除** | — | `rundir-paths.txt:67` 由 PR-P 移除(例外) |
| `$RUNDIR/cfgsave-onjoin.state`、`cfgsave-mount.failed`(**現在會被清**)、`cfgsave-pi3gate.failed`、`cfgsave-writes` | `batman-config-save` | `precheck-node` 讀 `mount.failed` | `--check` 不寫任何一個 |
| `$RUNDIR/p5-check.rc`(`<verdict> <uptime>`) | `batman-slot precheck-node`(stage 1,**每次**重寫) | `batman-slot node_checks`(stage 2) | 新;rundir 跨 supivot(`rundir.sh:9-11`) |
| live uci `wireless.<mesh>.key/encryption/mesh_id`、`wireless.<ap>.key`、`wireless.radio1.channel` | 執行期:`halow-setkey`、操作員、provd;firstboot 鏈:`96` → morse 驅動(寫回 42)→ `99-chanfix`;`99-halow-identity`(AP ssid) | joinwatch、config-save | 按生命週期階段互斥 |
| `hostname`、`ahwlan.ipaddr/proto`、`openmanetd.config.dhcpconfigured/roipconfigured` | firstboot:`99-halow-identity`;執行期:**openmanetd**、操作員、provd | config-save | 保留 IP 後果見矩陣 |
| `lock-status` | `96` | `halow-status` | 不變 |
| `mesh-expected` | config-save(seed/on-join) | autocommit | 裸 `--save` 不寫(T10 = 今天) |
| OTA 准駁 | `precheck-node`(stage 1,`platform-ab.sh:150`)與 `node_checks`(stage 2) | `sysupgrade` | C5 |

## 4. 契約

**rc 表(`batman-config-save`,所有模式一致)**

| rc | 意義 | 哪些模式 |
|---|---|---|
| 0 | 完成;`--on-join`:p5 == live 且有 root 密碼 | 全部 |
| 1 | 錯誤:非 root / mount 失敗(三次)/ Pi 3 gate / bypass(寫入模式)/ 鎖逾時(寫入模式)/ `--check` 掛不起 | 全部 |
| 3 | 不適用:無 p5 / 非 ext4 / bypass(`--check`)/ `--if-healthy` 非 OK | `--check`、`--if-healthy` |
| 4 | p5 == live 但節點 OPEN | `--on-join` |
| 5 | stale(含 unpersistable) | `--check` |
| 6 | live 有不可持久化的值(其餘已寫;`--on-join` 記快取) | `--save/--seed/--on-join` |
| 7 | p5 未 seed | `--check` |
| 8 | lock-busy(等待逾時;印持有者 pid、age) | `--check` |

**C0 共通**
- `[ "$(id -u)" = 0 ] || die "root only"`(rc 1)。
- 取鎖:mkdir `$RUNDIR/cfgsave.lock`,寫 `pid`、`uptime`;已存在 → 讀 pid:不存在或 cmdline 不含 `batman-config-save` → 接管(log);否則等待:`--on-join` 不等(rc 1;連續 ≥ 8 tick → syslog warn 一次/開機 + 寫 `cfgsave-lock.busy`,取到鎖時刪)、`--save/--seed` 等 ≤ 10 s(rc 1)、`--check` 等 ≤ 5 s(**rc 8**)。**取鎖之後才讀 uci / 算指紋。** trap 釋放。
- 讀已 commit 的值:`uci -q -P <空 batman_tmp 目錄> get`(02 實證 `-P` 空目錄回已 commit 值)。
- `stage_overrides()` 共用;staging 在 `batman_tmp -d`(0600);trap 清理。回傳被拒鍵名(字元集 `` [`$();|&<>'] ``);**placeholder 值(`CHANGE-ME-NOW`)視同空**:不寫、不算被拒。
- `batman_bypass=1`:寫入模式 rc 1 `bypass boot: refusing to persist image defaults over p5`;`--check` rc 3 `SKIP bypass`。
- 掛載:rw 模式 → 掛到 `batman_tmp -d` → 驗證 `/proc/mounts` 該點為 `rw` → 否則 umount、sleep 1、重試 ≤ 3 → 仍失敗:寫 `cfgsave-mount.failed`(`<uptime> <reason>`)、rc 1;**成功即 `rm -f cfgsave-mount.failed`**。ro 模式(`--check`)→ `ro,noload`,EBUSY 時 sleep 1 重試 ≤ 3。

**C1 `--on-join`**(joinwatch,JOINED 每 tick;rc 只進 log)
- 快取:指紋 + stamp 命中 → 回快取 rc(**0/4/6** 都進快取)不掛載。
- A3:`cfgsave-writes` 計數;≥ 20 → warn 一次;之後實際寫入間隔 < 60 s → 本 tick rc 1(不寫)。
- rc 6:其餘鍵已寫、lkg 照常旋轉(寫進去的部分是入網證明過的)、syslog warn 一次/開機 `unpersistable value in <keys>`。

**C2 `--save [--promote-lkg]`**(`halow-setkey`、操作員、provd)
- 寫 overrides + identity + schema、刪快取、刪 `mount.failed`(成功時);裸 `--save` 不旋轉 lkg;`--promote-lkg` 旋轉。**219 §6.4 L373 在 PR-P 改成此語意**。
- 未 seed 且有 p7 → `pi3_factory_check`。`.seeded` 語意放寬為「支援工具存過」(文件同步)。
- rc 0 / 6(`rejected: <keys>`)/ 1。

**C3 `--check`(唯讀)**
- 無 p5 / 非 ext4 / bypass → rc 3 `SKIP <why>`;無 `.seeded` → **rc 7 `unseeded`**;鎖逾時 → **rc 8 `lock-busy pid=<p> age=<s>`**;ro 掛不起(三次)→ rc 1 `error mount`;比對 overrides + schema + `same_identity` → rc 0 `fresh` / rc 5 `stale: <keys>`;被拒鍵且 live 非 placeholder 非空 → rc 5 `stale: <keys> (unpersistable)`。
- 不寫 p5 / 快取 / marker / `mesh-expected`。

**C4 `halow-setkey [--mesh <k>] [--ap <k>] [--mesh-id <id>] [--channel <n>]`**(至少一個)
1. 驗證(改之前):長度 ≥ 8、非 placeholder、字元集;`--channel`:整數且 `channels.csv` 中 `country_code == wireless.<radio>.country` 的某列 `s1g_chan == n`(netifd `morse_utils.sh:49 _get_regulatory` 同來源),印 `channel n = <bw> MHz @ <centre> MHz (<country>)`;否則 exit 2 不改。
2. 套用:uci set → 釋放 keyguard → `uci commit wireless` → `wifi reload`。
3. 讀回(**輪詢每 1 s**;key/mesh_id ≤ 20 s、channel ≤ 60 s;wlh0 在 reload 時會被移除重建,`morse_cli` 短暫失敗是正常):`uci get wireless.<radio>.channel == n`(否則 = morse 寫回 → 還原 uci、reload、exit 3 `radio rejected channel n`、不持久化);`morse_cli -i <if> channel` 的 Operating Frequency(kHz)== csv `centre_freq_mhz × 1000`;**逾時不還原**(peer 可能已跟著換)→ exit 3 `unverified — re-run halow-setkey --channel n to verify`、不持久化。
4. `batman-config-save --save` → `persist: saved -> /dev/mmcblk0p5` / `persist: FAILED (<原因>) — 設定只在本槽,下次 OTA 會遺失` / `persist: PARTIAL rejected: <keys>` / `persist: n/a (no p5)`。
- exit 0 = 套用且(持久化成功或無 p5);3 = 套用但讀回失敗 / 持久化失敗或部分(非 harness skip 語意);2 = 參數錯未改。
- 持久化範圍:mesh key / mesh_id / channel / country / hostname / 位址旗標 / AP key 會進 p5;mesh `encryption`(image sae)、AP ssid(`99-halow-identity` = hostname)不會。不迴印 key。root only。

**C5 `batman-slot` interlock**
- **stage 1 `precheck-node`**(live):既有 `.seeded` 判定 → 算生效後判定並**每次**寫 `$RUNDIR/p5-check.rc` = `<verdict> <uptime>`,verdict ∈ `skip:<no-p5|not-ext4|unseeded-allowed|bypass>` / `fresh` / `stale-allowed` / `stale:<keys>` / `error:<mount|lock-busy>`:
  - seeded=1 → `--check`:rc 0 → `fresh`;rc 5 → `allowed STALE_P5` ? `stale-allowed` : `stale:<keys>` + die(訊息同 v2,並註明 env 形式只對直接呼叫 `batman-slot` 有效,sysupgrade 用 `/tmp/batman-slot.allow-stale-p5`);rc 8 → `error:lock-busy` + die `a batman-config-save is still running (pid, age) — wait or investigate`(fail-closed:卡住的 save 正是 p5 可能不新鮮的時候);rc 1 → 看 marker:`cfgsave-mount.failed` 或 `cfgsave-lock.busy` 存在 → `error:mount` + die `p5 could not be mounted rw / save blocked this boot (<reason>) — fix p5 before an OTA`(同覆寫);否則 `skip:error` 不擋(查不了)。rc 3/7 → `skip:*`(7 只在 `allowed UNSEEDED` 路徑到得了)。
  - **marker 只在 `--check` ≠ 0 時參考**(rc 0 = p5 == live,mount 史無關)。
- **stage 2 `node_checks`**(ramfs,無 config-save/uci):讀 `p5-check.rc`;`stale:*` 且 `! allowed STALE_P5`(opf 檔在 /tmp,跨 supivot)→ die;**缺檔或 uptime 差 > 600 s** → die `no fresh stage-1 p5 verdict — run sysupgrade without -F, or batman-slot apply from the live system`;其他 verdict 放行。die 走 `otalog_k S2 REFUSE why=p5-stale|p5-no-verdict`(固定 token 進 p6 `ota-trace.log`)。`-F` 因此不能繞過(T7);覆寫/skip/LUKS 路徑不被誤擋。
- 失效模式:fail-closed(stale、lock-busy、mount 失敗有證據、無判定);fail-open 只有查不了(無 p5 / 非 ext4 / bypass:bypass 旗標只在當前槽的 boot 分割,新槽開機沒有 bypass,96 會照常還原 p5,所以放行無害)。

**C6 `99-batman-chanfix`**:不變。
**C7 harness**:§8;harness 全域要把 `REFUSING … STALE|lock-busy|no fresh stage-1` 當獨立 FAIL 行辨識(不是 "did not reboot")。

## 5. 生命週期矩陣

| 路徑 | 今天 | 之後 | 證明 |
|---|---|---|---|
| fresh slot 首次開機 | 96 還原 → morse 寫回 42 → 99 重設 → 99-identity 跳過 → JOINED → on-join | 同;LOCKED 也每 tick;AP key 也被還原 | D3 |
| 一般開機 | 同 | 同 | D1 |
| factory reset / overlay wipe | 同 fresh slot | 同 | D3 路徑 |
| clean stop / 重開 | 無持久狀態 | 同 | — |
| joinwatch 重啟 | 快取由指紋+stamp 驗證 | 同;殘鎖由 pid+cmdline 接管 | D1 步驟 3 |
| 兩個寫者同時(T6) | 舊蓋新 / lkg 回退 | 鎖序列化 | D1 步驟 4(真並行) |
| ro 讀者撞 rw 寫者(T11) | 寫者悄悄變 ro → EROFS 卻印 saved;或讀者 EBUSY | 寫者驗證 rw + 重試;讀者重試 | D1 步驟 4b:背景每 0.2 s `ro,noload` 掛/卸 30 s 同時改設定 → p5 仍跟上、無 `mount.failed`(舊版:期待出現 EROFS/假 saved) |
| rw 掛載暫時失敗(T12) | marker 永留 | marker 在下次成功時清;C5 只在 `--check` ≠ 0 時看它 | D1 步驟 5:白箱寫 marker → `precheck-node` 仍 rc 0(因 `--check` 0)→ 下個 tick 寫入後 marker 消失 |
| `wifi reload` 窗(plink 還 ESTAB) | on-join 可能把未證明 key 升 lkg(≤ 15 s) | 同(既有限制,provd 用 `--promote-lkg` 明示) | 文件化 |
| 保留 IP(openmanetd 兩段式) | 入網後跟上;未入網落後 | 同;未入網 → C5 擋,訊息給 `--save` 出口 | D2 步驟 4 等價 |
| 新網第一台 / 換 key 沒 peer(T2) | 不存;OTA 放行 | setkey 已 `--save`;raw 路徑 C5 擋 | D2 |
| trial 槽 setkey → autocommit revert(T10) | 舊 overlay + 新 p5;on-join 寫回 | 同(#254);revert 後 ≤ 15 s stale | 文件化;fault-injection R1–R4 覆蓋 revert |
| autocommit commit | 繼續 on-join | 同 | D3 |
| OTA stage 1(`-n`) | `.seeded` | + `--check` + 寫判定 | D2 步驟 4 |
| OTA stage 1 + 覆寫 `allow-unseeded` / `allow-stale-p5` | 放行 | 寫 `skip:unseeded-allowed` / `stale-allowed` → stage 2 放行 | D2 步驟 4c(白箱:寫判定檔 + `BATMAN_FAULT_INJECT` 走 `node_checks` 讀檔分支,不真 OTA) |
| OTA stage 2(ramfs) | 重跑 precheck | 讀判定;`stale`/缺/過期 → die(trace `S2 REFUSE`) | D2 4b(真 `-F -n`,04 重開一次) |
| OTA from 數小時前跑過 precheck 的節點 | — | 判定過期(> 600 s)→ die 要求不加 `-F` 重跑 | 程式碼審查 |
| `batman-slot apply` 直接呼叫(live) | node_checks | 自己跑 `--check` | 程式碼審查 |
| LUKS p5(#111) | skip | stage 1 `skip:not-ext4` → stage 2 放行 | 不適用 |
| 升級到本版(從 1.5.11) | 舊 precheck 這一次 | 之後受保護;**全 fleet 每台 on-join 一次性重寫 p5(指紋多 AP key)並旋轉 lkg;未入網的節點第一次 OTA 前會被 C5 擋直到 `--save`** | 文件化 + 02/04 OTA 到 rc 後觀察一次 |
| 回滾/降級到 1.5.11 | — | 舊 joinwatch 又 latch(T1 回來);schema 1 相容;舊 setkey 對 `--channel` exit 2、無 `persist:` 行 → 219 用 `/v1/info` 版本協商 | 文件化 |
| 混版 fleet | — | 舊節點 = 今天 | 文件化 |
| `batman_bypass=1`(T8) | on-join 蓋 p5 | 寫入拒絕;`--check` skip → OTA 放行(新槽無 bypass,96 照常還原) | 程式碼審查 + 殘項 |
| crash / crash loop | save 原子 | 同;殘鎖接管;SPI stall 卡住的 save → `--check` rc 8 → C5 擋 + 訊息 | 既有 ab-selftest |
| 斷電 / 斷網 | 未入網不 on-join | 同;工具改的靠 `--save`;其餘 C5 擋 | D2 |
| Pi 4 / Pi 3 / 無 p5 卡 | — | 同 v2(Pi 3 `--save` gate ❌ 無板 → 程式碼審查 + 殘項) | D1–D3 在 02/04 |

## 6. 依賴的行為與證據

v2 表全部保留(latch:144;快取 0.03 s;無鎖/固定掛載點;L177 靜默;`iw` 非 S1G 來源 vs `channels.csv`(02:631 列,US bw4 s1g_chan 8/16/24/32/40/48,centre 922.0 ↔ `morse_cli` 922000 kHz);`platform-ab.sh:37/146-150/262-285/296-299`;`rundir.sh:9-11`;`allowed()`/`batman_opf`;`96:62-65, 126-150`;`99-chanfix`;`99-halow-identity:7-27`;`batman-autocommit:30-35, 388-396, 458-509`;`uci -P` 空目錄回已 commit 值;節點無 `su` 有 `start-stop-daemon`;`/etc/config/wireless` 0644;02 `eth0 NO-CARRIER`;`fault-injection.sh:120-146 precheck()` 真比 /rom sha;`suite()` rc 3 + SKIP-REASON;known-failures 規則;provisioning-sync;rundir-paths;02 payload 快照)。v3 新增:

| 假設 | 證據 |
|---|---|
| 先 ro,noload 再 rw → rw 掛載回 0 但 `ro,norecovery`;先 rw 再 ro → EBUSY | 02 探針 2026-10-17(A 序 `rc_rw=0`、兩個掛載都 `ro,relatime,norecovery`;B/C 序 `rc_ro=32`) |
| `cfgsave-mount.failed` 無清除者 | `batman-config-save` 全文 `MNTFAIL` 只在 63/64/86/87/108 |
| `uci batch` 對不存在 section 的 `set` rc 0、其餘行照常 | 02 scratch 實測(審查 A) |
| setkey 換 key reload ~2 s,wlh0 被移除重建 | 02 logread 2026-10-15 20:45:47–49(審查 A) |
| stage 2 die 文字不在 logread,只有 p6 `ota-trace.log`(`otatrace.sh:7,27`);`die` 需走 `otalog_k` 才有固定 token | 原始碼(審查 A) |
| netifd `_get_regulatory` 讀同一 csv | `morse_utils.sh:49`(審查 B) |
| fault-injection case 要被 `daily-validation.sh` 以 `suite … --case` 接進才算全套 | `daily-validation.sh:197, 212-213`(前例 H261) |
| ramfs/procd 不繼承 env | `batman-slot:71-77` 註解 |

## 7. 安全

同 v2,增量:
- **本機非特權**:`cfgsave.lock/`、`cfgsave-lock.busy`、`p5-check.rc`、staging、掛載點全在 root 0700 rundir;覆寫走 `batman_opf`;`channels.csv` 在 squashfs(root 0644 唯讀)。非 root → C0 rc 1。
- **TOCTOU**:p5 掛載點改 `batman_tmp -d`;rw 驗證以 `/proc/mounts` 為準(不是 mount rc)。
- **秘密**:同 v2;`p5-check.rc` 只含鍵名。
- **失效模式**:C5 fail-closed(stale / lock-busy / mount 失敗有證據 / 無判定 / 判定過期);fail-open 只有查不了。
- **我們自己的錯**:T11(mount rc 0 不等於可寫)、T12(marker 永留)在 v3 收掉。
- **負向驗證**:D1(非 root rc 1;T11 背景 ro 讀者下 p5 仍跟上;marker 白箱);D2(stale 拒絕;`-F` 拒絕;字元集;`--channel 36`;覆寫不被誤擋)。

## 8. 測試(harness PR 先進 main;真驅動介面;FAIL 行固定字串)

**D1 `p5-follows-config-202`(tier A,MESH_NODE 與 OTS_NODE)**
前置:p5 ext4 且 `.seeded`(否則 `SKIP-REASON:`,rc 3);JOINED;`batman-config-save --check` 存在(否則 `FAIL batman-config-save --check unsupported`)。
1. `touch $RUNDIR/config-saved`(白箱 latch)。
2. 改 hostname 後綴;每 5 s ro,noload 讀 p5,≤ 60 s 要變 → 否則 `FAIL p5 hostname stale after 60 s`。
3. `/etc/init.d/joinwatch restart`;再改一次 → ≤ 60 s 跟上。
4. **真並行**:節點端兩個背景迴圈同時跑 30 s(迴圈 1:每 0.5 s `--save` 改後綴;迴圈 2:每 0.5 s `--on-join`);結束等 ≤ 30 s(一個 tick + 鎖)→ `overrides == live` 且 `lkg == overrides`(on-join 看到 lkg ≠ overrides 會旋轉,`:204-206`)→ 否則 `FAIL p5 lost an update under concurrent writers`;量 `s_mnt_count` 增量 ≤ 實際寫入 + 5。
4b. **T11**:背景每 0.2 s `mount -o ro,noload` + umount 30 s,同時改後綴 → ≤ 60 s 跟上且 `cfgsave-mount.failed` 不存在、無 `saved` 但內容不變的情況(比對 stdout 與 p5)→ 否則 `FAIL writer silently read-only under ro readers`。
5. 白箱 marker:`echo "0 test" > $RUNDIR/cfgsave-mount.failed` → `batman-slot precheck-node` rc 0(`--check` 0 → marker 不看)→ 改後綴 → 下次寫入後 marker 消失。
6. 還原:`rm $RUNDIR/cfgsave-writes`(A3 計數,白箱重置)→ `batman-config-save --save` 還原 hostname → ≤ 30 s `--check` rc 0;刪 latch;`sh -c 'start-stop-daemon -S -c nobody -x /usr/bin/batman-config-save -- --check; echo rc=$?'` 輸出含 `rc=1`。
負對照:rel.1 步驟 2(G1)、4(無鎖)、4b(T11)、前置 `--check` 不存在 → 固定字串 FAIL,known-failures 掛 #202。
**D2 `setkey-persists-202`(tier B,DNODE = 04,有乙太網;D:離網兩次 + 重開一次)**
前置:`batman-config-save --check` 存在(否則 `SKIP-REASON: pre-#202 image`;4b 在舊 image 上會真刷 04);p6 無 hold-commit 旗標;`is-trial` rc 1;payload 過 fault-injection `precheck()`(== 執行中 build)。
節點端單一腳本(setsid,結果檔 `/opt/batdata/log/dv202.out`,看門狗 150 s 以 `halow-setkey --mesh <old>` 還原);harness 送腳本 → 等 DNODE 重新 JOINED → 讀回逐項斷言;檔缺/空 = FAIL。
1. 字元集:`halow-setkey --mesh 'ab&cd12345'` → exit 2、key 不變。
2. channel:`--channel 36`(US)→ exit 2 不改;`--channel <目前值>` 單獨 → exit 0、輸出含 `4 MHz @ 922.0`(會 reload 一次 = 離網 ①)。
3. 持久化:`--mesh <tmp-key>`(離網 ②)→ exit 0、`persist: saved`;p5 key md5 == 新;`precheck-node` rc 0;`p5-check.rc` 含 `fresh`。
4. stale(用 **hostname** 不用 key,擋失效時 fresh slot 仍可入網):`uci set hostname=<x>; uci commit`(不存)→ `--check` rc 5 含 `hostname`;`precheck-node` rc ≠ 0 含 `STALE`,`p5-check.rc` 含 `stale:`;`BATMAN_ALLOW_STALE_P5=1 batman-slot precheck-node` rc 0 且判定 `stale-allowed`。
4b. `-F`:`sysupgrade -F -n <已 precheck 的同 build payload>` → `waitboot`;重開後 active slot 不變、`is-trial` rc 1、`ota-trace.log` 最後一組含 `S2 REFUSE why=p5-stale` 與 `S2 END rc≠0`;`ots_wait` + `fleet_settle`。
4c. 覆寫不誤擋(白箱,不 OTA):寫 `p5-check.rc` = `skip:unseeded-allowed <now>` → `BATMAN_FAULT_INJECT=stage2 batman-slot node_checks-dry`(新的 dry 入口只跑讀檔分支)rc 0;寫 `stale:x <now-700>` → rc ≠ 0 含 `no fresh stage-1`。
5. 還原:`halow-setkey --mesh <old>`(= `--save`)→ hostname 由 `--save` 一併還原;p5 == 舊;precheck rc 0;JOINED ≤ 180 s。
負對照:rel.1 → 前置 SKIP(誠實:4b 的負對照由 T7 程式事實 + 一次人工在 rc 前後各跑提供,PR 標 ⚠️);步驟 1/3/4 在 rel.1 用 `DV202_FORCE=1` 人工跑一次取 FAIL log 附 PR-H。
**D3 fault-injection case `p5`(reflash-survives-config)**,由 daily-validation destructive 區塊接進:`suite reflash-survives-config-202 "…(DESTRUCTIVE, reflashes MESH_NODE)" "$REPO/scripts/fault-injection.sh $MESH_NODE --case p5" D`(節點來自 harness 變數,不寫死;`fi all` 不含 p5,寫明)。
前置:`precheck()`(payload == 執行中 build,否則 SKIP-REASON 絕不刷);`is-trial` rc 1;無 hold-commit;記 boot_id / slot / version / p5 快照(遮罩)。
1. `uci set hostname=<old>-fi202; uci commit; batman-config-save --save`;`--check` 0。
2. `ota_boot`;`waitboot 600`。
3. 新槽:slot 翻轉;hostname == 新;mesh key ≠ placeholder、`halow-setkey --status` 無 blocked;AP key md5 同 OTA 前;JOINED ≤ 240 s;BATMAN_VERSION 不變。
4. `committed()` ≤ 300 s(預期 60–180 s);否則等到 DEADLINE 600 s + 開機(≤ 900 s)判 revert = FAIL 附 autocommit log。
5. 還原 hostname + `--save`;`--check` 0;p5 快照對照。每跑一次節點換槽並 commit → DUT 現況檔。D3 = DoD 第 1 條黑箱證明,非 A/B/C 負對照(PR 明寫)。
**CI**:`check-provisioning-sync`、shellcheck、`check-tmp-trust`(`cfgsave.lock/`、`cfgsave-lock.busy`、`cfgsave-writes`、`p5-check.rc`、staging 前綴先進 `rundir-paths.txt`;目錄型條目的規則在 PR-H 確認)、`ab-card-invariants` 不動。

## 9. 實作切法

- **PR-H(先)**:`test/202-harness` → main:D1、D2(+ 節點腳本)、D3 case + daily-validation suite 行、`rundir-paths.txt` 新條目、harness 辨識 `REFUSING … STALE|lock-busy|no fresh stage-1`、known-failures(固定字串,#202)、rel.1 FAIL log。
- **PR-P**:`feat/202-config-survival`:`joinwatch`、`batman-config-save`(C0–C3、A2–A4、B2–B5、rc 表)、`halow-setkey`(C4)、`batman-slot`(C5 兩段 + `node_checks-dry` + `otalog_k S2 REFUSE`)、`platform-ab.sh:299` 註解、文件(§2 E)、`rundir-paths.txt` 移除 `config-saved`、本文件。兩份(deploy/ + feed/)同步。
- rc `1.5.12-wsl.N` → OTA 02 與 04 → **同一 rc payload 放到節點 `/opt/batdata/ota.tar.gz`** → D1/D2/D3 → 全套 → PR → 使用者 merge → firmware pin bump → 出貨產物煙霧/全套。

## 10. 殘項(關單時回 #202)

LOCKED 黑箱;Pi 3 `--save` gate 實測;autocommit 單台建網(#254);LUKS;`--country`;`/etc/config/wireless` 0644(→ #13);bypass 路徑只程式碼審查;`wifi reload` 窗 lkg 洞;回滾後 T1;外部 ro 讀者不持鎖(靠寫側重試)。

## 11. v2 審查發現 → v3 對應

| 發現 | 收法 |
|---|---|
| A-M1 / B-M3 判定檔缺檔誤擋 | C5:stage 1 每次寫生效後判定;stage 2 只對 `stale`/缺檔/過期(600 s)die;env 形式註明;矩陣加覆寫列、LUKS 列;D2 4c |
| A-M2 鎖接管/忙碌不可見/`--check` 逾時 fail-open | C0:pid+cmdline 接管;`cfgsave-lock.busy` + warn;`--check` rc 8 → C5 die |
| A-M3 / B-M1 marker 永留、ro/rw 互撞 | A4 + C0 掛載規則(驗證 rw、重試、成功清 marker);C5 只在 `--check` ≠ 0 看 marker;**T11 探針已做**;D1 步驟 4b/5 |
| A-M4 / B-M2 rc 6 不進快取 | C1:0/4/6 都進快取 |
| A-M5 / B-M5 D2 4b | 前置 `--check` 存在、payload precheck、hold-commit、stale 用 hostname、`otalog_k S2 REFUSE` token、`ota-trace.log` 斷言、`ots_wait`/`fleet_settle` |
| B-M4 / A-m4 D1 步驟 4 | 真並行 + `overrides == lkg == live` 斷言;A3 計數白箱重置;步驟 6 用 `--save` 還原 |
| B-M6 D3 沒接進全套 | D3 以 `suite … --case p5` 接進 destructive 區塊,節點 `$MESH_NODE` |
| A-m1 讀回時序 | C4 步驟 3 輪詢、channel 60 s、逾時不還原 exit 3 unverified |
| A-m2 / B-m1 rc 多義 | rc 表:6 unpersistable、7 unseeded、8 lock-busy |
| A-m3 / B-m2 B2 後果 | placeholder 視同空;矩陣「升級到本版」列(一次性重寫 + 未入網被擋) |
| A-m5 判定年齡 | stage 2 600 s |
| A-m6 harness 辨識 STALE | C7、PR-H |
| A-m7 bypass 措辭 | C5 失效模式段改寫 |
| A-m8 start-stop-daemon rc | D1 步驟 6 用 `sh -c … echo rc=$?` |
| A-m9 csv 行數 | 我自己 `grep -c .` = 631 ✅ |
| B-m3 `--check` 等鎖預算 | C0 5 s;C5 rc 8 處理 |
| B-m4 A3 vs D1 步驟 5 | 白箱重置計數 + `--save` 還原 |
| B-m5 D2 兩次離網 | D2 標題與步驟 2 註明 |
| B-m6 kHz/MHz | C4 步驟 3 `centre × 1000` kHz 整數比對 |
| B-m7 lock 是目錄 | §3 備註;PR-H 確認 rundir-paths 規則 |
