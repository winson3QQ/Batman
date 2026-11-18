# 審查 I：`docs/design/329-ble-settle.md` v1（BleGate settle + 連線失敗狀態碼）

審查者：獨立對抗式審查（唯讀）。範圍：整份設計＋背景設計 `329-app-uiux.md` §4.2 / §4.3 / §9.2，`app/lib` 在 `test/329-retest-a`（c795d63，設計檔尚未 commit），plugin `reactive_ble_mobile-5.6.0` / `flutter_reactive_ble-5.6.0` / RxAndroidBle 1.16.0 jar，證據 `scratchpad/b2/f22*`。

**結論：REJECT（v1 照現在的寫法）→ 修完 M1–M6 後重審。** 方向（斷線後隔一段時間再連）合理而且便宜，但 (a) 證據撐不起文件裡寫的 ✅ 因果與「1 s」；(b) 「系統回報斷線」這個前提經 plugin 原始碼查證是錯的；(c) `close()` 契約變了，但有一個呼叫端（`NodeLink._dropAll`）把 5 s 寫死；(d) 時間成本只用工作台情境（1 台自己的＋1 台別人的）算，沒有用現場情境（隊長手機、附近很多節點）算。

---

## 我自己重新抽的數字（按日期過濾，每次執行從開始時間起 75 s）

✅ 確認：`f22.out` 第 18–20 次、`f22flip.out` 第 1–8 次的摘要是錯的（awk 只比 `HH:MM:SS`；`f22flip.out` 第 1–8 次的 firstRead 是前一天 23:50/23:56 的行）。另外**第 18 次的 phone 檔被截斷**：`$2 >= 23:59:15` 把 00:00 之後的行全丟了，第 19 次的過濾（`>= 00:00:41`）也沒收到這段，所以第 18 次在午夜之後的部分**在任何檔案裡都沒有**。

我的抽取（腳本 `scratchpad/ex.awk`，日期＋時間）：

| | 基線 f22 | 等 1 s f22flip |
|---|---|---|
| 檔案裡的嘗試數 / 輪數 | 33 / 21（第 18 次被截斷） | 33 / 20 |
| 全部 `noResponse`（每次都對應 Android `status=133`） | **5**：第 07、18 次（04 的位址）；第 08、12、14 次（`452DD3_A` = …3A，02） | **1**：第 08 次（`5C1799_D` …0D） |
| 距離上一次 `cancelOpen` < 0.5 s 就連 | 6 次，**2 次 133** | 0 次（照設計本來就不會有） |
| 距離上一次 `cancelOpen` ≥ 0.5 s 才連 | 4 次，0 次 133 | 12 次，0 次 133 |
| **這一程序裡第一次連線**（前面沒有斷線，修正管不到） | 3 次 133（08/12/14） | 1 次 133（08） |
| 從開始到讀到 04：中位 / 最慢 | 7.8 s / 45.1 s（19 次；不含第 18 次） | 10.4 s / 15.9 s |

設計 §1 寫的「37 次嘗試、36 輪」「35 次」「中位 7.2 / 9.1、p90 14.2 / 13.0、最慢 45.3 / 14.5」**都無法從引用的檔案重現**（輪數 21 和 36 差太多；計時起點也沒寫）。

---

## MAJOR

### M1. 翻轉測試撐不起「✅ 等 1 s 就不會」，也撐不起「1 s」這個值
**情境**：要宣稱是這個修正讓失敗消失。
**證據**：
- 有因果關係的那一層只有「剛斷線就連」：基線 2/6，翻轉 0/12。Fisher 單尾 p = C(6,2)/C(18,2) = 15/153 ≈ **0.098**。設計用的 3/37 對 0/35：p ≈ **0.13**。照「每 20 次 2 次」的基本比率算，20 次出現 0 次的機率 = 0.9^20 ≈ **0.12**。三種算法都不顯著。
- 表格第 3 列「剛斷線就連 → 133：2 → 0」是**同義反覆**：翻轉之後根本不存在 1 s 內就連的情形，這一列一定是 0，不是量出來的結果。
- 修正碰不到的那一層（程序裡第一次連線）也從 3/20 掉到 1/20（p ≈ 0.30）。所以「同樣幅度的下降」在**沒有這個機制的那一層也發生了**，偶然或批次差異解釋得通。
- **訊號特徵不一致**：第 07 次（設計的主要例子）是 connect 後 **5 s** 才 `Connection Accept Timeout` → 133，和 4 次「前面沒有斷線」的失敗（基線 08/12/14、翻轉 08：都是 connect → 正好 5.0 s → 133）**一模一樣**。只有第 18 次是另一種（connect 後 **442 ms** 就 133，`23:59:21.713 → 22.155`）。也就是說，「16 ms 間隔」這個原因最多只有第 18 次有特徵上的支持。第 07 次可能就是那個和間隔無關、每次第一連線約 10–15% 的「對方沒回應」失敗。
- **混雜因素**：基線在 11-17 23:35–00:03 跑，翻轉在 11-18 05:45–06:12 跑（隔了 6 小時，沒有交錯）。位址不同（基線 04 = …0D/0E/DC/90/B1/80，翻轉 = …CF/AB/…；02 從 …3A 變成 …3B）。翻轉組有 14/20 次是先試 02 再試 04，基線是 10/20，所以延遲比較被嘗試順序混在一起了（中位數變慢 2.6 s，比 1 s 還多）。
- 1 s 以下沒量過，1 s 以外的手機或 Android 版本也沒量過。

