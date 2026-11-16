# #329 PR 3 實作計畫 v11：新增節點、建立 / 加入 / 檢查網路（新畫面）

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

**版本紀錄**：v1–v7 共 14 位審查。 v8 的兩位審查（O、P）都是 APPROVE-WITH-CHANGES，MAJOR 都是我縮減時漏掉的舊行為或設計（檢查網路頁、送新密碼、`clearNotY`、pending 時的「建立網路」、和設計不同處沒列）；v9 照舊控制台與上層設計補回，不加新機制。v3 起每一輪的 MAJOR 都落在我在新頁面上**自己加的**建立條件、「重新建立」、結果推論與 Rust 新欄位，而這些在 join2 都已經有答案。v8 把它們全部拿掉，回到 join2 的行為。v1–v7 審查裡**關於新程式**（登入、交接、佔用、列檔、`openRawPage`、認領交接）的發現保留，見 §9。 v9 的兩位審查（Q、R）都是 APPROVE-WITH-CHANGES：節點頁的「建立網路」沒條件（Q-M1）、拔電後多筆 pending 與登入失敗也給建立（Q-M2）、佔用有兩個釋放者（R-M1）；v10 照設計 §5.1 / §5.5 與 join2 收斂，不加新機制，對應見 §9 末表。 v10 的兩位審查（S、T）都是 APPROVE-WITH-CHANGES：檢查網路頁「升級」「拿到回答」沒定義清楚（S-M1）、pending 建立者壞掉時新頁面沒有建立的出口（T-M1）；另外我在 v10 說「精確比對要新的 bridge 函式」是錯的，`nodeDacHash()` 早就有（owner.rs:991-994、lib/src/rust/api/owner.dart:107），v11 改用它。

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
- 複製：步驟迴圈、`ask`（逾時、unclear / notSent、重送一次、`ended`）、`makeNetwork`、`joinNetwork(rel)`、`confirmNetwork(rel)`、`linkCheck`、`sendUpdateFor(rel)`，與 join2 相關的國家 / 被移除過的問題（注入的對話框，計時規則同 nodes.dart:276-291）。**行為與句子和舊控制台相同。**
- 和舊控制台只差在接線：登入用 `loginFor`；寫入用 `RecordWriter.writeCas(lease, …)`（`NoLease` 時照樣呼叫 `persistFailed`）；`join` / `confirm` 吃 `rel`；回傳 Rust 的句子給頁面（不是 `_say`）；文字紀錄不寫回答內容。
- `leaseLost` 只看 `!lease.valid`（`Refused` 在佔用有效時 = 斷線，照 `ask` 的 unclear / notSent 處理）。
- 原始碼鎖：`lib/src/flows/`、`lib/ui/`（`ui_state.dart` 除外）不准直接呼叫 `storeWriteCas` / `storeWriteSealed` / `storeRemove` / `storeKeepCopy`。
- 防漂移：9b00ca6 的四條路徑測試改成表格驅動，同一組情境對 `OwnerConsole` 也跑。

### 2.4 新頁面怎麼決定建立 / 加入（照現有的規則，不新增）

- 首頁第 6 列與 3.5 / 3.6 照 PR 2 已審的分流（`joinChoice` + `NetRecords`，home_logic.dart:92-96）與設計 §5.1 / §5.3：沒有 net → 「建立網路」；有 net → 「加入網路」；只有 mnet / mpend → 舊控制台（PR 5 換）。
- 4.1：
  - 建立：網路名稱、頻道，和舊控制台的「建立網路」一樣。
  - 加入：選目標網路（一筆就不問），和舊控制台的 `_pickNet` 一樣（只列打得開的；標「已建立 / 建立中」，nodes.dart:617）。
  - 4.1 自己看到只有 mnet / mpend（例如從中性入口進來）→ 不給表單，給「到舊控制台」（dev；PR 5 換），field 只顯示句子；不顯示 nodes.dart:612-614 那句「舊節點要重燒」。
  - `NetIndex` 計算中 → 「正在讀取網路紀錄」，算完才給表單；列不出來 → 「讀不到手機裡的網路紀錄」+「再試一次」（重算 `NetIndex`），沒有表單（v9 Q m5、v10 S-m5）。
