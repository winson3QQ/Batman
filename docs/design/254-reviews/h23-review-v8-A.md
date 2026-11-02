# h23 設計審查 v8(§17 misc 變體)— 審查者 A

- 對象:`docs/design/254-h23-harness.md` @ 46819e6(harness/254-h23),全文 §0–§17,重點 §17 與它依賴的 §3 / §4.3 / §4.5 / §5 / §6.2 / §7.2。
- 原始碼:rc 樹 `/home/yello/Batman-rc` @ d0643d5(P1b 1f82e36 + harness b6d562a)。
- 方法:逐行讀 `batman-autocommit`、`platform-ab.sh`、`batman-slot`(apply / precheck / rollback gate)、`joinwatch`、`99zz-batman-prov-state`、`98-batman-sysupgrade`、`batman-prov-lock`、`prov-lock.sh`、`prov-base-254.sh`、`chain1-254.sh` 8.7;在 `/home/yello` 下的拋棄式沙箱實跑 dry-run watchdog(已清除)。無節點存取。

## 結論

**REJECT(§17)**:1 BLOCKER / 3 MAJOR / 9 MINOR。§0–§16 在本輪沒有新的 BLOCKER / MAJOR(只就 §17 依賴的部分複查)。BLOCKER 與 MAJOR 都只在 §17 的局部,改法明確,改完後需要再審一輪 §17(連同它對 §3 / §5 / §7.2 的增列)。

---

## BLOCKER

### B1. L51 的 bind 對象錯了:sysupgrade 與 procd 根本不讀 `/usr/lib/batman/platform-ab.sh`
- **情境**:§17.2 把 `misc-L51` bind 在 `/usr/lib/batman/platform-ab.sh`。但 sysupgrade 第 1 段、procd 的 `validate_firmware_image`、第 2 段都只 `include /lib/upgrade`,讀的是 `/lib/upgrade/platform.sh`。這個檔是 `98-batman-sysupgrade` 在每個新 overlay 第一次開機時 **複製**過去的(overlay upper 裡的一份副本),之後就跟 `/usr/lib/batman/platform-ab.sh` 沒有關係;`RAMFS_COPY_DATA` 也沒列 platform-ab.sh。所以 bind 對 `_ab_arm_mesh` 完全看不到,負對照永遠寫 `m=joined`。這個單位不可能 PASS;如果 harness 只看結果、不看見證,它也永遠沒有鑑別力。
- **證據**:✅ `platform-ab.sh:2-5`(「installed over the stock /lib/upgrade/platform.sh by 98-batman-sysupgrade (overlay copy)」)、`:38-40`(RAMFS_COPY_* 不含 platform-ab.sh)、`:62`(「sourced by every `include /lib/upgrade`」);✅ `98-batman-sysupgrade:7-11`(`cp -f /usr/lib/batman/platform-ab.sh /lib/upgrade/platform.sh`);✅ `feed/batman-provision/Makefile:131-133`。⚠️ 第 2 段 `switch_to_ramfs` 會把 `/lib/upgrade/*.sh` 的**內容**複製進 ramfs(上游 stage2,依記憶推論,未在本機原始碼核對:firmware 樹正在 build,依指示不碰)。
- **修法**:
  1. bind 對象改成 `/lib/upgrade/platform.sh`,來源 = 變體 payload 的 `usr/lib/batman/platform-ab.sh`。
  2. bind 前斷言 `cmp /lib/upgrade/platform.sh /usr/lib/batman/platform-ab.sh`,證明 overlay 副本就是目前版本(不是別的單位留下的舊副本)。
  3. bind 後在 `otalog S1 ARMED-MESH` 行(或新增的 otalog 行)裡看到見證字串,才算 mutant 生效。
  4. 文件寫明:mutant 內容也會被複製進第 2 段 ramfs。兩邊只差 `_ab_arm_mesh`,所以無害。
  5. P9 / deadman 的 bind 殘留檢查加上這個路徑(見 m5)。

## MAJOR

