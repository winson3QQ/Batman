# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 87d4e83）第五輪程式審查：審查 J

審查範圍：整個 PR（core.dart 只看新程式怎麼用它）。重點：900 s 原始佔用上限下的佔用生命週期、logcat 會出現什麼、prober 面對附近惡意裝置與被攻破節點時的期限、測試用的掛鉤、#329「實作殘項」能不能接受。
副本：`git archive 87d4e83 app tests` 匯出到 scratchpad `core/pr1J`（沒有碰 `C:/src/Batman-329pr1` 的工作目錄）。我寫的測試與改壞腳本在 `core/pr1J/jtests/`，沒有 commit。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、0 MAJOR、5 MINOR。

我找不到任何一條路徑會讓 NodeLink 永遠回不來，或讓兩個藍牙使用者在正常路徑上同時使用藍牙，所以沒有 MAJOR。先前各輪的修正都有會 FAIL 的測試：下面 31 條改壞全部被抓到。剩下的發現：

- J-m1：一個留給 PR 3 的 gate 契約缺口。
- J-m2：關閉連線時不耐例外。
- J-m3：6 s 間隔可以被繞過，擴大了既有殘項 F-m6。
- J-m4：文字還寫著過時的「420 s」。
- J-m5：一個測試用的 token getter。

A13 與 B 組真機量測是合併條件，不算發現。

## 基準（✅ 已驗證）

- `flutter test --no-pub`（全套，我的副本）：`00:28 +423: All tests passed!`
- `flutter test --no-pub test/nodelink`：`00:08 +201: All tests passed!`
- Rust bridge `cargo test --offline`（WSL Ubuntu-24.04，用自己的 CARGO_TARGET_DIR）：`test result: ok. 62 passed; 0 failed`。
  - 歸因紀錄：第一次在 WSL 跑出 `58 passed; 4 failed`。失敗的是 claim.rs:640、rekey.rs:560、replay_node.rs:46，三處都讀不到 `../../../tests/vectors/219-protocol/vectors.json`。
  - flip 測試：只把副本改放成 `~/j329/app/rust` + `~/j329/tests`，讓相對路徑找得到 fixture，其他不動，結果 62 passed。原因是我的副本少了 fixture，不是產品問題。

## 我做的改壞對照

每次只改壞一條。測試範圍是 test/nodelink 加上 claim_flow、scan_page、nodes_update_send、recovery_scan_count；改 main.dart 的幾條另外加跑 key_abilities、key_gate、member_ui、nodes_zero。

全部 ✅ FAIL，沒有一條是因為編譯錯誤才失敗：

| # | 改壞 | 抓到的測試 |
|---|---|---|
| M1 | `rawGoneMax` 從 900 改成 420 | review_pr1「…taken back 900 s after the pop (r4 H-M1), not at 420 s」 |
| M2 | `nodeLinkToken` 永遠給 `_current` | RA-5 / RB-1 |
| M3 | `GateLink._usable` 不查 token | B-m5 / M10 / M14 |
| M4 | prober 把登入結束 5 和其他結束種類當成 `Res.body` | prober_test 4 條 |
| M5 | mask 拿掉 MAC 規則 | app_link_test F-m2、review_pr1 T-S4 |
| M6 | raw 佔用釋放時不比對紀錄清單 | RA-2 / A-M2、X12 / X9 |
| M7 | start() 的背景判斷移到讀紀錄之後 | r4 G-m1 |
| M8 | due 不看 gotMsg2 | r3 F-m1 |
| M9 | `RawLeaseScope.dispose` 不呼叫 `pageGone` | 真頁面 4 條（認領、我的節點、附近的節點、C-m2） |
| M10 | `hold()` 的取消不釋放佔用 | 6 條 |
| M12 | acquire 不等 `_dropAll` | B-M6a |
| M13 | 錯誤碼當成讀到 | prober row 2' |
| M14 | 不該出現的步驟當成讀到 | B-m6、「a step that would write a record…」 |
| M15 | 收回 token 時不關連線 | ble_gate 2 條 |
| M16 | inactive 當成背景 | T20 |
| M17 | RecordWriter 不查目前佔用 | T-K、420 s 收回 |
| M18 | 拿掉 msg2 之後的 20 s 期限 | r2 D21 |
| M19 | 不 dispose session | B-m2 |
| M20 | keyErrorToRadio 不作用 | AppLink 接線、C-M1 |
| M21 | unauthorized 不對應到沒有權限 | T-L5 |
| M22 | 舊頁面的掃描不計數 | 3 個真頁面 |
| M23 | 等到掃描名額後不重新驗 token | B-m5 |
| G1a/b/c | 啟動頁三個入口各自不把佔用交給頁面 | key_abilities「the start page r3 E-M1 / r4 G-M1: <入口> …」 |
| H1 | main.dart 不傳 `life:` | 「started while the app is in the background does not read」 |
| H2 | 遇到不該出現的步驟不放棄（只設 `st = null`） | 「…given up at once, nothing written」（計時測試，00:45） |
| S1 | 首頁不顯示狀態清單 | key_abilities 3 條 |
| Rust | `AuthRefused(Ok)` 改對應成 (5,0) | `make_network_needs_a_login` FAILED（61 passed; 1 failed） |

