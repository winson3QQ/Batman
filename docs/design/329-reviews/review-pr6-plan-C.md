# #329 PR 6 計畫 v2：審查 C（第二輪，整份）

審查對象：`docs/design/329-pr6-plan.md` v2（worktree C:/src/Batman-329pr6，main c4905ed）。基準不重審（設計 v12.1、PR 1–5、#349）；舊行為只在被刪 / 被改時看。
方法：唯讀。F1–F16 與每個 D 都對原始碼查（file:line 附在各條）；D7 的規則對 Rust / Dart 裡**每一個**全形括號句型逐一套用（`grep -rn "（" app/rust/bridge/src app/rust/batman-proto/src`，約 250 行，逐行過）。沒有上機、沒有跑測試。

## 第一輪 MAJOR 是否解掉

| 第一輪 | 結果 | 說明 |
|---|---|---|
| A-M1 / B-M3 國家 | ⚠️ 一半 | Revert 那條寫清楚了（join2flow.rs:482-484 屬實）；A-M1 點名的**第二條**（隊員模式 netcfg 由別支手機簽）沒處理，計畫反而寫了一句不精確的保證 → 本輪 MAJOR-4 |
| A-M2 / B-M1 / B-M2 代碼形狀與測法 | ⚠️ 一半 | 括號後的下一步保住了、語料 fixture 的作法可行；但新加的「只含 ASCII 的段 → 技術資訊」會藏掉有用內容（含一個安全判斷要用的指紋），而且仍有形狀拆不乾淨 → MAJOR-1、MAJOR-2 |
| A-M3 英文來源 | ⚠️ | F6 列了大部分，但 claim.rs:327 的 `（Broken：中文）`、owner.rs:585 的 `（手機儲存失敗：{英文}）` 不在清單，規則也拆不到 → MAJOR-2 |
| A-M4 重試半套 AppLink | ✅ | D1 不加重試；main.dart:150-162 / app_link.dart:168-170 屬實 |
| A-M5 / B-M6 R-7 | ✅ | 三種中斷、X13 / X14、計時、dev3 理由、副作用一次清單都在 §7 |
| A-M6 全隊頁 | ⚠️ | 做了，但掛的位置讓「N+1 改一行就出現」仍然不成立 → MAJOR-3 |
| B-M4 文字紀錄 | ✅（另有 MINOR-3） | |
| B-M5 SSH 語意 / 驗證 | ✅（另有 MINOR-2） | regex 與 node.go:752、:841-849 逐字一致 |

## 事實查核（F1–F16）

| # | 結果 | 證據 / 備註 |
|---|---|---|
| F1 | ✅ | settings_page.dart:63-70；main.dart:313-316；`_ok && _app != null` 時走首頁，所以「我的節點」只在 NodeLink 起不來時出現 |
| F2 | ⚠️ | 除 (a)(b)(c) 外，**原始狀態**（`requestStatus` → `status_text` / `status::decode_owner`）也只有 nodes.dart 用（grep `requestStatus(` 在 lib 只剩 nodes.dart）。不影響功能（狀態頁有 `statusView`），但影響 D7：見 MINOR-1 |
| F3 | 未查（issue 文字） | |
| F4 | ✅ | teamview.rs:16、:20-21 |
| F5 | ⚠️ | 形狀列得對，但 swupd.rs:910、:1238 **本來就在 `Screen.tech` 欄位**（swupd.rs:673 `screen(text, tech, …)`、:787 `give_up(text, tech)`；swupdate.dart:361-363 已經放在技術資訊），不是主畫面句子 → MINOR-1 |
| F6 | ⚠️ | 漏 claim.rs:327、:187 的 `（{code}：{中文 detail}）` 形狀與 owner.rs:585 → MAJOR-2 |
| F7 | ✅ | home_page.dart:283-286；main.dart:296、:311 |
| F8 | ✅ | |
| F9 | ⚠️ | Revert 屬實；`want()` 在隊員模式取 mnet 的 netcfg（join2flow.rs:21-25、:377、:389、:427-429），不是本機 joinflow → MAJOR-4 |
| F10 | ✅ | claim.dart:540-553 |
| F11 | ✅ | key_abilities.dart:9；HomePage 已有 `keys`（home_page.dart:95、main.dart:180），接進 SettingsPage 成本小 |
| F12 | ✅ | node.go:752、:839-882；另見 MINOR-2 的節點端邊角 |
| F13 | ✅ | core.dart:141-147；但 log 內容含 BLE 位址與完整 device id（core.dart:343、:434），見 MINOR-3 |
| F14 | ✅ | rekey.rs:25；owner.rs:1728 |
| F15 | ✅ | |
| F16 | ✅ | 13 個檔 import `nodes_update_send_test.dart`（實數）；其中假節點庫（FakeSession / FakeRust / FakeNode，:74-383）不依賴 NodesPage 本體，可搬；只有 :457、:573 pump NodesPage |

