# 審查 I（第四輪）：設計 `329-ble-settle.md`（整份）＋ 實作 commit `a36c383`

唯讀。我在臨時 worktree `C:/src/Batman-329ra-rI`（detached 在 a36c383）跑測試和負向對照，跑完已經 `git worktree remove`。

**判定：APPROVE-WITH-CHANGES。** 有 1 個 MAJOR，是測試缺口，補一個測試就好，不用改設計。另有 5 個 MINOR。
- 主要修正（`_run`）的程式和設計一致，負向對照我重跑過，成立。
- 失敗碼 log 的測試**確實**把帶碼的事件放在另一個 event-loop task，而且晚於 close 才送到。負向對照成立。
- 缺的是：`loginFor`（`_lfAttempt`）這半邊沒有任何測試。我把它改回 `firstWhere`，**全套 1709 個測試照樣全過**。

---

## 上一輪的問題逐項核對

| v3 的問題 | 現在 | 結果 |
|---|---|---|
| N1：trace 在 close 前寫，晚到的碼漏掉 | gate 在 `_states` 收到帶碼的事件就自己記一行，不管連結還在不在表上（`ble_gate.dart` 約 141-148 行） | ✅ 程式和測試都核對了，負向對照也重跑了（下面 c） |
| n1：藍牙關閉那一列寫成條件式 | 定案：不加撤回機制；有測試 | ✅ 測試 5 用 `run(2001)` 讓失敗先記進 core 才關藍牙，真的有走到競態那條路；斷言 2.3、開回後讀得到 |
| n2：根本原因沒寫進 #329 清單 | #329 內文第 194 行有了，留言 6964891622 也有 | ✅ 用 `gh` 讀到原文 |
| n3：假 backend 名單少兩個 | 6 個檔都改了 | ✅ |
| n4：pid 22497 的說法沒有佐證 | 改成「本檔（到 07:57:49）期間沒有它的其他行」 | ✅ |
| n5：§1 A 失敗的形狀寫錯 | 改成 0.4–2.9 s 和 5.0 s 兩種 | ✅ |
| n6：同位址快速重連那一列的測試沒寫清楚時間軸 | 設計已經寫清楚 | ⚠️ **但沒有實作這個測試**，見 m1 |

## 程式和設計對照

- `node_link.dart:380`（`_lfAttempt`）和 `:557`（`_run`）改成 `state.first.then((s) => s, onError: (_) => false)`，符合 §2.1。連結被 close 或撤回時 `_state` 關閉，`first` 會丟錯，這裡收成 false，結果是 `noResponse`。✅
- `ReactiveBackend.linkStates`：`up` 時第三欄是 null；`up == false` 時由 `failureCode(u.failure?.message)` 決定：
  - 沒有 failure → null；
  - 有 failure 但訊息裡沒有數字 → -1，記成 `?`；
  - 抓到數字 → 那個數字。

  regex 是 `with status (\d{1,3})\b`。符合 §2.2 和 §3。✅
- gate 記的那一行是 `link …XX down fail=N`，只有位址末 2 碼和數字，不記訊息全文。失敗碼不參與任何判斷。✅
- AppLink 的 trace 接到 `debugPrint('BMAPP gate …')`。✅

## 我重跑的測試和負向對照（✅ 都有原始輸出）

| 情況 | 結果 |
|---|---|
| 基線：`connect_fail_test.dart` | `+6: All tests passed!` |
| a. `_run` 改回 `firstWhere((s) => s)` | `§2.1 … [E] Expected: be in range from 1900 (inclusive) to 2500 (inclusive) Actual: <8000>` → **FAIL**。commit 說的負向對照成立 |
| b. **`_lfAttempt` 改回 `firstWhere`**（`:380`），跑全套 `flutter test test/` | `01:09 +1709: All tests passed!` → **沒有任何測試抓到** → M1 |
| c. gate 只在連結還在表上時才記（`f != null && _links.any(...)`） | 兩個 log 測試都 `[E]`，`+4 -2` → 證明帶碼的事件確實在 close 之後才到。commit 說的負向對照成立 |
| d. gate 多記一行完整位址 | 「never the full address」那個斷言 `[E]` → 抓得到 |

