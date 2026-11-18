# #329 PR 7 計畫 v4 — 獨立對抗式審查 H（第四輪）

範圍：`docs/design/329-pr7-plan.md` v4（ab8cdbe；v3 本文 + §10，衝突時以 §10 為準）整份，對照本 worktree 原始碼（= main 3020374 + 計畫文件）、前幾輪審查 A–F、PR 6 真機紀錄 `pr6-device-2026-11-18.md`。基準（設計 v12.1、PR 1–6）不重審。唯讀：沒有上機、沒有跑測試、沒有編譯。證據是 `file:line`（路徑相對 `app/`，feed 相對 `feed/batman-prov/src/`）。

統計：**BLOCKER 0 / MAJOR 0 / MINOR 9**。結論：**APPROVE-WITH-CHANGES**。

---

## 前幾輪 BLOCKER / MAJOR 的處理狀況

| 前輪 | v4 狀態 | 依據 |
|---|---|---|
| A-B1 / B-B1 / C-B1 / D-M2（T14 毀損或卡死） | ✅ 已解決 | 三態只加在 `store_has_records`（rust/bridge/src/api/simple.rs:44-48，今天是 `.unwrap_or(false)` 與 `is_ok_and` 吞錯）；`firstRun` 不動（Keys.kt:185-189 失敗全刪）。唯一產品呼叫者 main.dart:220；marker 在時 main.dart:215-218 直接返回，S20 走不到 |
| C-M1 / C-M2 / A-M1 / B-M3 | ✅ 不適用 | 清理規則沒改 |
| B-M1 / D-M1（漏項） | ✅ | E、F 已逐行對過 49 列；§10 改正合計 |
| D-M3（ScanPage `_busy`） | ✅ | T20 另一個旗標；`_read` 只看 `_busy`（scan.dart:79-81）；`Lease.hold()` 計數式（lease.dart:60-70），§10 補了 `hold()` 丟 StateError 的處理（lease.dart:61） |
| A-M2 / A-M3 / B-M2（T13） | ✅ 接受（N1） | — |
| A-M4 / B-M5（T6） | ✅ | §10 補 `radio(permission: true)` |
| B-M4（字級） | ✅ | T8 (b) + §10 先空跑 |
| **F-M1**（btsnoop / bugreport 個資） | ✅ 已解決 | §10 整列移出本 PR，#329:194 改「要使用者同意或在場（另一場）」，並寫明 bugreport 的內容與方法要先查證 |
| **F-M2**（節點重開中斷沒有結束狀態 / 還原 / 停止條件） | ✅ 大致解決（細節見 m-2、m-3） | §10：只在畫面閒置時重開；前後唯讀記錄；國家 US / 網路 bm-94676ef40105 不符就停；5 分鐘 SSH 回不來停整場；加回失敗停。我對照原始碼確認：(1) 04 在網路中時國家頁只能看、不能改（PR 6 紀錄「要先離開網路才能改國家」），所以情境 8 的閒置重開不會碰國家；(2) 主機走乙太網 link-local（`fe80::…6c89%15`）SSH 04，`leave` 只動無線（node.go:1272-1317：commit → `ForgetMesh` → 移除 mesh marker），不碰 `/etc/dropbear/authorized_keys`（provhelper main.go:379 是另一條 SSH 金鑰命令）；PR 6 真機在設 SSH 金鑰之後走過離開 + 加回，結束時 SSH 仍可登入。所以就算加回失敗，04 仍可用 BLE（擁有者紀錄在 S20）與 SSH 管理，不會像 02 那樣失去 |

---

## 從實際使用出發（隊長 S20 + 遠端單台 04，沒人在現場）

我把真機場次可能讓 04 失去管理能力的路徑逐條走過：

