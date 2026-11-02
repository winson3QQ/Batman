# h23 設計審查 v11(§20)— 審查者 A

- 對象:`docs/design/254-h23-harness.md` 全文 §0–§20(worktree `/home/yello/Batman-h23`,派工寫 branch `harness/254-h23` @ 2e48a9c;本機 git 因 safe.directory 無法從 Windows 端讀 HEAD,以檔案內容為準:標頭已是 v11、§20 共 7 小節)。
- 原始碼:rc 樹 `/home/yello/Batman-rc`
  - `batman-autocommit:52,65-106,190-241,270-291,300-440`;
  - `batman-slot:54,84,254-267,357-369,735-797,809-833,840-853`;
  - `bootfacts.sh:43`、`otatrace.sh:24-30`;
  - `tests/prov-p1/batman-slot-rollback-gate.sh:1-30,55-90`;
  - helper 寫 `prov-state` 的位置(`main.go:208-215,340`、`node.go:1090`、`boot.go:284`)。
- harness:`scripts/lint-wbox.sh:20-40`、`.github/workflows/ci.yml:26-27,77-87`、`scripts/dv/chain1-254.sh:277-295`。
- firmware(唯讀):busybox 1.36.1 `.config`(`CONFIG_SETSID=y`、`CONFIG_ASH_JOB_CONTROL=y`、`CONFIG_FEATURE_SH_NOFORK=y`、`CONFIG_PGREP=y`)與 `util-linux/setsid.c`。
- 沙箱:`mktemp -d -p /home/yello dreview11A.XXXXXX`,以 WSL busybox 1.36.1 ash 跑,跑完已刪(`cleaned: 0 left`)。沒有 ssh,沒有 commit,沒動 firmware build。
- 標記:✅ 實跑或原始碼看過;⚠️ 推論或部分;❌ 沒做。

## 結論

**APPROVE-WITH-CHANGES:0 BLOCKER / 1 MAJOR / 12 MINOR。**

§20 正面收掉了 v10 的三個 MAJOR(A-M1、A-M2、B-M1),做法都對。
- §20.1:改掃 `/proc/*/stat`,計時從 `mesh join required` 行起算,L38 臂 b 用 uptime ≥ 58 s,`hold-consumed` 也有承重斷言。
- §20.2:變體名改小寫。
- §20.3:rollback 臂在一條節點端指令內完成,並有回補。

原始碼與沙箱都支持這些作法,細節見下。

唯一的 MAJOR 是記帳問題,不是機制問題:v10 兩位共約 15 項 MINOR(含 v9 遺留),§20 沒有處理,也沒有寫進 §9 殘項或 #254 checklist。這已是連續第二輪(v10 A-m10 就指出過同一類),其中兩項有實質風險:P9 的 `[all]` 檢查、E-H5 的 `/rom` 實機確認。

12 個 MINOR 多是「照字面實作會壞」的細節,其中三項要先講:
- §20.6 規定見證行「緊接在被改的那一行之後」。這對 `misc-l42` 會產生 ash 語法錯誤(沙箱實證),對 l43 / l51 則與 v10 B-m3 的要求相反(m3)。
- §20.3 的分類順序沒寫死。「rc ≠ 0、訊息不是 wbox、但 `[all]` 已變」這一格會判成 INVALID,而且不回補(沙箱實證,m4)。
- `prov-wbox-nocommit-254` 沒有 pre-P1b 前置。§8 第 4 步規定每個單位都先在 wsl.4 上跑,在那裡 rollback 一定放行,會直接走進回補路徑(m5)。

---

## 0. 前輪發現的處理狀況

