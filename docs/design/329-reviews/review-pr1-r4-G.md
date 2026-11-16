# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 26057eb）第四輪程式審查：審查 G

範圍：整個 PR（`core.dart` 只看新程式怎麼用它）。重點：從實際使用出發的端到端生命週期；每一條使用者依賴的規則有沒有能 FAIL 的測試（自己改壞接線：舊頁面、啟動頁、AppLink、NodeLink 的 start / release / lease）；以及這輪修正有沒有弄壞別的東西。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、1 MAJOR、3 MINOR。

這輪的修正本身都正確，而且大部分有能 FAIL 的測試：我做的 30 個改壞裡有 23 個被抓到（見下表）。但第三輪 E-M1 / F-M1 仍然沒有完全關掉。啟動頁把佔用交給「我的節點」「附近的節點」這兩行，改成 `use: null` 之後全套照樣 418 PASS。第三輪 E 的表直接列出這一條（E6），PR 說明卻寫「三個舊頁面與啟動頁的佔用接線 … 14 / 14 都有測試 FAIL」。另外找到一個啟動時的生命週期競態（G-m1），已附重現測試和修法的負向對照。

A13（合併條件）在等使用者決定，這裡只記錄，不算發現。#329 的「實作殘項」第 117 行已經把 A13 列為 PR 1 的合併條件。

## 基準（✅ 已驗證）

- 匯出：`git archive 26057eb app | tar -x` 和 `git archive 26057eb tests | tar -x`，放在 `scratchpad/core/pr1G`，沒有複製工作目錄。另外複製了 `.dart_tool/package_config.json` 和 `package_graph.json`。
- `flutter test --no-pub`：`00:19 +418: All tests passed!`
- `flutter analyze --no-pub lib test`：1 個 info（`member_ui_test.dart:4`，原本就有）。
- bridge `cargo test --offline`（WSL Ubuntu-24.04，`CARGO_TARGET_DIR=/home/yello/tgt-pr1G`）：`test result: ok. 62 passed; 0 failed`。
- Rust 的負向對照：把 `login_end_kind` 的 `End::CertRejected(_) => (3, 0)` 改成 `(5, 0)` → `make_network_needs_a_login ... FAILED`，panic 在 `owner.rs:1887`，`61 passed; 1 failed`。之後已還原，`cmp` 確認和 26057eb 相同。
- 每次改壞之後都還原，並用 `cmp` 對 `git show 26057eb:<file>` 確認。

## 我做的改壞對照

做法：一次只改一處，跑 `flutter test --no-pub`，範圍寫在表裡。工具在 `scratchpad/core/pr1G-tools/mut.sh`，每一項的完整輸出在 `pr1G-tools/out/G*.txt`。

### 沒有被抓到的（全部 `+418: All tests passed!`）

| # | 改壞 | 使用者會碰到什麼 | 對應先前的發現 |
|---|---|---|---|
| **G2** | main.dart：`NodesPage(ble: a?.ble, use: null)` | 「我的節點」沒有佔用：登入或操作時按返回，佔用立刻放掉，NodeLink 和頁面同時用藍牙（第一輪 A-M1 回來） | 第三輪 **E6**，這輪沒有關 |
| **G3** | main.dart：`ScanPage(ble: a?.ble, use: null)` | 「附近的節點」讀取中按返回也一樣 | 第三輪 E-M1 修法第 4 點要求「三個按鈕」 |
| **G4** | main.dart：拿掉 `if (_ok && _app != null) NodeStatusList(...)` | PR 1 唯一看得到的新東西（首頁的節點狀態清單）消失 | 第三輪 E-M1 修法第 4 點「`NodeStatusList` 有出現」 |
| **G5** | nodes.dart：拿掉登入前的 `rawScanStarted()` | 「我的節點」的掃描不算進 30 s 內 4 次。釋放後 NodeLink 可能成為 30 s 內第 5 次掃描，Android 會悄悄不給結果，那一輪就把節點判成「連不到」 | 第三輪 **E3**，這輪沒有關 |
| **G22** | claim.dart：`ReactiveRecoveryBle(_ble)`（拿掉 `onScan: rawScanStarted`） | 同上（恢復時的掃描） | 第三輪 **E14**，這輪沒有關 |
| G1 | main.dart：拿掉 `life: WidgetsBinding.instance.lifecycleState` | 啟動檢查期間按 HOME：NodeLink 在背景照讀，回前景時舊的讀取也不會標成不新鮮（第三輪 E-m1 回來） | 這輪 E-m1 的修正，見 G-m1 |
| G13 | raw_use.dart：拿掉 `!nav.mounted → release` | — | 已列在殘項（F-m5），可以接受 |