1. **安裝本 PR 的 APK（T1 新接線）**：S20 目前 `appUsable` = true，代表 RECORD_AES 已是硬體等級（KeyPolicy.kt:62-65、:79-83）。T1 檢查的是同一個 `allowed(RECORD_AES, …)`，讀等級的方法也和啟動時 `keyLevels` 一樣（Keys.kt:37-43，S20 每次啟動都跑過）。所以正確實作的 T1 在 S20 不會擋 open。實作若有錯（例如讀錯 role），結果是 open 全部失敗：紀錄不會被刪；會吞錯並覆寫的只有 `ui/state-v1`（ui_state.dart:228）與 mpend（app_link.dart:204 → owner.rs:1293-1294），都不是擁有者憑證。用保留的 main APK `install -r` 就能回復（versionCode 都是 `1.0.0+1` → 1，pubspec.yaml:19、build.gradle:46，同版號允許）。→ 可回復，但開場順序要加一道關卡（m-1）。
2. **T14**：S20 有 marker，走不到。✅
3. **閒置重開 04**：PR 6 已實測一次（13:05:37 → 13:06:59 app 讀回）。✅
4. **情境 9 離開 / 加回**：見上表 F-M2，失敗時 04 留在「已認領、未加入」（node.go:1279-1282：`State = Claimed`、`Left = true`），可再管理。✅
5. **藍牙關開、切背景**：只動手機。✅

結論：照 v4 做，最壞情況是「04 暫時不在網路裡」或「app 暫時打不開紀錄、要 rollback APK」，兩者都可回復。沒有 BLOCKER / MAJOR。

---

## MINOR

