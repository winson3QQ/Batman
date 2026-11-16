# #329 PR 3 實作計畫 v13 審查（審查者 Y，獨立）

對象：`docs/design/329-pr3-plan.md` v13 @ 7d7aa9a。範圍照指示：(1) v12 審查 W、X 每一項在 v13 是否修好；(2) v13 新增的 §2.3 `ConsoleReply` 契約、§2.5 `NetRunPage` 單一 route、§2.8 建立交接、D9 / D10、§6 有沒有新洞或跨節矛盾；(3) 從現場出發，不提重新決定 join2 的新機制。join2 與舊控制台（nodes.dart、owner.rs、netrec.rs、flow.rs）是基準，疑問放「基準備註」。只讀原始碼，沒有跑。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 0 MAJOR / 5 MINOR / 4 nit）

v12 的三個 MAJOR 都修好：`ConsoleReply` 讓頁面不再看到 `[ANSWER] ` 前綴、`persistedRel` 只在寫入成功後設；迴圈與結果是同一個 route，結果畫面出現時佔用還在，§6 有用真 `Navigator` 的改壞對照。剩下的都是 v13 改動留下的文字對不齊：acquire 移到 `NetRunPage.initState` 之後，「開始被拒 / 快照不同」的畫面沒有主人（Y-m1）；§2.5 的 `rel` 還寫成步驟帶來的那個（Y-m3）；`ConsoleReply` 有幾條舊路徑沒有對到 kind（Y-m4）；「寫入失敗 → 頁面重登再送一次」在 PR 3 用到的請求裡，舊控制台其實從來不會做（Y-m5）。都不會損壞紀錄（方向 fail-closed 或只是多問一次），各一句話修。

---

## 1. v12 發現的對應

