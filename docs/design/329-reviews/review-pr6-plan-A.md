# #329 PR 6 計畫 v1：審查 A

審查對象：`docs/design/329-pr6-plan.md` v1（main c4905ed）。只審新範圍；舊行為只在被刪或被改時審。
方法：逐條對原始碼查 F1–F11 與 D1–D12 的事實；從現場（S20 + HaLow 節點、隊長 / 隊員、dev / dev3 build）推使用路徑。沒有上機、沒有跑測試（唯讀）。

## 事實查核摘要

| 項目 | 結果 | 證據 |
|---|---|---|
| F1 入口 | ✅ settings_page.dart:66-70、main.dart:313-316；`_open` 在 `_app == null` 時直接 push、不經佔用（main.dart:81-87） | 原始碼 |
| F2 舊控制台功能對表 | ✅ 我抽查的都有新入口：忘記節點 → more_pages.dart:62-110；排除加入中的自己節點 → team_pages.dart:174-183；建網頻道 → net_pages.dart:540-544；放棄加入 → net_pages.dart:321-341；claim 恢復留在 ClaimPage（claim.dart:96、:505-527）。SSH 只有 nodes.dart:1682 | grep |
| F4 | ✅ 但路徑是 `app/rust/batman-proto/src/teamview.rs:16、:20-21`（計畫寫成 `rust/batman-proto`） | 原始碼 |
| F5「（代碼…）只在句尾」 | ❌ 不成立，見 MAJOR-2 | flow.rs:248-249 等 |
| F6 | ⚠️ 只對一半：同類英文還有 `NodeCert({c:?})`、`Broken(w)`、claim.rs 的一整批，見 MAJOR-3 | member.rs:42、:59；claim.rs:19-55 |
| F7 | ✅ `NodeStatusList` 是死碼（main.dart:296 先走閃屏，:311 永遠不到） | 原始碼 |
| F9 / D11「app 沒有任何路徑送 TW」 | ❌ 不成立，見 MAJOR-1 | join2flow.rs:8-15、:483 |
| C-8 | 計畫的 D9 其實就是 review-pr2-r2-C.md:114（MINOR-8）原本建議的修法（「不新鮮時用『上次讀取』」）；後來 r3 E 那輪改成「不顯示」。D9 不是推翻審查結論，而是回到 C 的建議與設計 T2（:41）／:605 | 文件 |

---

## MAJOR

### MAJOR-1　D11 說「app 沒有任何路徑送 TW」不成立；fail-closed 閘門只擋住一條路

**情境**：節點目前是 TW（使用者決定前用舊程式設的）。隊員用 PR 6 的 app 讓它加入網路 → join2 流程問「這台的國家是 TW，要改成 US 才能加入」→ 改成 US → 加入失敗（例如節點回 4 或「另一個網路」）→ join2 依設計把國家**改回 prev_country = TW**（`settings/set {2:"TW"}`）。另一條：隊員加入的網路，其 netcfg 是**別支手機**（較舊版 app、或別隊的 app）簽的，國家欄可能不是 US，app 會照 netcfg 問並送出那個值。

**證據**：
- app/rust/batman-proto/src/join2flow.rs:8-15（國家不同 → 確認 → `settings/set`；失敗 → 「the country is put back」）、:483（`prev_country` 拿來改回）；owner.rs:1474 `ConfirmCountry { have, want }`，`want` = netcfg 的國家（join2flow.rs:427）。
- 本機建網的 netcfg 國家寫死 US：joinflow.rs:18 `COUNTRY = "US"`、:157。所以只有「本機建網」這一半保證 US。
- 這兩條路都不經 `OwnerConsole.setCountry`，D11 的閘門擋不到；T6-9 也只測 `setCountry('TW')`。
- #329「併入 PR 6」最後一項是「PR 6 確認 app 不送 TW」——照計畫的寫法會在 PR / issue 裡留下一句錯誤的保證。

