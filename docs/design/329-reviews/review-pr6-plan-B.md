# #329 PR 6 計畫 v1 — 審查 B

審查對象：`docs/design/329-pr6-plan.md` v1（worktree C:/src/Batman-329pr6，main c4905ed）。
基準不重審：`329-app-uiux.md` v12.1、PR 1–5、#349。只審新範圍與被刪 / 被改的舊行為。所有事實都對原始碼查過（file:line 附在每條）。

結論：**APPROVE-WITH-CHANGES**（0 BLOCKER、6 MAJOR、11 MINOR）。MAJOR 修完後請整份再審一次。

---

## MAJOR

### M1. D7 只拆「句尾」的（代碼 …），很多送到主畫面的 Rust 句子裡，代碼在句子中間 → P1-2b 修不掉

- 情境：S20 上按「離開網路」，節點回 11 → 5.7 / 10.3 顯示 `沒有離開網路（節點仍在隊伍網路裡，代碼 11）— 請再按一次…`。代碼後面還有「— 下一步」，所以不在句尾，D7 的 `splitCode` 拆不到，主畫面照樣出現「代碼 11」。p1p2-check :43 寫 P1-2b 時**點名的就是這一句**（flow.rs:255）。
- 證據（代碼不在句尾，或括號裡還有中文）：
  - `app/rust/batman-proto/src/flow.rs:248`、`:249`、`:255-257`（離開，後面接「— …」）
  - `app/rust/bridge/src/api/owner.rs:543`（`…（代碼 {code}，原因 {reason}），沒有改動任何東西`）、`:556`、`:557`（`…（代碼 {c}），{LATER}`）
  - `app/rust/bridge/src/api/replay.rs:133`（`…（{what}，代碼 {c}），已停止；紀錄先保留`，經 claim.dart:183 送到新的「新增節點」頁，home_page.dart:245）
  - `app/rust/bridge/src/api/rekey.rs:458`（`（代碼 11，原因 14：App 的問題，請回報）`：整段拆走的話，「請回報」這個下一步會從主畫面消失）
  - `app/rust/batman-proto/src/status.rs:182`（`（代碼 7：SEARCHING）`）
  - 組合字串：join_pages.dart:629 是括號裡又有括號；join_pages.dart:642 把兩句用 `\n` 接起來，第一句的代碼會落在中間
  - 規則 2 拆不到的英文：member.rs:41 `Error::NodeCert(c) => …（{c:?}）`（Debug 名稱，沒有冒號）；join_pages.dart:102/260/381/400/602、team_pages.dart:104/294 的 `e.runtimeType`；claim.dart:495 的 `認領中斷：$e`
- 修法：列出每一個會產生「代碼」或英文的函式（上面這張表，再用 `grep -rn "代碼\|{.*:?}" app/rust` 補齊），每一個都要決定怎麼處理：
  - 把 Rust 字串改成「主句（＋下一步）＋句尾（代碼 …）」（T8 允許只改字串）；或
  - 讓 `splitCode` 定義句中括號怎麼拆，並保留括號裡的中文下一步。

  T-C4c / T6-6 要逐一跑過每一個這類函式，不能只跑 `error_text`；P1-2b 必須等這些都處理完才能標 ✅。

### M2. T-C4c 寫的「真的 Rust，經 FRB 的同一函式」在現有測試設施下做不到

- 證據：
  - `error_text` 是私有的 `fn`（owner.rs:667），沒有經 FRB 匯出；
  - `app/test` 裡沒有任何一個測試載入真的 Rust 函式庫：`grep "RustLib.init("` 0 筆，全部都是 `RustLib.initMock(api: …)`（例如 claim_flow_test.dart:138）。

  照計畫寫，最後只會變成「假 API 回一句手寫的字串」，那是在測 Dart 對自己的假資料，不是規則 2 對 Rust 輸出的檢查（違反「測試要真」）。
- 修法：Rust 測試把 M1 那張表的每個函式、對固定輸入的輸出，寫成一個簽入版本庫的 fixture（JSON），並斷言 fixture 是最新的（Rust 字串改了、fixture 沒更新 → cargo test FAIL）。Dart 的 T-C4c 讀這個 fixture 經 `SayLine` 渲染。負向對照：拿掉拆分 → Dart FAIL；改一句 Rust 字串但不更新 fixture → cargo FAIL。

