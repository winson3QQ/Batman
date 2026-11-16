# #329 PR 3 實作計畫 v10 審查（審查者 S，獨立）

對象：`docs/design/329-pr3-plan.md` @ 78a5177。範圍照指示：(1) v9 審查 Q、R 的每一項在 v10 是否修好；(2) v10 本身的改動（§2.4 節點頁、§2.5 迴圈 / 佔用 / `close` / `send_update`、§2.8 檢查網路頁、§3.1 / §3.2、D6 / D7、§6、§9 v9 表）有沒有新的洞。join2 與舊控制台的行為是基準，疑問放「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 1 MAJOR / 6 MINOR）

v10 把 Q-M1、Q-M2、R-M1 都照設計 §5.1 / §5.5 與舊控制台收斂了，沒有再加 Rust 欄位或結果分類。剩下的 MAJOR 是 v10 自己新寫的 §2.8：決定「建立網路」要不要出現的兩個輸入（「升級了沒」與「拿到 Rust 的回答」）沒有定義清楚，而且「升級了沒」寫成看 `NetIndex`，但 §2.6 規定 `NetIndex` 在佔用期間不重算——照字面實作，Q-M2 要擋的情況（節點其實已在網路裡、頁面卻給「建立網路」）會再出現。修法是一句話。

---

## 1. v9 發現的對應

| 發現 | 結果 | v10 位置 | 證據 |
|---|---|---|---|
| Q-M1 節點頁「建立網路」沒條件、沒「檢查網路」 | ✅（附 S-m2） | §2.4 節點頁段、D6 | 設計 329-app-uiux.md:755「網路（加入網路 / 檢查網路…）」；節點頁不放建立。但「同第 6 列分流」在手機沒有任何 net 時會變成「建立網路」（home_logic.dart:92-96 `NetRecords.none => makeNetwork`），和「節點頁不放建立」互相矛盾 → S-m2 |
| Q-M2 多筆 pending、登入失敗也給建立 | ⚠️ 部分 | §2.8、§6 第 5 步 | 逐筆檢查、登入失敗不給建立 ✅；「升級」判定與「拿到回答」的定義有洞 → S-M1 |
| Q m1 `close()` 時還在跑的步驟 | ⚠️ 部分 | §2.5 末段 | 「先等進行中的步驟做完」有；Q 要的上限沒寫；`close()` 的定義在 §2.2，順序沒同步改 → S-m6 |
| Q m2 生命週期表 | ⚠️ 部分 | §3.2 | 不存在的 pending 待辦已改成實際路徑（T-M2(a)）✅；檢查網路頁只有一列 T-R1，藍牙關 / 頁面消失（自己拿 vs 借用）/ 佔用收回沒有分列 → S-m6 |
| Q m3 4.1 pending 看全部 | ✅ | §2.4 | 看選到的那一筆；選單標「已建立 / 建立中」= nodes.dart:621 |
| Q m4 送新密碼失敗 | ✅ | §2.5 | 「已加入，新密碼沒有送出」+ 句子、算失敗、問繼續 |
| Q m5 `NetIndex` 列不出來 / 只有 mnet | ⚠️ 部分 | §2.4 | 「讀不到」、沒有表單 ✅；只有 mnet / mpend → 舊控制台 ✅；Q 要的「再試一次」沒有，而 `NetIndex` 只在啟動與 `released` 後重算（§2.6）→ 讀不到之後沒有路可以恢復 → S-m5 |
| Q m6 紀錄行斷言 | ✅ | §6 第 4 步 | 「斷言整行不含其他內容」 |
| Q m7 先選對象再拿佔用 | ✅ | §2.8 第一段 | — |
| R-M1 兩個釋放者 | ✅（附說明） | §2.5、§2.8、§3.1、T-M1(h)(i) | 「誰 acquire 誰放、借用的不放」；lease.dart:60-90 `hold` / `release` 冪等。從借用的檢查網路頁按「建立網路」→「回結果頁由迴圈處理」：誰把頁面帶到 4.1、迴圈先 `release` 再開 4.1 的順序只由 T-M1(i) 的結果保證，文字沒寫 → 併入 S-m6 |
| R m1 自動檢查和舊控制台不同 | ⚠️ 部分 | §2.5、D6 | 只在有 `rel` 時做 ✅、列 D6 ✅；「同一個 session，60 s」：建立結果不明多半是連線斷了（nodes.dart:50 `_makeUnclear`），同一個 session 已經不能用，要不要重新 `loginFor` 沒寫 → S-m4 |
| R m2 `sendUpdateFor` 參數 / 結果 | ✅ | §2.5 | `member: false, confirm: false` = nodes.dart:668 |
| R m3 對象比對、多筆 pending | ⚠️ 部分 | §2.8、§9 | 多筆 ✅（Q-M2 逐筆）；保留名稱比對的理由「精確比對要新的 bridge 函式」不成立：`OwnerSession.nodeDacHash()` 已存在且已匯出 → S-m1 |
| R m4 「放棄這次加入」佔用、dev 排除分支 | ✅ | §2.4、D7 | 自己拿短佔用；排除分支（nodes.dart:1277）不複製，列 D7；選 :698 有寫 |
| R m5 `close()` 等進行中的步驟 | ⚠️ 部分 | 同 Q m1 | — |
| R m6 放 hold 的順序 | ✅ | §2.5「頁面消失」、T-M1(g) | lease.dart:46-55 `run` 結束才 `_busy--` |
| R m7 生命週期表 | ⚠️ 部分 | 同 Q m2 | — |
| R m8 節點頁建立網路列 §4 | ✅ | D6 | — |
| R m9 零碎 | ✅ | §2.5（`Page.node` 連節點還原，core.dart:186-201 `setPage(pg, node:)`）；§2.4 改 :506（owner.rs:506 ✅）；4.1 句子不複製 Rust 字串；只有 mnet → 舊控制台；§6 第 4 步斷言 | — |

