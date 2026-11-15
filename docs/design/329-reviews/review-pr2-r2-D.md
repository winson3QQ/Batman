# #329 PR 2（winson3QQ/Batman#340，feat/329-pr2 @ 596baeb，base feat/329-pr1 @ a0f3fbb）第二輪審查 D

審查者 D（獨立）。範圍：`git diff a0f3fbb 596baeb` 全部（新介面、main.dart 路由、UiState / cbor_mini、Kotlin 三個新 method、§3.4 文字 Dart + Rust、joinChoice、測試），加上第一輪 A / B 每一項是否真的關掉、有沒有會 FAIL 的測試。
做法：`git archive 596baeb app tests` 匯出到自己的資料夾（`scratchpad/core/pr2D`），沒有動 `C:/src/Batman-329pr2`、`Batman-329pr1`；每個改壞（mutation）跑**全套** `flutter test --no-pub test/`，跑完還原，最後 `diff -r` 對 `git archive` 確認乾淨（輸出 `CLEAN`）。

## 結論

**APPROVE-WITH-CHANGES**：BLOCKER 0、MAJOR 2、MINOR 12。

第一輪的使用者可見問題（A-M1～A-M4、B-M1、B-M2）在程式裡都改對了，我逐條讀過、也用改壞確認純函式與舊控制台那一層的測試會 FAIL。兩個 MAJOR 都是「改對了但守不住」：從節點讀到的畫面資料（`Outcome.extra`）一路到新畫面，以及首頁第 1 / 6 列按鈕的接線，拿掉之後 656 個測試全綠。

---

## ✅ 我自己跑過的（原始輸出）

| 項目 | 結果 |
|---|---|
| 全套 `flutter test --no-pub test/`（596baeb，未改） | `00:26 +656: All tests passed!` |
| bridge `cargo test`（WSL Ubuntu-24.04，自己的 CARGO_TARGET_DIR） | `test api::simple::tests::t_u4_ui_is_not_a_record ... ok` / `test result: ok. 63 passed; 0 failed` |
| batman-proto `cargo test` | 21 個 test result 全部 `ok`（50、40、39、36、20… passed，0 failed） |
| T-U4 負向對照：`RECORD_KINDS` 加 `"ui"` | `test api::simple::tests::t_u4_ui_is_not_a_record ... FAILED` / `panicked at src/api/simple.rs:119:9`（還原後 diff 為空） |

### 改壞對照（每一個跑全套，跑完還原）

