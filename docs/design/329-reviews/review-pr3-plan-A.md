# #329 PR 3 實作計畫 v1 — 對抗式審查（審查者 A）

審查對象：`docs/design/329-pr3-plan.md`（v1）。上層：`docs/design/329-app-uiux.md` v12.1。原始碼：`feat/329-pr3` 工作樹（審查期間 HEAD 由 29b0085 前進到 9b00ca6「PR 3 step 1」，只動 `app/test/nodes_update_send_test.dart`）。只讀；沒有改任何檔案（本檔除外），沒有跑測試。

## 結論

**Verdict：REJECT（改版後整份重審）。** 1 個 BLOCKER、8 個 MAJOR、9 個 MINOR。

方向是對的（請求機制整塊搬、舊控制台當 adapter、新頁面走 `BleGate` / `RecordWriter`、D2 延到 PR 6），但：
- 佔用下的登入（§2.2）和已核准設計 §4.3.9 相反，而且把 `core.loginFor` 的行為寫錯（P7）。這條直接打到「認領完立刻建立網路」——從零到組網的第一步。
- 「`_busy` = 佔用 hold」這個搬移最大的坑，計畫只在 P4 列為事實，沒有說 `GateIo` 下它變成什麼。
- 多台迴圈沒有對上 Rust 的硬限制：加入要求網路紀錄「已套用」。
- 網路摘要表照設計字面實作會 fail-open，可能讓使用者建立第二個網路。

---

## §1 事實逐條核對

| # | 結果 | 證據 |
|---|---|---|
| P1 | ✅ 行號正確 | `git show 29b0085:app/lib/nodes.dart` → `194: _tryLogin`、`365: _login`、`511: _ask`、`687: _watchLink` |
| P2 | ✅ 但**不完整** | `:277 final yes = mounted`、`:614 if (nets.length == 1 \|\| !mounted) return nets.first;`：page 不在時選網路回**第一個**，不是「不要」（見 m1） |
| P3 | ✅ | `nodes.dart:261, :764, :1290 storeWriteCas`；`:467, :1026 storeRemove`；`claim_records.dart:43-53` 也是直接呼叫 |
| P4 | ✅ | `raw_use.dart:30-44`：`rawBusy=true` 就是 `lease.hold()`，`rawIdle()` 就是放開 |
| P5 | ✅ | `ble_gate.dart:185 scan(Token? t…)`、`:226 connect(Token? t…)`；`prober.dart:41-157` |
| P6 | ✅ | `grep "writer\."` 只有 `ui/node_page.dart:72,76` 和 `app_link.dart` |
| **P7** | **❌ 錯一半** | 「`core.loginFor` 只決定要試哪些位址」不對。`core.dart:628-747` 的 `LoginFor` 是有狀態的：寫 `isY` / `notY` 備忘（:697-731），把 Y 的狀態改成 `unreachable(identity / refused)`（:712-722），有 N9 例外（`writtenAt` + `n9Login`，:703-705），**同一位址會再試**（`retry` 集合，:689、:705、:725、:731），還有 60 s 預算（:736-741）。「`NodeLink` 沒有入口」這半句對 |
| P8 | ✅ | `lease.dart:73-84`：上限只在 `pageGone` 裡排定 |
| P9 | ✅ | `claim.dart:212-472`；`claim_recovery.dart:165` 的 `class ClaimRecovery` 只 import `services` 與 BLE，沒有 widget |
| P10 | ✅（在 29b0085）；現在已過時 | 9b00ca6 已加 5 個 PR3-1 測試（commit 訊息：「mutate2, 5/5 killed」） |
| P11 | ✅ | `nodes_update_send_test.dart:~400` `RustLib.initMock`、`ReactiveBlePlatform.instance = node` |

---

## BLOCKER

### B1　佔用下的登入（§2.2）違反設計 §4.3.9，從零到組網的第一步會失敗

**情境（真實使用）**：使用者認領 04（3.x），在 3.5 立刻按「建立網路」。
- 認領完，節點換成 RPA 位址（`core4_test.dart:248` RB-CLAIM），而且每 4 s 才輪詢一次新紀錄（設計 N9）。
- 計畫的 `GateIo` 登入是「試過的不再試」+ 沿用 `_tryLogin`：新位址第一次回「解不開」→ 記成試過 → 60 s 後回 NOT_FOUND。這正是舊控制台那句「剛認領完的話，等幾秒再試一次」。
- 設計 §4.3.9 用 N9 例外與「隔 6 s 再試」解決這件事（T-L17）。計畫把它丟了，而且沒有列成偏離。

