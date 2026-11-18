# 審查 J：`test/329-retest-a` 上非 BLE 的 lib 改動（663bb5e、c795d63）

範圍：
- `app_link.dart`：`recordsByWrite`
- `member.rs`：`invite_err` 的 Format 原因
- `home_page.dart`：HomePage 實作 `LeaseListener`，每次 lease 釋放都重算待辦
- `join_pages.dart`：8.5 的每一行先去掉 marker
- 對應的測試

Flutter 的負向對照在 scratch worktree `C:/src/Batman-329ra-rJm`（detached 67a1360，分支頭，含這兩個 commit）重跑，跑完已 `git worktree remove`（`git worktree list | grep -c rJ` → 0）。Rust 只讀程式碼，沒有跑 cargo。

**Verdict：APPROVE-WITH-CHANGES。** 三個 Flutter 修正都正確，負向對照我都重現了。有 1 個 MAJOR：同一類問題（畫面出現英文內部原因）在 8.5 的 `mupdate_text` 沒有一起修。其餘是 MINOR。

## 1. 重跑結果（✅ 原始輸出）

| 跑法 | 結果 |
|---|---|
| 67a1360 原樣：`retest_h_home_test` + `join_pages_test` + `record_mtime_test` | `00:04 +24: All tests passed!` |
| NC-H：註解掉 `home_page.dart` 的 `a.reg.listeners.add(this)` | `T-H3: the todos are computed again when a lease is released … [E]`，`+5 -1` ✅ |
| NC-8.5a：只把 already-imported 那行改回 `${prep.detail}` | `8.5 new key … already imported -> its Rust line without the marker [E]` ✅ |
| NC-8.5b：只把 `:642` 改回 `'${prep.detail}\n${st.detail}'` | `8.5 new key … no log marker on either Rust line … [E]` ✅ |
| NC-A23：`recordsByWrite` 一律回 5 | `T-L20 … [E]`、`A23 … [E]`，`+0 -2` ✅ |
| Rust `format_reasons_are_words`（只讀） | 斷言是：從 `qr_object(QR_INVITE 的碼, QR_JOINREQ)` 拿到的錯誤 → 新的中文句子；`["not hex","not a qr-object","approval keys","x"]` 每一個都以「這不是正確的碼」開頭，而且不含原本的英文字、`qr-object`、`hex`。如果把舊格式 `format!("這不是正確的碼（{w}）")` 放回去，`!t.contains(w)` 會失敗 ✅（推論；沒有跑 cargo） |

## 2. 介面與呼叫點

- **`LeaseRegistry.listeners`**（`lease.dart`）：
  - 由 `_release` 和 `_revoke` 用 `for (final x in listeners)` 依序呼叫。加入的順序是 BleGate（建構時）→ NodeLink → HomePage（`home_page.dart:118` initState 加入、`:136` dispose 移除）。
  - HomePage 的 `released` 只是啟動一個 async 的 `_todos()`：同步部分只讀 `widget.devTrust`，`listPending` 在 `try` 裡面。所以不會同步丟出例外、也不會在迴圈中途改動 `listeners`，不會讓排在後面的 listener 被跳過。✅
  - `revoked` 是空的。被收回的 lease 之後一定會跑 `_release`（`lease.dart` 的 `_revoke` → `_release`），所以重算一定會發生。✅
- **`_todos()` 的呼叫點**：initState `:120`、`released` `:129`、`_back` `:183`、`_addNode` `:245`。全部都以 `if (mounted)` 保護 setState。✅
- **`recordsByWrite`** 唯一的呼叫點是 `AppLink.readRecords`（app_link.dart）。行為和原本 inline 的版本完全相同，只是搬出來讓測試可以呼叫。✅
- **`invite_err`** 的呼叫點：
  - `member.rs:71`（8.1 貼邀請，期待 `QR_INVITE`）
  - `:94-95`（收申請，期待 `QR_JOINREQ`）
  - `:153`、`:226`、`:253`、`:291`（8.4 匯入同意，期待 `QR_APPROVAL`）
  - `:302`
  - `owner.rs:1333`

  所以「another kind of qr-object」至少會從三種頁面出現。見 m-1。

## 3. 協調者指定要想的情境

