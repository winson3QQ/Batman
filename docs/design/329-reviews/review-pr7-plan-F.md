# #329 PR 7 計畫 v3 審查（審查者 F，第三輪）

範圍：`docs/design/329-pr7-plan.md` v3（3b89fab）整份，對照本 worktree 原始碼（= main 3020374 + 計畫）與 #329 未勾清單（scratchpad `i329d.md`，49 行）。基準（設計 v12.1、PR 1–6）不重審。唯讀；沒有上機，也沒有跑測試。

統計：**BLOCKER 0 / MAJOR 2 / MINOR 12**。結論：**APPROVE-WITH-CHANGES**。兩個 MAJOR 都在 §5 真機場次，T 項目的設計本身沒有 MAJOR。M-1、M-2 要在真機場次開場、問同意之前改好。

---

## 前幾輪 BLOCKER / MAJOR 的處理狀況

| 前輪 | v3 狀態 | 依據 |
|---|---|---|
| A-B1 / B-B1 / C-B1 / D-M2（T14 毀損或卡死） | ✅ 已解決 | Kotlin `firstRun` 不動，所以「中斷後全部重產、能自己恢復」照舊（Keys.kt:62-72、:180-191）。三態只加在 `store_has_records`（simple.rs:44-48） |
| C-M1（`_install` 失敗後 app 仍可用） | ✅ 已解決 | `firstRun` 失敗時照舊刪掉四把（Keys.kt:188），`appUsable` 是 false（KeyPolicy.kt:161、main.dart:183） |
| C-M2 / A-M1 / B-M3（清理規則沒有測試） | ✅ 不適用 | 清理規則沒有改 |
| D-M1 / B-M1（漏項） | ✅ 已解決 | §1 剛好 49 列，和 `i329d.md` 的 `- [ ]` 行號逐一相符。合計那一行算錯了，見 m-11 |
| D-M3（ScanPage `_busy`） | ✅ 已解決 | T20 用另一個旗標，`_read` 照舊只看 `_busy`（scan.dart:81-82） |
| A-M4 / B-M5（T6） | ✅ 大致解決 | 剩下的見 m-7 |
| C m-2 / D m-2（T1 的範圍） | ✅ 已解決 | 只檢查 RECORD_AES。呼叫端清單見 m-6 |

---

## MAJOR

### M-1 §5 btsnoop / `adb bugreport`：同意清單沒寫 bugreport 裝了什麼、放在哪裡、誰會看到

**情境**
- 依 §5，隊長的私人 S20 會被取一份 `adb bugreport`。
- bugreport 不只有 btsnoop，還有：
  - 完整 logcat；
  - `dumpsys` 全部內容，包括通知（近期通知的標題與內容）、帳號名稱、記住的 Wi-Fi SSID、位置相關服務狀態、已安裝的套件；
  - 開了 full 模式的 HCI 記錄。這份記錄也會收到手機和其他藍牙裝置（耳機、手錶、車）之間的流量。
- #329:194 的證據過去是貼在公開 repo 的 issue comment（`issuecomment-6964891622`）。照 §5 現在的寫法，分析完把片段貼回 #329 是很自然的做法，而計畫沒有任何一條擋住它。

**證據**
- §5 這一列的副作用只寫「改手機開發者設定、bugreport 檔很大」，還原只寫「設定關回」。
- 計畫沒有寫檔案存放的位置、保留多久、什麼內容可以公開。

**其他缺口**
- `settings put secure bluetooth_hci_log 1` 在 S20（Android 13 / One UI）上是否有效，⚠️ 沒有證據。新版 Android 的開發者選項改的是 `persist.bluetooth.btsnooplogmode`（第二輪 D m-9 也指出過）。
- 把設定關回去之後，手機上的 snoop 檔還會留著，直到被覆寫為止。

**修法**（全部是 §5 的文字，不動設計）
1. 問同意時寫明：bugreport 含個人資料（通知內容、帳號、Wi-Fi、所有藍牙裝置的流量）。
2. bugreport 的 zip 只放 scratchpad，不放進任何 repo。分析時只取出 btsnoop。分析完刪掉 zip，並列出刪了什麼。
3. 公開 issue 只貼推導出的事實：時間差、HCI status / opcode、133 的次數。不貼原始記錄、MAC 位址或 logcat 段落。
4. 開場前先唯讀探測：`settings get secure bluetooth_hci_log`、`getprop persist.bluetooth.btsnooplogmode`，把方法定在真的會生效的那一個。
5. 可以考慮先試 `adb shell dumpsys bluetooth_manager`。AOSP 開了 snoop 時，它會附 `BTSNOOP_LOG_SUMMARY`，可能就不必取整份 bugreport（⚠️ 未查證 S20）。
6. 還原那一欄加上：snoop 檔會留在手機上。

