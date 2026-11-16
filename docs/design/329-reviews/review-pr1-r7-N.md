# #329 PR 1 第 7 輪程式碼審查（審查者 N，獨立）— commit 02eeab3

範圍：`02eeab3`（父 `a0f3fbb`）`app/rust/batman-proto/src/swupd.rs` 的 `on_status` 三個 `screen()` 的 tech 字串 + `tests/swupd.rs` 新測試 `a13_status_unread_names_its_cause_and_nothing_else`。
一併讀了：`gate()`（swupd.rs:314-334）、`Reply`（:415-423）、`screen()/decorate()`（:673-691）、`start()`（:615-621）、`Button::Refresh => self.start()`（:755）、`tech()`（:1223-1228）、bridge `api/owner.rs:1602-1655`（Reply 的產生）、`api/swupdate.rs:149-184`（tech 直接轉給 Dart）、`lib/swupdate.dart:347-349`（「技術資訊」ExpansionTile 顯示 `a.tech`）、設計 `docs/design/254-app-update.md` D8（:113）。

## 會走到這兩個 screen() 的路徑（從實際使用推）

| 路徑 | 之前 tech | 之後 tech（實測） | 按鈕 / 重試次數 |
|---|---|---|---|
| 狀態 4 次都沒有 trust（真機 `{15:{stale:true}}`） | `""` | `status: no trust (stale)` | 不變：Refresh；1+TRIES(3) 次，間隔 2.5 s |
| 狀態回了但沒有 key 15（舊節點／別的格式） | `""` | `status: no trust (stale)` ← 標籤說 stale，但其實不是 | 同上 |
| E_RATE(12) 重試用完 | `""` | `status: code 12` | 不變：1.5 s 重試、共用 `status_tries` |
| 其他錯誤碼 | `""` | `status: code N`（u64，只有數字） | Refresh |
| `Reply::Lost`（逾時、斷線、送不出／簽不了） | `""` | `status: no answer` | Refresh |
| `Reply::NoLink` | `""` | 不變 `""`（T_NOT_BACK） | Refresh |
| dev build，先前 Gate::Open 設過 trust，再按 Refresh 後讀不到 | `測試信任:<fp>` | `status: no trust (stale);測試信任:<fp>` ← 兩句互相矛盾 | Refresh |
| field build | `""` | 同上表各列，沒有 trust 後綴（PROD_TRUST=None，trust 永遠是空的） | — |

`_` 分支現在只會接到 `Lost`（`Ok`／`Err`／`NoLink` 都已經有自己的分支，Reply 只有四種，swupd.rs:416-423），所以「no answer」沒有說錯。

## 發現

### BLOCKER
無。

### MAJOR
無。

### MINOR

**N-1. 「(stale)」是推出來的，不是讀到的；一般性的「沒有 trust」也會被標成 stale。**
- 情境：節點回的狀態沒有 key 15，或 key 15 沒有 `trust`／`trust` 不是文字（比如舊版節點、格式改過）。`gate()` 一律回 `Gate::Unread`（swupd.rs:316-318），所以技術行寫「no trust (stale)」，但節點根本沒有說 stale。這一行就是用來診斷的，這種情況會把人帶到錯的方向（去查 status cache，而不是查版本或格式）。
- 證據：探針 `probe_no_key15`（回 `{1:2}`，沒有 key 15）→ `PROBE no-k15: text=讀不到節點的狀態 — 請重新整理 tech="status: no trust (stale)"`。commit message 寫 "(the node's status cache was stale on every read)" 也是同樣的過度宣稱：程式從來沒有讀 `stale`。
- 修法（擇一）：(a) 改成 `status: no trust`；或 (b) 讓 Gate::Unread 帶一個 bool，表示 key 15 是否有 `stale: true`，有才加「(stale)」，並補一個「沒有 key 15」的測項。同時修正 commit message 的說法。

**N-2. dev build：Refresh 後讀不到，技術行會同時出現「no trust」和上一次的「測試信任」。**
- 情境：dev build 第一次讀狀態時 Gate::Open 把 `self.trust` 設好（swupd.rs:883）；`start()` 不清 `trust`（:615-621）；之後按 Refresh 又讀不到（stale）。`decorate()` 把舊的 trust 接在後面（:687-688）。
- 證據：探針 `probe_trust_carryover` → `tech="status: no trust (stale);測試信任:0123456789abcdef"`。trust 留著不清是既有行為（不是這個 commit 造成的），但這個 commit 讓矛盾第一次並排出現在同一行。field build 不受影響（`PROBE field: tech="status: no trust (stale)"`）。
- 修法：`start()` 裡加 `self.trust.clear()`（`blocked` 是否也要清請一起看，它同樣只在 Open／Closed 時才寫），再補一個 Refresh 後的測項。也可以只在 commit／PR 裡註明這是已知的 dev-only 行為。

**N-3. D8 的引用不準，格式也和其他畫面不一致。**
- 設計 D8（254-app-update.md:113）講的是秘密只經過 Dart，以及 Kotlin 呼叫和 debugPrint；它沒有規定「更新流程永遠不顯示回應內容」。同一份 swupd.rs 的 `tech()`（:1223-1228）會把 `detail[2]`（原因碼，一個 uint）顯示成「代碼 N,原因 r」，也被其他六個畫面使用（:1104/1139/1145/1166/1184/1216）。所以「detail 永不顯示（D8）」不是全流程都成立的事實，只有這個 commit 新加的分支是這樣。
- 另外，新字串用英文 `status: code N`，其他畫面用中文 `代碼 N,原因 r`，同一個「技術資訊」區塊出現兩種格式。
- 修法：把程式註解和 commit message 改成「這裡只顯示 kind 和 code，不碰 detail」，不要寫成 D8 的全域規則。格式可以考慮統一。不影響安全。

