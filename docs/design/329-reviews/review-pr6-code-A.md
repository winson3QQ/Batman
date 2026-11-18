# #329 PR 6 程式碼審查 A（`git diff c4905ed..HEAD`，HEAD 229490d）

審查者：A（獨立、對抗式；只看新／改的程式；基準 = 凍結設計 v12.1 + PR 1–5 已合併行為 + 計畫 v6 §11–§14）。
沒有碰手機、沒有改產品程式。負向對照都在**複本**上做（Dart：scratchpad `revA-nc/`；Rust：WSL `~/revA`，做完已刪），worktree 原樣。

## 結論

**0 BLOCKER / 0 MAJOR / 9 MINOR — APPROVE-WITH-CHANGES**（MINOR 都可以在 PR 內順手修或寫進 PR 說明）。

全隊資料路徑（prober `_afterRead` → `Outcome.team` → `NodeLink._run` → `teams`）、`core.result` 回 bool、`Page.team` 與 home↔team no-op、新鮮規則（`core.fresh` + `readAt` 相等）、U+001E/U+001F 規則（Rust / Dart 同一組向量）、國家閘門、D9 `heroTime`、文字紀錄的 `mask` / `note`、`orphanJoins` 都照計畫做，且我抽的 17 個 Dart 負向對照中 13 個對應測試會 FAIL（其餘 4 個見下面，屬多餘的防線或向量缺口，不是漏測產品行為）。

## 驗證紀錄

### ✅ 跑過
- Dart 全套（複本 `revA-nc`，內容與 worktree 的 `app/lib`、`app/test` 逐檔 `cmp` 相同）：`+1798 -4`。4 個 FAIL（`rekey_send_test` R14、`wording_test` T-C4a / T-C4b / T-C5）是**我的複本沒有複製 `rust/` 與 `android/`**（那幾條讀 `rust/bridge/src`、`android/app/src/main/AndroidManifest.xml`）。翻轉測試：同兩個檔在 worktree 跑 → `+15: All tests passed!`。
- 目標檔在 worktree：`core_team_test`、`node_link_team_test`、`prober_team_test`、`team_status_page_test`、`say_test`、`say_src_test` → `+61: All tests passed!`（連跑 3 次）。
- Rust（WSL Ubuntu-24.04，`CARGO_TARGET_DIR=$HOME/tgt-329pr6-ra`）：bridge `cargo test` → `86 passed`；batman-proto `--test say_scan` `3 passed`、`--test join2flow` `51 passed`、`--test joinflow` `9 passed`。
- FRB content hash 兩端一致：`frb_generated.dart:80` 與 `frb_generated.rs:47` 都是 `-1172584611`。

### ❓ 未歸因
- 我在 worktree 的**第一次**跑（同上 6 個檔）出現 `+59 -2`：`say_test.dart` 的「shared vectors」「joined sentences…」兩條 FAIL；當時沒拿到失敗內容。之後同指令連跑 3 次全過、單跑 `say_test` 也過。可能是另一位審查者同時在同一個 worktree 跑 `flutter test`（共用 `build/` 與 `.dart_tool`），但**沒有證據**，標 ❓。

