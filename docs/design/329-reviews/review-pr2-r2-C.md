# #329 PR 2 第二輪審查 C（winson3QQ/Batman#340，feat/329-pr2 @ 596baeb，疊在 PR 1 a0f3fbb 上）

審查者 C（獨立）。範圍：`git diff a0f3fbb 596baeb` 全部（不是只看第一輪修正）。程式碼匯出到自己的資料夾
`scratchpad/core/pr2C`（`git archive 596baeb app tests`），沒有動 `C:/src/Batman-329pr2` / `-329pr1`；跑完改壞對照後已比對
`lib/`、`rust/bridge/src` 與 596baeb 完全相同（`diff -r` → IDENTICAL），沒有留下 `.orig`。

## 結論

**APPROVE-WITH-CHANGES**：BLOCKER 0、MAJOR 1、MINOR 11。

第一輪的五個 A-MAJOR、三個 B-MAJOR 在行為上都修了，大部分有能 FAIL 的測試（下表）。剩下一個 MAJOR：第一輪最重要的修正（首頁第 6 列的按鈕照手機的網路紀錄決定，A-M1 / B-M1）只有純函式有測，**首頁實際去讀紀錄的那段接線沒有任何測試**：把首頁改回第一輪的行為（永遠「加入網路」），全部測試照過。

## ✅ 我自己跑的（原始輸出）

| 項目 | 結果 |
|---|---|
| `flutter test --no-pub test/`（596baeb，Windows，Flutter 在 `/c/src/flutter`） | `00:32 +656: All tests passed!` |
| batman-proto `cargo test --offline`（WSL Ubuntu-24.04，自己的 `CARGO_TARGET_DIR=~/tgt-pr2C`） | 全部 `test result: ok`（9 / 2 / 5 / 4 / 50 / 8 / 7 / 5 / 11 / 1 / 40 / 20 / 13 / 6 / 39 / 14 / 36 …，0 failed） |
| bridge `cargo test --offline` | `test api::simple::tests::t_u4_ui_is_not_a_record ... ok`、`test result: ok. 63 passed; 0 failed` |
| T-U4 負向對照：`RECORD_KINDS` 加 `"ui"` | `t_u4_ui_is_not_a_record ... FAILED`（`panicked at src/api/simple.rs:119:9`） |
| T-C2 負向對照抽查：`BatButton` 高度 54 → 36 | `KILLED (+104 -64)`：`Tappable objects should be at least Size(48.0, 48.0)` |
| Rust 改動是否只有字串 | `git diff a0f3fbb 596baeb -- app/rust` 濾掉含 `"` 的行與註解後，只剩 `t_u4` 測試本身的行；`if`、代碼表沒有變 |

### 改壞對照（每一個都在自己的副本改一處、跑指定的測試檔、還原）

