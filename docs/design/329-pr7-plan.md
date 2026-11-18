# #329 PR 7 計畫（v3）：可遠端完成的剩餘項目

基準（已審過、不重審）：`docs/design/329-app-uiux.md` v12.1、PR 1–6 已合併的行為（main 3020374）。本計畫只列新範圍。

v1 → v2：第一輪 A（1 / 4 / 11）、B（1 / 5 / 12），都 REJECT（T14）。v2 → v3：第二輪 C（1 / 2 / 11）、D（0 / 3 / 11），都 REJECT（T14 換了一個同類的毀損路徑；漏項）。v3 的 T14 改在根源修（兩位都這樣建議），Kotlin `firstRun` 不動。對應在 §9。

## 1. #329 全部 49 個未勾項目的去處（逐行；合計 49）

類別：**做** = 本 PR 做；**勾** = 已解 / 已過時 / 使用者已決定，本 PR 打勾；**接受** = 決定不修、寫成接受的殘項（留著，關單時一併確認）；**場** = 要使用者在場；**硬** = 要額外硬體；**同意** = 可遠端但會改節點或手機狀態，本 PR 的真機場次開場前一次問。

| 行 | 項目 | 類別 | 處理 |
|---|---|---|---|
| 84 | 原型確認 | 勾 | 已打勾（使用者 2026-11-18） |
| 85 | 設計兩位審查 | 勾 | 已打勾（使用者 2026-11-18） |
| 86 | 未看過 app 的人走完一輪 | 場 | 要真人；02 要先重燒 |
| 87 | P1 / P2 逐項截圖對照 | 做 | §4 |
| 88 | 深色、48dp、對比實測 | 做 | §4（畫板斷言 + 真機截圖量對比） |
| 89 | S20 走過全部主要流程 | 場 + 同意 | 已走：情境 5、8（暱稱、國家）、9；本 PR 真機補情境 8 / 9 的中斷（見 91）；其餘（1、2、3、6、7、8 Wi-Fi）要 02 重燒或使用者在場 |
| 90 | 情境 1–10 寫進設計 + 一般隊員實測 | 勾一半 / 場 | 設計 §6 已寫完（:796-811）；改寫這行成「實測」那一半留著 |
| 91 | 每條情境的三種中斷 | 同意 + 場 | 本 PR 真機：情境 8（改暱稱、國家頁）與 9（離開、加回）各做關藍牙、04 重開、切背景（要同意）；1、2、3、6、7 要 02 重燒或使用者在場 |
| 92 | 一致性檢查表逐畫面 | 做 | §4 |
| 104 | 舊 ClaimPage 返回 | 勾 | 已打勾 |
| 105 | X26 只認 keyLevel；open 不經閘門 | 做 | T1 |
| 106 | 明文無法在 Dart 端清零 | 做一半 + 接受 | T2（Kotlin 自己那份清零）；Dart 端寫成接受的殘項 |
| 110 | 舊頁不走 BleGate / RecordWriter；T-G5 | 做 | T3 |
| 111 | BleGate 藍牙關閉不另外拒絕 | 接受 | T4 理由 |
| 112 | 啟動頁等佔用的字 | 做 | T19，合併後打勾 |
| 113 | openRawPage 測試 | 做 | T12 |
| 114 | 舊頁佔用先交回 | 做 | T20，合併後打勾 |
| 115 | prober msg2 後斷線白等 20 s | 接受 | N1：原始碼已證實會白等；真機**沒嘗試**（遠端打不到窗口）；結果正確只多等，修法要三條新契約 → 不修，寫成接受的殘項 |
| 117 | 發布前一次做完 R-3 / R-4 / A22 / A11 / R-6 / A13 | 改寫 + 場 | R-4、A22 已在 #349 做完（改寫這行）；R-6 → T17；其餘要使用者在場 |
| 118 | A13：VPN | 場 | 子項（太舊節點的句子）N2 不改；本體要使用者在場 |
| 120 | 舊「我的節點」登入例外 | 勾 | 已打勾 |
| 122 | B 組在 PR 1 合併 commit 的 APK | 勾 | 已打勾 |
| 125 | 節點頁沒有主要按鈕 | 做 | T6 |
| 126 | 看清單 | 做 | T7 |
| 127 | 頭兩輪、字級 | 做 | T8 |
| 128 | 「網路：」 | 做 | T9 |
| 129 | S10 BLE 位址 | 做 | T10 |
| 130 | 第 6 列中性按鈕 | 勾 | 已打勾 |
| 147 | 04 回 N0 | 勾（決定） | 使用者 2026-11-18：先不回 N0（已記） |
| 148 | 02 B 槽重寫 | 場 | 被 02 重燒擋住；重燒後再確認是否還需要 |
| 177 | 04 回 N0 與 02 B 槽 | 同 147 / 148 | — |
| 178 | R-7 大部分情境 | 場 + 同意 | 同 89 / 91 |
| 181 | R-3 拔電、A11、建網途中拔電、04 不開機 | 場 | 實體操作 |
| 182 | A13 VPN 排除 | 場 | 手機的 VPN 設定 |
| 183 | 重掃機身 QR | 場 | 要人拿手機對實體 QR |
| 184 | 密碼欄、FLAG_SECURE 人眼 | 場 | widget 已鎖（settings_pages_test.dart:158）；FLAG_SECURE 截圖是黑的，只能人看 |
| 185 | 未看過 app 的人實測 | 場 | — |
| 188 | 第二支手機 | 硬 | — |
| 189 | 第三台節點、其他 Android | 硬 | — |
| 194 | BLE 133 根因（btsnoop） | 同意 | 可遠端：`adb` 開 HCI snoop（改手機開發者設定）→ 重現 133 → 拉 log 分析。**本 PR 真機場次一起問**；不同意就留著 |
| 199 | 首頁待辦競爭 | 做 | T11 |
| 201 | 02 擁有者金鑰毀 | 場 | 重燒 |
| 216 | 02 重燒後情境 1 / 2 / 3 / 6 | 場 | — |
| 217 | 情境 7 + X14 | 場 | VPN、AP 密碼 |
| 218 | 情境 8 手機 Wi-Fi | 場 | AP 密碼 |
| 219 | 全隊卡片後四碼 | 接受 | N3 |
| 220 | Kotlin firstRun 沒有防呆 | 做 | T14（在根源修，見下） |
| 221 | 30 s 記憶位址等待 | 接受 | N4 |
| 222 | 中英混排 | 做 | T16 |

