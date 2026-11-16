# #329 PR 3 實作計畫 v2：新增節點、建立 / 加入 / 檢查網路

上層設計：`docs/design/329-app-uiux.md`（v12.1，已合併）§4.1、§4.3.8、§4.3.9、§4.4、§4.7、§5.1、§5.3、§5.4、§7、§9.1、§12。main = 29b0085。

v1 → v2：兩位審查（A：1 BLOCKER / 8 MAJOR / 9 MINOR；B：2 BLOCKER / 6 MAJOR / 8 MINOR，都 REJECT）的每一條對應見 §11。最大的三個改變：
1. 佔用下的登入改成照設計 §4.3.9：`NodeLink.loginFor` 驅動 `core.LoginFor`，登入成功後把連線與 session 交給流程（v1 沿用舊控制台的 `_tryLogin`，是錯的）。
2. 「建立網路」只在**拿到佔用後、重新列檔、net / mnet / mpend 三種檔案都沒有、而且目錄讀得到**時才允許；任何解不開或讀不到 → 不給建立（v1 會讓隊伍分裂）。
3. 新頁面用**從舊控制台複製出來**的 `OwnerConsole`；**舊控制台一行不動**（v1 要整段搬移，邊界畫不清、回歸風險最大）。

## 1. 事實（原始碼，main 29b0085；v1 審查已逐條核對）

| # | 事實 | 證據 |
|---|---|---|
| P1 | 建網、加入、檢查、加入後的連線檢查都在舊控制台 `_NodesPageState`，共用一組請求機制：`_login` / `_tryLogin`、步驟迴圈 `_run`、`_ask`、`_kick`、`_drop`、`_lost`、`_endUnclear`；`_askSw`、`_runOp`、`_holding`、`_writeRecord` 也共用同一批欄位，步驟迴圈另外設一批旁路旗標（`_linkFrom`、`_left`、`_sendAfter`、`_last*`、`_removedQ`、`_joinreqInFlight`、`_saved`） | nodes.dart:194-589、:687-716、:750-797、:1574-1622 |
| P2 | 這組機制綁頁面：`setState`、`mounted`、`context` 對話框、`_say`（**會 `debugPrint`**，不只顯示）；頁面不在時 `_pickNet` 回第一筆（:614） | nodes.dart:157-160、:277、:405、:520、:614 |
| P3 | 舊控制台與 `ClaimRecords` 的紀錄寫入不經 `RecordWriter` | nodes.dart:261、:467、:764、:1026、:1290；claim_records.dart:43-53 |
| P4 | `_busy` 就是原始佔用的 hold（`rawBusy = true` = `lease.hold()`），`_ask` 用 `_busy && !held` 擋重入 | raw_use.dart:25-44；nodes.dart:520-529 |
| P5 | `BleGate.scan(token)` / `connect(token, addr)`；`GateLink` 有 `requestMtu`、`read`、`subscribe`、`write`，夠登入步驟用；一次只允許一條連線 | ble_gate.dart:185、:226-231 |
| P6 | `RecordWriter.writeCas(lease, rel, gen, sealed)` 吃已封好的位元組，只認登記表**目前**的佔用 | record_writer.dart:27-40 |
| P7 | `core.LoginFor` 是完整的登入狀態機：排程、同位址隔 6 s 可重試、N9（剛寫紀錄 10 s 內「解不開」放進 retry）、身分不符寫首頁狀態、寫 `isY` / `notY` 備忘、60 s 預算。**`NodeLink` 沒有驅動它的入口** | core.dart:628-748；node_link.dart（無） |
| P8 | session 佔用 420 s 上限只從 `pageGone` 起算 | lease.dart:72-102 |
| P9 | `ClaimPage` 自己做藍牙、進度只有 `_say` 文字；原始佔用到頁面 `dispose` 才交回 | claim.dart:154-157、:212-472；raw_use.dart:57-66、:122-144 |
| P10 | 9b00ca6 已替舊控制台補上國家、被移除過、連線檢查、檢查網路四條路徑的測試（改壞 5/5） | 9b00ca6 |
| P11 | Rust 加入要求網路已套用（`NotApplied`） | join2flow.rs:340-341 |
| P12 | Rust `list_kind` 讀不到目錄回空清單、不報錯 | owner.rs:41-47 |
| P13 | `NodeLink.released` 非同步：新佔用在讀完紀錄前拿到時，不呼叫 `core.releaseLease`，`writtenAt` 不設定 → N9 視窗失效 | node_link.dart:171-195；core.dart:703-705 |
| P14 | `MemberView` 只有 `last4`（舊節點 ""）、`joining`、`approved`、`creator`，沒有 device id | owner.dart:243-270；owner.rs:79-80、:108 |
| P15 | `request_member_join` 只在 dev 版本 | owner.rs:1213-1215 |
| P16 | 首頁第 6 列現況：`net \|\| mnet \|\| unknown → 加入網路`，四種動作都開舊控制台 | home_logic.dart:92-96；home_page.dart:129-151、:177-178 |

