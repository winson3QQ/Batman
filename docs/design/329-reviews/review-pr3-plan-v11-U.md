# #329 PR 3 實作計畫 v11 審查（審查者 U，獨立）

對象：`docs/design/329-pr3-plan.md` v11 @ 4dd3563。範圍照指示：(1) v10 審查 S、T 每一項在 v11 是否修好；(2) v11 自己的改動（§2.2 `close()` 上限、§2.4 全部 pending 的次要建立與節點頁規則、§2.5 hold / pageGone / release 與自動檢查重新登入、§2.6 佔用中重讀單筆、§2.8 `nodeDacHash` / `[NET_STATE]` / 重讀判升級 / 停止規則 / 借用頁交出建立、§3.1 / §3.2、D6、§6、§7、§8）有沒有新的洞；(3) 從現場情境出發。join2 與舊控制台（nodes.dart、owner.rs、netrec.rs、flow.rs）是基準，疑問放「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 0 MAJOR / 4 MINOR / 2 nit）

v10 的兩個 MAJOR（S-M1、T-M1）都照建議修好，對到原始碼也成立：確認請求的每一條「沒拿到回答」路徑都以 `[REQ_FAIL]` 結束，只有節點真的回答時才是 `[NET_STATE]`；`nodeDacHash()` 登入後一定有值，`MemberView.creator` 只在 pending 時成立。剩下的都是寫法要再精確一點：`[NET_STATE]` 要用「開頭是」判斷（節點能把字串塞進錯誤句子中間）、檢查網路頁與自動檢查在交出連線前要先 `close()`、結果頁「再試這一台」對建立那一列沒有定義。都不需要新機制。

---

## 1. v10 發現的對應

