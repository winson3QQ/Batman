# #329 PR 3 實作計畫 v12 審查（審查者 X，獨立）

對象：`docs/design/329-pr3-plan.md` v12 @ 3ff31eb。角度：以明天要寫第 2–7 步的實作者身分讀完整份 §0–§9，把九個現場情境走過新頁面，檢查每個畫面、按鈕、佔用呼叫與紀錄寫入能不能只靠計畫文字決定。基準（join2、舊控制台、owner.rs / netrec.rs / flow.rs）不重審，疑問放「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 2 MAJOR / 9 MINOR）

v12 修好了 V-M1：結果頁每一列的下一步有寫，建立網路的入口在各節一致。剩下兩個 MAJOR 都是**新程式自己的介面沒寫下來**，不需要改 join2 的行為：
- **X-M1**：`OwnerConsole` 回給頁面的是什麼沒有定義。照字面複製 `_ask`，回傳值會是 `[ANSWER] …` 字串、`null` 加 `_askEnd`，加上幾個旁路旗標。§2.5 / §2.8 的判斷（`[NET_STATE] ` 開頭、`[JOINED]`、`NOT_LOGGED_IN`、「有 `rel`」、送新密碼失敗）都要靠它，現在只能用猜的。
- **X-M2**：迴圈頁用 `pushReplacement` 換成結果頁時，迴圈那個 route 會被 dispose。照 §2.5 的字面，這時會呼叫 `pageGone()`，佔用立刻被釋放，結果頁的「再試這一台」和「檢查網路」就借不到佔用。

---

## 1. MAJOR

### X-M1　`OwnerConsole` → 頁面的回傳契約沒有定義；照字面複製舊 `_ask` 的話，§2.5 / §2.8 的判斷對不上

- **情境**：情境 (c) 拔電，04 已套用。04 回來後，在借用的檢查網路頁上 `confirmNetwork` 拿到 `Upgraded`，接著寫入並 `netPersisted`。計畫 §2.8 的規則是「這一筆確認請求本身的 Rust 回答，文字以 `[NET_STATE] ` 開頭 = 拿到回答」。但舊 `_ask` 交給呼叫者的是 `'[ANSWER] ${st.detail}'`（nodes.dart:303、:324），所以字串開頭是 `[ANSWER] [NET_STATE] …`。舊控制台自己區分「Rust 回答」和「Dart 的句子」，靠的就是這個 `[ANSWER] ` 前綴（nodes.dart:709 `_watchLink`）。
  - 實作者如果照 §2.8 的字面寫 `startsWith('[NET_STATE] ')`，**永遠不會拿到回答**。結果是每次確認都「整頁停」，連升級成功也一樣；也從不給「建立網路」（fail-closed，但功能壞掉）。用假資料的單元測試照實作者自己的字串寫，抓不到，要到第 7 步真機才會發現。
  - 反過來，如果實作者把前綴拿掉之後再比對，Dart 自己的 `_makeUnclear = '[NET_STATE] 結果不明…'`（nodes.dart:50）就分不出來，只能再另外分辨。
- **還依賴同一個沒有定義的介面的判斷**：
  1. **自動檢查的「回 `NOT_LOGGED_IN`」**：`request_confirm_network` 用 `Err(String)` 拒絕（owner.rs:1173-1175）。舊 `_ask` 會 `rethrow` 字串，外層 catch 之後回 `null`，原因放在 `_askEnd`（nodes.dart:542-543、:581-584）。頁面拿不到「NOT_LOGGED_IN」這個值。
  2. **舊 `_ask` 一開始就會自動重新登入**：`if (_session == null && _lastNode != null) await _login(_lastNode!)`（nodes.dart:521）；寫入失敗時 `retry` 也會再登入一次（:549-565）。§2.3 列的複製項目沒有寫要不要保留這兩點。保留的話，§2.5「先 `await close()` 再 `loginFor` 一次」就和 `ask` 自己的重新登入重複或衝突，§2.5「`pageGone` 之後不開新的登入」也要靠 `ask` 自己來檢查（舊的是 `!mounted`，nodes.dart:518-520；`OwnerConsole` 不是 widget）。
  3. **送新密碼與連線檢查**：舊的用旁路旗標 `_sendAfter` / `_linkFrom` / `_removedQ`（nodes.dart:316-318、:296-303），不是回傳值。
  4. **「有 `rel`」**：§2.5 寫「有 `rel`（已寫入、已送出）」，但 `rel` 是 `PersistNet` **步驟**帶來的（owner.rs:428-431、:1460-1467）。步驟出現之後寫入仍可能失敗（seal 失敗、Keystore、`NoLease`），這時 Rust 回 `[REQ_FAIL] 建立網路沒有成功：…`（`persist_failed` 在 `applied: false` 時，owner.rs:1144-1150）：什麼都沒寫、也沒送出（join2 §3.1）。照計畫的字面，這一列算「有 `rel`」，所以只給「檢查網路」。檢查網路頁重新列檔時找不到這一筆 pending，下一步沒有定義（見 X-m3）。實際上它應該是可以安全「再試這一台」的情況。
