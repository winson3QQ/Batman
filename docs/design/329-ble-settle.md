# #329 補測：連線失敗時立刻結束這次嘗試 ＋ 失敗原因進 log

狀態：設計 **v3**（2026-11-18）。v1（BleGate.close 後等 1 s）兩位審查 REJECT、撤回；v2 兩位 APPROVE-WITH-CHANGES（I：3 MAJOR / 7 MINOR；J：1 MAJOR / 6 MINOR），v3 逐條修。分支 `test/329-retest-a`。審查紀錄：`329-reviews/review-settle-{I,J}.md`（v1）、`review-settle2-{I,J}.md`（v2）。

**這個修正不會讓失敗變少**，只讓每次失敗少等 3–5 s。失敗的根本原因（手機的連線請求節點沒收到）未知，要 btsnoop HCI 紀錄（手機開發者選項，使用者自己開）才能往下查，已寫進 #329 清單。

## 0. 版本差異

- v1 → v2：v1 假設「前一條連線剛斷就連下一台 → 133」並以 1 s 間隔修；審查指出樣本不足（p≈0.1）、兩組不同場次、plugin 的「斷線」是自己合成的（`DeviceConnector.kt:63-87`）、放在 `close()` 拖慢每個呼叫點。同場次量測（§1 B）看到失敗在前一條連線斷了 18–20 s 之後照樣發生，所以「剛斷線」**不是失敗的必要條件**。換台後 ≤ 12 ms 就連的那一類（§1 A 兩例）沒有再量，不能說它不存在；v2 起不處理間隔。
- v2 → v3：失敗碼改從 gate 已在聽的 `linkStates` 取（I-M1）；刪掉「只取 connecting 之後的事件」的退路與「先 false 再 true」的測試（I-M2）；真機驗收改成至少 3 次自然失敗（I-M3 / J-M1）；補藍牙關閉競態、同位址快速重連兩列生命週期；行號、名稱、假 backend 清單、regex 改正（I / J MINOR）。

## 1. 證據

**A. 冷啟動 20 次**（`scratchpad/b2/f22/`，已按日期重抽）：失敗的形狀有兩種，Android 都回 `status=133`——
- 0.4–2.9 s 回 133，沒有 `on_create_connection_timeout`（f22 第 18 次 442 ms、ab 2.9 s）；
- 5.0 s `on_create_connection_timeout` / `hci_status: Connection Accept Timeout` → 133。
兩種都是：節點 provd log 在那段時間沒有 `adv withdrawn reason=connect`（沒收到連線），前一筆是 `adv registered`（廣播開著）；同位址前後都成功過（I：`.bt` 裡 133 之後 11 s 同位址再連成功，失敗的 connector 不會卡住）。

**B. 同場次重新整理 15 次**（`scratchpad/b2/ab/r1_a0.app`、`.bt`；該 build 每次 connect 記 `since` = 距上一條連過的連結關掉多久）：

| 發起連線 | since | Android | app 嘗試結束 |
|---|---|---|---|
| 07:54:00.720 …7C | 18 571 ms | 07:54:03.597 `status=133`（2.9 s，無 timeout 行） | 07:54:08.708（**8.0 s**） |
| 07:55:31.032 …7C | 19 868 ms | 07:55:36.033 Accept Timeout → 133（5.0 s） | 07:55:39.024（**8.0 s**） |

成功的 13 次 `since` 在 4.5–21 s。04 的 provd log（換算到手機時間 ±1 s；原始輸出存 `ab/r1_a0.node`）：兩段都只有 `adv registered`，下一個 `withdrawn reason=connect` 分別在 07:54:15、07:55:46。同時段另一個 app 程序（pid 22497，`dev3`）在 07:53:23 對 7C31 有一次 BLE 嘗試；本檔（到 07:57:49）期間沒有它的其他行。

## 2. 改動

