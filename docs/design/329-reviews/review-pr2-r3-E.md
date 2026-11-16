# #329 PR 2 第三輪審查 E（winson3QQ/Batman#340，feat/329-pr2 @ ca6d07d，疊在 PR 1 a0f3fbb 上）

審查者 E，獨立對抗式。範圍：`git diff a0f3fbb ca6d07d` 全部（新介面、main.dart 路由、UiState / cbor_mini、圖示 / manifest / Kotlin、§3.4 文字 Dart + Rust、測試），以及第一、二輪每個發現的關閉狀況。
工作副本：`scratchpad/core/pr2E`（`git archive ca6d07d`），沒有動 `C:/src/Batman-329pr2`、`Batman-329pr1`。

## 結論

**APPROVE-WITH-CHANGES**：BLOCKER 0、MAJOR 0、MINOR 9。

第二輪的兩個 C-MAJOR / D-MAJOR 都關了：第 6 列四種紀錄的接線（V2、V8 KILLED）、第 1 列「開啟藍牙設定」（V6 KILLED）、設定頁 `Page.other`、只記新鮮讀取（V11 KILLED）、prober → core 的畫面資料（J、K KILLED）。我找不到「現在就會讓使用者看到錯的東西」的大問題，也找不到安全洞。

但有兩件事要先講清楚：

1. **新使用者主路徑上的好幾條接線仍然沒有任何測試**（MINOR-1）：第 2 列「允許藍牙權限」按了沒反應、歡迎頁按「開始」卡住、看過歡迎頁不寫旗標、離開設定 / 節點頁後首頁不回 `Page.home`、field 版的設定頁出現開發者選項、`JoinChoice.own` 走錯路——每一個改壞後 672 個測試全綠。照本輪 brief 的定義（MAJOR 只給錯誤行為、安全洞、不會 FAIL 的測試），現在程式是對的，所以列 MINOR；但第二輪 C、D 把同類問題（修好的接線沒有測試）判成 MAJOR。**如果照第二輪的標準，MINOR-1 是 MAJOR。** 這是我最建議先處理的一項。
2. **第二輪修正有三項宣稱有測試、實際沒有，其中一項只修了一半**（MINOR-2、MINOR-3）。commit ca6d07d 的訊息寫「tests: the above」，但 D-m8（藍牙設定頁打不開時的提示）、D-m6(b)（`2'` 的讀取時間）沒有測試；D-m6(b) 我用探針確認：節點**剛變成** `2'` 的那一輪，讀取時間仍是上一次本體的時間（或空的），要到下一輪才更新。

## ✅ 我自己跑的（原始輸出）

- 基準：`flutter test --no-pub`（Windows，Flutter 在 `C:/src/flutter`）
  `00:23 +672: All tests passed!`
- Rust（WSL Ubuntu-24.04，`CARGO_TARGET_DIR=$HOME/pr2E-target`，`cargo test --offline`）：batman-proto 每個測試檔都 `test result: ok`（9 / 2 / 5 / 4 / 50 / 8 / 7 / 5 / 0 / 11 / 0+3 ignored / 1 / 40 / 20 / 13 / 6 / 39 / 14 / 36 / 0）；bridge `test result: ok. 63 passed; 0 failed`（含 `t_u4_ui_is_not_a_record`）。

### 改壞對照（每個在自己的副本改一處、跑**全套** `flutter test --no-pub`、還原；腳本 `pr2E/tools/mut.sh`、`batch1.sh`、`batch2.sh`，完整紀錄 `pr2E/mutations.log`；最後用 `diff` 對 `git show ca6d07d:` 確認三個被改過的檔都已還原）

