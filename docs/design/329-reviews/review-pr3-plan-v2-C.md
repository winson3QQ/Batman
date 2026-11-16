# #329 PR 3 實作計畫 v2 — 對抗式審查（審查者 C，獨立）

審查對象：`docs/design/329-pr3-plan.md`（v2，commit 8892836，branch `feat/329-pr3`）。上層：`docs/design/329-app-uiux.md` v12.1。v1 審查：`review-pr3-plan-A.md`、`-B.md`。
只讀；沒有改任何檔案（本檔除外），沒有跑測試、沒有上機。`git status --short` 審查開始時乾淨。

## 結論

**Verdict：APPROVE-WITH-CHANGES。** 0 BLOCKER、5 MAJOR、11 MINOR。

v1 的兩個 BLOCKER 在結構上解掉了：登入改成 `NodeLink` 驅動 `core.LoginFor` 再交接；「建立」改成在佔用下重新列檔、fail-closed。改成「從舊控制台複製」也是對的，比搬移風險小，而且 PR 6 會刪掉舊的。從 0 到組網（隊長那條路）可以不經過舊控制台。

但還有五個 MAJOR，每個都會在真實使用中出事：
- `loginFor` 的驅動器漏了掃描。
- `Refused` 被當成佔用被收回。
- 4.1 和建立閘門的分流對不起來。
- 未套用的網路找不到建立者。
- 建立閘門沒有改壞對照。

照使用者規則，MAJOR 修完要整份再審一次。不過這五條都是局部修正，不需要改結構；步驟 2–3 可以在修文時同時開工，但步驟 4–5 要等 M3、M4、M5 寫進計畫才開工。

---

## v1 審查逐條是否真的解掉（§11 對照）

| v1 | 判定 | 說明 |
|---|---|---|
| A-B1 / B-B1 登入 | ⚠️ 方向對，有洞 | 見 **M1**（沒有掃描、`_run` / `_pump` 不能直接沿用）、m1 |
| B-B2 建立條件 | ⚠️ 大致解掉 | 有兩個洞：**M3**（中性入口和只有 mnet 的手機）、**M5**（沒有改壞對照） |
| A-M1 佔用 / 重入 | ✅ | §3.4 把重入旗標和 hold 分開了 |
| A-M2 / B-M-2 搬移邊界 | ✅ | 改成複製。`_sendUpdateFor` 已列入 |
| A-M3 / B-M-1 多台迴圈 | ✅ | 目標網路只決定一次；建立者失敗就整個停 |
| A-M4 摘要表 fail-open | ✅ | 有沒有紀錄只看列檔 |
| A-M5 / B-M-3 認領交接 | ⚠️ | `openRawPage` 的回傳值與釋放時機沒處理，見 m2 |
| A-M6 入口 | ⚠️ | 中性入口去 4.1 的情況和「只有 mnet 不會進這頁」矛盾，見 M3 |
| A-M7 真機 | ⚠️ | 少了 X13 的那次中斷；做完後怎麼回 N0 沒寫，見 m10 |
| A-M8 結果契約 | ⚠️ | `leaseLost` 的分類錯了，見 **M2** |
| B-M-4 生命週期 | ⚠️ | 建立做到一半的那一列找不到節點，見 **M4** |
| B-M-5 / A-m7 負向對照 | ⚠️ | 每一步都有改壞，但 B-2 本身沒有，見 **M5** |
| B-M-6 擁有權 | ⚠️ | `keepScreenOn` 兩處寫法互相矛盾，見 m5 |
| A-m6 / B-m-6 原始碼鎖 | ❌ 照寫會失敗 | `lib/ui/ui_state.dart` 本來就合法呼叫這些函式，見 m3 |
| B-m-8 `Refused` / `NoLease` | ❌ | 見 M2 |
| 其他 MINOR（A-m1–m5、m8、m9；B-m-1–m-7） | ✅ | §1、§2.3、§2.4、§2.7、§6 已處理 |

---

## MAJOR

### M1　`loginFor` 驅動器沒有掃描，也不能沿用 `_run` / `_pump`；照 §2.1 的字面寫，登入永遠 `notFound`

