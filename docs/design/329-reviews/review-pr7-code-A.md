# #329 PR 7 程式碼審查 A（3020374..6d763d8）

審查者：獨立對抗式審查 A。範圍：只審新程式碼（基準設計 v12.1 與 PR 1–6 已審過）。凍結計畫：`docs/design/329-pr7-plan.md` v4（§10 / §11 覆蓋）。
只在 `C:/src/Batman-329pr7b`（detached 6d763d8）讀檔與跑測試；沒有碰 `C:/src/Batman-329pr7`、手機或模擬器。

## 結論

**BLOCKER 0 · MAJOR 1 · MINOR 7 → APPROVE-WITH-CHANGES**

產品邏輯的重點項目（T14 三態、T1 open 只查 RECORD_AES、T2 回覆後清零、T3 原始碼鎖、T6、T8 queued 不算、T11、T20）我都讀過，並且用負向對照確認測試會 FAIL。唯一的 MAJOR 是測試的完整性問題：CI 上對比規則會被跳過，但結果仍然是「通過」。MINOR 是顯示上的競爭與邊界情況，以及文件和實作不一致的地方。

## 實跑證據

### ✅ 驗過（附原始輸出）

- Windows 全套 `flutter test`（6d763d8，還沒做任何突變之前）：`01:03 +2069: All tests passed!`，`EXIT 0`。log 裡 `A11Y-SKIP` 出現 0 次，代表 Windows 上有載入 CJK 字型，對比規則確實有判。
- `flutter analyze lib test device_check tool`：`No issues found! (ran in 30.8s)`。
- WSL `cargo test --lib`（bridge，`CARGO_TARGET_DIR=$HOME/tgt-329pr7-ra`），還原之後：`test result: ok. 90 passed; 0 failed`。
- 負向對照：每次只改一行，跑完用 `cp` 還原，再用 `cmp` 和 `git diff --stat` 確認還原乾淨。

| # | 改動 | 結果 |
|---|---|---|
| 1 | `main.dart` `_install` 的 `catch (e)` 改成 `on StateError catch (e)`（等於 T14 分支失效） | `key_abilities_test.dart: ... T14: no marker, the record store unreadable -> no firstRun ...` FAIL |
| 2 | `core.dart` `if (c != Concl.queued) s.roundsEnded++;` 改成無條件 `s.roundsEnded++;` | `first_rounds_test.dart: T8 (E m-11): a target still 排隊中 ...` FAIL |
| 3 | `home_page.dart` T11 改回「讀清單時就過濾」，`_pending = _pendingIds.length` | `pr7_pages_test.dart: T11: a claim-pending todo whose node record arrives after ...` FAIL |
| 4 | `node_page.dart` `extra: _radioButton(a)` 改成 `extra: null` | `pr7_pages_test.dart` T6 三條 FAIL（藍牙關閉、沒有權限、hint 加藍牙） |
| 5 | `scan.dart` `_scanHold = use.lease.hold();` 改成 `_scanHold = () {};` | `scan_page_test.dart` T20 四條 FAIL |
| 6 | `simple.rs` 讀資料夾錯誤改回 `Err(_) => continue`（等於 `unwrap_or(false)`） | `t14_kind_path_not_a_folder_is_an_error`、`t14_permission_denied_folder_is_an_error`、`t14_a_record_beside_an_error_is_true` FAIL（`an unreadable record folder must be an error, never "no record": false`） |

### ⚠️ 推論，或只讀了原始碼

- Kotlin（T1 / T2）：我讀了 `KeyHandlers.kt`、`Keys.kt`、`MainActivity.kt`、`KeyHandlersTest.kt`、兩個 lint 測試和 `KeyHandlersDeviceTest.kt`，但**沒有自己跑 gradle**。原因：審查期間 `git status` 出現 `M .../keystore/KeyHandlers.kt`，內容是拿掉 `fill(0)` 和 open 的 RECORD_AES gate。那不是我改的，是另一個程序在同一個 worktree 做 Kotlin 負向對照，後來已還原（我最後一次 `git status` 只剩 `?? docs/design/329-reviews/security-review-pr7.md`）。為了不互相干擾，我沒有再動 Kotlin。另外，`flutter test` 全套是在看到那個改動之前跑的，Dart 測試也不讀 Kotlin 原始碼，所以不受影響。
- MINOR 2 和 MINOR 3 的情境是從原始碼推出來的，沒有寫成測試去觸發。

