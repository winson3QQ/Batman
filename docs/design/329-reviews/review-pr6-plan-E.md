# #329 PR 6 計畫 v3：審查 E（第三輪，整份）

審查對象：`docs/design/329-pr6-plan.md` v3（worktree C:/src/Batman-329pr6，HEAD c4905ed）。基準不重審（設計 v12.1、PR 1–5、#349）。
方法：唯讀。每條都對原始碼查（`file:line` 附在各條，路徑相對 repo 根）。沒有上機、沒有跑測試、沒有跑 cargo / flutter。全隊頁照使用者 2026-11-18 的決定要做，本輪只審「怎麼做」。

## 前兩輪 MAJOR 是否解掉

| 前輪 | 結果 | 說明 |
|---|---|---|
| A-M1 / B-M3 / C-M4 / D-m5 國家 | ✅ | D11 的三種來源寫得精確：joinflow.rs:18 `COUNTRY = "US"`；join2flow.rs:21-25 隊員模式用 mnet netcfg；join2flow.rs:481-484 `SetCountry` 送 `want()`、`Revert` 送 `prev_country`。剩一處文字不一致（MINOR-2） |
| A-M2 / B-M1 / C-M1 ASCII 段 | ✅ | 只拆含「代碼 」的括號；`操作（x/y）`、`（4 MHz）`、`（v3）`、指紋都留在主畫面 |
| C-M2 形狀 / 巢狀 / 語料完整性 | ⚠️ 一半 | 巢狀、不成對、跨行的處理寫清楚了；節點括號換半形也有。但 C-M2 修法 1（D8 範圍改成「所有把非中文內部字串放進括號的句子」）沒做，而且掃描用的關鍵字只有「代碼」，抓不到其他帶碼的形狀 → 本輪 MAJOR-1 |
| A-M3 英文來源 | ⚠️ | 同上：owner.rs:583、:585、:587、:1188、:1199 還沒處理 |
| A-M4 重試半套 AppLink | ✅ | |
| A-M5 / B-M6 / D-M4 R-7 | ⚠️ 大致解 | dev3 的性質、同一支手機不能互掃、順序都寫了；節點重開的做法沒有證據，結束狀態前後矛盾 → MINOR-11 |
| A-M6 / C-M3 / D-M1 全隊頁 | ⚠️ | 方向對了（`Page.team`、不經 `wanted`、首頁入口）；但新加的契約有洞 → MAJOR-2、MAJOR-3 |
| B-M4 / D-M2 文字紀錄 | ✅ | `NodeLink.mask`（node_link.dart:78-80）會遮掉 18 位 hex 的 ID 與 MAC；事件的接法見 MINOR-7 |
| B-M5 SSH | ✅ | |
| D-M3 孤兒加入項目 | ✅ | D4a 對；`forgettable` = `joining && !creator`（member_ui.dart:174），所以不會列到別人的 approved 節點。另見 MINOR-8 |

## 查過、沒有問題

- **core 裡把 `Page.home` 當特例的地方**：整個 `lib/`（nodes.dart 除外）只有三處——core.dart:164-168 `_pageTargets`（exhaustive switch，加了 enum 值不改會編譯失敗，所以不會漏）、core.dart:170 `_eligible`（`page != Page.other`，team 自動算在內）、core.dart:196（只對 `Page.node`）。node_link.dart:115、:155 與 app_link.dart:129 只看 `Page.node`，team 的處理和 home 相同、是對的。main.dart:156 用 `Page.home` 起動，不用改。home_page.dart:184 的 `_back` 在 TeamPage 關掉後設回 home，是對的。唯一要改的地方是 `setPage` 的「同一頁不動作」判斷（MINOR-1）。
- **net 紀錄路徑**：`v.netId` 是 16 bytes 的 hex（owner.rs:2282），`store::valid_path` 擋掉 `..`（batman-proto/src/store.rs:43-44、:74-75），所以節點回報的 netId 不能拿來穿越路徑。
- **網路秘密的明文**：field 版的 `NetIndex.compute` 本來就會打開每個 `net/`（net_index.dart:186-193）。N+1 每次讀取都打開一次，增加的是次數，不是新的暴露面。
- **reason 14 / AlreadyMember**：reason 14 =「要先讓節點離開網路才能改國家」（owner.rs:650）。第 2 步時 02 不在網路，可以改。`check_joinreq` 只有同一台、同一個擁有者、而且是 Approved 的時候才放行（approve.rs:125-131），其他情況都是 `AlreadyMember`。第 6 步用新網路，不會碰到這條，也不會碰到 `previous_of`。順序沒問題。

