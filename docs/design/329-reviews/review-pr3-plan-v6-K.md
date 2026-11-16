# #329 PR 3 實作計畫 v6：對抗式審查（審查者 K，獨立）

審查對象：`docs/design/329-pr3-plan.md` v6（commit 951f4b9，branch `feat/329-pr3`），整份重審。上層：`docs/design/329-app-uiux.md`。對照 v5 審查 I、J。原始碼：同一個工作樹（`app/lib`、`app/rust/bridge`、`app/rust/batman-proto`）。除本檔外沒有改任何檔案；沒有跑測試、建置或真機。

## 結論

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER、3 MAJOR、7 MINOR）

- I-M1（閘門依模式分開）✅ 解了；I-M3（4.1 的 `Page`）✅ 解了（見下方事實）。
- I-M2 / J-M1 **只解了一半**，v6 新加的判斷有兩個沒查到的事實：
  - `StatusView.netId` / `unfinished` 是**空的**時，不代表「確定沒有」。info 讀不到或被限速時也是空的，所以這是 fail-open（M1）。§2.8 的「這次登入讀到的 netId / unfinished」在計畫的登入路徑上**沒有來源**（M1）。
  - 舊的建立者在套用中時，v6 只把它排除在「建立者」之外，**新網路照樣能用別台建立**。J-M1 情境 B 的分裂照樣發生（M2）。
- v6 為 J-m2 加的「generation 前進」判定**不成立**。NotSent 會先寫 joining（g+1）、再寫回 `before`（g+2），generation 前進了兩次。重燒過的節點加入失敗時，結果仍判成「完成」（M3）。
- 三個都是局部修改，不用重新設計。修完要整份再審一次。

---

## MAJOR

### M1　「`netId`、`unfinished` 都是空的」被當成「確定沒在網路、沒在套用」，但 info 讀不到或被限速時也是空的；§2.8 用的「這次登入讀到的」沒有來源

**情境**
1. 04 建立網路 A，途中拔電，手機上 A 是 pending。04 開機後正在套用 A：info key 10 不在，key 11 = true。
2. 首頁自動讀取讀到 04。status 回答了，但 info 這一步遇到 E_RATE / 錯誤，或 info.net 被限速，9 / 10 / 11 都不在。
3. `StatusView.netId == ""`、`unfinished == ""`、`nodeState` 仍是「還沒加入」。依 §2.3，04 **符合建立者條件**，而且「預設清單上第一台」很可能就是它。
4. 4.1 沒有任何一台的 `netId` 等於 A，所以給「建立新的網路」。結果 B 由 04 建立，或由 02 建立而 04 留在 A。

**證據**
- ✅ owner.rs:911 `self.page_info = None;` 在送出 info 之前清掉；:922-925 info 回錯誤時 `Outcome::Err { .. } => None`；:917 info 請求送不出去時直接 `Answer`，info 也是 None。
- ✅ owner.rs:2204-2217：`unfinished` 只在 `unfinished_line(info)` 有值時才非空；`net_id: info.and_then(|i| i.get(10))…unwrap_or_default()`，info 是 None 時是空字串。
- ✅ statuspage.rs:407-411：`info_k11(info) != Some(true)` 就回 None。分不出「key 11 = false」和「沒有 info」。
- ✅ flow.rs:152：`/// 9 / 10 / 11 all absent (info.net hit E_RATE), or malformed -> poll`。Rust 自己承認 info 被限速時這三個鍵都不在，而且在 join 裡把它當成 `Unknown`，不是「沒套用」。
- ✅ §2.8 寫「次要按鈕『建立新的網路』**只在**這次登入讀到的這一台 `netId` 和 `unfinished` 都是空的時才出現」。但：
  - §2.1.1 的 `HandoffProber` 只讀到 `loggedIn`，不讀狀態頁；
  - §2.2「不複製：…狀態頁」；
  - `confirmNetwork` 讀到的 info 只進 `netrec::confirm`，結果只以文字回來（owner.rs:879-893），不寫 `page_info`（`page_info` 只有 :911、:922 兩處寫入）。
  - 所以 §2.8 這次登入**拿不到** `StatusView`。實作時只能退回登入前自動讀取的舊值（可能已過期、可能 info 沒讀到），或永遠是空的（`status_view` 對沒讀過的 session 回空）。兩種都會變成「一律給建立新的網路」。

**為什麼是 MAJOR**：這是 v6 對 I-M2 / J-M1 的主要防線，而它在「拔電後節點剛開機、info 常被限速」這個 §8 情境 2 的時機最容易失效。失效的方向是允許建立（fail-open），結果是隊伍分裂。

