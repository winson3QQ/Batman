# #329 PR 3 實作計畫 v13 審查（審查者 Z，獨立）

對象：`docs/design/329-pr3-plan.md` v13 @ 7d7aa9a。角度：我是明天開始寫第 2–7 步的實作者。先讀完整份 §0–§9，再把九個現場情境走過新頁面，檢查每個畫面、按鈕、佔用呼叫（acquire / hold / pageGone / release）、`OwnerConsole` 呼叫與 `ConsoleReply` 的處理、紀錄寫入，是不是都能只靠計畫文字決定。基準（join2、舊控制台、owner.rs / netrec.rs / flow.rs）不重審，疑問放在「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 2 MAJOR / 8 MINOR）

v13 補上了 `ConsoleReply` 契約，也把迴圈和結果改成同一個 route，W-M1 / X-M1 / X-M2 的主要問題都解掉了。剩下兩個 MAJOR 都是 **v13 自己的修法和其他章節衝突**，不需要重新決定 join2：

- **Z-M1**：佔用改在 `NetRunPage.initState` 裡 `acquire`，而 4.1 在按「開始」時就被 `pushReplacement` 換掉。這樣 §2.4 的「開始時比對快照、不同就讓使用者在 4.1 重新確認」、D9 的「再按一次即可」、§3.2 的「開始」那一列，都沒有頁面可以執行。拿不到佔用時（例如認領頁按返回後還在跑的原始佔用）會發生什麼，計畫也沒有寫。
- **Z-M2**：§2.3 新寫的「寫入失敗 → `notSent` → 頁面重新登入、再送一次」在舊控制台裡從來不會發生在 PR 3 的任何一個請求上。這和設計 §5.4 的「不自動重送」以及 §2.5 的「問繼續 / 停」衝突。

---

## 1. MAJOR

### Z-M1　4.1 →`NetRunPage`：`acquire` 放在被換上來的 route 裡，§2.4 的快照比對、D9、拿不到佔用時的畫面都沒有地方放

- **情境**：
  - 情境 (a) 的變形：新增 04 時，認領頁在認領中按了返回（設計 :577 刻意不加 `PopScope`，F41）。這時原始佔用還在，最長可以撐 900 s（lease.dart:102）。使用者回首頁，按第 6 列「建立網路」→ 4.1 → 填名稱、勾 04 →「開始」。
  - D9：從檢查網路頁按「建立網路」→ 新的 4.1 →在退場動畫期間就按了「開始」。
  - §2.4:92：4.1 開著的時候，NetIndex 重算後網路紀錄變了。
- **計畫文字**：
  - §2.5:114：「按『開始』→ 4.1 `pushReplacement(NetRunPage)`（4.1 不持有佔用，被換掉無妨）……佔用在這個 route 的 `initState` 裡 `acquire`」。
  - §2.4:92：「按『開始』時在佔用下重新列一次檔，和 4.1 的快照比……不同 → 不開始，**畫面換成新的快照請使用者再確認**」。
  - D9 :210 / §2.8:159：「這段空檔內按 4.1 的『開始』會被拒……畫面說『另一個操作還在進行』，**再按一次即可**」。
- **矛盾**：
  1. 佔用要等 `NetRunPage` 的 `initState` 才拿得到，可是 4.1 這時已經被換掉了。「在佔用下重新列檔、和 4.1 的快照比」只能在 `NetRunPage` 裡做；比對不同時，「畫面換成新的快照」沒有 4.1 可以顯示。
  2. `NodeLink.acquire` 回 `null`（node_link.dart:153-154；lease.dart:124-125）時，「再按一次」的按鈕已經不在了。使用者只能返回，回到的是入口頁，填好的網路名稱、頻道、勾選全部丟失。`NetRunPage` 在這種情況要顯示什麼、怎麼離開，計畫沒有寫；§6 第 5 步也沒有對應的測試。
  3. 現有做法是先拿佔用再開頁：`openRawPage` 在 push **之前** `acquire`，拿不到就由還在畫面上的呼叫者顯示「另一個操作還在進行」（raw_use.dart:73-82，home_page.dart:47-61）。v13 的做法反過來，但沒有說明理由，也沒有列在 §4。
