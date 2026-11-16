# #329 PR 3 實作計畫 v2 — 對抗式審查（審查者 D，獨立）

審查對象：`docs/design/329-pr3-plan.md` v2（commit 8892836，branch `feat/329-pr3`）。上層：`docs/design/329-app-uiux.md` v12.1。對照 v1 審查 A / B。原始碼：同一工作樹（`git diff 29b0085 HEAD --stat` 只有 `app/test/nodes_update_send_test.dart` 與三份文件）。只讀；除本檔外沒有改任何檔案；沒有跑測試。

## 結論

**Verdict：REJECT（改版後整份重審）。** 1 個 BLOCKER、4 個 MAJOR、14 個 MINOR。

v2 的方向是對的，v1 的主要問題大多真的處理了：
- 登入改成 `NodeLink.loginFor` 驅動 `core.LoginFor`。
- 舊控制台改成複製、不動。
- 建立閘門改在佔用下重新列檔。
- 摘要表改成列檔決定有沒有紀錄。
- 多台流程寫成狀態機，目標網路只決定一次。

但還有一個新的問題，而且正是 v2 的 fail-closed 閘門造成的：**建立網路失敗一次，這支手機就再也建不了、也加不了網路（field 版沒有出口）。** 另外，`ConsoleResult` 和交接機制沒有對上程式碼的實際行為。

---

## BLOCKER

### B1　建立失敗一次就是死路：閘門不准再建立，加入要求已套用，檢查網路升不上去

**情境（現場）**：隊長第一次建網。`PersistNet`（pending 的 net 紀錄）已經寫進手機，之後以下任何一件事發生：
- 節點斷電或重開，沒有套用；
- 節點回 `Rejected`；
- nonce 連續兩次被拒；
- 自動「檢查網路」之後仍然沒有套用。

**證據**：
- Rust 先寫紀錄再送出：`owner.rs:1451-1458`（`J::PersistNet` → `persist_step(..., 0)`）。
- 失敗之後只回到連線狀態，紀錄留在磁碟：`owner.rs:1500-1502`（連兩次拒絕）、`:1514-1516`（`Rejected`：「**下次會用新的網路編號**」，也就是 Rust 預期隊長再建立一次、產生新的 net id）、`:1518-1524`。
- 建立者永遠不會被忘記：`owner.rs:87-88`「the node that made the network (never forgotten)」。`net_forget_joining`（`owner.rs:131`）只處理加入中的成員。Dart 與 Rust 都沒有「丟掉一筆 pending net」的入口（grep `storeRemove` 只命中 `node/` 與 `mpend/`：`nodes.dart:467`、`:1026`）。
- 計畫 §2.3：「任何一個有檔案 → 這次是加入」；加入時目標不是已套用 → 不送。§2.4：「建立按鈕只在三種檔都是 0」。§2.3 第 2 步：仍未套用 → 整個流程停，結果頁給「檢查網路」。
- `request_confirm_network`（`owner.rs:1168-1178`）只在節點的 key 10 對得上時升級。節點根本沒套用時，結果是 `NoChange` / `OtherVersion`（`owner.rs:484-491`），紀錄維持 pending。
- 舊控制台的出口是再按一次「建立網路」（`_makeNetwork` 不檢查已有的 net，`nodes.dart:476-492`）。但它只在 devTrust 的開發者選項裡（`settings_page.dart:37-44`）。

**後果**：
- 第 6 列：有 net、沒有已套用的 →「檢查網路」→ 升不上去 → 永遠停在這裡。
- 4.1 加入：目標沒有已套用的網路 → 不送。
- 建立：閘門擋住。
- field 版（以及「不進舊控制台」的目標）沒有任何出路。
- 唯一的出口是重裝或清資料。這會連帶丟掉 Keystore，所有節點紀錄打不開，**每台節點都要重燒**。
- 觸發條件（建網途中節點斷電）在現場很常見。

**修法（最小）**：加一個只在一種條件下出現的動作：「這個網路沒有建立成功，重新建立」。條件全部成立才給：
1. 這筆 net 是 pending；
2. 成員只有建立者（沒有其他加入中或已套用的成員）；
3. 在佔用下對建立者做「檢查網路」，節點明確回報不在這個網路（info key 10 沒有、或不是這個 net id）。

