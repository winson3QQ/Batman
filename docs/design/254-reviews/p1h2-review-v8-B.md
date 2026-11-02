# 審查 B 第 8 輪:設計 v5.1(§3 / §5.4 鏈 1 / §13.3 / §13.4)、P1 31b4751、H2 afb8f91、E1c v2

審查者 B,2026-10-21。

**範圍**
- 整份設計 `254-p1-impl.md`,包含第 8 輪改動。
- `feat/254-p1` HEAD 31b4751(在 c1e1c72 之上的 diff,外加 boot.go、batman-autocommit、batman-config-save、batman-slot、platform-ab.sh 全文)。
- `harness/254-h2` HEAD afb8f91:`prov-base-254.sh`、`prov-base-statecmp.sh`。
- 草稿 `prov-claim-254.sh`。
- `e1c/e1c.sh` v2,逐行追過每一條出口路徑。
- 上游 procd 原始碼(firmware 樹 build_dir)。
- 上游 `lib/upgrade/stage2`、`do_stage2`。

**真機**:對 04、02 只做了唯讀 ssh(`ls`、`cat`、`date`、`batman-slot active/is-trial`、`find -mmin`)。沒有寫入、沒有重開,也沒有印出任何秘密。

**WSL**:測試都在 `/tmp/rv8`、`/tmp/rv8b` 的副本裡跑,沒有修改 repo:
- Go 用的是 firmware 樹的 go1.26.4,設了 `GOTOOLCHAIN=local`,這次沒有下載任何東西;
- mutant 在副本上跑;
- losetup 測試用 root 跑。

我的工具放在 `scratchpad/h2/rv8/`。

**判定:REJECT**:0 BLOCKER / 4 MAJOR / 15 MINOR。

**E1c 能不能跑**:M1、M3 修好之前不要跑。
- M1:幾乎一定會誤判 FAIL,白白破壞一次 p5。
- M3:有一條「04 committed 在沒有 dead-man 的 fresh B 上」的路徑。

兩項都是幾行的修改。除此之外,E1c v2 的出口路徑我逐一追過,沒有找到會讓 04 卡死、會弄丟 p5、或會誤報 DONE 的路徑(見 §2)。
- M2:鏈 1 的文字錯誤,不影響 E1c,但鏈 1 照現在的寫法做不出來。
- M4:產品在現場生命週期上的缺口(Pi 3)。

---

## 0. 本輪證據

