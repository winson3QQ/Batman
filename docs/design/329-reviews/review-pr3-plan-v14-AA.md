# #329 PR 3 實作計畫 v14 審查（審查者 AA，獨立）

對象：`docs/design/329-pr3-plan.md` v14 @ e947148。範圍照指示：
1. v13 審查 Y、Z 的每一項在 v14 是否修好。
2. v14 改動（§2.3、§2.4 用詞與 `forgetJoining`、§2.5 重寫、§2.8 建立交接、D9、§3.1、§3.2、§6 第 3 / 5 步）有沒有新洞或跨節矛盾。
3. 從現場出發，不提重新決定 join2 的新機制。

join2 與舊控制台是基準，疑問放在「基準備註」。只讀原始碼，沒有跑。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 0 MAJOR / 6 MINOR / 3 nit）

v13 的兩個 MAJOR 都修好了：
- Z-M1：4.1 先 `acquire` 再 `push`，和 `openRawPage` 同一個順序。
- Z-M2：不再複製重送分支。

Y-m1..m5 與 Z-m1..m8 也大多落實。剩下的有兩類，都不會損壞紀錄：
- v14 新增的「4.1 在 `acquire` 與 `push` 之間做非同步比對」留下一個沒有主人的空檔（AA-m1）。
- 幾處文字與測試清單和 §2.3 的新規則不一致（AA-m2、m3、m4、m6）。

---

## 1. v13 發現的對應

| 發現 | 結果 | v14 位置 | 證據 |
|---|---|---|---|
| Z-M1 / Y-m1 `acquire` 放在 `NetRunPage.initState` | ✅（附 AA-m1） | §2.5:104-110、§3.1:177、§3.2:190、D9:220、§6:237 | 4.1 `acquire` + 比對 → 成功才 `push(NetRunPage(lease))`。被拒時 4.1 留著顯示 D9 的句子，和 raw_use.dart:73-82 同序。`NodeLink.acquire` 第一行就看 `reg.current`（node_link.dart:154）。§6 有改壞對照「先換頁再 acquire → FAIL」。缺的是 acquire 之後、push 之前的非同步比對期間 → AA-m1 |
| Z-M2 / Y-m5 自動重送 | ✅（附 AA-m3） | §2.3:74、§2.5:122、§6:235 | 引用的行號都對：nodes.dart:547-566 重送分支要 `unclear == null && retry`；建立 :486-490 帶 `unclear`；加入 :647、連線檢查 :703、確認 :1244、送新密碼 :1581 都是 `retry: false`。但 §6 的改壞對照分辨不出有沒有修 → AA-m3 |
| Z-m1 「net」的定義 | ⚠️（AA-m6） | §2.4:87 | 用詞已定義。但 §2.4:94 仍說兩者是「同一條規則」；Z 要的改壞對照（只有 pending → 第 6 列仍是「加入網路」）§6 第 4 步沒有列 |
| Z-m2 `sessionAlive` | ⚠️（AA-m2、nit AA-n1） | §2.3:76、§2.5:118 | 規則寫明了，但 §6:237 還是「遇到 `NOT_LOGGED_IN` → 重新登入」，和 §2.3 衝突 |
| Z-m3 「放棄這次加入」是獨立函式 | ✅（附 nit AA-n2） | §2.4:96、§6:235 | 舊 `_forgetJoiningBody` 只呼叫 `netForgetJoining` + seal + CAS，不需要 session（nodes.dart:1286-1291）。Rust 是 sync、回 `PersistNet` 步驟（owner.rs:129-131） |
| Z-m4 結果頁一次一件事 | ✅ | §2.5:124、§6:237 | 舊控制台用 `_busy` 停用按鈕（nodes.dart:521、:528） |
| Z-m5 `loginFor` 中頁面消失 | ✅ | §2.5:114、§6:237 | 照 nodes.dart:405-409：登入成功時頁面已不在 → `_drop()` 後 return |
| Z-m6 哪些節點可以勾 | ✅ | §2.5:101 | 所有 `node/` 紀錄都可以勾；已在網路裡的預設不勾 |
| Z-m7 兩個 4.1 | ✅ | §2.8:166、§6:237 | 從 4.1 進來的檢查網路頁 pop「去建立」給 4.1；§6 有「堆疊只有一個 4.1」 |
| Z-m8 金鑰拒絕 | ⚠️（AA-m5） | §2.3:77、§2.5:123、§6:235 | `keyErrorToRadio` 已接上（app_link.dart:142-144 → `link.radio(keyOk: false)`）。kind 的優先順序、和舊控制台的差異沒有寫清楚 → AA-m5 |
| Z 小提醒：`lease.run` 寫錯 | ✅ | §2.5:114 | 「撐住佔用的是 `hold`」，和 lease.dart:60-70 一致 |
| Z 小提醒：從結果頁進來時預選那一列 | ✅ | §2.5:125 | 「預選那一列的節點」 |
| Y-m2 兩個 4.1 | ✅ | 同 Z-m7 | — |
| Y-m3 `rel` → `persistedRel` | ✅（nit AA-n3） | §2.5:102、:117、:118、:125、:126 | §2.5 全部改了；D6:216 還寫「`PersistNet` 的 `rel`」 |
| Y-m4 舊路徑對到 `kind` | ✅ | §2.3:75 | 三條都列了：沒有 session（:524-526）、`retry: false` 的非字串錯誤（:554 → :579-582）、`confirmRemoved`（:653-663；`_readRecord` 回 null → :662 靜默 return）。§6 第 3 步也有測試 |
| Y-n1 | ✅ | §3.1:177 | 寫成 `NetRunPage` |
| Y-n2 | ✅ | §6:237 | 「國家對話框開著時頁面消失 → 回答不要」 |
| Y-n3 | ✅ | §6:237 | 「`NetIndex` 每次重算完成都通知」（§2.6:136 本文沒寫「內容沒變也通知」，測試補上了） |
| Y-n4 | ✅ | §2.3:70、:78 | `unclear` 的句子是 Dart 的；結果列只看 `persistedRel` |

