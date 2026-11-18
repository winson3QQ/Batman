# #329 補測 A — retest-p 報告（2026-11-17）

Worktree `C:/src/Batman-329ra`（`test/329-retest-a` @ 663bb5e），只新增 5 個 `retest_p_*` 測試檔，沒改 `app/lib`、沒改既有測試、沒有 commit。
負對照在 `C:/src/Batman-329ra-p`（detached HEAD）做，做完已 `worktree remove --force`。每次突變的 diff 與輸出：`scratchpad/b2/mut/M*.log`（摘要）與 `M*.log.full`（完整）。

## 新檔案
- `app/test/ui/retest_p_pr3_test.dart`（5 個測試）
- `app/test/flows/retest_p_console_close_test.dart`（1 個）
- `app/test/ui/retest_p_pr4_test.dart`（3 個）
- `app/test/ui/retest_p_uistate_lock_test.dart`（3 個）
- `app/test/ui/retest_p_layout_test.dart`（12 頁 × 12 組合 = 144 個 + 1 個「渲染的確實是那個畫板」）

## 逐項

### 1. PR 3 小修正 / 第三輪 MINOR — 全部新寫（✅ 每項負對照 FAIL）
| 項目 | 程式位置 | 測試 | 突變 | FAIL 行 |
|---|---|---|---|---|
| 結果頁重讀的 hold | net_pages.dart:741 | `retest-p PR3 結果頁重讀的 hold…` | `final h = _hold = widget.lease.hold()` → `final Cancel h = () {}` | `Expected: true / Actual: <false> / the reread holds the lease (the other rows wait)` |
| 取消狀態訂閱 ⚠️ | owner_console.dart:659 `_stateSub?.cancel()` | `retest-p PR3 取消狀態訂閱…`（flows 檔） | 刪掉 cancel | `Expected: false / Actual: <true> / closed: no subscription left on the link` |
| 收起「放棄這次加入」 | net_pages.dart:554 `!_forgotten` | `retest-p PR3 收起「放棄這次加入」…` | 拿掉 `&& !_forgotten` | `Expected: no matching candidates / Actual: …Found 1 widget with type "TextButton"…` |
| 「網路已經不在」一行 | net_pages.dart:280-285 | `retest-p PR3 「網路已經不在」…` | 刪掉整個 `if (!_makes && rel == null) {…}` | `Expected: no matching candidates / Actual: …Found 1 widget with type "NetRunPage"` |
| `dc ??=` | net_pages.dart:691 | `retest-p PR3 dc ??=…` | `dc ??= _open = c` → `dc = _open = c` | `Expected: exactly one matching candidate / Actual: …Found 0 widgets with type "NetRunPage" / the run page is never popped by a closed question` |
| `_appFlow` onLost | net_pages.dart:627-628 | `retest-p PR3 _appFlow onLost…` | 拿掉 `onLost: lost` | `Expected: no matching candidates / Actual: …Found 1 widget with text "要改這台節點的國家嗎？"` |

說明與發現：
- ⚠️「取消訂閱」指哪一個是推論：#341 寫「state subscription cancelled on close」，我判斷是 `OwnerConsole._stateSub`（名稱與「close」都對得上）。`NetFormPage` 的 `a.link.changed` 訂閱（net_pages.dart:200）黑箱看不到：`_changed` 有 `mounted` 檢查，`NodeLink._changed` 是私有 controller，要測需要 lib 加一個測試用的監聽數接口；**沒寫**。
- `_stateSub` 在正式路徑上也是看不到的（`h.close()` 會關掉 GateLink 的 state controller，`_lost` 在 `_closed` 後直接 return）；所以測試用一條不會被關掉的假 GateLink，驗「關閉後沒有監聽者」。這是 white-box 的資源洩漏檢查，不是使用者可見行為。
- **發現（推翻 PR 3 的說法）**：PR 3 說「網路已經不在」那行在 C N-3 之後碰不到。PR 5 的隊員模式碰得到：`_key` 只比 `mnetIds`，不比那筆 mnet 還開不開得了；佔用下重讀時那筆打不開 → `still == null` → 這一行。測試就是走這條。
- `dc ??=` 的觸發：回答問題後、對話框退場動畫期間主題改變（深淺色切換）讓 builder 重跑，接著連線斷掉；拿掉 `??=` 會把**執行頁本身** pop 掉。
- `_appFlow` onLost 用真的 AppLink + 真的 NodeLink 登入（假藍牙節點、假 Rust session，HandoffProber 真跑），不給 `flow`，所以走 app 自己的 `_appFlow`。輸出有 `BMAPP owner console: link lost`。

