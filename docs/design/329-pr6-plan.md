# #329 PR 6 計畫（v6，凍結）：刪舊控制台、全隊頁、診斷頁、顯示規則補完、國家、P1 / P2 收尾

基準（已審過、不重審）：`docs/design/329-app-uiux.md` v12.1（凍結）、PR 1–5 與 #349 已合併的行為（main c4905ed）。本計畫只列**新範圍**；舊行為只在被刪或被改時列出。路徑相對於 repo 根（app 程式在 `app/`）。

依據：設計 §12 PR 6 列（:1070）＋ #329「併入 PR 6」段（使用者 2026-11-18 決定）＋ `docs/design/329-reviews/p1p2-check.md` 的部分解項目。

v1 → v2：第一輪 A（0 / 6 / 10，REJECT 窄）、B（0 / 6 / 11，APPROVE-WITH-CHANGES）。v2 → v3：第二輪 C（0 / 4 / 9）、D（0 / 4 / 12），都是 APPROVE-WITH-CHANGES；全隊頁由使用者決定照設計做完整版（2026-11-18）。v3 → v4：第三輪 E（0 / 3 / 13）、F（0 / 5 / 11），APPROVE-WITH-CHANGES。v4 → v5：第四輪 G（0 / 2 / 8）、H（0 / 3 / 12），APPROVE-WITH-CHANGES。v5 → v6：第五輪 I（0 / 1 / 6）、J（0 / 1 / 11），APPROVE-WITH-CHANGES（同一個 MAJOR）。逐條對應在文末 §9。

## 1. Reality check（main c4905ed，2026-11-18；只讀）

| # | 事實 | 證據 |
|---|---|---|
| F1 | 舊控制台 = `NodesPage`（app/lib/nodes.dart，1776 行，`RawBusy` 原始佔用）。入口兩個：開發者選項「舊版控制台」（settings_page.dart:62-71，devTrust）；舊啟動頁的「我的節點」（main.dart:313-316，**沒有 dev 閘門**，只在啟動檢查通過但 `NodeLink` 起不來時出現，main.dart:150-162） | 原始碼 |
| F2 | 舊控制台的功能在新畫面都有，除了：(a) **SSH 金鑰**（`requestSshKeys` 只有 nodes.dart:1683 呼叫）；(b) 原始設定的完整內容；(c) 狀態頁的全隊段（`StatusPageView` + `teamView`，只有 nodes.dart:1129、:1166 用） | Explore 報告逐項對表；兩位審查抽查屬實 |
| F3 | 02（dev3 的 7C31）要還原需要先加回 lab SSH key，唯一入口是舊控制台 | #329 :200-201 |
| F4 | `teamView.visible` 在可出貨 build 永遠 false（app/rust/batman-proto/src/teamview.rs:16、:20-21）。但設計契約是「N+1 只改一行常數，頁面自動出現」（§2.2、§5.6），所以頁面要先存在 | 審查 A-M6 |
| F5 | 「代碼」在 Rust 句子裡有多種形狀，**不只句尾**：`（代碼 N）— 請再按一次`（flow.rs:249）、`（代碼 3：這支手機的權限…）— …`（flow.rs:248）、`（節點仍在隊伍網路裡，代碼 11）— …`（flow.rs:257）、`（代碼 11，原因 14）`（owner.rs:543、:671）、`（代碼 6，status）`、`（代碼 6，原因 20，settings/set）`（owner.rs:1779-1782）、`（代碼 11，原因 14：App 的問題，請回報）`（rekey.rs:458）、`（{what}，代碼 {c}）`（replay.rs:133）、`（代碼 7：SEARCHING）`（status.rs:182）、`swupd.rs:910` `status：代碼 N`、swupd.rs:1238 半形逗號 | grep；審查 A-M2、B-M1 |
| F6 | 英文內部字串到主畫面的來源：`Error::Invalid(w)`（member.rs:37、rekey.rs:352）、`NodeCert({c:?})`（member.rs:41-42）、`Broken(w)`（member.rs:59）、claim.rs:19-55、owner.rs:154-187 的一批；Dart 端 `${e is String ? e : e.runtimeType}`（join_pages.dart:103 等）、claim 的 `認領中斷：$e` | 審查 A-M3、B-M1 |
| F7 | 首頁狀態區資料不新鮮時不顯示時間（home_page.dart:283-286、:315）；`NodeStatusList`（node_list.dart）只在 `_ok && _app != null` 時建，但那時 build() 走閃屏（main.dart:296）→ 死碼 | 原始碼 |
| F8 | `NetFormPage` 訂閱 `a.link.changed`、dispose 取消（net_pages.dart:182-206）；`changed` 是 broadcast，`hasListener` 會被其他訂閱者（首頁）干擾 | 審查 A / B |
| F9 | 國家：選單 `{'TW','US'}`（settings_pages.dart:233）→ `setCountry`。**另一條送國家的路**：join2 加入失敗時 `Op::Revert` 把節點**自己原本的**國家送回去（app/rust/batman-proto/src/join2flow.rs:8-15、:482-484）。加入時問的國家 = netcfg key 5；本 app 建網一律寫 US（joinflow.rs:18） | 審查 A-M1、B-M3 |
| F10 | 開發版認領頁：輸入框在最上面（標籤截斷）；「掃描 QR」「認領」「停止恢復」都是 primary（claim.dart:540-553） | 原始碼 |
| F11 | 沒有診斷頁；`SettingsPage` 沒有拿到 `KeyAbilities`；每台的技術資訊在 `NodeLinkCore.states[id].extra`（`StatusView.tech`） | 審查 B |
| F12 | `ssh_keys/set` = **整組取代** app 加過的金鑰（feed/batman-prov/src/node/node.go:839-872）；每行要符合 `^ssh-ed25519 [A-Za-z0-9+/=]{1,200}( [ -~]{0,40})?$`、≤ 256 B、無 CR / LF，0–8 行（node.go:752、:848；219-protocol.md:223）。0 行 = 移除 app 加過的全部 | 審查 A / B-M5 |
| F13 | `NodeLinkCore.log` 是 500 行環狀紀錄（core.dart:141-147，設計 :342）——設計 10.2「文字紀錄」的來源是它，不是舊控制台 | 審查 B-M4 |
| F14 | 4.1 / 10.3 / 8.4 的小寫「…7d2c」來自 Rust 字串（rekey.rs:25 `last4`、:452-517；owner.rs:1728），Dart 的 `last4()`（home_logic.dart:8）本來就大寫 | 審查 B |
| F15 | `AppLink` 的 `make` 已註冊生命週期觀察者與藍牙訂閱（app_link.dart:168、:170），`start` 失敗後沒有清理 | 審查 A-M4、B |
| F16 | `nodes_update_send_test.dart` 是 13 個測試檔共用的假節點庫；pop 類測試（nodes_pop / paste_pop / persist_pop）測的原始佔用機制還在（ClaimPage 用） | 審查 A |

## 2. 決定