---

## 2. MINOR

### AA-m1　4.1 在 `acquire` 之後、`push` 之前要做非同步的快照比對。這段期間頁面被關、或比對本身失敗時，佔用沒有人釋放，也沒有期限

- **情境（現場）**：使用者在 4.1 按「開始」。4.1 拿到佔用，開始在佔用下重新列檔、解密每一筆 net 紀錄（每筆都要一次 Kotlin `open`），並和快照比對（§2.4:97、§2.5:105）。
  - 比對還沒做完，使用者按了返回，或系統把頁面關掉。
  - 或者列檔丟了不是 `PathNotFoundException` 的錯誤。
- **計畫文字**：§2.5:108 只寫「`acquire` 回來時 4.1 已不在 → 立刻 `release()`」，沒有寫比對**之後**頁面已經不在、或比對失敗時要做什麼。
- **後果**：照字面實作會對已卸載的 context 呼叫 `push`（丟錯），或者直接 return。這時佔用：
  - 沒有呼叫過 `pageGone`，所以沒有 420 s 期限（`_deadline` 只在 `pageGone` 設，lease.dart:73-83）；
  - 也沒有呼叫 `release`。

  結果 `reg.current` 一直不是 null。NodeLink 的自動讀取停住（`nodeLinkToken == null`，lease.dart:120），之後每個 `acquire` 都被拒（node_link.dart:154），直到 app 重開。
- **為什麼和 `openRawPage` 不同**：`openRawPage` 在 `acquire` 和 `push` 之間沒有任何非同步步驟，只檢查一次 `nav.mounted`（raw_use.dart:74-80）。v14 的 4.1 多了一段非同步比對，所以只照抄這一次檢查不夠。
- **為什麼只是 MINOR**：細心的實作者會自己檢查 `mounted`。不會損壞紀錄（方向是 fail-closed），但會讓整個 app 卡在「另一個操作還在進行」。
- **修法（一句話，不加機制）**：§2.5 寫明「4.1 從 `acquire` 到交給 `NetRunPage` 之前是佔用的擁有者。這段期間的任何結束路徑——頁面已不在、比對不同、列檔或解密失敗（顯示『讀不到手機裡的網路紀錄』）——都先 `release()`」。§3.2 的「開始」那一列補上這三條。
- **改壞對照**：讓列檔回一個慢的 Future；按「開始」後立刻 pop 4.1；完成列檔後斷言 `reg.current == null`。改壞成只在 `acquire` 回來時檢查一次 → FAIL。另外一條：列檔丟錯 → 斷言 `reg.current == null`，畫面顯示「讀不到」。

### AA-m2　§6 第 5 步「自動檢查遇到 `NOT_LOGGED_IN` → 重新 `loginFor` 一次」和 §2.3:76「不比對 Rust 的 `NOT_LOGGED_IN` 字串」衝突