- **證據**：plan §2.3「回傳 Rust 的句子給頁面（不是 `_say`）」是唯一描述；§2.5、§2.8、§6 第 5 步的判斷都以此為前提。nodes.dart:296-336（`OwnerKind.answer` / `ended` / `confirmRemoved` 怎麼完成 `_answer`）、:507-589（`_ask`）。
- **修法（只是把介面寫下來，不加新機制）**：在 §2.3 加一張表，定義 `ask` 的回傳型別。例如 `ConsoleReply { kind, detail, … }`：
  - `kind` 的值：`answer`（Rust 的 `OwnerKind::Answer`，`detail` = Rust 的 detail，不帶 `[ANSWER] `）/ `unclear` / `notSent` / `timeout` / `ended` / `refused`（Rust 的 `Err(String)`，原字串）/ `leaseLost`。
  - 旗標：`sendUpdate`、`pollLink`、`removedQ`。
  - `persistedRel`：只有在**第一個** `PersistNet` 寫入成功、呼叫 `netPersisted` 之後才設。
  
  §2.5 / §2.8 改成照 `kind` 判斷：「拿到回答」= `kind == answer && detail.startsWith('[NET_STATE] ')`；`NOT_LOGGED_IN` = `kind == refused && detail == NOT_LOGGED_IN`，或 `kind` 是 `unclear` / `ended`；「有 `rel`」= `persistedRel != null`。另外寫明 `ask` **不**自己登入，登入一律由頁面呼叫 `loginFor`；`OwnerConsole` 有一個 `stopped` 旗標，頁面在 `pageGone` 時設，設了就不開新的請求。
- **改壞對照**：
  1. 用複製來的真 `ask` 跑 confirm（假 session 回 `Confirm::NoChange(NotApplied)` 的 detail）→ 「建立網路」出現。改壞成比對未去前綴的字串 → FAIL。
  2. pending 的 `writeCas` 拋錯 → 結果頁那一列是「再試這一台」（`makeNetwork`），**不是**「檢查網路」。改壞成「看到 `PersistNet` 步驟就算有 `rel`」→ FAIL。

### X-M2　迴圈頁 → 結果頁用 `pushReplacement`，迴圈 route 被 dispose 時佔用會被釋放；佔用在兩個 route 之間的交接沒有寫

- **情境**：情境 (a) / (c)。迴圈做完 → 「進結果頁 = 工作做完：`close()`、關 `keepScreenOn`、放掉 `hold`（`_busy` 歸 0，佔用仍在、頁面仍在）」（§2.5:90）→ 「結果頁取代迴圈頁（`pushReplacement`）」（§2.5:102）。替換的動畫跑完之後，迴圈頁的 State 被 dispose。§2.5:92 把「工作途中頁面消失」定義成 dispose → `pageGone()`，§3.1 又說「迴圈 / 結果頁是唯一的 `pageGone` / `release` 呼叫者」。照字面寫，迴圈頁的 `dispose` 會呼叫 `pageGone()`，這時 `_busy == 0` → 立刻 `release()`（lease.dart:73-78）。接著結果頁按「再試這一台」或「檢查網路」時呼叫 `hold()`，因為佔用已經不 `valid`，丟 `StateError`（lease.dart:60-61）。T-M1(h) 會失敗，但計畫文字沒有告訴實作者怎麼避免。
- **第二個後果（已對 Flutter 原始碼確認）**：`pushReplacement` 會在舊 route 被換掉時就完成「push 舊 route 那一方」的 future（flutter/packages/flutter/lib/src/widgets/navigator.dart:2383-2386：「the future that had been returned from pushing that old route will complete with `result`」）。所以入口頁 `await push(4.1)` 在**迴圈一開始**就回來了，不是在離開結果頁的時候。
  - 首頁現有的 `_back`（home_page.dart:157-162：`setPage(Page.home)` + `_todos()`）會在建網之前就跑完。§2.5「離開 4.1 回到進來前的那一頁（`Page.node` 連同節點一起還原）」與「離開結果頁回到入口頁」的時機都因此對不上。
  - 「結果頁 pop 自己 → 開 4.1 建立表單」（§2.8:145）這時已經沒有入口頁在等，由誰 push 4.1 沒有寫（V-m5 的殘留）。
