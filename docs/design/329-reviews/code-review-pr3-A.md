# #329 PR 3 程式碼審查 — CR-A（正確性：實作 vs 計畫 v18 與原始碼）

- 範圍：`git diff 9b00ca6^..a01379b -- app`（step 1 = 9b00ca6，steps 2–7 = aeeb941..a01379b），head a01379b。
- 基準（不重審）：docs/design/254-app-join2.md、舊控制台 nodes.dart / member_ui.dart、owner.rs / rekey.rs、batman-proto。基準的疑問放在最後「基準備註」。
- 方法：逐檔讀 lease / NodeLink.loginFor / prober / handoff / OwnerConsole / NetRun / CheckRun / NetIndex / net_pages / node_page / home_page / claim / app_link；對照計畫 §2.1–§2.9、§3.1–§3.2；在 repo 的**拷貝**（`C:/Users/yello/AppData/Local/Temp/cr329a`，a01379b）跑 30 個改壞對照與 1 個探針測試。repo 本身沒有改動（只新增本檔）。

**判定：APPROVE-WITH-CHANGES**（0 BLOCKER、1 MAJOR、6 MINOR）

---

## 發現

### MAJOR

**M-1 從節點頁開的「檢查網路」按「建立網路」什麼都不做（計畫 §2.8 :143 沒實作）**

- 情境：pending 網路的建立者是這一台 → 節點頁「檢查網路」→ 開始 → 每筆都拿到回答、沒升級、手機沒有已建立的 net、不是手選 → `offerMake` 為真，頁面給次要「建立網路」。使用者按下 → 頁面 `pop(goMake)` 回節點頁，**節點頁不看回傳值**，沒有開 4.1 建立模式。使用者看到的是「按了建立網路，又回到節點頁」。這正是計畫 v10 T-M1「pending 的建立者壞掉時的出口」之一。
- 證據：
  - 計畫 §2.8：「從節點頁進來（自己拿佔用）：`close()` → `pushReplacement(4.1 建立模式)`（本頁 dispose 時釋放）」。
  - `lib/ui/node_page.dart` `_network()`：`onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CheckNetPage(app: a, ui: widget.ui, preselect: widget.id, nets: pending)))` — 沒有 `await`、沒有處理回傳。
  - `lib/ui/net_pages.dart` CheckNetPage build：`if (r != null && r.offerMake) BatButton(Btn.makeNetwork, ..., onPressed: () => Navigator.of(context).pop(goMake))` — 只會 pop。
  - 只有 4.1（`_NetFormPageState._check`）與 NetRunPage（`_check`）處理 `goMake`。`test/ui/wiring_test.dart:124` 只驗開頁與 preselect，沒按「建立網路」；`net_pages_test` T-R1(a) 用的是測試 host，只斷言 `popped == goMake`。
- 修法：節點頁 `final r = await push<String>(CheckNetPage…)`；`r == goMake && mounted` → `push(NetFormPage(makes: true, ticked: {id}, back: Page.node, backNode: id))`（或照計畫在 CheckNetPage 加「從節點頁進來」旗標改用 `pushReplacement`）。佔用：CheckNetPage pop 時 dispose → `_own.pageGone()` 已立即釋放，4.1 拿得到（同 T-R1(a)）。
- 負對照：wiring test「節點頁 → 檢查網路 → 每筆回答、沒升級 → 建立網路 → 畫面是 4.1 建立模式、`reg.current == null`」；目前的程式會 FAIL（停在節點頁）。

### MINOR

**m-1 console 請求丟例外時，結果頁那一列永遠是「進行中」**