- **證據**：
  - §2.3:76：`sessionAlive == false` → 先 `close()` 再 `loginFor`。其他 `refused` → 那一台算失敗。
  - §6:237 的測試名稱還是 v13 的寫法。
  - `NOT_LOGGED_IN` 是 Rust 的 `Err("還沒連線到節點")`（owner.rs:438、:1173-1175），對 Dart 來說只是 `refused` 的一種。
- **後果**：照測試名稱實作，就得比對中文字串，也就是 §2.3 刻意拿掉的做法。照 §2.3 實作，那條測試就沒有辦法依名稱寫出來。
- **修法**：§6 改成「自動檢查前 `sessionAlive == false` → `close()` + `loginFor` 一次；`sessionAlive == true` 但回 `refused` → 不重新登入、那一台停」。
- **改壞對照**：假的 session 讓 `sessionAlive == false` → 斷言 `close` 在 `loginFor` 之前、`loginFor` 只呼叫一次。改壞成比對字串（假 session 回別的 refused 文字）→ 斷言不重新登入；字串版會漏判 → FAIL。

### AA-m3　Z-M2 的改壞對照分辨不出有沒有修

- **證據**：§6:235 寫「寫入失敗 → 只送一次、不自動重送（改壞 = 複製重送分支 → FAIL）」。但舊重送分支只有在 `unclear == null && retry` 時才會走到（nodes.dart:547、:554）。§2.3:74 自己也說，PR 3 的五個請求都走不到它。所以照原樣（連同 `retry: false` / `unclear`）複製這個分支，測試仍然會過——這個改壞對照不會 FAIL。
- **修法**：改壞的位置要放在可能真的被實作出來的地方，也就是頁面層：「迴圈看到 `notSent` 就重新 `loginFor` 再送」。斷言 `loginFor` 只呼叫一次、`requestMakeNetwork` 只呼叫一次、畫面問繼續 / 停。這條移到第 5 步（Z-M2 原本的建議）。第 3 步保留「`OwnerConsole` 內部不重送」，改壞方式改成把 `retry` 預設成 `true` 且不帶 `unclear`。

### AA-m4　§2.3:73「建立完成 = `[NET_STATE] ` 開頭」不對：建立成功的句子是 `[NET_MADE]`

- **證據**：建立成功的回答是 `net_made_text` 的 `[NET_MADE] 網路已建立：…`（owner.rs:446-447、:1100），P8:34 也這樣寫。`[NET_STATE] ` 是確認網路的回答（owner.rs:487-490）。
- **後果**：§2.5:118 判斷建立有沒有完成是靠重讀那一筆紀錄，不看句子，所以照 §2.5 做是對的。但 §2.3 寫「判斷只在頁面做、只看這個型別」，實作者如果照 §2.3:73 用 `[NET_STATE] ` 判斷建立完成，就永遠判斷成沒完成，每次建立後都會自動檢查一次。
- **修法**：§2.3:73 改成「檢查拿到回答 = `kind == answer && text.startsWith('[NET_STATE] ')`；建立有沒有完成不看句子，看重讀（§2.5）」。

### AA-m5　金鑰拒絕：`ConsoleReply.kind` 的優先順序沒寫；這和舊控制台不同，§4 沒有列

- **現況**：舊控制台在 `OwnerConsole` 範圍內遇到金鑰拒絕時，不會設 `core.blocked`：
  - sign / signAdmin 遇到拒絕時送空的簽章，Rust 收到後結束；
  - seal 遇到拒絕時，`why` 帶 `KEY_LEVEL` 句子進 `persist_failed`，Rust 回一般的 `Answer`（`[REQ_FAIL] …`），在 owner.rs:1144-1154；
  - 對應的 Dart 程式在 nodes.dart:164-167、:236-252、:266-271。
- **v14 的寫法**：§2.3:77「回 `leaseLost` 以外的 `refused` 並帶 `keyError` 旗標」。也就是說，Rust 這時其實回了 `answer` 或 `ended`，`OwnerConsole` 要把它改寫成 `refused`。
- **沒寫清楚的地方**：
  1. 一個請求中途發生金鑰拒絕，Rust 之後還會回句子。`text` 用哪一句？
  2. `persistedRel` 要不要保留？例如建立時第二次 `PersistNet`（applied）的 seal 失敗：第一筆已經寫成功，結果頁應該給「檢查網路」，不是「再試這一台」。
  3. 這是新的行為（舊控制台只顯示 `[KEY_LEVEL]`），但沒有列在 §4。
