# #329 PR 3 實作計畫 v1 — 審查 B（獨立、對抗式）

審查對象：`docs/design/329-pr3-plan.md`（v1，未追蹤檔）。上層設計：`docs/design/329-app-uiux.md` v12.1。原始碼：branch `feat/329-pr3`，HEAD = 29b0085（= origin/main）。
審查期間工作樹另有作者正在改的檔：`app/lib/nodes.dart`（拿掉 `_joinNetwork` 結尾的 `await _watchLink();`，看起來是 step 1 的改壞對照）與 `app/test/nodes_update_send_test.dart`（+115 行「PR3-1」測試）。我只讀，沒有跑測試（作者同時在改，跑會互相干擾）。

**判定：REJECT**（2 個 BLOCKER、6 個 MAJOR；改版後請整份重審，不只看差異）。

---

## BLOCKER

### B-1 `GateIo` 的登入不是設計 §4.3.9 的 `loginFor`，而且計畫把現有的錯誤原樣帶進 `BleGate`

**情境（第一次使用的人、兩台新節點）**：3.4 認領完 → 3.5 主要按鈕「建立網路」→ 4.1 → 立刻登入第一台。節點每 4 s 才輪詢到新紀錄（N9），前幾秒的嘗試回「解不開」。

**證據**
- 計畫 §2.2：「候選位址照 `core.loginFor` 的順序（『是 Y』優先、**試過的不再試**），每個候選 `BleGate.connect`，登入步驟**沿用 `_tryLogin` 的步驟迴圈**…上限 60 s（現況）」。P7 把 `core.loginFor` 說成「只決定要試哪些位址」。
- 實際 `core.dart:628-748`：`LoginFor` 是完整的狀態機，**同一位址可以重試**（`_ok(a) = !tried.contains(a) || retry.contains(a)`，:666；`freeAt = now + gap(6 s)`，:694），N9 視窗內「解不開」放進 `retry`（:702-705，`n9Login = 10000`，:20），身分不符會**寫首頁狀態** `s.kind = unreachable / why = identity`（:711-716），還有 60 s `tick`（:737-742）。它還寫 `c.isY` / `c.notY`（NodeLink 的備忘）。
- 設計 §4.3.9：入口是 `NodeLink.loginFor(佔用, Y)`，「備忘與節點狀態只由 `NodeLink` 寫，流程不碰」；嘗試規則同 §4.3.3（**8 s 收到 msg2**、同位址斷線後隔 6 s）；T-L17 的負向對照**正是**「照現況 `_login`（每個位址 60 s 只試一次）→ 60 s 後 NOT_FOUND → FAIL」（設計 :933）。
- 現況 `_login`（nodes.dart:365-429）：`tried.add(d.id)` 一個位址只試一次；`_tryLogin`（:194-363）每次嘗試最長 20 s 等連上 + 20 s 等登入（:205、:347），沒有 8 s msg2 預算。
- PR 1 審查已記錄這個缺口：review-pr1-A.md:180「(e) `loginFor` 只在 core，沒有接上 driver」；`node_link.dart` 全檔沒有 `loginFor`（✅ 讀過全檔 1-359）。
- `_tryLogin` 連上之後 `requestMtu` / 讀 ctrl / `frameLimit` 丟例外時，`conn` 沒取消（#329 殘項第 120 行，第四輪 G-m3；nodes.dart:209-211 在 `_conn` 指派之前）。在原始佔用下只是節點晚點廣播；換到 `BleGate` 之後，那條沒關的 `GateLink` 佔住唯一的連線格（ble_gate.dart:228-231 `a link is already open`），**之後每一個候選都被拒**，整個登入失敗到佔用釋放為止。計畫寫「行為不變的搬移」，就是把這個錯搬進 `GateIo`。

**後果**
1. 「認領完立刻建網」照現況會 60 s NOT_FOUND（現有句子還叫使用者「等幾秒再試」）。PR 3 正是第一個把這兩步接在一起的 PR。
2. 如果 `GateIo` 改成從外面驅動 `core.loginFor`，`OwnerConsole` 就變成 `NodeLink` 記憶體（`isY`/`notY`/`states`）的第二個寫入者：違反設計 §4.1 與本計畫 §3.1。
3. 惡意 BLE 裝置廣播 provd UUID：用 `_tryLogin` 的時序，兩三個「接受連線但不回答」的裝置就能吃光 60 s（每個 20+20 s）；`LoginFor` 的 8 s 預算加上「不是 Y」備忘可以擋住。
4. T-S3 的 `loginFor` 案例（身分不符要更新首頁那台的狀態）不會成立。

