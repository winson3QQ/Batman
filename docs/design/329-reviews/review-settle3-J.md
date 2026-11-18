# 審查 J（第三輪）：`docs/design/329-ble-settle.md` v3

唯讀，整份重審。對照的來源：
- app（c795d63）
- plugin 原始碼：`reactive_ble_mobile-5.6.0` 的 Kotlin 與 Dart、`flutter_reactive_ble-5.6.0`
- 證據檔：`ab/r1_a0.{app,bt,node}`
- I 的第二輪報告：`review-settle2-I.md`

**Verdict：APPROVE-WITH-CHANGES。**
- 「失敗就結束」（§2.1）可以實作，理由和證據都成立。
- 「失敗碼進 log」（§2.2）有 1 個 MAJOR：照 v3 的寫法，在 I-M1 描述的那種事件順序下，trace 一定記成 `fail=?`。v3 改用 `linkStates`，正是為了這種順序。修法是改一兩句設計，不必重審 §2.1。

---

## 1. 協調者問：v3 不採用我 v2 的 m-1（「只在帶 failure 的事件上結束」），理由成立嗎？

**成立。我 v2 的 m-1 是錯的，在此更正。**
- `DeviceConnector.kt:119-126` 的 `doOnNext` 先碰 lazy 的 `connectionStatusUpdates`，它會用 `startWith(device.connectionState)` 送出一筆**不帶 failure** 的 `ConnectionUpdateSuccess`；之後才 `updateListeners(ConnectionUpdateError)`。
- 如果那筆的狀態是 DISCONNECTED，Dart `connect()` 會在這一筆結束（`device_connector.dart:57-64` 的 `takeWhile`）。帶 failure 的事件永遠到不了 connect 串流。
- 照我 m-1 的規則，那次嘗試會退回等滿 8 s。
- 如果狀態是 CONNECTING 或 DISCONNECTING，會被 `ble_backend.dart` 的 `where` 濾掉，第一個 `false` 就是帶 failure 的那筆。
- 兩種情況下「第一個 `false` = 這次失敗」都成立，所以 v3「第一個事件是 false 就結束」是對的。

我擔心的「上一條的合成 DISCONNECTED 晚到」只會發生在同一位址約 200 ms 內重連。v3 §2.1 / §6 第 4 列已經寫明三件事：NodeLink 對同一位址至少間隔 6 s（`core.dart:430`、`:694`）；若真的碰到，結果是 noResponse，和今天一樣；有單元測試。✅ 可以接受。

## 2. 新的 MAJOR

**M-1（v3）：失敗碼在 attempt 結束之後才到，但 v3 只收「連結開著期間」的碼，trace 又在 close 之前寫，所以會一直記成 `fail=?`。**

情境（I-M1 的事件順序，也就是 v3 改用 `linkStates` 的理由）：
1. 原生端送出 E1 = DISCONNECTED（不帶 failure），接著 E2 = DISCONNECTED + failure，再 E3（重複一次，`ReactiveBleClient.kt:115-121`）。
   - 每一筆都經過 `observeOn(mainThread)`（`DeviceConnectionHandler.kt:48-51`）各自 post，再各自 `eventSink.success`。
   - 所以它們是**三則不同的平台訊息**，Dart 在**三個不同的 event-loop 任務**裡處理。
2. 處理 E1 的那個任務：connect 串流送出 `false` → `GateLink._on(false)` → `_run` 的 `Future.any` 完成。microtask 裡接著執行 `stopDue()` 和 `trace('attempt … connected=-1ms …')`（`node_link.dart:572-573`），然後 `await mine?.close()`。
   - `close()` 一開頭就同步設 `_open = false`（`ble_gate.dart:110-111`）。
3. E2 要到下一個任務才到。這時 trace 已經寫完、`_open` 已經是 false。依 v3 §3「只在連結開著、位址相同時寫第一次」，這個碼會被丟掉。

結果：每一次真的失敗都記成 `fail=?`。§8 的「`fail=` 與 Android status 一致」會在真機 FAIL。如果單元測試的假 backend 把 E1 和 E2 放在同一個 microtask 送，或在 `false` 之前就送 E2，單元測試會是綠的。這正是「stub 要照真實格式」那條教訓。

即使第一個被放行的事件就是 E2（CONNECTING 被濾掉的那種情況），E2 要分別經過兩條 broadcast 鏈：connect 串流（`expand`/`takeWhile`/Repeater/`where`/`map`）和 `connectedDeviceStream`（Repeater/`where`/`map`）。兩條鏈之間 microtask 的先後沒有保證。trace 可能在 gate 寫入 `failure` 之前就讀它。

修法，擇一。建議 (a)，最不依賴順序：
- (a) 失敗碼**自己記一行**。gate（或 NodeLink 收到 gate 的回呼時）在 `linkStates` 收到帶碼事件時就寫 `BMAPP nl link …7C fail=133`，只記位址末 2 碼。attempt 行照舊有 `after`，兩行用時間和位址末 2 碼對起來。§8 的判準改成「每次 Android 133 之後 ≤ 500 ms 內有 attempt 結束，也有一行 `fail=133`」。
- (b) 收碼的期間延長到 `close()` 完成為止（不是只到 `_open` 變 false 為止），trace 移到 `await close()` 之後。
  - 依據：`close()` 會 await `_sub.cancel()`，也就是 `disconnectDevice` 那次 method call 的回覆（`PluginController.kt:149-156`）。在 Android 上，E2、E3 比這個回覆更早被 post 到主執行緒。⚠️ 平台到 Dart 是否保證 FIFO，要寫出證據或做真機測試。
  - 缺點：attempt 行的時間點會晚一點，而且依賴跨 channel 的順序。

