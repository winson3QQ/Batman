# Review M — #329 PR 5 plan v7 (round 7)

Reviewer M. Focus: consistency with the source and the baseline, and field behaviour (lifecycle, ownership, contracts, faithful moves, the §2.9 entry table). Worktree `C:/src/Batman-329pr5` @ main 2e18de6 (plus the plan, and the R-8 change to `QrScanActivity.kt` in the working tree). Read-only; only this file was written.

Result: **0 BLOCKER / 1 MAJOR / 9 MINOR. Verdict: APPROVE-WITH-CHANGES.**

## What I checked against source (and found consistent)

- **§2.9 against nodes.dart:1733-1770.** Every button in that block, one by one:
  - 加入網路 `_join` (:1735; member branch → `_memberJoin`, :1065-1094);
  - 檢查網路 (:1737; this is not a member button, PR 3);
  - 忘記加入中的節點 (:1741);
  - 狀態頁 (:1744; the hint, :1158-1177);
  - 把新密碼送給節點 (:1745);
  - 隊員名單／移除 (:1750);
  - 產生更新包 (:1751);
  - 貼上更新包 (:1752);
  - 邀請隊員 (:1757);
  - 貼上隊員的申請 (:1758);
  - 貼上邀請 (:1759);
  - 貼上同意碼 (:1760);
  - 申請加入 (:1763-1766);
  - 再顯示申請 (:1768).

  Each one has a row in §2.9. The 「排除這台」 inside the forget dialog (:1277-1283) and the 3.6 「我是隊員」 button (add_pages.dart:124-130, :151) are covered too. **Nothing is missing from the table.** Two of its rows contradict other sections (m1, m9).
- **§2.3 against prober.dart.**
  - The `answer` case (:122-127) runs inside `run()`, before `done`. The session is disposed only by the cleanup after `await result.future` (:188-203).
  - So computing the hint before `done` while the session is live is sound. A `cleaning` flag set at the start of the cleanup (before `await sub?.cancel()`, :195) closes the window where `openNet` returns during that await.
  - `answer` is a `Timer?` in the enclosing scope (:87, :172), so cancelling it at the answer step is possible.
  - `cancelled` (:83) can still complete the result during the 2 s hint wait. The cleaning check covers that.
  - `page_info` is set before the `[STATUS] 狀態已更新` answer (owner.rs:959-965). `update_hint` reads it (owner.rs:1099-1101). Key 10 is filtered to 16 bytes, lowercase hex (owner.rs:2262).
  - `Page.node` already restricts the auto read to that one node (core.dart:166), so "only for the open node page" adds no new reads.
- **8.3**: `_remove` tries each `removeOwnNodes` node that is in `_nodes` (all `node/` records: nodes.dart:171-174, :1363-1372). Each login has the same 60 s budget (old `_login` nodes.dart:390; `loginFor` node_link.dart:222). After a release, NodeLink waits `afterLease` 6 s (core.dart:19), so the next `once` does not race it. K-M1 is closed.
- **8.4 positive signal**: `AlreadyCurrent` comes after the JoinState / version checks and before any signing (updflow.rs:247-258), and its text is `[UPDATED] 節點 …x 已是新密碼` (rekey.rs:447). L-M1 is closed for 8.4 only; see M1.
- **D10**: `begin_member` returns `NotThisNode` unless both the secrets target and `me.dac_pub_hash` match this login (join2flow.rs:378-384). `mnet_summary` gives only `device_last4` (member.rs:312-327), so K-m1 is correct.
- **OfflineOp 60 s cap**:
  - `_revoke` is private (lease.dart:140-149), so the one-line public `revoke()` is the only addition to PR 1.
  - `_revoke` adds the `unsavedTodos` text that home_page shows with the "go to the node page" sentence. K-m9's per-kind branch is needed and is planned.
  - `RecordWriter._check` refuses once `reg.current` is not the lease (record_writer.dart:27-33): fail-closed, as claimed.