### 負向對照（每條改一行 → 跑 → 還原，並 `diff` 確認還原）
| # | 改了什麼 | 結果 |
|---|---|---|
| NC1 | `node_link.dart` 拿掉 `accepted &&` | FAIL：「the record gone while its read runs…」 |
| NC2 | team 的 readAt 改用另一次 `now()` | FAIL：「positive end-to-end…」（§14 假時鐘每次前進有效） |
| NC3 | `_dropGoneTeams` 改成空函式 | FAIL：「node/<id> removed … its team goes」 |
| NC4 | prober 拿掉 `openNet` 之後的 `stop()` | FAIL：「cancelled after openNet started…」 |
| NC5 | prober 拿掉 `netReady()` 閘門 | FAIL：「§14 cold start…」 |
| NC6 | `wantTeam = teamEnabled() && wantHint` | FAIL：「field build / no node page…」 |
| NC7 | 拿掉 `&& !result.isCompleted` | **全過**（見 MINOR-6） |
| NC8 | home↔team no-op 關掉 | FAIL：「T6-13(e) … the round goes on」 |
| NC9 | 拿掉 `_round?.t.remove(id)` | **全過**（見 MINOR-6）；拿掉 `_round?.targets.remove(id)` → FAIL |
| NC10 | `splitCode` 巢狀 OPEN 改成「結束前一段、開新段」 | **全過**（見 MINOR-3） |
| NC11 | 單獨 CLOSE 改成忽略 | FAIL：shared vectors |
| NC12 | 沒結束的 OPEN 改成收進技術段 | FAIL：兩條 |
| NC13 | `setCountry` 閘門關掉 | FAIL：「T6-9: setCountry outside {US}…」 |
| NC14 | `orphanJoins` 改用 `todos` 的過濾 | FAIL：「T6-14 orphan joins…」 |
| NC15 | `logShown` 不經 `mask` | FAIL：「T6-12 text log every line masked…」 |
| NC16 | lease 收回不寫 `log` | FAIL：「T6-12 … a lease taken back…」 |
| NC17 | `heroTime` 非某台的列、有新鮮 → null | FAIL：pr6_dev T6-7 + pages_test r3 E-m3 |
| NC-R1 | Rust flow.rs:257 把 `\u{1E}代碼 {c}\u{1F}` 改回 `（代碼 {c}）` | FAIL：`d7a_1`（列出 flow.rs:257）+ `d7a_2_leave_text` |
| NC-R2 | Rust owner.rs:671 `error_text` 改回括號 | FAIL：`d7a_1`（列出 owner.rs:671）+ `d7a_2_owner_sentences` |

## 逐項追蹤（重點）

- **prober（D5(b)）**：`prober.dart:176-185`：只有 `hs != null && o.res == Res.body` 才算（row 2' 不算 ✔）；`Future.any([_afterRead(...).timeout(hintMax → null), cancelled → null])`，cancel 時 `cancelled.then(done(read))`（:128）先登記，所以結果是沒帶 team 的 `read` ✔。`_afterRead`（:274-314）：`teamEnabled()` 丟例外 → fail-closed ✔；每次 session 呼叫前 `stop()` ✔；`netId` 空 → NoNet 版本 ✔；`netReady()` false → null（§14）✔；`netKnown` false → `recordPlain: null` 版（NoList）✔；記錄打開後 hint 只在 `wanted`、team 只在 `teamEnabled` ✔；逾時後還在跑的 `_afterRead` 在 `openNet` 回來時 `stop()` 為真、什麼都不呼叫 ✔。
- **`_run`（D5(c)）**：`node_link.dart:631-646`：`!identical(_attempt, a)` → abort / 取消的一輪直接返回；`t = now()` 一次給 core 與 team ✔；`accepted && Res.body && TeamSeen && w != null` ✔。`core.result`（core.dart:449-512）在 record 已移除時回 false ✔。
- **移除**：`setRecords` 從進行中的一輪拿掉 id（core.dart:261-263）；`_dropGoneTeams` 在 start、release 兩條路 ✔。
- **home↔team**：`setPage`（core.dart:200-207）no-op ✔；`_pageTargets` 把 team 當 home ✔；`_eligible` 只看 `!= other` ✔；`HintSource.wanted` 只看 `Page.node` ✔。
- **背景**：`background` 設 `stale` → `core.fresh` false → TeamPage 整段 unk ✔（測試「back from the background」）。
- **標記**：Rust 與 Dart `split_code` / `splitCode` 規則一致、共用向量 ✔；`screenText` 先去 log marker 再切 ✔；`SayLine` / `StatusHero` / `BatBanner` 切開 ✔；logcat / 複製 / 文字紀錄用 `logText`（〔〕）✔；`goneNote` 傳整句、首頁 `BatBanner(text:)` 經 `SayLine` ✔。`main.dart` 舊啟動頁的 `Text(_report!)` 只在 `_ok && _app == null` 時出現，這時 `lines` 只有 Dart 中文句，沒有標記（例外那條 `sayErr(e)` 只在 `_ok == false` → `StatusHero` 那條路）✔。
- **`changed`（Y1 Stream.multi）+ teams（Y2）合併**：`node_link.dart:130-146` 每個 listener 自己一個底層訂閱、`addSync` 不多一跳，時序同 PR 5；`teams` 寫入後 `_pump()` → `_changed.add` ✔；TeamPage 訂閱 `changed` ✔。合併沒有打壞任一邊（兩邊的測試都在全套裡過）。
- **dev 頁**：SSH / 節點設定用 `OpSession.once`（session 佔用 + `loginFor`）✔；忘記加入中的節點用自己的 session lease + `RecordWriter`（`forgetJoining`）✔；入口看 `KeyAbilities`（`settings_page.dart` `_ownerNo`）✔；SSH 成功判定 `[SSH_DONE]`（owner.rs:1012）✔。
- **國家**：`allowedCountries = {'US'}`（owner_console.dart:62）、`setCountry` 先擋（:584）✔；國家頁只有 US、非 US 目前值經 `countryShown`（≤ 8、去控制字元）✔。
- **NodesPage 刪除**：`git grep NodesPage|StatusPageView|ControlsAndLog|ReadClock|NodeStatusList` 在 lib / test 沒有程式引用（只剩註解，見 MINOR-9）。`key_gate_test` 的 Kotlin signAdmin 拒絕那條已由 `owner_console_test.dart:384-403` 涵蓋；T30 在 `join_pages_test.dart:524`。