- **證據**：plan :92、:114、:159、:180、:210；raw_use.dart:73-82；node_link.dart:153-164；lease.dart:102、:124-125；設計 329-app-uiux.md:577（認領頁不加 `PopScope`、原始佔用撐到工作結束）。
- **修法（照 `openRawPage` 的現有做法，不加機制，擇一寫進 §2.5 / §3.1 / §3.2）**：
  - (a) **4.1 在畫面上的時候 `acquire`**：
    - 拿不到 → 4.1 顯示「另一個操作還在進行：<名稱>」，表單保留，D9 的「再按一次」成立。
    - 拿到 → 4.1 在佔用下重新列檔並比對快照。不同 → `release()`，4.1 換成新的快照。相同 → `pushReplacement(NetRunPage(lease))`，佔用交給 `NetRunPage`。
    - 擁有權寫明：交出之後 `NetRunPage` 是唯一的 `pageGone` 呼叫者，4.1 的 `dispose` 不碰佔用；4.1 在 `acquire` 回來之前就消失 → `release()`（raw_use.dart:75-78）。
  - (b) **`NetRunPage` 用 `push` 疊在 4.1 上面，不用 `pushReplacement`**：
    - `acquire` 失敗或快照不同 → `NetRunPage` pop 一個原因給 4.1，4.1 照原因顯示。
    - 離開結果頁 → pop「完成」，4.1 跟著 pop。
    - §2.8 借用路徑的「去建立」改成 pop 給 4.1，由 4.1 切到建立模式。

  建議用 (a)：和 `openRawPage` 一樣先拿再換頁，D9 的文字不用改。
- **改壞對照**：假的登記表先讓另一個佔用拿著 → 按「開始」→ 斷言 4.1 還在、表單的值都還在、出現「另一個操作還在進行」。改壞成在 `NetRunPage.initState` 裡 `acquire` → FAIL。另一條：快照不同 → 斷言 `reg.current == null`，而且 4.1 顯示新的快照。

### Z-M2　§2.3「寫入失敗 → 頁面重新登入、再送一次」在 PR 3 的請求上是新行為，和設計 §5.4 的「不自動重送」、§2.5 都衝突

- **計畫文字**：§2.3:74：「舊 `_ask` 的『寫入失敗 → 重新登入再送一次』改成 `OwnerConsole` 先 `close()` 自己的連線、回 `notSent`，由頁面 `loginFor` 後再送一次（次數同舊控制台：一次）」。§6 第 3 步也把「重送一次」列成測試項目。
- **原始碼的事實**：舊 `_ask` 的重送分支只有在 `unclear == null && retry == true` 時才會走到（nodes.dart:547-565：`unclear` 分支在前、`if (!retry) rethrow;` 在 :554）。PR 3 要複製的請求**全部**不會走到這個分支：
  - `makeNetwork`：`unclear: _makeUnclear`（nodes.dart:486-489）。寫入失敗 → `_unclearNow()`，也就是結果不明或 `_notSent`，然後 `return null`，不重送。
  - `joinNetwork`：`retry: false` 加上 `unclear: _joinUnclear`（:647-648）。
  - `confirmNetwork`：`retry: false`（:1244）。寫入失敗 → rethrow → `[REQ_FAIL] 操作沒有成功：…`（:581-584）。
  - `sendUpdateFor`：`retry: false` 加上 `unclear: _sendUnclear`（:1581）。
  - 連線檢查：`retry: false, held: true`（:703）。
- **衝突**：
  1. 設計 §5.4（329-app-uiux.md:750，另見 :842）寫明「**不自動重送**（現況如此）」。原句講的是結果不明，但舊控制台對這幾個請求連「什麼都沒送出」也不重送，所以「現況」就是完全不重送。
  2. §2.5:112 寫的是「其他（Rust 的拒絕或結果不明句子……）→ 顯示 Rust 的句子，問『繼續下一台 / 先停在這裡』」，沒有重送。
  3. 照 §2.3 的字面實作，`makeNetwork` 在 op/nonce 寫入失敗（SendTrack 還沒標成已送出 → `notSent`，member_ui.dart:297-309）時，頁面會**自動**再登入、再建立一次。這不在 D1–D10 裡，也和 §0「行為與句子和舊控制台相同」不一致。

  對現場的傷害不大：`notSent` 代表什麼都沒寫、也沒送出。問題是實作者要決定做不做、測試要鎖住哪一種行為，而設計和舊控制台都說不做。