### M1. committed 槽上的 dry-run 會自己起 watchdog,刪掉真的 p6 `ota-armed.mesh`,並在真的 run dir 留下 `autocommit.wd` / `autocommit.decided`
- **情境**:
  - 加上 `AUTOCOMMIT_FORCE_TRIAL=1` 後,`real_tryboot` 回真(`:69`),所以 `REVERT=1`(`:351`),dry-run 用 `( revert_watchdog ) &` 起自己的 watchdog(`:432`)。
  - committed A 上,真的 autocommit 開機時已在 `:326` 結束,沒有建 `$RUNDIR/autocommit.wd`。所以 dry-run 的 watchdog 會搶到 `mkdir autocommit.wd`(`:199`)。這兩個名字都沒有 dry 版本:`autocommit.wd` 寫死在 `:199`,`DECIDED` 定義在 `:45`。
  - 到了期限,watchdog 先 `claim` → `mkdir autocommit.decided`(`:84,211`),接著 **`rm -f "$ST/ota-armed.mesh"`(`:237`)——這一行在 `DRY` 檢查(`:240`)之前**。它也把 `TRIAL-REVERTED slot A …` 寫進 syslog 和 kmsg(`:238`)。
- **什麼時候發生**:dry-run 的 main 在期限前沒有決定 COMMIT 就會發生:未入網 / 不健康 / canary 失敗 / held(04 member 在測試網、沒有鄰居時一定是這樣)。另一種情況是 harness 只 kill main 的 pid(chain1 8.7 的寫法 `kill $p`,`chain1-254.sh:347`):watchdog 子殼不會跟著死,照樣在期限動手。
- **後果**:
  - (a) 前一臂的 watchdog 在下一臂進行中刪掉 harness 剛寫的 `ota-armed.mesh`。L43 對照臂會變成 `no usable` → 假 FAIL;L43 負對照會變成 `required: 1` → 誤判「mutant 無效」。
  - (b) committed 開機的 syslog 出現 `TRIAL-REVERTED`。`fault-injection.sh:246,277,342,408,441` 這類 grep `logread` 的工具會看到它。
  - (c) §6.2 (9) 不受影響:它在真 trial 內跑,真的 `autocommit.wd` 已經存在,dry-run watchdog 在 `:199` 就退出了。這也是 chain1 8.7 從來沒有暴露這個問題的原因。
- **證據**:✅ 沙箱實跑(把路徑改到沙箱,`AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AC_DEADLINE=0 AC_SLOT=A batman-autocommit watchdog`):
  ```
  before: ota-armed.mesh | run:
  batman-autocommit: TRIAL-REVERTED slot A after 2522s: unhealthy
  DRYRUN decision: REVERT (reboot to the committed slot) — reason: unhealthy
  after: state=[] run=[autocommit.decided
  autocommit.wd]
  ```
  ✅ 原始碼行號如上。
- **修法**(harness 端,P1b 不必改):
  1. 每臂用 `setsid` 起 dry-run,拿到決定行後 `kill -- -<pgid>` 殺整個 group。
  2. 每臂之前記錄、之後斷言:`ota-armed.mesh` 的內容沒變;`$RUNDIR/autocommit.wd` / `autocommit.decided` 沒有新建。若是本臂建的就刪掉,並記一行。
  3. `AUTOCOMMIT_TIMEOUT` 設得比一臂長很多(例如 uptime + 900),讓 watchdog 在 kill 之前絕不會到期。
  4. 產品缺陷(dry-run 宣稱「never commits or reboots」,卻刪 p6 狀態、用到真名的 claim)寫進 #254 checklist:`:237` 應受 `DRY` 保護,`wd` / `DECIDED` 應有 dry 版名字。
  5. §7.2 為 §17 加一列。

