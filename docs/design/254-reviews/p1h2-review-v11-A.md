# #254 P1 + H2 — 第 11 輪審查(審查者 A)

**判定:APPROVE-WITH-CHANGES**(0 BLOCKER / 2 MAJOR / 8 MINOR)

- **A10-M1 已關**(解除看權威狀態 + `slot-committed` 序列化 + joinwatch 對帳),**B10-M1 已關**(`setsid … start` 取代 `restart`)。兩者的機制我都對到 procd 原始碼,見 §1。
- 新修訂帶進兩個新問題,都在 §13.8.1 新加的零件上:(M1)決定者的「10 s 逾時 kill」在 Pi 3 會把 p7 留在掛載狀態,之後這次開機再也 commit 不了;(M2)對帳用的 detached `start` 沒有單例/上限,而 procd 的 per-service flock 放在人人可寫的 `/var/lock`、任何本機使用者都能永久持有 → joinwatch 每 15 s 多堆一個卡住的程序。
- 兩個修法都很局部,不用換機制。依使用者規則,MAJOR 開著就要改設計再整份重審。

證據檔:`scratchpad/h2/rv10a/`(第 10 輪的唯讀複本與 p1/p2 log 沿用)+ 本輪 `rv10a/p3-flock.sh`、`scratchpad/h2/rv11a-flock.log`。節點 02/04 只做唯讀 ssh(wsl.12)。

---

## 1. 已驗證(✅,附來源或輸出)

### 1.1 `/etc/init.d/openmanetd start` 對已註冊 service 的語意(使用者點名要追的)

全部來自 build 樹的 procd `c59f2d80`:

| 步驤 | 證據 |
|---|---|
| `start` = `rc_procd start_service` → `procd_open_service … procd_close_service "set"` → `ubus call service set` | `rc.common:139-152`;`procd.sh:99-109` |
| procd 端 `service_handle_set`:已存在的 service 走 `service_update(s, tb, add=false, init=false)`;不存在就 `service_alloc` + `service_update(init=true)`,`autostart` 預設 true → instance 直接啟動 | `service.c:418-453`、`:161-164`、`:86-88` |
| `service_update`:`vlist_update` → `service_instance_add` → `vlist_flush`。instance 樹是 `no_delete`,同名 instance 走 `update_only` → `service_instance_update(in_o, in_n)` → `instance_update(in_o, in_n)`;`s->deleted=false` | `service.c:182-196`;libubox `vlist.c:44-58` |
| `instance_update`:`changed = instance_config_changed()`;**running 且不在 stop 中**:changed → `instance_restart`(SIGTERM,`halt=restart=true`,term_timeout 後 SIGKILL),否則什麼都不做,config 搬過來。env 不同即 changed | `instance.c:1564-1575`、`:940-960`、`:904-918` |
| **mid-stop**(`stop` 剛送 SIGTERM、程序還沒退):`stopping=in->halt` 為 true → `instance_config_move` + `instance_start`;`instance_start` 看到 `proc.pending && halt` → 只設 `restart=true` 回去;程序退出時 `instance_exit` 走 `halt && restart` → `instance_start`。**不會丟失,也不會留下已刪除的 service**:`service_stopped` 只在 `s->deleted && instances 空` 時真的刪,而 `set` 已把 `deleted` 清回 false | `instance.c:1568-1570`、`:636-640`、`:857-861`、`:838-888`;`service.c:1063-1077` |
| **未註冊**(例如之前被 `stop` 刪乾淨):`service_alloc` → `service_update(init=true)` → autostart → `instance_start`;trigger 也一起重掛 | `service.c:445-453`、`:166-173` |
| respawn 沿用 `in->env`;`instance_restart` 不清 `respawn` | `instance.c:863-878`、`:904-918` |

結論:§13.8.1 第 3 點「env 有變就在內部原子地重啟,沒變就什麼都不做」**成立**;mid-stop 與未註冊兩種狀態也都收斂到「在跑、帶新定義」。**B10-M1 關閉**(前提:真的是 `start`,而且 detached;見 §1.3)。

