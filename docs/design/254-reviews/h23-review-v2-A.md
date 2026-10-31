# Review A — `254-h23-harness.md` v2(2026-10-28,唯讀審查,未碰 02 / 04)

審整份。先從「15–20 h 無人值守、04 為 DNODE、02 為 peer」的真實跑法逐單位走一遍,再對 §1.3 F1–F36 與 §6 的判定字串逐條查原始碼(Batman-h23 `b2a00da`、firmware-2710 工作樹)。v1 的 2 BLOCKER / 8 MAJOR 與 B 的 3 / 17 都有對應處置,其中 **A-M1、A-M4(b)、A-M8、A-m10、B-M2、B-M12 只算部分解決**(表見末段)。

## 摘要

v2 把 v1 的結構性問題(順序、`prov_test` helper 到 A、socket 目錄、見證、sysrq)都處理了,契約面(§3、§4.1–4.8、§5)已經夠細,可以實作。但有一個會讓無人值守 run **在第一個「member + held trial」單位停下**的產品行為沒查到:`joinwatch.lastjoined` 是 tmpfs 內**只寫不刪**的檔,04 在同一次開機內先入 fleet mesh、再 `net-apply` 進隨機網路後,`sysupgrade` stage 1 的 `_ab_arm_mesh` 仍寫 `ota-armed.mesh … joined` → trial 內 autocommit `NEED_MESH=1` → 隨機網路沒鄰居 → UNHEALTHY → 600 s 期限 revert → `bad-slot` → hold 型單位的 `pr_end` 走不過 brewrite 前置 → NEEDS-PERSON → 之後 ~20 個單位不跑(B1)。另有 6 個 MAJOR:(5)/(6) 的判定字串不存在且結果型別寫錯;powerloss (b) 與 overlay-corrupt 負對照要在 held trial 內做「改狀態動詞 + 重開」,兩者在 trial 裡都不可能;預期 REVERT 單位的 `bad-slot` 斷言會被 `overlay-restore` 先抹掉;autocommit (7) 讓 02 停在 B committed,下一次 run 的 P3 就擋;(8)/(9) 在 P1 下 WARN 行無條件出現,沒有鑑別力;17 個 `-wbox` build 與 `-i` / 板 patch 的互動只擋了一半。

**BLOCKER 1 / MAJOR 6 / MINOR 15 → REJECT**(B1 一個單位加一次重開就解,但它決定整個 run 能不能跑完,必須先改再審)。

---

## BLOCKER

### B1. member 的 held trial 必 revert:`joinwatch.lastjoined` 在同一次開機內不會清掉,`ota-armed.mesh` 寫 `joined`
- **情境**:autocommit (3)、`prov-ota-254`(含 `96-noprov` 負對照)、以及 (5)/(6) 的前置都是「04 `net-apply --first` 隨機網路 → 同一次開機 → OTA V hold」。04 在單位開始前在 fleet mesh 內(`pr_begin` 要求 02 在 `batctl n`),joinwatch 每 tick 寫 `$RUNDIR/joinwatch.lastjoined`;`net-apply` 之後 04 離開 fleet、隨機網路沒有鄰居,但**沒有任何程式刪那個檔**。`sysupgrade -n` stage 1 → `_ab_arm_mesh`:`[ -s $RUNDIR/joinwatch.lastjoined ] → m=joined` → `ota-armed.mesh = <boot> B joined`。B trial 的 autocommit:`member:*` → 第 3 欄不是 `radio` → `NEED_MESH=1`,log `member: no usable ota-armed.mesh — neighbours required (fail-closed)` 不會印(檔在,只是不是 radio),印的是 `mesh join required: 1 (prov=member …)`;隨機網路 0 鄰居 → `why=mesh not joined/reachable (0/3 samples…)` → `otalog AC UNHEALTHY` → hold 擋不住 deadline → 600 s `TRIAL-REVERTED` → `bad-slot slot=B version=V`。
- **證據**:`feed/batman-provision/files/usr/bin/joinwatch:135`(唯一寫者,無刪除者;`grep -rn lastjoined feed/` 只有它與讀者);`usr/lib/batman/platform-ab.sh:110-112`;`batman-autocommit:416-421`(只有第 3 欄 `radio` 才 `NEED_MESH=0`)、`:502`、`:505`、`:238-244`。
- **後果**:(3) 期望 `is healthy and HELD` → FAIL;`prov-ota` 的 B 斷言可能在 600 s 內做完,但之後 revert → `pr_end` 走 `pr_restore → pr_brewrite`,brewrite 前置 `badslot=[]`(`brewrite-254.sh:21`)→ stop → `pr_abort` → `pr_needs_person` → §4.3「NEEDS-PERSON 後不再跑 prov」→ 其餘單位全部不跑。p1-impl §5.5 (3) 的「radio-only」設計前提(`m=radio`)只在「這次開機從未 JOINED」時成立。
- **修法**:凡「member(隨機網路)→ OTA hold」的單位,在 `net-apply` 之後、OTA 之前加一次 `batman-slot reboot committed`(tmpfs 清空 → `lastjoined` 不在 → `meshjoin_joined` 假 → `m=radio`),並在 trial 內斷言 `member: armed in radio-only mode (ota-armed.mesh) — no neighbour required` + `mesh join required: 0 (prov=member mesh_expect=<m> radio_required=1)`(`batman-autocommit:420,425`)。不要用 `rm $RUNDIR/joinwatch.lastjoined`(harness 動產品 run dir,且 `rundir-paths.txt` 沒有列這個名字——順帶:該檔也不在 `scripts/rundir-paths.txt`,tmp-trust lint 的範圍問題,另記)。時間預算每單位 +3 分;(5)/(6) 見 M1。