**a. lease 釋放時首頁不在最上層（上面還疊著別的頁）。**
- 這種情況正好就是原本的 bug：認領頁已經關了，但認領工作還在 raw lease 底下跑完，釋放時使用者可能已經在別頁。
- 那時重算的效果：`setState` 只改 `_pending`，首頁在 Navigator 底下照常 rebuild，不會顯示任何東西，也不會影響上面那頁。之後 `_back` 回到首頁時還會再算一次。所以**結果正確而且無害**。✅
- 另一種情況：下一個 lease（例如再一次認領）正在跑，而且已經寫了 claim-pending。這時首頁會先把「上次新增節點沒有做完」算進去，但它被蓋在底下看不到；認領結束後 `_addNode` `:245` 會再算一次。✅
- 這條路徑沒有測試。現有的 T-H3 只在首頁位於最上層時釋放。見 m-3。

**b. listener 執行中 `listPending` 丟出例外。**
- 例外被 `catch (_) {}` 吃掉，`n = 0` → **待辦會消失**。這是 fail-open：一個讀檔錯誤就把提醒藏起來。
- 修改前（換頁時重算）也是一樣的行為；現在重算的時機更多，觸發的機會也跟著變多。
- 依「失敗就回到之前的狀態」的原則，例外時應該保留原本的 `_pending`，不要設成 0。見 m-2。

**c. 和 NodeLink 的先後順序。**
- `n = pending 裡、core 還不認得的 id`。NodeLink 的 `released` 也會非同步地重讀紀錄（`node_link.dart:436` `readRecords().then(...)`），讀完才更新 `_recs` / core。
- 一般的認領流程是 `records.claimed`：先寫 node 紀錄、再刪 pending（`claim.dart:443`），之後才釋放 lease。所以釋放時 pending 已經不在，不受影響。✅
- 只有「pending 刪不掉」（`PendingNotRemoved`，`claim.dart:445`）時，兩個非同步工作誰先完成不一定：首頁可能先算完、core 還不認得新的 id，於是顯示一個其實已完成的「沒有做完」。要等下一次換頁才會消失。很少見，見 m-4。

**d. 中文的 Format 句子能不能讓使用者分清楚「貼錯頁」和「碼壞了」。**
- 可以：
  - `another kind of qr-object` → 「這是另一種碼…」（貼錯頁）
  - `not hex`、`not a qr-object` → 「內容不完整或不是 App 產生的碼，請重新複製」（碼壞了）

  兩者分得開。✅
- 但例子寫死成「例如把邀請碼貼到了收申請」。在 8.1（把同意碼貼到加入頁）和 8.4（把邀請碼貼到匯入同意）也會出現同一句，舉的例子不對。見 m-1。

**e. batman-proto 的 `Error::Format(` 全部列出來**（`grep -rn 'Error::Format(' app/rust/batman-proto/src`）：

| 原因 | 位置 | 新的句子 |
|---|---|---|
| `not hex` | invite.rs:79、81 | 內容不完整… ✅ |
| `not a qr-object` | invite.rs:91、92、96 | 內容不完整… ✅ |
| `another kind of qr-object` | invite.rs:94 | 另一種碼… ✅ |
| `not an approval`、`approval keys`、`approval item is not a COSE_Sign1`、`approval secrets` | approve.rs:313、314、317、326 | 只有「這不是正確的碼」，沒有英文 ✅，但也沒有下一步（m-5） |

另外，**mupdate 有自己的 `Refusal::Format`**（mupdate.rs:78–116，共 13 種原因：`not an update`、`too large`、`steps` 等），在 bridge 的 `rekey.rs:342` 是 `R::Format(w) => format!("這不是正確的更新包（{w}）")`，**仍然把英文放到畫面上**。見 M-1。

## MAJOR

