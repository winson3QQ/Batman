# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 75683ab）程式審查 — 審查 A

審查對象：排程核心以外的全部：`lease.dart`、`record_writer.dart`、`ble_gate.dart`、`ble_backend.dart`、`node_link.dart`、`prober.dart`、`app_link.dart`、`node_list.dart`、`main.dart` / `scan.dart` 的改動、`owner.rs` 的 `login_end` / `login_code`、這些檔案的測試，以及 PR 說明裡的「和設計不同的地方」。
重點：擁有權、契約、生命週期矩陣、PR 說明列出的偏離、測試改壞會不會 FAIL。

做法：把 `app/` 複製到 `scratchpad/core/pr1A/app`（不動 `C:/src/Batman-329pr1`），先確認基準，再照真實使用寫情境測試（`test/review/review_a_test.dart`、`review_a5_test.dart`），最後一次只改壞一條規則，跑對應的測試。

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER、5 MAJOR、11 MINOR。MAJOR 全部修完、整份再審之前不合併。

- **A-M1** 舊頁面的原始佔用在頁面關掉時就釋放，但 `ClaimPage` 的認領在頁面關掉後照樣跑（掃描、連線、寫紀錄）。PR 說明「仍然只有一個藍牙使用者、一個寫入者」不成立。
- **A-M2** 舊頁面寫的紀錄沒有回報給佔用（`writtenNodes` 永遠是空的）。重新認領一台「身分不符」的節點之後，紅色的「身分和手機記錄的不同」會一直留著；剛認領完的 N9 例外也不會生效。
- **A-M3** 藍牙、權限、金鑰這三個前提沒有接上（`NodeLink.radio()` 沒有任何呼叫者），掃描錯誤也沒有處理。藍牙關著時，畫面兩輪後顯示「手機連不到節點：可能沒開機…」，不是「藍牙沒有打開」。
- **A-M4**「從開始連線到收到 msg2 最多 8 s」沒有從頭算到尾。MTU、ctrl 讀取、開紀錄都沒有期限，一個不回 MTU 的假裝置可以把一次嘗試拖到藍牙協定層的逾時。守這條規則的測試把 msg2 計時器拿掉之後仍然通過。
- **A-M5** 佔用釋放之後，紀錄是非同步讀的。讀完之前如果有人拿到新的佔用，`core.releaseLease` 會把 `lease` 清成 false，`NodeLink` 就在別人佔用期間開一輪。而且它用的是 `reg.token`，也就是佔用者的憑證，所以 `BleGate` 擋不住。

## 基準

| 項目 | 結果 |
|---|---|
| `lib/` 與 PR worktree 相同 | ✅ `diff -r lib /c/src/Batman-329pr1/app/lib` 無差異（HEAD 75683ab） |
| 全套 `flutter test --no-pub`（不含我的檔案） | ✅ `00:23 +374: All tests passed!`，和 PR 說明一致 |
| nodelink 四個新測試檔 | ✅ 29 passed |
| Rust `cargo test` | ❌ 沒有跑。`owner.rs` 的改動是原樣轉傳，我只讀了程式碼：`login_end_kind`（owner.rs 新增 :451-461）與 loginflow.rs:102-175 對得上 |

## 擁有權與契約（逐項）