| 發現 | 結果 | v11 位置 | 證據 |
|---|---|---|---|
| S-M1 「升級」「拿到回答」沒定義；`NetIndex` 佔用中不算 | ✅（附 U-m1） | §2.8:129-130、§2.6:107 | 升級 = 佔用下重讀那一筆的 `applied`，不看 `NetIndex` ✅。回答 = `[NET_STATE]`：owner.rs:484-491 `confirm_text` 四種都帶 `[NET_STATE]`；`Upgraded` 先給 `PersistNet`（owner.rs:886-889），寫好後 `net_persisted` 才回 `[NET_STATE]` 句子（owner.rs:1107-1114），寫入失敗 `persist_failed` 回 `[REQ_FAIL]`（owner.rs:1154）；netrec 壞掉回 `[REQ_FAIL]`（owner.rs:892）；節點錯誤碼走 `error_text` = `[REQ_FAIL]`（owner.rs:645-649、:963-966）。Dart 端確認呼叫不帶 `unclear`（nodes.dart:1244），所以逾時 = `_waitLine` `[REQ_FAIL]`（nodes.dart:498、:527 附近）、沒連線 = `askNoLink` `[REQ_FAIL]`（member_ui.dart:257）、Rust 結束 = `endedLine` 補 `[REQ_FAIL]`（member_ui.dart:283）、Rust 拒絕 = `'[REQ_FAIL] 操作沒有成功'`（nodes.dart:583）。S-M1 第 3 點（`InProgress` / `Unknown` 算回答、給建立 = 舊控制台基準）規則已隱含決定，但沒寫出、沒測試 → 併入 U-m1 |
| S-m1 精確比對不需新函式 | ✅ | §2.8:125 | owner.rs:993-994 `node_dac_hash` = `hex_lower(dac_hash(dac_pub))`；登入成功時 `self.node = login.verified()`（owner.rs:1671），`verified()` 在 msg2 驗證後才有值（loginflow.rs:84-88）→ 登入後非空。`MemberView.dac_hash` 同一個 `hex_lower` 格式、`creator = pending_creator() == dac_pub_hash`（owner.rs:106-120），`pending_creator` 只在 pending 時回值（netrec.rs:406-412）→「這台是哪幾筆的建立者」天然只含 pending ✅ |
| S-m2 節點頁「同第 6 列」會給建立 | ✅（nit U-n1） | §2.4:78 | 改成「手機有 net 才給加入、從不給建立」，和設計 :312（S7「建立網路（首頁、3.5、3.6）」）、:755 一致；但設計 :758「主要按鈕照 §5.1 第 6 列」字面上在零筆 net 時會是建立 → U-n1 |
| S-m3 只有 pending、建立者回不來是死路 | ✅ | §2.4:77、D6、§7、§8 | 由 T-M1 的修法解掉（4.1 全部 pending → 次要建立） |
| S-m4 自動檢查斷線 | ✅（附 U-m3） | §2.5:96 | session 在 → 直接確認；`NOT_LOGGED_IN`（owner.rs:1174-1176）/ 斷線 → 再 `loginFor` 一次；沒 `PersistNet` 不檢查（反向測試）。重新登入前要先關掉舊連線沒寫 → U-m3 |
| S-m5 `NetIndex` 讀不到沒出路 | ✅（nit） | §2.4:75 | 「再試一次」重算 ✅；§2.6:107 的重算時機清單沒加這個觸發點（只是一致性） |
| S-m6 `close()` / 生命週期 / 交接順序 | ⚠️ 部分 | §2.2:57、§2.8:135-137、§3.2:166-173 | `close()` 等處理者、上限 10 s ✅；檢查網路頁分列 T-R1(a)–(e) ✅；借用頁按建立的順序 ✅。S-m6 第二點「借用頁返回前要先 `close()` 自己的 `OwnerConsole`，否則結果頁再試會撞到還開著的連線」沒寫 → U-m2 |
| T-M1 pending 建立者壞掉時沒有建立出口 | ✅ | §2.4:77、D6、§6 第 5 步、§7 | 4.1 選到 pending 且全部 pending → 次要「建立網路」；有已建立的 net → 沒有。測試兩條都列了 |
| T-m1 佔用規則寫清楚 | ✅（nit U-n2） | §2.5:87-92、§2.8:121-123、§3.1:145 | 對 lease.dart 核過：進結果頁放 hold 時 `_gone == false` → 不釋放（lease.dart:64-69）✅；離開結果頁 `pageGone()` 且 `_busy == 0` → 立刻 `release()`（:73-79）✅；中途消失先 `pageGone()` 再放 hold → hold 的取消函式在 `_gone` 時 `release()`（:68）✅；借用頁不呼叫 `pageGone` / `release` ✅；`release()` 的本體沒有 `await` 之前就呼叫 `reg._release`，同步生效（:85-90）✅。「頁面 dispose 在退場動畫之後」的時序見 U-n2 |
| T-m2 自動檢查在拔電時 session 已不在 | ✅ | §2.5:95-96 | 同 S-m4；反向測試「沒有 `PersistNet` → 不自動檢查」✅ |
| T-m3 用 `nodeDacHash` | ✅ | §2.8:125-126 | 同 S-m1；不是建立者 → 不送確認、不給建立 ✅ |
| T-m4 acquire 回來頁面已不在 | ✅ | §2.5:88、§2.8:122、§6 | 迴圈與檢查網路頁寫了；「放棄這次加入」寫「寫完就放」，沒有 `mounted` 早退，方向對；§6 的測試是通用的一條 |
| T-m5 檢查網路頁生命週期 | ✅ | §3.2:169-173 | |
| T-m6 升級判斷、寫入失敗、`close()` 上限 | ✅ | §2.8:129-130、§2.2:57 | 寫入失敗 = `[REQ_FAIL]` → 停、不給建立 ✅；§6 有「升級後寫入失敗 → 停、沒有建立」 |

---

## 2. MINOR

### U-m1　`[NET_STATE]` 的判斷要寫成「確認請求本身的回答、而且字串開頭是」；寫成「含有」時，被入侵的節點可以讓頁面給出「建立網路」

