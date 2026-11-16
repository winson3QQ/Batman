# #329 PR 4 程式碼審查：審查者 B，第 1 輪

範圍：`git diff origin/main..HEAD`（feat/329-pr4，HEAD 35b796c，共 13 個 commit），對照凍結計畫 `docs/design/329-pr4-plan.md` v3（含附錄 A）。基準（leave v4.1、update v0.4、p3-impl §3.3、PR 3 機制）不重審，只看新程式有沒有照基準做。

## 0. 我自己跑過的東西

| 項目 | 結果 |
|---|---|
| `flutter test --no-pub`（worktree，Git Bash） | ✅ `00:50 +998: All tests passed!`，rc=0 |
| Rust bridge `CARGO_TARGET_DIR=$HOME/tgt-329pr3 cargo test -q`（WSL Ubuntu-24.04） | ✅ `test result: ok. 69 passed; 0 failed` |
| `flutter analyze --no-pub lib test` | ✅ `1 issue found`（既有的 `test/member_ui_test.dart:4` unnecessary_import，不是本 PR 造成的） |
| 突變測試（在 scratchpad 的副本上做，worktree 沒有動） | 見 §3 表 |
| 重現 m1（setState during build） | ✅ 在副本加一個「下面有頁面在聽 `AppLink.sw`」的測試，結果 FAIL，輸出見 m1 |

## 1. 指定的三個重點

### 1.1 離開頁和舊控制台，逐個結局比對

- 舊的做法：`nodes.dart:1146-1150` `_leaveNetwork` → `leaveFlow(ask: _ask(...), askEnd: _askEnd, left: _left, reread: _readStatusPage)`，結果顯示在 `StatusPageView._leave`（member_ui.dart:381-418）。
- 新的做法：`more_pages.dart` `_LeavePageState._leave`，在一個 `OpSession.once` 裡跑 `leaveFlow`。

| 結局 | 舊控制台顯示 | 新頁面顯示 | 一致嗎 |
|---|---|---|---|
| 節點回答（非 0） | `_ask` 回字串 a → `LeaveResult(a)` → `_leaveLine` | `c.leave()` 的 kind 是 answer → `r.text` → `LeaveResult(a)` → `screenText(r.line)` | ✅ |
| 回答 0（left） | 在同一個 session 上重讀（`_readStatusPage`），截斷一次 | `last.left`（owner_console.dart 的 answer 臂讀 `st.left`）→ `c.statusPage` 用同一個 console、同一個 Rust session（`derive` 在 `_run` 裡算 `statusView`）→ `after_left` 截斷 | ✅（T-L2 有測） |
| unclear（送出後斷線或逾時） | `_kick` / `_endUnclear` 回 `_unclearNow()`：有 sent 時是 `leaveUnclear`，否則是 `notSentLine`，當成回答字串 | `_unclearReply(unclear)` 用同一個 `SendTrack.unclearNow`，kind 是 unclear 或 notSent → ask 回 null → `askEnd()` 給出同一句 | ✅ 句子相同（T-L1 測了「結果不明」） |
| notSent | 同上，`notSentLine` | 同上 | ✅ |
| ended（Rust 結束 session） | Ended 臂顯示 `endedLine(detail)`；leave 的 Unknown 句以 `[` 開頭，原樣顯示 | `c.leave` 沒帶 `endedAfterSent`，Ended 臂顯示 `endedLine(detail)` → askEnd 給出同一句 | ✅ |
| 登入失敗 | `_askEnd = askNoLink`（「沒有連上節點，沒有送出」） | `opLine(login)` = `loginLine(end)` +「沒有送出任何東西。」 | ✅ 用字不同、意思相同（計畫 §2.7 表已經定了） |
| 佔用忙 | — | 「另一個操作還在進行：X」 | ✅ |
| 佔用失效 | — | 在 `hold()` 之前就失效時顯示「這個操作被中斷了，沒有送出」；有回覆時顯示回覆的原句 | ✅（`once` 不呼叫 `pageGone`，實際上不會被撤銷） |
| left 了，但重讀讀不到（stale） | `_missed = r.stale` → 顯示 `refreshMissed`「沒有讀到，請再按一次」 | 沒有用到 `r.stale`，只顯示離開的那一句 | ⚠️ 見 m4 |
| 警告行 | `'⚠️ ${f.warning}'` | `f.warning`，沒有 ⚠️ 前綴 | ⚠️ 見 m4 |

