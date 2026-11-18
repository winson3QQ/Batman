# #329 PR 7 計畫 v1 審查（審查者 A）

範圍：`docs/design/329-pr7-plan.md`（753681c）整份，對照 main 3020374 的程式與 #329 清單（i329d.md 的 49 個 `- [ ]`）。基準（設計 v12.1、PR 1–6）不重審。唯讀；沒有上機。

結論：**REJECT**（1 BLOCKER、4 MAJOR、11 MINOR）。T14 照現在寫法會在「第一次啟動被中斷」後把 app 永久鎖在「金鑰不見了」，而且違反 §4.1「全有或全無 + 每把自我測試」的已審契約；改完 T14 與 MAJOR 後整份再審。其餘大部分定案方向正確（T1、T2、T3、T4、T7、T11、T12、T15、T19 沒有問題，或只有 MINOR）。

---

## BLOCKER

### B-1 T14：「沒有 marker、沒有紀錄、金鑰還在 → 沿用並寫 marker」會把不完整、沒測過的金鑰組永久定案

**情境**：第一次開 app，`firstRun` 在 Kotlin 執行緒上逐把產生金鑰（StrongBox 產生要數秒）。使用者在這時滑掉 app，或系統殺掉行程：
- `Keys.firstRun` 的 `catch` 只在**例外**時刪金鑰（Keys.kt:180-194）；行程被殺不會走到 → 留下 1–3 把金鑰，或 4 把但最後一把沒做 `selfTest`。
- `generate()` 本身也可能停在 `make(strongBox=true)` 之後、改試 TEE 之前（Keys.kt:66-76），留下的是**較差的等級**那一把（例如 KM4 上被軟體模擬的 owner_enc = SOFTWARE）。

下次開 app：沒有 marker、沒有紀錄（main.dart:215-224）→ 呼叫 `firstRun` → T14 下 Kotlin 回 `keysExist` → `_install`「沿用現有金鑰、寫 marker」。marker 一寫，之後**永遠不再產生金鑰**（main.dart:216-219；key_abilities_test.dart:600 `with a marker the keys are never made again`）。結果：
- 缺 RECORD_AES / OWNER_SIGN → 每次啟動都是「金鑰不見了」，唯一出路是清除資料或重裝；
- 缺的那把等級不對（SOFTWARE）→ field 版永久不能認領。

今天的行為反而是對的：沒有 marker、沒有紀錄時重新產生，什麼都沒丟（沒有紀錄 = 沒有東西被封過）。

**計畫的理由不成立**：「重產反而可能毀掉別人以為還在的東西」。Android 在**解除安裝**時會清掉該 app UID 的 Keystore 金鑰（keystore2 在套件移除時清 namespace；計畫要附 AOSP `file:line` 或 S20 實測——目前沒有證據），所以「重裝後金鑰還在」幾乎不會發生。實際會走到 `keysExist` 的路徑只有：(a) 第一次啟動被中斷（上面這條，最常見）；(b) `firstRun` 成功但 `storeWriteMarker` 失敗（此時四把完整、測過）；(c) 檢查程式（T-U2）。計畫的沿用規則對 (a) 是錯的。

另外 `keysExist` 這條路沒有 levels 可寫進 marker（`_install` 的 marker 內容來自 `firstRun` 的回傳，main.dart:226-229），計畫沒說從哪裡來。

**修法（技術細節，可自行定案）**：把 Kotlin `firstRun` 改成「**補齊、但絕不刪除已經存在的金鑰**」：
1. 每個 role：已存在 → 保留，讀等級，做 `selfTest`；不存在 → `generate` + `selfTest`。
2. 失敗時只刪**這次呼叫產生的**金鑰（不是 `KeyRole.values()` 全部，Keys.kt:189）。
3. 已存在的金鑰等級不被允許或 `selfTest` 失敗 → 回錯誤（例如 `keysExist`，details = role 與等級），不寫 marker；畫面走現有的「金鑰沒有建立成功」+ 技術資訊；出路 = 清除 App 資料（要先附證據：S20 上「清除資料」會刪 Keystore 金鑰。沒有證據就寫「重新安裝」）。
4. 成功 → 回四把的等級 → Dart 照舊寫 marker。不需要 Dart 端的「沿用」分支。

這個版本比計畫的更強：任何呼叫者（T-U2、被汙染的 plugin）都毀不掉既有金鑰，也不需要「覆寫旗標」這種可以被任何人帶上的後門。中斷後下次啟動會自動補齊。

---

## MAJOR

