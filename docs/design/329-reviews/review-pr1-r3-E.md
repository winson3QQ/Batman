# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 70209ef）第三輪程式審查：審查 E

範圍：整個 PR（core.dart 只看使用它的地方）。重點：實際使用與生命週期、假物件和真平台的差異、舊頁面的 `RawBusy` / `openRawPage`、main.dart 接線。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、1 MAJOR、6 MINOR。

機制層（lease、RawBusy fail-closed、RawLeaseScope、prober 的 msg2 定義、gate）這輪的修正都有能 FAIL 的測試（E11、E12、E13、E17 都被抓到）。但第二輪 C-M1 只關了一半：NodesPage、ScanPage、main.dart、AppLink 的接線，16 個改壞裡有 12 個全套照樣 409 PASS，其中包括第一輪 B-M1 修正本身（E2）。

## 基準（✅ 已驗證）

- 匯出：`git archive 70209ef app | tar -x`（沒有複製工作目錄），另外補上 `.dart_tool/package_config.json`、`package_graph.json`。
- `flutter test --no-pub`：`00:20 +409: All tests passed!`
- bridge `cargo test`（WSL Ubuntu-24.04，自己的 CARGO_TARGET_DIR）：
  - 第一次跑：58 passed、4 failed。四個 panic 都在讀 `../../../tests/vectors/219-protocol/vectors.json`，例如 claim.rs:640、rekey.rs:560、replay_node.rs:46。
  - 歸因（flip test）：只多匯出 `tests/vectors/219-protocol`，其他不變，再跑：`test result: ok. 62 passed; 0 failed`。所以那 4 個 FAIL 是我只匯出 `app/` 造成的，和這個 PR 無關。

## 我做的改壞對照（一次只改一處，跑全套 `flutter test --no-pub`，原始輸出在 `scratchpad/core/pr1E/out/E*.txt`）

| # | 改壞 | 對使用者的後果 | 結果 |
|---|---|---|---|
| E1 | nodes.dart `_login` 的 finally：`rawIdle()` 改成 `if (mounted) rawIdle()` | 登入中按返回：佔用撐 420 s，自動讀取停 7 分鐘，每個按鈕都顯示「另一個操作還在進行：我的節點」，最後多一筆假的待辦 | ❌ 409 PASS |
| E2 | 拿掉 nodes.dart:399-402 `if (ok && !mounted) { await _drop(); return; }`（第一輪 **B-M1 的修正本身**） | 頁面關掉後登入才成功：連線永遠留著，節點不廣播，NodeLink 一直顯示「連不到」，直到 app 重開 | ❌ 409 PASS |
| E3 | 拿掉 nodes.dart 登入的 `rawScanStarted()` | 舊頁面的掃描不算進 4 次 / 30 s | ❌ 409 PASS |
| E4 | scan.dart `_read` 結尾改成 `if (mounted) rawIdle()` | 同 E1（附近的節點頁） | ❌ 409 PASS |
| E5 | 拿掉 scan.dart 的 `rawScanStarted()` | 同 E3 | ❌ 409 PASS |
| E6 | main.dart：`NodesPage(ble: a?.ble, use: null)` | 我的節點頁沒有佔用：NodeLink 和頁面同時用藍牙（第一輪 A-M1 本身） | ❌ 409 PASS |
| E7 | main.dart：拿掉 `a.link.radio(keyOk: keys.login)` | 登入金鑰不能用時，第一次失敗之前顯示的是「找不到」 | ❌ 409 PASS |
| E8 | main.dart：拿掉 `_app = a;` | 首頁清單消失；三個舊頁面全部沒有佔用，和 NodeLink 同時用藍牙 | ❌ 409 PASS |
| E9 | app_link.dart：拿掉 `addObserver(_Life(link))` | 背景照讀；鎖屏 30 分鐘前的綠燈回來時算新鮮（設計 §4.3.2 的 B-M2） | ❌ 409 PASS |
| E10 | app_link.dart：拿掉 `wireRadio(...)` | 藍牙關閉時顯示「連不到」，不是「藍牙沒有打開」 | ❌ 409 PASS |
| E11 | raw_use.dart：`hold()` 的例外吞掉（fail-open） | — | ✅ FAIL：`r2 D-3` |
| E12 | `pageGone` 從 `RawLeaseScope.dispose` 移回 push 回傳之後 | — | ✅ FAIL：`r2 C-m2 / D-10` |
| E13 | prober：任何一個 frame 就算 msg2 | — | ✅ FAIL：`r2 D-2` |
| E14 | claim.dart：拿掉 `ReactiveRecoveryBle(..., onScan: rawScanStarted)` | 恢復的掃描不算進 4 次 / 30 s | ❌ 409 PASS |
| E16 | app_link.dart：拿掉 `keyError: (e) => keyErrorToRadio(...)` | 金鑰被拒時顯示「連不到」，不是 2.4 | ❌ 409 PASS |
| E17 | claim.dart `_claim` 的 finally 改成 `if (mounted) rawIdle()` | — | ✅ FAIL：`A-M1 real page` |

