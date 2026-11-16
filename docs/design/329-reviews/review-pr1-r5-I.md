# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 87d4e83）第五輪程式審查：審查 I

範圍：整個 PR（`core.dart` 只看新程式怎麼用它）。重點：從實際使用出發的端到端生命週期；使用者依賴的每條規則有沒有能 FAIL 的測試（自己做改壞，特別是接線）；這輪修正（原始佔用 900 s / session 420 s、`NodeLink.start` 的生命週期順序）有沒有弄壞別的東西。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、1 MAJOR、3 MINOR。

- 這輪兩個修正本身正確，都有能 FAIL 的測試（I07、I08、I12、I13）。
- 第四輪 G-M1 列出的五個沒被抓到的改壞，四個現在會 FAIL（G2→I01、G3→I02、G4→I03、G5→I06）。**G22 仍然全過**（I05，`+423: All tests passed!`）：新加的 `recovery_scan_count_test` 只測 `ReactiveRecoveryBle` 自己，沒測 `claim.dart` 有沒有把 `onScan` 接上去（I-M1）。
- 我懷疑「我的節點」的 `_ask` 在頁面卸載後會不持有佔用就送請求（`if (mounted) setState(() => _busy = true)`，nodes.dart:520）。寫了真頁面測試去打它：**沒有成立**。頁面 `dispose` 會 `_drop()` 掉 session，後面的請求走 `_login`，在 `setState` / `hold()` 就丟例外，沒有送出任何 frame（fail-closed 成立）。但同一個測試量到另一件事：連線在返回時就斷了，佔用卻還要再撐 360 s（I-m1）。
- A13 與 B 組真機量測是合併條件，照指示不算發現。

## 基準（✅ 已驗證）

- 匯出：`git -C C:/src/Batman-329pr1 archive 87d4e83 app tests | tar -x`，放在 `scratchpad/core/pr1I`；`.dart_tool/package_config.json`、`package_graph.json` 另外複製。沒有複製工作目錄。
- `flutter test --no-pub`：`00:21 +423: All tests passed!`
- `flutter analyze --no-pub lib test`：`1 issue found`（`member_ui_test.dart:4` 的 info，原本就有）。
- bridge `cargo test --offline`（WSL Ubuntu-24.04，`CARGO_TARGET_DIR=/home/yello/tgt-pr1I`）：`test result: ok. 62 passed; 0 failed`。
- 每次改壞後還原，最後對 `git ls-tree 87d4e83 app/lib app/test` 的每個檔案 `cmp`，全部相同。

## 我做的改壞（一次改一處，跑全套 `flutter test --no-pub`）

工具：`scratchpad/core/pr1I-tools/mut.sh`；每一項的 diff 與完整輸出在 `pr1I-tools/out/I*.diff`、`I*.txt`。

| # | 改壞 | 結果 | 抓到的測試 / 備註 |
|---|---|---|---|
| I01 | main.dart:215 `NodesPage(..., use: null)`（第四輪 G2） | ✅ FAIL | `r3 E-M1 / r4 G-M1: 我的節點 opens its page…`（`Expected: same instance as <Lease>, Actual: <null>`） |
| I02 | main.dart:225 `ScanPage(..., use: null)`（G3） | ✅ FAIL | 同一組，附近的節點那一個 |
| I03 | main.dart:211 拿掉 `NodeStatusList`（G4） | ✅ FAIL ×3 | `Found 0 widgets with type "NodeStatusList"` |
| I04 | main.dart:143 拿掉 `life:`（G1 / H-m1） | ✅ FAIL | `r4: the start page started while the app is in the background does not read`（`Expected: false Actual: <true>`） |
| **I05** | **claim.dart:478 `ReactiveRecoveryBle(_ble)`（拿掉 `onScan: rawScanStarted`；第四輪 G22）** | **❌ `+423: All tests passed!`** | **→ I-M1** |
| I06 | nodes.dart:386 拿掉 `rawScanStarted()`（G5） | ✅ FAIL | `r3 E-M1: 我的節點 popped mid-login…`（`Expected: a value greater than <0> Actual: <0>`） |
| I07 | lease.dart:78 原始佔用也用 `goneMax`（420 s） | ✅ FAIL | `a busy older page that never ends: … 900 s …` |
| I08 | `rawGoneMax` 900 → 485 | ✅ FAIL | 同上 |
| I09 | prober.dart:108 拿掉 `done(failed())`（H-m2） | ✅ FAIL | `given up at once`（`Expected: < 5000 Actual: <20004>`） |
| I10 | claim_recovery.dart:85 拿掉 `onScan?.call()` | ✅ FAIL ×2 | `recovery_scan_count_test` |
| I11 | claim.dart:216 拿掉認領掃描的 `rawScanStarted()` | ✅ FAIL ×2 | `A-M1 real page…`（`recentScanStarts`） |
| I12 | lease.dart:78 session 佔用也用 `rawGoneMax` | ✅ FAIL | `ble_gate_test` 的 420 s 收回、`lease_test` 的 420 s |
| I13 | node_link.dart：`life` 改回在 `readRecords` **之後**套用（還原 G-m1 修正前） | ✅ FAIL | `r4 G-m1: back in the foreground while start() reads the records`（`Expected: true Actual: <false>`） |
| I14 | node_link.dart:177 原始佔用不比對紀錄（A-M2） | ✅ FAIL | `Expected: Kind.read Actual: Kind.unreachable` 等 |
| I15 | lease.dart:66 `hold` 結束時不釋放 | ✅ FAIL | `Expected: null Actual: <Lease>`（多個） |

