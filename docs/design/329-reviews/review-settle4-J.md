# 審查 J（第四輪）：設計 `329-ble-settle.md`（a36c383 版）＋ 實作 a36c383

範圍：整份設計、`git show a36c383` 的程式與測試、`app/test/nodelink/connect_fail_test.dart`。負向對照全部在我自己的 scratch worktree `C:/src/Batman-329ra-rJ`（detached a36c383）重跑，跑完已經 `git worktree remove`（`git worktree list` 裡沒有 rJ，目錄也不在了）。沒有碰手機和節點。

**Verdict：APPROVE-WITH-CHANGES。**
- 程式行為和設計 §2 一致。我 v3 的 MAJOR（帶碼的失敗事件在 close 之後才到）真的修好了，負向對照也重現了。
- 開放項目有 **1 個 MAJOR**：`_lfAttempt`（流程登入）那一半的改動沒有任何測試守著，我實際改回舊寫法，全套 1709 個測試照樣全過。
- 其餘是設計文字和測試對不上的 MINOR。補一個測試、改幾句文字就能收，不必重審。

---

## 1. 我重跑的結果（✅ 原始輸出）

| 跑法 | 結果 |
|---|---|
| a36c383 原樣，`flutter test test/nodelink/connect_fail_test.dart` | `00:00 +6: All tests passed!` |
| a36c383 原樣，`flutter analyze lib test` | `No issues found!`（整個 app 目錄跑 `flutter analyze` 會有 115 個問題，都在 `rust_builder/cargokit`，不在這次改動的範圍） |
| **NC1** `node_link.dart` 兩處都改回 `firstWhere((s) => s, orElse: () => false)` | `§2.1 … [E]  Expected: be in range from 1900 (inclusive) to 2500 (inclusive)  Actual: <8000>`。全套 `test/nodelink test/flows` 跑出 `+411 -1`，只有這一個失敗 ✅ |
| **NC1b** 只把 **:380（`_lfAttempt`）** 改回 `firstWhere`，`:557` 不動 | **全套 `flutter test test` → `01:09 +1709: All tests passed!`** ❌（見 M-1） |
| **NC2** gate 只在連結還在表上時記錄（`if (f != null && _links.any((l) => l.address == e.$1))`） | 兩個 §2.2 測試都失敗：`Expected: contains 'link …01 down fail=133'  Actual: []`、`… fail=?  Actual: []` ✅（我 v3 MAJOR 的負向對照成立） |
| **NC3** trace 改記完整位址（`'link $a down …'`） | 兩個 §2.2 測試都失敗 ✅。⚠️ 其中 `fail=?` 那個是因為字串整個不同才失敗，不是 MAC 斷言抓到的；有 MAC 斷言的只有 `fail=133` 那個 |
| **探針** 藍牙關閉那個測試，在 `nl.radio(bluetooth:false)` 之前印出 trace | `PROBE before-off: [attempt …01×Y1 connected=-1ms result=noResponse after 2000ms] core=Kind.unread`：失敗確實比藍牙關閉先記進 core，所以這個測試走的是新的競態路徑，不是舊的 `_abort` 路徑 ✅ |

## 2. 測試有沒有照 plugin 的真實事件順序（✅ 讀 `FailRadio`）

- connect 串流的 `false`（非同步 controller，下一個 microtask 才送到）和**不帶碼**的 `(addr,false,null)`（`sync: true`）在**同一個任務**裡送出。帶碼的兩筆用兩個 `Timer(Duration.zero)` 送，也就是**之後的 event-loop 任務**。這和 I-M1 / 我 v3 的分析一致：E1 不帶碼、E2/E3 帶碼，是三則不同的平台訊息。
- 另一種順序（E1 是 CONNECTING，被濾掉，所以第一個就是帶碼的）沒有測。但 gate 不論連結在不在都會記錄，這種順序不會改變結果。可以接受。
- `ReactiveBackend`（真正接 plugin 的那一層）沒有單元測試。`failureCode` 有直接測，`failure?.message` 也符合 `GenericFailure.message` 的型別。⚠️ 訊息格式 `with status 133` 仍然要真機確認一次（§5 已經寫了）。

## 3. 程式碼對設計

| 設計 | 程式 | 結果 |
|---|---|---|
| §2.1 第一個事件；`first` 外面包 `onError → false` | `node_link.dart:380`、`:557` `state.first.then((s) => s, onError: (Object _) => false)` | ✅（close 時的 `StateError` 會變成 `false`，trace 不會多一行例外） |
| §2.2 gate 對每個帶碼事件記一行，不管連結還在不在 | `ble_gate.dart` `_states` listener：`if (f != null) trace('link …XX down fail=N')`，`-1` 記成 `?` | ✅ |
| §3 `linkStates` 改成 `(String, bool, int?)`、寫者只有 `ReactiveBackend`、讀者只有 gate | ✅；6 個假 backend 都改了 | ✅ |
| §3 `GateLink.failure`「讀者只有測試」 | `l.failure ??= f`。**沒有任何測試讀它**（grep `connect_fail_test`），等於沒用的欄位 | 見 m-1 |
| §7 只記末 2 碼、只記數字、不參與任何判斷 | ✅ | ✅ |