## 發現

### MINOR-1　§7「既有」對照表不在 repo / commit 裡
- 情境：計畫 §7 要求「刪掉的每一個測試……PR 附對照表，每條標『已有對應（檔:行）』或『移植到 X』」。94146c7 的 commit 訊息只有摘要（「deleted or ported」），`nodes_update_send_test.dart` 自己的 12 條（S3 / T-N2 ×4、r3 F-m9 / E-m9、PR3-1、E-MINOR-1、E-M1、T30 ×2、T19）、`member_ui_test` 的 T8 / S6 等沒有逐條的對應位置可查。
- 證據：`git show c4905ed:app/test/nodes_update_send_test.dart | grep testWidgets`（:464-630）；repo 內沒有對照表檔。
- 修法：PR 說明放逐條表（含 T19「commit 後到按鈕前不送」對應到 PR 4 的哪一條）。

### MINOR-2　Dart 原始碼掃描（D7a (3)）沒掃 `swupdate.dart`、`main.dart`、`scan.dart`
- 情境：`swupdate.dart:379-380` `Text(a.text)`、`Text(a.note)` 直接顯示 Rust 的 `Screen.text / note`。今天 swupd.rs 沒有任何 U+001E（`grep u{1E} batman-proto/src` 只有 flow.rs），所以**現在沒有洩漏**；但之後 swupd.rs 若把技術段包起來，這兩處會把控制字元原樣送上畫面，而 `say_src_test` 不會抓到（`_files()` 只有 `lib/ui`、`claim.dart`、`member_ui.dart`，say_src_test.dart:27-33）。
- 修法：把 `lib/swupdate.dart`、`lib/main.dart` 加進掃描範圍，命中的照現有允許清單寫理由（或 `swupdate` 改用 `SayLine`）。

### MINOR-3　共用向量測不到巢狀規則（NC10 全過）
- 情境：巢狀 OPEN 的實作（say.dart:37、say_scan.rs `(OPEN, Some(_))`）是對的，但唯一的巢狀向量 `外<<一<<二>>三>>尾` 在後面還有一個多出來的 CLOSE，所以就算巢狀 OPEN 被誤做成「結束前一段、開新段」，後面那個單獨 CLOSE 仍觸發整句保留，結果一樣。
- 證據：NC10（say.dart:37 改成 `parts.add(cur)` 後 `say_test` 7/7 過）。
- 修法：`split_vectors.txt` 加一行 `a<<b<<c>>d|abcd|`（只有一個 CLOSE 的巢狀）。