### M2. member 前置靠單位順序不成立;L51 負對照在 back_to_a 之後沒有鑑別力
- **情境 1**:§17.3 說「L42 / L51 需要 04 = member(放在 `prov-netjoin-254` 之後)」。但每個單位的 `pr_end` 都會 `pr_restore` 回 S0(§4.3 步驟 2;`prov-netjoin-254` 的型 = `— / A / F`),member 狀態不會留到下一個單位。所以 `prov-misc` 必須自己 claim + `net-apply --first`(首版要 owner-op,F38),而 §17.3 / §17.4 都沒有列這些步驟和成本。
- **情境 2(L51)**:
  - 正向臂在「本次開機入過網」的 A 開機做,而且必須**不**照 §4.3 的通則在 net-apply 後 `reboot committed`。§17 沒寫這個例外。
  - 正向臂 `back_to_a` 之後 04 是新的 A 開機,member 在測試網(provgen 值、02 不在),本次開機不會入網。結果:`joinwatch.lastjoined` 不存在(`joinwatch:135` 是唯一寫者,檔在 tmpfs),`meshjoin_joined` 也是假。
  - 這時**真的** `_ab_arm_mesh` 本來就寫 `m=radio`(`platform-ab.sh:110-112`)。負對照的結果(`ARMED-MESH m=radio`、`armed in radio-only mode`)有沒有 mutant 都一樣,所以「mutant 讓保護失效」的證據是假的。
- **證據**:✅ `platform-ab.sh:110-112`、`joinwatch:132-135`、§4.3 步驟 2、§4.3 通則、§6.2 `prov-netjoin-254` 列;⚠️ 單位內的狀態推移是依設計文字推論。
- **修法**:
  - L51 兩臂都在 member **且本次開機已由 joinwatch 寫入 `lastjoined`** 的 A 開機上做。建議用 fleet 值入網(同 `prov-netjoin-fleet`,經 fd 3),每次回 A 都會重新和 02 入網。B trial 正向臂會入網並 HELD,仍然看得到 `mesh join required: 1`。
  - 每一臂的前置斷言都要包含 `lastjoined` 非空(不只正向)。
  - 若改用白箱寫 `lastjoined`,在 §3 列為測試例外寫者並寫明條件。
  - §17.3 寫出單位內的 claim / net-apply / 重開步驟、對 §4.3 通則的例外,以及 F restore + brewrite(單位寫過 B)。

### M3. 偽造的 `prov-state` 改了第 3 欄(last_known_state),harness 中途死掉後 04 重開會被鎖、rollback 會被擋
- **情境**:§17.3 寫 `<boot> 99zz - unclaimed - 0`、`<boot> helper member member - radio`,L43 也寫 `member` 在第 3 欄。可是 `prov_read` 只讀 `$1/$2/$4/$6`(`batman-autocommit:402`)。第 3 欄另有讀者:
  - `batman-prov-lock`(S13,`any` 模式)看到 p6 是 claimed / member 就 LOCK:password 登入關閉、`ttylogin=1`;
  - `batman-slot` 的 rollback gate 會擋;
  - 96 也讀它。
- **後果**:deadman 不還原 p6(§3 prov deadman 列)。若 harness 中途死掉,且 04 在 P9 restore 之前重開(joinwatch 3600 s、斷電),一台 legacy 04 會以 LOCKED 開機。另外,當 overlay 沒有明確 record 時,`99zz` 會沿用舊的第 3 欄(`99zz:44-50`),錯值會黏住。
- **證據**:✅ `prov-lock.sh:54-58,69-75`、`init.d/batman-prov-lock:62-63`、`batman-slot:774-776`、`96-batman-config-migrate:70,105`、`99zz-batman-prov-state:44-50`。
- **修法**:
  - 偽造時第 3、5 欄照抄現值,只改 `prov_read` 讀的欄。
  - §5 補一列「harness 死於 L38 / L43(p6 已偽造)」,寫明行為與證明;deadman 若有本 run 的快照,至少把 `prov-state` / `ota-armed.mesh` 寫回。
  - §7.2 補一列。

## MINOR