**N-4. 測試覆蓋還有缺口（不影響判定）。**
新測試蓋到 stale 用完、Err(9)、Lost 三種情況，但沒有蓋：E_RATE 重試用完後顯示 `code 12`；沒有 key 15；dev build Refresh 後的 trust 後綴；`detail` 是 Map、而且含 key 2 原因的情況（這種情況下 `tech()` 會顯示原因，比用 Text 更能區分實作有沒有誤用 `tech()`）。建議至少補 E_RATE 用完和 Map detail 兩項。探針結果附在下面。

**N-5. 流程提醒：負對照不能和正向測試共用同一個 CARGO_TARGET_DIR。**
我第一次用同一個 `$HOME/tgt-rev-b` 在 `git archive` 出來的父版本樹上跑負對照，結果 cargo 直接沿用了上一棵樹編好的 test binary：跑出「1 passed; 43 filtered out」，但父版本樹其實只有 40 個測試。這是一次假 PASS。原因：archive 出來的檔案 mtime 是舊的，路徑雜湊也沒有讓 cargo 重編。改用各自獨立的 target dir 後才得到真正的 FAIL。commit 宣稱「fails without the change」，如果作者也是這樣跑的，就要用獨立的 target dir 重跑確認。

### 安全
- 惡意節點（BLE）：新分支只用了 `code: u64`，用 `format!("{code}")` 輸出，只會是十進位數字；`detail` 被 `..` 丟掉。探針 `probe_err_map_detail`（code=u64::MAX、detail 是含 `"EVIL\nBODY"` 的 Map）→ `tech="status: code 18446744073709551615" contains_evil=false`。節點能控制的只有一個數字，無法注入文字或換行。
- stale 和 Lost 兩個分支是固定字串，節點的內容進不去。
- 本機非特權程序：這個 commit 沒有新增任何輸入、檔案或 log。tech 經過 bridge `swupdate.rs:179/184` 原樣交給 Dart，只顯示在 ExpansionTile（swupdate.dart:347-349），沒有新的 debugPrint 或 log。
- 我們自己的錯：見 N-1（誤導診斷）、N-2（dev 的矛盾行）。都只影響顯示，不影響更新閘門：`blocked`／`trust` 的判定邏輯沒有改。
- 測試確實證明了 detail 沒有顯示：`assert!(!format!("{a:?}").contains("SECRET-DETAIL"))` 檢查的是整個 Action 的 Debug 字串，而且還有 tech 的等值斷言，兩道檢查都有。

### 既有行為是否改變
- 按鈕：都還是 `[Refresh]`（diff 只改 tech 參數）。
- 重試：`STALE_RETRY_MS`／`STATUS_RATE_MS`／`TRIES` 和 `status_tries` 的邏輯沒動。
- NoLink 的畫面沒動，其他畫面也沒動。
- 有改變的只有一處：這三種情況下，「技術資訊」從原本不顯示（tech 是空的，Dart 也沒有 putCode）變成會顯示。

## 判定：APPROVE-WITH-CHANGES
沒有 BLOCKER 或 MAJOR。建議合併前處理 N-1（拿掉「(stale)」，或確實讀到 stale 才加），並修正 commit message 的說法；N-2 到 N-5 可以一起改，或寫進 #329 的 checklist。

## 結果分類

### ✅ 已驗證（原始輸出）
- 全套 `cargo test -q`（02eeab3 的副本，加上我的 4 個探針）：每個 test result 都是 `ok`、`0 failed`、`rc=0`；swupd 這組是 `44 passed`（40 個原有測試 + 4 個探針）。
- 負對照（父 a0f3fbb 的 swupd.rs 加上新的測試檔，獨立 target dir）：
  ```
  panicked at tests/swupd.rs:1325:5: assertion `left == right` failed
    left: ("讀不到節點的狀態 — 請重新整理", "")
   right: ("讀不到節點的狀態 — 請重新整理", "status: no trust (stale)")
  test result: FAILED. 0 passed; 1 failed; ... 39 filtered out   rc=101
  ```
- 探針輸出：
  ```
  PROBE no-k15: tech="status: no trust (stale)"
  PROBE rate: text=讀不到節點的狀態 — 請重新整理 tech="status: code 12"
  PROBE carry: tech="status: no trust (stale);測試信任:0123456789abcdef"
  PROBE field: tech="status: no trust (stale)"
  PROBE err-map: tech="status: code 18446744073709551615" contains_evil=false
  ```
- 假 PASS 的紀錄（N-5）：共用 target dir 時負對照跑出 `1 passed; 43 filtered out`，但那棵樹只有 40 個 `#[test]`（用 grep 數過）。

### ⚠️ 推論／未獨立驗證
- 真機上 02／04 每次都回 `{15:{stale:true}}`：這是 commit 作者的觀察，我沒有接觸真機。
- 「技術資訊」只在 ExpansionTile 顯示、沒有進 log：靠讀程式碼（swupdate.dart:347-349、bridge swupdate.rs:179/184）得出，沒有在手機上跑過，也沒有看 logcat。
- 父版本測試 FAIL 的原因：看起來是第一個斷言（stale）就失敗；Err／Lost 兩段在父版本也會失敗（父版本的 tech 都是空的），這是推論，因為斷言在第一處就停了。

### ❌ 未做
- 沒有在手機（S20）上看畫面。
- 沒有修改 worktree（照指示）。
- 沒有跑 Dart／Flutter 測試，也沒有跑 bridge crate 的測試（這個 commit 沒有碰到它們）。
