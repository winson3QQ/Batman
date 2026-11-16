# #329 PR 3 實作計畫 v9 審查（審查者 Q，獨立）

對象：`docs/design/329-pr3-plan.md` @ c70de1a（feat/329-pr3）。範圍照指示：只審 §0 的新部分（4.1–4.5 / 檢查網路頁 / `ClaimPage` 換樣式；`loginFor` + `HandoffProber` / `FrameInbox` + `OwnerConsole`；多台迴圈；`NetIndex` 與首頁 / 節點頁按鈕去處），以及新頁面和舊控制台 / join2 / 上層設計 §5.1、§5.3、§5.4（另看 §5.5，因 v9 在節點頁加了按鈕）不同而 §4 沒寫的地方。join2 的疑問放「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 2 MAJOR / 7 MINOR）

v9 補回了 v8 漏掉的舊行為（送新密碼、`clearNotY`、檢查網路頁、D5 / A18），`loginFor` / 交接 / `OwnerConsole` / `NetIndex` 的接線和原始碼對得上。剩下兩個 MAJOR 都出在 v9 新加的接線：節點頁的「建立網路」沒有條件（和設計 §5.5 / §5.3 不同、沒列 §4），以及「建立途中拔電」這條真實路徑上，手機會有兩筆以上 pending，檢查網路頁沒說檢查哪一筆。

## MAJOR

### Q-M1　節點頁的次要「建立網路」沒有條件，和設計 §5.5 / §5.3 不同且沒列進 §4；節點頁也沒有「檢查網路」入口

- 情境 A（拆隊）：隊長已有一個已建立的網路，新增第 3 台 → 節點頁。v9 §2.4「節點頁對還沒加入網路的節點也給次要『建立網路』」→ 主要「加入網路」旁邊就是「建立網路」。誤按 → `request_make_network` 不檢查手機已有的網路（owner.rs:1067-1089，每次新 net id）→ 第 3 台在另一個網路，手機有兩筆已建立的 net，之後每次加入都要選。Rust 自己的句子把這件事當成嚴重後果（「新建網路會讓整隊分成兩個網路」，owner.rs:554 `AdminSignFailed`）。
- 情境 B（單台、拔電後節點其實已套用）：隊長只有 04，建立途中拔電，04 開機後已在網路裡（`node_state` ≠ 1），手機紀錄還是 pending。首頁第 6 列不成立（home_logic.dart:89-99 只看 `notInNetwork`），走第 7 列 →「看這台節點」→ 節點頁。v9 沒寫節點頁有「檢查網路」（設計 §5.5 :755 的網路分組有；現在的 node_page.dart 只有移除，:47-55）。紀錄卡在 pending，直到新增第二台、經 4.1 的 pending 畫面才走得到檢查網路頁。
- 證據：設計 §5.5 :755「網路（加入網路 / 檢查網路 / 離開在『更多』）」；§5.3 :726「手機已經有 net 紀錄 → 3.6，主要『加入網路』，次要『再加一台』」（有 net 時刻意不給建立）；§5.1 第 6 列只在「都沒有」時給「建立網路」。v8 P-M2 的缺口只在「手機的 net 都是 pending」時存在。
- 修法：
  1. 節點頁網路分組照 §5.5：`node_state == 1` →「加入網路」（同第 6 列分流）；有 pending net 時加「檢查網路」→ 檢查網路頁、預選這一台。
  2. 次要「建立網路」只在手機**沒有已建立的 net**（`NetIndex` 全部 pending 或沒有）時出現——這就是 P-M2 的缺口，和 4.1 pending 畫面同一個條件；不是新的建立條件，是設計 §5.1 / §5.3「沒有 net 才建立」的同一規則。
  3. 若刻意保留無條件版（照舊控制台），就列 D6 寫理由。
  4. 測試：已建立 net + 未加入節點 → 節點頁沒有「建立網路」；只有 pending → 有；節點已在網路、紀錄 pending → 節點頁有「檢查網路」。各附改壞。

