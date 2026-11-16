# #329 PR 4 程式碼審查 — 審查者 A，第 1 輪

範圍：`git diff origin/main..HEAD`（feat/329-pr4，13 commits，main 4acddf6），只審新程式；基準（leave v4.1、update v0.4 + swupdate.dart 流程、p3-impl §3.3 + settingsset.go、PR 3 的 loginFor / OwnerConsole 核心 / lease）不重審。對照計畫 `docs/design/329-pr4-plan.md` v3（含附錄 A）。

## 我自己跑過的

| 項目 | 結果 |
|---|---|
| `flutter test --no-pub`（整套，worktree） | ✅ `00:54 +998: All tests passed!` |
| `cargo test --lib`（bridge，WSL Ubuntu-24.04；Windows 主機缺 dlltool 編不動 getrandom） | ✅ `test result: ok. 69 passed; 0 failed`（含 `settings_tests` 6 項） |
| `flutter analyze --no-pub lib test` | ✅ 新檔案 0 error / 0 warning（整個 app 的 116 個問題都在 vendored `rust_builder/cargokit`，與本 PR 無關） |
| 突變測試（在 scratchpad 的副本上改，worktree 未動） | 見下表 |
| 一個探測測試（副本裡加一個聽 `AppLink.sw` 的頁面再開更新頁） | ❌ 斷言錯誤，見 m1 |

突變結果（每個單獨做、跑完還原）：

| 突變 | 跑的測試 | 結果 |
|---|---|---|
| `askSw` 的 `sw.lost(now())` 改成 console 的 `nowMs()` | test/flows + update_route | KILLED（`a lost link is lost at once` FAIL） |
| update_route 的 `failed: (_) => link.noLink(h.now())` 改成 `noLink(BigInt.from(1))` | test/flows + update_route（116） | **SURVIVED** |
| update_route：`s.pageGone()` 從 `finally` 移到開完 5.6 之後（5.6 開的時候佔用還在） | update_route（8） | **SURVIVED** |
| 5.6 / 5.8 的 `canPop: !_sending`、離開頁的 `canPop: !_running` 全改成 `true` | settings_pages + more_pages（37） | **SURVIVED** |
| 離開頁拿掉 `a.link.refresh()` | more_pages（12） | **SURVIVED** |
| 離開頁 `memberEntryOf(..., _raw4)` 改成大寫的 `last4(widget.id)` | more_pages（12） | **SURVIVED** |

## 計畫第二輪兩個 MAJOR 的核對

- **(C M1) OpenSession 不碰 keepScreenOn** — ✅ 程式：`OpenSession`（op_session.dart:121-184）整個類別沒有呼叫 `d.keepScreen`；只有 `once` 在 :89 / :115 開關。更新頁照舊自己管（swupdate.dart:124 `initState` 開、:135 dispose 關）。測試 op_session_test.dart:206 斷言 `f.screen` 為空。同時存在的情況：`once` 在 `acquire` 成功之後才開（:85-89），而更新頁開著時佔用在 `OpenSession` 手上，所以 `once` 拿不到、不會去關。goWifi 時更新頁先 dispose（送 false），5.6 的 `once` 才送 true / false，平台通道照順序送，沒有互相蓋掉。
- **(D M1) 更新的每一個呼叫都用 SwHold 的時鐘** — ✅ 程式：`askSw` 收 `BigInt Function() now`，answered（owner_console.dart:552 的 derive）與 lost（:558）都用它；update_route.dart:45 傳 `h.now`，noLink 用 `h.now()`；`press` 照舊用 `_h.now()`（swupdate.dart:318）。console 的 `nowMs` 只在 `_linkFrom` 用（:330），不進更新。⚠️ 測試只擋住 answered 與 lost 兩條，**noLink 那條沒有會失敗的測試**（見 m3）。

## 其他我核對過、沒有問題的

