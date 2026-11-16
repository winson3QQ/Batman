# #329 PR 3 實作計畫 v6 審查（審查者 L，獨立）

審查對象：`docs/design/329-pr3-plan.md` @ 951f4b9（branch feat/329-pr3），整份。原始碼同一個 commit。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 4 MAJOR / 8 MINOR）

v5 的四個 MAJOR 中，I-M1（閘門依模式分開）、I-M3（4.1 用 `Page.home`）已解。I-M2 和 J-M1 的修法方向對，但 v6 新加的三條規則各有一個落空的地方：
- 建立者規則把「沒讀到 info」當成「沒有網路」；
- §2.8 的按鈕條件沒有資料來源；
- generation 前進的判定在 NotSent 還原時也成立。

另外首頁「在網路「名稱」」在預設名稱下分不出兩個網路。四條都是局部修改，不用重新設計。

---

## MAJOR

### M1　建立者規則「`netId` 空、`unfinished` 空」在 info 沒讀到時也成立（fail-open）；正在套用的節點仍可能被選成建立者

**情境**
- 04 建立 A 時拔電，重開後正在套用 A：info key 10 不在、key 11 = true、status key 1 = 1。
- 這一輪 NodeLink 讀 04：status 回 OK，但 info 回錯誤碼（E_RATE / E_BUSY），或 info 本身回 OK、裡面的 info.net 子讀取被限速（9 / 10 / 11 都不在）。
- 兩種情況下，`StatusView.netId == ""`、`unfinished == ""`、`nodeState == 1`。04 符合 v6 的建立者條件，而且多半是清單第一台，會被預設成建立者。I-M2 / J-M1 情境 B 原樣回來。
- 另一個情況：4.1 用的是「最後一次讀取」。core 在讀不到時不清 `extra`，所以可能拿拔電前那一次的 StatusView 判斷。

**證據**
- ✅ owner.rs:911-926：status 讀完先 `self.page_info = None`；info 回 `Outcome::Err` → `page_info = None`；請求送不出去也一樣留 None。
- ✅ owner.rs:2204-2217 `status_view_of`：`unfinished` 來自 `statuspage::unfinished_line(info)`，info None → `""`；`net_id` 也 → `""`。
- ✅ statuspage.rs:398-411：`info_k11` 不在 → `None` → `unfinished_line` 回 None → `""`。所以「key 11 不在 / 讀不到」和「key 11 = false」都得到空字串。
- ✅ flow.rs:152「9 / 10 / 11 all absent (info.net hit E_RATE) … -> Unknown」：info 回 OK 也可能沒有網路欄位。`flow::join_state` 自己把這種情況當成 `Unknown`，不是 `NotApplied`（flow.rs:157-175）。
- ✅ core.dart:440 只在 `Res.body` 時更新 `s.extra`；notFound / unreachable 時不清。計畫 §2.3 沒有定義「讀到」是不是 `fresh`。

**修法**
1. 建立者條件改成 Rust 自己的判定。在 `StatusView` 加一個欄位，例如 `net_state`（用 `flow::join_state` 的分類，key 10 不在時是 `InProgress` / `NotApplied` / `Unknown`；或只加 `k11_known: bool`），改一行加一個 Rust 測試。
2. 建立者 = `fresh` && `nodeState == 1` && `net_state == NotApplied`（key 10 不在而且 key 11 明確是 false）。`Unknown`（含 info 讀不到）→ 不能當建立者，標「這台的網路狀態沒讀到，等一下」。
3. 規則只寫在一個純函式裡，4.1 和 §2.8 共用。
4. 測試：
   - info 回錯誤 → 不能當建立者；
   - info 回 OK 但沒有 9 / 10 / 11 → 不能；
   - 讀不到時保留的舊 StatusView → 不能（要求 `fresh`）；
   - key 11 = false → 可以。
5. 改壞：用 `unfinished.isEmpty && netId.isEmpty` → 前兩條 FAIL。

### M2　§2.8「這次登入讀到的 `netId` 和 `unfinished`」沒有資料來源：`confirmNetwork` 不讀狀態頁，照字面寫會讓「建立新的網路」永遠出現

**情境**：pending A，04 正在套用（InProgress），或讀不到網路欄位（Unknown）。§2.8 登入 04 → `confirmNetwork(rel)` → 沒有升級 → 「不是 applied」。這時要決定次要按鈕。