這時用 `RecordWriter.keepCopy`（留副本到例如 `forgotten-net/`）+ `remove` 處理那筆紀錄，閘門就會放行。
- 建立者讀不到或回答不明 → 維持 fail-closed，句子寫「把建立網路的那台開機放在旁邊再按檢查網路」。
- 測試：上面三種情況各一案例 + 負向對照（條件 3 拿掉 → 節點其實已套用時也被丟掉 → FAIL；整個動作拿掉 → 死路 → FAIL）。
- 只靠「建立閘門放寬到全部 pending 就可以建」不行：那次結果不明時，建立者可能已經套用，會分成兩個網路。

---

## MAJOR

### M1　`ConsoleResult` 對不上實際結束方式：成功 / 失敗只能看文字；`Refused` 被當成佔用遺失；`NoLease` 進不了 `leaseLost`

**證據**：
- **加入的結果幾乎都以 `answer` 回來**，只差字頭：`[JOINED]`、`[REQ_FAIL]`、`[JOIN_STATE] 結果不明`（Rust 自己判斷的不明：`Keep::Unclear7` / `Unclear`）、`[COUNTRY] 已取消`（`owner.rs:501-566`）。計畫的 `done(line)` 不分成功或失敗，`unclear` 只指 Dart 端的斷線（`SendTrack`）。NetworkRun 的「完成 / 失敗原因」、停止規則、結果頁「再試這一台 / 檢查網路」都需要分類，計畫只能靠解析字頭。
- **`GateLink.write` 在連線已斷時丟 `Refused`**（`ble_gate.dart:84-86` `_usable`：`!_open || _down || !valid`）。這是「節點重開 / 連線斷」最常見的路徑。計畫 §2.2.1 把 `NoLease / Refused` 對到 `leaseLost`（整個流程停、「這個操作被中斷了」），等於把可恢復的斷線變成致命。這也和 `_ask` 的行為不同：舊程式在可重送的請求遇到寫入失敗時會重新登入、重送一次（`nodes.dart:540-566`），在 unclear 類的請求裡給 unclear / notSent。
- **`NoLease` 在 persist 路徑被吞掉**：舊程式把任何非 String 的例外變成 `'${e.runtimeType}'`，交給 `persistFailed`（`nodes.dart:265-271`）。Rust 回的是 `answer`：「[REQ_FAIL] 建立網路沒有成功：手機儲存失敗（NoLease）」（`owner.rs:1133-1155`）。照抄的話，`leaseLost` 在最重要的寫入點永遠不會出現。
- 表裡沒有的結束方式：
  - `confirmNetwork` 用預設 15 s、沒有 `unclear` 參數，逾時回 `_waitLine`（`nodes.dart:530`、`:1244`）；
  - `ended` → `endedLine(detail)`（`:331-337`）；
  - 處理訊框時丟例外 → `_endUnclear`（`:344-346`）；
  - 重入（`_busy && !held`，`:521`）。
- `keyFail` 不是步驟迴圈的結果。簽章失敗時舊程式只 `_say`（`_keyFail`，`:163-166`），送空簽章，結束的是 Rust（例如 `AdminSignFailed`，`owner.rs:551-553`）。計畫沒有寫怎麼得到 `keyFail(level)`。`seal` 的金鑰閘門錯誤（`:268`）也一樣。

**修法**：
- `ConsoleResult` 帶結構化欄位，不解析文字：
  - 加入成功 = 收到 `pollLink`（`nodes.dart:315`，Rust 在已套用時設）；
  - `sendUpdate` 照現況；
  - 建立 / 檢查網路的成敗 = 用 `rel` 重讀紀錄的 `applied`（計畫在建立者那裡已經這樣做，加入者也要寫）；
  - Rust 判斷的不明（`[JOIN_STATE]` 那兩種）要有自己的種類，或明寫視為 `unclear`。
