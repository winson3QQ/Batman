# Review H — commit c15a92d (feat/329-pr5)

審查範圍：只看這個 commit 改的東西（8.1 的計數改用 `netRecipients`；7.1→7.3、7.3→7.4 從 `pushReplacement` 改成 push 再 pop），以及它可能弄壞的地方。已經審過的舊行為當基準，不重審。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER / 0 MAJOR / 4 MINOR。兩個修正的根因都在原始碼裡核對過，兩個新測試都會被對應的突變打掉。四個 MINOR 都不擋合併，建議順手修 1、3，2、4 至少要寫進文件。

## 證據

### ✅ 已驗證

- 在 `C:/src/Batman-329pr5/app` 跑 `flutter test test/ui/team_pages_test.dart`，結果是 `+16: All tests passed!`。
- 在自己的 worktree（`c15a92d --detach`，跑完已移除）跑整套 `flutter test`，結果是 `+1396: All tests passed!`。
- 突變測試：一次改一處，跑 team_pages_test。
  - M1 拿掉 `_need.contains(p.owner)`：`a member 8.4 does not list ... is not counted [E]`。
  - M2 7.1 改回 `pushReplacement`、不 pop：`邀請 -> 下一步 -> back: 8.1 re-reads [E]`。
  - M3 7.3 改回 `pushReplacement`、不 pop：同一個測試 [E]。
  - M4 7.1 保留 push，只拿掉 pop：同一個測試 [E]。
  - M5 7.3 保留 push，只拿掉 pop：同一個測試 [E]。

  五個突變全部被打掉。
- 另外寫了一份測試（暫時放在 worktree 裡，跑完已刪），補 commit 沒有涵蓋的出口：

| 測試 | 這個 commit | 上一版（c15a92d^ 的 team_pages.dart） |
|---|---|---|
| H1 在 7.3 直接按返回 → 8.1 重讀 | PASS | **FAIL**（7.1 被取代時就重讀了，讀到舊名單） |
| H2 「下一步」快速點兩下 → 返回 | PASS（只疊一個 RequestPage，返回後停在 8.1，8.1 沒被多 pop） | PASS |
| H3 像 team_hub 那樣直接開 InvitePage（底下不是 8.1）→ 7.3 → 7.4 → 返回 | PASS（停在底下那頁，沒有多 pop） | PASS |
| H4 7.6「完成」→ 回 7.4；7.7「重新邀請」→ 回 7.4；再返回 → 8.1 重讀 | PASS | **FAIL** |
| H5 `netRecipients` 丟錯 | 名單 0 列、顯示 REQ_FAIL | 名單 1 列 |
| H6 在 7.3 複製後按「下一步」，7.4 上有沒有剪貼簿提醒 | 7.4 上 0 個，回 8.1 後 1 個 | 7.4 上 1 個 |

### Rust `rekey::recipients`（batman-proto/src/rekey.rs:401-433）實際列出誰

規則：key 11 裡、owner 不是隊長本人、而且**這個人任一筆**的 `known_of(x) < cur`。`known_of` 在沒有 key 10 時回 `最舊版本 − 1`（netrec.rs:423-427），所以一定算「落後」。

逐個情境判斷「8.1 只算 recipients」對不對：

| 情境 | `known` | 有沒有列出 | 需不需要更新包 | 8.1 算得對嗎 |
|---|---|---|---|---|
| 移除之後才被同意的隊員 | `Some(current)`（approve.rs:239，同意包裡就有目前的密碼） | 不列 | 不需要，同意包就夠 | ✅ |
| 版本不明（舊 app 寫回、沒有 key 10） | None → 最舊 − 1 | 列 | 需要 | ✅（偏向多算，安全的方向） |
| 被移除過、又被重新同意的人 | 舊的那筆已經被 keep_list 拿掉；新的那筆是 `Some(current)` | 不列 | 不需要 | ✅ |
| 一個人兩台節點，一台是移除後才加入的 | 另一台落後 | 列 | 需要 | ✅ |
| 移除前就同意、還沒匯入（old_approval） | 比 cur 小 | 列 | 需要 | ✅ |
| 移除後同意、對方還在加入中 | `Some(current)` | 不列 | 不需要：他拿到的是同意碼 | ✅ |
| 移除後同意的人，之後又移除了一次 | 比新的 cur 小 | 列 | 需要 | ✅ |