- **情境（被入侵的節點）**：使用者在檢查網路頁對 04 檢查兩筆 pending。04 是被入侵的節點，對 `info` 回錯誤碼並把 detail key 1 填成文字 `[NET_STATE] x`。Rust 的 `error_text` 把這段節點給的文字放進句子中間：`[REQ_FAIL] …沒有成功：…（代碼 n，[NET_STATE] x）`（owner.rs:648-649 `verb` 取自 `detail.get(1)`）。實作若用 `contains('[NET_STATE]')` 判斷「拿到回答」，這筆就算「拿到回答、沒升級」→ 每筆都這樣 → 次要「建立網路」出現。這正是 S-M1 要擋的結果（只是由節點觸發）。
- **另兩個同名標籤**：
  - 舊控制台的建立結果不明句子 `_makeUnclear = '[NET_STATE] 結果不明…'`（nodes.dart:50）也帶 `[NET_STATE]`。§2.8 只對 `confirmNetwork` 的回答判斷，所以碰不到；但和 P8 對 `[JOINED]` 的寫法一樣，要寫明「只看確認請求本身的回答」，免得實作把判斷函式也用在建立的回答上。
  - owner.rs:883 `[NET_STATE] 這次連線還沒有建立過網路` 不是節點的回答（`self.confirm` 已被拿走時才出現）。`requestConfirmNetwork` 在送出前一定會設 `self.confirm`（owner.rs:1176），所以照現在的程式碰不到 ⚠️（推論，沒有跑）。
- **S-M1 第 3 點的基準**：`InProgress` / `Unknown`（owner.rs:477、:480「請一分鐘後 / 稍後再按『檢查網路』」）是 `[NET_STATE]` → 算拿到回答 → 若手機沒有已建立的 net，就和「再檢查一次」一起給次要「建立網路」。這和舊控制台一樣（一直給），是基準；v11 的規則已經這樣決定，但文字沒說，測試也沒有。寫一句並加一條測試，免得實作者自己加「`InProgress` 不給」之類的分類（§0 說不重新分類）。
- **修法（一句話，不加機制）**：§2.8「拿到回答」改成「`confirmNetwork` 這一步的回答句子**以** `[NET_STATE] ` **開頭**」。§6 加三條測試，各附改壞：(a) 錯誤句子中間含 `[NET_STATE]` → 不算回答、沒有「建立網路」（改壞 = `contains` → FAIL）；(b) `InProgress` → 有「再檢查一次」+ 次要「建立網路」（基準，鎖住行為）；(c) 判斷函式不吃建立的回答（`_makeUnclear` 的複製句子 → 不算）。

### U-m2　檢查網路頁在工作結束時就要 `await close()` 自己的 `OwnerConsole`，不要等到 dispose（S-m6 第二點沒寫到）

- **情境**：結果頁 →「檢查網路」（借用）→ 04 確認完（每筆都回答、沒有升級）→ 頁面顯示結果 → 使用者按返回 → 結果頁立刻按 02 的「再試這一台」→ `loginFor` → `gate.connect` → `_links` 不是空的 → `Refused('a link is already open')`（ble_gate.dart:217-221）。`GateLink.close()` 要等系統回報斷線或 5 s 才從 `_links` 拿掉（ble_gate.dart:108-129）。就算 dispose 有呼叫 `close()`，它是非同步的，結果頁的下一個動作可能先到。自己拿佔用的檢查網路頁也一樣，只是之後的動作要先等 `released`，碰到的機會小。
- **證據**：§2.8 只在「按建立網路」時寫了 `close()` → pop（:136-137）；「結果」那一段（:131-134）與返回（:124、§3.2 T-R1(b)）都沒寫什麼時候關連線。§2.5:90 迴圈是「進結果頁 = `close()`」，檢查網路頁沒有對應的一句。
- **修法**：§2.8 加一句「每次檢查結束（升級停、整頁停、全部檢查完）先 `await close()`，然後才顯示結果與按鈕；『再檢查一次』重新 `loginFor`」。這樣返回時已經沒有連線。T-M1(h) 改成用會記連線數的假 `BleGate`，斷言返回時 `_links` 是空的、結果頁再試的 `connect` 沒被拒（改壞 = 只在 dispose 關 → FAIL）。

### U-m3　自動檢查的「再 `loginFor` 一次」前要先 `await close()` 第一個 `OwnerConsole`