### ❌ 沒做

- Kotlin JVM 測試（原因見上）。
- 模擬器的 `am instrument`。
- 真機。

## MAJOR

### MAJOR-1　CI 上兩條對比規則被跳過，結果仍是「通過」（違反「找不到東西可查的測試必須 FAIL」）

- **情境**：`app-tests.yml` 跑在 `ubuntu-latest`（`.github/workflows/app-tests.yml:36`），沒有安裝任何字型的步驟（grep 不到 `fonts` / `apt`）。`loadFonts` 依序找 `C:/Windows/Fonts/NotoSansTC-VF.ttf`、`/mnt/c/...`、`/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`，找不到就靜默跳過（`test/retest_s_shot.dart:25-34`）。這時 `contrastJudged == false`，`a11yFailures` 在 `test/support/a11y.dart:249`（`if (!contrastJudged) return out;`）直接回傳，不判 `contrast` 和 `contrast2x`。`expectA11y` 只 `print('A11Y-SKIP ...')`，測試照樣通過（`a11y.dart:276-280`）。結果是：之後某個畫面的對比退步，CI 全綠也不會發現。對比是 #329 第 88 行的驗收項目，第 87 / 92 行也靠這些畫板。
- **證據**：上面引的那幾行；檔頭也寫明「such a run does not judge contrast」（`a11y.dart:21-22`）。⚠️ GitHub runner 映像裡有沒有那個 `.ttc` 我沒查到；如果有，這條降為 MINOR（但 stale exception 的檢查只在 Windows 做，`a11y.dart:285`，這點仍然存在）。
- **修法**：
  1. `app-tests.yml` 在 test-all 之前加 `sudo apt-get install -y fonts-noto-cjk`。
  2. `contrastJudged` 是 false 時讓畫板 FAIL；只有明確設了環境變數（例如 `A11Y_NO_FONT_OK=1`）才降成 SKIP，而且 test-all.sh 要把 SKIP 數印成 FAIL 或 ❓，不能算 PASS。
  3. 如果 Linux 字型下 Flutter 那條規則的結果不同，`a11yExceptions` 要按平台分開列，或把 stale 檢查也套到 Linux。

## MINOR

### MINOR-1　T8 的「頭兩輪」可能一直不結束；首頁第 10 列用全體旗標，點名的節點可能不對

- **情境 A**：只有一台節點，它的 `是 Y` 記憶位址已知，但每次登入都超過一輪的上限（`p.cap`）。每一輪結束時它都是 `Concl.queued`（`core.dart:646-648`），所以 `roundsEnded` 一直是 0，`firstRounds` 一直是 true；`concluded` 也是 false（`home_logic.dart:113`）。首頁第 5 列「正在找你的節點…／你不用按任何東西。通常幾秒鐘。」會**一直**顯示，而且沒有「重新讀取」。改之前是 `roundsRun < 3`，三輪後就轉到第 10 列（有重新讀取）。作者自己的測試 `first_rounds_test.dart` 第 3 條就證實 260 s 後仍 `firstRounds == true`，只是沒有測首頁的後果。
- **情境 B**：`home_logic.dart:144` 的 `i.firstRounds` 是「有任何一台還在頭兩輪」（`home_page.dart:314`）。新認領一台 B（`roundsEnded = 0`）的時候，已經過了頭兩輪的 stale 節點 A 會被顯示成「正在找A…」，而不是「還沒讀到A的狀態」。
- **修法**：
  - `firstRounds(id)` 再加一個上限，例如本次執行開始以來、包含這台的輪數 ≥ 3（不論結論）就結束。或者 `queued` 只在前 N 輪不算。
  - 第 10 列改用 `firstRounds(stale.first.id)`。第 5 列可以保留「任何一台」。

### MINOR-2　ScanPage：`_stop` 還在 await 時按「搜尋」，會變成沒有佔用在掃描（T20 想防的情況）

