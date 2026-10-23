# #254 PR-P1 + H2 設計 v5.1 / §13.8 — 第 10 輪獨立審查(審查者 B)

**Verdict: APPROVE-WITH-CHANGES**(0 BLOCKER / 1 MAJOR / 8 MINOR)

§13.8 的核心機制我逐段實查過,成立:env 能關掉 worker、蓋得過 config.yml(含壞 YAML)、procd 保留帶點的鍵名、所有「重啟 openmanetd」的路徑都會重新跑 start_service。第 9 輪 B9-M1(config.yml 有第二個寫入者)已經由「完全不碰 config.yml」根除。剩下一個 MAJOR 在**解除**那一步:`/etc/init.d/openmanetd restart` 是 stop+start 兩段,不是原子的,而設計自己列的「操作員手動 commit」路徑裡,有一條常見的現場做法(openmanetd 網頁終端機)會在兩段之間把呼叫者殺掉。修法很便宜(改用 `start`,並脫離呼叫者)。

審查範圍:整份 v5.1,§13.8 和它的證據段看得最細。所有實查都是唯讀:WSL 讀原始碼,04(wsl.12)用 ssh 只讀。我沒有改 repo,也沒有改節點狀態。

---

## A. 證據(我自己重跑 / 實查)

| # | 主張 | 結果 | 證據 |
|---|---|---|---|
| E-1 | env `ALFRED.DATATYPES.ADDRESSRESERVATION=false` 會關掉 worker | ✅ | 重跑 `src/envprobe.sh`:不設 → `true`;設 `…=false` → `false`;底線版 → `true`;`=true` → `true`;`=garbage` → `false`;`gnss.enable` 一律 `true` |
| E-2 | env 優先於 config.yml | ✅(新) | `rv10/ep3.sh`:檔案寫 `alfred.dataTypes.addressReservation: true`,不設 env → `true`,設 env=false → `false`;壞 YAML + env=false → `readErr=true addressReservation=false`(env 在讀檔失敗時仍然有效) |
| E-3 | 讀取時機 | ✅ | `cmd/root.go:63` `cobra.OnInitialize(initConfig)`;`:91` `AutomaticEnv()`;`openmanet.go:45` `config.New(nil)` 位在 `Start()` 裡面,所以在 initConfig 之後;`:106` 把值傳給 mgmt;`mgmt.go:122` 只在 Start 判斷一次。`config.go:277` 的 WatchConfig 只做 `c.reload()`,不會重啟 worker |
| E-4 | jshn / procd 保留帶點的鍵 | ✅ busybox 實測 | 04 上 source 真的 `procd.sh` + `jshn.sh`,把 `_procd_ubus_call` 換成 `json_dump`:`"env": { "ALFRED.DATATYPES.ADDRESSRESERVATION": "false" }`。原始碼:`jshn.sh` `_json_add_generic`(`N_` 另存原名)、`instance.c:480-481` `setenv(blobmsg_name…)`、`:960` env 不同 → changed |
| E-5 | 每一條重啟路徑都會重跑決定者 | ✅ | `rc.common`:`restart` = `stop; start`;`reload`(沒有 reload_service)= `start`;`start` = `rc_procd start_service`。procd respawn 沿用上次存下的 env。`instance_update`(`instance.c:1564-1575`)在 changed 時由 procd 自己 `instance_restart` |
| E-6 | `procd_add_reload_trigger "$CONF"` | ✅ 實際不會觸發 | `procd.sh:461` → `_procd_add_config_trigger "config.change" "/etc/openmanetd/config.yml"`,比對的是 `eq package <path>`(`:350`)。uci 的 package 名稱永遠不會是一個路徑,所以網頁改 config.yml 不會觸發 reload;就算觸發,走的也是 `start`,一樣會重跑決定者 |
| E-7 | openmanetd 其他會重啟 / 重開機的路徑 | ✅ 列舉 | `/etc/init.d/openmanetd restart`:`services.go:147`、`handlers.go:822`(兩者都經過 init,所以會重跑決定者)。plain `reboot`:`address_reservation.go:167`(被 env 關掉)、**`blos/blos.go:108`(BLOS 切換;設計沒列,見 m7)** |
| E-8 | 04 現況 | ✅ | `ubus call service list` 沒有 env;openmanetd 的 `/proc/<pid>/environ` = `HOME TERM batman_slot PATH LD_PRELOAD`;DT tryboot=`00000000`;`is-trial`=1;`/tmp/run/batman` 是 root `drwx------`;logread 有 `AddressReservationWorker initialized`(pid 5504);`dhcpconfigured=1` |
| E-9 | `is_trial` 不拿 slot lock | ✅ | `batman-slot:720-726`。所以 rc 2 不會因為 commit 持有 lock 而出現 |
| E-10 | Pi 3 的 `is-trial` 會掛載 p7 | ✅ 原始碼 | `autoboot_read`(`:254-260`):p7 沒掛 → `mount -t vfat -o ro p7` 到暫存目錄,讀完卸載。`write_autoboot_pi3`(`:308`):p7 有掛載就 `die`;讀回(`:360`)經 `/proc/mounts` 上的掛載點去讀 |
| E-11 | 網頁終端機 | ✅ 原始碼 | `config.go:174` `DefaultTerminalEnable = true`;`terminal/session.go:42-51` `pty.Start`(Setsid + Setctty);teardown 會關掉 PTY,並對 shell 的 process group 送 TERM,之後送 KILL |