- 情境：`OwnerConsole` 的請求在送出前丟例外：`ConsolePlatform.readRecord` 的 `storeReadSealed` 回 `Err`（`owner.rs:34-39`，例如紀錄檔壞掉；app_link 只接 `open` 的 `PlatformException`）、`publicKeys` 的 `PlatformException`（Keystore）。例外穿出 `NetRun._make/_join` → `run()`；`_one` 的 finally 有 `close()`、hold 有放，所以**沒有洩漏**，但那一列停在 `RowState.running`，沒有「再試這一台」、`stopped == none`、沒有原因句；`NetRunPage._work` 的 `f().whenComplete(...)` 沒人接錯誤（未處理的非同步錯誤）。送新密碼那一步的 `readRecord` 丟例外時，已加入的那一列也停在「正在把新密碼送給節點」，而不是計畫 §2.9 的「已加入，新密碼沒有送出」。
- 證據（探針，拷貝裡的暫時測試，跑完已刪）：`World()` 不給 join 的回答（FakeConsole 丟 StateError）→
  `err=StateError running=false stopped=StopWhy.none rows=n1:running:"正在加入網路，這一步最多 6 分鐘" retry=false | n2:notDone:"" retry=false calls=[join n1, close n1]`
- 修法：`_one` 接住 `_make/_join` 的例外 → 那一列 `failed`、句子用舊 `_ask` 的 `'[REQ_FAIL] 操作沒有成功：$e'`（nodes.dart:579-582）；`PlatformException` → 照 D11 以 `keys` 停。CheckRun 同樣（`_go` 的 `run.run` 例外現在會讓頁面回到「開始」而沒有句子）。觸發罕見、方向 fail-closed（什麼都沒送），所以列 MINOR。

**m-2 頁面消失時 `linkCheck` 不會停（計畫 §2.9 AF m9 沒實作）**

- 證據：計畫 §2.9：「頁面消失時的 `linkCheck`：停（`OwnerConsole.close()` 會中止）」。`NetRun.pageGone()`（net_run.dart:117）只設 `_gone`；`_join` 只在 `[JOINED]` 之後看一次 `_stopNow`；`OwnerConsole.linkCheck()`（owner_console.dart:445）只看 `_closed`，而 `close()` 只由 `_one` 的 finally 在請求結束後呼叫。
- 影響：頁面消失後最多再 120 s 每 10 s 送一次 link check，hold 撐著佔用（< 420 s，不會被收回），`keepScreenOn(false)` 也延到結束；結果那一列是 linkCheck 的結果而不是「連線狀態未知」。
- 修法：`NetRun` 記住目前的 console，`pageGone()` 時 `unawaited(c.close())`（`close()` 已會 `_stopWait` 並把等待中的請求收成 unclear）。補一條測試：linkCheck 中 `pageGone` → 不再送 `link`、佔用在當下釋放。

**m-3 檢查網路頁消失時 CheckRun 不停（§3.2 T-R1(c) 沒實作、沒測試）**

- 證據：`CheckRun` 沒有 `pageGone`；`_CheckNetPageState.dispose` 只 `_own?.pageGone()`。系統關頁時（PopScope 擋得住返回鍵，擋不住系統），若正在 `loginFor`，登入成功後仍會 `confirmNetwork` 每一筆（計畫 §2.5「`pageGone` 之後不開新的登入…登入成功 → 直接 `close()`」，§3.2 T-R1(c)「同上一列」）。測試裡搜不到 T-R1(c)。
- 影響有界（登入 ≤ 60 s + 每筆 ≤ 15 s，寫入都經 `RecordWriter` 在佔用下）；但和計畫寫的生命週期不同。
- 修法：`CheckRun.pageGone()`；登入回來與每筆之間檢查；dispose 時呼叫。補 T-R1(c) 測試。

**m-4 改壞對照活下來的三個（測試擋不住它聲稱要擋的錯）**

