# #329 PR 3 實作計畫 v12 審查（審查者 W，獨立）

對象：`docs/design/329-pr3-plan.md` v12 @ 3ff31eb。範圍照指示：(1) v11 審查 U、V 的每一項在 v12 是否修好；(2) v12 的改動（§2.5 頁面堆疊與結果頁每列的下一步、關連線再返回 / 再登入、確認等 15 s、`pageGone` 後不開新工作；§2.8 佔用下重新列檔解密、「拿到回答」= `[NET_STATE] ` 開頭、`InProgress` / `Unknown` 基準；§2.6；D8 / D9；§6）有沒有新的洞、和 §2.4 / §3.1 / §3.2 / D6 / §6 有沒有矛盾；(3) 從現場出發，不提重新決定 join2 的新機制。join2 與舊控制台（nodes.dart、owner.rs、netrec.rs、flow.rs）是基準，疑問放「基準備註」。只讀原始碼，沒有跑。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 1 MAJOR / 6 MINOR / 4 nit）

v11 的 MAJOR（V-M1 = U-m4）照設計 :750 修好：有 `rel` 的建立列只有「檢查網路」，「建立網路」的出現位置現在五處一致。U-m1 / U-m2 / U-m3 / V m3 / V m4 / V m6 / V m7 的文字都到位。v12 自己新加的「頁面堆疊」那一句（§2.5:102「結果頁取代迴圈頁」）和同一節 :90–92 的佔用規則互相矛盾：照字面做，結果頁一出現佔用就被釋放，結果頁的「再試這一台」「檢查網路」全部拿不到佔用（W-M1）。修法一句話，不加機制。其餘是契約要再精確：「拿到回答」該在哪一層判斷（舊控制台 `_ask` 回的是 `[ANSWER] ` 包起來的字串）、D9 的說法和 `acquire` 的原始碼不符、§2.8 還留著 60 s、「有 `rel`」在寫入失敗時的定義。

---

## 1. v11 發現的對應