| 發現 | 結果 | v13 位置 | 證據 |
|---|---|---|---|
| W-M1 / X-M2 結果頁另開 route 放掉佔用 | ✅（附 Y-m1、Y-m2） | §2.5:114、§3.1:172、§6:227 | 同一個 route、`initState` acquire、`dispose` `pageGone`；結果階段 hold 已放、`_busy == 0`，佔用要到 dispose 才釋放（lease.dart:73-78）✅。借用頁 `hold()` 在佔用有效時才成功（lease.dart:60-61），結果階段佔用仍有效 ✅。改壞對照「結果另開 route → FAIL」✅。入口頁改聽 `NetIndex`（§2.6:127），不靠 `await push`：`_back` 現在會在 `pushReplacement` 時就跑（home_page.dart:153-158），只做 `setPage(Page.home)` + `_todos()`，佔用中沒有讀取，無害 ✅。§3.1:167 還寫「多台迴圈 + 它的結果頁」（兩個名字），nit Y-n1 |
| W-m1 `[ANSWER] ` 前綴 | ✅ | §2.3:64-75 | 舊步驟迴圈 `a.complete('[ANSWER] ${st.detail}')`（nodes.dart:303、:324）；v13 `text` = Rust `detail` 原樣、判斷 `kind == answer && startsWith('[NET_STATE] ')`。Dart 的 `_makeUnclear`（nodes.dart:50）是 `unclear` kind，不會被當成回答 ✅。改壞對照 :75 ✅ |
| W-m2 / X m4 D9 說法 | ⚠️（Y-m1） | D9:210、§2.8:159 | 改成「被拒、再按一次」，和 `NodeLink.acquire` 第一行 `if (reg.current != null) return null;`（node_link.dart:153）一致 ✅。但 v13 把 acquire 移到 `NetRunPage.initState`：被拒時 4.1 已經被 `pushReplacement` 換掉，沒有「開始」可以再按 → Y-m1。W-m2 要的改壞對照（pop 後立刻開始 → 顯示「另一個操作還在進行」）§6 沒有 |
| W-m3 內部重送也重新登入 | ✅（附 Y-m5） | §2.3:74 | `ask` 不自己登入（舊 :522 會），寫入失敗 → `close()` + `notSent` → 頁面 `loginFor` 再送，選 W 的第一種修法 ✅。但「次數同舊控制台：一次」對 PR 3 的請求不成立 → Y-m5 |
| W-m4 「有 `rel`」= 寫成功 | ⚠️（Y-m3） | §2.3:70、§2.5:116-117 | 契約與結果頁改成 `persistedRel` ✅；§2.5:97「`rel` 取自 `PersistNet` 步驟的 `OwnerStep.rel`」與 :107-108「沒有 `PersistNet`（拿不到 `rel`）/ 有 `rel` → 重讀那一筆」沒跟著改 → Y-m3 |
| W-m5 打不開的單筆 | ✅ | §2.8:141 | 同 `NetIndex` 函式、同規則；和舊 `_pickNet` 跳過一致（nodes.dart:597-605）✅ |
| W-m6 / X m1 15 s | ✅ | §2.8:144、D10:211 | §2.8 已改 15 s；D10 列出和設計 :738（60 s）不同，照 `_ask` 預設（nodes.dart:511-513）與 `_confirmNetwork` 不帶 `wait`（:1244）✅ |
| W-n1 | ✅ | §3.1:172、§6 | `keepScreenOn` 寫入者 = `NetRunPage`（含再試）；§6「再試中返回被擋」✅ |
| W-n2 | ✅ | §2.5:108 | ble_gate.dart:226-231、nodes.dart:511-513 ✅ |
| W-n3 | ✅ | §2.5:117 | 「之後照迴圈的建立規則（含自動檢查一次）」✅ |
| W-n4 | ✅ | §6:227 | 「自己拿佔用時 `NetIndex` 計算中也能檢查」✅ |
| X-M1 `OwnerConsole` 回傳契約 | ✅（附 Y-m4） | §2.3:64-76 | kind / text / `persistedRel` / 旗標 ✅。X 列的 `removedQ` 旗標沒有收、`NOT_LOGGED_IN` 怎麼用 kind 表達沒寫、幾條舊路徑沒有對應的 kind → Y-m4 |
| X m2 `[JOINED] ` 開頭 | ✅ | §2.3:73、§6 | P8:34 與 §2.5:109 仍只寫「`[JOINED]` = 成功」，但 §2.3「判斷只在頁面做、只看這個型別」覆蓋它；§6 有「加入成功只認開頭」✅ |
| X m3 沒有 pending | ✅ | §2.8:141 | 「沒有需要檢查的網路」+「完成」，不給建立 ✅ |
| X m5 對話框開著時頁面消失 | ⚠️ | §2.5:115 | 規則寫了（照舊控制台 nodes.dart:278-291 的 `mounted ? showDialog : false`）✅；X 要求的 T-M1(g) 測試 §6 沒列 → nit Y-n2 |
| X m6 開始時比對什麼 | ⚠️（Y-m1） | §2.4:92 | 比對內容寫明 ✅；「畫面換成新的快照請使用者再確認」的畫面在 v13 已經不存在（4.1 被換掉）→ Y-m1 |
| X m7 `NetIndex` 通知 | ✅ | §2.6:127 | ✅（見 Y-n3：每次重算都要通知） |
| X m8 結果列更新 | ✅ | §2.5:115 | ✅ |
| X m9 舊 pending 的「檢查網路」 | ✅ | §8:239 | 寫進限制與 #329 checklist ✅ |

---

## 2. MINOR

### Y-m1　acquire 移到 `NetRunPage.initState` 之後，「開始被拒」與「快照不同」的畫面沒有主人；D9 的「再按一次」做不到

