# #329 PR 6 程式碼審查 B（安全與失敗模式）

範圍：`git diff c4905ed..HEAD`（feat/329-pr6 @ 229490d），只看新增 / 改動的程式；基準（設計 v12.1、PR 1–5）不重審。
依據：`docs/design/329-pr6-plan.md` v6（§2 D1–D11、§6 安全）。

## 判定

**APPROVE-WITH-CHANGES**：BLOCKER 0 / MAJOR 0 / MINOR 5。

## 驗證過的（✅，附證據）

| 項目 | 結果 | 證據 |
|---|---|---|
| SSH 驗證 = node.go:752 / :848 | ✅ 等價。手寫的 `node_accepts`（ssh.rs:63-75）= `^ssh-ed25519 [A-Za-z0-9+/=]{1,200}( [ -~]{0,40})?$`（key 字元集不含空白，所以貪婪切分與 regex 回溯結果一樣）；≤ 256 B、無 CR/LF 先擋（ssh.rs:82-86）。比節點嚴的地方只有 base64 要能解開 | node.go:752、:846（`len(s) > 256 \|\| ContainsAny("\r\n") \|\| !sshLine.MatchString`） |
| SSH 指紋正確 | ✅ 用 WSL `ssh-keygen` 新產一把：`SHA256:66elAVhhQerlTxxmqfuCPE7F3Wbz4X9bJ8iLKerJyBI`；Python `b64encode(sha256(b64decode(key))).rstrip('=')` 得到同值 = ssh.rs 的演算法；Rust 測試 `t6_3_fingerprint_matches_ssh_keygen` 用另兩把 ssh-keygen 向量 | `cargo test`：`api::ssh::tests::*` 3 ok |
| 取代語意寫明 | ✅ 按鈕「設定 SSH 金鑰（取代之前由 app 加入的）」+ 固定說明；0 行 = danger +確認對話框 | dev_pages.dart:80-84、:118-136（但說明有一處過度保證，見 MINOR-2） |
| 只在 devTrust | ✅ 入口在 `if (devTrust)`（settings_page.dart:83）；頁面自己再擋（dev_pages.dart:117、:230、:379）；pages_test「T6-1」雙版本斷言；pr6_dev_test「not a devTrust build: the page sends nothing」 | 原始碼 + 測試 |
| 金鑰能力閘門 | ✅ SSH / 節點設定 / 忘記加入中 用 `keys.refusal(KeyUse.login)` 灰掉並附原因；`keys == null` 也灰（fail-closed） | settings_page.dart:32、:86-95；pages_test「D4a」 |
| field build 可達性 | ✅ 4 個 dev 頁只在 settings_page.dart:86-102 被建；舊啟動頁的「我的節點」已刪、「附近的節點」加 `_devTrust`（main.dart:332）；ClaimPage 的開發輸入照舊 `_dev` 閘門（claim.dart:562）；`TeamPage` 入口要 `view.visible`，`team_enabled()` = `WRITE_MESH_ADDR`（release 為 false）；新 Rust API `ssh_line_problem` / `ssh_fingerprint` 是純函式（不碰節點），`request_ssh_keys` 是既有 API | grep `SshKeysPage\|NodeSettingsPage\|LogPage(\|OrphanJoinsPage\|TeamPage(` |
| 國家只送 US | ✅ Dart 唯一呼叫點 settings_pages.dart:334 → `setCountry` 先擋 `allowedCountries`（owner_console.dart:584）；其餘國家值只在 Rust join2 路徑（netcfg key 5 / Revert），與計畫 D11 的三種一致 | grep `requestSetCountry\|setCountry(` |
| 被入侵節點的字串 | ✅ 技術段內的節點字串：`error_text` 的 verb 經 `statuspage::shown`（owner.rs:670），有測試餵 `x\u{1F}\n\u{202E}y`（owner.rs:1829-1831）；國家經 `invite::display_name`（owner.rs:170、:539、:548、:571-575）；`settings_text` 全部經 `shown`，測試含密碼欄位與 `\n \r BEL U+202E U+2066`（owner.rs:1778-1796）。`display_name` 把 Cc（含 U+001E / U+001F）與 Cf 換成 U+FFFD（invite.rs:110-111），所以節點不能塞成對標記把文字搬進主句。其他插值（`Broken`、cbor 錯誤）都是 `{:?}`（Debug 會跳脫控制字元）或固定字串 | 原始碼 |
| 全隊段落不能互蓋 | ✅ `teams[id]` 只由 `_run` 在 `core.result` 回 true 後寫（node_link.dart:634-645）；頁面每台一段、key = id；段標題名稱取自隊長簽的名單 / 驗過的 DAC（teamview.rs:294-297）；卡片內名字經 `shown`（無換行，不能偽造下一行） | 原始碼 |
| 全隊內容不進紀錄 | ✅ team_status_page_test「T-A9」；prober 只記 `e.runtimeType` | 原始碼 + 測試 |
| 文字紀錄 / 診斷複製遮罩 | ✅ `logShown` = `logText(NodeLink.mask(l))` + 其他 C0 換空白（dev_pages.dart:298-299）；`diagCopy` 每值經 `mask`（diag_page.dart:52-62）；`shortRel` 只留後四碼；租約名稱沒有插值（grep `acquire(\|OpSession.once(` 無 `$`） | 原始碼 |
| 失敗走 fail-closed | ✅ `orphansUnknown`（net_index.dart:250-252）；`setCountry` 擋；`splitCode` 不成對 / 巢狀 → 全部當主句（say.dart:31-48）；`teamEnabled()` 丟例外 → false（prober.dart:280-285）；預算超時 / 取消 → `Outcome.team = null` | 原始碼 + 下表負向對照 |

