# #329 PR 3 實作計畫 v7：新增節點、建立 / 加入 / 檢查網路

上層設計：`docs/design/329-app-uiux.md`（v12.1，已合併）§4.1、§4.3.8、§4.3.9、§4.4、§4.7、§5.1、§5.3、§5.4、§7、§9.1、§12。main = 29b0085。

**版本紀錄**
- v1：A、B 都 REJECT。
- v2：C APPROVE-WITH-CHANGES；D REJECT。
- v3：E REJECT（1 BLOCKER / 3 MAJOR）、F REJECT（1 BLOCKER / 2 MAJOR）。兩位的 BLOCKER 都在 v3 新加的「重新建立」。
- v4：G、H 都 APPROVE-WITH-CHANGES（各 0 BLOCKER / 3 MAJOR）。
- v5：I APPROVE-WITH-CHANGES（0 / 3 MAJOR）、J APPROVE-WITH-CHANGES（0 / 1 MAJOR）。
- v6：K APPROVE-WITH-CHANGES（0 / 3 MAJOR）、L APPROVE-WITH-CHANGES（0 / 4 MAJOR）。兩位的 MAJOR 都在「從空欄位或 generation 推論節點狀態」。
- v7（本版）：逐條對應見 §12 的 v6 段。**Rust 多回三個結構化欄位**（§2.9：狀態的 `netPresence`、檢查網路的 `netState` + `isCreator`、加入的 `joinEnd`），Dart 只照欄位判定、不再推論。「建立新的網路」只在每一筆 pending 都由建立者本人確認「沒有套用」之後才給；首頁對在別的網路的節點顯示警告（不靠網路名稱）。
- v6 的內容（以下各節已併入 v7）：建立者必須沒有 `netId` 也沒有 `unfinished`；有一台讀到的 `netId` 等於某筆 pending 時只給「檢查網路」；首頁顯示節點在哪個網路；建立閘門依模式分開；4.1 用 `Page.home` 讓剛認領的節點被讀到；加入判定加上 generation 前進；形狀釘子改成 golden JSON。
- v5 的內容（以下各節已併入 v6）：
  - 結果判定改用 Rust 真正的成員狀態：建立 / 檢查只看網路 `applied`；加入看這一台的成員項是否「已套用」（`!joining && !approved`），並用 Rust 測試釘住 `net_summary` 的輸出形狀（G-M1、H-M1）。
  - **只有沒套用的網路紀錄時，新頁面允許建立新的網路**（H-M3）：沒套用的網路不可能有其他成員（加入要求已套用，join2flow.rs:340-342），舊的那筆留著不動。兩個版本都有出口，不改 Rust，D4 的 field 死路消失；dev 的「到舊控制台重新建立」拿掉（G-M2、H-M2）。
  - 4.1 跟著讀取結果即時更新，剛認領完的節點讀到後就能當建立者（G-M3）。
- v4 的內容（以下各節已併入 v5）：
  - **拿掉「重新建立」。** 它要判斷「節點確定沒有套用」，但 Rust 的檢查結果只有文字、不分「還在套用中 / 讀不到 / 沒套用 / 別的網路」，也不檢查登入的是不是建立者（E-B1、F-B1）。照「只做必要的修改」，PR 3 不新增這個動作。網路沒有套用時：新頁面給「檢查網路」；dev 版另外給「到舊控制台重新建立」（現況的出口：`request_make_network` 每次產生新的網路編號，舊的 pending 紀錄留著，owner.rs:1067-1088）。field 版的死路寫進殘項，等 Rust 能回結構化的網路狀態再設計。
  - 加入 / 建立 / 檢查的結果改成**用 `rel` 重讀紀錄**判定，不靠標籤（E-M1）。
  - `HandoffProber` 的結果對應和 `SessionProber` 共用同一個純函式（F-M1）。
  - 新增 `openRawPageFor<T>`，舊的 `openRawPage` 不動（F-M2）。
  - `loginFor` 補上「掃到新位址就叫醒」、掃描名額、掃描被系統結束時重掃、60 s 到時收尾（E-M3）。
  - 網路摘要表移到獨立的 `NetIndex`，不放在 `NodeLink`（F m11）。

## 1. 事實（原始碼，main 29b0085）

| # | 事實 | 證據 |
|---|---|---|
| P1 | 舊控制台的請求機制與它共用的欄位、旁路旗標 | nodes.dart:194-589、:687-716、:750-797、:1574-1622 |
| P2 | 這組機制綁頁面；`_say` 會 `debugPrint`；頁面不在時 `_pickNet` 回第一筆 | nodes.dart:157-160、:277、:405、:520、:614 |
| P3 | 舊控制台與 `ClaimRecords` 不經 `RecordWriter`；`UiState` 合法直接寫 `ui/state-v1` | nodes.dart:261、:467、:764、:1026、:1290；claim_records.dart:43-53；ui_state.dart:228、:232 |
| P4 | `_busy` = 原始佔用的 hold；`_ask` 用 `_busy && !held` 擋重入 | raw_use.dart:25-44；nodes.dart:520-529 |
| P5 | `BleGate.scan(token)` 每 30 s 最多 4 次（超過會在閘門裡等，最多約 30 s）；`connect` 一次一條；`GateLink` 在連線斷掉**或**佔用收回時都丟 `Refused` | ble_gate.dart:84-86、:185、:202-206、:226-231 |
| P6 | `RecordWriter.writeCas` 只認登記表目前的佔用 | record_writer.dart:27-40 |
| P7 | `core.LoginFor`：位址只從 `onScan` 收到的挑；同位址隔 6 s 可再試；N9；身分不符寫首頁；寫 `isY` / `notY`；計時從 `core.loginFor(now)` 起算 60 s；藍牙 / 權限 / 金鑰經 `setRadio` 結束成 `precondition`。`LoginEnd` = ok / identity / refused / notFound / precondition | core.dart:282-292、:628-748 |
| P8 | 佔用期間 `reg.nodeLinkToken == null`；`_run` 與掃描都用它；`_pump` 會砍掉不是自己排的嘗試（`_lf*` 欄位不受影響） | node_link.dart:157、:215、:260、:296 |
| P9 | `SessionProber` 決定結果後丟掉後續訊框，`finally` 取消訂閱並 dispose session；訊框各自 `run`；登入結果的對應在 :96-104（login_end 5 或登入前結束 = noResponse） | prober.dart:96-104、:133-134、:147、:160-175 |
| P10 | `openRawPage` 推 `MaterialPageRoute<void>`，pop 的值被丟掉；呼叫者用 `busy != null` 判斷「另一個操作還在進行」 | raw_use.dart:73-82；main.dart:87-88；home_page.dart:55-61 |
| P11 | `ClaimPage` 自己做藍牙、進度只有 `_say`；開發用的貼上 / 16 進位輸入每版都顯示 | claim.dart:154-157、:212-472、:500-512 |
| P12 | 9b00ca6 已替舊控制台補四條路徑的測試（改壞 5/5） | 9b00ca6 |
| P13 | 加入要求網路已套用 | join2flow.rs:340-341 |
| P14 | Rust `list_kind` 讀不到目錄回空清單、濾掉 `.` 開頭的檔名；store 暫存檔是 `.<name>.tmp-…` | owner.rs:41-47；store.rs:20、:118 |
| P15 | `released` 非同步；新佔用在讀完紀錄前拿到時 `writtenAt` 不設 → N9 視窗失效。`releaseLease` 把下一輪排在 6 s 後，等它不會死鎖（v3 審查 E、F 都確認） | node_link.dart:171-195；core.dart:703-705 |
| P16 | `MemberView` 有 `name`、`last4`、`joining`、`approved`、`creator`、`prevCountry`、`dacHash`，沒有 device id；`net_summary` 手上有 `m.device_id`；加入中的成員帶 device id；pending 紀錄的建立者 device id 是 None、`name = "node-<last4>"` | owner.dart:243-270；owner.rs:79-80、:116、:1080；join2flow.rs:362；netrec.rs:212、:375-377、:391-396 |
| P17 | `request_member_join` 只在 dev 版本 | owner.rs:1213-1215 |
| P18 | 首頁第 6 列現況：`net \|\| mnet \|\| unknown → 加入網路`，動作都開舊控制台 | home_logic.dart:92-96；home_page.dart:129-151、:170-171 |
| P19 | 建立：Rust 先寫 pending 的 net 紀錄（`OwnerStep.rel` 帶路徑）再送出；`Rejected`、NewNonce 兩次、其他錯誤、檢查得到 InProgress / NotApplied / Unknown / OtherNetwork / OtherVersion 都會讓紀錄停在 pending；`request_make_network` 每次產生新的網路編號 | owner.rs:428-430、:1067-1088、:1451-1458、:1477-1480、:1500-1524 |
| P20 | 「檢查網路」的結果只以文字回來（`[NET_STATE] …`），`OwnerStep` 沒有狀態欄位；`flow::join_state` 分 InProgress / NotApplied / OtherNetwork / Unknown；`netrec::confirm` 不檢查登入的是不是建立者 | owner.rs:879-893；flow.rs:143-175 |
| P21 | 被入侵的節點加入時只能換掉 net 紀錄裡它自己的成員項（key = 驗證過的 node_cert 的 dac_hash）；國家只收兩個大寫字母 | join2flow.rs:285-288、:345-365、:445-458 |
| P22 | 加入的 answer 標籤（`[JOINED]`、`[REQ_FAIL]`、`[JOIN_STATE]`、`[COUNTRY]`）是 log 記號、混了確定與不明的結果；「國家未驗證」的成功加入沒有 `pollLink` → **不用標籤判定結果** | owner.rs:498-566、:1437 |
| P23 | `UiState` 沒有設定暱稱的方法；`_save` 把寫入串成一列，並行的寫入依序完成、不互相覆蓋 | ui_state.dart:95-97、:131-138、:197；ui_state_test.dart:179 |
| P24 | `StatusView.netId` 與 `nodeState` 可得到「讀到的節點在哪個網路」 | owner.dart:559-560；home_logic.dart:31 |
| P25 | `keepScreenOn` 是現成的視窗旗標（不計數），軟體更新頁也用 | swupdate.dart:137；SwUpload.kt:77-81 |
| P26 | 有安裝紀錄就不碰金鑰（`RECORD_KINDS` 只在沒有安裝紀錄時才看） | main.dart:196-205；simple.rs:31-48 |