## 2. 做法

### 2.1 `NodeLink.loginFor`：佔用下的登入（設計 §4.3.9）

- 新增 `Future<LoginResult> NodeLink.loginFor(Lease lease, String id, {bool clearNotY = false})`。只在 `lease` 是登記表目前的 session 佔用時可用，否則丟 `NoLease`。
- 它驅動 `core.LoginFor`（`next / result / tick / wakeAt`），每次嘗試用 `BleGate.connect(lease.token, addr)` 加一個「**登入到 `loggedIn` 就停**」的 prober 變體（`HandoffProber`，和 `SessionProber` 同一個步驟迴圈與 8 s msg2 預算，只是不讀狀態）。`loginEnd` 照 `prober.dart` 的對應表交給 `LoginFor.result`。
- 結果：
  - `LoginResult.ok(LoginHandoff h)`：`h` 帶 `GateLink`、`OwnerSession`、已訂閱的 TX 串流。**交接之後歸呼叫者**：呼叫者負責 `h.close()`（取消 TX 訂閱、`await link.close()`）。
  - `LoginResult.notFound / identity / refused / keys`：照 `core.LoginFor` 的結論；身分不符與被拒由 core 寫進首頁狀態（現況 core 已做）。
- 每一次失敗的嘗試都 `await link.close()` 之後才試下一個（和 `NodeLink._run` 一樣，node_link.dart:317）。`requestMtu` / 讀 ctrl / 訂閱丟例外 → 也關連線（修掉殘項 G-m3 在新路徑上的版本）。
- 位址備忘、節點狀態的唯一寫入者仍是 `NodeLink`（§3.1）。

### 2.2 `OwnerConsole`：從舊控制台複製，只給新頁面

- 新檔 `lib/src/flows/owner_console.dart`。**舊控制台不改。** PR 6 刪舊控制台時重複消失。
- 複製的範圍只到新頁面要用的：步驟迴圈（`write` / `sign*` / `persist*` / `confirmCountry` / `confirmRemoved` / `answer` / `ended`）、`ask`（逾時、unclear / notSent、寫入失敗重新登入只重送一次、`ended` → 放掉 session）、`makeNetwork`、`joinNetwork(rel)`、`confirmNetwork(rel)`、`linkCheck`、`sendUpdateFor(rel)`（加入時節點版本落後，`_sendAfter`）。**不複製**：邀請、隊員、移除、離開、軟體更新、狀態頁（PR 4 / 5）。
- 和舊控制台的差別（逐條寫進檔頭註解）：
  1. 登入：不自己掃描，呼叫 `NodeLink.loginFor`；斷線重新登入也一樣。
  2. 紀錄寫入：`RecordWriter.writeCas(lease, …)`。
  3. 選網路：不在裡面挑。`joinNetwork` / `confirmNetwork` 吃 `rel`（M-1）。
  4. 對頁面的介面是**結構化結果**，不是 `_say`（§2.2.1）。
  5. 重入旗標（`_inFlight`）和佔用分開；佔用由呼叫者（`NetworkRun`）持有（§3.4）。
  6. 文字紀錄只寫種類、代碼、後四碼（位址經 `NodeLink.mask`）；不寫回答內容。
