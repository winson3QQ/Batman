# #329 PR 7 計畫 v4 審查（審查者 G，第四輪）

範圍：`docs/design/329-pr7-plan.md` v4（ab8cdbe）整份（§1–§9 為 v3 本體，§10 覆蓋衝突處），對照本 worktree 原始碼（app/lib、app/android、app/rust）與 A–F 六份前輪審查。基準（設計 v12.1、PR 1–6）不重審。唯讀；沒有上機、沒有跑測試。

統計：**BLOCKER 0 / MAJOR 0 / MINOR 7**。結論：**APPROVE-WITH-CHANGES**（MINOR 併入實作 / 開場前的文字即可，不需再整輪審查）。

---

## 第三輪 MAJOR 的處理

| 前輪 | v4 狀態 | 依據 |
|---|---|---|
| F-M1 btsnoop / bugreport 隱私 | ✅ 已解決 | §10 把 btsnoop 整個移出本 PR，#329:194 改「要使用者同意或在場（另一場）」，並把 bugreport 的內容（通知、帳號、SSID、logcat、所有藍牙流量）與方法查證（`persist.bluetooth.btsnooplogmode` vs settings）寫進待辦。本 PR 不再取 bugreport，風險面消失。殘留文字不一致見 m-1 |
| F-M2 節點重開中斷的還原 / 停止條件 | ✅ 大致解決 | §10：只在畫面閒置、沒有送出中的請求時重開；前後唯讀 SSH 記錄；預期狀態（國家 US、網路 bm-94676ef40105）；不符 → 停、不自己修；5 分鐘 SSH 回不來 → 停整場；加回失敗 → 停。國家頁不在送出途中重開（F 的建議）。暱稱是只在手機的值（329-app-uiux.md:809「節點名稱 = 只在這支手機的暱稱」），重開不影響。剩下兩個缺口見 m-2、m-3 |

前兩輪 BLOCKER / MAJOR（A-B1 / B-B1 / C-B1 / D-M2 的 T14、C-M1、C-M2 / A-M1 / B-M3、B-M1 / D-M1、D-M3、A-M4 / B-M5、A-M2/M3/B-M2、B-M4）：v4 沒有改動這些部分，F 的判定照舊成立，沒有重新打開。我另外對 T14 / T1 對過原始碼：

- `store_has_records` 目前是 `read_dir(...).map(...).unwrap_or(false)`（app/rust/bridge/src/api/simple.rs:47）；`sweep_temps` 對種類目錄 `fs::read_dir(k.path())?`、但先 `continue` 掉非目錄（app/rust/batman-proto/src/store.rs:211-216）。§10 改正的「今天」描述（ENOTDIR 與目錄內一項錯誤）正確。
- `_install` 順序 sweep → marker → has_records → firstRun（app/lib/main.dart:211-238）；outer catch 把例外變成 retry（main.dart:148-157），所以 §10 要求 Dart 測試斷言新句子＋「不進首頁」才有負向對照，正確。
- T1：`KeyPolicy.refused(op, levels, ...)` 只走 `op.needs`（KeyPolicy.kt:53-58），以 `mapOf(RECORD_AES to level(RECORD_AES))` 呼叫即可只查一把；`Keys.level(role)` 已存在（Keys.kt:35）。`Keys.open` 改 private 只影響同 class 的 `selfTest`（Keys.kt:163-166），firstRun 的自測不經閘門，正確（那時還沒有 marker）。
- `KeyHandlersDeviceTest` 用 `Keys("bmtest")` 測試別名、只刪 bmtest-*（KeyHandlersDeviceTest.kt:19-20、:32-35），檔頭規定 `adb -s emulator-5554`（:22-27）；§10 的「模擬器加 open 案例」不會碰到 S20 的 batman-* 金鑰。

---

## MINOR

**m-1 §1 / §5 與 §10 的文字不一致（btsnoop、instrumented 測試、合計）。**
- 情境：實作者或問同意時照 §5 / §1 念，會把已移出的 btsnoop 一起問；或照 §5「本 PR 沒有 instrumented 測試」把 §10 新加的 `KeyHandlersDeviceTest` open 案例漏掉。
- 證據：§1:52（194「本 PR 真機場次一起問」）、§5:113（btsnoop 列）、§5:116（「本 PR 沒有 instrumented 測試」）都還在；§10 只用「改為 / 刪掉」描述。§1:24 的 105 仍寫「做」，§10 改成「做一半 + 接受」，合計的「接受」也要 +1。
- 修法：實作前把 §10 實際套進 §1 / §5 / §8（問同意用的那份清單必須是改過的版本），§8 全套加上「模擬器 `adb -s emulator-5554 ... am instrument -w -e class ...KeyHandlersDeviceTest`」一列。

**m-2 F-M2：加回後的重開沒先確認節點端沒有未 commit 的變更。**
- 情境：情境 9 加回後 app 顯示已套用（join2 以 info k10 = net_id 判定，254-app-join2.md:80），但節點端可能仍是「k10 存在 ∧ k11 = true」（254-app-leave.md:25：加入中也會這樣；「在它 commit 前重開會把它退回」）。這時「畫面閒置、沒有送出中的請求」成立，重開會把 04 退回網路外 → 觸發停止條件，04 留在網路外等使用者。
- 證據：§10 的重開前檢查只列 `uname -n`、country、`batctl n`、mesh id，沒有 k11 / 未完成變更。
- 修法：重開前加一個閘門：app 節點頁沒有「節點上還有沒完成的網路變更」那行（或唯讀讀 info k11 = false）；不成立就等（最多 10 分鐘，同 leave 文件的句子），仍不成立 → 不重開、記錄。

