# #329 PR 4 實作計畫 v3（FROZEN：第二輪 2 MAJOR 已處理，附錄 A）

上層設計：`docs/design/329-app-uiux.md`（v12.1）§12 第 4 列、§5.5（節點頁 5.1–5.8）、§4.8、§9 表情境 7 / 9、§4.3.6 X22–X24、:841。main = 4acddf6（PR 3 #341 已合併）。

## 0. 範圍：只做新的部分，已審過的行為照舊

**行為基準（已設計、已審、已合併；本 PR 不重新決定，審查也不重審）**：
- 離開網路：`docs/design/254-app-leave.md`（v4.1）；`leaveFlow` / `sendLeave` / `LeaveResult`（lib/member_ui.dart:246-300）；確認文字 Rust `leave_confirm_text`。
- 軟體更新：`docs/design/254-app-update.md`（v0.4）；`SwFlow` / `RustSwFlow` / `SwHold` / `SwUpdatePage`（lib/swupdate.dart，356 行）；舊控制台的 `_askSw`（nodes.dart:1590-1640）。
- 設定（國家、手機 Wi-Fi）：`docs/design/254-p3-impl.md` §3.3（settings/get、settings/set {2: country}、{20: {1: ssid, 2: passphrase}}）；Rust `request_settings` / `request_set_country` / `request_set_ap`（owner.rs:771-783、:1538-1541）；錯誤句 `error_text`（例：國家要先離開網路，代碼 11 原因 14）。
- PR 3 已合併的機制：`NodeLink.loginFor`、`HandoffProber`、`OwnerConsole`（`ConsoleReply`）、頁面佔用的做法（`openRawPage` 順序、`_pending`、`hold` / `pageGone`）、對話框 `_closeQ`。

**本 PR 新做的（審查範圍）**：
1. 節點頁下半的分組（設計 §5.5）：網路（PR 3 已有）、手機 Wi-Fi、軟體更新、更多。
2. 5.6 手機 Wi-Fi 頁（`SecureScreen`；名稱 1–32 位元組、密碼 8–63 可顯示 ASCII；送出後清空；目前值來自 settings）。
3. 5.8 國家頁（台灣 TW / 美國 US；目前值來自 settings；改變要確認；不改預設，U9）。
4. 5.7 更多：改暱稱（`UiState.setNick`，PR 3 已有）、國家、離開網路、技術資訊、從這支手機移除（PR 2 已有）。
5. 離開網路接到新頁面：新的「離開 controller」（session 佔用，設計 §12 第 4 列唯一新的寫入者）——行為照 leave v4.1。
6. 軟體更新換版面：`SwUpdatePage` 經 `loginFor` + `OwnerConsole`（或同等的 session）在新頁面下跑，整段持有佔用，套用後自己等節點回來（:841、§4.8）；首頁待辦「軟體更新還沒做完」（§4.8）。
7. 設定各頁（設計 §12「設定各頁」——待對設計 §5.x 逐列確認範圍）。

## 1. 事實（main 4acddf6）

| # | 事實 | 證據 |
|---|---|---|
| P1 | 舊控制台的設定：查看設定 / 設定國家 / 設定 Wi-Fi 都是 `_ask` 一個請求，回答只是顯示文字 | nodes.dart:1670、:1694、:1714 |
| P2 | Rust 的 settings 回答只有顯示用的句子（`settings_text`），沒有結構化欄位；新頁面要「目前值」就要一個新的 Rust view（新的介面，要審） | owner.rs:656、:960-961、:1716 |
| P3 | 離開網路已抽成 `leaveFlow(ask, askEnd, left, reread)`，舊控制台與隊員頁共用 | member_ui.dart:264-300；nodes.dart:1146-1150 |
| P4 | 軟體更新頁 `SwUpdatePage(hold, ask, onSetAp, channel, specifierText)`：`ask(waitMs)` 是「節點頁 owner session 上的一個請求（含重新登入）」 | swupdate.dart:86-104；nodes.dart:1590-1640 |
| P5 | `SecureScreen` 已存在 | lib/secure_screen.dart:11 |
| P6 | 狀態頁 `StatusPageView` 有 `onLeave` / `onSendUpdate` | member_ui.dart:345；nodes.dart:1125-1134 |
| P7 | 節點對手機 AP 的規則：名稱 1–32 個 `[A-Za-z0-9 ._~+=,:@%^*-]`、頭尾不是空白；密碼 **12–63** 個同一組字元（不含空白）。不合 → `E_INPUT` reason 13。設計 §5.5 寫的「8–63 個可顯示 ASCII」比節點寬，照設計做會讓節點拒收 | feed/batman-prov/src/node/settingsset.go:60-78、:139-141；254-p3-impl §3.3 表 |
| P8 | 國家只在**沒有入網**時能改（入網 → reason 14）；legacy 節點 → `E_UNSUPPORTED` reason 20；只驗「兩個大寫字母」+ regdb | settingsset.go:80-82、:113-124；254-p3-impl §3.3 |
| P9 | `settings/set` 在節點上最長約 230 s（setkey 預算），helper 上限 300 s、`HelperWait` 330 s。舊控制台用 `_ask` 的預設 15 s 等待（每次寫出重新計時），所以慢一點的設定在舊控制台會顯示「結果不明」 | 254-p3-impl §3.3 時間預算表、:149；nodes.dart:1694-1712（`_ask` 不帶 wait） |
| P10 | `settings/get` 回 1 名稱、2 國家、10 {1 頻道, 2 頻寬}、20 {1 ssid}；**不回密碼**。`settings/set` 成功回套用後的 settings（快取讀不到時回空 map，不算錯） | 254-p3-impl §3.3；settingsset.go:150-160 |
| P11 | `OwnerConsole` 的 `answer` 分支只看 `pollLink` / `sendUpdate`：**不看 `st.left`、不看 `st.sw`**；`sw` 的回答會被當成一般文字回答 | lib/src/flows/owner_console.dart:278-281 |
| P12 | 更新流程的「等節點重開」以時間計：`no_link` / `lost` 只回「10 s 後再讀」，超過 `REBOOT_FOR_MS` 才結束；一次登入花多久不影響判定 | app/rust/batman-proto/src/swupd.rs:848-855、:1066-1073 |
| P13 | 節點頁（PR 2）沒有顯示 info k11 的「沒完成的網路變更」那一行（`StatusView.unfinished`），舊控制台的狀態頁有 | lib/ui/node_page.dart:155-160；member_ui.dart:210-213 |
| P14 | 離開確認對話框的文字由 Rust `leave_confirm_text(last4, netId, adminApplied, memberEntry)` 產生；舊控制台以 `_netNames` 讀手機的 net / mnet 紀錄算後兩個值 | app/rust/bridge/src/api/owner.rs:413-419；nodes.dart:1176-1177、:1206-1230 |
| P15 | `NickPage(app, ui, id)` 已存在（PR 3 的 3.2），預設值是目前暱稱 | lib/ui/add_pages.dart:19-31 |