| # | 改壞什麼 | 守的規則 / 第一輪項目 | 結果 |
|---|---|---|---|
| M1 | 沒有權限 **而且** 沒有節點時走第 3 列（第 2、3 列對調） | T-H1 相鄰列 2/3 | **SURVIVED** |
| M4 | 沒加入網路的節點記成 `bad` | A-m1 | KILLED |
| M5 | `_remember` 也記不新鮮的讀取 | A-m10 | **SURVIVED** |
| M6 | `joinChoice(true,true)` → own | A-M4 / B-M2 | KILLED（2 個測試） |
| M8 / M9 | 暱稱不擋控制 / 方向字元；讀取時間不檢查範圍 | B-m1 | KILLED / KILLED |
| M10 | 載入時不刪沒有紀錄的節點 | §4.6 | KILLED |
| M11 | 歡迎頁只看 `!welcomed`（不看有沒有節點紀錄） | T-U3 | KILLED（4 個） |
| M12 | 副本沒留成也照刪 | T-N1 / T17 | KILLED |
| M13 | 新鮮但沒有畫面資料也能到第 14 列 | A-M2 | KILLED |
| M14 | 2' 不換成錯誤回答的畫面資料 | A-M2 | KILLED |
| M15 | 身分不符的下一步改回「會自動重試」 | A-M3 | KILLED |
| M16 | 第 1 列「開啟藍牙設定」按鈕拿掉 | 第一輪 B-m2 的修正 | **SURVIVED** |
| M17 / M18 / M19 | 每輪都寫；檔頭壞不先 `remove`；寫入失敗後不重讀 generation | T-U1 / T-U2 / §4.6 | KILLED ×3 |
| M20 | 未來的讀取時間照樣顯示時間 | T-U5 | KILLED |
| M21 | 不新鮮的讀取也上顏色（節點列） | T2 / T-H2(a) | KILLED |
| M22 | 進設定頁不設 `Page.other` | A-m3 的修正 | **SURVIVED** |
| M23 | 第 10 列兩種句子對調 | A-m5 的修正 | **SURVIVED** |
| M24 | 首頁讀到 net 紀錄時當成沒有 | A-M1 / B-M1 的接線 | **SURVIVED** |
| M25 | 提示卡不只在第 14 列出現 | §5.2 1.7 | KILLED |
| M27 | 「還沒輪到」也算結論（提早離開第 5 列） | §5.1 第 5 列 | **SURVIVED** |
| M32 / M33 | 移除後不清 UiState；不經確認就移除 | T-N1 | KILLED / KILLED |
| M35 | 歡迎頁按「開始 / 跳過說明」不寫旗標 | §5.2 | **SURVIVED** |
| M36 / M37 / M38 | 第 6、7 列用不新鮮的讀取；第 14 列不要求每台都新鮮 | A-M5 / T2 | KILLED ×3 |
| M39 | 首頁把 `records` 固定成 `NetRecords.net`（= 第一輪的行為） | A-M1 / B-M1 | **SURVIVED**（跑 `test/ui`、`key_abilities_test`、`nodes_update_send_test`、`join_choice_test`） |
| M40 | 按鈕高度 36 | T-C2 | KILLED |

## ⚠️ 只推論、沒有實測

- 「使用者會看到什麼」是讀程式路徑推的（home_page.dart → `NodesPage` 等），沒有在真機或完整 widget 流程走過。
- `RecordUiStore` 的檔頭判斷（`'$e'.contains('NotARecord')`）依賴 FRB 把 Rust `Result<_, String>` 的 `format!("{e:?}")` 原樣帶到 Dart（owner.rs:35、claim.rs:78 的 `map_err`）；我讀了原始碼，沒有在真機觸發。

## ❌ 沒做

- 沒有真機（規則禁止 adb / flutter run）。
- 沒有逐字比對畫布 gen.js 與每個畫面的文字，只抽查了「加入隊長的網路」「還沒有節點」。

## 第一輪項目的關閉狀況

| 第一輪 | 現況 | 證據 |
|---|---|---|
| A-M1 / B-M1 第 6 列按鈕 | 行為修了；**接線沒有測試** → 本輪 MAJOR-1 | M24、M39 存活 |
| A-M2 / 2' | 修了，有測試 | M13、M14 KILLED |
| A-M3 節點頁依原因給下一步 | 修了，有測試 | M15 KILLED |
| A-M4 / B-M2 joinChoice | 修了：兩者都有時問；有純函式與舊控制台接線測試 | M6 KILLED（-2） |
| A-M5 / B-M3 測試證明力 | 大部分修了；相鄰列 2/3 漏了（MINOR-1）；歡迎頁兩個條件都有測 | M11、M21、M36–M38 KILLED；M1 存活 |
| B-m1 UiState 值域 | 修了 | M8、M9 KILLED |
| A-m1 | 修了 | M4 KILLED |
| A-m2 / B-m2 第 1 列按鈕 | 按鈕做了（Kotlin `bluetoothSettings`），**沒測試**；多台的「捲到清單」仍沒有按鈕 | M16 存活 → MINOR-2、MINOR-7 |
| A-m3 設定頁 `Page.other` | 修了，沒測試 | M22 存活 → MINOR-2 |
| A-m4 舊啟動頁閃一下 | 修了（main.dart：`_report == null \|\| (_ok && _app != null)` 一直顯示 1.1） | 讀碼 |
| A-m5 第 10 列句子 | 修了，沒測試 | M23 存活 → MINOR-2 |
| A-m10 `_remember` 只記新鮮 | 沒測試 | M5 存活 → MINOR-2 |
| B-m3 / A-m6 用詞（SAS、成員金鑰） | 修了；掃描也擋 SAS、成員 | wording_test、layout_test 的 `retired` |
| B-m4 `roundsRun < 3`、B-m5 字級 | 沒改，也沒在 PR 說明 | MINOR-9 |
| B-m7 RecordUiStore / T-U6(b) / 「只流向顯示」 | 沒做 | MINOR-3、MINOR-4 |
| A-m7 / B-m8 T-C2 覆蓋 | 補了藍牙關閉、身分不符、連不到、沒有節點、節點頁身分不符；仍缺幾頁 | MINOR-10 |