| # | 決定 | 理由 |
|---|---|---|
| D1 | **刪 `NodesPage`**、兩個入口、只有它用的程式（`StatusPageView`、`ControlsAndLog`、`ReadClock`、`NodeStatusList`；兩位審查確認沒有其他使用者）。舊啟動頁在 `NodeLink` 起不來時：原因 +「請完全關閉 app 再開；仍然如此請找維修人員」+ 技術資訊；**不加「再試一次」**（F15：重試會在同一個 `AppLink` 上留半套訂閱）。現有「認領節點」保留；「附近的節點」加 devTrust 閘門（現在 field 版也看得到）。 | 設計 §12；F15 |
| D2 | **開發者選項「SSH 金鑰」頁**（devTrust）：選一台自己的節點 → 多行輸入（0–8 行）→ 每行照 F12 的規則驗（同一個 regex、≤ 256 B）（輸入先去掉每行**行尾**的 `\r` 與空白行，剪貼簿常帶 CRLF；行中間還有 CR → 該行不合格）→ 每行顯示 SHA256 指紋（Rust 新 sync 函式 `ssh_fingerprint(line)`：base64 解第二欄 → sha256 → base64 **不帶 `=`**，同 ssh-keygen；解不開 → 該行不合格）讓使用者核對 → 按鈕「設定 SSH 金鑰（取代之前由 app 加入的）」；頁面固定一行說明「送出的這一組會取代之前由 app 加入的全部金鑰」；0 行時按鈕是 danger「移除 app 加入的全部 SSH 金鑰」並確認，說明另寫「如果這把金鑰本來就在節點上（不是 app 加的），也會被一起移除」（node.go:862-873）。成功句改成「SSH 金鑰已設定」/「已移除」（`verb_text("ssh_keys/set")` 改「設定 SSH 金鑰」，owner.rs:629、:1009；只改字串）。走 `OwnerConsole.sshKeys(lines)`（新方法）→ `requestSshKeys`，`OpSession.once` session 佔用 + `loginFor`（同 5.6）。結果在原位；斷線 = 結果不明，重送同一組是等冪的（整組取代）。 | F2(a)、F3、F12 |
| D3 | **開發者選項「查看節點設定」**（Rust 回的是白名單欄位）：選一台 → `OpSession.once`（session 佔用 + `loginFor`，同 5.6）→ `OwnerConsole.settings()` → 回答文字放在可複製的區塊。Rust `settings_text` 白名單、不含 AP 密碼（B 已核）；**節點字串經 `shown` 清理**（換行、方向控制字元）——改在 Rust，Rust 測試鎖：假回答帶密碼欄位與控制字元 → 輸出不含。 | F2(b) |
| D4 | **開發者選項「文字紀錄」**：唯讀列出 `NodeLinkCore.log`（F13），**每行先經 `NodeLink.mask`**（同 logcat 那條路，node_link.dart:78-80：裝置 ID 與藍牙位址只留後四碼）＋「複製」（複製的也是遮罩後的）。設計 :342 要求記錄的「佔用 420 s 收回」與「紀錄寫入失敗」兩類事件，現在只進 logcat：在 `LeaseRegistry` 收回與 `RecordWriter` 寫入失敗處加 `link.note(line)` → `core._log`（只記種類、操作名稱、後四碼）。 | 設計 10.2；B-M4；D-M2 |
| D4a | **開發者選項「忘記加入中的節點」**：`NetIndex` 另外算 `orphanJoins` = 網路紀錄裡 `forgettable(...)` 為真、但手機上已經沒有 `node/<id>` 的成員（`todos` 用 `mine.contains` 過濾掉它們，net_index.dart:213-221；T17 刪節點紀錄後沒有入口）。`nodeIds()` 讀不到 → **不列任何孤兒**（fail-closed，不能把全部 joining 成員都當孤兒，J MINOR），頁面顯示「讀不到手機上的節點清單」。頁面列出（網路名 + 後四碼），每列「放棄這次加入」：對話框沿用舊控制台的內容與選項（nodes.dart:1264-1283）——`forgetNotice(offerExclude: …)` 的警告，以及（devTrust、已同意過的成員）「排除這台（換密碼）」按鈕 → 開 `PersonPage` 的排除流程（team_pages.dart:175-183，同一個 controller）；「只忘記」= `forgetJoining`（session 佔用、`RecordWriter`）。理由：孤兒最可能是遺失 / 被抓的節點，忘記之後它也會從排除清單消失（F-M4）。有 `node/<id>` 的照舊在首頁待辦 → 4.x。所有會用擁有者金鑰的開發者選項入口（SSH、節點設定、忘記加入中的節點）在 `KeyAbilities` 說不能管理時是灰的、附原因句（同 §5.1 :703）。 | D-M3；F-M4；設計 :634、:790 |
| D5 | **全隊頁（6.1–6.3）照設計做完整版（使用者 2026-11-18 決定）**。<br>(a) **開關**：Rust 加 sync `team_enabled() -> bool`（= `teamview::WRITE_MESH_ADDR`）。`SessionProber` 以建構參數 `bool Function() teamEnabled`（預設呼叫 Rust）取得，單元測試可注入。本版 false → 下面 (b) 全部不做，行為和 PR 5 相同。<br>(b) **計算位置**：`SessionProber` 現在讀到本體後在同一個 session 做 `_hint`（prober.dart:158-166，`Future.any` + `hintMax` 2 s、之後 `done()`）。改成一個 `_afterRead`，**同一個 2 s 預算、同一次 `openNet`**：要不要開紀錄 = (`hs.wanted(id)` 或 `teamEnabled()`) 且 `v.netId` 不空且 `hs.netKnown(v.netId)`（保留 netKnown 閘門）；開到的明文 `p` 同時給 `updateHint`（只在 `wanted` 時）與 `teamView`（只在 `teamEnabled()` 時）。**每個 await 之後、每次呼叫 session 之前都檢查 `stop()`**（cancel 後不碰已 dispose 的 FRB 物件，prober.dart:242、:264）。**算出來的 team 跟著這次讀取的 `Outcome` 一起回去**（`Outcome.team`，I-M1 / J-M1：prober 裡還沒有這次的 `readAt`，它是 `NodeLink._run` 在 `core.result(now(), …)` 時才寫的，node_link.dart:582、core.dart:489）。照已審的舊程式（nodes.dart:1165-1176、254 v2.4）：先 `teamView(recordPlain: null)`；netId 不空、`netKnown`、紀錄打開 → 用紀錄重算覆蓋——NoNet / NoList / NoInfo（teamview.rs:250-345）照舊出現。**紀錄打開這一步超過 2 s 預算或被 cancel → `Outcome.team` = null（不給「沒有名單」版本，因為那句在這種情況是錯的，I MINOR-1）**。<br>(c) **存放**：**寫者只有 `NodeLink._run`**：在 `core.result` 之後、**只有這次結果被接受**（不是被取消的一輪、不是 `_abort`、不是 row 2' 的錯誤碼）而且 `Outcome.team` 不是 null 時，寫 `NodeLink.teams[id] = (netId, view, readAt, readWall)`，`readAt` / `readWall` 就是 `core.result` 剛寫進 `states[id]` 的那兩個值；`core.states` 已沒有 id（T17 移除）→ 不寫。沒有 `TeamSink` 回呼（prober 不碰 NodeLink 的狀態）；`node/<id>` 移除時清；換頁不清。新鮮 = `core.fresh(id, now)` **而且** `teams[id].readAt == core.states[id].readAt`（team 是最新那次被接受的讀取算出來的）；否則整段舊資料樣式，「上次讀取」用 **team 自己的 `readWall`**（不是狀態的，I MINOR-3）（G-M2、H-M1）。<br>(d) **讀取**：`Page` 加 `team`。core 的 `setPage`（core.dart:186-201）在換頁時會取消進行中的一輪、清 earlyDue / fullDue；**home ↔ team 互換整個是 no-op**（目標相同，H MINOR）。其他判斷「三種頁面」的地方把 team 當 home（E 核過 :165 / :170 / :196）。其他判斷「三種頁面」的地方把 team 當 home。<br>(e) **入口**：首頁「可以做的事」在任何一台 `teams[id]` 存在且 `view.visible` 時出現（不要求 netId，同舊程式，H-M2）「看全隊狀態」。<br>(f) **頁面** `TeamPage`：`setPage(Page.team)`；**每台自己的節點一段**：段標題 = Rust 的 `title`（它本身已含「由『X』看到」與「僅供參考」，teamview.rs:298；不另加小字，J MINOR），不跨節點合併——同一網路多台各一段，所以一台被入侵的節點只能影響自己那一段，不能蓋掉別台的資料（E-M2）。每段照 254-app-team-status 凍結版面：`only`（在卡片上方）、`cards`（Rust 組好的句子原樣）、`note`、`tech` 只在技術資訊。那台不新鮮 → 整段 unk 樣式 +「上次讀取 HH:MM」（卡片的燈號也換成 unk，不顯示舊的綠燈）。狀態區「重新整理」= `link.refresh`。全部消失 →「全隊狀態目前不可用」。**全隊內容不進任何紀錄**（`core.log`、logcat、文字紀錄頁；254 T-A9 那條安全測試移植過來）。<br>(g) **偏離**：§5.6「卡片上同時顯示後四碼」——`TeamView` 的卡片是 Rust 組好的句子、`Listed` 沒有 device id（teamview.rs:85-97、:241-264），名稱來自隊長簽的名單（teamview.rs:1-4）；加後四碼要改 Rust 的判定資料，不在本單（§3.4 只改字串）。寫進 #329 checklist。<br>(h) **成本**：N+1 時每台每輪多一次 `openNet`（Keystore 解密）、在 2 s 預算內且 BLE 連線還開著；本版不發生。release 開不了 `team-write`，真機量不到 → ⚠️ 寫進 §8 與 #329（N+1 時用 debug build 量）。 | F4；A-M6；C-M3；D-M1；E-M2 / M3；F-M2 / M3 |
| D6 | **診斷頁 10.5**（所有版本；設定 →「診斷」）：app 版本、flavor、金鑰能力（`KeyAbilities`，由 HomePage 傳進 SettingsPage；`softOwnerEnc` 時警告句，T-H4）、每台 `states[id].extra` 的 `StatusView.tech`（沒有就寫「這次還沒讀到」）、「複製」。**複製內容是欄位白名單**：版本、flavor、金鑰能力名稱、每台後四碼 + `tech`。只讀，不用佔用。匯出不做（T11）。 | §5.8；B |
| D7 | **顯示規則 2（T-C4c），技術部分用一對控制字元包起來**（v2 / v3 的括號解析有漏，E-M1；v4 的單一分隔字元在句子被接到別的句子中間時會把後面的主句吞掉，G-M1：claim_recovery.dart:461-462、owner.rs:602、:543、main.dart:264、node_page.dart:184）。Rust 的句子把技術部分寫成 **U+001E … U+001F**（開始 / 結束）：`沒有離開網路（節點仍在隊伍網路裡）— 請再按一次\u{1E}代碼 11\u{1F}`。一句裡可以有好幾段；**句子被接起來（`format!("{a}；{b}")`、Dart 的 join）時每段仍然成對**，所以接句不會吞掉任何主句——不需要改接句的地方。主句裡不再有代碼、原因碼、回覆碼、英文內部字串、節點送來的 verb（`error_text` 的 `{v}` 另經 `shown`，G MINOR；節點送來的國家字串（join2flow.rs:631 → owner.rs:170、:517、:540、:569）也經 `display_name`，被入侵的節點不能塞控制字元，J MINOR）。括號裡有用的中文、身分指紋、後四碼、國家、MHz 留在主句。Dart `splitCode(line)`：main = 拿掉所有成對的 U+001E…U+001F 段；tech = 這些段依序以「；」接起來；**不成對**（只有開始或只有結束）→ 控制字元全部拿掉、整句當主句（寧可多顯示，不吞文字）。`screenText` 回 main；`SayLine(line)` = main + 有 tech 時小的「技術資訊（給維修人員看）」展開列。文字紀錄頁、複製內容、logcat 把兩個控制字元換成「〔」「〕」（不留看不見的字元，G MINOR）。Dart 自己組的句子（`e.runtimeType`、`認領中斷：$e`）**只包非 String 的分支**（`e` 是 Rust 回的 String 時它自己已經帶標記，原樣接上，不再包一層，I MINOR-2）。**巢狀**：`splitCode` 在一段還沒結束時又遇到 U+001E → 當成不成對處理（控制字元全部拿掉、整句當主句，J MINOR）；Rust 端插值的片段若本身是帶標記的句子，放在技術段之外（D7a 掃描只要求「代碼」等字樣在技術段內，不要求把整個插值包起來）。Rust 與 Dart 共用一組 `splitCode` 測試向量（`app/test/fixtures/split_vectors.txt`，Rust 有同規則的 test-only helper，I MINOR-5）。對話框、`goneNote` 也用 `SayLine`（保留技術段，J MINOR）。遷移清單同 v4；`plain()` 改成呼叫 `splitCode`；Dart 測試裡的假 Rust 句子改成新形狀。 | F5；A-M2、B-M1、C-M1 / M2、E-M1、G-M1 |
| D7a | **機械檢查（取代 v3 的語料）**：(1) Rust 測試（兩個 crate 各一，讀 `env!("CARGO_MANIFEST_DIR")/src/**/*.rs`）：任何**字串字面量**（含 `format!` 的格式字串）裡出現 `代碼`、`原因 ` 接數字或 `{`、`回覆碼`，或 `{…}` 插值位在全形括號「（…）」裡面，**而且不在同一個字面量裡的 `\u{1E}…\u{1F}` 之間** → FAIL，列出檔名:行。字面量用一個簡單的 Rust 字串掃描器抽出（處理跳脫的引號與 raw string），不分測試段（測試裡的期望字串本來就要跟著改成帶分隔字元，所以一起掃是對的）；允許清單分兩種、每條附理由：整類豁免（只進技術欄位的 swupd.rs `Screen.tech`、statuspage 的 tech 欄位、已不上畫面的 status.rs:169 / :182）；逐條豁免（括號插值是身分指紋、後四碼、國家、MHz——要留在主句的使用者資訊，G MINOR 約 60 行先分類再定）。掃描器把 `SEP_OPEN` / `SEP_CLOSE` 常數（若用常數）也當成界線，避免誤報（H MINOR）。(2) 每個 F5 / F6 / E-M1 列出的函式各有一條 Rust 單元測試：輸出經同規則的 helper 切開後，主句沒有 ASCII 字母（白名單 `App`、`QR`、`Wi-Fi`、`SSH`、`HaLow`、`US`、`TW`、`MHz`、版本號、`…XXXX`、指紋），技術部分含原本的代碼。(3) Dart：`splitCode` / `SayLine` 的單元與 widget 測試；Dart 原始碼掃描：lib/ui、claim.dart、member_ui.dart 裡不得把沒經過 `splitCode` / `screenText` / `SayLine` 的 `.detail` / `.text` / `.line` / `$e` 放進任何會顯示的地方（`Text(`、`StatusHero(text:/next:)`、`BatBanner`、對話框內容、`SnackBar`；規則與允許清單在測試裡，G MINOR）。 | B-M2；C-M2；D；E-M1 |
| D8 | **英文內部字串**（F6 全部 + E-M1：owner.rs:583、:585、:587、:1188、:1199；claim.rs:186 `ended`；member.rs:37、:41-42、:59；rekey.rs:352；claim.rs:19-55；owner.rs:154-187）→ 中文說明 + `\u{1E}英文\u{1F}`。例：`內容驗證沒有通過\u{1E}invalid: record netcfg\u{1F}`。Dart 端同理。只改字串，不改判定。 | A-M3；E-M1 |
| D9 | **「上次讀取」**：首頁狀態區時間——那一列講某一台（`about`）：新鮮「讀取於 HH:MM:SS」、不新鮮「上次讀取 HH:MM」+ home_logic.dart:157-183 的 `was` 句尾（照它的四種；身分不符 / 被拒那種列不接「當時…」）；不是講某一台的列（例如第 10 列）：有任何新鮮的 →「讀取於 <最新的新鮮時間>」，一台都不新鮮 →「上次讀取 <最新的 readWall>」（不加句尾，因為不是講某一台）；時間在未來 →「之前讀過」（同 home_logic.dart:157）；沒讀過 → 不顯示。這就是 review-pr2-r2-C MINOR-8 原本建議的修法（r3 E 那輪改成不顯示）。`NodeStatusList` 隨 D1 刪除。 | F7 |
| D10 | **NetFormPage 訂閱**：測試只 pump `NetFormPage`（不經首頁），用 `NodeLink` 的 `@visibleForTesting bool get hasChangedListener`：開頁 true、關頁 false。 | F8 |
| D11 | **國家**：選單只剩 `US`，顯示「美國 US（台灣使用這個頻段）」；`OwnerConsole.setCountry` 只接受 `{'US'}`，其他不送（fail-closed）。節點目前值不在集合 → 顯示「目前：XX（不在可選清單）」並可改 US。**精確的保證**（C-M4 / D 改寫）：本 app 只會送三種國家值——(1) 國家頁：只有 US；(2) 加入網路（隊長的 join2 與隊員的加入）：netcfg key 5，它由**建網的那支手機**寫入並簽章，本 app 建網一律寫 US（joinflow.rs:18）；隊員的 `want` 來自隊長簽的 mnet netcfg（join2flow.rs:21-25、:377-389、:427-429、:481），所以只要隊長也用本 app 就是 US；(3) 加入失敗時改回**節點自己原本的值**（`Op::Revert`，join2flow.rs:482-484；使用者規則「失敗就回到之前的狀態」）。今天能讓節點變成 TW 的路有兩條：PR 4 國家頁的「台灣 TW」（settings_pages.dart:233）與舊控制台的自由輸入——PR 6 兩條都拿掉，之後本 app 不會讓任何節點變成非 US；已經是 TW 的節點只在 (3) 被改回 TW。加兩條 Rust 測試：Revert 送 `prev_country`；`joinflow` 寫的 netcfg 國家是 US。join2（已凍結）不改；被改過的 app 簽出 TW 的 netcfg 不在本 app 的控制內（簽章者被信任），節點的 regdb 沒有 TW，會拒絕或照它自己的規則處理。允許集合放在 flows 層（`owner_console.dart` 的常數），國家頁讀它（C MINOR：層次）。設計 §0 U9、§5.5、§2.3 與 #329 第 35 行改寫。 | F9；A-M1、B-M3 |
| D12 | **P1 / P2 收尾**：§3 表。 | 使用者併入 PR 6 |