### v10-A(本人上一輪)
| 項 | 狀態 | 依據 |
|---|---|---|
| M1 `ps -o` 不存在、15 s 殺掉 L38 a/b | ✅ | §20.1:`/proc/[0-9]*/stat` 第 6 欄;計時從判定行起算;a/b 90 s 上限;uptime ≥ 58 s。細節見 m1 / m2 |
| M2 大寫變體名 | ✅ | §20.2;實跑 `grep -oE 'WBOX-[a-z0-9-]+-[0-9a-f]{8}'` 抓得到 `WBOX-misc-l38-1a2b3c4d`;`lint-wbox.sh:26` 的名字規則可以過 |
| M2「gate 自測加大寫見證一案」 | ❌ 未提(MAJOR-1 表) | |
| m1 uptime 量 | ✅ §20.1(門檻 58) | |
| m2 `revert=0` + `hold present` + deadman 刪 `hold-consumed` | ✅ §20.1;字串原文見 m2 | |
| m3 hold 旗標前置 + `ctl.dry` / `dryrun.log` | ✅ §20.1 | |
| m4 rollback 臂假 PASS / 回歸安全網 / `reboot committed` | ✅ §20.3 | 分類順序見 m4 |
| m5 reason 不穩 / INVALID | ✅ §20.3 | 判定行的範圍見 m6 |
| m6 成本 | ✅ §20.7 寫明需重新確認 | 仍是待決事項(m11) |
| m7 `/rom` 邊界 | ⚠️ 部分 | 獨立字串 ✅。failsafe 下操作員 `commit` 被擋的生命週期列、`cmd_commit` 的拒絕字串都沒寫(m9) |
| m8 F5 | ✅ §20.5 | 只走 CLI |
| m9 lint / 推送 | ✅ §20.4 | |
| m10 前輪遺留 | ⚠️ 部分 | `.txn` ✅、L3 ✅、L42 靜態 lint ✅、L27 / L10 副作用 ✅。L51 = L43 對照只差第 3 欄 ❌;L38 臂 c 標 characterization ❌(§20.6 改標「判定半邊」,不同義);見證位置 ⚠️ 方向與要求相反(m3);(6a) 標 characterization ❌;§5「(6a) apply 與重開之間死掉」❌;actor 表「bind 覆蓋 root 的 autocommit」❌ |
| m11 CI `/rom` stub | ✅ §20.5 | 「`BATMAN_WBOX=` 空」「只有 VER 含 `.wbox-`」兩案 ❌ |
| m12 hold-once 互動、`release --wait`、會改 default 的路徑清單 | ❌ | |
| m13 優先序宣告 | ✅ §20 標題 | |
| m14 §4.2 DISCARDED 分支加註 | ❌ | |

### v10-B
| 項 | 狀態 | 依據 |
|---|---|---|
| MAJOR-1 rollback 臂失敗路徑 | ✅ §20.3 修法 1–4 | 修法 5 的 P9「`[all]` ≠ 執行中槽且該槽含 wbox → FAIL」❌ 未採(§20.4 只加了跨閘降級的提醒) |
| m1 / m2 / m9 | ✅ §20.1 | |
| m3 檢查位置、既有測試 | ✅ 位置 | 既有測試的改法寫錯(m8);「補救 = 對該槽 apply release」❌ |
| m4 獨立字串 | ✅ | E-H5 加「A committed 與 B trial 都 `grep ' /rom ' /proc/mounts; cat /rom/etc/batman-build`」❌ |
| m5 (a)(b)(c) | ✅ | (c) 的 lint 放錯地方(m7) |
| m6 跨閘降級 | ✅ 文字 + P9 提醒 | 「pre-P1b 單位在任何 OTA 之前就 FAIL」❌ → m5 |
| m7 `back_to_a` 靜默 | ✅(記 stderr,行為不變,理由已寫) | |
| m8 L9 / L11 | ✅ | `hci0_powered=1` 未採,⚠️ 可接受 |
| m10 | ✅ §20.5 | |
| m11 小遺留 | ⚠️ 部分 | 見 MAJOR-1 表 |

### 更早
- v8 / v9 的 BLOCKER / MAJOR 已在 v9 / v10 收掉,本輪沒有回歸。
- 安全審查 F1–F5 ✅(F5 由 §20.5 收尾)。

---

