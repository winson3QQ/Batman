# #329 PR 3 實作計畫 v5：對抗式審查（審查者 J，獨立）

審查對象：`docs/design/329-pr3-plan.md` v5（commit 2a58cc2，branch `feat/329-pr3`），整份重審。上層：`docs/design/329-app-uiux.md` v12.1。對照 v1–v4 八份審查（A–H）。原始碼：同一個工作樹。除本檔外沒有改任何檔案；沒有跑測試、建置或真機。

## 結論

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER、1 MAJOR、9 MINOR）。

- v4 的六個 MAJOR（G-M1..M3、H-M1..M3）在 v5 都有實質處理，判定欄位已對上 Rust（見「之前的 BLOCKER / MAJOR」）。
- 但 v5 的 D4（只有 pending 時允許建立新網路）**自己帶進一個新狀態**：舊的建立者其實已經套用（或正在套用）舊網路 A，手機卻建好了網路 B。計畫只說「最壞是它自己留在舊網路裡」，沒有讓使用者**看得到**、也沒有給**修得回來**的路；而且這個「最壞」的前提（「讀到在網路裡 → 不能當建立者」）在節點還在套用中時不成立。這是 M1。
- 修法不需要新機制：`NodeLink` 已有每台最後一次讀到的 `StatusView.netId` 與 `unfinished`，拿來比對手機上的 pending 紀錄就夠。修完要再整份審一次。

---

## MAJOR

### M1　D4 會把舊的建立者留在舊網路裡，使用者看不到、也沒有出口；正在套用的節點還可能被選成新網路的建立者

**情境 A（拔電後節點其實套用了）**
1. 04 建立網路 A，途中拔電。手機上 A 是 pending。04 重開後其實套用了 A（commit 點在節點上，p5）。
2. 使用者沒按「檢查網路」，或按了但 04 還沒開好、讀不到（`Unknown`），或還在套用中（`InProgress`），就照 §2.8 / 4.1 的次要按鈕「建立新的網路」。
3. 4.1 建立表單：04 讀不到 → 可勾但不能當建立者 → 選 02 當建立者，網路 B 建好、applied。
4. 之後：
   - §2.7：手機已有 applied 的 B → 「建立網路沒有確認完」**不再列待辦**。
   - §2.5 第 6 列：有 applied → 「加入網路」→ 4.1 加入表單。04 讀到在網路裡、`netId = A ≠ B` → **不能勾**（§2.3）。
   - 第 6 列本身只看 `nodeState == 1`（home_logic.dart:31、:88-89），04 是「在網路裡」，**不會出現在第 6 列**。
   - 節點頁：主句來自狀態頁，`netId` 只在技術資訊裡以 16 進位顯示（node_page.dart:128）；新頁面沒有用 `status_membership_line` / `networkName` 對名稱（舊控制台才有，nodes.dart:1166-1182）。
   - 結果：04 在 A、02 在 B，**隊伍分裂**（§6 的資產），首頁沒有任何一列告訴使用者，也沒有任何按鈕能對 04 做「檢查網路 A」（唯一能升級 A 的動作，netrec.rs:511-536）。
   - 若使用者在 B 的加入流程硬勾 04（例如它當時讀不到），加入 B 會得到 `Fail::OtherNetwork`（join2flow.rs:756）→ `absent` →「再試這一台」，永遠再失敗；Rust 句子「這台已在別的網路」不說那是手機自己的 A。

**情境 B（還在套用中的節點被選成建立者）**
- §2.3 的理由寫「pending 的建立者其實已經套用（還在設定中）：它不能當這次的建立者（讀到在網路裡 → 不能當建立者）」。
- 但「還在設定中」時 info key 10 不在、key 11 = true（flow.rs:146-147、:166-170 → `InProgress`），狀態頁 key 1 多半仍是「還沒加入」：`notInNetwork` 為真，04 **可以當建立者**，而且 §2.3「預設是清單上第一台」很可能就是它（最早認領）。
- `request_make_network` 不檢查節點目前的網路或未完成的變更（owner.rs:1067-1088 只看 `flow_busy`、`node`、`St::Conn`）。節點在套用 A 的途中收到建立 B 的要求會怎樣，本 repo 查不到（firmware）⚠️。
- §2.8 的次要按鈕「建立新的網路」不分 `InProgress` / `Unknown` / `NotApplied` 都出現（計畫 §2.8；檢查結果只有文字，P20）。G-m4 / v3 E-B1 指的就是這個時機。

