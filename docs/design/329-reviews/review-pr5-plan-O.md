# Review O: #329 PR 5 plan v8 (round 8)

Reviewer O. Focus: consistency with the source and the baseline, lifecycle paths, ownership, contracts, faithful moves,
the §2.9 entry table, and contradictions between sections. Worktree `C:/src/Batman-329pr5` at main 2e18de6 plus the
uncommitted `QrScanActivity.kt` change. All file:line references are to that tree. Read-only except this file.

Summary: **0 BLOCKER / 1 MAJOR / 11 MINOR. Verdict: APPROVE-WITH-CHANGES.**

## What I checked and found sound (with evidence)

- **§2.9 against nodes.dart:1733-1770.** Every member button there has a new entry: 加入網路 (member branch, :1735),
  狀態頁 hint (:1744), 把新密碼送給節點 (:1745), 隊員名單／移除 (:1750), 產生更新包 (:1751), 貼上更新包 (:1752),
  邀請隊員 (:1757), 貼上隊員的申請 (:1758), 貼上邀請 (:1759), 貼上同意碼 (:1760), 申請加入 (:1763-1766),
  再顯示申請 (:1768). The 排除這台 path of 忘記加入中的節點 (:1741, `_forgetOrExclude` :1303-1308) is in too. The other
  buttons in that range (Wi-Fi, 建立網路, 檢查網路, 軟體更新) are not member buttons; PR 3 / PR 4 already moved them.
  The 3.6 button outside the old console (add_pages.dart:124-130, :151) is also listed. **The table is complete.**
- **§2.3 hint placement against prober.dart.** The answer step is :122-127, `done` is :69-71, the 20 s timer is :172,
  cleanup and `s.dispose()` are :188-205, and the `catchError` that logs `$e` is :174-177. The v5–v7 order is sound:
  compute before `done`, cancel `answer` at the answer step, and check `cleaning` after `openNet` returns. The flag can
  be set synchronously at the start of cleanup (before `await sub?.cancel()`, :195). The continuation of
  `await result.future` runs as a microtask, and the platform reply of `openNet` is a later event. So a timed-out
  `openNet` that returns late always sees `cleaning` set. I agree with "updateHint is sync, no dispose can interleave".
- **The hint rule.** `update_hint` reads `self.page_info` (owner.rs:1099-1101). It is set by the info-page step
  (owner.rs:960-965), which runs inside `requestStatusPage`, so it is set at the prober's answer step. `StatusView.net_id`
  comes from info key 10, which is format-checked to 16 bytes (owner.rs:2260). That matches the §5 compromised-node
  claim. The old net → mnet order with `break` is nodes.dart:1166-1176.
- **Lease.** `reg._revoke` is lease.dart:140-149, and the pageGone deadline uses it at :80-82. `RecordWriter._check`
  refuses a lease that is not `reg.current` (record_writer.dart:27-33), so revoke is fail-closed for later writes, as
  claimed. `acquire` drops NodeLink's links (node_link.dart:184-191).
- **joinreq.** The wait is 15 s (`_ask` default, nodes.dart:512). `joinreqLostLine` is member_ui.dart:166-169. The
  persistPend step already goes through `lease.run` + `writer.writeCas` (owner_console.dart:281-292).
  `ConsoleReply.sendUpdate` / `pollLink` exist (owner_console.dart:88-116).
- **The rekey texts.** `AlreadyCurrent` and `Updated` are the only two positive lines. `Applying` carries the same
  `[UPDATED]` prefix (rekey.rs:447-452). So N-m3 / N-m4 are right, and M-M1 / N-M1 are closed in 8.4, 8.5 and §5.
- **Others.** `nodeDacHash()` exists (owner.rs:1031-1035; owner_console.dart:217). `mnet_summary` gives only
  `device_last4` (member.rs:312-327), as K-m1 says. `NoEntry` is "需要新的邀請" (owner.rs:584). The scanner change in
  the worktree is exactly the 1280×960 `CLOSEST_HIGHER_THEN_LOWER` selector (QrScanActivity.kt:58-62, :105-106). The
  name limit is 32 UTF-8 bytes in Rust (invite.rs:28, :114). Note that the old TextField counts characters
  (nodes.dart:1765), so T-V1 / T-V2 really are new behaviour, as the plan says.