- Rust `sent`：owner.rs:787 `verb == LEAVE || verb == SETTINGS_SET`，只在簽章後那次寫出設；op/nonce 的寫出（:839）不設。測試 `[false, true]`、ssh_keys `[false, false]`。
- `SettingsView` 只在 `Outcome::Ok` 的臂設（owner.rs:1001），錯誤臂、其他動詞是 `None`；字串經 `statuspage::shown`（=`display_name`，只把控制 / 格式字元換成 U+FFFD，不 trim、不改空白，所以 5.6 預填名稱再送回去不會被改掉；invite.rs:110-112）。
- `endedAfterSent`（owner_console.dart:431-432）：Rust 結束連線時經 `_track.unclearNow`，op/nonce 之後才結束 → notSent，簽章寫出之後 → unclear。符合 C m3。
- 重新登入的條件：計畫寫 `console == null || !alive || !上一次.sessionAlive`，程式只看 `c.alive`（op_session.dart:152）。我逐一查了 `sessionAlive == false` 的每個來源（`_kick` :353、`_endUnclear` :366、`_ask` catch :415、ended :340、`askSw` :557），都先把 `_session` 設成 null，所以兩個條件等價。
- 密碼：只在 `once` 的 requests 回呼裡從欄位取出並清空（settings_pages.dart:142-144），進 `requestSetAp`；`_ask` 的錯誤句只用 `e.runtimeType` / Rust 的錯誤字串，`owner_op` 的錯誤（owner.rs:830-843）不含 body；`ConsoleReply.toString` 不含 text；OwnerConsole 的 log 行沒有回答內容。sw 回答的 `detail` 是空字串（owner.rs:1650）。
- 離開頁的對話框事實與舊控制台等價：`hasNet = netFiles > 0` 等於舊的 `nets.isNotEmpty`（兩者都含打不開的檔案，net_index.dart:54-55）；`applied` 都要求紀錄打得開；`_raw4` 與 Rust `session.last4()`（owner.rs:717，裝置 id 原樣後四碼，不轉大寫）一致。
- `OpenSession.pageGone` 在請求中不打斷、回來後先關 console 再放佔用（:171-172 + lease.dart:68）；測試 op_session_test.dart:180 有。

## BLOCKER

無。

## MAJOR

無。

## MINOR

**m1. 更新頁 `initState` 裡同步通知 `AppLink.sw`，正在 build 時讓節點頁 / 首頁 `setState`（debug 版會報斷言錯誤）**
- 情境：節點頁按「軟體更新」（或首頁待辦 → 節點頁 → 更新頁）。`_SwUpdatePageState.initState` → `_go(_f.start())` 同步跑到 `_show`（swupdate.dart:128、:172）→ `widget.onShown` = `a.sw.touched`（update_route.dart:47）→ `notifyListeners` → `NodePage._netsChanged` / `HomePage._netsChanged` 的 `setState`（node_page.dart:39、home_page.dart:115）。這時框架正在 build 新的路由。
- 證據：我在副本裡加一個聽 `a.sw` 的頁面，照 `openIt` 開更新頁，結果 `setState() or markNeedsBuild() called during build ... SwHolds.touched (sw_holds.dart:29) ← _SwUpdatePageState._show (swupdate.dart:153) ← initState (swupdate.dart:128)`，測試 FAIL。現有測試沒抓到，因為 update_route_test 的宿主沒有聽 `a.sw` 的頁面。
- 影響：release 版沒有斷言，功能照常；debug 版每次開更新頁都報一個 FlutterError（被 `ChangeNotifier` 接住，不會讓頁面掛掉），第一次通知沒讓節點頁重畫（那一次是 `send`，沒有「套用」鈕，不影響待辦）。
- 修：`onShown` 延到這一幀之後（`WidgetsBinding.instance.addPostFrameCallback` 或 `scheduleMicrotask`），或 `_show` 在 `initState` 那一次不通知；加一個「宿主有聽 `a.sw` 的頁面」的測試（上面的探測測試就能當負對照）。