| 發現 | 結果 | v12 位置 | 證據 |
|---|---|---|---|
| V-M1 / U-m4-1 結果頁建立列的「再試這一台」 | ✅（附 W-m4） | §2.5:103-108 | 有 `rel` → 只有「檢查網路」；沒有 `rel` → 再 `makeNetwork`；加入列 → `joinNetwork(rel)`；還沒做的台不在結果頁接著做（:103）。和設計 329-app-uiux.md:750「下一步按鈕 =『檢查網路』… 不自動重送」一致。建立不看既有紀錄的事實：owner.rs:1066-1088 ✅。「有 `rel`」在 `persist_failed`（沒寫成）時的定義見 W-m4 |
| U-m4-2 / V m2 檢查網路頁佔用中的兩個輸入 | ⚠️ | §2.8:128 | 拿到佔用 / 借用後重新列檔解密，得 pending 清單與「有沒有已建立的 net」，不看 `NetIndex` ✅；列不出來 → 只給「再檢查一次」✅。V m2 另提的「有打不開的紀錄」沒寫（W-m5）；V m2 的測試「`NetIndex` 計算中 + 已建立 A + pending B → 沒有建立」§6 只寫了借用那一種（:212「借用時剛建立的 pending 會被檢查」），自己拿佔用、`NetIndex` 計算中那一種沒有 |
| U-m4-3 再試的等待規則 | ⚠️ | §2.5:107 | 「再試這一台照迴圈的等待規則（`PopScope`、`keepScreenOn`、頁面消失就停）」✅；但 §3.1:158 `keepScreenOn` 的寫入者仍只寫「多台迴圈（等待期間）」，§6 沒有「再試中返回被擋」的測試（nit W-n1） |
| U-m4-4 / V-M1 測試 | ✅ | §6:212 | 「有 `rel` 的建立列沒有『再試這一台』（改壞 = 給再試 → FAIL）」「沒有 `rel` 的建立列再試 = `makeNetwork`」「加入列再試 = `joinNetwork`」 |
| U-m1 / V m1「拿到回答」 | ⚠️（W-m1） | §2.8:136 | 改成「確認請求本身的 Rust 回答、以 `[NET_STATE] ` 開頭」，排除 `_makeUnclear`（nodes.dart:50）✅；`InProgress` / `Unknown` 算回答、給建立（基準）寫出且有測試 ✅；注入句子 → 測試有 ✅。但 v12 沒說在哪一層判斷：照 §2.3「複製 `ask`」，`OwnerConsole` 回的是 `'[ANSWER] ${st.detail}'`（nodes.dart:324），開頭永遠是 `[ANSWER] ` → W-m1。U-m1 測試 (c)「判斷函式不吃建立的回答」§6 沒有 |
| U-m2 檢查網路頁結束時先 `await close()` | ✅ | §2.8:138、§6:212 | `GateLink.close()` 等系統回報斷線或 5 s 才從 `_links` 拿掉（ble_gate.dart:109-128、:150）；`connect` 在 `_links` 非空時丟 `Refused('a link is already open')`（ble_gate.dart:228-230）。§6「沒 `await close()` → `BleGate` 拒絕 → FAIL」是正確的改壞對照。引用行號寫成 :217-221（實為 :226-231），nit W-n2 |
| U-m3 自動檢查重新登入前關掉前一條 | ✅（附 W-m3 同類） | §2.5:96、§6:212 | `NOT_LOGGED_IN` 來源 owner.rs:1173-1175 ✅；舊 `_ask` 在 unclear / 逾時時 `_drop()` session（nodes.dart:567-568），所以自動檢查實際上幾乎都走重新登入那條 ✅。`OwnerConsole` 內部「重送一次」的重新登入沒蓋到 → 見 W-m3 |
| U-n1 節點頁不給建立 | ✅ | D8 | 照 :312 / :755，不照 :758 字面 |
| U-n2 pop 後 dispose 才交回佔用 | ❌（W-m2） | D9 | D9 說「4.1 的『開始』靠 `acquire` 等 `released` 接住這段空檔」——和原始碼不符：`NodeLink.acquire` 第一行就是 `if (reg.current != null) return null;`（node_link.dart:153），§2.1 加的等待只等「上一個 `released` 的讀紀錄段」，佔用還沒釋放時根本沒有那一段可等 |
| U nit `readRecords` 名稱 | ✅ | §2.6:113、§2.8:137 | `storeReadSealed`（lib/src/rust/api/owner.dart:17）+ Kotlin `open` + `netSummary`（:51），同 claim_records.dart:33-37、nodes.dart:597-601 |
| V m3 確認的等待 | ⚠️（W-m6） | §2.5:96、§6:212；§2.8:131 | §2.5 / §6 改成 15 s ✅：舊控制台 `_confirmNetwork` 不帶 `wait`（nodes.dart:1244），用 `_ask` 的預設 15 s（nodes.dart:511-513，`_waitFor = wait` 在 :530）；計畫引用的 nodes.dart:91 只是欄位初值，結果相同（nit）。但 §2.8:131 仍寫「每筆確認 ≤ 60 s」，而且 15 s 和設計 §5.4 表（329-app-uiux.md:738 寫 60 s）不同、沒列進 §4 → W-m6 |
| V m4 `pageGone` 後不開新工作 | ✅ | §2.5:92、§6:212 | 和舊控制台 nodes.dart:518-520（`if (!mounted && !held) return null;`）一致；國家問題在 `pageGone` 後不彈對話框（§2.5:92） |
| V m5 頁面堆疊 | ⚠️ → **W-M1** | §2.5:102 | 寫了 `pushReplacement` 的順序，但和佔用規則衝突（W-M1）；自己拿佔用的檢查網路頁按「建立網路」後由誰開 4.1、從 4.1 加入表單進來時底下已有一個 4.1，仍沒寫（併入 W-M1 修法） |
| V m6 節點頁「可能是建立者」 | ✅ | §2.8:126 | 名稱 `node-<last4>` 只做預選（owner.rs:1079）；登入後 `MemberView.creator && dacHash == nodeDacHash()`（owner.rs:106-123、:993-994）。`node_dac_hash` 未驗證時回 `""`，`dac_hash` 是 32 位元組雜湊的 hex，不會是空字串 → 不會誤配 ✅ |
| V m7 零碎 | ✅ | §9:274、§2.4:73、§2.6:113、§2.8:138、§2.4:79 | R m3 列改寫 ✅；:621 ✅（nodes.dart:621）；重算時機 + 測試 ✅；借用頁返回前關連線 ✅；「放棄這次加入」acquire 回來頁面不在 → release ✅ |
| V S-m5 | ✅ | §2.6:113、§6:211 | |

---

## 2. MAJOR