合計：做 19（87、88、92、105、106 半、110、112、113、114、125–129、199、220、222）· 勾 / 決定 10（84、85、104、120、122、130、147、177 隨 147 / 148、90 一半）· 接受 5（106 半、111、115、219、221）· 場 / 硬 / 同意 其餘。逐行各屬一列，共 49 行。

## 2. 本 PR 做的

| # | 行 | 做法 | 測試與負向對照 |
|---|---|---|---|
| T1 | 105 | Kotlin `"open"` 經金鑰政策：**只檢查 RECORD_AES 一把的等級**（不是 keyCall 的四把全查：另外三把暫時讀不到時，open 失敗會讓 `ui_state` 與 joinreq 的 mpend 被當「沒有」而覆寫，owner_console.dart:544、owner.rs:1294——兩位審查指出），錯誤用同一套 `keyLevel` / `keystore` 分類（X26 因此認得 open 的等級拒絕）。`Keys.open` 改 private。S20 量 open 耗時（讀 log）。Dart 端：open 的 `keyLevel` 拒絕 → 2.4（現在的 X26 路徑）——加 Dart 測試 | Kotlin：KeyHandlersTest 加「RECORD_AES 等級不符 → keyLevel；另一把讀不到 → open 照樣成功」；lint 測試加 open 走政策（拿掉 → FAIL）。Dart：假通道回 open 的 keyLevel → 2.4（拿掉 refusedBy 的 open → FAIL） |
| T2 | 106 | Kotlin 在 `result.success(plain)` 之後 `plain.fill(0)`；寫明 codec 緩衝、Cipher 內部、Dart 端都還有明文，不宣稱清乾淨 | 白箱：抽出 `openAndWipe(open, reply)`，JVM 測試斷言回覆之後 ByteArray 全 0（拿掉 fill → FAIL） |
| T3 | 110 | ClaimPage / ScanPage 保留原始佔用（改設計 §5.3、§4.4 寫明）。T-G5 原始碼鎖：直接呼叫紀錄寫入（`storeWrite*` / `storeRemove` / `storeKeepCopy`）的檔案只准：`record_writer.dart`、`claim_records.dart`（認領寫入是新憑證唯一的一份，佔用收回後也不能拒絕）、`ui_state.dart`（`ui/state-v1` 不經佔用，設計 §4.6）、`main.dart`（安裝 marker）、`app_link.dart`（建 RecordWriter）、生成碼 `lib/src/rust/**` | 掃描測試：新加一個檔案直接寫 → FAIL；先在 main 上空跑確定 0 FAIL |
| T4 | 111 | 接受：權限收回時系統直接結束行程（A22 實測）；藍牙關閉時 NodeLink 前提擋住 | — |
| T6 | 125 | 節點頁 StatusHero 的 `extra`：藍牙關閉 → `Btn.openBluetooth`；沒有權限 → 開 `PermissionsPage`（同首頁 2.2；永久拒絕的分辨在那一頁做）。「加入網路」沿用 node-join 列，不加重複入口；不加「建立網路」（PR 3 D8）。有 hint 按鈕且藍牙關閉 → 藍牙那顆是唯一實心。`whyNext` 的「請回首頁按」改成指向這顆按鈕 | widget 三種狀態；藍牙 + hint 只有一顆實心；拿掉 extra → FAIL |
| T7 | 126 | 第 7、8 列加 `Btn.showList` → `Scrollable.ensureVisible` 到清單 | 兩台紅 → 有按鈕、按了清單可見；拿掉 → FAIL |
| T8 | 127 | (a) 「頭兩輪」改成**每台**：`NodeState.roundsEnded` = 讀過這一台、正常結束的輪數（被取消的不算；首頁全輪、節點頁單台輪、提前再讀都算，因為都讀了它）；`firstRounds(id) = roundsEnded < 2`；三處 `roundsRun < 3` 改用它。只增不減，`start()` 時歸零（和 states 同生命週期）。(b) 字級：逐處對到 §3.1 六級（現值 → 目標列在 commit；確認碼大數字 40 / 44 / 24 白名單）；畫板在 2.0 倍字級重跑，溢出 = FAIL | (a) core 測試：第 2 輪結束前 true、結束後 false；取消的輪不算（改回 roundsRun → FAIL）。(b) 運算式掃描（`Fs.x ± n`、數字常數）+ 渲染字級檢查（放一個非六級 → FAIL） |
| T9 | 128 | 節點頁 StatusHero 下加 membership line，**只在讀取新鮮、而且 k1 ≠ 1 時**（PR 2 第一輪 B-m12 的條件） | S6 新鮮 → 有「網路：」；不新鮮 / k1=1 → 沒有；拿掉條件 → FAIL |
| T10 | 129 | 照設計 §3.4 S10：認領時的 BLE 位址放進技術資訊 | 主畫面沒有、技術資訊有；不放 → FAIL |
| T11 | 199 | 首頁存 pending id 清單，build 時對當下 `core.states` 過濾 | states 晚到 → 待辦消失；改回 → FAIL |
| T12 | 113 | `openRawPage` 測試 | 拿掉 release → FAIL |
| T14 | 220 | **在根源修**：`store_has_records` 改成三態（Rust 回 `Result<bool, String>`）：某個紀錄種類的目錄**不存在** → 該種類沒有；目錄或其中任一項**讀取錯誤** → 回錯誤（不再 `unwrap_or(false)`）。`_install` 收到錯誤 → **不呼叫 firstRun、不碰金鑰**，啟動檢查顯示「讀不到手機裡的紀錄，金鑰保持原樣」+「再試一次」（同 `keys.unread` 的處理）。Kotlin `firstRun` 不改（部分金鑰時全部重產的行為保留——那時確定沒有紀錄，重產不會丟資料，而且能從中斷中恢復）。`_install` 的錯誤句「金鑰已全部刪除」保留（firstRun 失敗時確實全刪，Keys.kt:187-189）。device_check 的 T-U2 已有防呆 | Rust：目錄不存在 → false；有紀錄 → true；目錄讀取錯誤（權限 000 的暫存目錄）→ Err（改回 unwrap_or → FAIL）。Dart：假 `storeHasRecords` 丟錯 → firstRun 沒被呼叫、畫面有「再試一次」（拿掉分支 → FAIL）。FRB codegen |
| T16 | 222 | Dart 的 `X` 範本：名字頭 / 尾是 ASCII 英數、而且旁邊是中文字時才加一個空白；中文標點、中文字相鄰不加。Rust 給的句子不改（另有自己的格式） | 英文 / 中文 / 英文開頭中文結尾各一；固定加 → 中文那條 FAIL |
| T17 | 117 | 改寫設計 R-6（一台節點只有一個擁有者）：「對方連著時這邊顯示連不到」改用另一台主機的 bluetoothctl 連著 04 驗——**主機待確認**（Windows 的 WSL 碰不到藍牙；Pi 500 ⚠️ 未查），驗證留在 #329；「兩個 app 各管一台輪流前景」要 02 重燒 | 文件 |
| T19 | 112 | 刪 main.dart:97-99 死碼 | analyze |
| T20 | 114 | ScanPage：掃描用**另一個旗標**持有佔用（`_scanHold`），不動 `_busy`（`_read` 用它判斷，scan.dart:81-82）；dispose 時等掃描取消完成才交回 | 掃描中點一台 → 會發出連線；dispose → 佔用留到取消完成；拿掉 → FAIL |