## 沙箱實證(✅ 原始輸出;WSL busybox 1.36.1 ash)

**S1 `setsid` 與 session 掃描**(`x.sh` 第 1 版)
```
case1 non-interactive: $!=1430389  stat-exists=y
  members(sid=$!)=1
case2 set -m: $!=1430445 stat-exists=n members(sid=$!)=0
  actual sleep procs: pid=1430389/stat sid=1430389
pid=1430446/stat sid=1430446
  stat of spaced comm: 1430559 (a b) 9 9) S 1430388 1430385 1430385 34818 1430385 4
  naive field6=S  robust sid=1430385
```
- 非互動 ash:setsid 不 fork,`$!` = sid,掃描有效 ✅。
- 開了 job control(`set -m`)時:setsid 是 pgrp leader,`setsid()` 失敗,於是 fork,父程序立刻退出(`setsid.c` 的 `fork_or_rexec` 分支)。這時 `$!` 已經不存在,真正的 sid = `$!+1`,以 `$!` 掃描得到 0 個成員,也就是被當成「已結束」。
- comm 含空白 / `)` 時,天真的第 6 欄解析會錯;要取最後一個 `) ` 之後的第 4 欄才對。

**S2 見證行「緊接在被改的那一行之後」用在 `:421`**(`case` 分支以 `;;` 結尾)
```
.../s.sh: line 7: syntax error: unexpected word (expecting ")")
rc=2
```

**S3 §20.3 rollback 臂照條列順序實作**(stub `batman-slot`)
```
wbox          PASS (b=[1] a=[1])
other         INVALID (b=[1] a=[1]) <- recovery ran? no
regress       REGRESSION -> commit rc=0 all=[1]
writethendie  INVALID (b=[1] a=[2]) <- recovery ran? no
unreadable    REGRESSION -> commit rc=0 all=[1]
regress+commitfail REGRESSION -> commit rc=1 all=[2]
```
`writethendie`(寫了 `[all]` 之後才 die,訊息不是 wbox)被判 INVALID,而 `[all]` 停在 B。接著 harness 走 `pr_abort` → `pr_restore` → `reboot committed`,04 就會開進 committed 的 wbox,正是 v10 B-M1 的事件,只是範圍縮小了。

**原始碼核對(✅)**
- `batman-autocommit`
  - `:372`:`hold present — this trial will not be reverted`(只在 `REVERT=1` 且 `held` 時印)。
  - `:68-69`:dry-run + FORCE_TRIAL → `real_tryboot` 為真,所以 `REVERT` 起始為 1,這一行一定會印。
  - `:386`:`gate until … revert=$REVERT`。
- `:404`:`while [ "${pr%% *}" = 99zz ] && [ "$i" -lt 60 ]; do sleep 1; …`,以次數計,與開機 uptime 無關。60 次 `sleep 1` 的 monotonic 時間 ≥ 60 s,所以 58 s 門檻安全。
- `:314-318`:`$RUNDIR/batman-fw-override` 存在時 **dry-run 也會在判定行之前 `exit 0`**(只有 `:308` 的 pending 分支會看 `DRY`)。
- `batman-slot`
  - `:786-797`:`cmd_rollback` 不會重開,`write_autoboot` 之後 rc 0;回補用的 `cmd_commit`(`:735-745`)在非 trial 的 A 上可以執行,並把 `[all]` 寫回 A ✅。
  - `:357-361`:`write_autoboot` 先寫,讀回不符才 die → S3 的 `writethendie` 是真實存在的路徑。
- `bootfacts.sh:43`:`bf_ab_all` 失敗時印空字串,且一律 return 0。
- `otatrace.sh:28`:每行帶 `boot=<8hex>`。
- `rollback-gate.sh:13`:只抽 `rollback_lock_gate` 一個函式來測;`:16-18` 斷言順序在 `write_autoboot` 之前。

---

## MAJOR

