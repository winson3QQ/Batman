# #329 PR 5 計畫 v10 審查（第十輪，審查者 T）

審查對象：`docs/design/329-pr5-plan.md` v10（worktree C:/src/Batman-329pr5，main 2e18de6）。
重點：安全與 fail-safe，包括 R6–R9 提示、R14 `RekeyResult`、R10–R12 `OfflineOp`、R1–R4 QR / SecureScreen / 剪貼簿、R15/R16 gate 與入口節點、記錄。
範圍：只審 §0「本 PR 新做的」與 §2–§7。基準（219 §7.4/§7.6、member-join v6.1、remove-member v6.5、PR 1–4 機制、Rust）只拿來對照。

**結論：APPROVE-WITH-CHANGES。0 BLOCKER / 2 MAJOR / 8 MINOR。**

---

## 已對原始碼核過的部分（沒有問題）

- **R3 的 SecureScreen**：`_held` 是全域計數（secure_screen.dart:21、:27、:37）。所以 7.9 同時有兩個 `SecureScreen`（QR 與確認碼）時，拿掉其中一個不會把 FLAG_SECURE 關掉。等待 Android 回答時（`_on == null`）是 `SizedBox.shrink`（:45），R3 的描述正確。
- **邀請碼不是秘密**：app 只產生遠端邀請（kind 1），裡面沒有 SAE 密碼（invite.rs:3-5、:300、:317；member.rs:158-163）。219 §7.6 裡含 SAE 密碼的「當面」那一種沒有實作，所以 D3（兩條路做的事一樣）和 D6 / §5「碼本身不是秘密」都成立。同意碼裡的 `net_secrets` / `member_secrets` 都已經對收件者加密（219 §7.4）。
- **確認碼的換管道規則**：`SasConfirmView` 和 `SasShowView` 都已經帶 `sasRule`「請用電話或當面核對…」（member_ui.dart:35、:71、:94）。所以中途攔截的遠端攻擊者換掉申請碼時，雙方必須到聊天以外的管道核對。
- **R16 不是 fail-open**：Rust 的 `begin_member` 會比對 mnet 的 `me.dac_pub_hash`、secrets 的目標與這次登入的 DAC，不符就回 `NotThisNode`（join2flow.rs:376-384）。入口節點即使用後四碼選錯，也送不出東西。
- **R6–R9 的提示面對被入侵的節點**：
  - k10 只能是 16 位元組的十六進位（P-m2，owner.rs:2258-2260）；
  - `update_hint_of` 會再比對 k10 和紀錄的 net_id（rekey.rs:474、:485）；
  - 提示的按鈕送出時，Rust 會檢查節點在名單裡（`NotListed`，rekey.rs:438）。

  所以節點謊報 k10，最多只能讓提示卡顯示錯的內容，拿不到別的網路的秘密。
- **R7 的順序**：`answer` 那一步（prober.dart:122-127）是 `done` 之前唯一還能用 session 的地方；`dispose` 只在清理時發生（prober.dart:188-203）。`cleaning` 旗標加上 `updateHint` 是同步呼叫，可以關掉取消那一段空檔。G-M1 / H-M1 確認已關。
- **R12 收回**：`_revoke` 把 `_ended` 設為真並換掉 token（lease.dart:140-149），之後 `RecordWriter._check` 會拒絕（record_writer.dart:27-33）。如果某個寫入在收回前已經通過 `_check`、還在等 `store.writeCas`，它和新佔用者之間由 CAS 保護。依操作重讀的表格是 fail-safe 的：判斷不出來的一律「結果不明」。
- **devTrust 的來源**：值來自 flavor 的 platform 呼叫，並和 Rust 的 `info.devTrust` 比對（main.dart:103-107），本機其他 app 改不了。`request_send_update` 和 `request_info` 確實沒有 `dev_gate`（owner.rs:1027、:1041），所以 T-S5 的 Dart gate 測試是必要的，計畫也寫了。
- **顯示文字裡的 last4**：來自手機的節點紀錄（owner.rs:717-720），不是節點自己報的。所以被入侵的節點沒辦法用名字偽造「已是新密碼」這句話（和 m2 有關）。
- **附錄 A 的 MAJOR**（只核我負責的面）：
  - D-M1、E-M1、G-M1/H-M1、I-M1、J-M1、K-M1、L-M1/M-M1、O-M1/P-M2、Q-M1 都已關。
  - 正文裡的「消失」「略過」「已送出」「clearOwnClip」只出現在歷史說明或負對照裡。
  - `nodeState` 只出現在 R16 隊長那一支。
  - **P-M1 / R-M1 只關了一部分**，見 T-M1、T-M2。