| # | 改壞 | 結果 | 抓到的測試 |
|---|---|---|---|
| M1 | 暱稱過濾拿掉 U+0000–U+001F | KILLED | ui_state_test「B-m1: a nickname with a control character」 |
| M23 | 暱稱過濾拿掉 U+202A–U+202E | KILLED | ui_state_test「B-m1: … direction mark」 |
| M2 | `_save` 不排隊（直接 `_saveNow()`） | KILLED | ui_state_test「B-m9: writes asked together…」 |
| M3 | 讀取時間不檢查上限 | KILLED | ui_state_test「B-m1: a read time beyond 2100」 |
| M13 | 暱稱上限 24 → 100 | KILLED | ui_state_test「body a nickname over 24」 |
| M15 | CBOR 深度上限 4 → 40 | KILLED | ui_state_test「nesting deeper than 4」 |
| M4 | core 拿掉 `s.extra = s.errExtra` | KILLED | two_prime_test |
| **M5a** | prober：`Outcome(Res.body, v.color, v)` → 不帶 `v` | **SURVIVED** `00:24 +656: All tests passed!` | — |
| **M5b** | prober：錯誤碼的 `Outcome(Res.errorCode, '', v)` → `const Outcome(Res.errorCode)` | **SURVIVED** `00:24 +656` | — |
| **M5c** | core：拿掉 `s.extra = o.extra`（讀到本體） | **SURVIVED** `00:25 +656` | — |
| M6 | `_remember` 不把 node_state 1 記成 warn | KILLED | pages_test「review A-m1」 |
| **M7** | `_todos` 的 `_records = recs` → 永遠 `NetRecords.none` | **SURVIVED** `00:24 +656` | — |
| **M8** | 設定按鈕前拿掉 `setPage(Page.other)` | **SURVIVED** `00:23 +656` | — |
| **M9** | 第 1 列按鈕不呼叫 `bluetoothSettings` | **SURVIVED** `00:23 +656` | — |
| **M18** | `actionText` 拿掉 `makeNetwork → Btn.makeNetwork`（第 6 列沒有按鈕） | **SURVIVED** `00:22 +656` | — |
| **M21** | 第 6 列不畫次要「加入隊長的網路」 | **SURVIVED** `00:20 +656` | — |
| **M30** | `actionText` 拿掉 `openBluetooth`（第 1 列沒有按鈕） | **SURVIVED** `00:21 +656` | — |
| M29 | 第 6 列 mpend → joinNetwork | KILLED | home_logic_test「row 6 … network records」 |
| M14 | 拿掉「新鮮但沒有畫面資料不是一切正常」 | KILLED | home_logic_test「review A-M2」 |
| M10 | joinChoice (true,true) → own | KILLED | nodes_update_send_test「both net and mnet」 |
| M10b | `_join` 的選單結果固定走 `_joinNetwork` | KILLED | 同上 |
| **M26** | `_join` 的 `JoinChoice.own` 接到 `_memberJoin` | **SURVIVED** `00:21 +656` | — |
| M11 | 歡迎頁條件拿掉 `!ui.welcomed` | KILLED | `T-U3: records false, seen true -> welcome false`（`Expected: no matching candidates / Actual: … "歡迎"`） |
| M19 | 歡迎頁「開始」不呼叫 `setWelcomed` | SURVIVED `00:30 +656` | —（MINOR，見 m3） |
| M12b | `whyNext(Why.identity)` 改成 notFound 那句 | KILLED | pages_test「review A-M3」 |
| M16 | `RecordUiStore._header` 永遠 false | **SURVIVED** `00:21 +656` | — |
| M22 | 移除後不呼叫 `ui.forget` | KILLED | pages_test「T-N1 … UiState forgets it」 |
| M24 | 2.2「開啟 app 設定」呼叫錯的 method | SURVIVED `00:21 +656` | — |
| M25 | 第 10 列頭兩輪的句子分支拿掉 | SURVIVED `00:21 +656` | — |
| M27 | `_remember` 不再只記新鮮的讀取 | SURVIVED `00:22 +656` | — |
| M28 | `_back` 不 `setPage(Page.home)` | SURVIVED `00:22 +656` | — |
| M32 | 設定頁 `if (devTrust)` → `if (true)`（field 版看得到開發者選項） | **SURVIVED** `00:20 +656` | — |
| M33 | 首頁提示卡不限第 14 列 | KILLED | layout_test（多頁） |
| M34 | 「上次新增節點沒有做完」不限 devTrust（F48） | SURVIVED `00:20 +656` | — |

M12（第一次寫法）與 M31 是編譯錯誤（`loading …`），不算 KILLED，已改寫成 M12b；M31 沒有重做。

### 探針（只在我的副本，跑完已移走）

`_unsafe` 過濾實際擋了哪些字（暱稱 `a<字>b` 放進密封檔內容再 `load()`）：

```
PROBE U+0085 accepted=true
PROBE U+009b accepted=true
PROBE U+2028 accepted=true
PROBE U+2029 accepted=true
PROBE U+061c accepted=true
PROBE U+200b accepted=true
PROBE U+200d accepted=true
PROBE U+feff accepted=true
PROBE U+2060 accepted=true
PROBE U+2066 accepted=false
PROBE U+00ad accepted=true
PROBE U+180e accepted=true
PROBE 8byte-negative accepted=false
```

## ⚠️ 只讀程式推論、沒有實測

- MAJOR-1 / MAJOR-2 的「使用者會看到什麼」是從改壞後的程式路徑推的（`home_logic.dart:136-139` 的 blank 列、`home_page.dart:205-214` 的按鈕表），沒有在真機或 widget 測試裡把改壞後的畫面渲染出來；測試全綠是實測。
- m6 / m9 的情境是讀原始碼推的，沒有實際觸發。

