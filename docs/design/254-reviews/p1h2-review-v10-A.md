# #254 P1 + H2 — 第 10 輪審查(審查者 A)

**判定:APPROVE-WITH-CHANGES**(0 BLOCKER / 1 MAJOR / 10 MINOR)

- §13.8 的**機制本身成立**:env 從 init 一路到 openmanetd 的整條路,我在 jshn、procd、viper、真正的 `cmd/root.go` 路徑上都實測或對過原始碼(見「已驗證」)。在 Pi 4 上,它能關掉 trial 內的 worker,而且網頁改 config.yml 也蓋不掉。
- **但「解除」的設計有洞**(A10-M1):解除與監測都看一個代理旗標,而不是看真正的狀態;旗標的 fail 方向是錯的;決定者的 fallback 在 commit 之後同一次開機裡仍然成立;決定者和 commit 之間沒有序列化。§13.8「為什麼不會卡住」裡「唯一會延後的情況」這句話不成立。
- 依使用者規則,MAJOR 未關要先改設計,再整份重審。修法很局部(見 M1),不需要換機制。

證據檔:`scratchpad/h2/rv10a/`
- `p1.sh` / `p1.log`:jshn round-trip;
- `p2.sh` / `p2.log`:真正的 root.go initConfig 路徑;
- `feed/`、`omd/`、`procd/`:唯讀複本。

節點只做唯讀 ssh。

---

## 已驗證(✅,附原始輸出)

1. **作者的 `envprobe.sh` 我重跑了**,結果相同:
   ```
   no env:                                     addressReservation=true  gnss.enable=true
   ALFRED.DATATYPES.ADDRESSRESERVATION=false:  addressReservation=false gnss.enable=true
   ALFRED_DATATYPES_ADDRESSRESERVATION=false:  addressReservation=true
   ...=garbage:                                addressReservation=false
   ```
2. **擴充:走 openmanetd 真正的 `cmd/root.go`**。做法是 `root.go` 原檔用 sed 只拿掉 `openmanet.Start`,透過 cobra `Execute` 加 `--config`,觸發 `OnInitialize(initConfig)`;再用 `config.New(nil)`,也就是帶 `WatchConfig` 的那一版,和 `openmanet.go:45` 相同(`p2.log`):
   ```
   == env false + persist rewrite
   PROBE start: addrRes=false gnss=true
   PROBE after-persist+reload: addrRes=false gnss=false   ← PersistGNSSConfig 改寫 config.yml + watcher reload 後 env 仍生效
   == config says true, env false
   PROBE start: addrRes=false                             ← config.yml 明寫 true 也被 env 蓋過(網頁改不掉暫停)
   == env empty
   PROBE start: addrRes=true                              ← 空值被忽略(viper AllowEmptyEnv=false)
   ```
   - worker 只在 `mgmt.go:122-125` 的 Start 時判斷一次;`AlfredDataTypeAddressReserv` 的唯一消費者是 `openmanet.go:106` → worker(grep 全樹)。
   - 所以 viper 的 config watch 和 reload 都不會讓 worker 中途啟動。
3. **jshn/procd round-trip**(`p1.log`):用 build 樹的 `procd.sh` + `jshn.sh` + host `jshn`,bash 與 busybox ash 結果相同:
   ```
   "instance1": { "command": [...], "env": { "ALFRED.DATATYPES.ADDRESSRESERVATION": "false" }, "respawn": [...] }
   ```
   - procd 端:`instance.c:480-481` 依原名 `setenv`;`:960` env 不同就算 instance changed。
   - respawn 用的是同一份 `in->env`(`:865-878` 不重跑 init),所以 trial 內 openmanetd crash 後 respawn,env 仍在 ✅。
   - `instance.c:1685-1691`:`ubus call service list` 會吐出 env。這是一個**權威、可讀**的狀態,M1 會用到。
