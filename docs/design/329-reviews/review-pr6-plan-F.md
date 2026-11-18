# #329 PR 6 計畫 v3：審查 F（第三輪，整份）

審查對象：`docs/design/329-pr6-plan.md` v3（worktree C:/src/Batman-329pr6，main c4905ed）。基準不重審（設計 v12.1、PR 1–5、#349）；只看新範圍與被刪 / 被改的舊行為。全隊頁「做不做」已由使用者決定，本輪只審「怎麼做」。
方法：唯讀。對原始碼逐條查（file:line 附在各條）；`grep -rn` 掃 app/test 全部依賴；沒有上機、沒有跑測試。

## 前輪 MAJOR 是否解掉

| 前輪 | 結果 | 說明 |
|---|---|---|
| C-M1 ASCII 段誤藏 | ✅ | D7 只拆含「代碼 」的最內層括號 |
| C-M2 形狀 / 語料完整性 | ✅（另有 MINOR-4） | sites 檔機械掃描可行（Rust 含「代碼」的非測試行約 22 處，7 個檔） |
| C-M3 / D-M1 全隊頁 | ⚠️ | 結構對了（`Page.team`、不經 `wanted`、首頁入口）；資料契約與卡片內容有新問題 → MAJOR-2、MAJOR-3 |
| C-M4 國家 | ✅ | D11 三種來源寫清楚 |
| D-M2 文字紀錄遮罩 | ✅（另有 MINOR-7） | `NodeLink.mask`（node_link.dart:78-80）＋ note |
| D-M3 孤兒加入項目 | ⚠️ | 有入口了，但 D-M3 修法要求的「排除這台」與警告句被拿掉 → MAJOR-4 |
| D-M4 R-7 | ⚠️ | dev3 性質、同手機、順序都寫了；「每一步三種中斷」的破壞性部分沒列時機與副作用 → MAJOR-5 |

## BLOCKER

無。

## MAJOR

### MAJOR-1　刪 NodesPage / StatusPageView 會丟掉的測試沒有列全，其中有安全回歸測試

- 情境：照 §7「既有」列實作，刪 nodes.dart 與 member_ui.dart 的 `StatusPageView` / `ControlsAndLog` / `ReadClock`（D1）。編不過的測試檔被整段刪掉或改寫，沒有對照清單，回歸保護默默消失。
- 證據（`grep -rn "nodes.dart\|NodesPage\|StatusPageView\|ControlsAndLog\|ReadClock" app/test`）：
  1. **`test/nodes_zero_test.dart`（計畫完全沒提）**：2 條測試，把每個 platform 回答做成**唯讀 buffer**（S20 實機發現的 bug：`fillRange` 在 channel 的 view 上丟例外，檔頭 :1-5），驗「成員同意匯入 / 更新匯入」完成且 z 歸零不丟例外。新頁的對應測試 `test/ui/join_pages_test.dart:396-408`、:486 只驗 `everyElement(0)`，**沒有任何唯讀 buffer 的假資料**（`grep asUnmodifiableView\|Unmodifiable test/ui` 無結果）。刪掉後，新頁若改成直接歸零 channel 的 buffer，離線全綠、真機丟例外。
  2. **`test/member_ui_test.dart`**：計畫只寫「nodes.dart 排除拿掉」，但這個檔直接 pump 被刪的 widget：T8 status page（:86-260，含 `ReadClock` :241）、S6 leave（:295-460 的 widget 部分）、S6 remove member（:575-600）、**T-A9「全隊段不進紀錄」安全測試（:605-656，含負向對照）**、team section 兩條（:116-157：`only` 在卡片之上、位址尾碼只在摺疊的技術資訊裡、標題接「，讀取於」）、T9 My nodes layout（:499-530，`ControlsAndLog`）。
  3. **`test/nodes_update_send_test.dart` 自己的 12 條**（:464-657）：S3 / T-N2 加入路由、PR3-1 防漂移（consolePaths，§3 已寫「劃掉」，OK）、r3 E-M1 pop mid-login、T30 ×2、T19。計畫只把它當假節點庫搬家。
  4. `test/key_abilities_test.dart:338`（入口表的「舊版控制台」列）、:633-643（「我的節點: login not allowed」）；`test/ui/pages_test.dart:275`（舊版控制台入口斷言）。
