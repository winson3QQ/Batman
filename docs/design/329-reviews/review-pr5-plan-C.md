# #329 PR 5 計畫 v2 — 審查 C（第二輪；與原始碼 / 基準一致性、現場行為）

審查對象：`docs/design/329-pr5-plan.md` v2（worktree `C:/src/Batman-329pr5`，main 2e18de6；工作樹另有 QrScanActivity.kt 的解析度改動）。依 brief 只審 §0「本 PR 新做的」1–9 與 §2–§7，基準只用來對照搬移是否忠實。整份 v2 重讀，不只看改動。所有證據都是本人用 Read / Grep 讀原始碼，或在本機跑 python `qrcode` 算 QR 容量；沒有上機。

先核對、確認無誤的部分：
- §0 舊函式行號（nodes.dart 798-812、815-864、867-878、881-910、926-954、957-999、1001-1037、1040-1062、1311-1344、1348-1421、1425-1448、1450-1499、1503-1542、1546-1582）、member_ui.dart:166-169 的 `joinreqLostLine`、nodes.dart:49 `_joinUnclear`、nodes.dart:1334-1338 的 isSelf 分流、nodes.dart:1745 的「把新密碼送給節點」：都和原始碼一致。
- P6 / P7：`OwnerConsole._run` 的 persistPend / persistMnet 經 `lease.run` + `writer.writeCas`（owner_console.dart:281-307）；`_persistedRel` 只記 persistNet（:290）；`_derive` 只在請求還在等時才算（:331-334）。
- P8：`more_pages.dart:80-92`、`net_pages.dart:307-320` 都是 `link.acquire(…, session)` 加上經 `RecordWriter` 寫。
- `request_joinreq` 的步驟依序是 fresh addr read、SignOwner ×2、PersistPend，然後立刻 Answer（owner.rs:1279-1326）。所以 2.3 的 `_pendSaved` 規則涵蓋了兩種情形：
  - 斷線發生在步驟迴圈中間：`_run` 在 :258 return、不 complete，等 15 s 計時，之後改寫句子；
  - 斷線發生在等回答時：同樣是 15 s 計時之後改寫。

  `_ask` 對 unclear 會再等 `_chain` 最多 10 s（:454-459）。所以 persist 晚一點落地，`saved` 也會跟著是 true，和實際一致。
- 解析路徑：大寫與空白經 `from_hex`（invite.rs:75-82），兩者都接受。
- 掃描器的工作樹改動與 2.1 相符：`ResolutionSelector(1280×960, FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)`。`QrDecode.MAX_LEN = 4096` 不變。
- `minSdk = 31`（build.gradle.kts:39）。

### 第一輪 MAJOR 的關閉情形（逐項對原始碼）

| 項目 | 結論 | 證據 |
|---|---|---|
| A-M1 / B-M1（update_hint） | ✅ 已關。v2 不用 `update_hint`，8.5 與「把新密碼送給節點」都改成常駐入口；`sendUpdateFor` 已在 OwnerConsole（owner_console.dart:522-529，wait = joinWait、unclear = sendUnclearLine，和 nodes.dart:1567-1582 相同）。殘留：§6 第 8 步還寫「節點頁的隊員分組與 `update_hint` 那一行」（見 m1） | rekey.rs:466-499 不再被用到；node_page.dart:76-111 |
| A-M2（排除最後一台後進不去） | ⚠️ **只關了一半**。入口條件改成看 net 紀錄是對的，但 8.1 沒有通往 8.4 的路，離開 8.4 之後就不能再產生更新包（見 **M1**） | plan :223、:225-230、:367 |
| A-M3 / B-M2（大的同意碼） | ✅ 已關。依編碼器實際給的版本決定，≤ 27 才畫 QR；貼上不設上限。殘留：D1 對後果的描述不正確、3.2 契約表還寫「≤ 4096」（見 m2、m3） | 本人計算：v27-L 英數模式最多 2132 個字元 |

---

## MAJOR

### M1. 8.1 沒有「產生更新包」的入口：離開 8.4 以後（返回、接電話、app 被殺）就再也產生不了更新包；A-M2 只關了一半

**情境**：隊長的節點被抓。他從設定頁的「隊員」→ 8.2「排除 …xxxx」→ 8.3 commit → 8.4。複製了兩位隊員的包以後接了一通電話，回來時 app 已經被系統殺掉；或者他按了返回。這時 net 紀錄已經是新版本（rekey.rs:330 `rec.base.members = members`）。留下的隊員還沒拿到包的，節點換密碼後都會斷線。