## ❌ 沒做

- 沒有上真機（照 brief 不用 adb）；Kotlin 的 `appVersion` / `bluetoothSettings` / `appSettings` 只讀原始碼，沒有在裝置上按。
- 沒有跑 `flutter analyze`。
- M31（背景寫一次）沒有重做成可編譯的改壞。

---

## 第一輪每一項的狀態

| 第一輪 | 現在 | 證據 |
|---|---|---|
| A-M1 / B-M1 第 6 列按鈕 | 程式改對；**接線沒有測試** | `home_logic.dart:92-96`；M29 KILLED，但 M7 / M18 / M21 SURVIVED → MAJOR-2 |
| A-M2 錯誤碼兩輪後的 `2'` | 程式改對；**prober 那一半沒有負向對照** | `core.dart:445,559`、`prober.dart:92`；M4、M14 KILLED，M5b SURVIVED → MAJOR-1 |
| A-M3 節點頁每種原因各自的下一步 | 關掉 | `home_logic.dart:189-196`、`node_page.dart:102`；M12b KILLED |
| A-M4 / B-M2 net + mnet 都有 | 關掉（選單） | `nodes.dart:1065-1087`；M10、M10b KILLED；own 那條接線沒有測（m12） |
| A-M5 / B-M3 相鄰列、只給新鮮、歡迎頁旗標 | 關掉 | home_logic_test「adjacent rows」「rows 6 and 7 only from fresh」；M11 KILLED。8/10 對調：被連不到的節點同時不新鮮這件事自然守住（row 5 測試的單台連不到會變第 10 列） |
| B-m1 UiState 值域、控制字元 | 大部分關掉；過濾不完整 | M1 / M3 / M23 KILLED；探針 → m1 |
| B-m2 / A-m2 第 1 列按鈕 | 程式有做；沒有測試 | M9 / M30 SURVIVED → MAJOR-2 |
| B-m3 / A-m6 用詞 | 關掉 | Rust owner.rs「要重新核對確認碼」；`wording_test` 掃 `成員`、`SAS`；我 grep 舊按鈕名只剩註解 |
| B-m4 / A-m5 後半 `roundsRun < 3` | **沒改**，也沒列為偏離 | `home_page.dart:201`、`node_page.dart:97` → m7 |
| B-m5 狀態區到秒 | 關掉 | `hhmmss`（`home_page.dart:233`） |
| B-m6 / A-m6 按鈕字從 Btn、`$e` 不上主畫面 | 關掉 | `intro_pages.dart:96-98`、`node_page.dart:76-77` |
| B-m7 / A-m8 RecordUiStore、「只流向顯示」、假秘密搜尋、devTrust 閘 | **沒改** | M16、M32 SURVIVED → m2、m3、m4 |
| B-m8 / A-m7 T-C2 覆蓋 | 部分（多了藍牙關閉、身分不符、連不到、沒有節點、節點頁身分不符） | `layout_test.dart:83-114` → 其餘見 m10 |
| B-m9 寫入排隊 | 關掉 | M2 KILLED |
| A-m1 node_state 1 記成 warn | UiState 關掉；同一次執行的節點列仍說「當時有問題」 | M6 KILLED；`home_logic.dart:177-179` → m6 |
| A-m3 設定頁算 Page.other | 程式有做；沒有測試 | M8 SURVIVED → MAJOR-2 |
| A-m4 舊啟動頁閃一下 | 關掉 | `main.dart` build：`_report == null || (_ok && _app != null)` 一直顯示 1.1 |
| A-m9 引用畫面上沒有的東西 | **沒改** | → m5 |
| A-m10 首頁 → UiState 的路 | 部分（A-m1 那一例從 `changed` 驅動）；「只記新鮮」仍沒鎖 | M27 SURVIVED（併入 m3） |

---

## MAJOR

### MAJOR-1　節點讀到的畫面資料（`Outcome.extra`）從 prober 到新畫面整條沒有測試；`2'` 修正的 prober 那一半沒有負向對照

