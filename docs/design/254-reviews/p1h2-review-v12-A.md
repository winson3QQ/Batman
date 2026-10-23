# #254 P1 + H2 — 第 12 輪審查(審查者 A):§13.8.2 的程式碼審查 + 整份設計重審

**判定:APPROVE-WITH-CHANGES**(0 BLOCKER / 1 MAJOR / 10 MINOR)

- **A11-M1 / B11-M1 已關**:決定者不再呼叫 `is-trial`,整支程式沒有 mount / umount / batman-slot(靜態檢查 + 我讀過全文 `batman-addr-defer:1-75`)。
- **A11-M2 已關**:對帳集中在 `reconcile`,單例(pid 檔)+ 每次開機 3 次上限 + HUNG rc 2 + `env -i` + `setsid` + stdio 到 /dev/null,全部對得上 §13.8.2;突變負對照證明測試真的在抓這幾條(§3)。
- **A11-m1(rollback 刪旗標)、m3(ubus -t 5 + grep 字串)、m5(env -i)已實作**;m2(「該暫停卻沒暫停」只 WARN)已實作;m7 隨「tryboot≠1 → stock」消失。
- **真機證據**(§4):B-M4 在 wsl.12 重現(126 s 重開,§13.9),wsl.13 上 trial 內 305 s 無 worker、respawn 保留 env、release 後 1 s 內 env 清掉、worker 恰一次、重開落在 committed 槽、`dhcpconfigured=1`、300 s 穩定。**端到端成立**。
- 剩下的 MAJOR 是**回歸保護沒進常規套**:22 案例的 stub 測試沒有接進任何 runner(CI / daily-validation),§13.8.1 (5) 承諾的 tier A 斷言不存在,`batman-slot commit/rollback` 的旗標路徑沒有任何 stub。這不是程式碼問題,但依使用者規則(每個修法的回歸測試進常規全套)在 H2 PR 前必須補。
- 其餘是文件一致性(§3 擁有權表、§8 安全、§13.8 舊文)、log 噴量、文案歸因、CM4 前提。

證據檔:`scratchpad/h2/rv12a/`(`d88250b.diff`、`run-tests.sh` + 輸出、`probe2.sh`、`probe3.sh`)。節點 02/04 只做唯讀 ssh(wsl.13);沒有在節點上寫任何東西、沒有碰 `/opt/batdata/dv-prov`。

---

## 1. 程式碼 vs §13.8.2 逐條核對(✅ = 讀碼確認;附 file:line,行號以 `feat/254-p1` d88250b 的檔案為準)

