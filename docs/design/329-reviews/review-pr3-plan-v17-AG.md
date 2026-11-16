# #329 PR 3 實作計畫 v17 審查 — AG（獨立）

- 審查對象：`docs/design/329-pr3-plan.md` v17 @ 13d4053（§0–§9 整份讀過一次）。
- 前一輪：`review-pr3-plan-v16-AE.md`、`review-pr3-plan-v16-AF.md`。
- 基準（不重審）：`254-app-join2.md`；舊控制台 nodes.dart、member_ui.dart、owner.rs、rekey.rs、netrec.rs、flow.rs、join2flow.rs。對基準的疑問放在 §4。
- 方法：只讀原始碼（Read / grep / sed / git log），沒有跑測試，沒有上機。除了本檔，沒有改任何檔案。

**Verdict：APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 9 MINOR**

v16 的 AF-M1（加入列「再試這一台」）已經修好。其餘 MINOR 大多也落實了。

v17 新增的 §2.9 第一條「金鑰例外一條規則」把 `open` 也算進去，但 `open` 在原始碼裡根本分不出「金鑰例外」和「這筆打不開」。所以這條和 §2.5:135、§2.6:147、§2.8:162，以及它自己同一段的 T8 句互相矛盾，實作者沒辦法照原始碼自己解開，見 MAJOR-1。另外幾行舊字沒有跟著 §2.9 改，見 MINOR。

---

## 1. v16 發現的對應

