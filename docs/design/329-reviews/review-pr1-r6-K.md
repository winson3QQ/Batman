# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 73e87cc）第六輪程式審查：審查 K

範圍：整個 PR（`core.dart` 只看新程式怎麼用它）。重點：從實際使用出發的端到端生命週期；使用者依賴的每條規則有沒有能 FAIL 的測試（自己做改壞，接線也算）；第五輪的修正有沒有弄壞別的東西：
- `dispose` 把等待中的請求以「結果不明」結束；
- `acquire` 收回 NodeLink 的 token；
- gate 的 stop / close 順序。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、0 MAJOR、3 MINOR。

- 第五輪的修正都有能 FAIL 的測試（K01–K07、K09，見下表），I-M1 / I-m1 / I-m3 / J-m1 / J-m2 / J-m5 都關了。
- 但 I-m1 的修法（`dispose` 立刻結束等待）開了一個新缺口，我用真頁面測試重現了：建立網路 / 加入網路等流程「寫紀錄」那一步還在跑時按返回，紀錄會在佔用交回之後才寫進去（K-m1）。
  - 負向對照：拿掉第五輪那一行，同一個寫入就落在佔用之內。
  - 修法很小，我試過的草稿全套 428 PASS。
- 開發版的貼上流程（貼上更新包 / 同意碼 / 隊員申請）寫紀錄時本來就不持有佔用，同類問題，不是這輪造成的（K-m2）。
- A13 與 B 組真機量測是合併條件，照指示不算發現。

## 基準（✅ 已驗證）

- 匯出：`git -C C:/src/Batman-329pr1 archive 73e87cc app tests | tar -x`，放在 `scratchpad/core/pr1K`。`.dart_tool/package_config.json`、`package_graph.json` 另外複製，沒有複製工作目錄。
- `flutter test --no-pub`：`00:19 +427: All tests passed!`
- `flutter analyze --no-pub lib test`：`1 issue found`（`member_ui_test.dart:4` 的 info，原本就有）。
- 每次改壞後都還原。最後對 `git ls-tree 73e87cc app/lib app/test` 的 62 個檔案逐一 `cmp`：`files=62 diff=0`；我自己的測試已移出 test 目錄。
- Rust：`git diff --stat 87d4e83 73e87cc -- app/rust` 是空的，owner.rs 和 frb glue 從第五輪之後沒變。⚠️ 我這輪沒有重跑 `cargo test`（第五輪 I 在 87d4e83 上 `62 passed`）。

## 我做的改壞（一次改一處，跑全套 `flutter test --no-pub`）

工具：`scratchpad/core/pr1K-tools/mut.sh`。每一項的 diff 與完整輸出在 `pr1K-tools/out/K*.diff`、`K*.txt`。

| # | 改壞 | 結果 | 抓到的測試 / 備註 |
|---|---|---|---|
| K01 | nodes.dart:149-150 `dispose` 不結束 `_answer`（還原 I-m1 修正前） | ✅ FAIL | `nodes_pop_test: r5 I-m1 / I-m3` |
| K02 | nodes.dart:518 拿掉 `if (!mounted && !held) return null;` | ✅ FAIL | 同上。注意：抓到它的是 debug 版的 `setState() called after dispose()`（`_login` :365），不是測試自己「沒有再送 frame」的斷言。release 版沒有這個 assert，但 `hold()` 對已釋放的佔用丟 `StateError`，一樣不送（第五輪 I-m3 已分析）。可以接受 |
| K03 | node_link.dart:161 拿掉 `gate.revoked(mine)` | ✅ FAIL | `review_pr1_test: r5 J-m1` |
| K04 | ble_gate.dart `GateScan.stop` 改回先 `cancel` 再 `_scans.remove` | ✅ FAIL | 同上（`BleGate refused: a scan is already running`） |
| K05 | `GateScan.stop` 拿掉 try/catch | ✅ FAIL | `r5 J-m2` |
| K06 | `GateLink.close` 拿掉 catch | ✅ FAIL | `r5 J-m2` |
| K07 | claim.dart:478 `ReactiveRecoveryBle(_ble)`（拿掉 `onScan`，第五輪 I05 / G22） | ✅ FAIL | `claim_replay_page_test: r5 I-M1` |
| K09 | nodes.dart:403 `if (ok && !mounted)` → `if (false)`（B-M1） | ✅ FAIL | `nodes_update_send_test: r3 E-M1 … popped mid-login` |
| K-1 | 我寫的真頁面測試：建立網路的 `seal` 還沒回來時按返回 | **❌ 原始碼上寫入落在佔用之外** | → K-m1；負向對照見下 |
| K-2 | 我寫的真頁面測試：貼上更新包的 `ecdh` 還沒回來時按返回 | **❌ 寫入落在佔用之外** | → K-m2 |

