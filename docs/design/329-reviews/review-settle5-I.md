# 審查 I（第五輪）：設計 `329-ble-settle.md` v4（整份）＋ 程式 67a1360

唯讀審查。負向對照是在臨時 worktree `C:/src/Batman-329ra-rI`（detached 在 67a1360）裡自己重跑的，跑完已經 `git worktree remove`，`git worktree list | grep -c rI` 回 0。

**判定：APPROVE。** 沒有 BLOCKER，也沒有 MAJOR。有 2 個 MINOR，可以在 PR 裡順手改，不用再審。

---

## 上一輪（第四輪）的問題逐項核對

| 第四輪的問題 | 67a1360 怎麼改 | 結果 |
|---|---|---|
| M1：`loginFor`（`_lfAttempt`）沒有測試 | 新增測試「a flow login (loginFor) also ends a failing connect at once」 | ✅ 只把 `:380` 改回 `firstWhere`，這個測試 FAIL，`Actual: <8000>`（下面 NC1） |
| m1：§6 第 3 列沒有測試 | 新增兩個測試：NodeLink 不會在 200 ms 內重連（`staleHits 0`）；假 radio 本身在 200 ms 內確實會送出延後的 false | ⚠️ 有了，但第一個測試證明的不是它名稱寫的那件事，見下面 n1 |
| m2：`GateLink.failure` 沒有讀者 | 刪掉了（欄位和寫入那一行） | ✅ |
| m3：開頭還寫 v3、§6 第 2 列不準 | 開頭改成 v4；§6 第 2 列改成「每筆帶碼的事件記一行，一次失敗通常兩行」 | ✅ |
| m4：真機驗收要搜 `BMAPP gate` | §8 改成用「同一時間附近的 gate 行」對照，「沒有 gate 行 → 那一項 ❓」 | ✅（腳本要記得加上 `BMAPP gate`，見 n2） |
| m5：`ReactiveBackend` 的對應只靠真機驗 | §8 寫明了 | ✅ |

## 我自己重跑的結果（✅ 有原始輸出）

| 情況 | 結果 |
|---|---|
| 基線：`connect_fail_test.dart` | `+9: All tests passed!` |
| 基線：全套 `flutter test test/` | `+1712: All tests passed!`（和 commit message 一致） |
| `flutter analyze lib` 加上新的測試檔 | `No issues found!` |
| **NC1：只把 `node_link.dart:380`（`_lfAttempt`）改回 `firstWhere`** | `§2.1 (review 4 I-M1): a flow login … [E] Actual: <8000>`，`+8 -1` → **FAIL**。上一輪的缺口補上了 |
| NC2：只把 `:558`（`_run`）改回 `firstWhere` | `§2.1: a failing connect … [E] Actual: <8000>` → FAIL |
| NC3：gate 只在連結還在表上時才記失敗碼 | 兩個 log 測試 `[E]`，`+7 -2` → FAIL |
| NC4：把 core 的同位址間隔 `gap` 從 6000 改成 100 | `+9: All tests passed!` → **沒有測試抓到**，見 n1 |

測試確實照 plugin 的真實順序送事件：connect 串流的 false 和不帶碼的事件在同一個 task；兩筆帶碼的事件各用一個 `Timer(Duration.zero)`，排在後面的 event-loop task。新加的 `onCancel` 會送 `(addr,false,null)`，對應 plugin 在取消連線時自己合成的 DISCONNECTED。✅

## 設計和程式對照（整份重看）
- §2.1：兩處都改成等「第一個事件」（`:380`、`:557`）。各自都有一個測試守著，負向對照 NC1 / NC2 都會 FAIL。✅
- §2.2 和 §3：
  - gate 收到帶碼的事件一律記一行，不管連結還在不在表上；
  - 只記位址末 2 碼和數字；
  - `linkStates` 的型別、寫的人（`ReactiveBackend`）、讀的人（`BleGate`）都對；
  - 舊頁面和「連上之後才帶碼斷線」的事件也會被記到，§2.2 有寫明。

  ✅
- §4 時間常數只會變短；§5 依賴的證據和前幾輪核對的一樣；§7 安全沒有新問題。✅
- §6 藍牙關閉那一列，以及 §8 至少 3 次自然失敗、湊不到就 ❓。✅

## MINOR

- **n1. 「NodeLink 不會在 200 ms 內重試同一位址」那個測試，證明的其實是別的東西。**
  - 我把 `Params.gap` 改成 100 ms（NC4），測試照樣全過。
  - 原因：測試裡的位址從來沒有成功讀到過，所以 core 沒有把它記成「是 Y」。這種位址 `noResponse` 之後直接被標成這一輪用完（`core.dart:479` 的 `r.exhausted.add`），要等下一輪才會再連。所以「≥ 6 s」和 `staleHits 0` 是輪的結構造成的，不是 6 s 間隔造成的。
  - §6 第 3 列的結論（沒碰到過期的 false、下一次讀得到）仍然成立，只是**真正會在同一輪重試的路徑**沒有被守住。那條路是：一個已經是「是 Y」的位址 noResponse 之後被放進 `retry`（`core.dart:476-477`），這時候是 6 s 間隔在防止它太快重連。
  - 建議：先讓這個位址成功讀一次，變成「是 Y」，再讓它失敗、打開 `staleFalse`。這樣 NC4（`gap = 100`）就會 FAIL。
  - 另外，`loginFor` 的 `freeAt` 是每個 LoginFor 物件各自一份（`core.dart:650`）。「一輪剛對 X 失敗，使用者 200 ms 內就按了操作」這條跨物件的路徑，第二輪我說過「可能但很窄，結果和今天一樣」。可以在 §6 那一列加一句。
- **n2. §8 只寫了「gate 行」，沒寫實際的搜尋字串。**
  - 真機收 log 的腳本必須搜 `BMAPP (nl|gate)`。之前的 f22 和 ab 腳本只搜 `BMAPP nl`。
  - 依 §8 的規定，漏搜就會變成「沒有 gate 行 → ❓」，不會被當成通過。所以不會誤判，只是會白跑一次。
  - 建議在 §8 寫出搜尋字串。

## 驗證分類
- ✅ 有原始輸出：基線 9/9、全套 1712、analyze 乾淨、NC1 / NC2 / NC3 FAIL、NC4 全過（n1）、worktree 已移除。
- ⚠️ 推論：n1 裡對 core 路徑的說明是讀程式得出的（`core.dart:472-480`），沒有另外寫測試證明。
- ❌ 沒做：沒上機（§8 的真機項目還沒跑）。
