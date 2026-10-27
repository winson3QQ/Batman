# 審查 B(第 2 輪):`254-h23-harness.md` v2(2026-10-28,唯讀;未碰 02 / 04)

審整份。先查 §3 / §5 的缺列與雙寫者,再逐條對 §1.3 事實與 §6 判定字串、錯誤碼對原始碼(repo `Batman-h23` main 5914f03 工作樹;firmware `firmware-2710`);協定面對 `219-protocol.md` v0.7 / CDDL;範圍對 `254-p1-impl.md` §5、`254-stage1-impl.md` §8–§9;最後逐條核對 v1(A 與 B)每個發現是否真的解掉。

## 摘要

v1 的三個 BLOCKER 都解了(順序 + `pr_normalise`、`push-helper` + `test` 變體契約、frame socket 分目錄),judgement 字串大多已對回原始碼。還剩下 7 個會讓**正確的產品被判 FAIL**或**測項做不出來**的問題:(1) provd 測試 socket 目錄 root:provd 0750 → uid 471 `bind()` EACCES(同 v1 B3 類);(2) autocommit (8)(9) 在 P1 的 health 永遠 `adv_registered_once=0`,`WARN ble` 行不論注入與否都出現 → 無鑑別力;(3) `chan` mutant 等的 F15 settled 行只在至少 reassert 一次時才印;(4) `ble-rpa` provd 模式「RPA 改變 ⇔ 重註冊」與 F28 不符;(5) F16 的 `dbus-send` 是 libtool wrapper 不是二進位;(6) p1-impl §4.3 provclient 放置負測試仍被靜默丟掉;(7) `prov-sec-psk-timing` 沒把 §8 的 20 / 分全域限速與「假訊息等逾時才斷」算進去。

BLOCKER 0、MAJOR 7、MINOR 19。**APPROVE-WITH-CHANGES**(MAJOR 全收後 v3 整份再審)。

---

## MAJOR

### M1. provd 建不了 `gatt.sock`:目錄 root:provd 0750,uid 471 沒有寫入權
- **情境**:§3「`/tmp/run/batman-provd-test/`(root:provd 0750)、`gatt.sock`(provd,0660)… 目錄由 provd init 建(同 `PrepareDir` 規則)」。`PrepareDir` 的規則是 root 擁有、0750(`sock.go:37-55`),而 socket 由**root 的 helper** 建。provd 以 uid/gid 471 在一個 root 0750 目錄裡 `bind()` 需要目錄的 w 位 → EACCES。乙部主傳輸整個不通,CI `peer-vs-provd` 第一步就掛。這和 v1 B3 / A-M6 是同一類錯,只是換了目錄。
- **證據**:`sock.go:37-55`(0750 root);stage1 §4.7(provd uid 471);§3 第 3 列。
- **修**:目錄 `provd:provd 0700`(init 以 root `mkdir`+`chown 471:471`+`chmod 0700`;provd 自己 `O_NOFOLLOW` 驗 owner=471、非 symlink)或 `root:provd 1770`;harness 以 `provclient sock-as 471` 連(需目錄 x 位 → 0700 owner provd 即可)。§7「本機非 root 連 provd 測試 socket → EACCES」的擋法改寫成「目錄 0700 provd 擁有」。

### M2. autocommit (8)(9) 的 `WARN ble` 行在 P1 **必然**出現,注入無鑑別力
- **情境**:`batman-autocommit:496-499` 只在 health 行含 `bluetoothd=1`**且**`hci0_powered=1`**且**`adv_registered_once=1` 時不印 WARN;health 由 helper 寫,`health.go:137-139` 固定 `adv_registered_once=0`(註解:「P1 always writes 0」)。所以 P1 上只要 `ble-ok` 在,WARN 行**一定**印,`btmgmt power off`(8)或 `helper-flap`(9)有沒有做都一樣。(8) 兩臂現在只鑑別 `[ -f ble-ok ]` 這一條 gate,不鑑別 health;(9) 的判定(`WARN … (no health file)` + `HELD`)同樣對 mutant 不敏感。§6.2 把 (8) 寫成「`btmgmt power off` → WARN」是把因果寫錯。
- **證據**:`batman-autocommit:496-499`;`health.go:9,137-139`;stage1 §6.4「`ble-ok` 存在才檢查 `bluetoothd=1 hci0_powered=1 adv_registered_once=1`」。
- **修**:(8) 甲部 = 「`ble-ok` gate」測項(兩臂:在 → 有行;不在 → 無行),**明寫 P1 不能驗 power off**;要驗 health 分支就白箱:bind 一份 health 視圖(三欄全 1)到 `$RUNDIR/batman-prov.health` → 無 WARN(正向),再 bind 一份 `hci0_powered=0` → 有 WARN;真正的 power off 臂移到 H3(provd 把 `adv_registered_once` 寫 1 之後)。(9) 同理:P1 上只能證「HELD + release → commit(P-U5)」,標為 characterization。