### 我自己做的負向對照（改一行 → 跑測試 → `git checkout --` 還原，`git status --short` 為空）

| 破壞 | 結果 |
|---|---|
| owner_console.dart:584 `if (false && !allowedCountries...)` | `owner_console_pr4_test`「T6-9: setCountry outside {US} -> notSent」**FAIL** |
| net_index.dart:251 `orphansUnknown = false` | `pr6_dev_test`「J MINOR: the node records cannot be listed -> no orphan at all」**FAIL** |
| dev_pages.dart:298 拿掉 `NodeLink.mask` | `pr6_dev_test`「T6-12 text log every line masked」**FAIL** |
| diag_page.dart:59 拿掉 `NodeLink.mask` | `pr6_dev_test`「T6-5 diagnostics … copy = whitelist only」**FAIL** |
| say.dart 未結束的段改成「吞掉」 | `say_test` 2 條 **FAIL**（共用向量、unpaired / nested） |
| ssh.rs:91 字串加「（代碼 9）」 | `d7a_1_every_code_literal_is_wrapped` **FAIL**：`api/ssh.rs:91: 代碼: "金鑰內容解不開（代碼 9）"` |

全套：`flutter test` → `00:40 +1802: All tests passed!`；`cargo test --lib -- ssh:: team_flag say_scan settings_text`（WSL，`CARGO_TARGET_DIR=$HOME/tgt-329pr6-rb`）→ `10 passed; 0 failed`。

## 發現

### MINOR-1　啟動頁把完整裝置 ID 印進 logcat（PR 6 新增）

- 情境：金鑰檢查沒過（`!keys.appUsable`）時，PR 6 把 `節點紀錄：<完整 device id>`、`認領暫存：<完整 id>` 加進 `tech`（main.dart:139），而 main.dart:158 `debugPrint('BMAPP ${logText([...lines, ...tech].join(' | '))}')` 沒經 `NodeLink.mask` → 完整 ID 進 logcat（release 也印）。PR 5 時完整 ID 只在 `index`（畫面），沒有進 debugPrint。計畫 D4 / §6 的原則是 logcat 那條路只留後四碼。
- 影響：logcat 只有 adb / 系統讀得到，裝置 ID 也不是金鑰；但這和本 PR 自己在文字紀錄、診斷建立的遮罩規則不一致，且是新出現的。
- 修法：`debugPrint('BMAPP ${NodeLink.mask(logText(...))}')`（畫面的技術資訊與「複製文字」照計畫保留完整 ID）；key_abilities_test 加一條 logcat 不含完整 ID 的斷言。