**情境**：第一次使用的人在 4.1 按「開始」。`acquire` 先 `_dropAll`，把 NodeLink 的掃描停掉。佔用下 `reg.nodeLinkToken == null`。`loginFor` 開始後沒有任何位址被 `onScan`，`LoginFor.next()` 一直回 null，60 s 後 `notFound`。

**證據**：
- `core.dart` 的 `LoginFor.onScan` / `seen`：`next()` 只從 `seen` 挑位址。
- `node_link.dart:157`：佔用期間 NodeLink 的 token 是 null。
- `node_link.dart:260`：掃描用 `reg.nodeLinkToken`。
- `node_link.dart:296`：`_run` 用 `reg.nodeLinkToken` 連線（佔用下會被 `Refused` → `noResponse`）。
- `node_link.dart:322`：`_run` 回報給 `core.result`，不是 `LoginFor.result`。
- `node_link.dart:215`：`_pump` 遇到 `_attempt` 不是 `core.running` 就 `_abort()`。所以如果 `loginFor` 共用 `_attempt` / `_link`，會被 `_pump` 砍掉。
- `core.dart:288-292`：`setRadio` 從外面把 `LoginFor.end` 設成 `precondition`。驅動器要在這時被叫醒，現在沒有掛點。

計畫 §2.1 只寫 `BleGate.connect(lease.token, addr)`。A2 寫「同一份程式碼抽成共用函式」，但沒有寫掃描，也沒有寫驅動器自己的計時與狀態欄位。

**修法**：§2.1 補上以下幾點：
1. `loginFor` 用 `gate.scan(lease.token, …)` 自己掃描，每個位址呼叫 `LoginFor.onScan`；成功、失敗或結束時停掉掃描（交接後不能留著掃描）。
2. 用自己的 `_loginAttempt` / `_loginLink` / `_loginTimer`，不碰 `_attempt` / `_link` / `_timer`。照 `LoginFor.wakeAt` 自己排計時。
3. `radio()` 之後要叫醒驅動器，讓 `precondition` 立刻結束登入。
4. 每次嘗試前檢查 `lease.valid`。

測試要包含：假 `BleGate` 只在掃描後送出位址，T-L17 端到端要通過。改壞對照：不掃描，或用 `nodeLinkToken` → FAIL。

### M2　`ConsoleResult.leaseLost` 用例外型別 `Refused` 判斷，會把節點斷線當成佔用被收回

**情境**：多台建網，第 2 台送出加入的過程中節點重開。`GateLink.write` 丟 `Refused('write on a closed link or a revoked token')`，計畫把它分成 `leaseLost`，結果整個流程停下，顯示「這個操作被中斷了」。實際上應該是那一台 `unclear`（結果不明）或 `notSent`，問「繼續 / 停」，結果頁給「再試這一台」。同樣的事也會發生在 `requestMtu` / `read` / `subscribe`。

**證據**：
- `ble_gate.dart` `GateLink._usable`：`if (!_open || _down || !gate.reg.valid(token)) throw Refused(...)`，斷線和收回丟的是同一個例外。
- 計畫 §2.2.1：`leaseLost | NoLease / Refused`。
- 現況 `_ask` 對寫入失敗的處理是 unclear / 重新登入一次（nodes.dart:533-566），不看例外型別。

**修法**：用 `!lease.valid`（或 `reg.current` 不是這個佔用）判斷 `leaseLost`。其他 `Refused` 照寫入失敗走 `unclear` / `notSent` / 重送一次。測試：節點在寫入時斷線 → 那一台 `unclear`、流程問繼續。改壞對照：照型別分類 → FAIL。另外收回佔用要有一例 → `leaseLost`。

### M3　4.1 的表單和建立閘門的分流對不起來：中性入口、只有 mnet、解不開的手機進到 4.1 之後沒有定義