---

## MAJOR

### T-M1：隊員端的勾只代表「這一頁剛匯入過」，不代表是最新版本；計畫要求的「用電話和隊長核對」沒有可以比對的東西

**情境**（攻擊者是一個**惡意隊員**；他最後一定會被移除，並且看得到隊上的聊天）：
1. 第一次移除後，網路換到 v(N-1)。隊長把 X 的更新包 B1 貼在隊上的聊天裡。X 當時不在，沒有匯入，所以 X 的 mnet 還停在 v(N-2)。攻擊者 A 當時還是隊員，手上有 B1，也知道 v(N-1) 的秘密。
2. 第二次移除的就是 A，網路換到 vN。
3. A 冒充隊長，把舊的 B1 私訊給 X。
4. B1 有隊長的真簽章，對象也是 X 的加密金鑰（mupdate.rs:263-268），所以 `prepare` 回 `Advance { to: N-1 }`（mupdate.rs:290-298），8.5 匯入成功，`justImported` 為真。
5. X 在 8.5 按「送出」，節點換到 v(N-1)，回 `Updated`，R14 打勾。

結果：X 的節點用的是 A 知道的 v(N-1) 密碼，A 可以繼續連上 X 的節點，而 X 的畫面上是一個勾。

同一類的情形：`AddSecrets`（同版本、補另一台節點的秘密）也會讓 `justImported` 為真，但那個版本本身可能已經過時。

**計畫的防線無法操作**：
- `kMemberRekeyRule` 叫隊員「用電話和隊長確認你拿到的是最新的更新包」。
- 但 v10 拿掉了版本號（:10、附錄 Q-m4），8.5 也沒有寫要顯示 `memberUpdatePrepare` 的 detail。舊程式 `_takeUpdate` 只在 `alreadyImported` 時才顯示它（nodes.dart:1520-1524）。
- 所以雙方在電話上沒有任何可以比對的數字。

Q-m4 原本的修法是「拿不到 N 時才用不帶數字的句子」，不是全部拿掉。不需要解析也拿得到數字：
- Rust 在 `Advance` 的 prepare 原句就是「[UPDATE] 更新到第 {to} 版」（rekey.rs:400）；
- 隊長在移除時看到的是「[REKEY] 已換成第 {version} 版的密碼」（rekey.rs:208）。

**修法**（二選一，都不用改 Rust）：
- (a) 8.5 原樣顯示 `prep.detail`，不解析。`kMemberRekeyRule` 改成「把畫面上『更新到第幾版』念給隊長，和隊長移除時看到的『第幾版』對」。`AddSecrets` 沒有版本號，那就不打勾。
- (b) 隊員端一律不打勾，只顯示原句和規則。這是 fail-closed，也是最簡單的做法。

**測試**：匯入一份比網路舊、但比 mnet 新的更新包，然後送出回 `Updated`：
- (a) 頁面要顯示「第 N-1 版」；
- (b) 頁面不打勾。

負對照：恢復成 v10 的做法 → FAIL。

### T-M2：R14 說「共四個地方」，但漏了「加入網路之後順便送新密碼」的路徑；那條路把 `Applying` 當成功

**證據**：
- PR 3 的 `NetRun._join`（net_run.dart:299-311）在 `j.sendUpdate` 時呼叫 `c.sendUpdateFor(rel)`，只用 `u.starts('[UPDATED] ')` 判斷成功。`Applying`「正在套用新密碼，稍後再看狀態頁」也是 `[UPDATED]` 開頭（rekey.rs:453，P22）。
- 判斷成功之後，那一列顯示的是加入的原句 `j.text`（:317），不是送密碼的結果，也沒有 `kRekeyDoneRule`。
- R16 的隊員加入「用 PR 3 的加入等待頁跑 `memberJoin`；回 `sendUpdate` 時跑 `sendUpdateFor(member: true)`，結果用 `RekeyResult`」（:408-409）。所以計畫自己也有第五個地方，但 R14 的清單（:360-364）沒有列它。
- R16 也沒寫這裡的 `justImported` 該是什麼。剛從同意碼匯入，不是更新包，所以應該是假。

