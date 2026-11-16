# #329 PR 3 實作計畫 v10 審查（審查者 T，獨立）

對象：`docs/design/329-pr3-plan.md` v10 @ 78a5177。範圍照指示：(1) v9 審查 Q、R 每一項在 v10 是否修好；(2) 佔用（lease）生命週期：多台迴圈、結果頁、檢查網路頁（從 4.1 / 節點頁 / 結果頁進來）、「放棄這次加入」、「建立網路」交到 4.1；檢查網路頁「一次登入、逐筆 confirm」對 owner.rs / netrec.rs；(3) 從現場情境出發。join2 / 舊控制台 / owner.rs 的既有行為是基準，疑問放「基準備註」，不算發現。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 1 MAJOR / 6 MINOR）

v10 把 v9 的兩個 MAJOR 方向都修對了（節點頁不放建立、檢查網路逐筆 confirm、登入失敗不給建立、誰 acquire 誰放）。剩下的 MAJOR 是這兩個修法**疊在一起**造成的死路：pending 的建立者節點不在了（壞了、被移除）時，新頁面上再也沒有「建立網路」。其餘是佔用機制的寫法（`pageGone` / `hold` / 借用的交接）要寫到實作者不會猜錯。

## 1. v9 發現的對應

| 發現 | 結果 | v10 位置 | 證據 / 說明 |
|---|---|---|---|
| Q-M1 節點頁「建立網路」沒條件、沒「檢查網路」 | ✅ | §2.4 節點頁、D6、§6 第 5 步 | 節點頁只有「加入網路」/「檢查網路」，照設計 329-app-uiux.md §5.5（「網路（加入網路 / 檢查網路 / 離開在『更多』）」）；測試列了「已建立 net + 未加入 → 沒有建立」「已在網路但紀錄 pending → 有檢查網路」 |
| Q-M2 多筆 pending、登入失敗也給建立 | ✅（§7 兩種情況 ⚠️） | §2.8、§6 第 5 步 | 逐筆 confirm 在同一 session 可行：`request_confirm_network` 只要 `St::Conn`（owner.rs:1168-1178），confirm 回答後 `asked=""` 留在 Conn（owner.rs:879-893），升級的寫入走 `persist_then` → `net_persisted` 後仍是 Conn（owner.rs:1107-1114）；節點端 read-only 動詞每連線 burst 20（feed/batman-prov/src/node/readonly.go:8、:24-25），幾筆 pending 不會被限速；對錯的紀錄只會 `NoChange` / `OtherVersion`（netrec.rs:509-520）。Q-M2 第 4 點「§7 記下 04 已套用 / 沒套用兩種」v10 §7 沒寫明。**但和 D6 疊起來產生 T-M1 的死路** |
| Q m1 `close()` 時進行中的步驟 | ✅ | §2.5 末條、§6 第 5 步 | Q 要求的「有上限」沒寫（見 T-m6） |
| Q m2 生命週期表 | ⚠️ | §3.2 | 不存在的 pending 待辦拿掉了、借用與交接兩列加了；檢查網路頁只有一列（T-R1），頁面消失 / 藍牙 / 返回鍵沒寫（T-m5） |
| Q m3 4.1 看選到的那一筆 | ✅ | §2.4 | `_pickNet` 標「已建立 / 建立中」對到 nodes.dart:614-619 |
| Q m4 送新密碼參數與失敗 | ✅ | §2.5 | `member: false, confirm: false` = nodes.dart:668；`send_update` 只在 applied && behind（owner.rs:1439） |
| Q m5 `NetIndex` 列不出來、只有 mnet | ✅ | §2.4 | |
| Q m6 紀錄行斷言 | ✅ | §6 第 4 步 | |
| Q m7 先選對象再拿佔用 | ✅ | §2.8 | |
| R-M1 兩個釋放者 | ⚠️ | §2.5、§2.8、§3.1、T-M1(h)(i) | 規則對（誰 acquire 誰放、借用不放）；但「借用的按建立網路 → 回結果頁由迴圈處理」沒寫怎麼回、「離開結果頁」沒定義、`pageGone` / `hold` 的用法沒寫，§3.2 還寫了結果頁有「建立網路」（§2.5 沒有）→ T-m1 |
| R m1 自動檢查和舊控制台不同 | ⚠️ | §2.5、D6 | 只在有 `rel` 時做 ✅；「同一個 session」在拔電（session 已結束）時做不到，要不要重新登入沒寫 → T-m2；R 要求的反向測試「沒有 PersistNet → confirm 0 次」§6 沒列 |
| R m2 `sendUpdateFor` 參數與結果 | ✅ | §2.5、§6 | 「沒有對話框」的斷言沒明列（nit） |
| R m3 對象比對 | ⚠️ | §2.8、§9 末表 | v10 說「精確的 dac hash 比對要新的 bridge 函式」——**登入後不用**：`OwnerSession.nodeDacHash()` 已有（owner.rs:991-996，dart src/rust/api/owner.dart:107），`MemberView.dacHash` / `creator` 已有（owner.rs:84-87、:114-119）→ T-m3 |
| R m4 放棄這次加入沒有佔用 / dev 排除 | ✅ | §2.4、D7 | 舊控制台同樣是讀完紀錄再 `_underLease` 寫（nodes.dart:1248、:1285-1291），CAS 擋過期 |
| R m5 同 Q m1 | ✅ | §2.5 | |
| R m6 頁面消失放 hold 的順序 | ✅（順序）/ ⚠️ | §2.5、T-M1(g) | 順序對；但沒寫 `pageGone()` 由誰在何時呼叫——只放 hold 不會釋放（lease.dart:64-69 要 `_gone`）→ T-m1 |
| R m7 同 Q m2 | ⚠️ | §3.2 | 同上 |
| R m8 節點頁建立不在 §4 | ✅ | D6 | |
| R m9 零碎 | ✅ | §2.4、§2.5、§6 | owner.rs:506 = `Pre::NotApplied` 句子 ✅；`Page.node` 連節點還原（core.dart:181-192 `startup` / `setPage` 帶 `node`）✅ |