### M3. D11「app 沒有任何路徑送 TW」不成立：加入失敗時的還原會把節點原本的國家送回去

- 情境：某台隊員節點目前是 TW（PR 4 的國家頁現在就提供 TW，settings_pages.dart:233）。加入網路時使用者在 `_askCountry` 按「改」→ 先送 `settings/set US`；加入明確失敗 → join2 把國家還原，送出 `settings/set {2: prev_country}`，也就是 `TW`。
- 證據：
  - `app/rust/batman-proto/src/join2flow.rs:482-484`（`Op::Revert` 送 `prev_country`）、`:489-497`（`fail` 先還原國家）；
  - `prev_country` 來自節點自己的 `settings/get`（:453-456）；
  - Rust `request_set_country`（owner.rs:819-822）沒有閘門。

  #329「併入 PR 6」最後一項是使用者明確要求的「PR 6 確認 app 不送 TW」，計畫給的確認是錯的。
- 修法：計畫要寫明這條路徑，並定案。建議：照「失敗就回到之前的狀態」保留還原（還原到 TW 是回到原狀，不是 app 自己選了 TW），在 PR 說明與 #329 寫清楚「唯一會送非 US 的路徑是 join 失敗時的還原，送的是節點原本的值」；再加一個 Rust 測試鎖住這個行為。§5 的「不會送非 US」與 §6 的 fail-closed 句子要一起改。另外，要不要在 Rust 的 `request_set_country` 也擋（不在允許集合 → Err），一併定案。

### M4. D4 的理由與凍結設計不符：文字紀錄的來源是 `NodeLink`，不是舊控制台

- 證據：
  - 設計 §4.1 資源表（329-app-uiux.md:342）：「文字紀錄（開發者選項）｜`NodeLink`（記憶體環狀 500 行）｜開發者選項頁」；
  - 實作已經有這個環狀紀錄（`app/lib/src/nodelink/core.dart:141-147`，`log` / `logMax = 500`），目前只經 `trace` 印到 logcat（app_link.dart:153）；
  - 設計有好幾處把事件「寫進文字紀錄」，其中包括安全事件：身分不符（:411）、420 s 收回佔用（:576）、寫入失敗（:607）。

  所以這不是「做一個空的紀錄頁」，U2-2（空入口）的理由不成立。刪掉之後，現場的維修人員在 app 裡完全看不到這些事件（只能接 adb）。
- 修法：二選一。
  - (a) 開發者選項加一頁唯讀的「文字紀錄」：顯示 `NodeLink.mask` 過的 `core.log`（node_link.dart:79-80 的遮罩），可複製，T-S4 的檢查套到這一頁。成本很小。
  - (b) 照「縮範圍要進原單 checklist」，把這條偏離用**正確的理由**寫進 #329 與 PR 說明。

  建議 (a)。

### M5. D2 的 SSH 頁把「取代」說成「加入」；驗證規則和節點的不一致；沒有撤銷的路徑

- 證據：
  - 節點 `sshKeys`（`feed/batman-prov/src/node/node.go:839-882`）：保留所有**不是 app 加的**行，把 app 加過的那一組**整組換成**這次送來的 `lines`（`next.SSHKeysAdded = lines`）。Rust 的註解（owner.rs:811-813）也這樣寫。
  - 節點的規則：`len(list) ≤ 8`；每行 ≤ 256 byte；不能有 CR/LF；而且要符合 `^ssh-ed25519 [A-Za-z0-9+/=]{1,200}( [ -~]{0,40})?$`（node.go:752）。
- 會發生的事：
  - 在 dev 的手機上加入 B 的公鑰 → 之前用 app 加入的 A 的公鑰被**默默拿掉**，A 從此 SSH 不進去；按鈕上卻寫「加入」。
  - 計畫的驗證是 ≤ 512 byte、只檢查 base64 能不能解，比節點寬：結尾註解有中文、超過 40 字元、或 base64 超過 200 字元時，app 會送出，節點回 ESchema「key line rejected」，使用者不知道錯在哪。
  - 計畫不允許送空的清單，所以 app 加入的金鑰沒有辦法撤銷；手機遺失或金鑰外洩後，只能重燒。
- 修法：
  - 頁面和按鈕寫實際語意，例如「設定由 App 加入的 SSH 金鑰（會取代之前由 App 加入的）」；
  - 允許 0–8 行，0 行 =「移除 App 加入的金鑰」，要另外確認；
  - app 端的驗證逐字照搬 node.go:752 的規則與上限；
  - T6-3 加上「多行（≤ 8）合法」「0 行要先確認」「中文註解 → 不送」三個案例。