**測試真的有照 plugin 的事件順序嗎？** ✅ 有。
- `FailRadio` 在同一個 task 裡先送 connect 串流的 false，再送不帶碼的 `(addr,false,null)`。
- 兩筆帶碼的事件各用一個 `Timer(Duration.zero)` 送，所以是後面的 event-loop task。這對應 plugin 的另一則 platform 訊息，也對應 `ReactiveBleClient.kt:115-121` 的第二筆錯誤。
- `Clock.run` 每一步先觸發到期的計時器，再 `await Future.delayed(zero)` 兩次。所以 attempt 結束和 close 在 microtask 裡就完成了，帶碼的事件到的時候連結已經不在表上。負向對照 c 證明了這一點。

## MAJOR

### M1. `loginFor`（`_lfAttempt`，流程登入）的改動沒有回歸測試
**證據**：負向對照 b。`node_link.dart:380` 改回 `firstWhere` 之後，全套 1709 個測試照樣全過。設計 §2.1 有寫這一處，commit message 也寫了「`NodeLink._run` / `_lfAttempt` wait for the first link event」。可是 commit 列的負向對照只有 `_run` 的。

**影響**：每次使用者開始操作時，「正在連到節點…」都走這條路（R-7）。之後有人改回來不會被發現。使用者規則要求每個修正都有一個會在沒修時 FAIL 的測試。

**修正**：在 `connect_fail_test.dart`（或 `login_for_test.dart`）加一個 `loginFor` 的案例：
- 拿一個 session lease；
- `FailRadio.failAt[addr] = 2000`；
- 斷言第一次嘗試的 trace 是 `loginFor … result=noResponse after ≈2000ms`（目前 `:396` 的 trace 有 `after`）；
- 負向對照：`:380` 改回 `firstWhere` → 8000 → FAIL。

## MINOR

- **m1. §6 第 3 列（同位址快速重連、收到延後的不帶碼 false）沒有測試。** 設計的寫法是：「失敗並 close 之後 200 ms 內同一位址再連，backend 先送延後的不帶碼 false → noResponse、不顯示連不到、下一次 ≥ 6 s 後」。測試 4 只驗了 6 s 間隔，沒有模擬那筆延後的 false。§8 寫「§6 各列」都要有單元測試。請補上，或把這一列標成「由 core 的 6 s 間隔保證、不另測」並說明理由。
- **m2. `GateLink.failure` 沒有任何讀者。** 設計 §3 說「讀者 = 只有測試」，但 `grep '\.failure\b'` 在 lib 和 test 都只找到寫入的那一處（`ble_gate.dart:150`）。拿掉 `l.failure ??= f` 不會有任何測試失敗。請刪掉這個欄位（和 §3 那一行），或補一個斷言。
- **m3. 設計開頭的狀態還是寫「v3」，§0 也沒有 v3 → v4 的變更紀錄**（gate 自己記、`GateLink.failure` 改成只給測試讀、藍牙關閉定案、#329 已加清單）。§6 第 2 列「取第一個帶碼的」也已經不準：現在每一筆帶碼的事件都記，所以一次失敗記兩行，§2.2 也這樣寫了。請一起改。
- **m4. 真機驗收要搜對前綴。** 失敗碼的那一行是 `BMAPP gate link …`，不是 `BMAPP nl`。之前 f22 / ab 腳本用的是 `BMAPP nl (attempt|…)`，`ab` 的 build 是 `BMAPP settle`。§8 的腳本必須加上 `BMAPP gate`，否則「fail= 與 Android status 一致」那一項會**沒有樣本**，按規則要記 ❓，不能算通過。
- **m5. `ReactiveBackend` 的對應本身沒有單元測試。** `failureCode` 有測（3 種訊息加 null），但 `up ? null : failureCode(...)` 這段只靠真機驗。§8 真機那一項（≥ 3 次 133，`fail=` 要一致）可以涵蓋，請在 §8 註明「這一段只由真機驗」。

## 安全
沒有新問題。
- gate 會記所有位址的帶碼失敗，包括舊頁在 raw lease 下開的連線，但只記末 2 碼和數字。
- 錯誤訊息全文（含 MAC）從來不進 log，負向對照 d 也抓得到。
- 失敗碼不影響任何判斷。

## 驗證分類
- ✅ 有原始輸出：基線 6/6；負向對照 a、c、d 會 FAIL；b 全套 1709 全過（缺口）；#329 第 194 行和留言 6964891622；`GateLink.failure` 沒有讀者（grep）。
- ⚠️ 只讀程式的：`ReactiveBackend` 的對應（m5）。
- ❌ 沒做：沒上機；沒有重跑 `dart analyze`。
