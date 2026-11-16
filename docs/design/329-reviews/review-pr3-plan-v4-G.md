# #329 PR 3 實作計畫 v4 審查（審查者 G，獨立）

對象：`docs/design/329-pr3-plan.md` @ 514d3df（feat/329-pr3）。整份重看，不只看 v4 的改動。
上層設計：`329-app-uiux.md`。原始碼以同一個 commit 的 `app/` 為準。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 3 MAJOR / 9 MINOR）。

三個 MAJOR 都是計畫文字層級的修正（改判定欄位、補一條規則、補一張處理表），不必重新設計。但依全域規則，MAJOR 修完後要再整份審一次。M1 如果照字面實作，**主要路徑（加入成功、建立後經檢查升級）會全部判錯**；而 Dart 測試用 `RustLib.initMock`，假資料會讓這個錯照樣全綠。所以 M1 的修法一定要包含 Rust 端的測試。

D4（拿掉「重新建立」）：**我接受。** 理由與條件見最後一節。

---

## MAJOR

### M1　§2.2.1 重讀判定：用錯欄位，找不到建立者的成員項；表格各列重疊；mock 測試抓不到

**情境 A：加入成功。** 加入者的流程正常結束，紀錄裡它的成員項是 `MemberState::Applied`。
- 計畫的 `applied` 列寫「這台的成員項 `approved` 且網路 `applied`」。
- 但 `MemberView.approved` 是 `m.state == MemberState::Approved`（owner.rs:122）。`Approved` 指的是「隊員的節點、由管理者核准」（netrec.rs:43-44 的註解：「a remote member's node this admin approved」）。
- 隊長自己加入的節點，狀態是 `Applied`（join2flow.rs:528-532 `e.state = MemberState::Applied`）。在 `MemberView` 上是 `joining = false`、`approved = false`。
- 照字面實作：每一次成功的加入都不符合 `applied`、不符合 `joining`、也不是 `absent`，落在表外。

**情境 B：建立回來結果不明，自動檢查（或之後 §2.8）把紀錄升級。**
- `JoinReply::ReadInfo` → `check_network` → `netrec::confirm` → `Upgraded`（owner.rs:1487-1492、:879-890）。
- `confirm` 用 `rec.members()` 做新的清單（netrec.rs:524-533）。v1 成員一律 `device_id: None`（netrec.rs:212 `member_base`）。
- 升級之後，`pending_creator()` 回 `None`（netrec.rs:404-410），所以 `MemberView.creator = false`，`last4 = ""`。
- 計畫寫「以 `MemberView.deviceId` 對；建立者在 pending 紀錄裡用 `PersistNet` 剛寫的那筆」。但這時紀錄已經是 applied，建立者那一項**沒有 device id、沒有 creator 旗標**，對不到 → `absent` → 「建立者不是 `applied` → 整個流程停」。網路其實已經建好了。
- 只有 `JoinReply::Applied` 這條路會把 device id 補進所有成員（owner.rs:1460-1466）。哪一條路在真機上比較常見還不知道（§8 A18）。

**情境 C：建立後仍是 pending。**
- pending 紀錄的建立者在 `members()` 裡是 `Joining`（netrec.rs:395），所以 `MemberView.joining = true`。
- 它同時符合表裡的 `joining`（「結果不明 +再試這一台」）和 `notApplied`（「檢查網路」）。計畫沒有寫先後順序。

**為什麼測試抓不到**：Dart 測試的 Rust 是假的（例如 `test/nodes_persist_pop_test.dart:57 RustLib.initMock(api: rust)`）。§7 步驟 3 的「重讀得 `applied`」如果用手寫的 `MemberView(approved: true)` 當假資料，會把錯的對應釘死。

**修法**：
1. 判定改成兩種，分開寫：
   - **建立 / 檢查**（`makeNetwork`、`confirmNetwork`）：只看 `NetView.applied`。`confirm` 會在同一次寫入裡升級紀錄和建立者（netrec.rs:524-533），所以不需要找成員項。
   - **加入**：用 `deviceId` 找這台的成員項。
     - 項目存在、不是 `joining`、網路 applied → `applied`；
     - `joining` → 不明；
     - 沒有項目 → `absent`。
   - 拿掉 `approved` 這個條件。