**修法**（小）
1. Rust `StatusView` 加一個欄位 `netKnown: bool`：info 有讀到，而且 key 11 有值（`info_k11(info).is_some()`）。一行，加一個 Rust 測試。
2. 建立者資格、§2.8 次要按鈕改成**正面條件**：`netKnown && netId == "" && unfinished == ""`，而且是 `fresh()` 的讀取。讀不到、過期或 `netKnown` 為假 → 不能當建立者 / 不給「建立新的網路」，顯示「節點可能還在開機或設定中，等一兩分鐘再檢查」。
3. §2.8 的「這次登入」要有來源。`confirmNetwork` 之後在同一個 session 呼叫現成的 `requestStatusPage()` → `statusView()`：一個請求，`OwnerConsole` 加這一步，不複製整個狀態頁。建立者在 `makeNetwork` 之前也照樣讀一次。這樣同時處理了 4.1 讀取過期的 TOCTOU。
4. 改壞：
   - info 回 E_RATE（`netKnown` 假）時 04 仍可當建立者 → FAIL；
   - §2.8 用登入前的自動讀取值 → FAIL。
   - 測試用真的 `OwnerSession` 回放 info 錯誤的訊框，不用手寫的 `StatusView`。

### M2　舊的建立者在套用中時，v6 只不讓它當建立者，新網路仍能用別台建立 → J-M1 情境 B 的分裂沒擋住

**情境**：同 M1 的第 1 步。這次 04 的 info 有讀到：key 10 不在、key 11 = true，所以 `unfinished` 非空，04 不能當建立者 ✅。但：
- 4.1 那一列「有 net、都是 pending，沒有任何一台讀到這些 net id」成立：04 的 `netId` 是空的，只有 `unfinished`。所以 4.1 給次要「建立新的網路」。
- 使用者選 02 當建立者 → B applied。04 可以勾成「一般成員」（create mode 只限制建立者，§2.3 :188），之後加入 B 時遇到 InProgress → 輪詢最多 960 s → 04 套用完 A → `Fail::OtherNetwork`（join2flow.rs:756）→「再試這一台」，永遠失敗。
- 04 在 A、02 在 B。這正是 J-M1 修法 2 要擋的（「`unfinished` 非空的節點不能當建立者、**也不能勾**」），也是 v6 §2.3 理由段「建立者條件排除它」想處理、但只處理了建立者那一半的情況。

**證據**
- ✅ 計畫 §2.3 :176-177（4.1 表只看 `netId`）、:216-217（閘門只看 `netId`）、:188（create mode 的 `unfinished` 只限建立者）。
- ✅ flow.rs:146-147、:169-171：key 10 不在、key 11 = true = `InProgress`（輪詢 ≤ 960 s）。
- ✅ statuspage.rs:411：key 10 不在、key 11 = true → `unfinished` 是 `UNFINISHED_LEFT`，非空。
- ⚠️ 套用中節點的 status key 1 值（firmware）沒查。不管是哪個值，`netId` 都是空的，所以 v6 的「netId 等於 pending」都不會成立。

**修法**
- 建立模式：如果手機有 pending 的 net，而**那筆 pending 的建立者**（用 §2.8 的 `node-<last4>` 名稱對到的那一台）最後一次讀到 `unfinished` 非空 → 和「`netId` 等於 pending」一樣：不給建立，只給「檢查網路」，並寫「這台還在套用上一次的設定，等一兩分鐘再檢查」。
  - 只看那筆 pending 的建立者，不看所有節點，避免一台被入侵的節點謊報 `unfinished` 就讓整支手機都建不了網路。
- 建立模式下，`unfinished` 非空、或 `netId` 非空的節點**不能勾**（一般成員也一樣，和加入模式「netId 不是目標 → 不能勾」對齊）。勾了只會換到永遠失敗的「再試這一台」。
- 改壞：拿掉這兩條 → 測試「04（A 的建立者）`unfinished` 非空 → 4.1 沒有『建立新的網路』、04 不能勾」FAIL。

### M3　「generation 前進」不能分辨 NotSent 還原：NotSent 會寫兩次，generation 前進 2