I13 那次同時跑到我自己的 `I-1` 測試（當時還放在 test 目錄，它在原始碼上本來就會因 `setState() called after dispose()` 而 FAIL，見 I-m1），和改壞無關；之後已移出 test 目錄並重跑確認全套 423 PASS。

## 發現

### MAJOR

**I-M1：認領恢復的掃描計數（第四輪 G22 / 第三輪 E14），`claim.dart` 的接線仍然沒有測試會 FAIL。PR 說明寫「兩處掃描計數 … 9 / 9 都有測試 FAIL」，但新測試只測 `ReactiveRecoveryBle` 本身**

- 情境：
  - 正式版的恢復一定走 `ReactiveRecoveryBle(_ble, onScan: rawScanStarted)`（claim.dart:478）。
  - 如果這個 `onScan:` 被拿掉（重構、合併衝突），恢復每 6 s 一次的掃描（claim_recovery.dart:393 `ble.scan(scanFor)`）就不算進 gate 的「30 s 內 4 次」。
  - 恢復結束、佔用釋放，6 s 後 NodeLink 開一輪掃描。它可能是 30 s 內第 5 次以上。Android 會悄悄不給結果（設計 A10 / M-1 E），那一輪就把剛認領的節點判成「手機連不到節點」。
- 證據：
  - I05（只改 claim.dart:478）：`00:19 +423: All tests passed!`（`pr1I-tools/out/I05.txt`）。
  - 新的 `recovery_scan_count_test.dart` 直接 `ReactiveRecoveryBle(OneDeviceBle(), onScan: …)`，所以只守住 claim_recovery.dart 自己的呼叫（I10 會 FAIL）。
  - `claim_flow_test` 的恢復路徑都注入 `recoveryBle`，於是 `widget.recoveryBle ?? ReactiveRecoveryBle(...)` 的右邊從來沒有被執行。
  - 第四輪 G 的表把 G22 列為沒被抓到，修法第 4 點要求「`claim_flow_test` 的恢復路徑也比照，斷言 `gate.recentScanStarts`」。
- 為什麼是 MAJOR：宣稱修好的項目沒有能 FAIL 的測試（使用者規則：每個宣稱的修正都要有負向對照）。程式目前是對的，使用者碰到的機率很低，修法也很小。
- 修法（擇一）：
  1. 把建構抽成函式，例如 `RecoveryBle recoveryBleFor(FlutterReactiveBle ble, void Function() onScan)`，ClaimPage 呼叫它；測試呼叫同一個函式，斷言 `onScan` 被呼叫。
  2. 或在 ClaimPage 用 `recoveryBle == null` 跑一次恢復掃描：用 `ReactiveBlePlatform.instance` 假平台，`nodes_update_send_test` 已經有 `FakeNode` 可以借。斷言 `gate.recentScanStarts > 0`。
  3. PR 說明那一列附上 I05 的負向對照。

