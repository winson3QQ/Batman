# #329 PR 1 第六輪程式審查 — 審查者 L（73e87cc）

範圍：整個 PR（核心排程 core.dart 除外），重點在安全與資料完整性：第五輪「頁面 dispose 時結束等待中的請求」、佔用的生命週期、logcat、prober 的期限、#329「實作殘項」。
在自己的匯出副本（`git archive 73e87cc app tests`）上做，沒有動 C:/src/Batman-329pr1。

**判定：APPROVE-WITH-CHANGES** — BLOCKER 0、MAJOR 0、MINOR 5。要改的都是文件（殘項清單、PR 內文）或小的防呆，沒有一項會讓紀錄壞掉，也沒有一項讓藍牙在沒有佔用時跑起來。

## 跑過的東西（✅ 實跑）

- `flutter test --no-pub`（全套）：`00:19 +427: All tests passed!`
- bridge `cargo test`（WSL Ubuntu-24.04，自己的 CARGO_TARGET_DIR）：`test result: ok. 62 passed; 0 failed`
- Rust 負向對照：`End::CertRejected(_) => (2, 0)` → `api::owner::tests::make_network_needs_a_login --- FAILED`（owner.rs:1887）
- 我自己的改壞對照（每次只改一處，跑 `test/nodelink` + `nodes_pop_test` + `claim_flow_test` + `scan_page_test` + `recovery_scan_count_test`）：

| # | 改壞什麼 | 結果 |
|---|---|---|
| M1 | nodes.dart:150 dispose 不結束等待中的請求 | FAIL（`Expected: null, Actual: <Instance of 'Lease'>`） |
| M2 | nodes.dart:518 拿掉 `!mounted && !held` | FAIL（setState-after-dispose；release 版會是 `lease.hold()` 的 StateError，也是不送） |
| N1 | node_link.dart:161 拿到佔用後不收回 NodeLink 的 token | FAIL（review_pr1_test r5 J-m1） |
| N2 | ble_gate.dart:53 scan stop 的 cancel 例外不吞 | FAIL（r5 J-m2） |
| N4 | lease.dart:80 原始佔用上限改回 420 s | FAIL（A-M1 / B-M1） |
| N5 | raw_use.dart:32 頁面忙時不 hold | FAIL（r2 C-m2 / D-10 等） |
| N6 | prober.dart:98 身分不符 → noResponse | FAIL（prober_test login ends） |
| N8 | prober.dart:92 2' 當成讀到 | FAIL（prober_test row 2'） |
| N9 | node_link.dart:303 attempt 結束不關自己的連線 | FAIL（node_link_test） |
| N10 | node_link.dart:184 讀紀錄期間被拿走佔用的分支拿掉 | FAIL（RA-5 / RB-1） |
| N12 | ble_gate.dart:228 允許第二條連線 | FAIL（T-G1） |
| N13 | ble_gate.dart:198 等掃描名額後不再檢查 token | FAIL（B-m5） |
| N14 | ble_gate.dart:85 GATT 不檢查 token | FAIL（B-m5） |
| N7 | prober.dart:143 拿掉 `!gotMsg2`（每個步驟重設 20 s） | PASS — 等價改壞：舊的 Timer 沒被取消，仍在第一個 20 s 結束，行為不變 |
| N11 | record_writer.dart:28 拿掉 `identical(reg.current, l)` | PASS — 等價改壞：`l.valid` 已經包含「token 是目前的」，而 token 只在這個佔用是目前的時候有效（lease.dart:43,121,127,134） |

N7、N11 不是測試漏洞，是多餘的條件；不列為發現。

## 第五輪的改動逐條看（安全 / 完整性）