- **m1(L38 正向可能因時序而過)**:如果 harness 的改寫早於 dry-run 第一次 `prov_read`(ssh 延遲),正向臂直接讀到 member、沒經過等待迴圈也會 PASS;mutant 臂也一樣,就會被誤判成「mutant 無效」。修法:先看到 `:386` 的 `gate until uptime` 行輸出,才在 T+20 改寫;斷言決定行晚於改寫時間。
- **m2(擁有權)**:§3 沒有這些列:
  - harness 對 `prov-state`(產品寫者 99zz / helper)與 `ota-armed.mesh`(產品寫者 platform-ab 第 1 段、autocommit 刪)的**測試例外寫者**;
  - 三個新的 bind 目標;
  - (若採用)`joinwatch.lastjoined`。
  依規則,兩個寫者要明列例外條件:lease、dirty、helper 狀態。
- **m3(L42)**:
  - hold 旗標必須在 `batman-slot apply` **之前**寫。apply 已經 arm tryboot(`batman-slot:704-724`);如果 harness 在 apply 和重開之間死掉,下一次任何重開都會進 trial。負對照臂的 arm 是 radio 且沒有 hold → V 被 commit 進 B,槽就變了。
  - `pr_ota_b` 的落點斷言(DT tryboot = 1、`HOLD-COMMIT`、無 DISCARDED)也要套用到 apply 這條路徑。
  - payload 解在 `$DVD/<run>/`(root 0700);`/tmp` 空間要寫明。
- **m4(重疊)**:L42 正向臂和 §6.2 (6a) 是同一個實驗,合併可以省一次 trial。(6b) 的負對照由 L43 的 dry-run 提供,寫明這點。
- **m5(殘留檢查)**:P9 與 deadman `unbind-all` 要以 `/proc/mounts` 為準,涵蓋 `/usr/bin/batman-autocommit`、`/usr/sbin/batman-slot`、`/lib/upgrade/platform.sh`(不只看 `wbox.list`),並加一個負對照:bind 著 `/lib/upgrade/platform.sh` → P9 FAIL。同一個單位裡,任何 `pr_ota_b` / sysupgrade 之前都要先 unbind:`RAMFS_COPY_BIN` 會把 `/usr/sbin/batman-slot` 複製進第 2 段(`platform-ab.sh:38`)。
- **m6(成本)**:§17.4 的「每次離網 3–5 分鐘」低估了。L42 / L51 還有 claim、net-apply(L51 用 fleet 值)、重開、F restore、brewrite(單位寫過 B,§4.3 步驟 3)。照 §7.3 的 hold 型約 47 分鐘重估,並更新全套總時數。
- **m7(上層與範圍)**:
  - p1-impl §4(`:288`)說 L38 / L42 / L43 / L51 走「開機路徑 `-wbox` 只寫進 B」,§17 改成 A 上 bind + dry-run,要寫進 §10。
  - p1-impl `:377` 的 `prov-misc` 另有 L3 / L9 / L10 / L11 / L27「各一個 mutant」,§6.2 / §17 都沒有寫程序或負對照,要嘛寫出來,要嘛明標 characterization 並放進 §9。
- **m8(dry-run 共用寫入)**:dry-run 在 committed 開機也會寫 p6 `ota-trace.log`(`otalog_k AC START … revert=1`,`:426`;`AC UNHEALTHY`,`:505`)、`$RUNDIR/autocommit.why`(`:515`),而且 COMMIT 路徑在 04 上會跑 canary `docker run` 並 prune 舊 tag(`:139-140,521-523`)。這和 §7.2 (9) 是同一種破例,§17 要列出。
- **m9(build 成本,可選)**:為了三個 shell 檔要 build 四個完整 image。留著可以沿用 gate / 見證機制,合理;但要寫明 bind 來源的 sha 對照 payload `SHA256SUMS`(§17.2 已寫),而且這四個 payload 永遠不進槽(P9「payload 18 份」照算)。

---

## 回答派工時的具體問題