**其他後果**：
1. **身分不符 / 登入被拒不再結束流程。** `_tryLogin` 收到 `ended` 只 `done(false)`（nodes.dart `case OwnerKind.ended`），會換下一個位址。設計要求顯示身分不符句子、首頁 `unreachable(身分不符)`、記安全紀錄（§4.3.9 表）。
2. **惡意 / 安靜的 BLE 裝置能吃掉整個預算。** `_tryLogin` 等連線 20 s（`.timeout(const Duration(seconds: 20)`）再等登入 20 s，一個不回應的廣播者就吃掉 60 s 裡的 40 s。設計是 msg2 8 s 的規則（§4.3.3-3，`NodeLink.msg2`）。
3. **擁有權。** 備忘與節點狀態的唯一寫入者是 `NodeLink`（設計 §4.1、§4.3.9「備忘與節點狀態只由 NodeLink 寫，流程不碰」）；`OwnerSession` 的擁有者也是 `NodeLink`。計畫讓 `GateIo` 自己登入、自己持有 session，這兩點都沒有列在 §4 的偏離裡，§3.1 擁有權表也沒有「備忘 / 節點狀態」這一列。

**修法**：
- 在 `NodeLink` 寫 `loginFor(lease, Y, {clearNotY})` 驅動器，跑 `core.LoginFor`（排程、備忘、N9、60 s 已寫好並有 core2–core5 測試）。每次嘗試用一個「登入後不讀狀態、把 `OwnerSession` 與 `GateLink` 交出來」的 prober 變體，`loginEnd` 照 `prober.dart` 的對應表。
- `GateIo` 只拿回傳的 session / link。「再試一次」呼叫 `clearNotY: true`。
- 測試：T-L17 / T-L18 / T-S3 在**驅動器**上（不只在 core sim）。負向對照：拿掉 N9 retry，RB-CLAIM 式案例 FAIL；身分不符不結束流程 FAIL；安靜裝置佔滿 60 s FAIL。
- §3.1 補「位址備忘、節點狀態 — 唯一寫入者 `NodeLink`」。

---

## MAJOR

### M1　`_busy` / 佔用 hold 在 `GateIo` 下沒有定義；照現況搬，不是靜默不送就是寫入被拒

**證據**：
- `raw_use.dart:30-44`：設 `_busy` 就等於拿 / 放 `lease.hold()`。
- `_ask` 在 nodes.dart:520-529 有 `if (_busy && !held) return null;`，而且在 `_ask` 的 `finally` 裡 `if (!held) rawIdle()`。
- `_joinNetwork`（:627-634）先 `_busy = true`，選完網路就 `rawIdle()`，再進 `_ask` 重拿。
- `_watchLink`（:692）`_busy` 為真就直接 return。
- `lease.dart:73-78`：`pageGone` 時 busy == 0 就立刻釋放。
- `record_writer.dart:27-33`：釋放後拒絕寫入。

**情境**：`NetworkRun` 想讓整段多台流程「進行中」，用同一個旗標 hold 住佔用 → `_ask` 一進來就 `return null`，不說話。不 hold 的話，台與台之間、或 `_joinNetwork` 選完網路那一刻都是 0，頁面一旦消失（Activity 重建、測試裡的 pop）就立刻釋放，接著的 PersistNet 被 `RecordWriter` 以 `NoLease` 拒絕。

**修法**：
- 把「console 的重入旗標」和「佔用進行中」拆成兩個東西，寫成表：`RawIo` 兩者綁在一起（現況，逐字不變）。`GateIo` 的旗標只擋重入；每個請求與每次 persist 包在 `lease.run`；`NetworkRun` 從第一台到結果頁持有一個 `lease.hold()`。
- 補 T-K3（頁面在 Persist 前消失 → 紀錄寫完）的 `GateIo` 版。負向對照：hold 只綁頁面 → FAIL。

### M2　搬移範圍漏列：共用欄位的其他原語與步驟迴圈設的旁路旗標；step 1 的釘子不夠

