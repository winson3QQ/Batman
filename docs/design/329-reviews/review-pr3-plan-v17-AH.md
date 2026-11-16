# #329 PR 3 計畫 v17 審查 — AH（明天要開工第 2–7 步的實作者角度）

- 審查對象：`docs/design/329-pr3-plan.md` v17 @ 13d4053（§0–§9 整份讀過一次）
- 基準（不重審）：`254-app-join2.md`、舊控制台（nodes.dart、member_ui.dart、owner.rs、rekey.rs、netrec.rs、flow.rs、join2flow.rs）
- 方法：用 11 個現場情境逐一走過新頁面，看文字能不能決定每個畫面、按鈕、navigator 呼叫、佔用呼叫、`OwnerConsole` 呼叫、`ConsoleReply` 的處理和紀錄寫入。計畫引用的原始碼逐條對過。全程只讀，除了本報告沒有改任何檔案，也沒有執行任何測試。

**結論：APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 9 MINOR**

9 個 MINOR 都只要補文字，不加機制。實作時順手補進計畫就好，不需要再審一輪。

---

## 1. 原始碼事實核對

| 計畫的說法 | 結果 | 證據 |
|---|---|---|
| `[NET_MADE]`、`confirm_text` 的 `[NET_STATE] `、`[JOINED] ` 只在 `E::Applied` | ✅ | owner.rs:446-448、:484-491、:513-517 |
| 連線檢查的句子也用 `[JOINED]`；連上是 `[CONNECTED]` | ✅ | owner.rs:586-590 |
| `send_update = applied && behind`；`poll_link` 要求 `!behind` 而且國家已驗證 → 兩者互斥 | ✅ | owner.rs:1435-1439 |
| 選到 pending 時 Rust 拒絕加入（NotApplied）；國家「不要」回 `[COUNTRY] 已取消`；`LATER` 是「稍後在這台按『加入網路』」 | ✅ | owner.rs:507、:518、:497/:529-533 |
| `persist_failed`：applied 之後寫入失敗 → `[REQ_FAIL] 節點已套用，手機紀錄沒存好…`，並回到 Conn（session 還在） | ✅ | owner.rs:1131-1155 |
| 確認的 Upgraded 會再發一個 PersistNet（`persist_then`） | ✅ | owner.rs:878-893、:1107-1114 |
| Rust 自己在 ReadInfo 時做一次 `check_network` | ✅ | owner.rs:1503-1510 |
| `node_dac_hash()`、`MemberView.dac_hash` / `creator`（只在 pending 時才有） | ✅ | owner.rs:990-994、:84-119 |
| `net_forget_joining` 是獨立函式，拒絕忘記建立者 | ✅ | owner.rs:128-140 |
| 送新密碼（非隊員）沒有 PersistNet；成功是 `[UPDATED] `，失敗是 `[REQ_FAIL] ` | ✅ | rekey.rs:432-456（只有 :420 的 PersistMnet，屬於隊員路徑） |
| 舊的 `_join`：`go` →（`_removedQ`）再 `go` → `_sendAfter` → `_sendUpdateFor(rel, member:false, confirm:false)` → `_watchLink` | ✅ | nodes.dart:651-670 |
| `_watchLink` 每 10 s 一次，非回答就停，`[CONNECTED]` 就停 | ✅ | nodes.dart:687-716 |
| `_ask` 的重送分支、`unclear` 時 drop、`_waitLine`、`操作沒有成功` | ✅ | nodes.dart:511-588 |
| `_makeUnclear` 本身就以 `[NET_STATE] ` 開頭（所以「拿到回答」一定要同時看 `kind == answer`，計畫有寫） | ✅ | nodes.dart:50；計畫 §2.3:77、§2.8:170 |
| `_sendUnclear`；送新密碼等 `_joinWait`（360 s） | ✅ | nodes.dart:55、:1581 |
| `SendTrack.persisted()` 在 PersistNet **寫入之前**就標成 wrote | ✅ | nodes.dart:258（`_track.persisted()` 在 `_underLease` 之前）；member_ui.dart:294-310 |
| `forgettable = joining && !creator` | ✅ | member_ui.dart:172 |
| `keyErrorToRadio` 只在 `refusedBy != null` 時才動 | ✅ | app_link.dart:142-144 |
| `Lease.hold()` 在佔用無效時丟例外；唯一的收回路徑是 `pageGone` 之後 420 s / 900 s 到期 | ✅ | lease.dart:57-90、:140-150（`_revoke` 只有 lease.dart:81 一個呼叫者） |
| `NodeLink.acquire` 是 async：先看 `reg.current`，等 `_dropAll` 之後才 `reg.acquire` | ✅ | node_link.dart:150-163 |
| `core.loginFor(clearNotY)`；`setRadio` 讓進行中的 `LoginFor` 結束成 `precondition` | ✅ | core.dart:628-640、:274-289 |
| 上層設計 :547：流程頁的「再試一次」用 `loginFor(…, 先清「不是 Y」)` | ✅ | 329-app-uiux.md:547 |
| 舊 `_pickNet` 沒有可用的 net 時，不分原因一律顯示 T8 那句 | ✅ | nodes.dart:603-612 |
| 本 PR 沒有新的平台方法或匯出元件 | ❌ 沒查 | 程式還沒寫 |