### W-M1　v12 新加的「結果頁取代迴圈頁（`pushReplacement`）」和同一節的佔用規則矛盾：照字面做，結果頁一出現佔用就被釋放

- **情境（現場，最常走的那條）**：4.1 勾 04、02 → 開始 → 迴圈頁做完兩台 → 照 §2.5:102「結果頁取代迴圈頁（`pushReplacement`）」→ 迴圈頁的 State 被 dispose。§2.5:92 規定「工作途中頁面消失 → 先 `pageGone()`」，§3.1:153 又說 `pageGone` / `release` 的呼叫者是「多台迴圈 + 它的結果頁」。迴圈頁的 dispose 分不出「正常換到結果頁」和「頁面被系統拿掉」，照字面就呼叫 `pageGone()`。這時 :90「進結果頁 = 放掉 `hold`」已經做了（`_busy == 0`）→ `pageGone()` 立刻 `release()`（lease.dart:73-78）。結果頁顯示時佔用已經不在：
  - 「再試這一台」「檢查網路」是**借用**（§2.5:107、§2.8:130），借不到 → `loginFor` 回 `NoLease`（§2.1:44）或 `BleGate` 拒絕（ble_gate.dart:177-181）；
  - 佔用一釋放，`NodeLink` 就開始自動讀取（node_link.dart:172-193），結果頁上的動作和自動讀取搶同一個無線電——正是設計 §5.4「從第一台登入到最後一頁都不釋放」（329-app-uiux.md:732）要避免的；
  - 結果頁之後 dispose 時再呼叫一次 `pageGone()`（冪等，lease.dart:74，無害），等於這個佔用有兩個 `pageGone` 呼叫者。
- **同一節自己的矛盾**：§2.5:90 寫「放掉 `hold`（`_busy` 歸 0，佔用仍在、**頁面仍在**）」——「頁面仍在」只有在迴圈頁和結果頁是同一頁時才成立；:102 卻說是兩頁、後者取代前者。4.1 → 迴圈頁也是 `pushReplacement`，而 §2.4:80「按開始時在佔用下重新列一次檔」暗示 `acquire` 在 4.1 的按鈕裡；那 4.1 被取代時佔用交給誰也沒寫。
- **為什麼是 MAJOR**：這是全計畫最核心的共享資源（session 佔用）的擁有權，兩句話直接衝突，照字面實作會讓結果頁的每一個下一步都失效，而 §6 的 T-M1(h) 若用假的頁面而不是真的 `Navigator` 就測不出來。不會損壞紀錄（方向是 fail-closed），但 v9 R-M1 / v10 T-m1 收斂的「誰 acquire 誰放」又被打開。
- **修法（一句話，不加機制）**：§2.5:102 改成「按『開始』後**迴圈頁**取代 4.1（`pushReplacement`；`acquire`、重新列檔都在迴圈頁做，`acquire` 回來時迴圈頁已不在 → 立刻 `release()`）；**結果是迴圈頁自己換內容，不是另一個 route**（同一個 State，:90 的『頁面仍在』）；離開結果 = 迴圈頁 dispose = 唯一的 `pageGone()`」。§3.1:153 改成「多台迴圈頁（含它的結果畫面）」。同時補 V m5 第 2 點：自己拿佔用的檢查網路頁 pop「去建立」給呼叫它的頁面，由那一頁 `pushReplacement` 開 4.1 建立表單（從 4.1 加入表單進來時就是取代自己）。
- **負向對照**：T-M1(b)/(h) 用真的 `Navigator` + `LeaseRegistry`：走完兩台 → 結果畫面出現時斷言 `reg.current` 仍是迴圈的佔用、`nodeLinkToken == null`；改壞 = 結果用 `pushReplacement` 推成另一個 route（迴圈頁 dispose 呼叫 `pageGone`）→ FAIL。

---

## 3. MINOR

### W-m1　「拿到回答」要寫在哪一層判斷：照 §2.3 複製的 `ask` 回的是 `[ANSWER] [NET_STATE] …`，`startsWith('[NET_STATE] ')` 永遠不成立

