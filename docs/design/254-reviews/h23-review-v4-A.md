# Review A(第 4 輪):`254-h23-harness.md` v4(37b62e8;2026-10-28,唯讀;未碰 02 / 04)

審整份 v4(乾淨全文),先走 22 h 無人值守的真實跑法(每個階段 harness 死、`pr_normalise`、restore 中、`-wbox` 殘留、killpoint 已 arm、兩個操作員、02 在 `prov-netjoin-fleet` 認領後),再逐條對 F1–F41 與 §4–§6 的判定字串 / 錯誤碼 / 行號查原始碼(Batman-h23 工作樹 37b62e8;firmware-2710 工作樹,含 a72 kernel 6.6.138 原始碼與 `root-bcm27xx` staging rootfs),最後逐條核對 v3 A / B 每個發現。

## 摘要

v3 的 13 個 MAJOR 全部有實質處置,而且處置都對得上原始碼:hold 不擋 revert(`batman-autocommit` 的 watchdog 只看 `held()` `:202,234`,`held_commit()` `:60` 只折進 why `:511-513`);`ble-ok` 每次 poll 都重讀(`:496` 在 `while` 迴圈內,`:487`)所以臂 C 成立;`restoreWireless` 只由 daemon 以 120 s 排程(`main.go:441-443`;`--boot` 模式無人呼叫,grep 零命中)所以 txn-2 (a) 的視窗存在;`.txn` 分支不看 gen(`boot.go:115-120`)所以 `helper-norebuild` 定義正確;`--check` 在 prov 相等後仍比 overrides 並以 `p5 stale: <keys>` exit 5(`batman-config-save:440-450`)所以 txn-4 判定成立;`/proc/sysrq-trigger` 走 `__handle_sysrq(c, false)`(`sysrq.c:1160`);`scripts/dv/*.sh` 確實被 tmp-trust 掃(`check-tmp-trust.sh:29`;allowlist `:13` 無邊界)。

還留下 2 個會在無人值守 run 裡製造**壞狀態或假 FAIL** 的問題與一批 MINOR:

1. (9) 故意 `release` → **commit 一個 `-wbox` 槽**再跨槽還原,違反 §4.2 / §3 自己立的「wbox 只進非 committed 槽、一律 hold」與 P9「committed 含 wbox → FAIL」;harness 死在 commit 之後 → 04 停在 helper 每 5 s 退出的槽上,§5 沒有這一列;而且不必要(`AUTOCOMMIT_DRYRUN` 已能印 `DRYRUN decision: COMMIT`)(M1)。
2. 預期 REVERT 單位等 `TRIAL-REVERTED` 的上限 720 s 沒算進 watchdog 的 `DEFER_MAX=600`(`:35,222-231`):slot write / first-load / payload converge 進行中時 revert 可延到 uptime ≈ 1200 s → 假 FAIL → `pr_abort`(M2)。

**BLOCKER 0 / MAJOR 2 / MINOR 14 → APPROVE-WITH-CHANGES**(M1 / M2 修法都是一段文字,不動 §3 / §4 架構;v5 可窄範圍複查 M1 / M2 + m1–m5)。

---

## MAJOR