| # | 改壞 | 使用者會遇到什麼 | 結果 |
|---|---|---|---|
| A | `home_page.dart:138` 讀紀錄失敗 → `NetRecords.none`（撤回 D-m9 的接線） | 讀不到紀錄時首頁又給「建立網路」 | **SURVIVED** `+672: All tests passed!` |
| B | `home_page.dart:181` 藍牙設定頁打不開時不顯示提示（D-m8） | 按了沒反應 | **SURVIVED** |
| C | `node_link.dart:310` 撤回 `2'` 的讀取時間（D-m6(b)） | `2'` 顯示舊時間 | **SURVIVED** |
| D | `home_page.dart:193` 拿掉 `_addNode` 的 KeyGate（C-m6） | 不能認領也進得去 | KILLED（`r2 C-m6`） |
| E | `main.dart` 拿掉 `ui.setWelcomed()` | 沒有節點的手機每次開 app 都看歡迎頁 | **SURVIVED** |
| F | `home_page.dart:259` 首頁提示不看 `homeTip` | 「一切正常」時提示卡永遠在 | **SURVIVED** |
| G | `home_page.dart:220` 狀態區時間不看新鮮（C-m8） | 舊時間寫成「讀取於」 | **SURVIVED** |
| H | `home_page.dart:214` `roundsRun < 3` → `< 1` | 第 5 列幾乎不出現 | **SURVIVED** |
| I | `ui_state.dart:208` `RecordUiStore._header` 永遠 false | 長度 0 的 ui 檔永遠寫不進去 → 每次看歡迎頁 | **SURVIVED** |
| J | `prober.dart:92` 錯誤碼不帶畫面資料 | `2'` 沒有 Rust 句子 | KILLED（prober_test） |
| K | `core.dart:559` 拿掉 `s.extra = s.errExtra` | `2'` 顯示上次本體的句子 | KILLED（two_prime_test） |
| L | `intro_pages.dart:158` 「開啟 app 設定」呼叫錯的 method | 被拒後按了沒反應 | **SURVIVED** |
| O | `home_page.dart:240` `SettingsPage(devTrust: true)` | field 版設定頁出現開發者選項（舊控制台、舊認領頁、藍牙測試頁） | **SURVIVED** |
| O2 | `main.dart` `_devTrust = true` | 同上 | **SURVIVED** |
| P | `home_page.dart:153` `_back` 不 `setPage(Page.home)` | 進過設定 / 節點頁回來，首頁停在 `other` / `node` | **SURVIVED** |
| Q | `home_page.dart:204` 開節點頁不 `setPage(Page.node)` | 節點頁不讀這一台 | **SURVIVED** |
| R | `home_page.dart:106` 進背景不 `ui.background()` | 讀取時間不寫回，重開顯示更舊的時間 | **SURVIVED** |
| U | `ui_state.dart:14` 拿掉 U+00AD、U+061C、U+180E | 這些字元進得了暱稱 | **SURVIVED** |
| U2 | `ui_state.dart:14` 拿掉 U+2060–206F、U+FEFF | 同上 | **SURVIVED** |
| Y | `home_page.dart:142` 「上次新增節點沒有做完」不看 devTrust（F48） | field 版出現 devTrust 才有的待辦 | **SURVIVED** |
| Z | `home_page.dart:188` 允許後不通知 NodeLink | 靠 `statusStream` 補上（`app_link.dart:116-119`），影響小 | SURVIVED |
| AA | `home_page.dart:160` 第 2 列「允許藍牙權限」不做事 | **新使用者第一個看到的按鈕按了沒反應** | **SURVIVED** |
| AB | 拿掉 `_remember()` | 不記讀取 | KILLED（`review A-m1`） |
| V1 | `main.dart` 歡迎頁不看「有節點紀錄」 | 升級使用者看到歡迎頁 | KILLED（T-U3） |
| V2 | `records: NetRecords.net` | 第一輪 A-M1 | KILLED（`r2 C-M1`） |
| V5 | `nodes.dart` `JoinChoice.own` → `_memberJoin()` | 隊長的「加入網路」走隊員的加入 | **SURVIVED** |
| V6 | `_settings('x')` | 第 1 列按了沒反應 | KILLED（`r2 C-m2`） |
| V7 | 移除失敗也 `ui.forget` | | KILLED（T-N1） |
| V8 | 拿掉「看我的申請」按鈕字 | | KILLED（`r2 C-M1`） |
| V11 | `_remember` 不看新鮮 | | KILLED（`r2 C-m2`） |
| V15 | 首頁提示卡永遠不顯示（`h.row == 99`） | 1.7 永遠不出現 | **SURVIVED** |
| V16 | `main.dart` 歡迎頁 `onDone` 不換到首頁 | **按「開始」/「跳過說明」後卡在歡迎頁** | **SURVIVED** |