- **選到的那一筆網路還沒確認建立完成（pending）**時（看選到的那一筆），照 join2 §3.2：不送加入（Rust 會拒絕並叫人按「檢查網路」，owner.rs:506），改成顯示「這個網路還沒確認建立完成」+ 主要「檢查網路」（§2.8）。這句是新畫面的文字，不複製 Rust 的字串。
  - 手機**沒有任何已建立的 net**（全部 pending）時，再給次要「建立網路」（v10 T-M1）：這和第 6 列「沒有 net → 建立」是同一條規則（pending 的網路還不能加入），也是 pending 的建立者壞掉 / 移除時新頁面唯一的出口（舊控制台的這顆按鈕一直在，nodes.dart:1726-1731）。手機已經有已建立的 net 時不給（設計 §5.3 :726：有 net 時刻意不給建立，免得拆成兩個網路）。
- 節點頁的網路分組照設計 §5.5（:755）：這台 `node_state == 1` 而且手機有 net →「加入網路」（開 4.1 加入、預勾這一台）；手機有 pending 紀錄而這台可能是建立者 →「檢查網路」（§2.8，預選這一台）。節點頁**不放**「建立網路」；手機沒有 net 時建立的入口是首頁第 6 列與 3.5 / 3.6（v9 Q-M1、v10 S-m2）。
- 「節點加入網路沒有做完」的待辦（設計 §5.1）→ 4.1 加入表單，目標 = 那筆網路、那一台預設勾。同一頁的「放棄這次加入」= 舊控制台的「忘記加入中的節點」（`_forgetJoining`，join2 §3.4）：按下時**自己拿一個 session 佔用、寫完就放**（4.1 平時不拿佔用）。舊控制台 dev 版的「排除這台（換密碼）」分支（nodes.dart:1279-1283）不複製（D7）。設計 §5.1 :698 寫「同一頁」、:784 寫「開發者選項」，本計畫照 :698。
- 按「開始」時在佔用下重新列一次檔：和 4.1 開頁時看到的不同（例如中間多了一筆 net）→ 不開始，請重開 4.1。這只是避免表單過期，不是新的規則。

### 2.5 多台迴圈（設計 §5.4）

- 4.1 勾節點（`node/` 紀錄）；4.1 開著時 `NodeLink` 用 `Page.home`（P9），剛認領的節點讀到後就能勾；離開 4.1 回到進來前的那一頁（`Page.node` 連同節點一起還原，core.dart:186-201）。
- 建立模式：勾的第一台（使用者可以點選換）建立，其餘加入它建出來的網路；`rel` 取自那一台建立時 `PersistNet` 步驟的 `OwnerStep.rel`（owner.rs:428-430）。設計 §5.4 的表就是這樣，不另加條件。
- 加入模式：其餘每台加入 4.1 選的那一筆。
- **佔用（照 lease.dart:60-90 的用法，v10 T-m1）**：
  - 按「開始」：迴圈 `acquire` session 佔用；`acquire` 回來時頁面已不在 → 立刻 `release()`（照 raw_use.dart:75-78，不照 node_page.dart:62-64，v10 T-m4）。
  - 工作期間迴圈拿一個 `hold()`；`PopScope`、`keepScreenOn`。
  - 進結果頁 = 工作做完：`close()`、關 `keepScreenOn`、放掉 `hold`（`_busy` 歸 0，佔用仍在、頁面仍在）。
  - 離開結果頁（dispose）→ `pageGone()`，這時沒有 hold → 立刻釋放。迴圈 / 結果頁是這個佔用唯一的 `pageGone` / `release` 呼叫者。
  - 工作途中頁面消失（app 被系統關頁）：先 `pageGone()`（有 hold，`_busy > 0`，開始 420 s 期限），等當前請求（含它的 `lease.run` 寫入）做完，不做之後的送新密碼與連線檢查，不開下一台、不彈對話框，`close()`、關 `keepScreenOn`，**然後**放 `hold` → 佔用立刻釋放（v9 R m6）。
- 每一台：上一台 `close()` 完成 → `loginFor` → 建立或加入。
  - 建立：`makeNetwork`。
    - 沒有 `PersistNet`（拿不到 `rel`）→ 整個流程停，顯示 Rust 的句子；不自動檢查（反向測試）。
    - 有 `rel` → 在佔用下重讀**那一筆**紀錄。已建立 → 繼續。不是 → 照設計 §5.4 自動「檢查網路」一次：session 還在就直接 `confirmNetwork(rel)`；回 `NOT_LOGGED_IN` 或連線已斷（例如拔電，owner.rs:1173-1175）→ 再 `loginFor` 一次（60 s）後 `confirmNetwork`（確認回答 60 s）。之後重讀那一筆；仍不是 → 整個流程停，結果頁那一列給「檢查網路」（§2.8，借用同一個佔用）。A18 在真機確認。
  - 加入：`joinNetwork(rel)` → 看**加入請求本身**的回答（P8）：`[JOINED]` = 成功。
    - 有 `send_update` → 接著 `sendUpdateFor(rel, member: false, confirm: false)`（照舊控制台 nodes.dart:668，不彈確認框）。送新密碼失敗 → 那一台記「已加入，新密碼沒有送出」+ Rust 的句子，算失敗、問繼續 / 停。
    - 有 `poll_link` → 連線檢查（每 10 s、120 s）。
  - 其他（Rust 的拒絕或結果不明句子、登入失敗）→ 顯示 Rust 的句子，問「繼續下一台 / 先停在這裡」（返回鍵 = 停）。
  - 先看 `core.blocked` 或 `precondition`：藍牙、權限、金鑰 → 整個流程停、不問。`leaseLost` → 整個流程停。