| # | 事實 | 證據 |
|---|---|---|
| ✅ R1 | 04 現況:`1.5.12-wsl.11+c1e1c72.fw3db3f36`,`slot=A trial=1`,up 994 s。p6 state 有 `ble-ok`、`lock-status`、`mesh-expected`(`seeded --on-join`)、`mesh-joined`(`first-joined boot=ffbd1908 20250630-212254`)、**`ota-armed.mesh` = `dceb9f18 B joined`**(rollout 留下的)、`prov-state` = `helper legacy legacy - today` | ssh 唯讀 |
| ✅ R2 | 02 現況:`1.5.12-wsl.12+31b4751.fw499bb1d`,**`slot=B trial=1`**,up 149 s,p6 上有 **`autocommit-hold-commit`**。rollout 還在進行,不是 S0(預期中) | ssh 唯讀 |
| ✅ R3 | 兩台的 `/lib/upgrade/` 都只有 `common.sh do_stage2 fwtool.sh keep.d luci-*.sh platform.sh stage2 tar.sh`,**沒有 `platform-ab.sh`**;`grep -c prov-lock /lib/upgrade/platform.sh` = 2。`platform-ab.sh` 是由 98-batman-sysupgrade 從 `/usr/lib/batman/platform-ab.sh` 複製到 `/lib/upgrade/platform.sh` 的(`98-batman-sysupgrade:7`、`platform-ab.sh:3`) | ssh、讀檔 |
| ✅ R4 | procd:`sysupgrade.c:38` `chroot(prefix)` 之後 exec `upgraded`;`upgraded.c:81` `chroot(".")` 回到原本的 root,再 exec `/lib/upgrade/stage2`(`upgraded.c:46/57`)。stage2 在 live root 上執行,先 `include /lib/upgrade`(`stage2:16`),再 `install_file … /lib/upgrade/*.sh … $RAMFS_COPY_DATA`(`stage2:56-59`)。所以**同一個 mount namespace 裡的 bind mount 會被複製進 ramfs**,而且用的是被 bind 那份檔案的 `RAMFS_COPY_DATA` | procd 2026.03.14 原始碼、stage2 |
| ✅ R5 | stage 2 的 gate:`_ab_do_upgrade` → `batman-slot stage-root` → `precheck` → `node_checks`。L44 的例外要 `[ -r /usr/lib/batman/prov-lock.sh ]`(`batman-slot:549`),`part_fstype` 只用 `hexdump`(在 `RAMFS_COPY_BIN` 裡)。找不到 prov-lock.sh → die 「not seeded」,這發生在 `begin_write` **之前** → `ota_s2_explicit_restart_if_not_armed` → 重開到 `[all]` | `batman-slot:110-116, 519-553, 625-632`;`platform-ab.sh:282-320, 326-384` |
| ✅ R6 | `AUTOCOMMIT_DRYRUN` 會依 boot_id 重讀 `prov-state`(`:402`),也會重讀 p6 marker(`:390`、`:413`)。DRY 不消耗 hold flag(`:291`),CTL / ACLOG 各自獨立(`:53`、`:44`)。DRY 的 `revert_watchdog` 子程序能直接結束,是因為**真的那個** `autocommit.wd` 已經存在(`:199`)。`AUTOCOMMIT_TIMEOUT` 是**絕對的 uptime**,不是一段時長(`:380-383`)。命令一定要帶 `run`(`:251`) | 讀檔 |
| ✅ R7 | 04 的時鐘是 `Thu Jul 17 22:22:14 UTC 2025`,主機是 `Wed Oct 21 10:01:24 UTC 2026`;`/etc/batman-build` 的 mtime 是 2025-06-23 20:40(SOURCE_DATE_EPOCH);NTP 開著,但從來沒有對時成功 | `date -u`、`ls --full-time` |
| ✅ R8 | payload 的 `metadata` 內容是 `board=ekh-bcm2711` / `version=20261019-142437` / `size=…`。這個 `version` 是 build 的時間戳,**不是** autocommit hold 比對用的 `BATMAN_VERSION`(`batman-autocommit:66, 274`) | 04 `dv-prov/payload-wsl9/metadata` |
| ✅ R9 | Go(副本 + 原生 1.26.4):`batman-prov/boot`、`provstore`、`sock` 都 ok。`proto` 在副本裡 FAIL,原因是 `open ../../../../tests/vectors/219-protocol/vectors.json: no such file`:我只複製了 `src`,相對路徑超出了副本的範圍,和產品無關(錯誤訊息本身就是證據) | `rv8/gotest.sh` 輸出 |
| ✅ R10 | mutant(`mut7.sh` 改成在副本上跑):5 個 mutant 全部 FAIL。<br>`persistnow-gen`:`boot_test.go:312 downgrade allowed`<br>`rc13-gen`:`:297`<br>`txn-readtxn`:`:363 malformed txn`<br>`persistnow-ident`:`:346 mismatch allowed`<br>`meshexpect-empty`:`:270 MeshExpect(claimed, "") = 0, want today`<br>真正的程式碼:`REAL CODE: PASS` | `rv8/run1.sh` |
| ✅ R11 | autocommit case 區塊的 stub:<br>**OLD c1e1c72**:`claimed:0 marker=mesh-joined -> NEED_MESH=0`、`marker=mesh-expected -> 0`<br>**HEAD**:同樣情況 `-> 1`;`claimed:0 marker=none -> 0`;`unclaimed:0 marker=mesh-joined -> 0`<br>99zz stub:**OLD** `key=[] -> me=0`;**HEAD** `key=[] -> me=today`、`CHANGE-ME-NOW -> 0`、`realkey -> today` | `tac.sh`、`t99zz.sh` 以兩個版本各跑一次 |
| ✅ R12 | 凍住時 p5 的掛載次數:**HEAD** `tick1 rc=1 rw-mounts=1; tick2 … 1; tick3 … 1`、`M6 RESULT: PASS`;**OLD** `1 -> 3`、`M6 RESULT: FAIL`。cfgsave2 HEAD `PASS=8 FAIL=0`。statecmp:**afb8f91** `fails=0`;**afb8f91^** `fails=2` | WSL root `rv8/run2.sh` |
| ✅ R13 | 我的探針 `TestRB8PersistNowRc10`:`--prov-get` 回 rc 10(p5 的 meta 壞掉,什麼都不複製,`batman-config-save:464`),overlay 是 legacy gen 1。結果 **`rc=0 why=persisted gen 1 (identity too: true)`**,也就是 FAIL。`TestRB8BootRc10Verdict`:`boot verdict="legacy" persists=[id=…]` | `rv8/rc10_test.go` |
| ✅ R14 | 31b4751 把 `feed/…/batman-config-save` 的模式從 100755 改成 100644。這沒有影響:Makefile 是用 `$(INSTALL_BIN)` 安裝(`Makefile:86`),`batman-autocommit` 本來就是 100644 | `git ls-files -s` |
| ✅ R15 | 04 的 busybox 支援 `find -mmin`,也有 `setsid`、`pgrep`、`mkfs.ext4`、`logger`;`/etc/rc.local` 最後一行是 `exit 0`(`:4`);`S95done` 存在;p5 = 1048576 個 sector(512 MiB);p6 還有 18.5G 可用 | ssh 唯讀 |

