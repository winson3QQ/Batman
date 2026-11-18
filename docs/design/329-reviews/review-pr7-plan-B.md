# #329 PR 7 計畫 v1 — 獨立對抗式審查 B

審查對象：`docs/design/329-pr7-plan.md`（753681c，main 3020374 + 計畫）。基準（設計 v12.1、PR 1–6）不重審，只看新範圍。審查從現場用法出發：隊長拿 S20 上的 dev app、HaLow 節點 04（在 dev 的網路第 5 版、wsl.26）、02 等重燒。所有證據都在 worktree `C:/src/Batman-329pr7` 唯讀查證；reactive_ble 證據取自 pub cache `flutter_reactive_ble-5.6.0`。

統計：**BLOCKER 1 / MAJOR 5 / MINOR 12**。結論：**REJECT（v1）**。計畫大部分方向正確，修正點都很局部；但 B-1 是第一次安裝這條路徑上的新退化，而且計畫的理由寫反了，要改完整份重審。

---

## BLOCKER

### B-1 T14：已有部分金鑰時「沿用 + 寫 marker」會讓 app 永久停用（第一次安裝 / 當機路徑上的退化）

- **情境**：第一次開 app。`Keys.firstRun()` 依序產生四把金鑰，每把都先試 StrongBox 再自我測試（Keys.kt:180-191、:68-79），在 S20 上要好幾秒。這段時間使用者把 app 滑掉、手機沒電，或行程被系統結束，結果只產生了 RECORD_AES、OWNER_SIGN 兩把；也可能四把都產生了，但最後一把還沒做 selfTest。此時 marker 還沒寫，也沒有任何紀錄。
  - **現在**：下次開 app，`_install` 看到沒有 marker、沒有紀錄（main.dart:215-225），就呼叫 `firstRun`，`generate()` 先 `delete(role)` 再重新產生（Keys.kt:68），可以自己恢復。
  - **T14 之後**：`firstRun` 回 `keysExist`，`_install`「沿用現有金鑰、寫 marker」。marker 一旦存在，`_install` 就不會再進產生金鑰的分支（main.dart:216-219）。接著 `KeyAbilities.read` 看到少了金鑰：缺 RECORD_AES 時整個 app 停用（`aesGone`，key_abilities.dart:75）；缺 OWNER_SIGN 時是「擁有者金鑰不見了…節點需要重燒卡回收」（:77）。唯一的出路是清除資料或重裝。這是在第一次安裝路徑上新增的永久失敗狀態。
- **計畫的理由也不對**：計畫寫「金鑰沒有被用來封任何紀錄，沿用不會丟資料」，但「沒有紀錄」是由 `store_has_records` 判斷的，而它在 `read_dir` 失敗時回 `false`（rust/bridge/src/api/simple.rs:47，`unwrap_or(false)`）。所以「沒有 marker、看起來沒有紀錄、金鑰還在」可能代表兩件事：(a) 第一次執行做到一半當掉；(b) 紀錄其實在，只是讀不到。拒絕重產對 (b) 是對的，這也是 T14 真正的價值；但對 (a)，原樣沿用就是 B-1。
- **修正**：
  1. Kotlin 把「已有金鑰時怎麼辦」寫成一個純函式（輸入四把的 level，可能是 null），讓 JVM 測得到。
  2. 新增一個通道方法，例如 `adoptOrComplete`：**只產生缺的那幾把，絕不刪除或覆蓋已經存在的金鑰**；對每一把（含既有的）跑 selfTest；失敗時只刪除這次呼叫新產生的金鑰；回傳四把讀回的 level。`_install` 收到 `keysExist` 後改呼叫它，成功才寫 marker。
  3. 既有金鑰的 selfTest 失敗時：不刪除、不寫 marker，顯示「金鑰檢查失敗」並提供重試（fail-closed，金鑰保持原樣）。
  4. 一併修正：`firstRun` 一開頭的存在檢查如果丟例外（`level()` 會因 Keystore 錯誤丟例外，Keys.kt:36-41），`_install` 現在會顯示「金鑰已全部刪除」（main.dart:232），但其實什麼都沒刪。`keysExist` 和這種檢查錯誤要各有自己的錯誤碼和句子。