**m-1 §5 / §10：安裝 PR APK 之後、做任何會改 04 的步驟之前，沒有「app 仍能打開 04 的紀錄」這道關卡；`install -r` 失敗時的處理也沒寫。**
- 情境：T1 接線寫錯（例如 `level(role)` 讀到別的 role，或 open 改走 `keyCall` 後錯誤碼不對），S20 上所有 open 失敗。接著照表走情境 9「離開」——登入需要開 04 的紀錄，會在前面就失敗，不會半途；但在這個狀態下做其他步驟沒有意義，還會讓 `ui/state-v1` 被覆寫（ui_state.dart:227-231）。
- 另外：如果 PR APK 與手機上現有 APK 的簽章不同（例如在 WSL 與 Windows 用不同 debug keystore 建），`install -r` 會回 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`；這時唯一「讓它裝上」的做法是解除安裝，等於重演 02（Keystore 金鑰隨 UID 消失）。
- 修法（§5 文字）：
  1. 安裝前比對簽章：`apksigner verify --print-certs <apk>` 的 SHA-256 與 `adb -s RFCN30HMRAR shell dumpsys package <dev 套件名> | grep -A1 signatures`（或已裝 APK 的 `pm path` 拉回後同法）一致才裝；main 還原用的 APK 也一樣。
  2. `install -r` 失敗 → 停，回報；**絕不解除安裝、不清資料**。
  3. 安裝後第一步（唯讀）：首頁看到 04 的暱稱「04」、節點頁讀得到狀態、logcat 沒有 `open` 的 `keyLevel` / `keystore` 錯誤；不符 → 立刻 `install -r` main APK，停場次。T1 的 open 耗時就在這一步一起量。

**m-2 §10 F-M2 的唯讀指令沒查證，而且其中一條可能把 mesh 金鑰印進紀錄。**
- `uci -q get wireless.*mesh_id`：uci 的 get 不接受萬用字元，會回空。mesh 介面的 section 名稱是執行時找的（provhelper main.go:214-220：`meshIface()` → `wireless.<i>.mesh_id`）。空值若被當成「沒變」就是 UNKNOWN 算 PASS；若被當成「不符」就是誤停。
- 最自然的替代是 `uci show wireless`，但它會印出 `wireless.<i>.key`（同一處 main.go:220 讀的 mesh 金鑰）。真機紀錄 `pr7-device-*.md` 會進公開 repo。
- `batctl n | wc -l`：04 目前沒有鄰居（02 不能用），這個數字只是紀錄、不是判斷依據，要寫明。
- 修法：寫死指令，例如 `uci show wireless | grep '\.mesh_id='`（只取這一行）、`uci -q get wireless.radio1.country`（status.go:36 正是讀這個 key，✅）；空值 = 停並回報；禁止 `uci show wireless` 不加過濾。開場前先在 04 唯讀試一次，把輸出格式貼進計畫。

**m-3 §10 F-M2：每次重開後只看 SSH，沒看 BLE / app 端也回來了，就進下一個中斷。**
- 情境：SSH 回來了但 provd 的 BLE 沒有起來（或 RPA 換了、app 30 s 記憶視窗內讀不到）。接著做下一個中斷（例如情境 9 的離開），結果被歸因成新功能的問題。
- 修法：每次重開後的還原驗證加一條：app 在 N 分鐘內（PR 6 實測 82 s）於首頁 / 節點頁重新讀到 04；讀不到 → 停，不做下一個中斷。

**m-4 v4 本文與 §10 互相矛盾的地方還留在本文，開場問同意時容易拿到舊表。**
- §1 表 194 仍寫「本 PR 真機場次一起問」；§5 表仍有 btsnoop 列與「SSH 重開 04 → 自己回來」列；§5 / §8 仍寫「本 PR 沒有 instrumented 測試」，而 §10 T1 加了模擬器 `KeyHandlersDeviceTest`；§1 表 105 仍是「做」。
- 「衝突以 §10 為準」對審查者夠用，但問使用者同意時要給的是一張完整、正確的副作用表。
- 修法：凍結前把 §10 併回本文（§1 的 105 / 194、§5 整張表、§8 全套清單加上模擬器測試），§10 只留變更紀錄。

**m-5 §10 T1 的模擬器裝置測試：只寫了「用 `am instrument -w`」，沒寫怎麼建、怎麼裝。**
- `am instrument` 前要先裝 app APK 與 androidTest APK。若用 gradle 的 `install*AndroidTest` / `installDevDebug` 且 S20 也接在 adb 上，gradle 會裝到所有已連線裝置，S20 上的 app 會被換成測試建置（記憶 `feedback_never_flutter_install_phone`：04 的金鑰就是這樣毀的；那次是 connectedAndroidTest，但 install 任務也會碰所有裝置）。
- 另外，`KeyHandlersDeviceTest` 的 open 案例預期 `Err("keyLevel","RECORD_AES",0)`：前提是模擬器上已有 RECORD_AES（SOFTWARE）；沒有這把時會是 `null`。要在測試裡先產生，或兩種都寫明。
- 修法：寫死流程：`gradlew assemble<Flavor>DebugAndroidTest` 只建不裝 → `adb -s emulator-5554 install -r` 兩個 APK → `adb -s emulator-5554 shell am instrument -w …`；禁止任何 gradle install / connected 任務；全程 `ANDROID_SERIAL=emulator-5554`。

**m-6 T1 的 Dart 測試仍標成負向對照（E m-6 / F m-6 未在 §10 處理）。**
- prober 在 `openRecord` 出錯時已呼叫 `keyCheck`（prober.dart:206-211），`keyLevel` 的判斷不分是哪個方法。所以「假通道回 open 的 keyLevel → 2.4」在 main 上就會過；§2 寫的「拿掉 refusedBy 的 open → FAIL」找不到對應程式碼。
- 修法：§2 的 T1 測試欄改成：負向對照 = Kotlin `KeyHandlersTest` + lint（拿掉 open 的政策檢查 → FAIL）；Dart 那條是回歸保護，或改成 F 建議的「拿掉 prober.dart:209-210 的 `keyCheck` → FAIL」。

**m-7 §10 T14 的 Dart 測試寫「main 上會 FAIL」，但依 §10 的字句放法，它在 main 上會過。**
- §10 說錯誤句雙語（主句中文 + 技術段），即 Rust 的 `中文\u{1E}english\u{1F}` 格式（simple.rs:40、:55 同款）。字句在 Rust 端，Dart 測試的假 `storeHasRecords` 丟的就是測試自己給的字串；在 main 上，同樣的假物件丟錯 → `_run` 的 catch（main.dart:148-157）→ 顯示同一字串、不進首頁、不呼叫 firstRun。整條測試在 main 上 PASS。
- 修法：寫明 T14 的負向對照只在 Rust（改回 `unwrap_or(false)` → ENOTDIR / 單項錯誤兩條 FAIL；字句內容也由 Rust 測試斷言）；Dart 測試標成回歸保護。若想要 Dart 端的負向對照，就要把「不要清除資料或重裝」這行放在 Dart 的專用分支，負向對照 = 拿掉分支 → FAIL。

**m-8 T2：§10 說白箱測試「不靠 lint」，但白箱測試只測 helper，碰不到 MainActivity 的接線。**
- 若 open 改走 `keyCall(result, wipe = true)`（T1 讓 open 經 KeyHandlers 後最自然的寫法；`keyCall` 本身在 `result.success` 後清零，MainActivity.kt:83），清零就在 MainActivity（非 JVM 可測）。另抽 `openAndWipe` 的 JVM 測試在 MainActivity 沒呼叫它時仍然 PASS。
- 修法：兩條都要：(a) 把 `keyCall` 的回覆處理抽成純函式（`deliver(answer, wipe, success, error)`），JVM 測試斷言回覆後 ByteArray 全 0（拿掉 fill → FAIL）；(b) `MainActivityKeyUseLintTest` 對 `"open"` 要求 `wipe = true`（現在的正則 `(, wipe = true)?` 是可有可無，MainActivityKeyUseLintTest.kt:27；拿掉 → FAIL）。

**m-9 §4 真機截圖：存放位置沒寫。**
- `screencap` 會把狀態列（通知圖示、時間、有時是通知預覽）一起截進去；`uiautomator dump` 會含畫面上所有文字。若截圖或 dump 進了 repo（`p1p2-check.md` 的附件），就把手機的通知資訊公開了。
- 修法：截圖與 dump 只放 scratchpad；進 repo 的只有算出來的對比數字與元素名稱；需要附圖時裁掉狀態列。

---

## 已查證、沒有問題的部分

- **T1 只查 RECORD_AES**：與 `appUsable`（KeyPolicy.kt:79-83）同一條規則，S20 已滿足；錯誤以 `keyLevel` 回傳時 Dart 的 X26 路徑接得到（KeyHandlers.kt:72-79）。open 的六個呼叫點（claim_records.dart:37、app_link.dart:35 / 115 / 183 / 204、ui_state.dart:228）與 §10 所列一致（§10 寫成「Kotlin open 的六個呼叫點」，其實是 Dart 端的呼叫點，用字小誤，不另列）。
- **T14 的範圍**：`store_sweep` 先擋 kind 目錄 EACCES（store.rs:211-216）；剩下 ENOTDIR 與單項錯誤兩種，§10 已改正並各有 Rust 測試。`storeHasRecords` 的 Dart 簽名不變（`Future<bool>`），device_check 沒有用到它。
- **T19**：舊啟動頁按鈕只在 `_app == null` 時出現（main.dart:162-171 只在成功時指派；按鈕在 :323-337 的失敗畫面），所以 `_open` 的 `a != null` 分支（main.dart:97-99）走不到；`openRawPage` 另有 home_page.dart:60 與 claim_flow_test 使用，T12 不受影響。
- **§1 128 子項證據**：home_page.dart:203-206（看申請、加入隊伍開新頁）、node_page.dart:192（手機 Wi-Fi）✅。
- **還原 APK 的版號**：pubspec `1.0.0+1`，兩個建置 versionCode 相同，`install -r` 可降回 main（簽章相同的前提見 m-1）。
- **安全（逐 actor）**：本機無特權 app 碰不到別的 UID 的 filesDir / Keystore；被入侵的節點不經過 T1 / T14 / T2；遠端攻擊者沒有新入口（T9 / T10 只顯示既有資料）；我們自己的錯誤是主要對象——T14 fail-closed、T1 fail-closed、真機場次可回復（見上），剩下的防線見 m-1、m-5。沒有新的攻擊面。

## 結論

**APPROVE-WITH-CHANGES**（BLOCKER 0 / MAJOR 0 / MINOR 9）。前幾輪全部 BLOCKER / MAJOR（含 F-M1、F-M2）都已解決。m-1、m-2、m-5 是真機場次與模擬器測試的操作細節，請在開場問同意之前寫進 §5（併回本文，m-4）；m-6 – m-8 是測試欄的負向對照寫法，實作時改；m-3、m-9 是場次紀錄的細節。不需要整份再審一輪；§5 改完由一位審查者確認差異即可。