---

## MAJOR

### M1. autocommit (5)/(6):判定字串 `first_why=need-mesh…` 不存在;「trial 內刪 `ota-armed.mesh`」做不到;結果型別不是 hold
- **字串**:`batman-autocommit` 全檔沒有 `need-mesh`。缺檔時的行是 `member: no usable ota-armed.mesh — neighbours required (fail-closed)`(`:421`)+ `mesh join required: 1 (…radio_required=1)`(`:425`);UNHEALTHY 的 why 是 `mesh not joined/reachable (<n>/3 samples: plink=… batman(wlh0)=…)`(`:502`)或 `mesh lost (last joined …s ago)`(`:503`),`otalog AC UNHEALTHY first_why=<why>`(`:505`)。規則 3:不存在的判定字串 = MAJOR。
- **時序**:autocommit 在 trial 開機早期一次讀 `ota-armed.mesh`(`:419`),之後不再讀;「trial 內刪」在它讀完才發生 = 無效;在 stage 1 arm 與 stage 2 重開之間刪 = 賽跑。(6) `sysupgrade -T` + 直接 `batman-slot apply` 本來就不經 `_ab_live_sysupgrade`(`platform-ab.sh:104-109`)→ 無檔,這才是可做的注入。
- **型別**:member 無鄰居 + `NEED_MESH=1` 必 UNHEALTHY;hold 只擋 commit 不擋 revert(`:238-244`)→ 要嘛在 600 s 內 `back_to_a`(p1-impl §4.5.4 第 3–4 步,無 bad-slot),要嘛標成 revert 型並走 §4.3 收尾。v2 標「hold / A」兩者都不是。
- **修法**:(5) 改為「member(依 B1 重開過,radio 模式)→ OTA V hold → 在 **sysupgrade 之前** `state-set ota-armed.mesh absent` 做不到,改用 (6) 的路徑或把 (5) 定義為『arm 檔第 1 欄 boot_id 不符』(寫一個舊 boot_id 的假檔,`:419-420` 的 `ab` 比對會拒)」;兩者判定 = 上列三行確切字串;型別 = hold + 480 s 內 `back_to_a`。(3) 則是正向(`armed in radio-only mode`、`HELD`),與 (5)/(6) 互為對照。

### M2. 三個負對照要在 held trial 內「改狀態 / 重開」,在 trial 裡都做不到
1. **`prov-powerloss` (b)**(txn-3 用 `-wbox helper-notxn` hold 進 B 做同一注入):(i) `net.apply` 是 `stateChanging`,`dispatch` 先查 `IsTrial()`(`batman-slot is-trial` rc≠1)→ `EBusy "trial slot (updating)"`(`node/node.go:165-170`;這正是 `prov-trial-busy` 要證的事)→ 注入到不了 txn-3;(ii) `helper-notxn` 是 `-wbox` 變體,§4.2 只有 `test` 設 `BATMAN_PROV_TEST=1` → 沒有 `--killpoint`;(iii) 就算有,sysrq 重開後 tryboot 一次性 → 回 A,B 的 mutant helper 不會跑開機對帳。三重不可能。
2. **`prov-overlay-corrupt` 負對照**(`-wbox helper-nogen` hold 進 B,寫垃圾進 `prov.cbor` → 重開):held trial 重開 = 回 A,B 的 helper 不會再開機。
3. **`prov-powerloss` 正向 txn-3 的鑑別力**:即使在 A 上做,`.txn` 對帳(`boot.go:22-45`)與 gen 比對(步驟 7)是兩條獨立路徑;txn-3 的「overlay 重建」由 gen 比對就會做,`helper-notxn` 不會讓它 FAIL;txn-3 的負對照應該是 `helper-nogen`,`helper-notxn` 只對 txn-2 有鑑別力。
- **修法**:(a) trial 內需要「helper 重跑開機邏輯」的注入一律改 `/etc/init.d/batman-provhelper restart`(daemon 啟動必跑 `boot.Run`,`main.go:439`,F8),不重開;overlay-corrupt 負對照 = hold 進 B → 在 B 寫垃圾 → restart helper → 斷言不重建。(b) 需要「重開後 A 以 mutant helper 開機」的負對照(txn-2 `helper-notxn`、txn-3 `helper-nogen`)用 **A 的 overlay upper**:把從 `-wbox` payload 抽出的 helper(要和 `test` 一樣帶 `prov_test` tag 才有 killpoint → §4.2 加 `BATMAN_PROV_TEST=1` 的 `<name>+test` 組合或讓 helper mutant 一律 tag build)`cp` 到 `/usr/bin/batman-provhelper`(落在 upper,撐過重開),`overlay-restore` 的「刪多出」把它清掉,`prov-base` compare 當負對照;P9 的標記 grep 擋殘留。設計通則「重開後觀察不用 bind」要補「用 upper,restore 清」這一句。(c) §6.2 每個負對照標明觀察點是「重開前 / restart 後 / 重開後」。

