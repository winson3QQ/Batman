# #329 PR 3 實作計畫 v8 審查（審查者 O，獨立）

對象：`docs/design/329-pr3-plan.md` @ a55a08c（feat/329-pr3）。範圍照指示：只審 §0 列的新部分（4.1–4.5 / 3.x 畫面、`loginFor` + 交接 + `OwnerConsole`、多台迴圈、`NetIndex` 與首頁按鈕去處），以及新部分有沒有讓 join2 / 舊控制台的既有行為走樣。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 3 MAJOR / 5 MINOR）

v8 拿掉重新決定 join2 的部分，方向對；`loginFor`、交接、`OwnerConsole` 的接線、`NetIndex` 列檔規則都和原始碼對得上。但拿掉時連帶刪掉了幾條**關於新程式**、v7 已有的規則（§9 不是忠實的保留表），其中兩條讓新頁面在同一情境下和舊控制台 / 上層設計做的事不同。

## MAJOR

### M1　「檢查網路」頁與 pending 時的入口沒有規格；只剩 pending net 的手機在新頁面上走不到「檢查網路」也走不到「建立網路」

- 情境（§7 自己列的真機情境）：建立途中拔建立者的電 → app 重開。手機只有一筆 pending net。
- 證據：
  - 首頁第 6 列照 PR 2：任何 net 檔 → `NetRecords.net` → 「加入網路」（home_logic.dart:90-96、home_page.dart:131-134）。v8 §2.4 第 1 點說照它；第 3 點又說 pending 時「主要是『檢查網路』」——兩點互相矛盾，計畫沒寫按鈕從哪裡來。
  - v8 §2.6 的待辦只有「節點加入網路沒有做完」（joining）；v7 §2.7 的「建立網路沒有確認完」待辦被刪了。
  - 4.1 加入模式選到 pending → Rust `Refused(NotApplied)`「請先在建立網路的節點按『檢查網路』」（owner.rs:506）→ 新頁面沒有這顆按鈕的去處。
  - 檢查網路之後 Rust 說 `NotApplied`「可以再建立一次同一個網路」（owner.rs:478）；§2.4 說「使用者可以照它的話按『建立網路』」，但 §2.4 第 1 點只在「沒有 net」時給建立表單 → 新頁面沒有入口（舊控制台有，是 D3 以外的路）。
  - 「檢查網路頁」只出現在 §3.1 擁有權表；v7 §2.8 的整節（入口、對象節點怎麼決定、佔用）在 v8 沒有對應。`confirmNetwork(rel)` 要登入**哪一台**是新程式的問題（舊控制台是「目前登入的那台」，join2 沒有回答新頁面怎麼選）。
  - 結果頁的「檢查網路」若另開頁面另拿佔用，會撞到結果頁自己的 hold（v5 I-m2，同一類，v8 未保留）。
- 修法（不新增建立條件，只補接線）：
  1. 一小節「檢查網路」：入口 = 結果頁（**重用同一個佔用**，不另 `acquire`）、節點頁「網路」分組、首頁待辦「建立網路沒有確認完」（`NetIndex` 有 pending 時）。
  2. 對象 = pending 紀錄的建立者（`MemberView.creator` + §2.6 新加的 `deviceId`）；對不到 → 讓使用者從 `node/` 紀錄選。
  3. Rust 回 `NotApplied` 時，頁面照它的句子給「建立網路」→ 4.1 建立表單（和舊控制台同樣的行為；不加閘門）。§2.4 第 1 點改成「沒有 net 或只有 pending（照 Rust 句子）」，寫清楚第 6 列在只有 pending 時顯示什麼。
  4. 測試：只有 pending 的 `NetIndex` → 首頁出現「檢查網路」待辦；`NotApplied` → 4.1 建立表單可開；結果頁按「檢查網路」不出現「另一個操作還在進行」。各附改壞。

### M2　多台迴圈漏了 `_sendAfter`：已是舊版本成員的節點加入後不會送新密碼，和舊控制台不同