- **修法（刪一句、補一句）**：
  - §2.3 改成：「PR 3 的請求在舊控制台都不走重送分支，`OwnerConsole` 不複製它。寫入失敗時，`makeNetwork` / `joinNetwork` / `sendUpdateFor` 照 `SendTrack` 回 `unclear` 或 `notSent`；`confirmNetwork` 回 `refused`（`[REQ_FAIL] 操作沒有成功：…`）。頁面不自動重送，下一步照 §2.5 / §2.8。」
  - §6 第 3 步的「重送一次」改成「寫入失敗 → 不重送」。
- **改壞對照**：假的 `GateLink.write` 在 op/nonce 丟錯 → 斷言 `requestMakeNetwork` 只被呼叫一次、`kind == notSent`、迴圈問繼續 / 停。改壞成頁面重登再送 → 呼叫兩次 → FAIL。

---

## 2. MINOR

**Z-m1　「有 net」沒有定義：是「任何 `net/` 紀錄」還是「已建立的 net」。**
- 現況：PR 2 的第 6 列只要有任何 `net/` 檔就給「加入網路」，pending 也算（home_page.dart:131-134）。設計 §5.3 也寫「任何 net 紀錄」（329-app-uiux.md:726）。§3.2:182 照這個規則寫（「建立中途 app 被殺 → 第 6 列『加入網路』」）。
- 問題：§2.4:89 的理由句寫「這和第 6 列『沒有 net → 建立』是同一條規則（pending 的網路還不能加入）」，讀起來像是 pending 不算 net。第 4 步要把第 6 列改用 `NetIndex`，而 `NetIndex` 有 `applied`，實作者很容易改成「沒有已建立的 net → 建立網路」，這就改了 PR 2 已審過的分流。
- 修法：在 §2.4 寫明「net」= 任何 `net/` 紀錄（含 pending），「已建立的 net」= `applied`。改壞對照：只有 pending → 第 6 列仍是「加入網路」。

**Z-m2　「session 還在」沒有對應的介面；判斷 `NOT_LOGGED_IN` 要比對 Rust 的中文字串。**
- §2.5:108 寫「session 還在就直接 `confirmNetwork`；回 `NOT_LOGGED_IN` 或連線已斷 → close → loginFor」。
- 但照抄的 `ask` 在 `unclear` / `notSent` 之後會 drop session（nodes.dart:571），回 `_waitLine` 之後也會（:572）。`ConsoleReply` 和 `OwnerConsole` 都沒有「session 還能不能用」這個值。`NOT_LOGGED_IN` 是 `refused` 裡的 Rust 中文字串（owner.rs:438、:1173-1175）。
- 修法：給 `OwnerConsole` 一個 `alive` 值（或在 `ConsoleReply` 加一個欄位）。規則寫成：`kind` 是 `unclear` / `notSent` / `ended`，或 `!alive`，或 `refused` 而且 `text == NOT_LOGGED_IN`（Dart 端用一個常數，測試對 Rust 的字串）→ 先 `close()` 再 `loginFor`；其他 `refused`（`NET_DAMAGED`、`ADDR_BUSY`…）→ 不重新登入，那一台停、顯示句子。

**Z-m3　「放棄這次加入」不登入，可是計畫把它放在 `OwnerConsole` 裡。**
- §6 第 3 步：「`OwnerConsole`（含 `_forgetJoining` 的複製）」。§2.2 的 `OwnerConsole` 是在交接（`LoginHandoff`）之後才存在的。舊 `_forgetJoiningBody` 不需要節點連線：只呼叫 `netForgetJoining`，再 seal + CAS（nodes.dart:1250-1295）。
- 修法：寫明它是不需要 session 的靜態函式，簽名類似 `forgetJoining(Lease, rel, dacHash) → ConsoleReply`，經 `RecordWriter` 寫入。