## 發現

### MAJOR

**E-M1：第二輪 C-M1 只關了一半。NodesPage、ScanPage、main.dart、AppLink 的接線，任何一行改壞，全套照樣全過；其中包括第一輪 B-M1 的修正本身**

- 情境：見上表 E1–E10、E14、E16。C-M1 的修法第 1 點寫「NodesPage 的 `_login` 也一樣做一次」，第 2 點寫「`_open` 可測（或在 StartupCheck 測試裡注入 `makeLink`）」。這輪只做了 ClaimPage（`claim_flow_test` 的 `A-M1 real page`）和 `openRawPage` 本身。
  - E2：B-M1 是宣稱已修的 MAJOR，守它的那幾行被拿掉，沒有任何測試 FAIL。
  - E6、E8：main.dart 把錯的（或沒有）`RawUse` 交給頁面，A-M1 整個回來，仍然全過。
  - E9、E10、E16：`AppLink.create` 有沒有接上生命週期、狀態流、金鑰錯誤，沒有任何測試在看。抽出來的 `wireRadio` / `keyErrorToRadio` 有測試，但呼叫它們的那一行沒有。
- 證據：
  - 上表，每個 ❌ 的輸出最後一行都是 `All tests passed!`（`out/E1.txt` … `out/E16.txt`）。
  - 補這種測試不難。我寫了 `scratchpad/core/pr1E/mytests/review_r3E_test.dart` 的 `E-1`：
    - 做法：用 `openRawPage` 打開真的 `NodesPage`，點節點開始登入（登入卡在 `keyLevels` 平台呼叫），按返回，斷言佔用還在；讓登入結束，斷言佔用立刻釋放。
    - 70209ef：PASS。
    - 套上 E1：FAIL，`Expected: null  Actual: <Instance of 'Lease'>`，原因是「the login ended after the pop: released at once, not 420 s later」。
- 為什麼是 MAJOR：守宣稱已修的 MAJOR（A-M1 / B-M1 / A-M3 / B-M5）的測試，在修正被拿掉時不會 FAIL。這違反全域規則「每個修正要有負向對照」。而這一層正是 PR 2 / PR 3 會重寫的地方。
- 修法：
  1. 把 `E-1` 收進去。
  2. 加一個 B-M1 測試：登入在 pop 之後才成功，斷言 `_conn` 被取消；假的 BLE 的 connect stream 被 cancel 了沒有，可以直接看。
  3. ScanPage `_read` 加一個同樣的測試。
  4. 加一個 StartupCheck widget 測試：注入一個假的 `makeLink`，例如讓 `AppLink` 可以從 `(ble backend, status stream, binding)` 建出來。斷言三個按鈕打開的頁面都拿到 `RawUse`；`NodeStatusList` 有出現；lifecycle、狀態流、`keyError` 會傳到 `NodeLink`。
  5. 每一項附上對應的 E 號負向對照。

### MINOR

**E-m1：NodeLink 建立時不看 app 目前的生命週期狀態。啟動檢查期間就離開 app 的話，NodeLink 在背景照讀，回前景時也不會標成不新鮮**

