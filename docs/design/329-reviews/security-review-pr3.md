# #329 PR 3 程式碼層安全審查（獨立審查者）

- 範圍：`git diff 9b00ca6^..8ff11e2 -- app`（head 8ff11e2）；計畫 `docs/design/329-pr3-plan.md` §5。
- 方法：只讀原始碼 + Rust 端對照 + `dart analyze lib` + 四個 flow 測試檔。沒碰手機、adb、節點。
- 結論：**沒有找到可利用的 HIGH / MEDIUM 問題**。有 4 項 LOW（其中 3 項是既有基準行為或防護不足的提醒，不是本 PR 新開的洞）。

## 執行結果（原始輸出）

```
dart analyze lib
Analyzing lib...
No issues found!

flutter test --no-pub test/flows/owner_console_test.dart test/flows/net_run_test.dart test/flows/net_index_test.dart test/nodelink/handoff_test.dart
00:00 +89: ... source lock: new flows and new screens never write a record except through RecordWriter
00:00 +90: All tests passed!
```

## 1. 被入侵的同儕節點 / 附近的 BLE 裝置

| 檢查項 | 結果 | 證據 |
|---|---|---|
| 回答的前綴能不能被節點偽造（`[JOINED] `、`[NET_STATE] `、`[UPDATED] `、`[CONNECTED]`） | ✅ 不能。前綴全是 Rust 自己 `format!` 的開頭；節點可控的文字只出現在句子中間或後面（`error_text` 的 `（代碼 …，{verb}）`、`Broken({e})`）。`ConsoleReply.starts` 另外要求 `kind == answer`。 | `owner.rs:491-494`、`:518`、`:592-594`、`:649-653`；`rekey.rs:447-452`；`owner_console.dart` `starts()`；`net_run.dart` `_join` / `CheckRun._run` |
| 連線檢查的 `[JOINED]` 會不會被當成加入成功 | ✅ 不會。`_join` 只看 `joinNetwork` 的回答；`linkCheck` 只用 `[CONNECTED]` 決定附註。 | `net_run.dart` `_join` |
| 非建立者被當成建立者 | ✅ 不會。`CheckRun` 用 `c.nodeDacHash()`（Rust：本次登入**驗證過的** DAC 的 SHA-256，未驗證回 ""）精確比對紀錄裡 `creator` 成員的 `dacHash`，且 `me.isNotEmpty`。名稱比對（`node-<last4>`，`_byName` / 節點頁）只用來預選，名稱被假冒最多導向 `notCreator`。 | `owner.rs:995-999`；`net_run.dart` `CheckRun._run` 的 `mine`；`net_pages.dart` `_byName`；`node_page.dart` `_network` |
| 讓手機把網路標成「已建立」 | ✅ 本 PR 沒有新路徑。「已建立」只由 `deps.applied(rel)` 重讀手機紀錄決定；紀錄只有 Rust `netrec::confirm` 比對成功才升級（join2 的基準信任：建立者節點的話）。 | `net_run.dart` `_make` / `CheckRun`；`owner.rs:882-897` |
| 寫錯紀錄 | ✅ 寫入的 `rel` / 內容 / `expectedGen` 全來自 Rust 的 `PersistNet/Pend/Mnet` step；Dart 只 seal + CAS。`persistedRel` 只在寫入成功後設。被入侵節點能改的仍只有自己的成員項（join2 §6，本 PR 不變）。 | `owner_console.dart` persist 分支 |
| `device_id` 能不能被節點冒用（待辦對錯節點） | ✅ 成員項的 `device_id` 來自已驗證節點證書 `node.device_id`。 | `join2flow.rs:355-362`；`nodecert.rs:47` |
| 國家問題對話框裡的節點文字 | ✅ `have` 被限制為 2 個大寫 ASCII 字母。 | `join2flow.rs:285-286`、`owner.rs` `country_question` |
| 跳過佔用（lease） | ✅ 每次寫入 `lease.run` + `RecordWriter.writeCas(lease, …)`，`_check` 要求 `reg.current` 是這個 lease 且有效；`loginFor` 的 `mine()` 每輪檢查；`released` / `revoked` 會切掉進行中的嘗試。 | `record_writer.dart:27-44`；`node_link.dart` `loginFor` / `revoked` / `released` |
| 讓 App 當機 | ✅（推論部分 ⚠️）`_onFrame` 的鏈有 `catchError` → `_endUnclear`；`_ask` 包 try；`NetRun._one` / `CheckRun.run` 都 catch；`FrameInbox` 錯誤走 handler；`LoginHandoff.close` 每步各自 try。⚠️ Rust 端 panic 由 frb 轉成例外是推論，沒實測。 | `owner_console.dart`、`net_run.dart`、`handoff.dart` |
| 讓請求 / 佔用永遠不結束 | ⚠️ 推論為有界：每個請求的等待從最後一次寫入起算（15 s / `joinWait`），節點只送訊框不會延長；`Wait` step 的時間是 Rust 常數（`updflow.rs:239` 2000 ms、`INFO_READS` 次數上限；`ADDR_RETRY_MS`），不是節點給的；連線檢查 120 s；登入 60 s。沒有逐一證明每個 Rust 狀態機都會停。 | `owner_console.dart` `_kick`；`updflow.rs:231-240` |