- **負向對照**：(i) JVM：給純函式「兩把存在」，斷言只產生缺的兩把；把它改回「沿用、不補」→ FAIL。(ii) emulator 儀器測試（`bmtest` 前綴，照 KeyHandlersDeviceTest 的方式，只用 `adb -s emulator-5554`）：先只產生兩把再呼叫，斷言四把都在、原本兩把的公鑰沒變；負向對照改回 T14 v1 → 缺兩把 → FAIL。(iii) 「四把都在、sealed 紀錄在、`records/` 讀不到」→ 斷言不刪、不重產；負向對照改回今天的 `firstRun` → 公鑰改變 → FAIL。

---

## MAJOR

### M-1 §5 漏列了 6 個未勾項目（計畫說「全部 49 個逐條盤點」）

- **證據**：i329d.md 未勾的行有 49 行。計畫 §1、§2、§3、§5 合起來沒有提到以下 6 行：
  - **:90**：設計逐條寫出使用情境 1–10，並由一般隊員實測；
  - **:117**：合併條件改寫，R-3、R-4、A22、A11、R-6、A13 要在任何發布之前做完；
  - **:118**：A13 現場補測；
  - **:148**：02 的 B 槽重寫；
  - **:177**：04 回 N0 的路徑與 02 B 槽；
  - **:178**：R-7 大部分情境。

  其中 :117 是發布閘門，漏掉它，交接時就會寫成「全部收完」，正是 feedback「PR 縮範圍必進原單 checklist」記過的那類漏項。
- **修正**：§5 逐行列出這 6 行和原因：:90、:117、:118、:178 要使用者在場或等 02 重燒；:148、:177 跟 :147 一起，依使用者「先不回 N0」的決定。§1 或 §5 的列數加總要等於 49，並寫出對照表。

### M-2 T13（prober 聽 `link.state`）：結果並不一定「不變」，規格少了三條契約；真機驗證幾乎打不到那個時間窗

- **20 s 推論已查證（給計畫當證據）**：
  - reactive_ble 的 `subscribe()` 在斷線時會**結束**特徵值串流（flutter_reactive_ble-5.6.0 reactive_ble.dart:534-558、connected_device_operation.dart:99 `isDisconnected → repeater.dispose()`）；
  - prober 只接 `inbox.add` / `onError`，沒有 `onDone`（prober.dart:262）；
  - msg2 之後只剩 `answer` 計時器（prober.dart:255-258）。

  所以確實會白等到 20 s。另外要注意：`isDisconnected` 是用**位址**比對 `connectedDeviceStream`，上一條連線晚到的 DISCONNECTED 也會結束新連線的 tx 串流。所以用 `link.state`（connect 串流，已有 `takeWhile`，329-ble-settle.md §5）是對的選擇，**不要**改用 tx 的 `onDone`。這點要寫進計畫。
- **缺的契約**：
  1. **讀到狀態之後、hint／全隊區段的 2 s 之內斷線**（prober.dart:212-224 在 `done(o)` 之前 await `_afterRead`）：`failed()` 會是 `Res.broken`，把已經讀到的好結果蓋掉，違反 PR 5 R7 K-m2「hint 的等待不能把好的讀取變成壞的」的基準。斷線時必須 `done(read ?? failed())`，和取消路徑（prober.dart:139）一樣。
  2. **交接路徑**：HandoffProber 在 `loggedIn` 就 `done`，接著在清理之前提早 return（prober.dart:278）。新加的 `state` 訂閱必須在這條路徑也取消，否則會留在已經交給流程的連結上。
  3. **只認 `false` 事件**：`GateLink.close()` 在 finally 會 `_state.close()`（ble_gate.dart:129），abort 或租約收回時會觸發 `onDone`。`onDone` 不能當成斷線，否則取消路徑的結果會變。另外，`NodeLink._run` 的 `state.first` 和 probe 訂閱之間有空隙，事件可能掉在那裡；`GateLink` 已經有 `_down`（ble_gate.dart:67），應公開成唯讀的 `down`，probe 一開始就先檢查。
- **真機驗證打不到時間窗**：msg2 到狀態回答通常不到 1–2 s，而 04 的節點頁每 60 s 才讀一次。用 SSH 隨機重開 04，幾乎不會剛好落在這個窗口，結果大多只是「沒有嘗試在進行」或「msg2 之前斷線」（那條已經有 8 s 預算）。這樣既用掉一次重開節點的同意，又拿不到證據；如果寫成 ✅ 就是誇大。
- **修正**：
  - 寫出上面三條契約，各附單元測試（假 backend）：(a) msg2 後送 `false` → <100 ms 結束、結果 = `failed()`；負向對照拿掉監聽 → 20 s FAIL。(b) 讀到狀態後、hint 等待中送 `false` → 結果仍是 body；負向對照改成 `done(failed())` → FAIL。(c) 交接後送 `false` → 不影響流程，訂閱數回到 0。(d) `close()`／取消 → 結果和今天相同。
  - 真機部分改標 ⚠️，或改成可以命中窗口的做法（例如手動按重新整理後立刻 `reboot`，重複 N 次、記錄命中次數；命中 0 次 → ❓，不算通過）。