- **情境**：`_stop` 先 `await _scan?.cancel()`，之後才 `_scan = null; _dropScanHold()`（`scan.dart:132-137`）。這段期間「搜尋」是可以按的，因為條件只有 `_busy || _starting`（`scan.dart:201`）。如果使用者在這時按下：
  1. `_startScan` 看到 `_scanHold != null`，就不再取佔用（`:95`）；
  2. 接著 `_stop` 繼續執行，把佔用交回；
  3. `_startScan` 開新的掃描，但 `_scanHold == null`。

  結果是 NodeLink 可能在掃描中拿回藍牙。窗口只有幾毫秒，所以是 MINOR。
- **修法**：`_startScan` 在 `await cancelling` 之後才判斷並取 hold（`if (_scanHold == null) hold()`）；或者 `_stop` 先記下 `s = _scan`，只在 `identical(_scan, s)` 時才清除並交回；或者 `_stop` 執行期間停用「搜尋」。

### MINOR-3　ClaimPage `_fromPending` 在選擇／確認之前就改了失敗區的旗標

- **情境**：先有一次認領失敗，狀態區顯示「沒有新增節點 …ABCD」。接著使用者按「從認領暫存恢復」，然後在選單按「取消」，或在確認框按「取消」：
  - `_failFromPending = true`、`_recovering = true` 已經在 `claim.dart:197-201` 設好，選了之後 `_who` 也已經改成選中那台（`:228`）；
  - `_fail` 沒有清掉，因為確認框的取消說的是 `no`，不是 `[CLAIM_FAIL]`。

  所以狀態區會變成「沒有恢復節點 …PICK」，下面接的卻是上一次**認領**的失敗句，而且下一步也換成「從認領暫存恢復」那一套（`_failNext`，`:665-672`）。這條路只在開發版出現，也只影響顯示，所以是 MINOR。
- **修法**：這三個旗標等確認之後（開始恢復時）再設；或者 `_fromPending` 一開始就清掉 `_fail` 和 `_failHead`，跟 `_claim` 在 `:463` 的做法一樣。

### MINOR-4　device_contrast 的前景定義和凍結的 §4 不同，文件沒有同步

- **情境**：計畫 §4 寫死的是「前景 = 和背景亮度差最大、且佔 ≥ 2% 的顏色」。e611f9d 改成「佔**非背景**像素的 ≥ 2%，而且佔整個框的 ≥ 0.2%」（`tool/device_contrast.dart:132-155`），計畫、設計和 p1p2-check 都沒有寫這次改動（grep `非背景` / `non-background` / `minAbs` 都沒有結果）。另外，「亮度差最大」本來就偏樂觀：一個 uiautomator 的框裡如果有黑色 icon 或其他高對比元素，淡灰色的字也會被判 PASS。6 px 內縮只處理掉卡片邊框。
- **修法**：把新的定義、理由和 S20 那個例子寫回計畫 §4 和 p1p2-check。真機表格裡附上前景的佔比（現在 report 已經有），佔比低的 PASS 要人工看過。

### MINOR-5　字級的全域改動在沒有畫板的頁面上沒有驗證

- **情境**：StatusHero 主句從 21 改成 24（`widgets.dart:120`）、`BatButton` 從 17 改成 16、`titleLarge` 從 22 改成 18（`theme.dart` `sixLevels`）。這些對所有頁面生效。2.0 倍字級的溢出檢查只涵蓋有畫板的頁面。沒有畫板的頁面（例如 `main.dart` 退回用的啟動頁、對話框比較長的舊頁）溢出風險 ⚠️ 沒有驗證。
- **修法**：PR body 列出沒有畫板、但吃到這些改動的頁面，標成 ⚠️；或者用一個掃描測試，把每個 `StatusHero` 的使用處都放進 2.0 倍字級跑一次。

### MINOR-6　小地方

- `core.dart:585` 的 `s.notYetRun =c == ...` 等號後面少一個空格（沒跑 `dart format`）。
- `frb_generated.rs` 的 `use crate::api::*` 順序變了（codegen 產出不固定），diff 多了雜訊。如果將來要加「codegen 結果和 commit 一致」的檢查，這個順序會一直造成假差異。

