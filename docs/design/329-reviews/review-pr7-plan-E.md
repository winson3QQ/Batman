# #329 PR 7 計畫 v3 — 獨立對抗式審查 E（第三輪）

範圍：`docs/design/329-pr7-plan.md` v3（3b89fab）整份，對照 main 3020374 的原始碼與 #329 未勾清單（scratchpad `i329d.md`）。基準（設計 v12.1、PR 1–6）不重審。唯讀；沒有上機、沒有跑測試、沒有編譯。所有證據是原始碼 `file:line`（路徑相對 `app/`）。

統計：**BLOCKER 0 / MAJOR 0 / MINOR 12**。結論：**APPROVE-WITH-CHANGES**。

---

## 前幾輪 BLOCKER / MAJOR 的處理狀況

| 前輪 | v3 狀態 | 證據 |
|---|---|---|
| A-B1 / B-B1 / C-B1 / D-M2（T14 毀損或卡死） | ✅ 解決 | Kotlin `firstRun` 不動（Keys.kt:180-192：`generate` 先 `delete`，Keys.kt:63；失敗時四把全刪，:187-189）。中斷留下的半套 / SOFTWARE / 讀不出來的金鑰，下次啟動都會照今天的方式重產，不會卡死。唯一真正的毀損路徑是「沒有 marker、紀錄存在但讀不到 → `unwrap_or(false)`」（rust/bridge/src/api/simple.rs:44-48），改成三態後，讀取錯誤 → Err → 不呼叫 firstRun |
| C-M1（`_install` 失敗後 RECORD_AES 還在、app 照常可用） | ✅ 消失 | firstRun 失敗仍刪全部（Keys.kt:188），`appUsable` 一定 false（main.dart:127-133、183）。main.dart:232「金鑰已全部刪除」的字仍然正確 |
| C-M2 / A-M1 / B-M3（清理規則測不到） | ✅ 不再需要 | 清理規則沒改 |
| D-M1 / B-M1（漏項） | ✅ 解決 | §1 表 49 列；我逐行比對 i329d.md 的 `- [ ]` 行號（84 … 222，共 49 個）與 §1 表的行號，**完全一致、沒有多也沒有少**。只剩合計那行的數字錯（m-1） |
| D-M3（ScanPage `_busy`） | ✅ 解決 | T20 用另一個旗標；`Lease.hold()` 是計數式（src/nodelink/lease.dart:60-70），掃描持有與讀取持有可以並存 |
| A-M2 / A-M3 / B-M2（T13） | ✅ 改成接受（N1），不打勾 | — |
| A-M4 / B-M5（T6） | ✅ 解決 | PermissionsPage、只有一顆實心 |
| B-M4（字級） | ✅ T8 (b) | — |

---

## 重點查證（T14）

1. **storeHasRecords 的呼叫者**：產品碼只有 main.dart:220。其餘是測試：simple.rs:103/105/119/124、claim.rs:605（都要改成 `.unwrap()`），以及 Dart 假物件 test/key_abilities_test.dart:76。
2. **FRB 簽名**：`Result<bool, String>` 在 Dart 端仍然是 `Future<bool>`，錯誤以 `String` 丟出。對照 `store_read_marker`：`Result<Option<String>, String>` → `Future<String?>`，`decodeErrorData: sse_decode_String`（lib/src/rust/frb_generated.dart:4098-4099）。所以 key_abilities_test.dart:76 的覆寫不會編譯失敗。`sayErr` 對 String 原樣顯示（lib/say.dart:138）。要重跑 codegen（frb_generated.rs/.dart 會變）。
3. **第一次安裝**：`records` 不存在 → `store_sweep` 回 0（batman-proto/src/store.rs:211 `let Ok(kinds) = … else { return Ok(0) }`）→ marker `File::open` NotFound → None（store.rs:86）→ 每個種類 `read_dir` 都是 NotFound → Ok(false) → firstRun。✅ 照常。
4. **還有沒有別的路徑能在紀錄存在時呼叫 firstRun**：Dart 端只有 main.dart:226；T-U2（device_check/t_u2_main.dart:52）在另一個套件，有 guard。`firstRun` 只在 `marker == None && !has_records` 時走到。marker 讀取錯誤會丟例外（store.rs:87）→ `_run` 的 catch（main.dart:153-164）→ 不呼叫 firstRun。✅ 沒有其他路徑。
5. **重試會不會無限循環**：不會自動循環。錯誤從 `_install` 丟出，現有 catch 設 `retry = true`；「再試一次」由使用者按（main.dart:306-311 → `_run()`）。錯誤一直存在時，使用者看到的是同一頁一直重試，**沒有下一步**（見 m-4）。
6. **「目錄不存在 vs 讀取錯誤」在 Android filesDir 上的意義**：見 m-2。重點是 `store_sweep` 在 `store_has_records` 之前跑，而且已經把「種類目錄 EACCES」擋下來了。所以計畫 §6 寫的「今天」那條毀損路徑，實際只剩比較窄的幾種觸發。