### Q-M2　「建立途中拔電」：手機會有兩筆以上 pending，檢查網路頁沒規定檢查哪一筆；登入失敗後也給「建立網路」

- 情境（§7 的真機情境，只用新頁面）：
  1. 4.1 建立 04、途中拔 04 電 → `ask` 結果不明 → 重讀 pending → 自動檢查一次：04 沒電，`loginFor` 60 s → `notFound` →「仍不是」→ 結果頁給「檢查網路」與「建立網路」（§2.5）。
  2. 使用者看到「建立網路」就按了（04 開機後）。但 04 可能**已經套用了第一個網路**（拔電發生在 apply 之後）。新的建立 → 新 net id（owner.rs:1067-1089），PersistNet 先寫 pending（owner.rs:1092-1093 `net_persisted` 註解：先存紀錄再送 `network/join`），節點拒絕或結果不明 → 手機現在有**兩筆 pending、同名**。
  3. 檢查網路頁：§2.4 只定了「對象節點 = pending 紀錄的建立者」，沒定**哪一筆紀錄**。檢查到第二筆 → `flow::join_state` 看到節點的 key 10 是第一筆的 net id → `OtherNetwork`（flow.rs:166）→「這台節點已經在『另一個』網路裡，已停止」（owner.rs:479）→ 使用者再按「建立網路」→ 第三筆。真正能升級的第一筆從沒被檢查。
- 證據：§2.4 檢查網路頁的對象規則只有節點；§2.5「仍不是 → 結果頁顯示 Rust 的句子、『檢查網路』與『建立網路』」把 `loginFor` 失敗（沒有 Rust 句子、結果未知）也算進去；join2 §3.2 / owner.rs:478 只有在檢查回 `NotApplied` 時才說「可以再建立一次」。`confirm` 對錯的紀錄無害（netrec.rs:509-537 只會 `NoChange` / `OtherVersion`），所以多檢查幾筆是安全的。
- 修法（不分類 Rust 結果、不加 Rust 欄位）：
  1. 檢查網路頁：一次登入後，對**建立者是這台的每一筆 pending** 依序 `confirmNetwork(rel)`，遇到「升級」就停（`NetIndex` 重讀判定已建立，不看句子）；從結果頁進來時先檢查剛建立的 `rel`。顯示每一筆的 Rust 句子。
  2. 「建立網路」只在**這次真的拿到了檢查的回答**之後才給（區分的是 `loginFor` 有沒有成功，不是 Rust 句子的內容）；`loginFor` 失敗 → 只給「再檢查一次」。
  3. 測試：兩筆 pending、節點 info key 10 = 第一筆 → 檢查網路頁把第一筆升級；`loginFor notFound` → 結果頁沒有「建立網路」。改壞：只檢查最後一筆 / 登入失敗也給建立 → FAIL。
  4. §7 的拔電情境把「04 已套用」與「04 沒套用」兩種都記下來。

## MINOR

