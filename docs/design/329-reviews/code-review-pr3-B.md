# #329 PR 3 程式審查 — CR-B（現場與安全）

範圍：`git diff 9b00ca6^..a01379b -- app`（head a01379b）。對照：凍結計畫 `docs/design/329-pr3-plan.md` v18、上層設計 `329-app-uiux.md`。基準（join2、舊控制台、Rust）不重審，疑問放「基準備註」。只讀；沒有改產品檔，沒有碰手機或節點。

## 全套與 analyzer（本機 Windows，C:\src\flutter）

✅ `flutter test --no-pub`（整套）最後幾行：
```
00:26 +827: C:/src/Batman-329pr3/app/test/ui/layout_test.dart: T-C2 permissions 412x915 ×2.0 dark
00:26 +828: All tests passed!
```
✅ `dart analyze lib test`：
```
   info - test\member_ui_test.dart:4:8 - The import of 'dart:typed_data' is unnecessary ... - unnecessary_import
1 issue found.
```
（`test/member_ui_test.dart` 不在本 PR 的 diff 裡，是之前就有的 info。）

## 判定：APPROVE-WITH-CHANGES（4 MAJOR、0 BLOCKER）

4 個 MAJOR 都不會寫錯紀錄、也不會漏掉佔用（dacHash 檢查、`RecordWriter` 與佔用規則都守得住）。但它們是使用者在現場會碰到的錯誤行為，或是計畫寫明、程式卻沒做到的保護。每一個都很好修。

---

## MAJOR

### M1 3.6 的「再加一台」沒有作用（回到首頁，不會開始新增）
- 情境 (l)：新增 04 → 3.2 取名 → 按「儲存」→ 3.6 →「再加一台」→ 回到首頁，**不會**再開認領頁。
- 證據：`add_pages.dart` `_save` 用 `pushReplacement(AddedPage)`，再用 `if (r != null && mounted) Navigator.of(context).pop(r)` 把 AddedPage 的值轉回首頁。但 Flutter 的 `pushReplacement` 被換掉時，舊 route 會立刻用 `result`（null）結束（`C:\src\flutter\packages\flutter\lib\src\widgets\navigator.dart:5258-5260`：`_history.lastWhere(...).complete(result, isReplaced: true, ...)`）。所以首頁 `home_page.dart` `_addNode` 的 `await push<String>(NickPage)` 在 AddedPage 一出現時就拿到 null，`r == addAgain` 永遠不成立。之後 AddedPage pop `'again'` 時 NickPage 已經 dispose（`mounted == false`），值被丟掉。
- 測試：`add_pages_test.dart:70` 只看按鈕在不在，沒有一條測試按下「再加一台」後去看認領頁有沒有開。
- 修法：NickPage 用 `push` 等 AddedPage 的結果再 `pop(r)`，或讓首頁直接開 AddedPage。加一條真 `Navigator` 的測試（首頁 → ClaimDone → 取名 → 再加一台 → 認領頁出現）；改壞對照用現在的 `pushReplacement`，應該 FAIL。

### M2 從節點頁進檢查網路頁、按「建立網路」不會進建立模式
- 情境 (c)/(d)：節點頁「檢查網路」→ Rust 說還沒套用（每筆都有回答、沒升級、手機沒有已建立的 net）→ 頁面給「建立網路」→ 按下去只回到節點頁，什麼都沒開始。
- 證據：`net_pages.dart` CheckNetPage 的「建立網路」一律 `Navigator.of(context).pop(goMake)`。節點頁 `node_page.dart` `_network` 用 `Navigator.of(context).push(... CheckNetPage ...)`，沒有 await，也沒處理回傳值。計畫 §2.8 寫的是「從節點頁進來：`close()` → `pushReplacement(4.1 建立模式)`」。`wiring_test.dart:124` 只測到頁面有開。
- 修法：照計畫，CheckNetPage 知道自己是從節點頁開的時候，用 `pushReplacement(NetFormPage(makes: true, ...))`；或節點頁 await `goMake` 後開 4.1 建立模式。加改壞對照：現在的寫法 → 4.1 沒出現 → FAIL。

