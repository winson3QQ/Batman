# h23 設計審查 v10 — 審查者 B(全文 §0–§19,重點 §19)

- 對象:`docs/design/254-h23-harness.md`,worktree `/home/yello/Batman-h23`。派工寫 @16a0b0b;實際 HEAD = 18114c7,和 16a0b0b 只差 §19.3 的一行:使用者 2026-10-28 決定做 `prov-wbox-nocommit-254`。本審查以 18114c7 為準。
- 對照原始碼:rc 樹 `/home/yello/Batman-rc` @d0643d5(`batman-autocommit`、`batman-slot`、`platform-ab.sh`、`halow-status`、`feed/batman-prov/src/health`、harness `scripts/dv/*.sh`、`tests/prov-p1/*`)。
- 沙箱:busybox 1.36.1 ash 驅動 autocommit 的「路徑改寫副本」,全部在 `mktemp -d -p /home/yello dreview10B.XXXXXX` 內。跑完已清:`no sandbox left`、`no procs left`。
- 唯讀:沒有 ssh、沒有 commit,也沒碰 firmware build 樹。

## 0. 結論

**APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 11 MINOR)**

§19 把 v9 兩位的 7 個 MAJOR 都正面處理了。沙箱確認了兩件事:
- §19.1 的 dry-run 作法(`hold-consumed` + `AUTOCOMMIT_TIMEOUT=1`)在四個 L 臂與四個 mutant 上都成立。
- §19.3 的閘放在 hold 之後時,wbox + hold → HELD,wbox 無 hold → `WBOX-NOCOMMIT`;讀不到 → 不 commit;放在 hold 前(CI 負對照)→ HELD 消失。

剩下一個 MAJOR:新節點單位的 rollback 臂若真的放行(也就是被測的閘回歸),harness 的正常失敗處理(`pr_abort` → `pr_restore` → `batman-slot reboot committed`)會直接開進 wbox B,而且是 committed。這正是 F1 要防的事件,只是改由失敗路徑觸發。修法只動 harness 文字,不需要再審整份;修完可由作者自行確認。

---

## 1. 前輪發現的處理狀況

### 1.1 v9-B(本人上一輪)
| # | 處置 | 判定 |
|---|---|---|
| M1 閘與 hold 的先後 | §19.3 寫死 `HOLDUNSAFE → held_commit → wbox`;CI 案「閘擺在 hold 前 → BAD」;預期 REVERT 單位斷言 reason 不含 `wbox test image` | ✅ 已解(沙箱 R2:after → HELD=1,before → HELD=0) |
| M2 dry-run 會跑 canary;臂 a 的 `sleep` 偵測不成立 | §19.1:`hold-consumed` + `TIMEOUT=1`;臂 a 改用 `gate until` + 3 s | ✅ 已解(R1);但 15 s 規則與 L38 臂 b 衝突(m1),`hold-consumed` 承重卻沒斷言(m2) |
| M3 節點負對照會 commit 舊 wbox | 刪除;安全網 = COMMITTED → rollback + `pr_needs_person` | ✅ autocommit 臂已解;rollback 臂的對應安全網缺 → 本輪 MAJOR-1 |
| M4 rollback 沒擋 | §19.3 `cmd_rollback` 讀目標槽,無逃生口 | ✅ 方向對;實作位置與既有測試見 m3 |
| m1 見證 `grep -c` | = 2 | ✅ |
| m2 `pgrep -f` 自我匹配 | 改用 `ps -o pid,pgid` | ✅ |
| m3 見證位置不受 mutant 條件影響 | 未寫 | ❌ 遺留(m11) |
| m4 快照清單 / 「本來不存在」 | 加了 `why`、`hold-*`、`canary-ok`,不再假設 `wd` / `decided` 不存在 | ⚠️ 部分:缺 `autocommit.ctl.dry`、`autocommit-dryrun.log`,也缺「p6 無 hold 旗標」的前置斷言(m2) |
| m5 `test-arm-mesh` 寫不出來 / 漏案 | 改放 dv-sbx,補了 fallback 案 | ⚠️ 部分:`meshjoin.sh` stub 檔、`_ab_live_sysupgrade` 覆寫、`RUNDIR` 沒寫;L42 靜態 lint 沒採用(m11) |
| m6 pgid 重用 | deadman 比對 leader 命令列 | ✅ |
| m7 讀 `/rom`、讀不到 → wbox、第二訊號 | ✅ | ✅;診斷字串見 m4 |
| m8 逃生口 | 作廢 | ✅;但可能經 `UNLOCKED_ROLLBACK` 旁路回來(m3) |
| m9 stale-fallback / bcm2710 / PR 兩節 | ✅ | ✅ |
| m10 `WBOX-NOCOMMIT` 只在 `ok ≥ NEED` 記;reason 只記錄 | 前半 ✅;節點單位仍硬斷言 reason | ⚠️ m5 |
| m11 舊 payload | 隔離 + `pr_ota_b` 斷言 `WBOX-NOCOMMIT` | ✅ |
| m12 上層與 actor 表 | §10 ✅;actor 加了「誤推 wbox」 | ⚠️ autocommit bind 那一列仍缺(m11) |
| m13 成本 | 使用者已決定做 | ✅ |
| m14 F2–F5 負測試 | ✅ | ✅;F5「不會繼承」的機制沒寫(m11) |
| m15 L9 / L10 / L27 副作用 | L10 改 characterization | ⚠️ L27(在 harness 自己的 ssh 上重啟 dropbear)仍未寫(m11) |
| m16 P9 快照跨 run | §19.2 | ✅ |