**頁面 dispose 時結束等待中的請求（nodes.dart:147-151）** — 會不會丟紀錄、寫壞紀錄？
- dispose 裡的 `_drop()` 在這個 PR 之前就有（diff 裡是 context 行），所以 dispose 之後節點的回答本來就收不到；第五輪只是把 `_ask` 等到逾時（最多 `_joinWait`）改成立刻結束。紀錄的結果和之前一樣：
  - 建立網路 / 加入：Rust 在送出之前先寫好紀錄（owner.rs:1451-1456，CAS 從 0），回答 Applied 之後才寫 applied（owner.rs:1458 起）。回答沒收到 → 紀錄停在「建立中」/「加入中」，就是原本「結果不明」的狀態，可以「繼續加入」。
  - 回答已經進了 inbox、persist 正在寫：寫入照樣完成（storeWriteCas 是 CAS），之後 loop 頂端 `gone()`（nodes.dart:216）停下。紀錄是對的（節點真的套用了）。
- 佔用：Flutter 先 dispose 子 widget 再 dispose 父 widget，所以 NodesPage.dispose 先完成 answer、RawLeaseScope.dispose 再 `pageGone()`；answer 的監聽在 microtask 才跑，所以 `_ask` 的 finally `rawIdle()` → hold 歸零 → `release()`（lease.dart:64-69）。nodes_pop_test 驗證了 `reg.current == null`。
- 頁面不在之後不送新請求：`_ask` 入口的 `!mounted` 擋住；就算沒擋，`_login` 的 `setState(() => _busy = true)` 會走到 `rawBusy=true` → `lease.hold()`，佔用已結束 → StateError（raw_use.dart:244、lease.dart:61），fail-closed。M2 證明測試會抓到。
- 寫入是否可能在佔用之外完成：見 MINOR-1（不是第五輪造成的）與 MINOR-2（第五輪讓「連線還沒斷完就交回」也出現在請求中的頁面）。

**acquire 收回 NodeLink 的 token（node_link.dart:157-161）**：`mine` 在 `_dropAll` 之後讀，期間 token 只會在 acquire/release 時換，所以是同一個；等名額中的掃描被 stop，`gate.scan` 醒來看到 `!s.open` 就丟 Refused（ble_gate.dart:198-200）。N1 對照 FAIL。

**stop/close 在 cancel 丟例外時仍離開 gate**：ble_gate.dart:50-53、123-128。N2 對照 FAIL。

## 佔用生命週期與單一使用者 / 單一寫入者

- 每個 `_busy = true` 的地方都有 finally `rawIdle()`（nodes.dart 的 diff 全數替換；scan.dart `_read` 在 await 之前設、finally 放）。頁面在時佔用一直有效（只有 `pageGone` 之後的期限會收回，lease.dart:73-83），所以 `hold()` 在掛載的頁面上不會丟例外。
- 永遠不放的佔用：只有「頁面一直開著」（設計如此）。頁面關掉後：閒著 → 立刻放；忙 → 工作結束放，最遲 900 s 收回並記待辦。
- NodeLink 在佔用期間沒有 token（lease.dart:120），gate 在 scan / connect / GATT 每一步都檢查（ble_gate.dart:85,176,198）。
- 讀紀錄期間又被拿走佔用（node_link.dart:184-189）有測試（N10）。我另外檢查了「acquire 進行中（core 已 leased、registry 還沒）時，上一個佔用的 readRecords 回來把 core 解除 leased」：要發生，`_dropAll` 必須比一次 FFI 的 `listNodes` 還慢；而上一個佔用期間 NodeLink 沒有 gate 連線，`_dropAll` 只有幾個 microtask，所以走不到。不列。

## prober 與各個對手