## 2. 做法

### 2.0 共用：`OpSession`（新，lib/src/flows/op_session.dart）

設定、離開、更新三種頁面都是「拿 session 佔用 → 登入 → 一個或幾個 owner 請求」。PR 3 的建網頁把這段寫在頁面裡；PR 4 有四個頁面要用，抽成一個小類別，**只組合 PR 3 已審的零件**（`loginFor`、`OwnerConsole`、lease 的 `hold` / `pageGone`），規則照 PR 3：

- **兩種用法**（v2，審查 A m8 / B m4：頁面閒著不佔著佔用）：
  - `OpSession.once(app, id, name, ops)`：**一次操作**用（5.6 讀 / 送、5.8 讀 / 送、離開）：`acquire` → 登入 → `ops(c)`（一個或連續幾個請求，例如離開 + 重讀）→ `close()` console → `release()`（先關再放，§4.4；審查 A m11 / B m12）。頁面在兩次操作之間不持有佔用，自動讀取照常。
  - `OpSession.open(app, id, name)` + `run(op)` + `pageGone()`：**整頁持有**，只給更新頁用（設計 §4.8：頁面開著或工作在跑就持有）。
- 拿不到佔用（別的操作在跑）→ 回 `OpReply.busy(name)`，頁面顯示「另一個操作還在進行：X」（同 node_page.dart:71-76）。
- 每一個請求之前要不要重新登入（v2，審查 A M2 / B M2）：`console == null || !console.alive || !上一次回覆.sessionAlive` → 先 `close()` 舊的，再 `loginFor`；這和 PR 3 net_run.dart:262 同一條件、和設計 N2 / T-X17（:839）一致——節點把閒置 300 s 的已登入連線關掉（provd/server.go:31 `IdleAuthed`）之後，下一個請求自己重新登入。
- 登入不是 `ok` → `OpReply.login(end)`，什麼都沒送；畫面用 `loginLine(end)`（PR 3）。
- **頁面不在就不開始**（v2，審查 A M4；PR 3 的 T-R1(c)，net_pages.dart:736）：`OpSession` 有 `_gone`（頁面 dispose 時設），`loginFor` 回來之後、每一個請求寫出之前都檢查；已 gone → 關掉 handoff / console、放佔用、回 `OpReply.gone`，什麼都不送。
- `pageGone()`（只有 open 用法）：設 `_gone`；**不打斷進行中的請求**（審查 B m3）：沒有請求在跑 → `close()` + 放佔用；有 → 等它回來再關、再放（同 net_pages.dart:525-527）。
- 例外：`hold()` 在佔用失效時丟 `StateError`（lease.dart:61）、`OwnerConsole` 同時兩個請求丟 `StateError` → 都轉成 `OpReply.leaseLost` / 程式錯誤的固定句，不冒到頁面（審查 B m10）。頁面在請求期間按鈕停用，所以第二種在正常操作下不會發生。
- **不重送**：一個請求沒有回答（unclear / notSent / ended）就照實回給頁面；使用者再按一次才會再送（PR 3 的規則，舊 `_ask` 的 resend 分支不搬，owner_console.dart:350-352）。
- 「螢幕保持亮著」（v3，審查 C M1）：Kotlin 的 `keepScreenOn` 只是加 / 清 `FLAG_KEEP_SCREEN_ON`，沒有計數（SwUpload.kt:77-83），所以同一時間只能有一個擁有者。
  - `once`：開始時 `true`、結束時 `false`（PR 3 NetRunPage 的做法，net_pages.dart:513-515；設計 :145 螢幕關掉後計時器不可靠；審查 A m6 / B m9）。
  - `open`：**不碰**。更新頁照現況整頁自己管（swupdate.dart:119 `initState` 開、dispose 關；update D9）。負對照：更新頁跑完一次 `ask` 後最後一次 `keepScreenOn` 必須是 `true`。
  - 兩者不會同時存在：同一時間只有一個佔用（`once` 與更新頁不會同時開著）。
- 重新登入只在 `open.run` 的請求之前判斷（v3，審查 C m4）；`once` 在開始時登入一次，裡面連續的請求（例如離開後的重讀）都在同一個 console 上，console 死了就照實回「讀不到」，不重新登入（否則 `after_left` 的截斷會不見）。
- 結局對應（v3，審查 C m3）：Rust 回 `ended` 而且這次請求已經寫出 `sent` 的步驟（`_track.wrote`）→ 當成 unclear；沒寫出 → 「還沒有送出」。
- 這個類別不寫紀錄（四個頁面都不寫，§2.7 / §2.8 / 254-app-leave §4）。

### 2.1 Rust：設定的結構化回答 + `settings/set` 的 `sent`（兩個 Rust 變更）

**(a) `settings/set` 寫出時設 `sent`**（v2，審查 A M1 / B M1）：現在只有 network/leave 的寫出帶 `sent`（owner.rs:752 `sent: verb == LEAVE`，owner.rs:2790 的測試鎖住）。`SendTrack` 沒有 `wrote` 時一律回「還沒有寫入或送出」（member_ui.dart:309），所以設定送出後斷線 / 逾時會被說成沒送出，但節點可能已經換了 AP 或國家。改成 `sent: verb == LEAVE || verb == "settings/set"`。
- 舊控制台：設定按鈕不帶 unclear（nodes.dart:1694、:1714），`sent` 只在帶 unclear 時被讀（`_unclearNow`），所以舊控制台的行為不變。ssh_keys/set 不改（不在本 PR 範圍）。
- Rust 測試：settings/set 的 op/nonce 寫出 `sent == false`、簽章後的寫出 `sent == true`（序列 `[false, true]`）；leave 照舊；ssh_keys/set 仍是 false。負對照：只認 LEAVE。

**(b) 結構化回答：**

