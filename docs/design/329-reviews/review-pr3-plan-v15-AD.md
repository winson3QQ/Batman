# #329 PR 3 計畫 v15 審查 — AD（實作者角度）

審查對象：`docs/design/329-pr3-plan.md` v15（commit 8a8f9df）。基準（join2、舊控制台）不重審，疑問放在「基準備註」。
方法：通讀 §0–§9，逐一走 (a)–(j) 十個現場情境，每一步問「畫面、按鈕、navigator、lease（acquire / hold / pageGone / release）、`OwnerConsole` 呼叫、`ConsoleReply` 處理、紀錄寫入」是否只靠文字就能決定；計畫引用的原始碼位置逐一回原始碼核對（read-only）。

## 結論

**APPROVE-WITH-CHANGES**：2 MAJOR、7 MINOR。兩個 MAJOR 都是計畫內部兩節之間沒對齊（不需要新機制，各用一行現有的判斷補上）。

## 情境走查

| 情境 | 文字能否完全決定 | 說明 |
|---|---|---|
| (a) 0 → 04 建立 → 02 加入 | ⚠️ 大致可以 | 首頁第 6 列 / 3.5 → 4.1 建立 → `acquire`+比對 → push `NetRunPage` → `loginFor` → `makeNetwork` → `persistedRel` + 重讀 → 結果 → pop → 4.1 pop。缺：3.5 / 3.6 進 4.1 時剛認領的節點算不算「帶進來的那一台」（AD-m5） |
| (b) 兩台一起勾 | ✅ | 第一台建立、`close()` → `loginFor` 第二台 → `joinNetwork(persistedRel)`；`[JOINED] ` 開頭判斷；`sendUpdate` 與 `pollLink` 互斥（owner.rs:1437-1439），所以「送新密碼之後再連線檢查」那條實際不會發生，無矛盾 |
| (c) 建立中拔 04 電 | ✅ / ⚠️ | 已寫 pending 後斷線 → `_unclearNow()` = `_makeUnclear`（`SendTrack.wrote` 為真，member_ui.dart:309）→ `unclear`、`sessionAlive=false` → 重讀 pending → `close()` → `loginFor`（04 重開中多半失敗）→ 重讀仍 pending → 停、該列「檢查網路」。已套用：檢查網路頁 Upgraded → 完成。沒套用：`NoChange(NotApplied)` → 拿到回答、沒有已建立的 net → 「建立網路」→ pop 鏈回 4.1 建立模式。缺：重開 app 後首頁會多出錯的待辦（AD-M1） |
| (d) 建立者壞掉、只剩 pending | ✅（除 AD-M1） | 第 6 列「加入網路」→ 4.1 pending →「檢查網路」+ 次要「建立網路」；檢查網路頁登入失敗 → 不給建立。4.1 次要按鈕按下後「切到建立模式」只是推得出來（AD-m6） |
| (e) 加入中 app 被殺 | ✅ | 成員 joining → 待辦 → 4.1 加入、預勾 → `joinNetwork` |
| (f) 迴圈中關藍牙 | ⚠️ | 登入中 → `precondition` → 停 ✅；請求中 GATT 先斷 → `unclear` → 問之前看 `core.blocked`。若狀態事件在對話框打開之後才到，文字沒說怎麼辦；§6 的「不問直接停」測試無法確定地做出來（AD-m3） |
| (g) 請求中頁面關掉 | ✅ / ⚠️ | `pageGone`（有 hold）→ 等當前請求 → `close()` → 放 hold → 釋放。「≤ 360 s、在 420 s 內」不精確（AD-m4） |
| (h) 檢查網路頁選錯台 | ✅ | `MemberView.creator && dacHash == nodeDacHash()`（owner.rs:991-994、:110-121）→ 不是建立者 → 不送確認、不給建立 |
| (i) 被入侵的節點送特製回答 | ✅ | 所有成功判斷都看 Rust 組出來的**開頭**（owner.rs:513、:487-490、:589-590；rekey.rs:432 起），節點字串只會出現在 `reason_text` 的中段（owner.rs:645-650）。「還在設定中 / 無法確定」→ 給建立是 join2 基準；預勾看節點自報的 `node_state` 只是建議，對象仍是自己認領過、DAC 驗過的節點 |
| (j) 加入成功後送新密碼失敗 | ⚠️ | 那一台失敗、問繼續 / 停；結果頁加入列「再試」= `joinNetwork` → Rust 對「已是成員但落後」再設 `send_update`（owner.rs:1437-1439）→ 再送一次，可行。但「結果不明」時那一列的標籤和舊控制台句子相反（AD-m2） |

