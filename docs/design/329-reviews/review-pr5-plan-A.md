# #329 PR 5 計畫 v1 — 審查 A（與原始碼 / 基準一致性、現場行為）

審查對象：`docs/design/329-pr5-plan.md`（worktree `C:/src/Batman-329pr5`，main 2e18de6）。只審 §0「本 PR 新做的」1–9 與 §2–§7；基準（219 §7.4/§7.6、member-join v6.1、remove-member v6.5、254-app-qr、舊控制台函式、Rust 入口、PR 3/4 機制）只拿來對照搬移是否忠實。所有證據為本人以 Read/Grep 讀原始碼所得；未上機。

先核對的事實（都對）：§0 的舊函式行號（nodes.dart 798-812、815-864、867-878、881-910、926-954、957-999、1001-1037、1040-1062、1311-1344、1348-1421、1425-1448、1450-1499、1503-1542、1546-1582）與 P1–P14、P18 的引用都與原始碼相符。join2 的 `poll_link` / `send_update` 互斥（owner.rs:1477-1479），所以 NetRun 的 `if sendUpdate … else if pollLink`（net_run.dart:299-315）與舊 `_memberJoin` 的「送完再 `_watchLink`」行為相同 —— member 模式沿用 NetRun 是忠實的。

---

## MAJOR

### M1. 8.5「收新密碼」與隊長「送到我的節點」的入口綁在 `update_hint`，這個條件在現場永遠不成立

**情境**：隊長移除一個人 → 8.4 把更新包傳給隊員 B。B 打開 app，到自己節點的節點頁，想按 8.5 匯入。依計畫 2.6-14 / 2.7，8.5 的入口是「節點頁那一行（`update_hint` 有按鈕時）」。

兩個原因讓這一行不會出現：
1. **按鈕只在匯入之後才會亮**。`update_hint_of`（rekey.rs:466-499）對隊員：`!behind(m.version)` 時回空（:476-478）——只有手機的 mnet 版本**已經比節點新**才回 `button: true`。匯入前手機與節點同版，沒有任何一行。所以「匯入」這一步沒有入口；舊控制台的「貼上更新包」是獨立、常駐的按鈕（nodes.dart:1752），不靠 hint。
2. **節點頁沒有可以問 hint 的 session**。`update_hint` 讀的是「同一個 session 上次狀態頁的 info」（owner.rs:1099-1101，`page_info`）。節點頁的狀態是 NodeLink 的 Prober 讀的，讀完就 `s?.dispose()`（prober.dart:119-123、:193-197），node_page.dart 也沒有任何 OwnerConsole。計畫 2.7「用節點頁現有那一輪的 session；沒有那一輪時不顯示，不另外登入」等於永遠不顯示；而 2.3 又寫「session 沒讀過狀態頁時先 `statusPage`」——兩處互相矛盾。

隊長端同樣受影響：8.4 最後一列「把新密碼送到我的節點 → 節點頁的 8.5 那一行」也靠這個 hint。

**後果**：新 UI 裡換密碼走不完（隊員收不到、隊長自己的節點換不了）。PR 6 刪掉舊控制台以後就沒有路可走；PR 5 期間只能回舊控制台。

**修法**：
- 8.5 的「匯入更新包」入口不依賴 hint：devTrust 版本、手機有 mnet（隊員）時常駐（節點頁網路分組，或首頁 / 待辦）。匯入是不連節點的寫入（OfflineOp），本來就不需要 session。
- 「把新密碼送給節點」照舊控制台 `_sendUpdate`（nodes.dart:1546-1563）：在 `OpSession.once` 裡 `info()` → `infoNetId` → 讀 `net/`，沒有就讀 `mnet/` → `sendUpdateFor`。它本來就不靠 hint。
- hint 那一行如果要顯示，就在 8.5 頁進頁時的 `OpSession.once` 裡算（`statusPage` 之後在同一個 console 上 `updateHint`），不放在節點頁。
- 測試：widget 測試「有 mnet、沒有 hint → 8.5 匯入入口存在」，負對照是把入口接回 hint → FAIL。

### M2. 「隊員」入口綁在「這台節點在網路裡」：隊長排除自己最後一台之後，8.1 / 8.4 就進不去了

**情境**：隊長只有一台節點，它被抓了。remove-member 明定這時「可以排除自己最後一台」（254-app-remove-member.md:19、:151、:250），之後「網主手機仍保有紀錄，照樣產包」。隊長在節點頁 → 隊員 → 8.2 排除這台 → 8.3 commit → 8.4。commit 會把這台從 k11 刪掉（remove-member :81、:149）。之後計畫 2.6 的入口條件「這台在某個 net 紀錄裡已套用」就不成立了。

接下來兩件事都會發生：
- 隊長離開 8.4（或 app 被殺）以後，沒有任何頁面能回到 8.4 重新產生更新包。設計情境 6 的出路正是「更新包可以重新產生」（329-app-uiux.md:807）。
- 手機有 net 紀錄、但沒有任何 `node/` 紀錄時（例如節點從手機移除了），根本沒有入口。舊控制台的 `_members` / `_makeUpdates` 是用 `_pickNet` 選網路（nodes.dart:1313、:1452），不需要節點。