## 3. P1 / P2 收尾清單

| 項目 | 改法 | 不做（理由） |
|---|---|---|
| P2-2 / P2-3b 認領頁 | 同一時間只有一顆主要按鈕：沒有碼、沒有恢復 →「掃描 QR」主要、「認領」不顯示；有碼 →「認領」主要、「掃描 QR」次要；恢復中 →「停止恢復」主要（不改 danger）、掃描停用。開發版輸入框與「貼上」移到底部「開發用」摺疊區，標籤「QR 內容（16 進位）」；「從未完成的認領恢復」照舊。既有約 8 條斷言（含 R6）依新規則改寫，改寫清單列在 PR。 | — |
| P1-2b | D7 / D8 | — |
| P1-3 | 沒有暱稱時節點列 meta 不重複後四碼；2.4 清單改「節點 XXXX」 | — |
| 後四碼大小寫 | Rust 字串（F14）改大寫（只改字串） | — |
| country 兩個冒號 | 「讀不到目前的國家（另一個操作還在進行：建立網路）」 | — |
| swupdate | 摺疊標題改「技術資訊（給維修人員看）」；頂端加 `StatusHero` | 寫入預估時間：沒有資料來源 |
| P2-5 / 9.2「開始傳送」 | 加畫板、斷言它是 danger 且有後果文字 | — |
| 4.x_working | 加「這一步最多 6 分鐘」（S5） | — |
| 2.4 | 加標題列；技術資訊展開後加「請把技術資訊給維修人員看」+ 複製 | — |
| home_todo_banner / 提示卡 | 「知道了」統一 `BtnKind.text` | — |
| home_no_node | 「新增節點」只留一顆 | — |
| 7.4 / 7.5 / 7.8 | 主要動作移到內容底部 | — |
| 7.9 | 重複提醒留 `sasRule` 一句；橘紅字改 `BatBanner` | — |
| 8.5 | 「貼上文字」改主要 | — |
| P2-1 隊伍與邀請 | 隊長「1 邀請隊員 → 2 收隊員的申請」，其他（隊員名單、產生更新包）在「其他」；隊員「1 收隊長的邀請 → 2 匯入隊長的同意 → 3 讓我的節點加入隊長的網路」，「再顯示申請」「貼上隊長給的新密碼」在「其他」 | — |
| phone_wifi / country 讀到值的畫板 | 用假 OpDeps（能登入的假 session）各加一張 | — |
| 8.1 底部三顆 | — | 沒有違規 |
| I2 防漂移表 | 舊控制台刪除 → 劃掉 | — |