1. **mutant 是否只拿掉指名的保護?**
   - L38(刪 `:404` 迴圈):✅ 只拿掉等待。
   - L43(`:420` 不比對第 1 欄):✅ 只拿掉 boot_id 比對;對照臂證明其他欄沒問題。
   - L42(apply 後寫 arm 檔):✅ 這是「加入」一個不存在的寫者;產品端的保護是「`batman-slot` 不寫」,用 grep 確認:只有 platform-ab 與 autocommit 碰這個檔。
   - L51(一律 `m=radio`、保留 caller / upgraded / live 檢查):✅ 指名正確,❌ 但 bind 對象錯(B1),而且負對照的開機狀態沒有鑑別力(M2)。
2. **dry-run 在 committed 槽是否走到 §17 依賴的路徑?** ✅ 會。`:270` hold 段 → `:298` / `:308` DRY 跳過 → `:315`(fw-override 檔,平常不存在)→ `:323` rc=0 → `:332` **SLOT = `batman-slot active` = A** → `:351` REVERT=1 → `:376-386` 期限(`AUTOCOMMIT_TIMEOUT` 為絕對 uptime,MIN_WINDOW=0)→ `:398` → `:403-404` `prov_read` 迴圈 → `:416-421` member 臂:`ab` = boot-reasons 倒數第 2 行 = 前一次開機,arm 檔第 2 欄要等於 A。副作用見 M1、m8。
3. **bind 是否安全、看得到?**
   - autocommit:✅ 真的 autocommit 早已退出,dry-run 經 PATH 呼叫 → 看得到。
   - `batman-slot`:✅ 直接 apply 看得到。⚠️ bind 期間所有 `batman-slot` 呼叫者(halow-status、harness 自己的 `is-trial` / `active`)都會用 mutant,而 mutant 只改 apply 之後的動作 → 可接受。
   - `platform-ab.sh`:❌ 看不到(B1)。
   - 同一個 mount namespace(dropbear / procd 沒有 unshare)⚠️ 推論,未上機。
4. **p6 副作用與還原**:`prov-state`、`ota-armed.mesh` 都在 `STATEFILES` 裡(✅ `prov-base-254.sh:29`),`pr_restore` 會寫回。缺口:deadman 不還原(M3);dry-run watchdog 會刪 arm 檔(M1)。boot-reasons:正常的追加,不還原,也不需要。
5. **harness 中途死掉**:bind → deadman 會 unbind(✅ §3);p6 偽造 → 只剩 dirty,重開會鎖(M3);dry-run 程序繼續活著 → 到期刪 arm 檔(M1);L42 apply 之後 → tryboot 已 arm(m3)。
6. **與其他單位的順序**:不能靠順序取得 member(M2)。

## 證據分類
- ✅ 已驗:B1、M1(含沙箱輸出)、M3、m3、m5、m8 的原始碼行號;dry-run 路徑追蹤;`STATEFILES` 內容;chain1 8.7 的 kill 寫法。
- ⚠️ 推論:上游 stage2 會複製 `/lib/upgrade/*.sh`(firmware 樹依指示未讀);bind 與 procd 同一個 mount namespace;單位內的狀態推移(依設計文字)。
- ❌ 未做:任何上機驗證(無節點存取);上游 OpenWrt stage2 原始碼核對。

## 摘要
§17 的方向正確:L38 / L43 用 dry-run,L42 / L51 用 A 上 bind 加 hold trial,四個 mutant 也都只拿掉指名的保護。但有三個問題必須先修:
- L51 bind 錯檔:sysupgrade 讀的是 98 複製出來的 `/lib/upgrade/platform.sh`(B1)。
- committed 槽上的 dry-run watchdog 會刪真的 `ota-armed.mesh`,並佔用真名的 claim 目錄(沙箱已重現,M1)。
- member 前置不能靠單位順序取得,而且 L51 負對照在 back_to_a 之後沒有鑑別力(M2)。

另外,偽造的 `prov-state` 第 3 欄會在 harness 死掉後讓 04 被鎖(M3)。修完後請重審 §17 及它對 §3 / §5 / §7.2 的增列。