- **修法**：§2.3 補一句：「請求期間只要有任何 `KeyAbilities.refusedBy(e) != null`，就設 `keyError = true`、`kind = refused`、`text` = Rust 最後回的句子（沒有就用舊控制台的 `[KEY_LEVEL]` 句子）；`persistedRel` 照實際寫入結果，不清掉」。§4 加 D11：「`OwnerConsole` 裡的金鑰拒絕會讓 `core.blocked` 變成 `keys`（舊控制台只顯示）」。
- 「放棄這次加入」與檢查網路頁自己的 `open` / `seal` 遇到金鑰拒絕時，也走同一條 `keyErrorToRadio`（§3.2 T-R1(d) 已經假設會停）。
- **改壞對照**：第二次 `PersistNet` 的 seal 丟 `keyLevel` → 斷言 `keyError`、`persistedRel != null`、整個流程停、結果列只有「檢查網路」。改壞成在 `keyError` 時清掉 `persistedRel` → 結果列出現「再試這一台」→ FAIL。

### AA-m6　Z-m1 只修了一半：§2.4:94 仍說兩者是「同一條規則」，而且沒有改壞對照

- **證據**：
  - §2.4:87 定義了兩個用詞：「有 net」= 任何紀錄，「已建立的 net」= `applied`。
  - 但 §2.4:94 仍寫「這和第 6 列『沒有 net → 建立』是同一條規則」。照新的定義，第 6 列看的是「沒有任何紀錄」，4.1 看的是「沒有已建立的」，兩者不是同一條。
  - 第 4 步要把第 6 列改成用 `NetIndex`，而 `NetIndex` 帶 `applied`，這正是 Z-m1 擔心的誤改點。現在的 PR 2 行為是 home_page.dart:131-134。
- **修法**：
  - 把 :94 的理由改成「第 6 列在沒有任何紀錄時才給建立；4.1 選到 pending 時，再多給一個沒有已建立 net 時的出口」。
  - §6 第 4 步加「只有 pending 紀錄 → 第 6 列仍是『加入網路』」。改壞 = 第 6 列看 `applied` → FAIL。

---

## 3. nit

- **AA-n1**　§2.3:76「`unclear` / `ended` / 寫入錯誤之後舊碼會 drop session（nodes.dart:571-572）」：寫入錯誤那條路徑，舊碼其實**不會** drop。
  - `retry: false` 遇到非字串錯誤時，在 :554 rethrow，被 :579-582 接住，回 `[REQ_FAIL] 操作沒有成功`，session 留著。
  - v14 把它當成 `sessionAlive == false`、先關再登入，比舊碼保守，沒有問題，因為 Rust 那邊可能停在流程中間，下一個請求會被 `flow_busy` 拒絕。
  - 只要把文字改成「（寫入錯誤：新程式也當成已斷，比舊碼保守）」，不要寫成是照抄的。
- **AA-n2**　兩個地方沒有寫「`acquire` 被拒時顯示什麼」：
  - 檢查網路頁自己 `acquire`（§2.8:151）；
  - 「放棄這次加入」自己 `acquire`（§2.4:96）。

  照 D9，顯示同一句「另一個操作還在進行：<名稱>」、頁面不動，各補一句即可。另外，舊控制台的「忘記」前面有確認對話框（nodes.dart:1269-1280）。新頁面要不要保留，計畫沒有寫；建議照舊。
- **AA-n3**　D6:216「只在拿到 `PersistNet` 的 `rel` 時做」改成「只在有 `persistedRel` 時做」（Y-m3 的殘留）。

---

## 4. v14 改動的其他檢查（沒有發現問題）

- **`NetRunPage` 用 `push` 疊在 4.1 上**：4.1 在 `NetRunPage` 期間仍然存在，`Page.home` 不變。佔用期間 `nodeLinkToken == null`，所以不會自動讀取（lease.dart:120）✅。`NetRunPage` 從建構子拿到佔用時 `_busy == 0` 且沒有 `pageGone`；佔用只有在 `pageGone` 的期限到了才會被收回（lease.dart:80-82、:140-149），所以 `initState` 呼叫 `hold()` 不會因為「已失效」而丟錯（lease.dart:60-61）✅。
- **`pageGone` 的擁有權**：`NetRunPage` dispose 時呼叫 `pageGone()`；這時沒有 hold，會立刻 `release()`（lease.dart:76-78）✅。4.1 只在交出之前的失敗路徑 `release`（範圍見 AA-m1）✅。借用的頁面只拿 / 放 `hold`，不會讓 `_gone` 變成 true ✅。
- **D9**：`NetRunPage` 或檢查網路頁 pop 之後，在 dispose 之前，4.1 已經在畫面上。這時按「開始」→ `acquire` 被拒 → 4.1 還在、表單還在，「再按一次」成立 ✅（Flutter 的 route dispose 時機是推論 ⚠️）。
- **§2.8 三條建立交接路徑**：
  - 從 4.1 進來：pop 給 4.1 ✅；
  - 從節點頁進來：`pushReplacement(4.1)`，4.1 記下的「進來前的那一頁」是節點頁 ✅（⚠️ 推論：檢查網路頁不改 `Page`）；
  - 借用的：檢查網路頁 → `NetRunPage` → 4.1，兩次 pop，佔用在 `NetRunPage` dispose 時釋放 ✅。

  三條都沒有兩個寫入者。
