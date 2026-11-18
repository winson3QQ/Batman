# #329 PR 7 計畫 v2 — 獨立對抗式審查 D（第二輪）

審查對象：`docs/design/329-pr7-plan.md` v2（worktree `C:/src/Batman-329pr7`，b4259a7 = main 3020374 + 計畫）。基準（設計 v12.1、PR 1–6）不重審，只審新範圍。所有行號都在本 worktree 上查證過。

統計：**BLOCKER 0 / MAJOR 3 / MINOR 11**。結論：**REJECT（v2）**——三個 MAJOR 都是局部修正，改完整份再審一次即可。

## 第一輪 MAJOR 的處理狀況

| 第一輪 | 狀態 |
|---|---|
| A-B1 / B-B1（T14 沿用半套金鑰） | 方向改對了（補齊、不刪既有），但新路徑留下永久卡死與沒有測試的回滾 → 本輪 M-2 |
| A-M1 / B-M3（T14 測不了、金鑰變更缺契約） | 部分解決：`firstRunPlan` 只涵蓋「要產生 / 要驗」的決定，A-M1 要求的「產生到一半丟例外 → 只刪這次產生的」沒有測試 → M-2 |
| A-M2 / A-M3 / B-M2（T13） | 改成不修（N1），可以接受；打勾的寫法見 m-8 |
| A-M4 / B-M5（T6） | 已解決（node_page.dart:85-128 的 `node-join` 列確實涵蓋 join / member；whyNext 改字） |
| B-M1（漏項） | **沒有解決**：§8 寫「§1、§3 補 :90、:178」，但 §1 / §3 都沒有這兩行；另外還有 15 行完全沒提到 → M-1 |
| B-M4（字級藏在算式） | 已解決（運算式掃描 + 渲染字級 + 2.0 倍重跑） |

---

## MAJOR

### M-1 盤點仍然不完整，§8 的「已補」說法不實；其中 :91 有一部分可以遠端做

- **情境**：使用者看 §8 會以為 49 行都分類過了，實際上有 17 行沒有出現在 §1–§5 任何一處。依規則「範圍從規格逐列推」，這正是第一輪 B-M1 的問題，而且這次 §8 還寫了已補，是誇大。
- **證據**：對計畫逐行 grep 未勾行號（i329d.md 的 `- [ ]` 共 49 行）。在 §1–§5 找不到的：:86、:89、:90、:91、:178、:181、:182、:183、:184、:185、:188、:189、:194、:201、:216、:217、:218。:90 與 :178 只出現在 §8:88 的對應表裡（「§1、§3 補 :90 … :178」），§1 / §3 本身沒有。plan 中 `183`、`90`、`91` 的命中都是 `claim.dart:183-190`、`main.dart:91-95` 這類行號，不是 issue 行。
- **漏掉的是否有可遠端做的**：
  - **:91 中斷測試**（藍牙斷線、節點重開、app 切背景）：情境 5、8（暱稱 / 國家）、9 在 04 上能做（PR 6 #350 已做這些情境的正向）。切背景用 `adb shell input keyevent HOME` / `am start` 回來，不改任何設定；關藍牙與 T6 是同一個 `cmd bluetooth_manager` 動作（已列要同意）；04 重開是節點動作（SSH，要同意）。這一部分可以和 §5 的真機場次一起做，不需要使用者在場。情境 1 / 2 / 3 / 6 要 02 重燒才行。
  - **:89 S20 走過全部主要流程**：#349 / #350 已走過大部分；剩下的都卡 02 重燒或手機 Wi-Fi 密碼。要寫清楚剩下哪些、為什麼。
  - **:194 btsnoop**：見 m-9（⚠️ 可能可以用 adb 開，未查證）。
  - 其餘（:86、:90 後半、:178、:181–:185、:188、:189、:201、:216–:218）確實要使用者在場、02 重燒或額外硬體，但要逐行寫進表。
- **修正**：加一張 49 行的對照表（行號 → §1 / T# / N# / 留著 + 原因），列數加總 = 49。:91 的 04 可做部分（切背景、關藍牙、04 重開各一次，對情境 5 / 8 / 9）放進 §5 真機場次，副作用與還原照 §5 格式列出，開場前一起取得同意；做不到的情境逐條寫原因。

