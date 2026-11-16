# #329 PR 3 實作計畫 v14：新增節點、建立 / 加入 / 檢查網路（新畫面）

上層設計：`docs/design/329-app-uiux.md`（v12.1，已合併）§4.3.8、§4.3.9、§4.4、§4.7、§5.1、§5.3、§5.4、§9.1、§12。main = 29b0085。

## 0. 範圍：只做新的部分，已審過的行為照舊

**行為基準（已設計、已審、已上線，本 PR 不重新決定）**：
- `docs/design/254-app-join2.md`（建網、第 N 台加入、確認網路、國家、結果不明、pending 補救；T1–T9）；
- `254-app-claim-noover.md`、`254-app-replay.md`（認領與恢復）；
- `254-app-status-page.md`、`254-app-remove-member.md`、`254-app-member-join.md`（狀態、隊員）；
- PR 1（#339，`NodeLink`、佔用、`BleGate`、`RecordWriter`）與 PR 2（#340，`joinChoice` 四態、首頁、`UiState`）。

建網 / 加入 / 檢查網路的結果與下一步**由 Rust 決定**（join2 §3.2、§3.3-6），新頁面**照 Rust 的句子顯示**，和舊控制台一樣。新頁面不加自己的建立條件、不重新分類 Rust 的結果。

**本 PR 新做的（審查範圍）**：
1. 新頁面的畫面：4.1–4.5（建立 / 加入 / 多台）、3.x（新增節點換樣式）。
2. 新頁面的連線方式：`NodeLink.loginFor`（設計 §4.3.9）、交接、`OwnerConsole`（從舊控制台複製，寫入改經 `RecordWriter`）。
3. 多台迴圈（設計 §5.4：一台接一台、失敗時問繼續 / 停、結果頁）。
4. 網路摘要表 `NetIndex`（設計 §4.3.8）與首頁按鈕去處。

**版本紀錄**：v1–v7 共 14 位審查。 v8 的兩位審查（O、P）都是 APPROVE-WITH-CHANGES，MAJOR 都是我縮減時漏掉的舊行為或設計（檢查網路頁、送新密碼、`clearNotY`、pending 時的「建立網路」、和設計不同處沒列）；v9 照舊控制台與上層設計補回，不加新機制。v3 起每一輪的 MAJOR 都落在我在新頁面上**自己加的**建立條件、「重新建立」、結果推論與 Rust 新欄位，而這些在 join2 都已經有答案。v8 把它們全部拿掉，回到 join2 的行為。v1–v7 審查裡**關於新程式**（登入、交接、佔用、列檔、`openRawPage`、認領交接）的發現保留，見 §9。 v9 的兩位審查（Q、R）都是 APPROVE-WITH-CHANGES：節點頁的「建立網路」沒條件（Q-M1）、拔電後多筆 pending 與登入失敗也給建立（Q-M2）、佔用有兩個釋放者（R-M1）；v10 照設計 §5.1 / §5.5 與 join2 收斂，不加新機制，對應見 §9 末表。 v10 的兩位審查（S、T）都是 APPROVE-WITH-CHANGES：檢查網路頁「升級」「拿到回答」沒定義清楚（S-M1）、pending 建立者壞掉時新頁面沒有建立的出口（T-M1）；另外我在 v10 說「精確比對要新的 bridge 函式」是錯的，`nodeDacHash()` 早就有（owner.rs:991-994、lib/src/rust/api/owner.dart:107），v11 改用它。 v11 的兩位審查（U、V）：U 0 MAJOR；V 1 MAJOR（結果頁建立列的「再試這一台」沒定義，等於另一個沒條件的建立入口，V-M1 = U-m4），v12 照設計 :750 定義每一列的下一步。 v12 的兩位審查（W、X）：W 1 MAJOR、X 2 MAJOR，都是新程式自己的介面沒寫——`OwnerConsole` 回給頁面的形狀（X-M1；照抄會帶 `[ANSWER] ` 前綴），以及我 v12 新寫的「結果頁 `pushReplacement` 迴圈頁」會先放掉佔用（W-M1 = X-M2）；v13 補契約表、迴圈與結果改成同一個 route。 v13 的兩位審查（Y 0 MAJOR、Z 2 MAJOR）：兩個 MAJOR 都是我 v13 新寫錯的——把 `acquire` 放到 `NetRunPage.initState`（4.1 已被換掉，被拒時沒地方顯示），以及「寫入失敗自動重送一次」（舊控制台對這五個請求根本不重送）。v14 改回 `openRawPage` 的順序（4.1 先拿、再 push），拿掉重送。

## 1. 事實（main 29b0085）

| # | 事實 | 證據 |
|---|---|---|
| P1 | 舊控制台的請求機制（`_login` / `_tryLogin` / 步驟迴圈 / `_ask` …）綁頁面，紀錄寫入不經 `RecordWriter` | nodes.dart:157-160、:194-589、:750-797 |
| P2 | `BleGate.scan(token)` 每 30 s 最多 4 次；`connect` 一次一條；`GateLink` 在斷線或佔用收回時都丟 `Refused` | ble_gate.dart:84-86、:185、:202-206、:226-231 |
| P3 | `core.LoginFor`：位址只從 `onScan` 收到的挑；同位址隔 6 s 可再試；N9；身分不符寫首頁；60 s；前提經 `setRadio` 結束成 `precondition`；`NodeLink` 沒有驅動它的入口 | core.dart:282-292、:628-748 |
| P4 | 佔用期間 `nodeLinkToken == null`，自動讀取的 `_run` / 掃描不能用；`_pump` 會砍掉不是自己排的嘗試 | node_link.dart:157、:215、:260、:296 |
| P5 | `SessionProber` 決定結果後丟掉後續訊框、`finally` dispose session；結果對應在 :96-104 | prober.dart:96-104、:133-134、:160-175 |
| P6 | `openRawPage` 丟掉 pop 的值；呼叫者用 `busy != null` | raw_use.dart:73-82；main.dart:87-88；home_page.dart:55-61 |
| P7 | `released` 非同步，新佔用在讀完紀錄前拿到時 N9 視窗失效 | node_link.dart:171-195；core.dart:703-705 |
| P8 | Rust 的結果標籤：建立成功 `[NET_MADE]`（只在 Applied）；加入請求的回答裡 `[JOINED]` 只在 `E::Applied`（含國家未驗證）——連線檢查的句子也用 `[JOINED]`（owner.rs:589-590），所以只看**加入請求本身**的回答；版本落後時設 `send_update`、不設 `poll_link`（owner.rs:1437-1439）；檢查網路升級紀錄（`Confirm::Upgraded`）並以 `[NET_STATE]` 回句子 | owner.rs:447、:487-490、:513-517 |
| P9 | `Page.other` 不排讀取；`Page.home` 讀所有節點 | core.dart:169、:186-201 |
| P10 | Rust `list_kind` 濾掉 `.` 開頭的檔名、讀不到目錄回空清單 | owner.rs:41-47 |
| P11 | `UiState` 沒有設定暱稱的方法；`_save` 把寫入串成一列 | ui_state.dart:95-97、:131-138 |
| P12 | `keepScreenOn` 是現成的視窗旗標，軟體更新頁也用 | swupdate.dart:137；SwUpload.kt:77-81 |

## 2. 做法

### 2.1 `NodeLink.loginFor`（設計 §4.3.9；新程式）