- `leaseLost` 改成看 `!lease.valid`（`lease.dart:43`），不看例外類型。`GateLink` 的 `Refused` 在 lease 仍有效時 = 斷線，照 `_ask` 的 unclear / notSent / 重送一次處理。
- persist：`writeCas` 丟 `NoLease` 時仍要呼叫 `persistFailed`（讓 Rust session 回到一致的狀態），但結果標成 `leaseLost`。
- 補上 timeout、ended、frameError、busy 四種。`keyFail` 由注入的 sign / seal 包裝記一個旗標，結束時一起回傳。
- 測試與負向對照：
  - 斷線後寫入（`Refused`、lease 有效）→ 重送一次，不是 `leaseLost`。對照：照計畫的對應 → FAIL。
  - persist 時 lease 被收回 → `leaseLost`。
  - Rust 回 `[JOIN_STATE] 結果不明` → 結果頁給「再試這一台」。

### M2　`HandoffProber`「和 `SessionProber` 同一個步驟迴圈」做不到計畫寫的樣子；交接後訊框會被丟掉，也沒有排成一列處理

**證據**：
- `SessionProber.probe` 的迴圈是區域 closure。訂閱的處理函式在結果決定之後**丟掉所有訊框**：`prober.dart:133-134` `if (result.isCompleted) return;`。登入成功（= 結果決定）之後交出去的「已訂閱 TX 串流」不會再把任何訊框交給 Rust。
- `finally` 會取消訂閱並 `dispose` session（`prober.dart:160-175`）。交接時這兩件都不能做。
- `SessionProber` 每個訊框各自 `run(st)`，彼此沒有排隊（`:147`）。舊控制台用 `inbox.stream.asyncMap(...)` 讓訊框一個接一個處理（`nodes.dart:340-347`）。建網 / 加入中間有 `seal` + `writeCas` 的 await；這段時間到的訊框如果並行跑，同一個 `OwnerSession` 會被交錯呼叫。
- 計畫 A2：「同一份程式碼抽成共用函式；`SessionProber` 現有測試不改判定」。要達成，至少要把「停在 loggedIn」「成功時不清理」「訊框改走可移交的佇列」都參數化。計畫沒有寫，也沒有對應的測試。

**修法**：
- 寫明交接機制：在訂閱之前先建一個 inbox `StreamController`，prober 從 inbox 讀到 `loggedIn` 為止；之後 inbox 原封交給 `OwnerConsole`，`OwnerConsole` 用 `asyncMap` 排成一列消費。交接之間到的訊框留在 inbox 裡，不丟。
- `SessionProber` 只抽出不影響它判定的部分，或者乾脆不共用，寫一個獨立的 `HandoffProber`（只到 loggedIn，約 60 行）並有自己的測試。
- 測試 + 負向對照：
  - persist 等待中再來兩個訊框 → 依序處理。對照：每個訊框各自 `run` → FAIL。
  - 交接瞬間來一個訊框 → 被處理。對照：沿用 `result.isCompleted` 丟棄 → FAIL。
  - 交接成功時 session 沒有被 `dispose`。

### M3　4.1「已在網路裡的不能勾」把設計裡的恢復路徑堵死

**證據**：
- §2.7：待辦「節點加入網路沒有做完」→ 4.1 預設勾那一台。但加入結果不明時，節點常常其實**已經套用**，只是手機紀錄還是 joining。這時節點讀到的是在網路裡，照 4.1 的規則不能勾，待辦點下去是死路。
- Rust 自己就叫使用者對這種節點再按一次「加入網路」：
  - `owner.rs:498`（`LATER`）、`:534-535`（Unclear7 / Unclear）；
  - `:556-560`（`PersistFailed { applied: true }`：「節點已套用……請在這台按『加入網路』補上紀錄」）；
  - `join2flow.rs:107`（「the join stays joining … try again later on this node」）。
- §2.3 第 3 步的 `sendUpdate` 只會發生在「已經是成員（舊版）」的節點。讀得到的這種節點都不能勾，這條路只剩「沒讀到」的節點走得到。
- 需要的資料其實有：`StatusView.netId`（`owner.dart:559-560`，info key 10）和 `nodeState`（`home_logic.dart:31`）。

**修法**：
- 規則改成：讀到在網路裡、而且 `netId` 不是這次的目標（或讀不到 `netId`）→ 不能勾。`netId == 目標` → 可以勾，標「補完加入」。
- 建立模式：在網路裡的節點都不能當建立者。
- 待辦點下去時，目標 = 那筆 net，那一台一定可勾。
- 測試：待辦那一台的 `netId` = 目標 → 可勾、加入送出。對照：照計畫的規則 → 不能勾 → FAIL。