## 2. 做法

### 2.1 `NodeLink.loginFor`（設計 §4.3.9）

- `Future<LoginResult> NodeLink.loginFor(Lease lease, String id, {bool clearNotY = false})`。`lease` 不是登記表目前的 session 佔用 → 丟 `NoLease`。
- 開始前：即時讀一次 `KeyAbilities`（不能用 → `precondition(keys)`）；`core.blocked` → `precondition(why)`。
- **驅動器自己的狀態**：`_lfScan`、`_lfAttempt`、`_lfLink`、`_lfTimer`，不碰自動讀取的欄位（P8）。
- **掃描**：
  - `gate.scan(lease.token, addr → { LoginFor.onScan(addr); 叫醒驅動器 })`，掃到新位址就叫醒。
  - 計時從**第一次掃描真的開始**時起算：在閘門裡等名額的時間（P5）不吃 60 s 預算。
  - 掃描被系統結束（`ended`）而登入還沒結束 → 重新掃（照閘門的名額）。
  - 結束時先停掃描再回傳。
- **計時**：照 `LoginFor.wakeAt` 排計時；`radio()` 改變時叫醒，前提失效立刻結束；每次嘗試前檢查 `lease.valid`。
- **60 s 到**（`LoginFor` 結束成 notFound）：取消進行中的嘗試、`await` 關掉它的連線，再回傳。
- **每次嘗試**：`gate.connect(lease.token, addr)` + `HandoffProber`（§2.1.1），8 s 內沒收到 msg2 就結束那次。
  - 結果經共用的 `loginOutcome(...)`（§2.1.1）交給 `LoginFor.result`。
  - 失敗的嘗試先 `await link.close()` 才試下一個；`requestMtu` / 讀 ctrl / 訂閱丟例外也一樣。
  - `keyError` → `keyErrorToRadio`。
- **`LoginResult`**（照 `LoginEnd`）：`ok(LoginHandoff)` / `identity` / `refused` / `notFound` / `precondition(Why)`。
- 位址備忘、節點狀態的唯一寫入者仍是 `NodeLink`。
- `gate.scan` 回來之前（`LoginFor` 還沒建好）到的掃描回呼：存進一個小清單，`LoginFor` 建好後依序交給 `onScan`。
- `NodeLink.dispose` 也收掉 `_lf*`（停掃描、取消計時、關嘗試中的連線；node_link.dart:352-358 現在只收自動讀取的欄位，v3 E-m12）。
- **限制**：一個不回應的位址每次花 8 s，約 7 個就能吃光 60 s（設計接受，§4.3.7）。

#### 2.1.1 `HandoffProber` 與交接

- **`ended` 那一步的結果對應抽成純函式** `loginOutcome(OwnerStep ended, {bool loggedIn})`（prober.dart:96-104 的那張表，原樣搬出：`loginEnd`、`loginCode`、`loggedIn` → `Res`）。`SessionProber` 改呼叫它（判定不變，現有測試照過）；`HandoffProber` 的 `ended` 也用它。
  - login_end 5、或登入前結束 → `noResponse`（不能種下錯的「是 Y」）。
  - **「收到 `loggedIn` → `Res.body`」是 `HandoffProber` 自己的分支**，不放進共用函式（否則 `SessionProber` 會在 `loggedIn` 就結束、不讀狀態頁）。
- `HandoffProber` 是獨立類別（約 60 行），只讀到 `loggedIn`，有自己的測試。收到 msg2 之後也有上限：20 s 內沒到 `loggedIn` 就結束那次（同 `SessionProber` 的 answerMax，prober.dart:37，v4 G m3）。
- **收件匣 `FrameInbox`**（不重新 listen 串流）：
  - 訂閱 TX 之前先建好。訂閱的處理函式只呼叫 `inbox.add(frame)`。
  - `inbox` 有一個暫存清單和**一個**目前的處理者；換處理者時，先把暫存的依序交給新處理者。
  - prober 是第一個處理者，讀到 `loggedIn` 為止。處理 `loggedIn` 那一步時，在第一個 `await` 之前**同步**把處理者設成「無」，之後到的訊框進暫存（不沿用 `SessionProber` 的「結果決定就丟訊框」，prober.dart:134）。
  - 交接時把處理者換成 `OwnerConsole` 的佇列（一個接一個），暫存的先依序交出。交接之間到的訊框不會丟。
- 成功時：取消 msg2 計時器與 `due` / `cancelled` 回呼；**不**取消訂閱、**不** dispose session；交出 `LoginHandoff(link, session, inbox, subscription)`。
- **交接後**：`link.state` 的監聽和訂閱的 `onError` 都歸 `OwnerConsole`。斷線或訂閱錯誤時，等待中的請求結束成 `notSent` / 由重讀判定（§2.2.1）。
- `LoginHandoff.close()`（冪等）：先取消 `link.state` 的監聽 → 取消訂閱 → `await link.close()` → dispose session。
- 在閘門裡等名額的掃描：`loginFor` 結束時一起取消（`GateScan.stop()`）。

#### 2.1.2 `acquire` 等上一個釋放

- `released` 回呼裡「讀紀錄 + `core.releaseLease`」那一段的 future 存起來；`NodeLink.acquire` 先 await 它（上限 5 s），**之後**才檢查 `reg.current`。
- 網路摘要表的計算不在這段裡。
- 修掉 P15。

### 2.2 `OwnerConsole`：從舊控制台複製，只給新頁面

- 新檔 `lib/src/flows/owner_console.dart`。**舊控制台不改**，PR 6 刪舊控制台時重複消失。
- **複製清單**：
  - 步驟迴圈：`write`、`sign` / `signAdmin`、`persistNet`、`confirmCountry`、`wait`、`confirmRemoved`、`answer`、`ended`、處理訊框時的例外。
  - `ask`：逾時、unclear / notSent、寫入失敗重新登入只重送一次、`ended` 放掉 session、重入。
  - 動作：
    - `makeNetwork`（含即時 `KeyAbilities.refusal(makeNetwork)`；記下 `PersistNet` 步驟的 `rel`）；
    - `joinNetwork(rel)`；
    - `confirmNetwork(rel)`（含它的逾時句）；
    - `linkCheck`；
    - `sendUpdateFor(rel)`（含 `_sendUnclear`）。
- **不複製**：邀請、隊員、移除、離開、軟體更新、狀態頁。
- **和舊控制台的差別**（寫進檔頭註解）：
  1. 登入呼叫 `NodeLink.loginFor`；重新登入前先 `await` 舊的 `LoginHandoff.close()`；訊框經 `FrameInbox` 一個接一個處理。
  2. 寫入用 `RecordWriter.writeCas(lease, …)`；`writeCas` 丟 `NoLease` 時仍呼叫 `persistFailed`，結果標 `leaseLost`。
  3. `joinNetwork` / `confirmNetwork` 吃 `rel`，不在裡面挑網路。
  4. 回傳結構化結果（§2.2.1），不用 `_say`。
  5. 重入旗標 `_inFlight` 和佔用分開。
  6. 文字紀錄只寫種類、代碼、後四碼（位址經 `NodeLink.mask`），不寫回答內容。
  7. 國家問題：停計時 → 注入的 `askCountry` → 重新計時。被移除過：注入的 `askReAdd`，同意 → 重讀紀錄、`removedConfirmed: true` 重來。
  8. sign / seal 經包裝：金鑰錯誤記 `keyFail` 並 `keyErrorToRadio`。
- `console.close()` 由 `NetworkRun` 呼叫。