- **情境（現場）**：(a) 檢查網路頁（借用）→「建立網路」→ `NetRunPage` `pushReplacement(4.1)`；舊 `NetRunPage` 要等 4.1 的進場動畫結束才 dispose（D9 自己的前提）。這段時間按 4.1 的「開始」→ `pushReplacement(NetRunPage)` → 新 route 的 `initState` acquire → `reg.current != null` → null（node_link.dart:153）。這時 4.1 已經被換掉，D9:210 / §2.8:159 說的「再按一次即可」沒有按鈕可按。使用者只能返回入口頁、重開 4.1、重新填名稱和勾選。(b) §2.4:92「按『開始』時在佔用下重新列一次檔，和 4.1 的快照比，不同 → 不開始，畫面換成新的快照請使用者再確認」：v13 裡重新列檔的地方是 `NetRunPage`（acquire 之後），4.1 已經 dispose，「再確認」的表單不存在。
- **證據**：plan §2.5:100、:114（acquire 在 `NetRunPage.initState`、4.1 `pushReplacement`）；§2.4:92；D9:210；node_link.dart:152-163；lease.dart:124-129。
- **為什麼只是 MINOR**：兩條都很少碰到（a 要在約 300 ms 內按下；b 要在 4.1 開著時紀錄被別處改），結果是 fail-closed（不開始、不寫），沒有資料風險。但這是 v13 改動造成的跨節矛盾，照字面寫不出來。
- **修法（一句話，不加機制）**：§2.5 寫明「`NetRunPage` acquire 被拒或快照不同 → 先 `release()`（有拿到時）→ `pushReplacement(4.1)` 並帶回原本填的值（快照不同時用新快照），4.1 顯示原因」；D9 改成「被拒時回到 4.1、表單保留，再按一次」。另外可選：`NetRunPage` / 自己拿佔用的檢查網路頁在 `pushReplacement(4.1)` **之前**自己 `release()`（同一個擁有者，之後 dispose 的 `pageGone` 是空操作，lease.dart:74、:86），D9 的空檔就不存在；這不是新機制，只是同一個擁有者提早呼叫自己的 release。
- **負向對照**：真 `Navigator`，pop 後不 `pumpAndSettle` 立刻按開始 → 斷言回到 4.1、名稱與勾選還在、顯示「另一個操作還在進行」；改壞 = 停在空的 `NetRunPage` → FAIL。快照不同那條同樣斷言回到 4.1。

### Y-m2　自己拿佔用、從 4.1 進來的檢查網路頁按「建立網路」→ 堆疊裡會有兩個 4.1

- **情境**：首頁第 6 列「加入網路」→ 4.1（加入）→ 選到 pending →「檢查網路」（push，自己拿佔用）→ 拿到回答、沒升級、全部 pending →「建立網路」→ §2.8:157 `pushReplacement(4.1 建立模式)`。堆疊 = [首頁, 4.1 加入, 4.1 建立]。建網跑完、離開 `NetRunPage` 後回到的是**舊的 4.1 加入表單**（快照過期，§2.4:92 會擋住開始），不是 §2.5:114 說的「回到入口頁」。
- **證據**：plan §2.8:157；§2.5:114；X-M2 的建議「自己拿佔用、從 4.1 進來的檢查網路頁：pop『去建立』給 4.1，4.1 自己切到建立模式」v13 沒採用。
- **影響**：沒有資料風險（4.1 不持有佔用、開始時會比對快照），只是使用者多一層返回、看到過期的表單。
- **修法**：§2.8:157 分兩種來源：從 4.1 進來 → pop「去建立」給 4.1，4.1 切到建立模式（同一頁）；從節點頁進來 → `pushReplacement(4.1 建立模式)`（現寫法）。
- **負向對照**：真 `Navigator`，4.1 → 檢查網路 → 建立 → 開始 → 結束 → 返回，斷言回到入口頁；改壞 = 一律 `pushReplacement` → 回到舊 4.1 → FAIL。

### Y-m3　§2.5 的 `rel` 還是 `PersistNet` 步驟帶來的那個，和 §2.3 `persistedRel` 不一致（W-m4 只修了一半）

- **證據**：§2.5:97「`rel` 取自那一台建立時 `PersistNet` 步驟的 `OwnerStep.rel`」；:107「沒有 `PersistNet`（拿不到 `rel`）→ 整個流程停」；:108「有 `rel` → 在佔用下重讀那一筆…不是 → 自動檢查一次」。舊步驟迴圈在寫之前就 `_track.persisted()`，寫失敗走 `persistFailed`（nodes.dart:255-272），Rust 在 `applied == false` 時回 `[REQ_FAIL] 建立網路沒有成功`（owner.rs:1146-1151，W 已驗）。
- **情境**：seal 失敗（金鑰被系統作廢）或空間滿 → 步驟有 `rel`、磁碟沒有紀錄 → 照 §2.5:108 重讀「不是已建立」（其實是讀不到）→ 自動檢查要 `confirmNetwork(rel)`，但沒有紀錄可讀（`_readRecord` 回 null，nodes.dart:738-745）→ 這一步沒有定義。結果頁照 §2.5:116 看 `persistedRel`（null）會給「再試這一台」，兩節對同一台的判斷不同。
- **修法**：§2.5:97、:107、:108 的「`rel`」一律改成「`persistedRel`」（§2.3 的定義）；其餘台加入用的也是 `persistedRel`。
- **負向對照**：§6 已有「`persistedRel` 只在寫入成功後設」；補一條迴圈層的：`writeCas` 拋錯 → 自動檢查 0 次、迴圈停、結果列「再試這一台」；改壞 = 迴圈用步驟的 `rel` → 自動檢查被呼叫 → FAIL。

