# #254 PR-P1 + H2 — 第 12 輪獨立審查(審查者 B):§13.8.2 位址保留延後的程式碼審查 + 整份設計複審

**Verdict: APPROVE-WITH-CHANGES**(0 BLOCKER / 1 MAJOR / 8 MINOR)

- **B11-M1 已關**:決定者不再呼叫 `is-trial`、不碰磁碟(`batman-addr-defer:35-36`,只讀 DT + `[ -e ]`);stub 以 grep 斷言程式碼內沒有 `mount`/`batman-slot`(`addr-defer.sh:54`)。
- **B11-m1 已關**:規則只有一份(joinwatch/halow-status 都呼叫決定者,`joinwatch:130`、`halow-status:124`);RUNDIR 不可用 → 決定者 fail-closed 暫停(`:36`,stub `:51`)、對帳只回報(`:61`,stub `:74`);限流 3 次/開機(`:64-67`,stub `:69-70`)。
- **A11-M1/M2、A11-m1/m2/m3/m5/m8** 在程式碼裡都有對應(見 §A)。
- 真機:§13.13 的 E1c v4 第 2 次是端到端的正向證據,§13.9 是 B-M4 的真機重現(負對照);我重讀了 `e1c-v4-pos2.log` 原始行,結論與 §13.13 一致。
- 這一輪新引進的問題沒有 BLOCKER。唯一的 MAJOR 不是程式碼錯,而是**這個修法在常規驗證裡沒有任何測項**:stub 沒接 CI,設計 §13.8.1 第 5 點承諾的 tier A 斷言沒有寫進 `prov-p1-254.sh`。

審查範圍:整份 `254-p1-impl.md`(含 §13.8–§13.13)、Batman-p1 `feat/254-p1` d88250b(+6e3a8c1 只看 stat)、firmware 51f8f256 / 92925673、Batman-h2 `harness/254-h2` e815493 / 65d351f / 7459641、E1c v4 腳本與三份 log。全部唯讀:repo 內容以 `git show` 複製到 scratchpad `rv12/src/` 再讀;節點只碰 02(10.41.1.1,wsl.13)且只讀;**沒有碰 04**。測試在 WSL 跑,寫入只在 scratchpad。

---

## A. 證據(✅ 實跑或原始碼;⚠️ 推論)

