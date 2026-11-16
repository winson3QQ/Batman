# #329 PR 3 實作計畫 v14 審查（審查者 AB，獨立）

對象：`docs/design/329-pr3-plan.md` v14 @ e947148。角度：明天開始寫第 2–7 步的實作者。整份 §0–§9 讀過一次，再把九個現場情境走過新頁面，看每個畫面、按鈕、navigator 呼叫、佔用呼叫（acquire / hold / pageGone / release）、`OwnerConsole` 呼叫、`ConsoleReply` 處理、紀錄寫入，是不是只靠計畫文字就能決定。基準（join2、舊控制台、owner.rs / netrec.rs / flow.rs）不重審，疑問放在「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 2 MAJOR / 8 MINOR）

v14 把 Z-M1（`acquire` 移回 4.1、先拿再 push）和 Z-M2（不複製重送分支）都修好了，和 `openRawPage`（raw_use.dart:73-82）、舊 `_ask`（nodes.dart:547-566）對得上。剩下兩個 MAJOR 都是新程式自己的介面缺口，不需要重新決定 join2：

- **AB-M1**：4.1 從 `acquire` 回來到 `push(NetRunPage)` 之間，要在佔用下列檔、解密、比對快照。這段期間 4.1 持有佔用，但沒有任何路徑會放掉它。`pageGone` 從沒被呼叫，所以 420 s 期限也不會啟動，結果是藍牙永久鎖住。
- **AB-M2**：「送新密碼失敗 → 那一台算失敗」用到一個沒有定義的判斷。§2.3 只定義了 `[NET_STATE]` 和 `[JOINED]` 兩個開頭，而 Rust 的送新密碼失敗都是 `kind == answer`。

---

## 1. MAJOR

### AB-M1　4.1 在「`acquire` 回來 → 比對快照 → `push`」這段持有佔用，但沒有釋放者。頁面在這段期間消失時，佔用永久不釋放

- **情境**：(a)／(b)。使用者按「開始」後立刻按返回（4.1 沒有 `PopScope`，計畫也沒有給它加），或在比對快照時 app 切掉這一頁。
- **計畫文字**：
  - §2.5:105-108：按「開始」→ 4.1 `acquire`，並且「在佔用下比對快照（§2.4）」。只寫了「`acquire` 回來時 4.1 已不在 → 立刻 `release()`」。
  - §2.4:97：比對要「在佔用下重新列一次檔」，內容包含每一筆的 `applied`，也就是每筆都要 `storeReadSealed` + Kotlin `open` + `netSummary`（async，筆數 × 平台呼叫）。
  - §3.1:177：「4.1 只在交出前的**失敗路徑** `release`」，而且 4.1 的 `dispose` 不碰佔用（§2.5:109「4.1 不再碰它」）。
- **原始碼的事實**：
  - `Lease.pageGone()` 是唯一會設定期限的地方（lease.dart:73-83）。沒有呼叫 `pageGone`、也沒有呼叫 `release` 的佔用，`_deadline` 永遠是 null，`reg._lease` 一直不會清掉（lease.dart:124-125、:131-138）。
  - 佔用期間 `nodeLinkToken == null`（lease.dart:120），自動讀取停止。之後每個 `acquire` 都回 null（「另一個操作還在進行」），直到 app 重開。
  - `NodeLink.acquire` 本身會 `await _dropAll()`，v14 §2.1:51 還多加「先等 `released` 的讀紀錄段（上限 5 s）」。所以只要在比對前檢查一次 `mounted`，比對之後不再檢查，這個窗口就有好幾秒。
