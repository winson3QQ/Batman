# Review G: #329 PR 5 plan v4 (round 4)

Reviewer G. Focus: consistency with source and baseline, field behaviour, lifecycle, ownership, contracts, faithful moves, completeness of the §2.9 table. Worktree `C:/src/Batman-329pr5` @ 2e18de6 (plus the uncommitted QrScanActivity.kt resolution change). Read-only. I did not re-review the baseline items listed in §0.

## Summary

0 BLOCKER / 1 MAJOR / 10 MINOR. Verdict: **APPROVE-WITH-CHANGES**.

The MAJOR: the v4 ordering "提示在 done 之後才算" races with the prober's own cleanup, which disposes the Rust session. As written, `update_hint` would run on a disposed `OwnerSession` on every real read. The resulting exception is swallowed, so the hint card never appears in the field. That means D-M1 / E-M1 are still not closed in practice. The planned T-P5-H test, which uses a fake session, cannot catch this.

## Rounds 1–3 MAJORs, checked against source

| Item | Status | Evidence |
|---|---|---|
| A-M1 / B-M1 (send entry) | Closed. The permanent entry is in 更多; 8.4 has its own-node section. | nodes.dart:1745, 1546-1563; plan 2.6-10, 2.7 |
| A-M2 (隊員 entry without own node) | Closed. The entry is on the settings page and depends on the net record. | plan 2.6, 2.9 |
| A-M3 / B-M2 (QR size) | Closed. The rule uses the encoder's version ≤ 27; paste has no 4096 cap. | QrDecode.kt:18, :42 |
| C-M1 / D-M3 (8.4 reachable) | Closed. The 2.9 row covers it. | nodes.dart:1751, 1450-1454 |
| C-M2 (7.8 permanent) | Closed. | nodes.dart:1759; home_logic.dart:95-99 |
| D-M2 (fingerprint / same name) | Closed. Dart compares the full owner. | rekey.rs:95-98 (Rust compares fpr) |
| **D-M1 / E-M1 (hint computed and shown)** | **Placement closed (node_page.dart:79-87, 128-135 support a card under StatusHero). The computation itself is still broken: see M-1.** | prober.dart:122-127, 190-205 |
| E-M2 (mnet-only 加入網路) | Closed. There is a caveat about non-entry nodes, see m-3. | node_page.dart:81; net_pages.dart:352-360 |
| F-M1 (8.4 lists from the record) | Closed. There is a mapping detail, see m-4. | rekey.rs:47-98 |

## §2.9 completeness against nodes.dart:1733-1770

I went through every control in that range:

| Control | Covered |
|---|---|
| 加入網路 `_join` (member branch → `_memberJoin`) | Yes |
| 檢查網路 | PR 3, not a member button |
| 忘記加入中的節點 `_forgetOrExclude` | Yes, with the 排除 row added in v4 |
| 狀態頁 hint + `_sendFromPage` | Yes |
| 把新密碼送給節點 | Yes |
| 隊員名單／移除 | Yes |
| 產生更新包 | Yes |
| 貼上更新包 | Yes |
| 邀請隊員 | Yes |
| 貼上隊員的申請 | Yes |
| 貼上邀請 | Yes |
| 貼上同意碼 | Yes |
| 申請加入 | Yes |
| 再顯示申請 | Yes |
| 軟體更新 | PR 4 |

Behaviours hidden inside the dialogs are also covered:
- `_members`: 移除這個人 / 排除 per own node, nodes.dart:1336-1339.
- `_checkRequest`: previous / updateFirst, :829-835.
- `_takeApproval`: the replace dialog, :969-976.
- `_memberJoin`: `_sendAfter` and `_watchLink`, :1056-1061.

The status page's team section (`teamView`) belongs to PR 6. **Nothing is missing from the table.** Its text has stale cells, see m-1.

---

## MAJOR

### M-1. The hint is computed after `done()` while the prober disposes the session, so it never shows on a real read

**Scenario.** A team leader removes a member and hands out the update bundles. One of the leader's own nodes keeps the old secrets: it was out of range when 8.4 was used, or the app was killed before 8.4. Later the leader opens that node's page, and NodeLink reads it.

Plan 2.3 v4 computes the hint in the `answer` step after `done(Outcome(...))`:
1. `openNet('net/<id>')`, which is async: `storeReadSealed` plus the Keystore `open` over the platform channel;
2. then `session.updateHint(...)`.