#### 2.2.1 結果契約：**用 Rust 的結構化欄位判定，不靠標籤、不猜**（P22）

- **加入**看 Rust 的 `joinEnd`、**檢查**看 Rust 的 `netState`（§2.9 新增的欄位）；**建立**看重讀紀錄的 `applied`（Rust 只在收到 Applied 時寫已套用的紀錄）。
- 每個請求結束後仍用 `rel` 重讀那筆 net 紀錄（唯讀：`storeReadSealed` + 平台 `open` + `netSummary`），但除了「建立」以外，重讀只用來更新顯示與 `NetIndex`。
- 成員狀態照 Rust 的定義（netrec.rs:43、:212、:395、:524-533；join2flow.rs:530；owner.rs:122）：「已套用的成員」= `!joining && !approved`；建立者在 pending 紀錄裡沒有 device id、`confirm` 升級時也不補（netrec.rs:526-527）。這只用在 `NetIndex` 的顯示與待辦。

**判定順序**（由上往下，第一個成立的就是結果）：

| # | 種類 | 怎麼判定 | 新頁面顯示 |
|---|---|---|---|
| 1 | `leaseLost` | `!lease.valid`（不看例外型別，P5） | 「這個操作被中斷了」 |
| 2 | `keyFail` | sign / seal 包裝記的旗標 | 2.4 的句子 |
| 3 | `cancelled` | 國家 / 加回的問題回答是「不要」 | 「已取消，沒有寫入、沒有送出」 |
| 4 | `noLink(LoginResult)` | 登入失敗 | 依原因的固定句（設計 §4.3.5） |
| 5 | `noRecord` | 沒有 `rel`（建立在 `PersistNet` 之前就結束），或重讀時檔案不在 | Rust 的句子（去標籤）+ 建立者失敗 → 流程停 |
| 6 | `unreadable` | 有 `rel`、檔案在，但打不開 | 「讀不到手機裡的網路紀錄」，流程停 |
| 7 | 建立：`applied` / `notApplied` | 建立回來後重讀網路的 `applied`（Rust 在收到 Applied 時才寫已套用的紀錄，P19） | 完成 / 本頁固定句「網路還沒有確認完成」+「檢查網路」（不顯示 Rust 那句「可以再建立一次同一個網路」，owner.rs:478） |
| 8 | 檢查：`netState` | Rust 回的結構化欄位 `netState`（§2.9 R2） | applied → 完成；其他 → 本頁固定句 +（條件成立時）「建立新的網路」（§2.8） |
| 9 | 加入：`joinEnd` | Rust 回的結構化欄位 `joinEnd`（§2.9 R3）：applied / unclear / refused / notSent / cancelled | applied → 「完成」→ 連線檢查；unclear → 「結果不明」+「再試這一台」；refused → Rust 的句子（去標籤）+「再試這一台」；notSent → 「還沒有寫入或送出，可以再試一次」 |
| 10 | Dart 端結束（逾時、斷線、訊框錯誤），沒有 Rust 的結束答案 | `SendTrack.wrote` 為真 → `unclear`；為假 → `notSent` | 同上 |

- **加入不再看紀錄的成員項或 generation 判定**（v6 K-M3、L-M3：NotSent 與國家被拒的還原各有兩次 CAS，generation 一樣會前進，join2flow.rs:450-458、:495-513、:583-590、:670-681）。分類只看 Rust 的 `joinEnd`；重讀只用來更新顯示與 `NetIndex`。所以逾時路徑的重讀時機也不影響分類（v6 L m）。
- 連線檢查的結果另外記：`[CONNECTED]` 之外（120 s 沒連上、讀不到）→ 結果頁那一台寫「已加入，連線狀態未知」（現況 `_linkUnknown` 的意思），仍算完成。
- **形狀釘子**（只剩建立用的 `applied` 與 `NetIndex` 的成員欄位）：Rust 加一個測試，對「剛建立的 pending」「Applied 回來的建立者」「confirm 升級後的建立者」「隊長加入成功的成員」「加入中的成員」各產生一筆紀錄，斷言 `net_summary` 的 `applied`、`joining`、`approved`、`creator`、`deviceId`，並寫成 golden JSON（`app/test/fixtures/net_summary_shapes.json`）。Dart 的 `NetIndex` 測試讀同一個檔；檔案不存在時兩邊的測試都 FAIL。
- Rust 的句子只用來**顯示**（去掉標籤），不用來分類。
- 例外原文、逾時句、`ended` 句只進技術資訊。
- `GateLink` 的 `Refused` 在 `lease.valid` 時 = 斷線，照現況 `ask` 的 unclear / notSent / 重送一次處理。

### 2.3 多台建網：`NetworkRun`

新檔 `lib/src/flows/network_run.dart`（邏輯）+ `lib/ui/network_pages.dart`（4.1–4.5）。

**4.1 開頁時自己列檔**（不拿佔用，列檔規則同 §2.4）；「打得開 / 已套用」用 `NetIndex` 的結果（解密只在 `NetIndex`）。`NetIndex` 計算中 → 4.1 顯示「正在讀取網路紀錄」，等它算完才給表單（v5 I m1）：

| 列檔結果 | 4.1 |
|---|---|
| 列不出來 | 「讀不到手機裡的網路紀錄」，沒有「開始」 |
| net / mnet / mpend 都沒有 | 建立表單：名稱（預設 `Batman`）、頻道（進階 40 / 42） |
| 有 net、其中有打得開而且已套用的 | 加入表單：「加入哪一個網路」（只列這些；一筆就不問） |
| 有 net、但都打不開 | 現有的重裝警告句，沒有「開始」 |
| 有 net、都打得開、都是 pending，而且**這次執行裡每一筆 pending 都已經由它的建立者確認「沒有套用」**（§2.8 的清除紀錄） | 建立表單，表單上方提醒「上次建立的網路沒有建立成功，舊的紀錄會留在手機上」 |
| 有 net、都打得開、都是 pending，還有沒清除的 | 只有「檢查網路」（§2.8；有一台讀到的 `netId` 等於某筆 pending → 對象 = 那一台、那一筆，v5 J-M1）。**沒有**「建立新的網路」 |
| 有 mnet / mpend（不論有沒有 pending 的 net） | 不顯示建立表單，顯示 §2.5 那一列的句子（dev 版給舊控制台按鈕）。有已套用的 net 時仍給加入表單 |

- **4.1 跟著讀取結果即時更新**：4.1 開著（拿佔用之前）時把 `NodeLink` 的頁面設成 `Page.home`（讀所有節點；`Page.other` 不排任何讀取，core.dart:169，v5 I-M3），並訂閱 `NodeLink.changed`。剛認領完的節點讀到之後，就能勾、能當建立者。拿到佔用後自動讀取停止，清單就固定。離開 4.1 時把頁面設回**進來之前的那一頁**（從節點頁進來就回 `Page.node` 那一台，v6 K m、L m）。測試用**真的 `NodeLinkCore`**（不是假的 NodeLink）。
- 「讀到」的定義：這次執行裡、最近一次讀取在新鮮時間內（`NodeLinkCore.fresh`，和首頁同一個規則）；過期的讀取當成沒讀到。

**節點清單**（`node/` 紀錄）：
- 加入模式：
  - 讀到在網路裡、`netId` 不是目標（或讀不到 `netId`）→ 不能勾。
  - `netId` 是目標：手機紀錄裡這台已套用 → 不能勾，標「已在這個網路」；紀錄裡是加入中或沒有這台 → 可勾，標「補完加入」（v5 I m「太寬」）。
  - 沒讀到 → 可勾，標「目前讀不到」。
  - 預設勾「剛讀到、還沒加入網路」的。
- 建立模式：
  - 建立者必須**讀到**（新鮮），而且 Rust 回的 `netPresence == none`（§2.9 R1：key 10 不存在、key 11 = false，確定讀到）。`unknown`（info 讀不到 / 被限速）、`inProgress`、`inNet` 都不能當建立者（v6 K-M1、L-M1：不再用「欄位是空的」推論）。
  - `inProgress` 或 `inNet` 的節點在建立模式**不能勾**（它在套用中或已在某個網路，v6 K-M2）。
  - 沒讀到的節點可以勾，但不能當建立者。
  - 符合條件的有好幾台時，預設是清單上第一台，使用者可以點選換一台（「由這台建立」）。
- 從待辦或節點頁進來：那一台預設勾、一定可勾。
- 至少一台。

