# #329 PR 1（winson3QQ/Batman#339，`feat/329-pr1` @ 26057eb）第四輪程式審查：審查 H

重點：安全（logcat、prober 期限、佔用生命週期、測試用的掛鉤）與 #329 實作殘項能不能接受。

## 結論

**APPROVE-WITH-CHANGES**：1 MAJOR、5 MINOR。A13（合併條件，等使用者決定）照指示只記下、不算發現。

- 第三輪的 E-M1 / F-M1（接線沒有能 FAIL 的測試）已關：我改壞 10 處接線，9 處有測試 FAIL；只剩 main.dart 的 `life:`（H-m1）。
- 安全面沒有新的洞：logcat 有遮罩、prober 期限有上限、測試掛鉤正式版走不到、prober 不寫紀錄。
- 唯一的 MAJOR 在殘項第 120 行：420 s 收回 + 認領頁不加 `PopScope`。認領頁一次忙的時間可以超過 420 s，所以使用者照常操作（認領很慢時按返回）就會走到「兩個藍牙使用者同時跑」。殘項把它寫成「擋不住的缺口」，但它是可以走到的，修法也很便宜。

## 基準（✅ 已驗證）

- 匯出：`git archive 26057eb app` + `tests` 到 `scratchpad/core/pr1H`（沒有複製工作目錄）。
- `flutter test --no-pub` 全套：`00:20 +418: All tests passed!`（`pr1H/base-test.log`）。
- WSL `cargo test --offline`（bridge）：`test result: ok. 62 passed; 0 failed`（`pr1H/cargo.log`）。

## 改壞對照（一次改一處，改完還原；輸出在 `pr1H/mut/*.log`，腳本在 `pr1H-tools/`）

| # | 改壞 | 結果 |
|---|---|---|
| M01 | `RecordWriter` 不檢查佔用 | ✅ FAIL（T-K、420 s） |
| M02 / M12 | GATT、等掃描名額之後不檢查 token | ✅ FAIL（B-m5/M10/M14） |
| M03 | 不做 420 s 收回 | ✅ FAIL ×4 |
| M04 / M05 | `RawBusy` 不 hold／`RawLeaseScope` 不呼叫 `pageGone` | ✅ FAIL（真的 Claim／Nodes／Scan 頁） |
| M06 / M07 | CertRejected→noResponse／ended 一律 broken | ✅ FAIL |
| M08 | 拿掉 hex 遮罩 | ✅ FAIL ×3 |
| M09 / M10 / M15 / M16 | acquire 不等斷線／NodeLink 永遠拿得到 token／release 不理新佔用／gate release 不關 | ✅ FAIL |
| M11 / M13 | inactive 當背景／`start` 不理生命週期 | ✅ FAIL |
| M14 | 期限改成 20 s | ✅ FAIL |
| M17 / M22 | poweredOff、金鑰拒絕沒接上 | ✅ FAIL |
| M18 | `RawBusy` 改成 fail-open | ✅ FAIL（D-3） |
| M19 / M20 / N20 | Nodes pop 後登入成功不 `_drop`／Scan busy 太晚設／沒有 finally | ✅ FAIL |
| M21 | `openRawPage` navigator 已卸載時不釋放 | ❌ 全過（`+203`）＝殘項 123（F-m5），已知 |
| N01 / N02 | main 不走 `openRawPage`／不送 `keyOk` | ✅ FAIL |
| **N03** | **main 不把 `life:` 傳給 `start`** | **❌ 全過（`+241`）→ H-m1** |
| N04 / N05 / N06 | Nodes／Claim 的 `rawUse => null`、認領掃描不計數 | ✅ FAIL |
| N07 / N08 / N09 | 沒有生命週期監聽／prober log、例外 trace 不遮罩 | ✅ FAIL |
| N10 / N11 | close 不等斷線／上一條連線沒斷就開下一次嘗試 | ✅ FAIL |
| N12 / N13 / N14 / N15 | 片段就算 msg2／msg2 之後仍套用 8 s 期限／沒有 answerMax／不理取消 | ✅ FAIL |
| **N16** | **讀取時遇到不該出現的步驟不立刻放棄** | **❌ 全過（`+200`）→ H-m2** |
| N17 / N18 / N19 | 原始佔用不比對紀錄／2' 當讀到／不 dispose session | ✅ FAIL |
| R（Rust） | `AuthRefused(Ok) → (5,0)` | ❌ `62 passed` → H-m4 |

