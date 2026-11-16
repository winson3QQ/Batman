# #329 PR 3 實作計畫 v3 — 對抗式審查（審查者 F，獨立）

審查對象：`docs/design/329-pr3-plan.md` @ cc0c2bf（branch feat/329-pr3），整份重審；原始碼 = 同一個 worktree（main 29b0085 + 9b00ca6 + 兩個文件 commit）。

## 結論

**Verdict：REJECT**（1 BLOCKER / 2 MAJOR / 11 MINOR）。

BLOCKER 只在 §2.8，修法範圍很小（Rust 加兩個結構化欄位 + §2.8 的條件改寫 + 四個改壞）。其他部分（loginFor、結果契約、建立閘門、摘要表、入口表）我認為 v3 已經把 v2 的 C-M1..M5、D-M1..M4 處理到可以開工的程度。§2.8 修完、M1 / M2 處理後，我預期可以給 APPROVE-WITH-CHANGES。

v2 D-B1（建立失敗的死路）：**概念上已解決**（有出口、fail-closed、留副本）。但 v3 照抄了 D 建議的條件字面「info key 10 沒有」。這個條件本身不安全，Dart 端也沒有結構化的訊號能判斷它（見 B1）。

---

## BLOCKER

### B1　§2.8「重新建立」的觸發條件不安全，也做不出來：「key 10 沒有」包含「還在設定中」和「讀不到（E_RATE）」；confirm 不檢查登入的是不是建立者

**情境 1（現場最常見）：建立途中斷電。**
1. 隊長建網，建立者斷電後重開，正在套用（或回復）設定。info 回 key 10 不在、key 11 = true。
2. 隊長從待辦進 §2.8 →「檢查網路」。節點回 key 10 沒有。
3. 照 §2.8 條件 2 的字面，這算「節點明確回報不在這個網路」→ 出現「重新建立」→ 隊長按下，pending 紀錄被移走。
4. 一分鐘後，節點完成套用原本那個網路。
5. 結果：節點在一個手機已經「忘掉」的網路裡；手機另外建一個新網路。這正好是 §2.8 自己說要防止的分裂。§6 也寫了：錯誤的建立要重燒節點才能恢復。

**情境 2：E_RATE。** info.net 撞到 E_RATE 時，9 / 10 / 11 全部不在。key 10「沒有」同樣成立，同樣會出現按鈕。

**情境 3：登入的不是建立者。**
- §2.8 的對象用 `node-<last4>` 對手機裡唯一一筆 `node/`；對不上或多筆時讓使用者從清單選。
- 使用者選錯台（或建立者的 `node/` 已被忘掉，剛好另一台後四碼相同）→ 登入另一台 → confirm 回 NotApplied → 出現「重新建立」。
- 這時真正的建立者可能已經套用（關機或不在附近）→ 分裂。
- §2.8 寫「檢查是唯讀比對，對錯台只會『不符、不寫』」：加了「重新建立」之後這句不再成立。錯台的回答會觸發一個破壞性動作。
- 被入侵的節點也能用這條路：只要被使用者選到，就能讓手機丟掉別台建立的 pending 紀錄。§6 的論證（「那時建立者本來就是它自己」）只有在核對身分之後才成立。

**證據（✅ 原始碼）**：

`batman-proto/src/flow.rs:143-175`：「key 10 沒有」對應三種不同的狀態。
```
/// 10 absent, 11 == true: in progress -> poll (≤ 960 s)
InProgress,
/// 10 absent, 11 == false: not applied or rolled back -> the same net_id may be sent again
NotApplied,
...
/// 9 / 10 / 11 all absent (info.net hit E_RATE), or malformed -> poll (≤ 960 s)
Unknown,
...
None => match unfinished {
    Some(true) => JoinState::InProgress,
    Some(false) => JoinState::NotApplied,
    None => JoinState::Unknown,
```

`bridge/src/api/owner.rs:879-893`：confirm 的結果只以**文字** answer 回來。`OwnerStep`（owner.rs:206-246）沒有任何欄位帶 JoinState；`info` 欄位只給 `request_info` 用（:235-236）。
```
Ok(c) => Some(OwnerStep::text(OwnerKind::Answer, confirm_text(&c))),
```
四種 NoChange 都是同一個標籤 `[NET_STATE]`，只差中文句子（owner.rs:474-491）。計畫 §2.2.1 明訂「不解析中文句子」，所以 §2.8 條件 2 在 Dart 端沒有可以用的訊號。計畫也沒有列這個 Rust 改動（§2.8「Rust 改動（最小）」只有 `forgotten-net` 兩項）。