**按「開始」**：
1. 拿 session 佔用（拿不到 →「另一個操作還在進行：<名稱>」）。從這裡到離開結果頁，`NetworkRun` 持有佔用與一個 `lease.hold()`。
2. 在佔用下重新列檔，照**建立閘門表**：

   閘門**依模式分開**（v5 I-M1：加入不被不相干的紀錄擋住）。

   **加入模式**：只看目標那一筆。

   | 佔用下 | 結果 |
   |---|---|
   | 目標檔案在、打得開、已套用 | 加入 |
   | 其他（不在、打不開、未套用、列不出來） | 不開始，請重開 4.1 |

   手機同時有 mnet / mpend、或別的 net 打不開，都不影響加入（設計 §5.1 第 6 列、T-N2；nodes.dart:1781「兩條路都不能消失」）。

   **建立模式**：

   | 佔用下的列檔 | 結果 |
   |---|---|
   | 列不出來 | 不開始 |
   | 有 mnet 或 mpend | 不開始，顯示隊員的句子 |
   | 有打不開的 net | 不開始（重裝警告句） |
   | 有已套用的 net | 不開始，請重開 4.1 |
   | 沒有 net | 建立 |
   | 有 net、都打得開、都是 pending，每一筆都在 §2.8 的清除紀錄裡 | 建立（舊的 pending 留著不動） |
   | 有 net、都打得開、都是 pending，還有沒清除的 | 不開始，轉「檢查網路」 |

   「pending 都清除後可以建立」的理由：
   - pending 的網路不可能有其他成員。能把成員項寫進 net 紀錄的七條路徑（建立、加入、邀請 / 同意、移除、檢查網路、忘記加入中的成員、隊員匯入）都要求已套用，或只碰建立者（join2flow.rs:340-342、invite.rs:185-187、rekey.rs:98、netrec.rs:509-535；v5 審查 I 逐條核對）。
   - 唯一可能在那個網路裡的就是建立者，而「清除」= 建立者**本人**（Rust 的 `isCreator`）在同一次連線裡明確回答 `netState == notApplied`（§2.9 R2）。所以新網路不會讓任何節點分裂。
   - 建立者讀不到、回答不明、在套用中、或登入的不是建立者 → 不清除，只能「檢查網路」（fail-closed）。建立者壞掉或遺失時沒有出口：寫進殘項，綁 field 版出貨（#255）；dev 版仍可用舊控制台（現況）。

   不開始時什麼都不送、不寫，放掉佔用。
3. `PopScope` 擋返回、`keepScreenOn` 開（等待期間）。

**每一台**（照設計 §5.4）：
1. `console` 登入那一台（`loginFor`）。
2. 建立者：`makeNetwork` → 重讀。`applied` → 繼續；其他 → **整個流程停**，結果頁給「檢查網路」（§2.8）。
3. 加入者：每台開始前用 `rel` 重讀（新的 generation 與內容）→ `joinNetwork(rel)`（國家 / 加回問題照 §2.2）→ `sendUpdate` 時 `sendUpdateFor(rel)` → 依 `joinEnd` 判定 → `applied` 時連線檢查（每 10 s、最多 120 s）。

**停止規則**：
- 任何失敗之後**先看 `core.blocked`**；`noLink(precondition(…))`（含 `loginFor` 開始前即時讀金鑰得到的 `precondition(keys)`，它不經 `setRadio`，`core.blocked` 不會成立）也一樣。被擋 → 整個流程停，顯示 2.3 / 2.2 / 2.4 的原因，不問繼續。
- `leaseLost`、`unreadable` → 整個流程停。
- 建立者不是 `applied` → 整個流程停。
- 加入者的其他結果（`noLink`、`refused`、`unclear`、`notSent`、`cancelled`）→ 問「繼續下一台 / 先停在這裡」；對話框被返回鍵關掉 = 停。

**結果頁**：
- 進入結果頁時：`console.close()`（最後一台恢復廣播）→ `keepScreenOn` 關。佔用留到離開結果頁（設計 §5.4）。
- 逐台列「完成 / 結果不明 / 失敗原因 / 還沒做」。「再試這一台」「檢查網路」重用同一個佔用。
- 離開結果頁：放 hold → `lease.release()`。

**流程中頁面消失**（雖然有 `PopScope`）：做完當前請求（不做之後的 `sendUpdate` 與連線檢查），不開始下一台，不彈對話框，`console.close()`，`keepScreenOn` 關，放 hold。一個加入請求最長 360 s（每次寫入重新計時），加上收尾在 420 s 之內；萬一超過，佔用被收回，`RecordWriter` 拒絕之後的寫入（fail-closed），首頁出現設計的「上一個操作可能沒有存完」。

### 2.4 網路摘要表：`NetIndex`（設計 §4.3.8；從 `NodeLink` 移出，F m11）

- 新類別 `NetIndex`，由 `AppLink` 持有；在啟動檢查通過時、`NodeLink.released` 之後各算一次（不在 `acquire` 等待的那段裡）。
- **列檔**（Dart，和 Rust `list_kind` 同規則）：
  - 直接 `list()`，**不先 `exists()`**（避免兩次呼叫之間的 TOCTOU）；錯誤是從串流送出來的，在 `toList()` 那一層接；
  - 先接 `PathNotFoundException` = 空；
  - 其他 `FileSystemException` = 列不出來；
  - 濾掉 `.` 開頭的檔名。
- **有沒有紀錄只看列檔**：`netFiles`、`mnetFiles`、`mpendFiles`、`pendingClaims`、`listFailed`。每個 net 檔另記檔案修改時間（`File.stat`；讀不到 = 最舊）。
- **解密只用來取**每個網路的名稱、`applied`、成員。一筆解不開 → 標「打不開」、記一行（只寫種類與 net id 前 8 碼，v5 J m）。金鑰閘門錯誤不走 X26（只影響顯示）。
- 另外提供 `netId → 網路名稱` 的對照，給首頁與節點頁顯示「節點在哪個網路」（§2.5）。
- **Rust `MemberView` 加 `deviceId`**（`net_summary` 已有 `m.device_id`；改一行 + 一個 Rust 測試）。
- 只保留代號最新的一次結果。計算中 → 第 6 列、3.5 / 3.6 都用中性的「加入網路」並顯示「正在讀取網路紀錄」，不顯示「建立網路」（剛認領完、佔用剛釋放時就是這個狀態，v3 E-m11）。
- 「建立網路」按鈕只在：列得出來、沒有 mnet / mpend、沒有已套用或打不開的 net，而且 net 檔是 0 或每一筆 pending 都已清除（§2.8）。有還沒清除的 pending 時，主要是「檢查網路」，沒有「建立網路」。這裡只決定顯示；真正的閘門是 §2.3。

### 2.5 入口去處表

| 入口 | 條件（`NetIndex`） | dev / dev2 | field |
|---|---|---|---|
| 第 6 列 | 計算中 / 列不出來 / 有打不開的 | 中性「加入網路」→ 4.1（4.1 自己列檔決定） | 同 |
| 第 6 列 | 0 檔 | 「建立網路」→ 4.1 建立表單 | 同 |
| 第 6 列 | 有已套用的 net | 「加入網路」→ 4.1 加入表單（排除已在待辦「加入沒有做完」裡的節點） | 同 |
| 第 6 列 | 有 net、都是 pending | 「檢查網路」→ §2.8（句子寫明檢查的是建立者那一台，不是這一列的節點，H m14）；4.1 裡另有次要的「建立新的網路」 | 同 |
| 第 6 列 | 只有 mnet | 「加入網路」→ 舊控制台（隊員加入，PR 5 換） | 只顯示句子（P17） |
| 第 6 列 | 只有 mpend | 「看我的申請」→ 舊控制台（PR 5） | 只顯示句子 |
| 第 6 列次要 | 0 檔 | 「我是隊員，加入隊長的網路」→ 舊控制台（PR 5） | 不顯示 |
| 首頁「新增節點」 | — | 3.x（§2.6） | 同 |
| 3.5（0 檔） | — | 主要「建立網路」；次要「我是隊員，加入隊長的網路」 | 主要同；次要不顯示 |
| 3.6（有 net） | — | 主要「加入網路」；次要「再加一台」 | 同 |
| 節點列、節點頁 | Rust 的 `netPresence`（§2.9 R1） | `inNet` 且是手機已套用的那個網路 → 照現況（正常）；`inNet` 但不是（別的網路或 pending 的網路）→ **警告**「節點 X 在另一個網路（不是這支手機的網路）」，首頁落在第 12 列的警告、不會是「一切正常」；`inProgress` → 「節點 X 正在套用網路設定」。不用網路名稱區分（名稱預設都是 `Batman`，v6 L-M4、K m） | 同 |
| 節點頁「還沒加入網路」 | 同第 6 列 | 對象預設勾這一台 | 同 |
| 待辦「節點加入網路沒有做完」 | §2.7 | 4.1 加入表單，目標 = 那筆網路、那一台預設勾 | 同 |
| 待辦「建立網路沒有確認完」 | §2.7 | §2.8 | 同 |

### 2.6 新增節點：`ClaimPage`（D1）

- **換 `build` 的樣式 + 兩處很小的邏輯補充**（交出結果、記下結果句）；`_claim` / `_find` / `_recover` 不動，`claim_*` 測試不改判定。不給步驟清單與經過時間（設計 §5.3 縮掉的部分寫進殘項）。
- 開發用的貼上 / 16 進位輸入在 `!devTrust` 時不顯示（設計 §5.3）。
- **新增 `openRawPageFor<T>`**，回傳 `(T? result, String? busyName)`。**舊的 `openRawPage` 不動**（P10：現有呼叫者用 `busy != null`）。新增節點的入口改用新函式。
- **`ClaimDone(deviceId)`**：
  - 認領成功、恢復成功、已有紀錄的覆寫認領成功時，`Navigator.pop(ClaimDone(id))`；
  - 失敗、返回、取消 → 沒有值；
  - 首頁收到 → 3.2 暱稱 → 3.5 / 3.6。