**證據**：
- 計畫列出的 8.1 內容只有：以人分組、「我」排第一、同名標示、底部「邀請隊員」、頂端 `RemoveTicks` 那一行（plan :225-230）。8.4 只能從 8.3 的 commit 成功進去（:260）。
- 頂端那一行只讀 `RemoveTicks`（:215）。app 被殺之後 `RemoveTicks` 是空的（:213、:361），所以那一行也不會出現。就算那一行可以點，app 重開之後它也不在。
- 舊控制台有一顆獨立、常駐的「產生更新包」（`_makeUpdates`，nodes.dart:1450-1454、:1749），它用 `_pickNet` 選網路，不需要先做過移除。計畫 §0 把 `_makeUpdates` / `_updates` 列為「照搬」（plan :30），但新頁面沒有任何地方對應 `_makeUpdates`。
- 上層設計要求這條路：「移除的勾選不存檔（T15），回來後勾選是空的、**更新包可重新產生**」（329-app-uiux.md:192）；情境 6 的出路也是重新產生更新包（A 第一輪引用 :807）。
- 計畫的生命週期矩陣寫「設定頁的『隊員』仍進得去 8.1 / 8.4」（:367）。但從 8.1 到 8.4 沒有定義任何路。

**後果**：緊急換密碼做到一半就斷掉，沒交到包的隊員全部斷線。PR 5 期間只能回開發者選項裡的舊控制台；PR 6 刪掉舊控制台以後，就完全沒有路可走。

**修法**：
- 8.1 加一列常駐「給隊員更新包」（devTrust），進 8.4。
- 8.4 的名單一律由 `netRecipients` 在進頁時重算（舊 `_updates` 就是這樣做，nodes.dart:1461-1468），不依賴這次 app 做過移除。`RemoveTicks` 是空的時候，勾都是空的（T15）。
- 生命週期矩陣加兩列：「commit 後離開 8.4 / app 被殺 → 8.1 → 8.4 仍能產生包」，以及排除最後一台之後的同一條路。
- 測試：widget 測試「沒有 `RemoveTicks`、紀錄已是新版本 → 8.1 有入口 → 8.4 列出 `netRecipients`」。負對照是拿掉入口 → FAIL。

### M2. 7.8「收邀請」只能從首頁第 6 列、而且只在手機沒有任何 net / mnet / mpend 紀錄時進得去：Rust 明說「需要新的邀請」的那幾種情形，隊員都走不到 7.8

**情境**（都是基準已定義的現場路徑）：
1. 隊員加入網路失敗，Rust 回「需要新的邀請（手機裡已沒有這台節點的加入資料）」，或者 Failed 之後加上「；需要新的邀請」（owner.rs:574、:577-581）。這時手機還留著那份 mnet。
2. 隊員被移除之後，隊長重新邀請他。手機上還有舊的 mnet，要走 remove-member §3.6-2 的「取代」匯入（`ImportState.replace`，nodes.dart:973-981）。
3. 匯入同意碼時 Rust 回 `[IMPORT] 需要新的邀請`（member.rs:258 `NeedsNewInvite`）。
4. 第一次確認碼不同（7.7），隊長重新邀請。手機上還有 mpend。

**證據**：
- 計畫寫 7.8 的入口只有首頁第 6 列的「加入隊長的網路」（plan :278、:312）。
- 第 6 列只在 `NetRecords.none` 時才給 `joinTeam`（home_logic.dart:95）。有 mnet 就是 `joinNetwork`、有 mpend 就是 `seeRequest`（:93-94）。而且第 6 列只在有節點 `notInNetwork` 時出現（:89）。
- 節點頁、設定頁、7.9、7.10、8.5 都沒有「收邀請」（plan :278-305、:318-322）。
- 舊控制台的「貼上邀請」是常駐的（nodes.dart:1757），所以 `_takeInvite` 的入口沒有照搬。
- 上層設計也預期隊員會在已有紀錄時重新收邀請。例如 remove-member :186 的「這台要請網主重新邀請」，以及 §3.6-2 的取代匯入。

