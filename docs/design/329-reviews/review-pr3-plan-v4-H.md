# #329 PR 3 實作計畫 v4：對抗式審查（審查者 H，獨立）

審查對象：`docs/design/329-pr3-plan.md` v4（commit 514d3df，branch `feat/329-pr3`），整份重審。上層：`docs/design/329-app-uiux.md` v12.1。對照 v1（A、B）、v2（C、D）、v3（E、F）六份審查。原始碼：同一個工作樹。除本檔外沒有改任何檔案；沒有跑測試、建置或真機。

## 結論

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER、3 MAJOR、14 MINOR）。三個 MAJOR 都是局部修文，不用改結構；照使用者規則，改完仍要整份再審一次。

v4 拿掉「重新建立」是對的：v3 的 E-B1 / F-B1 在新頁面上消失了。`loginFor` 的掃描與叫醒（E-M3）、`loginOutcome` 共用（F-M1）、`openRawPageFor<T>`（F-M2）也都處理到可以開工。

剩下的三個 MAJOR：

1. **M1** §2.2.1 用重讀紀錄判定的方向對，但判定表**寫錯了 Rust 的成員狀態**。照字面實作，每一次成功的建立與加入都不會被判成 `applied`。
2. **M2** dev 版「到舊控制台重新建立」**沒有任何條件**。它會留下一筆永遠在的 pending 紀錄與待辦；之後點那個待辦，會對一台**已經在新網路裡的建立者**再給一次「重新建立」。
3. **M3** D4 的理由前後不一致。計畫說重建不可靠，所以新頁面不做；卻在 dev 版無條件提供同一個動作。field 版的死路只寫成殘項，沒有綁住出貨。

---

## MAJOR

### M1　§2.2.1 的判定表和 Rust 的成員狀態對不上：成功的建立 / 加入都判不成 `applied`；`confirmNetwork` 成功會被判成 `absent`

**情境**
- 隊長從零建網，04 建立成功。`makeNetwork` 之後重讀：網路是 applied，但 04 的成員項是 `Applied`，不是 `approved`。§2.2.1 的 `applied` 列要求「這台的成員項 `approved`」，所以這一筆不成立。
  - 照 §2.3 第 2 步「建立者不是 `applied` → 整個流程停」，**成功的建立也會讓多台流程停下**，結果頁還會給「檢查網路」。
- 02 加入成功：成員項同樣是 `Applied`，判不成 `applied`，也不會做連線檢查。
- 從待辦進 §2.8 按「檢查網路」，節點已套用，`confirm` 把紀錄升級。但升級後的建立者成員項**沒有 device id**，所以「以 `MemberView.deviceId` 對」找不到這台，結果是 `absent`。§2.8 寫的「`applied` → 回首頁」永遠走不到。

**證據**（✅ 原始碼原文）
- `MemberView.approved` 只代表 `Approved`；`Applied` 的成員是 `joining = false`、`approved = false`。
  - owner.rs:118 `joining: m.state == MemberState::Joining,`
  - owner.rs:122 `approved: m.state == MemberState::Approved,`
  - owner.rs:84-85 的註解：approved =「a remote member's node this phone approved (member-join §3)」，也就是別人的節點。
- 加入成功的成員項是 `Applied`：join2flow.rs:528-530 `fn applied(...) { let mut e = self.me.clone()?; e.state = MemberState::Applied;`
- 建立成功：owner.rs:1463-1469 把紀錄改成 APPLIED，並把每個成員的 `device_id` 設成這台。成員來自 `members()`，v1 清單在 APPLIED 時的狀態是 `Applied`（netrec.rs:395）。
- pending 紀錄裡的建立者：netrec.rs:395 `None => self.v1_members(if self.state == APPLIED { MemberState::Applied } else { MemberState::Joining })`，加上 netrec.rs:212 `device_id: None`。也就是 `joining = true`，沒有 device id。
- `confirm` 升級時只改狀態，不補 device id：netrec.rs:526-527 `for m in list.iter_mut().filter(|m| m.dac_pub_hash == creator && ...) { m.state = MemberState::Applied;`
- 其他沒寫到的結束方式：
  - 加入確定失敗時，成員項被刪掉；只有 `NotSent` 會還原成原本的成員項（join2flow.rs:507-514 `after_fail`）。
  - `Revert::NotReverted` 時成員項留著、仍是 joining（join2flow.rs:94-95）。照表會顯示「結果不明」，Rust 那句「國家沒有改回來」就不顯示了。