| 資源 | 設計的擁有者 | 程式實際 | 判定 |
|---|---|---|---|
| 藍牙掃描 / 連線 | `BleGate`，唯一入口 | `NodeLink` 經 `BleGate`。舊頁面在原始佔用下直接用共用的 `FlutterReactiveBle` | ⚠️ 偏離已寫在 PR 說明；但釋放時機錯了，見 A-M1 |
| 誰能用 `BleGate`（憑證） | 登記表：沒有佔用 = `NodeLink`，有佔用 = 佔用者 | `NodeLink` 用 `reg.token`，取的是「目前的憑證」，不是「`NodeLink` 自己的憑證」 | ❌ A-M5：`NodeLink` 能拿佔用者的憑證通過 gate |
| 佔用旗標（`core.lease`） | 登記表 → `NodeLink` | `acquire` 時同步設成 true；`released` 讀完紀錄後**非同步**才清掉 | ❌ A-M5：舊的釋放會清掉新佔用的旗標 |
| 金鑰紀錄 | 目前的佔用者，經 `RecordWriter` | 舊頁面直接呼叫 `storeWriteCas` / `storeRemove`（偏離已寫）。頁面關掉後，認領照樣寫，這時已經沒有佔用 | ❌ A-M1 |
| `writtenNodes`（釋放時要丟的備忘） | `RecordWriter` 記 | 只有 `RecordWriter` 會記；舊頁面不經過它 → 永遠是空的 | ❌ A-M2 |
| 一次嘗試的連線 `_link` | 目前這次嘗試 | 被取消的舊嘗試回來時會關掉 `_link`，這時它可能已經是下一次嘗試的連線 | ⚠️ A-m1 |
| 讀一次的結果（`Res`） | `SessionProber` → `core.result` | `login_end` 對應正確；登入前的 `Broken` → `noResponse`；`AuthRefused` 只會出現在憑證驗過之後（loginflow.rs:139-149、:166-175） | ✅ |
| 讀一次的時候寫紀錄 | 不准 | `SessionProber` 拿不到任何寫入函式；Persist* 這類步驟走 default 分支 → `broken`，什麼都不寫 | ✅（prober_test 守著，M6/M7/M8 都抓得到） |
| 憑證收回 | 登記表 → `BleGate` 關掉該憑證的掃描與連線 | `revoked()` 與 `released()` 都會關 | ✅（M11 抓得到） |

## 發現

### MAJOR

**A-M1 原始佔用在頁面關掉時就釋放，但認領在頁面關掉之後還會跑 60 s 以上（兩個藍牙使用者，加上一個沒有佔用的寫入者）**

- 情境：使用者在「認領節點」頁開始認領，在 60 s 的搜尋期間或握手中按返回。`_open` 等到 `Navigator.push` 回來就呼叫 `lease.pageGone()`。舊頁面從不呼叫 `lease.run`，所以 `_busy == 0`，`pageGone` 立刻釋放。6 s 後 `NodeLink` 開一輪：自己掃描，連自己的節點。同一時間 `ClaimPage._find` 還在掃描、連線，最長 `findFor` = 60 s；找到之後繼續握手，寫 `claim-pending/`，再寫 `node/<id>`。
- 證據（原始碼）：
  - claim.dart:83-89：`dispose` 只取消恢復，註解寫「a claim/finish in flight is not interrupted」。
  - claim.dart:51：`findFor = 60 s`；claim.dart:209、:222：自己的 `scanForDevices` / `connectToDevice`；claim.dart:399：`records.persistPending`。
  - `grep PopScope|WillPop claim.dart`：沒有結果。
  - main.dart `_open`：`await Navigator...push(...); lease.pageGone();`。
  - lease.dart:56-61：沒有在跑的工作就立刻 `release()`。
  - `ScanPage._read` 也一樣：頁面關掉之後連線最多還留 30 s（scan.dart:81-112）。
- 後果：
  - 兩條連線、兩個掃描同時存在，違反 §4.1 / §4.2 與 PR 說明自己的安全宣稱。
  - 認領寫紀錄時已經沒有佔用。
  - 釋放時讀紀錄是在認領寫入 `node/<id>` **之前**，所以新節點直到下一次佔用釋放（或重開 app）才會出現在清單上。