---

## B. 發現

### MAJOR

**B10-M1 解除用 `restart`(stop+start)不是原子的。操作員從網頁終端機 commit 時,openmanetd 會被刪掉而不重啟,一直停到下次開機。**

- **情境**(現場):unclaimed OTA,hold 中或 trial 出問題。操作員依 #274 B-P2 的處方手動 commit,而他手上只有 openmanetd 的網頁(預設就有 root 網頁終端機,E-11),沒有 ssh。他在網頁終端機打 `batman-slot commit`,接著:
  1. commit 寫入並 sync 成功;
  2. 依 §13.8,`batman-slot` 執行 `/etc/init.d/openmanetd restart`;
  3. `stop` → `ubus call service delete`(`procd.sh:530-537`)。procd 對 openmanetd 送 SIGTERM。**service 被刪除,連同它的 trigger,包括 bat0 up 那個。**
  4. openmanetd 結束 → 終端機 session teardown 關掉 PTY → tty hangup。前景 job(`batman-slot` 和它的子程序 `rc.common`)收到 SIGHUP。`rc.common` 的 `restart` 只在 stop 那段 `trap '' TERM`,HUP 沒有任何保護。
  5. 這時 `start` 還在跑決定者(Pi 4 約 0.3 s 的 `is-trial`;Pi 3 還要掛 p7,更久),很可能來不及 `ubus call service set` 就被殺。
- **結果**:
  - openmanetd 不在 procd 裡:沒有網頁、沒有 alfred / mesh 管理、沒有位址保留;
  - bat0 trigger 也跟著 service 一起消失,所以之後也不會自己回來,要等到重開機;
  - 操作員失去唯一的介面,halow-status 寫的處理方法(`/etc/init.d/openmanetd restart`)他也沒有地方可以打。
- **證據**:
  - ✅ 原始碼:`rc.common:23-28` 的 `restart`;`procd.sh:530-537` 的 `_procd_kill` → `delete`;`session.go:42-51` 加上 teardown 的註解。
  - ⚠️ 推論:SIGHUP 落在 stop 和 start 之間。這是時序推論,我沒有在節點上做(那會改狀態)。
  - 設計對這條路徑的證明只有「stub」,stub 抓不到這件事。
- **為什麼是 MAJOR**:這是設計自己列在生命週期表裡、而且說「同一條解除路徑」的現場路徑。失敗是靜默的,恢復要重開機,而操作員在現場可能做不到。
- **修法**(都很小):
  1. 解除改用 `/etc/init.d/openmanetd start`,不要用 `restart`。`start` 只是 `ubus … set`;env 改變時由 procd 在內部 `instance_restart`(`instance.c:1564-1575`)。不會有「已刪除、還沒加回」的空窗;env 沒變時也什麼都不做。
  2. 讓它脫離呼叫者的 session:`setsid /etc/init.d/openmanetd start </dev/null >/dev/null 2>&1 &`。放在 commit 的 `sync` 之後、而且已經釋放 slot lock 之後。
  3. 解除改成**無條件**,不看旗標:`start` 本來就是冪等的。這樣旗標只剩 halow-status 診斷用途,也一併消掉 m1(TOCTOU)和 m3(旗標寫不進去 → 卡住暫停)。