| §13.8.2 的規定 | 程式碼 | 結果 |
|---|---|---|
| 決定 = DT `tryboot`=1 **且** `$RUNDIR/slot-committed` 不存在 → 暫停;否則 stock | `want()`:`dt_tryboot && [ ! -e "$FLAG" ]`(`batman-addr-defer:40`);`dt_tryboot` 用 `hexdump -v -e '1/1 "%02x"'` 比 `00000001`(`:39`) | ✅;旗標只做 `[ -e ]`(B11-m1(a)),不經 `batman_rundir`;RUNDIR 不可用時 `RUNDIR=/nonexistent/...`(`:33`)→ 旗標不存在 → 暫停(fail-closed)✅ |
| 不呼叫 `is-trial`、不碰磁碟 | 全文無 mount/umount/batman-slot;測試 `addr-defer.sh:54` 靜態 grep(排除註解) | ✅ |
| 權威狀態 = `ubus -t 5 call service list '{"name":"openmanetd"}'` 的 env,grep 字串;ubus 失敗 → unknown | `have()`(`:42-46`):失敗 → `unknown`;無 `"instances"` → `absent`;grep `"ALFRED.DATATYPES.ADDRESSRESERVATION": *"false"` → present | ✅;02 實跑 `ubus -t 5 …` rc 0(committed 槽無 env 鍵);E1c 在 trial 內讀到 `env=present`(`e1c-v4-pos2.log` 09:26:49)= 解析器對真實 procd 輸出有效。grep 的 `.` 是任意字元,只會放寬不會漏 |
| 無參數:rc 0 暫停 / rc 1 stock | `:50-54` | ✅;暫停時 `log` 到 logger + stderr → procd 轉成 `procd: /etc/rc.d/S99openmanetd: batman-addr-defer: …`(E1c log 可見)— 良好的證據鏈 |
| `status` 輸出 `want=… env=… openmanetd=…` | `:55-56` | ✅ 02/04 實跑 `want=stock env=absent openmanetd=up` |
| `reconcile`:只修「不該暫停卻在暫停」;want=defer & env=absent & up → 只 WARN | `:57-62` | ✅ |
| RUNDIR 不可用 → 不送 start、只回報 | `:65` `batman_rundir \|\| { log WARN…; exit 0; }` | ✅ |
| 單例:pid 檔,前一支還活著就不送 | `:66-67` `[ -s "$pf" ] && kill -0 "$(cat "$pf")"` | ✅(pid 檔只含 `$!` 一個 pid;busybox `kill -0 "a b"` 會 `invalid number` rc 1 — 04 實測 — 所以若將來寫多個 pid 會變成「沒在跑」,目前不會) |
| 上限 3 次/開機 → HUNG rc 2 | `:68-71`,計數檔內容驗數字(`:68`) | ✅ |
| `env -i PATH=… setsid /etc/init.d/openmanetd start </dev/null >/dev/null 2>&1 &` | `:74`;`batman-slot:750` 同一行 | ✅;02 實查 `env -i` / `setsid` 存在、`timeout` 不存在 |
| commit:寫完 → `slot-committed`(umask 077)→ 無條件 detached start → rc 不影響 commit | `batman-slot:738` 在 `st COMMITTED`、`echo committed` 之後呼叫 `addr_defer_release`(`:746-752`);`return 0` | ✅;otatrace `SLOT ADDR-DEFER-RELEASE flag=written`(04 三筆、02 兩筆,含 E1c 的 `boot=7cfc636a up=427`) |
| rollback 刪 `slot-committed` | `batman-slot:763` `rm -f … 2>/dev/null` | ✅(`$RUNDIR` 可能是 `/nonexistent/...`,`rm -f` 安全) |
| joinwatch 每 tick 一次 reconcile | `joinwatch:130`,在 `live` 之前;joinwatch 無 `set -e`;poll 15(02 uci 實查) | ✅ |
| halow-status:committed 但 env 在 → WARN;trial 暫停中 → INFO;trial 但 env 不在且 up → WARN | `halow-status:124-129`;bootstrap INFO 在 want=defer 時抑制(`:130`) | ✅ 層級對;**文案**見 m3/m4 |
| 掛勾:`[ -x … ] && decider && procd_set_param env …`,兩板同 patch,witness | `0014…patch`(2711/2710 `diff` 相同);`&&` 鏈在 `start_service` 內,rc.common 不是 `set -e`,決定者 rc 1 只讓這一行為 1,下一行 `procd_set_param respawn` 照跑 | ✅;04 `/rom/etc/batman-patch-witness` 第 10 行 `0014…\|file\|/etc/init.d/openmanetd\|batman-addr-defer`,`BATMAN_BOARD_PATCHES=10` 與 witness 10 行一致;`/rom/etc/init.d/openmanetd` 含 hook |
| Makefile | `INSTALL_DIR … $(1)/usr/libexec` + `INSTALL_BIN … batman-addr-defer`(`Makefile:62-63`) | ✅;04 上 `-rwxr-xr-x root 5041`,sha256 前 16 碼 `3543a850afdf69f3` **等於** feed 檔 — 節點上跑的就是被審的那份 |
| procd 語意(start 對運行中服務:env 變才 restart) | `procd-2026.03.14~c59f2d80/service/instance.c:940-960`(`instance_config_changed` 比 `env`)、`:1564-1583`(`instance_update`:running 且 changed → `instance_restart`) | ✅(本輪再讀一次原始碼) |

