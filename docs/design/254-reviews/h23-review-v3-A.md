# Review A(第 3 輪):`254-h23-harness.md` v3(2026-10-28,唯讀;未碰 02 / 04)

審整份(v2 本文 + 每節「v3 修正 / 補充」合起來的結果設計),先走 22 h 無人值守的真實跑法(每個階段 harness 死、`pr_normalise`、`-wbox` 殘留、killpoint 已 arm、兩個操作員、02 在 `prov-netjoin-fleet` 認領後還原失敗),再逐條對 F1–F40 與 §4–§6 的判定字串 / 錯誤碼 / 行號查原始碼(Batman-h23 工作樹 c3a346b;firmware-2710 工作樹),最後逐條核對 v2 A / B 每個發現。

## 摘要

v2 的 1 BLOCKER / 13 MAJOR 都有處置,字串面(F12 `:420` / `:421` / `:425` / `:494` / `:499` / `:502-505` / `:513` / `:537`、F13、F9、F11、F38–F40)全部逐字對上。還留下 7 個會在無人值守 run 裡製造**誤 commit、假 PASS 的負對照、或假 FAIL** 的問題,全部有明確修法、不動架構:

1. `99zz-wbox-chan` 的「排在 `99-batman-chanfix` 之後 = chanfix 已完成」不成立:chanfix 把整段 reassert 放到背景子殼(`( … ) &`),uci-defaults 排序只保證「啟動」順序;mutant 若同步等 `wifi status` 會卡住 boot,若背景跑則和 chanfix 的 6 次 reassert 賽跑 → mutant 被蓋回 → 04 入網 → **revert 型單位沒有 hold → wbox B 被 commit**(M1)。
2. powerloss 三個負對照有兩個沒鑑別力:txn-3 的 `helper-nogen` 碰不到 `.txn` 分支(M2);txn-2 (a)「重開後 mv `.txn`」在 helper 已把 Txn 讀進記憶體、睡 120 s 後照樣 restore(M3)。
3. txn-4 的判定「helper 補 `--save`」沒有任何原始碼呼叫路徑(M4)。
4. autocommit (8) 的 `WARN ble:` 是 autocommit **第一次 poll 的一次性快照**(`autocommit.ble-warned`),在 harness 能 `btmgmt power off` 之前就印完了;臂 1 / 臂 2 的括號內容只反映 bluetoothd 的開機時序(M5)。
5. 範圍對 p1-impl §5 靜默縮小:(10) L41 caller 偽造被換成不相干的一列、`prov-misc` 掉了「socket 目錄預置 symlink → 拒絕」、(4) 沒有列(M6)。
6. lease / deadman 契約:重用的 `dm-fire` 是「睡固定秒數 → lease 未到期就退出」,所以 +900 / +1800 的延長若只改 lease 檔會讓 deadman 變成無效程序;而且 lease、deadman、`restoring` 全在 tmpfs / 程序內,單位內每次重開都消失(hold 型單位 ≥ 4 次重開),「節點端 lease 是唯一互斥」在第一次重開後就不成立(M7)。

**BLOCKER 0 / MAJOR 7 / MINOR 10 → APPROVE-WITH-CHANGES**(MAJOR 全收後 v4 整份再審;M1 / M7 是現場會真的把 04 留在壞狀態的那種)。

---

## MAJOR