- 結果頁：逐台列結果；「再試這一台」「檢查網路」**借用**同一個佔用（各自在工作時拿 `hold`、做完放，不呼叫 `pageGone` / `release`）。結果頁本身沒有「建立網路」；建立網路的入口在檢查網路頁（§2.8）。
- `close()`（§2.2）先等進行中的步驟（seal / CAS）做完，再 dispose session。

### 2.6 `NetIndex`（設計 §4.3.8）

- 由 `AppLink` 持有；啟動檢查通過與 `released` 之後各算一次；不在 `acquire` 的等待裡。佔用期間不重算；新頁面在佔用中要判斷某一筆有沒有建立完成時，直接重讀那一筆紀錄（`readRecords` 的那一筆 + 解密取 `applied`），不看 `NetIndex`。
- 列檔（和 `list_kind` 同規則：濾 `.` 檔；`PathNotFoundException` = 空，在 `toList()` 接；其他錯誤 = 列不出來）決定「有沒有」；解密只取名稱、`applied`、成員；壞的一筆記一行（只寫 net id 前 8 碼，不含內容；§6 有測試）。
- 只留代號最新的一次；計算中 → 第 6 列、3.5 / 3.6 用中性的「加入網路」（PR 2 的 D-m9 做法）。
- 待辦「節點加入網路沒有做完」：`joining` 的成員對到這支手機的節點（Rust `MemberView` 加 `deviceId`：`net_summary` 已有 `m.device_id`，一行 + 一個 Rust 測試）。

### 2.7 新增節點：`ClaimPage`（D1）

- 換 `build` 的樣式；`_claim` / `_find` / `_recover` 不動，`claim_*` 測試不改判定。開發用輸入只在 devTrust 顯示（設計 §5.3）。
- 新增 `openRawPageFor<T>`（舊的 `openRawPage` 不動，P6）；認領 / 恢復 / 覆寫成功時 `pop(ClaimDone(id))` → 3.2 暱稱（`UiState.setNick`：1–24 字、拒絕 Cc / Cf / Zl / Zp）→ 3.5 / 3.6。
- F41：不加 `PopScope`（設計 §4.4）；被 pop 後的結果句寫到 `AppLink.lastClaimNote`，首頁顯示一次。

### 2.8 檢查網路頁（設計 §5.4 的「檢查網路」）

- **先選對象、再拿佔用**：預選 = pending 紀錄裡建立者 `name`（`node-<last4>`）對到手機唯一一筆 `node/` 的那台（只是預選與顯示）；對不上或多筆 → 讓使用者選。頁面寫明「檢查的是節點 XXXX」。從節點頁進來時預選那一台。
- 佔用：
  - 從 4.1 或節點頁進來：本頁 `acquire`（回來時頁面已不在 → 立刻 `release()`）；工作時 `hold`；離開時 `pageGone()`。
  - 從結果頁進來：**借用**結果頁的佔用，工作時 `hold`、做完放，不呼叫 `pageGone` / `release`。
  - 返回鍵：登入或確認進行中時 `PopScope` 擋住並顯示「正在檢查」；不開 `keepScreenOn`（登入 ≤ 60 s + 每筆確認 ≤ 60 s；切背景時照現況，Rust 回答不明 → 顯示句子）。