## 2. 佔用生命週期（對原始碼）

已核對的機制：
- `pageGone()`：`_busy == 0` → 立刻 `release()`；否則設 `_gone`，420 s 後 `_revoke`（寫 `unsavedTodos`「上一個操作可能沒有存完」）（lease.dart:73-83、:140-148）。
- `hold()` 的取消函式：`_busy--`，只有 `_gone && !_ended` 時才 `release()`（lease.dart:64-69）。**沒呼叫過 `pageGone` 時放 hold 不會釋放。**
- `release()` 不看 `_busy`，直接 `_ended = true` 並通知（lease.dart:85-90）；之後放 hold 無作用。
- `RecordWriter` 要 `l.valid && identical(reg.current, l)`（record_writer.dart:27-33）→ 借用的佔用寫得進去 ✅；被放掉後寫入丟 `NoLease` ✅。
- `BleGate.connect` 同時只能一條連線，`GateLink.close()` 等堆疊回報或 5 s 才從 `_links` 移除（ble_gate.dart:107-129、:217-227）→ 結果頁「進來就 `close()`」後，借用的檢查網路頁才連得上 ✅。
- `released` 之後 `BleGate` 關掉該 token 剩下的掃描 / 連線（ble_gate.dart:247-253），`NodeLink` 重讀紀錄、6 s 後一輪（node_link.dart:171-195）✅。
- 讀紀錄不需要佔用（app_link.dart:61-65 `storeReadSealed` + `open`）→ 檢查網路頁在佔用下重讀單筆紀錄可行 ✅。

逐條路徑：