**m2. 5.8 國家頁不會跟著 NodeLink 的讀取更新；結果不明之後也沒有「重新讀取」**
- 情境 1（計畫 §7 的真機場次就會碰到）：離開網路成功 → `link.refresh()` → 使用者按完成 → 更多 → 國家。5.8 的 `_read` 拿佔用（NodeLink 這一輪被 `_dropAll` 中止，node_link.dart:185-186），讀完放掉；這時 NodeLink 對這台「新鮮」的讀取（≤ 300 s）還是離開之前的，`_blocked()` 顯示「要先離開網路才能改國家。」（settings_pages.dart:271）。NodeLink 之後讀到新狀態，但 `_CountryPageState` 沒有訂 `link.changed`（對照 more_pages.dart:44 有訂），畫面不會變，頁面上也沒有任何鈕能重新判斷；只能退出再進來。計畫 §2.7 加 `link.refresh()` 的理由（審查 D m3）正是讓「5.8 的先離開網路」更新，5.8 這半沒有做到。是 fail-closed（只會多擋，不會放行），所以不是 MAJOR。
- 情境 2：國家送出後斷線 → 「結果不明 — 請重新讀取設定」（opLine），但「重新讀取」只在 `cur == null` 時出現（settings_pages.dart:338），`_cc` 仍是舊值，所以沒有鈕。計畫 §2.5「結果處理同 5.6」（5.6 在 unclear 時給「重新讀取」，:156、:215）。
- 修：`initState` 訂 `widget.app.link.changed`（同 MorePage）；unclear 時也給「重新讀取」。各加一個測試（NodeLink 讀取在頁面開著時變成不在網路 → 選單可用；unclear → 有重新讀取）。

**m3. （D M1 的負對照不完整）更新頁 `noLink` 的時鐘沒有會失敗的測試**
- 證據：突變 `failed: (_) => link.noLink(BigInt.from(1))`（update_route.dart:45）SURVIVED，116 個測試全過。程式現在是對的，但「套用」之後節點重開的那段時間，每一次 `ask` 都是登入失敗 → `noLink`，這正是 Rust 依時間判定 `REBOOT_FOR_MS` 的路徑（swupd.rs:848-855）；這條換成別的時鐘，重開判定就會錯，而沒有測試會紅。
- 修：update_route_test 加一項：登入失敗（`f.loginEnd = notFound`）→ `link.nows` 全是 `4242`。

**m4. goWifi 的佔用交接沒有會失敗的測試**
- 證據：突變「`pageGone` 移到開完 5.6 之後」SURVIVED。T-U5（update_route_test.dart:214-223）只斷言 `WifiPage` 出現、hold 是同一個，沒斷言 5.6 真的拿到佔用並讀到名稱（佔用沒放時 5.6 會顯示「另一個操作還在進行」，測試照過）。程式現在是對的（`_running == 0` 時 `pageGone` 同步放佔用，lease.dart:76-78）。
- 修：T-U5 加斷言：5.6 讀到 `node-ap`（或 `f.reg.current` 在 5.6 讀完後為 null、畫面沒有「另一個操作還在進行」）。

**m5. 5.6 / 5.8 / 離開頁的 `PopScope` 沒有測試**
- 證據：三處 `canPop` 全改成 `true`，settings_pages + more_pages 37 項全過。計畫 §2.4 / §2.5 / §2.7（審查 A M4）列了這個守衛。`_gone` 已經擋住「登入回來才送」，所以少了 PopScope 的後果是使用者看不到結果（請求照送、佔用照放），不是錯誤寫入。
- 修：各加一個「送出中按返回 → 頁面還在」的 widget 測試。

**m6. 離開頁：幾個守衛沒測；計畫要的共用函式沒有抽**
- `a.link.refresh()`（more_pages.dart:254）拿掉 → SURVIVED。
- 對話框的 `memberEntry` / `adminApplied` 兩條只測了 `false/false`（more_pages_test.dart:178-182）；把 `_raw4` 換成大寫 `last4()` → SURVIVED。裝置 id 是小寫十六進位（測試的 `…7d2c`），大寫就永遠比不到 Rust 的 `device_last4`，「之後可以按加入網路」那一句會錯；現在的程式是對的，只是沒有測試擋。
- 計畫 §2.7 說把 `_netNames` 與「`StatusView` → `StatusFields`」抽成兩邊共用的函式、「不改判定」。實作只共用了 `memberEntryOf`；`adminApplied` 改從 `NetIndex` 算、`leaveFieldsOf` 是新寫的。我逐條對過，判定等價（見上「核對過」），但這是第二份實作，之後改一邊另一邊不會跟。請在計畫 / PR 說明這個偏離，或照計畫抽出。
- 修：加 `admin=true`、`member=true` 兩個對話框測試（用小寫 id）、一個 refresh 有被呼叫的斷言。