---

## BLOCKER

無。

## MAJOR

### MAJOR-1　D7 / D7a 的規則與掃描只認「代碼」：`（原因 N）`、`（回覆碼 N）`、括號裡的英文內部字串都會留在主畫面，而且語料也不會收到它們

**情境**：隊長用 S20 讓第二台加入網路，節點回「沒有套用」（R-7 情境 5 / 6 很可能遇到）。主畫面顯示 `[JOIN_STATE] 節點沒有套用這個網路（回覆碼 11）。常見原因：…`。另一個情境：節點回了 app 不認得的 reason 99，主畫面顯示 `更改設定沒有成功：節點拒絕了（原因 99）（代碼 4，原因 99）`，D7 只拆第二組括號，於是主畫面還有「原因 99」。

**證據**：
- owner.rs:649 `r => format!("節點拒絕了（原因 {r}）")` 是 `reason_text` 的預設分支。它的結果是 owner.rs:668-671 `error_text` 的 `{why}`，接在 `（代碼 …）` 前面。這組括號裡沒有「代碼 」，照 D7「不含代碼的括號一律不動」會留下來。T-C4c 卻斷言「主畫面不含『原因 』」。規則和測試自相矛盾，而且語料有沒有收進這一句，取決於固定輸入有沒有用到 7 / 13 / 14 / 20 以外的 reason。
- owner.rs:560 `（回覆碼 4）`、owner.rs:563 `（回覆碼 {c}）`，join2 的失敗句（測試 owner.rs:1873 鎖著）。「回覆碼」不含「代碼」，所以：D7 不拆；D7a 的掃描（「每一行含『代碼』的字串」）找不到；T-C4c 的「不含『代碼』『原因 』與 ASCII 字母段」也擋不到「回覆碼 11」（只有數字）。結果是碼留在主畫面，違反顯示規則 2，而且沒有任何測試會紅。
- 括號裡的英文內部字串（C-M2 修法 1 點名、v3 沒做）：owner.rs:583 `手機儲存失敗（{why}）`、:585 `（手機儲存失敗：{why}）`、:587 `加入網路中斷（{e}）`、:1188 / :1199 `（手機儲存失敗（{error}））`（巢狀，`error` 是英文，例如 `Io(StorageFull)`，owner.rs:2188）。這些括號裡沒有「代碼」，D7 不動，英文留在主畫面。D8 只寫「F6 全部 + Broken」。claim.rs:186-188 `ended` 是 `{text}（{code}：{detail}）`，D8 只說改成「（代碼 內部：Broken）」，沒說中文 detail（claim.rs:327）放在哪裡。照 D7「『：』之後有中文就留下」，`Broken：手機沒有這次認領的暫存紀錄` 會整段留下，「Broken」還是在主畫面。
- 機械掃描的關鍵字只有「代碼」。上面這三類都不會被要求登記，所以「完整性是機械的」這句只對「代碼」成立。

**修法**：
1. Rust 端把碼的寫法統一：`（原因 {r}）` 改成不帶碼的說明（例如「節點拒絕了」），碼只放在後面那組 `（代碼 …，原因 …）`；`回覆碼` 改成 `（代碼 N）`。
2. D8 範圍照 C-M2 改成「所有括號裡放非中文內部字串的 Rust 句子」，逐一列出 owner.rs:583 / :585 / :587 / :1188 / :1199、claim.rs:186-188（中文 detail 移到括號外，例如 `{text}：{detail}（代碼 內部：{code}）`）。
3. D7a 的掃描關鍵字改成一組：`代碼`、`原因 `、`回覆碼`，再加上「全形括號裡有 `{e}` / `{why}` / `{error}` / `{:?}` 插值」。T-C4c 的斷言同步加「回覆碼」。
4. 負向對照：把 owner.rs:563 改回「回覆碼」→ 掃描 FAIL；`reason_text(99)` 的句子 → T-C4c FAIL。

### MAJOR-2　全隊頁的資料契約不夠：`TeamView` 沒有 netId 可以分段、新鮮度沒有照 §4.3.1、卡片的後四碼沒有來源

