# #329 PR 3 實作計畫 v3：新增節點、建立 / 加入 / 檢查網路

上層設計：`docs/design/329-app-uiux.md`（v12.1，已合併）§4.1、§4.3.8、§4.3.9、§4.4、§4.7、§5.1、§5.3、§5.4、§7、§9.1、§12。main = 29b0085。

**版本紀錄**
- v1：兩位審查都 REJECT（A：1 BLOCKER / 8 MAJOR；B：2 BLOCKER / 6 MAJOR）。
- v2：C APPROVE-WITH-CHANGES（0 / 5 MAJOR / 11 MINOR）；D REJECT（1 BLOCKER / 4 MAJOR / 14 MINOR）。
- v3（本版）：逐條對應見 §12。主要改變：
  1. 建立失敗後的出口「重新建立」（§2.8）。
  2. `loginFor` 自己掃描、自己排程，交接改成先建好收件匣再交出（§2.1）。
  3. 結果契約改成結構化欄位，佔用遺失只看 `lease.valid`（§2.2.1）。
  4. 4.1 自己列檔決定表單，閘門寫成表並各有改壞（§2.3）。
  5. 成員帶完整 device id，精確對到 `node/` 紀錄（§2.4）。

## 1. 事實（原始碼，main 29b0085）

| # | 事實 | 證據 |
|---|---|---|
| P1 | 舊控制台的請求機制與它共用的欄位、旁路旗標 | nodes.dart:194-589、:687-716、:750-797、:1574-1622 |
| P2 | 這組機制綁頁面；`_say` 會 `debugPrint`；頁面不在時 `_pickNet` 回第一筆 | nodes.dart:157-160、:277、:405、:520、:614 |
| P3 | 舊控制台與 `ClaimRecords` 的紀錄寫入不經 `RecordWriter`；`UiState` 合法直接寫 `ui/state-v1` | nodes.dart:261、:467、:764、:1026、:1290；claim_records.dart:43-53；ui_state.dart:228、:232 |
| P4 | `_busy` = 原始佔用的 hold；`_ask` 用 `_busy && !held` 擋重入 | raw_use.dart:25-44；nodes.dart:520-529 |
| P5 | `BleGate.scan(token)`（每 30 s 最多 4 次）、`connect(token, addr)`（一次一條）；`GateLink` 在連線斷掉**或**佔用收回時都丟 `Refused` | ble_gate.dart:84-86、:185、:226-231 |
| P6 | `RecordWriter.writeCas / keepCopy / remove` 只認登記表目前的佔用 | record_writer.dart:27-60 |
| P7 | `core.LoginFor`：位址只從 `onScan` 收到的裡面挑；同位址隔 6 s 可再試；N9；身分不符寫首頁；寫 `isY` / `notY`；60 s；藍牙 / 權限 / 金鑰經 `setRadio` 結束成 `precondition`。`LoginEnd` = ok / identity / refused / notFound / precondition | core.dart:282-292、:628-748 |
| P8 | 佔用期間 `reg.nodeLinkToken == null`；`_run` 與掃描都用它；`_pump` 會砍掉不是自己排的嘗試 | node_link.dart:157、:215、:260、:296 |
| P9 | `SessionProber` 決定結果後丟掉後續訊框，`finally` 取消訂閱並 dispose session；訊框各自 `run`，沒有排隊。舊控制台用 `asyncMap` 讓訊框一個接一個 | prober.dart:133-134、:147、:160-175；nodes.dart:340-347 |
| P10 | `openRawPage` 推 `MaterialPageRoute<void>`，pop 的值被丟掉 | raw_use.dart:73-82 |
| P11 | `ClaimPage` 自己做藍牙、進度只有 `_say`；開發用的貼上 / 16 進位輸入在每個版本都顯示（只有 `_paste` 在 field 版拒絕） | claim.dart:154-157、:212-472、:500-512 |
| P12 | 9b00ca6 已替舊控制台補四條路徑的測試（改壞 5/5） | 9b00ca6 |
| P13 | 加入要求網路已套用 | join2flow.rs:340-341 |
| P14 | Rust `list_kind` 讀不到目錄回空清單、濾掉 `.` 開頭的檔名；store 暫存檔是 `.<name>.tmp-…` | owner.rs:41-47；store.rs:20、:118 |
| P15 | `released` 非同步；新佔用在讀完紀錄前拿到時，`writtenAt` 不設 → N9 視窗失效 | node_link.dart:171-195；core.dart:703-705 |
| P16 | `MemberView` 有 `name`、`last4`、`joining`、`approved`、`creator`、`prevCountry`、`dacHash`，**沒有 device id**；`net_summary` 手上有 `m.device_id`。pending 紀錄（`list: None`）的成員來自 `v1_members`，device id 是 None、建立者的 `name = "node-<last4>"` | owner.dart:243-270；owner.rs:79-80、:116、:1080；netrec.rs:212、:375-377、:391-396 |
| P17 | `request_member_join` 只在 dev 版本 | owner.rs:1213-1215 |
| P18 | 首頁第 6 列現況：`net \|\| mnet \|\| unknown → 加入網路`，動作都開舊控制台 | home_logic.dart:92-96；home_page.dart:129-151、:170-171 |
| P19 | 建立：Rust 先寫 pending 的 net 紀錄再送出；失敗後紀錄留著（「下次會用新的網路編號」）；Rust 沒有丟掉一筆 net 的入口；`store_keep_copy` 只支援 `node/`、`claim-pending/` | owner.rs:1451-1458、:1500-1524；claim.rs:134-141 |
| P20 | 建立回來：收到 Applied 時 Rust 直接寫已套用的紀錄；結果不明（ReadInfo）時 Rust 自己做一次檢查；只剩寫入失敗或檢查也讀不到時停在未套用 | owner.rs `join_step` Applied 分支 → `persist_step`、ReadInfo → `check_network()` |
| P21 | 被入侵的節點加入時只能換掉 net 紀錄裡**它自己**的成員項（key = 驗證過的 node_cert 的 dac_hash）；國家只收兩個大寫字母；`mesh_addr` 只在測試 feature 寫 | join2flow.rs:285-288、:345-365、:445-458；teamview.rs:16 |
| P22 | 加入的結果都以 answer 回來，以標籤區分：`[JOINED]`、`[REQ_FAIL]`、`[JOIN_STATE]`（Rust 判斷的結果不明）、`[COUNTRY]`；Rust 在已套用時設 `pollLink` | owner.rs:498-566；nodes.dart:315 |
| P23 | `UiState` 沒有設定暱稱的方法（只有解析與 `forget`） | ui_state.dart:95-97、:197 |
| P24 | `StatusView.netId`（info key 10）與 `nodeState` 可得到「讀到的節點在哪個網路」 | owner.dart:559-560；home_logic.dart:31 |