### 2. PR 4 守衛 — 新寫三項（✅），I2 沒寫（❌，不是純測試缺口）
| 項目 | 程式位置 | 測試 | 突變 | FAIL 行 |
|---|---|---|---|---|
| 離開後 `link.refresh()` | more_pages.dart:271 | `retest-p PR4 link.refresh()…` | 刪掉 `a.link.refresh();` | `Expected: empty / Actual: {'AA:BB': Set:['0000000000000c4f2a7d2c']} / refresh() after the leave (core.refresh clears the memo)` |
| `openSwUpdate` 的 `context.mounted` | update_route.dart:29-32 | `retest-p PR4 context.mounted…` | 刪掉整個 `if (!context.mounted) {…}` | `Expected: null / Actual: FlutterError:<Looking up a deactivated widget's ancestor is unsafe.…` |
| `SwHolds.take` 的 done 檢查 | sw_holds.dart:15 | `retest-p PR4 SwHolds.take…` | `if (h != null && …kind != SwKind.done)` → `if (h != null)` | `Expected: true / Actual: <false> / a done update is replaced by a new one` |

- ⚠️ `refresh()` 用 `NodeLinkCore.notY` 被清空當觀察點（`core.refresh` 第一行就是 `notY.clear()`，core.dart:271）；測試裡 NodeLink 沒 start，所以「下一輪立刻開始」那一半沒驗。
- `context.mounted` 測試：在拿佔用的那段時間把呼叫頁拆掉，之後佔用才回來。斷言：沒有例外、佔用已釋放、沒有建立更新、沒有推更新頁。
- ❌ **I2（`console_paths.dart` 設定 / 離開列）沒寫**：這不是純測試缺口。PR 4 計畫 `docs/design/329-pr4-plan.md:372` 寫明兩個控制台的行為**本來就不同**（舊控制台的設定按鈕不帶 unclear 句，nodes.dart:1694、:1714），所以不能放進「兩邊都要一樣」的共用表；新控制台這邊已由 `test/flows/owner_console_pr4_test.dart:183-269` 涵蓋。要補的話得先決定：讓舊控制台改成一樣（改 lib），或接受兩邊不同、把這項劃掉。PR 6 刪掉舊控制台後這張防漂移表也就沒有對象了。建議在 PR 6 一起劃掉。

### 3. 「UiState 只流向顯示」測試鎖 — 新寫（✅ 三個突變都 FAIL），附一個發現
差分黑箱：同樣的節點、讀取結果與紀錄，一次用空的 UiState、一次用每個欄位都不同的 UiState（暱稱排序相反、上次狀態相反、讀取時間一個在未來一個很久以前），比對使用者能做的事：每顆按鈕（文字、開或關）、圖示按鈕、有 key 的列、動作指向哪一台、勾了哪幾台、執行開在哪幾台。歡迎頁 / 首頁提示兩個旗標兩邊相同（它們照設計決定顯示哪一頁 / 卡）。
| 測試 | 突變（模擬「拿 UiState 做決定」） | FAIL 行 |
|---|---|---|
| `retest-p UiState lock: home…` | home_page.dart:256 的節點順序改成照暱稱排 | `Expected: '…1111' / Actual: '…2222' / UiState never decides which node the action is about` |
| `retest-p UiState lock: node page…` | node_page.dart `_network` 的 `join` 加 `&& ui.nodes[id]?.look != 'bad'` | `Expected: [ 'button 重新整理:true', 'key node-join', …`（實際少了 node-join） |
| `retest-p UiState lock: 4.1…` | net_pages.dart `_tickOnce` 加 `&& ui.nodes[id]?.look != 'bad'` | `Expected: Set:[…1111, …2222] / Actual: Set:[…2222] / UiState never decides which nodes are ticked` |

- 第一次跑首頁突變**沒有 FAIL**（`+1: All tests passed!`）：我原本挑的暱稱「乙隊 B / 甲隊 A」用 Unicode 排序並沒有反過來（乙 U+4E59 < 甲 U+7532）。改成「B 隊 / A 隊」後才真的反過來，再跑就 FAIL（上表）。這是我自己的錯，已修正。
- ⚠️ **發現：設計 §4.6 與程式不一致**。4.1 的節點清單照暱稱排序（net_pages.dart:209 `_ids`），建立網路時預設由「清單第一台」建立（code review D M-1 刻意這樣做，讓畫面上標「由這台建立網路」的就是真的建立的那台）。所以**暱稱（UiState）會決定預設由哪一台建立網路、各台加入的順序**。我在 scratch 量過：空 UiState → `NetRunPage.ids = [...1111, ...2222]`；有暱稱 → `[...2222, ...1111]`。畫面上標得出來、使用者按「開始」前看得到，所以不是隱藏的決定；但跟「沒有任何決定讀它」的字面不符。我的測試鎖只比「集合」（勾了哪些、開在哪些），**沒有鎖住順序 / 建立者**，否則現在的程式會 FAIL。要不要改設計文字或程式由主 agent / 使用者決定。