### M6. 真機 R-7 的範圍比設計少

- 證據：設計 §9.2 R-7（329-app-uiux.md:980）除了逐條走完情境，還要求：
  - 每條情境各做一次「關藍牙再開」「節點重開」「切到背景」的中斷；
  - 記錄每次「正在連到節點…」的秒數，10 次至少 9 次 ≤ 20 s，超過的要歸因；
  - 另外兩次指定的中斷（X13 / X14：建網後的連線確認中、軟體更新上傳中，各切背景 30 s），並和 main 的 app 對照。

  計畫 §7 的表只列了情境和需要的同意，以上都沒有。依「範圍從規格逐列推」與「全套不准縮水」，這算漏項。
- 修法：把 R-7 的原文逐列抄進計畫的真機表，每列標上能不能做、需要什麼同意；做不到的，在開場前問使用者，不要默默略過。

---

## MINOR

1. **認領頁的改動會打壞既有斷言，計畫沒有列怎麼搬。**
   - 「沒有碼時不顯示『認領』」之後，`button(t,'認領').onPressed isNull` 這類斷言在找不到按鈕時會直接丟例外：claim_scan_test.dart:76、:108、:126；claim_flow_test.dart:225、:317（R6）；claim_replay_page_test.dart:278（R6）。
   - 有碼之後「掃描 QR」改名成「重新掃描」，claim_scan_test.dart:62 / :85-91 第二次點 `find.text('掃描 QR')` 會找不到。
   - 計畫要寫清楚：
     - R6 的語意改成「認領按鈕不在」來斷言，不能刪掉；
     - T4（`_fromPending`，沒有 QR，`_qr == null`）恢復進行中，「停止恢復」照樣顯示（claim.dart:548-551 目前和 `_qr` 無關，改版時不能被新的條件吃掉）；
     - 開發版的「貼上 QR 碼（開發用）」放在哪裡（claim_replay_page_test.dart:501 用的是 OutlinedButton）；
     - 「重新掃描」要加進 `Btn` 表（T-C4b）。
2. **D3「原始設定」不是完整內容，也沒有過濾節點字串；T6-4 的負向對照測不到要守的東西。**
   - 顯示的是 `settings_text`（owner.rs:674-690）：只有名稱、國家、頻道、頻寬、SSID 這幾項（白名單），和 `SettingsView` 一樣，只多了名稱與頻道。
   - 而且 `settings_text` 沒有像 `settings_view`（:704）那樣經 `statuspage::shown`，所以節點送來的控制字元 / bidi 字元會原樣出現在一個可以複製的頁面上。
   - 密碼不會出現，是 Rust 白名單的功勞；Dart 的假回答帶密碼，頁面一定會照印，所以 T6-4 寫的負向對照沒有意義。
   - 修法：
     - 加 Rust 測試：回答帶 `{20:{1:ssid,2:"pw"}}` → `detail` 不含 pw；負向對照：`settings_text` 印出 20.2 → FAIL；
     - `settings_text` 的字串改經 `shown`；
     - D3 的文字改成實際內容。
3. **D6 的資料名稱不對。**
   - `NodeLink` 沒有 `StatusFields.tech`。每台的技術資訊是 `core.states[id].extra` 為 `StatusView` 時的 `.tech`（home_page.dart:42；owner.dart:603-629）。
   - `KeyGate` 實際的類別是 `KeyAbilities`（key_abilities.dart:9），而 `SettingsPage` 拿不到它（settings_page.dart:20-23，要另外接進來）。
   - app 版本已經有來源：`appVersion` platform method（settings_page.dart:96），沿用即可，不要加新的套件。