### M4　建立閘門（v1 BLOCKER 的修法）的分支沒寫完，也沒有自己的負向對照

**證據**：
- §2.5：「列不出來 / 計算中 / 有打不開」→ 中性「加入網路」→ 4.1。但 4.1 要依摘要表決定顯示「名稱 / 頻道」（建立）還是「加入哪一個網路」，計算中時兩種都不知道。
- §2.3「只有 mnet / mpend 的手機不會進這頁」不成立：計算中或列不出來時走中性入口，只有 mnet 的手機也會進 4.1。閘門看到 mnet → 「加入」模式，可是沒有 net 目標。計畫沒有寫這時怎麼辦。
- Dart `Directory` 列檔要和 Rust `list_kind` 用同一個過濾（`.` 開頭不算，`owner.rs:41-46`；`member.rs:331-345`）。不然 store 的暫存檔 `.<name>.tmp-…`（`store.rs:20`、`:118`）會讓閘門以為「有檔」。啟動時有 `store_sweep`（`simple.rs:61`），所以很少發生，但規則要寫。
- §7 步驟 5 的改壞清單沒有閘門本身：閘門改用摘要表、不在佔用下重新列檔；列檔丟例外仍建立；只有 mnet 仍建立。這三種改壞都沒有測試會抓到。

**修法**：寫一張閘門表，每一列各有測試與突變。
- 沒有任何檔 → 建立。4.1 是加入表單時 → 不開始，請使用者重開 4.1。
- 有 net → 加入。4.1 選的目標仍存在、打得開、已套用，否則不開始。
- 只有 mnet 或 mpend → 不開始，顯示隊員的句子。
- 列檔例外 → 不開始。

4.1 在摘要表是「計算中 / 列不出來」時，先等它算完（或顯示「正在讀取網路紀錄」），不給表單。

---

## MINOR

1. **`LoginResult` 少了 `precondition`。** `core.dart:640` 的 `LoginEnd` 是 ok / identity / refused / notFound / precondition，沒有 `keys`。藍牙關、權限、金鑰都經 `setRadio` 結束成 `precondition`（`core.dart:282-291`），要帶 `core.blocked` 的 `Why`。另外三件事也要寫：
   - `loginFor` 要自己用 `lease.token` 掃描（`ble_gate.dart:185`，受每 30 s 4 次限制），交接前停掉掃描；不停的話，下一台的 `scan` 會被拒（「a scan is already running」）。
   - `HandoffProber` 要接 `keyError → keyErrorToRadio`（`app_link.dart:69-70`、`:142-144`）。
   - 建網前即時讀 `KeyAbilities.refusal(KeyUse.makeNetwork)`（`nodes.dart:479-484`）要一起複製。
2. **請求進行中藍牙被關掉。** 連線斷掉，結果是 unclear，加入者照規則會問「繼續 / 停」，和 §2.3「前提類不問繼續」相反。任何失敗之後都先看 `core.blocked`。
3. **事實與現況有出入。**
   - P16 的 `home_page.dart:177-178` 實際是 `:170-171`。
   - §2.6「貼上 / 16 進位現況已是 dev-only 按鈕」不對：`claim.dart:500-512` 的輸入框與「貼上 QR 碼（開發用）」在每個版本都顯示，只有 `_paste` 在 field 版拒絕。設計 §5.3 要求不顯示。
   - `UiState` **沒有**設定暱稱的方法（只有解析 `ui_state.dart:95-97` 與 `forget` `:197`）。3.2 要新增寫入方法與輸入過濾，測試要涵蓋控制字元與方向字元，不只 24 / 25 字。
4. **原始碼鎖會誤判。** 鎖 `lib/ui/` 會撞到 `ui_state.dart:228`、`:232`（合法的 `storeWriteCas` / `storeRemove`）。要照設計 T-G5 排除 `UiState`（只允許常數 `ui/state-v1`）。
5. **複製清單漏了東西。**
   - `OwnerKind.wait`（`nodes.dart:292-298`，`sendUpdateFor` 需要）；
   - `_sendUnclear`；
   - `requestConfirmNetwork` 的逾時句；
   - 訊框例外。