| 路徑 | v10 的寫法 | 判定 |
|---|---|---|
| 4.1 →「開始」→ 迴圈 acquire + hold → 結果頁 → 離開 | 迴圈唯一釋放者 | ✅ 規則；`hold` 何時放、離開時用 `release()` 還是 `pageGone()` 沒寫（T-m1） |
| 迴圈頁在等待中消失 | 等當前請求、`close()`、放 hold | ⚠️ 少了「先 `pageGone()`」；只放 hold 佔用永遠不釋放，`NodeLink` 停住到 app 重開 |
| 結果頁 → 檢查網路（借用）→ 返回 → 再試這一台 | 借用不放 | ✅ 規則（T-M1(h)）；要寫「借用頁不呼叫 `pageGone` / `release`」——`pageGone` 在 `_busy == 0` 時就是立刻釋放 |
| 結果頁 → 檢查網路（借用）→ 建立網路 → 4.1 | 「借用的就不放，回結果頁由迴圈處理」 | ⚠️ 若 4.1 被 push 在結果頁上面，結果頁沒被移除 → 佔用還在 → 4.1「開始」得到「另一個操作還在進行」。要寫成：檢查網路頁 pop 回一個值，結果頁釋放後用 replacement 開 4.1（T-m1） |
| 結果頁 / 借用檢查網路頁 → 升級 →「回首頁」 | 回首頁 | ⚠️ 同上，要經過結果頁的釋放 |
| 4.1 / 節點頁 → 檢查網路（自己 acquire）→ 離開 | 離開時放 | ✅；但 `acquire` 最多等 5 s 以上，期間頁面被關掉時要放掉（T-m4） |
| 4.1 →「放棄這次加入」短佔用 | 拿、寫、放 | ✅；同 T-m4 |
| 檢查網路頁（自己的）→ 建立網路 → 4.1 →「開始」 | 先放再開 4.1；`acquire` 等 `released` 讀紀錄段 | ✅（§2.1、T-M1(i)） |

## 3. MAJOR

### T-M1　pending 的建立者節點不在了（壞掉 / 被移除 / 永遠連不到）→ 新頁面沒有任何「建立網路」入口（死路）

- **情境（現場）**：隊長有 04、05。在 4.1 用 04 建立，途中拔電；04 之後開不了機（或使用者在節點頁把它「移除」，node_page.dart:62-88）。手機留下一筆 pending net。
  1. 首頁：05 未加入 → 第 6 列。`NetRecords.net` 只看有沒有 net 檔，pending 也算 → 主要「加入網路」、沒有次要建立（home_logic.dart:88-93）。3.5 / 3.6 同理（設計 §5.3：有 net → 3.6）。
  2. 4.1：選到的那筆是 pending → 只給「這個網路還沒確認建立完成」+「檢查網路」，「不在 4.1」給建立（v10 §2.4）。
  3. 檢查網路頁：04 的紀錄還在 → 名稱對到 04 → 登入失敗 → 只有「再檢查一次」（§2.8）。04 的紀錄已被移除 → 名稱對不上 → 使用者手選 05 → Rust 回 `NotApplied`（05 不在任何網路，owner.rs:478）→「對象是使用者自己選的」不給建立（§2.8）。
  4. 節點頁：不放建立（§2.4、D6）。
  → 新頁面上永遠建不了網路；field 版沒有舊控制台可退（§8、D3）。舊 pending 紀錄也沒有清除的方法（基準，Q / R 都記過）。
- **基準怎麼處理**：舊控制台「建立網路」一直都在（nodes.dart:1726-1731）；join2 §3.2 只是在 `NotApplied` 時說「可以再建立一次」，沒有禁止建立。v10 的 D6 是新頁面自己的限制；Q-M1 修法第 2 點原本給的條件是「手機**沒有已建立的 net**（全部 pending 或沒有）時出現次要建立」，v10 收得比 Q 要求的更緊，連這個也拿掉了。
- **修法（不加機制，照 Q-M1 第 2 點）**：4.1 選到的那筆 pending、**而且手機沒有任何已建立的 net** 時，在「檢查網路」下面加次要「建立網路」（這就是 P-M2 的缺口、舊控制台的行為）；D6 改寫這個條件。檢查網路頁的規則（登入失敗 / 手選 → 不給）可以保留，因為入口在 4.1 有了。
  - 另一種（二擇一）：檢查網路頁在手選時用 T-m3 的 `nodeDacHash` 判斷「這台不是建立者」，這時 Rust 對這台說的 `NotApplied` 是真的，給次要建立。但「04 還在紀錄、只是連不到」仍是死路，所以建議第一種。
