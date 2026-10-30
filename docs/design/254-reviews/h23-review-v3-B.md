# 審查 B(第 3 輪):`254-h23-harness.md` v3(2026-10-28,唯讀;未碰 02 / 04)

審整份(v2 全文 + 每節「v3 修正 / 補充」合成後的設計)。先查 §3 / §5 缺列與雙寫者,再逐條對 §1.3 F1–F40 與 §4–§6 的判定字串 / 錯誤碼 / 行號對原始碼(Batman-h23 工作樹 c3a346b;firmware-2710 工作樹,含 `root-bcm27xx` staging rootfs 與 kernel 6.6.138 原始碼);協定面對 `219-protocol.md` §3.4 / §4.1 / §5.2 / §8 / §10;範圍對 `254-p1-impl.md` §4.3 / §4.10 / §5、`254-stage1-impl.md` §4.7 / §6.4 / §8;最後逐條核對 v2(A 與 B)每個發現。

## 摘要

v2 的 7 個 MAJOR 與 A 的 BLOCKER / 6 MAJOR 都有處置,其中 **B-M2 / A-M5((8) 三臂)、B-M3(`chan` mutant)只算部分解決**,另外 v3 新寫的內容裡有 4 個會讓測項做不出來、靜默縮小範圍或把事實寫錯的問題:(1) §6.2 的 autocommit (10) 不是上層的 (10)(L41 caller 偽造),L41 被靜默丟掉,§7 的 OTS actor 負測試指向一個不存在的測項;(2) `99zz-wbox-chan` 與 `99-batman-chanfix` 都是背景子殼,uci-defaults 檔名序只排「啟動」不排「生效」,兩者仍是賽跑;(3) (8) 臂 1 的 `WARN ble` 行在 autocommit 第一次 poll 就 latch(`autocommit.ble-warned`),harness 連上 trial 時早已印出 `hci0_powered=1` 版本,`btmgmt power off` 之後不會再印第二行 → 臂 1 ≡ 臂 2;(4) CI 的 Go 單元測試以非 root 跑,root-gated 測試 `t.Skip` 回綠(`TestWrongPeerClosed` 今天就是這樣),killpoint 單元的正向臂與 mutant 負對照在 CI 上一樣跑不到;(5) F30 寫錯:`scripts/dv/*.sh` **有**被 tmp-trust 掃(git pathspec `*` 跨 `/`;allowlist 第 71/72/75/87/95/97 行就是 `scripts/dv/` 條目),`prov-lib-254.sh:20` 今天過關是靠第 13 行 `scripts/*` 的無邊界前綴 `/tmp/run/batman-dv` 把 `batman-dvpc` 切掉;(6) p1-impl §5.3 `prov-misc` 的「socket 目錄預先放 symlink / 他人擁有 → 拒絕」在 v3 的 `prov-misc-254` 列裡不見了。

BLOCKER 0、MAJOR 6、MINOR 13。**APPROVE-WITH-CHANGES**(MAJOR 全收後 v4 可由一位做窄範圍複查;M1–M6 都不動架構)。

---

## MAJOR

### M1. §6.2 的 autocommit (10) 不是上層 (10);L41 被靜默丟掉;§7 的負測試指向它
- **情境**:stage1 §6.4 (10)(L41)= 「非 root 程序 / 容器 root 偽造 sysupgrade cmdline、相對路徑呼叫 → 判定正確(沒有 `ota-armed.mesh`);另外 `-T`、真 OTA、中止後 LuCI validate 三種 caller 各一次」(p1-impl §5.5 (10) 同)。v3 §6.2 的 (10) 列是「member 單台 → OTA V hold → `is healthy and HELD`」— 那是 stage1 (3) 的內容,與 v3 (3) 重複。§1.2 範圍寫「§5.5 (1)(3)(5/6)(7)–(10)」,§7 OTS actor 列的負測試寫「既有 autocommit (10)」— 兩處都指向一個設計裡不存在的測項。
- **證據**:`254-stage1-impl.md:423`;`254-p1-impl.md:451`;v3 §6.2 (10) 列、§7 表第 5 列;`platform-ab.sh:104-109`(caller 判定 = `/sbin/procd*` + `$RAM_ROOT/sbin/upgraded` + `_ab_live_sysupgrade`)。
- **修**:(10) 改回 L41:三個偽造 caller(非 root `sysupgrade -T`、容器 root 以相對路徑 / 假 cmdline 呼叫 `platform_check_image`、`-T`)→ p6 無 `ota-armed.mesh`;真 OTA → 有;判定 = 檔案存在與否 + 三欄格式。型別 `— / A / F`(不進 trial 就能做,只需 `sysupgrade -T` 與直接呼叫 `_ab_arm_mesh`)。§7 的指向跟著修。

