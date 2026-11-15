# #329 PR 2 第三輪審查 F（winson3QQ/Batman#340，feat/329-pr2 @ ca6d07d，疊在 PR 1 a0f3fbb 上）

審查者 F（獨立）。範圍：`git diff a0f3fbb ca6d07d` 整份（新 UI、main.dart 路由、UiState / cbor_mini、Kotlin 三個方法與圖示 / manifest、§3.4 Dart 與 Rust 字串、joinChoice 與舊控制台接線、所有新測試），外加第一、二輪每一項的關閉狀況。重點：安全與正確性、fail-open / fail-closed、每個測試能不能 FAIL。

## 結論

**APPROVE-WITH-CHANGES**：BLOCKER 0、MAJOR 0、MINOR 10。

第二輪的兩個 MAJOR（C-M1 第 6 列按鈕接線、D-M1 prober → core 的畫面資料）都關了，我的改壞對照 Mf、Mg、P4、O2、Ms 都 FAIL。UiState 的嚴格 CBOR、白名單、節點字串不入檔、移除先留副本、KeyGate、歡迎頁條件都有能 FAIL 的測試。找不到安全洞：沒有新的對外入口，Kotlin 三個方法只開系統設定頁 / 回版本字串；UiState 只寫種類與時間，節點字串只經 Rust `display_name` 後顯示。

剩下的都是 MINOR，但其中幾項是**第二輪宣稱修了、卻沒有負向對照**（MINOR-1、MINOR-2），有一項的修正前提根本不成立（MINOR-1）；PR body 仍是第一輪的內容（MINOR-7），合併前一定要更新。

## ✅ 我自己跑的（原始輸出）

副本：`scratchpad/core/pr2F`（`git archive ca6d07d app tests` + package_config）。

- 全套：`flutter test --no-pub` → `00:21 +672: All tests passed!`
- Rust（WSL Ubuntu-24.04，自己的 CARGO_TARGET_DIR）：batman-proto 20 個 test result 全 ok，合計 270 passed、0 failed；bridge `test result: ok. 63 passed; 0 failed`，含 `t_u4_ui_is_not_a_record ... ok`。
- T-U4 負向對照：把 `"ui"` 加進 `RECORD_KINDS` → `t_u4_ui_is_not_a_record ... FAILED`（已還原）。

### 改壞對照（每個只改一處、跑全套或指定檔、跑完還原；log 在 `pr2F/out/`）

| # | 改壞 | 結果 |
|---|---|---|
| Ma | `RecordUiStore._header` 永遠 false | **SURVIVED** `+672` |
| Mb | 拿掉 `RecordUiStore.write` 的 generation 檢查 | **SURVIVED** `+672` |
| Mc | 歡迎頁條件拿掉「沒有節點紀錄」 | KILLED `+668 -4`（T-U3） |
| Md | 歡迎頁 `onDone` 不呼叫 `ui.setWelcomed()` | **SURVIVED** `+672` |
| Me | `_todos` 的 catch 改回 `NetRecords.none` | **SURVIVED** `+672` |
| Mf | `NetRecords.unknown` → 建立網路 | KILLED `+671 -1` |
| Mg | prober 的 2' 不帶畫面資料 | KILLED（prober_test） |
| Mh | 拿掉 node_link 的「2' 也記 readWall」 | **SURVIVED** `+672` |
| Mi / Mj / Mk | cbor 深度 4→40 / 不查尾端多餘位元組 / 不查重複鍵 | 全 KILLED |
| Ml | 狀態區時間改回「全部最新的那次」 | **SURVIVED** `+672` |
| Mm | 拿掉「新鮮但沒有畫面資料」那一列 | KILLED |
| Mo | 首頁不呼叫 `_remember` | KILLED `-2` |
| Mp | 首頁提示不限第 14 列 | KILLED `-11` |
| Mq | 「跳過說明」按了不做事 | **SURVIVED** `+672` |
| Ms | 舊控制台「加入網路」直接接 `_joinNetwork` | KILLED `-3` |
| Mt | 首頁不在 paused / hidden 呼叫 `ui.background()` | **SURVIVED** `+672` |
| Mu | 權限頁同意後不呼叫 `a.link.radio(permission: true)` | **SURVIVED** `+672` |
| Mv | 2.4 頁不給「再試一次」 | KILLED `-6` |
| Mw | 節點頁不顯示 `whyNext` | KILLED |
| Mx | 首頁 `firstRounds` 永遠 false | **SURVIVED** `+672` |
| My | 開發者選項不看 devTrust | KILLED |
| Mz | 移除失敗也 `ui.forget` | KILLED |
| N1 / N2 / N3 | 第 5 列關掉 / 紅色也算不新鮮的 / 讀取時間不轉 UTC | 全 KILLED |
| O1 | `JoinChoice.own` 接到 `_memberJoin` | **SURVIVED** `+680`（當時副本多 8 個我的探針測試） |
| O2 | 選單兩個選項對調 | KILLED |
| P1 / P2 / P4 | 第 11 列移到第 10 列前 / 黃不看 warning / mpend → 加入網路 | 全 KILLED |
| P3 | 第 8 列只算 `notFound`（`refused` 掉到第 10 列） | **SURVIVED** 全套 `+672` |
| P5 | `refused` 的節點列改成「手機連不到」 | **SURVIVED** `+672` |
| R1 | Rust `JoinButton::Admin` 改回「加入網路／繼續加入」 | KILLED（wording_test T-C4b） |