### M-1 T14 的測試照計畫寫法跑不起來

`Keys` 在建構時就 `KeyStore.getInstance("AndroidKeyStore")`（Keys.kt:25），所以 `app/tools/kotlin-unit-tests.sh` 的 JVM 單元測試沒辦法建出它。現在唯一碰 `Keys` 的測試是 instrumented 的 `KeyHandlersDeviceTest`（androidTest），而照使用者規則它只能在模擬器上用 `adb -s emulator-5554` 跑（真機絕不准 `connectedAndroidTest`）。
**修法**：把「補齊 / 拒絕」的決定抽成純函式（照 `KeyUses` 的作法注入：存在與否、等級、產生、selfTest、刪除），用 JVM 測試涵蓋：空 → 四把；部分存在（模擬中斷）→ 只補缺的、既有的公鑰不變；既有一把 selfTest 失敗 → 拒絕、什麼都不刪；產生到一半丟例外 → 只刪這次產生的。負向對照：換回現在的 `firstRun`（`generate` 先 `delete`）→「既有金鑰公鑰不變」FAIL。再加一個模擬器的 instrumented 測試跑真的 AndroidKeyStore（alias 前綴 `bmtest`，現有 `@Before` 會清）。

### M-2 T13：斷線立刻結束會和最後一個 frame 競爭，改變結果

- 計畫說「結果不變」。但 characteristic 通知（`inbox`，prober.dart:222-240）和連線狀態（`GateLink.state`，ble_gate.dart:71-77）是**兩條不同的 stream**，順序沒有保證。節點送出 `ended`（登入被拒、附代碼）或狀態回答後立刻斷線時，斷線事件可能先處理 → `done(failed())` 搶在 `loginOutcome(code)`／`Res.body` 之前，結果從「被拒（代碼）」變成 noResponse/broken。節點會不會在 `ended` 之後主動斷線要附證據（provd 原始碼或真機 log）。
- 讀到狀態後、等 hint/全隊區塊的 2 s 期間（prober.dart:170-188）斷線：照計畫的字面 `done(failed())` 會把已讀到的 body 變成 broken。必須是 `done(read ?? failed())`。
- `state` 是不重播的 broadcast stream：NodeLink 在 `state.first` 拿到 true（node_link.dart:611-615）到 prober 訂閱之間的斷線會漏掉。`GateLink` 只露出 `open`，沒有 `_down`（ble_gate.dart:66-69），要加一個同步可讀的狀態，訂閱時先檢查。
- handoff（prober.dart:256 提早 return）之前要取消 prober 自己的 state 訂閱，不能留在交給 flow 的 link 上；一般清理也要取消。

**修法**：斷線時不要直接結束，而是把 `answer` 計時器縮成短的寬限（例如 1 s，讓已在途的 frame 先處理），到期 `done(read ?? failed())`；訂閱前同步檢查已斷線；handoff 與清理都取消訂閱。測試：frame 先到 / 斷線先到兩種順序、hint 視窗內斷線、訂閱前已斷線、handoff 後斷線不影響 flow；負向對照：拿掉寬限 → 「ended 後斷線」那一案 FAIL。

### M-3 T13 的真機前提（SSH 重開 04）幾乎碰不到要驗的那一段

#329:115 寫的是「推論未查證」。依規則修之前要在真機重現。msg2 之後到回答之間只有登入簽章 + 狀態請求，通常不到一秒；SSH 下 `reboot` 的時間點落進這個視窗的機率很低，一次重開（使用者只同意一次）大概率只會驗到「msg2 之前斷線」（那一段本來就由 8 s `due` 處理）。這樣的真機結果不能當重現，也不能當修好的證據。
**修法**：二選一並寫進計畫：(a) 設計一個能命中視窗的觸發（例如在 04 上看到 session 開始後暫停 provd 再關藍牙控制器；這是節點動作，要列副作用與還原、另外取得同意）；(b) 照規則寫明「真機重現不到，嘗試了什麼」，T13 只靠假 backend 測試，並問使用者是否仍要修。

### M-4 T6 說「照 §5.1 第 6 列」，但只做了一部分