### M2. `chan` mutant 與 `99-batman-chanfix` 仍是賽跑(v2 B-M3 只解一半)
- **情境**:v3 §4.2 `chan`:「uci-defaults `99zz-wbox-chan`(排在 `99-batman-chanfix` 之後)等 `wifi status` radio1 up 後 `uci set radio1.channel` + commit + `wifi reload`」。`99-batman-chanfix:28-55` 把整段邏輯放在 `( … ) &` 背景子殼:等 `wlh0` 出現(≤ 80 s)→ 每 8 s 檢查 uci 頻道 == p5 值,相符就 exit(a=0 時無 log),不符就 `uci set` + `wifi reload`,最多 6 次。uci-defaults 的檔名序只決定兩個檔案**開始**的順序(都在 S10 幾秒內),不決定兩個背景迴圈誰後動手。mutant 若在 chanfix 的某次檢查之前改頻道 → chanfix 把它改回 → mutant 無效 → (7) 的 04 不 revert → 假 FAIL / 錯誤歸因;若在 chanfix exit 之後才改 → 有效。順序取決於 `wifi status` 與 `iw dev wlh0` 誰先成立與 8 s 相位,不可預測。chanfix 的子殼沒有可 `pgrep` 的名字(uci-defaults 由 `uci_apply_defaults` 以 `( . ./file )` source,cmdline 是 boot init 的),mutant 也等不到它結束。
- **證據**:`99-batman-chanfix:22-55`;uci-defaults 執行方式 = OpenWrt base-files `uci_apply_defaults`(subshell source;未在樹中複驗,⚠️)。
- **修**:mutant 不做一次性改寫,改做**比 chanfix 活得久的重複斷言**:背景迴圈從 radio1 up 起每 5 s 讀 `uci get wireless.radio1.channel`,≠ 目標值就 `uci set` + commit + `wifi reload`,持續 ≥ 200 s(> chanfix 最長 80 + 6×8 s)後 exit;log 一行 `wbox-chan: asserted <ch> (<n> times)`(見證字串放這裡)。(7) 的前置斷言 = 「trial 120 s 內 radio1 channel ≠ p5 值且 `batctl n` 空」;chanfix 的 `gave up reasserting` 行若出現 = mutant 生效的旁證(不當判定)。

### M3. autocommit (8) 臂 1 的順序讓 `WARN ble` 行在 harness 動手前就 latch(v2 B-M2 / A-M5 部分解決)
- **情境**:v3 (8) 臂 1 = 「`ble-ok` 在 + `btmgmt power off` → `WARN ble: … hci0_powered=0 …`」。`batman-autocommit:496-499`:每次 poll,`ble-ok` 在且 `autocommit.ble-warned` 不在 → 印一次 WARN 並 touch `ble-warned`;之後**本次開機不再印**。autocommit S99 開機即進 poll(`:487`),helper S89 `Run` 一開始 `Tick(15)` 已寫 `hci0_powered=1`(F14)。harness 以 ssh 進 fresh B trial 至少要 60–90 s,此時 WARN 已以 `hci0_powered=1 … adv_registered_once=0` 印出並 latch;之後 `power off` 不會產生任何新行 → 臂 1 的判定字串永遠是臂 2 的。
- **證據**:`batman-autocommit:487,496-500`;`health.go:160-163`;`etc/init.d/batman-autocommit:6`(START=99)。
- **修**:臂 1 改序:OTA 前 `state-set` 移除 `ble-ok`(STATEFILES,restore 會放回)→ trial 內 `btmgmt power off` → 等一個 health tick(≤ 15 s)讀到 `hci0_powered=0` → `state-set` 放回 `ble-ok`(trial 未 committed,helper 不會自己寫,`health.go:166`)→ 下一次 poll 印 `WARN … hci0_powered=0 …` + HELD。臂 2 / 臂 3 不變。寫明 P1 期臂 2 的行是 characterization(v3 已寫)。

