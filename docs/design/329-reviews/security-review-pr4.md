# #329 PR 4 程式碼層安全審查（獨立審查者）

- 範圍：`git diff origin/main..HEAD -- app`（branch `feat/329-pr4`，head 0f23b52）；計畫 `docs/design/329-pr4-plan.md` §5。只審新程式碼；已審過的基準（254-app-leave v4.1、254-app-update v0.4 流程、254-p3-impl §3.3 節點端、PR 3 機制）不重審。
- 方法：只讀原始碼 + Rust 端對照 + 跑新測試檔。沒碰手機、adb、節點、gradle connected test。
- 結論：**沒有 HIGH / MEDIUM。** 3 項 LOW（一項記憶體中秘密的存活時間、一項測試覆蓋不如計畫所寫、一項防禦性的錯誤分類）。密碼路徑、SecureScreen、只在 Rust 給結果時才說成功（fail-closed）、`sent` 旗標對舊控制台的影響，都查過，沒有問題。

## 執行結果

✅ 新測試檔（Git Bash，`flutter test --no-pub`）：

```
flutter test --no-pub test/ui/settings_pages_test.dart test/flows/op_session_test.dart test/ui/update_route_test.dart test/flows/owner_console_pr4_test.dart test/ui/more_pages_test.dart
...
00:09 +84: .../update_route_test.dart: T-U5: 去設定手機 Wi-Fi -> 5.6, the update page's lease given back first; the same update kept
00:10 +85: .../update_route_test.dart: (tearDownAll)
00:11 +85: All tests passed!
```

❌ Rust `cargo test --lib settings_tests` 沒跑成（本機 auto-mode 分類器兩次沒給結果，所以沒執行）；Rust 端只做了原始碼審查。

## 發現

### LOW-1　舊控制台「忘記節點」不會清掉 `AppLink.sw` 的更新 hold，bearer / AP 認證留在記憶體到 app 結束

- **情境**：在新的節點頁開始軟體更新，做到一半（hold 留在 `AppLink.sw`），之後從「舊版控制台」（`settings_page.dart:57` 等入口仍開得到 `NodesPage`）忘記這台節點。`nodes.dart:461-470` 只 `storeRemove('node/$deviceId')`，`NodesPage` 拿不到 `AppLink`，所以不會呼叫 `a.sw.drop(id)`。那份 `SwUpdate`（Rust 裡面有 upload bearer 和節點 AP 的 ssid/密碼，`swupdate.rs:5-6`、`:260-264`）會一直留到 app 結束。
- **證據**：`sw_holds.dart:25-27`（只有 `drop` 會移除）；`drop` 只在 `more_pages.dart:101`（新頁面的移除）和 `update_route.dart:53`（`done`）呼叫；計畫 §5 寫的是「到 `done`、移除節點或 app 結束」。程式碼審查 A m9 / B m9 只修了首頁計數（`unfinishedOf(states.containsKey)`），記憶體裡的 hold 還在。
- **影響**：只在程序記憶體裡，不落地、不記 log（D8 不變），能利用的人要能讀這個 app 的記憶體（root / 除錯器）。另外，同一個 device id 之後再被加回來（id 不變時）時，`take` 會撿回這份舊的未完成 hold（`sw_holds.dart:14-17`）。節點會拒絕不存在的上傳，所以不是安全洞，只是狀態殘留。
- **修**：最小的做法是在 `AppLink.nets` / record 變動的回呼（或首頁算 `unfinishedOf` 時）把 `states` 裡已經沒有的 id 從 `SwHolds` 丟掉，也就是加一個 `SwHolds.retain(bool Function(String))`，在節點清單重算時呼叫。或者把計畫 §5 的說法改成「舊控制台的移除不清，到 app 結束」，明說接受這個風險。

### LOW-2　「密碼 / sw 回答不進 log」的測試抓不到 `OwnerConsole` 的 log 行，計畫 §5 承諾的 sw log 測試也不存在