| 發現 | 結果 | v17 位置 | 證據 |
|---|---|---|---|
| **AF-M1** 加入列「再試這一台」只寫 `joinNetwork` | ✅ | §2.5:139；§6 第 5 步（:270「加入列再試：已是成員回 `[JOINED] ` + `sendUpdate` → 會送新密碼…改壞 = 拿掉 `sendUpdate` 分支 → FAIL」） | `send_update = applied && behind`（owner.rs:1436-1440）；`node_behind`（join2flow.rs:322-331）；舊控制台的「繼續加入」整條重跑，包括 `_sendAfter`（nodes.dart:663-668） |
| AF m1 停下時的畫面 | ⚠️ | §2.9:192 | `Why` 在 core.dart:61，句子在 node_list.dart:19-25 ✅。但上層設計 :546 寫的是「`precondition` → 顯示 2.3 / 2.2 / 2.4 的**內容與按鈕**」；§2.9 只寫「原因句子」，沒寫按鈕（例如開藍牙）。見 m6 |
| AF m2 / AE-m3 金鑰例外兩條規則重疊 | ❌ | §2.9:189 | 把 `open` 也算進「Keystore 例外」，但 `open` 的錯誤碼永遠是 `keystore`，不是 `keyLevel`（MainActivity.kt:136-139，不經 `keyCall` 的閘門）。見 **MAJOR-1** |
| AF m3 全部打不開時 4.1 顯示什麼 | ⚠️ | §2.9:189 | 方向對（join2:128 的 T8 句 = nodes.dart:609-610）。但「全部**因金鑰**打不開」無從判斷，而且和同段「金鑰例外 → 整個停、core 的金鑰句子」衝突。見 MAJOR-1 |
| AE-m4 / AF m4 `makeNetwork` 開頭的 `KeyUse` 檢查 | ⚠️ | §2.9:190 | 對到 `notSent` + `keyError` ✅（nodes.dart:476-482）。不足：(1) 這條是拒絕不是例外，不會呼叫 `keyErrorToRadio`，`core.blocked` 不變，所以 §2.9:189 的「顯示 core 的金鑰句子」不存在，畫面該顯示的是 `[REQ_FAIL] [KEY_LEVEL] …` 原句；(2) 結果頁建立列沒有 `persistedRel` → 給「再試這一台」，但必定再被拒；(3) §6 第 3 步沒有這條測試（AE-m4 有要求）。見 m4 |
| AE-m1 / AF m10 送新密碼的列文字 | ⚠️ | §2.9:191；§2.5:131 沒同步 | `[REQ_FAIL] …` 系列與 `中斷（{w}）` 都在 rekey.rs:432-456 ✅。但 `refused`、`ended` 對到哪個列文字仍沒寫；§6 沒有 AE-m1 要的改壞對照（`Broken` → 不是「沒有送出」）。見 m3 |
| AF m5 擁有權表少寫入者 | ✅ | §3.1:211 | — |
| AF m6 `OwnerConsole` 生命週期、`nodeDacHash` | ✅（小殘字） | §2.9:198 | §2.8:166 仍寫 `session.nodeDacHash()`，應改成 `OwnerConsole.nodeDacHash()`（session 歸 `OwnerConsole`，§3.1:210）。見 m1 |
| AF m7 / AE-m5 對話框、`precondition` | ⚠️ | §2.9:196 ✅；§2.5:134 ❌ | §2.5:134 仍寫「`core.blocked` 或 `precondition` 變成擋住」，和 §2.9:196「不是 `precondition`」相反。能聽的事件在 node_link.dart:146-148、:229，`blocked` 在 core.dart:312 ✅。見 m1 |
| AF m8 第一台的順序、自動檢查登入失敗的句子 | ⚠️ | §2.9:192、:194 | 句子 ✅。順序：「節點暱稱排序」是新規則。現有清單都照 id 排（home_page.dart:214、node_list.dart:73），而且暱稱可能是空的或重複，沒有寫同名時怎麼排。見 m7 |
| AF m9 頁面消失時 `linkCheck` | ✅ | §2.9:197 | 舊碼靠 `mounted` 中止（nodes.dart:700）。§6 沒有對應的改壞對照，見 m8 |
| AF m11 / D12 建立失敗不問 | ⚠️ | D12:254、§2.9:193 | D12 ✅。但 §2.5:133 的「其他（…登入失敗）→ 問繼續 / 停」沒有限定只對加入的台，建立那一台登入失敗照字面會問。見 m2 |
| AE-m2 §3.2 頁面消失 | ⚠️ | §3.2:229 ✅；§2.5:125 ❌ | §2.5:125 仍只寫「紀錄停在 pending → 檢查網路」（只對建立成立），沒有補加入 → joining。佔用收回時的首頁待辦「上一個操作可能沒有存完」（lease.dart:110、:140-144 `_revoke`）兩處都沒提。見 m5 |
| AE-m6 預勾只算一次 | ✅ | §2.9:195 | — |
| AE-m7 小處 | ⚠️ | §2.9:201 | GATT 寫入錯誤用「操作沒有成功」✅（nodes.dart:579-580）。app_link 路徑 ✅。但 (1) §2.9:201 說 AD-M1 的改壞對照「移到 §6 第 4 步」，實際上 §6 第 4 步（:269）沒有，它仍在第 5 步（:270「首頁待辦不列 pending 的建立者（`forgettable`…）」）；(2) §2.8:180 仍放在「按『建立網路』」的子項底下。見 m1 |

---

## 2. 發現

### MAJOR-1 「金鑰例外」把 `open` 算進去，但原始碼分不出 `open` 的金鑰例外和「這筆打不開」；§2.9:189 和 §2.5:135、§2.6:147、§2.8:162 以及自己的 T8 句互相矛盾

**事實（✅，原始碼）**

- Kotlin `open` 不經 `keyCall` 和閘門。任何失敗（GCM tag 不符、紀錄太短、金鑰失效）都回錯誤碼 `"keystore"`（MainActivity.kt:136-139；Keys.kt:131-137）。
- `KeyAbilities.refusedBy` 只認 `code == 'keyLevel'`（key_abilities.dart:96-97）。
- 因此 `keyErrorToRadio` 對 `open` 的錯誤**永遠什麼都不做**（app_link.dart:142-144），`core.blocked` 不會變成 `Why.keys`，畫面上沒有「core 的金鑰句子」可以顯示。
- 真正「紀錄金鑰不見了」的情況，在 `RECORD_AES` 不見時 → `appUsable == false`（key_abilities.dart:39），已經被 `loginFor` 開始前的即時 `KeyAbilities` 檢查擋成 `precondition`（計畫 §2.1:45）。
- 舊碼對 `open` 失敗的處理都是「這筆打不開」：
  - `_pickNet` 跳過並記一行（nodes.dart:600-605）；
  - `_readRecord` 回 null（nodes.dart:738-746，`on PlatformException` 在 :743）。