- `loginFor(Lease lease, String id, {bool clearNotY = false})`（設計 §4.3.9；core.dart:628 已支援）：`lease` 不是登記表目前的 session 佔用 → `NoLease`。「再試這一台」傳 `clearNotY: true`（剛認領的節點被記成「不是」時才找得到）。
- 開始前即時讀 `KeyAbilities`、看 `core.blocked`；不行 → `precondition`。
- 驅動器自己的欄位（`_lf*`），不碰自動讀取的；`dispose` 一起收掉。
- **掃描**：`gate.scan(lease.token, …)` → `LoginFor.onScan`，掃到新位址就叫醒；60 s 從掃描真的開始算（閘門等名額的時間不算）；掃描被系統結束而登入還沒結束 → 重掃；結束時停掃描（含還在等名額的）。
- **計時**：照 `LoginFor.wakeAt`；`radio()` 改變時叫醒；每次嘗試前看 `lease.valid`；60 s 到時取消嘗試、`await` 關連線。
- **每次嘗試**：`gate.connect(lease.token, addr)` + `HandoffProber`（8 s msg2、msg2 之後 20 s）。失敗先 `await link.close()` 再試下一個；`keyError` → `keyErrorToRadio`。
- 結果：`ok(LoginHandoff)` / `identity` / `refused` / `notFound` / `precondition`。備忘與節點狀態的寫入者仍只有 `NodeLink`。
- `acquire` 先等上一個 `released` 的讀紀錄段（上限 5 s）再檢查 `reg.current`（修 P7）。

### 2.2 交接：`HandoffProber` + `FrameInbox`

- `ended` 那一步的結果對應抽成純函式 `loginOutcome`（prober.dart:96-104 原樣），`SessionProber` 改呼叫它（判定不變）。「收到 `loggedIn` → 成功」是 `HandoffProber` 自己的分支。
- `FrameInbox`：訂閱前建好；暫存清單 + 一個處理者；換處理者時暫存依序交出；prober 在處理 `loggedIn` 時同步把處理者設成「無」。交接後由 `OwnerConsole` 一個接一個處理。
- 成功時不取消訂閱、不 dispose session，交出 `LoginHandoff`；交接後 `link.state` / 訂閱 `onError` 歸 `OwnerConsole`；`close()` 冪等：取消監聽 → 等 `FrameInbox` 正在跑的處理者做完（seal / `writeCas` / `netPersisted`；上限 10 s，超過就照常往下，那一步之後的呼叫會被已釋放的佔用或已關的 session 擋下，方向是紀錄停在 pending → 檢查網路）→ 取消訂閱 → `await link.close()` → dispose session（v9 Q m1、R m5；v10 S-m6、T-m6）。

### 2.3 `OwnerConsole`：從舊控制台複製，只給新頁面

- 新檔 `lib/src/flows/owner_console.dart`，舊控制台不改（PR 6 刪掉時重複消失）。
- 複製：步驟迴圈、`ask`（逾時、unclear / notSent、`ended`；不含重送分支，見下）、`makeNetwork`、`joinNetwork(rel)`、`confirmNetwork(rel)`、`linkCheck`、`sendUpdateFor(rel)`，與 join2 相關的國家 / 被移除過的問題（注入的對話框，計時規則同 nodes.dart:276-291）。**行為與句子和舊控制台相同。**
- 和舊控制台只差在接線：登入用 `loginFor`；寫入用 `RecordWriter.writeCas(lease, …)`（`NoLease` 時照樣呼叫 `persistFailed`）；`join` / `confirm` 吃 `rel`；回 `ConsoleReply`（下面）給頁面（不是 `_say`）；文字紀錄不寫回答內容。
- **回給頁面的契約（v12 X-M1、W-m1、W-m3、W-m4）**：舊 `_ask` 回字串（`'[ANSWER] ${detail}'`，nodes.dart:324；Rust 的 `Err(String)` 變成 `null` + `_askEnd`），新頁面不能照抄這個形狀。`OwnerConsole` 的每個請求回 `ConsoleReply`：

  | 欄位 | 意思 |
  |---|---|
  | `kind` | `answer`（Rust 的 `OwnerKind.answer`）、`refused`（Rust 以 `Err(String)` 拒絕，例如 `NOT_LOGGED_IN`）、`unclear`（送出後逾時 / 斷線，Rust 的結果不明句子）、`notSent`（什麼都沒寫、沒送出）、`ended`、`leaseLost` |
  | `text` | `answer`：Rust 的 `detail` 原樣，**不加** `[ANSWER] ` 前綴；其他：要顯示的句子（Rust 的，或舊控制台同一句） |
  | `persistedRel` | 只在**第一個 `PersistNet` 寫入成功之後**才設（`writeCas` 回成功）；寫入失敗時是 `null`（owner.rs:1144-1151 那一步會 `[REQ_FAIL]`）。結果頁的「有 `rel`」就是看它 |
  | `sendUpdate` / `pollLink` | 照 `OwnerKind.answer` 的旗標 |

  - 判斷只在頁面做、只看這個型別：建立完成 / 檢查拿到回答 = `kind == answer && text.startsWith('[NET_STATE] ')`；加入成功 = `kind == answer && text.startsWith('[JOINED] ')`（v12 X m2；Dart 自己的 `_linkUnknown` 等句子不會是 `answer`）。
  - `ask` **不自己登入**（舊 `_ask` 在 :521 會）：登入一律由頁面用 `loginFor`。**不複製**舊 `_ask` 的重送分支（nodes.dart:547-566）：它只在 `unclear == null && retry` 時走到，PR 3 的五個請求都走不到（建立帶 `unclear`，:486-489；加入 :647、確認 :1244、送新密碼 :1581、連線檢查 :703 都是 `retry: false`）。新頁面也不自動重送（設計 :750）（v13 Z-M2、Y-m5；v13 的「頁面重登再送一次」是我寫錯的）。
  - 舊路徑對到 `kind`（v13 Y-m4）：沒有 session（:525）→ `notSent`；`retry: false` 的請求遇到非字串的寫入錯誤（:554、:580）→ `unclear`；`confirmRemoved` 之後的加入 → 回最後一次請求的 reply，取消或重讀失敗 → `notSent`；國家 / 被移除過的對話框回答「不要」→ `notSent`。
  - `sessionAlive`（v13 Z-m2）：`unclear` / `ended` / 寫入錯誤之後舊碼會 drop session（nodes.dart:571-572），這時為 `false`。頁面要再對同一台送請求前，`sessionAlive == false` → 先 `await close()` 再 `loginFor`；不比對 Rust 的 `NOT_LOGGED_IN` 字串。其他 `refused`（例如 `NET_DAMAGED`、`ADDR_BUSY`）→ 顯示句子、那一台算失敗、問繼續 / 停。
  - 金鑰拒絕（Keystore）→ `OwnerConsole` 照 `core` 的路徑呼叫 `keyErrorToRadio`（app_link.dart:142），回 `leaseLost` 以外的 `refused` 並帶 `keyError` 旗標；迴圈看到就整個停、不問（v13 Z-m8）。
  - `unclear` 的 `text` 是 Dart 的結果不明句子（舊控制台同一句，`_unclearNow`），不是 Rust 的（v13 Y-n4）。
  - 測試（改壞對照）：`text` 加回 `[ANSWER] ` 前綴 → 檢查網路頁從不給「建立網路」的測試 FAIL；`persistedRel` 在寫入前就設 → 「寫入失敗 → 結果頁給再試」的測試 FAIL。