- 國家問題：步驟迴圈收到 `confirmCountry` 先停計時，交給注入的 `Future<bool> askCountry(String question)`，回答後重新計時（同 nodes.dart:276-291）。被移除過：交給 `Future<bool> askReAdd(String text)`，同意 → 重讀紀錄、`removedConfirmed: true` 重新開始那一台。

#### 2.2.1 結果契約（`ConsoleResult`）

| 種類 | 何時 | 新頁面顯示 |
|---|---|---|
| `done(line)` | 節點的回答（Rust 組的句子） | Rust 原句（去掉標籤） |
| `refused(line)` | Rust 拒絕（String 例外） | Rust 原句 |
| `unclear` | 送出後斷線 / 逾時，`SendTrack.wrote` 為真 | 本頁固定句「結果不明」+ 下一步按鈕（見 §2.3 表） |
| `notSent` | 寫入之前斷線 | 「還沒有寫入或送出，可以再試一次」 |
| `noLink(LoginResult)` | 登入失敗 | 依 `LoginResult` 的固定句（設計 §4.3.5 原因句） |
| `leaseLost` | `NoLease` / `Refused` | 「這個操作被中斷了」（佔用被收回，§4.4） |
| `keyFail(level)` | 金鑰閘門 / 簽章失敗 | 2.4 的句子 |
| `cancelled` | 使用者在國家 / 加回的問題選「不要」 | 「已取消，沒有寫入、沒有送出」 |

例外原文（`$e`）只進技術資訊，不上主畫面（A-M8）。

### 2.3 多台建網：`NetworkRun` 狀態機（新寫）

- 新檔 `lib/src/flows/network_run.dart`（邏輯）+ `lib/ui/network_pages.dart`（4.1–4.5）。
- **4.1（表單，不拿佔用）**：
  - 手機**沒有任何 net 檔**時：網路名稱（預設 `Batman`）、頻道（進階，40 / 42）。有 net 檔時這兩項不顯示，改成「加入哪一個網路」（只有一筆就不問；只列已套用的，見下面）。
  - 節點清單：手機的 `node/` 紀錄。預設勾「最近一次讀到、而且還沒加入網路」的；最近一次讀到已在網路裡的**不能勾**（避免誤送新密碼）；沒讀到的可以勾、標「目前讀不到」。至少一台。
- **按「開始」才拿 session 佔用**（拿不到 →「另一個操作還在進行：<名稱>」）。從開始到離開結果頁，`NetworkRun` 一直持有 `lease.hold()`。期間 `PopScope` 擋返回、`keepScreenOn` 開著。
- **開始時的建立閘門**（B-2）：在佔用下用 Dart `Directory` 列 `records/net`、`records/mnet`、`records/mpend`：
  - 三個目錄都不存在、或存在但是空的 → 這次是「建立」（第一台建立、其餘加入）。
  - 任何一個有檔案 → 這次是「加入」：目標網路 = 4.1 選的那筆 net（只能是 net；只有 mnet / mpend 的手機不會進這頁，見 §2.5）。
  - 列目錄丟例外 → 不開始，顯示「讀不到手機裡的網路紀錄」，什麼都不做。
  - 加入時目標 net 打不開 → 不開始，顯示現有的重裝警告句（nodes.dart:609-612 的內容），**不給建立**。
- **目標網路只決定一次**（M-1）：建立 → 第一台 `PersistNet` 的 `rel`；加入 → 4.1 選的 `rel`。每一台開始前用 `rel` 重讀紀錄（拿新的 generation 與內容）。
- **每一台**（照設計 §5.4 表）：
  1. 上一台的 `LoginHandoff.close()` 完成（`await`）→ `NodeLink.loginFor(lease, id)`。
  2. 建立者：`makeNetwork` → 紀錄不是已套用 → 自動 `confirmNetwork(rel)` 一次（A18）。仍未套用 → **整個流程停**（後面每一台都會 `NotApplied`，P11），結果頁給「檢查網路」。
  3. 加入者：目標網路不是已套用 → 不送，結果「網路還沒有確認完成：先在建立的那台按『檢查網路』」。是 → `joinNetwork(rel)`（國家 / 加回問題照 §2.2）→ 節點版本落後（`sendUpdate`）→ `sendUpdateFor(rel)` → 連線檢查（每 10 s，120 s）。
