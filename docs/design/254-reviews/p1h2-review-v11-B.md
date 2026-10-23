# #254 PR-P1 + H2 設計 v5.1 / §13.8 + §13.8.1 — 第 11 輪獨立審查(審查者 B)

**Verdict: APPROVE-WITH-CHANGES**(0 BLOCKER / 1 MAJOR / 7 MINOR)

- **B10-M1 已關**:解除改成 detached `setsid … start`,不經 stop。我在主機上做了負對照(見 E-1):模擬網頁終端機的 teardown(關 PTY master → 對 shell 的 process group 送 TERM 再 KILL),舊寫法的前景工作被殺,新寫法的 setsid 子程序在 dash 和 busybox sh 下都活到底。另外一個更強的理由:HUP 的來源是 openmanetd 死掉,而 openmanetd 只會在 procd 收到那個 `ubus call service set` **之後**才死,所以 HUP 在因果上永遠落在 `setsid()` 之後,沒有 fork 與 setsid 之間的競賽。
- **A10-M1 已關**:(a) 權威狀態改讀 `ubus call service list` 的 env(`instance.c:1685-1691` 實際會輸出 env;04 上現在沒有 env 鍵,所以「沒有這個鍵」= 沒有暫停);(b) `slot-committed` 旗標在 DT `tryboot=1` 的整個 committed 開機內短路了 `is-trial`,Pi 3 的 rc 2 不再能讓 committed 槽重新暫停;(c) 決定者和 commit 的競賽由「無條件 `start`」加 joinwatch 對帳收斂,最壞延遲一個 tick(15 s)+ 一次 openmanetd 重啟。
- 修訂新引進的問題只有一個 MAJOR:步驟 3 的「逾時就 kill `is-trial`」在 Pi 3 上會留下 p7 的唯讀掛載,之後每一次 commit 都會 die,好的 trial 在期限到時被退回。修法很小(不 kill,或乾脆拿掉步驟 3)。

審查範圍:整份 v5.1 再看一遍,§13.8/§13.8.1 與它們引用的程式最細。全部唯讀:WSL 讀原始碼與 Batman-p1 feed(HEAD 6e3a8c1),04(10.41.1.3,wsl.12)只用 ssh 讀。沒有改 repo,沒有改節點狀態,實驗只在主機 /tmp。

---

## A. 證據