- **為什麼會照著寫錯**：照字面，實作者只會在 `acquire` 之後檢查一次 `mounted`，比對完直接 `Navigator.push`。這時 4.1 已經 dispose，`push` 會丟錯或什麼都不做，佔用就這樣留著。
- **修法（照 `openRawPage` 的做法，不加機制）**：§2.5／§3.1 補三句：
  1. 4.1 把「拿到、還沒交出」的佔用記在自己的欄位裡。
  2. 4.1 的 `dispose` 看到這個欄位還在 → `release()`。比對完、`push` 之前再檢查一次 `mounted`，不在 → `release()`。交出後清掉這個欄位。
  3. `acquire` 和比對進行中，「開始」按鈕停用。兩次 `acquire` 會在 `reg.current` 檢查之後、`reg.acquire` 之前交錯（node_link.dart:152-158），第二次會顯示「另一個操作還在進行：<4.1 自己的名稱>」。
- **改壞對照**：假的 `open` 卡住 → 按「開始」→ pop 4.1 → 放行 `open` → 斷言 `reg.current == null`。拿掉 dispose 的 `release` → FAIL。

### AB-M2　送新密碼的成功 / 失敗沒有判斷規則；照 `ConsoleReply.kind` 判斷會把失敗當成功

- **情境**：(a)／(b) 的加入台是「已經是成員、但版本落後」（`send_update`，owner.rs:1437-1439）。`sendUpdateFor` 回來後，§2.5:120 要分成「成功」，或「已加入，新密碼沒有送出 → 算失敗、問繼續 / 停」。
- **計畫文字**：§2.3:73「判斷只在頁面做、只看這個型別」，只定義了兩個判斷：`[NET_STATE] ` 開頭、`[JOINED] ` 開頭。§2.5:120 用到「送新密碼失敗」，但沒有寫怎麼判斷。
- **原始碼的事實**：
  - 送新密碼成功的句子都以 `[UPDATED] ` 開頭（rekey.rs:447、:451、:452）。
  - 失敗的句子大多也是 `OwnerKind.answer`，以 `[REQ_FAIL] ` 開頭（rekey.rs:435-456：`NotListed`、`Unfinished`、`TooFar`、`NotChanged`、`SignFailed`……）。
  - 結果不明走 `_sendUnclear`（nodes.dart:1581）。
- **後果**：照 §2.3 表的語意，`kind == answer` 就是「Rust 的回答」，實作者很可能拿它當成功。這樣一來，`[REQ_FAIL] 這台落後太多版…` 也會被列成成功：結果頁顯示這一台已完成，但節點仍是舊密碼，和其他隊員連不上，使用者也不會被問繼續 / 停。這正是 X-M1 那一類的問題（頁面自己判斷 Rust 的回答），只是落在第三個判斷上。
- **修法**：§2.3 的判斷清單加一條：「送新密碼成功 = `kind == answer && text.startsWith('[UPDATED] ')`；其他都是失敗。」連線檢查同樣寫一條：「連上 = `kind == answer && text.startsWith('[CONNECTED]')`；其他都當連線狀態未知，照 nodes.dart:709；這一台仍算加入成功，結果列顯示最後一句」（見 AB-m3）。
- **改壞對照**：假的 Rust 回 `answer`、`[REQ_FAIL] 沒有換成功，可再試` → 斷言那一列是「已加入，新密碼沒有送出」，而且出現繼續 / 停。改成用 `kind == answer` 判斷 → FAIL。

---

## 2. MINOR

**AB-m1　§2.3:73 的「建立完成 = `[NET_STATE] ` 開頭」和 P8、§2.5 矛盾。**
- 建立請求成功時回的是 `[NET_MADE]`（owner.rs:447、:1100）。只有在 `ReadInfo` 自動轉成確認時才會回 `[NET_STATE]`（owner.rs:1494-1498）。
- §2.5:118 判斷建立有沒有完成，是用 `persistedRel` 加上重讀紀錄。
- 修法：:73 改成「檢查拿到回答 = …」，並明寫「建立完成**不看句子**，只看重讀紀錄（§2.5）」。