KILLED 10、SURVIVED 21（其中 Z 有其他機制補上）。KILLED 的輸出例：`V2 ... pages_test.dart: r2 C-M1: row 6 with nets [] mnets [] pen...`。

### 探針（只在我的副本，跑完已刪）

1. `2'` 的讀取時間（NodeLink + `two_prime_test` 的 `Script`，每輪看 `readWall`）：
   ```
   PROBE withBody=false atBody=null first2p(i=23) readWall=null final=2026-11-16 06:10:10.977760 view=2'
   PROBE withBody=true atBody=2026-11-16 06:10:11.019167 first2p(i=35) readWall=2026-11-16 06:10:11.019167 final=2026-11-16 06:10:11.160769 view=2'
   ```
   剛變成 `2'` 時，`readWall` 是 null（從沒讀到本體）或**正好等於上一次本體的時間**；下一輪才更新。
2. 暱稱過濾（每個 BMP 的 Cc / Cf / Zl / Zp 字元，加 4 個補充平面字元，各做一個 `ui/state-v1` 再 `load()`）：
   `PROBE-CF taken=15 [U+0600, U+0601, U+0602, U+0603, U+0604, U+0605, U+06DD, U+070F, U+0890, U+0891, U+08E2, U+110BD, U+1D173, U+E0001, U+E0041]`
3. 版面（360×640、字級 2.0、淺色）：移除確認對話框 `PROBE-DIALOG exception=null` 且通過 `androidTapTargetGuideline`；節點頁 + 90 字紅色句子 + warning + lagNote + 技術資訊展開 `PROBE-NODE exception=null`；首頁第 7 列長句 `PROBE-HOME7 exception=null`；歡迎頁第 2、3 頁 `exception=null` 並通過兩條 guideline。
4. 2.2 權限頁，`ask` 丟例外（例如 Kotlin 的 `result.error("ble", "a permission request is already open")`，MainActivity.kt:147）：測試框架抓到未處理的 `StateError`，`PROBE-PERMTHROW ... button-enabled=false`——「繼續」永遠是灰的。

## ⚠️ 只讀程式推論、沒有實測

- P / Q 的使用者影響（首頁停在 `Page.other` 就不再自動讀取、節點頁不讀該台）是照 §4.3.2 與 `core.setPage` 推的，沒有在改壞後實際跑一段時間觀察。
- MINOR-7 的「啟動檢查的訊息在通過時不再顯示」是讀 `main.dart:156-186` 推的（通過時只有 1.1 啟動畫面，然後直接 `pushReplacement`），沒有用 widget 測試渲染。
- 沒有真機：PR 2 的真機場次是在 d3b5d38，第一、二輪的修正都沒有上機。

## ❌ 沒做

- 沒有上真機（brief 禁止 adb）。
- 沒有逐條重查第一輪 A / B 的每一項；以第二輪 C、D 的對照表為起點，對第二輪的修正和仍開著的項目做了改壞與探針。
- 沒有審 PR 1 的檔案（只看 PR 2 對 `core.dart`、`node_link.dart`、`prober.dart`、`app_link.dart` 的改動）。

## 第二輪項目的關閉狀況