- 設計 §4.4「原始佔用的頁面」這一列本來就要求兩件事：工作包在 `lease.run` 裡，`ClaimPage` 認領中加 `PopScope`。PR 的偏離把這兩件事也一起拿掉了，但說明裡只寫了「不改走 `BleGate` / `RecordWriter`」。
- 修法（最少）：
  1. `ClaimPage` 認領中（`_busy`）加 `PopScope(canPop: !_busy)`，`ScanPage` 在 `_busy` 時也一樣。這和設計一致，也和軟體更新頁的做法一致。
  2. 或者 `_open` 把一個「工作開始 / 結束」的 callback 傳給頁面，讓佔用撐到工作結束，最多 420 s。
- 測試：一個 widget 測試。在假的認領進行中 pop `ClaimPage`，斷言 `reg.current` 仍然持有、`NodeLink` 沒有開掃描。負向對照：拿掉 `PopScope` 就 FAIL。

**A-M2 舊頁面寫入的紀錄沒有回報：重新認領後「身分不符」不會結束，N9 例外也不生效**

- 情境：節點被重新燒錄（DAC 換了），首頁正確顯示紅色「身分和手機記錄的不同」。使用者照正常做法去「認領節點」重新認領，回到首頁後紅字一直留著。原因是那個位址上有「不是 Y1」的備忘，Y1 不會再對它試；要等使用者按重新整理、20 分鐘沒掃到，或位址換掉。剛認領完的節點也一樣：§4.3.3-4 例外 (1)（釋放後 30 s 內「解不開」不記備忘）靠 `writtenAt`，而 `writtenAt` 只從 `written` 來。
- 證據：RA-2 是同一個情境，只改「有沒有把 Y1 放進 `writtenNodes`」（flip test）：

  ```
  reported=false kind=Kind.unreachable why=Why.identity      <- FAIL
    0.6   a1×Y1 -> certRejected
    8.6 round 1 full [Y1]  38.6 round 1 end {Y1: notFound}
    98.6 round 2 full [Y1] 128.6 round 2 end {Y1: notFound}
  reported=true kind=Kind.read why=null                      <- PASS
  ```

- 修法：`_open` 在 `acquire` 之後與 `pop` 之後各讀一次 `(id, mtime)`。新增、刪除、或 mtime 變了的 id 放進 `lease.writtenNodes`，再呼叫 `pageGone`。`AppLink.readRecords` 已經會讀 mtime，大約十行。
- 測試：把 RA-2 改成經過 `_open` 的版本。負向對照：不做比對就 FAIL（上面的輸出）。

**A-M3 藍牙、權限、金鑰三個前提沒有接上，掃描錯誤也沒有處理**

- 情境：手機藍牙關著時打開 app（或讀到一半關掉藍牙）。設計 §4.3.3-1、§7「藍牙關閉 → 打開：立刻顯示 2.3；打開後自動讀一輪」。實際上：
  - `BleGate.scan` 用 `backend.scan().listen(seen)`，沒有 `onError`（ble_gate.dart:366），錯誤變成沒有人接的例外；
  - `NodeLink` 以為掃描在跑，一輪跑到 30 s 什麼都沒看到，結論是「沒找到」，兩輪後顯示「手機連不到節點：可能沒開機、還在開機、離太遠…」；
  - 藍牙打開之後也不會立刻讀，要等下一個 60 s。
- 證據：
  - `grep '\.radio(\|setRadio' lib/`：只有定義（node_link.dart:85-86、core.dart:271），沒有呼叫者。
  - RA-3（掃描串流丟錯誤）的輸出：

  ```
  0.0 round 0 full [Y1] / 30.0 round 0 end {Y1: notFound} / 40.0 round 1 early [Y1] / 70.0 round 1 end {Y1: notFound} ...
  shownWhy=Why.notFound      (期望 Why.bluetoothOff)
  uncaught errors: 3 (Exception: bluetooth off, ...)
  ```