- **停止規則**（M-4、A-M3e）：
  - 前提類（藍牙關、沒有權限、金鑰不可用、`leaseLost`）→ 整個流程停，結果頁顯示那個原因（2.2 / 2.3 / 2.4 的句子），**不問繼續**。
  - 建立者失敗或未套用 → 整個流程停。
  - 加入者的其他失敗（`noLink`、`refused`、`unclear`、`notSent`）→ 問「繼續下一台 / 先停在這裡」；對話框被返回鍵關掉 = 停。
- **結果頁**：逐台「完成 / 失敗原因 / 還沒做」；結果不明的那一台給「檢查網路」（建立者）或「再試這一台」（加入者，加入是可重送的，現況 `_joinUnclear` 的意思）；離開結果頁時：`h.close()` 完成 → `keepScreenOn` 關 → `lease.release()`。

### 2.4 網路摘要表（設計 §4.3.8，照 A-M4 / B-2 改）

- `NodeLink` 在啟動檢查通過時、每次佔用釋放後各算一次（注入 `NetIndexSource`：列檔 + 打開 + `netSummary` / `mnetSummary`）。
- **有沒有紀錄只看列檔**（不解密）：`netFiles`、`mnetFiles`、`mpendFiles`、`pendingClaims`，以及「列不出來」旗標（Dart `Directory` 列檔丟例外）。
- 解密只用來取每個網路的名稱、`applied`、成員（加入中、建立者、後四碼）。一筆解不開 → 那一筆標「打不開」、記一行路徑。
- 用代號計數：只保留最新一次計算的結果（B m-4）。計算中 → 首頁第 6 列用中性的「加入網路」並顯示「正在讀取網路紀錄」，不顯示「建立網路」（A m8）。
- **建立按鈕只在**：列得出來、三種檔都是 0。其他情況都不顯示「建立網路」。這裡只決定顯示；真正的閘門是 §2.3 開始時在佔用下重新列檔（沒有 TOCTOU）。

### 2.5 入口去處表（A-M6、B-2 情境 A / D）

| 入口 | 條件（摘要表） | dev / dev2（devTrust） | field |
|---|---|---|---|
| 第 6 列主要 | 列不出來 / 計算中 / 有打不開的 | 中性「加入網路」→ 新頁 4.1，開始時的閘門決定（讀不到就不開始） | 同 |
| 第 6 列主要 | 0 檔 | 「建立網路」→ 新頁 4.1（建立） | 同 |
| 第 6 列主要 | 有 net、目標已套用 | 「加入網路」→ 新頁 4.1（加入） | 同 |
| 第 6 列主要 | 有 net、**沒有已套用的** | 「檢查網路」→ 新頁（對建立者 `confirmNetwork`，單台） | 同 |
| 第 6 列主要 | 只有 mnet | 「加入網路」→ **舊控制台**（隊員加入，PR 5 換） | 不顯示按鈕，只顯示句子（隊員加入在 field 版不存在，P15） |
| 第 6 列主要 | 只有 mpend | 「看我的申請」→ 舊控制台（PR 5） | 不顯示 |
| 第 6 列次要 | 0 檔 | 「我是隊員，加入隊長的網路」→ 舊控制台（PR 5） | 不顯示 |
| 首頁「新增節點」 | — | 新的 3.x（§2.6） | 同 |
| 3.5 / 3.6 主要 / 次要 | 同第 6 列 | 同上 | 同上 |
| 節點頁「還沒加入網路」 | 同第 6 列，對象預設勾這一台 | 同上 | 同上 |
| 待辦「節點加入網路沒有做完」 | 見 §2.7 | 新頁 4.1，預設勾那一台 | 同 |

### 2.6 新增節點：`ClaimPage` 原地換樣式（D1，縮小版）