### 1.2 v9-A
| # | 判定 |
|---|---|
| M1 | ✅(同上)。第 4 點「`release --wait` 對 wbox trial 一定逾時回 1、目前沒有單位這樣用」沒寫進文件 → m11 |
| M2 | ✅(同 B-M4) |
| M3 L11 | ✅ 改在 socket 層判定;「負對照前置:無 `.txn`」沒寫 → m8 |
| m1 / m2 / m3 / m4 / m5 / m8 / m12 / m13 / m14 / m15 / m16 | ✅ 或已併入上表 |
| m6 L3 負對照改用同一 run 的 sysrq | ❌ 遺留(m11) |
| m7 L51 正向檔 = L43 對照檔只改第 3 欄;L38 臂 c 標 characterization | ❌ 遺留(m11;沙箱 R1 就是這樣做的,證明可行) |
| m9 「行有、值空 = 非 wbox」要給 CI 一案 | ⚠️ 行為對(R2:`BATMAN_WBOX=` 空 → commit),但 CI 案沒列 → m11 |
| m10 `lint-wbox` 禁止碰閘的那幾行 | ❌ 遺留(m11) |
| m11 (b) 沒有 `WBOX-NOCOMMIT` 且 reason 是 mesh 類 → INVALID | ❌ → m5 |

### 1.3 v8、安全審查
- v8 的 MAJOR 都已在 v9 / §19 收掉。
- 安全審查 F1 → §18.1 / §19.3 ✅;F2–F5 → §19.3 的負測試 ✅;F7 已做。

---

## 2. 沙箱實驗(✅ 原始輸出節錄)

**R1:§19.1 的起法,四個 L 臂加四個 mutant**
起法:臂前建 `$RUNDIR/autocommit.hold-consumed`,用 `AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=1` 起。mutant 是對副本各改一行,對應 §17.2。
```
[L38b]     rc=0 wall=59.06s pg-left=[] run=[autocommit.hold-consumed ] arm:[]->[]
    hold present — this trial will not be reverted
    slot B is an uncommitted trial — gate until uptime 5094s (now 5094s), revert=0
    mesh join required: 0 (prov=unclaimed mesh_expect=0 radio_required=0)
[L38b-mut] rc=0 wall=.019s  ... mesh join required: 0 (prov=unclaimed ...)
[L38a]     rewrote prov-state at gate+3s
[L38a]     rc=0 wall=4.02s pg-left=[] run=[autocommit.hold-consumed ]
    member: no usable ota-armed.mesh — neighbours required (fail-closed)
    mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)
[L38a-mut] mesh line already out at gate+3s (not in loop) -> mesh join required: 0 (prov=unclaimed ...)
[L38c]     wall=.014s  mesh join required: 1 (prov=none mesh_expect=- radio_required=0)
[L42]      wall=.019s  no usable ... / mesh join required: 1 (prov=member ...)
[L42-good] arm:[bbbbbbbb B radio]->[bbbbbbbb B radio]  armed in radio-only mode / required: 0
[L42-mut]  no usable ... / mesh join required: 0
[L43]      arm:[cccccccc B radio]->[cccccccc B radio]  mesh join required: 1   (no 'no usable')
[L43-ctl]  armed in radio-only mode / required: 0
[L43-mut]  armed in radio-only mode / required: 0
[L51]      arm:[bbbbbbbb B joined]->(unchanged)  mesh join required: 1
[L51-mut]  armed in radio-only mode / required: 0
[HC: p6 有 autocommit-hold-commit 時] run=[autocommit-dryrun.log autocommit.hold-consumed autocommit.hold-discarded ]
[不先建 hold-consumed,TIMEOUT=1] 2 s 後 pg=[] run=[autocommit-dryrun.log autocommit.decided autocommit.wd ]
```
- `wall=59.06s` 是 WSL 的 `date` 時鐘漂移造成的。同一台機器另量 20 次 busybox `sleep 1`:`date=19.23`、`uptime=20.03`。所以真實等待約 60 s。
- 沙箱的 `otalog` 是 no-op(`otatrace.sh` 沒改路徑),「ota-trace 行數」在這裡不構成證據 ⚠️。