- 金鑰：啟動檢查之後 `KeyGate` 的結果也沒有傳給 `keyOk`（X26）。
- 修法：
  - `AppLink` 訂閱 `ble.statusStream`，`poweredOff` / `unauthorized` 分別呼叫 `nl.radio(bluetooth: …)` / `nl.radio(permission: …)`。
  - 啟動檢查的 `keys` 傳給 `keyOk`。
  - `BleGate.scan` 加 `onError`：停掉掃描、通知 `NodeLink` 取消這一輪（§4.3.3-7a：當成被取消，不算結論）。
  - 如果決定留到之後的 PR，就要寫進 PR 說明的偏離，並在 §12 註明；現在說明裡沒有寫。
- 測試：T-L4、T-L5、T-X7（設計 §12 把它們列在 PR 1）。負向對照就是 RA-3。

**A-M4「到 msg2 最多 8 s」沒有從頭算到尾；守這條規則的測試改壞也會過**

- 設計 §4.3.3-3：從**開始連線**到收到 msg2 最多 8 s。這個上限也是 §4.3.7 / §8「拖時間的上限、已認出來的自己的節點不受影響」的前提。程式實際的計時：
  - node_link.dart:42：連線用掉最多 8 s。
  - 接著 prober.dart:247-251：`openRecord`（Keystore）、`requestMtu`、`read(ctrl)` 都**沒有期限**。
  - 然後 prober.dart:307 的 msg2 計時器**重新**從 8 s 開始算。
  - 另外 prober.dart:313 先 `await run(first)`，才等 `result.future`。所以第一次寫入卡住的話，兩個計時器 `done()` 了也結束不了 `probe`。
- 情境（附近的攻擊者）：一個廣播 provd UUID 的裝置接受連線，但不回 MTU。每次嘗試就卡到 Android ATT 交易逾時（⚠️ 推論約 30 s，沒有實測），或到 90 s 上限被切掉。每個位址每輪 2 次，兩個這樣的位址就能把一輪 90 s 用完，已認出來的自己的節點也排不到。
- 證據：
  - RA-4：MTU 不回，msg2 期限設 50 ms，2 s 後 `probe` 還沒結束：`Expected: true Actual: <false> msg2 budget 50 ms, still waiting after 2 s`。
  - 改壞對照 M5：把 msg2 計時器 `t1` 拿掉，`prober_test` 的「no frame from the node within the msg2 budget -> noResponse」**仍然通過**。原因是 `t2` 在 20.05 s 觸發，比預設的 30 s 測試逾時早。這是一個改壞也不會 FAIL 的測試。
- 修法：
  - `NodeLink` 把「這次嘗試的開始時刻」或期限傳給 `probe`。
  - msg2 之前的每個 await（openRecord、requestMtu、read、write）都和「期限、cancelled」一起 `Future.any`。
  - `probe` 回傳 `Future.any([result.future, run(first).then(...)])`，不要先等 `run(first)`。
- 測試：
  - RA-4。
  - msg2 那個測試加 `timeout: Timeout(Duration(seconds: 2))`，或斷言經過的時間，才能抓到 M5。
  - 另加一個 node_link 測試：連線 7 s 才通 + 節點不回 → 總共 ≤ 8 s 就是 `noResponse`。

**A-M5 舊佔用的「釋放後讀紀錄」會蓋掉新佔用；`NodeLink` 拿佔用者的憑證通過 gate**