**修正**：
1. §5 把「等 1 s 就不會」從 ✅ 降成 ⚠️，寫上 p 值和特徵不一致的事。或者補資料：
2. **交錯的 A/B**（同一個時段，settle 0 / 1 s 每次交替或隨機），而且用**刻意製造背對背連線**的方式跑（同一輪強迫先連 02 再連 04；開發版開關或測試入口），**每組至少 30 次背對背連線**。如果基線 ≥ 8/30、修正 0/30，Fisher p ≈ 0.002，才算有意義。
3. 加一組 **settle = 300 ms** 看劑量反應，這也是選值的依據。
4. 收 **btsnoop HCI log**（開發者選項「啟用藍牙 HCI 窺探記錄」）：如果前一條連線的 `Disconnection Complete` 晚於下一次 `LE Create Connection`，因果就有直接證據。這比 20 次冷啟動有力得多。
5. 把 §1 的表格改成可以重現的版本：附上抽取腳本和原始輸出，第 18 次標成「資料截斷」，計時起點寫清楚。

### M2. 前提錯了：`close()` 等到的「系統回報斷線」其實是 plugin 自己發的，背景設計 A12 的 ✅ 不成立
**證據**（✅ 原始碼）：`reactive_ble_mobile-5.6.0/.../ble/DeviceConnector.kt:63-87`：`disconnectDevice()` **先** `sendDisconnectedUpdate(deviceId)`（`ConnectionUpdateSuccess(DISCONNECTED)`，是 plugin 自己合成的），**之後**才 `disposeSubscriptions()`，也就是才真的觸發 RxAndroidBle 斷線（`cancelOpen`）。而且 `disposeSubscriptions()` 把 `connectionStatusUpdates`（真正的 `observeConnectionStateChanges`）也 dispose 了，所以**之後 stack 真正的斷線狀態永遠不會送到 Dart**。Dart 端取消訂閱時呼叫 `disconnectDevice`（`flutter_reactive_ble-5.6.0/lib/src/device_connector.dart:74`）。log 上也對得起來：第 18 次 app 結果 `21.693` → `cancelOpen 21.701` → 下一次 `connect() 21.713`。
**影響**：背景設計 §4.2「斷線完成 = 連線狀態串流回報 disconnected（M-1 3–14 ms）」和 A12 ✅ 量到的是 plugin 合成事件的延遲，不是 stack 的拆線時間。v1 把 settle 寫成「系統回報斷線之後再等」，因果故事建立在錯的前提上。這也說明在這個 plugin 裡**時間式的等待是唯一可行的做法**（app 根本看不到真正的拆線），這一點應該寫進設計，當作選這個做法的理由。
**修正**：§1、§3、§5 改寫用語；背景設計的 A12 改成 ⚠️ 並附 `DeviceConnector.kt:63-87`；§4.2 定義改成「plugin 回報（合成）＋ settle」。