### M1. (9) commit 一個 `-wbox` 槽:違反 §4.2 / §3 / P9 的不變量,§5 無對應列,且不必要
- **情境**:§6.2 (9):`-wbox helper-flap` hold → HELD → **`release` → commit(P-U5)→ 跨槽還原**;§7.2 列 (9) 副作用「B 被 commit(mutant 槽)→ 跨槽還原」;§7.3 為它算 15 分。harness 死在 commit 之後、跨槽還原之前(或 `pr_brewrite` 之前)→ 04 committed 在 `helper-flap` 槽:helper 每 5 s `os.Exit(1)`、procd 5 s respawn(`batman-provhelper.init:13`),provisioning 服務實質不存在;prov deadman「不碰槽」(§3)所以不會回 A;P9 下次 FAIL「committed 槽含 wbox」→ 需人、OTS 停。
- **證據**:§4.2「**只進非 committed 槽;一律 hold**;P9:committed 槽 `.protected` 缺或含 `wbox` → run FAIL」;§3 B 槽列「單位期間:產品 `sysupgrade -n`(**一律 hold**)」;§1.4「不會 commit mutant 槽」;§5 只有「誤 commit(產品 bug)後 harness 死」,沒有「(9) 故意 commit 後 harness 死」。(9) 要證的只是「health 不 stale + WARN 不擋」:`batman-autocommit:529` `DRYRUN decision: COMMIT slot …` 在 `AUTOCOMMIT_DRYRUN=1` 下就會印(鏈 1 第 8.7 步已用同一招,p1-impl §5.4),不需要真 commit。
- **修**:(9) 改為「hold → `HELD`(`:513`)+ WARN 行只記錄 → 同一 trial 內 `AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=<now+60> batman-autocommit run` → 斷言 `DRYRUN decision: COMMIT` → `back_to_a`」;型別 `hold / A`;刪 §7.2 (9) 列與 §7.3 的「(9) 跨槽 15 分」;§1.4「不會 commit mutant 槽」就真的成立。若堅持要真 commit,§5 補一列 + deadman 在「committed 槽含 wbox 且 `restoring` 不在」時 `batman-slot rollback`——但這會讓 deadman 第一次碰槽,不建議。

### M2. 預期 REVERT 單位的 720 s 上限沒算 `DEFER_MAX`
- **情境**:§4.3 `pr_end` 步驟 1「等 `TRIAL-REVERTED`(≤ 720 s …)」;§7.3「revert 型 ≈ 37 分 + 600 s」。04 有 OTS tenant:B trial 第一次開機,payload guardian 若在 converge(`batman-payload-*.converging` + `payload-run --worker`)、或 `batman-slot.busy` / first-load `docker load` 在跑,watchdog 把 revert 延到最多 `DEFER_MAX=600` s 之後(log `revert deferred: …`)→ `TRIAL-REVERTED` 可晚到 uptime ≈ 600 + 600 s → harness 在 720 s 判 FAIL → `pr_abort` → restore,而節點其實正要 revert(restore 與 revert 重開賽跑)。
- **證據**:`batman-autocommit:35` `DEFER_MAX=600`;`:222-231` 延遲迴圈;`:233-246` 之後才寫 bad-slot 與 `reboot committed`;DEADLINE 預設 600(`:379-383`,Pi 4 `DEF=600`,p6 `autocommit.timeout` 可改到 3600)。
- **修**:等待上限 = `autocommit.deadline`(run dir 檔,`:384`)+ `DEFER_MAX` + 120 s,從 trial 內讀,不寫死 720;看到 `revert deferred` 行就把 lease 再 +600(同一把 flock、re-`dm_arm`);P9 讀 04 的 `/opt/batdata/state/autocommit.timeout`(存在且 > 600 → 印出,因為它改變所有 revert 型單位的預算)。§7.3 的 revert 型加「+ ≤ 600 s 延遲」。

---

## MINOR

### m1. E-H2 驗收「17 個變體 helper sha 互異」不可能成立
`96-noprov`、`radio1-off`、`chan`、`misc-*`(不碰 helper 的 release-tag 變體)建出來的 helper 二進位與正常 release 相同(`-trimpath -buildvcs=false`,F34;`BATMAN_WBOX` 只進 `/etc/batman-build`);`helper-exit1` 是 shell。改為「helper 變體(7 個 prov_test + `test` + `helper-exit1` + `helper-flap`)sha 互異且 ≠ release;其餘 = release helper sha」。§4.7 P9「`prov-test` helper 17 份 sha」同改。