- 情境：佔用 A 釋放。`NodeLink.released` 讀紀錄（`listNodes` 走 bridge，非同步）。讀完之前，佔用 B 已經拿到。讀完後 `core.releaseLease` 把 `lease` 設成 false、`leaseDue` 設成 6 s 後。6 s 後 `NodeLink` 在 B 持有期間開一輪，用 `reg.token`（node_link.dart:146、:163）去掃描、連線，而這張其實是 **B 的憑證**，所以 `BleGate._gate` 照樣放行。
- 證據 RA-5：`lease held by B; core.lease=false; rounds 1; gate scans=1`（期望 0 輪、0 個掃描）。
- 發生機率：PR 1 裡要在一次 `listNodes` 呼叫的時間（毫秒級）內再拿一次佔用，靠人手很難碰到。PR 3 起由流程 controller 連續釋放、再拿佔用時就會碰到。不論機率，這兩點本身都要修：「`NodeLink` 用的是誰的憑證」沒有被 gate 驗證；`core.lease` 有兩個寫入時間點，而且彼此不同步。
- `released()` 的 `readRecords()` 也沒有 `catchError`。一旦失敗，`releaseLease` 永遠不會被呼叫，`lease` 一直是 true，`NodeLink` 到重開 app 之前都不再讀（見 A-m6）。
- 修法：
  1. `released()` 讀完紀錄時，如果 `reg.current != null`，只做 `setRecords` 與丟備忘，不清 `lease`。
  2. 登記表另外提供「`NodeLink` 的憑證」：沒有佔用時才有效。`NodeLink` 只用它，不用 `reg.token`。
  3. 加 `catchError`：讀不到紀錄就用舊的清單照樣 `releaseLease`。
- 測試：RA-5。

### MINOR

- **A-m1 被取消的嘗試晚回來時，會關掉下一次嘗試的連線**
  - 位置：node_link.dart:183-184，`await _link?.close(); _link = null;`。這時 `_link` 可能已經是下一次嘗試的連線。
  - 觸發：嘗試 A 被取消時正卡在 Keystore（`openRecord` / `signOwner` 約 130–150 ms，M-1），而且新的一輪立刻開始（例如提前再讀的輪跑到一半時全輪計時到、或在提前再讀中按重新整理、或背景後馬上回前景），嘗試 B 已經連上。
  - 後果：B 拿到 `noResponse`，那個位址在這一輪被當成用完。通常會自己恢復（提前再讀），所以列 MINOR。
  - 證據 RA-1：`Expected: <1> Actual: <0>  A must not close the link of B`。
  - 修法（已在我的複本驗證）：在 `_run` 用區域變數 `mine` 記自己的連線，結尾改成 `await mine?.close(); if (identical(_link, mine)) _link = null;`。修完 RA-1 通過，node_link_test 6/6 照樣通過。
- **A-m2 改壞也不會 FAIL 的規則**（`mut.sh`，一次改一條，跑對應的測試檔）：

  | 改壞 | 結果 |
  |---|---|
  | M2：`acquire` 不先等斷線完成（拿掉 `await _dropAll()`） | SURVIVED。假無線電在取消時同步回報斷線，所以「等」這件事看不出來 |
  | M9：prober 不理 `cancelled` | SURVIVED |
  | M10：GATT 不檢查憑證、只看連線開著沒有 | SURVIVED。收回憑證時連線也被關了，所以測試名稱裡「with the current token」那一半沒有被測到 |
  | M14：等掃描名額之後不再檢查憑證 | SURVIVED |

  抓得到的：M1、M3、M4、M6、M7、M8、M11、M12、M13、M15。修法：假無線電加一個「斷線延後回報」的模式；每條規則各補一個能 FAIL 的測試。
- **A-m3 `main.dart` 的接線完全沒有測試**
  - 沒有測到的有兩件：`_open` 拿原始佔用；生命週期對應（`inactive` 不算背景；`paused` / `hidden` / `detached` 算背景，T20）。
  - 沒有任何測試建立 `makeLink` / `AppLink`（`grep -l "makeLink|AppLink" test/` 沒有結果；key_abilities_test 建 `StartupCheck` 時不帶 `makeLink`）。所以拿掉 `_open` 的佔用，或把 `inactive` 當背景，全套照樣通過（⚠️ 依測試內容推論，沒有實際改壞去跑）。
  - 修法：把 `didChangeAppLifecycleState` 的對應抽成一個純函式來測；`_open` 用假的 `AppLink` 做 widget 測試。
