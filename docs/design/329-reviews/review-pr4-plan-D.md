# #329 PR 4 計畫 v2（1022df5）— 審查 D（第二輪）

範圍：整份 v2 計畫的新部分（§0「本 PR 新做的」、§2–§7、附錄 A）。基準（leave v4.1、update v0.4、p3-impl §3.3、PR 3 機制、329-app-uiux v12.1）只當契約，不重審。
方法：逐條對原始碼查證；從現場（S20、HaLow 節點、BLE）出發，逐步走「軟體更新跨節點重開」，對照 swupd.rs / swupdate.dart / owner.rs；以「被入侵的節點」與「我們自己的錯」兩種角度攻擊。除了本報告沒有改任何檔案；沒有跑 flutter test（這是計畫審查，還沒有新程式）；沒有碰手機。

## 1. 第一輪修正是否關閉（逐條）

| 第一輪 | 結果 | 證據 |
|---|---|---|
| A M1 = B M1 `settings/set` 的 `sent` | ✅ 關閉。`sent: verb == LEAVE` 在 owner.rs:752（簽章後的那一次寫出）。改成也認 `settings/set` 之後，`stepFrames` → `SendTrack.wrote`（member_ui.dart:296-310），`_unclearReply`（owner_console.dart:302-305）就會回 unclear 句。舊控制台不受影響：`_unclearNow` 只在帶 unclear 時讀（nodes.dart:436），重送分支也不看 `wrote`（nodes.dart:546-556）。沒有開新洞。 | 同左 |
| A M2 = B M2 重新登入條件 | ✅ 關閉。`OwnerConsole.alive` = `_session != null && !_closed`（owner_console.dart:167）；沒有請求在等時，`_lost` 也會把 `_session` 設成 null（:315-321，由 link.state 觸發，:122-124）。和 net_run.dart:262 同一條件。 | 同左 |
| A M3 `NickPage` → `AddedPage` | ✅ 關閉（rename 模式 + T-N4 負對照）。 | add_pages.dart:41-57 |
| A M4 頁面不在了才送出 | ✅ 關閉（`loginFor` 回來後、每個請求之前都檢查 `_gone`；T-P5 負對照）。 | 計畫 §2.0 |
| B m1 askSw 的 unclear 記號 | ✅ 關閉。有記號時，`_lost → _endUnclear` 會立刻結束請求（owner_console.dart:307-312）。sw 的寫出 `sent` 一律是 false（owner.rs:1590-1592），所以結果是 notSent，對應到 `sw.lost`，正確。 | 同左 |
| B m2 回答用回答的 session | ✅ 方向對；但「在 `_run` 裡算 `swAnswer`」帶出時鐘問題，見 **MAJOR-1**。 | |

## 2. 軟體更新跨節點重開，逐步走（OpSession.open）

1. 打開更新頁 → `open` 拿佔用（kind 是 session，`loginFor` 只接受這種，node_link.dart:227）→ `start()` 送 status → `run`：console 是 null → `loginFor`（≤ 60 s）→ `askSw` → `_run` 的 `answer when st.sw` 臂 → `swAnswer`。✅
2. 選檔 / Check / bulk/open（owner-op：op/nonce → sign → 請求，owner.rs:1585-1600、`sw_signed`）→ Kotlin PUT。上傳期間 keepalive 每 10 s 一個 `ask`（swupdate.dart:181-189），不會和主迴圈重疊（`_upload` 先 `await keeping`），所以不會撞到 `OwnerConsole._busy` 的 StateError。✅
3. 「寫入中」每 5 s 讀一次；斷線 5 分鐘內繼續讀（swupd.rs:1002-1008）。✅
4. 使用者停在「套用並重開」超過 300 s → provd 關閉閒置連線 → `_lost` → `alive` 變 false → 下一個 `run` 先 `close()` 再 `loginFor`（M2 的修正）。✅
5. 按「套用並重開」→ `press(Apply, h.now())`（swupdate.dart:345）→ update/apply 寫出 → 有兩種情況：
   - 節點回 0 → `on_apply`：`self.since = now`（swupd.rs:1206）；
   - 節點先重開 → `_lost` → notSent → `sw.lost(now)` → `Read::Failed(Apply)` → `on_reboot`。
