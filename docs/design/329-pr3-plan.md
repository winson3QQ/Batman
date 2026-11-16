# #329 PR 3 實作計畫 v8：新增節點、建立 / 加入 / 檢查網路（新畫面）

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

**版本紀錄**：v1–v7 共 14 位審查。v3 起每一輪的 MAJOR 都落在我在新頁面上**自己加的**建立條件、「重新建立」、結果推論與 Rust 新欄位，而這些在 join2 都已經有答案。v8 把它們全部拿掉，回到 join2 的行為。v1–v7 審查裡**關於新程式**（登入、交接、佔用、列檔、`openRawPage`、認領交接）的發現保留，見 §9。

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
| P8 | Rust 的結果標籤：建立成功 `[NET_MADE]`（只在 Applied）；加入成功 `[JOINED]`（只在 `E::Applied`，含國家未驗證）；檢查網路升級紀錄（`Confirm::Upgraded`）並以 `[NET_STATE]` 回句子 | owner.rs:447、:487-490、:513-517 |
| P9 | `Page.other` 不排讀取；`Page.home` 讀所有節點 | core.dart:169、:186-201 |
| P10 | Rust `list_kind` 濾掉 `.` 開頭的檔名、讀不到目錄回空清單 | owner.rs:41-47 |
| P11 | `UiState` 沒有設定暱稱的方法；`_save` 把寫入串成一列 | ui_state.dart:95-97、:131-138 |
| P12 | `keepScreenOn` 是現成的視窗旗標，軟體更新頁也用 | swupdate.dart:137；SwUpload.kt:77-81 |

## 2. 做法

### 2.1 `NodeLink.loginFor`（設計 §4.3.9；新程式）

- `loginFor(Lease lease, String id)`：`lease` 不是登記表目前的 session 佔用 → `NoLease`。
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
- 成功時不取消訂閱、不 dispose session，交出 `LoginHandoff`；交接後 `link.state` / 訂閱 `onError` 歸 `OwnerConsole`；`close()` 冪等：取消監聽 → 取消訂閱 → `await link.close()` → dispose session。

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
  - 加入：選目標網路（一筆就不問），和舊控制台的 `_pickNet` 一樣（只列打得開的）。
- 網路還沒確認建立完成（pending）時，照 join2 §3.2：主要是「檢查網路」；Rust 說「沒有套用，可以再建立一次」時，使用者可以照它的話按「建立網路」（舊控制台本來就這樣）。新頁面不加額外的條件。
- 按「開始」時在佔用下重新列一次檔：和 4.1 開頁時看到的不同（例如中間多了一筆 net）→ 不開始，請重開 4.1。這只是避免表單過期，不是新的規則。

### 2.5 多台迴圈（設計 §5.4）

- 4.1 勾節點（`node/` 紀錄）；4.1 開著時 `NodeLink` 用 `Page.home`（P9），剛認領的節點讀到後就能勾；離開 4.1 回到進來前的那一頁。建立者要是讀到、還沒加入網路的那台（`nodeState`，PR 2 首頁用的同一個值）。
- 按「開始」拿 session 佔用與一個 hold，到離開結果頁為止；等待中 `PopScope`、`keepScreenOn`。
- 每一台：上一台 `close()` 完成 → `loginFor` → 建立或加入。
  - 建立成功 = 重讀紀錄是已建立（P8）；不是 → 整個流程停，結果頁顯示 Rust 的句子與「檢查網路」。
  - 加入成功 = Rust 的回答是 `[JOINED]`（P8）→ 有 `pollLink` 時連線檢查（每 10 s、120 s）。
  - 其他（Rust 的拒絕或結果不明句子、登入失敗）→ 顯示 Rust 的句子，問「繼續下一台 / 先停在這裡」（返回鍵 = 停）。
  - 先看 `core.blocked` 或 `precondition`：藍牙、權限、金鑰 → 整個流程停、不問。`leaseLost` → 整個流程停。
