# Review G — commit c15a92d (feat/329-pr5)

範圍：只審這個 commit 改的兩件事（7.1/7.3 改 push+pop、8.1 的「還有 N 位」改用 netRecipients）以及它可能弄壞的東西。基準（v16 計畫、已審過的舊行為）不重審。

## 我做了什麼（證據）

- 在 `C:/src/Batman-329pr5-rG`（`git worktree add … c15a92d --detach`）跑測試，做完已 `worktree remove --force`；原 worktree 沒動（`git status` 乾淨）。
- ✅ `flutter test test/ui/team_pages_test.dart` @ c15a92d：`+16: All tests passed!`
- ✅ 負對照：只把 `app/lib/ui/team_pages.dart` 換回 `c15a92d~1`，兩個新測試都失敗，各自為了對的原因：
  - count 測試：`Found 0 widgets with text "還有 1 位隊員沒交更新包"`
  - 導覽測試：`Found 0 widgets with key [<'person-OWNERBOB'>]`
  - 結果 `+14 -2: Some tests failed.`。兩個測試都是驅動畫面再斷言結果的黑箱測試，不是只檢查存在。
- ✅ 全套 `flutter test` @ c15a92d：`+1396: All tests passed!`
- ✅ 另外寫了探針測試（暫時的，已刪除），新舊兩版都跑：

| 探針 | c15a92d~1（舊） | c15a92d（新） |
|---|---|---|
| 7.3 按「複製文字」→「下一步」，在 7.4 時有沒有 R4 提醒 | `reminder=1` | `reminder=0` |
| 在 7.4 時 7.3 還掛在樹上嗎 | `codePageMounted=0` | `codePageMounted=1` |
| 在 7.4 時 FLAG_SECURE | `secureSets=[false]`（已關） | `secureSets=[]`（還開著） |
| 回到 8.1 時的提醒 | 1 | 1 |
| 「下一步」連按兩次（間隔 50 ms） | 1 個 RequestPage | 1 個 RequestPage |
| 連按後按一次返回 | 回到 8.1 | 回到 8.1 |
| 在 7.3 按系統返回 | 回到 8.1，InvitePage 0 | 回到 8.1，InvitePage 0 |
| 複製邀請碼 → 7.4 貼上申請（`platformCalls=[qrMatrix, copyCode, clearClip]`）→ 返回兩次到 8.1 | — | 8.1 顯示「剛才複製的碼還在剪貼簿」，可是剪貼簿已經被貼上清掉了 |

## 介面與假設（附證據）

- `PersonView.owner` 和 `RecipientView.owner` 都是 `hex_lower(&owner_pub)`（`rust/bridge/src/api/rekey.rs:80` 與 `:325`），`ticks.handed` 用的 key 也是同一個字串。所以 `_need.contains(p.owner)` 比的是同一種格式。✅
- `rekey::recipients`（`batman-proto/src/rekey.rs:401-430`）排除自己，只收 `known_of < cur` 的 owner。隊員在現在這一版被收進來的時候 `known == cur`，所以不在名單上，和 8.4 一致。✅
- `net_recipients` 有 `dev_gate()`（`rekey.rs:313`），`net_people` 沒有。8.1 只有 devTrust 版本進得去（`node_page.dart:144`、`team_hub.dart:2`），而 Dart 的 devTrust 是在啟動檢查確認和 Rust 的 `DEV_TRUST` 一致之後才設的（`main.dart:105,154`），所以 dev_gate 在這裡不會丟例外。✅
- `pop()` 收掉的是最上層的 route，不是「自己那一頁」。在這條鏈上只有 `Navigator.pop` 會讓 route 結束；整個 app 唯一的 `popUntil` 在 `more_pages.dart:110`，不會疊在這條鏈上；`removeRoute` 只在 `PersonPage`（`team_pages.dart:165`）。所以「回來時頂端不是預期那一頁」這件事目前不會發生。⚠️ 這是推論，依據是 grep 的結果。
- 其他入口：
  - `team_hub.dart:32`：PickNetPage 用 pushReplacement 換成 InvitePage，所以返回時回到 hub，行為和舊版一樣。
  - `team_hub.dart:33` 與 `team_pages.dart:139` 直接開 RequestPage，這次沒改到。
  - `log_pr5_test.dart:156` 與 `layout_test.dart:212-214` 仍然通過（全套綠）。
  - 舊 console `nodes.dart` 裡沒有引用這幾頁。

## 發現

### 1. MINOR — R4 的提醒從「離開 7.3 時」挪到「整條鏈結束、回到 8.1 時」；先在 7.4 貼上過，這句提醒就是錯的

- **情境**：隊長在 7.3「複製文字」，用訊息傳出去，按「下一步」。
  - 計畫 R4（`329-pr5-plan.md:177`）寫的是「離開這一頁時，如果複製過、又還沒按清除，用 SnackBar 提醒一次」。可是 7.3 現在還留在 stack 上（`maintainState`），`CodeView.dispose`（`code_view.dart:149-158`）要等到整條鏈退回 8.1 才會跑。
  - 在 7.4 收申請時，隊長用的是 dev 的「貼上文字」（PR 5 的頁面本來就只在 dev 版）。R4/P10 規定貼上一律 `clearClip()`，所以剪貼簿已經空了。回到 8.1 時卻跳出「剛才複製的碼還在剪貼簿」：提醒來晚了，而且內容是錯的。