### M1. `chan` mutant:uci-defaults 順序 ≠ chanfix 完成;revert 型 wbox 單位沒有 hold → mutant 失效 = wbox B 被 commit
- **情境**:(7) 的 04 側(以及 §4.3 順序提到的 (4)):`-wbox chan` 不 hold 進 B,預期 `TRIAL-REVERTED`。§4.2 寫「`99zz-wbox-chan` 排在 `99-batman-chanfix` 之後,uci-defaults 依檔名序執行:等 `wifi status` radio1 up 後 `uci set radio1.channel` …」。
- **證據**:`feed/batman-provision/files/etc/uci-defaults/99-batman-chanfix:21-58`:整段是 `( … ) &` 背景子殼 —— 等 `wlh0` 出現(≤ 80 s)→ `sleep 8` → 比 uci 的 channel 與 p5 → 不同就 `uci set` + `wifi reload`,最多 6 次。uci-defaults 由 `/etc/init.d/boot` 同步逐檔執行(排序只是啟動順序);所以 (a) mutant 若在 uci-defaults 裡同步等 `wifi status` radio1 up → boot 卡在 S10,網路永遠不起;(b) mutant 若也背景跑,它在 radio up 後改頻道,chanfix 在同一窗口內(`sleep 8` 後、第 1–6 次)比到不同就改回 p5 值 → mutant 無效 → 04 以 p5 頻道入網 → 單位是 revert 型、**沒有 hold** → autocommit commit wbox B → 04 committed 在 wbox 槽 → §5「誤 commit 後 harness 死 → 需人」,run 停、OTS 停。
- **修**:(1) **所有 wbox trial 一律 hold**(hold 不擋 revert,`batman-autocommit:233-244`;mutant 有效 → 期限 revert 同今天;mutant 無效 → `HELD` → harness 判「mutant 無效」FAIL 並 `back_to_a`,無 bad-slot、不 commit)。§4.2「hold 或預期 REVERT」改為「一律 hold;預期 REVERT 單位另等 `TRIAL-REVERTED`」。(2) `chan` 改成 `files/etc/init.d/` 的一次性 init(START=99,`start()` 背景化),條件 = `iw dev wlh0 info` 成立 **且** `pgrep -f p5-chanfix` / chanfix 子殼不存在(或 uptime ≥ chanfix 最長 80 + 6×8 s),才 `uci set` + commit + `wifi reload`;trial 內前置斷言 `uci get wireless.radio1.channel ≠ p5 值` 且 120 s 內不在 mesh,否則 FAIL「mutant 無效」(p1-impl (4) 原有的前置被 v3 漏掉)。§12 B-M3 標 partial。

### M2. txn-3 的負對照 `helper-nogen` 沒鑑別力;`helper-notxn` 單獨也沒有
- **情境**:§6.2 powerloss「txn-3:`helper-nogen` [upper]」;§4.2 `helper-nogen` = 「`--boot` 不比 gen」。
- **證據**:`boot/boot.go:105-130`:有 `.txn` 時先走 `ReadTxn` 分支,`g == t.To && p5Rec != nil` → `WriteOverlay(p5Rec)` + `RemoveTxn`(`txn … committed (gen n): overlay completed from p5`)—— 這條**不看 gen 比對**;gen 比對(`:178-189` `p5Rec.Generation > ovRec.Generation`)只在沒有 `.txn` 時才到。txn-3 的 killpoint 在 `--prov-only` rc 0 後、overlay 寫前(`node/txn.go:28-36`),`.txn` 還在 → 重開後走 `.txn` 分支 → `helper-nogen` 不影響 → 負對照照樣「重建」= PASS。反過來 `helper-notxn`(只刪 `.txn`)→ 落到 gen 比對 → p5 n+1 > overlay n → 一樣重建。單一 mutant 都做不出「不重建」。
- **修**:把 `helper-nogen` 定義為「`--boot` 不以 p5 重建 overlay:跳過 `.txn` 分支的 `g == t.To` 重建、跳過 `ovRec == nil || p5 gen > overlay gen` 重建」(同一個 mutant 同時服務 overlay-corrupt 的 `ovRec == nil` 分支),或 txn-3 的負對照改為 `helper-notxn` + `helper-nogen` 疊加(兩個 upper 副本不可能,所以做成一個 `helper-norebuild` 變體)。§4.2 表與 `lint-wbox` 的引用一起改。