D1 刪除完整度：✅ lib 下只有 main.dart、settings_page.dart 真的 import nodes.dart；其他檔案只在註解提到。`staleRecordLine` 只在 offline_op.dart:92 的註解。`swupdate.dart` 還被 net_pages / update_route / sw_holds 用，不能跟著刪（計畫沒說要刪，OK）。

---

## MAJOR

### MAJOR-1　D7 的「只含 ASCII 的段 → 技術資訊」會把有用、甚至安全判斷要用的內容藏起來

**情境**：隊長在 S20 上讓一台之前被排除（遺失 / 被抓）的節點加回網路。join2 跳出對話框「這台之前被排除過」，內文是 `這台（…7D2C）之前被排除（遺失 / 被抓），確定它回到你手上、而且沒被動過嗎？之前的擁有者：小明（a1b2c3d4）`，按鈕「確定，加回」。名稱只是顯示用（invite.rs:114「display only, never part of a decision」），能分辨「之前的擁有者是誰」的只有後面那 8 碼指紋。照 D7，`（a1b2c3d4）` 只含 ASCII → 進技術資訊，主畫面只剩「之前的擁有者：小明」。同名的人（或被改名的人）在主畫面就分不出來了。

**證據**：
- 指紋 = `hex_lower(sha256(owner_pub)[..4])`，8 個小寫 hex（batman-proto/src/rekey.rs:76-78），一定只含 ASCII。
- 句子：bridge/src/api/rekey.rs:514-517（`removed_question`，`[REMOVED_BEFORE]`）→ owner_console.dart:334 `_removedQ` → net_pages.dart:722 `_askRemoved(q)` → `plain(q)`（net_pages.dart:42 = `screenText`）。D7 寫「所有新畫面的 `screenText` 呼叫點改用它」，這個對話框就在範圍內，而且對話框旁邊**沒有**另外顯示指紋（對照：移除頁 remove_pages.dart:196 另有一行「指紋 …」，所以 rekey.rs:164 那句被拆還有備援）。
- 同一類（ASCII-only 但不是代碼）的其他句子：
  - owner.rs:469 `[NET_MADE] 網路已建立：…，頻道 40（4 MHz）`（net_pages 的建網結果）→ 頻寬消失；
  - member.rs:262 `這支手機有這個網路的舊紀錄（v3），要換成新的嗎？` → 版本號消失，使用者無從判斷「舊」是多舊；
  - owner.rs:637 `操作（x/y）` → 變成「操作沒有成功」，看不出是哪個操作；
  - member.rs:103 `{name}（{fpr}）`（`jr.previous`）目前走 `askYesNo` 不經 screenText，所以暫時沒事，但 T-C4c 語料如果收進它就會被當成要拆。
- 我順便查了任務要求的其他 ASCII 括號內容：節點名稱（例如 `BCM2711-6c89`）在 Rust 句子裡都用「」或『』包（owner.rs:688、teamview.rs:298），沒有被（）包；`…7D2C` 這種有 U+2026 刪節號，不是純 ASCII，不會被拆；Rust 句子裡沒有 `（1.5.13）` 這類版本號（swupd 的版本在 `tech` 欄位）。所以會誤傷的就是上面這四類，其中指紋那一條是安全問題。

**修法**：拿掉「只含 ASCII 的段」這條推斷。D8 已經決定把所有英文內部字串在 Rust 改成「（代碼 內部：…）」——那就讓 Dart **只認**「代碼 」「原因 」開頭的段（含 D8 的「代碼 內部：」），其餘括號原樣留在主畫面。這樣指紋、MHz、v3、verb 都留著，英文內部字串仍然因為 D8 進技術資訊。T-C4c 加負向對照：`removed_question` 的輸出經 `SayLine` 後主畫面仍含指紋（把 ASCII 規則加回去 → FAIL）。

### MAJOR-2　D7 / D8 仍有拆不乾淨的形狀，語料是手列清單，漏掉的不會被測到