**AB-m2　§2.5:122「其他」的括號像是完整清單，但漏了 `ended`，也漏了「`answer` 但不是加入成功」。**
- 加入失敗幾乎都是 `kind == answer`：`[REQ_FAIL]`、`[JOIN_STATE]`、`[COUNTRY] 已取消`（owner.rs:495-561）。
- 修法：改成「其他 = 不符合加入成功判斷的任何 reply（含 `answer`、`ended`）」。

**AB-m3　連線檢查的迴圈放在哪裡、怎麼結束、算不算這一台成功，都沒寫。**
- §2.3:62 說要「複製 `linkCheck`」，§2.5:121 說「每 10 s、120 s」，但沒寫這個迴圈在 `OwnerConsole` 還是在頁面裡。
- 修法：照舊 `_watchLink`（nodes.dart:687-716）寫明：
  - 迴圈在 `OwnerConsole`；
  - 看到 `[CONNECTED]` 就停；
  - 其他回答或沒有回答 = `_linkUnknown`；
  - 這一台照樣算加入成功，結果列附上最後一句。

**AB-m4　`ConsoleReply` 表沒有 `keyError` 欄位；`kind` 怎麼來的也和實際機制對不上。**
- §2.3:77 寫的是「回 `refused`、帶 `keyError`」。可是舊碼在簽章失敗時是送出空簽章（nodes.dart:238-241、:249-252），由 Rust 結束流程，回的是 `answer`（`[REQ_FAIL] …`）或 `ended`；seal 失敗則是 `persistFailed`（:269-271），也回 `answer`。
- 修法：把 `keyError` 加進表裡，寫成「這次請求中有金鑰拒絕，`kind` 照 Rust 回的，不改寫」。迴圈只看 `keyError`。另外寫明這條和 `persistedRel` 的先後：有 `persistedRel` 時，結果列照樣給「檢查網路」，但不做自動檢查。

**AB-m5　§2.3:78 寫「`unclear` 的 `text` = `_unclearNow`」，但確認請求和連線檢查沒有 `unclear` 字串。**
- 這兩種請求逾時時用的是 `_waitLine`（nodes.dart:531、:498）；`retry: false` 的寫入錯誤用的是 :580 的 `[REQ_FAIL] 操作沒有成功：…`。
- 修法：寫明這兩種情況 `kind = unclear`，`text` 是對應的那一句。

**AB-m6　檢查網路頁回到結果頁時，結果頁怎麼知道結果，沒有寫。**
- §2.5:124 寫「做完後那一列換成最新的結果」，§2.8:166-168 只定義了 pop「去建立」。
- 修法擇一：
  - (a) 檢查網路頁 pop `{去建立, 已升級, 其他}`；
  - (b) 結果頁在借出去的佔用還在時，自己重讀那一筆 `persistedRel`（§2.6 的單筆重讀）。
- 建議用 (b)，判斷只有一個來源。

**AB-m7　4.1 的預設勾選規則只寫了反面。**
- §2.5:101 只寫「讀到已在網路裡的 → 預設不勾」，再加上節點頁、待辦的「預勾這一台」。從 3.5 / 3.6（剛認領）或第 6 列進來時，其餘台要不要勾，沒有寫。
- 在情境 (a) 的第二步，04 如果在這次 app 啟動後還沒被讀到，照「沒寫不勾」的反面推論，04 會被預設勾起來，然後被送去加入自己建的網路。在 (d) 裡，壞掉的建立者 04 也會被預設勾上。
- 修法：寫成「只有入口指定的那一台預設勾；其他都不勾」。

**AB-m8　藍牙關掉時，GATT 斷線可能比 `statusStream` 先到。**
- 這時迴圈拿到 `unclear`，`core.blocked` 還是 null（app_link.dart:135-137 才會更新），就會先問一次繼續 / 停。§3.2 的「藍牙 → 整個停、不問」和 T-M1(d) 會依事件到達的順序而不同。
- 修法：寫明「回答到的時候和下一台的 `loginFor` 回 `precondition` 時都要檢查；順序相反時，最多多問一次，按繼續後 `precondition` → 停」。T-M1(d) 兩種順序各一條。

