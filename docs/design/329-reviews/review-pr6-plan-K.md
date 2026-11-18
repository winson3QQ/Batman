# #329 PR 6 計畫 v6 — 第六輪審查 K

審查對象：`docs/design/329-pr6-plan.md` v6（整份）。基準：設計 v12.1、PR 1–5 + #349（main c4905ed）。程式核對在 worktree `C:/src/Batman-329pr6`（HEAD c4905ed），全部唯讀。

## 前輪 MAJOR（I-M1 / J-M1：team 的 readAt 時序）是否解掉

**✅ 解掉。** 逐點核對：

| 檢查 | 結果 | 證據 |
|---|---|---|
| prober 寫 team 時沒有 readAt | 新設計 prober 不再產生 readAt，只把算好的 team 放進 `Outcome.team` 回傳 | prober.dart:154-169（`answer` 分支裡，`done(o)` 之前就是現在 `_hint` 的位置；`read = o` 先存、cancel 走 `done(read ?? …)`，所以 cancel 時回去的是不帶 team 的 `o`，符合「cancel → team null」） |
| readAt 的唯一來源 | `NodeLink._run` 呼叫 `core.result(now(), a, o)`（node_link.dart:582）→ `core.result` 的 body 分支 `_read(s, now, …)` 設 `s.readAt = now`（core.dart:445-450、:487-490）；`readWall[a.id] = wall()` 在 node_link.dart:584 只對 body 寫 | 原始碼 |
| 「被接受」在程式裡是否定義得出來 | 有兩道閘：`_run` 的 `if (!identical(_attempt, a)) return;`（node_link.dart:580，`_abort` / 被取消的一輪在這裡就回去，不到 `core.result`）；`core.result` 自己的 `if (r == null \|\| !identical(r.running, a)) return;`（core.dart:428）。`_pump` 每次 `core.tick` 之後同步檢查 `core.running` 不同就 `_abort`（node_link.dart:472-474），而所有會改 core 回合的入口（setPage :159、background :164、foreground :169、refresh :187、radio :192、acquire :208、released :451）後面都接 `_pump`；:446 的 `setRecords` 只發生在租用期間（沒有回合）。所以實務上「過了 :580 那道閘」≡「core 接受」，但計畫沒有寫用哪個訊號判斷（見 MINOR-1） | 原始碼 |
| row 2' 不寫 | 2' 是 `Res.errorCode`（prober.dart:157），core 走 errorCode 分支、不改 readAt；之後 `_end` 把它變 2' 時另蓋 readAt（core.dart:556-561）→ team 的 readAt 不相等 → 舊資料樣式。計畫「team 只在 body 時算」要寫明（MINOR-2） | 原始碼 |
| loginFor / handoff 不碰 team | `loginFor` 用 `loginProber` = `HandoffProber`（app_link.dart:142），`_handoff` 時 `hint = null`、在 `loggedIn` 就 `done(Outcome(Res.body, '', handed))`（prober.dart:141-148），不讀狀態頁；`LoginFor.result`（core.dart:691）不看 extra。計畫寫者只有 `_run` ✅ | 原始碼 |
| `Outcome` 能不能多帶一個欄位 | `Outcome(this.res, [this.view = '', this.extra])` 是 const、位置選填（core.dart:43-49）；`extra` 已被佔用：body / errorCode = `StatusView`（core.result 寫進 `s.extra` / `s.errExtra`，畫面讀 `StatusView.tech`），handoff = `LoginHandoff`（prober.dart:147、:249 `identical(o.extra, h)`）。所以 team **不能**塞 extra，另開具名選填欄位是對的；現有呼叫者（core4/core5 測試、node_link 的 `const Outcome(Res.noResponse)`）全部不受影響；沒有任何地方對 `Outcome` 做 `==` | grep `Outcome(`：core.dart、node_link.dart:385-390、:564-571、prober.dart:22-26、:102-190 |
| team 物件在 session dispose 後還能用 | `TeamView` 是 FRB 產生的普通 Dart 類別（欄位 visible/title/only/cards/note/tech，owner.dart:701-713），不是 opaque handle；`team_view` 是 sync（owner.rs:1360-1367）。只要在 `stop()` 檢查之後、`done()` 之前呼叫就安全 ✅ | 原始碼 |
| 正向測試 | T6-13 (b)「正常讀完一輪 → `teams[id].readAt == states[id].readAt`、那一段是新鮮的」——這條正好抓 I/J 說的「永遠舊」；(a) 另測 SessionProber 真的把 team 放進 `Outcome.team`。兩段合起來覆蓋 prober → `_run` → `core.result` 整條 ✅ | 計畫 :131 |
| 負向對照 | 「抄 `core.result` 之前的 `states[id].readAt`」→ 抄到上一次 → 正向那條 FAIL ✅（判別力足）。「被取消那次的 team」「`_abort`」「id 已移除」各一條 ✅。**但**「在 prober / 另一次 `now()` 蓋 readAt」那條在假時鐘下可能不 FAIL（MINOR-3） | 計畫 :131 |

