# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ e2292f0）第二輪程式審查：審查 C

審查者 C 是獨立審查。這一輪看整個 PR（core.dart 只看新程式有沒有用錯它），重點放在生命週期與並行。程式碼用
`git -C C:/src/Batman-329pr1 archive e2292f0 app` 匯出到 scratchpad `core/pr1C/`。worktree 沒有動，也沒有 commit。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、1 MAJOR、6 MINOR。

同一時間只有一個藍牙使用者、紀錄改動會被回報、單一 8 s 期限、前提條件的覆蓋層，這些規則在 `NodeLink` / `BleGate` /
`Lease` 這一層都成立，而且都有測試守著（下面 X1–X11 改壞全部 FAIL）。剩下的問題是：第一輪兩個 MAJOR 的修正真正落在
**舊頁面與 app 接線**上，這一層任何一行改壞，全套 397 個測試照樣全過（C-M1）。另外有一個開著的小窗口：頁面已經放掉佔用，
但還在 mounted 狀態，這時開始的工作不持有佔用（C-m2），而 `RawBusy` 在這種情況下會照樣往下做（fail-open）。

## 基準

| 項目 | 結果 |
|---|---|
| `flutter test --no-pub`（全套，e2292f0 匯出） | ✅ `00:20 +397: All tests passed!` |
| `flutter test --no-pub test/nodelink` | ✅ `00:07 +184: All tests passed!` |
| 第一輪負向對照 RA-1–RA-5、RB-1–RB-5（已收進 review_pr1_test / prober_test） | ✅ 在 e2292f0 PASS。對應的規則我自己改壞（X1–X11）會 FAIL，見下表 |

### 我自己做的改壞對照（一次只改一處，跑 `test/nodelink`；檔案 `pr1C/mut-*.txt`）

| # | 改壞 | 結果 |
|---|---|---|
| X1 | `released`：拿掉「另一個佔用已拿走 → 不解除核心佔用」的分支 | FAIL（RA-5） |
| X2 | `nodeLinkToken` 永遠給目前的憑證 | FAIL（RA-5） |
| X3 | `_pump` 不等 `gate.links == 0` | FAIL（RB-3） |
| X4 | `Lease.hold` 不加計數 | FAIL（3 個） |
| X5 | 連線不跟 `due` 賽跑 | FAIL（8 s 測試） |
| X6 | GATT 不檢查憑證 | FAIL（B-m5） |
| X8 | 原始佔用的紀錄差異不算寫入 | FAIL（RA-2） |
| X10 | 核心取消後不 `_abort` | FAIL（2 個） |
| X11 | gate 釋放時不關閉遺留的連線 | FAIL |
| X14 | 登入結束 4 一律當 EForbidden | FAIL |
| X15 | row 2' 當成讀到 | FAIL |
| **X9** | 拿掉 `_writtenWaiting.clear()` | **PASS（沒有測試能抓到）** |
| **X12** | 拿掉 `_writtenWaiting.addAll(written)`（A-M5 修正的後半段） | **PASS** |
| **X13** | `openRecord` 失敗時不呼叫 `keyCheck` | **PASS** |
| **X16** | 不記 `readWall` | **PASS**（作者已註明沒有測） |

### 接線層的改壞（跑全套 397）

| # | 改壞 | 結果 |
|---|---|---|
| CM1b | `NodesPage.rawUse => null`（頁面忙的時候不持有佔用，也就是 A-M1 / B-M1 修正前的行為） | **All tests passed!** |
| CM2b | `ClaimPage.rawUse => null` | **All tests passed!** |
| CM9 | `ScanPage.rawUse => null` | **All tests passed!** |
| CM3 | main.dart `_open` 不呼叫 `lease.pageGone()`（打開任何舊頁面一次之後，自動讀取永遠停掉） | **All tests passed!** |
| CM4 | nodes.dart 拿掉「頁面離開後才登入成功 → `_drop()`」 | **All tests passed!** |
| CM5 | AppLink 不把 `statusStream` 接到 `link.radio` | **All tests passed!** |
| CM6 | 不把 prober 的 `keyError` 接到 `radio(keyOk: false)` | **All tests passed!** |
| CM7 | 啟動時不傳 `keyOk: keys.login` | **All tests passed!** |
| CM8 | `rawScanStarted()` 變成什麼都不做 | **All tests passed!** |

