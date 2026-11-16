# #329 PR 3 實作計畫 v15 審查（審查者 AC，獨立）

對象：`docs/design/329-pr3-plan.md` v15 @ 8a8f9df。只讀原始碼（Read / grep），沒有跑測試、沒有上機。基準（join2、舊控制台 nodes.dart、owner.rs / rekey.rs / netrec.rs / flow.rs）不重審，疑問放在「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 0 MAJOR / 7 MINOR）

v14 的兩個 MAJOR 都修好了：
- AB-M1：4.1 有 `_pending`，每條交出前的結束路徑都 `release()`，比對中「開始」停用。
- AB-M2：送新密碼成功改用 `[UPDATED] ` 開頭判斷。

剩下的都是文字和舊碼對不上、或兩節之間的小矛盾。最壞的結果是多問一次「繼續 / 停」，或連線檢查多登入一次。不會損壞紀錄，也不會卡住佔用。

---

## 1. v14 發現的對應

| 發現 | 結果 | v15 位置 | 證據 |
|---|---|---|---|
| AB-M1 / AA-m1 4.1 交出前的佔用沒人放 | ✅（附 AC-m7 nit） | §2.5:114-118、§3.1:190、§6:251 | 只有 `pageGone` 會設期限，見 lease.dart:73-83。沒有呼叫 `pageGone` 也沒有呼叫 `release` 的佔用會一直留著，見 lease.dart:124-125、:131-138。v15 的 `_pending` 涵蓋了比對失敗、列檔失敗、返回鍵、dispose，push 前也再看一次。`acquire` 的交錯窗口在 node_link.dart:154-158，v15 已停用「開始」。§6 有改壞對照：慢的 `open`、中途 pop。§3.2「開始」那一列沒補上這幾條路徑，見 AC-m7 |
| AB-M2 送新密碼沒有判斷 | ✅（附 AC-m7 nit） | §2.3:79、§6:251 | rekey.rs:432 的 `fail = "[REQ_FAIL] 沒有送出："`。`[UPDATED] ` 出現在 rekey.rs:447、:451、:452，其中 :452 是 `Applying`，計畫沒有列。其他失敗都以 `[REQ_FAIL] ` 開頭（:453-456 是字面字串）。改壞對照（只看 `kind`）會 FAIL |
| AB-m1 / AA-m4 建立完成不看句子 | ✅ | §2.3:76 | 建立成功的句子是 `[NET_MADE]`（owner.rs:447）。v15 改成看 `persistedRel` + 重讀 |
| AB-m2 「其他」漏了 `ended` 和非成功的 `answer` | ✅ | §2.5:132 | 和 owner.rs:518 的 `[COUNTRY] 已取消` 是 answer 一致 |
| AB-m3 連線檢查的位置、結束、成功 | ⚠️ → AC-m3 | §2.5:131 | 「加入成功就算成功」和「看到連上就停」都寫了。迴圈放在 `OwnerConsole` 還是頁面仍然沒寫，而且和 §2.3:84 的重登規則互相打架 |
| AB-m4 / AA-m5 `keyError` | ⚠️ → AC-m4 | §2.3:73、:85、D11 | 欄位、「`kind` 照 Rust」、保留 `persistedRel` 都寫了。但只涵蓋 seal / open，沒有涵蓋 sign / signAdmin（nodes.dart:232-252）——AA-m5 明列的第一條路徑就是這兩個 |
| AB-m5 `unclear` 用哪一句 | ⚠️ → AC-m1 | §2.3:86 | 確認請求用 `_waitLine` 是對的（nodes.dart:1244：預設 15 s、沒有 `unclear`）。但 v15 把送新密碼也寫成 `_waitLine`，實際上是 `_sendUnclear` 經 `_unclearNow()`（nodes.dart:1581、:55、:436） |
| AB-m6 結果列怎麼更新 | ✅ | §2.8:172 | 結果頁在借出的佔用下自己重讀那一筆，判斷只有一個來源 |
| AB-m7 預設勾選 | ✅ | §2.5:110 | 寫成正面清單：`node_state == 1` 加上帶進來的那一台，其他不勾 |
| AB-m8 藍牙關時斷線先到 | ⚠️ → AC-m5 | §2.5:133、§6:251 | 「問之前再看一次」解決不了事件的先後；§6 的測試名稱要求的行為，這個做法保證不了 |
| AB 小提醒：§6 的 `NOT_LOGGED_IN` 測試名 | ✅ | §6:251 | 改成「`sessionAlive == false` → 先關再 `loginFor` 一次」 |
| AB 小提醒：§9 v12 表 | ✅ | §9:352 | 註明「v14 已取消」 |
| AB 小提醒：重讀單筆失敗 | ✅ | §2.5:134 | fail-closed，走檢查網路 |
| AA-m2 | ✅ | §6:251 | 同上 |
| AA-m3 重送的改壞對照 | ✅ | §6:249、:251 | 第 3 步：`OwnerConsole` 那一列斷言不重送。第 5 步：頁面看到 `notSent` 不重登再送 |
| AA-m6 「同一條規則」 | ✅ | §2.4:103、§6:250 | 理由改寫了；第 6 列看 `applied` 的改壞對照已加入 |
| AA-n1 寫入錯誤舊碼不 drop | ✅ | §2.3:87 | 對得上 nodes.dart:554 → :579-582 |
| AA-n2 自己 `acquire` 被拒、忘記前的確認 | ✅ | §2.8:171 | — |
| AA-n3 D6 的 `rel` | ❌ → AC-m7 | D6:229 | 還是寫「只在拿到 `PersistNet` 的 `rel` 時做」，但 §9 v15 表說已改 |