1. **m1　O m4 後半沒處理（§9 表只對應了 `rel`）。** `ask` 逾時時 `FrameInbox` 的處理者可能還在 seal / `writeCas` / `netPersisted`（nodes.dart:256-266 這段在 `OwnerConsole` 裡照抄）。§2.2 `close()` 的順序是「取消監聽 → 取消訂閱 → 關連線 → dispose session」，沒有等進行中的步驟；dispose 後那一步再呼叫 `s.netPersisted()` 會丟例外，重讀紀錄也可能早於那筆 CAS。方向 fail-safe（判成 pending → 檢查網路），但要寫：`close()` 先等目前的步驟結束（有上限）再 dispose；加測試。
2. **m2　§3.2 生命週期表不準、少檢查網路頁。** 「紀錄停在 pending → 首頁待辦」：沒有這個待辦（§2.6 只做 joining；pending 的建立者 `device_id` 是 None，owner.rs:1463-1469 到 Applied 才填，join2flow.rs:362 只有加入者有）。實際路徑是第 6 列 / 4.1 pending 畫面 / 節點頁（見 Q-M1）。檢查網路頁（登入 60 s + 確認）沒寫：頁面消失、藍牙關、`keepScreenOn`、`PopScope`。
3. **m3　4.1 的 pending 判斷用「手機的 net 都是 pending」。** 混合情況（一筆已建立 + 一筆舊 pending，正是 Q-M2 之後的狀態）時加入表單會列出兩筆，選到 pending → 迴圈登入 60 s 後被 Rust 拒（owner.rs:506）→ 結果頁只有「再試這一台」。改成看**選到的那一筆**的 `NetView.applied`（已顯示的欄位，不是新分類），選單照 `_pickNet` 標「已建立 / 建立中」（nodes.dart:617）。
4. **m4　送新密碼失敗時那一台算什麼（P m2 後半，v9 未寫）。** `[JOINED]` 之後 `sendUpdateFor` 不明 / 失敗：結果頁那一列要寫「已加入，新密碼沒送到」+ Rust 句子，不是單純成功。
5. **m5　`NetIndex` 列不出來時 4.1 會一直「正在讀取」；算完是 mnet / mpend / 沒有時 4.1 做什麼沒寫**（P m6 後半）。列不出來 → 顯示錯誤 +「再試一次」；算完不是 net → 照第 6 列分流（D3），不給隊長表單。
6. **m6　`NetIndex` 紀錄行的斷言沒進 §6 第 4 步**（O m2 要求原始碼 / 輸出斷言）。
7. **m7　檢查網路頁拿佔用的時機。** §2.4「拿 session 佔用 → 選對象」：對象要使用者選時，選單開著就佔著佔用（首頁不讀）。改成先選、後拿佔用。

## v8 審查 O、P 的對應（§9 宣稱是否成立）

| 項目 | 結果 |
|---|---|
| O-M1 檢查網路頁 | ⚠️ 部分：頁面、對象節點、重用佔用都有；入口少了節點頁（Q-M1）、哪一筆紀錄沒定（Q-M2）、首頁待辦改走 4.1（可接受，但 §3.2 沒改，m2） |
| O-M2 送新密碼 | ✅ §2.5；失敗結果見 m4 |
| O-M3 D5 / A18 | ✅ §4 D5（理由 netrec.rs:524-527 已核對）、§2.5 自動檢查、§7 A18 |
| P-M1 `clearNotY` | ✅ §2.1 簽章、「再試這一台」傳 true（core.dart:628、:676） |
| P-M2 pending 時建立網路 | ⚠️ 補了，但條件放寬成所有未加入的節點（Q-M1） |
| O m / P m `[JOINED]` | ✅ P8 + §2.5 只看加入請求的回答（owner.rs:514 vs :589-590） |
| O m / P m 頁面消失 | ✅ §2.5 立刻放 hold、關 `keepScreenOn`（lease.dart:60-71 hold 歸零即 release，不會進 `unsavedTodos`） |
| O m `NetIndex` 紀錄 | ✅ 規則有；測試見 m6 |
| O m4 `rel` / 逾時時寫入還在路上 | ⚠️ `rel` ✅（owner.rs:426-430）；寫入在路上 ❌（m1） |
| O m / P m 建立者 | ✅ 第一台、可換；不加條件 |
| P m 待辦與「放棄這次加入」 | ✅ §2.4（`net_forget_joining`，owner.rs:131-158，建立者拒絕） |
| P m 計算中按「加入網路」 | ⚠️ 計算中 ✅；列不出來 / 算完不是 net 沒寫（m5） |
| P m8 v7 報告 | ✅ §9 標題說明 v7 停掉、沒有報告 |

## 從零到兩台（只用新頁面，推論）

新增 04（`ClaimPage` 原始佔用）→ `ClaimDone` → 取名 → 3.5「建立網路」→ 4.1 建立 → 開始（session 佔用 + hold，`acquire` 等 `released`）→ `loginFor` 04 → `makeNetwork`：先 PersistNet pending（owner.rs:1092-1093 `net_persisted` 註解）再送 → `[NET_MADE]` + Applied 寫入（owner.rs:1460-1475）→ 重讀已建立 → 結果頁 → 放佔用、`NetIndex` 重算。新增 02 → 3.6「加入網路」→ 4.1（一筆、直接選）→ `loginFor` 02 → 國家對話框 → `[JOINED]` → `poll_link` 連線檢查 ≤120 s。順利路徑 ✅ 對得上。拔電路徑見 Q-M2。