### M3. `chan` mutant 等的「settled」行只在 reassert ≥ 1 次時才印 → 大多數開機 mutant 永遠不觸發
- **情境**:§4.2 `chan`:「等 F15 settled 行後 `uci set radio1.channel` …」;§6.2 (4):「F15 settled 行(150 s 內沒出現 → FAIL『mutant 無效』)」。`99-batman-chanfix:47` 是 `[ "$a" = 0 ] || logger … "radio1 channel is $CH (settled after $a reassert)"`:第一次檢查就相符(`a=0`)→ **靜默 exit 0,沒有任何行**。fresh B trial 的 radio1 channel 多半一開始就對 → mutant 等不到行 → (4)(7) 每次都「mutant 無效」FAIL,不是產品問題。
- **證據**:`99-batman-chanfix:45-55`。
- **修**:mutant 不以 log 行為觸發:S99 init(START 在 chanfix 之後)輪詢 `uci get wireless.radio1.channel == p5 值` 且 `wifi status` radio1 up 後再改;或改用 `99-batman-chanfix` 的 **exit** 當同步點(mutant 以 uci-defaults 檔名排在 `99-batman-chanfix` 之後,uci-defaults 依序執行)。(4) 的前置改為「trial 的 radio1 channel ≠ p5 值且 120 s 內不在 mesh」。

### M4. `ble-rpa-254` provd 模式的判定「RPA 改變 ⇔ provd 重註冊」與 F28 矛盾
- **情境**:§6.3「判定改為『RPA 改變 ⇔ provd 重註冊事件』」。stage1 F28(`hci_core.c:2502`、`mgmt.c:1016-1029`、`hci_sync.c:2050-2056`):新 RPA **只**在「廣播重新啟用」且「`HCI_RPA_EXPIRED` 已設(距上次換 ≥ `rpa_timeout` 900 s)」時產生。provd 因連線 / 斷線 / health 在 900 s 內重註冊 → **同一個 RPA**。照 v2 的 ⇔,每一次 `peer.py` 連線後的重註冊都會被判「重註冊但 RPA 沒變 → FAIL」。v1 B-M10 的修法被照抄成等價關係,沒有把 F28 的時間條件帶進來。
- **證據**:stage1 §1.2 F28、D24;§6.3 `ble-rpa-254` 列。
- **修**:三態:(i) 無重註冊 → 同 RPA;(ii) 重註冊且距上次 RPA 改變 < 900 s → 同 RPA;(iii) 重註冊且 ≥ 900 s → 新 RPA。以 provd log 的 `adv re-registered` 時間戳 + btmon 的 RPA 時間軸對齊;N1 負對照(停 provd + `adv-on` ≥ 30 分)不變。

### M5. F16 的 `dbus-send` 是 libtool wrapper(bash 腳本),不是可推上節點的二進位
- **情境**:F16 / §2.2 `dv-dbus-tools.sh`:「複製 `build_dir/…/dbus-1.14.10/tools/dbus-send`」。該檔 10004 B,開頭 `#! /bin/bash` + 「temporary wrapper script for .libs/dbus-send」;真二進位在 `tools/.libs/dbus-send`(77424 B)。節點沒有 bash → `provclient exec dbus-send` 直接 ENOENT / exec format error → `prov-sec-dbus-254` 全 FAIL,歸因錯誤。.libs 二進位的 `DT_RUNPATH`(libtool 未 install 前指向 build 樹)與 `libdbus-1.so.3` 的 SONAME / 版本對節點的 `libdbus` 是否相容,設計只標 ⚠️ E-H1「確認 .so 版本」。
- **證據**:`firmware-2710/build_dir/target-aarch64_cortex-a72_musl/dbus-1.14.10/tools/dbus-send`(wrapper)、`tools/.libs/dbus-send`(ELF,77424 B),2026-10-28 `ls -la` + `head`。
- **修**:F16 改為 `.libs/dbus-send`;`dv-dbus-tools.sh` 複製前以 `file` / ELF magic 斷言;E-H1 在 04 跑 `readelf -d`(或 `ldd` 等價:musl 無 ldd,用 `LD_TRACE_LOADED_OBJECTS=1`)確認只需 `libdbus-1.so.3` + musl,且 `dbus-send --system --print-reply --dest=org.bluez / org.freedesktop.DBus.Introspectable.Introspect` 以 uid 471 能跑(dbus 政策 + socket 權限)。