§5.1 第 6 列（329-app-uiux.md:671）與現有首頁（home_logic.dart:92-96）是：net / mnet / **unknown** →「加入網路」；**只有 mpend →「看我的申請」**；都沒有 →「建立網路」+ 次要「加入隊長的網路」。第 2 列還有「系統不再顯示對話框時 →『開啟 app 設定』」。T6 只列了「藍牙關閉、沒有權限、有網路紀錄 → 加入網路」：
- 漏了 mpend（看我的申請）與 `NetRecords.unknown`（中性「加入網路」）；
- 漏了權限永久拒絕的「開啟 app 設定」；
- 用詞「開啟藍牙」和首頁 `Btn.openBluetooth`（§3.3 用詞表）不一致；
- 節點頁**已經有**「網路」分組的「加入網路」列（node_page.dart:87-111，條件 `nodeState == 1 && netFiles > 0` 或 R16 隊員入口）。計畫沒說新的主要按鈕和這一列的關係（兩個一樣的入口？條件一致嗎？mnet 的情況現在走 R16 條件）。

照現在寫法打勾 #329:125 會是錯的勾。**修法**：把節點頁主要按鈕寫成和 `decideHome` 第 1、2、6 列同一張表（D8 的例外只是不給「建立網路」——那一格要寫成什麼：無按鈕 + 一句「到首頁建立網路」？），共用 `HomeAction`／`Btn`；和現有分組列的關係寫清楚；測試逐格（含 mpend、unknown、永久拒絕）。

---

## MINOR

### m-1 清單盤點有漏項 / 分類不完整
- **90**（設計逐條寫出情境 1–10）：前半已完成（329-app-uiux.md:796-811 §6），後半（一般隊員實測）要使用者在場。計畫完全沒列。
- **148、177**（02 B 槽重寫、04 回 N0 路徑）與 **178**（R-7 大部分情境）：§5 沒列。148/177 跟著使用者「147 先不回 N0」的決定，178 依賴 02 重燒或使用者在場。
- **117**：R-4、A22 已在 #349 做完（i329d.md:108、:169）。本 PR 要把 117 的文字更新成只剩 R-3、A11、A13、R-6。
- **118**：T5 只處理「太舊節點的句子」這個子項；118 的本體（A13 + VPN）還要使用者在場（同 182/217）。計畫要寫明 118 不打勾。

### m-2 T18 是沒查完的分支，應在計畫內定案
實際查證：`Listed` 沒有 device id（teamview.rs:118-126）。隊長手機的 `net/` key 11 每一項有**選填**的 `?6 device_id`（netrec.rs:4、:239），而 `admin_names` 本來就解開這份紀錄（teamview.rs:162-174）→ 隊長手機可以帶後四碼，不必多一次 openNet。隊員手機的名稱來源是簽章名單 key 4（只有 key 1-5，沒有 device id）→ 要改協定，做不到。舊紀錄沒有 key 6 → 不顯示。#329:219 原本說「N+1 打開 team-write 時一併做」，計畫要說明為什麼現在做。

### m-3 T1 的連帶改動
- `MainActivityKeyUseLintTest.everyKeyChannelForwardsToKeyHandlers` 的清單（MainActivityKeyUseLintTest.kt:25）要加 `open`，否則以後有人改回 `Thread {}` 不會被抓到；KeyHandlers.kt:9 與 MainActivity.kt:72-74 的註解要改；`KeyOp` 加 `OPEN(listOf(RECORD_AES))`。
- `KeyHandlers.use` 每次都讀**四把**的等級（KeyHandlers.kt:73）：任一把讀不到時 `open` 也會失敗；`RecordUiStore.read` 把任何 `open` 錯誤當「沒有」並在下次寫入時覆蓋（ui_state.dart:227-231）。這是既有行為，但失敗的情況變多了，要寫進計畫。
- 成本：每次 open 多四次 Keystore 讀取；NetIndex 每次佔用釋放後重算時會打開每一份 net/mnet 紀錄（app_link.dart:177-186）。真機量一次。

### m-4 T3 的原始碼鎖寫錯對象
T-G5 (b) 鎖的是**寫紀錄的函式**，不是原始佔用。現有的鎖（owner_console_test.dart:519-529）只掃 `lib/src/flows` 和 `lib/ui`；`claim_records.dart:43-53` 直接呼叫 `storeKeepCopy`／`storeWriteSealed`／`storeRemove`。建議：(1) 寫入函式掃整個 `lib/`，允許清單 = `app_link.dart`（RecordWriter 接線）、`ui_state.dart`、`claim_records.dart`、`main.dart`（只有 `_install`）；(2) 另外鎖住 `openRawPage`／`openRawPageFor` 的呼叫者只能建 `ClaimPage`／`ScanPage`。也要寫出不在佔用收回後拒絕 ClaimPage 寫入的理由：CLAIMED 那次寫入是新憑證唯一的一份，拒寫會讓節點被認領卻沒有紀錄（只能重燒）；碰撞的機率是同一個 id 在 900 s 後還有另一個寫入者，可以忽略。

