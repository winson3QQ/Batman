# #329 PR 3 實作計畫 v8 審查（審查者 P，獨立）

對象：`docs/design/329-pr3-plan.md` @ a55a08c（branch feat/329-pr3）。範圍照 v8 §0：只審新頁面、`loginFor` / 交接 / `OwnerConsole`、多台迴圈、`NetIndex`、首頁按鈕去處，以及新頁面和舊控制台在同一情況下行為不同的地方。join2 的建網 / 加入 / 確認行為不重新決定，疑問放在最後的「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 2 MAJOR / 8 MINOR）

v8 拿掉自己加的閘門與結果分類，方向正確；§2.1–§2.3 的新程式跟 v1–v6 的發現大致對得上。剩下兩個問題都是新頁面的路徑沒接好：一個是設計要求的「再試一次先清『不是 Y』」沒有放進來，一個是建立網路沒有確認完時，新頁面沒有入口可以再建立一次。

## MAJOR

### P-M1　`loginFor` 的簽章少了設計 §4.3.9 的「再試一次先清『不是 Y』」
- **情境**：剛認領完的 04，第一次 `loginFor` 時 N9 的 30 s 已經過了（例如使用者在 3.2 取名花了比較久），節點還沒換好身分，回「解不開」。core.dart:705-710 會對這個位址記「不是 04」。結果頁按「再試這一台」，`next()` 會跳過有「不是 Y」備忘的位址（core.dart:676 `!c.isNot(a, id)`），所以在位址輪換之前每次都是 60 s 後 `notFound`。這是設計第七輪 B-m7 指出的情境。
- **證據**：設計 329-app-uiux.md:547 寫「再試一次」呼叫 `loginFor(佔用, Y, 先清「不是 Y」)`。core 已經支援（core.dart:628 `{bool clearNotY = false}`）。計畫 §2.1 的簽章是 `loginFor(Lease lease, String id)`，§2.5「再試這一台」只寫「重用同一個佔用」。v1 A-B1 / B-B1 都寫了 `{clearNotY}`（review-pr3-plan-A.md:50-51、B.md:31），§9 說有保留，但實際上被拿掉了。
- **修法**：改成 `loginFor(lease, id, {bool clearNotY = false})`，直接傳給 `core.loginFor`。結果頁的「再試這一台」、流程頁的前提恢復後的「再試一次」都傳 `true`。加測試：位址先有「不是 Y」，`clearNotY: true` 時會試這個位址；改壞對照是忽略這個參數，測試要 FAIL。

### P-M2　建立網路沒有確認完時，新頁面沒有「再建立一次」的入口；§3.2 說的待辦也不存在
- **情境**（只用新頁面）：建立網路的途中手機 app 被殺或拔電，或者結果頁顯示「結果不明」之後使用者離開。這時手機有一筆 pending 的 `net/`。
  1. 首頁第 6 列：只要有任何 net 紀錄就給「加入網路」（home_logic.dart:93，pending 也算）。
  2. 對建立者按「加入網路」，Rust 拒絕：`Pre::NotApplied`，句子是「請先在建立網路的節點按『檢查網路』」（owner.rs:568）。
  3. 到節點頁按「檢查網路」，Rust 回 `NoChange(NotApplied)`，句子是「沒有套用（或已還原），可以再建立一次同一個網路」（owner.rs:478、:490）。
  4. 這時新頁面沒有任何地方有「建立網路」：§2.4 只在「沒有 net」時給；設計 §5.5 的節點頁網路分組只有「加入網路 / 檢查網路」（329-app-uiux.md:755）；§2.4 寫「使用者可以照它的話按『建立網路』」，但沒有寫這顆按鈕在哪一頁。

  舊控制台的「建立網路」按鈕一直都在（nodes.dart:1730）。所以這是新頁面在同一個情況下比舊控制台少了一條路，也就是 v2 D-B1 的死路，換了一個形式。此外，§3.2 寫「紀錄停在 pending → 首頁待辦與『檢查網路』」，但設計 §5.1 的待辦只有「節點加入網路沒有做完」（joining 的成員），計畫 §2.6 也只做 joining。pending 的 net 沒有待辦。v2 C-M4 也指出過：pending 紀錄裡建立者沒有 device id，因為 owner.rs:1463-1469 要到 Applied 才會填。這一條沒有列進 §9。
- **修法**（不要重新分類 Rust 的結果，比照舊控制台即可）：節點頁對 `node_state == 1` 的節點，除了「加入網路」，也給次要按鈕「建立網路」（進 4.1 的建立模式，預選這一台）。把 §3.2 那一列改成實際的路徑：首頁第 6 列 →「加入網路」被拒的句子 → 節點頁「檢查網路」→「建立網路」。建立模式要加入的網路是這一次 persist 步驟寫的 `rel`，不是另外挑一筆（見 m3）。加一個情境測試 T-M2b：pending net + 建立者 node_state 1，只用新頁面能走到再建立。改壞對照是拿掉這顆按鈕，測試要 FAIL。

