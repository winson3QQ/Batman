# #329 PR 3 程式碼審查第三輪（窄範圍）— CR-F（現場走查）

- 範圍：`git diff 1bf9ae7..4460d0f`（c26e0bd、4460d0f），也就是 code-review-pr3-C.md / -D.md 的修正。head = 4460d0f。
- 方法：在 4460d0f 上照 (1)–(5) 五條現場路徑逐行讀碼。改壞對照和探針都在 scratchpad 的拷貝（`git archive 4460d0f app`）裡做，原 repo 只新增本檔。手機、adb、節點都沒碰。

**判定：APPROVE-WITH-CHANGES**（0 BLOCKER、0 MAJOR、4 MINOR）。C / D 提的修正都成立，8 個修正裡 8 個有測試擋（改壞就 FAIL）。剩下的是兩個測試缺口和兩個畫面上缺一句說明，都不會讓現場行為出錯。

## 全套測試與 analyzer（原 repo，4460d0f）
```
00:28 +852: C:/src/Batman-329pr3/app/test/ui/layout_test.dart: T-C2 permissions 412x915 ×2.0 dark
00:28 +853: All tests passed!
Analyzing lib, test...
   info - test\member_ui_test.dart:4:8 - The import of 'dart:typed_data' is unnecessary ... - unnecessary_import
1 issue found.
```
✅ 853 和 c26e0bd commit 訊息寫的數目一致（上一輪 860/845 不符的問題已經沒有）。analyzer 唯一的 info 不在本 PR 的 diff 裡。

## 改壞對照（拷貝裡做，每個做完都還原）
| # | 改壞內容 | 結果 |
|---|---|---|
| MA | D M-1：`ticked` 改回 `_ticked.where(states.containsKey)`（Set 的加入順序） | ✅ FAIL `code review D M-1` |
| MB | C N-1：`_closeQ` 拿掉 `identical(_open, c)` | ✅ FAIL `code review C N-1 / D m-2` |
| MC | `dc ??= _open = c` 改成 `dc = _open = c` | ⚠️ net_pages_test 17 個全 PASS（防禦用；畫面退場時的重建很難重現，見 m-4） |
| MD | C N-2：`close()` 改回 `if (_closed) return;` | ✅ FAIL `code review C N-2` |
| ME | C N-3：`_picked` 改回退到唯一網路 | ✅ FAIL `code review C N-3` |
| MF | C N-4：拿掉 `已加入，新密碼沒有送出` 這行 | ✅ FAIL net_run_test N-4 |
| MG | D m-1：拿掉 `makeFailed → none` | ✅ FAIL `code review D m-1` |
| MH | flowDeps 的 `onLost: onLost` 改成 null | ✅ FAIL `code review C N-5: flowDeps hands…` |
| MI | CheckNetPage dispose 拿掉 `_run?.pageGone()` | ✅ FAIL `code review C N-5 / D m-3` |
| MJ | `NetRunPage._appFlow`（net_pages.dart:491）不傳 `onLost: lost` | ❌ 全套 `+853: All tests passed!`（見 m-1） |

## 現場走查

### (1) 4.1 建立模式，勾兩台，勾的順序和名稱順序對調 — ✅
- 標示：`maker = _maker`（有勾才算）否則用 `ids.where(_ticked.contains).firstOrNull`（net_pages.dart:362-363），`ids = _ids` 照名稱排序（:192）。
- 實際：`ticked = _ids.where(_ticked.contains)`（:246），`order` 第一台 = 同一個 `_maker` 規則否則 `ticked.first`（:255-258）。兩邊用同一個排序、同一個規則，所以標示的那台就是建立的那台，其他台照清單順序加入。
- 名稱來源 `ui.nodes[id]?.nick ?? '節點 last4'`（home_page.dart:35），在 4.1 頁面裡不會改，所以從畫出畫面到按「開始」之間排序不會變。
- 證據：測試 D M-1（勾的順序 id→other，名稱 other 在前）在 MA 下 FAIL。探針 P1（勾的順序反過來，再把星號按到第二台）：`P1 marked=節點 7D2C` / `P1 runOrder=[0000000000000c4f2a7d2c, 0000000000000000001234]`，標示的那台排第一。
- ⚠️ 兩台暱稱完全一樣時，順序取決於 map 的插入順序（和 sort 的穩定性；32 台以內是插入排序）。畫面和開始用的是同一份輸入，所以兩邊一致。這點只讀碼，沒跑。

