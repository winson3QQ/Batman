# #329 PR 3 程式碼審查第二輪 — CR-C

（審查者的 Write 被權限檢查故障擋下；本檔由作者照審查者交回訊息的原文存檔。拷貝在 C:/Users/yello/AppData/Local/Temp/cr329c。）

判定：**APPROVE-WITH-CHANGES**（0 BLOCKER、0 MAJOR、6 MINOR）。第一輪 5 個 MAJOR（A M-1 / B M1–M4）都已修好，每個都有一條拿掉修正就會失敗的測試。

## 1. 全套測試與 analyzer（原 repo 1bf9ae7）
- ✅ `flutter test --no-pub` → `00:27 +845: All tests passed!`
- ✅ `dart analyze lib test` → 只有 `test\member_ui_test.dart:4:8 unnecessary_import`（不在本 PR 的 diff）
- ⚠️ commit 訊息寫 860，實測 845。

## 2. 第一輪發現逐條（改壞對照在拷貝裡做，每個跑完還原）
- A M-1 / B M2 節點頁「建立網路」：✅ node_page.dart:101-109、:137；MUT-2 → wiring_test FAIL（⚠️ 測試直接呼叫 pop(goMake)）。
- A m-1 / B m2 例外卡「進行中」：⚠️ 大致修好（net_run.dart:190-205、:357-359；MUT-7 → 兩條測試 FAIL），子情境見 N-4。
- A m-2 頁面消失時 linkCheck：✅ net_run.dart:119-125、:311-312；MUT-8 → FAIL；副作用見 N-2。
- A m-3 / B m3 CheckRun pageGone：流程 ✅（MUT-9 FAIL）；頁面接線 ❌ 沒測試（MUT-15：拿掉 net_pages.dart:719 → 全套 845 PASS）。
- A m-4：M03 ✅（MUT-12 FAIL）；M19 ✅（MUT-13 FAIL）；AG-M1 ✅（app_link_console_test.dart）。
- A m-5 選的網路不見：程式 ✅（:260），測試 ❌（MUT-17 → 全套 PASS）。
- A m-6 死欄位：✅ 已刪。
- B M1 再加一台：✅ add_pages.dart:54-56；MUT-1 FAIL。
- B M3 預選錯台：✅ net_pages.dart:287-290；MUT-3 FAIL。
- B M4 兩個對話框：⚠️ 部分——`_dismiss`（MUT-4 FAIL）、OwnerConsole `_lost` / `close` 的 onLost（MUT-14 / MUT-16 FAIL）；flowDeps 傳 onLost 的接線（net_pages.dart:62-63）MUT-5 → 全套 PASS；另見 N-1。
- B m1 問前先關：✅ net_run.dart:236；MUT-6 FAIL。
- B m4 `_seen` 跟 NetIndex：✅ :173-178；MUT-10 FAIL；帶出 N-3。
- B m5 拿掉手選規則：✅ net_run.dart:341-343；非建立者拿不到「建立網路」（`answered` 需要 `mine` 非空，:385-390）。
- B m6 成員被預勾：✅ :200-210；MUT-11 FAIL；pending 建立者 device_id 為空（owner.rs:82-84、:2195），沒有回歸。
- B m7 / m8 / m9：程式 ✅，沒有測試（commit 已聲明；MUT-18 → 全套 PASS）。

改壞對照 18 個：14 抓到、4 存活（MUT-5、15、17、18）。MUT-4、MUT-10 也讓 net_pages_test 下一條測試失敗（測試之間沒有隔離）。

## 3. 指定要查的新洞
- 連線關兩次：✅ 無害（`close()` 冪等，owner_console.dart:482），但第二個呼叫者不等第一個（N-2）。
- 再試這一台與自動檢查：✅ 沒壞。
- `_one` 的 catch-all：✅ 不吞佔用不見或頁面消失（`_blockedStop`，:172-185）；⚠️ PlatformException 一律當 keys 停但沒呼叫 keyErrorToRadio，可接受（下一次 loginFor 的 KeyAbilities 會擋，計畫 §2.9:189）。
- linkCheck 中頁面消失：✅。
- close() 叫 onLost 會不會收掉「繼續 / 停」：✅ 不會；兩個收法會互踩（N-1）。
- `_seen`：⚠️ 有一條路徑蓋掉真的變化（N-3）。
- 節點頁 await：✅；NickPage push：✅。

## 4. 發現（全部 MINOR）
- **N-1**（⚠️ 只讀碼）同一個對話框兩個收法（`_ask` 的 `dc`、`_dismiss` 的 `_open`）都只看 `c.mounted`；同一批 microtask 時第二次 pop 會打到 NetRunPage（navigator.dart:3156-3161、:3524-3527、:5652）。修法：統一一個 helper，pop 前 `identical(_open, c)`；負對照：同一 microtask 觸發 `radio(off)` 與 `lost()`。
- **N-2** `close()` 冪等但第二個呼叫者不等：頁面在 linkCheck 中消失 → `unawaited(close())` → `_one` finally 的 `await c.close()` 立刻回 → 佔用先放。違反 §2.8:174。修法：`_closing ??= _close()`。
- **N-3**（⚠️ 只讀碼）使用者選的網路 B 不見（打不開）→ `_seen` 換成新快照 → `_picked` 退回唯一的 A → 開始時 `_key` 一致 → 加入 A。修法：`_pick` 有值但找不到時回 null。
- **N-4** `[JOINED]` 之後 `sendUpdateFor` 的 readRecord / publicKeys 丟例外 → note 空的；計畫 §2.9:191 要「已加入，新密碼沒有送出」。
- **N-5** 三個新接線沒有測試（MUT-5 onLost、MUT-15 檢查頁 dispose、MUT-17 m-5 句子）。
- **N-6** commit 的 860 與實測 845 不符。

## 5. 安全
沒有新增輸入面；`[REQ_FAIL]` 只顯示 code / runtimeType；被入侵的節點：判斷仍只看 Rust 回答開頭與 nodeDacHash。

## 6. 證據分類
- ✅ 全套 845、analyzer、18 個改壞對照（14 / 4）、讀碼結論附 file:line。
- ⚠️ N-1、N-3（沒跑探針）、N-2 的影響範圍、860 vs 845 的原因。
- ❌ N-1 / N-3 探針、真機、`cargo test`、M21 沒重做；報告檔本身沒寫成。