## 安全

- 沒有佔用：`loginFor` 比對 `reg.current`、`Lease.valid`（lease.dart:43）、`RecordWriter` 拒絕 → fail-closed ✅。
- 交接只在 `loggedIn` 之後（prober.dart:85-87 的同一點），`loginOutcome` 原樣抽出、不種「是 Y」（prober.dart:94-104）✅。`FrameInbox` 無上限（P nit，仍建議上限）。
- 檢查網路頁可由使用者選任一台 `node/` 當對象：選錯只會 `NoChange`（netrec.rs:509-516）✅。
- 秘密：`OwnerConsole` 不寫回答內容、`NetIndex` 只記 net id 前 8 碼 ✅（規則層；實作未見）。

## 最小必要

- `MemberView.deviceId`：一行 + 測試；`last4` 也能對，但 deviceId 精確，接受。
- 「按開始時重新列檔」：防表單過期，接受。
- Q-M2 的修法（同一次登入檢查多筆）是在現有 `request_confirm_network` 上重複呼叫，不加 Rust。

## 基準備註（不算發現）

- 舊 pending 紀錄在新頁面沒有清掉的方法，會一直出現在選單（join2；O / P 也記過）。
- `confirm` 信任節點的 key 10 / key 9：一台說謊的節點可把 pending 紀錄升級成已建立（不加成員，netrec.rs:503-505 註解）；join2 §3.2 的決定。
- `RecordWriter` 檢查佔用與寫入之間的空檔（PR 1）。

## 驗證分類

### ✅ 已驗證（原始碼，c70de1a）
- owner.rs:78-93 `MemberView` 沒有 `deviceId`；:116 `net_summary` 有 `m.device_id`；:426-430 `persist_step` 設 `rel`；:446-447 `[NET_MADE]`；:474-480 `join_state_text`（NotApplied「可以再建立一次」、OtherNetwork「另一個網路」）；:506 NotApplied 拒絕句；:514 / :589-590 `[JOINED]`；:1067-1089 建立不看既有網路；:1092-1093 pending 先存再送；:1158-1163 `check_network` 用 session 的 `made`；:1168-1181 `request_confirm_network` 只要 `St::Conn`；:1437-1439 `poll_link` / `send_update`；:1460-1475 device_id 到 Applied 才填。
- netrec.rs:400-412 pending 建立者 = 第一個 Joining 成員；:509-537 `confirm` 只升級建立者；flow.rs:157-168 `join_state` 的 OtherNetwork。
- join2flow.rs:362 加入者有 `device_id`。
- nodes.dart:50 `_makeUnclear`；:476-492 舊控制台建立不自動檢查；:592-624 `_pickNet` 標「已建立 / 建立中」；:651-669 `_sendAfter`；:274-291 國家對話框頁面消失時答「不要」；:1730-1737 兩顆按鈕一直都在。
- lease.dart:43-91 `valid` / `hold` / `pageGone` / 420 s 收回進 `unsavedTodos`。
- home_logic.dart:89-99 第 6 列分流；node_page.dart 目前只有移除。
- 設計 329-app-uiux.md §5.1 第 6 列、待辦表；§5.3 :726；§5.4 表與 :738、:750；§5.5 :755。

### ⚠️ 推論
- Q-M2 第 2 步「節點已在第一個網路時拒絕第二次建立」：provd 端行為沒查（Rust 端確認不擋）。
- 從零到兩台、拔電路徑：只讀原始碼，沒跑。
- `node-<last4>` 名稱與 `node/` 紀錄後四碼同格式（owner.rs:679、:1080 同一個 `last4`；大小寫未在真機確認）。

### ❌ 沒做
- 沒跑測試、沒上真機；沒逐條重驗 v1–v6 發現。