| # | 主張 | 結果 | 證據 |
|---|---|---|---|
| E-1 | stub 測試在 dash 與 busybox ash 下全過;四個 mutant 都被抓到(測試有鑑別力) | ✅ | `rv12/runtests.sh` 輸出:`/bin/sh (/usr/bin/dash) … ADDR-DEFER fails=0`;`busybox ash … fails=0`;**M1 決定者忽略 `slot-committed`** → `FAIL slot-committed should make it stock, fails=1`;**M2 拿掉單例** → `FAIL singleton: starts=3`;**M3 `MAX_STARTS=99`** → `FAIL cap: rc=0 starts=4`;**M4 `have()` 比對 `"true"`** → 6 FAIL。負對照(stock init)`ok stock init (negative control): never sets env`。shellcheck `-s sh` 無輸出(乾淨)。 |
| E-2 | 兩板 patch 0014 逐位元相同;掛勾位置在 `procd_set_param command` 之後、`respawn` 之前 | ✅ | `diff patches/ekh-bcm2710/0014… patches/ekh-bcm2711/0014…` → IDENTICAL;patch 內容如 51f8f256。stock init 以 `patch -R` 還原後只有 3 行差。 |
| E-3 | 02(committed、tryboot=0)上的真實 `ubus call service list` 沒有 `env` 鍵;決定者 `status` = `want=stock env=absent openmanetd=up`;DT `tryboot` 存在且 `hexdump` 輸出 `00000000` | ✅ 02 | 原始輸出在本輪 ssh 紀錄:`instance1 {running, pid 5357, command, term_timeout 5, respawn{3600,5,5}}`,無 `env`;`/proc/device-tree/chosen/bootloader/tryboot` 4 bytes;`hexdump/setsid/env/pidof/flock/logger -> /bin/busybox`。 |
| E-4 | 真機 trial 內 grep 比對得到 `present`(格式 `"KEY": "false"`) | ✅ 04 log | `e1c-v4-pos2.log:24` `status=[want=defer env=present openmanetd=up]`;`:29` release 後 1 s `env=0 status=[want=stock env=absent …]`。procd 輸出 env 的碼:`instance.c:1685-1691`(有 env 才開 table)。 |
| E-5 | `start` 對執行中的 instance:env 變 → `instance_restart`;不走 respawn 計數 | ✅ 原始碼 | `instance.c:960` `blobmsg_list_equal(&in->env, …)`;`:1564-1583 instance_update`;`:857-864 instance_exit` `halt && restart → restart=true`,respawn 分支 `:866-` 不經過。 |
| E-6 | `procd_lock` 在 `rc_procd` → `procd_open_service` 之前取得(序列化決定者與 commit 的 `start`) | ✅ 原始碼 | `procd.sh:48-60 procd_lock` 以 `exec 1000>/var/lock/procd_<svc>.lock; flock 1000`;`procd.sh:71` 在 `_procd_open_service` 路徑呼叫;`rc.common:129-134 rc_procd`。 |
| E-7 | `env -i PATH=… setsid /etc/init.d/openmanetd start` 在真機能讓 procd 重啟 openmanetd | ✅ 04 log | `e1c-v4-pos2.log:27-30`:`release: committed` → 1 s 內 `omd_pid 13541 -> 10915`、`env=0`、`worker_init=1`。這條就是 `batman-slot:addr_defer_release` 的那一行(經 autocommit release)。所以「`env -i` 會不會缺 rc.common/procd.sh 需要的變數」已由真機回答:不缺(`IPKG_INSTROOT` 空即可,`initscript` 由 `/bin/sh /etc/rc.common` 自己設)。 |
| E-8 | busybox `setsid` 在這裡不 fork → `$!` 就是 start 鏈的 pid | ✅ 原始碼 + ⚠️ 推論 | `busybox setsid.c:56-73`(第 11 輪 E-2):只有呼叫者已是 pgrp leader 才 fork。`&` 的子程序在非互動 sh(無 job control)下與父同 pgrp、pid ≠ pgid → 不是 leader → `setsid()` 直接成功、`exec`。procd 起 joinwatch 時沒有 `setsid/setpgid`(`instance.c` grep 無)。⚠️ 對帳路徑從未在真機觸發,所以 `$pf` 的 pid 正確性只有推論。 |
| E-9 | joinwatch 單一 instance、每 15 s 一 tick | ✅ 02 | `/etc/init.d/joinwatch:18-20` 一個 instance,`respawn 3600 5 0`;02 上 `ps` 只有 1 個 `joinwatch run`;poll 用預設 15。 |
| E-10 | `/var/lock` 1777、`procd_openmanetd.lock` root 0644 → 本機任何 uid 可 O_RDONLY + flock 永久持有 | ✅ 02 | `drwxrwxrwt /var/lock`;`-rw-r--r-- procd_openmanetd.lock`、`procd_joinwatch.lock`。`fs.protected_regular=2`(rundir.sh 註解寫 0,過時但方向更嚴,無害)。 |
| E-11 | config-save `--on-join` 會把 `config.yml` 與 `dhcpconfigured` 寫進 p5,每 tick 一次 | ✅ 原始碼 | `batman-config-save:48` `openmanetd.config.dhcpconfigured` 在 uci 鍵清單;`:400-401` 複製 `/etc/openmanet/config.yml` 到 `identity/openmanet/`;`:165` `.txn` 進行中 → `--on-join` 退 1 不寫;`joinwatch:150` 每個 JOINED tick 呼叫。 |
| E-12 | 02 現況與旗標語意一致 | ✅ 02 | boot `a0faaf6a`、`is-trial` rc 1、`/tmp/run/batman/` **沒有** `slot-committed`;otatrace 最後一筆是前一次開機的 `ROLLED-BACK`,本次開機沒有 commit,所以沒有旗標是對的。 |
| E-13 | CI 不跑 `tests/prov-p1/*`;tier A 判官沒有 addr-defer | ✅ h2 | `grep prov-p1\|addr-defer .github/workflows/*.yml` → 無;`scripts/node/prov-p1-254.sh` 無 `addr-defer`;`git grep addr-defer` 只中 `tests/prov-p1/addr-defer.sh`。 |
| E-14 | deploy/provisioning 鏡像一致 | ✅ p1 | `halow-status`、`joinwatch` deploy==feed;`batman-slot`、`batman-addr-defer` 沒有 deploy 副本(golden 路徑沒有 A/B;兩支呼叫端都有 `[ -x ]` 守門,golden 節點是 no-op)。`provisioning-sync.yml` 只比對兩邊都有的檔。 |
| E-15 | wsl.12 負對照是法醫式重現,不是 v4 腳本的斷言路徑 | ✅ log | `e1c-v4-neg.log:12-13`:腳本在 trial 階段當掉(`FOUND_HOW` bug)→ `E1c RESULT: FAIL`;重現證據來自 p6 的 `boot-reasons.log`(`uptime=170.45s trigger=reboot/halt command`)與關機 dump(`AddressReservationWorker initialized` → 126 s 後 `Rebooting system`,`dt_tryboot=00000001`),見 §13.9。 |