`netrec.rs:511-536`（`confirm`）：只比 info 的 key 10 / 9 和紀錄，**不比登入節點是不是 `rec.creator()`**。登入節點的身分在 session 裡（`self.node`，owner.rs:1068）。

**修法（最小）**：
1. Rust：`info-confirm` 的 answer 加兩個結構化欄位。
   - `join_state: u8`：Applied / InProgress / NotApplied / OtherNetwork / Unknown / OtherVersion / 錯誤碼。
   - `is_creator: bool`：`self.node` 的 DAC hash == `rec.pending_creator()`。
   - 各加一個 Rust 測試，含 E_RATE（`Outcome::Err`）走哪一條。
2. §2.8 條件改成：`is_creator && join_state ∈ {NotApplied, OtherNetwork}`（OtherNetwork 要不要列入請寫理由；保守做法是只列 NotApplied）。
   - 其他全部（InProgress、Unknown、OtherVersion、錯誤碼、逾時、`refused`、`frameError`）→ 沒有按鈕。
   - InProgress 用 Rust 現成的句子「還在設定中，請一分鐘後再按『檢查網路』」。
   - 這樣是 default-deny：新增的狀態自動沒有按鈕。
3. §2.8 的對象改用 `dac_hash` 對：`MemberView.creator` + `dac_hash` 已經存在（owner.rs:85-88、:116-121），pending 紀錄也有。
   - 需要一個 Rust 小函式：`node/<id>` → DAC hash（node 紀錄裡有 DAC），或只靠第 1 點的 `is_creator` 在登入後把關。
   - 不再需要 `node-<last4>` 的名稱對應；「讓使用者選」只剩下 `is_creator = false` 時顯示「這台不是建立網路的那台」。
4. §7 步驟 6 補改壞：
   - InProgress → 有按鈕 → FAIL；
   - Unknown / E_RATE → 有按鈕 → FAIL；
   - OtherVersion → 有按鈕 → FAIL；
   - 錯台（`is_creator = false`）+ NotApplied → 有按鈕 → FAIL。
5. 條件「紀錄只有建立者一個成員」：pending 紀錄永遠只有 v1 成員（`members()` 在 `list: None` 時從 key 8 推，netrec.rs:391-396；加入要求已套用，join2flow.rs:340-341），所以這個條件在現行程式下恆真。
   - 可以保留當防呆，但「拿掉條件 → FAIL」的改壞做不出來（拿掉也不會 FAIL）。
   - §6 也不要把它當成安全論證。真正擋住被入侵節點的是第 1 點的 `is_creator`。

---

## MAJOR

### M1　`HandoffProber` 的結果對應沒有寫，包括信任邊界那一條（login_end 5 / 登入前結束 = noResponse）

**情境**：
- `LoginFor.result` 只在 `Res.body` / `Res.errorCode` 時結束成 `ok`（core.dart:707-710）。
- `SessionProber` 是在登入後讀完狀態頁才給 `body`（prober.dart:86-94）。
- `HandoffProber` 在 `loggedIn` 就停（計畫 §2.1.1），所以它必須自己決定給 `Res.body`。計畫沒寫。
- 更重要的是 `ended` 的對應（prober.dart:96-104）：
  - 2 → undecryptable；3 → certRejected；4 → forbidden / other；
  - 5（Broken）或登入前結束 → **noResponse**，這樣附近的裝置不能用壞掉的 msg2 種下錯的「是 Y」（core.dart:37-40 的 driver contract，code-1 A-m7 / B-m9）。
- 計畫讓 `HandoffProber`「獨立、不共用」，等於把這張信任邊界的表再寫一次，卻沒有列它的測試與改壞。這正是 brief 裡「複製的 OwnerConsole 會漂移」的同一類風險，而且出在安全路徑上。

**證據（✅）**：prober.dart:96-104。
```
2 => const Outcome(Res.undecryptable),
3 => const Outcome(Res.certRejected),
4 => st.loginCode.toInt() == eForbidden ? const Outcome(Res.refusedForbidden) : const Outcome(Res.refusedOther),
// 5 (Broken in the login) and anything before a login: noResponse — never plant a 「是 Y」
_ => loggedIn ? const Outcome(Res.broken) : const Outcome(Res.noResponse),
```