### m2. `upper-helper` 的 mutant 副本撐過重開,但 deadman 不清
§3:A 槽 upper 的 `/usr/bin/batman-provhelper` 副本只由 `overlay-restore` 刪;deadman「不碰槽 / p5」。harness 死在 `upper-helper helper-norebuild` 之後 → 04 之後每次開機都跑「不以 p5 重建」的 helper(prov_test tag,P9 會抓到標記 → FAIL ✓),直到有人 restore。建議 deadman 加一步:`/overlay/upper/usr/bin/batman-provhelper` 存在且 sha ≠ `/rom/usr/bin/batman-provhelper` → `rm` + restart helper(只動 harness 自己放的檔;F6 04 的 upper 本來沒有 `usr/bin/`)。

### m3. `helper-norebuild` 跳過 `ovRec == nil` 分支後會 nil 解參考
`boot.go:180` 跳過後落到 `:185` `ovRec.Generation`,`ovRec == nil` 時 panic → helper crash loop,負對照變成「helper 沒起來」而不是「不重建」。mutant 要在 `ovRec == nil` 時回 `unknown(…)` 或 `in sync`。`lint-wbox` 管不到這個,寫進 §4.2 的變體說明。

### m4. txn-2 (a) 的 120 s 視窗要驗「注入成立」,不是直接判 FAIL
sysrq 重開 → helper S89 起 → 120 s 內 harness 要找到 04、`mv .txn`、restart。ssh 可達約在 helper 起後 30–60 s,餘裕不大。`mv` 前先斷言「`.txn` 在 **且** 本次 pid 的 log 無 `not committed: restored`」,不成立 → INVALID(重跑一次),不是 FAIL。同理 txn-1 的「`.txn` 刪」也要等 ≥ 120 s(`RemoveTxn` 在 `restoreWireless` rc 0 之後,`main.go:492-494`),§6.2 只對 txn-2 寫了「≥ 120 s」。

### m5. txn-4 killpoint 的位置要相對 `RemoveTxn` 寫死
`node.go:1115` `commitTxn`(含 overlay rename)→ `:1118` `RemoveTxn` → `:1120` `Save`。「rename 後、`--save` 前」有兩個位置:`RemoveTxn` 前(重開走 `.txn` 分支 `g == t.To` → `overlay completed from p5` 行)或後(無 `.txn` → gen 相等 → `in sync`)。判定「`--check` rc 5 + gen n+1 + wireless == prov」兩者都成立,但 `boot rc=… action=` 行不同;寫明 txn-4 = `:1118` 之後。

### m6. `pr_normalise` 的前置少了「02 在 `batctl n`」;「其他不符 → `pr_needs_person`」含 04 已在 A 的正常情況
04 legacy、p6 有 `mesh-joined` → `expected_in_mesh` → A trial `NEED_MESH=1`(`:397`);02 不在 → 600 s revert → `bad-slot slot=A version=V`(§3 自己註明的「normalise 殘骸」)。加前置。另外字面上「04 A committed V」也是「不符 = B」→ 寫明 no-op。

### m7. CI `sudo -E … go test` 的 PATH 與 `grep -c` 退出碼
GitHub runner 的 sudo `secure_path` 會蓋掉 setup-go 放進 PATH 的 go → `go: command not found`。寫 `sudo -E env "PATH=$PATH" GOFLAGS=-mod=vendor GOTOOLCHAIN=local go test -tags prov_test -v ./...`;`grep -c -- '--- SKIP'` 在 0 命中時 rc 1,`set -e` 下會把「沒有 SKIP」判成失敗,用 `[ "$(… | grep -c …)" = 0 ]`。

### m8. 範圍:claim-lock §11.4 真機 tier B(4 / 4-inj / 4b / 4b' / 4c / 4d / 5)只在 F27,§1.2 沒有處置
使用者 2026-10-26 已決定縮小(claim-lock §13),可接受;但 §1.2「不在本 PR(逐條理由)」要列它與理由,否則 §1.2 看起來是靜默漏掉。同樣:p1-impl §5.1 `prov-unit-bcm2710`(CI smoke)在 v4 沒出現,§1.2 只寫「bcm2710 真機」——寫一句(P-U14 → 連 CI smoke 都不做,或做)。

