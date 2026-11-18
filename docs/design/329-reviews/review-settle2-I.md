# 審查 I（第二輪）：`docs/design/329-ble-settle.md` v2（失敗即結束 ＋ 失敗狀態碼進 log）

唯讀審查整份 v2。依據：
- app 原始碼：`test/329-retest-a` 的 c795d63。
- plugin 原始碼：`flutter_reactive_ble-5.6.0` 的 Dart、`reactive_ble_mobile-5.6.0` 的 Kotlin。
- RxAndroidBle 1.16.0：用 `javap` 反組譯 jar。
- 證據檔：`scratchpad/b2/ab/r1_a0.app`、`r1_a0.bt`。

**判定：APPROVE-WITH-CHANGES。** 兩個改動的方向都對，而且確實和原因無關。但有 3 個 MAJOR：
- 狀態碼放錯擷取點，照設計做出來真機很可能永遠記成 `?`；
- §5 的退路做下去會把這次的修正打回原形；
- 真機驗收可能什麼都沒測到，卻記成通過。

照使用者的規則，MAJOR 修完後要再審一次整份文件。

---

## 協調者問的問題：全新連線時，`connectToDevice` 會不會在 `connecting` 之前先送一個 `disconnected`？

**對一個全新的 DeviceConnector 來說，不會。**（✅ 已讀原始碼）

- `ReactiveBleClient.getConnection`（`ReactiveBleClient.kt:281-290`）會建立 `DeviceConnector`，接著存取 lazy 的 `connection`，也就是 `establishConnection`。它送出的第一個更新是 `CONNECTING`（`DeviceConnector.kt:94-97`）。
- 唯一會吐出「目前狀態」的來源是 `connectionStatusUpdates`（`DeviceConnector.kt:43-58`，`startWith(device.connectionState)`）。它是 lazy 的，只有兩個地方會碰到它：
  - 連線結果出來之後的 `doOnNext`（`:116-120`）。成功時這個值是 CONNECTED；失敗時可能是 DISCONNECTED，見 M1。
  - 關閉時的 `disposeSubscriptions`（`:89-93`）。
- Dart 端的 `connectedDeviceRawStream` 是 `receiveBroadcastStream`（`reactive_ble_mobile_platform.dart:334`），不會重播舊事件。`connect()` 要等 `connectToDevice` 的 method 回覆之後才訂閱（`device_connector.dart:66-73`）。Kotlin 端先回覆（`PluginController.kt:120`），之後才發 `CONNECTING`，經 `observeOn(mainThread)` 送出（`DeviceConnectionHandler.kt:48-51`）。

**例外：同一個位址、上一次關閉後約 200 ms 內再連，會收到過期的 `disconnected`。** 有兩個來源：
- (a) 上一個 connector 的合成 DISCONNECTED。如果它距離「建立或失敗」不到 200 ms，會被計時器延後最多 200 ms 才送出（`DeviceConnector.kt:63-75`）。失敗時 `timestampEstablishConnection` 也會被設定（`:117-118`），所以 v2「失敗馬上結束 → 馬上 close」**正好**會走進這條延後的路。可是 connector 已經從 `activeConnections` 移除了（`ReactiveBleClient.kt:136-138`）。
- (b) 一條從沒連上的連結被取消時，`disposeSubscriptions` 會順便初始化 `connectionStatusUpdates`，多吐出一個目前狀態。

我們的排程擋掉了大部分這種情形：
- 同一位址間隔 6 s。一輪是 `core.dart:430`；`loginFor` 是 `core.dart:694`，但這個 6 s 是記在每個 LoginFor 物件自己身上（`:650`）。
- 會發生的唯一路徑：一輪裡對 X 失敗 → 使用者在 200 ms 內按下操作 → `loginFor` 掃到 X 又馬上連。發生時結果是 `noResponse`，6 s 後重試。今天同樣是 `noResponse`，只是要等 8 s。所以**不會變差**。
- 另外，Dart 的 `connect()` 在第一個 `disconnected` 就結束（`device_connector.dart:57-64`，`expand` 加 `takeWhile`）。所以 connect 串流上**不可能出現「先 false 再 true」**。

---

## MAJOR

### M1. 狀態碼從 connect 串流拿，真機上很可能永遠拿不到
**證據**（✅ 原始碼）：失敗時 plugin 依序送出：
1. `doOnNext` 一碰 `connectionStatusUpdates`，就送出 `ConnectionUpdateSuccess(device.connectionState)`（`DeviceConnector.kt:117` → `:43-58`）。
2. 接著才送 `ConnectionUpdateError(errorMessage)`（`:121-123`）。
3. `ReactiveBleClient.connectToDevice` 的 subscribe 會**再送一次** `ConnectionUpdateError`（`ReactiveBleClient.kt:115-121`）。