### M3. `close()` 的契約變了，但 `NodeLink._dropAll` 把 5 s 寫死 → 佔用拿到之後 gate 還是忙的
**情境**：stack 沒回報斷線（例如藍牙關閉或 stack 卡住、走 `closeMax`），使用者在一輪中按下一個操作。
**證據**：`node_link.dart:598-608`：`_dropAll` 用 `50 × 100 ms`（真實時間 `Future.delayed`）等 `gate.links == 0`，註解寫「the gate counts a link … or 5 s」，是刻意對齊 `closeMax` 的。v1 之後 `close()` 最長是 5 + 1 = 6 s。`_dropAll` 在 5 s 放棄 → `acquire`（`node_link.dart:197-211`）照樣 `reg.acquire` → `gate.revoked(mine)` 對一條 `_open == false` 的連結什麼都不做（`ble_gate.dart:104`）→ 連結在 `_links` 裡還要再留約 1 s。這段時間持有者的 `gate.connect` 會被 `Refused('a link is already open')`（`ble_gate.dart:222-226`），`_lfAttempt` 把它記成 `noResponse`（`node_link.dart:385-386`）。照目前的程式，`loginFor` 會先看 `gate.links == 0`（`node_link.dart:299`），所以實際影響是延後，不是失敗。但契約已經不對了，背景設計 §4.4「拿到之前……最長 5 s」、X4 / T-L7「≤ 5 s」的文字和測試也都過時。
**修正**：`_dropAll` 的上限改成從 `BleGate.closeMax + BleGate.settle` 推出來（不要寫死 50）；§4.2 / §4.4 / X4 / T-L7 的「5 s」一起改；在 v1 §3「契約變更」列出這個呼叫端。

### M4. 時間成本只用工作台情境算，現場情境（隊長手機、附近很多節點）沒算
**情境**：隊長手機有 7–12 台自己的節點，附近還有別隊的節點和陌生的廣播者（T-L21 的情境）。
**證據**：設計 §4 只寫「一輪 2 台最多多 2 s」。實際上 settle 是**每次嘗試**都多 1 s，包括對別人位址的「解不開」嘗試。一輪的上限是 90 s（`core.dart:10`），一次嘗試大約 3–5 s（§1：2.8–5.7 s），所以每輪能做的嘗試數會少大約 20–25%（4 s 一次時 22 次 → 18 次）。T-L21 (b)(c)(d)（12 台＋陌生位址，斷言「沒有連不到」「每台最長間隔 ≤ 300 s」「狀態區一切正常」）的餘量會被吃掉，設計沒有重跑也沒有分析。基線中位數 7.8 → 10.4 s 也表示一般情況下的成本是看得見的。
另外：一個在 BLE 範圍內、廣播 provd UUID 的攻擊者（或只是很擠的房間），本來就能讓每個位址每輪耗兩次嘗試（§4.3.7），每次嘗試多 1 s 會讓這個放大效果再大約 25%。
**修正**：§4 加上「每輪嘗試數上限」的算式（`90 / (t_a + 1)` 對 `90 / t_a`），用 T-L21 的參數重算（假時鐘，A1 = 實測上限）並列出結果。考慮**改放的位置**（見 m1），讓只有「剛斷線就要連」的情形付這 1 s。

### M5. 結果在 settle 之後才交給 core → 上限到時會丟掉已經讀到的結果；freeAt 也往後推
**證據**：`node_link.dart:575-580`：`await mine?.close()` 之後才 `core.result(now(), a, o)`。`core.tick` 在 90 s 上限時把 `r.running` 切掉，記成「沒試過」（`core.dart:510-519`）；之後才到的 `result` 會因為「late result」被丟掉（`core.dart:428`）。今天這個空窗約 10 ms，v1 之後每次嘗試都是約 1 s：一次**已經拿到 body** 的讀取，如果剛好落在上限前 1 s 內，core 不會記錄（`readWall` 卻會更新，`node_link.dart:582`，兩邊不一致）。`freeAt = now + gap`（`core.dart:430`）也一起往後推 1 s。在很擠的現場每輪都會碰到上限，這不是罕見的情形。
**修正**：在 `_run` 裡先 `core.result(...)`，再 `close()`（下一次嘗試本來就要等 `gate.links == 0`，`node_link.dart:463`，順序安全），或者明確寫下這個取捨並加測試（上限前 0.5 s 拿到 body → 那一台算讀到）。

### M6. 範圍：同樣「剛斷線就連」的路徑還有別的地方，不只舊控制台
**證據**：`claim_recovery.dart:93-108, 131`：`ReactiveRecoveryBle.connect` / `_ReactiveLink.close() => conn.cancel()` 直接用 `FlutterReactiveBle`，不等斷線，然後換下一台（「next device」，`claim_recovery.dart:618`）。只有 msg1 送出後才有 10 s 的 `pace`（`:201, :587`），**連線失敗或 msg1 之前結束的話，下一台是馬上連**。這是認領流程（PR 6 不會刪），而且是現場最痛的地方（45 s 的寫入前時限）。`claim.dart:260`、`nodes.dart:197`、`scan.dart:95` 也一樣。
**修正**：v1 §3 列出這幾處，說明哪一個由誰負責（不修的話，照規則寫進 #329 的清單，不要只寫「PR 6 會刪」），或者把 settle 做成 gate 和 recovery 共用的「上一次斷線時間」。