- **測試**：只有一筆 pending、建立者的 `node/` 不存在 / 連不到 → 4.1 有次要「建立網路」→ 按下 → 4.1 建立表單可開始（改壞 = 拿掉 → FAIL）；有一筆已建立 + 一筆 pending → 沒有（保住 Q-M1）。

## 4. MINOR

**T-m1　佔用的實作規則寫清楚（R-M1 的剩餘）。** 依 lease.dart:60-90，計畫要寫明：
- 迴圈：acquire → `hold()`；進結果頁時放 hold；離開結果頁（route 被移除，dispose）時呼叫 `release()`（或 `pageGone()`，此時 `_busy == 0` 等同立刻釋放）。不要在 hold 還在時用 `pageGone()` 離開，否則 420 s 後 `_revoke` → 假的「上一個操作可能沒有存完」+ `NodeLink` 停 420 s（lease.dart:80-82、:140-148）。
- 迴圈頁在等待中消失：**先 `pageGone()`**，等當前請求（`lease.run` 內）結束、`close()`，**再**放 hold → 這時才真的釋放（lease.dart:64-69）。只放 hold 不會釋放。
- 借用的檢查網路頁：不呼叫 `pageGone()` / `release()`；它的出口（返回、「回首頁」、「建立網路」）都 pop 回一個值給結果頁，由結果頁決定：返回 → 留在結果頁；回首頁 / 建立網路 → 結果頁釋放後再 replacement 到首頁 / 4.1。
- §3.2「結果頁 / 檢查網路頁 → 建立網路」：§2.5 的結果頁沒有建立網路，改成「檢查網路頁（自己的 / 借用的）→ 建立網路」。
- 測試：T-M1(g) 斷言消失後 `reg.current == null`、`unsavedTodos` 空（改壞 = 不呼叫 `pageGone` → 佔用留著 → FAIL）；T-M1(i) 從**借用的**檢查網路頁按建立 → 4.1「開始」拿得到（改壞 = push 在結果頁上 → FAIL）。

**T-m2　自動檢查「同一個 session」在拔電時不成立。** §7 的主情境（建立途中拔電）裡連線已斷、`ask` 回 unclear / `ended`，session 不在了；`request_confirm_network` 在非 `St::Conn` 時回 `NOT_LOGGED_IN`（owner.rs:1174-1176）。寫明：session 還在 → 在同一個 session `confirmNetwork(rel)`；session 已結束 → 再 `loginFor` 一次（設計 §5.4 表的 60 s）後 confirm；登入失敗 → 停、結果頁「檢查網路」。補 R m1 要的反向測試（沒有 `PersistNet` → confirm 0 次）。

**T-m3　「建立者是這台」用登入後已有的值判斷，不需要新 bridge 函式。** 登入前選對象用名稱 `node-<last4>`（owner.rs:679、:1080）可以；登入後要逐筆 confirm 的清單應是 `m.creator && m.dacHash == session.nodeDacHash()`（owner.rs:84-87、:114-119、:991-996，都是現有的）。好處：手選錯台時清單是空的 → 直接說「這台不是建立這些網路的節點」，不送 confirm、不顯示 Rust 那句「可以再建立一次同一個網路」（R m3 的誤導就沒了）；被入侵的節點也只能被拿去 confirm 它自己是建立者的那幾筆。§9 末表 R m3 的理由（「要新的 bridge 函式」）要改。

