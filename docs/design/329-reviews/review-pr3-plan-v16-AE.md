# #329 PR 3 實作計畫 v16 審查 — AE（獨立）

對象：`docs/design/329-pr3-plan.md` v16 @ df47d0d。只讀原始碼（Read / grep / sed），沒有跑測試、沒有上機。基準（join2、舊控制台 nodes.dart / member_ui.dart、owner.rs / rekey.rs / netrec.rs / flow.rs）不重審，疑問放在「基準備註」。

**Verdict：APPROVE-WITH-CHANGES**（0 BLOCKER / 0 MAJOR / 7 MINOR）

v15 的兩個 MAJOR 都已修好，修法用的是舊碼現成的東西：
- AD-M1：待辦改用 `forgettable`。
- AD-M2：`keyError` 涵蓋所有金鑰呼叫。

v16 自己改的地方沒有和別節衝突到會讓實作者做出錯誤現場行為的程度。剩下的 7 個 MINOR 都是同一類問題：兩節之間的優先順序沒寫，或標籤沒對到所有 `kind`。只要改文字，不需要新機制。

---

## 1. v15 發現的對應

| 發現 | 結果 | v16 位置 | 證據（原始碼 @ df47d0d） |
|---|---|---|---|
| AD-M1 待辦列到 pending 的建立者 | ✅ | §2.6:150、§6 第 5 步 | `forgettable = joining && !creator`，見 member_ui.dart:172。pending 紀錄沒有 key 11 時成員一律是 `Joining`，見 netrec.rs:395。`creator` 只在 pending 時為真，見 owner.rs:110、:121。改壞對照放在第 5 步，不在實作待辦的第 4 步（AE-m7） |
| AD-M2 / AC-m4 `keyError` 沒涵蓋 sign / signAdmin | ✅ | §2.3:86、§6 第 3 步 | `_keyFail` 在 nodes.dart:238、:249；`keyErrorToRadio` 只在 `refusedBy != null` 時設 `keyOk:false`，見 app_link.dart:142-144（檔案在 `lib/src/nodelink/`）。v16 選擇任何 Keystore 例外都設 `keyError`，沒有採用 AC 建議的 `refusedBy != null` 條件，並寫明理由（迴圈不能只看 `core.blocked`）。這個方向比較保守，畫面上有 Rust 的句子可看，可以接受。改壞對照有寫 |
| AC-m1 / AD-m2 送新密碼的不明句與等待 | ⚠️ | §2.3:87 ✅；§2.5:131 ⚠️ | `_sendUnclear` 在 nodes.dart:55，等待在 :1581 用 `_joinWait`，`joinWait` 是 360 s（member_ui.dart:231）✅。但 §2.5 只替 `notSent` / `unclear` 定了標籤；送新密碼最常見的失敗是 `kind == answer` 加上 `[REQ_FAIL] …`（rekey.rs:432-456），它的標籤沒有定義。`_readRecord` 回 null 時對到哪個 `kind` 也還沒寫（nodes.dart:1573-1577）。見 AE-m1 |
| AC-m2 `sessionAlive` 漏一種 | ✅ | §2.3:85 | 對得上 nodes.dart:571 `unclear != null && (a == unclear \|\| a == _notSent)` |
| AC-m3 連線檢查放哪 | ✅ | §2.5:132 | `_watchLink` 在 nodes.dart:687-716：讀取失敗或 session 被換掉 → break；不是連上的回答 → 繼續。`poll_link` 和 `send_update` 互斥，見 owner.rs:1437、:1439 |
| AC-m5 / AD-m3 藍牙關的先後 | ✅（附 AE-m5 nit） | §2.5:134、§6 第 5 步 | `NodeLink.radio()` → `_pump()` → `_changed.add`（node_link.dart:146-148、:229），`core.blocked`（core.dart:312）。所以頁面確實能在對話框開著時聽到。兩種先後各有一條測試 |
| AC-m6 國家「不要」的 kind | ✅ | §2.3:83 | `E::Declined` → `[COUNTRY] 已取消…` 經 `A::Done(e)` 變成 `OwnerKind::Answer`（owner.rs:518、:1427-1434）；被移除過的取消是 Dart 句子（nodes.dart:657-659） |
| AC-m7 D6、§3.2 開始列、行號、:452、`persistedRel` 只用在建立列 | ✅ | D6:231、§3.2:205、§2.3:79-80 | 開始列已補 `_pending` 路徑與「讀不到」；:710、:452 都對 |
| AD-m1 兩種「寫入失敗」 | ✅ | §2.3:84、§6 第 3 步 | `persist_failed` 回 `Answer` 並 `back_to_conn()`（owner.rs:1132-1155）。§9 v12 表的舊字還在，屬歷史表，不算 |
| AD-m4 360 s 會重設 | ⚠️ | §2.5:125 ✅；§3.2:213 ❌ | §2.5 已改寫；§3.2「工作途中頁面消失」那一列仍寫「那一次寫入成功、沒有『沒存完』待辦」，和 §2.5 互相矛盾。見 AE-m2 |
| AD-m5 3.5 / 3.6 進來預勾 | ⚠️ | §2.5:111 | 預勾已補。但「預勾只在 4.1 第一次顯示時算」沒寫；同一段的「讀到後狀態會更新」會被讀成「讀到 `node_state == 1` 就補勾」。見 AE-m6 |
| AD-m6 4.1 次要建立、檢查頁非建立回來 | ✅（附 nit） | §2.4:104、§2.8:180 | 兩句都補了。:180 放在「按『建立網路』」的子項底下，位置不對（AE-m7） |
| AD-m7 登入失敗前看 `lease.valid` | ✅ | §2.5:134 | — |