### MINOR-4　`readWall` 在 core 丟掉結果時仍被寫
- 情境：`node_link.dart:637` `if (o.res == Res.body) readWall[a.id] = wall();` 在 `accepted` 之前、不看它。PR 6 新增了「record 已移除 → `result` 回 false」這條路（core.dart:456-458），這時會替已移除的 id 寫一筆 `readWall`，之後沒人清（`_dropGoneTeams` 只清 `teams`）。今天不上畫面（`heroTime` 的 `infos` 來自 `states`），但 D9 現在會顯示 `readWall`，語意上「被丟掉的讀取」不該留時間。
- 修法：`if (accepted && o.res == Res.body) readWall[a.id] = wall();`，並在 `_dropGoneTeams` 一起清 `readWall`。

### MINOR-5　「排除這台」不再預先指定那一台
- 情境：舊控制台選「排除這台（換密碼）」時記下 `(net, m.dacHash)` 直接進那台的排除（`c4905ed:app/lib/nodes.dart:1283-1286` `_pendingExclude`）。新頁 `OrphanJoinsPage._exclude`（dev_pages.dart:381-395）開 `PersonPage(self)`，列出這支手機在該網路的**全部**節點，使用者要自己認出是哪一列（列上有後四碼與「加入中」）。若孤兒不在 `self.nodes`（例如 `deviceId` 空、或不是本手機群組的成員），頁面上找不到它，使用者沒有任何提示。
- 修法：`PersonPage` 收一個 `focus: dacHash`（只標示 / 置頂那一列），或在 `_exclude` 找不到對應列時給一句「這台不在你的節點清單，不能從這裡排除」。

### MINOR-6　兩道防線沒有負向對照能證明它們有用
- `prober.dart:184` `&& !result.isCompleted`：取消時 `Future.any` 已經回 null、逾時也回 null，這個條件目前到不了（NC7 全過）。
- `core.dart:263` `_round?.t.remove(id)`：`result` 已經用 `states[a.id] == null` 擋下、`tick` 只走 `targets`（NC9 全過；拿掉 `targets.remove` 才 FAIL）。
- 兩者都無害，但依「只做必要的修改」規則：拿掉，或在註解寫明它是防禦、沒有測試能觸發。

### MINOR-7　`OrphanJoinsPage._forget` 的非 String 例外丟掉技術資訊
- 情境：dev_pages.dart:419 `line = e is String ? e : '[REQ_FAIL] 忘記沒有成功';` — `NoLease`、`PlatformException` 等全部變成同一句，技術段是空的。D7 的規則是 Dart 組句時「只包非 String 的分支」（`sayErr`）。
- 修法：`line = '[REQ_FAIL] 忘記沒有成功${e is String ? '：$e' : tech(e.runtimeType)}'`（或 `sayErr`）。`_exclude` 的 catch（:393）同理。

### MINOR-8　診斷頁以後四碼當 map key，同後四碼的兩台會互蓋
- 情境：`diag_page.dart:37-46` `nodeTech` 回 `{last4(id): tech}`；兩台後四碼相同時只剩一台，畫面與複製內容都少一台。
- 修法：以完整 id 當 key、顯示時才取後四碼（或用 list of pairs）。

### MINOR-9　程式註解仍以 `nodes.dart:行號` 當依據
- 情境：`owner_console.dart` 約 20 處、`net_run.dart:115/:230`、`offline_op.dart:3/:92`、`net_index.dart:9`、`member_ui.dart:235/:306` 引用已刪除的 `nodes.dart` 行號。
- 修法：改成「the old console (main c4905ed, nodes.dart:…)」或拿掉行號，避免之後有人以為檔案還在。

## 附註（流程）
- 我把 Dart 複本一開始誤放到 scratchpad 既有的 `nc/` 目錄（裡面已有 `*.sed` 與另一份 app 複本，時間 10:04，應是主 session 的負向對照用），`tar` 以 HEAD 版本**覆蓋了 `nc/` 裡同名的 `lib/`、`test/` 等檔案**。之後改用自己的 `revA-nc/`。如果主 session 在 `nc/` 裡有尚未還原的改動，已被 HEAD 版本蓋掉，請重新確認。
