# Review r5-A: `329-takeover.md` v5 (ad2a3c2)

Reviewer A, round 5, independent. Whole document reviewed against main 99d156a (`app/`) and the two captures in
`Desktop\Batman\a1\`. Read-only: no device, node, adb, flutter or state-changing git command was used; nothing was
run. Baseline documents and the three product decisions were not re-reviewed.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 0 MAJOR, 6 MINOR.**
All six are text or test-wording fixes; none changes the mechanism. No further whole-document round is required by
the rules.

## 1. What was checked and holds

Method: read the design in full, r4-A and r4-B in full, then `node_link.dart`, `core.dart`, `prober.dart`,
`ble_gate.dart`, `op_session.dart`, `settings_pages.dart` at every cited line and around it, and traced the proposed
changes by hand over the existing code. "Holds" means traced on source, not run.

### 1.1 mechanism — interleavings traced

- **Detach + line 900.** `setPage` (`node_link.dart:303–311`) sets `_det`; `_pump` line 900 with the new condition
  keeps a detached attempt only while `wanted(a)`. `_attempt` stays set, so nothing else starts
  (`:911`, `:928`). Page left, background, radio blocked, record removed each make `wanted` false; the next `_pump`
  aborts. No path found where `_det` outlives its attempt (identity compare; cleared only for that attempt).
- **`_run` end.** Early return `:999`, aborted return `:1038`, normal end `:1040–1057`. With a per-attempt `ended`
  completed under `isCompleted` in the normal path, in `_abort` (`:1060–1069`) and in `finally`, there is no double
  completion and no attempt whose `ended` never completes (the early return at `:999` is before a link exists, so
  no waiter can be waiting for it: the wait requires `_link != null`, set at `:1008`).
- **Late end of an aborted attempt** while a newer attempt is detached and awaited: identity checks keep the newer
  one and its waiter (T17 discriminates).
- **acquire wait.** Placed before `core.acquireLease` (`core.dart:285–290`), so the round is alive during the wait
  and the attempt ends by its normal path. After the wake, today's code from the repeated `reg.current` check
  (`node_link.dart:359–377`). One waiter; a live waiter refuses the second call, a gone one is replaced and returns
  null when it wakes. A replaced waiter wakes on the same `ended`, before or after the new one — in either order it
  returns null and clears `_waiter` only if it is still itself, so the new waiter is not lost.
- **Timer.** NodeLink's own 8 s timer is stopped on wake; `dispose` (`:1085`) → `_dropAll` → `_abort` → `ended`
  wakes the waiter, which returns null. No leaked timer or link found.
- **Two writers.** The parked link has gate token null; `_dropAll` (`:1071`) and `gate.revoked(mine)`
  (`ble_gate.dart:302–309`) do not touch it; `_loginFor` lends it (`node_link.dart:446–452`). The kept-link map is
  still written only by `_park` / `_lend` / `_forget`.
- **Detached outcome.** Body / error code through `core.keptRead` (`core.dart:603–625`), which records only for a
  target of the active round; an error code sets the error without a retry key and `_candidates`
  (`core.dart:472–489`, stop at `:474` only on body / reason) lets the round make its own attempts. Anything else
  records nothing. Fail-secure as claimed.

### v5 changes

- §0 against the captures, re-counted by me this round: `a2-step1` has 11 `attempt … result=body` lines,
  2907–4802 ms; the three cancelled attempts to 04 are 736 ms (12:21:13.530), 1696 ms (12:23:00.864), 2201 ms
  (12:23:37.418). `a2-repro`: 524 ms, 465 ms, 104 ms second attempts; `11:47:27.135 attempt …5A×…880c
  connected=1633ms result=noResponse after 2163ms`; round 32 cancelled 11:47:28.144 → `loginFor … -> body`
  11:47:53.851 = 25.7 s. `grep -c "kept link"` = 0 in both files.
- Cost paragraph: the 8 s waiter timer against the prober's 20 s answer limit (`prober.dart:233`) is stated
  correctly (the timer can end an attempt that has logged in; then today's path). The expected range follows from
  the captured body times.
- Cites opened one by one (all correct except m6): `widgets.dart` 31, 104–106, 133, 143, 162; `home_page.dart` 208,
  280, 288, 295, 321–331, 340, 353–358, 361, 414; `home_logic.dart` 155, 158, 171; `ble_gate.dart` 195, 302–309;
  `update_route.dart` 28; `net_pages.dart` 203, 224, 271, 342, 548, 917; `node_page.dart` 208, 213; `app_link.dart`
  80; `statuspage.rs` 333; `tests/statuspage.rs` 303–305, 390; `owner.rs` 461, 2579, 2792; `owner.dart` 573–574,
  616, 630; `more_pages.dart` 84, 192, 211, 258, 313; `member_ui.dart` 186, 205; `dev_pages.dart` 183, 274, 459;
  `join_pages.dart` 117, 721; `remove_pages.dart` 102; `offline_op.dart` 118; `team_deps.dart` 23–25;
  `team_status_page.dart` 62; `op_session.dart` 69, 94, 112, 150; `settings_pages.dart` 25–37, 41, 126, 133, 148,
  156, 182, 295, 307–314, 326, 340; `prober.dart` 129–132, 233. `opDeps` is the only maker of `OpDeps` under `lib/`.
  The `setPage` caller list reproduces by grep.
- Device criteria use log lines that exist: `loginFor … -> ok (kept link)` (`node_link.dart:451`),
  `kept … -> body` (`core.dart:623`), `round N cancelled`, `attempt …×…7d2c`. D1 is now stated inside the page's own
  round (r4 A-m2 / B-m4 fixed); D5 has the 0.6–1.5 s delay (r4 A-m3 fixed) and no invented log line (r4 B-M2 fixed).
- r4 B-M1 (steady hero): the hero button is drawn only when `actionText != null` (`home_page.dart:353–358`); the
  variant with `HomeAction.none` adds no height. `home_steady_test.dart` exists with the three states.

## 2. Findings

### m1 (MINOR, a matrix row and two test lines that do not match `core.refresh`) — §4 rows 268–269, T14, T14b

Scenario: `core.refresh` does nothing when the running round is full (`core.dart:340–341`: `if (!r.early) return;
// X2`). A node page's round starts full (`core.dart:258`). So:
- Row 268 "`refresh` … with the round's own attempt in flight on the node page | abort | abort" is true only when
  the running round is early (an early re-read, `core.dart:669–670`). In the common case (full round) main does not
  abort and neither does the design. T14's `refresh` sub-case, written against a full round, would fail on a
  correct build; against an early round it holds. The T14 mutation is still killed by the cap and early → full
  sub-cases (`core.dart:643–645`, tick at cap: `core.running` becomes null, line 900 with only `wanted(a)` keeps
  the attempt).