### M-3 T1／T2／T14 是金鑰變更，但計畫沒有擁有權、契約、生命週期、安全這幾段；而且列的測試在 JVM 上跑不起來

- **證據**：
  - 使用者規則要求每份設計都要有 1–5 段。計畫 §2 每項只有一句理由。
  - `Keys` 在建構式就呼叫 `KeyStore.getInstance("AndroidKeyStore")`（Keys.kt:25），JVM 跑不了，KeysWiringLintTest.kt:7-10 自己也這樣寫。所以 §6「Kotlin 單元測試（kotlin-unit-tests.sh，T1／T2／T14）」對 T14 和 T2 做不到；T2 的清零在 `MainActivity.keyCall` 裡（MainActivity.kt:83），只能用原始碼 lint 鎖住。
- **修正**：補一段（可以很短）：
  - **契約**：`open` 新增 `keyLevel` 錯誤碼。列出 7 個呼叫點遇到錯誤時的行為並附證據，確認沒有一處把「打不開」當成「紀錄壞了 → 刪除或 keepCopy」：
    - claim_records.dart:37／:72（丟例外，不寫）；
    - claim_recovery.dart:282-285（不恢復）；
    - app_link.dart:35、:115、:183、:204；
    - ui_state.dart:228（當作沒有）。
  - **生命週期**：
    - 第一次安裝、第一次執行做到一半當掉 → B-1；
    - 升級：已有 marker → 不受影響；
    - 降級回 PR 6：marker 照讀；
    - 清除資料：Keystore 是否一起清 ⚠️ 未查證，查不到就照 B-1 的路徑處理。
  - **安全（逐個 actor）**：
    - 遠端攻擊者、被攻破的節點：沒有新的攻擊面；
    - 本機無權限的 app：通道在本行程內，Keystore 依 UID 隔離，沒有新的攻擊面；
    - 實體取得手機：T2 只清 Kotlin 自己那份副本。codec 編碼緩衝區、`Cipher` 內部、Dart 堆積裡都還有明文，不能寫成「已清零」；
    - 自己的失誤：T14。另外，`Keys.generate`／`delete` 仍然是 public，所以「防止任何呼叫者毀掉金鑰」要改成「平台通道的呼叫者」。

  **測試**：T14 照 B-1 的修正（純函式 JVM 測試 + emulator 儀器測試）；T2 是 lint（`"open" -> keyCall(result, wipe = true)`），標明是 lint；T1 用 KeyHandlersTest（假 KeyUses：RECORD_AES 是 null → `keyLevel`；負向對照：直接呼叫、不經 `use()` → FAIL），再加上 MainActivityKeyUseLintTest 的清單加入 `"open"`。

### M-4 T8 字級：不在六級裡的大小藏在算式裡，「照設計」會讓每一頁的狀態句變大

- **證據**：`grep -oE "fontSize: *[^,)]+"` 找到這些：

  | 位置 | 現在的值 |
  |---|---|
  | widgets.dart:120 StatusHero 的句子 `Fs.hero - 3` | 21（設計 24） |
  | widgets.dart:67 `Fs.title + 1` | 19 |
  | settings_page.dart:144 `Fs.hero + 2` | 26 |
  | widgets.dart:324 BatButton | 17（設計：按鈕 16） |
  | widgets.dart:135、:173、team_status_page.dart:192 | 15 |
  | main.dart:342 技術資訊 | 12（設計 13） |

  如果原始碼掃描只找「這一行有沒有 `Fs.`」，`Fs.hero - 3` 和 :324 那行都會過關。
- **影響**：StatusHero 是每一頁最顯眼的那句話，21 → 24 會改變每一頁的版面，T-C2 在 2.0 倍字體、360 dp 寬時可能溢出，T9 的 PNG 也全部要重產。
- **修正**：
  1. 計畫列出每一處「現值 → 目標級」。像 21 → 24 這種會被看見的改變要明寫；若 21 是當初為了排得下才刻意縮的，就改設計（目前 21 的理由要先查），不要默默改。
  2. 掃描要解析整個運算式：只接受 `Fs.<級>` 或白名單的確認碼大數字（member_ui.dart:66／:95、team_pages.dart:352），其他算式一律 FAIL。
  3. 原始碼掃描只是 lint，另外要在畫板測試裡走一遍 render tree，斷言每個 `RenderParagraph` 的實際字級 ∈ {28, 24, 18, 16, 14, 13} ∪ 白名單（這樣也抓得到 Material 預設字級）。負向對照：放回一處 `Fs.hero - 3` → 兩者都 FAIL。