---

## MINOR

- **m1（替代方案沒寫）**：在 `close()` 裡等，代表**每一次**關閉都付 1 s（輪結束、佔用釋放、流程的每次 `h.close()`，例如 `net_run.dart:252` 失敗後的「繼續 / 停」對話框會晚 1 s 跳出），就算下一次連線本來就在 6 s 之後。另一個做法：gate 記錄 `lastDownAt`，`NodeLink` / `loginFor` 選下一次嘗試時多一個條件 `now - lastDownAt >= settle`（要在 `t0` 之前，不要吃到 8 s 的預算），`acquire` 也等到同一個條件。這樣 `close()` 的契約不變，M3 / M5 也不會發生。設計應該列出替代方案和選擇的理由。
- **m2（失敗要 8 s 才結束）**：第 18 次的 133 在 442 ms 就到了，第 07 次是 5 s，但兩次都等滿 8 s（`connected=-1 … after 8002ms`）。因為 `link.state.firstWhere((s) => s, orElse: …)`（`node_link.dart:553`、`:378`）會忽略 `false`，而 plugin 的連線串流在失敗時不會結束。這和 settle 無關，但對「最慢 45 s」的影響比 1 s 大（每次 133 白白多等 3–7.5 s）。至少寫進清單；如果做 M4 的時間分析，要把它算進去。
- **m3（第二個呼叫者馬上返回）**：`GateLink.close()` 的 `if (!_open) return;`（`ble_gate.dart:104`）讓第二個呼叫者在第一個還在 settle 時就返回（例如 `revoked` 已經開始關，之後 `LoginHandoff.close` → `link.close()`）。v1 §3「呼叫端只依賴 close 結束後可以開下一條」對第二個呼叫者不成立，而且空窗從約 10 ms 變成約 1 s。目前每個連線方都會先看 `gate.links`，所以還沒出事。建議改成共用一個 `_closing` future（`OwnerConsole.close` 已經這樣做，`owner_console.dart:653`）。
- **m4（文件裡別的常數）**：§4.3.1 的 300 s 推導寫「一輪最多 95 s → 95 + 60 + 95 = 250，留 50 s 給 X25」，要改成 96 / 252。X25 最多約 30 s，所以 300 s 還夠，但文字要更新。§4.4「最長 5 s」、§4.2 的定義也要改（見 M2 / M3）。
- **m5（R-3 門檻 160 → 165）**：背景設計 R-3 明寫門檻「PR 開始前定案，不是事後放寬」。這次是因為公式變了才調，可以接受，但要在 PR 和 issue 裡**明白標成驗收標準的變更**並附算式，不要埋在設計裡。
- **m6（測試會卡住）**：`handoff_test.dart:39`、`prober_test.dart:135, :307`、`prober_hint_test.dart:85`、`app_link_console_test.dart:92` 建 gate 時用的是不會觸發的 `after: (d, f) => () {}`。v1 之後 `close()` 要等 settle 計時器，這些測試裡 `await link.close()` 會永遠卡住。§8 要寫明這些測試怎麼改（改成假時鐘，**不要**加「settle 可以關掉」的後門，否則正式程式也能關掉它）。`close()` 的兩個計時器結束後也沒有取消（`ble_gate.dart:118` 本來就這樣）。
- **m7（狀態碼 log）**：
  - ✅ RxAndroidBle 1.16.0 的 `BleDisconnectedException` 訊息是 `"Disconnected from " + commonMacMessage + " with status " + N + " (" + desc + ")"`（從 jar 抽的字串：`Disconnected from `、` with status `、`MAC='%s'`），而且 MAC 是否遮罩取決於 `getMacAddressLogSetting`。所以「不記全文」是必要的，regex 要寫成 `with status (\d{1,3})\b`，只取 1–3 位數字。
  - plugin 的逾時路徑（`timeout`，訊息是 null → `"Unknown error"`）和 `"Device is not in queue"` 都會變成 `status=?`。第 07 次那種 5 s 的情形，plugin 的 8 s 逾時先到還是 133 先到要確認，否則現場最常見的那一種可能永遠記成 `?`。
  - `ReactiveBackend` 現在沒有 log 介面，要注入 log 函式並經過 `NodeLink.mask`。
  - 建議 log 行帶遮罩過的位址（和 attempt 行一樣）。注意末 2 碼會撞：基線的 `7C7116_D` 和翻轉的 `5C1799_D` 都記成 `…0D`，設計把翻轉第 08 次歸給 02 就是靠這個不可靠的根據。
