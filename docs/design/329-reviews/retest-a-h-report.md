# #329 re-test H 回報：T-C4c / T-H2 / T-H3 / T-H5（2026-11-17）

Worktree `C:/src/Batman-329ra` @ 663bb5e（branch `test/329-retest-a`），沒有 commit。新增 3 個未追蹤檔：
- `app/test/nodelink/retest_h_core_test.dart`（3 個測試）
- `app/test/nodelink/retest_h_unseal_test.dart`（2 個測試）
- `app/test/ui/retest_h_home_test.dart`（5 個測試）

沒改 `app/lib/`、沒改既有測試。負向對照都在暫時 worktree `C:/src/Batman-329ra-h`（`--detach HEAD`）裡做，做完已經 `worktree remove --force` 移除。

## T-C4c — ❌ 不改 lib 就寫不出來（需要先改 lib）
- 證據：Dart 端「顯示規則 2」（把句尾「（代碼 …）」搬到技術資訊）**沒有實作**。`lib/say.dart:5-8` 的 `screenText` 只拿掉開頭的 `[TAG] `。在 `lib/ui`、`lib/say.dart` 裡 grep「代碼」，0 筆。
- 在暫時 worktree 跑過探針 ✅：`screenText('[REQ_FAIL] 設定沒有成功：節點不接受這個值（代碼 2，原因 13）')` 輸出 `設定沒有成功：節點不接受這個值（代碼 2，原因 13）`。
- ⚠️ 從原始碼推論（沒有用 widget 跑）：設定頁 `settings_pages.dart:44-45` 直接顯示 `screenText(r.reply!.text)`，所以主畫面上會出現「（代碼」。
- 需要的 lib 改動：
  - 一個 Dart 函式，例如 `splitTech(line) -> (main, tech)`，把句尾的全形括號段（「（代碼 …）」「（CertRejected: …）」）切掉。
  - 每一個顯示 `screenText(...)` 的新畫面改成：主畫面用 `main`，技術資訊（收合）放 `tech`。
- 之後的測試：
  - `splitTech` 單元測試；
  - 至少一個畫面（例如設定頁的 REQ_FAIL）的 widget 測試：主畫面 `find.textContaining('（代碼')` 是 0，展開技術資訊後是 1。
  - 負向對照：拿掉拆分 → FAIL。

## T-H2 — 部分已有，缺的部分已補
| 案例 | 狀態 | 證據 |
|---|---|---|
| (a) 存檔的舊資料 → unk | 函式層已有；**新增 widget 層** | 已有：`pages_test.dart:333` T-U5（`nodeRowWords` 加 `prev` → `Look.unk`）。新增：`retest_h_home_test.dart` `T-H2(a): …`（真的 HomePage + UiState 存了 'ok' → NodeRow 是 unk，句子是「上次讀取 …，當時正常」，狀態區是 unk，沒有「一切正常」） |
| (b) 301 s 到期 | 已有 | `core5_test.dart:20`「R1 / T-H2(b)」（299 s 仍新鮮、301 s 不新鮮）；不新鮮的列是 unk 由 `home_logic_test.dart`「node rows」涵蓋。⚠️ 這次沒有重跑它的負向對照 |
| (c) | 設計已拿掉 | — |
| (d) 錯誤碼不是讀到 | prober 半段已有；**新增 core / 畫面半段**；「真的 OwnerSession」⚠️ 只有 Rust 測試 | 已有：`prober_test.dart:158`（row 2' 就算 fresh==true 也是 errorCode）。這次重跑了設計的對照（照 v5 改成 `!v.fresh ? errorCode : body`）→ FAIL，見下。Rust 端：`rust/bridge/src/api/owner.rs:2542` `status_page_rate_limit_keeps_the_earlier_read`（新 session 第一次 E_RATE → row 2'、fresh true）。新增：`retest_h_core_test.dart` 兩個 `T-H2(d): …`（讀到之後一整輪都是錯誤碼 → kind / view / readAt 不變、earlyDue null、50 s 內沒有握手；從沒讀到過 → unread + responded，列是 unk「有回應，還沒拿到狀態」，一輪後不變灰） |
| (e) 兩輪變灰、一輪不灰 | 已有 | `core_test.dart:195` |
| (f) 背景再回來仍會變灰；一輪錯誤碼下一輪本體不變灰 | 已有 | `core_test.dart:210`、`core_test.dart:182`（round-12 A-M2） |
| (f) 找不到的節點登入成功但回錯誤碼 → 不再是連不到 | **新增** | `retest_h_core_test.dart` `T-H2(f): …` |