### M3. txn-2 (a)「重開後真檔 `mv .txn .txn.dv`」做不到:restore 已在記憶體裡排程
- **證據**:`cmd/batman-provhelper/main.go:441-443`:daemon 啟動 `boot.Run` 回 `Restore` 後 `go restoreWireless(p, res.Restore, 120 s)`;`:481-495`:睡 120 s → `halow-setkey` 用 **記憶體裡的** `t.PrevKey / PrevID / PrevChannel` → rc 0 才 `RemoveTxn`。重開後 harness 無論什麼時候 `mv .txn`,setkey 都照做,`txn … not committed: restored …` 行照印 → 負對照「預期 FAIL」卻 PASS(非鑑別)。重開前沒有窗口(killpoint 立即 sysrq)。
- **修**:(a) 改為「重開後 ≤ 120 s 內 `mv .txn .txn.dv` → `/etc/init.d/batman-provhelper restart`(殺掉帶 Txn 的 goroutine;新 daemon `ReadTxn` 失敗 → 無 Restore)→ 斷言 ≥ 150 s 後**沒有** `not committed: restored` 行、wireless 仍是新值、`.txn.dv` 還在」;並寫明 120 s 窗口是前提(`main.go:443`)。或只留 (b) `helper-notxn` [upper]。

### M4. txn-4 的判定「`--check` 報 stale → helper 補 `--save`」沒有原始碼依據
- **證據**:helper 沒有任何開機後呼叫 `--check` / `--save` 的路徑:`main.go:115` 的 `Save()` 只被 `applyNet`(`node.go:1120`)、`saveRetry`(`:400-403`,claim)與 `:454 / :795`(owner / ssh_keys 動詞)用;`boot.go` 不呼叫;`applyState` 不呼叫(grep 零命中)。`--check` 本身只回報(`batman-config-save:157` `p5 stale: prov` exit 5)。能補寫 overrides 的只有 joinwatch 的 `--on-join`,前提 JOINED(`joinwatch:135`)—— txn-4 的 04 在無鄰居的隨機網路上永遠不 JOINED。所以重開後 `overrides == prov` 要嘛永遠不成立(單位假 FAIL),要嘛是一個產品缺口(txn-4 斷電後 overrides 到下一次入網才追上)。F39 只講 prov-state,沒講這件事。
- **修**:實作前先查:txn-4 重開後誰寫 overrides(`grep -rn -- '--save\|--on-join' feed/`,含 95 / 96 / 99zz / `batman-prov-lock`),有就寫進 F39 附 file:line;沒有 → txn-4 判定改為「`--check` rc 5 `p5 stale: <keys>`、`prov.meta` gen n+1、wireless == prov;`overrides` 落後列為產品殘項回 #254(§10)」,txn-5 的差 = `--check` rc 0。

### M5. autocommit (8)(9):`WARN ble:` 是第一次 poll 的一次性快照,臂 1 / 臂 2 沒鑑別力;臂 3 的 `state-set` 會被 helper 15 s 內寫回
- **證據**:`batman-autocommit:496-500`:`[ -f ble-ok ] && [ ! -f autocommit.ble-warned ]` → 讀 health → 不符就 log + `: > ble-warned`。poll 迴圈從 autocommit 啟動(S9x)就開始,第一次 poll 在 harness 經 eth 找到 trial 之前;那時的 health 行內容 = bluetoothd 是否已起、hci0 是否已 powered(`health.go:138`)—— 和 harness 之後做不做 `btmgmt power off` 無關。臂 1 期望 `(… hci0_powered=0 …)`、臂 2 期望 `(… hci0_powered=1 …)`:兩者都由開機時序決定,同一臂兩次跑可得不同結果。臂 3:`ble-ok` 用 `state-set` 刪掉後,A 上的 helper 每 15 s `Tick`,`poweredFor ≥ 600 && Committed && ConfigOK` 仍成立(程序內計數)→ `health.go:151-157` 立刻寫回 `ble-ok`;sysupgrade 要幾分鐘 → trial 開機時 `ble-ok` 又在 → 臂 3 也印 WARN。(9) 的「WARN 行含 health 內容」同樣取決於 helper 的第一次 `Tick` 是否早於 autocommit 第一次 poll。
- **修**:P1 期 (8) = 「`ble-ok` gate」兩臂:臂 A `ble-ok` 在 → 有 WARN 行;臂 B 不在 → 無 WARN 行;括號內容只記錄不斷言。臂 B 的 `ble-ok` 移除要在 helper **停止**狀態下做並在 `sysupgrade -n` 前保持停止(或 `state-set` 後立刻 OTA,但 OTA 本身 > 15 s,所以只能停 helper),trial 讀的是 p6 快照一次(`:419`),所以 trial 內 helper 重起不影響。要驗 `hci0_powered=0` 分支:boot 時序內的 mutant(`-wbox bt-off`:init START < autocommit 的 `btmgmt power off`)或移到 H3。(9) 只斷言 `HELD` / commit,WARN 內容改記錄。§12 A-M5 / B-M2 標 partial。