- **只換 `ClaimPage.build` 的樣式**，邏輯（`_claim` / `_find` / `_recover`）不動，`claim_*` 測試不改判定。不承諾步驟清單與經過時間（A-M5 二擇一的第二案）；畫面上是一個進度句（現有 `_say` 的最後一行，經 §3.4 規則）+ 技術資訊。
- 3.1 一顆主要按鈕「掃描 QR code」；貼上 / 16 進位只在開發者選項（現況已是 dev-only 按鈕，換樣式時保留 key）。
- 認領成功：`ClaimPage` 以 `Navigator.pop(ClaimDone(deviceId))` 交出結果（新增的一個回傳值，不改邏輯）；首頁收到後開 3.2 暱稱（`UiState`，1–24 字，PR 2 的過濾）→ 3.5 / 3.6。
- **佔用交接**（B M-3、A-M5）：3.5 / 3.6 在 `ClaimPage` 已經 pop 之後才顯示；按「建立 / 加入網路」時 `NodeLink.acquire` 會**先等上一個 `released` 處理完**（新增：`released` 回傳的 future 存起來，`acquire` 先 await 它），再拿佔用。這同時修掉 P13 的 N9 視窗失效。
- F41（認領中按返回）：`ClaimPage` 在 `_busy` 期間 `PopScope(canPop: false)` + 提示「認領進行中，請稍候」。
- S10（BLE 位址搬進技術資訊）：留在 #329 殘項（ClaimPage 邏輯不動；位址目前只進 logcat，不上主畫面，PR 2 已做）。

### 2.7 待辦與生命週期的接續（B M-4、A m5）

- 「節點加入網路沒有做完」：摘要表裡 `joining` 的成員，**只有**在它的 `last4` 非空、而且剛好對上這支手機唯一一筆 `node/` 紀錄時才成待辦；`last4` 空或對上多筆 → 不成待辦、記一行。點下去 = 4.1 預設勾那一台、目標 = 那筆網路。
- 「建立網路沒有確認完」：有 net、自己是建立者、`applied = false` → 待辦，點下去 = 單台「檢查網路」。

## 3. 介面

### 3.1 擁有權

| 資源 | 唯一的寫入者 | 只讀 |
|---|---|---|
| session 佔用（建網） | `NetworkRun`（按開始時拿、離開結果頁時放） | `NodeLink`（停讀）、`BleGate`、`RecordWriter`（驗 token） |
| `lease.hold()`（進行中） | `NetworkRun`（開始到離開結果頁） | 登記表 |
| 位址備忘、節點狀態 | `NodeLink`（含 `loginFor` 裡的 `core.LoginFor`） | 首頁、節點頁 |
| 一條 GATT 連線 | 登入嘗試中：`NodeLink.loginFor`；交接後：`OwnerConsole`（`LoginHandoff`） | — |
| `OwnerSession` | 交接後：`OwnerConsole`（`h.close()` 時丟掉） | — |
| net 紀錄（新頁面） | `OwnerConsole` 經 `RecordWriter` | 摘要表、`NetworkRun` 的重讀 |
| net / mnet / mpend（舊控制台、`ClaimRecords`） | 舊程式（現況，D2） | 同上 |
| 網路摘要表 | `NodeLink` | 首頁、節點頁、3.5 / 3.6、4.1 |
| `keepScreenOn` | `NetworkRun`（等待開始時開，`finally` 關） | — |
| `ui/state-v1` 暱稱 | `UiState` | 首頁、節點頁 |
| `ClaimPage` 的原始佔用 | `ClaimPage`（現況） | — |

一次只有一個佔用（§4.4），所以舊控制台、`ClaimPage`、`NetworkRun` 不會同時寫。

### 3.2 契約