- T14b "`refresh` on the node page while a detached attempt runs: … body recorded in the **new** round": a detached
  attempt exists from the `setPage` that began the page's full round; `refresh` during it is a no-op, so there is no
  new round and the body lands in the same round. The stated outcome (not aborted, one connect, recorded, parked)
  holds, the word "new" does not, and the test does not exercise "answer goes to the round active when it ends".

Fix (text): row 268 and T14: "`refresh` while the round is early" (or drop `refresh` there: cap and early → full
cover line 900). T14b: produce the second round by a path that exists — the page's round is early when `refresh`
comes, or the full-round timer replaces an early round (`core.dart:643`) — or state T14b as "`refresh` is a no-op
on the full round; the body is recorded in the page's round".

### m2 (MINOR, device criterion: which clock) — D2 "logged in no later than 1 s after the attempt's end"

Scenario: the `loginFor` trace lines reach logcat together when the operation ends. In `a2-repro` the four lines
`nl 986.9 loginFor …7d2c` … `nl 990.4 loginFor …9E×…7d2c -> body` all carry logcat time 11:46:13.229 (file lines
4689–4692); only the `nl` column (986.9 … 990.4) tells when each step happened. Read by logcat time, D2's 1 s limit
and the "tap-to-logged-in" time would be measured to the flush, not to the login.

Fix: one sentence in the device rules: "times of `loginFor` lines are read from the `nl` clock column, not from the
logcat timestamp" (the `attempt …` and `round …` lines carry both).

### m3 (MINOR, unstated case) — a lease without `forNode` asked during a live wait