## 4. 擁有者 / 契約（只列新的或改的）

| 資源 / 介面 | 寫者 | 讀者 | 缺 / 壞時 | 信任邊界 |
|---|---|---|---|---|
| 節點的 app 加入 SSH 金鑰 | 節點（`ssh_keys/set` owner-op） | — | 斷線 → 結果不明，重送同一組（整組取代，等冪） | 那台節點的擁有者（簽章）；入口只在 devTrust |
| `NodeLink.teams[id] = (netId, view, readAt, readWall)` | 只有 `NodeLink._run`（`core.result` 接受這次讀取之後，來源 = `Outcome.team`） | 首頁入口、`TeamPage` | 沒有 → 沒有入口；`readAt` 和狀態的不同或不新鮮 → 舊資料樣式；id 已移除 → 丟掉 | 資料來自那台已登入節點的 status + 手機自己的紀錄；一台只影響自己那一段 |
| 句子的技術段（U+001E…U+001F） | Rust 句子函式、Dart 組句處 | `splitCode` / `SayLine` | 不成對 → 整句當主句；沒有 → 整句是主句（Rust 掃描保證含代碼的都包了） | 節點送來的文字只在技術段裡（另經 `shown`） |
| `NodeLinkCore.log` | `core._log` + 新的 `link.note`（佔用收回、`RecordWriter` 寫入失敗） | 文字紀錄頁（經 `mask`） | 空 →「還沒有紀錄」 | 記憶體；只有使用者按複製才離開 app |
| 國家允許集合 `{'US'}` | `owner_console.dart` 常數 | 國家頁、`setCountry` | 不在集合 → 不送 | — |
| `KeyAbilities` 傳進 SettingsPage | HomePage（啟動檢查那一份；診斷頁標「啟動時的檢查結果」） | 診斷頁、開發者選項入口 | — | — |