## 發現

### MINOR

**K-m1：第五輪 I-m1 的修法讓「寫紀錄」那一步可以在佔用交回之後才落地。流程是「我的節點」的建立網路、加入網路、申請加入、加入隊伍網路（`persistNet` / `persistPend` / `persistMnet`）**

- 情境：
  1. 使用者按「建立網路」。Rust 走到 `persistNet`：nodes.dart:254-270 先 `_track.persisted()`，再 `await seal`（Keystore），再 `await storeWriteCas`。
  2. 這時按返回。`dispose`（nodes.dart:149-150）立刻把 `_answer` 完成成「結果不明」。
  3. `_ask` 從 `await _answer!.future` 回來，走 finally → `rawIdle()` → `hold` 結束。頁面已經 `pageGone`，佔用就交回（lease.dart:66）。NodeLink 收到 `released`。
  4. 但 step loop 還在 `seal` / `storeWriteCas` 裡，它沒有持有佔用。`seal` 回來後 `storeWriteCas` 照寫。寫完才在下一圈的 `gone()` 停下（不送 frame）。
  - 另一條同樣的路：`_drop()` 在兩個 `await` 之後才把 `_session` 設成 null（nodes.dart:172-179）。在這之前，inbox 裡已經緩衝的 frame 仍會被 `asyncMap` 處理，`gone()` 是 false，所以也可能走到一個 persist 步驟。
- 證據（✅ 實跑，真的 `NodesPage` + `openRawPage` + 假 BLE 平台 + 把 `seal` 卡住）：`pr1K-tools/k_persist_pop_test.dart`。
  - 73e87cc：
    ```
    K-1 after pop, before the seal returns: lease=null
    K-1 cas: [net/abab…ab:NO LEASE]; frames: [1, 40]
    ```
  - 負向對照 K00（只拿掉第五輪 dispose 那一行）：
    ```
    K-1 after pop, before the seal returns: lease=我的節點
    K-1 cas: [net/abab…ab:我的節點]; frames: [1, 40]
    ```
    這次測試因為那個 360 s 計時器還在而 FAIL，那正是 I-m1 原本的問題。
  - 所以這是第五輪才出現的：之前佔用要等 360 s 等待結束才放，寫入一定在佔用之內。
- 為什麼只是 MINOR：
  - 這個窗口只有 `seal` + CAS 的時間（毫秒級）。
  - NodeLink 只讀 `node/*`。這裡寫的是 `net/` / `mpend/` / `mnet/`。
  - 下一個持有者要寫同一筆紀錄時，CAS 會拒絕（「紀錄已被別處更新」）。
  - 所以使用者看不到錯的結果。但這破壞了 §4.4 的契約「一次一個操作用藍牙、寫紀錄」：只有現在的持有者能寫。PR 說明第 31 行「同一時間仍然只有一個藍牙使用者、一個寫入者」也就不成立了。
- 修法（✅ 我試過）：persist 步驟自己持有佔用，直到寫入落地。在 nodes.dart:254 `_track.persisted();` 之後：
  ```dart
  final keep = rawUse?.lease.hold();
  try { …seal + storeWriteCas… } catch … finally { keep?.call(); }
  ```
  - 結果：K-1 變成 `lease=我的節點`、`cas: [net/…:我的節點]`；全套加上 K-1 共 `+428: All tests passed!`（`pr1K-tools/out/KFIX.txt`）。
  - 正式修時，`hold()` 要放進 try 裡面：佔用已被收回時 `hold()` 會丟例外，應該變成 `persistFailed`，不寫。
  - 把 K-1 收進 `nodes_pop_test.dart` 當回歸測試（負向對照：拿掉 `hold` → `NO LEASE`）。

**K-m2：開發版的貼上流程寫紀錄時不持有佔用（不是這輪造成的）。這幾個流程是 `_takeUpdate`（貼上更新包 → `mnet/`）、`_checkRequest` → `_runOp`（同意 → `net/`）、`_takeApproval` → `_importApproval`（同意碼 → `mnet/` + 刪 `mpend/`）、`_makeInvite` 以外的 `_paste` 入口；頁面在 `ecdh` / `seal` 途中被關，寫入就落在佔用之外**