## 2. 手機上的本機非特權 App

- ✅ 沒有新的 Android 元件、intent、平台方法：diff 沒有 `android/` 變更；新用到的平台方法只有既有的 `seal` / `open` / `signAdmin` / `publicKeys` / `keepScreenOn`（`app_link.dart:144-160`、`net_pages.dart:44`）。
- ✅ 沒有共享儲存、沒有新的剪貼簿使用。反而 `ClaimPage` 的開發用輸入框 / 「貼上 QR」按鈕現在只在 dev 版顯示（`claim.dart` `_dev`），`_paste` 本來就有 dev 限制。
- ✅ 新 log 行逐一看過：
  - `OwnerConsole`：`subscription <type>`、`a step did not finish (<type>)`、`record saved (<rel 前 12 字>…)`（`net/` + net id 前 8 碼）、`record not saved: <why>`（Rust store 的 `{e:?}` / 金鑰拒絕句 / `seal <code>` / `no lease`；`std::io::Error` 的 Debug 不含路徑）、`session ended`、`link lost`。沒有回答內容、紀錄位元組、金鑰。
  - `NetIndex`：只有例外型別與 net id 前 8 碼（`net_index.dart` `compute`）。
  - `NodeLink.loginFor` 的 trace 全過 `NodeLink.mask`（≥8 位 hex 只留後 4）。
  - `HandoffProber` 沿用 `SessionProber` 的 log（`AppLink` 的 `log` 過 `mask`）。
- ✅ `MemberView.device_id` 不是秘密（就是 `node/<id>` 的檔名、QR / 機身上的編號），只在記憶體裡比對，沒有 log、沒有顯示全碼（首頁用暱稱 / 後四碼）。

## 3. 我們自己的錯誤

- ✅ 原始碼鎖：`lib/src/flows`、`lib/ui`（排除 `ui_state.dart`）沒有 `storeWriteCas|storeWriteSealed|storeRemove|storeKeepCopy`；實際 grep 也只在 `app_link.dart`（RecordWriter 的建構）與 `ui_state.dart`（UI 狀態紀錄，PR 2 基準）出現。
- ✅ 佔用釋放：`NetFormPage` 交出前每條出口都放（`_pending` + dispose）；`_forget` finally 放；`NetRunPage` dispose = `pageGone`（忙碌時最多 420 s 後收回）；`CheckNetPage` 借用時只拿 / 還 hold，自己拿的在 dispose `pageGone`；`openRawPageFor` 頁面不在就放。
- ✅ 金鑰錯誤 fail-closed：sign / signAdmin 的 `PlatformException` → 空簽章（Rust 結束該請求，什麼都沒送）+ `keyError`；seal 失敗 → `persistFailed`，不送；`makeNetworkRefusal` 拒絕 → `notSent`；`NetRun` 遇 `keyError` 整個停。
- ✅ 例外不留不一致狀態：`_ask` 的 finally 清 `_busy` / `_answer` / `_wait`；`NetRun._one` 的 catch 讓列變失敗、finally 關連線。