---

## 1. MAJOR

### M1. E1c 第 2 段(以及鏈 1 第 5 步)只抓一次證據,會和 autocommit 的 `HELD` 互相競賽,很可能誤判 FAIL,白白破壞一次 p5

- **情境**:
  - `e1c.sh:102-105` 一掃到 B 就跳出迴圈。`:111` **只抓一次** logread(`tail -12`),`:115` 要求裡面有 `HELD`。
  - `HELD` 要等到第一次健康 poll 才會記錄(`batman-autocommit:511-513`)。健康判定需要 OTS tenant 的 canary,以及這次開機的 drift 判定(`:459-481`)。
  - E3 實測「開機到 `HELD`」是 **92–105 s**;E1a 用同一種掃法,**83 s** 就找到 fresh trial。
  - 所以最可能的時序是:約 70–90 s 抓證據 → 還沒有 `HELD` → `dec=bad` → `:124` `abort_to_a` → rollback。
  - 結果是 p5 被 mkfs 又 dd 回去、04 離開 mesh 約 10–20 分鐘,E1c 的第 1 個事實卻沒有被測到。這是「結果不實」,不是安全問題。
- **另外**:`tail -12` 有可能把 `mesh join required: 0 (prov=unclaimed` 那一行截掉:helper、99zz、autocommit 的行數加起來可能超過 12。
- **修法**:
  - 找到 B 之後,每 5 s 輪詢一次,直到同時看到 `mesh join required: 0 (prov=unclaimed` 與 `is healthy and HELD`;如果先看到 `HOLD-COMMIT-DISCARDED`,或已經到 `t0+150`,才判定。
  - 輪詢時用 `logread | grep -E '<各個 pattern>'`,不要用 `tail -N`。
  - 鏈 1 第 5 步、第 7.2 步、第 8.6 步都要用同一個 helper 函式。
  - 負對照:沒有。這是判讀時序的問題,可以用 E3 的分布(92–105 s)當依據。

### M2. 鏈 1 第 7.1 步的負對照把 bind mount 掛在不存在的路徑上。路徑改對之後,這個機制本身成立

- **證據**:
  - R3:節點上沒有 `/lib/upgrade/platform-ab.sh`,live 的檔案是 `/lib/upgrade/platform.sh`。
  - R4 / R5:bind mount 在 stage 2 看得到;`switch_to_ramfs` 會把被 bind 那份的 `/lib/upgrade/*.sh` 和它自己的 `RAMFS_COPY_DATA` 一起複製進去;gate 在 ramfs 裡,`begin_write` 之前就會 die,之後重開回 `[all]`(= B)。
  - 所以把**目標改成 `/lib/upgrade/platform.sh`**,第 7.1 步就做得出來,也有鑑別力。
- **照現在寫法的後果**:
  1. `mount --bind X /lib/upgrade/platform-ab.sh` 因為目標不存在而失敗。如果腳本沒有檢查 rc,接下來的 `sysupgrade -n` 就是一次**真的**正向 OTA,A 被寫成 fresh 的 trial,「負對照」被判成功能失效。
  2. 如果實作的人改成「先建立 `/lib/upgrade/platform-ab.sh`」:`include` 依字母順序先 source `platform-ab.sh` 再 source `platform.sh`(`-` 0x2d 排在 `.` 0x2e 前面),`RAMFS_COPY_DATA` 會被後者蓋回去,負對照失去鑑別力;而且 overlay 裡多出一個檔,之後**每一次** sysupgrade 都會 source 它。
- **修法**:
  - 目標改成 `/lib/upgrade/platform.sh`;
  - mutant 用 `sed` 從 live 檔產生,並斷言 diff 只有 `RAMFS_COPY_DATA` 那一行;
  - `mount` 之後讀回 `grep -c prov-lock /lib/upgrade/platform.sh` = 0,做完 `umount` 再讀回 = 2;
  - 判讀改看 p6 `ota-trace.log` 的 `S2 STAGE-ROOT rc≠0` 和 `S2 EXPLICIT-RESTART`(正向則是 `S2 STAGE-ROOT rc=0`、`S2 APPLY rc=0`),不要只寫「sysup log」;
  - 斷言 `slot-A.protected` 不變:`begin_write` 才會刪它(`batman-slot:432-433`),而 die 發生在那之前,所以這個斷言有效。