### MINOR

**I-m1：「我的節點」在長請求中（加入網路、建立網路、把新密碼送給節點，等待 360 s）被關掉時，連線在 `dispose` 就斷了，但原始佔用還要撐到 360 s 的等待結束。這段時間首頁清單完全不讀**

- 情境：
  1. 使用者在「我的節點」按「把新密碼送給節點」或「加入網路」。畫面寫「最多可能要等幾分鐘」，使用者按返回回首頁。
  2. `_NodesPageState.dispose` → `_drop()`（nodes.dart:146-148、:172-179）取消通知與連線，session 清掉。節點的回答再也收不到。
  3. `_ask` 還在等 `_answer`，只能等 `_kick` 的計時器（`_joinWait` = 360 s，member_ui.dart:231）。這段時間 `_busy` 仍為 true，原始佔用一直被持有（`Lease.hold`）。
  4. 結果：沒有任何藍牙在用，NodeLink 卻被擋 6 分鐘。首頁只顯示「上次讀取 N 秒前」，直到 360 s 到期才讀。
- 證據（✅ 實跑，真的 `NodesPage` + `openRawPage` + 假 BLE 平台）：`scratchpad/core/pr1I-tools/mytests/i_unleased_ask_test.dart`。
  - 返回後 `node.disconnects` 非空（連線斷了），但 `reg.current` 仍是同一個佔用；
  - 再過 300 s 還在；
  - 再 70 s 才變成 null。
  - 這幾個斷言都通過（輸出 `I-2 frames: [20:我的節點]`，也就是只送了那一個 send frame）。
  - 測試最後的 FAIL 是 `setState() called after dispose()`：`_readStatusPage` → `_ask` → `_login`（nodes.dart:361）。這正是下一點說的 fail-closed 路徑。
- 和殘項的關係：殘項 F-m6 是「閒著的頁面」（佔用太早放），這條是反方向（忙著但連線已經斷了，佔用放太晚），殘項沒有寫到。
- 修法（擇一）：
  1. `dispose` 裡把還沒完成的 `_answer` 以「結果不明」完成（`_unclear != null ? _unclearNow() : _waitLine`），讓 `_ask` 立刻走 finally → `rawIdle()`；
  2. 或寫進 #329 殘項，和 F-m6 放在一起（PR 3 / 6 換掉頁面時解決）。

**I-m2：這輪把原始佔用改成 900 s，但程式註解和 PR 說明還有好幾處寫 420 s**

- lease.dart:3（「the 420 s rule」）、:57（`hold`：「at most 420 s after the pop」）、:70（`pageGone`：「at most 420 s from now」）。這幾個方法對原始佔用的上限是 900 s。
- raw_use.dart:3、:30、:40；scan.dart:86；ble_gate.dart:231（「§4.4 420 s」，這個對 session 佔用是對的）。
- PR 說明「內容」最後一點寫「（最多到返回後 420 s）」，「和設計不同的地方」第 4 點寫「舊頁面在 420 s 被收回之後」。同一份說明的第 1 點和 #329 殘項已改成 900 s，前後矛盾。
- `review_pr1_test.dart:595` 用 `'我的節點'` 當佔用名稱，註解卻寫「a slow claim」。不影響結果。
- 修法：註解寫成「raw 900 s / session 420 s」；PR 說明那兩句改成 900 s。

**I-m3：`_ask` 用 `if (mounted) setState(() => _busy = true)`（nodes.dart:520）。頁面已卸載時它不持有佔用；現在靠 `dispose` 已經清掉 session 才沒有出事，這個前提沒有寫下來**

- 我實際去打了：status 頁送出中連按兩次返回，送出結束後 `_sendFromPage` 會接著 `_readStatusPage` → `_ask`。
  - 結果：沒有任何 frame 在佔用釋放後送出。
  - 原因：`dispose` 的 `_drop()` 已經把 `_session` 清掉，`_ask` 改走 `_login`。`_login` 的 `setState`（沒有 `mounted` 保護，nodes.dart:361）在 debug 版丟 FlutterError；在 release 版會先執行 callback，`hold()` 對已釋放的佔用丟 `StateError`。
  - 所以 fail-closed 成立，但靠的是兩個沒寫下來的前提：「dispose 一定清 session」和「`_login` 的 `setState` 沒有 `mounted` 保護」。
