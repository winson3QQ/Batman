# #329 PR 7 計畫 v2 審查（審查者 C，第二輪）

範圍：`docs/design/329-pr7-plan.md` v2（b4259a7）整份，對照 main 3020374 的原始碼與 #329 未勾清單（scratchpad `i329d.md`，49 行）。基準（設計 v12.1、PR 1–6）不重審。唯讀；沒有上機，沒有跑測試。

統計：**BLOCKER 1 / MAJOR 2 / MINOR 11**。結論：**REJECT**。第一輪的 T13 問題已經因為不修（N1）而消失，T6 也已大致修正；但 T14 的新規則「既有金鑰絕不刪」換掉了舊的 BLOCKER，卻帶出同一類的新 BLOCKER：第一次啟動被中斷後，手機會永久停在死狀態。另外，`_install` 不改這個前提也不成立。

---

## 第一輪 BLOCKER / MAJOR 的處理狀況

| 第一輪 | v2 狀態 | 說明 |
|---|---|---|
| A-B1 / B-B1（T14 沿用半套金鑰） | ⚠️ 部分解決 | 「缺的才補」修好了「缺金鑰卻寫 marker」的問題。但「既有金鑰不合格就回錯誤、永遠不刪」造成同類的新死狀態（見 B-1）；`_install` 的失敗路徑也沒有跟著改（見 M-1） |
| A-M1 / B-M3（JVM 測不到、缺契約/安全段） | ⚠️ 部分解決 | §6 已補。但純函式只涵蓋「該產生哪幾把」，「只刪這次產生的」這條清理規則沒有 JVM 測試，也沒有負向對照（見 M-2） |
| A-M2 / A-M3 / B-M2（T13） | ✅ 改成不修（N1） | 剩下的是記帳問題（m-1） |
| A-M4 / B-M5（T6） | ✅ 大致解決 | 「加入網路」沿用 node-join 列；有 hint 時只有一顆實心按鈕；whyNext 改字。剩 m-4 |
| B-M1（漏項） | ⚠️ 沒有完全解決 | §8 說 :90、:178 已補進 §1 / §3，但兩張表裡都找不到（見 m-10） |

---

## BLOCKER

### B-1 T14：「既有金鑰不合格 → 回錯誤、不刪、不寫 marker」讓第一次啟動中斷的手機永久停用。今天的程式會自己恢復

**情境 1：產生金鑰時被中斷，留下 SOFTWARE 等級的金鑰。**
- `generate()` 先用 StrongBox 產生並讀回等級（Keys.kt:64）。等級不是硬體時，下一行才刪掉它（:66），再改用 TEE 產生（:67）。
- Keys.kt:58-59 的註解寫明：在 Keymaster 4 上，keystore2 會「靜默用軟體模擬 ECDH」。所以 OWNER_ENC 用 StrongBox 產生時，讀回可能是 SOFTWARE（facts §9；S20 是否屬於這類，⚠️ 我沒查）。
- StrongBox 產生金鑰要好幾秒。如果行程在 :64 到 :66 之間被結束（使用者滑掉 app、沒電、系統回收），就會留下一把 SOFTWARE 的 `batman-owner_enc-v1`，而且沒有 marker、沒有任何紀錄。

**今天：** 下次啟動時 `_install` 呼叫 `firstRun`（main.dart:220-226），`generate` 先 `delete` 再重新產生（Keys.kt:63），得到 TEE 等級的金鑰，手機恢復正常。

**T14 之後：** OWNER_ENC 已經存在，等級是 SOFTWARE。field build 不允許這個等級（KeyPolicy.kt:63-66 `allowed`），T14 規則是回錯誤、不刪、不寫 marker。之後每次啟動都會再呼叫 `firstRun`，每次都得到同樣的錯誤，**永遠不會恢復**。畫面上看到的是：
- RECORD_AES 是硬體等級，所以 `appUsable` 為真，app 照常進首頁（見 M-1）；
- 但 `claim` 和 `recover` 永遠是 false。

唯一的出路是清除 App 資料或重新安裝。畫面不會這樣告訴使用者，而且 key_abilities_test.dart:619 明確斷言不顯示「清除 App 資料」。

