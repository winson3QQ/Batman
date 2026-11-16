# #329 NodeLink 排程程式 審查 B（程式審查第 1 輪）

- 審查對象：分支 `feat/329-nodelink-core` @ 236ea4b 的 `app/lib/src/nodelink/core.dart`、`app/test/nodelink/sim.dart`、`core_test.dart`、`core2_test.dart`（47 個測試）、作者的負向對照輸出 `mutate4.out`；契約為 329-app-uiux.md v12.1 的 §1.2、§1.3、§4.3、§5.1、§9.1。
- 做法：自己的 throw-away worktree `C:/src/Batman-329core-rB`（detached 236ea4b）。寫了真實情境測試、加了一個「連線必須等節點廣播」的模擬模式、跑了 51 個自己的突變（R1–R51）、兩個修法實驗。沒有 commit / push，沒有碰硬體；`C:/src/Batman-329core` 沒有動。結束時 core.dart 已還原（`cmp` 與 core.orig 相同）。
- 標記：✅ = 有實跑輸出；⚠️ = 推論。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、5 MAJOR、9 MINOR。

排程本身的大方向（兩個佇列輪流、兩次一輪、30 s 等已知位址）在我跑的情境裡成立，作者的 19 個對照都確實改到了測試名稱上的那條規則。但是：(1) 核心沒有辦法加入或移除節點紀錄，「從零到組網」的認領路徑在核心裡走不通；(2) 90 s 上限切掉的那次嘗試被當成試過了，12 台的時候每一輪都有一台健康的節點被判「沒找到」，提前再讀的計數因此永遠停在 3；(3) 藍牙關掉再打開會把「身分不符」清掉；(4) 附近有 8 台以上別人的節點時，「認領完立刻建網」的第一次登入會失敗；(5) T-L13(a)、T-L16 沒辦法 FAIL，另外有 22 條規則沒有任何測試守著。

## 我寫的測試與模擬改動（都在 worktree，沒有 commit）

- `C:/src/Batman-329core-rB/app/test/nodelink/rb/rb_scenarios_test.dart`：情境測試。`RB-BUG-*` 在 236ea4b 上**應該 FAIL**（每一個代表一個發現）；`RB-OK-*` 只印數字。
- `C:/src/Batman-329core-rB/app/test/nodelink/sim.dart`：加了 `SIM_REAL=1` 模式（原檔備份在 `C:/src/Batman-329core-rB/sim.orig`）。原本的模擬裡，節點只要不是「連著」就連得上——節點在斷線後重新廣播前那約 5 s 也連得上。真的節點撤下廣播後，中央端連不上它（N1）。`SIM_REAL=1` 改成：連線要等節點開始廣播，等待時間算在 8 s 的 msg2 預算裡；超過預算就是「沒有回應」，而且沒連上的嘗試不會讓節點變成忙碌。預設模式的行為和原檔相同（47/47 照樣通過）。
- `C:/src/Batman-329core-rB/rb_mutate.sh`、`rb_mutate2.sh`：自己的突變，只跑作者那兩個測試檔。輸出在 `rb_mutate.out`、`rb_mutate2.out`。
- 完整輸出：`rb_final.out`（預設模擬）、`rb_final_real.out`（`SIM_REAL=1`）、`rb_fix1.out`、`rb_fix2.out`（修法實驗）。都在 worktree 的根目錄。

✅ 作者的 47 個測試在兩種模擬下都通過。`rb_final.out` 與 `rb_final_real.out` 的失敗清單只有 `rb/` 底下的測試。兩種模擬印出來的 `[RB]` 數字完全相同。

## MAJOR

### M1 核心沒有辦法加入或移除節點紀錄：認領的新節點首頁永遠不讀，`loginFor` 直接丟例外；T-L17 會通過，只是因為測試事先放好了那筆紀錄

