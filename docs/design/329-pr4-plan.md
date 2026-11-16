# #329 PR 4 實作計畫 v1（基準、新範圍、事實、做法；待審）

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
| P11 | `OwnerConsole` 的 `answer` 分支只看 `pollLink` / `sendUpdate`：**不看 `st.left`、不看 `st.sw`**；`sw` 的回答會被當成一般文字回答 | lib/src/flows/owner_console.dart:265-268 |
| P12 | 更新流程的「等節點重開」以時間計：`no_link` / `lost` 只回「10 s 後再讀」，超過 `REBOOT_FOR_MS` 才結束；一次登入花多久不影響判定 | rust/batman-proto/src/swupd.rs:848-855、:1066-1073 |
| P13 | 節點頁（PR 2）沒有顯示 info k11 的「沒完成的網路變更」那一行（`StatusView.unfinished`），舊控制台的狀態頁有 | lib/ui/node_page.dart:155-160；member_ui.dart:210-213 |
| P14 | 離開確認對話框的文字由 Rust `leave_confirm_text(last4, netId, adminApplied, memberEntry)` 產生；舊控制台以 `_netNames` 讀手機的 net / mnet 紀錄算後兩個值 | owner.rs:413-419；nodes.dart:1176-1177、:1206-1230 |
| P15 | `NickPage(app, ui, id)` 已存在（PR 3 的 3.2），預設值是目前暱稱 | lib/ui/add_pages.dart:19-31 |

## 2. 做法

### 2.0 共用：`OpSession`（新，lib/src/flows/op_session.dart）

設定、離開、更新三種頁面都是「拿 session 佔用 → 登入 → 一個或幾個 owner 請求」。PR 3 的建網頁把這段寫在頁面裡；PR 4 有四個頁面要用，抽成一個小類別，**只組合 PR 3 已審的零件**（`loginFor`、`OwnerConsole`、lease 的 `hold` / `pageGone`），不加新規則：

- `OpSession(app, lease, id)`：頁面打開時由頁面 `acquire(name, session)` 拿到 lease 後建立。拿不到（別的操作在跑）→ 頁面不開，SnackBar「另一個操作還在進行：X」（同 node_page.dart:71-76 的移除）。
- `Future<OpReply> run(Future<ConsoleReply> Function(OwnerConsole c) op)`：
  1. `hold()`；
  2. 沒有 console、或上一次回覆 `sessionAlive == false` → 先 `close()` 舊的，再 `loginFor(lease, id)`；不是 `ok` → 回 `OpReply.login(end)`（什麼都沒送）；
  3. `ok` → `OwnerConsole(handoff, lease, writer, platform, onLost: …)`，跑 `op`；
  4. 放開 hold。
- **不重送**：一個請求沒有回答（unclear / notSent / ended）就照實回給頁面；使用者再按一次，才會重新登入（PR 3 的規則，舊 `_ask` 的 resend 分支不搬，owner_console.dart:350-352）。
- `pageGone()`：頁面 dispose 時呼叫；`close()` console，lease `pageGone`（閒著 = 立刻放；有請求在跑 = 跑完才放，同 net_pages.dart:525-527）。
- 這個類別不寫紀錄（四個頁面都不寫，§2.7 / §2.8 / 254-app-leave §4）。

### 2.1 Rust：設定的結構化回答（唯一的 Rust 介面變更）

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
| `askSw(sw, nowMs)` | `requestSw(sw)` | 流程給的 `waitMs` | — | 見 §2.8 |

- `ConsoleReply` 加 `left`（`answer` 臂讀 `st.left`）與 `settings`（`st.settings`）。
- `answer` 臂加 `when st.sw`：完成一個 `ReplyKind.answer`、`text = ''`、`sw = true`，**不記 log**（254-app-update D8：bulk/open 的回答帶秘密；舊控制台 nodes.dart:309-313 同樣只回一個記號）。
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