- **建立失敗的分支和 Rust 對得上**：`persist_failed` 在 `St::Join { applied: true }` 時回「節點已套用，手機紀錄沒存好，請按『檢查網路』」（owner.rs:1144-1150）。這只會發生在第二次 `PersistNet`，這時第一筆已經寫成功，`persistedRel` 有值，結果頁給「檢查網路」✅。`applied: false` 時回「建立網路沒有成功」，第一筆沒寫成，沒有 `persistedRel`，結果頁給「再試這一台」，而且什麼都沒送出 ✅。
- **`forgetJoining` 與 Rust**：`net_forget_joining` 拒絕忘記 pending 的建立者（owner.rs:140-141）。它從呼叫者給的 `record_gen` 做 CAS，所以在佔用下要重讀紀錄；拿過期的世代會被 CAS 擋下（fail-closed）✅。
- **被入侵的節點 / 本機非特權程序**：v14 沒有新的輸入面、平台方法或檔案路徑。`[NET_STATE] ` / `[JOINED] ` 只看開頭（owner.rs:645-650 的錯誤句子騙不到）✅。`keyError` 只由本機的 Keystore 例外觸發，節點沒辦法製造 ✅。

## 5. 基準備註（不算發現）

- 舊控制台的「忘記」也能忘記「已同意」的成員（`forgettable(joining, approved, creator)`，nodes.dart:1252）；新頁面的「放棄這次加入」只處理待辦裡那一台 `joining` 成員。這是範圍縮小，不是行為改變。
- Y / Z 的基準備註仍然成立：`InProgress` / `Unknown` 也給「建立網路」；pending 紀錄刪不掉；`_kick` 每次寫入都重設等待，和 420 s 上限的關係。

## 6. 驗證分類

### ✅ 已驗證（原始碼 @ e947148，唯讀）
- raw_use.dart:60-82（`RawLeaseScope.dispose` → `pageGone`；`openRawPage` 在 acquire 和 push 之間只檢查一次 `nav.mounted`，沒有非同步步驟）。
- lease.dart:42-150（`run` / `hold` 失效時丟錯；`pageGone` 在 idle 時立刻 `release`、busy 時設 420 / 900 s 期限；沒有呼叫 `pageGone` 就沒有期限；`nodeLinkToken`；`acquire` 被拒）。
- node_link.dart:151-195（`acquire` 先看 `reg.current`、`_dropAll`；`released` 讀紀錄）。
- app_link.dart:60-71、:135-144（`keyErrorToRadio` → `link.radio(keyOk: false)`）。
- nodes.dart:155-342（步驟迴圈；`_keyFail`；seal 失敗 → `persistFailed`；`confirmRemoved`；`ended` → `_drop`）、:395-443（:405-409 頁面不在時登入成功 → drop）、:476-500、:502-589（`_ask`：:520-521、:524-526、:547-554、:571-572、:579-582）、:640-671、:1240-1296。
- owner.rs:129-141（`net_forget_joining`）、:438、:446-447、:487-490、:514、:589-590、:1066-1155（`request_make_network`、`net_persisted`、`persist_failed`）、:1168-1192。

### ⚠️ 推論
- AA-m1 的後果（佔用卡到 app 重開）：從 lease.dart 推出，沒有跑。
- Flutter 的 route 在退場動畫之後才 dispose（D9 的前提）：沒有對 Flutter 原始碼逐行核對。
- 從節點頁進來的檢查網路頁不改 `Page`：計畫沒寫，照 §2.8 推論。

### ❌ 沒做
- 沒跑測試、沒上真機。
- 沒重驗 v1–v12 的發現。
- 沒審 PR 1 / PR 2 的實作。
- 沒讀 join2 全文、join2flow.rs。
- 沒查 home_page.dart:131-134 的現況（Z 已驗）。