---

## 2. MINOR

### AE-m1　送新密碼失敗的列標籤只對到 `notSent` / `unclear`，最常見的 `answer` + `[REQ_FAIL] ` 沒有標籤

- **情境**：情境 (j)，加入成功後送新密碼。節點回 `Unfinished` 或 `Broken(w)`。
- **證據**：
  - 送新密碼的失敗幾乎都是 Rust 的 `answer`：`[REQ_FAIL] 沒有送出：…`（rekey.rs:432-450、:455），`[REQ_FAIL] 沒有換成功，可再試`（:454），`[REQ_FAIL] 中斷（{w}）`（:456）。
  - 其中 `Broken` 可能發生在訊框已經送出之後。
  - 另外還有 `refused`、`ended`、`leaseLost` 三種。
  - `_readRecord` 回 null（nodes.dart:1573-1577）時，舊碼只 `_say`、不經 `ask`。
- **後果**：
  - 頁面的判斷是對的：不是 `[UPDATED] ` 就算失敗、問繼續 / 停。
  - 但列標籤得由實作者自己猜。若把所有失敗都標成「新密碼沒有送出」，`中斷` / `ended` 那幾種會誤導使用者，以為節點沒被動過。不過句子本身會一起顯示。
- **修法**：§2.5:131 寫成三條：
  - `notSent`、`refused`、`leaseLost`、`_readRecord` 回 null（記成 `notSent`）→「新密碼沒有送出」；
  - `answer` 而且以 `[REQ_FAIL] 沒有送出：` 開頭 → 也是「新密碼沒有送出」；
  - 其他（`unclear`、`ended`、別的 `[REQ_FAIL] `）→「新密碼沒有完成」（或「結果不明」）。
  - 每一條都附上句子。
- **改壞對照**：假節點回 `Broken` → 斷言那一列不是「沒有送出」。

### AE-m2　§3.2「工作途中頁面消失」和 §2.5:125 矛盾；`fail-closed` 那句只對建立成立