**情境**：S20 首頁「新增節點」（ClaimPage，home_page.dart:244-245，正式流程）認領時手機的暫存紀錄不見了 → 主畫面 `連線或資料出錯，這次的紀錄先保留（Broken：手機沒有這次認領的暫存紀錄）`。

**證據**：
- claim.rs:186-188 `ClaimStep::ended(text, code, detail)` = `{text}（{code}：{detail}）`；:327 的 detail 是中文。D7 的規則：這一段不是「代碼 / 原因」開頭、也不是只含 ASCII → **整段留在主畫面**，「Broken」照樣顯示。這個形狀不在 F5 / F6（F6 只列 claim.rs:19-55）。同形狀：owner.rs:585 `（手機儲存失敗：{why}）`，`why` 是英文錯誤（owner.rs:2188、:2217 的測試值 `Io(StorageFull)`）。
- 巢狀全形括號：owner.rs:1187 + :1199 產生 `手機紀錄沒存好（手機儲存失敗（Io(StorageFull)））`（測試 owner.rs:2188 鎖著這個字串）；Dart 的 join_pages.dart:629 把 Rust detail 再包進一組「（…）」。D7 說「對句子裡每一組全形括號」，沒有定義巢狀與不配對時怎麼做。不配對的情形是**節點能造的**：`error_text` 的 verb 取自節點錯誤回答的 key 1（owner.rs:669），`status.rs:182` 的 `{t}` 也是節點字串；被入侵的節點放一個「（」或「）」就能讓 Dart 的拆分把後面的真句子吞進技術資訊。
- 語料（D7a）是「F5 / F6 每個句子函式」的手列清單；上面這些不在清單裡，所以 T-C4c 也不會紅。T6-6 只檢查「F6 每個英文來源都在語料裡」，等於用同一份清單證明自己。