## 發現

### MINOR

**J-m1：拿到佔用之後，NodeLink 一個還在 gate 裡等掃描名額的掃描不會被關掉；拿到 session 佔用的流程在接下來最多 30 s 內呼叫 `gate.scan` 會被拒絕（「a scan is already running」）**

- 情境：
  1. 舊頁面剛用掉 30 s 內的 4 次掃描名額。
  2. NodeLink 開新的一輪，`gate.scan` 在 gate 裡等名額（`ble_gate.dart:186-195`）。這時這個 `GateScan` 已經加進 `_scans`。
  3. 使用者打開一個用 session 佔用的流程頁（PR 3 起才有）。
  4. `NodeLink.acquire` 呼叫 `_dropAll`，但 `_dropAll` 只停 `_scan`（`node_link.dart:324-326`）。`_scan` 要等 `await gate.scan` 回來才會指派（`node_link.dart:263`），所以等待中的這個掃描沒有被停。`LeaseRegistry.acquire` 也不通知 gate（`lease.dart:119-124`）。
  5. 新持有者呼叫 `gate.scan`，撞上 `_scans.isNotEmpty`（`ble_gate.dart:180-183`），被拒絕。
- 證據（✅ 實跑，`jtests/j_probe_test.dart`）：
  ```
  J1 holder scan right after acquire: BleGate refused: a scan is already running; gate.refused=[scan: a scan is already running]
  J1 after 31 s: gate.scans=0
  ```
- 影響：PR 1 還沒有任何流程使用 session 佔用，所以使用者碰不到。PR 3 的流程頁會碰到。它本來就得等名額，但應該是在 gate 裡等，而不是直接被拒絕。這不會讓兩個使用者同時用藍牙：名額到時 `reg.valid` 會失敗（`ble_gate.dart:191`）。
- 修法：二選一。
  - `LeaseRegistry.acquire` 換 token 時，對 listeners 發 `revoked(舊的 NodeLink token)`。gate 已經有關掉該 token 掃描與連線的程式（`ble_gate.dart:233-240`）。
  - 或者讓 `scan()` 判斷「已經有掃描」時只算 token 仍有效的掃描。

  不論哪一種，都把 J1 收進 ble_gate_test 當負向對照。

**J-m2：`GateLink.close()` 和 `GateScan.stop()` 遇到 `cancel()` 丟例外時，不會把自己從 gate 移除。NodeLink 的 `_run` 又是在 try 之外 `await mine?.close()`，例外會讓 `_attempt` 永遠不被清空，自動讀取就一直停到重開 app**

- 情境：
  - `close()` 先 `await _sub?.cancel()`（`ble_gate.dart:111`），之後才 `gate._links.remove(this)`（:120），中間沒有 try/finally。
  - `NodeLink._run` 的 `await mine?.close()`（`node_link.dart:299`）在 try/catch 之外。它丟出例外後，`_attempt = null`（:302）不會執行。
  - 之後 `_pump` 的條件 `gate.links == 0`（:214）永遠不成立，`connect` 也永遠被拒絕（「a link is already open」）。
  - `revoked` / `released` 救不回來，因為 `close()` 第一行是 `if (!_open) return`。
  - 掃描的 `stop()`（:50-51）有同樣的問題。