## 2. 做法

### 2.1 `NodeLink.loginFor`（設計 §4.3.9）

- `Future<LoginResult> NodeLink.loginFor(Lease lease, String id, {bool clearNotY = false})`。`lease` 不是登記表目前的 session 佔用 → 丟 `NoLease`。
- 開始前：
  - 即時讀一次 `KeyAbilities`（登入用的金鑰）；不能用 → `precondition(keys)`。
  - 檢查 `core.blocked`；被擋 → `precondition(why)`。
- **驅動器自己的狀態**：`_lfScan`、`_lfAttempt`、`_lfLink`、`_lfTimer`，不碰自動讀取的 `_attempt` / `_link` / `_timer`。
  - 自己掃描：`gate.scan(lease.token, addr → LoginFor.onScan(addr))`。
  - 照 `LoginFor.wakeAt` 自己排計時；`radio()` 改變時叫醒它，前提失效立刻結束。
  - 每次嘗試前檢查 `lease.valid`。
  - 結束（成功、失敗、前提）時先停掉掃描，再回傳。
- **每次嘗試**：`gate.connect(lease.token, addr)` + `HandoffProber`（§2.1.1），8 s 內沒收到 msg2 就結束那次（同自動讀取的規則）。
  - 結果交給 `LoginFor.result`。
  - 失敗的嘗試先 `await link.close()` 才試下一個；`requestMtu` / 讀 ctrl / 訂閱丟例外也一樣。
  - `keyError` → `keyErrorToRadio`（同 app_link.dart:69-70）。
- **`LoginResult`**（照 `LoginEnd`）：
  - `ok(LoginHandoff)`；
  - `identity`（core 已寫首頁狀態）；
  - `refused`；
  - `notFound`；
  - `precondition(Why)`。
- 位址備忘、節點狀態的唯一寫入者仍是 `NodeLink`。
- **限制（照實寫）**：一個不回應的位址每次花 8 s；附近有約 7 個這種位址就能吃光 60 s（設計接受的代價，§4.3.7）。

#### 2.1.1 `HandoffProber`（獨立的類別，不和 `SessionProber` 共用）

- 約 60 行，有自己的測試。`SessionProber` 不改。
- 訂閱 TX **之前**先建一個 inbox `StreamController`。訂閱的處理函式只把訊框放進 inbox。
- prober 從 inbox 讀，餵給 `OwnerSession.onFrame`，讀到 `loggedIn` 為止。
- 成功時：
  - 取消自己的 msg2 計時器與 `due` / `cancelled` 回呼；
  - **不**取消訂閱、**不** dispose session；
  - inbox 原封交出：`LoginHandoff(link, session, inbox, subscription)`。
- 交接之間到的訊框留在 inbox 裡，不會丟。
- `LoginHandoff.close()`（冪等）：先取消 `link.state` 的監聽（避免自己關連線時送出的 false 被當成斷線，A v1 m3）→ 取消訂閱 → `await link.close()` → dispose session。

#### 2.1.2 `acquire` 等上一個釋放

- `released` 回呼裡「讀紀錄 + `core.releaseLease`」那一段的 future 存起來。
- `NodeLink.acquire` 先 await 它（上限 5 s，和「正在結束上一個讀取…」同一個上限），**之後**才檢查 `reg.current`。
- 網路摘要表的計算**不在**這段裡（平台呼叫不回來不會卡住 `acquire`）。
- 這修掉 P15 的 N9 視窗失效。

### 2.2 `OwnerConsole`：從舊控制台複製，只給新頁面

- 新檔 `lib/src/flows/owner_console.dart`。**舊控制台不改**，PR 6 刪舊控制台時重複消失。
- **複製清單**：
  - 步驟迴圈：`write`、`sign` / `signAdmin`、`persistNet`、`confirmCountry`、`wait`、`confirmRemoved`、`answer`、`ended`、處理訊框時的例外；
  - `ask`：逾時、unclear / notSent、寫入失敗重新登入只重送一次、`ended` 放掉 session、重入；
  - 動作：`makeNetwork`（含即時的 `KeyAbilities.refusal(makeNetwork)`）、`joinNetwork(rel)`、`confirmNetwork(rel)`（含它的逾時句）、`linkCheck`、`sendUpdateFor(rel)`（含 `_sendUnclear`）。