### 1.2 init 腳本之間的序列化(A10-M1(c) 的關鍵)

- `procd.sh` 在被 source 時就執行 `_procd_wrapper` → `procd_lock`(`procd.sh:70-76`、`:685`),也就是**整支 `/etc/init.d/openmanetd <action>` 從 source 到結束都持有 `/var/lock/procd_openmanetd.lock` 的 flock**(`procd.sh:48-58`)。決定者在 `start_service` 裡執行,所以**兩個 start 不會交錯**:commit 寫完 `slot-committed` 之後才送出的 `start`,一定排在任何「看到舊狀態的決定者」那次 `set` 之後,而它自己的決定者一定看到 `slot-committed`。
- `restart` 在同一個 shell 裡做 stop+start,鎖貫穿兩段(`rc.common:23-28`)。
- 因此 A10-M1(c) 的殘餘只剩「commit 的 detached `start` 自己失敗」,由 joinwatch 一個 tick(15 s,joinwatch init 預設 `poll 15`)內補上。**A10-M1 關閉**:(a) 由「不看旗標、無條件 start、ubus env 為權威」關閉;(b) 由 `slot-committed` 先於 `is-trial` 關閉;(c) 由 flock 序列化 + 對帳關閉。

### 1.3 `setsid` 與 detached

- 04/02 都有 `/usr/bin/setsid`(busybox)與 `flock`;**沒有** `timeout`、`nohup`(✅ 04/02 實查;設計 §13.8.1 說的沒有 `timeout` 正確)。
- ash 非互動 shell 的 `&` 子程序不是 process-group leader,busybox `setsid` 直接成功、新 session、無 controlling tty → 網頁 PTY hangup 的 SIGHUP 打不到它。⚠️ 推論(沒在節點上做)。

### 1.4 節點現況(唯讀)

- 04 `ubus call service list '{"name":"openmanetd"}'`:instance1 running、`term_timeout 5`、`respawn 3600/5/5`、**沒有 env 欄**;02 相同。DT `tryboot=00000000`;`/proc/device-tree/chosen/bootloader/` 有 `tryboot`。
- `/var -> tmp`,`/var/lock` 是 **`drwxrwxrwt`(1777)**;`/var/lock/procd_openmanetd.lock` 是 root `-rw-r--r--`。節點上有非 root 程序在跑(uid 999 ×18、1000 ×4、dnsmasq、ntp、nobody、ubus、logd、network)。
- `/tmp/run/batman` root `drwx------`。
- feed 現況(`/home/yello/Batman-p1` @6e3a8c1):`usr/libexec/` 還不存在、`patches/` 沒有 0014(設計尚未實作,符合預期);`cmd_commit`(`batman-slot:729-738`)目前只到 `echo committed`,沒有任何 release;`is_trial`(`:720-726`)不拿 slot lock;`autoboot_read` 在 Pi 3 會 mount/umount p7(`:254-262`);`write_autoboot_pi3` 一開頭 `grep -q "^$P7 " /proc/mounts && die`(`:309`);EXIT trap 只清 MBR cache / busy / lock(`:157`)。
- Pi 3 DT `tryboot` 存在且忠實:`docs/design/209-ab-on-pi3.md:24`(E0 實機)。所以決定者第 1 步在兩板都有東西可讀。

### 1.5 flock 可被唯讀開啟者持有(M2 的前提)

`rv11a-flock.log`(WSL,非 root):
```
holder: LOCK_EX taken on read-only fd by uid 1000
second flock: BLOCKED (EWOULDBLOCK) -> a read-only opener holds the lock
```
⚠️ 部分:測試檔是同一 uid 擁有(WSL 無 sudo)。flock(2) 只要求檔案能 open,不看擁有者;節點上該檔是 0644,任何 uid 都能 `open(O_RDONLY)`。沒有在節點上試(會阻斷 openmanetd 的 init,屬改狀態)。

---

## 2. MAJOR