**情境**：
- (a) 手機只有 mnet（隊員），摘要表還在計算，或其中一筆打不開。§2.5 第一列把中性「加入網路」導到新頁 4.1。§2.3 說 4.1「沒有 net 檔時顯示名稱 / 頻道」，於是隊員看到建立網路的表單。按開始後閘門看到 mnet → 「加入」，目標是「4.1 選的 net」，可是根本沒有 net。§2.3 寫「只有 mnet / mpend 的手機不會進這頁」，和 §2.5 第一列矛盾。
- (b) 紀錄金鑰失效（Keystore 失效，檔案還在）：§2.5 →「有打不開的」→ 4.1。4.1「只列已套用的」是空的，使用者沒有東西可選，不知道能不能按開始。警告要等按了開始才出現，而且 4.1 用什麼來源決定顯示「有沒有 net 檔」也沒寫（摘要表正在計算中）。

**證據**：計畫 §2.3（4.1 的兩種表單）、§2.3 閘門第二點的括號、§2.5 第一列。

**修法**：
- 4.1 開頁時自己列一次檔（不解密，不需要佔用），決定表單：
  - 0 檔 → 建立表單；
  - 有 net 而且有已套用、打得開的 → 加入表單；
  - 只有 mnet / mpend → 不顯示表單，顯示 §2.5 那一列的句子（dev 給舊控制台按鈕）；
  - 列不出來，或有 net 但都打不開 / 未套用 → 直接顯示重裝警告或「檢查網路」，不給「開始」。
- 開始時的閘門照舊（佔用下重新列檔）。表單是「建立」而閘門判定「加入」時（兩次之間多了檔案），不開始，請使用者重新進入。
- 測試：只有 mnet 加上摘要計算中 → 4.1 不出現名稱欄、`requestMakeNetwork` / `requestJoinNetwork` 都沒有被呼叫。改壞對照：4.1 用摘要表決定 → FAIL。

### M4　「建立網路沒有確認完」與第 6 列「檢查網路」找不到建立者：未套用的 net 紀錄沒有 device id

**情境**：建立做到一半 app 被殺（§3.3「net 已寫、未套用」那一列，T-M2(b)）。回來後待辦或第 6 列要「對建立者 `confirmNetwork`，單台」，但沒有寫怎麼知道建立者是手機裡哪一筆 `node/<id>`。§2.7 對「加入中」用 `last4` 對應，而**未套用的紀錄裡建立者的 `last4` 一定是空的**。

**證據**：
- `owner.rs` `join_step` 的 `J::PersistNet(rec)` → `NetRec::made(rec)`（`netrec.rs:375-377`：`list: None`）。
- `members()` 在 `list == None` 時走 `v1_members`（`netrec.rs:391-396`）→ `member_base` 的 `device_id: None`（`netrec.rs:212`）→ `MemberView.last4 = ""`（`owner.rs` `net_summary`）。
- device id 只在收到 Applied 時才補上（`owner.rs` `J::Done(Replied(Applied))` 那段 `m.device_id = device_id.clone()`）。
- 計畫 P14 說 `MemberView` 只有 `last4` / `joining` / `approved` / `creator`，漏了 `name` 與 `dacHash`。建立時的 `name = "node-<last4>"`（`owner.rs:1080` `node_name: format!("node-{}", self.last4)`）。

**修法**：
- 「檢查網路」的對象改成：
  1. `creator` 成員的 `last4`，空的話從 `name` 的 `node-xxxx` 取後四碼（⚠️ 開工時確認 v1 members 的 name 就是這個值），對上這支手機唯一一筆 `node/` 紀錄就用它；
  2. 對不上或對上多筆 → 讓使用者從節點清單選一台。檢查本身是唯讀比對（`netrec::confirm`），對錯台只會「不符、不寫」。
- §2.7 那一列「自己是建立者」改成「有 net 而且 `applied = false`」。
- 測試：pending 紀錄（`list: None`）→ 待辦點下去對到正確的節點；兩筆 `node/` 後四碼相同 → 讓使用者選。改壞對照：只用 `last4` → 沒有對象 → FAIL。

### M5　B-2（v1 的 BLOCKER）本身沒有改壞對照

**證據**：§7 第 5 步的改壞只有「建立者未套用時繼續、前提類問繼續、換台不等關連線、對話框返回當繼續」。第 4 步的改壞只針對摘要表（「用解密結果決定」）。佔用下列檔的建立閘門是這次真正防止整隊分裂的機制，卻沒有一個突變證明測試抓得到它。

