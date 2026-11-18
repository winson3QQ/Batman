# #329 PR 6 計畫 v6 — 第六輪獨立審查（L）

審查對象：`docs/design/329-pr6-plan.md` v6（整份），worktree `C:/src/Batman-329pr6` @ c4905ed。只讀原始碼核對、沒有上機（只做了一個唯讀的本機查詢：`netsh interface ipv6 show interfaces`）。基準（設計 v12.1、PR 1–5、#349、254 v2.4）不重審；全隊頁照設計做完整版是使用者的決定，這裡只審做法。

## 前輪 MAJOR 是否解掉

| 前輪 | 狀態 | 本輪核對 |
|---|---|---|
| I-M1 / J-M1 team `readAt` 時序 | ✅（剩 MINOR-1 / MINOR-2 是實作細節） | v6 D5(b)(c)：team 跟著 `Outcome.team` 回去，只有 `NodeLink._run` 會寫入。原始碼確認了這條路走得通：(1) prober 的 hint 在 `done(o)` 之前跑（prober.dart:155-167），所以 `Outcome` 可以帶著 team 一起回去；(2) 取消時 prober 送出的是 `read ?? noResponse`（prober.dart:113），也就是沒有 team 的那個 `Outcome`，而且只有 `_abort` 會觸發取消（node_link.dart:588-597）；`_abort` 之後 `_run` 在 :579 就 return，不會寫入；(3) `readAt` 只在 core.dart:489（`_read`）與 :560（2'）寫入：2' 會改 `readAt` 但沒有 team，所以那一段自然變舊；(4) `background()` 會把每台設成 stale（core.dart:203-205），`core.fresh` 就是 false（:156-158），整段變 unk；(5) `TeamView` 是普通的 struct（owner.rs:371-381），session dispose 之後在 Dart 端仍然可以用。T6-13(b) 已有正向測試，負向對照兩條：「prober 用自己的 `now()`」與「套用被取消那一輪的 team」。 |
| A–H 各 MAJOR | ✅ | 第五輪 I / J 已經核過一次。本輪重新抽查了下面幾項，都屬實：`ssh_keys/set` 是整組取代，重送同一組是等冪的（node.go:839-879：`added` 會先去掉上一組，再接上這一組）；`setCountry` 只有 settings_pages.dart:318 一個 UI 呼叫者，加上 nodes.dart（會被刪掉）；`OpSession.once` 存在（op_session.dart:89）；`HintSource.wanted` 只在 devTrust 而且在節點頁時為真（app_link.dart:126-130），所以 D5(a) 把 team 的計算和 `wanted` 分開是必要的；第 2 步 SSH 用的 `%15` 是「乙太網路」（netsh：Idx 15 = 乙太網路；Wi-Fi 是 5），J MINOR-8 的前提成立。 |
| 第五輪 MINOR | ✅（除了 MINOR-5） | 2 s 逾時 → `Outcome.team` 為 null；巢狀標記規則；Dart 只包非 String 的分支；共用測試向量；team 用自己的 `readWall`；T6-13(c) 不看 netId；國家字串經 `display_name`；`orphanJoins` fail-closed；dev3 `DEV_TRUST`；第 5 步備案；對話框用 `SayLine`。都已寫進計畫。D5(d) 那句重複的句子還在（MINOR-5）。 |

## 從實際使用出發的整份檢查（本輪新看）

- **N+1 打開時一輪的路徑**：首頁（`Page.home`）→ 對每台做 `_run` → 讀到本體 → 在同一個 session 裡 `openNet`（2 s 內）→ `teamView` → `Outcome(body, color, StatusView, team)` → `core.result(t)` → `readWall` → `teams[id]`。接著換到 TeamPage，home ↔ team 是 no-op，不會中斷正在進行的那一輪。中途 flow 拿到佔用：`acquireLease` → `_cancel` → `_pump` 呼叫 `_abort` → 這一輪丟掉、不寫 team。切到背景：stale → 整段 unk。這幾條路徑本輪都對過原始碼，都正確。
- **被入侵的節點**：每台一段，影響不到別台那一段。節點送來的字串在 `teamView` 經 `shown`，國家字串經 `display_name`，設定經 `shown`，`{v}` 經 `shown`。它能做的是讓自己那一段停在「沒有名單」或其他句子；修好 readAt 之後，被丟掉的那一輪不會被當成新鮮的。
- **本機無特權 app**：沒有新的 IPC、檔案或連接埠。剪貼簿只在使用者按「複製」時寫入（診斷頁走白名單，文字紀錄經 `mask`）。SSH 頁從剪貼簿讀進來的內容，在送出前顯示指紋給使用者核對。
- **實體取得手機**：`teams` 只在記憶體；SSH 頁、節點設定只在 devTrust 版本；刪掉舊啟動頁那個沒有閘門的「我的節點」入口之後，攻擊面變小。
- **自己的錯**：見 MINOR-1 / MINOR-2 / MINOR-3。
- **fail-secure**：國家只允許 `{'US'}`；`splitCode` 遇到不成對的標記 → 整句當主句顯示（fail-visible，合理）；`orphanJoins` 讀不到節點清單時 → 一個都不列。