- 情境：從零到組網（U2-1）。手機已經有 Y1，使用者認領一台新節點 Y2。認領的佔用寫入 `node/Y2`，接著在建網流程裡呼叫 `loginFor(Y2)`。
- 證據：`_recs` 與 `states` 只在建構子裡設定（core.dart:93-96）。沒有任何 API 能加入、移除紀錄或更新修改時間。`releaseLease(written:{Y2})` 對不認識的 id 什麼都不做（:211）。
  - ✅ `RB-BUG-7`：`home targets after the claim: [Y1] / 8.0 round 1 full [Y1]`，也就是 Y2 永遠不會出現在任何一輪的目標裡。
  - ✅ `RB-CLAIM-*-pre=false`（同一個流程，但沒有事先放 Y2）：`Null check operator used on a null value` 丟在 `core.dart 630:27 LoginFor.result`（`c.states[id]!`）。
  - 作者的 T-L17 在 `w.phone('p', [const Rec('Y1', 1)])` 就把被認領的紀錄放進去了。也就是說，模擬比真實情況寬鬆。
  - 「從這支手機移除節點」（T17）同樣做不到：被刪掉的紀錄會一直留在首頁的目標裡。§4.3.3-6 要求「每次佔用釋放後各讀一次」修改時間，也做不到。
- 修法：加 `setRecords(now, List<Rec>)`，由 `NodeLink` 在啟動檢查與每次佔用釋放後呼叫（和 §4.3.8 同一個時機）。新的 id 建 `NodeState`；消失的 id 刪掉 state 與指向它的備忘；mtime 更新。`loginFor` 與 `setPage(node)` 遇到不認識的 id 要回錯誤，不能丟 null 例外。T-L17 改成先不放紀錄、由認領流程加入；另外加一個「刪除後不再讀」的測試。

### M2 90 s 上限切掉的嘗試被算成「試過」：節點多時每一輪都有一台健康的節點被判「沒找到」，提前再讀從此被鎖住

- 契約：§4.3.4「90 s 時被切掉的那次嘗試算沒試過」；切掉已知位址那一次應該是「排隊中」。
- 程式：`next()` 開始一次嘗試時就把它加進 `tried` 並計入 `count`。到上限時 `tick()` 只記一行 log 就呼叫 `_end`（:462）。所以 `_conclude` 會看到 `!_canTry`，判成 `notFound`。那是第一次「沒找到」，所以觸發提前再讀。每一輪都觸發，計數永遠停在 3，不會歸零（`trigger.isEmpty` 永遠不成立）。
- 證據：
  - ✅ `RB-BUG-1`：12 台都正常，穩定之後 15 分鐘 `cuts=6 rounds-with-notFound=6`，也就是每一輪被切的那一台都被判「沒找到」。完整 log（rb12.log，scratchpad）裡的例子：`540.0 a6×Y6 cut at the cap` 接著 `round 6 end {… Y6: notFound …}`。
  - ✅ `RB-BUG-2`：12 台穩定後關掉 Y5 → `earlyCount=3 early rounds after off=0; Y5 連不到 after 330 s`。
  - ✅ 修法實驗（`rb_fix1.out`）：在上限切掉時把那次嘗試退回（拿掉 `tried`、`count` 減 1、`n` 減 1）→ `RB-BUG-1 … rounds-with-notFound=0`，`RB-BUG-2 earlyCount=0 early rounds after off=1; Y5 連不到 after 220 s`。**作者的 47 個測試在修法前、修法後都全部通過**，所以沒有任何測試守著這條規則。
  - T-L21 的「沒有提前再讀」會通過，是**因為**計數已經卡在 3，不是因為規則對（突變 R18「還沒輪到不觸發」反而讓 T-L21 FAIL，`rb_mutate.out`）。
- 使用者看到的：台數超過一輪讀得完的數量時（A1 = 11 s 時 ≥ 8 台；§4.3.5 寫的是 demo 2–8 台、隊長的手機），一台真的掉線的節點要 330 s 才顯示連不到，設計的流程是 220 s。另外，冷啟動之後提前再讀等於永久關閉，直到進背景一次。
- 修法：照上面的實驗做。加 `RB-BUG-1`、`RB-BUG-2` 當回歸測試；它們的對照就是現在的程式碼。

### M3 藍牙關掉再打開（或金鑰暫時不能用）會把「身分不符」清掉，變成「連不到」