- 情境：
  - `core.fg` 預設是 true（core.dart:120）。
  - 生命週期的監聽在 `AppLink.create` 時才加上（app_link.dart:84）。
  - main.dart:137-139 接著就 `start(Page.home)`。
  - 使用者打開 app、在啟動檢查跑的 1–2 s 內按電源鍵或 HOME：`paused` 發生在監聽加上之前，NodeLink 不知道。所以會發生兩件事：
    - 在背景掃描、連線；
    - 回前景時，`foreground()` 因為 `if (fg) return`（core.dart:209）什麼都不做，讀取也沒有被 `background()` 標成不新鮮。
  - 結果和設計 §4.3.2 要防的一樣：深度休眠時單調時鐘不走，30 分鐘前的綠燈可能被當成新鮮。
- 證據：`review_r3E_test.dart` 的 `E-2`，照 main.dart 的順序在「已經在背景」時呼叫 `start`：`Expected: <0>  Actual: <1>`，也就是掃描了。
- 窗口：只有啟動檢查那 1–2 s。第一次安裝要建金鑰，窗口比較長，不過那時還沒有紀錄。
- 修法：`start` 之後呼叫 `a.link.lifecycle(WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed)`；或者讓 `start` 收目前的狀態。

**E-m2：拿佔用最多等 5 s，畫面沒有任何回應；這期間再點一次，會看到「另一個操作還在進行：我的節點」，而它就是使用者自己剛點的那一個**

- 證據：
  - 設計 §4.4「拿到之前」一列要求「期間畫面顯示『正在結束上一個讀取…』」，PR 1 沒有做。
  - main.dart:66-81 的 `_open` 在 `await openRawPage` 期間不改任何狀態。
  - node_link.dart:147-153：兩個同時的 `acquire` 都會通過開頭的 `reg.current != null` 檢查，都會等 `_dropAll`。後到的那個在 `reg.acquire` 拿到 null。
  - raw_use.dart:214 回傳 `reg.current?.name`，也就是先到的那個的名稱。
  - 這個等待真的會發生：使用者點下去的時候，NodeLink 剛好在連線中。
- 修法：在 `_open` 等待期間顯示那一行，按鈕先停用；或者後到的同名要求就不提示。也可以寫進 #329 的殘項。

**E-m3：`BleGate` 在藍牙關閉或沒有權限時不會拒絕掃描與連線，設計 §7 與 T-L5 都要求它拒絕；這一點沒有列在偏離清單裡**

- 證據：
  - 設計 329-app-uiux.md:837 寫「`BleGate` 在權限沒了的期間拒絕新的掃描與連線」；:924 T-L5 寫「拿掉 `BleGate` 的權限檢查 → FAIL」。
  - ble_gate.dart:168-173 的 `_gate` 只看 token，沒有權限與藍牙檢查。
  - review_pr1_test.dart:179 的 `T-L5` 只測 `bleStatusToRadio` 與 core 的 `blocked`。
- 影響：現在只有 NodeLink 走 gate，而 core 在前提不成立時不開輪（core.dart:161 加上 `blocked`），所以使用者碰不到。這是一層縱深防禦，到 PR 3 才有別的使用者。
- 修法：加這個檢查與測試；或者在 PR 說明的「和設計不同的地方」與 #329 殘項各寫一行。

**E-m4：PR 說明列了偏離，#329 的「實作殘項」沒有列**

- 這些縮掉的範圍只寫在 PR 說明：
  - 舊頁面不走 `BleGate` / `RecordWriter`；
  - 所以 T-G5 的原始碼鎖（`storeWriteCas` 等只能出現在 `RecordWriter`）在 PR 1 不存在；
  - 420 s 收回之後，舊頁面的工作 gate 擋不住；
  - E-m2、E-m3。
- 證據：`gh issue view 329` 裡搜 `RecordWriter|420|BleGate|正在結束`，沒有任何結果。
- 依使用者的規則「PR 縮範圍必進原單 checklist」，這些要寫進 #329 的殘項，並註明 PR 3 / PR 6 的哪一個來解決。

**E-m5：殘項「B 組真機量：從沒連上就被取消的連線，Android 會不會送 disconnected」大部分可以從原始碼回答，真正要量的是另一件事**