## BLOCKER

無。

## MAJOR

無。整份再掃一次（D1–D12、§3–§7），前五輪已解的不重列；沒有找到新的真實破壞、安全缺口或無測試的宣稱修法。

## MINOR

1. **「被接受」用哪個訊號沒寫**。情境：實作者在 `core.result` 之後無條件寫 `teams`，靠 :580 那道閘；若將來有人在 `_run` 的 `await mine?.close()` 之後、`core.result` 之前加一個 await 或改 `_pump` 的同步檢查，core 丟掉結果而 NodeLink 照寫。修法：讓 `core.result` 回 `bool`（body 且被套用 = true），`_run` 只在 true 時寫 `teams`；或寫入後比對 `core.states[id]?.readAt == t`。計畫 D5(c) 寫明其一。
2. **team 只在 `Res.body` 算**：D5(b) 寫的是「讀到本體後」，`_hint` 現在已有 `o.res == Res.body` 閘（prober.dart:160），`_afterRead` 照用即可；寫一句避免 row 2' 也帶 team（雖然 (c) 的 row 2' 不寫已擋住）。
3. **「另一次 `now()`」負向對照可能不判別**：`_run` 若寫成 `core.result(now(), …)` 再 `teams[id] = (…, now(), …)`，真機上兩次 `now()` 偶爾差 1 ms → 那段間歇性變舊；假時鐘不前進時 T6-13 (b) 照過。修法：實作取一次 `final t = now()` 共用（或讀回 `states[id].readAt`），測試的假時鐘每次呼叫 `now()` 都前進 1 ms（或假 link 的 `close()` 前進時間），負向對照才真的會 FAIL。
4. **`Outcome.team` 的型別**：core.dart 目前零 import（純 Dart 排程器，檔頭 :1-4 宣告）。`TeamView` 是 FRB 型別；建議 `final Object? team;`（同 `extra` 的做法），由 NodeLink 轉型，避免 core 拉進 Rust 綁定。
5. **readWall 的說法**：D5(c)「`readAt` / `readWall` 就是 `core.result` 剛寫進 `states[id]` 的那兩個值」——`readWall` 不在 `states`，是 `NodeLink.readWall`、在 `core.result` 之後由 node_link.dart:584 寫。改成「`core.result` 寫的 readAt 與 :584 寫的 wall time」，`teams` 寫入放在 :584 之後。
6. **`teams` 的第二個寫者（清除）**：D5(c)「`node/<id>` 移除時清」是除了 `_run` 之外的另一個改動點。§4 表的寫者欄補「清除：NodeLink 在記錄清單更新（`start` / `released` 後 `setRecords` 拿掉 id）時」，兩處都在 NodeLink，不構成雙寫者衝突，但要寫出來。
7. **`hint == null` 而 `teamEnabled()` true**：`netKnown` / `openNet` 來自 `HintSource`；`SessionProber` 的 `hint` 可為 null（測試、flow）。寫明：沒有 HintSource → 只算 `recordPlain: null` 版本或整個不算（建議不算，`Outcome.team` = null）。
8. 編修：D5(d) 最後一句「其他判斷「三種頁面」的地方把 team 當 home。」重複一次，刪掉。

## 安全（逐 actor，只看本輪改動）

- 遠端 / 被入侵的節點：team 只從自己那次 body 讀取算出、每台一段；新機制讓「延遲 / 逾時那輪」必為 null → 舊值必為 unk，被入侵節點無法讓舊段以新鮮樣式留著 ✅。
- 本機無特權程序：`teams` 只在記憶體，無新輸入面 ✅。
- 自己的錯：MINOR-1 / MINOR-3 是「兩個元件各自正確、接起來的時間值」同一類，修法都是取單一來源。

## 結論

BLOCKER 0 / MAJOR 0 / MINOR 8

**APPROVE-WITH-CHANGES**（只剩 MINOR，可直接進實作，MINOR-1 / -3 / -4 建議在實作時一起處理並列在 PR）。I-M1 / J-M1 已解：team 隨 `Outcome` 回去、`_run` 在 `core.result` 之後寫入，`Outcome` 加欄位不影響現有 `extra` 使用者（StatusView / LoginHandoff），正向測試存在且能抓「永遠舊」。