- 契約：§4.3.3-4 規定身分不符只在三種情況結束：之後的某一輪讀到、重新整理、紀錄被寫入或刪除。§5.1 第 4 列（bad）排在第 8 列（warn）前面。
- 程式：`_precondition()` 把**每一台**的 `why` 都覆蓋成前提原因（:255-258）。恢復時 `_begin` 把 `why` 清成 null（:263-268）。這時位址上還有「不是 Y」的備忘，Y 不會再被試，所以兩輪之後變成 `unreachable(notFound)`。
- 證據：✅ `RB-BUG-3`：`after BT off/on: kind=Kind.unreachable why=Why.notFound`。✅ `RB-BUG-3b`（金鑰）：同樣的結果。突變 R5（前提成立時不標 unreachable）沒有任何作者測試 FAIL。
- 使用者看到的：一個安全事件（bad「節點 X 的身分和這支手機記錄的不同」）在使用者「關掉藍牙再開」之後，降成 warn「手機連不到節點 X」，下一步也變成「重新整理」。關掉再開藍牙正是一般人遇到問題時會做的事。
- 修法：前提原因和每台的原因分開存，例如另設一個欄位 `pre`，畫面上前提優先。或者 `_precondition` 不覆蓋 `Why.identity`。

### M4 「認領完立刻建網」：附近有 8 台以上別人的節點時，`loginFor` 第一次一定失敗

- 情境：隊訓時隊長認領新節點，附近有其他隊員的節點（§4.3.7 用 m = 10 估）。
- 程式：認領後 30 s 內（N9 例外），對**任何**位址的「解不開」都不記備忘，並且讓那個位址重試（:635-637）。`LoginFor.next` 依掃到的順序挑「第一個可以試的」，所以重試排在還沒試過的位址前面。新節點換成 RPA 之後最後才被掃到，60 s 內輪不到它。
- 證據（Y2 的紀錄事先放好，避開 M1）：
  - ✅ `RB-CLAIM-10-pre=true loginFor end=LoginEnd.notFound handshakes=12`。log：`f0, f1, f2, f0, f1, f2, f0, f1, f3 …` 一直重試前三個。
  - ✅ `RB-CLAIM-RETRY-8/10/12 ends: [LoginEnd.notFound@262, LoginEnd.ok@335]`，也就是 8 台就會失敗，使用者要再按一次「再試一次」。
  - ✅ 修法實驗（`rb_fix2.out`）：`LoginFor.next` 先試沒試過的位址、再試重試的 → `CLAIM-10 ok handshakes=11`、`RETRY-8/10 ends: [ok@262]`；12 台時仍然失敗（12 × 5 s 已經是整個 60 s，這是物理限制）。作者的 47 個測試都照樣通過。
- 使用者看到的：需求 1（從零組網）與需求 4（不要重連的雜事）。正常的環境裡，第一次登入就失敗。
- 修法：照上面的實驗做。§4.3.9 的「順序」補一句：「沒試過的位址先於同一個 `loginFor` 裡要重試的位址」。加 `RB-CLAIM-10` 當回歸測試。

### M5 有測試不會 FAIL，另有 22 條規則沒有任何測試守著

- **T-L13(a)**（斷線後 8 s 才重新廣播 → 不顯示連不到）：兩批共 70 個突變（作者 19 個 + 我 51 個）都沒有讓它 FAIL。原因：一支手機、每台每輪讀一次時，下一次連線離上一次斷線至少 60 s，8 s 的重新廣播根本碰不到。原模擬又讓「安靜期」的節點照樣連得上。它沒有辦法對它名稱上的那個 bug FAIL。
- **T-L16**：
  - `log.where((l) => l.contains('Why.notFound'))` 永遠是空的，因為 log 裡只會出現 `notFound`（列舉的 `.name`）。✅ `RB-VACUOUS` 通過：狀態**確實是**找不到時，那個斷言仍然是空的。
  - 另外只檢查跑完時的最後狀態，不是 §9.1 要的「出現次數 = 0」。
  - ✅ 我每秒取樣一次：`RB-T-L16 off=0..50 noResponse=[0, 0] notFound rounds=0 連不到 seconds=0`（兩種模擬都一樣），也就是 6 種錯開時間裡兩支手機**從來沒有撞到過一次**。所以這個測試連安全斷言都沒有被觸發。作者說它只是安全檢查，我同意不拿它證明兩輪規則，但斷言要改成真的會看狀態的，並且要能造出碰撞（例如每支手機各有兩台節點，或讓第一次看到廣播的時間隨機在 1–2.6 s 之間）。