### M4. CI 的 Go 單元測試以非 root 跑:root-gated 測試 `t.Skip` 回綠;killpoint 單元在 CI 跑不到正向臂
- **情境**:`ci.yml:73` 的 Go 步驟是 `go test ./...`(無 sudo、無 `-tags`)。`sock_test.go:13-17` `needRoot` 非 root → `t.Skip` → 綠。F20 說「`TestWrongPeerClosed` 已覆蓋 PEERCRED 負對照」— 它在 CI 上今天**從沒跑過**(只在 WSL root 手動跑)。§4.1.1 的 killpoint 單元:「正確 → armed + 刪」需要 root 擁有的檔(契約:檔 root 0600)— 非 root 建不出 uid 0 的檔;「mutant 拿掉 link count → FAIL」的負對照同樣需要正向臂先成立。照 v3 寫法,這兩個會變成 skip 或永遠 refused,CI 綠燈沒有鑑別力(通用規則:找不到東西可查的測試必須 FAIL)。
- **證據**:`.github/workflows/ci.yml:70-73`;`feed/batman-prov/src/sock/sock_test.go:13-17,67-68`;§4.1.1、§6.1 `prov-p1-stubs`。
- **修**:(a) CI 加一步 `sudo -E go test -tags prov_test ./cmd/batman-provhelper/... ./sock/...`(root,loop-device 那步已用 sudo),並在 job 內 `go test -v | grep -c SKIP` = 0 斷言(skip = FAIL);(b) killpoint 檢查的 expected uid 不寫死 0 而是「= 程序 euid」或以 build tag 注入,讓非 root 也能跑正向臂(擇一;若選 (b),節點上仍是 root);(c) F20 改寫為「存在,CI 上目前被 skip」。

### M5. F30 寫錯:`scripts/dv/*.sh` 有被 tmp-trust 掃;§2.2 的 allowlist 計畫與「`batman-dvpc.*` 條目不需要」的理由都建立在這個錯誤上
- **情境**:`check-tmp-trust.sh:29` 的 `git ls-files -- 'scripts/*.sh'` 是 git pathspec,`*` 跨 `/`(實跑:12 個 `scripts/dv/*.sh` 列入;allowlist 第 71、72、75、87、95、97 行本來就是 `scripts/dv/` 的條目)。`prov-lib-254.sh:20` 的 `/tmp/run/batman-dvpc.$RUN` 今天過關不是因為「不掃」,而是第 13 行 `scripts/*` 的 regex `/tmp/run/batman-dv` **無邊界**,把 `/tmp/run/batman-dv` 從 `batman-dvpc.$RUN` 裡切掉 → 剩 `pc.$RUN` 不含 `/tmp` → 放行(與 F30 指的第 99 行同一類缺陷)。後果:新的 `scripts/dv/prov-254.sh`、`prov-<unit>-254.sh` 裡任何 `/tmp/run/batman-prov-test`、`/tmp/run/batman-provd-test` 字面都會 UNTRUSTED(沒有條目);`/tmp/run/batman-dv/wbox/` 則被第 13 行吃掉(無邊界)。
- **證據**:`check-tmp-trust.sh:24,29`;`tmp-trust-allowlist.txt:13,71,72,75,87,95,97`;`git ls-files -- 'scripts/*.sh' | grep -c ^scripts/dv/` = 12;`bash scripts/check-tmp-trust.sh` = 0 untrusted(2026-10-28)。
- **修**:F30 改寫;§2.2 的條目改為:`scripts/dv/prov-254.sh` + `scripts/dv/prov-*-254.sh` 各加 `/tmp/run/batman-prov-test([^-]|$)`、`/tmp/run/batman-provd-test([^-]|$)` 條目(理由:root 0700 / provd 0700,節點端由 `prov-wbox-254.sh` 以 `mkdir` 非 `-p` 建);第 13 行收緊為 `/tmp/run/batman-dv([^-a-z]|$)` 並給 `batman-dvpc\.` 自己的條目(`scripts/dv/prov-lib-254.sh`,理由 = root 0711、`mkdir` 無 `-p` 故 EEXIST 即拒);`test-tmp-trust.sh` 加一個案例:`scripts/dv/x.sh` 含 `/tmp/run/batman-dvpc-evil` → UNTRUSTED。

### M6. p1-impl §5.3 `prov-misc` 的「helper socket 目錄預先放 symlink / 他人擁有 → 拒絕啟動」被靜默丟掉
- **情境**:p1-impl §5.3 `prov-misc-254`:「L11 helper 重啟;**socket 目錄預先放 symlink / 他人擁有 → 拒絕**;L9 / L10 …」。v3 §6.2 `prov-misc-254` = L38 / L42 / L43 / L51 / L11 / L9 / L10 / L27 / L3,沒有這條;§1.2「不在本 PR」沒列;§7 第 1 列的「`nobody` 預建 → refused」是 killpoint 目錄,不是 helper socket 目錄。F11 證明機制存在(`PrepareDir`:非 root 擁有 / symlink / 目錄裡多一個東西 → `sock: … refusing to start`),但沒有節點端的黑箱測試;Go 單元那邊的 `needRoot` 又在 CI 被 skip(M4)。
- **證據**:`254-p1-impl.md:375`;`sock.go:37-78`;v3 §6.2。
- **修**:進 `prov-sec-254` tier A 白箱(lease 內:停 helper → root 以 `ln -s /tmp/x /tmp/run/batman-prov` / `chown 471` 預建 → 啟 helper → log `sock: … refusing to start` + socket 不存在 → 還原 → 啟 helper 正常)或在 §1.2 列為不做並給理由。