- 這一項不影響 E1c。

### M3. E1c 的安全前提是「dead-man 武裝前,不會有任何東西 commit」,這依賴 hold 生效,但腳本沒有斷言 payload 的版本 == `VEXP`

- **證據**:
  - `e1c.sh:59` 只斷言 **A** 的版本 == `VEXP`;`:60` 只比 operator 給的 PSHA;`:92` 寫 hold = `VEXP`。
  - hold 只在 `want = $(version)`(也就是 B 的 `/etc/batman-build` 裡的 BATMAN_VERSION)時生效,否則記 `HOLD-COMMIT-DISCARDED`(`batman-autocommit:274, 286-290`)。
  - payload 的 `metadata` 裡的版本是時間戳(R8),不能拿來比。
- **情境**:
  1. operator 給的 PAY / PSHA 來自另一個 build。例如 wsl.12 重新 build 過,hash 後綴不同。這屬於「我們自己的錯」那一類 actor。
  2. hold 被丟棄 → unclaimed B 在約 95 s 自己 commit(NEED_MESH=0)。
  3. 這時如果 150 s 內掃不到:`abort_to_a` 不知道 FIP,只能等 A,但 B 已經 committed,而且約 168 s 會被 openmanetd 重開到新的位址。
  4. 900 s 後印出「needs a person」。
  
  這就是第 7 輪 M1 的卡死路徑:04 committed 在 fresh、沒有 dead-man 的 B 上,02 被隔離。
  
  如果有掃到,`:116` 會判 `dec=bad`、種下 dead-man,再 `abort_to_a` 走 rollback,是安全的。所以風險只出在「hold 被丟棄」**加上**「沒找到」。
- **修法**:
  - `apply` 完成、重開之前,以 `ro` 掛起 B 的 root 分割區(squashfs),斷言 `BATMAN_VERSION` == `VEXP`。也可以比 `root.squashfs` 的 sha 和 A 當初的 payload 是否相同。
  - 不符 → 先 disarm tryboot 並讀回(§4.5.0),再 `p5-restore`、刪 hold,然後 exit。
  - 負對照:給一份不同版本的 PAY → 必須在重開之前停下。

### M4. 現場生命週期缺口:P1 讓 unclaimed 節點可以 OTA(L44),而每一次這種 OTA 開的都是 fresh 槽,openmanetd 在 trial 中自己重開,會和 autocommit 的 commit 互相競賽。Pi 3(ekh-bcm2710)完全沒有證據

- **證據**:
  - unclaimed 的 p5 沒有 seed,96 什麼都不還原 → `99-halow-identity` 個人化、`dhcpconfigured=0` → openmanetd 保留位址後重開(F8;E1a 實測約 **168 s**,F34)。
  - autocommit 對 unclaimed 判 NEED_MESH=0,Pi 4 上約 95–105 s 就 commit(E3 / §13 A-M1)。Pi 4 的餘裕約 60 s。
  - P1 之前,未 seed 的 p5 會被 #202 閘擋下 OTA,所以**這條路徑是 P1 新開的**。
- **現場情境**:
  - **Pi 3**(民用 C0–C3,主力 SKU):開機比較慢、期限 900 s、也跑 docker canary。沒有任何量測。
  - 如果 openmanetd 的重開先到:trial 沒有 commit 就結束 → 回到舊槽,不記 `bad-slot` → **這種 OTA 每次都會無聲失敗**。
  - 如果重開剛好落在 `batman-slot commit` 寫入時:Pi 3 的 commit 是 p7 的 raw sector 寫入。autocommit 自己的註解說「在它寫入時重開會撕裂 autoboot.txt = 變磚」(`batman-autocommit:205-207`),所以 autocommit 用 claim 擋住**自己的** watchdog,但擋不住 openmanetd 的 `reboot`。⚠️ 這是推論:procd 送 SIGTERM / SIGKILL 時,dd 是否寫到一半,沒有實測。
  - 設計對 Pi 3 只寫了「沙箱 + DRYRUN」,§13.3 的理由是「找不到 fresh 槽」。但量這個競賽不需要找到它,只要 serial 或 p6 log。