**計畫的文字**

- §2.9:189：「任何地方（…頁面的單筆重讀、檢查網路頁的重新列檔、4.1 的快照）遇到 Keystore 例外 → `keyErrorToRadio` → 整個流程 / 頁面停，顯示 `core` 的金鑰句子；**優先於**『重讀失敗 → 檢查網路』與『打不開就跳過』。」
- 同一段接著寫：「手機有 net 檔但全部因金鑰打不開 → 4.1 顯示 join2 T8 的提示句。」
- §2.8:162：「打不開的單筆照 `NetIndex` 同一個函式、同一規則（跳過…舊控制台也跳過）。」
- §2.6:147：壞的一筆記一行。
- §2.5:135：「重讀單筆紀錄失敗（打不開、讀不到）→ 當成不是已建立（走檢查網路）。」

**情境**

手機裡有一筆打不開的 `net/` 紀錄。可能是舊安裝留下的，或某次寫壞了。另外還有一筆正常、已建立的網路。

- `NetIndex`（不在佔用下）照 §2.6 跳過那一筆，所以 4.1 顯示加入表單。
- 使用者按「開始」→ 4.1 在佔用下重新列檔（§2.4:107）→ `open` 丟 `PlatformException('keystore')`。
- 照 §2.9:189，這就是「Keystore 例外」而且「優先於跳過」→ 整頁停。
- 因為 `NetIndex` 下次還是會跳過這筆，**之後每一次按開始都停**。檢查網路頁的重新列檔同樣每次都停。
- 實作者如果反過來，把這種錯誤當成「打不開」，那 §2.9:189 那一句對 `open` 就沒有任何作用，而「顯示 core 的金鑰句子」也無從實作。

兩種讀法都說得通，文字本身決定不了。其中一種會讓這支手機在新頁面上永遠不能加節點、不能檢查網路，舊控制台則照常可用。

同一段的 T8 句（「全部**因金鑰**打不開」）也一樣無從判斷，而且和「整頁停、core 的金鑰句子」是同一個觸發條件、兩種畫面。

**修法（照舊碼，不加機制）**

- §2.9:189 改成：`keyError` / `keyErrorToRadio` 只用在 seal / sign / signAdmin（經 `keyCall`，可能是 `keyLevel`），以及 `KeyUse` 的即時拒絕。
- `open` 的任何錯誤一律是「這筆打不開」（MainActivity.kt:136-139：`open` 不經閘門，分不出原因）：
  - 列檔時（`NetIndex`、4.1 快照、檢查網路頁）→ 跳過並記一行（舊 `_pickNet`）；
  - 單筆重讀 → 當成不是已建立（舊 `_readRecord`、§2.5:135，fail-closed）；
  - 有 net 檔但一筆都打不開 → 4.1 和檢查網路頁顯示 T8 句（nodes.dart:609-610），不給表單、不給「建立網路」，也不說「沒有需要檢查的網路」（這是 AF m2 原本擔心的誤報）。
- 紀錄金鑰真的不見時，由 `loginFor` 的即時 `KeyAbilities`（`precondition` → 2.4）處理，不需要從 `open` 判斷。
- 同步改 §2.3:86 的「頁面自己單筆重讀的 `open` 遇到同樣的例外…整個停」這一句。

**改壞對照**

- 假的 `open` 對三筆裡的一筆丟 `PlatformException('keystore')` → 4.1 的「開始」照常進 `NetRunPage`，檢查網路頁照常檢查其餘幾筆。改壞 = 把 `open` 的例外當 `keyError` → FAIL。
- 全部丟 → 4.1 顯示 T8 句、沒有表單；檢查網路頁不顯示「沒有需要檢查的網路」。改壞 = 照跳過後的空清單判斷 → FAIL。