- **修法（擇一寫進 §2.5 / §3.1，不加機制）**：
  - (a) 迴圈頁與結果頁是**同一個 route、同一個 State 的兩個階段**。佔用由這個 State 擁有，它的 `dispose` 是唯一的 `pageGone` 呼叫者。§2.5 的「pushReplacement 結果頁」改成「切換到結果階段」。
  - (b) 保留兩個 route，寫明交接：迴圈頁把 `Lease` 交給結果頁之後，自己的 `dispose` 不呼叫 `pageGone`。
  
  建議用 (a)，最少狀態。另外寫明三件事：
  - 從結果頁「去建立」：結果頁 `pushReplacement(4.1 建立表單)`。結果頁的 dispose → `pageGone` → 釋放，4.1 的「開始」照 `acquire` 規則。
  - 自己拿佔用、從 4.1 進來的檢查網路頁：pop「去建立」給 4.1，4.1 自己切到建立模式。
  - 從節點頁進來的檢查網路頁：節點頁收到「去建立」→ push 4.1 建立表單。
  
  入口頁的重新整理不靠 `await push` 回來的時機，改聽 `NetIndex` 的變更（X-m7）。
- **改壞對照**：結果頁出現後 `reg.current` 仍是迴圈的佔用；「再試這一台」能拿到 `hold`。改壞成迴圈頁 dispose 時呼叫 `pageGone` → FAIL。

---

## 2. MINOR

**X-m1　確認的等待時間在 §2.8 沒有跟著改。** §2.5:96 與 §6 都寫「確認等 15 s（nodes.dart:91）」，§2.8:131 仍寫「登入 ≤ 60 s + 每筆確認 ≤ 60 s」。改成 15 s，和 V-m3 的處理一致。

**X-m2　加入成功的判斷也要寫成「Rust 回答、以 `[JOINED] ` 開頭」，和 §2.8 一致。** 現在 P8 / §2.5 只寫「`[JOINED]` = 成功」。`error_text` 會把節點給的 verb 文字放在句子中間（owner.rs:648-649 `detail.get(1).as_text()`），被入侵的節點可以讓錯誤句子中間出現 `[JOINED]`。Dart 自己的 `_linkUnknown` 也以 `[JOINED]` 開頭（nodes.dart:54）。影響只在畫面上把那一台標成成功、讓迴圈繼續（紀錄由 Rust 決定，沒有被改），但兩節的寫法應該一樣。測試：錯誤句子中間有 `[JOINED]` → 那一台算失敗。

**X-m3　檢查網路頁重新列檔後「沒有要檢查的 pending」這個狀態沒有定義。** 會出現的情況：
- 借用進來時，那一筆已經被迴圈的自動檢查升級了；
- pending 根本沒寫成（X-M1 第 4 點）；
- 從節點頁進來之後，別的頁面把它升級了。

§2.8 只有「列不出來 → 再檢查一次」。建議寫成：「沒有建立中的網路要檢查」+「完成」（返回），不登入、不給建立。

**X-m4　D9 的說法和程式不符。** `NodeLink.acquire` 一開始就是 `if (reg.current != null) return null;`（node_link.dart:153-154）；§2.1 加的等待只蓋「`released` 之後讀紀錄」那一段，不蓋退場動畫結束、dispose 之前的空檔。D9 說「4.1 的『開始』靠 `acquire` 等 `released` 接住這段空檔」不正確。實際上使用者要填表單，很難在約 300 ms 內按下「開始」；就算按到，看到的也是「另一個操作還在進行」，再按一次就好，無害。改 D9 的文字即可，不加機制。

**X-m5　頁面消失時對話框已經開著（V-m4 後半）沒有處理。** §2.5 只寫「不彈對話框」。舊控制台的做法是不在畫面上時回答「不要」，接著 `gone()` 就返回（nodes.dart:278-291）。請寫一句「國家 / 被移除過的問題在頁面消失後一律當成『不要』（照舊控制台）；已經開著的對話框隨 route 關掉，答案同樣當成『不要』」，並在 T-M1(g) 加一條測試。