---

## 2. MAJOR

### S-M1　檢查網路頁決定「建立網路」的兩個輸入沒定義清楚；照字面實作時，節點已在網路裡也會給「建立網路」

- **情境 A（照字面）**：建立 04 途中拔電 → 結果頁 →「檢查網路」（借用迴圈的佔用）→ 04 開機、已套用 → 第一筆 `confirmNetwork` 回 `Confirm::Upgraded` → Rust 給 `PersistNet` 步驟、`OwnerConsole` 經 `RecordWriter` 寫入（owner.rs:885-889）。§2.8 說「遇到升級（`NetIndex` 重讀變成已建立，不看句子）就停」——但 §2.6 規定 `NetIndex`「啟動檢查通過與 `released` 之後各算一次」，佔用還在（借用或自己拿的都是），`NetIndex` 不會重算 → 判成「沒有升級」→ 繼續檢查其他 pending（`NoChange(OtherNetwork)`，「已停止」）→「都沒有升級，而且每一筆都拿到回答」→ 顯示次要「建立網路」。使用者照按 → 04 被建成第二個網路（owner.rs:1067-1089 不看既有紀錄），剛升級好的紀錄變成沒有節點的網路。這正是 Q-M2 要擋的結果。
- **情境 B（升級寫入失敗）**：`Upgraded` 後 CAS 失敗（另一筆寫入改了 generation，或佔用收回）→ `persistFailed` →「[REQ_FAIL] …」句子；紀錄仍是 pending，但節點**確實**在這個網路。「拿到 Rust 的回答」若把 `[REQ_FAIL]` 也算進去 → 給「建立網路」→ 同上。
- **情境 C（不確定）**：Rust 回 `InProgress` / `Unknown`（owner.rs:477、:480：「請一分鐘後 / 稍後再按『檢查網路』」）也是「Rust 的回答」。§2.8 括號寫「Rust 說『可以再建立一次』時照它的話」，但前一句的條件是「每一筆都拿到 Rust 的回答」——兩種讀法會寫出兩種程式。（舊控制台一直給建立，是基準；這裡只要求 v10 自己的條件寫成一種。）
- **證據**：plan §2.6「啟動檢查通過與 `released` 之後各算一次；不在 `acquire` 的等待裡」vs §2.8「`NetIndex` 重讀變成已建立」；owner.rs:879-892（升級才有 `PersistNet`、其他直接回 `confirm_text`）；owner.rs:442-449 `confirm_text` 每一種都以 `[NET_STATE]` 開頭；§0「新頁面不…重新分類 Rust 的結果」。
- **修法（不加 Rust、不分類句子內容，和 P8 看 `[JOINED]` 同一種做法）**：
  1. 「升級」= 這一筆 `confirmNetwork` 走到 `PersistNet` 且 `RecordWriter` 寫入成功後，在佔用下**直接重讀那一個 `rel`**（和 §2.5「重讀紀錄」同一個讀法）看 `applied`；不經 `NetIndex`。或寫明 §2.8 在佔用中觸發一次 `NetIndex` 重算，並把這個觸發點加進 §2.6——擇一寫明。
  2. 「拿到回答」= 每一筆 `confirmNetwork` 都以 `[NET_STATE]` 標籤的回答結束（`confirm_text` 的四種）；`[REQ_FAIL]`、`Err(String)`、`ask` 的 unclear / notSent、`persistFailed` 都不算 → 不給「建立網路」。
  3. 句子內容不分類：`InProgress` / `Unknown` 是否給建立照舊控制台（給），列在 §2.8 一句（屬基準）。
  4. 測試（各附改壞）：(a) 借用佔用、第一筆升級 → 停、沒有「建立網路」（改壞 = 用 `NetIndex` 判定 → FAIL）；(b) 升級後 CAS 失敗 → 沒有「建立網路」（改壞 = `[REQ_FAIL]` 也算回答 → FAIL）。