**m-3 F-M2：唯讀驗證指令本身沒先驗證。**
- 情境：`uci -q get wireless.*mesh_id` 不是合法的 uci 語法（uci get 不吃萬用字元），會回空；空字串被當「網路不符」→ 誤停，或被當「沒讀到、略過」→ 驗證形同虛設。`batctl n | wc -l` 在 02 不在網路時本來就是 0（或只有標頭行），對「04 是否還在 bm-94676ef40105」沒有鑑別力。
- 證據：§10:151 寫「`uci -q get wireless.*mesh_id` 之類」。
- 修法：開場前（唯讀）在 04 上試出確切指令（例如 `uci show wireless | grep -i mesh_id`，或 app 狀態頁 / info k10 的 net_id），把預期輸出寫進表；任一指令回空或錯誤 → 視為 ❓ 停下，不當通過。`batctl n` 只當參考，不當判定。另寫明「SSH 回來但 BLE / provd 5 分鐘內連不到」也算停止條件（現在只寫 SSH）。

**m-4 T2：白箱測試與接線鎖兩個都要。**
- 情境：§10 寫「白箱測試要能在拿掉 `fill(0)` 時 FAIL（不靠 lint 的 `wipe = true`）」。清零是在 MainActivity 的 `runOnUiThread` 裡（MainActivity.kt:83），JVM 測試碰不到；抽出 helper 測，只能抓「helper 裡拿掉 fill」，抓不到「open 那行沒傳 `wipe = true`」。而 lint 的正則把 `wipe = true` 當可有可無（MainActivityKeyUseLintTest.kt:27）。
- 修法：(1) 把 reply + wipe 抽成純函式並 JVM 測（拿掉 fill → FAIL）；(2) lint 對 `"open"` 與 `"ecdh"` 要求 `wipe = true` 必須出現（拿掉 → FAIL）。兩個負向對照都列進 PR body。

**m-5 T1：open 進 `keyCall` 後要把 `open` 加進 lint 的頻道清單。**
- 證據：`everyKeyChannelForwardsToKeyHandlers` 只列 keyLevels / signOwner / signAdmin / ecdh / seal（MainActivityKeyUseLintTest.kt:25）；MainActivity 的註解「Not gated: `open`」（MainActivity.kt:73-74）也要改。
- 修法：清單加 `open`（負向對照：open 留在舊的 `Thread { Keys().open }` → FAIL）。§7 的註解同步清單已涵蓋註解，lint 這點補進 T1 測試欄。

**m-6 T14 新句子與「不建議清除」斷言的寫法。**
- 現有斷言是 `find.textContaining('清除 App 資料'), findsNothing`（key_abilities_test.dart:617），在 firstRun 失敗那個案例，和 T14 不同案例，所以不衝突（已查）。
- 但 T14 的 Dart 測試若仿照這條加「不建議清除」斷言，而句子寫成「不要清除 App 資料」，就會自己撞到。修法：句子用 §10 的「不要清除資料或重裝」字樣，T14 測試斷言整句出現，並另斷言沒有任何以「請清除」開頭的建議；不要為了過測試放寬 :617。

**m-7 §10 T1 的「Kotlin open 的六個呼叫點」用語。**
- 那六個是 Dart 端呼叫平台方法 `open` 的地方（claim_records.dart、app_link.dart、ui_state.dart），不是 Kotlin。寫進 §6 時改成「Dart 端六個呼叫點」，避免實作者去 Kotlin 找。

---

## 從實際使用與各個角色出發查過、沒有新問題的部分

- **隊長的 S20 裝本 PR 的 APK**：有 marker → `_install` 在 main.dart:215-218 返回，T14 不走；RECORD_AES 是硬體等級 → T1 不擋；`ui_state` 在啟動檢查通過後才 open（main.dart:189-191），沒有新的啟動順序問題。
- **模擬器裝置測試**：只用 bmtest 別名，不碰 batman-* 金鑰；檔頭的 `-s emulator-5554` 流程不會碰到 S20。
- **btsnoop 移出後**：本 PR 不再取任何含個人資料的手機檔案；§4 的 `uiautomator dump` / `screencap` 只取 app 自己的畫面（FLAG_SECURE 頁是黑的）。
- **本機無特權 app / 被入侵的節點**：v4 沒有新增輸入面；T14 Err 的句子是固定字串加 Rust 錯誤的技術段，沒有秘密。
- **04 重開的 SSH 路徑**：走有線 link-local（329-pr6-plan.md:149），不隨 mesh IP 改變；網路不變時位址不變。

## 結論

**APPROVE-WITH-CHANGES。** F-M1 已解決、F-M2 大致解決，前輪 BLOCKER / MAJOR 沒有重開，v4 本身沒有新的 BLOCKER / MAJOR。m-1、m-2、m-3 要在開真機場次、問同意之前寫進計畫（m-2 是 F-M2 的延伸，避免 04 被重開退回網路外）；其餘併入實作。