**修法**：二選一並寫清楚（我建議 a）：
(a) 保留「失敗回到之前的狀態」（使用者規則，join2 已審過的行為），把 D11 的保證改寫成精確範圍：「app 自己建網、國家頁只會送 US；join2 失敗時把國家**還原成節點原本的值**（可能是 TW），這是『失敗回到之前狀態』；加入別人建的網路時，國家來自隊長簽過的 netcfg（目前版本的 app 一律 US）」；T6-9 加一條 join2 測試把這個行為鎖住（還原的是原值、不是 US），避免後人把它當 bug 改掉。
(b) 若使用者要求「絕不送 TW」：那是改 join2 已凍結的行為，要另外問使用者並重審 join2。
另外把「節點目前是 TW」時 join2 的確認句、國家頁的「目前：TW（不在可選清單）」在 R-7 情境 8 / 2 各走一次。

### MAJOR-2　T-C4c 拆分規則（D7）與實際字串形狀不符；照「句尾整段拆出」會藏掉下一步，測試方法也不可行

**情境**：S20 上建網兩次被拒，畫面要告訴使用者「請再按一次」。

**證據**（`grep -rn "（代碼" app/rust`）：
- 代碼**不在句尾**、後面接下一步：
  - batman-proto/src/flow.rs:248 `…沒有送出（代碼 3：這支手機的權限或連線有問題）— 請重新連線；仍然如此請找維修人員{tail}`
  - flow.rs:249 `…（代碼 {c}）— 請再按一次；仍然如此請找維修人員{tail}`
  - owner.rs:543 `…（代碼 {code}，原因 {reason}），沒有改動任何東西`
  - owner.rs:556 `…（代碼 3），不會再送；{LATER}`、:557 `…（代碼 {c}），{LATER}`
  - status.rs:182 `還沒連上網路（代碼 {c}：{t}）` 是狀態句的一段，後面可能還有別的段。
- **下一步在括號裡**：rekey.rs:458 `（代碼 11，原因 14：App 的問題，請回報）`——整段拆進技術資訊，主畫面就少了「請回報」。
- Dart 端會把 Rust 句子再組合（計畫自己也說「字串組合的地方」），例如國家頁「讀不到目前的國家：$line」，組合後代碼又不在句尾。
- 「（<英文識別字>: …）」這個形狀在 Rust 裡幾乎不存在；實際的英文括號是 `（not a map）`、`（no device id）`、`（CTRL：…）`（全形冒號）、`（{e}）`、`（{c:?}）` 等（claim.rs:19-55、owner.rs:154-187、member.rs:42/59/122/126/157），規則定義不出來就測不出來。
- T-C4c 說「真的 Rust，經 FRB 的同一函式」：目前 app/test 下 49 處全部是 `RustLib.initMock`，沒有任何測試載入真的 Rust 函式庫（`grep -rn "RustLib.init(" test` = 0）。照寫的做不到；會退化成手抄字串，Rust 改字時不會紅。

**修法**：
1. 規則改成「拆出**第一個**『（代碼 』開頭、到配對的『）』為止的那一段」，括號後面的文字（「— 請再按一次…」「，沒有改動任何東西」「；{LATER}」）**留在主畫面**；括號內若有冒號後的中文下一步（rekey.rs:458 這種），改 Rust 字串把下一步移到括號外（只改字串）。
2. 英文括號不靠 Dart 猜：在 Rust 端統一改成「（代碼 …）」形狀（D8 的作法推廣），Dart 只認「（代碼」一種。
3. 測試分兩半：Rust 端一個語料測試——對每個會產生畫面句的函式（`error_text`、`join2_text`、`leave_text`、`invite_err` 每個 variant、`mupdate_text` 每個 variant、claim.rs 的錯誤、flow.rs:248-249）輸出，斷言「去掉『（代碼…）』之後沒有 ASCII 字母（白名單：App、Wi-Fi、QR、SSH、HaLow、US、MHz、dB）」且「去掉之後仍含下一步」；Dart 端用一份由 Rust 測試**產生並 check-in** 的語料檔（Rust 測試在語料與檔案不同時 FAIL），餵給 `splitCode` / `SayLine`。負向對照：把 flow.rs:249 的「— 請再按一次」吃掉的拆法 → FAIL。
4. ClaimPage 也在範圍（見 MINOR-4）。