- **證據**：
  - §2.5:125 已承認「超過時佔用被收回、`RecordWriter` 拒絕」。
  - `pageGone` 420 s 期限（lease.dart:57、:80-81），收回時會加首頁待辦「上一個操作可能沒有存完」（lease.dart:101-105）。
  - §3.2:213 仍寫「那一次寫入成功、沒有『沒存完』待辦」。
  - 另外 §2.5:125 的「紀錄停在 pending → 檢查網路」只適用於建立。加入時是成員停在 joining → 待辦「節點加入網路沒有做完」（§3.2:208）。
- **修法**：§3.2:213 改成「通常那一次寫入成功；超過 420 s → 佔用收回、首頁『上一個操作可能沒有存完』；建立 → pending → 檢查網路，加入 → joining 待辦」。§2.5:125 同步補上加入那一半。T-M1(g) 加一條超時的情況。

### AE-m3　單筆重讀遇到金鑰例外：§2.3:86 說「整個停」，§2.5:135 說「當成不是已建立、走檢查網路」

- **證據**：
  - §2.3:86：「頁面自己單筆重讀的 `open` 遇到同樣的例外，也呼叫 `keyErrorToRadio` 並整個停」。
  - §2.5:135：「重讀單筆紀錄失敗（打不開、讀不到）→ 當成『不是已建立』（fail-closed，走檢查網路）」。
  - 照 §2.5:129，「不是已建立」而且 `sessionAlive` → 直接 `confirmNetwork`，**不經** `loginFor`，所以不會被 `precondition` 擋下。
- **後果**：照 §2.5 實作會多做一次確認。確認裡的 `PersistNet` → seal 又失敗 → `keyError` → 停。紀錄不會壞，但兩節的文字不一致。
- **同一類**：建立回來就帶 `keyError`（第二次 `PersistNet` 的 seal 失敗）時，要先停還是先重讀 / 自動檢查，§2.5:129 沒寫順序。
- **修法**：§2.5:135 加「金鑰例外除外（§2.3：整個停）」；§2.5:129 開頭加「`keyError` → 停（保留 `persistedRel`），不重讀、不自動檢查」。

### AE-m4　`makeNetwork` 前的 `KeyUse.makeNetwork` 即時檢查沒有對到 `ConsoleReply`

- **證據**：
  - 舊 `_makeNetwork` 先 `KeyAbilities.read(...).refusal(KeyUse.makeNetwork)`，被拒時只 `_say('[REQ_FAIL] [KEY_LEVEL] …')` 就返回，什麼都沒送（nodes.dart:476-482）。
  - `makeNetwork` 還需要 `ADMIN_SIGN`（key_abilities.dart:47）。`loginFor` 只看登入，所以「管理者金鑰遺失 / 不是硬體保護」時登入會成功。
  - 這不是例外，所以 §2.3:86 的 `keyError` 不會設；§2.3:83 的舊路徑對應也沒有這一條。
- **後果**：
  - 建立模式下沒有 `persistedRel` → 整個停，方向是對的。
  - 但 `kind` 由實作者自己決定。結果頁建立列會給「再試這一台」，而它必定再被拒。
  - 這也和 D11「金鑰 → 停不問」的精神不一致：`core.blocked` 沒設，沒有 2.4 畫面。
- **修法**：§2.3:83 加一條：「`KeyUse.makeNetwork` 被拒 → `notSent` + `keyError = true`，`text` 是舊碼同一句」。這不是新機制，只是對到已有的欄位。§6 第 3 步加一條測試。

### AE-m5　「`precondition` 變成擋住」不是可以聽的事件

- §2.5:134 寫「問的對話框開著時 `core.blocked` 或 `precondition` 變成擋住」。但 `precondition` 是 `loginFor` 的結果（core.dart:642），對話框開著時不會「變成」。
- 能聽的只有 `NodeLink.changed` 加上 `core.blocked`（node_link.dart:82、:229；core.dart:312），另外 `lease.valid` 也可以檢查。
- **修法**：改成「`core.blocked` 變成非 null 或 `!lease.valid`」。

### AE-m6　預勾的時機沒寫