### MAJOR-1 v10 的 MINOR(含 v9 遺留)約 15 項,§20 沒處理,也沒寫進 §9 / #254 checklist(連續第二輪)
- **情境**:
  - 使用者規則:砍掉的範圍要逐項寫進原單 checklist,交接時不准寫「全部收完」;v10 A-m10 也已點名過同一類問題。
  - §20 只處理了部分項目,其餘既不在 §20,也不在 §9 殘項。實作者照 §20 做完,這些項目就會消失,和 H2(#306)23 項漏掉是同一種失敗。
  - 其中兩項有實質風險:
    1. **P9「`[all]` ≠ 執行中槽,且 `[all]` 指向的槽含 wbox → FAIL」**(v10 B-M1 修法 5)。§4.7 只寫「committed 槽」,沒寫用 `[all]` 還是用執行中槽判斷。rollback 臂回補失敗、斷電、harness 死掉之後,04 會處在「跑 A、`[all]`=B(wbox)」的狀態。P9 若以執行中槽判斷就抓不到,下次任何重開都會進 committed wbox。
    2. **E-H5 的 `/rom` 實機確認**(v10 B-m4)。§20.4 讓 `cmd_commit` 與 autocommit 都依賴 `/rom/etc/batman-build`,對**每一次 release OTA** 都 fail-closed。CI 的 `/rom` 是 stub,真機只有間接證據(`daily-validation.sh:856`、`fault-injection.sh:141`,⚠️)。驗一次只要 `grep ' /rom ' /proc/mounts; cat /rom/etc/batman-build`,在 A committed 與 B trial 各跑一次。
- **證據**:✅ 逐項比對 v10-A / v10-B 與 §20 全文(上面第 0 節的表)。
- **修法**:加 §20.8「v10 遺留處理表」,每項標「已改(位置)」或「殘項 → §9 / #254 checklist」。至少涵蓋:
  - A-M2 gate 自測加大寫見證案;
  - A-m7 failsafe 下 `commit` 的生命週期列;
  - A-m10 的 L51 / L38c / (6a) characterization、§5 (6a) 列、actor 表 bind 列;
  - A-m11 兩個 CI 案;
  - A-m12 hold-once / `release --wait` / 路徑清單;
  - A-m14;
  - B-M1 修法 5(P9 `[all]`);
  - B-m3「補救 = apply release」;
  - B-m4 E-H5 `/rom`;
  - B-m11 dv-sbx L51 的 `meshjoin.sh` stub / `_ab_live_sysupgrade` 覆寫 / `RUNDIR`,以及 prov-misc 期間「不得有 `sysupgrade -T`」的前置;L27 重連方式。

  只補文件,不需要重新設計。

---

## MINOR

- **m1 §20.1 的 session 掃描要有「正向在場」,而且單一 entry 讀不到不能算 INVALID**
  - 情境:「該 sid 沒有成員 = 已結束」等於把「找不到東西」當成通過。S1 證明 setsid 一旦 fork(harness 的節點端包裝若開了 job control,或日後改用互動殼),`$!` 就不是 sid,掃描立刻得 0,於是判成「已結束」,這是 fail-open。另外,`/proc/[0-9]*` 展開之後程序隨時可能退出,個別 `stat` 讀不到是常態;照 §20.1「讀不到 = INVALID」的字面實作,會頻繁誤判 INVALID。
  - 修法:
    - 起動後立刻讀 `/proc/$!/stat`,斷言 session == `$!`(leader 本人在場),不成立 → INVALID;
    - 判定行出現前,至少一次掃到 ≥ 1 個成員;
    - 解析用 `r=${l##*) }; set -- $r; sid=$4`(S1);
    - 個別 entry 消失就 `continue`;只有「連自己 `$$` 的 stat 都讀不到」才算 `/proc` 不可用 → INVALID。

- **m2 §20.1 的時間戳要在節點端取;`hold present` 用原文;補一個前置**
  - (a) 「判定行出現時讀 `/proc/uptime`」要由**節點端**同一條指令內的輪詢迴圈(間隔 ≤ 0.5 s)來讀,不能由主機輪詢觸發。否則偵測延遲會把 mutant 的 < 1 s 量成數秒;若實作者先 sleep 60 才去看,真程式回歸成「不等」時,正向臂 b 也會假 PASS。⚠️ 同一 run 的 mutant 負對照會因此 FAIL,所以不會靜默,但 L38b 正向臂本身是 fail-open。臂 a 的「gate 行後 ≥ 3 s 仍無判定行」也要用同一個節點端迴圈判斷。
  - (b) §20.1 說「依實際字串,實作時抓原文」,原文是 `hold present — this trial will not be reverted`(`:372`),而且必須出現在 `gate until` 行(`:386`)之前。整行比對,不要用 `hold present` 子字串,否則會配到 watchdog 的 `hold present — revert watchdog stands down`(`:190,202`)或 `hold present at the deadline`(`:234`)。
  - (c) 前置加「本次開機沒有 `$RUNDIR/batman-fw-override`」:`:314-318` 在 dry-run 也會提早 exit,臂會一直等到上限才 INVALID,而且看不出原因。

- **m3 §20.6「見證 log 行緊接在被改的那一行之後」:對 l42 是語法錯誤,對 l43 / l51 與 v10 B-m3 的要求相反**
  - 情境:
    - `misc-l42` 改的是 `:421`(`else NEED_MESH=1; …; fi ;;`),「之後」就落在 `;;` 與下一個 pattern `*)` 之間,ash 回 `syntax error: unexpected word (expecting ")")`(S2)。被 bind 的 autocommit 整支跑不起來 → 永遠 INVALID,L42 也就永遠沒有負對照。
    - l43 / l51 改的是 `:420` 的條件。「之後」= then 分支內,只有在 mutant 條件為真時才會印見證。mutant 若無效,就得到「沒見證 = INVALID」,而不是「mutant 無效 = FAIL」,這正是 B-m3 要避免的混淆。
  - 證據:✅ S2;✅ `batman-autocommit:416-422`;✅ `lint-wbox.sh` 沒有 `sh -n`。
  - 修法:
    - 見證放在與 mutant 條件無關、必經的位置:l38 放在被刪的 `:404` 原位(`if [ -n "$pr" ]` 之前);l42 / l43 / l51 放在 `:417` `RADIO_REQ=1` 之後。
    - `lint-wbox` 對 patch 套用後的 shell 檔跑 `busybox sh -n`(另加一個語法錯誤 patch 的負對照)。

- **m4 §20.3 rollback 臂:分類順序與 `[all]` 讀法要寫死**
  - 情境:三個條列沒有優先序。照書寫順序實作時,「rc ≠ 0、訊息不是 wbox、`[all]` 已變」會判 INVALID 且不回補(S3 `writethendie`);`write_autoboot` 寫了才讀回失敗(`batman-slot:357-361`)就是這種情況。另外,`[all]` 前後都讀不到(都是空字串)時,「`[all]` 未變」會被當成成立。
  - 修法:
    1. 第一步永遠是「`[all]` 與臂前不同或 rc = 0 → 回補」,與 rc / 訊息無關;回補後才分類 PASS / INVALID / FAIL。
    2. `[all]` 用 `. /usr/lib/batman/bootfacts.sh; bf_ab_all`(`:43`)讀,值必須是 `1|2`,否則 INVALID;前後都記錄 `[tryboot]`。

- **m5 `prov-wbox-nocommit-254` 缺 pre-P1b 前置**
  - 情境:§8 第 4 步規定「每單位先在 wsl.4 跑負對照(`pre-P1b` 行)」。在 wsl.4 的 A 上,`batman-slot rollback` 沒有閘,一定放行,等於每次都走回補路徑。回補若因 `power_ok` 失敗,04 就停在「跑 A、`[all]`=B(wbox)」並等人(v10 B-m6 的延伸)。
  - 修法:OTA 之前先在 A 上斷言 `/usr/sbin/batman-slot` 含 `holds a -wbox test image`、`/usr/bin/batman-autocommit` 含 `STAMP-UNREADABLE`。不成立 → 印 `FAIL pre-P1b`、不 OTA、結束。test-dv 加一案:stub 舊版 → 不推送。

- **m6 `WBOX-NOCOMMIT` / `TRIAL-REVERTED` / `COMMITTED` 的判定要限定在本次 trial 的 boot id**
  - 情境:`ota-trace.log` 留著前幾輪的 `AC WBOX-NOCOMMIT` 行;只用 grep,會吃到上一輪的行而假 PASS。行號 offset 也不可靠,因為 95 會截短檔案(`chain1-254.sh:277`)。
  - 修法:照 `chain1-254.sh:282` 的做法,在 trial 內記下 `boot_id` 前 8 碼,只看含 ` boot=<b> ` 的行(`otatrace.sh:28`);aclog 的 `TRIAL-REVERTED boot=<b>` 也一樣。

- **m7 nohold 的 lint 放錯地方**
  - §20.3 要「`lint-install` 加規則掃 `scripts/dv/`」。但 `lint-install` 的契約是「`files/` 每檔都有 install 行」(p1-impl `:349`),而且 repo 裡還沒有這支 lint(`grep -rl lint-install` 只命中設計文件)。
  - 修法:放進 `lint-wbox`(它已在 CI `ci.yml:26-27`,也已擁有 wbox 相關規則),並附負對照:第二處使用 `nohold` → FAIL。

- **m8 §20.4 對既有 rollback-gate 測試的改法寫錯**
  - `tests/prov-p1/batman-slot-rollback-gate.sh` 只抽出 `rollback_lock_gate` 一個函式來跑(`:13`),所以 `:61` 的「legacy 時不掛載」對 lock gate 本身仍然成立,不應該改。
  - 該加的是新測試:
    - 抽出新的 wbox 函式,跑 rel / wbox / ver-only / 缺檔 / 掛不上五案;
    - 仿 `:16-18`,斷言 `cmd_rollback` 內的順序是 wbox 檢查行 < `rollback_lock_gate` 行 < `write_autoboot` 行,而且 wbox 檢查不在任何 `allowed` 分支內;
    - 負對照:把呼叫移到 lock gate 裡、或放在 `allowed UNLOCKED_ROLLBACK` 之後 → FAIL。

- **m9 `cmd_commit` 在 `/rom` 讀不到時的字串與 failsafe 生命週期**(A-m7 遺留)
  - §20.4 只定了 autocommit 的 `STAMP-UNREADABLE`。`batman-slot commit` 讀不到時的 die 字串沒定;failsafe / 無 overlay 開機時操作員 commit 被拒,這一列也還沒進 §5。
  - 修法:定字串;§5 加一列,並寫出補救方式。

- **m10 dry-run 的 stdout 檔路徑沒寫**
  - §17.3 / §19.1 只說「stdout 存檔」。如果放在 `/tmp` 下固定或可預測的檔名,本機非 root 程序可以預先放 symlink,讓 root 寫穿過去(actor:本機非 root)。
  - 修法:寫明放在 `$DVD/<run>/`(root 0700)並以 `mktemp` 建立,納入 tmp-trust allowlist 條目。

- **m11 §20.7 的成本重新確認是使用者待決事項,要進 §11,並卡住該單位**
  - 修法:
    - §11 加一列 D-H12「`prov-wbox-nocommit-254` ≈ 47–57 分,是否仍做」;
    - §7.3 的全套總時數與 H3-U3 一起更新(現在仍寫 22–23 h,沒有算進 prov-misc 的約 20 分與本單位);
    - 使用者確認之前,本單位不進全套。

- **m12 回補 commit 的副作用**
  - `cmd_commit` 結尾會跑 `addr_defer_release`(`batman-slot:745,752-760`):寫 `$RUNDIR/slot-committed`,並以 `setsid` 分離執行 `openmanetd start`。§7.2 要列出這兩項;回補後也要斷言 openmanetd 仍在跑。

---

## 安全(§20 增量)
| actor | 變化 | 判定 |
|---|---|---|
| 本機非 root | 新讀取:`/proc/*/stat`(唯讀,無法偽造他人 session);dry-run stdout 檔(路徑未定,m10) | ⚠️ m10 |
| 攻陷的元件 | 無法加入 harness 的 session(sid 只能是自己的 pid);在 5–30 s 視窗內重用 pid 的機率可忽略 | ✅ |
| 操作員 / 我們自己 | rollback 臂回補 ✅;分類順序(m4);pre-P1b(m5);舊行誤判(m6);見證語法(m3) | ⚠️ |
| 斷電 / harness 死 | rollback 放行與回補之間斷電 → 停在「`[all]`=wbox」→ 只能靠 P9 用 `[all]` 判斷來抓(MAJOR-1 第 1 點) | ⚠️ |
| 供應鏈 | `lint-wbox` 不准 patch 碰閘那幾行 ✅;F5 只走 CLI ✅ | ✅ |
| fail-secure | 產品閘 fail-closed ✅;harness 的「已結束」判定目前 fail-open(m1) | ⚠️ |

**生命週期(§20 部分)**:bcm2710 不適用(CM4 決定)✅;降級 ✅(§20.4)。以下沒寫或寫錯:
- 「pre-P1b 基底」(m5);
- 「rollback 放行後、回補前斷電」(MAJOR-1 第 1 點);
- 「failsafe 下 commit」(m9)。

---

## 證據分類
**✅ 實跑或原始碼**
- S1 / S2 / S3 沙箱輸出(上節)。
- `batman-autocommit:52,65-106,190-241,300-440`;`batman-slot:54,254-267,357-369,735-797,809-853`;`bootfacts.sh:43`;`otatrace.sh:24-30`;`rollback-gate.sh:1-30,55-90`。
- busybox `.config` 與 `setsid.c`;`lint-wbox.sh:20-40`;`ci.yml`;`chain1-254.sh:277-295`。
- helper 寫 `prov-state` 只在開機(`main.go:340`)、claim / replay(`:208`)、`applyNet`(`node.go:1090`):prov-misc 期間沒有 BLE / 認領操作時不會被改寫,臂 b 的 60 s 不會被 helper 提早打斷。

**⚠️ 推論或部分**
- 04 的 `/rom` 只有間接證據(MAJOR-1);
- 04 busybox 與 WSL 同版本,但沒上機;
- S3 的 stub 只模擬語意。

**❌ 沒做**
- 上機(唯讀規定);
- §0–§16 未改動的部分沒有逐行重審(前幾輪兩位已 APPROVE),只抽查 §1.4、§3、§4.1–§4.3、§4.7、§5 開頭、§7、§7.3、§8–§11 與 §20 的一致性。

## 摘要
- **判定**:APPROVE-WITH-CHANGES(0 / 1 / 12)。
- **v10 的三個 MAJOR 都已解**:`/proc` 掃描與計時、小寫變體名、rollback 臂單指令回補。原始碼確認 `hold present`(`:372`)、`revert=` 行(`:386`)、`:404` 的次數型等待成立,58 s 門檻安全。
- **MAJOR-1**:v10 約 15 項 MINOR 沒有處理也沒記成殘項,已連續兩輪;其中 P9 用 `[all]` 判斷、E-H5 `/rom` 實機確認兩項有實質風險。補一張對應表即可。
- **要先修的 MINOR**:
  - 見證位置規則會讓 `misc-l42` 語法錯誤(m3);
  - rollback 臂分類要「先回補再分類」(m4);
  - 本單位要有 pre-P1b 前置(m5);
  - 判定行要限定 boot id(m6);
  - session 掃描要有正向在場(m1);
  - 臂 b 的時間戳要在節點端取(m2)。
- **待使用者決定**:`prov-wbox-nocommit-254` 的實際成本約 47–57 分,不是當初的 25 分(m11)。