## BLOCKER

無。

## MAJOR

無。

## MINOR

1. **「結果被接受」怎麼判斷沒有寫明**：`core.result` 回傳 `void`（core.dart:426），被它丟掉的晚到結果（:428）呼叫端看不出來。依現有程式，`identical(_attempt, a)` 成立時 core 幾乎一定接受（core 每次改狀態後都會同步 `_pump` → :474 `_abort`），但計畫只寫「只有這次結果被接受」。照計畫實作的人可能會寫成「`o.res == body` 就把 `core.states[id].readAt` 抄進 team」。如果在 core 丟掉這次結果時這樣做，抄到的就是上一次的 `readAt`，這次被丟掉的 team 會以新鮮樣式顯示。修法：讓 `core.result` 回傳 `bool`（只有 `Res.body` 而且呼叫了 `_read` 時才回 true），`_run` 依這個值寫入；T6-13(b) 加一條「`core.result` 丟掉（round 已換）→ 不寫」，用注入的 core 狀態做。不要用 `states[id].readAt == t` 判斷：測試用的假時鐘不會前進時，這個比較會誤判。
2. **D5(c) 說 `readWall` 是「core.result 剛寫進 states[id]」的值**：事實上 `readWall` 是 `_run` 自己在 core.result 之後寫的（node_link.dart:584），不在 `states` 裡。實作時要注意寫入順序：team 寫在 :584 之後，並用 `readWall[a.id]`。改一下文字，免得實作的人去 `states` 裡找這個欄位。
3. **冷啟動時第一輪可能顯示錯的「沒有名單」**：`netKnown` 讀 `NetIndex.now`（app_link.dart:131-133）。`NetIndex` 第一次算完之前，`_now` 是 `NetSnapshot(computing: true)`，`nets` 是空的（net_index.dart:142），所以 `netKnown` 為 false → 得到 `recordPlain: null` 版本 →「這支手機沒有這個網路的名單」，而且會以新鮮樣式顯示約 60 s。這和 I MINOR-1「NoList 只在真的沒有時出現」的精神相反。修法：`nets.now.computing` 而且還沒有任何結果時，`Outcome.team` 設為 null（這一輪不寫）；T6-13(a) 加一條。只在 N+1 會發生。
4. **§5 那一列「網路離開 → `teams[id]` 清掉；該網路沒有別台 → 該段消失」和 D5(f)「每台一段」不一致**：離開網路之後，下一次讀取會寫入 NoNet 版本（「這台不在網路裡」那句），那一段不會消失。只有 `node/<id>` 被移除時才清掉。§4 的寫者欄也要補一句：清除是在 NodeLink 的 records 更新處做的（同一個擁有者）。改 §5 的文字，並讓 T6-13 的期望和它一致。
5. **D5(d) 那句「其他判斷『三種頁面』的地方把 team 當 home。」仍然重複兩次**（I MINOR-6 / J MINOR-3 指出過）。刪掉一句。

## 負向對照的完整性

每條聲稱的修正都有負向對照：T6-13(a)–(e)、T-C4c、T6-1 到 T6-14、既有測試的移植表。上面 MINOR-1 建議補的一條是對照「core 丟掉結果」這種情況，不屬於缺少負向對照的 MAJOR。

## 計數與判定

BLOCKER 0 / MAJOR 0 / MINOR 5

**APPROVE-WITH-CHANGES**：第五輪的 MAJOR（readAt 時序）已經解掉；前幾輪的 MAJOR 抽查後都成立。剩下 5 條 MINOR 是文字或實作細節，可以在實作時處理並列在 PR 裡，不需要再整份重審。