**證據**：
- `_askSw`（nodes.dart:1574-1610）直接碰 `_answer`、`_waitFor`、`_waitLine`、`_unclear`、`_track`、`_quiet`、`_session`、`_busy`，是第二個請求原語。
- `_holding`、`_runOp`、`_writeRecord`（:750-797）也共用這些欄位。
- 步驟迴圈設的旁路旗標：`_linkFrom`、`_left`、`_sendAfter`、`_lastInfo` / `_lastHex` / `_lastSas` / `_lastRenewed`（`case OwnerKind.answer`）、`_removedQ`（confirmRemoved）、`_joinreqInFlight`、`_saved`。邀請、隊員、移除、離開、狀態頁都讀它們。
- 計畫 §2.1 只列 P1 那組。

**step 1 沒有釘住的時序**（全都是搬移最容易改壞的地方）：
- `_ask` 寫入失敗 → 重新登入、**只重送一次**（:546-566）。
- 加入 / 建網中斷線 → `_unclearNow()` 的「結果不明」與「沒有寫入或送出」兩種（`SendTrack`）。
- 逾時 → `_drop`。
- ConfirmCountry 期間 `_wait?.cancel()`，答完 `_kick()`。
- `ended` → `_drop`。
- `_watchLink` 遇到 session 換掉 → `_linkUnknown`。

`grep "結果不明\|LINK_LOST\|秒內節點沒有回應" test` 只命中 `member_ui_test.dart`（測的是 helper，不是 `_ask`）與 `nodes_pop_test.dart`。

A1 寫「負向對照用搬移前的版本」：在搬移前的版本上跑，本來就會過，那不是負向對照。負向對照要像 9b00ca6 的做法，每一項給一個突變。

**修法**：
- 列出每個欄位與它的讀者；`_askSw` 一起搬。
- 旁路旗標改成 console 的唯讀 getter，或併進 `_ask` 的回傳結構。
- 上面 6 條時序各補一個釘子 + 突變；邀請、移除、軟體更新的舊測試照樣不改判定（明寫在步驟 2 的通過條件）。

### M3　多台迴圈沒有對上 Rust：加入要求網路「已套用」

**證據**：
- `join2flow.rs:340-341`：`if rec.state != netrec::APPLIED { return Err(End::Refused(Pre::NotApplied)); }`
- `_pickNet` 在 nodes.dart:614 多筆時開對話框。
- pending 網路的建立者被推導成 joining（`owner.rs:108` 的 creator 欄，`:2186` 的測試註解）。

**情境**：
- (a) 第一台不在旁邊 / 建立結果不明 / 自動檢查後仍未套用 → 計畫給「繼續下一台」，後面每台必定 NotApplied。
- (b) 手機留著一筆從沒套用的舊網路（上次結果不明）→ 計畫「有 net 紀錄就加入」→ 首頁第 6 列「加入網路」永遠失敗；正確的下一步是對建立者「檢查網路」。
- (c) 手機有兩筆網路 → 每一台都跳一次選網路對話框。
- (d) 建立者在待辦「加入沒有做完」出現，給的卻是「加入」動作。
- (e) 中途金鑰不能用 / 藍牙關 / 佔用被收回，問「繼續下一台」沒有意義。

**修法**：
- 寫 `NetworkRun` 的狀態機：這次的網路在 4.1 決定一次（net id 固定）；每台開始前重讀那筆紀錄（CAS generation）。
- 建立者失敗 → 「停在這裡」或「改用下一台建立」；未套用 → 先「檢查網路」。
- 致命類（`Refused` / `NoLease` / `StateError` / 藍牙關 / 金鑰）結束整個迴圈，不問繼續。
- 摘要表分流用 `applied` 與 `creator`。
- T-M1 每一條各一案例 + 負向對照。

### M4　網路摘要表 fail-open：Keystore 一失敗就會叫使用者「建立網路」→ 隊伍分裂

**證據**：
- 設計 §4.3.8「解不開的那一筆不進表……用到它的地方當成沒有這筆紀錄」。
- 計畫 §2.4 / §3.2 照抄。
- 3.5 / 3.6 與首頁第 6 列「都沒有 → 建立網路」（設計 §5.1、§5.3）。
- 舊碼自己警告過後果：nodes.dart:603-607「新建網路會讓整隊分成兩個網路，舊節點要重燒」。
- PR 2 的 `_todos` 刻意只用列檔（`home_page.dart:129-141`，D-m9 → unknown）。