（小提醒，不另編號：
- §6 第 5 步的測試名「自動檢查遇到 `NOT_LOGGED_IN` → 重新 `loginFor`」和 §2.3:76「不比對 `NOT_LOGGED_IN` 字串，看 `sessionAlive`」不一致，改名為「`sessionAlive == false` → close + loginFor」。
- §9 v12 表那一列還寫著「寫入失敗回 `notSent` 由頁面重登再送」，加註「v14 取消，見 v13 表 Z-M2」，免得實作者照歷史列寫。
- 重讀「那一筆」失敗（`open` 丟錯）時算「不是已建立」，寫一句即可。）

---

## 3. 現場情境走查（照計畫文字與原始碼推論，⚠️）

| # | 情境 | 每一步都能只靠文字決定？ | 缺的地方 |
|---|---|---|---|
| a | 從零：04 建立，再 02 加入 | 3.5「建立網路」→ 4.1 建立 → 開始 → 4.1 `acquire` + 比對 → `push(NetRunPage)` → `hold` + `keepScreenOn` → `loginFor(04)` → `OwnerConsole.makeNetwork` → `persistedRel` → 重讀已建立 → 結果階段（`close`、關螢幕旗標、放 `hold`）→ pop → `pageGone` → 釋放 → `NetIndex` 通知 → 4.1 pop。02：3.6 → 4.1 加入（一筆不問）→ `joinNetwork` → 國家對話框 → `[JOINED] ` → `pollLink` → 連線檢查 → 結果 ✅ | AB-M1（按開始後返回）、AB-m7（04 預設勾不勾）、AB-m3 |
| b | 兩台一起勾 | 第一台建立；重讀已建立；第二台加入 `persistedRel`；`sendUpdate` 只會出現在已是成員的台 ✅ | AB-M2（若有 send_update）、AB-m2 |
| c1 | 建立中拔 04 電，04 已套用 | 斷線 → `unclear`、`persistedRel` 已設 → 重讀 pending → `sessionAlive == false` → `close` → `loginFor` 60 s（04 開機中多半 `notFound`）→ 重讀仍 pending → 停 → 建立列只有「檢查網路」→ 借用 → 預選 04 → `nodeDacHash` 對上 → `Upgraded` → `[NET_STATE] ` → 重讀已建立 → 完成 ✅ | AB-m6（結果列怎麼更新）；02 要重開 4.1（§2.5:124）✅ |
| c2 | 同上，04 沒套用 | 確認 → `NoChange(NotApplied)` → 拿到回答、沒升級、沒有已建立的 net →「再檢查一次」+「建立網路」→ `close` → pop「去建立」→ `NetRunPage` pop「去建立」→ dispose `pageGone` → 4.1 建立模式；D9 空檔被拒，再按一次 ✅ | 新的 pending 讓快照不同時要再確認一次（§2.4，屬預期） |
| d | 建立者壞了，只剩 pending | 第 6 列「加入網路」→ 4.1 選到 pending →「檢查網路」+ 次要「建立網路」→ 同頁切建立模式 → 02 建立 ✅ | AB-m7（04 預設勾上會先試 04 建立） |
| e | 加入中 app 被殺 | 成員 `joining` + `deviceId` → `NetIndex` 待辦 → 4.1 加入、預勾那一台 → `joinNetwork` 重入；或「放棄這次加入」= 自己 `acquire` → `net_forget_joining`（owner.rs:131）→ seal → `RecordWriter.writeCas` → `release` ✅ | 無 |
| f | 迴圈中關藍牙 | `GateLink` 斷 → `unclear` → `core.blocked` → 整個停、不問 ✅ | AB-m8（事件先後） |
| g | 請求中頁面被關 | `pageGone`（有 `hold`，420 s）→ 當前請求跑到自己的結果（設計 X19 :501、:576）→ 對話框當成「不要」→ 不開下一步 → `close` → 放 `hold` → 釋放 ✅。按開始後、push 之前被關 → ❌ AB-M1 | AB-M1 |
| h | 檢查網路頁選錯台 | 登入 → `creator && dacHash == nodeDacHash()`（owner.rs:84-87、:115、:991-994）一筆都不是 →「不是建立者」+「換一台」→ `close` → 重新選 → 同一個佔用再 `loginFor` ✅。`nodeDacHash` 沒驗證時是 ""，不會對上任何 64 字元 hex（fail-closed）✅ | 無 |
| i | 被入侵的節點送假回答 | 只能碰到自己是建立者的 pending（DAC 驗證過）✅；`[NET_STATE]` / `[JOINED]` 用開頭判斷，節點給的字串只會出現在 `[REQ_FAIL] …` 中間（owner.rs:645-650）✅；`[UPDATED]` 是 Rust 自己格式化的（rekey.rs:447-452），補上 AB-M2 後同樣用開頭判斷就騙不到 ✅；`send_update` / `poll_link` 只影響它自己（基準） | AB-M2 |