### MINOR

- **m1 沒有跟著 §2.9 改的舊字。** 每一處各自讀起來都會讓實作者照舊行為做；有 §2.9 可以對照，所以列 MINOR：
  - :134 §2.5「`core.blocked` 或 `precondition` 變成擋住」→ 照 §2.9:196 改成「`core.blocked` 非 null 或 `!lease.valid`」。
  - :166 §2.8「`session.nodeDacHash()`」→ `OwnerConsole.nodeDacHash()`（§2.9:198）。
  - :180 §2.8「檢查網路頁回到 4.1 時不是『去建立』…」仍放在「按『建立網路』」的子項底下（AE-m7 第二點沒有做）。
  - :269 / :270 §6：§2.9:201 說 `forgettable` 的改壞對照搬到第 4 步，但它還在第 5 步，第 4 步沒有。
  - :87 §2.3「確認用 `_waitLine`」只對逾時成立；GATT 錯誤的句子在 §2.9:201。建議在 :87 直接寫兩種，免得兩處各說一半。
  - :131 §2.5 的列文字只有 `notSent` / `unclear`；`answer` 非 `[UPDATED] ` 的那一種只在 §2.9:191。建議在 :131 合併成一處。
- **m2 §2.5:133「其他（…登入失敗）→ 問繼續 / 停」沒有限定只對加入的台。** 建立那一台登入失敗、`refused`、`unclear`（沒有 `persistedRel`）時，照 :133 會問，照 D12 / §2.5:128 會整個停。修法：:133 開頭寫「加入的台：」，並寫明建立的台任何失敗都照 D12 停。§6 第 5 步加「建立那一台登入失敗 → 不問、整個停」（改壞 = 照 :133 問 → FAIL）。
- **m3 送新密碼的 `refused` / `ended` 沒有列文字，也沒有測試。**
  - `refused`（例如 `NOT_LOGGED_IN`）和 `ended` 都可能出現。建議：`refused` → 「已加入，新密碼沒有送出」+ 句子；`ended` → 「已加入，新密碼結果不明」+ 句子，因為訊框可能已經送出。
  - §6 加 AE-m1 的改壞對照：`[REQ_FAIL] 中斷（…）` → 那一列不是「沒有送出」。
- **m4 `KeyUse.makeNetwork` 被拒的畫面與「再試」。**
  - 這條不經 `keyErrorToRadio`，所以 `core` 沒有金鑰句子。停下時顯示 `[REQ_FAIL] [KEY_LEVEL] …` 原句（照舊碼 nodes.dart:479-480）。
  - 結果頁建立列帶 `keyError` 時不要給「再試這一台」（必定再被拒），只顯示句子。這一點是「照 D11 整個停」的延伸，不是新機制。
  - §6 第 3 步加：`KeyUse.makeNetwork` 被拒 → `notSent` + `keyError`，而且沒有送出任何訊框（改壞 = 沒設 `keyError` → 迴圈問繼續 → FAIL）。
- **m5 §2.5:125 頁面消失超過 420 s 只寫了建立。** 補「加入 → 成員停在 joining → 首頁待辦『節點加入網路沒有做完』」。另外佔用被收回時 `LeaseRegistry` 會加首頁待辦「上一個操作可能沒有存完：<名稱>」（lease.dart:110 `unsavedTodos`、:140-144 `_revoke`），§2.5:125 和 §3.2:229 都寫明這一行會出現。T-M1(g) 加超時那一臂（AE-m2 有要求）。
- **m6 停下畫面的 `precondition`。** §2.9:192 只寫「原因句子」。上層設計 :546 要的是 2.3 / 2.2 / 2.4 的**內容與按鈕**（例如開藍牙、到設定）。修法：`precondition` → `NetRunPage` / 檢查網路頁嵌入 2.x 的內容；其他 `LoginEnd` 用 `Why` 的句子（node_list.dart:19-25）。
- **m7 「勾的第一台」的排序。**
  - 「節點暱稱排序」和現有清單（照 id 排，home_page.dart:214、node_list.dart:73）不同。
  - 暱稱可以是空的或重複，沒寫怎麼排。
  - 修法：照 4.1 清單的顯示順序，清單本身照 id 排（和首頁一樣），或寫明「暱稱、同名再照 id」。
  - 4.1 要明確標出「這台建立網路」，使用者才知道可以換（從 3.6 按「建立網路」時，剛認領的 02 和先前的 04 都會預勾）。
