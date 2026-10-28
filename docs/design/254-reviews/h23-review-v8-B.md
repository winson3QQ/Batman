# h23 設計審查 v8 — 審查者 B(全文,重點 §17)

對象:`docs/design/254-h23-harness.md` @ 46819e6(harness/254-h23),§0–§17,§16/§17 優先。
原始碼:rc 樹 `/home/yello/Batman-rc` @ d0643d5(P1b 1f82e36 + harness b6d562a)。唯讀;沒有 ssh 上節點。
證據標記:✅ 原始碼或實跑看過;⚠️ 推論或未在真機查;❌ 沒查。

## 0. 結論

**判定:REJECT(只針對 §17;§0–§16 沿用 v6/v7 的 APPROVE,這輪沒有新發現)**
1 BLOCKER / 3 MAJOR / 12 MINOR。

最重要的問題:L51 的 mutant bind 到 `/usr/lib/batman/platform-ab.sh`,但 sysupgrade 根本不 source 那個檔,所以 L51 的負對照永遠打不中。另外三個 MAJOR:前提「04 = member」照 §4.3 的單位規則做不出來;A 槽 dry-run 留下的背景 watchdog 會刪 `ota-armed.mesh`,讓 L43 正向臂可能因為別的原因 PASS;harness 改寫 p6 `prov-state` 第 3 欄(安全記憶)沒有宣告擁有權,也沒有在死掉時還原。

## 1. 先從 §17 依賴的事實查起(✅ 原始碼)

| 依賴 | 查證 | 結果 |
|---|---|---|
| L38 等待迴圈在 `:404` | `batman-autocommit:402-404`:`prov_read` 用 awk 取本次 boot_id 的第 2/4/6 欄;writer=99zz 時每 1 s 重讀,最多 60 次 | ✅ |
| L43 / member 臂在 `:419-421` | `:419` `ab` = boot-reasons `tail -n 2 \| head -n 1` 的 `boot_id=` 值(95 寫 `cut -c1-8`,`95-batman-storage:380,708`),與 `_ab_arm_mesh` 寫的 `cut -c1-8` 一致;`:420` 三欄、boot8、`$SLOT`、`radio` 全對才 `NEED_MESH=0`;`:421` 只有在檔不存在或空時才印 `no usable` | ✅ |
| dry-run + FORCE_TRIAL 在 committed 槽跑同一段 | `:399-425` 沒有任何 DRY 分支;`:322` FORCE_TRIAL 跳過 is-trial;`SLOT=$(batman-slot active)` = A;`:382-383` `AUTOCOMMIT_TIMEOUT` 是**絕對 uptime**,`MIN_WINDOW=0` → `DEADLINE = uptime+150`,`START = 當下 uptime`;`real_tryboot` 回 0 → `REVERT=1` → 起背景 watchdog(`:432-434` `( revert_watchdog ) &`) | ✅ 同一段程式,數值如上 |
| L51 的 arm 在 `_ab_arm_mesh` | `platform-ab.sh` `_ab_arm_mesh`:caller `/sbin/procd*` + `$RAM_ROOT/sbin/upgraded` + `_ab_live_sysupgrade`;`lastjoined` 不空 → `joined`;否則取樣 | ✅ |
| sysupgrade 用的是哪個檔 | `98-batman-sysupgrade:7-10`:`cp -f /usr/lib/batman/platform-ab.sh /lib/upgrade/platform.sh`(新 overlay 第一次開機);`platform-ab.sh:3`、`batman-slot:3`、`otatrace.sh:3` 都寫 sysupgrade source 的是 `/lib/upgrade/platform.sh` | ✅ → BLOCKER-1 |
| `sock: unexpected` | `sock/sock.go:74` | ✅ 與 §17.1 相符(但看 m6) |
| stage1 L38/L42/L43/L51 定義 | `254-stage1-impl.md:368,372,373,379` | ✅;L38 還有「boot_id 不符 → 今天的規則」這一支(m2) |

## 2. 發現

