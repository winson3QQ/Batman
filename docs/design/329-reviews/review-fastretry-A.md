# Review A：`docs/design/329-fast-retry.md` v1

審查者：獨立審查 A（唯讀；沒有改任何檔案、沒有跑 flutter／adb）。
依據：`C:\src\Batman-fr`（fix/329-fast-retry）、vendored plugin `app/third_party/reactive_ble_mobile`、
pub cache 中的 `flutter_reactive_ble-5.6.0`、`Desktop/Batman/a4/a4-t2.logcat`、`a4-fc.logcat`、`a4stats.py`。

## 已核對的前提

- ✅ 298 行 attempt（`grep -c "BMAPP nl attempt .* connected="`，兩個檔合計 = 298），其中 16 行 `connected=-1ms`，
  時間 370–1070 ms（t2：14 行，fc：2 行）。兩個 logcat 都沒有 `loginFor` 行（`grep -c "BMAPP nl loginFor"` → 0/0）。
- ✅ air log：`20:24:00.565 on_le_enhanced_connection_complete` → `20:24:00.890 Failed to read remote features
  status:Connection Failed Establishment` → `on_le_disconnect … Reason : 62` → `status=133` → `20:24:00.902 BMAPP nl attempt
  …17×…880c connected=-1ms result=noResponse after 620ms`；下一次 `connect()` 在 `20:24:06.912`。
- ✅ `GateLink._close`：連線串流第一個事件是 `false` 時已經 `_down=true`（`ble_gate.dart` `_on`→`_downNow`），
  所以 `close()` 不會等那 5 s；`finally` 把它從 `_links` 移除，所以第二次 `connect` 不會因為「這個位址已經有連結」被拒。

## 發現

### B1 BLOCKER：失敗後立刻重連，會收到 plugin 延遲送出的過期 DISCONNECTED，重試幾乎一定失敗

情境：第一次 connect 在 t0 以 133 結束。Dart 端的 connect 串流在 `disconnected` 時以 `takeWhile` 結束
（`flutter_reactive_ble-5.6.0/lib/src/device_connector.dart:57-64`）。這會關閉 Repeater 的 broadcast controller，
接著觸發 `onCancel: () => _blePlatform.disconnectDevice(id)`（`:74`、`rx_ext/repeater.dart` 的 `detach`）。
在 plugin 這邊：

- `timestampEstablishConnection` 是在失敗那一刻的 `doOnNext` 裡寫入的（`DeviceConnector.kt` 的 `establishConnection`）；
- `disconnectDevice` 距離它不到 `minTimeMsBeforeDisconnectingIsAllowed = 200` ms，
  所以會在 `Single.timer(200 - diff)` 之後才 `sendDisconnectedUpdate(deviceId)`；
- 這則更新走的是共用的 `connectionUpdateBehaviorSubject`；
- `ReactiveBleClient.disconnectDevice` 會立刻把 connector 移出 `activeConnections`，所以新的 connect 拿到的是新的 connector，
  但舊 connector 的計時器還會照樣送出。

設計要求在 ≤ 0.1 s 內重連，正好落在這個大約 200 ms 的窗口裡，後果有兩條路：

1. 新的 connect 串流會看到這則沒有失敗碼的 `disconnected`，於是 `false` → `noResponse`。結果在 log 上看起來就像又一次快速失敗，
   只是沒有 `fail=` 那一行。
2. 即使沒走到第 1 條，gate 的 `linkStates` 監聽也會對同一位址的新連結執行 `_downNow()`（`ble_gate.dart` 的 `BleGate` 建構子）。
   之後 `_usable` 會拒絕所有 GATT 呼叫，所以就算連上了，probe 也會失敗。

證據：這個專案自己的 `329-ble-settle.md:31` 和 `:62`，就是把「同一位址至少隔 6 s（`p.gap`），走不到這個約 200 ms 的窗口」
當成成立前提；`connect_fail_test.dart:28-52` 的 `FailRadio.staleFalse` 和 `staleHits`，也正是在模擬這件事
（`:254-262` 證明 200 ms 內重連會拿到那個 false）。本設計拿掉了這個不變量，卻完全沒有提到。
§7 的裝置驗收結果會是「重試和第一次一樣失敗」，而設計會把它解讀成「前提錯了，停止」。也就是說，這是把 plugin 的副作用誤判成射頻上的事實。

修正：

- 重試不早於「失敗事件之後 ≥ 400 ms」（200 ms 計時器，加上 computation thread 和 platform channel 的延遲）；
  或者等到 `linkStates` 上出現該位址、晚於 `close()`、沒有失敗碼的 `disconnected`，並設上限（例如 500 ms）。
  所有「再檢查一次」（cancel、budget、`identical(_attempt, a)`、lease、disposed）都放在這段等待**之後**，
  而且再檢查和 `gate.connect` 之間不能有 await。
- T1 必須使用 `FailRadio.staleFalse`。負向對照：等待改成 0 → `staleHits ≥ 1`，T1 FAIL。
- §7 的「≤ 200 ms 內出現第二次 connect」改成「在 [等待, 等待 + 100 ms] 之內」。
- 裝置上要加一行 trace，記錄重試窗口中看到的沒有失敗碼的 down，證明過期事件確實落在等待之內。
- 這個等待時間仍然遠小於今天的大約 8 s，不影響設計的目的。

### M1 MAJOR：重試窗口中 `_link` 的值沒有寫清楚，接管 (a)／(b) 會因此改變行為