### M3. 預期 REVERT 單位的 `bad-slot` 斷言會被 `overlay-restore` 先抹掉(v1 A-M1 只解了一半)
- **情境**:§4.3「pr_end = pr_restore → compare → pr_brewrite」,而「預期 REVERT 收尾 = 等 TRIAL-REVERTED → 回 A → 斷言 bad-slot → 印 → 刪 → pr_brewrite」。`bad-slot` 在 `STATEFILES`(`scripts/node/prov-base-254.sh:29`),`overlay-restore` 對每個 STATEFILE「快照沒有就 `rm -f`」(`:215-217`)。快照取於單位開頭(無 bad-slot)→ restore 後 bad-slot 已不在 → 斷言「內容 = slot=B version=<wbox>」失敗 → `pr_needs_person` → (1)(4)(7-04) 每次都停。若收尾真的跳過 pr_restore 直接 brewrite,則 revert 單位沒有 S0 compare。
- **修法**:寫死順序:等 revert → `pr_find` 04 在 A committed → **先**讀 / 印 / 斷言 / 刪 `bad-slot` → `pr_restore` → compare → `pr_brewrite`;compare 的 state 比對本來就會驗 bad-slot 不在。§5「harness 死(非 hold 的 wbox trial 中)」那列的 P9 restore 指令也要含同一段。

### M4. autocommit (7):02 `release --wait` 後停在 **B committed**,沒有路回 A;下一次 run 的 P3 就擋
- **情境**:§6.2 (7)「02 hold OTA V 進 B → HELD → release --wait → 02 committed … 02 的 B 寫回 V 以 brewrite」。release 後 02 的 committed 槽是 B;`brewrite-254.sh:21` 前置要 `slot=A`,寫的是「另一槽」= A → 等於把 02 的 A 再 OTA 一次,之後 02 仍在 B。p1-impl §4.5.0 S0 = 每台 committed A;`dv-preflight.sh:43-45` P3 要求 BENCH_NODE(02)在 slot A,否則 `ab-selftest --destructive` 前置 FAIL;02 沒有乙太網,每一次 02 的 OTA 都是無 OOB 的風險(p1-impl §7.4 列為「02 需人」)。
- **修法**:L40 要的只是「04 的 stage 1 在本機 `lastjoined` 為真時寫 joined 並 revert」,02 不必 commit:02 hold OTA V → `HELD`(02 在 mesh,04 仍在 A)→ 02 `back_to_a`(rollback + reboot committed,期限內,無 bad-slot)→ 04 才做 `-wbox chan` revert;02 的 B 已是 V(`.protected`=V),不需 brewrite。`pr_end` 的「02 boot_id 前後相同」對 (7) 例外(02 重開兩次),改斷言 02 回 A committed、`badslot=[]`、在 `batctl n`。時間:02 一次 trial 約 15 分(非 15 + 一次 brewrite)。

### M5. autocommit (8)/(9):P1 下 `WARN ble:` 行無條件出現,兩臂只鑑別 `ble-ok` 有無,不鑑別 BT 健康
- **證據**:health 行永遠寫 `adv_registered_once=0`(`feed/batman-prov/src/health/health.go:138`,P1 固定);autocommit 的健康樣式是 `*"bluetoothd=1"*"hci0_powered=1"*"adv_registered_once=1"*`(`batman-autocommit:498`)→ P1 任何 health 內容都不符 → 只要 `ble-ok` 在就印 WARN(`:496-499`)。所以 (8) 臂 1「power off → WARN + HELD」不做 power off 也 PASS;(9) 的 WARN 同理。兩臂互為對照只證明 `ble-ok` 在不在。
- **修法**:判定改成括號內容:(8) 臂 1 = `WARN ble: ble-ok present but BLE health is not good (boot_id=… hci0_powered=0 …)`,加第三臂(ble-ok 在、BT 正常)= `(… hci0_powered=1 … adv_registered_once=0 …)`(P1 characterization,P2 後改「無 WARN」);(9) = `(no health file)`(helper 每 5 s 死,15 s ticker 從未寫檔,`health.go:163`)vs 臂「helper 正常」= 有 health 內容。寫明 P1 / P2 兩期的期望,免得 P2 一上 (8) 臂 3 變 FAIL 又被當回歸。

