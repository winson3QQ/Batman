# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 70209ef）第三輪程式審查：審查 F

審查範圍：整個 PR（排程核心 `core.dart` 只看新程式怎麼用它）。重點在安全：logcat trace、msg2 改動後的 prober、
fail-closed 的 `RawBusy` 與佔用的生命週期，以及 #329「實作殘項」能不能接受。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、2 MAJOR、7 MINOR。

程式本身在我追過的每條路徑上行為都正確：佔用、gate、prober 的信任邊界、log 遮罩都成立，沒有找到 secret 進 logcat
的路徑。剩下的問題有兩個：
- 第二輪的 MAJOR C-M1（接線層的修正沒有能 FAIL 的測試）只關了一部分。C 列的 9 個接線改壞裡，6 個在 70209ef 上全套照樣
  409 PASS，另外我又找到一個（F-M1）。
- 設計把 A13 定為「量到之前自動讀取不合併」，這個 PR 沒有量，也沒有記錄使用者撤銷這個條件（F-M2）。

## 基準（✅ 已驗證）

我的副本：`scratchpad/core/pr1F`，用 `git archive 70209ef app` 匯出，另外為 Rust 測試匯出 `tests/vectors`（見下）。

| 項目 | 結果 |
|---|---|
| `flutter test --no-pub test`（全套） | ✅ `00:19 +409: All tests passed!` |
| `flutter test --no-pub test/nodelink test/claim_flow_test.dart` | ✅ `00:21 +204: All tests passed!` |
| `flutter analyze --no-pub lib test` | ✅ 1 個 info（`member_ui_test.dart:4`，原本就有） |
| bridge `cargo test --offline`（WSL，自己的 `CARGO_TARGET_DIR`） | 第一次跑：❌ `58 passed; 4 failed`，四個都是 `NotFound`（`claim.rs:640`、`rekey.rs:560`、`replay_node.rs:46`）。**歸因（翻轉測試）**：這四個測試讀 repo 根目錄的 `tests/vectors/219-protocol/vectors.json`，我只匯出了 `app/`。只多匯出 `tests/vectors`、其他完全不變之後重跑：✅ `test result: ok. 62 passed; 0 failed` |
| frb glue 欄位順序 | ✅ Rust `sse_encode` 先 `login_end` 後 `login_code`（frb_generated.rs:3682-3683），Dart decode 同序（frb_generated.dart:6100-6101） |

## 我做的改壞對照

一次只改一處。工具是 `scratchpad/core/pr1F-tools/mut.sh`，每一項的完整輸出在 `pr1F-tools/out/<名稱>.txt`。

### 第二輪修正的守衛（大部分成立）

| # | 改壞 | 跑的範圍 | 結果 |
|---|---|---|---|
| F1 | prober：任何 frame 都算 msg2（第二輪 D-2 之前的寫法） | test/nodelink | ✅ FAIL（`r2 D-2: fragments …`） |
| F2 | `RawBusy` 拿不到佔用時吞掉 StateError（fail-open） | nodelink + claim_flow | ✅ FAIL（`r2 D-3`） |
| F3 | `RawLeaseScope.dispose` 不呼叫 `pageGone` | nodelink + claim_flow | ✅ FAIL（2 個：`A-M1 real page`、`r2 C-m2 / D-10`） |
| F6 | `_forwardLog` 不遮罩 | test/nodelink | ✅ FAIL（`T-S4`） |
| F10 | 拿掉 msg2 之後的 20 s `answer` 計時 | test/nodelink | ✅ FAIL（`r2 D21`） |
| F11 | `openRecord` 失敗時不呼叫 `keyCheck` | test/nodelink | ✅ FAIL（`r2 X13`）；不過見 F-m4 |
| F12 | `bleStatusToRadio`：poweredOff → 不變 | test/nodelink | ✅ FAIL（2 個） |
| F13 | 清理時 `dispose` 不包 try | test/nodelink | ✅ FAIL（`S20 …`） |
| F14 | 登入結束 4：EForbidden 和其他錯誤碼對調 | test/nodelink | ✅ FAIL |
| F23 | `rawScanStarted()` 什麼都不做（C 的 CM8） | 全套 | ✅ FAIL（`A-M1 real page`） |
| F24 | `ClaimPage.rawUse => null`（C 的 CM2b） | 全套 | ✅ FAIL（`A-M1 real page`） |