**情境 2：同一類的其他來源，結果都是今天會自己恢復、T14 之後卡死。**
- **金鑰讀不出來**：例如系統升級後金鑰資料損壞，`level()` 丟例外（Keys.kt:35-39）。`firstRunPlan(existing: Map<KeyRole, Int?>)` 的輸入沒有「讀不出來」這個值，所以整個 `firstRun` 丟例外，每次啟動都一樣。今天 `generate` 的 `deleteEntry` 會把它清掉再重產。
- **既有金鑰自我測試失敗**：例如舊版用不同的參數產生的同名 alias。也是永久錯誤。

**不一致：** 同一支手機、同一個等級，結果不同。新產生的 SOFTWARE 金鑰，`firstRun` 不檢查政策就照樣成功、寫 marker（Keys.kt:180-191，今天如此，v2 也沒改）；已經存在的同一把 SOFTWARE 金鑰卻是「錯誤、永不寫 marker」。

**v2 不刪既有金鑰的唯一理由，應該在它的根源修。** v2 的理由是 `store_has_records` 讀不到目錄時回 false（simple.rs:47 `unwrap_or(false)`）。如果讓這個函式在讀不到時失敗，「沒有 marker 而且確定沒有紀錄」就真的代表沒有任何資料依賴這幾把金鑰，替換不合格的金鑰就是安全的：
- marker 只在 `firstRun` 成功後才寫（main.dart:226-228）；
- 紀錄只在 app 可用之後才會寫；
- RECORD_KINDS 涵蓋了 forgotten 與 member 類（simple.rs:31-32）。

**修法（技術細節，可自行定案）：**
1. Rust：`store_has_records` 改成 `Result<bool, String>`。子目錄不存在算「沒有紀錄」；其他讀取錯誤回 Err，`_install` 把它當成啟動檢查失敗，顯示重試，**不呼叫** `firstRun`。這才是 #329:220 真正的風險，也就是紀錄存在但讀不到時把金鑰重產掉。負向對照：讓 `records/node` 不可讀時 `firstRun` 不被呼叫；改回 `unwrap_or(false)` → FAIL。
2. Kotlin `firstRun`，每個 role 分三種情況：
   - 不存在 → 產生；
   - 存在、讀得出來、`Level.isHardware`（OWNER_ENC 在 dev build 照 `KeyPolicy.allowed(…, devTrust)`）、而且自我測試通過 → 保留；
   - 存在但讀不出來、等級不合格、或自我測試失敗 → 刪掉再產生（前提是第 1 點已經保證沒有紀錄）。
3. 失敗時只刪這次呼叫產生的金鑰，保留第 2 點裡被保留的那幾把。
4. `firstRunPlan` 的輸入要能表示「讀不出來」，例如 `sealed class Seen { Missing, Unreadable, Level(n) }`，另外加上 `devTrust` 參數。

如果堅持「絕不刪既有金鑰」：計畫必須寫明這條死路，把出路「清除 App 資料」附上證據（見 m-8）顯示在畫面上，並修改 key_abilities_test.dart:619。但這只是把卡死改成需要人動手，不如第 1、2 點。

---

## MAJOR

### M-1 `_install` 不改不成立：firstRun 失敗後，只要 RECORD_AES 還在，app 照常可用，接著寫出的紀錄會讓缺的那把金鑰永遠補不回來

**證據：**
- `_firstRunFailed` 只在 `!keys.appUsable` 的分支裡被使用（main.dart:128-133），而 `_ok = agree && keys.appUsable`（main.dart:183）。也就是說，firstRun 失敗並不會讓 app 停用。今天這點沒有影響，因為失敗時會刪掉全部四把金鑰（Keys.kt:188），`appUsable` 一定是 false。
- T14 之後，失敗時保留既有的金鑰，RECORD_AES 常常還在。