**修法**
- 在 `NodeLink` 加 `loginFor(Lease, id, {clearNotY})`：重用 `_run` 的連線與 8 s 預算來驅動 `core.loginFor` 的 `next / result / tick / wakeAt`；探測改用「登入到 `LoggedIn` 就停」的版本，不讀狀態。成功時把 `(GateLink, OwnerSession, 已訂閱的 TX 串流)` 交給呼叫者。`GateIo` 只呼叫它。這樣備忘的寫入者仍然只有 `NodeLink`。
- 計畫要寫清楚交接契約：交出去之後 TX 訂閱與 session 歸誰；交接失敗時誰關連線；`OwnerSession` 誰 `dispose`。
- 每一次失敗的嘗試都要 `await GateLink.close()` 之後才試下一個（`NodeLink._run` 已經這樣做，node_link.dart:317）。
- 測試：T-L17 / T-L18 / T-S3（loginFor 那一例）要走 `NodeLink` + `GateIo` 端到端（不只 core2_test 的 core 層）。負向對照：換回 `_login` 的迴圈 → FAIL；`requestMtu` 丟例外而不關連線 → 下一個候選被 `BleGate` 拒 → FAIL。

### B-2 「建立還是加入」由什麼決定沒寫；幾條真實路徑會在已經有網路的手機上再建一個網路（整隊分裂）

**情境 A（隊員手機）**：手機只有 mnet。節點顯示「還沒加入隊伍網路」→ 首頁第 6 列的按鈕是 `joinNetwork`（home_logic.dart:93：`net || mnet || unknown → joinNetwork`）→ 計畫 §2.6「第 6 列…改開新頁」→ `NetworkRun`「第一台建立（沒有 net 紀錄時）」→ 在隊員的節點上**建立一個新網路**。現況的舊控制台會走 `_join` 分流（nodes.dart:1065-1094，T-N2：只有 mnet → 隊員的加入）。
**情境 B（重裝 app / 紀錄金鑰遺失）**：net 檔案還在但打不開。設計 §4.3.8 和計畫 §2.4 都說「壞的一筆不進表」→ 摘要表看起來「沒有 net」→ 3.5 / 3.6 與 `NetworkRun` 給「建立網路」。現況 `_pickNet(forJoin:true)` 在這種情況會明確警告：「若 App 重裝過：新建網路會讓整隊分成兩個網路，舊節點要重燒」（nodes.dart:609-612）。
**情境 C（列目錄失敗）**：計畫 §3.2 說「算不出來（列檔失敗）→ `unknown`，中性的『加入網路』」。但 Rust `list_kind` 讀不到目錄時回空清單、從不報錯（owner.rs:41-47 `unwrap_or_default()`，✅ 讀過）。所以 `unknown` 永遠碰不到，結果是「沒有紀錄」→「建立網路」。這正是 #329 PR 2 殘項第 130 行（F-MINOR-1）寫明「PR 3 網路摘要一起處理」的那一項，計畫照樣沿用了碰不到的失敗模式。
**情境 D**：只有 mpend → `seeRequest`；第 6 列的次要按鈕 `joinTeam`。計畫沒寫這兩個開哪裡（#329 PR 2 殘項第 128 行 D-m5「PR 3 / 4」）。

**修法**
- 「建立」只在拿到佔用之後、**當下重新列檔**確認 net/、mnet/、mpend/ 三種**檔案**都沒有時才允許（不靠摘要表，也就沒有 TOCTOU）。
- 有 net 檔但全部打不開 → 不給建立，顯示現有的重裝警告句。
- 只有 mnet、只有 mpend、或第 6 列的 `joinTeam` / `seeRequest` → PR 3 不開新頁，繼續開舊控制台（或明寫進殘項給 PR 5），**絕不**進 `NetworkRun` 的建立分支。
- 摘要表要分得出「沒有檔案」和「有檔案但打不開 / 列不出來」：在 Dart 端另外用 `Directory.exists` / `list` 判斷，或改 Rust 讓 `list_kind` 回 `Result`（改 Rust 要另外說明）。
- 測試（T-N2 擴充）：只有 mnet → 新頁不出現、`requestMakeNetwork` 沒被呼叫；net 檔存在但 `open` 丟例外 → 沒有建立按鈕，顯示警告；列目錄失敗 → 中性。負向對照：建立的條件改成「摘要表裡沒有 net」→ FAIL。