- 登入對象 → 用**現有的**值判斷這台是哪幾筆的建立者：`MemberView.creator && dacHash == session.nodeDacHash()`（owner.rs:84-87、:114-119、:991-994；v10 S-m1、T-m3，不加 bridge 函式）。
  - 一筆都不是 → 「這台不是這些網路的建立者」+「換一台檢查」；不送確認、不給「建立網路」（手選錯台時不會出現 Rust 的「可以再建立一次」，owner.rs:478）。
  - 是 → 在**同一次登入**裡依序 `confirmNetwork` 這幾筆（從結果頁進來時先檢查剛建立的那一筆），每筆顯示 Rust 的句子（`confirm` 對錯的紀錄只會 `NoChange` / `OtherVersion`，netrec.rs:509-537；同一次登入連續確認可行，owner.rs:879-893、:1107-1114；節點唯讀動詞每條連線 burst 20）。
  - 每筆的判斷（v10 S-M1、T-m6）：
    - **拿到回答** = 那一筆的步驟以 `[NET_STATE]` 標籤結束（owner.rs:487-490；做法同 P8 看 `[JOINED]`）。`[REQ_FAIL]`、寫入失敗（`persistFailed`）、結果不明、連線斷 → 沒拿到回答，**整頁停**。
    - **升級** = 拿到回答後在佔用下重讀那一筆、`applied` 為真（§2.6，不看 `NetIndex`、不看句子）→ 停。
- 結果：
  - 有一筆升級 → 顯示 Rust 的句子，「完成」。
  - 每一筆都拿到回答、都沒升級，而且手機沒有任何已建立的 net → 「再檢查一次」+ 次要「建立網路」（舊控制台一直有，nodes.dart:1730；和 §2.4 同一條「沒有已建立的 net 才建立」）。
  - 其他（登入失敗、沒拿到回答、不是建立者）→ 只有「再檢查一次」/「換一台檢查」。
- 按「建立網路」：
  - 自己拿佔用的：`close()` → pop（`pageGone()` 立刻釋放）→ 開 4.1 建立表單。
  - 借用的：`close()` → pop 一個「去建立」的值給結果頁 → 結果頁 pop 自己（`pageGone()` 釋放）→ 開 4.1 建立表單（不在結果頁上面 push，否則 4.1 拿不到佔用；v10 T-m1）。

## 3. 介面

### 3.1 擁有權（新的資源）

| 資源 | 唯一的寫入者 |
|---|---|
| session 佔用的 `pageGone` / `release` | **acquire 的那一方**：多台迴圈 + 它的結果頁、從 4.1 / 節點頁進來的檢查網路頁、「放棄這次加入」。借用的頁面只拿 / 放自己的 `hold` |
| `loginFor` 的掃描與嘗試連線 | `NodeLink`（`_lf*`） |
| 交接後的連線、訂閱、`FrameInbox`、`OwnerSession` | `OwnerConsole` |
| net 紀錄（新頁面） | `OwnerConsole` 經 `RecordWriter`（舊控制台、`ClaimRecords` 照舊） |
| `NetIndex` | `NetIndex` |
| `keepScreenOn` | 多台迴圈（等待期間）；軟體更新頁（現況）。一次一個佔用，不重疊。檢查網路頁不用 |
| 暱稱 | `UiState.setNick` |
| `AppLink.lastClaimNote` | `ClaimPage` 寫、首頁讀後清 |

### 3.2 生命週期（新頁面）

| 情況 | 行為 | 測試 |
|---|---|---|
| 開始 | 4.1 不拿佔用；按開始才拿；`acquire` 回來時頁面已不在 → 立刻釋放 | T-M1(a) |
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

## 5. 安全

- 新的輸入面只有網路名稱（Rust 檢查，同舊控制台）、暱稱（`setNick` 過濾）、勾選的節點（只能是 `node/` 紀錄）。沒有新的平台方法或匯出元件。
- 新頁面沒有佔用時，`BleGate` 與 `RecordWriter` 拒絕（fail-closed）；比舊控制台多一層檢查。
- 遠端 BLE / 惡意廣播：照 `core.LoginFor` 的 8 s msg2 預算與備忘；約 7 個不回應的位址能吃光 60 s（設計接受）。
- 被入侵的節點：照 join2 §6 的分析（只能換掉自己在 net 紀錄裡的成員項，join2flow.rs:345-365）；本 PR 不改。
- 秘密：`OwnerConsole` 不寫回答內容；位址經 `NodeLink.mask`。

## 6. 步驟（每一步跑全套、各自附改壞對照）