**X-m6　4.1「開始」時比對什麼沒有定義。** §2.4:80「和 4.1 開頁時看到的不同 → 不開始」。4.1 自己的「放棄這次加入」會改掉一筆 net 紀錄的成員，如果比對整個摘要，使用者剛放棄完、按開始就會被擋。請寫明比對的是「net 代號集合 + 各筆 `applied`」，並且 4.1 在自己寫完之後重新取一次快照。

**X-m7　`NetIndex` 要能通知變更。** 因為 X-M2 的 `pushReplacement` 語意，以及 `_back` 時機不對，首頁第 6 列、待辦、4.1 的「正在讀取網路紀錄」都要在 `NetIndex` 算完時重畫。§2.6 沒有寫 `NetIndex` 要提供變更通知（stream / listener），也沒寫誰在聽。

**X-m8　結果頁上「再試」或檢查完成之後，那一列怎麼更新沒有寫（V-m5 殘留）。**
- 沒有 `rel` 的建立列按「再試」→ 建立出 pending → 這一列變成「有 `rel`」，按鈕應該換成只剩「檢查網路」。
- 借用的檢查網路頁「完成」（升級）回來 → 那一列改成「已建立」。

各寫一句，並各加一條測試（改壞 = 再試成功之後仍給「再試這一台」→ FAIL）。

**X-m9　節點頁的「檢查網路」可能永遠留著。** 情境：04 第一次建立留下 P1（pending），之後 04 在 P2 建立成功。P1 在新頁面刪不掉（§8），它的建立者名稱一直對得到 04，所以 04 的節點頁永遠有「檢查網路」。按下去之後 `nodeDacHash` 對得上 P1 的建立者 → 確認 → `OtherVersion` / `NoChange` → 手機已有已建立的 net → 只剩「再檢查一次」。不會造成傷害，但會讓人困惑。不建議加新條件（會重新決定 §5.5）；請在 §8 / PR 內文與 #329 checklist 把它寫成「pending 不能刪」的後果。

---

## 3. 現場情境走查（照計畫文字與原始碼推論，⚠️）

| # | 情境 | 每一步都能從計畫文字決定？ | 缺的地方 |
|---|---|---|---|
| a | 從零：04 建立 → 02 加入 | 大致可以：3.5「建立網路」→ 4.1 → 開始 → `acquire` → `loginFor` 04 → `makeNetwork` → `[NET_MADE]` → 重讀那一筆，已建立 → `close` → `loginFor` 02 → `joinNetwork(rel)` → 國家問題 → `[JOINED]` → 連線檢查 → 結果 → 離開時釋放 | 結果頁交接（X-M2）、回傳型別（X-M1）、`[JOINED]` 只看開頭（X-m2）、首頁更新的時機（X-m7） |
| b | 兩台一起勾 | 可以：第一台建立（可以換）、其餘加入 `rel` | 同 a |
| c1 | 建立途中拔電，04 已套用 | `unclear` → 有 `rel` → 重讀是 pending → 自動檢查 → `NOT_LOGGED_IN` 或已斷 → `close` → `loginFor` 60 s（04 通常還在開機 → `notFound`）→ 停 → 結果頁那一列「檢查網路」→ 借用 → 升級 → 完成 | 「有 `rel`」的定義（X-M1）、借用時佔用還在不在（X-M2）、完成之後那一列的更新（X-m8）、02 要回首頁重開 4.1（§2.5 有寫） |
| c2 | 同上，04 沒套用 | 檢查網路 → `NoChange(NotApplied)` → 拿到回答、沒升級、手機沒有已建立的 net → 「建立網路」→ 結果頁 pop → 4.1 | 由誰 push 4.1（X-M2）；`[ANSWER] ` 前綴（X-M1） |
| d | 建立者死了，只剩 pending | 第 6 列「加入網路」→ 4.1 → 只有一筆就自動選 → 是 pending → 「檢查網路」+ 次要「建立網路」→ 用 02 建立 ✅ | 4.1 從檢查網路頁收到「去建立」之後切到建立模式（X-M2） |
| e | 加入途中 app 被殺 | 成員停在 joining（join2flow.rs:356-365 寫入 `device_id`，所以 `MemberView.deviceId` 對得上 ✅）→ 待辦 → 4.1 加入，那一台預設勾；「放棄這次加入」自己拿短佔用 ✅ | 「開始」時的比對（X-m6） |
| f | 迴圈中途關藍牙 | 連線斷 → `unclear` → 「先看 `core.blocked`」→ 整個流程停、不問 ✅；結果頁的「檢查網路」→ `precondition` → 只給「再檢查一次」✅ | 無 |
| g | 請求進行中頁面被關 | `pageGone` → 等當前請求 → 收尾 → 放 hold ✅ | 對話框已經開著（X-m5）；`ask` 的 `stopped` 旗標（X-M1） |
| h | 檢查網路頁選錯節點 | 登入後 `nodeDacHash` 對不上任何建立者 →「不是建立者」+「換一台檢查」，不送確認、不給建立 ✅ | 無 |
| i | 被入侵的節點回假訊框 | 確認：只影響它自己是建立者的 pending（基準）；以 `[NET_STATE] ` 開頭判斷 ✅。加入：只有畫面上會被標成成功（X-m2）。送新密碼：只送給它自己（基準）。佔用：每一段都有上限 ✅ | X-m2 |