6. **後四碼對應可以換成精確的。** `net_summary` 手上就有完整的 `device_id`（`owner.rs:116` `m.device_id`），只是沒有放進 `MemberView`。加一個欄位（Rust 改一行，加一個測試）就能精確對到 `node/<id>`，不會標錯。設計 §4.3.8 也要「入口節點 / 建立者」對到節點。B1 的「檢查網路」要找建立者，也是同一個問題，計畫沒有寫。
7. **`keepScreenOn` 與連線擁有者的說法前後不一。**
   - `keepScreenOn` 在 §2.3 是「開始到離開結果頁」，在 §3.1 是「等待開始時開，`finally` 關」，設計 §4.1 是等待頁期間。
   - 重新登入後 `OwnerConsole` 換了一個新的 `LoginHandoff`，`NetworkRun` 手上的 `h` 已經過時。改成由 `NetworkRun` 呼叫 `console.close()`。
8. **結果頁一直開著最後一台的 GATT 連線**（`h.close()` 在離開結果頁才做）。這段時間 dev2 或隊員的手機讀不到那台。建議最後一台做完就關（佔用照設計留到最後一頁）。
9. **流程中頁面消失**（§3.4，雖然有 `PopScope`）。要寫明：`NetworkRun` 做完當前請求、不開下一台、不彈對話框、關連線、放 hold。否則 hold 永遠不放，420 s 後被收回，首頁出現「上一個操作可能沒有存完」。
10. **§6「安靜的裝置吃不掉 60 s」說過頭。** 每個不回應的位址各花 8 s（`node_link.dart:75`），約 7 個就能吃光 60 s（設計接受這個代價）。照實寫。
11. **摘要表的計算與 `acquire` 的等待。**
    - 摘要表打開紀錄時遇到金鑰閘門錯誤，要不要走 X26，計畫沒有寫（v1 B-M-6 提過）。
    - `acquire` 要等的「上一個 `released`」不能包含摘要表的計算（平台呼叫不回來時，所有操作都會卡住），而且要有上限。
    - `reg.current` 的檢查要放在等待之後。
12. **§7 缺負向對照。**
    - F41 `PopScope`：拿掉 → 返回成功 → FAIL。
    - `ClaimDone`：恢復路徑或已有紀錄的覆寫路徑是否也算 `ClaimDone`，沒有定義。`openRawPage` / `openUnderLease` 的回傳型別要改（`raw_use.dart:73-82` 現在丟掉 pop 的結果）。
    - T-L17 要用一個慢的 `readRecords`，「`acquire` 不等 `released`」這個突變才會 FAIL。現有的假資料 `async => recs` 在一個 microtask 內就完成。
13. **入口表與設計不一致。**
    - 設計 §5.1 第 6 列要排除「已在待辦『加入沒有做完』裡」的節點（設計 :673），計畫沒寫。
    - 3.6 的次要按鈕是「再加一台」，不是第 6 列的「加入隊長的網路」（設計 §5.3）。§2.5 寫「同第 6 列」不準。
14. **建立者的選擇。** 預設「第一台」可能是「目前讀不到」的那台：60 s 後 notFound，整個流程停。建立者優先選剛讀到、還沒加入網路的那台。

---

## v1 審查逐條對照

| v1 | v2 處理 | 判定 |
|---|---|---|
| A-B1 / B-B1 登入 | §2.1 `loginFor` | ✅ 方向對；交接細節見 M2、m1 |
| B-B2 建立條件 | §2.3–§2.5 | ⚠️ 分支不完整（M4）；新的死路（B1） |
| A-M1 佔用 / 重入 | §3.4 | ✅ |
| A-M2 / B-M-2 搬移邊界 | 改成複製 | ✅；複製清單有缺（m5） |
| A-M3 / B-M-1 多台迴圈 | §2.3 | ✅ 結構對；停止規則依賴結果分類（M1、m2） |
| A-M4 摘要表 fail-open | §2.4 | ✅ |
| A-M5 / B-M-3 認領 | §2.6 | ✅ 縮小可接受；事實錯（m3）、對照缺（m12） |
| A-M6 入口 | §2.5 | ⚠️（M4、m13） |
| A-M7 真機 | §8 | ✅ `prov-bench-s0-254.sh unclaimed` 存在（:444-450） |
| A-M8 結果契約 | §2.2.1 | ❌ 對不上（M1） |
| B-M-4 生命週期 | §2.7、§3.3 | ⚠️（M3、m9） |
| B-M-5 負向對照 | §7 | ⚠️（M4、m12） |
| B-M-6 擁有權 | §3.1 | ✅（m7） |
| B-m-8 `Refused` / `NoLease` | `leaseLost` | ❌ 對應錯（M1） |