**後果**：緊急換密碼做到一半，更新包發不出去，留下的隊員全部斷線。

**修法**：入口改用網路紀錄判斷，不用節點：只要手機有已建立（applied）的 net 紀錄，devTrust 版本就給一個「隊員」入口。全隊頁要到 PR 6 才有，所以 PR 5 可以放在節點頁（這台節點在或曾在這個網路，包括 k14 / removed），並在開發者選項或首頁加一個用選網路進去的入口。另外加一個測試：排除最後一台之後，8.1 / 8.4 仍然進得去。

### M3. 「三種碼都有 QR」只量了最小的隊伍；隊伍換過一次密碼之後，同意碼會超過 QR 與掃描器的上限

**證據**：
- 同意碼包含整份 `members-sign1`（219-protocol.cddl:486-491）。每位成員約 0.29 KB（remove-member :34：16 人的成員清單約 4.6 KB）。
- 成員名單只在換版時重簽（remove-member :97），所以第一次移除之後，該版本的完整名單會跟著之後的每一張同意碼。
- 2082 個字元（≈1041 B）是測試向量，也就是名單只有一兩項時的大小。粗算：同意碼字元數 ≈ 2082 + 約 580 ×（換版時的成員數 − 1）。換版時的成員數到 4–5 人就超過 4096。

**現場後果**：
- 超過 4096：Kotlin `qrMatrix` 依計畫回錯誤，頁面顯示「請用複製文字」。這是 fail-safe，可以接受。但掃描器收到 > 4096 的文字會靜默丟掉、繼續掃（QrDecode.kt:18、:42），而且當面流程（7.1「請隊員掃」）的說明文字沒有寫要改走訊息。
- 2100–4096 字元：QR 是 v28–v40，R-8 只量到 v27（P15/P16），S20 掃不掃得到沒有證據。
- 計畫 3.2 的 `CodeInput.onText` 契約寫「≤ 4096」。若實作時把這個上限也套到「貼上文字」，大的同意碼與更新包（≤ 128 KiB，cddl:492）就貼不進來。舊 `PasteButton` 沒有長度上限（member_ui.dart:139-146）。

**修法**：
- T-Q1 加一組「16 人、換過版本」的同意碼向量，量出實際版本。
- `CodeView` 依長度或版本決定顯示：在實測過的上限（v27）以內才畫 QR，超過就照設計 :773 的規則「只留複製文字」，並寫一句「這張碼太大，請用訊息傳」。
- 契約寫明「貼上」路徑沒有長度上限，由 Rust 判斷。
- 掃描器收到超長文字時給一句提示，不要靜默。
- D1 改寫成「在多少字元以內有 QR」。

---

## MINOR

**m1. `joinreqLostLine` 沒有機制產生。** 計畫 2.3 寫「失去連線 → `joinreqLostLine`」，但 `OwnerConsole` 做不到：
- `_lost` 只在 `_unclear != null` 時結束請求（owner_console.dart:349-363）；
- `_run` 遇到 session 換掉時直接 return，不 complete（:258）。

舊程式是在 `gone()` 裡用 `_joinreqInFlight` 與 `_saved` 補上這一句（nodes.dart:220-224）。照現在的 `OwnerConsole`，joinreq 斷線後會等滿 15 s，回「15 秒內節點沒有回應（結果不明）」。修法：在 `OwnerConsole` 加明確的「lost line」鉤子，依 `_track` 是否已 persist 決定 saved；加測試，負對照是拿掉鉤子 → 回逾時句 → FAIL。

**m2. 同意與移除的 commit 要在佔用內重讀紀錄。** 舊 `_checkRequest` 在 onConfirm 時重讀（nodes.dart:844-846），`_remove` 在 commit 前重讀（:1404-1405）。計畫的 `OfflineOp('同意加入', approve)` / `('移除隊員', startRemove)` 沒寫這一步。CAS 會擋住過期的寫入（fail-closed），所以不會寫錯；但要寫明「work 內先 `readRecord` 再呼叫 Rust」，才是照搬。

**m3. `runNetOp` 抽出時要拿掉 UI。** 舊 `_runOp` / `_runRemove` 的 default 分支會：
- 把 hex 寫進剪貼簿；
- `await showDupNote(context)`，對話框開著時佔用一直不放（nodes.dart:788-791、:1441-1444）。

抽成 `runNetOp` 後，它只回 `(hex, detail, note)`。複製交給 `CodeView`，`showDupNote` 由頁面在佔用釋放之後顯示。7.10 的「換成新的網路紀錄嗎？」對話框也必須在 `OfflineOp` 外面。

**m4. 8.2 的「排除這台」只給自己那一組。** 計畫 8.2 寫「每台節點一行『排除這台』」。舊 `_members` 只對 `p.isSelf` 的節點提供（nodes.dart:1336-1338），設計也寫「只有網主自己的節點可以單台排除」（remove-member :32、:139）。Rust 會拒絕別人的節點，但 UI 不應該顯示這個按鈕。