- 證據（⚠️ 原始碼推論，沒有上機）：
  - reactive_ble_mobile 5.6.0 的 `connectToDevice` 經 `getConnection` → `activeConnections.getOrPut(deviceId)` 建一個 `DeviceConnector`（ReactiveBleClient.kt:105-110、:281-290）。
  - Dart 端 cancel 時呼叫 `disconnectDevice`（device_connector.dart，`onCancel: _blePlatform.disconnectDevice(id)`）。
  - `DeviceConnector.disconnectDevice` 一律送 `DISCONNECTED`，連上不到 200 ms 時延後到 200 ms（DeviceConnector.kt:63-84）。從沒連上也一樣送。
  - 所以「每次沒有回應多等 5 s」大概不會發生。
  - 但這個 `DISCONNECTED` 是在 `disposeSubscriptions()` **之前**送的（:72-79）。gate 的「斷線完成」其實是外掛層面的，不等於 GATT 已經關閉。緊接著舊頁面立刻連同一台或另一台，有沒有 status 133 之類的失敗，才是 B 組該看的。
- 修法：改寫這條殘項的內容。

**E-m6：ScanPage `_read` 的忙碌檢查與設定之間有 await，而且沒有 try/finally（開發用頁面）**

- 證據：
  - scan.dart:81 先檢查 `if (_busy) return`，:82 `await _stop()`，:83-86 才設 `_busy = true`。這段時間點另一台就會開出第二條連線；先結束的那條呼叫 `rawIdle()` 把 hold 放掉，第二條還在連。
  - :87-123 沒有 try/finally：`conn.cancel()` 丟例外時，`rawIdle` 不會執行。頁面關掉之後，佔用會撐到 420 s。
  - 兩者都是原本就有的寫法，但現在牽涉到佔用。
- 修法：檢查之後立刻設 busy；結尾放進 finally。

## 先前的發現是否已關

| 發現 | 狀態 | 依據 |
|---|---|---|
| C-M1 | **一半**（→ E-M1） | ClaimPage、`openRawPage`、`wireRadio` / `keyErrorToRadio` 函式有測試；NodesPage、ScanPage、main、AppLink 呼叫端沒有 |
| C-m1 / D-1（清零） | 改成殘項，可以接受 | 平台給的是唯讀緩衝區（nodes_zero_test.dart:1-5 也記載）；app 裡其他打開的紀錄也一樣靠 GC |
| C-m2 / D-3 / D-10 | ✅ 已關 | E11、E12 都被抓到 |
| C-m3 / D-5 | ✅ PR 說明已改成「PR 1 沒有畫面顯示待辦」 | — |
| C-m4 / D-7 | 有新測試（`r2 X12 / X9`、`r2 X13`） | ⚠️ 我沒有另外做改壞對照 |
| C-m5 | 殘項 F41，可以接受 | 認領最多約 300 s，在 420 s 以內（C 的計算） |
| C-m6 | ✅ NodeLink 已關（node_link.dart:253-256、:327-333） | `BleGate` 仍然沒有把自己從 `reg.listeners` 移除；它是單例，不影響 |
| D-2 | ✅ 已關 | E13 被抓到 |
| D-4（X26） | 殘項，可以接受 | 金鑰前提變 false 之後，要重開 app 才恢復 |
| D-9 | ✅ 設計 §4.4 已改成「原始佔用的頁面」一列 | — |

殘項判斷：五條都可以留到後面。第 4 條請照 E-m5 改寫內容。缺的那幾條見 E-m4。

## 生命週期（端到端）

- **啟動**：見 E-m1。啟動失敗時（main.dart:141-145），頁面在沒有佔用的情況下打開，各自建新的 `FlutterReactiveBle`（`a?.ble` 是 null）。
  - 如果失敗發生在 `core.startup` 之後（`_pump` 丟例外），NodeLink 已經在跑，舊頁面卻沒有佔用。這只是推論出來的極端情況，我沒有重現。
- **背景 / 前景 / inactive**：映射正確（node_link.dart:124-133，T20 測試）。前提是監聽在場；E9 改壞沒有被抓到，見 E-M1。
- **佔用頁關掉、工作進行中**：機制正確（lease.dart:58-81）。ClaimPage 有真頁面測試。NodesPage 我用 `E-1` 補驗，✅ PASS。
  - 420 s 之後頁面的工作不會被停下，這是 PR 說明裡宣告的缺口。
  - 舊頁面最長的單一請求是 `joinWait` 360 s（member_ui.dart:231），而 `_kick` 每次寫入都會重新計時。所以 pop 之後真的有可能超過 420 s，例如加入進行中。後果是 NodeLink 開始掃描，同時舊頁面還連著那台節點；那台不廣播，所以 NodeLink 碰不到它。
