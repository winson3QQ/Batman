# 審查：#329 PR 5 計畫 v9（第九輪，審查者 R）

範圍：計畫 `docs/design/329-pr5-plan.md` v9 的新部分（§0 第 1–9 項、§2–§7）。重點是安全與失敗時的行為：提示、8.4 / 8.5 的正向信號、OfflineOp 的收回、QR 上限與整數像素、SecureScreen fallback、剪貼簿、gate、記錄。原始碼對照的是 `C:/src/Batman-329pr5`（main 2e18de6，工作樹只改了 QrScanActivity.kt）。基準（219、join2 v6.1、remove-member v6.5、254-app-qr、舊控制台函式、Rust、PR 3/4 機制）只拿來對照，沒有重審。

結論：0 BLOCKER / 1 MAJOR / 8 MINOR。**APPROVE-WITH-CHANGES**

---

## 前幾輪 MAJOR 是否已關（對過原始碼）

- **O-M1 / P-M2（剪貼簿）**：已關。`clearClip` 一律清（照 nodes.dart:728-732 `_takeClipboard`），`clearOwnClip` 只在按鈕與離開提醒用。兩條都有負對照（計畫 :133-135）。
- **P-M1（隊員端的「已是新密碼」）**：**只關了 8.5 這一頁**，其他隊員送出的路沒關，見 R-M1。
- **G-M1 / H-M1（提示在 dispose 之後才算）**：設計上已關。prober.dart:122-127 的 answer 那一步握著 `session`，清理在 :188-205，只在 `result.future` 完成之後才做。提示在 `done` 之前 await，這段期間 `cancelled`（:83）仍可能觸發 `done`，再進入清理，所以 `cleaning` 旗標是必要的；計畫已有（:216-219）。
- **K-M1、L-M1、M-M1、I-M1、J-M1、F-M1、E-M1/E-M2、D-M1/D-M2、C-M1/C-M2、A-M1..A-M3**：抽查文字，與原始碼相符，沒有回歸。

---

## MAJOR

### R-M1：P-M1 的修法只套在 8.5；隊員實際最常用的送出路徑（節點頁「更多」與提示卡）仍然只顯示「已是新密碼」，被移除的人可以繼續連上隊員的節點，沒有人發現

**場景**（隊長 L、留下的隊員 Y、被移除的 X）：
1. L 移除 X，網路從第 4 版變成第 5 版。L 用訊息把 Y 的更新包傳過去，但訊息沒送到（或 Y 沒注意到）。
2. L 打電話給 Y：「把新密碼送給你的節點」。Y 打開節點頁 →「更多」→「把新密碼送給節點」。
3. Y 的手機 mnet 和節點都還是第 4 版。updflow 在 `k9 == cur` 時回 `AlreadyCurrent`（batman-proto updflow.rs:254-257），畫面上的 Rust 原句是「[UPDATED] 節點 …xxxx 已是新密碼」（bridge rekey.rs:438）。
4. Y 回報「已經是新密碼了」。Y 的節點留在第 4 版的 SAE，而 X 知道這個密碼，所以 X 仍然連得上 Y 的節點。L 看不到隊員的節點（T15），這件事沒有人會發現。

這就是 P-M1 說的那個情形（「已是新密碼」只代表和這支手機一樣），但它出現在 8.5 以外的入口。

**證據**：
- 計畫 :388 規定 `kRekeyDoneRule` 用在 8.4 與「**隊長**在節點頁『更多』的結果」；:427 規定 `kMemberRekeyRule` 只用在 8.5；:428-429 的「只有這一頁剛匯入成功才打勾」也只在 8.5。隊員從 :469「更多」或 :461 提示卡的按鈕送出時，要顯示哪一段固定文字、能不能打勾，計畫都沒有規定。照 :469「照舊 `_sendUpdate`」，結果就只剩 Rust 的原句。
- 隊員其實會被 Rust 的匯入原句**引導到這條路**：`member_update_import` 的 detail 是「等隊長說大家都拿到更新包了，再到狀態頁按『把新密碼送給節點』」（bridge rekey.rs:410）。計畫 :386 又寫明「狀態頁就是那台的節點頁」。所以隊員最常走的是節點頁，而不是 8.5 同一頁的「送到節點」。
- 會擋住這種情形的提示卡也不會出現：隊員端的提示只在 `k9 < m.version` 時出現（rekey.rs:466、:472-474），而節點與手機都停在第 4 版。

