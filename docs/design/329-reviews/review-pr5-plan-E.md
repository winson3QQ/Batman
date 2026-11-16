# #329 PR 5 計畫 v3 — 審查 E（第三輪；與原始碼 / 基準一致性、現場行為）

審查對象：`docs/design/329-pr5-plan.md` v3（worktree `C:/src/Batman-329pr5`，main 2e18de6）。只讀，原始碼逐項對過。
範圍：計畫 §0「本 PR 新做的」1–9 與 §2–§7；§0 的基準不重審，只用來對照搬移是否忠實。

## 摘要

- BLOCKER 0、MAJOR 2、MINOR 12。
- 兩個 MAJOR 都是同一類：計畫把新入口放進節點頁裡現有的元件，但那些元件在原始碼裡的顯示條件，剛好在需要這個入口的現場狀態下把它藏起來。
  - **M1**：D-M1 的修法（換密碼提示行）與 8.5 的入口都放在節點頁的「網路」分組。可是節點已經在網路裡、又沒有待檢查的網路時，這個分組整個是 `null`。也就是說，節點落後的時候提示永遠不會出現，D-M1 等於沒關。
  - **M2**：§2.9 把隊員的「加入網路」（`_memberJoin`）的常駐入口定為「節點頁『加入網路』：PR 3 的分流」。可是節點頁那一列要 `netFiles > 0`，而 `NetFormPage` 在只有 mnet 時只會給舊控制台的按鈕。只持有 mnet 的隊員手機，在節點頁根本沒有這一列；同時持有 net 與 mnet 時，也走不到隊員的加入。
- 第一、二輪的 MAJOR 關閉情形見最後一節。

## 第一、二輪 MAJOR 是否真的關了（對原始碼）

| 項目 | 判定 | 證據 |
|---|---|---|
| A-M1 / B-M1（送新密碼的入口） | 關了 | 2.7「更多」常駐，照舊 `_sendUpdate`（nodes.dart:1546-1563）；8.4 自己節點段照舊 1568-1572 的確認框 |
| A-M2（隊員入口不綁節點） | 關了 | 2.6 設定頁、2.9「隊伍與邀請」不看紀錄 |
| A-M3 / B-M2（大的碼） | 關了 | 依編碼器實際版本 ≤ 27（2.1）；approve.rs:217 打包 `rec.base.members`，另有可選的 key 1 netcfg（approve.rs:311-318），用版本判斷，兩種都涵蓋 |
| **D-M1（update_hint）** | **計算關了，顯示沒關（本輪 M1）** | prober 的做法可行（owner.rs:960-965 在 answer 前設好 `page_info`；`update_hint_of` 只用 `page_info`、`node`、`owner_pub`，rekey.rs:466-）。但顯示位置在節點頁的「網路」分組，node_page.dart:81-87 讓它在節點已入網時不出現 |
| D-M2（指紋、同名） | 8.1 / 8.2 / 8.3 關了；8.4 沒寫（m4） | nodes.dart:1324-1338、:1397 已搬；8.4 對應 nodes.dart:1483-1484，計畫沒寫 |
| C-M1 / D-M3（回到 8.4） | 關了 | 2.9「產生更新包」→ 8.4 |
| C-M2（7.8 常駐） | 關了 | 2.9「收隊長的邀請」 |

## MAJOR

### M1. 換密碼提示行（D-M1 的修法）與「貼上隊長給的新密碼」放在節點頁的「網路」分組，但節點已入網時這個分組整個不顯示：節點落後的時候，提示一定看不到（fail-open）

**現場情境**：
1. 隊長移除了一位隊員，在 8.4 交完更新包。
2. 隊長自己的節點 A 送新密碼時失敗（讀不到，或結果不明），之後就忘了。
3. 下一輪讀取時，prober 算出 A 的 `update_hint` =「這台還在舊密碼 — 把新密碼送給節點」。
4. 隊長打開 A 的節點頁：「網路」分組不存在，所以提示行也不存在。被移除的人仍連得上 A，UI 沒有任何提示。

這正是第二輪 D-M1 要防的情形（remove-member :27、:184-185、:235-236）。隊員端也一樣：手機有 mnet、節點已在隊伍網路裡時，2.7 / 2.6 第 14 項說「網路分組常駐一列『貼上隊長給的新密碼』」，這一列也不會出現。