**ash 正確性**:決定者沒有 `local`(函式外也沒有)、沒有陣列、`$((n + 1))`、`case` 驗數字;`busybox sh -n` 通過;22 案例在 busybox ash 下 0 FAIL(§3)。`have()` 的 `o=` 是全域變數,無害。

**`$!` / setsid 語意**(讀 `busybox-1.36.1/util-linux/setsid.c:56-73`):非互動 shell 的 `&` 子程序不是 pgrp leader → `setsid()` 成功、**不 fork**,`$!` 就是 init 的 pid(joinwatch → reconcile 這條路成立)。互動 shell 下 `&` 子程序是 pgrp leader → busybox setsid **fork 後父程序立刻回 0** → `$!` 的程序馬上結束 → 見 m6。

---

## 2. 競賽與序列化(讀碼推論,⚠️ 沒有在節點上造競賽)

- **決定者 vs commit**:決定者只在 `start_service` 內跑,整支 `/etc/init.d/openmanetd <action>` 從 source `procd.sh` 起就持有 `/var/lock/procd_openmanetd.lock`(第 11 輪 §1.2)。commit 先寫旗標再送 `start`,所以任何在 commit 之後排到的 `start` 一定看到旗標;在它之前的(bat0 flap 的 `restart`)可能看到「無旗標」而設 env,但 commit 的 `start` 排在後面,env 變了 → procd 內部重啟 → 收斂。✅ 與 §13.8.2「最後一個贏、決定者冪等」一致。
- **reconcile vs commit 的 start**:兩者都是 detached `start`,同樣被 flock 序列化;reconcile 只在 `want=stock && env=present` 動作,commit 之後最多多送一次(通常 commit 的 start 已在 1 s 內清掉 env,E1c 實測 `omd_up=1 env=0`),不會互相干擾。
- **rollback 後**:旗標刪、沒人送 start → openmanetd 繼續以 stock 跑(worker 開著)。tryboot 已消耗,它 125 s 後的 plain reboot 落在 `[all]`=另一槽 = rollback 想去的地方,無害(第 11 輪 A11-m1 的結論仍成立);但 reconcile 每 tick 會記 WARN「hook missing from this image?」,歸因錯 → m4。
- **joinwatch 重啟 / respawn**:計數與 pid 檔在 RUNDIR(每次開機新),不在 joinwatch 程序內 → 上限是「每次開機」而不是「每個 joinwatch 實例」✅(優於設計字面)。

---

## 3. 測試:實跑與負對照

`scratchpad/h2/rv12a/run-tests.sh`(WSL,`/tmp/rv12a`;stock init 以 `patch -R` 從樹內已套 patch 的 init 反推,並確認 stock + patch == 樹內檔 **IDENTICAL**):

```
== /bin/sh (/usr/bin/dash)   22 × ok   ADDR-DEFER fails=0
== busybox ash               ADDR-DEFER fails=0
== MUTANTS
singleton (拿掉 kill -0 判斷)          FAIL singleton: starts=3        ← 抓到
cap       (拿掉上限)                   FAIL cap: rc=0 starts=4         ← 抓到
flag      ([ ! -e ] 反轉)              6 FAIL                          ← 抓到
unknown   (ubus 失敗回 absent)          FAIL status: … env=absent       ← 抓到
envi      (拿掉 env -i)                fails=0                         ← 沒抓到
inst      (拿掉 "instances" 守衛)      fails=0                         ← 沒抓到(守衛其實多餘:無 instance 時 grep 本來就不中)
timeout   (ubus -t 5 → ubus)           fails=0                         ← 沒抓到
```

結論:**測試對 §13.8.2 的核心(決定、單例、上限、unknown 不動作、init 只在 defer 時設 env、stock init 永不設)有鑑別力**。沒有鑑別力的三處:A11-m5 的 `env -i`(見 m5)、`ubus -t 5`、`instances` 守衛(無害)。另外整份測試**沒有 `batman-slot` 的任何案例**(commit 寫旗標、rc 不受影響、rollback 刪旗標),見 M1。