如果第 1 步的狀態是 DISCONNECTED（不帶 failure），Dart `connect()` 會在這一筆結束（`takeWhile`）。帶 failure 的那兩筆**只會出現在全域的 `connectedDeviceStream`**，不會出現在 `connectToDevice` 串流上。

第 1 步是哪個值，原始碼定不下來。`javap` 看到 `RxBleGattCallback$2.onConnectionStateChange` 先呼叫 `disconnectionRouter.onDisconnectedException`，之後才 `connectionStatePublishRelay.accept`。這暗示失敗傳上去時狀態可能還沒變成 DISCONNECTED。但 device 層的 relay 和 scheduler 我沒有逐一查證。⚠️

如果照 §8 用假 backend 在 connect 串流上送 failure，單元測試會綠，真機卻全部 `fail=?`。這就是使用者記錄過的「stub 格式不照真東西」那種錯。

**修正**：
- failure 從 `BleGate` 已經在聽的全域串流取（`ble_gate.dart:142-149`，`backend.linkStates`）。條件是位址相同、時間在這條 GateLink 的 connect 和 close 之間；`linkStates` 要把 failure 帶出來，不要只回 `(String, bool)`。
- 或者兩邊都收，取第一個帶狀態碼的。
- 假 backend 要照上面 1–3 的真實順序和格式送事件。
- 真機驗收：logcat 的 `status=133` 要對上 trace 的 `fail=133`（見 M3）。

### M2. §5 第 3 列的退路和 §6 第 3 列的測試是錯的，做下去會讓修正失效
**情境**：設計說，如果 plugin 會先送 disconnected，就「只取 connecting 之後的事件」。
**證據**：
- `connecting` 現在被 backend 濾掉了（`ble_backend.dart:28-30`）。要採用這個退路，就得把它放行。
- `CONNECTING` 和 method 回覆走的是不同的 channel：回覆在 `PluginController.kt:120`，事件經 `observeOn(main)` 送出（`DeviceConnectionHandler.kt:50`）。Dart 要等回覆之後才訂閱（`device_connector.dart:66-73`）。
- 跨 channel 的先後順序沒有保證。只要漏掉一次 `CONNECTING`，真的失敗就會被忽略，又變回等滿 8 s，等於把這次修正打回原形。
- 「先 false 再 true → 不提早結束」這個測試，測的是 plugin 不可能產生的序列（見上面的 `takeWhile`）。它會把錯誤的期待寫進測試。

**修正**：刪掉這個退路和這個測試。改成：「同一位址 200 ms 內收到過期的 false → 這次嘗試以 `noResponse` 結束（和今天的結果相同），6 s 後重試那個位址」。在 §5 寫明上面的原始碼證據。

### M3. 真機驗收可能什麼都沒測到，卻記成通過
**證據**：
- `ab/r1_a0`：15 次連線中失敗 2 次，約 13%。f22：基線 5 / 約 33。
- 照 §8「≥ 20 次」，有相當的機率 0 或 1 次失敗。這樣「失敗的嘗試 after ≤ 6 s」和「fail 碼一致」都是空集合。
- 使用者規則：找不到可以檢查的東西就是 FAIL，不是通過。

**修正**：
- 判準改成「跑到**至少 3 次自然失敗**為止」，最好兩種都有：2.9 s 就 133 的，和 5 s Connection Accept Timeout 的。每一次都要對上：
  - trace 的 `after` 在 Android 133 時間 + 0.5 s 內；
  - `fail=` 等於 logcat 的 `status=`。
- 跑到上限仍不到 3 次，報 ❓ 並列出跑了幾次，不寫通過。
- 負向對照：同一支手機、同一場次，用改回 `firstWhere` 的 build 跑一次，記到 8.0 s（`r1_a0.app` 第 13、31 行就是現成的基線）。

---

## MINOR

- **m1 藍牙關閉時的競態（生命週期少一列）**：
  - v2 之後，關藍牙時進行中的嘗試會**立刻**以 `noResponse` 結束。這可能發生在藍牙狀態傳到 `core.setRadio` 之前（`core.dart:280-296`）。`_pump` 可能接著對另一個位址立刻再試，也立刻失敗。
  - 我讀程式的結論是不會留下永久的紀錄變化：
    - 刪「是 Y」要同一輪、同一位址 2 次，而且中間要隔 6 s（`core.dart:473-477`）；
    - `exhausted` 和 `noResp` 只屬於這一輪，`setRadio` 時 `_cancel` 會一起丟掉；
    - `loginFor` 的 `silent` 也要隔 6 s。
  - ⚠️ 這是推論。建議補一列和一個單元測試：連線中藍牙關 → 這一輪被取消、不算「沒找到」、「是 Y」不變。R-4 照原樣重跑。
