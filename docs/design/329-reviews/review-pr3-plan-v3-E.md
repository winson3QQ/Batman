# #329 PR 3 實作計畫 v3：對抗式審查（審查者 E，獨立）

審查對象：`docs/design/329-pr3-plan.md` v3（commit cc0c2bf，branch `feat/329-pr3`）。上層：`docs/design/329-app-uiux.md` v12.1。對照 v1 審查 A / B、v2 審查 C / D。原始碼：同一工作樹。除本檔外沒有改任何檔案，也沒有跑測試或建置。

## 結論

**Verdict：REJECT**（改版後整份重審）。1 個 BLOCKER、3 個 MAJOR、13 個 MINOR。

v3 確實處理了 v2 的大部分問題：
- 驅動器改成自己掃描（C-M1）。
- `leaseLost` 改成只看 `lease.valid`（C-M2、D-M1 的一半）。
- 4.1 表單與建立閘門寫成兩張表，各有改壞（C-M3、C-M5、D-M4）。
- `HandoffProber` 改成獨立類別、用 inbox 交接（D-M2）。
- 勾選規則改成 `netId` 等於目標時可以勾（D-M3）。
- 建立失敗後加了出口 §2.8（D-B1）。

剩下的問題集中在兩處，都和 Rust 實際回什麼有關：
1. **§2.8**（D-B1 的修法）用來判斷「節點明確不在這個網路」的資料，Dart 拿不到。照字面寫的條件，又把「節點還在套用中」也算進去。
2. **§2.2.1** 的結果契約靠 Rust 的字頭標籤分類，但這些標籤是給人看、給 log 用的記號，不是機器可用的分類，`[JOIN_STATE]` 底下混著確定失敗與結果不明。

另外兩件：建立者壞掉或遺失時，死路仍然存在；`loginFor` 驅動器的叫醒來源與掃描名額沒有寫清楚。

這些都是局部修正，不需要改結構。

---

## BLOCKER

### B1　§2.8「節點明確不在這個網路」：Dart 拿不到這個資料；照字面寫，「還在套用中」也會給「重新建立」

**情境**：隊長建網，建立者收到要求後開始套用，套用要一段時間（Rust 註解寫最多 960 s）。這時手機斷線或逾時，紀錄停在 pending。隊長從待辦進 §2.8，按「檢查網路」。節點回 info：key 10 還沒有、key 11 = true（還在設定中）。§2.8 第 2 條寫「info key 10 沒有……→ 顯示『重新建立』」。隊長按下去，紀錄被移走，再建一個新網路。幾分鐘後，建立者把舊網路套用完成，進了一個手機已經丟掉的網路。

**證據**：
- `request_confirm_network` 與 `check_network` 的結果只以文字回來，沒有結構化欄位。`Ok(c) => OwnerStep::text(OwnerKind::Answer, confirm_text(&c))`（owner.rs:885-893）；`confirm_text` 產生 `[NET_STATE] …中文…`（owner.rs:484-491）。`OwnerStep`（owner.rs:206-250）沒有任何欄位帶 `JoinState` / `Confirm`。舊控制台也只把它當成字串顯示（nodes.dart:1240-1245）。
- 計畫 §2.2.1 自己規定「不解析中文句子」，§2.8 的 Rust 改動只有 `store_keep_copy` 與 `RECORD_KINDS` 兩項。所以這個判斷在計畫裡**沒有資料來源**。
  - P24 提到的 `StatusView.netId` 要先讀狀態頁，可是 §2.2 寫明狀態頁「不複製」。
  - NodeLink 在佔用期間不讀。
- 「key 10 沒有」底下其實有三種不同的狀態（batman-proto flow.rs:143-173）：
  - `InProgress`：10 沒有、11 = true，還在套用，要輪詢，最多 960 s。
  - `NotApplied`：10 沒有、11 = false，沒有套用或已還原。
  - `Unknown`：9 / 10 / 11 都沒有（`E_RATE`）或格式不對。

  Rust 自己對 `InProgress` 的句子是「還在設定中，請一分鐘後再按『檢查網路』」，對 `Unknown` 是「目前還無法確定」（owner.rs:477-480）。照 §2.8 的字面，這兩種都會給「重新建立」。
- `OtherNetwork`（10 有、但不是這個 net）也符合「不是這個 net id」。這時建立者已經在別的網路裡，照 §2.3 它不能當建立者，重新建立對它沒有用。
- 計畫 §6 說這裡「fail-closed」，但它的條件比 Rust 定義的「沒有套用」寬。