結論：我找不到「真正還需要更新包、卻被藏起來」的人。

- 只有 approve.rs:239 會寫 `known`。rekey 的 keep_list 不動它，產生更新包也不寫紀錄（rekey.rs 的 `ROp::Bundle(_) => None`）。
- 有勾選能力的只有 8.4，而 8.4 也只列 recipients（remove_pages.dart:286、:358-366）。所以舊的算法裡，「移除後才加入的人」永遠勾不到，橫幅永遠不會歸零。這個 commit 修的是一個真實的 bug。
- 兩邊的 owner 字串格式相同：net_people 用 `hex_lower(&m.owner_pub)`（rekey.rs:80），net_recipients 也是 `hex_lower(&x.owner_pub)`（:323）。

### 導覽

修正後的頁面堆疊是：8.1 `_go` await push(7.1) → 7.1 await push(7.3) → 7.3 await push(7.4) → 7.4 push(7.5) → 7.5 用 pushReplacement 換成 7.6 或 7.7。

- 7.6「完成」和 7.7「重新邀請」都 pop 回 7.4（team_pages.dart:432、:444），所以「一張邀請收多份申請」還能做（H4）。
- 7.4 返回時連鎖 pop：7.3 → 7.1 → 8.1 `_load`。終點和舊版一樣，差別是重讀時機正確了。
- 在 7.1 執行 OfflineOp 時，PopScope 的 `canPop: !_running` 擋住返回；`_running` 在 push 之前就設回 false（:217）。OfflineUnknown、Busy、Failed 都不 push，只顯示一行字。這些都沒變。
- 其他入口：
  - team_hub.dart:32-33：PickNet 用 pushReplacement 開 7.1 或 7.4，結束後回到 hub（H3 驗過）。
  - 舊控制台（nodes.dart:1751-1758）用的是自己的 `_makeInvite`，不經過這些頁面。
  - 整個 lib/ 裡唯一的 popUntil 在 more_pages.dart:110，那一頁不會疊在這條鏈上面。

  沒有發現多 pop 或少 pop。

### F-m8

計畫第 310 行寫的是「`removedThisRun` 為真、還有沒勾的隊員時」。「勾」只存在 8.4，而 8.4 只列 recipients，所以新的算法是這句話唯一能做到的意思。`removedThisRun` 的接法沒有改。

## Findings

### MINOR-1　`netRecipients` 失敗時，8.1 整份名單都不見

- **情境：** 紀錄的 netcfg 或 history（key 13）解不開，但 members 解得開。舊版 8.1 只呼叫 `netPeople`（只讀 members），名單照樣顯示，隊長還能進 8.2 移除人。新版兩個呼叫放在同一個 try 裡（team_pages.dart:92-99），`netRecipients` 一丟錯，`_people` 就留在 null，畫面只剩 `[REQ_FAIL] …`。
- **證據：** H5 在這個 commit 是「person rows: 0; REQ_FAIL: 1」，上一版是「person rows: 1; REQ_FAIL: 0」。`recipients` 會多讀 `rec.netcfg()?` 和 `rec.history()?`（rekey.rs:402-403、netrec.rs:426）。
- **影響：** 只在紀錄部分損壞時出現（8.4 在同樣情況下本來就壞）。不算資安問題，但為了一個提示橫幅，把主要的名單功能也一起拖垮了。
- **修法：** `netRecipients` 放進自己的 try。失敗時名單照常顯示，`_need` 改成「全部非本人」，也就是退回舊的算法，寧可多提醒。再加一個像 H5 的測試。

### MINOR-2　7.3 留在堆疊上，剪貼簿提醒（R4）延後了

