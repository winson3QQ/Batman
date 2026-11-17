# Review K — #329 PR 5 plan v6 (round 6)

Reviewer K. Focus: consistency with the source and the baseline, and field behaviour: lifecycle paths, ownership, contracts, faithful moves, and the §2.9 entry table. Source: worktree `C:/src/Batman-329pr5` at main 2e18de6, read-only. The only working-tree change is `QrScanActivity.kt`, the R-8 resolution selector, which the plan already describes.

**Result: 0 BLOCKER / 1 MAJOR / 11 MINOR. Verdict: APPROVE-WITH-CHANGES.**

## What I checked and found consistent

- **§2.9 against nodes.dart:1733-1770.** I went through every member button:
  - 加入網路 (`_join` → `joinChoice`, :1735);
  - 忘記加入中的節點 (:1741, with the 排除這台 path at :1303-1308);
  - 狀態頁 (:1744) and its hint;
  - 把新密碼送給節點 (:1745);
  - 隊員名單／移除, 產生更新包, 貼上更新包 (:1750-1752);
  - 邀請隊員, 貼上隊員的申請, 貼上邀請, 貼上同意碼 (:1757-1760);
  - 申請加入 (:1763-1766);
  - 再顯示申請 (:1768).

  Each one has a row with a permanent entry. 檢查網路 and 軟體更新 are not member buttons; PR 3 and PR 4 own them. **No missing button.** One new-UI entry *outside* the old console was missed (m6).
- **§2.3 hint against the source.**
  - prober.dart:122-127: the answer step holds the live `session`.
  - owner.rs:949-965: `page_info` is set by the info-page step before the `[STATUS]` answer.
  - owner.rs:1099-1101: `update_hint` is sync.
  - rekey.rs:466-499: the hint uses k9/k10 plus the net/mnet rules.
  - owner.rs:2260: `net_id` is filtered to 16 bytes, so a compromised node cannot steer `openNet` to another path. This confirms the §5 claim.
  - The `cleaning` check followed by the sync `updateHint` cannot be interleaved by `s?.dispose()` (prober.dart:193-203). The G-M1/H-M1 order problem is closed. A remaining timing hole is m2.
  - The old console's `p == null → continue` / `break` loop (nodes.dart:1166-1175) is moved faithfully.
- **`Lease.revoke()`.** lease.dart:140-149 `_revoke` sets `_ended`, adds the unsaved todo and releases. `RecordWriter._check` (record_writer.dart:27-33) then refuses. The fail-closed claim holds.
- **D10.** join2flow.rs:376-384: the member join refuses `NotThisNode` unless the mnet's `me` and the secrets target match this node's DAC hash. Confirmed.
- **8.3.** The old `_remove` (nodes.dart:1361-1375) reads every `removeOwnNodes` node for which the phone has a `node/` record (`_nodes` = `listNodes`, :171-174). I-M1's restoration is faithful (but see M1).
- **8.4 list source.** rekey.rs (proto):86-94 `own_nodes` drops members without a `device_id`. That is why the merge with `netPeople`/`PersonNode` (rekey.rs bridge:47-52) is needed. The plan is correct.
- **`OwnerConsole` steps.**
  - owner_console.dart:281-307 handles persistPend/persistMnet under `lease.run` + `writer.writeCas`.
  - `sendUpdateFor` (:507-514) reads its own record.
  - `linkCheck` (:571-596) is the `_watchLink` port.
  - The plan's "no new ConsoleReply fields" holds.
- **SecureScreen nesting** (7.9 has CodeView plus SasShowView). secure_screen.dart:21,27,37 counts holders, so nesting does not drop the flag early.
- **Previous MAJORs.**
  - A-M1/2/3, C-M1/2, D-M1/2/3, E-M1/2, F-M1, G-M1/H-M1, H-M2 and J-M1 are closed in the design text.
  - I-M1 is closed for the read set, but its new "略過這台" control reopens the same weakness (M1).

## MAJOR

### M1. 8.3 「略過這台」 cannot skip. The next node's read hits `busy`, so in-range nodes go unchecked and the §2.4 / I-M1 endorsement is weakened again.

**Scenario.** A team leader has three own nodes; one is a relay on a ridge, out of range. In 8.3 the first read is the ridge node, and the leader taps 「略過這台」. Per the plan, the page stops waiting for that `once` ("`gone` 回真，不收回佔用，`once` 會照常結束並放掉佔用") and moves to node 2.