- 修法：§7 加一張「被刪測試對照表」：每條（檔:行）→ 新頁已有的對應測試（檔:行）/ 移植到哪 / 不再適用（理由）。至少：(a) nodes_zero 改成對 `join_pages` 的兩個匯入跑唯讀 buffer，負向對照 = 歸零 channel buffer → FAIL；(b) T-A9 與 team section 兩條移植到 `TeamPage`（假 `visible:true`、哨兵位址、`debugPrint` 攔截；負向對照沿用 :650）；(c) T30 / T19 / S3 對到新頁的現有測試行號，沒有就移植。

### MAJOR-2　D5(d)「卡片 = 節點回報的名稱 + 後四碼」用現有 `TeamView` 做不到，名稱來源也寫錯；254 凍結設計的版面規則沒帶過來

- 情境：實作 TeamPage 時要在每張卡片顯示後四碼（T6-13(c) 也要驗）。
- 證據：
  - `TeamView.cards` 是 Rust 排好的整句字串（teamview.rs:241-264：`format!("🟢 {name} 在線…")`），`Listed` 只有 `dac_pub_hash / name / addr / next`（teamview.rs:85-97），**沒有 device id**；Dart 拿不到「哪張卡是哪台」，也就沒有後四碼可加。只有不明節點有位址尾碼，而且 254 設計規定它**只在摺疊的技術資訊裡**（teamview.rs:265；member_ui_test.dart:131 `findsNothing` 斷言）。
  - 名稱不是「節點回報的」：teamview.rs:1-4「names … come only from the admin-signed list … never from a hostname」。設計 §5.6（329-app-uiux.md:768）的說法與程式不符；計畫照抄。這是安全性質（名稱只來自隊長簽的名單），寫錯會讓實作者去讀節點的 hostname。
  - 254 凍結設計的版面規則（`only` 在卡片之上、位址尾碼只在技術資訊、標題接讀取時間、全隊內容不進任何紀錄）在 D5(d) / T6-13(c) 都沒寫。
- 修法：二選一並寫進計畫：(1) 改 Rust `TeamView` 加每張卡的結構欄位（名稱、device 後四碼——需要簽章名單裡有 device id，先查 netrec 的 member entry 有沒有；沒有就做不到），這是改 254 凍結設計，列為偏離並請使用者拍板；或 (2) 不加後四碼，§5.6 那半句列為偏離（理由：凍結的 254 卡片沒有這個欄位）。名稱來源改成「隊長簽的名單（admin-signed）」。D5(d) 補上 254 的四條版面規則，T6-13(c) 各一條斷言＋負向對照。

### MAJOR-3　全隊資料路徑的契約不完整：分組鍵、離開網路、取消 / 移除競爭、時間上限