- 計畫自己的兩處寫法彼此衝突：
  - pending 建立者是 `joining`，所以它同時符合 `joining`（「結果不明 + 再試這一台」）與 `notApplied`（「檢查網路」），計畫沒有寫哪一個優先。
  - `makeNetwork` 在 `PersistNet` 之前就結束（金鑰失敗、`BadChannel`、拒絕）時，根本沒有 `rel` 可以重讀，計畫沒有寫要判成什麼。F-m4 的「沒有 PersistNet → 不重讀」在 v4 沒有保留下來。這時 §2.3 第 2 步會給一顆沒有對象的「檢查網路」。

**為什麼是 MAJOR**
- 這是 PR 3 的主路徑（從零建網、加入），照字面寫會整條停住。
- 新測試會在 Dart 裡自己建 `MemberView`（目前沒有任何地方這樣做，`grep "MemberView("` 只命中產生的檔案）。如果測試照計畫的表把 fake 設成 `approved: true`，離線測試會全綠，到真機才會發現。這和記憶裡「stub 要照真工具輸出格式」是同一類錯。

**修法**
1. 改寫 §2.2.1，依動作分開判定：
   - **建立、檢查網路**：只看網路狀態。`applied` ⇔ 重讀後紀錄是 applied；否則是 `notApplied`。不靠成員項找這一台（建立者在 pending 時沒有 device id，升級後也沒有）。
   - **加入**：找這台的成員項（`deviceId` 對）。
     - `applied` ⇔ 成員項 `!joining && !approved`，而且網路是 applied。建議在 Rust `MemberView` 加 `applied: bool`，這樣就不用在 Dart 推導。
     - `joining` → 「結果不明」，**同時**顯示 Rust 的句子（`NotReverted` 的國家提示不能丟）。
     - 沒有成員項 → `absent`。
2. 寫明判定的優先順序：`leaseLost` > `keyFail` > `cancelled` > `noLink` > `notSent`（以上都不重讀）> 重讀失敗 `unreadable` > 重讀的分類。
   - 寫明「沒有 `rel`（`PersistNet` 之前就結束）」= 什麼都沒寫：建立 → 「沒有建立」+ 回 4.1，不給「檢查網路」。
   - 寫明「`rel` 讀回來是不存在」= 寫入沒有成功 → 同上。
3. §7 第 3 步的判定測試，紀錄要用**真的 Rust** 產生：用 Rust 測試的 `make` / `join` 流程產出 applied、pending、joining、NotReverted 的紀錄，再經 `net_summary`。不准在 Dart 手寫 `MemberView`。
   - 改壞：`applied` 改回「`approved`」→ 建立成功、加入成功、檢查網路成功三個案例都 FAIL。

### M2　dev 版「到舊控制台重新建立」沒有條件：留下永久的 pending 與待辦，之後會對已在新網路裡的建立者再給一次重建

**情境**（就是計畫 §8 的情境 2，在唯一跑得起來的 dev 版上）
1. 建立途中拔 04 的電，紀錄 A 停在 pending。
2. 待辦 → §2.8 → 檢查得到 NotApplied → 按「到舊控制台重新建立」→ 舊控制台產生新的網路 B（新的網路編號）。A 留著（計畫 P19 自己寫的）。
3. 02 加入 B，隊伍正常運作。
4. 首頁的待辦「建立網路沒有確認完」**永遠不會消失**：§2.7 的條件是「有 net、`applied = false`」，而 A 永遠是 pending。也沒有任何介面能丟掉一筆 pending 的 net：舊控制台只有忘記節點、丟掉申請、忘記加入中的成員，沒有丟掉網路紀錄。
5. 使用者點那個待辦 → §2.8 → 登入 04（現在在 B）→ `confirmNetwork(A)` 得到 OtherNetwork → 頁面顯示句子，**dev 版另外給「到舊控制台重新建立」**。
6. 照著按下去 → 舊控制台對一台已在 B、而 B 有其他成員的節點送「建立網路」。