- 新 struct `SettingsView { read: bool, name: String, country: String, channel: i64, bw_mhz: i64, ap_ssid: String }`（缺的欄位 = "" / -1；`read = false` = 回答是空 map）。**沒有密碼欄位**（節點不回，P10）。
- `OwnerStep` 加 `settings: Option<SettingsView>`：**只在** `settings/get` 或 `settings/set` 的 `Outcome::Ok` 時設定（owner.rs:960-961 那兩臂）；錯誤回答、其他動詞都是 `None`。顯示文字（`settings_text`）不變，舊控制台照舊。
- 成功的判定：`settings != null`（Rust 只在 Ok 時給）。和 PR 3「成功只看 Rust 的回答」同一原則：判定在 Rust，Dart 不解析文字。
- 測試（Rust）：get / set 的 Ok 各一臂（欄位逐一）、空 map → `read = false`、錯誤回答 → `None`、其他動詞 → `None`；負對照：把 `settings` 也放到錯誤臂、或 set 不設。
- frb codegen 照 PR 3 的方式（WSL，`--no-rust-format`）。

### 2.2 `OwnerConsole` 加的請求（搬移舊控制台的呼叫，加上 P11 的兩個旗標）

| 方法 | Rust 請求 | 等待 | unclear 句 | 回覆多帶 |
|---|---|---|---|---|
| `settings()` | `requestSettings` | 15 s（舊值） | — | `settings` |
| `setCountry(cc)` | `requestSetCountry` | **360 s**（`joinWait`，D2） | 「[REQ_FAIL] 結果不明 — 請重新讀取設定」 | `settings` |
| `setAp(ssid, pass)` | `requestSetAp` | **360 s**（D2） | 同上 | `settings` |
| `leave()` | `requestLeaveNetwork` | `joinWait` 360 s（leave v4.1 §3） | `leaveUnclear`（照舊） | `left` |
| `statusPage(hasNet, hasMnet)` | `requestStatusPage` → `statusView` | 15 s | — | `StatusView?` |
| `askSw(hold, waitMs)` | `requestSw(hold.sw)` | 流程給的 `waitMs` | 一個記號（同舊 `_swUnanswered`，nodes.dart:1598；審查 B m1：沒帶 unclear 時斷線要等計時器，Check / Apply 會卡 340 s） | `SwAction` |

- **更新的時鐘**（v3，審查 D M1）：`swAnswer` / `sw.lost` / `sw.noLink` 一律用 **`hold.now()`**（SwHold 自己的 Stopwatch，swupdate.dart:63-64；`press` 也用它，:345）。Rust 要求同一個更新的每一次呼叫用同一個時鐘（bridge/src/api/swupdate.rs:205-206）；`OwnerConsole` 手上的 `nowMs` 是 AppLink 的 Stopwatch（app_link.dart:57、net_pages.dart:58），**不能**用在更新上，所以 `askSw` 收的是 `SwHold`，不是 `nowMs`。負對照：兩個起點不同的假時鐘，用 console 的時鐘時「設好了，繼續」之後的 30 s AP 重試不發生（swupd.rs:762、:1124）→ FAIL。
- `askSw` 的結局（v3，審查 D m1）：`answer` + sw → 回答的 `SwAction`；`refused` / unclear / notSent / ended / leaseLost → `sw.lost(hold.now())`，**console 當成死掉**（下一次 `ask` 重新登入；舊程式 nodes.dart:1606-1609 在這裡 `_drop`）；`login` / `busy` / `gone` → `sw.noLink(hold.now())`。
- `swAnswer` 只對**正在等的那個請求**的回答算（`_answer` 還沒完成時）；遲到的回答不改 flow（審查 D m8；測試：計時器到期後才到的 sw 回答，flow 的下一個動作不變）。

- `ConsoleReply` 加 `left`（`answer` 臂讀 `st.left`）與 `settings`（`st.settings`）。
- **回答要用回答它的那個 session 算**（審查 A m5 / B m2）：`statusPage` 的 `statusView(...)` 與 `askSw` 的 `swAnswer(sw, now)` 都在 `_run` 的 `answer` 臂裡、用當時的 `s` 同步算好，放進回覆。理由：套用後節點立刻重開，`_lost` 可能在 await 之後先把 `_session` 清掉（舊程式 nodes.dart:1621 也有這個窗口）。離開後的重讀不重新登入（同一個 Rust session 才有 `after_left` 的截斷）；那個 session 不在了 → 重讀 = 讀不到 → `LeaveResult.stale`（leave v4.1 的現有結局）。
- `answer` 臂加 `when st.sw`：完成一個 `ReplyKind.answer`、`text = ''`、帶 `swAction`，**不記 log**（254-app-update D8：bulk/open 的回答帶秘密；舊控制台 nodes.dart:309-313 同樣只回一個記號）。其他結局（unclear / notSent / ended / leaseLost）→ `askSw` 回 `sw.lost(now)`；`OpReply.login` → `sw.noLink(now)`。
- `setAp` 的密碼：Dart `String` 直接進 frb 呼叫，不進 log、不進 `ConsoleReply.text`（Rust 的契約：密碼從不出現在步驟文字，owner.rs:779-780）。

### 2.3 節點頁的分組（設計 §5.5）

節點頁下半改成：
1. 網路（PR 3，不變）。
2. 手機 Wi-Fi：一列「手機 Wi-Fi」→ 5.6。
3. 隊員：PR 5（本 PR 不放，D4）。
4. 軟體更新：一列「軟體更新」→ 9.x；有未完成的更新時副標「還沒做完」。
5. 更多：一列 → 5.7。
- 「技術資訊」與「從這支手機移除這台節點」從節點頁移到 5.7（設計 §5.5 的 5.7 清單）。
- 狀態區加上 P13 的那一行（`v.unfinished`，位置照 `unfinishedUnderVerdict`）：leave v4.1 §2 的行為，PR 2 漏了；離開網路搬到新頁面時一起補。

### 2.4 5.6 手機 Wi-Fi 頁（`WifiPage`）