| 改壞 | 結果 | 說明 |
|---|---|---|
| M03 `_loginFor` 拿掉「登入已結束時 `await h.close()`」（node_link.dart，handoff 回來但 60 s / precondition / 佔用已結束） | login_for_test 14/14 PASS | 程式碼是對的，但沒有測試讓 HandoffProber 在 `LoginFor` 已結束後才交出 session。佔用仍有效（precondition / 60 s）時，漏關會留下一條連線 → 同一佔用下一次 `loginFor` 卡在 `gate.links > 0` 直到 60 s。補一條：probe 在 tick 越過 60 s 之後才回 handoff → 斷言 `h.closed`、`gate.links == 0`。 |
| M19 `signOwner` 的 `PlatformException` 不呼叫 `_keyFail` | owner_console_test 28/28 PASS | 計畫 §6 第 3 步明寫「`sign` / `signAdmin` 的 `_keyFail` → keyError（改壞 = 只在 seal / open 設 → FAIL）」；只有 `signAdmin` 有測（M20 被抓到）。補 `signOwner` 一條。 |
| M21 `NodeLink.revoked` 不取消進行中的嘗試 | login_for_test PASS | 佔用被收回時閘門自己會關掉該 token 的連線（ble_gate.dart `revoked`），所以結果一樣，差在嘗試多撐到 8 s / 20 s。屬於多一層保護，不算缺陷；記錄在此。 |

另：v18 §2.9（AG-M1，計畫層沒再審）的兩段新碼**沒有任何測試走到**：`AppLink` 的 `ConsolePlatform.readRecord`（只接 `PlatformException` → `(gen, null)`）與 `flowDeps(...).applied` 的 try/catch → `false`。`grep -rn "flowDeps(" test/` 為空；net_pages_test 用自己的 `deps()`。邏輯我讀過是對的（見 ✅ 段），但沒有改壞對照。建議：用 mock MethodChannel 讓 `open` 丟 `PlatformException(code: 'keystore')`，斷言 `joinNetwork` 回 `notSent` + `recordUnopenedLine` 且 `keyError == false`、`applied` 回 false。

**m-5 4.1 加入模式下選到的那一筆不見了 → 默默放掉佔用、不說原因**

- `_start`：`if (!_makes && rel == null) { _pending = null; await l.release(); return; }` — 沒有 `_note`。使用者按「開始」沒有反應。觸發：佔用下重列時那一筆不在（但其他 key 一樣——實際上 `_key` 比對通常先擋下）。補一句「手機裡的網路紀錄剛剛變了…」即可。

**m-6 `CheckNetPage._pending` 是死欄位**

- 宣告與 dispose 都有，但從沒被設（`_go` 直接 `_own = l = got`）。不影響行為（`_own` 在 dispose 會 `pageGone`，與計畫一致），但註解「acquired, run not started yet」暗示有一條不存在的契約，易誤導下一位維護者。刪掉或照註解用起來。

---

## 逐項查核

### ✅ 已驗證（附證據）

**測試與分析器（原 repo，未改）**

```
flutter test --no-pub test/nodelink/login_for_test.dart test/nodelink/handoff_test.dart test/flows test/ui/net_pages_test.dart test/ui/add_pages_test.dart test/ui/wiring_test.dart test/nodes_update_send_test.dart
00:09 +136: All tests passed!
dart analyze lib test
   info - test\member_ui_test.dart:4:8 - The import of 'dart:typed_data' is unnecessary ... (不在本 PR 的 diff 內)
1 issue found.
```

**改壞對照（拷貝 cr329a，每個改完跑對應測試檔再還原；結束時 `git status --short` 為空）**：30 個，27 個被抓到。