**修法**：
- 把這張對應抽成一個兩邊共用的純函式（`SessionProber` 只是呼叫它，行為不變），或者在 §2.1.1 明列這張表。
- §7 步驟 2 加測試與改壞：
  - login_end 5 在登入前 → 必須 noResponse（改成 broken → FAIL）；
  - `loggedIn` → `ok`；
  - 3 → identity。

### M2　`openRawPage<T>` 回傳 record 會讓現有呼叫者每次都顯示「另一個操作還在進行」；「現有呼叫者照舊」不成立

**證據（✅）**：兩個呼叫者都用回傳值判斷 `!= null`。
```
lib/main.dart:87:    final busy = await openRawPage(Navigator.of(context), a.link, a.gate, name, (u) => page(a, u));
lib/main.dart:88:    if (busy != null) m.showSnackBar(SnackBar(content: Text('另一個操作還在進行：$busy')));
lib/ui/home_page.dart:55:  final busy = await openRawPage(...
lib/ui/home_page.dart:61:  if (busy != null) m.showSnackBar(SnackBar(content: Text('另一個操作還在進行：$busy')));
```
- 回傳型別改成 `(T?, String?)` 之後，`busy` 永遠不是 null。編譯不會失敗，最多只有 `unnecessary_null_comparison` 警告。
- 結果：每次關掉「新增節點」或「我的節點」，都會出現「另一個操作還在進行：(null, null)」。
- 另外 7 個測試直接呼叫 `openRawPage`：claim_flow_test:344、review_pr1_test:495、nodes_*_test、scan_page_test:53。

**為什麼是 MAJOR**：首頁每個入口都會受影響，而且計畫明寫「不用改」，實作者會照字面不去改它。

**修法**：二擇一。
- 保留 `openRawPage` 原簽名，另加 `openRawPageFor<T>`；或
- 在 §2.6 列出兩個呼叫者 + 7 個測試的改法。

再加一個測試：正常關頁不顯示 busy 的 SnackBar。

---

## MINOR

1. **inbox 交接在 Dart 上照字面做不出來。** `StreamController()` 的 stream 只能 listen 一次：prober「從 inbox 讀」之後，console 再對 `inbox.stream.asyncMap` 會丟 `Bad state`；改成 broadcast 會丟掉交接之間的訊框。`package:async` 的 `StreamQueue` 不是直接依賴（pubspec 沒有）。
   - 修法：整個 session 只有一條 `asyncMap` 管線（同 nodes.dart:340-347），交接時換處理函式；或明列加 `async` 依賴並用 `StreamQueue.rest`。
   - §7 的「交接瞬間的訊框不丟」測試會抓到這個問題，所以列 MINOR。
2. **loginFor 的 60 s 包含閘門等掃描名額的時間。** `gate.scan` 超過 4 次 / 30 s 時會在閘門裡等（ble_gate.dart:202-206，最多約 30 s）。`LoginFor.start` 在 `core.loginFor(now)` 時就開始計時（core.dart:634）。
   - 認領 + 恢復（每次一個 scan）之後馬上建網，可能只剩約 30 s。
   - loginFor 的掃描若被系統結束（`ended`），計畫沒寫重試（NodeLink 自己有 `scanEndedRetry` 2 s，node_link.dart:263-267）。
   - 另外，loginFor 結束時掃描可能還在閘門裡等名額，「先停掉掃描」要涵蓋這種還沒回來的掃描（同 node_link.dart:277-280 的處理）。
3. **§2.8 頁面的生命週期沒有寫進 §3.3。** 要寫：
   - 佔用 / hold / `PopScope` / `pageGone`；
   - 「重新建立」之後回 4.1 之前要先 `release`（4.1 不持有佔用）；
   - `keepCopy` 丟例外 → 不 `remove`，顯示原因；`keepCopy` 回 false（紀錄已經不在）→ 不 `remove`，直接重新列檔；
   - 各一個測試。
4. **`made` 的 `rel` 從哪裡來沒寫。** 建立前不知道 net id，應取 `PersistNet` 那一步的 `OwnerStep.rel`（owner.rs:428-430）。沒有 PersistNet 就失敗 → `refused`，不重讀。
5. **`rustUnclear` = `[JOIN_STATE]`，但這個標籤也用在其他句子。**
   - `TwiceRefused`（「節點連續兩次拒絕…不會再送」，owner.rs:534）也帶這個標籤，計畫會顯示「結果不明 + 再試這一台」。
   - forget-joining 的句子（owner.rs:153-155）也用這個標籤；目前新頁面不呼叫它，但應寫明標籤只在 join 的 answer 裡解讀。