### m-5 T8 的範圍與掃描
- 只掃字面的 `fontSize:` 會漏掉沒寫 style 的 `Text`（claim.dart、member_ui.dart、scan.dart 用 Material 3 預設 textTheme）與 `ThemeData` 的 textTheme；要嘛掃描也涵蓋這些，要嘛寫明舊頁不在規則內。
- 狀態句子現在是 `Fs.hero - 3` = 21（widgets.dart:120），改成 24 會影響 2.0 倍字級下的換行（T-C2）；§3 的畫板重跑要明確包含 2.0 倍。
- `roundsEnded` 要定義被取消的輪（core.dart:368-373 `_cancel`）算不算「結束」。

### m-6 T16 規則不完整
`home_logic.dart:120` 的範本是 `'還沒讀到X 的狀態'`：X 後面**固定**有空白，暱稱是中文時變成「還沒讀到前哨 的狀態」。另外 :108 `'手機連不到X'`、:97 等也是同樣的插入。規則應該是對稱的：只在中文與 ASCII 相鄰的那一邊補空白，套用到所有 `_many` 範本（home_logic.dart:66）。

### m-7 T10 是對 §3.4 S10 的偏離，不是「已滿足」
§3.4 S10（329-app-uiux.md:315）寫「BLE 位址搬到技術資訊」；§5.3（:722）只寫不顯示。計畫取 §5.3，要寫成偏離（附理由：RPA、隱私），並改 S10 那一列。

### m-8 T5 的前提有疑問
「app 無法確定節點是否太舊」：#329:118 的證據顯示，app 讀得到「status 沒有 trust（key 15）」。這可以變成一句誠實的話（「節點沒有回報更新需要的資料，節點軟體可能太舊」）。要嘛做，要嘛說明為什麼 key 15 不在不足以判斷。

### m-9 §4 真機場次要列副作用
關開 S20 藍牙（改手機設定）、安裝 APK（只准 `adb install -r`）、截圖、重開 04：逐項列出副作用與還原；FLAG_SECURE 頁截出來是黑的已經寫了。

### m-10 T17：「對方連著時」那一半不一定要第二支手機
用第二個 BLE central（Pi 或 PC 的 `bluetoothctl connect`）連著 04，同時 dev 在前景讀 04，就能在真機驗「或另一支手機正在連它」與斷線後恢復。「dev2 管自己的節點」那一半要 02 重燒（使用者在場），目前遠端做不到，要寫明。

### m-11 #329:114 的 ScanPage 殘留可以直接修
scan.dart:44-47 的 `dispose` 不等掃描取消。小修：掃描期間 `rawBusy = true`，`await _scan.cancel()` 之後 `rawIdle()`，佔用就會等掃描真的停了才交回（RawBusy 的既有機制，raw_use.dart:27-45）。比留一行殘留便宜。

---

## 已查證、沒有問題的部分
- §1 證據：claim.dart:183-190 `goneNote`、home_page.dart:246、add_pages_test.dart:160-171、main.dart:91-95（`_app == null` 的那頁只有 NodeLink 沒啟動時才出現，main.dart:322-323；:97-99 是死碼）、claim.dart:405-409 / :499-502、net_index.dart:135-147 + net_index_test.dart:95 + home_logic_test.dart:99：都成立。
- T1 對「已封好的紀錄」沒有影響：AppLink 只在啟動時 `appUsable`（RECORD_AES 是硬體等級）成立後才建立（main.dart:162-173），已存在的金鑰等級不會變，所以閘門不會擋掉正常可用的金鑰；改變只有「金鑰不見」從 `keystore` 變成 `keyLevel` → 2.4，這是 F-m4 想要的。
- T2：`result.success` 會同步編碼（ecdh 的 `wipe` 已經依賴這一點，MainActivity.kt:82-83），之後清零是安全的。
- T3（不改）在技術上是對的（見 m-4 的理由）；T4、T7、T11（建置時對 `core.states` 過濾，home_page.dart:170-180 / :275）、T12、T15、T19 沒有意見。
- T6 不給「建立網路」符合 PR 3 D8（329-pr3-plan.md:250）。
- 安全（T1/T2/T14）：本機非特權行程碰不到平台通道；主要的 actor 是「我們自己的檢查程式／被汙染的 Dart 端」，B-1 的修法讓它毀不掉既有金鑰（計畫原本的版本則只靠呼叫端不帶覆寫）。