### Y-m4　`ConsoleReply` 沒有對到的舊路徑：被移除過的問題、`retry: false` 的連線寫入錯誤、自動檢查的觸發條件

舊 `_ask` 與步驟迴圈的每一條結束路徑，對到 v13 kind 的結果（nodes.dart:194-340、:507-589）：

| 舊路徑 | 舊字串 | v13 kind |
|---|---|---|
| `OwnerKind.answer` | `[ANSWER] detail`（:324） | `answer` ✅ |
| `ended` | `endedLine(detail)`（:335，member_ui.dart:283） | `ended` ✅ |
| 逾時 / 斷線，有 `unclear`（建立 / 加入 / 送新密碼） | `_track.unclearNow`：寫過 → unclear 句、沒寫 → `notSentLine`（:436，member_ui.dart:309） | `unclear` / `notSent` ✅（以 `SendTrack.wrote` 分，不是以 `persistedRel` 分，兩者不同步，見下） |
| 逾時，沒有 `unclear`（確認、連線檢查） | `_waitLine` `[REQ_FAIL] 15 秒內節點沒有回應`（:530-531） | `unclear`（表上寫「Rust 的結果不明句子」，實際是 Dart 的句子；nit） |
| Rust `Err(String)` | rethrow → `[REQ_FAIL] 操作沒有成功：…`（:543、:580） | `refused` ✅ |
| 沒有 session | `askNoLink`（:525） | 推論為 `notSent`（表沒寫） |
| **連線寫入拋非字串錯誤、`retry: false`、沒有 `unclear`**（確認、連線檢查） | `if (!retry) rethrow` → `[REQ_FAIL] 操作沒有成功：Exception`（:554、:580） | **沒有對應**：不是 Rust 的 `Err(String)`，表上 `refused` 的定義不涵蓋；可能已部分送出，不能算 `notSent` |
| **`confirmRemoved`** | `[ANSWER] detail` + `_removedQ`（:299-303）；呼叫者問人、不要 → `_say('[JOIN_STATE] 已取消：沒有寫入、沒有送出')`（:658）；要 → 重讀紀錄（讀不到時靜默 return，:661-662）→ 再送 | **沒有對應**：§2.3 說注入對話框，但 `joinNetwork(rel)` 最後回哪一個 reply（第一次的 `confirmRemoved` 答案？取消句？第二次的答案？重讀失敗？）沒寫；X-M1 列的 `removedQ` 旗標也沒收 |

- **影響**：§2.5 / §2.8 對「不是 `answer`」的處理都是 fail-closed（停、問繼續、整頁停），所以這些缺口不會造成誤判成功；但實作者要自己決定 kind，§6 的表格驅動測試（§2.3:78）也沒有這幾列。另外 §2.5:108 的「回 `NOT_LOGGED_IN` 或連線已斷 → 先 close 再 `loginFor`」沒有用 kind 寫：舊 `_ask` 在 `unclear` / `notSent` / 逾時 / `ended` 都會 `_drop()`（:335、:571-572），所以建立回來不是 `answer` 時 session 幾乎一定已經沒了，下一個 `confirmNetwork` 在 v13 會回「沒有 session」（`notSent`），不是 Rust 的 `NOT_LOGGED_IN`。
- **修法（只寫下來，不加機制）**：§2.3 表加三列——(1) 連線寫入拋非字串錯誤 → `unclear`（可能已送出；同舊控制台 drop）；(2) 沒有 session → `notSent`；(3) `joinNetwork` 的被移除過：頁面看到的是**最後一次**請求的 reply，使用者選「不要」→ `notSent`、text = 舊的取消句，重讀失敗 → `notSent`、text = 舊控制台同一句。§2.5:108 改成「建立的 reply 不是 `answer`，或確認回 `refused(NOT_LOGGED_IN)` / `notSent` → close → `loginFor` 一次」。
- **負向對照**：表格驅動測試加這三列（假 `OwnerSession` 產生對應步驟 / 拋錯）；改壞 = 把非字串錯誤歸成 `refused` 或 `answer` → 斷言 FAIL。

