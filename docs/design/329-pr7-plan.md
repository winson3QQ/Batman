# #329 PR 7 計畫（v2）：可遠端完成的剩餘項目

基準（已審過、不重審）：`docs/design/329-app-uiux.md` v12.1、PR 1–6 已合併的行為（main 3020374）。本計畫只列新範圍。

來源：#329 本體全部 49 個未勾項目逐條盤點（2026-11-18；scratchpad `i329d.md`）。v1 → v2：第一輪 A（1 / 4 / 11，REJECT）、B（1 / 5 / 12，REJECT），同一個 BLOCKER（T14）。對應在 §8。

## 1. 已打勾（現有程式已解、已過時，或使用者已決定）

| #329 行 | 項目 | 證據 / 決定 |
|---|---|---|
| 84、85 | 原型確認、設計審查 | 使用者 2026-11-18 認可（已打勾附說明） |
| 104 | 舊 ClaimPage 返回後結果丟失 | F41 已修：claim.dart:183-190 `goneNote` → home_page.dart:246、:340-346；test add_pages_test.dart:162-169 |
| 120 | 舊「我的節點」登入例外 | NodesPage 已刪；ClaimPage 在 requestMtu 前就指派 conn（claim.dart:405-409） |
| 122 | B 組要在 PR 1 合併 commit 的 APK 跑 | PR 1 已合併，合併條件 :117 已改寫 |
| 130 | 第 6 列中性按鈕碰不到 | net_index.dart:135-147 → `NetRecords.unknown` → home_logic.dart:93；test net_index_test.dart:95、home_logic_test.dart:99 |
| 112 | PR 1 啟動頁等佔用的字 | 舊啟動頁 `_open` 在 `_app == null` 時不拿佔用（main.dart:91-95）；:97-99 死碼本 PR 刪（T19），合併後打勾 |
| 114 | 舊頁關掉時佔用先交回 | NodesPage 已刪；ClaimPage finally 先 `await conn?.cancel()`（claim.dart:499-502）。殘留 ScanPage dispose 本 PR 修（T20），合併後打勾 |

## 2. 本 PR 做的（技術細節由我定案，理由附上）