- **D9**: `start_remove`, `start_bundle`, `update_net_id`, `member_update_prepare` and `member_update_import` all call `dev_gate` (rekey.rs:255, :268, :335, :397, :411). `request_send_update` has none (owner.rs:1041). So T-S5 has to cover the Dart gate, and it is planned to.
- **minSdk 31** (build.gradle.kts:39): `clearPrimaryClip` is always there; `EXTRA_IS_SENSITIVE` is honoured from 33 up, as written.

## MAJOR

### M1. 8.5 still uses 「提示卡消失」 as the done signal: L-M1 is closed only on the leader side

- **Scenario.** A member gets a new bundle after a removal. They import it in 8.5 and press 「送出」 for their own node.
  - The send ends in `Applying`, `Unknown`, `[REQ_FAIL] 沒有換成功`, or the login drops.
  - Plan line 399 tells the member to "到節點頁確認提示卡已經消失".
  - The member opens the node page. The card is empty, because the page has only just opened, `openNet` took longer than 2 s, the read failed, `cleaning` was set, or `Applying` is not yet behind. The member concludes the node is done.
  - The member's node keeps the old network secrets. The removed person's node can still associate with it, and through it with the mesh: the member's node is a mesh peer on the same old key.
  - This is exactly the fail-open of L-M1. L-M1's own row in appendix A names "8.4 / 8.5".
- **Evidence.**
  - Plan line 399 (8.5): "請隊員到節點頁確認提示卡已經消失". It was not updated in v7.
  - Plan line 362 (8.4) still says "有沒有換好，只看基準的機制：那台下一次被讀到時的換密碼提示卡". That contradicts lines 363-366, which come right after it.
  - Plan line 596 (§5) still says "8.4 的固定文字已經提醒隊長到節點頁確認".
  - The empty-hint cases: rekey.rs:466-478 (no `info` → none; not behind → none). A save-pending node reports `Applying` (updflow.rs:316) and gives no hint.
  - The member path uses the same updflow with `member: true` (owner.rs:1041-1056), so `AlreadyCurrent` is reachable for the member too.
- **Fix.**
  - 8.5 uses the same fixed sentence as line 366 (「每台都要看到『已是新密碼』才算換好…」), with the same assertion test and negative control.
  - Delete line 362.
  - Reword line 596 to point at the 「已是新密碼」 rule.

## MINOR

### m1. Where the 8.5 entry appears contradicts §2.9 and T-P5-E

- §2.6-14 says the 「隊伍與邀請」 row 「貼上隊長給的新密碼」 appears only when the phone has an mnet.
- §2.9 says that page's rows follow the old console's condition, "不看紀錄" (old :1752 is dev only). T-P5-E asserts that every row is present and pressable on a phone with no records.
- **Fix**: pick one. I suggest §2.9's (always there under devTrust), which matches the old console. Let `updateNetId` / `memberUpdatePrepare` give the reason.

### m2. An mnet whose own-node entry was dropped (NoEntry) is a dead end on the main surfaces

- After a definite member-join failure, key 7 is dropped (owner.rs:577-583: "…；需要新的邀請"). `mnet_summary` then gives `entry_state == ""` (member.rs:315-325), so `memberEntryOf` is false (member_ui.dart:256).
- With the plan as written, three surfaces show nothing:
  - home row 6 (mnet-only) gives no button, and the D10 sentence is only for "entry node already in a network";
  - the node page hides 「加入網路」;
  - NetFormPage has no defined branch.
- The member saw 「需要新的邀請」 once, on the wait page. Afterwards only 設定 → 隊伍與邀請 → 「收隊長的邀請」 leads anywhere.
- **Fix**: when an mnet has no entry, row 6, the node page and NetFormPage say Rust's sentence ("需要新的邀請") and offer 7.8.

### m3. 3.6 「加入網路」 on an mnet-only phone with a non-entry node is undefined