---

## 2. MINOR

### AC-m1　§2.3:86 把送新密碼的 `unclear` 句子寫成 `_waitLine`，實際是 `_sendUnclear`

- **證據**：
  - nodes.dart:1580-1581：`_ask(... requestSendUpdate ..., wait: _joinWait, retry: false, unclear: _sendUnclear)`。
  - `_sendUnclear = '[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁'`（nodes.dart:55）。
  - 逾時和寫入錯誤都走 `_unclearNow()`（nodes.dart:498、:549），之後 drop session（:551、:571）。
  - 只有確認請求（nodes.dart:1244，沒有 `unclear`）才走 `_waitLine`（:531、:572）。
- **後果**：
  - 頁面用 `[UPDATED] ` 開頭判斷，所以結果不會錯。
  - 但 `OwnerConsole` 的實作者照 §2.3:86 會給送新密碼 15 s 的等待和錯的句子。v15 自己在 §2.3:82 也寫了送新密碼是 360 s 的 `_joinWait` 路徑，兩處不一致。
  - 等待太短 = 節點還在套用時就判成不明。這是現場行為的改變：在 Morse 上加入後送新密碼本來就要好幾分鐘。
- **修法**：§2.3:86 改成三種：
  - 建立 / 加入 / 送新密碼：用各自的 `unclear` 常數經 `_unclearNow()`；
  - 確認：`_waitLine`；
  - 連線檢查：`_linkUnknown`。
  - 另外寫明送新密碼的等待是 `_joinWait`。
- **改壞對照**：假節點在送新密碼後 20 s 才回 `[UPDATED]` → 斷言那一台成功。改成 15 s → FAIL。

### AC-m2　`sessionAlive` 的列舉漏了「帶 `unclear` 的請求回 `notSent`」

- **證據**：nodes.dart:571 `if (unclear != null && (a == unclear || a == _notSent)) await _drop();`。`_unclearNow()` 在什麼都沒送出時回 `notSent` 句子（nodes.dart:436 → `SendTrack.unclearNow`），這時舊碼也會 drop。§2.3:84 只列了「unclear / ended / 寫入錯誤」。
- **後果**：影響小。建立回 `notSent` 就沒有 `persistedRel`，不會自動檢查；加入回 `notSent` 會問繼續 / 停，下一台本來就先 `close()`。但如果同一台之後還要送請求，實作者照字面會用一條 Rust 可能還停在流程中間的 session。
- **修法**：§2.3:84 改成「`kind` 是 `unclear` / `notSent`（逾時或斷線造成的）/ `ended`、或寫入錯誤之後 → `sessionAlive = false`」。舊路徑「沒有 session」的 `notSent` 本來就是 false。

### AC-m3　連線檢查迴圈放在哪裡仍然沒寫；放在頁面時會和 §2.3:84 的重登規則打架