- 證據：Rust 在 `Applied && behind` 時設 `send_update`，同時 `poll_link = false`（owner.rs:1437-1439）。舊控制台 `_joinNetwork` 接著 `_sendUpdateFor(n.rel, member:false, confirm:false)`（nodes.dart:665-669）。上層設計 §5.4 表的最後一列也有「`_sendAfter`、連線檢查」。v7 §2.3 :226 有這一步；v8 §2.5 只寫「`[JOINED]` → 有 `pollLink` 時連線檢查」，§2.3 雖複製了 `sendUpdateFor`，迴圈沒有呼叫它。
- 情境：重新勾一台曾在網路裡、版本落後的節點（被移除後加回、維修回來）。回答是 `[JOINED]`，迴圈判成功；新密碼沒送，節點拿舊版本，連不上隊伍。
- 修法：§2.5 加入步驟寫成和 `_joinNetwork` 同一順序：（被移除過的問題）→ join →（`sendUpdate` 時）`sendUpdateFor(rel)` →（`pollLink` 時）連線檢查。測試：假 session 回 `sendUpdate=true` → 斷言 `request_send_update` 被呼叫一次；改壞 = 刪掉這一步 → FAIL。

### M3　和上層設計 §5.4 不同的兩點沒有寫進 §4，A18 也從真機清單消失

- 證據：上層設計 §5.4 :738「建立回來後紀錄不是已套用時：自動做一次『檢查網路』（A18 ⚠️ PR 3 對真機確認）」、:750「結果不明 → 下一步按鈕 = 檢查網路」。v8 §2.5 是「不是已建立 → 整個流程停」、加入不明 → 「再試這一台」。v7 把這寫成 D5 並把 A18 列進真機（v7 :394、:459）；v8 兩者都刪了。
- 為什麼是 MAJOR：行為照 Rust 句子（LATER = 「稍後在這台按『加入網路』」，owner.rs:498、:542-546）是合理的，但它就是和已凍結設計不同的地方，規則要求寫進 §4 並由真機確認 A18。不寫，實作者照上層設計做會多一次自動 confirm，審查也無從比對。
- 修法：§4 加回 D5（含理由與 `confirm` 只升級建立者），§7 加回 A18 量測。

## MINOR

1. **頁面消失的上限（v4 H-m3，v7 :239 有，v8 刪了）。** 加入 ≤360 s（每次寫入重計，nodes.dart:511-516）+ 登入 60 s + `sendUpdate` + 連線檢查 120 s 可超過 `goneMax` 420 s（lease.dart:96）。補回「頁面消失後不做 `sendUpdate` 與連線檢查、不開始新的登入」，並寫 `dispose` 時關 `keepScreenOn`（視窗旗標不計數，SwUpload.kt:77-81；只在結果頁關會漏掉頁面消失這條路）。
2. **`NetIndex` 的文字紀錄（v5 J-m8，v7 :250）。** v8 只寫「不含內容」；路徑含完整 net id。補回「只記種類與 net id 前 8 碼」，並加入原始碼 / 輸出斷言。
3. **建立者的選擇條件和 §0 自相矛盾、多台時誰是建立者沒寫（v4 H-m10）。** §0 說「不加自己的建立條件」，§2.5 又要求 `nodeState == 1`（home_logic.dart:31）。方向是 fail-closed，可以留，但要寫成「選擇過濾、和第 6 列同一個值」，並寫：多台符合時取哪一台（或讓使用者選）、沒有符合時 4.1 顯示什麼（剛認領完、還沒讀到的那幾秒）。
4. **迴圈怎麼知道新網路的 `rel`、以及逾時時寫入還在路上。** 「重讀紀錄是已建立」沒寫讀哪一筆；`OwnerConsole` 在 `persistNet` 時看得到 `p.rel`（nodes.dart:253-262），應由它回傳。`ask` 逾時時 `FrameInbox` 的處理者可能還在 seal / CAS（v4 G-m1 系列）：`close()` 要先等進行中的步驟結束（或確定它被 `lease`/session 擋下）再重讀、再 dispose session，否則可能 dispose 正在 `netPersisted` 的 session。方向是 fail-safe（判成沒建立 → 檢查網路），但要寫明順序並測。
5. **P8 證據不精確。** `[JOINED]` 不只在 `E::Applied`：`link_text` 的 `NotYet` / `Unknown` 也是 `[JOINED]`（owner.rs:589-590）。迴圈只能對 join 的回答判 `[JOINED]`，不能對連線檢查的回答判；照此改 P8 並在測試裡用連線檢查的句子當改壞。