- 整頁包在 `SecureScreen`（設計 §5.5 :760 原文「這一頁包在 `SecureScreen` 裡」；它設不了 FLAG_SECURE 時整頁不顯示，是既有元件的 fail-closed，secure_screen.dart:41-46。審查 A m1 以為設計只要求欄位，設計原文是整頁，照設計）。
- 打開 → `OpSession.once`：`settings()` → 顯示目前的名稱（`apSsid`；讀不到顯示「讀不到目前的名稱」+「重新讀取」）→ 放掉佔用。
- 欄位：名稱、密碼。密碼欄：`obscureText`，旁邊一顆切換顯示；`autocorrect: false`、`enableSuggestions: false`、`enableIMEPersonalizedLearning: false`、`autofillHints: null`（不讓密碼管理器提示儲存）、`enableInteractiveSelection: false`（不能選取 / 複製）；顯示時鍵盤用 `visiblePassword`（審查 A m3 / B m8）。
- 驗證照**節點的規則**（P7，D1）：名稱 1–32 個允許字元、頭尾不是空白；密碼 12–63 個允許字元、不是 `CHANGE-ME-NOW`（審查 A m2；254-p3-impl §3.3 表）。不合時按鈕不能按，欄位下面一行說哪裡不合（不顯示密碼本身）。
- 送出前一行說明（審查 A m12 / B m8）：「改完之後，正連著這台 Wi-Fi 的手機（例如跑 TAK 的）會斷線，要用新的名稱和密碼重新連」。
- 名稱欄預填讀到的目前名稱，不 trim（節點規則本來就拒頭尾空白，app 照規則顯示不合）。
- 送出：`OpSession.once` 登入成功後、呼叫 `requestSetAp` 的前一刻才把密碼從欄位取出並**清空欄位**（v3，審查 D m6：登入失敗——現場最常見——時不必重打；現況 nodes.dart:1703-1704 也是在送出那一刻清空）。gone 時欄位隨頁面消失。
  - `settings != null` → 「已更新」，名稱顯示回答裡的新值；`read == false`（節點的快取讀不到，settingsset.go:150-160）→「已更新；目前的名稱要重新讀取才看得到」+「重新讀取」（審查 C m12 / D m5）；
  - 錯誤回答 → 顯示節點的原因（Rust `error_text`）；
  - unclear（§2.1 (a) 之後，送出後斷線 / 逾時才會是 unclear）→ 「結果不明 — 請重新讀取設定」+「重新讀取」；
  - notSent → 「還沒有送出」+ 可再送（密碼要重打：欄位已清空，現況）；
  - 登入失敗 / 佔用忙 / gone → 對應的句子，什麼都沒送。
- 從按下送出到結果（含登入）`PopScope(canPop: false)`（審查 A M4）；之後可以離開。

### 2.5 5.8 國家頁（`CountryPage`）

- 打開 → `OpSession.once`：`settings()` → 放掉佔用；目前值顯示「台灣 TW」/「美國 US」/ 其他代碼原樣；讀不到 →「讀不到目前的國家」+「重新讀取」，選單不能用。
- 選單只有 TW、US（設計 §5.5；**不改預設**，U9）。⚠️ A1：TW 在節點 regdb（`/usr/share/morse-regdb/channels.csv`）裡沒有查證（repo 沒有副本；這次 ssh 連不到節點）。不在的話節點以 reason 13 拒絕，畫面照實顯示原因；真機場次查證（§7）。
- 選單只在**這一次 settings 讀到之後**、NodeLink 對這台**新鮮**的讀取說 `nodeState == 1` 且 `netId` 空時可以用（審查 A m4 / B m7）；不新鮮、沒有讀取、或在網路裡 → 不能用，說明「要先離開網路才能改國家」或「先讓手機讀到這台的狀態」（P8；節點也會以 reason 14 拒絕，這行只是先說）。
- 選到和目前不同的值 → 確認對話框（≤ 3 行）：「把這台的國家從 X 改成 Y？」「之後加入網路時，國家會改成那個網路的國家。」（join 會以 ConfirmCountry 把國家改成 netcfg 的值，owner.rs:197-198、:1426；審查 A m4）/「改」「取消」→ `OpSession.once`：`setCountry`。結果處理同 5.6；按下改到結果 `PopScope(canPop: false)`。

### 2.6 5.7 更多（`MorePage`）

- 列：改暱稱、國家（→ 5.8）、離開網路（只在 NodeLink 對這台**新鮮**的讀取 `view.canLeave` 時出現，→ §2.7；審查 A m9 / B m7）、技術資訊（從節點頁搬過來）、從這支手機移除這台節點（從節點頁搬過來，程式不變；成功後直接回首頁（`popUntil` 首頁），不回到已經沒有這台的節點頁（審查 C m9）；移除成功時一併清掉 `AppLink.sw` 裡這台的 hold，審查 A m7 / B m6）。
- 改暱稱（v2，審查 A M3 / B m5）：`NickPage` 存完會 push `AddedPage`（add_pages.dart:41-57），不能直接用。加一個 `rename` 模式：標題「改暱稱」、欄位旁寫「只有這支手機看得到；對別人請報後四碼」、存完 `pop`，不進 `AddedPage`。新增節點流程的行為不變（PR 3 的測試照過）。
- 這一頁本身不拿佔用；每一列進去的頁面各自拿。

### 2.7 離開網路（10.3，`LeavePage`；設計 §12 第 4 列的「離開 controller」）

- 行為基準：254-app-leave v4.1 §2–§4、`leaveFlow`。本 PR 只換 `ask` / `askEnd` / `left` / `reread` 由誰提供：

| leaveFlow 參數 | 舊控制台 | 新頁面 |
|---|---|---|
| `ask` | `_ask(requestLeaveNetwork, wait, retry: false, unclear)` | 在一個 `OpSession.once` 裡：`c.leave()`：`answer` → 文字；其他 → null |
| `askEnd` | `_askEnd` | 那次 `OpReply` 的文字（登入失敗 = `loginLine`、佔用忙、gone 各有固定句；都是「沒有送出」） |
| `left` | `_left` | 那次回覆的 `left` |
| `reread` | `_readStatusPage` | 同一個 `once`、同一個 console 的 `statusPage(...)`：**同一個 Rust session**，所以「回 0 後那一次重讀的截斷」（`after_left`）照舊；不重新登入（console 不在了 = 讀不到 = `stale`） |

- `reread` 要回 `StatusFields?`（member_ui.dart:268）：把 nodes.dart:1157-1203 的「`StatusView` + 紀錄 → `StatusFields`」抽成一個函式 `statusFieldsOf(...)`，舊控制台與新頁面共用，不改判定（審查 A m10）。新頁面只用它的判定句、⚠️ 行、`unfinished` 行。 `teamView` / `updateHint` / `last4` 也在 `_run` 的回答臂裡、用回答的 session 一起算好放進回覆（審查 D m7）。
- 確認對話框：`leaveConfirmText(last4, netId, adminApplied, memberEntry)`；`netId` 來自 NodeLink 對這台新鮮的讀取（5.7 只在新鮮時給這一列，§2.6）；`adminApplied` 與 `memberEntry` 把 nodes.dart:1206-1230 的 `_netNames` 抽成一個函式，兩邊共用，不改判定。和舊控制台的差別：舊的用同一個 session 剛讀到的狀態（nodes.dart:1146-1152），新的用 NodeLink「新鮮」的讀取（最多 300 s 前，core.dart:15；v3 審查 C m5 / D m3 更正）；對話框只決定「之後怎麼再加入」那一句的用字，送出後的結果仍以節點的回答與重讀為準（D7）。
- 頁面流程：確認 →（`once`：拿佔用、登入、`leave`、回 0 就 `statusPage`、關 console、**放掉佔用**；D6）→ 顯示結果句（`screenText`）與重讀到的判定句；放掉佔用之後呼叫 `link.refresh()`（NodeLink 自己的 API，node_link.dart:163），讓 5.7 的「離開網路」列與 5.8 的「先離開網路」在下一輪讀取後就更新，不必等 300 s（審查 D m3）。NodeLink 的狀態仍只有 NodeLink 寫。
- `once` 用 `release()`，不用 `pageGone()`（不受 420 s 的 `goneMax` 限制，lease.dart:96；審查 D m9）；離開頁的 `PopScope` 保證頁面在結果前不會被使用者關掉。
- 不寫任何紀錄（leave v4.1 §4）。
- 從按下確認到結果（含登入，最長約 60 + 360 + 15 s）`PopScope(canPop: false)`、`keepScreenOn`（審查 A M4、m6）。