**修法**：第 5 步加以下改壞，各一個都要 FAIL：
- (a) 閘門改用摘要表、不在佔用下重新列檔（測試：摘要表顯示 0 檔，但開始前寫入一筆 net）；
- (b) 列檔丟例外時當成空的；
- (c) 只看 net、不看 mnet / mpend；
- (d) 目標 net 打不開時改走建立。

---

## MINOR

- **m1　`LoginResult` 和 `core` 的 `LoginEnd` 對不上。** `core.dart` 有 `LoginEnd.precondition`（:636、:291），沒有 `keys`；金鑰失敗是經 `keyError` → `radio(keyOk:false)` → `precondition` 進來的。另外設計 §4.3.9 的前提要求「`KeyGate` 即時檢查登入用的金鑰」（現況 `_login` 每次都讀），計畫 §2.1 沒寫。請照 `LoginEnd` 列結果，並在 `loginFor` 開始前讀一次 `KeyAbilities`。
- **m2　`ClaimDone` 交不出去，交接時機也要再寫清楚。**
  - `openRawPage` 推的是 `MaterialPageRoute<void>`，回傳的是「佔用者名稱」，pop 的值被丟掉（`raw_use.dart:73-82`）；`openUnderLease`（`home_page.dart:47-61`）、`settings_page.dart:48` 都經它。要改成泛型並回傳頁面結果，改壞對照：`ClaimDone` 被丟掉 → 3.2 不出現。
  - 路由在 pop 時就完成，佔用到 `RawLeaseScope.dispose`（退場動畫之後）才交回。如果那時 `released` 還沒發生，`acquire` 第一行 `reg.current != null` 會直接回 null。
  - 「等上一個 `released`」要有上限（例如 5 s，和「正在結束上一個讀取…」同一個上限）；`readRecords` 的平台呼叫不回來時，`acquire` 會一直掛著。
- **m3　D2 的原始碼鎖照寫會擋到 `UiState`。** `lib/ui/ui_state.dart:228`、`:232` 呼叫 `storeWriteCas` / `storeRemove`，設計 §4.4 / §4.6 明文允許。鎖要寫成「`lib/src/flows/`、`lib/ui/`，`ui_state.dart` 除外」。
- **m4　`ClaimPage` 加 `PopScope` 是對設計的偏離，沒有列在 §4。** 設計 §4.4「原始佔用的頁面」寫「不加 `PopScope`」，理由是認領（90 s）與恢復（最長 300 s）期間按返回沒有反應。若要加，請列為 D4 並說明代價；否則用「結果交給首頁」解 F41。
- **m5　`keepScreenOn`、佔用、連線在結果頁上留到什麼時候，寫法前後矛盾。** §3.1 寫「等待開始時開，`finally` 關」，§2.3 寫「離開結果頁時關」。結果頁一直開著時：
  - 最後一台的 `LoginHandoff` 還連著，那台節點不廣播；
  - 佔用沒有上限（頁面還在，P8），自動讀取一直停著；
  - 螢幕一直亮著。

  建議進入結果頁時就 `h.close()`、關掉 `keepScreenOn`。佔用照設計 §5.4 留到最後一頁，但結果頁的「再試這一台」/「檢查網路」要寫明重用同一個佔用。
- **m6　P14 不完整。** `MemberView` 還有 `name`、`prevCountry`、`dacHash`（`owner.dart:243-270`）。M4 要用到 `name`。
- **m7　A3 / A5 現在就能用原始碼回答，不必等到開工。**
  - **A3**：收到 Applied 時就寫入已套用的紀錄（`owner.rs` `join_step` 的 Applied 分支 → `persist_step`）；結果不明（ReadInfo）時 Rust 自己呼叫 `check_network()`。只有兩種情況會停在未套用：寫入失敗（「節點已套用，手機紀錄沒存好…請按『檢查網路』」），以及檢查也讀不到。計畫的「自動 `confirmNetwork` 一次」在 ReadInfo 的情況下會和 Rust 重複做一次，應該只在 Rust 句子要求「檢查網路」時才做。
  - **A5**：成立。`join2flow.rs` 的 `with_entry(&h, …)` 只換掉這台節點自己的項目，`h = dac_hash(驗證過的 node_cert)`（:345-365、:445-458）；國家只接受兩個大寫字母（:285-288）；`mesh_addr` 經 `teamview::gate`，目前 `WRITE_MESH_ADDR` 只在測試 feature 打開（teamview.rs:16）。附這些行號，不用標 ⚠️。