### M6. 範圍對 p1-impl §5 靜默縮小(§1.2 寫「§5.3 全部 + §5.5 (1)(3)(5/6)(7)–(10)」)
- (a) §6.2「(10)」寫成「member 單台 → OTA V hold → `is healthy and HELD`」—— 這不是 p1-impl §5.5 (10)(L41:非 root / 容器 root 偽造 sysupgrade cmdline、相對路徑呼叫 → 不寫 `ota-armed.mesh`;`-T`、真 OTA、中止後 LuCI validate 三種 caller 各一次,對 `platform-ab.sh:90-115` `_ab_live_sysupgrade` / `_ab_arm_mesh`)。§7「OTS 容器 / tenant root」那列的負測試引「既有 autocommit (10)」—— 引的是不存在的測項。
- (b) p1-impl §5.3 `prov-misc-254` 的「socket 目錄預先放 symlink / 他人擁有 → 拒絕」(F11 `sock.go:62-75` `PrepareDir` 拒絕啟動的負測試)在 v3 的 `prov-misc` 列不見了;§7 沒有對應。
- (c) §4.3 順序寫「(1)(4) revert 型」,§4.2 `chan` 寫「用在 (4)(7)」,但 §6.2 沒有 (4) 這一列(只有 (7) 的 04 側)。
- **修**:(a) 恢復 (10) = L41 三種 caller + 偽造 caller,判定 = p6 `ota-armed.mesh` 有無 + `otalog S1 ARMED-MESH` 有無(只在 A、不動槽,`—` 型);現在那列若要留,改名為 (3) 的單台臂。(b) 加回 `prov-misc`(tier B,lease 內:`nobody` 建不了 `/tmp/run`,以 root 預建 `/tmp/run/batman-prov/x` 或 symlink → restart → log `sock: unexpected … refusing to start`、helper 退出 / respawn)。(c) 列 (4) 或在 §1.2 寫「(4) 併入 (7) 的 04 側」。