**情境**：Keystore 暫時不能用 / 紀錄金鑰失效 → 每一筆都「壞」→ 表是空的 → 「建立網路」→ 使用者建出第二個網路。

**修法**：「有沒有 net / mnet / mpend / claim-pending」只用 `list*`（不解密）決定；解密只用來取名稱與加入中的節點；有任何一筆列得到但解不開 → 中性的「加入網路」+ 原因。測試：`open` 全部丟例外 → 不出現「建立網路」。負向對照：用解密結果決定 → FAIL。

### M5　D1 寫得太空：新 3.x 畫面要的東西 `ClaimPage` 給不出；認領 → 建網的佔用交接沒定義；F41 沒處理

**證據**：
- `ClaimPage` 的進度只有 `_say` 自由文字（claim.dart:154-157），邏輯全在 `_ClaimPageState._claim`（:322-472，含 `mounted` / `setState` / `showDialog`）。
- 3.x 要步驟清單、經過時間、認領到的 id（3.2 暱稱）、成功 / 恢復中 / 失敗的結果，才能接 3.5 / 3.6。
- 原始佔用只在 `RawLeaseScope.dispose` 交回（raw_use.dart:57-66）。
- 設計 §4.4「原始佔用的頁面」寫明 F41「PR 3 換掉這頁時解決」。

**情境**：
- 在 3.5 按「建立網路」時，`ClaimPage` 還在堆疊上 → `NodeLink.acquire` 回 null →「另一個操作還在進行：新增節點」。
- 認領中按返回 → 結果顯示在已關掉的頁面；非 devTrust 版沒有待辦，使用者不知道成功沒有。

**修法**（二擇一）：
- 寫一個 `ClaimController`，把 `_claim` / `_find` / `_recover` 原樣搬出，對外發事件。這是和 OwnerConsole 同級的搬移，要列進步驟、釘子與突變，`claim_*_test` 不改判定。
- 或明寫新畫面只換 `ClaimPage.build` 的樣式，並刪掉「步驟清單 / 經過時間 / 3.2」的承諾。

另外：
- 定義交接：`pushReplacement`，等 `released` 回呼（`NodeLink.released` 讀完紀錄）之後才 `acquire`。測試：認領完立刻建網拿得到佔用。
- F41：認領中加 `PopScope`，或結果進首頁。
- D1 寫進 #329 checklist，掛一個實際會發生的 PR（PR 6 刪的是舊控制台，`ClaimPage` 不會因此消失）。

### M6　範圍洞：T-N2 與設計 PR 3 範圍裡的幾個入口，計畫沒有說去哪

**證據**：
- 設計 §5.1 第 6 列：只有 mnet →「加入網路（隊員）」、只有 mpend →「看我的申請」。
- §5.3 的 3.5 次要按鈕「我是隊員，加入隊長的網路」。
- 待辦「節點加入網路沒有做完 → 4.x 接著做；同一頁有『放棄這次加入』」。
- 「結果不明 → 檢查網路」是一個獨立動作。
- 計畫 §2.3 只有隊長的建立 / 加入；`request_member_join` 是 dev only（`owner.rs:1213-1215` `dev_gate`）。

**修法**：給一張 PR 3 入口 → 去處的表，依版本（dev / dev2 / field、devTrust）分；去舊控制台的要寫明「PR 5 前暫走舊控制台」，或不顯示。T-N2 依這張表判定。

### M7　真機計畫做不到「從零」，而且縮了設計 R-7 的中斷項

**證據**：
- 記憶「04 / 02 都是 N0 member A committed」，也就是兩台都已認領、已在網路裡。
- 設計 §9.2：這一版沒有重置；「弄回未認領的實際做法在開始前另外列」。
- 設計 R-7 每條要做「關藍牙再開 / 節點重開 / 切到背景」三種中斷、X13 對照、「正在連到節點」10 次 9 次 ≤ 20 s。計畫 §8 只寫「R-7 情境 1」。

**修法**：
- 列出把 02 / 04 弄回未認領的做法（重燒 → 新身分、新 QR）及其副作用，取得同意。
- 情境 1 拆成「先一台建立、之後新增第二台再加入」，涵蓋「隊長之後加第三台」那條路。
- 照設計 R-7 補三種中斷與計時判定。