- **m8　Dart 列目錄的規則要和 Rust 一致。** `list_kind` 濾掉 `.` 開頭的檔名（`owner.rs:43`；暫存檔是 `.name.tmp-…`，`store.rs:118`）。Dart 端也要濾，否則判定會不一致。另外要寫明：目錄不存在 = 空，其他 `FileSystemException` = 列不出來（⚠️ Dart `Directory.exists` 遇到非 ENOENT 錯誤的行為沒有實測）。
- **m9　藍牙關掉時事件順序會造成誤判。** 斷線可能比 `setRadio(bluetooth:false)` 先到，那一台先被當成 `unclear`，先問「繼續 / 停」；按繼續後下一台才得到 `precondition`。建議那一台失敗後先看 `core.blocked`，再決定是否詢問。T-M1(d) 要涵蓋這個順序。
- **m10　真機（§8）缺兩件事。**
  - 設計 R-7 另外指定的 X13：建網後「正在確認節點連上了」期間切到背景 30 s，再和 main 的 app 對照。
  - 用 `prov-bench-s0-254.sh unclaimed` 讓 02 / 04 離開 N0 後，daily-validation 依賴 N0 的項目會受影響。場次結束後怎麼回 N0（或讓兩台留在 app 建的網路）要列在副作用清單裡。
- **m11　交接細節。** `SessionProber` 在 `finally` 裡取消訂閱並 `dispose` session（`prober.dart:160-175`），`HandoffProber` 成功時不能這樣做。也要取消 20 s 的 `answer` 計時器，以及 `due` / `cancelled` 的回呼，把同一個訂閱用 `onData` 換給 `OwnerConsole`，不要重新訂閱，避免漏掉訊框或重寫 CCCD。`_ask` 要重新登入時，先 `await h.close()` 再呼叫 `loginFor`（一次只能有一條連線，`ble_gate.dart` `connect`）。

---

## 事實核對（§1、§5）

| # | 判定 | 證據 |
|---|---|---|
| P1 | ✅ | nodes.dart `_tryLogin`:194、`_login`:365、`_ask`:511、`_watchLink`:687、`_writeRecord`:760、`_sendUpdateFor`:1567 |
| P2 | ✅ | `_say`:157-160 → `_log` → `debugPrint`（:30）；`:277 mounted`；`:614 !mounted → nets.first` |
| P3 | ✅ | grep：nodes.dart:261、:467、:764、:1026、:1290；claim_records.dart:43、:49、:53 |
| P4 | ✅ | raw_use.dart:25-44 |
| P5 | ✅，但不足以支撐 §2.1 | `scan`/`connect` 都要 token；佔用下也要掃描（M1） |
| P6 | ✅ | record_writer.dart:27-44 |
| P7 | ✅ | core.dart:628-748；node_link.dart 沒有 `loginFor` |
| P8 | ✅ | lease.dart:73-83 |
| P9 | ✅（沿用 A 的核對） | — |
| P10 | ✅ | `git show --stat 9b00ca6`：commit 訊息寫「mutate2, 5/5 killed」；nodes_update_send_test.dart:500-549 |
| P11 | ✅ | join2flow.rs:340-341 |
| P12 | ✅ | owner.rs:41-47 `unwrap_or_default()` |
| P13 | ✅ | node_link.dart:184-190；core.dart:252-256（`writtenAt` 只在 `releaseLease` 設定） |
| P14 | ⚠️ 不完整 | 見 m6、M4 |
| P15 | ✅ | owner.rs:1213-1215 `dev_gate()` |
| P16 | ✅ | home_logic.dart:92-96；home_page.dart `_act` 的 `joinNetwork \|\| makeNetwork \|\| seeRequest \|\| joinTeam` → `NodesPage` |
| A1 | ⚠️ | 修好 M1 之後才成立。另外 code 的 `n9Login` 是 10 s（core.dart:20），設計寫 30 s（:410、:560）；PR 3 的 3.2 + 4.1 通常會超過 10 s，到時節點早已輪詢過，N9 在這條路徑上影響小（推論） |
| A2 | ❌ 寫法不成立 | M1 |
| A3 | 可由原始碼回答 | m7 |
| A4 | ✅ | lease.dart:73-83 |
| A5 | ✅ 成立 | m7 |