**證據**：
- node_page.dart:79-87：`_network()` 的 `join = n.view != null && n.view!.nodeState.toInt() == 1 && nets.netFiles > 0`。也就是只有節點**不在**網路裡（nodeState 1，home_logic.dart:31）時才給「加入網路」。`pending` 只算「這台建立、還沒 applied 的 net」。`if (!join && pending.isEmpty) return null;`，整個分組不顯示。
- 節點落後的前提，是它**在**網路裡：`update_hint_of` 先要求 info key 10 等於紀錄的 net_id（rekey.rs:473、:482）。所以要顯示提示的時候，`join` 一定是 false，`pending` 通常是空的，分組就是 `null`。
- 計畫 2.7：「網路分組的提示行（v3，D-M1）」「網路分組另有『貼上隊長給的新密碼』」。整份計畫沒有提到要改 `_network()` 的 `null` 條件。
- 第 6 步第 8 項「節點頁的隊員分組與 `update_hint` 那一行」的 widget 測試，沒有指定節點在網路裡（nodeState ≠ 1）。如果用假的、nodeState 1 的節點來測，測試會過，但現場永遠看不到。

**修法**：
- 2.7 明寫：「網路」分組的顯示條件改成 `join || pending.isNotEmpty || hint.line.isNotEmpty || (mnet && devTrust)`。或者把提示行放在 StatusHero 的 `next` 裡，跟 `lagNote` 同一個位置（node_page.dart:117-123），不依賴分組。
- 測試 T-P5-H 加一個 widget 層的情形：節點 nodeState = 2（在網路裡），`extra` 帶落後的 hint，提示行與按鈕都要出現。
  - 負對照：把顯示條件改回現在的 `_network()` → FAIL。
- 8.5 的節點頁入口用同一個條件，或者明寫「節點頁不放，只在設定頁『隊伍與邀請』」（2.9 已有常駐入口，這樣也可以接受）。

### M2. 隊員的「加入網路」（`_memberJoin`）沒有可用的常駐入口：§2.9 指定的「節點頁『加入網路』：PR 3 的分流」，在原始碼裡碰不到 mnet

**現場情境**：
- **(a) 隊員手機只有 mnet**（一般隊員）：
  1. 7.10 匯入同意之後，加入等待頁跑 `memberJoin`，360 s 逾時，或節點斷電、斷線。
  2. 句子是舊的 `_joinUnclear`：「結果不明，稍後在這台按『加入網路』」（nodes.dart:49）。
  3. 隊員打開節點頁：沒有「加入網路」，因為要 `nets.netFiles > 0`（node_page.dart:81）。
  4. 首頁第 6 列只在節點新鮮讀到、而且 nodeState == 1 時才出現（home_logic.dart:89-97）。節點若已經開始套用、狀態不是 1，首頁也沒有。
  5. NetIndex 的待辦（`todos`）只從 net 紀錄算（net_index.dart:148-184），mnet 沒有「加入沒有做完」的待辦。
  6. 結果：新 UI 裡沒有任何地方可以重按，只剩開發者選項裡的舊控制台。到 PR 6 刪掉舊控制台時，這就是一條死路。
- **(b) 同一支手機同時有 net 與 mnet**：例如一位隊長同時是別隊的隊員。
  - 首頁第 6 列：`records` 在有 net 時就是 `NetRecords.net`（net_index.dart:64-72），所以走 `_form(makes:false)`（home_page.dart:183-190 的第一個 `when`）。
  - `NetFormPage` 只在 `netFiles == 0` 時看 mnet（net_pages.dart:352-360）。所以 mnet 的加入不會出現。
  - 舊程式在這種情形會先問「這支手機建立的網路 / 隊長的網路（我是隊員）」（nodes.dart:1086-1093，`JoinChoice.ask`）。計畫 2.7 說「T-N2 的分流不變，只換目的地」，但 T-N2 的 `ask` 分支在新 UI 裡不存在。

**證據**：
- node_page.dart:81、:87；net_pages.dart:352-360；home_logic.dart:89-97；net_index.dart:64-72。
- nodes.dart:1735（舊的「加入網路」只要已登入）、:1066-1094（`_join` 的四種分流）、:49（`_joinUnclear`）。
- 計畫 §2.9 表「加入網路，隊員那一支」那一列；計畫 §0 第 86 行：「每個 PR 保留全部現有功能」。

**修法**：
- §2.9 那一列改成真的常駐入口。設定頁「隊伍與邀請」加一列「讓我的節點加入隊長的網路」：
  - 多個 mnet → `_pickMnet`；
  - 再選節點，用 A-m7 的入口節點規則；
  - 進加入等待頁的 member 模式。
- 節點頁的「加入網路」條件改成 `nodeState == 1 && (netFiles > 0 || anyMnet)`。`NetFormPage` 補上 `JoinChoice.ask` 的分支（net 與 mnet 都有時讓使用者選），並明寫這是對 PR 3 `NetFormPage` 的增量。
- T-P5-E 加：只有 mnet 的手機，從設定頁進得去 member 模式；net 加 mnet 時兩條都看得到。
  - 負對照：拿掉這一列 → FAIL。

## MINOR