- **情境**：之後有人在 `OwnerConsole.setAp` 或 `_run` 的 answer 分支加一行 `log?.call(...)`，把 passphrase 或 sw 的回答帶進去。正式 app 的 `opDeps` 會把它接到 `debugPrint('BMAPP $l')`（`settings_pages.dart:34`），在 release 版一樣進 logcat。現有測試不會因此 FAIL。
- **證據**：
  - `test/` 裡沒有任何地方把 `log:` 傳給 `OwnerConsole`（grep `log:` 只命中 `member_ui_test.dart:522`、`net_index_test.dart:104`）。所以 `owner_console_pr4_test.dart:190-196`（「no reply and no log」）實際只檢查 `'$a ${a.text} ${asked}'`，而 `ConsoleReply` 沒有 `toString`，`$a` 只會印出 `Instance of`；`settings_pages_test.dart:98-117`（T-W2/T-W5）攔了 `debugPrint`，但頁面用的是測試自己的 `f.d` console，沒有接 log。
  - 計畫 §5 寫的「新增的 `sw` 臂加測試：sw 回答不出現在 log 擷取裡（負對照：記 log）」，在 `owner_console_pr4_test.dart:282-340` 的 sw 測試裡找不到，任何 sw 測試都沒有攔 log。
- **現況**：這個性質目前是成立的，靠原始碼保證：`owner_console.dart` 的 log 行全部是固定字串或型別名，包括 `:174`、`:225`、`:291`、`:305`、`:339`、`:373`，沒有一行帶回答內容、`st.detail` 或參數。新增的 `op_session.dart:121`、`:180` 只印 `runtimeType`。
- **修**：在 `owner_console_pr4_test` 的 `Rig` 接一個 `log: lines.add`，對 `setAp(…, secret)` 和一個 sw 回答斷言 `lines` 不含 secret 或回答的標記值。負對照：在 answer 分支暫時加 `log?.call(st.detail)`，或在 `setAp` 加 `log?.call(passphrase)`，看測試 FAIL。

### LOW-3（防禦性）　`OpSession.once` 把任何 `StateError` 都當成「被中斷了，沒有送出」

- **情境**：`op_session.dart:114-116` 把 `requests` 拋出的任何 `StateError` 都轉成 `OpReply(OpEnd.leaseLost)`（`reply == null`）。`opLine` 對它顯示「這個操作被中斷了，**沒有送出**。請再試一次。」（`settings_pages.dart:44`）。如果哪天有一個 `StateError`（例如 `.first` 用在空 list、或 completer 被完成兩次）在 `sent` 的寫入**之後**才拋出，畫面就會把「可能已送出」說成「沒有送出」，使用者可能重送 settings/set，或用舊密碼連線。這正是計畫 §5 「我們自己的錯」要擋的那一類。
- **證據**：目前查不到可以走到的路徑。`_ask` 的 `_busy` StateError 發生在寫入前（`owner_console.dart:400`）；`lease.hold()` / `lease.run` 的 StateError 也都在寫入前，或在 `_run` 裡面就被吃掉（`:300`）；`leaveFlow` 的 `reread` 有 try/catch（`member_ui.dart:278-282`）；WifiPage 的 closure 沒有會拋 StateError 的呼叫。所以這一項只是加固。
- **修**：只在確實發生在送出前的地方轉成 `leaseLost`（hold 拿不到、`_busy`），其他的 `StateError` 走 `OpEnd.failed`（「結果不明」）。一個簡單的做法是讓 `_ask` 的 busy 改丟自訂的 `ConsoleBusy`，`once` 只 catch 它和 hold 的錯；`OpenSession.run`（`:155`、`:176`）照同樣的方式處理。

## 逐 actor 檢查結果（清白的項目）

### 1. 密碼端到端（我們自己的錯 / 同手機其他 app）

