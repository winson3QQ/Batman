# 審查 J（第二輪）：`docs/design/329-ble-settle.md` v2（連線失敗即結束嘗試 + 失敗狀態碼進 log）

審查者 J，唯讀，整份重審。對照：`app/lib/src/nodelink/{node_link,ble_gate,ble_backend,core}.dart`、舊頁 `claim.dart` / `claim_recovery.dart` / `nodes.dart` / `scan.dart`、測試假 backend、plugin 原始碼（reactive_ble_mobile 5.6.0 Kotlin + Dart、flutter_reactive_ble 5.6.0）、原始證據 `b2/ab/r1_a0.app`、`r1_a0.bt`、`b2/ab.sh`、`b2/ab.out`。

**Verdict：APPROVE-WITH-CHANGES。** 方向對：改動小，失敗的嘗試只會變短，和舊頁的行為一致，也不再依賴一個沒有證據的原因。開放項目有 1 個 MAJOR（真機驗收在「沒有失敗」時會空過）和幾個 MINOR，都只要改文字或測試，不必重新設計。

---

## 證據覆核

✅ `r1_a0.app` / `.bt`：同一場次重新整理 15 次（只有 settle=0 這一組；`ab.out` 只有一行，A/B 腳本只跑了第一個 block）。

| connect（app `settle=0 since=`） | Android | app 結束 |
|---|---|---|
| 07:54:00.706 since=18571 | 07:54:00.720 `Creating le direct connection` → 07:54:03.597 `status=133`（**2.9 s，沒有 `on_create_connection_timeout` / `hci_status` 行**，`.bt` 的 grep 有收這兩種，所以確實沒出現） | 07:54:08.708 `noResponse after 8002ms` |
| 07:55:31.021 since=19868 | 07:55:31.032 → 07:55:36.033 `on_create_connection_timeout` → `hci_status:Connection Accept Timeout` → 133（5.0 s） | 07:55:39.024 `after 8003ms` |

- 其餘 13 次都成功，`since` 是 4.5–21 s，失敗的兩次就落在這個範圍裡。✅「失敗不需要剛斷線」成立。
- ⚠️ B 組只有一台節點、沒有換台，也沒有 since < 4 s 的樣本，所以它**沒有**測到 v1 那一類情況（≤ 12 ms 內換台；f22 是 2/6）。§0 寫「直接推翻假設」說過頭了，應改成「失敗在沒有剛斷線時也會發生；換台後立刻連有沒有貢獻，沒有測，v2 不處理」。
- ⚠️ 兩次失敗的樣子不一樣：一次 2.9 s、沒有逾時行；一次 5.0 s、有 Connection Accept Timeout。§1 A 把它們寫成同一種了。Android 兩次回報都是 `status=133`，所以單靠 `fail=133` 分不出這兩類。v2 之後 attempt 行的 `after` 會等於「失敗發生的時間」，這個數字才是分得出來的欄位。建議 §2.2 寫明：attempt 行同時看 `fail=` 和 `after`。
- ⚠️ §1 B 表的 04 provd 時間不在 `ab/` 的檔裡，無法覆核。請把節點 log 存到 `ab/`。
- `r1_a0.app` 第 1、3 行來自另一個 process（pid 22497，`round 3 cancelled`、`…6D×…7c31`），是同一支手機上的另一個 app 實例在 07:53:23 被取消。之後沒再出現，不影響結論，但 §1 B 應註明「另一個 app 實例在開始時已停止」。

## 對照 plugin 原始碼的假設（§5）

1. **失敗事件會不會送到連線串流**：✅ 會，而且送兩次。
   - `DeviceConnector.kt` `establishConnection` 的 `doOnNext` 會呼叫 `updateListeners(ConnectionUpdateError(...))`。
   - `ReactiveBleClient.kt:104-130` `connectToDevice` 的 subscribe 會再送一次 `ConnectionUpdateError`。
   - 兩次都由 `ProtobufMessageConverter.convertConnectionErrorToDeviceInfo` 轉成 `DISCONNECTED` 帶 `failure`。
   - Dart 端 `device_connector.dart:57-64` 在第一個 disconnected 之後用 `takeWhile` 結束串流。
   - 所以 app 收到的「第一個 false」帶 failure，接著串流結束（`ReactiveBackend` 的 `onDone` → `_on(false)`）。
   - 實作要用第一個帶 failure 的事件；第二個 failure、以及之後 `connectionStatusUpdates.startWith(DISCONNECTED)` 送的那筆無 failure 事件都要忽略。
