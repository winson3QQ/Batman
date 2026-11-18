# #329 PR 6 計畫 v4：第四輪獨立審查（G）

審查對象：`docs/design/329-pr6-plan.md` v4（整份），worktree `C:/src/Batman-329pr6` @ c4905ed。只讀；所有 `檔:行` 都是本輪自己開原始碼核過的。基準（v12.1、PR 1–5、#349）不重審；全隊頁「做不做」是使用者決定，本輪只審「怎麼做」。

## 前輪 MAJOR 是否解掉

| 前輪 | 狀態 | 說明 |
|---|---|---|
| E-M1 代碼以外的碼與英文 | ✅ 方向對（改分隔字元，不再解析括號） | 但分隔字元帶來新的組句問題 → 本輪 MAJOR-1 |
| E-M2 / F-M2 / F-M3 全隊資料契約 | ⚠️ 大部分解掉 | 每台一段、帶 netId、移除後晚到丟掉、netId 空清掉、後四碼偏離寫明 都有。剩「team 值比狀態舊卻顯示成新鮮」→ MAJOR-2 |
| E-M3 prober 計算 | ✅ | 注入開關、同一次 `openNet`、2 s 預算、每個 await 後 `stop()`、成本 ⚠️ 都寫了；和 prober.dart:158-166、:252-272 的現行結構對得上 |
| F-M1 刪掉的測試 | ✅ | §7「既有」逐條對照表 + 已知項目 |
| F-M4 孤兒排除 | ✅ | D4a 帶回 `forgetNotice(offerExclude)` 與排除按鈕；另核 `MemberView.joining = state == Joining`（owner.rs:126），別人的 Approved 節點不會被當成孤兒 |
| F-M5 R-7 | ✅ 主體解掉 | 中斷時機、OTA 不重開、02 SSH 前提、拔電都有；剩順序上的小洞 → MINOR-6、MINOR-7 |

## 已驗證的事實（本輪）

- FRB 傳字串是 UTF-8 bytes（`impl SseEncode for String` → `into_bytes()`，app/rust/bridge/src/frb_generated.rs:3451-3453），U+001F 是合法的單位元組 UTF-8，兩邊原樣通過。✅
- 節點字串都經 `display_name`（statuspage.rs:188、swupd.rs:156、teamview.rs:193/:295/:320），控制字元（含 U+001F）換成 U+FFFD，所以被入侵的節點**不能**在主句插假的分隔字元。✅
- 唯一例外：`error_text` 的 `{v}` 直接是節點送來的 `detail[1]` 文字，沒有經 `shown`（owner.rs:669-671）。它在新格式裡會落在分隔字元之後，所以主句安全；但技術資訊展開時是未清理的節點文字 → MINOR-3。
- 沒有任何記錄（`ui/state-v1`、claim records、net 紀錄）存句子文字；`ui_state.dart:15` 的 `\p{Cc}` 過濾只用在暱稱（:96、:200）。✅
- Dart 端比對 Rust 句子的地方：`rekeyEnd` 的錨定 regex（rekey_send.dart:25，`[UPDATED]` 句不含代碼、`sameLast4` 大小寫不敏感 → F14 改大寫不影響）、`unfinishedLine` / `sendUnclearLine` 全等（不含代碼）、`needsNewInvite` 用 `contains`（net_run.dart:344）、marker 前綴 `startsWith`。都不會被 U+001F 弄壞判定。✅（但 `needsNewInvite` 的畫面效果見 MAJOR-1）
- Dart 測試裡手寫的 Rust 形狀句子：owner_console_pr4_test.dart:120、:127，retest_s_boards_test.dart:169 → MINOR-4。

## BLOCKER

無。

## MAJOR

### MAJOR-1　帶分隔字元的句子被**接在別的句子中間**時，後面的主句（下一步、警告）會被藏進技術資訊；D7 / D7a 都沒處理，掃描也抓不到