**情境：**
1. 第一次啟動被中斷，留下 RECORD_AES、OWNER_SIGN、OWNER_ENC 三把。
2. 下次啟動補產 ADMIN_SIGN 時失敗，例如 StrongBox 暫時出錯。T14 只刪掉 ADMIN_SIGN，回錯誤。
3. 因為 `appUsable` 為真，app 照常進首頁；claim 也是可用的（sign + enc）。
4. 使用者認領節點，寫入 `node/` 紀錄。
5. 從此 `store_has_records` 為真，`firstRun` 永遠不會再跑（main.dart:220-223），ADMIN_SIGN 永遠不存在，「建立網路」永遠不能用。
6. 唯一的出路是重新安裝，這會丟掉擁有者金鑰，節點只能重燒。

**另一個問題：** 失敗時的字「第一次啟動失敗（金鑰已全部刪除，下次開 App 會重試）」（main.dart:232）在 T14 之後通常是錯的：既有金鑰留著，而且沒有寫明「下次」只會補缺的。第一輪 B-B1 第 4 點已經指出這點，v2 沒有處理。

**修法：**
- `_install` 回傳 firstRun 失敗時，`_ok` 必須為 false。也就是在 `firstRun` 失敗時強制停用 app，只顯示重試，不論 live levels 怎麼說。
- 修改那句字。
- 測試：假 `firstRun` 丟錯、`keyLevels` 回 RECORD_AES 是硬體等級 → 不進首頁、有「再試一次」。負向對照：拿掉強制停用 → 進了首頁 → FAIL。

### M-2 T14 的測試只涵蓋「要產生哪幾把」，「只刪這次產生的」與 devTrust 都沒有負向對照

- `firstRunPlan(existing) → (要產生的, 要驗的)`。其中「要驗的」永遠是四把，所以 JVM 能證明的只有「要產生的 = 缺的」。
- 真正會毀資料的是清理規則，也就是 catch 裡刪什麼（今天 Keys.kt:188 刪全部）。這段在純函式之外，JVM 測不到。
- instrumented 測試照計畫寫法，在既有金鑰等級被拒時就回錯誤。如果這個檢查放在 try 之前，把 catch 改回「刪全部」也不會被抓到。
- 計畫說「模擬器 Keystore 等級 0」，沒有附證據；KeyHandlersDeviceTest.kt:48 只把等級寫進 log。
- `firstRunPlan` 沒有 `devTrust` 參數，無法依 KeyPolicy.kt:63-66 判斷 OWNER_ENC 的 SOFTWARE 等級。

**修法：** 照第一輪 A-M1 的原意，把整個流程抽成注入式。例如：

```kotlin
interface KeyOps { fun seen(r): Seen; fun generate(r): Int; fun selfTest(r); fun delete(r) }
fun firstRun(ops, devTrust)
```

JVM 測試至少要有：
- 全無 → 產生四把；
- 部分存在 → 只產生缺的，既有的不碰；
- 部分存在、新產生的那把自我測試失敗 → 只刪新的；
- 照 B-1 的修法：既有一把讀不出來或等級不合格 → 刪掉再產生（或照你的定案）。

負向對照：catch 改回刪全部 → 「既有的不碰」FAIL；拿掉 devTrust → dev 的 OWNER_ENC SOFTWARE 那案 FAIL。

instrumented 測試（只在 `adb -s emulator-5554` 跑）改成不依賴等級：先用 `Keys("bmtest")` 產生一把，呼叫 `firstRun`，不論成功或失敗，斷言那把的公鑰沒變；另外把模擬器實際的等級記進計畫。

---

## MINOR

**m-1 N1 不能打勾。**
- 規則是「重現不到就說明嘗試了什麼，並在修之前先問」。這不等於把已知的缺陷算成完成。
- 20 s 白等的機制已經由原始碼證實（第一輪 B-M2：reactive_ble 會結束 subscribe、prober.dart:262 沒有接 onDone、只剩 `answer` 計時器）。
- 真機的部分是「沒有嘗試」，不是「重現不到」。
- 修法：#329:115 不打勾，改寫成殘項，列出：原始碼證據、沒有在真機嘗試的原因、不修的理由（結果正確、只是多等）、以及將來修時要守的三條契約（第一輪 A-M2 / B-M2）。在 PR body 讓使用者知道。