- 情境：這些入口都是 `PasteButton` → 直接呼叫，沒有 `_holding` / `_busy`（nodes.dart:733、:1438-1490、:807-839、:979-1015）。
  - 頁面還在時，佔用一直在，沒有問題。
  - 在 `ecdh` / `signAdmin` / `seal` 途中被關（先關 SAS 頁再關「我的節點」，或貼上更新包後馬上返回）：`pageGone` 看到 `_busy == 0`，立刻交回；之後 CAS 才寫。
- 證據（✅ 實跑）：`pr1K-tools/k2.dart`，把 `ecdh` 卡住，貼上更新包，按返回：
  ```
  K-2 after pop, ecdh pending: lease=null
  K-2 cas: [mnet/abab…ab:NO LEASE]
  ```
- 為什麼只是 MINOR：只有開發版才走得到（`devTrust`，field 版三層都拒絕）；窗口很短；有 CAS。前五輪的報告都沒有提到這條。
- 修法：
  - 和 K-m1 一起：`_writeRecord` 與 persist 步驟共用一個「寫入時持有佔用」的小函式；
  - 或把這幾個 `_paste` 處理函式包進 `_holding`。
  - 不修的話，寫進 #329 實作殘項，和 F-m6 放在一起（PR 3 / 6 換頁時解決）。

**K-m3：PR 說明與註解的小落差**

- PR 說明第 31 行「同一時間仍然只有一個藍牙使用者、一個寫入者」：K-m1 / K-m2 修好之前不成立。
- 第 65 行「J 審查中」：J 已經完成，第五輪的修正（73e87cc）也已包含 J 的發現，說明沒有更新。
- ble_gate.dart:238 `revoked` 的註解只寫「§4.4 420 s」。現在它也在 `acquire`（收回 NodeLink 的 token）與每次 `released` 時被呼叫。
- 修法：改這三處文字。

## 這輪修正有沒有弄壞東西（逐項）

### `dispose` 結束等待中的請求（nodes.dart:146-153）

我逐一看了按返回時可能還在等的每種請求，以及之後使用者看到什麼、寫了什麼：

| 等待中的請求 | 完成成什麼 | 之後 | 判斷 |
|---|---|---|---|
| 查看狀態 / 設定 / 國家 / Wi-Fi / ssh（`_unclear == null`） | `_waitLine` | `_ask` `a == _waitLine` → `_drop`；只寫 log（頁面不在） | ✅ 和逾時一樣 |
| 把新密碼送給節點（`_sendUnclear`） | `_track.unclearNow`：已送出 → 結果不明；還沒送 → 沒有送出 | 同上；`nodes_pop_test` 守住 | ✅ |
| 建立網路 / 加入網路 / 加入隊伍網路（`_makeUnclear` / `_joinUnclear`） | 同上 | `_joinNetwork` / `_memberJoin` 接著看 `_removedQ`（null）、`_sendAfter`（false），`_watchLink` 因 `!mounted` 直接回 | ✅ 結果正確；⚠️ 寫紀錄那一步見 K-m1 |
| 申請加入（`_joinreqInFlight`、沒有 unclear） | `_waitLine` | `_showRequest`：`_lastHex` 空就回；有答案時剪貼簿照設（原本就這樣），對話框因 `!mounted` 不顯示 | ✅ 和逾時一樣；persistPend 見 K-m1 |
| 加入後的連線檢查（`_watchLink`，`held: true`） | `_waitLine` | `last = _linkUnknown`；`while (mounted…)` 結束；`rawIdle` | ✅ 比之前好：不再撐 120 s |
| 軟體更新（`_askSw`，`_unclear = _swUnanswered`） | `[SW_LOST]` 或「沒有送出」 | `a != _swAnswered` → `_drop` → `sw.lost` | ✅ 但實際走不到：`SwUpdatePage` 的 `PopScope(canPop: !_running)`（swupdate.dart 的 build）在請求進行中擋住返回，而「我的節點」在它下面，關不掉 |
| 國家確認對話框中 | — | 返回鍵先關對話框（`yes = false`） | ✅ 走不到 dispose |
| `_ask` 還在 `_login` 裡（沒有 session） | `_answer` 還是 null，不動 | `_login` 的 `ok && !mounted` → `_drop`；`_ask` 回 `askNoLink`；佔用在 `_login` 的 finally 交回 | ✅（K09 守住） |