### 被抓到的（✅ FAIL）

| # | 改壞 | 抓到的測試 |
|---|---|---|
| G7 | nodes.dart：拿掉 `ok && !mounted` 之後的 `_drop()`（第一輪 B-M1） | `r3 E-M1: 我的節點 popped mid-login…` |
| G24 | nodes.dart `_login` 的 finally 改成 `if (mounted) rawIdle()`（第三輪 E1） | 同上 |
| G25 | `NodesPage.rawUse => null` | 同上 |
| G8 | scan.dart 的 finally 改成 `if (mounted) rawIdle()`（E4） | `附近的節點: the scan is counted; popped mid-read…` |
| G9 | scan.dart：`_busy = true` 移到 `await _stop()` 之後（E-m6） | 同上（`Expected: same instance as Lease, Actual: null`） |
| G26 | scan.dart：拿掉 `rawScanStarted()`（E5） | 同上 |
| G27 | `ScanPage.rawUse => null` | 同上 |
| G23 | main.dart：`ClaimPage(..., use: null)` | `r3 E-M1: 認領節點 opens ClaimPage under a raw lease…` |
| G28 | main.dart `_open` 永遠不拿佔用（`final AppLink? a = null`，F16） | 同上 |
| G19 | main.dart：拿掉 `a.link.radio(keyOk: keys.login)`（E7） | `r3: login not allowed at startup…` |
| G11 | app_link.dart：拿掉 `addObserver(_Life(link))`（E9） | `AppLink: lifecycle, Bluetooth status and key refusals…` |
| G20 | app_link.dart：拿掉 `wireRadio(...)`（E10） | 同上 |
| G21 | app_link.dart：拿掉 `keyError:`（E16） | 同上 |
| G12 | app_link.dart：prober 的 log 不遮罩（F4） | `r3 F-m2: the probers log lines reach logcat masked` |
| G30 | node_link.dart：例外 trace 不遮罩（F5） | `r3 F-m2: an attempts exception reaches the trace masked` |
| G10 | node_link.dart：`start` 不理 `life` | `r3 E-m1: started while the app is already in the background…` |
| G29 | prober：msg2 之後 8 s 期限仍然結束這次嘗試（F15） | `r3 F-m1: once msg2 arrived…` |
| G14 | `acquire` 不 `await _dropAll()` | `B-M6a: acquire returns only once the round's link is gone` |
| G15 | `released` 不看 `reg.current`（釋放時讀紀錄，期間又拿了新佔用） | `RA-5 / RB-1`、`r2 X12 / X9` |
| G16 | `acquire` 不呼叫 `core.acquireLease` | `§4.4: acquiring a lease cancels the round…`、`RA-5 / RB-1` |
| G17 | `BleGate.revoked` 什麼都不做 | `ble_gate_test` 2 個 |
| G18 | `rawIdle` 在頁面已卸載時不放佔用 | 5 個（claim / nodes / scan 的真頁面測試，以及 review_pr1 兩個） |
| G6 | nodes.dart：拿掉這輪新加的 `_wait?.cancel()` | `r3 E-M1: 我的節點…`，但原因是 `A Timer is still pending`（fake_async），不是行為斷言。見下方「這輪修正有沒有弄壞東西」 |

## 發現

### MAJOR

**G-M1：E-M1 / F-M1 還是沒有完全關。啟動頁交給「我的節點」「附近的節點」的佔用、首頁清單、兩處掃描計數，改壞之後全套照樣通過；PR 說明宣稱這些都有測試**