Harness 的其他兩個 commit:`65d351f`(prov-base `lock_take` 不用 setsid、cmdline 重試 4 次)— 與 §13.9 bug 2 的描述一致,而且和本輪 §1 的 setsid fork 語意吻合(`setsid` 會讓 `$!` 錯);`7459641`(overlay allow-list,kind content,附證據)— 只讀過,statecmp 14/14 是作者數字,我沒重跑(⚠️)。

---

## 4. E1c v4 證據:證明了什麼、沒證明什麼

| §13.8.2 的主張 | 證據 | 狀態 |
|---|---|---|
| 沒有 hook 時 B-M4 真的會在 trial 內重開 | `e1c-v4-neg.log` + `recover2-04.log`:wsl.12,boot b4486f5b,`AddressReservationWorker initialized` 11:27:12 → `Rebooting system` 11:29:18(126 s),`dt_tryboot=00000001`,boot-reasons `uptime=170.45s trigger=reboot/halt command` | ✅ 負對照成立(腳本當掉,但證據在 p6) |
| trial 內 env 在、worker 不起、撐過 125 s | `pos2` 09:26:49 `env=1 status=[want=defer env=present openmanetd=up] alfred_started=1 worker_init=0`;09:32:00 `openmanetd up 305s, no worker, no reservation reboot` | ✅ |
| procd respawn 保留 env | 09:27:02 kill 後 pid 6269→13541,`env=1 … worker_init=0` | ✅ |
| release → committed → env 清掉、新 pid、worker 恰一次 | 09:32:13 `release: committed`;09:32:14 `omd_pid=10915 omd_up=1 env=0 status=[want=stock env=absent]`,`worker_init=1`,`slot_committed=y` | ✅(B11-m6 要的 ≤30 s 時間界:實測 1 s) |
| 保留重開發生在 committed 槽、重開後找得到、`dhcpconfigured=1`、不在 bootstrap 網段、300 s 穩定 | prev-boot 12:12:53 init → 12:14:58 reserved → 12:15:00 reboot;mDNS 27 s 找到 `10.41.80.47`,`trial_rc=1 dt_try=00000000`,`dhcpconfigured=1`;300 s 無第二次重開 | ✅ |
| 還原、02 不受影響 | dead-man `P5-RESTORED … sha=7feb94f1`、`rollback rc=0`;A `check_rc=0 helper=up want=stock env=absent`;02 `trial_rc=1` 前後一致 | ✅ |

**沒證明的**(都要寫進設計的 ⚠️ 欄,不是阻擋):
1. **reconcile 在節點上從未觸發**:兩台的 otatrace / shutdown log / logread 都沒有 `re-registering` / `HUNG`;E1c 的 env 由 commit 自己的 start 清掉。reconcile 只有 stub 證據。
2. **操作員從互動 ssh 直接 `batman-slot commit`**(§13.8.1 要求「再從 ssh 直接 commit 一次」):E1c 用 `batman-autocommit release --wait` → autocommit 主程序呼叫 commit(非互動)。ROLL13 的 4 次也都是 autocommit。互動 shell 下 setsid 會走 fork 路徑(§1),功能上仍 detached,但沒實測。
3. **網頁終端機 commit(B10-M1 的原始情境)**:只有審查者 B 的主機模擬,節點未試。
4. **rollback 刪旗標**:E1c 的 dead-man 在 committed B 上做了 rollback 然後重開,沒有斷言旗標狀態。
5. `pos2` 09:32:14「openmanetd logged the reservation reboot 1 s after the commit」是假訊息(§13.13 已承認,`grep -q` 的 rc 被 `tr` 蓋掉);實際重開在 146 s。判定未受影響。
6. Pi 3:P-U14 暫不支援。

---

## 5. MAJOR