**情境**：D7 規定 `splitCode` 在**第一個** U+001F 切。今天有多處把一個「會變成帶分隔字元」的句子插在另一句的中間、後面再接主句文字。改完之後，接在後面的主句全部落到分隔字元之後，畫面上消失：

1. **T4 恢復的安全警告不見**：replay.rs:133 `neutral` =「節點沒有接受這次恢復（{what}，代碼 {c}），已停止；紀錄先保留」（在 F5 清單裡，會改成 `…\u{1F}{what}，代碼 {c}`）。claim_recovery.dart:461-462 把它接上 `$warn` =「。這筆暫存可能不是這台節點最後一次認領用的，請不要一直重試」。改完後這句警告只在「技術資訊（給維修人員看）」裡。這正是 §19.2-6 要使用者看到的那句。
2. **「需要新的邀請」不見**：owner.rs:600-602 `format!("{t}；需要新的邀請")`，`t = join2_text(Failed…)`，而 Failed 的句子帶代碼 / 回覆碼（owner.rs:562-565）。改完後畫面只剩前半，下一步藏起來（net_pages.dart:802 用 `needsNewInvite(r.line)` 仍會出現按鈕，但列的文字 `plain(r.line)`（:797）不再說明為什麼）。
3. **「沒有改動任何東西」不見**：owner.rs:543 `節點不讓改國家：{why}（代碼…），沒有改動任何東西`，`why = reason_text(...)`，而 `reason_text` 的預設分支是 `節點拒絕了（原因 {r}）`（owner.rs:649，D7a (1) 會逼它改成帶分隔字元）。即使 543 本身照規則改寫，`{why}` 內含的分隔字元仍會把後面的「，沒有改動任何東西」切掉；`error_text`（:668-671）同理會出現兩段技術部分。
4. Dart 端多行組合：main.dart:264 把 `lines.skip(1).join('\n')` 當 `StatusHero.next`（其中 :158 `節點自動讀取沒有啟動：$e` 的 `$e` 可能帶分隔字元）；node_page.dart:184 把 `StatusView` 的多個欄位 join 成 `next`。D7 的遷移清單有 `StatusHero`——如果 `StatusHero` 對整個 `next` 做 `splitCode`，第一個分隔字元之後的**其他行**全部消失。

**為什麼掃描抓不到**：D7a (1) 只看「同一個字面量裡、代碼字樣前面有沒有 `\u{1F}`」。`"{t}；需要新的邀請"`、`'${t.step.detail}$warn'`、`"{why}…，沒有改動任何東西"` 的字面量裡都沒有代碼字樣，掃描通過；D7a (2) 的逐函式測試清單（F5 / F6 / E-M1 列的函式）也不含這些組句者（`member_join_text`、`_final`、`CountryRefused` 分支）。D7a (3) 只看 `Text(`。

**修法**：
- 規則寫成「**句子是 (main, tech) 兩段，只在最外層輸出時才接成 `main\u{1F}tech`**」：Rust 加一個小型別或兩個 helper（例：`Say { main, tech }`、`say.then(more)` = main+more、tech 不變；`join(a, b)` = mainA+mainB、techA；techB），`reason_text` / `join2_text` / `neutral` 這類會被再組合的函式回 `Say` 或 (main, tech)，不回已接好的字串。Dart 同理：`sayThen(line, more)` = 在分隔字元**之前**插入 `more`；多行 `join('\n')` 之前每行先 `splitCode`，或 `StatusHero.next` 收 `List<String>` 逐行切。
- 測試（各附負向對照）：Rust `member_join_text(Failed…)` 的主句含「需要新的邀請」；`CountryRefused` + 未知 reason 的主句含「沒有改動任何東西」且技術部分只有一段；Dart：`_final` 的 T4 refused 路徑，主句含「請不要一直重試」（負向對照：改回 `'$detail$warn'` → FAIL）；`StatusHero(next: 兩行，第一行帶分隔字元)` → 第二行仍在畫面上。
- D7a 加一條機械檢查：Rust 字面量裡 `{識別字}` 後面還有非空白文字、且該識別字是句子函式的回傳值 → 要用 helper（或至少把上面 4 個已知點列入 (2) 的逐函式測試）。