不論選哪個，§6 第 2 列的單元測試都必須讓 E1、E2、E3 在**不同的 event-loop 任務**送出（例如每筆之間 `await Future<void>.delayed(Duration.zero)`），而且 E2 晚於 connect 串流的 `false`。負向對照：照 v3 現在的寫法實作，這個測試必須 FAIL（`fail=?`）。

## 3. 我 v2 的每一條，逐項核對

| v2 | v3 | 結果 |
|---|---|---|
| M-1 驗收會空過 | §8：至少 3 次自然的 133，每次 ≤ 500 ms、碼要一致；不到 3 次判 ❓；負向對照用 `r1_a0`（5.1 s / 3.0 s，✅ 我重算：07:54:03.597→08.708、07:55:36.040→39.024） | ✅ 已修。碼一致這項受新 M-1 影響 |
| m-1 只在帶 failure 時結束 | 不採用，理由見 §1 | ✅ 理由成立，我的 m-1 撤回 |
| m-2 藍牙關閉競態 | §6 新增一列和單元測試 | ⚠️ 部分。見 m-a |
| m-3 `LinkSession`、行號 | 已改成 `:556`、`:379`，`owner_console.dart:179` 寫明 | ✅ |
| m-4 介面型別、假 backend | `linkStates` 改成 `(String, bool, int?)`，寫者和讀者都寫明 | ✅。清單少了 `prober_test.dart`、`review_pr1_test.dart`（grep `linkStates` 實際 6 個測試檔），見 m-b |
| m-5 措辭、兩種 133、節點 log | §0/§1 已改，`ab/r1_a0.node` 已存 | ✅ |
| m-6 三種訊息、不含 MAC | §8 有 | ✅。缺「改成記錄全文 → FAIL」這個負向對照，見 m-c |

## 4. 證據覆核（新檔）

✅ `ab/r1_a0.node`：04 在 07:53:46 `adv registered` 之後，下一筆 `withdrawn reason=connect` 是 07:54:15；07:55:15 之後是 07:55:46。兩次失敗的期間，節點都沒有收到連線。成功的 13 次各對應一組 withdrawn → connection → registered，共 13 組。和 §1 B 一致。換算的偏移值寫在檔頭（±1 s）。

⚠️ 「另一個 pid 22497 在 07:54 之前停止、直到 08:01 沒有 attempt 行」：`r1_a0.app` 在 07:53:23 之後確實沒有它的行。但檔案只到 07:57:49，「直到 08:01」在這個檔裡無法核對。請改成「本檔期間（到 07:57:49）沒有它的行」。

## 5. 其餘 MINOR

- **m-a 藍牙關閉那一列的「若會消失，改成撤回剛記的 noResponse」：** 這是事先授權一個新機制。依「只做必要修改」的規則，應改成：依 I 讀程式的結論（刪「是 Y」要同一輪同一位址 2 次、中間隔 6 s；這一輪會被 `_cancel` 丟掉），斷言「不會消失」。若測試 FAIL，回到設計再決定，不要預先寫好修法。
- **m-b 假 backend 清單：** 補上 `test/nodelink/prober_test.dart`、`test/nodelink/review_pr1_test.dart`。實際用到 `linkStates` 的有 6 個測試檔：`owner_console_test`、`ble_gate_test`、`handoff_test`、`node_link_test`、`prober_test`、`review_pr1_test`。
- **m-c 失敗碼 log 的負向對照：** 「實作改成記錄訊息全文 → MAC 斷言 FAIL」寫進 §8。
- **m-d 實作細節（I m3）：** 等第一個事件時不要用 `link.state.first`。close 時 `_state.close()` 會讓 `first` 丟 `StateError`，trace 會多一行例外。用現在的 `firstWhere((_) => true, orElse: () => false)`。§2.1 寫一句即可。
- **m-e 碼的來源只有 `ConnectionUpdateError`：** E3 是重複的，所以「取第一個」正確。順帶寫一句：別的頁面（舊頁直接用 FlutterReactiveBle）對**同一位址**的失敗，在本連結開著時也會被收進來。單一 BLE 入口下不會同時發生，⚠️ 可接受，寫明即可。

## 6. 安全

同意 §7。新的 log 行（若採 M-1 的 (a)）只有位址末 2 碼和 1–3 位數字。攻擊者影響不了碼，因為碼是本機協定堆疊產生的；失敗碼也不參與任何判斷。嘗試頻率的上界（每個位址每輪 ≤ 2 次、間隔 6 s、一輪 ≤ 90 s）已寫進 §4。✅

## 7. 負向對照總表

| 主張 | 對照 |
|---|---|
| 失敗就結束 | 單元：connect 串流先送 false → 嘗試立刻結束；改回 `firstWhere((s) => s)` → 8 s → FAIL。真機：§8（至少 3 次；`r1_a0` 是 before） |
| 失敗碼 | 單元：E1、E2、E3 分在不同任務送，而且晚於 false → 有 `fail=133`；照 v3 現在的寫法 → `fail=?` → FAIL。真機：每次 133 都對到 `fail=` |
| 同位址過期的 false | 已有（§6 第 4 列） |
| 藍牙關閉 | §6 第 5 列；照 m-a 改成只斷言 |
| 不記 MAC | m-c |