原始佔用（`RawBusy`）的使用者在刪除後剩：`ClaimPage`（首頁「新增節點」、開發者選項、舊啟動頁）、`ScanPage`（開發者選項、舊啟動頁）。`Lease` 原始佔用機制保留；pop 類測試移植到 ClaimPage（F16）。佔用收回事件有三種上限（60 s、420 s、900 s，§4.4）——三種都記一行。`RecordWriter` 目前在 app 裡沒有接 log（app_link.dart），PR 6 接到 `link.note`。

## 5. 生命週期（只列有變的）

| 路徑 | 之後 | 測試 |
|---|---|---|
| 升級 PR 5 → PR 6 | 紀錄、`ui/state-v1` 格式不變。舊控制台準備好、還沒套用的更新（X22 / X23）：新的更新頁（PR 4）讀節點狀態接手 | 既有 T-W*；R-7 情境 7 |
| 降級回 PR 5 | 無格式改變 | — |
| `NodeLink` 起不來 | 舊啟動頁：原因 + 關閉再開的指示；沒有「我的節點」；「附近的節點」只在 devTrust | T6-2 |
| SSH：送出後 app 被殺 / 斷線 | 節點可能已套用；再開頁重送同一組（等冪）；查看節點設定看不到 SSH（不在白名單）——結果只能從節點端確認，頁面寫明 | T6-3 |
| 節點設定 / 診斷 / 文字紀錄 | 唯讀；關頁即結束；被殺無殘留 | T6-4、T6-5、T6-12 |
| 全隊頁：開著時 | 同首頁：前景每 60 s 一輪、提前再讀、背景不讀、回前景立刻一輪、佔用期間不讀 | T6-13、T-X（H0 的 team 版） |
| 全隊頁：節點紀錄被移除 / 網路離開 | `teams[id]` 清掉；那個網路沒有別台 → 該段消失；全部消失 →「全隊狀態目前不可用」 | T6-13 |
| 全隊頁：app 被殺 / 重開 | `teams` 是記憶體，重開後要讀一輪才有入口 | T6-13 |
| 本版（`team_enabled()` false） | 不開紀錄、不呼叫 `teamView`，沒有入口——行為和 PR 5 相同 | T6-13（假 false） |
| 忘記加入中的節點（開發者選項） | 確認 → session 佔用 → `RecordWriter`；失敗原樣顯示、紀錄不變 | T6-14 |
| 舊啟動頁的「認領節點」 | 現況：`NodeLink` 起不來時 ClaimPage 不經 `LeaseRegistry`（沒有 NodeLink 也就沒有自動讀取可衝突）；不改 | — |
| 國家：節點目前值 TW / 其他 | 顯示目前值，可改 US；不送非 US | T6-9 |
| 平台 | Android 12+（不變）；只有 dev / dev2 有開發者選項頁 | T6-1、T6-3 |

## 6. 安全

- **SSH 頁**：加金鑰 = 給私鑰持有者節點 root。只在 devTrust 版本、且要是該節點擁有者（節點驗 owner-op）。攻擊面不增加（舊控制台本來就有，而且舊啟動頁的入口沒有 dev 閘門——刪掉它反而縮小）；驗證比舊的嚴（照節點規則）；送出前顯示指紋防剪貼簿被換；整組取代的語意寫在按鈕上，避免以為是追加而把別的金鑰洗掉。Rust 端不加閘門（protocol 層已經靠擁有者簽章；dev 閘門在 app）。
- 節點設定：Rust `shown` 清理節點字串（被入侵的節點不能塞換行 / 方向字元假造畫面）。
- 文字紀錄 / 診斷複製：白名單、不含長 hex。
- 國家：fail-closed；例外只有 join2 的「改回原值」。
- 程式完成後跑 `/security-review`。

## 7. 測試

### 自動（`flutter test` 全套 + cargo；每條附負向對照）