6. **「`ClaimPage` 只換 build」和 `ClaimDone` / `lastClaimNote` 互相矛盾。**
   - 這兩項要改 `_claim` / `_recover` 的成功路徑（pop 帶值）和頁面已經 pop 之後的結果寫回（`_say` 在 `!mounted` 時什麼都不做，nodes/claim 的 `_say` 模式）。
   - 應寫成「邏輯只加兩個出口」，並列在 claim 測試不改判定的例外裡。
7. **`UiState.setNick` 與 `noteReads` 並行。** 兩者都走 `_save()` 的 CAS（ui_state.dart:228-232）；同時發生時第二個丟 `StateError`，暱稱靜默遺失。
   - 修法：在 `UiState` 內排成一列，或 `setNick` 失敗時明確顯示。
   - 加測試。
8. **`keepScreenOn` 是現成的平台方法（SwUpload.kt:77-81，`dev.batman/swupd` channel），不是新方法。** 它是視窗旗標、不計數；目前靠佔用互斥避免和軟體更新相衝。§6「沒有新的平台方法」成立，但 §3.1 應寫明這個共用旗標和互斥的理由。
9. **建立模式裡「沒讀到」的節點能不能當建立者沒寫**（加入模式有寫）。
   - 重裝之後、節點其實還在舊網路時，會由 Rust / 節點擋下（OtherNetwork），結果是 fail-closed。
   - 但結果頁要有對應的句子；§2.8「重新建立」之後的預設建立者規則也要寫。
10. **舊控制台（dev）仍可在 pending 存在時再按「建立網路」**（nodes.dart:476、settings_page.dart:37-44），繞過新的建立閘門。這是 D2 接受的現況，但 §9 的 PR 限制應寫一句。
11. **摘要表由 `NodeLink` 擁有，超出它的職責**（BLE 排程器變成也要開 Keystore 紀錄）。
    - 建議放 `AppLink` 或獨立的 `NetIndex`。
    - 「記一行路徑」要經 `NodeLink.mask`（net id 是 32 個 hex）。

---

## 指定要查的問題

| 問題 | 結論 |
|---|---|
| 佔用期間 NodeLink 能不能另開登入掃描 | ✅ 可以。<br>• `acquire` 先 `_dropAll()` 停掉自己的掃描，再 `gate.revoked(mine)`（node_link.dart:155-161）。<br>• 佔用中 `core.lease = true` → `_eligible` 為假 → `_pump` 不開掃描（core.dart:168、:223-228）。<br>• 閘門只認目前的 token、一次一個掃描（ble_gate.dart:694-699）→ `gate.scan(lease.token, …)` 會被接受。<br>• `_pump` 的 `_abort` 只看 `_attempt`（node_link.dart:214-215），所以 `_lf*` 不會被砍。 |
| `acquire` 等上一個 `released` 會不會死鎖 | ✅ 不會。<br>• 等的是讀紀錄（Rust `listNodes`），不依賴佔用。<br>• 原始頁面還在堆疊上時 `reg.current != null` → 回 null。<br>• `releaseLease` 只把下一輪排在 6 s 後（core.dart:263），所以 ≤5 s 的等待期間 NodeLink 不會開新的一輪。<br>• ⚠️ 5 s 上限要用注入的 `after`，否則 fake clock 測試會卡住。 |
| `confirmNetwork` 能不能區分「不在 / 別的網路」與「不明」 | ❌ 目前不能，見 B1（只有文字；`[NET_STATE]` 一個標籤涵蓋四種狀態）。 |
| `keepCopy` / `remove` 語意、Rust 改動夠不夠 | ✅ 夠。<br>• `RecordWriter.keepCopy` / `remove` 存在，`AppLink` 已接線（app_link.dart:97-104）。<br>• `copy_aside` 是通用的（store.rs:167-197）。<br>• `forgotten-net/<32hex>-n` 通過 `valid_path`（≤64、小寫 / 數字 / `-`，store.rs:44-48）。<br>• `store_keep_copy` 加一個 match 分支就夠（claim.rs:134-141）。<br>• 缺的是失敗處理（MINOR 3）。 |
| 降級 / `RECORD_KINDS` | ✅ 計畫的說法成立，而且比計畫寫的更強。<br>• `_install` 先看安裝紀錄；有紀錄就**完全不碰金鑰**（main.dart:196-199）。`RECORD_KINDS` 只在安裝紀錄遺失時有作用（:201-205）。<br>• 舊版不認得 `forgotten-net/` 只會少算，而 `node/` 或 `forgotten-node/` 通常仍在。 |
| 「重新建立」能不能防住「建立者已套用、手機紀錄仍是 pending」 | ⚠️ 建立者在旁邊、回 Applied 時能防住（confirm 會升級）。<br>❌ 但在「還在設定中」、E_RATE、登入錯台這三種情況會分裂（B1）。 |
| `openRawPage<T>` 相容性 | ❌ 見 M2。 |
| `MemberView.deviceId` | ✅ 沒有洩漏：device id 不是秘密，已是 `node/` 的檔名，後四碼也已在畫面上。<br>• Dart 端沒有手寫建構 `MemberView` 的地方（grep `MemberView(` 在 lib / test 只有 generated），不會壞掉測試。<br>• 加入中的成員確實帶 device id（join2flow.rs:362 `device_id: Some(node.device_id)`）。<br>• 建立成功的紀錄由 Rust 填上建立者的 device id（owner.rs:1463-1469）。 |