- **沒有任何作者測試 FAIL 的規則**（✅ `rb_mutate.out`、`rb_mutate2.out`，每一個都是「+47: All tests passed!」）：

  | # | 規則（core.dart） | 契約 |
  |---|---|---|
  | R1 | `fresh` 的 300 s（:131） | §4.3.1，T-H2(b) |
  | R2 | 位址 20 分鐘沒被掃到就丟備忘（:272） | §4.3.3-5 |
  | R5 | 前提不成立 → 標 unreachable（:257） | §4.3.3-1、X7 |
  | R6 | 節點頁的一輪不算首頁的「上一輪結束」（:147） | §4.3.2 |
  | R7 | 回首頁、上一輪結束未滿 60 s → 排到滿（:171） | T-L3、X11 |
  | R8 | 進背景清掉「上一輪結束」（:184） | X34 |
  | R10 | 釋放時寫入的紀錄結束身分不符（:213-214） | §4.3.3-4 |
  | R11 | 身分不符只在之後的輪結束（:444） | §4.3.3-4 |
  | R12 | 登入被拒不蓋掉身分不符（:417） | §4.3.4 |
  | R13 | 「不變」結束找不到 / 登入被拒（:489） | §4.3.4 |
  | R14 | 「不變」把 miss 歸零（:488） | §4.3.4 |
  | R15 | 提前再讀的輪不算進 2'（:494） | §4.3.4 |
  | R16 | 2' 不蓋掉身分不符（:495） | §4.3.4 |
  | R21 | 提前再讀的計數歸零（:528） | §4.3.2（見 M2） |
  | R22 | 「排隊中」這個結論（:542） | §4.3.4 |
  | R26 | 這一輪在別的位址登入過 → 不拿 Y 去試別的位址（:340） | §4.3.3-6（v12 A-M2） |
  | R29 | 這次執行沒讀到過的排前面（:310） | §4.3.3-6 |
  | R30 | `loginFor` 的「先清不是 Y」（:567） | §4.3.9 |
  | R31 | `loginFor` 遇到身分不符就結束（:650） | §4.3.9 |
  | R33 | `loginFor` 的前提（:573） | §4.3.9 |
  | R36 | 有佔用時不開輪（:143） | X20 |
  | R50 | 藍牙關閉時取消進行中的輪（:237） | X7 |

  等價突變（拿掉之後行為不變，不需要測試，但程式可以簡化）：
  - R40：`refusedForbidden` 時的 `t.why`。沒有重試鍵，本來就不會再試。
  - R43：`certRejected` 時的 `t.why`。只影響結論的名稱：結論從 reason 變成 notFound，畫面不變，因為身分不符有守住。
  - R51：`isNot` 的「是別台」條款（:126）。兩個呼叫者都已經先濾掉 `isY[a] != null`，這個條款是死碼。
- 作者對照的對應檢查（mutate4.out）：19 個對照都改到了測試名稱上的規則，我同意。只有一點：「turns of one attempt」讓 X2 FAIL，是時間被擠動的副作用，不是 X2 的規則。另外 T-L14 和 T-L18 第一個測試在 mutate4 裡**沒有**對照；我補的 R45（已知的目標先試陌生位址）讓 T-L14 FAIL，R44（`loginFor` 不優先試已知位址）讓 T-L18 兩個都 FAIL，所以這兩個測試是有效的，但對照要寫進 mutate 腳本。
- 修法：
  - T-L13(a) 改成真的會碰到重新廣播的情境，例如在節點頁讀完立刻 `loginFor`，或錯誤碼之後隔 6 s 重試，而且模擬要用 `SIM_REAL` 的連線規則。
  - T-L16 改成每秒取樣，並造出碰撞。
  - 上表每一列補一個測試；突變腳本附在 PR。

## MINOR

1. **重播節點舊位址的靜默裝置會讓那台永遠讀不到，連流程都登不進去**。✅ `RB-REPLAY-a/b/c`：
   - Y1 換位址之後，一台不回應的裝置用舊位址廣播 → 15 分鐘內 `reads after rotation=0`，狀態是 `unreachable/notFound`。
   - 新位址已經有「是 Y1」時，如果舊位址先被掃到，同樣結果。原因：`_knownAddr` 只取第一個。
   - `loginFor`（含「先清不是 Y」）→ `LoginEnd.notFound`。
   - 舊位址的 `lastSeen` 會被攻擊者一直更新，所以 20 分鐘到期永遠不會發生；重新整理不清「是 Y」。

   這屬於 §4.3.7 已經接受的「學位址」類，所以列 MINOR。但畫面給的下一步「重新整理」對它沒有用。建議：
   - 已知位址在一輪裡兩次都沒有回應時，下一輪先試其他「是 Y」位址（成本低）；
   - 或者重新整理也丟掉「這次執行從來沒有回應過」的「是」備忘；
   - 另外在 §8 寫明這件事。