---

## MAJOR

### M-1 多台迴圈的「網路是哪一個」與第一台失敗之後怎麼辦都沒定義
- `_joinNetwork` 內部自己呼叫 `_pickNet`（nodes.dart:633）：手機有兩個以上 net 時，每一台都會跳選網路對話框；頁面不在時直接取 `nets.first`（:614），可能是別的、甚至還沒套用的網路。
- 建立回來之後，新網路的 `rel` 要從 `PersistNet` 步驟（`p.rel`，:254-262）取出交給後面每一台。計畫沒有這個介面。
- 第一台（建立者）失敗時，計畫只說「問繼續下一台 / 先停」。如果選「繼續」，第二台要加入什麼？沒有網路就會變成在第二台建立（B-2），或加入一個還沒套用的網路。
- 修法：4.1 決定一次目標網路（建立的話 = 第一台建出來的 rel；加入的話 = 使用者選一次的 rel），把 rel 傳給每一台；`OwnerConsole` 的 join 接受 `rel` 參數，不在裡面挑。建立失敗或確認沒套用 → 整個迴圈停，不問「繼續」。測試：兩個 net 的手機跑三台，只問一次；建立失敗 → 後面幾台沒有任何 `request*`。

### M-2 `OwnerConsole` 的搬移邊界沒寫：實際上牽動整個舊控制台
- P1 只列了 `_login / _tryLogin / _run / _ask / _kick / _drop / _lost / _endUnclear`。但步驟迴圈的 `answer` 分支會寫 `_linkFrom / _left / _sendAfter / _lastInfo / _lastHex / _lastSas / _lastRenewed / _removedQ / _joinreqInFlight / _saved / _quiet / _track`（nodes.dart:225-345），而 `_session / _answer / _run / _lastNode` 在檔案裡被引用超過 60 處（✅ grep：81…1714），使用者包括 `_askSw`（:1590-1622，自己複製了一份 `_ask`）、`_sendUpdateFor`（:1567）、`leaveFlow`（:1146）、`_readStatusPage`、`_remove / _runRemove`、`_requestJoin`、`_runOp`。
- **新的加入流程直接需要 `_sendUpdateFor`**（`_sendAfter`，:664-669；設計 §5.4 表列了 `_sendAfter`），計畫卻沒列它和它用的 `_yesNo`。
- `_busy` 在 `GateIo` 下代表什麼也沒寫（舊的是 `rawBusy` = `lease.hold()`；`_ask` 用 `_busy && !held` 擋重入，`_watchLink` 要求 `!_busy`）。`alive()` 在設計 §4.4「controller 由登記表持有、頁面關掉寫入照樣做完」之下是什麼意思也沒寫。
- 修法：計畫列出搬進 `OwnerConsole` 的完整欄位與函式清單，以及留在舊頁面、經 adapter 存取的清單（至少 `_askSw`、`_sendUpdateFor`、`leaveFlow` 的 `askEnd`）。或者改成另一個做法：舊控制台**完全不動**，`OwnerConsole` 從它複製出來只給新頁面用（PR 6 刪掉舊的就沒有重複）。兩案比較風險後擇一寫進計畫。依「只做必要的修改」，我傾向後者，因為 D2 已經讓舊控制台活到 PR 6、用不同的 IO。

