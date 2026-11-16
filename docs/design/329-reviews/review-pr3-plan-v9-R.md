# #329 PR 3 實作計畫 v9 審查（審查者 R，獨立）

對象：`docs/design/329-pr3-plan.md` @ c70de1a（feat/329-pr3）。範圍照 §0：只看新的部分、新頁面和舊控制台 / join2 / 上層設計（329-app-uiux.md）沒有寫出來的不同，以及 v8 審查 O、P 的發現是否照 §9 處理掉。join2 的建網 / 加入 / 確認行為不重新決定。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 1 MAJOR / 9 MINOR）

v9 補回的檢查網路頁、`send_update`、`clearNotY`、pending 時的「建立網路」、頁面消失立刻放 hold，方向都對，也對得上舊控制台與 Rust。剩下的 MAJOR 是新資源的擁有權：結果頁和檢查網路頁共用同一個佔用，但兩邊都寫了「離開時釋放」。

## 從零到兩台（只用新頁面，推論）

新增 04（`ClaimPage`）→ `ClaimDone` → 3.2 取名 → 3.5「建立網路」（沒有 net）→ 4.1 建立表單（`Page.home`，勾 04）→ 開始（acquire + hold + `keepScreenOn`）→ `loginFor` 04 → `makeNetwork` → `[NET_MADE]`（owner.rs:447）→ 重讀已建立 → 結果頁 → 新增 02 → 3.6「加入網路」→ 4.1（一筆網路不問）→ `loginFor` 02 → 國家對話框 → `[JOINED]`（owner.rs:514）→ `poll_link` → 連線檢查 120 s → 結果頁。⚠️ 只讀原始碼。這條路徑走得通；中斷路徑見 M1、m1、m3。

## MAJOR

### M1　結果頁與檢查網路頁共用一個佔用，但有兩個釋放者；從結果頁 / 檢查網路頁按「建立網路」也沒寫佔用怎麼交

- **情境**：建立途中斷線 → 自動檢查一次仍不是 → 結果頁（佔用 + hold 還在，§2.5）→ 按「檢查網路」→ 檢查網路頁「從結果頁進來時重用同一個佔用」（§2.4）→ Rust 回「還在設定中，請一分鐘後再按」（owner.rs:477）→ 使用者按返回 → 檢查網路頁「離開時放佔用」→ 回到結果頁，按「再試這一台」/「檢查網路」→ 佔用已經 `_ended`（lease.dart:85-90），`loginFor` 回 `NoLease`、`hold()` 丟 `StateError`（lease.dart:60-61）。反過來，結果頁離開時再 `release()` 一次（冪等，無害）。
  另一條：結果頁 / 檢查網路頁的次要「建立網路」→ 4.1 建立表單；4.1「按開始才拿佔用」（§3.2），但結果頁的佔用和 hold 還在 → acquire 得到「另一個操作還在進行」（v5 I-m2 同一類；O-M1 修法第 4 點要求的測試，v9 §6 沒有列）。
- **證據**：§3.1 擁有權表「session 佔用與 hold（新頁面）｜多台迴圈 / 檢查網路頁」——一個資源兩個寫入者；§2.4「離開時放佔用」與 §2.5「離開時釋放」；lease.dart:60-90。
- **修法**：佔用與 hold 只有一個擁有者：拿到它的那個流程物件（多台迴圈，或從首頁 / 4.1 / 節點頁直接開的檢查網路頁）。檢查網路頁收到借用的佔用時**不釋放**，返回時交回；只有自己 acquire 的才釋放。從結果頁 / 檢查網路頁按「建立網路」：先由擁有者釋放（或在同一佔用下直接開建立，二擇一寫明），再開 4.1。測試：結果頁 → 檢查網路 → 返回 →「再試這一台」成功（改壞 = 檢查網路頁照樣釋放 → `NoLease` → FAIL）；結果頁 →「建立網路」→ 開始 不出現「另一個操作還在進行」（改壞 = 不先釋放 → FAIL）。