### A12-M1 回歸保護沒有進常規套:stub 測試沒接進任何 runner;§13.8.1 (5) 的 tier A 斷言不存在;`batman-slot commit/rollback` 的旗標路徑零 stub
- **現況**(`probe3.sh`):`Batman-h2` 的 `.github/workflows/ci.yml` 只跑 `tests/vectors/219-protocol/ci-check.sh` 與 `tests/ab-card-invariants.sh`(`ci.yml:41-54`);`scripts/daily-validation.sh` 只呼叫 `tests/ab-card-invariants.sh`(`:158`);`grep -rn addr-defer scripts/ .github/` 為空;整個 `tests/prov-p1/` 目錄沒有任何 runner 引用。`chk_patches_275` 只驗「image 建時用的 patch 都有 witness」,**不會**在 0014 不在樹裡時 FAIL(§13.8.1 (5) 要的「witness 與決定者同時存在,少一個 = FAIL」沒有)。「committed 槽 ubus env 不能有變數」「settle 後 `dhcpconfigured=1`」兩條 tier A 斷言也不存在(只在 E1c 腳本的 `a_healthy` 裡)。
- **現場後果**:若某天 firmware 樹掉了 0014(上游 init 改版 patch 失敗被人 `-i` 跳過、或 feed 與 firmware 的 PR 分開 merge 中間出了 rc),image 會靜默回到 B-M4;唯一的訊號是 trial 上 halow-status 的 WARN,沒有人在 trial 期間看它,全套會 PASS。
- **證據**:`ci.yml:41-54`、`daily-validation.sh:158,787-815`;§13.8.1 第 5 點;§13.8.2「已實作」段只列 stub 測試。
- **修法**(H2 PR 前):
  1. `addr-defer.sh` 接進 CI(決策/status/reconcile 三段不需要 init,可直接跑;init 段需要 firmware 的 patch 檔 — 在 Batman repo 的 CI 裡用 `tests/fixtures/` 放一份 patched/stock init 副本,並加一條 lint 比對 firmware 樹的 witness 字串)。
  2. tier A 新增 `chk_addrdefer_254`(唯讀):每台 `/usr/libexec/batman-addr-defer status` 必須是 `want=stock env=absent openmanetd=up`(committed 開機);`/rom/etc/init.d/openmanetd` 含 `batman-addr-defer` **且** `/rom/usr/libexec/batman-addr-defer` 可執行,少一個 FAIL;`/proc/device-tree/chosen/bootloader/tryboot` 存在(見 m9);wsl.12 以前依 P-U9 標 KNOWN + 期限。
  3. `batman-slot` 的 stub:commit 寫 `slot-committed`(umask 077、內容空)、`start` 被送出、`addr_defer_release` 失敗(假 init 不存在 / `batman_rundir` 失敗)時 commit rc 仍 0 且 trace 記 `flag=NOT-written`;rollback 刪旗標。放進 `tests/ab-card-invariants.sh`(它已經是 commit/rollback 的單元測試家)。負對照:6e3a8c1 的 `batman-slot`(無 release)→ 前兩條 FAIL。
  4. `addr-defer.sh` 補 `env -i` 的負對照(m5)。

---

## 6. MINOR

**A12-m1 §3 擁有權表沒有本改動的任何資源。**
- §3 沒有 `slot-committed`、`addr-defer.start.pid`、`addr-defer.starts`、procd instance env、決定者自身的列;§13.8 的「擁有權」段是**作廢版**(`addr-deferred` 由決定者寫)。真正的擁有權只散在 §13.8.2 的條列。
- 修:§3 加四列:`slot-committed`(寫:`batman-slot commit`;刪:`batman-slot rollback`;讀:決定者 `[ -e ]`;缺 = 未 commit → 暫停);`addr-defer.start.pid` / `.starts`(寫讀皆 `reconcile`;缺 = 0);procd env(寫:init 掛勾依決定者;讀:`have()` 經 ubus;unknown = 不動作)。