2. **連上之前會不會先送一個非 connected 的事件**：
   - 本次連線自己的事件，依序只有 `CONNECTING`（`establishConnection` 一開始就送）→ `CONNECTED` 或 failure。`CONNECTING` 被 `ble_backend.dart:28-30` 的 `where` 濾掉。
   - **但上一條連線合成的 `DISCONNECTED` 可能晚到**，而且晚到時新連線的串流已經在聽了：
     - `PluginController.kt:116-123` 和 `:149-156` 都是先 `result.success(null)`，才去做 connect 或 disconnect。
     - `DeviceConnectionHandler.listenToConnectionChanges` 用 `observeOn(mainThread)` 投遞事件。
     - 所以 Dart 依序收到：connect 的回覆（`asyncExpand` 在這時開始聽本 id）→ 上一條的合成 `DISCONNECTED`（無 failure，同一個 id）→ `CONNECTING` → …
   - 會碰到的條件：**同一個位址**，上一條是失敗的連結，然後立刻重連。失敗的連結在 `close()` 時已經是 `_down`，所以不會等 `_gone`（`ble_gate.dart:112`），close 立刻回來。
   - 目前 NodeLink 碰不到：`core.dart:430`、`:694` 讓同一個位址在結果之後 `gap` = 6 s 內不能再試；B 組失敗後重連就是 6.0 s 後。
   - 這個依賴必須寫進設計，見 m-1。
3. **舊頁本來就是「第一個 disconnected 就結束」**：`claim.dart:260-265`、`claim_recovery.dart:98-103`、`nodes.dart:197-205` 都是收到 `disconnected` 就 `complete(false)`。v2 只是讓 NodeLink 跟它們一致，這算有現場使用的先例 ✅。這些頁面不經 gate，不在本設計範圍。PR 6 刪掉它們之前，它們也有 m-1 那個晚到事件的問題，原本就存在。

## 介面、擁有權與呼叫點

- 等「連上」的地方只有兩處：`node_link.dart:379`（`_lfAttempt`，流程登入）和 `:556`（`_run`，自動讀取）。整個 `lib/` 裡 `firstWhere` 只出現在這兩處。
- `owner_console.dart:179` 在 handoff 之後聽 `link.state`，那時已經連上，不受影響。
- 舊頁見上一節。
- **§2.1 寫的 `LinkSession` 不存在**：`lib/` 和 `test/` 都搜不到。應改成上面兩個行號（m-3）。
- `GateLink.failure` 由 backend 的 connect 串流寫、NodeLink trace 讀，這部分清楚。但 `BleBackend.connect` 現在回 `Stream<bool>`（`ble_gate.dart:15`），設計沒寫新型別：是 `Stream<(bool, int?)>`，還是另一個回呼。請明寫，並列出要跟著改的 4 個假 backend：`test/nodelink/{ble_gate,node_link,handoff}_test.dart`、`test/flows/owner_console_test.dart`（m-4）。
- 失敗碼只從 connect 串流擷取，不從 `linkStates`（全域 `connectedDeviceStream`）擷取。後者會收到舊頁的連線事件，混進來會重複或張冠李戴。請明寫。

## 對 core 排程的影響（逐項查）

- **下一次嘗試提早**：失敗結果早 3–5 s 送到 `core.result` → 同位址的 `freeAt = now + gap`（`core.dart:430`）跟著提早。一輪內可以多試，`perAddr = 2` 的「是 Y 位址一輪兩次沒回應就丟備忘」（`core.dart:473-477`）會更快達到。語意不變，只是時間軸變短。
- **掃描次數（A10）**：一輪只有一次掃描，嘗試不會啟動掃描，所以不受影響。✅
- **90 s 上限 / 30 s 窗口**：上限不變；輪可能更早結束（`core.dart:511`）。都只會變短。✅
- **R-3 / R-7 / §4.3.7**：都是上限，8 s 的路徑還在（一直沒有任何事件時），所以不用重算。✅ 同意 §4。
- **新出現的路徑：藍牙在連線中被關掉。**
  - 今天：attempt 一直等到 `setRadio(bluetooth:false)` → `_cancel` → `_abort`。`_attempt` 已經清掉，所以結果被丟棄（`node_link.dart:577`）。
  - v2 之後：plugin 的 failure（adapter off）可能**比藍牙狀態串流先到**，那次嘗試會以 noResponse 記進 core。如果這是那個位址這一輪第二次 noResponse，「是 Y」備忘會被丟（`core.dart:474-477`）。等藍牙打開後，就要重新認一次節點，可能多試幾個別人的位址。
  - 不會寫錯任何東西，但 §6 少了這一行，見 m-2。

## 安全（逐 actor）