| # | #329 行 | 做法 | 測試與負向對照 |
|---|---|---|---|
| T1 | 105 | Kotlin `"open"` 改走 `keyCall`（KeyPolicy 檢查 RECORD_AES 等級），`Keys.open` 改 private 經 KeyHandlers。**行為變化**：任何一把金鑰等級讀不到時，open 也失敗（`RecordUiStore` 把 open 失敗當「沒有」）——這和 seal / sign 已是同一規則；在 S20 量一次每次 open 多讀四把等級的耗時並記錄。「金鑰前提變 false 後要重開 app 才恢復」維持（review pr1 B-M5 刻意設計） | `MainActivityKeyUseLintTest` 加 `open`（拿掉 keyCall → FAIL）；`KeyHandlersTest` 加一條 open 經政策（假 Keys，拿掉政策檢查 → FAIL） |
| T2 | 106 | Dart 端唯讀緩衝區 → 已知殘留（寫明：codec 緩衝、Cipher 內部、Dart 端都還有明文，**不宣稱已清零**）；只做 Kotlin 自己那份 ByteArray 在 `result.success` 之後 `fill(0)` | lint 測試鎖住 `fill(0)` 在 open 的回傳之後（拿掉 → FAIL） |
| T3 | 110 | ClaimPage / ScanPage **保留原始佔用**（PR 1 機制，已有測試與真機）；改設計 §5.3、§4.4 寫明。T-G5 的原始碼鎖做成「寫紀錄只經 RecordWriter，例外只有 `claim_records.dart`（ClaimPage 的寫入，理由：認領寫入是新憑證唯一的一份，佔用收回後也不能拒絕寫）」 | 原始碼掃描測試（新檔案直接呼叫 store 寫入 → FAIL） |
| T4 | 111 | 不改：權限收回時系統直接結束行程（A22 實測）；藍牙關閉時 NodeLink 前提擋住 | — （打勾附理由） |
| T6 | 125 | 節點頁 StatusHero 的 `extra` 加**藍牙 / 權限**的主要按鈕：藍牙關閉 → `Btn.openBluetooth`、沒有權限 → `Btn.allowBluetooth`、永久拒絕 → 開 app 設定（同首頁 2.2 / 2.3 的按鈕與動作）。**「加入網路」不另加按鈕**：節點頁已有 `node-join` 列（node_page.dart:87-111，涵蓋 net / mnet / mpend / unknown 各分支），不做兩個同名入口；不加「建立網路」（PR 3 D8）。有 hint 的「把新密碼送給節點」且藍牙關閉時，藍牙按鈕是唯一主要按鈕、hint 按鈕改次要。`whyNext` 的「請回首頁按」改成指向畫面上的按鈕 | widget：三種前提各一顆實心按鈕、按下呼叫同首頁的動作；藍牙關閉 + hint 時只有一顆實心；負向對照：拿掉 extra → FAIL |
| T7 | 126 | 第 7、8 列（多台有事）加 `Btn.showList` →`Scrollable.ensureVisible` 捲到節點清單 | widget：兩台紅 → 有按鈕、按了清單可見；拿掉按鈕 → FAIL |
| T8 | 127 | (a) core 加 `roundsEnded`（**只算正常結束、目標包含全部節點的全輪**；被取消的、提前再讀的不算），四處 `roundsRun < 3` 收成一個 getter `firstRounds => roundsEnded < 2`。(b) 字級：逐處對到 §3.1 六級，**現值 → 目標**列在實作 commit；確認碼的大數字（40 / 44 / 24）白名單。畫板測試在 2.0 倍字級下重跑，溢出 = FAIL | (a) core 測試：第 2 輪結束、第 3 輪開始前 `firstRounds` 為 false；取消的輪不算（改回 roundsRun → FAIL）。(b) 原始碼掃描用運算式解析（`Fs.x ± n`、數字常數都抓）；畫板測試檢查渲染出來的字級（放一個非六級的 → FAIL） |
| T9 | 128 | 節點頁 StatusHero 下加 membership line（`statusMembershipLine`，S6 / S9A 說的「網路：」） | widget：S6 狀態下找得到「網路：」；拿掉 → FAIL |
| T10 | 129 | **照設計 §3.4 S10**：認領時的 BLE 位址放進技術資訊（`tech(…)`，完整位址；技術資訊只在摺疊區、不進剪貼簿以外的地方） | widget：找到節點後主畫面沒有位址、展開技術資訊有；負向對照：不放 → FAIL |
| T11 | 199 | 首頁存 pending id 清單，build 時對當下 `core.states` 過濾 | widget：states 晚到後待辦卡消失；改回在拿清單時算 → FAIL |
| T12 | 113 | 補 `openRawPage` 測試（佔用等候中 navigator 卸載 → 釋放） | 拿掉 `lease.release()` → FAIL |
| T14 | 220 | **Kotlin `Keys.firstRun()` 改成「補齊缺的、絕不刪既有的」**：先讀四把的等級；不存在的才產生；已存在的與新產生的都跑 `selfTest`；任何一步失敗 → 只刪**這次呼叫新產生的**金鑰、回錯誤（既有的金鑰留著）；既有金鑰等級不符政策或 selfTest 失敗 → 回錯誤、不寫 marker（app 照現有路徑顯示金鑰問題）。決策抽成純函式 `firstRunPlan(existing: Map<KeyRole, Int?>)` → (要產生的、要驗的)，JVM 可測；`_install` 不改（它本來就只在沒有 marker、沒有紀錄時呼叫 firstRun；部分金鑰的情況現在變成補齊而不是全部重產）。**證據補齊**：Android 解除安裝時清除該 app 的 Keystore 金鑰（AOSP `KeyStore` per-UID 刪除，實作時附來源與 S20 的 `pm` 實測：tu2 套件的金鑰在重裝後不存在）；`store_has_records` 讀不到目錄時回 false（simple.rs:47）→ 這正是「不刪既有金鑰」的理由 | JVM：`firstRunPlan` 四種情況（全無、部分、全有、有一把等級不符）；負向對照：改回「全部產生」→ 部分那條 FAIL。Instrumented（只在模擬器 `adb -s emulator-5554`，不碰手機）：已有一把金鑰時 firstRun 不換掉它（比對公鑰）——模擬器 Keystore 等級 0 被政策拒絕，所以這條測「不刪既有」，等級判斷由 JVM 測 |
| T16 | 222 | 中英混排：所有 `X` 範本（`'還沒讀到X 的狀態'` 等）改成依名字頭尾字元決定空白：ASCII 與中文相鄰才加一個空白，兩邊都中文不加（對稱，中文暱稱不會多空白） | 單元：英文 / 中文暱稱各一；負向對照：固定加空白 → 中文那條 FAIL |
| T17 | 117、190 | 改寫設計 R-6：一台節點只有一個擁有者。「對方連著時這邊顯示連不到」那一半改成用電腦的 `bluetoothctl` 連著 04 來驗（不需第二支手機，之後真機場次做，要同意）；「兩個 app 各管自己的節點輪流在前景」要第二台由 dev2 管的節點（02 重燒後）。:117 的文字更新（R-4、A22 已在 #349 做完） | 文件 |
| T19 | 112 | 刪 main.dart:97-99 死碼 | analyze |
| T20 | 114 | ScanPage：掃描期間 `rawBusy`，取消完成後才 `rawIdle`（dispose 不再提早交回） | widget：dispose 時佔用留到掃描取消完成；拿掉 → FAIL |