- **證據**：舊控制台的回答在步驟迴圈裡被包成 `a.complete('[ANSWER] ${st.detail}')`（nodes.dart:324；`confirmRemoved` 也一樣，:303）。Dart 自己產生的句子都**沒有**這個前綴：逾時 `_waitLine = '[REQ_FAIL] …'`（:531）、`_makeUnclear`（:50，經 `_unclearNow()`）、`endedLine`（member_ui.dart:283）、`askNoLink`、Rust 拒絕 `'[REQ_FAIL] 操作沒有成功：…'`（:583）。舊控制台自己判斷「節點的回答」就是看這個前綴：`_watchLink` 用 `a.startsWith('[ANSWER] ') ? a.replaceFirst(...) : _linkUnknown`（nodes.dart:709）。
- **情境**：實作者照 §2.3「複製 `ask`」，再照 §2.8:136 寫 `answer.startsWith('[NET_STATE] ')` → 確認的回答永遠是 `[ANSWER] [NET_STATE] …` → 永遠「沒拿到回答」→ 檢查網路頁從不給次要「建立網路」。方向是 fail-closed，但正好把 v10 T-M1 / v11 U-m1 要鎖住的基準（建立者壞掉時的出口之一、`InProgress` / `Unknown` 給建立）弄掉；§6 的測試若用假的 `OwnerConsole` 直接回裸句子，會全綠。§2.5:97 的 `[JOINED]` 判斷有同樣的問題。
- **修法（一句話）**：§2.3 寫明 `OwnerConsole` 回給頁面的契約，例如「回答 = Rust `OwnerKind.answer` 步驟的 `detail`（不加 `[ANSWER] `）；其他結束（逾時、`ended`、沒連線、Rust 拒絕）= 另一種結果」，或保留舊字串並規定判斷用 `[ANSWER] [NET_STATE] ` / `[ANSWER] [JOINED] ` 開頭（同 nodes.dart:709）。兩者擇一寫死。被入侵節點的注入（owner.rs:645-649 `verb` 在句子中間）兩種寫法都擋得住 ✅。
- **負向對照**：§6 的「還在設定中 → 有建立網路」測試要用**真的** `OwnerConsole` 步驟迴圈 + 假的 `OwnerSession` 回 `OwnerKind.answer`（不是假的 console 回字串）；改壞 = 判斷不剝 / 不認 `[ANSWER] ` → FAIL。另補 U-m1 (c)：建立結果不明（`_makeUnclear` 複製句）不算回答。

### W-m2　D9 的說法和原始碼不符：佔用還沒釋放時 `acquire` 不會等

- **證據**：`NodeLink.acquire`（node_link.dart:152-163）第一行 `if (reg.current != null) return null;`；`LeaseRegistry.acquire` 同樣在 `_lease != null` 時回 null（lease.dart:123-128）。§2.1:51 要加的是「先等上一個 `released` 的讀紀錄段（上限 5 s）再檢查 `reg.current`」——等的是**已經釋放**之後 `released()` 裡的 `readRecords()`（node_link.dart:172-193），不是「還沒 dispose 的頁面」。檢查網路頁 / 結果頁 pop 之後到 dispose 之前（退場動畫期間，設計 329-app-uiux.md:577），`reg.current` 仍是舊佔用 → `acquire` 立刻回 null →「另一個操作還在進行」。
- **影響**：使用者要先在 4.1 填名稱才按開始，實際上幾乎碰不到（U-n2 的判斷是對的）；問題是 D9 把它寫成「已經接住」，是沒有證據的說法，之後的審查或實作會照錯的前提走。
- **修法**：D9 改回 U-n2 的說法：「退場動畫期間按開始會被拒（現有提示），再按一次即可；不另加機制」。或者（若要真的接住）在 §2.1 寫明 `acquire` 在 `reg.current` 是「已 `pageGone` 且 `_busy == 0`」時等它 dispose——這是新機制，本審查**不建議**。
- **負向對照**：T-M1(i) 不用 `pumpAndSettle`、在 pop 之後立刻按開始 → 斷言顯示「另一個操作還在進行」（鎖住真實行為，不是假裝通過）。

### W-m3　`OwnerConsole` 內部「重送一次」也會重新登入，v12 的「先關再登入」沒蓋到它