- **修法**(擇一,並寫進 §5.7 / §10 / §11):
  - (a)Pi 3 bench 用 serial 量「開機到 commit」對「openmanetd 重開」的時間分布,而且要在 docker canary 有 tenant 的條件下量;
  - (b)產品端讓 openmanetd 的保留重開等到 trial 決定之後(trial 中延後到 commit 之後),或讓 autocommit 在 commit 前取得一個 openmanetd 也會遵守的 reboot 抑制;
  - (c)至少在 §10 回報上層,在原單的 checklist 列為已知、未處理,並寫明影響。
  - 驗證:Pi 3 上 unclaimed 節點的 OTA 連做 N 次,每次都 commit,而且 autoboot 讀回正確。

---

## 2. E1c v2 出口路徑逐一追蹤(回答「會不會卡死 / 丟 p5 / dead-man 誤觸 / 誤報 DONE」)

| 路徑 | 結果 | 依據 |
|---|---|---|
| 前置不符(`:59-62`)、payload sha 不符、snap 失敗、copy 失敗 | 沒有任何破壞性動作;`STAGED=0`;trap 只印結果 | `:58-67` |
| dead-man 寫入失敗(`:82`) | 同上 | — |
| p5 忙、mkfs 失敗 | 還沒 apply;mkfs 失敗時印出手動 `p5-restore` 指令。⚠️ mkfs 之後 p5 可能是半格式化的狀態,需要人處理(MINOR m4) | `:87-90` |
| apply 沒有 arm | 刪 hold、`p5-restore`。⚠️ B 已經被 `begin_write` 標成 BAD,S0 被破壞,需要 brewrite(寫進報告) | `:94`;`batman-slot:423-436` |
| p5 在重開前已經被 seed | 刪 hold 後 exit。⚠️ **tryboot 仍是 armed,p5 也沒有 restore**,報告沒有寫 | `:96`(m4) |
| 重開後落點落空(plain reboot no-op,F29) | 150 s 後 `abort_to_a`(不知道 FIP)→ A committed → `p5-restore`、刪 hold。**tryboot 沒有 disarm**(m3) | `:98, 106-107, 36-43` |
| 在 trial 中 abort(HELD / DISCARDED / 沒有 AP 等斷言失敗,或 dead-man 讀回失敗) | 在 B 上 rollback + `reboot committed`,不留 `bad-slot` → A。B 的 rc.local 可能已經有 dead-man,但 cleanup 確認回到 A 就會 cancel | `:38, 118-124`;`cmd_rollback:740-748` |
| openmanetd 在 release 之前重開了 HELD 的 trial | tryboot 是一次性的 → A committed,但 p5 這時是 B 寫的(unclaimed、身分 Y、未 seed)→ A 凍住。之後 `abort_to_a` 做 `p5-restore` ✅;但 A 這次開機的 verdict 仍然是 `unknown(identity-mismatch)`,還留著 `cfgsave-frozen`,helper 也被停掉、沒有重啟(m4) | `boot.go:191-210`;`prov-base-254.sh:176` |
| release 之後確實 commit 了,但 `:127` 讀不到 | `abort_to_a`:如果 B 還在 FIP → rollback → A ✅;如果 B 已經換位址 → 900 s 後印「needs a person」。這時 rc.local 的 dead-man 已經武裝(`:123` 已讀回),25 分鐘後回到 A ✅(訊息有誤導,屬於 MINOR) | — |
| commit 之後找不到 | `exit 1`,cleanup 印出「dead-man stays ARMED」→ B 這次開機的 rc.local 在 1500 s 後執行 dead-man ✅ | `:141` |
| 正常 DONE | dead-man 以 `setsid` 執行 → `p5-restore`(失敗也照樣 rollback)→ A。斷言 `P5-RESTORED <run> sha=<快照前 16 碼>`、`rc=0`、prov-state 為 legacy、`--check` = 0、02 是 committed。cleanup 做 cancel 並刪掉腳本 ✅ | `:149-162` |
| 主機在任一階段死掉 | 在 dead-man 武裝之前:HELD → openmanetd 或期限讓它回到 A,A 用自己的設定把 p5 重新寫一份(不是快照,但功能上等價),快照和 dirty 都還在 ✅。在武裝之後:dead-man ✅ | — |
| dead-man 之後在健康節點上誤觸 | 只在 `active=B` 時動作;回到 A 時是 inert。DONE 之後腳本被刪;`finish` 之後 `find $D/p5.img` 不存在 → 不動作 ✅。剩下的窗口是「DONE 之後、brewrite 之前,又開進舊的 B overlay,而且 cleanup 沒能 cancel」;6 h 期限在這台時鐘上不會生效(m5) | `:71-74` |
| 誤報 DONE | 沒有找到。`committed` / `found` 都來自 ssh 回傳的 slot,dead-man 的證據要求讀回 sha。弱點只有:`BT` 為空時 `rebooted=0`(m6) | — |