- **藍牙關閉、權限收回**：藍牙關閉走 `statusStream`。權限被收回時 Android 會結束 app 的行程，回來就是重新啟動；`unauthorized` 是啟動時的狀態。第一次安裝在使用者按舊頁面之前沒有權限，清單會顯示「app 還沒有藍牙權限」，PR 1 沒有能按的按鈕（2.2 在 PR 2）。
- **深度休眠與計時器**：Dart 的 `Timer` 與 `Stopwatch` 都用單調時鐘，兩者一致。背景時取消一輪並標成不新鮮，這是正確的做法；前提是有收到 `paused`（E-m1）。

## 假物件與真平台的差異（S20 唯讀緩衝區那一類）

- 唯讀緩衝區：nodelink 底下沒有任何 `fillRange`、`setAll`、`setRange`，或寫入平台回傳 list 的地方。✅ 我 grep 過 prober.dart、node_link.dart、ble_gate.dart、app_link.dart。
- `connectToDevice` 的 stream 在第一個 `disconnected` 之後就結束（device_connector.dart，`takeWhile`）。gate 的 `onDone` 會呼叫 `_on(false)`，有處理到。
- 一個 `FlutterReactiveBle` 開新的掃描時，會 dispose 前一個掃描的 repeater（device_scanner.dart，`_scanStreamDisposable.set`）：前一個掃描會默默停掉。所以「同一時間一個掃描」除了 Android 的限制，外掛本身也要求。佔用的設計剛好避開了它，只有 420 s 之後的缺口會碰到。
- GATT 操作走外掛的 `getConnection(deviceId)`，它用 `getOrPut`：如果裝置沒有活著的 connector，**讀寫會自己建一條新連線**（ReactiveBleClient.kt:281-290）。gate 在 `close()` 一開始就同步設 `_open = false`（ble_gate.dart:108-109），所以關閉之後 NodeLink 的晚到步驟會被擋下，✅。舊頁面不受 gate 保護。
- `FakeSession.requestStatusPage` 正常回傳；真的 Rust 在 Err 時丟 String，`run` 的 `catchError` 把它變成 broken，結果一樣。`FakeSession.signed` 回 null，真的會回一個寫入的 step，測試沒有覆蓋「簽完之後送出 auth」這一段，但 prober 對兩者的處理方式相同。

## 安全（逐個角色）

- **附近惡意的 BLE 裝置**：
  - 它造不出 `Res.body`。
    - `Answer` 只會在 `St::Conn` 出現（owner.rs:823-827 之後）。
    - 要進 `St::Conn`，需要 loginflow 的 `LoggedIn`（loginflow.rs:139-149）。
    - 要走到那一步，msg2 必須用紀錄裡的金鑰解得開，而且憑證要對上 pinned 的那一個（loginflow.rs:160-171）。
  - `certRejected` 也需要解開 msg2，所以只有持有節點金鑰的一方能觸發。
  - 它能做到的：
    - 每個位址拖到 8 s，或拖到 msg2 之後的 20 s；
    - 換位址拖延一輪，T14 已經知道這件事。
- **其他 app**：沒有新的 intent 或埠。別的 app 連著節點時，節點不廣播，畫面文字已經涵蓋這個原因。
- **被入侵的節點**：
  - 可以報任何顏色，這是本來就有的信任。
  - msg2 之後最多拖 20 s，計時器不會因為收到 frame 而重設（prober.dart:264-267）。
  - 讀取中出現任何寫紀錄的 step，都會被放棄（prober.dart:226-230）。
- **我們自己的錯**：接線層沒有測試保護，見 E-M1。

## 我寫的東西（都在 scratchpad，沒有 commit）

- `scratchpad/core/pr1E/mut.sh`、`runall.sh`：改壞腳本。`out/E*.txt` 是原始輸出，`out/summary.txt` 是摘要。
- `scratchpad/core/pr1E/mytests/review_r3E_test.dart`：
  - `E-1`：負向對照已驗證，70209ef PASS，套上 E1 FAIL；
  - `E-2`：證明 E-m1 的特性測試，在 70209ef 上 FAIL。
