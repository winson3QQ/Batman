# h23 設計審查 v12 — 審查者 B(全文 §0–§21,重點 §21)

(審查者 agent 無法寫檔,全文由主 session 依其回報存入。)

對象:`docs/design/254-h23-harness.md` @ 2902e90(934 行)。原始碼:rc `/home/yello/Batman-rc` @ d0643d5 — `batman-slot:33-80,238-370,730-870`、`batman-autocommit:42,62,111-113,270-300,355-440,515-560`、`bootfacts.sh:43`、`rundir.sh`、`95-batman-storage:715-718`;harness — `lint-wbox.sh`、`tests/wbox/*.patch`(13)、`tmp-trust-allowlist.txt`、`prov-base-254.sh:27`、brewrite / chain1 / pty-commit。沙箱 WSL busybox 1.36.1 ash(`/home/yello/dreview12B.*`,三次都已刪)。無 ssh、無 commit、未碰 firmware-2710。

## 0. 結論
**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 9 MINOR)。** §21 處理 v11 兩位共 21 條發現;§21.7 遺留表逐項對上 v11 A MAJOR-1 清單與 B-m7(1)–(13)(只一條殘項沒落地,m9)。沙箱重建 detached rollback 臂:四種結果 + 臂中殺 ssh 照設計運作,負對照成立;`/proc` 掃描在 churn 與 comm 偽裝下正確;見證位置 `sh -n` 可解析;13 個 patch 都沒碰 `batman-autocommit` / `batman-slot`。實作前要寫進規格:m1–m5;實作時補:m6–m9。修完只需確認 §21.1、§21.4 與 P9。

## 1. 前輪處理
v11-B:m1 ✅(斷電恢復指令 m3、P9 比較方式 m4);m2 ✅(pre-gate 停止無負對照 m9);m3 ✅(三字串互不相同,不含 `holds a -wbox test image`);m4 ✅(dry-run pid 取法未寫 m7);m5 ⚠️(「被讀取就建檔」對一般檔做不到、lint 未豁免 gate m8);m6 ⚠️(漏被 source 的 lib m5);m7 ✅;m8 ✅。
v11-A:MAJOR-1 ✅;m1 ✅(pid 取法 m7);m2 ✅ 臂 b(臂 a 節點端 m7);m3 ✅(R3;語法錯誤 patch 負對照 m8);m4 ✅(R1 writethendie);m5 ✅(A 的 autocommit 不需檢查:trial 跑 B 的 autocommit;負對照 m9);m6 ⚠️(漏 `COMMITTED` m6);m7 ✅ 位置(第二處 → FAIL 負對照 m9);m8 ✅;m9 ✅;m10 ✅ `$DVD/<run>/`(但臂結果檔放 `$RUNDIR` m1);m11 ✅(H3-U3 第 18 行、§7.3 原文仍寫 22–23 h,§21 優先,僅記錄);m12 ✅ §7.2(回補後沒斷言 openmanetd m9)。
更早:v8 / v9 / v10 與安全審查 F1–F5 的 BLOCKER / MAJOR 都已關閉、無回歸;§19.3 / §20.4 閘位置對照 `cmd_rollback`(`:786-797`)仍成立;`BADMARK` 只在 apply 驗證失敗時寫(`:384`),autocommit revert 只寫 p6 `bad-slot`(`:195,244`),revert 後 `slot_is_bad B` 不擋 rollback 臂 ✅。