- 證據（✅ 實跑，`jtests/j_close_test.dart`；假 backend 的 onCancel 回傳一個失敗的 Future）：
  ```
  J2 close error: Exception: disconnect failed; gate.links=1
  ```
  ⚠️ 真機上發生的機率低：
  - reactive_ble 5.6.0 連線的 onCancel 是 `disconnectDevice`（`device_connector.dart:74`）。Android 端的 `PluginController.kt:153` 先 `result.success(null)` 再去斷線，正常情況不會丟例外。
  - 不過 `Repeater.detach` 另外還會 `await _sourceSubscription!.cancel()`。外掛脫離引擎時，理論上這裡可能丟例外。

  這是 fail-closed：不會造成兩個使用者同時用藍牙，只影響可用性。
- 修法：`close()` / `stop()` 用 try/finally，保證一定會從 gate 移除並執行 `_state.close()`；`_run` 裡的 close 也包進 try。負向對照就用 J2。

**J-m3：殘項 F-m6 說「閒著的頁面被關掉時，佔用在連線斷掉前就交回，不重疊只靠 `afterLease` 的 6 s」。但按「重新整理」、從背景回到前景、藍牙從關到開，都會立刻開一輪，繞過這 6 s**

- 情境：
  1. 使用者在「我的節點」登入（連線開著，頁面不忙）。
  2. 按返回。
  3. 馬上按首頁的「重新整理」。PR 1 的 `NodeStatusList` 就在同一個畫面上（`node_list.dart:382`）。

  原因：`releaseLease` 只設定 `leaseDue`（`core.dart:258`），而 `refresh`、`foreground`、`setRadio` 都直接呼叫 `_begin`（`core.dart:268, 211, 284`）。
- 證據（✅ 實跑，`jtests/j_refresh_test.dart`；在 release 之後 100 ms 做動作）：
  ```
  J3 none: scans started within 0.6 s of the release: 0
  J3 refresh: scans started within 0.6 s of the release: 1
  J3 bg-fg: scans started within 0.6 s of the release: 1
  ```
- 影響：最壞的情況是一次嘗試失敗（節點還連著舊頁面時不會廣播），不會寫錯任何東西。但殘項 F-m6「只靠 6 s」的說法比實際情況樂觀。
- 修法：二選一。
  - 最少把殘項 F-m6 改寫成「6 s，而且重新整理、回前景、藍牙恢復都會繞過」，並在 B 組真機上看一次。
  - 或者在 raw 佔用 release 後的 6 s 內，NodeLink 把 `refresh` / `foreground` 延到 `leaseDue` 才執行。

**J-m4：上限改成 900 s 之後，有好幾處文字還寫 420 s**

- `raw_use.dart:3-4`（檔頭寫「at most 420 s after the pop; then the registry takes the lease back」）。
- `lease.dart:55-57`（`hold()` 的說明寫「at most 420 s after the pop」）。
- PR 本文有兩處：「內容」最後一點的「最多到返回後 420 s」，以及偏離段的「舊頁面在 420 s 被收回之後還沒做完的工作」。偏離段同一段前面已經寫了 900 s，自相矛盾。
- #329 殘項第 110 行是對的（900 s）。
- 修法：改成「原始佔用 900 s（session 佔用 420 s）」。

**J-m5：`LeaseRegistry.token` 是公開的 getter，有人持有佔用時，它會把持有者的 token 交給任何呼叫者**

- `lease.dart:111` 是 `Token get token => _current;`。A-M5 / B-M2 的規則是「NodeLink 永遠拿不到持有者的 token」（靠 `nodeLinkToken`，:115），有了這個 getter，這條規則就只靠慣例維持。
- `lib/` 裡沒有人用它；grep 只找到 `test/nodelink/ble_gate_test.dart:91,102,139,144`。
- 修法：標成 `@visibleForTesting`；或者直接刪掉，測試改用 `nodeLinkToken` / `lease.token`。