### 探針（T-C2 沒渲染的狀態；只在我的副本，跑完已刪）

360×640、字級 2.0、淺 / 深：歡迎頁第 3 頁、權限被拒後（橫幅 + 兩顆按鈕）、移除確認對話框、第 7 列 64 字紅色句子 → `00:01 +8: All tests passed!`（不溢出、`androidTapTargetGuideline`、`textContrastGuideline` 都過）。所以第二輪 C-m10 / D-m10 擔心的這四種畫面**實際沒問題**，只是 PR 沒有測試鎖住。

## ⚠️ 只讀碼推論、沒實測

- Mu 存活的後果：flutter_reactive_ble 的 `statusStream` 在使用者同意權限後是否會自己送出新狀態，我沒在真機確認；如果不會，拿掉那一行後首頁會停在「app 還沒有藍牙權限」。現在的程式有那一行，行為是對的，缺的是測試。
- 啟動畫面（1.1）、2.4 金鑰不足頁、節點頁技術資訊展開在 2.0 倍字級的版面，沒渲染。
- Kotlin `bluetoothSettings` / `appSettings` / `appVersion` 沒在真機或 Robolectric 跑過，只讀碼（MainActivity.kt diff）。

## ❌ 沒做

- 沒上真機、沒 adb（brief 禁止）。
- 沒審 PR 1 的 NodeLink / BleGate / lease 本身（只看 PR 2 的用法：`released` 會重讀紀錄，node_link.dart:172-193，移除後首頁那一列會消失，靠讀碼）。

## 第一、二輪項目的關閉狀況（只列這輪還有話要說的）