**T-m4　acquire 之後頁面已不在 → 要放掉佔用（新頁面別照抄節點頁的寫法）。** `NodeLink.acquire` 會等 `_dropAll`（最多 5 s 以上，node_link.dart:153-164）。現有節點頁「移除」在 acquire 後 `if (!mounted) return;`，佔用就留著沒人放（node_page.dart:62-64）；`openRawPage` 有處理（raw_use.dart:75-78，review pr1 A-m4）。檢查網路頁（自己的）、「放棄這次加入」、迴圈的「開始」都要照 `openRawPage` 的做法：拿到後頁面已不在 → 立刻 `release()`。加一條測試（acquire 期間 pop → `reg.current == null`；改壞 = 照節點頁寫法 → FAIL）。

**T-m5　檢查網路頁的生命週期只有一列。** 它最多 60 s 登入 + 每筆 confirm，期間：返回鍵（有沒有 `PopScope`？）、頁面消失（自己的佔用：`pageGone` + 請求在 `lease.run` 內；借用的：只 `close()`，等進行中的升級寫入）、藍牙關 / 金鑰（停、不給建立）、切背景（沒有 `keepScreenOn`，照現況）各一列。方向都是 fail-safe（寫不進去 = 紀錄留 pending、下次再檢查），但要寫出來給實作與測試。

**T-m6　逐筆 confirm 的「升級就停」用什麼判斷；升級寫入失敗時也要停。**
- §2.8「`NetIndex` 重讀變成已建立」和 §2.6「`NetIndex` 只在啟動與 `released` 之後算」衝突（佔用中不算）。改成：這次 confirm 出現過 `PersistNet` 步驟（confirm 路徑上只有 `Confirm::Upgraded` 會產生，owner.rs:886-890）就停；或重讀**那一筆**紀錄的 `applied`（`storeReadSealed` + `netSummary`，不經 `NetIndex`）。
- 升級的寫入失敗（`persist_failed` → `[REQ_FAIL] …`，owner.rs:1154）時節點其實已在那個網路；若繼續檢查下一筆，會得到 `OtherNetwork`，然後「每一筆都有 Rust 回答、沒有升級」→ 給「建立網路」，誤導。規則改成「出現過 `PersistNet`（成功或失敗）就停，失敗時不給建立」。
- `close()` 等進行中的步驟要有上限（Q m1 原文），例如等 `writeCas` 至多 N 秒後照樣 dispose（結果 = pending，fail-safe）。

## 5. 現場情境走查（只讀原始碼，⚠️ 推論）

- **0 → 兩台網路**：新增 04、02 → 3.5 建立 → 4.1 勾兩台 → acquire + hold → 04 `makeNetwork` → PersistNet pending（owner.rs:1092-1093）→ `[NET_MADE]` + Applied 寫入 → 重讀已建立 → 02 `joinNetwork(rel)` → 國家對話框 → `[JOINED]` → `poll_link` 連線檢查 → 結果頁 → 離開釋放、`NetIndex` 重算。對得上。
- **建立途中拔電**：unclear → 有 `rel` → 重讀 pending → 自動檢查（T-m2：要重新登入）→ 04 還在開機 → 登入失敗 → 停 → 結果頁「檢查網路」（借用）→ 04 開機後再檢查 → 升級 / `NotApplied` → 建立網路（T-m1 的交接）。04 永遠回不來 → T-M1。
- **建立回來 `[NET_MADE]` 但 Applied 寫入失敗**：Rust 回「節點已套用，手機紀錄沒存好，請按檢查網路」（owner.rs:1142-1143），session 回到 Conn（`back_to_conn`）→ 自動檢查在同一 session 升級。
- **app 被殺**：04 已建立、02 加入到一半 → 待辦「節點加入網路沒有做完」→ 4.1 加入表單、02 預勾（pending 建立者沒有 device id，不會誤成待辦，owner.rs:116 / Q 已證）。
- **藍牙關**：`core.blocked` → 迴圈停、不問。檢查網路頁沒寫（T-m5）。
- **等待中關頁面**：`PopScope` 擋返回；被系統移除時見 T-m1（少 `pageGone`）。
- **選錯台**：4.1 建立選錯 = 使用者的選擇，照做；檢查網路手選錯台 → T-m3 讓它不誤導。