**Evidence.**
- prober.dart:122-127: `done(...)` completes `result`.
- prober.dart:188-205: `probe()` resumes at `final o = await result.future;` on the next microtask. It then runs `answer?.cancel()`, `inbox.handle(null,null)`, `await sub?.cancel()`, and `s?.dispose()`.
- The hint code yields at its first `await openNet(...)`. A platform-channel round trip takes far longer than the cancel/dispose sequence, so the `OwnerSession` (an FRB opaque) is disposed before `updateHint` runs. A flutter_rust_bridge opaque used after dispose throws. The plan's try/catch then turns that into "這一輪沒有提示", every round.
- Result: the card added for E-M1 and the D-M1 rule (remove-member §3.5, :184-185, T7 / T7b) never appear in the field. The node stays on the old secrets, so the removed person can still reach the mesh through it. No visible prompt says so (fail-open).
- The 8.4 banner only exists while 8.4 is open in this run (it is memory only), so it does not cover the "app restarted / later" case. In that case the hint is the only reminder.
- T-P5-H uses a fake session that does not model dispose, so it passes either way. The planned negative control ("不呼叫 updateHint → FAIL") does not test this ordering.

**Fix.** Keep "deliver the read first", but keep the session alive until the hint is done:
- In the `answer` case, call `done(...)` first, then start `hintFut = _hint(session, v)`, which catches everything itself.
- In `probe()`'s cleanup, before `s?.dispose()`, `await hintFut.timeout(2 s, onTimeout: ...)`. The read outcome has already been returned through `result` and does not change.

Alternatively, copy what `update_hint` needs (`page_info` and the node) out of the session before `done`. That would need a Rust change, so the first option is preferred.

Add a white-box test with a fake session whose `updateHint` throws after `dispose()`, and an `openNet` that takes one event-loop turn:
- with the current v4 ordering → no hint → **FAIL**;
- with the fix → hint present → PASS.

Also state that the BLE link and session stay open for up to 2 s longer per read. That is acceptable, but NodeLink's round timing should know about it.

---

## MINOR

### m-1. Stale text still puts the hint and the 8.5 entry in the 「網路」 group

v4 moved both out of that group (2.7, E-M1), because the group is only drawn for nodes that are not in a network (node_page.dart:79-87). The following places still say otherwise:
- §0 item 8: 「節點頁的換密碼提示行」 and 「網路分組的「貼上隊長給的新密碼」」.
- 2.6 item 14: 「入口（v2，A-M1）：節點頁網路分組常駐一列」.
- The 2.9 rows 「貼上更新包 … 其他捷徑：節點頁網路分組」 and 「狀態頁（:1744）的換密碼提示 → 節點頁網路分組的提示行」.

An implementer who follows the table, which the plan calls the authoritative list, would reintroduce E-M1. **Fix:** change all four to "the card under StatusHero" or "更多".

### m-2. The `hints` map: contract gaps

The plan does not say:
- (a) that `onHint` fires `link.changed`. NodePage only rebuilds on `changed` (node_page.dart:38). Since the hint arrives after the outcome's own notify, without this the card shows up a full read late (60 s);
- (b) whether a round whose hint is skipped (timeout, exception, devTrust off, no record) clears the previous entry or keeps it;
- (c) that an `onHint` for an id that is no longer in `core.states` (forgotten between `done` and the hint) is dropped, not re-added.

Also, the old `_sendFromPage` re-reads the page right after sending (nodes.dart:1140-1141). After the card's 「把新密碼送給節點」 succeeds, call `link.refresh()` for that node. Otherwise the stale 「這台還在舊密碼」 card stays for up to 60 s and invites a second send.

### m-3. Member-mode 「加入網路」 is offered on nodes where Rust always refuses it

Rust's member mode only succeeds on the node the mnet's secrets are for. See join2flow.rs:77, "member c: the mnet's secrets are for another node than this login's"; mrec `me` is a single entry.

With 2.7's new condition `nodeState == 1 && (netFiles > 0 || mnets.isNotEmpty)`, every unjoined node of a member phone shows the button. On a non-entry node it always fails after a login. Two related problems:
- D10's sentence 「要用別台，從節點頁…和舊程式一樣任選」 is inaccurate: any other node is refused.
- Home row 6 names node X (`notIn.first`) but member mode acts on the entry node.

**Fix:** in member mode, show the button only on the `memberEntryOf` node (member_ui.dart:256). On other nodes, show a one-line reason, for example 「這台不是你申請加入的那台」. Correct D10.

### m-4. 8.4 own-node mapping: specify the source

2.6-10 matches `PersonNode.last4` with 「device_id 後四碼」 plus 「讀回的 dacHash」 and does not say where the dacHash comes from. `NetIndex` already holds `MemberView.deviceId` (full) and `dacHash` per member (owner.rs:84, :89; net_index.dart:149-152). Map with the full device_id and the dacHash from the record. Then verify after login with `c.nodeDacHash()` (owner.rs:1033), as net_run.dart:388 does. last4 is only 16 bits.