| 第二輪項目 | 狀態 | 證據 |
|---|---|---|
| C-M1 / D-M2 第 6 列接線 | ✅ 關 | V2、V8 KILLED |
| D-M1 畫面資料 prober → core | ✅ 關（分層測：prober_test 斷言 `o.extra`、two_prime_test 斷言 `s.extra`） | J、K KILLED |
| D-M2 第 1 列按鈕、設定頁 `Page.other` | ✅ 關 | V6 KILLED；`r2 C-m2` 斷言 `Page.other` |
| C-1 第 2 / 3 列 | ✅ 有測試 | home_logic_test `r2 C-m1` |
| C-2 負向對照 | 部分：第 1 列、設定頁、第 10 列、只記新鮮、第 5 列有；**歡迎頁旗標寫入沒有** | E SURVIVED → MINOR-1 |
| C-3 / D-m2 `RecordUiStore` | ❌ 第三次仍沒有測試 | I SURVIVED → MINOR-5 |
| C-4 / D-m3 T-U6(b) | 首頁那一段有（標記字串）；「值只流向顯示」沒有 | 讀碼：沒有判斷讀 UiState |
| C-5 節點頁沒有下一步按鈕 | ❌ 沒改、沒列偏離 | MINOR-8 |
| C-6 KeyGate | ✅ 關 | D KILLED |
| C-7 / D-m8 多台沒有按鈕 | ❌ 沒改、沒列偏離 | MINOR-8 |
| C-8 狀態區時間 | 一半：關於某台的列改了但**沒有測試**；第 10 列仍是「讀取於 <不新鮮的時間>」 | G SURVIVED → MINOR-3 / MINOR-8 |
| C-9 / D-m7 `roundsRun < 3`、字級 | ❌ 沒改、沒列偏離 | H SURVIVED → MINOR-8 |
| C-10 / D-m10 T-C2 沒渲染的頁 | 對話框改成三行；T-C2 仍沒有 1.1、2.4、歡迎第 2 / 3 頁、對話框、技術資訊展開。我的探針這幾頁都沒有 overflow | MINOR-8 |
| C-11 / D-m11 PR body | ❌ 第三次仍過時 | MINOR-9 |
| D-m1 暱稱 | 一半：加了範圍，但宣稱「Cc, Cf, Zl, Zp」仍漏 15 個；只測了 3 個新字元 | 探針 2；U、U2 SURVIVED → MINOR-4 |
| D-m4 devTrust 閘 | 一半：`SettingsPage` 本身有測試；**從 main → HomePage → SettingsPage 的接線沒有**；F48 待辦沒有 | O、O2、Y SURVIVED → MINOR-1 |
| D-m5 句子引用畫面上沒有的東西 | ❌ 沒改、沒列偏離 | MINOR-8 |
| D-m6 (a) | ✅ 改了、有測試 | home_logic_test `r2 D-m6` |
| D-m6 (b) | ⚠️ 只修了下一輪起；沒有測試 | 探針 1；C SURVIVED → MINOR-2 |
| D-m8 藍牙設定頁打不開時提示 | 改了，**沒有測試**；2.2 的「開啟 app 設定」沒有同樣處理 | B、L SURVIVED → MINOR-3、MINOR-6 |
| D-m9 讀不到紀錄 → 不給「建立網路」 | 純函式有測試；**接線沒有**；`_records` 的初始值仍是 `none` | A SURVIVED → MINOR-3 |
| D-m12 `JoinChoice.own` 的接線 | ❌ 仍沒有測試 | V5 SURVIVED → MINOR-1 |

## MINOR

### MINOR-1　新使用者主路徑和頁面之間的接線仍沒有測試：改壞 11 處、672 個測試全綠（照第二輪標準是 MAJOR）

**情境**（真實使用，從安裝到首頁）：剛裝好 → 1.1 → 歡迎三頁 →「開始」→ 首頁第 2 列「app 還沒有藍牙權限」→「允許藍牙權限」→ 2.2 →「繼續」→ 系統詢問 → 首頁第 3 列 → 新增節點……。這條路上每一個「頁面之間」的接點都沒有測試：

- AA：第 2 列按鈕不做事 → 新使用者第一個按鈕就卡住。
- V16：歡迎頁 `onDone` 不換頁 → 按「開始」/「跳過說明」沒反應。
- E：不寫「看過歡迎頁」→ 加入節點前每次開 app 都重看。
- P：`_back` 不回 `Page.home` → 進過設定或節點頁之後，首頁的自動讀取依 §4.3.2 不再恢復。
- Q：節點頁不設 `Page.node` → 進節點頁不讀這一台（§5.5「進節點頁 = 對這一台讀一輪」）。
- O / O2：devTrust 從 `main.dart` 經 `HomePage` 到 `SettingsPage` 的傳遞 → field 版看得到開發者選項（舊控制台、舊認領頁、藍牙測試頁）。舊頁裡的危險按鈕另有 `DevOnlyButton`，所以不是直接的安全洞。
- F / V15：1.7 提示卡（永遠顯示 / 永遠不顯示）。
- R：進背景不寫讀取時間（§4.6「進背景時寫一次」）。
- Y：F48 待辦不看 devTrust（第二輪 D-m4 已提）。
- L：2.2 被拒後「開啟 app 設定」。
- V5：舊控制台「加入網路」的 own 路徑（T-N2 的負向對照「分流條件調換 → FAIL」只對純函式成立；第二輪 D-m12）。