**情境**：新首頁、節點頁、節點列的每一句話都來自 `NodeState.extra`（`home_page.dart:38` `view: s.extra is StatusView ? …`）。這個值只有一條來源：`SessionProber` 把 Rust 的 `StatusView` 放進 `Outcome`（`prober.dart:92`），core 在讀到本體時存起來（`core.dart:440`），錯誤碼時存 `errExtra`、兩輪後變成 `extra`（`core.dart:445`、`:559`）。

- 改壞 M5a（本體不帶 `v`）或 M5c（core 不存 `o.extra`）：每一台新鮮的節點 `view == null` → 首頁永遠是第 13 列「節點 X：有回應，還沒拿到狀態」、節點頁沒有狀態句子、沒有技術資訊，第 6 / 7 / 12 / 14 列永遠到不了——整個新介面看不到任何節點狀態。**全套 656 個測試照過。**
- 改壞 M5b（錯誤碼不帶 `v`）：第一輪 A-M2 的修正說「`2'` 用錯誤回答自己的畫面資料（Rust 的灰色『狀態未知』）」，但 two_prime_test 用的是自己寫的 `Script` prober，直接給 `Outcome(Res.errorCode, '', 'ERRVIEW')`，完全不經過 `SessionProber`。改壞後 `2'` 變成「有回應，還沒拿到狀態」（fail-closed，不會變綠，但不是修正宣稱的句子），測試照過。

**證據**：上表 M5a / M5b / M5c 都是 `+656: All tests passed!`。`test/nodelink/prober_test.dart` 已經有 `FakeSession.statusView`（:79）與 `expect((o.res, o.view), (Res.body, 'yellow'))`（:154）這類斷言，就是沒有檢查 `o.extra`；layout_test / pages_test 都直接手寫 `states[id]!.extra = …`（`layout_test.dart:63`、`pages_test.dart:173`），跳過了這條路。

**為什麼是 MAJOR**：這是使用者規則裡「宣稱的修正要有負向對照」沒做到的那一半（M5b），而且整個新畫面的資料來源一改就壞、沒有任何測試會 FAIL。

**修法**：
1. prober_test 加兩例：本體 → `o.extra` 就是 `FakeSession.statusView` 回的那個物件（`identical`）；`row == "2'"` → `o.res == Res.errorCode` 而且 `o.extra` 是那個 `StatusView`。
2. 一個 NodeLink → HomePage 的 widget 測試：用回傳 `StatusView` 的 prober（綠 → 第 14 列「一切正常」與節點列的句子；錯誤碼兩個全輪 → 第 13 列 Rust 的「狀態未知 …」）。
3. 負向對照：M5a、M5b、M5c 各跑一次，附 FAIL 輸出。

### MAJOR-2　第一輪修好的首頁按鈕（第 1 列、第 6 列）與「設定頁不排讀取」都沒有接線測試：改壞後回到第一輪的錯，測試全綠

**情境**：
- 第一輪 A-M1 / B-M1 的使用者錯誤是「第 6 列的按鈕字和手機的網路紀錄不符」。現在 `decideHome` 對了（M29 KILLED），但決定輸入的 `_todos()`（`home_page.dart:128-138`，`listNets` / `listMnets` / `listPends`）與把動作變成按鈕字的表（`home_page.dart:205-214`）沒有任何測試。M7（`_records` 永遠 none）→ 隊長的手機（有 net）首頁寫「建立網路」＋「加入隊長的網路」——照著按就是設計 nodes.dart 舊句子警告的「新建網路會讓整隊分成兩個網路」；M18 → 新使用者第 6 列沒有按鈕；M21 → 沒有次要按鈕。三個都全綠。
- 第 1 列「開啟藍牙設定」（B-m2 / A-m2 的修正）：M30（沒有按鈕）、M9（按了不呼叫 Kotlin）都全綠。
- 設定頁算 `Page.other`（A-m3，設計 T-L8「離開首頁（進設定頁）就不排」）：M8 拿掉後全綠，進設定頁時首頁的讀取照樣每 60 s 解開節點紀錄、用擁有者金鑰簽名。