⚠️ (d)「用**真的** `OwnerSession` 餵 EBusy」：Dart 測試全部用 `RustLib.initMock`，跑不到真的 Rust session。Rust 測試有 E_RATE（12）和 Err(3)，**沒有明確餵 EBusy 的案例**。要補的話是 Rust 測試，在我被允許改的範圍外。

## T-H3 — 部分已有，缺的部分已補
| 來源 | 狀態 | 證據 |
|---|---|---|
| claim-pending：有 `node/<id>` 時**不**出現 | **新增** | `retest_h_home_test.dart` `T-H3: claim-pending — no todo when node/<id> exists …` |
| claim-pending：非 devTrust 不出現 | 已有，另加一個直接案例 | `key_abilities_test.dart:469`；新增 `T-H3: claim-pending — not in a field build …` |
| 加入中 | 已有 | `pages_test.dart:450`（出現 / 消失） |
| mpend | 已有 | `home_team_test.dart:53/63` |
| SwHold | 已有 | `update_route_test.dart:206` T-U3 |
| 被收回的佔用（T-G3c）在首頁出現、按「知道了」後消失 | registry 層已有；**新增首頁 widget 層** | `review_pr1_test.dart:623`（900 s 收回、`unsavedTodos`）；新增 `T-H3 / T-G3(c): …`（真的 raw lease，pageGone，899 s 還在、900 s 後首頁出現，按「知道了」後消失） |
| 首頁的一輪前後待辦不變 | **新增** | `T-H3: a home round does not recompute the todos …`（3 次 changed 加上 15 s tick，`listPending` 呼叫數不變；從設定頁回來才重算） |

❌ 發現（需要先改 lib，沒寫成測試）：設計寫「待辦只在啟動與**佔用釋放後**重算」，但 `home_page.dart` 只在 initState、`_back`（從別頁回來）、`_addNode` 重算 claim-pending，**佔用釋放時不會重算**。
- ✅ 探針（暫時 worktree）：首頁顯示中，取得 raw lease 再釋放 → `PROBE listPending calls before=1 after=1`。
- ⚠️ 推論的現場影響（沒有實跑）：認領頁按返回、認領還在跑 → `_addNode` 在 pop 時就重算，這時 `node/<id>` 可能還沒寫，「上次新增節點沒有做完」會出現；認領完成、佔用釋放後也不會消失，要等下次換頁才消失。
- 要改的 lib：首頁訂閱 lease 釋放（例如加一個 `LeaseListener` 或 `reg.listeners`），釋放後呼叫 `_todos()`。

## T-H5 — 大部分缺，已補（用真的 AppLink 計數）
- 新增 `retest_h_unseal_test.dart`。用真的 `AppLink.create`（它自己的 NodeLink、SessionProber、hint 接線、NetIndex、LeaseRegistry），配上假藍牙、會計數的假 Rust API、假 Keystore。
- `T-H5: home rounds open 0 net / mnet records and list nothing; one node-page read opens exactly 1`：
  - dev build，手機知道該台的網路。
  - 首頁讀兩次：net / mnet 的 storeReadSealed 是 0、資料夾列表是 0、summary 是 0、Keystore open 恰好 2（只有節點紀錄）、`hints` 是空的。
  - 節點頁讀一次：恰好 `['net/aa']`，hint 有出現。
  - 回首頁：hint 清掉；再讀一次，net 讀取仍然只有那 1 筆。
- `T-H5: a lease release computes the network summary exactly once`：釋放前 summary 是 0，`acquire` 再 `release` 之後 summary 恰好 1、net 讀取恰好 1。
- 已有的部分：
  - `prober_hint_test.dart:114`（wanted=false → 不開紀錄）；
  - `:105`（wanted → 只開 net/aa）；
  - `:189/:209` R8（hint 只在該節點頁保留）；
  - `net_index_test.dart:171`（釋放 → 會重算，但沒有斷言「恰好一次」，也沒有測 AppLink 的接線）。