### A11-M1 決定者的「10 s 逾時 kill」會把 Pi 3 的 p7 留在掛載狀態 → 這次開機之後每次 commit 都 die → deadline revert,OTA 失敗

- **情境**(Pi 3,fresh 槽 trial):openmanetd start(S99 或 bat0 up)→ 決定者:`tryboot=1`、無 `slot-committed` → 背景跑 `batman-slot is-trial` → `autoboot_read` 在 Pi 3 `mount -t vfat -o ro p7 $m` → 慢卡/壞卡讓 `cat` 或 mount 拖過 10 s → 決定者 **kill** 子程序。
  - kill 落在 `mount` 成功與 `umount` 之間:p7 **留在掛載狀態**(`batman-slot` 的 EXIT trap 不 umount,`:157`);掛載點是 RUNDIR 裡的 `tmpd` 目錄,也不會被清。
  - 之後 autocommit 健康 → `batman-slot commit` → `write_autoboot_pi3` 第一行 `die "p7 is mounted"`(`:309`)→ autocommit「commit failed rc=1 — retrying」(`batman-autocommit:539`)**每個 poll 都一樣** → 到 deadline → watchdog revert。trial 被退回,`bad-slot` 記上。操作員手動 commit 也同樣 die。
  - 若是 `mount` 本身卡在 D state,kill 根本無效,決定者的「10 s 上限」也不成立。