### MAJOR-3　D8 只修 `Error::Invalid`；同一個 #329 項目（「英文內部原因顯示在手機上」）的其他來源沒列

**情境**：隊長貼上一份節點憑證過期的申請 → 畫面「申請裡的節點身分沒有通過檢查（Expired）」或 Debug 形式的英文。

**證據**：member.rs:42 `Error::NodeCert(c) => format!("…（{c:?}）")`（Debug，英文）；member.rs:59 `Broken(w) => "中斷（{w}）"`；claim.rs:19 `QR 碼內容看不懂（{e}）`、:20 `（not a map）`、:44-55、:125-138；owner.rs:154、:183-187；member.rs:122、:126、:157。這些都會經 `screenText` 上新畫面（claim.dart:183、join_pages.dart 7 處、team_pages.dart 4 處…）。

**修法**：D8 擴成「所有把英文內部字串放進括號的 Rust 句子」，改成「（代碼 驗證：…）」形狀；MAJOR-2 的語料測試自動涵蓋，T6-6 的「沒有 ASCII 字母」改成對整份語料。

### MAJOR-4　D1 的「再試一次」會留下半個 AppLink：第二個生命週期觀察者、第二個藍牙狀態訂閱

**情境**：現場 S20，`NodeLink` 起不來（例如 `readRecords` 那一步丟例外），使用者按三次「再試一次」。

**證據**：main.dart:150-162 先 `make(...)` 再 `a.link.start(...)`，start 丟例外時 `a` 被丟掉、沒有任何清理。`make` 本身已經做了 `WidgetsBinding.instance.addObserver(_Life(link))`（app_link.dart:168）與 `wireRadio(radio.statusStream, link)`（:170）。`NodeLink` 沒有 dispose（只有 `_disposed` 旗標，node_link.dart:133）。今天沒有重試入口所以只漏一次；D1 加了重試後，每按一次多一組觀察者與訂閱，前後景切換會去 `_pump` 那些沒啟動的 link。這違反「BLE 只有一個擁有者（BleGate）」的前提，計畫的生命週期表沒有這一列。

**修法**：重試只重跑 `start`（`make` 成功的 AppLink 留著重用），或給 AppLink 一個 `dispose()`（移除觀察者、取消訂閱），在 catch 裡呼叫。測試：makeLink 回傳的 link `start` 前兩次丟例外、第三次成功 → 只有一個觀察者 / 一個訂閱（負向對照：不 dispose / 每次重建 → FAIL）。

### MAJOR-5　R-7 計畫少了設計 §9.2 R-7 的必要項目

**證據**：設計 docs/design/329-app-uiux.md:980 R-7 要：情境 1、5、7、8、9 各一遍＋2、3、6（dev + dev2）；**每個「正在連到節點…」的秒數，10 次至少 9 次 ≤ 20 s，超過的歸因**；**每條情境各做一次「關藍牙再開」「節點重開」「切到背景」中斷**；**另外兩次指定中斷（X13 建網確認等待中、X14 軟體更新上傳中，各切背景 30 s）**。計畫 §7 的表只有情境能不能走，以上四類全沒列；情境 3（只用複製文字＋電話核對）併在「2 / 3」沒有分開；另外用的是 dev3，不是設計寫的 dev2（02 現在屬於 dev3，這個替換要寫明理由）。依使用者規則「全套不准默默縮」。

**修法**：R-7 表逐列照 :980 展開（情境 × 三種中斷、X13 / X14、計時欄），把需要同意的節點動作（重燒 02 或 04、OTA = sysupgrade、04 換密碼、02 加 lab key、關 02 / 拔天線）**合成一份副作用＋還原清單一次問**；做不到的（例如沒有未認領節點而使用者不同意重燒）在 PR 與 #329 checklist 逐項寫明，不寫「依同意結果」。

### MAJOR-6　D5 不做全隊頁：理由的前半成立，但後果沒寫完，而且這是 §12 交付項的取消，屬於產品方向