## 3. 不做（理由寫進 #329 並打勾或留著）

| # | #329 行 | 決定 | 理由 |
|---|---|---|---|
| N1 | 115 prober 在 msg2 之後斷線要等 20 s | **不修**，打勾附理由 | 原始碼已查證（reactive_ble `onDone` 不接，prober.dart:262）；但真機遠端打不到 msg2 到回答之間 1–2 s 的窗口（重現不到），而結果本來就正確、只是多等；修法要處理最後一個 frame 與斷線事件的先後、hint 視窗、交接取消三條新契約（兩位審查都指出），風險大於收益。照規則：重現不到不修。**因此不需要重開 04**（使用者同意的那次不用了） |
| N2 | 118 太舊節點「讀不到…」 | 子項不改；本體 A13 仍要使用者在場（留著） | app 讀得到「沒有 trust」，但「沒有 trust」不等於「太舊」（也可能是設定損壞），改句子會說錯 |
| N3 | 219 全隊卡片後四碼 | 維持 PR 6 偏離（:219 已寫） | 隊長的 net 紀錄有 device_id，隊員的名單來源沒有；只做隊長那半，兩種角色畫面不一致；要改協定 |
| N4 | 221 30 s 記憶位址等待 | 不改常數；歸因寫進設計 §10 A1 | 設計 §4.3 凍結、R-7 9/10 ≤ 20 s 通過 |
| N5 | 147、148、177 | 使用者 2026-11-18：先不回 N0；02 要重燒 | — |

## 4. 驗收文件與畫板（87、88、92）

- 先**空跑**：在現有畫板測試加 `androidTapTargetGuideline`、`textContrastGuideline`、「最多一顆實心主按鈕」三個斷言，記下 FAIL 數，再修。開發者頁（10.2 以下）照設計 §3.4 不在 T-C4a 範圍，但 48dp 與對比照樣要過（現場維修人員也用）。
- 補從沒渲染的畫板：3.3、3.4、3.7、9.x 完成 / 退回、10.5、開發者各頁、6.x（假 visible）。
- 淺、深兩色**全部**打開看過，重寫 `p1p2-check.md`，每格寫看了什麼；沒看的格子明寫「沒看」。
- 真機對比：adb 截 S20 主要頁（不改狀態），以「文字像素中最常見色 vs 背景最常見色」的 WCAG 對比公式算，方法寫進 p1p2-check；FLAG_SECURE 頁截出全黑記 ❓，不算過。

## 5. 真機（S20 + 04）與副作用