- `leaseLost` 只看 `!lease.valid`（`Refused` 在佔用有效時 = 斷線，照 `ask` 的 unclear / notSent 處理）。
- 原始碼鎖：`lib/src/flows/`、`lib/ui/`（`ui_state.dart` 除外）不准直接呼叫 `storeWriteCas` / `storeWriteSealed` / `storeRemove` / `storeKeepCopy`。
- 防漂移：9b00ca6 的四條路徑測試改成表格驅動，同一組情境對 `OwnerConsole` 也跑。

### 2.4 新頁面怎麼決定建立 / 加入（照現有的規則，不新增）

- 首頁第 6 列與 3.5 / 3.6 照 PR 2 已審的分流（`joinChoice` + `NetRecords`，home_logic.dart:92-96）與設計 §5.1 / §5.3：沒有 net → 「建立網路」；有 net → 「加入網路」；只有 mnet / mpend → 舊控制台（PR 5 換）。
- 用詞（v13 Z-m1）：「有 net」= 手機有任何 `net/` 紀錄（含 pending；PR 2 home_page.dart:131-134、設計 :726 的意思，第 6 列照這個，不改）。「已建立的 net」= `applied` 為真的 `net/` 紀錄，只用在 4.1 pending 畫面與檢查網路頁「要不要給次要『建立網路』」。
- 4.1：
  - 建立：網路名稱、頻道，和舊控制台的「建立網路」一樣。
  - 加入：選目標網路（一筆就不問），和舊控制台的 `_pickNet` 一樣（只列打得開的；標「已建立 / 建立中」，nodes.dart:621）。
  - 4.1 自己看到只有 mnet / mpend（例如從中性入口進來）→ 不給表單，給「到舊控制台」（dev；PR 5 換），field 只顯示句子；不顯示 nodes.dart:612-614 那句「舊節點要重燒」。
  - `NetIndex` 計算中 → 「正在讀取網路紀錄」，算完才給表單；列不出來 → 「讀不到手機裡的網路紀錄」+「再試一次」（重算 `NetIndex`），沒有表單（v9 Q m5、v10 S-m5）。
- **選到的那一筆網路還沒確認建立完成（pending）**時（看選到的那一筆），照 join2 §3.2：不送加入（Rust 會拒絕並叫人按「檢查網路」，owner.rs:506），改成顯示「這個網路還沒確認建立完成」+ 主要「檢查網路」（§2.8）。這句是新畫面的文字，不複製 Rust 的字串。
  - 手機**沒有任何已建立的 net**（全部 pending）時，再給次要「建立網路」（v10 T-M1）：這和第 6 列「沒有 net → 建立」是同一條規則（pending 的網路還不能加入），也是 pending 的建立者壞掉 / 移除時新頁面唯一的出口（舊控制台的這顆按鈕一直在，nodes.dart:1726-1731）。手機已經有已建立的 net 時不給（設計 §5.3 :726：有 net 時刻意不給建立，免得拆成兩個網路）。
- 節點頁的網路分組照設計 §5.5（:755）：這台 `node_state == 1` 而且手機有 net →「加入網路」（開 4.1 加入、預勾這一台）；手機有 pending 紀錄而這台可能是建立者 →「檢查網路」（§2.8，預選這一台）。節點頁**不放**「建立網路」；手機沒有 net 時建立的入口是首頁第 6 列與 3.5 / 3.6（v9 Q-M1、v10 S-m2）。
- 「節點加入網路沒有做完」的待辦（設計 §5.1）→ 4.1 加入表單，目標 = 那筆網路、那一台預設勾。同一頁的「放棄這次加入」= 舊控制台的「忘記加入中的節點」（`_forgetJoining`，join2 §3.4）：不需要登入，是獨立函式（Rust `net_forget_joining`，owner.rs:131，不經 `OwnerConsole`），按下時**自己拿一個 session 佔用、經 `RecordWriter` 寫完就放**（v13 Z-m3）（4.1 平時不拿佔用；`acquire` 回來時頁面已不在 → 立刻 `release()`）。舊控制台 dev 版的「排除這台（換密碼）」分支（nodes.dart:1279-1283）不複製（D7）。設計 §5.1 :698 寫「同一頁」、:784 寫「開發者選項」，本計畫照 :698。
- 按「開始」時在佔用下重新列一次檔，和 4.1 的快照比：net 紀錄的集合、每筆的 `applied`、勾的節點都還在。不同 → 不開始，畫面換成新的快照請使用者再確認（v12 X m6）。4.1 自己做完「放棄這次加入」後更新快照，不會擋到自己。這只是避免表單過期，不是新的規則。

### 2.5 多台迴圈（設計 §5.4）

- 4.1 列出手機所有 `node/` 紀錄，都可以勾（和舊控制台相同，對不對由 Rust 判斷）；最近一次讀到已在網路裡的，顯示狀態、預設不勾（v13 Z-m6）。4.1 開著時 `NodeLink` 用 `Page.home`（P9），剛認領的節點讀到後狀態會更新；離開 4.1 回到進來前的那一頁（`Page.node` 連同節點一起還原，core.dart:186-201）。
- 建立模式：勾的第一台（使用者可以點選換）建立，其餘加入它建出來的網路，目標是那一台建立回來的 `persistedRel`（§2.3）。設計 §5.4 的表就是這樣，不另加條件。
- 加入模式：其餘每台加入 4.1 選的那一筆。
- **頁面堆疊與佔用（照 `openRawPage` 的順序：先 `acquire`、再開頁，raw_use.dart:73-82；v13 Z-M1、Y-m1）**：
  - 按「開始」：**4.1 自己** `acquire` session 佔用，並在佔用下比對快照（§2.4）。
    - `acquire` 被拒 → 4.1 留在畫面上、表單不動，顯示「另一個操作還在進行：<名稱>」（D9）。
    - 快照不同 → `release()`，4.1 換成新快照請使用者再確認。
    - `acquire` 回來時 4.1 已不在 → 立刻 `release()`（raw_use.dart:75-78）。
  - 成功 → 4.1 `push(NetRunPage(lease))` 並 `await`。迴圈與結果是 `NetRunPage` 這**同一個 route** 的兩個階段（v12 W-M1、X-M2）；`NetRunPage` 從此是這個佔用唯一的 `pageGone` 呼叫者（4.1 不再碰它）。
  - `NetRunPage` 回來後：回「去建立」→ 4.1 切到建立模式（§2.8）；其他 → 4.1 pop 回入口頁。入口頁聽 `NetIndex` 的變更通知重畫（§2.6）。
  - 工作期間 `NetRunPage` 拿一個 `hold()`；`PopScope`、`keepScreenOn`。
  - 進結果階段 = 工作做完：`close()`、關 `keepScreenOn`、放掉 `hold`（`_busy` 歸 0，佔用仍在、頁面仍在）。
  - 離開 `NetRunPage`（dispose）→ `pageGone()`，這時沒有 hold → 立刻釋放。
  - 工作途中頁面消失（app 被系統關頁）：先 `pageGone()`（有 hold，`_busy > 0`，開始 420 s 期限），等當前請求做完（撐住佔用的是 `hold`，v13 Z），不做之後的送新密碼與連線檢查，不開下一台、不彈對話框，`close()`、關 `keepScreenOn`，**然後**放 `hold` → 佔用立刻釋放。`pageGone` 之後不開新的登入、自動檢查或下一台；`loginFor` 進行中頁面消失、之後登入成功 → 不送建立 / 加入，直接 `close()`（照舊控制台 nodes.dart:405-409；v13 Z-m5）。剩下的只有當前那一個請求（≤ 60 s 登入或 ≤ 360 s 建立，設計 :737），在 420 s 內。