**為什麼是 MAJOR**
- 這是 v5 新加的出口（D4）直接造成的狀態，就落在 §8 情境 2（建立途中拔電）——拔電後節點最常見的回報正是「還在設定中」或讀不到。
- 使用者的規則：「範圍從現場推」；「不誇大」——首頁會在隊伍已分裂時顯示正常。
- 計畫 §2.3 承認「它自己留在舊網路裡，要等離開（PR 4）」，但沒有讓使用者知道它在哪、為什麼；PR 4 的「離開」也要使用者先知道要對 04 做。

**證據**
- ✅ home_logic.dart:31 `bool get notInNetwork => view != null && view!.nodeState.toInt() == 1;`；:88-89 第 6 列只取 `notIn`。
- ✅ node_page.dart:128 `if (v.netId.isNotEmpty) '網路 ${v.netId}'`（技術資訊，收合）。
- ✅ owner.dart（Dart 綁定）:559-560 `StatusView.netId`「lowercase hex … the app maps it to a local record's name」；owner.rs:125 `NetView.net_id = hex_lower(...)`：兩邊格式相同，可直接比對。
- ✅ `StatusView.unfinished`（info key 11）已在 Dart 綁定（lib/src/rust/api/owner.dart:575-576）。
- ✅ flow.rs:166-170：key 10 不在、key 11 = true → `InProgress`。
- ✅ netrec.rs:511-536 `confirm`：key 10 == 紀錄的 net_id 且 key 9 == 版本才升級，**不看登入的是哪一台**——所以對「讀到 netId = A」的那台檢查 A，正好就是正確的升級。

**修法**（不加新機制，只用 `NodeLink` 現有的讀取結果）
1. **建立閘門與 4.1 多一個條件**：若有任何一台最後一次讀到的 `netId` 等於手機上某筆 pending 紀錄的 `net_id`，**不給「建立新的網路」**；改成主要按鈕「<那台> 已經在網路「<A 名稱>」裡，按『檢查網路』完成建立」，§2.8 的對象 = 那一台、那一筆 `rel`。升級後 A 就是隊伍網路，其他節點加入 A。
2. **建立模式的資格**：最後一次讀到 `netId` 非空、或 `unfinished` 非空（節點上有沒完成的變更）的節點，**不能當建立者、也不能勾**（顯示「這台還在套用上一次的設定，等一下再試」）。這同時處理情境 B。
3. **§2.8 的次要「建立新的網路」**：只在對象那台**這次讀得到、`netId` 空、`unfinished` 空**時出現（用 `NodeLink` 在 §2.8 拿佔用之前的最後讀取；或在佔用下登入後讀一次狀態頁）。讀不到 → 只給「再檢查一次」並寫「節點可能還在開機或設定中，等一兩分鐘」。
4. **看得到**：首頁 / 節點頁對「`netId` 是手機上 pending 紀錄」與「`netId` 不是手機上任何 applied 紀錄」的節點不顯示一切正常——至少用現有的 `status_membership_line(nodeState, netId, networkName(...))`（owner.rs:422、member_ui.dart:313）把網路名稱顯示出來，並把前者做成待辦（=修法 1 的按鈕）。後者（例如已在 A 卻有 applied B）寫「這台在另一個網路，要先離開（PR 4）」；寫進 §11 殘項與 §9 限制。
5. **§2.8 對象的對應**：先用 `netId == rel 的 net_id` 精確對（修法 1），對不到才用 `node-<last4>` 名稱、再不行讓使用者選。比現在只用名稱可靠。
6. **測試 + 改壞**：
   - 04 讀到 `netId = A`（A pending）→ 4.1 沒有「建立新的網路」、主要是檢查 04；改壞：拿掉條件 → FAIL。
   - 04 `unfinished` 非空 → 不能當建立者；改壞 → FAIL。
   - applied B + 04 讀到 `netId = A` → 首頁不是第 14 列「一切正常」；改壞 → FAIL。
   - §8 情境 2 補一個分支：拔電後等 04 開好、讀到已在 A，確認首頁導向「檢查網路」而不是「建立新的網路」。
7. §2.3 的理由段、§6「隊伍不分裂」改寫成上面的實際保護，不要寫「讀到在網路裡 → 不能當建立者」就當成已處理。

---

## MINOR