- 整頁包在 `SecureScreen`。打開 → `OpSession` → `settings()` → 顯示目前的名稱（`apSsid`；讀不到顯示「讀不到」）。
- 欄位：名稱、密碼（`obscureText`，旁邊一顆切換顯示；`autocorrect: false`、`enableSuggestions: false`、`enableIMEPersonalizedLearning: false`）。
- 驗證照**節點的規則**（P7，D1）：名稱 1–32 個允許字元、頭尾不是空白；密碼 12–63 個允許字元。不合時按鈕不能按，欄位下面一行說哪裡不合（不顯示密碼本身）。
- 送出：先把密碼從欄位取出並**立刻清空欄位**（現況 nodes.dart:1703-1704），再 `setAp`。
  - `settings != null` → 「已更新」，名稱顯示回答裡的新值；
  - 錯誤回答 → 顯示節點的原因（Rust `error_text`）；
  - unclear → 「結果不明 — 請重新讀取設定」+「重新讀取」（重新登入再 `settings()`）；
  - 登入失敗 → `loginLine(end)` +「再試一次」。
- 送出期間 `PopScope(canPop: false)`；之後可以離開。

### 2.5 5.8 國家頁（`CountryPage`）

- 打開 → `OpSession` → `settings()`；目前值顯示「台灣 TW」/「美國 US」/ 其他代碼原樣。
- 選單只有 TW、US（設計 §5.5；**不改預設**，U9）。
- 節點在網路裡（最後一次讀到 `netId` 不空，或 `nodeState` 不是 1）→ 選單不能用，說明「要先離開網路才能改國家」（P8；節點也會以 reason 14 拒絕，這行只是先說）。
- 選到和目前不同的值 → 確認對話框（≤ 3 行：「把這台的國家從 X 改成 Y？」+ 一行影響 /「改」「取消」）→ `setCountry`。結果處理同 5.6。

### 2.6 5.7 更多（`MorePage`）

- 列：改暱稱（→ `NickPage`，P15；欄位旁的說明照設計 §5.5）、國家（→ 5.8）、離開網路（只在 `view.canLeave` 時出現，→ §2.7）、技術資訊（從節點頁搬過來）、從這支手機移除這台節點（從節點頁搬過來，程式不變）。
- 這一頁本身不拿佔用；每一列進去的頁面各自拿。

### 2.7 離開網路（10.3，`LeavePage`；設計 §12 第 4 列的「離開 controller」）

- 行為基準：254-app-leave v4.1 §2–§4、`leaveFlow`。本 PR 只換 `ask` / `askEnd` / `left` / `reread` 由誰提供：

| leaveFlow 參數 | 舊控制台 | 新頁面 |
|---|---|---|
| `ask` | `_ask(requestLeaveNetwork, wait, retry: false, unclear)` | `OpSession.run((c) => c.leave())`：`answer` → 文字；其他 → null |
| `askEnd` | `_askEnd` | 那次 `OpReply` 的文字（登入失敗 = `loginLine`） |
| `left` | `_left` | 那次回覆的 `left` |
| `reread` | `_readStatusPage` | 同一個 session 的 `statusPage(...)`：**同一個 Rust session**，所以「回 0 後那一次重讀的截斷」（`after_left`）照舊 |

- 確認對話框：`leaveConfirmText(last4, netId, adminApplied, memberEntry)`；`netId` 來自 NodeLink 最後一次讀到的 `view.netId`；`adminApplied` 與 `memberEntry` 把 nodes.dart:1206-1230 的 `_netNames` 抽成一個函式，兩邊共用，不改判定。
- 頁面流程：確認 →（拿佔用、登入）→ 送出 → 顯示結果句（`screenText`）與重讀到的狀態；**結果出來後立刻放掉佔用**（不等使用者離開頁面，D6）；之後 NodeLink 照一般規則讀。
- 不寫任何紀錄（leave v4.1 §4）。
- 送出到回答期間 `PopScope(canPop: false)`（最長 360 s）。

### 2.8 軟體更新換版面（9.x）

- 行為基準：254-app-update v0.4；`SwFlow` / `SwHold` / `SwUpdatePage` 的邏輯不動，**只換**：
  1. 外觀用 PR 2 的元件（`BatPage` / `BatButton` / `BatCard`），按鈕文字照舊。
  2. `ask(waitMs)` 由 `OpSession` 提供（取代 `_askSw`）：
     - 沒有 session → `loginFor`；登入不到 → `sw.noLink(now)`（同 `_askSw` 沒 session 時，nodes.dart:1590-1593）；
     - `askSw` 的回答帶 `sw` → `session.swAnswer(sw, now)`；
     - 其他（逾時、斷線、Rust 結束）→ `sw.lost(now)`，丟掉 session（同 nodes.dart:1611-1612）。
     - 重開期間每次 `ask` 都會再登入一次；判定由 Rust 依時間做（P12），一次登入多久不影響。
  3. `SwHold` 從舊控制台的欄位移到 `AppLink.sw`（`Map<id, SwHold>`，記憶體，ChangeNotifier）。舊控制台保留自己的那份（不共用；兩邊不會同時跑：佔用）。
  4. `onSetAp`：更新頁 `pop(goWifi)`，節點頁收到後開 5.6（同 PR 3 的 `goMake`：先放掉更新頁的佔用，再由 5.6 拿）。