對話框用的事實：`adminApplied` 用 `a.nets.now.nets[].applied`（NetIndex，等於 netSummary.applied）；`memberEntry` 用共用的 `memberEntryOf`，開的是 `mnet/<netId>`；last4 用 `widget.id` 的後四碼（Rust 的 `last4` 也是 device_id 的最後 4 個位元組，owner.rs:717）。判定結果一致，但做法不是計畫寫的「把 `_netNames` 抽出來兩邊共用」（見 m6）。

### 1.2 軟體更新跨過節點重開（`_go` → `OpenSession.run` → `askSw` → Rust）

逐步走一遍：
1. `openSwUpdate`（update_route.dart）先用 `OpenSession.open` 拿佔用，再 `a.sw.take`，然後 push 頁面；`finally` 裡呼叫 `pageGone`。✅
2. 按「套用並重開」→ `_go(_f.press(apply, _h.now()))` → Rust `send(Verb::Apply)`（swupd.rs:771-774）→ `ask(ms)` = `s.run((con) => con.askSw(link, h.now, ms), failed: (_) => link.noLink(h.now()))`。時鐘一律用 `h.now`（審查 D M1）。✅（T-U1 斷言 `link.nows == [4242]`）
3. 節點回答後開始重開：BLE 斷線 → `OwnerConsole._lost` → `_session = null`。如果回答還沒到就斷了：`_endUnclear` → kind 是 notSent（sw 的寫出不帶 sent）→ `askSw` 回 `sw.lost(now)`，並把 `_session` 設成 null。舊程式 nodes.dart:1606-1612 在這裡也是 lost。✅
4. Rust 回「等 10 秒」（`RELOGIN_MS`）→ `_f.resume()` → 送 UpdStatus → `run`：`c.alive` 是 false → 先 `await c.close()` 再 `loginFor`。節點還在重開，登入結果不是 ok → `failed` → `link.noLink(h.now())` → Rust `on_reboot(None)` 用 `link_since` 計時（swupd.rs:1066-1073），超過 `REBOOT_FOR_MS`（300 秒）才 done(T_LATER)。一次登入花多久不影響判定（P12）。✅
5. 節點回來 → 登入成功 → 開新的 console → `askSw` → answer 臂的 `derive` 在 `_run` 裡用回答的那個 session 算 `swAnswer`（owner_console.dart:331-336）→ 進入試用或完成。✅（T-U2）
6. done → 按「關閉」→ `pageGone` → `a.sw.drop(id)`（update_route.dart 的 `if (h.last?.kind == SwKind.done)`）。✅（T-U3）
7. 關掉頁面、再從首頁待辦打開：關頁時 `last` 是 Show[apply] → `SwHolds.unfinished` 為真 → 首頁出現 banner → `_open(id, update: true)` → NodePage 在 postFrame 呼叫 `_update()` → `openSwUpdate` → `take` 拿回同一個 hold → `initState` 走 `_a = last`（不呼叫 start）→ 按套用 → 回到第 2 步。✅
8. 遲到的回答：`_kick` 逾時時把 `_session` 設成 null，之後的 frame 在 `_onFrame` 被丟掉；`derive` 只在 `_answer` 還沒完成時跑。✅（owner_console_pr4_test「a timeout is lost; a late answer does not reach the update」）

這段的問題：m1（每次第一次開更新頁，都在 build 中通知首頁和節點頁）、m2（佔用失效時 Rust 的 flow 被推兩次）、m3（計畫 3a 的藍牙／權限提示列沒有做）。

### 1.3 Rust 把 `settings/set` 標成 `sent`

- 寫入點只有一處：owner.rs:787 `sent: verb == LEAVE || verb == SETTINGS_SET`。Rust 其他地方不讀 `OwnerStep.sent`（`leave_info` 的 `sent` 是另一個參數）。
- Dart 讀 `sent` 的只有 `SendTrack.write`（member_ui.dart:302-311，經過 `stepFrames`），而 `wrote` 只在 `unclearNow(unclear)` 裡用到。
- 舊控制台：三個設定按鈕都是 `_ask(...)`，不帶 `unclear`（nodes.dart:1670、:1694、:1714）；`_unclearNow()` 只在 `_unclear != null` 時才會被呼叫（nodes.dart:150、:433、:498、:549）。所以**舊控制台的行為不變**。✅
- OwnerConsole 既有的 make、join、sendUpdate 都不是 settings/set，不受影響。claim_recovery 有自己的 `wrote`，不讀 step.sent。✅
- Rust 的 `settings_tests`（6 個）鎖住了：sent 序列是 `[false, true]`、ssh_keys 仍是 `[false, false]`、錯誤回答和其他動詞的 `settings == None`、節點字串經過 `shown`。✅