| # | 改壞 | 抓到的測試 |
|---|---|---|
| M01 | `persistedRel` 在 CAS 之前設 | owner_console「a record write that fails…no persistedRel」等 2 條 |
| M02 | answer 文字加回 `[ANSWER] ` | 4 條（含 paths table、`[NET_MADE]`） |
| M04 | `acquire` 不等 `_releasing` | login_for「P7」 |
| M05 | 加入成功改成只看 `kind == answer` | net_run 4 條 |
| M06 | 送新密碼成功改成只看 `kind` | net_run 2 條（含 AF-M1 再試） |
| M07 | 檢查回答改成只看 `kind` | net_run「not start with [NET_STATE]」 |
| M08 | 4.1 dispose 不放 `_pending` | net_pages「v14 AB-M1」 |
| M09 | NetRunPage 不還 hold | net_pages T-M1(a)(b)/(c)/(g) |
| M10 | 借用的檢查頁也 `pageGone` | net_pages T-M1(h)/(i)（後一條是連帶失敗） |
| M11 | NetIndex 留舊的計算 | net_index「only the newest」 |
| M12 | 建立者也列成待辦 | net_index「v15 AD-M1」 |
| M13 | `close()` 不等進行中的步驟 | owner_console「close waits…」 |
| M14 | FrameInbox 丟掉暫存 | handoff 3 條 |
| M15 | 失敗的嘗試不關連線 | login_for「never two links」「60 s cut」 |
| M16 | `radio()` 不切登入 | login_for「Bluetooth off…precondition at once」 |
| M17 | `leaseLost` 不看佔用 | owner_console「lease taken back before the record write」 |
| M18 | page 消失後登入成功不關 | net_run「a login that ends after the page is gone」 |
| M20 | `signAdmin` 不設 keyError | owner_console「a key the gate refused while signing」 |
| M22 | 60 s 從等名額前開始算 | login_for「the 60 s start when the scan really starts」 |
| M23 | GATT 寫入失敗重送一次 | owner_console「one try only (no resend)」 |
| M24 | make 的 keyError 不停 | net_run「a key error on make: stop…」 |
| M25 | `offerMake` 不看 `anyApplied` | net_run「answered but the phone has an applied net」 |
| M26 | `_ask` 不在 `_chain` 之後重算 unclear | owner_console「v17 AH m1」 |
| M27 | 繼續/停對話框不因藍牙關而收 | net_pages「§2.9…」 |
| M28 | release 後不重算 NetIndex | net_index「a lease release computes again」 |
| M29 | 拿掉快照比對 | net_pages「§2.4 records changed」 |
| M30 | prober 在 loggedIn 不清處理者 | handoff「no frame is lost」 |
| M03 / M19 / M21 | 活下來 | 見 m-4 |

**程式碼對計畫（讀碼）**

1. 佔用生命週期
   - 4.1 `_pending`（net_pages.dart `_start` / `dispose`）：acquire 回來頁面不在 → release；比對中 dispose → dispose 放、`_start` 看到 `_pending == null` 就不再碰；快照不同 / 列不出來 → release；push 前清空。與 §2.5 / §3.1 一致；M08 證實有測。
   - NetRunPage：`_work` 拿 hold、`whenComplete` 還；dispose = `run.pageGone()` + `lease.pageGone()`（lease.dart:73-83：idle 立刻放、busy 等 hold）。結果頁「再試這一台」也走 `_work`。M09 證實。
   - 借用的 CheckNetPage 只 `hold()`/還，dispose 只碰 `_own`；NetRunPage 在 `_borrowed` 時 `PopScope(canPop: false)`；回來後自己在 hold 下重讀那一列（v14 AB m6）。M10 證實。
   - 自己拿的 CheckNetPage：先選節點再 acquire；回來頁面不在 → release；dispose → `pageGone`。
   - D9：acquire 被拒 → `_note` 顯示 `reg.current.name`，表單不動（測試 D9）。
2. `NodeLink.loginFor`（node_link.dart）：
   - 只接登記表目前的 session 佔用（`mine()`），一次一個（`_lfBusy`），`_lfGen` 擋舊掃描。
   - 60 s 從 `gate.scan` 回來（名額等待在 gate 裡）才 `core.loginFor(now())`（M22）。
   - 掃描被系統結束 → `ended` → `scanEndedRetry` 後重掃；`Refused` → `scanRetry`；結束時 `_lfStop` 停掃描、取消計時。
   - `radio()` → `_lfCut` 只在 `LoginFor` 已結束（setRadio 設 precondition，core.dart:280-293）時取消嘗試；`revoked` / `released` 取消並叫醒；`dispose` 取消並叫醒。
   - 每次嘗試：失敗先 `await link.close()`；handoff 但登入已結束 / 佔用不在 → `h.close()`；`result()` 對舊的 attempt 丟棄（core.dart `!identical(running, a) || !c.lease`）。
   - `acquire` 先等上一個 `released` 的讀紀錄段 ≤ 5 s（M04）。