## 負向對照（都在暫時 worktree 跑，每一個都 FAIL；跑完把 lib 檔從原 worktree 複製回去，`diff -q` 確認一樣）
| 測試 | 改壞的東西 | FAIL 輸出 |
|---|---|---|
| T-H2(d) 讀到後錯誤碼 | core.dart:555 `Concl.unchanged` 加 `trigger.add(id)`（錯誤碼觸發提前再讀） | `Expected: null  Actual: <115000>`（earlyDue） |
| T-H2(d) 兩個案例 | core.dart:445 errorCode 設 `s.readAt = now` | `Expected: (Kind.read, green, 14000)  Actual: (Kind.read, green, 105000)`；`Expected: (Kind.unread, true, null)  Actual: (Kind.unread, true, 31000)` |
| T-H2(d) 兩個案例（設計的「上限改成 1 輪」） | core.dart:556 `s.same >= 2` 改成 `>= 1` | `Actual: (Kind.read, 2', 105000)`；`Actual: (Kind.read, true, 31000)` |
| T-H2(d) prober 半段（既有 prober_test:158，設計對照「照 v5 用 fresh==true 判定」） | prober.dart:157 改成 `!v.fresh ? errorCode : body` | `a status answer that is an error code (row 2') -> errorCode, not a read [E]  Expected: Res.errorCode  Actual: Res.body` |
| T-H2(f) 找不到 → 錯誤碼 | core.dart:550 那個 unreachable→unread 的 if 改成 `if (false)` | `Expected: null  Actual: Why:<Why.notFound>` |
| T-H2(a) | home_logic.dart:187 舊資料照 prev 的顏色（ok → Look.ok） | `Expected: Look.unk  Actual: Look.ok` |
| T-H3 node/<id>（**設計的對照**） | home_page.dart:163 `n = p.length`（拿掉「沒有 node/<id>」） | `Expected: no matching candidates  Actual: Found 1 widget with text "上次新增節點沒有做完"` |
| T-H3 field build | home_page.dart:160 `if (widget.devTrust)` 改成 `if (true)` | `Found 1 widget with text "上次新增節點沒有做完"` |
| T-H3 一輪不重算 | home_page.dart 的 `changed` listener 加 `_todos()` | `Expected: <1>  Actual: <4>` |
| T-H3 / T-G3(c) 知道了 | home_page.dart:321 不移除 `unsavedTodos` | `Found 1 widget with text "上一個操作可能沒有存完：新增節點"` |
| T-H5 首頁 0 筆（**設計的對照**「首頁每次讀狀態都列/開網路」） | app_link.dart:129 `wanted` 改成只看 `devTrust`（不看頁面） | `Expected: empty  Actual: ['net/aa', 'net/aa']  (reads: [node/…, net/aa, node/…, net/aa])` |
| T-H5 釋放後重算 | app_link.dart:185 拿掉 `reg.listeners.add(nets)` | `TimeoutException after 0:00:30 …`（從沒重算） |
| T-H5 恰好一次 | `reg.listeners.add(nets)` 加兩次 | `Expected: <1>  Actual: <2>` |

⚠️ T-H5 的對照跑完之後，我又對 `retest_h_unseal_test.dart` 做了兩個只影響 analyzer 的修正（多一個 `@override`、多一個 import），並把等待上限從 30 s 改成 20 s。測試邏輯沒變，**但沒有對修正後的版本重跑對照**。T-H2(b)、(e)、(f) 既有測試的對照，這次也沒有重跑。

## 最後在原 worktree（沒改壞）的通過輸出 ✅
```
flutter test test/ui/retest_h_home_test.dart test/nodelink/retest_h_core_test.dart test/nodelink/retest_h_unseal_test.dart
00:01 +10: All tests passed!
flutter analyze（三個檔）: No issues found!（unseal 修正後；home / core 在修正前跑過一次，只有 unseal 有 2 個 issue，已修）
flutter test test/nodelink/retest_h_unseal_test.dart（修正後）: 00:00 +2: All tests passed!
```