**後果**：
- 建立者最後落在手機已丟掉的網路裡。手機沒有任何紀錄指向那個網路：`forgotten-net/` 只是留副本，沒有讀回的路徑（claim.rs:131-133「no restore in this version」）。
- 之後這台在 4.1 會顯示「在網路裡、`netId` 不是目標」，不能勾，要重設節點才能恢復。
- 這正是 §6 列的資產「隊伍不分裂」。

**修法**：
1. Rust 的確認答覆帶結構化狀態，例如 `OwnerStep.net_state: u8`，值為 Upgraded / Already / OtherVersion / NotApplied / InProgress / OtherNetwork / Unknown。這要加進 §2.8「Rust 改動」，並附一個 Rust 測試。`check_network`（建立時的自動檢查）走同一條路。
2. 「重新建立」只在 `NotApplied` 時出現。其他狀態都 fail-closed：`InProgress` 的句子是「還在設定中，一分鐘後再檢查」；`OtherNetwork` 是另一種句子。
3. T-R1 加四個案例：InProgress、Unknown（E_RATE）、OtherNetwork、OtherVersion，各自都不顯示按鈕。
   - §7 步驟 6 的改壞「拿掉條件 2」只有用這些案例才抓得到。節點真的已套用時，`confirm` 會直接升級（owner.rs:886-890），根本到不了按鈕，所以計畫現在寫的「節點其實已套用也被丟」不是有效的對照。
4. （請比較，不是要求）Rust 對 `NotApplied` 的句子是「可以再建立一次同一個網路」（owner.rs:478）。另一個做法是對同一筆 pending 紀錄、用同一個 net_id 再送一次 make-network：不刪紀錄，`forgotten-net`、`RECORD_KINDS`、`keepCopy(net)` 都不用改。代價是 Rust 要多一個「從現有 pending 紀錄重送」的入口（現在只有 `Join::resend` 在 NewNonce 時用，owner.rs:1470-1481）。選哪一個由作者決定，但要在 D4 寫明為什麼。

---

## MAJOR

### M1　`ConsoleResult` 靠字頭標籤分類，但標籤不分「確定」與「不明」；`joined` 只看 `pollLink` 會漏掉成功的加入

**證據**（owner.rs:498-566 `join2_text`，:1430-1442 `join2_step`）：
- `[JOIN_STATE]` 底下不只是「結果不明」：
  - `Unclear7` / `Unclear`：確實是不明。
  - `TwiceRefused`、`NonceRefused`：確定沒有送出或被拒。
  - `Failed(Rejected | OtherNetwork | NotApplied | NotSent)`：都是確定的失敗，還帶 `Revert` 尾句。

  計畫 §2.2.1 把所有 `[JOIN_STATE]` 都對到 `rustUnclear` →「結果不明」+「再試這一台」。結果是「這台已在別的網路」「節點不接受這份網路設定」也會顯示「結果不明」，還給「再試」。
- `[COUNTRY]` 有兩種意思：`Declined`（已取消）與 `Keep::CountryUnknown`（「國家狀態不明」，其實是不明）。計畫寫「`[COUNTRY]` 且已取消」，這等於要解析中文「已取消」，違反計畫自己的規則；而 `CountryUnknown` 也沒有對應的種類。
- `[REQ_FAIL]` 裡有 `PersistFailed { applied: true }`：「節點已套用，手機紀錄沒存好……請在這台按『加入網路』」。計畫把它當 `refused`，結果頁不給「再試這一台」。待辦還能接手（成員仍是 joining），所以只是體驗差。
- `joined ⇔ pollLink` 不成立：
  - `poll_link = Applied { country_unverified: false } && !behind`（owner.rs:1437）。
  - `Applied { country_unverified: true }` 的答覆是 `[JOINED]` 已套用，但 `pollLink = false`。計畫的表裡沒有它的位置，成功的加入會被歸到失敗或沒有分類。
  - `behind` 的情況走 `send_update`，計畫有寫；`country_unverified` 沒有。
- 這些標籤是 log 記號，不是穩定的機器標記：
  - nodes.dart:155 自己的註解稱它們是「log markers」。
  - Dart 自己也會產生同樣的標籤：nodes.dart:658 `'[JOIN_STATE] 已取消…'`、:55 `'[REQ_FAIL] 結果不明…'`、:531 `_waitLine = '[REQ_FAIL] … 結果不明'`。
  - owner.rs:1777 的測試釘的是整句中文，不是標籤。