## 2. 發現

**沒有 BLOCKER，也沒有 MAJOR。**

### MINOR

**m1. 第一次開更新頁時，`onShown` 在 build 中通知 `AppLink.sw`，首頁和節點頁的 `setState` 觸發 "setState() called during build"**
- 情境：在節點頁按「軟體更新」（沒有做到一半的 hold）→ `SwUpdatePage.initState` → `_go(_f.start())` → 同步呼叫 `_show(a)` → `widget.onShown`，也就是 `a.sw.touched` → `notifyListeners` → NodePage 和 HomePage 的 `_netsChanged` → `setState`。這時框架正在 build 新的 route。
- 證據：swupdate.dart:128（initState 呼叫 `_go`）、:153（`_show` 呼叫 `onShown`）；node_page.dart:40、:49-51；home_page.dart:115、:120-122。我在副本加了一個測試，下面放一個聽 `a.sw` 的 StatefulWidget，結果：
  ```
  The following assertion was thrown while dispatching notifications for SwHolds:
  setState() or markNeedsBuild() called during build.
  #5 SwHolds.touched (sw_holds.dart:29) #6 _SwUpdatePageState._show (swupdate.dart:153) #7 _go (swupdate.dart:172) #8 initState (swupdate.dart:128)
  ```
- 影響：`ChangeNotifier` 會接住這個例外；release build 沒有這個 assert，畫面結果不變。debug APK 每次都會印一個 FlutterError。現有的 update_route_test 都是從一個不聽 `a.sw` 的 `Builder` 開頁面，所以測不到。
- 修法：把 `touched()` 的通知延到下一個 frame 或 microtask（`scheduleMicrotask(notifyListeners)`，或 `SchedulerBinding.addPostFrameCallback`）；或者 `_show` 在 initState 那一次不呼叫 `onShown`。另外加一個從真的 NodePage 開新更新的測試。

**m2. `askSw`：回答已經到了、但佔用已經失效時，Rust 的 flow 被推兩次**
- 情境：`derive` 已經在 answer 臂呼叫了 `sw.answered(s, now)`，Rust 的 `swAnswer` 已經改了 flow 狀態。接著 `_leaseCheck` 把回覆改成 `leaseLost`，而且**沒有帶上 `value`**（owner_console.dart 的 `_leaseCheck` 只抄 text、persistedRel、sessionAlive、keyError）。於是 `askSw` 又呼叫一次 `sw.lost(now())`，作用在已經往前走的狀態上（swupd.rs:864-866 `let Out::Req(..) = self.out else { return None }`，多半得到 nothing，頁面停在上一個畫面）。`_leaseCheck` 也一樣丟掉 `settings` 和 `left`。
- 實際上要佔用被撤銷才會發生（`pageGone` 之後 420 秒）。`OpenSession` 只在 dispose 時呼叫 `pageGone`，`PopScope` 又擋住使用者，所以很少見。
- 修法：讓 `_leaseCheck` 保留 `value`、`settings`、`left`；或者 `askSw` 在 `v is SwAction` 時直接回 `v`（Rust 已經吃下這個回答），沒有 `v` 時才呼叫 `lost`。

**m3. 計畫 §2.8 3a 的「藍牙／權限提示列（X7）」在更新頁沒有做**
- 證據：update_route.dart 和 swupdate.dart 都沒有讀 `a.link.core.blocked`（grep `blocked|precondition` 沒有結果）。
- 情境：按了套用、節點重開期間，使用者把藍牙關了 → 每次 `loginFor` 都回 precondition → `noLink` → 畫面一直寫「正在重開」，300 秒後變成「稍後再看」，沒有告訴使用者是手機的藍牙關了。舊控制台也是這樣，所以不算錯誤結局，但計畫答應過要加這一列。
- 修法：照計畫在更新頁加上 PR 2 的提示列，或把這項寫進 #329 的 checklist。

**m4. 離開頁沒有照舊控制台顯示 stale 提示和 ⚠️ 前綴**
- 證據：more_pages.dart 的 `_leave` 只用 `r.line` 和 `r.fields`，沒有用 `r.stale`；`f.warning` 沒有加「⚠️ 」前綴（舊的在 member_ui.dart:413、:480）。
- 情境：回 0 之後重讀失敗 → 新頁只說「已離開網路」，沒有「沒有讀到，請再按一次」。下面的節點頁還是 NodeLink 舊的「在網路裡」，要等下一輪讀取才更新。這不會讓節點被改，只是少了一句提示。
- 修法：`r.stale` 時加上 `refreshMissed` 那一行（或「狀態還沒重新讀到」）；警告行照舊加前綴。