### M-3 D1 可以接受，但「認領 → 建網」的交接、F41、S10 沒寫
- `ClaimPage` 用原始佔用，在頁面 `dispose` 時才交回（raw_use.dart:122-127、`openRawPage` :135-144）。如果 3.5 的「建立網路」把 `NetworkRun` 推在認領頁上面，`acquire` 回 null（lease.dart:268-269）→「另一個操作還在進行：新增節點」。主要路徑會卡住。
- `released` 是非同步的（node_link.dart:177-194）。新的佔用在 `readRecords` 完成前拿到時，走 `reg.current != null` 分支：`core.releaseLease` 不會被呼叫，`writtenAt` 不會設定（:184-190）→ N9 的 10 s 重試視窗不生效（core.dart:703-705）。計畫要嘛讓 `NodeLink.acquire` 先等上一個 `released` 處理完，要嘛在 `releaseLease` 之外也設定 `writtenAt`。
- #329 殘項第 104 行（F41：認領結果顯示在已關掉的頁面上，「PR 3 換掉認領頁時解決」）與第 129 行（S10：BLE 位址進技術資訊，「PR 3 認領頁」）：D1 之下這兩項做不做，計畫都沒說。
- 修法：寫明 3.5 / 3.6 的按鈕先 `pop` 認領頁、等它 `dispose`（佔用釋放），再開新頁並 `acquire`（沿用 `openUnderLease` 的「正在結束上一個讀取…」）。D1 的範圍寫成「`ClaimPage` 原地換樣式（build 方法）＋暱稱、步驟、經過時間，不抽出邏輯」。F41、S10 在計畫裡逐項寫「做 / 留在殘項＋理由」。測試：認領成功 → 按「建立網路」→ 新頁拿到佔用（負向對照：用 push 疊上去 → 被拒 → FAIL）。

### M-4 生命週期缺的路徑
- **建立做到一半被殺**（net 已寫、`applied = false`）：首頁第 6 列會給「加入網路」→ 新頁看到有 net → 讓建立者加入自己還沒套用的網路？現況的出路是「檢查網路」（`_makeUnclear`，nodes.dart:46）。計畫的生命週期表只有「多台做到一半」。需要一列，加上待辦或按鈕，並有測試。
- **T-M2 的「做到一半的那台」怎麼對到節點**：`MemberView` 只有 `last4`（舊節點是 ""）、`joining`、`approved`，沒有 device id（lib/src/rust/api/owner.dart:243-270）。隊長的 net 裡別人的已同意節點也是 joining。計畫要寫比對規則（只對這支手機的 `node/` 紀錄；`last4` 重複或空 → 不顯示待辦，寫進文字紀錄），以及待辦點下去做什麼（用同一個 rel 再跑一次加入）。
- **結果不明之後的按鈕**：加入的不明句子寫「稍後在這台按『加入網路』」（`_joinUnclear`，nodes.dart:45），計畫 §2.3 卻說下一步按鈕一律是「檢查網路」。句子和按鈕要一致（§3.4 規則 3）。
- **等待中藍牙關閉、沒有權限、金鑰不能用**：這是前提失敗，不是某一台的失敗。計畫寫「那一台失敗、問繼續 / 停」，結果會一台一台地失敗、一台一台地問。應該直接停在 2.3 / 2.2 / 2.4 的內容。
- 「繼續 / 停」對話框被返回鍵關掉時算什麼：計畫沒寫（建議 = 停）。

### M-5 負向對照不成立或測不出東西
- A1：「補的測試先在搬移前寫好、搬移後照樣過（負向對照用搬移前的版本）」。兩版都過只證明「沒變」，不能證明這些測試**抓得到**改壞。負向對照必須是在**搬移後**的程式上故意改壞（例如拿掉 ConfirmRemoved 的重新開始、把 `_watchLink` 拿掉、把 persist 移到 write 之後），看到 FAIL。工作樹裡作者正拿掉 `_watchLink`，方向對，但計畫的文字要改，而且每一項都要做。
- PR3-1 的 ConfirmCountry 測試是立刻按「改」（nodes_update_send_test.dart:500-510），所以抓不到搬移時漏掉 `_wait?.cancel()`（nodes.dart:276，「使用者想的時間不計時」）。要加一例：對話框開著時先推 400 s 的時鐘再回答，請求不能逾時。
- T-M1「連線數 ≤ 1」：`BleGate` 本來就拒絕第二條連線（ble_gate.dart:228-231），所以這個計數永遠成立。要改成驗事件順序：上一台的 `close` 完成 → 下一台的 `connect`，而且第二台成功。負向對照：不關上一台 → 第二台被拒 → FAIL。

