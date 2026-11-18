# #329 PR 7 計畫（v1）：可遠端完成的剩餘項目

基準（已審過、不重審）：`docs/design/329-app-uiux.md` v12.1、PR 1–6 已合併的行為（main 3020374）。本計畫只列新範圍。

來源：#329 本體全部 49 個未勾項目逐條盤點（2026-11-18，唯讀；結果存 scratchpad `i329d.md` 與盤點報告）。分類：已解 / 可遠端改程式 / 要動手機或節點（要同意）/ 要使用者在場 / 要硬體 / 要決定。本 PR 收「可遠端改程式」的全部，加上技術細節由我定案的項目；要使用者在場或要硬體的不在本 PR（留在 #329，逐條寫原因）。

## 1. 直接打勾（現有程式已解或已過時，附證據）

| #329 行 | 項目 | 證據 |
|---|---|---|
| 104 | 舊 ClaimPage 返回後結果丟失 | F41 已修：claim.dart:183-190 `goneNote` → home_page.dart:246、:340-346；test add_pages_test.dart:162-169；「我的節點」PR 6 已刪 |
| 112 | PR 1 啟動頁等佔用的字 | 舊啟動頁只在 `_app == null` 時出現，`_open` 那時不拿佔用（main.dart:91-95）；:97-99 是死碼，本 PR 刪 |
| 114 | 舊頁關掉時佔用先交回 | NodesPage 已刪；ClaimPage finally 先 `await conn?.cancel()`（claim.dart:499-502）。殘留：ScanPage dispose 不等掃描取消（開發版，scan.dart:45-47）→ 寫一行殘留 |
| 120 | 舊「我的節點」登入例外沒取消連線 | NodesPage 已刪；ClaimPage 在 requestMtu 前就指派 conn（claim.dart:405-409） |
| 122 | B 組要在 PR 1 合併 commit 的 APK 跑 | PR 1 已合併，合併條件 :117 已改寫 |
| 130 | 第 6 列中性按鈕碰不到 | NetIndex 讀不到目錄 → `NetRecords.unknown` → 中性「加入網路」（net_index.dart:135-147、home_logic.dart:93）；test net_index_test.dart:95、home_logic_test.dart:99 |

## 2. 技術細節定案（不需使用者決定；理由附上）