### 2.8 軟體更新換版面（9.x）

- 行為基準：254-app-update v0.4；`SwFlow` / `SwHold` / `SwUpdatePage` 的邏輯不動，**只換**：
  1. 外觀用 PR 2 的元件（`BatPage` / `BatButton` / `BatCard`），按鈕文字照舊。
  2. `ask(waitMs)` 由 `OpSession.open` 的 `run` 提供（取代 `_askSw`）：
     - 要不要重新登入照 §2.0 的條件（含閒置 300 s 被節點關掉，審查 A M2）；登入不到 → `sw.noLink(now)`（同 `_askSw` 沒 session 時，nodes.dart:1590-1593）；
     - `askSw` 的回答帶 `swAction`（在 `_run` 裡用回答的 session 算好，§2.2）；
     - 其他（逾時、斷線、Rust 結束、佔用失效）→ `sw.lost(now)`，console 視為死掉（同 nodes.dart:1611-1612）。
     - 重開期間每次 `ask` 都會再登入一次；判定由 Rust 依時間做（P12），一次登入多久不影響。
  3. `SwHold` 從舊控制台的欄位移到 `AppLink.sw`（`Map<id, (SwUpdate, SwHold)>`，記憶體，ChangeNotifier；`SwUpdate` 一起存，`request_sw` / `sw_answer` 要它，審查 D m2）。舊控制台保留自己的那份（不共用；兩邊不會同時跑：佔用）。更新頁每次 `_show` 之後呼叫 `AppLink.sw.touched()` 通知首頁（審查 C m8：`last` 由頁面直接改，不會自己通知）。
     - hold 裡的 bearer 與 AP 認證在 Rust 的 `SwUpdate` 裡（不在 Dart 欄位）。現況活到控制台頁面關掉；搬家後活到 `done`、移除節點或 app 結束。這段時間它們只在 app 程序的記憶體裡，和現況一樣不落地、不記 log（審查 C m8，接受，寫進 §5）。
  3a. 更新頁打開時拿不到佔用 → 不開，顯示「另一個操作還在進行：X」（審查 C m10 / D m1）；拿到之後整頁持有，不會中途再 acquire。更新中藍牙被關 → `ask` 的登入回 precondition → `sw.noLink`，流程照現況顯示 Rust 的句子；頁面另外在 NodeLink 的 precondition 成立時顯示 PR 2 的藍牙 / 權限提示列（X7）。
  3b. 去設定手機 Wi-Fi（`goWifi`，審查 C m1）：更新頁 `pageGone` 是先 `close()` 再放佔用，5.6 若立刻 acquire 會被拒。節點頁等更新頁的佔用真的放掉（`reg.current == null` 的通知）之後才開 5.6；最多等 15 s，還沒放就照常顯示「另一個操作還在進行」。
  4. `onSetAp`：更新頁 `pop(goWifi)`，節點頁收到後開 5.6（同 PR 3 的 `goMake`：更新頁的佔用先放，5.6 用 `once` 自己拿）；從 5.6 回來，節點頁的「軟體更新」列帶回同一個 hold。
- 佔用：頁面打開就拿，`dispose` 時 `pageGone`；執行中不能離開（`PopScope(canPop: !_running)`，現況）。所以從「套用」到節點回來（最長約 25 分鐘以上：重開最多 5 分鐘 + 試用最多 15 分鐘 + 傳送；審查 D m9 更正）都持有佔用，期間沒有自動讀取（設計 §4.8）。更新頁的 `keepScreenOn` 照舊（swupdate.dart:123）。
- 首頁待辦「軟體更新還沒做完」（設計 §4.8「已準備、還沒套用」）：`AppLink.sw` 裡這台的 hold 的 `last.buttons` 含 `apply` 或 `applyAnyway`（Rust 的狀態，不看 `uris`；審查 A m7：放棄上傳之後不會留著）。點下去 → 節點頁 → 更新頁。app 被關掉 → hold 消失，待辦也消失（記憶體，現況）；節點上準備好的更新仍在（X23，已知）。
- `AppLink.sw` 的寫入者只有兩個動作、都在 UI 執行緒：更新頁（建立、`done` 後關頁時移除）與「從這支手機移除這台節點」成功時移除（§2.6）。
- 不寫紀錄。

### 2.9 設定各頁（10.1、10.4）

- 10.1 設定頁（PR 2 已有「關於」與開發者選項）加兩列：
  - 「說明」：純文字頁，含設計 :374 的「畫面上的狀態大約每分鐘更新一次，旁邊的時間是讀取的時間」與「對別人說是哪一台時，請報後四碼」。
  - 「換手機 / 手機遺失」（10.4）：純文字，照情境 10（設計 :811）寫做不到的事。
- 10.2 開發者選項：**不變**（D5）。
- 10.5 診斷：PR 6（設計 §12）。

## 3. 介面 / 生命週期

### 3.1 擁有權

| 資源 | 唯一寫入者 | 只讀 |
|---|---|---|
| session 佔用 | `OpSession`：`once` 只在一次操作期間持有（5.6 / 5.8 / 離開）；`open` 在更新頁開著時持有 | NodeLink（等它放） |
| 節點的手機 AP / 國家 | 節點 helper（app 經 owner-op 請求） | app 以 `settings/get` 讀 |
| 節點的網路成員身分（leave） | 節點 helper | app 讀 status / info |
| `AppLink.sw`（SwHold） | `SwHolds` 物件本身（`take(id)` / `drop(id)`，UI 執行緒）；呼叫它的只有更新頁（建立、`done` 後移除）與移除節點成功時（`drop`） | 首頁待辦、節點頁副標 |
| `ui/state-v1` 暱稱 | `UiState.setNick`（PR 3） | 各頁 |
| 手機的金鑰紀錄 | **本 PR 沒有新的寫入者**（離開、設定、更新都不寫；設計 §12 第 4 列的「離開 controller」是佔用的使用者，不寫紀錄） | 離開對話框讀 net / mnet |