## MAJOR

### MAJOR-1　首頁第 6 列「照網路紀錄決定按鈕」的接線沒有測試：改回第一輪的錯，全部測試照過

**情境**：第一輪 A-M1 / B-M1 的錯是「新使用者第一台節點加好、還沒有任何網路，首頁唯一的按鈕卻是『加入網路』」。修正分兩半：`decideHome` 依 `HomeInputs.records` 選按鈕（home_logic.dart:92-96，有測試），以及首頁去讀手機的 `net/`、`mnet/`、`mpend/` 檔名算出 `records`（home_page.dart:128-138 `_todos`）。第二半沒有任何測試：在所有 widget 測試裡 `listNets` 打到假的 `RustLibApi.noSuchMethod` → 例外 → `catch (_) {}` → `records` 永遠是 `none`，所以測試從來沒有走過「手機有網路」的那條路。

**證據**：
- M24（`recs = NetRecords.net` → `NetRecords.none`，有網路的手機被當成沒有，會給「建立網路」——再建一個網路會讓整隊分成兩個網路）：`test/ui` + `key_abilities_test` 全過，SURVIVED。
- M39（build 裡 `records: _records` → `records: NetRecords.net`，正好是第一輪的行為：沒有網路的新使用者拿到「加入網路」）：`test/ui`、`key_abilities_test`、`nodes_update_send_test`、`join_choice_test` 全過，SURVIVED。
- 設計 T-C3 的負向對照明寫「沒有 net 紀錄時給『加入網路』→ FAIL」。PR 2 的版本做不到。

**修法**：在 `pages_test`（或 layout_test）的 `FakeRust` 實作 `crateApiOwnerListNets`、`crateApiMemberListMnets`、`crateApiMemberListPends`，對 `HomePage` 跑四種（net / 只有 mnet / 只有 mpend / 都沒有）+ 一台 `node_state == 1` 的新鮮讀取，斷言狀態區的按鈕文字（「加入網路」/「加入網路」/「看我的申請」/「建立網路」+「加入隊長的網路」）；附 M24、M39 的改壞 → FAIL 輸出。順便測「列檔名丟例外」時不要變成「建立網路」（見 MINOR-6 的同類問題；fail-open 到「建立網路」比到「加入網路」危險：會多建一個網路）。

## MINOR

**MINOR-1　T-H1 漏了相鄰列 2/3，而那正是新使用者最常見的狀態。** 沒有藍牙權限 + 還沒有節點（剛裝好、看完歡迎頁）兩列同時成立；設計 T-H1 的八個案例包含它（互斥的只有 3/4、4/5、5/6、13/14）。M1（`noPermission && ns.isNotEmpty`）SURVIVED：home_logic_test 的第 2 列測試都帶一台節點。修法：`home([], blocked: Why.noPermission)` → 第 2 列，附 M1 → FAIL。

**MINOR-2　第一輪的幾個修正沒有負向對照。** M16（第 1 列「開啟藍牙設定」按鈕）、M22（設定頁 `Page.other`，A-m3）、M23（第 10 列兩種句子，A-m5）、M35（歡迎頁旗標寫入；拿掉後每次開 app 都再看一次歡迎頁，直到有節點）、M5（`_remember` 只記新鮮讀取，A-m10）、M27（第 5 列「還沒輪到不算結論」）全部存活。規則是「每個宣稱的修正要有負向對照」。修法：各補一個 widget / 純函式測試（第 1 列的 `layout_test` 那頁直接斷言 `find.text('開啟藍牙設定')`；設定頁斷言 `link.page`；IntroPages 按「跳過說明」後 `MemStore.writes == 1`）。