- **3.2 暱稱**：`UiState.setNick(id, text)`（新增；去前後空白，1–24 字，拒絕 Cc / Cf / Zl / Zp）。空白 = 預設「節點 <後四碼>」。和 `noteReads` 的並行寫入依序完成（P23）。
- **F41**（認領中按返回）：不加 `PopScope`（設計 §4.4）。`ClaimPage` 被 pop 之後認領照樣做完（現況），結果句寫到 `AppLink.lastClaimNote`（記憶體）；首頁回來時顯示一次「上一次新增節點：<結果句>」。
- S10：留在殘項。

### 2.7 待辦

- 「節點加入網路沒有做完」：`NetIndex` 裡 `joining` 的成員，用 `deviceId` 精確對到 `node/<id>`；對不上的不成待辦。
- 「建立網路沒有確認完」：手機**沒有任何已套用的 net**，而且有**還沒清除**的 pending net 時（§2.8 的清除紀錄），只列**一個**待辦，對象依序挑：
  1. `net_id` 等於某一台讀到的 `netId` 的那一筆（節點真正所在的網路，v5 I-M2）；
  2. 否則檔案修改時間最新的那一筆。

  每一筆 pending 都清除了 → 不列待辦，第 6 列給「建立網路」（§2.4）。

  點下去 → §2.8（對那一筆的 `rel`）。手機已經有已套用的 net 時，舊的 pending 不再列待辦（它們只是留在手機上的舊紀錄；清理寫進殘項）。

### 2.8 檢查網路（建立沒有確認完）

- **對象**：那一筆 pending net 的建立者。用 `name` 的 `node-<last4>`（**不分大小寫**：Rust 的 `last4` 是 device id 原字，首頁顯示時轉大寫）對手機唯一一筆 `node/`；對不上或多筆 → 讓使用者從節點清單選。
  - 對錯台沒有危險：Rust 回 `isCreator = false`（§2.9 R2），不升級、也不清除。
- 頁面：拿 session 佔用 → 登入對象 → `confirmNetwork(rel)` → Rust 回 `netState` 與 `isCreator`。
  - `netState == applied` → 紀錄已由 Rust 升級；回首頁（之後可以加入其他台）。
  - `isCreator && netState == notApplied` → 把 `rel` 記進**清除紀錄**（記憶體，`NetIndex` 持有，這次執行有效；重開 app 要重新檢查）。顯示「這個網路沒有建立成功」+ 主要按鈕「建立新的網路」。
  - 其他（`inProgress`、`otherNetwork`、`unknown`、`isCreator == false`、登入失敗）→ 本頁固定句「網路還沒有確認完成」+ Rust 句子進技術資訊；只有「再檢查一次」（`inProgress` 的句子寫「節點正在套用，請稍等幾分鐘再檢查」）。
  - 按「建立新的網路」：**先放掉這一頁的佔用**，再開 4.1 建立表單（§2.3；舊的 pending 留著，4.1 自己按開始時再拿佔用）。
- 離開頁面時放佔用。

### 2.9 Rust 的結構化欄位（新增，各附 Rust 測試；v6 K、L）

讓 Dart 不必從文字或空欄位推論節點狀態。都只是「多回傳一個 Rust 已經算出來的值」，不改任何流程或紀錄格式。

| # | 欄位 | 在哪裡算 | 值 |
|---|---|---|---|
| R1 | `StatusView.netPresence` | `status_view`，從同一次狀態頁讀到的 info（owner.rs:1300-1302、:2204-2217） | `none`（key 10 不存在、key 11 = false）/ `inProgress`（key 10 不存在、key 11 = true）/ `inNet`（key 10 是 16 位元組）/ `unknown`（info 沒讀到、被限速、格式不對） |
| R2 | 檢查網路的 answer 帶 `netState`、`isCreator` | `info-confirm` 那一段（owner.rs:879-893），用 `flow::join_state(info, record.net_id)`（flow.rs:155-175）與 `record.pending_creator() == 這次登入的節點的 dac_hash` | `netState`：applied / inProgress / notApplied / otherNetwork / unknown；`isCreator`：bool |
| R3 | 加入的 answer 帶 `joinEnd` | `join2_text` 旁邊（owner.rs:498-566，每一種結束都已經在這裡分好） | applied / unclear / refused / notSent / cancelled |

- 三個欄位都經 flutter_rust_bridge 產生 Dart 型別（`OwnerStep`、`StatusView` 多一個欄位；舊的呼叫者不用改）。
- Rust 測試：R1 四種值各一；R2 對「建立者回 notApplied / inProgress / otherNetwork / 被限速」「不是建立者」各一；R3 對 `join2_text` 現有的每一種結束各一（和現有的句子測試放一起）。
- 改壞：R1 把 `unknown` 回成 `none`；R2 `isCreator` 永遠 true；R3 把 NotSent 還原回成 applied → 各自 FAIL。

## 3. 介面

### 3.1 擁有權

| 資源 | 唯一的寫入者 | 只讀 |
|---|---|---|
| session 佔用與 `lease.hold()` | `NetworkRun` / §2.8 頁（按開始時拿、離開時放） | `NodeLink`（停讀）、`BleGate`、`RecordWriter` |
| `loginFor` 的掃描與嘗試連線 | `NodeLink`（`_lf*`） | — |
| 位址備忘、節點狀態 | `NodeLink` | 首頁、節點頁 |
| 交接後的連線、訂閱、`FrameInbox`、`OwnerSession` | `OwnerConsole`（`console.close()` 時放） | — |
| net 紀錄（新頁面） | `OwnerConsole` 經 `RecordWriter.writeCas` | `NetIndex`、`OwnerConsole` 的重讀、4.1 的列檔 |
| net / mnet / mpend（舊控制台、`ClaimRecords`） | 舊程式（D2） | 同上 |
| `NetIndex` | `NetIndex`（`AppLink` 持有；代號最新的一次） | 首頁、節點頁、3.5 / 3.6 |
| `keepScreenOn`（視窗旗標，P25） | `NetworkRun`（等待時開；進結果頁、例外、頁面消失時在 `finally` 關）；軟體更新頁（現況）。一次只有一個佔用，兩者不會同時 | — |
| `ui/state-v1` 暱稱 | `UiState.setNick` | 首頁、節點頁 |
| `AppLink.lastClaimNote` | `ClaimPage` 寫 / 首頁讀後清掉 | — |
| 清除紀錄（`rel` 的集合，記憶體） | §2.8 頁（只在 Rust 回 `isCreator && notApplied` 時加入） | 4.1、建立閘門、待辦、第 6 列 |
| `ClaimPage` 的原始佔用 | `ClaimPage`（現況） | — |

### 3.2 契約

| 介面 | 寫 / 讀 | 有效時 / 格式 | 缺、過期、壞掉 | 誰寫得到 |
|---|---|---|---|---|
| `NodeLink.loginFor` | `NodeLink` / `OwnerConsole` | 呼叫者持有目前的 session 佔用 | 不是 → `NoLease`；見 `LoginResult` | app 內 |
| `loginOutcome` | 純函式 / 兩個 prober | 每個登入步驟 | 不認得的結束 → `noResponse`（不種「是 Y」） | app 內 |
| `LoginHandoff` / `FrameInbox` | `NodeLink` 交出 / `OwnerConsole` | 交接後到 `close()` | 連線斷 → `notSent` 或重讀判定；`close()` 冪等 | app 內 |
| `ConsoleResult` | `OwnerConsole` / 新頁面 | 每個請求一個，以重讀紀錄判定 | 重讀失敗 → `unreadable`（停） | app 內 |
| 建立閘門 | `NetworkRun` 開始時列檔 | 佔用下、當下 | 列不出來 → 不開始；和 4.1 不一致 → 不開始 | 紀錄檔：app 私有目錄 |
| 4.1 的列檔 | 4.1 開頁時 | 只決定表單 | 列不出來 → 沒有「開始」 | 同上 |
| `NetIndex` | `NetIndex` / UI | 代號最新的一次 | 計算中 / 列不出來 → 中性按鈕；打不開的一筆 → 標記 | 同上 |
| `MemberView.deviceId`（新） | Rust / Dart | 加入中、已套用的成員 | 空（pending 建立者）→ 用 `name`，再不行讓使用者選 | Rust（紀錄內容由 app 寫） |
| `openRawPageFor<T>` / `ClaimDone` | `ClaimPage` pop / 首頁 | 認領（含恢復、覆寫）成功 | 沒有值 → 不開 3.2 | app 內 |
| 節點的回答 | 節點 / `OwnerConsole` | 解得開的 session 訊框 | 只顯示句子；分類看重讀的紀錄 | 被入侵的節點：只能換掉它自己的成員項（P21） |