| 檢查項 | 結果 | 證據 |
|---|---|---|
| 欄位旗標 | ✅ `obscureText: !_show`、`autocorrect:false`、`enableSuggestions:false`、`enableIMEPersonalizedLearning:false`、`enableInteractiveSelection:false`（不能選取 / 複製 / 貼上）、`autofillHints: null`（不參與 Android autofill，密碼管理器不會提示儲存）；顯示密碼時用 `visiblePassword` 鍵盤。有 widget 斷言。 | `settings_pages.dart:200-219`；`settings_pages_test.dart:153-164` |
| 什麼時候讀取、什麼時候清空 | ✅ 在 `OpSession.once` 的 requests closure 裡才讀：登入成功、`gone()` 和 `lease.valid` 都檢查過之後同步讀出，接著馬上 `_pass.clear()`，再檢查一次規則，然後交給 `c.setAp`。登入失敗、busy、gone 時，密碼留在欄位裡（還沒送出，合理）。送出中欄位 disabled，所以送出的值就是檢查過的值。 | `settings_pages.dart:141-152`；`op_session.dart:100-112`；測試 `settings_pages_test.dart:98-129` |
| Dart 端有沒有任何地方印出 / 存下密碼 | ✅ diff 裡新增的 `debugPrint` 只有 4 處：`op_session.dart:121`、`:180`（`runtimeType`）、`more_pages.dart:94`（`runtimeType`）、`settings_pages.dart:34`（console 的固定 log 行）。`ConsoleReply` / `OpReply`（`op_session.dart:59`：只有 enum 名稱）/ `SettingsView`（frb 產生的，沒有 `toString`，也沒有 passphrase 欄位）都不帶密碼。密碼不進 `UiState`、不寫紀錄、不進任何 `Text`；成功句只帶節點回的 SSID（`settings_pages.dart:161`）。 | grep `^\+.*(debugPrint\|log\(\|toString…)` 對整個 `app/lib` diff |
| Rust / frb | ✅ `request_set_ap` 把密碼放進 `Value` → `owner_op` 存成 `op` → 簽章時 `op.take()`（`owner.rs:772`）→ 加密請求。`owner_op` 的錯誤字串只有 `conn.request("op/nonce", {})` 的 `{e:?}`（`:836`），不含 body；送出失敗的字串 `:789` 是 `verb_text` + 連線錯誤，不含 body。`SettingsView` 有 `derive(Debug)`，但沒有密碼欄位。frb 的 constMeta 只有參數名稱。Rust 測試 `set_ap_marks_its_signed_write_sent_and_answers_the_settings` 斷言 `detail` 不含密碼（沒跑，見上）。⚠️ Rust 記憶體裡的 `Value` 沒有 zeroize（基準，舊控制台也一樣）。 | `owner.rs:770-790`、`:815-819`、`:830-843` |
| 舊控制台 | ✅ 只換成 `memberEntryOf`，邏輯相同（`nodes.dart:1232`、`member_ui.dart:256`）。 | |

### 2. SecureScreen（同手機其他 app：截圖 / 錄影 / Recents）

✅ fail-closed：`SecureScreen` 要等 Android 回答 `true` 才 build child（`secure_screen.dart:41-45`），`null` 時是空白，`false` 或例外時顯示說明句、不顯示內容。整個 `BatPage`，包括密碼欄和「顯示密碼」，都在 child 裡（`settings_pages.dart:177-229`），所以截不到也錄不到。機制本身有自己的測試（`test/secure_screen_test.dart`）；這頁另外有一個測試斷言它有被包在 SecureScreen 裡（`settings_pages_test.dart:183-186`）。⚠️ 剩下的風險：「顯示密碼」打開時，有無障礙權限的 app 讀得到明文（Android 對非 password 欄位的通例），計畫沒提，屬於可以接受的行為。

### 3. 只在 Rust 給結果時才說成功（被入侵的節點 / 我們自己的錯）