### M7. lease / deadman 契約:延長 lease 不 re-arm = deadman 失效;lease / deadman / `restoring` 都活不過單位內的重開
- **證據**:`scripts/node/ble-lib-254.sh:212-226` `cmd_dm_fire`:`sleep $2` → 重讀 lease → **未到期(`up_s < expiry`)就 `exit 0`**,不重排;`:116` 註解「Caller holds the lock and extends the lease to $2-5」= 延長是 `dm_arm` 新秒數(舊 deadman 被 `pg_kill`),不是只改 lease 檔。§4.3「初值 3000;`pr_ota_b` 落點後 +900;`pr_restore` 前 +1800」與 §3「deadman 到期刪 lease」沒說延長 = re-arm;照字面實作(只 `lease_write`)→ 3000 s 時 deadman 醒來看 lease 未到期 → 退出 → 之後**沒有任何 deadman**,§5「harness 死於 restore 途中 → deadman 只 unbind、不起 joinwatch」那列整個落空。另:`dm_fire` 用 `lease_read` = `$BT/lease`(`:84-85`);設計的 prov lease 是 `lease-prov`,prov 的 `dm-fire` 若沿用 `ble-lib` 的函式永遠讀到 BLE 的 lease → `$1 != run` → 退出。
- **生命週期**:lease(`/tmp/run/batman-dv`)、deadman(程序)、`restoring`(tmpfs)在每次重開都消失;hold 型單位有 reboot committed、OTA、back_to_a、restore 重開、brewrite ×2 ≥ 5 次重開。第一次重開之後「節點端 lease 是唯一互斥」不成立;真正跨重開的只有 p6 `dv-prov-dirty`(`prov-base-254.sh:145`,snap 時寫;第二個 harness 的 `pr_begin` 走 P9 子集會撞到 ✅)—— 但 `pr_normalise` 不 snap、不寫 dirty,它的 A trial(≈ 15 分)期間第二個 harness 的 P9 不會擋。
- **修**:(1) §4.3 / §3 寫死:每次延長 = `dm_arm <run> <new secs> prov-base-254.sh`(同一把 `$BT/lock` 內);prov 的 `dm-fire` 讀 `lease-prov`;BLE `acquire` 看到有效的 `lease-prov` 要拒絕,反之亦然(兩個檔、同一把 flock)。(2) 每次 `pr_find` 找到 04 後**重新** acquire lease + `dm_arm`(剩餘預算),並寫明「單位內互斥 = lease(重開前)+ `dv-prov-dirty`(跨重開)」。(3) `pr_normalise` 寫一個 p6 標記(例如 `dv-prov-normalising <run> <boot>`),P9 看到 = FAIL「正規化進行中 / 殘骸」,完成時刪;§5「harness 死於 normalise」那列的清法也用它。(4) `restoring` 若要撐過 restore 內的重開(`p5-restore` 後 `overlay-restore` 前不重開;`reboot committed` 後 compare —— 若 compare 前 harness 死,標記已不在,deadman 也不在,只剩 dirty ✅ 可接受,但要寫明)。

---

## MINOR

### m1. `joinwatch.lastjoined` **在** `scripts/rundir-paths.txt:97`
§1.2「不在本 PR」、§9 殘項、§10、§12 A-m10 都說它不在清單裡,F33 的證據是 `grep -rn lastjoined feed/`(沒掃 `scripts/`)。刪掉這個假殘項;F33 證據補 `rundir-paths.txt:97`。

### m2. (6) 兩臂的 `first_why=` 是串接字串
`batman-autocommit:502` `why="${why:+$why; }mesh not joined/reachable (…)"`,前面可能先有 `health_ok` 的服務 why 或 `:494` 的 `member: HaLow mesh interface not up …`(第一次 poll radio 可能還沒起)。斷言改「`otalog AC UNHEALTHY first_why=` 行**含** `mesh not joined/reachable`」,不是等於。

### m3. `helper-flap` 要定義退出點
daemon 順序:`boot.Run` → `keystore.Load`(失敗 → `select {}`,health 永不跑)→ `applyState` → `go h.Run`(`main.go:439-461`);health 的第一行在 `h.Run` 才寫(`health.go:165`)。mutant 若在 `serving` 前退出 → `no health file`。寫明「`serving` 後 5 s `os.Exit(1)`」。(9) 的 WARN 內容依 M5 改記錄。

### m4. `upper-helper` 與 bind 的順序
bind 掛在 `/usr/bin/batman-provhelper` 上時 `cp` 到同一路徑寫的是 bind 來源檔,不是 upper。powerloss txn-2 (b) / txn-3 要「先 `upper-helper <mutant>`、再 `push-helper test`(bind)+ arm」。§4.5 寫進去。

### m5. §4.2「只進 B;P9 任一槽 `.protected` 含 wbox → FAIL」與 `prov-legacy-upgrade` 矛盾
那個單位把 `rc9-unclaimed` hold 進 **A**(B = wsl.9 committed)。改成「只進非 committed 槽;P9:**committed 槽**含 wbox → FAIL,另一槽含 wbox → 印 restore 指令」;`pr_ota_b` 參數化目標槽。

### m6. `prov-netjoin-fleet` 的還原順序與 02 快照
04 是主機進 mesh 的唯一橋;04 先 restore(重開、離網)→ 02 還原指令送不到。寫死:02 先 p5-restore + overlay-restore + 重開並回到 `batctl n`,再 04。02 要先 `snap`(§6.2 只寫「02 F」)。