**R2:§19.3 閘的原型**
- 判定:讀 `$SB/rom/etc/batman-build`;讀不到或沒有 `BATMAN_VERSION` → wbox;`BATMAN_WBOX=` 非空或 VER 含 `.wbox-` → wbox。
- 位置:`held_commit` 那個 `elif` 之後;`WBOX-NOCOMMIT` 只在 `ok ≥ NEED` 時記一次。
- 環境:非 dry、`POLL=1`、`MIN_WINDOW=25`。
```
gate lines: after=516 held_commit-elif=512 ; before=510
[after|release]               commit-calls=1 HELD=0 why=[] reverted=0
[after|wbox, no hold]         commit-calls=0 WBOX-NOCOMMIT ok=3 why=[wbox test image …] bad-slot=[slot=B version=…wbox-96-noprov] reverted=1
[after|wbox + hold]           commit-calls=0 HELD=1 why=[held for operator acceptance …] reverted=1
[after|wbox + DISCARDED hold] commit-calls=0 WBOX-NOCOMMIT ok=3 DISCARDED=1 why=[wbox test image …] reverted=1
[after|rom wbox, /etc forged] commit-calls=0 WBOX-NOCOMMIT ok=3 bad-slot=[slot=B version=1.5.14-wsl.8+abc.fw123] reverted=1
[after|rom missing]           commit-calls=0 WBOX-NOCOMMIT ok=3 why=[wbox test image …] reverted=1
[after|rom unreadable]        commit-calls=0 WBOX-NOCOMMIT ok=3 why=[wbox test image …] reverted=1
[after|BATMAN_WBOX= empty]    commit-calls=1 why=[] reverted=0
[after|dry-run + wbox]        DRYRUN decision: COMMIT
[before|wbox + hold]          commit-calls=0 HELD=0 WBOX-NOCOMMIT ok=3 why=[wbox test image …]   <- CI mutant: BAD
rollback target (unsquashfs -cat 代替 node 的 mount):rel->allow  wb->refuse  veronly->refuse  none->refuse  garbage->refuse
```

---

## 3. 發現

### MAJOR-1 `prov-wbox-nocommit-254` 的 rollback 臂失敗時,harness 自己的收尾會把 04 開進 committed 的 wbox 槽
- **情境**:§19.3 的正向流程是「…期限 revert → 回 A;再在 A 上 `batman-slot rollback`(目標 = 含 wbox 的 B)→ 被拒絕、預設槽不變」。安全網只寫了 autocommit 那一臂(出現 `COMMITTED` → rollback 到 A)。rollback 這一臂要抓的,正是「`cmd_rollback` 的檢查回歸」。回歸時事情會這樣發生:
  1. `batman-slot rollback` 成功,`write_autoboot "$FT" "$FA"` 把 `[all]` 寫成 B(`batman-slot:793-795`)。
  2. 斷言「預設槽不變」FAIL。依 §4.3,任一步失敗 → `pr_abort` → `pr_restore`。
  3. `pr_restore` 內有 `batman-slot reboot committed`(F4;§3 `restoring` 列),它會開進 `[all]` = B。結果 04 開進 committed 的 `96-noprov` mutant,而且不是 trial,autocommit 在 `:326` 直接退出。
  4. 另一條路:harness 在步驟 1 之後死掉。deadman 不碰槽(§3),04 停在 `[all]=B`。下一次任何重開(joinwatch 3600 s、操作員、斷電)都會開進 committed 的 wbox。