（CM1 的第一個版本把 `_busy` 改回一般欄位，結果 6 個測試 FAIL。原因是那個改法讓 `_busy` 永遠不會變回 false，屬於改壞的方法錯了，
不算守住；所以改用 CM1b，只拿掉佔用。）

## 發現

### MAJOR

**C-M1：第一輪 A-M1/B-M1 與 A-M3/B-M5 的修正真正生效的那幾行（舊頁面、main.dart、AppLink），任何一行改壞，全套測試照樣全過**

- 情境：修正分兩層。
  - 機制層：`Lease.hold`、`RawBusy`、`NodeLink.radio`、`bleStatusToRadio`。這一層有測試。
  - 接線層：三個頁面的 `rawUse`；`_open` 的 `pageGone`；nodes.dart:399-402 的 `_drop`；app_link.dart:55-57 與 :86-89；main.dart:264。這一層沒有任何測試。

  上表 CM1b–CM9 每一項都把使用者會碰到的行為改回第一輪的 bug，全部 397 PASS。舉例：
  - CM2b：認領中按返回，佔用立刻放掉，自動讀取和認領同時用藍牙。這正是 A-M1 本身。
  - CM3：打開「我的節點」一次之後，首頁清單永遠不再更新。
  - CM5：藍牙關掉之後顯示「手機連不到節點」，而不是「藍牙沒有打開」。這正是 A-M3 / B-M5 本身。
- 證據：上表，原始輸出在 `pr1C/mut-CM*.txt`，每一個的最後一行都是 `All tests passed!`。
  - pr1-changes.md 把 A-M1 的守衛寫成 `A-M1: an older page that is gone while busy…`。那個測試用的是測試檔自己的 `_Busy` 小部件（review_pr1_test.dart:357-369、:430-447），不是 `ClaimPage` / `NodesPage`。
  - 第一輪 A 的要求是「在假的認領進行中 pop `ClaimPage`」。B 的要求是「pushes ClaimPage with a fake claim … pops it」。兩者都沒有做。
  - `T-L5` / `RA-3` 測的是 `bleStatusToRadio` 與 `NodeLink.radio`，不是 `AppLink` 有沒有把兩者接起來。
- 為什麼是 MAJOR：這是宣稱已修好的 MAJOR，但守它的測試在真正的修正被拿掉時不會 FAIL（全域規則「每個修正要有負向對照」）。
  接線層正是 PR 2 / PR 3 會重寫、最容易被改壞的地方。
- 修法（不必大改）：
  1. 一個 widget 測試：`ClaimPage(ble: <fake>, use: RawUse(lease, gate))`，讓 `_claim` 卡在假的連線上，然後 pop。斷言 `reg.current` 仍然是這份佔用、NodeLink 7 s 內沒有掃描；把工作結束後，佔用釋放。NodesPage 的 `_login` 也一樣做一次。現有的 `claim_flow_test` / `nodes_*_test` 已經有假的 BLE 可以重用。
  2. 把 `_open` 抽成一個可以測的函式（或在 `StartupCheck` 測試裡注入 `makeLink`），測「pop 之後 `pageGone` 被呼叫」。
  3. `AppLink.create` 把 `statusStream` 與 `keyError` 的接線抽成 `wire(NodeLink, Stream<BleStatus>)` 之類的函式，測 poweredOff 會變成 `Why.bluetoothOff`。
  4. 每一項附 CM1b / CM2b / CM3 / CM5 / CM6 的負向對照。

### MINOR

**C-m1：B-m2「紀錄用完歸零」不完整。Keystore 在嘗試被取消之後才回來的紀錄明文，永遠不會歸零**