### m9. §5 缺兩列
(a) harness 死於 `prov-netjoin-fleet` 中、02 已認領 + 入測試網(非「還原失敗」):02 LOCKED、member 於測試網,joinwatch 3600 s 重開不會改回(p5 已寫);02 的 p6 dirty 由 02 的 snap 寫 ✓ → P9 擋;需人、金鑰保留。(b) M1 的 (9) 列(若保留 commit)。

### m10. `-wbox chan` 前置斷言的措辭與 `wifi reload` 次數
「120 s 內 `uci get … channel` ≠ p5 值」在 mutant 與 chanfix 交替期間(≤ 6 × 8 s)會瞬間相等;寫成「120 s 內**曾**讀到 ≠ p5 值,且 120 s 時刻 ≠ p5 值且 `batctl n` 空」。另:mutant 與 chanfix 合計 ≤ 13 次 `wifi reload`;`health_ok` 看的是 `/etc/init.d/wpad running`(`:452`),不受影響,但 (7) 04 側本來就不等 HELD。`wifi reload` 對 morse 真的換頻道這點只有 chanfix 自己的註解當證據 → E-H7 ✓ 必做。

### m11. init 類 mutant 要驗 `enable`
`files/etc/init.d/wbox-chan` 要在 rootfs 有 `/etc/rc.d/S99wbox-chan`(OpenWrt 在 image build 由 postinst `enable`;staging rootfs 現有 `S99batman-autocommit` 為例)。`check-prov-test-gate.sh` 有 name 時加「`etc/rc.d/S??wbox-*` 存在」;`lint-wbox` 的 Makefile install 行 lint 已涵蓋檔案本身。

### m12. `dm-arm` 重用 `dm_arm` 需要節點上有 `ble-lib-254.sh` 與 `$BT`
`dm_arm` / `lock()` 要 `$BT/lock`、`$ST`(`ble-lib-254.sh:78-80,117-133`),都在 tmpfs,每次 `pr_find` 後要先 re-stage(ble-254 的 `ble_stage` 做這件事)。§4.3 寫「重新 acquire + `dm_arm`」,補「先 `ble_stage`-等價的 prov stage」;否則第一次重開後 `dm-arm` 直接 `die "cannot open $BT/lock"`。

### m13. 02 boot_id 前後相同的斷言在 > 3600 s 的單位會假 FAIL
hold 型 ≈ 47 分 + `pr_ota_b` 重試一次 + M2 的延遲 → 可能 > 60 分 → 02 joinwatch `t_reboot 3600` 重開(`joinwatch:37`)→ `pr_end` 步驟 4 FAIL。chain1 已把它降為 warn(`chain1-254.sh:362`);`pr_end` 比照:02 重開但回 `batctl n` 且 A committed → WARN 不 FAIL。

### m14. 小字串 / 行號
- F13 `boot.go:119` 的 Action 字串在 `:120`(`:119` 是 `RemoveTxn`);F7 `build-board.sh:166` 是 echo,`patch-witness.sh check` 在 `:170`;F11 `sock.go:107-141` 的拒絕在 `:136-141`;F12 `:233-244` ✓。都不影響判定。
- §4.1.1 標題叫 `--killpoint` 但契約是「daemon 啟動時讀檔」(無 CLI 旗標;`push-helper` 先寫檔再 restart,`arm-killpoint` 只寫檔);改名為「killpoint 檔」或寫明無旗標。
- §6.2 (6) 沒寫前置「04 = member」(只有 `member:*` 分支讀 `ota-armed.mesh`,`:416-421`);「與 (3) 互為對照」隱含了,寫出來。
- (10) 的「容器 root」臂:容器裡沒有 `/lib/upgrade/platform.sh`、沒有 p6 mount(F35)→ `_ab_arm_mesh` 在 `:105` 就 return 0,判定「p6 無檔」對這一臂幾乎沒有鑑別力;主機 root 以非 procd 父程序呼叫 `platform_check_image`(`:81` 讀 `/proc/$PPID/cmdline`)才是有意義的偽造臂。保留容器臂當 F35 的 characterization 即可,但要標明。