| 代號 | 測什麼 | 負向對照 |
|---|---|---|
| T6-1 | 開發者選項沒有「舊版控制台」；`lib/` 原始碼沒有 `class NodesPage`（掃不到檔案 = FAIL） | 放回入口 → FAIL |
| T6-2 | `makeLink` 的 `start` 丟例外 → 舊啟動頁有關閉再開的指示、沒有「我的節點」；非 devTrust 沒有「附近的節點」 | 放回按鈕 → FAIL |
| T6-3 | SSH 頁：合格多行 → `requestSshKeys(lines)` 一次、指紋顯示正確（對 ssh-keygen 算好的向量）；不合格（regex 外、> 256 B、> 8 行、含 CR）→ 不送、顯示哪一行；0 行 → danger + 確認；非 devTrust 沒有入口 | 拿掉驗證 → FAIL；指紋算錯 → FAIL |
| T6-4 | Rust：`settings_text` 對帶密碼欄位與控制字元的回答 → 輸出不含密碼與控制字元；Dart：頁面顯示回答文字 | 拿掉 `shown` → FAIL |
| T6-5 | 診斷頁：版本、flavor、金鑰能力、soft 警告、每台 tech、複製內容 = 白名單欄位 | 拿掉 soft 警告 → FAIL；複製內容多加一個欄位（例：完整 device id）→ 白名單那條 FAIL |
| T-C4c | Rust：D7a (1) 掃描與 (2) 每函式測試；Dart：`splitCode`（多段、接句、不成對）/ `SayLine`；主畫面沒有代碼、展開技術資訊有；下一步（「請再按一次」「請回報」）在主句；**G-M1 的五處接句**各一條：接起來的主句全部在、技術段都在技術資訊 | (1) 拿掉任一句的包裝 → 掃描 FAIL；(2) 代碼搬回主句 → FAIL；`splitCode` 改成「第一個控制字元之後都是技術」→ 接句那五條 FAIL；不成對時吞文字 → FAIL |
| T-C4c-src | D7a (3) 的 Dart 原始碼掃描 | 放回一個 `Text(x.detail)` → FAIL |
| T6-6 | D8 每個英文來源的 Rust 測試：主句沒有 ASCII 字母（白名單外） | 改回原字串 → FAIL |
| T6-7 | D9 四種情況（某台新鮮 / 不新鮮、非某台的列、未來時間） | 回到不顯示 → FAIL |
| T6-8 | 只 pump NetFormPage：`hasChangedListener` 開 true、關 false | 刪 cancel → FAIL |
| T6-9 | 國家頁沒有 TW；`setCountry('TW')` 不送；目前值 TW → 顯示並可改 US；Rust：join2 Revert 送 `prev_country` | 加回 TW / 拿掉閘門 → FAIL |
| T6-10 | 認領頁三種狀態各只有一顆主要按鈕（T-C3 擴到 ClaimPage）；恢復中有停止 | 認領常駐 primary → FAIL |
| T6-11 | §3 其餘各項各一條 widget 斷言 | 各自改回 → FAIL |
| T6-12 | 文字紀錄頁：每行經 `mask`（假 log 含完整 device id 與 MAC → 畫面與複製內容只有後四碼）；佔用收回與寫入失敗各產生一行；空時的句子 | 拿掉 mask → FAIL；拿掉 `note` 呼叫 → FAIL |
| T6-13 | (a) prober（注入 `teamEnabled`）：true 且讀到本體 → 開一次紀錄、hint 與 team 共用、`Outcome.team` 有值；netId 空 → NO_NET 版本；info 沒讀到 → NO_INFO 版本；紀錄打不開 / netKnown false → `recordPlain: null` 版本（NoList）；紀錄超過 2 s 或 cancel → `Outcome.team` null；false → 不開紀錄、不呼叫；**field（非 devTrust、不在節點頁）也會算**；cancel 在 openNet 之後 → 不呼叫 `teamView`；2 s 預算；(b) `NodeLink._run`：**正向——正常讀完一輪 → `teams[id].readAt == states[id].readAt`、那一段是新鮮的**；被取消的一輪、`_abort`、row 2'、id 已移除 → 不寫；(c) 首頁：任一台 `visible` → 「看全隊狀態」（不看 netId），否則沒有；(d) TeamPage：每台一段（標題 = Rust title）、only 在卡片上方、**第 2 輪 openNet 延遲 / cancel 時那一段不是綠的**、tech 只在技術資訊、不新鮮整段 unk + 上次讀取、全部消失的句子、重新整理呼叫 `refresh`；全隊內容不進 `core.log` / 文字紀錄（254 T-A9 移植）；(e) core：`Page.team` 在最上層時 60 s 一輪、目標全部、背景不讀；home ↔ team 換頁不取消進行中的一輪、不清 due | (a) 計算放回 `wanted` 之後 → field 那條 FAIL；cancel 檢查拿掉 → FAIL；(b) 在 prober 用自己的 `now()` 當 readAt → 正向那條 FAIL；套用被取消那次的 team → FAIL；拿掉「id 已移除不寫」→ FAIL；(c) 拿掉 visible 判斷 → FAIL；(d) 拿掉 `readAt` 比對 → 延遲那條 FAIL；改用固定 300 s → 背景回來那條 FAIL；把 team 內容寫進 log → T-A9 FAIL；(e) team 不算「三種頁面」→ FAIL；home ↔ team 會取消或清 due → FAIL |
| T6-14 | `NetIndex.orphanJoins`：網路紀錄有 joining 成員、手機沒有 `node/<id>` → 列出；有 `node/<id>` → 不列（在 todos）；頁面按放棄 → `forgetJoining` 一次、紀錄改寫 | 用 `todos` 的過濾 → FAIL |
| 既有（刪除前逐條處理，PR 附對照表） | 刪掉的每一個測試，**實作時**先列出（`git grep` NodesPage / StatusPageView / ControlsAndLog / ReadClock / NodeStatusList 的所有測試檔），每條標「已有對應（檔:行）」或「移植到 X」。已知的（F-M1）：`nodes_zero_test.dart`（唯讀 buffer 的 z 歸零，S20 上真的發生過）→ 移植到新的同一程式路徑；新路徑若沒有歸零 = bug，一起修；`member_ui_test` 的 T8、S6 leave / remove、T-A9「全隊不進紀錄」（:605-656）→ TeamPage、team section 版面兩條 → TeamPage、T9 layout；`nodes_update_send_test` 自己的 12 條（T30 / T19 / S3）；`key_gate_test.dart:146`（安全回歸）、`key_abilities_test:338`、`:633`；`pages_test:275`；pop 類 → ClaimPage；`nodes_update_send_test.dart` 的假節點庫先搬 `test/support/`；`member_ui_test`、`rekey_send_test` 的 nodes.dart 掃描排除拿掉 | 每條移植後的測試各做一次負向對照 |

T9 畫板：加 10.5、SSH、節點設定、忘記加入中的節點、文字紀錄、全隊（假 visible）、國家（只有 US）、新認領頁三狀態、9.2、讀到值的 phone_wifi / country；重跑、開圖看改過的那些。

### 真機（S20；R-7，設計 §9.2 :980 全部要求）

每條情境：走完；記錄點擊數與卡住的地方；每次「正在連到節點…」的秒數（全場合計 ≥ 10 次，≥ 9 次 ≤ 20 s，超過的歸因）；**每條**各做一次「關藍牙再開」「節點重開」「切到背景」中斷；另做 X13（建網後「正在確認節點連上了」等待中切背景 30 s）與 X14（軟體更新上傳中切背景 30 s），和 main 的 app 同一步比對。

節點現況（記憶 2026-11-18 08:40 / 10:00）：04 在 dev 的網路 v6；02 是 dev3 的 7C31，**最後紀錄是在 dev3 自己建的網路 bm-50c1fae753ae**（H-M3；之後沒有離開的紀錄）。

**第 0 步（唯讀，開場前）**：04 SSH 讀 `uci`/狀態；02 用 dev3「查看節點設定」與首頁狀態確認是否在網路、國家；04 / 02 的版本（給第 8 步）。結果決定下面第 1–2 步之間是否插入「dev3 讓 02 離開網路」（副作用：02 離開 bm-50c1…；dev3 手機的 net/ 紀錄保留）。dev3 有 net/ 紀錄，首頁第 6 列會導向 join2，所以第 3 / 6 步的隊員加入一律從「隊伍與邀請」的隊員入口進。dev3 重建前先核對套件名與簽章和手機上已裝的一致（`adb shell pm list packages`、`apksigner verify --print-certs` 比對），不一致就不裝。

**dev3 flavor**：和 dev 相同設定、`DEV_TRUST = true`、不同 applicationId（J MINOR）。