- **證據**：§2.3:62 複製 `ask` 的「重送一次」；舊 `_ask` 在 `retry: true` 時寫入失敗 → `_drop()` → `_login(_lastNode!)` → 再送（nodes.dart:553-566），而且 session 為 null 時開頭就自動 `_login`（:521）。§2.3:63 說新版「登入用 `loginFor`」。`BleGate` 一次一條（ble_gate.dart:226-231），而 `OwnerConsole` 自己的 `GateLink` 還開著時 `loginFor` 的 `connect` 會被拒。新頁面會用到 `retry: true` 的請求（例如連線檢查以外的狀態讀取；`linkCheck` 本身是 `retry: false, held: true`，nodes.dart:702-703）。
- **修法（一句話）**：§2.3 寫明「`OwnerConsole` 只活一個 session：不在內部重新登入；需要重新登入時回『沒有連線』給呼叫者，由呼叫者 `await close()` → `loginFor` → 新的 `OwnerConsole`（同 §2.5:96）」，或「內部重新登入前先 `await` 關掉自己的連線」。擇一。
- **負向對照**：§6 第 3 步「重送一次」用會記連線數的假 `BleGate`：寫入失敗後的第二次 `connect` 沒被拒；改壞 = 不先關 → `Refused` → FAIL。

### W-m4　「有 `rel`」要定義成「`PersistNet` 寫成功」：寫入失敗時 `rel` 拿得到、紀錄卻不存在

- **證據**：§2.5:85「`rel` 取自那一台建立時 `PersistNet` 步驟的 `OwnerStep.rel`」。`PersistNet` 步驟在寫之前就給出 `rel`；寫失敗 → `persist_failed`，`applied == false` 時回「`[REQ_FAIL] 建立網路沒有成功：…`」（owner.rs:1146-1151），這時磁碟上沒有紀錄、什麼都沒送出（join2 §3.1，紀錄先落地再送）。§2.5:104 的括號「有 `rel`（已寫入、已送出）」顯示作者的本意是「寫成功」，但 :85 的取法不是。
- **情境**：建立時 seal 失敗（金鑰被系統作廢）或儲存空間滿 → 照 :85 這一列「有 `rel`」→ 自動檢查：重讀那一筆讀不到（:96 沒定義讀不到時怎麼辦）→ 停 → 結果頁只有「檢查網路」→ 檢查網路頁重新列檔找不到以這台為建立者的 pending →「這台不是這些網路的建立者」→ 死路（要回首頁才看得到第 6 列「建立網路」）。
- **修法（一句話）**：§2.5:85 改成「`rel` = `PersistNet` 寫成功後（呼叫 `netPersisted` 那一刻）才記下；`persistFailed` → 沒有 `rel`」。`applied == true` 的寫入失敗（owner.rs:1144-1145「節點已套用，手機紀錄沒存好」）磁碟上有 pending 那一筆 → 有 `rel`，照現在的規則走 ✅。
- **負向對照**：`persistFailed`（未套用）→ 結果頁那一列有「再試這一台」、自動檢查 0 次；改壞 = 寫之前就記 `rel` → 只有「檢查網路」→ FAIL。

### W-m5　§2.8 重新列檔遇到「打不開的那一筆」沒有規則

- **證據**：§2.8:128 只寫「列不出來 → 只給『再檢查一次』」。§2.6:114 對 `NetIndex` 的規則是「壞的一筆記一行」（跳過）；舊控制台 `_pickNet` 也是跳過並顯示一句（nodes.dart:603-605）。V m2 曾建議 fail-closed（打不開的可能是已建立的 net）。
- **情境**：手機有已建立的 A（紀錄壞了 / 金鑰問題打不開）+ pending B。檢查網路頁照「跳過」會得出「沒有已建立的 net」→ B 回 `NotApplied` → 次要「建立網路」→ 拆成兩個網路。4.1 經 `NetIndex` 也會得出同樣結論（§2.4:77），所以不是 v12 才有的；問題是 §2.8 沒寫，兩處實作可能各自決定，結果不一致。
- **修法**：§2.8 寫明「重新列檔用和 `NetIndex` 同一個函式、同一規則（打不開的跳過並記一行）」——和基準（舊控制台一直給建立）一致，不新增分類。若要 fail-closed，兩處一起改並列進 D6（本審查不要求）。
- **負向對照**：同一組 fixture（A 打不開 + pending B）對 4.1 與檢查網路頁給同樣的「有沒有已建立的 net」答案。

### W-m6　確認 15 s：§2.8:131 還寫 60 s；和設計 :738 不同卻沒列進 §4