**修法**：
1. 隊員端**每一個**送出結果都用 `kMemberRekeyRule`：8.5、節點頁「更多」、提示卡按鈕。提示卡在隊員手機上出現時也一樣。打勾仍然只在 8.5 剛匯入之後。
2. 在 2.7「更多」那一項明寫：隊長用 `kRekeyDoneRule`，隊員用 `kMemberRekeyRule`。
3. 版本號 N 的來源見 R-m1。沒有 N 時，改用不帶版本號的句子：「節點和這支手機的版本一樣。請和隊長確認你已經匯入他最新的更新包；沒收到就請他再傳一次。」
4. 測試與負對照：mnet 停在第 4 版、在節點頁「更多」送出、回 `AlreadyCurrent` → 畫面上有 `kMemberRekeyRule` 而且沒有勾 → PASS；改成只顯示 Rust 原句 → FAIL。

---

## MINOR

### R-m1：`kMemberRekeyRule` 的「第 N 版」只有 Advance 的時候拿得到
- 計畫 :427 寫「N 取自 Rust 的匯入原句（rekey.rs:400 的『更新到第 {to} 版』）」。但這句是 `member_update_prepare` 在 **Advance** 時才給的 detail（bridge rekey.rs:400）。
- AddSecrets 的 detail 是「補上另一台節點的新密碼」（:401），裡面沒有版本號。`member_update_import` 的 detail（:410）也沒有。
- `MnetView` 也沒有版本欄位（member.rs:302-309），而 Rust 入口凍結，不能加。
- 另外，解析給人看的句子來拿數字，等於把一段顯示文字當成介面，格式一改就壞。
- 修法：
  - 只在 Advance 時從 `prepare` 的 detail 取 N，用嚴格的正規式；解析不到就用 R-M1 第 3 點那句不帶版本號的句子。
  - 在 3.2 契約表登記這個「顯示文字當介面」的依賴，附 Rust 測試的句子當作固定樣本。

### R-m2：收回後待辦的句子，計畫兩處寫法互相矛盾，也和現有程式對不上
- 計畫 :272 一邊說 `revoke(todo:)` 直接帶入整句，一邊又說「home_page.dart:304 加一個依種類選句子的分支」。可是 `unsavedTodos` 是 `List<String>`，沒有種類欄位（lease.dart:126、:144）。
- 現在的待辦卡，`title` 是那個字串，而 `text` 固定寫「請到那台節點的頁面看目前的狀態」（home_page.dart:305-307）。只改 title 的話，不碰節點的操作在內文裡還是會叫使用者「到那台節點的頁面」。
- 修法擇一，並把另一種寫法刪掉：
  - 待辦改存 `(title, text)`；或
  - 內文改成中性的句子。

### R-m3：收回後對「移除」的判斷，殘留舊的寬鬆寫法
- :277 寫的是 N-m1 的規則：「名單裡已經沒有這個人，**而且**網路版本加了 1」。
- :285 卻還留著 v6 的句子：「移除：版本變了就顯示『已經移除』」。
- :286 的測試「寫入在收回之前落地 → 頁面顯示『已經完成』」沒有說是哪一種操作，和 :279「邀請、同意不能期待『已經完成』」衝突。
- 移除的結果直接決定隊長會不會進 8.4 換密碼，所以一定只能留一個規則。修法：刪掉 :285，並把 :286 的測試指定為「移除」與「匯入」。

### R-m4：入口條件的舊文字（第七輪說過要全文 grep）
- 3.3「首次安裝 / 啟動：沒有紀錄時入口不出現」，和 2.8.1、T-P5-E 的「『隊伍與邀請』每一列都一直在」矛盾。
- 3.3「設定頁的『隊員』」是 O-m2 已經併掉的那一列。
- 2.7 :448 與 :473 要求入口節點 `nodeState == 1`，:451（O-m6）卻說隊員那一支不看 nodeState。照 :473 實作的話，`PersistFailed{applied:true}` 之後，節點頁上 Rust 叫使用者按的那顆「加入網路」不會出現。「隊伍與邀請」還有一條路，所以不是死路，但文字要統一。
- 修法：
  - :473 改成「`nodeState == 1 && netFiles > 0`，或者這台是某個 mnet 的入口節點」；
  - 3.3 那兩列改成目前的規則。

### R-m5：整數像素的 QR，原點也要對齊實體像素，測試才鎖得住
- 計畫 :147 定了格寬取整數，但「QR 置中」的原點在邏輯像素下可能落在半個實體像素上。這時每一格的邊還是會被抗鋸齒，模組邊緣灰掉。這正是 P-m7 想避免的情形。
- 「讀回點陣逐格比對」如果只取每格的中心點，原點偏了也照樣 PASS，就不是有效的負對照。
- 另外，可用寬度小於 `size + 8` 個實體像素時，格寬會是 0，結果什麼都不畫（例如分割畫面）。
- 修法：
  - 原點取整到實體像素；
  - 測試檢查每一格的**全部**像素都是純黑或純白，負對照是原點加 0.5 px → FAIL；
  - 格寬 < 1（或 < 2）時，當成「無法用 QR 顯示」，顯示原因句。

