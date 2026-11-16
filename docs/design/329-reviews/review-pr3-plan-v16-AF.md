# #329 PR 3 計畫 v16 審查 — AF（實作者角度）

- 審查對象：`docs/design/329-pr3-plan.md` v16 @ df47d0d（整份 §0–§9 讀過一次）
- 基準（不重審）：`254-app-join2.md`、舊控制台（nodes.dart、member_ui.dart、owner.rs、rekey.rs、netrec.rs、flow.rs）
- 方法：把 11 個現場情境逐一走過新頁面，看文字本身能不能決定每個畫面、按鈕、navigator 呼叫、佔用呼叫、`OwnerConsole` 呼叫、`ConsoleReply` 處理和紀錄寫入；引用的原始碼事實逐條對過。只讀，沒有改任何檔案（本報告除外）。

**結論：APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 11 MINOR**

---

## 1. 原始碼事實核對

| 計畫的說法 | 結果 | 證據 |
|---|---|---|
| `[JOINED] ` 只在 `E::Applied` 的加入回答裡；連線檢查的句子也用 `[JOINED]` | ✅ | owner.rs:513-517（`join2_text` Applied）；owner.rs:586-590（`link_text` NotYet / Unknown） |
| `send_update = applied && behind`；`poll_link` 要 `!behind` → 兩者互斥，而且 `send_update` 只會跟 `[JOINED] ` 一起出現 | ✅ | owner.rs:1435-1439 |
| 確認的回答都以 `[NET_STATE] ` 開頭；錯誤是 `[REQ_FAIL] ` | ✅ | owner.rs:484-491（`confirm_text`）；owner.rs:640-645（`error_text`）；owner.rs:879-893 |
| `[UPDATED] ` 是送新密碼成功；失敗是 `[REQ_FAIL] ` | ✅ | rekey.rs:432、:447、:451-452 |
| `forgettable = joining && !creator`；pending 紀錄的建立者是 `Joining` | ✅ | member_ui.dart:172；netrec.rs:392-396 |
| 只有 pending 的時候才有 `MemberView.creator`；`nodeDacHash()` 已經有 | ✅ | owner.rs:98-119（`pending_creator`）；netrec.rs:405-412；owner.rs:990-994 |
| 加入中的成員帶 `device_id`（待辦要靠它對到手機的節點） | ✅ | join2flow.rs:362 |
| 建立中的 pending 紀錄裡，建立者是 v1 成員，沒有 `device_id`，名稱是 `node-<last4>`（所以預選要用名稱） | ⚠️ 推論 | netrec.rs:383-396、owner.rs:1083；沒有實際印出一筆 pending 紀錄 |
| `Lease.hold()` 在佔用無效時丟例外；`pageGone` 忙碌時給 420 s 期限；放掉最後一個 hold 才釋放 | ✅ | lease.dart:57-90 |
| `acquire` 在 `reg.current != null` 時立刻回 null（D9） | ✅ | node_link.dart:153-154（lease.dart:124-129） |
| `BleGate.connect` 一次只能有一條連線 | ✅ | ble_gate.dart:226-231 |
| `RecordWriter` 檢查 `identical(reg.current, l)` | ✅ | record_writer.dart:27-33 |
| `keyErrorToRadio` 只在 `refusedBy != null` 時才動 | ✅ | app_link.dart:142-144；key_abilities.dart:96-106（被收回或不見的金鑰也是 `keyLevel`，`details == null`） |
| 舊的 `_ask` 重送分支，PR 3 的五個請求都走不到 | ✅ | nodes.dart:547-566；make :486-489（`unclear`）、join :647、confirm :1244、sendUpdate :1581（`retry: false`）、`_watchLink` :703 |
| `_watchLink` 遇到非回答就停 | ✅ | nodes.dart:700-712（`null` 時 break；逾時 → `_drop` → 下一輪 `!identical(_session, joined)` 時 break） |
| `_sendUnclear` 這一句、送新密碼等 360 s | ✅ | nodes.dart:55、:1581 |
| 首頁第 6 列：`mnet` 也對到 `joinNetwork`（所以 4.1 自己會碰到只有 mnet 的情況） | ✅ | home_logic.dart:92-96 |
| 舊控制台的「建立網路」一直都在 | ✅ | nodes.dart:1718-1731 |
| 被入侵的節點不能讓 `answer` 的開頭變成 `[NET_STATE] ` / `[JOINED] ` / `[UPDATED] `（節點的字串只會出現在句子中間） | ✅ | owner.rs:640-645、:484-491、:513-517；rekey.rs:432-452 |
| `LoginFor` 的 60 s 從物件建立的那一刻算 | ✅ | core.dart:628-640、:735-741（所以「從掃描真的開始才算」= 等掃描開始後才呼叫 `core.loginFor`，實作要注意） |
| 本 PR 沒有新的平台方法或匯出元件 | ❌ 沒查 | 程式還沒寫；第 7 步做程式審查時看 manifest 的 diff |