- 附帶：release 版那個 `StateError` 會變成 status 頁 `_send` 的未處理非同步錯誤（只進 log，不影響使用者）。
- 修法：nodes.dart:520 改成 `if (!mounted) return null;`（卸載後不開始新請求），或在那一行加註解寫明依賴的前提。成本很低，日後有人改 `dispose` 也不會悄悄打開。

## 這輪修正有沒有弄壞東西

- **原始佔用 900 s / session 420 s**（lease.dart:78、:100）
  - 只在 `pageGone` 時依 `kind` 選上限。session 佔用在 PR 1 沒有使用者；I12 證明兩個方向都有測試。
  - 900 s 是否蓋得住舊頁面最長的忙碌時間：
    - 認領：60 s 找 + 20 s 連 + 90 s 回答 + 15 s `t1Wait` + 恢復 `total` 300 s + 進行中那一步最多 90 s（`afterWriteFor`）≈ 575 s。
    - 「我的節點」加入網路：登入（60 s 掃描 + 最後一台 40 s）+ 360 s 等待 + 120 s link watch ≈ 600 s。
    - 都小於 900 s ✅。
  - 被入侵的節點可以靠一直送 `wait` 步驟重新計時（`_kick`，nodes.dart:286-291），讓舊頁面忙超過 900 s。後果只是 NodeLink 提早進來，和那台節點的連線並存。這已經寫在殘項（「900 s 收回後擋不住」），不另外列。
  - 代價：平台呼叫永遠不回時，首頁最多 15 分鐘不讀。PR 1 沒有待辦畫面（PR 說明已寫明），可以接受。
- **`NodeLink.start` 先套用生命週期再讀紀錄**（node_link.dart:102-111）
  - `core.background` 只設旗標、清排程；這時 `started == false`，所以讀紀錄期間任何 `foreground` / `background` 都不會開一輪（core.dart:161 `_eligible`）。`startup` 之後由 `_begin` 決定。
  - 讀紀錄期間：
    - 回到前景 → `fg = true` → `startup` 開一輪（I13 守住）；
    - 離開 → `fg = false` → `startup` 不開。
  - 觀察者在 `AppLink.create` 就註冊（app_link.dart:90），比 `lifecycleState` 的取值（main.dart:143）早，中間全是同步程式，沒有漏事件的窗口。
  - `start` 丟例外：`_app` 留 null，`core.started == false`，旗標可能停在背景。下一次 `再試一次` 由觀察者的 `resumed` 或新的 `life` 修正。✅ 無害。
- **teardown**：`app_link_test`、`key_abilities_test` 已加 `addTearDown`（第四輪 G-m2 已關）。

## 先前發現的關閉狀態

| 發現 | 狀態 | 依據 |
|---|---|---|
| G-M1 啟動頁接線 | ⚠️ 大部分關了（I01–I04、I06 會 FAIL）；G22（恢復掃描的接線）沒關 | → I-M1 |
| G-m1 啟動時的生命週期競態 | ✅ 已修，I13 會 FAIL | |
| G-m2 teardown | ✅ | |
| G-m3 登入例外留下連線 | 已寫進殘項 | 可以接受（PR 3 / 6 換頁） |
| H-M1 420 s 太短 | ✅ 改成 900 s；I07、I08 會 FAIL；最壞忙碌時間見上 | |
| H-m1 main 的 `life:` | ✅ I04 會 FAIL | |
| H-m2 遇到不該出現的步驟立刻放棄 | ✅ I09 會 FAIL（`20004 ms`） | |
| H-m3 連線立刻失敗也等 8 s | 已寫進殘項，交給 B 組量 | 可以接受：理由（前一條連線晚到的 DISCONNECTED 可能誤結束新嘗試）合理，結果本身正確 |
| H-m4 `AuthRefused(Ok)` 斷言 | ✅ owner.rs 已加；62 passed | 沒有再做 Rust 改壞（第四輪 G 的方法已驗過同一張表） |
| H-m5 B 組在合併 commit 上跑 | 已寫進殘項 | |

## #329 實作殘項：能不能接受