- §2.5:111 的「剛認領的節點讀到後狀態會更新」沒說會不會跟著改勾選。AD-m5 的第二點沒有落實。
- 如果讀到 `node_state == 1` 就自動補勾，使用者剛手動取消的那一台可能又被勾回去。
- **修法**：加一句「預勾只在 4.1 第一次顯示時算；之後讀到的狀態只更新顯示，不改勾選」。

### AE-m7　小處

- AD-M1 的改壞對照（「首頁待辦不列 pending 的建立者」）列在 §6 第 5 步，但待辦是在第 4 步（`NetIndex` + 首頁待辦）做的。第 4 步的「每一步跑全套、各自附改壞對照」在那時沒有這條測試。建議搬到第 4 步。
- §2.8:180「檢查網路頁回到 4.1 時不是『去建立』…」放在「按『建立網路』」的子項底下，建議提出來成為獨立的一項。
- 計畫引用的 `app_link.dart` 實際路徑是 `lib/src/nodelink/app_link.dart`。
- §2.3:87「確認用 `_waitLine`」只對逾時成立。確認遇到 GATT 寫入錯誤時，舊碼走 :554 `rethrow` → :579-582，句子是「`[REQ_FAIL] 操作沒有成功：…`」，不是 `_waitLine`。判定一樣（沒拿到回答），只是句子不同。寫明或照舊句。

---

## 3. v16 改動的其他檢查（沒有發現問題）

- **§2.3 `keyError` 全涵蓋**：
  - sign / signAdmin 的例外在步驟迴圈裡被接住、送空簽章，Rust 回 `answer` 或 `ended`（nodes.dart:232-252；rekey.rs:455 `SignFailed`）。
  - v16 寫「`kind` 照 Rust 原樣、另設 `keyError`」，和這條路徑一致 ✅。
  - `confirmRemoved` 之後的重讀（舊 `_readRecord` 吞掉 `PlatformException`，nodes.dart:738-746）在 OwnerConsole 裡也算金鑰呼叫：`notSent` + `keyError`，迴圈停 ✅。
- **§2.3 `sessionAlive`**：`unclear` 的確認逾時（`_waitLine`）也在舊碼 drop 的範圍（nodes.dart:572），v16 用 `kind == unclear` 涵蓋 ✅。
- **§2.3 GATT 與紀錄寫入**：
  - 有 `unclear` 參數的請求，寫入錯誤在 :545-551 處理。`SendTrack.wrote` 在送出前就設好（nodes.dart:184-185 的註解；member_ui.dart:309），所以實際上多半是 `unclear`，方向保守 ✅。
  - 紀錄寫入失敗是 `answer`、session 還在 ✅。
  - 佔用已收回時是 `leaseLost`。§2.3:90 的 `leaseLost` 優先於 :84 的 `answer`；文字可以更明確，但 §6 第 3 步已經有「persist 時佔用收回 → `leaseLost` 且呼叫 `persistFailed`」，不另列。
- **國家「不要」= `answer`**：頁面消失時回答「不要」→ `answer` → 頁面已不在，不問 ✅。
- **`linkCheck` 放在 OwnerConsole**：
  - 連線檢查用的是加入那次的 session，不重新登入。§2.3:85 的重登規則只適用於「頁面再送請求」，兩處不衝突 ✅。
  - `secsSinceJoin` 要從加入回答的時間算（舊 `_linkFrom`，nodes.dart:316）。照「複製 `_watchLink`」就會保留，不另列。
- **對話框被擋住就收起**：
  - 只有 `pageGone` 會收回佔用（lease.dart:81、:101），而頁面消失時對話框本來就當成「停」，兩條規則一致 ✅。
- **4.1 次要「建立網路」與非建立返回**：
  - 切到建立模式後，「開始」照常比對快照 ✅。
  - 檢查網路頁升級後，佔用在 dispose 時釋放 → `NetIndex` 重算並通知（§2.6:146、:148）→ 4.1 看到已建立的 net，次要「建立網路」消失、改給加入表單 ✅。
  - D6:232 列出的建立入口和 §2.4:104、§2.8:177 一致 ✅。