### Y-m5　「寫入失敗 → 頁面重登再送一次（次數同舊控制台）」：PR 3 用到的請求在舊控制台從來不會重送

- **證據**：舊 `_ask` 只有在 `retry == true` **而且** `unclear == null` 時才重新登入重送（nodes.dart:547-566：先看 `unclear`，再 `if (!retry) rethrow`）。`OwnerConsole` 要複製的請求：建立 `unclear: _makeUnclear`（:486-490）→ 走 `unclear` 分支、不重送；加入 `retry: false`（:647）；確認 `retry: false`（:1244）；送新密碼 `retry: false`（:1581）；連線檢查 `retry: false`（:703）。所以在這組請求裡，「重送一次」在舊控制台是**死路徑**。
- **情境**：v13 §2.3:74 把它寫成「回 `notSent`，由頁面 `loginFor` 後再送一次」。但 `notSent` 同時也是建立 / 加入「寫入前斷線」的 kind（`notSentLine`）。實作者照字面寫成「看到 `notSent` 就重登再送」→ 迴圈裡建立 / 加入斷線（寫入前）會自動多一次 60 s 登入 + 重送，舊控制台是顯示「連線失敗，還沒有寫入或送出，請重試」由人決定；而 §2.5:112 又說「其他（結果不明句子、登入失敗）→ 問繼續 / 停」。兩節對同一個 kind 給了兩種處理。重送本身是安全的（`SendTrack.wrote == false` 表示沒有紀錄、沒有 `sent` 步驟，member_ui.dart:292-309），所以不是 MAJOR，但它是沒列進 §4 的行為差異。
- **修法（擇一寫死）**：(a) 刪掉「由頁面重登再送一次」，`notSent` 照 §2.5:112 問繼續 / 停、結果列「再試這一台」（和舊控制台一致）；或 (b) 保留，但寫明只用於哪些請求，並列進 §4 成 D11。建議 (a)：照基準、少一條路徑。
- **負向對照**：(a) 時：假 session 在建立的第一個 `sent` 步驟前斷線 → 斷言 `loginFor` 只被呼叫一次、畫面問繼續 / 停；改壞 = 自動重送 → `loginFor` 兩次 → FAIL。

---

## 3. nit

- **Y-n1**　§3.1:167 的 `pageGone` / `release` 呼叫者寫成「多台迴圈 + 它的結果頁」，改成「`NetRunPage`（含結果階段）」，和 §2.5:114、§3.1:172 一致。
- **Y-n2**　§6 補 X m5 的測試：國家問題對話框開著時頁面消失 → 回答「不要」→ 沒有寫入（照 nodes.dart:278-291）；改壞 = 等對話框 → FAIL。
- **Y-n3**　§2.6:127 寫明「每次重算完成都通知（內容沒變也通知）」：首頁的「上一個操作可能沒有存完」來自 `reg.unsavedTodos`（home_page.dart:216、:264），v13 之後首頁的 `_back` 會在迴圈**開始**時就跑完，佔用被收回後首頁要靠 `released` → `NetIndex` 重算的通知才會重畫出這一列。
- **Y-n4**　§2.3 表 `unclear` 的說明「Rust 的結果不明句子」：`_makeUnclear` / `_joinUnclear` / `_waitLine` 都是 Dart 的句子（nodes.dart:49-50、:531），改成「舊控制台同一句」。另外 `unclear` / `notSent` 依 `SendTrack.wrote`（寫之前就設，nodes.dart:256），`persistedRel` 依寫入成功；seal 失敗後又斷線會是「`unclear` + 沒有 `persistedRel`」——結果列給「再試這一台」（照 `persistedRel`，對），但句子說「稍後檢查網路」。寫一句「結果列的按鈕只看 `persistedRel`」即可。

---

## 4. v13 改動的其他檢查（沒有發現）