Scenario: a settings page waits for the attempt; another flow that passes no `forNode` (`OpenSession.open`,
`op_session.dart:150`, or a `once` for another node) calls `acquire`. It takes today's path: `core.acquireLease`,
`_abort()` (`node_link.dart:369`), `_dropAll`. The abort completes `ended`; the waiter wakes while the other call
is still awaiting `_dropAll`, sees `reg.current == null`, and goes down the same path; `reg.acquire` (`:374`) gives
the lease to one and null to the other. Same arbitration as two concurrent `acquire` calls on main, no stuck state
— but the ownership row for `_waiter` and "a lease other than (b) aborts it" do not say what the live waiter gets.
Not reachable from one screen in normal use (the sub-page covers the node page); inferred, not a real-use path I
could name.

Fix: one sentence in 1.1 (b): "a call that does not wait aborts the awaited attempt as today; the waiter wakes and
`reg.acquire` decides between the two, as on main".

### m4 (MINOR, unstated window) — detach while `_run` is in `await mine?.close()`

Scenario: the attempt's outcome is decided and `_run` is awaiting the link's close (`node_link.dart:1034`) when
`setPage` runs. `_attempt` is still set and `_link != null`, so the attempt is detached with its outcome already
fixed. For an outcome without `keep` the detached end then records a body through `keptRead` with nothing to park;
for a non-body it records nothing and the new round starts its own attempt. Both are correct results; the design's
"detached only after its connect started" reads as if the attempt were always still running.

Fix: none needed in the mechanism; add "(also when its outcome is already decided and the link is closing: the
same end path)" to (a), so the code review does not treat it as a missed case.

### m5 (MINOR, wording) — "never an empty name" (line 117)

Between the waiter's wake (it clears `_waiter`) and `reg.acquire` (`node_link.dart:374`) lie the awaits of today's
path (`_dropAll`). A call refused in that window (e.g. by `core.acquireLease` state or by losing `reg.acquire`)
still gets `reg.current?.name ?? waitingName ?? ''` with both possibly null for the first of two losers — the same
window as on main (`settings_pages.dart:27`). O3 asserts a non-empty name for "null lease, page alive" in general.

Fix: line 117 "names the waiting operation during the wait"; O3 scoped to "refused during a wait or while a lease
is held".

### m6 (MINOR) — bare file names

`rekey_send.dart` is `lib/src/flows/rekey_send.dart` (`:112`, `:139` correct) and `raw_use.dart` is
`lib/src/nodelink/raw_use.dart` (`:74`, `:88` correct). Unambiguous by name; listed for completeness.

## 3. Negative controls

- T1–T13, T15–T18, O1–O4, W, H, R: each named mutation changes a condition the test asserts on; checked against
  the code the mutation touches. T14 / T14b: see m1 (the mutation is killed, but not by the `refresh` sub-case as
  worded). T14c, T9: marked defensive, as agreed in round 4.
- "Fails on main" claims: T1 / T3 (main cancels and connects again: §0 rows 1 and 2, re-counted above); the labels
  (main shows 「讀取中…」 until the read, `settings_pages.dart:190, 370`); the hero (main prints the sentence on the
  yellow hero, `home_logic.dart:155–171`, `statuspage.rs:332–334`).
- Device: D1 / D2 / D3 / D7 have a captured failing state; D5 / D6 are new code with unit controls and a main
  baseline, stated as such.

## 4. Verified / inferred / not verified

- Verified by reading source or the capture files myself: everything in §1 and the evidence lines of m1, m2, m5,
  m6.
- Inferred (traced by hand over code that does not exist yet, not run): all §1.1 interleavings; m3 and m4.
- Not verified: the "about 0.1 s" figure cited from the PR #366 body (no access; D2's limit does not depend on
  it); Flutter's route-transition timing behind D5's 0.6–1.5 s; the cited lines of `329-app-uiux.md`,
  `254-app-status-page.md`, `329-honest-errors.md` (checked by r4-A, not re-opened this round); no test or device
  run of any kind.

## 5. Only necessary changes

Nothing in v5 goes beyond the three scope items, and v5 added no mechanism over v4. This review asks for none.

## 6. Verdict

APPROVE-WITH-CHANGES. Apply m1–m6 as text edits; m1 and m2 before the tests and device runs are written, since
they decide what a pass means.