6. 重開期間：每次 `ask` 時 console 都是死的 → `loginFor` 60 s 失敗 → `OpReply.login` → `sw.noLink(now)` → `on_reboot(None)`：`link_since.get_or_insert(now)`；還沒滿 300 s 就等 10 s 再讀（swupd.rs:1066-1073）。一次登入花多久不影響判定（P12 ✅）。
7. 節點回來 → 登入成功 → phase 4 → 每 30 s 讀一次、最長 15 分鐘（:1076-1082）→ phase 5 → done → 關頁 → `pageGone` → 放掉佔用；`AppLink.sw` 移除這台。

整條路徑要成立，前提是「每一次呼叫的 `now` 都來自同一個時鐘」。計畫沒有寫出這個前提，而 `OwnerConsole` 手邊現成的是另一個時鐘 → MAJOR-1。

## 3. 發現

### MAJOR-1　`askSw` / `swAnswer` / `lost` / `noLink` 的 `now` 沒說用哪個時鐘；照計畫字面用 `OwnerConsole.nowMs`，會和 `press` 的時鐘不一致，「設好手機 Wi-Fi 之後 30 s 內重試」和重開的判定都會錯

- **情境**：計畫有三處只寫 `now`：§2.2 表的 `askSw(sw, nowMs)`、§2.2「`swAnswer(sw, now)` 在 `_run` 的 `answer` 臂裡算」、§2.8「`sw.noLink(now)` / `sw.lost(now)`」。
  - `OwnerConsole` 手邊現成的時鐘是建構參數 `nowMs`。PR 3 傳進去的是 `a.link.now`（net_pages.dart:58），也就是 AppLink 的靜態 Stopwatch，從 app 啟動開始算（app_link.dart:57）。
  - 同一個更新的 `press` 用的卻是 `SwHold` 自己的 Stopwatch，從 hold 建立開始算（swupdate.dart:63-64、:345）。
  - Rust 的契約是「Dart 的單調時鐘，**同一個更新的每一次呼叫都用同一個**」（bridge/src/api/swupdate.rs:205-206）。舊 `_askSw` 全部用 `h.now()`（nodes.dart:1590-1622）。
- **後果（發生在 PR 4 新做的路徑上）**：假設 app 已經開了 40 分鐘，hold 才建立 2 分鐘：
  - 使用者按「去設定手機 Wi-Fi」→ 5.6 → 回來按「設好了，繼續」。`press(ApDone, h.now())` 設 `ap_until = 120 000 + 30 000`（swupd.rs:762）。bulk/open 的回答走 `swAnswer(link.now = 2 400 000)`，`on_open` 判斷 `now < ap_until`（:1124）永遠是 false。結果是節點 AP 剛重啟時回的 16 / 21 不會重試，畫面直接又顯示「去設定手機 Wi-Fi」。這正是 PR 4 新做的 goWifi 往返（T-U5）。
  - `since`（:966、:1206）、`link_since`、`trial_since` 如果有的值來自 `press`、有的來自 `swAnswer` / `lost` / `noLink`，`saturating_sub` 會算出 0 或一個很大的數。重開的等待會提早變成「稍後再看」，或一直不結束。
- **修法**：寫明 `askSw` 收 hold（或收 `BigInt Function() now` = `hold.now`）；`swAnswer` / `lost` / `noLink` 全部用 `hold.now()`，**不得**用 `OwnerConsole.nowMs`。
- **負對照**：T-U2 / T-U5 用兩個起點刻意不同的假時鐘（console 時鐘 = hold 時鐘 + 10⁶）。按「設好了，繼續」之後第一次 bulk/open 回 16，期待得到「再試」的 Wait；用 console 時鐘時這個測試 FAIL。
- **附帶（不另列）**：goWifi 往返之後重新打開更新頁，等於做一次新的 `loginFor`；舊控制台則沿用 5.6 的同一個 session。登入的時間會吃掉 `AP_RETRY_FOR_MS` 的 30 s 窗口（swupd.rs:39-40；`ap_until` 在按下按鈕時就設了）。節點的 setkey 在回答之前已經套用，通常不需要重試，所以列為已知差異、寫進 §3.3 即可。

### MINOR