- **證據**：
  - 舊 `_watchLink`（nodes.dart:687-716）遇到任何非回答就結束：
    - 讀取失敗回 null → break（:704-706）；
    - 逾時 → `_drop`（:572），下一圈 `!identical(_session, joined)` → break（:697-699）；
    - `ended` → drop（:337）→ 下一圈 break。
  - 這幾種情況都是「連線狀態未知」，不會重新登入。
  - §2.3:84 的規則是：「頁面要再對同一台送請求前，`sessionAlive == false` → 先 `close()` 再 `loginFor`」。
  - §2.5:131 只寫了「照 `_watchLink`」。
- **後果**：如果實作者把每 10 s 的迴圈寫在頁面，同時遵守 §2.3:84，那麼一次逾時之後會在 120 s 的視窗內再掃描、登入一次（最多 60 s）。舊控制台這時會停下來顯示「狀態未知」。這不會損壞紀錄，但每一台最多多花約 1 分鐘，而且和「照舊控制台」矛盾。
- **另外**：§2.5:131 的「送新密碼之後……有 `pollLink`」不會發生。`poll_link` 和 `send_update` 互斥（owner.rs:1437 要求 `!behind`、:1439 要求 `behind`），送新密碼的回答也不會設 `poll_link`（rekey 的 `update_text` 只回句子）。
- **修法**：寫明「連線檢查迴圈在 `OwnerConsole`（`watchLink`），回一個 `ConsoleReply`：連上 → `[CONNECTED]` 那一句；其他 → `_linkUnknown`。迴圈內不重新登入；§2.3:84 的重登規則不適用於它」。拿掉「送新密碼之後」，改成「沒有 `sendUpdate`、有 `pollLink` 時」。
- **改壞對照**：假 session 在第二次連線檢查時逾時 → 斷言 `loginFor` 只呼叫一次（加入那次），結果列是「連線狀態未知」。

### AC-m4　`keyError` 只涵蓋 seal / open；sign / signAdmin 的金鑰拒絕和頁面自己的 `open` 沒涵蓋。條件也要寫成 `refusedBy != null`

- **證據**：
  - 舊碼裡 sign / signAdmin 的拒絕會送空簽章，`_keyFail` 只顯示 `[KEY_LEVEL]`（nodes.dart:164-167、:232-252）。加入時的 `signAdmin` 正是這條。
  - §2.3:85 只寫「seal / open 時」。
  - `keyErrorToRadio` 只在 `KeyAbilities.refusedBy(e) != null` 時設 `keyOk: false`（app_link.dart:142-144），但 §2.3:85 寫的是「接到 Keystore 例外 → …設 `keyError = true`」，沒有這個條件。
  - 頁面層也有兩個 `open` 沒說：4.1 的比對（§2.4:106）、結果頁 / 檢查網路頁的單筆重讀（§2.5:128、§2.8:170）。它們遇到金鑰拒絕時要不要 `keyErrorToRadio`，沒寫。
- **後果**：
  - 加入時 `signAdmin` 被拒，`kind` 是 Rust 的 `ended` 或 `[REQ_FAIL]`，`keyError == false`，`core.blocked` 也沒設 → 頁面會問「繼續 / 停」。這和 §3.2「金鑰 → 整個流程停」以及 D11 的理由不一致。
  - 按繼續之後，下一台的 `loginFor` 在登入簽章時會走 §2.1:49 的 `keyErrorToRadio`，然後 `precondition` → 停。所以最多多問一次（和 AB-m8 同等級）。
  - 反過來，如果任何 `PlatformException` 都設 `keyError`（例如一般的 seal 失敗），迴圈會在 `core.blocked == null` 時停下，畫面上沒有說明原因。
- **修法**：§2.3:85 改成「`OwnerConsole` 在 sign / signAdmin / seal / open 時，只要 `KeyAbilities.refusedBy(e) != null` → `keyErrorToRadio` + `keyError = true`」。§2.6 的單筆重讀寫一句「金鑰拒絕 → `keyErrorToRadio`，這次算『不是已建立』」。這樣自動檢查的 `loginFor` 會回 `precondition` → 停。
- **改壞對照**：假 `signAdmin` 丟 `keyLevel` → 斷言 `keyError`、沒有問、`core.blocked == keys`。只在 seal 設 → FAIL。

