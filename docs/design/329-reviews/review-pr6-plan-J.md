# #329 PR 6 計畫 v5 — 第五輪獨立審查（J）

審查對象：`docs/design/329-pr6-plan.md` v5（整份），基準 main c4905ed。只讀原始碼核對；沒有上機。

## 前幾輪 MAJOR 是否解掉

| 前輪 | 狀態 | 說明 |
|---|---|---|
| G-M1 接句吞主句 | ✅ | 成對 U+001E…U+001F：`format!("{a}；{b}")` 後每段仍成對，主句不會被吞；T-C4c 五處接句各一條測試、負向對照「第一個控制字元之後都是技術」。 |
| G-M2 / H-M1 舊 team 當新鮮 | ⚠️ 意圖對，**寫法做不出來** | `readAt` 必須等於 `core.states[id].readAt`，但 `onTeam` 在 prober 裡、`core.result` 之前呼叫，那時這個值還不存在 → 本輪 MAJOR-1。 |
| H-M2 偏離 254 / 舊程式 | ⚠️ | D5(b)(e) 已改（先 `recordPlain: null`、入口不要求 netId），但 T6-13(c) 仍寫「netId 不空」→ MINOR-2；D5(b) 2 s 逾時兩種說法 → MINOR-1。 |
| H-M3 R-7 起點 | ✅ | 第 0 步唯讀確認 + 條件式「02 離開」+ 隊員入口 + 套件 / 簽章核對。 |
| A–F 各 MAJOR | ✅ | 抽查 D2（node.go:752、:839-873 整組取代與移除語意屬實）、D11（join2flow.rs:481-485 Revert 送 `prev_country`；joinflow.rs:18 `COUNTRY = "US"`；`setCountry` 只剩 settings_pages.dart:318 與 nodes.dart:1695 兩個呼叫者）、D4a（net_index.dart:213-221 `mine.contains` 過濾屬實）、F1 / D1（main.dart:313-316 入口無 dev 閘門、`_devTrust` 在 main.dart:104-105 已可用）。 |

## BLOCKER

無。

## MAJOR

### MAJOR-1　team 的 `readAt` 依計畫寫法無法等於狀態的 `readAt`：要嘛整段永遠是舊資料樣式，要嘛實作者自己編一個值讓比對失去意義；而且現有測試抓不到「永遠舊」

**情境**：D5(b)(c) 要 `SessionProber._afterRead` 經 `TeamSink.onTeam(id, netId, view, readAt)` 寫 `NodeLink.teams[id]`，`readAt` =「和 `core.states[id].readAt` 同一個值」。

**證據**：
- prober 的計算在 `done(o)` **之前**（prober.dart:158-166：`await Future.any([_hint(...)…])` 之後才 `done(o)`），而 `core.states[id].readAt` 是在 prober 回傳、`NodeLink._run` 關掉連線之後的 `core.result(now(), a, o)` → `_read(s, now, …)` 才寫（node_link.dart:577-582、core.dart:487-489）。`onTeam` 被呼叫時，那次讀取的 `readAt` 還不存在；prober 也沒有注入的時鐘。
- `core.result` 還會丟掉被取消那一輪的晚到結果（core.dart:428 `if (r == null || !identical(r.running, a)) return;`），`_run` 在 `_abort` 後也提早 return（node_link.dart:579）——這兩種情況 prober 已經呼叫過 `onTeam`。
- 結果：照字面實作（prober 自己蓋時間）→ 永遠 `!=` → TeamPage 每段永遠 unk；或實作者改成「收到時抄 `core.states[id].readAt`」→ 抄到的是**上一次**讀取的值，和狀態相等，延遲 / cancel 那一輪的舊 team 會被當新鮮（正是 G-M2 / H-M1 要擋的）。
- T6-13(d) 的負向對照只測「延遲 / cancel 時那一段不是綠的」；「永遠 unk」的實作也通過。沒有正向對照（正常讀完一輪 → 那段新鮮、照 Rust 卡片顯示）。

**修法**：team 跟著讀取結果走，不另開寫入時機。例：`Outcome.extra` 帶 `(StatusView, TeamView?)`（或在 `Outcome` 加 `team` 欄位）；`NodeLink._run` 在 `core.result(now(), a, o)` 之後、只在 `o.res == Res.body` 且 `core.states[a.id].readAt` 這次被設定時寫 `teams[a.id] = (netId, view, core.states[a.id].readAt)`。這樣「唯一寫者」= `_run`；cancel / abort / 晚到 / T17 移除都自然不寫（`_run` 已經處理）；2' 改了 `readAt` 但沒有 team → 自然變舊。§4 擁有者表改寫。T6-13(d) 加正向對照：注入時鐘，正常一輪 → 那段新鮮（綠）；再加「`_abort` 後晚到的 body 不寫 team」。

## MINOR