- 情境：N+1 打開後，field 版首頁每 60 s 一輪；使用者在一輪中按「新增節點」或 T17 移除一台；或某台節點離開網路。
- 證據與缺口：
  1. **分組鍵不在契約裡**：D5(d)「每個網路一段（同一個 netId 取 readAt 最新的）」，但 `TeamSink.onTeam(id, team, readAt)` 沒有 netId，`TeamView` 也沒有（owner.rs:1361-1367）。TeamPage 只能另外去讀 `states[id].extra` 的 `StatusView.netId`——那是不同的寫入點，可能不是同一次讀取。
  2. **離開網路自相矛盾**：D5(a)「netId 空 → `recordPlain: null`」仍呼叫 `teamView`，Rust 回 `visible:true` ＋ `only`（teamview.rs:219、:300-305）→ 會產生一段 netId 為空的「網路」；§5 卻寫「網路離開 → `teams[id]` 清掉」。
  3. **取消後還在寫**：prober 在 `cancelled` 時先 `done(read)`、再 `cleaning = true` 並 `dispose` session（prober.dart:118、:224-240）。`_hint` 靠 `stop()` 在呼叫 session 前檢查（:264）。D5 沒寫 team 的計算要同樣檢查 `stop()`，也沒寫晚到的 `onTeam` 要丟：T17 在一輪中移除 `node/<id>`（拿佔用 → 取消這輪）→ 先清掉 `teams[id]`，再被晚到的 `onTeam` 加回來；那台不會再被讀，首頁「看全隊狀態」與那一段會一直留著。
  4. **沒有時間上限**：`_hint` 被 `hintMax = 2 s` 限住（prober.dart:47、:136），因為讀取期間 BLE 連線還開著、整輪只能一個嘗試（T1）。D5 在**所有版本、每輪每台**多開 1–2 次 Keystore 解密，沒寫上限；dev 版在節點頁時 hint 與 team 會把同一份紀錄各開一次。
  5. **netKnown 閘門被拿掉**：`_hint` 先 `netKnown(v.netId)`（prober.dart:260；app_link.dart:131-134）。D5 直接用節點回報的 netId 開 `net/` / `mnet/`。路徑本身安全（store.rs:44-48 只收小寫 hex 等），但被入侵的節點可以回報手機上**另一個**網路的 id，讓那個網路的名單被套到它的鄰居上（名稱是參考用，影響小，但應該寫進契約）。
  6. 「資料過 300 s」用的時鐘：`readAt` 若是牆鐘，時間被調就判錯；現有的新鮮判斷用 core 的單調鐘（node_link.dart:63-65 註解）。
  7. §4 擁有者表仍寫「寫者 `SessionProber._hint`」——v2 的殘留，和 D5(a) 矛盾。
- 修法：契約寫成：`onTeam(id, netId, team)`，寫者只有 prober，條件 `!stop()` 且 `id` 仍在 core 的紀錄裡；netId 空 → `teams.remove(id)`（不呼叫 `teamView`）；紀錄集合變動時（`setRecords`）修剪 `teams`；team 與 hint 共用同一次開紀錄、共用 2 s 上限，逾時 = 這次不更新（留舊值）；保留 `netKnown` 閘門（沒有對應紀錄 → `recordPlain: null`，不開檔）；過期用 `core.states[id].fresh`。T6-13 加：取消中晚到的 onTeam 被丟、移除紀錄後沒有入口、netId 空時那段消失、開紀錄卡住 > 2 s 不拖住讀取；各附負向對照。

### MAJOR-4　D4a「忘記加入中的節點」拿掉了安全警告與「排除這台」，正好是最需要的情況

- 情境：隊長的節點 X 在加入時中斷（net 紀錄是 joining），之後 X 遺失或被抓，使用者用 T17 把 `node/X` 從手機移除。現在到開發者選項「放棄這次加入」。
- 證據：
  - 舊控制台的同一個動作顯示 `forgetNotice(approved: false, offerExclude: dev)`，並在 dev 版多一顆「排除這台（換密碼）」（nodes.dart:1269-1283；member_ui.dart:177-180：「只忘記不會撤銷它已拿到的密碼；這台若可能遺失或被抓，請改按『排除這台』」）。
  - D4a 寫「和 `NetFormPage._forget` 同一個」——那裡是 `forgetNotice(approved: false)`，**沒有** offerExclude（net_pages.dart:321）。那條路只給手機上還有 `node/<id>` 的節點，可以接受；孤兒正是「節點已不在手機上」，遺失 / 被抓的機率最高。
  - 忘記之後，X 從 net 紀錄消失，「我（隊長）」頁的「排除 …XXXX（遺失 / 被抓；換全隊密碼）」列也跟著消失（team_pages.dart:175-183 從紀錄列出）→ 唯一的排除入口沒了，而 X 可能已拿到網路密碼。
  - D-M3 的修法原文就要求「dev 版保留『排除這台』入口（接 remove_pages 的排除）」。