| 介面 | 寫 / 讀 | 有效時 / 格式 | 缺、過期、壞掉 | 誰寫得到 |
|---|---|---|---|---|
| `NodeLink.loginFor` | `NodeLink` / `NetworkRun` 經 `OwnerConsole` | 呼叫者持有登記表目前的 session 佔用 | 不是 → `NoLease`；60 s 沒找到 → `notFound`；身分不符 → `identity`（並寫首頁） | app 內 |
| `LoginHandoff` | `NodeLink` 交出 / `OwnerConsole` 持有 | 交接後到 `close()` | 連線斷 → `OwnerConsole` 得到 `unclear` / `notSent`，`close()` 冪等 | app 內 |
| `ConsoleResult` | `OwnerConsole` / 新頁面 | 每個請求一個 | 例外原文只進技術資訊 | app 內 |
| 網路摘要表 | `NodeLink` / UI | 代號最新的那一次 | 計算中 / 列不出來 → 中性按鈕；打不開的一筆 → 標記，不當成沒有 | 紀錄檔：app 私有目錄 |
| 建立閘門 | `NetworkRun` 開始時列檔 | 佔用下、當下 | 列檔例外 → 不開始；任何檔案 → 不建立 | 同上 |
| 節點的回答 | 節點 / `OwnerConsole` | 解得開的 session 訊框 | Rust 拒絕句、結果不明、還沒送出 | 被入侵的節點：只能影響共用 net 紀錄裡它自己的成員項（國家、加入中），句子經 Rust 組字；不能改金鑰（§6） |
| `ClaimDone` | `ClaimPage` pop / 首頁 | 認領成功 | 沒有（返回或失敗）→ 首頁不開 3.2 | app 內 |

### 3.3 生命週期

| 情況 | 現在 | PR 3 之後 | 測試 |
|---|---|---|---|
| 安裝 / 第一次 | 第 6 列開舊控制台 | 0 檔 → 「建立網路」→ 新頁 | T-N2 |
| 開始 | — | 4.1 不拿佔用；按開始才拿 | T-M1(a) |
| 正常結束 | — | 離開結果頁：`close` → `keepScreenOn` 關 → 釋放；摘要表重算 | T-M1(b) |
| 建立做到一半被殺（net 已寫、未套用） | 舊控制台按「檢查網路」 | 待辦「建立網路沒有確認完」、第 6 列「檢查網路」 | T-M2(b) |
| 加入做到一半被殺 | 一次一台 | 待辦（只在 `last4` 唯一對上時）；沒開始的沒有紀錄、第 6 列給按鈕 | T-M2(a) |
| 等待中切背景 / 關螢幕 | 照逾時走 | `keepScreenOn`；佔用中不自動讀；回來接著等 | T-M1(c)、R-7 |
| 藍牙關 / 權限收回 / 金鑰失效 | `[LINK_LOST]` | 整個流程停，顯示 2.3 / 2.2 / 2.4 的原因，不問繼續 | T-M1(d) |
| 節點重開 / 斷線 | 結果不明 | `unclear` → 結果頁「檢查網路」或「再試這一台」 | T-M1(e) |
| 佔用被收回（`pageGone` 420 s） | — | `leaseLost` → 整個流程停 | T-M1(f) |
| dev2 同時讀同一台 | — | 那一台 `noLink`（文字含「另一支手機」，T-L2）→ 問繼續 / 停 | T-M1(g) |
| 升級 / 回退 / 降級 | — | 紀錄格式不變（同一個 Rust 寫入）；舊版 app 讀得到新版寫的紀錄 | 不需要新測試 |
| 平台 | Android 12+ | 同 | — |

### 3.4 佔用與重入（A-M1）

| | 舊控制台（不動） | 新頁面 |
|---|---|---|
| 重入擋法 | `_busy`（= `lease.hold()`） | `OwnerConsole._inFlight`（只擋重入，和佔用無關） |
| 進行中 | `_busy` | `NetworkRun` 從開始到離開結果頁持有一個 `lease.hold()` |
| 寫入 | `_underLease`（`rawUse.lease.hold()`） | `RecordWriter.writeCas(lease, …)`，`lease` = `NetworkRun` 的那一個 |
| 頁面消失（不該發生：`PopScope`） | `dispose` 完成等待中的回答 | `lease.pageGone()` → hold 撐到流程結束（最多 420 s）→ 寫入照樣做完 |

## 4. 和設計不同的地方

- **D1 認領留在 `ClaimPage`（原始佔用）、只換樣式**（設計 §5.3 寫 PR 3 改走 `BleGate` / `RecordWriter`）。安全性和 PR 1 / 2 相同（一次一個佔用）。新畫面因此不給步驟清單與經過時間（設計 §5.3 的「認領期間顯示步驟清單與經過時間」縮掉，寫進 #329 殘項）。`ClaimPage` 改走 `BleGate` 的工作也寫進殘項，掛 PR 6。
- **D2 舊控制台照舊**（不經 `RecordWriter`）：PR 6 刪掉。新增原始碼鎖：`lib/src/flows/`、`lib/ui/` 不准出現 `storeWriteCas` / `storeWriteSealed` / `storeRemove` / `storeKeepCopy`（T-G5(b) 縮小版）。
- **D3 隊員路徑、看申請**（設計 PR 3 範圍裡第 6 列只有 mnet / mpend 的入口）：PR 3 仍開舊控制台（dev 版），field 版不顯示按鈕；PR 5 換。