### 沒有測試能抓到（全部 `All tests passed!`）

| # | 改壞 | 跑的範圍 | 使用者會碰到什麼 |
|---|---|---|---|
| **F16** | main.dart `_open` 永遠走「沒有 NodeLink」的分支（`final AppLink? a = null;`），不拿佔用 | 全套 409 | 舊頁面和自動讀取同時用藍牙（A-M1 本身） |
| **F17** | `NodesPage.rawUse => null`（C 的 CM1b） | 全套 409 | 「我的節點」登入或操作時按返回，佔用立刻放掉，兩個藍牙使用者 |
| **F18** | `ScanPage.rawUse => null`（C 的 CM9） | 全套 409 | 同上（讀狀態的 30 s 內） |
| **F21** | nodes.dart 拿掉「頁面離開後才登入成功 → `_drop()`」（C 的 CM4） | 全套 409 | 頁面不在了，連線還開著 |
| **F19** | `AppLink.create` 不呼叫 `wireRadio`（C 的 CM5） | 全套 409 | 藍牙關掉時顯示「手機連不到節點」，而不是「藍牙沒有打開」 |
| **F20** | `AppLink.create` 不接 `keyError`（C 的 CM6） | 全套 409 | 金鑰被拒時顯示「連不到」 |
| **F22** | 啟動時不傳 `keyOk: keys.login`（C 的 CM7） | 全套 409 | 金鑰不能用時沒有 2.4 |
| F15 | prober：8 s 期限在 msg2 之後也會結束這次嘗試（拿掉 `if (!gotMsg2)`） | test/nodelink | 從連線開始到狀態頁讀完超過 8 s 的節點，每次都變成「沒有回應」（F-m1） |
| F4 | AppLink 的 prober log 不遮罩 | nodelink + claim_flow | 完整 id 和 MAC 進 logcat（F-m2） |
| F5 | NodeLink 例外 trace 不遮罩 | test/nodelink | 同上（F-m2） |
| F7 | `openRawPage` 拿掉「navigator 已卸載 → 釋放」 | nodelink + claim_flow | 佔用永遠不放，自動讀取停到 app 重開（F-m5） |
| R1 | Rust `login_end_kind`：`CertRejected` → `(5, 0)` | cargo test（62） | 「身分不符」變成「沒有回應」，識別警報被藏起來（F-m3） |
| F8 | RecordWriter 拿掉 `identical(reg.current, l)` | test/nodelink | 不算發現：這個改壞和原本等價（`l.valid` 已經要求 token 是目前的，每份佔用的 token 都不同，lease.dart:43、:113） |
| F9 | `NodeLink.dispose` 不移除監聽 | test/nodelink | 不算發現：正式版的 AppLink 是單例，不會 dispose |

## 發現

### MAJOR

**F-M1：第二輪 C-M1 只關了一部分。舊頁面與 AppLink 的接線，7 處改壞後全套照樣通過**

- 情境：70209ef 把接線抽成函式（`wireRadio`、`keyErrorToRadio`、`openRawPage`、`RawLeaseScope`），也幫 ClaimPage 補了一個
  真頁面的測試。但呼叫這些函式的地方沒有測試：
  - `AppLink.create` 裡的 `wireRadio(ble.statusStream, link)`、`keyError:`（app_link.dart:56、:86）；
  - main.dart `_open` 走不走 `openRawPage`，以及 `radio(keyOk: keys.login)`；
  - NodesPage、ScanPage 的 `rawUse`；
  - nodes.dart 的「pop 之後才登入成功 → `_drop`」。

  拿掉任何一處，行為就會退回第一輪的 A-M1 / A-M3 / B-M5，例如「我的節點」登入中按返回，自動讀取和登入同時用藍牙；藍牙關掉
  時顯示「連不到」。