**M-1 同一類問題（畫面出現英文的內部原因）在 8.5 沒有一起修。**
- 情境：隊員把邀請碼或同意碼貼進 8.5「匯入新密碼」。`mupdate.rs:93` 把 `qr_object(hex, QR_UPDATE)` 的任何錯誤都壓成 `Refusal::Format("not an update")`，畫面顯示「這不是正確的更新包（not an update）」。截斷的包也一樣（`not deterministic CBOR`、`too large`、`steps`）。
- 這正是 663bb5e 要修的症狀（真機上看到 `another kind of qr-object`），只是換了一頁。而且因為所有錯誤都被壓成同一個原因，連「貼錯頁」和「碼壞了」都分不出來。
- 證據：`app/rust/bridge/src/api/rekey.rs:339-342`；`app/rust/batman-proto/src/mupdate.rs:93`。
- 修：
  - `mupdate_text` 比照 `invite_err`：原因一律不顯示，句子是「這不是正確的更新包」。
  - `mupdate.rs:93` 不要把 `qr_object` 的錯誤全部壓掉，至少保留「另一種碼」這個情況，讓畫面能說「這是另一種碼（不是更新包）」。
  - 加一個測試，比照 `format_reasons_are_words`。
  - 依「一類東西一次掃完」的規則，也要列出 `Error::Invalid(w)` / `R::Invalid(w)`（`member.rs:35`「內容驗證沒有通過（{w}）」、`rekey.rs:347`）：它們同樣把英文原因放到畫面上。要嘛一起改，要嘛寫進 #329 清單。

## MINOR

- **m-1** 「另一種碼」的例子寫死成「把邀請碼貼到了收申請」，但同一句也會出現在 8.1 和 8.4。改成不提頁名的通用句（例如「這是另一種碼：邀請碼、申請碼、同意碼不能互換，請確認貼在對的頁面」），或由 Dart 依所在頁面自己組句子。測試裡寫死的字串要跟著改。
- **m-2** `_todos` 在 `listPending` 丟例外時把 `_pending` 設成 0，等於把待辦藏起來。改成例外時保留原值，加一個測試：假 rust 的 `listPending` 丟例外 → 原本的待辦仍然在。
- **m-3** 沒有「釋放時首頁被別頁蓋住」的測試。補一個：push 一頁 → 釋放 → pop → 待辦已經是新的，而且被蓋住的期間沒有例外。
- **m-4** 「pending 刪不掉」的路徑和 NodeLink 重讀紀錄之間有先後的競態。可以讓 `_todos` 等 NodeLink 的 `_releasing` 完成（例如 AppLink 提供一個 `Future`），或在 `link.changed` 時也重算一次（首頁已經在聽 `changed`，見 `:111`）。很少見，寫進清單也可以。
- **m-5** approval 系列的 4 種 Format 原因只顯示「這不是正確的碼」，沒有告訴使用者下一步。這種碼的外層格式對、內容不對，比較可能是版本不合或碼被改過，建議加上「請隊長重新產生同意碼」。
- **m-6** `recordsByWrite` 依手機的檔案時間排序。如果手機時間被往回調，順序會錯，但影響只是讀取的優先順序（§4.3.3-6），不會顯示錯的東西。可接受，在 A23 註明一句即可。

## 安全（各 actor）

- **惡意或被竄改的碼（貼進 app）**：新的句子不帶任何來自輸入的內容，原因字串都是常數；8.5 現在也不再回顯 Rust 的 marker。✅ M-1 那邊目前顯示的 `{w}` 也是常數，沒有注入風險，只是 UX 問題。
- **本機其他程序**：`recordsByWrite` 只讀 app 私有目錄裡的 `node/<id>` 檔案時間；id 來自 Rust `listNodes` 的檔名，不需要處理路徑穿越。✅
- **log**：8.5 拿掉 marker 只影響畫面字串；這頁不會把 `_line` 寫進 logcat，repo 裡也沒有腳本 grep `[UPDATE]`（我 grep 過 .sh / .py / .dart）。✅

## 生命週期（HomePage listener）

| 路徑 | 行為 |
|---|---|
| 首頁建立 / 銷毀 | initState 加入、dispose 移除 ✅ |
| 首頁被蓋住時釋放 | 重算，無害（見 §3a；沒有測試，m-3） |
| lease 被收回 | `_revoke` → `_release` → 重算 ✅ |
| `listPending` 失敗 | 待辦消失（m-2） |
| app 進背景再回來 | listener 不變；有釋放就會重算 ✅ |
| 熱重啟 / 兩個 HomePage 並存 | 各自重算，無害 |