### M-2 §5 的節點重開中斷：沒有列出每個中斷之後 04 的狀態、還原步驟與停止條件，而 04 是現在唯一能用的節點

**情境**
- §1 第 91 行與 §5 要在情境 8（改暱稱、**國家頁**）和情境 9（**離開網路、加回**）途中用 SSH 重開 04。
- 設計 §6 情境 8 的國家頁是「改 → 儲存」（329-app-uiux.md:809），情境 9 是「離開網路 → 確認」（:810）。中斷就是在這些設定送出後、套用之前或套用途中重開。
- 可能的結果：
  - 04 停在別的國家設定。使用者已經決定台灣用 US 頻段。
  - 04 停在網路之外或 N0。memory 記錄過改網路會換 IP，SSH 路徑會斷。
  - 04 開不起來。#329:181 把「04 不開機」列為要使用者在場的項目。
- 02 已經不能用（#329:201，要重燒），沒有人在現場。

**證據**
- §5 只有兩列：「SSH 重開 04 → 斷線約 1.5 分鐘 → 自己回來」，以及「情境 9 再走一次 → 加回」。
- 「設定送出後重開」這種組合的結束狀態、還原步驟和驗證都沒寫。
- 使用者的規則（feedback_destructive_test_side_effects）：會動節點狀態的測試，要先列出每個碰到的資源與還原方法。

**修法**
每一個「情境 × 中斷」寫一列：
- 預期的結束狀態；
- 還原動作，例如國家改回 US、暱稱改回、加回 bm-94676ef40105；
- 唯讀的驗證指令，例如用 app 讀狀態，或 SSH `uci get`；
- 停止條件，例如 04 在 N 分鐘內沒有回來（BLE 和 SSH 都連不到），就停下整個場次、記錄現況、等使用者，不再做下一個中斷。

國家頁的中斷建議只做「切背景」與「關藍牙」，不在國家送出後重開節點。如果要做，同意時要另外說明風險。

---

## MINOR

**m-1 T14 / §6 對「今天」的描述不正確，`store_has_records` 從來碰不到「目錄讀不到」的情況。**
- `_install` 在 `storeHasRecords` 之前會先跑 `storeSweep` 和 `storeReadMarker`（main.dart:211-219）：
  - `sweep_temps` 對每個種類目錄做 `fs::read_dir(k.path())?`（store.rs:216）。所以種類目錄讀不到時，今天就已經丟錯，走「啟動檢查失敗 + 重試」，不會走到 firstRun。
  - 根目錄讀不到時，sweep 回 `Ok(0)`（store.rs:211），但讀 marker 會得到非 NotFound 的錯誤（store.rs:84-87），一樣會丟錯。
- 今天真正會被當成「沒有紀錄」的只有兩種：
  - 種類的路徑不是目錄：sweep 跳過不是目錄的項目（store.rs:213-215），`read_dir` 回 ENOTDIR，再被 `unwrap_or(false)` 吞掉；
  - 目錄裡某一項讀取錯誤：sweep 用 `.flatten()`、has_records 用 `is_ok_and` 吞掉。
- 修法：
  - 把 §6 的生命週期列改成這兩種實際情況；
  - Rust 測試除了權限 000，再加一個「`records/node` 是一般檔案」的情況（以 root 執行也成立）；
  - 再加一條「先 sweep 再 has_records」的串接測試。改回 `unwrap_or` 時，ENOTDIR 那條要 FAIL。

**m-2 T14 的 Dart 測試沒有負向對照。**
- 在 main 上讓假的 `crateApiSimpleStoreHasRecords` 丟錯，例外會被 `_run` 外層的 catch 接住（main.dart:153-164）：
  - `retry = true`；
  - 畫面顯示「再試一次」；
  - firstRun 從來不會被呼叫。
- 所以計畫寫的「拿掉分支 → FAIL」不成立，測試在沒有改動的程式上也會通過。
- 修法：
  - 測試斷言 T14 新的那句字；
  - 讓假的 `keyLevels` 回 RECORD_AES 是硬體等級，斷言沒有進首頁（`_ok` 為 false）；
  - 負向對照：仿照 main.dart:220-223 寫成「加一行字就 return」→ 進了首頁 → FAIL。