- **負對照**:
  - stub:在 stop 之後對呼叫端送 SIGHUP(或用 `setsid` 開一個 pty session,commit 時把它 hang up)。舊寫法(`restart`)→ 斷言 service 不存在;新寫法 → service 存在,env 已移除。
  - 真機:E1c v4 至少加一次「從 ssh 直接 `batman-slot commit`」的解除,不經 autocommit;並且在 release 後斷言 `ubus call service list '{"name":"openmanetd"}'` 有 instance 而且沒有 env。

### MINOR

**B10-m1 決定者和 commit 之間的 TOCTOU:commit 之後仍然暫停。**
- **情境**:
  1. bat0 up 的 restart(或網頁的 restart)剛好在 commit 那一刻跑決定者,`is-trial` 得到 0;
  2. commit 完成,看旗標:決定者還沒寫,所以不重啟;
  3. 決定者寫旗標,procd 收到 env=false。
- **結果**:committed 的槽繼續暫停,直到下一次 openmanetd start。「為什麼不會卡住」那段把這種情況漏掉了。反過來也會發生:兩個並行的 `start` 最後由 procd 決定誰贏(last-writer-wins)。
- **修法**:
  - 照 M1 第 3 點,無條件 `start`;
  - 或者決定者**先**寫旗標、**再**問 `is-trial`。
- **測項**:stub 在 is-trial 之後插入 commit。

**B10-m2 Pi 3:決定者的 p7 唯讀掛載會和 autocommit 的 commit 撞在一起。**
- **情境**:每次 openmanetd start,決定者都會呼叫 `is-trial`,在 Pi 3 上就會掛載 p7(E-10)。
  - 如果剛好落在 `write_autoboot_pi3` 執行期間:可能在開頭就被 `die "p7 is mounted"`;
  - 也可能寫完之後,讀回經由決定者的掛載去讀到舊的快取,而 `die "…CHECK THE CARD"`(卡其實沒問題)。
  - autocommit 會重試(`batman-autocommit:539`),所以不致命。但這是 Pi 3 才有的新競態,而 Pi 3 沒有硬體可以驗證。
  - 另外,穩定狀態下每一台 Pi 3 只要 bat0 up 一次,就會多掛一次 p7。
- **修法**:決定者**先看 DT tryboot**,只有 `tryboot=1` 才呼叫 `is-trial`。這樣也一併處理 m4。若要在 Pi 3 上完全不掛 p7,可以改成:`tryboot=1` 而且 `$RUNDIR` 沒有 `batman-slot commit` 這次開機寫的 committed 標記 → 暫停。
- **測項**:stub 斷言 `tryboot=0` 時決定者不會呼叫 `batman-slot`。

