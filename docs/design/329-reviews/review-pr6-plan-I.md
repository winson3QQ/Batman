# #329 PR 6 計畫 v5：第五輪獨立審查（I）

審查對象：`docs/design/329-pr6-plan.md` v5（整份），worktree `C:/src/Batman-329pr6` @ c4905ed。只讀；`檔:行` 都是本輪自己開原始碼核過的。基準（v12.1、PR 1–5、#349、254 v2.4）不重審；全隊頁「做不做」是使用者決定，只審「怎麼做」。

## 前輪 MAJOR 是否解掉

| 前輪 | 狀態 | 說明 |
|---|---|---|
| G-M1 接句吞主句 | ✅ | 改成成對 U+001E…U+001F 之後，`"{t}；需要新的邀請"`（owner.rs:601-602）、`'$detail$warn'`（claim_recovery）、`{why}…，沒有改動任何東西`（owner.rs:543）、`join('\n')`（main.dart:260-264）接起來後每段仍成對，`splitCode` 拿掉成對段，主句文字都留著。五處接句各有測試（T-C4c）。巢狀見 MINOR-2 |
| G-M2 / H-M1 舊 team 顯示新鮮 | ⚠️ 規則對，但**產生 `readAt` 的機制不存在** → 本輪 MAJOR-1 | |
| H-M2 偏離 254 / nodes.dart | ✅ | 先 `teamView(recordPlain: null)` 再用紀錄覆蓋，和 nodes.dart:1165-1176 一致；入口不要求 netId。但 T6-13(c) 文字沒跟著改 → MINOR-4 |
| H-M3 R-7 起點 | ✅ | 第 0 步唯讀確認、條件式離開、隊員入口、dev3 套件 / 簽章核對都寫了；順序（1 → [離開] → 2 → 3 …）和 reason 14 / `AlreadyMember` 不衝突 |

## 已驗證的事實（本輪）

- `core.states[id].readAt` 只在 `NodeLinkCore.result(now, a, o)` 的 `Res.body` 分支（core.dart:436-441 → `_read`，:487-490）與 2' 成立時（tick，:557-561）寫入。`now` 是 `NodeLink._run` 在 **probe 回來、`await mine?.close()` 之後**才取的（node_link.dart:582）。`readWall` 同時（:584）。
- `SessionProber` 的 hint（將來的 `_afterRead`）在 probe **裡面**、`done(o)` 之前跑（prober.dart:155-167）；prober 不知道、也不可能知道之後 core 會用哪個 `now`。
- 被取消 / 被 core 切掉的那次讀取：`_run` 在 `!identical(_attempt, a)` 時直接 return，不呼叫 `core.result`（node_link.dart:579）；core 自己也丟晚到的結果（core.dart:428）。
- `loginFor`（流程的登入）`Res.body` / `errorCode` 都不寫 `readAt`（core.dart:697-701）；`HandoffProber` 的 `hint = null`（prober.dart:71）。→ handoff 讀取不會把 team 弄舊，✅。
- row 2' 讀取：prober 不跑 hint（`o.res == Res.body` 才跑，:163）；兩次之後 tick 把 `readAt` 改成 2' 的時間（core.dart:557-561）→ team 的 `readAt` 不等於 → 該段變 unk。行為合理 ✅（顯示時間見 MINOR-3）。
- 節點字串全部經 `display_name`（invite.rs:110-111，`is_control()` 對 U+001E / U+001F 都成立 → U+FFFD），被入侵的節點插不進假標記 ✅。Rust 端沒有任何地方把 app 自己的句子再經 `shown` / `display_name` 或截斷（grep `display_name(` / `shown(` 全部是節點或紀錄字串）✅。
- Dart 對句子做字串操作的地方：say.dart:5 的 TAG 前綴（`^`，標記在後面，不受影響）、rekey_send.dart:25 錨定 regex（`[UPDATED]` 句不含代碼）、`endedLine` / `starts()` / `startsWith('[REKEY]')` / main.dart:114 `安裝紀錄：` 前綴、member_ui.dart:500-501 卡片 `split('\n')`（團隊卡片不含代碼）——都不被標記弄壞 ✅。沒有對句子做 `substring` / 位元組上限 / 持久化的地方 ✅。
- `NodeLink.mask`（node_link.dart:78-80）只換 hex 與 MAC，和標記無關；D7 規定紀錄 / logcat 把標記換成〔〕✅。
- `teamview::WRITE_MESH_ADDR = cfg!(feature = "team-write")`（teamview.rs:16），release 開不了（:20-21）✅。
- home ↔ team：`setPage` 只在 `pg == page && node == pageNode` 才是 no-op（core.dart:188-189），否則 `_cancel` 並清 due（:190-194）；計畫 D5(d) 明寫 home ↔ team 整個 no-op、T6-13(e) 有負向對照 ✅。HomePage 的 `_back` 回來時 `setPage(home)`（home_page.dart:182-186）也會是 no-op ✅。