**m-2 T1 的 `open` 經過 `KeyHandlers.use`，會讀全部四把的等級（KeyHandlers.kt:73）。**
- 結果是：OWNER_ENC 或 ADMIN_SIGN 任一把讀不到時，所有 `open` 都會失敗，雖然 `KeyOp.OPEN` 只需要 RECORD_AES。
- 把 open 失敗當成「沒有」並且之後會覆寫的呼叫點，不只 `RecordUiStore`（ui_state.dart:227-231）。還有 owner_console.dart:544 的 `joinreq`：它把 `pendPlain == null` 當成沒有暫存的申請，以 CAS 寫新的。
- 這些都是既有的風險，但 T1 擴大了觸發的條件。
- 修法（二選一）：讓 OPEN 只讀它需要的那幾把的等級（`KeyUses` 加 `level(role)`）；或在 §6 列出所有呼叫點，逐一說明為什麼沒有變得更糟（第一輪 B-M3 要求過這份清單）。

**m-3 T3 的原始碼鎖寫錯了例外清單。** 直接寫紀錄的，除了 `claim_records.dart`，還有：
- `ui_state.dart`（`storeWriteCas` / `storeRemove`）；
- `main.dart`（`storeWriteMarker`）；
- `app_link.dart`（RecordWriter 的接線）；
- `lib/src/rust/api/*` 的生成碼。

照 v2 寫的「例外只有 claim_records.dart」，鎖一上線就會 FAIL。修法：照第一輪 A m-4 的清單寫。

**m-4 T6 的「永久拒絕 → 開 app 設定」在節點頁拿不到這個狀態。**
- 核心只有 `Why.noPermission`（core.dart:340）。「永久拒絕」是在 `PermissionsPage` 被拒絕之後才知道的，那一頁會給「開啟 app 設定」（intro_pages.dart:163-173）。
- 修法：節點頁的 noPermission 按鈕走首頁 `_permission()` 的同一條路，也就是推出 PermissionsPage。把 `_permission` / `_settings`（home_page.dart:215-230，目前是 HomePage 的私有方法）抽成共用的函式。測試只寫兩種狀態，不是三種。
- 有 hint 而且藍牙關閉時，「把新密碼送給節點」按下去也送不出去，建議隱藏，不要只降成次要按鈕。

**m-5 T8 `roundsEnded` 沒有寫重設的時機，也沒有上限。**
- `background()` 會清 `_fullEnds`（core.dart:228）。`firstRounds` 是每次回到前景就重算，還是整個行程只算一次？
- 輪會被取消的情況很多：`setPage`、`acquireLease`、`setRadio`、`refresh` 都會 `_cancel`（core.dart:208/242/298/310）。節點頁的輪又只讀一台，不算數。所以 `firstRounds` 可能一直為 true，「沒找到」也就一直被壓成「正在找」。
- 修法：寫明重設的規則，並加一個時間上限（例如從第一輪開始算超過 N 秒，就不再算頭兩輪）。

**m-6 T16 的字元分類要寫清楚。** 「中文」指的是 CJK 表意字；全形標點（「」、：）、emoji、數字各自怎麼處理要寫明。例如 X 前面是「到」、後面是「」」時：英文名字的開頭補空白，結尾接標點就不補。單元測試加一條「後面接全形標點」。

**m-7 §4 真機對比的方法還是無法執行。** 「文字像素中最常見色」沒有說怎麼找出哪些是文字像素。反鋸齒會讓文字的顏色分散，畫面上最常見的第二種顏色多半是卡片底色。修法：用畫板裡元件的座標，裁出 S20 截圖上同一個區塊，取亮度最暗和最亮的那一群顏色，判準寫成數字；找不到文字區塊時記 ❓。

**m-8 T14 的證據前後矛盾，而且還沒補上。**
- §2 寫「S20 的 `pm` 實測：tu2 套件的金鑰在重裝後不存在」；§5 卻寫真機不做、改用 AOSP 原始碼。
- 解除安裝和清除資料都會清 Keystore 這件事：我記得 PackageManagerService 的 `clearKeystoreData`，在移除套件和 `clearApplicationUserData` 時都會呼叫。但這是 ⚠️ 憑記憶，沒有查原始碼。
- 如果 B-1 不照我的修法，這就是唯一的出路，必須在設計核准前補上 `file:line`。