- **不複製**：邀請、隊員、移除、離開、軟體更新、狀態頁。
- **和舊控制台的差別**（逐條寫進檔頭註解）：
  1. 登入：呼叫 `NodeLink.loginFor`；重新登入前先 `await` 舊的 `LoginHandoff.close()`。訊框用 `inbox.stream.asyncMap` 一個接一個處理（同舊控制台）。
  2. 寫入：`RecordWriter.writeCas(lease, …)`；`writeCas` 丟 `NoLease` 時仍呼叫 `persistFailed`（讓 Rust session 一致），但結果標 `leaseLost`。
  3. 選網路：不在裡面挑，`joinNetwork` / `confirmNetwork` 吃 `rel`。
  4. 對頁面回傳結構化結果（§2.2.1），不用 `_say`。
  5. 重入旗標 `_inFlight` 和佔用分開；佔用由 `NetworkRun` 持有（§3.4）。
  6. 文字紀錄只寫種類、代碼、後四碼（位址經 `NodeLink.mask`），不寫回答內容。
  7. 國家問題：停計時 → 注入的 `askCountry(question)` → 重新計時（同 nodes.dart:276-291）。被移除過：注入的 `askReAdd(text)`，同意 → 重讀紀錄、`removedConfirmed: true` 重來。
  8. 簽章 / 封裝（sign、seal）經包裝：平台丟金鑰錯誤時記 `keyFail` 旗標並 `keyErrorToRadio`，結束時一起回傳。
- `console.close()` 由 `NetworkRun` 呼叫（console 自己知道它目前的 `LoginHandoff`，重新登入後 `NetworkRun` 不必持有過時的 handoff）。

#### 2.2.1 結果契約（`ConsoleResult`，不解析中文句子）

| 種類 | 怎麼判定 | 新頁面顯示 |
|---|---|---|
| `joined` | 加入的 answer 帶 `pollLink`（P22） | 「已加入」→ 接著連線檢查 |
| `made` / `confirmed(applied)` | 用 `rel` 重讀紀錄的 `applied` | 已套用 / 還沒確認 |
| `rustUnclear(line)` | answer 的標籤是 `[JOIN_STATE]`（Rust 的機器標籤，不是中文） | 「結果不明」+「再試這一台」 |
| `refused(line)` | String 例外，或 answer 標籤 `[REQ_FAIL]` | Rust 原句（去標籤） |
| `cancelled` | 國家 / 加回的問題選「不要」，或 answer 標籤 `[COUNTRY]` 且已取消 | 「已取消，沒有寫入、沒有送出」 |
| `unclear` | 送出後斷線 / 逾時，`SendTrack.wrote` 為真，`lease.valid` 仍為真 | 「結果不明」+ 下一步（§2.3 結果頁） |
| `notSent` | 寫入之前斷線，`lease.valid` 為真 | 「還沒有寫入或送出，可以再試一次」 |
| `timeout` | 沒有 unclear 參數的請求（`confirmNetwork`）逾時 | 「節點沒有回應」 |
| `ended(line)` | `ended` 步驟 | Rust 原句 |
| `frameError` | 處理訊框時丟例外 | 同 `unclear` |
| `busy` | 重入 | 不顯示（不該發生；記一行） |
| `noLink(LoginResult)` | 登入失敗 | 依原因的固定句（設計 §4.3.5） |
| `leaseLost` | **`!lease.valid`**（不看例外型別，P5） | 「這個操作被中斷了」 |
| `keyFail` | 包裝記的旗標 | 2.4 的句子 |

- 例外原文只進技術資訊。
- `GateLink` 的 `Refused` 在 `lease.valid` 時 = 斷線，照 `unclear` / `notSent` / 重送一次處理。

### 2.3 多台建網：`NetworkRun`

新檔 `lib/src/flows/network_run.dart`（邏輯）+ `lib/ui/network_pages.dart`（4.1–4.5）。

**4.1 開頁時自己列檔**（不解密、不拿佔用，規則同 §2.4 的列檔）。依結果決定顯示哪一種：

| 列檔結果 | 4.1 |
|---|---|
| 列不出來（`FileSystemException`，不是「目錄不存在」） | 「讀不到手機裡的網路紀錄」，沒有「開始」 |
| net / mnet / mpend 都沒有 | 建立表單：名稱（預設 `Batman`）、頻道（進階 40 / 42） |
| 有 net、其中有打得開而且已套用的 | 加入表單：「加入哪一個網路」（只列這些；一筆就不問） |
| 有 net、但都打不開 | 現有的重裝警告句，沒有「開始」 |
| 有 net、打得開、但沒有已套用的 | 不顯示表單，轉到 §2.8（檢查網路 / 重新建立） |
| 只有 mnet / mpend | 不顯示表單，顯示 §2.5 那一列的句子（dev 版給舊控制台按鈕） |

**節點清單**（`node/` 紀錄）：

- 加入模式：讀到在網路裡、而且 `netId` 不是目標（或讀不到 `netId`）→ 不能勾；`netId` 是目標 → 可勾，標「補完加入」；沒讀到 → 可勾，標「目前讀不到」。預設勾「剛讀到、還沒加入網路」的。
- 建立模式：在網路裡的節點不能當建立者。建立者預設是剛讀到、還沒加入網路的那台（不是清單第一台）。
- 從待辦或節點頁進來：那一台預設勾、一定可勾。
- 至少一台。

**按「開始」**：

1. 拿 session 佔用（拿不到 →「另一個操作還在進行：<名稱>」）。從這裡到離開結果頁，`NetworkRun` 持有佔用與一個 `lease.hold()`。
2. 在佔用下重新列檔，照**建立閘門表**：

   | 佔用下的列檔 | 4.1 是建立表單 | 4.1 是加入表單 |
   |---|---|---|
   | 列不出來 | 不開始 | 不開始 |
   | 三種都沒有 | 建立 | 不開始，請重開 4.1 |
   | 有 net | 不開始，請重開 4.1 | 目標仍在、打得開、已套用 → 加入；否則不開始 |
   | 只有 mnet / mpend | 不開始，顯示隊員的句子 | 同左 |

   不開始時什麼都不送、不寫，放掉佔用。
3. `PopScope` 擋返回、`keepScreenOn` 開（等待期間）。

**每一台**（照設計 §5.4 表）：