**m7. 計畫 §2.8 3a 的「藍牙 / 權限提示列」沒有做**
- 計畫：更新中藍牙被關 → `ask` 的登入回 precondition → `sw.noLink`，「頁面另外在 NodeLink 的 precondition 成立時顯示 PR 2 的藍牙 / 權限提示列（X7）」。update_route.dart 與 swupdate.dart 都沒有這一列（grep `precondition` / `藍牙` 無結果）。
- 影響：重開等待時藍牙被關，畫面只有 Rust 的「連不到節點」類句子，到 `REBOOT_FOR_MS` 用完時結論是節點沒回來，使用者不知道是自己的藍牙關了。結局判定本身是基準（update v0.4），所以列 MINOR。
- 修：照 3a 加那一列；或寫進 #329 checklist 並在 PR 說明。

**m8. 計畫列的兩個項目沒有做，也還沒進 checklist**
- T-U4 / §5「sw 回答不出現在 log 擷取裡（負對照：記 log）」：owner_console_pr4_test 的 software update 組（:280-325）沒有 log 擷取的斷言。程式現在不記（sw 的 `detail` 是空字串，console 也不記回答），但沒有守衛。
- §6 第 2 步 `console_paths.dart` 共用表的設定 / 離開列：commit 589d859 寫「Not done」，理由合理（舊控制台的設定沒有 unclear 句），但依規則縮掉的範圍要寫進 #329 的 checklist。

**m9. 首頁待辦數字與橫幅不一致；舊控制台移除節點不清 `AppLink.sw`**
- home_page.dart:257 的 `todos` 加 `a.sw.unfinishedIds.length`（不過濾），橫幅（:327）只顯示 `states.containsKey(id)` 的。從新頁面移除會 `drop`（more_pages.dart:101），但從舊控制台移除（nodes.dart）不會，那台的 hold 留著 → 待辦數字多 1、看不到對應的橫幅。
- 修：`unfinishedIds` 的計數也過濾 `states.containsKey`（或在 `SwHolds` 外面過濾一次給兩處用）。

**m10. 離開後的重讀讀不到（`LeaveResult.stale`）時，畫面沒有說**
- more_pages.dart:260-262 只取 `r.line` 與 `r.fields`；`fields == null`（重讀逾時 / console 已死）時，結果句下面什麼都沒有，使用者分不出「沒有重讀」與「重讀到了」。舊控制台會把狀態頁標成舊的（leave v4.1 §2 的 `stale`）。
- 修：`r.stale` 時加一行「離開後沒有讀到節點的狀態，稍後回節點頁看」。

**m11. `once` 只接 `StateError`，其他例外會冒到頁面，而頁面此時 `canPop: false`**
- op_session.dart:108 只 `on StateError`；`finally` 會放佔用，但例外接著丟到 `_send` / `_leave`，`_sending` / `_running` 不會被設回 false，頁面卡在「正在送出…」、返回鍵被擋。我沒找到現在會丟其他例外的路徑（`_ask` 會接住 req 的例外、`leaveFlow` 接住重讀的例外），所以是預防性的。
- 修：頁面的 `_send` / `_leave` / `_pick` 用 `try/finally` 把旗標設回來，或 `once` 把其他例外也轉成固定句。

## 結論

**APPROVE-WITH-CHANGES**

沒有 BLOCKER / MAJOR：設定的 `sent`、`SettingsView`、OpSession 的佔用 / 登入 / gone 規則、密碼路徑、計畫第二輪的兩個 MAJOR（C M1、D M1）都照計畫寫進程式，整套 998 + Rust 69 都過。要改的主要是測試缺口：D M1 的 noLink 時鐘（m3）、goWifi 交接（m4）、PopScope（m5）、離開頁的幾個守衛（m6）。這些守衛在突變下都 SURVIVED，程式現在對，但沒有測試擋住以後改壞。另外 m1（debug 版的斷言錯誤，已用探測測試重現）與 m2（5.8 在離開網路後仍說「要先離開網路」，計畫的 D m3 修正對 5.8 沒有作用）建議在真機場次之前修。m7、m8 是計畫列了卻沒做的項目：要嘛補做，要嘛寫進 #329 checklist。
