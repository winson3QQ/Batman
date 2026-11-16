# #329 PR 3 程式碼審查第三輪（窄範圍）— CR-E

- 範圍：`git diff 1bf9ae7..4460d0f`（c26e0bd、4460d0f），只看修 C / D 第二輪報告的部分。基準（第一輪以前已審過的行為）不重審。
- 方法：逐條讀碼；在 repo 的拷貝 `C:/Users/yello/AppData/Local/Temp/cre329/app`（不含 .git）做改壞對照與探針；repo 本身只跑測試與 analyzer。手機、adb、節點都沒碰。

**判定：APPROVE-WITH-CHANGES**（0 BLOCKER、0 MAJOR、3 MINOR）

## 1. 全套測試與 analyzer（原 repo，4460d0f）

```
flutter test --no-pub   -> 00:28 +853: All tests passed!     (845 + 本輪新增 8 條)
dart analyze lib test   -> info - test\member_ui_test.dart:4:8 ... unnecessary_import
                           1 issue found.                    (不在本 PR 的 diff)
```

## 2. 逐條：修好沒、改壞對照、有沒有帶出新洞

改壞對照都在拷貝裡做，每次從 `lib.orig` 還原；跑的是 net_pages_test / app_link_console_test / net_run_test / owner_console_test 四檔（基準 `+88: All tests passed!`）。

| 發現 | 修正位置 | 改壞對照（拷貝） | 結果 |
|---|---|---|---|
| D M-1 建立者順序 | net_pages.dart:246 `_ids.where(_ticked.contains)` | MUT-DM1 改回 `_ticked.where(states.containsKey)` | ✅ `D M-1 ... is the one that makes [E]` |
| D m-1 升級後仍顯示「沒有建立完成」 | net_pages.dart:613 | MUT-Dm1 刪掉該行 | ✅ `D m-1 ... no longer reads 「網路沒有建立完成」 [E]` |
| D m-2 / C N-1 兩個關法 | net_pages.dart:530-541（`_closeQ` + `identical` 守門）、:549、:556、:576-578 | MUT-CN1-guard 刪 `if (!identical(_open, c)) return;` | ✅ `C N-1 / D m-2 ... close the question once [E]` |
| 同上，`dc ??= _open = c` | net_pages.dart:556 | MUT-CN1-once 改回 `dc = _open = c` | ❌ 四檔全過（`+88: All tests passed!`）→ m-2 |
| C N-2 第二個 close 不等 | owner_console.dart:482-486 | MUT-CN2 改回 `if (_closed) return; await _close();` | ✅ `C N-2: a second close waits for the first [E]` |
| C N-3 選的網路不見 | net_pages.dart:216-222 | MUT-CN3 改回 `?? (length == 1 ? first : null)` | ✅ `C N-3 ... no 開始 [E]` |
| C N-4 已加入、送新密碼前就丟例外 | net_run.dart:204-205 | MUT-CN4 刪該行 | ✅ `C N-4 ... 「已加入，新密碼沒有送出」 [E]` |
| C N-5 / D m-3 三個接線沒測試 | 測試：app_link_console_test（onLost）、net_pages_test（檢查頁 dispose）、N-3（m-5 句子由 開始 停用取代） | MUT-onLost（flowDeps 傳 `onLost: null`）、MUT-checkGone（刪 net_pages.dart:731 `_run?.pageGone()`） | ✅ 兩個都 `[E]` |

（MUT-DM1 也讓下一條 N-3 測試失敗——沿用 C 指出的測試間沒有隔離，不影響判斷。）

### 指定要查的點