- 證據：上表 F16–F22，輸出在 `pr1F-tools/out/F1[6-9]*.txt`、`F2[0-2]*.txt`，每一個的結果都是 `+409: All tests passed!`。
  C 的 9 個改壞（review-pr1-r2-C.md 的 CM 表）只有 CM2b、CM3、CM8 現在會 FAIL（F24、F3、F23）。
- 為什麼是 MAJOR：被宣稱修好的 MAJOR，它的守衛在修正被拿掉時不會 FAIL。這一層正是 PR 2 / PR 3 會重寫的地方。
- 修法：
  1. NodesPage 照 `claim_flow_test` 的 `A-M1 real page` 做一個：假的 BLE 讓 `_login` 卡在連線上，pop，斷言
     `reg.current` 還是那份佔用；放開之後佔用釋放、連線被 `_drop`。ScanPage 的 `_read` 做一個同樣的。
  2. `StartupCheck` 測試注入 `makeLink`，用假的 AppLink 點「我的節點」，斷言拿到了佔用、`pageGone` 在 pop 之後呼叫。
  3. 把 `AppLink.create` 裡建 NodeLink 的部分抽成 `AppLink.build(statusStream, platform, …)`，讓測試餵 `poweredOff`，斷言
     `Why.bluetoothOff`；同一個測試給 prober 的 `signOwner` 丟 `PlatformException('keyLevel')`，斷言變成 `Why.keys`。
  4. 每一項附 F16–F22 的負向對照。

**F-M2：設計的合併條件 A13（對已準備更新的節點自動登入、讀狀態，不影響那次更新）沒有量，也沒有記錄使用者撤銷這個條件**

- 情境：使用者用舊控制台在節點上準備了一次軟體更新，然後關掉控制台。從 PR 1 起，自動讀取會在 6 s 後登入那台節點、讀
  狀態頁（X22）。會不會打斷節點上那次更新，現在沒有任何證據。
- 證據：
  - 設計 `329-app-uiux.md:504`（X22）：「A13 ⚠️ 在 PR 1 的真機場次量（要同意）；量之前自動讀取不合併進 main」。
  - 同一份設計 :1003、:1032、:1065（§12 第 1 列）：「A13 在這個 PR 的真機場次量，量到之前不合併」。
  - PR 本文的測試段：「❌ B 組真機場次：R-1–R-6、A13、A22」。
  - PR 本文的偏離段寫「A 組量測（A1、F22、A21 / A26、A11）併入 B 組真機場次（使用者 2026-11-15 決定）」。A13 不在這個
    清單裡，#329 的實作殘項也沒有提。
- 為什麼是 MAJOR：會不會讓使用者的節點更新失敗，現在不知道；設計自己把它定為合併的阻擋條件。這不是程式碼本身的錯。
- 修法（二擇一）：
  1. 合併前在真機量 A13（要準備一次更新，改節點狀態，要使用者同意）；
  2. 請使用者明確決定 A13 改到 B 組、不再阻擋合併，把決定記進 #329 和設計 §12 / §9.3，並在 PR 本文的偏離段寫出來。

### MINOR

**F-m1：「msg2 之後 8 s 期限不再適用」這條規則沒有能 FAIL 的測試**

- 情境：F15 讓 `due` 在 msg2 之後也結束嘗試，`test/nodelink` 照樣 195 PASS。
  - `r2 D21` 的 `answerMax` 是 100 ms，`due` 是預設的 8 s，所以 8 s 期限根本來不及觸發。
  - 其他測試的 frame 每 1 ms 一個，整次登入都在期限之內完成。
  - 真機上舊 app 一次登入 4.1–10.6 s（PR 本文）。這條規則一旦被改壞，慢一點的節點每次都會顯示「沒有回應」。