- **Earlier MAJORs.** I re-checked each one against source. A-M1..3, B-M1..2, C-M1..2, D-M1..3, E-M1..2, F-M1, G-M1,
  H-M1..2, I-M1, J-M1, K-M1, L-M1 and M-M1 / N-M1 are closed in v8 as written. The one exception is the clipboard
  regression below. It was introduced by the v8 handling of N-m8, not by any earlier MAJOR.

## MAJOR

### O-M1: the v8 `clearClip` rule (N-m8) stops "貼上後立刻清剪貼簿" from working: every pasted code now stays on the clipboard.

- **Scenario.** A member copies the leader's approval code (or an invite, or a 128 KiB update bundle) from the messaging
  app and presses 貼上文字 in 7.8, 7.10 or 8.5. The plan says the paste path clears with `clearClip` (2.2: "貼上後清剪貼簿用
  `clearClip`，不再用 `setData('')`（v3，D-m3）"). But v8 changed `clearClip` to "只在剪貼簿裡還是我們剛複製的那段碼時才清"
  (2.1, N-m8). A pasted code was never copied by this app, so `clearClip` does nothing. The code, and with it the
  member roster inside approvals and bundles, stays on the clipboard. Any later clipboard reader can see it, and the
  user may paste it into the wrong place later.
- **Why this is a field failure and not wording.**
  - It breaks the decided upper design §5.7 (329-app-uiux.md:774): "貼上後立刻清剪貼簿".
  - It breaks the frozen baseline: remove-member :163, "成員端照今天貼上的做法,按下貼上那一刻就清空剪貼簿".
  - It breaks the old behaviour the plan says it moves unchanged: `_takeClipboard`, nodes.dart:728-732, which is P10.
  - §5 still claims "貼上後立刻清" as a guard, and §6 step 2 tests "貼上後清". So the test will either fail, or it will
    be written against our own copy, where it passes without ever running the paste path.
  - N-m8 was about the copy side: the "清除剪貼簿" button after a copy must not wipe what the user copied later. Its fix
    was applied to the one shared method that the paste path also uses.
- **Fix.**
  - Use two methods, or one method with a mode. The paste path clears unconditionally, right after reading, as
    `_takeClipboard` did. Only the copy-side button and the leave reminder use the "only if it is still ours" check.
  - Write the two contracts separately in 3.2.
  - Test both. After a paste, the clipboard is empty even though the text was not ours. Negative control: route the
    paste through the "only ours" variant, and the test FAILs. After a copy, the user copies other text, then presses
    清除剪貼簿, and the other text survives.
  - Add the N-m8 rule to the grep you promised for rule changes: "清剪貼簿" appears in 2.1, 2.2, 2.6 #14 and §5.

## MINOR

### O-m1: 8.3 says it reads "every own node on the phone", but the old `_remove` reads only the record's own nodes minus the target.

- **The old code.** nodes.dart:1352-1374 loops over `own = removeOwnNodes(...)`. In Rust (proto rekey.rs:86-93) that is
  the own members of this net record, with the target node filtered out, intersected with `_nodes`. Each read is passed
  as `NodeInfo(dacHash: o.dacHash, ...)`, using the record's hash for that device_id.
- **What v8 says.** 8.3 step 1 and its test ("手機有 2 台節點紀錄 → 兩台都被嘗試登入") read as "every `node/` record".
  2.7.1 maps each read by the session's read-back `dacHash`.
- **Field effect.**
  - With 排除這台, the phone logs in to the lost or captured node it is about to exclude. Old code never does that.
  - The phone also logs in to nodes of other networks.
  - Each unreachable node costs a 60 s `loginFor`.
  - The result is still correct, because precheck ignores unknown or excluded hashes (proto rekey.rs:114-123). But this
    is not a faithful move, and it touches a node the user said is in an attacker's hands.
- **Fix.** Iterate over `removeOwnNodes(record, owner, person, node)` ∩ `node/` records, as the old code does. I-M1's point
  (all records, not just the visible ones) still holds, because `_nodes` is all records. Change the test to "2 own nodes
  of this net plus 1 node of another net plus the target → only the 2 are logged in".

### O-m2: stale entry conditions contradict 2.8.1 and T-P5-E. This is the same class as M-M1, but here it is not fail-open.

2.8.1 says 「隊伍與邀請」 is one row whose items are "一直在，不看紀錄", and T-P5-E tests that with no records at all.
These places still say otherwise:
- **2.6, leader entries.** "設定頁的「隊員」一列：手機有 net 紀錄就出現". 2.8.1 says this row was merged away.
- **2.6 #14 (8.5 entry).** "「隊伍與邀請」的「貼上隊長給的新密碼」…都要手機有 mnet 紀錄…才出現".
- **3.3, row 1.** "首次安裝 / 啟動 | 沒有紀錄時入口不出現".
- **3.3, row "隊長排除自己最後一台節點".** "設定頁的「隊員」仍進得去".

**Fix.** Reword all four so that the conditions apply only to shortcuts, and only the 隊伍與邀請 row is gated, by
devTrust alone. Then run the "grep the concept" step you adopted in round 7 for 「隊員」一列 and 有 mnet 紀錄.

### O-m3: 2.3's hints contract still says "送新密碼成功後 … `NodeLink.refresh`", but v7 (K-m4) removed it from 8.4.

- **The contradiction.** 8.4 explains that a refresh does nothing from a settings-rooted page (core.dart:170
  `_eligible`, and Page.other at :167). 2.3 keeps the rule for every send. It works only for the node-page "更多" send,
  where the page is Page.node.
- **"Success" is undefined.** If it means "[UPDATED]", that includes `Applying`.
- **Fix.** Scope the 2.3 sentence to the node page, and say "after any answer" (the refresh only reads, so there is no
  harm). Or drop it and leave the existing on-entry read (X33, core.dart:196).

### O-m4: the 2.9 row "讓我的節點加入隊長的網路 → 選 mnet → 選節點" contradicts D10.

D10 says 「隊伍與邀請」 uses the entry node directly. Rust refuses any other node with `NotThisNode`
(proto join2flow.rs:78, :383; the plan cites :76-77). **Fix.** Write "選 mnet → its entry node (`memberEntryOf`); no
record of it → the old reason line" in 2.9, and fix the citation.

### O-m5: the 7.8 node filter contradicts itself and drops a baseline path.

- **Self-contradiction.** 2.6 #11 lists nodes "沒加入任何網路". 2.7.1 lists "所有沒加入網路的 node/ 節點，包括這一輪還沒讀到的".
  The state of an unread node is unknown, so the two cannot both hold.
- **The dropped path.** `request_joinreq` has no node-state check (owner.rs:1283-1300), and the old console offered
  申請加入 on any logged-in node (nodes.dart:1763-1766). The baseline supports a re-invited, removed member whose node is
  still in the old configuration. remove-member :147 says he can be re-invited. :186 says the member-mode join of an
  already-member node goes straight to the send when the chain connects, and says "請先按『離開網路』再加入" only when it
  does not. The filter hides that node.
- **Fix.** List every `node/` record. Show its last read state as a label ("已在網路裡" or "還沒讀到"). Let Rust decide,
  as 2.7.1 already says for a wrong choice.

### O-m6: the member-mode join has no node-page retry when the node already applied.

- **The texts that point there.** Rust's member texts tell the user to press 加入網路 on this node:
  - `PersistFailed{applied:true}`, "節點已套用，手機紀錄沒存好…請在這台按「加入網路」補上紀錄" (owner.rs:572-574, reused by
    `member_join_text` :592);
  - `_joinUnclear` (nodes.dart:49).
- **Where the button is.** The node-page 加入網路 row appears only when `nodeState == 1` (2.7; node_page.dart:81). Home
  row 6 appears only for nodes not in a network (home_logic.dart:88-96). Unlike the leader's join, there is no NetIndex
  todo for a joining mnet entry.
- **The unverified claim.** 2.7's "結果不明之後，節點還是 nodeState == 1" is not proven, because an unclear result may
  have applied. So after an applied-but-unsaved member join, only 「隊伍與邀請」 → 讓我的節點加入 reaches the retry.
- **Fix.** Pick one:
  - The join wait page's member-mode result shows a "再試一次" button for these two lines.
  - The node-page row also shows when this node is an mnet entry whose `entryState` is `joining`.

  Add the path to 3.3.

### O-m7: the kind-based revoke todo needs more than the one-line `Lease.revoke()`.

- **The data does not carry a kind.** `unsavedTodos` is a `List<String>` filled by `_revoke` as "上一個操作可能沒有存完：<名稱>"
  (lease.dart:110, :144). The banner text is fixed (home_page.dart:300-302).
- **The plan needs one.** K-m9's "依種類選句子的分支" needs a kind that the registry does not record. So "the only
  increment to PR 1" is not accurate. The branch must match the constant names (N-m5 makes that possible), or the todo
  entry must carry the kind.
- **Fix.** Say which. I suggest matching against the set of `OfflineOp` name constants, with a test that covers each name.

### O-m8: the `OfflineReply` contract and the revoke tests do not match 2.4.

- **The contract.** 3.2 lists `done` / `busy` / `failed`. 2.4 also has a revoked, result-unknown outcome that the page
  later resolves by a per-operation re-read. Add it to 3.2, with its re-read predicates.
- **The test.** 2.4's test "寫入在收回之前落地 → 頁面顯示「已經完成」" contradicts the per-operation rule. Invite and approve
  must say 結果不明 even when the record landed (I-m8 / J-m4). Name the operations the test covers.
- **startBundle.** It is in `OfflineOp` but has no revoke judgement. It writes nothing, and the hex is lost, so the
  answer is "結果不明，請再按一次「複製更新包」".
- **The removal re-read.** When the revoke path re-reads and finds "已經移除", it must also call
  `RemoveTicks.removed(netId)`. Otherwise the 8.1 line from §5.7-4 never appears for that removal.

### O-m9: `OfflineOp.failed(line)` must keep Rust's refusal text.

- **The old code** showed Rust's reason for `startRemove`, `approve`, `makeInvite` and the import refusals
  (`_say('[REQ_FAIL] $e')`, nodes.dart:808, :858, :1417, :1033, :1538). For example, NotSoleAdmin and Joining come from
  rekey.rs:128-145.
- **The plan** says only that the text log records `runtimeType` (2.4, D-m4). The line on screen is not defined.
- **Fix.** A `String` exception becomes the shown line verbatim, as `OwnerConsole` does (owner_console.dart:295-296).
  Any other exception gets a fixed line. Only the log is restricted to `runtimeType`.

### O-m10: the 3.1 ownership table has two `InviteHolds` rows with different writer sets.

One row has "收下、申請成功、「不用這份邀請」". The other has "收下、申請成功（清）" and lacks 不用. Neither row has "app 關掉"
(2.5). The `RemoveTicks` row says 8.3 "清", but 2.5 has 8.3 call `removed(netId)`, which also sets `removedThisRun`.
**Fix.** Keep one row per resource, matching 2.5.

### O-m11: the 8.4 fixed texts.

- **"被移除的人" with no removal.** The standalone 產生更新包 entry has no removal, yet the page says "沒有送出新密碼的節點，被移除的人仍然連得上",
  and `kRekeyDoneRule` ends with "被移除的人仍可能連得上". The appendix says H-m5 limits that line to a removal in this
  run. v8 shows it always. Either restore the H-m5 condition, or word it as "上一次被移除的人…".
- **"狀態頁" in the `Applying` line.** Rust's line says "稍後再看狀態頁" (rekey.rs:452), and the new UI has no 狀態頁.
  `kRekeyDoneRule` already says to press 送出 again. Note in 8.4 / 8.5 that the Rust wording refers to the node page or
  the button, or add one line under the result: "（狀態頁 = 節點頁）".

## Actor walk (summary)

- **Remote attacker with an intercepted code.**
  - The codes are non-secret, and the SAS is unchanged (`SasConfirmView` moved as is).
  - 7.7 is worded honestly (D7).
  - The clipboard residue from paste (O-M1) widens what a later reader sees.
- **Local unprivileged app.**
  - FLAG_SECURE is ref-counted across stacked pages (secure_screen.dart:21-38), so 7.5 → 7.6 keeps it.
  - On the clipboard side, O-M1 applies. The copy side is fine with N-m8.
- **Compromised peer.**
  - A malicious member can grind a same-fpr, same-name group. F-m5 uses full-owner comparison, which is fine.
  - A malicious node can choose only `net/<16B>` or `mnet/<16B>` and affects display only. Since M-M1, 8.4 / 8.5 do
    not trust a missing card.
- **Physical capture.** 排除這台 must not log in to the captured node (O-m1).
- **Our own mistakes.** The v8 N-m8 handling broke an unrelated guard (O-M1). Stale entry text remains (O-m2, O-m4).
  These are the same pattern as M-M1, so the round-7 "grep the concept" step should also cover the clipboard and the
  entry conditions.

## Verdict

**APPROVE-WITH-CHANGES.** Fix O-M1, which is a one-method split plus a test with a negative control. The MINORs are
doc consistency, plus three faithful-move corrections: O-m1, O-m5 and O-m9.