- **A-m4 拿到佔用後頁面已經不在，佔用就永遠不放**
  - 位置：main.dart `_open` 的 `if (!mounted) return;`，這時已經拿到佔用，卻沒有釋放。之後 `NodeLink` 到重開 app 之前都不讀。
  - 修法：這條路徑先 `lease.release()` 再 return。
- **A-m5 啟動時建立 `NodeLink` 失敗，啟動頁會一直轉圈**
  - 位置：`AppLink.create` 與 `link.start` 寫在 `_run` 的 try 外面。`filesDir` / `listNodes` / `start` 丟例外的話，`setState` 不會被呼叫。這違反同一函式 catch 區的註解「never a spinner that does not end」。
  - 修法：包進 try，失敗就不建 `NodeLink`，照樣顯示啟動結果，並記一行。
- **A-m6** `released()` 的 `readRecords().then(...)` 沒有 `catchError`。一旦失敗，`NodeLink` 永久停止（修法併入 A-M5）。
- **A-m7 `BleGate` 的「30 s 內最多 4 次掃描」看不到舊頁面的掃描**
  - 舊頁面用原始的 `FlutterReactiveBle`。關掉附近節點頁（每按一次「搜尋」就啟動一次掃描）或認領頁之後 6 s，`NodeLink` 啟動的掃描可能是 30 s 內的第 5、6 次，被 Android 靜默擋下（A10），那一輪什麼都看不到。
  - 修法：原始佔用釋放時，`BleGate` 保守地把 4 次啟動記在釋放的時刻（或改成釋放後至少等 30 s 才掃描）。這也該寫進 PR 說明的偏離。
- **A-m8「上次讀取 N 秒前」用的是單調時鐘**
  - node_list.dart:436-438 用 `Stopwatch`。手機深度休眠時它不走（§4.3.2 M-1 S），鎖屏 30 分鐘回來會寫「上次讀取 30 秒前」。
  - 設計寫的是「上次讀取 HH:MM」，用牆上時間。PR 2 會換掉這個清單，但這段期間的真機場次會看到錯的數字。
- **A-m9 每收到一個廣播就整個更新一次**
  - `onScan` 每收到一個廣播就 `_pump`，進而 `changed.add`，`NodeStatusList` 就 `setState`。lowLatency 掃描下，每台裝置每秒好幾次，一輪 90 s。
  - 修法：只在「這一輪新看到的位址」才 pump。
- **A-m10 登入後的失敗被歸成 `noResponse`**
  - 登入成功後 `requestStatusPage()` 回 Rust `Err`（Dart 端是例外），`probe` 會丟出去，driver 把它當成 `noResponse`。§4.3.3-4 最後一列：登入之後壞掉應該是 `broken`（保留「是 Y」、隔 6 s 重試）。
  - `openRecord` 的 Keystore 失敗也一樣被當成 `noResponse`，不是 X26 的金鑰前提。
  - 修法：在 `probe` 裡依 `loggedIn` 分開處理例外。
- **A-m11 PR 說明的偏離清單不完整**
  - 該寫但沒寫的：(a) 前提沒接（A-M3）；(b) 原始佔用的寫入沒回報（A-M2）；(c) 掃描次數不含舊頁面（A-m7）；(d) T-G5 的原始碼鎖不存在；(e) `loginFor` 只在 core，沒有接上 driver。
  - 「整頁持有原始佔用……仍然只有一個藍牙使用者、一個寫入者」這句和 A-M1 矛盾，要改。

## 生命週期（§7，只列 PR 1 碰到的）