---

## 事實核對（§1、§5）

| # | 判定 | 證據 |
|---|---|---|
| P1 | ✅ | `nodes.dart:194` `_tryLogin`、`:365` `_login`、`:431` / `:438` / `:494` / `:511-589`、`:687` `_watchLink`、`:750-797`、`:1590` `_askSw` |
| P2 | ✅ | `:157-160`、`:277`、`:405`、`:520`、`:614` |
| P3 | ✅ | `nodes.dart:261`、`:467`、`:764`、`:1026`、`:1290`；`claim_records.dart:43-53` |
| P4 | ✅ | `raw_use.dart:25-44`；`nodes.dart:520-529` |
| P5 | ✅ | `ble_gate.dart:185`、`:226-231` |
| P6 | ✅ | `record_writer.dart`（`writeCas` 吃已封好的位元組；封裝要經平台的 `seal`，計畫沒寫注入，見 M1） |
| P7 | ✅ | `core.dart:628-748`；`n9Login = 10000`（`:20`），設計寫 30 s，程式是 10 s |
| P8 | ✅ | `lease.dart:72-84` |
| P9 | ✅ | `claim.dart:154-157`；`raw_use.dart:57-66`、`:73-82` |
| P10 | ✅ | `git log`：9b00ca6 |
| P11 | ✅ | `join2flow.rs:341` |
| P12 | ✅ | `owner.rs:41-47` |
| P13 | ✅ | `node_link.dart:171-195`；`core.dart:703-705` |
| P14 | ✅；不完整 | `MemberView` 另有 `dac_hash`；`net_summary` 有 `device_id` 但沒交出來（m6） |
| P15 | ✅ | `owner.rs:1214-1215` |
| P16 | ⚠️ 行號偏 | `home_logic.dart:92-96` ✅；`home_page.dart` 的開舊控制台在 `:170-171` |
| A1 | ⚠️ | T-L17 用現有假資料做得到（`node_link_test.dart:78` `FakeProber` 依位址回答，`Clock` 手動推時間）。但 `NodeLink` 要多注入一個交接用的 prober（現在只有 `Prober`，`node_link.dart:17-19`），而且要用慢的 `readRecords`（m12） |
| A2 | ❌ | M2 |
| A3 | ⚠️ | 照計畫，真機確認 |
| A4 | ✅ | `lease.dart:72-84`：只有 `pageGone` 會排上限 |
| A5 | ⚠️ 大致成立 | `join2flow.rs` 的寫入都經 `self.entry()`（這台自己的成員項，`:362` `device_id` 來自驗證過的 cert、`:386`、`:456`、`:530`）；沒有逐行讀完 |

---

## 指定要查的問題

- **`acquire` 等 `released` 會不會擋到 NodeLink 自己的一輪，或和 `RawLeaseScope` 死結？**
  - 不會擋到一輪：等待期間 `core.lease` 仍是 true（上一個 `acquireLease` 設的，`releaseLease` 還沒呼叫），`_begin` 不會開始一輪。
  - 不會死結：`RawLeaseScope.dispose` 只呼叫 `pageGone`，不等 `acquire`。
  - 風險在無限等待（m11）。這個機制在 UI 上幾乎碰不到：中間隔了 3.2 取名頁，readRecords 早就讀完。主要是為了讓 T-L17 成立。
- **`ConsoleResult` 有沒有涵蓋 `_ask` 的每一種結束？** 沒有（M1）。
- **4.1 的規則用的資料 app 有沒有？** 有（`StatusView.nodeState`、`netId`），但規則本身錯（M3）。
- **§2.5 和 `home_logic` / 設計 §5.1 一致嗎？** 大致一致；差異見 M4、m13。
- **只用後四碼對應會不會標錯？** 計畫有避開重複的情況，所以不會標錯；但遇到後四碼是空的或重複時，待辦就不見了。有精確解（m6）。
- **T-L17 端到端做得到嗎？** 做得到（A1 列）。