| 項目 | 狀態 | 證據 |
|---|---|---|
| C-M1 第 6 列接線 | 關 | pages_test:147-173；Mf、P4 KILLED |
| D-M1 畫面資料 prober → core | 關 | two_prime_test、prober_test；Mg KILLED |
| D-m1 暱稱過濾 | 關（Cc、Cf、Zl、Zp） | ui_state_test:161-176 |
| D-m4 開發者選項 devTrust | 關 | My KILLED |
| D-m6 2' 自己的讀取時間 | 程式改了，**沒測試** | Mh SURVIVED → MINOR-2 |
| D-m9 列紀錄失敗 → 中性按鈕 | **修正前提不成立、沒測試** | MINOR-1 |
| D-m12 / O1 自己網路的加入 | **仍沒測試**（第二次） | O1 SURVIVED → MINOR-2 |
| C-m2 歡迎頁旗標寫入 | **仍沒測試**（第二次） | Md、Mq SURVIVED → MINOR-2 |
| C-m8 狀態區時間 | 程式改了，**沒測試** | Ml SURVIVED → MINOR-2 |
| C-MINOR-3 / D-m2 `RecordUiStore` | **仍沒測試**（第三次） | Ma、Mb SURVIVED → MINOR-3 |
| C-MINOR-4 / D-m3「只流向顯示」 | T-U6(b) 做了（pages_test:221）；「只流向顯示」仍沒測試 | MINOR-3 |
| C-MINOR-5、C-MINOR-7 / D-m8、C-MINOR-9 / D-m7、D-m5 | **沒改、也沒寫進「和設計不同」** | MINOR-4 |
| C-MINOR-10 / D-m10 T-C2 | 四種畫面我渲染過是好的；啟動畫面、2.4 仍沒測試 | MINOR-5 |
| C-MINOR-11 / D-m11 PR body | **沒更新** | MINOR-7 |

## MINOR

**MINOR-1　D-m9 的修正實際上不會發生，而且沒有負向對照。** ca6d07d 的說明是「network records that cannot be read give the neutral 加入網路」，程式是 `home_page.dart:137-139` 的 `catch (_) { recs = NetRecords.unknown; }`。但 Rust 的 `list_kind`（owner.rs:41-47）、`list_mnets` / `list_pends`（member.rs:331-346）都是 `read_dir(...).unwrap_or_default()`，讀目錄失敗會回空清單、**不丟例外**，所以 Dart 收到的是「沒有紀錄」→ `NetRecords.none` →「建立網路」+「加入隊長的網路」。D-m9 指出的情況（`read_dir` 失敗）完全沒被擋住，只擋住 FFI 本身壞掉。Me（catch 改回 none）SURVIVED，證明沒有測試。影響只在按鈕文字（四顆按鈕都開同一個舊控制台），所以 MINOR；但 commit 說明宣稱了沒做到的事，要更正紀錄。修法：要嘛 Rust 回 `Result`（目錄不存在 = 空，其他錯誤 = Err）、Dart 照現在的 catch；要嘛把 commit / PR 說明改成「只擋 FFI 錯誤」。補一個 `crateApiOwnerListNets` 丟例外 → 「加入網路」的 widget 測試，附 Me 的 FAIL。

**MINOR-2　第二輪的幾個修正與幾條接線沒有負向對照（全部 SURVIVED，見上表）。**
- Mh：2' 自己的讀取時間（D-m6）。
- Ml：狀態區只顯示該台、而且新鮮的時間（C-m8）。
- Md、Mq：歡迎頁「開始 / 跳過說明」寫旗標（C-m2 第二次提出）。拿掉後，沒有節點的使用者每次開 app 都看到歡迎頁；「跳過說明」壞掉則按了沒反應。
- O1：舊控制台「加入網路」只有 net 紀錄時走 `_joinNetwork`（D-m12 第二次提出）：隊長把自己的節點加進自己的網路，是最常見的路徑。
- Mt：進背景時寫一次（§4.6「什麼時候寫」第三項）。純函式有測，首頁的接線沒有。
- Mu：權限頁同意後通知 NodeLink。
- Mx：首頁的 `firstRounds` 接線（純函式有測）。
- P3、P5：`Why.refused`（節點被重設或交給別人）走第 8 列、節點列寫「不接受這支手機的登入」。

修法：各補一個 widget / 純函式測試，附各自的改壞 → FAIL。

**MINOR-3　`RecordUiStore` 仍完全沒有測試（第三次提出）；「UiState 只流向顯示」仍沒有測試。** Ma（`_header` 永遠 false）、Mb（拿掉 `generation != expectedGen + 1`）全綠。`_header` 靠 `'$e'.contains('NotARecord')` 判斷字串（ui_state.dart:310），Rust 錯誤字串一改，長度 0 的檔就會變成「每次寫入都失敗」。我用 grep 確認 UiState 的值現在只到 `name`、`prev`、歡迎頁路由、提示卡（main.dart:177、home_page.dart:34、:259、home_logic.dart:153），沒有任何決定讀它，所以只是 MINOR。修法：`RustLib.initMock` 對 `RecordUiStore` 跑 T-U2 (a)(b)。