每一條都可以接受（理由同第四輪 G / H，我重新查過 900 s 那一條的數字，見上）。建議補一條 I-m1（或直接修）。殘項裡「900 s 收回後擋不住（只有平台呼叫永遠不回來時才會走到）」：被入侵的節點靠 `wait` 步驟也走得到（見上）。後果有限，建議括號改成「平台呼叫永遠不回來，或節點一直要求等待」。

## PR 說明的偏離：安不安全

- **舊頁面在原始佔用下保留自己的 BLE 程式**：安全。
  - 頁面在時，佔用一直持有。
  - 忙碌時按返回，佔用撐到工作結束（I15 守住）。
  - 卸載後開始新的工作，會在 `setState` / `hold()` 丟例外（I-m3 實跑）。
  - 900 s 上限比最壞忙碌時間長。
  - 剩下的缺口：I-m1（放太晚，只影響首頁更新）、F-m6（放太早，靠 6 s）。
- **不加 PopScope**：安全，理由同上一輪。
- **A 組量測併入 B 組**：使用者的決定；A13 是合併條件。
- 說明裡 420 / 900 前後不一致（I-m2）；「9 / 9 都有測試 FAIL」對 G22 的接線不成立（I-M1）。

## 生命週期（端到端）

| 路徑 | 行為 | 證據 |
|---|---|---|
| 第一次安裝 / 啟動 | 啟動檢查通過才建 NodeLink；`keyOk` 來自啟動檢查；`start` 失敗時畫面留結果、NodeLink 不讀 | main.dart:137-149 |
| 啟動檢查中離開 | 不讀（I04）；讀紀錄期間回來 → 讀（I13） | |
| 背景 / 前景 / inactive | paused / hidden / detached = 背景；inactive 不變 | node_link.dart:130-139；第四輪 G11 / H M11 |
| 藍牙關閉 / 權限收回 | 狀態流 → 取消、顯示原因 | 第四輪 G20 / H M17；真機在 B 組 |
| 拿佔用時一次嘗試正在連線 | 取消、等斷線（最多 5 s）才給佔用 | 第四輪 G14 |
| 舊頁面忙碌中被關 | 佔用撐到工作結束（最多 900 s） | I07、I15 |
| 「我的節點」長請求中被關 | 連線立刻斷，佔用再撐最多 360 s | I-m1（實跑） |
| 閒著的頁面被關 | dispose 時立刻交回，靠 6 s 錯開 | 殘項 F-m6 |
| 卸載後頁面又想開始工作 | `setState` / `hold()` 丟例外，不送 frame | I-m3（實跑） |
| App 被殺 | 佔用只在記憶體 | lease.dart |

## 安全（逐個角色）

這輪沒有新的輸入面。
- **附近的惡意 BLE 裝置**：prober 的對應不變。只有 Rust LoggedIn 之後的 `answer` 才給 `body`（prober.dart:88-92）；遇到會寫紀錄的步驟立刻放棄（I09 守住）；msg2 前 8 s，之後 20 s。
- **被入侵的節點**：能讓舊頁面忙超過 900 s（`wait` 重新計時），結果只是 NodeLink 提早進來，見上；不能讓 NodeLink 寫紀錄或拿到 owner 簽章。
- **其他 app**：沒有新的 IPC；logcat 遮罩不變（第四輪 G12 / G30）。
- **我們自己的錯**：
  - I-M1（接線沒有守住）；
  - I-m3（fail-closed 靠沒寫下的前提）；
  - 註解寫錯上限（I-m2），會誤導下一個改 lease 的人。

## 我寫的東西（都在 scratchpad，沒有 commit）

- `scratchpad/core/pr1I-tools/mut.sh`：一次改一處 → 全套 → 還原並 `cmp`。
- `scratchpad/core/pr1I-tools/out/I01–I15.{diff,txt}`、`summary.txt`。
- `scratchpad/core/pr1I-tools/mytests/i_unleased_ask_test.dart`：真的 `NodesPage` 在原始佔用下，status 頁送出中連按兩次返回。結果：
  - 不持有佔用的請求沒有發生（I-m3 的反證）；
  - 佔用在連線斷掉後仍然持有 360 s（I-m1）。
  - 原始輸出在 `out/I-1-base.txt`、`out/I-2-base.txt`。