**情境**：N+1 打開後，隊長有兩台節點（A 在網路 X，B 剛離開網路），app 從背景回來、藍牙還沒開。

**證據**：
- D5(d) 寫「每個網路一段（同一個 netId 取 `readAt` 最新的那台）」，但 `TeamView` 只有 `visible / title / only / cards / note / tech`（teamview.rs:234-246；bridge owner.rs:1365），沒有 netId。D5(a) 的 `TeamSink.onTeam(id, team, readAt)` 也沒有帶 netId。頁面只能另外去 `states[id].extra` 找 netId，那是另一個寫者、另一個時間點，兩者會對不上。
- 不在網路的節點：`team_names` 在 netId 空時是 `Names::NoNet`，`team_view_with` 仍然回 `visible: true` 加 `ONLY_NO_NET`（teamview.rs:290-298、:348-354）。讀資訊失敗時是 `NoInfo`，netId 未知。D5 沒說這兩種要歸到哪一段。它們讓 `visible` 為 true，所以 D5(c) 的首頁入口在 N+1「只要讀到任何一台」就會出現，即使手機沒有任何網路。這與設計 :703「只列現在真的能做的」相衝突。
- 新鮮度：卡片帶 🟢「在線」（teamview.rs:322）。這是顏色，設計 §4.3.1 規定「新鮮」是唯一能給顏色的判斷，實作上是 `core.fresh()`：進背景就變舊、藍牙關或沒權限就沒有顏色（core.dart:149-154）。D5(d) 只用 `readAt` 過 300 s。從背景回來或藍牙關掉時，全隊頁還會顯示最多 5 分鐘前的 🟢，首頁同時已經變成不明樣式。
- 「卡片 + 後四碼」（設計 :768）：Rust 的卡片是已經排好的字串（teamview.rs:313-327），只有名稱；`Listed` 只有 `dac_pub_hash`，沒有裝置 ID。D5 沒有說後四碼從哪裡來。要嘛現在改 Rust，要嘛 N+1 又得改不只一行。
- 被入侵的自己節點：它可以回報手機上**另一個**網路的 netId，加上假的 key 9。因為「取 readAt 最新」，它的 TeamView 會蓋掉那個網路的真資料。名稱本來就只供參考，但「哪台在線」被整段替換掉了。

**修法**：
1. `onTeam(id, netId, team, readAt)` 由 prober 從同一次讀取的 `v.netId` 帶入。分段規則寫明：netId 空 / 未知 → 不分段，或在頁尾逐台列出。首頁入口只看「netId 非空、手機有這個網路的紀錄、而且 `visible`」。
2. 顏色與舊資料樣式用來源節點的 `core.fresh(id)`（不新鮮 → T2 樣式「上次讀取 HH:MM」，卡片去掉 🟢 或整段改成不明樣式）。`readAt` 用 `NodeLink.readWall`，不另外記時間。
3. 後四碼：Rust `team_view` 在 `Listed` 帶出節點的後四碼（名單裡有 DAC，app 的 node 紀錄可以對應）；或明寫 v3 不做、移到 #329 checklist，並刪掉 §5.6「同時顯示後四碼」的承諾。
4. 只有當這台節點在那個網路紀錄的名單裡（`own_dac` 能在 `names` 找到）時，才把它的 view 算進該網路那一段。
5. T6-13 加：背景回來 / 藍牙關 → 沒有 🟢（負向對照：只看 300 s → FAIL）；NoNet 的節點不造成入口（負向對照：只看 visible → FAIL）。

### MAJOR-3　prober 裡的全隊計算：放在哪個預算、session 的存活、每次讀取的成本，都沒有寫

**情境**：N+1 field 版，手機有 4 台節點，每 60 s 一輪。

**證據**：
- 現有的 `_hint` 在 `done(o)` 之前執行，用 `Future.any([... .timeout(hintMax 2 s), cancelled])` 包住（prober.dart:159-166）。這段期間 BLE 連線與 session 都還開著，一輪的下一台要等。D5 只寫「讀到本體之後、不經 `wanted`」，沒說：
  (a) 是不是在同一個 2 s 預算裡；
  (b) 在 dev 版的節點頁，hint 和 team 都要開 `net/`，會不會開兩次（各一次 Keystore `open`，app_link.dart:132 → `openSealedRecord`）；
  (c) `await openNet` 之後、呼叫 `session.teamView` 之前有沒有 `stop()` 檢查。`_hint` 有（prober.dart:264），因為 cancel 時 `done(read)` 會讓清理段 `s?.dispose()`（prober.dart:242）。少了這個檢查，就會呼叫已經 dispose 的 FRB 物件。