---

## 3. MINOR

1. **S-m1　名稱比對的保留理由不成立；精確比對不用新函式。** `OwnerSession.nodeDacHash()` 已存在（owner.rs:991-995「which own node this session is」）並已匯出到 Dart（lib/src/rust/api/owner.dart:107），`MemberView.dacHash` / `creator` 也已在（owner.rs:86-88、:120-121）。所以登入後可以精確判斷「這一筆 pending 的建立者是不是這台」：`creator && dacHash == s.nodeDacHash()`。用途：
   - §2.8「建立者是這台的每一筆 pending」改用它（名稱 `node-<last4>` 撞號時不會去檢查別台的紀錄；owner.rs:1079 名稱只有後四碼）；
   - 使用者手選的對象登入後若**確實**是建立者，就和名稱對到一樣處理；不是建立者 → 顯示「這台不是建立這個網路的節點」，不顯示 Rust「可以再建立一次」那句的誤導（owner.rs:478）。
   - 登入前的預選仍用名稱（顯示用）。改 §9 R m3 那一列的理由。這不是新機制（現成的 bridge 方法）；若決定不用，請把理由改正。
2. **S-m2　節點頁「同第 6 列分流」在手機沒有任何 net 時會分到「建立網路」。** home_logic.dart:95 `NetRecords.none => (makeNetwork, joinTeam)`；§2.4 同時寫「節點頁不放建立網路」。手機零筆 net、節點 `node_state == 1`（剛新增、還沒建網）時節點頁到底顯示什麼沒定。設計 §5.5（:755）只列「加入網路 / 檢查網路」；建議寫明：零筆 net 時節點頁網路分組照第 6 列給「建立網路」（入口與 3.5 相同，沒有拆隊風險），或不給、只指回首頁——擇一，§6 加一條測試。
3. **S-m3　「只有 pending、建立者回不來」在新頁面是死路，要寫進 D6 / §8。** 情境：0→2 台，04 建立途中拔電、04 壞了（或使用者想改用 02 建）。首頁第 6 列（有 net）→「加入網路」→ 4.1 選到 pending →檢查網路頁 → 04 登入失敗 → 只有「再檢查一次」；手選 02 → 不給建立（§2.8）；節點頁不放建立（§2.4）；pending 紀錄新頁面清不掉（基準）。新頁面永遠走不到建立。這是設計 §5.1 / §5.3「有 net 就不建立」加上 v10 §2.8 的直接結果，不必加新機制，但要誠實寫出：dev 版出口 = 舊控制台的「建立網路」（nodes.dart:1731，一直都在）；field 版的出口隨 PR 5 / 6 / #255；寫進 §4 D6 與 §8 限制、§7 真機情境記一次，並進 #329 checklist。
4. **S-m4　自動檢查一次的「同一個 session」。** 建立結果不明多半是連線斷了（`_makeUnclear`，nodes.dart:50）；`request_confirm_network` 要求 `St::Conn`（owner.rs:1172-1174）。寫明：session 還在 → 直接 `confirmNetwork(rel)`；已斷 → 一次 `loginFor`（60 s）再確認；兩者的計時各多少（R m1 後半）。現寫法若照字面只用舊 session，斷線時永遠「沒拿到回答」，A18 的真機觀察會偏。
5. **S-m5　`NetIndex`「讀不到」之後沒有恢復路徑。** §2.4 讀不到 → 4.1 沒有表單；§2.6 只在啟動與 `released` 後重算。使用者唯一的方法是做一個會拿佔用的操作或重開 app。Q m5 要的「再試一次」= 觸發一次重算（同一個函式），寫進 §2.4 / §2.6 並加測試；或寫明「重開 app」並列為限制。
6. **S-m6　生命週期與 `close()` 的文字沒同步。**
   - §2.2 的 `close()` 順序仍是「取消監聽 → 取消訂閱 → 關連線 → dispose」，§2.5 末段才說先等進行中的步驟——放回 §2.2 同一段，並寫上限（例如等到 `ask` 的逾時；seal / CAS 卡住時的處理）。
   - §3.2 檢查網路頁只有一列：自己拿 / 借用兩種在「頁面消失」「藍牙關（precondition）」「佔用收回」各是什麼行為；借用時按返回要先 `close()` 自己的 `OwnerConsole` 再回結果頁（不然結果頁「再試這一台」的 `loginFor` 會撞到還開著的連線，`BleGate.connect` 一次一條，ble_gate.dart:185）。
   - 借用的檢查網路頁按「建立網路」：寫明順序「本頁 `close()` → pop 回結果頁 → 迴圈 `close()` + 關 `keepScreenOn` + `release` → 開 4.1」，由誰執行。

