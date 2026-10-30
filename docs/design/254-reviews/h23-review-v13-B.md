# h23 設計審查 v13 — 審查者 B(全文 §0–§22,重點 §22)

(審查者 agent 無法寫檔,全文要點由主 session 依其回報存入。)

對象:`docs/design/254-h23-harness.md` @ 2ec108a(1021 行)。原始碼(rc):`batman-slot:28-100,186-230,265-300,340-365,720-870`、`batman-autocommit:41-42,108-113,176-200,357-358,420-440`、`bootfacts.sh` 全文、`usr/lib/batman/` 清單、`95-batman-storage:717`;firmware `git show github/feat/254-wbox:scripts/check-prov-test-gate.sh`(104 行)與 `test-prov-test-gate.sh`(grep);`lint-wbox.sh` 全文;13 patch `+++` 路徑與兩個 Makefile hunk;`.github/workflows`(busybox)。#254 唯讀:留言 6460421575、本體與留言搜 `/rom`。沙箱 WSL busybox 1.36.1 + bash,`/home/yello/dreview13B.*` 已刪。無 ssh / commit / worktree 改動;firmware-2710 只 `git show`。

## 0. 結論
**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 8 MINOR)。** §22 對 v12 兩份 22 條逐條有處理;A-MAJOR-1(節點不放 stub)已關。沙箱發現兩處與實際不符:F5 —— 現行 gate `[ -f "$LIST" ]`(gate:68)不會開 FIFO,「舊 gate 會建 sentinel」不成立(m6);`dry.pid` 剛起動讀到空檔 137/200(m5)。另:節點「殺 ssh」沒證明什麼(m1);「另起同一回補腳本」照字面重跑 `rbarm.sh` 會被自己的 a0 前置擋掉(m2)。都不會讓節點停在 `[all]` = wbox(產品閘仍擋、P9 仍抓),列 MINOR。修完只需複核 §22.1、§22.5。

