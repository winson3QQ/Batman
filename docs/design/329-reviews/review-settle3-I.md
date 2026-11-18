# 審查 I（第三輪）：`docs/design/329-ble-settle.md` v3

唯讀，整份重審。這一輪重新核對了以下來源：
- plugin 原始碼：`DeviceConnector.kt`、`ReactiveBleClient.kt`、`device_connector.dart`
- app 程式：`node_link.dart` 的 trace 和 close 順序，用 `grep linkStates` 找出所有實作者
- 新證據：`ab/r1_a0.node`
- GitHub issue #329 的內文（用 `gh issue view` 唯讀查看）

**判定：APPROVE-WITH-CHANGES。** 還有 1 個 MAJOR（N1），修法很局部。另有 6 個 MINOR。照使用者的規則，MAJOR 修完後要再審一次整份文件。我的看法是 N1 修完、改幾行字就可以實作。

---

## 上一輪的問題真的修好了嗎

| v2 的問題 | v3 | 結果 |
|---|---|---|
| M1：失敗碼的擷取點放錯 | 改從 `linkStates` 取 | ⚠️ **只修了一半**：來源對了，但讀取的時間點不對，見 N1 |
| M2：退路和「先 false 再 true」的測試要刪 | 兩個都刪了；§6 改成「過期的 false → noResponse」 | ✅ |
| M3：真機驗收可能沒有樣本也算通過 | §8 改成：至少 3 次 133、133 之後 ≤ 500 ms 結束、fail 碼和 Android 一致、湊不到 3 次就記 ❓；負向對照是 r1_a0 那兩次 | ✅ 核對過：負向對照的 5.1 s 是 03.597→08.708，3.0 s 是 36.040→39.024 |
| m1：藍牙關閉的競態 | 補了一列 | ⚠️ 補了，但寫成條件式（「若會消失，改成…」），見 n1 |
| m2：介面變了、假 backend 要列出來 | `linkStates` 的型別寫清楚了，也列了假 backend | ⚠️ 名單不完整，見 n3 |
| m3：行號、`LinkSession` | 改成 556 / 379；grep 找不到 `LinkSession` 了 | ✅ |
| m4：缺節點 log、pid 22497 | `r1_a0.node` 已存，見下面核對 | ✅ / ⚠️ 見 n4 |
| m5：說清楚修了什麼沒修什麼；根本原因寫進 #329 清單 | 開頭寫清楚了 | ✅ 開頭寫了；❌「已寫進 #329 清單」**不是事實**，見 n2 |
| m6：失敗的 connector 不會卡住 | §1 A 和 §5 有引用 | ✅ |
| m7：regex、只進 log、頻率上界 | §2.2、§4、§7 都有 | ✅ |

**`r1_a0.node` 核對** ✅：
- 07:53:46 `adv registered` 之後，下一筆 `withdrawn reason=connect` 在 07:54:15。期間就是 07:54:00.7 的 133。
- 07:55:15 `registered` 之後，下一筆 `withdrawn` 在 07:55:46。期間就是 07:55:31 的 133。
- 其他 13 次成功的連線，每一次都在 3 s 內看到節點的 `withdrawn reason=connect`。

和 §1 B 的說法一致。

**v3 §2.1 不採用 J 的 m-1，我同意。** 原始碼的順序是這樣：
- `DeviceConnector.kt` 的 `doOnNext` 裡，先存取 `connectionStatusUpdates`。這是 lazy 屬性，存取時才訂閱，`startWith(device.connectionState)` 會同步送出一筆。
- 之後才 `updateListeners.invoke(ConnectionUpdateError…)`。在檔案裡大約是第 122 行先、第 126 行後。

所以「不帶失敗碼的那一筆在帶碼那一筆**之後**」這個說法和程式碼順序不合。帶碼的會不會是第一個 false，取決於那一刻 `device.connectionState` 的值。只在帶碼的事件上結束，就要賭這個值。在第一個 false 就結束，則兩種順序都成立。

---

## MAJOR

### N1. trace 在第一個 false 時就寫出、緊接著 close；帶碼的事件晚一個訊息才到，就會變成 `fail=?`
**情境**：連線失敗。plugin 送出的順序是 A 或 B：
- A：先一筆**不帶碼**的 `DISCONNECTED`（`device.connectionState` 已經是 DISCONNECTED 時），再一筆帶碼的。
- B：先 `CONNECTING`（被濾掉），再帶碼的那筆。

**證據**：
- `node_link.dart:573`：trace 先寫，`:575` 才 `await mine?.close()`。`_lfAttempt` 也一樣，`:396` 先 trace，`:397` 才 close。
- v3 §2.2 規定 gate 只在「連結開著」時寫 `GateLink.failure`。close 一結束，`gate._links.remove`，之後才到的碼就沒人收了。
- 在順序 A 裡，帶碼的那筆是**下一個 platform 訊息**：
  - plugin 先後呼叫兩次 `updateListeners`；
  - 兩筆都經 `observeOn(mainThread)` 送出（`DeviceConnectionHandler.kt:50`）；
  - 每一筆是 EventChannel 的一則訊息，Dart 端各自是一個 task。
- 第一則訊息的 task 裡，connect 串流的 `takeWhile` 收到 false 就結束。接著 `firstWhere` / `Future.any` 回來、寫 trace、close，全部在這個 task 的 microtask 裡完成。所以碼還沒到，trace 已經寫了 `fail=?`，而且是**每次都這樣**。
- `ReactiveBleClient.kt:115-121` 的第二筆錯誤一定更晚到。
- 在順序 B 裡，兩條路徑吃的是同一則訊息，結果取決於 microtask 的層數：
  - `linkStates` 這條經過 Repeater 一層；
  - connect 這條經過 `initialize().asStream().asyncExpand` → Repeater → `asyncExpand` → `GateLink._state`（非同步的 broadcast）→ `firstWhere` → `Future.any`。

  大概率是 `linkStates` 先到，但這也是推論 ⚠️。