1. **失敗就結束**：`NodeLink._run`（`node_link.dart:556`）與 `_lfAttempt`（`:379`）等的是「連線串流的第一個事件」，不是「第一個 `true`」：第一個事件是 `false` → 這次嘗試立刻以 `noResponse` 結束。整個 `lib/` 只有這兩處用 `firstWhere((s) => s)` 等連上（`owner_console.dart:179` 是 handoff 之後才聽，不受影響）。
   - 為什麼不是「只在帶 failure 的事件上結束」（J m-1）：I-M1 指出失敗時第一個事件可能就是**不帶** failure 的 `DISCONNECTED`（`DeviceConnector.kt:117` 先於 `:121-123`），而 Dart 的 `connect()` 在第一個 `disconnected` 就以 `takeWhile` 結束串流（`device_connector.dart:57-64`）——等 failure 會漏接、退回等滿 8 s。全新 connector 在 `CONNECTING` 前不會送 `disconnected`（I 讀原始碼：`:94-97`、lazy 的 `:43-58`、broadcast 不重播）；唯一的例外是同一位址關閉後約 200 ms 內再連（延後合成的 DISCONNECTED、`:68-75`），NodeLink 對同一位址的嘗試至少隔 6 s（`core.dart:430`、`:694`）；就算碰到，結果是 `noResponse`，和今天相同，只是不用等 8 s。
2. **失敗原因進 log**：`BleGate` 已在聽 `backend.linkStates`（`ble_gate.dart` 的 `_states`，來源是 `connectedDeviceStream`）。`linkStates` 的事件加上失敗碼（`(address, up, failure)`），gate **只要在 `linkStates` 收到帶碼的事件，就自己記一行** `BMAPP gate link …7C down fail=133`，不管那條連結還在不在表上（帶碼的事件是另一則平台訊息，可能在 connect 串流的 false 結束嘗試、`close()` 之後才到：J v3 MAJOR）；它和 NodeLink 的 attempt 行（`attempt …7C×…7d2c connected=-1ms result=noResponse after 2901ms`）用時間與位址末 2 碼對起來。連結開著時收到的第一個碼另外存在 `GateLink.failure`（`int?`，只有測試讀）。失敗碼 = plugin 錯誤訊息 regex `with status (\d{1,3})\b` 的數字，沒有數字的失敗記 `?`。plugin 一次失敗會送兩筆帶碼事件（`ReactiveBleClient.kt:115-121`），同一次失敗可能記兩行，屬預期。不記訊息全文（含完整 MAC），位址只記末 2 碼（現行）。失敗碼只進 log，不參與任何判斷。

## 3. 介面與擁有權

- `BleGate` 仍是唯一開關連結的元件；`close()` 不變（v1 撤回）。
- `BleBackend.linkStates` 的型別從 `Stream<(String, bool)>` 變成 `Stream<(String, bool, int?)>`（第三欄 = 失敗碼；`up == true` 時一律 null）。**寫者**：只有 `ReactiveBackend`（ble_backend.dart）；**讀者**：只有 `BleGate`。要跟著改的假 backend（grep `linkStates`，6 個檔）：`test/nodelink/{ble_gate,node_link,handoff,prober,review_pr1}_test.dart`、`test/flows/owner_console_test.dart`。
- `GateLink.failure`：寫者 = gate（連結開著、位址相同時的第一個碼）；讀者 = 只有測試。log 由 gate 的 `trace`（AppLink 接到 `debugPrint('BMAPP gate …')`）記，不依賴連結還在。
- `connect` 串流的 bool 契約不變（true 連上 / false 斷了或失敗）。
- 「8 s 預算」語意：從「等到連上或 8 s」變成「等到第一個連線事件或 8 s」。連上之後的 msg2 等待不變。

## 4. 時間常數（§4.3）

只會變短（失敗的嘗試從 8 s 變 2.9–5 s）。一輪上限、提前再讀、R-3（160 s）、R-7 都是上限，不重算。同一位址下一次嘗試會提早 3–5 s；「是 Y 的位址一輪兩次沒回應就丟備忘」更早達到，語意不變。A10（掃描次數）不受影響：一輪一次掃描。嘗試頻率的上界不變：一輪 ≤ 90 s、每個位址每輪 ≤ 2 次（§4.3.3），範圍內廣播服務 UUID 的攻擊者只會讓失敗的嘗試變短。

## 5. 依賴與證據