- 成本：N+1 之後每台每輪多一次 Keystore 解密，而且解密時連線還開著。設計 T12 的代價只算了「每分鐘每台一次登入」。這次沒有任何量測（本版 `team_enabled()` false，真機量不到，而 release build 不能開 `team-write`，teamview.rs:20-21 是 `compile_error`）。「N+1 只改一行」的承諾等於把一個沒量過的成本直接交給 N+1。
- `team_enabled()` 是 FRB sync 呼叫。prober 的單元測試不初始化 RustLib，T6-13「假 true / 假 false」要靠注入（例如 `HintSource.teamEnabled`），計畫沒寫。

**修法**：
1. 寫明：team 與 hint 共用**一次** `openNet` 的結果；兩者都在同一個 `hintMax` 預算內；每個 `await` 之後都有 `stop()` 檢查，`session.teamView` 前也有；逾時或例外只記 log，不影響這次讀取的結果。
2. 或者更好：`team_view` 只需要 session 裡已經讀到的 `page_status / page_info`（owner.rs:1361-1366），不需要 BLE。改成在 `done(o)` 之後、清理段 `s?.dispose()` 之前計算，就不會佔住連線。
3. `team_enabled` 用注入（`HintSource.teamEnabled`，app 傳 Rust 的 `team_enabled`）。
4. 在 S20 上跑一次 debug build（開 `team-write`，只供量測，不出貨），記錄每次讀取多出的毫秒數與一輪的總時間，寫進 PR 與 #329 的 N+1 checklist。真機數字不到手就標 ⚠️。

---

## MINOR

1. **home ↔ team 換頁會取消正在跑的一輪。** `setPage` 只在 `pg == page && node == pageNode` 時不動作（core.dart:189），從首頁進全隊頁會 `_cancel`（core.dart:190）。兩頁的目標一樣（都是全部節點），卻把讀到一半的一輪丟掉；來回切換時，一輪可能永遠讀不完。修法：home 與 team 互換時只改 `page`，不取消、不重排計時。T-X 加一條「H1（首頁一輪進行中）→ 進全隊頁 → 同一輪繼續」。
2. **§4 契約表有三列還是 v2 的內容，和 D 段矛盾。**「`NodeLink` 的每台 `team`」寫者寫 `SessionProber._hint（同 updateHint）`、讀者有節點頁，和 D5 矛盾。「`rust_sentences.txt`」是單一檔，D7a 是兩個語料檔加一個 sites 檔。「國家允許集合」的寫者寫 `settings_pages.dart`，D11 寫 `owner_console.dart`。以 D 段為準改正。
3. **節點的 verb 只換括號還不夠。** `error_text` 的 `{verb}` 是節點錯誤回答的 key 1 原文（owner.rs:670），沒有經過 `shown`。被入侵的節點可以塞全形「，」切出新的段，或塞中文段讓 D7 把它「留在主畫面」，看起來像 app 自己的說明；拿掉代碼之後，這句反而比現在更像 app 的話。修法：verb 只收 `^[a-z0-9_/-]{1,32}$`，其他一律不放；或者 verb 那一段一律進技術資訊。
4. **D7「緊接在代碼段之後」沒定義「原因 」段算不算代碼段。** F5 的例子 `（代碼 6，原因 20，settings/set）`（owner.rs:1782）需要算。寫明「代碼段或原因段之後」。
5. **D7a 掃描的細節。**
   - (a) 「非測試段」怎麼判斷：member.rs 有好幾個 `#[cfg(test)]`（:358、:438、:465、:480），swupdate.rs:153 是 impl 內的單一項目，不能用「第一個 cfg(test) 以後全是測試」。建議直接掃全部行（測試裡的斷言字串也登記），或寫出括號配對的規則。
   - (b) sites 檔的一行怎麼對到語料的 id，沒有定義。
   - (c) dev-trust 那一輪是跟哪一個檔比、會不會改寫 field 那一輪的檔，沒有寫。