- 附近的惡意 BLE 裝置：已認領的節點用 `Noise_NXpsk0`，psk = psk_owner（noise.rs:3）。沒有 psk 做不出能解開的 msg2 → `Msg2Undecryptable`（noise.rs:112）→ Res.undecryptable（只表示「這個位址不是 Y」）。簽章在 msg2 解開且憑證比對通過之後才要求（loginflow.rs:160-175），所以惡意裝置拿不到擁有者簽章，也觸發不了「身分不符」。最壞是每個位址吃掉一次 8 s 的嘗試（連線 + msg2 共用 `due`，node_link.dart:275-292、prober.dart:400-402）——可用性問題，屬排程層，不在本輪範圍。
- 被入侵的節點（有自己的 psk）：msg2 之後最多 20 s（一次性 Timer，prober.dart:143-145），一直送片段也不會延長；能謊報狀態顏色（本質）；讀取中遇到 persist / 問使用者之類的步驟走 `default` → 放棄（prober.dart:449-453），而且 prober 根本沒有寫紀錄的介面。
- 其他 app：沒有新增 exported 元件或平台方法。
- logcat：prober 只記錯誤型別、訊息、login end 種類與碼；id 與 MAC 經 `NodeLink.mask`（node_link.dart:56-58；app_link.dart:60,87）。Kotlin 錯誤的 message 是「類名: message」（MainActivity.kt:121,133），沒有位元組。舊頁面自己的 log 不在本 PR 範圍。

## 發現

### MINOR-1 舊「我的節點」有幾個寫紀錄的動作不在 `rawBusy` 之下，頁面在寫入中被關掉時，寫入會在佔用交回之後才落地
- 情境：在 SAS 確認頁按「確認碼相同，匯入」（`_importApproval`，nodes.dart:979-1004）、貼上更新包（`_takeUpdate`，nodes.dart:1454-1483）、管理者核准（`_checkRequest` → `_runOp`，nodes.dart:827-841、771）、長按忘記節點（`_forget`，nodes.dart:446-465）。這些路徑都沒有拿 `_busy`；ECDH / seal 的平台呼叫進行中，使用者連按兩次返回（先關 SAS 頁、再關「我的節點」）→ `RawLeaseScope.dispose` → `pageGone()` 時 busy 是 0 → 立刻 `release()`（lease.dart:76-78）→ 之後 `storeWriteCas` / `storeRemove` 才完成。
- 影響（⚠️ 由程式推論，未實跑）：不會寫壞（CAS；PR 1 沒有其他 mnet / net 的寫入者）。`_forget` 的情況下 NodeLink 的 `released()` 已經讀過紀錄清單，被忘記的節點會留在清單上顯示「手機連不到節點」，直到下一次佔用釋放或重開 app。窗口很窄（平台呼叫的幾十到幾百 ms）。
- 但 PR 內文寫「所以同一時間仍然只有一個藍牙使用者、一個寫入者」，殘項第 110 行只寫了 900 s 收回後的缺口，這一類沒有寫。
- 修法：把這幾個寫入包進 `_holding`（或寫入前後 `rawBusy=true` / `rawIdle()`）；或至少寫進 #329 實作殘項，並把 PR 內文那句改成「頁面忙的工作期間」。

### MINOR-2 第五輪讓「佔用在舊頁面的連線斷完之前就交回」也發生在請求進行中被關掉的頁面
- 情境：「我的節點」有請求在等時按返回。之前：dispose 的 `_drop()` 開始斷線，佔用撐到 `_ask` 逾時（≥15 s），斷線早就完成。現在：`_drop()` 沒有 await（nodes.dart:151），answer 立刻完成，佔用在隨後的 microtask 就交回（raw_use.dart:253 → lease.dart:68），斷線還在進行。
- 影響：和殘項 F-m6 / J-m3 同一類（通常 `afterLease` 6 s 之後才開始自動讀取；按重新整理、回前景、藍牙打開會立刻開一輪，可能和舊連線重疊，最多讓那一次嘗試失敗）。不是新的種類，但殘項第 114 行寫的是「閒著的舊頁面」。
- 修法：更新殘項文字（「閒著、或有請求在等的舊頁面」）；或在 dispose 時讓 hold 撐到 `_drop()` 的 future 結束再放。