### 3.3 生命週期

| 情況 | 現在 | PR 3 之後 | 測試 |
|---|---|---|---|
| 安裝 / 第一次 | 第 6 列開舊控制台 | 0 檔 → 「建立網路」 | T-N2 |
| 開始 | — | 4.1 自己列檔、不拿佔用；按開始才拿 | T-M1(a) |
| 正常結束 | — | 進結果頁 `close` + `keepScreenOn` 關；離開時釋放；`NetIndex` 重算 | T-M1(b) |
| 建立做到一半被殺 / 建立失敗 | 舊控制台再按「建立網路」（dev） | 待辦（最新一筆 pending）+ 第 6 列「檢查網路」→ §2.8；檢查後仍未套用 →「建立新的網路」（舊 pending 留著；dev 與 field 相同） | T-M2(b)、T-R1 |
| 加入做到一半被殺 | 一次一台 | 待辦（`deviceId` 對上）；沒開始的沒有紀錄 | T-M2(a) |
| 加入結果不明、節點其實已套用 | 舊控制台再按「加入網路」 | 待辦 → 4.1，那一台 `netId` = 目標 → 可勾「補完加入」 | T-M2(c) |
| 等待中切背景 / 關螢幕 | 照逾時走 | `keepScreenOn`；佔用中不自動讀；回來接著等 | T-M1(c)、R-7 |
| 藍牙關 / 權限收回 / 金鑰失效 | `[LINK_LOST]` | 先看 `core.blocked` → 整個流程停 | T-M1(d)（含斷線比 `setRadio` 先到） |
| 節點重開 / 斷線 | 結果不明 | `notSent` 或重讀判定 → 問繼續 | T-M1(e) |
| 佔用被收回 | — | `leaseLost` → 整個流程停 | T-M1(f) |
| dev2 同時讀同一台 | — | 那一台 `noLink` → 問繼續 | T-M1(g) |
| 流程中頁面消失 | `dispose` 完成等待中的回答 | 做完當前請求、不開下一台、`close`、放 hold | T-M1(h) |
| 認領中按返回（F41） | 結果顯示在已關掉的頁面 | 首頁顯示一次「上一次新增節點：…」 | T-F41 |
| 升級 / 回退 / 降級 | — | 紀錄格式不變；`MemberView.deviceId` 是 Rust → Dart 的顯示欄位，不寫進紀錄 | 不需要新測試 |
| 平台 | Android 12+ | 同 | — |

### 3.4 佔用與重入

| | 舊控制台（不動） | 新頁面 |
|---|---|---|
| 重入 | `_busy`（= `lease.hold()`） | `OwnerConsole._inFlight` |
| 進行中 | `_busy` | `NetworkRun` / §2.8 頁從開始到離開持有一個 `lease.hold()` |
| 寫入 | `_underLease` | `RecordWriter`，`lease` = 流程的那一個 |
| 頁面消失 | `dispose` 完成等待中的回答 | `pageGone` → hold 撐到收尾（最多 420 s） |

## 4. 和設計不同的地方

- **D1** 認領留在 `ClaimPage`（原始佔用）、換樣式 + 兩處小補充；不給步驟清單與經過時間；`ClaimPage` 改走 `BleGate` 寫進殘項（PR 6）。
- **D2** 舊控制台照舊。原始碼鎖：`lib/src/flows/`、`lib/ui/`（`ui_state.dart` 除外）不准出現 `storeWriteCas` / `storeWriteSealed` / `storeRemove` / `storeKeepCopy`。舊控制台（dev）仍能在 pending 存在時再按「建立網路」（現況，繞過新閘門）。
- **D3** 隊員路徑、看申請仍開舊控制台（dev）；field 版不顯示按鈕；PR 5 換。
- **D4** 有 net 但都是 pending、而且每一筆都已由它的建立者本人確認「沒有套用」（Rust 的 `isCreator` 與 `netState`，§2.9 R2）時，新頁面允許「建立新的網路」，舊的 pending 留著不動（設計 §5.3 寫「沒有任何 net 紀錄」才給建立）。理由見 §2.3：pending 的網路不可能有其他成員，唯一可能在裡面的建立者已明確回答不在。建立者讀不到或回答不明 → 只能「檢查網路」；建立者壞掉或遺失時 field 版沒有出口（殘項，綁 #255 的 field 版出貨），dev 版仍可用舊控制台。
- **D8** Rust 多回三個結構化欄位（§2.9 R1–R3）。設計沒有寫，但不加的話 Dart 只能從文字或空欄位推論節點狀態，v6 審查 K、L 證明這種推論會在該擋的時候放行。
- **D5** 建立回來不是已套用 → 整個流程停、讓使用者按「檢查網路」（設計 §5.4 寫自動檢查一次）。理由：Rust 在結果不明時已自己檢查過一次（owner.rs `join_step` ReadInfo 分支），再自動做一次是重複；A18 在真機量。加入結果不明 → 「再試這一台」（設計寫「檢查網路」）：`confirm` 只會升級建立者，不會升級加入者（netrec.rs:524-527）。
- **D6** 網路摘要表放在獨立的 `NetIndex`（設計 §4.3.8 放在 `NodeLink`）：`NodeLink` 只做藍牙排程，不碰 Keystore。
- **D7** 首頁第 6 列多一個去處「檢查網路」（有 net 但都是 pending 時）。

## 5. 假設與證據

| 假設 | 證據 / 怎麼確認 |
|---|---|
| A1 `loginFor` 能處理剛認領完的節點（N9） | core2–core5 的 sim 測試 + 端到端 T-L17（假 `BleGate` + 慢的 `readRecords`）；真機 R-7 |
| A2 建立回來可能停在 pending 的原因不只一種 | P19；所以建立者不是 `applied` 一律整個流程停、轉檢查網路 |
| A3 被入侵的節點只能換掉自己的成員項 | P21 |
| A4 頁面開著時佔用沒有上限 | lease.dart:72-102 |
| A5 pending 紀錄的建立者 `name` = `node-<last4>` | owner.rs:1080；⚠️ 開工時用 Rust 測試確認 `net_summary` 對 pending 紀錄回的 `name` |
| A6 Dart `list()` 對不存在的目錄丟 `PathNotFoundException` | ⚠️ 開工時用測試確認；不行就全部當成「列不出來」（fail-closed） |
| A7 `loginOutcome` 抽出後 `SessionProber` 判定不變 | 現有 prober 測試照過 |

## 6. 安全

- **資產**：擁有者 / 管理者金鑰（Keystore，不變）、net 紀錄（密封，不變）、節點的網路設定、隊伍不分裂。
- **輸入面**：網路名稱（Rust 檢查）、暱稱（`setNick` 過濾）、勾選的節點（只能是 `node/` 紀錄的 id）。沒有新的平台方法（`keepScreenOn` 是現成的，P25）、檔案路徑、匯出元件。
- **遠端 BLE / 惡意廣播**：8 s msg2 預算 + 「不是 Y」備忘，約 7 個不回應的位址能吃光 60 s（設計接受）；登入結果不認得的一律 `noResponse`，不會種下錯的「是 Y」。身分不符結束那一台並寫首頁。
- **被入侵的節點**：每台加入都 CAS 同一筆 net 紀錄，但只能換掉它自己的成員項、國家只收兩個大寫字母（P21）；能用國家 / 加回問題對使用者發問（要使用者同意）。每台開始前重讀紀錄。結果分類看紀錄，不信節點的句子。
  - 它能在狀態裡謊報 key 10（假裝在某筆 pending 的網路裡）或 key 11（假裝套用中），讓那筆 pending 永遠清除不了 → 只能「檢查網路」。這只是阻斷服務：出口是「從這支手機移除這台節點」（PR 2），之後那筆 pending 的建立者就對不上任何節點，使用者從節點清單選真正的建立者檢查（v6 K m、L m）。
  - 它不能讓手機在別台還在網路裡時建立新網路：清除需要**建立者本人**（dac_hash 對得上）回答 notApplied；被入侵的建立者說謊時，最壞是它自己沒在新網路裡，不會讓其他節點分裂。
- **本機無權限 app**：沒有新的入口。
- **我們自己的錯**：建立閘門（佔用下列檔、fail-closed、每一列有改壞）；佔用語意（§3.4）；原始碼鎖（D2）。
- **秘密**：`OwnerConsole` 只寫種類、代碼、後四碼；位址經 `NodeLink.mask`。舊控制台的 `_say` 會把回答寫進 logcat（現況）。
- **fail-closed**：沒有佔用 → `BleGate` 與 `RecordWriter` 拒絕；列檔失敗 → 不開始；目標打不開 → 不建立；重讀失敗 → 停。

## 7. 步驟（每一步都跑全套、各自附改壞對照）