**Evidence.**
- `OpSession.once` checks `gone` only after `d.login` returns (op_session.dart:104-112). It releases the lease only in `finally` (:125-129).
- `loginFor` for an absent node runs until the 60 s budget (`LoginFor.tick`, core.dart:731-736; node_link.dart:266-290). Nothing a page can call cuts it.
- While that lease is held, `NodeLink.acquire` returns null (node_link.dart:183). The next `OpSession.once` therefore returns `OpEnd.busy` at once (op_session.dart:91-92).

**What goes wrong.**
- If the page waits for the skipped `once` before starting node 2, the skip saves nothing. The control is a lie: it says "skipped" while the 60 s still runs.
- If the page does not wait, node 2's read is `busy`. Either the leader gets 「另一個操作還在進行：移除隊員…」, or (if busy is mapped to "讀不到", the same as skip) node 2 and node 3 are sent to `removeCheck` with empty info. In that case the reachable nodes never vouch for the record:
  - `NodeNewer` (proto rekey.rs:118-136) is not checked on them;
  - the plan becomes `unverified`.

  This is exactly the weakening I-M1 removed. The plan's test (two records, none read yet → both tried) does not exercise skip followed by the next node.

**Fix.** Pick one and test it:
- **(a) Drop 「略過這台」.** The old `_remove` has no skip. Show 「正在讀第 i / n 台…（最多 60 秒）」 instead. This is the minimal, baseline-faithful choice.
- **(b) Define skip as "stop reading, check with what has been read so far".** Mark the current and all remaining nodes 「不檢查」, then wait for the in-flight `once` to release before `removeCheck`. Rust then shows its own `unverified` warning (rekey.rs bridge:172), and the leader made that choice knowingly.

Either way, add a negative control: skip node 1 of 2, then node 2 must be actually logged in (fake `loginFor` called for node 2). If the next `once` returns busy, or node 2 is recorded unread, the test fails.

## MINOR

### m1. 2.7.1 says the entry node is matched by "mnet 紀錄裡的完整 device_id", but the frozen Rust gives only the last four.
- `mnet_summary` returns `MnetView { net_id, net_name, entry_state, device_last4 }` (member.rs:303-327).
- `memberEntryOf` compares `deviceLast4 == last4` (member_ui.dart:256).
- §2.8 itself stores `entryLast4`.
- §0 says no Rust entry changes.

The full-id match is therefore not implementable as written. Impact is small: a last-4 collision between two of one member's nodes would only offer a choice that Rust then refuses (`NotThisNode`, fail-closed). **Fix:** say "後四碼 + Rust 的 NotThisNode 把關", or list the Rust change explicitly.

### m2. The 20 s answer timer still runs while the hint is awaited, so a good read can become `broken`.
- `answer = Timer(answerMax, () => done(failed()))` starts at msg2 (prober.dart:170-173) and is cancelled only in cleanup (:190).
- The v5/v6 hint wait (up to 2 s) sits *before* `done(Outcome(body))`.
- If the status answer arrives in the last ~2 s of the 20 s window, the timer fires during `openNet`. The result is `failed()` = `Res.broken` (loggedIn is true), not the body that was already read.

The plan's line 「讀取照常交出」 is untrue in that window; the `cleaning` paragraph only prevents the `updateHint` call. **Fix:** at the answer step, cancel `answer` before awaiting the hint, so that only `cancelled` can still end it. Add a test: answer at 19 s plus `openNet` taking 2 s → the color is delivered, with no hint.

### m3. 「提示卡消失」 is the only success signal, but no card also means "the hint was not computed".
- 8.4's fixed text tells the leader that the line disappearing means the node changed over.
- A card is also absent when:
  - the hint timed out or `openNet` threw (2.3);
  - `cleaning` was set;
  - `NetIndex` has not listed the netId yet;
  - on the first entry after the hint was cleared ("離開節點頁時清掉").
- In those cases the leader concludes "updated" while the node still runs the old secrets, and the removed person can still connect. This is fail-open on the signal.
- The baseline old status page had the same absence semantics (nodes.dart:1166-1175), so this is MINOR.

**Fix.** Carry a third state in `hints`: computed-empty vs not-computed. On a computed-empty result for a node in a net the phone holds, show one neutral line, 「這台已是新密碼」. Show nothing (or 「還沒確認密碼版本」) when the hint was not computed. Change 8.4's text to "確認出現『已是新密碼』".

### m4. "送出後對那台觸發提前讀取，讓提示卡盡快更新" (2.3 hints contract; 2.6-10) has no effect from 8.4.
- The hint is computed only while that node's page is open (v6 condition 3).
- 8.4 is reached from 隊伍與邀請 in Settings, where `Page.other` makes NodeLink ineligible: `_eligible` needs `page != Page.other` (core.dart:169; home_page.dart:284).