---

## MINOR

### m1. F29 的 sysrq 語意寫反:`/proc/sysrq-trigger` 不看 mask
`drivers/tty/sysrq.c:1152-1164`(kernel 6.6.138,firmware 樹)`write_sysrq_trigger` → `__handle_sysrq(c, false)`;`:598` `if (!check_mask || sysrq_on_mask(...))` → 經 proc 寫入**永遠執行**,`kernel.sysrq` 只管鍵盤。所以 (a) F29「mask 不含 0x80 時寫入成功、動作被忽略」不成立;(b) §4.1.1 的 `sleep 2` fallback 是死碼(留著當保險可以,但不要寫成「F29 的理由」);(c) P9「`kernel.sysrq` 含 0x80」對此無關,可留作 E-H6 旁證但不應是 FAIL 條件。E-H6 實測會證實。

### m2. §4.2 的 tag 規則自相矛盾
文字:「**所有 `helper-*` 變體也設 `BATMAN_PROV_TEST=1`**」;表格:`helper-exit1 | —`、`helper-flap | —`。`helper-exit1`(shell 取代 Go)設不設都沒意義(§4.1.3 已說只以見證判),`helper-flap` 是否 prov_test 影響 P9 的「helper 標記 ≠ 0 → FAIL」與 (9) 跨槽還原的 gate 判定。擇一寫死,`lint-wbox` 照表驗。

### m3. autocommit (4) 從 §1.2 範圍消失,沒有理由
v2 有 (4)(`chan` 單台);v3 §1.2「§5.5 (1)(3)(5/6)(7)–(10)」把 (4) 拿掉,§1.2「不在本 PR」與 §9 都沒提。若意思是「(7) 的 04 臂 = (4)(有鄰居、改頻道 → revert)」就寫一句;`chan` 變體的「用在」欄也要對齊。

### m4. `prov-sec-psk-timing-254`:n 公式退化;節點等逾時的契約沒寫進 sock 層
- 公式 `n ≥ (2·1.96·MAD / 效應量)²`,效應量 = PASS 門檻 `max(2·MAD, 5 ms)`:MAD ≥ 2.5 ms 時 n ≥ (2·1.96·MAD / 2·MAD)² = 3.84 → 永遠 n = 4。中位數差的 SE ≈ 1.2533·σ·√(2/n),等價檢定要 CI 半寬 ≤ 門檻 → n ≥ (1.96·1.2533·√2·MAD·1.4826 / 門檻)²,並給下限(建議 n ≥ 30、上限 200 不變)。
- 219 §3.4:錯 PSK「送出後和真 session 一樣**等到逾時才斷線**」。v3 讓 `peer.py` 收到假 msg2 就主動斷;provd 若在「等逾時」期間不收 EOF(或收了但 session 槽到 10 s 才釋放),錯臂每條連線仍佔用 §8 的 2 個同時連線 10 s → 第 3 條被拒,資料被 E_BUSY / 斷線汙染。§4.8.3 / 219 §10 要加一條 P2 契約:「假第 2 則送出後,peer 斷線 → 立即釋放連線槽(BLE 斷線本來就如此,sock 比照)」,並在 §6.3 寫錯臂的並行度 ≤ 2。

### m5. `prov-legacy-upgrade-254` 兩臂之間要重做 `strip-p5-prov`
負對照臂讓 `rc9-unclaimed` helper 在 A trial 開機:rc 9 路徑會產生身分(p1-impl §5.1 `prov-unit-helper`:「rc 9 且 overlay 完整也產生」),並可能 `--save` seed p5(`.seeded` / prov.meta unclaimed)。p5 是兩槽共用;正向臂(V 進 A → `verdict=legacy`)若看到已 seed 的 p5 就不是 legacy → 假 FAIL。兩臂之間加 `strip-p5-prov` + 斷言 p5 無 `.seeded` / prov.meta;或把負對照臂改到正向臂之後(正向臂結束 = A committed V,再 hold OTA mutant 進 B → rollback)。

### m6. `prov-sandbox` 的底 rootfs 從哪來、怎麼認證沒寫
§4.4「`unsquashfs` 底(釘住 `base.env`:版本 + sha)」:CI runner 要下載一個 rc 的 `root.squashfs`(~100 MB)。來源(firmware repo release asset?private?token?GitHub artifact 保留期?)與「sha 不符 → job FAIL」要寫進契約;§1.2 又說 release asset 由 firmware CI 產、Batman tag push 時不存在 — 若 `prov-sandbox` 依賴它,PR CI 在 rc 之前拿不到底 → 要寫「E-H3 前用哪個版本」。