### BLOCKER-1 L51 的 bind 目標不是 sysupgrade source 的檔 → 負對照不可能生效
- **情境**:照 §17.2 把 `misc-L51` 的 `platform-ab.sh` bind 到 `/usr/lib/batman/platform-ab.sh`,然後 `pr_ota_b`。sysupgrade 第 1 段、procd 呼叫的 `validate_firmware_image`、第 2 段都是 `include /lib/upgrade`,也就是 source `/lib/upgrade/platform.sh`(98 在 overlay 放的副本)。mutant 不會被執行,otalog 照樣是 `ARMED-MESH m=joined`,harness 判「mutant 無效」FAIL。這是 fail-closed(不會假 PASS),但這個單位永遠過不了,而且很容易被人「修」成放寬判定。
- **證據**:✅ `98-batman-sysupgrade:7-10`;✅ `platform-ab.sh:2-5` 檔頭;✅ `grep -rn platform-ab` 沒有任何 runtime source 這個路徑(只有 98 拿它當複製來源、tmp-trust 拿它當 lint 目標)。⚠️ procd 的 `validate_firmware_image` 由 procd 直接 fork/exec,在初始 mount namespace、沒有 ujail(根據 OpenWrt procd 的記憶,本輪沒有在 04 上查;F33 的 `caller=/sbin/procd` 是間接佐證)。
- **修法**:
  1. bind **來源** = 變體 payload 抽出的 `usr/lib/batman/platform-ab.sh`;bind **目標** = `/lib/upgrade/platform.sh`。
  2. 前置斷言 `cmp /lib/upgrade/platform.sh /usr/lib/batman/platform-ab.sh`(04 的 A overlay 副本要等於 release;⚠️ 本輪沒查 04);bind 後斷言 `grep -c WBOX-misc-L51 /lib/upgrade/platform.sh` = 1。
  3. 正向證據:mutant 新增的 `otalog` 見證行(帶 `caller=/sbin/procd`)必須出現在 otalog;沒有 = INVALID(mutant 沒被執行),不是「mutant 無效」。
  4. ⚠️ 這是第一個在 bind 掛著時跑真 sysupgrade 的單位(其他 bind 單位都不 OTA)。第 2 段 `install_file /lib/upgrade/*.sh` 會把 mutant 抄進 ramfs(無害,因為 mutant 只改 arm),但 `/tmp` move、pivot、umount 遇到一個從 `/tmp/run/...` bind 出來的檔會怎樣沒有證據。在 E-H 實證加一項:bind 一個內容相同的 `platform.sh` → V hold OTA → 落點斷言照常;或改成在 procd 驗證之後、第 2 段之前 umount(這個時點抓不到,不建議)。

### MAJOR-1 「04 = member」這個前提照 §4.3 做不出來;L51 還需要的是**fleet mesh** 的 member
- **情境**:§17.3 寫「L42 / L51 需要 04 = member(放在 `prov-netjoin-254` 之後、`prov-leave-ota-254` 之前)」。但 §4.3 每個單位的 `pr_end` 都會 `pr_restore` 回 S0(netjoin 是 F 型),`pr_begin` 的 P9 子集也要求 S0。上一個單位留下的 member 狀態不存在,排序沒有用。另外,L51 的前置是 `joinwatch.lastjoined` 不空,也就是**本次開機真的入過網**。如果 04 用 `provgen.py` 的測試網值成為 member,它跟 02(fleet mesh)不會是鄰居,`lastjoined` 一直是空的,正向臂的前置不會成立。
- **證據**:✅ §4.3 步驟 2–4、§4.3 單位骨架;✅ `joinwatch:135`(F33,唯一寫者,join 時才寫);✅ `platform-ab.sh` `_ab_arm_mesh` 的 `m=joined` 條件。
- **修法**:在 §17.3 寫出單位內的程序。照 `prov-netjoin-fleet-254` 的寫法:lab 金鑰 claim → `net-apply --first`,fleet 值經 fd 3(§7 的 secrets 規則、canary 照用)→ 斷言 `batctl n` 有 02 且 `lastjoined` 不空 → L51。L42 只要 member、任何網都行,但沿用同一個狀態最省事。還原 = F(p5-restore + overlay-restore + 重開),02 不動。joinwatch 在單位期間必須是 running 的,寫成前置斷言(deadman 會起 joinwatch,表示有些單位會停它)。claim 會讓 04 LOCKED,沿用既有還原。同時更新 §7.2 副作用表。