### MAJOR-2　全隊的值比狀態舊時仍顯示成「新鮮」：新鮮度借用 `core.fresh(id)`，但 team 值有好幾條「不更新、保留舊值」的路

**情境**：D5 (b)(c) 規定「超過 2 s → 不更新（保留舊值）」「紀錄打不開 → 不更新」「`netKnown` 為假 → 不開紀錄」，而 (c) 又規定新鮮度「不另計時，顯示時用 `core.fresh(id, now)`」。`core.fresh` 只看**狀態讀取**（core.dart:155-159：`kind == read && !stale && now - readAt < fresh`）。所以只要狀態每 60 s 讀成功、但 team 這段每次都沒更新，舊的 team 卡片（例如「全員在線」的綠燈）就一直以新鮮樣式顯示。現場會發生的觸發：
- Keystore 解密慢（`openNet` → platform `open`，app_link.dart:30-34）超過 2 s 預算，每輪都超時；
- 手機的 `net/` / `mnet/` 紀錄打不開（金鑰問題，X26 那類）；
- 節點換到另一個這支手機不認得的網路（`netKnown` 假）→ 舊網路的全隊卡片仍掛在這台下面、標成新鮮；
- status 回 row 2'（`Res.errorCode`，prober.dart:155-156）時 `_afterRead` 不跑。

這正是 §4.3.1「只有新鮮的才能給顏色」要防的事：顯示一份過時的全隊狀態當成現況。E-M2 / F-M3 要求的「時間上限」只解了一半。

**修法**：`teams[id] = (netId, view, readAt)`，`readAt` 取**產生這份 view 的那次狀態讀取**的 `readAt`；顯示新鮮 = `core.fresh(id, now) && teams[id].readAt == states[id].readAt`（或 `now - teams[id].readAt < p.fresh` 且無 `blocked`）。`netKnown` 為假、`v.netId != teams[id].netId` → 清掉（不保留別的網路的舊值）。T6-13 加負向對照：狀態讀到、`openNet` 超時 / 回 null / 丟例外 → 該段變 unk（改回「只看 `core.fresh`」→ FAIL）；netId 換成未知網路 → 該段消失。

## MINOR