### 3.2 契約

| 介面 | 寫 → 讀 | 格式 / 有效 | 缺、過期、壞掉時 |
|---|---|---|---|
| `OwnerStep.settings` | Rust → Dart | 只在 settings/get、set 的 Ok 回答 | `None` = 不是成功；頁面顯示文字回答（fail-closed：不說「已更新」） |
| `ConsoleReply.left` | Rust `st.left` → leaveFlow | 只在 network/leave 回 0 | false = 不重讀（leave v4.1） |
| `ConsoleReply.sw` | Rust `st.sw` → `askSw` | 只在更新請求的回答 | 其他回答 → `lost`（fail-closed：流程重讀） |
| `AppLink.sw` | 更新頁 → 首頁 | 記憶體 | app 被殺 → 沒有（現況） |
| Wi-Fi 名稱 / 密碼 | 使用者 → Rust → 節點 | P7 的規則，app 先驗，節點再驗 | 節點拒絕 → 顯示原因 |
| 國家 | 使用者 → 節點 | TW / US | 入網中 → reason 14 |

### 3.3 生命週期矩陣

| 路徑 | 現況（舊控制台） | 新頁面 | 測試 |
|---|---|---|---|
| 第一次安裝 / 啟動 | — | 不影響（沒有新的紀錄格式；`AppLink.sw` 從空開始） | — |
| 頁面在登入或請求中被關（返回鍵） | 舊控制台可離開 | 按下到結果（含登入）`PopScope` 擋住；被別的方式拿掉頁面（系統、路由）→ `_gone`：登入回來後不送，請求在跑就等它回來再關、再放（§2.0） | T-P1、T-P5 |
| 佔用中閒置，節點關掉已登入連線（300 s，`IdleAuthed`） | `_askSw` 看 `_session` 重新登入 | `console.alive` 為 false → 下一個請求先重新登入（§2.0；N2 / T-X17）。5.6 / 5.8 / 離開用 `once`，閒著時不持有 | T-P4 |
| 設定送出後藍牙斷、provd / helper 重啟、或 360 s 逾時 | 「還沒有寫入或送出」（錯） | `sent` 已設（§2.1 (a)）→「結果不明 — 請重新讀取設定」 | T-W3、Rust sent 測試 |
| 設定在 op/nonce 之前斷線 | 還沒送出 | 同：「還沒有送出」 | T-W3b |
| 請求中藍牙被關 / 權限被收回 | `_lost` → unclear | 同（PR 3 `OwnerConsole._lost`）；下一次 `once` 的登入回 precondition，畫面用 `loginLine`（設計 :837） | T-P6 |
| 螢幕關掉 | 計時器不可靠 | 請求在跑時 `keepScreenOn`（§2.0） | T-P7（呼叫有沒有發生） |
| app 被系統殺 | 結果不明 | 同：節點照做；下次讀取看得到（Wi-Fi / 國家 / 離開都可重讀）；`AppLink.sw` 消失（記憶體，現況） | ⚠️ 無自動測試（現況同） |
| 節點在請求中重開 | 逾時 → 結果不明 | 同（設定 360 s；離開 360 s） | T-W3 |
| 更新：套用後重開 | `_askSw` 重新登入 | `OpSession` 重新登入；判定在 Rust（P12）；回答用回答的 session 算（§2.2） | T-U2 |
| 更新：頁面關了（還沒套用） | hold 在控制台欄位 | hold 在 `AppLink.sw`，首頁待辦 | T-U3 |
| 更新：去設定手機 Wi-Fi 再回來 | pop 回控制台的 Wi-Fi 列 | `goWifi` → 5.6 → 回節點頁 → 更新頁帶回同一個 hold | T-U5 |
| 有 SwHold 時移除這台節點 | — | hold 一起移除，待辦消失 | T-U6 |
| app 升級 / 降級 | — | 沒有持久化格式變更；降到 PR 3 版：新頁面消失，舊控制台仍有 | 不適用 |
| 節點是舊版（沒有 settings 動詞） | 錯誤句 | 錯誤句（`E_UNSUPPORTED` 的原因） | T-W4 |
| legacy 節點 | reason 20 | 同，顯示原因 | T-W4 |
| settings/get 回 `E_BUSY` | 錯誤句 | 「讀不到」+ 原因 +「重新讀取」 | T-W4 |
| 佔用被別的操作拿著 | — | 這次操作不開始，顯示「另一個操作還在進行：X」 | T-P2 |
| app 切到背景（使用者切去別的 app） | 同前景，計時器可能延遲 | 同（螢幕亮著旗標只在前景有用）；請求照常跑，結果回來時頁面更新；已知：背景時計時器不可靠（設計 :145），結局可能是「結果不明」 | ⚠️ 真機看一次 |
| 平台 | Android only | 同 | — |

## 4. 和設計不同的地方

| # | 設計 | 做法 | 理由 |
|---|---|---|---|
| D1 | §5.5：密碼 8–63 個可顯示 ASCII | 照節點：12–63 個 `[A-Za-z0-9._~+=,:@%^*-]`、不是 `CHANGE-ME-NOW`；名稱也照節點的字元集 | P7：照設計做，節點會拒收（reason 13）。設計寫的是 WPA2 的一般規定，節點更嚴 |
| D2 | 舊控制台的設定請求等 15 s | 360 s | P9：節點最長 230 s；15 s 會在正常情況下報「結果不明」 |
| D3 | §4.7「設定」controller | 不另寫 controller：`OpSession` + 頁面 | 每個頁面只有一兩個請求，沒有步驟狀態要持有 |
| D4 | §5.5 節點頁「隊員」分組 | PR 5 | 隊員功能在 PR 5 |
| D5 | 10.2 開發者選項的各項（查看原始設定、SSH 金鑰、文字紀錄、貼上碼、忘記加入中的隊員） | 本 PR 不搬，PR 6 刪舊控制台前搬 | 舊控制台還在，功能沒有少；寫進 #329 checklist |
| D6 | 設計 §5.5「按任何會用節點的操作 → 拿佔用」，沒有說頁面閒著時要不要放 | 5.6 / 5.8 / 離開：一次操作一個佔用，做完就放；更新頁整頁持有（§4.8） | PR 3 安全審查 LOW 3（閒著的頁面佔著佔用，自動讀取全停）；審查 A m8 / B m4 |
| D7 | 舊控制台的離開對話框用同一個 session 剛讀到的狀態 | 用 NodeLink 對這台新鮮的讀取 | 對話框只影響「之後怎麼再加入」的用字；結果仍以節點的回答與重讀為準 |
| D8 | 設計 §8 :874 只要求密碼欄不能切換成顯示；§5.5 :760 寫整頁包在 `SecureScreen` | 照 §5.5：整頁 | 設計兩處不一致，取較嚴的；SecureScreen 設不了時整頁不顯示是既有元件的行為（審查 A m1 / C m7） |