**MINOR-3　`RecordUiStore` 完全沒有測試（B-m7 仍開著）。** 所有 UiState 測試都用 `MemStore`，不經過 `RecordUiStore.read/write`：檔頭判斷靠 `'$e'.contains('NotARecord') || contains('UnknownVersion')`（ui_state.dart:208），`write` 的 `p.generation != expectedGen + 1` 檢查（:226）也沒人測。字串格式一改（例如 Rust 錯誤改成 Display），檔頭壞的檔就會變成「每次寫入都失敗」——只影響顯示，所以 MINOR。修法：用 `RustLib.initMock` 對 `RecordUiStore` 跑 T-U2 (a)(b)。

**MINOR-4　§4.6 寫明「測試鎖住」的兩件事仍沒有測試：T-U6(b)（假節點的名稱 / 句子帶標記字串，跑完後搜尋 `ui/state-v1` 明文）與「UiState 的值只流向顯示用的 widget」。** 現在的保護是結構上的（`noteReads` 只收四種種類、`encode` 只寫 1/2/4），我讀碼找不到洩漏；但 PR 2 是引入 UiState 的 PR，T-U6(b) 至少可以先做首頁這一段（`StatusView.sentence` 帶標記 → `_remember` → 搜 `MemStore.plain`）。

**MINOR-5　節點頁對「還沒加入網路」與藍牙 / 權限問題沒有下一步按鈕。** §5.5：「`node_state == 1` 的節點…主要按鈕照 §5.1 第 6 列」；節點頁只顯示「還沒加入隊伍網路」，沒有句子也沒有按鈕（node_page.dart:99-103 只放 warning / lagNote / whyNext）。使用者從首頁點那一列進來就停住，要按返回才看得到按鈕。藍牙關閉時節點頁也沒有「開啟藍牙設定」；`whyNext(noPermission)` 寫「請回首頁按『允許藍牙權限』」，引用別頁的按鈕（§3.4 顯示規則 3）。修法：節點頁的狀態區沿用首頁同一個 `HomeAction` → 按鈕對應。

**MINOR-6　第 3 列狀態區的「新增節點」不看 KeyGate。** 「可以做的事」裡的「新增節點」在不能認領時是灰的（home_page.dart:265 `enabled: widget.keys.claim`），但第 3 列狀態區那一顆（:238）與待辦「繼續完成」（:248）都直接 `_addNode`。不是安全問題：`ClaimPage._claim` 每次認領前會再讀金鑰等級並拒絕（claim.dart:331-335）。但使用者要先掃完 QR 才被拒，和同一頁的灰色入口矛盾。修法：`_addNode` 開頭看 `widget.keys.claim`，不能用時狀態區的按鈕灰掉並顯示 `refusal(KeyUse.claim)`。

**MINOR-7　多台紅 / 多台連不到時沒有按鈕。** `HomeAction.showList` 在 `actionText` 是 `null`（home_page.dart:205-214），設計第 7、8 列多台是「捲到節點清單」。清單就在下面，影響小；但 PR 的「和設計不同」沒有列這一項。

**MINOR-8　狀態區的「讀取於 HH:MM:SS」取的是所有節點裡最新的一次讀取（home_page.dart:204、233）。** 第 8 列「手機連不到節點 X」下面寫的是另一台的讀取時間；從背景回來第 10 列（全部不新鮮、unk）仍寫「讀取於」，不是 T2 的「上次讀取」。修法：時間取決定這一列的那台（`h.node`），不新鮮時用「上次讀取」。

**MINOR-9　第一輪 B-m4、B-m5 沒處理也沒說明。** `firstRounds = roundsRun < 3`（home_page.dart:201、node_page.dart:97；`roundsRun` 在一輪開始時 +1，core.dart:334）；字級 21（`Fs.hero - 3`）、19、17、15、26 不在 §3.1 的六級裡（設計狀態區那句是 24）。要嘛改，要嘛寫進「和設計不同」。