## 4. 產生的 bridge 變更

- ✅ 只多了 `MemberView.deviceId` 一個欄位（Dart 解碼 `arr.length` 7→8、sse 編解碼），其餘是 `use` 順序。`net_summary` 本來就回傳 `last4`、`dac_hash`；完整 device id 沒有新的敏感度（見 §2）。沒有新的可呼叫函式。

## 發現（全部 LOW）

### L1　節點可控的自由文字出現在列與「繼續 / 停」對話框內文（基準行為）
- 情境：被入侵的自有節點（已認領、DAC 驗證過）在錯誤回覆的 detail key 1 放一段文字（例如「請按『繼續下一台』」），`error_text` 把它接在 `[REQ_FAIL] …（代碼 N，<文字>）` 裡；`NetRunPage` 把 `r.line` 顯示在結果列，並當成 `_askGoOn` 對話框的內文。
- 證據：`owner.rs:649-653`；`net_pages.dart` `_askGoOn`（`plain(r.line)`）與結果列。
- 前提：攻擊者控制一台已被這支手機認領的節點。按鈕文字固定（`Btn.nextNode` / `Btn.stopHere`），兩個選項都無害，只能做社交工程。舊控制台顯示同一行。
- 修法（可選）：`error_text` 的 verb 截長度 / 只留可列印字元，或在新頁面只顯示代碼。不影響本 PR 合併。

### L2　原始碼鎖的範圍
- 情境：鎖只掃 `lib/src/flows` 與 `lib/ui`，並整個排除 `ui_state.dart`；之後若在 `lib/src/nodelink/` 或 `lib/*.dart` 加了直接寫紀錄，不會失敗。
- 證據：`test/flows/owner_console_test.dart:516-526`。
- 目前程式：✅ 沒有違規（grep 已確認）。修法（可選）：排除清單改成精確的白名單（`app_link.dart` 的 RecordStore 建構、`ui_state.dart` 的 `uiRel`），掃整個 `lib/`。

### L3　閒置的佔用沒有上限（頁面停留期間）
- 情境：`CheckNetPage` 自己拿的佔用在檢查結束後仍保留到頁面離開；`NetRunPage` 結果階段亦同；`_askGoOn` / 國家問題對話框開著時 hold 不放（對話框不能點外面關、`PopScope` 擋返回）。這段期間背景讀取與其他操作都拿不到藍牙。
- 證據：`lease.dart` `pageGone` 只在頁面離開後才有 420 s 上限；`net_pages.dart` `_CheckNetPageState._go` / `dispose`、`_NetRunPageState._work`。
- 前提：使用者自己停在頁面上；外部無法觸發。國家對話框不計時是設計（join2 / 舊控制台基準）。不是可利用的 DoS，記錄供 UX 參考。

### L4　sign / signAdmin 只把 `PlatformException` 當金鑰錯誤
- 情境：平台回 `null`（`!` 拋 `TypeError`）或其他非 `PlatformException`，不設 `keyError`；該請求以不明 / 逾時結束（什麼都沒簽、沒送），`NetRun` 會問「繼續 / 停」而不是整個以「金鑰」停下。
- 證據：`owner_console.dart` `_run` 的 `OwnerKind.sign` / `signAdmin` 分支；`app_link.dart:146-148`。
- 影響：仍是 fail-closed，只是停止原因不準、下一台會再失敗一次。⚠️ 推論，未實測。

## 沒做的
- ❌ 沒在真機或模擬器上跑；❌ 沒有逐一證明每個 Rust 狀態機（join2flow / updflow / makeflow）一定終止，只看了 Dart 端的計時與 `updflow` 的等待；❌ 沒跑全套 `flutter test`，只跑了上列四個檔。