## 5. 安全

- **資產**：節點的手機 AP 密碼（控制誰能連節點的 Wi-Fi）；節點的國家（法規、能不能入網）；節點的網路成員身分。
- **新的輸入面**：Wi-Fi 名稱 / 密碼、國家選單。只有手機上的使用者能輸入；請求經 owner-op 簽章（只有擁有者），節點再驗一次（P7 / P8）。app 端的驗證只是提早說，安全邊界在節點。
- **密碼**：
  - 只存在：輸入欄位（送出時立刻清空）→ 一個區域變數 → frb 呼叫 → Rust 的加密請求。
  - 不進 log、不進 `ConsoleReply.text`、不進 `ui/state-v1`、不進 argv；節點不回傳。
  - `SecureScreen`（不能截圖、不出現在最近使用的 app 縮圖；設不了就整頁不顯示）；IME 不學習；不能選取 / 複製；不讓密碼管理器提示儲存（§2.4）。
  - 驗證：測試輸入一個特徵密碼，斷言 debugPrint 擷取、回覆文字、`UiState` 檔案都不含它（負對照：把密碼放進 log 行，測試 FAIL）；欄位的 `enableInteractiveSelection` / `autofillHints` / IME 旗標各有 widget 斷言（負對照：拿掉旗標）；PR 3 的原始碼鎖涵蓋新檔案。
- **更新**：D8 不變（回答不記 log）；新增的 `sw` 臂加測試：sw 回答不出現在 log 擷取裡（負對照：記 log）。
- **同一支手機上的其他 app**：沒有新的檔案；密碼欄不能複製。
- **被入侵的節點的字串**（v3，審查 C m6 / D m4）：`SettingsView` 的每個字串欄位在 Rust 端經過 `statuspage::shown`（`display_name` 換掉控制 / 格式字元，最多 64 字，statuspage.rs:186-190），和狀態頁的節點字串同一個處理；Rust 測試給一個帶控制字元、超長的 ssid，斷言輸出（負對照：不經 `shown`）。
- **更新的秘密**：搬到 `AppLink.sw` 之後，`SwUpdate` 裡的 bearer / AP 認證活得比現況久（到 `done`、移除節點或 app 結束）；只在程序記憶體，不落地、不記 log。接受。
- **被入侵的節點**：它的錯誤句會出現在畫面上（PR 3 安全審查 LOW 1，同一類，不新增）；它不能讓 app 寫紀錄（本 PR 不寫）；它回假的「已更新」只影響這一台自己的設定（它本來就控制自己）。
- **我們自己的錯**：送出後斷線說成「沒送出」→ 使用者重送 / 拿舊密碼連（審查 A M1 / B M1，§2.1 (a) 修）；頁面不在了才送出 leave（審查 A M4，§2.0 `_gone`）。
- **失敗模式**：成功只在 Rust 給 `settings` / `[LEFT]` 時說；其他一律「沒有成功」「沒有送出」或「結果不明」（fail-closed）。

## 6. 步驟（每步附測試與負對照）

1. Rust：`settings/set` 的 `sent`（§2.1 (a)）、`SettingsView` + `OwnerStep.settings` + 測試；codegen。
2. `OwnerConsole` 的六個方法 + `ConsoleReply.left / settings / swAction`（回答在 `_run` 裡用回答的 session 算）；`console_paths.dart` 的共用表加設定 / 離開列（舊控制台與 OwnerConsole 跑同一張表；設定的 unclear 只對 OwnerConsole）。
3. `OpSession` + 測試：
   - T-P1 `pageGone` 在請求中：不打斷、回來後才關與放；
   - T-P2 佔用忙；
   - T-P3 回答不重送；
   - T-P4 閒著時連線斷了 → 下一個請求先 `loginFor`（負對照：只看 `sessionAlive`）；
   - T-P5 登入途中 gone → 不寫出任何 frame、handoff 關、佔用放（負對照：拿掉 `_gone` 檢查）；
   - T-P6 precondition；T-P7 keepScreenOn；`hold()` 丟 StateError → leaseLost；
   - `once` 結束時先 `close()` 再 `release()`（負對照：反過來）。
4. 5.6 / 5.8 頁 + 測試：
   - T-W1 驗證每條規則（含 `CHANGE-ME-NOW`、頭尾空白、字元集外、長度兩端）；
   - T-W2 送出後欄位清空；
   - T-W3 簽章寫出後斷線 → 「結果不明 — 請重新讀取設定」（守衛在 Rust 測試：settings/set 的 sent 序列，負對照只認 LEAVE；Dart 的假 session 照 Rust 的序列給 sent）；T-W3b op/nonce 前斷線 →「還沒有送出」；
   - T-W4 錯誤句（reason 13 / 14 / 20、`E_UNSUPPORTED`、get 的 `E_BUSY`）；
   - T-W5 密碼不外流（log、回覆、UiState、欄位旗標）；
   - T-W6 國家選單：入網中 / 不新鮮 / 沒讀到都不能用；
   - T-W7 確認對話框（≤ 3 行，取消不送）；
   - T-W8 讀完放佔用（`once` 結束後 NodeLink 可以 acquire）。
5. 5.7 + 節點頁分組 + `unfinished` 行（T-N 系列）；`NickPage` 改名模式（T-N4：從 5.7 存完堆疊上沒有 `AddedPage`；負對照：用新增模式）。
6. 離開頁 + `_netNames`、`statusFieldsOf` 抽出：
   - T-L1 leaveFlow 的三種結局（沒送、送了沒離開、離開 + 重讀）；
   - T-L2 `after_left` 截斷只一次（同一 session 重讀截斷，之後 NodeLink 的讀取不截）；
   - T-L3 結果後佔用已放（負對照：等頁面 dispose 才放）；
   - T-L4 對話框三種句子；T-L5 5.7 只在新鮮讀取時給離開列；
   - 舊控制台的離開測試不改判定照過。