---

## 2. 情境走查

| 情境 | 文字能不能完全決定？ | 走查 |
|---|---|---|
| (a) 從零開始，先建 04 再加 02 | ✅ | 認領 → 3.2 → 3.5（沒有 net）→ 4.1 建立模式、預勾 04 → 4.1 `acquire` + 比對快照（`_pending`）→ `push(NetRunPage)` → `loginFor` → `makeNetwork` → 有 `persistedRel` → 重讀 → 已建立 → 結果階段（`close` → 關 `keepScreenOn` → 放 `hold`）→ 離開 → `pageGone` 釋放 → `NetIndex` 重算 → 通知。02：3.6（有 net）→ 4.1 加入模式（只有一筆，不問）、預勾 02 → `joinNetwork` → `[JOINED] ` + `pollLink` → `linkCheck`。全部有寫。順序問題見 m8。 |
| (b) 兩台一起勾 | ✅ | 照清單順序（暱稱排序）第一台建立（§2.9），重讀已建立後，第二台加入 `persistedRel`。每一台之間先 `close()`。 |
| (c) 建立途中拔 04 的電 | ⚠️ | 通常的時機（等 360 s 的時候拔）：`unclear` + `persistedRel` → 重讀是 pending → 自動檢查：`sessionAlive == false` → `close` → `loginFor`（60 s，`notFound`）→ 停（D12），那一列寫「沒有連到節點，無法檢查」+ `Why`，按鈕是「檢查網路」→ 借用佔用的檢查網路頁。已套用 → 升級 → 「完成」→ 結果頁自己重讀那一列。沒套用 → `[NET_STATE] …沒有套用` → 「再檢查一次」+「建立網路」→ pop「去建立」→ `NetRunPage` pop「去建立」→ 4.1 建立模式。都決定得了。沒決定的有兩處：PersistNet 正在寫的那一瞬間斷線（m1），以及回到 4.1 之後的模式 / 快照（m4）。 |
| (d) 建立者壞了，只剩 pending | ✅ | 第 6 列「加入網路」→ 4.1 選到 pending →「檢查網路」+ 次要「建立網路」（全部 pending）→ 切到建立模式。從節點頁進來也一樣。預選有多筆時見 m6。 |
| (e) 加入途中 app 被殺 | ✅ | 成員停在 joining → 待辦（`forgettable` + `deviceId`）→ 4.1 加入、目標那一筆、預勾那一台；「放棄這次加入」自己拿佔用、經 `RecordWriter` 寫完就放。建立途中被殺 → 沒有待辦 → 第 6 列或節點頁的「檢查網路」。 |
| (f) 迴圈途中關藍牙 | ✅ | GATT 先斷 → `unclear` → 問之前看 `core.blocked`；狀態事件比較晚到 → 對話框收起、當成停。下一台的 `loginFor` → `precondition` → 停。文字裡有一處矛盾（m3）。 |
| (g) 請求進行中頁面關掉 | ✅ | `pageGone`（有 hold，420 s）→ 等當前的請求 → 不送新密碼、不做連線檢查、不開下一台（進行中的 `linkCheck` 被 `close()` 中止，§2.9）→ `close` → 關 `keepScreenOn` → 放 hold → 釋放。4.1 的 `_pending`、借用頁只放 hold，都有寫。 |
| (h) 檢查網路頁選錯台 | ⚠️ | 登入後比 `nodeDacHash` 對不上 → 「這台不是…」+「換一台檢查」，不送確認、也不給建立。「再檢查一次」/「換一台檢查」要不要清「不是 Y」沒寫（m5）。 |
| (i) 被入侵的節點回假的答案 | ✅ | 判斷都看 `kind == answer` 加上 Rust 自己寫的開頭標籤。節點的字串只會出現在句子中間（owner.rs:484-533、:586-590；rekey.rs:432-456）。`_makeUnclear` 的 `[NET_STATE] ` 開頭因為 `kind` 是 `unclear` 而被排除。節點能謊稱「已套用」屬於基準（join2 §6）。 |
| (j) 加入成功後送新密碼失敗，再試這一台 | ✅ | v17 改成照迴圈的加入規則整段再跑（`joinNetwork` → `sendUpdateFor` → `linkCheck`）。Rust 會再回帶 `sendUpdate` 的 `[JOINED] `（owner.rs:1435-1439）。再試時遇到失敗、金鑰錯誤的處理沒寫清楚（m7）。 |
| (k) 迴圈途中管理者金鑰失效 | ⚠️ | `signAdmin` → `_keyFail` → `keyErrorToRadio` + `keyError` → 整個停、不問，有寫。登入時的擁有者金鑰例外沒有管道告訴頁面（m2）；4.1 / `NetIndex` 的兩條金鑰規則互相衝突（m2）。 |

