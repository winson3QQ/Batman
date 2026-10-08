# #265 + #261 autocommit:commit 前重驗 canary + 「驗收前不 commit」旗標(ab-autocommit v2.4)

狀態:設計 v1(待 review)· 2026-10-07 · 範圍:`feed/batman-provision/files/usr/bin/batman-autocommit`、`scripts/fault-injection.sh`(R1、新 R3)、`docs/design/ab-autocommit.md`

## 0. 背景(reality check)

**#265**:`health_ok()` 的 canary 成功一次就 latch(`/tmp/autocommit.canary-ok`,第 328–331 行),之後的 poll 都不再跑。這是 v2.3 刻意的設計(review S3:Pi 3A+ 只有 512 MB,不想每 10 秒跑一次 canary)。結果是 latch 之後 runc 壞掉,trial 照樣被 commit。
- 實測證據(#268 加的 R1 診斷,04 Pi4 1.5.4):`canary latched 46s before injection (uptime 97s)` → `R1 committed a broken trial`。兩次 destructive 結果相同(另一次 41s)。

**#261**:沒有「trial 先不 commit、deadline 照常 revert」的持久開關。
- `autocommit-hold-once` 只取消 revert,不擋 commit;`autocommit-skip-once` 會同時關掉 commit 和 revert(新版讓節點掉出 mesh 時 = 失聯)。
- Pi4 約 85–100 秒、Pi3 約 85 秒就 commit,沒有時間在 trial 內做驗收。

**兩者的關係**:光修 #265,R1 仍然會時好時壞。R1 是在開機第 92–97 秒弄壞 runc,commit 也大約在 85–100 秒發生。commit 若先發生,commit 前的重驗照樣會通過。要讓 R1 有確定的結果,測試必須能「先擋 commit → 注入故障 → 放行」,這就是 #261 的開關。

## 1. 設計

### D1(#265)commit 前重驗 canary
在主迴圈決定 commit 的分支裡(`ok >= NEED` 且 `why` 為空),**拿 claim 之前**:
```
if have_docker_tenant; then
    c=$(canary_run) || { rm -f "$CANARY_LATCH"; why="pre-commit canary failed: $c"; echo "$why" > /tmp/autocommit.why;
                         log "health regressed at commit time ($why) — resetting dwell"; otalog AC PRECOMMIT-CANARY-FAIL why="$c"; ok=0; sleep $POLL; continue; }
fi
```
- 不看 latch,每次要 commit 都實際跑一次(Pi 3A+ 實測:import <1 s、run 5 s、約 4 MB)。只在要 commit 時跑,平常的 poll 仍然用 latch → 不違背 v2.3 S3 的記憶體考量。
- 失敗就**清掉 latch**:之後每次 poll 的 `health_ok` 都會重跑 canary 並失敗 → `ok` 一直是 0 → 不會 commit → watchdog 在 deadline revert。
- `have_docker_tenant` 的判斷抽成函式(目前寫在 `health_ok` 裡;`health_ok` 在 `$(...)` subshell 執行,變數帶不出來)。
- 剩下的競態:重驗通過之後、`batman-slot commit` 寫完之前(毫秒級)才壞掉 → 照樣會 commit。commit 之後才壞的情況,本來就不在 autocommit 的範圍內(那是 guardian / watchdog 的事)。

### D2(#261)hold-commit 旗標
- **p6 一次性旗標** `/opt/batdata/state/autocommit-hold-commit`:在 real tryboot 開始時(和 hold-once 同一處)**消耗掉**,改寫成 `/tmp/autocommit.hold-commit`(本次開機有效,main 重啟也看得到)。
  - 消耗時 `aclog HOLD-COMMIT` + `otalog AC HOLD-COMMIT`。
  - 只在 real tryboot 消耗;committed slot 開機不消耗(避免 operator 先放好旗標,結果被一次普通重開吃掉)。
- 有 `/tmp/autocommit.hold-commit` 而且**沒有** `/tmp/autocommit.released` 時,主迴圈健康也不 commit:`why="held for operator acceptance (batman-autocommit release)"`,寫進 `/tmp/autocommit.why`(halow-status 的 LAST OTA 看得到)。**watchdog 照常在 deadline revert**。
- `batman-autocommit release`:
  - 必須是 root,而且 `/tmp/autocommit.hold-commit` 存在、這次開機確實是 trial;否則印原因、exit 1。
  - 建立 `/tmp/autocommit.released`(root-owned;main 用 `[ -O ]` 檢查,因為 /tmp 人人可寫)。
  - **不直接 commit**:只是解除擋住。由主迴圈照常走「NEED 次健康 + D1 重驗 + claim + commit」,不另開一條 commit 路徑(避免和 watchdog 的 claim 搶)。
  - `release --wait`(給測試用):等到 `/tmp/autocommit.committed` 出現,或主迴圈結束、或 deadline 到,印出結果。
- **hold-commit 和 hold-once 是不同的旗標**:hold-once = 「不要 revert」(planned mesh-breaking OTA,手動 commit);hold-commit = 「不要自動 commit,但要 revert」。兩個都設時,hold-once 讓 watchdog 不 revert,hold-commit 讓主迴圈不 commit → trial 一直停在未 commit 的狀態,直到 release 或 operator 手動處理(和現在只設 hold-once 的行為一致,只是多了「不自動 commit」)。文件寫明。

### D3 fault-injection R1 改成確定性 + 新增 R3
- **R1**(壞 trial 必須回退):OTA 前先 `touch /opt/batdata/state/autocommit-hold-commit` → OTA → trial 起來、確認是 trial、確認 `HOLD-COMMIT` 已消耗 → 弄壞 runc → `batman-autocommit release` → 預期:**不 commit**(log 有 `pre-commit canary failed`)→ 在 deadline revert 回原 slot → OTS 6/6、canary OK。
  - 等待時間:deadline = Pi4 600 秒(uptime);R1 等到 deadline + 120 秒。比現在多約 8 分鐘,只在 release gate 跑。
  - 移除「latch 是否在注入之前」的判斷(hold-commit 之後不再有賽跑);保留診斷輸出。
- **R3**(新增,#261 正向):hold-commit → OTA → trial 健康 → 確認 `why` 是 held、**超過 NEED×POLL 的時間仍未 commit** → `release --wait` → 必須 commit。
- known-failures 清單移除 #265 的兩行(修好之後 R1 應該 PASS;還 FAIL 就是新 FAIL)。

### D4 文件
`docs/design/ab-autocommit.md` 加 v2.4 一節:D1/D2、表格加兩列(hold-commit → 不 commit → deadline revert;hold-commit → release → commit)、和 hold-once 的組合。

## 2. Alternatives(不採用)
- **拿掉 latch,每次 poll 都跑 canary**:Pi 3A+ 每 10 秒多 5 秒的 docker run、約 4 MB,違背 v2.3 S3;而且仍然有「最後一次 poll 之後才壞」的競態。D1 只在 commit 前多跑一次,覆蓋同樣的情況。
- **R1 改成 trial 開機前就是壞的**(在 payload 或 overlay 裡放壞的 runc):侵入性大,而且測的是另一件事(「開機就壞」canary 本來就抓得到),不是 #265 的 TOCTOU。
- **`release` 直接 commit**:多一條 commit 路徑,要另外處理 claim 競態和 pre-commit 檢查;不如讓主迴圈照原路走。
- **hold-commit 放在 /tmp**:重開就消失,做不到「OTA 前先設好」。

## 3. Failure modes
| 情況 | 結果 |
|---|---|
| 設了 hold-commit 卻沒人 release | deadline revert(和 #261 的要求一致:沒人驗收 = 回舊版) |
| 設了 hold-commit,trial 掉出 mesh(新版不相容) | deadline revert(本來就該這樣;要 commit 不相容版本的人應該用 hold-once) |
| release 時 runc 已壞 | D1 重驗失敗 → 不 commit → revert |
| release 後、commit 前 main 被 restart | 新 main 接手,`/tmp/autocommit.released` 還在 → 照常 commit |
| 非 root 建 `/tmp/autocommit.released` | `[ -O ]` 擋掉 |
| committed slot 開機時有 hold-commit 旗標 | 不消耗,留給下一次 OTA(log 一行) |
| D1 的 canary 因為 p6 快滿無法 import | `canary_run` 已回 `p6 nearly full` → 不 commit → revert。和平常 poll 的行為一致 |

## 4. 測試計畫
- **dry-run(bench)**:`AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1`:(a) 正常 → COMMIT;(b) hold-commit → 不 commit、why = held;(c) hold-commit + release → COMMIT;(d) latch 已存在但 canary 會失敗(暫時改名 runc)→ 不 COMMIT、latch 被清掉。
- **真機,兩板**(#261 要求;共用 A/B 檔案):
  - 04(Pi4):fi-r1 必須 PASS(回退)、fi-r3 必須 PASS(commit);fi-f1/f2/r2 不回歸。
  - 03(Pi3):fault-injection 需要 OTS(Pi3 沒有)→ 用手動流程:hold-commit → OTA → 確認不 commit → release → commit;另一輪不 release → deadline(900 秒)revert。
- daily-validation 全套(destructive + 非 destructive)。

## 5. v1.1 — review(PASS-with-changes)意見併入,取代上面的對應段落

| # | review | 決定 |
|---|---|---|
| 1 | D1/held 在 DRY `exit 0`(第 361 行)之後 → dry-run 測不到;held 期間每輪都會進 commit 分支跑 canary;held 被記成 `UNHEALTHY first_why` | **held 在算 `why` 時就併進去**(第 360 行之前),所以 held 期間根本不會進 commit 分支;**D1 放在 DRY 那行之前**(DRY 也跑重驗);held 另記 `otalog AC HELD`(一次),不算 UNHEALTHY |
| 2 | 旗標殘留:UNKNOWN / fw-override / skip-once / stale fallback / EEPROM 開錯槽 / OTA 沒成功,都會在消耗前 exit | (a) **任何 `dt_tryboot=1` 的開機,在 is-trial 判斷之後、所有 early-exit 之前就消耗**。(b) **旗標內容 = 目標版本**(`BATMAN_VERSION` 全字串):消耗時版本相符才生效,不符就丟棄並 log `HOLD-COMMIT-DISCARDED (flag for X, booted Y)`。不用 TTL:節點沒有 RTC,時鐘只是 faketime 的下界。(c) `halow-status` 和 daily-validation(`autocommit-211`)會顯示「hold-commit armed for X」。(d) fault-injection 的 `restore_node` 和所有 early-return 都 `rm` p6 旗標 |
| 3 | stale fallback 會無視 hold-commit | **明確的例外,寫進文件**:hold-commit 只作用在旗標指定版本的 real tryboot。stale fallback 不是 operator 發起的那次 trial(韌體自己退回),維持現行 v2.3 的 guarded commit。旗標在那次開機若 dt_tryboot=0 就不會被消耗,留給真正的 trial |
| 4 | /tmp marker 可被 symlink 繞過或 clobber;非 root 可預建 hold marker 造成 DoS | marker 放在 **root 擁有、0700 的目錄 `/tmp/autocommit.ctl/`**:建立時 `mkdir -m700`,每次使用前檢查 owner=root、不是 symlink(`[ -d ] && [ ! -L ] && [ -O ]`);不符就視為**沒有 hold、也沒有 release**,並 log。不放在 `$RUN`(takeover 會 `rm -rf`)。DRY 模式:不刪 p6 旗標,只寫 `/tmp/autocommit.ctl.dry/`。現有 `/tmp/batman-autocommit.hold` 的同類問題另開單 |
| 5 | release 在 deadline 之後、或 main 已死時呼叫,不會有效果 → trial 永遠未 commit | `release` 先檢查:目前是 trial、`hold-commit` 已生效、`main_alive`、`up < DEADLINE`;任一不成立 → 印原因、exit 1,提示 `batman-slot commit`(人工)。`--wait`:結束條件 = COMMITTED / main 已死 / uptime ≥ deadline / slot 改變;本地上限 = deadline − now + 30 秒 |
| 6 | R1 可能假 PASS;R3 太弱 | **R1 的 PASS 條件要全部成立**:release exit 0 且 released marker 存在;log 有 `PRECOMMIT-CANARY-FAIL`;aclog `TRIAL-REVERTED` 的 reason 含 `canary`、不含 `held`;revert 後 slot = pre;`bad-slot` 記的是 trial slot。等待改為**輪詢** boot_id/slot,直到 watchdog 的 revert reboot(上限 = deadline + 120 秒),**移除手動 reboot**。**R3**:確認 why **只有** held;等到 uptime ≥ 240 秒仍未 commit;release 後 60 秒內必須 commit;全程在 deadline 之前。R1/R3 都先斷言 `HOLD-COMMIT` 已消耗、p6 旗標已不在 |

## 6. v1.2 — harness 收尾(2026-10-08,rc4 全套的兩個 FAIL 類型)

產品部分(D1/D2)在 rc4(1.5.5-wsl.4)上已確認流程正確,04 的 autocommit.log 依序出現 `HOLD-COMMIT → HELD → RELEASED → PRECOMMIT-CANARY-FAIL → REVERT → BOOT slot=A committed`。剩下兩類 FAIL 都在 harness:

### H1 fault-injection:讀取在 mesh 重組空窗失敗,被當成產品 FAIL
- 現象(rc4 fi-r1):revert 之後 04 開回 A,要重新加入 mesh(`mesh not joined 0/3`)。主機要經過 03→mesh 才能連到 04。`waitup` 成功、再 `sleep 20` 之後,ssh 還會斷一陣,所以讀到空字串:
  - `aclog:` 是空的;
  - `post=` 是空的;
  - `committed` 判成否。
  - 結果 4 個 FAIL。
- 修法:
  - **`settle`**:連續 3 次 ssh 成功(間隔 5 秒)才算節點穩定,上限 N 秒。所有「等節點回來再判定」的地方都用 settle,取代 `waitup; sleep`。
  - **`q`**:判定用的讀取。ssh 回 255(連線層失敗)時重試，最多 6 次、間隔 10 秒；其他 rc(含命令自己的 0/1)照原樣回傳。6 次都 255 就設 `UNREAD`,回 255。
  - **動作**(sysupgrade、reboot、mv runc、release)仍用 `n`,不重試，因為它們不是 idempotent。
  - 每個判定在下結論前先看 `UNREAD`。有的話印 `FAIL <case> UNDETERMINED: node unreadable (<what>) — not verified`,不判產品結果。
    - daily-validation 的 `classify` 會把 `unreadable` / `not verified` 歸為 NEVER_KNOWN,所以一定算 NEW。
    - 「讀不到」不能被當作 PASS,也不能被當作已知產品 FAIL。
  - 套用範圍:
    - R1/R3 全部的判定讀取;
    - R2 的 `committed` / `ots_up` / latch;
    - F1 的 `left` / `failed` / `ots_up`;
    - F2 的 `ots_up`;
    - `restore_node`。
  - **輪詢迴圈不套 `q`**:R1 等 revert 的 bootid 迴圈、R3 的 uptime 迴圈。這類迴圈本來就預期會連不上，讀不到就是下一輪。但 R3 迴圈結束後的 `why` 判定讀取要改用 `q`。

### H2 daily-validation:destructive suite 讓 fleet 暫時斷線，下一項被 SKIP
- 現象(rc4):`ramoops-173` 讓 03 panic。03 是主機進 mesh 的唯一橋，所以 02/04 也斷了 1–2 分鐘。下一項的一次性 `up` 失敗 → SKIP。
  - #274 已經對自己的兩項加了 `dwait 300`。
  - 但通用問題還在:fi-* 讓 04 重開之後接著跑的 meshtest(MESH_NODE)/ flash-write-guard、rejoin-245 之後的各項、halow-fi-263 之後的 soak。
- 修法:`suite()` 結尾呼叫 **`fleet_settle "$name"`**。
  - **fleet** = 執行開始時 `up` 成功的 {BENCH, MESH, OTS, DNODE, DV_T263_NODE}(去重)。開始時就不在的節點不等，那些 suite 會照現行規則 SKIP 並寫原因。
  - **快速路徑**:每個 fleet 節點 `up` 一次(約 1–2 秒)。全部都回應就結束。
  - **慢速路徑**:有節點沒回應，或 suite 名稱符合 `DESTRUCTIVE_RE`(會讓節點重開或掉出 mesh 的項目:`ab-selftest|fi-.*|rejoin-245-246|faketime-174|guardian-192|ramoops-173|converge-274|cleanstop-274|halow-fi-263|hold-261-.*`)時，每個節點都要**連續 3 次 `up` 成功(間隔 5 秒)**,上限 300 秒。
  - 300 秒還等不到的節點:
    - 加一列 `fleet-settle-after-<suite>` = **FAIL**,寫明節點和等待秒數。這不是 SKIP:一個 destructive suite 結束後 5 分鐘還回不來，是實際發現的問題。
    - 把該節點移出 fleet,不再重複等，避免每項都多花 300 秒。之後的 suite 會照常用 `up` 判斷 → SKIP 並寫明原因。
  - `DV_ONLY` 沒選到的 suite 不會執行，也不做 settle。
  - 成本:快速路徑每項約 3–6 秒,55 項約 3–5 分鐘;全套 destructive 本來就要數小時，可以接受。

### H3 Pi 3 兩板實測進 daily-validation(#261 要求兩板)
- fault-injection 的 R1 需要 tenant(canary),Pi 3 沒有 tenant。所以 **R3(hold → release → commit)** 和新的 **R4(hold、不 release → deadline revert)** 要能在沒有 tenant 的節點上跑:
  - 節點沒有 `*.manifest` 時，略過 OTS 6/6 的斷言(印 `no tenant on this node — OTS not asserted`)。
  - 有 tenant 時照舊斷言。
- **R4 判定**(全部要成立):
  1. 不 release;
  2. 期間從未出現 committed;
  3. 等到 boot_id 改變(上限 deadline + 180 秒);
  4. settle 之後 slot == pre 而且已 committed;
  5. aclog 的 `TRIAL-REVERTED slot=<trial>` 的 reason 含 `held`;
  6. `bad-slot` **記錄** trial slot。現行 code(watchdog,第 213 行)每次 revert 都會寫 bad-slot,held 也一樣。這是正確的:沒被驗收的版本不能被 #133 stale fallback 拿去 guarded commit。
- daily-validation:新增 `hold-261-release` / `hold-261-norelease`,在 DNODE 是 bcm2710 時對 DNODE 跑:
  - `fault-injection.sh $DNODE --case r3` 和 `--case r4`;
  - 放在 FEATURE_MODE=--destructive、DNODE 有 eth 的區塊。
  - Pi 4 由 OTS_NODE 的 fi-r1/fi-r3 涵蓋。
  - DNODE 是 Pi 4 時，這兩項為 N/A,因為 fi-r1/r3 已經涵蓋同一個 SoC。
- 03 是主機進 mesh 的唯一橋:它 OTA 或 revert 時 02/04 會暫時斷線。這正是 H2 要處理的情況，而且會被實際觸發到。

### H4 驗收(改自 §4)
1. **離線**:`bash -n`、`shellcheck -S warning`。
   - stub 測試:用假的 ssh(回 255 若干次後才成功)證明 `q` 會重試、`UNREAD` 會變成 UNDETERMINED FAIL,而且不會變成 PASS。
   - `fleet_settle` 用假的 `up`,證明三條路徑:快速 / 慢速成功 / 逾時 → FAIL 列 + 移出 fleet。
2. **rc(1.5.6-wsl.1)兩板 build、ab-card、OTA fleet。**
3. **04**:`fi-r1` ×3 全 PASS、`fi-r3` PASS、fi-f1/f2/r2 不回歸。
4. **03**:`hold-261-release`、`hold-261-norelease` PASS。
5. **全套 destructive daily-validation**(DESTRUCTIVE_NODE=03),驗收條件:
   - 不再出現「did not answer」SKIP;
   - 沒有 fleet-settle FAIL;
   - 除了 #264 的兩項外沒有其他 FAIL。

## 7. v1.3:review of v1.2(APPROVE-WITH-CHANGES,18 項)的處理

全系統 scope 的獨立 review。下表是每一項的處理方式，已全部實作。

| # | 問題 | 處理 |
|---|---|---|
| 1 | R1 等 revert 的迴圈讀兩次 bootid;讀不到也會被當成換了 boot | `wait_revert`:每次輪詢只讀一次。讀不到就跳過那一輪，不判斷 |
| 2 | `UNREAD` 變數在 `$(...)` subshell 裡設定，主程式看不到 | 改寫到檔案 `$UNREADF`。stub 測試有測 `$(q … \| tr)` 這種情況 |
| 3 | ssh 連上後路由斷掉會一直卡住 | `ServerAliveInterval=5`/`CountMax=3`,另加 `timeout`(預設 90 秒,precheck 600 秒)。rc 124 和 255 一樣會重試。文件註明：讀取用的遠端命令不能自己 exit 255 |
| 4 | Pi 3 沒有 tenant,`restore_node` 一定 FAIL | `--no-tenant` 時，`restore_node` 只驗 hold flag 已移除，不驗 OTS、dockerd、canary |
| 5 | 從節點推斷「沒有 tenant」可能造成 false PASS | 改由 caller 宣告 `--no-tenant`。沒宣告卻找不到 tenant = FAIL(`need_tenant`) |
| 6 | 兩板覆蓋不完整 | Pi 3:`hold-261-*` 在 fleet 裡第一台 bcm2710 上跑，找不到就 SKIP(不是 N/A)。Pi 4:OTS host 新增 `fi-r4` |
| 7 | 等待上限沒算到 watchdog 的 DEFER_MAX | 上限改為 deadline + 600 + 120 秒。逾時會印出 watchdog 的 log(`revert deferred` 等)作為證據 |
| 8 | `sleep 50; waitup` 分不出「已重開」和「sysupgrade 還在寫」 | `ota_boot`:先記下 boot_id,等它變了(上限 600 秒),再 settle |
| 9 | R3 迴圈沒有上限，也偵測不到重開 | `wait_held`:每輪單次讀取 boot/uptime/committed/why,上限是 deadline−120。不用固定的 240 秒，改成連續 held ≥60 秒 |
| 10 | 殘留的 hold flag | `restore_node` 用 `q` 刪除後再驗證，還在就 FAIL。`autocommit-211` 對**每一台 fleet 節點**檢查，有殘留 flag 就 FAIL |
| 11 | `DESTRUCTIVE_RE` 是手寫清單，會漂移 | 改成 `suite` 的第 4 個參數 `D`,由呼叫的地方宣告。settle 只在 suite 真的有跑時做。settle FAIL 走 FAILED/log 的正常路徑，列為 NEW |
| 12 | settle 沒看 boot_id | 3 次回應必須是同一個 boot,而且 uptime ≥ 60 秒 |
| 13 | 判定用單次讀取;revert 原因寫死 | OTS 改成輪詢(≤240 秒)。revert 原因接受 `canary` 或 `docker engine not live`,但 `PRECOMMIT-CANARY-FAIL` 仍然必須出現 |
| 14 | hold 有 fail-open 路徑 | (a) control dir 不安全：先刪掉重建一次，還是不行就 **fail closed**(`HOLDUNSAFE`:不 commit、保留 p6 flag、deadline revert)。(b) 若 marker 已存在，直接刪掉 p6 flag。(c) flag 被丟棄的原因寫進 `/tmp/autocommit.hold-discarded`,halow-status 會顯示 |
| 15 | halow-status 狀態判斷 | 判斷順序改為：committed > released > hold-once(不 revert)> HELD。只信任 root 擁有的 control dir |
| 16 | `release --wait` 競態 | 回報「沒 commit」之前再檢查一次 COMMITTED |
| 17 | bad-slot | 文件已寫明是刻意設計：只有下一次成功 commit 才會清掉 |
| 18 | 流程 | `/tmp/batman-autocommit.hold` 的同類問題記在 #265 原單，不另開單。usage 和 header 已更新(r3/r4、`--no-tenant`) |

**離線證據**:
- `scripts/test-harness-265.sh` 共 21 項，用 stub ssh 測，全部 PASS。CI(`ci.yml` lint)和 daily-validation 的 `harness-265` 都會跑它。
- mutation 測試：把以下 6 個修正逐一改回 bug 版本，每一個都會讓測試 FAIL:
  - `UNREAD` 改回變數;
  - 不重試 124;
  - 讀不到當成新 boot;
  - 拿掉 uptime 下限;
  - fleet_settle 忽略 `D`;
  - 不寫 FAIL 列。
- 已知限制(記在原單):
  - #133 stale fallback 不受 hold-commit 影響。
  - pre-commit 重驗通過之後到 commit 之間(毫秒級)的 TOCTOU。