**證據**：上表各列 `+672: All tests passed!`。T-U3 只斷言歡迎頁「出現 / 不出現」，沒有按「開始」；`r2 C-m2` 斷言進設定是 `Page.other`，沒有斷言回來是 `Page.home`；`r2 D-m4` 直接建 `SettingsPage(devTrust: …)`。

**為什麼不是 MAJOR**：現在的程式在這幾處都是對的；brief 的 MAJOR 定義不包括「沒有測試」。但第二輪把「修好的接線沒有測試」判 MAJOR，而這裡 AA、V16 是比第 6 列按鈕更前面、每個新使用者都會走的路。

**修法**（都用現有的 `FakeRust`、`MemStore`、mock `dev.batman/platform`）：
1. `BatmanApp` 測試接著 T-U3：沒有節點、沒看過 → 按「跳過說明」→ 出現「可以做的事」、`MemStore.writes == 1`（或 Rust mock 收到 `storeWriteCas` 的 `ui/state-v1`）；再按一次「開始」路徑。負向對照 E、V16。
2. 首頁第 2 列：`a.link.radio(permission: false)` → 按「允許藍牙權限」→ 出現 2.2 →「繼續」→ mock 收到 `blePermissions`；回 true → 回首頁。負向對照 AA。2.2 回 false → 按「開啟 app 設定」→ mock 收到 `appSettings`（L）。
3. 首頁 → 設定 → 返回 → `a.link.core.page == Page.home`；首頁 → 點節點列 → `Page.node`、返回 → `Page.home`。負向對照 P、Q。
4. `BatmanApp` 的 field mock（`devTrust` 回 false）→ 首頁 → 設定 → 沒有「開發者選項」。負向對照 O、O2。
5. 首頁 row 14 + `homeTip` false / true → 有 / 沒有「第一次使用的提示」；按「知道了」→ `homeTip` 寫入。負向對照 F、V15。
6. `HomePage` 收 `AppLifecycleState.paused` → `MemStore.writes` +1（R）；`devTrust: false` + `listPending` 有一筆 → 沒有「上次新增節點沒有做完」（Y）；nodes_update_send_test 加 own 與「選這支手機建立的網路」兩例（V5）。

### MINOR-2　D-m6(b)「`2'` 有自己的讀取時間」只修了一半：剛變成 `2'` 的那一輪仍是上一次本體的時間

**情境**：一台節點連兩個全輪只回錯誤碼，首頁 / 節點頁換成 Rust 的灰色「狀態未知」。這一刻「讀取於」寫的是上一次讀到本體的時間（例如半小時前）；從沒讀到本體的節點則沒有時間。`_remember` 同時把 `('unk', 舊時間)` 存進 `ui/state-v1`。要等下一個全輪（約 60 s）才更正。

**證據**：`node_link.dart:309-310` 在 `core.result(...)` 之後立刻看 `core.states[a.id]?.view == "2'"`；但 `2'` 是在 `_end`（`core.dart:556-560`）設的，而 `_end` 只由 `tick` 呼叫（`core.dart:521`），`tick` 在後面的 `_pump()` 裡。所以變成 `2'` 的那一次錯誤碼不會更新 `readWall`。探針 1 的輸出：`first2p ... readWall=2026-11-16 06:10:11.019167`（= `atBody`）、無本體時 `readWall=null`。改壞 C 全綠：這個修正沒有任何測試。

**修法**：在 `_pump()` 的 `core.tick` 之後，對 `view == "2'"` 而 `readAt` 比 `readWall` 對應的時間新的節點補上 `readWall`（或讓 core 在設 `2'` 時記下一個旗標給 NodeLink 讀）。測試就用探針 1 的寫法：斷言第一次看到 `2'` 時 `readWall` 不是 null、也不等於本體的時間；負向對照 = 撤回修正。

### MINOR-3　第二輪修正裡宣稱有測試、實際沒有的三項（commit 訊息過度宣稱）