| # | 項目 | 定案 | 理由 |
|---|---|---|---|
| T1 | 105 X26 | Kotlin `"open"` 改走 `keyCall`（KeyPolicy 檢查 RECORD_AES 等級），錯誤分類和其他金鑰呼叫一致；「金鑰前提變 false 後要重開 app 才恢復」**維持**（review pr1 B-M5 刻意的設計，避免金鑰狀態抖動時自動恢復） | open 是唯一繞過閘門的金鑰呼叫；恢復策略是已審過的基準 |
| T2 | 106 明文清零 | Dart 端是平台唯讀緩衝區，修不了 → 記為已知殘留；Kotlin 在 `result.success` 之後把自己那份 ByteArray 清零（Dart 收到的是複本，不受影響） | 能做的那一半做掉 |
| T3 | 110 ClaimPage / ScanPage 的原始佔用 | **不改**走 BleGate / RecordWriter；改設計 §5.3、§4.4 寫明這兩頁保留原始佔用（PR 1 機制、900 s 上限、測試已有），T-G5 原始碼鎖改成「只有這兩頁可以用原始佔用」 | 兩頁行為已被 PR 1–6 的測試與真機覆蓋；重寫認領流程風險大、對現場沒有新的保護。原始碼鎖防止新頁面再用原始佔用 |
| T4 | 111 BleGate 藍牙關閉 | 不改，關掉：權限被收回時系統直接結束行程（A22 實測）；藍牙關閉時 NodeLink 前提已擋住，flow 也先看前提 | 加一層不增加保護 |
| T5 | 118 太舊節點的「讀不到…請重新整理」 | 不改：app 無法確定節點是否太舊，現在的句子沒錯 | — |
| T6 | 125 節點頁主要按鈕 | 加：藍牙關閉 →「開啟藍牙」、沒有權限 →「允許藍牙權限」、還沒加入網路且手機有網路紀錄 →「加入網路」（同首頁第 6 列）；**不加「建立網路」**（PR 3 D8 已定案：節點頁不建網，從首頁建） | 照 §5.5 / §5.1 第 6 列；D8 是已審過的基準 |
| T7 | 126 看清單 | 第 7、8 列（多台有事）加「看清單」→ 捲到節點清單 | 照設計 |
| T8 | 127 頭兩輪、字級 | core 加 `roundsEnded`，`firstRounds = roundsEnded < 2`；所有 `fontSize:` 收進 `Fs` 六級（確認碼大數字列白名單），加原始碼掃描測試 | 照設計 §3.1 |
| T9 | 128「網路：」 | 節點頁 StatusHero 下加 membership line（`statusMembershipLine`，設計 `StatusFields`），S6 / S9A 句子說的「網路：」就在畫面上 | 照設計 |
| T10 | 129 S10 BLE 位址 | 不放進技術資訊（隱私）；設計 §5.3 只要求畫面不顯示 → 關掉 | — |
| T11 | 199 首頁待辦競爭 | 首頁存 pending id 清單，build 時對當下 `core.states` 過濾（不在拿清單那一刻算數量） | — |
| T12 | 113 `openRawPage` 測試 | 補 widget 測試（佔用等候中 navigator 卸載 → 釋放） | — |
| T13 | 115 prober msg2 後斷線 | probe 聽 `link.state`，斷線 → 立刻結束（不等 20 s）；假 backend 測試 + 負向對照 | 結果不變、少等 |
| T14 | 220 Kotlin `firstRun` | `Keys.firstRun()` 已有任何一把金鑰時**拒絕**（錯誤 `keysExist`），不再無條件重產；`_install` 在「沒有 marker、沒有紀錄、金鑰還在」時收到 keysExist → 沿用現有金鑰、寫 marker（金鑰沒有被用來封任何紀錄，沿用不會丟資料；重產反而可能毀掉別人以為還在的東西）。Kotlin 單元測試 + 負向對照 | 防止任何呼叫者（含檢查程式）毀掉金鑰；T-U2 事故的根本防呆 |
| T15 | 221 30 s 記憶位址等待 | **不改**常數（設計 §4.3 凍結、R-7 9/10 ≤ 20 s 通過）；把真機 59.9 s 的歸因寫進設計 §10 A1 回填 | 改常數要重審 §4.3 排程 |
| T16 | 222 中英混排 | 暱稱以 ASCII 開頭時補一個空白（「還沒讀到 R7-test04 的狀態」） | 極小 |
| T17 | R-6（:117、:190） | 改寫設計 R-6：一台節點只有一個擁有者，「兩個 app 輪流讀同一台」改成「dev 與 dev2 各管自己的節點、同時在前景切換」+ 對方連著時的那一半由 T-L16（模擬）涵蓋；真機要第二支手機（D 組） | 前提錯，照實改寫 |
| T18 | 219 全隊卡片後四碼 | 先查 `Listed` 是否有 device id 可用：有 → 加到卡片（Rust 加欄位、Dart 顯示）；沒有 → 維持 PR 6 偏離，寫明要協定層改 | 能做就做 |
| T19 | 112 死碼 | 刪 main.dart:97-99 | — |

## 3. 驗收文件與畫板（87、88、92）

- 在本 PR 的 HEAD 重跑全部畫板測試（retest_s_boards、retest_s_boards_p、pr6_boards），補從沒渲染的：3.3、3.4、3.7、9.x 完成 / 退回、10.5、開發者各頁、6.x（假 visible）。
- 所有畫板加三個斷言：`androidTapTargetGuideline`、`textContrastGuideline`、每頁最多一顆實心主按鈕（目前只有 layout_test 約 50 頁有）。
- 淺、深兩色**全部**打開看過，重寫 `docs/design/329-reviews/p1p2-check.md`（PR 6 之後的狀態），每格寫看了什麼。
- 真機對比：用 adb 截 S20 主要頁（不改狀態，只操作 app；FLAG_SECURE 頁截出來是黑的，寫明）計算文字與背景的像素對比，記錄數字。

## 4. 真機（S20 + 04）

- 本 PR 改動的畫面：節點頁的主要按鈕（關藍牙時、04 在網路中）、看清單（只有一台時不會出現，寫明）、「網路：」行、首頁待辦、字級。
- 115 的真機前提：SSH 重開 04 時 prober 的行為（要同意：重開 04，約 1.5 分鐘斷線，自動回來）。
- 真機對比截圖。

## 5. 不在本 PR（留在 #329，原因寫在那裡）

要使用者在場：86、89、91 的其餘情境、181–185、194、201、216–218。要硬體：188、189。使用者已決定（2026-11-18）：84、85 算通過（已打勾附說明）；147 先不回 N0；同意 SSH 重開 04 一次驗 115。

## 6. 測試

每一項各有 widget / 單元 / Kotlin 測試與負向對照；全套 = WSL `test-all.sh` + Windows `flutter test` + `flutter analyze` + Kotlin 單元測試（`app/tools/kotlin-unit-tests.sh`，T1 / T2 / T14）。