- 每一台：上一台 `close()` 完成 → `loginFor` → 建立或加入。回來的 `ConsoleReply` 照 §2.3 判斷。
  - 建立：`makeNetwork`。
    - 沒有 `persistedRel` → 整個流程停，顯示句子；不自動檢查（反向測試）。
    - 有 `persistedRel` → 在佔用下重讀**那一筆**紀錄（§2.6）。已建立 → 繼續。不是 → 照設計 §5.4 自動「檢查網路」一次：`sessionAlive` → 直接 `confirmNetwork(persistedRel)`；否則先 `await close()`（`BleGate` 一次一條，ble_gate.dart:226-231）→ 再 `loginFor` 一次（60 s）→ `confirmNetwork`。等確認回答 15 s（舊控制台 `_ask` 預設，nodes.dart:511-513；D10）。之後重讀那一筆；仍不是 → 整個流程停，結果頁那一列給「檢查網路」（§2.8，借用同一個佔用）。A18 在真機確認。
  - 加入：`joinNetwork(rel)` → 加入成功 = `kind == answer && text.startsWith('[JOINED] ')`（§2.3、P8）。
    - 有 `sendUpdate` → 接著 `sendUpdateFor(rel, member: false, confirm: false)`（照舊控制台 nodes.dart:668，不彈確認框）。送新密碼失敗 → 那一台記「已加入，新密碼沒有送出」+ 句子，算失敗、問繼續 / 停。
    - 有 `pollLink` → 連線檢查（每 10 s、120 s）。
  - 其他（`refused`、`unclear`、`notSent`、登入失敗）→ 顯示句子，問「繼續下一台 / 先停在這裡」（返回鍵 = 停）。不自動重送（設計 :750）。
  - 先看 `core.blocked` 或 `precondition`、`ConsoleReply` 的 `keyError`：藍牙、權限、金鑰 → 整個流程停、不問。`leaseLost` → 整個流程停。
- 結果頁：逐台列結果（成功 / 失敗原因 / 還沒做，設計 §5.4 :746）。**一次只做一件事**：一列的「再試這一台」或「檢查網路」進行中，其他列的按鈕停用（`BleGate` 一次一條；舊控制台用 `_busy`；v13 Z-m4）。做完後那一列換成最新的結果。對話框（繼續 / 停、國家、被移除過）開著時頁面消失 → 當成「停 / 不要」，照舊控制台。停下之後還沒做的台不在這裡接著做（重開 4.1，設計 :748 的第 6 列會顯示它們）。每一列的下一步（照設計 :750）：
  - 建立列、**有 `persistedRel`** → 只有「檢查網路」（預選那一列的節點）；**不給**「再試這一台」（再建立會是第二個網路，owner.rs:1067-1088）。
  - 建立列、沒有 `persistedRel`（什麼都沒寫成功、沒送出）→「再試這一台」= 再 `makeNetwork` 一次，之後照迴圈的建立規則（含自動檢查一次）。
  - 加入列 →「再試這一台」= `joinNetwork(rel)`（D5）。
  - 「再試這一台」「檢查網路」**借用**同一個佔用（各自在工作時拿 `hold`、做完先 `await close()` 再放 `hold`，不呼叫 `pageGone` / `release`）；「再試這一台」照迴圈的等待規則（`PopScope`、`keepScreenOn`、頁面消失就停）。
  - 結果頁本身沒有「建立網路」；建立網路的入口在檢查網路頁（§2.8）。
- `close()`（§2.2）先等進行中的步驟（seal / CAS）做完，再 dispose session。

### 2.6 `NetIndex`（設計 §4.3.8）

- 由 `AppLink` 持有；啟動檢查通過與 `released` 之後各算一次；不在 `acquire` 的等待裡。佔用期間不重算；新頁面在佔用中要判斷某一筆有沒有建立完成時，直接重讀那一筆紀錄（`storeReadSealed` + Kotlin `open` + `netSummary` 取 `applied`），不看 `NetIndex`。「讀不到」頁的「再試一次」= 重算 `NetIndex`（§6 有測試）。
- 列檔（和 `list_kind` 同規則：濾 `.` 檔；`PathNotFoundException` = 空，在 `toList()` 接；其他錯誤 = 列不出來）決定「有沒有」；解密只取名稱、`applied`、成員；壞的一筆記一行（只寫 net id 前 8 碼，不含內容；§6 有測試）。
- 提供變更通知（`ChangeNotifier`）：首頁、4.1、節點頁聽它重畫，不靠 `await push` 回來（v12 X m7）。
- 只留代號最新的一次；計算中 → 第 6 列、3.5 / 3.6 用中性的「加入網路」（PR 2 的 D-m9 做法）。
- 待辦「節點加入網路沒有做完」：`joining` 的成員對到這支手機的節點（Rust `MemberView` 加 `deviceId`：`net_summary` 已有 `m.device_id`，一行 + 一個 Rust 測試）。

### 2.7 新增節點：`ClaimPage`（D1）

- 換 `build` 的樣式；`_claim` / `_find` / `_recover` 不動，`claim_*` 測試不改判定。開發用輸入只在 devTrust 顯示（設計 §5.3）。
- 新增 `openRawPageFor<T>`（舊的 `openRawPage` 不動，P6）；認領 / 恢復 / 覆寫成功時 `pop(ClaimDone(id))` → 3.2 暱稱（`UiState.setNick`：1–24 字、拒絕 Cc / Cf / Zl / Zp）→ 3.5 / 3.6。
- F41：不加 `PopScope`（設計 §4.4）；被 pop 後的結果句寫到 `AppLink.lastClaimNote`，首頁顯示一次。

### 2.8 檢查網路頁（設計 §5.4 的「檢查網路」）

- **先選對象、再拿佔用**：預選 = pending 紀錄裡建立者 `name`（`node-<last4>`）對到手機唯一一筆 `node/` 的那台（只是預選與顯示）；對不上或多筆 → 讓使用者選。頁面寫明「檢查的是節點 XXXX」。從節點頁進來時預選那一台。節點頁的「檢查網路」條件 = 手機有 pending 紀錄、而且它的建立者名稱對到這一台（同上的名稱比對；真正的判斷在登入後用 `nodeDacHash`，v11 V m6）。
- 佔用：
  - 拿到佔用（或借用）後，**重新列檔並解密 net 紀錄**，得到這一頁要用的兩個值：要檢查的 pending 清單、手機有沒有已建立的 net（不看 `NetIndex`：借用時剛建立的那一筆還不在裡面，`NetIndex` 也可能還在算；v11 V m2、U-m4）。列不出來 → 只給「再檢查一次」，不給建立。打不開的單筆照 `NetIndex` 同一個函式、同一規則（跳過、記一行只含 net id 前 8 碼；舊控制台也跳過）（v12 W-m5）。重新列檔後沒有要檢查的 pending → 「沒有需要檢查的網路」+「完成」，不給建立（v12 X m3）。
  - 從 4.1 或節點頁進來：本頁 `acquire`（回來時頁面已不在 → 立刻 `release()`）；工作時 `hold`；離開時 `pageGone()`。
  - 從結果頁進來：**借用**結果頁的佔用，工作時 `hold`、做完放，不呼叫 `pageGone` / `release`。
  - 返回鍵：登入或確認進行中時 `PopScope` 擋住並顯示「正在檢查」；不開 `keepScreenOn`（登入 ≤ 60 s + 每筆確認 ≤ 15 s；切背景時照現況，Rust 回答不明 → 顯示句子）。