### M6. p1-impl §4.3 provclient 放置負測試仍被靜默丟掉
- **情境**:p1-impl §4.3「`/tmp/run/batman-dvpc.<run_id>/`:root 0711 … 負測試:預先放一個 provd 可寫的檔或 symlink → 拒絕執行」。`pl_prep`(`prov-lib-254.sh:88-92`)只做 `mkdir -m 0711` + sha 比對,沒有拒絕邏輯;v1 A 的範圍對照已點名,v2 的 §1.2「不在本 PR」、§6.2、§9 都沒有它。
- **證據**:`prov-lib-254.sh:20,88-92`;p1-impl §4.3;v1 A「範圍對照」。
- **修**:進 `prov-sec-254` tier A(或 `pl_prep`):`mkdir` 前 `lstat` 既有路徑,存在且(非 root 擁有 / symlink / group-or-other 可寫)→ `FAIL dvpc dir pre-exists: <why>` 不放工具;白箱負對照:lease 內以 `nobody` 預建同名(`/tmp/run` 是 root 0755,非 root 建不了 → 改以 root 預建 symlink 模擬)→ 拒絕。或在 §1.2 列為不做並給理由。

### M7. `prov-sec-psk-timing-254` 沒把 §8 限速與「假訊息等逾時才斷」算進去 → 統計被限速汙染
- **情境**:§6.3:sock 上 n=50 錯 PSK vs n=50 對 PSK。§4.8.2 明定 sock 連線 = BLE 連線,§8 全部計數器適用:**全域交握 20 / 分**;219 §3.4:全部失敗時「送出後**和真 session 一樣等到逾時才斷線**」(10 s)。50 次對 PSK 不節流 → 第 21 次起被限速(拒絕或延後)→ 延遲分佈出現尖峰 / 錯誤;50 次錯 PSK 每次佔連線 10 s,同時連線 ≤ 2 → 錯臂至少 250 s。`NO_BRUTE_LIMIT` 只關每連線 3 次,不關 20 / 分。另外 v1 B-M6 要的是「先量抖動分佈**定 n**」,v2 把 n 釘死 50,只量抖動定門檻。
- **證據**:219 §3.4、§8;§4.8.2;§6.3 該列;`node.go:302`(另一個全域限速 2 / s 簽章,不影響此測但同類)。
- **修**:節流 ≤ 18 / 分(兩臂交錯送,消除時段漂移);錯臂用兩條 sock 並行、每條連線在收到假 msg2 後立即由 `peer.py` 主動斷(量的是 msg1→msg2 延遲,不需等節點斷);n 由第一次抖動量測決定(給公式:n ≥ (2·1.96·MAD/效應量)²,上限寫明);PASS 條件保留 v2 的 CI 等價檢定;時間預算寫進 §7.3。

---

## MINOR

### m1. F3 計數仍錯
- 13 個名字以外還有 `harness-negctl-254`(`daily-validation.sh:208`,在 F3 引用的行號範圍外)→ 14。要嘛列入,要嘛寫明「不含 harness 自測」。

### m2. F12「只有同槽同版本 COMMITTED 才刪 bad-slot」不對
- `batman-autocommit:537` 的 `rm -f "$ST/bad-slot"` 在**任何** COMMITTED 都執行;`:361` 的同槽同版本檢查是「拒絕 commit」,不是「刪除條件」。§3 bad-slot 列的「產品 COMMITTED」沒錯,F12 的描述要改。

### m3. txn-2 的對帳觀察點:daemon 模式延後 120 s;既有 log 行已經存在
- `main.go:439-441` daemon 啟動 `go restoreWireless(p, res.Restore, 120*time.Second)`;`:493` 已有 `txn %s not committed: restored the previous wireless values, setkey rc=%d (%s)`(`%s` 是 Verb 不是 token)。§6.2 txn-2 的斷言要等 ≥ 120 s + setkey;§10 第 5 點「P1b 補一行 `txn <tok>: reverted wireless to .txn values`」多餘 → 改引用既有字串(或改既有字串帶 token,一起寫進 §10)。