- **證據**：§2.5:96、§6:212 是 15 s（照舊控制台，nodes.dart:511-513、:1244）；§2.8:131 仍寫「登入 ≤ 60 s + 每筆確認 ≤ 60 s」。設計 §5.4 表 329-app-uiux.md:738 寫自動檢查 60 s；:574 寫「一般請求 15 s、本設計不加新的逾時」。計畫照 :574 / 舊控制台是對的，但依 O-M3 的慣例，和設計表不同的地方要列在 §4。
- **修法**：§2.8:131 改成 15 s；§4 加一行 D10「自動檢查的等待用舊控制台的 15 s（設計 :574），不是表上的 60 s（:738）」。
- **負向對照**：§6 已有「確認等 15 s」✅（改壞 = 60 s → FAIL）。

---

## 4. nit

- **W-n1**　§3.1:158 `keepScreenOn` 的寫入者加上「結果的『再試這一台』」（若照 W-M1 是同一頁，寫「多台迴圈頁（含再試）」）；§6 補「再試中返回被擋」（U-m4 第 4 點）。
- **W-n2**　引用行號：§2.5:96 / §2.8:138 的 ble_gate.dart:217-221 應為 :226-231（`connect` 的一條限制）；§2.5:96 的 nodes.dart:91 是 `_waitFor` 欄位初值，確認實際用的是 `_ask` 的預設 `wait`（:511-513，:530 賦值）。數值都是 15 s，不影響結論。
- **W-n3**　結果頁「沒有 `rel` 的建立列再試 = `makeNetwork`」之後，若這次拿到 `rel` 但重讀不是已建立，要不要照 §2.5:96 自動檢查一次？寫一句「照迴圈的建立步驟」即可。
- **W-n4**　§6 補 V m2 的「自己拿佔用、`NetIndex` 計算中 + 已建立 A + pending B → 沒有建立」測試（現在只有借用那一種）。

---

## 5. v12 改動的其他檢查（沒有發現）

- **§2.5 `pageGone` 後不開新工作**：和舊控制台 nodes.dart:518-520 同規則 ✅；國家問題在 `pageGone` 後回 `countryConfirmed(yes: false)` → `Declined`、沒有寫入（owner.rs join2 `Declined`）⚠️（推論，照 :92「不彈對話框」）。
- **§2.5 自動檢查**：session 還在的情況只有「`[REQ_FAIL] 節點已套用，手機紀錄沒存好`」那種（`persist_failed` 後 `back_to_conn`，owner.rs:1144-1150）；`[NET_MADE]` 只在套用並寫成後出現（owner.rs:1094-1099），重讀必定是已建立 ✅；結果不明時舊 `_ask` 一定 `_drop()`（nodes.dart:567），所以走重新登入 ✅。
- **§2.8 同一次登入逐筆確認、15 s**：逾時 → `_waitLine` → `_drop()`（nodes.dart:568）→ 下一筆會 `NOT_LOGGED_IN`；計畫「沒拿到回答 → 整頁停」先擋住 ✅。`Upgraded` 的 `PersistNet` 寫入不重設計時（只有寫節點時 `_kick`，nodes.dart:225-229、:248-266）；寫入超過 15 s → 回答變逾時、紀錄可能已升級 → 整頁停、「再檢查一次」→ `Already` → 完成。fail-closed ✅。
- **§2.8 建立者比對**：`creator` 只在 pending 時為真（owner.rs:106-108），`node_dac_hash` 來自本次登入驗過的 DAC（owner.rs:991-994）✅。
- **§2.6**：佔用中只重讀單筆 / 重新列檔，`NetIndex` 不重算 ✅；和 §2.4:80、§2.8:128 同一讀法（W-m5 要求寫明同一函式）。
- **D8**：照 :312 / :755 ✅。
- **安全**：沒有新的輸入面或平台方法（§5）。被入侵節點：能把字串塞進 `error_text` 的中間（owner.rs:648），開頭比對擋住 ✅；能讓自己是建立者的 pending 回 `NotApplied` / `Unknown` → 次要建立出現（只帶到 4.1 表單，要使用者按開始），屬 join2 基準 ✅；能拖長每一步 → 見基準備註。本機非特權程序：紀錄在 app 私有目錄，不適用。

## 6. 現場情境走查（只讀原始碼與計畫，⚠️ 推論）