### M-6 擁有權表缺資源
計畫 §3.1 少了以下幾項（使用者的規則：每個資源要有唯一擁有者）：
- `keepScreenOn` 旗標：設計 §4.1 說等待頁開始時開、結束與 `dispose` 時關。要寫在例外與返回路徑上也會關（finally）。
- 佔用釋放前的斷線：#329 殘項第 114 行（`_drop()` 沒有 await，F-m6 / L-m2）註明「PR 3 換掉頁面時解決」。`GateIo` 要在 `lease.release()` 之前 `await GateLink.close()`。
- `PopScope` 的範圍：只有等待頁，還是 4.1 也算。
- 4.1 一開頁就拿佔用：使用者停在表單上時，自動讀取一直停著。這是可以接受的代價，但要寫出來；另外要寫拿不到佔用時顯示「另一個操作還在進行」。
- 網路摘要表：`NodeLink` 現在沒有任何平台或 Keystore 相依（只有注入的 `readRecords`）。算摘要表要另外注入「打開紀錄 + `netSummary` / `mnetSummary`」。打開時金鑰出錯是否走 X26（`keyErrorToRadio`），也要寫。

---

## MINOR

- m-1 P7 把 `core.loginFor` 寫成只決定位址順序，事實不對（見 B-1）。
- m-2 §6「回答內容不寫 log（現況 `_quiet`）」：現況 `_say` 會 `debugPrint` 每一個回答（nodes.dart:157-160），`_quiet` 只是不顯示在畫面上；真正不寫 log 的只有軟體更新的回答（D8，:309-313）。請照現況改寫。
- m-3 §6「一台的回答不影響別台的紀錄寫入」說過頭了：每一台加入都 CAS 同一筆 net 紀錄（成員表、`applied`、`prevCountry`），後面幾台讀的是前一台寫過的版本。請改成「影響範圍 = 共用 net 紀錄裡它自己那一項；不能改金鑰」，並附 Rust 的證據。
- m-4 摘要表的重算可能亂序：釋放 A 開始算 → B 很快拿到、寫入、釋放、又開始算 → A 那次較晚完成，蓋掉較新的結果。加一個代號計數，只保留最新的一次。
- m-5 4.1 的節點清單：列哪些、預設勾哪些（建議只預設勾「最近一次讀到還沒加入網路」的；在別的網路裡的節點不能勾，或要另外確認）。
- m-6 T-G5(b) 的原始碼鎖在 D2 之下做不到，但可以縮小：新檔（`lib/src/flows/`、`lib/ui/network_pages.dart`）不得出現 `storeWriteCas / storeWriteSealed / storeRemove / storeKeepCopy`。新程式就不會繞過 `RecordWriter`。負向對照：在新檔留一個直接呼叫 → FAIL。
- m-7 同一支手機上的 dev2 正在自動讀同一台：登入會撞到「節點正在被連」。計畫的生命週期表可以註明照 T-L2 處理（那一台失敗、文字包含「另一支手機」）。
- m-8 `GateIo` 被 `BleGate` 拒絕時丟的是 `Refused`，被 `RecordWriter` 拒絕時丟的是 `NoLease`。它們在 `_ask` 的分類裡算「連線問題」（nodes.dart:545-552），在 persist 的分類裡算 `'${e.runtimeType}'`（:268）。請寫出畫面上會看到哪一句，並各有一個測試。

---

## 事實核對（P1–P11、§5）