### m1. prober 裡的 hint 計算不能改變讀取的結果；位置、例外與 `extra` 的型別都要寫清楚

- prober.dart:117-122 的 answer 分支是同步呼叫 `done(...)`。`run()` 若丟例外，會被 `catchError` 接到，變成 `done(failed())`，也就是 `Res.broken`（prober.dart:150-153、:89）。
- 2.3 要在 answer 這一步 `await openNet(rel)`（Keystore）。如果這段沒有自己的 try/catch，打不開或 Keystore 出錯時，這台節點會從「已讀到」變成 Broken，顏色就變了。這和 2.3「失敗不影響讀取本身的顏色」相反。
- `cancelled`（佔用被拿走）或 20 s 的 answer 計時，如果剛好在 `await` 中觸發，這一輪的讀取就變成沒有回應。
- 修法：
  - hint 用自己的 try/catch，不經 `keyError`；
  - 或者先用 `page_info` 決定要不要開紀錄，並把 `done(body)` 放在 hint 算完之後，但在 `result.isCompleted` 之後不再改；
  - 測試加兩條：openNet 丟例外時結果仍是 `Res.body`、顏色相同；openNet 執行中 cancelled 時結果是 noResponse，不是 broken。
- 另外，`Outcome.extra` 現在是 `StatusView`，home_page.dart:40、:147 直接用 `is StatusView` 判斷。改成包裝型別時，這兩處要一起改，計畫應該列出來。

### m2. §2.9「收隊員的申請：網路由申請本身決定，照舊 815-864 的 `_pickNet`」自相矛盾

- 舊 `_checkRequest` 是讓使用者選網路（nodes.dart:816，`_pickNet('這份申請是哪個網路的？', only: applied)`）。
- Rust 沒有「從申請取得網路代號」的入口：member.rs 的公開函式只有 `net_check_joinreq(record_plain, hex)`（member.rs:85），要先給紀錄。
- 修法：照舊，讓使用者選網路（只列 applied）；或者明寫「對每個 applied 的 net 跑 `netCheckJoinreq`，取第一個不報錯的」，並說明這是新行為。

### m3. 選網路時要保留 `applied` 篩選

- 舊的邀請、收申請、隊員名單、更新包都用 `only: (v) => v.applied`（nodes.dart:802、:816、:1314、:1452）。
- 2.6 / 2.7.1 / 2.9 的「選網路」沒有寫這個篩選。照抄應該帶上；沒帶的話，建立中的網路也會被列出來，選了才被 Rust 拒絕。

### m4. 8.4 每一列的內容沒有寫：名字、指紋、節點、`note`

- 舊 `_updates` 每列是 `${p.name}（${p.fpr}）…節點`，加上 `p.note`（nodes.dart:1483-1484）。
- `note` 是 Rust 給的現場指示（rekey.rs:318-323），例如「升級前的版本不明 —— 若他匯入失敗，請讓他的節點離開網路、再重新邀請」、「先貼同意包、再貼更新包；順序反了就要重新邀請那台」。
- D-M2 要求 8.4 也有指紋，v3 只寫了 8.1 / 8.2 / 8.3。2.6 第 10 項應寫明這四樣都照搬。

### m5. §2.9 漏了舊「忘記加入中的節點」對話框裡的「排除這台（換密碼）」

- 舊 `_forgetJoiningBody` 在 devTrust 時多給一個「排除這台（換密碼）」（nodes.dart:1281-1289），之後跑 `_remove(net, node:)`（:1305-1309）。
- 新的忘記入口（PR 3，net_pages.dart:304-330）沒有這一顆。
- 新的去處其實是 8.2 自己那一組的「排除 …xxxx」：`netPeople` 包含加入中的節點，rekey.rs:72-77。但 8.1 只列 applied 的網路，而舊對話框也接受還沒 applied 的網路。
- 修法：§2.9 表加一列，寫明去處是 8.2，以及建立中的網路要怎麼辦（或寫明不支援）。

### m6. 8.5「送到節點」沒有寫送到哪一台

- 2.6 第 14 項：`OpSession.once(c.sendUpdateFor(member:true))`，沒有節點。8.5 是從設定頁或節點頁進來的，不一定有節點的脈絡。
- Rust 會擋掉不在這個網路的節點（updflow.rs:243 `OtherNetwork`），所以送錯不會出事。但頁面得先決定一台。
- 建議：用 mnet 的入口節點（`memberEntryOf`），或者讓使用者從手機的 `node/` 節點裡選。從節點頁進來時，就用那一台。

### m7. A-m7「只在入口節點加入」比舊程式嚴，§4 沒有列成偏離