本地非特權程序：新頁面沒有新增平台方法、匯出元件或檔案路徑（plan §5 ✅）。BLE 廣播的攻擊面照 `LoginFor` 的規則，設計已經接受。沒有發現新的攻擊面。

## 4. 基準備註（不算發現）

- Rust 建立網路時，如果節點的回覆是 11 / 其他 / 不明（`JoinReply::ReadInfo`），Rust **自己**就會做一次 `check_network`（owner.rs:1505-1512）。所以 `makeNetwork` 的回答可能本身就是 `[NET_STATE] …`，§2.5 的自動檢查會是同一次登入裡的第二次確認。無害（netrec 的 confirm 是冪等的），但實作者要知道建立的回答不一定是 `[NET_MADE]` 或 `[REQ_FAIL]`。
- 舊控制台在頁面 dispose 時會立刻把等待中的請求當成「結果不明」（nodes.dart:146-152）；新頁面改成等當前請求做完（R m6）。這是新頁面的決定，計畫有寫，不算偏離基準。
- V 的基準備註（全部 pending 時的次要「建立網路」可能拆成兩個網路；`InProgress` / `Unknown` 也給建立）仍然成立。

## 5. 驗證分類

### ✅ 已驗證（原始碼 @ 3ff31eb）
- lease.dart:42-90（`run` / `hold` 在 `!valid` 時丟錯、`pageGone` 在 `_busy == 0` 時立刻 `release`、420 s）、:124-129（`acquire` 回 null）。
- record_writer.dart:177-194（`NoLease`，只檢查 `valid` 與 `current`）。
- raw_use.dart:285-293（acquire 回來時頁面已不在 → release）。
- ble_gate.dart:84-86、:185-212、:226-236（一次一條、`Refused`）。
- node_link.dart:153-164（`acquire` 一開始就檢查 `reg.current`，X-m4）、:171-195。
- core.dart:186-201（`setPage`）、:282-297（`setRadio` 結束 `_login`）、:628-748（`LoginFor`：`start` = 呼叫時、60 s、`result` 要 `c.lease`）。
- prober.dart:96-104、:133-175。
- home_page.dart:157-162（`_back` 在 push 的 future 回來後才 `setPage` + `_todos`）、:164-171；home_logic.dart:92-96。
- nodes.dart:50、:54（`_makeUnclear` / `_linkUnknown` 的標籤）、:146-152、:251-272（PersistNet：`_track.persisted()` 在寫入之前，失敗 → `persistFailed`）、:278-291、:296-336（`[ANSWER] ` 前綴、旁路旗標）、:507-589（`_ask`：一開始自動登入、retry 再登入、`String` 拒絕 → null + `_askEnd`）、:621、:668、:709、:1240-1245、:1248-1290、:1718-1737。
- owner.rs:77-123、:428-431、:445-447、:474-491、:506、:514、:589-590、:621-650（`error_text` 帶節點的 verb 文字）、:879-892、:991-994、:1094-1157、:1168-1178、:1434-1439、:1460-1512。
- join2flow.rs:337-365（joining 成員有 `device_id`）。
- Flutter `navigator.dart:2383-2386`（`pushReplacement` 讓舊 route 的 future 完成）。
- 設計 329-app-uiux.md:690-760。

### ⚠️ 推論
- X-M1 / X-M2 的後果、§3 的走查：照計畫文字與原始碼推論；新頁面與 `OwnerConsole` 還沒實作，沒有跑過。
- X-m4 的「約 300 ms」是 Material 預設的轉場時間，不是量到的。

### ❌ 沒做
- 沒跑測試、沒上真機；沒有重驗 v1–v10 的發現；沒有審 PR 1 / PR 2 的實作；沒查 Kotlin `open` 在 `NetIndex` 計算與佔用寫入同時發生時的行為。