### m4. `build-board.sh --wbox` trap 的 `git clean -fd tests/ files/` 範圍錯
- 路徑相對 `feeds/batman` 根;mutant 新增的檔在 `feed/batman-provision/files/…`(`radio1-off`、`chan`、`misc-*` 都是新檔)→ 留下 untracked → 下一次正常 build `stamp-batman-build.sh:44` `feeds/batman status --porcelain` 非空 → `DIRTY=1`、VER 帶 `.dirty`(不 install 所以 gate 過,但樹不乾淨、版號錯)。改 `git -C feeds/batman clean -fdx`(整個 feed 工作樹;OpenWrt 不在 feeds/ 裡產生 build 產物)。

### m5. Go 原始碼 mutant 的見證字串若是註解,不會進二進位
- §2.1「patch 必須把見證字串寫進它改的那個檔(註解或字串)」+ §4.1.3「`<rootfs>` 裡 `grep -rl` ≥ 1」。`helper-*` 七個 mutant 都是 Go;註解不進二進位 → gate 的正向(有 wbox-name 時見證 ≥ 1)必 FAIL。規則改為:`.go` hunk 的見證必須在一個被引用的字串字面值裡(例如那條 mutant 的 log 行);`lint-wbox` 對 `.go` hunk 檢查見證出現在 `"…"` 內。

### m6. `claim/replay` 10 / h 計的是**失敗**
- `node.go:549` `claim.replay failures (10/h)`,成功不計。§6.3 `prov-ble-claim-254`「`claim/replay` 10 / h(第 11 次 `E_RATE` 12)」要改成「10 次失敗(錯 response)後第 11 次 → `E_RATE`;成功的 replay 不計」。

### m7. `NEEDS-PERSON` / `FAIL blocked` 不在 `NEVER_KNOWN`
- `daily-validation.sh:2740` `NEVER_KNOWN='restore|cleanup|CONNECTION-LOST|…'`。§4.3「known-failures 拒收此 pattern → 永遠 NEW」要落地:把 `NEEDS-PERSON|blocked: DNODE` 加進 `NEVER_KNOWN`,並讓這兩種行都以 `FAIL ` 開頭(`classify` 只抓 `^FAIL `,`:2745`)。`test-known-failures.sh` 各一個案例。

### m8. `DNODE_BLOCKED` 擋的「目標含 DNODE 的 suite」沒有機制
- `suite()`(`daily-validation.sh:77`)只收 name / why / cmd / kind,不知道目標節點;`fi-*` 的目標是 `$OTS_NODE`、`reflash-202` 是 `$MESH_NODE`,它們與 `$DNODE0` 可能相同也可能不同(`:127`)。定義為「cmd 展開後含 `$DNODE0` 的 IP 字串」或加第 5 個參數 `target=`,並寫負對照(目標不是 DNODE 的 D 類照跑)。