### MAJOR-2 A 槽 dry-run 的背景 watchdog 會在期限刪 `ota-armed.mesh`,L43 正向臂可以因為「檔不見」而 PASS
- **情境**:FORCE_TRIAL 讓 `REVERT=1`,dry-run 起 `( revert_watchdog ) &` 子殼(`:432-434`)。chain1 8.7 的寫法只 `kill $p`(主程序),殺不到這個子殼。在 committed A 上,真的 main 開機就退出了,沒有 `$RUNDIR/autocommit.wd`,所以第一個 dry-run 的 watchdog 會真的跑:到 `DEADLINE` 時拿 `$RUNDIR/autocommit.decided`(真的 claim 路徑)、做 `rm -f "$ST/ota-armed.mesh"`(`:237`),**這一行在 `:240` 的 DRY 判斷之前**,然後才印 REVERT。後果有三:
  1. L43 正向臂只斷言 `mesh join required: 1`。如果上一臂(或 L38)留下的孤兒 watchdog 在這段期間刪掉了 harness 寫的檔,`a` 會是空的,`:421` 照樣得到 `required: 1`。正向臂 PASS 了,原因卻是「檔不見」而不是「boot_id 不符」,判別力就沒了。整個單位還是會被負對照(mutant 也得到 1 → 「無效」FAIL)擋下,所以結果是假 FAIL,不是假 PASS,但正向臂本身不成立。
  2. L43 對照臂 / 負對照會因為檔被刪而假 FAIL。
  3. 如果 L51 / L42 排在 dry-run 之後、還在孤兒的期限內,arm 檔可能在 arm 與重開之間被刪 → B 得到 `no usable` → L51 負對照假「mutant 無效」。
  另外,第一個 dry-run 留下的 `autocommit.wd` 會讓同一次開機後面所有 dry-run 都沒有 watchdog(不影響 decision 行,但要知道)。
- **證據**:✅ `batman-autocommit:207-215,233-240,432-434`;✅ `chain1-254.sh:347`(只 kill 主 pid,而且沒有用 FORCE_TRIAL;§17.3 說「同 chain1 8.7 的寫法」並不精確)。
- **修法**:
  - 每一臂用 `setsid` 起 dry-run,讀到 decision 行(或逾時)就 `kill -- -<pgid>`,並斷言沒有任何 `batman-autocommit` 程序殘留後才進下一臂。四個 misc 的順序固定為 dry-run 臂全部在 L42 / L51 之前,而且每臂都要殺乾淨。
  - L43 正向臂斷言整行 `mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)`,**且**本次 stdout 沒有 `no usable`,**且** decision 行之後讀回 `ota-armed.mesh` 仍是 harness 寫的內容。L43 也寫明 `AUTOCOMMIT_TIMEOUT`(目前沒寫;預設會變成 `START+300`)。
  - 產品面:dry-run 會刪 p6 `ota-armed.mesh`、拿真的 claim 路徑,這是 dry-run 接縫的副作用。記進 #254 checklist(一行),不在本 PR 改。

### MAJOR-3 harness 改寫 p6 `prov-state` 沒有宣告擁有權;第 3 欄是安全記憶,harness 死掉時留下偽值
- **情境**:L38 第一臂寫 `<boot_id> 99zz - unclaimed - 0`,第 3 欄(`last_known_state`)被寫成 `-`。這一欄有三個讀者:`batman-prov-lock`(S13,每次開機,`init.d/batman-prov-lock:62`)、96(`:70,105`)、`batman-slot rollback_lock_gate`(`:774`)。p5 讀不到的時候,`prov_lock_decision` 只靠它決定是否 LOCK(`prov-lock.sh:65-71`)。helper 下次開機重寫時,只要 verdict 不是確定值,就**沿用前一個第 3 欄**(`boot.go:281-290`)。所以 harness 在兩臂之間死掉時(deadman 不還原 STATEFILES,P9 也不查),偽造的 `-` 可能一直留著,把 claimed / member 的記憶抹掉 → fail-open。另外,§17 把 harness 變成 `prov-state` 的第三個寫者(99zz、helper 之外),§3 沒有這一列;單位內 helper 若被 restart(procd respawn),`boot.Run` 會重寫 `prov-state`,污染那一臂。還原排在「單位結尾」,但同一單位後面還有 L42 / L51 要用到這個狀態。
- **證據**:✅ `99zz-batman-prov-state`(格式、第 3 欄語意);✅ `boot.go:276-290`;✅ `prov-lock.sh:53-71`;✅ `batman-slot:771-776`;✅ `prov-base-254.sh:29,108-120`(snap / compare 有涵蓋 prov-state,但只在 `pr_restore` 用)。
- **修法**:
  - 白箱只改第 2 / 4 / 6 欄。第 1 欄 = 本次 boot_id,**第 3 欄 = 快照值**。tmp + `mv`、0600(awk 讀到半寫檔會讓 `pr` 為空)。
  - 每一臂結束**立即**寫回快照行,不要等單位結尾。斷言 helper pid 在整臂期間不變(變了 → INVALID)。
  - §3 加一列:「p6 `prov-state`:99zz / helper(產品);prov-misc 的 dry-run 臂期間 harness 是白箱寫者,只在 lease 內、helper 不重啟時寫」。p6 `ota-armed.mesh` 同樣加一列(`_ab_arm_mesh` 寫,autocommit commit / revert 刪,harness 白箱寫)。
  - deadman 或 P9 補一條:`prov-state` 第 2 欄 ≠ `helper` 且 uptime > 120 s,或第 3 欄 ≠ 快照 → FAIL 並印還原指令。也可以讓 deadman 直接寫回 `$DVD/<run>` 裡的快照行。