## 3. 接受的殘項（寫進 #329，關單時一併確認）

| # | 行 | 理由 |
|---|---|---|
| N1 | 115 | 白等 20 s 原始碼已證實（reactive_ble `onDone` 不接，prober.dart:262）；真機沒嘗試（遠端打不到 msg2 到回答之間 1–2 s 窗口）；結果正確只多等；修要處理最後 frame 與斷線事件先後、hint 視窗、交接取消三條新契約，風險大於收益 |
| N2 | 118 子項 | 「沒有 trust」不等於「太舊」（也可能設定損壞），改句子會說錯 |
| N3 | 219 | 隊長的 net 紀錄有 device_id、隊員的名單沒有；只做一半兩種角色不一致；要改協定 |
| N4 | 221 | §4.3 凍結；R-7 9/10 ≤ 20 s 通過；59.9 s 的歸因寫進設計 §10 A1 |
| N5 | 106 Dart 端 | 平台唯讀緩衝區 |
| N6 | 111 | T4 |

## 4. 驗收文件與畫板（87、88、92）

- **先空跑**：現有畫板測試加 `androidTapTargetGuideline`、`textContrastGuideline`、「最多一顆實心主按鈕」，記下 FAIL 數再修；開發者頁一樣要過 48dp 與對比。
- 補從沒渲染的畫板：3.3、3.4、3.7、9.x 完成 / 退回、10.5、開發者各頁、6.x（假 visible）。
- 淺、深兩色**全部**打開看過，重寫 `p1p2-check.md`；沒看的格寫「沒看」。
- 真機對比（方法寫死，用 Dart 小程式在電腦上算，不用 python）：`uiautomator dump` 取每個文字元素的 bounds → `screencap` → 在 bounds 內取顏色直方圖，背景 = 最多的顏色，前景 = 和背景亮度差最大、且佔 ≥ 2% 的顏色 → WCAG 對比公式。列每個元素的數字；< 4.5:1 的逐一歸因。FLAG_SECURE 頁截出全黑 → ❓，不算過。