- add_pages.dart:118-121 and :150: after a claim with `records == mnet`, the main button is `_form(false)` → NetFormPage.
- That is the member's second node, which is never the entry. §2.7 removes net_pages.dart:352-360 and says "mnet 走 member 模式", but D10 allows member mode only on the entry node.
- **Fix**: NetFormPage applies the same D10 sentence as home row 6 (「這台不是你加入隊伍時用的節點…請隊長再邀請一次」). Add a widget test from 3.6.

### m4. 7.5 drops the old SAS title (who, which node, 「重新同意」)

- Old `_checkRequest` shows `核對隊員的申請：${jr.name}（…${jr.deviceSuffix}）${jr.replacesApproved ? '，重新同意' : ''}` (nodes.dart:850). The title is the caller's, not part of `SasConfirmView`.
- With "一張邀請可以收多份申請" (§2.9), the name, node suffix and re-approval mark are what tell the leader which request they are approving. 「重新同意」 is the only cue that an approved node is being replaced.
- §2.6-5 says only "`SasConfirmView`，原樣搬過來".
- **Fix**: state that 7.5's title is moved verbatim, and add a widget assertion on `replacesApproved`.

### m5. member mode: `sendUpdateFor` after `memberJoin` must re-read the mnet

- Old `_sendUpdateFor` reads the record at the call (nodes.dart:1573), after `_memberJoin`'s persistMnet changed it.
- §2.6-13.5 says "再依 `sendUpdate` 跑 `sendUpdateFor(member:true)`" without saying where the record comes from. Reusing the `(gen, plain)` read before the join would send from a stale record.
- **Fix**: one line: re-read `mnet/<id>` under the same lease just before `sendUpdateFor`.

### m6. After an `Applying` result, pressing 「送出」 again gives `Unfinished`, not 「已是新密碼」

- A save-pending node ends `Unfinished` (updflow.rs:248; rekey.rs:445 「…超過 10 分鐘仍如此，重新開機一次」) until its save finishes.
- The fixed text tells the leader to press 送出 again to confirm, so they may loop on it.
- This is fail-closed, so it stays MINOR. Add one line: after 「正在套用」, wait (or restart the node) before the confirming press.

### m7. The lifecycle matrix (§3.3) lacks the OfflineOp failure paths that §2.4 designs

- Missing rows:
  - the 60 s revoke;
  - the app being killed between PersistNet and the hex reaching the page (invite or approve: the record was written and the code is lost);
  - the app being killed during 8.3's node reads (the reads are lost, nothing was written).
- **Fix**: add these rows with their tests (the revoke test exists in §2.4; the others are "write landed → re-press; Rust `showDupNote`").

### m8. Stale or contradictory sentences

- Line 362 vs 363 and line 596: see M1.
- §2.6 leader entries mention "設定頁的「隊員」一列：手機有 net 紀錄就出現", while §2.9 has one settings page 「隊伍與邀請」 that does not look at records.
- **Fix**: say whether these are two rows or one, and which condition applies.

### m9. `InviteHolds` ownership row is incomplete

- §2.5 says it is also cleared on "使用者放棄", but §3.1 lists only 7.8 (take) and 7.8's successful request (clear). No page has a discard-the-invite control: 7.9's 「放棄申請」 deletes mpend, not the held invite.
- **Fix**: name the control and its owner, or drop "使用者放棄".

## Earlier MAJORs, checked against source

- A-M1/B-M1, A-M2, A-M3/B-M2, C-M1, C-M2, D-M2, D-M3, E-M1, E-M2, F-M1: closed (§2.6, §2.7, §2.9 rows checked above).
- D-M1, G-M1/H-M1: closed (prober.dart analysis above; the `cleaning` flag covers the dispose window).
- H-M2, J-M1: closed by removing the mechanism.
- I-M1, K-M1: closed (8.3 analysis above).
- L-M1: **only half closed** (M1).

## Verdict

**APPROVE-WITH-CHANGES.** Fix M1 (one sentence and one test in 8.5, plus the two stale lines). The MINORs can be folded in without another full round.