## BLOCKER

無。

## MAJOR

### MAJOR-1　`teams[id].readAt == core.states[id].readAt` 的值在寫 team 的時候還不存在；照 D5(c) 寫，team 不是永遠舊、就是永遠跟上一次讀取配對；而且 T6-13 沒有一條正向測試會抓到

**情境**：D5(b)(c) 規定 `SessionProber._afterRead` 經 `TeamSink.onTeam(id, netId, view, readAt)` 寫 `teams[id]`，`readAt` 要「和 `core.states[id].readAt` 同一個值」。但：

- `_afterRead` 在 probe 裡、`done(o)` 之前跑（prober.dart:155-167）；
- `core.states[id].readAt` 是之後 `_run` 在 probe 回來、關完連線才取 `now()` 寫的（node_link.dart:567-584 → core.dart:436-441、:489）。

所以 prober 在 `onTeam` 的時候拿不到那個值。實作者只能猜：
- 用 `now()` → 永遠不等於 → **每一段永遠是 unk 樣式**（N+1 打開後全隊頁整頁灰，功能等於沒做）；
- 用當下的 `core.states[id].readAt`（上一次讀取的）→ 寫完後 `core.result` 立刻改掉 `readAt` → 一樣永遠不等於；
- 或在 `onTeam` 寫入時順手把 `readAt` 補成 core 之後的值 → 需要一個計畫沒寫的「暫存到 `core.result` 之後再套用」機制；而且被取消 / 被 core 丟掉的讀取（node_link.dart:579、core.dart:428）不能套用，否則 team 比 status 新、配到一個不存在的讀取。

**為什麼測試抓不到**：T6-13 對新鮮度只有負向條（(d)「第 2 輪 openNet 延遲 / cancel 時那一段不是綠的」、「不新鮮整段 unk」），**沒有一條「正常讀到 → 那一段是新鮮的、有燈號」的正向斷言走過 prober → NodeLink → `core.result` → TeamPage 這整條路**。TeamPage 的 widget 測試多半直接塞 `teams` 與 `states`，會繞過這個機制。「永遠 unk」的實作會通過全部列出的測試——H-M1 的修法變成「宣稱有修、實際不可用且沒有測」。

**修法**：
- 寫明機制：team 隨 outcome 一起回去，不在 probe 中途寫。例：`Outcome` 多一個欄位（或 extra 包一層）帶 `(netId, view)`；`NodeLink._run` 在 `core.result(now(), a, o)` 之後、**只有** `o.res == Res.body` 且這次結果被 core 接受（`identical(_attempt, a)` 那條路、且 `core.states[a.id]?.readAt` 剛被設成這次的 `now`）時，寫 `teams[a.id] = (netId, view, core.states[a.id]!.readAt, readWall[a.id])` 並 `_changed.add`；`TeamSink` 只保留給測試注入。prober 裡 2 s 逾時後的晚到結果要寫進一個**已經快照過**的區域變數，不能在 `done(o)` 之後改 outcome。
- T6-13 加正向端對端：假 prober 回 body + team → `NodeLink` 套用 → TeamPage 那一段是新鮮樣式、有燈號、時間 = 這次 `readWall`。負向對照：`readAt` 改成 prober 自己的 `now()` → 這條 FAIL；被取消的那次讀取的 team 被套用 → 另一條 FAIL（team 新、status 舊）。

## MINOR

