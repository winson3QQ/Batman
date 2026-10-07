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