- 證據：我寫了負向對照 `review F: after msg2 the 8 s budget no longer ends the attempt`
  （`pr1F-tools/prober_test.reviewF.dart` 的最後一個測試）：msg2 期限設 100 ms，msg2 在約 30 ms 到，後面的 frame 在
  約 280 ms 到。
  - 在 70209ef：`+1: All tests passed!`。
  - 套上 F15：`Expected: Res:<Res.body> Actual: Res:<Res.noResponse>`。
- 修法：把這個測試收進 prober_test.dart。

**F-m2：prober 的 log 和 NodeLink 的例外 trace 有遮罩，但沒有測試守著（F4、F5）**

- 現況是對的：
  - app_link.dart:54 用 `NodeLink.mask` 包住 prober 的 log；
  - node_link.dart:288 的例外 trace 也包了 `mask`；
  - T-S4（review_pr1_test.dart:372-398）只測 core log 和 `attempt` 那一行。
- 會進 logcat 的內容，我逐一查過：
  - `probe $id`：id 是 hex（nodecert.rs:118 `device_id = hex_lower(&sn)`），≥8 個 hex 字元會被截成後 4 碼。
  - 例外文字：
    - Keystore：`PlatformException(keystore, "<類別>: <訊息>")`（MainActivity.kt:121、:133）；
    - Rust 字串：例如 `手機裡的節點資料損壞（cbor: Unsupported(xx)）`，最多帶紀錄的 1 個 byte（owner.rs:167、cbor.rs:29-43）；
    - flutter_reactive_ble 的失敗訊息：帶 MAC，被第二條 regex 截成最後一組。
  - 沒有任何路徑會把紀錄明文、簽章、owner_tag_key、QR、frame 內容寫進 log：
    - prober 只 log 例外的型別與訊息，以及 `loginEnd` / `loginCode`（prober.dart:95、:139、:148、:157）；
    - `ended` 的 `detail`（可能帶 `{e:?}`）不會被 log。
  - logcat 在 Android 4.1 以後只有 system 或 adb 讀得到。
- 修法：T-S4 補一段，走 `SessionProber`（用 app_link 的 log 接線，或者把那個 lambda 抽出來）加上一個會丟出含完整 id 與 MAC
  訊息的例外，斷言輸出裡沒有 ≥8 個連續 hex 字元、沒有 `AA:BB`。

**F-m3：Rust 的 `login_end_kind` 沒有斷言 `CertRejected → 3` 和 `AuthRefused(Ok) → (4, 0)`**

- 情境：R1 把 `CertRejected` 對應成 5，`cargo test` 照樣 `62 passed`。
  - Dart 的 prober 測試用的是假的 `loginEnd` 值，抓不到 Rust 這一端。
  - 結果是節點的 DAC 和手機釘住的不同時（被換掉或被複製的節點），本來要顯示「身分和手機記錄的不同」，會變成「連不到」。
    這是最重要的識別警報。
- 證據：owner.rs 的測試（PR diff :1883-1887）只斷言 LoggedIn、Msg2Undecryptable、AuthRefused(Err)、Broken。
- 修法：補 `assert_eq!(login_end_kind(&End::CertRejected(..)), (3, 0))` 和 `AuthRefused(Outcome::Ok(..)) → (4, 0)`。

**F-m4：X13 的守衛測的是一條正式版走不到的路徑**

- 情境：
  - `openRecord` 呼叫 Kotlin 的 `open`，而 `open` 不經過金鑰閘門（MainActivity.kt:70-71「Not gated: `open`」），錯誤碼一律是
    `keystore`（:130-134）。
  - `keyErrorToRadio` 只認 `keyLevel`（key_abilities.dart:97），所以紀錄金鑰出錯時永遠不會出現 2.4。
  - 測試 `r2 X13` 只斷言 `keyError` 被呼叫，丟的還是 `StateError('keyLevel')`，不是 `PlatformException`。