---

## MINOR

**m-1 §1 合計那行的數字錯。**
- 「做 19」後面括號裡只列了 17 項：87、88、92、105、106 半、110、112、113、114、125–129、199、220、222。
- 「勾 / 決定 10」只列了 9 項。
- 表本身 49 列是對的。修法：把數字改成和表一致，或寫成逐行加總。

**m-2 T14：§6 對「今天」的描述不準確；真正還沒擋住的觸發沒有測到。**

證據：`_install` 先跑 `storeSweep`（main.dart:213），sweep 會對每個種類目錄做 `fs::read_dir(k.path())?`（store.rs:216）。所以：
- 某個種類目錄 EACCES（例如權限 000）時，**今天就已經在 sweep 丟錯**，進到 catch，不會呼叫 firstRun。
- `records` 本身沒有搜尋權限時，marker 的 `File::open` 會丟 EACCES（store.rs:87），也已經擋下。

今天 `unwrap_or(false)` 真正會說錯的，只剩下面三種：
- (a) 種類路徑不是目錄：sweep 遇到非目錄就 `continue`（store.rs:213-214），但 has_records 的 `read_dir` 會回 ENOTDIR，結果被當成 false。
- (b) 迭代中途某一項出錯：sweep 用 `.flatten()`、has_records 用 `is_ok_and`，兩邊都把錯誤吞掉。
- (c) sweep 過了之後，has_records 自己那次 `read_dir` 遇到暫時性錯誤（EMFILE、ENOMEM、EIO）。

計畫的 Rust 負向對照（權限 000 的暫存目錄）在函式層級仍然有效，因為它直接呼叫 `store_has_records`。但它測的正好是系統層級已經被 sweep 擋下的那一種。

修法：
- §6 的「今天」改成上面這三種。
- Rust 測試加一條「`records/node` 是一般檔案 → Err」。這條確定會成功，用 root 跑、在 Windows 上跑都一樣（權限 000 在 root 或 Windows 下擋不住）。改回 `unwrap_or` → FAIL。
- 權限 000 那條保留，但要註明「只在非 root 的 Linux 才有意義」。CI 的 ubuntu-latest 用 `runner` 跑，這點成立。

**m-3 T14：迭代時遇到某一項出錯就直接回 Err，會讓「明明有紀錄」的手機也停用。**
- 如果寫成「遇到第一個出錯的項就回 Err」，那麼只要有一個壞掉的項排在有效紀錄前面，結果就是 Err，app 停用。其實這時回 true（不碰金鑰）是安全的。
- 修法：把整個目錄掃完。只要看到任何一個有效項就回 `Ok(true)`；只有沒找到有效項、而且途中出過錯時，才回 Err。測試的寫法可以照 `net_index.dart` 的 `listKind`（PathNotFound = 空，其他錯誤丟出）。

**m-4 T14：錯誤一直存在時，使用者沒有下一步，畫面上的字也還沒定。**
- 走現有 catch 的話，畫面是「啟動檢查失敗：<Rust 字串>」加上「再試一次」。因為 `_retry` 為 true，「請找維修人員」不會顯示（main.dart:277）。
- 如果錯誤一直存在（情形 (a)），使用者只會一直重試。最自然的自救是重新安裝或清除資料，而這兩個動作正好會把金鑰清掉。
- 修法：
  - Rust 的 Err 用和其他句子一樣的雙語格式（`中文\u{1E}english\u{1F}`），內容寫計畫說的「讀不到手機裡的紀錄，金鑰保持原樣」，再加上是哪個種類、哪種 io 錯誤。不要用 `{e:?}` 的原始輸出。
  - 這一種錯誤另外加一行：「仍然如此請找維修人員；不要重新安裝或清除 App 資料」。
  - Dart 測試斷言這兩行都有出現。