**證據**：上表 M7、M8、M9、M18、M21、M30 都是 `+656: All tests passed!`。commit 88e39ca 寫「wired tests with the real console」——接線測試只有舊控制台那一層（nodes_update_send_test），首頁這一層沒有。

**為什麼是 MAJOR**：第一輪判 MAJOR 的使用者錯誤，修正後沒有任何會 FAIL 的測試守著顯示層；設計 T-C3 的負向對照「沒有 net 紀錄時給『加入網路』→ FAIL」要求的是畫面，不是純函式。

**修法**：HomePage widget 測試（`FakeRust` 已能假 `listNodes`，加 `listNets` / `listMnets` / `listPends`）：
1. 第 6 列四種紀錄 → 畫面上的實心按鈕字分別是「加入網路」「加入網路」「看我的申請」「建立網路」，最後一種另有文字按鈕「加入隊長的網路」。
2. 藍牙關閉 → 有「開啟藍牙設定」，點下去 mock channel 收到 `bluetoothSettings`；2.2 被拒後「開啟 app 設定」→ 收到 `appSettings`。
3. 點右上角設定 → `a.link.core.page == Page.other`；返回 → `Page.home`。
4. 負向對照：M7、M18、M21、M30、M9、M8 各附 FAIL 輸出。

---

## MINOR

**m1　暱稱過濾不完整。** `ui_state.dart:14` 只擋 U+0000–001F、U+007F、U+202A–202E、U+2066–2069、U+200E/F。探針：C1 控制字元（U+0085、U+009B）、行／段分隔（U+2028、U+2029，Flutter 會換行）、阿拉伯字母方向記號 U+061C、零寬字元（U+200B、U+200D、U+2060、U+FEFF）、U+00AD 都照收。B-m1 要的是「沒有 Cc / Cf」。PR 2 沒有寫暱稱的入口、檔案是密封的，只剩「我們自己的錯」這個 actor，所以 MINOR。修法：改成 Unicode 類別（Cc、Cf、Zl、Zp）一條規則，和 Rust `display_name` 同一套；PR 4 做暱稱編輯時寫入端用同一個函式。

**m2　`RecordUiStore` 仍然完全沒有測試（第二次提出：A-m8、B-m7）。** M16（`_header` 永遠 false）全綠。後果：一個長度 0 的 `ui/state-v1`（`NotARecord`）不再走「先 storeRemove 再寫」，而是 `_reread` → 每次寫都先讀 → 又丟例外 → 永遠寫不進去；沒有節點的手機每次開 app 都看到歡迎頁。設計 T-U2 要的四種真檔案（長度 0、版本位元組、改密文、內文版本 2）都還沒有；`write` 的 `p.generation != expectedGen + 1`（`ui_state.dart:226`）也沒有測試。

**m3　§4.6 要求的兩個測試仍缺（第二次提出：B-m7、A-m10）。** 「UiState 的值只流向顯示用的 widget」沒有測試；T-U6(b) 的假秘密／標記字串位元組搜尋沒有做（只有白名單一半）。M27（`_remember` 記不新鮮的讀取）、M19（歡迎頁按「開始」不寫旗標）全綠。我讀過所有讀 `UiState` 的地方（`main.dart` 的 `welcomed`、`home_page.dart:34,40,243`、`node_page.dart` 經 `nodeInfo`），目前確實只用於顯示——但沒有東西鎖住。

**m4　開發者選項的 devTrust 閘沒有測試（第二次提出：B-m7 的 M11）。** M32（`settings_page.dart:32` 改成 `if (true)`）全綠：field 版會看得到舊控制台、舊新增節點頁、藍牙測試頁。舊頁面裡的危險入口另有 DevOnlyButton，所以不是直接的安全洞，但 §5.8「devTrust 才有」這條 gate 一改就沒有測試抓。同類：M34「上次新增節點沒有做完」只在 devTrust（F48）也全綠。修法：layout_test 已渲染「settings (dev)」，加一頁 `devTrust: false` 斷言沒有「開發者選項」「舊版控制台」。