## 6. 安全（新部分）

- 本輪沒有新的輸入面。借用的佔用仍是同一個 token，`BleGate` / `RecordWriter` 的 fail-closed 不變（ble_gate.dart:175-180、record_writer.dart:27-33）。
- 被入侵的節點：逐筆 confirm 讓一台說謊的節點有機會把**它能說中 net_id + version 的**任一筆 pending 升級（netrec.rs:509-520 只看 key 10 / key 9）；T-m3 的 `creator && dacHash == nodeDacHash()` 把範圍限在它自己是建立者的那幾筆，比 v10 的名稱規則窄。confirm 不加成員（netrec.rs:503-505 註解），屬 join2 基準。
- 本機非特權程序：沒有新的平台方法或匯出元件；紀錄目錄在 app 私有路徑（app_link.dart:59）。不適用。

## 7. 基準備註（不算發現）

- `info-confirm` 回錯誤碼時走通用的 `Outcome::Err` 分支，`self.confirm` 沒有被清掉（owner.rs:964-967）；下一次 confirm 會覆寫，無害。
- 節點頁「移除」acquire 後頁面已不在 → 佔用沒人放（node_page.dart:62-64）：PR 2 的程式，不在本 PR 範圍；新頁面別照抄（T-m4）。
- 舊 pending 紀錄沒有清除方法（join2；T-M1 讓它更容易卡住）。
- `RecordWriter` 檢查佔用與寫入之間的空檔（PR 1）。

## 8. 驗證分類

### ✅ 已驗證（原始碼 @ 78a5177）
- lease.dart:42-90（`valid` / `run` / `hold` / `pageGone` / `release`）、:124-148（`acquire` 回 null、`_revoke` 寫 `unsavedTodos`）。
- record_writer.dart:27-33；ble_gate.dart:107-129（`close` 等斷線）、:175-180、:217-227、:240-253；node_link.dart:153-195；raw_use.dart:60-82；node_page.dart:62-88；app_link.dart:59-65。
- owner.rs:84-87、:106-122（`MemberView.dacHash` / `creator`）、:473-491（`join_state_text` / `confirm_text`）、:498、:506、:514、:531-535、:679、:879-893（info-confirm）、:964-967、:991-996（`node_dac_hash`）、:1080、:1094-1155（`net_persisted` / `persist_failed`）、:1168-1178（`request_confirm_network`）、:1436-1439（`poll_link` / `send_update`）、:1541-1563。
- netrec.rs:400-412（pending 建立者）、:495-536（`confirm`）；flow.rs:142-175（`JoinState`）。
- provd：server.go:564-590（info.net 失敗只丟 9/10/11）、node/readonly.go:8、:24-25（read-only 動詞限速）。
- nodes.dart:44-55、:194-300（`_tryLogin` / `run`，persist 在 `_underLease` 內）、:476-492、:614-619、:664-670、:1240-1291、:1726-1737。
- home_logic.dart:84-94（第 6 列：pending 也算 `NetRecords.net`）。
- 設計 329-app-uiux.md §5.1 待辦表、§5.4 表與條列、§5.5。

### ⚠️ 推論
- §5 的現場走查、T-M1 的死路、T-m1 的 420 s 假待辦：照原始碼與計畫文字推，沒有跑。
- T-m2「拔電時 session 已結束」：依 `_tryLogin` 的斷線處理（nodes.dart:197-200）與 owner.rs:1174-1176 推；`OwnerConsole` 尚未實作。
- 軟體更新頁與新頁面的 `keepScreenOn` 不重疊：只看到 swupdate.dart:137 與首頁經 `openRawPage` 開舊頁（home_page.dart:54-55），沒逐一確認軟體更新頁一定在佔用下。

### ❌ 沒做
- 沒跑測試、沒上真機；沒有重驗 v1–v8 的發現；沒看 provd 端「節點已在第一個網路時是否拒絕第二次建立」。