3. HandoffProber / FrameInbox：FrameInbox 在 subscribe 之前建好；`loggedIn` 分支同步 `inbox.handle(null, null)` 再 `done(...)`；交出時不取消訂閱、不 dispose；沒交出時照舊清理；`LoginHandoff.close()` 冪等、每步獨立 try。OwnerConsole 建構時設處理者，暫存依序交出（M14、M30）。`GateLink.state` 是 broadcast（ble_gate.dart:63），第二個監聽者安全。
4. OwnerConsole vs 舊控制台（nodes.dart:205-342、:505-600、:476-490、:626-671、:687-716、:1240-1245、:1567-1582）：
   - 步驟迴圈的每個 kind 都有對應；`confirmCountry` 等使用者時取消計時、`wait` 之後 `_kick`；`ended` → `ReplyKind.ended` + `endedLine`、`sessionAlive false`。
   - `_ask`：沒 session → `notSent`/`askNoLink`；Rust `Err(String)` → `refused`；GATT/平台錯誤 → `unclear`/`notSent`（有 unclear 參數時走 `_track.unclearNow`）、`_session = null`；**不重送**（M23）。逾時 → `_kick` 計時 → unclear；`unclear/notSent` 等 `_chain` ≤ 10 s 再算（v17 AH m1，M26）。`leaseLost` 只由 `lease.valid` 決定（M17）。
   - `persistedRel`：只在 `lease.run(seal + writeCas)` 成功後、只對 `persistNet` 設（M01）；寫入失敗呼叫 `persistFailed`（`NoLease`/`StateError` → "no lease"）。
   - `keyError`：seal（persist catch）、sign、signAdmin、`makeNetworkRefusal` 都設（signOwner 沒測，m-4）。
   - `close()`：`_closed`、`_stopWait`、清處理者、把等待中的請求收成 unclear、等 `_chain` ≤ 10 s、再 `h.close()`（M13）。
   - `joinNetwork` 被排除過：問 `askRemoved`，取消 → `notSent` + 舊句；確定 → 重讀紀錄再送（測試表 ConfirmRemoved 兩列）。
5. NetRun / CheckRun（net_run.dart）：
   - 成功只看開頭：`[JOINED] `、`[UPDATED] `、`[CONNECTED]`、`[NET_STATE] `（M05–M07）；建立看 `persistedRel` + `deps.applied(rel)` 重讀。
   - 建立：沒 `persistedRel` → D12 整個停；keyError → 停、不重讀（M24）；沒 applied → 自動檢查一次，`sessionAlive`/`alive` 為假時先 close 再登入；仍不是 → 停，結果列只給「檢查網路」（`canCheck`）。
   - 加入：非 `[JOINED] ` → 問繼續/停（最後一台不問、再試不問）；`sendUpdate` 非 `[UPDATED] ` → 列附註依 kind；`pollLink` → `linkCheck`，未連上只是附註。
   - 問之前先看佔用 / blocked / keys（`_blockedStop`），對話框關成「停」時再判一次。
   - 結果列規則 = 設計 :750（`canRetry` / `canCheck`）；再試帶 `clearNotY: true`、照整段加入規則。
   - CheckRun：`listFailed || noneOpens` → unreadable；只對 `creator && dacHash == nodeDacHash()` 的 pending 送確認；`offerMake = answered && !anyApplied && !picked`（M25）。`nodeDacHash` 與 `MemberView.dac_hash` 都是 `hex_lower`（owner.rs:124、:998）。