- **範圍內廣播服務 UUID 的攻擊者**：它能讓手機失敗的時間只會變短，失敗碼也是本機協定堆疊產生的整數，不受遠端控制。✅
- **本機其他 app**：只能透過同一個藍牙協定堆疊間接影響失敗碼，log 只多一個數字。✅
- **被攻陷的節點**：連上之後的行為不變。✅
- **log 內容**：RxAndroidBle 的訊息含 `MAC='…'`，只擷取 `status (\d{1,3})` 是對的。plugin 自己的逾時訊息是 `"Unknown error"`，`"Device is not in queue"` 也沒有狀態碼，這兩種都應記 `fail=?`。另外，舊頁 `scan.dart:96` 會記 `id=${d.id} … failure=${u.failure}`，含完整位址和錯誤訊息全文。這是既有問題，不在本設計範圍，PR 6 刪除時一起消失；建議在 §7 記一行。

---

## MAJOR

**M-1 真機驗收在沒有失敗時會空過，負向對照也沒有寫成「必須看到失敗」。**
- 情境：§8 的判準是「失敗的嘗試 `after` ≤ 6 s」。B 組的失敗率是 2/15 ≈ 13%，跑 20 次一次都沒失敗的機率約 0.87^20 ≈ 6%。這時判準在沒有樣本的情況下「通過」。依使用者規則，找不到東西可以檢查的測試必須 FAIL。
- 修：判準改成「持續重新整理，直到收集到 ≥ 3 次 Android `status=133`（`.bt` 為準）。每一次的 app attempt 都要在 133 之後 ≤ 500 ms 結束，`fail=` 和 Android status 一致。收集不到 3 次就判 ❓，不能判通過」。負向對照：現有的 `r1_a0`（今天 8.0 s，兩次）就是 before，寫進 §8。

## MINOR

- **m-1 只在帶 failure 的事件上提早結束，或明寫依賴 `gap`。** 建議實作規則是「連上之前收到帶 failure 的 disconnected → 結束」。無 failure 的 disconnected 照今天處理：串流結束，等到 8 s 或 close。這樣上一條連線晚到的合成 `DISCONNECTED` 永遠不會讓新嘗試誤判失敗，也不用依賴 `core` 的 6 s `gap`。若仍要用「第一個 false」，§5 要寫明這個依賴（`core.dart:430`、`:694`），並加一個單元測試：同一位址在 close 之後 0 ms 重連、假 backend 先送一個無 failure 的 false → 不得以失敗結束。§6「plugin 先送 disconnected 再 connecting」那一行應改成這個具體情境，不要寫「若會發生」，因為從原始碼看是會發生的。
- **m-2 §6 加「藍牙在連線中被關」**：單元測試讓假 backend 先送 failure，再在同一個 tick 送 `radio(bluetooth:false)`，斷言「是 Y」備忘不變、不出現「連不到」。如果 FAIL，修法是「core 在 `bt` 為 false 時丟掉 noResponse 結果」，或 NodeLink 收到 failure 後先讓 status 串流處理一個 tick。
- **m-3** §2.1 的 `LinkSession` 不存在，改成 `node_link.dart:379`（`_lfAttempt`）和 `:556`（`_run`）。
- **m-4** 寫明 `BleBackend.connect` 的新型別，以及要跟著改的 4 個假 backend。log 擷取只從 connect 串流做。第二個 failure 事件要忽略。
- **m-5** §0 / §1 B 的措辭：「推翻」改成「失敗不需要剛斷線；換台後 ≤ 12 ms 就連的效果沒測、不處理」。§1 A 把兩種 133 分開寫（2.9 s 沒有逾時行 / 5.0 s 有 Connection Accept Timeout）。04 的 provd log 存檔到 `ab/`。
- **m-6** 單元測試要涵蓋三種訊息：`status 133` → `fail=133`；`"Unknown error"`、`"Device is not in queue"` → `fail=?`。斷言 log 裡沒有 `[0-9A-F]{2}(:[0-9A-F]{2}){5}`。負向對照：改成記錄全文 → FAIL。

## 每項修正的負向對照

| 主張 | 對照 |
|---|---|
| 失敗即結束 | 單元：假 backend 2 s 送 failure → 嘗試在 2 s 結束；改回 `firstWhere((s) => s)` → 8 s → FAIL（設計已有）。真機：`r1_a0` 的 8.0 s 是 before；after 依 M-1 |
| 不誤判（m-1） | 同一位址 0 ms 重連 + 晚到的無 failure false → 不結束；改成「任何 false 都結束」→ FAIL |
| 失敗碼 log | 見 m-6 |
| 藍牙關閉 | 見 m-2 |
