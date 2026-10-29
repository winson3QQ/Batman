# h23 設計審查 v13(§22)— 審查者 A

(審查者 agent 無法寫檔,全文要點由主 session 依其回報存入。)

對象:`docs/design/254-h23-harness.md` @ 2ec108a(1021 行),逐項比對 `h23-review-v12-{A,B}.md`。原始碼(rc d0643d5):`batman-slot:28-100,180-300,340-370,700-870`、`batman-autocommit:42,62,111-113,190-234,366-386,537-552`、`bootfacts.sh:1-43`、`prov-base-254.sh:1-60`(`DVD=$RUNDIR-dv` `:27`)、`tests/wbox/*.patch` 的 `+++` 路徑、`.github/workflows/ci.yml`。GitHub 唯讀 `gh issue view 254 --comments`。沙箱 WSL busybox 1.36.1 ash + `script`(pty),已刪。無 ssh / commit / worktree 改動 / firmware-2710。

## 結論
**APPROVE-WITH-CHANGES:0 BLOCKER / 1 MAJOR / 10 MINOR。** §22 把 v12 兩份 25 條逐條對到段落;抽查:先回補再分類符合 `write_autoboot` 先寫後讀回(`:218-222`);`slot_lock` 擋第二個 batman-slot(`:61-73`);dry-run `log` 在 `DRY=1` 印 stdout(`:62`);`hold present`(`:372`)在 `gate until`(`:386`)之前;`COMMITTED boot=`(`:537`)。v12 A-m12 殘項已登記(留言 6460421575 ✅)。唯一 MAJOR:§22.1 的節點「撐過斷線」證明:ssh 已立即返回,10 s 窗口無 ssh 可殺;不配 pty 時連無保護的 `&` 都活 → 無判別力。

## v12 逐項
v12-A:MAJOR-1 ⚠️(節點不放 stub ✅,替代證明無判別力 → MAJOR-1);m1 ✅(起法 inline 引號 → m2);m2 ✅;m3 ✅(多等 60 s 之後 → m1);m4 ✅(合法 trial 被 WARN → m3);m5 ✅(lint job 無 busybox → m5);m6 ✅;m7 ⚠️(舊 gate 開 FIFO 無證據 → m4);m8 / m9 / m10 ✅;m11 (1)–(7) ✅;m12 ✅。
v12-B:m1 ✅(→ MAJOR-1、m1);m2 ✅(dv-sbx a0 = B 未進 checklist → m9);m3–m9 ✅(細節見 m3 / m8 / m10 / m2 / m4 / m7)。

## 沙箱(✅;`script -qec` 模擬 `ssh -tt`)
arm = `echo $$ > pid; sleep 4; echo RESULT=PASS`,起動同 §22.1(stdin / stdout 重導),起動器立即結束:
```
plain-nopty            nopty out=[RESULT=PASS ]
design-nopty           nopty out=[RESULT=PASS ]      (trap '' HUP PIPE; setsid … &)
traponly-nopty         nopty out=[RESULT=PASS ]
setsidonly-nopty       nopty out=[RESULT=PASS ]
plain-pty              pty   out=[] outfile=n         (SIGHUP 殺在重導之前)
design-pty             pty   out=[RESULT=PASS ]
traponly-pty           pty   out=[RESULT=PASS ]
setsidonly-pty         pty   out=[] outfile=n         (setsid() 前就被 HUP)
hold-plain   (pty,起動器 sleep 30,1 s 後 kill script)  out=[]
hold-design  (同上)                                     out=[RESULT=PASS ]
```
引號:外層設 `DVD=/x/dv` 不 export,內層 `sh -c '…$DVD…'` 讀到 `inner DVD=[]`。

## MAJOR-1 §22.1 的節點「撐過斷線」證明沒有判別力,照規格也做不到
§22.1 起動 `setsid sh …rbarm.sh </dev/null >…rbarm.out 2>&1 &`、ssh 立即返回,又要求 harness 在 10 s 內殺 ssh → 無 ssh 可殺。就算把 ssh 返回當斷線,不配 pty 時沙箱 nopty 四種(含完全無保護的 `&`)全寫 `RESULT=PASS` → 節點 PASS 證明不了 `trap '' HUP PIPE; setsid` 有作用(正向因別的原因通過)。真正會殺臂的是 pty 斷線(plain / setsid-only 死、design 活;`addr_defer_release` 註解約 `:290-293` 記錄過實測現象)。§22.7 把 A-MAJOR-1 標已解所依的節點證據是假保證。修:節點改 `ssh -tt`,同一連線起臂後 `sleep 30` 保持 session,在臂的 10 s 窗口內殺 ssh client;臂 rollback 前後記 uptime,harness 記殺 ssh 時 session shell pid 已消失並斷言殺的時間早於 rollback;負對照:同一 `ssh -tt` 路徑起無害臂(不呼叫 batman-slot,只 `sleep; echo RESULT=PASS`)不加 trap / setsid → 必須無 `RESULT`;若不做,§22.1 / §22.7 改寫為「節點只驗正常路徑;撐過斷線只在 dv-sbx(⚠️ 模擬)」。