### M6. `-wbox` build 與 `-i` / 板 patch / 步驟 7 見證的互動只擋了一半
- (a) §4.2「patch 在第 2 步之後套」正確(`build-board.sh:86-96` 的 `-i` 會 reset feeds),但第 4 步 stamp 會跑 `check-board-patches.sh`(`stamp-batman-build.sh:49`)、第 7 步跑 `patch-witness.sh check`(`build-board.sh:166`):wbox patch 若碰到 `patches/<board>/` 也改的檔(例如 `batman-autocommit`、`96`),板 patch 的 context 可能被打壞 → stamp 拒絕;`lint-wbox` 只對 **main 的 `feed/`** `git apply --check`,不是對「已套板 patch 的 feeds/batman」→ lint 綠、build 紅,在 E-H2 之後才發現。修:lint 對 `openmanet_setup.sh -i` 後的 feeds 樹(CI 用 firmware repo 的 `patches/<board>/` 先套)做 `--check`,或規定 wbox patch 不得碰 `patches/<board>/` 列出的檔(lint 用 `board-patch-digest.sh` 的檔案清單比對)。
- (b) `helper-exit1`:要讓 image 裝 shell 取代 Go 二進位,patch 必須改 `feed/batman-prov/Makefile` 的 install(`GoPackage/Package/Install/Bin`,`Makefile:49`)— 可行,但 §4.2 沒寫;`check-go-toolchain.sh` 的 REQUIRED 不含 helper(v1 A 查)所以不擋 ✅。寫明 patch 改哪裡。
- (c) 17 個 build 的 `logs/wbox-<board>.stamp` 只記「上次的 name|PROV_TEST」:兩個不同 patch 變體之間靠 mtime 觸發重編(`include/depends.mk:14` `%p%T@`)✅;但 `test` ↔ 正常 build 之間若 `feeds/batman` 的 git checkout 把 mtime 復原到**和上次相同秒**(同秒內 apply + checkout)則不重編 — 機率低,E-H2 的「helper sha ≠ test 變體」驗收要對 17 個變體各做一次,不是只做兩個。
- (d) 成本:§7.3 空著。單次增量 build(squashfs + payload + 兩個套件 clean)在這台 WSL 依記憶 5–15 分;17 × 10 ≈ 3 h,外加每次 `git checkout -- .` 後下一個 build 的 batman-provision 重編。E-H2 量兩次後乘 17 寫回;P9 要求 17 個都在,少一個整段 prov tier B FAIL — 先寫清楚哪幾個單位只在 `rc` 發版時跑,否則每次動 prov 的 PR 都要 3 h build。

---

## MINOR

### m1. killpoint 的 sysrq 退路永遠不會觸發
`echo b > /proc/sysrq-trigger` 在 `kernel.sysrq` 沒有 0x80 時**寫入成功、動作被忽略**,不是「寫入失敗」;helper 會繼續跑完交易,單位以「boot_id 沒變」FAIL 並錯誤歸因。改:寫入後 `sleep 2` 仍活著 → log `fallback reboot -f` → `sync; reboot -f`。P9 的 `kernel.sysrq` 檢查(F29 `0x1f6` 含 0x80 ✅)已是第一道,這是第二道。

### m2. `pr_normalise` 在 lease / deadman 之外 OTA 04
§4.3 的 `pr_normalise` 在「prov 區塊開頭」、`pr_begin` 之前,它做 hold OTA + release + commit,卻不在 `pr_lease` 內;第二個操作員此時可以 `brewrite`。改:normalise 自己 acquire / release 一個 lease(≤ 1500 s)並 arm deadman。§5 補一列「harness 死於 normalise 的 A trial 中」:deadline revert → `bad-slot slot=A version=V` → 下次 P9「bad-slot 存在 → FAIL」→ 需人(可接受,但要列)。