- `_closeQ`：按鈕與 radio 同一刻 → 先到的把 `_open` 清掉並 pop，後到的 `identical(_open, c)` 不成立就返回（:539）。順序反過來也一樣。前一個對話框退場中、下一個已開時，前一個的按鈕或監聽呼叫 `_closeQ(舊 c)` 也被擋（舊碼 `Navigator.pop(c)` 會 pop 掉頂端的新對話框——這是順帶修好的）。✅ 讀碼 + 測試。
- 對話框退場中重建：builder 拿到的 `c` 是 `DialogRoute` 裡 `Builder(builder: builder)` 的 context（flutter `material/dialog.dart:1843`），外層 `_page ??=` 快取（`widgets/routes.dart:1228`）、結構固定，所以重建拿到的是同一個 `c`。舊碼 `dc = _open = c` 會在 `_ask` 的 finally 清掉 `_open` 之後又設回去，下一次 onLost（`_one` finally 的 `c.close()` 一定會呼叫）就 pop 掉 NetRunPage。✅ 探針證實（見 m-2）；新碼 `dc ??=` 中 `_open = c` 只在第一次求值，修好。按鈕閉包拿的 `c` 與 `_open` 同一個（context 穩定），不會出現「按鈕關不掉」。
- `close() => _closing ??= _close()`：`_close` 的同步段先設 `_closed = true`（:486），所以 `_lost`（:316）立刻看到 `_closed`；`_lost` 本身不設 `_closed`，之後的 close 照舊跑完整流程（與修正前相同）。✅ 既有測試 `expect(rig.lost, 2, reason: 'idempotent')` 仍過。
- `_ask` 逾時路徑中開始的 close：`_close` 等 `_chain`（:499，上限 10 s），`_ask` 也等 `_chain`（:365，上限 10 s）；`_chain` 裡沒有任何步驟等 `close()`（`grep close()` owner_console.dart 只有 :502 `h.close()`）。國家問題卡在 chain 裡時，`_close` 先同步呼叫 onLost（:488）把對話框當「不要」關掉，chain 自己往下走並看到 `_closed`。不會互等；最壞 10 s 後放行。✅ 讀碼。
- `_picked` 回 null：4.1 的 radio 群組 `groupValue` 變 null、其他網路還列著，按一下就重新選（`onChanged: _pick = v`，:368）；「開始」只在 `picked == null` 時停用（:432-433）。不會卡住。✅ 讀碼 + N-3 測試。⚠️ 小變化：`widget.todo` 的網路若不在清單上，以前會退回唯一那個網路，現在要手點——這正是 N-3 要的。
- 建立者順序改用 `_ids`：`_ids` 取自 `a.link.core.states.keys`，期間被移除的節點不在 `_ids`，`ticked.length != _ticked.length` 照樣成立 → 「紀錄剛剛變了」。與修正前（`_ticked.where(states.containsKey)`）語意相同。✅ 讀碼。
- 升級後清 `makeFailed`：`run.stopped` 只在 net_run.dart:142（`run()` 迴圈，只在 initState 跑一次，:487）、:231（`_failed`）與頁面文字 :640 被讀；「還沒做」的列沒有按鈕（`canRetry` / `canCheck` 都要 `failed`，net_run.dart:79-80），`retry` 自己會把 `stopped` 設成 none。不會重新啟用任何東西。✅ 讀碼。帶出 m-1（只是文字）。

## 3. 發現（全部 MINOR）

**m-1 建立網路升級成功後，其他「還沒做」的台沒有任何提示**
- 情境：make 第一台結果不明 → `makeFailed`，其他台「還沒做」→ 在結果列按「檢查網路」升級成功 → `stopped = none`（:613）。畫面：`有節點沒有完成`、`next: null`，其他台只寫「還沒做」，沒有按鈕、也沒說要回 4.1 加入。
- 證據：net_pages.dart:637-646（`StopWhy.none` → `next: null`）；計畫 329-pr3-plan.md:136「停下之後還沒做的台不在這裡接著做（重開 4.1…）」。修正前的文字錯（說沒建立），修正後是沒有文字。⚠️ 只讀碼。
- 修法：清 `makeFailed` 時，若還有 `notDone` 的列，給一句「網路已建立；其他節點按「完成」後再加入」（或另設 StopWhy）；在 D m-1 那條 widget 測試補斷言。

**m-2 `dc ??=`（退場中重建不再設回 `_open`）沒有測試擋**
- 證據：MUT-CN1-once（`dc = _open = c`）→ 四檔 `+88: All tests passed!`。探針（拷貝 `cre329/npt.probe`，測試名 `PROBE rebuild during exit`）：問題開著 → `lostNow()` → pump → 退場 20 ms 時以深色主題重 pump 同一個 `NetRunPage` → `lostNow()` 再一次：
  - 新碼：`+1: All tests passed!`
  - 舊碼 `dc = _open = c`：`Found 0 widgets with type "NetRunPage"` / `the second close never pops the run page` → FAIL。
- 現場：主題 / 字級在 150 ms 退場中變動才會發生，機率低，但後果是結果頁被 pop 掉（且 PopScope 擋不住程式 pop）。
- 修法：把探針收進 net_pages_test.dart。

**m-3 N-4 的條件比原意寬**
- `if (r.joined && r.note.isEmpty)`（net_run.dart:205）對「加入後任何丟例外」都寫「新密碼沒有送出」，包括不用送密碼的 `pollLink` 路徑（linkCheck）與 `_one` finally 的 `c.close()`。⚠️ 讀碼推論：`linkCheck` 經 `_ask` 已接住 `req` 的例外、`_close` 內部都 try，現場大概走不到；不影響行為判斷。修法（可選）：只在 `sendUpdateFor` 前後設旗標，或在 `_join` 的 send 分支自己 try/catch 寫 note。

## 4. 安全
本輪沒有新增輸入面；`_closeQ` 只在同一行程內被按鈕 / 監聽 / onLost 呼叫；`_closing` 是私有欄位。被入侵的節點在國家問題開著時斷線：onLost 只把問題當「不要」關一次，不會 pop 掉結果頁（N-1 測試 + 探針）。

## 5. 證據分類
- ✅ 全套 853、analyzer 1 info（不在 diff）；9 個改壞對照中 8 個被擋、1 個存活（m-2）；退場重建探針新碼 PASS / 舊碼 FAIL；其餘結論附 file:line。
- ⚠️ m-1、m-3 只讀碼；`_ask` 逾時與 close 不互等是讀碼推論（10 s 上限有程式碼依據）；context 穩定性靠 flutter 原始碼行號 + 探針間接證明。
- ❌ 沒碰真機 / adb / 節點；沒跑 `cargo test`；commit 測試數（C N-6 / D m-4）不在本輪範圍、沒查。