1. **D7a (1) 的括號插值規則打到大量合法主句，允許清單沒列、而且有些絕不能搬到技術資訊**：粗掃 `（…{x}…）` 在兩個 crate 有約 60 行（含測試）。其中屬於「使用者要核對身分」的：rekey.rs:164（排除某人前的確認，`〈{name}〉（{fpr}）`）、rekey.rs:517（REMOVED_BEFORE，`（…{last4}）`）、member.rs:103 / :106、owner.rs:1329（申請名稱）、rekey.rs:356；屬於主句要的數值：owner.rs:469 / :684（`（{} MHz）`）、owner.rs:170 / :540（國家 `{p}` / `{want}`）、teamview.rs:223 / :298；屬於本來就在技術清單的：statuspage.rs:439、:446（`未入網代碼（key 5）`，member_ui_test.dart:94 鎖著這行）、swupd.rs 除 :910 / :1238 之外的 953、963、1042、1108、1145、1175、1194、1218、1220、1239（都是 `Screen.tech` 參數）。修法：計畫寫明「身分 / 指紋 / 後四碼 / 國家 / 頻寬留在主句」並列出上述允許清單；技術欄位（`Screen.tech`、`StatusView.tech`、`TeamView.tech`）用結構豁免（依呼叫位置或欄位），不要逐行。另 D7a (2) 的 ASCII 白名單沒有 `TW`（§10 有），owner.rs:540「國家仍是 TW」會誤判。
2. **D7a (3) Dart 掃描只看 `Text(`**：`StatusHero(text: …)`（net_pages.dart:770 直接放 `run.rows[i].line`）、`askYesNo` 對話框內文、`BatRow` title / sub、SnackBar、`main.dart`、`swupdate.dart`、`scan.dart` 都不在範圍。漏網的句子會把 marker 與 U+001F 原樣顯示。擴大掃描到這些建構子與檔案。
3. **技術資訊裡的節點文字沒清理**：`error_text` 的 `{v}`（owner.rs:670）是節點送的原始文字，搬到技術部分後由 `SayLine` 展開顯示——被入侵的節點可塞換行 / bidi 在技術資訊裡排版。既有行為，但 D7 正好重寫這行：順手 `shown(v)`。
4. **Dart 測試的假 Rust 句子要跟著改形狀**：owner_console_pr4_test.dart:120、:127，retest_s_boards_test.dart:169 仍是括號代碼形狀；不改的話這些測試繼續通過、但測的是不存在的格式。列入實作清單。
5. **文字紀錄頁 / 複製**：`core.log` 的行若含句子，會帶 U+001F；畫面上是不可見字元，複製到聊天 / issue 也帶著。D4 顯示與複製前把 U+001F 換成可見的「 ｜ 」。
6. **R-7 第 6 步會遇到「之前被排除」**：第 4 步排除了 dev3（與 02），第 5 步主路徑把 04 加回**同一個**網路紀錄，排除清單還在；第 6 步「同 3 的完整一次」會碰到 member.rs:106-107「之前被排除…確定要讓它回來嗎」/ join2 `Pre::RemovedBefore`（owner.rs:534）。這是值得走的路徑，但計畫要寫成預期結果並記錄，否則現場會被當成卡住。
7. **R-7 第 7 步「SSH 關 02 的 HaLow 介面」不會自己回來**：還原欄寫「02 復原後自己回來」，但 `ifdown` 之後要 `ifup` 或重開；把還原命令（與 02 SSH 走 link-local 的前提）寫進副作用表。另第 8 步「同版本 OTA」：app 端 swupd 沒有同版本阻擋（swupd.rs 無對應分支），節點端是否接受同版本要先唯讀確認，否則該步可能直接被拒。
8. **D2 與 T6-3 對 CR 的說法不一致**：D2 先去掉行尾 `\r`，T6-3 又說「含 CR → 不送」。寫明：行尾 CR 去掉；行中 CR 才不送。

## 安全（本輪增量）

- 遠端 / 被入侵的節點：不能偽造分隔字元（`display_name` 已過濾，見上）；能控制的只剩技術資訊的內容（MINOR-3）。全隊每台一段，被入侵的節點只污染自己那段 ✅；但「舊值當新鮮」（MAJOR-2）會讓一台節點只要讓 `_afterRead` 每輪失敗（例如回一個讓 netId 指向未知網路的 status）就凍住自己那段的舊畫面——因為只影響自己那段，嚴重度仍是 MAJOR-2 的範圍。
- 本機無權限 app：無新攻擊面（U+001F 只在程序內與 logcat；logcat 本來就是遮罩後的）。
- 自己的錯誤：MAJOR-1 是典型——每個元件各自正確（Rust 句子照規則、Dart 照規則切），組在一起把警告藏起來。
- 實體取得：無新增（沒有新的持久化文字）。

## 結論

BLOCKER 0 / MAJOR 2 / MINOR 8

**APPROVE-WITH-CHANGES**。前輪 MAJOR 都已解掉或只剩本輪列出的殘項。要修的兩個 MAJOR：
- MAJOR-1：分隔字元句子被再組合時，後面的主句（T4 的「請不要一直重試」、「需要新的邀請」、「沒有改動任何東西」、StatusHero 的後續行）會被藏進技術資訊；要用 (main, tech) 結構組句並加這幾條的負向對照。
- MAJOR-2：全隊值比狀態舊時仍以新鮮樣式顯示；team 值要帶自己的讀取時間，`netKnown` 假 / netId 改變要清掉。

修完後只需針對 D5 (c) 與 D7 / D7a 的改動再看一次；其他部分可以進實作。