- 登入對象 → 用**現有的**值判斷這台是哪幾筆的建立者：`MemberView.creator && dacHash == session.nodeDacHash()`（owner.rs:84-87、:114-119、:991-994；v10 S-m1、T-m3，不加 bridge 函式）。
  - 一筆都不是 → 「這台不是這些網路的建立者」+「換一台檢查」；不送確認、不給「建立網路」（手選錯台時不會出現 Rust 的「可以再建立一次」，owner.rs:478）。
  - 是 → 在**同一次登入**裡依序 `confirmNetwork` 這幾筆（從結果頁進來時先檢查剛建立的那一筆），每筆顯示 Rust 的句子（`confirm` 對錯的紀錄只會 `NoChange` / `OtherVersion`，netrec.rs:509-537；同一次登入連續確認可行，owner.rs:879-893、:1107-1114；節點唯讀動詞每條連線 burst 20）。
  - 每筆的判斷（v10 S-M1、T-m6）：
    - **拿到回答** = 這一筆**確認請求本身**的 Rust 回答，文字以 `[NET_STATE] ` **開頭**（owner.rs:484-491；不是「含有」——被入侵的節點能把字串塞進錯誤句子中間，owner.rs:645-650；Dart 自己的 `_makeUnclear`，nodes.dart:50，不算；v11 U-m1、V m1）。「還在設定中」「無法確定」這兩種回答也算拿到回答、照舊控制台會給「建立網路」（基準，測試鎖住）。`[REQ_FAIL]`、寫入失敗（`persistFailed`）、結果不明、連線斷 → 沒拿到回答，**整頁停**。
    - **升級** = 拿到回答後在佔用下重讀那一筆、`applied` 為真（`storeReadSealed` 那一筆 + Kotlin `open` + `netSummary`；不是 `AppLink.readRecords`，它只列 `node/`，app_link.dart:72-85）（§2.6，不看 `NetIndex`、不看句子）→ 停。
- 每次工作結束（成功、失敗、停）都先 `await close()` 再更新畫面，返回結果頁後「再試這一台」才連得上（ble_gate.dart:226-231；v11 U-m2）。
- 結果：
  - 有一筆升級 → 顯示 Rust 的句子，「完成」。
  - 每一筆都拿到回答、都沒升級，而且手機沒有任何已建立的 net → 「再檢查一次」+ 次要「建立網路」（舊控制台一直有，nodes.dart:1730；和 §2.4 同一條「沒有已建立的 net 才建立」）。
  - 其他（登入失敗、沒拿到回答、不是建立者）→ 只有「再檢查一次」/「換一台檢查」。
- 按「建立網路」：
  - 從 4.1 進來（自己拿佔用）：`close()` → pop「去建立」回 4.1（本頁 dispose 時 `pageGone()` 釋放）→ 4.1 切到建立模式（不另開一個 4.1；v13 Y-m2、Z-m7）。
  - 從節點頁進來（自己拿佔用）：`close()` → `pushReplacement(4.1 建立模式)`（本頁 dispose 時釋放）。
  - 借用的（從結果頁進來）：`close()` → pop「去建立」給 `NetRunPage` → `NetRunPage` pop「去建立」給 4.1（dispose 時 `pageGone()` 釋放）→ 4.1 切到建立模式（v10 T-m1、v12 X-M2）。
  - 退場動畫結束前按 4.1 的「開始」，`acquire` 會因為佔用還在被拒（node_link.dart:153-154），4.1 留在畫面上顯示「另一個操作還在進行」，再按一次即可（D9）。

## 3. 介面

### 3.1 擁有權（新的資源）

| 資源 | 唯一的寫入者 |
|---|---|
| session 佔用的 `pageGone` / `release` | **acquire 的那一方**：4.1 `acquire` 後交給 `NetRunPage`（之後只有 `NetRunPage` 呼叫 `pageGone`；4.1 只在交出前的失敗路徑 `release`）、從 4.1 / 節點頁進來的檢查網路頁、「放棄這次加入」。借用的頁面只拿 / 放自己的 `hold` |
| `loginFor` 的掃描與嘗試連線 | `NodeLink`（`_lf*`） |
| 交接後的連線、訂閱、`FrameInbox`、`OwnerSession` | `OwnerConsole` |
| net 紀錄（新頁面） | `OwnerConsole` 經 `RecordWriter`（舊控制台、`ClaimRecords` 照舊） |
| `NetIndex` | `NetIndex` |
| `keepScreenOn` | `NetRunPage`（迴圈與結果頁「再試這一台」的等待期間）；軟體更新頁（現況）。一次一個佔用，不重疊。檢查網路頁不用 |
| 暱稱 | `UiState.setNick` |
| `AppLink.lastClaimNote` | `ClaimPage` 寫、首頁讀後清 |

### 3.2 生命週期（新頁面）

| 情況 | 行為 | 測試 |
|---|---|---|
| 開始 | 4.1 平時不拿佔用；按開始時 4.1 `acquire` + 比對快照，成功才 push `NetRunPage`；被拒 → 4.1 留著顯示原因；快照不同 → 釋放、更新表單；`acquire` 回來時 4.1 已不在 → 立刻釋放 | T-M1(a) |
| 正常結束 | 結果頁 `close` + 關 `keepScreenOn` + 放 hold；離開時 `pageGone` 立刻釋放；`NetIndex` 重算 | T-M1(b) |
| 建立中途 app 被殺 | 照 join2：紀錄停在 pending → 首頁第 6 列「加入網路」→ 4.1 選到 pending →「檢查網路」（全部 pending 時另有「建立網路」）；或節點頁「檢查網路」 | T-M2(a) |
| 加入中途 app 被殺 | 照 join2：成員停在 joining → 首頁待辦「節點加入網路沒有做完」 | T-M2(b) |
| 等待中切背景 / 關螢幕 | `keepScreenOn`；佔用中不自動讀 | T-M1(c)、R-7 |
| 藍牙 / 權限 / 金鑰 | 整個流程停 | T-M1(d) |
| 節點重開 / 斷線 | Rust 的結果不明句子 → 問繼續 | T-M1(e) |
| 佔用被收回 | 整個流程停 | T-M1(f) |
| 工作途中頁面消失 | `pageGone` → 等當前請求寫完 → 收尾 → 放 hold → 釋放；那一次寫入成功、沒有「沒存完」待辦 | T-M1(g) |
| 結果頁 → 檢查網路 → 返回 → 再試這一台 | 借用的佔用沒被放掉，再試照常 | T-M1(h) |
| 檢查網路頁（借用）→ 建立網路 → 4.1 → 開始 | 結果頁已 pop、佔用已釋放，4.1 拿得到 | T-M1(i) |
| 檢查網路頁（自己拿）→ 建立網路 → 4.1 → 開始 | 本頁 pop 時釋放，4.1 拿得到 | T-R1(a) |
| 檢查網路頁：返回鍵 | 登入 / 確認中擋住；其他時候離開 → 自己拿的釋放、借用的不放 | T-R1(b) |
| 檢查網路頁：頁面消失 | 同上一列「工作途中頁面消失」，借用的只放 hold | T-R1(c) |
| 檢查網路頁：藍牙 / 權限 / 金鑰、佔用被收回 | 停，只給「再檢查一次」 | T-R1(d) |
| 檢查網路頁：切背景 / 關螢幕 | 不開 `keepScreenOn`；回答不明 → 沒拿到回答 → 只給「再檢查一次」 | T-R1(e) |
| 升級 / 降級 | 紀錄格式不變（`MemberView.deviceId` 只是 Rust 回給 Dart 的顯示欄位） | — |