1. `console` 登入那一台（`loginFor`）。
2. 建立者：`makeNetwork` → 用 `rel` 重讀紀錄。
   - 已套用 → 繼續。
   - 未套用 → **整個流程停**，結果頁轉 §2.8。Rust 在結果不明時已自己檢查過一次（P20），不再重複自動檢查。
3. 加入者：目標已套用（開始時確認過；每台開始前用 `rel` 重讀，拿新的 generation 與內容）→ `joinNetwork(rel)`（國家 / 加回問題照 §2.2）→ `sendUpdate` 時 `sendUpdateFor(rel)` → `joined` 時連線檢查（每 10 s、最多 120 s）。

**停止規則**：

- 任何失敗之後**先看 `core.blocked`**（藍牙關、沒有權限、金鑰；斷線可能比 `setRadio` 先到）。被擋 → 整個流程停，顯示 2.3 / 2.2 / 2.4 的原因，不問繼續。
- `leaseLost` → 整個流程停。
- 建立者失敗或未套用 → 整個流程停。
- 加入者的其他失敗（`noLink`、`refused`、`rustUnclear`、`unclear`、`notSent`、`timeout`、`ended`、`frameError`）→ 問「繼續下一台 / 先停在這裡」。對話框被返回鍵關掉 = 停。

**結果頁**：

- 進入結果頁時：`console.close()`（最後一台的連線放掉，那台恢復廣播）→ `keepScreenOn` 關。佔用照設計 §5.4 留到離開結果頁。
- 逐台列「完成 / 失敗原因 / 還沒做」。
- 結果頁上的「再試這一台」（加入者的不明、還沒送出、找不到）、「檢查網路」（轉 §2.8）重用同一個佔用。
- 離開結果頁：放 hold → `lease.release()`。

**流程中頁面消失**（雖然有 `PopScope`）：做完當前請求，不開始下一台，不彈對話框，`console.close()`，放 hold。

### 2.4 網路摘要表（設計 §4.3.8）

- **列檔**（Dart `Directory`，和 Rust `list_kind` 同規則）：
  - 濾掉 `.` 開頭的檔名；
  - 目錄不存在 = 空；
  - 其他 `FileSystemException` = 列不出來（⚠️ `Directory.exists` 遇到非 ENOENT 的行為，開工時用測試確認）。
- **有沒有紀錄只看列檔**：`netFiles`、`mnetFiles`、`mpendFiles`、`pendingClaims`、`listFailed`。
- **解密只用來取**每個網路的名稱、`applied`、成員。一筆解不開 → 標「打不開」、記一行路徑。
  - 金鑰閘門錯誤**不**走 X26：摘要表只影響顯示；登入與建網自己會碰到金鑰並走 X26。
- **成員帶 device id**：Rust `MemberView` 加 `device_id` 欄位（`net_summary` 已經有 `m.device_id`，改一行 + 一個測試）。
  - 加入中、已套用的成員可以精確對到 `node/<id>`。
  - pending 紀錄的建立者沒有 device id（P16），用 `name` 的 `node-<last4>` 對手機唯一一筆 `node/` 紀錄；對不上或多筆 → 讓使用者從節點清單選。
- 只保留代號最新的一次計算結果。計算中 → 第 6 列用中性的「加入網路」並顯示「正在讀取網路紀錄」，不顯示「建立網路」。
- 「建立網路」按鈕只在：列得出來、三種檔都是 0。這只決定顯示；真正的閘門是 §2.3 的建立閘門表。

### 2.5 入口去處表

| 入口 | 條件（摘要表） | dev / dev2 | field |
|---|---|---|---|
| 第 6 列 | 計算中 / 列不出來 / 有打不開的 | 中性「加入網路」→ 4.1（4.1 自己列檔決定） | 同 |
| 第 6 列 | 0 檔 | 「建立網路」→ 4.1 建立表單 | 同 |
| 第 6 列 | 有已套用的 net | 「加入網路」→ 4.1 加入表單（排除已在待辦「加入沒有做完」裡的節點，設計 §5.1） | 同 |
| 第 6 列 | 有 net、沒有已套用的 | 「檢查網路」→ §2.8 | 同 |
| 第 6 列 | 只有 mnet | 「加入網路」→ 舊控制台（隊員加入，PR 5 換） | 只顯示句子，沒有按鈕（P17） |
| 第 6 列 | 只有 mpend | 「看我的申請」→ 舊控制台（PR 5） | 只顯示句子 |
| 第 6 列次要 | 0 檔 | 「我是隊員，加入隊長的網路」→ 舊控制台（PR 5） | 不顯示 |
| 首頁「新增節點」 | — | 3.x（§2.6） | 同 |
| 3.5（0 檔） | — | 主要「建立網路」；次要「我是隊員，加入隊長的網路」（同第 6 列次要） | 主要同；次要不顯示 |
| 3.6（有 net） | — | 主要「加入網路」；次要「再加一台」 | 同 |
| 節點頁「還沒加入網路」 | 同第 6 列 | 對象預設勾這一台 | 同 |
| 待辦「節點加入網路沒有做完」 | §2.7 | 4.1 加入表單，目標 = 那筆網路、那一台預設勾 | 同 |
| 待辦「建立網路沒有確認完」 | §2.7 | §2.8 | 同 |

### 2.6 新增節點：`ClaimPage` 原地換樣式（D1）

- **只換 `build` 的樣式**；`_claim` / `_find` / `_recover` 不動，`claim_*` 測試不改判定。不給步驟清單與經過時間（設計 §5.3 縮掉的部分寫進殘項）。
- 開發用的貼上 / 16 進位輸入在 `!devTrust` 時不顯示（設計 §5.3；P11 現況每版都顯示）。
- `openRawPage` 改成泛型 `openRawPage<T>`，回傳 `(T? result, String? busyName)`。`openUnderLease` 跟著改，現有呼叫者不用結果，照舊。
- **`ClaimDone(deviceId)`**：
  - 認領成功、恢復成功、已有紀錄的覆寫認領成功時，都 `Navigator.pop(ClaimDone(id))`；
  - 失敗、返回、取消 → pop 沒有值；
  - 首頁收到 `ClaimDone` → 3.2 暱稱 → 3.5 / 3.6。
