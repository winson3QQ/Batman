# h23 設計審查 v11 — 審查者 B(全文 §0–§20,重點 §20)

(審查者 agent 無法寫檔,全文由主 session 依其回報存入。)

對象:`docs/design/254-h23-harness.md` @ 2e48a9c。對照:rc 樹 `/home/yello/Batman-rc` @ d0643d5(`batman-slot`、`batman-autocommit`、`bootfacts.sh`、`halow-status`)、harness(`brewrite-254.sh`、`lint-wbox.sh`、`tests/wbox/*.patch`、`tests/prov-p1/batman-slot-rollback-gate.sh`)、gate(只 `git show feat/254-wbox:scripts/check-prov-test-gate.sh`)。沙箱:WSL busybox 1.36.1 ash(與 04 同版),`/home/yello/dreview11B*`,已清。無 ssh、無 commit、未碰 firmware 工作樹。

## 0. 結論
**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 8 MINOR)。** §20 正面處理 v10 三個 MAJOR(A-M1 掃 `/proc/*/stat` + 計時起點;A-M2 小寫;B-MAJOR-1 單指令 rollback 臂 + 同指令 commit 回補)。沙箱以 stub `batman-slot` 驗 rollback 臂三種情況(wbox 拒 → PASS;他因拒 → INVALID;回歸 → FAIL 並回補),都不重開;負對照:拿掉回補分支 → `[all]` 停在 B。實作前先修 m1–m3;v10 有 13 條 MINOR 未修也未記(m7)。修完只需確認 §20.3 / §20.4。

## 1. 前輪處理
- v10-B:MAJOR-1 ✅ 機制成立(但沒規定撐過 ssh 斷線、P9 `[all]` 檢查未寫 → m1);m1 ✅;m2 ✅(字串應寫死 → m8);m3 ✅(讀不到的訊息未定 → m3);m4 ✅(E-H5 上機查 `/rom` 未列 → m7);m5 ✅(nohold 規則放錯 lint → m8);m6 ⚠️(節點單位無前置 → m2;pre-P1b 單位在任何 OTA 前停 → m7);m7–m9 ✅;m10 ✅ 機制對、負測試無鑑別力(→ m5);m11 ⚠️。
- v10-A:M1 ✅(掃描陷阱 → m4);M2 ✅;m1–m5、m8、m9、m13 ✅;m6 已重算(使用者待確認);m7、m10 ⚠️;m11、m12、m14 ❌(→ m7)。
- v9 / v8 / 安全審查的 BLOCKER / MAJOR 已關閉、無回歸;§20 的「優先於前文全部」修掉 v10 A-m13 衝突。

## 2. 沙箱實證(✅ 原始輸出)
R1 單指令 rollback 臂(`[all]` 以 `bootfacts.sh:43 bf_ab_all` 讀):
```
[wbox]          RESULT=PASS | all_now=boot_partition=2 commit_calls=0
[other]         RESULT=INVALID (batman-slot: rollback lock gate: cannot read slot B's rootfs — refusing) | all_now=2 commit_calls=0
[succeed]       RESULT=FAIL-RECOVERED rc=0 a1=3 a2=2 | all_now=boot_partition=2 commit_calls=1
[msg-and-write] RESULT=FAIL-RECOVERED rc=1 a1=3 a2=2 | all_now=boot_partition=2 commit_calls=1
negative control (no recovery branch): rc=0  all_now=boot_partition=3 (B stays default)
unreadable autoboot (a0=a1=''): RESULT=?? rc=0 but [all] 'unchanged'
HUP between rollback write and commit:
[none]   out=[] all_now=boot_partition=3 commit_calls=0
[ignore] out=[RESULT=FAIL-RECOVERED rc=0 a1=3 a2=2] all_now=boot_partition=2 commit_calls=1
```
真 `cmd_rollback` 不重開(`batman-slot:786-798`);`cmd_commit` 非 trial 時照寫 `[all]=A` / `[tryboot]=B`(`:735-746`)。
R2 `/proc` 掃描:
```
naive scanner under churn: 38/40 scans hit an unreadable stat (=> INVALID per §20.1 wording)
robust: members=2
spoof comm: [x) S 1 1498767 ]  stat head: 1506180 (x) S 1 1498767 ) S ...
recorded $!=1513929 child_pid=1513929 sid=1513929                  (no fork)
launcher pid=1513931 (group leader) child_pid=1513932 sid=1513932   (setsid forks: pid != sid)
```
(⚠️ churn 為 WSL 人為製造,比 04 重)
R3 現行 gate(讀 env):
```
env GO=/bin/echo WBOX_DIR=fake → FAIL (marker) rc=1
no env                         → FAIL (not a Go binary) rc=1
env GO=<sentinel script>       → FAIL rc=1 sentinel=CREATED
```