## 先前發現的關閉狀態（抽查，每條都有改壞對照）

- 第四輪 G-M1（三個入口交出佔用、狀態清單、掃描計數）：G1a/b/c、S1、M22 都 ✅ FAIL，已關。
- G-m1（生命週期在讀紀錄之前套用）：M7 ✅，已關。
- G-m2（teardown）：`app_link_test.dart:29,51` 有 `addTearDown`，已關。
- G-m3：留在殘項（第 119 行）。
- H-M1（900 s）：M1 ✅，已關。
- H-m1（main.dart 的 `life:`）：H1 ✅。
- H-m2：H2 ✅（計時測試）。
- H-m3：殘項第 120 行。
- H-m4：Rust 改壞 ✅ FAIL。
- H-m5：殘項第 121 行。
- 第一到三輪的主要修正（RA/RB、B-M6a、C-M1、D21、F-m1、F-m2、T-S4、B-m2、B-m5、T-L5、T20）：上表的 M2–M23 都 FAIL，仍然關著。

## 佔用生命週期（900 s 上限下）

| 路徑 | 結果 | 依據 |
|---|---|---|
| 頁面開著（包括 app 進背景） | NodeLink 一直停著；設計就是如此 | `core.dart:161` 的 `_eligible` 要求 `!lease` |
| 閒著時關掉頁面 | 立刻交回，6 s 後開一輪（可被繞過，見 J-m3） | `lease.dart:71-77`；J3 |
| 忙著時關掉頁面，工作之後結束 | 工作結束才交回 | M9 / M10 被抓到 |
| 忙著時關掉頁面，工作永遠不結束 | 900 s 後收回並記一筆待辦；舊頁面不走 gate，之後可能和 NodeLink 重疊 | `lease.dart:78-80`；殘項第 110 行 |
| 收回之後舊頁面設 `rawBusy = true` | `hold()` 丟 StateError，工作不會開始 | `raw_use.dart:177`；在已卸載的頁面上 `setState` 也會先丟例外 |
| 兩次同時 acquire | 第二個拿到 null；core.lease 只是一個 bool，第一個釋放後就恢復 | `core.dart:214-218, 243-244` |
| release 讀紀錄期間佔用又被拿走 | core 保持 leased，寫過的 id 留到下一次釋放再套用 | M2 / X12 被抓到 |
| close / stop 丟例外 | NodeLink 停到重開 app（J-m2） | J2 |

900 s 夠不夠：

- 認領：`_find` 60 s、最後一次連線 20 s、認領 90 s、恢復 `total` 300 s（到期後還可能多等一次 `afterWriteFor` 90 s）、等候 15 s，合計約 560–580 s。
- 「我的節點」：`_linkWindow` 120 s。

兩者都小於 900 s。工作中間的對話框（`claim.dart:303` 的 `_ask`）在頁面卸載後直接回 false，不會無限等。所以收回只會發生在平台呼叫一直不回來的時候，偏離說明的前提成立。

## 安全（逐個角色）

**附近的惡意 BLE 裝置（廣播 provd UUID）**

- NodeLink 會連它並送出 msg1。msg1 是 NXpsk0，每次用新的 ephemeral 金鑰（`loginflow.rs:61-63`），裝置拿不到可以用來追蹤的固定值。
- msg2 解不開時是 `Undecryptable`；格式錯時是 `Broken`，對應成 noResponse。
- 手機只在 `verify_pinned` 通過之後才簽章（`loginflow.rs:160-177`），簽的輸入綁定 handshake hash。所以裝置拿不到 owner 簽章，也做不出「身分不符」（那需要 owner_tag_key）。
- 期限：msg2 之前 8 s（`due`），之後最多 20 s，全部和平台呼叫賽跑。
- 裝置提供的 `ctrl` 只會進 `frame_limit`，錯誤訊息只帶數字（`claim.rs:43-51`）。
- 它能做的只有拖時間，或讓真節點晚一點被讀到。這是可用性問題，跟無線電干擾一樣，屬於排程核心的範圍。