**m-3 T14 在現場的出路要寫在畫面上，§6 的「可重試」寫得太滿。**
- 永久性的錯誤（儲存毀損、ENOTDIR）按重試永遠過不了，app 會一直停在那裡。今天的程式會「恢復」，但代價是重產金鑰、失去所有節點。
- 改成停住是對的取捨（fail-closed），但要寫成接受的行為。
- 重試是在同一個行程裡再跑一次 `_run`。如果原因是本行程的 fd 用完，重試修不好。
- 修法：畫面加上兩句：
  - 「關掉 App 再開；仍然不行就重開手機」；
  - 「不要清除 App 資料或重裝（會失去節點）」。
- 不要出現「清除 App 資料」這個建議（key_abilities_test.dart:619 的斷言照舊）。§6 補上「永久錯誤 → 停住，需要回報」這一列。

**m-4 T1 的接線沒有測試鎖住，現有的裝置測試也沒列進全套。**
- `KeysWiringLintTest` 只鎖 `levels` 和 `ownerEncPub`。T1 在 `Keys.handlers` 加的新 override（讀 RECORD_AES 的等級並 open）如果寫成別的 role，JVM 測試抓不到。
- 現有的 `KeyHandlersDeviceTest` 是 `Keys.handlers` 的行為測試（KeysWiringLintTest.kt:9-10 自己這樣說），但 §5 / §8 寫「本 PR 沒有 instrumented 測試」，等於默默把它從全套拿掉。
- 修法：在 KeyHandlersDeviceTest 加一個 open 的案例。模擬器的 RECORD_AES 等級是 0，所以應該得到 `Err("keyLevel","RECORD_AES",0)`，這正好證明接線讀的是 RECORD_AES。照該檔頭的方法只在 `adb -s emulator-5554` 跑。另外在 lint 鎖住新的 override。

**m-5 T2 的白箱測試對到 helper，沒有對到 MainActivity 的接線。**
- `MainActivityKeyUseLintTest` 的正則是 `(, wipe = true)?`，wipe 是可有可無（MainActivityKeyUseLintTest.kt:27）。把 open 那一行的 `wipe = true` 拿掉，所有測試仍然通過。
- `keyCall` 本來就會在 `result.success` 之後清零（MainActivity.kt:83）。另外抽一個 `openAndWipe` 是重複的。
- 修法：open 走 `keyCall(result, wipe = true)`，lint 對 open 要求一定要有 `wipe = true`，負向對照是拿掉它 → FAIL。

**m-6 T1 的呼叫端清單（任務要求列出），寫進 §6。** 平台方法 `open` 共有六個呼叫點：

| 呼叫點 | 出錯時的行為 |
|---|---|
| claim_records.dart:37 | 往上丟 |
| app_link.dart:35（hint） | 往上丟，hint 保留上一個值 |
| app_link.dart:115（prober / handoff 的 openRecord） | prober.dart:208-210 → `keyCheck` → `refusedBy` → 2.4 |
| app_link.dart:183（NetIndex） | 記成「打不開」，跳過（net_index.dart:211-229） |
| app_link.dart:204（console `readRecord`） | 吞掉 → null → `joinreq` 覆寫（owner.rs:1294） |
| ui_state.dart:228 | 吞掉 → 用 CAS 覆寫 |

T1 新增的錯誤只有兩種：
- RECORD_AES 等級被拒。這時 app 本來就是停用的（KeyPolicy.kt:161）。
- 讀 RECORD_AES 的等級失敗。這和 `getKey` 是同一個 Keystore，不會比今天更容易發生。

舊版寫的紀錄格式沒有變，打開的方式也一樣。所以沒有變得更糟，但要寫明。另外，計畫裡 Dart 負向對照的「拿掉 refusedBy 的 open」意思不清楚，改成「拿掉 prober.dart:209-210 的 `keyCheck`」。

**m-7 T6 從節點頁開 PermissionsPage 時，要和首頁做一樣的事。**
- 首頁的 `_permission()` 在權限給了之後會呼叫 `a.link.radio(permission: true)`（home_page.dart:223-228）。
- 節點頁如果只推出 PermissionsPage，就要等藍牙狀態串流送來新的狀態，2.2 才會消失。
- 修法：
  - 把 `_permission` / `_settings` 抽成共用的函式（第二輪 C m-4）；
  - widget 測試斷言權限給了之後前提會被清掉。負向對照：漏掉 `radio(permission: true)` → 仍顯示 noPermission → FAIL。
- 藍牙關閉時，hint 的 `SendKeyButton`（node_page.dart:137）按下去也送不出去，建議隱藏，不要只降成次要按鈕。