## 5. 假設與證據

| 假設 | 證據 / 怎麼確認 |
|---|---|
| A1 `loginFor` 能處理剛認領完的節點（N9） | core2–core5 的 sim 測試（core 層）+ 本 PR 的端到端 T-L17（驅動器 + 假 `BleGate`）；真機 R-7 |
| A2 `HandoffProber` 的步驟迴圈和 `SessionProber` 一樣 | 同一份程式碼抽成共用函式；`SessionProber` 現有測試不改判定 |
| A3 建立回來後紀錄已套用（A18） | ⚠️ 真機確認；沒有套用時自動檢查一次 |
| A4 頁面開著時佔用沒有上限 | lease.dart:72-102 |
| A5 被入侵的節點只能改共用 net 紀錄裡自己的成員項 | ⚠️ 開工時讀 join2flow.rs 的加入回應處理確認，附行號進 PR；不成立就寫進 §6 |

## 6. 安全

- **資產**：擁有者 / 管理者金鑰（Keystore，不變）、net 紀錄（密封，不變）、節點的網路設定、隊伍不分裂（錯誤的「建立」要重燒節點才能恢復）。
- **輸入面**：網路名稱（Rust 檢查）、暱稱（`UiState` 過濾）、勾選的節點（只能是 `node/` 紀錄的 id）。沒有新的平台方法、檔案路徑、匯出元件。
- **遠端 BLE / 惡意廣播**：登入照 `core.LoginFor` 的 8 s msg2 預算與「不是 Y」備忘，安靜的裝置吃不掉 60 s；身分不符結束那一台並寫首頁。
- **被入侵的節點**：每一台加入都 CAS 同一筆 net 紀錄（成員表、`applied`、國家）；被入侵的節點能影響它自己那一項，能用國家 / 加回問題對使用者發問（都要使用者同意）；不能改金鑰（A5 開工時附證據）。每一台開始前重讀紀錄。
- **本機無權限 app**：沒有新的入口。
- **我們自己的錯**：建立閘門（列檔、佔用下、fail-closed）；佔用語意（§3.4）；原始碼鎖（D2）。
- **秘密**：`OwnerConsole` 只寫種類、代碼、後四碼，不寫回答內容；位址經 `NodeLink.mask`。舊控制台的 `_say` 會把回答寫進 logcat（現況，不在本 PR 改）。
- **fail-closed**：沒有佔用 → `BleGate` 與 `RecordWriter` 拒絕；列檔失敗 → 不開始；目標網路打不開 → 不建立。

## 7. 步驟（每一步都跑全套、各自附改壞對照）

1. ✅ 舊控制台補測試（9b00ca6，改壞 5/5）。舊控制台在本 PR 不再改，這些測試保持原判定。
2. `NodeLink.loginFor` + `HandoffProber` + `acquire` 等上一個 `released`；測試 T-L17、T-L18、T-S3（端到端）、失敗嘗試會關連線。改壞：拿掉 N9 retry、身分不符不結束、失敗不關連線、`acquire` 不等 `released`。
3. `OwnerConsole`（複製）+ `ConsoleResult` + `RecordWriter` 寫入 + 原始碼鎖；測試：重送只一次、結果不明 / 還沒送出、逾時、國家問題期間不計時（時鐘推 400 s 再答）、`ended` 放掉 session、`NoLease` → `leaseLost`。改壞各一。
4. 網路摘要表（列檔決定有沒有、代號計數、計算中）+ 首頁第 6 列與待辦改用它；T-L19、T-N2（含只有 mnet / mpend / 打不開 / 列不出 / 計算中）。改壞：用解密結果決定有沒有 → FAIL。
5. `NetworkRun` + 4.1–4.5 頁；T-M1(a)–(g)、T-M2(a)(b)、T-C2 / T-C3。改壞：建立者未套用時繼續、前提類問繼續、換台不等關連線、對話框返回當繼續。
6. `ClaimPage` 換樣式 + `ClaimDone` + 3.2 暱稱 + F41 `PopScope`；`claim_*` 測試不改判定；T-C3、T-V1（暱稱 24 / 25）。
7. 首頁、節點頁、3.5 / 3.6 接線；兩位審查（程式）；真機。