**證據**
- ✅ §2.8 的 dev 按鈕條件只有「不是 applied」（計畫 :244-245），沒有看手機有沒有已套用的網路，也沒有看結果是哪一種狀態。
- ✅ Rust `request_make_network` 不檢查節點目前在不在網路裡：owner.rs:1067-1088 只檢查 `flow_busy`、`self.node` 與 `St::Conn`。
- ✅ 舊控制台沒有丟掉 net 紀錄的動作：`grep storeRemove lib/nodes.dart` 只有 `node/`（:467）與 `mpend/`（:1026）。
- ⚠️ 節點收到「建立網路」時如果自己已經在網路裡，會拒絕還是照做，要看節點端（firmware repo），本 repo 查不到。如果照做，就是 04 離開 B、02 留在 B：隊伍分裂，也就是 §6 列的資產。
- E-m9（多筆 pending）在 v4 沒有處理，§12 的對照表也沒有列。重建一次就會出現多筆，§2.8「pending 那筆」是哪一筆沒有定義。

**修法**（最小的做法，不加新機制）
- §2.8 的 dev 按鈕只在「手機**沒有任何已套用的 net**」時出現。有已套用的 net 時，§2.8 只顯示句子，加一行「這是先前沒有完成的網路，可以不理它」。
- §2.7：手機有已套用的 net 時，「建立網路沒有確認完」不當成待辦（`decideHome` 的第 11 列不算它），只在 §2.8 或設定裡留一列資訊。這樣第 6 列與待辦就不會永遠是黃的。
- 寫明多筆 pending 的處理：每筆各自一個入口，或只取最新的一筆。
- 殘項加一條「丟掉一筆未完成的網路紀錄（留副本）」，和 D4 的殘項放在一起。
- 測試（T-R1 補）：有已套用的 B、加上 pending 的 A → §2.8 沒有 dev 按鈕、沒有待辦。改壞：拿掉條件 → FAIL。

### M3　D4：理由前後不一致，field 版的死路沒有綁住出貨

**證據與推理**
- 計畫說可靠的重建要 Rust 回結構化狀態，而且要確認登入的是建立者（P20）。PR 3 因此不在新頁面做重建，但在 dev 版無條件導去舊控制台做同一件事。
  - 唯一的差別是舊控制台**不刪舊紀錄**。這正好說明風險主要來自 v3 的「刪紀錄」，不是重建本身。
  - pending 的網路不會有其他成員（加入要求網路已套用，join2flow.rs:340-342 `if rec.state != netrec::APPLIED { return Err(End::Refused(Pre::NotApplied)) }`）。所以「只有 pending、沒有任何已套用的 net」時再建一個（舊紀錄留著）不會讓別台分裂，最壞只是建立者落在兩筆紀錄的其中一筆，兩筆都還在手機上。
- field 版跑不起來（#255），所以現在不影響使用者。但 #255 修好的那一刻，這就是 D-B1 的死路：
  - 有 pending → 閘門不准建立；
  - 加入要求已套用；
  - 檢查網路升不上去；
  - 最後只能重裝，所有節點重燒。

  建立者壞掉或遺失（E-M2）也落在同一條死路。
- 使用者的規則是「範圍從現場推」。殘項本身可以接受（不開新單，寫進 checklist），但它是 field 出貨的前提，不只是一行待做。

**修法**（二擇一，寫進 D4）
- (a) 照上面的推理，新頁面在「只有 pending、沒有任何已套用的 net」時**允許建立**（舊紀錄留著，兩個版本一樣），閘門表加一列，也要有改壞對照。這樣 dev 版不用回舊控制台，field 版也沒有死路，Rust 一行都不用改。
  - 剩下的風險（建立者正在套用舊網路時收到新的建立要求）照實寫進 §6。
  - 這個做法和 M2 的條件（有已套用的 net 時不給）一起用。
- (b) 維持 D4。在 #329 的 checklist **和** #255 寫明：「field 版出貨前必須先有網路沒有套用時的出口」，並列成 field 出貨的阻擋條件；§9 的 PR 內文也照寫。