**A12-m2 §13.8 舊文仍是完整的另一套契約;§13.8.1 的測項清單含已作廢案例。**
- §13.8 的元件 1/3、「為什麼不會卡住」、擁有權、契約、生命週期表、tier A 三條,全部是 `addr-deferred` + `restart` 版;標題只有一句「定稿見 §13.8.2」。§13.8.1 測項清單還有「`is-trial` 卡住 → 10 s 內回來」(已無 is-trial)。讀者對照程式碼會以為少實作了旗標與 halow-status 的 `addr-deferred` 檢查。
- 修:像 §13.7 一樣在 §13.8 每個被取代的段落開頭標「(作廢,見 §13.8.2)」,或直接把 §13.8 的表改成最終版;§13.8.1 的清單標明哪些已被 §13.8.2 取代。

**A12-m3 §13.8.2 說「寫進 §8 並列殘項」的 `/var/lock` 既有面,§8 與 §11 都沒有。**
- `grep -n var/lock` 只命中 §13.8.2 兩行(1127、1134)。§8 沒有「本機非 root 可持有 procd per-service flock」;§11 殘項沒有這條。
- 修:§8 加一條(資產:openmanetd 可用性;actor:本機非特權程序;本改動的緩解:3 次上限 + HUNG WARN;既有面另開殘項歸 #280 類),§11 加殘項。

**A12-m4 reconcile / halow-status 對「trial 但 env 不在」一律歸因「hook missing from this image」,rollback 後也會這樣說。**
- `batman-addr-defer:59`、`halow-status:128`。rollback 刪旗標後 want=defer、env=absent、up → 同一句 WARN,但 image 明明有 hook。每 15 s 一行。
- 修:文案改成中性(「trial 開機但 openmanetd 沒有暫停(image 沒有 hook,或這次開機 rollback 過)— 它的保留重開會落在 [all] 槽」);或 reconcile 多看 `/etc/init.d/openmanetd` 是否含 hook 字串再決定文案。

**A12-m5 `env -i`(A11-m5)沒有負對照;`ubus -t 5` 也沒有。**
- 突變 `envi`、`timeout` 都 0 FAIL(§3)。
- 修:stub 案例 — `BATMAN_FAULT_INJECT=x` 下跑 reconcile,假 init 把 `env` 寫進檔案,斷言沒有 `BATMAN_`;假 `ubus` 睡 20 s,斷言 reconcile 在 ~6 s 內回來(busybox 沒有 `timeout`,測試跑在 WSL 可以用)。

**A12-m6 互動 shell 下的 reconcile 單例無效(busybox setsid 的 fork 路徑)。**
- `setsid.c:56-73`:呼叫者是 pgrp leader(互動 shell 的 `&` 工作)→ fork,父程序立刻 `return EXIT_SUCCESS` → `$!` 幾乎立刻結束 → 下一 tick 的 `kill -0` 說「不在跑」。只影響操作員手動連按 `batman-addr-defer reconcile`;joinwatch(非互動)不受影響;上限 3 次仍擋。
- 修:註解寫明,或 reconcile 用 `setsid -w`?(busybox 沒有 `-w`)— 最簡單是接受並寫進介面表「reconcile 給 joinwatch 用;手動請用 `status`」。

**A12-m7 HUNG 之後每 tick 一行 log,永不停。**
- `batman-addr-defer:70` 在 `n ≥ 3` 時每次呼叫都 `log "HUNG…"`;joinwatch 15 s 一 tick → 5760 行/天進 logd ring,會把同一次開機的其他線索沖掉(logd ring 不大,第 11 輪 B 的 R1 教訓)。同理 `:59` 的 WARN 在 trial 期間每 tick 一行。
- 修:記 `$RUNDIR/addr-defer.hung` 旗標,只在第一次 log(或每 N tick 一次);halow-status 仍每次都報。

**A12-m8 §13.8.2 說 halow-status 也呼叫 `reconcile`;程式碼只呼叫 `status`。**
- 程式碼是對的(halow-status 契約是唯讀,`halow-status:3`),文件錯。順帶:§13.8.2 的 HUNG WARN 文案「請檢查 /var/lock」與 `halow-status:126` 實際文案不同(實際提的是 `joinwatch retries 3x, then reports HUNG`);`reconcile` 對 `env=unknown` **不 log**(`:58` 直接 exit 0),與介面表「只回報的情況 rc 0 + log」不符。
- 修:文件改成「halow-status 呼叫 status」;unknown 時加一行 log(受 m7 的節流)或把介面表改成「unknown:靜默」。

**A12-m9 CM4(P-U14 的量產板)上 `/proc/device-tree/chosen/bootloader/tryboot` 存在與否沒有證據;不存在時決定者 fail-open(stock)而且沒有任何 WARN。**
- `want()` 在 DT 節點缺失時回 stock(測試第 5 案「no DT node → stock」是刻意的)。Pi 4 上節點存在(02/04 實查 `00000000`;E1c trial `00000001`)。CM4 用同一代 EEPROM,**應該**一樣 — 但這正是「should be」。若缺失,每次 OTA trial 都回到 B-M4 而 halow-status 說 OK(want=stock env=absent 是正常態)。
- 修:列進 CM4 reality check(§13.12 已預告);tier A 加「DT tryboot 節點存在」斷言(M1 第 2 點),把 fail-open 變成看得見的 FAIL。

**A12-m10 witness 條目的路徑格式與其他 patch 不一致。**
- 0014 的 `Batman-Witness: file /etc/init.d/openmanetd …` 帶前導 `/`,其餘都是 `etc/…`;`chk_patches_275` 做 `$R/$a` → `/rom//etc/init.d/openmanetd`,Linux 接受,所以 04 上判 ok。純一致性;改成 `etc/init.d/openmanetd` 即可(firmware 一行)。

---

## 7. 生命週期矩陣(本輪核對;✅ 讀碼/實測可證,⚠️ 推論)

| 路徵 | 行為 | 證據 |
|---|---|---|
| 安裝 / 首次開機(新卡,tryboot=0) | 決定者 stock;不碰磁碟 | ✅ stub 案 1;02/04 committed 槽 `want=stock` |
| trial 開機(tryboot=1) | 暫停;S99 一行 log;worker 不起 | ✅ E1c pos2 |
| bat0 up 的 `restart`(trial 內) | 決定者再跑一次,仍暫停;不碰 p7 | ✅ 讀碼(`service_triggers`);Pi 3 不適用(P-U14) |
| openmanetd 崩 → respawn | env 沿用 | ✅ E1c kill 測試 |
| crash loop → procd 放棄 | autocommit 判 svc down → revert;與今天同 | ⚠️ 推論(第 11 輪 B 的 `instance_exit:866-873`) |
| commit(autocommit) | 旗標 → start → 1 s 內 env 清掉 → worker → 125 s 後重開到同槽 | ✅ E1c pos2 |
| commit(互動 ssh / 網頁終端機) | 同一條;setsid 走 fork 路徑 | ⚠️ 未在節點實測(§4 第 2、3 點) |
| commit 的 start 沒送達 | joinwatch 下一 tick reconcile;3 次後 HUNG | ✅ stub;節點上未發生 |
| commit → rollback 同一開機 | 旗標刪;worker 開著;重開落 [all]=另一槽;WARN 文案錯 | ⚠️ 讀碼;m4 |
| 乾淨停機 / 斷電 | tmpfs 旗標、計數、pid 全消失;下次開機 tryboot=0 → stock | ✅ 設計;E1c 多次重開後 `want=stock env=absent` |
| 升級 wsl.12 → 13 | trial 有 hook;legacy 槽(`dhcpconfigured=1`)暫停無可見效果,commit 多一次 openmanetd 重啟 | ✅ ROLL13(§13.10),4 筆 `ADDR-DEFER-RELEASE flag=written` |
| 降版到 wsl.12 | trial 無 hook → B-M4 回來 | ✅ 這就是 E1c NEG |
| ubusd 無回應 | `have`=unknown → 不動作;halow-status / joinwatch 每次多等 ≤5 s | ✅ stub(unknown)/ ⚠️ 延遲未量 |
| procd 鎖被持有 | start 卡住;最多 3 支;HUNG WARN(log 噴量 m7) | ✅ stub(hang) |
| joinwatch 重啟 | 計數在 RUNDIR,上限仍是每開機 | ✅ 讀碼 |
| Pi 4 / CM4 / Pi 3 | Pi 4 ✅;CM4 ⚠️ m9;Pi 3 P-U14 殘項 | — |

## 8. 安全(逐 actor)

- **遠端 / 網頁使用者**:沒有新輸入面。網頁能改 config.yml,改不了 procd env、寫不進 RUNDIR(root 0700)。網頁終端機本來就是 root。
- **本機非特權程序**(04 上有 provd/dnsmasq/ntp/logd/ubus/nobody/docker 等 uid):`/usr/libexec/batman-addr-defer` 0755 可執行 — `status` 只讀;`reconcile` 在 `batman_rundir` 失敗(不是 owner)前就只能 log,寫不了 pid/計數;決定者無參數對非 root 無副作用。能做的:持有 `/var/lock/procd_openmanetd.lock`(既有面)→ 現在上限 3 支 + WARN ✅ 比第 11 輪好;跑一個叫 `openmanetd` 的程序騙 `pidof` → 只影響 status 文字。✅ 無新權限。
- **被攻陷的 openmanetd**:它以 root 跑(04 `ps`),本來就能做任何事;新 env 變數對它無意義。
- **供應鏈 / 我們自己的錯**:patch 掉了 → 靜默回 B-M4(M1、m9);決定者檔與 image 不一致 → 本輪驗 sha 相同 ✅。
- **fail 方向**:判不出(RUNDIR 壞、ubus 壞)→ 暫停 / 不動作 = 安全;DT 節點缺 → stock = **fail-open**(m9,設計刻意,但要有可見性)。
- **秘密**:無。

## 9. 沒做 / 部分 / 推論
- ❌ 節點零寫入、零重啟;沒有在節點上造競賽、持鎖、或觸發 reconcile。
- ⚠️ setsid fork 路徵、rollback 後的行為、ubusd 卡住的延遲、CM4 DT 節點,都是讀碼或推論。
- ⚠️ `7459641` 的 statecmp 14/14 沒重跑。
- ✅ 22 案例 + 7 突變實跑;02/04 唯讀探查;E1c 四份 log 對照 §13.9–§13.13 逐條核過。

## 10. 編號摘要
- **A12-M1**(MAJOR)stub 測試沒接進 CI / daily-validation;§13.8.1 (5) tier A 斷言不存在;`batman-slot commit/rollback` 旗標路徑無 stub。H2 PR 前補,附負對照(6e3a8c1 的 batman-slot)。
- A12-m1 §3 擁有權表缺四個新資源。
- A12-m2 §13.8 舊文未逐段標作廢;§13.8.1 測項清單含已作廢案例。
- A12-m3 `/var/lock` 既有面未寫進 §8 / §11。
- A12-m4 「hook missing」文案在 rollback 後歸因錯。
- A12-m5 `env -i` 與 `ubus -t 5` 無負對照。
- A12-m6 互動 shell 下 reconcile 單例無效(busybox setsid fork)。
- A12-m7 HUNG / trial-WARN 每 tick 一行 log,無節流。
- A12-m8 §13.8.2 說 halow-status 呼叫 reconcile(實為 status);HUNG 文案與 unknown 不 log 與介面表不符。
- A12-m9 CM4 上 DT tryboot 節點存在性無證據;缺失時 fail-open 且無 WARN。
- A12-m10 0014 witness 路徑帶前導 `/`,與其他 patch 不一致。

**判定:APPROVE-WITH-CHANGES。** 程式碼與 §13.8.2 一致、真機端到端成立、負對照成立;M1 是常規套的回歸保護,必須在 H2 PR 前補齊;MINOR 可在同一輪修訂一併處理,不需要再換機制。