**後果**：
- 情境 1–3：隊員端在新 UI 裡卡住。首頁只給「加入網路」，按下去又失敗或「需要新的邀請」，形成迴圈。
- 情境 4 有一條繞路：7.9「放棄申請」，然後回首頁第 6 列。但畫面沒有任何字告訴使用者要這樣做。
- 被移除後重新加入是 remove-member 的正式流程。PR 6 之後完全做不到。

**修法**：
- 「收邀請」（7.8）給一個常駐入口，不看紀錄種類：devTrust 版本的節點頁網路分組加一列「貼上 / 掃描隊長的邀請」，或者設定頁的「隊員」區加一列。
- 7.9 加「收到新的邀請」→ 7.8。`requestJoinreq` 本來就會換新同一個網路的 mpend（renewed）。
- 測試：widget 測試「手機有 mnet → 入口在」與「有 mpend → 入口在」。負對照是把入口改回只看 `NetRecords.none` → FAIL。

---

## MINOR

**m1. §6 第 8 步的殘文。** 它還寫「節點頁的隊員分組與 `update_hint` 那一行」（plan :448），和 2.3 的「`update_hint` 本 PR 不用」（:167）矛盾。改成「節點頁的兩列常駐項目」，並列出它們的 widget 測試：有 mnet → 「貼上隊長給的新密碼」在；非 devTrust → 都不在。

**m2. D1 說錯了同意碼什麼時候會變大。**
- 計畫寫「隊伍裡已有 1 位以上隊員之後，同意碼大概就超過 v27」（:375）。
- 原始碼：同意碼帶的是 `rec.base.members`（approve.rs:217）。它在建網時只簽建立者一項（joinflow.rs:206-221，名字 `node-<last4>`，owner.rs:1120），之後只在換密碼時重簽（rekey.rs:330）。同意不重簽（approve.rs:241-262 只改 `rec.list`）。
- 所以第一次移除之前，不管加了幾位隊員，同意碼都和向量差不多大。
- 本人計算：向量是 2082 個字元，v27-L 英數模式的上限是 2132 個字元，只剩約 50 個字元（25 位元組）的餘裕。實際的成員項和向量有差別：
  - 名字是 `node-xxxx`（9 位元組），向量是「客廳」（6 位元組）；
  - SAE 是 24 字元（joinflow.rs:133），向量是 21 字元；
  - 給節點的 secrets 沒有 key 4（approve.rs:290-299），向量有 `team-ap-pass`。
- 修法：D1 改成「第一次換密碼之後」。T-Q1 除了 F36 向量，再加一份由 Rust `NetOp::approve` 實際產生、建立者名稱為 `node-xxxx` 的同意碼，量出實際版本。如果超過 v27，當面加入就從第一位隊員起都沒有 QR，要在 PR 裡寫明。

**m3. 3.2 契約表的 `CodeInput.onText` 還寫「≤ 4096，掃描器已限」**（:349）。這和 2.2「貼上不設長度上限」（:147）讀起來衝突，正是 A-M3 要防的寫法。改成兩列：掃描 ≤ 4096（QrDecode）；貼上由 Rust 判斷。另外，貼上建議設一個遠高於合法值的上限，例如 2 × 128 KiB + 少量餘裕的字元數，超過就拒絕、不交給 Rust。這是為了防止本機 app 塞進來的超大剪貼簿把 UI 卡住。同一處的「更新包上限 128 KiB（rekey.rs:30）」引錯了行，實際在 mupdate.rs:87。

**m4. 7.4 沒有獨立入口：遠端邀請時，隊長要收申請只能再產生一張新邀請。**
- 7.4 只能從 7.3 的「下一步」進去（plan :234）。遠端邀請時，申請通常在幾小時後才從訊息傳回來，隊長那時已經關過 app。照計畫，他只能 8.1 →「邀請隊員」→ 7.1 →（`OfflineOp` 寫入一張新的邀請）→ 7.3 → 7.4。
- `check_joinreq` 接受紀錄裡任何一張邀請（approve.rs:119），所以流程走得通。但每繞一次，紀錄裡就多一張不能撤銷的邀請（D7；Rust 沒有上限也沒有清理，grep 無結果）。7.3 也會叫隊長把新的碼傳出去。
- 舊控制台的「貼上隊員的申請」是常駐的（nodes.dart:1757）。設計 :192 寫「邀請中途離開靠 mpend 與**隊長端重新進入**」。
- 修法：8.1 加一列「收隊員的申請」→ 7.4。