- 修法：D4a 的確認對話框用 `forgetNotice(approved: false, offerExclude: true)`（此頁只在 devTrust），並加「排除這台（換全隊密碼）」→ `RemoveConfirmPage(node: dacHash, owner: '')`（同 team_pages.dart:166-168）。T6-14 加：對話框有警告句與排除按鈕、按排除開到 8.3；負向對照：拿掉 offerExclude → FAIL。

### MAJOR-5　R-7「每一步都做三種中斷」的破壞性部分沒有時機、副作用與還原

- 情境：§7 第 161 行「每一步都做三種中斷（關藍牙再開、節點重開、切到背景）」。第 8 步是 OTA（X14 上傳中切背景），第 1 步時 02 還沒有 SSH key，第 3 / 5 步在加入 / 建網的提交過程中。
- 證據：
  - 「節點重開」在第 8 步若落在上傳 / 寫入期間，就是刷機中斷電（A/B 回退路徑），副作用欄只寫「刷機（同版本）」。
  - 第 1 步的「節點重開」：02 還不能 SSH（§7 :145 自己寫了），只能請使用者拔電，沒列進同意清單。
  - 第 3 / 5 步在 join2 / 建網提交中重開 → 節點可能停在 joining / 未確認，還原步驟（再加入、檢查網路、`forgetJoining`）沒寫。
  - 使用者規則（CLAUDE.md「破壞性測試先列副作用」；記憶 feedback_destructive_test_side_effects）：動節點狀態的測試要先列每個碰到的資源與還原。
- 修法：加一張「中斷時機表」：每一步 × 三種中斷 → 精確時機（例：OTA 的節點重開只在上傳完成後、套用前，或明列為 A/B 回退測試並寫還原方式）、誰執行（SSH / 使用者拔電）、預期畫面、還原步驟；開場前一併取得同意。

## MINOR

1. **D3 沒寫佔用**：「查看節點設定」要登入節點，應照 5.6 走 `OpSession.once`（op_session.dart:89-136）；§5 只寫「唯讀」，容易被讀成不用佔用。寫明。
2. **D9 細節**：`was` 句尾在 home_logic.dart:179-183 有四種（含「當時還沒加入隊伍網路」與空字串），計畫只列三種；「時間在未來 →之前讀過」在 :157 只套用在上一次執行的 `UiNode.prev`，不是這次的 `readWall`；`prev` 在狀態區是否顯示沒寫；第 4 列（身分不符）旁顯示「當時正常」會誤導，建議第 4 列不加句尾。T6-7 的「四種情況」少於規則數，逐一列。
3. **§4 表過期 / 自相矛盾**：team 寫者寫 `_hint`；語料寫單一 `rust_sentences.txt`（D7a 是兩檔 + sites 檔）；國家允許集合寫 `settings_pages.dart`，D11 寫 `owner_console.dart`。
4. **D7a「子模組看得到私有項目」只對定義模組的後代成立**：一個 crate 層的 `sentence_corpus` 模組叫不到 owner.rs / rekey.rs / flow.rs 裡的私有函式；而且像 owner.rs:1335、:1554 這類句子在狀態機的 match 分支裡，不是可單獨呼叫的函式。寫明作法（改 `pub(crate)` 的句子函式、或每個模組各自的 `#[cfg(test)]` 產生器 + 共用寫檔）。
5. **T-C4c-src 的漏洞（D MINOR-2）仍在**：`plain(s) => screenText(s)`（net_pages.dart:42）這類包裝 grep 不到。改成 `screenText` library-private 或 widget 斷言。
6. **負向對照缺**：T6-13(c) 沒有負向對照；T6-1 只是不存在檢查，可接受但請加「入口被點擊後不會開到任何舊頁」的行為斷言。
7. **D4 收回事件不只 420 s**：OfflineOp 60 s 與原始佔用 900 s 也會收回（lease.dart:85-101）；三種都記，或寫明只記哪種。
8. **D6 金鑰能力是啟動時的快照**：設計 §4.1 每次登入前即時讀（app_link.dart:183）；診斷頁要嘛即時讀 `KeyAbilities.read`，要嘛標「啟動時」。
9. **D11「目前：XX（不在可選清單）」的 XX 來自節點**：要經 `shown`，並遵守 D7 的括號換半形規則。
10. **§3 swupdate「頂端加 StatusHero」**：內容（look / text 從哪來）沒寫，T6-11 無從斷言。
11. **新開發者選項入口的 KeyGate**：SSH、查看節點設定、忘記加入中的節點都要登入或寫紀錄；設計 :703（F42）要求 KeyGate 不允許時入口變灰並寫原因。key_abilities_test.dart:337-340 的入口表應加這幾列。