### R-m6：一頁裡有兩個 SecureScreen，各自的 fallback 不同
- 7.9 同時有申請碼的 `CodeView`（整頁 SecureScreen，fallback 不顯示 QR）和確認碼（D6 的 fallback 是照樣顯示確認碼）。
- `SecureScreen` 用靜態計數 `_held`，旗標本身沒有問題（secure_screen.dart:21、:27、:37）。問題是：如果整頁只包一層 SecureScreen，設不了旗標時只會走一種 fallback，要嘛 QR 被顯示，要嘛確認碼被藏起來。
- 修法：明寫 7.9 的 QR 與確認碼各自包一層 `SecureScreen`，各用各的 fallback；widget 測試在「設不了」時斷言：沒有 QR、確認碼仍在。

### R-m7：收回後判定「已經匯入同意」時，mpend 可能留下
- 匯入同意的 `work` 是先寫 mnet、再刪 mpend。如果收回發生在兩者之間，mnet 已經落地，刪 mpend 則被 `RecordWriter` 拒絕（record_writer.dart:27-31）。
- 依 :280 的規則，頁面會判定「已經匯入」，但 mpend 還在。待辦有 A-m6 擋住，不會誤顯示。可是「再顯示申請」/ 7.9 仍然會列出它，而且頁面沒有說明接下來要做什麼（例如是否接著進「加入網路」）。
- 修法：判定「已經匯入」時，在新的佔用裡補刪 mpend，再進加入步驟；加一條白箱測試。

### R-m8：剪貼簿雜項（不影響安全）
- `clearOwnClip` 記的雜湊放在 Kotlin 記憶體裡。Activity 被重建後，雜湊就不在了，即使剪貼簿裡還是我們的碼，也會回「清除失敗」。
- 建議：沒有雜湊時，回一個固定代碼 `noRecord`，畫面說「剪貼簿裡可能還有剛才的碼，請手動清除」，和「讀不到剪貼簿」分開。

---

## 逐項確認過、沒有問題的

- **提示（2.3）**：
  - 被入侵的節點只能讓手機打開 `net/<hex>` 或 `mnet/<hex>`，結果只影響顯示（§5）。
  - 8.4 / 8.5 不把「提示卡不見」當成換好，有 `kRekeyDoneRule` 的文字與負對照。
  - field 版不會打開紀錄（devTrust 條件）。
  - `catchError` 會記 `$e`（prober.dart:174-175）。計畫在本地接住、只記 `runtimeType`，必須做到，T-P5-L 會攔。
- **8.4（隊長）**：
  - `AlreadyCurrent` / `Updated` 都和隊長手機的 net 紀錄版本比（updflow.rs:254-258、:317）。隊長的手機是這筆紀錄唯一的寫入者，所以隊長端把它當正向信號是對的。
  - 名單來自紀錄；送出前比對 `infoNetId`、後四碼與 `dacHash`。
  - 讀不到的節點照樣列出。
- **OfflineOp 收回**：
  - `_revoke` 會設 `_ended`、換 token（lease.dart:140-149）。`RecordWriter._check` 用 `identical(reg.current, l)` 拒絕（record_writer.dart:27-31），所以收回之後的寫入一律不落地（fail-closed）。
  - 已經通過檢查的那一次 `writeCas` 可能落地，計畫已經改說「結果不明」。
  - 之後 `release()` 因為 `_ended` 而什麼都不做，沒有重複釋放。
  - Keystore 不需要使用者驗證（keystore/*.kt 沒有 `UserAuthentication`），所以 60 s 不會在等指紋時誤收回。
- **QR 上限**：
  - 用編碼器給的版本判斷，加上 `size` 與 `bits` 的一致性檢查；超過 4096 字元就回錯誤，「複製文字」照樣可用（fail-safe）。
  - `from_hex` 接受大寫與空白（invite.rs:75-81）。
- **SecureScreen**：
  - 平台錯誤時是 `false`（secure_screen.dart:31），不會在沒有旗標時顯示 QR。
  - 沒給 `fallback` 的頁面行為不變，有新測試鎖住。
- **gate**：
  - `request_send_update` 沒有 `dev_gate`（owner.rs:1041），只靠 Dart 一層，T-S5 已涵蓋。
  - `request_joinreq` 與 `request_member_join` 有 `dev_gate`（owner.rs:1255、:1284）。
- **記錄**：
  - `OwnerConsole` 只記 `rel` 的前 12 個字元與 `runtimeType`（owner_console.dart:291、:305）。
  - 操作名稱是常數。
  - Kotlin 有原始碼檢查。

## 判定

**APPROVE-WITH-CHANGES**：R-M1 改完（隊員端所有送出結果都用 `kMemberRekeyRule`，並加負對照）就可以進實作。MINOR 可在實作時一起處理。