## MINOR

1. **建立後自動檢查一次：和舊控制台不同，沒寫進 §4；觸發條件與時間沒寫完。** 舊控制台 `_makeNetwork` 只顯示回答、不自動確認（nodes.dart:476-490，`_makeUnclear` = 「稍後在這台按『檢查網路』」nodes.dart:50）。v9 照設計 §5.4（329-app-uiux.md:738）做是可以的，但它是「和舊控制台不同」，§4 要列（不然實作者照「行為與句子和舊控制台相同」§2.3 會漏掉或做兩套）。另外要寫：
   - 只有**這次建立有過 `PersistNet`**（拿得到 `rel`，owner.rs:427-431）而回答不是 `[NET_MADE]` 才自動檢查；`PersistNet` 之前就被拒（金鑰、`這次連線沒有驗證過節點身分`、Rust 的 `Err(String)`）→ 沒有 `rel` 可確認，直接停、顯示 Rust 的句子。
   - 時間：設計寫 60 s；舊 `_confirmNetwork` 的 `_ask` 用預設 15 s（nodes.dart:512、:1245）。寫明是 `loginFor` 60 s + confirm 的等待各多少。
   - 測試：建立被 Rust 拒絕（沒有 PersistNet）→ confirm 次數 = 0；改壞 = 一律自動檢查 → FAIL。

2. **`sendUpdateFor` 的參數與結果沒寫。** 舊控制台是 `_sendUpdateFor(n.rel, member: false, confirm: false)`（nodes.dart:668）；預設 `confirm: true` 會彈「包都交給隊員了嗎？」對話框（nodes.dart:1567-1572），在迴圈裡不該出現。§2.3 / §2.5 只寫 `sendUpdateFor(rel)`。另外 P m2 的後半（送新密碼失敗或結果不明時，這一台在結果頁算什麼）v9 沒回答：照 Rust / 舊控制台的句子（`_sendUnclear` nodes.dart:55）顯示並問繼續 / 停，寫進 §2.5。測試：`send_update=true` → `requestSendUpdate(member:false)` 一次、沒有對話框；改壞 = `confirm:true` → 測試等不到 → FAIL。

3. **檢查網路頁的對象用名稱比對，可以改成精確比對；對錯台時 Rust 的句子會叫人再建立。** 對錯台不寫紀錄（netrec.rs:511-516），但未加入網路的那台回 `NoChange(NotApplied)`，句子是「沒有套用（或已還原），可以再建立一次同一個網路」（owner.rs:478、:490），頁面接著給「建立網路」→ 使用者會在**錯的那台**建第二個網路。pending 建立者的 `MemberView` 已有 `creator` 與 `dacHash`（owner.rs:110-121），`node/` 紀錄 → dac hash 已有現成的 Rust 函式（rekey.rs:109-114 `remove_own_nodes`）。改成 `dacHash` 比對，對不到才讓人選；名稱 `node-<last4>`（owner.rs:1079）留作顯示。另外：手機有**多筆** pending net（每次再建立都是新 net_id，owner.rs:1067-1089）時選哪一筆沒寫——舊控制台 `_pickNet` 會問（nodes.dart:1242）；寫明（例如新的先，或讓人選）。

4. **「放棄這次加入」在 4.1 沒有佔用。** 4.1 不拿佔用（§3.2），`RecordWriter` 沒有佔用時拒絕（§5、record_writer.dart:27-33）→ 照 v9 寫法這顆按鈕永遠失敗。舊控制台是 `_holding` + `_underLease`（nodes.dart:1248、:1288）。寫明：按下時拿一個短的 session 佔用、寫完就放（或由誰持有）。另外舊控制台 dev 版有「排除這台（換密碼）」分支（nodes.dart:1279-1283 → `_remove`），寫明複製或不複製（不複製 → D 項，dev 版仍走舊控制台）。上層設計自己兩處說法不同（§5.1 :698「同一頁」vs :784「在開發者選項」），計畫選了 :698，寫一句。