**證據**：設計 §5.6（:768）「`visible` 為 false 就沒有入口（本版一律如此）」、§2.2 表（:178）「N+1 打開後**自動出現**」、F13（:80）「N+1 才打開」、teamview.rs:14「N+1 makes it `true` in a one-line」。設計的契約是：N+1 只改一行常數，頁面就會出現。D5 刪掉 `StatusPageView`（teamView 在 Dart 唯一的呈現者，nodes.dart:1129、:1166）且不寫新頁 → N+1 從「一行」變成「一個新頁面＋審查＋測試」，`member_ui_test.dart` 對 teamView 呈現的測試也隨之消失。「真機不能驗」也不完全對：widget 測試可以餵假的 `TeamView{visible:true,…}`（`team_view_with(true, …)` 本來就為測試留了，teamview.rs:286-289）。

**修法**：建議照 §12 做最小的 6.1 頁（`visible` 才有入口、卡片照凍結文字、用 `team_view_with` / 假 TeamView 做 widget 測試、負向對照 visible=false 時沒有入口），代價小且保住「N+1 一行」的契約；若仍決定不做，要明確問使用者（這是交付範圍，不是技術細節），並把「N+1 不再是一行」寫進 #329 checklist 與設計 §5.6。

---

## MINOR

**MINOR-1　SSH 金鑰頁（D2）的驗證與語意要對齊協定與 Rust。**
- 協定 docs/design/219-protocol.md:223：每行整行符合 `ssh-ed25519 [A-Za-z0-9+/=]{1,200}( [ -~]{0,40})?`、≤ 256 B、0–8 行。計畫寫 ≤ 512 B，允許節點必拒的行（例如中文註解）。改成照抄這條 regex 與 256 B。
- owner.rs:811 註解：`ssh_keys/set` 是**取代之前用 App 加入的金鑰**，不是追加。按鈕叫「加入 SSH 金鑰」，dev 甲加了自己的 key，dev 乙之後加 lab key，甲的就沒了。頁面要寫「這會取代之前用 App 加入的金鑰（節點上其他金鑰不變）」，T6-3 加一條斷言文字存在。
- 加一把 key = 節點 root。剪貼簿可被其他 app 換掉（本機無權限 app 的寫入），送出前顯示 `SHA256:` 指紋請使用者對照筆電 `ssh-keygen -lf`。可選：Rust `request_ssh_keys` 加 `cfg(feature="dev-trust")`，field 版連函式都沒有（舊控制台刪掉後沒有 field 呼叫者，零成本的縱深）。
- 正面：舊啟動頁的「我的節點」沒有 dev 閘門（main.dart:313-316），field 版在 NodeLink 起不來時本來可以進舊控制台、看到 SSH；D1 刪掉它是**縮小**攻擊面，可寫進 PR。

**MINOR-2　D3 / T6-4 的密碼測試放錯層。** 原始設定的文字由 Rust `settings_text`（owner.rs:674-691）產生，它本來就只取 key 20 的 1（SSID），不碰 2；Dart 假回答「含密碼」時頁面照理就會印出來（頁面的工作就是印回答），負向對照「讓頁面直接印原文」在定義上不成立。改成 Rust 測試：`settings_text` 輸入帶 `{20:{1:ssid,2:"pw"}}` → 輸出不含 "pw"。另：`settings_text` 的名稱 / 國家 / SSID 沒經 `statuspage::shown`（對照 :695 `SettingsView` 有），被入侵的節點可塞換行、方向字元；原始設定頁改用 `SettingsView` 或在 Rust 套 `shown`。