1. **D5(b) 逾時兩種說法互相矛盾**：同一段先寫「超過 2 s → 這一輪不更新 team（保留舊值）」，後面又寫「紀錄打不開或超過 2 s 時得到的是『沒有名單』版本，不是舊值」；T6-13(a) 照後者。刪掉前一句（配 MAJOR-1：到期時手上的就是 `recordPlain: null` 版本）。
2. **T6-13(c) 與 D5(e) 不一致**：測試寫「有 visible 且 netId 不空 →『看全隊狀態』」，D5(e)（H-M2 的修法）是不要求 netId。照測試實作就把 H-M2 改回去。改測試，負向對照加「netId 空（NoNet 段）且 visible → 入口仍在」。
3. **段標題重複「看到」**：Rust title 已是 `全隊（僅供參考；由『{title_name}』看到）`（teamview.rs:298），D5(f) 又加一行「從 <暱稱或節點 XXXX> 看到」。二擇一（Rust 的名稱來自節點，Dart 的是手機暱稱；若要手機暱稱，就只改 Dart 那行、title 原樣，並寫明兩者可能不同）。另 D5(d) 末句重複一次，刪。
4. **節點送來的國家字串沒經 `display_name`，而 U+001E 現在有意義**：`country_of(b)`（join2flow.rs:631）原樣進 `country_question`（owner.rs:517）、`Declined`（:540）、`國家已改回 {country}`（:569）、`原本是 {p}`（:170），`prev_country` 也存進紀錄後再回到句子。被入侵的節點可以在國家值放 U+001E，和後面合法的 U+001F 配成一段，把中間的主句藏起來。修：國家值在 Rust 取出時經 `display_name`（只影響畫面，不影響送回節點的 `prev_country`——或兩者都限制為 `[A-Z]{2}`，國家碼本來就是兩個大寫字母）；`splitCode` 規定「開始之後、結束之前又遇到開始」= 不成對；加一條 Rust 測試（節點國家含 U+001E/U+001F → 句子主句完整）。
5. **D4a 孤兒清單要 fail-closed**：`NetIndex` 現在 `nodeIds()` 失敗時 `mine` 不會建立、`todos` 空（net_index.dart:213-224 的 catch）。若 `orphanJoins` 寫在同一處但以 `mine = {}` 計算，`nodeIds()` 失敗 → **所有** joining 成員都變成孤兒，使用者可能把手機上還有節點紀錄的加入項目忘掉。寫明「節點清單讀不到 → `orphanJoins` 空」，T6-14 加這條負向對照。
6. **dev3 的 flavor 要寫明 `DEV_TRUST = true`**：SSH 頁、查看節點設定都是 devTrust（main.dart:104-105 由 flavor 決定；build.gradle.kts:57-76 只有 dev / dev2 / field）。第 0、1 步依賴它；套件名 / 簽章核對之外加「BuildConfig.DEV_TRUST 與已裝的 dev3 相同」。
7. **R-7 第 5 步的備案改了結束狀態**：若 join2 不讓 04（建網時的第一台、`creator`）加回、改建新網路，第 6 步 02 加入的是新網路，結束狀態「04 = dev 的網路（第 4 步後的新密碼）」不再成立，第 4 步的新密碼也作廢。把備案的結束狀態與第 6 步目標寫進副作用表（開場一次同意的那張）。第 0 步順便唯讀查 join2flow 對 creator 成員重新加入的前提（「替換同一台的舊條目」是否含 creator），先知道會不會走備案。
8. **R-7 第 2 步改 04 的 AP 名稱**：若電腦到 04 的 link-local（`%15`）走的是 04 的 AP，改名期間 SSH 重開（第 2 步的「節點重開」中斷）會斷。第 0 步確認 `%15` 是哪個介面；是 04 的 AP 就把第 2 步的節點重開改成拔電或註明略過。
9. **對話框與 `goneNote` 會丟掉技術段**：`plain(q)` 進對話框（net_pages.dart:720-722）、`goneNote(screenText(s))`（claim.dart:185）只留主句，技術段沒有地方看。寫明：對話框內容用 `SayLine`（有展開列），或這幾處接受只留主句並列在 PR；`goneNote` 改傳原句、在首頁顯示時再切。
10. **文字紀錄頁的 `mask` 會把 8 位以上的十進位數也遮掉**（node_link.dart:78-79 `[0-9a-fA-F]{8,}`）：例如毫秒數。不是安全問題；T6-12 的期望字串照這個寫，或文字紀錄頁說明「長數字也會被遮」。
11. **D2 的指紋解不開 → 不合格比節點嚴**：節點 regex 允許 `=` 出現在中間（node.go:752），嚴格 base64 解碼會拒絕；這是保守方向，可以接受，但 T6-3 的「不合格」清單加一條「節點會收、app 拒絕」的例子並在頁面說明原因（避免實機時以為是 bug）。

## 安全（逐 actor）

- **遠端 / 被入侵的節點**：全隊每台一段 ✅；節點字串經 `shown` / `display_name`（settings_text D3、`error_text {v}`）✅；國家字串缺口 → MINOR-4。被入侵的節點能讓自己那段停在「沒有名單」或舊值，但只影響自己那段（修 MAJOR-1 後舊值必為 unk）。
- **本機無特權 app**：新頁不新增 IPC / 檔案；複製到剪貼簿是使用者動作（診斷白名單、文字紀錄經 `mask`）✅。剪貼簿換 SSH 金鑰 → 送出前顯示指紋 ✅。
- **實體奪取**：SSH 頁只在 devTrust 版、要擁有者金鑰；field 版刪掉舊啟動頁的無閘門入口，攻擊面縮小 ✅。
- **自己的錯**：MAJOR-1（兩個各自正確的元件——prober 與 core——對「讀取時間」的假設互相矛盾）；MINOR-5（失敗時變成「全部是孤兒」）。
- **秘密**：設定白名單無 AP 密碼；team 不進紀錄（T-A9 移植）✅。
- **fail-secure**：國家 `{'US'}` fail-closed ✅；`splitCode` 不成對 → 全顯示（fail-visible，合理）✅。

## 計數與判定

BLOCKER 0 / MAJOR 1 / MINOR 11

**APPROVE-WITH-CHANGES**。前幾輪 MAJOR 除了 G-M2 / H-M1 的實作方式外都已解掉。MAJOR-1 的修法很小（team 跟著 `Outcome` 走、在 `_run` 的 `core.result` 之後蓋 `readAt`，加一條正向對照），修完不需要再整份重審，只核對 D5(b)(c)、§4 那一列與 T6-13。