5. **O m4 後半沒處理：`close()` 時還在跑的 persist 步驟。** `ask` 逾時時 `FrameInbox` 的處理者可能正在 seal / `writeCas`；§2.2 的 `close()` 順序是「取消監聽 → 取消訂閱 → `await link.close()` → dispose session」，沒有等進行中的處理者。§9 把 O m4 對到「建立者與 rel」，只回答了前半。寫明 `close()` 先等進行中的步驟結束（它會被佔用或 session 擋下）再 dispose，並加測試（慢的 `writeCas` + 逾時 → 不出現 dispose 後呼叫 `netPersisted`）。

6. **頁面消失「立刻放 hold」要在當前請求的 `lease.run` 結束之後。** `pageGone` 在 `_busy == 0` 時立刻 `release()`（lease.dart:73-78）。若當前請求不是包在 `lease.run` 裡、hold 又先放掉，寫入時 `RecordWriter` 拒絕 → `PersistFailed{applied:true}`（owner.rs 的「節點已套用，手機紀錄沒存好」）。寫明「請求都在 `lease.run` 內；hold 在請求結束後才放」，T-M1(g) 斷言頁面消失後那一次 persist 成功、`unsavedTodos` 空（改壞 = 消失時直接放 hold → FAIL）。

7. **生命週期表缺檢查網路頁；§3.2 的「首頁待辦」不存在。** §3.2 只寫多台迴圈。檢查網路頁的開始 / 頁面消失 / 藍牙權限金鑰 / 佔用收回 / 關螢幕各補一列（它的 `loginFor` 最多 60 s，但沒有 `keepScreenOn`，§3.1 也沒列它）。§3.2「紀錄停在 pending → 首頁待辦與『檢查網路』」：§2.6 只有 joining 的待辦（P-M2 已指出，v9 沒改這一列）——改成實際路徑（第 6 列「加入網路」→ 4.1 的 pending 句子 →「檢查網路」；或節點頁「網路」分組的「檢查網路」，設計 §5.5 :755），並把節點頁列進檢查網路頁的入口。

8. **節點頁無條件的次要「建立網路」是和上層設計不同的地方，沒進 §4。** 設計 §5.5 節點頁網路分組只有「加入網路 / 檢查網路」（329-app-uiux.md:755），§5.1 第 6 列只在沒有 net 紀錄時給「建立網路」（:673）。v9 §2.4 對所有還沒加入網路的節點都給——和舊控制台相同（nodes.dart:1728-1731 只看 `logged`），但手機已有已建立的網路時，按錯會把新節點建成另一個網路。建議加 D6，並把條件定成和 4.1 一樣（手機沒有已建立的 net 時才給；這是 PR 2 第 6 列已經在用的值，不是新規則）。

9. **零碎**：
   - P m6 後半：`NetIndex` 算完是「只有 mnet」時，4.1 要轉去舊控制台（D3），不能顯示 nodes.dart:612-614 那句「不能再加節點…舊節點要重燒」。
   - P m8 後半：離開 4.1 回到 `Page.node` 時連 node 參數一起還原（core.dart:186-201）。
   - §2.4 引用 owner.rs:568 是空行；`Pre::NotApplied` 的句子在 owner.rs:506。4.1 自己顯示「同一句話」時從 Rust 取，不在 Dart 複製字串。
   - O m2 的紀錄遮罩：§6 第 4 步補一條輸出斷言（紀錄行不含完整 net id）。

## v8 發現的對應（§9）