**MINOR-10　T-C2 仍沒渲染的頁 / 狀態**：1.1 啟動畫面、2.4 金鑰不足頁、歡迎頁第 2、3 頁（第 3 頁有 `BatBanner`）、2.2 被拒絕後（橫幅 + 兩顆按鈕）、移除確認對話框（內文約 5 行，§3.2 說 ≤ 3 行；「取消」在 `actions` 裡和「移除」並排，§3.2 說取消固定在主要按鈕下方）、第 7 列 64 字的紅色句子在 2.0 倍字級、節點頁技術資訊展開。

**MINOR-11　PR body 過時。** 仍寫 `d3b5d38`、`570 passed`、「『管理者金鑰』『成員金鑰』保留」（現在是「隊員金鑰」）、joinChoice「照 T-N2：net 優先」（現在兩者都有時會問）、「『開啟 app 設定』按鈕沒有做」（現在做了，Kotlin `appSettings`）；沒有 596baeb 的測試結果與第一輪修正的負向對照輸出。全域規則：PR body 要有實際輸出。

## 依角色的安全檢查

- **同一支手機的其他 app**：`ui/state-v1` 在 app 私有目錄、經 Keystore 封裝（`RecordUiStore` 用 `storeSealParams` + `seal` + `storeWriteCas`）。內容只有旗標、暱稱、四選一種類、時間；`noteReads` 不在 `lookKinds` 的值直接丟（ui_state.dart:182），`encode` 只寫 1/2/4。沒找到秘密或節點字串進檔。Kotlin 新增的 `bluetoothSettings` / `appSettings` 只開固定的系統頁，不吃 Dart 傳的參數；`appVersion` 只讀 `BuildConfig`。
- **被入侵的節點**：新畫面顯示的是 Rust 組好的句子（`shown()` = `display_name` + 64 字，statuspage.rs）；版本、netId、tech 只在收合的技術資訊。首頁狀態區對 `node_state == 1` 不用節點句子（home_logic.dart:97）。2' 改用錯誤回答本身的畫面資料（M14 守住），一台只回錯誤碼的節點不再能讓首頁變綠（M13 守住）。
- **我們自己的錯 / 壞掉的 ui 檔**：`cborDecode` 嚴格（型別、截斷、重複鍵、深度 ≤ 4、尾端位元組），`_parse` 對值域與暱稱字元檢查（M8、M9 守住），任何問題當成不存在；讀時間有界（1970–2100），build 不會丟 `RangeError`。沒有任何判斷讀 UiState：`decideHome` 不看 `prev`；main.dart 只用 `welcomed` 決定要不要顯示歡迎頁（顯示）。
- **拿到已解鎖手機的人**：移除要確認（M33 守住）、先留副本（M12 守住）、在 session 佔用下經 `RecordWriter`；和現況長按忘記相比沒有新能力。

## 對 PR body「和設計不同」的判斷

| 項目 | 判斷 |
|---|---|
| T-N2 vs S3 | **接受現在的做法**：只有 net → 自己的網路、只有 mnet → 隊員、兩者都有 → 問、都沒有 → 說怎麼開始。S3 的「加入中 → 接著做」由 `_joinNetwork` / `_memberJoin` 本身涵蓋（nodes.dart:625 註解），「其他 → 選網路」就是兩者都有時的選單。但 PR body 的描述要改（MINOR-11），設計回填時寫成三態加 none |
| T-C4a 的 Rust 半邊改掃原始碼 | 接受（`retired` 也擋了 SAS、成員）；Rust 句子在畫面上的那一半由 T-C2 的 `retired` 掃渲染結果 |
| 按鈕 `shrinkWrap` 讓「高度 36 → FAIL」成立 | 接受，M40 實測 KILLED |
| 網路摘要、10.5、暱稱編輯、T-C4c、T-H2/3/5 完整版延後 | 接受；但第 6 列按鈕的接線不能沒有測試（MAJOR-1） |
| 「開啟 app 設定」沒做 | 已經做了，body 過時 |

## 檔案

- 改壞腳本與輸出：`scratchpad/core/pr2C/mut/run.sh`、`mut/all.sh`、`mut/results.txt`
- Rust：`scratchpad/core/pr2C/rust.sh`、`rust.log`、`rust2.sh`（T-U4 負向對照）