### m7. `prov-sec-dvpc-254`:機制已經存在,設計把它寫成要新加
`prov-lib-254.sh:92` 是 `mkdir -m 0711 $PCD`(無 `-p`)+ `set -e`:路徑已存在(檔、目錄、symlink 都算)→ EEXIST → 「tool placement」FAIL。F23「沒有放置負測試」正確,但 §4.5 的「`mkdir` 前 `lstat` …」是多餘的(且 lstat→mkdir 之間還多一個視窗;`mkdir` 本身原子)。改寫為「機制 = `mkdir` 無 `-p`;本 PR 只加白箱(root 預建 symlink → `tool placement` FAIL)與一行明確的 `FAIL dvpc dir pre-exists` 訊息(從 `mkdir` 的 rc 判)」。

### m8. helper 的拒絕字串有尾巴
`sock.go:138` 是 `connection refused: peer uid %d (want %d) %v` → 實際行是 `… (want 471) <nil>`。§4.5 的 grep 用前綴(`grep -F 'connection refused: peer uid 65534 (want 471)'`)即可;不要 `-x`。

### m9. `radio1-off` 變體的 uci-defaults 檔名要排在 96 之後
96 在 S10 把 p5 `overrides.uci` 寫回 uci(含 radio1);mutant 檔名若排在 96 之前就被覆蓋。指定 `99zz-wbox-radio1-off`(在 `99zz-batman-prov-state` 之後,`r` > `b`),並在 `lint-wbox` 驗「新 uci-defaults 檔名 ≥ `99zz-`」。

### m10. §7 表第 3 列仍寫 `root:provd 0750 目錄、0660 socket`
「v3 修正」一句把它改成 provd 0700,但表格原文沒改;§3 第 3 列已是 0700。合併(規則:override 不清楚處要標)。

### m11. `pr_normalise` 的 1500 s lease 偏緊
正規化 = hold OTA(`sysupgrade -n` 3 分 + `waitboot` 上限 900 s)+ HELD(≤ 480 s)+ `release --wait`(canary:04 有 OTS,docker 起來 1–3 分)+ settle 90 s。`waitboot` 用滿就超過。改 1800 s 或與 `pr_begin` 同一套「落點後 +900」規則。

### m12. `prov-unit-sbx` / `peer-vs-provd` 的 `continue-on-error` 期間要有「紅了誰看」
E-H3 前 `continue-on-error: true` 的 job 在 PR 頁是綠勾(只有 job 內部紅)。依「開 PR 後必看 CI」規則,PR body 要貼該 job 的結論,或在 job 最後一步 `echo "::warning::prov-sandbox FAILED (continue-on-error)"` 讓 annotations 看得到。

### m13. `99zz-wbox-chan` 與 §4.2 的 `chan` 列:寫明只在 fresh overlay 第一次開機跑
uci-defaults 只在 B trial 的第一次開機執行(exit 0 後自刪;背景子殼續跑)。(7) 的 04 revert 回 A 後 B 的 overlay 留著已執行過的狀態 — brewrite 會重寫 B,所以沒事;但若單位中途以 `restart`/重開再進 B(不會,tryboot 一次性),mutant 不再跑。寫一句,免得實作時拿它做第二次 trial。

---

## v2 發現 → v3 處置核對