| 項目 | 結果 |
|---|---|
| O-M1 檢查網路頁 / pending 入口 | ⚠️ 頁面與對象有了；佔用重用的擁有權 → M1；入口與待辦 → m7；對象 → m3 |
| O-M2 送新密碼 | ⚠️ 有了；參數與結果 → m2 |
| O-M3 和設計不同處 | ✅ D5、A18（§4、§7）；自動檢查改照設計，但變成和舊控制台不同 → m1 |
| P-M1 `clearNotY` | ✅ §2.1；core.dart:628-633 已支援；T-L18 |
| P-M2 pending 時「建立網路」 | ✅ 4.1 與節點頁；節點頁的條件 → m8 |
| O m / P m `[JOINED]` | ✅ P8 只看加入請求的回答（owner.rs:514 vs :589-590） |
| O m / P m 頁面消失 | ✅ 方向；順序 → m6 |
| O m `NetIndex` 紀錄 | ✅ §2.6；缺測試 → m9 |
| O m / P m 建立者與 `rel` | ⚠️ 建立者 / `rel` 有了；O m4 的進行中寫入 → m5 |
| P m 放棄這次加入 | ⚠️ 有了；佔用 → m4 |
| P m 計算中 | ⚠️ 有了；mnet-only → m9 |

## 安全（新部分）

- 沒有佔用：`loginFor` 比對登記表、`BleGate` / `RecordWriter` 拒絕 → fail-closed ✅（§5；record_writer.dart:27-33）。M1 的錯誤方向是「該做的做不了」，不是越權。
- 惡意廣播（`loginFor` 期間）：8 s msg2 預算、`loginOutcome` 不種「是 Y」——沿用 v8 已驗的；本輪沒有新輸入面。
- 檢查網路頁的對象來自手機自己封存的紀錄，不是對方能控制的；對錯台不寫（netrec.rs:511-516）。剩下的是 m3 的「錯誤引導」。
- 秘密：檢查網路與送新密碼只顯示 Rust 句子（owner.rs:434-436 註解：句子不含秘密）✅。

## 基準備註（不算發現）

- 舊的 pending 紀錄不會被清掉，再建立一次就多一筆（owner.rs:1067-1089）；會讓 m3 的多筆 pending 變成常見情況。屬 join2。
- Rust 對「還在設定中 / 不確定」與「沒有套用」都只給句子；新頁面照舊控制台一律給次要「建立網路」，在「還在設定中」時按下會多一筆 pending。屬基準行為，記錄。

## 驗證分類

### ✅ 已驗證（原始碼，c70de1a）
- nodes.dart:476-490（建立不自動確認）、:626-671（加入 → `_sendAfter` → `_sendUpdateFor(rel, member:false, confirm:false)` → `_watchLink`）、:1240-1246（`_confirmNetwork` 用 `_pickNet`、預設 15 s）、:1248-1293（`_forgetJoining` 用 `_holding` / `_underLease`、dev 的排除分支）、:1567-1572（`confirm` 對話框）、:1728-1737（「建立網路」只看 `logged`）。
- owner.rs:110-121（`MemberView.creator`、`dacHash`）、:427-431（`persist_step` 的 `rel`）、:447、:476-490、:498、:506、:514、:589-590、:1067-1089（建立名稱 `node-<last4>`、不看舊紀錄）、:1437-1439。
- netrec.rs:511-533（confirm 只升建立者、對錯台 `NoChange`）；core.dart:628-633（`clearNotY`）；lease.dart:46-90（`run` / `hold` / `pageGone` / `release`）；home_logic.dart:92-96。
- rekey.rs:109-114 `remove_own_nodes`：`node/` 紀錄 → (dac hash, device id)。

### ⚠️ 推論
- 從零到兩台的路徑、M1 的返回後 `NoLease`：照原始碼推，沒有跑。
- m6 的 `PersistFailed`：要看實作是否把請求包在 `lease.run` 裡，計畫沒寫。

### ❌ 沒做
- 沒跑測試、沒上真機；沒重驗 v1–v6 對 `loginFor` / 交接的發現。