### M-5 T6 節點頁的主要按鈕：會出現重複按鈕、兩顆主按鈕，句子也會自相矛盾

- **證據**：
  - 節點頁已經有「網路」分組的 `node-join` 列，條件是 `nodeState==1 && netFiles>0` 或 R16 成員（node_page.dart:86-122）。T6 在 StatusHero 再加一顆「加入網路」，同一頁就有兩個同名入口；PR 6 的 home_no_node 規則是「頁上只有一個」（home_page.dart:385-387 的註解）。
  - `SendKeyButton` 是主要按鈕 BatButton（send_key.dart:50）。藍牙關閉時 hint 會保留上一次的值（prober.dart:29-31 的註解：key error 時 hint keeps its last value；藍牙關閉時 hint 不會被清掉），這時加上「開啟藍牙」就是兩顆實心主按鈕，違反 §3.2，也會被 §3 新加的斷言抓到。
  - `whyNext(Why.noPermission)` 寫「請回首頁按『允許藍牙權限』」（home_logic.dart:195）。節點頁有了按鈕之後，這句話指向別的頁面，違反 §3.4 規則 3。
  - 首頁第 6 列在 `NetRecords.unknown` 時也給「加入網路」（home_logic.dart:93），T6 寫「手機有網路紀錄」，沒有說明 unknown 的情況怎麼處理。
- **與 D8、租約的關係（查過，沒有衝突）**：按鈕開的是同一個 `NetFormPage`，「開始」時才拿 flow 租約，和現有的 `node-join` 列相同；藍牙／權限按鈕不拿租約；也沒有「建立網路」。
- **修正**：
  - StatusHero 的按鈕出現時，拿掉 `node-join` 列（或反過來只留列，二擇一並寫明）；
  - 被擋住（藍牙關閉、沒有權限）時，hint 的按鈕隱藏或降為次要；
  - `whyNext` 在節點頁改成指向這頁的按鈕；
  - unknown 照第 6 列處理。

  測試：畫板測試涵蓋「hint + 藍牙關閉」和「沒加入網路 + 有 net」，斷言一顆主按鈕、一個「加入網路」；負向對照：拿掉互斥 → FAIL。

---

## MINOR

- **m-1 T10 與基準相反**：設計 :315（S10）明寫「BLE 位址搬到技術資訊」，計畫卻寫「§5.3 只要求畫面不顯示」，這不正確。如果因為隱私決定不搬，要在設計 S10 寫「偏離 + 理由」（例如：節點用隨機位址、技術資訊可以複製出去），不能直接「關掉」。這是對已審設計的變更，在 PR body 上要標出來。（§2 其他項目我沒有看到真正屬於產品決策的；T15 的「另議」在設計 §4.3 凍結的範圍內，不改是合理的。）
- **m-2 T1 細節**：
  - `Keys.open` 改成 private，像 sign／seal 一樣，只透過 `KeyUses` 交給 `KeyHandlers`，否則 MainActivity 仍然能繞過閘門；
  - 加 `KeyOp.OPEN(listOf(RECORD_AES))`；
  - 每次 `open` 會多讀四把金鑰的 level（`levels()` 讀全部，KeyHandlers.kt:74），自動讀取每次嘗試、hint、NetIndex 每次重算都會呼叫 `open`。要在 S20 量每次 `open` 的耗時，對照 8 s 的 msg2 預算記錄下來；
  - 計畫說 open 是「唯一繞過閘門的金鑰呼叫」，要補一句：publicKeys／firstRun 也不經閘門，但它們不用私鑰對外做事。
- **m-3 T2 不能誇大**：Dart 收到的是 codec 編碼的副本（`result.success` 會同步編碼，和現有 ecdh 的 wipe 用同一個前提），清零只是讓 Kotlin 那份消失。殘留寫成「Dart 端、codec 緩衝、Cipher 內部仍有副本」。
- **m-4 T8 `roundsEnded` 的定義**：
  - 只在 `_end` 計數，`_cancel` 不算（core.dart:369-374 對 :563）；要寫明 early 輪和節點頁只讀單台的輪算不算。
  - 被取消的輪不算的話，常開頁面的使用者會比較久看到「正在找你的節點…」，要寫成預期行為。
  - `roundsRun < 3` 有 4 處（home_page.dart:280、node_page.dart:168、net_pages.dart:540，還有 home_logic 的輸入），改成 core 的一個 getter。
  - 負向對照：第 2 輪結束、第 3 輪開始之前 → `firstRounds` 是 false；改回 `roundsRun < 3` → FAIL。