2. **「不變 → 登入被拒 → 不變」會變成灰 2'**。✅ `RB-BUG-5`：`kind=Kind.read view=2' same=2`。§4.3.4 說「中間任何一輪對 Y 的結論不是「不變」，計數歸零」；`_end` 的 `case Concl.reason:` 沒有把 `same` 歸零。

3. **`foreground()` 不是冪等的**。✅ `RB-BUG-6`：
   - 有一輪在進行時再呼叫一次 → `roundsRun=2`，進行中的嘗試變成孤兒，它的結果被丟掉。
   - §4.3.2 把「啟動時第一個 `resumed` 不另開一輪」交給 driver 負責。
   - 建議核心自己判斷：`fg` 已經是 true 就不做事。`startup` 也一樣。

4. **在其他頁面時藍牙恢復，60 s 內回首頁，每一列仍然是「藍牙關閉」**。✅ `RB-BUG-8`：`Y1 = Kind.unreachable/Why.bluetoothOff, round active = false`。只有 `_begin` 會把前提原因還原。`setRadio` 從「前提不成立」變成「成立」時，應該不管 `_eligible` 都先還原狀態。

5. **擁有權只靠慣例**：`states`、`isY`、`notY`、`lastSeen`、`writtenAt`，以及 `lease`、`fg`、`bt`、`page` 都是公開可改的欄位（X2 的測試就直接寫 `c.notY`）。建議對外只給唯讀檢視，`LoginFor` 透過核心的私有方法寫。另外 `loginFor` 沒有檢查 `lease`。

6. **冷啟動的時間沒有斷言，也沒有寫進設計**。✅：
   - 2 台 + 1 個陌生位址：30 s；
   - 7 台：240 s；
   - 8 台：270 s；
   - 2 台 + 12 個不回應的位址（先被掃到）：145 s；
   - 「Y1 讀到、Y2 關機、10 筆舊紀錄、12 個陌生位址」：Y2 在 691 s 才變成連不到，S0 在 1160 s。

   這些是每次 app 被系統結束後重開都會碰到的時間（備忘只在記憶體）。§4.3.7 只寫了「前兩次嘗試」。建議把數字回填到 §4.3.5、§4.3.7，T-L21 加上限斷言（例如 8 台 ≤ 300 s），避免以後改壞。

7. **模擬與真機**：
   - 原模擬對「安靜期」寬鬆（見上）。我加的 `SIM_REAL` 模式下，47 個測試和我所有的數字都不變（✅），所以目前的結論不受影響。但 T-L13(a) 這類測試要用它才有意義。
   - 第一次看到廣播 3 s，比 M-1 R 的 1.05–2.6 s 保守。斷線後 5 s 重新廣播加上 3 s 第一次看到，等於 8 s 才再看到；M-1 R 隔 0 s 時是約 4.9 s，所以也保守。
   - 沒有模擬的：N4 握手限速（10 支手機時 ⚠️ 推算不會碰到）、A1（⚠️ 未量）、手機的掃描次數限制（E）。
   - 「拿錯紀錄」固定 5 s，是 M-1 W 的上緣。

8. **重新整理不再結束身分不符**（作者的偏離第 3 點）：節點關機時，按重新整理之後仍然顯示 bad。我接受，因為這樣更安全。但 §4.3.3-4 與 T-L11(f) 的文字要改，負向對照要寫明。

9. **`Res.broken` 會記「是 Y」**：driver 必須只在登入成功（簽名之後）才回報 `broken`。握手前的 `End::Broken` 要回報成 `noResponse`（§4.3.3-4 最後兩列）。否則一個攻擊者送一個格式壞掉的 msg2，就能種下「是 Y」。這是 driver 的契約，建議寫進 core.dart 的 `Res` 註解，並在 PR 2 的 driver 測試裡驗。

## 情境走查摘要（其餘沒有問題的）

- 兩台自己的節點冷啟動：第一輪兩台都讀到、3 次握手（T-L11(a)）。✅
- 一台讀到、一台關機、12 個陌生位址、10 筆舊紀錄：Y1 最長間隔 150 s，從不變成不新鮮；Y2 在 691 s 變成連不到。每個陌生位址被握手 11–13 次：每一對最多一次，多出來的是被上限切掉、算沒試過的那幾次。✅（`RB-OK-e`）
- 不回應的攻擊者 + 已知節點：T-L14 成立，R45 證明它有對照。✅
- 7 / 8 / 12 台 + 一個陌生位址 + 換位址：換位址的那台分別在 66 s、62 s 後重新讀到（7、8 台），10 分鐘內每台都是新鮮的；12 台照作者的 T-L21(d)。✅
- 每次讀都回錯誤碼，鎖屏再解鎖：T-H2(f) 成立。✅
- 一個節點兩支手機：沒有出現連不到，但也從來沒有碰撞過（見 M5）。
- 10 支手機：T-L11(j) 通過；它的對照（不記「不是 Y」）有效。✅

## 原始輸出（節錄；全文在 worktree）

```
##### rb_final.out (default sim)            ##### rb_final_real.out (SIM_REAL=1) — identical [RB] lines
7 nodes: all read after 240 s
12 nodes: all read after 820 s
[RB] RB-BUG-1 cuts=6 rounds-with-notFound=6
[RB] RB-BUG-2 earlyCount=3 early rounds after off=0; Y5 連不到 after 330 s
[RB] RB-BUG-3 after BT off/on: kind=Kind.unreachable why=Why.notFound
[RB] RB-BUG-8 back home with BT on: Y1 = Kind.unreachable/Why.bluetoothOff, round active = false
[RB] RB-REPLAY-a reads after rotation=0 state=Kind.unreachable/Why.notFound handshakes on a1n=2
[RB] RB-REPLAY-b reads after replay=0 state=Kind.unreachable/Why.notFound
[RB] RB-REPLAY-c loginFor end=LoginEnd.notFound handshakes=5
[RB] RB-BUG-5 after 不變/被拒/不變: kind=Kind.read view=2' same=2
[RB] RB-BUG-6 roundsRun=2 Y1=Kind.unread
[RB] RB-BUG-7 home targets after the claim: [Y1] / 8.0 round 1 full [Y1]
[RB] RB-CLAIM-0-pre=true loginFor end=LoginEnd.ok (done) handshakes=2
[RB] RB-CLAIM-3-pre=true loginFor end=LoginEnd.ok (done) handshakes=9
[RB] RB-CLAIM-6-pre=true loginFor end=LoginEnd.ok (done) handshakes=12
[RB] RB-CLAIM-10-pre=true loginFor end=LoginEnd.notFound (done) handshakes=12
[RB] RB-CLAIM-RETRY-8 ends: [LoginEnd.notFound@262, LoginEnd.ok@335]
[RB] RB-CLAIM-RETRY-10 ends: [LoginEnd.notFound@262, LoginEnd.ok@335]
[RB] RB-CLAIM-RETRY-12 ends: [LoginEnd.notFound@262, LoginEnd.ok@335]
[RB] RB-T-L16 off=0 noResponse=[0, 0] notFound rounds=0 連不到 seconds=0     (same for off=10..50)
[RB] RB-OK-cold-2 all read after ~30 s; rotated node read again after 90 s; not-fresh node-seconds in 10 min=0
[RB] RB-OK-cold-7 all read after ~240 s; rotated node read again after 66 s; not-fresh node-seconds in 10 min=0
[RB] RB-OK-cold-8 all read after ~270 s; rotated node read again after 62 s; not-fresh node-seconds in 10 min=0
[RB] RB-OK-cold-silent both read after 145 s (reads=(Y1, Y2))
[RB] RB-OK-e Y2 連不到 at 691 s; S0 at 1160 s; Y1 max gap 150 s; handshakes per foreign = [12, 11, 11, 11, 12, 12, 13, 11, 13, 12, 12, 11]
Failing: only rb/rb_scenarios_test.dart (RB-BUG-1,2,3,3b,5,6,7,8, RB-REPLAY-a,b,c, RB-CLAIM-{0,3,6,10}-pre=false (null-check throw), RB-CLAIM-10-pre=true, RB-CLAIM-RETRY-8,10,12)