---

## 3. 發現

沒有 BLOCKER，也沒有 MAJOR。

### MINOR

**m1 `ConsoleReply` 可能在 PersistNet 還在寫的時候就回傳。這時建立那一列的文字和按鈕互相矛盾。**
- **情境**：建立時，就在 seal / `writeCas` 進行的那一瞬間斷線。
  - `link.state` 的監聽會立刻用 `_unclearNow()` 結束這次請求（舊碼是 nodes.dart:440-444 的 `_lost` → `_endUnclear`）。
  - 但 `_track.persisted()` 在寫入**之前**就被呼叫了（nodes.dart:258），所以句子是 `_makeUnclear`：「結果不明，稍後在這台按『檢查網路』」（nodes.dart:50）。
  - 同一時間，`persistedRel` 還是 null，因為寫入還沒完成（§2.3:70）。`close()` 會等這次寫入（§2.2），寫入通常會成功。
- **結果**：那一列顯示「去按檢查網路」，按鈕卻只有「再試這一台」，也就是再 `makeNetwork` 一次（§2.5:138）。
  - 新建出來的是第二個 net。第一筆 pending 成為孤兒：新頁面刪不掉；04 節點頁的「檢查網路」會永遠留著（§8 已接受這一類，但這裡的觸發是新的）；4.1 會多一筆「建立中」。
  - 節點那時候還沒收到任何網路資料（PersistNet 在送出之前，nodes.dart:254-256），所以不會拆隊。只是留下垃圾紀錄，加上畫面自相矛盾。
  - 反過來也有同樣的問題：寫入失敗時句子一樣是 `_makeUnclear`，但沒有 `persistedRel`。
- **修法**（寫一句，不加機制）：`OwnerConsole` 等 `FrameInbox` 正在跑的處理者做完（同 §2.2 的 10 s 上限）才組 `ConsoleReply`。另外，建立列的文字照 `persistedRel` 有沒有來寫：有 → 結果不明 / 檢查網路；沒有 → 沒有建立。
- **改壞對照**：慢的 `writeCas`（成功）加上在寫入中途斷線 → 那一列有「檢查網路」、沒有「再試這一台」。拿掉「等處理者」之後，這個測試要 FAIL。