### M-2 T14：已存在、但不合格的金鑰會讓 app 永久卡在「重試」，畫面文字是錯的；「只刪這次產生的」沒有測試

- **情境 A（永久卡死）**：第一次啟動時，`Keys.generate` 在 StrongBox 產生後讀回不合格的等級（Keys.kt:64-66：讀回 SOFTWARE 就 `delete` 再試 TEE），或在 `rank` 比較後的 `delete → make`（Keys.kt:68-69）中間，行程被系統結束（拔電、滑掉、OOM）。這時留下一把等級比該手機做得到的還差的金鑰。facts §9（254-app-s1-facts.md:128-131）說明 KM4 手機上 StrongBox ECDH 會靜默變成 SOFTWARE，所以「StrongBox 那一把是 SOFTWARE、TEE 那一把是硬體」在 KeyMint 手機上是真的會發生的組合。下次啟動，T14 看到「既有金鑰等級不符政策 → 回錯誤、不寫 marker」。`_install` 照現有程式顯示 `_firstRunFailed`（main.dart:229-232）→ 畫面寫「金鑰沒有建立成功」，並給一顆**重試**（main.dart:129 `retry = … || _firstRunFailed`）。但重試永遠過不了，因為 T14 從不刪既有金鑰。今天的程式在這條路上會全部重產，下一次就好了。T14 把一個能自己恢復的狀況變成永久停用，而唯一的出路（清除 App 資料）計畫裡沒有寫、沒有證據、畫面也沒說。
- **情境 B（dev 版靜默降級）**：同上，但留下的是 OWNER_ENC 的 SOFTWARE。dev 版政策允許 SOFTWARE owner_enc（KeyPolicy.kt `allowed`），T14 就保留它並寫 marker。這支手機明明做得到 TEE，卻永久用軟體 owner_enc，只剩一行「只有軟體保護」的注意。
- **情境 C（文字不實）**：main.dart:231 `第一次啟動失敗（金鑰已全部刪除，下次開 App 會重試）`。T14 之後這句話不再正確（既有的不刪），但計畫寫「`_install` 不改」。
- **測試缺口**：計畫的 JVM 測試只測 `firstRunPlan(existing)` 回傳（要產生的、要驗的）；真正的安全性質「失敗時只刪這次產生的、絕不刪既有」在純函式之外，沒有 JVM 測試。模擬器上的 instrumented 測試因為等級 0 被政策拒絕，只會走「既有金鑰不符 → 回錯誤」，不會走「補齊 → 產生到一半失敗 → 回滾」。第一輪 A-M1 要求的注入式測試（generate / selfTest / delete 由 fake 注入、產生到一半丟例外）沒有做。
- **更小的替代做法（建議評估）**：T14 想防的實際風險只有一種：「marker 不見、`records/` 讀不到 → 被當成沒有紀錄」（simple.rs:44-48，`read_dir(...).unwrap_or(false)`，而且 entry 錯誤也被 `is_ok_and` 吞掉）。把 `store_has_records` 改成三態（目錄不存在 = false；其他 IO 錯誤 = Err → `_install` 丟例外 → 現有的「啟動檢查失敗 + 重試」路徑，main.dart:153-164），就不必改 Kotlin、不動已審的 §4.1「全有或全無」，也沒有情境 A / B。`net_index.dart` 的 `listKind`（lib/src/flows/net_index.dart:135-147）已經是這個規則（PathNotFound = 空，其他錯誤丟出），可以照著做。若仍採用「補齊」，至少要：
  1. 既有金鑰「不合格」時，分清楚兩種情況：(a) 有可能是本 app 中斷留下的（沒有 marker、`store_has_records` 是可靠的 false）→ 刪掉重產；(b) 紀錄讀不到 → 拒絕。這又回到三態判斷，所以三態是必要的。
  2. 回滾邏輯放進可注入的純 Kotlin 類別（同 `KeyUses` 作法），JVM 測：產生第三把時丟例外 → 只刪第三把（以及這次產生的前兩把），既有的那把還在；負向對照：改回 `KeyRole.values().forEach { delete }`（Keys.kt:188）→ FAIL。
  3. 改 main.dart:231 的字；永久拒絕時的畫面要說出路（附「清除資料會清 Keystore」的證據，否則寫「重新安裝」）。