---

## 2. 情境走查

| 情境 | 文字能不能完全決定？ | 備註 |
|---|---|---|
| (a) 從零開始，先建 04 再加 02 | ✅ | 認領 → 3.2 → 3.5（沒有 net → 建立）→ 4.1 建立模式、預勾 04 → 4.1 `acquire` 並比對 → push `NetRunPage` → `loginFor` → `makeNetwork` → 有 `persistedRel` → 重讀 → 已建立 → 結果頁。02：3.6（有 net → 加入）→ 4.1 加入模式（只有一筆，不問）→ `joinNetwork` → `[JOINED] ` → `pollLink` → `linkCheck`。全部有寫。 |
| (b) 兩台一起勾 | ⚠️ | 流程有寫（§2.5 建立模式），但沒寫「勾的第一台」照什麼順序排（m8） |
| (c) 建立途中拔 04 的電：已套用 / 沒套用 | ⚠️ | `unclear` + `persistedRel` → 重讀 → 自動檢查 → 先關再重新 `loginFor`（04 還在開機，多半 `notFound`）→ 重讀 → 停 → 那一列給「檢查網路」→ 借用佔用的檢查網路頁 → 已套用：升級 →「完成」；沒套用：`[NET_STATE] …沒有套用` → 「建立網路」→ 回「去建立」→ `NetRunPage` → 4.1 建立模式。大致都能決定。沒寫的：自動檢查的登入失敗時，那一列顯示哪一句（m8）；停下的畫面要不要顯示 2.x 的內容（m1） |
| (d) 建立者壞了，只剩 pending | ✅ | 第 6 列「加入網路」→ 4.1 選到 pending →「檢查網路」+ 次要「建立網路」（全部都是 pending）→ 切到建立模式 |
| (e) 加入途中 app 被殺 | ✅ | 待辦用 `forgettable` + `deviceId` → 4.1 加入模式、目標網路、預勾那一台；被殺的如果是建立者 → 不列待辦 → 第 6 列或節點頁的「檢查網路」（§3.2） |
| (f) 迴圈途中關藍牙 | ⚠️ | 停止的規則有寫（`core.blocked`、對話框收起）；畫面內容沒寫（m1） |
| (g) 請求進行中頁面關掉 | ⚠️ | 順序是 `pageGone` → 等 → `close` → 放 hold，有寫。`linkCheck` 正在跑時要在下一次讀取前停，還是跑完 120 s，沒寫（m9） |
| (h) 檢查網路頁選錯節點 | ✅ | 用 `nodeDacHash` 比對失敗 → 「這台不是…」+「換一台檢查」，不送確認、也不給建立 |
| (i) 被入侵的節點回假的答案 | ✅ | 只看 `kind == answer` + 開頭的標籤；節點能說謊說「已套用」是基準（join2 §6） |
| (j) 加入成功後送新密碼失敗 | ❌ | 見 **MAJOR-1** |
| (k) 迴圈途中管理者金鑰失效 | ⚠️ | `signAdmin` → `_keyFail` → `keyError` → 整個停，有寫。和「重讀失敗」那條規則重疊（m2） |

---

## 3. 發現

### MAJOR-1 加入列的「再試這一台」只寫了 `joinNetwork(rel)`，送新密碼與連線檢查沒寫 → 情境 (j) 那一列會被標成成功，但節點其實還在舊版本