---

## v3 發現(A 與 B)→ v4 解決了嗎

| v3 | 解決? | 說明 |
|---|---|---|
| A-M1 / B-M2 `chan` 賽跑、revert 無 hold | yes | §1.4 / §4.2 一律 hold;watchdog 只看 `held()`(`:202,234`),`held_commit()`(`:60`)只進 why(`:511-513`)→ hold 不擋 revert ✅;mutant 無效 → `is healthy and HELD`(`:513`)→ harness FAIL + `back_to_a` ✅;`chan` 改 init 迴圈 ≥ 200 s(> 80 + 48,`99-batman-chanfix:39-55`)✅;E-H7;m10 / m11 殘餘 |
| A-M2 txn-3 / overlay-corrupt | yes | F41 ✅(`boot.go:106-131` `.txn` 分支不看 gen;`:179-184` gen 比對只在無 `.txn`);`helper-norebuild` 定義對;m3(nil) |
| A-M3 txn-2 (a) | yes | `main.go:441-443` daemon 排程 120 s;`--boot` 模式(`:386-390` 立即 restore)無人呼叫(feed / scripts grep 零命中)→ 視窗存在 ✅;m4(INVALID 判法) |
| A-M4 txn-4 | yes | F39 ✅;`--check`:`prov_compare`(`:149-157`)prov 相等後 `stage_overrides` + `diff_keys` → `p5 stale: <keys>` exit 5(`:440-450`)✅;殘項回 #254 / §10 ✅;m5 |
| A-M5 / B-M3 (8)(9) | **partial** | 三臂 ✅:`:496` `[ -f "$ST/ble-ok" ]` 在 poll 迴圈內每次重讀、latch 只在印過之後 → 臂 C「移除 → power off → 放回 → 下一次 poll 印」成立;臂 B 停 helper → `health.go:151` `Committed()`(`main.go:457` `is-trial` rc 1)在 trial 為假 → 不寫回 ✅;臂 A ✅。(9) characterization ✅ 但 commit mutant 槽(**M1**) |
| A-M6 / B-M1 / B-M6 範圍 | yes | (10) = L41 三臂 + 真 OTA(`platform-ab.sh:77-83,103-117`)✅(m14 容器臂鑑別力);`prov-sec-sockdir-254` 對 `sock.go:37-77`(symlink → `!fi.IsDir()`;`chown 471` → `st.Uid != 0`;訊息 `sock: … refusing to start` `:49`;`main.go:461-463` exit 1 → respawn)✅;(4) 併 (7) ✅;§7 OTS 列指向 (10) ✅ |
| A-M7 lease / deadman | yes | F22 ✅(`ble-lib-254.sh:212-226` `sleep` → 重讀 lease → 未到期 exit 0;`:117-133` `dm_arm` 殺舊 group);§3 / §4.3 renew = `lease_write` + `dm_arm` ✅;`dm-fire` 讀 `lease-prov` ✅;互斥雙向 ✅;每次 `pr_find` 重取 ✅(m12 re-stage);p6 `dv-prov-normalising` ✅;`restoring` 生命週期 ✅;§5 補列 ✅(m9 缺兩列) |
| B-M4 CI 非 root | yes | F20 ✅(`sock_test.go:13-17,67`;`ci.yml:74` 無 sudo 無 tags);§2.2 / §6.1 root + SKIP = FAIL ✅;m7 |
| B-M5 tmp-trust | yes | F30 改寫正確:`check-tmp-trust.sh:29` pathspec `scripts/*.sh`;allowlist `:13` `/tmp/run/batman-dv` 無邊界、`:99` `/tmp/run/batman-prov` 無邊界 ✅;§2.2 條目與測試案例 ✅ |
| A-m1 rundir-paths:97 | yes | `rundir-paths.txt:97` = `joinwatch.lastjoined` ✅;假殘項已刪 |
| A-m2 (6) `first_why` 含 | yes | `:502` 串接、`:505` ✅ |
| A-m3 helper-flap 退出點 | yes | §4.2「`serving` 後 5 s」(`main.go:475`) |
| A-m4 upper 先於 bind | yes | §3 / §4.5 |
| A-m5 只進 B 矛盾 | yes | 「非 committed 槽」+ P9 分 committed / 另一槽;legacy-upgrade 負對照改到正向之後 ✅ |
| A-m6 fleet 還原順序 / 02 snap | yes | §6.2「02 先 snap」「02 先還原」 |
| A-m7 (6b) boot_id | yes | 「不等於本次開機」(`:419` `ab` = 倒數第二行)✅ |
| A-m8 (1) hold | yes | 同 A-M1 |
| A-m9 brewrite 條件 | yes | §4.3 步驟 3「或 B 的 `.protected` ≠ V」 |
| A-m10 空區塊 / F29 行號 | yes | 全文重寫;F29 語意改正(`sysrq.c:598,1160`;`.config:6904-6905`)✅ |
| B-m1 F29 語意 | yes | 同上;fallback 當保險、P9 只記錄 ✅ |
| B-m2 tag 規則 | yes | 表為準;lint 驗 |
| B-m3 (4) | yes | §1.2 |
| B-m4 timing n / 釋放槽 | yes | n ≥ (1.96·1.2533·√2·1.4826·MAD/門檻)²(門檻 = 2·MAD 時 ≈ 6.6 → 下限 30 生效)✅;§4.8.2 P2 契約 + §10 ✅ |
| B-m5 legacy-upgrade 兩臂 | yes | 負對照移到正向之後 + `strip-p5-prov` + 斷言 |
| B-m6 沙箱底來源 | yes | §4.4.1 / D-H11 |
| B-m7 dvpc 機制 | yes | `prov-lib-254.sh:92` `mkdir -m 0711`(無 `-p`)✅;本 PR 只加訊息 + 白箱 |
| B-m8 字串尾巴 | yes | F11 `sock.go:140` `%v` ✅ |
| B-m9 radio1-off 檔名 | yes | `99zz-wbox-` 前綴 + lint |
| B-m10 §7 殘文 | yes | 重寫 |
| B-m11 normalise lease | yes | 1800 + renew(m6 前置) |
| B-m12 continue-on-error 可見 | yes | `::warning::` + PR body |
| B-m13 chan 只跑一次 | yes | §4.2 uci-defaults 規則;`chan` 現為 init,不受此限(但 B trial 仍一次性,tryboot) |