**m5. 好幾個守衛沒有會失敗的測試（突變存活）**
- 見 §3：三個頁面的 `PopScope`（計畫 A M4 的守衛）；`OpenSession.run` 登入後的 `_gone` 檢查（T-P5 只測了 `once`）；`once` 登入後的 `lease.valid` 檢查；離開後的 `a.link.refresh()`（審查 D m3）；首頁待辦的「節點還在」過濾；`openSwUpdate` 的 `context.mounted` 分支；`SwHolds.take` 的 done 檢查。
- 修法：各補一個測試。例如：Wi-Fi 送出中 `maybePop()` 之後頁面還在；OpenSession 登入途中 `pageGone` → 沒有寫出任何 frame；離開出結果後 NodeLink 的 refresh 有被呼叫；舊控制台刪掉節點後 banner 不出現。如果 `SwHolds.take` 的 done 檢查只是防禦性的，就在 commit 裡註明它是等價突變。

**m6. 計畫第 2、6 步有兩項沒照做，commit 只寫了其中一項**
- `console_paths.dart` 的共用表加設定和離開的列：589d859 寫了「Not done」，但沒有寫進 #329 checklist（使用者的規則：縮範圍要寫進原單）。
- 把 `statusFieldsOf` 和 `_netNames` 抽成共用函式（計畫 §2.7「舊控制台與新頁面共用，不改判定」）：實際上只抽了 `memberEntryOf`，`adminApplied` 和 StatusFields 的轉換在新頁面另外寫了一份（`_facts`、`leaveFieldsOf`）。現在判定一致（見 §1.1），但兩份以後會各自漂移。
- 修法：抽出來，或把「不抽，理由是什麼」寫進計畫的偏離表和 checklist。

**m7. 5.6 送出期間欄位還能編輯；送出去的是登入完成那一刻的欄位內容，沒有再驗一次**
- 證據：settings_pages.dart `_send` 的 callback 在登入之後才讀 `_pass.text`；TextField 沒有 `enabled: !_sending`；`can` 只在按下時計算。
- 情境：登入要幾十秒，使用者在這段時間改了密碼欄（例如刪了幾個字）→ 送出一個沒驗過的值 → 節點以 reason 13 拒絕（安全邊界在節點，不會改錯）。另外，名稱用的是按下時的值，密碼用的是登入後的值，兩者取值的時間點不同。
- 修法：送出中把兩個欄位設成 `enabled: false`；或在 callback 裡再跑一次 `apPassProblem`，不合就不送。

**m8. 5.8 結果不明之後沒有「重新讀取」，「目前」還顯示舊的值**
- 證據：settings_pages.dart CountryPage：「重新讀取」只在 `cur == null` 時出現；unclear 時 `_cc` 不變。
- 情境：改國家逾時 → 顯示「結果不明 — 請重新讀取設定」，但頁面上沒有重新讀取的按鈕，「目前」還寫舊的國家。要離開頁面再進來才會重讀。
- 修法：unclear 時清掉 `_cc`，或顯示「重新讀取」（同 5.6 的 `_again`）。

**m9. 首頁待辦的計數沒有套用 banner 的過濾**
- 證據：home_page.dart 的 `todos = ... + a.sw.unfinishedIds.length`，banner 另外有 `if (a.link.core.states.containsKey(id))`。舊控制台刪掉節點時不會呼叫 `a.sw.drop`，這時計數會比 banner 多一個。影響很小。
- 修法：計數用同一個過濾條件。

**m10.（觀察，不要求改）** `OpSession.once` 和各頁的 `_running` / `_sending` 沒有 try/finally。如果 `loginFor` 或 `requests` 丟出不是 `StateError` 的例外，`PopScope(canPop: false)` 會讓頁面卡住。現在的 `loginFor` 和 `_ask` 都把錯誤轉成結果，所以這只是個脆弱點；加 `finally` 的成本很低。

## 3. 突變測試（在 scratchpad 副本上做，每次只改一處，跑相關的測試檔）