- **m8 §2.9 的新規則大多沒有改壞對照。** 全域規則要求每個宣稱的修正都有負對照。§6 缺：
  - 預勾只算一次（讀到 `node_state == 1` 不補勾；改壞 = 讀到就勾 → FAIL）；
  - 國家對話框開著時斷線 → 只出現一個「繼續 / 停」（改壞 = 疊兩個 → FAIL）；
  - 頁面消失時 `linkCheck` 中止（改壞 = 跑完 120 s → FAIL）；
  - 自動檢查的重新登入失敗 → 那一列的句子；
  - D12（見 m2）、`KeyUse` 被拒（見 m4）、T8（見 MAJOR-1）。
- **m9 §2.9:189「顯示 `core` 的金鑰句子」對 seal / sign 的 `keystore` 錯誤也不存在。** 只有 `keyLevel` 會讓 `keyErrorToRadio` 設 `keyOk:false`。其他 Keystore 錯誤（`keyCall` 的 catch，MainActivity.kt:76-77）不會。§2.3:86 寫「`kind` / `text` 照 Rust 原樣」，§2.9 寫「顯示 core 的金鑰句子」，兩處說法不同。修法：停下時有 `core.blocked == Why.keys` 就顯示那一句，否則顯示 `ConsoleReply.text`。

---

## 3. 整份對照：§2.9 和其他節是否一致（逐行）

| 行 | 內容 | 和 §2.9 的關係 | 嚴重度 |
|---|---|---|---|
| :86 | §2.3「頁面自己單筆重讀的 `open` 遇到同樣的例外…整個停」 | 和 :135 衝突；`open` 沒有可分辨的金鑰例外 | MAJOR-1 |
| :135 | §2.5「重讀單筆失敗（打不開…）→ 當成不是已建立」 | 被 :189 的「優先」吃掉 | MAJOR-1 |
| :147 | §2.6 壞的一筆記一行 | `NetIndex` 跳過、4.1 快照停 → 永遠開始不了 | MAJOR-1 |
| :162 | §2.8 打不開的單筆跳過 | 被 :189 吃掉 | MAJOR-1 |
| :189 | §2.9 T8 句 vs 金鑰停 | 同一觸發條件、兩種畫面 | MAJOR-1 |
| :125 | §2.5 超過 420 s 只寫 pending | 和 §3.2:229 不一致 | m5 |
| :131 | §2.5 送新密碼列文字 | 由 §2.9:191 補充，分兩處 | m1 |
| :133 | §2.5「其他…登入失敗 → 問」 | 和 D12 衝突（建立的台） | m2 |
| :134 | §2.5「`precondition` 變成擋住」 | 和 §2.9:196 相反 | m1 |
| :166 | §2.8 `session.nodeDacHash()` | §2.9:198 | m1 |
| :180 | §2.8 位置 | AE-m7 沒做 | m1 |
| :270 | §6 第 5 步 `forgettable` 測試 | §2.9:201 說已移 | m1 |

其他節（§2.1、§2.2、§2.4、§2.7、§3.1、§3.2 其餘列、§4 D1–D11、§5、§7、§8）沒有找到和 §2.9 衝突的地方，也沒有 v9–v16 留下、會讓實作者照舊行為做的字。§9 的歷史表保留舊用語屬於紀錄，不算。

---

## 4. 基準備註（不算發現）