**Z-m4　結果頁同一時間只能做一件事，計畫沒有寫。**
- 「再試這一台」或「檢查網路」進行中時，其他列的按鈕要不要停用，計畫沒有寫。`BleGate` 一次只開一條連線（ble_gate.dart:228-231）；同時按兩列會讓兩個 `loginFor` / `OwnerConsole` 搶同一個佔用。舊控制台用 `_busy` 停用所有按鈕（nodes.dart:1730-1737）。
- 修法：寫一句「一列在做時，其他列的按鈕停用」，並加一條測試。

**Z-m5　`pageGone` 發生在 `loginFor` 進行中時，登入成功後要不要送建立 / 加入，沒有寫清楚。**
- §2.5:104 說「不開新的登入、自動檢查或下一台」，又說「剩下的只有當前那一個請求（≤ 60 s 登入**或** ≤ 360 s 建立）」，兩種讀法都說得通。
- 舊控制台：頁面不在了以後登入才成功 → `_drop()`，不送請求（nodes.dart:405-409、:518-520）。
- 修法：照舊控制台寫明「登入成功時頁面已不在 → `close()`，不送建立 / 加入」，並加一條測試。

**Z-m6　4.1 列出哪些節點、哪些可以勾，沒有定義。**
- §2.5:96 只說「剛認領的節點讀到後就能勾」，像是要先讀到才能勾。可是沒寫可勾的條件：是任何 `node/` 紀錄？還是要讀到、而且 `node_state == 1`？讀不到（離太遠、還在開機）的那台能不能勾？
- 這直接影響情境 (a) / (b)：02 剛認領完就開 4.1，第一輪還沒讀到它。
- 修法：照設計 §5.4 :731「要加入的節點（可勾多台，至少一台）」寫一條規則。建議列出所有 `node/` 紀錄、都可以勾；讀到的狀態只用來顯示。

**Z-m7　從 4.1 進檢查網路頁、再按「建立網路」，堆疊上會有兩個 4.1。**
- 自己拿佔用的檢查網路頁會 `pushReplacement(4.1 建立模式)`（§2.8:157）。如果它是從 4.1 進來的，堆疊變成「入口頁 / 4.1（加入，pending）/ 4.1（建立）」：離開建立頁後回到舊的 4.1，兩個 4.1 各自設定、還原 `Page`。
- §2.4:89 的 4.1 本來就有次要「建立網路」，可以在同一頁切換模式。
- 修法：從 4.1 進來的檢查網路頁改成 pop「去建立」給 4.1，由 4.1 切到建立模式（X-M2 的建議）。從節點頁進來的才 `pushReplacement`。

**Z-m8　`OwnerConsole` 裡金鑰不能用時，迴圈會先問「繼續 / 停」，不是直接停。**
- 舊控制台在 sign / signAdmin / seal 遇到金鑰等級不夠時只顯示 `[KEY_LEVEL]`（nodes.dart:164-168、:205-226、:241-249），不會設 `core.blocked`。§2.1 只有 `loginFor` 會呼叫 `keyErrorToRadio`（app_link.dart:142-144）。
- 照 §2.5:113「金鑰 → 整個流程停、不問」，`OwnerConsole` 內的金鑰拒絕也要讓 `core.blocked` 變成 `keys`，否則要等下一台的 `loginFor` 重新讀 `KeyAbilities` 時才停，中間會多問一次。
- 修法：寫一句「`OwnerConsole` 遇到 `KeyAbilities.refusedBy(e) != null` 時呼叫 `keyErrorToRadio`」，並加一條測試。

（小提醒，不另編號：§2.5:104「含它的 `lease.run` 寫入」——`RecordWriter.writeCas` 不經 `lease.run`（record_writer.dart:39-44），撐住佔用的是迴圈的 `hold`，字面改一下即可。從結果頁進檢查網路頁時，預選應該是那一列的節點；§2.8 只寫了從節點頁進來的情況。）

---

## 3. 現場情境走查（照計畫文字與原始碼推論，⚠️）