**證據**
- ✅ owner.rs:1170-1179 `request_confirm_network` 送的是 `"info-confirm"`。owner.rs:880-893 只把結果交給 `netrec::confirm`，回 `OwnerStep::text`，**不設 `page_info` / `page_status`**。
- ✅ owner.rs:1300-1303 `status_view()` 讀的是 `page_status` / `page_info`。這個 session 沒做過狀態頁讀取時，兩個都是 None → `netId ""`、`unfinished ""`。
- ✅ 計畫 §2.2「不複製：…狀態頁」。`OwnerConsole` 沒有讀狀態頁的動作。`OwnerStep` 也沒有結構化的 `net_state`（P20）。
- 後果有兩種：實作者拿 `session.statusView()` 判斷 → 按鈕永遠出現，E-B1 / F-B1 / I-M2 的危險時機原樣回來；不拿 → §2.8 的條件做不出來。

**修法**
1. `OwnerConsole` 加一個唯讀動作 `readStatus()`，就是 `requestStatusPage`（status + info，舊控制台 nodes.dart:1155 已有同樣的呼叫）。
2. §2.8 在 confirm 沒有升級之後，**同一個 session** 讀一次狀態頁，用 M1 的同一個純函式判斷。
3. 讀不到或 `Unknown` → 只給「再檢查一次」，並寫「節點可能還在開機或設定中」。
4. 測試：
   - confirm 沒升級 + 狀態頁讀到 InProgress → 沒有按鈕；
   - 讀到 NotApplied → 有按鈕；
   - 狀態頁讀取失敗 → 沒有按鈕。
5. 改壞：不讀狀態頁、直接用 `statusView()` → 第一條 FAIL。
6. §2.2「不複製」那一行改寫，說明多了這一個唯讀讀取。

### M3　加入判定「generation 前進」分不出 NotSent 還原：還原本身就是兩次 CAS 寫入

**情境**：02 原本在手機紀錄裡是 Applied。後來它被重燒或維修，認領後讀到「還沒加入」，可以勾。重新加入時，國家相同 → `persist_joining`（寫入一次，gen+1）→ op/nonce 被拒（任何不是 7 的代碼，例如 E_RATE）→ `Fail::NotSent` → `fail()` / `reverted()` 把 `before`（Applied）寫回去（再寫一次，gen+2）。重讀結果：有 02 的成員項、`!joining && !approved`、generation 比開始時前進了 2。照第 8 列判成「完成」→ 連線檢查沒連上 →「已加入，連線狀態未知」，**仍算完成**。這正是 v5 J m2 要擋的情況。v6 宣稱已修好，但這個判定擋不住。

**證據**
- ✅ join2flow.rs:450-455 `persist_joining` → `persist()`（PersistNet，CAS）。它在 network/join 之前一定會寫（檔頭 :12-13「the entry joining … lands before anything is sent」）。
- ✅ join2flow.rs:495-502 `fail()`：沒有 prev_country 時，直接 `persist(after_fail)`。join2flow.rs:524-528 `reverted()` 也是 persist。join2flow.rs:507-513 `after_fail(NotSent)` = `before`（原來的 Applied 項目）。
- ✅ join2flow.rs:681 `Op::Join` 的 op/nonce 回錯誤（不是 7）→ `fail(Fail::NotSent)`。
- ✅ store.rs:132-142 每次 `write_cas` 都是 `expected_gen + 1`。join2flow.rs:584 `self.gen += 1`。
- 所以 NotSent 還原時 generation 一定會前進，和成功時一樣。§7 第 5 步的改壞「加入判定不看 generation（NotSent 還原被當成完成）」，前提就是錯的。

**修法**（擇一，建議 a）
- a. 已套用之後，在同一個 session 讀一次狀態頁（M2 的 `readStatus()`），要求 info key 10 == 目標 net id。不符或讀不到 → 第 9 列「結果不明 +再試這一台」。這也讓「完成」有節點本身的證據。
- b. Rust 在 `OwnerStep` 帶一個結構化的加入結束種類（Applied / Failed / Joining），只用來分類、不顯示。
- 測試：用 Rust 驅動 join2flow 走 NotSent 還原（golden 裡已有這個形狀）→ Dart 判成 `absent` / 不明，不是 `applied`。
- 改壞：只看 generation → FAIL。