### m3. 時間與成本(規則 7,把數字寫出來)
- hold 型單位:snap 1 + net-apply 2 + (B1 的重開 3) + OTA 3 + settle 1.5 + HELD ≤ 8 + 斷言 2 + back_to_a 3 + restore(p5 dd、overlay、reboot)5 + compare 1 + brewrite(OTA 3 + HELD ≤ 8 + back 3)14 ≈ **47 分 ≈ 2800 s**;`waitboot` 900 s / `settle` 600 s 任一次用滿就破 3000 s。§4.3 的「restore 前 +1800 s」救得了 restore 之後,救不了 restore 之前的慢開機;建議 lease 初值 3000、`pr_ota_b` 落點後再 +900。
- revert 型:OTA 3 + 600 s 期限 + revert 重開 3 + find 2 + restore 5 + brewrite 14 ≈ 37 分。
- 全套:30 單位 × ~40 分 = 20 h;另加獨立的 held-trial 負對照 8 個(legacy-upgrade、lock-failsecure、prov-ota、leave-ota、overlay-corrupt、overlay-wipe、powerloss(b)、(7) 的 02)× 15 分 = 2 h;(9) 跨槽 +15 分 → **≈ 22–23 h**,不是 15–20 h。04 OTS 中斷:每單位 ≥ 5 次重開 × ~3 分 = 15 分 × 30 ≈ **7.5 h**,不是 4 h。
- `pr_end` 無條件 `pr_brewrite`:「— / A / F」型單位(約 12 個)B 根本沒動,brewrite 白花 14 分 × 12 ≈ 3 h。改:只在單位寫過 B(§6.2 hold / revert 欄非 —)時 brewrite,否則斷言 `slot-B.protected`=V、B 的 `.protected` mtime 未變。

### m4. `txn-2` 的判定字串已存在,不必請 P1b 加新行
`cmd/batman-provhelper/main.go:491`:`txn %s not committed: restored the previous wireless values, setkey rc=%d (%s)`;`boot rc=… action=txn <verb> NOT committed (gen n): wireless to be restored`(`boot.go:43`)。§6.2 txn-2 與 §10 第 5 點的「P1b 補一行 `txn <tok>: reverted wireless to .txn values`」刪掉,用現有兩行;harness 若 grep 新字串而 P1b 忘了加 = 假 FAIL。

### m5. `txn-5` 的視窗在 `net.apply` 裡不存在
`applyNet` 在 `--save` 之後只剩回應(`node/node.go:1120-1124`);`prov-state` 只在 `boot.Run`(`boot.go:60`)與 claim 的 `SetLastKnown`(`:517,581`)寫。txn-5 應定義為「`--save` 之後、回應之前」,鑑別對象 = 與 txn-4 的差:txn-4 開機 `--check` 報 stale → helper 補 `--save`;txn-5 開機 `--check` rc 0。現在寫的「prov-state 本次」在任何重開後都為真,不是鑑別。

### m6. `misc-L38` 的「96 `:89` 出口」是舊行號
現在 `96-batman-config-migrate:89` 是 `lockdown_today()` 裡的 `has_key=` grep;p1-impl §5.1 的 `:64/:67/:71/:89/:93` 來自更早的版面。實作前以 `grep -n 'exit\|return' 96` 重列出口並以字串(不是行號)寫進測項。

### m7. `prov-lock-failsecure` 前置「claimed、無 shadow-root 撐過 sysrq 重開」缺證據
重開後 A 的 S13 `batman-prov-lock` 只在 p5「ok claimed/member 且有 `identity/shadow-root`」時收斂 root(`feed/batman-provision/files/etc/init.d/batman-prov-lock:8-9,52-55`)→ 無 shadow-root 時 root 欄不變、門會鎖 → 前置成立 ✅,但 §6.2 要引用這兩行,並斷言重開後 `lock-status=LOCKED`、`/etc/shadow` root 欄 = 注入前、p5 無 `shadow-root`;否則 wsl.9 負對照的 `has_pw=0 → UNPROVISIONED`(F32)前提沒驗。

### m8. `DNODE_BLOCKED` 的擋法沒有機制
`suite()`(`daily-validation.sh:77-99`)只有 name / why / cmd / kind,不知道目標節點;「目標含 DNODE」要定義為 `kind=D` 且 `$cmd` 字串含 `$DNODE0` 或 `$DNODE`(兩個變數,`:127`、`:386`)。`fault-injection`(`:335`,目標 `$OTS_NODE` = 04)與 `reflash-survives-config-202`(`:2175`,`$MESH_NODE`)都要被擋到,`ab-selftest`(BENCH=02)不擋 — 用 IP 比對才涵蓋三個變數名。