- 結果頁：逐台列結果；進結果頁就 `close()`、關 `keepScreenOn`；「再試這一台」重用同一個佔用；離開時釋放。
- 頁面消失：做完當前請求、不開下一台、不彈對話框、收尾。

### 2.6 `NetIndex`（設計 §4.3.8）

- 由 `AppLink` 持有；啟動檢查通過與 `released` 之後各算一次；不在 `acquire` 的等待裡。
- 列檔（和 `list_kind` 同規則：濾 `.` 檔；`PathNotFoundException` = 空，在 `toList()` 接；其他錯誤 = 列不出來）決定「有沒有」；解密只取名稱、`applied`、成員；壞的一筆記一行（不含內容）。
- 只留代號最新的一次；計算中 → 第 6 列、3.5 / 3.6 用中性的「加入網路」（PR 2 的 D-m9 做法）。
- 待辦「節點加入網路沒有做完」：`joining` 的成員對到這支手機的節點（Rust `MemberView` 加 `deviceId`：`net_summary` 已有 `m.device_id`，一行 + 一個 Rust 測試）。

### 2.7 新增節點：`ClaimPage`（D1）

- 換 `build` 的樣式；`_claim` / `_find` / `_recover` 不動，`claim_*` 測試不改判定。開發用輸入只在 devTrust 顯示（設計 §5.3）。
- 新增 `openRawPageFor<T>`（舊的 `openRawPage` 不動，P6）；認領 / 恢復 / 覆寫成功時 `pop(ClaimDone(id))` → 3.2 暱稱（`UiState.setNick`：1–24 字、拒絕 Cc / Cf / Zl / Zp）→ 3.5 / 3.6。
- F41：不加 `PopScope`（設計 §4.4）；被 pop 後的結果句寫到 `AppLink.lastClaimNote`，首頁顯示一次。

## 3. 介面

### 3.1 擁有權（新的資源）

| 資源 | 唯一的寫入者 |
|---|---|
| session 佔用與 hold（新頁面） | 多台迴圈 / 檢查網路頁 |
| `loginFor` 的掃描與嘗試連線 | `NodeLink`（`_lf*`） |
| 交接後的連線、訂閱、`FrameInbox`、`OwnerSession` | `OwnerConsole` |
| net 紀錄（新頁面） | `OwnerConsole` 經 `RecordWriter`（舊控制台、`ClaimRecords` 照舊） |
| `NetIndex` | `NetIndex` |
| `keepScreenOn` | 多台迴圈（等待期間）；軟體更新頁（現況）。一次一個佔用，不重疊 |
| 暱稱 | `UiState.setNick` |
| `AppLink.lastClaimNote` | `ClaimPage` 寫、首頁讀後清 |

### 3.2 生命週期（新頁面）

| 情況 | 行為 | 測試 |
|---|---|---|
| 開始 | 4.1 不拿佔用；按開始才拿 | T-M1(a) |
| 正常結束 | 結果頁 `close` + 關 `keepScreenOn`；離開時釋放；`NetIndex` 重算 | T-M1(b) |
| 建立 / 加入中途 app 被殺 | 照 join2：紀錄停在 pending / joining → 首頁待辦與「檢查網路」 | T-M2 |
| 等待中切背景 / 關螢幕 | `keepScreenOn`；佔用中不自動讀 | T-M1(c)、R-7 |
| 藍牙 / 權限 / 金鑰 | 整個流程停 | T-M1(d) |
| 節點重開 / 斷線 | Rust 的結果不明句子 → 問繼續 | T-M1(e) |
| 佔用被收回 | 整個流程停 | T-M1(f) |
| 頁面消失 | 做完當前請求、收尾 | T-M1(g) |
| 升級 / 降級 | 紀錄格式不變（`MemberView.deviceId` 只是 Rust 回給 Dart 的顯示欄位） | — |

## 4. 和設計不同的地方