### AC-m5　「問之前再看一次 `core.blocked`」解決不了事件的先後；§6 的測試要求它保證不了的行為

- **證據**：
  - `core.blocked` 只由 `statusStream` 經 `wireRadio` 更新（app_link.dart:135-138）。
  - GATT 斷線在 `GateLink` 那邊，是另一條事件來源。
  - §2.5:133 寫「每次要問之前都再看一次」，可是迴圈拿到 `unclear`、準備問的那一刻，狀態事件可能還沒到。
  - §6:251 的測試「藍牙關時 GATT 斷線先到 → 不問直接停」只有在假的狀態事件比問的時間點更早到時才會過；真正的先後計畫沒有控制。
- **後果**：實作者有兩條路，兩條都不好：
  - 照寫，測試只是剛好照順序過；
  - 自己加一個等狀態的延遲——這是計畫沒有的新機制。
- **修法（不加機制）**：
  - 照 AB-m8 原本的建議，寫明「順序相反時最多多問一次：按『繼續』後，下一台的 `loginFor` 回 `precondition` → 整個停」。
  - 或者寫明「問的對話框開著時 `core.blocked` 變成非 null → 對話框當成『停』」。這用的是頁面原本就聽的 `NodeLink` 狀態。
  - 選一條，§6 的測試照它改名，兩種順序各一條。

### AC-m6　§2.3:83 把「國家對話框回答不要」對到 `notSent`，但 Rust 回的是 `answer`

- **證據**：
  - 舊碼答「不要」→ `s.countryConfirmed(yes: false)`（nodes.dart:291）。
  - Rust 回 `E::Declined` → `[COUNTRY] 已取消：這台的國家仍是 …，沒有加入網路`，kind 是 `answer`（owner.rs:518）。
  - 只有「被移除過」的對話框回答「取消」才是 Dart 自己的 `[JOIN_STATE] 已取消：沒有寫入、沒有送出`（nodes.dart:657-659），對到 `notSent` 才對。
- **後果**：兩者都會走「問繼續 / 停」（§2.5:132），結果相同。但 §2.3:85 說「`kind` 照 Rust 原樣」，同一節裡互相矛盾。照 :83 實作，就得在 `OwnerConsole` 裡改寫 Rust 的回答，`sessionAlive` 也會變得說不清：Rust 在 Declined 之後 session 還在。
- **修法**：:83 拆成兩條：國家「不要」→ Rust 的 `answer`；被移除過「取消」→ `notSent`。

### AC-m7　小處（nit 合併）

- D6:229 仍寫「只在拿到 `PersistNet` 的 `rel` 時做」，§9 v15 表卻說 AA-n3 已改。改成「只在有 `persistedRel` 時做」。
- §3.2「開始」那一列沒補 `_pending` 的路徑：比對中返回 / dispose、列檔失敗 → 釋放（AA-m1 要求過）。另外，4.1「開始」時列檔失敗要顯示什麼沒寫，建議沿用 §2.4:101 的「讀不到手機裡的網路紀錄」+「再試一次」。
- §2.3:80 引用 nodes.dart:709；判斷 `[CONNECTED]` 的其實是 :710，:709 是去掉 `[ANSWER] `。
- §2.3:79 的 `[UPDATED] ` 行號補上 rekey.rs:452（`Applying`「正在套用新密碼」）。寫明它也算成功，和舊控制台一樣只顯示句子。
- `persistedRel` 的定義是「第一個 `PersistNet` 寫入成功」。加入請求也會有 `PersistNet`（join2 寫成員項），所以加入列也會帶 `persistedRel`。結果頁只在「建立列」看它，沒有影響，但寫一句「只在建立列使用」可以免得實作者拿它判斷加入。

---

## 3. v15 改動的其他檢查（沒有發現問題）

- **`_pending` 和其他節**：
  - §3.1:190「4.1 只在交出前的失敗路徑 `release`」和 §2.5:115 一致。
  - 交給 `NetRunPage` 時清空 `_pending`，之後只有 `NetRunPage` 呼叫 `pageGone`，沒有兩個寫入者 ✅。
  - 4.1 持有 `_pending` 的期間沒有 `hold`，所以 dispose 時直接 `release()` 會立刻清掉 `reg._lease`（lease.dart:85-90）✅。