### (2) 國家問題開著時，藍牙關掉和連線斷掉同時發生；按「改」和斷線同時發生 — ✅（有一個一幀的窗口，m-3）
- 藍牙關掉加斷線：兩個來源（`a.link.changed` 的監聽 :548-551、`onLost` → `_dismiss` :530-533）都走 `_closeQ`，`_closeQ` 只關「還開著的那個」對話框（:537-541）。不管哪個先到，都只 pop 一次。MB 改壞後測試 FAIL。
- 按「改」加斷線：探針 P2 `yesThenLost` → `dialog now=0 runPage=1 answer=true`；`lostThenYes` → `now=0 runPage=1 answer=false`。兩種順序都只關一次，run 頁面還在。
- 答案是 true 時會不會送出：`askCountry` 回來後，owner_console.dart:260 會檢查 `_closed || !identical(_session, s)`；`_lost` 已經把 `_session` 設成 null（:319），所以 `countryConfirmed` 不會送到已經斷掉的連線上。✅ 讀碼。
- 如果按鍵的 microtask 比斷線事件先跑：frame 寫出去時失敗，走 `_onFrame` 的 catchError → `_endUnclear`（:178-181），也就是原本「結果不明」的路，這不是本 PR 新增的。

### (3) 連線檢查中關掉頁面 — ✅
- `pageGone`（net_run.dart:119-122）呼叫 `unawaited(_current?.close())`，這時 `_closing` 已經建立。`linkCheck` 的 `_stopWait` 讓等待立刻結束（owner_console.dart:452-463），迴圈看到 `_closed` 就 break。接著 `_join` 把列設成 ok（附註「連線狀態未知」），`_one` 的 finally 執行 `await c.close()`（net_run.dart:191-192），拿到的是同一個 `_closing` future（:482），所以會一直等到 `h.close()` 把連線關完才回來。然後 `_work` 的 whenComplete 才歸還 hold（net_pages.dart:503-508），佔用在這之後才放（dispose 已經呼叫過 `lease.pageGone()`）。
- 有沒有東西留下：`_stateSub` 已取消、inbox 已解除、session 是 null；之後 run 迴圈 `_stopNow` 成立就 break（:139-140），不會再開始別的請求。
- 證據：MD 改壞後 N-2 FAIL；A m-2 測試仍在。⚠️ 「頁面消失 → 佔用在連線關完之後才放」這整條沒有一個端到端的測試，是把 N-2 的單元測試和 `_one` 的 finally 組合起來推的。

### (4) 4.1 開著時，選好的網路變成打不開 — ✅ 行為正確，⚠️ 少一句說明（m-2）
- `_pick` 有值但找不到時回 null（net_pages.dart:217-222）→ 單選沒有選中的項目，`開始` 變灰（:432）。不會像以前那樣偷偷換成剩下的網路 A。使用者要自己點 A 才能開始；點 A 是明確的選擇，`_seen` 已經換成新的快照（:173-176），所以按開始時 key 會一致，加入的就是 A。
- B 重新打得開時會自動選回 B。開始途中 B 消失：key 比對擋下，顯示「手機裡的網路紀錄剛剛變了」（:248-253）。
- 全部都打不開時（`noneOpens`）進 join2 T8 的畫面（:377-382）。
- 證據：ME 改壞後 N-3 FAIL。

### (5) 結果列被「檢查網路」升級，然後按「完成」 — ✅，⚠️ 少一句說明（m-2）
- `_check`（net_pages.dart:595-620）：重讀時拿 hold，`working` 為真，PopScope 不能退、「完成」按鈕隱藏；列改成 ok，`makeFailed` 改成 `none`；finally 歸還 hold。按「完成」→ pop → dispose → `lease.pageGone()` 立刻釋放（這時沒有 hold）→ 4.1 收到 null，自己 pop（:279-282）。不會留下佔用或對話框。MG 改壞後 FAIL。
- 升級之後，其他台還是「還沒做」（`notDone` 沒有 canRetry / canCheck，net_run.dart:79-80），標題是「有節點沒有完成」，下面那行說明變成 null（net_pages.dart:637-643）。見 m-2。

## 發現