- **情境**：02 加入，回 `[JOINED] ` 而且 `sendUpdate`（節點本來就是成員，只是版本落後）。接著 `sendUpdateFor` 回 `unclear` 或 `[REQ_FAIL] …`。照 §2.5，那一列記成「已加入，新密碼沒有送出 / 結果不明」，這一台算失敗。結果頁對加入列的下一步是 §2.5:139「再試這一台 = `joinNetwork(rel)`（D5）」。
  - 再加入一次，Rust 會再走一次「已經是成員」的路（節點回 5 → 讀 info → 還是落後），又回一個帶 `sendUpdate` 的 `[JOINED] `（join2flow.rs:321-330，owner.rs:1435-1439）。
  - 建立列寫明了「之後照迴圈的建立規則（含自動檢查一次）」（§2.5:138），加入列沒有對應的句子。:140 只說「照迴圈的**等待**規則（PopScope、keepScreenOn、頁面消失就停）」。
  - 照字面實作的人會只呼叫 `joinNetwork`、只看 `[JOINED] `，就把那一列換成「成功」。但節點還拿著舊密碼，現場的結果是：之後一換密碼，它就和隊伍斷線。
- **證據**：計畫 §2.5:138-140；owner.rs:1435-1439；join2flow.rs:321-330；nodes.dart:661-669（舊控制台的「繼續加入」整條都會再跑，包括 `_sendAfter`）。
- **修法（不加新機制，照迴圈）**：§2.5 加入列改成「再試這一台 = 迴圈的加入規則：`joinNetwork(rel)` → 有 `sendUpdate` 就 `sendUpdateFor(rel, member: false, confirm: false)` → 有 `pollLink` 就 `linkCheck()`；成功與失敗的判斷和那一列的文字都照迴圈」。
- **改壞對照**：結果頁對加入列「再試」，假 Rust 回帶 `sendUpdate` 的 `[JOINED] `，送新密碼回 `[REQ_FAIL] ` → 那一列仍是失敗。拿掉 `sendUpdate` 的分支後，這個測試要 FAIL。

### MINOR

- **m1 停下時畫面上顯示什麼沒寫。**
  - §3.2「藍牙 / 權限 / 金鑰 → 整個流程停」、§2.5「其他（…登入失敗）→ 顯示句子」。上層設計 :546 寫的是「不成立 → 流程頁顯示 2.3 / 2.2 / 2.4 的內容與按鈕」。
  - `LoginEnd` 的 `identity` / `refused` / `notFound` 也沒有指定句子。現成的句子在 node_list.dart:19-25（`Why`）。
  - 修法：寫明 `precondition` → `NetRunPage` / 檢查網路頁顯示 2.x 的內容；另外三種用 `Why` 的句子。
- **m2 金鑰例外有兩條規則重疊，沒寫哪一條優先。**
  - §2.3 說頁面自己單筆重讀時的 `open` 例外 → `keyErrorToRadio` + 整個停。§2.5 說「重讀單筆紀錄失敗（打不開…）→ 當成不是已建立、走檢查網路」。
  - §2.8 檢查網路頁重新列檔時，「打不開的單筆跳過」；遇到 `keyLevel` 例外時，照字面會變成「沒有需要檢查的網路」+「完成」，等於騙使用者沒事。
  - 修法：一句「`open` 回 `refusedBy != null` → 一律走 `keyError` 規則，優先於跳過或當成不是已建立」。
- **m3 手機裡有 net 檔，但全部打不開時，4.1 顯示什麼沒寫。** 第 6 列看的是有沒有檔案（§2.6），所以會顯示「加入網路」；4.1 只列打得開的。join2 :128 / T8 對這種情況有固定的提示（不能再加節點、新建會拆隊）。修法：4.1 加入模式沒有打得開的 net → 顯示 join2 的那一句，沒有表單，也不給「建立網路」。
- **m4 有些舊路徑沒有對到 `ConsoleReply`。**
  - `makeNetwork` 開頭那道 `KeyUse.makeNetwork` 的檢查（nodes.dart:478-482，`[REQ_FAIL] [KEY_LEVEL]`，什麼都沒送出）。
  - `joinNetwork` / `confirmNetwork` / `sendUpdateFor` 讀 `rel` 打不開（nodes.dart:1572-1575）。
  - 這兩類要回什麼 `kind`、要不要設 `keyError`，沒寫。建議都回 `notSent`；`KEY_LEVEL` 那一類設 `keyError`。