| # | 主張 | 結果 | 證據 |
|---|---|---|---|
| E-1 | detached `setsid … &` 不受 PTY hangup + pgrp TERM/KILL 影響;`restart` 式的前景工作會 | ✅ 實測 | `scratchpad/h2/rv11/hup.py`(`pty.fork` 一個互動 shell,送指令,0.5 s 後 `os.close(master)`、`killpg(TERM)`、`killpg(KILL)`,照 `terminal/session.go:94,116,121` 的順序)。輸出:<br>`dash old foreground-job-finished: False setsid-child-finished: False`<br>`busybox old foreground-job-finished: False setsid-child-finished: False`<br>`dash new foreground-job-finished: False setsid-child-finished: True`<br>`busybox new foreground-job-finished: False setsid-child-finished: True`<br>舊 = 前景 `sleep 2; touch`(代表 stop…start);新 = `setsid sh -c '…' </dev/null >/dev/null 2>&1 &`。 |
| E-2 | busybox `setsid` 語意 | ✅ 原始碼 | `busybox-1.36.1/util-linux/setsid.c:56-73`:`setsid()` 失敗(呼叫者已是 pgrp leader)時 fork 後在子程序再 `setsid()`,父程序回 0。從非互動的 `batman-slot`(`/bin/sh` 跑腳本,不開 job control)用 `&` 啟動時子程序不是 leader,`setsid()` 直接成功。兩條路都到新 session。04:`/usr/bin/setsid -> busybox`,`CONFIG_SETSID=y`。 |
| E-3 | `start` 對執行中的 service:env 變 → procd 內部重啟;沒變 → 不動 | ✅ 原始碼 | `rc.common:137-142` `start()` = `rc_procd start_service`,無條件 `ubus call service set`(`procd.sh:99-110`);`instance.c:1564-1583 instance_update`:running 且 `changed` → `instance_restart`;否則只比 data。`instance_config_changed:960` 比 env。`instance_restart:904-919`:`halt=restart=true`、SIGTERM、`term_timeout`;`instance_exit:859-864` 走 `restart=true` 分支,**不經過 respawn 計數**(`:866-879` 只在 `else if (in->respawn)` 才算)。所以解除的那次重啟不會吃掉 5 次 respawn 額度。 |
| E-4 | `ubus call service list` 吐 env | ✅ 原始碼 + 04 | `instance.c:1685-1691`(有 env 才開 `"env"` table)。04 現況(wsl.12,無 hook):instance1 pid 5504,沒有 `env` 鍵。 |
| E-5 | `rc.common restart` 兩段;`stop` 刪 service | ✅(同第 10 輪) | `rc.common:23-28`;`procd.sh` `_procd_kill` → `service delete`。 |
| E-6 | 04 沒有 `timeout`,有 `flock`、`setsid`;busybox `sleep` 不吃小數 | ✅ 04 | `command -v timeout` → MISSING;`sleep 0.1` → `invalid number`。所以輪詢步長最小 1 s。 |
| E-7 | 網頁終端機 teardown 順序 | ✅ 原始碼 | `terminal/session.go:94-95` 先關 PTY/WS,`:116` `Kill(-pgid, SIGTERM)`,`:121` `SIGKILL`。 |
| E-8 | Pi 3 `is-trial` 的 I/O 路徑 | ✅ 原始碼 | `batman-slot:720-726 is_trial` → `committed_fw` → `autoboot_read:254-263`:p7 沒掛就 `mount -t vfat -o ro` 到 `tmpd`、cat、umount;`detect_layout:188-202` 讀 MBR(`raw_read` 1 磁區)。`write_autoboot_pi3:308` 看到 p7 已掛就 `die`。EXIT trap(`:157`)只清 MBR 快取/busy/lock,**不卸載**。 |
| E-9 | `slot_lock` 需要 RUNDIR;commit 一定經過 | ✅ 原始碼 | `batman-slot:84-96`、`cmd_commit:728-729`。所以「commit 成功但 RUNDIR 不可用」不存在;`slot-committed` 寫不進去只可能在 commit 之後目錄被動過。 |
| E-10 | procd 開機 rcS 序列化 | ✅ 原始碼 | `rcS.c:199-201` `q.max_running_tasks = 1`(開機 `/etc/rc.d` 佇列);`:217-219` 一般 `rc()` 佇列 8。 |
| E-11 | joinwatch tick | ✅ 原始碼 | `joinwatch:127-182` `while :; live; …; sleep $POLL`,預設 `poll=15`(init 寫的 uci 預設)。 |
| E-12 | rundir 契約 | ✅ 原始碼 | `rundir.sh:23-33`:`batman_rundir` 驗 parent 非 group/other-writable、RUNDIR `drwx------` 且 owner=me,失敗 rc 1。 |

---

## B. 發現

### MAJOR

**B11-M1 步驟 3 的逾時 `kill` 在 Pi 3 上會留下 p7 的唯讀掛載;之後每一次 `batman-slot commit` 都 die,好的 trial 在期限到時被退回。**
- **情境**(現場,Pi 3,trial 開機):S99 openmanetd start → 決定者 → tryboot=1、沒有 `slot-committed` → 背景 `batman-slot is-trial`。SD 在開機 I/O 風暴下慢(Pi 3A+ 512 MB,`rcS` 又是序列化的,E-10),`mount -t vfat -o ro p7` 或 `cat` 超過 10 s。決定者 kill 背景的 shell。
  - `kill` 殺的是 `/bin/sh batman-slot`;`mount` 若已回來,掛載留著,沒有人 umount(E-8:EXIT trap 不卸)。`mount` 若還在 syscall 裡,它是另一個 process,會自己完成,然後掛載一樣留著。
  - 之後 autocommit 判健康 → `batman-slot commit` → `write_autoboot_pi3:308` `die "p7 is mounted"` → `batman-autocommit:539` 重試 → 每個 poll 都 die → 期限到 → revert 回 A。**一個健康的 trial 因為我們自己的新機制被退回**,而 log 只會寫「p7 is mounted」,看不出是決定者留的。
  - 連帶:`autoboot_read:256` 之後會從 `/proc/mounts` 找到那個 mktemp 目錄去讀,`halow-status`/`is-trial` 全部走這個洩漏的掛載。