RB-CLAIM-10-pre=true log:  192.0 loginFor Y2 / 200.0 f0×Y2 -> undecryptable / 205.0 f1 / 210.0 f2 / 215.0 f0 / 220.0 f1 / 225.0 f2 / 230.0 f0 / 235.0 f1 / 240.0 f3 / 245.0 f4 / 250.0 f5 / 255.0 f6 ...
RB-CLAIM-0-pre=false:  Null check operator used on a null value  package:batman_app/src/nodelink/core.dart 630:27  LoginFor.result

##### rb_fix1.out (cut attempt = not tried)
[RB] RB-BUG-1 cuts=6 rounds-with-notFound=0
[RB] RB-BUG-2 earlyCount=0 early rounds after off=1; Y5 連不到 after 220 s
author's 47: all pass (failing list contains only rb/ tests)

##### rb_fix2.out (loginFor: untried addresses before retries)
[RB] RB-CLAIM-3-pre=true loginFor end=LoginEnd.ok (done) handshakes=4
[RB] RB-CLAIM-6-pre=true loginFor end=LoginEnd.ok (done) handshakes=7
[RB] RB-CLAIM-10-pre=true loginFor end=LoginEnd.ok (done) handshakes=11
[RB] RB-CLAIM-RETRY-8 ends: [LoginEnd.ok@262]
[RB] RB-CLAIM-RETRY-10 ends: [LoginEnd.ok@262]
[RB] RB-CLAIM-RETRY-12 ends: [LoginEnd.notFound@262, LoginEnd.ok@335]
author's 47: all pass