- **D1** 認領留在 `ClaimPage`（原始佔用）、只換樣式；不給步驟清單與經過時間；`ClaimPage` 改走 `BleGate` 進殘項（PR 6）。
- **D2** 舊控制台照舊、不經 `RecordWriter`（PR 6 刪）。
- **D3** 只有 mnet / mpend 的入口仍開舊控制台（PR 5 換）。
- **D4** 網路摘要表放在 `NetIndex`，不在 `NodeLink`（`NodeLink` 不碰 Keystore）。

## 5. 安全

- 新的輸入面只有網路名稱（Rust 檢查，同舊控制台）、暱稱（`setNick` 過濾）、勾選的節點（只能是 `node/` 紀錄）。沒有新的平台方法或匯出元件。
- 新頁面沒有佔用時，`BleGate` 與 `RecordWriter` 拒絕（fail-closed）；比舊控制台多一層檢查。
- 遠端 BLE / 惡意廣播：照 `core.LoginFor` 的 8 s msg2 預算與備忘；約 7 個不回應的位址能吃光 60 s（設計接受）。
- 被入侵的節點：照 join2 §6 的分析（只能換掉自己在 net 紀錄裡的成員項，join2flow.rs:345-365）；本 PR 不改。
- 秘密：`OwnerConsole` 不寫回答內容；位址經 `NodeLink.mask`。

## 6. 步驟（每一步跑全套、各自附改壞對照）

1. ✅ 舊控制台補測試（9b00ca6，改壞 5/5）。
2. `loginOutcome` 抽出 + `NodeLink.loginFor` + `HandoffProber` + `FrameInbox` + `acquire` 等 `released`。測試：T-L17（慢的 `readRecords`）、T-L18、T-S3、掃描叫醒 / 名額 / 重掃 / 60 s 收尾、失敗關連線、交接不丟訊框、訊框依序。改壞各一。
3. `OwnerConsole` + `RecordWriter` 寫入 + 原始碼鎖 + 表格驅動的四條路徑。測試：重送一次、unclear / notSent、逾時、國家問題不計時（推 400 s）、`ended`、`Refused` 且佔用有效 ≠ `leaseLost`、persist 時佔用收回 → `leaseLost` 且呼叫 `persistFailed`。改壞各一。
4. `NetIndex` + `MemberView.deviceId` + 首頁第 6 列 / 待辦改用它。測試：T-L19、T-N2、列檔規則、計算中。改壞各一。
5. 多台迴圈 + 4.1–4.5。測試：T-M1(a)–(g)、T-M2、`[JOINED]` / 已建立 判定（含國家未驗證的成功）、表單過期、4.1 用 `Page.home`（真的 `NodeLinkCore`）、T-C2 / T-C3。改壞各一。
6. `ClaimPage` 換樣式 + `openRawPageFor<T>` + `ClaimDone` + `setNick` + F41。`claim_*` 與 `openRawPage` 的測試不改判定；T-C3、T-V1、T-F41。改壞各一。
7. 首頁、節點頁、3.5 / 3.6 接線；兩位程式審查；真機。

## 7. 真機（要使用者同意；開始前另列副作用）

- 從零：`prov-bench-s0-254.sh unclaimed` 讓 02、04 回未認領（離開 N0；場次後留在 app 建的網路或 `restore` 回 N0，開始前擇一）；手機上移除兩筆節點紀錄。
- 情境：新增 04 → 建立 → 新增 02 → 加入；兩台一起勾；建立途中拔電 → 檢查網路。每條做設計 R-7 的三種中斷與 X13；記「正在連到節點…」的秒數。

## 8. PR 內文要寫明的限制

- 手機 Wi-Fi 在 PR 4；隊員路徑在舊控制台（PR 5）；field 版跑不起來（#255），「別人的手機」= dev 版；認領沒有步驟清單（D1）。

## 9. v1–v7 審查保留下來的（關於新程式的）

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