- **3.2 暱稱**：`UiState.setNick(id, text)`（新增）。去掉前後空白，1–24 字，拒絕 Cc / Cf / Zl / Zp（同 PR 2 的解析過濾）。空白 = 用預設「節點 <後四碼>」。
- **F41**（認領中按返回）：**不加 `PopScope`**（設計 §4.4 明文不加）。`ClaimPage` 被 pop 之後，認領照樣做完（現況），結果寫到 `AppLink.lastClaimNote`（記憶體）。首頁回來時若有，顯示一次「上一次新增節點：<結果句>」的橫幅。
- S10（BLE 位址搬進技術資訊）：留在殘項（`ClaimPage` 邏輯不動；位址目前只進 logcat，不上主畫面）。

### 2.7 待辦

- 「節點加入網路沒有做完」：摘要表裡 `joining` 的成員，用 device id 精確對到這支手機的 `node/<id>`；對不上的不成待辦。
- 「建立網路沒有確認完」：有 net、`applied = false`。點下去 → §2.8。

### 2.8 建立沒有確認完：檢查網路 / 重新建立（D v2 B1）

**對象**：pending 那筆 net 的建立者。用 `name` 的 `node-<last4>` 對手機唯一一筆 `node/`；對不上或多筆 → 讓使用者從節點清單選。檢查是唯讀比對，對錯台只會「不符、不寫」。

**頁面**：拿 session 佔用 → 登入建立者 → `confirmNetwork(rel)`。

1. 結果 `applied` → 紀錄升級，回首頁（之後可以加入其他台）。
2. 節點**明確回報不在這個網路**（info key 10 沒有、或不是這個 net id），**而且**這筆紀錄只有建立者一個成員 → 顯示「這個網路沒有建立成功。重新建立會丟掉這筆紀錄（留一份副本），再建一個新的網路」+ 按鈕「重新建立」。
   - 按下 → `RecordWriter.keepCopy(net/<id>)`（到 `forgotten-net/`）→ `RecordWriter.remove(net/<id>)` → 回 4.1（現在是 0 檔 → 建立表單）。
3. 讀不到建立者、回答不明、或紀錄裡還有別的成員 → **不給重新建立**（fail-closed），句子「把建立網路的那台開機放在旁邊，再按『檢查網路』」。

**為什麼不能只放寬閘門**（「全部 pending 就可以建」）：結果不明時建立者可能其實已經套用，會分成兩個網路。

**Rust 改動（最小）**：
- `store_keep_copy` 加 `net` → `forgotten-net`（claim.rs:134-141）。
- `RECORD_KINDS` 加 `forgotten-net`（simple.rs:31-32），手機只剩這種副本時也算「有紀錄」，金鑰不會被重新產生。
- 各加一個測試。

## 3. 介面

### 3.1 擁有權

| 資源 | 唯一的寫入者 | 只讀 |
|---|---|---|
| session 佔用與 `lease.hold()` | `NetworkRun` / §2.8 頁（按開始時拿、離開結果頁時放） | `NodeLink`（停讀）、`BleGate`、`RecordWriter` |
| `loginFor` 期間的掃描與嘗試連線 | `NodeLink`（`_lf*` 欄位） | — |
| 位址備忘、節點狀態 | `NodeLink` | 首頁、節點頁 |
| 交接後的 GATT 連線、TX 訂閱、inbox、`OwnerSession` | `OwnerConsole`（`console.close()` 時放） | — |
| net 紀錄（新頁面） | `OwnerConsole` 經 `RecordWriter.writeCas`；§2.8 經 `keepCopy` + `remove` | 摘要表、`NetworkRun` 的重讀、4.1 的列檔 |
| `forgotten-net/` | §2.8 經 `RecordWriter.keepCopy` | 啟動檢查（`RECORD_KINDS`） |
| net / mnet / mpend（舊控制台、`ClaimRecords`） | 舊程式（D2） | 同上 |
| 網路摘要表 | `NodeLink`（代號最新的一次） | 首頁、節點頁、3.5 / 3.6 |
| `keepScreenOn` | `NetworkRun`（等待開始時開；進結果頁、例外、頁面消失時在 `finally` 關） | — |
| `ui/state-v1` 暱稱 | `UiState.setNick` | 首頁、節點頁 |
| `AppLink.lastClaimNote` | `ClaimPage`（寫）/ 首頁（讀後清掉） | — |
| `ClaimPage` 的原始佔用 | `ClaimPage`（現況） | — |

一次只有一個佔用（§4.4）：舊控制台、`ClaimPage`、`NetworkRun`、§2.8 頁不會同時寫。

### 3.2 契約