### M4　「在網路「<名稱>」」在預設名稱下分不出舊網路和新網路；J-M1 的「看得到」沒有做到

**情境**：§8 情境 2 的延伸。04 建立 A（名稱預設 `Batman`）時拔電，之後其實套用了 A，但手機讀不到它。使用者按「建立新的網路」，名稱又是預設的 `Batman`，由 02 建立 B，套用成功。
- `NetIndex` 的 `netId → 名稱` 對照包含 pending 的 A（§2.4「另外提供對照」沒有排除 pending）。
- 首頁和節點頁：04 顯示「在網路「Batman」」，02 也顯示「在網路「Batman」」。
- §2.7 有已套用的 B 時，不列待辦。4.1 加入模式裡，04 `netId ≠ B` → 不能勾，而且沒有寫要標什麼。
- home_logic 的狀態區（首頁上方那一行，home_logic.dart:61-140）只看顏色和 `nodeState`。04 是「在網路裡」，不會出現在第 6 列。

結果：隊伍已經分裂，畫面上沒有任何一處看得出來。J-M1 修法 4 要的是區分「`netId` 是手機上 pending 的紀錄」和「`netId` 不是任何已套用的紀錄」，v6 只做了名稱。

**證據**
- ✅ 計畫 §2.3 建立表單「名稱（預設 `Batman`）」；§2.4「`netId → 網路名稱` 的對照」；§2.5 節點列「在網路「<名稱>」」或「在另一個網路」（對照不到時）。
- ✅ home_logic.dart:31、:86-97：第 6 列只取 `nodeState == 1`；:139 之後是第 14 列「一切正常」。
- ✅ §7 第 8 步沒有列這個顯示的測試和改壞。

**修法**
1. 對照分三種，各一句：
   - `netId` = 已套用的紀錄 → 「在網路「名稱」」；
   - `netId` = 手機上 pending 的紀錄 → 「在一個還沒確認完成的網路「名稱」」；
   - 對不到 → 「在另一個網路」。
2. 手機有已套用的網路，而有一台讀到的 `netId` 不是這個網路時（它在 pending 或別的網路），首頁不能落到第 14 列「一切正常」。用現有的第 12 列（黃）寫「X 在另一個網路，要先離開（PR 4）」，或至少算進待辦數（第 11 列）。
3. 4.1 加入模式裡不能勾的那一台，標同一句。
4. 測試與改壞：
   - applied B + 04 讀到 `netId` = pending A → 首頁不是第 14 列，節點列寫「還沒確認完成」；
   - 改壞：pending 和 applied 用同一句 → FAIL。
5. §3.3 補一列「舊建立者留在舊網路」：現在 / 之後 / 測試。

---

## MINOR

1. **重讀時機在逾時時仍然不成立**（G m1 / I m3 / J m1 沒有真的解決）。
   - 情況：`ask` 可以因為 `_wait` 計時器回來（nodes.dart:497-498 和 :547-571 的結構），這時步驟迴圈還可能在 `persistNet` 的 seal / CAS 裡（nodes.dart:253-265）。v6 的理由「Rust 只在 netPersisted 之後才往下走」只對正常結束成立。
   - 後果：建立 → 檔案還沒在 → `noRecord`「建立失敗」，之後 pending 才落地；加入 → `absent`，之後 joining 才落地。都能恢復（之後會變成待辦），但結果頁說錯了。
   - 修法：重讀前先 await `FrameInbox` 處理者閒下來（或 `console.close()` 等迴圈結束）。測試：persist 卡住 → 逾時 → 先等再判定。
2. **§2.8 的對象永遠讀不到時沒有出口**（E-M2 換了形式）。
   - 情況：建立者壞了或遺失，但手機還有它的 `node/` 紀錄。第 6 列和待辦都進 §2.8，登入失敗只有「再檢查一次」。4.1 的「建立新的網路」只能從 3.6（再認領一台）進去，或先把壞掉的節點從手機忘掉。
   - 修法：§2.8 登入結果是 `notFound` 時，加一行「如果這台節點已經不在了」，次要按鈕開 4.1。4.1 自己的規則（沒有一台讀到 pending 的 net id）和表單上的提醒照舊。