- 情境：
  - 使用者每天用的「我的節點」，佔用是由啟動頁的 `_open('我的節點', (a, u) => NodesPage(ble: a?.ble, use: u))` 交給頁面的（main.dart）。這一行退回 `use: null`，A-M1 整個回來：登入中按返回，自動讀取和登入同時用藍牙，節點在另一條連線上不廣播，NodeLink 顯示「連不到」。
  - 現在的程式是對的，問題是沒有任何測試守著。
- 證據：
  - 上表 G2、G3、G4、G5、G22，輸出都是 `+418: All tests passed!`（`pr1G-tools/out/G2_main_nodes_nouse.txt` 等）。
  - 新加的 `key_abilities_test.dart:306` 只點「認領節點」（G23、G28 會 FAIL）。
  - `nodes_update_send_test` 和 `scan_page_test` 自己呼叫 `openRawPage(..., (u) => NodesPage(use: u))`，所以測不到 main.dart 那一行。
  - 第三輪 E 的表把 E6（就是 G2）、E3（G5）、E14（G22）列為沒被抓到；修法第 4 點要求「三個按鈕打開的頁面都拿到 `RawUse`；`NodeStatusList` 有出現」。
  - PR 說明寫「第三輪審查修正的改壞對照（14 條：三個舊頁面與啟動頁的佔用接線 …）✅ 14 / 14 都有測試 FAIL」。這句話比實際涵蓋的範圍大。
- 為什麼是 MAJOR：被宣稱修好的 MAJOR（A-M1 的「我的節點」部分）在修正被拿掉時沒有測試會 FAIL。依使用者的規則，每個宣稱的修正都要有負向對照。
- 修法（都很小）：
  1. `key_abilities_test.dart:306` 的測試改成依序點三個按鈕（「我的節點」「認領節點」「附近的節點」）。每個都斷言 `t.widget<X>(find.byType(X)).use?.lease` 和 `a.reg.current` 是同一個，並且 pop 之後 `a.reg.current == null`。「我的節點」需要 `listNodes` 的 mock，這個檔案裡「我的節點」的登入測試已經有了。
  2. 同一個測試加一行：`expect(find.byType(NodeStatusList), findsOneWidget)`（需要至少一筆紀錄，或者斷言 `_app` 已經建立、清單已經放進 widget tree）。
  3. `nodes_update_send_test` 的 r3 測試加一行：`expect(gate.recentScanStarts, 1)`。
  4. `claim_flow_test` 的恢復路徑也比照，斷言 `gate.recentScanStarts`。
  5. PR 說明的那一列改成實際的涵蓋範圍；附上 G2、G3、G4、G5、G22 的負向對照。

### MINOR

**G-m1：`start` 在讀紀錄**之前**就取了生命週期狀態，讀紀錄**之後**才套用。讀紀錄期間回到前景的話，那次回前景會被吃掉，自動讀取停到下一次離開再回來；main.dart 的 `life:` 那一行也沒有測試**

- 情境：
  1. 使用者打開 app，啟動檢查期間按 HOME（第三輪 E-m1 的情境）。
  2. 啟動檢查結束：main.dart 用 `life: WidgetsBinding.instance.lifecycleState` 取到 `paused`，呼叫 `start`。
  3. `start` 先 `await readRecords()`（node_link.dart:103）。這段時間使用者剛好回到 app：觀察者呼叫 `foreground()` → `core.foreground`。這時 `fg` 還是預設的 true，所以 `if (fg) return`（core.dart:209），什麼都沒做。
  4. 讀完之後，`start` 依照已經過時的 `life` 呼叫 `core.background`（node_link.dart:105-107）→ `fg = false`。
  5. 結果：app 在前景，但 NodeLink 認為在背景。首頁清單一直顯示「正在找節點…」，要等使用者再離開、回來一次才會讀。