| 介面 | 寫 / 讀 | 有效時 / 格式 | 缺、過期、壞掉 | 誰寫得到 |
|---|---|---|---|---|
| `NodeLink.loginFor` | `NodeLink` / `OwnerConsole` | 呼叫者持有目前的 session 佔用 | 不是 → `NoLease`；見 `LoginResult` | app 內 |
| `LoginHandoff` | `NodeLink` 交出 / `OwnerConsole` 持有 | 交接後到 `close()` | 連線斷 → `unclear` / `notSent`；`close()` 冪等 | app 內 |
| `ConsoleResult` | `OwnerConsole` / 新頁面 | 每個請求一個 | 例外原文只進技術資訊 | app 內 |
| 建立閘門 | `NetworkRun` 開始時列檔 | 佔用下、當下 | 列不出來 → 不開始；和 4.1 的表單不一致 → 不開始 | 紀錄檔：app 私有目錄 |
| 4.1 的列檔 | 4.1 開頁時 | 只決定表單 | 列不出來 → 沒有「開始」 | 同上 |
| 網路摘要表 | `NodeLink` / UI | 代號最新的那一次 | 計算中 / 列不出來 → 中性按鈕；打不開的一筆 → 標記，不當成沒有 | 同上 |
| `MemberView.deviceId`（新） | Rust `net_summary` / Dart | 已套用或加入中的成員 | 空（pending 建立者）→ 用 `name` 對，再不行讓使用者選 | Rust（紀錄內容由 app 寫） |
| `ClaimDone` | `ClaimPage` pop / 首頁 | 認領（含恢復、覆寫）成功 | 沒有值 → 不開 3.2 | app 內 |
| 節點的回答 | 節點 / `OwnerConsole` | 解得開的 session 訊框 | 見 `ConsoleResult` | 被入侵的節點：只能換掉它自己的成員項（P21） |

### 3.3 生命週期

| 情況 | 現在 | PR 3 之後 | 測試 |
|---|---|---|---|
| 安裝 / 第一次 | 第 6 列開舊控制台 | 0 檔 → 「建立網路」 | T-N2 |
| 開始 | — | 4.1 自己列檔、不拿佔用；按開始才拿 | T-M1(a) |
| 正常結束 | — | 進結果頁 `close` + `keepScreenOn` 關；離開時釋放；摘要表重算 | T-M1(b) |
| 建立做到一半被殺 / 建立失敗 | 舊控制台再按「建立網路」（dev 才有） | 待辦 + 第 6 列「檢查網路」→ §2.8（升級或重新建立） | T-M2(b)、T-R1 |
| 加入做到一半被殺 | 一次一台 | 待辦（device id 對上）；沒開始的沒有紀錄 | T-M2(a) |
| 加入結果不明、節點其實已套用 | 舊控制台再按「加入網路」 | 待辦 → 4.1，那一台 `netId` = 目標 → 可勾「補完加入」 | T-M2(c) |
| 等待中切背景 / 關螢幕 | 照逾時走 | `keepScreenOn`；佔用中不自動讀；回來接著等 | T-M1(c)、R-7 |
| 藍牙關 / 權限收回 / 金鑰失效 | `[LINK_LOST]` | 先看 `core.blocked` → 整個流程停，不問繼續 | T-M1(d)（含斷線比 `setRadio` 先到） |
| 節點重開 / 斷線 | 結果不明 | `unclear` / `notSent`（lease 仍有效）→ 問繼續 | T-M1(e) |
| 佔用被收回 | — | `leaseLost` → 整個流程停 | T-M1(f) |
| dev2 同時讀同一台 | — | 那一台 `noLink` → 問繼續 | T-M1(g) |
| 流程中頁面消失 | `dispose` 完成等待中的回答 | 做完當前請求、不開下一台、`close`、放 hold | T-M1(h) |
| 認領中按返回（F41） | 結果顯示在已關掉的頁面 | 首頁顯示「上一次新增節點：…」一次 | T-F41 |
| 升級 / 回退 / 降級 | — | net 紀錄格式不變；`forgotten-net/` 是新的種類：舊版 app 不認得它（不列、不刪），只是多一個資料夾，不影響舊版的判斷 | T-R2（舊版 `RECORD_KINDS` 不含它：只差在「有沒有紀錄」少算一筆，舊版只在完全沒有紀錄時才重新產生金鑰，而這時 net/ 已被刪、node/ 仍在 → 仍算有紀錄） |
| 平台 | Android 12+ | 同 | — |

### 3.4 佔用與重入

| | 舊控制台（不動） | 新頁面 |
|---|---|---|
| 重入 | `_busy`（= `lease.hold()`） | `OwnerConsole._inFlight` |
| 進行中 | `_busy` | `NetworkRun` / §2.8 頁從開始到離開結果頁持有一個 `lease.hold()` |
| 寫入 | `_underLease`（`rawUse.lease.hold()`） | `RecordWriter`，`lease` = 流程的那一個 |
| 頁面消失 | `dispose` 完成等待中的回答 | `pageGone` → hold 撐到流程收尾（最多 420 s） |

## 4. 和設計不同的地方

- **D1** 認領留在 `ClaimPage`（原始佔用）、只換樣式；不給步驟清單與經過時間；`ClaimPage` 改走 `BleGate` 寫進殘項（掛 PR 6）。安全性和 PR 1 / 2 相同。
- **D2** 舊控制台照舊（不經 `RecordWriter`）。原始碼鎖：`lib/src/flows/`、`lib/ui/`（`ui_state.dart` 除外）不准出現 `storeWriteCas` / `storeWriteSealed` / `storeRemove` / `storeKeepCopy`。
- **D3** 隊員路徑、看申請仍開舊控制台（dev），field 版不顯示按鈕；PR 5 換。
- **D4** 建立失敗的出口「重新建立」（§2.8）是設計沒有的新動作：設計沒有處理 pending 網路的死路（v2 審查 D-B1）。動作只在三個條件都成立時出現，並且留副本。

## 5. 假設與證據

| 假設 | 證據 / 怎麼確認 |
|---|---|
| A1 `loginFor` 能處理剛認領完的節點（N9） | core2–core5 的 sim 測試 + 本 PR 的端到端 T-L17（驅動器 + 假 `BleGate` + 慢的 `readRecords`）；真機 R-7 |
| A2 建立回來的未套用只剩寫入失敗或檢查讀不到 | P20（owner.rs `join_step`） |
| A3 被入侵的節點只能換掉自己的成員項 | P21 |
| A4 頁面開著時佔用沒有上限 | lease.dart:72-102 |
| A5 v1 pending 紀錄的建立者 `name` = `node-<last4>` | owner.rs:1080；⚠️ 開工時用 Rust 測試確認 `net_summary` 對 pending 紀錄回的 `name` |
| A6 Dart `Directory` 能分出「目錄不存在」和「讀不到」 | ⚠️ 開工時寫測試（權限拒絕的目錄）確認；不行就把「讀不到」當成「列不出來」（fail-closed） |