2. 表格寫明優先順序：`leaseLost` > `keyFail` > `cancelled` > `unreadable` > 依紀錄判定。
3. 加一個 Rust 測試（bridge），釘住 Dart 會依賴的 `net_summary` 輸出：
   - (a) `JoinReply::Applied` 之後，建立者有 `device_id`；
   - (b) `Confirm::Upgraded` 之後，建立者 `device_id` 是空的、`creator = false`、紀錄 applied；
   - (c) 加入成功的成員是 `joining = false`、`approved = false`、有 `device_id`；
   - (d) 確定失敗（`Fail::OtherNetwork`）之後沒有這台的項目；`NotSent` 之後回到 `before`。

   Dart 端的分類測試用這幾種形狀當假資料，再加改壞：
   - 用 `approved` 判定 → (c) FAIL；
   - 建立用成員項判定 → (b) FAIL。
4. 真機 §8 補一條：建立結束時記下走的是哪一條路（`Applied` 或 `ReadInfo` → 升級）。

### M2　dev 的出口會留下多筆 net 紀錄：計畫沒寫 `NetIndex`、待辦、§2.8 怎麼處理（v3 E-m9 沒有對應）

**情境**：
1. 情境 2（§8：建立途中拔電）。檢查得到 `NotApplied`。
2. dev 使用者照 §2.8 的按鈕「到舊控制台重新建立」，建好新網路。
3. 舊控制台每次都產生新的網路編號（P19），舊的 pending 紀錄留著。
4. 結果：手機有一筆 applied、一筆 pending。

之後：
- 待辦「建立網路沒有確認完」（§2.7：有 net、`applied = false`）**永遠存在**。
- 點進 §2.8：對象是用 `node-<last4>` 找到的同一台。那台現在在新網路裡，`confirm` 回 `OtherNetwork`（「已停止」）。
- 新畫面沒有任何方式清掉它：`forget_joining` 不准忘記 pending 的建立者（netrec.rs:543-545），計畫也刻意不加刪除。
- 如果使用者在 InProgress / Unknown 時就按了重新建立（按鈕不分狀態），也可能留下**兩筆 pending**。§2.4 與 §2.8 都寫「pending 那筆」（單數），對多筆沒有規則。
- v3 審查 E 的 m9 就是這一點，但 v4 §12 的對應表沒有列它。

這是 PR 3 自己的出口（D4）一定會產生的狀態，而且就在 §8 的展示場次裡。

**修法（不加新機制）**：
1. §2.4 / §2.7 / §2.8 寫明「每一筆 pending 各自一項」：
   - 待辦逐筆列出（網路名稱 + 建立時間 / 後四碼）；
   - §2.8 處理的是點進來的那一筆（`rel`），不是「pending 那筆」。
2. 有 applied 的 net 時，pending 的待辦降成次要（例如收在「其他」），不擋第 6 列。在 §9 寫明這是已知限制：清掉要等殘項的 Rust 結構化狀態。
3. 測試：
   - 一筆 applied + 一筆 pending → 第 6 列是「加入網路」、4.1 只列 applied 的、待辦只有一項；
   - 兩筆 pending → 待辦兩項、各自的 `rel`。
4. §12 補上 E-m9（以及下面 MINOR 9 列出的其他漏項）。

### M3　建立模式：剛認領完的節點還沒讀到 → 不能當建立者 → 第一次使用最常見的路徑會卡住

**情境（第一次使用的隊長）**：
1. 新增 04，`ClaimDone`。
2. 3.2 暱稱（幾秒）→ 3.5「建立網路」→ 4.1 建立表單。

這時 04 多半還沒被 `NodeLink` 讀到：
- 佔用釋放 → 讀紀錄 → 6 s 後才開始下一輪（設計 §4.3「佔用釋放後 6 s」，core `releaseLease`）；
- 剛認領完前約 4–10 s 會回「解不開」（N9；設計 T-L13(b)）。