---

## B. 發現

### MAJOR

**B12-M1 這個修法在常規驗證裡沒有任何測項:stub 沒接 CI,§13.8.1 第 5 點承諾的 tier A 斷言沒有實作。**
- **情境**:下一個改 `batman-slot`/`joinwatch`/決定者的人(或上游 openmanetd init 改版讓 patch 0014 失效後有人「修」patch)把 `slot-committed` 的寫入或決定者的旗標判斷弄壞。今天唯一會發現的是:有人手動跑 scratchpad 的 `run_addrdefer.sh`,或是下一次 OTA 的 unclaimed 節點又在 trial 內無聲退回(也就是 B-M4 回來)。
- **證據**:E-13。`ci.yml` 只跑 `tests/vectors/219-protocol` 與 `tests/ab-card-invariants.sh`;`tests/prov-p1/` 八支都沒接。`prov-p1-254.sh`(tier A 唯讀判官)沒有「committed 槽 ubus env 不得有變數」「settle 後 `dhcpconfigured=1`」「image 同時有 witness 與決定者」三項。§13.8.2「已實作」段只列了 stub,沒有說 tier A 待做,§11 殘項也沒有。
- **為什麼是 MAJOR**:使用者規則「每個修法把回歸測試放進常規全套」「出貨判定只認 main 的 harness」(#290)。這是 P1 出貨前就必須在的東西,不是 nice-to-have;而且 E1c v4 這種 20 分鐘的破壞性測試不會每天跑,tier A 是唯一每天會跑的那層。
- **修法**(都在 H2,harness PR):
  1. `prov-p1-254.sh` 加三個斷言:(a) `batman-addr-defer status` 第二欄 `env=absent` 且第一欄 `want=stock`(tier A 只在 committed 節點跑);(b) `uci get openmanetd.config.dhcpconfigured` = 1 **或** 節點是 claimed+placeholder(A-m6 的例外要寫明判法,否則那類節點每天 FAIL);(c) `grep -q batman-addr-defer /etc/init.d/openmanetd` 與 `[ -x /usr/libexec/batman-addr-defer ]` **同時**成立,只有一個 = FAIL(A-m5)。wsl.12 依 P-U9 標 KNOWN + 期限。
  2. CI 跑 `tests/prov-p1/addr-defer.sh`(需要 patched init:CI 可用 `patch` 把 0014 套在 firmware 的 stock init 複本上,或把 stock init 放 fixture);兩種 sh 都跑。
  3. 若使用者決定 tier A 等 H2 整體收尾一起做,至少把它寫進 §11 殘項 + #254 checklist 並標 ❌,不要讓 §13.8.1 第 5 點看起來像已完成。
- **負對照**:(1) 把 `prov-p1-254.sh` 的斷言指向一個 `env=present` 的假 status → FAIL;(2) stub 在 CI 上以 E-1 的 mutant 1 跑一次 → FAIL。

### MINOR

**B12-m1 對帳的「HUNG」在 start 真的卡住時永遠到不了;設計表、halow-status 文案都說會到。**
- 情境:本機非 root 以 flock 持有 `/var/lock/procd_openmanetd.lock`(E-10;§13.8.2 自己列的既有面),或 ubus/procd 卡住。commit 的 detached `start` 卡住;joinwatch 第一個 tick 的 reconcile 再送一個,也卡住,`$pf` 記了它。之後每個 tick `kill -0` 成功 → `exit 0`(`:63`),計數停在 1,`HUNG` 那行(`:66`)永遠不印,rc 永遠 0。
- 設計 §13.8.2 生命週期列寫「flock 被卡住 … 第 1–3 次各一個 detached 程序;第 4 次起 HUNG」,halow-status 文案寫「joinwatch retries 3x, then reports HUNG」(`halow-status:124`)——兩者都不是程式的行為。程式的行為是:卡住 = 一個程序 + 沉默。可見性還在(halow-status 每次都會 WARN `want=stock env=present`),所以不是 MAJOR。
- 修法(擇一):(a) 改文件與文案成「一個 start 在跑就等它;3 次**完成**但沒效果才 HUNG」;(b) `$pf` 旁記 start 時的 uptime,活超過例如 60 s 就 log `HUNG` rc 2(start 正常 1 s 內完成,E-7)。stub 加一條:`hang` 旗標存在、連續 N 次 reconcile → 預期 rc 2。
- 負對照:現行程式在 stub `hang` 下跑 10 次 reconcile,rc 全 0、沒有 HUNG。

**B12-m2 `$RUNDIR/addr-defer.start.pid` 不會清除,pid 重用會讓對帳沉默。**
- `:63` 只看 `kill -0`。start 結束後 `$pf` 留著;pid 被任何長命程序重用(節點 400 s 內 pid 已到 13541,`pid_max` 預設 32768)→ 之後整個開機 reconcile 都「以為上一支還在跑」。只在「同一次開機需要第二次對帳」時才有影響,而這在現行狀態機裡幾乎不會發生(旗標寫一次、對帳成功一次就完),所以 MINOR。
- 修法:比對 `/proc/<pid>/cmdline` 含 `rc.common`/`openmanetd`(像 `batman-slot:84-96 slot_lock` 那樣),或對帳成功(`have`=absent)時 `rm -f "$pf"`。

**B12-m3 同一次開機 commit → rollback 後,halow-status / reconcile 的文案說「hook missing from this image」,是假訊息。**
- `cmd_rollback:763` 刪旗標是對的(A11-m1)。但 openmanetd 已在 commit 時被 restart 成 stock(env 沒了),rollback 不送 `start`,所以狀態 = `want=defer env=absent openmanetd=up` → `reconcile:56` log「hook missing?」、`halow-status:126` WARN「deferral hook missing from this image」。真相是「這個槽剛被 rollback,worker 將在 ≤125 s 內 plain reboot 到 `[all]`」——結果正好是 rollback 想要的(A11-m1 已分析無害),但文案會把操作員引去查 image。
- 修法:文案改成中性(「trial but openmanetd runs with reservation ON — either the hook is missing or this slot was rolled back after a commit; expect a reboot to the default slot」)。stub 一條。

**B12-m4 §13.8.1 列的 E1c 項目「再從 ssh 直接 `batman-slot commit` 一次,斷言 env 被清掉」❌ 沒做;B10-M1(PTY hangup)只有主機端證據。**
- E1c v4 兩次正向與 ROLL13 的四次 commit 都經 `batman-autocommit release`/autocommit 主程序,不是從 PTY 的 shell 跑 `batman-slot commit`。PTY hangup 免疫的證據仍是第 11 輪 E-1 的 python `pty.fork` 實驗(dash + busybox 都通過),機制上足夠,但這一條是設計自己列的真機項目。
- 修法:下一次有 trial 的機會(任何 tier B 跑完的 B 槽 trial)從 ssh **PTY**(`ssh -t`)跑 `batman-slot commit` 然後立刻斷線,30 s 內 `status` 要 `env=absent`、pid 要變。寫進 #254 checklist,標 ⚠️ 未做。

**B12-m5 wsl.12 負對照是法醫式的,不是「同一支 v4 在舊版 FAIL」。**
- E-15。重現本身成立(§13.9 的 shutdown dump 直接給出 126 s 的因果鏈),B-M4 算真機重現 ✅;但「v4 的斷言路徑在沒有 hook 的 image 上會 ABORT 到 A」這件事沒有被腳本證明(腳本在那之前就當了)。§13.9 要把這點寫明:負對照 = p6 證據,不是腳本結果。不需要重跑(成本高、結論不會變),除非之後有人要拿 v4 當 harness 測項。

**B12-m6 文件:§3 擁有權表沒有新資源;§8 / §11 沒有 §13.8.2 說要加的項目;§13.8 舊元件文字沒有逐段標作廢。**
- §3 沒有 `$RUNDIR/slot-committed`(寫:`batman-slot commit`;刪:`cmd_rollback`;讀:決定者)、`addr-defer.start.pid` / `addr-defer.starts`(決定者 reconcile 專用)、procd instance env(init 掛勾依決定者設;其他人只讀 ubus)。
- §13.8.2 說「`/var/lock` 面寫進 §8 並列殘項」— §8、§11 都沒有;P-U14 的 Pi 3 殘項也不在 §11(只在 §13.12 說「寫進 #254 checklist」)。
- §13.8 元件 1(寫 `addr-deferred` 旗標)、元件 3(`restart`)、「為什麼不會卡住」、契約段仍是舊版,只有標題一句「定稿見 §13.8.2」。A11-m8 要求的是像 §13.7 那樣逐段標「作廢」。
- 修法:補 §3 四列、§8 一條、§11 三條(tier A/CI = M1、PTY commit = m4、Pi 3 時序 + CM4 reality check),§13.8 被取代的段落開頭加「(作廢,見 §13.8.2)」。

**B12-m7 決定者的 log 在開機時出現兩次。**
- `log()`(`:27`)同時 `logger` 與 `echo >&2`;S99 由 procd 執行時 stderr 也進 syslog,所以 `e1c-v4-pos2.log:16-17` 同一句出現 `user.notice batman-addr-defer:` 與 `daemon.notice procd: /etc/rc.d/S99openmanetd: batman-addr-defer:` 兩行。無害,但 tier A 若用 `grep -c` 計數會算成 2。修法:`[ -t 2 ] && echo >&2`,或 tier A 用 `grep -q`。

**B12-m8 E1c 的 `OMD` 探針以 `pidof openmanetd | cut -d" " -f1` 取 pid,在 restart 的 5 s 內可能讀到舊 pid。**
- `e1c-v4.sh:37`。procd `instance_restart` 送 SIGTERM 後最多 5 s(`term_timeout 5`)新舊兩個 pid 並存;`pidof` 的順序沒有保證,`cut -f1` 可能選到正在死的那個 → `env=1` 誤判「還沒解除」。`:223` 的迴圈重試 30 s,所以只會延後、不會誤判 FAIL;這次實跑 1 s 就拿到新 pid。不是產品碼(決定者的 `omd_up` 只用 `pidof` 的 rc,`:43`,沒有這個問題)。修法:取 `ubus … service list` 的 `pid` 欄位,那是 procd 認的那一個。

---

## C. 生命週期矩陣(Pi 4 / CM4;Pi 3 依 P-U14 暫不支援,不列)

| 路徑 | 今天(wsl.12) | 改後(wsl.13) | 證明 |
|---|---|---|---|
| 新卡第一次開機 / 一般開機(DT tryboot=0 或無節點) | worker 125 s 後保留並重開 | 不變:決定者 `dt_tryboot` 假 → rc 1 → stock | stub `:48,:52`;02 實況 E-3 |
| fresh unclaimed 槽 trial(tryboot=1、無旗標) | **B-M4**:126 s 在 trial 內被 plain reboot 退回 A | 暫停;openmanetd 撐過 305 s;B boot_id 不變 | ✅ §13.9 負對照 vs §13.13 正向(`pos2.log:24-26`) |
| trial 內 openmanetd 崩 → procd respawn | 同上 | env 沿用、worker 仍關 | ✅ `pos2.log:25`(pid 6269 → 13541,env=1,worker_init=0) |
| commit(autocommit release) | — | 旗標寫入 → detached `start` → procd 重啟(env 變)→ 1 s 內 stock;worker 一次;146 s 後保留重開到同一槽;新開機 `dhcpconfigured=1`、IP `10.41.80.47`、300 s 穩定 | ✅ `pos2.log:27-58` |
| commit(操作員 ssh PTY,斷線) | — | 同上;PTY hangup 殺不到 setsid 子程序 | ⚠️ 只有第 11 輪 E-1 主機實驗;真機 ❌(m4) |
| commit 與 bat0-up `restart` 同時 | — | procd flock 序列化(E-6);最後進去的 `start` 讀到旗標 → stock;最壞一個 tick 由 reconcile 收斂 | 原始碼 E-5/E-6;⚠️ 真機沒觸發 |
| commit 後 `start` 送不出去(flock 被持有 / ubus 掛) | — | 下一 tick reconcile 送一次;**若那一支也卡住 → 沉默(m1)**;halow-status WARN 仍會出現 | stub `:66-67`(單例);HUNG 的真機路徑 ❌ |
| commit 後、`start` 前斷電 | — | 下次開機 tryboot=0 → stock;無殘留(tmpfs) | 設計;E-12(02 本次開機無旗標) |
| 同一次開機 commit → rollback | — | 旗標刪;openmanetd 已是 stock;worker 會 reboot 到 `[all]`(= rollback 目標);文案誤導(m3) | 原始碼 `batman-slot:763`;⚠️ 無真機 |
| 保留重開期間有人認領(`.txn`) | — | `--on-join` 遇 `.txn` 退 1 不寫(E-11);重開後由 `--apply-state` 收尾 | 原始碼;鏈 1 的那條測試 ❌ 尚未存在(設計 §13.8 自己列的) |
| claimed、`dhcpconfigured=0` 的還原槽 trial | 同 B-M4 競賽 | 暫停到 commit;若 trial 內已 JOINED,`--on-join` 會把 `dhcpconfigured=0` 寫進 p5,重開後 JOINED 的每個 tick 再寫成 1 → 收斂 | 原始碼 E-11;⚠️ 無真機(鏈 1) |
| 還原槽 trial、`dhcpconfigured=1` | worker 不觸發 | 暫停無可見效果 | ✅ §13.10(ROLL13 四次 commit,`flag=written`,都 committed) |
| 升級 wsl.12 → wsl.13 | — | trial 有 hook;committed 後多一次 openmanetd 重啟 | ✅ §13.10 |
| 降版到 wsl.12 | — | 無 hook → B-M4 回來(= 負對照) | ✅ §13.9 |
| crash loop → procd 放棄 openmanetd | — | `omd_up`=down;autocommit 判 svc down → 不 commit → deadline revert;和今天同 | `instance.c:866-873` |
| RUNDIR 不可用(/tmp/run 被動過) | — | 決定者:旗標不存在 → 暫停(fail-closed);commit 仍走 `slot_lock→need_rundir` 所以根本不會 commit | stub `:51,:74`;`batman-slot:65,84` |
| CM4(ekh-bcm2711 同 target) | — | 同一 image;DT `chosen/bootloader/tryboot` 由 EEPROM 提供,Pi 4 已證;CM4 eMMC / EEPROM 差異 | ⚠️ P-U14 說另開 reality check;本輪無硬體 |

## D. 安全(逐 actor,只寫這次改動的差異)
- **遠端 / 網頁使用者**:新增零對外輸入。決定者的輸入只有 root 唯讀的 DT 與 root 0700 目錄下的旗標;`ubus call service list` 唯讀。網頁改 config.yml 影響不到 procd env(這正是 §13.7 → §13.8 的理由)。無新面。
- **本機非 root 程序**:(1) 旗標 `/tmp/run/batman/slot-committed` 在 root 0700 目錄,`/tmp/run` root 0755 由 procd 建(E-3/E-12 實查),非 root 無法預建或刪除 → 無法強迫「trial 不暫停」也無法強迫「committed 永遠暫停」。(2) **既有面**:持有 `/var/lock/procd_openmanetd.lock`(E-10)可讓 commit 的 `start` 與 reconcile 永遠卡住 → committed 槽的 openmanetd 停在暫停、節點留在 bootstrap IP,halow-status WARN 但 HUNG 不出現(m1)。這和「卡住任何 init script」是同一個洞,不是本改動引進,但本改動讓它多了一個**可見後果**(位址永遠不保留);§8 要寫(m6)。(3) `env -i`(A11-m5)擋掉了 `BATMAN_FAULT_INJECT`/`BATMAN_ALLOW_*` 的繼承,只是可解釋性,不是權限邊界(能設 root env 的本來就是 root)。
- **被攻陷 peer / mesh**:能讓 bat0 flap → openmanetd 多次 restart → 決定者多跑幾次;決定者零 I/O、無狀態,代價只有 log 行。無新權限。
- **供應鏈 / 上游**:patch 0014 打在釘住版本的 init;上游改 init → patch 失敗 → build 失敗(不會靜默)。但若有人「修」patch 時弄錯位置(例如放到 `procd_close_instance` 之後),env 不會進 instance 而 build 照過 → 這就是 M1 要 CI 跑 stub(patched init 案例)的理由。
- **我們自己**:規則單一實作 ✅;文案與程式不一致(m1、m3);沒有常規測項(M1)。
- **秘密**:無。log 只有判斷結果。
- **失效模式**:決定者 fail-closed(無 RUNDIR → 暫停;hexdump 失敗 → 不暫停 ← 這一條是 fail-open,但 `hexdump` 是 busybox 內建,E-3,且 DT 節點不存在本來就該是 stock);對帳 fail-safe(unknown → 不動)。

## E. E1c v4 證明了什麼、沒證明什麼
**證明(一台 04,一次完整跑,Pi 4):** S99 決定者判 defer;`/proc/<pid>/environ` 有變數;`status` present;respawn 保留;openmanetd 305 s 無 worker、B 不重開(對照 wsl.12 的 126 s);release → committed → `start` 讓 procd 1 s 內換 pid、env 消失、worker 恰好一次;146 s 後在 committed 槽上保留重開;新開機 stock、`dhcpconfigured=1`、mDNS 27 s 找回、300 s 無第二次重開;還原到 A 乾淨(compare diffs=0)。
**沒證明(都要標 ⚠️/❌):** reconcile 任何分支在真機(含單例、計數、HUNG);rollback 刪旗標;PTY commit(m4);commit 與 bat0 restart 的競賽;hook-missing WARN 文案;claimed/`dhcpconfigured=0` 槽(鏈 1);保留重開期間認領;CM4;「在 30 s 內解除」只量到 1 s 一次,沒有分佈;respawn 只做一次。這些要麼靠 stub(有)、要麼列殘項。

## F. 對第 11 輪結論的更正
無。B11-M1 修法 1(拿掉 `is-trial`)被採用,結果如預期:決定者零 I/O、Pi 3 問題整類消失。B11-m1 的「限流 N 次」我當時沒想到「卡住的 start」會讓計數停住(m1 是在補我自己的漏洞)。

## G. 判定
**APPROVE-WITH-CHANGES。** 程式碼本身可以上 PR;M1 必須在 P1 出貨判定前落地(harness PR,或由使用者明確決定延後並寫進殘項);m1–m3、m6、m7 是同一版可以一起改的小修;m4、m5、m8 是紀錄與下一次有 trial 時的補量。不需要再換機制。