## 2. 沙箱(✅)
R1 detached 臂(stub 寫假 `autoboot.txt`,`[all]` 用真 `bf_ab_all`):
```
[wbox] RESULT=PASS rc=1 a1=1 | all=1 commits=0
[other] RESULT=INVALID rc=1 msg=[batman-slot: rollback lock gate: cannot read slot B's rootfs — refusing] | all=1 commits=0
[regress] RESULT=FAIL-RECOVERED rc=0 a1=2 a2=1 out=[rolled] | all=1 commits=1
[writethendie] RESULT=FAIL-RECOVERED rc=1 a1=2 a2=1 out=[batman-slot: autoboot.txt does not read back] | all=1 commits=1
[needsperson] RESULT=FAIL-NEEDS-PERSON rc=0 a1=2 a2=2 | all=2 commits=0
== negative control: arm without trap/setsid, outer killed by HUP between rollback and commit
[noprotect] res=[] all=2
== design form: session leader (ssh-like) killed by HUP + KILL to its group mid-arm
  immediately: res file exists=y size=0
[detached] res=[RESULT=FAIL-RECOVERED rc=0 a1=2 a2=1 out=[]] all=1
== setsid fork check: is arm in its own session?
  arm pid=1776130 sid=1776130 leader=1776128
== empty a0
RESULT=INVALID a0=''
```
R2 robust 掃描(3000 個短命程序背景起落):
```
robust under churn (expect 1 each): 1 1 1 1 1 1 1 1 1 1
with spoof comm: members=1  (expect 1)
after end: members=0 (expect 0)
```
R3 見證位置:`:404` 換成 `log "… WBOX-misc-l38-1a2b3c4d"` → busybox `sh -n` 0;`:417` 之後插行 → 0;對照組插在 `:421`(`;;`)之後 → busybox 2、dash 2;原檔 busybox / dash / bash `-n` 都 0。
R4 13 個 patch 的 `+++` 路徑:`96-batman-config-migrate`、`boot.go`、`node.go`、`main.go`、兩個 Makefile、`wbox-chan`、`99zz-wbox-radio1-off`、`wbox-helper-exit1.sh`;沒碰 autocommit / batman-slot ✅。

## 3. 發現(全部 MINOR)
- **m1** 結果檔:重導向在 setsid 前建檔(R1 0.3 s 已存在、大小 0)→「沒有結果檔」分支永不觸發;檔放產品 `/tmp/run/batman`(`rundir.sh`),§3 沒這寫者且與 §21.3 不一致;120 s 後第一臂仍在跑時另起回補會撞 `slot_lock` 而 die(`:72-80`)→ 誤判 NEEDS-PERSON;沒寫 ssh 是否立即返回。修:輪詢 `^RESULT=`;路徑 `$DVD/<run>/rbarm.out` + `rbarm.pid`;120 s 先 `kill -0`,活著再等(+60 s)不另起回補;外層 `setsid … &`。
- **m2** `power_ok` 是內部函式(`:278-300`)無法外呼;前置只要求 a0 ∈ {1,2},若 a0 已是 B → 被拒、a1 = a0 → 假 PASS(⚠️ 現行 `pr_end` 第 1 步斷言 04 在 A committed,照現序碰不到)。修:`a0 = $(batman-slot fw-part "$(batman-slot active)")` 且 `is-trial` rc = 1;電源改 `vcgencmd get_throttled` bit 0 取樣三次(照 `:285-293`);dv-sbx 加 a0 = B → INVALID。
- **m3** 回歸窗口斷電 → 下次開進 B 且 committed(以 `[all]` 開機,非 trial,autocommit 不評估);新 P9 不觸發,舊 §4.7 規則抓到但印 brewrite;正確恢復 = B 上 `batman-slot rollback`(目標 A)+ `reboot committed`;FAIL-NEEDS-PERSON 後節點停在「跑 A、`[all]`=B」,之後任何重開進 committed wbox。修:§5 列明;P9 對「執行中 = `[all]` 且含 wbox」印 rollback + reboot;NEEDS-PERSON 文字寫明先修電源再 commit、在那之前不要重開。
- **m4** P9:`bf_ab_all` 回 1|2(`:817`)、執行中是字母 → 直接比永遠不等;讀不到回空(`bootfacts.sh:43`)未定;`.protected` 缺且 squashfs 掛不上未定 → 常見寫法 fail-open。不誤觸發(一般 committed、release trial、mid-OTA `:720`、Pi 4 EEPROM 走錯槽)✅,前提是比較寫對;`/boot` 一律 bootA(`:33`);bcm2710 無 `/boot/autoboot.txt`。修:`[ "$(bf_ab_all)" = "$(batman-slot fw-part "$(batman-slot active)")" ]`;`bf_pi4` = yes 時空值 / 非 1|2 → FAIL;`.protected` 缺且掛不上 → FAIL;掛載點 `mktemp -d`;`test-dv-preflight.sh` 三案。
- **m5** 檔案範圍漏被 source 的 lib:`batman-slot` source `otatrace.sh`(`:51`)、`rundir.sh`(`:62`)、`bootfacts.sh`(`:812`);`batman-autocommit` source `rundir.sh`(`:42`)、`otatrace.sh`(`:111`)、`meshjoin.sh`(`:113`)、`bootfacts.sh`(`:358`);非 misc 變體改 lib 重定義 `die` / `log` / `wbox_image` 就能拆閘;Makefile install 能把別的檔裝到 `/usr/sbin/batman-slot`(rootfs sha 擋得到、lint 擋不到);misc「只改 autocommit」lint 沒強制。修:受保護集合 = `usr/sbin/batman-slot`、`usr/bin/batman-autocommit`、`etc/init.d/batman-autocommit`、`usr/lib/batman/{otatrace,rundir,bootfacts,meshjoin}.sh`;非 misc 不得碰;misc 只准 autocommit;`pr_ota_b` 整集合 sha = 同 rc 正常 build;負對照改 `otatrace.sh` → FAIL。
- **m6** 安全網的 `COMMITTED` 也要限本次 trial boot8:aclog 有 brewrite / normalise / 前單位的 `COMMITTED boot=…`(`:537`),吃到舊行 → B trial 中途 rollback + 重開 → INVALID(白跑一輪)。
- **m7** dry-run pid 取法未寫:`setsid sh -c 'echo $$ > $DVD/<run>/dry.pid; exec env … batman-autocommit run' &`;臂 a「`gate until` 行後 ≥ 3 s 無判定行」也要節點端迴圈判。
- **m8** (a) `sh -n` 用 busybox ash(CI `sh` 是 dash)+ 「`;;` 後插行」patch 負對照;(b) `--selftest-` lint 要豁免 gate 本身,寫明在 firmware repo 跑,斷言 `build-board.sh` / `local-ab-tar.sh` 不傳;(c) F5 sentinel:一般檔被讀不會建檔 → `helpers.list` 用 FIFO(背景寫者在對端 open 後 touch),或偽內容一被採用就改變判定、以逐位元組相同證明未讀;`GO` 用一執行就建檔的腳本。
- **m9** 缺負對照:pre-gate 停止(test-dv stub 舊版 → 不 OTA、`FAIL pre-gate image`);nohold 第二處 → lint FAIL;回補 commit 後斷言 openmanetd running。記帳:§21.7 v10 B-m8(L9 `hci0_powered=1`)標「殘項 → #254」但 §9 沒加、無證據進 #254;§8 E-H5 原文沒有 `/rom` 那項。