- **m1 `askSw` 的結局對應不完整**：§2.2 / §2.8 只列了 answer、login、unclear / notSent / ended / leaseLost。漏了三種：
  - **`refused`**：`request_sw` 回 `Err`（`flow_busy`，或「上一個操作還沒結束」，owner.rs:1572-1582）時，`OwnerConsole._ask` 會轉成 `ReplyKind.refused`，而 `sessionAlive` 仍是 true（owner_console.dart:355-358）。舊 `_askSw` 遇到這種情況會先 `_drop()` 再 `lost`（nodes.dart:1606-1609）。新程式要寫明：refused → `sw.lost`，**而且 console 要當成死掉**，下一次重新登入。不然同一個卡住的 session 會一直被沿用，每次都 refused。
  - **`busy`**：`open` 如果在頁面打開時拿不到佔用（例如前一頁已經 gone、但還在 420 s 內忙），計畫沒說之後每次 `run` 會不會再試 `acquire`，也沒說 busy 對應到什麼。建議：`run` 時如果還沒持有佔用就再 `acquire` 一次；busy → `sw.noLink`（畫面顯示「連不到」+「重新整理」），同時頁面顯示「另一個操作還在進行：X」。
  - **`gone`** → `sw.noLink`（同舊程式的 `!mounted`，nodes.dart:1589）。
  - 測試：每一種 `OpReply` 一列。負對照：refused 不標成死掉 → 第二次 `run` 沒有呼叫 `loginFor`。
- **m2 `SwHold` 裡沒有 `SwUpdate`**：`askSw(sw, …)` 需要 Rust 的 `SwUpdate`（`request_sw(&mut SwUpdate)`、`sw_answer`，owner.rs:1571、:1605），但 `SwHold` 只帶 `SwFlow` 介面（swupdate.dart:48-50）；舊控制台是另外存一個 `_sw`（nodes.dart:1630-1636）。`AppLink.sw` 的值要寫成 (SwUpdate, SwHold)，或在 hold 裡加一個 `SwUpdate` 欄位；不要靠把 `SwFlow` 向下轉型成 `RustSwFlow`。
- **m3 「新鮮」是 300 s，不是 60–90 s；拿佔用也不會讓讀取變舊**：
  - 事實：`core.fresh` 預設是 300 000 ms（core.dart:15、:155-158），只有 `background()` 會把讀取標成 stale（:205-210）。D7 和 §2.7 的「最多約 60–90 s」要改成「最多 5 分鐘」。
  - 後果：離開網路成功之後，NodeLink 那份「在網路裡」的讀取仍然算新鮮，直到下一輪讀到為止（放掉佔用 6 s 後開始，`afterLease`；節點連不到時最長 5 分鐘）。這段時間裡 5.7 還顯示「離開網路」，5.8 還說「要先離開網路才能改國家」，和使用者剛剛看到的結果相反。
  - 修法：leave 回 0（`left`）之後，把這台在 NodeLink 的讀取標成 stale；或者在 NodeLink 有更新的讀取之前，5.7 / 5.8 改用離開頁重讀到的欄位。
  - 測試：離開成功後，5.7 不出現離開那一列，5.8 顯示「先讓手機讀到這台的狀態」。
- **m4 被入侵的節點：`SettingsView` 的字串原樣顯示**：`name` / `country` / `ap_ssid` 直接取自節點的 CBOR（owner.rs:656-672 也是原樣顯示），5.8 還寫明「其他代碼原樣」。節點可以送很長的字串、換行、bidi 控制字元，偽裝成「已更新」或別的國家。影響只限這台自己的畫面；但這是新的結構化欄位，修法也便宜：Rust 組 `SettingsView` 時套用 `statuspage::shown`（statuspage.rs:188）並限制長度；國家不是兩個大寫字母時顯示「（不明）」。測試：一列含 `\n` 和 U+202E 的回答。
- **m5 `settings/set` 成功但 `read = false`**：節點快取讀不到時回空 map（settingsset.go:153-160），而計畫 §2.4 寫「名稱顯示回答裡的新值」，結果會顯示空白。改成「已更新 — 請按重新讀取確認」，並自動 `settings()` 一次（或只顯示這句話）。
- **m6 密碼在登入之前就清空**：§2.4 規定按下送出時先清空欄位，再跑 `once`，而 `once` 裡有最長 60 s 的 `loginFor`。現場最常見的失敗正是登入不到（太遠、藍牙被關），照這個順序，每次失敗都要重打 12–63 個字元。建議：
  - `once` 期間欄位停用、內容保留；只在呼叫 `requestSetAp` 的前一刻取出並清空。登入失敗 / busy / gone 時不清，頁面 dispose 時清。
  - 名稱欄預填讀到的目前名稱（節點要求兩個值都送）。
  - 秘密的保護不變（SecureScreen、不可選取、不進 log）。