**修法**（擇一，寫進 §2.2.1，並附改壞）：
- (a) 和「建立」一樣，看紀錄，不看文字。加入的答覆回來後，用 `rel` 重讀 net 紀錄，用 device id 或 dac_hash 找這台的成員項：
  - `applied` → `joined`（`pollLink` 只決定要不要做連線檢查）；
  - 仍是 `joining` → 「沒有完成」（給「再試這一台」）；
  - 不在紀錄裡 → 確定失敗。

  Rust 一個字都不用改，也涵蓋 `country_unverified` 與 `PersistFailed { applied: true }`。
- (b) Rust 在 `OwnerStep` 加 `join_end: u8`（Applied / Unclear / Failed / Declined / CountryUnknown / Refused / PersistFailed）。

刪掉 §7 步驟 3 的「`[JOIN_STATE]` → `rustUnclear`」測試（它把錯的對應釘死）。改成每一種 `join2flow::End` 一個案例，並加上 `country_unverified` 的已套用案例；對照「只看 `pollLink`」→ FAIL。

### M2　建立者壞掉、遺失、被抓：§2.8 永遠 fail-closed，D-B1 的死路在這種情況仍然存在

**情境**：建網途中，建立者斷電之後再也開不了機；或節點遺失、被抓。現場這不罕見，建立失敗的原因往往就是節點壞了。

**證據**：
- §2.8 第 3 條：讀不到建立者 → 不給重新建立，只有「把建立網路的那台開機放在旁邊」。
- §2.3 建立閘門：有 net → 不建立。
- 加入要求網路已套用（P13，join2flow.rs:340-341）。
- field 版沒有舊控制台。
- 最後只剩重裝。重裝 = Keystore 消失，所有節點都要重燒（v2 D-B1 的後果）。

**修法**：在 §2.8 讀不到建立者（`noLink`）之後，給第二個動作「建立網路的那台已經不在了」：
- 要明確確認，對話框寫清楚：「如果之後找到它，要先重設才能加入新網路」。
- 只在 pending、而且只有建立者一個成員時出現。
- 同樣 `keepCopy` + `remove`。

這和 B1 的「重新建立」分開（B1 是節點明確回答 `NotApplied`）。

測試：`noLink` 之後按鈕出現，確認後副本存在、`net/` 不在。對照：
- 拿掉整個動作 → 死路 → FAIL；
- 不經確認就丟 → FAIL。

殘餘風險（那台其實套用了，之後又被開機）寫進 §6。

### M3　`loginFor` 驅動器：沒寫「掃到新位址就叫醒」；掃描名額的等待吃掉 60 s 預算；預算到時沒有取消進行中的嘗試

**證據**：
- §2.1 只寫 `gate.scan(lease.token, addr → LoginFor.onScan(addr))`，叫醒來源只有 `LoginFor.wakeAt` 與 `radio()`。
  - `LoginFor.wakeAt` 只有 `start + 60 s`、`start + 30 s`、`freeAt`（core.dart:744-748）。
  - `LoginFor.onScan` 不回傳「是不是新位址」（core.dart:660-663），不像 round 的 `onScan`（core.dart:300-306）。
  - 照字面實作，第一台的第一次嘗試要等到 30 s 的 window 才會開始。這會打穿 §8 的「10 次 9 次 ≤ 20 s」。
- `BleGate.scan` 超過「30 s 內 4 次」時，會**在 gate 裡面等**最多 30 s（ble_gate.dart:182-202、:218-223）。
  - 這些都算進同一個名額：ClaimPage 的掃描（`noteScanStart`，raw_use.dart:46）、NodeLink 釋放後 6 s 的 round、每一台的 `loginFor`、每一次重新登入。
  - 情境 1a 與 1b（認領 → 首頁 round → 很快按建立 → 多台）很容易碰到。
  - `core.loginFor` 在掃描之前就設好 `start`（core.dart:634），等名額的時間也算進 60 s。
- 掃描被系統結束（`ended`）時，NodeLink 自己會在 2 s 後重試（node_link.dart:263-268）。§2.1 沒有寫，掃描被結束就只能等 60 s 變成 `notFound`。
- 60 s 到時，`LoginFor.tick` 只把 `running = null`（core.dart:737-742）。驅動器還要完成 `cancelled`、關掉那條連線，§2.1 沒有寫。