- **附帶的不一致**：§2 T14 寫「S20 的 `pm` 實測：tu2 套件的金鑰在重裝後不存在」，§5 又寫「規則禁止解除安裝 → 改用 AOSP 原始碼證據，真機不做」。兩處要一致（以 §5 為準，§2 刪掉 S20 實測的說法）。

### M-3 T20 照寫的做會讓 ScanPage 在掃描中點不了節點

- **情境**：維修人員在設定頁（settings_page.dart:110）開「附近的節點」，按搜尋，清單出來後點一台要讀狀態。
- **證據**：ScanPage 的 `_busy` 就是 `rawBusy`（scan.dart:41-42）；`_read` 第一行 `if (_busy) return;`（scan.dart:81-82），然後才 `_stop()` 停掃描（scan.dart:91）。計畫 T20 寫「掃描期間 `rawBusy`」。照字面做 → 掃描中 `_busy == true` → 點任何一台都直接 return，ScanPage 的主要功能壞掉。計畫列的測試只看 dispose，不會抓到。
- **修正**：掃描用另一個旗標持有租約（例如 mixin 加 `rawHoldScan()` / `rawReleaseScan()`，或在 `_start` 直接 `lease.hold()` 另存一個 Cancel），`_read` 的防重入仍只看讀取中的 `_busy`；dispose 時 `_scan?.cancel().whenComplete(release)`。加 widget 測試：掃描中點一台 → 有發出 connect；負向對照：把掃描旗標接回 `rawBusy` → FAIL。

---

## MINOR

- **m-1 T3 原始碼鎖的例外清單不對**：直接呼叫 store 寫入的不只 `claim_records.dart`：還有 `ui/ui_state.dart:240,244`（ui/state-v1 顯示記憶，`storeWriteCas` / `storeRemove`）、`main.dart:213,228`（sweep、marker）、`src/nodelink/app_link.dart:165-168`（RecordWriter 的接線本身）。照計畫寫的規則，測試在 main 上就會 FAIL。例外清單要逐檔列出並寫理由（例如只鎖 `node/`、`net/`、`mnet/`、`mpend/` 這幾類紀錄的寫入）。
- **m-2 T1 讓「打不開」的原因變多，而有些呼叫端把「打不開」當成「沒有」再覆寫**：`levels()` 讀四把（Keys.kt:43），任何一把暫時讀不到 → open 失敗。`RecordUiStore.read`（ui_state.dart:223-231）把失敗當沒有、用 CAS 覆寫；console `readRecord` 吞掉所有 `PlatformException` 回 null（app_link.dart:199-207），`joinreq` 把 null 的 `mpend` 交給 Rust，而 Rust 明寫「None = 打不開：覆寫」（owner.rs:1294-1298），也就是隊員還在等的申請會被新的蓋掉。今天只有 RECORD_AES 本身出錯才會這樣；T1 之後另外三把的暫時錯誤也會。修正：`readRecord` / `RecordUiStore` 只在「真的解不開」（例如 `AEADBadTagException`）時回 null，`keystore` / `keyLevel` 錯誤往上丟；或至少在計畫裡列出這三個呼叫端並寫明可以接受的理由。另外加一條 Dart 端測試：prober 的 `openRecord` 丟 `keyLevel` → `keyErrorToRadio`（app_link.dart:247-249）→ 節點顯示金鑰原因（#329:105 要的是「會顯示 2.4」，目前只測到 Kotlin 那一半）。
- **m-3 T2 的 lint 是存在檢查**：「原始碼裡有 `fill(0)`」不是規則認可的測試。可以做成白箱：open 走 `keyCall(result, wipe = true)`，JVM 測 `KeyHandlers` / 一個小的 answer helper，抓住交給 fake `result.success` 的那個陣列，在回呼後斷言全為 0；負向對照拿掉 wipe → FAIL。
- **m-4 T8 (a)**：`roundsRun < 3` 只有三處（home_page.dart:280、net_pages.dart:540、node_page.dart:168），不是四處。`roundsEnded` 定義成「目標包含全部節點」：節點頁的輪只讀那一台（core.dart:349 `_pageTargets`），使用者一開 app 就進節點頁並停留，`firstRounds` 會一直是 true，回首頁時第 5 列「正在找你的節點…」（home_logic.dart:87）會比今天停留更久。要寫明這是預期，或改成「每台都有過一次結論」。
- **m-5 T9 沒有處理第一輪 B-m12**：「網路：」只在讀取新鮮時顯示；k1=1 時 `membership_line` 會說「已認領，還沒加入網路」，和 StatusHero 重複，要排除。§8 的 MINOR 對應沒有列這一條。
- **m-6 T14 的周邊註解（第一輪 B-m11）沒有列**：t_u2_guard.dart、t_u2_main.dart 寫「firstRun 會重產四把」；KeyHandlers.kt:9-10、MainActivity.kt:72-73 的「Not gated: `open`」在 T1 之後是錯的。
- **m-7 T17 的 `bluetoothctl` 要先確認由哪台機器跑**：這台 Windows 電腦的 WSL 碰不到藍牙；02 沒有 lab key、SSH 不能用（i329d.md:201）。要指定一台有 BlueZ、在 04 藍牙範圍內、我們進得去的主機，先唯讀確認（`bluetoothctl list`），否則這一半仍然要使用者在場，要寫 ⚠️。
- **m-8 N1 打勾的寫法**：20 s 等待是程式碼已查證、仍然存在的行為。打勾時文字要寫「不修（理由…），行為仍在」，不能看起來像已解決；或者留著不勾、改成「已接受」。
- **m-9 :194 btsnoop 可能不必等使用者**：Android 13 可以試 `adb shell setprop persist.bluetooth.btsnooplogmode full` 再關開藍牙，然後 `adb bugreport` 拿 btsnoop。⚠️ 未查證 shell 有沒有權限設這個屬性（先 `getprop` 唯讀確認）。這是改手機開發者設定，要先取得同意，但不需要人在現場。若可行，可以和 §5 的藍牙關開放在同一場。
- **m-10 instrumented 測試的執行方式要寫死**：§7 只寫 `adb -s emulator-5554`。照 KeyHandlersDeviceTest.kt:25 的作法：`assembleAndroidTest` → `adb -s emulator-5554 install -r` 兩個 APK → `adb -s emulator-5554 shell am instrument …`；**絕不跑 gradle `connectedAndroidTest`**，因為它會在接著的 S20 上安裝再解除安裝，04 的擁有者金鑰會跟 02 一樣毀掉。測試用 `Keys("bmtest")` 前綴。
- **m-11 T16 範圍**：只改 Dart 的 `X` 範本；Rust 給的句子裡也有名字（例如第 7 列「節點 X：」，設計 :674）。要寫明 Rust 句子是否也改，或列為不改。

