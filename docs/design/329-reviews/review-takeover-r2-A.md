# Review r2-A — 329-takeover.md v2 (whole document)

Reviewer A, round 2, independent. Design at 511c472, source read in worktree `C:\src\Batman-a2` (based on main
99d156a). Read-only: no test run, no device, no git change.

Marks: ✅ = read in source at the cited line; ⚠️ = inferred (the design does not say, or it depends on how it is
written); ❌ = not done.

Baseline documents were not re-reviewed. The product decision in §1.3 is not argued; only its consistency is checked.

## Findings

### 1. MAJOR — the (b) wait applies to every session `acquire` made on the node page, also to callers that never log in to that node

`acquire(name, kind)` has no node id (`node_link.dart:352`) ✅. The design's condition is "kind == session and an
attempt `a` with `_link != null` and `wanted(a)`", and `wanted` only looks at `core.page / pageNode`. §1.1 and the
matrix describe the caller as "the sub-page that is then lent the parked link". These session callers run while
`core.page == node X` (they never call `setPage`, §5) and do not use a link to X:

| Caller | Evidence ✅ | What it does under the lease |
|---|---|---|
| 「更多」→「移除節點」 | `more_pages.dart:84` | record write only (`keepCopy`, `remove`), no login |
| 「隊員名單」→ MembersPage and the pages under it | `node_page.dart:158–160`; `team_deps.dart:24`; `offline_op.dart:118`; `team_pages.dart:219, 402`, `join_pages.dart:275, 428, 624`, `remove_pages.dart:128, 307` | `OfflineOp.run`: record work, no login |
| the remove flow's reads of *other* nodes | `remove_pages.dart:102` (`OpSession.once(teamDeps(a).op, o.deviceId, …)`) | logs in to node Y while the page is still node X |
| dev 「忘記加入」 | `dev_pages.dart:459` | no login to X |

Scenario: node page of 04 still connecting → 「更多」→「移除節點」→ confirm. Today the lease is given at once. After the
change the removal waits for 04's attempt (typically 1.5–4.5 s, up to 8 s, and up to 8 s on every such tap when a
device answers on 04's old address), the attempt's body is recorded and its link parked, and then the record it
belongs to is deleted. In the remove flow each read of another node can wait again for X's attempt, because the
node page's round starts again after each lease.

None of these has a matrix row or a test; the row "session lease from another page: abort" is true only for pages
that changed `core.page`.