- 情境：換頁、拿佔用、背景、cap 截斷，都會在 `openRecord`（StrongBox 解密，數百 ms）進行中取消嘗試。
  - `probe` 的 `finally` 先跑。這時 `record` 還是 null（prober.dart:146-154）。
  - 接著 `work()` 拿到 `r`，執行 `record = r`（:122），看到 `result.isCompleted` 就 return（:123）。明文留在 Dart heap，直到 GC。
- 證據：我寫的 `pr1C/review_r2c_test.dart` `C-1`，在 e2292f0 上：`Expected: every element(<0>) Actual: [7, 7, 7, 7, 7, 7, 7, 7]`。
  把 :122 後面加上 `if (result.isCompleted) r.fillRange(0, r.length, 0);` 之後，這個測試 PASS，`test/nodelink` 全部 186 個 PASS。
- 修法：就是上面那一行，再加上這個測試。

**C-m2：pop 的時候，`Navigator.push` 的 future 先完成，頁面要等轉場動畫結束才 dispose；這段時間開始的忙碌工作沒有佔用，而 `RawBusy` 照樣往下做（fail-open）**

- 情境：main.dart:200-201 在 push 回來的同一個 microtask 就呼叫 `pageGone()`。頁面閒著就立刻釋放。這時頁面還是 `mounted`（約 300 ms 轉場）。
  - 頁面自己的後續程式在這段時間設 `_busy = true`，例如：
    - `_joinNetwork` 在選網路的對話框之後先 `rawIdle()`，再等 `publicKeys`，然後 `_ask` 用 `if (mounted) setState(() => _busy = true)`（nodes.dart:519）；
    - `_login` 剛好在 pop 的瞬間成功，`ok && !mounted` 是 false（還 mounted），接著 `_ask` 繼續送 join。
  - 這時 `hold()` 丟出 `StateError`，raw_use.dart:166-171 把它吞掉，`_rawHold = null`，工作照樣送出請求。NodeLink 6 s 後恢復自動讀取。
  - NodesPage 的這段工作會在 dispose 的 `_drop()` 時被切斷，所以窗口只有約 300 ms 加上一個請求。
  - ClaimPage 的工作都在按鈕當下就設 busy，轉場期間不會收到點擊，所以 ClaimPage 不受影響。
- 證據：`review_r2c_test.dart` `C-2` 用真的 `MaterialPageRoute`：pop 之後 `mountedAtGone == true`，`rawBusy = true` 時沒有例外，`reg.current == null`，所以測試 FAIL（`Expected: false Actual: <true>`）。
  把 raw_use.dart:170 改成 `_rawBusy = false; rethrow;`（fail-closed）之後，這個測試 PASS，既有測試全部 PASS。
- 修法：二擇一或兩者都做。
  1. `RawBusy` 在拿不到佔用時丟出例外，讓工作停下（fail-closed，和 §8「預設 fail-secure」一致）。
  2. 把 `pageGone()` 移到 `RawBusy` 的 `dispose()`，也就是頁面真的卸載之後，而不是 push 的 future 一完成就呼叫。

**C-m3：420 s 收回時的待辦「上一個操作可能沒有存完」在 PR 1 沒有任何畫面顯示，PR 說明卻寫「之後收回並在首頁列待辦」**

- 證據：`grep -rn unsavedTodos lib` 只有 lease.dart:102 與 :133。`StartupCheck` / `NodeStatusList` 都沒有讀它。
- 影響：舊頁面的工作在 PR 1 的上限內都會結束（見下面的 PopScope 判斷），所以實際上很難走到收回這一步。但如果真的走到，使用者完全看不到，PR 說明的描述也不正確。
- 修法：在啟動檢查頁的最小清單上方顯示 `reg.unsavedTodos`，加上「知道了」；或者把 PR 說明改成「PR 2 首頁才顯示」。

**C-m4：A-M5 修正的後半段、`keyError` 的 `openRecord` 路徑、`_writtenWaiting.clear()` 沒有測試**