A 還是 B，原始碼定不下來（v2 我已標 ⚠️）。v3 §6 第 2 列的單元測試「linkStates 先送不帶碼、再送帶碼 → 取第一個帶碼的」，如果假 backend 在同一個 microtask 裡連送兩筆，測試會綠，真機卻是 `?`。這正是使用者記錄過的「stub 格式不照真機」那類坑。

§8 的真機判準（fail 碼要一致）**會抓到**這個問題，不會靜默通過。但那時候就要回頭改設計。

**修正**（擇一，建議 1）：
1. 失敗碼由 **gate 自己記一行**：`_states` 的 listener 收到帶碼的事件時，只要位址屬於最近 N 秒內開過的連結（例如 10 s，留一個小表），就記 `BMAPP nl link failure …7C status=133`。trace 的 attempt 行照舊；兩行用遮罩後的位址加時間對起來。這和事件的先後順序無關。
2. 或者 `GateLink.failure` 在 close 之後還收一段時間（≥ 300 ms），attempt 行改到這段時間結束後才寫。

單元測試要照真實順序，在**兩個不同的 event-loop task** 裡送這兩筆：先 `(addr,false,null)`，`await Future(() {})`，再送 `(addr,false,133)`，最後斷言 log 裡有 `status=133`。負向對照是現在的寫法（trace 在 close 之前、只在連結開著時收碼），會得到 `fail=?`，測試 FAIL。

---

## MINOR

- **n1. 藍牙關閉那一列寫成條件式。** 設計要先決定，不要寫「若會消失，改成撤回」。
  - 我和 J 都讀到同樣的結論：只有在同一輪、同一位址已經有一次 noResponse 時，才會丟掉「是 Y」（`core.dart:473-477`，`count >= perAddr`）。
  - 後果只是下一輪要重新認節點，不會顯示錯的東西。
  - 建議直接定為「接受，記錄在 §6」，或直接寫撤回的做法，然後照那個寫測試。
- **n2. 「已寫進 #329 清單」不是事實。**
  - `gh issue view 329`：內文最後更新是 2026-11-17T23:55Z，早於 v3。內文和留言都搜不到 `btsnoop`。
  - 相關的舊項目在第 107、121、158、170 行，第 121 行就是這次的「先等滿 8 s」。
  - 要實際加上，或改用現有的第 121 行勾掉、第 158 行改寫。PR 和 issue 要同步。
- **n3. 假 backend 名單少兩個。** `grep linkStates app/test` 還找到 `test/nodelink/prober_test.dart` 和 `test/nodelink/review_pr1_test.dart`。`app_link_console_test.dart` 用的是 `node_link_test` 的 `Radio`。請列完整。
- **n4. pid 22497 的說法沒有檔案佐證。** 「logcat 直到 08:01 沒有它的 attempt 行」：`r1_a0.app` 只到 07:57:49，看不到 08:01。請把那段 logcat 存檔，或改成「存檔範圍內（到 07:57:49）沒有它的行」。
- **n5. §1 A 失敗的形狀寫錯。**
  - f22 第 18 次是 connect 之後 **442 ms** 就 133（`23:59:21.713 → 22.155`），沒有 timeout 行，不是 2.9 s。
  - 應寫成兩種：「0.4–2.9 s 回 133、沒有 timeout 行」和「5.0 s Accept Timeout → 133」。
  - J 也提過：attempt 行的 `after` 才是分得出這兩種的欄位，`fail=` 兩種都是 133。§2.2 已經保留 `after`，可以寫明。
- **n6. 同一位址快速重連那一列的測試要寫清楚時間軸。** 「0 ms 重連」應該是：前一條連線失敗並 close 之後，200 ms 內對同一位址 `gate.connect`，再送一筆不帶碼的 false。要模擬的是 `DeviceConnector.kt:63-75` 延後的那一筆。斷言：結果是 noResponse；core 的 `freeAt` 讓下一次在 6 s 後；不出現「連不到」。

## 其他已核對、沒有新問題的部分
- 整個 `lib/` 只有 `node_link.dart:379` 和 `:556` 這兩處 `firstWhere((s) => s)`。`owner_console.dart:179` 是 handoff 之後才聽。✅
- 時間常數只會變短，R-3（160 s）、R-7 不用改。✅
- 安全：
  - regex 是 `with status (\d{1,3})\b`；
  - 只進 log，不參與判斷；
  - 嘗試頻率的上界寫在 §4；
  - 範圍內的攻擊者能造成的影響只會變小。

  ✅ 補一點：照 N1 修正 1，gate 自己記的那一行也只能有遮罩後的位址和數字，不能有訊息全文。
- 舊頁不經 gate，不在範圍內。J 提的 `scan.dart:96` 會把完整位址和 failure 全文記進 log，那是既有問題，PR 6 刪掉舊頁時一起消失。可以在 §7 記一行。

## 驗證分類
- ✅ 原始碼或檔案：上一輪問題的核對表、`r1_a0.node` 的時間、trace 和 close 的順序、`doOnNext` 的順序、`grep linkStates`、issue #329 內文。
- ⚠️ 推論：N1 裡順序 B 的 microtask 層數、plugin 實際送 A 還是 B（要真機確認，§8 會抓到）。
- ❌ 沒做：沒跑測試、沒上機。