**題目指定要查的幾點**：
- **NodeLink 能不能用現有 `_run` / prober 驅動 `LoginFor` 並乾淨地交接**：不能直接沿用（M1、m11）。要另寫一個小驅動器，自己掃描、自己排計時，prober 的步驟迴圈可以共用。
- **`acquire` 等 `released` 會不會死結**：不會死結，`readRecords` 不需要佔用。但需要上限，也蓋不到「佔用還沒交回」的情況（m2）。它確實修掉 `writtenAt` 沒設定的問題。
- **Dart 列目錄和 Rust 的位置是否一致**：路徑一致，都是 `<filesDir>/records/{net,mnet,mpend,claim-pending}`（nodes.dart:169；member.rs:331-341；simple.rs:32）。要濾掉 `.` 開頭的檔案（m8）。用 Dart `Directory` 分得出「空」和「讀不到」，Rust `list_kind` 分不出來（P12）。
- **加入需要網路已套用**：✅ join2flow.rs:340-341（member 模式例外，PR 3 不用）。
- **被入侵的節點能改多少**：只能改共用 net 紀錄裡它自己的那一項（m7 的證據）；還能讓使用者看到國家 / 加回的問題（國家字串經過過濾）、讓那一台結果不明或失敗、對連線檢查謊報「已連上」。
- **`ClaimPage` pop `ClaimDone` 搭配 `openRawPage` / `RawLeaseScope`**：照現況不行（m2）。

## 生命週期（補充計畫 §3.3）

| 情況 | 判定 |
|---|---|
| 安裝 / 第一次（兩台新節點） | M1 修好後可以走完；摘要表還在計算時 3.5 會顯示中性按鈕（M3 處理） |
| 隊長之後加第三台 | ✅ 3.6 → 4.1 加入；目標固定、每台開始前重讀 |
| 只有匯入隊伍網路（mnet）的手機 | ❌ M3(a) |
| 重裝 / 紀錄金鑰失效 | 真的重裝會清掉 filesDir（備份關閉，F9），節點紀錄也一起沒了，要重新認領，不會分裂。金鑰失效時檔案還在 → M3(b) |
| 建立 / 加入中被殺 | 加入 ✅（§2.7）；建立 ❌ M4 |
| 切背景 / 關螢幕 | ✅（`keepScreenOn`；行程還在就照跑）；結果頁的部分見 m5 |
| 藍牙關 | ⚠️ m9 |
| 節點重開 | ❌ M2 |
| 同一支手機上的 dev2 | ✅ 那一台 `noLink` → 問繼續 |
| 惡意 BLE 廣播 | ✅ `LoginFor` 對每個位址最多握手一次（N9 的 10 s 內例外）、8 s msg2；輪換 RPA 的多個假裝置仍能耗光 60 s（設計已接受的 DoS） |
| 佔用被收回（420 s） | ✅ 但要用 `lease.valid` 判斷（M2） |
| 升級 / 回退 / 降級 | ✅ 沒有新的持久狀態，紀錄格式不變 |

## 安全摘要

- **權限**：新路徑都在 app 內，沒有新的平台方法、匯出元件或路徑輸入（⚠️ 沒有對 AndroidManifest 驗證）。
- **沒有佔用時 fail-closed**：`BleGate._gate`、`RecordWriter._check` ✅。
- **最大的完整性風險**仍是錯誤的「建立」：佔用下的閘門設計正確，但缺改壞對照（M5），而且 4.1 有一條路會讓隊員看到建立表單（M3）。
- **秘密**：`OwnerConsole` 的文字紀錄只寫種類、代碼、後四碼 ✅。`Refused` / `NoLease` 的 `toString` 不含位址 ✅。
- **舊控制台**（設定 → 舊版控制台）仍能在沒有閘門的情況下建立網路（D2 的現況，只在 dev / 設定裡），列入已知限制即可。