### M8　新頁面要顯示什麼沒有契約：`ConsoleHost` 只有 `say` / `log`，會把舊控制台的句子帶進新畫面

**證據**：
- 舊句子帶舊按鈕名：`_joinUnclear`「稍後在這台按『加入網路』」（nodes.dart:47）。
- `_join` 的「請按『建立網路』，或向隊長要邀請」（:1083-1084）。
- 「操作沒有成功：$e」把例外原文（將包含 `BleGate refused: …`、`RecordWriter: … refused`）顯示出來。
- 設計 T-C4a 檢查新畫面的字；§5.4 結果頁要「逐台：成功 / 失敗原因 / 還沒做」。

**修法**：`OwnerConsole` 對每個請求回傳結構化結果（種類：answer / unclear / notSent / timeout / leaseLost / keyFail …，加 Rust 原句）；新頁面只依 §3.4 規則顯示 Rust 原句與自己的固定字；`say` 行只進技術資訊。T-C4a 涵蓋 4.x。

---

## MINOR

- **m1**　§3.2「`alive()` 為 false → 對話框當成『不要』」不符現況：`_pickNet` :614、`_pickMnet` :1111 回第一筆。實際被 :635 的 `!mounted` 擋住所以無害；文件照實寫，行為不改。
- **m2**　`_login` 呼叫 `blePermissions`，Kotlin 會**彈系統對話框**（MainActivity.kt:145-148 `requestPermissions`）；設計 §4.3.9 只檢查不彈。藍牙關 / 權限收回時要顯示 2.3 / 2.2 並停下，不是「那一台失敗、問繼續」（設計 §7 X16 列）。
- **m3**　`GateLink.state` 在**自己** `close()` 時也會送 false（ble_gate.dart `_on` ← `linkStates`）。若照 `_tryLogin` 把 disconnected 接到 `_lost()`，換台時會多一行 `[LINK_LOST]`，並對等待中的回答 `_endUnclear`。要先取消監聽再 close；補一個測試。
- **m4**　計畫寫「頁面開時拿佔用」：使用者在 4.1 打字期間自動讀取全停。改在按「開始」時拿。已有網路時 4.1 隱藏名稱 / 頻道。勾選清單排除已是成員的節點（避免誤觸 `_sendAfter` 的送新密碼）。
- **m5**　「加入中的節點」和 `node/<id>` 怎麼對上沒寫：`MemberView` 只有 `last4`（舊節點是 ""，owner.rs:79-80）與 `dac_hash`。指定對應鍵；後四碼相同的情況寫明怎麼處理。
- **m6**　T-G5(b) 在 PR 1 沒落地（grep：nodes.dart:261/467/764/1026/1290、claim_records.dart:43-53）。D2 可以接受，但 PR 3 至少對新目錄（`lib/src/flows/`、`lib/ui/`）加原始碼搜尋測試，禁止直接呼叫 `store*`。負向對照：新檔留一個直接呼叫 → FAIL。
- **m7**　改壞對照集中在步驟 7；應該每一步各自附（9b00ca6 已示範）。step 1 在計畫審查前就 commit 了：只是測試，可以接受，但記錄一下。
- **m8**　§3.1 缺 `keepScreenOn`（設計 §4.1 擁有者 = 流程頁）。摘要表在釋放後是非同步重算，要定義「計算中」的顯示（避免短暫顯示舊的「建立網路」）。
- **m9**　`OwnerConsole` 的 `_log('裝置 $id：…')` 印 BLE 位址；`GateIo` 下要經 `NodeLink.mask`（T-S4 / S10）。

---

## D1 / D2 判定

- **D2（舊控制台繼續 `RawIo`）**：**可接受**。原因：同一時間一個佔用；舊控制台 PR 6 刪；PR 1 第六輪 L 已記錄這個偏離（review-pr1-r6-L.md:91）；`writtenNodes` 由 `_changedIds` 的檔案時間補上（node_link.dart:178-181）。條件：m6。
- **D1（認領留在原始佔用）**：**有條件可接受**。安全性和 PR 1 / 2 相同；但計畫的理由「改它不會讓使用者多得到任何東西」不成立，新 3.x 畫面需要認領的結構化狀態（M5）。M5 解掉之前不接受。

## 範圍是否交付「從 0 到組網、不進舊控制台、別人的手機也能用」