## MINOR
- **m1** 輪詢收尾:「再等 60 s」後仍活著(卡 `vcgencmd` / mount)未寫;`kill -0` 未防 pid 重用;臂被殺但子程序 `batman-slot rollback` 仍持 `slot_lock` 時,第二個回補 die(`another batman-slot`,`:66-67`)誤判 needs-person。修:180 s 後一律不另起回補,`pr_needs_person` 附 `[all]` / `[tryboot]` / 程序列表;`kill -0` 加比對 `/proc/<pid>/cmdline` 含 `rbarm.sh`;回補腳本先確認無 cmdline 含 `batman-slot` 的程序;`pr_begin` / P9 對殘留且活著的 `rbarm.pid` 判 FAIL。
- **m2** §22.3 `setsid sh -c 'echo $$ > $DVD/<run>/dry.pid; …'` 在 `prov-base-254.sh` 執行時 `DVD` 未 export(`:27`)→ 內層讀不到 → 寫到 `/<run>/dry.pid`(root 寫進 overlay)或失敗;從主機雙引號經 ssh 則 `$$` 在主機展開。修:stage 成 `$DVD/<run>/dry.sh`,或位置參數 `sh -c '…"$1"/dry.pid…' _ "$DVD/$RUN"`。
- **m3** P9 把合法 trial(release trial、`pr_normalise` 的 A trial、本單位 B trial)標 WARN;S 的 `.protected` 缺且掛不上 → 讀不到 → FAIL;fixture「release trial → PASS」與 WARN 矛盾;`fw-part` / `active` 在 `detect_layout` die(`:95,98`)回空未寫。修:DT tryboot = 1 且執行中 = `[tryboot]` → INFO「trial 進行中」只對 S 做 wbox 判定;回空 → FAIL;fixture 寫明 release trial → PASS 且無 WARN。
- **m4** F5 FIFO:「舊 gate 會開 FIFO → sentinel」是斷言無證據(⚠️ gate 在 firmware 未讀);舊 gate 若先 `[ -s ]` / `[ -f ]`(FIFO 皆假)就不 open → 負對照永不成立;新 gate 不開 FIFO 時背景寫者永遠阻塞 → CI 殘留。修:對 F5 前的 gate commit 實跑負對照記進 PR;寫者加 timeout、結束 kill 並刪 FIFO;加一般檔版本(偽內容被採用就改判定,逐位元組相同證明未讀)。
- **m5** `sh -n` 用 busybox 但 lint job 沒裝(`lint-wbox` 在 `ci.yml:26-27`,busybox 只在 `:53-54` 另一 job)。修:該 job 裝 busybox;找不到 → FAIL 不跳過。
- **m6** §22.2 先信 `.protected`:它是槽首開時寫的(`95-batman-storage:717`),apply 之後、首開之前是舊版本號;閘回歸讓 `[all]` 指向剛 apply 未開過的 wbox B → 讀到舊非 wbox → 只 WARN 漏抓。修:一律唯讀掛 squashfs 讀 `etc/batman-build` 為準,`.protected` 只交叉核對,不一致 → FAIL。
- **m7** E-H5 第 4 項「A committed ✅」無原始輸出;#254 留言搜不到 `/rom`。修:原文貼 #254 並在 §22.6 附連結。
- **m8** 斷電恢復路徑需能 ssh 進 B;B 是 `96-noprov`(provisioning 不還原,mesh / 身分可能不同)。修:§5 註明到達 B 的方式(lab key、乙太網、IP),本單位前置斷言 B trial 期間 ssh 可達(`pr_find`)。
- **m9** §22.8 checklist 漏:F5 sentinel 與舊 gate 實跑;`cmd_rollback` wbox 檢查在 lock gate 之前的順序測試(§21.6);`/proc` churn 白箱(§21.3);「單位期間無 sysupgrade 程序」(§21.7);`release --wait` 遇 wbox 必逾時的文件註記;dv-sbx a0 = B → INVALID;`dry.pid` sid 輪詢與在場判定;回補後 openmanetd running(要等候,`addr_defer_release` 背景)。
- **m10** 受保護集合只擋 patch 動到路徑,擋不住執行期改寫:mutant 新增 uci-defaults(如 radio1-off 形式)在 B 首開以 root 改寫 overlay 裡的 `/usr/bin/batman-autocommit` 或 lib,rootfs sha 與檔案範圍 lint 都抓不到,trial 期間跑 overlay 版。修:`lint-wbox` 拒絕任何 patch 的 `+` 行出現受保護路徑字串(misc-* 對 autocommit 例外);節點 B trial 期間斷言 `/overlay/upper` 內無受保護路徑。

## 攻擊與生命週期(§22 增量)
ssh 斷線 / harness 死 ⚠️(沙箱 pty 下設計存活 ✅,節點證明無效);rollback 前斷電 ✅;回歸窗口斷電 ✅(既有 P9 抓、恢復指令已更正,可達性 m8);NEEDS-PERSON 後 ✅;harness 重跑時臂仍在 ⚠️ m1;P9 讀不到 ✅ fail-closed(m3 / m6);本機非 root ✅;攻陷元件 ✅;我們自己 m2 / m10 / m9;供應鏈 ✅;F5 ⚠️ m4;failsafe / 升降級 ✅;bcm2710 不適用 ✅;fail-secure 產品閘 ✅,harness 端 m1 / m3 偏誤判、方向安全。

## 證據
✅ 沙箱 10 列與引號案;`batman-slot:61-73,177-222,260-331,342-370`;`batman-autocommit:62,372,386,537,551`;`bootfacts.sh:40,43`;`prov-base-254.sh:27`;`ci.yml:26-27,53-54`;13 patch `+++` 路徑(Makefile 只新增 INSTALL 行);#254 留言 6460421575。⚠️ 舊 firmware gate 讀 helpers.list 的方式;dropbear `-tt` 斷線行為(以 `script` pty 關閉模擬)。❌ 上機;§0–§16 未改動部分只抽查。