計畫 §2.3 寫「沒讀到的節點可以勾但不能當建立者」。「從待辦或節點頁進來：一定可勾」沒有包含從 3.5 進來的 `ClaimDone` 節點，而且「可勾」也不等於「可當建立者」。所以 4.1 沒有任何可以當建立者的節點，「開始」按不下去，或要使用者自己退出再進來。

計畫沒有寫 4.1 會不會跟著 `NodeLink` 的讀取結果即時更新。設計自己的 T-L17 正是「寫完紀錄立刻對 Y `loginFor`、≤15 s」，表示設計原本就預期剛認領完可以直接建立。

**修法（二擇一，寫進 §2.3 並加測試）**：
- (a) 4.1 訂閱 `NodeLink` 的變化（它不拿佔用，`NodeLink` 照常讀）。還沒讀到的那台顯示「正在讀取這台…」；讀到「沒加入網路」就變成可當建立者。
  - 測試：假 `NodeLink` 先回「沒讀到」，3 s 後回「沒加入網路」→「開始」從不能按變成能按。
  - 改壞：不訂閱 → FAIL。
- (b) `ClaimDone` 那一台（本次 app 執行中剛認領、認領時驗過身分）可以當建立者。
  - 但建立會先寫 pending 再送（P19）。如果那台其實在別的網路裡，會留下 pending，在 field 版就是死路（D4）。所以建議 (a)。

---

## MINOR

1. **重讀的時機。** `ask` 逾時（unclear）時，訊框佇列可能還在 `persistNet` 中間（Keystore seal + CAS）。這時重讀會拿到寫入之前的紀錄，判成 `absent`，之後寫入才落地。
   - 修法：重讀之前先等 `FrameInbox` 的處理佇列閒下來（或先 `close` 再讀）。
   - 測試：persist 卡住 → 逾時 → 先等再判定。
2. **舊的成員項會讓「完成」變成誤判。** 如果 `begin` 在寫入之前就拒絕（`Pre::Full`、`NotAdmin`、`RemovedBefore`，join2flow.rs:340-353），紀錄沒有變。這時如果那台原本就有 `Applied` 的項目，重讀會判成 `applied`。
   - 修法：記下請求前的 generation；請求後 generation 沒變，又不是 `notSent`，就用 Rust 的句子 + `absent` 類的顯示，不判「完成」。
   - 或者至少在連線檢查失敗時不顯示「完成」，見 6。
3. **`HandoffProber` 收到 msg2 之後到 `loggedIn` 沒有上限。** `SessionProber` 有 20 s 的 `answerMax`（prober.dart:37、:145）。計畫只寫「8 s 內沒收到 msg2 就結束」。一個送了 msg2 就停住的裝置，可以一直佔著到 60 s。
   - 照抄 `answerMax`，並加改壞。
   - （v3 E-m10 的一部分，沒有對應。）
4. **§2.8 的 dev 按鈕。**
   - 開舊控制台前要先放掉 §2.8 的 session 佔用。舊控制台走 `openRawPage` → `acquire`，§2.8 頁面還在底下沒有離開，佔用沒放，會得到「另一個操作還在進行」。
   - 按鈕不分 InProgress / Unknown 都出現，正是 E-B1 / F-B1 說的分裂情境（只是改由舊控制台執行）。至少要在按鈕旁寫「節點說『還在設定中』或『無法確定』時，先等一分鐘再檢查，不要重新建立」。
   - 或者乾脆不給按鈕：dev 版設定頁本來就有「舊版控制台」（settings_page.dart:44）。這樣更符合「只做必要的」。
5. **field 版顯示的句子會誤導。** `NotApplied` 的 Rust 句子是「可以再建立一次同一個網路」（owner.rs:478），但 field 版沒有任何動作做得到。
   - field 版這一種結果改用固定句：「這一版還不能重新建立，請……」。
   - 這是 D4 的直接後果，也寫進 §9。