修掉 B1、M3、M4、M5、M6 之後，主線（新增節點 → 建立 → 加入多台 → 確認連線）可以不進舊控制台。

但還有三點要在 PR 內文寫明，不能宣稱完整交付：
- 手機 Wi-Fi（5.6）在 PR 4，所以「能拿手機上 TAK」還不行。
- 隊員路徑是 dev only。
- field 版本現在跑不起來（#255）。所以「別人的手機」= 安裝 dev 版。

## 安全（逐 actor）

- **遠端 BLE 攻擊者 / 惡意廣播**：B1-2，安靜裝置佔預算；用設計的 8 s msg2 規則修。B1-1，身分不符要結束流程並記錄。
- **惡意 / 被入侵的節點**：計畫 §6「一台的回答不影響別台的紀錄寫入」不精確，每台加入都 CAS 同一筆 `net/<id>`。被入侵的第 2 台能影響這筆紀錄裡它自己的成員項（加入中 / 國家），第 3 台會讀到它；也能用 ConfirmRemoved / ConfirmCountry 對使用者發問。寫實，並確認每台開始前重讀紀錄（M3）。
- **本機無權限 app**：沒有新的匯出元件或 intent（計畫說明；⚠️ 沒有對 manifest 驗證）。
- **被入侵的對方手機**：只能連著節點讓它不廣播 → NOT_FOUND，現況如此。
- **我們自己的錯**：M1（佔用語意）、M4（fail-open 建第二個網路）、M2（搬移時序）。
- **秘密**：m9。

---

## 我做了什麼

### ✅ 已驗證（附原始輸出）

- 寫入點（P3、m6）：
  ```
  $ grep -rn -E "storeWriteCas|storeWriteSealed|storeRemove|storeKeepCopy" lib
  lib/claim_records.dart:43/49/53 ; lib/nodes.dart:261,467,764,1026,1290 ; lib/src/nodelink/app_link.dart:100-103 ; lib/ui/ui_state.dart:228,232
  ```
- P1 行號：`git show 29b0085:app/lib/nodes.dart | grep -n …` → `194: Future<bool> _tryLogin`、`365: _login`、`511: _ask`、`592: _pickNet`、`687: _watchLink`、`750: _underLease`。
- P7：`core.dart:686-731` 的 `LoginFor.result`。`Res.undecryptable` 在 `now - w < c.p.n9Login` 時 `retry.add`；`Res.noResponse` 也 `retry.add`；`certRejected` → `s.why = Why.identity; end = LoginEnd.identity`。
- `RecordWriter` 只在 node_page 使用：`grep "writer\."` → `lib/ui/node_page.dart:72, :76`。
- 加入要求已套用：`join2flow.rs:340-341`。
- 權限會彈窗：`MainActivity.kt:145-148`（`requestPermissions(blePerms, BLE_REQ)`）。
- step 1 的狀態：`git log` → `9b00ca6 #329 PR 3 step 1: pin the console paths…`，訊息「Negative controls (mutate2, 5/5 killed)」。審查中途看到工作樹有一個未提交突變 `go(plain, gen, true)` → `false`，之後已還原（`git status` 只剩計畫檔未追蹤）。
- 測試覆蓋：`grep -rln "結果不明\|LINK_LOST\|秒內節點沒有回應" test` → 只有 `member_ui_test.dart`、`nodes_pop_test.dart`。

### ⚠️ 推論（沒有實跑）

- B1 的「認領後 60 s 內 NOT_FOUND」：由 N9（設計 :132）、`core4_test` RB-CLAIM 情境與 `_tryLogin` 的 `tried` 集合推得，沒有實跑。
- M1 的「`_ask` 靜默 return / persist 被 `NoLease` 拒」：由程式路徑推得。
- m3 的多一行 `[LINK_LOST]`：由 `BleGate` 的 `linkStates` → `_on(false)` 推得。
- M7 的 02 / 04 現況：來自記憶，沒有上機確認。

### ❌ 沒做

- 沒有跑 `flutter test`（工作樹只讀，跑會寫 `.dart_tool`）；沒有真機。
- 設計 §4.3.1–§4.3.7 只讀到與本計畫相關的部分；`claim_recovery.dart` 只看了類別邊界。
- 沒有驗證 AndroidManifest 有沒有新的匯出元件（計畫說沒有新元件）。
