# h23 設計審查 v12(§21)— 審查者 A

(審查者 agent 無法寫檔,全文由主 session 依其回報存入。)

對象:`docs/design/254-h23-harness.md` 全文 §0–§21(標頭 v12,933 行),逐項比對 `h23-review-v11-{A,B}.md`。原始碼(rc `/home/yello/Batman-rc`):`batman-autocommit:36-110,180-262,300-560`、`batman-slot:28-35,78-97,186-226,238-300,354-440,727-870`、`bootfacts.sh`、`rundir.sh:1-50`、`otatrace.sh:20-32`、`halow-status:125-147`、`95-batman-storage:717`、全 feed / scripts 寫 autoboot 或呼叫 commit / rollback 的檔。GitHub:唯讀 `gh issue view 254`。沙箱 WSL busybox 1.36.1 ash,已刪。無 ssh、無 commit、未改 worktree、未碰 firmware build。

## 結論
**APPROVE-WITH-CHANGES:0 BLOCKER / 1 MAJOR / 12 MINOR。** §21 正面處理 v11 主要發現(detached 臂、先回補再分類、pre-gate 前置、P9 `[all]`、`/proc` 容錯、見證位置、檔案範圍 lint、F5 sentinel、§21.7 表)。原始碼確認:revert 不寫 BATMAN-BAD(`batman-slot:381-385,426,684` 只在 apply 寫)→ rollback 一定走到 wbox 檢查;`cmd_commit` 在 A 上可寫回 `[all]=A`;`slot_lock` 擋第二個並行 batman-slot(`:84-96`)。唯一 MAJOR:§21.1「節點一次」stub 白箱沒有規格。MINOR:sid 讀法競態(m1 沙箱實證)、兩條 lint 擋到自己的定義處(m5)、v11 子項與兩條「殘項 → #254」又沒記(m11 / m12,連續第三輪)。