ca6d07d 的訊息列了四項修正，最後寫「tests: the above」。實際：
- D-m8 藍牙設定頁打不開時的提示：沒有測試（B SURVIVED）。
- D-m9 讀不到紀錄 → 中性的「加入網路」：只有純函式測試；首頁 `_todos` 的 `catch` 改回 `none` 全綠（A SURVIVED）。另外 `_records` 的初始值（`home_page.dart:80`）仍是 `NetRecords.none`——正是這個修正要避免的狀態：`_todos` 回來之前如果第 6 列成立，按鈕是「建立網路」。實際上 `listNets` 幾毫秒就回來，時間窗很小，但初始值改成 `unknown` 不用任何成本。
- D-m6(b)：見 MINOR-2。
- d7b7e60 的 C-m8（狀態區時間只看那一台、只在新鮮時）：G SURVIVED。

使用者規則：「宣稱的修正要有負向對照」「不誇大」。**修法**：各補一個測試（藍牙 mock 回 false → 出現「請到手機的設定打開藍牙」；`FakeRust.crateApiOwnerListNets` 丟例外 + 第 6 列 → 「加入網路」且沒有「建立網路」；第 8 列 + 另一台新鮮 → 狀態區沒有「讀取於」），`_records` 初值改 `unknown`，並在 PR body 更正。

### MINOR-4　暱稱過濾宣稱「Cc, Cf, Zl, Zp」，實際漏 15 個；空白暱稱也收

**證據**：探針 2：U+0600–0605、U+06DD、U+070F、U+0890–0891、U+08E2（阿拉伯數字記號等 Cf），以及補充平面的 U+110BD、U+1D173、U+E0001、U+E0041（tag 字元；Dart 的非 unicode `RegExp` 看到的是代理對，`ui_state.dart:14` 的範圍抓不到）都照收。U、U2 SURVIVED：新增的範圍裡只有 U+2028、U+200B、U+0085 三個有測試。另外 `_parse` 對空字串、全空白暱稱不拒絕（`ui_state.dart:96` 只檢查長度上限），設計 §5.3 是「1–24 個字，去掉控制字元與前後空白」；空暱稱會讓首頁寫成「 的身分和這支手機記錄的不同」。

**為什麼是 MINOR**：PR 2 沒有寫暱稱的入口，檔案是密封的，只有「我們自己的錯」這個角色。

**修法**：`RegExp(r'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', unicode: true)`，加 `nick.trim().isEmpty` 拒絕；測試對整個 BMP 的這四類跑一次（探針 2 的寫法）；PR 4 的寫入端用同一個函式。

### MINOR-5　`RecordUiStore` 第三次仍沒有任何測試（A-m8、B-m7、C-3、D-m2）

I SURVIVED：`_header` 永遠 false 時，一個長度 0 的 `ui/state-v1` 不再走「先 `storeRemove` 再寫」，每次寫都失敗，沒有節點的手機每次開 app 都看到歡迎頁。設計 T-U2 要四種真檔案（長度 0、版本位元組、改密文、內文版本 2）且「下一次寫入成功、重新載入讀得到」；現在的 T-U2 用 `MemStore.header` 模擬，跳過了真正判斷字串的那一行（`ui_state.dart:208`）和 `write` 的 generation 檢查（`:226`）。**修法**：用 `RustLib.initMock` 讓 `crateApiOwnerStoreReadSealed` / `crateApiClaimStoreSealParams` 丟真的 Rust 錯誤字串（從 bridge 原始碼取，`NotARecord`、`UnknownVersion`），跑 T-U2 (a)(b)；負向對照 I。

### MINOR-6　2.2 權限頁對平台錯誤沒有處理：按鈕永遠灰掉、「開啟 app 設定」沒有回饋

- `PermissionsPage._go`（`intro_pages.dart:121-133`）沒有 try：`blePermissions` 丟例外（Kotlin `MainActivity.kt:147` 在已有請求時回 `result.error("ble", ...)`）→ 未處理的非同步錯誤，`_asking` 留在 true，「繼續」永遠是灰的。探針 4：`button-enabled=false`，測試框架抓到 `StateError`。使用者只能按返回。
- 「開啟 app 設定」（`:158`）沒有 `catchError`，回 false 時沒有提示——D-m8 只修了首頁的藍牙那一顆。