**情境**：02 曾經是網路 N 的正式成員（手機紀錄裡是 Applied）。後來 02 被重燒或維修，回到「還沒加入」。
1. 4.1 加入模式：02 `netId` 是空的 → 可勾（「剛讀到、還沒加入網路」）。
2. `joinNetwork`：`begin` 允許已經是 Applied 的項目，`before` = Applied 項目。國家相同 → `persist_joining`（寫 joining，g→g+1）→ `ask_nonce(Join)` 被拒 → `Fail::NotSent` → `fail` → 沒有 `prev_country` → `persist(before)`（g+1→g+2），項目變回 Applied。
3. 重讀：有 02 的成員項、`!joining && !approved`、generation 比開始時前進 → §2.2.1 第 8 列「完成」→ 連線檢查沒連上 →「已加入，連線狀態未知」，**仍算完成**。
4. 另一條同類的路：國家要改 → `persist_joining(Some(have), Then::SetCountry)`（g+1）→ SetCountry 的 nonce 被拒 → `persist(before)`（g+2）→ `End::Joining(NonceRefused)`，也判成完成。

**證據**
- ✅ join2flow.rs:352-355：`begin` 不拒絕已經存在的 Applied 項目；`self.before = list.iter().find(...)`。
- ✅ join2flow.rs:454-458 `persist_joining` → :442-451 `persist` → :583-590 `net_persisted` 的 `self.gen += 1`，然後 `Then::Join => self.ask_nonce(Op::Join)`。
- ✅ join2flow.rs:681 `Op::Join => self.fail(Fail::NotSent(*code))` → :497-501 沒有 prev_country 時 `persist(self.with_entry(self.after_fail(&f)))` → :509-512 `Fail::NotSent(_) => self.before.clone()`。
- ✅ join2flow.rs:670-675：SetCountry 的 nonce 被拒時 `with_entry(self.before.clone())` 後再 `persist`。
- ✅ 計畫 §2.2.1 :142 的理由寫「NotSent 會把舊的已套用項目還原」，但沒有注意到還原本身也是一次寫入。

**為什麼是 MAJOR**：v6 把它當作 J-m2 的修法列在 §12，但它對 J-m2 自己的情境（重燒的節點）不成立。結果把失敗報成「完成」，違反「不誇大」。§7 的改壞「加入判定不看 generation」也會綠：有 generation 判定時這一例照樣判成完成。

**修法**（擇一，都很小）
- (a) Rust：在 `End::Applied` 那一步的 `OwnerStep` 帶一個結構化欄位（例如 `joinApplied: bool`，只在 `Then::Applied` 寫入完成後為真）。第 8 列 = 重讀得到已套用的項目 **且** `joinApplied`。這是狀態機的結果，不是 log 標籤，和「不靠標籤」不衝突。
- (b) 只改 Dart：記下請求前這台的成員項。如果請求前已經是 Applied，第 8 列另外要求同一個 session 讀一次狀態頁，而且 info key 10 == 目標 net id（用 M1 修法 3 的那一次讀取）。
- 形狀釘子的 golden 要放「請求前已 Applied + NotSent」和「請求前已 Applied + SetCountry nonce 被拒」兩種，連同 `expected_gen` 序列一起放進去。
- 改壞：拿掉 (a) / (b) → 這兩例判成完成 → FAIL。

---

## MINOR