## 4. 和設計不同的地方

- **D1** 認領留在 `ClaimPage`（原始佔用）、只換樣式；不給步驟清單與經過時間；`ClaimPage` 改走 `BleGate` 進殘項（PR 6）。
- **D2** 舊控制台照舊、不經 `RecordWriter`（PR 6 刪）。
- **D3** 只有 mnet / mpend 的入口仍開舊控制台（PR 5 換）。
- **D4** 網路摘要表放在 `NetIndex`，不在 `NodeLink`（`NodeLink` 不碰 Keystore）。
- **D5** 加入結果不明時，結果頁的下一步是「再試這一台」（設計 §5.4 寫「檢查網路」）：照舊控制台與 Rust 的句子（「稍後在這台按『加入網路』」，owner.rs:531-532）；`confirm` 只升級建立者、不升級加入者（netrec.rs:524-527），對加入者按「檢查網路」不會有結果。
- **D6** 和舊控制台不同（設計已定，列出供核對）：
  - 建立後重讀不是已建立 → 自動檢查一次（設計 §5.4；舊控制台要人按）。只在拿到 `PersistNet` 的 `rel` 時做。
  - 「建立網路」不是一直都在（舊控制台 nodes.dart:1726-1731 一直有）：只在手機沒有已建立的 net 時給——第 6 列與 3.5 / 3.6（沒有 net）、4.1 選到 pending 而且全部 pending（§2.4）、檢查網路頁每筆都拿到回答且沒升級（§2.8）。節點頁不放。手機已經有已建立的 net、又真的要另建一個網路時（拆隊）→ dev 用舊控制台；field 版在這一版沒有這個入口（§8）。
- **D7** 「放棄這次加入」不含舊控制台 dev 版的「排除這台（換密碼）」分支；要排除時用舊控制台（PR 5 / 6 再處理）。
- **D8** 節點頁網路分組：設計 :755 列「加入網路 / 檢查網路」，:758 的字面可讀成手機沒有 net 時也給建立；本計畫照 :312、:755——節點頁從不給「建立網路」，手機沒有 net 時這台的入口是首頁第 6 列與 3.5 / 3.6（v11 U-n1）。
- **D9** 從檢查網路頁或 `NetRunPage` 回到 4.1 時，佔用在 dispose（退場動畫之後）才交回；這段空檔內按 4.1 的「開始」會被拒（`acquire` 先看 `reg.current`，node_link.dart:153-154），4.1 留在畫面上說「另一個操作還在進行」，再按一次即可。不另加機制（v11 U-n2、v12 W-m2）。
- **D10** 檢查網路的等待：設計 §5.4 表（:738）寫 60 s；本計畫照舊控制台 `_ask` 的 15 s（nodes.dart:511-513），`OwnerConsole` 是舊控制台的複製（v12 W-m6）。

## 5. 安全

- 新的輸入面只有網路名稱（Rust 檢查，同舊控制台）、暱稱（`setNick` 過濾）、勾選的節點（只能是 `node/` 紀錄）。沒有新的平台方法或匯出元件。
- 新頁面沒有佔用時，`BleGate` 與 `RecordWriter` 拒絕（fail-closed）；比舊控制台多一層檢查。
- 遠端 BLE / 惡意廣播：照 `core.LoginFor` 的 8 s msg2 預算與備忘；約 7 個不回應的位址能吃光 60 s（設計接受）。
- 被入侵的節點：照 join2 §6 的分析（只能換掉自己在 net 紀錄裡的成員項，join2flow.rs:345-365）；本 PR 不改。
- 秘密：`OwnerConsole` 不寫回答內容；位址經 `NodeLink.mask`。

## 6. 步驟（每一步跑全套、各自附改壞對照）

1. ✅ 舊控制台補測試（9b00ca6，改壞 5/5）。
2. `loginOutcome` 抽出 + `NodeLink.loginFor` + `HandoffProber` + `FrameInbox` + `acquire` 等 `released`。測試：T-L17（慢的 `readRecords`）、T-L18（`clearNotY`）、T-S3、掃描叫醒 / 名額 / 重掃 / 60 s 收尾、失敗關連線、交接不丟訊框、訊框依序。改壞各一。
3. `OwnerConsole` + 「放棄這次加入」的獨立函式+ `RecordWriter` 寫入 + 原始碼鎖 + 表格驅動的四條路徑（「重送一次」那一列只對舊控制台跑，`OwnerConsole` 那一列斷言不重送）。測試：寫入失敗 → 只送一次、不自動重送（改壞 = 複製重送分支 → FAIL）、各舊路徑對到的 `kind`（Y-m4 的四條）、`sessionAlive`、金鑰拒絕 → `keyError` 且整個停不問、unclear / notSent、逾時、國家問題不計時（推 400 s）、`ended`、`Refused` 且佔用有效 ≠ `leaseLost`、persist 時佔用收回 → `leaseLost` 且呼叫 `persistFailed`。改壞各一。
4. `NetIndex` + `MemberView.deviceId` + 首頁第 6 列 / 待辦改用它。測試：T-L19、T-N2、列檔規則、計算中、「讀不到」→「再試一次」重算、壞的一筆的記錄行只有 net id 前 8 碼（斷言整行不含其他內容）。改壞各一。
5. 多台迴圈 + 4.1–4.5 + 檢查網路頁。測試：T-M1(a)–(g)、T-M2、`[JOINED]` 只看加入請求的回答（連線檢查的 `[JOINED]` 不算）/ 已建立 判定（含國家未驗證的成功）、`send_update` → 送新密碼、建立後沒套用 → 自動檢查一次、沒有 `PersistNet` → 不自動檢查、自動檢查遇到 `NOT_LOGGED_IN` → 重新 `loginFor` 一次、pending（選到的那一筆）時 4.1 給「檢查網路」、全部 pending → 另有「建立網路」、有已建立的 net → 沒有、節點頁：從不給「建立網路」、節點已在網路但紀錄 pending → 有「檢查網路」、檢查網路頁：登入的不是建立者（`nodeDacHash` 對不上）→ 不送確認、沒有「建立網路」、兩筆 pending 且節點在第一筆 → 第一筆升級（重讀那一筆，不看 `NetIndex`；借用佔用時也一樣）、升級後寫入失敗 → 停、沒有「建立網路」、登入失敗 → 沒有「建立網路」、有已建立的 net → 沒有「建立網路」、`acquire` 回來時頁面已不在 → 立刻釋放、借用時不呼叫 `pageGone` / `release`、`close()` 等處理者（慢的 `writeCas` + 逾時 → 不會在 dispose 後呼叫 `netPersisted`）、結果頁：有 `rel` 的建立列沒有「再試這一台」（改壞 = 給再試 → FAIL）、沒有 `rel` 的建立列再試 = `makeNetwork`、加入列再試 = `joinNetwork`、檢查網路頁做完後「再試這一台」連得上（沒 `await close()` → `BleGate` 拒絕 → FAIL）、自動檢查重新登入前關掉前一條、拿到回答只認開頭的 `[NET_STATE] `（句子中間有這個字串的錯誤 → 沒有「建立網路」）、「還在設定中」「無法確定」→ 有「建立網路」（基準）、借用時剛建立的 pending 會被檢查（重新列檔，不看 `NetIndex`）、`pageGone` 之後不開新的登入、確認等 15 s、再試中返回被擋、結果畫面出現時 `reg.current` 仍在（真的 `Navigator`；改壞 = 結果另開 route → FAIL）、4.1 `acquire` 被拒時表單還在（改壞 = 先換頁再 acquire → FAIL）、檢查網路頁從 4.1 按建立 → 堆疊只有一個 4.1、結果頁一列進行中其他列停用、`loginFor` 中頁面消失 → 不送建立、國家對話框開著時頁面消失 → 回答不要、`NetIndex` 每次重算完成都通知、`ConsoleReply.text` 沒有 `[ANSWER] ` 前綴、`persistedRel` 只在寫入成功後設、`ask` 不自己登入、加入成功只認開頭的 `[JOINED] `、重新列檔後沒有 pending →「沒有需要檢查的網路」、自己拿佔用時 `NetIndex` 計算中也能檢查、開始時快照不同 → 不開始、`NetIndex` 通知 → 首頁重畫、`sendUpdateFor` 失敗 → 那一台算失敗、「放棄這次加入」自己拿放佔用、頁面消失時等寫入完成才放 hold、`close()` 等進行中的步驟、借用的佔用不被釋放（T-M1(h)）、從結果頁建立 → 4.1 開始拿得到佔用（T-M1(i)）、T-R1、`NetIndex` 列不出來 → 4.1「讀不到」、表單過期、4.1 用 `Page.home`（真的 `NodeLinkCore`）、T-C2 / T-C3。改壞各一。
6. `ClaimPage` 換樣式 + `openRawPageFor<T>` + `ClaimDone` + `setNick` + F41。`claim_*` 與 `openRawPage` 的測試不改判定；T-C3、T-V1、T-F41。改壞各一。
7. 首頁、節點頁、3.5 / 3.6 接線；兩位程式審查；真機。