| # | 情境 | 每一步都能只靠計畫文字決定？ | 缺的地方 |
|---|---|---|---|
| a | 從零：04 建立，再 02 加入 | 3.5「建立網路」→ 4.1（可勾的條件 Z-m6）→「開始」→ `acquire`（Z-M1：放哪裡、拿不到怎麼辦）→ `loginFor` 04 → `makeNetwork` → `persistedRel` → `[NET_MADE]` → 重讀那一筆，已建立 → 離開時 `pageGone` 釋放 → `NetIndex` 通知首頁。新增 02 → 3.6「加入網路」→ 4.1 加入（只有一筆網路，不問）→ `joinNetwork(rel)` → 國家問題（注入的對話框）→ `[JOINED] ` 開頭 → 連線檢查 → 結果 ✅ | Z-M1、Z-m6 |
| b | 兩台一起勾 | 第一台建立（可以換），重讀是已建立，接著另一台加入 `persistedRel` ✅ | Z-m4（結果頁同時操作） |
| c1 | 建立途中拔 04 的電，04 已套用 | `unclear`（`_makeUnclear`）→ 有 `persistedRel` → 重讀是 pending → 自動檢查：照抄的 `ask` 已經 drop session（Z-m2）→ `close` → `loginFor` 60 s（04 還在開機 → `notFound`）→ 重讀仍是 pending → 整個流程停 → 結果頁那一列只有「檢查網路」→ 借用佔用 → 預選 04 → `nodeDacHash` 對上 → `Upgraded` → `PersistNet` → `[NET_STATE] ` 開頭 → 重讀是已建立 → 完成 → 那一列更新 ✅ | Z-m2（怎麼知道 session 還在）；02 要重開 4.1（§2.5 有寫）✅ |
| c2 | 同上，04 沒套用 | 確認 → `NoChange(NotApplied)` → 拿到回答、沒升級、手機沒有已建立的 net →「再檢查一次」+「建立網路」→ pop「去建立」→ `NetRunPage` `pushReplacement(4.1 建立)` → `dispose` 時 `pageGone` ✅ | Z-M1（新 4.1 的「開始」是 D9 說的那個空檔） |
| d | 建立者壞掉，只剩 pending | 第 6 列「加入網路」（Z-m1：pending 算 net）→ 4.1 選到 pending →「檢查網路」+ 次要「建立網路」（全部 pending）→ 建立模式 → 02 建立 ✅ | Z-m1、Z-m7 |
| e | 加入途中 app 被殺 | 成員停在 joining（join2flow 寫入 `device_id`）→ `NetIndex` 待辦 → 4.1 加入、那一台預設勾。「放棄這次加入」自己拿短佔用 ✅ | Z-m3（不需要 session 的介面） |
| f | 迴圈中途關藍牙 | 連線斷 → `unclear` → 先看 `core.blocked` → 整個流程停、不問 ✅。建立列有 `persistedRel` →「檢查網路」→ `precondition` →「再檢查一次」✅ | 金鑰那一支不會讓 `core.blocked` 變成 `keys`（Z-m8） |
| g | 請求進行中頁面被關 | `pageGone`（有 hold，420 s）→ 等當前請求 → 對話框當成「不要」→ `close` → 放 hold → 釋放 ✅ | Z-m5（登入成功後要不要送） |
| h | 檢查網路頁選錯節點 | 登入後 `nodeDacHash` 對不上任何建立者 →「不是建立者」+「換一台檢查」，不送確認、不給建立；`close()` 之後再 `loginFor` ✅ | 無 |
| i | 被入侵的節點送假回答 | 確認：只會碰到 `creator && dacHash == nodeDacHash()` 的那幾筆（owner.rs:114-119、:991-994）✅；`[NET_STATE] ` / `[JOINED] ` 用開頭判斷，所以 `error_text` 裡節點給的 verb 字串（owner.rs:648-649）騙不到 ✅；`send_update` / `poll_link` 只影響它自己（基準）✅；每段都有上限（updflow 的 `INFO_READS`）✅ | 無新增 |

**本地非特權程序**：新頁面沒有新增平台方法、匯出元件或檔案路徑（plan §5）✅。`NetIndex` 的記錄行只有 net id 前 8 碼，§6 有測試 ✅。沒有發現新的攻擊面。