6. **連線檢查的結果沒有位置。** 加入 `applied` 之後的連線檢查（每 10 s、最多 120 s）如果沒有通過，§2.2.1 和結果頁都沒有寫顯示什麼。建議用「已加入，還沒確認連上」，不要顯示「完成」。
7. **交接之後，訂閱的 `onError` 與 `link.state` 監聽由誰處理沒寫。**
   - prober 的 `onError` 會呼叫已經完成的 `done`，沒有任何效果（prober.dart:151）。
   - `LoginHandoff.close()` 提到要取消 `link.state` 的監聽，但 §2.1.1 沒寫是誰、在什麼時候註冊的。
   - 要寫明：交接後串流錯誤 / 斷線交給 `OwnerConsole`，並轉成 `notSent` 或重讀判定。
8. **`loginFor` 結束時，掃描可能還在閘門裡等名額。** `gate.scan` 等待期間還沒回傳（ble_gate.dart:189-196），「先停掃描」停不到它。
   - 照 node_link.dart:277-280 的做法，等它回來後立刻 `stop`。
   - `NodeLink.dispose` 也要收掉 `_lf*`（node_link.dart:352-358，v3 E-m12）。
9. **§12 對應表不完整。** 沒有列出：
   - E-m9（多筆 pending，見 M2）；
   - E-m11（3.5 / 3.6 在 `NetIndex` 計算中時要用中性狀態；§2.5 的 3.5 / 3.6 列沒有寫計算中的情況）；
   - E-m12、E-m13（暱稱 ZWJ）；
   - F-m2 的「掃描還在等名額」；
   - F-m11 的「路徑經 `NodeLink.mask`」（§2.4「記一行路徑」沒寫要遮）。

---

## 之前的 BLOCKER / MAJOR 是否真的解掉

| 項目 | 結論 |
|---|---|
| E-B1 / F-B1（重新建立） | ✅ 動作拿掉了，判斷資料的問題跟著不存在。⚠️ dev 按鈕把同一個風險轉到舊控制台（MINOR 4）。 |
| E-M1（標籤分類） | ⚠️ 方向對（看紀錄），但判定欄位錯（M1）。 |
| E-M2（建立者不在了） | ⚠️ field 版仍是死路，已寫進殘項（D4）；dev 版走舊控制台。可接受，理由見下一節。 |
| E-M3（`loginFor` 掃描 / 叫醒 / 名額 / 60 s） | ✅ §2.1 全寫了。漏了「等名額中的掃描」（MINOR 8）。 |
| F-M1（`loginOutcome`） | ✅ 對照 prober.dart:96-104，抽成純函式、`SessionProber` 改呼叫，對應不變。 |
| F-M2（`openRawPageFor<T>`） | ✅ 舊的不動。兩個呼叫者（main.dart:87-88、home_page.dart:55-61）仍用 `busy != null`，相容。 |
| C-M1..M5、D-M1..M4 | 同 v3 E / F 的結論；D-M1 剩下的部分見 M1。 |

## D4 是否可接受

可以，有條件：
- 使用者的目標是「從 0 到組網」，展示給別人的手機。今天「別人的手機」就是 dev 版，因為 field 版受 #255 影響跑不起來（P11 / §9）。
- dev 版有出口：§2.8 按鈕，或設定頁的舊版控制台。
- 建立途中斷電，最常見的結果是「還在設定中」或「已套用」。§2.8 重新檢查就能收尾（`confirm` 升級，netrec.rs:511-536）。真正走不出去的只有「確定沒套用」和「建立者不在了」。
- 照「只做必要的修改」與「後續工作會取代它就只止血」，PR 3 不做可靠的重建是合理的。殘項已寫明條件（結構化 `net_state` + `is_creator`）。

條件：
1. M2 要處理：dev 出口留下的紀錄不能讓待辦永遠卡著，而且沒有規則。
2. MINOR 4、5：不要把使用者導向「還在設定中」時的重建，field 版不要顯示做不到的建議。

## 各角色的實際使用