### MINOR-7　計畫 §6 T14 的錯誤句和實作的分工

- **事實**：`lines[0] = '啟動檢查：${sayErr(unread)}$recordsUnreadKept'`。Rust 的技術段 `\u1E…\u1F` 夾在主句中間，靠 StatusHero 的 `screenText` / `techText` 拆開；測試有斷言 `hero-tech` 裡看得到技術段（`key_abilities_test.dart:712-715`）。這部分正確。
- **問題**：`_tech`（「技術資訊（給維修人員看）」與「複製文字」）裡沒有 store 的錯誤原因。複製文字是 `logText('$_report\n$_tech')`，`_report` 裡帶著技術段，所以複製的內容會有原因，但畫面上 `startup-tech` 那一格看不到。
- **修法**：`_recordsUnread` 不是 null 時，也 `tech.add('紀錄讀取：${techText(sayErr(unread))}')`，讓兩個地方一致。

## 確認沒有問題的項目（重點）

- **T14**：`store_has_records` 在 `NotFound` 時繼續、其他錯誤記下來後繼續；先把每一種紀錄都掃完，只要看到一筆有效紀錄就回 `Ok(true)`。`_install` 收到錯誤：不呼叫 firstRun；`_run` 不讀金鑰等級、不建 NodeLink，`retry = true`。「再試一次」會重設 `_recordsUnread`，再跑一次 sweep 和 marker。
  - 第一次安裝：目錄不存在 → `Ok(false)` → firstRun（現況）。
  - marker 遺失但有紀錄 → 不碰金鑰。
  - 種類資料夾讀不到 → `store_sweep` 先擋，進 catch，顯示「啟動檢查失敗」加重試。
  - FRB：`decodeErrorData: sse_decode_String`，丟出的是 String，`sayErr` 直接用。

  每一條啟動分支都對得上計畫 §6。
- **T1**：`KeyHandlers.open` 只讀 `level(RECORD_AES)`，錯誤碼和其他用途一樣是 `keyLevel` / `keystore`。`Keys.open` 改成 private，firstRun 的自我測試在類別內仍然可以用。MainActivity 的 open 走 `keyCall(result, wipe = true)`。lint 要求 `ecdh` / `open` 必須 `wipe = true`、其他都不帶，而且 `keyCall` 裡除了 `deliver` 沒有別的 `result.success`。
- **T2**：`KeyAnswer.deliver` 是在 `success` 回傳之後才 `fill(0)`。Flutter 的 `Result.success` 會同步完成 codec 編碼，跟原本 ecdh 的做法相同。
- **T3**：鎖會比對識別字（含 tear-off 與生成碼直接呼叫），每個允許的檔案限定呼叫數，掃到的檔案數 < 40 就 FAIL。
- **T6**：`openSystemSettings` 在 await 之前先取 `ScaffoldMessenger`。權限回來後呼叫 `radio(permission: true)`。藍牙關閉時 hint 裡的 SendKeyButton 變成停用的 secondary，確保只有一顆實心按鈕。
- **T16**：`fillX` 只用在一定含 `X` 的範本上（`_many`）。如果範本沒有 `X`，`indexOf` 會回 -1，`substring` 會丟例外；目前沒有這種呼叫。
- **§4 畫板的 a11y 例外**：只允許 Flutter 的 `contrast` 一條被豁免；被豁免時，Flutter 判 FAIL 的每一個節點都要在 contrast2x 裡逐一量到並且通過。在 Windows 上，例外如果已經不需要（stale）也算 FAIL。這套例外範圍窄、而且有真的依據；問題只在 MAJOR-1 說的 CI。
- **6d763d8**：
  - `runWaitFor`：「正在連到節點」= 1 分鐘，有寫明的照寫明，其他不說數字。
  - `swNext`：用的字串和 `swupd.rs:77-78` / `:128`、既有 `swupdate.dart:83` 一致。
  - `BatBanner` 改用 `BtnKind.text`。
  - claim 狀態區：忙碌時 Look.busy；逾時與停止用 unk；`shown` 會把失敗句從清單移掉。

  這些和 commit message 寫的負向對照都對得上（我沒有逐條重跑）。