## 5. 真機（S20 + 04）與副作用——開場前一次問

| 動作 | 副作用 | 還原 |
|---|---|---|
| `adb install -r` 本 PR 的 dev APK | 換程式，資料與金鑰保留 | — |
| 截圖、操作 app | 無 | — |
| 關開藍牙（`cmd bluetooth_manager`）：T6 節點頁按鈕、91 的中斷 | 手機藍牙關開數次 | 開回 |
| SSH 重開 04（91：情境 8 / 9 的節點重開中斷） | 04 斷線約 1.5 分鐘 | 自己回來 |
| 情境 9 再走一次（04 離開、加回 bm-94676ef40105） | 04 網路暫時變動 | 加回 |
| btsnoop（194）：`settings put secure bluetooth_hci_log 1` + 藍牙關開 → 重現 133 → `adb bugreport` 取 log → 關回 | 改手機開發者設定、bugreport 檔很大 | 設定關回 |
| T1 open 耗時 | 讀 log | — |

只用 `adb -s RFCN30HMRAR install -r`；不跑 `flutter install` / `flutter run` / `connectedAndroidTest`；本 PR 沒有 instrumented 測試。04 在網路中，節點頁「還沒加入網路」的分支真機看不到 → ⚠️ 只有 widget 測試。

## 6. 契約、生命週期、安全