## 發現

### MAJOR

**AD-M1 首頁待辦把 pending 網路的建立者當成「節點加入網路沒有做完」**
- 情境：(c)/(d)。建立送出後斷線或 app 被殺，`net/` 紀錄停在 pending。重開 app 後 `NetIndex` 照 §2.6「`joining` 的成員對到這支手機的節點」算待辦。
- 證據：pending 紀錄沒有 key 11 時成員由 key 8 推出、狀態一律 `Joining`（rust/batman-proto/src/netrec.rs:395）；`net_summary` 照原樣回 `joining: true` 並另標 `creator: true`（owner.rs:110-121）。舊控制台的「忘記加入中」用 `forgettable = joining && !creator`（member_ui.dart:172；nodes.dart:1252、:1257）排除建立者，Rust 也拒絕忘記建立者。
- 後果：04（建立者）出現待辦「節點加入網路沒有做完」→ 4.1 加入、預勾 04 → 同頁的「放棄這次加入」對 04 會被 Rust 拒絕；而且和 §3.2「建立中途 app 被殺」那一列（只寫第 6 列與節點頁「檢查網路」）矛盾。
- 修法：§2.6 待辦條件寫成 `joining && !creator`（現有 `forgettable`，不是新機制）；§6 第 4 步加一條：只有 pending 建立者 → 沒有這個待辦（改壞 = 只看 `joining` → FAIL）。

**AD-M2 `keyError` 只涵蓋 seal / open，簽章失敗（管理者 / 擁有者金鑰）不會讓迴圈停**
- 情境：迴圈中管理者金鑰失效（join2 T8），每一台的 `signAdmin` 都失敗。
- 證據：§2.3 只說「seal / open 時接到 Keystore 例外 → `keyErrorToRadio` + `keyError = true`」。舊控制台的簽章失敗在 nodes.dart:236-251 走 `_keyFail`（只顯示句子、送空簽章）；Rust 把它變成 `answer`（例如送新密碼的 `E::SignFailed`「[REQ_FAIL] 沒有送出：手機的管理者金鑰無法簽章」，rekey.rs 的 `update_text`）或 `ended`。`keyErrorToRadio` 只在 `KeyAbilities.refusedBy` 非 null 時才設 `keyOk=false`（app_link.dart:142-144），所以 `core.blocked` 也可能不變。
- 後果：§2.5「藍牙、權限、**金鑰** → 整個流程停、不問」與 D11 的理由（「金鑰壞了下一台也一樣會失敗」）落不到簽章路徑上；實作者照 §2.3 會做出「每一台都問繼續 / 停、每一台都失敗」。§2.3 和 §2.5 / D11 互相矛盾。
- 修法：§2.3 `keyError` 的觸發點加上 `sign` / `signAdmin` 的 `PlatformException`（舊碼 `_keyFail` 的兩處），同樣先呼叫 `keyErrorToRadio`；§6 第 3 步加「`signAdmin` 丟例外 → `keyError` 且停不問」與改壞對照。

### MINOR

**AD-m1 「寫入失敗」一詞同時指 GATT 寫入與紀錄寫入，§6 第 3 步的測試和 §2.3 對不上**
- §6 第 3 步：「寫入失敗 → `notSent`、`sessionAlive == false`」。但 (1) 紀錄寫入（`PersistNet`）失敗時，Rust `persist_failed` 回 `OwnerKind::Answer`「[REQ_FAIL] 建立網路沒有成功：…」並 `back_to_conn()`（owner.rs:1131-1155），舊碼不 drop session，所以是 `answer`、`sessionAlive` 為真；(2) GATT 寫入失敗時，建立 / 加入 / 送新密碼都帶 `unclear`，走 nodes.dart:545-551 的 `_unclearNow()`，`notSent` 還是 `unclear` 要看 `SendTrack.wrote`；確認 / 連線檢查走 :554 → :579-582，§2.3 自己寫成 `unclear`。
- 修法：把 §6 那條測試與 §9 v12 表的「寫入失敗」改寫成「建立 / 加入在任何東西寫出之前 GATT 寫入失敗」；另加「`PersistNet` 失敗 → `answer` 帶 Rust 句子、`persistedRel == null`」。