結論:**p5 不會丟**(快照在 p6,任何寫回都先驗 sha)。**04 會卡死的路徑只剩 M3 一條**。

---

## 3. MINOR

- **m1 rc 10 的「不降代」不成立(產品 + 上層)**:
  - `PersistNow` 與 `boot.Run` 的 case 10,都會把 overlay 的紀錄(**任何 gen**,而且連同身分)寫進一個 meta 壞掉的 p5(R13)。
  - 這是依照上層 §4.2 第 10 列「以 overlay 為準」做的,但遇到「rollback 或舊槽(L12 / L63)加上 SD 損壞的 meta」時,claimed 的 cbor 會被 legacy 的紀錄蓋掉。
  - 31b4751 的 commit 訊息與 `TestPersistNow` 說「a generation is never lowered」,對 rc 10 來說不是真的。
  - **修法**:
    - `--prov-get` 在 rc 10 時仍然輸出原始的 cbor(標為不可信),讓 helper 解出 gen 與 state;解出的 gen 比較高或 state 不同 → `unknown(prov-corrupt)`,不寫;
    - 這件事寫進 §10 回報上層;
    - 補上我的 `TestRB8PersistNowRc10`(real 版本目前 FAIL;修好之後當作負對照)。
- **m2 第 7 輪 B-m7 的前半段還沒處理**:
  - `identity_mismatch` 仍然要兩邊都有 `sha256` 才成立(`batman-config-save:146-148`)。
  - p5 有 `prov.meta` 但 `identity/prov` 不見時,helper 判 `identity-lost`(凍住),但 `--on-join` / `--save` 照樣把這一槽的 host key、`authorized_keys`、shadow 寫進那份 p5。
  - §13.4 把 B-m7 只對應到提示文字。
  - **修法**:寫入模式遇到「p5 有 `prov.meta` 但身分不完整」→ rc 1,並設 `cfgsave-frozen`。
- **m3 E1c 用的是 plain reboot,沒有落點斷言,也沒有 disarm**:
  - `:98` 是 `(sleep 2; reboot)`,和 §13.3 第 3 步、§4.5.0 規定的「受控重開(停服務、sync、`reboot -f`)」不符(F29)。
  - 落在 A 上時,要等滿 150 s 才 abort,而且 abort 時不 disarm tryboot。下一次非預期的重開會進入一個沒有 hold 的 B trial(從還原的 p5 建),健康就 commit,S0 就這樣無聲地被破壞了。這是第 7 輪 m2 仍未處理的部分。
  - **修法**:
    - 照 §4.5.0 做受控重開;
    - 每輪掃描前先看 10.41.1.3:如果是 A 而且 boot_id 是新的 → 用 vcmailbox 讀 tryboot,armed 就 disarm 並讀回 → `p5-restore` → 刪 hold → exit。
- **m4 abort 之後 A 處於降級狀態,也沒有驗證**:
  - `p5-restore` 會停掉 `joinwatch`、`batman-provhelper`、`batman-provd`(`prov-base-254.sh:176`),cleanup 只重啟 joinwatch。
  - 如果 A 是在 B 寫過身分 Y 之後回來的,這次開機的 verdict 是 `unknown(identity-mismatch)`,`cfgsave-frozen` 也還在。
  - `abort_to_a` 的 `p5-restore` 結果沒有斷言;走期限 revert 那條路時,`bad-slot` 會留下來,而且沒有印出。
  - `:96` 的出口沒有 `p5-restore`,也沒有 disarm。
  - **修法**:abort 一律依序做 `p5-restore`(斷言 `P5-RESTORED`)→ disarm 並讀回 → `batman-slot reboot committed` → 斷言 prov-state 為 legacy、`--check` = 0;`bad-slot` 有就印出。
- **m5 dead-man 的 6 h 期限在沒有 RTC 的節點上是無效的**:
  - 04 的時鐘是 2025-07-17,主機是 2026-10-21(R7)。fresh B 的時鐘是從 build 日期(2025-06-23)起算,所以 `p5.img` 永遠看起來是「未來的檔案」,`find -mmin -360` 永遠成立 → 期限永遠不會到。
  - 反過來,萬一 NTP 對到時,時鐘一次往前跳 15 個月,dead-man 就**完全不會動作**。這就是「需要它的時候它不動」。
  - **修法**:改用和 run 綁定的條件:`$ST/dv-prov-dirty` 的第 1 欄 == `$RUN` 才動作(`finish` 會刪掉 dirty),並保留「快照存在」的檢查。