1. **形狀釘子的 generation 不是 `net_summary` 的輸出。** `NetView` 只有 `net_id`、`mesh_id`、`net_name`、`applied`、`country`、`members`（owner.rs:94-102）。generation 是 store 的 `SealedRecord` 給的。golden 要另外記 `PersistNet.expected_gen` 序列（Rust 測試從 `Action::PersistNet` 取）。另外要寫明 golden 怎麼重新產生（例如設環境變數才覆寫，平常只比對），否則第一次就要手寫。bridge 的 Rust 測試在 field 和 dev-trust 兩種組態各跑一次（app-tests.yml:3），兩次要寫出同一份 golden。可以做到。
2. **重讀時機只涵蓋正常結束。** §2.2.1 :146 用「Rust 收到 `netPersisted` 才往下走」回應 J-m1，但 J-m1 的情境是 `ask` **逾時**或斷線時，`FrameInbox` 的處理者還在 seal / CAS。這時重讀會拿到寫入前的紀錄：建立 → `noRecord`、加入 → `absent`，之後寫入才落地。修法照 J 的建議：重讀前先 `await` 收件匣的處理佇列閒下來（或先 `close` 再讀）。測試：persist 卡住 → 逾時 → 判定在寫入之後。
3. **用預設名稱時，「在網路『<名稱>』」看不出是兩個網路。** 4.1 的名稱預設是 `Batman`（§2.3 :173）。舊的 A（pending）和新的 B 都叫 Batman，首頁兩台都顯示「在網路『Batman』」，J-M1 要的「看得到」就沒了。修法：`NetIndex` 的對照只用**已套用**的紀錄給名稱；對到 pending 的 → 「在一個沒有確認完成的網路」+ 檢查那一台的動作；對不到 → 「在另一個網路」。另外 §2.7 在已有 applied 時不列舊 pending 的待辦；但如果有一台讀到的 `netId` 等於某筆 pending，應該照樣列（J-M1 修法 4）。
4. **從節點頁進 4.1 時，`Page` 的還原不對。** 4.1 在首頁上開時，`setPage(Page.home)` 是 no-op（core.dart:189 `if (pg == page && node == pageNode) return;`）。這是正確的：首頁本來就是 `Page.home`，認領釋放後 6 s 就開始一輪（core.dart:267、:526）。但從節點頁（`Page.node`，home_page.dart:207）進 4.1 時，計畫寫「離開 4.1 時照 `_back` 設回首頁」。回到的是節點頁，卻變成 `Page.home`。修法：4.1 記下進來前的 `page` / `pageNode`，離開時還原；§3.1 擁有權表補一列 `NodeLink.page`（首頁、節點頁、設定、4.1 都會寫，各自只在自己開著時寫）。
5. **「讀到」沒有定義新鮮度。** 建立者條件、「`netId` 等於 pending」都用最後一次讀取，`states[id].extra` 在切背景後會留著（core.dart:212-214 只設 `stale`）。擋建立時用舊值沒關係（fail-closed）；允許建立時要用 `fresh()`（M1 修法 2）。寫進 §2.3。
6. **被入侵的節點謊報 `netId` = pending 會造成死路。** 它回報 key 10 = A、key 9 ≠ 版本 → `confirm` 一律 `OtherVersion`（netrec.rs:517-519）→ 4.1 永遠只給「檢查網路」。出口是「從這支手機移除這台節點」。§6 要寫明這一點，而且 4.1 / §2.8 檢查失敗時的句子要提到這個出口。⚠️ 它要先知道 A 的 net_id（推論只有建立者收到過），影響很小。
7. **§12 說 J-m1、J-m2 已處理，實際只處理了一部分**（本文 MINOR 2、M3）。對應表要照實改。

---

## 之前的 BLOCKER / MAJOR

| 項目 | v6 判定 |
|---|---|
| I-M1 閘門擋錯模式 | ✅ §2.3 :198-205 加入模式只看目標那一筆；mnet / mpend / 別的打不開的 net 不影響；改壞有列（§7 步驟 5）。 |
| I-M2 套用中的建立者 / 多筆 pending 挑錯 | ⚠️ 建立者條件有了，§2.7 先挑 `netId` 對得上的那一筆 ✅；但條件是負面的、info 讀不到時 fail-open（M1），而且只限建立者（M2）。 |
| I-M3 4.1 不會讀取 | ✅ `Page.other` 才停讀（core.dart:166-170 `_pageTargets`、:170 `_eligible`）；4.1 用 `Page.home` 正確，測試用真的 `NodeLinkCore`。從節點頁進來時的還原見 MINOR 4。 |
| J-M1 舊建立者留在舊網路、看不到 | ⚠️ `netId == pending` 的擋法 ✅（`confirm` 只看 key 10 / 9，netrec.rs:511-521，對那一台檢查正好升級 A）；但 M1、M2 的缺口讓分裂仍可能發生；看得到的部分在預設名稱下失效（MINOR 3）。 |
| G / H / E / F 的 BLOCKER / MAJOR | ✅ 依 I、J 的結論；本輪抽查 prober.dart:92-104（`loginOutcome` 的來源表）、node_link.dart:153-195（`acquire` / `released`）沒有退步。 |

## 指定要查的事實

- **flow.rs:169-171 / `status_view`**：✅ 套用中 = key 10 不在、key 11 = true。`StatusView.unfinished` 只在 key 11 = true 時非空（statuspage.rs:407-411）；`netId` 只在 info 有 key 10 時非空（owner.rs:2217）。兩個「空」都分不出「沒有」和「沒讀到」（M1）。
- **`Page.home` vs `Page.other`（core.dart:166-170、:186-201）**：✅ `Page.other` 沒有目標、`_eligible` 為假。在首頁上設 `Page.home` 是 no-op：不取消進行中的一輪，下一輪照首頁原本的時間（`fullDue` = 上一輪結束 + 60 s，或釋放後 `leaseDue` 6 s）。不影響首頁的狀態。
- **owner.rs:1094-1110 `net_persisted` 的順序**：✅ 正常結束時寫入一定在最後一個 `answer` 之前。逾時 / 斷線不在此保證內（MINOR 2）。
- **join2flow.rs:509 NotSent 還原**：❌ generation 不是有效的區分條件（M3）。
- **golden JSON**：✅ 做得到：CI 跑 bridge 的 cargo test（app-tests.yml:3），Dart 測試在 `app/` 下讀 `test/fixtures/`。但 generation 要另外取（MINOR 1）。
- **`NetIndex` 檔案修改時間**：✅ 現有的 `readRecords` 已用 `File.lastModifiedSync()`，讀不到 = 0（app_link.dart:72-84）。照抄即可。store 是先寫暫存檔再改名，修改時間就是寫入時間（⚠️ 依 store.rs:118 暫存檔命名推論）。