---

## MINOR

1. **live `KeyAbilities` 擋下的 `precondition(keys)` 不一定會讓 `core.blocked` 成立**（§2.1 開始前的檢查只回傳結果，不呼叫 `setRadio`）。
   - §2.3 的停止規則是先看 `core.blocked`，否則「`noLink` → 問繼續」。這樣金鑰不能用時，會一台一台問下去。§7 第 5 步的改壞「前提類問繼續」說明作者本意是要停。
   - 修法：寫明 `noLink(precondition(_))` 一律整個流程停，不看 `core.blocked`。
2. **連線檢查的結果沒有進契約。** `applied` 之後的連線檢查（每 10 s、最多 120 s）沒連上時，結果頁該寫什麼，§2.2.1 與 §2.3 都沒有寫。被入侵或還在開機的節點回「已套用」卻沒連上，使用者會看到「完成」。
   - 修法：多一種「完成，還沒確認連上」，下一步「看這台節點」。
3. **頁面消失後的「做完當前請求」可能超過 420 s。** 一台加入 = 重新登入 60 s + 加入（每次寫入重新計 360 s）+ `sendUpdate` + 連線檢查 120 s。超過之後佔用會被收回，寫入被拒，成員項停在 joining。結果仍是 fail-closed，由待辦接手。
   - 修法：寫明 `pageGone` 之後不做連線檢查（可能的話也不開始 `sendUpdate`）。
4. **E-m9、E-m11、E-m12 沒有處理，§12 也沒有列。**
   - E-m9 多筆 pending：見 M2。
   - E-m11：剛認領完時 `NetIndex` 還在計算，3.5 / 3.6 該顯示什麼沒寫。§2.4 只寫了第 6 列。
   - E-m12：`NodeLink.dispose` 要一併停掉 `_lf*`（node_link.dart:352-358 只處理自動讀取的欄位）。
5. **和設計不同、但沒有寫進 §4 的地方：**
   - 設計 §5.4 的表是「建立回來不是已套用 → 自動做一次檢查網路」。計畫是整個流程停、讓使用者按。A18 還沒量測，這要寫成 D5。
   - 設計 §5.4 的「結果不明 → 下一步 = 檢查網路」。計畫對加入給「再試這一台」。計畫的做法比較對：`confirm` 不會升級加入者，netrec.rs:524-527 只升級建立者。但要寫出來。
   - 設計 §4.3.8 把摘要表放在 `NodeLink`，計畫改成 `NetIndex`。
   - 第 6 列多了「檢查網路」這個去處。
6. **§2.8 的對象對應。**
   - E-m4 建議用 `dac_hash` 對，§12 的回應「pending 建立者沒有 device id」答非所問：`dac_hash` 和 device id 無關，pending 的成員項就有它。
   - 用 `name` 對時：Rust 的 `last4` 取自 device id 原字（owner.rs:679），首頁的 `last4()` 會轉大寫（home_logic.dart:8）。要寫明比對不分大小寫。
7. **`FrameInbox` 的交接細節。**
   - prober 在處理 `loggedIn` 那一步時，要在第一個 `await` 之前**同步**把處理者設成「無」（之後到的訊框進暫存）。否則依現在 `SessionProber` 的寫法（prober.dart:134 `if (result.isCompleted) return;`），結果決定後到的訊框會被吃掉丟棄。
   - 另外，`gate.scan` 回來之前的掃描回呼（`LoginFor` 還沒建立）要先存著或忽略，計畫要寫明。