- **證據**：上表的探針。舊版在 7.4 就顯示 `reminder=1`；新版在 7.4 是 `0`，`clearClip` 之後回到 8.1 才出現 `1`。
- **影響**：提醒錯的方向是「多提醒」（說剪貼簿裡還有、其實已經清了），不會外洩。但它違反 R4 寫明的時機，而且在隊長最需要清剪貼簿的時候（傳完邀請碼時）沒有提醒。
- **修法**：7.3 的「下一步」不要把自己留在 stack 上。InvitePage 改成擁有整條鏈：
  - InviteCodePage 的「下一步」做 `Navigator.of(context).pop(true)`；
  - InvitePage 寫成 `final next = await push<bool>(InviteCodePage…); if (next == true && mounted) await push(RequestPage…); if (mounted) pop();`。

  這樣 7.3 在進 7.4 前就被 dispose，R4 提醒照舊在離開 7.3 時出現，FLAG_SECURE 也照舊關掉；8.1 還是等整條鏈結束才重讀，所以第 1 點的修正保留。另外加一個回歸測試：「複製 → 下一步 → 7.4 上看得到提醒」，負對照就是目前這個 commit。

### 2. MINOR — 7.3 的 SecureScreen 一路留到鏈結束：7.4–7.7 的 FLAG_SECURE 沒關，邀請碼的 QR 留在一個看不見的 route 上

- **情境**：`SecureScreen._held` 是靜態計數（`secure_screen.dart:24-41`），7.3 沒被 dispose，所以在 7.4、7.5、7.6、7.7 這幾頁，旗標一直開著。
- **證據**：探針在 7.4 時 `secureSets=[]`（舊版是 `[false]`）。
- **影響**：方向是 fail-secure（不能截圖的頁面變多了）。掃描器是另一個 Activity（`QrScanActivity`），不受 MainActivity 視窗旗標影響，這點是推論。R3 說碼本身不是秘密，所以邀請碼多留在記憶體裡一段時間，不構成洩漏。不擋，但是和計畫「每個 QR 各自包一個 SecureScreen」原本的生命週期不一樣了。第 1 點的修法會一起把它恢復成原樣。

### 3. MINOR — 8.1 把 `netRecipients` 和 `netPeople` 綁在同一個 try 裡：recipients 失敗時，整張名單都不見

- **情境**：`team_pages.dart:92-101`。`rekey::recipients` 比 `net_people` 多讀 `rec.netcfg()`、`history()`、`known_of`（`rekey.rs:402-414`）。萬一 netcfg 解析失敗（`netcfg_of` 用 exact_keys 檢查，很嚴格，`netrec.rs:115-118`）而成員清單是好的：
  - 以前 8.1 照樣列出名單；
  - 現在只剩 `[REQ_FAIL] …`，隊長連 8.2 的移除都進不去。
- **影響**：在正常的紀錄上不會發生，因為同一份紀錄 R19 的 `net_summary` 也要讀 netcfg。所以這是 robustness 的問題，不是功能 bug。
- **修法（建議）**：`_need` 自己放一個 try。失敗時名單照樣顯示，計數退回「每位沒勾的隊員」（多算，fail-safe），或在 banner 上說「讀不到誰需要更新包」。

### 4. 沒有發現（列出來，表示有查過）

- 連按「下一步」：Navigator 在 push 時會取消正在進行的觸控，所以只會推一個 RequestPage（探針確認）。退一步說，就算推了兩個，按一次返回也是一路退回 8.1，不會留下孤兒頁。
- PopScope（R10）：push 之前 `_running` 已經設為 false（`team_pages.dart:217`），imperative 的 `pop()` 也不受 `canPop` 影響。7.5 ApprovePage 自己的 `PopScope(canPop: !_running)`（`:407-408`）會擋住系統返回，所以操作跑到一半時，鏈不會被拆掉。
- 頁面在等的時候被拆掉：兩個 continuation 都有 `mounted` / `context.mounted` 守著。
- 呼叫端在等回傳值嗎：`MembersPage._go` 只 await 不讀值（`:105-108`）；hub 的 `go` 不 await。
- AC-M1 / R19：8.1 在整條鏈結束時才 `_load`，版本號在鏈中間由 `nets` 的通知觸發重讀（`:65`），沒有退步。
- review C m7（8.3 移除後返回到名單）：PersonPage 的 `removeRoute` 這次沒改到，`team_pages_test` 的 C m7 測試照樣通過。
- 8.1 的計數和計畫 §2.7-1「還有沒勾的隊員」一致，現在和 8.4 的勾選範圍相同。
- hostile 隊員的申請：沒有任何新輸入面，`netRecipients` 讀的是本機簽過的紀錄。

## Verdict

**APPROVE-WITH-CHANGES**：0 BLOCKER / 0 MAJOR / 3 MINOR。

兩個宣稱的修正都成立，負對照也確認了。建議用 #1 的修法（InvitePage 擁有整條鏈，7.3 用 `pop(true)` 交棒）一次收掉 #1 和 #2，並補一個「7.4 上看得到 R4 提醒」的回歸測試；#3 可以順手做。