**m5. 7.10 第 5 步「顯示舊的原因句」沒有對應的句子。**
- 舊 `_memberJoin` 用的是已登入的那台（nodes.dart:1040-1062），沒有「找不到入口節點」這一句。
- `MnetView.entry_state == ""`（member.rs:306、:324）時，`device_last4` 也是空的。這時應該直接說「需要新的邀請」，並帶到 7.8（接 M2），不要另寫一句。
- 後四碼對到兩筆 `node/` 紀錄時要讓使用者選；對不到時給一句固定的話。兩種都寫進計畫並加測試。

**m6. 7.8 選節點時，節點狀態可能「不明」（A-m7 的後半，v2 沒處理）。** 「沒加入任何網路的節點」要靠 NodeLink 讀到的 `nodeState`（node_page.dart:86 用的是 `nodeState == 1`）。沒讀到時是不是列出要寫明。建議照舊列出，由 Rust / 節點拒絕，句子照 Rust 的。

**m7. `joinreqLostLine(saved: true)` 的句子叫使用者按「再顯示申請」**（member_ui.dart:168-169），但新 UI 的 7.9 沒有列這顆按鈕。設計 S7（329-app-uiux.md:312）明定 7.8 / 7.9 保留「再顯示申請」這個按鈕名稱。計畫的 7.8 / 7.9 要列出這顆按鈕（→ 7.9 / 重新顯示申請碼），不然句子指向一顆不存在的按鈕。

**m8. 「隊員」入口的條件應該是「有已建立（applied）的 net」，不是「有 net 紀錄」。**
- 計畫 :220、:223 寫「手機有 net 紀錄就出現」。舊 `_members` / `_makeInvite` / `_makeUpdates` 都是 `_pickNet(only: (v) => v.applied)`（nodes.dart:800、:1313、:1452）。
- 只有一份還沒確認建立的 net 時，入口會出現，但選網路是空的。
- 改用 `NetSnapshot.anyApplied`（net_index.dart:84）。

**m9. 選網路時沒有照設計 :778 處理同名網路。** 設計要求「同名的網路後面加建立日期與網路代號後四碼」。計畫只寫「照 `_pickNet` 的做法」（:222），但舊 `_pickNet` 沒有這條規則。8.1、7.x 的選網路都要寫進去，並加一個 widget 測試。

**m10. 8.5 的「送到節點」沒有說送到哪一台。**
- 舊程式一律先在已登入的節點讀 info → `infoNetId` → 找紀錄（nodes.dart:1546-1563，code review r1 A-F6：「never a guessed one」）。
- 計畫 :305 只寫 `OpSession.once(c.sendUpdateFor(member:true))`，沒有節點，也沒有 info 那一步。隊員可能有兩台節點。
- 修法：8.5 列出這個 mnet 裡自己的每台節點，和 8.4 隊長那段一樣。每台都走節點頁那條 `info → infoNetId → 紀錄 → sendUpdateFor`，不另寫一條。

**m11. 8.4「我的節點」那段要從 `PersonNode` 對回節點 id。** `PersonNode` 只有 `last4` / `dacHash`（rekey.dart:189-200）。`OpSession.once` 要的是 device id。建議用 `removeOwnNodes`（給 `OwnNodeView.deviceId`，rekey.rs:109）或 node 紀錄的 dacHash 來對。對不到的那台要顯示「這支手機沒有這台節點的紀錄，送不了」，不能默默略過。這正是 8.4 固定句「沒有送出新密碼的節點，被移除的人仍然連得上」要提醒的那一種。

**m12. `RemoveTicks` 存了版本號，但沒有說誰要比對它。** PR 5 期間舊控制台還在。在舊控制台做的移除不會清 `RemoveTicks`，8.1 頂端那一行就會顯示上一次移除的勾。8.1 / 8.4 讀的時候，要比對 `RemoveTicks` 的版本號和紀錄目前的版本，不一樣就當成空的。加一個測試。

**m13. `runNetOp` 的金鑰失敗沒有接到 X26。** 舊 `_runOp` / `_runRemove` 在 signAdmin 失敗時呼叫 `_keyFail`（nodes.dart:780-783、:1432-1435）。新 UI 的對應做法是 `keyErrorToRadio`（app_link.dart:203-205；net_pages.dart:316 的 `forgetJoining` 也有接）。計畫 2.4 的 `runNetOp(step, lease, writer, platform)` 沒寫。補上，並加一個測試：signAdmin 回金鑰閘門拒絕 → NodeLink 進 2.4。