**m-8 T8 首頁怎麼彙總沒有定義。**
- `HomeInputs.firstRounds` 是單一個 bool（home_page.dart:280、home_logic.dart:47 / :87）。改成每台的 `firstRounds(id)` 之後，首頁第 5 列要用哪一種規則（任一台 < 2，或全部 < 2）要寫明，並且要有測試。
- 另外，core 裡的函式叫 `startup()`（core.dart:193），計畫寫成 `start()`。

**m-9 T20：租約收回之後，`hold()` 會丟例外。**
- `Lease.hold()` 在租約已經無效時會 throw（lease.dart:61）。
- `_start` 沒有 try（scan.dart:49-68）。所以租約在 900 s 被收回之後再按「搜尋」，會丟出沒人接的例外。
- 修法：拿 `_scanHold` 時用 try 包起來，失敗就顯示原因並且不開始掃描。

**m-10 T3 的例外是整個檔案。**
- `app_link.dart` 是一個很大的檔案，`main.dart` 也是整個檔案都例外。以後在這兩個檔案裡新加的直接寫入，鎖都抓不到。
- 修法：例外改成「指定的函式或行」，或鎖住每個檔案的出現次數（app_link 4 次、main 1 次、ui_state 2 次、claim_records 3 次），多一次就 FAIL。

**m-11 §1 的合計算錯了。**
- 「做」列出來的是 17 行，不是 19 行；「勾 / 決定」是 9 行，不是 10 行。
- 49 列的表本身是對的。合計那一行要照表重算。

**m-12 §5 / PR body 要寫明的地方。**
- 安裝本 PR 的 APK 之前，先保留 main（#350）的 APK，還原就是 `adb install -r` 它。
- S20 有 marker，所以 T14 在真機上走不到。PR body 要把 T14 標成 ⚠️「只有 Rust 與 widget 測試」。
- §5 寫「讀 log 量 open 耗時」，但現在沒有這行 log，要寫明加在哪裡。這行 log 只記耗時，不記內容。

---

## 從實際使用與各個角色出發查過、沒有問題的部分

- **隊長的 S20（已有 marker）裝本 PR：** `_install` 讀到 marker 就返回（main.dart:215-218），T14 不會被呼叫。RECORD_AES 是硬體等級，所以 T1 不會擋住 open。舊紀錄的格式和 AAD 都沒變，照樣打得開。
- **T14 遇到斷電：**
  - firstRun 做到一半：沒有 marker、目錄不存在 → firstRun 全部重產，能恢復（Keys.kt:63）。
  - firstRun 成功但 marker 還沒寫：下次會重產，因為那時還沒有任何紀錄。
  - 寫紀錄做到一半：暫存檔是點開頭，`has_records` 會忽略（simple.rs:47），sweep 會清掉。
  - `RECORD_KINDS` 涵蓋了 app 會寫的所有種類：node / claim-pending / net / mnet / mpend / forgotten-×2。`ui`、`meta` 不算紀錄，和 T-U4 一致。
- **T14 的 FRB 介面：** 改成 `Result<bool, String>` 之後，Dart 端的型別仍然是 `Future<bool>`，所以各測試的 mock（例如 key_abilities_test.dart:76）不用改；claim.rs:605 要加上 `.unwrap()`。
- **本機的無特權 app：** `allowBackup=false` 並有 dataExtractionRules（AndroidManifest.xml:23-30），filesDir 與 Keystore 依 UID 隔離，T14 / T1 沒有新增攻擊面。
- **被入侵的節點：** T9、T10 顯示的是既有的 Rust 句子和認領時的位址，新面只是放在摺疊起來的技術資訊裡。
- **T1 / T2：** Flutter 的 `result.success` 會同步編碼，所以接著清零是安全的。前提和 ecdh 相同（MainActivity.kt:83）。
- **T-U2：** 防呆在 t_u2_guard.dart:19-26，不受影響。`Keys.open` 改成 private 只影響 `selfTest`，它在同一個 class 裡，而 androidTest 沒有呼叫 open。
- **T19、T11、T12、T16、T17：** 沒有意見。

## 結論

**APPROVE-WITH-CHANGES。**
- T 項目的設計可以開始實作，同時照 MINOR 修正。
- M-1（bugreport 的內容、存放位置與公開範圍）和 M-2（節點重開中斷的結束狀態、還原與停止條件）要先寫進 §5，才能問使用者同意、開真機場次。這兩項只改 §5 的文字，由一位審查者確認差異就夠了。