- 判斷：使用者會看到的結果和殘項 2 寫的一樣（顯示「連不到」）。啟動時的 `keyLevels` 會檢查 RECORD_AES 在不在
  （KeyPolicy.kt:9、KeyHandlers.kt:31-40），所以只有在執行中金鑰壞掉才會碰到。可以接受。
- 修法：殘項 2 補一句「紀錄金鑰（`open`）出錯一律顯示『連不到』，2.4 只來自簽章」；或者刪掉 X13 測試名稱裡的宣稱。

**F-m5：`openRawPage` 的「navigator 已卸載 → 釋放佔用」（第一輪 A-m4）沒有測試（F7）**

- 拿掉之後，佔用永遠不放，自動讀取要停到 app 重開。實際上很難走到（要在拿佔用的最多 5 s 內卸載 `StartupCheck` 的
  navigator），所以是 MINOR。
- 修法：一個 widget 測試：`acquire` 期間卸載 navigator，斷言之後 `reg.current == null`。

**F-m6：「我的節點」閒著時按返回，佔用在連線還沒斷的時候就交回；兩個藍牙使用者不重疊，只靠 `afterLease` 這個 6 s 常數**

- 情境：
  - NodesPage 的 `dispose` 呼叫 `_drop()`，沒有 await（nodes.dart:146-148）；
  - `RawLeaseScope.dispose` → `pageGone()` → 閒著 → 立刻釋放（lease.dart:72-75）；
  - gate 看不到舊頁面的連線，`gate.links == 0`。

  第二輪 D 的 MINOR-10 前半段（改成在 dispose 時才交回）已修。後半段（在常數旁邊註明這個依賴）沒做：core.dart:19 沒有說明。
  §4.4 寫的是「釋放：先等斷線完成」。
- 修法：在 `afterLease` 旁邊寫明「舊頁面的連線在釋放時可能還沒斷（PR 3 / 6 之前）」，或者讓 `_drop` 在 dispose 時被
  `hold()` 撐住，等連線斷了才釋放。

**F-m7：prober 不看連線狀態。連線在 msg2 之後斷掉，要等 `answerMax` 20 s（或核心截斷）才結束**

- 情境：`probe` 只聽 TX 的訂閱（prober.dart:133-151），沒有聽 `link.state`。
  - 連線在 msg2 之前斷掉：等到 8 s 期限才結束。
  - 連線在 msg2 之後斷掉：沒有寫入的話，等到 20 s。
  - 結果對（broken / noResponse），只是浪費一輪的時間。
  - ⚠️ 推論：flutter_reactive_ble 斷線時，特徵值訂閱會不會丟出錯誤，我沒有查證；如果會，`onError` 已經會結束這次嘗試。
- 修法：`link.state.where((up) => !up).first.then((_) => done(failed()))`。

## 第一、二輪發現的關閉狀態