### m9. prov 區塊的位置要寫「2f 之後」
2e 與 2g 之間還有 2f(#305 tier B:`bt-uart-boot-305` 對 04 做 loaded reboots,`daily-validation.sh:254-276`)。§4.3「2e 之後、2g 之前」要改成「2f 之後、2g 之前」,並說明 2f 的重開讓 04 以乾淨 tmpfs 進 prov 區塊(對 B1 的 `lastjoined` 也有幫助,但不能依賴它)。

### m10. `rundir-paths.txt` 不是放 `/tmp/run/batman-prov-test` 的地方
該檔只列 `$RUNDIR` = `/tmp/run/batman` **底下**的 basename(`scripts/rundir-paths.txt:1-4`);`/tmp/run/batman-prov-test`、`/tmp/run/batman-provd-test` 是 `/tmp/run/` 的兄弟目錄,歸 `tmp-trust-allowlist.txt`(§2.2 已列那兩行 ✅)。§2.2 的 `rundir-paths.txt` 那句刪掉。順帶:`joinwatch.lastjoined`(`joinwatch:135`)不在 rundir-paths 清單裡,lint 沒抓到 — 產品側,記 #254 殘項即可。

### m11. `prov-netjoin-fleet-254`(雙台)漏了 02 的認領與金鑰保留
02 是 legacy;`net.apply` 首版要 owner-op(`node.go:220-222,998`),legacy 無 owners → 02 要先 `claim.verify`(→ LOCKED、密碼關、只剩 key;需 02 有 lab key,`pk_proof`),之後才能 join;還原 02 = p5-restore + overlay-restore + 重開,全程經 mesh、無 OOB。若 02 的還原失敗,02 是 LOCKED + 擁有者 = 本 run 的隨機金鑰,而 `pr_end` 會刪 `~/.batman-dv/prov-keys/<run_id>/` → 02 只剩重燒。改:`pr_abort` / `pr_needs_person` 路徑**保留**金鑰目錄並在通知裡寫路徑;§7.2 副作用表加這列。

### m12. CI `peer-vs-provd` 的 helper「fakeSys CI 模式」不在 `prov_test` 封閉清單
§4.1.2 說 `prov_test` 的額外行為「全部」是 (1)–(4);§4.8.3 卻要 helper 二進位在 runner 上以 fakeSys 跑(「與 `prov-p1` job 同套」— 現在的 prov-p1 job 是 shell stub,fakeSys 只在 Go 測試程序內,`node_test.go` / `lock_test.go`)。要嘛清單加 (5)「`BATMAN_PROV_FAKESYS=1` 選 fakeSys(只 tag build)」並列 gate / 單元測試,要嘛 runner 上用 PATH stub(`batman-slot`、`batman-config-save`、`halow-setkey` 假腳本)跑真 `realSys`。

### m13. 02 boot_id 斷言的例外與 `pr_end` 的 02 檢查時機
除 (7)(M4)外,`prov-netjoin-fleet` 的 02 `wifi reload` 不重開 ✅;但 `pr_end` 的「02 在 `batctl n`」在 04 剛 `reboot committed` 後 90 s(`settle`)可能還沒 3 個 join 樣本 — 給 180 s 重試窗,否則每單位尾端假 FAIL。

### m14. 範圍:p1-impl §4.3 的 provclient 放置負測試仍然默默不見
「預先放一個 provd 可寫的檔或 symlink 在 `/tmp/run/batman-dvpc.<run>/` → 拒絕執行」v1 A 已點名,v2 §12 沒對應、§1.2「不在本 PR」也沒列。要嘛進 `prov-sec-254`(一行:root 0711 目錄、檔案 root 0755、symlink → 拒),要嘛列理由。

### m15. 小字串 / 事實
- F7 的行號:`stamp-batman-build.sh` 的 DIRTY 在 `:38-44`、VER 在 `:52-53`(不是 51-67);不影響結論。
- F34 的旗標:實際是兩個 `-ldflags`(`all=-linkmode external -extldflags …` 與 `-s -w -linkmode external -extldflags …`,`golang-package.mk:241-260`),E-H4 照 make V=s 記整串。
- `prov-sock-254` 的 `CONN-CLOSED` 是 provclient 的新輸出(原始碼沒有;helper 端只 log `connection refused: peer uid 65534 (want 471)`,`sock.go:139`)— 可以,但 §4.5 要寫明它是 provclient 印的,判定對 helper log 用那一行。
- `prov-sec-dbus-254` tier A 在 P1 期:節點沒有 provd 的 dbus 政策 → 連正向 `Disconnect` 也 AccessDenied;§6.3 已標 tier B 在 P2 ✅,但 tier A 的「以 root 同方法 → 成功」在 P1 也要先證 root 能呼叫(不然 AccessDenied 可能是 dbus-send 動態連結失敗,F16 ⚠️)。
- F17 `noiseprotocol`:`tests/vectors/219-protocol/requirements.txt` 已釘 `noiseprotocol==0.3.1`(純 Python)→ Windows wheel 風險低,E-H1 可降為 ✅ 預期。

---

## v1 發現 → v2 解決了嗎

| v1 | 解決? | 說明 |
|---|---|---|
| A-B1 / B-B1 順序 | yes | §4.3 prov 區塊在 2g 前 + `pr_normalise` + 白箱;位置要寫「2f 之後」(m9);normalise 要進 lease(m2) |
| A-B2 `prov_test` helper 到 A、`test` 變體、重建雜湊 | yes | §4.5 `push-helper`、強制 DIRTY、wbox stamp → clean;E-H2 待做(M6c 要 17 個都驗) |
| A-M1 bad-slot | **partial** | 擁有權列 ✅、收尾段 ✅,但順序與 `overlay-restore` 的 STATEFILES 還原衝突(M3) |
| A-M2 / B-M1 版本與見證 | yes | `batman-build.txt` + unsquashfs + 見證 + gate 第 7 步(`build-board.sh:157-172` 位置 ✅) |
| A-M3 sysrq;txn-1/5 | yes | sysrq 無 sync ✅;退路偵測錯(m1);txn-5 定義(m5) |
| A-M4 / B-M2 powerloss / netupdate 負對照 | **partial** | (a) `disable` 法 ✅ 有鑑別力;(b) 三重不可能(M2);netupdate 改 p5 overrides 斷言 ✅ |
| A-M5 legacy-upgrade | yes | held A trial + rollback;rollback gate 只擋 claimed/member(`batman-slot:771-783`),legacy/unclaimed 不受影響 ✅ |
| A-M6 / B-B3 provd socket / env / CI 模型 | yes | 獨立目錄、`provd.env`、`SOCK_ONLY`、useradd;fakeSys 模式漏列(m12) |
| A-M7 / B-m2 NEEDS-PERSON | yes | `DNODE_BLOCKED` + rc 契約;機制未定(m8) |
| A-M8 autocommit (7) | **partial** | 改序 ✅;02 release 後停在 B、無路回 A(M4) |
| A-m1 gate 位置 / shell helper / release-scan | yes | 第 7 步 `$WR/r`;`helper-exit1` 以見證判;release-scan 刪句附理由 |
| A-m2 chain1 > 3000 / 02 boot_id | yes | 例外列明;(7) 要例外(m13) |
| A-m3 whiteout | yes | `/etc/banner` 刪 lower 負對照;opaque 風險接受 §9 |
| A-m4 lease 鎖 | yes | 同一把 `$BT/lock` flock |
| A-m5 / B-m1 計數、到期欄 | yes | F3 13、F26 7 行、第 4 欄 + 測試 |
| A-m6 `.protected` 缺 | yes | §4.7 |
| A-m7 目錄刪除者 | yes | §3 |
| A-m8 傳輸三件事 | yes | §4.8.2 |
| A-m9 / B-m9 沙箱 | yes | 步驟順序、gate 獨立、排隊不計 |
| A-m10 (8)(9) | **partial** | 兩臂改寫 ✅,但 P1 下 WARN 無條件(M5) |
| A-m11 authorized_keys | yes | 同一 ssh 批次 |
| A-m12 / B-M5 peer.py 裁判 | yes | `noiseprotocol`、selftest 對 gen.py transcript、`verify.py` `main()` |
| B-B2 四個 helper mutant | yes | 五個補齊 + lint 查引用;但 mutant 若要有 killpoint 需 tag build(M2b) |
| B-M3 lease / ch1 deadman / 主機鎖 | yes | §3、§4.7 |
| B-M4 六項 | yes | 到期欄、sec-helper-uid、key-perms、eeprom-hooks、provd A-N2/B-m2(§6.3 prov-boot provd 側)、雙台 netjoin(m11 補 02 認領)、ble-ok 負對照、settings.set 全在 |
| B-M6 timing | yes | sock、抖動 n、效應量、`FAST_FAKE_DELAY_MS` |
| B-M7 brute | yes | `NO_BRUTE_LIMIT` |
| B-M8 dbus | yes | `exec` 動詞;Disconnect / 回呼移 tier B |
| B-M9 / B-M10 bond / rpa | yes | provd 停止模式;RPA ⇔ 重註冊 log 契約回 P2 |
| B-M11 sock vs §8 / `E_STATE` | yes | 一條 sock = 一條 BLE;`E_BUSY`(`node.go:170` 已是 EBusy ✅;`EState=22` 存在但協定沒有 ✅ F9 正確) |
| B-M12 判定字串 | **partial** | `E_SCHEMA` 20 ✅、`prov-ota` 改 96 字串 ✅(`96:113,168`)、sock EACCES ✅、(9) ✅;(5)/(6) `need-mesh` 仍不存在(M1);txn-2 多造一行(m4) |
| B-M13 `prov_test` 無 wbox | yes | P9 + tier A 標記 grep |
| B-M14 release-scan | yes | 刪 |
| B-M15 / B-M16 deadman restore / 記憶體 arm | yes | `restoring`(tmpfs,與 deadman 同生命週期,可接受)、`wbox.list armed`、P9 |
| B-M17 adv-on | yes | instances / provd running 先查 |
| B-m3 / B-m4 / B-m5 / B-m6 / B-m7 / B-m8 / B-m10 / B-m11 / B-m13 / B-m14 | yes | 見 §12;B-m8 的 `rundir-paths` 一句放錯檔(m10) |
| B-m12 Windows 依賴 | yes | F17 實裝;`noiseprotocol` 已在 requirements(m15) |

## 已核對的假設(file:line)
- F3 13 個:`daily-validation.sh:214,227-296` ✅。F8:`main.go:376-407`(無 `--version`,default → usage exit 2)、`:439` daemon `boot.Run`、`node.go:62-83` Sys 20 法、`node/txn.go:16-34`、`provstore/txn.go:21-33`、`provstore.go:326` ✅。F9:`node.go:34-50`(`ESchema 20`、`EApply 21`、`EState 22`、`EBusy 7`、`ERate 12`、`ELockIncomplete 23`)✅。F10:`provclient/main.go:294-305,417-424,470,489-560` ✅。F11:`sock.go:37-78,110-118,136-141` ✅。F12:`batman-autocommit:192-195,238-244,277-288,361,425,499,505,513,537` 逐字 ✅。F13:`96:79,113,159-169,193`、`boot.go:59,72,187` ✅。F14:`health.go:8-9,151` ✅(另見 `:138` 固定 `adv_registered_once=0`)。F15:`99-batman-chanfix:47,53` ✅。F24:`chain1-254.sh:27,57-92,122-176,205-221,259,362` ✅。F25:`pty-commit-254.sh:14`、`daily-validation.sh:77-99,278-296,335,2175` ✅。F26:7 行 `:10,19-24`、3 欄 ✅。F30:`tmp-trust-allowlist.txt:99` ✅(ERE 以 `sed s///g` 剪掉命中,`check-tmp-trust.sh:52-56`,`([^-]|$)` 收緊可行)。F31:`batman-slot:424-436`、`95-batman-storage:717` ✅。F33:`joinwatch` init:14、bin:19-20,37 ✅。F34:`golang-package.mk:236-262` ✅(兩個 `-ldflags`)。F35:`grep -rn` deploy/ots 零命中 ✅。F36:`build-board.sh:146-172` ✅。F7:`stamp-batman-build.sh:38-44,52-53`、`build-board.sh:86-96,124-140`、`package.mk:114`、`depends.mk:14`、`golang-package.mk:106-111,260` ✅。F29:`CONFIG_MAGIC_SYSRQ=y`、`DEFAULT_ENABLE=0x1f6` ✅。F16(樹側):`build_dir/…/dbus-1.14.10/tools/dbus-send` 存在、`python3-base_3.11.14` ipk 存在 ✅。F19:`verify.py:16-42,181`、`ci.yml:45` `MIN_CHECKS=195`、`ci-check.sh` ✅。F20 ✅。F22:`ble-periph-254.sh:42-52`(第一動作 `mg rm-adv 1`)、`ble-lib-254.sh:78-134` ✅。F23 ✅。F4 / F5:`prov-base-254.sh:190-220`,無 `firstboot` ✅。F27 / F28 依 memory / §13 ✅。
- 其他:`IsTrial` 擋 stateChanging(`node.go:165-170`);rollback gate 只在 `cmd_rollback`(`batman-slot:771-791`);`_ab_arm_mesh` 規則(`platform-ab.sh:104-115`);`release --wait`(`batman-autocommit:151-165`);`halow-setkey:37-39` app-managed 警告;`vectors.json` 有 `cose.net_config / member_list / net_secrets`(§4.6 selftest 可做);requirements 釘 `noiseprotocol==0.3.1`;`scripts/node/prov-wbox-254.sh` 尚不存在(F1 一致);`deploy/ots` 無 `/dev/log`、`/tmp/run`、`/opt/batdata/state` bind。

## 無法核對的假設
- F16(節點側 `which`)、F17(主機 venv 實裝、藍牙 radio Off)、F18(arm64 runner 免費;無法上網)、F21(04 mgmt settings)、F28(04 S0)、F32(`git show f2f2bf6` 我沒重跑,沿用 v1 A 的查證)— 本審查未上機、未上網。
- E-H2 的「節點有無 unsquashfs」、單次 wbox build 時間;E-H1 的 RSSI;E-H6 的 sysrq 實測。
- `busybox tar` 是否保存 whiteout char device(`prov-base` 的 `/etc/banner` 負對照依賴它;`tree_manifest` 已記 `c*` 型別,restore 的「刪多出」路徑不依賴 tar 內容,所以結論仍成立,但 snap 的 tar 若遇 whiteout 可能印 warning)。
- `claim.verify` 的 `n.commit` 是否與 `commitTxn` 同一條 `.txn` 路徑(grep 找不到 `func (n *Node) commit(` 的定義行;`claim-after-persist` / `claim-before-shadow` 的對照以 `node.go:510-523` 的順序為準:commit → `SetLastKnown` → `setPassword`,語意成立)。

## 裁決

**REJECT**(BLOCKER 1:B1)。B1 讓 (3) / `prov-ota` 必 revert 並在 brewrite 前置停下,整個 prov 區塊在那裡 NEEDS-PERSON;修法是每個「member → OTA hold」單位多一次重開 + 斷言 `armed in radio-only mode`。M1–M6 都是在 15–22 h 無人值守下會製造假 FAIL、錯誤歸因或把 02 留在 B 的問題;一起修完整份再審(第 3 輪可只由一位做窄範圍複查,若 M2 的 upper 做法與 M6 的 lint 範圍沒有再牽動 §3 / §4.2)。