**修法**：寫進 §2.1，並加改壞：
- 掃到新位址 → 立刻規劃下一次嘗試（`onScan` 回 bool，或由驅動器自己比對）。改壞：不叫醒 → 第一次嘗試晚於 1 s → FAIL。
- 掃描拿到名額**之後**才呼叫 `core.loginFor`；或者整個 `NetworkRun` 用同一個掃描，換台時不停。
- 掃描被結束時照 `scanEndedRetry` 重試。
- 預算到時取消進行中的 `HandoffProber`，並關掉連線。

---

## MINOR

1. **A2 / P20 不準。** 「建立回來的未套用只剩寫入失敗或檢查讀不到」不成立。以下都會讓紀錄停在 pending：`Rejected`（owner.rs:1512-1515）、NewNonce 兩次（:1477-1480）、其他 `JE`（:1521-1524）、自動檢查得到 `NoChange(InProgress | NotApplied | Unknown | OtherNetwork)` 或 `OtherVersion`。目前流程把它們全部送去 §2.8，所以結論不受影響，但事實表要改。
2. **P22 不準**（見 M1）。`[JOIN_STATE]` 不只是「Rust 判斷的結果不明」。
3. **§2.8 的動作順序與佔用。**
   - 只有在 `keepCopy` 回 `true` 之後才 `remove`；`keepCopy` 回 `false` 或丟例外 → 停下、不刪。
   - 「回 4.1」之前要先放掉 §2.8 的佔用。否則 4.1 按「開始」時 `acquire` 會拿到「另一個操作還在進行」：§2.3 規定佔用留到離開結果頁。
4. **建立者的對應可以精確。** pending 紀錄的成員有 `dac_hash`（owner.rs:116，`MemberView.dacHash`），手機的 `node/` 紀錄裡有 DAC（owner.rs:170-171）。用 dac_hash 對，比用 `name` 的 `node-<last4>` 精確，也不會有後四碼相同的問題。`name` 可以留作後備。
5. **T-R2 的理由寫錯前提。** 「net/ 被刪、node/ 仍在」不一定成立：忘記節點時直接 `storeRemove`，不留副本（nodes.dart:467）。真正的保護是安裝紀錄：只有「沒有安裝紀錄**而且**沒有紀錄」時才重新產生金鑰（main.dart:189-205）。結論（降級安全）仍然成立，理由要改寫。
6. **A6（列檔）。** Dart 的 `Directory.list` 遇到不存在的目錄，丟的是 `PathNotFoundException`，它是 `FileSystemException` 的子類別（⚠️ 依 Dart SDK 知識，沒有實跑）。要先單獨接住它，不要用 `exists()` 再 `list()`：兩次呼叫之間有 TOCTOU。
7. **`keepScreenOn` 是全域的視窗旗標**，swupdate.dart:137 也會用（SwUpload.kt:77-81）。§3.1 擁有權表要寫兩個使用者，並註明一次只有一個佔用，所以不會重疊。
8. **「只有建立者一個成員」對 pending 紀錄永遠成立**（加入要求已套用，P13）。這個條件只是多一層保護，`有其他成員 → 沒有按鈕` 的測試要用手造的紀錄才做得出來。要照實寫，不要把它當成主要的判斷依據。
9. **多筆 pending net。** 舊控制台可以建好幾次，留下多筆 pending。§2.8 寫「pending 那筆」，沒說有好幾筆時處理哪一筆、要不要逐筆處理。
10. **`HandoffProber` 的實作細節要寫明。**
    - `loggedIn` 對到哪個 `Res`（要讓 `LoginFor.result` 得到 `ok`，core.dart:697-701）。
    - 驗證之前結束的一律 `noResponse`（core.dart:37-41 的驅動器契約）。
    - msg2 之後到 `loggedIn` 的上限（`SessionProber` 是 20 s，prober.dart:143-146）。
    - inbox 如果是單一訂閱的 `StreamController`，prober 取消自己的 listen 之後，`OwnerConsole` 不能再 listen（會丟 StateError）。要用 `StreamQueue`，或把同一個 subscription 暫停後交出去。「交接瞬間的訊框不丟」這個測試會抓到，但計畫要先寫清楚用哪一種。
11. **3.5 / 3.6 剛認領完時摘要表可能還在計算**（佔用釋放後會重算）。要照第 6 列給中性的狀態。
12. **`NodeLink.dispose` 要一併收掉 `_lf*`**（node_link.dart:352-358 現在只處理自動讀取的欄位）。
13. **暱稱過濾 `\p{Cf}` 會擋掉 ZWJ 組合的 emoji**（ui_state.dart:15）。這和 PR 2 一致，只是體驗；要的話在 T-V1 寫明。

