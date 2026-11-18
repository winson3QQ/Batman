# Review K — `329-ux-speed-plan.md` v3 (whole document)

Reviewer K, independent. Source: worktree `C:\src\Batman-b8` (off main 6760b78), read only. Nothing was run
(no suite, no device, no node); every finding below is from reading source. Not read: the v2 reviews G / H and
H's prototype, so I did not check §8's "resolved" claims against them.

Verdict: **APPROVE-WITH-CHANGES** — 0 BLOCKER, 3 MAJOR, 9 MINOR.

The design (one kept link, null token while parked, lent under the lease token, a lent link only forgotten) is
sound and small. The three MAJORs are places where the plan's words do not match what the existing code does
at that point, so an implementer following the plan literally gets a wrong result.

## MAJOR

### M1. "session lease acquired × reading → waits ≤ 1.5 s" cannot work where the plan puts it

Scenario: owner is on the node page, the 60 s kept read is running (state *reading*, NodeLink's token), the
owner taps Wi-Fi. `OpSession.once` calls `NodeLink.acquire`, then `loginFor`.

Evidence:
- §4.2 puts the wait in `loginFor`; §8 says "`acquire` waits"; §4.5 says "waits ≤ 1.5 s (4.2)". Three places, two answers.
- `acquire` (`node_link.dart:253-270`) runs, before `loginFor` is ever called: `core.acquireLease` →
  `await _dropAll()` → `reg.acquire` → `gate.revoked(mine)`.
  - `_dropAll` (`:664-675`) waits up to 50 × 100 ms real time while `gate.links > 0`. §4.6 exempts only a
    *parked* link; the reading link is counted → up to 5 s wait (the thing T2 forbids).
  - `reg.acquire` replaces the current token (`lease.dart:137-138`), so `_usable` refuses the read's next write.
  - `gate.revoked(mine)` closes every link whose token is identical to NodeLink's old token
    (`ble_gate.dart:252-258`) — that is the reading link.
- So by the time `loginFor` could wait, the link is closed. T11's "read ends in time → lent, 1 connect" fails;
  the result is baseline behaviour (slow path), not a bug the user sees, but the row and the test are wrong.

Smallest fix: put the wait in `acquire`, before `_dropAll` / `reg.acquire`: session lease and state reading →
wait for the read up to 1.5 s; finished → it is parked (null token) and nothing below touches it; not finished →
close it. Say so in 4.2, 4.5, 4.6 and §8 with one wording. Keep T11; its control "wait removed" then fails for
the right reason.

### M2. "No path on which a returned `keep` is neither parked nor destroyed" has no test, and today's `_run` is the opposite shape

Scenario: the prober returns `Outcome.keep` (it skipped its cleanup); between the prober's `done` and `_run`
resuming, the attempt was aborted (`setPage`, `background`, `acquire`, `radio`).

Evidence:
- `_run` today (`node_link.dart:599-651`): `await mine?.close()` unconditionally at `:632`, then
  `if (!identical(_attempt, a)) return;` at `:634`, **before** `core.result` at `:639`. The plan needs: no
  unconditional close when `keep != null`, and the destroy on the early-return path. Neither is written.
- If the destroy is missed there, the link still carries NodeLink's token (not null), so the gate's 120 s timer
  (§4.5 last row, armed only by `pass(link, null)`) does not cover it. `_pump` attempts only when
  `gate.links == 0` (`:533`) → no more reads until the app restarts. T14 does not catch this.
- §6 has no row for: keep returned and attempt aborted / `core.result` false / record gone / link already down.

Smallest fix: one test row "keep returned, then each of: attempt aborted before `_run` resumes, `core.result`
false, record removed, link down → 0 links, session disposed", control "destroy on that branch removed". In 4.1
add: "`_run` does not close `mine` when the outcome carries `keep`; the abort return at `:634` destroys it."

### M3. "link up" has no source, and a link that went down unseen gets parked and lent

Scenario: the link drops (a) between the prober's answer and NodeLink parking it, or (b) while a console is
closing: `_close` cancels its state subscription first and may wait up to 10 s for the chain
(`owner_console.dart:672-693`) before the hook runs.

Evidence:
- `GateLink` exposes only `open` (`ble_gate.dart:69`); `_down` is private. `_state` is a broadcast controller
  (`:65`): an event before NodeLink subscribes is lost.
- §4.7 `pass` refuses only "a link that is not open". A down-but-open link is parked: `gate.links` stays 1, and
  the next `loginFor` fast path lends it (§4.2 "link up" — from what?). The flow's request then fails with
  today's failure text, where baseline (fresh connect) succeeds. Worst case it sits until the 120 s timer.

Smallest fix: `bool get up` on `GateLink` (`_open && !_down`); every "link up" in 4.1–4.4 and `pass` use it;
NodeLink subscribes and then checks `up` in the same synchronous step as `pass(link, null)`. One test: state
`false` delivered before the park / before the hook → 0 links, next op by the slow path (control: the `up`
check removed).

## MINOR

1. **§4.4 "one request per read" is wrong; `E_RATE` is per session.** A status-page read is two requests:
   `status`, then `info` (`owner.rs:949-972`). The rate limit is per session (`provd/session.go:868-874`), and
   the session is now shared by NodeLink's reads and a console's `statusPage`. Two status requests < 1 s apart
   on the kept session (a round started early right after another read) → `fresh == false` → `noResponse` →
   link closed and a full reconnect. Fail-closed, so only speed is lost. Fix the sentence; say that the 5 s
   limit covers both requests. (Flows that call `statusPage`: only the leave re-read, `more_pages.dart:271`,
   after a send — not reusable anyway.)
2. **T4 "`refresh` during the read → nothing recorded in the new round" is not reachable by `refresh`.**
   `core.refresh` returns without a new round when the round is full (`core.dart:315`). The reachable cases are
   `acquireLease`, `setRadio`, `setPage` away and back. Reword the sub-case and its control.
3. **Lease released (not taken back) while lent and the holder never closed.** `gate.released` closes the link
   (lease token), NodeLink stays *lent*; `keepFor` ("no kept link") is false until the page changes, so no new
   kept link. Add to 4.5: "lease released | — | — | forget" (in `NodeLink.released`).
4. **`radio()` / `core.blocked` while parked.** The row says close, but "(4.2, 4.3)" reads as "seen only at
   lending / giving back". Say that `radio()` setting blocked closes a parked link at once; else it waits for
   the 120 s timer.
5. **`OwnerConsole._close`: evaluate `reusable` before `_closed = true` and again after the chain wait.**
   `_closed` is set first today (`:672-676`); `_kick`'s timeout, `_lost` and `ended` null `_session`
   (`:368-397`), possibly during the 10 s wait. The plan's "alive at the call" should be "alive after the chain
   finished".
6. **provd restart (lifecycle row) has no evidence** that the BLE link drops when only provd restarts (BlueZ may
   keep it). Then a parked link is closed only by the next kept read's 5 s limit, and a lent one gives the flow
   a 15 s timeout instead of baseline's fresh login. ⚠️ inferred, not checked on a node; either capture it on 04
   or state it as accepted.
7. **Existing-tests list is not in the plan.** I found no test that drives the real `SessionProber` through
   NodeLink on `Page.node` (the `SessionProber(` uses are in `prober_*_test.dart` and `handoff_test.dart`,
   without `keepFor`), so the list is probably empty; say so instead of "found by running the suite". Direct
   `LoginHandoff` users with no hook (`owner_console_test.dart:144`, `retest_p_console_close_test.dart:32`,
   `login_for_test.dart:29`, `app_link_console_test.dart:96`, `join_pages_test.dart:223`) keep today's close.
8. **§6 table: T11 and T13 have their text in the wrong columns** (Expect is "—"). T13 has no control; a source
   check may have none, but say so.
9. **Fact citations.**
   - F3: `core.dart:218` is the start of `setPage`; the read begins at `:232`.
   - F7: `team_status_page.dart:62` sets `Page.team`; `Page.other` is `home_page.dart:340`.
   - F8: `bluez.go:412-418` is the disconnect code, not slots / advertising (`:772-776` is right).
   - F11: the handed-over skip is `prober.dart:256-257`.
   - F10: there is an earlier check at `node_link.dart:304` (`p == null || _disposed || _lfBusy || !mine()`);
     the fast path must come after it too.
   - F2, F4, F5, F6, F9, F12, F13: checked, correct.

## The brief's six checks

- (a) Leak paths: M2 (keep not parked), M3 (parked or lent while down), MINOR 3 (lent, released). No other found.
- (b) Deadlock / 5 s wait: none for a *parked* link (null token; `_dropAll` exempt; 4.5 closes it before any
  slow path). A *reading* link does hit the 5 s wait — M1.
- (c) §4.5 table: wrong cell = session lease × reading (M1); missing rows = lease released × lent (MINOR 3),
  keep returned but not yet parked (M2).
- (d) §4.4 against `core.dart` / `_pump`: implementable. It needs new core API (round identity, targets, the
  target's body / error flags are private today) — `core.keptRead` plus one query; say so in §5. The errorCode
  path without a retry ends the same way (window → `Concl.unchanged` → 2').
- (e) `_close`'s reusable rule matches `_ask` and the session, with MINOR 5.
- (f) Tests that break: only `_FakeHandoff` (`net_run_test.dart:143`), which the plan names. See MINOR 7.

## Security and over-design

- Security section holds: null token refused by `_usable`; lending after the three checks; a frame on a parked
  link is not parsed; background closes. The physical-capture note is honest. No new input.
- The gate's 120 s timer is a second mechanism for "our own mistakes", but it is small, has one owner and a
  test; I would keep it. Note it does not cover M2's path.