## 8. 真機（要使用者同意；開始前另列副作用）

- **從零**：把 02、04 弄回未認領（現有 `scripts/dv/prov-bench-s0-254.sh unclaimed`，11-16 對 02 做過；會清掉節點的擁有者與網路設定），手機上忘掉兩筆紀錄（「從這支手機移除這台節點」）。
- 情境 1a：新增 04 → 建立網路（一台）→ 新增 02 → 加入（第二台，從節點頁或第 6 列）。情境 1b：兩台一起勾、多台流程。
- 每條各做一次設計 R-7 的三種中斷（關藍牙再開、節點重開、切背景），記「正在連到節點…」的秒數（10 次 9 次 ≤ 20 s）。
- A18（建立回來是否已套用）。
- 手機 VPN 會擋軟體更新的傳送（11-16 發現），不影響建網（建網只走藍牙）。

## 9. PR 內文要寫明的限制

- 手機 Wi-Fi（5.6）在 PR 4，所以「手機上的 TAK 透過節點通訊」還不行。
- 隊員路徑只有 dev 版、還在舊控制台（PR 5）。
- field 版現在跑不起來（#255），所以「別人的手機」= 安裝 dev 版。

## 10. 要使用者決定的

無（D1–D3 是技術細節）。真機場次開始前取得同意。

## 11. v1 審查的對應

| 審查 | 處理 |
|---|---|
| A-B1 / B-B1 登入 | §2.1（`loginFor` 驅動器、交接、失敗關連線）；步驟 2 的測試與改壞 |
| B-B2 建立條件 | §2.3 建立閘門、§2.4 列檔決定、§2.5 入口表 |
| A-M1 佔用 / 重入 | §3.4 |
| A-M2 / B-M-2 搬移邊界 | 改成複製（§2.2），舊控制台不動；新程式各條時序在步驟 3 各有測試與改壞 |
| A-M3 / B-M-1 多台迴圈 | §2.3 狀態機、停止規則、目標網路只決定一次 |
| A-M4 摘要表 fail-open | §2.4 |
| A-M5 / B-M-3 認領 | §2.6（原地換樣式、`ClaimDone`、交接、F41；S10 留殘項） |
| A-M6 入口 | §2.5 |
| A-M7 真機 | §8 |
| A-M8 結果契約 | §2.2.1 |
| B-M-4 生命週期 | §2.7、§3.3 |
| B-M-5 / A-m7 負向對照 | §7 每一步各自的改壞；國家問題用推時鐘；T-M1 改驗事件順序 |
| B-M-6 / A-m8 擁有權表 | §3.1 補 `keepScreenOn`、hold、連線、session |
| A-m1 | §1 P2 照實寫 |
| A-m2 權限對話框 | `loginFor` 不呼叫 `blePermissions`；沒有權限 = 前提類，整個流程停（§2.3） |
| A-m3 自己 close 送 false | `OwnerConsole` 關連線前先取消監聽（§2.2 的差別 1、步驟 3 測試） |
| A-m4 / B-m-5 4.1 | §2.3（按開始才拿、已在網路的不能勾） |
| A-m5 / B-M-4 last4 | §2.7 |
| A-m6 / B-m-6 原始碼鎖 | §4 D2 |
| A-m9 / B-m-2 log | §2.2 差別 6、§6 |
| B-m-1 P7 | §1 P7 |
| B-m-3 / A 安全 | §6、A5 |
| B-m-4 亂序 | §2.4 代號計數 |
| B-m-7 dev2 | §3.3 |
| B-m-8 `Refused` / `NoLease` | §2.2.1 `leaseLost` |