**本地非特權程序**：沒有新的平台方法、匯出元件或檔案路徑（plan §5）✅。`NetIndex` 的記錄行只有 net id 前 8 碼 ✅。原始碼鎖擋住新頁面直接寫 store ✅。

## 4. 基準備註（不算發現）

- 被入侵或很慢的節點每讓手機寫一次，就重設一次 360 s 等待（nodes.dart:494-500）。`NetRunPage` 有 `PopScope`，使用者在這段期間離不開。這屬於基準 / 設計 :576 的單一請求假設（Z 已記）。
- `NoChange(NotApplied)` 的 Rust 句子說「可以再建立一次**同一個**網路」（owner.rs:476），但 app 的「建立網路」會建出新的 net id（Z 已記）。

## 5. 驗證分類

### ✅ 已驗證（原始碼 @ e947148）
- lease.dart:42-90（`hold` 在 `!valid` 時丟錯；只有 `pageGone` 會設期限）、:120、:124-138、:140-149（`_revoke` 只由期限觸發）。
- node_link.dart:152-164（`acquire`：先看 `reg.current`、`await _dropAll`，有交錯窗口）、:171-195。
- raw_use.dart:60-82；record_writer.dart:27-44；ble_gate.dart:226-236。
- nodes.dart:146-153、:164-168、:194-363（`run`：sign 失敗送空簽章、persist 失敗走 `persistFailed`、`ended`）、:405-409、:476-500、:511-589、:592-622、:626-716、:1240-1295、:1567-1582、:1718-1737。
- owner.rs:77-123、:131、:425-600（標籤與句子）、:879-893、:991-994、:1067-1200、:1406-1500（`join2_step` 的 `send_update` / `poll_link`、`join_step` 的 `PersistNet` / `ReadInfo`）；rekey.rs:430-456（`[UPDATED]` / `[REQ_FAIL]`）。
- home_logic.dart:88-97、home_page.dart:129-140；app_link.dart:135-144。
- 設計 329-app-uiux.md:341、:501、:576-577、:728-760。

### ⚠️ 推論
- §3 的走查、AB-M1 的窗口長短（假設每筆 `open` 是幾百 ms 的平台呼叫，沒有量過）、AB-M2 的實作者讀法、AB-m8 的事件先後：都是照文字與原始碼推論，沒有實作，也沒有跑過。

### ❌ 沒做
- 沒跑測試、沒上真機；沒有重驗 v1–v13 的發現；沒有讀 join2flow.rs 的重入細節和 updflow 的上限（屬基準）；沒有查 Kotlin `open` 和 `NetIndex` 同時跑的行為。