### MINOR
- **m1 L38 第一臂可能沒有走到切換**:如果 dry-run 到達 `prov_read` 時已經過了 20 s,第一臂讀到的直接是 `helper`,PASS 但沒有走過「從 99zz 切到 helper」。負對照會抓到(那時 mutant 也會是 member → 判「無效」),所以不會假 PASS。修法:改寫前先確認 dry-run 已經在迴圈裡(它的 pid 有 `sleep 1` 子程序,或 harness 已收到 `gate until uptime` 行),並在文件寫明真正有判別力的是第二臂(≥ 60 s)。
- **m2 L38「boot_id 不符 → 今天的規則」沒有測**(stage1 `:368`)。加一個便宜的臂:`prov-state` 第 1 欄用別的 boot_id → `prov=none`。
- **m3 L42 / L51 只 mutate 保護的一半**:L42 = 「apply 不寫檔」(mutant)+「缺檔 → fail-closed」(`:421`,沒有 mutant);L51 = 「arm 寫 joined」(mutant)+「第 3 欄 ≠ radio → 要鄰居」(`:420`,沒有 mutant)。對 autocommit 做 dry-run mutant 幾乎零成本,建議補。此外 L42 的負對照用 mutant `batman-slot`(root 的槽寫入器)去做「apply 後出現檔」,和 harness 在真 apply 後直接寫檔的效果一樣,而 B 接受 radio 檔已由 L43 對照臂證明,風險高、價值低。另一個風險:bind 期間若發生真 OTA,`RAMFS_COPY_BIN` 會把 mutant `batman-slot` 抄進 ramfs,第 2 段 apply 寫出 `radio` 檔,把 joined 蓋掉(fail-open)。§7 要寫明,或改成上面說的白箱寫檔。
- **m4 成本**:L42 / L51 的正向臂分別等於 (6a) 和 (7) / (3) 已有的斷言,可以共用,省 2 次 trial。§17.4 沒有算 `pr_brewrite`(單位寫過 B → 每次約 14 分,§7.3)。新增的 trial 超出使用者核准的 H3-U3(22–23 h、04 OTS 斷約 7.5 h),要回報使用者。
- **m5 L42 程序沒寫清楚**:hold 要在 apply **之前**寫並 `cmp`(否則 harness 在 apply 後死掉 → 重開就是沒有 hold 的 trial);落點斷言照 `pr_ota_b`(DT tryboot=1、目標槽、`HOLD-COMMIT`、無 DISCARDED);重開指令寫明(tryboot 已 armed 時 `batman-slot reboot committed` 會退成 plain reboot,`batman-slot:816-826`)。
- **m6 §17.1 說 `sock: unexpected` 已由 `prov-sec-sockdir-254` 測**:但 §4.5 的白箱只有 symlink 和 `chown 471`,`sock.go:74` 的「目錄內有其他東西」分支不在裡面。補一案(root 預放一個普通檔 → `sock: unexpected … refusing to start`),或在 §9 明列為缺口。
- **m7 §6.2 `prov-misc-254` 那一列還是舊文字**(L38 = 96 superblock、L51 = sock),會有兩個版本。改成「見 §17」;同列的 L11 / L9 / L10 / L27 / L3 也確認一下有沒有定義負對照。
- **m8 bind 檔的契約**:autocommit / batman-slot 的副本要 root 0755;推上節點後節點端 sha = 主機 sha;每次負對照前 `grep -c WBOX-misc-LNN <目標路徑>` = 1;mutant 的見證 log 行是「mutant 有被執行」的必要證據(沒有 = INVALID)。
- **m9 §7.2 補 A 槽 dry-run 的副作用**:p6 `ota-trace.log` 多出 `AC START` / `UNHEALTHY`;OTS 節點上 canary 的 import 與 prune;有 hold 旗標時寫 `autocommit.hold-discarded` / `ctl.dry`;`autocommit.wd` / `decided` 留到重開。
- **m10 為了抽一個 shell 檔,build 四個完整 image**:可以考慮在主機端對乾淨 checkout `git apply` 出 mutant 檔(lint-wbox 已經跑 `apply --check`),見證與 sha 照記。如果保留真 build(為了 gate 鏈的一致性),在 §4.2 / §7.3 寫明理由。
- **m11 L43 沒寫 `AUTOCOMMIT_TIMEOUT`**(併入 MAJOR-2 的修法)。
- **m12 §5 生命週期矩陣缺 §17 的列**:harness 在 dry-run 臂中死掉(偽 `prov-state`、孤兒 watchdog、bind);在 L51 bind + OTA 中死掉(bind 隨重開消失、hold 擋 commit、期限 revert);在 L42 apply 與重開之間死掉(tryboot 已 armed、負對照臂可能留有 `radio` arm 檔、hold);bcm2710 = 不適用(CM4 決定)。