- **為什麼是新問題**:第 10 輪 A10-m4 只要求「有時間上限」;§13.8.1 選的實作是 kill,而被 kill 的程式持有一個沒有人會收的資源。這條路在生命週期表裡沒有(Pi 3 列只寫「同一個 patch」)。
- **證據**:`batman-slot:254-262`(mount/cat/umount 沒有 trap)、`:157`(EXIT trap 內容)、`:309`、`batman-autocommit:536-539`。⚠️ 推論,03 停用無法實測;Pi 4 不受影響(`autoboot_read` 讀 `/boot`)。
- **修法**:
  1. 逾時時**不要 kill**:決定者只停止等待、回「暫停」(fail-closed 已經是這個方向),讓子程序自己跑完 umount;或者 kill 之後由決定者檢查 `/proc/mounts` 有沒有 `$P7` 掛在 RUNDIR 下的 `batfw.ro.*` 並 umount+rmdir(這條要寫清楚擁有權:掛載是 `is-trial` 建的、只有這種逾時路徑才由決定者收)。我建議前者,簡單且沒有第二個寫入者。
  2. 把這一列加進生命週期表(Pi 3 / 決定者逾時),並加 stub:`is-trial` stub 在「mount 之後」睡 30 s,斷言決定者回來後 `/proc/mounts` 乾淨、之後的 `commit` stub 不會 die。負對照:v5.1 現文的 kill 版會留下掛載。
  3. 順帶:逾時用的 rc 檔與輪詢必須走 `batman_tmp`(#280),RUNDIR 不可用時決定者仍要能回答(這時只能依 DT:`tryboot=1` → 暫停)。設計沒寫。

### A11-M2 對帳的 detached `start` 沒有單例、沒有上限;procd 的 per-service 鎖在人人可寫的 `/var/lock`,任何本機非 root 程序都能永久持有 → joinwatch 每 15 s 再堆一個卡住的 `start`

- **情境**:
  - 本機非 root 程序(節點上就有 uid 999/1000/nobody/dnsmasq 等在跑;或逃出容器的 tenant)`open("/var/lock/procd_openmanetd.lock", O_RDONLY)` + `flock(LOCK_EX)`,一直持有。這是合法操作:檔案 0644、目錄 1777(§1.4、§1.5)。
  - 之後所有 `/etc/init.d/openmanetd *` 在 `procd_lock` 卡住(`procd.sh:48-58` 第二個 `flock 1000` 沒有 `-n`,也沒有逾時)。這一點是 OpenWrt 既有面,**不是本設計新開的**。
  - 新加的部分:§13.8.1 第 4 點讓 joinwatch **每個 tick** 在「不該暫停但 env 還在」時送出 detached `start`。commit 後若鎖被持有,第一支 `start` 卡住、env 永遠清不掉 → 條件每 tick 都成立 → 每 15 s 多一支卡住的 `sh /etc/init.d/openmanetd start`(每支約 1 MB RSS 的 ash + jshn),Pi 3 512 MB,一天 5760 支。
  - 同一條路也會讓 §13.8.1 第 3 點 commit 的 detached `start` 永遠不回,雖然 commit rc 不受影響(設計有寫),但沒有任何上限或告警。
- **為什麼是 MAJOR**:規則要求逐 actor 看「本機非特權程序」;這是可用性攻擊,觸發只需一個 open+flock,後果是記憶體被吃光(Pi 3 本來就是 OOM 邊緣,`209-ab-on-pi3.md`)。沒有攻擊者時也會發生在 `ubusd` 無回應、或 openmanetd SIGTERM 後 5 s 才被 SIGKILL 的期間疊兩個 tick(較輕)。
- **證據**:`procd.sh:48-58`;04 `ls -ld /var/lock` = 1777、鎖檔 0644;`rv11a-flock.log`(⚠️ 同 uid 示範);joinwatch init `poll 15`。
- **修法**:
  1. joinwatch 的對帳**單例**:記下自己送出的 `start` 的 pid(RUNDIR,root 0700),上一支還活著就不送、只 WARN;活著超過 N(例如 60 s)→ 記 `HUNG` 並通知(§7.4),不要 kill(kill 一支等 flock 的 init 也救不了鎖)。
  2. commit 的 detached `start` 也記 pid 到 RUNDIR,`halow-status` 看到它還在而且 > 60 s → WARN「openmanetd init 卡住(鎖被持有?)」,附診斷指令(busybox 有沒有 `fuser`/`lsof` 要查)。
  3. 既有面(`/var/lock` 可被非 root 鎖)**不在本單修**,但要寫進 §8 安全段並開殘項(#280 一類):procd 的 `procd_lock` 是上游行為,修法得是 board patch 或 `/var/lock` 權限。
  4. stub:用 flock 持住鎖檔,跑 joinwatch 對帳 5 個 tick,斷言只有一支 `start` 在、有 WARN;負對照是 §13.8.1 現文(5 支)。

---

## 3. MINOR

**A11-m1 `batman-slot rollback` 不刪 `slot-committed`。**
- 操作員同一次開機先 `commit` 再 `rollback`(或 autocommit commit 後操作員 rollback):running slot 又變成「非 committed」,但 `slot-committed` 還在 → 決定者/對帳都認為「不該暫停」→ worker 可能 plain `reboot`。tryboot 已消耗,reboot 落在 `[all]` = 另一槽,正好是 rollback 想去的地方,所以**後果無害**,但狀態語意錯了,而且 halow-status 會對一個其實是 trial 的槽說 OK。
- 修:`cmd_rollback` 成功後 `rm -f $RUNDIR/slot-committed`;契約寫明「`slot-committed` = 這次開機最後一次成功的 slot 寫入是 commit」。stub 一條。

**A11-m2 對帳只有一個方向。**
- 「不該暫停但有 env → 修」有了;「**應該**暫停(tryboot=1、無 `slot-committed`)但 env 不在」沒有人看。這就是決定者缺席/非 0 退出/patch 沒套上在**執行期**的樣子,只靠 build-gate 與 tier A witness(離線)。
- 修:halow-status 加 WARN(不自動修,因為自動修會在真的 committed-but-unknown 時把 worker 關掉);E1c v4 的 trial 內斷言已經涵蓋正向,OK。

**A11-m3 決定者的 rc 檔/輪詢、`ubus call` 的失敗模式沒有規定。**
- rc 檔要在 RUNDIR(`batman_tmp`),不是 `/tmp`(#280 D1);RUNDIR 不可用 → 依 DT 回答(見 M1 第 3 點)。
- `ubus call service list` 在對帳與 halow-status 裡沒有逾時;ubusd 卡住時 joinwatch 整個 tick 卡住(joinwatch 還負責 save-on-join)。busybox 沒有 `timeout`;可用與決定者相同的背景+輪詢,或接受並寫明。
- jsonfilter 的路徑要寫死:`@.openmanetd.instances.instance1.env["ALFRED.DATATYPES.ADDRESSRESERVATION"]`(鍵名帶點,要用括號形式)。stub 用 04 的真實 `service list` 輸出加上 env 當 fixture。

**A11-m4 Pi 3:trial 期間決定者的 p7 ro 掛載仍會和 `write_autoboot_pi3` 互撞(A10-m2 的殘餘)。**
- `slot-committed` 只保護 commit **之後**;commit **當下**(bat0 flap 讓 openmanetd 同時 start)決定者仍會 mount p7 → `write_autoboot_pi3` die「p7 is mounted」→ autocommit 下個 poll 重試。有重試所以不致命;但要寫進 Pi 3 生命週期列並標 ⚠️,而且 M1 修好之後這裡才真的只是「重試一次」。

**A11-m5 detached `start` 繼承呼叫者的環境。**
- 操作員 shell 裡的 `BATMAN_FAULT_INJECT=soc-unknown` / `BATMAN_ALLOW_*`(給 `batman-slot` 用的測試/覆寫變數,`batman-slot:69-74`)會一路傳到決定者的 `is-trial` → rc 2 → 暫停。只有 root 能設,所以不是安全問題,但會讓 E1c/fault-injection 的結果不可解釋。
- 修:`env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin setsid /etc/init.d/openmanetd start …`(要確認 busybox `env -i`),並在 stub 斷言決定者看不到 `BATMAN_*`。

**A11-m6 §13.8.1 第 3 點的 procd 語意要把 mid-stop / 未註冊 / term_timeout 寫進依賴證據。**
- 現文只引 `instance.c:1564-1575`。我追到的三條(§1.1)都成立,但設計要寫出來,連同「SIGTERM 後 5 s SIGKILL(`term_timeout 5`,04 實查)→ openmanetd 若不理 SIGTERM,release 會多 5 s」。E1c v4 要記 release 時 openmanetd 的退出方式(logread `pid … not stopped on SIGTERM` 有沒有出現)。

**A11-m7 stale-fallback 開機(DT `tryboot≠1`、is-trial=0)下 halow-status 的文案。**
- 對帳條件 1 會在這種開機 strip env,正確(A10-m1 已接受);但 halow-status 在那種開機會對「is-trial=0 而且不暫停」的狀態說 OK。文案要區分「committed」與「stale fallback, not committed」。

**A11-m8 §13.8 舊文與 §13.8.1 修訂並存,讀者會讀到兩套契約。**
- §13.8 元件 1/3、契約、「為什麼不會卡住」仍是舊版(旗標 + restart)。§13.8.1 說「取代」,但生命週期表沒有重寫(例如「commit 後、restart 前當機」一列現在應寫成「下一個 tick 對帳」)。實作前把 §13.8 改成最終版,或在每個被取代的段落開頭標「作廢,見 §13.8.1」(像 §13.7 那樣)。

---

## 4. 生命週期矩陣:本輪要求補上或修正的列

| 路徑 | §13.8.1 寫法 | 實際 / 要求 |
|---|---|---|
| Pi 3,決定者逾時 kill `is-trial` | 沒有 | p7 留在掛載 → 之後 commit 全 die → revert → **M1** |
| procd 鎖被持有(本機非 root,或 ubusd 無回應) | 沒有 | detached `start` 永不回;joinwatch 每 tick 堆一支 → **M2** |
| commit → rollback 同一次開機 | 沒有 | `slot-committed` 殘留 → m1 |
| 決定者缺席 / 非 0,trial 中 | 只有 build-gate / tier A | 執行期沒人看 → m2 |
| RUNDIR 不可用時的決定者 | 沒有 | 要能只依 DT 回答 → M1(3)/m3 |
| mid-stop 時收到 `start` | 沒有 | ✅ 收斂為 restart(§1.1),寫進證據 → m6 |
| 未註冊時收到 `start` | 沒有 | ✅ 建立並啟動(§1.1)→ m6 |
| commit 當下的 bat0 flap(Pi 3) | 沒有 | `write_autoboot_pi3` die 一次、重試 → m4 |
| commit 後 detached `start` 失敗 | 「rc 不影響 commit」 | ✅ joinwatch 一 tick 內修;但要有單例與 WARN → M2 |
| 網頁 `restart` 與 commit 的 `start` 同時 | 沒有 | ✅ flock 序列化(§1.2),結果一致;寫一列 |
| 降版到 wsl.12 / 升級 / 斷電 / revert | 表格成立 | ✅ 無異議(tmpfs 旗標、舊 image 無掛勾) |
| Pi 4 / Pi 3 | 「同一個 patch」 | Pi 3 多 M1、m4;❌ 無硬體 |

## 5. 安全(逐 actor,只寫有變的)

- **本機非特權程序**:新發現 M2(flock on `/var/lock`)。`slot-committed`、rc 檔、pid 檔都要在 RUNDIR(root 0700),否則 #280 那一類問題重演。
- **網頁使用者**:B10-M1 關了,網頁終端機 commit 不再殺掉 openmanetd;網頁 `restart` 現在和 commit 的 `start` 經 flock 序列化,結果一致。
- **被攻陷的 openmanetd / tenant**:能呼叫 init 的本來就是 root;新 env 變數對子程序無害(無人讀)。
- **我們自己的錯**:M1(kill 持資源的程式)、m5(環境洩入)。
- **fail 方向**:判不出 → 暫停(安全);鎖被持有 → 暫停且堆程序(**不安全**,M2)。

## 6. 負對照總評

設計列的 stub 與 E1c v4 斷言(含 wsl.12 負對照、ssh 直接 commit)有鑑別力。缺:M1(逾時後掛載殘留)、M2(鎖被持有時的單例)、m1(rollback)、m5(env 洩入)四條的負對照。

## 7. 沒做 / 部分 / 推論

- ❌ 節點上零寫入、零重啟(依指示);沒有在節點上持鎖或跑決定者。
- ⚠️ §1.3 setsid 行為、M1 的 Pi 3 時序、M2 的「非 root 可 open 鎖檔」(WSL 示範是同 uid)都是推論或部分示範。
- ⚠️ 端對端(trial 內 worker 沒啟動、release 後恰一次保留)仍要等 rc 上的 E1c v4。

## 8. 編號摘要

- **A11-M1**(MAJOR)決定者 10 s 逾時 **kill** `is-trial` 會在 Pi 3 留下 p7 掛載 → 這次開機之後每次 commit 都 die → deadline revert。改成逾時不 kill(或由決定者收掛載),加生命週期列與 stub。
- **A11-M2**(MAJOR)對帳的 detached `start` 無單例/無上限;procd per-service flock 在 1777 的 `/var/lock`、任何本機程序可持有 → joinwatch 每 15 s 堆一支。加單例 + WARN;既有面寫進 §8 並開殘項。
- A11-m1 `rollback` 不刪 `slot-committed`。
- A11-m2 對帳只修「多暫停」,不報「該暫停卻沒暫停」。
- A11-m3 rc 檔位置、RUNDIR 不可用、`ubus call` 逾時、jsonfilter 路徑未規定。
- A11-m4 Pi 3 commit 當下仍與決定者的 p7 掛載互撞(有重試)。
- A11-m5 detached `start` 繼承呼叫者 `BATMAN_*` 環境。
- A11-m6 把 mid-stop / 未註冊 / term_timeout 的 procd 語意寫進依賴證據。
- A11-m7 stale-fallback 開機 halow-status 文案要區分。
- A11-m8 §13.8 舊文未標作廢,與 §13.8.1 並存。