- **D6**：「只在有 `persistedRel` 時做」和 §2.5:128-129 一致 ✅。
- **§3.2**：建立中途被殺那一列（:207）和 §2.6 的 `forgettable` 一致，pending 建立者不會有加入待辦 ✅。只有 :213 有矛盾（AE-m2）。
- **被入侵的節點**：
  - 送新密碼成功只認 Rust 組的 `[UPDATED] ` 開頭（rekey.rs:447、:451、:452）。
  - 節點字串只出現在 `[REQ_FAIL] 中斷（{w}）` 的中段（:456）。
  - `[CONNECTED]` 由 Rust 組成（owner.rs:588-590）。
  - 被入侵的節點能做的仍然只有回失敗或回不明，不能讓頁面判成功 ✅。
- **本機非特權程序**：v16 沒有新的平台方法、檔案路徑或匯出元件 ✅。

## 4. 基準備註（不算發現）

- `keyErrorToRadio` 對 `ADMIN_SIGN` 的拒絕也會把 `keyOk` 設成 false，直到 app 重開（app_link.dart:140-144）。結果是管理者金鑰壞了之後，連只需要擁有者金鑰的登入也被擋。這是 PR 1 的 X26 基準。
- 國家對話框開著時斷線：舊碼的對話框留到使用者按下才發現 `gone()`（nodes.dart:271-289）。新頁面這時迴圈已經拿到 `unclear`。對話框怎麼收屬於基準行為，v16 沒改。

## 5. 驗證分類

### ✅ 已驗證（原始碼 @ df47d0d，唯讀）
- nodes.dart：
  - :48-55（常數）；
  - :164-167（`_keyFail`）；
  - :224-340（步驟迴圈：:238 / :249 簽章失敗、:256-273 persist、:276-291 國家、:292-298 `wait`、:331-338 `ended` 時 drop）；
  - :427-436（`_endUnclear`、`_unclearNow`）；
  - :476-489（`_makeNetwork` 的 `KeyUse.makeNetwork` 即時檢查）；
  - :494-499（`_kick`）；
  - :511-589（`_ask`：:545-551 有 `unclear` 的寫入錯誤、:554 `rethrow`、:571-572 drop、:579-582 外層 catch）；
  - :626-671（`_joinNetwork`）；
  - :687-716（`_watchLink`）；
  - :738-746（`_readRecord`）；
  - :1565-1582（`_sendUpdateFor`）。
- member_ui.dart:172（`forgettable`）、:231（`joinWait` 360 s）、:309（`unclearNow`）。
- owner.rs:
  - :105-121（`net_summary`、`creator`）；
  - :505-518（`join2_text`：`[JOINED] ` 在 :514、`Declined` 在 :518）；
  - :1132-1155（`persist_failed`）；
  - :1420-1440（`poll_link` / `send_update` 互斥）。
- netrec.rs:392-395（pending 成員為 `Joining`）。
- rekey.rs:430-457（`update_text`）。
- app_link.dart:135-144（`lib/src/nodelink/`）。
- key_abilities.dart:47、:96-131。
- node_link.dart:82、:146-148、:229。
- core.dart:280-292、:312、:642。
- lease.dart:73-83、:96-105。

### ⚠️ 推論
- AE-m1 的「`Broken` 可能發生在訊框已送出之後」：從 `updflow::End::Broken(w)` 的名稱與句子推論，沒有追 updflow.rs。
- AE-m3 的「多一次確認」：照 §2.5:129 的字面推論。
- AE-m4 的「管理者金鑰不符時登入仍成功」：依 `KeyUse.login` 不看 `ADMIN_SIGN`（key_abilities.dart:44-47），而 §2.1 只寫「即時讀 `KeyAbilities`」、沒寫看哪個 use。

### ❌ 沒做
- 沒跑測試、沒上真機。
- 沒讀 join2 全文、join2flow.rs、updflow.rs。
- 沒有重新核對 v1–v14 的發現。
- 沒有核對上層設計 329-app-uiux.md 的行號。