| 路徑 | 改後（程式實際） | 測試 | 判定 |
|---|---|---|---|
| 一般啟動 | 啟動檢查通過 → `start(home)` → 一輪 | node_link_test 第 1 個 | ✅；失敗時會一直轉圈（A-m5） |
| 停在首頁 | 每 60 s 一輪（core） | core 測試 | ✅（core 已審） |
| 背景（paused / hidden / detached） | `background()` → 取消、斷線 | node_link_test 最後一個（只測 `NodeLink`，沒測 `main` 的對應） | ⚠️ A-m3 |
| `inactive` | 不動 | 無 | ⚠️ A-m3 |
| 回前景 | `foreground()` → 立刻一輪 | 同上 | ✅；剛被取消的那次嘗試還沒回來時有 A-m1 |
| 藍牙關閉 → 打開 | **沒處理**：兩輪後顯示「連不到」；打開後等 60 s | RA-3 | ❌ A-M3 |
| 權限被收回 | 同上 | 無 | ❌ A-M3 |
| 金鑰中途失效（X26） | 沒有傳給 `keyOk` | 無 | ❌ A-M3 |
| 舊頁面開著（原始佔用） | 自動輪停止；關掉 6 s 後恢復 | node_link_test acquire 那個（不經 `main`） | ⚠️ 關掉頁面時工作還在跑：A-M1 |
| 佔用頁面關掉時工作還在跑（420 s） | 原始佔用：從不呼叫 `run`，420 s 規則永遠用不到 | lease_test 只測 session 佔用 | ❌ A-M1 |
| 釋放 → 讀紀錄 → 6 s 一輪 | 有；會和下一個佔用競爭 | RA-5 | ❌ A-M5 |
| 程序被殺掉 | 全部在記憶體，重開 = 一般啟動 | — | ✅（依原始碼；沒有寫入） |
| 當機循環 | 一輪只讀不寫 | prober_test persistNet | ✅ |
| 附近的假裝置 | 拿不到簽名（簽名在憑證驗證之後，loginflow.rs:166-175）；登入前的 `Broken` 不會記成「是 Y」 | prober_test、M6 | ✅；拖時間的上限沒守住：A-M4 |

## 安全（逐個角色）

- **附近的攻擊者（假節點）**：
  - 拿不到擁有者簽名：`Sign` 只出現在 `verify_pinned` 通過之後，loginflow.rs:166-175。
  - 拿不到「讀到」；不能種「是 Y」：登入前的 `Broken` → `noResponse`，prober.dart:291，M6 抓得到。
  - 不能種「身分不符」：NXpsk0 握手需要 psk 才解得開 msg2，noise.rs:3、:110-112。
  - 但可以把每次嘗試拖得比 8 s 久很多（A-M4）。
- **同一支手機上的其他 app**：沒有新增的介面。
- **被入侵的節點**：只能影響自己的狀態顏色（現況就可以）；`row 2'` 正確當成錯誤碼。
- **我們自己的錯**：兩個藍牙使用者、沒有佔用的寫入者（A-M1、A-M5）；釋放時沒丟備忘（A-M2）。
- **秘密**：`SessionProber` 只記步驟種類（prober.dart:296），不記紀錄內容、簽名或幀。解開的紀錄只留在區域變數，`OwnerSession` 靠 frb finalizer 回收，和舊頁面相同（nodes.dart:165-172 也只把 `_session` 設成 null）。✅

## 我寫的東西（都在 scratchpad，沒有 commit，沒有改 PR worktree）

| 檔案 | 內容 |
|---|---|
| `scratchpad/core/pr1A/app/test/review/review_a_test.dart` | RA-1（晚回來的嘗試關掉下一條連線）、RA-2（原始佔用寫入後身分不符；含 flip 對照）、RA-3（藍牙關閉）、RA-4（MTU 不回不會被 msg2 期限切掉） |
| `scratchpad/core/pr1A/app/test/review/review_a5_test.dart` | RA-5（釋放後讀紀錄蓋掉新佔用） |
| `scratchpad/core/pr1A/mut.sh` | 一次只改壞一條規則的腳本；結果在 A-m2 |

RA-1 到 RA-5 在 75683ab 上全部 FAIL（輸出已附在各條）。A-m1 的修法在我的複本上讓 RA-1 PASS，node_link_test 仍然 6/6。