**m-9 兩個 `firstRun` 同時跑時，「只刪自己產生的」不成立。**
- `generate` 一開頭就 `delete(role)`（Keys.kt:63）。兩個呼叫同時補同一把時，後到的會刪掉先到的剛產生的金鑰；失敗清理也會刪掉對方的。
- 實際上很難發生：Manifest 的 configChanges 已涵蓋旋轉、深色模式、語言（AndroidManifest.xml:38），T-U2 又是另一個套件。
- 修法：`firstRun` 加行程內的鎖（companion object 的 `@Synchronized`）。產生前再確認一次那把不存在，不要在 `firstRun` 的路徑上做無條件的 `delete`。

**m-10 漏項的對照表還是不完整。**
- §8 說 :90、:178 已經補進 §1 / §3，但兩張表都沒有。
- 計畫完全沒有提到的未勾行還有：86、89、90、91、178、181、182、183、184、185、188、189、194、201、216、217、218。這些都要使用者在場、要第二支手機或第三台節點，或要 02 重燒。
- 修法：加一張「本 PR 不碰」的表，列出這些行和原因，讓總數等於 49。

**m-11 周邊的註解還沒列進要改的清單。** 第一輪 B m-11 指出的：
- t_u2_guard.dart:1-2、t_u2_main.dart:6 / :31：「firstRun 會重產四把」；
- KeyHandlers.kt:9-10、MainActivity.kt:70-74、:114：「Not gated: open」、「all or nothing」；
- Keys.kt:175-179 的 KDoc。

T1 和 T14 之後這些都不再正確，v2 的 §8 MINOR 欄沒有列。

---

## 已查證、沒有問題的部分

- **既有金鑰的 selfTest 是否無害：** 是。OWNER_SIGN 簽的是 `batman-owner-op-v1` 加上 32 個 0x01（Keys.kt:143）；ADMIN_SIGN 簽的是 payload 為空的 COSE Sig_structure（:169-173）；兩個簽章都只在記憶體裡驗完就丟，不會離開這個行程。OWNER_ENC 是和臨時金鑰做 ECDH，結果清零（:152-158）。RECORD_AES 是 seal/open 一個固定字串（:161-163）。對既有金鑰跑 selfTest 不會產生可以拿到外面用的東西。
- **T1：** `KeyOp.OPEN(listOf(RECORD_AES))` 加 `keyCall`，失敗時是 fail-closed。「金鑰不見了」從 `keystore` 錯誤改成 `keyLevel` → 2.4，這是 F-m4 要的結果。T2 是在 `keyCall(result, wipe = true)` 裡 `result.success` 之後清零（MainActivity.kt:83），前提和 ecdh 相同；殘留的明文已寫明，沒有誇大。
- **T10：** 現在的位址只進 logcat（claim.dart:285 `_log('found $id')`）。改成放進技術資訊符合 S10（329-app-uiux.md:315）。
- **T6：** 不加「建立網路」符合 PR 3 D8。whyNext 只有 node_page.dart:176 和 net_run.dart:52-53 在用，而 net_run 只用 identity / refused，改 noPermission 那句不會影響它。
- **T20、T11、T12、T7、T19：** 沒有意見。
- **§5 副作用：** 只用 `adb install -r`；關開藍牙要先取得同意；04 在網路中，所以只有 widget 測試。這些都已經寫明。
- **安全（逐 actor）：**
  - 本機無特權 app：Keystore 依 UID 隔離，平台通道在本行程內，沒有新的攻擊面。
  - 遠端攻擊者、被攻破的節點：不經過這條路徑。
  - 我們自己的錯：B-1 / M-1 照修法改了之後，任何呼叫者（包括 T-U2）都只能替換「沒有紀錄可以依賴」的金鑰。這比 v2 的「絕不刪」少了死路，又比今天的「無條件重產」多了 `store_has_records` 在讀不到時失敗這道保護。

## 結論

**REJECT**。B-1、M-1、M-2 修正後，整份計畫重新送審。其餘各項（T1–T20 除 T14 外）方向正確，只有 MINOR。