### m7. (6b) 的「舊 boot_id」要排除 apply 那次開機
`:419` 的 `ab` = boot-reasons 倒數第二行 = apply 當時那次開機的 boot_id。若 harness 寫的是「當下」boot_id 且第 3 欄 radio → 會被採用。寫「一個不等於本次開機的 boot_id」。

### m8. (1) 的 `radio1-off` 同樣沒有 hold(見 M1 修法 (1));型別欄一併改「hold + 預期 REVERT」。

### m9. `pr_end` 對 `prov-legacy-upgrade` 的 brewrite 條件
該單位結束時 B = wsl.9、A = V committed → 必須 brewrite(§6.2 型別欄 R ✅),但 §4.3 步驟 3「單位寫過 B 才 brewrite」要把「B 現在不是 V」也列為條件,否則依型別欄判斷不夠。

### m10. 小字串 / 事實
- F29 行號:我在 bcm2710 kernel 樹看到 `.config:6859-6860`(a72 樹可能是 6904);不影響。
- F16 / F17 / F18 / F21 / F28 / F32(wsl.9 內容):未上機 / 未上網,沿用;`f2f2bf6` 存在 ✅。
- §5「v3 修正」表把兩個 v2 的列合併為「同 v2」,可接受;但 §4.9 / §4.10 / §6.1 / §8 / §11 的「v3 修正 / 補充」區塊是**空的**(只有標題)—— 刪掉或寫「無」。

---

## v2 發現 → v3 解決了嗎