- 佔用：頁面打開就拿，`dispose` 時 `pageGone`；執行中不能離開（`PopScope(canPop: !_running)`，現況）。所以從「套用」到節點回來（最長約 20 分鐘）都持有佔用，期間沒有自動讀取（設計 §4.8）。
- 首頁待辦「軟體更新還沒做完」：`AppLink.sw` 裡有 hold，且 `uris` 不空（已經選過檔）且 `last.kind != done`。點下去 → 節點頁 → 更新頁。app 被關掉 → hold 消失，待辦也消失（記憶體，現況）；節點上準備好的更新仍在（X23，已知）。
- 完成（`done`）後關頁 → 從 `AppLink.sw` 移除。
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
| session 佔用 | 拿到它的頁面（WifiPage / CountryPage / LeavePage / 更新頁），經 `OpSession` | NodeLink（等它放） |
| 節點的手機 AP / 國家 | 節點 helper（app 經 owner-op 請求） | app 以 `settings/get` 讀 |
| 節點的網路成員身分（leave） | 節點 helper | app 讀 status / info |
| `AppLink.sw`（SwHold） | 更新頁（加入；完成時移除） | 首頁待辦、節點頁副標 |
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
| 頁面在請求中被關（返回鍵） | 舊控制台可離開 | 送出中 `PopScope` 擋住；dispose 時 `pageGone` 等請求結束才放佔用 | T-P1 |
| app 被系統殺 | 結果不明 | 同：節點照做；下次讀取看得到（Wi-Fi / 國家 / 離開都可重讀） | ⚠️ 無自動測試（現況同） |
| 藍牙在請求中斷 | `_lost` → unclear | `OwnerConsole._lost`（PR 3）→ unclear | PR 3 的 T-C 系列 + T-W3 |
| 節點在請求中重開 | 逾時 → 結果不明 | 同（設定 360 s；離開 360 s） | T-W3 |
| 更新：套用後重開 | `_askSw` 重新登入 | `OpSession` 重新登入；判定在 Rust（P12） | T-U2 |
| 更新：頁面關了（還沒套用） | hold 在控制台欄位 | hold 在 `AppLink.sw`，首頁待辦 | T-U3 |
| app 升級 / 降級 | — | 沒有持久化格式變更；降到 PR 3 版：新頁面消失，舊控制台仍有 | 不適用 |
| 節點是舊版（沒有 settings 動詞） | 錯誤句 | 錯誤句（`E_UNSUPPORTED` 的原因） | T-W4 |
| legacy 節點 | reason 20 | 同，顯示原因 | T-W4 |
| 佔用被別的操作拿著 | — | 頁面不開，SnackBar | T-P2 |
| 平台 | Android only | 同 | — |

## 4. 和設計不同的地方

| # | 設計 | 做法 | 理由 |
|---|---|---|---|
| D1 | §5.5：密碼 8–63 個可顯示 ASCII | 照節點：12–63 個 `[A-Za-z0-9._~+=,:@%^*-]`；名稱也照節點的字元集 | P7：照設計做，節點會拒收（reason 13）。設計寫的是 WPA2 的一般規定，節點更嚴 |
| D2 | 舊控制台的設定請求等 15 s | 360 s | P9：節點最長 230 s；15 s 會在正常情況下報「結果不明」 |
| D3 | §4.7「設定」controller | 不另寫 controller：`OpSession` + 頁面 | 每個頁面只有一兩個請求，沒有步驟狀態要持有 |
| D4 | §5.5 節點頁「隊員」分組 | PR 5 | 隊員功能在 PR 5 |
| D5 | 10.2 開發者選項的各項（查看原始設定、SSH 金鑰、文字紀錄、貼上碼、忘記加入中的隊員） | 本 PR 不搬，PR 6 刪舊控制台前搬 | 舊控制台還在，功能沒有少；寫進 #329 checklist |
| D6 | 離開的頁面 | 結果出來就放佔用 | PR 3 安全審查 LOW 3（閒著的頁面佔著佔用） |