### MINOR-3 「我的節點」在請求中被關掉，結果（含「結果不明」）只進 logcat，使用者看不到，也沒有待辦
- 情境：建立網路（「最多可能要等 3 分鐘」）、加入、送新密碼、移除中按返回。第五輪之後立刻以「結果不明」結束，但 `_say` 在頁面不在時只寫 log（nodes.dart:156-159）；待辦只在佔用被收回時記（lease.dart:144）。
- 這不是這個 PR 造成的（PR 之前頁面關掉也一樣看不到），但殘項第 104 行（F41）只寫了 ClaimPage。
- 修法：殘項 F41 加上「我的節點」的建立網路 / 加入 / 送更新 / 移除，PR 3 / 6 換頁面時一起處理（或 PR 2 的首頁待辦也記這種情況）。

### MINOR-4 `_askSw` 沒有 `!mounted` 的停止；頁面關掉後軟體更新流程再要求時，是靠例外擋下，不是靠判斷
- 情境：軟體更新頁在上傳中被關掉（§3.5 允許，`_go` 迴圈繼續，swupdate.dart:163-178；keepalive swupdate.dart:204），接著關「我的節點」。下一次 `widget.ask` → `_askSw`（nodes.dart:1541）→ `_session == null` → `_login`（nodes.dart:363-365）→ `setState` 在已 dispose 的 State 上：debug 版 FlutterError，release 版 `rawBusy=true` → `lease.hold()` StateError。
- 影響（⚠️ 由程式推論，未實跑）：fail-closed，藍牙沒有動作；但 `_go` / `keep()` 以未處理的 async 例外結束，更新流程停在上一步，log 多一筆未處理例外。
- 修法：`_askSw` 開頭比照 `_ask`：`if (!mounted) return sw.noLink(nowMs: h.now());`，加一個測試。

### MINOR-5 殘項是否可接受（逐條）
- 104 F41：可接受，但要補「我的節點」（MINOR-3）。
- 105 X26 只認 keyLevel / open 不經閘門：可接受（只影響顯示的原因，錯的方向是「連不到」，不會讀到錯的結果）。
- 106 明文靠 GC：可接受（平台通道唯讀緩衝區，S20 實證；和 app 其他地方一樣）。
- 107 / 108 / 117 / 120 / 121 B 組真機：合併條件，不算發現。
- 110 舊頁面不走 BleGate / RecordWriter：可接受（PR 3 / 6 取代），但要補 MINOR-1 的寫入窗口。另外 `RecordWriter` 在 lib 裡完全沒有被用到（只有測試用），「唯一寫入入口」在 PR 1 只是元件；PR 內文可寫清楚。
- 111 BleGate 不另外擋藍牙關閉：可接受（NodeLink 的前提擋住；舊頁面本來就自己處理）。
- 112 啟動頁 5 s 沒提示：可接受；副作用是 5 s 內連按兩個入口時第二個會跳「另一個操作還在進行：<第一個>」，不影響正確性。
- 113 openRawPage navigator 卸載：可接受。
- 114 F-m6 / J-m3：可接受，文字要涵蓋 MINOR-2。
- 115 msg2 之後不看連線狀態：我核對了：連線斷了之後下一個 `link.write` 會因為 `_down` 丟 Refused（ble_gate.dart:85）立刻結束；只有在等回答時才會等滿 20 s。結果正確，可接受。
- 119 G-m3 舊登入例外時區域連線沒取消：PR 之前就有，可接受。

## 之前各輪的發現

I-m1、I-m3、J-m1、J-m2 的修正都有會 FAIL 的測試（上表 M1、M2、N1、N2）。J-m5：`LeaseRegistry.token` 標 `@visibleForTesting`，lib 裡沒有人用（grep 只找到 GateScan / GateLink / Lease 自己的 `token` 欄位）。其餘各輪的修正抽查（N4、N5、N6、N8、N9、N10、N12–N14）都會 FAIL。

## 沒做的

- ❌ 沒有上真機（brief 禁止 adb）。MINOR-1、MINOR-4 是讀程式推論，沒有寫測試重現。
- ⚠️ 惡意裝置用輪換位址拖慢讀取：只從程式推論每個位址最多 8 s，沒有量排程層的總影響（核心不在本輪範圍）。