**AD-m2 送新密碼的「結果不明」：§2.3 說用 `_waitLine`，舊碼用的是 `_sendUnclear`；§2.5 的標籤「新密碼沒有送出」和句子相反**
- 證據：`_sendUpdateFor` 呼叫 `_ask(..., retry: false, unclear: _sendUnclear)`（nodes.dart:1580-1581），逾時 / 斷線回 `_track.unclearNow(_sendUnclear)` =「[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁」（nodes.dart:56）或 `notSentLine`，不是 `_waitLine`。同理 §2.3 的「`retry: false` 的請求遇到寫入錯誤 → :554」對送新密碼不成立（`unclear != null`，在 :545 就返回了）。
- 後果：結果不明時節點可能已經換了密碼，那一列卻寫「已加入，新密碼沒有送出」。
- 修法：§2.3 改成「送新密碼用 `_unclearNow()`（`_sendUnclear`）」；§2.5 的標籤依 `kind` 分成「沒有送出」（`notSent`、Rust `[REQ_FAIL] 沒有送出：…`）和「結果不明」（`unclear`）。另外 `_sendUpdateFor` 在 `_readRecord` 回 null 時直接 `_say` 返回（nodes.dart:1574-1577），沒有經過 `ask`，要寫明對到哪個 `kind`（`notSent`）。

**AD-m3 藍牙關閉時 GATT 斷線先到，「每次要問之前再看一次」擋不住之後才到的狀態事件**
- §2.5 / §6 要求「藍牙關時 GATT 斷線先到 → 不問直接停」，但如果 `statusStream` 的 poweredOff 在對話框已經打開之後才到，文字沒說要怎麼做；這個測試寫不出確定的結果。退路其實已經有了：使用者按「繼續」→ 下一台 `loginFor` → `precondition` → 停。
- 修法：二選一寫明——(a) 問題開著時 `core.blocked` 變成非 null → 當成「停」關掉對話框；或 (b) 承認可能先問一次，靠下一台的 `precondition` 停，§6 的測試改成「最多問一次、下一台不登入」。

**AD-m4 「當前請求 ≤ 360 s，在 420 s 內」不精確**
- 舊 `_kick` 每次寫到節點都重設等待（nodes.dart:493-499 與步驟迴圈的 `_kick()`），所以 360 s 是從**最後一次寫入**算起，總時間可能超過；另外 `pageGone` 之前已經過的時間也沒算進去（`goneMax` 是從 `pageGone` 起算，lease.dart:73-83）。超過時佔用被收回 → 第二次 `PersistNet` 被 `RecordWriter` 拒絕 → 紀錄停在 pending，方向是安全的（§2.2 已經這樣寫）。
- 修法：§2.5 改寫成「通常在 420 s 內；超過時佔用被收回、紀錄停在 pending → 檢查網路，首頁出現『上一個操作可能沒有存完』（lease.dart:143）」，§3.2「工作途中頁面消失」那一列一起改。

**AD-m5 從 3.5 / 3.6 進 4.1 時，剛認領的那台沒有被預勾**
- §2.5 的預勾只有「最近讀到 `node_state == 1`」與「從待辦或節點頁帶進來的」。剛認領完回到 3.5 / 3.6 時，這台多半還沒被讀到（釋放後 6 s 才開始一輪），4.1 會把它列成「還沒讀到、預設不勾」；之後讀到時要不要自動補勾也沒寫。
- 修法：3.5 / 3.6 把 `ClaimDone(id)` 的 id 當成「帶進來的那一台」傳給 4.1（同節點頁的做法）；並寫明預勾只在 4.1 第一次顯示時算，之後讀到的狀態只更新顯示。

**AD-m6 回到 4.1 的幾條路徑沒寫清楚**
- 4.1 自己的次要「建立網路」（§2.4）按下去做什麼，沒寫（推論是切到建立模式，同 §2.8 的「去建立」）。
- 檢查網路頁從 4.1 進來、回傳的不是「去建立」（例如升級後按「完成」）時，4.1 怎麼做也沒寫；§2.5 只定義了 `NetRunPage` 回來的值。推論是留在 4.1、靠 `NetIndex` 通知加上「開始」時的快照比對更新畫面。
- 修法：各補一句。

**AD-m7 迴圈裡「登入失敗」沒有先看 `lease.valid`**
- §2.5 問繼續 / 停之前只看 `core.blocked`、`precondition`、`keyError`；`leaseLost` 是 `ConsoleReply` 的 kind，`loginFor` 的結果裡沒有對應的值（§2.1 的 `refused` 在 gate `Refused` 時也會出現，ble_gate.dart:226-231）。目前只有 `pageGone` 的期限會收回佔用（lease.dart:81 是唯一的 `_revoke` 呼叫者），而那時頁面已經不在、不會問，所以實際上不會出事。
- 修法：§2.5 那一句改成「問之前先看 `core.blocked`、`!lease.valid`、`keyError`」，免得實作者在 `NoLease` / `Refused` 之後還開對話框。

## 驗證過的事實

✅ 已對原始碼核對：
- nodes.dart:50 `_makeUnclear` 以 `[NET_STATE] ` 開頭、:53 `_linkUnknown` 以 `[JOINED] ` 開頭，所以「只認 `kind == answer` 的開頭」是必要的（§2.3 寫對了）。
- nodes.dart:323-324 / :302 `answer` 與 `confirmRemoved` 都會補上 `[ANSWER] `；:525-526 `askNoLink`；:531 `_waitLine`；:545-566 重送分支；:571-572 drop；:668 `member:false, confirm:false`；:687-716 `_watchLink`、:709 `[CONNECTED]`；:1244 確認是 `retry:false`、沒有 `unclear`；:1580-1581 送新密碼帶 `_sendUnclear`。
- owner.rs:447 `[NET_MADE]`；:487-490 `[NET_STATE] `；:506 NotApplied；:513-517 `[JOINED] `；:589-590 link_text；:645-650 error_text；:991-994 `node_dac_hash`；:1131-1155 `persist_failed` 回 `Answer` 並 `back_to_conn()`；:1437-1439 `poll_link` 與 `send_update` 互斥。
- netrec.rs:395 pending 成員為 `Joining`；:509-537 `confirm` 只升級建立者。
- lease.dart:43-101（`hold` 在 `!valid` 時丟例外、`pageGone` 420 s、唯一的 `_revoke` 呼叫者在 :81）；lease.dart:123-128 第二個 `acquire` 回 null；node_link.dart:153-158；raw_use.dart:73-82；ble_gate.dart:226-231；app_link.dart:142-144；member_ui.dart:172、:294-310。

⚠️ 推論：
- (j) 再試 `joinNetwork` 對「已是成員但落後」的節點會再設 `send_update`：依據 owner.rs:1427-1439 的 `flow.node_behind()`，沒有追到 join2flow 內部。
- AD-m3 狀態事件可能晚於 GATT 斷線：依據 Android BLE 的一般行為，沒有在真機量過。
- 建立途中寫出 addr-read 訊框時 `SendTrack.wrote` 是否為真（決定 `notSent` / `unclear`），取決於該步的 `sent` 旗標，沒有逐步追。

❌ 沒有檢查：
- core.dart:186-201 `Page.node` 還原、prober.dart 行號（前幾輪已核對）。
- join2flow.rs:345-365 被入侵節點的分析（基準）。
- 沒有執行任何測試。

## 基準備註（不算發現）

- pending 紀錄裡建立者的成員狀態是 `Joining`（netrec.rs:395）。這是 join2 的資料模型，本 PR 只需要在待辦條件上避開它（AD-M1）。
- 建立者的節點如果被入侵，可以回「沒有套用」讓使用者再建一個網路（檢查網路頁 →「建立網路」）。這是 join2 已接受的行為，舊控制台的「建立網路」一直都在。
- 舊控制台在 `PersistNet` 失敗後不 drop session，`OwnerConsole` 在 GATT 寫入錯誤時 drop，比舊碼保守（§2.3 已寫明）。