- **情境**：建立 04 時 `ask` 等到 360 s 逾時（節點在處理、BLE 連線還在）→ 舊控制台的做法是結果不明時 `_drop()` 這個 session（nodes.dart:571）。新的 `OwnerConsole` 若照抄，session 已不能用；§2.5:96 接著「再 `loginFor` 一次」。如果第一個 console 的連線還沒關完，`gate.connect` 會被拒（ble_gate.dart:217-221），`loginFor` 失敗 → 整個流程停，結果頁給「檢查網路」。不會造成錯誤的狀態，但自動檢查白做，§7 的 A18 真機觀察也會被這個時序影響。
- **修法**：§2.5:96 寫成「`NOT_LOGGED_IN` 或連線已斷 → `await close()` 這個 console → `loginFor`」，和 §2.5:93「上一台 `close()` 完成 → `loginFor`」同一條規則。§6 的「自動檢查遇到 `NOT_LOGGED_IN` → 重新 `loginFor` 一次」測試用同一個假 `BleGate` 斷言第二次 `connect` 沒被拒。

### U-m4　結果頁「再試這一台」對建立那一列沒有定義；再試的等待規則也沒寫

- **情境 A（建立那一列）**：0→2 台，04 建立途中拔電 → 有 `rel`、重讀 pending → 自動檢查：04 還在開機，`loginFor` 60 s 失敗 → 整個流程停（§2.5:96）。結果頁 04 那一列：§2.8 / §2.5:96 說給「檢查網路」；§2.5:102 又說結果頁每一列有「再試這一台」。如果建立那一列也有「再試這一台」，而它的意思是「再 `makeNetwork` 一次」——04 開機後其實已經套用了 A（§7 要測的「已套用」那種），使用者按再試 → 在 04 上又建一個 B（owner.rs:1067-1089 建立不看既有紀錄），A 變成永遠清不掉的 pending（§8 已知限制）。這等於在 v10 / v11 費力收緊的「建立網路」條件旁邊開了一個沒條件的建立按鈕（Q-M2 的同類）。
- **情境 B（判斷用的資料過期）**：§2.8:133 檢查網路頁的「手機沒有任何已建立的 net」在佔用中只能看 `NetIndex`（佔用期間不重算，§2.6:107）。若同一個佔用裡已經用「再試這一台」建好了一個網路，`NetIndex` 還說「沒有」→ 檢查舊的 pending 時又給「建立網路」。
- **情境 C（再試的等待）**：「再試這一台」= 登入 60 s + 加入 360 s + 連線檢查 120 s，和迴圈的一台一樣長；§2.5:102 只寫了 hold，沒寫 `PopScope` / `keepScreenOn` / 頁面消失時「做完當前請求就停」。設計 :576 的 420 s 上限只蓋單一請求，多個請求的等待頁要擋返回；不擋的話，返回後連線檢查會超過 420 s → 被收回 → 首頁出現假的「上一個操作可能沒有存完」（lease.dart:80-82、:144）。
- **修法（都照現有規則，不加機制）**：
  1. §2.5 結果頁：建立那一列**有 `rel`** → 只有「檢查網路」，沒有「再試這一台」；**沒有 `rel`**（沒寫任何紀錄）→「再試這一台」= 在這台重新建立，然後照建立模式繼續（這時沒有 pending，和第一次一樣）。加入的列照 D5。
  2. §2.8:133「手機沒有已建立的 net」在佔用中用和 §2.4:80「按開始時重新列檔」同一個讀法，不看 `NetIndex`。
  3. 「再試這一台」執行時照迴圈的等待規則（`PopScope`、`keepScreenOn`、頁面消失 → 當前請求做完就停）；§3.1 的 `keepScreenOn` 寫入者加上它（仍是同一個頁面、同一個佔用，不重疊）。
  4. 測試（各附改壞）：建立列有 `rel` → 沒有「再試這一台」；同一個佔用裡已建立一個網路 → 檢查網路頁沒有「建立網路」；再試中返回被擋。

---

## 3. nit