1. ✅ 舊控制台補測試（9b00ca6，改壞 5/5）。
2. **Rust 結構化欄位（§2.9 R1–R3）+ `MemberView.deviceId` + 形狀釘子（golden JSON）**；重新產生 bridge。
   - 測試與改壞照 §2.9；`deviceId` 一個 Rust 測試；golden JSON 不存在或內容不同 → FAIL。
3. `loginOutcome` 抽出（`SessionProber` 改呼叫，現有測試照過）+ `NodeLink.loginFor` + `HandoffProber` + `FrameInbox` + `acquire` 等上一個 `released`。
   - 測試：T-L17（慢的 `readRecords`）、T-L18、T-S3；掃到新位址立刻嘗試；名額等待不計入 60 s；掃描被結束會重掃；60 s 到時進行中的連線被關；失敗嘗試會關連線；交接瞬間的訊框不丟；persist 等待中再來的訊框依序處理；交接成功時 session 沒被 dispose；不認得的登入結束 → 不種「是 Y」；`dispose` 收掉 `_lf*`。
   - 改壞：不掃描或用 `nodeLinkToken`；不叫醒；拿掉 N9 retry；身分不符不結束；失敗不關連線；60 s 不收尾；`acquire` 不等 `released`；交接丟暫存訊框；訊框不排隊；登入成功對成 `noResponse`。
4. `OwnerConsole`（複製）+ `ConsoleResult` + `RecordWriter` 寫入 + 原始碼鎖。
   - 測試：重送只一次；`notSent`；逾時進技術資訊；國家問題期間不計時（時鐘推 400 s 再答）；`ended` 放掉 session；`Refused` 且 lease 有效 → 不是 `leaseLost`；persist 時 lease 收回 → `leaseLost` 且有呼叫 `persistFailed`；`joinEnd` 每一種 → 對應的結果（含「國家未驗證」的成功、NotSent 還原 → `notSent` 不是完成）；`netState` / `isCreator` 傳到結果；金鑰錯誤 → `keyFail`；`makeNetwork` 的 `rel` 取自 `PersistNet`；建立回來重讀 `applied`。
   - 9b00ca6 的四條路徑改成表格驅動，同一組情境也對 `OwnerConsole` 跑；兩邊不同的地方（§2.2 差別 1–8）在表裡標成例外。
   - 改壞各一（含：加入改用重讀紀錄判定、忽略 `joinEnd`） + 原始碼鎖（新檔留一個直接呼叫 → FAIL）。
5. `NetIndex` + 首頁第 6 列、待辦、節點列改用它與 `netPresence`。
   - 測試：T-L19；T-N2（0 檔 / 已套用 / 未套用 / 只有 mnet / 只有 mpend / 打不開 / 列不出 / 計算中 / pending 都已清除）；待辦精確對應；`PathNotFoundException` = 空；節點 `inNet` 但不是手機的網路 → 首頁第 12 列警告、不是「一切正常」；`inProgress` 的句子。
   - 改壞：用解密結果決定有沒有；不濾 `.` 檔；計算中顯示「建立網路」；待辦只用後四碼；多筆 pending 時待辦不先挑 `netId` 對得上的那一筆；在別的網路的節點落到「一切正常」。
6. `NetworkRun` + 4.1–4.5。
   - 測試：T-M1(a)–(h)、T-M2(a)–(c)、建立閘門表每一列（加入模式只看目標；建立模式含「pending 都已清除 → 可建立」「還有沒清除的 → 不建立」）、4.1 跟著讀取更新（真的 `NodeLinkCore`；剛認領完的節點讀到後可當建立者）、離開 4.1 回到進來前的頁面、`precondition(keys)` 也停、連線檢查沒連上 → 「已加入，連線狀態未知」、T-C2 / T-C3。
   - 改壞：建立閘門每一列各一（改用 `NetIndex` 不重新列檔、列檔例外當成空的、加入模式被 mnet / mpend 擋、目標打不開仍開始、表單與閘門不一致仍開始、還沒清除的 pending 仍建立）；建立者不是 `applied` 仍繼續；前提類問繼續；不先看 `core.blocked`；換台不等關連線（驗事件順序）；對話框返回當繼續；`netPresence` 是 `unknown` / `inProgress` 的節點當建立者；`inNet` 的節點在建立模式可勾；4.1 用 `Page.other`；離開 4.1 一律回首頁。
7. §2.8 檢查網路 + 清除紀錄 + 待辦「建立沒有確認完」。
   - 測試 T-R1：`applied` → 回首頁；`isCreator && notApplied` → 清除、出現「建立新的網路」；`inProgress` / `otherNetwork` / `unknown` / 不是建立者 → 只有「再檢查一次」；對錯台 → 不寫、不清除；名稱對應不分大小寫；待辦只列一筆還沒清除的；都清除後不列待辦；按「建立新的網路」前放佔用。
   - 改壞：`isCreator` 不看就清除；`unknown` 當 `notApplied`；清除紀錄跨重開 app 保留；待辦列出每一筆 pending；按「建立新的網路」前不放佔用（4.1 拿不到）。
8. `ClaimPage` 換樣式 + `openRawPageFor<T>` + `ClaimDone` + 3.2 `setNick` + F41 橫幅 + 開發用輸入只在 devTrust 顯示。
   - `claim_*` 測試不改判定；`openRawPage` 的現有測試不改。測試：T-C3、T-V1（暱稱 24 / 25、控制字元、方向字元）、T-F41、`ClaimDone` 三種成功路徑、`setNick` 與 `noteReads` 並行都留下。
   - 改壞：`ClaimDone` 被丟掉；`setNick` 不過濾；開發用輸入在 field 顯示；舊的 `openRawPage` 改成新簽名（`busy != null` 永遠真）。
9. 首頁、節點頁、3.5 / 3.6 接線；兩位程式審查；真機。

## 8. 真機（要使用者同意；開始前另列副作用）

- **從零**：`scripts/dv/prov-bench-s0-254.sh unclaimed` 把 02、04 弄回未認領；手機上「從這支手機移除這台節點」忘掉兩筆紀錄。
  - 副作用：兩台離開 N0，daily-validation 依賴 N0 的項目在場次結束前不能跑。
  - 場次結束後：讓兩台留在 app 建的網路，或用 `restore` 回 N0。開始前擇一列出。
- 情境 1a：新增 04 → 建立（一台）→ 新增 02 → 加入（從節點頁或第 6 列）。
- 情境 1b：兩台一起勾、多台流程。
- 情境 2：建立途中拔建立者的電 → 待辦 → §2.8 檢查網路 →（仍未套用時）建立新的網路。
- 情境 3：加入途中切斷（例如加入送出後馬上拔那台的電，開機後讀到已在網路裡）→ 待辦「加入沒有做完」→ 4.1 那一台可勾「補完加入」。做不到時在 PR 內文標成 ⚠️ 只有模擬（T-M2(c)）。
- 每條各做一次設計 R-7 的三種中斷（關藍牙再開、節點重開、切背景），以及 X13（「正在確認節點連上了」期間切背景 30 s，和 main 的 app 對照）。記「正在連到節點…」的秒數（10 次 9 次 ≤ 20 s）。
- A18（建立回來是否已套用）。

## 9. PR 內文要寫明的限制

- 手機 Wi-Fi（5.6）在 PR 4。
- 隊員路徑只有 dev 版、還在舊控制台（PR 5）。
- field 版現在跑不起來（#255），所以「別人的手機」= 安裝 dev 版。
- 認領期間沒有步驟清單與經過時間（D1）。
- 網路建立後沒有套用時，出口是「檢查網路」；建立者本人確認「沒有套用」後才能「建立新的網路」（舊的 pending 紀錄留在手機上，D4）。建立者壞掉或遺失時 field 版沒有出口（dev 版用舊控制台）。舊控制台（dev）仍能繞過新的建立閘門。

## 10. 要使用者決定的

無（D1–D4 是技術細節）。真機場次開始前取得同意。

## 11. 殘項（寫進 #329）

- `ClaimPage` 改走 `BleGate` / `RecordWriter`、步驟清單與經過時間（D1，PR 6）。
- S10：認領時的 BLE 位址進技術資訊。
- 隊員加入、看申請的新頁面（D3，PR 5）。
- 手機上留下的舊 pending net 紀錄的清理（D4）：Rust 的 R2 欄位已經能判斷，之後可以加「丟掉這筆紀錄（留副本）」。
- **field 版出貨前必須解決**（綁 #255）：建立者壞掉或遺失時，pending 網路沒有出口（D4）。

## 12. 審查的對應

### v6 審查 K