---

## 4. v10 新改動的其他檢查（沒有發現）

- **選對象 → 再拿佔用（§2.8）**：選單開著時不佔用 ✅；從結果頁進來是借用，選單期間佔用本來就在迴圈手上，沒有新的佔用期間。
- **一次登入逐筆檢查**：`request_confirm_network` 每次只要求 `St::Conn` 且 `flow_busy` 為空（owner.rs:1166-1178），回答後回到 `Conn`（owner.rs:879-892 `*asked = ""`）→ 同一 session 可連續檢查 ✅。`info.net` 唯讀額度每連線 5/s、突發 20（254-p2-impl.md:98）→ 幾筆依序檢查不會撞 `E_RATE` ⚠️（推論，依設計文件，沒查 provd 原始碼）；就算撞到，`Unknown` 是 `NoChange`，不寫紀錄。
- **檢查錯的紀錄**：`confirm` 對不是自己的 net_id 只會 `NoChange` / `OtherVersion`（netrec.rs:511-521）✅，逐筆檢查無害。
- **D6 / D7**：和 §2.4 / §2.8 一致 ✅（D6 的條件在 S-M1 修好後要同步改字）。
- **§3.1**：佔用一個寫入者（acquire 的一方）✅；`keepScreenOn` 只有迴圈與軟體更新頁 ✅。
- **安全**：沒有新的輸入面；佔用 / `RecordWriter` fail-closed 不變（lease.dart:43 `valid`）。被入侵的節點對 `confirm` 說謊可把 pending 升級（netrec.rs:504-506 註解，join2 §3.2 的決定，基準）；在 S-M1 修好之後，說謊最多讓頁面**不**給「建立網路」，方向安全。本機無特權程序：本 PR 沒有新的平台方法或匯出元件（§5）✅（照計畫，未審實作）。