## 事實核對（§1、§5）

| 項目 | 結果 |
|---|---|
| ✅ 已核對 | P5（ble_gate.dart:84-86 `_usable`、:185、:226-231）、P7（core.dart:282-292、:628-748）、P8（node_link.dart:157、:215、:260、:296）、P10（raw_use.dart:73-82）、P14（owner.rs:41-47）、P15（node_link.dart:171-195；core.dart:703-705）、P16（owner.rs:79-80、:116；netrec.rs:212、:375-377、:391-396）、P19、P20（owner.rs:1451-1524）、P22（owner.rs:498-566） |
| P24 的附註 | `StatusView.netId` 為 "" 時，同時代表「沒讀到」和「不在網路」（owner.rs:2217）。4.1 把它當成不能勾是 fail-closed，可以；§2.8 **不能**用它，見 B1。 |
| A2 | ✅ owner.rs:1506-1512 |
| A4 | ✅ lease.dart：只有 `pageGone` 才設上限 |
| A5 | ⚠️ owner.rs:1080 `node_name = node-<last4>` 已見；沒有追到 v1 成員項。照 B1 第 3 點改用 `dac_hash` 之後，這個假設就不需要了。 |
| A6 | ⚠️ 未驗（計畫自己也標了） |
| 沒查 | P1–P3、P9、P11、P12、P17、P18、P21、P23、A1、A3 |

## 安全（逐 actor）

- **遠端 BLE / 惡意廣播**：同設計（7 個安靜位址可耗盡 60 s，計畫已寫）。M1 的對應若漂移，會變成可以種下「是 Y」。
- **被入侵的節點**：
  - 在 §2.3：只能換掉自己的成員項（P21，未重驗），並能發問；
  - 在 §2.8：**目前可以讓手機丟掉別台的 pending 紀錄**（B1 情境 3）；加上 `is_creator` 之後只剩它自己的。
- **本機無權限 app**：沒有新入口。`forgotten-net/` 在 app 私有目錄。
- **我們自己的錯**：
  - B1 的條件字面；
  - M2 的簽名改動；
  - inbox 交接（MINOR 1）；
  - `[JOIN_STATE]` 標籤多義（MINOR 5）。
- **秘密**：沒有看到新的洩漏點；摘要表的路徑要經 mask（MINOR 11）。

## 我做了什麼

- ✅ 讀完：計畫 v3 全文、v2 D 的 B1、v2 C 的標題；node_link / lease / ble_gate / record_writer / raw_use / prober / app_link / core（LoginFor、lease、setRadio、tick）；main.dart `_install`；home_page 入口；settings_page；ui_state 寫入；claim_records。Rust 讀了 owner.rs（MemberView、net_summary、confirm、join_step、request_confirm_network、OwnerStep）、netrec.rs（confirm、members、creator）、flow.rs（join_state）、join2flow.rs（begin、on_info、device_id）、claim.rs（store_keep_copy）、simple.rs（RECORD_KINDS）、store.rs（valid_path、copy_aside、remove）。上面引用的片段都是讀到的原文。
- ⚠️ 推論：
  - 「還在設定中」在斷電後的實際回報是推論，依 flow.rs 的註解，沒有真機看過；
  - inbox 單次 listen 是 Dart 的語意，沒有實跑；
  - `busy != null` 永遠為真是型別推論，沒有編譯。
- ❌ 沒做：
  - 沒跑任何測試或 `flutter analyze`；
  - 沒上真機；
  - 沒讀 nodes.dart 的整段請求機制（P1–P4）和 claim.dart 的 UI。