##### rb_mutate.out / rb_mutate2.out (author's two test files only) — rules with a FAILING test
R3 refresh keeps 不是            -> T-L11(f) CertRejected, T-L11(g), X2
R4 refresh opens a 2nd round     -> X2
R9 release(written) keeps 是 Y   -> T-L11(g)
R17 沒找到 overrides identity     -> T-L11(f)
R18 還沒輪到 does not trigger     -> X28, T-L21(12)
R19 no cap of 3 early rounds     -> T-L21(12)
R20 early round targets everyone -> T-L11(h), T-L2
R23 30 s window ignored          -> T-L2, T-H2(e), T-L11(f)
R24 no-response not exhausted    -> turns
R25 no-response not last         -> turns
R27 mtime order reversed         -> T-L11(a), T-L11(h), T-L2(e), T-L21(12)
R28 lastRead order reversed      -> T-L21(12)
R32 loginFor budget x10          -> T-L17 control premise
R34 90 s cap ignored             -> T-L2(e)
R35 full timer at 120 s          -> X28, T-L21(12), X2
R37 other page does not block    -> X27, X35
R38 responded never set          -> T-H2(e)
R39 BT on does not start a round -> X7/X8, X31
R41 read does not clear stale    -> T-L3
R42 error code: no 是 Y memo     -> round-12 A-M2
R44 loginFor known not preferred -> T-L18 (both)
R45 known target looks first     -> T-L2(e), round-12 M1 attack, T-L21(12), T-L14
R46 setPage does not cancel      -> X35
R47 background does not cancel   -> T-H2(f), X5/X34
R48 foreground no round          -> T-H2(f), T-L3, X29
R49 node page waits for timer    -> X3
All tests passed (no control): R1 R2 R5 R6 R7 R8 R10 R11 R12 R13 R14 R15 R16 R21 R22 R26 R29 R30 R31 R33 R36 R50
Equivalent (no behaviour change): R40 R43 R51
core.dart restored OK (both scripts)
```

## 給作者的修改清單（全部 MAJOR 都要改；改完請重跑 mutate4 + rb_mutate*.sh + rb_scenarios_test.dart）

1. M1：`setRecords`；T-L17 改成新紀錄由認領加入；刪除節點的測試。
2. M2：上限切掉的嘗試退回成「沒試過」；`RB-BUG-1/2` 進測試。
3. M3：前提原因和身分不符分開；`RB-BUG-3/3b` 進測試。
4. M4：`loginFor` 先試沒試過的位址；§4.3.9 補一句；`RB-CLAIM-10` 進測試。
5. M5：T-L13(a)、T-L16 重寫；上表 22 條規則各補一個測試；mutate 腳本加上 R44、R45 這類對照。
6. MINOR 1–9 依上面的建議處理，並回填設計。