| v2 | 解了? | 說明 |
|---|---|---|
| A-B1 `lastjoined` | 是 | §4.3 通則(member → `reboot committed` → OTA);F33 ✅(`joinwatch:135` 唯一寫者、`platform-ab.sh:111` 讀);(3) / `prov-ota` / `leave-ota` 都加重開;trial 斷言 `:420` + `:425` 字串逐字 ✅ |
| A-M1 (5)/(6) | 是 | (6) 兩臂(無檔 / 舊 boot_id)字串 `:421` / `:425` / `:502` / `:505` 逐字 ✅;hold + 480 s `back_to_a` 與 p1-impl §4.5.4 一致;`held_commit` 只擋 commit(`:60,277`),watchdog 的 `held` 是 hold-once(`:94-100`)不是這個 ✅ |
| A-M2 trial 內負對照 / txn-3 | 是 | `upper-helper` + 通則 + 每列標法;`IsTrial` 擋 stateChanging(`node.go:165-170`)✅;txn-3 → `helper-nogen` ✅ |
| A-M3 bad-slot 順序 | 是 | `pr_end` 步驟 1 在 restore 前;`overlay-restore` 的 STATEFILES `rm -f`(`prov-base-254.sh:29,215-217`)✅ |
| A-M4 (7) 02 | 是 | 02 `back_to_a`、不 release、不 brewrite;例外斷言 |
| A-M5 / B-M2 (8)(9) | **部分** | 三臂括號內容寫了,但 **M3**:臂 1 的 WARN 在 harness 動手前已 latch;(9) characterization ✅ |
| A-M6 wbox × 板 patch / exit1 / stamp / 成本 | 是 | `lint-wbox` 對套板 patch 樹 + 檔案清單;`helper-exit1` 改 Makefile install(`Makefile:49-53` 可改 ✅);17 變體 sha;§7.3 數字 |
| B-M1 socket 目錄 | 是 | provd:provd 0700;`sock-as 471` = owner → 進得去,65534 → EACCES ✅;m10 表格殘文 |
| B-M3 chanfix 行 | **部分** | 不依賴 log 行 ✅,但 **M2**:兩個背景迴圈仍賽跑 |
| B-M4 rpa 三態 | 是 | §6.3 三態 + F28 時間條件 ✅ |
| B-M5 dbus-send wrapper | 是 | F16 改 `.libs`(77424 B ELF ✅、wrapper 10004 B bash ✅);ELF 斷言;E-H1 `readelf -d`;root 正向改 Introspect ✅(04 的 `bluetooth.conf` 無 default policy,只 root:`patches/ekh-bcm2711/0012`、staging rootfs `etc/dbus-1/system.d/bluetooth.conf` ✅ → uid 471 連 Introspect 都 AccessDenied,§6.3 tier A 的期望成立) |
| B-M6 / A-m14 dvpc | 是 | `prov-sec-dvpc-254`;m7(機制已在) |
| B-M7 timing 限速 / n | **部分** | 節流 18 / 分、交錯、主動斷 ✅;**m4**:n 公式退化、sock 側「等逾時」契約缺 |
| A-m1 sysrq 退路 | 是(但 m1) | `sleep 2` 偵測寫了;前提 F29 錯,fallback 是死碼 |
| A-m2 / B-m10 normalise lease / 殘骸 | 是 | §4.3 自取 lease;§5 新列;P9 訊息;m11 lease 長度 |
| A-m3 時間 / brewrite 省略 | 是 | lease 3000 + 900 + 1800;步驟 3 條件式 brewrite;§7.3 |
| A-m4 / A-m5 txn-2 字串 / txn-5 視窗 | 是 | F13 兩行逐字 ✅(`main.go:491`、`boot.go:43,59`);txn-5 = `--save` 後回應前(`node.go:1120-1125` ✅) |
| A-m6 96 行號 | 是 | F13 以呼叫字串;`96:104-115` 唯一 exit ✅ |
| A-m7 lock-failsecure 前置 | 是 | F37 ✅(`batman-prov-lock:7-11,50-56`) |
| A-m8 / B-m8 DNODE 機制 | 是 | `$cmd` 展開後含 DNODE0 IP;`suite()` 收到的 `$3` 已展開(`:335` `$OTS_NODE`、`:2175` `$MESH_NODE` 在呼叫端展開)✅ |
| A-m9 / B-m9 2f | 是 | 2f = #305 tier B(`bt-uart-boot-305` D 類)✅ |
| A-m10 rundir-paths | 是 | 不改,理由正確(`rundir-paths.txt:1-4`)✅ |
| A-m11 02 認領 / 金鑰保留 | 是 | `claim.verify` 先(F38 ✅ `node.go:218-224,998`);`pr_abort` 保留金鑰;§7.2 |
| A-m12 fakeSys | 是 | PATH stub,真 `realSys`;§4.1.2 封閉清單一致 |
| A-m13 02 batctl 窗 | 是 | 180 s |
| A-m15 F7 / F34 / CONN-CLOSED / dbus root / noiseprotocol | 是 | F7 `:38-44,52-53` ✅;F34 兩個 `-ldflags` ✅(`golang-package.mk:236-262`);CONN-CLOSED 標 provclient 自印 ✅;m8 字串尾巴 |
| B-m1 F3 | 是 | 14 ✅(`:208` harness-negctl + 13) |
| B-m2 F12 | 是 | 任何 COMMITTED `rm -f bad-slot`(`:537`)✅;`:361` 是拒絕 commit ✅ |
| B-m3 120 s | 是 | txn-2 ≥ 120 s(`main.go:441`)✅ |
| B-m4 clean -fdx | 是 | §4.2 |
| B-m5 Go 見證字串 | 是 | §2.1 / §4.1.3 / lint |
| B-m6 replay 失敗計 | 是 | F40 ✅(`node.go:94,542-549`) |
| B-m7 NEVER_KNOWN | 是 | §2.2;`NEVER_KNOWN` 是 ERE(`:2740`),加 `|NEEDS-PERSON|blocked: DNODE`(§3 表裡的 `\|` 只是 markdown 跳脫,實作用 `|`) |
| B-m11 deadman 共用 | 是 | 重用 `dm_arm` / `$ST/dm`(`ble-lib-254.sh:107-134`)✅ |
| B-m12 dbus root 副作用 | 是 | Introspect / `Properties.Get`;RegisterAgent 只在 tier B 並 Unregister |
| B-m13 radio P9 / scan response | 是 | P9 WinRT state;E-H1 bleak 合併 |
| B-m14 scalar 規則 | 是 | F19 ✅(`gen.py:37-38,184`;`vectors.json` note 逐字) |
| B-m15 tmp-trust 範圍 | **否** | **M5**:F30 事實錯,§2.2 的結論建立其上 |
| B-m16 一次 restart | 是 | `push-helper` 先寫 killpoint 再一次 restart |
| B-m17 brewrite 02 | 是 | `pr_brewrite <node>` 依角色(`brewrite-254.sh:37` `-ge 6` ✅) |
| B-m18 parser 測試 | 是 | 四案例;`read -r ks pat iss`(`:2749`)第 4 欄併進 `iss` 由 daily-validation 處理 |
| B-m19 (1) reason 字串 | 是 | F12 `why` 表逐字 ✅(`:494,502,503`);(1) 列寫「以 `health_ok` 的 why 表為準」 |