| 動作 | 副作用 | 還原 |
|---|---|---|
| `adb install -r` 本 PR 的 dev APK | 換 app 程式，資料與金鑰保留 | — |
| 截圖、操作 app（節點頁、首頁、診斷） | 無 | — |
| 測藍牙關閉時節點頁的按鈕：`cmd bluetooth_manager disable/enable` | 手機藍牙關開一次（改手機設定）→ **開場前取得同意** | 開回 |
| T1 在 S20 量 open 耗時 | 無（讀 log） | — |
| T14：tu2 套件重裝後金鑰不存在的實測 | 在 `dev.batman.app.tu2`（測試用、不持有節點）上 `install -r` 不會清金鑰；要證明「解除安裝會清」須解除安裝 tu2 → 規則禁止解除安裝 → **改用 AOSP 原始碼證據**，真機不做 | — |

04 在網路中，所以節點頁「還沒加入網路」的分支真機看不到 → ⚠️ 只有 widget 測試。

## 6. 契約、生命週期、安全（T1、T2、T14 是金鑰變更）

- **擁有者**：Keystore 的四把金鑰只有 `Keys`（Kotlin）能產生 / 刪除；firstRun 從「可能全部重產」改成「只補缺、只刪自己新產生的」。`_install` 是唯一呼叫者（加上 device_check 的 T-U2，已有防呆）。
- **生命週期**：第一次安裝（全無 → 全產生、selfTest、marker）；第一次啟動中斷（部分 → 下次補齊，不再全部重產；今天是全部重產，結果相同但不會毀掉既有的）；marker 遺失但有紀錄（不呼叫 firstRun，現況）；marker 遺失、紀錄目錄讀不到（`store_has_records` 回 false → 呼叫 firstRun → 現在**不會**刪掉既有金鑰，紀錄保住；今天會毀掉——這是 T14 修掉的實際風險）；既有金鑰等級降級（拒絕、不寫 marker、app 顯示金鑰問題）；升級 / 降級 app（firstRun 只在沒有 marker 時跑，不影響）。
- **安全（逐 actor）**：本機無特權 app 碰不到別的 UID 的 Keystore；被入侵的節點不經過這條路；我們自己的錯誤（檢查程式、重產）是 T14 要防的對象。T1：open 多經一道政策（等級不符拒絕），fail-closed。T2：只減少一份明文副本，不宣稱清乾淨。
- **失敗模式**：firstRun 失敗 → 不寫 marker（現況），下次再補；fail-closed。

## 7. 測試總表

每項各有測試與負向對照（§2 表）。全套 = WSL `test-all.sh` + Windows `flutter test` + `flutter analyze lib test device_check` + Kotlin JVM 測試（`app/tools/kotlin-unit-tests.sh`）+ 模擬器 instrumented（T14，`adb -s emulator-5554`）。

## 8. 第一輪審查對應

| 審查 | 對應 |
|---|---|
| A-B1 / B-B1（T14 沿用半套金鑰） | T14 改「補齊、不刪既有」；§6 生命週期與證據 |
| A-M1 / B-M3（Keys 綁 AndroidKeyStore、JVM 測不了；金鑰變更沒有契約 / 安全段） | `firstRunPlan` 純函式 + 模擬器 instrumented；T2 改 lint；§6 |
| A-M2 / A-M3 / B-M2（T13 契約缺、真機打不到窗口） | 不修（N1），附理由 |
| A-M4 / B-M5（T6 範圍與重複入口） | T6 只加藍牙 / 權限按鈕；「加入網路」沿用 node-join 列；hint 時一顆實心；whyNext 改字 |
| B-M1（漏 6 項） | §1、§3 補 :90（設計已寫、實測要人）、:117、:118、:148、:177、:178 |
| B-M4（字級藏在算式裡） | T8 (b) 運算式掃描 + 渲染字級檢查 + 2.0 倍重跑 |
| MINOR | T10 照設計做；T1 open private、量耗時、lint；T8 roundsEnded 定義；T16 對稱；T3 T-G5 鎖寫紀錄；N2 / N3 定案；T17 bluetoothctl；T20 ScanPage；§4 空跑 FAIL 數、開發者頁、真機對比方法；§5 副作用；§7 負向對照 |