## 發現

### MAJOR

**H-M1：認領頁不加 `PopScope`，而原始佔用 420 s 就收回。認領頁一次忙的時間可以超過 420 s，收回之後 NodeLink 和認領恢復同時用藍牙；PR 說明和殘項第 120 行把它寫成「擋不住的缺口」，但它其實是一般操作就走得到的**

- 情境：
  1. 使用者按「認領」，節點訊號差，馬上按返回（沒有 `PopScope`，F41）。
  2. 頁面繼續忙：
     - 找節點：最多 60 s，加上最後一台的連線最多 20 s（claim.dart:221、:237）；
     - 認領回答：90 s（claim.dart:430）；
     - 失敗後改做恢復：先等 15 s（`t1Wait`），恢復的 `total` 300 s。這 300 s 從 `_prepare` 之後才開始算，做到一半的那一步還有自己的逾時，例如 `afterWriteFor` 90 s（claim_recovery.dart:190-199、:340）。
     - 合計：最壞約 485 s 以上，大於 `goneMax` 420 s（lease.dart:94）。
  3. 返回後 420 s，登記表收回佔用 → `released` → 6 s 後 NodeLink 開一輪。這時恢復還在跑：
     - **掃描互相打斷**：reactive_ble_mobile 5.6.0 的 Android 端只有一個掃描。`prepareScan` 一開始就 `stopDeviceScan()`（`ScanDevicesHandler.kt:35`、`:68`）。所以 NodeLink 一開始掃描，恢復那一輪 6 s 的掃描就被停掉，反過來也一樣。
     - **搶連線**：還在認領中的節點還沒有 `node/` 紀錄，它的位址對 NodeLink 來說是陌生位址，NodeLink 會連上去試（最多 8 s，連著的時候節點不廣播）。恢復的連線因此失敗。
     - **漏看紀錄**：恢復在收回之後才寫的 `node/` 紀錄，NodeLink 要等下一次佔用釋放才會讀到（`_changedIds` 在收回那一刻就算完了，node_link.dart:171-176）。新認領的節點不會出現在首頁清單，直到使用者再開一個頁面。
  4. 使用者看到的結果：恢復在最後一段失敗，紀錄停在「認領沒有確認」，要再開認領頁恢復一次；待辦「上一個操作可能沒有存完」在 PR 1 也不會顯示。
- 證據：
  - 我寫的 `test/reviewH/review_r4H_test.dart` 的 H2：raw 佔用 `hold()` 後 `pageGone()`，時鐘走 421 s + 7 s。輸出：`H2: page still busy; NodeLink scans since=1 connects=1 todos=[上一個操作可能沒有存完：新增節點]`，`Expected: <0> Actual: <1>`。
  - 翻轉對照：只把 `goneMax` 改成 600 s，H2 在第一個斷言失敗（`Expected: null Actual: <Instance of 'Lease'>`），也就是佔用還在、NodeLink 不會進來（`mut/FLIP-goneMax600.log`）。
  - 設計 §4.4「進行中最長多久」一列說 420 s 夠，理由是「認領……進行中不能按返回，不會走到這一列」；PR 拿掉了 `PopScope`，這個前提不再成立。
  - PR 說明「所以同一時間仍然只有一個藍牙使用者、一個寫入者」：在這條路徑上不成立。
  - ⚠️ 485 s 是從原始碼加總的，沒有在真機量。
- 修法（擇一，都很小）：
  1. 原始佔用的 `goneMax` 改成蓋住舊頁面最壞情況的值，例如 600 s，或依頁面名稱給值。收回對原始佔用反正停不了頁面，它只拿來防 `rawIdle` 漏掉而永遠佔著。
  2. 原始佔用收回之後，NodeLink 繼續停著，直到 hold 真的結束（另外設一個很長的保險上限）。
  3. 認領忙的期間加回 `PopScope`。

  同時把 H2 收進測試，並改正殘項第 120 行與 PR 說明的那一句。

### MINOR

**H-m1：r3 E-m1 的修正（`start(life:)`）在 main.dart 的呼叫處沒有測試**