- 這就是安全審查 F1 的事件。這一次是「測試失敗後照規則收尾」自己造成的,不需要操作員犯錯。
- 另外,這一臂的「被拒絕」還可能因為別的理由成立,形成假 PASS:
  - `slot_lock` 忙;
  - `assert_fw_sane`;
  - 04 若是 claimed / member,`rollback_lock_gate` 掛不上 B;
  - 檢查擺在 lock gate 之後,而 lock gate 先 die。

  文字只要求「被拒絕、預設槽不變」,沒要求拒絕原因。
- **證據**:
  - ✅ `batman-slot:786-797`(`cmd_rollback` 依序:`slot_lock` → `assert_fw_sane` → `slot_is_bad` → `rollback_lock_gate` → `write_autoboot`);
  - ✅ `:364-369`(`slot_is_bad` 看的是 boot FAT 上的 `BATMAN-BAD`,不是 p6 的 `bad-slot`,所以 revert 後 B **不會**因 bad 被拒,這一臂確實會走到新檢查);
  - ✅ `batman-slot:809-833`(`reboot committed` = 開進 `[all]`);
  - ✅ 設計 §4.3 步驟「任一步失敗 → `pr_abort`(restore…)」、§3 deadman「不碰槽」。
- **修法**(只改 harness 與文字):
  1. 臂前記錄 `ab_section all` 與 `[tryboot]`(`batman-slot` 有讀它們的函式;或直接讀 `/boot/autoboot.txt`)。
  2. 同一個 ssh 指令裡執行 `out=$(batman-slot rollback 2>&1); rc=$?`。PASS 必須同時滿足:rc ≠ 0、`out` 含 `holds a -wbox test image`、`[all]` 與臂前相同。
  3. **在同一個節點端指令裡**,只要 rc = 0 或 `[all]` 改變,就立刻執行 `batman-slot commit`(在 A 上跑,A 是 V,不是 wbox,允許),再讀回 `[all]=A`。這一步要在任何 `pr_abort` / `pr_restore` / 重開之前完成;讀回失敗 → `pr_needs_person`,**不重開**。
  4. 拒絕原因不是 wbox 那句 → 判 INVALID(不是 PASS),並印出原因。
  5. §5 補一列「rollback 臂放行後 harness 死」:修法 3 把窗口縮到同一個 ssh 指令內;P9 加一條「`[all]` ≠ 目前執行的槽,且該槽含 wbox → FAIL」。

### MINOR
- **m1 §19.1 的「15 s 未結束 → kill → INVALID」會讓 L38 臂 b 永遠 INVALID**。臂 b 的判別力就在 `:404` 的 60 s 等待(§17.4 自己寫「有判別力的是臂 b」)。R1 實測約 60 s(WSL `date` 量到 59.06 s,uptime 量到 60 s)。修法:
  - 計時起點改成「`mesh join required` 行出現」;或每臂設預算(L38 b = 75 s,其他 15 s)。
  - E-H5 的「15 s 內結束」只適用於非 L38 b 的臂。
  - 臂 b 的「≥ 60 s」用節點 uptime 整數秒判,門檻寫 ≥ 58。mutant < 1 s,中間有很寬的鑑別間隔。
- **m2 `hold-consumed` 是承重的,但 §19.1 沒有斷言它生效**。R1 最後一案:不先建 `hold-consumed` 時,`TIMEOUT=1` 讓 dry-run 的 watchdog 立刻到期,2 s 內建出真名的 `autocommit.wd` / `autocommit.decided`,並執行 `:237 rm -f "$ST/ota-armed.mesh"`,也就是刪掉被測的檔(L42-good / L43 / L51 三臂都會受影響)。修法:
  - 臂前斷言檔已建好。
  - stdout 必須有 `hold present — this trial will not be reverted`,而且在 `mesh join required` 之前;沒有 → INVALID + 依快照還原。
  - deadman 也要刪 `hold-consumed`:它不影響 committed 開機的行為,但 `halow-status:144` 會對操作員顯示「this trial HELD and hold-once set — no deadline revert」。
  - 前置斷言 p6 沒有 `autocommit-hold-commit` / `autocommit-hold-once`。R1 的 HC 案:有 hold-commit 旗標時,dry-run 會建真名的 `autocommit.hold-discarded`(`pr_ota_b` 用它偵測 DISCARDED)與 `autocommit-dryrun.log`。快照清單補 `autocommit.ctl.dry`、`autocommit-dryrun.log`。