8. **`loginOutcome` 的範圍。** 寫明它只對 `ended` 那一步（`loginEnd`、`loginCode`、`loggedIn`）。HandoffProber 的「`loggedIn` → `Res.body`」是它自己的分支，不放進共用函式。否則 `SessionProber` 若在 `loggedIn` 就呼叫它，會不讀狀態頁就結束。照這樣寫，A7 成立（⚠️ 推論，沒有實跑）。
9. **複製的控制台會漂移。** 9b00ca6 的四條路徑測試只對舊控制台跑。建議改成表格驅動，讓同一組情境也對 `OwnerConsole` 跑；兩邊行為不同的地方（§2.2 的 1–8）在表裡標成例外。
10. **建立模式有多台「剛讀到、還沒加入網路」時，建立者是哪一台沒寫**（例如第一台，或讓使用者選）。
11. **真機 §8 缺使用者列的兩條真實路徑：**「加入結果不明、節點其實已套用」（T-M2(c) 只在模擬裡）、dev 的重建出口（M2 情境）。要嘛加進場次，要嘛在 PR 內文標成 ⚠️ 模擬。
12. **A6 的寫法。** `Directory.list()` 對不存在的目錄，錯誤是從串流送出來的，不是呼叫當下丟例外（⚠️ 依 Dart SDK 知識，沒有實跑）。要在 `await for` / `toList()` 那一層接；開工時的測試要涵蓋這一點。
13. **再試一台加入確定失敗（代碼 4）沒有意義。** `absent` 一律給「再試這一台」：對 `Rejected` 只會再失敗一次，無害。可以只在 Rust 句子屬於可重試的情況才給，或者接受現況並寫明。
14. **row 6「檢查網路」的對象。** 第 6 列對的是「還沒加入網路的那一台」（例如 02），但「檢查網路」登入的是建立者（04）。句子要寫明是檢查哪一台，否則使用者會以為在處理 02。

---

## 更早的 BLOCKER / MAJOR 逐條

| 項目 | v4 判定 |
|---|---|
| A-B1 / B-B1 佔用下的登入 | ✅ §2.1 `loginFor`（C 已確認；本輪核對 core.dart:628-748、node_link.dart:150-233） |
| B-B2 建立或加入 | ✅ 建立閘門表（佔用下重新列檔、fail-closed）；M3 (a) 若採用要加一列 |
| A-M1…M8、B-M1…M6 | ⚠️ 依 C、D 的對照判定已解；本輪只抽查 A-M4（摘要 fail-closed，§2.4 ✅）、A-M5 / B-M3（`ClaimDone`、F41，§2.6 ✅） |
| C-M1 驅動器掃描 | ✅ §2.1 寫了叫醒、名額不計入、重掃、60 s 收尾（也解掉 E-M3） |
| C-M2 `Refused` ≠ 佔用遺失 | ✅ |
| C-M3 4.1 / 閘門 | ✅ |
| C-M4 找建立者 | ✅（m6） |
| C-M5 閘門改壞 | ✅ |
| D-B1 建立失敗死路 | ⚠️ dev 有出口但沒有條件（M2）；field 仍是死路（M3） |
| D-M1 結果契約 | ⚠️ 方向對（重讀紀錄），判定表錯（M1） |
| D-M2、D-M3、D-M4 | ✅ |
| E-B1 / F-B1 重新建立 | ✅ 新頁面拿掉了；同一個風險在 dev 的舊控制台出口，見 M2 |
| E-M1 標籤分類 | ⚠️ 不用標籤 ✅；判定表錯（M1） |
| E-M2 建立者不在了 | ⚠️ 進殘項（M3） |
| E-M3 掃描 / 叫醒 / 名額 / 60 s | ✅ |
| F-M1 `HandoffProber` 對應 | ✅ `loginOutcome`（m8） |
| F-M2 `openRawPage<T>` | ✅ 新函式、舊的不動；main.dart:87-88、home_page.dart:55-61 不受影響 |

## 指定要查的問題

- **每個請求結束都對到一個 `ConsoleResult` 嗎**：❌ 目前不行，見 M1：
  - 成功被判錯；
  - 沒有 `rel` 沒定義；
  - pending 建立者同時是 `joining` 與 `notApplied`；
  - `confirm` 成功被判成 `absent`。

  逐一回答指定的情況：
  - CAS 寫入失敗：`persistFailed` 之後紀錄沒變，加入 → `absent` 或原本的狀態，建立 → 沒有紀錄（沒定義）。
  - `Rejected` 的加入：成員項被刪 → `absent`，給「再試」（m13）。
  - 從沒見過的節點：`loginFor` 得 `notFound` → `noLink`。
  - 對錯台按檢查網路：`netrec::confirm` 只比 key 10 / key 9，沒有寫入（netrec.rs:511-519），得 `notApplied` + 句子；dev 另有按鈕，見 M2。