**被攻破的節點**

- 它只能回答自己那一筆紀錄。
- 讀取期間，任何要寫紀錄、要使用者確認、或要簽 owner-op 的步驟，都會走 default 分支立刻放棄（M14、H2 被抓到）。
- 登入後的 Answer 只會在 `St::Conn` 狀態出現（`owner.rs:1659-1686`），所以「是 Y」不可能來自一次沒有驗證過節點的登入。

**其他 app**

- 碰不到 gate；讀 logcat 需要 READ_LOGS 權限。
- log 內容：
  - NodeLink trace 和 prober log 都經過 `NodeLink.mask`：8 個以上的十六進位字元只留後 4 碼，MAC 只留最後一組（M5 被抓到）。
  - 錯誤只印型別和訊息。Kotlin `open` 的錯誤格式是「類別名: message」，details 為 null（`MainActivity.kt:130-134`）。
  - 沒有印出紀錄明文、簽章或簽章輸入。
- 舊頁面仍然印完整位址。這是既有程式，不在本 PR 範圍。

**我們自己的錯**

- RecordWriter 有佔用檢查，但 app 裡還沒有人用它；舊頁面直接寫紀錄，偏離說明已經講了。
- `reg.token`（見 J-m5）。

**測試用掛鉤**

- `AppLink.forgetForTest` 標了 `@visibleForTesting`。
- `BatmanApp.makeLink == null` 時頁面不拿佔用。正式的 `main` 一定會傳 `makeLink`。
- `make` 或 `start` 失敗時 `_app` 是 null，頁面也不拿佔用。但這時 core 還沒有 `startup`：`start` 先讀紀錄，才呼叫 `core.startup`（`node_link.dart:107-109`），所以 `_eligible` 是 false，不會出現第二個藍牙使用者。可以接受。

## #329 實作殘項：能不能接受

| 行 | 判斷 |
|---|---|
| 104 認領結果顯示在已關閉的頁面上 | 可以接受到 PR 3（紀錄會在 release 後被讀到） |
| 105 X26 只認 keyLevel 拒絕、2.4 要重開 app 才恢復 | 可以接受（設計的 X26 本來就是到重開為止） |
| 106 明文不能清零 | 可以接受（和 app 其他打開紀錄的地方一致，S20 證實緩衝區唯讀） |
| 107 / 108 / 117 / 120 / 121 真機量測 | 屬於 B 組合併條件 |
| 110 舊頁面不走 gate；900 s 後擋不住 | 可以接受（見上面的生命週期表，只剩平台呼叫不回來的情況）；請同步 J-m4 的文字 |
| 111 gate 在藍牙關閉時不另外拒絕 | 可以接受（NodeLink 的前提會擋住） |
| 112 啟動頁拿佔用的 5 s 沒有提示 | 可以接受（第二次點會跳「另一個操作還在進行」，無害；PR 2 換掉首頁） |
| 113 openRawPage 等佔用時 navigator 卸載，沒有測試 | 可以接受 |
| 114 閒頁關閉只靠 6 s | **要改寫**：補上 J-m3 的繞過條件 |
| 115 msg2 之後不看連線狀態 | 可以接受（結果正確，最多多等 20 s） |
| 119 舊「我的節點」的連線沒有取消 | 可以接受到 PR 3 / 6 |

建議殘項加一行 J-m1：PR 3 開始使用 session 佔用之前要修。

## PR 說明的偏離：安不安全

- 舊頁面在原始佔用下保留自己的 BLE 程式，忙的工作撐住佔用：安全（見生命週期表）。
- 不加 `PopScope`：安全。佔用已經撐到工作結束，而 `_ask` 在頁面卸載後不會等使用者。
- A 組量測併入 B 組：屬於合併條件。
- 文字：420 s 和 900 s 不一致（J-m4）。

## 我寫的東西（在 scratchpad，沒有 commit）

- `core/pr1J/jtests/mut.sh`：改壞執行器。
- `j_probe_test.dart`：J1。
- `j_close_test.dart`：J2。
- `j_refresh_test.dart`：J3。
