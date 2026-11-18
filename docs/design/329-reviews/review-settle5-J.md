# 審查 J（第五輪）：設計 `329-ble-settle.md` v4 ＋ 程式 67a1360

範圍：
- 整份設計 v4。
- `git diff a36c383 67a1360`：`ble_gate.dart` 刪掉 `GateLink.failure`；`connect_fail_test.dart` 多 3 個測試、多 1 個斷言。
- 程式核對的基礎沿用第四輪（a36c383），加上這次的差異。
- 負向對照在 scratch worktree `C:/src/Batman-329ra-rJ5`（detached 67a1360）重跑，跑完已 `git worktree remove`：`git worktree list | grep -c rJ` → 0，目錄不存在。

**Verdict：APPROVE。** 沒有 BLOCKER / MAJOR。剩 2 個文字層級的 MINOR（m-1、m-2），可以在下一次 commit 順手改，不需要再審。

## 1. 重跑結果（✅ 原始輸出）

| 跑法 | 結果 |
|---|---|
| 67a1360 原樣，`flutter test test`（全套） | `00:46 +1712: All tests passed!` |
| 67a1360 原樣，`flutter analyze lib test` | `No issues found! (ran in 5.8s)` |
| **NC1b**：只把 `node_link.dart:380`（`_lfAttempt`）改回 `firstWhere((s) => s, orElse: () => false)`，全套 | `connect_fail_test.dart: §2.1 (review 4 I-M1): a flow login (loginFor) also ends a failing connect at once … [E]  Expected: be in range from 1900 (inclusive) to 2500 (inclusive)  Actual: <8000>`，`+1711 -1: Some tests failed.` ✅ 第四輪 MAJOR 已修（a36c383 時同樣的改動全套照樣全過） |
| **NC3**：gate trace 改記完整位址 | 兩個 §2.2 測試都 FAIL（`Actual: ['link AA:BB:CC:DD:EE:01 down fail=133', …]`、`… fail=?`） ✅ |
| **NC3'**（我加的）：保留原本的 `…01` 那行，另外多記一行完整位址，看 MAC 斷言本身會不會抓到 | 兩個 §2.2 測試都 FAIL，原因是 `Expected: false  Actual: <true>  never the full address` ✅。第四輪 m-4 已修：`fail=?` 那個測試現在也是 MAC 斷言抓到的 |

## 2. 第四輪各條的修正核對

| 第四輪 | 67a1360 / v4 | 結果 |
|---|---|---|
| M-1 `_lfAttempt` 沒有測試 | 新增 loginFor 測試：位址 2 s 後失敗 → `loginFor … result=noResponse after ~2000ms`，之後在另一個位址登入成功（`LoginForEnd.ok`），handoff 有關閉 | ✅ NC1b 證明 |
| m-1 `GateLink.failure` 沒人讀 | 欄位和寫入都刪了；§3 也改了 | ✅ |
| m-2 §6 / §8 和實作對不上 | 第 1、2 列和 §8 已改成 gate 那一行、每個帶碼事件記一行、`fail=?` 的條件；§8 寫明「沒有 gate 行 → ❓」；`ReactiveBackend` 那段只靠真機驗證也寫了 | ✅；第 4 列見 m-1 |
| m-3 gate 也記到舊頁、以及連上後才斷的帶碼事件 | §2.2 已寫；「沒有任何帶碼事件的失敗不會有 gate 行」也寫了 | ✅ |
| m-4 commit 的負向對照 / `fail=?` 的 MAC 斷言 | commit message 已列 NC1b；`fail=?` 那個測試加了 MAC 斷言 | ✅ NC3' 證明 |

## 3. 新的測試本身

- **過期 false 的模型**（`staleFalse`）：
  - 假 radio 只在「同一位址、距上次 close 不到 200 ms」時，先在 connect 串流送一個 `false`。這對應 `DeviceConnector.kt:63-75` 的延後合成 DISCONNECTED，以及 I 第三輪的分析。
  - 有兩個測試：(a) NodeLink 自己跑 16 個週期，`staleHits == 0`、同一位址的重試 ≥ 6 s、最後讀到；(b) 直接在 gate 上 0 ms 重連，證明這個假 radio 真的會送出那個 `false`（`(false, 1)`）。這可以避免「(a) 是因為假 radio 根本不會觸發才通過」的情況。✅
- loginFor 測試用的 `LoginProber` 是從 `login_for_test.dart` import 的。在 Dart 裡 import 另一個測試檔的 class 可以用，那個檔的 `main` 不會執行。✅

## 4. 整份設計再看一次

§0–§8 的內容和第四輪相同，只多了上面那些修正。下面幾項我再確認了一次，沒有新的問題：
- 擁有權：gate 是唯一的連結擁有者；`linkStates` 的寫者只有 `ReactiveBackend`，讀者只有 gate。
- 介面：`linkStates` 的三元組契約、8 s 預算的語意。
- 生命週期：失敗、正常連上、同位址快速重連、藍牙關閉、lease、安裝。
- 時間常數只會變短；R-3、R-7、A10 不受影響。
- 安全：log 只有末 2 碼和 1–3 位數字，不參與任何判斷；攻擊者能造成的影響只會變小。
- 真機驗收：至少 3 次自然的 133，不到就判 ❓；有負向對照（`r1_a0`）。

## MINOR（不擋）

- **m-1** §6 第 4 列「同一位址關閉後立刻重連」：「之後」那欄仍寫「以 noResponse 結束」，測試欄仍寫「這次結果 noResponse、core 不顯示『連不到』」。實際測試證明的是另一回事：NodeLink 走不到這條路（`staleHits == 0`、≥ 6 s），而且這個假 radio 在 gate 層確實會送出 `false`。建議照測試改寫這一列：「NodeLink 的輪和 loginFor 都隔 ≥ 6 s，所以走不到；若真的碰到，gate 層第一個事件是 false → noResponse，和今天一樣」。今天那一欄寫「會被 `firstWhere` 忽略」也不精確：串流已經結束，所以是等滿 8 s 後 noResponse。
- **m-2** §2.1 的行號 `:556` / `:379` 現在是 `:557` / `:380`（加了註解那一行）。

## 5. 仍是 ⚠️ 的（設計已標，不是審查發現）

- `ReactiveBackend` 對真 plugin 的轉換、`with status 133` 的訊息格式：要等 §8 的真機步驟。
- 失敗本身的根因：要 btsnoop，已在 #329 的清單裡。