## 3. 各路徑 / 殘留(依任務要求)

| 單位 | harness 死掉時留在 p6 / tmpfs | 還原是否完整 |
|---|---|---|
| L38 / L43 | p6 `prov-state` 偽值(第 3 欄可能是 `-`);`ota-armed.mesh`(L43 錯 boot8 或上一次開機的 boot8,slot A:之後任何 trial 都對不上,無害 ✅);tmpfs 有 bind、孤兒 dry-run / watchdog(期限 ≤ uptime+150 + DEFER_MAX)、`autocommit.wd` / `decided` | ❌ `prov-state` 沒有 deadman / P9 路徑(MAJOR-3) |
| L42 | 負對照臂:`ota-armed.mesh` = `<本次 boot8> B radio`、tryboot armed、hold(若已寫)。重開 → B 接受 radio → hold 擋 commit → 期限 revert → bad-slot + dirty → P9 ✅;hold 未寫 → V 會 commit 進 B → `pr_normalise` 可處理 ⚠️ | ⚠️ 看 m5 的順序 |
| L51 | bind 隨重開消失;arm 檔隨 trial commit / revert 刪 ✅ | ✅(BLOCKER 修好後) |

## 4. 安全(§17 的增量)
- 新的寫入面:root harness 對 p6 `prov-state` / `ota-armed.mesh` 的白箱寫入(MAJOR-3);root bind 蓋住三個 root 執行的產品檔(autocommit、batman-slot、platform.sh)。bind 期間的 fail-open:L51 mutant 讓任何 OTA 都是 `radio`;L42 mutant 在真 OTA 時寫 `radio`(m3)。兩者都只活在 lease 內、重開即消失、deadman 會 unbind;要寫進 §7 的「我們自己」列,負測試 = P9 的 bind 殘留檢查(既有)。
- 本機非 root:bind 來源目錄是 root 0700 ✅;`prov-state` / `ota-armed.mesh` 在 p6 state 目錄(root),非 root 進不去 ⚠️(沒查 04 上的權限)。
- 供應鏈:四個變體都是 `release/same`,gate 的見證集合規則照用 ✅;不進槽 ✅。

## 5. 摘要
§17 的方向正確:四個 L 編號的機制都找對了地方,dry-run + FORCE_TRIAL 確實走的是同一段 `:399-425`。需要修正四點:
1. L51 的 bind 目標要改成 `/lib/upgrade/platform.sh`,並加上「mutant 有被執行」的證據(BLOCKER)。
2. member 前置要在單位內用 fleet 值建立(MAJOR-1)。
3. dry-run 要整組 process group 殺乾淨;L43 的判定要收緊(MAJOR-2)。
4. `prov-state` 白箱只改第 2 / 4 / 6 欄、每臂立即還原,並寫進 §3 / §5(MAJOR-3)。

12 個 MINOR 大多是程序細節與成本,其中一項要回報使用者:新增的 trial 超出 H3-U3 核准的預算。