- **證據**:E-8(原始碼);⚠️ 時序推論,沒有 Pi 3 可驗(03 停用)。10 s 在 Pi 3 開機時會不會被超過,設計沒有量過,我也量不到;但這條分支存在就不該留下掛載。
- **為什麼是 MAJOR**:修訂新引進的失效路徑;靜默;結果是丟掉一次 OTA。第 10 輪 B10-m2 的修法本意是「少掛 p7」,這一版反而在最糟時刻多了一個不會收尾的掛載。
- **修法**(擇一,都小):
  1. **拿掉步驟 3**。在 DT `tryboot=1` 的開機裡,`[tryboot]` 永遠指向非 committed 槽(`cmd_apply:565-567` 拒絕 mis-aimed),而這次開機內的 commit 一定寫 `slot-committed`(E-9)。所以「tryboot=1 且沒有旗標」⇒ 未 commit,`is-trial` 回 1 只可能來自我們自己以外的寫者(手改 autoboot.txt)。這種情況暫停到下次 start 也只是 fail-closed。決定者於是零 I/O、零逾時、Pi 3 零掛載,B10-m2 的殘留競賽(m2)也一起消失。
  2. 若保留步驟 3:**逾時不 kill**。決定「暫停」後直接返回,讓背景 `is-trial` 自己跑完並卸載(stdio 全導向 `/dev/null`,rc 檔之後沒人讀也無妨)。
- **負對照**(stub):`batman-slot` stub 的 `is-trial` = `touch $STUB_MOUNTED` 後 `sleep 30` 再 `rm`。舊規則 → 決定者回來後 `$STUB_MOUNTED` 仍在、stub 的清理沒執行;修法 1 → 決定者根本不叫 stub;修法 2 → 30 s 後 stub 自己清掉。

### MINOR

**B11-m1 決定者在 RUNDIR 不可用時的行為沒有規定;而且 joinwatch 用自己的一套規則對帳,沒有限流。**
- 設計寫「`$RUNDIR/slot-committed` 存在 → 不暫停」,但沒說是 `[ -e ]` 還是先 `batman_rundir` 驗目錄。如果實作學 `batman-slot` 的 `need_rundir` 模式,目錄驗不過就 die/暫停,而 joinwatch 只做 `[ -e ]`:兩邊對同一個旗標得到不同答案 → joinwatch 每 15 s 送一次 `start` → 決定者每次都暫停 → **openmanetd 每 15 s 重啟一次**(網頁、alfred、位址保留全部不穩),直到重開機。
- 觸發需要一個實作分歧,不是現場事件;但「同一條規則兩份實作」正是第 10 輪 A10-M1 的根因類型,而且 `start` 的無條件性讓分歧的代價變成重啟迴圈,不再是「卡住」。
- **修法**:(a) 規定決定者對旗標只做 `[ -e "$RUNDIR/slot-committed" ]`(信任根是 `/tmp/run` root 0755 + `/tmp/run/batman` root 0700,非 root 寫不進去,E-12;不需要 `batman_rundir`),RUNDIR 讀不到 = 旗標不存在 → 進下一步;(b) joinwatch 的對帳**不要自己重寫規則**,直接呼叫 `batman-addr-defer`(有旗標時它零成本),「決定者說不暫停、ubus 卻有 env」才送 `start`;(c) 每次開機最多對帳 N 次(建議 3)並 WARN,超過只 WARN 不再 `start`;halow-status 顯示次數。
- **負對照**(stub):stub 決定者強制回「暫停」+ 旗標存在:舊 → 60 s 內 ≥4 次 `start`;新 → 最多 N 次然後只剩 WARN。