## 已核對的假設(file:line)
- F3 14 ✅(`daily-validation.sh:208,214,227-296`);F4 ✅(`prov-base-254.sh:29,65-75,190-220`,`overlay-restore` 另停 `batman-provd`);F5 `overlay-allow.txt` 3 條 ✅;F6 `build-ab-payload.sh:69` `version=$(date …)` ✅、`platform-ab.sh:12,154-156,329` ✅;F7 ✅(`stamp:38-44,48-49,52-54`;`build-board.sh:74-100,146-173`;`golang-package.mk:106-111,260`;`package.mk:114`;`depends.mk:14`);F8 ✅(`main.go:373-410,439-477,481-495`;init `respawn 3600 5 0`);F9 ✅(`node.go:32-48,165-171`);F10 ✅(`provclient/main.go:294-306,417-424,470,489-492`);F11 ✅(`sock.go:37-77,80-95,136-141`);F12 逐字 ✅(`:35,60,94-106,183-248,277,361,379-384,419-421,425,487,494,496-500,502-505,513,529,537`);F13 ✅(`96:104-116,168,193`;`boot.go:59,72,120,127,187`;`main.go:491`);F14 ✅(`health.go:8-9,138,146-157,162-173`);F15 ✅(`99-batman-chanfix:22-57` 背景子殼、`a=0` 靜默 exit);F19 ✅(`verify.py:176-186` 模組層 check、`:29-32` dissononce;`gen.py:36-38,184,225-227`;`ci-check.sh:12` 195;`requirements.txt`);F20 ✅;F22 ✅;F23 ✅(`prov-lib-254.sh:20,92`;`brewrite-254.sh:5,21,37`);F24 ✅(`chain1-254.sh:27,122-176,145,259,362`);F25 ✅;F26 ✅(`:10,19-24`,3 欄);F29 ✅(`sysrq.c:571,598,1152-1164`;`.config:6904-6905`);F30 ✅;F31 ✅(`batman-slot:423-436,771-791`;`95:717`);F33 ✅(`joinwatch:135`、`:37` t_reboot;`platform-ab.sh:103-117`;`rundir-paths.txt:97`);F34 ✅(`golang-package.mk:237-260` 兩個 `-ldflags`);F35 ✅(deploy/ots grep 零命中);F36 ✅(`build-board.sh:168-172`;`check-go-toolchain.sh:16`);F37 ✅(`batman-prov-lock:7-11,48-58`);F38 ✅(`node.go:216-222,996-1001`);F39 ✅(`node.go:399-405,795,1118-1123`;`boot.go` / `main.go` 無 `--save`);F40 ✅(`node.go:94,540-549`);F41 ✅。
- killpoint 五點對 `applyNet` `node.go:1098-1123` + `commitTxn` `txn.go:17-40` ✅;txn-2 後重開 wireless 仍是新值(`halow-setkey --no-persist` 只跳過 persist `:150-151`,uci 已寫;96 只在 fresh overlay 跑)→ txn-2 正向 / 負對照有鑑別力 ✅。
- `is-trial` 語意:`realSys.IsTrial` rc ≠ 1(`main.go:110`)、health `Committed` rc == 1(`:457`)✅。
- init 順序:staging rootfs `etc/rc.d/` 有 `S13batman-prov-lock`、`S89batman-provhelper`、`S99batman-autocommit` ✅;`S99wbox-chan` 會排在 autocommit 之後(字母序),mutant 等 `wlh0` 所以無關。
- `release --wait` 存在(`batman-autocommit:151-161`);`AUTOCOMMIT_DRYRUN` 決定字串 `:529` / `:240`。
- 協定:219 §5.2 無 `E_STATE`、7 / 12 / 13 ✅;§8 計數器 ✅;§3.4「等逾時才斷」✅(§4.8.2 的 P2 契約成立);§10 `flynn/noise` ✅。
- 範圍:p1-impl §5.1–§5.7、stage1 §8 / §9 的列都有對應(m8 的兩條例外)。