**m2 金鑰例外有三處接不起來。**
- **4.1 / `NetIndex`**：
  - §2.9 第一句要求「任何地方遇到 Keystore 例外 → 停，顯示 `core` 的金鑰句子，**優先於**打不開就跳過」。但列舉的地方沒有 `NetIndex`，而 §2.6 寫的是「壞的一筆記一行」（跳過）。
  - 同一段又寫「全部因金鑰打不開 → 4.1 顯示 T8 的提示句」。全部都是金鑰例外的時候，到底顯示金鑰句子還是 T8 句子，兩句互相衝突。
  - `NetIndex` 的輸出也沒有欄位分辨「因金鑰打不開」和「損壞」，所以 4.1 無從判斷。
  - 另外，「全部打不開、但原因不是金鑰」時 4.1 顯示什麼沒寫。舊控制台不分原因，一律顯示 T8 那句（nodes.dart:607-612）。
  - 修法：`NetIndex` 算出 `keyRefused`（任一筆的 `refusedBy != null` → 呼叫 `keyErrorToRadio`）；4.1 照「金鑰句子優先，否則沒有可用的 net 時顯示 T8 句」，並且不給表單。
- **`loginFor`**：§2.1 寫了 `keyError → keyErrorToRadio`，但 `LoginEnd` 沒有管道告訴頁面。`refusedBy == null` 的金鑰例外不會讓 `core.blocked` 變成擋住，迴圈因此會照「登入失敗」去問繼續 / 停，和 §2.9「任何地方 → 整個停」不符。
  - 修法：二選一，並寫明是哪一個。
    - 讓 `loginFor` 回傳的結果帶上 `keyError`；或
    - 明說「登入時的金鑰例外，只在 `refusedBy != null` 時停」。

**m3 「擋住」的定義前後不一。** §2.5:134 寫「`core.blocked` **或 `precondition`** 變成擋住 → 對話框收起」，§2.9 寫「擋住 = `core.blocked` 非 null 或 `!lease.valid`，**不是** `precondition`」。修法：把 §2.5:134 改成和 §2.9 一樣。

**m4 從檢查網路頁按「建立網路」回到 4.1 之後，模式和快照怎麼處理沒寫。**
- 這時迴圈剛寫下一筆 pending，4.1 手上的快照是舊的。
- §2.8:180 只寫了「不是去建立時，等 `NetIndex` 通知再更新快照」。
- 4.1 收到通知、更新快照之後，快照裡多了一筆 pending。這時 4.1 是要照 `joinChoice` 改回加入模式（選到 pending → 又出現「檢查網路」+「建立網路」），還是留在建立模式，沒寫。
- 如果在通知之前就按「開始」，快照比對一定不同，會被彈回去再確認一次。
- 修法：寫明「回『去建立』之後，4.1 留在建立模式，同樣等 `NetIndex` 通知再更新快照；更新後只要手機仍然沒有已建立的 net，就保持建立模式」。

**m5 檢查網路頁的重試沒寫要不要清「不是 Y」。** 上層設計 :547 寫「流程頁的『再試一次』用 `loginFor(…, 先清『不是 Y』)`」。計畫只在結果頁的「再試這一台」傳 `clearNotY: true`（§2.1:44）；檢查網路頁的「再檢查一次」/「換一台檢查」沒寫。
- 情境 (c)：04 斷電重開時，如果它的位址被記成「不是 04」，之後在檢查網路頁重試會一直 `notFound`，要等到位址輪換或使用者按重新整理（core.dart:670-686、設計 :528）。
- 修法：檢查網路頁由使用者觸發的重試也傳 `clearNotY: true`，自動檢查不傳。