- **情境：** 遠端邀請時，隊長在 7.3 按「複製文字」，再按「下一步：收隊員的申請」。舊版 7.3 被換掉時就 dispose，7.4 上立刻出現「剛才複製的碼還在剪貼簿」。新版 7.3 一直留在堆疊上，提醒要等整條鏈結束、回到 8.1 才出現，那時可能已經過了很久。
- **證據：** H6 在這個 commit是「7.4 上 0 個 / 回 8.1 後 1 個」，上一版是「7.4 上 1 個」。程式在 code_view.dart:149-158（提醒只在 dispose 時發）。
- **附帶影響：** 7.3 的 `SecureScreen` 一直被持有（secure_screen.dart 的 `_held` 引用計數不歸零），所以 7.4、7.5、7.6 全程都開著 FLAG_SECURE。這是偏安全的副作用，可以接受。邀請碼明文會在記憶體多留一段時間，但 Dart 字串本來就無法清除，影響可以忽略。
- **緩解因素：** 7.4 用「貼上」收申請時，本來就會把剪貼簿換成申請內容，而且貼完一律清掉（R4）。實際風險低。
- **修法（二選一）：**
  - 在 7.3 的「下一步」push 之前，如果已複製而且沒清，先發一次提醒；
  - 或者在計畫的 R4 或 2.7 第 3 點註明「7.3 留在堆疊上，提醒在整條鏈結束時才出現」，當成已接受的行為。

### MINOR-3　連鎖 pop 用的是 `Navigator.pop()`，pop 的是「最上面那頁」，不一定是自己

- **情境：** 7.1（:223）和 7.3（:259）在 await 結束後呼叫 `Navigator.of(context).pop()`，它 pop 的是整個 Navigator 最上面的 route。
  - 目前的程式沒問題：7.3 和 7.4 只會被 pop 結束，結束時自己就在最上面。
  - 但只要哪天有路徑用 replace 或 remove 把 7.3、7.4 拿掉，或者在上面疊了別的 route，這個 pop 就會多 pop 一頁。
  - 突變 M3 就是例子：7.3 改用 pushReplacement 之後，7.1 的 await 立刻結束，把剛 push 的 7.4 pop 掉了。
  - 另外，`mounted` 和 `context.mounted` 在自己的退場動畫期間仍然是 true，所以不能拿它們來判斷「我還在最上面」。
- **證據：** team_pages.dart:223、:259。PersonPage 已經有比較穩的寫法：記下自己的 route，`isActive` 才 `removeRoute`（team_pages.dart:159-165）。add_pages.dart:58-62 用的是同一種寫法，所以這是和既有程式一致的取捨。
- **修法：** 先記 `final route = ModalRoute.of(context);`，await 之後寫成 `if (route != null && route.isActive) Navigator.of(context).removeRoute(route);`，或者只在 `route.isCurrent` 時 pop。現有的測試全部照樣適用。

### MINOR-4　文件和回歸測試的涵蓋面

- 計畫 §2.7 第 1 點（第 310 行）和 F-m8 還寫著「還有沒勾的隊員」。建議改成「8.4 列出的（`netRecipients`）、還沒勾的隊員；移除後才被同意的人不算」，並把 2026-11-17 實機的發現記進計畫的修訂紀錄。
- 新的導覽測試只走「不在旁邊 → 下一步 → 在 7.4 返回」。H1（在 7.3 直接返回）和 H4（完成、重新邀請之後再返回）也都能把舊版打成 FAIL，建議至少補 H1 進 team_pages_test。

## 和本 commit 無關、但順帶看到的（舊行為，不列為 finding）

- `RequestPage._got`（team_pages.dart:283-298）在 `await readRecord` 之後用 `mounted` 擋。如果使用者在讀取期間按返回，頁面在退場動畫中仍然是 mounted，之後的 askYesNo 或 push(7.5) 可能疊到 8.1 上面。這是舊行為，這個 commit 沒有改變它發生的機率。要不要處理，由作者決定。

## 資安（逐個 actor）

- **惡意隊員的申請：** 7.4、7.5 的檢查（`netCheckJoinreq`、SAS、`previous` 對話框）都沒動。8.1 的計數只是提示，不參與任何判斷（T15、T-R1）。
- **惡意隊員能不能讓自己不被列入 recipients：** `known` 只由隊長端的 approve 寫入（approve.rs:239），值是當下的版本。隊員沒辦法寫隊長的紀錄。
- **畫面和剪貼簿上的秘密：** 見 MINOR-2。7.3 被蓋住時是 offstage，不會被繪製；FLAG_SECURE 反而開得更久。
- **本機其他程式：** 沒有新的輸入面。

## ❌ 沒做

- 沒碰手機或節點。
- 沒跑 Rust 測試：這個 commit 沒改 Rust，`recipients` 的行為是從原始碼和既有的 tests/rekey.rs t3、t10 讀出來的。