## 5. 從零到兩台 / 中斷情境（只讀原始碼推論 ⚠️）

- 順利路徑：同 Q / R 的推演，v10 沒改 → 走得通。
- 建立中拔電、04 回來已套用：結果頁 → 檢查網路（借用）→ 第一筆 `Upgraded` → 寫入 →（S-M1 修好後）停、回首頁 → 02 要從第 6 列重新「加入網路」。OK。
- 04 回不來：死路，見 S-m3。
- app 被殺：佔用只在記憶體，紀錄停在 pending / joining → T-M2(a)(b) 的路徑 ✅。
- 藍牙關：`precondition` → 迴圈整個停；檢查網路頁 → 「登入失敗 → 只有再檢查一次」✅。
- 頁面關掉：迴圈等當前 `lease.run` 再放 hold ✅；檢查網路頁的兩種見 S-m6。
- 選錯節點：4.1 選錯只是在那台建立；檢查網路頁手選錯 → 不給建立、只看到「可以再建立一次」的句子（S-m1 可改善）。

## 6. 基準備註（不算發現）

- 舊控制台在 `InProgress` / `Unknown` 時也給「建立網路」（nodes.dart:1724-1731 只看 `logged`）；按下後節點的 `.txn` 會先 Finish（254-net-update-members.md:108），多一筆 pending。屬 join2 / 舊控制台。
- pending 紀錄新頁面清不掉；`confirm` 信任節點的 key 10 / 9；`RecordWriter` 檢查佔用與寫入的空檔（PR 1）。

## 7. 驗證分類

### ✅ 已驗證（原始碼 @ 78a5177）
- owner.rs:78-91 `MemberView`（`dac_hash`、`creator`、`last4` 來自 device_id）；:110-121 `net_summary`；:427-431 `persist_step`；:442-449 `confirm_text` 都帶 `[NET_STATE]`；:474-481 `join_state_text`；:506 NotApplied 拒絕句；:879-892 info-confirm 回答（升級 → `PersistNet`，其他 → 直接回答）；:991-995 `node_dac_hash`；:1067-1089 建立不看既有紀錄、名稱 `node-<last4>`；:1158-1178 `check_network` 用 `made`、`request_confirm_network` 要 `St::Conn`；:1460-1470 device_id 只在 Applied 填。
- lib/src/rust/api/owner.dart:107 `String nodeDacHash();`（已匯出；lib 內目前沒有呼叫者）。
- netrec.rs:511-537 `confirm`；flow.rs:142-175 `JoinState` / `join_state`（`Unknown` 含 info.net E_RATE）。
- nodes.dart:50（`_makeUnclear` 由 Q 引）、:621、:668、:1240-1246、:1248-1290、:1277、:1724-1737。
- home_logic.dart:89-99 第 6 列分流；core.dart:186-201 `setPage(pg, node:)`；lease.dart:43-90。
- 329-app-uiux.md:673、:726、:738、:750、:755。

### ⚠️ 推論
- S-M1 情境 A 的危害依「照字面實作」推；實作者若自行在佔用中重讀，就不會發生——所以是介面定義的問題。
- `info.net` 額度來自 254-p2-impl.md:98，沒查 provd 原始碼。
- 所有中斷情境只讀原始碼，沒有跑。

### ❌ 沒做
- 沒跑測試、沒上真機；沒有重驗 v1–v8 的發現；沒有審 PR 1 / PR 2 的基準實作。
