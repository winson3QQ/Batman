# #329 PR 2（winson3QQ/Batman#340，feat/329-pr2 @ d3b5d38，base 26057eb）審查 B

審查者 B（獨立）。範圍：`git diff 26057eb d3b5d38` 全部（新介面 app/lib/ui/*、main.dart 路由、UiState / cbor_mini、圖示 / manifest / Kotlin `appVersion`、§3.4 S1–S10 的 Dart 與 Rust 文字、joinChoice、測試）。
做法：先從真實使用走（新使用者、升級使用者、首頁每一列、節點頁、移除、設定 / 關於），再逐項對原始碼；自己匯出 d3b5d38 到 scratch 跑測試與改壞對照，沒有動 C:/src/Batman-329pr2 或 pr1。

## 結論

**APPROVE-WITH-CHANGES**：BLOCKER 0、MAJOR 3、MINOR 9。三個 MAJOR 都要先修再合併（兩個是使用者會遇到的錯行為，一個是宣稱有負向對照但改壞不會 FAIL 的測試）。

## 我自己跑的東西（證據）

| 項目 | 結果 |
|---|---|
| `flutter test --no-pub test/ui test/join_choice_test.dart test/key_abilities_test.dart`（d3b5d38 原樣） | ✅ `+179: All tests passed!` |
| 全套 `flutter test --no-pub test/`（在 M15 那一次順便跑到） | ✅ `+570: All tests passed!`（含 M15 的改壞，見 MAJOR-3） |
| batman-proto `cargo test`（WSL，自己的 CARGO_TARGET_DIR） | ✅ 全部 ok。第一次跑有 6 條 FAIL：panicked at `tests/claimflow.rs:18`（讀 `../../../tests/vectors/219-protocol/vectors.json`），我的複本沒有放 repo 根目錄的 `tests/`。翻轉測試：只補上 `tests/` 目錄，同一批全部 PASS → 歸因於我的複本，不是產品 |
| bridge `cargo test` | ✅ `63 passed` |
| T-U4 負向對照（`RECORD_KINDS` 加 `"ui"`） | ✅ `t_u4_ui_is_not_a_record --- FAILED`（simple.rs:119）；還原後 `1 passed` |
| Rust 只改字串 | ✅ diff 的 +/- 行逐行看過：除了新增的 T-U4 測試與拿掉的一條斷言，每一行都只換中文字串常數；沒有 `if`、代碼表、判定改動 |

改壞對照（每個都只改一處，跑完還原；最後 `diff -r` 對 d3b5d38 的 app/lib 一致）：

| # | 改壞 | 結果 |
|---|---|---|
| M14 | `joinChoice` 改成 mnet 優先 | KILLED（join_choice_test） |
| M5 | 首頁提示卡不看是不是第 14 列 | KILLED（pages_test T-H4） |
| M1 | 首頁表第 11 列（待辦）搬到第 10 列（未讀 / 舊）前面，句子不變 | **SURVIVED** |
| M3 | 第 12 列（黃 / warning）搬到第 11 列（待辦）前面 | **SURVIVED** |
| M2b | 第 13 列（灰）搬到第 12 列前面（灰而且 warning 不空的節點因此走 13） | **SURVIVED** |
| M13 | main.dart 歡迎頁條件拿掉 `!ui.welcomed`（看過了還是每次出現） | **SURVIVED** |
| M15 | 舊控制台 `_join` 的 `JoinChoice.member` 改接 `_joinNetwork`（隊員的加入完全接不到） | **SURVIVED**（全套 570 passed） |
| M4 | `_remember` 把紅記成 `warn` | SURVIVED |
| M7 | cbor 深度上限 4 → 400 | SURVIVED |
| M11 | 設定頁開發者選項不看 devTrust | SURVIVED |

另外寫了一個只在我複本裡的測試（`zz_review_test.dart`，跑完移出）：

```
loaded readAt=9000000000000
nodeRowWords threw: RangeError (millisecondsSinceEpoch): Invalid value: Not in inclusive range -8640000000000000..8640000000000000: 9000000000000000
nick=[8238, 97, 98, 99, 10, 7]
```

cbor 的截斷 / 2^32 個項目的 map / 8 位元組長度最高位 / 不合法 UTF-8 / 不定長度 / 空檔 / 第 5 層巢狀，全部 `FormatException`（✅）。

## MAJOR

### MAJOR-1　新使用者的第一條路：首頁第 6 列的按鈕永遠是「加入網路」，沒有網路的手機按下去得到錯的警告

- **情境**：新使用者（沒有 net / mnet）新增第一台節點後，首頁第 6 列「節點 XXXX 還沒加入隊伍網路」＋主要按鈕「加入網路」（PR 的真機表也正是這個狀態）。按下去打開舊控制台；登入後照著按「加入網路」→ `_join` → `joinChoice(hasNet:false, hasMnet:false)` = `own` → `_joinNetwork` → `_pickNet(forJoin:true)` 找不到 net，畫面說「手機裡沒有可用的網路紀錄，不能再加節點。若 App 重裝過：新建網路會讓整隊分成兩個網路，舊節點要重燒」。對一個從沒建過網路的人，這句話是錯的、而且嚇人；他要做的其實是「建立網路」。
- **證據**：`home_logic.dart:79-82`（第 6 列一律 `HomeAction.joinNetwork`）、`home_page.dart:183-189`（`joinNetwork → Btn.joinNetwork`）、`home_page.dart:146-147`（開舊控制台）、`nodes.dart:1043-1050`、`nodes.dart:598-602`。設計 §5.1 第 6 列明寫依網路摘要表：「都沒有 →『建立網路』，次要『加入隊長的網路』；只有 mpend →『看我的申請』」，§5.3 也特別說 v2 給「沒有網路可加的『加入網路』」是錯的。PR body 的「和設計不同」只列了待辦的網路摘要來源延到 PR 3，沒有說第 6 列的按鈕也沒照表。
- **修法**：第 6 列的按鈕在 PR 2 就照紀錄決定（`listNets` / `listMnets` / `listPending` 不用解密，`_todos()` 已經在做同類的事）：都沒有 →「建立網路」（打開同一個舊控制台即可，但字要對）；只有 mpend →「看我的申請」或至少不是「加入網路」。加一個 widget 測試：無 net/mnet 時第 6 列的按鈕是「建立網路」，負向對照 = 改回一律「加入網路」→ FAIL。

### MAJOR-2　joinChoice：同時有 net 與 mnet 的手機再也做不到隊員的加入，而且按「加入網路」會直接把節點加進自己的網路

- **情境**：一支手機建過自己的網路（net/），後來又收了別隊隊長的同意（mnet/）——隊長換人、一人在兩隊、或開發測試。以前舊控制台有兩顆按鈕可以選；現在只剩一顆「加入網路」，`joinChoice` 在 hasNet 時一律 `own`。`_joinNetwork` → `_pickNet`：只有一筆 net 時 `if (nets.length == 1 ...) return nets.first`，不問就開始把這台節點加入**自己的**網路（最長 6 分鐘、改節點狀態），使用者原本要的是隊伍網路。app 裡沒有任何其他入口能做隊員的加入（`_memberJoin` 只剩 `_join` 一個呼叫點，`grep` 確認）。
- **證據**：`nodes.dart:1043-1050`、`nodes.dart:1734-1736`、`nodes.dart:605`；舊的「加入隊伍網路」按鈕在 diff 被刪（原 nodes.dart:1715）。Rust 端拿掉的斷言 `assert!(!s(&claimed, J::Admin).contains("「加入隊伍網路」"), ...)` 在字串統一後確實已無意義（兩邊句子相同），拿掉本身是誠實的；但它原本守的「隊長手機不會被指去錯的加入」改由 `joinChoice` 承擔，而 joinChoice 在兩者都有時直接選一邊、不問。
- **對 PR 的偏離（照 T-N2 而非 S3）的判斷**：「net 優先」作為**沒有選擇時的預設**可以接受，和 `JoinButton::of` 一致；但 S3 與 T-N2 兩種寫法在「兩者都有」時都會讓另一條路消失，這是設計本身的洞，不只是兩處文字不一致。設計回填時要把「兩者都有」寫成一列。
- **修法**：兩者都有時不要自動決定：列出自己的網路與隊伍網路讓使用者選（同一個選單，隊伍網路走 `_memberJoin`）；`_pickNet` 在這條路上即使只有一筆也要顯示名稱讓人確認。joinChoice 改成三態（own / member / ask），測試三態，並加一個接線測試（見 MAJOR-3 的 M15）。

### MAJOR-3　宣稱有負向對照的規則，改壞了測試不會 FAIL

PR body 寫「PR 2 規則的改壞對照（首頁表的上下順序、歡迎頁條件、…、`joinChoice`…）14 / 14 都有測試 FAIL」，`home_logic_test.dart` 開頭也寫「when two rows hold the upper one wins」。實測：

1. **首頁表的順序**只守住了部分相鄰列：10↔11（M1）、11↔12（M3）、12↔13（M2b）三種交換全部 SURVIVED。理由：第 11 列的測試只拿「全綠＋待辦」與「連不到＋待辦」，第 12、13 列的測試各自只有一台節點，沒有任何一個輸入讓兩列同時成立。M2b 不只是順序：灰色但 `warning` 不空的節點，設計說走第 12 列，改壞後走第 13 列，測試照過。
2. **歡迎頁條件**只測了「有沒有節點紀錄」那一半：拿掉 `!ui.welcomed`（M13）SURVIVED → 沒有節點、已經看過歡迎頁的人每次開 app 都會再看到歡迎頁，測試不會發現。
3. **joinChoice 的接線**：`_join` 把 member 接到 `_joinNetwork`（M15）全套 570 個測試照過。純函式有測，按鈕實際呼叫哪條路沒測——而拿掉的那條 Rust 斷言原本就是守這件事的。

- **修法**：(1) 對每一對相鄰列加一個「兩列同時成立」的輸入（至少 10/11、11/12、12/13，並加「灰＋warning → 12」）；(2) T-U3 加第三種情況：沒有紀錄、`welcomed = true` → 不顯示歡迎；(3) joinChoice 的接線用 widget 測試或把分派抽成可測的函式（假的 net/mnet 列表 → 呼叫到哪個流程）。每一條附上述改壞 → FAIL 的負向對照。

## MINOR

1. **UiState 只驗型別、不驗值域，一個解得開的值可以讓首頁 build 丟例外**。`ui_state.dart:198` 只檢查讀取時間是 `int`；`home_logic.dart:128` `DateTime.fromMillisecondsSinceEpoch(p.readAt! * 1000)`，值 ≥ 8.64e12 秒就 `RangeError`（上面原始輸出）。這發生在 `HomePage.build` → 發佈版是一整頁灰色，而且檔案還在，每次開都一樣，直到清資料。暱稱也一樣：`\u202E`、`\n`、`\u0007` 照收（輸出 `nick=[8238, 97, 98, 99, 10, 7]`），§5.3 說暱稱要去控制字元。可達性：檔案是 AEAD（aad 綁 rel + generation，store.rs:50），只有 app 自己寫得出來，所以只剩「我們自己的 bug」這個 actor，定 MINOR。修法：`_parse` 檢查 `readAt` 在合理範圍（例：0 ≤ t ≤ 4e9 或 ≤ 現在 + 10 年）、暱稱 1–24 字且沒有 Cc/Cf，否則當成內文壞；`nodeRowWords` 的轉換也包一層。§4.6「讀不到一律當不存在」的保證才完整。
2. **第 1 列（藍牙關閉）沒有按鈕**。`decideHome` 給 `HomeAction.openBluetooth`，但 `home_page.dart:183-189` 的對應表沒有它（落到 `_ => null`），`_act` 也什麼都不做；設計第 1 列的主要動作是「開啟藍牙設定」，`Btn.openBluetooth` 已存在。PR 只說「開啟 app 設定」沒做，這顆沒有列在偏離裡。修法：做（`BluetoothAdapter.ACTION_REQUEST_ENABLE` 或系統設定頁）或寫進偏離與 #329 checklist。
3. **S8 與用詞掃描的缺口**。Rust `owner.rs:1275`「[JOINREQ] 申請已換新，要重新核對 SAS」沒改（舊控制台的紀錄區看得到；設計 S8 只列了 nodes.dart:872，是設計表漏的，但 S1–S10 的精神是同一句話全 app 一致）。`wording_test.dart:31` 的退役詞只有 網主 / 末四碼 / 管理者 / 成員，沒有 SAS、「確認網路」「繼續加入」「加入隊伍網路」這些退役按鈕名，所以掃不到。另外「復原／成員金鑰」出現在新首頁 KeyGate 灰掉的原因句（`key_abilities.dart:80/125` 經 `home_page.dart:231`）：設計說金鑰名稱只在技術資訊，PR 說保留「成員金鑰」，兩者至少要對齊一邊。
4. **`firstRounds = roundsRun < 3`（home_page.dart:180、node_page.dart:96）**：`roundsRun` 在一輪**開始**時 +1（core.dart:331），所以第 2 輪結束後、第 3 輪開始前的空檔（可能數十秒）仍算「頭兩輪」，第 5 列的「正在找你的節點…」與節點列的 busy 會停留到第 3 輪開始。⚠️ 推論，沒有實際量到空檔長度。修法：用「第 2 輪已結束」判斷（例如結束的輪數 < 2）。
5. **規範對不上的小地方**：狀態區的時間是 `HH:MM`（設計：狀態區到秒）；字級出現 21（`Fs.hero - 3`，設計狀態區那句是 24）、19、17、15，設計只有六級。
6. **按鈕字串沒有全部來自 `Btn`**（§3.4 規則 4）：歡迎頁「下一步」「跳過說明」「開始」、2.2「繼續」、待辦「繼續完成」寫死；節點頁移除失敗把 `$e` 原樣放進主畫面（設計：代碼進技術資訊）。
7. **§4.6 要求的測試沒有做**：「測試鎖住：UiState 的值只流向顯示用的 widget」沒有對應測試；T-U6 只做了白名單一半，沒有「搜尋假秘密」；`RecordUiStore`（`'$e'.contains('NotARecord')` 的檔頭判斷、seal / CAS 的 generation 檢查）完全沒有測試，MemStore 不經過它；cbor 深度上限（M7）、開發者選項的 devTrust 閘（M11）、紅 → `bad` 的對應（M4）改壞都不會 FAIL。
8. **T-C2 沒涵蓋的頁 / 狀態**：首頁第 1 / 2 列（藍牙關閉、沒權限）、2.4 金鑰不足頁、1.1 啟動畫面、節點頁技術資訊展開（版本、tech 行在 2.0 字級）、移除確認對話框、多台節點與長的紅色句子。PR 寫「8 頁」，實際 9 個項目，但上面這些都沒有。
9. **UiState 的寫入沒有序列化**：`_remember` 的 `noteReads`、`setHomeTip`、`background()` 都沒有 await 彼此，兩個 `_save` 交錯時第二個 CAS 失敗、那次內容丟掉（下次再寫）。只影響顯示，符合「不重試」，記一行即可。

## 逐項檢查（沒有問題的部分）

- **UiState 契約**：不存在 / 檔頭壞（先 `storeRemove`）/ 解不開 / 內文壞 / 版本不是 1 / 白名單外欄位 / 寫入失敗（下次先重讀 generation）/ 載入時刪掉沒有 `node/` 的項目 / `forget`，對照 `ui_state.dart:157-284` 與 ui_state_test 逐列都在。寫入內容只有旗標、四選一的種類、牆鐘秒數；沒有句子、位址、節點字串、秘密。`ui` 不在 `RECORD_KINDS`（T-U4，負向對照實跑 FAIL）。沒有任何決定讀它：歡迎頁、提示卡、暱稱都只影響顯示；節點清單來自 `core.states`（`listNodes`），不是 UiState 的節點表。
- **cbor_mini 嚴格度**：只收 uint / bool / text / map；長度先對剩餘位元組檢查再配置；重複鍵、尾端多餘位元組、深度 > 4 都拒絕；遞迴最多 5 層。
- **新畫面上的節點字串**：狀態句子、warning、lagNote 由 Rust 依代碼組；`version` 走 `shown`（display_name + 截 64，statuspage.rs:188、386）；`tech` 走 `value()`；`netId` 是 hex。Flutter `Text` 不解譯標記。沒有新的節點字串進到主畫面。
- **Kotlin `appVersion`**：只回 `BuildConfig.VERSION_NAME`，Dart 端錯誤吞掉、顯示空字串。沒有新的輸入面。`allowBackup=false` 不變。
- **移除節點（T17）**：拿 session 佔用 → `keepCopy` 成功才 `remove` → 釋放 → UiState 忘記；副本失敗不刪、顯示錯誤（測試的順序斷言 `['copy …', 'remove …']` 能抓到順序對調）。
- **升級使用者**：`NodeLink.start` 先 `await readRecords()` 再進路由（node_link.dart:102-104），所以「有紀錄就不顯示歡迎」在判斷時是準的。
- **§3.4 S1–S10**：S1、S2、S4–S7、S9、S10 在 Dart 與 Rust 都改到（grep 剩下的只有 SAS 那句與「成員金鑰」，見 MINOR-3）；S10 的 BLE 位址只進 `debugPrint`（claim.dart:27、252）。

## 對 PR body「和設計不同的地方」的判斷

| 偏離 | 判斷 |
|---|---|
| joinChoice 照 T-N2（net 優先） | 預設順序可接受；「兩者都有」不能自動決定 → MAJOR-2 |
| T-C4a 的 Rust 半邊改掃原始碼 | 可接受，但退役詞清單要補退役按鈕名與 SAS（MINOR-3） |
| 新元件 `shrinkWrap` 讓 36 高的負向對照成立 | 合理 |
| 網路摘要、診斷、暱稱編輯等延到 PR 3 / 4 | 可接受；但第 6 列的按鈕文字不在這個清單裡，要在本 PR 修（MAJOR-1） |
| 「開啟 app 設定」沒做 | 可接受（已寫出去哪裡開）；「開啟藍牙設定」同類但沒列（MINOR-2） |

## 沒有做的

- ❌ 沒有上真機（照 brief 不用 adb）；真機表的數字沒有重驗。
- ❌ 沒有逐張對照畫布 gen.js 的版面細節，只對了設計 §3 / §5 的文字規則。
- ⚠️ MINOR-4 的空檔長度是從原始碼推的，沒有量。