6. v18 §2.9（AG-M1）在碼裡：`ConsolePlatform.readRecord` 只把 `open` 的 `PlatformException` 收成 `(gen, null)` → console 回 `notSent` + `recordUnopenedLine`，**不設** keyError（owner_console.dart `joinNetwork/confirmNetwork/sendUpdateFor`）；`flowDeps.applied` 任何例外 → `false`；NetIndex 打不開的一筆跳過並只記 net id 前 8 碼、全部打不開 → `noneOpens` → 4.1 T8 句 / CheckRun unreadable。`keyError` 只來自 seal / sign / signAdmin / `KeyUse.makeNetwork`。邏輯正確；但 AppLink 那兩段沒有測試（m-4）。
7. NetIndex：列檔濾 `.`、`PathNotFoundException` = 空、其他錯誤 = `listFailed`；只留最新一次（`_gen`，M11）；release 後以 microtask 重算（M28）；待辦 = `forgettable(joining, approved, creator)`（member_ui.dart:172）且 `deviceId` 在手機的 `node/` 裡（M12）。
8. 原始碼鎖：owner_console_test「source lock」掃 `lib/src/flows/`、`lib/ui/`（`ui_state.dart` 除外）不直接呼叫 `storeWriteCas/...`。

**安全角度**

- 本機無權限程序：新增的輸入只有 app 私有目錄下的紀錄檔名與內容（NetIndex 只讀、紀錄寫入全經 `RecordWriter` + 佔用）；沒有新的 IPC / port / exported 元件。
- 被入侵的節點：成功判斷全部用 Rust 回答的**開頭**（計畫 §2.8 owner.rs:645-650 的理由），結果頁不靠節點說的字串推斷「已建立」，建立一律重讀手機自己的紀錄；建立者比對用登入後驗證過的 DAC hash，不用節點可控的 `name`（`name` 只做預選）。節點在 `MemberView.device_id` 裡謊報別台的 id，最壞是首頁多一條「加入沒做完」待辦、「放棄這次加入」以該成員的 dacHash 忘記它自己——不影響其他節點。
- 紀錄行：OwnerConsole 只寫 rel 前 12 字元（`net/` + 8 碼）；NodeLink 的 trace 走 `mask`。

### ⚠️ 推論 / 部分

- 對話框在佔用被收回時收起：靠 `a.link.changed` 事件觸發後檢查 `!lease.valid`；收回後 NodeLink 的 `released` → 重讀紀錄 → 推測會發 `changed`，但我沒有跑「收回時對話框開著」的測試（只有藍牙關那條有測）。
- 理論上的掃描洩漏：`loginFor` 迴圈中背景啟動的重掃，若恰在 `_lfStop` 的 `await s?.stop()`（此時 `_lfScan` 為 null → 只是一個 microtask）期間完成，會被設成 `_lfScan` 而沒人停，直到佔用釋放時閘門的 `revoked` 收掉。需要 gate 的名額計時器剛好落在同一個 microtask 間隙，我判斷實際不會發生；只記錄，不列發現。
- `listKind`（Dart）只算 `File`，Rust `list_kind` 連目錄也算、讀不到時當空。正常資料夾內兩者相同；只在 `net/` 底下出現子目錄時不同（舊控制台會把它當一筆打不開的 net，新頁面忽略）。影響可忽略。

### ❌ 沒查 / 沒跑

- `cargo test`（owner.rs 的兩行 `device_id` 斷言）沒有跑。
- 真機（手機、節點）完全沒碰；所有結論來自讀碼與 Dart 單元 / widget 測試。
- `claim.dart` 只看了 PR 的改動（`_done`、`goneNote`、樣式）；`_claim/_find/_recover` 本身是基準，沒有重審。
- `add_pages.dart`、`home_page.dart` 的版面與文字只粗看，沒有逐列對設計 §5.3。

---

## 基準備註（不是發現）

- `loginFor` 的 `keysOk` 讀不到（`KeyAbilities.read` 平台錯誤回 `none`）會 `radio(keyOk: false)`，整個 app 顯示 2.4 直到重開——這是啟動檢查 / X26 既有的做法（main.dart `a.link.radio(keyOk: keys.login)`），PR 3 只是在每次登入前多做一次；一次暫時性的 channel 錯誤就會讓 2.4 黏住，值得在 X26 那邊想一下。
- 舊控制台在請求逾時後才到的回答仍會 `_say` 出來；OwnerConsole 直接丟掉（沒有畫面可顯示）。符合計畫「回 ConsoleReply、不寫回答內容」，記錄一下差異。