## 安全（逐 actor）

- **遠端惡意廣播者**：與 v5 相同。msg2 8 s、之後 20 s 上限（§2.1.1）✅。
- **被入侵的節點**：
  - 只能換掉自己的成員項 ✅（P21）。
  - 謊報 `netId = pending` → 死路，出口是移除那一台（MINOR 6）。
  - 謊報 `unfinished` → 只會讓自己不能當建立者。M2 的修法只看 pending 的建立者，不會讓整支手機都建不了網路。
  - 謊報 info 讓 `netId` / `unfinished` 是空的，騙自己當建立者 → 最壞是自己建立新的網路，和現況一樣。
- **本機無權限 app**：沒有新的入口 ✅。M1 / M3 的修法只加 Rust → Dart 的欄位，不是新的輸入面。
- **我們自己的錯**：M1（負面條件 fail-open）、M3（判定條件不成立）。兩個都是「用手寫的 `StatusView` / 成員組合寫測試照樣全綠」的類型。修法要求用真的 Rust 狀態機或 `OwnerSession` 產生資料。
- **秘密**：沒有變化 ✅。
- **沒有佔用時 fail-closed**：✅ 不變。
- **TOCTOU**：4.1 的讀取和建立之間沒有重新讀節點，M1 修法 3（建立者登入後讀一次狀態頁）一起處理。

## 生命週期補充

- **重裝 app**：紀錄打不開 → 重裝警告，沒有「開始」✅。
- **第三台之後加入**：第 6 列「加入網路」→ 加入表單 → 加入閘門只看目標 ✅。
- **加入結果不明但其實已套用**：待辦 → 4.1「補完加入」✅（:185）。
- **同時有 net 和 mnet 的手機**：加入不受影響 ✅；建立被擋，顯示隊員的句子（合理）。
- **建立模式勾到在別的網路的節點**：v6 沒擋（M2 修法第 2 點）。

## 我做了什麼

### ✅ 已驗證（原始碼原文）
- owner.rs:911 `self.page_info = None;`；:922-925 `self.page_info = match o { Outcome::Ok(b) => Some(b), Outcome::Err { .. } => None, };`
- owner.rs:2204 `let unf = statuspage::unfinished_line(info);`；:2217 `net_id: info.and_then(|i| i.get(10)).and_then(Value::as_bytes).filter(|b| b.len() == 16).map(nodecert::hex_lower).unwrap_or_default(),`
- statuspage.rs:407-411 `if info_k11(info) != Some(true) { return None; } Some(if info_k10(info) { (UNFINISHED_MEMBER, false) } else { (UNFINISHED_LEFT, true) })`
- flow.rs:152 `/// 9 / 10 / 11 all absent (info.net hit E_RATE), or malformed -> poll (≤ 960 s)`；:169-171 `None => match unfinished { Some(true) => JoinState::InProgress, Some(false) => JoinState::NotApplied, None => JoinState::Unknown }`
- owner.rs:879-893（`info-confirm` 只產生文字或 persist）；:1292-1303（`request_status_page` / `status_view` 是現成的）。
- join2flow.rs:352-355、:442-458、:497-512、:583-590、:670-681（M3 的寫入序列）。
- netrec.rs:496-536（`Confirm` 種類；不看登入的是誰；`OtherVersion`）。
- core.dart:166-170、:186-201、:261-267；home_page.dart:156、:207、:243（`Page` 的寫入者）。
- node_link.dart:153-195；app_link.dart:72-84；owner.rs:94-102（`NetView` 沒有 generation）；app-tests.yml:3。

### ⚠️ 推論（沒有實跑）
- 套用中節點的 status key 1 值，以及 info.net 被限速的頻率（firmware，本 repo 查不到）。
- 被入侵的節點要知道 pending 的 net_id 才能謊報。
- store 改名後的修改時間。

### ❌ 沒做
- 沒有跑 Dart / Rust 測試、`flutter analyze` 或建置。
- 沒有真機。
- 沒有逐條重驗 v1–v4（A–H）的每一個 MAJOR，依 I、J 的結論並抽查。