4. **04 / 02 現況**(唯讀;兩台都是 1.5.12-wsl.12):
   - `/etc/init.d/openmanetd` md5 `24bda6e7…`,與 `feeds/openmanet/openmanetd/files/openmanetd.init` 相同。所以 board patch 的基底就是現行檔案。
   - `S99batman-autocommit` 排在 `S99openmanetd` 之前。
   - `ubus service list` 目前沒有 env 欄。
   - openmanetd 的 environ 名稱是 `HOME TERM batman_slot PATH LD_PRELOAD`。
   - `/tmp/run/batman` 是 root 0700。
   - `is-trial=1`,DT tryboot=`00000000`,`dhcpconfigured=1`。
5. **其他會重啟 openmanetd 的路徑,全部經過 init**(所以都會重新判斷):
   - bat0 up trigger(init `service_triggers`);
   - 網頁存設定(`frontend/handlers.go:820-823`,`/etc/init.d/openmanetd restart`);
   - dashboard quick action(`system/services.go:147`);
   - `setup_reset.go`。
   - `procd_add_reload_trigger "$CONF"` 的參數是檔案路徑,不是 uci package 名,所以 `config.change` 永遠比對不到,是死的 trigger。即使觸發,`reload` 也會走 `start`(`rc.common:165-172`),一樣會重新判斷。
   - 沒有任何路徑會不經 init 就啟動 openmanetd(respawn 例外,而 respawn 保留 env,見上)。
6. **`is-trial` 不拿 slot lock**(`batman-slot:719-726`、`:805`),所以在 `cmd_commit`(拿著 `slot_lock`)裡呼叫 `openmanetd restart` → 決定者 → `is-trial` 不會死鎖。
   - 另外,procd 的 `procd_lock` 是 per-service 的 flock(`procd.sh:48-58`),和 slot lock 無關。
7. **#275 witness 格式**:`Batman-Witness: file <glob> <string>`(`patch-witness.sh:13-15`),設計的 witness 寫法合格。
   - `build-board.sh:101-102,167-170`:patch 沒套上 → 拒絕 build;image 裡沒有 witness 字串 → FAIL。
   - 上游改了 init → patch 套不上 → build 失敗,不會靜默失效 ✅。
8. **舊有的 fault-injection P5**(restored 槽、`dhcpconfigured=1`)在新設計下不受影響:暫停沒有作用,解除時多一次 restart 也不會重開。它的「no re-reservation」斷言(`fault-injection.sh:491-494`)仍然成立。⚠️ 這是推論。

**B-M4 是否關閉**:
- **Pi 4**:機制 ✅(上面 1–5);端對端 ⚠️ 要等 E1c v4。
- **Pi 3**:
  - init 和 patch 相同,決定者在 S99 才跑:rootfs 可寫、rundir 可用,比 §13.7 的 uci-defaults 時機可靠;
  - 但 Pi 3 的 `is-trial` 要掛 p7(`batman-slot:254-262`),這帶來 M1(b) 和 m2 的新問題;
  - ❌ 沒有硬體可測。

---

## MAJOR

### A10-M1 解除與監測只看代理旗標;旗標的 fail 方向錯;決定者的 fallback 在 commit 後同一次開機仍成立;決定者和 commit 沒有序列化 → committed 槽可能一直停在暫停狀態

§13.8 說「唯一會延後的情況:commit 之後、restart 之前 batman-slot 被殺」。實際上至少還有三條路,而且都**不會**被 `halow-status` 的 WARN 抓到,或者只會 WARN、不會自動修好。