- **D4 可不可以接受**：條件式接受，見 M3。
- **§2.5 / §2.3 和 `home_logic.dart`、設計 §5.1 / §5.3 是否一致**：
  - `home_logic.dart` 的 `NetRecords` 是五個值（:35），第 6 列的 `switch` 在 :92-96，要擴充成 §2.5 的列。
  - 設計 §5.1 第 6 列「不在待辦『加入沒有做完』裡」：計畫只在「有已套用的 net」那一列寫了排除，其他列要一併套用。
  - 差異見 m5。
- **抽出 `loginOutcome` 會不會改變 `SessionProber`**：⚠️ 只要它限定在 `ended` 那一步（prober.dart:94-103），就不會改變；見 m8。
- **`NodeLink` 能不能同時有 `_lf*` 與暫停中的輪**：✅ 可以。
  - 佔用中 `_eligible` 為假（core.dart:168 `started && fg && !lease && ...`），`_pump` 不開掃描。
  - `_pump` 只砍 `_attempt`（node_link.dart:214-215）。
  - `LoginFor.result` 要 `c.lease` 為真（core.dart:690）。
  - `core.tick` 不碰 `_login`，所以 `_lfTimer` 要自己呼叫 `LoginFor.tick`（core.dart:737-742）。計畫寫了自己的計時，可以。
  - 要補的只有 m4 的 `dispose`。
- **`FrameInbox`**：設計可行，交接細節見 m7。
- **`openRawPageFor<T>`**：✅ 不影響現有呼叫者。
- **恢復與覆寫路徑的 `ClaimDone`**：✅ 可行。
  - 恢復有三個入口：T1 replay（claim.dart:459）、T2 找不到時改試恢復（:351-356）、T4 從暫存恢復（:114-150），都經 `_recover` 回 `RecoveryOutcome.recovered`。
  - 覆寫是 `_held` 問過之後走一般的 `_claim`，以 `claimed` 為準。
  - 計畫要列出這三個入口各一個測試，不能只寫「恢復成功」。
  - pop 之後 `finally` 裡的 `rawIdle()` 仍會執行，佔用照常放掉。
- **§2.8 用 `node-<last4>` 對**：✅ 名稱來源是 owner.rs:1080 `node_name: format!("node-{}", self.last4)`，經 joinflow.rs:209 `name: &inp.node_name` 寫進 v1 成員，再由 netrec.rs:384-389 `v1_members` 讀回。A5 成立；大小寫見 m6。

## 安全（逐 actor）

- **遠端 BLE / 惡意廣播**：和 v3 相同。8 s 的 msg2 預算、不認得的結束一律 `noResponse`（prober.dart:100-102 的表搬到共用函式），不會種下錯的「是 Y」。約 7 個不回應的位址能吃光 60 s，設計已接受。
- **被入侵的節點**：
  - 加入時只能換掉自己的成員項（join2flow.rs:355-366，成員項以驗證過的 DAC 計算的 hash 為 key）。
  - 它可以謊稱已套用，讓自己的成員項變成 Applied、結果頁顯示「完成」（m2：連線檢查的結果要進畫面）。
  - 在 §2.8，它被選錯成對象時只能回「不符」，不會寫入。但 dev 的按鈕會讓使用者往重建走（M2）。
- **本機無權限 app**：沒有新的入口、匯出元件或平台方法。`keepScreenOn` 只有軟體更新頁在用（swupdate.dart:137），而它只從舊控制台打開（nodes.dart:1635），都在佔用之下，兩者不會同時。
- **我們自己的錯**：
  - M1（判定表）；
  - M2（無條件的按鈕）；
  - 複製的控制台會漂移（m9）；
  - 原始碼鎖：現況的寫入點只有 nodes.dart、claim_records.dart、app_link.dart、ui_state.dart（grep 結果），新目錄 `lib/src/flows/`、`lib/ui/network_pages.dart` 在鎖的範圍內。