1. **（G-m1 未處理）重讀的時機。** `ask` 逾時時，`FrameInbox` 的處理者可能還在 `persistNet`（Keystore seal + CAS）。這時重讀拿到寫入前的紀錄（加入 → `absent`；建立 → 檔案還不存在 → `unreadable`「讀不到手機裡的網路紀錄」，字面錯），之後寫入才落地。修法：重讀前先等收件匣的處理佇列閒下來（或先 `close` 再讀）；測試：persist 卡住 → 逾時 → 先等再判定。另：「`rel` 讀回不存在」（H-M1 修法 2）應判成「沒有建立」，不是 `unreadable` 的句子。
2. **（G-m2 未處理，且有現場觸發）`NotSent` 還原舊的 Applied 項目 → 判成「完成」。** join2flow.rs:509-512 `Fail::NotSent` 把 `before` 還原。節點被重燒 / 維修後回到「還沒加入」，手機紀錄裡它的項目仍是 Applied；再加入時 op/nonce 被拒（NotSent）或 `begin` 拒絕（Full / NotAdmin，紀錄沒寫），重讀得 `!joining && !approved` → 第 8 列「完成」→ 連線檢查失敗 →「已加入，連線狀態未知」，仍算完成。修法：記下請求前的 generation，第 8 列要求這次請求有寫入（generation 前進）且不是 `notSent`；否則落到第 10 列。
3. **（G-m3 未處理）`HandoffProber` 在 msg2 之後沒有上限。** `SessionProber` 有 `answerMax` 20 s（prober.dart:37、:145）；計畫只寫 8 s 等 msg2。送了 msg2 就停住的裝置能吃掉剩下的 60 s。照抄 `answerMax` 並加改壞。
4. **形狀釘子不完整、Dart 假資料仍是手抄。** §2.2.1 的 Rust 測試只列五種形狀，沒有第 10 列 `absent`（確定失敗後項目被刪）、`NotSent` 還原 `before`、`Revert::NotReverted`（項目留著仍 joining，join2flow.rs:102-104）。第 9 / 10 列的 Dart 測試因此只能手寫，和「不手寫其他組合」矛盾。另外「檔頭註明出自那個 Rust 測試」不防漂移：建議 Rust 測試把 `net_summary` 結果寫成 golden JSON 進 repo，Dart 判定測試讀同一個檔，Rust 輸出一改就有一邊 FAIL。第 9 列也要顯示 Rust 句子（`NotReverted` 的國家提示不能丟，H-M1）。
5. **改壞「先 `exists()` 再 `list()`」分辨不出來。** `exists()` 為假 → 空；為真但之後被刪 → `list()` 丟 `PathNotFoundException` → 也當空。兩種寫法行為相同，這個改壞不會 FAIL（全域規則：presence check 不算測試）。改成可觀察的故障（例如注入「目錄存在但不可讀」→ 必須是「列不出來」），或拿掉這一條。
6. **§2.7「最新的一筆（檔案修改時間）」不在 `NetIndex` 的契約裡。** §2.4 寫「有沒有紀錄只看列檔」，沒有 `stat`；`stat` 失敗、時間相同時取哪一筆沒寫。且只列最新一筆會把較舊、其實已套用的 pending（M1 情境）藏起來——M1 修法 1 用 `netId` 比對後，這條只剩決定順序的細節。
7. **（G-m5 部分未處理）Rust 的 `NotApplied` 句子說「可以再建立一次同一個網路」**（owner.rs:478），新頁面的按鈕卻是「建立新的網路」（新的網路編號）。§2.8 顯示時把這句換成固定句，避免使用者以為是同一個網路。
8. **（G-m9 / F-m11 未處理）`NetIndex`「記一行路徑」** 會寫出 `net/<net_id 全碼>`；照 §6 的規則要經 `NodeLink.mask` 或只記後四碼。
9. **（G-m7、G-m8 未寫明）** 交接後 `link.state` 監聽是誰註冊、串流 `onError` 由誰轉成 `notSent`；`loginFor` 在 `gate.scan` 還在閘門裡等名額時結束（例如 `precondition`），「先停掃描」停不到，要照 node_link.dart:277-280 等它回來再 `stop`。兩條都是一句話的補充。

---

## 之前的 BLOCKER / MAJOR