3. **4.1 表和建立閘門在「pending net + mnet / mpend」「pending + 打不開的 net」時不一致。**
   - 4.1 表的 pending 列沒有排除 mnet / mpend，會給「建立新的網路」，閘門每次都拒絕。
   - 「有打得開的 pending + 一筆打不開」在 4.1 表沒有對應的列（I m 提過）。
   - 修法：4.1 表補這兩列，和閘門一一對應（加入模式不受影響，維持 I-M1 的修法）。
4. **golden JSON 的 `generation` 不是 `net_summary` 的欄位**（owner.rs:115-126 `NetView` 沒有 generation）。
   - 要寫明 generation 從哪裡來（驅動 join2flow / store 的寫入次數）。
   - Rust 測試在檔案**不存在**時也要 FAIL，不能自動產生（規則：找不到東西可測必須 FAIL），另外用環境變數才重寫。
   - Dart 測試讀不到檔案也要 FAIL。
5. **4.1 從節點頁進來時，離開後頁面被設成 `Page.home`。** `_back`（home_page.dart:154-156）一律設回首頁，回到節點頁後就不再優先讀那一台（core.dart:163-166、:196 X33）。修法：離開 4.1 時還原成進來前的 `Page` / `pageNode`。
6. **被入侵的節點可以讓使用者一直卡在「只有檢查網路」。**
   - 情況：一台已認領、被入侵的節點在 info key 10 報 pending A 的 net id（它是建立者時一定知道）。4.1 / §2.7 就只給「檢查網路」那一台，`confirm` 會因為 key 9 不符而不升級，或者在它也假報 key 9 時把 A 升級。
   - 影響：只是阻斷服務，或升級一個沒有其他成員的網路（I 的 D4 驗證），不擴大權限。
   - 修法：§6 照實寫；§2.8 結果是「不符」時提示「可以從這支手機移除這台節點」。
7. **§7 沒有 `NetIndex` 對照與首頁顯示的測試**（§2.5 最後一列的新功能）。隨 M4 補上。
8. **§12 的 v5 對照表把 I-M2、J-M1、J m「NotSent」寫成已處理。** M1–M4 修好後要更新，照「先講自己錯在哪」的慣例寫明 v6 的落空處。

---

## 之前的 BLOCKER / MAJOR

| 項目 | v6 狀態 |
|---|---|
| I-M1 加入閘門被不相干的紀錄擋住 | ✅ 已解（§2.3 依模式分開；加入只看目標） |
| I-M2 套用中的建立者、多筆 pending 挑錯 | ⚠️ 部分解決：§2.7 先挑 `netId` 對得上的 ✅；建立者條件在 info 讀不到時 fail-open（M1）；§2.8 的條件沒有資料來源（M2） |
| I-M3 4.1 不排讀取 | ✅ 已解（core.dart:169 確認 `Page.other` 不排；`Page.home` 會讀；用真的 core 測）；小問題見 m5 |
| J-M1 舊建立者看不到 | ⚠️ 部分解決：顯示名稱有了，但預設名稱下分不出來，狀態區仍可能是「一切正常」（M4） |
| J m NotSent 被當成完成 | ❌ 沒解（M3） |
| G m1 / I m3 / J m1 重讀時機 | ❌ 逾時的路徑沒解（m1） |
| G-M1–M3、H-M1–M3 | ✅ 依 I、J 的核對，本輪沒有發現回退 |
| E-B1 / F-B1 | ✅ 「重新建立」已拿掉；但 M1 / M2 沒修好的話，同樣的危險時機會從「建立新的網路」回來 |
| A–D | ⚠️ 本輪未逐條重驗，依 E–J 的對照 |

## 指定要查的問題

- **建立者規則與 owner.rs `status_view` / flow.rs**：不成立，見 M1。
- **4.1 用 `Page.home`**：✅ core.dart:163-169，`Page.home` 讀所有 `node/`；拿佔用後 `!lease` 讓 `_eligible` 為假，清單就固定。首頁本來就是 `Page.home`，從首頁進來時 `setPage` 不會改變什麼（core.dart:188 同頁直接 return），下一輪照 6 s 後（釋放）或 60 s 的間隔。從節點頁進來的副作用見 m5。
- **net_persisted 之後重讀**：正常結束成立（owner.rs:1094-1127）；逾時路徑不成立（m1）。
- **generation 前進當成加入判定**：不成立，見 M3。
- **golden JSON**：方向對；細節見 m4。CI 有跑 cargo 與 flutter test（.github/workflows/app-tests.yml:80）。
- **§2.7 待辦對象**：✅ 規則合理；`netId` 和 net 檔名都是小寫 16 進位（owner.rs:125、:2217）。
- **§2.8「建立新的網路」的條件**：方向對，資料來源缺（M2），判斷規則要用 M1 的版本。
- **「在另一個網路」**：只在對照不到時才顯示；對到 pending 時顯示同名，見 M4。使用者能做的事只有等 PR 4，計畫 §9 有寫。