- **m2 介面其實變了**：`BleBackend.connect` 的回傳是 `Stream<bool>`（`ble_gate.dart:16`），要帶 failure 就要改介面，或照 M1 改 `linkStates`。所有假 backend 都要跟著改（`ble_gate_test`、`node_link_test`、`prober_test`、`handoff_test`、`app_link_console_test` 等）。§3 說「契約不變」不準確，請列出來。`GateLink.failure` 的擁有權（只由 gate 寫、只由 NodeLink trace 讀）OK。
- **m3 行號和名稱**：
  - 實際要改的只有兩處：`node_link.dart:556`（`_run`）和 `:379`（`_lfAttempt`）。設計寫的是 555-559 和 :397，:397 是 close。
  - `LinkSession` 這個類別不存在（grep 不到）。
  - `owner_console.dart:179` 是登入之後才聽 `state`，不受影響。請寫明。
  - 改的時候不要用 `link.state.first`。`GateLink._state` 被 close 時會丟 `StateError`，雖然會被 `catch` 收成 `noResponse`，但 trace 會多一行例外。
- **m4 §1 B 的證據**：
  - `ab/` 裡沒有 04 的 provd log，表格的「04 provd」那一欄無法查證。請附檔。
  - `r1_a0.app` 第 1、3 行有**另一個程序**（pid 22497，`…7c31`，`round 3 cancelled`）在 07:53:23 還有 BLE 活動。請說明它之後有沒有停（例如進背景），因為同一個控制器被兩個 app 共用是可能的干擾。
  - 「失敗在斷線 18–20 s 之後」✅ 已核對：`since=18571` 對應 07:54:03.597 的 133；`since=19868` 對應 07:55:36.040。這推翻了 v1 的假設，同意。
- **m5 說清楚這次修好什麼、沒修好什麼**：v2 不會讓失敗變少（約 10–15% 的連線仍會失敗），只是每次失敗少等 3–5 s，冷啟動最慢的那幾次會短一些。根本原因（btsnoop、對方沒收到連線請求）照規則要寫成 #329 的清單項目，不能只寫「不在本設計」。PR 也要照這樣寫。
- **m6 失敗的 connector 不會卡住** ✅：`r1_a0.bt` 中 07:54:03.597 對 `40ED78_C` 133 之後，07:54:14.725 又真的發出 `Creating le direct connection`，而且成功。所以失敗後 plugin 有把 connector 移除。v2 只是比較早 close，路徑相同。建議在 §5 引用這一點。
- **m7 安全**：同意 §7。
  - regex 寫成 `with status (\d{1,3})\b`。這是 RxAndroidBle 的格式，jar 字串是 `with status `；訊息裡含 MAC，不記全文。
  - 範圍內的攻擊者讓連線失敗，現在花的時間更短，放大效果變小。
  - 如果 stack 卡在「每次立刻失敗」，嘗試頻率會變高，但受「每個位址每輪 2 次、間隔 6 s」限制（`core.dart:430`）。這個上界請寫出來。
  - 狀態碼只進 log，不能拿來做任何判斷（`core.dart` driver contract：驗證憑證之前都是 `noResponse`）。請寫明。

## 時間常數
同意「只會變短」：失敗的嘗試從 8 s 變成 0.4–5 s。每個位址每輪的次數、6 s 間隔、一輪 30 s / 90 s、R-3、R-7 都是上限，不用重算。唯一行為上的差別是 m1 的競態。

## 負向對照
- 失敗即結束：
  - 單元：假 backend 依真實順序送出事件（M1），嘗試在 false 時結束；改回 `firstWhere` → 8 s → FAIL。
  - 真機：見 M3。
- 狀態碼：
  - 單元：假 backend 照真實順序和格式送事件 → `fail=133`；只看 connect 串流的實作 → `fail=?` → FAIL。
  - 真機：至少 3 次自然失敗，`fail=` 都等於 logcat 的 `status=`。
- 過期的 false：單元測試，同一位址 200 ms 內 → `noResponse`、6 s 後重試。

## 驗證分類
- ✅ 原始碼或檔案：上面的 plugin 事件順序、`takeWhile`、200 ms 延後、6 s 間隔、`firstWhere` 的兩處、`ab` 的 since 和 133 時間、失敗後同位址重連成功。
- ⚠️ 推論：M1 中第 1 步的狀態值（需要真機）、m1 不會改變紀錄、跨 channel 的先後順序。
- ❌ 沒做：沒跑測試、沒上機。