## 是否是最小必要

- 大致是。`HandoffProber`、`OwnerConsole`（複製）、`NetworkRun`、摘要表都是設計要求，或是修 v1 BLOCKER 所必需。
- 唯一多出來的是「建立後自動 `confirmNetwork`」，在 ReadInfo 的情況下和 Rust 自己做的重複（m7），建議縮成「只在 Rust 句子要求檢查網路時才做」。
- `ClaimPage` 的 `PopScope` 是新增的機制，而且違反設計（m4）。

---

## 我做了什麼

### ✅ 已驗證（附原始輸出）

- 寫入點：`grep -rn "storeWriteCas|storeRemove|storeWriteSealed|storeKeepCopy" lib/ui lib/src` →
  ```
  lib/ui/ui_state.dart:228:    return (await storeWriteCas(dir: dir, rel: uiRel, ...
  lib/ui/ui_state.dart:232:  Future<void> remove() => storeRemove(dir: dir, rel: uiRel);
  lib/src/nodelink/app_link.dart:100-103 (RecordStore wiring)
  ```
  （m3）
- `GateLink._usable`：`if (!_open || _down || !gate.reg.valid(token)) throw Refused('$what on a closed link or a revoked token');`（M2）
- `NetRec::made`：`NetRec { base, state: PENDING.into(), list: None, ... }`（netrec.rs:375-377）；`member_base` 的 `device_id: None`（netrec.rs:212）（M4）
- `owner.rs:1080`：`node_name: format!("node-{}", self.last4)`（M4、m6）
- `LoginFor.next` 只從 `seen` 挑位址；`onScan` 是唯一加入的方法（core.dart:660-689）（M1）
- `node_link.dart:157`、`:260`、`:296` 用 `reg.nodeLinkToken`；`lease.dart:120` 寫明佔用下它是 null（M1）
- `openRawPage` 推 `MaterialPageRoute<void>`，回傳 `String?`（raw_use.dart:73-82）（m2）
- `join2flow.rs:340-341` NotApplied；`with_entry(&h, …)` 只換自己的項目；`country_of` 只接受兩個大寫字母（:285-288）；`WRITE_MESH_ADDR = cfg!(feature = "team-write")`（m7）
- `list_kind` 濾 `.`（owner.rs:43）；`list_pends` / `list_mnets` 在 member.rs:331-341；暫存檔名 `.{name}.tmp-…`（store.rs:118）；`sweep_temps` 在啟動時清掉（main.dart:194）（m8）
- `git show --stat 9b00ca6`：「Negative controls (mutate2, 5/5 killed)」（P10）
- `scripts/dv/prov-bench-s0-254.sh` 存在，有 `unclaimed:04|unclaimed:02` 分支（:78-79）

### ⚠️ 推論（沒有實跑）

- M1 的「60 s `notFound`」：由程式路徑推得，沒有跑測試。
- M2 的「節點重開時寫入丟 `Refused`」：由 `_usable` 與 `linkStates → _downNow` 推得。
- M4 的「v1 members 的 `name` 是 `node-<last4>`」：由 make-network 的 `node_name` 推得，沒有讀 `joinflow` 怎麼把它放進 key 8。
- A1：PR 3 路徑上通常超過 `n9Login` 的 10 s，是由畫面步驟推估。
- Dart `Directory.exists` 對非 ENOENT 錯誤的行為。
- `prov-bench-s0-254.sh unclaimed` 跑完後節點真的是未認領、不在 N0：只讀了檔頭註解。

### ❌ 沒做

- 沒有跑 `flutter test` / `cargo test`（只讀審查）；沒有真機。
- 沒有讀 AndroidManifest；沒有逐行讀 `claim.dart` 的 `_claim` / `_recover`（沿用 A 的核對）；沒有讀設計 §9.1 的 T-M1 / T-M2 原文逐條對表。