- **m3 `cmd_rollback` 檢查的位置要寫死,並改既有測試**。§19.3 說「它本來就會唯讀掛載目標槽」,這不正確:
  - `rollback_lock_gate` 對 legacy / unclaimed 在 `:775-776` 就 `return 0`,不掛載;
  - `allowed UNLOCKED_ROLLBACK`(env **或** root 擁有的 `/tmp/batman-slot.allow-unlocked-rollback`,`:77`)在 `:777` 掛載之前 `return 0`。

  實作者若把 wbox 讀取塞進 `rollback_lock_gate`,legacy 節點根本不檢查;而 UNLOCKED_ROLLBACK 的 `/tmp` 旗標(活到重開)就成了 wbox 的旁路,和「沒有逃生口」矛盾。修法:
  - 獨立函式,在 `slot_is_bad` 之後、`rollback_lock_gate` 之前無條件呼叫,不受任何 `allowed` 影響;掛載失敗 → 拒絕。
  - lifecycle 寫明補救方式 = 對該槽 `apply` 一個 release。
  - `tests/prov-p1/batman-slot-rollback-gate.sh:61` 的「legacy:target not even read」對 `cmd_rollback` 整體不再成立,要隨 P1b 一起改,並加一案「檢查在 lock gate 之前、override 不影響」。
- **m4 讀不到 `/rom/etc/batman-build` 時的診斷字串錯誤;`/rom` 的存在未在節點上證實**。R2:release image 只要讀不到 `/rom`,就會得到 `WBOX-NOCOMMIT` 與 `TRIAL-REVERTED … reason=wbox test image`,操作員會被誤導成「這是 wbox」。修法:
  - 讀不到另給一個 `why`(`cannot read /rom/etc/batman-build — not committing (fail-closed)`)與另一個 otalog 種類,CI 加一案。
  - ⚠️ `/rom` 是否在每個開機狀態都存在,我沒上機驗證。旁證:`daily-validation.sh:358` 用到 `/rom/root/meshtest`;fstools 的 overlay / ramoverlay 都會 pivot 出 `/rom`。E-H5 加兩項:04 的 A committed 與一次 B trial 都執行 `grep ' /rom ' /proc/mounts; cat /rom/etc/batman-build`。
  - 有 `/etc/batman-build` 的版本,往前到 1.5.0 都在(autocommit 自 678a801 / 2026-09-24 起就讀它,`git tag --contains` = v1.5.0、v1.5.11)。所以 fleet 內的 release 槽作為 rollback 目標不會被誤拒。
- **m5 節點單位的判定細節**:
  - (a) 硬斷言 `reason=wbox test image` 會不穩:reason 是最後一輪的 `why`。04 `NEED_MESH=1`,最後 60 s 只要 mesh 掉了,reason 就變成 `mesh lost`(`:503`)。判定應該以 `otalog AC WBOX-NOCOMMIT`(只在 `ok ≥ NEED` 才有,R2 `ok=3`)、無 `COMMITTED`、有 `TRIAL-REVERTED` 為準,reason 只記錄。
  - (b) 沒有 `WBOX-NOCOMMIT` 且 reason 是 mesh 類 → INVALID,不判 FAIL(v9 A m11b)。
  - (c) 「不設 hold」的例外要有機制:例如 `pr_ota_b … no-hold=prov-wbox-nocommit-254`,參數值必須等於呼叫單位名,lint 檢查全 repo 只有這一處用它。否則「一律 hold」就靠記性維持。
- **m6 跨閘降級:rollback 的防線在「執行中的槽」,不在被 rollback 的目標**。§18.1 說「降級不相關」,這只對 autocommit 那一層成立。若 04 跑的是沒有閘的 image(§5「rollback(fleet 回 wsl.4)」、§8 第 4 步在 wsl.4 上跑 pre-P1b 負對照、prov-downgrade 的 wsl.9),另一槽又剛好有 wbox,`batman-slot rollback` 不會擋。修法:
  - §19.3 lifecycle 寫明這一點。
  - P9 在「另一槽含 wbox」時,檢查 committed 槽的 `batman-slot` 是否含新檢查的字串;沒有 → 輸出加一行「不要 rollback」。
  - 確認每個 pre-P1b 單位都在任何 OTA 之前就印 `FAIL pre-P1b` 並結束。
