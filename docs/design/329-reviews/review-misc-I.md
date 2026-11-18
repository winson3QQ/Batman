# 審查 I：`test/329-retest-a` 上與 BLE 無關的 lib 改動（663bb5e、c795d63）

唯讀審查。負向對照是我在臨時 worktree `C:/src/Batman-329ra-rI`（detached 在 67a1360，已包含這兩個 commit）自己重跑的，跑完已移除：`git worktree list | grep -c rI` 回 0。Rust 的 `format_reasons_are_words` 照指示沒有跑，只讀了程式碼。

**判定：APPROVE。** 沒有 BLOCKER，也沒有 MAJOR，只有 5 個 MINOR。

## 負向對照（✅ 都有原始輸出）

| 情況 | 結果 |
|---|---|
| 基線：三個測試檔 | `+24: All tests passed!` |
| N1：拿掉 `a.reg.listeners.add(this)` | `T-H3: the todos are computed again when a lease is released … [E]` → FAIL ✅ |
| N2：拿掉 `dispose` 裡的 `a.reg.listeners.remove(this)`，跑全套 | `+1712: All tests passed!` → **沒有任何測試守住**（m1） |
| N3a：642 行換回舊寫法 `'${prep.detail}\n${st.detail}'` | `no log marker on either Rust line … [E]` → FAIL ✅ |
| N3b：629 行換回 `${prep.detail}` | `already imported -> its Rust line without the marker [E]` → FAIL ✅ |
| N4：`recordsByWrite` 改成回傳固定時間 | 兩個測試（T-L20、A23）都 `[E]` → FAIL ✅（和 commit message 說的一致） |

## 問題 1：首頁的 listener 會不會漏掉沒移除？

- 註冊在 `home_page.dart:118`（initState），移除在 `:137`（dispose 的第一行）。正常情況下不會漏。
- `HomePage` 只在 `main.dart:180` 建立，每次執行只用 `pushReplacement` 建一個實例，所以 listener 只會被加一次，不會因為頁面重複建立而越積越多。
- `LeaseRegistry._release` 和 `_revoke` 用 `for (final x in listeners)` 逐一通知（`lease.dart` 約 142-157 行）。`released()` 只同步呼叫一次 `_todos()`，同步部分只讀 `widget.devTrust`，接著就 `await listPending`，所以通知過程中不會改到 listener 清單，不會出現 ConcurrentModificationError。
- dispose 不會在 listener 的回呼裡同步發生（Navigator 的 pop 不會同步觸發 dispose）。
- 如果某個頁面的 dispose 觸發了釋放，而那時首頁正在被拆掉：`_todos` 在 await 之後會先檢查 `mounted` 才 `setState`（`:177`），不會出錯。
- 很多次釋放：每次釋放做一次 `listPending`，就是列一個目錄，便宜；而且只有 devTrust 版才做，正式版只是 `setState`。不是熱路徑。
- **但是**，移除那一行沒有任何測試（上表 N2）。見 m1。

## 問題 2：釋放時重算待辦，會不會和頁面自己處理的待辦互相干擾，或讓錯的待辦閃一下？

先說正常路徑：
- 認領完成時 `claimed()` 的順序是先寫節點紀錄、再刪 pending（`claim_records.dart:88-92`），都在佔用之下完成。之後才釋放佔用，首頁那時才讀 pending。所以不會出現錯的「上次新增節點沒有做完」。
- 認領沒做完、pending 還在、也沒有紀錄：這時顯示待辦是對的。
- 被撤回的佔用：`_revoke` 會先通知 `revoked` 再走 `_release`，所以首頁的 `setState` 也會刷新 `reg.unsavedTodos`（`:272` 一帶）。✅

**會閃的那一種情況**（m2）：
- 刪 pending 失敗時，會拋 `PendingNotRemoved`（`claim_records.dart:91`），此時節點紀錄已經寫好，pending 也還在。
- 首頁算待辦時用 `!a.link.core.states.containsKey(id)` 把「已有紀錄的」排除。可是 `core.states` 要等 NodeLink 在釋放後重新讀紀錄（`node_link.dart` 的 `released`，非同步）才會更新。
- 首頁的 `listPending` 和 NodeLink 的 `readRecords` 誰先完成不一定。如果首頁先完成，那台節點會被算進「沒做完」。
- 之後 `a.link.changed` 只會 `setState`（`:111-114`），不會再呼叫 `_todos`。所以錯的待辦會一直留著，直到下一次換頁觸發 `_back`。
- 這種情況很少見，而且是修改前就存在的，但這次的修改讓它在釋放的那一刻更容易遇到。

## 問題 3：還有其他地方把帶標記的 Rust 行接起來嗎？