- **m6 E1c 判讀的鑑別力**:
  - 沒有在跑之前斷言 `--check` rc 0,所以跑完後如果 `check_rc≠0`,無法歸因;
  - `BT` 為空時 `rebooted=0` 是靜默的;
  - recorder 和 timer 在 ssh session 裡用 `&` 啟動,沒有 `setsid`,讀回也在同一個 session 裡。dropbear 在 non-pty session 結束後,子程序會不會留下來,⚠️ 沒有實證(第 7 輪 A-M1 要求「以新的 ssh 讀回」)。
  - **修法**:前置斷言 `--check` = 0;用 `setsid` 啟動;換一條新的 ssh 讀回 `timer≥1`,而且 recorder 的檔案在增長。
- **m7 鏈 1 的文字有錯,照寫的做不出來**:
  - 8.7 的 `batman-autocommit` 少了 `run`:沒有它會走 usage,exit 2(R6)。
  - `AUTOCOMMIT_TIMEOUT=60` 是絕對 uptime:poll 迴圈不會執行,只有開頭的判定行。這正好是要的,但 DRY 的 `log()` 仍然寫進 syslog / kmsg(`:62`),會多出「mesh join required: 1」與「NOT committed … watchdog reverts」兩行,之後對 logread 的判讀要能容忍這兩行。
  - DRY 的 watchdog 能結束,依賴的是真的 `autocommit.wd` 已經存在,這點要寫明。
  - 8.x 的 A / B 是 claimed、LOCKED,「找到」的判定必須用 publickey;E1c 的 `is_b` 是 `none` 登入,在這裡會失敗。
  - 7.2 的 A 是 fresh 的 unclaimed trial,openmanetd 約 168 s 會重開(F34),要套用 150 s 的時間預算,而且重開本身就會把節點帶回 B。
  - 第 4 步說「沒有 `ota-armed.mesh`(= L42)」,但 04 現在就有一個 `dceb9f18 B joined`(R1)。要嘛前置先移走,要嘛把文字改掉。
- **m8 鏈 1 第 7 步之後,dead-man 的承諾不再成立**:
  - 從第 7 步起,A 已經被重寫過:第 7 步是 fresh unclaimed,8.6 是由 B 的 p5 建的 claimed、身分 Y。
  - 這時 dead-man「restore p5 → rollback 到 A」得到的是一個凍住的 A:身分 Y 對上快照的 X,位址可能也變了。登入方式不一定:可能是 `none`(unclaimed),也可能要 lab key(claimed)。
  - 這不是 §3 那一列所說的「回到已知良好的 A」。
  - 另外,每次開進 B 只有 1500 s;第 8 步的「找到 + 寫 key + 認領 + sysupgrade」要在 B 的同一次開機內完成,否則 dead-man 會在認領進行到一半時觸發。
  - **修法**:
    - 生命週期表加一列「第 7 步之後主機死掉 / dead-man 觸發」= 需要人處理 + 通知;
    - 或者第 7 步之前 disarm dead-man,只靠 hold 與期限;
    - 寫明每一段 B 開機的時間預算。
- **m9 02 的隔離時間**:鏈 1「超過就把鏈 1 拆成兩個 lease,中間讓 04 回到 mesh」在第 4–8 步之間做不到,因為 B 沒有 mesh key。應該照實寫:02 的 joinwatch 會在 3600 s 時重開一次(F9),並帶 #132 的風險。
- **m10 文件與程式不一致**:
  - §3 寫「`finish` 刪 p6 檔」,但 `finish` 只刪 `$D`、標記、dirty(`prov-base-254.sh:204-208`):
    - `e1c.cancel`、`e1c-deadman.log` 一定會留著;
    - FAIL 時 `e1c-deadman.sh` 也會留著;
    - P9 看不到這些檔。
  - §4.5.1 寫「upper 的 tar 不含 identity 的私鑰,私鑰另存」,但 `snap` 是整個 upper 打 tar(`:127`)。改文字,或改程式。
- **m11 round-7 產品修正的 shell 回歸測試不在常規全套裡**:
  - autocommit 的 `claimed:0 + marker`、99zz 的 placeholder 規則、`cfgsave-frozen`、cfgsave2 8/8,目前只存在 scratchpad。
  - 目前 CI 不跑 `go test`(F13)。
  - §5.1 要明列 `prov-unit-autocommit`、`prov-unit-99zz`,以及 `prov-unit-cfgsave` 的凍住案例,並附上舊版的負對照。舊版的結果我跑過了,見 R11、R12。