## 假設驗證表

| 設計主張 | 結果 | 證據 |
|---|---|---|
| F3 14 | ✅ | `daily-validation.sh:208,214,227-296` |
| F4 restore 逐檔 + STATEFILES `rm -f`,無 firstboot | ✅ | `prov-base-254.sh:29,190-220` |
| F6 `version=` 時間戳;payload 只 SHA256SUMS + metadata | ✅ | `build-ab-payload.sh:69-71` |
| F7 stamp 行號 / check-board-patches / witness list;`-i`;第 7 步 witness check;`GO_PKG_TAGS` | ✅ | `stamp-batman-build.sh:38-49,52-53`;`build-board.sh:86-96,166`;`golang-package.mk:106-111,260-262`;`package.mk:114`、`depends.mk:14` |
| F8 CLI / 非 root exit 2 / daemon `boot.Run` + 120 s / `--boot` 立即 | ✅ | `main.go:373-407,439-443,479-491` |
| F9 錯誤碼;trial → `EBusy "trial slot (updating)"` 第一條 | ✅ | `node.go:33-50,165-170`(另有 `EForbidden 3`、`EBadObject 4`) |
| F10 provclient | ✅ | `provclient/main.go:294-305,417-424,470,489-560` |
| F11 `PrepareDir` / 0660 / uid 拒絕 | ✅ | `sock.go:37-78,136-141`(字串尾 ` %v`,m8) |
| F12 全部字串與行號 | ✅ | `batman-autocommit:151-165,192-195,238-244,277-288,361,412-426,494-505,513,537` |
| F13 96 / helper 字串;96 唯一 exit | ✅ | `96:104-115,168,193`;`boot.go:43,59,72,187`;`main.go:491` |
| F14 stale 60 s、`Tick(15)` 啟動、`adv_registered_once=0`、`ble-ok` 條件 | ✅ | `health.go:8-9,138,151,160-166` |
| F15 chanfix 只在 reassert ≥ 1 印 | ✅(但 M2) | `99-batman-chanfix:45-55`;是 uci-defaults,背景子殼 `:22-28` |
| F16 wrapper vs `.libs`;節點 `libdbus-1.so.3` | 樹側 ✅;節點側 ⚠️ 未上機 | `tools/dbus-send` 10004 B `#! /bin/bash`;`.libs/dbus-send` 77424 B |
| F19 verify.py / gen.py / MIN_CHECKS 195 / pin | ✅ | `verify.py:16-36,176-186`;`gen.py:37-38,184,225-227`;`ci-check.sh:12`;`ci.yml:45`;`requirements.txt` |
| F20 go.mod;`TestWrongPeerClosed` | ✅ 存在 / ❌ CI skip | `go.mod`;`sock_test.go:13-17,67`;`ci.yml:73`(M4) |
| F22 `adv-on` 第一動作 `rm-adv`;`dm_arm` 單一 | ✅ | `ble-periph-254.sh:45`;`ble-lib-254.sh:107-134` |
| F23 `pl_prep` / brewrite 預設 / docker ≥ 6 | ✅ | `prov-lib-254.sh:88-92`;`brewrite-254.sh:4,21,37` |
| F24 chain1 | ✅ | `chain1-254.sh:27,135-137,145,259,362` |
| F25 `suite()`、DNODE 變數、`NEVER_KNOWN`、`read -r ks pat iss`、2f | ✅ | `daily-validation.sh:77-99,127,386,2740-2749` |
| F26 7 行 3 欄 | ✅ | `validation-known-failures.txt:10,19-24` |
| F29 `0x1f6`;mask 語意 | 行號 ✅ / 語意 ❌ | `.config:6904-6905`;`sysrq.c:1152-1164,571,598`(m1) |
| F30 `:99` 無邊界;`scripts/dv` 不掃 | 前半 ✅ / 後半 ❌ | `check-tmp-trust.sh:29`;allowlist `:13,71-97`(M5) |
| F31 apply 刪 `.protected`;rollback gate 只擋 claimed/member | ✅ | `batman-slot:424-436,771-791` |
| F33 `lastjoined` 唯一寫者、無刪除者;`_ab_arm_mesh` | ✅ | `joinwatch:135`;`platform-ab.sh:104-115`;grep |
| F34 兩個 `-ldflags` + `-buildvcs=false -trimpath` + `-tags` | ✅ | `golang-package.mk:234-262` |
| F35 deploy/ots 無三個 bind | ✅ | grep 零命中 |
| F36 gate 位置 / `$WR/r`;REQUIRED 不含 helper | ✅ | `build-board.sh:146-172`;`check-go-toolchain.sh:16` |
| F37 S13 收斂條件 | ✅ | `batman-prov-lock:7-11,50-56` |
| F38 owner-op 首版信任錨;legacy 先 `claim.verify` | ✅ | `node.go:218-224,996-1000` |
| F39 `--save` 後只剩回應;prov-state 寫者 | ✅ | `node.go:1114-1127`;`boot.go:57-61` |
| F40 replay 計失敗 | ✅ | `node.go:94,540-549` |
| §4.5 dbus:uid 471 → AccessDenied(P1 期) | ✅ | staging rootfs `etc/dbus-1/system.d/bluetooth.conf`(只 root policy,無 default);`patches/ekh-bcm2711/0012` |
| §4.8.2 frame / `max_msg` 8192 / 控制包長度 1 無歧義 | ✅ | 219 §4.1、§8;frame ≥ 3 B |
| §4.9 預算 3 + 18 = 21 / scan response 13 B | ✅ | 算對 |
| §6.3 two-phones `E_BUSY` | ⚠️ 設計決定(provd 需實作) | 219 §5.2 有 7;helper `EBusy` 只給 trial |
| §6.3 `claim/replay` 10 / h、`E_RATE` 12 | ✅ | `node.go:548-549`、219 §8 |
| uci-defaults 以子殼 source、依檔名序 | ⚠️ 依 OpenWrt base-files(樹中 `root-bcm27xx/lib/functions.sh` 未找到,未複驗) | — |
| F1、F2、F17、F18、F21、F27、F28、F32、04 無 unsquashfs、bleak WinRT 合併、`noiseprotocol` Windows wheel、04 upper opaque、E-H6 sysrq 實測 | ⚠️ 未上機 / 未上網 | — |