7. 更新頁：`OpSession.open` 的 ask、`AppLink.sw`、首頁待辦：
   - T-U1 一般流程；T-U2 重開時重新登入、回答用回答的 session（負對照：await 之後才取 `_session`）；
   - T-U3 待辦：有 apply 按鈕才出現，放棄 / 完成後消失；
   - T-U4 sw 不記 log；T-U5 `goWifi` 來回帶回同一個 hold；T-U6 移除節點清掉 hold；
   - T-U7 askSw 斷線立刻回 lost（負對照：不帶 unclear 記號 → 等到計時器）；
   - 舊 `swupdate_test` 不改判定照過。
8. 10.1 / 10.4 / 說明。
9. 全套 `flutter test` + Rust 測試 + analyze；每個守衛的突變負對照。
10. 兩位程式碼審查 → 安全審查 → 真機（§7）→ PR。

## 7. 真機（S20 + 04 / 02；開始前取得使用者同意）

- 5.6：讀到目前名稱；改名稱與密碼 → 手機連得上新的 AP；再改回原值。⚠️ 會改節點的手機 AP；**不在對話裡顯示密碼**。
- 5.8：在入網中的節點上選單不能用；國家改動要節點不在網路裡，只在離開網路那一場做（A1：TW 是否被節點接受、改成 US 再改回原值）。
- 離開網路：04 或 02（目前在 `bm-94676ef40105`）→ 離開 → 結果與重讀 → 之後再加入（PR 3 的頁面）。
- 閒置 5 分鐘後再送（T-X17 的真機版）：開 5.6 讀完、等 6 分鐘、送出 → 會重新登入。
- 軟體更新：需要一個更新檔與使用者同意（會重開節點）；不同意就只驗到「選檔、傳送前」。
- 密碼欄：在 S20 上確認不會跳出密碼管理器的儲存提示、不能長按複製（審查 C m11）。
- 每一項先列副作用與還原方式再問。

## 附錄 A. 審查處理

### 第一輪（v1 → v2；docs/design/329-reviews/review-pr4-plan-A.md、-B.md）

| 審查 | 嚴重度 | 處理 |
|---|---|---|
| A M1 = B M1 設定送出後斷線說成沒送出 | MAJOR | §2.1 (a)：Rust `settings/set` 寫出設 `sent`；T-W3 + Rust 測試 |
| A M2 = B M2 只看 `sessionAlive` | MAJOR | §2.0：`console == null \|\| !console.alive \|\| !sessionAlive`；T-P4 |
| A M3 = B m5 `NickPage` 會進 `AddedPage` | MAJOR | §2.6：改名模式；T-N4 |
| A M4 頁面不在了才送出 | MAJOR | §2.0 `_gone`；PopScope 含登入；T-P5 |
| A m1 SecureScreen 整頁 | MINOR | 不改：設計 §5.5 原文是整頁（§2.4 已說明） |
| A m2 `CHANGE-ME-NOW` | MINOR | §2.4、D1、T-W1 |
| A m3 = B m8 複製 / 自動填入 / 鍵盤 | MINOR | §2.4、§5 |
| A m4 TW regdb、join 改回國家、`view == null` | MINOR | §2.5（A1 ⚠️ 真機查）、對話框一句、選單條件 |
| A m5 = B m2 回答的 session | MINOR | §2.2 |
| A m6 = B m9 keepScreenOn | MINOR | §2.0 |
| A m7 = B m6 `AppLink.sw` 清理 / 待辦條件 / 擁有者 | MINOR | §2.6、§2.8、§3.1 |
| A m8 = B m4 頁面閒著持有佔用 | MINOR | §2.0 `once`、D6 |
| A m9 = B m7 離開對話框用的讀取 | MINOR | §2.6 只在新鮮時給列、§2.7、D7 |
| A m10 `StatusFields` 轉換 | MINOR | §2.7 `statusFieldsOf` |
| A m11 = B m12 先關再放；`hold()` 例外 | MINOR | §2.0 |
| A m12 = B m8 AP 上的手機會斷線 | MINOR | §2.4 說明一行 |
| A m13 = B m13 行號 / 路徑 | MINOR | §1 已改 |
| B m1 askSw 的 unclear 記號 | MINOR | §2.2；T-U7 |
| B m3 pageGone 不打斷請求 | MINOR | §2.0 |
| B m10 同時兩個請求 | MINOR | §2.0（按鈕停用 + 例外轉固定句） |
| B m11 / A 矩陣缺列 | MINOR | §3.3 補上 |

### 第二輪（v2 → v3；review-pr4-plan-C.md、-D.md）

| 審查 | 嚴重度 | 處理 |
|---|---|---|
| C M1 OpSession 會關掉更新頁的螢幕保持亮著 | MAJOR | §2.0：`open` 不碰，更新頁自己管；負對照 |
| D M1 更新的時鐘沒寫明 | MAJOR | §2.2：一律 `hold.now()`，`askSw` 收 `SwHold`；兩個假時鐘的負對照 |
| C m1 goWifi 交接 | MINOR | §2.8 3b |
| C m2 T-W3 負對照在 Dart 做不到 | MINOR | 守衛放 Rust 測試；Dart 假物件照 Rust 的序列（§6 第 4 步 T-W3 改寫） |
| C m3 ended 沒對應 | MINOR | §2.0 結局對應 |
| C m4 重新登入範圍 | MINOR | §2.0：只在 `open.run` |
| C m5 = D m3 新鮮是 300 s；離開後列不更新 | MINOR | §2.7 數字更正 + `link.refresh()` |
| C m6 = D m4 SettingsView 字串 | MINOR | §5：Rust `shown` |
| C m7 SecureScreen 偏離 | MINOR | D8 |
| C m8 待辦不通知；秘密活得較久 | MINOR | §2.8 `touched()`；§5 接受 |
| C m9 移除後回首頁 | MINOR | §2.6 |
| C m10 = D m1 更新頁拿不到佔用、藍牙被關；askSw 結局 | MINOR | §2.8 3a；§2.2 結局表 |
| C m11 autofill 旗標要真機確認 | MINOR | §7 加一項 |
| C m12 小地方 | MINOR | §2.4（`read == false`、不 trim） |
| D m2 SwUpdate 要一起存 | MINOR | §2.8 |
| D m5 read == false 顯示 | MINOR | §2.4 |
| D m6 密碼太早清空 | MINOR | §2.4：登入後、送出前一刻 |
| D m7 statusFieldsOf 用 session | MINOR | §2.7 |
| D m8 遲到的 sw 回答 | MINOR | §2.2 |
| D m9 背景、更新時間、goneMax | MINOR | §3.3 加列；§2.8 數字；§2.7 `release()` |

兩個 MAJOR 都是一行層級的規定、各有負對照，v3 凍結不再開計畫審查；實作後的兩位程式碼審查要逐條核對這兩條（同 PR 3 v18 的做法）。