- 窗口：只有 `readRecords` 的時間（`listNodes` 加上每個檔案的 stat，大約幾 ms）。機率很低，但一旦碰到，在使用者眼中就是「自動讀取壞了」。
- 證據（✅ 實跑）：`scratchpad/core/pr1G-tools/mytests/g_start_race_test.dart` 的 `G-1`。做法是用 `start(life: paused)`，讓 `readRecords` 卡住，期間送 `lifecycle(resumed)`，再讓它結束。
  - 26057eb：`Expected: true  Actual: <false>  the app is in the foreground`。
  - 套上修法（把 `life` 的判斷移到 `await readRecords()` **之前**）：`test/nodelink` 加上 `G-1`，`+201: All tests passed`。原有的 `r3 E-m1` 仍然通過。這就是修法的負向對照。
  - main.dart 的 `life:` 那一行拿掉（G1），全套照樣 418 PASS。
- 修法：
  1. node_link.dart:102-110 改成先套用 `life`，再 `await readRecords()`。這樣讀紀錄期間觀察者送來的 `resumed` 會正常把 `fg` 設回 true；`core.startup` 之後由 `_begin` 決定要不要開一輪。
  2. 把 `G-1` 收進 `review_pr1_test.dart`。
  3. 在 `key_abilities_test` 裡用 `t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused)` 之後再 pump `BatmanApp`，斷言 `AppLink.instance!.link.core.fg == false`，守住 main.dart 那一行（G1）。

**G-m2：AppLink 的測試沒有用 `addTearDown` 清理。一個測試失敗時，它留下的 NodeLink 會讓下一個測試也 FAIL，一個錯誤報成兩個**

- 證據：G23（只改壞 `ClaimPage` 的佔用）讓 `r3 E-M1: 認領節點…` FAIL。但 `r3: login not allowed at startup…` 也一起 FAIL，原因是 `A Timer is still pending`。那個計時器是前一個測試沒有 dispose 的 NodeLink 留下的：`NodeLink.released.<anonymous closure> (node_link.dart:188)` → `_pump` → `AppLink._after`（`out/G23_main_claim_nouse.txt`）。
  - `key_abilities_test.dart:322-324`、`app_link_test.dart` 都把 `a.link.dispose` 和 `forgetForTest()` 寫在測試最後，斷言一失敗就不會執行。
  - `app_link_test` 的兩個測試完全不 dispose NodeLink。`_Life` 觀察者也從來沒有從 binding 移除。
- 為什麼要修：依使用者的規則，每個 FAIL 都要歸因。連帶出現的第二個 FAIL 會誤導歸因。
- 修法：建立之後立刻 `addTearDown(() async { await t.runAsync(a.link.dispose); AppLink.forgetForTest(); })`。可以考慮讓 `forgetForTest` 也移除 `_Life` 觀察者。

**G-m3：「我的節點」登入時，連上之後的步驟（`requestMtu`、`readCharacteristic`、`frameLimit`、`run(first)`）如果丟例外，`conn` 永遠不會被取消。佔用照樣釋放，但連線留著，節點不廣播，NodeLink 一直顯示「連不到」**

- 情境：
  - `_tryLogin` 只在兩條路徑上取消 `conn`：連線逾時（nodes.dart:202-203），以及 `ok == false`（:347-350）。
  - :205 之後任何一個 `await` 丟例外，例如 GATT 錯誤或平台例外，都會直接傳到 `_login` 的 `catch`，只顯示「連線中斷」，然後 `finally rawIdle()` → 佔用釋放。
  - 這時 `conn` 是區域變數，還沒有指派給 `_conn`（:354），所以 `_drop()` 也取消不到它。
  - 結果：手機和節點的連線一直開著，節點不廣播。6 s 後 NodeLink 開始讀，把這台判成「連不到」，直到節點自己的閒置逾時或 app 重開。
- 歸類：這是原本就有的寫法（不是這個 PR 加的），但 PR 1 讓「舊頁面釋放佔用時，自己開的連線已經關掉」變成 NodeLink 的前提（§4.4「釋放：先等斷線完成」）。gate 的 `released` 只收得到走 gate 的連線（ble_gate.dart:242-247）。
- 證據：程式碼推論（nodes.dart:190-207、:340-357），⚠️ 沒有實跑。
- 修法：
  - 在 `_tryLogin` 用 try/catch 包住 :205-:345，例外時 `await notify?.cancel(); await conn.cancel(); rethrow;`。
  - 或者寫進 #329 殘項，和 F-m6 放在一起（PR 3 換頁時解決）。

## 這輪修正有沒有弄壞東西