## 6. 安全

- **資產**：擁有者 / 管理者金鑰（Keystore，不變）、net 紀錄（密封，不變）、節點的網路設定、隊伍不分裂（錯誤的「建立」要重燒節點才能恢復）。
- **輸入面**：網路名稱（Rust 檢查）、暱稱（`setNick` 過濾）、勾選的節點（只能是 `node/` 紀錄的 id）。沒有新的平台方法、檔案路徑（`forgotten-net/` 是 store 內的新種類，路徑規則同其他種類）、匯出元件。
- **遠端 BLE / 惡意廣播**：8 s msg2 預算 + 「不是 Y」備忘；約 7 個不回應的位址就能吃光 60 s（設計接受）。身分不符結束那一台並寫首頁。
- **被入侵的節點**：每台加入都 CAS 同一筆 net 紀錄，但只能換掉它自己的成員項、國家只收兩個大寫字母（P21）；能用國家 / 加回問題對使用者發問（要使用者同意）。每台開始前重讀紀錄。在 §2.8 裡，它能謊稱「我不在這個網路」→ 讓使用者丟掉一筆 pending 紀錄：只在紀錄只有建立者一個成員時才可能，而那時建立者本來就是它自己，最壞是重建一個網路，不會讓已經在網路裡的其他節點分裂。
- **本機無權限 app**：沒有新的入口。
- **我們自己的錯**：建立閘門（佔用下列檔、fail-closed、每一列有改壞）；佔用語意（§3.4）；原始碼鎖（D2）；§2.8 的三個條件各有改壞。
- **秘密**：`OwnerConsole` 只寫種類、代碼、後四碼；位址經 `NodeLink.mask`。舊控制台的 `_say` 會把回答寫進 logcat（現況，不在本 PR 改）。
- **fail-closed**：沒有佔用 → `BleGate` 與 `RecordWriter` 拒絕；列檔失敗 → 不開始；目標打不開 → 不建立；§2.8 不確定 → 不給重新建立。

## 7. 步驟（每一步都跑全套、各自附改壞對照）

1. ✅ 舊控制台補測試（9b00ca6，改壞 5/5）。
2. `NodeLink.loginFor`（自己掃描、自己排程、叫醒、`lease.valid`）+ `HandoffProber` + `acquire` 等上一個 `released`。
   - 測試：T-L17（慢的 `readRecords`）、T-L18、T-S3（身分不符寫首頁）、失敗嘗試會關連線、交接瞬間的訊框不丟、persist 等待中再來的訊框依序處理、交接成功時 session 沒被 dispose。
   - 改壞：不掃描或用 `nodeLinkToken`；拿掉 N9 retry；身分不符不結束；失敗不關連線；`acquire` 不等 `released`；沿用 `result.isCompleted` 丟訊框；每個訊框各自 `run`。
3. `OwnerConsole`（複製）+ `ConsoleResult` + `RecordWriter` 寫入 + 原始碼鎖。
   - 測試：重送只一次；結果不明 / 還沒送出；逾時；國家問題期間不計時（時鐘推 400 s 再答）；`ended` 放掉 session；`Refused` 且 lease 有效 → 不是 `leaseLost`；persist 時 lease 收回 → `leaseLost` 且有呼叫 `persistFailed`；`[JOIN_STATE]` → `rustUnclear`；`pollLink` → `joined`；金鑰錯誤 → `keyFail`。
   - 改壞各一，加上原始碼鎖（新檔留一個直接呼叫 → FAIL）。
4. 網路摘要表 + Rust `MemberView.deviceId` + 首頁第 6 列、待辦改用它。
   - 測試：T-L19；T-N2（0 檔 / 已套用 / 未套用 / 只有 mnet / 只有 mpend / 打不開 / 列不出 / 計算中）；待辦精確對應。
   - 改壞：用解密結果決定有沒有；不濾 `.` 檔；計算中顯示「建立網路」；待辦只用後四碼。
5. `NetworkRun` + 4.1–4.5。
   - 測試：T-M1(a)–(h)、T-M2(a)–(c)、建立閘門表每一列、T-C2 / T-C3。
   - 改壞：建立閘門的每一列各一（改用摘要表不重新列檔、列檔例外當成空的、只看 net、目標打不開改走建立、表單與閘門不一致仍開始）；建立者未套用時繼續；前提類問繼續；不先看 `core.blocked`；換台不等關連線（驗事件順序：上一台 `close` 完成 → 下一台 `connect` 成功）；對話框返回當繼續；4.1 的勾選規則照 v2（`netId` = 目標也不能勾）。
6. §2.8 檢查網路 / 重新建立 + Rust `forgotten-net`。
   - 測試 T-R1：已套用 → 升級；不在網路 + 只有建立者 → 可以重新建立、副本存在、net/ 不在；回答不明 → 沒有按鈕；有其他成員 → 沒有按鈕。T-R2：降級相容。Rust 測試兩個。
   - 改壞：拿掉條件 2（節點其實已套用也被丟）、拿掉條件 3、拿掉留副本、整個動作拿掉（死路）。
7. `ClaimPage` 換樣式 + `openRawPage<T>` + `ClaimDone` + 3.2 `setNick` + F41 橫幅 + 開發用輸入只在 devTrust 顯示。
   - `claim_*` 測試不改判定。測試：T-C3、T-V1（暱稱 24 / 25、控制字元、方向字元）、T-F41、`ClaimDone` 三種成功路徑。
   - 改壞：`ClaimDone` 被丟掉；`setNick` 不過濾；開發用輸入在 field 顯示。