## 無法核對的假設
- 節點側(未上機):F16、F17、F21、F28、04 upper 無 `usr/bin/`(F6 的 `ls`)、`btmgmt` 在 04、`wifi reload` 對 morse 換頻道(E-H7)、`autocommit.timeout` 是否在 04 的 p6(M2)。
- `uci_apply_defaults` 以子殼 source、依檔名序:staging rootfs 的 `lib/functions.sh` 樹中找不到(與 v3 B 相同)→ 仍 ⚠️,E-H2 boot log 證。
- F18、E-H1–E-H7 全部;F32 wsl.9 的 96 內容;firmware repo 可見性。
- `go version -m` 在 `-trimpath` musl 靜態二進位上保留 `-tags`(§4.1.3 gate 無 name 的第一條;有 name 時設計已改只看見證)。

## 裁決

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 2 / MINOR 14)。M1 是無人值守 run 會故意把 04 留在 mutant 槽的路徑,與設計自己的不變量衝突,且用 dry-run 就能免掉;M2 是會把正常 revert 判成 FAIL 並觸發 restore 的時間常數。v3 的 13 個 MAJOR 全部核實解決(A-M5 / B-M3 的 (9) 部分併入 M1)。v5 窄範圍複查 M1 / M2 + m1–m5 即可。