1. ✅ 舊控制台補測試（9b00ca6，改壞 5/5）。
2. `loginOutcome` 抽出 + `NodeLink.loginFor` + `HandoffProber` + `FrameInbox` + `acquire` 等 `released`。測試：T-L17（慢的 `readRecords`）、T-L18（`clearNotY`）、T-S3、掃描叫醒 / 名額 / 重掃 / 60 s 收尾、失敗關連線、交接不丟訊框、訊框依序。改壞各一。
3. `OwnerConsole`（含 `_forgetJoining` 的複製）+ `RecordWriter` 寫入 + 原始碼鎖 + 表格驅動的四條路徑。測試：重送一次、unclear / notSent、逾時、國家問題不計時（推 400 s）、`ended`、`Refused` 且佔用有效 ≠ `leaseLost`、persist 時佔用收回 → `leaseLost` 且呼叫 `persistFailed`。改壞各一。
4. `NetIndex` + `MemberView.deviceId` + 首頁第 6 列 / 待辦改用它。測試：T-L19、T-N2、列檔規則、計算中、壞的一筆的記錄行只有 net id 前 8 碼（斷言整行不含其他內容）。改壞各一。
5. 多台迴圈 + 4.1–4.5 + 檢查網路頁。測試：T-M1(a)–(g)、T-M2、`[JOINED]` 只看加入請求的回答（連線檢查的 `[JOINED]` 不算）/ 已建立 判定（含國家未驗證的成功）、`send_update` → 送新密碼、建立後沒套用 → 自動檢查一次、沒有 `PersistNet` → 不自動檢查、自動檢查遇到 `NOT_LOGGED_IN` → 重新 `loginFor` 一次、pending（選到的那一筆）時 4.1 給「檢查網路」、全部 pending → 另有「建立網路」、有已建立的 net → 沒有、節點頁：從不給「建立網路」、節點已在網路但紀錄 pending → 有「檢查網路」、檢查網路頁：登入的不是建立者（`nodeDacHash` 對不上）→ 不送確認、沒有「建立網路」、兩筆 pending 且節點在第一筆 → 第一筆升級（重讀那一筆，不看 `NetIndex`；借用佔用時也一樣）、升級後寫入失敗 → 停、沒有「建立網路」、登入失敗 → 沒有「建立網路」、有已建立的 net → 沒有「建立網路」、`acquire` 回來時頁面已不在 → 立刻釋放、借用時不呼叫 `pageGone` / `release`、`close()` 等處理者（慢的 `writeCas` + 逾時 → 不會在 dispose 後呼叫 `netPersisted`）、`sendUpdateFor` 失敗 → 那一台算失敗、「放棄這次加入」自己拿放佔用、頁面消失時等寫入完成才放 hold、`close()` 等進行中的步驟、借用的佔用不被釋放（T-M1(h)）、從結果頁建立 → 4.1 開始拿得到佔用（T-M1(i)）、T-R1、`NetIndex` 列不出來 → 4.1「讀不到」、表單過期、4.1 用 `Page.home`（真的 `NodeLinkCore`）、T-C2 / T-C3。改壞各一。
6. `ClaimPage` 換樣式 + `openRawPageFor<T>` + `ClaimDone` + `setNick` + F41。`claim_*` 與 `openRawPage` 的測試不改判定；T-C3、T-V1、T-F41。改壞各一。
7. 首頁、節點頁、3.5 / 3.6 接線；兩位程式審查；真機。

## 7. 真機（要使用者同意；開始前另列副作用）

- 從零：`prov-bench-s0-254.sh unclaimed` 讓 02、04 回未認領（離開 N0；場次後留在 app 建的網路或 `restore` 回 N0，開始前擇一）；手機上移除兩筆節點紀錄。
- 情境：新增 04 → 建立 → 新增 02 → 加入；兩台一起勾；建立途中拔電 → 檢查網路 →（Rust 說沒套用時）建立網路；拔電時 04 已套用與沒套用兩種都做、都記（v9 Q-M2、v10 T）；只有 pending、04 不開機 → 4.1 的次要「建立網路」。A18：建立回來是否已套用。每條做設計 R-7 的三種中斷與 X13；記「正在連到節點…」的秒數。

## 8. PR 內文要寫明的限制

- 手機 Wi-Fi 在 PR 4；隊員路徑在舊控制台（PR 5）；field 版跑不起來（#255），「別人的手機」= dev 版；認領沒有步驟清單（D1）。
- 手機已有已建立的網路、又要另建一個網路（拆隊）：新頁面不給，dev 用舊控制台；field 版這一版沒有入口（D6）。pending 紀錄在新頁面不能刪（照舊控制台）。兩項都寫進 #329 checklist。

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
| R m3 對象比對、多筆 pending | 名稱比對保留（精確的 dac hash 比對要新的 bridge 函式，屬新機制）；對不上 → 手選且不給「建立網路」；多筆 pending 由 Q-M2 的逐筆檢查處理 |
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