**修法**：`_go` 包 try/finally（失敗當成被拒絕，顯示橫幅）；「開啟 app 設定」走首頁的 `_settings` 同一個做法；各一個測試。

### MINOR-7　啟動檢查通過時，原本顯示的訊息不再出現，也沒有列為偏離

舊的啟動頁會顯示 `lines` 的每一行。PR 2 在通過時只顯示 1.1，接著直接換到首頁（`main.dart:169-186`），所以下面這些使用者以前看得到的訊息現在看不到：`softOwnerEnc` 的「這支手機的復原／隊員金鑰只有軟體保護，只適合開發使用」（`:132`，dev 版）、「找不到安裝紀錄，但手機裡還有節點資料：金鑰保持原樣，不會重建」（`:202`）、「已清除 N 個中途中斷的存檔」（`:194`）。設計 §5.2 把 `softOwnerEnc` 的警告放在 10.5 與 3.1，兩者都是之後的 PR，所以 PR 2 到 PR 4 之間這個警告在任何畫面上都沒有；T-H4 的「`softOwnerEnc` 時 10.5 有警告」也沒有。各認領入口的拒絕原因則有 KeyGate 灰色入口顯示，沒問題。**修法**：列進「和設計不同」與 #329 checklist；或在首頁加一個 `BatBanner`（只有 `softOwnerEnc` 時）直到 10.5 存在。

### MINOR-8　第二輪仍開著、既沒改也沒列在「和設計不同」的項目

PR body 的「和設計不同」只寫了 T-N2、T-C4a、按鈕 shrinkWrap、延後的功能。下面這些仍是現況，要嘛做、要嘛寫進偏離與 #329 checklist：
- 節點頁對 `node_state == 1`、藍牙 / 權限沒有下一步按鈕（§5.5「主要按鈕照 §5.1 第 6 列」；C-5）。`whyNext(noPermission)` 仍叫人「回首頁按『允許藍牙權限』」。
- 第 7、8 列多台的 `showList` 沒有按鈕（C-7、D-m8）。
- 第 10 列沒有 `node`，狀態區時間取 `freshest`（`home_page.dart:217-220`），所以從背景回來、全部不新鮮時寫「讀取於 <不新鮮的時間>」，不是 T2 的「上次讀取」（C-8 的後半）。
- `firstRounds = roundsRun < 3`（第二輪結束到第三輪開始之間仍算頭兩輪）；字級 21 / 19 / 17 / 15 / 26 不在 §3.1 的六級（C-9、D-m7；H SURVIVED）。
- Rust 句子引用新畫面上沒有的東西：「對照下面『網路：』的名稱」、「可在『手機 Wi-Fi』設定」；首頁「看我的申請」「加入隊長的網路」打開的舊控制台沒有同名按鈕（D-m5；§3.4 規則 3）。
- T-C2 仍沒有 1.1、2.4、歡迎第 2 / 3 頁、移除對話框、技術資訊展開、長句子。我的探針（360×640、2.0 倍）這幾頁都沒有 overflow，所以只是覆蓋缺口，不是錯誤。
- 「UiState 的值只流向顯示用的 widget」沒有測試鎖（§4.6 寫「測試鎖住」）。我讀過所有讀 `UiState` 的地方（`main.dart:177` `welcomed`、`home_page.dart:34,40,259`、`node_page.dart` 經 `nodeInfo`），目前都只用於顯示。

### MINOR-9　PR body 第三次仍過時，而且沒有目前 head 的測試結果

`gh pr view 340`（head `ca6d07d`）仍寫：`d3b5d38`、`570 passed`（現在 672）、T-C2「8 頁 … 108 passed」（現在 14 頁、168 例）、「『管理者金鑰』『成員金鑰』保留」（現在是「隊員金鑰」，`main.dart:132`、key_abilities_test）、joinChoice「照 T-N2：net 優先」的兩態描述（現在四態，兩者都有時會問）、「『開啟 app 設定』按鈕沒有做」（`MainActivity.kt` 的 `appSettings` 已經做了）。第一、二輪的修正和它們的負向對照輸出都沒寫；真機結果只有 d3b5d38，之後首頁邏輯、狀態區時間、移除對話框、Kotlin 兩個 method 都改過，沒有重跑。使用者規則：PR body 要有實際的測試結果，模擬的要標明。**修法**：merge 前改寫 body，附 ca6d07d（或修完 MINOR 之後的 head）的全套輸出、改壞對照、還沒上機的項目。