- **秘密**：`OwnerConsole` 只記種類、代碼、後四碼。Rust 的句子只上畫面。`lastClaimNote` 是結果句，不含 BLE 位址。
- **沒有佔用時**：fail-closed 成立。`BleGate._usable` 檢查 token（ble_gate.dart:84-86）；`RecordWriter._check`（record_writer.dart:27-33）沒有佔用就丟 `NoLease`。
- **TOCTOU**：列檔不先 `exists()`（§2.4）；閘門在佔用下重新列檔；新的 net 用 CAS 從 0 開始寫。可以接受。

---

## 我做了什麼

### ✅ 已驗證（原始碼原文節錄）

- owner.rs:118、:122：
  ```
  joining: m.state == MemberState::Joining,
  approved: m.state == MemberState::Approved,
  ```
- join2flow.rs:528-530：
  ```
  fn applied(&mut self, save_pending: bool) -> Option<Action> {
      let mut e = self.me.clone()?;
      e.state = MemberState::Applied;
  ```
- netrec.rs:395：
  ```
  None => self.v1_members(if self.state == APPLIED { MemberState::Applied } else { MemberState::Joining }),
  ```
- netrec.rs:212 `device_id: None,`（`member_base`）
- netrec.rs:526-527：
  ```
  for m in list.iter_mut().filter(|m| m.dac_pub_hash == creator && m.state != MemberState::Applied) {
      m.state = MemberState::Applied;
  ```
  device id 沒有被補上。
- owner.rs:1463-1469：建立成功時 `l.iter_mut().for_each(|m| m.device_id = device_id.clone());`
- join2flow.rs:507-514：`after_fail` 只有 `Fail::NotSent` 還原 `before`，其他是 `None`（成員項被刪）。
- join2flow.rs:340-342：加入要求網路已套用。
- owner.rs:1067-1088：`request_make_network` 不檢查節點在不在網路裡；`node_name: format!("node-{}", self.last4)`。
- owner.rs:1170-1181：`request_confirm_network` 只把紀錄交給 `info-confirm`。owner.rs:879-893：只有 `Upgraded` 時寫入。
- `grep storeRemove lib/nodes.dart` → 只有 :467（`node/`）、:1026（`mpend/`），沒有丟掉 net 紀錄的動作。
- prober.dart:94-103：結束的對應表；:134 結果決定後到的訊框被丟棄。
- core.dart:168 `_eligible`；:286-292 `setRadio` 把 `_login` 結束成 precondition；:628-748 `LoginFor`（start 是 final，`tick` 只把 `running = null`）。
- lease.dart：`hold()` / `pageGone()` / `goneMax = 420 s`。
- raw_use.dart:73-82：`openRawPage` 推 `MaterialPageRoute<void>`。main.dart:87-88、home_page.dart:55-61 用 `busy != null`。
- ble_gate.dart:186-205：掃描在閘門裡等名額；:226-231：`connect` 一次一條；GateLink.close 等 `_links.remove` 之後才回來（:109-128）。
- ui_state.dart:131-138：`_save` 串成一列（P23 ✅）。
- main.dart:196-205、simple.rs:31-48（P26 ✅）。
- swupdate.dart:137 是 `keepScreenOn` 唯一的使用者，只從 nodes.dart:1635 打開。
- 事實表核對結果：
  - 一致：P5、P7、P8、P9、P10、P14、P15、P16、P17、P19、P20、P23、P25、P26。
  - P24：行號差一兩行，內容一致。

### ⚠️ 推論（沒有實跑）

- M1「照字面實作，成功判不成 `applied`」：依原始碼推論，沒有寫程式驗證。
- M2 第 6 步：節點在網路裡時收到建立要求的行為，要看 firmware，本 repo 查不到。
- m3 的 420 s 超時：依各段的逾時相加推論。
- m8 / A7：依 prober.dart 的結構推論，沒有實際抽出函式跑測試。
- m12：`Directory.list` 的錯誤傳遞方式，依 Dart SDK 知識。

### ❌ 沒做

- 沒有跑 Dart、Rust 測試或 `flutter analyze`。
- 沒有上真機。
- 沒有逐條重驗 v1 A / B 的每一個 MAJOR（依 C、D 的對照，抽查兩項）。
- 沒有讀 nodes.dart 請求機制的全文（P1–P4 只抽查 :467、:476-490、:1026）。
- 沒有驗證 9b00ca6 的「改壞 5/5」（P12）。