**B10-m3 旗標 / RUNDIR 的寫法沒有規定(#280)。**
- 設計只寫「寫 `/tmp/run/batman/addr-deferred`」。
- 如果實作用 `mkdir -p`,而 S99 的決定者又比其他人先建立 RUNDIR,目錄會變成 0755。`batman_rundir`(`rundir.sh`)會判它 UNUSABLE,於是 autocommit RDBAD、永不 commit,`batman-slot` 拒絕所有 slot 寫入。這就是 #280 的那一類錯。
- **修法**:
  - 規定決定者 source `rundir.sh`,用 `batman_rundir`;
  - RUNDIR 不能用時仍然暫停(fail-closed),並記 log。照 M1,旗標只做診斷用,所以寫不進去也不會卡住。
- **測項**:stub,在 RUNDIR 不存在、或模式是 0755 時執行決定者。

**B10-m4 `is-trial` rc 0 但不是 tryboot(#133 stale fallback)時也暫停,這是多餘的,而且會關掉 IP 衝突偵測。**
- 在這種開機下,reboot 本來就會回到 `[all]`,也就是修正落點。所以暫停防的不是 trial 被無聲退回。
- 在 Pi 4 上,commit 後那次保留重開(plain reboot)有 5/10 會落在 A(`batman-slot:756-760` 的註解)。A 會進入暫停,直到自檢把它修正回來。如果修正失敗(`batman-fw-override`),A 會一直停在「worker 關閉」的狀態。
- **修法**:同 m2,只在 `tryboot=1` 時暫停。

**B10-m5 E1c v4 的「這次開機沒有 `AddressReservationWorker initialized`」需要正向錨點,否則一行都沒有也會被當成 PASS。**
- 證據來源是 logread 的環形緩衝區。04 現在有 1200 行。只看「沒有」的話,log 輪替掉、或 openmanetd 根本沒啟動 mgmt,都會被誤判成 PASS。
- **修法**:每一個 openmanetd pid 都要:
  - 有 `Alfred Client Started`(證明 mgmt 有跑,而且 log 有收進來);
  - 同一個 pid 沒有 `…initialized`;
  - `/proc/<pid>/environ` 有那個變數;
  - `ubus call service list` 有那個 env。這三者都可以唯讀讀取(E-8)。
- daily-validation tier A 的「committed 不能有 `addr-deferred`」也改成直接看 environ / ubus,不要只看旗標。只看旗標檢查的是代理物,不是實際效果。

**B10-m6 wsl.12 負對照的那條分支,沒有出口和副作用清單。**
- 預期是「B 在 HELD 的 trial 裡約 165–200 s 自己重開,回到 A」。但 E1c v2 的 `abort_to_a` 假設 B 還連得到(要在 B 上 rollback)。負對照時 B 已經自己回到 A,p5 是剛 mkfs 過、未 seed 的狀態。
- 依使用者「破壞性測試先列副作用」的規則,要寫明:
  - 怎麼偵測「已經回到 A」:A 的 boot_id 是新的,而且 `trial_rc=1`;
  - 回到 A 之後的 p5-restore 和讀回 sha;
  - hold 是否已被消耗、要不要刪;
  - `bad-slot` 要不要清(不會有,因為是 tryboot 自然退回;但要斷言);
  - 要記錄的證據:A 上前一次開機的 logread(p6 記錄器),裡面有 `Rebooting system to apply new network settings`。

**B10-m7 現場文件缺了另一條 plain reboot,而且暫停期間 IP 衝突偵測是關的。**
- `blos.go:108`:在網頁切換 BLOS 會執行 plain reboot,和網頁的「重開」一樣,會讓 trial 無聲退回。要一起寫進「hold 期間不要做」。
- 「bootstrap IP 碰撞和今天前 125 s 相同」這句話不完全對:
  - 暫停期間,worker 的衝突偵測(`address_reservation.go:55-66`)也一起關掉了;
  - hold 的 trial 是沒有上限的,碰撞會一直持續到 release。
- 對 `dhcpconfigured=1` 的還原槽,trial 內同樣失去衝突偵測(今天是有的,代價是「偵測到就重開」)。這是正確的取捨,但要照實寫出來。

**B10-m8 witness 只證明字串存在,不證明掛勾放在正確的位置。**
- `file /etc/init.d/openmanetd batman-addr-defer` 只是 grep。patch 就算套在 `service_triggers` 裡,也一樣會 PASS。
- **修法**:把 §13.8 的 rc.common 模擬,改成跑在**建出來的 image** 的 `/etc/init.d/openmanetd` 上(build-board 第 7 步解開的 rootfs,或節點上的 `/rom`)。用真的 `procd.sh` / `jshn.sh`,在 **busybox ash** 下跑(E-4 的做法),並斷言 dump 出來的 JSON。現在設計寫的是「對打過 patch 的 init」,沒有說是哪一份檔案、在哪個 shell 下跑。

---

## C. 生命週期矩陣(§13.8 之外,審查者補的)

| 路徑 | 結論 | 依據 |
|---|---|---|
| install / 新卡第一次開機 | 不變(rc 1) | E-9 + 設計 |
| start(S99) | 決定者同步執行;Pi 3 會掛 p7(m2) | E-10 |
| clean stop | 不相關(stop 不跑決定者) | rc.common |
| restart(bat0 trigger、網頁、`services.go:147`) | ✅ 都會重跑決定者 | E-5, E-7 |
| procd respawn / crash loop | ✅ 沿用上次的 env;5 次之後 procd 放棄,和今天一樣,autocommit 判 `svc openmanetd down` → 不 commit → revert | `openmanetd.init`、`batman-autocommit:452` |
| reload trigger | 實際不會觸發(E-6);就算觸發也安全 | E-6 |
| viper WatchConfig | 不會重啟 worker;env 仍然蓋過檔案 | E-2, E-3 |
| 解除:autocommit | ✅(改用 `start` 更好) | `batman-autocommit:536` |
| 解除:操作員從 ssh | 可以用,但要改成 `start` + `setsid` | M1 |
| 解除:操作員從網頁終端機 | ❌ restart 被中斷 → openmanetd 停掉 | **M1** |
| commit 半途失敗(寫入後讀回才 die) | 卡在暫停,直到下次 start;halow-status 會 WARN | m1/M1 |
| 停在 rc 2 + tryboot=1 | 暫停;autocommit UNKNOWN → 期限到就 revert,一致 | `batman-autocommit:323-330` |
| commit 後的保留重開 | Pi 4 有 5/10 落在 A → 自檢修正;A 暫停沒有壞處(m4) | `batman-slot:756-760` |
| revert | tmpfs 旗標消失,A 的 rc 1 → 正常 | — |
| 降版 / 升級 | 設計的表格成立 | — |
| 斷電(trial 中 / commit 後) | trial 中 → 回 A;commit 後 → 下次開機 rc 1 → 正常保留 | — |
| ab-selftest | trial 有 skip-once,沒有 commit;暫停到它重開為止,沒有壞處 | `ab-selftest.sh:99-108` |
| Pi 4 / Pi 3 | 機制兩板相同;Pi 3 多 m2;DT `tryboot` 在 Pi 3 是否存在:⚠️ 沒有實查(03 停用),但 autocommit 的 `real_tryboot` 已經依賴它 | — |

## D. 安全(逐 actor)
- **遠端 / 網頁使用者**:改不了 procd 的 env(E-2 證明 env 蓋過 config.yml)。§13.8 的主張成立。網頁終端機本來就是 root,不在新的攻擊面裡;但它會觸發 M1(可用性)。
- **本機非 root 程序**:`/tmp/run` 和 `/tmp/run/batman` 都是 root 所有(E-8)。決定者讀的是 DT、`/proc/cmdline`、`/boot`、p7,都是 root 的東西。Pi 3 掛載用的暫存目錄由 `batman_tmp` / `mktemp` 建立,不可預測。前提是 m3 有照 `batman_rundir` 實作。
- **被攻陷的 mesh peer**:沒有新的輸入。bat0 up 次數不是 peer 能直接控制的。
- **供應鏈 / 上游**:上游已釘住;patch 的 context 涵蓋 `procd_set_param command` 那一行,所以上游改成 shell 包裝(busybox ash 會丟掉名稱帶點的環境變數)時,patch 會套不上而失敗。仍建議加 m5 的 environ 斷言,當作執行期的哨兵。
- **我們自己的錯**:M1(restart 不是原子的)、m3(RUNDIR 權限)。
- **fail 方向**:判不出的 tryboot → 暫停,正確;解除失敗 → 停在暫停,只是延後保留,方向是安全的。M1 例外,它是可用性失敗。

## E. 負對照總評
- wsl.12 上的 E1c v4:在 **HELD** 的 trial 裡,今天的版本約 165 s 會重開 → 有鑑別力 ✅。但要補 m6 的出口。
- stub(決定者 rc 0/1/2,有無 tryboot,沒有 batman-slot;有 patch / 沒有 patch 的 init):有鑑別力,前提是照 m8 跑在真的 image init + busybox ash 上。
- **缺少**:
  - 「解除不是原子的」的負對照(M1);
  - TOCTOU(m1);
  - Pi 3 的 p7 競態(m2,至少 stub:模擬 p7 已掛載時 commit 的行為);
  - RUNDIR 權限(m3)。

## F. 編號摘要
- **B10-M1**(MAJOR)解除用 `restart` 不是原子的;操作員從網頁終端機 commit 會讓 openmanetd 停掉直到重開機 → 改用 `setsid … start`,無條件執行。
- **B10-m1** 決定者和 commit 的 TOCTOU → commit 後仍然暫停。
- **B10-m2** Pi 3:決定者的 p7 唯讀掛載和 commit 競態,而且每次 start 都掛 p7 → 先看 DT tryboot 再呼叫 is-trial。
- **B10-m3** 旗標 / RUNDIR 的建立方式沒有規定(#280),要用 `batman_rundir`。
- **B10-m4** 不是 tryboot 的 rc 0 也暫停,是多餘的,而且會關掉衝突偵測。
- **B10-m5** E1c v4 的「沒有那行 log」需要正向錨點;daily 檢查要看 environ / ubus,不要只看旗標。
- **B10-m6** wsl.12 負對照的分支缺出口和副作用清單。
- **B10-m7** 現場文件缺 BLOS 的 plain reboot;暫停期間衝突偵測是關的,hold 的 trial 沒有上限。
- **B10-m8** witness 只是 grep;rc.common 模擬要跑在 image 的 init 上、busybox ash 下。