## 依角色的安全檢查

- **同一支手機的其他 app**：`ui/state-v1` 在 app 私有目錄、用紀錄金鑰（Keystore）密封（`RecordUiStore` 用 `storeSealParams` + Kotlin `seal` + `storeWriteCas`）。新的 Kotlin method `appVersion`、`bluetoothSettings`、`appSettings` 不吃 Dart 傳的參數，只開系統頁或回 `BuildConfig`；`appSettings` 用自己的 `packageName`。manifest 只加 `screenOrientation`，沒有新的 exported 元件。沒有發現問題。
- **被入侵的節點**：新畫面上的節點內容（`sentence`、`warning`、`lagNote`、`version`、`tech`、`netId`）都經 Rust 組字或 `shown()`；首頁第 6 列不用節點句子；只回錯誤碼的節點到不了「一切正常」（`home_logic.dart:135-139`，A-M2 的測試）；身分不符排在第 4 列、節點頁給安全警告。UiState 不存任何節點字串（T-U6(b) 的標記字串測試，`pages_test.dart:221`）。
- **附近的攻擊者**：BLE 位址不再顯示在認領頁（S10）。沒有新面。
- **我們自己的錯 / 壞掉的 ui 檔**：`cborDecode` 嚴格（型別、截斷、重複鍵、深度 ≤ 4、尾端位元組、8 位元組負值）；`_parse` 對值域、時間 1970–2100 檢查；任何問題都是「不存在」；沒有任何判斷讀 UiState（`decideHome` 不看 `prev`；`main.dart` 只用 `welcomed` 決定顯示）。缺口：暱稱過濾不完整（MINOR-4）、`RecordUiStore` 沒有測試（MINOR-5）、devTrust 傳遞沒有測試（MINOR-1 的 O / O2）。
- **拿到已解鎖手機的人**：移除要確認（T-N1 cancelled）、先留副本（T-N1 no copy）、在 session 佔用下經 `RecordWriter`；和現況的長按忘記相比沒有新能力。
- **fail-open 只給顯示**：成立。第 6 列的紀錄判斷讀不到時已改成中性的「加入網路」（接線沒有測試，MINOR-3）。

## 對 PR body「和設計不同」的判斷

| 項目 | 判斷 |
|---|---|
| T-N2 vs S3（joinChoice） | 接受現在的四態（own / member / ask / none），它涵蓋 S3 與 T-N2 兩邊；S3 的「加入中 → 接著做」由 `_joinNetwork` 本身處理。設計回填成同一句。但 T-N2 的負向對照只對純函式成立，own 路徑的接線沒有測試（V5，MINOR-1）。PR body 的兩態描述要改（MINOR-9） |
| T-C4a 的 Rust 一半改掃原始碼 | 接受；渲染那一半由 T-C2 的 `retired` 掃，但 T-C2 的句子很短（MINOR-8） |
| 按鈕 `shrinkWrap` 讓「36 高 → FAIL」成立 | 接受 |
| 延後：網路摘要、10.5、暱稱編輯、T-C4c、T-H2/3/5 完整版 | 接受；但 10.5 延後連帶 `softOwnerEnc` 警告在 PR 2–4 之間沒有任何畫面（MINOR-7），要寫出來 |
| 「開啟 app 設定」沒做 | 已經做了，這條要刪（MINOR-9） |

## 檔案

- 工作副本與工具：`C:/Users/yello/AppData/Local/Temp/claude/C--Users-yello-Desktop-Batman/50df948c-82da-4f59-a554-0cabd26317a4/scratchpad/core/pr2E/`（`tools/mut.sh`、`tools/batch1.sh`、`tools/batch2.sh`、`mutations.log`、`baseline.txt`、`rust.txt`）。探針測試檔跑完已從副本刪除。