## 範圍對照(p1-impl §5 / stage1 §8–§9)
- 涵蓋:§5.1 全部、§5.2、§5.3(除 M6 一條)、§5.4 鏈 0、§5.5 (1)(3)(6)(7)(8)(9)、§5.6、§5.7;stage1 §8 的 `prov-sec-*`、provd A-N2 / B-m2、§9 tier 列。
- 靜默丟掉:§5.5 (10) L41(M1,被另一個測項頂替名字)、§5.3 `prov-misc` socket 目錄預建(M6)、§5.5 (4)(m3,若由 (7) 涵蓋要寫)。
- 多出且有說明:`prov-sec-psk-timing`(m4 後可留)、`ble-rpa` provd 模式。
- 不在本 PR 且理由可接受:P3 / bcm2710 真機 / L16 / iPad 自動化 / `prov-rename` / 真斷電 / release asset 掃描 / `docs/validation` 文字 / (5) 刪檔不可測(理由 ✅:autocommit `:419` 一次讀)。

## 結論

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 6 / MINOR 13)。M1、M6 是範圍靜默縮小(其中 M1 讓 §7 的一個負測試指向不存在的測項);M2、M3 會讓兩個負對照 / 臂在真機上無鑑別力並錯誤歸因;M4 讓 CI 的 Go 單元(含新的 killpoint 單元)以 skip 回綠;M5 是事實錯、會在 harness PR 的 CI 上以 UNTRUSTED 紅燈現形(不是靜默)。都有明確修法,不動架構;v4 可由一位做窄範圍複查(M1–M6 + m1–m5),除非 M2 的 mutant 改法或 M4 的 CI 改法再牽動 §4.2 / §6.1。