**m5　畫面上的句子引用畫面上沒有的東西（第二次提出：A-m9）。** 節點頁／首頁第 7 列顯示的 Rust 句子 S6、S9A 叫人「對照下面『網路：』的名稱」（statuspage.rs:138、:143），新節點頁沒有網路名稱（技術資訊裡只有 16 進位 netId，而且收合）；WARN_AP 說「可在『手機 Wi-Fi』設定」（:124），新節點頁沒有這一組。另外首頁第 6 列「看我的申請」「加入隊長的網路」打開舊控制台，那裡沒有同名的按鈕（「再顯示申請」、匯入同意）。§3.4 規則 3。T-C4b 只掃 `按「…」`，所以抓不到。修法：PR 2 先在節點頁狀態區下方顯示網路名稱（或至少寫進「和設計不同的地方」與 #329 checklist），按鈕名不一致也列進去。

**m6　同一台節點的時間與種類說法不一致。** (a) A-m1 只修了 UiState：同一次執行裡，`node_state == 1` 的節點變不新鮮後節點列走 `home_logic.dart:177-179`，用 `state.view == 'red'` →「上次讀取 HH:MM，當時有問題」；重開 app 後同一台卻是「當時要注意」。(b) `2'` 時 `readAt` 是現在，但 `readWall` 只在讀到本體時更新（`node_link.dart:308`），所以節點列與狀態區寫「讀取於 <上一次本體的時間>」配「狀態未知」，`_remember` 也存 `('unk', 舊時間)`；從沒讀到本體的節點則沒有時間。修法：(a) 那個分支對 `notInNetwork` 用「當時要注意」；(b) `2'` 的時間用 `readAt` 對應的牆上時間，或不顯示「讀取於」。

**m7　頭兩輪的判斷與第 10 列的字。** `firstRounds = roundsRun < 3`（`home_page.dart:201`、`node_page.dart:97`）沒改也沒列偏離（B-m4、A-m5 後半），第 2 輪結束到第 3 輪開始之間仍算頭兩輪。第 10 列頭兩輪的句子分支（M25）沒有測試。第 10 列句子多一個半形空白：`'還沒讀到 X 的狀態'` → 「還沒讀到 節點 0010 的狀態」，設計是「還沒讀到節點 X 的狀態」。

**m8　按鈕失敗沒有回饋。** 第 7、8 列多台時 `HomeAction.showList` 沒有按鈕（`home_page.dart:213` 落到 null；設計「捲到節點清單」），沒有列為偏離（A-m2 後半）。`bluetoothSettings` / `appSettings` 回 false（`MainActivity.kt` `openSettings` 找不到頁面）時畫面沒有任何反應；`invokeMethod` 沒有 await 也沒有 catch（`home_page.dart:170`、`intro_pages.dart:158`），Kotlin 丟 `SecurityException` 時只會變成未處理的非同步錯誤。修法：false / 例外時顯示「請到手機的設定 → 藍牙」這類文字。

**m9　第 6 列的紀錄判斷 fail-open 到最危險的按鈕。** Rust 的 `list_nets` / `list_mnets` / `list_pends` 把 `read_dir` 的任何錯誤吞成空清單（owner.rs:41-47、member.rs:331-345），`_todos` 也 `catch (_) {}`（`home_page.dart:137`）。讀不到 → `NetRecords.none` → 隊長的手機首頁主要按鈕是「建立網路」。很少發生（目錄存在但讀不到），但這是唯一會引導使用者分裂隊伍的按鈕。修法：判斷不確定時不給「建立網路」（只給「看這台節點」或「加入網路」）。

**m10　T-C2 仍沒渲染的頁與狀態。** 1.1 啟動畫面、2.4 金鑰不足頁、節點頁技術資訊展開（版本、tech 行在 2.0 倍字級）、移除確認對話框、多台節點、長的 Rust 句子（例如 S9A 約 90 字、加上 warning / lagNote）。測試用的句子只有「已連上隊伍網路」「沒有連上隊伍網路」。