### M3 從 4.1 進檢查網路頁時，預選的是「唯一勾選的節點」，不是用名稱比對建立者
- 情境 (c) 已套用的那一種 + 已新增 02：04 建立途中拔電，04 其實已套用（重開後讀到 `node_state` ≠ 1，不會預勾），紀錄停在 pending；02 剛新增（`node_state == 1`，會預勾）。首頁第 6 列 → 4.1 → 選到 pending →「檢查網路」→ 頁面寫「檢查的是節點 02」→ 登入 02 →「這台不是這些網路的建立者」→「換一台檢查」→ 手選 04 → `_picked = true` → 就算 Rust 回答了，也永遠不給「建立網路」（`net_run.dart` `offerMake` 有 `!picked`）。
- 證據：`net_pages.dart` `_NetFormPageState._check`：`preselect: _ticked.length == 1 ? _ticked.first : null`，而 CheckNetPage 的 `initState` 是 `_id = widget.preselect ?? _byName()`，有 preselect 時名稱比對根本不會跑。計畫 v18 對應表 AH m6：「從 4.1 進檢查網路頁照 §2.8 名稱預選」。4.1 在 pending 畫面不顯示勾選清單（`if (!pending)`），使用者也看不到是哪一台被勾。
- 影響：資料不會錯（`nodeDacHash` 擋住、不送確認）。但主要路徑會先檢查錯的節點，還多花一次登入；手選之後又少了「建立網路」這個出口。
- 修法：4.1 進來時不傳 preselect（或改傳 `_byName()` 的結果）。加測試：只勾 02、建立者是 04 → 預選 04；改壞 = 現在的寫法 → FAIL。

### M4 國家（或「被排除過」）對話框開著時連線斷了，會疊上第二個對話框；計畫 §2.9 說「不疊兩個」
- 情境 (c)/(f) 的變形：加入時 Rust 問國家 → 對話框開著 → 節點斷電或走出範圍 → `_lost` → `_endUnclear` 讓請求以 unclear 結束（`owner_console.dart` `_lost`、`_endUnclear`），`_ask` 最多等 10 s 的 `_chain`（卡在 `await askCountry`）就回 → `NetRun._join` → `_failed` → `askGoOn` 在**國家對話框上面**再開一個「繼續 / 停」。按完上面那個之後，舊的國家對話框還留在畫面上，下一台跑的時候它還在；使用者可能以為它在問下一台。
- 證據：`net_pages.dart` `_NetRunPageState._ask` 只在 `core.blocked != null || !lease.valid` 時收起對話框，連線斷了不收。計畫 §2.9（AE-m5 / AF m7）：「國家對話框開著時連線斷了 → 國家對話框收起、當成『不要』，之後才問一次『繼續 / 停』，不疊兩個」。`net_pages_test.dart` / `net_run_test.dart` 沒有這種情境的測試。
- 影響：不會寫錯。那個舊對話框按「改」時，`countryConfirmed` 被 `_closed` / `identical(_session, s)` 擋下（`owner_console.dart:253-254`），不會送出去。但畫面上同時有兩個問題，而且留著一個沒有作用的問題，這正是計畫要擋的情況。
- 修法：OwnerConsole 在 `_lost` / `close()` 時通知頁面收起它開的對話框（例如 `askCountry` 接一個 cancel future，或頁面在問國家時也聽這台的 `link.state`）。加測試：國家對話框開著 → 連線斷 → 對話框收起、只剩一個「繼續 / 停」；改壞對照 = 現況 → FAIL。

---

## MINOR