## 4. 基準備註（不算發現）

- **「建立網路」的出口和 Rust 的句子對不上**：確認回 `NoChange(NotApplied)` 時，Rust 的句子是「可以再建立一次**同一個**網路」（owner.rs:478），但 app 的「建立網路」會建出**新的** net id，舊的 pending 會一直留著（§8 已寫）。`InProgress` / `Unknown` 也給建立（V 已提過），在節點還在套用時可能拆成兩個網路。這兩點是舊控制台的行為。
- **`error_text` 會把節點給的 verb 字串放進畫面句子**（owner.rs:645-650）：被入侵的節點可以在 `[REQ_FAIL] …（代碼 N，<任意文字>）` 裡塞誤導的字。開頭的標籤騙不到判斷，舊控制台也照樣顯示。
- **每次寫入都會重設 360 s 的等待**（nodes.dart:494-500 `_kick`）：有改國家的加入，在最壞情況下可能超過 `pageGone` 之後的 420 s 上限，佔用被收回，之後的寫入走 `PersistFailed { applied: true }` 的補救句子。設計 :576 把 420 s 定成「單一請求」，這是設計層的假設。
- **`FrameInbox` 的暫存沒有上限**：和舊控制台的 `asyncMap`（nodes.dart:343-349）等價，送訊框的是已經通過憑證驗證的自己的節點。

## 5. 驗證分類

### ✅ 已驗證（原始碼 @ 7d7aa9a）
- lease.dart:42-90（`run` / `hold` 在 `!valid` 時丟錯、`pageGone` 在 `_busy == 0` 時立刻 `release`）、:96、:102（420 s / 900 s）、:124-129。
- node_link.dart:153-164（`acquire` 先看 `reg.current`、等 `_dropAll`）、:171-195、:256-283。
- ble_gate.dart:185-212（掃描名額、`Refused`）、:226-236（一次一條連線）、:240-255。
- record_writer.dart:27-44（`NoLease`；`writeCas` 不經 `lease.run`）。
- raw_use.dart:73-82（先 `acquire` 再 push；頁面不在 → `release`）。
- core.dart:280-296（`setRadio` 只結束現有的 `_login`）、:628-748（`LoginFor`：`start` = 建立的時候、`result` 要 `c.lease`、`certRejected` → identity）。
- app_link.dart:60-71、:135-144（`keyErrorToRadio` 只接在 prober 上）。
- home_logic.dart:88-97、home_page.dart:129-162（第 6 列：任何 `net/` 檔就是 `net`；`_back` 時機）。
- nodes.dart:48-56、:146-152、:164-168、:205-273、:276-291、:405-409、:476-500、:507-589（`_ask`：:547 `unclear` 分支在重送之前、:554 `!retry`、:571-572 drop）、:592-622、:626-684、:687-721、:1240-1295、:1567-1582、:1718-1737。
- member_ui.dart:231（`joinWait` 360 s）、:290、:294-310（`SendTrack`）。
- owner.rs:41-47、:77-123（`MemberView`，`creator` 只在 pending 時有值）、:428-431、:438、:445-447、:470-489、:495-561、:577-583、:645-650、:879-893、:991-994、:1066-1184（`net_persisted` / `persist_failed` / `check_network` / `request_confirm_network`）、:1427-1512。
- updflow.rs:231-239（`Wait` 有 `INFO_READS` 上限）。
- 設計 329-app-uiux.md:574-577、:690-760。

### ⚠️ 推論
- §3 的走查、Z-M1 / Z-M2 與各 MINOR 的後果：照計畫文字與原始碼推論。新頁面和 `OwnerConsole` 還沒實作，沒有跑過。
- Z-M1 的「認領返回後原始佔用還在」：照 lease.dart 與設計 :577 推論，沒有在真機上量。

### ❌ 沒做
- 沒跑測試、沒上真機；沒有重驗 v1–v12 的發現；沒有審 PR 1 / PR 2 的實作；沒有查 Kotlin `open` 和 `NetIndex` 同時跑的行為；沒有讀 join2flow.rs 的加入重入細節（屬基準）。