## 4. 攻擊與生命週期(§21)
臂中 ssh 斷線 / harness 死 ✅(R1);rollback 前斷電 ✅;rollback 寫入後、回補前斷電(閘回歸時)⚠️ m3;回補後斷電 ✅;NEEDS-PERSON 後重開 ⚠️ m3;harness 重跑 ✅(P9 依 m4);閘回歸:放行 ✅ / 寫了才 die ✅ / 閘在 lock gate 後 ✅ INVALID;mutant 經 lib 拆閘 ⚠️ m5;`/proc` churn / 偽裝 ✅、setsid fork ✅(pid 取法 m7);本機非 root ✅(結果檔放 `$DVD` m1、P9 掛載點 `mktemp -d` m4);攻陷元件 ✅;供應鏈 / 我們自己 ⚠️ m5 / m8;fail-secure:產品閘 ✅,P9 讀不到判法(m4)與結果檔判定(m1)偏 fail-open;升降級 ✅;bcm2710 不適用(P9 `bf_ab_all` 只在 Pi 4 跑,m4)。

## 5. 證據
✅ R1–R4;`batman-slot:33-80,238-370,384,720,727-746,786-797,812-817`;`batman-autocommit:42,62,111-113,195,244,280-300,361,372,386,404-425,537`;`bootfacts.sh:43`;`rundir.sh`;`95-batman-storage:717`;`lint-wbox.sh` 全文;13 patch `+++` 路徑;`tmp-trust-allowlist.txt:7-13,81-90`;`prov-base-254.sh:27`。⚠️ dropbear 斷線行為(以 HUP + KILL 整組模擬)、04 churn、04 `/rom`。❌ 上機;真 `cmd_rollback` 閘原型(閘未實作);firmware gate 原始碼未讀(依指示)。

## 6. 摘要
APPROVE-WITH-CHANGES(0 / 0 / 9)。實作前寫進規格:m1–m5;實作時補:m6–m9。