## 3. 發現(全部 MINOR)
- **m1** rollback 臂撐不過 ssh 斷線;斷電窗口不在 §5。harness 以 `timeout 90 ssh` 跑(`brewrite-254.sh` 的 `q()`),死在「rollback 已寫 `[all]=B`、commit 未執行」→ 下次開進 committed wbox(R1 HUP 段實測);斷電同理;兩者只在閘回歸時發生(⚠️ dropbear 無 pty 時是否送 SIGHUP 未驗)。修:節點端 `trap '' HUP PIPE; setsid sh -c '…' </dev/null >"$RUNDIR/dv-rbarm.<run>" 2>&1`,harness 輪詢結果檔;白箱:臂中殺 ssh,結果檔仍寫 `FAIL-RECOVERED`;§5 增列 ssh 斷線 / harness 死 / 斷電;P9:`[all]` ≠ 執行中的槽且 `[all]` 指的槽含 wbox → FAIL;`a0` 必須是合法 fw 分割區,否則 INVALID。
- **m2** rollback 臂沒先確認 A 帶閘:rc d0643d5 的 `cmd_rollback` 無 wbox 檢查(`:786-798`),wsl.5–7 都過 pre-P1b 偵測卻沒閘 → 臂會真的把 wbox 設成預設,只靠回補救。修:同指令內前置 `grep -q 'holds a -wbox test image' /usr/sbin/batman-slot` 且 p6 `slot-B.protected` = 本次 wbox 版本,任一不成立 → INVALID、不 rollback;需要閘的單位在任何 OTA 前印 `FAIL pre-gate image` 並停。
- **m3** `cmd_rollback`「讀不到」的訊息與清理沒定:與 wbox 同句 → B 掛不上時假 PASS。修:獨立訊息(例 `slot <X> build stamp unreadable — refusing to make it the default`)、dv-sbx CI 一案、加進 `lint-wbox` 保護清單;每條路徑 `umount` + `rmdir`(照 `:778-782`),CI 斷言無殘留 `/tmp/.rb*`。
- **m4** `/proc` 掃描三個陷阱:(a) 掃描中程序消失 → 整輪 INVALID(R2 38/40);(b) `comm` 可含 `)` 與空白,非 root 可偽裝同 session 成員(只 DoS,fail-safe);(c) busybox `setsid` 在呼叫者已是組長時會 fork,拿 launcher pid 當 sid → 誤判「已結束」(fail-open)。修:單筆讀不到略過,只有 `/proc/self/stat` 讀不到或整輪 0 筆才 INVALID;從最後一個 `) ` 之後解析;sid 從 dry-run 程序自己的 stat 讀;第一次掃描必須 ≥ 1 成員;加 churn 白箱測試。
- **m5** §20.5 負測試對舊 gate 也成立(R3)。修:sentinel —— env 的 `GO` / `WBOX_DIR` 指向「一執行就建檔」的東西,斷言檔未被建且輸出與不設 env 時逐位元組相同;先解析 `--selftest-*`,未知 `--*` → FAIL(`--selftest-wbox-dir` 能過名字的 `[a-z0-9-]` 檢查);lint:`--selftest-` 只准出現在 `test-prov-test-gate.sh`。
- **m6** 行級字串 lint 擋不住改函式本體或插 `return`。13 個現有 patch 都沒碰 `batman-autocommit` / `batman-slot`;碰 autocommit 的只有 4 個 `misc-*`(只 bind)。修:`lint-wbox` 改為只有 `misc-*` 可碰 `usr/bin/batman-autocommit`、任何變體都不得碰 `usr/sbin/batman-slot`;`pr_ota_b` 斷言這兩檔 sha 與同 rc 正常 build 相同。
- **m7** v10 有 13 條 MINOR 沒修也沒記:(1) dv-sbx 的 L51 stub(`meshjoin.sh`、`_ab_live_sysupgrade`、`RUNDIR`);(2) (6a) 標 characterization;(3) L51 正向檔 = L43 對照檔只改第 3 欄;(4) CI 加 `BATMAN_WBOX=` 有但空、只有 `.wbox-` 兩案;(5) prov-misc 期間不得有 `sysupgrade -T`;(6) `release --wait` 遇 wbox 一定逾時;(7) L27 重連方式與判定;(8) §7 actor 表加「bind autocommit / 白箱寫 p6」;(9) §5 加「(6a) 在 apply 與重開之間死掉」;(10) failsafe 下操作員 commit 會被擋,寫進 lifecycle;(11) hold-once + wbox 行為,以及「會讓某槽變成 committed default」的路徑清單;(12) §4.2 DISCARDED 已 commit 分支加註;(13) **E-H5 上機確認 `/rom`**(04 A committed 與一次 B trial)—— 閘讀不到會 fail-closed,trial 若無 `/rom` 則每個 release 都被 revert;⚠️ 無上機證據。修:每條補進 §20 或 #254 checklist;第 13 條實作前做。
- **m8** 文字:`hold present` 行寫死全文 `hold present — this trial will not be reverted`(`:372`;前綴會誤配 watchdog 的 `:190,202,234`);刪 `hold-consumed` 的理由寫錯(`halow-status` 只在 `autocommit.ctl/hold-commit` 存在時顯示;dry-run 用 `ctl.dry`),刪除本身仍對;nohold 規則不應放 `lint-install`(不存在),改放 `lint-wbox` 或新 dv lint;讀 `[all]` 寫明用 `bf_ab_all`(`batman-slot` 無對應子命令,usage `:866`);回補 `commit` 遇欠壓 `power_ok` 會 die(`:278-300`),建議每 5 s 重試共 3 次仍失敗 → `pr_needs_person`;§20.7 成本使用者確認前,`prov-wbox-nocommit-254` 不進全套。