- **T14 `store_has_records`**：寫者 = 無（唯讀）；讀者 = `_install`。缺：目錄不存在 = 沒有（第一次安裝的正常情況）；壞：讀取錯誤 = 回錯誤（fail-closed：不重產金鑰）。生命週期：第一次安裝（目錄不存在 → false → firstRun，現況）；marker 遺失 + 紀錄在（true → 不碰，現況）；marker 遺失 + 目錄讀不到（**今天：false → firstRun 全部重產 → 紀錄永遠打不開；之後：錯誤 → 不碰金鑰、可重試**）；第一次啟動中斷留下部分金鑰（目錄不存在 → firstRun 全部重產，現況保留，能恢復）。
- **T1**：open 多一道 RECORD_AES 等級檢查（fail-closed）；其他三把讀不到不影響 open（避免覆寫）。
- **T2**：少一份明文副本；不宣稱清乾淨。
- **安全（逐 actor）**：本機 app 碰不到別的 UID 的 Keystore 與 filesDir；被入侵的節點不經過這些路；我們自己的錯誤（T14 的毀損路徑、檢查程式）是要防的對象。
- **失敗模式**：全部 fail-closed（T1 拒絕、T14 不動金鑰）。

## 7. 註解與文件同步

T-U2 檔頭、KeyHandlers / MainActivity 提到 open / firstRun 的註解、設計 §5.3 / §4.4 / §3.4 S10 / R-6 / §10 A1、#329 各行，照 §1 的類別更新。

## 8. 測試總表

每項各有測試與負向對照（§2）。全套 = WSL `test-all.sh` + Windows `flutter test` + `flutter analyze lib test device_check` + Kotlin JVM 測試（`app/tools/kotlin-unit-tests.sh`）。

## 9. 審查對應

| 審查 | 對應 |
|---|---|
| A-B1 / B-B1 / C-B1 / D-M2（T14 毀損或卡死） | T14 改在根源（`store_has_records` 三態）；Kotlin firstRun 不改 |
| C-M1（`_install` 前提）/ C-M2 / A-M1 / B-M3（測不到清理、Keys 綁 Keystore） | firstRun 不改 → 不需要清理測試；Rust + Dart 測試覆蓋新路徑；§6 |
| B-M1 / C（:90、:178 沒列）/ D-M1（17 行不見） | §1 逐行 49 列 |
| D-M3（ScanPage `_busy`） | T20 另一個旗標 |
| A-M2 / A-M3 / B-M2（T13） | N1 接受（不打勾） |
| A-M4 / B-M5（T6） | T6 |
| B-M4（字級） | T8 (b) |
| C / D MINOR | T1 只查 RECORD_AES（避免覆寫）+ Dart 2.4 測試；T2 白箱；T3 例外清單完整、先空跑；T6 PermissionsPage；T8 每台 roundsEnded、生命週期；T9 B-m12；T16 標點；§4 對比方法寫死；§5 btsnoop、只用 install -r、沒有 instrumented；N1 寫成接受；§7 註解清單；T17 主機待確認 |