- 證據：N03 把 main.dart:140 的 `, life: WidgetsBinding.instance.lifecycleState` 拿掉，全套（nodelink + 頁面 + key_abilities）`+241: All tests passed!`。
- `review_pr1_test` 的 `r3 E-m1` 直接呼叫 `nl.start(life: paused)`，沒有經過 `StartupCheck`。
- 修法：`key_abilities_test` 已經有注入 `makeLink` 的 start-page 測試。在那裡先送 `paused` 再讓啟動檢查完成，斷言 `core.fg == false`。

**H-m2：「讀取時遇到不該出現的步驟就放棄」的測試抓不到「不放棄」**

- 證據：N16 把 prober.dart:108 的 `done(failed())` 拿掉，`test/nodelink` `+200` 全過。
- 原因：測試只斷言「什麼都沒寫」和最後的結果，而結果最後由 answerMax 補上。
- 影響：結果一樣，只是一次嘗試多佔 20 s 的連線，對節點來說是被這支手機多佔住。
- 修法：測試把 `answerMax` 設長，斷言結果在下一個 frame 之內就出來。

**H-m3：連線立刻失敗（例如 GATT 133）也要等滿 8 s**

- 證據：H3（`FastFailRadio` 一連就回 disconnected）輸出 `attempt a1×Y1 connected=-1ms result=noResponse after 8000ms`。
- 原因：node_link.dart:279 `link.state.firstWhere((s) => s, orElse: …)` 跳過 `false`，連線串流沒有結束，所以要等到 `due`。
- 結果是對的，只是每一輪變慢。
- 修法：`link.state.first`（`false` 就結束），或者 `firstWhere` 之外另外聽 `false`。

**H-m4：Rust `login_end_kind` 的 `AuthRefused(Outcome::Ok(_)) → (4, 0)` 仍然沒有斷言（第三輪 F-m3 的後半）**

- 證據：把它改成 `(5, 0)`，`cargo test`：`62 passed; 0 failed`。
- 影響小：一般節點不會以 Ok 拒絕登入；如果真的發生，畫面會從「節點不接受這支手機的登入」變成「連不到」。
- 修法：在 owner.rs 的 `record_parse_and_texts` 補一行斷言。

**H-m5：PR 本文的測試段沒有說 26057eb 本身沒有上過真機**

- 本文寫「PR 1 自己的 APK 沒有另外裝」「真機看過的是 PR 2 的 APK」。26057eb 改了 main.dart、nodes.dart、scan.dart、app_link.dart 的接線，這些都沒有在 S20 上跑過。
- 這屬於 B 組場次，不阻擋審查。建議在 B 組清單上寫明「在合併的那個 commit 上跑」。

## 先前發現的關閉狀態

| 發現 | 狀態（證據） |
|---|---|
| E-M1 / F-M1 接線沒有測試 | ✅ N01、N02、N04–N09、N19、N20、M19、M20、M22 都 FAIL；只剩 N03（H-m1） |
| E-m1 背景中啟動 | ✅ 程式已修（node_link.dart:102-110，M13 FAIL）；main 的呼叫處見 H-m1 |
| E-m6 ScanPage busy | ✅ M20、N20 FAIL |
| F-m1 msg2 之後不套用期限 | ✅ N13 FAIL |
| F-m2 log 遮罩 | ✅ N08、N09 FAIL |
| F-m3 Rust 斷言 | ⚠️ CertRejected 已補；AuthRefused(Ok) 沒有（H-m4） |
| F-m5、F-m6、F-m7、E-m2、E-m3、E-m4、E-m5 | 已寫進殘項（第 117、121–125 行），判斷見下 |
| F-M2 A13 | 等使用者決定，不計入 |

## #329 實作殘項：能不能接受

| 行 | 內容 | 判斷 |
|---|---|---|
| 114 | 認領結果顯示在已關掉的頁面上（F41） | ✅ 可以接受。但它和 H-M1 是同一個決定（不加 `PopScope`）的另一面 |
| 115 | X26 只認 `keyLevel`，`open` 出錯顯示「連不到」 | ✅ 可以接受（啟動時的 `keyLevels` 已經擋掉常見情況） |
| 116 | 明文靠 GC 回收 | ✅ 可以接受（S20 上平台緩衝區是唯讀的；app 其他地方本來也一樣） |
| 117、118 | B 組真機量 | ✅ |
| 120 | 舊頁面不走 gate / RecordWriter；420 s 收回後擋不住 | ⚠️ 不走 gate / RecordWriter 可以接受（PR 3 / 6 換掉頁面）。**420 s 擋不住那一半不能照現在的寫法接受**：它不是理論上的缺口，認領頁一般操作就走得到，而且修法很小（H-M1） |
| 121 | gate 在藍牙關閉時不另外拒絕 | ✅ 可以接受（NodeLink 的前提擋住；M17 證明前提接線有測試） |
| 122 | 拿佔用的最多 5 s 沒有提示 | ✅ |
| 123 | `openRawPage` 卸載路徑沒有測試 | ✅（M21 確認沒有測試；很難走到） |
| 124 | 閒著的「我的節點」關掉時，只靠 6 s 錯開 | ✅ 可以接受到 B 組量（E-m5 指出 DISCONNECTED 最多晚 200 ms 送出） |
| 125 | msg2 之後斷線要等 20 s | ✅（結果正確） |
| 127 | 合併條件 B 組／A13 | 照指示不計 |