## MINOR

1. **m1　P8 的證據不完整**：`[JOINED]` 不只出現在 `E::Applied`（owner.rs:514）。連線檢查的 `link_text` 也會用（owner.rs:589-590），舊控制台的 `_linkUnknown` 也是（nodes.dart:53）。多台迴圈判斷「加入成功」時，只能看 `requestJoinNetwork` 這一次的回答，不能看最後一行或連線檢查的回答。P8 要補上這兩處；測試要包含「加入結果不明，之後的 `_linkUnknown` 不算成功」。
2. **m2　§2.5 每一台的步驟漏了 `send_update`**：Rust 在 `applied && behind` 時設 `send_update`，這時 `poll_link` 是 false（owner.rs:1437-1439）。舊控制台會接著 `_sendUpdateFor`（nodes.dart:663-667），設計 §5.4 的表也有這一步。§2.3 有把它複製進 `OwnerConsole`，但 §2.5 沒有寫迴圈要呼叫它，也沒有寫這一步失敗時那一台算什麼結果。
3. **m3　建立模式的細節沒寫**：勾了好幾台時，哪一台當建立者（有好幾台都符合、或一台都還沒讀到時怎麼辦）？其他台要加入的網路是哪一個？應該是這一次 persist 的 `rel`。手機裡已經有舊的 pending net 時，`_pickNet` 一筆就不問的規則會挑錯。另外，§2.5「建立者要是讀到、還沒加入網路的那台」和 §9「拿掉：建立者的額外條件」互相矛盾。如果要保留，請寫成顯示條件，並說明不符合時畫面上看到什麼。Rust 和節點本身已經會拒絕在別的網路裡的建立者（`OtherNetwork`）。
4. **m4　沒有列出和設計不同的地方**：設計 §5.4 寫「建立回來後紀錄不是已套用：自動做一次『檢查網路』」（329-app-uiux.md:738，A18 ⚠️）。計畫 §2.5 改成停下來顯示 Rust 的句子。這樣做本身沒問題，和舊控制台一致，但應該列進 §4 的 D 清單，也要在真機計畫裡確認 A18。
5. **m5　「節點加入網路沒有做完」的待辦去哪裡沒寫**：設計 §5.1 寫「4.x 接著做；同一頁有『放棄這次加入』」。計畫沒有寫待辦按下去開哪一頁、預選哪一筆，也沒有「放棄這次加入」（`net_forget_joining`，寫入經 `RecordWriter`）。節點壞掉或送修時，這一項待辦在新頁面上會永遠消不掉。要嘛做進來，要嘛列為 D 項，並寫明舊控制台的入口。
6. **m6　`NetIndex` 計算中或列不出來（`unknown`）時，「加入網路」按下去去哪裡沒寫**：home_logic.dart:93 把 unknown 和 net、mnet 都送到 joinNetwork。只有 mnet 的手機在計算中按下去，可能會進到隊長的 4.1，然後看到「手機裡沒有可用的網路紀錄，不能再加節點，若 App 重裝過…」（nodes.dart:612-614），這句話會嚇到人，而且是錯的。建議：按下去時先等 `NetIndex` 算完再分流；一直列不出來時顯示錯誤，不進 4.1。
7. **m7　頁面消失時 hold 什麼時候放沒寫清楚**：§2.5 的 hold 一路拿到離開結果頁。如果頁面消失時 hold 沒有在當前請求結束後立刻放掉，`pageGone` 會讓佔用撐到 420 s，然後被收回（lease.dart:73-76），首頁會多一項錯誤的「上一個操作可能沒有存完」（lease.dart:139）。T-M1(g) 要斷言請求結束時佔用就釋放，而且 `unsavedTodos` 是空的。
8. **m8　§9 的來源追溯不完整**：計畫說 v1–v7 共 14 位審查，但 `docs/design/329-reviews/` 裡只有 A–L 12 份，v7 的兩份不在 repo 裡，所以 §9 是否忠實帶過 v7 的發現無法核對。請把那兩份放進來。另外，離開 4.1「回到進來前的那一頁」時，要連 `Page.node` 的 node 參數一起還原（core.dart:188 用 `node == pageNode` 判斷有沒有換頁）。