**m5. `RemoveTicks` 用 owner 當鍵，不要用 fpr。** 舊 `_copied` 的鍵是 `p.owner`（完整 owner_pub hex，nodes.dart:1483、:1494；rekey.dart:217-219）。8 碼的 fpr 是顯示用的。

**m6. 匯入後 mpend 沒刪掉時，首頁待辦會說錯話。** 舊程式接受「刪 mpend 失敗無害」（nodes.dart:1027-1032）。但新的待辦「你的加入申請還在等隊長同意」會在已經有 `mnet/<同 id>` 時繼續出現。修法：同 id 已有 mnet 時不出這一列；T-H3 加這個案例。`NetIndex` 已經同時有 mpendIds 與 mnets，可以直接比。

**m7. 7.10 加入時用哪一台節點沒有寫。**
- 應該用 mnet 入口那一台（`MnetView.deviceLast4`，member.dart:253-259），用後四碼對回 `node/` id；對不上或對到兩台時要選。
- 用錯台時 Rust 會回 NotThisNode（owner.rs:585）。
- 7.8「沒加入任何網路的節點」的資料來源（NodeLink 讀到的 nodeState）可能是「不明」。這時是否列出要寫明；建議照舊列出，由 Rust / 節點拒絕。

**m8. 設不了 FLAG_SECURE 時的畫面。**
- 現在的 `SecureScreen` 會把整頁換成一句話（secure_screen.dart:42-46）。計畫要「不顯示 QR 但留複製文字」，需要給 `SecureScreen` 新參數（例如 fallback child），這是對 PR 3 機制的介面變更，要寫進計畫。
- 7.5 / 7.9 / 7.10 的確認碼也在 `SecureScreen` 裡。在這種手機上確認碼看不到，流程就卡住。要寫明這是接受的結果，或者讓確認碼在 fallback 裡照樣顯示（確認碼本身不是秘密）。

**m9. 8.4 / 8.5 的剪貼簿與掃描。**
- 8.4 的「複製更新包」直接寫剪貼簿，沒有走 `CodeView`。這樣就沒有「清除剪貼簿」，離開時也不會提醒，和其他碼不一致。
- 更新包沒有 QR，而且常常超過 4096 個字元。8.5 的 `CodeInput` 只放「貼上文字」就好，否則「掃描 QR」是一顆用不了的按鈕。

**m10. `memberJoin` 不必用 `value`。** `ConsoleReply` 已經有 `sendUpdate` / `pollLink`（owner_console.dart:96-99、:122），NetRun 也直接讀它們（net_run.dart:299-311）。計畫 2.3 的 `value = (sendUpdate, pollLink)` 是多出來的第二條管道，刪掉。

**m11. `OfflineOp` 與 `pageGone`。** 2.4 寫「頁面被關掉時照 `pageGone` 規則、最多 420 s」，但 `OfflineOp.run` 拿到佔用後一定在 finally 裡 release，從來不呼叫 `pageGone`。所以 420 s 那條不適用，矩陣那一列應寫「work 跑完就釋放」。另外要確保 work 裡沒有任何等使用者的步驟（見 m3），否則佔用沒有上限。

**m12. 搬移細節要列出。** `_takeUpdate` 的 `nodeRecords` 取自這支手機的所有 `node/` 紀錄（nodes.dart:1513-1519），`_requestJoin` 的 mpend 讀取（:884）也要在同一個佔用裡。計畫說「照搬」，但 2.6 沒寫，實作時容易漏。

**m13. 手機螢幕對手機掃描沒有量過。** R-8 是電腦螢幕（計畫 §7 已標 ⚠️）。`CodeView` 可以考慮顯示 QR 時把螢幕調到最亮。不擋 merge；真機場次能做時補一筆。

---

## 生命週期 / 擁有權檢查摘要

- 擁有權表（3.1）：紀錄由佔用者經 `RecordWriter` 寫入，沒有兩個寫入者。`RemoveTicks` 的兩個寫入點（8.3 清、8.4 勾）要都經 controller 的方法，建議寫明 controller 是唯一擁有者。
- 漏的路徑，已列為 M2 / m6：
  - 「隊長排除最後一台之後」（M2）；
  - 「匯入後、刪 mpend 之前 app 被殺」（m6）。
- 漏的資源：8.5 需要一個「狀態頁 session」，計畫沒有任何擁有者（M1）。
- 降版、field、相機路徑：同意計畫的結論。field 版本由三層 gate 擋住，Rust `dev_gate` 在 member.rs:17-23 與各入口（owner.rs:1255、:1284），已核對。

## 判定

MAJOR 3（M1、M2、M3），MINOR 13，BLOCKER 0。

**APPROVE-WITH-CHANGES**：三個 MAJOR 都只需改計畫的局部（入口條件、8.5 的流程、QR 尺寸門檻與契約），不必推翻架構。但依規則，MAJOR 修完後要整份再審一次。