- **`NodeLink.start(life:)`**：邏輯本身正確（G10 被抓到）。這次修正帶進了 G-m1 的競態。
  - 啟動失敗的情況（`start` 丟例外）：`_app` 還是 null，NodeLink 的 `core.started == false`。生命週期事件和狀態流只會改旗標，不會開始一輪（core.dart:161 `_eligible` 要求 `started`）。✅ 無害。
- **AppLink 可以注入 radio**：
  - 正式版的 main.dart 沒有傳 `ble`，所以走 `FlutterReactiveBle()`。這個建構子本來就是 factory，回傳 `_sharedInstance`（flutter_reactive_ble-5.6.0 `reactive_ble.dart:18-20`）。舊頁面在 `a?.ble == null` 時自己建的那一個也是同一個實例。「全 app 一個 radio」✅ 沒有被改變。
  - `create` 在 `_one` 已經存在時會忽略傳進來的 `ble`，正式版只呼叫一次。
  - `forgetForTest` 有 `@visibleForTesting`，正式程式沒有呼叫它。
- **nodes.dart 的 `_wait?.cancel()`**：
  - `_login` 開始時要求 `!_busy`，而且會先 `_drop()`。所以這時的 `_wait` 只可能是登入自己的寫入 `_kick()` 出來的（nodes.dart:226）。
  - 那個計時器到期時只會完成 `_answer`，而登入期間 `_answer == null`（:488-493）。
  - 所以取消它不會影響任何其他請求；拿掉它在正式版也沒有任何後果。G6 只是讓 fake_async 回報有計時器沒結束。✅ 無害；這只是測試衛生，不是行為規則。
- **scan.dart 把忙碌改在第一個 await 之前設定，結尾放進 finally**：
  - 頁面還在的時候佔用一定有效（只有 `pageGone` 之後才會被收回），所以 `rawBusy = true` 不會丟例外。
  - 結果文字 `_status[d.id] = r` 不再自己 setState，靠 finally 裡 `rawIdle()` 的 setState 顯示。✅ 一致。

## 先前發現的關閉狀態

| 發現 | 狀態 | 依據 |
|---|---|---|
| E-M1 / F-M1 接線 | ⚠️ 大部分關了（G7、G8、G9、G11、G12、G19–G21、G23–G28、G30 都會 FAIL）；E6、E3、E14、啟動頁的另外兩個按鈕、首頁清單還沒有關 | → G-M1 |
| E-m1 背景啟動 | ⚠️ NodeLink 有測試（G10）；main.dart 那一行沒有（G1）；修法帶進新的競態 | → G-m1 |
| E-m2、E-m3、E-m4、E-m5 | 已寫進 #329 殘項（:107、:110-112） | 可以接受 |
| E-m6 ScanPage | ✅ G8、G9 會 FAIL | |
| F-M2 A13 | 已列為合併條件（殘項 :117）；在等使用者決定 | 不算發現 |
| F-m1 | ✅ G29 會 FAIL | |
| F-m2 | ✅ G12、G30 會 FAIL | |
| F-m3 | ✅ Rust 改壞會 FAIL（見基準）。`AuthRefused(Ok) → (4, 0)` 仍然沒有斷言，影響可以忽略 | |
| F-m4、F-m5、F-m6、F-m7 | 已寫進殘項（:105、:113-115） | 可以接受 |

## #329 實作殘項：能不能接受

每一條都可以接受。理由同第三輪 E 和 F，我重新查過以下幾點：
- 420 s 以內的工作上限仍然成立：
  - 認領最多約 300 s；
  - 「我的節點」的登入是 60 s 掃描，加上每台 20 s，再加上 20 s；
  - `_joinWait` 由 `_kick` 重新計時，但 `_ask` 有自己的收尾。
- 建議補一條：G-m3（登入的例外會讓連線留著）。如果這輪不修，放進 F-m6 那一條一起寫。

## PR 說明的偏離：安不安全

- **舊頁面在原始佔用下保留自己的 BLE 程式**：安全。理由：
  - 頁面還在時，佔用一直有效；
  - 忙碌時按返回，佔用撐到工作結束（G18 守著）；
  - NodeLink 在佔用期間拿不到 token（lease.dart:357，gate 會拒絕）。
  - 缺口只有兩個：420 s 收回之後（已宣告），以及 G-m3。