## 安全（逐個角色）

- **logcat**
  - 新增的輸出有三種：
    - `BMAPP nl` trace：attempt 行與 core log，每處都包 `mask`，node_link.dart:69、:293、:296；
    - prober log：app_link.dart:61 包 `mask`；
    - `nodelink lifecycle`。
  - prober 只 log 例外的型別與訊息、`loginEnd`、`loginCode`（prober.dart:95、:139、:148、:157）。`ended` 的 `detail`（可能含 `{e:?}`）不 log。
  - Kotlin 的錯誤是 `類別: 訊息`，不帶資料（MainActivity.kt:121、:133）。`OwnerSession.on_frame` 不丟錯誤，回傳 `Option`（owner.rs:807）。
  - 遮罩只蓋 ≥8 個連續 hex 字元與 MAC；用十進位列印的位元組串列不會被蓋。不過我沒找到任何會印出 frame 或紀錄內容的路徑。
  - N08、N09、M08 證明遮罩有測試守著。
- **附近的惡意 BLE 裝置**
  - msg2 之前合計 8 s（`due`，N12、N13、M14 FAIL）。
  - 片段不算 msg2（N12）。
  - MTU、ctrl 讀取卡住也受 8 s 管（prober.dart:56-58、:156）。
  - 解不開 → `undecryptable`；沒有登入就不會有 `body`：`answer` 只在 Rust 進入 `Conn` 之後才會出現，而 `Conn` 只在 `End::LoggedIn` 之後（owner.rs `login_step`）。
  - 其他 login 結束都對應成 noResponse，不會給出「是 Y」（M07 FAIL）。
- **被入侵的節點**
  - 登入之後最多佔 20 s（`answerMax`，N14 FAIL）。
  - 只能謊報自己的顏色。
  - 任何 Persist*、Confirm* 步驟都走 default 分支，不寫東西（但會晚放棄，見 H-m2）。
- **其他 app**：沒有新的 IPC。logcat 只有 system / adb 讀得到。
- **我們自己的錯**
  - Token 只有私有建構子，以 `identical` 比對，偽造不了（lease.dart:7、:110）。
  - NodeLink 在有佔用時拿不到 token（M10 FAIL）。
  - `RecordWriter` 在正式版沒有人呼叫（`grep RecordWriter lib` 只有它自己）。舊頁面直接寫 bridge，這是殘項 120。
- **測試掛鉤**
  - `AppLink.forgetForTest` 只有定義（`@visibleForTesting`），`lib/` 沒有任何呼叫。
  - `AppLink.create(ble:)` 在正式版的 `main()` 沒有傳入（main.dart:23）。
  - 正式版走不到，也不會因此變弱。
- **佔用生命週期**
  - 頁面開著時一直佔著，這是設計（§4.4）。
  - 頁面關掉之後最多 420 s。H-M1：這個上限太短，而不是太長。
  - session 佔用在 PR 1 沒有人使用。
  - 沒有永久佔用的路徑：`hold` 回傳的函式只會作用一次，收回之後再呼叫什麼都不做（lease.dart:58-68、:85）。

## 我寫的東西（都在 scratchpad，沒有 commit）

- `scratchpad/core/pr1H/app/test/reviewH/review_r4H_test.dart`：H1（release 的讀取和下一次 acquire 競爭：沒有重現，core 保持在佔用中）、H2（H-M1）、H3（H-m3）。
- `scratchpad/core/pr1H-tools/mut.sh`、`batch1.sh`、`batch2.sh`；輸出在 `scratchpad/core/pr1H/mut/`。