8. 首頁、節點頁、3.5 / 3.6 接線；兩位程式審查；真機。

## 8. 真機（要使用者同意；開始前另列副作用）

- **從零**：用 `scripts/dv/prov-bench-s0-254.sh unclaimed` 把 02、04 弄回未認領（會清掉節點的擁有者與網路設定），手機上用「從這支手機移除這台節點」忘掉兩筆紀錄。
  - 副作用：兩台離開 N0，daily-validation 依賴 N0 的項目在場次結束前不能跑。
  - 場次結束後：讓兩台留在 app 建的網路，或用同一支腳本的 `restore` 回 N0。兩者擇一，在開始前列出。
- 情境 1a：新增 04 → 建立（一台）→ 新增 02 → 加入（從節點頁或第 6 列）。
- 情境 1b：兩台一起勾、多台流程。
- 情境 2：建立途中拔建立者的電 → 待辦 → §2.8 → 檢查網路 → （重新建立）。
- 每條各做一次設計 R-7 的三種中斷（關藍牙再開、節點重開、切背景），以及 X13：建網後「正在確認節點連上了」期間切背景 30 s，和 main 的 app 對照。記「正在連到節點…」的秒數（10 次 9 次 ≤ 20 s）。
- A18（建立回來是否已套用）。
- 手機 VPN 只擋軟體更新的 Wi-Fi 傳送，不影響建網（只走藍牙）。

## 9. PR 內文要寫明的限制

- 手機 Wi-Fi（5.6）在 PR 4，所以「手機上的 TAK 透過節點通訊」還不行。
- 隊員路徑只有 dev 版、還在舊控制台（PR 5）。
- field 版現在跑不起來（#255），所以「別人的手機」= 安裝 dev 版。
- 認領期間沒有步驟清單與經過時間（D1）。

## 10. 要使用者決定的

無（D1–D4 是技術細節）。真機場次開始前取得同意。

## 11. 殘項（寫進 #329）

- `ClaimPage` 改走 `BleGate` / `RecordWriter`、步驟清單與經過時間（D1，PR 6）。
- S10：認領時的 BLE 位址進技術資訊。
- 隊員加入、看申請的新頁面（D3，PR 5）。

## 12. 審查的對應

### v2 審查 C

| 項目 | 處理 |
|---|---|
| M1 驅動器沒掃描 | §2.1（自己掃描、`_lf*`、叫醒、`lease.valid`）、§7 步驟 2 改壞 |
| M2 `Refused` ≠ 佔用遺失 | §2.2.1 `leaseLost` 只看 `!lease.valid` |
| M3 4.1 表單 / 閘門 | §2.3 4.1 自己列檔的表、建立閘門表 |
| M4 建立者找不到 | §2.4 `deviceId` + `name` 對應 + 使用者選；§2.8 對象 |
| M5 閘門沒有改壞 | §7 步驟 5 每一列各一 |
| m1 LoginResult / 金鑰即時讀 | §2.1 |
| m2 ClaimDone / 交接上限 | §2.6 `openRawPage<T>`；§2.1.2 5 s 上限、等待後才檢查 `reg.current` |
| m3 原始碼鎖撞 UiState | §4 D2（`ui_state.dart` 除外） |
| m4 PopScope 違反設計 | §2.6 F41 改成首頁橫幅，不加 `PopScope` |
| m5 結果頁的連線 / 螢幕 | §2.3 進結果頁就 `close`、關 `keepScreenOn` |
| m6 P14 不完整 | §1 P16 |
| m7 A3 / A5 | §1 P20、P21；§2.3 不重複自動檢查 |
| m8 列檔規則 | §2.4 |
| m9 事件順序 | §2.3 先看 `core.blocked`；T-M1(d) |
| m10 真機 X13 / N0 | §8 |
| m11 交接細節 | §2.1.1 |

### v2 審查 D

| 項目 | 處理 |
|---|---|
| B1 建立失敗的死路 | §2.8、D4、Rust `forgotten-net`、T-R1 / T-R2 |
| M1 結果契約 | §2.2.1（結構化、`pollLink`、重讀 `applied`、`[JOIN_STATE]` 標籤、timeout / ended / frameError / busy、`keyFail` 旗標、persist 的 `NoLease`） |
| M2 HandoffProber | §2.1.1 獨立類別、inbox、`asyncMap` |
| M3 勾選規則 | §2.3（`netId` = 目標可勾） |
| M4 閘門分支 | §2.3 兩張表 |
| m1 precondition / 掃描 / keyError / 建網前金鑰 | §2.1、§2.2 |
| m2 藍牙中途關 | §2.3 先看 `core.blocked` |
| m3 事實 | §1 P11、P18、P23 |
| m4 原始碼鎖 | §4 D2 |
| m5 複製清單 | §2.2 |
| m6 device id | §2.4 |
| m7 `keepScreenOn` / handoff 擁有者 | §3.1、§2.2 `console.close()` |
| m8 結果頁連線 | §2.3 |
| m9 頁面消失 | §2.3、§3.3 |
| m10 安靜位址 | §2.1 限制、§6 |
| m11 摘要表 X26 / acquire 不等摘要 | §2.4、§2.1.2 |
| m12 負向對照 | §7（F41、ClaimDone、慢的 `readRecords`） |
| m13 入口表 | §2.5（排除待辦、3.6 次要「再加一台」） |
| m14 建立者選擇 | §2.3 |

### v1 審查 A / B

v2 已處理（登入、建立條件、佔用、複製、多台迴圈、摘要表、認領、入口、真機、結果契約、生命週期、負向對照、擁有權、原始碼鎖、log）；v2 審查確認其中多數已解決，未解決的（結果契約 A-M8、`Refused` / `NoLease` B-m-8）在本版 §2.2.1。