- **m5 擁有權表少一個寫入者。** §3.1「net 紀錄（新頁面）| `OwnerConsole` 經 `RecordWriter`」，但「放棄這次加入」的獨立函式也經 `RecordWriter` 寫 net 紀錄，而且不經 `OwnerConsole`（§2.4）。表裡要加這一列。
- **m6 `OwnerConsole` 的生命週期與介面沒寫完整。**
  - 沒寫一個 `OwnerConsole` 是對應一次 `LoginHandoff`，還是一個頁面一個。§2.2 的 `close()` 是屬於誰的。
  - 檢查網路頁要用 `nodeDacHash()`，但 §2.3 列出的方法裡沒有它（session 歸 `OwnerConsole`，§3.1）。
  - 修法：寫明「每次 `loginFor` 成功建一個；`close()` 之後不再使用；提供 `nodeDacHash()`」。
- **m7 國家對話框開著時連線斷了。**
  - `ask` 回 `unclear` 之後，頁面會把「繼續 / 停」疊在還開著的國家對話框上面；`close()` 要等那個處理者，每次最多 10 s（§2.2）。
  - 舊控制台也會這樣（nodes.dart:274-289，靠 `gone()` 擋），屬於基準。但新頁面要寫明：請求結束、而且沒有回答時，把國家對話框當成「不要」收起，處理者裡保留 `gone()` 檢查。
- **m8 建立模式的兩個小地方沒寫。**
  - 「勾的第一台」照什麼順序排（4.1 清單的順序沒定義）。
  - 自動檢查的重新登入失敗時，那一列顯示哪一句（`_makeUnclear` 還是登入失敗的句子）。
- **m9 頁面消失時 `linkCheck` 正在跑。** §2.5「不做之後的送新密碼與連線檢查」沒有涵蓋「正在跑的那一次」。建議：`OwnerConsole.linkCheck` 每次讀取前看頁面是不是已經消失，已消失就停（舊碼靠 `mounted`，nodes.dart:700）。
- **m10 送新密碼失敗那一列的文字只定義了兩種。** 只有 `notSent` / `unclear` 有文字；`answer` 但不是 `[UPDATED] `（例如 `[REQ_FAIL] 沒有送出：…`，rekey.rs:432-450）與 `refused` 沒有。建議歸到「已加入，新密碼沒有送出」+ Rust 的句子。
- **m11 和設計的不同沒有列進 §4。** 建立失敗（沒有 `persistedRel`）時整個流程停、不問「繼續 / 停」，和設計 §5.4 :748「一台失敗：問繼續 / 停」不同。這是邏輯上必然的（其餘的台沒有網路可以加入），但 §4 沒有列這一條 D。

---

## 4. 基準備註（不是發現）

- Rust 建立網路時，如果節點的回答不明（`JoinReply::ReadInfo`），自己已經會在同一個 session 裡做一次 `check_network`（owner.rs:1506-1512）。所以 §2.5 的「自動檢查一次」在這條路上會是第二次確認。這不影響正確性，A18 量的時候可以順便記下來。
- 舊的 `_readRecord` 把 `open` 的 `PlatformException` 吞掉，也不呼叫 `_keyFail`（nodes.dart:725-733）。新頁面設 `keyError` 比舊碼嚴格；D11 已經涵蓋「停」，但沒有提到 `open` 這一點。
- 基準的節點版本落後：重新加入會靠節點回 5 走回送新密碼的路。MAJOR-1 依賴這個行為（join2flow.rs:321-330，⚠️ 只讀了原始碼，沒有在真機上跑過）。

## 5. 驗證分組

- ✅ 已驗證：§1 表裡標 ✅ 的各列（原始碼 file:line）。
- ⚠️ 推論：pending 建立者沒有 `device_id`、名稱是 `node-<last4>`；重新加入會再觸發 `sendUpdate`（只讀原始碼，沒有跑測試）。
- ❌ 沒做：沒有執行任何測試或程式；manifest 有沒有新的匯出元件，要等程式寫出來才能查。