## 4. 攻擊與生命週期(§20)
- ✅ 擋得住 / fail-safe:操作員手動 rollback 到 wbox(閘在 lock gate 前,`UNLOCKED_ROLLBACK` 的 env / `/tmp` 繞不過;設計層,實作待 CI);在含閘槽上 commit wbox(`/rom` 拒絕,`/rom` 本身 ⚠️);harness 死在 dry-run 臂(deadman + dry-run 自行結束,sid 見 m4);dry-run 臂中斷電(`prov-state` 由 helper 重寫;`ota-armed.mesh` 的 boot8 不會符合,`platform-ab.sh:106` 也先刪);本機非 root(只能 DoS);攻陷的 helper / tenant(碰不到 `/rom`、squashfs、autoboot);CI(`/rom` stub 只在 dv-sbx mount ns,產品無 env 覆寫)。
- ⚠️ / ❌ 缺口:harness 死在 rollback 臂(❌ m1);回歸窗口斷電(⚠️ m1);mutant 拆閘(⚠️ m6);節點跑沒閘的 image(autocommit 層 ✅、rollback 層 ⚠️ m2)。bcm2710 不適用(CM4)。

## 5. 證據
- ✅ R1 / R2 / R3 沙箱;`batman-slot:60-80,238-300,345-370,735-798,809-866`;`batman-autocommit:52,78,94-100,180-246,270-291,372,386,434,537`;`bootfacts.sh:43`;`halow-status:136-147`;`brewrite-254.sh`;`lint-wbox.sh:26-80`;patch 路徑清單;`helpers.list`;`rollback-gate.sh`;gate 的 `GO` / `WD` / 名字規則。
- ⚠️ dropbear SIGHUP 行為、04 上的 churn、04 的 `/rom`。
- ❌ 上機;dv-sbx CI;真 `cmd_rollback` 閘的原型(只 stub 驗判定邏輯)。

## 6. 摘要
APPROVE-WITH-CHANGES(0 / 0 / 8)。實作前先修 m1–m3;其餘 m4–m8;使用者待決 §20.7 成本(47–57 分)。m1–m3 修完只需確認 §20.3 / §20.4。