**現場後果**：
- 隊員在 7.10 → R16 加入的時候，如果節點回 `Applying`：照 PR 3 的寫法會顯示「已加入」；看不到「等幾分鐘再按、超過 10 分鐘重開機」那段說明，也沒有隊員規則。
- 如果套用沒有完成，節點就停在舊密碼，沒有任何畫面會提醒。節點頁開著時提示卡會出現，但沒開就不會（R6）。
- R14 的原始碼檢查「`sendUpdateFor` 的結果除了 `RekeyResult` 之外不能被任何 widget 直接顯示」：
  - 如果照字面實作，第一天就會在 net_run.dart:301-309 FAIL；
  - 如果把 net_run 排除掉，等於靜靜開了一個例外。
  - 這正是 v10 想消滅的「規則改一處、別處留舊的」。

**修法**：
1. R14 的清單加上「加入網路之後的送出」，隊長（PR 3）與隊員（R16）兩條都列。
2. 寫明這裡用 `RekeyResult(member, justImported: false)`，而且這一列的狀態不能只看 `[UPDATED]` 前綴。
3. 至少 R16 的隊員那條要這樣做。PR 3 的隊長那條如果要動，算對 PR 3 的增量，要在 §0 增量清單加一行；如果不動，R14 要明寫這個例外和理由，並且原始碼檢查的允許清單要寫出來。

**測試**：`memberJoin` 回 `sendUpdate`，送出回 `Applying`：
- 不打勾；
- 畫面顯示 Applying 的原句與 `kRekeyDoneRule` / `kMemberRekeyRule`。

負對照：用 `starts('[UPDATED] ')` 判斷 → FAIL。

---

## MINOR

### T-m1：R16「登入後用 `nodeDacHash()` 比對」沒有可以比的對象
- `MnetView` 只有 `device_last4`，沒有入口節點的 dac hash（member.rs:303-327）。計畫又規定 Rust 入口不改。所以 Dart 拿不到 mnet 入口節點的 hash，這一步照字面做不出來。
- 真正的守門是 Rust 的 `NotThisNode`（join2flow.rs:380-384），它是 fail-closed。
- 修法：拿掉這個 Dart 比對，改成「後四碼撞號時列出候選；送出後如果回 `NotThisNode`，顯示 Rust 原句」，並加一個測試。8.4 的 `nodeDacHash` 比對有 `PersonNode.dac_hash` 可以用（rekey.rs:47-52），那裡沒問題。

### T-m2：R14 怎麼判斷「原句是 AlreadyCurrent 或 Updated」沒有寫，等於回頭解析顯示文字
- `sendUpdateFor` 只回文字（owner.rs:1090、`ConsoleReply.text`），沒有結構化的結果。所以打勾必定要比對字串，和開頭「解析顯示文字很脆弱」的立場相反。
- 修法：
  - 寫明用錨定的整句比對：`^\[UPDATED\] 節點 …[0-9a-f]{0,4} (已是新密碼|已換成新密碼)$`。last4 來自手機紀錄（owner.rs:717），節點無法注入。
  - 加一個 Rust 端的測試，把 `update_text` 每一個 `End` 都輸出，Dart 端逐一斷言只有兩種會打勾。這樣 Rust 改了措辭時，測試會 FAIL；現在的情形是靜靜地永遠不打勾。

### T-m3：`removedThisRun` 只在記憶體裡，app 重啟後隊長就看不到「被移除的人仍可能連得上」
- 3.3 寫明 app 被殺之後 `RemoveTicks` 會丟掉。之後從「隊伍與邀請」→「產生更新包」進 8.4：
  - R14 那一句不會出現；
  - 8.1 頂端的「還有 N 位」也不會出現。