**m6 從 4.1 進檢查網路頁時，預選的對象沒寫清楚。** §2.8:160 寫「預選 = pending 紀錄裡建立者的名稱，對到手機唯一一筆 `node/`；對不上或多筆 → 讓使用者選」。從 4.1 進來時，4.1 已經選了某一筆 pending：是預選那一筆的建立者，還是看全部的 pending？「多筆」指的是多筆 pending，還是多台節點對得上？修法：從 4.1 進來時，用 4.1 選到的那一筆 pending 的建立者來預選。

**m7 結果頁再試加入時，遇到失敗或金鑰錯誤怎麼辦沒寫。**
- §2.5:139 說「照迴圈的**加入規則**整段再跑」。但迴圈的規則裡有「失敗 → 問繼續 / 停」和「`keyError` → 整個流程停」，在結果頁單一列的再試裡，這兩句是什麼意思沒寫。
- 修法：寫明「再試失敗 → 那一列換成新的原因，不問；`keyError`、擋住、佔用無效 → 那一列寫原因，其他列的按鈕維持停用到擋住解除」（或者「照樣可按、按了由 `loginFor` 回 `precondition`」，擇一）。

**m8 §6 的步驟順序和測試清單有殘字。**
- §2.9 說 AD-M1 的改壞對照（「首頁待辦不列 pending 的建立者」）移到第 4 步。但第 4 步的清單裡沒有它，第 5 步仍然列著。
- 第 5 步還留著舊的「加入列再試 = `joinNetwork`」，和 v17 §2.5:139 不一致；新的 AF-M1 測試倒是已經列了。
- 第 5 步的「3.5 / 3.6 進 4.1，剛認領的那台預勾」用到的 3.5 / 3.6 頁，要到第 6 / 7 步才做。
- 修法：把 forgettable 的測試搬到第 4 步；刪掉舊的那一句；3.5 / 3.6 預勾的測試移到第 7 步，或在第 5 步用假的入口參數測。

**m9 小地方。**
- §2.1:44 的 `NoLease` 不在結果列舉（`ok` / `identity` / `refused` / `notFound` / `precondition`）裡。是丟例外還是回傳值，要寫明。依目前 lease.dart 的實作，只有 `pageGone` 之後才會發生。
- 4.1 一台都沒勾時，「開始」要停用（設計 §5.4 :734 寫「至少一台」）。計畫沒寫。
- 「手機沒有任何已建立的 net」只看打得開的紀錄。如果有一筆打不開，而它正是已建立的那一筆，4.1 仍然會給次要「建立網路」，和 join2 T8「新建會拆隊」的意思相反。把 m2 的 `keyRefused` / 打不開數量算進條件即可。

---

## 4. 基準備註（不是發現）

- 確定失敗的建立（例如 `[REQ_FAIL] 建立網路沒有成功：節點連續兩次拒絕`）已經寫過 pending 紀錄，所以會有 `persistedRel`。新頁面會走「自動檢查 → 停 → 檢查網路頁 → 建立網路」，比舊控制台直接再按「建立網路」多兩步。不過兩邊最後都會再建立一個 net、留下一筆孤兒 pending，結果相同（owner.rs:1495-1500；joinflow 每次建立都重抽 `net_id`，batman-proto/src/joinflow.rs:147-160）。
- Rust 的 NotApplied 句子是「可以再建立一次**同一個**網路」（owner.rs:477），但 `request_make_network` 每次都抽新的 `net_id`。這句話和行為之間的落差屬於基準。
- 舊的 PersistNet 路徑在 seal 遇到 `PlatformException` 時，不呼叫 `_keyFail`（nodes.dart:266-270）。新頁面在這裡設 `keyError`，比舊碼嚴格，D11 已涵蓋。

## 5. 驗證分組

- ✅ 已驗證：§1 表裡標 ✅ 的各列（原始碼 file:line，都在 13d4053 讀過）。
- ⚠️ 推論：m1 的時間差（只讀原始碼的順序，沒有跑過測試）；m5 的「04 重開時位址被記成『不是 04』」需要節點在開機途中回「解不開」，實際機率未知。
- ❌ 沒做：沒有執行任何測試或程式；manifest 有沒有新的匯出元件，要等程式寫出來才能查。