- **m8（生命週期矩陣缺的列）**：藍牙 stack 程序重啟（走 `closeMax` + 1 s，見 M3）；app 在背景時 Dart 計時器延後（settle 被拉長，影響 `acquire` 的等待）；**各家 Android 版本 / 廠商**（「支援平台：Android」只量過 S20 / 13；1 s 是在一台手機上量的經驗值，要寫成 ⚠️ 並列出換手機時要重量）；降級 / 回滾（沒有存檔，n/a，但要寫出理由）。
- **m9（安全）**：新輸入是同一支手機的 plugin 字串，只擷取數字，風險低，同意設計 §7。補兩點：(a) M4 提到的放大效果（範圍內的攻擊者可以讓每輪多耗時間）；(b) 狀態碼可以被遠端影響（對方用不同的 reason 拒絕連線），只是一個數字，不影響任何決策，要確認之後**不會**拿它當判斷依據（例如「133 就標成別人的節點」）。如果要拿來判斷，要先過信任邊界審查（`core.dart` 的 driver contract 規定：驗過憑證之前的事都是 `noResponse`）。

---

## 每個說法需要的負向對照

| 說法 | 需要的負向對照 |
|---|---|
| settle 讓背對背連線不再 133 | 交錯 A/B，同一時段，settle = 0 那一組要真的重現（每組 ≥ 30 次背對背連線）；最好加 btsnoop |
| `close()` 在 down + settle 之前不會完成 | 單元測試：settle = 0 → FAIL（設計 §8 已經有） |
| `acquire` 在 settle 結束後才發佔用（M3） | 單元測試：stack 不回報（走 `closeMax`）→ 佔用持有者的第一次 `connect` 不會被 `Refused`；`_dropAll` 寫死 50 次 → FAIL |
| 上限前拿到的 body 有記錄（M5） | 單元測試：body 在 cap − 0.5 s 拿到 → core 記成讀到；照 v1 的順序 → FAIL |
| log 有 `status=133`、沒有 MAC | 假 backend 送出真實格式的訊息（`Disconnected from MAC='AA:BB:CC:DD:EE:FF' with status 133 (GATT_ERROR)`，格式照 jar 字串，不要自己編）→ log 有 `status=133`、不含 `AA:BB`；拿掉遮罩 / 擷取 → FAIL |

## 呼叫點清單（`close()` 和等它的地方）

`ble_gate.dart:246`（`revoked`，沒有 await）；`node_link.dart:306`（`loginFor` 裡的 `h.close`）、`:397`（`_lfAttempt`）、`:575`（`_run`，之後才 `core.result`，見 M5）、`:594`（`_abort`，`.then(_pump)`）、`:598-608`（`_dropAll` 輪詢 5 s，見 M3）、`:197-211`（`acquire`）；`handoff.dart:87`；`owner_console.dart:672`；`op_session.dart:110, 114, 126, 167, 175, 187, 197`（都在 `lease.release()` 之前）；`net_run.dart:133, 212, 229, 252, 277, 291, 402, 430`。不經過 gate、會背對背連線的地方：`claim_recovery.dart:93-108, 131`、`claim.dart:260`、`nodes.dart:197`、`scan.dart:95`（見 M6）。除了 M3 以外，沒有呼叫端依賴 `close()` 快速完成：⚠️ 這是我逐一讀過的結論，沒有跑測試。

## 驗證分類

- ✅ 讀原始碼或檔案確認的：M2（plugin 原始碼）、M3 / M5 / m3 / m6（app 原始碼行號）、§1 的數字重抽（上表）、第 18 次截斷、RxAndroidBle 訊息格式（jar 字串）。
- ⚠️ 推論：M4 的嘗試數減少比例是算出來的，沒有模擬；Fisher p 值是我手算的；M1 說第 07 次是「對方沒回應」型失敗，只是根據訊號特徵相同。
- ❌ 沒做：沒有跑 Dart 測試、沒有上機、沒有 btsnoop。