**MINOR-3　刪測試的清單要先處理共用 fixture 與機制測試。**
- `test/nodes_update_send_test.dart` 是 13 個測試檔共用的假節點庫（op_session_test、owner_console_*_test、rekey_send_test、open_record_test、more_pages_test、retest_p_pr3_test、settings_pages_test、update_route_test…都 import 它），而它 import `nodes.dart`（:32）。要先把 `FakeNode` 等拆到 test/fakes，否則「刪 nodes_*_test」會連帶炸掉一半測試。
- nodes_pop / paste_pop / persist_pop_test 測的是 `openRawPage` 在請求等待中被 pop 的行為（review r5 I-m1/I-m3 的回歸），機制還在（ClaimPage、ScanPage 用 `RawBusy`）→ 移植到 ClaimPage，不是刪。
- nodes_zero_test（z 歸零）：確認 join_pages_test 有等價斷言再刪。
- member_ui_test 的 `StatusPageView`（:96、:295，含離開按鈕）、`ReadClock`（:241-248）。
- rekey_send_test.dart:167、:203 把 `lib/nodes.dart` 排除在掃描外，刪檔後移除例外。
計畫「既有」那列請改成逐檔表格（檔 → 斷言 → 新位置或移植）。

**MINOR-4　§4「原始佔用剩 ClaimPage（開發者選項與舊啟動頁）」不完整。** 首頁「新增節點」也是 ClaimPage（home_page.dart:244-245，正式流程），ScanPage 也是 `RawBusy`（scan.dart:33）。所以 claim.dart:183/:185 的 `screenText` 屬於 T-C4c 範圍（使用者在正式流程看得到），計畫的「24 個呼叫點」數字也要對（我數到 lib/ui 22 處＋claim.dart 2 處＝24，若是這樣請寫明包含 claim.dart）。

**MINOR-5　D9 細節。** (a) 決定那一列的不是單一節點時（`h.node == null`，例如第 10 列全部不新鮮），要用哪個時間？建議全部的最新 `readWall`，寫「上次讀取」。(b) 設計 :605：讀取時間在未來 → 只寫「之前讀過」；`readWall` 是牆上時鐘，手機改時間會遇到。(c) 設計 :605 的完整句是「上次讀取 HH:MM，當時正常 / 要注意 / 有問題」，D9 只寫時間。(d) `fresh` 為 false 也包含節點自報 stale（core.dart:158 `!s.stale`），這時讀取時間是剛剛，寫「上次讀取 10:42」是對的，但測試要涵蓋這一支。

**MINOR-6　P2-2 認領頁。** 「停止恢復」改 danger 不符設計 :247 / :271（danger = 危險或影響全隊、寫出後果）；停止恢復不破壞東西，用 secondary。另外改版時要保住：`_recovery != null` 時不論 `_qr` 都顯示停止（claim.dart:547-550）、T4「從未完成的認領恢復」（:551-552）與開發版「貼上」（:546）都還在；T6-10 加這三條斷言。

**MINOR-7　舊啟動頁改寫時順手給 ScanPage 加 dev 閘門。** main.dart:323-326「附近的節點（開發用：藍牙測試）」在 field 版也顯示。D1 既然重寫這頁，照 settings_page.dart:65 的 devTrust 規則收起來。

**MINOR-8　D6 診斷頁複製內容要列白名單。** 「每台技術資訊」= `StatusFields.tech`，內容來自節點（statuspage.rs:439-491），含網路代號等；寫明複製的欄位清單，節點字串經 `shown`；T6-5 的「沒有長 hex」保留。

**MINOR-9　D10 `hasChangedListener`。** `_changed` 有其他訂閱者（home_page、more_pages.dart:46…），測試若從首頁 push NetFormPage，關頁後仍為 true。寫明測試只 pump NetFormPage 本身，或改成回傳 listener 數目、斷言前後差 1。

**MINOR-10　小處。** F4 / D5 的路徑少了 `app/`；#329「補測場次留下」的「首頁待辦罕見競爭（PendingNotRemoved）」不在 PR 6 範圍也沒寫留在哪，請在 §8 寫一句（留在 checklist）。

---

## 計數與結論

BLOCKER 0 / MAJOR 6 / MINOR 10

**REJECT（窄）**——方向對，但 MAJOR-1（對 issue 的國家保證是錯的）、MAJOR-2 / 3（T-C4c 規則會藏掉下一步、測試不可行、英文來源沒列全）、MAJOR-4（新重試入口的資源洩漏）、MAJOR-5（R-7 縮水）、MAJOR-6（取消 §12 交付項要使用者拍板或照做）要先改計畫再審一輪整份。