- **m7 `back_to_a` 遇到拒絕時靜默**。`brewrite-254.sh:13`、`negctl-old-slot-254.sh:30` 都是 `batman-slot rollback >/dev/null && …SENT`,接著 `grep -q SENT || return 0`。新檢查是 rollback 的新拒絕理由:目標 A 掛載失敗或讀不到也會拒絕。這時 `back_to_a` 回 0 且什麼都不印。後果只是 trial 到期 revert(安全),但除錯線索丟了。修法:B 在執行、卻沒有 `SENT` → 印出 rollback 的 stderr,判 FAIL。
- **m8 L9 / L11 的細節**:
  - L9 的「`bluetoothd` pid 欄非 0」不存在。health 行的欄位是 `bluetoothd=0|1`(`health/health.go:4,138`),應改成 `bluetoothd=1 hci0_powered=1` 且 `uptime − ts ≤ 15`。
  - L11 負對照的前置「沒有 `.txn`」沒寫(v9 A M3):crash loop 每輪都跑 `boot.Run`,有 `.txn` 時會起 `restoreWireless`。
- **m9 L38 臂 a 遇到「3 s 內就出 `mesh join required`」時怎麼判,沒寫**。R1:mutant 在 3 s 內出行,harness 不改寫 → 得到 `prov=unclaimed`,這是對的「mutant 有效」。但真 autocommit 也可能因 prov-state 第 2 欄不是 99zz(快照寫錯、helper 剛好重寫)而提早出行。應寫明:真 autocommit 上提早出行 → INVALID,並印 prov-state 內容。
- **m10 CI 怎麼 stub `/rom/etc/batman-build` 要寫明**:用腳本副本改路徑(如本沙箱),或 `unshare -m` + bind。**不要**在產品加「build 檔路徑」的 env 覆寫,那會變成 production 的繞過口(v9 B m8 的延續)。F5 的 `PROV_GATE_SELFTEST_*`「不會繼承」也要寫出機制:`wbox_env_reset` 與 `local-ab-tar.sh` 都要 unset。
- **m11 小遺留(建議一次補成 checklist,不需重審)**:
  - v9 B m3:見證 log 行放在不受 mutant 條件影響的位置(L38:`:404` 前;L42 / 43 / 51:`:417` 後)。
  - v9 B m5 / A m4:dv-sbx 的 L51 要 bind 一個 stub `meshjoin.sh` 到 `/usr/lib/batman/meshjoin.sh`(`platform-ab.sh:112` 在子殼重新 source),source 後覆寫 `_ab_live_sysupgrade`,提供 `RUNDIR`。L42 寫入半邊的真保證是靜態 lint「`batman-slot` 不寫 `ota-armed.mesh`」;(6a) 標 characterization。
  - v9 A m6:L3 負對照改用同一 run 的 L7 sysrq。
  - v9 A m7:L51 正向檔 = L43 對照檔只改第 3 欄(R1 就是這樣做的);L38 臂 c 標 characterization。
  - v9 A m9:CI 加「`BATMAN_WBOX=` 空 → 非 wbox」一案(R2 行為正確)。
  - v9 A m10 / B §5:`lint-wbox` 拒絕碰閘那幾行的 patch;`pr_ota_b` 拒推 `misc-*`。
  - v9 A m16:prov-misc 期間不得有 `sysupgrade -T`(`platform-ab.sh:106` 會刪 arm 檔),寫成前置。
  - v9 A M1 第 4 點:寫明 `release --wait` 對 wbox trial 一定逾時回 1,§6.2 沒有單位這樣用。
  - v9 B m15:L27 在 harness 自己的 ssh 上重啟 dropbear,重連方式與判定要寫。
  - §7 actor 表補「我們自己:bind 覆蓋 root 執行的 `/usr/bin/batman-autocommit`」一列。
  - 文件第 1–3 行的標題與狀態仍寫「v7(定稿)」,應改成 v10。

---

## 4. 依任務要求的逐點回答

1. **§19.1 的 dry-run 作法在四個 L 臂上成立嗎?**
   - 成立(✅ R1)。`TIMEOUT=1` → `DEADLINE=START`(`:382-383`),`:487` 的迴圈一輪都不跑。`hold-consumed` → `:372` `REVERT=0`,不起 watchdog。
   - **L38 的 60 s 等待在 `:404`,只看 `i < 60`,與 DEADLINE 無關**,所以 `TIMEOUT=1` 保留了它(R1 L38b 約 60 s,mutant 0.019 s)。
   - `gate until` 行(`:386`)在 `:404` 之前印出,臂 a 的偵測有效(R1 L38a:gate + 3 s 改寫 → member / radio / required 1;mutant 3 s 內就出行 → unclaimed)。
   - 每個 mutant 都只翻轉自己那條判定;正向臂沒有靠別的原因成立。L43 正向沒有 `no usable` 行;L51 與 L43 對照只差第 3 欄;arm 檔都沒被動到。
   - 問題:m1(15 s 規則)、m2(`hold-consumed` 要斷言)。