**m14. 8.4「複製更新包」有沒有「清除剪貼簿」沒有寫。** 2.6 第 10 項只寫「→ 複製」。依 2.1 / 2.2，所有複製都應該經 `copyCode`（sensitive 旗標），並出現「清除剪貼簿」，離開時提醒一次，和 `CodeView` 一樣。寫明即可。

**m15. 平台：解析度改動只在 S20 量過。**
- 1440×1080 每幀的像素約是 640×480 的 5 倍，HybridBinarizer 在低階手機上每幀的時間也會跟著變長。STRATEGY_KEEP_ONLY_LATEST 不會讓幀堆積，所以不會卡死，但掃到所需的時間沒有證據。
- 這也影響 field 版的認領掃描（§7 只在 S20 重測）。
- PR 的測試段要標 ⚠️「只在 S20」。
- 另外，QrScanActivity 的新註解寫「121-141 modules」，但 P16 量到的是 121 / 125。141 是 v31。改成實測值。

---

## 擁有權 / 契約 / 生命週期檢查摘要

- **擁有權**：紀錄的寫入者只有佔用持有者，經 `RecordWriter`（`OfflineOp` 的 work，或 OwnerConsole 的步驟迴圈）。`RecordWriter._check` 要求 `identical(reg.current, l)`（record_writer.dart:31-36），沒有兩個寫入者。
  - `OfflineOp` 用 `link.acquire`，會 `_dropAll` 所有連線（node_link.dart:186）；釋放後 NetIndex 重算，NodeLink 6 s 後再跑一輪。8.4 每按一次「複製更新包」都會斷掉、重連一次，這是可接受的副作用，不另列 finding。
  - `OfflineOp` 不經 `pageGone`、沒有上限。Kotlin 呼叫一直不回來時，佔用要到重開 app 才會放。PR 3 的 `forgetJoining` 是一樣的做法（net_pages.dart:304-320），所以不另列。
- **契約**：見 m3、m10。`joinreq` 的 value 只在回答有 hex、而且請求還在等時才給（`_derive`，owner_console.dart:331-334），晚到的回答不採用，正確。
- **生命週期**：除了 M1 / M2，下面幾條我都走過，結論和計畫一致：
  - 升級：PR 4 舊控制台留下的 mpend / mnet，新的待辦與 7.9 / 7.10 都能接；
  - 降版：沒有新的紀錄種類；
  - crash：approve 寫入後、還沒顯示同意碼就 crash → `replacesApproved` 可以重新同意；匯入後、刪 mpend 前 crash → A-m6；
  - Activity 重建、斷線（joinreq，見前面的核對）。
  - M1 / M2 都是「已有紀錄的手機要重新進入流程」。這兩條矩陣裡都沒有。
- **安全**：
  - 剪貼簿：貼上後清、複製帶 sensitive 旗標、說明鍵盤 app 的紀錄清不到。
  - 截圖：設不了 FLAG_SECURE 時不顯示 QR。這是 fail-secure；確認碼照樣顯示，有理由（D6）。
  - 紀錄行不寫名稱。
  - field 版的三層 gate：Rust 的 `dev_gate` 已核對 owner.rs:1255、:1284、rekey.rs:110、:154、:255、:268、:313、:335、:397、:411。`net_people` 沒有 gate（rekey.rs:68），但它只讀，入口也只在 devTrust。
  - 本機 app 往剪貼簿塞超大文字：見 m3。
  - 中間人攔到邀請：7.7 不同意、請重新邀請；舊邀請不能撤銷，D7 已照實寫。m4 會讓不能撤銷的邀請越積越多。
- **負對照**：§5 / §6 列的都可以實作。M1 / M2 / m4 的新入口要各自加上負對照（拿掉入口 → FAIL）。

## 判定

BLOCKER 0、MAJOR 2（M1、M2）、MINOR 15。

**APPROVE-WITH-CHANGES**。兩個 MAJOR 都是「舊控制台常駐的入口（`_makeUpdates`、`_takeInvite`）沒有搬到新頁面」，修法都是在 8.1 / 節點頁或設定頁加一列並補測試，不用動架構。依規則，修完要整份再審一次。