- 使用者看到的：頁面已關，那一行只進 logcat，和第五輪之前（360 s 後逾時）一樣。紀錄本身記著狀態（`applied=false` 的 net 紀錄在選單上顯示「建立中」），使用者下次照樣可以「繼續加入」。
- 一個行為差異（不算發現）：之前在加入網路中按返回，佔用撐 360 s，重新打開「我的節點」會看到「另一個操作還在進行」，NodeLink 也不讀。現在 6 s 後 NodeLink 就會登入那台還在套用加入的節點、讀狀態。
  - 這和「頁面還開著時連線斷了，使用者馬上按查看狀態」是同一條已經存在的路（`_lost` → `_ask` 回來 → 使用者再操作），讀狀態是唯讀的。
  - ⚠️ 節點那邊在套用中被登入會怎樣，我沒有上機看。建議 B 組場次順便看一次（不是新的測項，A13 的同一類情境）。

### `acquire` 收回 NodeLink 的 token（node_link.dart:153-163）

- `mine` 在 `_dropAll()` 之後、`reg.acquire` 之前取，這時還沒有佔用，所以一定是 NodeLink 自己的 token。兩個 `acquire` 同時進來時，後到的拿到 `null`，不收回任何東西。
- 它同時補上了另一個縫：`_startScan` 在 `gate.scan` 回傳和 `_scan = s` 之間隔一個 microtask。`_dropAll` 看不到這個掃描（`_scan == null`），以前它會在佔用期間繼續掃描。現在 `gate.revoked(mine)` 會把它關掉，`_startScan` 的 `if (s.open)` 也不會再接手。
- K03 會 FAIL ✅。

### gate 的 stop / close 順序（ble_gate.dart:47-54、:109-129）

- `GateScan.stop` 先把自己從 gate 移除再 `cancel`。新的掃描可以在舊的平台取消完成之前開始。
  - 我查了 reactive_ble 5.6.0：`DeviceScannerImpl.scanForDevices` 一開始就 `_scanStreamDisposable.set(scanRepeater)`，同步處理掉前一個 repeater（`flutter_reactive_ble-5.6.0/lib/src/device_scanner.dart`）。
  - Kotlin 的 `prepareScan` 先 `stopDeviceScan()` 再設參數，`onListen` 才開始掃（`reactive_ble_mobile-5.6.0/.../ScanDevicesHandler.kt:24-36、:66-74`）。
  - 所以兩個掃描重疊時，由函式庫自己收掉前一個。⚠️ 這是讀原始碼的推論，真機沒有量。
- `GateLink.close`：`cancel` 丟例外時一樣在 finally 移除、關 `_state`；`_gone` 的計時器沒有啟動也無妨。
  - 代價：平台斷線失敗時，gate 可能以為沒有連線，而實際還連著。這是有意的取捨：不移除的話，自動讀取會永遠停住（J-m2）。可以接受，建議在註解寫明這是 fail-open 與理由。
- K04–K06 都會 FAIL ✅。

### `LeaseRegistry.token` 改成 `@visibleForTesting`

`lib/` 裡沒有人用（grep 只找到 `reg.token` 在 test 裡）；`flutter analyze` 沒有新警告 ✅。

## 先前發現的關閉狀態

| 發現 | 狀態 | 依據 |
|---|---|---|
| I-M1 認領恢復的掃描計數接線 | ✅ | K07 FAIL（`r5 I-M1: T4 on the real recovery radio`） |
| I-m1 返回後佔用多撐 360 s | ✅ 已修；⚠️ 修法帶出 K-m1 | K01 FAIL |
| I-m2 / J-m4 420 / 900 文字 | ✅ 大致已改；ble_gate.dart:238 小處見 K-m3 | grep |
| I-m3 卸載後不開始新請求 | ✅ | K02 FAIL（靠 debug assert，見表） |
| J-m1 等名額的掃描擋住持有者 | ✅ | K03、K04 FAIL |
| J-m2 cancel 丟例外 | ✅ | K05、K06 FAIL |
| J-m3 F-m6 的 6 s 會被繞過 | 已寫進殘項 | 可以接受 |
| J-m5 `token` getter | ✅ | `@visibleForTesting`，lib 沒有使用 |
| 第四輪 G / H 各項 | ✅（第五輪 I 已逐項確認；這輪 K09 再確認 B-M1） | |