**m-1（MINOR，測試缺口）App 實際用的 `onLost` 接線沒有測試。** 情境：有人把 `_appFlow` 裡的 `onLost: lost`（net_pages.dart:491）拿掉。證據：MJ → 全套 `+853: All tests passed!`。N-5 的測試只驗 `flowDeps` 本身（MH 會被擋），沒驗頁面有把 `_dismiss` 傳進去。現場影響：純斷線（藍牙沒被擋）時，國家問題要等到 `close()` 才會被關，最多晚 10 秒（`_chain.timeout`）。修法：用 `flow: null` 加 StoreRust 做一個頁面層測試；或者把 `_appFlow` 抽出來讓測試直接呼叫，斷言 console 的 `onLost` 會關掉開著的問題。

**m-2（MINOR，現場說明）兩個地方畫面變對了，卻沒告訴使用者為什麼、接下來怎麼做。**
- (a) 選好的網路打不開時，單選被清空、`開始` 變灰，但沒有任何一行字（:217-222）。使用者會看到自己剛選的網路不見了、按鈕按不下去。修法：`_pick != null` 但找不到時顯示「你選的網路現在打不開，請重新選」。
- (b) 升級之後提示行變成 null，畫面只剩「有節點沒有完成」和幾列「還沒做」，沒有下一步。修法：`run.stopped` 從 `makeFailed` 清掉、而且還有 `notDone` 的列時，顯示「網路已建立；其他節點請回到節點頁用「加入網路」」之類的句子。
- 證據：讀碼（行號如上）。⚠️ 沒有在畫面上截圖。

**m-3（MINOR，⚠️ 一幀的窗口）問題還沒畫出來就斷線，這個問題會留在畫面上，最多 10 秒。** 情境：節點送出國家問題的 frame 後馬上斷電，斷線事件在 dialog 的 builder 執行前（同一幀內）就到了，這時 `_open` 還是 null，`_dismiss` 什麼都不做（:530-533）。證據：探針 P2 `lostBeforeBuild` → `dialogAfterSettle(before)=1 now=1 … answer=none`，問題還開著。讀碼推下去：`_endUnclear` 讓請求結束，`_ask` 等 `_chain.timeout(10 s)`（owner_console.dart:362-364），然後 `_one` 的 finally / `_failed` 呼叫 `close()` → `onLost` → `_dismiss`，這時 `_open` 已經設好，就會關掉。這段時間按「改」也不會送出（:260）。不會兩個問題疊在一起（`_failed` 在問「繼續 / 停」之前會先 close，net_run.dart:236）。⚠️ 10 秒後被關掉這段是讀碼推的，探針用的 console 是假的，沒有 `_chain`。修法（可選）：`_ask` 在 `dc` 設好之前，如果 `onLost` 已經觸發，就在 builder 裡立刻關掉；或者 `_dismiss` 記一個 `lostPending` 旗標，讓 builder 看到後馬上 `_closeQ`。

**m-4（MINOR，測試缺口）`dc ??=` 這個防禦沒有測試**（MC 存活）。這是退場動畫中重建時才會走到的路徑，只讀碼可以接受；commit 訊息沒說它沒有測試。commit 訊息另外承認 A m-5 那行現在走不到、沒有測試，屬實（:261-266 只有在 key 一致但 `_picked(now)` 是 null 時才走得到，N-3 之後 `開始` 已經是灰的）。

## 安全
沒有新增輸入面。`_closeQ` 和 `_closing` 只在同一個行程內使用。被入侵的節點在國家問題開著時斷線：同 (2)，不會送國家設定、不會疊兩個對話框。

## ✅ / ⚠️ / ❌
- ✅ 全套 853 PASS、analyzer 只有 1 個 info（輸出如上）；改壞對照 10 個，8 個被擋（MA、MB、MD–MI），2 個存活（MC、MJ）；探針 P1、P2 三種模式，輸出如上；(1)(2)(4)(5) 的結論附了 file:line。
- ⚠️ (3) 佔用要等連線關完才放，這是單元測試加讀碼組合出來的，沒有端到端測試；m-3 的「10 秒後關掉」是讀碼推的；暱稱相同時的排序沒跑；m-2 沒有截圖。
- ❌ 沒碰真機（BLE 斷線的時序、GATT 事件順序都沒有實測）；`cargo test` 沒跑。