## 安全（逐 actor）

- **遠端 BLE / 惡意廣播**：照 `LoginFor` 的 8 s 與「不是 Y」備忘；能吃掉預算，但會被記住（m10）。
- **被入侵的節點**：
  - 只能改共用 net 紀錄裡自己的成員項（A5 ⚠️ 大致成立）；
  - 能叫 app 發出國家、加回兩種問題（都要使用者同意）；
  - 能用 `sendUpdate` 觸發 `sendUpdateFor`，把網路密碼送給它，但它已經是成員，沒有新的暴露；
  - 能拖時間，但每一步都有上限（360 s / 120 s）。
- **本機無權限 app**：沒有新的匯出元件或平台方法（⚠️ 沒有對 manifest 驗證）。
- **我們自己的錯**：B1（fail-closed 做過頭變成死路）、M1（`Refused` 被當成致命）、M2（訊框被丟或交錯）。
- **秘密**：
  - Rust 的句子明寫不含秘密（`owner.rs:432-434`）；
  - `OwnerConsole` 的技術資訊會帶例外原文（含 net id 十六進位，不是秘密）；
  - 紀錄明文只經 `seal`，不進 log。
- **TOCTOU**：在佔用下重新列檔，而且寫入都要佔用（`UiState` 例外，只寫 `ui/`），所以摘要表、閘門、寫入之間沒有可利用的空窗 ✅。

## 我做了什麼

### ✅ 已驗證（原始輸出節錄）

- `git diff 29b0085 HEAD --stat` → 只有 `app/test/nodes_update_send_test.dart | 115 +++` 與三份文件。
- 建立失敗後紀錄留著：`owner.rs:1514-1516` `"[REQ_FAIL] 建立網路沒有成功：節點說要求格式不對（App 的問題，請回報），下次會用新的網路編號"`；`:1451-1458` `J::PersistNet(rec) => … persist_step(&r.base.net_id, …, 0)`。
- `ble_gate.dart:84-86`：`if (!_open || _down || !gate.reg.valid(token)) throw Refused('$what on a closed link or a revoked token');`
- `prober.dart:133-134`：`sub = link.subscribe(Char.tx).listen((f) { if (result.isCompleted) return;`；`:160-175` 的 `finally` 呼叫 `sub?.cancel()`、`s?.dispose()`。
- `nodes.dart:340-343`：`inbox.stream.asyncMap((f) => run(s.onFrame(frame: f)))`。
- `nodes.dart:265-271`：persist 的 catch → `'${e.runtimeType}'` → `s.persistFailed(error: why)`。
- `grep store* lib/ui lib/src`（不含產生檔）→ `lib/ui/ui_state.dart:228`、`:232`；`lib/src/nodelink/app_link.dart:100-103`。
- `UiState` 沒有暱稱 setter：`grep nick lib/ui/ui_state.dart` 只命中解析、序列化與 `forget`。
- `claim.dart:500-512`：輸入框「開發用：QR 碼內容（16 進位）」與「貼上 QR 碼（開發用）」沒有 devTrust 條件。
- `core.dart:640` `enum LoginEnd { ok, identity, refused, notFound, precondition }`。
- `owner.rs:116`：`last4: m.device_id.as_deref().map(...)`，完整 id 在 Rust 手上。
- `prov-bench-s0-254.sh:444-450`：unclaimed 模式存在。

### ⚠️ 推論（沒有實跑）

- B1 的死路：由程式路徑推得，沒有在假節點上跑過。
- M2 的「訊框並行時同一個 session 被交錯呼叫」會造成錯誤：FRB opaque 的鎖行為沒有查。
- A5：只讀了 grep 命中的那幾行。
- 本機無權限 app：沒有讀 AndroidManifest。

### ❌ 沒做

- 沒有跑 `flutter test`、`cargo test`（只讀；跑會寫 `.dart_tool` / `target`）。
- 沒有真機。
- 設計文件只讀了與本計畫相關的段落（§4.1、§4.3.8–4.3.9、§4.4、§5.1、§5.3、§5.4、§9 的測項列）。