我搜了 `lib/ui` 和 `lib/src/flows` 裡所有換行串接、`.join(`、`.detail` 的用法，結論：**沒有。**
- 換行串接只有 `join_pages.dart:642`（已修）和 `:493`（`'結果不明\n$kNeedNewInvite'`，兩段都是常數）。
- `.join('\n')`：
  - `more_pages.dart:162` 是技術資訊，本來就顯示原文；
  - `team_pages.dart:137`、`node_page.dart:184` 是 StatusView 的欄位或自組的句子，不是帶標記的 Rust 步驟行。
- 只有一行 Rust 文字的地方，都由顯示端或 `offlineLine`、`opLine` 套 `screenText`：`join_pages.dart:186/328/524/751`、`team_pages.dart:28`、`settings_pages.dart:44-45`。
- `join_pages.dart:392` 對話框直接顯示 `prep.detail`。這是 `ImportState.replace` 的那一行，Rust 原文本身沒有標記（`member.rs:260`），沒有問題。
- Rust 端沒有任何字串是在 `\n` 後面接標記的（grep `\n[A-Z_]` 沒有結果）。所以 `screenText` 只剝開頭這個做法，對單行是夠的。

## 問題 4：`recordsByWrite` 和它取代的內嵌程式碼行為一樣嗎？

一樣。迴圈的內容、`lastModifiedSync`、讀取失敗時當成 0，逐字相同。差別只有：原本是在 `async` 函式裡 await `listNodes` 之後直接做，現在是 await 之後呼叫一個同步函式。順序和例外處理都沒變（`app_link.dart:40-49`、`:143`）。

`@visibleForTesting` 標在一個同一個 library 裡、正式程式也會呼叫的函式上，analyzer 不會警告，可以接受。

## Rust：`invite_err` 的 Format 原因改成中文（只讀）

- `match *w` 對應 `&'static str`（`invite.rs:34`），已知的三種原因有中文，其他原因只顯示「這不是正確的碼」，不再顯示內部英文字。✅
- 測試確實會在舊寫法（`format!("…（{w}）")`）下失敗：斷言要求不含 `w`、`qr-object`、`hex`。✅

## MINOR

- **m1. `dispose` 裡移除 listener 那一行沒有測試**（N2：拿掉之後全套照過）。目前每次執行只有一個 HomePage，漏掉的實際影響小。但它是這次新加的資源，按規則要有測試守住。建議加一個 widget 測試：把首頁換掉之後，斷言 `a.reg.listeners` 裡沒有 `_HomePageState`，或之後再釋放一次不會出錯。
- **m2. 釋放時的重算可能和 NodeLink 重讀紀錄互相競爭**（只在刪 pending 失敗時，見問題 2）。建議二擇一：
  - 在 `a.link.changed` 的回呼裡，如果 `core.states` 的鍵集合變了，就再呼叫一次 `_todos()`；
  - 或在 `released` 裡等 NodeLink 讀完紀錄（例如提供一個 `link.recordsReady` future）之後再算。
- **m3. 「另一種碼」那句的舉例只對一個入口是對的。** `"another kind of qr-object"` 固定顯示「例如把邀請碼貼到了收申請」。可是 `qr_object` 有好幾個入口：
  - `member.rs:71`：預期邀請碼，例如貼進來的是申請碼；
  - `:94`：預期申請碼，這個入口的舉例是對的；
  - `:226` / `:253`（`approve::approval_net_id` / `prepare_import`，`approve.rs:313` 的 `qr_object(hex, QR_APPROVAL)`）：預期同意碼。

  在其他入口，這個舉例會告訴使用者相反的事。建議改成中性的說法，例如「這是另一種碼（例如邀請碼、申請碼、同意碼貼錯了地方）」，或讓呼叫的地方各自帶上適合的提示。
- **m4. 同一個函式裡的 `Error::Invalid(w)` 還是會把英文內部字顯示出來**：`內容驗證沒有通過（{w}）`，`w` 是 `"signature"`、`"netcfg keys"`、`"admin_pub is not one of the network's admins"` 等（`invite.rs:68-164`）。這和這次修的是同一類「手機上出現英文」的問題。不在這個 commit 的範圍內，但建議寫進 #329 清單。
- **m5.** `format_reasons_are_words` 的 `assert_eq!` 寫死了完整句子。如果照 m3 改說法，要同步改這個斷言。

## 安全
- 新的 listener 只會觸發「讀 pending 目錄的檔名」，不會開任何紀錄，log 也沒有新增內容。✅
- `screenText` 只影響畫面上的字。log 本來就保留標記給腳本 grep，沒有變。✅
- 新的 Format 句子不帶任何輸入內容，比原本把 `{w}` 帶進來更不會洩漏東西。✅

## 驗證分類
- ✅ 有原始輸出：上面的負向對照表；listener 的註冊和移除位置；`claimed()` 的順序；各處 `screenText` 的覆蓋情況（grep）。
- ⚠️ 推論：m2 的競爭（`listPending` 和 `readRecords` 誰先完成）沒有寫測試重現；m3 是讀程式看出來的入口。
- ❌ 沒做：沒跑 Rust 測試（需要 WSL cargo，照指示略過），沒上機。