## 5. 安全

- **資產**：節點的手機 AP 密碼（控制誰能連節點的 Wi-Fi）；節點的國家（法規、能不能入網）；節點的網路成員身分。
- **新的輸入面**：Wi-Fi 名稱 / 密碼、國家選單。只有手機上的使用者能輸入；請求經 owner-op 簽章（只有擁有者），節點再驗一次（P7 / P8）。app 端的驗證只是提早說，安全邊界在節點。
- **密碼**：
  - 只存在：輸入欄位（送出時立刻清空）→ 一個區域變數 → frb 呼叫 → Rust 的加密請求。
  - 不進 log、不進 `ConsoleReply.text`、不進 `ui/state-v1`、不進 argv；節點不回傳。
  - `SecureScreen`（不能截圖、不出現在最近使用的 app 縮圖）；IME 不學習。
  - 驗證：測試輸入一個特徵密碼，斷言 debugPrint 擷取、回覆文字、`UiState` 檔案都不含它（負對照：把密碼放進 log 行，測試 FAIL）；PR 3 的原始碼鎖涵蓋新檔案。
- **更新**：D8 不變（回答不記 log）；新增的 `sw` 臂加測試：sw 回答不出現在 log 擷取裡（負對照：記 log）。
- **同一支手機上的其他 app**：沒有新的檔案、沒有剪貼簿。
- **被入侵的節點**：它的錯誤句會出現在畫面上（PR 3 安全審查 LOW 1，同一類，不新增）；它不能讓 app 寫紀錄（本 PR 不寫）。
- **失敗模式**：成功只在 Rust 給 `settings` / `[LEFT]` 時說；其他一律「沒有成功」或「結果不明」（fail-closed）。

## 6. 步驟（每步附測試與負對照）

1. Rust `SettingsView` + `OwnerStep.settings` + 測試；codegen。
2. `OwnerConsole` 的六個方法 + `ConsoleReply.left / settings / sw`；`console_paths.dart` 的共用表加設定 / 離開列（舊控制台與 OwnerConsole 跑同一張表）。
3. `OpSession` + 測試（T-P1 pageGone、T-P2 佔用忙、T-P3 回答不重送、T-P4 session 死了下一次才重新登入）。
4. 5.6 / 5.8 頁 + 測試（T-W1 驗證每條規則、T-W2 送出後欄位清空、T-W3 unclear、T-W4 錯誤句、T-W5 密碼不外流、T-W6 入網中國家不能選、T-W7 確認對話框）。
5. 5.7 + 節點頁分組 + `unfinished` 行（T-N 系列）。
6. 離開頁 + `_netNames` 抽出（T-L：leaveFlow 的三種結局、`after_left` 截斷只一次、結果後佔用已放、對話框三種句子）。
7. 更新頁：`OpSession` 的 ask、`AppLink.sw`、首頁待辦（T-U1 一般流程、T-U2 重開時重新登入、T-U3 待辦出現 / 消失、T-U4 sw 不記 log、`goWifi`）；舊 `swupdate_test` 不改判定照過。
8. 10.1 / 10.4 / 說明。
9. 全套 `flutter test` + Rust 測試 + analyze；每個守衛的突變負對照。
10. 兩位程式碼審查 → 安全審查 → 真機（§7）→ PR。

## 7. 真機（S20 + 04 / 02；開始前取得使用者同意）

- 5.6：讀到目前名稱；改名稱與密碼 → 手機連得上新的 AP；再改回原值。⚠️ 會改節點的手機 AP；**不在對話裡顯示密碼**。
- 5.8：在入網中的節點上選單不能用；國家改動要節點不在網路裡，只在離開網路那一場做（改成另一個再改回原值）。
- 離開網路：04 或 02（目前在 `bm-94676ef40105`）→ 離開 → 結果與重讀 → 之後再加入（PR 3 的頁面）。
- 軟體更新：需要一個更新檔與使用者同意（會重開節點）；不同意就只驗到「選檔、傳送前」。
- 每一項先列副作用與還原方式再問。