| v2 | 解決? | 說明 |
|---|---|---|
| A-B1 `lastjoined` | yes | §4.3 通則(member → `reboot committed` → OTA);`:420` 行逐字 ✅;`platform-ab.sh:110-112` ✅;F33 ✅(m1 是旁枝) |
| A-M1 (5)/(6) | yes | 字串改 `:421` / `:425` / `:505` ✅;(6a)/(6b) 可行(`batman-slot` 不寫 `ota-armed.mesh`,grep 零命中;`_ab_arm_mesh` 只在 `_ab_live_sysupgrade`);型別 hold + 480 s back_to_a ✅;m2 / m7 殘餘 |
| A-M2 trial 內負對照 | **partial** | 通則 + `upper-helper` ✅(`overlay-restore` 的 `tree_manifest /overlay/upper` 全樹刪多出,`prov-base-254.sh:65-71,205-211` ✅);txn-3 的 `helper-nogen` 仍無鑑別力(M2);txn-2 (a) 不可行(M3);m4 順序 |
| A-M3 bad-slot 順序 | yes | §4.3 步驟 1 在 restore 前 ✅(`STATEFILES` 含 bad-slot,`:29`;restore `rm -f`,`:213`) |
| A-M4 (7) 02 | yes | 02 `back_to_a`、不 release、不 brewrite;`pr_end` 例外列明 |
| A-M5 / B-M2 (8)(9) | **partial** | 三臂寫了,但一次性 WARN 快照 + `ble-ok` 被寫回(M5) |
| A-M6 wbox × 板 patch | yes | lint 對套板 patch 樹 + 檔案清單;`helper-exit1` 改 Makefile;17 sha;§7.3;trap `clean -fdx` |
| A-m1 sysrq 退路 | yes | `sleep 2` 偵測 |
| A-m2 normalise lease | yes(但見 M7 (3)) | lease ≤ 1500 s 夠(OTA 3 + settle 1.5 + HELD ≤ 8 + release/commit ≈ 20 分);§5 列有 |
| A-m3 時間 / brewrite 省略 | yes | §7.3 重算;步驟 3 條件;3000 / +900 / +1800 ≥ 47 分 ✅(但 M7:延長要 re-arm) |
| A-m4 txn-2 字串 | yes | `main.go:491`、`boot.go:127` ✅;§10 撤回 |
| A-m5 txn-5 | yes | `--save` 後回應前(`node.go:1120-1124` ✅);與 txn-4 的差 |
| A-m6 96 行號 | yes | 以呼叫字串(`96:104-115` 唯一 `exit "$2"` ✅) |
| A-m7 lock-failsecure 前置 | yes | F37 對 `batman-prov-lock:7-11,50-56` ✅ |
| A-m8 / B-m8 DNODE 機制 | yes | `$cmd` 展開含 DNODE IP;`suite()` 只收 4 參數 ✅ `daily-validation.sh:77` |
| A-m9 / B-m9 2f | yes | `:254-276` bt-uart-boot-305 ✅ |
| A-m10 rundir-paths | **partial** | §2.2 句子刪了 ✅;但新寫的「`lastjoined` 不在清單」是假的(m1) |
| A-m11 02 認領 / 金鑰 | yes | §3 金鑰列、§5 新列、§7.2;F38 ✅ `node.go:218-224,996-1000`;m6 順序 |
| A-m12 fakeSys | yes | PATH stub 跑真 `realSys` |
| A-m13 02 batctl 窗 | yes | 180 s |
| A-m14 / B-M6 dvpc | yes | `prov-sec-dvpc-254`(`pl_prep` 在 `prov-lib-254.sh:70`,無負測試 ✅ 一致) |
| A-m15 事實 | yes | F7 `:38-44,52-53` ✅;F34 兩個 `-ldflags` ✅ `golang-package.mk:244-262`;`CONN-CLOSED` 標明 provclient;dbus root 改 Introspect;`noiseprotocol` 0.3.1 釘 ✅ |
| B-M1 socket 目錄 | yes | provd:provd 0700 |
| B-M3 chanfix 行 | **partial** | 不依賴 log 行 ✅;但「排在之後 = 完成」不成立 + 賽跑(M1) |
| B-M4 rpa 三態 | yes | §6.3 |
| B-M5 dbus-send wrapper | yes | F16 `.libs`;ELF 斷言;E-H1 `readelf` |
| B-M7 timing 限速 / n | yes | ≤ 18 / 分、交錯、主動斷、n 公式 |
| B-m1 F3 | yes | 14 ✅(`:208,214,227-296`) |
| B-m2 F12 | yes | 任何 COMMITTED `rm -f bad-slot` ✅ `:537` |
| B-m3 120 s | yes | §6.2 txn-2 ≥ 120 s(但 M3) |
| B-m4 `clean -fdx` | yes | §4.2 |
| B-m5 Go 見證字串 | yes | §2.1 / §4.1.3 / lint |
| B-m6 replay 失敗計 | yes | F40 ✅ `node.go:94,548-552` |
| B-m7 NEVER_KNOWN | yes | §2.2(`:2740` ✅;`classify` `^FAIL ` ✅) |
| B-m10 normalise 殘骸 | yes | §5 列 + P9 文字(M7 (3) 補標記) |
| B-m11 deadman 共用 | yes(契約見 M7) | 重用 `dm_arm` / `$ST/dm` |
| B-m12 dbus root 副作用 | yes | Introspect / Properties.Get;RegisterAgent 只在 tier B 並立即撤 |
| B-m13 radio P9 / scan response | yes | §4.7 WinRT On;E-H1 bleak 合併 |
| B-m14 scalar 規則 | yes | F19 ✅ `verify.py:350,469`、`gen.py:38,225-227` |
| B-m15 tmp-trust 範圍 | yes | §2.2 明寫 `scripts/dv/*.sh` 不掃(`check-tmp-trust.sh:29` ✅) |
| B-m16 一次 restart | yes | `push-helper` 先寫 killpoint |
| B-m17 brewrite 02 | yes | `pr_brewrite <node>` 依角色(`brewrite-254.sh:4,21,37` ✅) |
| B-m18 parser 測試 | yes | 四案例(`read -r ks pat iss`,`:2749` ✅ 第 4 欄併進 `iss`) |
| B-m19 (1) reason | yes | F12 `why` 表(`:494,502,503` ✅) |