## 4. 我之前的各條

| 之前的發現 | 現況 |
|---|---|
| v2 M-1 驗收會空過 | §8：至少 3 次，不到判 ❓ ✅ |
| v3 MAJOR 碼在 close 之後才到 | 已修，NC2 證明 ✅ |
| v3 m-a 不預先寫撤回機制 | §6 已定案為不加，測試有斷言，探針證明走到新路徑 ✅ |
| v3 m-b 6 個假 backend | ✅ |
| v3 m-c MAC 的負向對照 | ✅（NC3；附註見上表） |
| v3 m-d 不用裸的 `.first` | ✅（有包 `onError`） |
| v3 m-e 別的頁面的失敗也會被記到 | 程式會記（gate 聽的是全域串流），設計沒寫，見 m-3 |
| pid 註記 | §1 B 已改成「本檔（到 07:57:49）期間」 ✅ |

---

## MAJOR

**M-1 `_lfAttempt` 的改動沒有回歸測試：改回舊寫法，全套照樣全過。**
- 情境：流程登入（R-7「正在連到節點…」、§6 的各個操作、net run、多台加入、8.4 換鑰匙）碰到 133 時，應該在失敗的那一刻結束。這是這次修正一半的使用者價值。
- 證據：NC1b，`node_link.dart:380` 改回 `firstWhere`，`flutter test test` 跑出 `+1709: All tests passed!`。commit message 寫的「firstWhere back -> the 2 s test fails」只對 `_run` 成立。
- 修：在 `connect_fail_test.dart` 加一個 `loginFor` 的測試。先 `acquire` 一個 lease，再 `loginFor('Y1')`，那個位址 2 s 後失敗。斷言 trace 的 `loginFor … result=noResponse after ~2000ms`（不是 8000），而且下一次嘗試的時間 ≥ 失敗 + 6 s（`core.dart:694`）。負向對照：只把 `:380` 改回 → FAIL。commit message 也要補上這一條。

## MINOR

- **m-1 `GateLink.failure` 沒人讀。** 依「只做必要修改」，刪掉這個欄位；或者寫一個測試讀它。刪掉比較乾淨：失敗碼只靠 gate 那一行 log。§3 跟著改。
- **m-2 §6 的文字和實作對不上：**
  - 第 1 列寫「trace `fail=133`」，實際是 gate 的 `link …XX down fail=133` 那一行。
  - 第 2 列寫「取第一個**帶碼**的；都沒有 → `fail=?`」，實作是每個帶碼事件記一行（一次失敗通常兩行）。**完全沒有帶碼事件時什麼都不記**，`fail=?` 只出現在訊息裡沒有 `with status` 的時候。
  - 第 4 列描述的測試（失敗後 200 ms 內同一位址重連、backend 先送一筆延後的不帶碼 false），實作沒有。現有的 §6 測試只驗了「≥ 6 s 才重試」，也就是靠 `gap` 讓這條路走不到。
  - 修：照實作改寫這三列。第 4 列寫成「NodeLink 的輪靠 `gap` 走不到；`loginFor` 那條路（I v2 指出的那條）若真的碰到，結果是 noResponse，和今天一樣；測試 = gap 測試」。或者補上那個測試。
  - §8 真機判準的「trace 的 `fail=`」也改成「gate 那一行的 `fail=`」。
- **m-3 gate 那一行不只記 NodeLink 的連線。** 它聽的是全域的 `connectedDeviceStream`，所以舊頁（ClaimPage、`claim_recovery`、`nodes.dart`、`scan.dart`，PR 6 會刪）的連線失敗也會被記到；**連上之後才斷掉**的帶碼事件也一樣（RxAndroidBle 在連線中斷時會送 `BleDisconnectedException`，經 `onErrorReturn` 變成 `ConnectionUpdateError`，例如 status 8）。這兩種都無害，而且是有用的資訊。§2.2 寫一句：「`down fail=N` 是任何連結帶碼的中斷，不只是 connect 失敗；真機對照時用 attempt 行的時間去配對」。
- **m-4 commit message 的負向對照列表**要補上 M-1 那一條。NC3 那條（完整位址 → 兩個都失敗）要註明 `fail=?` 那個是因為字串不同才失敗、不是 MAC 斷言抓到的；或者把 MAC 斷言也加進 `fail=?` 那個測試。

## 5. 安全

和 v3 相同，同意。新的 log 行只有末 2 碼加 1–3 位數字，由本機協定堆疊產生，遠端控制不了。一次失敗記兩行：每個位址每輪最多 2 次嘗試、一輪最多 90 s，所以 log 量有上界。✅

## 6. 生命週期

v3 已列的各列我都核對過。沒有新的缺項；新增的「舊頁失敗也會記一行」屬於 m-3，只影響 log。