| 假設 | 證據 |
|---|---|
| 失敗會讓連線串流結束（第一個事件是 `false`） | ✅ I：`device_connector.dart:57-64`（`takeWhile` 在第一個 disconnected 結束）；`DeviceConnector.kt:117-123` |
| 全新連線在 `CONNECTING` 前不會送 `disconnected` | ✅ I：`DeviceConnector.kt:94-97`、`:43-58`、`device_connector.dart:66-73`、`PluginController.kt:120`；例外見 §2.1 |
| 失敗碼出現在 `connectedDeviceStream`（`ConnectionUpdateError`） | ✅ `DeviceConnector.kt:121-123`、`ReactiveBleClient.kt:115-121`（會送兩次，取第一次）；⚠️ 訊息格式 `with status 133` 由 I 從 RxAndroidBle 1.16 jar 字串確認，真機確認一次 |
| 失敗的 connector 不會卡住 plugin 的佇列 | ✅ I：`.bt` 133 之後 11 s 同位址再連成功 |

## 6. 生命週期

| 路徑 | 今天 | 之後 | 測試 |
|---|---|---|---|
| 連線失敗（2.9 s 133 / 5 s timeout） | 等滿 8 s | 第一個事件 false → 結束 | 單元：假 backend 2 s 送 false（connect 串流）＋ linkStates 送 `(addr,false,133)` → 嘗試 2 s 結束、trace `fail=133`；負向對照（改回 `firstWhere((s)=>s)`）→ 8 s |
| 失敗，linkStates 先送不帶碼、再送帶碼 | — | 取第一個**帶碼**的；都沒有 → `fail=?` | 單元：照 plugin 真實順序（I-M1） |
| 正常連上 | 不變 | 不變 | 既有 T-L 全過 |
| 同一位址關閉後立刻重連，收到過期的 false | 會被 `firstWhere` 忽略 | 以 noResponse 結束（和今天結果相同，只是更快） | 單元：失敗並 close 之後 200 ms 內同一位址再連，backend 先送一筆延後的不帶碼 false → 這次結果 noResponse、core 不顯示「連不到」、同一位址的下一次嘗試在 ≥ 6 s 之後（core.dart:430 / :694） |
| 連線中藍牙被關 | `_abort` 丟掉這次嘗試、不記結果 | 失敗事件可能比 radio 狀態先到 → 這次以 noResponse 記進 core | 單元：連線中送 false 後 1 ms 再送 bluetooth off → 不出現「連不到」、畫面是 2.3（藍牙關閉），不是「連不到」。定案（I / J v3）：不加撤回機制；這次的 noResponse 留在 core 裡，最壞的後果是藍牙開回後那一輪要重新認那個位址（多一次握手），不會顯示錯的東西；單元測試斷言「不出現連不到、藍牙開回後下一輪讀得到」；真機 R-4 重跑 |
| lease / 背景 | 不變 | 不變 | 既有 |
| 安裝 / 升級 / 降級 | 無持久狀態 | 同 | n/a |
| 平台 | Android | Android | — |

## 7. 安全

新輸入：plugin 錯誤訊息（本機系統元件），只以 `with status (\d{1,3})\b` 取 1–3 位數字；log 不含完整 MAC、秘密；失敗碼不參與任何判斷。攻擊者（範圍內廣播服務 UUID）的影響只會變小。

## 8. 驗證

- 單元（假時鐘）：§6 各列；log 涵蓋 `status 133`、`"Unknown error"`、`"Device is not in queue"` 三種訊息（後兩種 `fail=?`），並斷言 log 不含完整位址；負向對照：把 trace 改成記訊息全文 → 位址斷言 FAIL（J v3 m-6）。帶碼事件要分在**不同的 event-loop 任務**、晚於 connect 串流的 false 送出（照平台訊息的真實順序）；「只在連結開著時收碼」的寫法必須讓這個測試 FAIL（J v3 MAJOR 的負向對照）。
- 真機：重新整理 / 冷啟動直到收集到 **至少 3 次** Android 的 `status=133`；判準：每一次 app 的嘗試在那筆 133 之後 **≤ 500 ms** 結束，且 trace 的 `fail=` 與 Android 的 status 一致。收集不到 3 次 → ❓（不是通過）。負向對照：`ab/r1_a0.app` 那兩次（133 之後 5.1 s / 3.0 s 才結束）。另重跑 R-4。
- 存檔：Android BT 行、app trace、04 provd 行（換算時間）都放 `scratchpad/b2/` 對應的資料夾。