## 7. 真機（要使用者同意；開始前另列副作用）

- 從零：`prov-bench-s0-254.sh unclaimed` 讓 02、04 回未認領（離開 N0；場次後留在 app 建的網路或 `restore` 回 N0，開始前擇一）；手機上移除兩筆節點紀錄。
- 情境：新增 04 → 建立 → 新增 02 → 加入；兩台一起勾；建立途中拔電 → 檢查網路 →（Rust 說沒套用時）建立網路；拔電時 04 已套用與沒套用兩種都做、都記（v9 Q-M2、v10 T）；只有 pending、04 不開機 → 4.1 的次要「建立網路」。A18：建立回來是否已套用。每條做設計 R-7 的三種中斷與 X13；記「正在連到節點…」的秒數。

## 8. PR 內文要寫明的限制

- 手機 Wi-Fi 在 PR 4；隊員路徑在舊控制台（PR 5）；field 版跑不起來（#255），「別人的手機」= dev 版；認領沒有步驟清單（D1）。
- 手機已有已建立的網路、又要另建一個網路（拆隊）：新頁面不給，dev 用舊控制台；field 版這一版沒有入口（D6）。pending 紀錄在新頁面不能刪（照舊控制台）。舊的 pending 刪不掉，所以那台節點頁的「檢查網路」會一直留著（v12 X m9）。兩項都寫進 #329 checklist。

## 9. v1–v6 審查保留下來的（關於新程式的；v7 的兩位審查在 v8 改方向時停掉，沒有報告）

| 來源 | 內容 | 在哪 |
|---|---|---|
| v1 A-B1 / B-B1、v2 C-M1、v3 E-M3 | `loginFor` 照設計、自己掃描與排程 | §2.1 |
| v2 D-M2、v3 F-M1、v4 H m7 / m8 | 交接、`FrameInbox`、`loginOutcome` 範圍 | §2.2 |
| v1 A-M1、v2 C-M2 / D-M1 | 佔用語意、`leaseLost` 看 `lease.valid` | §2.3 |
| v1 B-M-2 | 複製、不搬移 | §2.3 |
| v3 F-M2 | `openRawPageFor<T>` | §2.7 |
| v2 C m2 / B M-3、v4 G-M3、v5 I-M3 | `acquire` 等 `released`、4.1 `Page.home` | §2.1、§2.5 |
| v3 E m、v4 H m12 | 列檔規則 | §2.6 |
| v4 H m9 | 防漂移的表格驅動測試 | §2.3 |
| v3 F m | `setNick` 不會和 `noteReads` 競爭（已串成一列） | P11 |

**拿掉的**（重新決定了 join2 已定案的行為，或是為此加的新機制）：建立閘門表、「重新建立」與清除紀錄、`netPresence` / `netState` / `isCreator` / `joinEnd` 等 Rust 新欄位、重讀紀錄的結果分類、建立者的額外條件、首頁「在另一個網路」的新警告。若之後真的需要，各自對照 join2 開新的設計，不在 PR 3。

### v8 審查 O、P 的對應

| 項目 | 處理 |
|---|---|
| O-M1 檢查網路頁、pending 的入口與對象 | §2.4 檢查網路頁、pending 時 4.1 的處理 |
| O-M2 漏了送新密碼 | §2.5 `send_update` → `sendUpdateFor` |
| O-M3 和設計不同處沒列 | §2.5 照設計自動檢查一次（不再是偏離）；§4 D5（加入不明 → 再試這一台）；§7 A18 |
| P-M1 `clearNotY` | §2.1 |
| P-M2 pending 時沒有「建立網路」 | §2.4（4.1 與節點頁的次要「建立網路」） |
| O m / P m `[JOINED]` 也在連線檢查句子裡 | P8、§2.5 只看加入請求的回答 |
| O m / P m 頁面消失 | §2.5 立刻放 hold、關 `keepScreenOn` |
| O m `NetIndex` 紀錄行 | §2.6 只寫 net id 前 8 碼 |
| O m / P m 建立者與 `rel` | §2.5 建立模式（照設計 §5.4，第一台建立、可換；`rel` 取自 `PersistNet`） |
| P m 待辦與「放棄這次加入」 | §2.4 |
| P m 計算中按「加入網路」 | §2.4 |
| P 基準備註（佔用檢查與寫入之間的空檔） | 記錄；屬 PR 1 的基準行為，不在本 PR 改 |

### v9 審查 Q、R 的對應（v10）

| 項目 | 處理 |
|---|---|
| Q-M1 / R m8 節點頁「建立網路」沒條件、沒「檢查網路」 | §2.4：節點頁照設計 §5.5 只有「加入網路」/「檢查網路」，不放建立；D6 |
| Q-M2 多筆 pending、登入失敗也給建立 | §2.8：同一次登入檢查建立者是這台的每一筆 pending，升級就停；只有拿到 Rust 回答才給「建立網路」；§6 第 5 步兩條測試 |
| R-M1 兩個釋放者、建立網路時佔用怎麼交 | §2.5 / §2.8 / §3.1：誰 acquire 誰放，借用的不放；按「建立網路」先放自己的；T-M1(h)(i) |
| Q m1 / R m5 `close()` 時還在跑的步驟 | §2.5：`close()` 先等進行中的步驟再 dispose |
| Q m2 / R m7 生命週期表 | §3.2：拿掉不存在的 pending 待辦，改寫實際路徑；加檢查網路頁（T-R1）、借用與交接兩列 |
| Q m3 4.1 pending 看全部 | §2.4：看選到的那一筆；選單標「已建立 / 建立中」 |
| Q m4 / R m2 送新密碼參數與失敗 | §2.5：`member: false, confirm: false`；失敗 = 那一台失敗、問繼續 |
| Q m5 / R m9 `NetIndex` 列不出來、只有 mnet | §2.4：「讀不到」、沒有表單；只有 mnet / mpend → 到舊控制台，不顯示重燒那句 |
| Q m6 / R m9 紀錄行斷言 | §6 第 4 步 |
| Q m7 先選對象再拿佔用 | §2.8 |
| R m1 自動檢查和舊控制台不同 | §2.5：只有拿到 `rel` 才做；D6 |
| R m3 對象比對、多筆 pending | v10 誤說要新函式；v11 起登入後用現有的 `nodeDacHash()` 精確比對（§2.8），名稱只用來預選；多筆 pending 由 Q-M2 的逐筆檢查處理 |
| R m4 「放棄這次加入」沒有佔用；dev 排除分支 | §2.4：自己拿短佔用；D7 |
| R m6 頁面消失放 hold 的順序 | §2.5：當前請求的 `lease.run` 結束後才放；T-M1(g) |
| R m9 `Page.node` 還原、owner.rs:568 | §2.5；§2.4 改成 :506，4.1 的句子不複製 Rust 字串 |