## #329 實作殘項：能不能接受

每一條都可以接受，理由同第四、五輪。
- 「900 s 收回後擋不住（只有平台呼叫永遠不回來時才會走到）」：第五輪 I 提過「節點一直要求等待」也會走到。現在「我的節點」在 `dispose` 時斷線並結束等待，`wait` 步驟在下一圈 `gone()` 停下，所以這句對「我的節點」已經成立。
- 建議補一條 K-m2（如果不修）。

## PR 說明的偏離：安不安全

- **舊頁面在原始佔用下保留自己的 BLE 程式**：藍牙這部分安全。
  - 頁面在時佔用一直在。
  - 忙碌時返回，佔用撐到工作結束。
  - 卸載後不開始新工作（K02）。
  - 900 s 上限比最長的工作長。
  - 寫紀錄這部分有 K-m1（這輪造成，field 流程）與 K-m2（原本就有，開發版）兩個小縫，都是毫秒級窗口，有 CAS 擋住。
- **不加 PopScope**：安全。軟體更新頁自己有 `PopScope`，所以「更新中把我的節點關掉」走不到。
- **A 組量測併入 B 組**：使用者的決定；A13 是合併條件。

## 生命週期（端到端）

| 路徑 | 行為 | 證據 |
|---|---|---|
| 第一次安裝 / 啟動、啟動檢查中離開、讀紀錄中回來 | 不變（第五輪 I04 / I13） | node_link.dart:102-111 |
| 背景 / 前景 / inactive | 不變 | node_link.dart:130-139 |
| 藍牙關閉 / 權限收回 | 不變；真機在 B 組 | 殘項 |
| 拿佔用時 NodeLink 正在連線 / 掃描 / 等掃描名額 | 取消、等斷線（≤5 s）；等名額的掃描也關（J-m1） | K03 |
| 舊頁面忙碌中被關 | 佔用撐到工作結束（≤900 s） | 第五輪 I07 / I15 |
| 「我的節點」等待請求中被關 | 等待立刻以「結果不明」結束、佔用交回；**寫紀錄那一步若正在跑，會在交回後落地** | K01、K-m1 |
| 「我的節點」在貼上流程途中被關（開發版） | 佔用立刻交回，寫入之後才落地 | K-m2 |
| 卸載後頁面又想開始工作 | 不開始 | K02 |
| 軟體更新中 | 更新頁擋返回，所以「我的節點」不會被 dispose | swupdate.dart `PopScope` |
| cancel 丟例外 | gate 仍移除；自動讀取不停 | K05、K06 |
| App 被殺 | 佔用只在記憶體 | lease.dart |

## 安全（逐個角色）

這輪沒有新的輸入面。
- **附近的惡意 BLE 裝置**：prober 的對應不變。
  - `answer` 只在 Rust 登入完成後出現（prober.dart:105-110）。
  - 遇到會寫紀錄的步驟立刻放棄（prober.dart:122-127）。
  - 登入結束碼 5 和登入前的任何結束都對到 `noResponse` / `broken`，不會變成「是 Y」（:113-120）。
- **被入侵的節點**：在「我的節點」裡，`wait` 步驟現在在 `dispose` 後的下一圈停下，不能再讓頁面在關掉後一直撐住佔用。它也不能讓 NodeLink 寫紀錄。
- **其他 app**：沒有新的 IPC；logcat 遮罩不變。
- **我們自己的錯**：
  - K-m1：修一個問題時開了一個寫入缺口，是本輪唯一的新回歸；
  - K-m2：貼上流程沒有 `_busy`；
  - 說明文字落後（K-m3）。

## 我寫的東西（都在 scratchpad，沒有 commit）

- `scratchpad/core/pr1K-tools/mut.sh`：一次改一處 → 全套 → 還原並 `cmp`。
- `pr1K-tools/out/K00–K09.{diff,txt}`；`KFIX.txt`：修法草稿 + K-1，全套 428 PASS。
- `pr1K-tools/k_persist_pop_test.dart`（K-1）、`pr1K-tools/k2.dart`（K-2）：放進 `app/test/` 就能跑（依賴 `nodes_update_send_test.dart` 的假物件）。