- **m-5 §3 指引斷言的範圍與估計**：
  - layout_test 約 50 頁 × 2 尺寸 × 3 縮放 × 深淺色，已經通過 tap target 和 contrast 兩個指引（layout_test.dart:248-249），所以產品頁大致預期會過；
  - 風險集中在三處：畫板載入真的 CJK 字型（retest_s_shot.dart:24-40，反鋸齒，13 sp 的細筆畫）、開發者頁（舊 Material 元件，scan.dart:140 等）、對話框的遮罩；
  - 我估計產品頁要修 0–5 處，開發者頁可能更多；
  - 設計 T-C4a 把舊控制台和開發者頁排除在用詞檢查外（設計 :904），§3 要先寫明開發者頁是否也排除在這三個斷言外；先空跑一次記下 FAIL 數，再決定要修多少，不要讓 PR 範圍膨脹。
- **m-6 §3 真機對比的方法沒有定義**：要寫出怎麼從 `adb screencap` 定位文字和底色（例如用畫板的元件座標裁切，取兩個主要色叢），以及判準數字。FLAG_SECURE 頁截出全黑、或找不到文字區塊時，結果要記為 ❓，不能算通過。
- **m-7 §4 副作用清單**：
  - 只能用 `adb install -r`（feedback「手機只准 adb install -r」）；
  - 用 adb 關開藍牙是改手機設定，#349 R-4 也是先取得同意才做，要列出來並請使用者核准；
  - 04 目前在網路中，所以節點頁的「加入網路」按鈕真機看不到，要明寫 ⚠️（只有畫板測試），不要寫成真機驗過。
- **m-8 T18 已經有答案**：i329d.md:219 已經寫 `TeamView` 沒有 device id（teamview.rs:85-97），要改 Rust 資料，並且和 N+1 team-write 一起做。直接寫「維持偏離」，不必「先查」。
- **m-9 T11 的重畫時機**：NodeLink 在 `released` 時如果已經有下一個租約，只做 `setRecords`、不 `_pump`，也就不會發 `changed`（node_link.dart:497-504）。這時首頁要等 15 s 的 tick（home_page.dart:118）才會重新過濾，要寫明（可以接受）。負向對照：改回在取得清單那一刻算數量 → 「pending 列出時 core 還沒有那台、之後才有」的測試 FAIL。
- **m-10 §6 的負向對照太籠統**：使用者規則要求每個修正都有負向對照。T6、T7、T9、T11、T12、T16、T19 各寫一行「拿掉什麼 → 哪個測試 FAIL」。
- **m-11 T14 的周邊文字**：t_u2_guard.dart:1-2、t_u2_main.dart:6、:31 的註解寫「firstRun 會重產四把」，T14 之後不再正確，要一起改；KeyHandlers.kt:9-10、MainActivity.kt:70-74 的「Not gated: open」註解也要改。
- **m-12 T9「網路：」那一行**：要寫明只在讀取新鮮時顯示（不新鮮時是舊的 netId，可能誤導）；k1=1 時 `membership_line` 回「已認領，還沒加入網路」（statuspage.rs:372-377、tests/statuspage.rs:331），和 StatusHero 的「還沒加入隊伍網路」重複，這種情況不要顯示。

---

## 已查證、沒有問題的部分

- §1 的證據行號大致正確：claim.dart:183-190 `goneNote`、home_page.dart:246、:338-345、claim.dart:408 在 `requestMtu` 之前指派 `conn`、claim.dart:499-502 先 cancel、scan.dart:45-47 dispose 不 await。main.dart:97-99 只在 `_app != null` 時才會走到，而那時 MainPage 已經被首頁取代，確實是死碼。
- T3 的原始佔用頁面確實只有 ClaimPage 和 ScanPage（main.dart:331／:336、home_page.dart:245）。
- T6 不碰 D8（PR 3 計畫 :250），按鈕本身也不拿新的租約。

## 結論

**REJECT（v1）**。B-1 和 M-1～M-5 修正後，整份計畫重新送審。