- **`NetRunPage` 單一 route 與 Flutter**：`pushReplacement` 讓 4.1 被換掉、入口頁的 `push` future 提早完成（X 已對 navigator.dart:2383-2386 驗證）；v13 不再依賴它 ✅。4.1 不持有佔用，被 dispose 無妨 ✅。`initState` 裡的 acquire 是非同步（node_link.dart:152-163 `await _dropAll()`，加上 §2.1 等 `released` 讀紀錄 ≤ 5 s）；acquire 回來時 route 已 dispose → 立刻 `release()`（§2.5:100）✅。借用的檢查網路頁在 `NetRunPage` 上面，`NetRunPage` 不會在它之下被 dispose（只有系統殺 process，那時整個 app 都沒了）✅。
- **§2.8 借用頁建立交接**：借用頁 `close()` → 放 hold → pop「去建立」→ `NetRunPage` `pushReplacement(4.1)` → dispose → `pageGone`，`_busy == 0` → 立刻釋放 ✅（另見 Y-m1 的空檔）。
- **`ConsoleReply` 與被入侵的節點**：頁面只看 `kind == answer` 的開頭；`answer` 的 `detail` 由 Rust 組；節點只能把字串放進錯誤句子中間（owner.rs:645-650，W / X 已驗）；`ended` 的 detail 若以 `[` 開頭會原樣回（member_ui.dart:283），但 kind 是 `ended`，不會被當成回答 ✅。本機非特權程序：沒有新的平台方法、匯出元件或檔案路徑（§5）✅。
- **晚到的回答**：舊控制台在等待結束後仍把回答顯示出來（nodes.dart:328-330）；新頁面沒有 `_say`。但逾時 / 結果不明都會先 `_drop()`（:571-572），晚到的回答幾乎收不到；就算確認的 `Upgraded` 晚到被寫進紀錄，頁面也是「沒拿到回答 → 再檢查一次」→ `Already` → 完成，fail-closed ✅（⚠️ 推論）。
- **D10**：15 s 與設計 :738 的 60 s 不同已列出 ✅。

## 5. 基準備註（不算發現）

- 舊 `_ask` 的 `_track.persisted()` 在寫之前就設（nodes.dart:256），所以寫失敗後再斷線會說「結果不明」，雖然什麼都沒送出；保守、屬基準。
- 確認請求 `retry: false`、沒有 `unclear`：斷線時要等滿 15 s 才結束（`_lost` 只在有 `unclear` 時完成答案，nodes.dart:430-441）；屬基準。
- W / X / V 的基準備註（`InProgress` / `Unknown` 給建立、pending 刪不掉、420 s 與被入侵節點拖時間）仍然成立。

## 6. 驗證分類

### ✅ 已驗證（原始碼 @ 7d7aa9a，唯讀）
- nodes.dart:49-55（Dart 的 unclear / notSent / `_linkUnknown` 句子）、:146-152（dispose）、:194-340（步驟迴圈：`[ANSWER] ` 前綴 :303 / :324、PersistNet 寫前 `persisted()` :255-272、國家對話框 `mounted ? … : false` :276-291、`confirmRemoved` :299-303、`ended` :331-337）、:343-362（inbox `onError` → `_endUnclear`）、:430-441（`_endUnclear` / `_lost`）、:486-490（建立帶 `unclear`）、:507-589（`_ask`：:522 自動登入、:543 字串 rethrow、:547 先看 `unclear`、:554 `retry: false` rethrow、:571-572 drop、:580 `操作沒有成功`）、:640-672（加入 `retry: false`、被移除過的流程）、:703（連線檢查 `retry: false`）、:738-745（`_readRecord`）、:1244（確認 `retry: false`）、:1581（送新密碼 `retry: false`）。
- member_ui.dart:167-168、:257、:283、:290-309（`SendTrack`）。
- lease.dart:42-150；node_link.dart:152-195；home_page.dart:153-158、:207-216、:264。
- 設計 329-app-uiux.md:725-750（§5.4 表、ConfirmRemoved「同意後重新開始這一台」、「不自動重送」）。

### ⚠️ 推論
- `pushReplacement` 的舊 route 在新 route 進場動畫結束後才 dispose：照 Flutter 的 route 生命週期與 D9 的前提，沒有在本 repo 對 Flutter 原始碼逐行核對（X 驗過 future 完成那一段）。
- Y-m1 / Y-m2 / Y-m5 的後果、§4 的晚到回答：照計畫文字與原始碼推論；新頁面與 `OwnerConsole` 尚未實作，沒有跑。

### ❌ 沒做
- 沒跑測試、沒上真機；沒重驗 v1–v11 的發現；沒審 PR 1 / PR 2 的基準實作；沒讀 join2 全文；沒查 owner.rs 對 `confirmRemoved` 之後第二次加入的 Rust 端處理。