### v10 審查 S、T 的對應（v11）

| 項目 | 處理 |
|---|---|
| S-M1 / T-m6 「升級」「拿到回答」沒定義；`NetIndex` 佔用中不算 | §2.8：回答 = 以 `[NET_STATE]` 結束；升級 = 佔用下重讀那一筆；`[REQ_FAIL]` / 寫入失敗 → 停、不給建立；§2.6 寫明佔用中重讀單筆 |
| T-M1 / S-m3 pending 建立者壞掉時沒有建立出口 | §2.4：4.1 選到 pending 而且全部 pending → 次要「建立網路」（同第 6 列的規則）；D6、§7 |
| S-m1 / T-m3 精確比對不需新函式 | §2.8：登入後 `MemberView.creator && dacHash == nodeDacHash()`；不是建立者 → 不送確認、不給建立 |
| S-m2 節點頁「同第 6 列」會給建立 | §2.4：節點頁只在手機有 net 時給「加入網路」，從不給建立 |
| S-m4 / T-m2 自動檢查斷線 | §2.5：`NOT_LOGGED_IN` / 斷線 → 再 `loginFor` 一次（60 s）+ 確認 60 s；沒有 `PersistNet` 不檢查（反向測試） |
| S-m5 `NetIndex` 讀不到沒出路 | §2.4：「再試一次」重算 |
| S-m6 / T-m1 / T-m4 佔用用法、交接順序、`close()` 上限 | §2.5、§2.8：`hold` / `pageGone` / `release` 各由誰叫；借用頁 pop 值回結果頁、結果頁 pop 後才開 4.1；`acquire` 後頁面不在 → 立刻釋放；§2.2 `close()` 等處理者上限 10 s；§3.2 檢查網路頁分列 |
| T（Q-M2 補）§7 兩種情況 | §7 |

### v11 審查 U、V 的對應（v12）

| 項目 | 處理 |
|---|---|
| V-M1 / U-m4 結果頁建立列的「再試這一台」 | §2.5：有 `rel` 只給「檢查網路」；沒有 `rel` 才再 `makeNetwork`；加入列再 `joinNetwork`；再試照迴圈的等待規則；§6 改壞對照 |
| U-m1 / V m1 「拿到回答」用開頭判斷、只認確認請求本身；還在設定中 / 無法確定 | §2.8；§6 測試 |
| U-m2 / U-m3 / S-m6 第二點 關連線再返回 / 再登入 | §2.5、§2.8：`await close()` |
| V m2 佔用中的兩個輸入 | §2.8：拿到佔用後重新列檔解密 |
| V m3 等待時間 | 照舊控制台 15 s（nodes.dart:91） |
| V m4 頁面消失後不開新工作 | §2.5 |
| V m5 頁面堆疊、還沒做的台 | §2.5 |
| V m6 節點頁「可能是建立者」 | §2.8：名稱預選，登入後 `nodeDacHash` 判斷 |
| V m7 / U nit `readRecords` 名稱、:617、§9 R m3 | 改成 `storeReadSealed` + `open` + `netSummary`（claim_records.dart:33、owner.dart:51）；:621；§9 改寫 |
| V S-m5 重算時機 / 測試 | §2.6、§6 第 4 步 |
| V 「放棄這次加入」acquire 後頁面不在 | §2.4 |
| U-n1 / U-n2 | D8、D9 |

### v12 審查 W、X 的對應（v13）

| 項目 | 處理 |
|---|---|
| X-M1 / W-m1 / W-m3 / W-m4 `OwnerConsole` 回傳沒定義 | §2.3 `ConsoleReply` 表：`text` 不帶 `[ANSWER] `、`persistedRel` 寫入成功後才設、`ask` 不自己登入、寫入失敗回 `notSent` 由頁面重登再送；改壞對照兩條 |
| W-M1 / X-M2 `pushReplacement` 放掉佔用、入口頁提早回來 | §2.5：迴圈與結果同一個 route `NetRunPage`；入口頁聽 `NetIndex` 通知；§2.8 誰 `pushReplacement` 4.1；§6 用真 `Navigator` 斷言 |
| X m1 / W-m6 60 s vs 15 s | §2.8 改 15 s；D10 |
| X m2 加入成功用開頭判斷 | §2.3 |
| X m3 沒有 pending | §2.8 |
| X m4 / W-m2 D9 說法不符 | D9 改寫 |
| X m5 頁面消失時對話框開著 | §2.5：當成停 / 不要 |
| X m6 開始時比對什麼 | §2.4 |
| X m7 `NetIndex` 通知 | §2.6 |
| X m8 結果列更新 | §2.5 |
| X m9 舊 pending 的「檢查網路」一直在 | §8、#329 checklist |
| W-m5 重新列檔遇到打不開的 | §2.8：同 `NetIndex` 規則 |
| W nit `keepScreenOn` 寫入者、再試中返回、行號、自己拿佔用 + 計算中 | §3.1、§6、行號改正 |

### v13 審查 Y、Z 的對應（v14）

| 項目 | 處理 |
|---|---|
| Z-M1 / Y-m1 `acquire` 放在 `NetRunPage.initState` | §2.5：4.1 `acquire` + 比對快照，成功才 `push(NetRunPage)`；被拒 / 快照不同留在 4.1；D9、§3.1、§3.2 |
| Z-M2 / Y-m5 自動重送不存在於舊控制台 | §2.3：不複製重送分支；§2.5 不自動重送；§6 第 3 步改壞對照 |
| Y-m2 / Z-m7 兩個 4.1 | §2.8：從 4.1 進來 pop「去建立」回 4.1；借用的經 `NetRunPage` pop 回 4.1 |
| Y-m3 `rel` 改 `persistedRel` | §2.5 全部改用 `persistedRel` |
| Y-m4 舊路徑對到 `kind` | §2.3 |
| Z-m1 「net」的定義 | §2.4 用詞 |
| Z-m2 `sessionAlive`、其他 refused | §2.3、§2.5 |
| Z-m3 「放棄這次加入」不需要 session | §2.4、§6 第 3 步：獨立函式 |
| Z-m4 結果頁一次一件事 | §2.5 |
| Z-m5 `loginFor` 中頁面消失 | §2.5 |
| Z-m6 哪些節點可以勾 | §2.5 |
| Z-m8 金鑰拒絕 | §2.3 `keyError`、§2.5 |
| Y-n1–n4、Z 兩個小提醒 | §3.1、§6、§2.3、§2.5（`hold` 用詞、預選那一列的節點） |