- X12：等待中的寫入 id 被丟掉。結果是重新認領後「身分不符」不會結束，不過要在讀紀錄的幾 ms 內又拿走佔用才會發生。
- X13：`RECORD_AES` 被金鑰閘門拒絕時，不會顯示 2.4。
- X9：每一次釋放都重新套用舊的寫入 id，`writtenAt` 一直被刷新，N9 例外會一直延長。
- 三個改壞都 PASS（見基準表）。
- 修法：各補一個測試。RA-5 的測試多斷言「第二個佔用釋放之後，`writtenAt['Y1']` 有值」，並斷言再一次釋放不會再改它；prober 的 B-M5 測試加一個 `openRecord` 丟出 `keyLevel` 的情況。

**C-m5：ClaimPage 不加 `PopScope`（刻意的偏離）：佔用的範圍可以接受，但使用者看不到結果**

- 判斷：pop 之後認領還能跑多久，我逐段算過：
  - `_find` 最多 60 s，加上一次 20 s 連線與一次狀態讀取（讀取沒有 Dart 端逾時，靠 Android GATT 約 30 s）；
  - 加上 90 s 等節點回應；
  - T1 恢復在 `!mounted` 時不啟動（claim.dart:452-456）；
  - 已經開始的恢復被 `dispose` 取消，寫入之後最多再等 90 s。

  總共大約 300 s 以內，在 420 s 之下。所以「同一時間一個藍牙使用者」在 ClaimPage 這邊成立，偏離本身是安全的。
- 但使用者會碰到兩件事：
  - 認領結果（`[CLAIMED]` / `[CLAIM_FAIL]`）說給一個已經不在的頁面聽，使用者不知道成功了沒有；
  - 接下來幾分鐘，按任何舊頁面都只得到「另一個操作還在進行：新增節點」，而且沒有進度。

  設計當初要 `PopScope`，就是為了「認領不會在沒有頁面的情況下跑完」。
- 修法（可留到 PR 3，但請寫進 #329 的 checklist）：至少讓首頁在佔用被沒有頁面的工作持有時，顯示「認領還在背景進行」；或者 pop 時用 SnackBar 告知。

**C-m6：`NodeLink.dispose` 沒有收掉進行中的掃描啟動與登記表的監聽（只有測試會走到）**

- `_dropAll` 只停 `_scan`。如果 `_startScan` 正在 gate 的掃描名額等待中（最多 30 s），dispose 之後它還會回來，執行 `if (s.open) _scan = s;`（node_link.dart:227）。`_pump` 因為 `_disposed` 直接 return，所以這個掃描不會被停掉。
- `reg.listeners` 從來沒有移除 NodeLink 或 BleGate。
- 正式版的 `AppLink` 是單例，從不 dispose，所以使用者碰不到。
- 修法：dispose 時讓 `_startScan` 拿到結果後檢查 `_disposed` 並 `stop()`，並從 `reg.listeners` 移除自己。

## 生命週期（端到端，依 §7）