- **U-n1**　節點頁零筆 net：v11 選「不給建立」，和設計 :312、:755 一致，但 :758「主要按鈕照 §5.1 第 6 列」字面上是「建立網路」。D6 把它寫成「設計已定」，請在 §4 記一句「照 :312 / :755，不照 :758 的字面」，免得之後的審查再問一次。
- **U-n2**　「pop → 開 4.1」：佔用在頁面 **dispose** 時才交回（設計 :577，退場動畫期間頁面還在），而 `Navigator.pop` 的值在 pop 當下就交給下面那一頁。所以下面那一頁一拿到「去建立」就開 4.1，在動畫結束前 4.1 按「開始」會被拒（「另一個操作還在進行」）。使用者要先填名稱才按開始，實際上幾乎碰不到；被拒時再按一次就好（`acquire` 失敗的提示是現有的）。T-M1(i) 在 `pumpAndSettle` 下會通過，看不到這個時序。寫一句即可，不必改設計。
- 另外：§2.6:107 寫「`readRecords` 的那一筆 + 解密取 `applied`」——`AppLink.readRecords` 只列 `node/` 的 id 與檔案時間（app_link.dart:72-85），沒有 net 紀錄。實際可用的讀法是現成的：`storeReadSealed(dir, 'net/<id>')` + Kotlin `open` + `netSummary`（同 nodes.dart:738-746 `_readRecord`、:597-600 `_pickNet`），讀不需要佔用；確認請求要的 `recordGen` 也取自同一次讀。請改名稱，免得實作者去改 `NodeLink` 的 `readRecords`（D4：`NodeLink` 不碰 Keystore）。

---

## 4. v11 新改動的其他檢查（沒有發現）

- **§2.2 `close()` 上限 10 s**：超過後還在跑的 `writeCas` 可能在佔用釋放後才落地。`RecordWriter._check` 是在呼叫 store 之前檢查（record_writer.dart:39-44），所以已開始的那一筆會寫完；CAS 的 generation 擋住覆寫別人的更新；`NetIndex` 在 `released` 時算的那一次可能看到舊值，下一次重算就對。§6「慢的 `writeCas` + 逾時 → 不會在 dispose 後呼叫 `netPersisted`」有測試。可接受 ⚠️（推論）。
- **§2.4 全部 pending → 次要建立**：條件看 `NetIndex`（4.1 不在佔用中，資料是新的）；按開始在佔用下重新列檔（§2.4:80），中間多了一筆已建立的 net 就不開始 ✅。
- **§2.5 進結果頁放 hold、離開 `pageGone`**：見 §1 T-m1 列，對 lease.dart 逐行核過 ✅。
- **§2.8 同一次登入逐筆確認**：`request_confirm_network` 只要 `St::Conn` 與 `flow_busy` 為空（owner.rs:1168-1178）；`flow_busy` 只看 `addr_pending` / `joinreq`（owner.rs:1332-1340），`addr_pending` 只有建立 / 加入 / 申請會設（owner.rs:1088、:1208、:1235、:1264）→ 確認不會被「正在讀這台節點的狀態」擋 ✅。
- **§2.8 建立者比對**：只會挑出這台是建立者的 pending（§1 S-m1 列）；手選錯台 → 空清單 → 不送確認 ✅。被入侵的節點只能被拿去確認它自己是建立者的那幾筆。
- **§3.1**：`pageGone` / `release` 只有 acquire 的一方；`hold` 由工作的一方拿放 ✅。
- **安全**：沒有新的輸入面、平台方法或匯出元件（§5）。被入侵節點的新攻擊面只有 U-m1 那一個（字串比對），修法是一句話。本機非特權程序：紀錄目錄在 app 私有路徑（app_link.dart:59），不適用。

## 5. 現場情境走查（只讀原始碼，⚠️ 推論，沒有跑）

- **0 → 兩台網路**：新增 04、02 → 3.5「建立網路」→ 4.1 勾兩台 → acquire + hold → 04 `makeNetwork` → `[NET_MADE]` → 重讀已建立 → 02 `joinNetwork(rel)` → 國家 → `[JOINED]` → 連線檢查 → 結果頁（close、放 hold）→ 離開 `pageGone` 釋放 → `NetIndex` 重算。走得通。
- **建立途中拔電**：結果不明 → 有 `rel`、pending → 自動檢查：`close()`（U-m3）→ `loginFor` → 04 還在開機 → 失敗 → 停 → 結果頁「檢查網路」（借用）→ 04 開好後：已套用 → `Upgraded` → 寫入 → 重讀已建立 → 停、「完成」；沒套用 → `NotApplied` `[NET_STATE]` → 手機沒有已建立的 net → 次要「建立網路」→ 借用頁 close → pop 值 → 結果頁 pop（釋放）→ 4.1 建立。中間不要有「再試這一台」的建立（U-m4）。
- **建立者壞掉**：4.1 選到 pending → 檢查網路 + 次要建立 → 用 02 建立 ✅（T-M1 修好）。
- **app 被殺**：佔用只在記憶體；紀錄停在 pending / joining → T-M2(a)(b) 的路徑 ✅。
- **藍牙關**：迴圈 `precondition` → 停、不問；檢查網路頁 → 只有「再檢查一次」✅（T-R1(d)）。
- **請求中頁面消失**：迴圈 `pageGone` → 當前請求（≤ 360 s）+ `close()`（≤ 10 s + 連線 5 s）< 420 s → 放 hold → 釋放，不會出現假的待辦 ✅；結果頁的「再試這一台」沒有對應規則 → U-m4 C。
- **選錯節點**：4.1 選錯 = 使用者的選擇，照做；檢查網路頁手選錯 →「這台不是這些網路的建立者」，沒有建立 ✅。