### m-5. `NetIndex.mnets` keeps only openable records, but some checks need the listed ids

The ids are listed in net_index.dart:146, but only the records that open go into `mnets`. The checks disagree:
- home `records` uses `anyMnet` (the listed files);
- the node-page condition in 2.7 uses `mnets.isNotEmpty` (the opened ones);
- the mpend todo's "沒有同一個 netid 的 mnet" uses the opened ones.

So an mnet whose record does not open makes home offer 加入網路 while the node page does not. It also makes the todo say 「還在等」 for a network that was already imported. **Fix:** keep `mnetIds` (listed) separately and use it for the existence checks.

### m-6. `AppLink.devTrust` is read asynchronously; no default is stated

`AppLink.create` is synchronous (app_link.dart:65), so devTrust arrives later. State that it is `false` until the platform answers, so the entries stay hidden in the meantime (fail-closed). The only gate on 「把新密碼送給節點」 is in Dart (owner.rs:1041 has no `dev_gate`), so this default matters.

### m-7. The 60 s cap's line can be wrong

`RecordWriter` checks the lease only before awaiting the store (record_writer.dart:38-42). A `writeCas` that started before the cap still lands, yet the page says 「沒有完成，請再試一次」.

The retries are mostly safe:
- a duplicate approve hits `showDupNote`;
- a second remove gets Rust's NoTarget;
- a leftover mpend is covered by the A-m6 todo rule.

The sentence itself is still untrue. **Fix:** use 「可能沒有完成：請看目前狀態再決定要不要再做一次」, the same idea as `unsavedTodos` (lease.dart:139).

### m-8. The ownership table (§3.1) is missing resources

It lacks:
- `NodeLink.hints`: the writer is NodeLink via `onHint`; it is cleared on forget; NodePage reads it.
- `AppLink.devTrust`: written once at start.
- The new `NetIndex` fields: the writer is NetIndex's recompute.
- The 8.4 「已送出」 state: say whether it lives on the page or in the app. If it lives on the page, re-entering 8.4 shows N again. That is the safe direction, but it should be stated.

### m-9. Entering 8.3 now logs in to every own node, including unreachable ones

The old code read only the own nodes seen in the current scan (nodes.dart:1361, `_nodes.contains`). The plan runs one `OpSession.once` per own node from the record. Each unreachable node costs a full login timeout before the confirmation can appear. For a leader with a far relay, that can be tens of seconds.

**Fix:** state the per-node bound. Show progress (「正在讀節點 …x」, as the old :1362 did) and give each pending read a 「略過這台」. Rust treats a skipped node as "not checked", which is already the rule for an unreadable node.

### m-10. joinreq: where `mpend` is read

The old code read `mpend/<id>` before the request (nodes.dart:884). The plan's `joinreq(inviteHex, name, pend)` does not say whether the page reads it before `OpSession.once` or the request reads it under the lease. The CAS (`pend_gen`) makes either correct. Say "read inside the requests callback, under the lease", so that a pend written by a concurrent 放棄申請 cannot make the step fail with a confusing line.

---

## Other checks (no finding)

- **SecureScreen.** It is ref-counted (secure_screen.dart:22-37), so stacking 7.5 → 7.6 keeps the flag on. The `false` branch already shows a line, so the default behaviour of the `fallback` parameter is as claimed.
- **minSdk 31** (build.gradle.kts:39), so `clearPrimaryClip` (API 28) always works. `EXTRA_IS_SENSITIVE` is a compile-time string constant and harmless below API 33.
- **The 60 s cap and PopScope** are compatible with `Lease.hold()` / `release()` (lease.dart:66-77, 92-97). A late `hold` callback after `release()` does nothing.
- **Admin signing needs no user prompt** (KeyHandlers.kt:54; no BiometricPrompt), so 60 s is generous.
- **Record writes are atomic** (temp file + rename, store.rs:127), so the hint's unlocked read of `net/` while a flow writes it cannot see a torn file.
- **8.2 排除 on a joining own node.** The node is in `net_people` (rekey.rs:72-79). `precheck` ignores the joining state of the excluded node itself (batman-proto rekey.rs:114-116), so the v4 2.9 row works as described.
- **`request_send_update` has no `dev_gate`** (owner.rs:1041). The plan's T-S5 point is correct.
- **`update_hint_of` returns `NOT_LISTED`** for an admin node missing from key 11 regardless of version (rekey.rs:489-492). So the card can also appear for a node that is not behind. That is baseline behaviour; the card just shows Rust's line, which is correct.