1. **「繼續 / 停」問的時候，失敗那一台的 BLE 連線與 session 還開著。** `NetRun._one` 在 `try { _make/_join } finally { c.close() }` 裡；`_failed → askGoOn` 在 `_join` 裡面就被呼叫，所以使用者看對話框的整段時間（可能好幾分鐘），連線都沒關。建議在 `_failed` 問之前先 `await c.close()`（或把問的動作移到 `_one` 的 finally 之後）。
2. **OwnerConsole 請求前段的例外沒有接住，那一列會一直卡在「進行中」。** `makeNetwork` / `joinNetwork` / `sendUpdateFor` 裡的 `platform.publicKeys()`（Kotlin 失敗會回 `keystore` 錯誤，MainActivity.kt:125-127）、`makeNetworkRefusal()`，以及 `readRecord` 裡的 `storeReadSealed`（Rust 錯誤）丟出來的例外，會一路穿過 `NetRun._one` / `run()`（只有 try/finally）。結果：那一列停在 `RowState.running`、`stopped == none`，表頭寫「有節點沒有完成」卻沒有原因，也沒有「再試」；這個 Future 的錯誤沒有人接。佔用不會漏（`_work` 的 `whenComplete` 會放 hold）。舊控制台在這裡也沒接，但新頁面的後果不同。建議 `_one` 接例外 → 那一列算失敗、附句子；`PlatformException` 當成 `keyError`。
3. **檢查網路頁消失之後，`CheckRun` 還會接著登入、確認。** `CheckRun` 沒有 `pageGone`；頁面在 `deps.login` 途中被關掉，登入完成後照樣逐筆 `confirmNetwork`。計畫 §3.2 T-R1(c) 寫「同『工作途中頁面消失』」（不開新的登入或下一筆）。確認只會讓紀錄升級，沒有害處，但和計畫不一致。
4. **4.1 的快照 `_seen` 只在第一次 build 與比對失敗時更新**（`_seen ??= s`）。從檢查網路頁回來、紀錄升級之後（佔用釋放 → `NetIndex` 重算），第一次按「開始」一定被擋，顯示「紀錄剛剛變了」，要再按一次。計畫 AD m6 / AH m4 寫「4.1 等 `NetIndex` 通知後更新快照」。建議在 `_changed` 裡、沒有 `_pending` 時更新 `_seen`。
5. **`picked`（手選節點）一律不給「建立網路」**（`net_run.dart` `offerMake`）不在 §2.8 的結果表裡。計畫只寫了「v9 R m」。它和 M3 疊在一起時，主要路徑會失去這個出口；退路是回 4.1 用次要「建立網路」（全部 pending 時）。請在計畫 §2.8 補一行，或拿掉這條。
6. **join 模式的預勾用的是「最近一次讀到的」`node_state == 1`。** 剛建好網路的 04 如果還沒被重新讀過（佔用期間不自動讀），下一次開 4.1 加入時會被預勾，送一個加入到它自己建的網路；Rust 會回答，不會寫錯，但會多一次登入。可以把「是任一筆 net 的成員」的節點排除在預勾之外。
7. **結果頁從檢查網路頁回來時的重讀**用的是區域變數 `h`，不是 `_hold`。這段期間 `working == false`，別列的「再試這一台」可以按（時間很短）。
8. **`OwnerConsole` 建構時對 `h.link.state` 的訂閱在 `close()` 時沒有取消**（`_closed` 會讓它什麼都不做；只是會留著到 link 的 stream 結束）。
9. **4.1 做完「放棄這次加入」之後**，按鈕還在（`widget.todo` 不變）；再按一次只會得到 Rust 的錯誤句。

---

## 情境逐條（照程式走，不照計畫）