## 6. 基準備註（不算發現）

- `InProgress` / `Unknown` 時舊控制台也給「建立網路」（nodes.dart:1718-1731 只看 `logged`），節點的 `.txn` 之後才結束，可能多一筆 pending（S 已記）。v11 照這個基準（U-m1 要求寫出來）。
- 建立不看既有紀錄、provd 在節點已在網路時是否拒絕第二次建立：沒查 provd（T 也沒查）。
- pending 紀錄新頁面清不掉；`confirm` 只看 key 10 / key 9（被入侵的建立者可以說謊升級，join2 §3.2 的決定）；`RecordWriter` 檢查與寫入之間的空檔（PR 1）。
- 設計 :576 的 420 s 只蓋單一請求；國家對話框不計時（nodes.dart:276-291）——頁面在對話框開著時被系統拿掉的情形，舊控制台靠 `mounted ? showDialog : false` 只擋了「還沒開」的那一種。新頁面寫了「不彈對話框」，已開的對話框照基準。

## 7. 驗證分類

### ✅ 已驗證（原始碼 @ 4dd3563，唯讀）
- lease.dart:42-90（`valid` / `run` / `hold` / `pageGone` / `release`）、:124-149（`acquire`、`_release`、`_revoke` 寫 `unsavedTodos`）。
- record_writer.dart:27-44；ble_gate.dart:108-129（`GateLink.close` 等斷線或 5 s 才移除）、:175-180、:217-226（一次一條連線）。
- app_link.dart:59-92（`readRecords` 只列 `node/`）；lib/src/rust/api/owner.dart:17-20（`storeReadSealed`）、:47-49（`netSummary`）、:107（`nodeDacHash`）。
- owner.rs:76-120（`MemberView` / `net_summary`、creator 只在 pending）、:433-436（標籤慣例）、:444-449、:475-491（`join_state_text` / `confirm_text`）、:645-650（`error_text` 含節點給的 `verb`）、:879-893（info-confirm）、:963-967、:993-994、:1094-1155（`net_persisted` / `persist_failed`）、:1159-1178、:1322-1340、:1541-1561、:1659-1678（登入時設 `self.node`）。
- netrec.rs:395-412（`creator` / `pending_creator`）；loginflow.rs:84-88。
- nodes.dart:44-55（`_makeUnclear` 帶 `[NET_STATE]`）、:150、:194-340、:433-443、:476-491、:520-589、:590-622、:738-746、:1240-1245、:1718-1737；member_ui.dart:231、:257、:283。
- 設計 329-app-uiux.md:312、:495、:576-577、:701、:729-752、:755-758。

### ⚠️ 推論
- U-m1 的攻擊需要節點能在錯誤 detail key 1 放任意文字（看 owner.rs:648 的讀法推，沒查 provd 有沒有限制）。owner.rs:883 碰不到是看程式流程推的。
- U-m2 / U-m3 的被拒依 ble_gate.dart 推；`OwnerConsole` 還沒實作。
- §2.2 上限後的晚到寫入、所有現場走查：只讀原始碼與計畫，沒有跑。

### ❌ 沒做
- 沒跑測試、沒上真機；沒重驗 v1–v9 的發現；沒審 PR 1 / PR 2 的基準實作；沒查 provd 對重複建立的處理。