**(a) 決定者暫停了,但旗標沒寫成。**
- 掛勾是 `batman-addr-defer && procd_set_param env …`:只要決定者 rc 0,env 就會設。
- 旗標寫在 `/tmp/run/batman`。如果 rundir 不可用(#280 的 `batman_rundir` rc 1,`batman-slot:62-66` 就有這條分支)、tmpfs 滿了,或寫入失敗,env 照樣設了,但旗標不存在。
- 接著 commit:解除的條件是「旗標存在才 restart」→ 不 restart。`halow-status` 和 tier A 都只看旗標 → **完全靜默**。
- 「旗標不存在 = 沒有暫停」是 fail-open 的方向,而這裡的 open 是「卡住」。

**(b) fallback「rc 2 + DT tryboot=1 → 暫停」,在 commit 之後的整次開機都成立。**
- DT 的 `tryboot` 在整次開機裡都不會變(這次開機就是 tryboot 開機)。
- commit 之後,同一次開機內任何一次 openmanetd start(解除時的那次 restart 本身、之後的 bat0 up、網頁 restart)只要 `is-trial` 回 rc 2,就會再暫停一次,而這個槽已經 committed。
- Pi 3 的 `autoboot_read`(`batman-slot:256`)先 `grep` p7 是否已掛載,再從那個掛載點 `cat`。另一個 reader(halow-status、watchdog 的 `real_tryboot`、別的決定者)在這兩步之間卸載 → `cat` 失敗 → `committed_fw` 空 → rc 2(`:722`)。p7 掛載失敗也是 rc 2。
- 結果:committed + 暫停。這種情況下旗標確實會寫,所以會有 WARN,但沒有任何自動修復,要等到下一次 openmanetd start。這一點 §13.8 自己也承認,而 committed 之後通常不會再重開。
- ⚠️ 這是推論:Pi 3 的競賽窗口很小,沒有實測。

**(c) 決定者和解除並行。**
- 決定者讀到 `is-trial`=0(commit 寫入之前)→ commit 寫入 → 解除檢查旗標(還不存在)→ 不 restart → 決定者寫旗標 → init 把 env 送給 procd。
- 結果:committed 槽在暫停中跑,只有 WARN。
- 觸發來源:commit 期間剛好有 openmanetd start,例如 bat0 flap、網頁 restart、`services.go:142` 的 network restart 引起 bat0 up。

**現場後果**(與第 9 輪 A-M4 相同,已有證據):
- committed 的節點停在 `10.41.254.x`,`dhcpconfigured=0`;
- `NodeDataWorker` 不廣播(`internal/mgmt/node.go:79-88`),地圖看不到它;
- 沒有 IP 衝突偵測;
- 現場可能好幾天都不會重開。

**修法**(都很局部):
1. **解除看權威狀態,不看旗標**:
   - `batman-slot commit` 成功、`st COMMITTED` 之後,若 `ubus call service list '{"name":"openmanetd"}'` 的 instance env 含 `ALFRED.DATATYPES.ADDRESSRESERVATION` → restart(`instance.c:1685-1691` 會吐出 env);
   - `halow-status`、tier A 也改看這個:committed + env 存在 → WARN/FAIL;
   - 旗標降為只用來診斷,或者乾脆拿掉。
2. **決定者知道這次開機已經 commit 過**:
   - `batman-slot commit` 在**寫完 autoboot、restart 之前**,寫 `$RUNDIR/slot-committed`(root 0600,經 `batman_rundir`);
   - 決定者看到它 → 一律不暫停,不管 `is-trial` 回什麼。
   - 這樣 (b) 就消失了;(c) 也大部分消失,因為晚到的決定者會看到標記。
3. **補一個不靠開機的對帳點**,關掉 (c) 的殘餘:
   - joinwatch 每個 tick(或 autocommit 在 commit 之後再檢查一次,但 autocommit 是一次性的,所以用 joinwatch 較好)做一件冪等的事:`is-trial`=1 **或** `slot-committed` 存在,而且 instance env 有那個鍵 → `openmanetd restart`,並記 log;
   - 時間上限就變成分鐘級(第 9 輪 A-M4 的建議,§13.8 沒有採用)。
4. **測項**(stub,`tests/prov-p1/addr-defer.sh`):
   - (a) rundir 不可寫,但決定者 rc 0;
   - (b) commit 之後 `is-trial` stub 回 2,DT tryboot=1;
   - (c) 決定者在 commit 之前讀、在解除之後才送 env。
   - 三個案例都斷言:最後 committed 時 instance 沒有 env,或者在一個 tick 內被修好。
   - 負對照是 §13.8 原版:三個案例都會卡住。
5. §13.8「為什麼不會卡住」一段改成照實寫。

---

## MINOR

**A10-m1 stale-fallback 開機(is-trial rc 0、DT tryboot=0)也會暫停,但 §13.8 沒有處理這條路(第 9 輪 B9-m5 未回應)。**
- autocommit 在這種開機下:
  - 要麼「健康就 commit、不 reboot」(`batman-autocommit:344-345`),之後解除 OK;
  - 要麼「stale fallback NOT committed」直接 exit(`:351-358`)→ 整次開機都在暫停中,而且 `halow-status` 只對 committed 發 WARN → 靜默。
- 這種開機本來就不會被 tryboot 一次性退回,沒有東西需要保護。
- 修法:rc 0 而且 `! dt_tryboot` → 不暫停,和 autocommit 的 `REVERT` 切分一致;生命週期表加一列。

**A10-m2 Pi 3:決定者會在每次 openmanetd start 時 ro 掛 p7,這和 commit 的 raw sector 寫入互相干擾。**
- `write_autoboot_pi3` 一開頭,只要 p7 有掛載就 die(`batman-slot:309`)。
- 這是 TOCTOU:如果在檢查之後、`dd` 之前,有決定者把 p7 掛上,寫完之後的讀回 `ab_section` 會經由那個已存在的掛載點讀(`:256`),可能讀到舊的 page cache → die「CHECK THE CARD」→ autocommit 重試。重試又是一次 raw p7 寫入。
- 本來就有別的 reader(halow-status、watchdog),但決定者讓並行來源多了一個,而且是每次 openmanetd start 都會發生(bat0 up、respawn 不算,因為 respawn 不跑 init)。
- ⚠️ 推論,Pi 3 沒有測。
- 修法(擇一):
  - 決定者在 Pi 3 改讀 raw sector,不掛載。可以讓 `is-trial` 在 Pi 3 用和 `write_autoboot_pi3` 相同的 `raw_read` 解析;
  - 或者決定者一律先看 M1 第 2 點的 `slot-committed` 標記,只在沒有標記時才呼叫 `is-trial`。
- 不論哪一種,都把這一項寫進 Pi 3 的生命週期列,標 ⚠️。

**A10-m3 解除在 `cmd_commit` 裡的契約沒寫清楚。**
- 要寫明:
  - 解除排在 `write_autoboot` 讀回成功、`st COMMITTED`、`echo committed` **之後**;
  - restart 的 rc **不影響** commit 的 rc。否則 autocommit 會走「commit failed → 重試」(`batman-autocommit:536-539`),在 Pi 3 上就是再寫一次 p7;
  - restart 要有時間上限(`timeout`)。
- 另外,restart 是在 `slot_lock` 和 autocommit 的 claim 之內執行的,約 5–6 s(`term_timeout 5`)。這會讓 `$COMMITTED` 晚寫、`release --wait` 晚返回。可以接受,但要寫出來。

**A10-m4 決定者沒有時間上限。**
- 它在 openmanetd init 裡同步執行:開機時的 S99,和 procd interface trigger 的 restart。
- Pi 3 的 vfat 掛載在壞卡上可能卡住 → openmanetd 永遠不啟動。這比今天更糟。
- 修法:`timeout 10 /usr/libexec/batman-addr-defer`;逾時就依 DT tryboot 決定(=1 暫停,否則不暫停)。

**A10-m5 決定者缺席時是靜默的 fail-open。**
- witness 只證明 init 有那一行。決定者在 Batman feed(batman-provision),feed 版本和 patch 版本可能不同步。
- 這時 `[ -x ]` 不成立 → B-M4 原樣回來,而沒有人知道。
- 修法:
  - §2「firmware build gate」加:rootfs 有 `/usr/libexec/batman-addr-defer`,而且 0755 root;
  - tier A 加同樣的斷言,依 P-U9 對 wsl.12 標 KNOWN(在 H2 先進 main 的期間);
  - 依 #290,這些斷言走 harness PR,產品 PR 不碰。

**A10-m6 claimed + placeholder 節點的 p5 永遠是 `dhcpconfigured=0`:每次 OTA 都換新的亂數 IP,commit 後還多一次重開。**
- 有了 §13.8,每次 OTA 都不會再競賽(✅,這是 §13.8 比 §13.7 強的地方)。但現場後果仍在:
  - p5 是 0,原因見第 9 輪 A-M3:認領發生在保留之前,或者 `--seed`,而 on-join 永遠不會發生;
  - 每次 OTA:還原出 0 → trial 暫停 → commit → 保留 → plain reboot → 新的 `10.41.<1-252>.x`;
  - 操作員記住的 IP 每次升級都會失效。
- 第 9 輪 A-MINOR-4(helper 在 committed 但 `dhcpconfigured≠1` 時回 `E_BUSY`)沒有採用。
- 修法:
  - 二擇一:採用 A-MINOR-4,或者在 `dhcpconfigured` 變成 1 的那次開機,由 config-save 把它補進 p5(只在 p5 是 0 時,而且只寫這兩個鍵);
  - 至少要寫進 §13.8 的現場影響段。

**A10-m7 使用者決定沒有記錄。**
- §13.6 標題和內文仍然寫「待使用者決定」;§1.1 沒有記錄選了哪個選項。
- §13.8 等於選了選項 1,而且是用 board patch 改上游檔案(#264 的教訓是「overlay 蓋上游不耐久」;board patch + #275 witness 是耐久的做法,這點我同意)。
- 修法:
  - §1.1 加 P-U13:日期、選了選項 1、同意以 board patch 改 openmanetd init;
  - §13.6 的「待決定」改成指向 P-U13;
  - 上游 bug(`ipConflictDetected` 永遠不會清)的回報仍然待使用者決定,寫進 §11 殘項。

**A10-m8 E1c v4 的「trial 內」斷言只靠「某一行 log 沒出現」。**
- 規則是「找不到東西不能算 PASS」。logread 是 ring buffer,也可能沒抓到 openmanetd 的 stderr。
- 修法:加上正向證據:
  - `tr '\0' '\n' < /proc/$(pidof openmanetd)/environ | grep -c '^ALFRED.DATATYPES.ADDRESSRESERVATION=false$'` = 1(只印計數);
  - `ubus call service list` 的 env 含那個鍵;
  - 這次開機的 logread 有 `Using config file`。
- 另外補兩個破壞性斷言(在 E1c 的 04 上,屬於測試本身的動作):
  - trial 內 `kill` openmanetd 讓 procd respawn,新的 pid 仍有 env;
  - trial 內 `/etc/init.d/openmanetd restart`,仍然暫停。
- release 之後要斷言 env 已經不存在。
- 負對照(wsl.12)的斷言也要用 environ:沒有那個鍵。

**A10-m9 契約自相矛盾。**
- 解除一處寫「旗標存在,而且是這次開機寫的」,契約另一處寫「內容不符 → 照樣 restart」。旗標放在 tmpfs,必然是這次開機寫的,boot_id 檢查沒有作用。
- 修法:二擇一,寫清楚。照 M1 的修法,本來就該改看 env。
- 另外要寫明:決定者經 `batman_rundir`(#280)建立檔案,不跟隨 symlink。

**A10-m10 現場影響與操作文件要補兩項。**
- (i) BLOS:trial 期間若操作員在網頁啟用 BLOS,`blos.go:155-190` 會在 `blosconfigured` 未設時設定介面,然後 plain `reboot`。這和網頁的「重開」是同一類,trial 會無聲退回。
  - `blos.enable` 在 /rom 預設是 false(04 實查),所以只有操作員主動啟用才會發生。
  - 文件「hold 期間不要按重開」改成「hold 期間不要重開,也不要啟用 BLOS」。
- (ii) 每次 commit 都會多一次 openmanetd restart:對還原槽(`dhcpconfigured=1`)而言是沒有必要的,而且會讓 PTT、GNSS、alfred 短暫中斷幾秒。這是可以接受的代價,因為還要保留衝突偵測,但要寫進現場影響段。

---

## 生命週期矩陣:我要求補上或修正的列

| 路徑 | §13.8 的寫法 | 實際情況 / 要求 |
|---|---|---|
| stale-fallback(rc 0、tryboot 0) | 沒有列 | 暫停,可能整次開機無聲卡住 → m1 |
| rundir 不可用 | 沒有列 | env 設了但沒有旗標 → M1(a) |
| commit 之後同一次開機內有 openmanetd start,而且 `is-trial` 回 2(Pi 3) | 沒有列 | 再次暫停 → M1(b) |
| commit 期間有 openmanetd start | 沒有列 | 競賽 → M1(c) |
| trial 內 respawn | 沒有列 | ✅ 保留 env(`instance.c:865-878`);E1c 要測 → m8 |
| SKIP-ONCE(ab-selftest)trial | 沒有列 | 會暫停;ab-selftest 自己 commit 時會解除。bench 節點 `dhcpconfigured=1`,所以不會重開。要寫一列 |
| 決定者卡住 | 沒有列 | openmanetd 不啟動 → m4 |
| feed 和 patch 不同步 | 寫成「不暫停」 | 靜默 → m5 |
| 降版 OTA 到 wsl.12 | 寫成「和今天相同」 | ✅ 照實寫了;仍有競賽,要寫進現場影響段 |
| Pi 3 | 寫成「同一個 patch」 | ⚠️ 有 p7 掛載的互相干擾 → m2;沒有硬體 |

## 安全(逐 actor)

- **遠端或網頁使用者**:
  - 可以改 config.yml,但 env 會蓋過它(✅ 實測:config 寫 true,env 為 false → false);
  - 可以 restart openmanetd,但 restart 會重新判斷,仍然暫停;
  - 可以重開,或啟用 BLOS 讓節點重開 → trial 退回。這是既有能力,要寫進文件(m10)。
  - 沒有新增攻擊面。
- **本機非特權程序**:
  - 旗標放在 `/tmp/run/batman`(root 0700,✅ 04 實查);
  - DT 唯讀;
  - `is-trial` 的暫存掛載點走 `tmpd` → `batman_tmp`,失敗時退回不可預測的 `mktemp`;
  - env 只有 procd 設得了。
  - 沒有找到可以利用的路徑。
- **被攻破的元件**:能呼叫 `/etc/init.d/openmanetd` 的,本來就已經是 root。
- **實體取得**:改 rootfs 就什麼都能改,在既有的威脅模型內。
- **供應鏈**:上游 init 改了,patch 會套不上,build 失敗 ✅。
- **我們自己的失誤**:feed 和 patch 不同步 → m5;fail 方向 → M1。
- **子程序繼承 env**:openmanetd 的子程序(例如 `reboot`、uci、init 腳本)都會繼承 `ALFRED.…=false`。目前沒有任何東西會讀它,所以無害,但要寫一句。

## 沒做 / 部分 / 推論

- ❌ 沒有在節點上做任何寫入、重啟或改狀態(依指示)。
- ⚠️ M1(b)、(c) 和 m2 是讀原始碼推得的競賽,沒有實測;Pi 3 全部沒有實測(03 停用)。
- ⚠️ 端對端效果(節點上這次開機沒有出現 worker initialized)要等 E1c v4 在 rc 上證明。