### MINOR-2　SSH 頁的固定說明對「重複金鑰」過度保證

- 情境：sshReplaceNote（dev_pages.dart:80）寫「節點上原本就有、不是 app 加的不受影響」。node.go:862-873 是用**字串相等**過濾：若某行原本就在 authorized_keys（例如 lab key），使用者又用 app 加了同一行，之後任何一次整組取代（不只 0 行）都會把**兩份**一起刪掉。0 行的對話框有寫這個例外（dev_pages.dart:125），送 1–8 行的路徑沒有。F3 的用途正是「把 lab key 加回 02」，之後再換一組就可能把 lab key 洗掉、失去維修入口。
- 修法：sshReplaceNote 補上同一句例外（「如果某把金鑰本來就在節點上、你又用 app 加過，它也會被一起取代」）；pr6_dev_test 斷言兩條路徑都有這句。

### MINOR-3　診斷頁以後四碼當 map key，兩台後四碼相同時少一台

- 情境：`nodeTech` 回 `{last4(id): tech}`（diag_page.dart:40-48）；兩台節點後四碼相同時後者蓋掉前者，畫面與「複製」都少一台，且看不出來。設計 §3.3 本來就承認後四碼可能撞。
- 修法：用完整 id 當 key，顯示 / 複製時才轉後四碼（遮罩規則不變）。

### MINOR-4　`splitCode` 規則有兩處不在 D7a(3) 原始碼掃描範圍內

- 情境：(a) 舊啟動頁 `Text(_report!)`（main.dart:323）直接顯示；`_report` 的行目前只有固定字串，但同檔 `'啟動檢查失敗：${sayErr(e)}'`（main.dart:156）會帶標記，若日後走到這頁就會把 U+001E/U+001F 與技術段原樣顯示。say_src_test 的 `_files()` 只掃 lib/ui、claim.dart、member_ui.dart，不含 main.dart；而且 `_report` 這個名字不在 regex 的變數名清單裡。(b) `TeamPage` 的 `v.only` / 卡片 / `v.tech` 也是原樣 `Text`（team_status_page.dart:107、:127、:153）——今天 teamview.rs 沒有任何 `\u{1E}`，安全；但 D7a(1) 掃描會讓日後在 teamview 加代碼的人包標記，而這頁不會拆。
- 修法：main.dart:323 改 `screenText(_report!)`（或 SayLine）並把 main.dart 加進 `_files()`；TeamPage 的 `only` / 卡片第一行改經 `screenText`（或在 Rust 加一條「teamview 輸出不含 U+001E/U+001F」的測試鎖住現況）。

### MINOR-5　SSH 不合格原因的字眼不精確

- ssh.rs:88「後面的註解最多 40 個英數字元」——節點規則是 40 個可列印 ASCII（含空白與符號）。使用者看到會以為不能有 `@` `.`。改「最多 40 個英文、數字或符號（不能有中文）」。

## 沒有發現問題的攻擊面（簡記）

- 本機非特權 app：剪貼簿內容只有遮罩後的紀錄 / 診斷白名單、節點設定白名單（無密碼，Rust 測試鎖）；SSH 頁不寫剪貼簿，貼上的內容逐行顯示指紋可對防替換。
- 實體擄獲：新頁面都只讀記憶體或走既有的擁有者簽章；`teams` 只在記憶體。
- 被入侵節點：見上表；能影響的只有自己那一段與自己的設定頁內容（名稱裡放「，國家 US」之類的假欄位只能騙自己那台的開發頁，屬自身資料，不列）。
- `setRecords` 中途移除目標：`result` 先清 `running` 再回 false，`tick` 的 `allDone` 對剩下目標仍收尾（core.dart:449-458、:535）。