2. **§19.3 閘的位置**:✅ R2 全部符合規格:
   - wbox + hold → HELD(why = held);
   - wbox 無 hold → `WBOX-NOCOMMIT ok=3`,期限 revert;
   - DISCARDED → reason = wbox(§19.3 的「預期 REVERT 單位不得含 wbox」會抓到);
   - `/etc` 被偽造時仍擋(讀 `/rom`);
   - 讀不到 / 缺檔 → 不 commit;
   - `BATMAN_WBOX=` 空 → commit;
   - dry-run → `DRYRUN decision: COMMIT`;
   - 閘擺在 hold 前 → HELD 消失(CI 負對照有效)。
3. **讀不到就 fail-closed,健康的 release 會不會中?**
   - 依原始碼與旁證不會:`/etc/batman-build` 自 1.5.0 起都在;fstools 的 overlay / ramoverlay 都有 `/rom`;autocommit 在 START=99 才跑,掛載早已完成;bcm2710 不適用(CM4 決定)。
   - 但我沒上機看 `/rom` ⚠️(m4,E-H5 補)。真的中了的後果是 release 被 revert(安全),只是診斷字串會誤導(m4)。
4. **拒絕 rollback 到 wbox 槽,會不會破壞 harness 流程或操作員需要的復原路徑?** 逐一查 `batman-slot rollback` 的呼叫者:
   - `brewrite-254.sh:13` 與 `negctl-old-slot-254.sh:30` 的 `back_to_a`:只在 B 上跑,目標 A = V;
   - `chain1-254.sh:140,217,303,351`:兩槽都是 V;
   - `fault-injection.sh:501`:目標 A;
   - `ab-selftest.sh:325`:目標 A;
   - `pr_needs_person` 印的指令:從 committed 的 wbox 回 A。

   全部的目標都不是 wbox → 不受影響 ✅。

   wbox 只會進 B(§4.2「只進非 committed 槽」;§6.2 沒有任何單位把 wbox 推進 A)✅。

   新的副作用:
   - 目標槽 squashfs 掛不上 → rollback 被拒,補救 = apply(m3);
   - 拒絕時 `back_to_a` 靜默(m7);
   - 既有的 `batman-slot-rollback-gate.sh` 要改(m3)。
5. **節點單位不設 hold 的例外、它的安全網、成本**:
   - 例外缺機制(m5c);
   - autocommit 臂的安全網 ✅;
   - rollback 臂缺安全網(MAJOR-1);
   - 成本:使用者 2026-10-28 已決定做(18114c7)✅。
6. **F2–F5 的負測試**:照寫可行 ✅;F5 的「不繼承」要寫機制(m10)。

---

## 5. 安全(本輪增量)