## 查過、沒有問題

- 讀紀錄不需要佔用：store 寫入是暫存檔 + rename（app_link.dart:36-38、store.rs:106-127），讀到的永遠是完整的一版；`RecordWriter` 只管寫（record_writer.dart:21-30）。prober 不寫紀錄（prober.dart:1-5）。
- `loginFor` 交接的 `HandoffProber` 沒有 hint、不讀狀態頁（prober.dart:59-67、:150-156），所以流程登入不會觸發 team 計算。
- `team_view` 讀的是 `requestStatusPage` 的結果（owner.rs:1344-1367），prober 讀的正是這個（prober.dart:155）。
- `WRITE_MESH_ADDR` 在 release 不可能是 feature 打開的（teamview.rs:16-22 `compile_error!`），本版 `team_enabled()` 為 false 屬實。
- SSH 的節點語意（整組取代、保留非 app 加入的行、同一把若本來就在會被一起移除）與 node.go:841-873 一致；dev3 的 devTrust 來自 gradle BuildConfig（build.gradle.kts:57-77；main.dart:104-107），臨時 flavor 設 `DEV_TRUST=true` 即可，Dart / Rust 不必改。
- 被刪符號沒有其他 lib 使用者：`StatusPageView` / `ControlsAndLog` / `ReadClock` 只在 member_ui.dart 與 nodes.dart；`NodeStatusList` 只在 main.dart:311；`leaveFlow` / `SendTrack` 仍被 owner_console / more_pages 使用（不在刪除清單，正確）。
- 「我的節點」字樣在 claim.dart:398、claim_recovery.dart:32 仍指得到首頁的「我的節點」段（home_page.dart:373），不會變成死連結。
- TeamView 的欄位沒有秘密：名稱經 `shown`、位址只有 4 hex 尾碼（teamview.rs:146-148、:265）；需要遵守的只有「不進紀錄」與「尾碼只在技術資訊」（見 MAJOR-1、MAJOR-2）。

## 計數與判定

BLOCKER 0 / MAJOR 5 / MINOR 11。

**APPROVE-WITH-CHANGES**——前輪多數 MAJOR 已解，方向正確。MAJOR-1（被刪測試沒列全，含唯讀 buffer 歸零與 T-A9 兩條安全回歸）、MAJOR-2（卡片後四碼用現有 TeamView 做不到、名稱來源寫錯、254 版面規則沒帶過來）、MAJOR-3（team 資料契約：分組鍵、離開網路、取消 / 移除競爭、時間上限）、MAJOR-4（孤兒忘記拿掉警告與排除入口）、MAJOR-5（R-7 破壞性中斷沒列時機與還原）修完後，整份再審一輪。