## 安全（逐 actor）

- **遠端 BLE / 惡意廣播**：不變（8 s msg2、20 s 上限、`loginOutcome` 不種「是 Y」）。✅ prober.dart:96-104 確認。
- **被入侵的節點**：成員項只能換掉自己的（P21，前幾輪已驗證）。新的影響是用假的 key 10 / 11 讓 §2.3 / §2.7 / §2.8 卡住，或擋掉自己當建立者（m6），屬於阻斷服務。假報 key 11 = false 讓自己被選成建立者，它本來就是被認領的節點，沒有新的權限。
- **本機無權限 app**：沒有新的入口。
- **我們自己的錯**：M1–M3 都是 fail-open（把「不知道」當成「沒有」或「成功」），違反 §6 寫的 fail-closed。
- **秘密**：`NetIndex` 只記 net id 前 8 碼；`OwnerConsole` 只記種類。✅ 沒有新的外洩。

## 驗證分類

### ✅ 已驗證（原始碼原文，commit 951f4b9）
- owner.rs:911-926：
  `self.page_info = None; match conn.request("info", …)` …
  `Ok(Some(o)) if *asked == "info-page" => { … self.page_info = match o { Outcome::Ok(b) => Some(b), Outcome::Err { .. } => None }`
- owner.rs:2204-2208：
  `let unf = statuspage::unfinished_line(info);` …
  `unfinished: unf.map(|(l, _)| l).unwrap_or("").into(),`
- statuspage.rs:407-411：
  `pub fn unfinished_line(info: Option<&Value>) -> Option<(&'static str, bool)> { if info_k11(info) != Some(true) { return None; }`
- flow.rs:152：
  `/// 9 / 10 / 11 all absent (info.net hit E_RATE), or malformed -> poll (≤ 960 s)`
- owner.rs:1176-1178：
  `self.confirm = Some((rec, record_gen)); self.request_tagged("info", "info-confirm", …)`
- owner.rs:1300-1302：
  `pub fn status_view(&self, …) -> StatusView { … status_view_of(self.page_status.as_ref(), self.page_info.as_ref(), …)`
- join2flow.rs:507-513：
  `Fail::NotSent(_) => self.before.clone().map(|mut b| { b.prev_country = None; b }),`
- join2flow.rs:495-502、:524-528：`fail` / `reverted` 都呼叫 `self.persist(...)`
- join2flow.rs:681：
  `Op::Join => self.fail(Fail::NotSent(*code)),`
- store.rs:142：
  `let g = expected_gen + 1;`
- core.dart:169：
  `bool get _eligible => started && fg && !lease && page != Page.other;`
- core.dart:440：`s.extra = o.extra;` 只在 `Res.body`
- home_page.dart:154-156：`_back` → `a.link.setPage(nl.Page.home);`
- nodes.dart:253-265（persist 在步驟迴圈裡 await）、:497-498（`_wait` 計時器自己完成 `_answer`）
- owner.rs:115-126：`NetView` 沒有 generation

### ⚠️ 推論（沒有實跑）
- 節點的 info 實際上多常回錯誤碼，或 info.net 多常被限速：沒有真機數字。M1 的嚴重度建立在「會發生」，不是「常發生」。
- 對一台正在套用 A 的節點送出建立 B，節點會怎麼做（firmware，本 repo 查不到）。
- M3 的修法 a 假設 network/join 回 0 之後，info key 10 立刻就是新的 net id（flow.rs `JoinState::Applied` 的定義支持，但沒在真機量過）。

### ❌ 沒做
- 沒有跑任何測試或 cargo / flutter（唯讀審查）。
- 沒有逐條重驗 A–H 的每一個 MAJOR。
- 沒有看 firmware 端 provd 對 make-network / network/join 的處理。