- **`persistedRel` 和 owner.rs:1144-1151**：
  - 第一次 `PersistNet` 失敗時是 `St::Join { applied: false }` → `[REQ_FAIL] 建立網路沒有成功`，沒有 `persistedRel` → 結果頁給「再試這一台」✅。
  - 第二次失敗時是 `applied: true` → 「請按『檢查網路』」，`persistedRel` 已設 → 結果頁給「檢查網路」✅。
- **開頭判斷擋得住被入侵節點**：
  - 節點給的字串只會出現在 `[REQ_FAIL] …`（owner.rs:645-650）或 `[REQ_FAIL] 中斷（{w}）` 中間（rekey.rs:456）✅。
  - Dart 自己的 `_makeUnclear`（`[NET_STATE] 結果不明`，nodes.dart:50）和 `_linkUnknown`（`[JOINED] 已套用…`，nodes.dart:53）都不是 `answer`，所以不會被誤認成「拿到回答」或「加入成功」✅。§2.3:81 已寫明。
- **結果頁自己重讀（§2.8:172）**：借用的佔用一直沒放，所以重讀是在佔用下做的。重讀只讀不寫，不經 `RecordWriter` ✅。
- **D11 和 §2.5:133**：一致。`keyErrorToRadio` 讓 `keyOk` 保持 false，直到 app 重開（app_link.dart:140-141 的註解）。這段期間 `loginFor` 回 `precondition` ✅。
- **本地非特權程序**：v15 沒有新的平台方法、匯出元件或檔案路徑 ✅。`keyError` 只由本機 Keystore 例外觸發，節點製造不了 ✅。

## 4. 基準備註（不算發現）

- 舊 `_watchLink` 遇到 `ended` 時不會立刻 break，要等下一圈才發現 session 已換（nodes.dart:697）。行為上一樣是「狀態未知」。
- 送新密碼的 `wait` 循環（`OwnerKind.wait` → `resumeUpdate`，nodes.dart:292-298）每一圈都重設等待，所以實際上限可能超過 360 s，和 §2.5:124 的「≤ 360 s、在 420 s 內」的假設有出入。這屬於基準（Z / AB 記過的 `_kick` 問題同一類）。

## 5. 驗證分類

### ✅ 已驗證（原始碼 @ 8a8f9df，唯讀）
- rekey.rs:425-456（`update_text`：`fail` 在 :432；`[UPDATED] ` 在 :447 / :451 / :452；其他都以 `[REQ_FAIL] ` 開頭）。
- owner.rs:518（`Declined` 是 answer）、:588（`[CONNECTED] 已連上隊伍網路`）、:1135-1154（`persist_failed`）、:1437-1439（`poll_link` 和 `send_update` 互斥）。
- nodes.dart:49-55（各個 unclear 常數）、:155-342（步驟迴圈、sign 失敗送空簽章、persist 失敗、country、ended → drop）、:395-420、:476-500、:502-589（`_ask`）、:592-623、:626-716（`_joinNetwork`、`_watchLink`）、:1238-1244（確認：預設 15 s、沒有 `unclear`）、:1565-1582（送新密碼：`_joinWait`、`_sendUnclear`）。
- app_link.dart:125-144（`wireRadio`、`keyErrorToRadio`）。
- node_link.dart:145-195（`acquire`、`released`）。
- lease.dart:30-150（`hold` / `pageGone` / `release`；只有 `pageGone` 設期限）。

### ⚠️ 推論
- AC-m1 的「現場送新密碼要好幾分鐘」：照 `_joinWait` 的設計意圖推論，沒有量過。
- AC-m3 的後果（多登入一次）：假設實作者把迴圈放在頁面。
- AC-m5 的事件先後：從兩條事件來源推論，沒有在真機上觀察。
- `SendTrack.unclearNow` 在什麼都沒送出時回 `notSent`：只從 nodes.dart:436 的呼叫方式和註解（:506-507）推論，沒有讀 `SendTrack` 本體。

### ❌ 沒做
- 沒跑測試、沒上真機。
- 沒重驗 v1–v13 的發現。
- 沒讀 join2 全文、join2flow.rs、updflow.rs。
- 沒查 raw_use.dart、ble_gate.dart（AA / AB 已驗）。