情境：使用者在「失敗 → 等待 → 第二次 connect」的窗口裡打開這個節點的頁面。`setPage` 只有在 `_link != null` 時才會分離
（`node_link.dart:331`），`acquire(forNode)` 也一樣（`:389`）。

- 如果實作沿用現有尾段的 `if (identical(_link, mine)) _link = null`（`:1088`），或在 close 第一條連結時把 `_link` 清空，
  這段窗口裡的接管就會變成中止：`_pump` 會因為 `core.running != a` 而 `_abort`。
  使用者因此失去這次讀取，還得從頭登入。
- §4 只寫了「`_link` 指向目前的連結」，沒有寫窗口期間的值。加上 B1 的修正後，這段窗口會更長（≥ 0.4 s）。

修正：

- 明寫「`_link` 保持指向第一條連結，直到被第二條取代，中間不設成 null」。第二條連結的 `mine` 也要跟著更新，
  才能讓尾段只關閉自己的連結。
- 加兩個測試：
  - 窗口內打開頁面 → `_det == a`，重試照常進行，讀取以 keptRead 進入目前的輪；
  - 窗口內 `acquire(forNode)` → 等到結束，拿到 kept link。
- 負向對照：在窗口中把 `_link` 設成 null → 第一個測試 FAIL。

### M2 MAJOR：裝置驗收的量測工具和覆蓋範圍不足以支撐結論

1. `a4stats.py`（`Desktop/Batman/a4/a4stats.py:7`，不在 repo 內）只解析 attempt 行。重試成功後
   `connected=` 改成從第二次 connect 起算，原本那次快速失敗就從 `fast-failures` 消失，變成一次普通的成功。
   這個腳本既不認得 `retried`，也不認得 retry 行，所以 §7 的「每次快速失敗後幾 ms 有第二次 connect」「重試成功率」
   「從失敗到讀到的中位數和最差值」都算不出來。
   - 要改：腳本納入 repo；配對 `fail=133`、retry 行、attempt 行；找不到任何 retry 行時要 FAIL（使用者規則：空結果不算通過）。
   - 建議：attempt 行另外帶從 t0 起算的 up 時間，避免 `connected=` 的語意悄悄改變。
2. 這兩份 logcat 裡沒有任何 `loginFor` 行。`_lfAttempt` 那一處沒有任何快速失敗的資料，§7 的裝置驗收（a4cycle）
   也只跑 NodeLink 的輪。這個修改宣稱兩處都適用，裝置上只驗證了一處。
   要嘛加上 login 路徑的裝置驗證，要嘛在 PR 裡明確標成 ⚠️「只有單元測試」。
3. 樣本：基準快速失敗率大約 16/298 ≈ 5%，`a4cycle.sh 40` 可能只出現 2–5 次。以「≥ 3 次、成功 ≥ 2/3」來判定太弱；
   建議 ≥ 8 次，必要時合併多次執行。

### m1 MINOR：Bluetooth 關閉的事件順序是假設，沒有證據

那一列寫的是「輪被取消 → 不重試」，前提是 `radio(bluetooth:false)` 比連線失敗先到。實際上 Android 關藍牙時，
連線失敗事件可能先到（不同的 platform channel，順序沒有保證），結果會多一次對正在關閉的 adapter 的 connect。
之後 `radio()` → `_pump` → `_abort` 會關掉它（`_wanted` 需要 `core.blocked == null`），所以無害。
修正：該列改寫成「不重試，或重試後被 `radio()` 中止」；T5 兩種順序都要測。

### m2 MINOR：§6「不多佔射頻時間」的說法不完整

每次 attempt 的時間仍受 8 s 限制，但同一位址每輪最多可能有 `perAddr`（2）× 2 = 4 次 connect（`core.dart:12`、`:454`）。
附近的惡意裝置可以讓每次 attempt 都消耗兩次 connect，不過仍在同一個 8 s 預算之內，所以不是新的放大。
修正：把這點寫進 §6。

### m3 MINOR：§2 第 2 步沒有寫明順序

應寫成「await close → 等待（B1）→ 檢查 → 同一個同步段落裡 `gate.connect` 並寫入 `_link`」，避免實作在檢查之後又插入 await。

### m4 MINOR：§4 的 Ownership 漏列資源

漏了 plugin 每個位址一個的 connector（`activeConnections`）和它的 200 ms 延遲斷線計時器。
這正是 B1 的根源，應該列成「外部、唯讀、我們必須避開的資源」，並附上證據（`DeviceConnector.kt` 的 `disconnectDevice`）。

## Lifecycle 補充

- install、upgrade、downgrade、crash：同意，只在記憶體中，沒有狀態。
- 背景化、dispose、lease 在窗口中被拿走：只要按照 m3 的順序，現有的檢查就涵蓋得到（`background` → `core` 取消 → `_pump` → `_abort`）。
- iOS：不建置，n/a。

## 安全

沒有新的輸入；trace 只帶遮罩過的末 2 碼和末 4 碼；不涉及機密。只有 m2。

## Verdict：REJECT

B1 讓設計的核心機制（≤ 0.1 s 立刻重連）在這個 plugin 上會被自己觸發的過期事件打掉，裝置驗收也會因此得出錯誤結論。
修正方向明確（失敗後等待 ≥ 400 ms，或等到該位址沒有失敗碼的 down 事件，再檢查、再連），改完後連同 M1、M2 再審一次整份文件。