| 項目 | 判定 | 證據 |
|---|---|---|
| P1 | ✅ | nodes.dart `_tryLogin` :194、`_login` :365、`_endUnclear` :431、`_lost` :438、`_kick` :494、`_ask` :511-589、`_watchLink` :687-716 |
| P2 | ✅ | `_say` :157-160；國家 :277-278；`_pickNet` 對話框 :615；`_yesNo` :673-675；`!mounted` :405、:520 |
| P3 | ✅ | :253-272、:750-765 直接 `storeWriteCas`；另有 :467、:1026、:1290 也直接寫（計畫沒列，但 D2 已涵蓋） |
| P4 | ✅ | raw_use.dart:25-44 |
| P5 | ✅ 部分 | ble_gate.dart:185 `scan(token,…)`、:226 `connect(token,…)`；`GateLink` 有 `requestMtu / read(ctrl) / subscribe(tx) / write(rx)`，寫入是 without-response（ble_backend.dart:49-50），足夠 `_tryLogin` 的步驟迴圈用。但「沿用步驟迴圈」不夠，見 B-1 |
| P6 | ✅ | record_writer.dart:27-33；app_link.dart:97；node_page.dart:72-76。`writeCas(lease, rel, gen, sealed)` 吃的是已經封好的位元組，封裝仍在呼叫者 → 能用於 persistNet / Pend / Mnet |
| P7 | ❌ 描述不對 | core.dart:628-748 是完整的登入狀態機（見 B-1） |
| P8 | ✅ | lease.dart `pageGone` 只從 dispose 起算 |
| P9 | ✅ | claim.dart:212（`_find`）至 :472；claim_recovery.dart:165 `class ClaimRecovery` |
| P10 | ⚠️ 已過時 | 主線上確實沒有；工作樹的 nodes_update_send_test.dart 正在加 PR3-1 的四項（:483-545） |
| P11 | ✅ | nodes_update_send_test.dart `RustLib.initMock` 、`ReactiveBlePlatform.instance`、`dev.batman/platform` |
| A2 | ❌ | 「同一個步驟迴圈；只換 IO」不等於設計的 `loginFor`（B-1） |
| A4 | ✅ | 同 P8 |
| 首頁第 6 列現況 | ✅ | home_page.dart:129-151（`_todos` 只列檔名）、:177-178（四種動作都開舊控制台）；home_logic.dart:92-96 |
| `NodeLink` 能不能在釋放時算摘要表 | ⚠️ | `released` 掛點存在（node_link.dart:171-195），但沒有打開紀錄的相依，且有 M-3 / m-4 的兩個競態 |

## D1 / D2 判斷
- **D1（認領不改走 `BleGate` / `RecordWriter`）**：同意，理由成立（改它不會讓使用者多得到什麼，回歸風險大）。條件：補上 M-3 的交接、`writtenAt` 競態，以及 F41 / S10 的處理方式。
- **D2（舊控制台繼續用原始寫入）**：同意，但要嘛完整定義搬移邊界，要嘛改成「複製、不動舊的」（M-2）。並加上 m-6 的縮小版原始碼鎖。

## 安全摘要
- 新路徑的權限都在 app 內；沒有新的平台方法或匯出元件 ✅（讀過計畫 §6；沒有找到反例）。
- 沒有佔用時：`BleGate` 拒絕掃描與連線（ble_gate.dart:175-180），`RecordWriter` 拒絕寫入（record_writer.dart:27-33），都是 fail-closed ✅。
- 主要的安全與完整性風險不在權限，而在 B-2：錯誤的「建立」等於一次寫入、而且要動節點才能恢復。另一個在 B-1：惡意廣播者可以吃掉登入預算。
- 摘要表與寫入之間的 TOCTOU：只要依 B-2 的修法，「建立」在佔用下重新列檔，摘要表只用來決定顯示，就沒有問題。

## 驗證狀態
- ✅ 讀過並逐行對照：計畫全文；設計 §4.1–§4.7、§5.3、§5.4、§7、§9.1（T-L17/18/19、T-M1/2、T-N2、T-S3、T-G5）、§12；`nodes.dart` :1-1000、:1040-1130、:1200-1310、:1540-1625；`node_link.dart`、`core.dart` 的 loginFor 段（:220-270、:500-535、:600-749）、`prober.dart`、`ble_gate.dart`、`ble_backend.dart`、`lease.dart`、`raw_use.dart`、`record_writer.dart`、`app_link.dart`、`home_page.dart`、`home_logic.dart`；`owner.rs` :30-60；`gh issue view 329` 的殘項段（PR 1 / PR 2）。
- ⚠️ 推論、沒有實跑：B-1 的 60 s NOT_FOUND 與連線格被佔的後果（由程式碼推論，沒有跑測試）；M-3 的 `released` 競態在真機上的時間窗。
- ❌ 沒做：沒有跑 `flutter test`（作者同時在改工作樹）；沒有真機；沒有讀 Rust 的 `request_join_network` 對「已在別的網路的節點」怎麼處理（m-5 因此只列為 MINOR）。