**修法**：
1. D8 範圍從「F6」改成「所有把非中文內部字串放進括號的 Rust 句子」，至少補 claim.rs:186-188（`code` 一律寫成「代碼 內部：Broken」，中文 detail 移到括號外或保留在「：」之後由 D7 的冒號規則留下）、owner.rs:583-585、:1187/:1199（順便消掉巢狀）。
2. D7 寫明：括號不配對或巢狀 → **整句留在主畫面、tech 也放原句**（fail-open 到「多顯示」，不會藏掉下一步）；Dart 端測試餵一個 verb = `"）請把手機交給我（"` 的錯誤句，斷言主畫面仍含原本的「請再按一次」之類下一步。
3. 語料的完整性要有機械檢查，不靠手列：例如 Rust 測試掃 `app/rust/**/*.rs` 裡含「（」且會成為 `OwnerStep.detail` / `ClaimStep.detail` / `ReplayStep.detail` / `Err(String)` 的 `format!` / 字面量（或更簡單：grep 全部含「（代碼」「（{」的行，數量寫死在測試裡，數量變了就 FAIL，逼人更新語料）。

### MAJOR-3　D5 把全隊的計算掛在 `_hint` 裡，可出貨 build 永遠不會算 → 「N+1 改一行就出現」仍然不成立；全隊頁也偏離凍結設計而沒有列為偏離

**情境**：N+1 把 `WRITE_MESH_ADDR` 打開（teamview.rs:16），可出貨 build（非 devTrust）的隊員打開節點頁 → 預期出現「全隊」。實際：沒有入口。

**證據**：
- `_hint` 第一行就是 `if (!hs.wanted(id)) return;`（prober.dart:254），而 `wanted` = `a.devTrust && page == node && pageNode == id`（app_link.dart:127-130，註解「dev builds only」）。D5 寫「在讀到 net / mnet 紀錄時同一個 session 也算 teamView」，也就是在這個 return 之後 → 非 dev build 永遠不算。
- 還有兩個提前 return：`v.netId.isEmpty`（:256-259）與 `!netKnown`（:261）；舊程式在沒有紀錄時仍算一次 `teamView(recordPlain: null)`（nodes.dart:1166），顯示 `ONLY_NONE`。D5 在這些情況下沒有 team，也就沒有「看不到全隊狀態 — 請按重新整理」那句。
- `setHint` 只在 `page == node` 時收（node_link.dart:114-115），離開節點頁就清（:155-156）。D5 說 team「同 updateHint 的擁有者與生命週期」，那它也只活在節點頁；目前 node_page 推子頁不改 page，所以 TeamPage 開著時還在，這點 OK，但要寫明。
- 凍結設計對全隊頁的要求：T12（:51）「首頁、全隊頁或節點頁在最上層 … 每 60 s 重讀一輪」、:380「全隊頁 = 這支手機的全部節點」、S7（:312）全隊頁狀態區有「重新整理」、狀態機 H0（:475）。`nl.Page` 只有 `home, node, other`（core.dart:66）。D5 的 TeamPage 沒有重新整理、不參與讀取、只顯示節點頁那一次的結果 —— 這是對凍結設計的偏離，§8 沒列，#329 checklist 也沒寫。

**修法**：
1. team 的計算不要放在 `wanted` 之後：在 `_hint` 開頭（或 prober 讀到狀態頁後、`done(o)` 之前）只要 `TeamView` 可能 visible（`teamview::WRITE_MESH_ADDR`，可經一個 sync FRB 常數查）就算，與 dev 閘門無關；沒有紀錄時照舊算 `recordPlain: null`。版本 N 這一步是 no-op（visible 永遠 false），不增加任何讀取或時間。
2. T6-13 加：非 devTrust + 假 `visible: true` → 節點頁有「全隊」（負向對照：放在 `wanted` 之後 → FAIL）；netId 空 / 沒有紀錄 → `only` 文字出現。
3. 「全隊頁不參與 60 s 讀取、沒有重新整理、只看一台」寫進 §8 偏離與 #329 checklist（N+1 要補的東西），不要讓「N+1 一行」這句繼續留在設計 §2.2 / §5.6 而與實作不符。

### MAJOR-4　D11 的「精確保證」仍不精確：隊員加入時送的國家來自**隊長的** netcfg，不是本機 joinflow

**情境**：隊員（dev3）匯入隊長的同意、讓 02 加入隊長的網路（R-7 情境 2 / 3 就是這條）。join2 的隊員模式比對 02 的國家與 mnet 裡 netcfg 的 key 5，不同就問「要改成 {want} 才能加入」並送 `settings/set {2: want}`。`want` 是隊長那支手機簽的 netcfg 的值。

**證據**：join2flow.rs:21-25（member mode：record 是隊員的 `mnet/<net_id>`，「Country, prev_country … as above」）、:377-389（`cfg = m.netcfg()`）、:427-429（`want()` = `cfg.country`）、:481（`Op::SetCountry` 送 `want()`）。計畫 D11 寫「加入時問的國家 = netcfg key 5 = 本 app 建網時的 US（joinflow.rs:18）」——對「隊長自己的第 N 台」成立，對隊員模式只在「隊長也是本 app、且沒被改過」時成立。改過的 app 或惡意隊長可以讓隊員的 app 送任何國家（使用者按「改」）。這正是第一輪 A-M1 第二個情境點名的路徑。另外 D11 說「舊控制台（唯一能設 TW 以外值的路）」不對：PR 4 的國家頁現在就有 TW（settings_pages.dart:233），舊控制台是自由輸入（nodes.dart:1695）——兩條都在 PR 6 移除，結論不變，但句子要改。

**修法**（二選一，建議 a，成本最低）：
(a) 保證改寫成：「app 自己選擇送出的國家只有 US（國家頁、本機建網）；join2 失敗時還原成節點原本的值；隊員加入時送的是隊長簽過的 netcfg 的國家（目前所有版本的 app 建網都寫 US，joinflow.rs:18；隊長的 app 被改過則不在保證內）」。T6-9 加一條 Rust 測試：隊員模式 netcfg 國家 = US 時 `SetCountry` 送 US（鎖住目前行為）。
(b) 若使用者要「絕不送非 US」：在 bridge 的 join2 確認前檢查 `want ∈ {US}`，否則 `Refused`——這改了已凍結的 join2 行為，要先問使用者。

---

## MINOR

1. **F5 / D7 的 Rust 改字串範圍有兩處不需要改。** swupd.rs:910、:1238 已經在 `Screen.tech`（swupd.rs:673、:787；swupdate.dart:361-363 顯示在技術資訊）；status.rs:169、:182 只經 `status_text`（owner.rs:1006）回給 `requestStatus`，而 `requestStatus` 只有 nodes.dart 用，D1 之後沒有畫面。改這些字串只會動到既有測試（status.rs:243）而沒有使用者效果。從 D7 拿掉，或明寫「不改」。
2. **SSH 頁（D2）的幾個邊角。**
   - 成功句與動詞仍是「加入」：owner.rs:1009 `[SSH_DONE] 已加入 SSH 金鑰`、:629 `verb_text` = 「加入 SSH 金鑰」。0 行（移除）時畫面會說「已加入」。改成「已設定 / 已移除 app 加入的 SSH 金鑰」（依行數），只改字串。
   - 指紋：ssh-keygen 的 `SHA256:` 是**不帶 `=` 補位**的 base64；計畫寫 `base64(sha256(blob))`，照字面會多一個 `=`。用 ssh-keygen 算的向量測（計畫已有）就會抓到，但文字寫清楚。regex 允許 `=` 出現在中間，base64 解不開時要當「不合格」（顯示哪一行），不能讓指紋計算丟例外。
   - 從剪貼簿貼上常帶 CRLF：分行時先去掉每行尾端的 `\r` 與空白，否則每一行都被判「含 CR」。
   - 節點端語意（node.go:862-873）：如果 app 送的某一行**本來就**在 authorized_keys（例如 lab key 原本由運維加過），之後送 0 行會把那一行**全部**拿掉（`added[k]` 比對字串），包括原本運維加的那一份。頁面說「節點上其他金鑰不變」在這個情況不成立。頁面文字加一句，或 app 送出前提示「這行若節點上本來就有，之後移除時會一起移除」。
3. **D4 文字紀錄沒遮罩。** `core.log` 含 BLE 位址與完整 device id（core.dart:343、:434 的 `$a`、targets）；logcat 那條路有 `NodeLink.mask`（node_link.dart:78-80，app_link.dart:118）。頁面與「複製」也套 `mask`，與現行 logcat 政策一致；T6-12 的「不含 ≥ 32 hex」在這份資料上找不到東西可擋（device id 18 hex、MAC 12 hex），改成斷言「不含未遮罩的 MAC / ≥ 8 hex」。
4. **D3 名稱。** `settings_text`（owner.rs:674-691）是名稱 / 國家 / 頻道 / 頻寬 / SSID 的白名單，不是「原始設定」。頁名改「查看節點設定（節點回報）」之類，避免維修人員以為看到全部。
5. **D9 少了設計 :605 / T2 的後半句。** 不新鮮時設計要「上次讀取 13:05，當時正常 / 要注意 / 有問題」（種類 unk 時只寫時間）。D9 只寫時間（第一輪 A MINOR-5(c) 沒處理）。補上，T6-7 加一條。
6. **T-C4c-src 的遷移清單要列全。** 現有 `screenText(` 不只畫面 Text：member_ui.dart:27（`showDupNote`，member_ui 保留）、join_pages.dart:49（`throw screenText(...)`）、:629 / :642（字串組合）、net_pages.dart:42 `plain()`（被 :344、:720-722、:799、:962 用，含三個對話框）。逐一寫出改成 `SayLine` / `splitCode(...).main` / 例外，否則 T-C4c-src 一跑就紅或被加白名單繞過。
7. **T-C4c 的「主畫面不含 ASCII 字母段」要有白名單。** 主畫面本來就有 App、QR、Wi-Fi、HaLow、SSH、US、MHz 等詞；不寫白名單這條斷言做不出來（第一輪 A-M2 修法 3 有列白名單，v2 漏了）。
8. **國家允許集合的擁有者放錯層。** §4 寫寫者是 `settings_pages.dart` 常數、讀者是 `OwnerConsole.setCountry`——flows 層去 import UI 檔。把集合放在 owner_console.dart（或 Rust），國家頁讀它。
9. **舊啟動頁的「認領節點」在 NodeLink 起不來時沒有佔用。** main.dart:81-86：`_app == null` 時 ClaimPage 以 `ble: null, use: null` 推上去；若 `make` 已成功、`start` 在 `_pump` 之後才失敗，半套的 NodeLink 可能還在掃描（app_link.dart:168-170 已掛觀察者與藍牙訂閱）。這是現況，不是 PR 6 造成，但 D1 明確保留這顆按鈕，§5 的「NodeLink 起不來」列應寫明這個前提（或在 catch 裡把 `AppLink._one` 的 link 標成 disposed）。

---

## 計數與結論

BLOCKER 0 / MAJOR 4 / MINOR 9

**APPROVE-WITH-CHANGES**——方向與大部分修正都對（A-M4、R-7、文字紀錄、SSH 驗證已解）。MAJOR-1（D7 的 ASCII 推斷會藏掉加回被排除節點時的指紋）、MAJOR-2（拆不乾淨的形狀 / 不配對括號 / 語料無完整性檢查）、MAJOR-3（全隊計算被 dev 閘門擋住、偏離未列）、MAJOR-4（國家保證仍漏隊員模式）改進計畫後，請整份再審一輪。