- **不加 PopScope**：安全。佔用已經撐到工作結束，PopScope 只會讓返回鍵沒有反應。
- **A 組量測併入 B 組**：這是使用者的決定。A13 已列為合併條件。
- 說明裡「14 / 14 都有測試 FAIL」的那一列，涵蓋範圍寫得比實際大（G-M1）。

## 生命週期（端到端）

| 路徑 | 行為 | 證據 |
|---|---|---|
| 第一次安裝 / 啟動 | 啟動檢查通過後才建 NodeLink；金鑰前提來自啟動檢查（G19 守著）；`start` 失敗時畫面留著結果，NodeLink 不開始 | main.dart `_run` |
| 啟動檢查期間離開 | 不讀（G10）；讀紀錄的那幾 ms 內回來 → 卡在背景 | G-m1，G-1 實跑 |
| 背景 / 前景 / inactive | paused / hidden / detached → 取消一輪、標成不新鮮；inactive 不變 | node_link.dart:129-138；G11 |
| 藍牙關閉 | 狀態流 → 取消一輪、`_abort` 斷線、掃描停下、顯示 2.3 | G20；core.dart:271-283 |
| 權限收回 | Android 結束行程 → 重新啟動時是 `unauthorized` | ⚠️ 殘項，B 組 |
| 拿佔用時，一次嘗試正在連線 | `_abort` 之後等斷線最多 5 s，才拿到佔用 | G14 |
| 拿佔用時，NodeLink 的掃描正在等名額 | 那個掃描留在 `gate._scans` 裡，直到它的計時器到期，然後因為 token 已經失效被拒絕（ble_gate.dart:186-194；`reg.acquire` 不通知 listener，lease.dart:361-366）。PR 1 裡只有 NodeLink 用 gate，使用者碰不到；PR 3 的新頁面走 gate 時，最多 30 s 會被拒絕（「a scan is already running」） | 觀察，不算發現 |
| 釋放之後讀紀錄，期間又拿了新佔用 | 核心維持佔用狀態；寫過的 id 等到下一次釋放才套用 | G15 |
| 佔用頁在忙的時候被關掉 | 撐到工作結束，最多 420 s | G18、G24、G8 |
| 閒著的頁面被關掉 | dispose 時立刻交回；連線斷掉靠 `afterLease` 的 6 s | 殘項 F-m6 |
| App 被殺掉 | 佔用只存在記憶體裡，重開之後不存在 | lease.dart |

## 安全（逐個角色）

這輪的修改沒有改變信任邊界。第三輪 E 和 F 的分析仍然成立，我重新核對了這幾點：

- **附近的惡意 BLE 裝置**：
  - `Res.body` 只會在 `OwnerKind.answer` 出現。要走到這一步，必須先有 Rust 的 LoggedIn，也就是 msg2 用紀錄裡的金鑰解得開，而且 DAC 對得上 pinned 的那一個。
  - 片段沒有完整的 msg2：8 s 結束（D-2）。
  - msg2 之後最多 20 s（prober.dart:143-146）。
  - 讀取中遇到任何會寫紀錄的步驟，都會放棄那台節點（prober.dart:105-109）。
- **其他 app**：沒有新的輸入面；logcat 的內容有遮罩，而且 G12 / G30 現在守著。
- **被入侵的節點**：只能報它自己的狀態，最多拖 20 s；讀取從不送 op/nonce，所以拿不到 owner 簽章。
- **我們自己的錯**：G-M1（接線測試）、G-m3（舊頁面留下的連線）。

## 我寫的東西（都在 scratchpad，沒有 commit）

- `scratchpad/core/pr1G-tools/mut.sh`：一次改一處 → 跑測試 → 還原。
- `scratchpad/core/pr1G-tools/out/G*.txt`：每一項的完整輸出。
- `scratchpad/core/pr1G-tools/mytests/g_start_race_test.dart`：G-m1 的重現。26057eb 上 FAIL；套上修法後 PASS。