**MINOR-4　第二輪的幾項沒改，也沒寫進「和設計不同」。** 節點頁對「還沒加入網路」和藍牙 / 權限沒有下一步按鈕，`whyNext(noPermission)` 叫人「回首頁按『允許藍牙權限』」（C-MINOR-5，§3.4 規則 3）；第 7、8 列多台時沒有「捲到節點清單」（C-MINOR-7 / D-m8）；`firstRounds = roundsRun < 3` 在第 2 輪結束到第 3 輪開始之間（首頁 60 s）仍算頭兩輪（core.dart:334 在一輪開始時 +1；C-MINOR-9 / D-m7）；Rust 句子叫人「對照下面『網路：』的名稱」，新節點頁沒有那一行，第 6 列「看我的申請」「加入隊長的網路」打開的舊控制台沒有同名按鈕（D-m5）。另外第 6 列四顆按鈕在**非 devTrust 版本**也打開舊控制台（home_page.dart:166-168，只寫在程式註解）；舊控制台的危險入口自己有 `DevOnlyButton` 擋（nodes.dart:1743-1750），不是安全問題，但 §5.8 說舊控制台只在開發者選項，PR body 要寫出來。修法：改，或逐項寫進「和設計不同」與 #329 checklist。

**MINOR-5　T-C2 仍有畫面沒鎖住。** 我渲染了歡迎頁第 3 頁、權限被拒後、移除對話框、第 7 列 64 字紅色句子（360×640 ×2.0 淺 / 深，8 個全過），所以版面現在是好的；但 PR 的 T-C2 沒有這些，啟動畫面、2.4 金鑰不足頁、節點頁技術資訊展開也沒有。修法：把這些加進 `layout_test` 的 `pages`（互動後的狀態用 setup callback）。

**MINOR-6　節點列對「連不到 / 被拒」的時間用「讀取於」。** `nodeRowWords` 的 `why` 分支回 `meta = '讀取於 HH:MM　後四碼 …'`（home_logic.dart:159-169），而那次讀取已經不新鮮；節點頁的 `time` 也照樣顯示（node_page.dart:114）。T2 / §4.6 對舊資料用「上次讀取」。修法：`fresh` 為 false 時用「上次讀取」。

**MINOR-7　PR body 仍是第一輪的內容（第二輪兩位都提過）。** 仍寫 `d3b5d38`、`570 passed`、T-C2「8 頁 108 passed」（現在 14 頁 168 個）、「『管理者金鑰』『成員金鑰』保留」（現在是「隊員金鑰」）、joinChoice「照 T-N2：net 優先」（現在兩者都有時會問）、「『開啟 app 設定』按鈕沒有做」（intro_pages.dart:157 做了，Kotlin `appSettings`）；沒有第二、三輪修正的負向對照輸出。全域規則：PR body 要有實際輸出。**合併前一定要改。**

**MINOR-8　解析器收空白或空字串的暱稱。** `ui_state.dart:198` 只查長度上限與不安全字元；`''` 或 `'   '` 會成為節點名稱，首頁寫「：句子」、節點頁標題是空的。只有「我們自己的錯」這個 actor 寫得出來（PR 2 沒有寫暱稱的入口），所以 MINOR。修法：`nick.trim().isEmpty` 當成沒有暱稱（或當成內文壞）；PR 4 的寫入端用同一個檢查。

**MINOR-9　`JoinChoice.none` 對「只有 mpend」的手機說錯下一步。** nodes.dart `_join` 的 none 分支寫「請按『建立網路』，或向隊長要邀請」；只有 `mpend` 的隊員手機已經送出申請，該做的是「再顯示申請」或貼上同意。修法：none 時多看一次 `listPends`，有就改說「你的加入申請還在等隊長同意」。

