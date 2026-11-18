# 審查 J（第二輪）：663bb5e + c795d63 + b362f75（非 BLE 的修正）

範圍：三個 commit 的 lib / Rust 改動與測試，整份重看。負向對照的跑法：
- Flutter：在 scratch worktree `C:/src/Batman-329ra-rJn`（detached b362f75）跑。
- Rust：在**同一個 scratch worktree** 改檔，再用 WSL 的 cargo 跑。target 放在 `$HOME/tgt-rJn`，跑完已刪（654M）。
- 基線：協調者的 `rtestB.sh` 在 `C:/src/Batman-329ra` 上跑。那個 worktree 沒有被改動，`git status` 是乾淨的。
- worktree 已 `git worktree remove`（`git worktree list | grep -c rJ` → 0）。

**Verdict：APPROVE。** 我上一輪的 M-1、m-1、m-2、m-5 都修了，負向對照都重現，只剩下面 1 個 MINOR。兩項延後（`Error::Invalid` 的英文、PendingNotRemoved 的競態）我**同意**寫進 #329 清單，理由在 §3。

## 1. 重跑結果（✅ 原始輸出）

| 跑法 | 結果 |
|---|---|
| `rtestB.sh`（C:/src/Batman-329ra @ b362f75） | `== batman-proto passed 272 failed 0`、`== bridge passed 74 failed 0` |
| Flutter 原樣：`retest_h_home_test` + `join_pages_test` + `record_mtime_test` | `00:04 +26: All tests passed!` |
| NC-m2：`home_page.dart` 的 `return;`（catch 裡）註解掉 | `review misc J m-2: the pending list unreadable at a release keeps the todo shown … [E]` ✅ |
| NC-I-m1：`dispose` 裡的 `a.reg.listeners.remove(this)` 註解掉 | `review misc I m1: the home page removes its lease listener when it goes away [E]` ✅ |
| NC1（Rust）：mupdate 又把所有錯誤壓成同一個（拿掉 `another kind` 那個分支） | `update_format_reasons_are_words --- FAILED … panicked at src/api/rekey.rs:609:9` ✅ |
| NC2（Rust）：`mupdate_text` 改回 `format!("這不是正確的更新包（{w}）")` | `update_format_reasons_are_words --- FAILED … rekey.rs:605:9` ✅ |
| NC3（Rust，我加的）：`invite_err` 拿掉 approval 那個分支（m-5 的下一步） | `format_reasons_are_words` **仍然 `2 passed`** ❌，見 m-a |
| 第一輪的 NC（T-H3 listener、8.5 兩處 `screenText`、A23 常數） | b362f75 沒有動到那些程式，第一輪已在 67a1360 重現（`review-misc-J.md` §1） |

## 2. 第一輪各條的核對

| 第一輪 | b362f75 | 結果 |
|---|---|---|
| M-1：8.5 顯示英文原因、貼錯頁和碼壞了分不出來 | `mupdate.rs:93-97` 保留 `another kind of qr-object`，其餘照舊是 `not an update`；`rekey.rs:342-347` 的對應：另一種碼 → 「這不是更新包（這是另一種碼…貼錯了地方）」，`too large` → 「不是 App 產生的更新包（太大）」，其他 → 「內容不完整或已損壞，請隊長重新產生你的更新包」 | ✅ NC1、NC2 證明。`mupdate.rs` 的 13 種 Format 原因都會落到其中一句，畫面不會出現英文 |
| m-1：「另一種碼」的例子只寫了一頁 | `member.rs` 改成「邀請碼、申請碼或同意碼貼錯了地方」，三個入口都適用；8.5 也用同樣的說法 | ✅ |
| m-2：`listPending` 例外會把待辦藏起來 | catch 裡直接 `return`，保留原值 | ✅ NC-m2 證明。`return` 同時跳過 setState；`_back` 和 `_addNode` 呼叫完 `_todos()` 後自己會 setState，所以沒有漏掉 rebuild |
| m-5：approval 系列沒有下一步 | `w.starts_with("approval") \|\| w == "not an approval"` → 「這不是正確的同意碼（內容不完整或已損壞），請隊長重新產生同意碼」。`approve.rs` 的 4 種原因（`not an approval`、`approval keys`、`approval item is not a COSE_Sign1`、`approval secrets`）全部對上 | ✅ 行為正確；但沒有測試守著，見 m-a |
| m-3：首頁被蓋住時釋放沒有測試 | 沒有補，但 I m1 補了「離開時移除 listener」的測試 | ⚠️ 可接受：被蓋住時重算只是改 `_pending` 再 rebuild，第一輪已經從程式推論過無害 |
| m-4：PendingNotRemoved 的競態 | 延後 | 同意，見 §3 |
| m-6：手機時間往回調會影響 A23 排序 | 沒有動 | 可接受 |

## 3. 兩項延後，我同意

- **`Error::Invalid(w)` / `R::Invalid(w)` 的英文。** 只有在簽章或內容驗證失敗時才會出現：碼的格式正確，但是驗證不過，代表被竄改或版本不合。這不像「貼錯頁」那樣是常見的操作錯誤，而且句子前半「內容驗證沒有通過」已經是中文，看得懂下一步。依「只做必要修改」，寫進 #329 清單可以接受。
- **PendingNotRemoved 的競態。** 這是既有問題，只在 pending 檔刪不掉的少見情況發生，後果是一個多餘的提醒，換頁後就會消失。寫進清單可以接受。

請確認這兩條**真的寫進 #329 的 checklist**（commit 寫的是「to #329」）。這次我沒有去查 issue 本文。

## 4. 安全與介面

- 新的句子都是常數，不帶任何來自輸入的內容。`mupdate.rs` 的對應是用字串常數做 pattern match（`crate::invite::Error::Format("another kind of qr-object")`），沒有新的輸入。✅
- 新的 `Refusal::Format("another kind of qr-object")` 只有 bridge 的 `mupdate_text` 讀到。proto 裡沒有其他地方比對 `"not an update"`（我 grep 過 `app/rust`），proto 的 272 個測試照樣全過。✅
- 首頁 listener 的擁有權不變：initState 加入、dispose 移除，現在有測試守著。✅

## MINOR

- **m-a** approval 的下一步那句（m-5 的修正）沒有測試守著：NC3 把那個分支拿掉後，`format_reasons_are_words` 照樣通過。原因是測試只斷言「以『這不是正確的』開頭、不含內部字」，退回通用的「這不是正確的碼」也符合。建議加一行 `assert!(invite_err(&Error::Format("approval keys")).contains("請隊長重新產生同意碼"))`；另外三個 approval 原因也一起斷言，或者用迴圈。