1. **D5(b) 自相矛盾**：同一格先寫「超過 2 s → 這一輪不更新 team（保留舊值，照新鮮規則變舊）」，後面又寫「超過 2 s 時得到的是『沒有名單』版本，不是舊值」；T6-13(a) 照後者。刪掉前一句。另外後者的效果是：Keystore 慢一次，新鮮的段就說「這支手機沒有這個網路的名單，看不到隊員名稱」（teamview.rs:268）——這句是錯的（手機有名單，只是慢）。舊程式（nodes.dart:1165-1176）沒有 2 s 上限，所以 NoList 只在真的打不開時出現。建議：紀錄已經在開、只是超過 2 s → 這次不寫 team（照新鮮規則變舊），NoList 只用在 `netKnown` 假 / `openNet` 回 null / 例外；T6-13(a) 對應改。
2. **巢狀標記的規則沒寫**：`splitCode` 對「開始、開始、結束、結束」沒有定義（「不成對」只講只有一邊）。會發生的地方：Dart `'認領中斷：$e'`（claim.dart:496）、`${e is String ? e : e.runtimeType}`（join_pages.dart:103、:261、:382、:401、:603，remove_pages.dart:90）——`e` 是 Rust 的 String 錯誤，D8 之後本身就帶標記（member.rs:37 `內容驗證沒有通過（{w}）`→ 帶標記）。如果實作把整個 `${…}` 包起來，`e` 的中文主句（例：「這張邀請已用過或已作廢，請重新邀請」member.rs:47）會被藏進技術資訊。另一個推手：D7a (1) 的「同一字面量」規則會讓 `format!("，原因 {r}")`（owner.rs:668）這種**之後被插進技術段**的片段報 FAIL，實作者若照掃描把片段也包起來就造成巢狀。修法：(a) Dart 只包非 String 的分支（`e is String ? e : '\u{1E}${e.runtimeType}\u{1F}'`）、`$e` 同理；(b) `splitCode` 定義巢狀 = 依深度配對、外層段整段進技術；Rust 加 `debug_assert!` 包裝的內容不含標記；(c) D7a 允許清單加「只被插進技術段的片段」一類（owner.rs:668-669 的 `reason` / `verb`）；(d) 測試：`'邀請不能用：$e'` 且 `e` 帶標記 → 主句含 `e` 的中文。
3. **全隊頁不新鮮時的「上次讀取 HH:MM」用哪個時間沒寫**：`readWall[id]` 是 status 的時間（node_link.dart:584、2' 時 :499-504 也會改）。2' 或取消之後 team 比 status 舊，用 `readWall` 會顯示比資料新的時間。`teams[id]` 一起存那次的 wall time（MAJOR-1 的修法已帶），不新鮮段顯示它。
4. **T6-13 的文字沒跟 v5 改**：(c)「有 visible 且 netId 不空 →『看全隊狀態』」與 D5(e)「不要求 netId」（H-M2 修法）相反，照測試寫會把 H-M2 改回去；(a) `onTeam(id, netId, view)` 少 `readAt`；H-M2 要求的「netId 空 → `ONLY_NO_NET`」「info 失敗（nodeState ≠ 1、netId 空）→ `NO_INFO` 不是 NO_NET」兩條沒列。逐條改。
5. **D7a (2) 還是 v4 的寫法**：「輸出用 U+001F 切開後，主句…」。成對之後要用和 Dart `splitCode` 同一套規則的 Rust 測試 helper（`split_code`）取主句；否則 owner.rs:543 這種技術段在中間的句子，切在第一個 U+001F 會把技術段算進主句、或把後面的主句丟掉，測試要嘛誤報要嘛漏報。Rust helper 與 Dart `splitCode` 共用一組測試向量（多段、接句、不成對、巢狀）。
6. **D5(d) 有一句重複**（「其他判斷『三種頁面』的地方把 team 當 home。」兩次）。

## 安全（本輪增量）

- 遠端 / 被入侵的節點：插不進標記（`display_name`），只影響自己那一段 ✅；`error_text` 的 `{v}` 經 `shown` ✅。MAJOR-1 若照「永遠配到上一次」實作，被入侵的節點不需要做任何事就能讓自己那段的舊值以新鮮樣式留著——修法同 MAJOR-1。
- 本機無權限 app：無新攻擊面（`teams` 只在記憶體；標記只在程序內，紀錄 / logcat 換成〔〕）。
- 實體取得：無新持久化文字。
- 自己的錯誤：MAJOR-1 是「規則對、介面沒定義資料從哪來」的典型——prober 與 core 各自正確，接起來那個值不存在。

## 結論

BLOCKER 0 / MAJOR 1 / MINOR 6

**APPROVE-WITH-CHANGES**。G-M1、H-M2、H-M3 已解；G-M2 / H-M1 的規則對，但 `readAt` 的來源沒有定義（prober 寫 team 時 core 還沒產生那個值），而且沒有正向端對端測試，照計畫實作可能整頁永遠灰、測試照樣全過。MAJOR-1 的修法小（team 隨 outcome 回去、`core.result` 之後套用 + 一條正向測試與兩條負向對照）；修完只需再看 D5(b)(c) 與 T6-13，其他可進實作。