### m9. prov 區塊的位置相對 2f 沒寫
- 2e(BLE tier B)與 2g 之間還有 2f(#305 tier B,`bt-uart-boot-305` 對 DNODE 做 loaded reboots,`:272-274`)。寫明「2f 之後、2g 之前」;並確認 2f 結束時 04 committed = A(2f 不動槽 ✅)。

### m10. §5 缺列:harness 死於 `pr_normalise`(A 的 held trial 中)
- 600 s 到期 → revert → `bad-slot` = `slot=A version=V`(`:238-244`)→ 04 回 B committed;**沒有 snapshot、沒有 dirty 標記**(正規化不 snap)。下次 P9「`bad-slot` 存在 → FAIL」但印不出「這是正規化殘骸、清法 = 確認 A 的 `.protected` = V 後 rm」。補一列 + P9 的訊息。

### m11. prov deadman 的紀錄檔與 BLE deadman 可能是雙寫者
- BLE deadman 以 `$ST/dm` / `dm.new`(`ble-lib-254.sh:97-134`)保證每台至多一個;§3 prov deadman「每台至多一個」沒說紀錄放哪。若也寫 `$ST/dm` → 兩個 `dm_arm` 實作對同一檔;若另立檔 → 「至多一個」只在各自家族成立。指定:prov deadman 重用 `ble-lib-254.sh` 的 `dm_arm`(同一把 `$BT/lock`、同一個 `$ST/dm`),只有 `dm-fire` 的腳本不同。

### m12. `prov-sec-dbus-254` tier A 的 root 對照不是唯讀
- 以 root 呼叫 `AgentManager1.RegisterAgent` 會讓 current settings 出現 `bondable`(stage1 §3、§9),helper health `bondable=1` → P2 provd ≤ 10 s 撤廣播。tier A 標「唯讀」。root 正向對照改用無副作用的方法(`Properties.Get`、`Introspect`),或把 RegisterAgent / `Pairable` 的 root 正向移到 tier B 並緊接 `UnregisterAgent` / 設回。

### m13. Windows BLE 的 P9 只查 `bleak` 匯入,不查 radio
- F17:主機 radio 今天是 Off。無人值守的 H3 run 會在每個 BLE 單位裡以 bleak 錯誤失敗,而不是在 P9 一行 FAIL。P9 加「WinRT `Radio.get_radios_async` → Bluetooth state == On」(F17 已有讀法)。另 §4.9 只引 iOS 合併 scan response;bleak 的 WinRT 後端是否把 ScanResponse 的 service data 合進同一個 `AdvertisementData` 要在 E-H1 一併驗(影響 `transport_ble.py` 的 scan 過濾)。

### m14. `provgen.py --selftest` 的固定私鑰來源沒寫
- `vectors.json` 沒有私鑰 scalar,只有 `keys.p256_private_scalars_note`:`d = (int(SHA-256('batman-test-vector/'+name)) mod (n-1)) + 1`。§4.6 要寫「依此規則重算 owner-sign / admin 的 d,轉成 PEM,再逐位元組比」。

### m15. tmp-trust 的掃描範圍與 §2.2 的條目對不上
- `check-tmp-trust.sh:29-30` 只掃 `feed/**`、`deploy/**`、`scripts/node/**`、`scripts/*.sh`;`scripts/dv/*.sh` 不掃(所以 `prov-lib-254.sh:20` 的 `/tmp/run/batman-dvpc.$RUN` 今天沒有條目也過)。§2.2 要寫清:新條目只對 `scripts/node/prov-wbox-254.sh`(`/tmp/run/batman-dv/wbox/`、`/tmp/run/batman-prov-test/`)與 `feed/batman-prov/src/*`(killpoint 目錄、provd 測試 socket 目錄);p1-impl §2.2 的 `/tmp/run/batman-dvpc.*` 條目不需要(不在掃描範圍),明寫不是漏掉。

### m16. `push-helper` + `arm-killpoint` = 兩次 helper restart = 兩次 `boot.Run`
- 每次 restart 都重寫 `prov-state` verdict 行並可能觸發 `restoreWireless`(若 `.txn` 殘留)。順序改為:寫 killpoint 檔 → `push-helper`(一次 restart 同時讀 killpoint)→ 斷言 `armed` 行。

### m17. `pr_brewrite` 對 02 的參數化
- `brewrite-254.sh:4` `NODE=${NODE:-10.41.1.3}`、`PAY` 預設、`:36` 等 docker ≥ 6 個(02 沒有 OTS → 白等 180 s)。(7) 要 02 的 B 寫回 V,`pr_brewrite <node>` 要把 docker 等待改成依節點角色,並寫進 §4.3。

### m18. known-failures 第 4 欄的 parser 負對照要列
- `daily-validation.sh:2748` `read -r ks pat iss`:第 4 欄會併進 `iss` → `gh issue view "254<TAB>expires=…"`。設計已說 daily-validation 處理;`test-known-failures.sh` 要有三個案例:舊 3 欄 → run FAIL(格式錯)、`expires=` 格式壞 → FAIL、過期 → NEW。

### m19. autocommit (1) 的 `reason=` 字串沒對原始碼
- §6.2「`TRIAL-REVERTED … reason=` 含 mesh」:`reason=${why:-unhealthy}`(`:239`),`why` 來自 `health_ok()` 與 `:494` 的 `member: HaLow mesh interface not up …`;legacy 04 走今天的 NEED_MESH 規則,實際字串未核對。實作前 grep `health_ok` 的每個 `why` 字串,寫進 §6.2(同 F12 做法)。

---

## v1 發現 → v2 處置核對

| v1 | 解了? | 說明 |
|---|---|---|
| A-B1 / B-B1 順序 | 是 | §4.3 prov 區塊移前 + `pr_normalise` + 白箱;m9(2f 位置)、m10(正規化中死掉)是殘餘 |
| A-B2 `prov_test` helper 到 A、`test` 變體、重建雜湊 | 是 | §4.5 `push-helper`(sha + `/proc/pid/exe`);§4.2 `test` 無 patch 例外、stamp 強制 DIRTY、wbox stamp → clean;E-H2 |
| B-B2 四個 helper mutant | 是 | §4.2 補五個;`lint-wbox` 查引用;m5(Go 見證要字串)是殘餘 |
| B-B3 / A-M6 socket 目錄 / ujail / env / CI 模型 | 部分 | 分目錄 ✅、`provd.env` 契約 ✅、`SOCK_ONLY` ✅、CI useradd ✅;**M1**:新目錄權限讓 provd 仍建不了 socket |
| A-M1 bad-slot | 是 | §3 列、§4.3 預期 REVERT 收尾、§5 兩列;m2 F12 描述、m10 正規化殘骸 |
| A-M2 / B-M1 版本與見證 | 是 | `batman-build.txt` + unsquashfs + 見證;gate 在第 7 步(`build-board.sh:146-172` ✅ 位置正確) |
| A-M3 sysrq;txn-1 / txn-5 | 是 | §4.1.1 `echo b`、fallback 標 ⚠️;五個單位;F29 ✅(`.config:6904-6905`) |
| A-M4 / B-M2 powerloss / netupdate 負對照 | 是 | `disable` 法 ✅(`.txn` 由 `WriteTxn` fsync+rename,`provstore/txn.go:21-40`,重開後存在 ✅);netupdate 改斷言 p5 overrides ✅;m3(120 s 延遲)殘餘 |
| A-M5 legacy-upgrade 負對照 | 是 | held A trial + rollback;wsl.9 有 HOLD-COMMIT(F32) |
| A-M7 / B-m2 NEEDS-PERSON | 部分 | `DNODE_BLOCKED` 有了;m7(NEVER_KNOWN)、m8(目標判定機制)未落地 |
| A-M8 autocommit (7) | 是 | 02 先 commit、04 後 revert;m17 brewrite 參數化 |
| A-m1 gate 位置 / shell helper | 是 | 第 7 步 `$WR/r`;`go version -m` 無輸出改見證 |
| A-m2 chain1 > 3000 s | 是 | 列為例外;02 boot_id 每單位 |
| A-m3 whiteout / opaque | 是 | `/etc/banner` 負對照;opaque 列 §9 |
| A-m4 lease 同一把 flock | 是 | §3 |
| A-m5 / B-m1 計數 | 部分 | F26 7 行 ✅;F3 仍少 `harness-negctl-254`(m1) |
| A-m6 `.protected` 缺 | 是 | §4.7;F31 ✅(`batman-slot:428-433`) |
| A-m7 目錄刪除者 | 是 | §3 |
| A-m8 傳輸三件事 | 是 | §4.8.2:控制包只在交握前、`max_frame` 244、sock = BLE 連線 |
| A-m9 / B-m9 沙箱 | 是 | 步驟順序(loop 先、`/proc` bind)、gate 獨立、排隊不計 |
| A-m10 (8)(9) 判定 | 部分 | 兩臂寫了,但 **M2**:P1 上兩臂都不鑑別 health 分支 |
| A-m11 authorized_keys 同批次 | 是 | §6.2 |
| A-m12 verify.py 可 import / selftest 注入 | 是 | `def main()`、`load_vectors()`;`gen.py:225-227` 已注入臨時金鑰 ✅ |
| B-M3 lease / ch1 deadman / 主機鎖 | 是 | chain1 / brewrite / pty-commit 取 lease;P9 查 rc.local / timer / p6 腳本(F24 ✅ `chain1-254.sh:259`);主機鎖刪;m11 deadman 紀錄檔 |
| B-M4 六項 | 是 | 到期欄、sec-helper-uid、key-perms、eeprom-hooks、provd A-N2 / B-m2、雙台 netjoin、ble-ok 負對照、settings.set 都回來了;m15 tmp-trust 範圍說明 |
| B-M5 peer.py 裁判 | 是 | `noiseprotocol`;selftest 對 gen.py transcript 逐位元組 |
| B-M6 timing 統計 | 部分 | 效應量 + CI 等價 ✅;**M7**:限速、等逾時、n 釘死 |
| B-M7 brute 負對照 | 是 | `NO_BRUTE_LIMIT`;節點側 3 次是 provd 記憶體,helper 無此計數(✅ 與原始碼一致) |
| B-M8 dbus 工具 | 部分 | `exec` 動詞 ✅、Disconnect / 回呼移 tier B ✅;**M5** wrapper;m12 root 對照副作用 |
| B-M9 bond 翻轉 provd 停止模式 | 是 | §4.10、§6.3 |
| B-M10 rpa provd 模式 | 部分 | 改用 log 契約 ✅;**M4** 判定方向錯 |
| B-M11 sock vs §8 / `E_STATE` | 是 | §4.8.2;`E_BUSY`(7)回 219 §10;`EState` 22 只在 helper(`node.go:43,172`)✅ |
| B-M12 判定字串 | 是 | `E_SCHEMA` 20(`node.go:41,138,224`)、`prov: state=… copied=`(`96:168`)、`.batman-prov-restore` 第 3 欄(`96:113`)、`WARN ble: …`(`:499`)全部對上;`sock: unexpected`(`sock.go:76`)✅;`no-ssh-key` → `EUnsupported`(`node.go:502`)✅;`rename-pending`(`:733`)、未知 key `ESchema`(`:735`)✅;`--save: p5 busy, retrying once`(`:402`)✅;`boot rc= / overlay record unusable / p5 lost a committed`(`boot.go:59,72,187`)✅;m19 一條未核 |
| B-M13 `prov_test` 無 wbox | 是 | P9 + tier A 標記 |
| B-M14 release-scan | 是 | 刪句 + 理由(`release-scan.yml` 只在 tag push 掃原始碼 ✅) |
| B-M15 / B-M16 restore 中 deadman / 記憶體 arm | 是 | `restoring` 標記、lease 延長、`wbox.list armed`、P9 log |
| B-M17 `adv-on` 先檢查 | 是 | §2.2;F22 ✅(`ble-periph-254.sh:45` 第一個動作仍是 `rm-adv`,待改) |
| B-m1 | 部分 | 見 A-m5 |
| B-m2 | 部分 | 見 A-M7 |
| B-m3 killpoint Go 單元 | 是 | §4.1.1 |
| B-m4 pre-P1b | 是 | `--version` rc(`main.go:404-406` usage exit 2 ✅) |
| B-m5 provd-dos / respawn | 是 | §6.3 改寫;init `respawn 3600 5 0` ✅ |
| B-m6 coex | 是 | 主機 Wi-Fi 客戶端、第一輪記錄 |
| B-m7 UUID 預算 | 是 | 3+18=21、scan response 13 B、nonce 8+1 算對;m13 bleak 合併待驗 |
| B-m8 tmp-trust 第 99 行 | 是 | 收緊 + 新條目;m15 |
| B-m10 ldflags 整串 | 是 | F34 對 `golang-package.mk:236-262` ✅(含 `-ldflags "all=…"` 與自訂 `-ldflags` 兩段) |
| B-m11 keygen 格式 | 是 | PEM `EC PRIVATE KEY`(`provclient/main.go:304`)✅;m14 私鑰 scalar 規則 |
| B-m12 Windows 依賴 | 是 | F17 已裝;`noiseprotocol` E-H1(`requirements.txt` 有 0.3.1 pin,純 Python,應可裝) |
| B-m13 矩陣 / 擁有權缺列 | 是 | §3、§5 補;m10、m11 新缺口 |
| B-m14 其他 | 是 | stale 60 s(`health.go:9`)、gatt Flags 從 02、firstboot 手動、OTS actor(F35 grep 零命中 ✅) |

## 假設驗證表

| 設計主張 | 結果 | 證據 |
|---|---|---|
| F3 13 個 | ⚠️ 14 | `daily-validation.sh:208,214,227-296` |
| F4 restore 只逐檔、無 firstboot | ✅ | `prov-base-254.sh:190-220`;`chain1-254.sh:122-176` |
| F6 metadata `version=` 是時間戳 | ✅ | `feeds/batman/scripts/build-ab-payload.sh:69`(路徑在 feeds/batman,不在 firmware `scripts/`) |
| F7 stamp / DIRTY / `GO_PKG_TAGS` / `-i` | ✅ | `stamp-batman-build.sh:38-54`;`golang-package.mk:106-111,262`;`build-board.sh:86-96` |
| F8 CLI、無 `--version`、非 root exit 2、daemon 跑 `boot.Run` | ✅ | `main.go:373-407,439` |
| F9 錯誤碼 | ✅ | `node.go:33-46` |
| F10 provclient 動詞 / PEM / 471 / unixpacket | ✅ | `provclient/main.go:304,417-423,470,490-558` |
| F11 `PrepareDir` 拒絕外物、0750、0660 | ✅ | `sock.go:37-78,83-99` |
| F12 autocommit 字串 | ✅(m2 一處描述錯) | `batman-autocommit:192-195,238-244,277-288,361,425,499,505,513,537` |
| F13 96 / helper 字串 | ✅ | `96-batman-config-migrate:79,113,168,193`;`boot.go:59,72,187` |
| F14 stale 60 s、`ble-ok` 600 s | ✅ | `health.go:9,145-155` |
| F15 chanfix 兩行 | ✅(但 M3) | `99-batman-chanfix:47,53` |
| F16 dbus-send | ❌ wrapper | `tools/dbus-send` 是 bash;`tools/.libs/dbus-send` 才是 ELF |
| F19 verify.py 模組層讀向量、MIN_CHECKS 195 | ✅ | `verify.py:16-42,176-186`;`ci-check.sh:12`;`ci.yml:45` |
| F20 go.mod 只 x/crypto | ✅(x/sys indirect) | `go.mod` |
| F22 `adv-on` 先 `rm-adv` | ✅ | `ble-periph-254.sh:45` |
| F24 chain1 deadman / 主機鎖 / 事故註解 | ✅ | `chain1-254.sh:27,135-137,205-221,259` |
| F25 2g 順序、pty-commit 移槽、FI 目標、suite rc | ✅ | `daily-validation.sh:77-99,278-296,335`;`pty-commit-254.sh:14` |
| F26 7 行、無到期欄 | ✅ | `validation-known-failures.txt:10,19-24` |
| F29 sysrq 0x1f6 | ✅ | `linux-*/.config:6904-6905` |
| F30 allowlist :99 無邊界 | ✅ | `tmp-trust-allowlist.txt:99` |
| F31 apply 刪 `.protected`;95 寫完整版本 | ✅ | `batman-slot:428-433`;`95-batman-storage:717` |
| F33 joinwatch 3600 s | ✅ | `init.d/joinwatch:14`;`usr/bin/joinwatch:37` |
| F34 旗標整串 | ✅ | `golang-package.mk:236-262` |
| F35 deploy/ots 無三個 bind | ✅ | grep 零命中 |
| F36 gate 位置 / `$WR/r` | ✅ | `build-board.sh:146-172` |
| §4.1.2 `.txn` 用 tmp + rename + fsync(disable 法成立) | ✅ | `provstore/txn.go:21-40` |
| §4.5 PEERCRED 負對照只在 Go 單元 | ✅ 已有 | `sock_test.go:67 TestWrongPeerClosed` |
| §4.6 owner-op 首版 join 必驗 | ✅ | `node.go:690-700` |
| §4.8.2 frame / §8 計數器 | ✅ | 219 §4.1、§8(`claim/replay` 10 / h = 失敗,m6) |
| §4.9 預算 | ✅ 算對 | — |
| §6.3 two-phones `E_BUSY` | ⚠️ 設計決定,provd 需實作 claim 互斥 | 219 §5.2 有 7;helper 的 `EBusy` 只給 trial(`node.go:169`) |
| §3 provd socket 目錄 | ❌ | M1 |
| F1、F2、F17、F18、F21、F27、F28、F32(wsl.9 內容)、04 是否有 `unsquashfs`、`noiseprotocol` Windows wheel、bleak WinRT 合併 scan response、04 upper opaque | ⚠️ 未上機 / 未上網,未驗 | — |

## 範圍對照(p1-impl §5 / stage1 §8–§9)
- 涵蓋:§5.1 全部(含 gate 獨立)、§5.2、§5.3 全部(`prov-base` 的「同槽 A 重建」改以鏈 1 程序 + 負對照,理由在 §1.4,可接受)、§5.4 鏈 0、§5.5 (1)(3)–(10)、§5.6 含 `settings.set`、§5.7 的 H2 列;stage1 §8 的 `prov-sec-*`、`-helper-uid`、`-key-perms`、`-eeprom-hooks`、provd A-N2 / B-m2、§9 的 tier 列(tier A → B 的改分級有理由)。
- 靜默丟掉:p1-impl §4.3 放置負測試(M6)。
- 多出但有說明:`prov-sec-psk-timing`(M7 修後可留)、`ble-rpa` provd 模式(M4 修後可留)。
- 不在本 PR 且理由可接受:P3 / bcm2710 真機 / L16 / iPad 自動化 / `prov-rename` / 真斷電 / release asset 掃描 / `docs/validation` 文字。

## 結論

**APPROVE-WITH-CHANGES**(BLOCKER 0 / MAJOR 7 / MINOR 19)。M1–M4 會讓乙部傳輸不通或把正確的產品判 FAIL,M5 讓 `prov-sec-dbus` 整個做不出來,M6 是範圍靜默縮小,M7 讓一個新測項的統計失效;都有明確修法,不動架構。v3 請整份再審(特別是 §3 socket 目錄列、§6.2 (4)(8)(9)、§6.3 `ble-rpa` / `psk-timing`、F16)。