| 發現 | 狀態 |
|---|---|
| C-M1 接線層沒有測試 | ⚠️ 部分關閉，見 F-M1 |
| C-m1 / D-1 明文歸零 | 改成殘項 3（S20 上平台通道的緩衝區是唯讀的，d350838）。可以接受，見下 |
| C-m2 / D-3 / D-10 前半 fail-open、pop 時就交回 | ✅ F2、F3 會 FAIL |
| C-m3 / D-5 待辦沒有顯示 | ✅ PR 本文已改成「PR 2 的首頁才會顯示」；`readWall` 仍然沒有人讀（PR 2） |
| C-m4 / D-7 X12 / X9 / X13 | ✅ 有測試（`r2 X12 / X9`、`r2 X13`）；X13 見 F-m4 |
| C-m5 ClaimPage 沒有 `PopScope` | 改成殘項 1，見下 |
| C-m6 dispose | ✅ 已修（node_link.dart:253-256、:329）；正式版不會走到 |
| D-2 片段不算 msg2 | ✅ F1 會 FAIL；新的反方向缺口見 F-m1 |
| D-4 X26 | 改成殘項 2，見 F-m4 |
| D-6 raw_use 說明 | ✅ raw_use.dart:1-4 已寫明收回不會停下頁面 |
| D-8 D11 / D14 / D17 / D21 | ✅ 有測試；D21 會 FAIL（F10） |
| D-9 設計文字 | ⚠️ §4.4（:577）已改。§12 第 1 列（:1065）仍寫「回填之前不寫任何 NodeLink 程式」「八個寫入點全部改經 RecordWriter」「`ClaimRecovery` … `lease.run`」「A13 量到之前不合併」，和 PR 的偏離不一致（併入 F-M2 一起改） |
| D-10 後半 | ⚠️ 見 F-m6 |

## #329 實作殘項：能不能接受

1. **舊 ClaimPage 認領中按返回，結果顯示在已關掉的頁面上：可以接受。**
   - 佔用撐到認領結束，紀錄在佔用之下寫入。`A-M1 real page` 斷言 pop 之後 `reg.current` 還是同一份佔用、`write node/<id>`
     有發生、結束之後才釋放。
   - 首頁清單會在釋放 6 s 後讀到新節點。
   - C 算過最長約 300 s，不到 420 s。
   - 代價是使用者看不到結果，PR 3 換掉這頁時解決。
2. **X26 只認 `keyLevel`：可以接受**，但說明要補一句（F-m4）。
3. **明文無法在 Dart 清零：可以接受。**
   - S20 上緩衝區是唯讀的，`S20 …` 測試守著「清理不改變結果」（F13）。
   - Kotlin 的 `open` 也沒有清掉自己的 ByteArray（MainActivity.kt:130-134），舊頁面都一樣。
   - Rust 的 session 在 `finally` 裡 dispose（prober.dart:170-174）。
   - 要讀到 heap 需要 root 或 debugger。
4. **從沒連上就被取消的連線會不會送 disconnected：可以接受。** 最壞情況每次多 5 s，有 `closeMax` 封頂（ble_gate.dart:115-118）。
5. **藍牙關閉 / 權限收回只在假的狀態流上測過：可以接受**，B 組真機看。但 `AppLink` 有沒有接上狀態流，目前連假的測試都沒有（F19，見 F-M1）。

**缺了一項：** A13（F-M2）。PR 本文的偏離「420 s 收回之後舊頁面的工作 gate 擋不住」我也查過：
- ClaimPage 約 300 s；
- NodesPage 的 `_watchLink` 在 `!mounted` 時就離開（nodes.dart:684）；
- `_askSw` 在 dispose `_drop` 之後 `_session == null`，回 noLink；
- 一般的 `_ask` 被 `_wait` 計時（最長 `_joinWait`）收尾。

現有流程都在 420 s 內結束，可以接受。

## 安全（逐個角色）

- **附近的惡意 BLE 裝置**：
  - 它可以廣播 provd UUID，被排進嘗試。
  - 只送片段：8 s 結束（D-2 已修，F1 守著）。
  - 送一個完整但解不開的 msg2：Rust 回 Ended(2) 或 Ended(5)，馬上結束，結果是 undecryptable / noResponse（prober.dart:96-103）。
  - 拿不到 owner 簽章：Sign 只在 Rust 的 Login 解開 msg2、驗過 DAC 之後才會出現，而且簽的輸入由 Rust 產生。
  - 讓 app 顯示「身分不符」或「拒絕」要有那台節點的 owner_tag_key，它沒有。
  - 洪水式送 frame：每個 frame 是一次同步的 Rust 呼叫，受 8 s / 20 s 與核心截斷限制。
  - 觀察（不算發現，屬於核心的範圍）：偽造某台節點的位址，回一個解不開的 msg2，能讓那個位址被記成「不是 Y」。效果和
    干擾訊號一樣是拒絕服務。