| 檢查項 | 結果 | 證據 |
|---|---|---|
| Wi-Fi / 國家的成功判定 | ✅ `okSettings` 只在 `end == done && kind == answer && settings != null` 時算成功（`settings_pages.dart:49`）。Rust 只對 `settings/get`、`settings/set` 的 **Ok** 回答給 `settings`（`owner.rs:1001`）；錯誤回答、op/nonce 被拒、其他 verb 都是 `None`（`owner.rs` 測試 `an_error_answer_or_another_verb_has_no_settings`）。`leaseLost`、`failed`、`unclear`、`notSent`、`ended` 一律不算成功。 | |
| 晚到的回答 | ✅ `derive` / `_complete` 只作用在還在等的請求（`owner_console.dart:333-336`、`:238-241`）；逾時會 `_session = null`。每次 `OpSession.once` 都重新登入一個新 session，不會撿到上一個請求的回答。 | |
| 被入侵的節點回一個假的「已更新」 | ✅ 計畫 §5 已經接受：它控制的本來就是自己的設定。畫面上顯示的 SSID / 國家來自 `SettingsView`，都經過 `statuspage::shown`（`owner.rs:695-707`；超長 + U+202E 的測試在 `a_node_string_is_shown_as_node_text`）。國家選單只送 `countries` 的 key（`settings_pages.dart:283-286`）；`LeavePage` 用的 netId 是 16 bytes 轉 hex（`owner.rs:2260`），拼進 `mnet/$netId` 不會走出 records 目錄。 | |
| 節點的錯誤句 | ⚠️ 已接受（PR 3 LOW 1，同一類）：`error_text` 的 `{verb}`（`owner.rs:657`）是節點的原文。另外，`leaseLost` 但已有 Ok 回答的時候，`opLine` 會顯示 `settings_text`（`owner.rs:663-677`，名稱 / SSID 沒經過 `shown`）。路徑很窄（回答到了之後 lease 才失效），而且和 PR 3 LOW 1 是同一類，所以不另列。 | `settings_pages.dart:43` |
| 新的 `sent` 旗標對其他呼叫者的影響 | ✅ Rust 自己不讀 `OwnerStep.sent`（只用在 `leave_info` 的參數，那是 LEAVE 自己的路徑）。Dart 的 `SendTrack.wrote` 只在有 `unclear` 時，經由 `unclearNow` 讀到（`member_ui.dart:299-315`；`nodes.dart:150`、`:433`、`:498`、`:549` 都在 `_unclear != null` 底下）。舊控制台的 `requestSetCountry` / `requestSetAp`（`nodes.dart:1694`、`:1714`）不傳 `unclear`，所以行為不變；它的「寫入失敗重送」只包到第一個寫入（op/nonce，沒標 `sent`），簽章後的寫入不會被重送。新的 console 用 `settingsUnclearLine` + `endedAfterSent`（`owner_console.dart:526-538`、`:436-438`），送出後斷線就說「結果不明」。 | |
| `OpEnd.failed` | ✅ 只來自 `requests` 拋出的非 `StateError` 例外，顯示「操作出錯，結果不明」，並提供「重新讀取」（`settings_pages.dart:45`、`:165`、`:330`），不會說成功或「沒送出」。`finally` 先關 console，再放 hold 和 lease（`op_session.dart:122-127`）；`OwnerConsole.close` 和 `LoginHandoff.close` 每一步都各自 try，所以 lease 不會卡住（`owner_console.dart:609-627`、`handoff.dart:79-92`）。 | |
| 軟體更新的 `failed` → `noLink` | ✅ `OpenSession.run` 失敗時呼叫 `link.noLink`（`update_route.dart:45`）。可能已經送出的情況都在 `_ask` 裡被轉成 `unclear`（寫入例外 → `_unclearReply(swUnansweredMark)`，`owner_console.dart:415-424`），`askSw` 再轉成 `lost`（`:561-566`）。所以會變成 `noLink` 的只剩送出前的錯誤：登入、gone、hold、busy。已經交給 update 的回答不會被 `lost` 蓋掉（`:561-563`，有測試 `:293`）。 | |

### 4. 更新的秘密（實體取得手機 / 我們自己的錯）

- ✅ D8 不變：`swupdate.dart` 的 diff 只改了 UI 外觀和 `onShown`。「技術資訊」仍然只顯示 `a.tech` 和 `putCode`，`OwnerConsole` 不記錄任何回答（見 LOW-2 的「現況」）。
- ✅ `SwHolds` 只存在記憶體（`sw_holds.dart`），不落地；`done` 後從 `AppLink.sw` 丟掉（`update_route.dart:53`），新頁面的移除也會丟掉（`more_pages.dart:101`）。計畫 §5 接受秘密活得比以前久。例外見 LOW-1。
- ✅ `SwHold.last` 可能是一個帶 `bearerHex` 的 Upload action，但上傳中 `PopScope` 擋住返回，上傳結束後 `last` 就被換掉。
- ✅ `OpenSession`：lease 從 `open` 持有到 `pageGone`；頁面已經不在時，進行中的請求不會被切斷，但結束後就關 console、放 lease，上限 420 s（`op_session.dart:183-193`、`lease.dart:73-85`）。`!context.mounted` 時也會呼叫 `pageGone`（`update_route.dart:30-33`），不會殘留 lease。

### 5. 遠端 BLE / Wi-Fi 攻擊者、供應鏈

- ✅ 沒有新的對外介面：diff 沒有 `android/` 的變更，沒有新的 platform channel 方法，沒有新的相依套件（`pubspec` / `Cargo.toml` 沒變）。新的 BLE 流量全部走既有的 owner session（加密 + 已驗證的 DAC + owner-op 簽章），節點會再驗一次（P7 / P8）。app 端的 SSID / 密碼規則只是提早告知，安全邊界在節點（`settings_pages.dart:55-77`）。
- ✅ 「說明」、「換手機 / 手機遺失」頁是純文字，沒有輸入（`settings_page.dart` diff）。