## 已核對的假設(file:line)
- F1 grep 零命中 ✅;F2 檔案都在(`scripts/dv/prov-claim-254.sh`、`scripts/node/prov-p1-254.sh`、`addr-defer-254.sh`)✅;F3 14 ✅;F4 `prov-base-254.sh:29,190-213`(`STATEFILES`、`p5-restore`、`overlay-restore` 刪多出 + 每個 STATEFILE 快照沒有就 `rm -f`、無 firstboot)✅;F5 `overlay-allow.txt` 3 條 ✅;F7 ✅(另:`build-board.sh:74-84` 的 BASE dirty 閘只看 `package target …`,feeds/batman 的 wbox patch 不會被它擋 ✅;步驟 2 末 `check-board-patches.sh` 在 patch 套用前跑 ✅);F8 `main.go:375-407,439-443,479-495` ✅;F9 `node.go:33-50,163-170` ✅(`stateChanging` 含 `settings.set` / `ssh_keys.set`);F10 ✅;F11 `sock.go:41-74,87-91,140` ✅;F12 逐字 ✅(含 `:420` `member: armed in radio-only mode (ota-armed.mesh) — no neighbour required`);F13 `96:113,115,168,193`、`boot.go:59,72,127,187`、`main.go:491` ✅;F14 `health.go:138,151,163-165` ✅(`Run` 第一件事 `Tick(15)`);F15 `99-batman-chanfix:45-55` ✅(但整段在背景子殼,M1);F19 ✅;F20 ✅(`sock_test.go:67`);F22 `ble-periph-254.sh:42-52`(第一動作 `rm-adv` ✅)、`ble-lib-254.sh:78-134` ✅;F23 ✅;F24 `chain1-254.sh:27,135-137,145,259,362` ✅;F25 ✅;F26 ✅;F29 ✅;F30 ✅;F31 `batman-slot:424-436,771-791`、`95:717` ✅;F33 ✅(+ `rundir-paths.txt:97`);F34 ✅;F35 grep 零命中 ✅;F36 `build-board.sh:146-172` ✅(`check-go-toolchain.sh:16` REQUIRED 無 helper);F37 ✅;F38 ✅;F39 ✅;F40 ✅。
- killpoint 五點對 `applyNet`:`node.go:1089-1124` + `txn.go:17-40`(WriteTxn → SetKeyNoPersist → Persist(`--prov-only`)→ WriteOverlay → RemoveTxn → Save → 回應)✅ 五個窗口都存在;txn-3 的開機路徑 = `boot.go:116-121`(M2)。
- uci-defaults 排序:`99zz-batman-prov-state` < `99zz-wbox-chan`(`b` < `w`)✅;但 chanfix 背景(M1)。
- helper init `feed/batman-prov/files/batman-provhelper.init:13` `respawn 3600 5 0` ✅;joinwatch `t_reboot 3600` ✅。
- 協定:219 §5.2 無 `E_STATE`、`E_BUSY` 7、`E_RATE` 12 ✅;§8 計數器與 §4.8.2 / §6.3 的對應 ✅;§3.4「等逾時才斷」✅(B-M7 修法成立)。
- 範圍:p1-impl §5.1 / §5.2 / §5.6 / §5.7、stage1 §8 / §9 的列都有對應;缺口只有 M6 三項。

## 無法核對的假設
- 節點側:F16(`which`、`libdbus`)、F17、F21、F28、04 upper 是否已有 `usr/bin/batman-provhelper`(影響 `upper-helper` 的「多出」判定——若 lower 之外 upper 早有副本,`overlay-restore` 會把它還原成快照的那份,不是 lower 的)。
- F18(arm64 runner)、E-H1–E-H6 全部;F32 wsl.9 的 96 內容(只確認 commit 存在)。
- `busybox tar` whiteout;`claim.verify` 的 commit 路徑(沿用 v2)。

## 裁決

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 7 / MINOR 10)。M1 與 M7 是無人值守 run 會把 04 留在 wbox committed 或讓 deadman 名存實亡的問題;M2–M5 是負對照 / 判定沒鑑別力、會在第一次實跑時變成假 PASS 或假 FAIL;M6 是範圍靜默縮小。都有明確修法、不動 §3 / §4 架構;v4 整份再審(兩位)。