- **0 → 兩台**：4.1 → 迴圈頁（acquire、重新列檔）→ 04 建立 `[NET_MADE]` → 重讀已建立 → `close()` → 02 `loginFor` → 加入 `[JOINED]` → 連線檢查 → 結果 → **W-M1：結果若是另一個 route，佔用在這裡就沒了**；照 W-M1 修法（同一頁）→ 離開時 `pageGone` 釋放 → `NetIndex` 重算 ✅。
- **建立途中拔電，04 回來時已套用**：結果不明 → `_drop` → `close()` → `loginFor`（04 還在開機 → 60 s 失敗）→ 停 → 結果「檢查網路」（借用；需要 W-M1）→ `Upgraded` → 寫 → `[ANSWER] [NET_STATE] …`（W-m1）→ 重讀已建立 → 完成 → `close()` → 返回 → 02 那一列是「還沒做」，重開 4.1 ✅。
- **建立時 seal 失敗**：W-m4。
- **檢查網路 → 建立網路 → 4.1 → 立刻開始**：W-m2（實際上幾乎碰不到）。
- **藍牙關 / 佔用收回 / app 被殺**：照 §3.2 ✅。

## 7. 基準備註（不算發現）

- 舊 `_ask` 的等待從**每次寫節點**重新起算（`_kick`，nodes.dart:494-500、:229），所以「建立 ≤ 360 s」是每一段、不是總和。`pageGone` 之後被入侵的節點可以讓每一段都拖到快 360 s，總和超過 420 s → `_revoke` → 首頁出現「上一個操作可能沒有存完」（lease.dart:80-82、:143-148）。方向 fail-closed、只有在頁面已被拿掉時才會碰到，設計 :576 已接受「420 s 蓋單一請求」。
- `InProgress` / `Unknown` 給建立、pending 清不掉、confirm 信任建立者節點的 key 10 / 9、`RecordWriter` 檢查與寫入之間的空檔：同 S / U / V 的基準備註。
- 確認升級第一筆就停，同一台建立的第二筆 pending 留著（基準，§8）。

## 8. 驗證分類

### ✅ 已驗證（原始碼 @ 3ff31eb，唯讀）
- ble_gate.dart:108-129（`GateLink.close` 等斷線或 5 s）、:150（`closeMax`）、:177-181（`_gate`）、:226-231（一次一條連線）。
- lease.dart:42-90（`run` / `hold` / `pageGone` / `release`）、:104-148（`acquire` 有佔用就回 null、`_release`、`_revoke`）。
- node_link.dart:152-163（`acquire` 第一行 `reg.current != null → null`）、:171-193（`released` 讀紀錄）。
- nodes.dart:42-55、:89-91、:176-183（`_drop`）、:194-340（步驟迴圈；回答包成 `[ANSWER] `，:303、:324）、:494-500（`_kick`）、:511-589（`_ask`：預設 15 s、:518-520 頁面不在不開新請求、:521 自動登入、:553-566 重送前重新登入、:567-568 unclear / 逾時 drop）、:597-621（`_pickNet` 跳過打不開的）、:636-672（加入）、:690-713（`_watchLink` 用 `[ANSWER] ` 判斷）、:1240-1245（`_confirmNetwork` 不帶 wait）。
- member_ui.dart:283（`endedLine`）。
- owner.rs:77-123（`MemberView` / `net_summary`）、:438-439、:473-491（`join_state_text` / `confirm_text`）、:506、:645-650（`error_text` 的 `verb`）、:879-893（info-confirm）、:960-975、:991-994（`node_dac_hash`）、:1066-1088（建立不看既有紀錄、`node-<last4>`）、:1094-1157（`net_persisted` / `persist_failed`）、:1158-1178（`check_network` / `request_confirm_network`）。
- lib/src/rust/api/owner.dart:17、:32、:51、:107；claim_records.dart:28-37。
- 設計 329-app-uiux.md:570-580、:726-758。

### ⚠️ 推論
- W-M1 的危害依「迴圈頁 dispose 照 §2.5:92 呼叫 `pageGone`」的字面推論；`OwnerConsole` / 新頁面還沒實作。
- W-m1 依「`OwnerConsole` 照抄 `ask` 的回傳字串」推論；計畫 §2.3 沒寫死。
- §5、§6 的走查與國家問題在 `pageGone` 後的行為：只讀原始碼，沒有跑。

### ❌ 沒做
- 沒跑測試、沒上真機；沒重驗 v1–v10 的發現；沒審 PR 1 / PR 2 的基準實作；沒查 provd 對重複建立的處理；沒讀 join2 全文（只照計畫引用的段落與原始碼）。