- 舊 `_pickNet` 對只有 mnet 的手機也會顯示「新建網路會讓整隊分成兩個網路，舊節點要重燒」（nodes.dart:607-611，因為 `nets.isEmpty`）。計畫 §2.4:101 在新頁面避開了這個情況，和 MAJOR-1 修法裡「有 net 檔但全部打不開 → T8 句」的觸發條件不同（一個沒有 `net/` 檔，一個有但打不開），不衝突。
- 舊 `_ask` 把 Rust 的拒絕（`Err(String)`）經外層 catch 變成「`[REQ_FAIL] 操作沒有成功：<code>`」（nodes.dart:543、:579-580）。計畫的 `refused` 用的是同一句，沒問題。
- 舊 `_readRecord` 吞掉 `open` 的 `PlatformException`（nodes.dart:738-746），而 `keyErrorToRadio` 對 `open` 本來就沒有作用。所以 MAJOR-1 的修法就是「照舊碼」，不比基準寬鬆。

## 5. 安全

- 本機非特權程序：v17 沒有新的平台方法、路徑或匯出元件（§5）。紀錄目錄是 app 私有目錄。✅（從 §5 與 MainActivity.kt 的方法清單推論，manifest 沒有重查 ⚠️）
- 被入侵的節點：所有成功判斷只看 Rust 組出來的句子開頭（`[NET_STATE] ` / `[JOINED] ` / `[UPDATED] ` / `[CONNECTED]`）。節點提供的字串只會出現在句子中段（rekey.rs:432-456；owner.rs:513-517）。§2.9 沒有改這一點 ✅。MAJOR-1 的情境不是攻擊者造成的（紀錄只在手機上），但 fail 的方向是可用性：不能加節點，所以列 MAJOR。
- MAJOR-1 的修法是 fail-closed：單筆打不開 → 不是已建立 → 檢查網路；全部打不開 → 不給表單、不給建立。

## 6. 驗證分類

### ✅ 已驗證（原始碼 @ 13d4053，唯讀）
- MainActivity.kt:73-85（`keyCall`）、:136-139（`open` → `"keystore"`）；Keys.kt:124-137。
- key_abilities.dart:39（`RECORD_AES` → `appUsable`）、:96-106（`refusedBy`）。
- app_link.dart:140-144（`keyErrorToRadio`）。
- nodes.dart:
  - :48-55（常數）；
  - :476-489（`_makeNetwork` 的 `KeyUse` 檢查）；
  - :540-589（`_ask` 的寫入錯誤、drop、外層 catch「操作沒有成功」）；
  - :600-622（`_pickNet` 跳過、T8 句）；
  - :626-669（`_joinNetwork` 含 `_sendAfter`）；
  - :687-716（`_watchLink`，`mounted`）；
  - `_readRecord`（`on PlatformException` → null）。
- rekey.rs:430-457（`update_text`）。
- owner.rs:1425-1440（`poll_link` / `send_update`）；join2flow.rs:322-331（`node_behind`）。
- core.dart:61（`Why`）、:310-312（`blocked`）、:642（`LoginEnd`）；node_list.dart:19-25；node_link.dart:140-148、:225-229。
- lease.dart:57-90（`hold` / `pageGone` 420 s）、:96-117（`goneMax`、`unsavedTodos`）。
- home_page.dart:214、node_list.dart:73（照 id 排序）。
- 上層設計 329-app-uiux.md:546、:736-750。join2:127-128（T8）。

### ⚠️ 推論
- MAJOR-1 的「舊安裝留下或寫壞的單筆紀錄」在現場出現的頻率：沒有實際資料。觸發條件是任一筆 `open` 失敗，從原始碼可以確定。
- `ended` 的送新密碼「訊框可能已送出」（m3）：照 `updflow` 的結束種類推論，沒有追 updflow.rs。
- manifest 沒有新的匯出元件：程式還沒寫。

### ❌ 沒做
- 沒跑任何測試，沒上真機。
- 沒有重新核對 v1–v15 的發現。
- 沒讀 join2 全文。