**B11-m2 B10-m2 的殘留:Pi 3 trial 期間 bat0 up 的 restart 仍會在 commit 當下掛 p7。**
- §13.8.1 說「避免 Pi 3 在一般開機時每次都掛載 p7」——正確,但 trial 期間(tryboot=1、尚無旗標)每一次 `interface.*.up bat0` → `restart` → 決定者 → `is-trial` → 掛 p7,仍可能撞上 `write_autoboot_pi3`(die「p7 is mounted」或讀回經快取而 die「CHECK THE CARD」)。autocommit 重試,所以不致命,但要在生命週期表寫明「Pi 3 trial 內 commit 可能因此重試一次」,並承認沒有硬體驗證。M1 的修法 1 會一併消掉它。

**B11-m3 `start` 的副作用寫得太輕。**
- `start` 不看 enabled、不看操作員是否刻意 `stop` 過:commit 一律把 openmanetd 拉起來。測試或維修中刻意停掉 openmanetd 的操作員,commit 後會發現它又活了。
- 「只有 trial 才會多一次 openmanetd restart」沒錯,但每一台節點每一次 OTA 都是 trial:**fleet 每次 OTA 都多一次 openmanetd 重啟**(網頁 session 斷、alfred 重啟、term_timeout 5 s 內的空窗)。可接受,但要照實寫進操作文件和 §7.2 副作用。
- 修法:文件;以及 commit 那行加註「若 `/etc/init.d/openmanetd` 不存在或不可執行就跳過」(避免 shell 噴錯)。