- 舊 `_memberJoin` 在任何已登入的節點上都會跑（nodes.dart:1040-1062），沒有檢查入口節點。
- 2.6 第 13 項說「沒有那台的 `node/` 紀錄時，顯示舊的原因句」，但舊程式裡沒有這樣的句子。
- 另外，`memberEntryOf` 只比對後四碼（member_ui.dart:256）。
- 修法：列成 D9，附上理由（Rust 的 join2 對隊員只接受申請時的那一台？要附證據，或者標成推測），並寫出新的原因句。

### m8. `AppLink` 沒有 devTrust

- 第 6 步第 8 項說「`NodePage` 由 `AppLink` 拿 devTrust」，但 app_link.dart 裡沒有 devTrust。現在是 `HomePage` 用建構參數接（home_page.dart:85-88），`NetFormPage` / `AddedPage` 一層一層傳下去。
- 要寫明從哪裡來：建構參數，或在 AppLink 上新增一個欄位。「把新密碼送給節點」只有 Dart 這一層 gate（owner.rs:1041），來源不能含糊。

### m9. 「把新密碼送給節點」從「已登入」改成「只在 devTrust」，沒有列成偏離

- 舊條件是 `if (logged)`，不分版本（nodes.dart:1742-1746）。新的「更多」入口與提示行的按鈕只在 devTrust。
- 推測對 field 沒有影響：換密碼只來自移除（dev_gate），field 的版本號不會前進，所以不會落後。但這是推測，要附證據（版本號只在 rekey 時前進：rekey.rs:330 / approve.rs）。
- 建議列成 D 項；或者提示行不加 gate，只讓按鈕跟著 Rust。

### m10. `copyCode` 一次放 262 144 字元進剪貼簿，沒有在真機上試過

- `setPrimaryClip` 走 Binder。262 144 個字元的 UTF-16 約 512 KiB，接近交易緩衝區約 1 MiB 的上限。
- 舊程式用 Flutter 的 `Clipboard.setData`，同一條路。但 `copyCode` 是新的 Kotlin 程式碼，又多加了 extras。
- 建議 §7 加一項：在 S20 上用 128 KiB 的假更新包試一次複製加貼上（不動節點）。
- ⚠️ 沒有量過，是推測。

### m11. 7.9「放棄申請」的確認句要說清楚後果

- 刪掉 mpend 之後，隊長若已經同意，那份同意碼就匯入不了。舊程式在沒有 mpend 時會丟「找不到申請」（nodes.dart:1011），`member_import_prepare` 也要 `pend_plain`（member.rs:245）。
- 確認句應寫：「如果隊長已經同意，這份同意也不能用了，要重新邀請」。

### m12. 小地方

- 2.3 寫「prober.dart:123」，實際上 answer 分支在 prober.dart:117-122。
- 2.4 的程式簽名寫 `lease.hold()`，但拿佔用其實是 `a.link.acquire(name, LeaseKind.session)`（node_link.dart:177，例如 more_pages.dart:80）。要寫明先 acquire，再 run 或 hold。
- 3.1 擁有權表裡，`InviteHolds` 的寫入者漏了「使用者放棄」（2.5 有寫）。

## 擁有權 / 契約 / 生命週期

- **擁有權**：
  - net / mnet / mpend：寫入的有 `OfflineOp`（approve、import、放棄、remove）與 OwnerConsole 的 persistPend / persistMnet，都在佔用裡，經 `RecordWriter`。同一時間只有一個持有者（lease.dart:131-136），可以接受。
  - prober 只讀，而且只在沒有佔用時跑。
- **契約**：
  - `Outcome.extra` 的型別要改（m1）；
  - `OfflineReply` 與 `qrMatrix` 沒問題。
- **生命週期**：
  - 下面兩條路徑 3.3 沒有列：
    - 「member join 結果不明之後重試」（M2）；
    - 「節點落後時打開節點頁」（M1）。
  - 斷電、斷線之後的重試路徑，正是 M2 的情境 (a)。
- **安全**：
  - 每一種 actor 都看過了，沒有發現新的 fail-open。除了 M1：被移除的人仍連得上落後的節點，而 UI 沒有提示。
  - 剪貼簿、記錄、FLAG_SECURE 的處理可以接受。
  - `[JOINREQ]` 的 answer 文字帶隊員名稱（owner.rs:1313-1316）。T-U6 加假名稱是對的，請確定新頁面顯示 `reply.text` 的那條路不會寫進文字紀錄。

## 判定

**APPROVE-WITH-CHANGES**。BLOCKER 0、MAJOR 2、MINOR 12。

- M1、M2 都不用改 Rust，也不用改 PR 3 / 4 的機制。只要改節點頁的顯示條件、補設定頁的一列、補 `NetFormPage` 的 ask 分支，並各加一個有負對照的 widget 測試。
- 修完之後整份再審一次。