| # | 情境 | 使用者看到 / 寫入了什麼 | 判定 |
|---|---|---|---|
| a | 0→網路：04 建立、再加 02 | 第 6 列 / 3.5「建立網路」→ 4.1 建立模式，04 預勾 →「開始」：4.1 `acquire` + 比對快照 → push NetRunPage（hold、keepScreenOn）→ `loginFor` → `makeNetwork`（PersistNet 經 `RecordWriter`，`persistedRel` 寫入成功後才設）→ 重讀那一筆、已套用 → 完成 → pageGone 釋放 → `NetIndex` 重算。02：新增 → 3.6「加入網路」→ 4.1 加入模式，單一 net → `joinNetwork` → `[JOINED] ` → `linkCheck`（10 s 一次、最多 120 s）。3.6 的「再加一台」壞了（M1） | ✅ 程式走過；⚠️ 真機沒跑 |
| b | 兩台一起勾 | 建立者 = 勾的第一台（可換）；04 成功 → `joinRel = rel` → 02 加入。04 失敗 → D12 整個停、02「還沒做」 | ✅（`net_run_test.dart:134`、`:147`） |
| c | 建立途中拔 04 電 | 斷線 → unclear；有 `persistedRel` → 重讀不是已套用 → 自動檢查：`sessionAlive == false` → `close` → 再 `loginFor` 一次（60 s）→ 找不到：那一列「沒有連到節點，無法檢查。…」，只有「檢查網路」。找得到：已套用 → 升級、繼續；沒套用 → 失敗、只有「檢查網路」→ 檢查網路頁（借用）→ 給「建立網路」→ 回 4.1 建立模式。從節點頁進來時壞掉（M2）；從 4.1 進來時預選可能錯（M3） | ✅ 程式；⚠️ 拔電時間點沒在真機重現 |
| d | 建立者壞掉、只剩 pending | 第 6 列「加入網路」→ 4.1 選到 pending →「檢查網路」+ 次要「建立網路」（`!s.anyApplied`）→ 檢查網路登入失敗只給「再檢查一次」→ 回 4.1 →「建立網路」→ 建立模式 | ✅ |
| e | 加入途中 app 被殺 → 待辦 → 放棄 | `NetIndex` 照 `forgettable`（`joining && !creator`）列待辦，device id 要對到手機的 `node/` → 4.1 帶 todo →「放棄這次加入」→ 確認框 → 自己 `acquire`（被拒時顯示名稱）→ `forgetJoining` 經 `RecordWriter` → finally `release` | ✅（`net_index_test`、`wiring_test.dart:84`）；見 MINOR 9 |
| f | 「繼續 / 停」開著時藍牙關了 | `link.changed` → `core.blocked != null` → 對話框 pop(false) → `_blockedStop` = blocked →「藍牙或權限現在不能用，已經停止。」 | ✅（`net_pages_test.dart:273`、`net_run_test.dart:270`）；⚠️ `changed` 在 blocked 變化時會發，是依 core.dart 推論的 |
| g | 系統在請求途中關掉頁面 | dispose → `run.pageGone()` + `lease.pageGone()`；hold 撐到當前請求結束 → 不送新密碼、不做連線檢查、不開下一台 → `whenComplete` 放 hold → 釋放。`_ask` 在 `_gone` 時回 false。檢查網路頁：見 MINOR 3 | ✅（`net_pages_test.dart:149`、`net_run_test.dart:280/291`） |
| h | 在檢查網路頁選錯節點 | 登入 → `creator && dacHash == nodeDacHash()` 不成立 →「這台不是這些網路的建立者」+「換一台檢查」，不送確認、不給建立 | ✅（`net_run_test.dart:373`） |
| i | 被入侵的節點 | 前綴：所有判斷都要 `kind == answer && startsWith('[X] ')`（`ConsoleReply.starts`）；Rust 的 `Err(String)` 是 `refused`，句子中間有 `[NET_STATE]` 也不算（`net_run_test.dart:408`）。`ended` 落在 persist 途中：`_chain` 是串的，persist 先做完、`persistedRel` 保留、`sessionAlive == false` → 重新登入再檢查。一直不回答：登入 8 s / 20 s；請求的計時只在**我們**寫出去時重設（`_kick`）；更新流程的 Wait 由 Rust 限次（updflow.rs `INFO_READS`）。節點沒辦法冒充建立者（dacHash 來自驗證過的 DAC）；成員的 `device_id` 也來自驗證過的節點（batman-proto/src/join2flow.rs:362） | ✅ |
| j | 加入後送新密碼失敗 → 再試這一台 | 那一列「已加入，新密碼沒有換成 / 沒有送出 / 結果不明」+ 句子，問繼續 / 停 → 結果頁「再試這一台」= 整段加入規則（`clearNotY`）→ 已是成員、版本落後時 Rust 再回帶 `sendUpdate` 的 `[JOINED] ` → 再送一次 | ✅（`net_run_test.dart:230/310/323`） |
| k | 管理金鑰在迴圈途中失效 | `signAdmin` 丟 `PlatformException` → `_keyFail`：`keyError = true` + `keyErrorToRadio` → 整個停、不問；保留 `persistedRel`。`publicKeys` 失敗時會卡住那一列（MINOR 2） | ✅ sign 這條路；⚠️ Keystore 失效時 `publicKeys` 會不會丟例外沒在真機驗 |
| l | 認領 → ClaimDone → 3.2 → 3.5/3.6；頁面已關的認領（F41） | 認領 / 恢復成功 → `pop(ClaimDone(id))` → 3.2 `setNick`（1–24 字，拒絕 Cc/Cf/Zl/Zp）→ 3.5/3.6 照 `NetIndex.records`。「再加一台」壞了（M1）。F41：頁面不在時 `_say` 改寫到 `lastClaimNote` → 首頁橫幅顯示一次 | ✅ 除了 M1；⚠️ 首頁在 note 設定後才重畫（靠釋放後的 `changed`），是推論的 |