- 移除後被殺正是最需要提醒的時候（3.3「移除寫好、還沒進 8.4 就被殺」那一列）。
- 修法：這一句在 8.4 的「自己的節點段」**一律**顯示。這是 fail-safe，而且它本來就是事實陳述。

### T-m4：R12 移除「結果不明」時，沒有引導隊長進 8.4
- 判斷不出來時，`RemoveTicks.removed` 不會被呼叫，隊長只會被叫去 8.1 確認。
- 如果隊長在 8.1 看到人已經不在，沒有任何東西叫他去換密碼，只剩 8.1 那一行固定文字。
- 修法：「結果不明」的畫面加一顆「到換密碼檢查清單」（8.4）。

### T-m5：R11 的重讀清單漏了「邀請」
- `make_invite` 需要 `record_plain` 和 `record_gen`（member.rs:158-160），而且會寫 PersistNet。
- CAS 會擋下過時的紀錄，所以不會寫錯，只是會多一次失敗。
- 修法：把「邀請」加進 R11。

### T-m6：R14 的原始碼檢查要寫成可以執行的規則
- 舊控制台到 PR 6 之前還在，它用 `_say` 直接顯示結果（nodes.dart:1580-1581）。
- 修法：寫成「`lib/ui/**` 與 `lib/src/**` 裡對 `.sendUpdateFor(` 的呼叫，只能出現在允許清單列出的檔案」；`nodes.dart` 列為明寫的例外，PR 6 時移除。
- 否則這個檢查不是一跑就 FAIL，就是實作時被隨意放寬。

### T-m7：T-P5-L 要涵蓋「例外訊息裡含有碼」的情形
- prober 的兜底 catch 會記 `$e`（prober.dart:166、:175、:185）。R7 說提示路徑的例外在本地接住、只記 `runtimeType`。
- 修法：測試讓假的 `openNet` 丟出一個訊息裡含有假碼 / 假網路名稱的例外，斷言記錄裡沒有這些字。這樣才能證明本地 catch 真的接住了，而不是落到 :185。
- 同樣的測試也適用 `OfflineOp` 的 `failed`：顯示 Rust 原句，但記錄只有 `runtimeType`。

### T-m8：Android 12 的剪貼簿 sensitive 旗標只寫了 ⚠️，沒有退路
- 如果 Android 12 上字面字串沒有作用，別的 app 和鍵盤可以看到剪貼簿預覽。碼不是秘密，所以這不是 MAJOR。
- 但 R3 已經規定「這種手機上剪貼簿警告一直顯示」。建議 Android ≤ 12 也一律顯示同一句警告，不要等查證。

---

## 逐一攻擊者（摘要）

| 攻擊者 | 看了什麼 | 結果 |
|---|---|---|
| 遠端攻擊者（在聊天裡攔截碼） | 邀請沒有秘密；同意碼已經加密；確認碼必須換管道核對；7.7 不寫入 | 沒有新的發現 |
| 本機無權限的 app | 剪貼簿：貼上後一律清；複製後清不清由使用者決定；sensitive 旗標。截圖：FLAG_SECURE 有計數；設不了時不顯示 QR | 只有 T-m8 |
| 被入侵的節點 | k10 有格式驗證、Rust 會檢查名單、last4 不是節點給的；它能謊報 `AlreadyCurrent`，但它本來就是被入侵的那台 | 沒有新的發現 |
| 惡意隊員 / 被移除的人 | 重播舊的更新包 → 隊員端打勾 | **T-M1** |
| 實體奪取 | §5 已列為殘留風險 | 同意 |
| 我們自己的錯 | R14 漏了一個地方、`Applying` 被當成功 | **T-M2**；另見 T-m1、T-m2、T-m6 |

## 結論

**APPROVE-WITH-CHANGES**：0 BLOCKER / 2 MAJOR / 8 MINOR。

- T-M1 和 T-M2 都只要改文字並加測試，不用改 Rust，也不用新的機制。
- T-M1 可以選最簡單的 (b)：隊員端不打勾。
- 改完之後，請照 v10 自己的規則全文搜尋「RekeyResult」與「[UPDATED]」，確認沒有第六個地方。