| 路徑 | 現在的行為 | 證據 |
|---|---|---|
| App 啟動 | 啟動檢查通過 → `make` → `radio(keyOk)` → `start` 讀紀錄 → 首輪。`statusStream` 第一個事件 `unknown` 會被忽略；500 ms 後的真狀態接上 | main.dart:260-270、app_link.dart:86-101 |
| `start` 失敗 | 結果留在畫面上；`_app` 是 null，所以舊頁面不拿佔用（NodeLink 沒有啟動，`_eligible` 要求 `started`，core.dart:161），不衝突 | main.dart:184-188 |
| 背景 / 前景 | hidden / paused → 取消一輪並斷開連線；resumed → 立刻一輪；inactive（權限對話框、生物辨識）不算 | node_link.dart:100-109、T20、X10 |
| 舊頁面開著時被 pop | 閒著 → 立刻釋放（但見 C-m2 的轉場窗口）；忙著 → 撐到工作結束 | lease.dart:58-81；C-M1：頁面層沒有測試 |
| 420 s 收回 | 登記表收回 → NodeLink 讀紀錄，6 s 後一輪。舊頁面不走 gate，收回之後它還在跑的工作擋不住（PR 已經寫明）。實際上照 C-m5 算出的時間到不了 420 s；待辦不顯示（C-m3） | lease.dart:129-138 |
| 藍牙關 / 開 | 有 `poweredOff` → 立刻 2.3、取消一輪、斷開；有 `ready` → 一輪。掃描錯誤 → `ended` → 2 s 後重試 | RA-3；接線見 C-M1 / CM5 |
| 權限被收回 | Android 會殺掉 process；重開之後第一個狀態是 `unauthorized` → 2.2。RxAndroidBle 的 `observeStateChanges` 會一直等到權限給了才送 READY（reactive_ble_mobile-5.6.0 ReactiveBleClient.kt:270-273），所以舊頁面要到權限之後清單會自己恢復。⚠️ 沒有實機驗證 | — |
| 金鑰被拒 | 登入 sign 被拒 → 2.4，直到 app 重開；`openRecord` 被拒這條路徑沒有測試（C-m4 / X13） | prober.dart:76-82、:115-120 |
| 讀紀錄期間拿到佔用 | 核心維持佔用，寫入的 id 等下一次釋放（X1 / X2 守著；後半段 X12 沒守，C-m4） | node_link.dart:150-156 |
| 嘗試中途連線、被取消 | `_abort` 關掉連線；晚回來的 `_run` 只關自己的連線；下一次嘗試等連線消失 | RA-1、RB-3、X3 |
| 正在 Keystore 時被取消 | 嘗試立刻結束（M9），但紀錄明文沒有歸零（C-m1） | C-1 |
| dispose | 正式版不會走到；測試路徑有一個漏收的掃描（C-m6） | — |
| ⚠️ 假設 | 一次從沒連上就被取消的連線，`connectedDeviceStream` 會不會送出 disconnected？如果不送，每次「沒有回應」都多等 5 s（`closeMax`）才進下一次嘗試。M-1 只量過已連上之後的斷線（3–14 ms）。請在 B 組真機場次量 | ble_gate.dart:107-122 |

## 安全（逐個角色）

- **附近的惡意 BLE 裝置**：
  - 它可以廣播 provd UUID，吸走嘗試次數（核心的每位址上限限制住）；
  - MTU 或 GATT 卡住，受 8 s 單一期限限制（RB-4 / X5）；
  - 送垃圾 frame，結果是 `failed()`，也就是 noResponse / broken。
  - 簽章只在 msg2 解得開之後才會發生，它拿不到 owner 簽章。
  - 登入結束 3 / 4 只在 msg2 解開之後出現，它也無法讓 app 顯示「身分不符」或「拒絕」。
  - prober 不寫任何紀錄（default 分支就放棄這台節點）。沒有新的洞。
- **其他 app**：共用 Android 的藍牙堆疊，這部分沒有改變。
- **被攻陷的節點**：手上有紀錄金鑰，可以回任何狀態顏色。但這本來就是它自己的狀態；它無法讓 app 寫入或簽其他東西。
- **我們自己的錯**：
  - 接線層沒有測試（C-M1）；
  - `RawBusy` fail-open（C-m2）；
  - 明文沒有歸零（C-m1）。
  - log 只記 step 種類與生命週期，沒有紀錄內容或簽章（prober.dart:106、app_link.dart:109）。

## 我寫的東西（都在 scratchpad，沒有 commit）

- `scratchpad/core/pr1C/review_r2c_test.dart`：C-1、C-2 兩個負向對照。放進 `app/test/nodelink/` 就能跑；兩個在 e2292f0 都 FAIL；套上 C-m1 / C-m2 的修法之後，`test/nodelink` 全部 186 PASS。
- `scratchpad/core/pr1C/mut-*.txt`：每一個改壞的完整輸出。