| # | 突變 | 跑的測試 | 結果 |
|---|---|---|---|
| 1 | LeavePage、WifiPage、CountryPage 改成 `canPop: true` | more_pages_test、settings_pages_test | **存活**（+37 全過）→ m5 |
| 2 | 首頁 banner 拿掉 `states.containsKey(id)` | update_route_test、more_pages_test、pages_test | **存活** → m5 / m9 |
| 3 | 拿掉離開後的 `a.link.refresh()` | more_pages_test | **存活** → m5 |
| 4 | `SwHolds.take` 不看 done | update_route_test | **存活**（防禦性：openSwUpdate 會先 drop） |
| 5 | `OpenSession.run` 登入後不看 `_gone` | update_route_test、op_session_test | **存活** → m5 |
| 6 | `once` 登入後不看 `lease.valid` | op_session、settings_pages、more_pages | **存活** → m5 |
| 7 | `openSwUpdate` 拿掉 `!context.mounted` 分支 | update_route_test | **存活** → m5 |
| 8 | 5.6 unclear 時不給「重新讀取」 | settings_pages_test | KILLED（T-W3） |
| 9 | setCountry 不帶 unclear / endedAfterSent | owner_console_pr4_test | KILLED |
| 10 | `OpenSession.run` 的 finally 不關 console | op_session_test | KILLED（B m3） |
| 11 | 離開後的重讀不看 `gone() \|\| !c.alive` | more_pages_test | 存活（commit 已說明是等價突變：session 不在時 `_ask` 直接回 notSent） |

## 4. 安全（逐個 actor）

- **手機 AP 密碼**：路徑只有 `_pass.text` → 區域變數 → `c.setAp` → frb → Rust `request_set_ap`。`OwnerConsole` 的 log 只有固定句（例如 `a step did not finish (${runtimeType})`）；`_ask` 的錯誤句只帶 `PlatformException.code` 或 `runtimeType`；Rust 的錯誤句不含 body（owner.rs:785-789）；節點的錯誤句不回顯密碼（settingsset.go:139-141）。密碼欄設了 `enableInteractiveSelection: false`、`autofillHints: null`、IME 不學習，整頁包在 `SecureScreen` 裡（設不了旗標就不顯示內容）。T-W5 測了 log、回覆、UiState。✅ 沒有找到外洩的路徑。
- **被入侵的節點**：`SettingsView` 的字串都經過 `statuspage::shown`（Rust 測試 `a_node_string_is_shown_as_node_text`）；它回假的「已更新」只影響它自己；它沒辦法讓 app 寫紀錄（本 PR 沒有新的寫入者）。✅
- **同一支手機上的其他 app**：沒有新檔案、沒有新 channel；`AppLink.sw` 只在記憶體裡（bearer 和 AP 認證活得比現況久，計畫 §5 已經接受）。✅
- **我們自己的錯**：settings/set 送出後斷線不再說成「沒送出」（✅ Rust 和 Dart 兩邊都有測試）；頁面不在了才送出：`once` 有守衛也有測試 ✅，`OpenSession` 有守衛但沒測試（m5）；m2 的雙重推進。
- **fail-secure**：只有 Rust 給了 `settings` 才算成功（`okSettings` 要求 `OpEnd.done && kind == answer`）；其他情況一律顯示原因、結果不明或沒有送出。✅

## 5. 擁有權和生命週期抽查

- 佔用：`once` 的順序是先 `close()`、再 `hold()`、再 `release()`（op_session.dart 的 finally）；`OpenSession` 在 `_running == 0` 時才關 console，`lease.pageGone` 會等 hold。✅
- `keepScreenOn`：`once` 自己開、自己關；`OpenSession` 不碰（測試 C M1）；goWifi 路徑先 dispose 更新頁（false），再開 5.6（true 再 false），不會重疊。✅
- `AppLink.sw` 的寫入者：`take`（更新頁）、`drop`（done 後關頁、移除節點）、`touched`。✅（m1 是通知的時機問題，不是擁有權問題）
- 閒置 300 秒被節點關掉：`c.alive` 變成 false → 下一個請求先 `close` 再 `loginFor`（T-P4、T-U2）。✅

## 6. 結論

**APPROVE-WITH-CHANGES**

沒有會在現場造成錯誤結局、改了節點卻說沒改、洩密、佔用卡住或當機的問題。指定的三個重點（離開頁的各個結局、跨重開的更新、`sent` 對舊控制台的影響）都核對過，和基準一致。建議合併前處理：m1（debug APK 每次都報錯，修法只要一行）、m2（`_leaseCheck` 丟掉 `value`）、m5（補守衛的測試），並把 m3、m6 的縮範圍寫進 #329 checklist。其餘 MINOR 可以一起改，或寫進 checklist。
