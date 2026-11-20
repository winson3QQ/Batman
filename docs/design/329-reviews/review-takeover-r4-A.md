# Review r4-A: `329-takeover.md` v4 (3ab7e4b)

Reviewer A, round 4, independent. Whole document reviewed against main 99d156a (`app/`), `docs/design/REVIEW.md`,
and the two captures in `Desktop\Batman\a1\`. Read-only: no device, node, adb, flutter or git state was touched.
Baseline documents and the three product decisions were not re-reviewed.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 0 MAJOR, 7 MINOR.**
All seven are text or test-wording fixes; none changes the mechanism. No further whole-document round is required
by the rules (no BLOCKER / MAJOR open).

## 1. What was checked and holds

Method: read `node_link.dart`, `core.dart`, `ble_gate.dart`, `prober.dart`, `op_session.dart`, `settings_pages.dart`,
`home_logic.dart`, `statuspage.rs` and its tests in full or at every cited line, then traced the proposed changes
by hand over the existing code. "Holds" below means traced on source, not run.

Interleavings traced (`_run`, `_abort`, `_pump`, `setPage`, `acquire`):

- Detach in `setPage` (`node_link.dart:303`) plus the line-900 condition
  `a != null && !identical(core.running, a) && !(identical(_det, a) && wanted(a))`: a detached attempt survives the
  round change only while `wanted`; page left, background, radio blocked, record removed each make `wanted` false
  and the next `_pump` aborts it. No path found where `_det` stays set after its attempt ended (identity compare,
  cleared in `_run`'s end for that attempt only).
- A late end of an aborted attempt A after attempt B was detached: the per-attempt `ended` and the identity check
  keep B detached and B's waiter waiting (T17 is the right test; its mutation does fail).
- Waiter placed before `core.acquireLease` (`core.dart:285–290`): the lease is never given while the awaited
  attempt holds the link; after the wake `acquire` runs today's path (`_abort()` at `:369` is then a no-op or
  aborts a newer attempt, which is today's behaviour).
- Double completion: `ended` is completed in `_run` and, as backstop, in `finally`, and by `_abort`; all guarded by
  `isCompleted` per the design. One waiter only; a second `acquire(forNode)` during a wait takes today's path and
  `reg.acquire` arbitrates as on main.
- Leaks: the waiter's 8 s timer is stopped on wake; `dispose` aborts and wakes; a parked link survives
  `_dropAll` (`:1071`) / `gate.revoked` (`ble_gate.dart:302–309` closes only links with the identical token).
- Fail-secure: a detached attempt's non-body outcome (cert rejected, refused, no response) records nothing through
  `core.keptRead` (`core.dart:603–626`); the round's own attempt records it. A failed login on the taken link parks
  nothing.

Cites verified against source (all correct unless listed in m6): `node_link.dart` 303, 352, 360, 369, 446–452, 639,
644, 716–735, 893, 900, 994–1057, 1060–1069, 1071; `core.dart` 216–220, 244–265, 285–290, 472–489, 523, 594, 603–626;
`ble_gate.dart` 195, 302–309; `prober.dart` 129–132, 233; `op_session.dart` 94, 150; `settings_pages.dart` 25–37, 41,
126, 133, 148, 156, 182, 295, 307–314, 326, 340; `home_logic.dart` 155, 158, 171, 179; `home_page.dart` 361, 414;
`node_page.dart` 208, 213; `net_pages.dart` 548; `more_pages.dart` 84, 192, 211, 258, 313; `member_ui.dart` 186, 205;
`widgets.dart` 30–36, 133, 162; `app_link.dart:80`; `owner.dart` 570–574, 616, 630; `dev_pages.dart` 183, 274, 459;
`join_pages.dart` 117, 721; `rekey_send.dart` 112, 139; `remove_pages.dart` 102; `offline_op.dart` 118;
`raw_use.dart` 74, 88; `statuspage.rs` 111, 122–125, 314, 333; `owner.rs` 461, 2579, 2792;
`254-app-status-page.md` 28, 60, 73; `329-app-uiux.md` 682, 716, 976; `329-honest-errors.md` 14, 158. The two grep
claims (`setPage` callers; `acquire` / `once` callers; 「節點回報異常」 only in `statuspage.rs`, its tests and docs)
reproduce. `test/ui/home_steady_test.dart` exists.

§0 against the captures — every number is in the files:

- Row 1 (`a2-step1`): `noResponse after 736ms` 12:21:13.530, `1696ms` 12:23:00.864, `2201ms` 12:23:37.418; a second
  `connect()` to 04 after each; 11 `result=body after …ms` lines, 2907–4802 ms.
- Row 2 (`a2-repro`): 3.5 s, 6.1 s, 4.0 s; round 32 cancelled 11:47:28.144 → body 11:47:53.851 = 25.7 s; the quoted
  `11:47:27.135 attempt …5A×…880c connected=1633ms result=noResponse after 2163ms` line; first `connect()` to 04 at
  11:47:40.775. `grep -c "kept link"` is 0 in both files.

Not verified (no access under the review's constraints): the "about 0.1 s" figure cited from the PR #366 body. It
is used only as an expectation, and D2's pass limit (1 s) does not depend on it.

Lifecycle (REVIEW.md item 3): the matrix covers tap mid-connect, Back, background, radio off, record removed,
`refresh`, round end, cap, app restart (memo and note are memory-only / not fresh), second phone (label marked
unconfirmed, value confirmed by the read). Node-side rows (boot, OTA, boards) do not apply: no node change. No
missing resource found in the ownership table (`_det`, `ended`, `_waiter`, the 8 s timer, `SettingsMemo`, `note`
each have one writer).

Security (item 5): no new input from the radio; the detached path takes less than the round's path (body only);
the memo holds no passphrase (`owner.dart:573–574`) and is a label that a read always replaces; a spoofing device
costs bounded time and records nothing. Negative tests T10–T12 exist. Nothing to add.

## 2. Findings

### m1 (MINOR, a negative control that cannot fail) — T18

Scenario: T18 says it "fails if `ended` is completed only after the tail pump has started the next attempt".
`acquire` wakes from `ended.future` in a microtask. `_run` completes `ended` and calls the tail `_pump()`
(`node_link.dart:1057`) in the same synchronous run, so the waiter's continuation always runs after the tail pump,
in either order. And in T18's own scenario (the node page's one-target round ends with a body) the tail pump starts
no next attempt at all. The mutation therefore passes T18, and §"contracts" (`ended` … "before its tail
`_pump()`") states an order that has no observable effect.

Evidence: `node_link.dart:1051–1057` (no `await` between the park and the tail pump); Dart `Completer` listeners are
asynchronous unless `Completer.sync` is used.

Fix (text only): drop the order claim and T18's "fails if", or keep T18 as a plain behaviour test (state recorded,
link parked, one connect) with a mutation that does fail, e.g. "`ended` is not completed on the normal path, only
by the 8 s timer" (the test then sees an 8 s wait). What happens when the tail pump does start a next attempt
(non-body result with retries left) is already T5c: `acquire` aborts it, no second wait.

### m2 (MINOR, device criterion wording) — D1 "the next round logs `kept …7d2c`"

Scenario: the detached take enters through `core.keptRead`, which itself logs `kept …7d2c -> body` (`core.dart:623`)
in the page's round whether or not the link was then parked. A grep for `kept …7d2c` after the tap passes even if
`_park` destroyed the session.

Fix: state the criterion as "a `kept …7d2c -> body` line after a later `round N` line, with no `connect()` to 04
between" (as at 11:48:50.516 in the repro capture, round 38).

### m3 (MINOR, unstated edge) — `gone = () => !mounted` during the pop transition

Scenario: 「手機 Wi-Fi」 → Back → 「國家」 tapped while the route's pop animation still runs. The Wi-Fi page's `State`
is not disposed until the transition ends, so `gone()` is still false; the waiter for 「手機 Wi-Fi」 is not released
and 「國家」 gets 「另一個操作還在進行：手機 Wi-Fi」, as on main. (Inferred from Flutter's route lifecycle; not checked on
a device.) D5 says "within 1 s" with no lower bound, so a fast scripted tap can land in that window and fail a
correct build.

Fix: say in 1.1 that this window behaves as today, and give D5 a tap delay after Back (e.g. ≥ 0.5 s) or accept the
busy line as a pass inside the transition.

### m4 (MINOR, cost statement) — the 8 s timer can cut an attempt that is already logged in

Scenario: a slow connect reaches msg2 at 7 s; the prober's answer limit is another 20 s (`prober.dart:233`). At 8 s
the waiter's timer runs `_abort()` on an attempt that is past the login and reading, and the sub-page logs in from
the start. Not worse than main (main aborts at once), but 1.1's cost line reads as if 8 s were always enough.

Fix: one sentence in 1.1: "the 8 s can end an attempt that has logged in and is still reading; then today's path".

### m5 (MINOR) — T14c reachability

The page's round ending at its 30 s window while a detached attempt still runs needs an attempt older than the
attempt's own bounds allow in normal runs (≤ 6 s room + 8 s + 20 s, started in the earlier round). Mark it
defensive, as T9 already is, so nobody looks for it on a device.

### m6 (MINOR) — cite and wording slips

- `tests/statuspage.rs:305–307`: the lines that pin the text are 303–305; 307 asserts `None` for plinks 0 and does
  not change.
- §0: "phone clock 12:22–12:25"; the `a2-step1` lines run 12:21:00–12:24:42.
- `op_session.dart:68` is the comment; the `acquire` field is `:69`.
- `app_link.dart` is `lib/src/nodelink/app_link.dart`, `member_ui.dart` is `lib/member_ui.dart` (bare names are
  unambiguous; listed for completeness).

### m7 (MINOR, unstated behaviour change) — O2 applies to every `once` caller

Today a `once` whose page closed before the lease logs in and only then sees `gone` (`op_session.dart:112`). O2
(release at once) changes that for all eleven callers, not only the two settings pages. It is harmless (less radio
work, same `OpEnd.gone`), but the matrix row names only "page closed before a lease given without a wait"; add
"all `once` callers" so the code review does not read it as out of scope.

## 3. Negative controls

T1–T17, O1–O2, W1–W6, H1–H7, R1: each names a mutation or fails on main; checked one by one against the code they
guard. T18: see m1. Device: D1 / D2 / D3 / D7 have a captured failing state (§0, `a1-home-c1.png`, main APK); D5 /
D6 are new code with unit controls and a main baseline, stated as such — acceptable.

## 4. Only necessary changes

Nothing in the design goes beyond the three scope items. No new mechanism is asked for by this review.

## 5. Verdict

APPROVE-WITH-CHANGES. Apply m1–m7 as text edits (m1 and m2 before the tests and device runs are written, since
they decide what a pass means).