## 1. v12 逐項
v12-B:m1 ✅(殘:pid 重用、多等 60 s 之後、「同一回補腳本」→ m2);m2 ✅(殘:vcgencmd 不存在、batpower → m3);m3 ✅;m4 ✅(殘:release trial 印 WARN、golden Pi 4 → m4);m5 ✅(受保護集合與 source 行一致 `batman-slot:51,62,812`、`batman-autocommit:42,111,113,358`;四個 lib 不再 source 別檔,閉包完整;殘:執行期 overlay 被改 → m7);m6 ✅;m7 ✅(殘 → m5);m8 (a)(b) ✅、(c) ⚠️ → m6;m9 負對照 ✅、殘項登記 ✅(只在留言不在本體 → m8)、E-H5 `/rom` 已列 ✅(原始輸出沒附 → m8)。
v12-A:MAJOR-1 ✅(節點證明無判別力 → m1);m1–m3 ✅;m4 ✅(WARN 無 fixture → m4);m5 ✅(runner busybox → m7);m6 ✅;m7 ⚠️ → m6;m8–m10 ✅;m11 (1)–(7) ✅;m12 ✅(#254 留言 2026-10-28T04:08:55Z 逐字對上)。
更早:v8–v11 與安全審查 F1–F5 的 BLOCKER / MAJOR 無回歸。

## 2. 沙箱(✅)
S1 §22.3 起法(launcher 為 session leader,200 輪):
```
empty-first-read: 137  sid==pid: 200  sid!=pid: 0
```
S2 現行 gate + FIFO `helpers.list`:
```
rc=1 out=[check-prov-test-gate: FAIL: no .../wd/helpers.list] secs=.018 sentinel=absent
writer alive after gate: yes
no-env out=[check-prov-test-gate: FAIL: no .../fw/feeds/batman/tests/wbox/helpers.list]
```
S2b(`GO` 指向一執行就 touch 的腳本,舊 gate):`GO sentinel=CREATED`。S3(一般檔偽內容 `chan prov_test helper`):`FAIL: prov_test variant but the helper is not a Go binary`(判定改變,可當判別)。S4(無寫者 FIFO + GNU `timeout 3 bash -c 'cat fifo'`):`rc=124 secs=3 leftover=0`。

## 3. 發現(全部 MINOR)
- **m1** 節點「臂中殺 ssh」無判別力:起動 `setsid … </dev/null >rbarm.out 2>&1 &`、ssh 立即返回 → 10 s 內無 ssh 可殺,有無 trap / setsid 都寫 `RESULT=PASS`;無負對照。修(二選一):節點改稱 smoke;或 `ssh -tt node '<launcher>; sleep 30'`(pty,dropbear 關閉發 HUP),第 3 s 殺 client,正向仍 `RESULT=PASS`,負對照同法起不帶 trap / setsid 版本 → 臂死、無 `RESULT=`(真閘拒絕,負對照在節點也無害)。
- **m2** 收尾:(a) `kill -0` 被 pid 重用騙 → 比對 `/proc/<pid>/cmdline` 含 `rbarm.sh`(照 `slot_lock` `:89`);(b) 多等 60 s 後未寫 → 仍無 `RESULT=` 走「已不在」分支;(c)「另起同一回補腳本」重跑 `rbarm.sh` 時前置 `a0 = fw-part A` 在 `[all]`=B 不成立 → INVALID 不回補 → `[all]` 留 wbox → 另 stage 只做 commit 的 `rbfix.sh`;(d) 臂期間重開過 → `$DVD`(tmpfs)消失、回補可能跑在 B → 回補前斷言 `active` = A 且 boot_id 同起動時,不符 → 不 commit,交 P9 / §22.1 並 `pr_needs_person`。
- **m3** `vcgencmd` 不存在 / 讀不到未定 → 應 INVALID(fail-closed;產品 rollback 此時只 warn 照寫,`:280-290`);batpower `CRIT` 讓 `write_autoboot` die(`:294-298`),閘回歸時被誤判 INVALID 遮住回歸 → 前置排除 `CRIT`;回補後 openmanetd:`addr_defer_release` 背景 start(`:754-768`)→ ≤ 30 s 輪詢 `/etc/init.d/openmanetd running`;註明此斷言只在 dv-sbx 被執行到。
- **m4** P9:正常 release trial(跑 B、`[all]`=A)會進「S 非 wbox → WARN(stale fallback / EEPROM)」,與「release trial → PASS」矛盾且歸因錯 → 用 `bf_get` tryboot 旗標或 dt_tryboot 先分 trial,trial 不印 WARN;fixture 加 stale fallback → WARN;`bf_pi4` 只看 bcm2711 + 無 p7,golden / 非 A/B 的 Pi 4 無 `/boot/autoboot.txt` → 空 → FAIL → 前置改 A/B 卡(`batman-slot layout` 成功或 GPT 兩槽),A/B 卡讀不到維持 FAIL。
- **m5** `dry.pid` 空檔競態(S1 137/200)→ 輪詢到非空且全數字才開始 sid 輪詢(共用 2 s),或 `echo $$ > dry.pid.tmp && mv dry.pid.tmp dry.pid`。
- **m6** F5 機制事實錯誤:現行 gate `[ -f "$LIST" ] || fail`(`:68`),FIFO 非一般檔 → 舊 gate 不開 → sentinel 不建(S2);負對照現只靠錯誤訊息路徑不同;寫者在 gate 不開 FIFO 時一直卡著(writer alive: yes),測試末 `wait` 會 hang。修:一般檔誘餌(偽內容一被採用即改判定,S3),新 gate 判定與輸出須與不設 env 時逐位元組相同;負對照改「把 `WD=${WBOX_DIR:-…}` 加回去的新 gate mutant」→ 測試必須 FAIL,不拿舊 gate(不支援 `--selftest-*`,會因別的原因不同);保留 FIFO 則結束時 kill 寫者並 wait;`GO` sentinel 判別力有效(S2b)不變;新 gate 不讀 `WBOX_DIR` 就不 hang,若回歸去讀,GNU `timeout 30` 連孫程序一起收(S4)✅。
- **m7**(⚠️ 推論)非 misc 變體可帶 `99zz-wbox-*` / `wbox-*` 在首開以 root 執行,根是 overlay(§22.6 `/rom squashfs`;§3 upper 可寫 `/usr/bin`)→ 執行期改 `/usr/bin/batman-autocommit` 或 `/boot/autoboot.txt`,檔案範圍 lint 與 rootfs sha 都擋不到。修:`lint-wbox` 對非 misc patch 新增行 grep 受保護檔名與 `autoboot.txt` → FAIL + 負對照;busybox `sh -n` 那步 job 要裝 busybox(`ci.yml:53` 有先例),不存在 → FAIL;刪檔已由 `git apply --numstat` 第 3 欄涵蓋 ✅;Makefile 改安裝來源由 sha 擋 ✅。
- **m8** 記帳:(a) E-H5 第 4 項無原始輸出(#254 搜 `/rom` 無結果)→ 貼進 #254;(b) 兩條殘項只在留言,依規則要進 #254 本體 checklist(本體搜不到 `hci0_powered`);(c) §22.8 漏:F5 誘餌與 gate mutant 負對照、`dry.pid` / sid 輪詢、`hold present` 在 `gate until` 前、臂 a `arm-a.verdict`、`COMMITTED` 限 boot8、P9 WARN fixture、節點 rollback 臂(m1 形式)、`rbfix.sh`(m2)。

## 4. 攻擊與生命週期(§22)
rollback 臂:`sleep 10` 期間斷電 / ssh 斷 / harness 死 → 無寫入 ✅;真 rollback 被拒不寫 `[all]` ✅(閘順序對照 `:786-797`,`BADMARK` 只在 apply 寫 ✅);閘回歸窗口 §22.1 已涵蓋 ✅;臂中重開 ⚠️ m2(d);第二 run 同時起臂撞 `slot_lock`(`:84-96`)→ INVALID fail-safe ✅。P9:一般 committed 不觸發 ✅;mid-OTA ✅;trial ⚠️ m4;stale fallback / EEPROM WARN ✅;「跑 A、`[all]`=wbox B」FAIL ✅;apply 刪目標槽 `.protected`(`:432-433`)→ P9 改掛 squashfs、不讀舊 `.protected` ✅。dry-run sid ✅(S1);dry-run watchdog `( revert_watchdog ) &` 同 session(`:431-432`)掃描抓得到 ✅。lint 受保護集合 vs 13 patch:無碰 ✅。本機非 root ✅;攻陷元件 ✅;我們自己 m1 / m2 / m6 / m7;供應鏈 ✅;fail-secure:m3 第一點 fail-open,其餘 fail-closed ✅;bcm2710 不適用 ✅;升降級 ✅。

## 5. 證據
✅ S1–S4;`batman-slot:84-96,143,265-300,354-361,427-433,727-797,811-830,853`;`batman-autocommit:42,111,113,180-200,358,431-434`;`bootfacts.sh` `bf_pi4` / `bf_ab_all`;firmware gate `:34,39,66-68`(現行程式碼);`lint-wbox.sh`;13 patch 路徑;`ci.yml:53-54`;#254 留言 6460421575。⚠️ m7 overlay 執行期竄改(依設計描述,未上機);dropbear pty 斷線發 HUP。❌ 上機;新閘原型;04 busybox `setsid`。