## 0. v11 與 §21.7 逐項核對
v11-A:MAJOR-1 ✅(子項缺 m11、殘項未登記 m12);m1 ⚠️(sid 競態 m1);m2(a) 臂 b ✅、臂 a 節點端判 ❌;m2(b) 整行 ✅、須在 `gate until` 前 ❌;m2(c) ✅;m3 位置 ✅、`sh -n` shell 與負對照 ❌(m5);m4 ✅(`[tryboot]` 前後記錄 ❌、a0 不夠嚴 m2);m5 ✅(test-dv stub 舊版案 ❌);m6 ⚠️(`COMMITTED` 沒限 boot8);m7 ⚠️(負對照 ❌、規則擋到 `pr_ota_b` 定義 m5);m8 ✅;m9 ✅;m10 ⚠️(rollback 臂結果檔放 `$RUNDIR` m3);m11 ✅(#254 留言已再確認成本);m12 ⚠️(openmanetd 斷言 ❌)。
v11-B:m1 ✅(細節 m2 / m3 / m4);m2 ✅(`95-batman-storage:717` 在 B 首開寫入 wbox 版本);m3 ✅;m4 ⚠️((c) 修法有競態 m1);m5 ⚠️(`WBOX_DIR` sentinel 未寫 m7;lint 擋 gate 本身 m5);m6 ⚠️(閉包 / 取代字串檢查 m6);m7 ✅(E-H5 只在表裡,§8 沒更新 m10);m8 ✅(`hold-consumed` 理由仍不成立 m8)。

## 沙箱(✅)
S1 `setsid … &` 後立即讀 `/proc/$!/stat` 的 sid:
```
immediate own-stat read: sid==pid 15 / sid!=pid (still launcher session) 185
after 50ms: sid==pid 47 / ne 3
```
S2 極短命程序:
```
life=0      … scan_members=0
life=0.005  … scan_members=1
scan_ms=5 procs=49
```
(⚠️ WSL 只有 49 個程序)

## MAJOR-1 §21.1「節點一次」stub `batman-slot` 白箱沒有規格,可能讓 04 停在 `[all]` = wbox
§21.1 只寫「白箱測試(dv-sbx + 節點一次):臂執行中殺掉 ssh → 結果檔仍寫出 `FAIL-RECOVERED`(以 stub 回歸的 batman-slot 驗回補)」。若照 `prov-wbox-254.sh bind` 慣例 bind 到 `/usr/sbin/batman-slot`,步驟 3 的回補 `batman-slot commit` 也打到同一 stub;stub 若真寫 `[all]=B` → 回補不發生 → `FAIL-NEEDS-PERSON`、`[all]` = wbox → 下次重開進 committed wbox(v10 B-M1 要防的事)。stub 若只 rc 0 不寫,臂只要幾秒,「臂中殺 ssh」難打中。§21.4「任何變體不得碰 `usr/sbin/batman-slot`」與節點 bind 假的精神衝突;此 bind 不在 §3 / §7.2 / deadman。證據 ✅ §21.1 原文;`batman-slot:735-746`(commit 即 `write_autoboot`);`:84-96`。修法二選一:(1) 只做 dv-sbx,節點改以無害方式證斷線:臂照常 rollback(A 帶閘 → 被拒 → PASS),臂中殺 ssh,斷言結果檔仍寫 `RESULT=PASS`;(2) 保留節點:rollback 經 `${RB_ROLLBACK:-/usr/sbin/batman-slot}`、回補一律絕對路徑 `/usr/sbin/batman-slot commit`、stub 放 `$DVD/<run>/` 只 `sleep 20; exit 0`、列入 §3 / §7.2 / deadman、斷言前後 `[all]` = A 且 `ab.good` mtime 未變。

## MINOR
- **m1** sid 從 dry-run 自己的 stat 讀有競態(S1 185/200 讀到 launcher session → 永遠清不空 → 30 s INVALID;fail-safe 但長期無判定);短命臂第一輪掃描前結束 → INVALID(S2)。修:預期 sid = `$!`,≤ 2 s 輪詢至第 6 欄 = `$!` 才計時;「在場」= 曾讀到 sid = `$!` 或 stdout 已有任一 `batman-autocommit:` 行。
- **m2** a0 只要求 1 或 2:若已處「跑 A、`[all]`=2」→ 被拒、a1 = a0 → 假 PASS 且留危險狀態。修:`a0 = $(batman-slot fw-part A)` 且 `is-trial` rc = 1;`power_ok` 是內部函式(`:278`),改 `vcgencmd get_throttled` bit 0 = 0;前後記 `[tryboot]`。
- **m3** 結果檔放 `$RUNDIR`(產品)與 §21.3 的 `$DVD/<run>/` 矛盾;重導向在臂前建檔 → 「沒有結果檔」永遠不成立 → 改「120 s 內無 `RESULT=` 行」;第二個回補前先確認第一個臂已不在(否則撞 `slot_lock`,`:89`,誤判 needs-person);`sh -c '<arm>'` 內含單引號會壞 → stage 成 `$DVD/<run>/rbarm.sh`,執行中不改寫。
- **m4** P9:`bf_ab_all` 回 fw 分割區號(pi4 1 = A、2 = B,`batman-slot:207-224`),要以 `fw-part <slot>` 對照;讀不到 → FAIL;`[all]` ≠ 執行中且該槽非 wbox → 至少 WARN 列 stale fallback;`test-dv-preflight.sh` 兩 fixture(`[all]`=2 + `slot-B.protected` 含 wbox → FAIL;`[all]` 讀不到 → FAIL)。
- **m5** `--selftest-` 只准在 `test-prov-test-gate.sh` → gate 本身必解析它,lint 必紅;gate 在 firmware、lint-wbox 在 Batman,哪個 repo 掃哪檔未寫;`nohold` 同理擋到 `pr_ota_b` 定義;`sh -n` 在 runner 是 dash → 明定 busybox ash + 「`;;` 後插行」負對照;nohold 第二處 → FAIL 負對照。修:每條 lint 列豁免檔並各附負對照。
- **m6** 閘函式若在被 source 的 lib(`rundir.sh`、`bootfacts.sh` 等),變體改 lib 即可拆閘而兩檔 sha 照同 → sha 涵蓋閉包或改白名單;「取代字串檢查」會掉一層(正常 build 若是 pre-gate 舊產物)→ 保留 §19.3 `WBOX-NOCOMMIT` 字串檢查並存。
- **m7** F5 `WBOX_DIR` sentinel 機制未寫:`helpers.list` 做成 FIFO,背景寫者在 open 成功時建 sentinel,gate 加 `timeout`;`GO` 沿用 v11 B R3。
- **m8** `hold-consumed` 刪除理由仍不成立:`RUNDIR=/tmp/run/batman`(`rundir.sh:18`)是 tmpfs,真 trial 必另一次開機;影響只在同次開機後續 dry-run 臂與手動 `halow-status`(只在 `ctl/hold-commit` 存在時看,`:140-145`)。理由改寫、刪除保留。
- **m9** §19.3「stale-fallback:不是 trial → 不 commit 也不 revert」與原始碼不符:非 tryboot 開進非 committed 槽時 `is-trial` 回 0(`:727-733`),autocommit 印 `will commit when healthy, will NOT reboot`(`:363`)並在 `pq` 為 0 或 = `[all]` 時走 commit(`:367-381`);只因 wbox 閘摺在共用 `why`(`:509-514`)才剛好不 commit。更正文字 + CI 加「REVERT=0 stale fallback + wbox → 不 commit、不 revert」。
- **m10** E-H5 散在 §8(lock-hold)、§15:599(OTS canary)、§19.1(dry-run 自行結束)、§21.7(`/rom` A committed + B trial,實作 §18.1 前做);§8 沒更新,B trial 搭哪個 held trial 未寫 → 在 §21 重寫完整清單。
- **m11** v11 子項又漏(第三輪):(1) 臂 a 節點端判;(2) `hold present` 在 `gate until` 之前;(3) test-dv「stub 舊版 → 不推送 / `FAIL pre-gate image`」;(4) `COMMITTED` 限本次 trial boot8(不限 → `pr_normalise` / legacy-upgrade 留下的 `AC COMMITTED` 觸發安全網 → B 上 rollback + 重開 → 假 FAIL;沒拿到 trial boot8 → INVALID);(5) nohold 負對照;(6) 回補後斷言 openmanetd running;(7) §21.7 第一列「gate 自測加小寫見證 — 已改(§21.4)」§21.4 沒這段 → 改「實作時加」列入 checklist。
- **m12** 兩條「殘項 → #254」沒有實際登記:`gh issue view 254` 本體與留言都沒有 `hci0_powered`(§21.7 v10 B-m8),也沒有 §17.5 的產品殘項(dry-run watchdog 刪 `ota-armed.mesh`、拿真名 `autocommit.decided`);txn-4 overrides 缺口已登記 ✅、成本再確認已登記 ✅。請直接補進 #254 並在 §21.7 寫「已登記(連結)」。

## 攻擊與生命週期(§21 增量)
本機非 root:`/proc` 唯讀、comm 偽裝只 DoS(fail-safe)✅、結果檔位置要統一(m3);攻陷元件 / tenant:碰不到 autoboot、`/rom`、squashfs ✅;我們自己:MAJOR-1、m2、m5、m6、m11-4;供應鏈 / 誤推:檔案範圍 lint + sha ✅(閉包 m6);ssh 斷線 / harness 死:detached + 輪詢 ✅(m3);臂中斷電(閘回歸):下次開進 committed wbox → 既有 P9 抓到 ✅、新 P9 抓「跑 A、`[all]`=B」✅;failsafe §21.2 ✅;降級 / 跨閘 ✅;bcm2710 不適用 ✅;fail-secure:產品閘 fail-closed ✅,harness INVALID fail-safe 但 m1 會長期 INVALID。

## 證據
✅ S1 / S2;`batman-autocommit:43,47,68-110,180-262,300-440,440-560`;`batman-slot:28-35,78-97,186-226,238-300,354-440,727-870`;`bootfacts.sh`(`bf_ab_all` 讀 `/boot`,兩槽都掛 bootA,`batman-slot:33`);`rundir.sh:18`;`halow-status:136-145`;`95-batman-storage:717`;`otatrace.sh:28`;autoboot 寫者 grep(只有 `batman-slot` 寫 `[all]`;`batman-reboot` 只做一次性指定分割區重開);#254 本體與留言。⚠️ 04 上 dry-run 實際存活時間與程序數;stub 在節點上的做法是依字面推的風險。❌ 上機;§0–§16 未改動部分只抽查一致性。