**MINOR-10　S10 的 BLE 位址沒有搬到「技術資訊」，而是只進 logcat。** claim.dart 現在 `_log('found $id')`（`_log` = `debugPrint`，claim.dart:27），主畫面只剩「找到節點，後四碼 XXXX」。§3.4 S10 寫「BLE 位址搬到技術資訊」。認領頁在 PR 3 會被取代，影響很小；寫進「和設計不同」即可。

## 依角色的安全檢查

| 角色 | 檢查 | 結果 |
|---|---|---|
| 遠端 / 附近的假節點 | 新畫面顯示的節點字串：第 7、12、13 列的 `sentence` / `warning` 是 Rust 固定句子；節點頁技術資訊的 `version`、`tech` 經 `display_name` + 64 字（owner.rs:363-364 註解、`shown`，statuspage.rs:188）；`net_id` 只收 16 位元組轉 hex（owner.rs:2212） | 沒有未過濾的節點字串上畫面 |
| 假節點 → UiState | `noteReads` 只收四種種類與手機自己的時間，id 來自紀錄檔名；T-U6(b) 用標記字串搜尋位元組（pages_test:221-245），Mo KILLED | 沒有節點內容進 `ui/state-v1` |
| 本機其他 app | 新增的只有 MethodChannel 方法（不對外）、圖示、`screenOrientation`；沒有新的 exported 元件、intent filter 或 provider | 攻擊面沒變 |
| 壞掉 / 惡意的 `ui/state-v1` | cbor_mini：型別白名單、長度先比剩餘位元組（:78、:84）、深度 ≤ 4、重複鍵、尾端位元組、8 位元組整數溢位成負數被擋（:65）；`_parse` 只丟 `FormatException`，`load()` 另有通用 catch；時間限 1970–2100、暱稱限字元 | 不會讓 app 當掉；最多顯示空白暱稱（MINOR-8） |
| 我們自己的錯 | UiState 只寫 `ui/state-v1`、不需要佔用；`ui` 不在 `RECORD_KINDS`（T-U4 有負向對照）；移除先 `keepCopy`、失敗不刪（Mz KILLED、T-N1 copyOk=false） | 正確 |
| fail-open / fail-closed | UiState 讀不到 → 預設值（只影響顯示，理由成立）；KeyGate 灰掉入口、`_addNode` 在 `!keys.claim` 時不開認領頁（fail-closed，C-m6 測試）；列紀錄失敗 → 實際上是「建立網路」（MINOR-1） | 只有 MINOR-1 和宣稱不符 |

## 對 PR body「和設計不同」的判斷

| 項目 | 判斷 |
|---|---|
| T-N2 vs S3 | **接受現在的四態**（只有 net → 自己的網路；只有 mnet → 隊員；兩者都有 → 問；都沒有 → 說怎麼開始）。兩者都有時讓使用者選，比 S3 的「有 mnet → 隊員」安全，不會默默走錯網路。但 PR body 寫的「net 優先」是錯的（MINOR-7），設計回填時照四態寫，none 的句子見 MINOR-9 |
| T-C4a 的 Rust 一半改成掃原始碼 | 接受：R1 證明掃描能 FAIL；註解行跳過的規則合理 |
| T-C2 的 36 dp 負向對照、按鈕 `shrinkWrap` | 接受 |
| 延後的項目（網路摘要、10.5、暱稱編輯、T-C4c、T-H2/3/5 完整版） | 接受；MINOR-4 的幾項要補進這一段 |
| 「開啟 app 設定」沒做 | 已過時：做了（MINOR-7） |

## 檔案

- 本報告：`C:/src/Batman-329/docs/design/329-reviews/review-pr2-r3-F.md`
- 改壞對照的 diff 與 log：`scratchpad/core/pr2F/out/*.diff`、`*.log`；腳本 `scratchpad/core/pr2F/mut.sh`