## 安全

- ✅ **本機沒有權限的程式**：diff 沒有改 `android/`（diff stat 只有 `lib/`、`rust/bridge/`、`test/`）；沒有新的平台方法或匯出元件；紀錄目錄在 app 私有的 `filesDir/records` 下；MethodChannel 只在同一個 process 裡。新的輸入只有網路名稱（Rust 檢查）、暱稱（`setNick`）、勾的節點（只能是 `node/` 紀錄）。
- ✅ **秘密不進 log**（逐行 grep 新增的 `log?.call` / `debugPrint` / `trace?.call`）：
  - NetIndex 只寫 `${e.runtimeType}` 與 net id 前 8 碼；
  - OwnerConsole 寫 `p.rel.substring(0, 12)`（= `net/` + 8 碼）、`why`（store 錯誤 = `STALE_RECORD` 或 `Io(...)` 的 Debug，不含路徑或內容；或 `KeyAbilities.refusedBy` / `seal <code>`）、`runtimeType`；
  - `ConsoleReply.toString` 不含 `text`；
  - loginFor 的 `trace` 都經過 `NodeLink.mask`；
  - 回答內容（`r.text`）只出現在畫面上（`plain()`），不寫 log。
- ✅ **fail-closed**：寫入都經 `RecordWriter.writeCas(lease, …)`；佔用不見時 `persistFailed('no lease')`；重讀失敗 = 不是已套用 → 走檢查網路。
- ✅ **建立者判斷**用的是驗證過的 `nodeDacHash()`，名稱只拿來預選。

## 基準備註（不屬於本 PR）

- 舊控制台的 `_makeNetwork` / `_joinNetwork` 也沒有接 `publicKeys` 的例外（nodes.dart:483、:641）。
- 拔電後、建立者永遠不回來時，pending 紀錄刪不掉，節點頁的「檢查網路」會一直留著（計畫 §8 已列）。

## 證據分類

- ✅ 已驗：全套 828 PASS、analyzer 1 info（不在本 PR，原始輸出在上面）；M1（Flutter navigator.dart:5258-5260 + `add_pages.dart` / `home_page.dart` 程式碼）；M2、M3、M4 與 MINOR 1–9（逐行讀程式）；log 的 grep；diff 沒動 `android/`。
- ⚠️ 推論：`link.changed` 會不會在 blocked / 佔用變化時發出（core.dart，沒追完）；Keystore 失效時 `publicKeys` 的行為；真機上斷線事件的時間點（Android supervision timeout）；F41 首頁重畫的時機。
- ❌ 沒做：真機場次（§7）；各項保護的改壞對照沒有重跑（不准改產品檔）；M1–M4 我沒有寫會失敗的測試，只附了修法與改壞對照的建議。