**B11-m4 背景 `is-trial` 的 rc 檔與 stdio 沒有規定(#280)。**
- rc 檔必須用 `batman_tmp`(RUNDIR 內 mktemp),RUNDIR 不可用時退到 `mktemp /tmp/…XXXXXX`,**不能**是固定名(`/tmp/addr-defer.rc` 之類會被非 root 預建,fs.protected_regular=0)。
- 背景子程序 `</dev/null >/dev/null 2>&1`,否則它握著 init 的 stdout(procd 把 init 輸出接到 log),且 M1 修法 2 的「不 kill 讓它跑完」需要它完全脫離。
- 若採 M1 修法 1,此條消失。

**B11-m5 Pi 3 時序只有上限、沒有量測;rcS 序列化讓上限變成開機延遲。**
- 開機 S99 的 `start` 在 `rcS` 單工佇列裡(E-10):決定者最壞 10 s 會把 S99 之後所有 init 延後 10 s。正常路徑的 Pi 3 時間(MBR 讀 + vfat 掛/卸)沒有數字。
- 修法:決定者把自己的耗時與判斷寫一行 otatrace(`ADDR-DEFER verdict=… ms=…`),E1c 在 Pi 4 至少拿到一個數;Pi 3 列進 #254 殘項 checklist(「03 復活後量決定者耗時」),標 ⚠️。M1 修法 1 讓這一條只剩「讀 DT + `[ -e ]`」,毫秒級。

**B11-m6 stub/E1c 清單缺兩個收斂案例與一個時間界。**
- stub:(i) commit 的 `start` 送不出去(stub `ubus` 失敗)→ commit rc 不變、joinwatch 下一 tick 對帳成功;(ii) 決定者在旗標寫入前讀到「無旗標」、procd 後到的 `set` 蓋掉 commit 的 `set`(A10-M1(c))→ 一個 tick 後 env 消失。
- E1c v4 的「release 之後 ubus env 沒有變數」要加時間界:≤ 15 s(一個 tick)+ `term_timeout` 5 s + 啟動,建議斷言 30 s 內;沒有時間界的話,靠對帳收斂的 bug 會被當成 PASS。

**B11-m7 文件:OTA 到沒有 hook 的 image(降版 trial)會把 B-M4 競賽帶回來。**
- 表格寫「降版…行為和今天相同」是對的;操作文件要明說:退回 wsl.12 類 image 做 trial 時,fresh 槽仍會在 trial 內被 openmanetd 重開而無聲退回。一句話即可。

---

## C. 生命週期矩陣(第 11 輪補審;✅ = 原始碼可證,⚠️ = 推論/無硬體)

| 路徑 | 結論 | 依據 |
|---|---|---|
| 新卡第一次開機 / 一般開機(tryboot=0) | 決定者只讀 DT → 不暫停;Pi 3 不掛 p7 | §13.8.1 步驟 1 |
| trial 開機(tryboot=1) | 暫停;Pi 3 掛一次 p7(M1/m2) | E-8 |
| commit(autocommit 或操作員 ssh/網頁終端機) | 旗標 → detached `start` → procd 內部重啟 → 不暫停 | ✅ E-1/E-2/E-3 |
| commit 後、同一次開機的 bat0 up / 網頁 restart | tryboot 仍=1,旗標短路 → 不暫停;不碰 p7 | §13.8.1 步驟 2 |
| commit 與 trigger restart 同時 | 最壞一個 tick 後由 joinwatch 收斂 | m1(c)/m6 |
| commit 後 `start` 沒送達(ubus 掛、power loss 前) | 下一 tick 對帳;power loss → 下次開機 tryboot=0 → 正常 | m6 |
| RUNDIR 在 commit 後被動過 | 決定者行為未定(m1);最壞 15 s 重啟迴圈 | m1 |
| is-trial 逾時(Pi 3) | 暫停;**kill 留下 p7 掛載 → commit 永遠 die → 期限 revert** | **M1** |
| procd respawn(openmanetd 崩) | 沿用上次 env;解除的重啟不吃 respawn 額度 | ✅ E-3 |
| crash loop → procd 放棄 | autocommit 判 svc down → 不 commit → revert;和今天同 | `instance_exit:866-873` |
| 操作員刻意 stop 了 openmanetd | commit 會把它拉起來 | m3 |
| rollback(trial 內操作員) | 仍是 trial → 暫停直到重開回 A;A 開機 tryboot=0 → 正常 | 步驟 1 |
| 升級 wsl.12 → 新版 | trial 有 hook;dhcpconfigured=1 的節點只多一次 openmanetd 重啟 | m3 |
| 降版到 wsl.12 | 無 hook;B-M4 回來 | m7 |
| Pi 4 / Pi 3 | 同一 patch;Pi 3 全部 ⚠️ 無硬體(M1、m2、m5) | — |
| 停電 | 任何時刻都只丟 tmpfs 旗標與 env;下次開機重判 | 設計 |

## D. 安全(逐 actor,只寫差異)
- **網頁使用者 / 遠端**:仍改不了 procd env。新增的 `slot-committed` 在 root 0700 目錄,寫不到;`ubus call service list` 是唯讀。網頁終端機本來就是 root。無新面。
- **本機非 root**:m4 的 rc 檔若放固定名在 `/tmp` 就是 #280 類洞 → 必須 `batman_tmp`。旗標的讀取只信 `/tmp/run`(procd 建、root 0755)之下,`[ -e ]` 足夠。
- **被攻陷 peer**:能間接(讓 mesh 掉)讓節點多跑幾次決定者;後果只有 Pi 3 trial 內多掛幾次 p7(m2),commit 由 autocommit 重試。無新權限。
- **我們自己的失誤**:兩份規則(m1)、kill 留掛載(M1)。

## E. 對第 10 輪結論的更正
- 第 10 輪 B10-m2 我建議「只有 tryboot=1 才呼叫 is-trial」,沒有指出 trial 內的競賽仍在、也沒有想到逾時 kill 的後果;M1/m2 是在補我自己的漏洞。

## F. 判定
APPROVE-WITH-CHANGES。M1 關掉(建議修法 1:拿掉步驟 3)並把 m1 的「單一規則 + 限流」寫進 §13.8.1 後,不需要再換機制;其餘 MINOR 可在同一版修訂一併改。