---

## v2 審查逐條是否解掉

| 項目 | 判定 |
|---|---|
| C-M1 驅動器掃描 | ⚠️ 大致解掉；叫醒與名額見 M3 |
| C-M2 `Refused` ≠ 佔用遺失 | ✅ §2.2.1 |
| C-M3 4.1 表單 / 閘門 | ✅ 兩張表 |
| C-M4 找不到建立者 | ✅（建議改用 dac_hash，m4） |
| C-M5 閘門改壞 | ✅ §7 步驟 5 |
| D-B1 建立失敗死路 | ❌ 判斷的資料拿不到、條件太寬（B1）；建立者不在時仍是死路（M2） |
| D-M1 結果契約 | ⚠️ `leaseLost`、`NoLease`、timeout / ended / frameError / busy、`keyFail` 都解掉了；標籤分類錯（M1）。D 原本只說「`[JOIN_STATE]` 那兩種（Unclear7 / Unclear）」，計畫擴大到所有 `[JOIN_STATE]` |
| D-M2 HandoffProber | ✅（實作細節見 m10） |
| D-M3 勾選規則 | ✅ |
| D-M4 閘門分支 | ✅ |

## 指定要查的問題

- **§2.1 與 NodeLink 的互動**：`_pump` 只碰 `_attempt`、`_scan`、`_timer`（node_link.dart:208-233）。佔用期間 `roundActive` 為 false，不會開始掃描。`_dropAll` 只在 `acquire` 與 `dispose` 時跑。用 `_lf*` 分開是安全的。`radio()` 會讓 `core.setRadio` 把 `_login` 結束成 `precondition`（core.dart:286-292），驅動器要在同一次呼叫裡關掉連線（計畫有寫「叫醒」）。
- **§2.1.2 有沒有 deadlock**：`released` 的 future 只有 `readRecords` 這個平台呼叫加上同步程式碼（node_link.dart:177-194），沒有回頭等 `acquire`。5 s 上限之後回到現行的分支（`reg.current != null` → `_writtenWaiting`），沒有 deadlock。`RawLeaseScope` 在 dispose 時才放佔用（raw_use.dart:60-65），比 push 的 future 晚；`ClaimDone` 之後到按「開始」，中間隔著 3.2、3.5、4.1，時間足夠。F41 時 raw 佔用最多留 900 s，這段時間 `acquire` 會回「另一個操作還在進行」，是正確的。
- **§2.2.1 每一種結束方式是否都有一個 `ConsoleResult`**：Dart 這邊的結束方式都有。Rust 答覆的分類見 M1。
- **`MemberView.deviceId` 會不會改變現有行為**：沒有任何測試或程式碼自己建構 `MemberView`（grep 只命中產生的檔案），也沒有地方比較兩個 `MemberView` 是否相等。舊控制台只用 `dacHash`、`last4`。不會改變現有行為；要記得重跑 frb codegen。
- **§2.8 的 keepCopy + remove 放在 RecordWriter 之下**：兩者都檢查佔用（record_writer.dart:58-61、:52-56）。`remove` 不是 CAS，但在同一個佔用下，沒有其他寫入者（舊控制台與 `ClaimRecords` 也要佔用才能寫）。順序與佔用見 m3。
- **T-R2 / 金鑰重新產生**：見 m5。結論成立，理由要改寫。

## 安全（逐 actor）

- **遠端 BLE / 惡意廣播**：沒有 PSK 的裝置做不出解得開的 msg2，只能讓一次嘗試變成 `noResponse` 或 `undecryptable`，代價是時間（計畫已寫，接受）。M3 的掃描名額讓這個代價更容易吃光 60 s。
- **被入侵的節點**：
  - 加入時只能換掉自己的成員項（P21，已驗證）。
  - 在 §2.8，它可以謊稱 `NotApplied`，讓使用者丟掉以它為建立者的 pending 紀錄。最壞是重建網路，不會讓已經在網路裡的其他節點分裂（計畫的分析成立）。
  - 照 B1 的現狀，它也可以謊稱「key 10 沒有」以外的狀態，但不管說什麼，影響範圍都一樣只限於它自己。