| actor | §19 帶來的變化 | 判定 |
|---|---|---|
| 本機非 root | 新輸入:`/rom/etc/batman-build`(squashfs,唯讀)、目標槽 squashfs(root 掛載,`mktemp -d` 0700)、`$RUNDIR/autocommit.hold-consumed`(root-only run dir)。非 root 都寫不了 | ✅(run dir 權限依 #280 設計;本輪沒上機 ⚠️) |
| 攻陷的 tenant / mutant 本身 | 改 overlay `/etc/batman-build` 已無效(R2「/etc forged」仍擋);mutant 以 root 直接寫 `autoboot.txt` 不在本設計的威脅範圍(mutant 是我們自己的) | ✅ |
| 操作員 / 我們自己 | rollback 擋下了;rollback 臂失敗路徑(MAJOR-1);`UNLOCKED_ROLLBACK` 可能成為旁路(m3);跨閘降級(m6) | 待修 |
| CI runner | `/rom` stub 不得變成產品裡的覆寫口(m10) | 待寫明 |
| 斷電 / harness 死 | 閘沒有狀態 ✅;dry-run 臂的白箱檔都在 tmpfs 或有快照;`ota-armed.mesh` 白箱值若因斷電留在 p6,下一次真 OTA 的 `_ab_arm_mesh` 會先刪(`platform-ab.sh:106`)✅;rollback 臂 → MAJOR-1 | ⚠️ |
| fail-secure | 閘與 rollback 都 fail-closed ✅;診斷字串見 m4 | ✅ |

**lifecycle(§19.3 部分)**:

| 路徑 | 行為 |
|---|---|
| install / first run | release image 照常 commit(R2 release 案) |
| 重開 / main 被 restart | 閘沒有狀態,每輪重判;`WBL` latch 是行程內的,takeover 後會再記一次(無害) |
| upgrade 到含閘的 rc | release 行為不變 |
| downgrade 到不含閘的版本 | autocommit 層仍有效(閘在被 trial 的 image 裡);rollback 層失效(m6) |
| crash loop | autocommit 沒有 respawn,不適用 |
| 斷電 | 沒有狀態 |
| bcm2710 | 不適用(CM4 決定) |

---

## 6. 證據分類

- ✅ **驗過**:
  - R1 / R2 沙箱輸出(上節);WSL 時鐘對照(`date=19.23 uptime=20.03`)。
  - 原始碼行號:`batman-autocommit:44,53,62,66,78,94-106,199-247,270-291,323-326,351,372,380-386,402-425,429-437,487-516,529`;`batman-slot:77,364-369,735-745,771-797,809-833`;`platform-ab.sh:22,98-117`;`halow-status:144`;`health/health.go:4,138`;`brewrite-254.sh:13`;`negctl-old-slot-254.sh:30`;`chain1-254.sh:140,217,303,351`;`fault-injection.sh:501`;`ab-selftest.sh:325`;`tests/prov-p1/batman-slot-rollback-gate.sh:13-18,61,81`;`daily-validation.sh:358`。
  - `git log -S /etc/batman-build`(678a801、a466c63;tag v1.5.0 / v1.5.11)。
  - `~/out` 的現況:wsl.5 / 6 / 7 的 wbox payload 都還在,尚未建隔離目錄(符合 §19.3「待做」)。
  - h23 HEAD 18114c7 與 16a0b0b 的 diff。
- ⚠️ **推論或部分**:
  - 04 的 `/rom` 掛載與 busybox 行為(依 fstools 與 `.config`;§19.1 已把它排進 E-H5);
  - rollback 檢查的原型用 `unsquashfs -cat` 代替節點上的 `mount`,只驗了語意;
  - 沙箱的 `otalog` 是 no-op;
  - R2 是依 §19.3 文字寫的原型,不是實作。
- ❌ **未做**:真機(依指示唯讀,沒有 ssh);dv-sbx 版本的 `test-arm-mesh` 沒有試寫。

---

## 7. 摘要

- **判定**:APPROVE-WITH-CHANGES(0 / 1 / 11)。
- **v9 的狀況**:7 個 MAJOR 全部處理,沙箱證實 §19.1 與 §19.3 的核心設計成立。
  - dry-run 四臂加四個 mutant 都有判別力;`TIMEOUT=1` 保留了 L38 的 60 s 等待。
  - 閘擺在 hold 後:HELD 保留、無 hold 時 `WBOX-NOCOMMIT`、讀不到不 commit;擺在 hold 前會被 CI 抓到。
  - 拒絕 rollback 到 wbox 不影響任何既有的 harness 流程。
- **唯一的 MAJOR**:rollback 臂若被放行,`pr_abort` → `pr_restore` → `reboot committed` 會把 04 開進 committed 的 wbox。要在同一個節點端指令裡用 `batman-slot commit` 回補,並斷言拒絕原因。
- **主要 MINOR**:
  - 15 s 規則讓 L38 臂 b 永遠 INVALID;
  - `hold-consumed` 承重卻沒斷言(沒有它,dry-run 會刪掉被測的 arm 檔);
  - rollback 檢查若塞進 lock gate,legacy 不檢查,且 `UNLOCKED_ROLLBACK` 成了旁路;既有 rollback-gate 測試要改;
  - 讀不到 `/rom` 時的診斷字串會誤導;
  - 節點單位的 reason 斷言不穩、no-hold 例外沒有機制;
  - 跨閘降級時 rollback 防線失效;
  - `back_to_a` 遇拒絕時靜默。
- 修完 MAJOR-1 與 m1–m3 即可實作,不需要再審整份。