---

## 從實際使用出發查過、沒有問題的部分

- 隊長在 S20（已有 marker）裝本 PR：`_install` 讀到 marker 直接返回（main.dart:215-218），T14 不會被呼叫；T1 open 經 SEAL 同等的政策，S20 的 RECORD_AES 是硬體，不受影響。
- T19：main.dart:97-99 只在 `_app != null` 時才會執行，而那時 build 顯示的是啟動畫面（main.dart:247 `_ok && _app != null`），按鈕不在畫面上，確實是死碼。NodeLink 啟動失敗時 `_app == null`，走 :91-95，不受影響。
- T6：`node-join` 只在 `nodeState == 1` 且手機有 net 紀錄（node_page.dart:87）或有 mnet 入口時出現，不會出現「建立網路」（D8）；藍牙 / 權限按鈕不拿租約。
- §1 的證據：claim.dart:408 在 `requestMtu`（:409）之前指派 `conn`；claim.dart:499-503 finally 先 cancel 再 `rawIdle`；home_logic.dart:93 `NetRecords.unknown → joinNetwork`；simple.rs:47 `unwrap_or(false)`。都對。
- 安全（逐 actor）：T1 是 fail-closed；T10 的位址只進摺疊的技術資訊（節點用隨機位址，#329:221）；T14 的 Keystore 不跨 UID。除了 M-2 的降級情境，沒有找到新的攻擊面。

## 結論

**REJECT（v2）**：M-1（盤點與 §8 的說法）、M-2（T14 永久卡死 / 降級 / 回滾沒測；建議改用三態 `store_has_records`，比較小）、M-3（T20 會讓 ScanPage 點不了）。改完後整份重新送審。