| 項目 | 處理 |
|---|---|
| M1 空欄位不等於「沒在網路」；§2.8 拿不到 netId | §2.9 R1 `netPresence`（`unknown` 和 `none` 分開）；R2 檢查網路的答案自己帶 `netState`、`isCreator` |
| M2 套用中的舊建立者，新網路仍能用別台建好 | 「建立新的網路」只在每一筆 pending 都由建立者本人確認 notApplied 後才給（§2.3、§2.8）；`inProgress` / `inNet` 的節點在建立模式不能勾 |
| M3 generation 前進分不出還原 | §2.9 R3 `joinEnd`；加入不再看紀錄判定 |
| m golden JSON 的 generation | 不再用 generation；golden JSON 只剩 `net_summary` 的欄位 |
| m 逾時路徑的重讀時機 | 分類不看重讀（§2.2.1） |
| m 網路名稱都是 Batman | §2.5 用 `netPresence` 與網路編號判斷，不靠名稱 |
| m 從節點頁進 4.1 | §2.3 回到進來前的頁面 |
| m「讀到」的新鮮度 | §2.3 定義 |
| m 被入侵的節點謊報造成死路 | §6 |

### v6 審查 L

| 項目 | 處理 |
|---|---|
| M1 建立者規則在 info 沒讀到時也成立 | §2.9 R1；建立者要 `netPresence == none` |
| M2 §2.8 按鈕沒有資料來源 | §2.9 R2 |
| M3 generation 擋不住 NotSent 還原 | §2.9 R3 |
| M4 預設名稱分不出兩個網路 | §2.5 首頁警告（第 12 列），不靠名稱 |
| m 逾時重讀時機 | 同 K m |
| m 建立者壞掉或遺失 | §4 D4、§11（綁 #255） |
| m 4.1 表與閘門在 pending + mnet / mpend、pending + 打不開不一致 | §2.3 4.1 表與建立閘門對齊（有 mnet / mpend → 隊員句子；有打不開 → 重裝警告） |
| m golden JSON 不存在時要 FAIL | §2.2.1 |
| m 從節點頁進 4.1 | 同 K m |
| m 被入侵的節點假報 key 10 | §6 |
| m 首頁網路名稱顯示的測試 | §7 步驟 5 |
| m §12 對照表 | 本節 |

### v5 審查 I

| 項目 | 處理 |
|---|---|
| M1 閘門在加入模式也擋不相干的紀錄 | §2.3 閘門依模式分開，加入只看目標 |
| M2 套用中的建立者被當成建立者、多筆 pending 挑錯 | §2.3 建立者條件加 `netId` / `unfinished` 為空；讀到 `netId` 等於 pending → 只檢查；§2.7 先挑 `netId` 對得上的；§2.8「建立新的網路」的條件 |
| M3 4.1 不會讀取 | §2.3 4.1 用 `Page.home`；真的 `NodeLinkCore` 測 |
| m 4.1「不解密」矛盾 | §2.3 改用 `NetIndex` 的結果、計算中等待 |
| m 進 4.1 前沒放佔用 | §2.8 先放 |
| m G m1 / m3 | §2.2.1 重讀時機；§2.1.1 msg2 之後 20 s 上限 |
| m H-M1 的兩點 | §2.2.1 加入中也顯示 Rust 句子；檔案不在 = `noRecord` |
| m「補完加入」太寬 | §2.3 只在紀錄是加入中或沒有這台時 |
| m §9 舊建立者 | §9 |

### v5 審查 J

| 項目 | 處理 |
|---|---|
| M1 舊建立者留在舊網路、看不到 | §2.3 建立者條件、讀到 `netId` 等於 pending 時只檢查、§2.5 首頁顯示節點在哪個網路、§9 |
| m 重讀時 persist 還在途中 | §2.2.1 重讀時機 |
| m NotSent 還原被當成完成 | §2.2.1 第 8 列加 generation 前進 |
| m msg2 之後沒有上限 | §2.1.1 |
| m 形狀釘子少三種、Dart 手抄 | §2.2.1 golden JSON |
| m「先 exists 再 list」改壞抓不到 | §7 拿掉這條改壞（直接 `list()` 是寫法規定，測試以 `PathNotFoundException` = 空驗證） |
| m 最新 pending 的修改時間 | §2.4 `NetIndex` 記修改時間 |
| m Rust「可以再建立一次同一個網路」 | §2.2.1 第 7 列、§2.8 用本頁固定句 |
| m `NetIndex` 的路徑沒遮 | §2.4 只寫 net id 前 8 碼 |
| m 交接後 `link.state` / `onError`、等名額的掃描 | §2.1.1 |

### v4 審查 G

| 項目 | 處理 |
|---|---|
| M1 判定欄位錯 | §2.2.1 改用 Rust 的成員狀態與判定順序；形狀釘子（Rust 測試） |
| M2 dev 出口留下多筆 pending | dev 的舊控制台出口拿掉；建立新網路在新頁面、兩版相同（D4）；待辦只列最新一筆、有已套用的就不列（§2.7） |
| M3 剛認領完不能當建立者 | §2.3 4.1 跟著讀取更新 |
| D4 的條件（提醒、先放佔用、field 不顯示「可以再建立」） | 提醒在 4.1 表單上；不再開舊控制台（不用交接佔用）；「建立新的網路」兩版都有，Rust 那句也就做得到 |

### v4 審查 H

| 項目 | 處理 |
|---|---|
| M1 判定表與 Rust 成員狀態不合 | 同 G-M1；沒有 `rel` 的情況（`noRecord`）、判定順序都寫了 |
| M2 dev 重建沒有條件、多筆 pending | 同 G-M2 |
| M3 D4 前後不一致 | 採用 H 的做法：只有 pending 時新頁面允許建立（D4） |
| m1 `precondition(keys)` | §2.3 停止規則 |
| m2 連線檢查結果 | §2.2.1「已加入，連線狀態未知」 |
| m3 頁面消失超過 420 s | §2.3（頁面消失後不做 `sendUpdate` 與連線檢查；超過時 fail-closed） |
| m4 E-m9 / E-m11 / E-m12 | §2.7、§2.4、§2.1 |
| m5 和設計不同的地方 | §4 D5–D7 |
| m6 §2.8 對應 | §2.8（不分大小寫；不用 `dacHash` 的理由） |
| m7 `FrameInbox` 同步解除、掃描回呼早到 | §2.1.1、§2.1 |
| m8 `loginOutcome` 範圍 | §2.1.1 |
| m9 複製的控制台漂移 | §7 步驟 3 表格驅動 |
| m10 多台可當建立者 | §2.3 預設第一台、可點選換 |
| m11 真機缺兩條 | §8 情境 2、3；做不到的標 ⚠️ |
| m12 `Directory.list` 的錯誤 | §2.4 |
| m13 確定失敗也給「再試這一台」 | 接受並寫明（無害） |
| m14 第 6 列「檢查網路」的對象 | §2.5、§2.8 句子寫明是建立者 |

### v3 審查 E

| 項目 | 處理 |
|---|---|
| B1「重新建立」判斷不可靠 | 拿掉重新建立（D4），殘項記下條件 |
| M1 標籤分類 | §2.2.1 改成重讀紀錄判定 |
| M2 建立者不在了 | 隨 D4 進殘項；dev 有舊控制台出口 |
| M3 loginFor 掃描 / 叫醒 / 名額 / 60 s | §2.1 |
| m A2 / P20 / P22 不準 | §1 P19、P20、P22；§5 A2 |
| m keepCopy 後才刪 | 不再刪紀錄（D4） |
| m 建立者用 dac_hash | pending 建立者沒有 device id；§2.8 用 `name` + 使用者選，對錯只會「不符」 |
| m T-R2 理由 | 不再新增種類；§1 P26 記下真正的保護 |
| m `PathNotFoundException` | §2.4 |
| m `keepScreenOn` 兩個使用者 | §3.1、§1 P25 |
| m inbox | §2.1.1 `FrameInbox` |

### v3 審查 F

| 項目 | 處理 |
|---|---|
| B1「重新建立」 | 同 E-B1 |
| M1 `HandoffProber` 結果對應 | §2.1.1 共用純函式 `loginOutcome` |
| M2 `openRawPage<T>` | §2.6 新增 `openRawPageFor<T>`，舊的不動 |
| m inbox 單次 listen | §2.1.1 |
| m 60 s 含名額等待 / 掃描被結束 | §2.1 |
| m §2.8 生命週期 | §2.8 離開時放佔用；§3.3 |
| m `made` 的 `rel` | §2.2 取自 `PersistNet` |
| m `[JOIN_STATE]` 多義 | §2.2.1 不用標籤 |
| m `ClaimPage` 只換樣式的矛盾 | §2.6「換樣式 + 兩處小補充」 |
| m `setNick` 與 `noteReads` 競爭 | 不成立：`_save` 串成一列（P23），補一個測試 |
| m 建立模式「沒讀到」 | §2.3 不能當建立者 |
| m 舊控制台繞過閘門 | §4 D2、§9 |
| m 摘要表不該在 `NodeLink` | §2.4 `NetIndex` |

### 更早的審查

v1（A、B）與 v2（C、D）的 BLOCKER / MAJOR：v3 審查 E、F 確認 C-M2–M5、D-M2–M4 已解；C-M1 剩的掃描問題、D-M1 剩的分類問題、D-B1 在本版的 §2.1、§2.2.1、D4 處理。