**m-5 T14 的 Dart「負向對照」不成立。**
- 現有的 `_run` catch 已經會攔下 `_install` 丟出的任何錯誤，而且不會呼叫 firstRun。現有的 `sweepError` / `markerError` 測試（key_abilities_test.dart:62-70）就是這條路。
- 所以「假 `storeHasRecords` 丟錯 → firstRun 沒被呼叫」這個測試在 main 上也會過。計畫寫的「拿掉分支 → FAIL」並沒有一個分支可以拿掉，除非真的加了專用分支。
- 修法：寫明這個修正的負向對照只在 Rust（改回 `unwrap_or` → FAIL），Dart 測試是回歸保護。若加了 m-4 的專用字句，負向對照就改成「拿掉專用字句 → FAIL」。

**m-6 T1 的 Dart 測試同樣不是負向對照。**
- prober 在 `openRecord` 出錯時已經呼叫 `keyCheck`（src/nodelink/prober.dart:206-212）。`keyErrorToRadio` 只看錯誤碼 `keyLevel`（app_link.dart:247-249；key_abilities.dart:96-97），沒有分是哪一種操作。
- 所以「假通道回 open 的 keyLevel → 2.4」在 main 上就會過。「拿掉 refusedBy 的 open」也找不到對應的程式碼。
- 真正的負向對照是 Kotlin 的 KeyHandlersTest，加上 lint。修法：改寫測試欄。

順帶確認，X26 確實認得這個錯誤碼：只要 Kotlin 的 open 走 `use(...)`，就會回 `Err("keyLevel", role, level)`（KeyHandlers.kt:96-102），Dart 端 `refusedBy` 會接到。✅

另外，只檢查 RECORD_AES 需要在 `KeyUses` 加 `level(role)`（目前只有 `levels()`，KeyHandlers.kt:15）。測試用的 fake 也要跟著加，計畫裡沒寫。

**m-7 #329:105 有一半沒有處理，卻被標成「做」。**
- i329d.md:105 有兩件事：
  - (1) 「X26 只認 keyLevel；其他 Keystore 錯誤顯示成連不到；金鑰前提變 false 後要重開 app 才恢復（D-4）」；
  - (2) 「open 不經閘門（F-m4）」。
- T1 只處理 (2)。
- 修法：§1 把 105 拆成「做（open 走閘門）＋ 接受（其他 Keystore 錯誤 = 連不到、要重開才恢復，附理由）」，不要整行打勾。

**m-8 #329:220 的原文是「firstRun 沒有防呆」，v3 刻意不加。**
- 關單時這一行要改寫，寫明三件事：
  - 修的是 `store_has_records` 的三態；
  - 「沒有 marker、沒有紀錄、金鑰還在 → 重產」是刻意保留的，理由是能從中斷中恢復，而且沒有資料依賴這些金鑰；
  - T-U2 有 guard。
- 否則使用者看到打勾，會以為 firstRun 已經加了防呆。

**m-9 #329:128 還有兩個子項沒寫去處。**
- 這一行除了「網路：」，還有「手機 Wi-Fi」，以及首頁「看我的申請」「加入隊長的網路」開到舊控制台。
- 我查到後兩項看起來已經由 PR 4 / 5 處理：節點頁有「手機 Wi-Fi」（ui/node_page.dart:191-197），「看我的申請」在 ui/net_pages.dart:490。
- §1 要附上這些證據，說明為什麼整行可以打勾。

**m-10 T3 原始碼鎖的比對方式。**
- 例外清單我逐一 grep 過，完整。lib/ 裡直接呼叫的只有 claim_records.dart:43/49/53、main.dart:213/228、app_link.dart:165-168、ui_state.dart:240/244。Rust 端所有會寫入的 bridge 函式也都在這組名字裡（claim.rs:83/87/134、owner.rs:70、simple.rs:51/60）。
- 但比對時要比「識別字」，不能只比「識別字加左括號」。app_link.dart:165-168 是在 lambda 裡呼叫，以後也可能有人用 tear-off（直接傳函式名）。
- 另外要把 `crateApiClaimStoreWrite…` / `crateApiOwnerStoreWriteCas` 這類直接呼叫生成碼的寫法也鎖住。
- `record_writer.dart` 本身沒有直接呼叫，列在例外裡沒有壞處，但理由要寫對。