**用哪個 app**：隊長端 = dev（PR 6 的 APK，`adb install -r`）。隊員端：設計寫 dev2，但 dev2 沒有自己的節點；02 已被 dev3 認領，所以隊員端用 **dev3 = 從同一個 PR commit 建、只在 gradle 多一個臨時 flavor（不同 applicationId），Dart / Rust 程式完全相同**；PR 說明寫明這不是 PR 的產物、差異只有套件名。
**同一支手機的限制**：dev 與 dev3 在同一支手機上，兩邊不能互掃 QR，而顯示碼的頁面禁止截圖、不能放到電腦上顯示。所以情境 2 / 3 都走「複製文字」；QR 互掃（情境 2 原意）留在 D 組（第二支手機）。
**節點重開的做法**：04 用 SSH `reboot`——✅ 已驗證可登入（2026-11-18 唯讀 `ssh root@fe80::8aa2:9eff:feb5:6c89%15` 回 `BCM2711-6c89`）。02 要先完成第 1 步（還原 lab key）才能用 SSH；之前與之後都先用唯讀命令確認位址（link-local `fe80::da3a:ddff:fef8:45d7%15`，加入網路後 mesh IP 會變，以 link-local 為準）。SSH 重開是正常關機，不等於現場斷電：至少情境 5 要真的拔電（使用者在場；不在場則該項標 ❌ 並列進 C 組）。

順序（避開 reason 14：國家只能在不在網路時改；`AlreadyMember`：已在網路不能再加入）。中斷的時機：**不在送出 / 寫入的當下重開節點**（加入、建網在「正在確認節點連上了」等待中才重開；OTA 只做切背景與關藍牙，**不在刷機中重開節點**，理由：可能變磚，§9.4 已列為未涵蓋）：

| 步 | 情境 | 走法 | 中斷 | 會改的節點狀態 → 還原 |
|---|---|---|---|---|
| 1 | 02 還原 lab key | dev3 的 SSH 頁對 02 設 lab 公鑰 | 關藍牙、切背景；節點重開 = 使用者拔電，不在場則略過並註明 | 02 多一把 app 加入的 SSH 金鑰（就是要的狀態） |
| 2 | 8 改設定 | 先「查看節點設定」讀 02 國家；02（不在網路）國家設 US（原本就是 US → 只驗畫面，TW → US 的轉換只有 widget 測試）；04 手機 Wi-Fi 改再改回（電腦到 04 的 SSH 走有線 link-local `%15`，不經 AP，不受影響） | 三種 | 02 國家 = US；04 AP 名稱改回 |
| 3 | 2 加入（文字） | dev（04 隊長）邀請 dev3 → 申請 → 同意 → 02 加入 04 的網路 | 三種（重開在「正在確認」時） | 02 進 04 的網路 |
| 4 | 6 移除隊員 | dev 移除 dev3 → 04 換網路密碼 → 更新包 | 三種 | 04 網路新版本、新密碼；02 被排除 |
| 5 | 9 離開 + X13 | dev3 讓 02 離開網路；dev 讓 04 離開網路，再用「加入網路」把 04 加回 dev 的同一個網路紀錄（join2；若 app 因紀錄狀態不讓，記錄現象、改由 dev 建新網路，舊 `net/` 紀錄留在 dev 手機上並在 PR 記錄；這時第 6 步的目標是新網路、結束狀態的 04 是新網路的建立者） | 三種；X13 = 加回後「正在確認」時切背景 30 s | 04 回到 dev 的網路 |
| 6 | 3 遠端加入 | 同 3 的完整一次（只用複製文字）；02 在第 4 步被排除過，dev 會看到「之前被排除…」確認（rekey.rs:517），照實確認 | 三種 | 02 進 04 的網路 |
| 7 | 5 節點連不上網路 | 02 拔電（使用者在場）或 SSH `reboot` 02（不在場；重開期間就是連不上）→ 看 04 / dev3 的原因與下一步 | 切背景、關藍牙 | 02 開機完成後自己回來（不用 SSH 關介面，那不會自己恢復，G / H MINOR） |
| 8 | 7 軟體更新 + X14 | 對 04 OTA：第 0 步確認節點端接不接受同版本；不接受就用下一版（使用者決定），上傳中切背景 30 s | 切背景、關藍牙（不重開） | 刷機 |
| 9 | 1 出勤前整備 | 沒有未認領的節點，**要重燒才能走認領段**；不重燒則只走「建網 + 再加一台」的部分（已在 3 / 5 走過） | — | 重燒（使用者決定） |

**記錄**：「正在連到節點…」秒數取自 logcat 的 `loginFor <id>` 開始行與 `loginFor <id> -> <結果>` 行（core.dart:637、:695）的時間差（佔用登記本身沒有 log，H MINOR），全場合計 ≥ 10 次，≥ 9 次 ≤ 20 s，超過的歸因。每步記點擊數與卡住的地方。**結束狀態**：04 = dev 的網路（第 4 步後的新密碼；04 的 AP 密碼不變）；02 = 04 網路的隊員（dev3 管理）、有 lab key。開場前把上表（含每步副作用與還原）一次請使用者同意；重燒、OTA、拔電三項由使用者決定。**X13 / X14 的「和 main 比對」**：用 #349 已記錄的 main 行為（同一步）比對；需要重跑 main 時 `adb install -r` main 的同 flavor APK（同套件、同簽章，資料保留），比完再 `install -r` 回 PR 的 APK。

## 8. 不做 / 偏離（寫進 PR 說明與 #329）

- 寫入預估時間、8.1 擁擠：見 §3。
- 情境 1 的認領段若使用者不同意重燒：不走，PR 標 ❌。
- #329「首頁待辦罕見競爭（PendingNotRemoved）」不在使用者併入 PR 6 的清單，留在 #329 原段落。

## 9. 第一輪審查對應

| 審查 | 對應 |
|---|---|
| A-M1 / B-M3 國家 | D11 改寫保證範圍 + Revert 測試 |
| A-M2 / B-M1 / B-M2 代碼形狀與測法 | D7 規則逐形狀、D7a 語料 |
| A-M3 英文來源 | F6、D8 |
| A-M4 重試半套 AppLink | D1 不加重試 |
| A-M5 / B-M6 R-7 | §7 真機全部要求、副作用一次清單 |
| A-M6 全隊頁 | D5（v3：完整版，使用者決定） |
| B-M4 文字紀錄 | D4 唯讀頁 |
| B-M5 SSH 語意 / 驗證 | D2、F12 |
| MINOR | 認領頁按鈕（§3）、settings_text `shown`（D3）、測試庫搬移（§7 既有）、claim.dart 在 T-C4c 範圍（D7）、D9 細節、C-8 說法、「附近的節點」閘門（D1）、診斷白名單（D6）、`hasChangedListener` 只 pump 本頁（D10）、路徑、PendingNotRemoved 留處（§8）、`KeyAbilities` / `states.extra` 名稱（F11、D6）、小寫來源（F14）、原始佔用使用者（§4）、P2-5 / 2.4 / 讀值畫板（§3）、生命週期列（§5）、`NodeCert {c:?}`（F6） |

## 10. 第二輪審查對應