| 項目 | v5 判定 |
|---|---|
| G-M1 / H-M1 判定欄位 | ✅ 建立 / 檢查只看 `NetView.applied`；加入看 `!joining && !approved`。核對：owner.rs:118 `joining`、:122 `approved = Approved`；join2flow.rs:528-530 加入成功 = `Applied`；netrec.rs:524-533 `confirm` 升級不補 device id；owner.rs:1460-1469 `Applied` 才補。判定順序表寫了、`noRecord` 寫了。⚠️ 形狀釘子不完整（MINOR 4）。 |
| G-M2 / H-M2 dev 出口沒有條件 | ✅ 舊控制台出口拿掉；待辦只在沒有 applied 時列。⚠️ 但同類問題換了一個形狀出現（M1）。 |
| G-M3 剛認領完不能當建立者 | ✅ 4.1 訂閱 `NodeLink.changed`（node_link.dart:79-82 存在）。 |
| H-M3 D4 前後不一致 | ✅ 採 H 的 (a)。前提「pending 不會有其他成員」成立：加入要求 applied（join2flow.rs:340-342）、邀請要求 applied（invite.rs:187），核准要先有邀請（approve.rs 檔頭 :4-7，⚠️ 只讀檔頭說明）。剩下的風險見 M1。 |
| E-B1 / F-B1、E-M1..M3、F-M1..M2 | ✅ 同 G / H 的結論，本輪抽查 prober.dart:92-104（結束對應）、raw_use.dart:73-82（`openRawPage` 不動）、ble_gate.dart:84-86、:185-206、:226-231 無誤。 |
| A–D 的 BLOCKER / MAJOR | ⚠️ 依 E–H 的對照，本輪未逐條重驗。 |

## 指定要查的問題

- **pending 的網路能不能有其他成員**：不能（見上表）。但 D4 的風險不在「其他成員」，在建立者自己（M1）。
- **舊建立者留在舊網路**：看不到、沒出口（M1 情境 A）；可以不經 PR 4 修好——對它做「檢查網路 A」會升級 A（netrec.rs:511-536 只比 key 10 / 9），前提是 B 還沒建；B 建了之後才需要 PR 4 的離開。這正是修法 1 要擋在 B 之前的理由。
- **§2.2.1 判定順序 vs Rust 狀態**：✅ 主要路徑對；缺 `NotSent` 還原與 generation（MINOR 2）、重讀時機（MINOR 1）。
- **§2.7 只列最新 pending**：Dart 讀得到修改時間（node_link.dart:197-200 已用 `Rec.mtime`），但 `NetIndex` 契約沒寫（MINOR 6）。舊的 pending 永遠留著：`NetIndex` 每次重算都多解密一筆、4.1 加入表單只列 applied ✅、舊控制台的選網路對話框會標「建立中」（nodes.dart:614-621）✅，沒有其他讀者會被它卡住。
- **applied + pending 並存時的 `NetIndex` 與加入表單**：✅ 第 6 列走「加入網路」、加入表單只列 applied、閘門不准建立。
- **§7 的改壞會不會真的 FAIL**：大多可以；「先 `exists()`」那一條不會（MINOR 5）；判定測試靠手抄的形狀（MINOR 4）。
- **有沒有不必要的東西**：沒有看到多餘的機制。`FrameInbox`、`loginOutcome`、`openRawPageFor<T>` 都對應到具體的失敗。M1 的修法只用現有欄位。

## 安全（逐 actor）

- **遠端 BLE / 惡意廣播**：8 s 的 msg2 預算 + 不認得的結束一律 `noResponse`（prober.dart:99-101）✅；msg2 之後沒有上限（MINOR 3）。
- **被入侵的節點**：只能換掉自己的成員項（join2flow.rs:345-365）✅。它也能**謊報 `netId`**：若照 M1 修法 1 用 `netId` 擋建立，一台謊報「我在 A」的節點能讓使用者去「檢查 A」——`confirm` 只在 key 10 / key 9 都對時升級（netrec.rs:511-521），而建立者的身分在登入時驗過；最壞是升級一筆它自己建立的 pending，和現況「它謊稱已套用」同級，可以接受，要寫進 §6。
- **本機無權限 app**：沒有新的入口、平台方法或匯出元件 ✅。
- **我們自己的錯**：M1（D4 的理由前提不成立）；MINOR 4（假資料漂移）；MINOR 5（改壞分辨不出）。
- **秘密**：`OwnerConsole` 只記種類 / 代碼 / 後四碼 ✅；`NetIndex` 的路徑要遮（MINOR 8）。
- **沒有佔用時 fail-closed**：✅ `BleGate._usable`（ble_gate.dart:84-86）、`RecordWriter._check`（record_writer.dart:27-33）。注意 `_check` 與 `await store.writeCas` 之間佔用仍可能被收回（現況，不是 PR 3 新增；收回時寫入已在途，CAS 保證不覆蓋別人）。
- **TOCTOU**：閘門在佔用下重新列檔 ✅；M1 修法用的是佔用前最後一次讀取，可能過期——所以修法 3 要求 §2.8 的次要按鈕依「這次讀得到」決定，過期 / 讀不到一律不給建立（fail-closed）。