**m-11 T8 / T20 的細節。**
- T8 (a)：一輪結束時，結論是 `Concl.queued` 的目標（這一輪根本沒輪到它，core.dart:602）不能算「讀過這一台」。測試要加一條：queued 的目標不增加。`NodeState` 只在 core.dart:125 / 269 用 `putIfAbsent` 建立，重讀紀錄不會被歸零，計畫的生命週期描述是對的。
- T8 (b)：「2.0 倍字級溢出 = FAIL」要照 §4 的方式，先在 main 上空跑一次，把 FAIL 數記下來，再決定範圍。否則可能一次冒出一大批既有畫板的溢出。
- T20：
  - `_start` 在租約已被收回時，`hold()` 會丟 StateError（lease.dart:61），要 catch 並顯示，不要變成沒人接的 Future 錯誤。
  - 重按「搜尋」只能持有一次。
  - 掃描的 stream `onError` / `onDone` 結束時也要放掉持有。
  - 測試加「搜尋兩次 → 交回後 `_busy` 歸零、租約可以釋放」。

**m-12 §4 對比方法與 §5 btsnoop 有兩個沒查證的前提。**
- §4：
  - Flutter 的元素只有在無障礙語意打開時，才會出現在 `uiautomator dump` 裡，⚠️ 沒查證。開場前先 dump 一次，確認文字節點有出來；只拿到一個 FlutterView 節點時，整項記 ❓。
  - 一個語意節點的 bounds 常常把圖示和文字一起包進去，細字也可能佔不到 2%。所以要再加兩條 ❓ 規則：「沒有任何顏色佔 ≥ 2%」記 ❓；「bounds 裡有圖示」記 ❓，或改用畫板座標裁切。
- §5：`settings put secure bluetooth_hci_log 1` 是舊的開法。Android 10 以後，開發者選項寫的是 `persist.bluetooth.btsnooplogmode`。照計畫的指令，S20（Android 13）很可能什麼都沒開，⚠️ 沒查證。
  - 修法：開場前唯讀 `getprop persist.bluetooth.btsnooplogmode`，記下原值；用能生效的方式開（`setprop` 是否允許，要先試）；在 bugreport 裡確認真的有 btsnoop 檔；最後還原成原值。
  - 副作用表要加一列：bugreport 含帳號、Wi-Fi 等個資，只留在 scratchpad，不進 repo，分析完就刪掉。

---

## 已查證、沒有問題的部分

- **T2**：MethodChannel 的 `result.success` 會同步編碼回覆，所以之後再 `fill(0)` 是安全的，和 ecdh 的 `keyCall(wipe = true)`（MainActivity.kt:85）前提相同。殘留的明文已經寫明，沒有誇大。
- **T1 只查 RECORD_AES**：
  - 會把 open 失敗當成「沒有」再覆寫的呼叫端有兩個：`ConsolePlatform.readRecord`（app_link.dart:199-207）和 `RecordUiStore`（ui_state.dart:227-231）。
  - 今天 RECORD_AES 不見時，open 就已經失敗（`getKey` 回 null → Cipher init 失敗）。T1 只是把錯誤碼從 `keystore` 改成 `keyLevel`。另外三把讀不到時，T1 也不會讓 open 失敗。所以 T1 沒有增加覆寫的觸發。
  - `Keys.open` 只有 MainActivity.kt:142 一個呼叫者，改成 private 是可行的。
- **T19**：`_app` 只在 `agree && appUsable` 時才會被指派，所以畫面上看得到舊啟動頁按鈕時，`_app` 一定是 null。main.dart:96-99 確實走不到。
- **T20**：子頁的 dispose 會先於 `RawLeaseScope` 的 dispose。`pageGone` 遇到 `_busy > 0` 時會等，`hold` 的 cancel 在計數歸零時才 release（lease.dart:64-82）。「取消完成才交回」照這個機制做得到。
- **T9**：`status_membership_line(1, …)` 回「已認領，還沒加入網路」（owner.rs:2593），排除 k1=1 是對的。
- **§5 副作用**：只用 `adb -s … install -r`；節點重開、情境 9 離開與加回都列了，也會在開場前問。
- **安全（逐 actor）**：
  - 本機無特權 app：碰不到別人 UID 的 filesDir 與 Keystore。
  - 遠端攻擊者、被攻破的節點：不經過這些路徑。
  - 我們自己的錯：T14 把「紀錄讀不到就重產金鑰」改成 fail-closed，失敗模式是停用加重試，資料留著。
  - T1 是 fail-closed。
  - 沒有新的攻擊面。

## 結論

**APPROVE-WITH-CHANGES**。前幾輪的 BLOCKER / MAJOR 都已經解決，v3 的 T14 在根源修，正確。12 個 MINOR 都是計畫文字、測試寫法和查證步驟，可以在實作時一起改，不需要整份再審一輪。其中 m-2 / m-3 / m-4 是 T14 的實作細節，請在寫 Rust 之前先定案。