| 角色 / 情境 | 結論 |
|---|---|
| 第一次使用、兩台新節點 | ❌ 會卡在 M3；過了 M3 之後，建立判定還有 M1。 |
| 之後加第三台 | ✅ 加入模式允許「目前讀不到」（§2.3）；判定見 M1。 |
| 建立中斷電 → 檢查網路 | ✅ 升級路徑可以走（建立 / 檢查只看 `applied`，照 M1 修）；死路與多筆紀錄見 D4 / M2。 |
| 加入結果不明、節點其實已套用（補完加入） | ✅ `netId` = 目標可以勾；`begin` 用 `before` 保留舊項目，重送是現有行為（nodes.dart「繼續加入」）。 |
| 隊員手機 | ✅ 只有 mnet / mpend → 舊控制台（dev）或句子（field），D3。 |
| 重裝 app | ✅ 紀錄打不開 → 重裝警告、沒有「開始」；金鑰不會重建（main.dart:196-205、simple.rs:31-48）。 |
| 切背景 / 關螢幕 / 被殺 | ✅ `keepScreenOn`；被殺時佔用只在記憶體裡；待辦接手。 |
| 藍牙 / 權限 / 金鑰失效 | ✅ `setRadio` → `precondition`（core.dart:282-292），先看 `core.blocked`。 |
| 節點重開 | ✅ `notSent` 或重讀判定。注意 MINOR 1 的時機。 |
| 同一支手機上的 dev2 | ✅ 那一台 `noLink` → 問要不要繼續。 |
| 惡意廣播 | ✅ 8 s 的 msg2 預算；MINOR 3 要補 msg2 之後的上限。 |
| 被入侵的節點 | ✅ 只能換掉自己的成員項（join2flow.rs:345-365、P21）。分類看紀錄；MINOR 2 的過期項目只影響它自己那一台的顯示。 |
| 我們自己的錯 | M1 就是這一類；它被 mock 測試掩蓋。 |

## 事實查核

✅ 讀原始碼確認：
- P4（raw_use.dart:25-44）
- P5（ble_gate.dart:84-86 `_usable` 丟 `Refused`；:185-206 掃描名額在閘門裡等；:226-231 connect 一次一條）
- P7（core.dart:282-292、:628-748；`LoginFor.result` 只在 `body` / `errorCode` 結束成 ok）
- P9（prober.dart:96-104、:133-175）
- P10（raw_use.dart:73-82；main.dart:87-88；home_page.dart:55-61）
- P13（join2flow.rs:340-341）
- P14（owner.rs:41-47）
- P15（node_link.dart:171-195）
- P16（owner.rs:79-80、:116；netrec.rs:212、:375-377、:391-396）
- P18（home_logic.dart:92-96；home_page.dart:129-171）
- P19（owner.rs:1067-1088、:1451-1524）
- P20（owner.rs:879-893；flow.rs 的狀態對應；netrec.rs:511-536 不檢查登入的是誰）
- P23（ui_state.dart:131-138 `_save` 串成一列；ui_state_test.dart:179）
- P25（swupdate.dart:137；SwUpload.kt:77）
- P26（main.dart:196-205；simple.rs:31-48）
- A5：pending 建立者的 `name` = `node-<last4>`。owner.rs:1080 → joinflow.rs:209 寫進 members v1 的 key 3 → netrec.rs:209 `member_base` 讀出。
- 新查到的：
  - `MemberView.approved` = `MemberState::Approved`（owner.rs:122；netrec.rs:40-45）；
  - 加入成功 = `Applied`（join2flow.rs:528-532）；
  - `confirm` 升級後建立者沒有 `device_id`（netrec.rs:212、:524-533）；
  - `JoinReply::Applied` 才補 `device_id`（owner.rs:1460-1466）；
  - Dart 測試用 `RustLib.initMock`（nodes_persist_pop_test.dart:57）。

⚠️ 推論，沒有實跑：
- M3 的時間：依設計的 6 s + N9 推算；真機秒數沒量。
- M2 的多筆 pending：依原始碼推出，沒有在真機上走 dev 出口。
- MINOR 1 的時機：依 `ask` 逾時與佇列分開的結構推論。
- A6（`PathNotFoundException`）：計畫自己標了 ⚠️，我沒有實跑。

❌ 沒做：
- 沒有執行任何測試或建置；
- 沒有真機；
- 沒有細讀舊控制台的 `ask` 全文（只看了 :470-640、:1700-1745）。