- **其他 app**：logcat 要 READ_LOGS（system / adb）才讀得到，內容也遮罩了（F-m2）。藍牙堆疊共用的情況沒有改變。
- **被攻陷的節點**：
  - 它只能回自己的狀態；msg2 之後最多拖 20 s（F10 守著）。
  - 讀取中不會走到 owner-op：Rust 的 Conn 只有在 `asked == "op/nonce"` 時才會回 Sign（owner.rs:859-871），而讀取從來不送
    op/nonce。
  - SignAdmin、Persist*、Wait 都走 `default`，放棄這台節點，什麼都不寫（prober.dart:105-109；「a step that would write a
    record」守著）。
  - 錯誤碼 3 = EForbidden 是它自己的判定。
- **我們自己的錯**：接線層的測試（F-M1）、post-msg2 規則（F-m1）、Rust 的 CertRejected 對應（F-m3）。
- **寫入者**：正式版沒有使用 `RecordWriter`。舊頁面直接寫（nodes.dart:256、:460、:742、:1003、:1234；claim_records.dart:49、:53），
  都在它們的原始佔用之下。NodeLink 與 prober 不寫任何紀錄。420 s 之後的窗口見上。
- **佔用會不會永遠不放**：
  - 頁面閒著時 → dispose 就交回；
  - 頁面忙著時 → 工作結束交回，最多 420 s 後收回（lease.dart:72-81、:129-138）；
  - `openRawPage` 在 navigator 已卸載時釋放（未測試，F-m5）；
  - `RawBusy` 的 hold 計數只增減一次，setter 對同一個值什麼都不做（raw_use.dart:22-34）；
  - 頁面還在的時候，佔用不會失效（只有 `pageGone` 之後才會收回），所以 fail-closed 只作用在已卸載頁面的延續工作上。

## 生命週期（簡表）

| 路徑 | 行為 | 證據 |
|---|---|---|
| 啟動 / `start` 失敗 | 啟動結果留在畫面上，`_app` 是 null，舊頁面不拿佔用，NodeLink 沒有開始 | main.dart `_run` |
| 背景 / 前景 / inactive | paused / hidden / detached 算背景，取消一輪並斷線；inactive 不變 | node_link.dart:124-133，T20 |
| 藍牙關閉 | `statusStream` → 2.3（但接線沒有測試，F19） | app_link.dart:86、:112-115 |
| 權限收回 | process 被系統殺掉，重開後是 `unauthorized` → 2.2 | ⚠️ 沒有實機驗證（殘項 5） |
| 拿佔用時，一次嘗試正在連線 | `_dropAll` 會 `_abort`，最多等 5 s 讓連線消失；token 換掉之後 GATT 會被拒 | node_link.dart:147-154、:314-325；ble_gate.dart:82-84 |
| 釋放之後讀紀錄，期間又拿了佔用 | 核心維持佔用，寫入的 id 等下一次釋放 | node_link.dart:174-180；`r2 X12 / X9` |
| 頁面忙著時被關掉（420 s） | 撐到工作結束或 420 s | F3、`A-M1 real page` |
| App 被殺 | 佔用只在記憶體裡，重開就沒有佔用 | lease.dart |

## 我寫的東西（都在 scratchpad，沒有 commit）

- `scratchpad/core/pr1F-tools/mut.sh`：一次改一處的工具（perl 套用 → `flutter test --no-pub` → 還原）。
- `scratchpad/core/pr1F-tools/out/*.txt`：F1–F24 每一項的完整輸出。R1（Rust）的結果是上面那行 `62 passed`，是手動跑的。
- `scratchpad/core/pr1F-tools/prober_test.reviewF.dart`：prober_test.dart 加上 F-m1 的負向對照（最後一個測試）。
  在 70209ef PASS，套上 F15 FAIL。