## 生命週期補充

- **升級 / 回退 / 降級**：紀錄格式不變 ✅；回到沒有 PR 3 的版本時，多筆 pending 在舊控制台的對話框標「建立中」，加入會被 Rust 拒（NotApplied，join2flow.rs:340-342）fail-closed。§3.3 那一列可改寫成這句，不需要新測試。
- **`keepScreenOn`**：swupdate.dart:135-139 用的是軟體更新頁自己的 channel；`NetworkRun` 要寫明用哪個 channel，且 `PlatformException` 照現況吞掉（D9 只是方便）。一次只有一個佔用，兩者不會同時 ✅。
- **app 被殺**：`lastClaimNote`、`FrameInbox`、hold 都在記憶體，隨 process 消失；佔用不跨 process ✅。

---

## 我做了什麼

### ✅ 已驗證（原始碼原文節錄）
- home_logic.dart:31：`bool get notInNetwork => view != null && view!.nodeState.toInt() == 1;`
- node_page.dart:128：`if (v != null) ...['版本 ${v.version}', if (v.netId.isNotEmpty) '網路 ${v.netId}', ...v.tech],`
- lib/src/rust/api/owner.dart:559-560：`/// info key 10 (lowercase hex): the network the node is in; the app maps it to a local record's name` / `final String netId;`；:575-576 `final String unfinished;`
- owner.rs:125：`NetView { net_id: nodecert::hex_lower(&r.base.net_id), ... applied: r.state == netrec::APPLIED, ...}`
- owner.rs:1067-1088：`request_make_network` 只檢查 `flow_busy()`、`self.node`、`St::Conn`；`node_name: format!("node-{}", self.last4)`。
- owner.rs:478：`JoinState::NotApplied => "網路：沒有套用（或已還原），可以再建立一次同一個網路"`
- owner.rs:879-893：`info-confirm` 只有 `Upgraded` 才 persist。
- flow.rs:166-170：key 10 不在時 `Some(true) => InProgress`、`Some(false) => NotApplied`、`None => Unknown`。
- join2flow.rs:340-342：`if rec.state != netrec::APPLIED { return Err(End::Refused(Pre::NotApplied)); }`
- join2flow.rs:756：`(JoinState::OtherNetwork, _) => self.fail(Fail::OtherNetwork)`
- join2flow.rs:507-514：`Fail::NotSent(_) => self.before.clone()...`，其他 `None`。
- netrec.rs:395、:511-536（`confirm` 不看登入的是誰、升級不補 device id）。
- invite.rs:187：`return Err(Error::NotApplied);`
- prober.dart:37 `answerMax`、:92-104 結束對應、:134 結果決定後丟訊框。
- ble_gate.dart:84-86、:185-206、:226-231、:241-248；node_link.dart:153-165（`acquire` 先 `_dropAll`）、:171-195（`released`）；lease.dart:96 `goneMax = 420 s`；record_writer.dart:27-40；ui_state.dart:131-138；raw_use.dart:73-82；swupdate.dart:137；nodes.dart:614-621。
- §1 事實表：P5、P9、P10、P13、P14、P15、P16、P17、P19、P20、P23、P25 內容一致（行號差 1–2 行的不計）。

### ⚠️ 推論（沒有實跑）
- M1 情境 B：節點在套用中時狀態頁 key 1 是否為 1、收到第二個建立要求時的行為，要看 firmware，本 repo 查不到。
- M1 情境 A 的「首頁顯示正常」：依 home_logic 的列序推論；節點單獨在 A 時狀態頁是 green 還是 yellow（沒有鄰居）沒有查證，但無論哪一種都沒有告訴使用者原因與出口。
- approve 需要先有邀請：只讀 approve.rs 檔頭說明。
- MINOR 1 的時機、MINOR 5 的行為等價：依程式結構推論。

### ❌ 沒做
- 沒有跑 Dart / Rust 測試、`flutter analyze` 或建置。
- 沒有真機。
- 沒有逐條重驗 v1–v2（A–D）的每一個 MAJOR。
- 沒有讀 nodes.dart 請求機制全文、沒有驗證 9b00ca6 的「改壞 5/5」。