- **m7 `statusFieldsOf` 會用到 session**：nodes.dart:1157-1203 的轉換還會呼叫 `s.teamView` / `s.updateHint` / `s.last4()`（:1166-1176），而且是在回答之後、非同步讀紀錄的時候用 session，正好落在 §2.2 想避開的窗口。要寫明：新頁面只用 `_run` 裡算好的 `StatusView`（判定句、⚠️ 行、`unfinished` 行）；`statusFieldsOf` 裡需要 session 的部分改成由參數傳入，新頁面不傳。
- **m8 `_run` 裡算 `swAnswer` 的範圍**：要寫明只對「目前正在等的那個 askSw 請求」算（`_sw` 在每個請求開始時設、在 `finally` 清掉），每個請求最多算一次。逾時之後才到的回答，目前會被兩道檢查擋掉：`_kick` 把 `_session` 設成 null，以及 `_run` 開頭的 `identical(_session, s)`（owner_console.dart:213、:291）。加一個測試把這件事鎖住：逾時後送進一個遲到的 sw 回答，flow 的狀態不變。負對照：拿掉 `identical` 檢查。
- **m9 矩陣缺的列和數字**：
  - **app 被切到背景**（使用者切去 TAK）時 `once` / `open` 正在跑：NodeLink 的 `background()` 會把讀取標成 stale，佔用不受影響；但 Android 在背景限制掃描，重開期間 `loginFor` 可能一直 notFound，300 s 後變成「稍後再看」。和現況相同，列出來即可。
  - **§2.8「最長約 20 分鐘」**：寫入 ≤ 5 分鐘 + 重開 ≤ 5 分鐘 + 試用 ≤ 15 分鐘（swupd.rs:43、:45），合計約 25 分鐘以上。
  - **`once` 與 `lease.pageGone()`**：如果頁面被系統拿掉時 `once` 呼叫了 `lease.pageGone()`，離開頁最長要 60 + 360 + 15 + 10 s，超過 `goneMax` 420 s（lease.dart:117）。佔用會被收回，還會留下一個「上一個操作可能沒有存完：離開網路」的待辦，但離開根本不寫紀錄。要寫明 `once` 不呼叫 `lease.pageGone()`（只設 `_gone`，做完就放），或者接受這個行為並寫出來。

## 4. 安全（逐 actor，只看新增的部分）

- **遠端攻擊者**：沒有新的空中介面；owner-op 要簽章，節點會再驗一次（settingsset.go:96-142）✅。
- **同一支手機上的其他 app**：沒有新檔案；密碼欄不可選取、autofill 關閉、IME 不學習 ✅。第三方鍵盤本來就看得到按鍵，這是平台的限制。
- **被入侵的節點**：
  - 顯示字串，見 m4。
  - 它能讓 sw 流程顯示「套用」按鈕，因而產生首頁待辦；這只是提醒，不會寫紀錄 ✅。
  - 它收到的 AP 密碼本來就是它自己 AP 的密碼 ✅。
- **實體取得手機**：密碼不落地；SecureScreen 設不了時整頁不顯示（fail-closed）✅。
- **供應鏈**：沒有新套件 ✅。
- **我們自己的錯**：
  - MAJOR-1（時鐘）、m1（refused 不標成死掉）、m3（離開之後還邀請離開）。
  - 密碼路徑：Dart 區域變數 → frb → `request_set_ap`（owner.rs:777-783，不進步驟文字）；`OwnerConsole.log` 只記類型（owner_console.dart:366-368）✅。

## 5. 事實抽查

- 核對無誤：
  - P7 ✅（settingsset.go:60-78；`CHANGE-ME-NOW` 由 setkey 檢查，不在 Go 程式裡）
  - P8 ✅（:113-124）
  - P10 ✅（:153-160）
  - P11 ✅（owner_console.dart:278-281）
  - P12 ✅（swupd.rs:43、:1066-1073）
  - IdleAuthed 300 s ✅（provd/server.go:31）
  - owner.rs:752 / :2790 ✅
- **新增事實**：
  - NodeLink 的「新鮮」是 300 s（core.dart:15），見 m3。
  - OwnerConsole 的 `nowMs` 是 AppLink 的時鐘（net_pages.dart:58、app_link.dart:57），見 MAJOR-1。

## 6. 結論

**APPROVE-WITH-CHANGES**：1 個 MAJOR（MAJOR-1：計畫寫明用哪個時鐘、加一個負對照就能關閉），9 個 MINOR。第一輪的 4 個 MAJOR 都已關閉，修正本身沒有開新洞。