**m11　PR body 過時。** 測試數字還是 570（現在 656）、T-C2 寫 8 頁（現在 14 頁）；「『開啟 app 設定』按鈕沒有做」（現在做了）；joinChoice 的描述是兩態（現在四態，含選單與 none）；第一輪的修正、`2'` 的資料來源改動、Kotlin 兩個新 method 沒寫進去。合併前要更新（使用者規則：PR body 要有實際的測試結果）。

**m12　舊控制台「加入網路」的 own 路徑沒有接線測試。** M26（`JoinChoice.own` 接到 `_memberJoin`）全綠：最常見的「隊長把自己的節點加進自己的網路」走一顆按鈕之後沒有測試；選單選「這支手機建立的網路」也沒有。B-M3 要的接線測試只做了 member、none、ask→member 三種。

---

## 依角色的安全檢查

- **其他 app**：`ui/state-v1` 在 app 私有目錄、用紀錄金鑰（Keystore）密封，AAD 綁 `rel` + generation（store.rs:50-56），無法和 `node/` 紀錄互換。新的 Kotlin method 只在本行程的 MethodChannel；`ACTION_BLUETOOTH_SETTINGS` 與 `ACTION_APPLICATION_DETAILS_SETTINGS`（自己的 packageName）都是系統頁，app 不改任何設定；manifest 只加 `screenOrientation`，沒有新的 exported 元件。沒有發現問題。
- **被入侵的節點**：新畫面上的節點內容都經 Rust：`sentence` / `warning` / `lagNote` 是 Rust 的固定句子，`version` / `tech` 經 `statuspage::shown()`（控制與格式字元替換、64 字上限，statuspage.rs:187-190），`netId` 是 16 進位。UiState 不存任何節點字串（T-U6 白名單有效）。只回錯誤碼的節點到不了「一切正常」（M14 KILLED）。身分不符立即上第 4 列，節點頁給安全警告（M12b KILLED）。節點本來就能謊報綠燈，不是新攻擊面。
- **附近的攻擊者**：S10 之後 BLE 位址只進 `_log`（claim.dart:252）；廣播的後四碼仍顯示在舊認領頁（原有行為）。
- **我們自己的錯**：UiState 的解碼器嚴格（型別、長度、深度、重複鍵、尾端位元組、8 位元組負值都拒絕，探針 `8byte-negative accepted=false`）；值域與控制字元見 m1；讀不到一律當不存在；寫入排隊（M2 KILLED）。沒有任何判斷讀 UiState（讀過每個使用點），但沒有測試鎖（m3）。devTrust 閘沒有測試（m4）。
- **fail-open 只給顯示**：成立。唯一不在 UiState 的 fail-open 是 m9（第 6 列紀錄判斷）。

## 對 PR body「和設計不同的地方」的判斷

| 項目 | 判斷 |
|---|---|
| joinChoice 照 T-N2（S3 不一致） | 現在的四態（own / member / ask / none）比 S3、T-N2 都完整，接受；設計 S3 與 T-N2 要回填成同一句（含「兩種都有 → 選」與「都沒有 → 說明怎麼開始」）。S3 的「加入中 → 接著做」由 own 路徑的 `_joinNetwork` 涵蓋（舊的「加入網路／繼續加入」就是它），接受。PR body 的描述要更新（m11） |
| T-C4a 的 Rust 半邊改掃原始碼 | 接受；用變數組出來的句子掃不到（第一輪已提），渲染半邊由 T-C2 補，但 T-C2 的句子太短（m10） |
| T-C2 的 36 dp 負向對照改用 `shrinkWrap` | 接受 |
| 網路摘要、10.5、暱稱編輯、T-C4c 等延後 | 接受；但 m5 的「引用不存在的東西」與 m8 的多台沒有按鈕應列進來 |
| 「開啟 app 設定」沒做 | 已經做了（`intro_pages.dart:157`），PR body 要刪掉這條 |

## 結論重述

APPROVE-WITH-CHANGES。MAJOR-1、MAJOR-2 只要補測試（程式不用改），各附 M5a/M5b/M5c 與 M7/M8/M9/M18/M21/M30 的 FAIL 輸出即可關掉；MINOR 建議至少處理 m1、m2、m4、m11，其餘寫進 #329 checklist。