- **本機無權限的 app**：沒有新的入口；`forgotten-net/` 在 app 私有目錄裡。
- **我們自己的錯**：B1（條件太寬）、M1（分類錯）是這一類。
- **秘密**：`OwnerConsole` 只寫種類、代碼、後四碼。Rust 的答覆句裡有 mesh_id（`[NET_MADE]`），它只上畫面、不進 log，要在 code review 時確認這一點。
- **沒有佔用時**：`BleGate` 與 `RecordWriter` 都拒絕（ble_gate.dart:175-180；record_writer.dart:27-33），fail-closed 成立。

---

## 我做了什麼

### ✅ 已驗證（原始碼原文節錄）

- 確認答覆只有文字，`OwnerStep` 沒有狀態欄位。owner.rs:885-893：`Ok(c) => Some(OwnerStep::text(OwnerKind::Answer, confirm_text(&c)))`。
- 「key 10 沒有」底下有三種狀態。flow.rs:169-173：`None => match unfinished { Some(true) => JoinState::InProgress, Some(false) => JoinState::NotApplied, None => JoinState::Unknown }`。
- owner.rs:477：`JoinState::InProgress => "網路：還在設定中，請一分鐘後再按「檢查網路」"`；:478：`NotApplied => "…可以再建立一次同一個網路"`。
- `[JOIN_STATE]` 底下也有確定的失敗。owner.rs:546-562：`E::Failed(f, r) => { … Fail::Rejected => "節點不接受這份網路設定（回覆碼 4）" … format!("[JOIN_STATE] {head}{tail}")`。
- `[COUNTRY]` 也用在不明。owner.rs:536：`E::Joining(Keep::CountryUnknown) => format!("[COUNTRY] 國家狀態不明，{LATER}")`。
- `poll_link` 的條件。owner.rs:1437：`st.poll_link = matches!(e, join2flow::End::Applied { country_unverified: false, .. }) && !behind;`
- Dart 自己也會產生同樣的標籤。nodes.dart:658：`_say('[JOIN_STATE] 已取消：沒有寫入、沒有送出')`；nodes.dart:55：`const _sendUnclear = '[REQ_FAIL] 結果不明 — 請重新連線後看狀態頁'`。
- `LoginFor.wakeAt` 沒有「掃到新位址」。core.dart:746：`[start + budget, start + c.p.window, ...freeAt.values]`；`LoginFor.onScan` 回傳 `void`（core.dart:660）。
- 掃描名額在 gate 裡等。ble_gate.dart:193-197：`final w = _waitForScanSlot(); if (w > 0) { … await c.future;`
- 金鑰只有在「沒有安裝紀錄而且沒有紀錄」時才產生（main.dart:196-205）；忘記節點直接 `storeRemove`（nodes.dart:467）。
- `RECORD_KINDS` 目前有 7 種（simple.rs:31-32），沒有 `forgotten-net`；`store_keep_copy` 對 `net` 會回錯誤（claim.rs:134-141）。
- 事實核對：P2（nodes.dart:614）、P4（:520-529）、P7（core.dart:282-292、628-748）、P8、P9（prober.dart:133-134、:147、:160-175）、P10（raw_use.dart:73-82）、P13、P14、P15（node_link.dart:171-195）、P16（owner.rs:79-80、:116、:1080；netrec.rs:375-396）、P17、P18（home_logic.dart:92-96）、P21、P23（ui_state.dart:95-97、:197）、P24（owner.dart:559-560），都和原始碼一致。
- 沒有地方自己建構 `MemberView`：grep `MemberView(` 只命中 `lib/src/rust/api/owner.dart` 與 `frb_generated.dart`。
- `keepScreenOn` 在 swupdate.dart:137 已經使用。

### ⚠️ 推論（沒有實跑）

- M3「第一次嘗試會等到 30 s」是照計畫字面推出的實作結果，沒有寫程式驗證。
- m6 中 `Directory.list` 對不存在目錄的行為是依 Dart SDK 知識，沒有實跑。
- 「情境 1a / 1b 很容易用完 30 s 內 4 次的掃描名額」：沒有真機計數。
- B1 的「建立者最後落在手機丟掉的網路裡」：依 Rust 文字與 flow.rs 的狀態定義推論，沒有真機重現。

### ❌ 沒做

- 沒有跑任何測試、Rust 測試或建置。
- 沒有逐行驗證 9b00ca6 的「改壞 5/5」（P12）。
- 沒有上真機。
- 沒有逐條核對 v1 審查 A / B 的每一項（依 C / D 的對照，抽查其中與本版相關的部分）。