| 審查 | 對應 |
|---|---|
| C-M1 ASCII 段誤藏 | D7：只拆含「代碼 」的括號；ASCII 段只在代碼段之後 |
| C-M2 形狀 / 巢狀 / 不成對 / 語料完整性 | D7（最內層成對、節點文字的括號換半形）、D7a（sites 檔機械掃描）；`Broken：…` 形狀由 D8 改成「（代碼 內部：Broken）」 |
| C-M3 / D-M1 全隊頁 | D5 完整版：prober 不經 `wanted`、`Page.team`、首頁入口、60 s |
| C-M4 / D 國家 | D11 改寫為三種來源的精確保證 + 兩條 Rust 測試 |
| D-M2 文字紀錄遮罩 / 事件 | D4：`mask`、佔用收回與寫入失敗的 `note` |
| D-M3 孤兒加入項目 | D4a |
| D-M4 R-7 | §7 真機：dev3 的性質、同手機不能互掃、節點重開做法、順序、結束狀態 |
| MINOR | SSH：指紋在 Rust、不帶 `=`、CRLF、0 行說明、成功句（D2）；節點設定改名（D3）；D9 句尾與非某台的列；遷移清單補齊（D7）；國家集合放 flows 層（D11）；舊啟動頁 ClaimPage 不經佔用寫進 §5；swupd / status 字串不改（D7）；T-C4c 的 ASCII 白名單：主畫面允許 `App`、`QR`、`Wi-Fi`、`SSH`、`HaLow`、`US`、`TW`、版本號與 `…XXXX` 後四碼，其他 ASCII 單字 FAIL |

## 11. 第三輪審查對應

| 審查 | 對應 |
|---|---|
| E-M1 其他碼與英文 | D7 改成 U+001F 分隔字元（不再解析括號）；D7a 機械掃描；D8 擴大 |
| E-M2 / F-M2 / F-M3 全隊資料契約 | D5 (b)(c)(e)(f)(g)：帶 netId、netId 空清掉、每台一段（被入侵的節點只影響自己）、`core.fresh`、移除後晚到丟掉、netKnown 保留、後四碼偏離寫明、254 版面規則 |
| E-M3 prober 計算 | D5 (a)(b)(h)：注入開關、共用 openNet 與 2 s 預算、每個 await 後 `stop()`、成本 ⚠️ |
| F-M1 刪掉的測試 | §7「既有」：逐條對照表、`nodes_zero_test` 等已知項目 |
| F-M4 孤兒排除 | D4a：`forgetNotice(offerExclude)` + 排除按鈕 |
| F-M5 / E R-7 | §7 真機：中斷時機、OTA 不重開、02 SSH 前提、拔電、結束狀態、秒數來源 |
| MINOR | D3 `OpSession.once`；收回事件三種上限、`RecordWriter` 接 log（§4）；診斷頁標「啟動時的檢查結果」；開發者選項入口看 `KeyAbilities`（D4a）；§4 表更新；home ↔ team 換頁（D5 d）。實作時處理並列在 PR：D9 的 `was` 句尾照 home_logic.dart 的四種、「未來時間」只用在 prev；國家頁「目前：XX」經 Dart 端清理（控制字元、長度 ≤ 8）；swupdate 的 StatusHero：準備好 = ok「已準備好，還沒套用」、寫入中 = busy、完成 = ok、失敗 = bad；T6-13 各項負向對照已補 |

## 12. 第四輪審查對應

| 審查 | 對應 |
|---|---|
| G-M1 接句吞主句 | D7 改成成對控制字元 U+001E…U+001F；T-C4c 五處接句測試 |
| G-M2 / H-M1 舊卡片顯示新鮮 | D5：每次讀到本體都寫 team、`readAt` 必須等於狀態的讀取時間；T6-13 延遲 / cancel 測試 |
| H-M2 偏離 254 / 舊程式 | D5：先 `recordPlain: null` 再用紀錄覆蓋；入口不要求 netId |
| H-M3 R-7 起點 | §7 第 0 步唯讀確認、必要時讓 02 離開、隊員入口、dev3 套件 / 簽章核對 |
| MINOR | D7a 允許清單分類、白名單加 TW / MHz、Dart 掃描範圍、`{v}` 經 `shown`、假句子新形狀、控制字元在紀錄 / 複製中換成〔〕；home ↔ team no-op；段標題用 Rust title；`key_gate_test`；秒數來源；第 6 步「之前被排除」、第 7 步改 reboot、第 8 步同版本先確認；X13 / X14 比對方法；D9 身分列不接句尾；診斷白名單負向對照；SSH 取代說明常駐；CR 規則一致 |

## 13. 第五輪審查對應

| 審查 | 對應 |
|---|---|
| I-M1 / J-M1 readAt 時序 | D5：team 跟著 `Outcome` 回去，`NodeLink._run` 在 `core.result` 接受後寫入並帶那次的 readAt / readWall；T6-13 正向測試 + 兩條負向對照 |
| MINOR | 2 s 逾時改成不寫（不給錯的 NoList）；巢狀標記規則、Dart 只包非 String、共用測試向量；不新鮮用 team 自己的時間；T6-13 的 netId / readAt / NO_NET / NO_INFO；D7a (2) 用同規則 helper；段標題不重複；國家字串經 `display_name`；`orphanJoins` fail-closed；dev3 `DEV_TRUST`；第 5 步備案對第 6 步的影響；第 2 步 SSH 路徑；對話框保留技術段。未採：`mask` 遮 8 位以上十進位（文字紀錄頁多遮一些數字，不影響安全或判讀）；SSH 指紋比節點嚴（base64 解不開的金鑰節點會收、app 拒絕——fail-closed，接受） |

## 14. 第六輪審查（K 0 / 0 / 8、L 0 / 0 / 5，都是 APPROVE-WITH-CHANGES，0 MAJOR）→ 計畫凍結

實作時照下面處理（MINOR，列在 PR）：
- 「被接受」的訊號：`core.result` 改回傳 `bool`（接受 / 丟掉），`_run` 依它決定寫不寫 team；測試含「core 丟掉結果時不寫」。不用 `readAt == t` 判斷。
- `readWall` 由 `_run` 在 node_link.dart:584 寫；team 寫在那一行之後，帶同一個 `t`（只取一次 `now()`）；測試的假時鐘每次呼叫都前進 1 ms，讓「另一次 `now()`」的負向對照測得出來。
- `Outcome.team` 宣告為 `Object?`（core.dart 保持不 import FRB 型別）；只在 `Res.body` 計算；`hint` 來源為 null 時也照常計算 team（team 不依賴 hint）。
- 冷啟動 `NetIndex` 還沒算完（net_index.dart:142）時 `netKnown` 為 false → 這一輪 `Outcome.team` = null（不寫錯的「沒有名單」）。
- §5「網路離開」：離開後下一次讀取寫「不在網路裡」的版本，那一段**不會消失**；只有 `node/<id>` 移除時清掉。T6-13 照這個期望。
- §4 寫者欄：`teams` 的清除者 = `node/<id>` 移除時的 `NodeLink` 同一處。
- D5(d) 的重複句刪掉。