## 生命週期（新頁面）抽查
- 開始、正常結束、佔用收回、藍牙 / 權限 / 金鑰中斷：§3.2 有寫，也有對應的測試，✅ 合理。藍牙 / 權限 / 金鑰中斷時，`setRadio` 會立刻把 `_login` 結束成 precondition（core.dart:280-292）。
- 節點重開：Rust 的「結果不明」句子 → 問「繼續 / 停」。✅ 和舊控制台一致（nodes.dart:536-551 的 unclear 路徑）。
- 背景 / 關螢幕：`keepScreenOn` 只在等待頁開。⚠️ 背景時藍牙掃描靠的是服務過濾，這次沒有查 gate 的掃描參數。
- dev2 在同一支手機上：它是另一個 app（另一個 uid），有自己的 `NodeLink`。dev2 在前景時可能先連上同一台節點，dev 的 `loginFor` 會「沒有回應」，60 s 後 `notFound`。這和舊控制台一樣，不算發現。⚠️ 沒有實測。
- 頁面消失：見 m7。

## 安全（逐 actor）
- **遠端惡意廣播者**：還沒登入就結束算 `noResponse`，不會留下「是 Y」備忘（prober.dart:100-102，`loginOutcome` 原樣抽出）。`refusedOther` 只有在節點已經認證之後才可能出現。大約 7 個不回應的位址就能吃光 60 s，設計已接受。✅
- **交接**：只有 `loggedIn` 之後才交出，而且這時節點憑證已經比對過（loginflow 先檢查 CertRejected）。`FrameInbox` 只放已登入連線上的訊框。建議設一個上限，例如超過 64 筆就把連線當成壞掉，屬於 nit。
- **本機無權限程式**：沒有新的平台方法或匯出元件（§5）。`RecordWriter` 在沒有佔用時拒絕寫入（record_writer.dart:27-33）。✅
- **秘密**：`OwnerConsole` 不寫回答內容；Rust 的句子本來就不含秘密（owner.rs:434-436）。✅

## 基準備註（不算發現）
- `RecordWriter._check` 在 `await store.writeCas` 之前檢查佔用。如果在檢查和寫入之間佔用被收回，這一筆仍然會寫進去（record_writer.dart:38-41）。這是 PR 1 的做法。
- Rust 的句子說「可以再建立一次同一個網路」，但每次建立都會產生新的 net_id（`request_make_network` 不吃舊紀錄，owner.rs:1067-1088），所以舊的 pending 紀錄會一直留著，也會出現在 `_pickNet` 的清單裡。這是 join2 的基準行為。

## 從零到兩台的實際路徑（推論）
新增 04（`ClaimPage`，原始佔用）→ `ClaimDone` → 取名 → 3.5「建立網路」→ 4.1（`Page.home`；佔用釋放 6 s 後一輪，N9 的 30 s 內解不開會重試）→ 開始（`acquire` 等 `released` 讀完紀錄）→ `loginFor` 04 → 建立 → `[NET_MADE]`，重讀紀錄是已套用 → 結果頁。新增 02 → 3.6「加入網路」→ 4.1（只有一筆網路，直接選）→ `loginFor` 02 → 國家對話框 → `[JOINED]` → 連線檢查最多 120 s。⚠️ 只看了原始碼，沒有實際跑。中斷的情況見 P-M2。

## 驗證分類
### ✅ 已驗證（原始碼原文，worktree a55a08c）
- owner.rs:446-447 `net_made_text`；:514 `[JOINED]` 只在 `E::Applied`；:589-590 `link_text` 也用 `[JOINED]`；:478、:490 NotApplied 的句子；:1437-1439 `poll_link` / `send_update`；:1463-1469 device_id 到 Applied 才填；:1067-1088 建立網路不檢查節點狀態。
- core.dart:628-641 `loginFor({clearNotY})`；:676 跳過有「不是 Y」備忘的位址；:280-292 `setRadio` 結束 `_login`。
- prober.dart:94-104 結束種類的對應；node_link.dart:153-195 `acquire` / `released`；ble_gate.dart:107-126 `close` 在 finally 移除連線；lease.dart:71-79、:132-141 420 s 收回並加待辦。
- home_logic.dart:92-96 只要有 net 就給 joinNetwork；nodes.dart:476-492、:626-671、:687-716 舊控制台的建立、加入、連線檢查；nodes.dart:1730 舊控制台一直有「建立網路」。
- 設計 329-app-uiux.md:547（clearNotY）、:738（自動檢查）、:755（節點頁網路分組）、§5.1 待辦表。
- `ls docs/design/329-reviews/`：只有 review-pr3-plan-A…v6-L 共 12 份。

### ⚠️ 推論
- 從零到兩台的路徑、dev2 的干擾、背景掃描：只讀了原始碼，沒有實際跑。

### ❌ 沒做
- 沒有跑測試，也沒有上真機。
- 沒有逐條重驗 v1–v6 每一個發現的修法，只抽查了和新程式有關的部分（clearNotY、C-M4、D-B1）。