So the refresh reads nothing, or reads without computing a hint. The leader still has to open each node page, and entering it reads (X33, core.dart:196). **Fix:** drop the claim, or say "請到節點頁看；進入節點頁就會讀一次".

### m5. A hint written after the node page closed can come back as a stale card.
- The page clears the hint at dispose.
- A round that was already past condition 3 can still call `onHint` afterwards.
- On the next entry, if that entry's hint computation fails, the contract keeps the previous value (「逾時或失敗的一輪：保留上一次的值」). The stale card shows.

**Fix:** `onHint` re-checks `page == node && pageNode == id` before writing, or the "keep last value" rule does not apply across page entries.

### m6. A missed new-UI entry: 3.6's 「我是隊員，加入隊長的網路」 still opens the old console, ungated. D9's premise is also false at main.
- add_pages.dart:124-130 and :150-151: `AddedPage` shows `Btn.memberJoin` when the phone has no records and one node. It opens `NodesPage` under a raw lease with no `devTrust` check.
- This is the natural first-run path of a new member: claim the first node, then "I am a member".
- P2 lists only home_page.dart:183-190, so §0-8, §2.7 and T-S5 do not cover it. After PR 5 this entry still lands in the old console, and in a field build it is a dead end, because the paste buttons refuse.
- home_page.dart:188-190 also opens `NodesPage` with no `devTrust` gate today. D9's 「整個舊控制台只在 devTrust 才進得去」 is therefore not true at 2e18de6. In a field build the old console's ungated 「把新密碼送給節點」 (nodes.dart:1745; Rust `request_send_update` has no `dev_gate`) is reachable.

**Fix:** route 3.6's button to 7.8. Hide it in field builds, as B-m9 does for home. Add it to T-S5, with a negative control that no field-build route reaches `NodesPage`. Correct D9's wording.

### m7. Where the confirm box goes for 更多 → 「把新密碼送給節點」 is unspecified.
- Whether the record is net (the leader, who gets a confirm) or mnet (a member, who does not) is known only after `info` → `infoNetId`, inside `OpSession.once`'s requests.
- A dialog there runs under the session lease with a live login. NodeLink is blocked, and the node closes an idle login after 300 s (op_session.dart:9-10).
- The old code shows it between two `_ask` calls with `_busy` released (nodes.dart:1567-1572).

**Fix:** decide before `once`, from the node's last `StatusView.netId` and `NetIndex` (net vs mnet). Fall back to asking inside, and say so.

### m8. 8.4 without a removal: `removeOwnNodes` needs a target.
- `target_of` refuses when both `person` and `node` are empty, or both are set (rekey.rs bridge:37-43). `remove_own_nodes` calls it (:109-114).
- The 「產生更新包」 path into 8.4 has no person and no node. The plan does not say what it passes.
- Passing the leader's own `owner` as `person` works, because only `precheck` refuses `SelfPerson`, and `own_nodes` filters only `Target::Node`. That should still be written down and tested.

### m9. The 60 s revoke reuses a banner whose text is wrong for an offline operation.
- home_page.dart:303-305: 「…請到那台節點的頁面看目前的狀態…」.
- `OfflineOp` work touches no node.
- **Fix:** give the banner a no-node variant (「請到隊伍與邀請再看一次」), or let `OfflineOp` add its own todo text.

### m10. Who owns the hint's condition 2.
NodeLink (the prober) would read `NetIndex`, but PR 3's D4 header says NodeLink never touches it (net_index.dart:5). It is a read, but state it in 3.1 as an injected read-only callback (`hasNet(netId)`), the same way `openNet` is injected, so the layering rule is not silently broken.

### m11. `NetFormPage`'s `noneOpens` check runs before the new mnet branch.
- net_pages.dart:345-351 returns the T8 page whenever `netFiles > 0 && nets.isEmpty`.
- A phone with an unopenable net file and a good mnet therefore gets 「手機裡沒有可用的網路紀錄」 from the node page's 加入網路, even on the mnet entry node.
- The member join is then reachable only through 隊伍與邀請.
- **Fix:** route the member branch before the T8 check when the node is the mnet entry node.

## Verdict

**APPROVE-WITH-CHANGES.**
- Fix M1 by dropping skip, or redefining it as "stop and check with what was read" with a negative control.
- Fold in m1-m11 as wording or small changes.
- No BLOCKER.
- §2.9 is complete for the old console's member buttons. The one missed entry is the new-UI 3.6 button (m6).