6. **T-C4c 的 ASCII 白名單會碰到從輸入帶進來的 ASCII。** 例如 owner.rs:536 的 `{mesh_id}`、owner.rs:540 `國家仍是 {have}`（JP）。寫明語料固定輸入的佔位值另外列入白名單，或者改成檢查「字面量裡的 ASCII」。
7. **D4 的兩類事件。** app_link.dart 建 `RecordWriter` 時沒有傳 `log`（app_link.dart 的 `RecordWriter(reg, RecordStore(...))`），所以「現在只進 logcat」對寫入失敗不成立：拒絕連 logcat 都沒有。另外，「寫入失敗」是指 `NoLease` 拒絕（record_writer.dart:27-31）還是 store 的 I/O / CAS 錯（:41、:48，現在直接往外丟），要寫明（建議兩者都記）。佔用收回可以掛在 `NodeLink.revoked`（node_link.dart:419，它本來就是 `LeaseListener`），並分開記 420 s 收回與 OfflineOp 的 60 s 收回（lease.dart:85-89）。
8. **D4a 的確認對話框。** 孤兒項目最常見的成因正好是「節點壞了 / 遺失之後用 T17 刪掉」。對話框要用 `forgetNotice(approved: false, offerExclude: true)` 的說明，並指向既有的排除入口（team_pages.dart:174-183，自己的節點逐台排除）。舊控制台有這個選項（nodes.dart:1274-1286）。
9. **D6 的金鑰能力是開 app 時的快照。** X26 之後金鑰可能已經不能用。診斷頁改成開頁時 `KeyAbilities.read(platform)` 讀當下的值，與 app_link.dart 的 `keysOk` 同一個來源。
10. **全隊頁真機看不到。** release build 不能開 `team-write`（teamview.rs:20-21），R-7 走不到全隊頁。PR 說明與 §8 要標 ⚠️「只有 widget 測試與畫板」（D 第二輪 m10 在 v3 沒寫進去）。
11. **R-7。**
    - (a) **未驗證的前提**：「04 用 SSH `reboot`（04 有 lab key）」與「02 加回 lab key 後可以 SSH」都沒有附任何擷取的輸出。02 加入網路後 IP 可能改變（上游兩段式定址），電腦從哪條路連到 02 也沒寫。開場前先用唯讀命令（例如 `ssh … true`）確認，連不上就改成請使用者拔電，並寫進同意清單。
    - (b) SSH `reboot` 是正常關機，不等於現場的斷電（例如「存檔要等這台節點下次開機才完成」那一類，owner.rs:537）。至少一條情境用拔電。
    - (c) 情境 8 的國家：02 如果本來就是 US，「目前 TW → 改 US」在真機上走不到（app 已不能設 TW），要標 ⚠️。
    - (d) 結束狀態寫「04 = dev 的網路（新版本號、新密碼）」，但第 5 步是 04 離開後建**新**網路。舊的 `net/`（v6 / v7）留在 dev 手機上。結束狀態與要不要清舊紀錄，要寫清楚。
    - (e) 「正在連到節點…」秒數的證據來源（BMAPP logcat 時間戳）沒寫（D 第二輪 M4(e)）。
12. **D2 成功句。** Rust `[SSH_DONE]`（owner.rs:1009）不知道送了幾行。「已設定 / 已移除」要靠 session 記住行數，或由 Dart 依送出的行數決定。寫明由誰決定。
13. **D11 的閘門只在 Dart。** `request_set_country`（owner.rs:818-821）在 Rust 不檢查國家。fail-closed 的承諾只靠 `owner_console.dart` 的一個常數。可以接受，但 §6 的「fail-closed」要寫明只在 flows 層；或者在 Rust 也加 `{"US"}` 的檢查（成本很低）。

---

## 計數與結論

BLOCKER 0 / MAJOR 3 / MINOR 13

**APPROVE-WITH-CHANGES**

前兩輪多數 MAJOR 已解：國家、ASCII 段、重試、文字紀錄遮罩、孤兒加入項目；全隊頁的方向也對了。

還要修的三個 MAJOR：
- MAJOR-1：「原因 N」「回覆碼」和括號裡的英文會留在主畫面，掃描只認「代碼」，抓不到它們。
- MAJOR-2：全隊頁分段沒有 netId，新鮮度沒有照 §4.3.1，後四碼沒有來源。
- MAJOR-3：prober 裡的全隊計算沒有寫預算、session 存活與成本。

修完後請整份再審一輪。