## baseline notes（不算發現）

- 只有 pending net 時的出口（建立者壞掉）屬 join2 / PR 4，照 v8 不在此處理。

## §9 保留表是否忠實

不完全。關於新程式、v7 有而 v8 沒有對應的：v7 §2.8 檢查網路頁與 v5 I-m2（→ M1）、迴圈的 `sendUpdateFor`（→ M2）、D5 / A18（→ M3）、頁面消失 420 s（v4 H-m3 → m1）、`NetIndex` 紀錄遮罩（v5 J-m8 → m2）、建立者是哪一台（v4 H-m10 → m3）、逾時時的重讀時機（G-m1 / I-m3 / J-m1 / K-m2 / L-m1 → m4，形式改變但仍適用）。§9 列出的其餘項目對得上 v8 本文。

## 安全（新路徑）

- 沒有佔用：`loginFor` 先比對 `reg.current`；`GateLink._usable` 對撤銷的憑證丟 `Refused`（ble_gate.dart:84-86）；`RecordWriter._check` 拒絕（record_writer.dart:27-33）。fail-closed ✅。
- `LoginFor.result` 在 `!c.lease` 時丟掉結果（core.dart:692），交接後的 `Refused` 只在 `!lease.valid` 時算 `leaseLost` ✅。
- 惡意廣播：8 s msg2 + 20 s（prober.dart:37、:145 的同一套）✅；`loginOutcome` 不種「是 Y」（prober.dart:96-104）✅。
- 秘密：`OwnerConsole` 不寫回答內容 ✅；`NetIndex` 紀錄見 m2。

## 驗證分類

### ✅ 已驗證（原始碼，a55a08c）
- P2 / P5 / P6 / P10 / P11 / P12 引用位置與內容相符（ble_gate.dart:84-86、:185-231；prober.dart:96-104、:160-175；main.dart:87-88、home_page.dart:55-61；owner.rs:41-47 `list_kind` 濾 `.`、`unwrap_or_default`；ui_state.dart:131-138 `_save` 串列；swupdate.dart:137 + SwUpload.kt:77-81 `FLAG_KEEP_SCREEN_ON`）。
- P3：`setRadio` 把進行中的 `LoginFor` 結束成 `precondition`（core.dart:282-292）；`LoginFor` 60 s、6 s gap、N9 retry（core.dart:628-748）。
- P4：`_pump` 在 `core.running` 不是自己的嘗試時 `_abort()`；`nodeLinkToken` 佔用中為 null（node_link.dart `_pump`、lease.dart `nodeLinkToken`）。
- P8：`[NET_MADE]` owner.rs:447；`[JOINED]` owner.rs:514 **以及** :589-590；`Confirm::Upgraded` :487。
- `send_update = applied && behind`、`poll_link = Applied{country_unverified:false} && !behind`（owner.rs:1437-1439）；舊控制台 `_sendAfter → _sendUpdateFor`（nodes.dart:665-669）。
- `net_summary` 有 `m.device_id`（owner.rs:116），`MemberView` 目前沒有 `deviceId`。
- `request_make_network` 每次新建網路（owner.rs:1067-1089），pending 的 net 讓 PR 2 首頁給「加入網路」（home_page.dart:131-134）。
- v7 有、v8 刪的段落：`git show b49423f:docs/design/329-pr3-plan.md` 的 :226、:239、:250、:299、:394、:459。

### ⚠️ 推論
- `m.device_id` 和 `node/<id>` 的檔名同格式（owner.rs:1474 寫入的是 session 的 `device_id`，未追到 claim 端）。
- M2 的現場頻率（重新加入落後節點）未在真機確認。

### ❌ 沒做
- 沒跑任何測試或程式；沒逐條重驗 join2 / v1–v6 的發現。