- **m12 99zz 與 Go 的判法仍然不一致**:99zz 只要「任一個 mesh 介面是 placeholder」就判 0;helper 不在的時候,這是 fail-open。改成「全部都是 placeholder 才判 0」只要一行。
- **m13 `--seed` 會寫 `mesh-expected`**(`batman-config-save:501-505`):
  - batman-slot 自己的提示會叫 operator 跑 `--seed --reformat`。
  - 一台 claimed + placeholder 的節點照做之後,之後每次 OTA 都會要求鄰居 → revert、寫 `bad-slot`,直到它真的入網。
  - 這是 fail-closed,但文件沒寫,要在 §4.8 / §10 寫明恢復方式。
- **m14 `prov-claim-254.sh` 草稿**:第 7 輪 A-m8 的項目還開著:
  - `claim.secret` 的前 16 hex 帶回了主機;
  - `overlay-restore` 和重開分成兩條 ssh;
  - canary 只掃 `claim.secret`;
  - §5.3 的覆蓋不完整;
  - compare 要等 E4 產生允許清單才可能過。
  
  不影響設計判定,只是記錄。
- **m15 E1c 沒有 lease**:沒有取得 prov lease,也沒有和 H1 `bt/lease` 互斥。這是第 7 輪 m5 的後半段。

---

## 4. 確認成立(✅,附證據)

- **第 7 輪 B-M2 / A-M7(mesh_expect fail-open)**:Go、99zz、autocommit 都改了,負對照有效(R10 `meshexpect-empty`、R11)。marker 規則讓 `claimed:0` 在 p6 有 `mesh-joined` / `mesh-expected` 時要求鄰居;唯一會刪這兩個 marker 的是 `network.leave`(`main.go:228`、`node.go:73`)。認領的 `--save` 不會寫 marker(只有 `--seed` / `--on-join` 會寫,`:501-505`),所以鏈 1 第 8 步的前提成立。
- **第 7 輪 B-M3**:`PersistNow` 不呼叫 `boot.Run`,不動 `.stage`、`.txn`、`prov-state`;它擋下了 bypass、`.txn` 存在、身分不一致、gen 降代、rc 13 的 sn 不同這幾種情況,每一條都有 mutant 會 FAIL(R10)。例外是 rc 10(m1)。
- **第 7 輪 A-M6**:凍住的節點只會 rw 掛載一次 p5(R12)。joinwatch 把 config-save 的輸出丟掉(`joinwatch:147`),所以每 15 s 也不會留下 log。
- **第 7 輪 B-M6**:state 的比對規則有鑑別力,舊版有 2 項 FAIL(R12)。`ota-armed.mesh` 只允許從「存在」變成「不存在」,這和 commit 會刪它的行為一致。
- **第 7 輪 B-M1 / M5、A-M1~M5**:E1c v2 做到了以下幾點:
  - 在 HELD 時種下 dead-man,讀回後才 release;
  - 「找到」以 ssh 回傳的 slot 與 boot_id 為準;
  - dead-man 以 `setsid` 執行,`p5-restore` 失敗也照樣 rollback;
  - 不再比原始映像的 sha;
  - 每個出口都會 cancel;
  - 使用 `mktemp`。
  
  例外見 M1、M3、m3–m6。
- **鏈 1 第 7.1 步的機制**(把路徑改成 `platform.sh` 之後):bind mount 撐得到 stage 2 與 ramfs,die 發生在 `begin_write` 之前,而且會重開回 B(R3–R5)。
- **鏈 1 第 8.7 步的 DRYRUN**(補上 `run` 之後):會依 boot_id 重讀 prov-state 和 marker,不消耗 hold,不寫正式的 ACLOG,不 commit,也不重開(R6)。新版印 `neighbours required (fail-closed)` / `mesh join required: 1`,舊版的規則會印 0,所以有鑑別力(R11)。
- **`PROV_BASE_TEST_ROOT`**:只會改變 `BASE`、`ST` 的前綴,不影響 `P5`、`LOCK`、`MARK`、`/overlay/upper`。節點上不會有人設它;能設 root 環境變數的人本來就是 root,所以不是新的權限邊界。§3 的說法成立。
- **verdict 每次開機固定**:§3 已寫明;autocommit 只讀 boot_id 相符的那一行(`:402`)。

## 判定
**REJECT**(0 BLOCKER / 4 MAJOR / 15 MINOR)。

順序建議:
1. **E1c**:修好 M1(輪詢 HELD)、M3(重開前斷言 B 的 BATMAN_VERSION)之後就可以跑。m3–m6 建議一起修,都是幾行。
2. **設計**:修 M2(`/lib/upgrade/platform.sh`)、M4(Pi 3 上 unclaimed OTA 對 openmanetd 重開的競賽:量測,或寫明並回報上層),m7–m10 一併處理。
3. **產品**:m1(rc 10)、m2 回報上層並修正,附負對照。

修完後,依規則整份重審。