### 4. T-C2 沒渲染的頁面 — 新寫（✅），每頁都有負對照
`retest_p_layout_test.dart` 用 layout_test 的 T-C2 檢查原樣（{360×640, 412×915} × {1.0, 1.3, 2.0} × {淺, 深}；沒有 overflow、tap target、文字對比、最多一顆主要按鈕、退役字詞；`retired` 直接 import 自 layout_test）。新加的 12 頁：
1.1 啟動畫面（`StartupCheck`，平台第一個問題不回）；2.4 金鑰不是硬體；2.4 金鑰讀不到（有「再試一次」）；2.4 技術資訊展開；歡迎第 2 頁；歡迎第 3 頁；移除對話框；更多 → 技術資訊展開（長的技術行）；長句子：首頁一台有問題（24 字暱稱 + 長 Rust 句）；長句子：首頁還沒讀到；長句子：節點頁（長句、長警告、lagNote、未完成變更）；長句子：24 字暱稱的移除對話框。
另加一個測試確認每一頁真的是那個畫板（否則一頁沒打開也會全過）。

| 突變 | 打到的頁 | 結果 |
|---|---|---|
| M13 main.dart 啟動列的字串加長三倍 | 1.1 | 10/12 FAIL：`A RenderFlex overflowed by 51 pixels on the right.`（1.0 倍的兩組合放得下） |
| M14 main.dart 2.4 節點清單改放到 `BatRow.right`（不換行） | 2.4 三頁 | 32/36 FAIL：`A RenderFlex overflowed by 99 pixels on the right.` 等 |
| M15 main.dart 2.4 技術資訊改成 `Row(children:[Text])` | 2.4 技術資訊展開 | 12/12 FAIL：`overflowed by 1888 pixels` / `no overflow after the user's step` |
| M16 intro_pages.dart 標題包進 Row | 歡迎 2、3 | 8/24 FAIL（2.0 倍全部）：`overflowed by 49 / 199 / 251 pixels` |
| M17 more_pages.dart 對話框內文顏色改 `t.line` | 移除對話框 | 12/12 FAIL：`Expected contrast ratio of at least 4.5 but found 1.48 for a font size of 16.0.` |
| M18 more_pages.dart 技術資訊包進 Row | 更多 → 技術資訊 | 12/12 FAIL：`overflowed by 471 pixels` |
| M19 widgets.dart StatusHero 文字區 `Expanded` → `SizedBox` | 長句子三頁 | 28/36 FAIL（首頁一台有問題 12、節點頁 12、首頁還沒讀到 4）：`overflowed by 1750 pixels` |
| M21 more_pages.dart 對話框標題包進 Row | 長句子：移除對話框 | 12/12 FAIL：`overflowed by 380 pixels` |
| M20 intro_pages.dart「下一步」不翻頁 | 畫板身分測試 | FAIL：`Found 0 widgets with text "開始之前，請準備三樣東西"`（這個突變下歡迎 2 / 3 的版面測試本身會全過，所以需要身分測試） |

另外有一個我自己寫壞、已丟掉的突變（M18 第一版：`softWrap: false`），它不會造成 overflow 例外，結果全過；換成上表的 M18 後才 FAIL。

## 最後在 `C:/src/Batman-329ra` 不突變全部跑一次（✅）
```
flutter test test/ui/retest_p_pr3_test.dart test/flows/retest_p_console_close_test.dart test/ui/retest_p_pr4_test.dart test/ui/retest_p_uistate_lock_test.dart test/ui/retest_p_layout_test.dart
00:07 +157: All tests passed!
flutter analyze（這 5 個檔）: No issues found!
```
完整輸出：`scratchpad/b2/retest-p-final.log`。157 = 5 + 1 + 3 + 3 + 145。

## 沒做 / 限制
- ❌ I2：見第 2 節（要先做決定，不是純測試）。
- ❌ `NetFormPage` 的 `a.link.changed` 取消訂閱：黑箱看不到，要 lib 給測試接口。
- ⚠️ 4.1 的建立者 / 順序由暱稱決定：測試鎖沒有涵蓋，見第 3 節。
- ⚠️ `refresh()` 只驗了清 memo，沒驗「立刻開一輪」（測試裡 NodeLink 沒 start）。
- 全套（整個 `flutter test`）沒跑，只跑這 5 個新檔。