Fix: the caller says which node it will log in to. `acquire(name, kind, {String? forNode})`; wait only when
`forNode == a.id`. `OpSession.once` and `OpenSession.open` pass their `id`; every other caller gets today's
`_abort()` path unchanged. Add a test: session `acquire` without `forNode` (and with another node's id) on the node
page mid-attempt → no wait, aborted (negative control: fails with the v2 condition).

### 2. MAJOR — a superseded waiter gets a plain null; only `OpSession.once` is told what to do with it. Double tap on 「軟體更新」 shows 「另一個操作還在進行：」 with an empty name

`OpenSession.open` returns right after `acquire`, with no login (`op_session.dart:148–151`) ✅, and the update page
is pushed only after it returns (`update_route.dart:28–37`) ✅. `_update` has no re-entry guard
(`node_page.dart:54–57, 256`) ✅.

Scenario: node page of 04 connecting → tap 「軟體更新」. Nothing changes on screen during the wait (today the page
opens after the abort). The user taps again after 2 s. The second `acquire` reaches the wait and takes the
generation; the first wakes, sees another generation, returns null. `openSwUpdate`: context still mounted, `s ==
null` → SnackBar 「另一個操作還在進行：${a.reg.current?.name ?? ''}」 (`update_route.dart:33–36`) ✅ — `reg.current` is
still null (the second call has not reached `reg.acquire`), so the name is empty; then the update page opens from
the second call. The same for tap 「軟體更新」 then 「手機 Wi-Fi」 within the wait (the snackbar appears over the Wi-Fi
page).

§5's last row gives exactly this as the reason a superseded waiter must not end as busy, but the design changes
only `OpSession.once`. The other readers of a null lease all print the busy line: `update_route.dart:33`,
`more_pages.dart:86–88`, `offline_op.dart:119` (`OfflineBusy(busyName ?? '')`), `net_pages.dart:271, 342, 917`,
`dev_pages.dart:459` ✅. And in `OpSession.once` a superseded waiter whose page is still mounted (`gone()` false)
still ends as `OpEnd.busy` with `busyName()` possibly empty (`settings_pages.dart:27, 41`).

Also unstated: an `acquire` that does not wait (raw, or a session call after fix 1) arriving during a wait does not
change the generation. It aborts the attempt, `_ended` completes, the waiter wakes with its own generation and both
run to `reg.acquire` (`node_link.dart:360–374`). That is today's race between two concurrent `acquire` calls (the
loser gets null with the winner's name), so it is acceptable, but §3's `_waitGen` row should say it.

Fix (smallest): with fix 1 only `OpSession.once` / `OpenSession.open` can wait. Let the superseded waiter be
distinguishable (for example `acquire` completes with null and NodeLink exposes nothing; instead the two callers
pass a `gone` callback or receive a sealed result `superseded`), and specify: `OpSession.once` → `OpEnd.gone`
regardless of `gone()`; `OpenSession.open` → a third result on which `openSwUpdate` returns silently. Add a
re-entry guard to `NodePage._update` (it is the only waiter with no page on screen). Tests: O3 `OpenSession.open`
superseded → no snackbar; widget test double tap on `node-update` during the wait → one update page, no busy line
(negative control: fails with v2 as written).

### 3. MINOR — what a detached result does not do in the core is not stated; the round can attempt the same address at once

`core.result` sets `r.freeAt[a.addr] = now + p.gap` (6 s) and the per-address count (`core.dart:523–527`) ✅;
`core.keptRead` does neither, and for an error code sets `t.err` with no retry (`core.dart:603–620`) ✅; a detached
no-response / refusal records nothing at all. So after a detached failure `_run`'s tail `_pump()`
(`node_link.dart:1057`) can start the round's attempt to the same address in the same tick, and the node can get
three logins in one round (detached + `perAddr` 2). Not worse than today's cancel-and-reconnect, but the matrix row
"the round's own attempt follows" and T12 should state and assert it (connect count, no 6 s gap). Also state that a
detached `certRejected` (identity) is dropped and shown one attempt later (fail-secure).

### 4. MINOR — "`_abort()` is a no-op when the attempt ended" is not always true; `_ended` completes after the tail `_pump()`

With `_ended` completed in a `finally` around `_run`'s body, the tail `_pump()` (`node_link.dart:1057`) runs first
and can start the next attempt (`:928–931`) when the waited attempt failed and another address is free. `acquire`
then wakes, and its `_abort()` cuts that new attempt and `_dropAll` waits for its link to go (up to `closeMax`).
Also `await mine?.close()` (`:1034`) sits before the end, so a failed attempt's `_ended` comes after the close.
Both are inside the 8 s timer. Fix: complete `_ended` before the tail `_pump()` (or have `_pump` start nothing
while a waiter is pending), and let T5 assert "no connect starts between the attempt's end and the lease".

### 5. MINOR — `dispose` during the wait, and the 8 s timer, are not covered

`acquire` has no `_disposed` check (`node_link.dart:352–380`) ✅. `dispose` → `_dropAll` → `_abort` → `_ended` → the
waiter goes on to `core.acquireLease` and `reg.acquire` on a disposed NodeLink. Harmless today (`loginFor` returns
`noLease` when disposed, `:414`), but the waiter should return null. The 8 s `after` timer must be cancelled when
`_ended` wins and at `dispose`. §4's `dispose` row and T11 cover only the detached state; add "dispose during the
wait".

### 6. MINOR — §1.3: callers, documents and one home widget the place table does not name

- `nodeRowWords` returns a 3-tuple destructured at `home_page.dart:414` and `node_page.dart:208`, and read by index
  at `net_pages.dart:548` and in tests (`home_logic_test.dart:116–202`, `pages_test.dart:385–388`,
  `retest_h_core_test.dart:71`) ✅. The table names only the home row. State that the node page ignores `hint` (the
  full line is already there, `node_page.dart:213`) and that `NodeRow` (`widgets.dart:186–196`) gets the new line.
- `home_page.dart:361`: `HomeTipCard` is shown when `h.row == 14` ✅; `329-app-uiux.md:716` ties it to the first
  「一切正常」 home. The new rule-14 variant keeps row 14, so the tip appears on a home that carries a reminder.
  Decide (suggest: only without a note) and add it to H1.
- `329-app-uiux.md:682` (§5.1 table, row 14: 「一切正常，可以使用」, no action) is not in the list of documents
  edited ✅.
- `329-honest-errors.md:158` is not a rule: it says C4's device check could not be done because 02 was in the F1
  state ✅. The rule being superseded is the row-12 condition (`329-app-uiux.md` §5.1 / `home_logic.dart:155`). Edit
  :158 as "C4 can now be checked on the device", not as a reversed decision.
- The new variant has a button (`seeNode` / `showList`); plain rule 14 has none (`home_logic.dart:171`). The steady
  height of C4 (`widgets.dart:104–107`) is then different between the two green states; say so and add the variant
  to the home size matrices (`layout_test`, `retest_p_layout_test`).
- `rust/bridge/src/api/owner.rs:2792` asserts an empty warning for a not-joined node ✅; it does not change. A bridge
  test for `note` (joined + k2 = 2 → `warning == ""`, `note` set) is missing from §7.
- `member_ui.dart:186, 205` are the field's declaration only; the one place that fills it is
  `more_pages.dart:192` ✅.

### 7. MINOR — §1.2 details

- "`drop(id)` right before any set is sent": in `WifiPage._send` the request closure can end as `notSent`, and the
  login can fail before anything is sent (`settings_pages.dart:148–157`) ✅. Say where the drop is (inside the
  closure, right before `c.setAp` / `c.setCountry`), or accept that a set never sent also forgets the label.
- A `SettingsView` with `read == true` and an empty `country` is possible (`settings_pages.dart:300` guards it) ✅:
  the country label must not show 「（確認中…）」 with nothing before it. Same for an empty name.
- One entry serves both pages (a Wi-Fi read primes the country label). Fine; say it, and W3 should use it.
- A node removed and claimed again in the same app run keeps its entry ("pages open only for nodes with a record"
  does not cover that). The label is marked 「確認中」 / 「上次讀到」, so only state it.

### 8. MINOR — two citations

- §1.1 "only target (`core.dart:255`)": :255 is `earlyDue = null`; the targets are `_pageTargets` (:218) and
  `_begin` at :258 ✅ (§5's `:244–258` is right).
- §1.1 `wanted(a)` does not ask "the active round has `a.id` as a target". When it does not, `keptRead` returns
  false and the detached attempt held the radio for nothing. ⚠️ By the limits (attempt ≤ 8 s + 20 s + 2 s from its
  start; window 30 s from the later page entry, `core.dart:9–19`) the round does not end first, but the margin is
  not stated. Either add the round check to `wanted` or state the bound.

## Round-1 answers (§9) — checked against v2 ✅

A1/B11 (own text, action, count, fresh only), A2/B12/B13 (readers, text unchanged, note only without a warning),
A3/B1/B2 (wait before `core.acquireLease`; park condition = :1051 with `taken`), A4/B8 (label only, `drop` before a
set), A5/B5 (`_ended` in `_abort` and `finally`; `_det` by identity; T16), A6/B3 (own timer; connect started),
A7/B4 (detach only in `setPage`; T14), A8/B9 (one object, two callers), A9 (facts corrected), B6/B7 (rows added):
each is in the text and consistent with the source. Open remainder of A3(c) is finding 2; of A2 is finding 6.

## Checked, no finding ✅

- Every §5 row and every file:line in §0–§3 except the two in finding 8: `core.dart:244–258, 285–290, 603–625`;
  `node_link.dart:303–311, 352–380, 446–452, 639, 644, 716–735, 900, 911, 928, 994–1058, 1060–1069`; `_abort()`
  call sites are exactly :369, :900 and `_dropAll`; `ble_gate.dart:195, 302–309`; `prober.dart:129–132, 233`;
  `settings_pages.dart:27, 41, 126, 133, 182, 295, 307–314`; `owner.dart:570, 628`; `statuspage.rs:125, 314–336`;
  `tests/statuspage.rs:305, 390`; `owner.rs:461, 2579`; `home_logic.dart:155, 158, 171, 179`; `setPage` callers as
  listed; the grep for 「節點回報異常」 (source, its test, the two documents; plus this design and r1-B).
- Interleavings traced: `setPage` X → home → X (second call sees `wanted` false, `_pump` aborts, `_det` cleared);
  `setPage` to another node; same-page `setPage` (`core.dart:245` returns early); attempt end and the 8 s timer in
  one tick (either order: parked or destroyed, `:1036–1038`); `acquire` during `_releasing` (no attempt while the
  lease is held); `reg.current` set during the wait (the repeated check returns null with the holder's name); a
  detached attempt whose round a lease cancels (`keptRead` false → destroyed); kept link already present (no
  attempt to that node, no wait); page left / background / Bluetooth off during the wait (`_pump` → `_abort` →
  `_ended`).
- A parked link has token null: not counted by `_dropAll`'s wait, not closed by `gate.revoked`. `keepFor`
  (`node_link.dart:113–119`) has no page condition, so a home-round attempt can return `keep`.
- Security: no new input; a failed or foreign login parks and records nothing; the passphrase stays in `_pass`,
  cleared before the request (`settings_pages.dart:150–151`), never in the memo; note and warning are constants.
  The remembered value is the SSID and country only.
- The look remembered across runs (`home_page.dart:173–186`, from `s.view`) is 'ok' for this state today as well:
  no change.

## Not done ❌

No test was run and nothing was tried on a device; whether T1–T16 can be written with the fakes in
`test/nodelink/sim.dart` was not checked. The reproduction log in §0 was not opened.

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 2 MAJOR (1, 2), 6 MINOR. Both MAJOR have one small fix in common (the caller
names its node; only those callers wait). Revise and review the whole document again before implementation.