4. **後四碼大寫改錯地方。** Dart 的 `last4()` 已經是大寫（home_logic.dart:8）。小寫的「…7d2c」來自 Rust 字串：owner.rs join2 `Applied` 的 `…{last4}`（OwnerSession.last4 是 device_id 的小寫尾巴，:756）、flow.rs `leave_confirm(last4)`（10.3）、rekey.rs `MissingOwn` / `Removed`（8.4）。要改 Rust 字串，不是改共用的 Dart 函式。
5. **§4「原始佔用的使用者剩 ClaimPage（開發者選項與舊啟動頁）」不完整。** 主路徑首頁的「新增節點」也是原始佔用（home_page.dart:245 `openUnderLease`），`ScanPage` 也是（settings_page.dart:76-78、scan.dart）。
6. **D1「再試一次」的生命週期。**
   - `AppLink.create` 是單例（app_link.dart:104-105），重試會在**同一個** `NodeLink` 上再呼叫一次 `start`。如果第一次是在 `core.startup` 之後才失敗，第二次就會重複啟動。
   - T6-2 只測了 `makeLink` 丟例外，要再加「`start` 丟例外 → 再試一次 → 只有一輪讀取在跑」。
   - 另外，`_open` 在 `_app == null` 時把 `ClaimPage(ble: null, use: null)` 推上去，沒有佔用（main.dart:83-86），而這時單例的 `BleGate` 可能已經建好了。這是現況，至少在計畫裡寫明。
7. **D10 用 `hasListener` 分不出來。** `_changed` 是 broadcast，CountryPage（settings_pages.dart:260）、首頁、節點頁都會訂閱，所以頁面底下只要還有任何訂閱者，關頁後仍是 true。改成提供訂閱者計數（或關頁前後的差），測試斷言「開頁 +1、關頁 −1」。
8. **D9 沒定義彙總列。** `h.node == null` 的列（不是在講某一台）而且沒有任何一台是新鮮的時候，要顯示什麼沒有寫（home_page.dart:283-286）。
9. **p1p2-check 還有幾項 ⚠️ 沒有出現在 §3，也沒寫不做的理由。**
   - P2-5：9.2「開始傳送」沒有渲染（:59）；
   - 2.4 沒有標題列（:95-96）；
   - phone_wifi / country 只有被佔用狀態的畫板（:83-84）。

   另外，#329「補測場次留下」的「首頁待辦罕見競爭」也沒說是在 PR 6 處理，還是留在 checklist。
10. **生命週期矩陣缺新頁面的列。** SSH / 原始設定 / 診斷三頁要補：頁面在請求中被關掉（OpSession 會把佔用留著）、藍牙被關、節點重開、切到背景、field 版本（沒有入口；診斷頁所有版本都有）。SSH 在結果不明時，因為是整組取代、重送是冪等的，可以把「再試一次」安全的理由寫進去。
11. **D8 只改了 `Invalid`。** 同一個函式裡的 `Error::NodeCert(c) => …（{c:?}）`（member.rs:41）還會把英文 Debug 名稱顯示在主畫面；可以併進 M1 的清單一起處理。

---

## 查過、沒有問題的部分

- F4：`WRITE_MESH_ADDR = cfg!(feature="team-write")`；release 帶這個 feature 會 `compile_error!`（teamview.rs:16、:20-21）。D5 的偏離有根據。
- F7：`NodeStatusList` 是死碼。main.dart:296 在 `_ok && _app != null` 時一律回閃屏，所以 :312 那一行永遠到不了。
- 刪 `member_ui.dart` 的部分（`StatusPageView`、`ControlsAndLog`、`ReadClock`、`readTime`、`hms`、`verdictColor`、`teamLogLine`）：除了 nodes.dart 與 member_ui_test.dart，沒有其他使用者。more_pages.dart:203 只在註解裡提到 `StatusPageView`。`StatusFields`、`leaveFlow`、`showDupNote`、`SasShowView`、`forgettable`、`forgetNotice`、`sendLeave` 等都還有人用，要留著。
- SSH / 原始設定走 `OpSession.once`（op_session.dart:84-130）：session 佔用 → `loginFor` → console → 先關 console 再放佔用。這和設計 :634（「session / 原始」）以及 §4.3.9 / §4.4 一致。`setCountry` / `setAp` 的 `endedAfterSent` 模式可以直接套到 `sshKeys`。
- 原始設定的回答不會含 AP 密碼：`settings_text` 是白名單（owner.rs:674-690）。問題只在 MINOR 2 講的過濾。
- 加入時的國家問題：`country_question` 的 want 一定是 `joinflow::COUNTRY = "US"`（joinflow.rs:18），和 D11 不衝突。唯一的問題是 M3 的還原路徑。
- 診斷頁的技術資訊（statuspage.rs:427-491）沒有秘密，也沒有 ≥ 32 字元的 hex。

## 判定

**APPROVE-WITH-CHANGES**。M1–M6 要在實作前改進計畫，改完後整份再審一次。
