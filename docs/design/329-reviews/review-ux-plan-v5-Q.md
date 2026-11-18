# Review Q of `329-ux-speed-plan.md` v5 (whole document; angle: implementability and tests)

Method: source read only (`app/lib`, `app/test`, `329-n1-plan.md`). Nothing was run: no prototype, no phone, no
node, no test. Every statement below is "read from source" unless marked otherwise. I formed my findings before
opening the v3 / v4 reviews; I then read only the finding titles of M and N to check for overlap. I did not open
review P.

Baseline (leases, sessions, login, node protocol) was not reviewed. N1 is taken as given.

Result: 0 BLOCKER, 0 MAJOR, 13 MINOR. Verdict: **APPROVE-WITH-CHANGES** (the changes are edits to the plan text
and the test table; none changes the design).

---

## 1. What I checked and how far

Verified against source (file:line read by me):
- F2–F6, F9–F11, F13, F14 as cited; the listener order contract (`app_link.dart:109-110`, `ble_gate.dart:136`).
- §4.2 line references in `acquire` (`node_link.dart:253-270`: `_releasing` wait 256-259, refusal 260,
  `core.acquireLease` 261, `_dropAll` 262) and `loginFor` (:304), `op_session.dart:109-115`, `:126`.
- `GateLink`: a state-down event sets `_down` and leaves `_open` true (`ble_gate.dart:74-83`), so `up` is a
  real second condition and T20's control ("`pass` checks `open` instead of `up`") can fail in (a), (b), (c).
- `OwnerConsole._close` (`owner_console.dart:675-693`), `OpSession.once` (`op_session.dart:89-131`),
  `rekey_send.dart:112/139`, `statusPage`'s single caller (`ui/more_pages.dart:271`).
- The rig of §6 can be built from existing fakes: `Clock` and `Radio implements BleBackend` with `linkStates`
  (`test/nodelink/node_link_test.dart:10-76`), `FakeSession implements OwnerSession` and `FakeRust` with
  `RustLib.initMock` (`test/nodelink/prober_test.dart`), `Fx` (`test/flows/op_session_test.dart:29`).
- N1's rule (`329-n1-plan.md` §2/§3): only a connected device with **no** session entry older than 30 s is cut.

Not checked (say so rather than imply): the Rust and provd citations (`owner.rs`, `swupd.rs`, `server.go`,
`session.go`, `bluez.go`); `member_ui.dart:267-282`; `more_pages.dart:314-316`; the body of `sim.dart`,
`login_for_test.dart`, `owner_console_test.dart`. F1's timing numbers and "0.6 s" are the plan's own
measurements; I have no way to confirm them.

---

## 2. Findings

### BLOCKER
None.

### MAJOR
None. I looked for: a `keep` that is neither parked nor destroyed; a parked link that blocks `connect` for
ever; a use after dispose; a park off the node page or in the background; a kept link that N1 cuts in a loop.
I found none that the plan's rules do not already close (see §5 and §6 below).

### MINOR

**m1. `_pump` starts a scan while a link is parked and the plan gives no rule for it.**
Scenario: T4 (d). A kept read returns an error code; the link is parked again; `keptNeeds(id)` is now false.
`_pump` falls through to the scan branch, and `node_link.dart:531` starts a scan whenever a round is active.
Only the connect is held back today (`:533`, `gate.links == 0`). §4.4 says "no scan and no connect … while it
is parked" as behaviour, but names no code rule; the new `_pump` branch as written ("before the scan branch:
round active, kept link parked, `keptNeeds`") does not cover `keptNeeds == false`.
Fix: one sentence in §4.4 / §4.6: "`_pump` returns before the scan branch whenever NodeLink has a kept link
(parked or reading)". T4 (d) then has a named control ("that return removed → a scan starts").

**m2. `_run`'s branch "`keepFor(id)` is no longer true → destroy" cannot be reached and has no control.**
Evidence: every change of page, page node or foreground cancels the round (`core.dart:218-251`), and `_pump`
aborts the attempt, so `_run` takes the abort return first. "No kept link" cannot flip either: no second
source can park while an attempt holds NodeLink's token. T19 has no case for this branch.
Fix: delete the branch, or list it under "rules with no control" in §6 as the plan does for `keptNeeds`.

**m3. T19: two of its cases are one case, and the abort cases need a specific fake.**
"`core.result` returns false" and "the record is removed" are the same path: `result` returns false when the
record is gone or the attempt is not the running one (`core.dart:469-532`). Records change only in
`NodeLink.released` (`node_link.dart:493-505`), and a lease's `acquire` aborts the attempt first. So in the
rig this case needs a direct `core.setRecords` call between the prober's return and `_run` resuming. Also,
`FakeProber` is not a `KeptReader`, so `keepFor` is null with it; the abort cases need the real
`SessionProber` plus a fake session that lets the test act between the answer and `_run`'s next step.
Fix: say both in the T19 row (one case, driven through `core.setRecords`; real prober).

**m4. Three of the four `reusable` conditions have no control that can fail.**
§4.3 lists: `_session != null`; no request waiting and `_busy` false; allow-list; wait not ended by its 10 s
limit. A request that is waiting when `_close` begins sets `_session = null` at `owner_console.dart:685`, so
"no request waiting" and (as far as I can find for a read-only console) "`_busy` false" and "not timed out"
are already implied by `_session != null` after the wait. T9's control forces `reusable` true as a whole and
T17 covers the allow-list; neither can show that any of the three does anything. This is the redundant-
condition class the plan itself removed elsewhere (L-M2).
Fix: either reduce the rule to "`_session != null` after the wait, and the allow-list", or add one row:
`close()` called while an `info` request hangs → 0 links, control = that condition removed, and record
whether it fails.

**m5. `destroy()` and the hook are under-specified for the implementer.**
- `LoginHandoff.close()` today closes the link first and disposes the session last (`handoff.dart:56-92`);
  §4.1 defines `destroy()` as session first. With `_closed` one-shot, `destroy()` needs its own flag or must
  share `_closed`; the plan does not say which (it matters for "a second close is a no-op", §4.5 rule 4).
- "`close()` returns when the link is gone or parked" (§4.3) while "the hook is one synchronous step": the
  hook must return the future of the `destroy()` it starts. The hook's signature is not given.
Fix: two lines in §4.3: the hook is `Future<void> Function(LoginHandoff, {required bool reusable})`, its
decision is synchronous and it returns the destroy's future; `destroy()` and `close()` share the one-shot.

**m6. "Record of this id removed → close" has no named call site.**
Records reach the core only at `start` and in `released` (`node_link.dart:499`, `:505`). The close must sit
right after those two calls. T5's "record removed" must therefore be driven as: session lease, records
changed, release. As written ("from T1 … record removed") the row does not say how.
Fix: name the two call sites in §4.5 and the drive path in T5.

**m7. `KeptReader.read` cannot reuse `probe`'s `answer` step as the code stands.**
`probe`'s steps are local closures inside `probe` (`prober.dart:110-270`); "the `answer` step as in `probe`"
means a refactor of `probe` into a shared method, or a second copy. Also `Outcome`'s constructors are `const`
with positional `res, view, extra` (`core.dart:43-58`), so `keep` needs a new named parameter or a
`withKeep`, and it must be attached after the hint / team step (the outcome is replaced there by `withTeam`).
"Skips its cleanup" must be decided on the outcome that is actually returned, because a cancel can complete
the probe with the stored read (`prober.dart:131`) after `keep` was built.
Fix: state "the step loop is moved to a method shared by `probe` and `read`; no behaviour change in `probe`"
(so the reviewer of the code knows the baseline file is touched on purpose), and the rule "cleanup is skipped
only if the returned outcome carries the `keep`".

**m8. Small things the gate and NodeLink need that the plan does not list.**
- `GateLink.token` is `final` (`ble_gate.dart:62`); `pass` writes it. Stated only as "nullable".
- `BleGate._timer` throws away the `Cancel` (`ble_gate.dart:179`); the 120 s timer needs it kept per link
  (§4.5 rule 5).
- `gate.links` is read at `node_link.dart:352`, `:366`, `:533` and in `_dropAll` (`:671`). §4.6 names
  `_dropAll` and says the others "run only after the kept link is closed"; true for `:352/:366`
  (§4.2), and for `:533` only with the return of m1.
- `SessionProber.keepFor` must be a settable field (NodeLink sets it after construction, `app_link.dart:142`
  then `:149`).

**m9. A link closed by the gate's 120 s timer leaves NodeLink's reference until the state stream ends.**
`GateLink.close()` adds no `false` event; it closes the stream in `finally` (`ble_gate.dart:128-130`), so
NodeLink learns through "state stream ends" (the first row of §4.5). That works, but only after the close has
finished (up to 5 s). In between, `keepFor` says "there is a kept link" and a `loginFor` gets `Refused` from
`pass` and closes it, which is the stated fail-closed path. No wrong behaviour; T14 should assert that
NodeLink's reference is cleared (next round's read is kept), not only "the gate has 0 links".

**m10. The device pass criterion misses a fourth slow case: any tap within about 6–16 s after a send.**
After a send the link is closed (not reusable). The lease release starts a round 6 s later, which reconnects
(one F1, 6–10 s by the plan's own numbers). A sub-page opened in that time finds no kept link, or aborts the
reconnect, and pays a full login. "Change Wi-Fi, then open the country page" is an ordinary sequence. §6 says
"every read after the first is under 1.5 s, with three stated exceptions"; this is not one of them, so the
device pass would fail on a path the design accepts.
Fix: add it to §2 "does not handle" and to the exceptions in §6 (or time it and record it).
Related honesty points, all MINOR and mostly already stated:
  - Open node page and the first status: one F1, unchanged (stated).
  - Send key (`rekey_send.dart:112/139`): two `OpSession.once`; with a parked link both are on the kept
    session, 0 logins. The plan does not claim this; it is free.
  - Home page and team pages: unchanged, as slow as today (stated in §2).
  - A second 「重新整理」 inside 1 s of the last status closes the link and reconnects (stated in §4.4 as
    fail-closed). A user who taps refresh twice quickly gets the slow path once.
  - "Under 1.5 s" rests on one measured number; the plan marks it ❌ not run.

**m11. Interaction with N1's 30 s rule: stable; two rows can say so.**
(Inferred from the two plans and the app source; no node was used.)
- A parked link always carries an authenticated session, so it has a session entry on the node and N1 never
  counts it as stale. It is read every 60 s on the node page, inside the 300 s idle limit. A session lease
  held with no login stops the rounds, and the gate closes the link at 120 s, also inside 300 s. So a kept
  link does not sit on the node without a session in normal use.
- It can sit without a session in three cases: the node ended the session (300 s, an error) and its
  disconnect did not reach the phone; provd restarted and BlueZ kept the link; the app froze between connect
  and login. In each, N1 cuts the link within about 50 s at the next register tick, the app sees link down
  (parked: close; lent: the request fails as today), and the next round reconnects once. I found no loop:
  after the reconnect the new link has a session.
- Fix (text only): the lifecycle row "provd restart only" can add "with N1 the node cuts a link with no
  session within about 50 s, which closes a parked link by link down". Whether provd sees an already-
  connected device after its own restart was not verified by me either.
- A link that is connected but still logging in for more than 30 s (a slow first login) is the baseline's
  and N1's concern, not this plan's.

**m12. Real-time assertions in T2 and T11.**
Both use a `Stopwatch` "under 1 s" because `_dropAll` waits with a real `Future.delayed`
(`node_link.dart:672-674`). T11's control then needs a real 5 s wait, and "under 1 s" can flake on a loaded
CI host. Acceptable; say the bound is generous on purpose, or count the `_dropAll` loop passes instead.

**m13. T5 `radio(bluetooth: false)` must be driven without a link-down event in the rig.**
On a phone Bluetooth off gives both `radio()` and a link down (§4.5 rule 4). If the rig also sends the link
down, removing the `radio` row's close leaves the listener to close the link and the control passes. The row
should say "only `radio()` is called; the fake radio keeps the link up".

---

## 3. What the implementer must invent (not in the plan)

1. The `_pump` guard for "kept link exists, `keptNeeds` false" (m1).
2. Whether `destroy()` shares `close()`'s one-shot flag; the hook's signature and return (m5).
3. How `read` shares `probe`'s step code; how `Outcome` carries `keep`; when cleanup is skipped (m7).
4. Where "record removed" is detected (m6).
5. `GateLink.token` mutable, a per-link `Cancel` for the 120 s timer, `keepFor` as a settable field (m8).
6. The mapping in `read` of a session `ended` step and of a thrown error (I assume: as `probe`, i.e.
   `Res.broken` / never throws; §5 says "never completes with an error").
7. How NodeLink's 5 s limit cancels the read: it has to complete the `cancelled` future it passed to `read`,
   and then apply the "still mine and still reading" rule to whatever comes back.
8. What `addr` NodeLink passes to `core.keptRead` (the link's address: `GateLink.address`).
9. The UI look during a kept read: there is no running attempt in the core, so anything that shows "busy"
   from `r.running` will not show it for 0.5 s. Probably wanted; not stated.

None of these is a design choice with more than one sensible answer, which is why none is MAJOR.

---

## 4. Test table, row by row

"Writable" = with the existing fakes plus the combined rig of §6. "Control fails?" = my reading of whether
removing the named change makes an assertion of that row fail. Nothing was run.

| # | Writable | Control fails? | Note |
|---|---|---|---|
| T1 | yes | yes (main) | |
| T2 | yes | yes; `_dropAll` exception removed → 5 s real wait | real time, m12 |
| T3 | yes | yes (main: 2 connects) | |
| T4 a | yes | yes | |
| T4 b | yes | yes | |
| T4 c | yes | yes | |
| T4 d | yes | yes for "no connect"; "no scan" needs the guard of m1 to exist first | m1 |
| T4 e | yes (fake returns the body after cancel) | yes: without the rule the old body goes to `keptRead` in the new round | |
| T5 parked | yes | yes for `setPage`, `background`, `dispose`; `radio` only if no link-down is sent (m13); "record removed" needs the path of m6 | |
| T5 reading | yes (rig has time between `status` and `info`) | yes | |
| T6 | yes | yes | |
| T7 a | yes | yes | |
| T7 b | yes | yes (frame stays held, 1 link) | |
| T8 | yes | yes (stale lent reference makes `keepFor` false) | the test must be on the node's page when the round runs |
| T9 | yes | yes, but it controls `reusable` as a whole | m4 |
| T10 | yes | yes | |
| T11 | yes | yes, by the time assertion only; needs 5 s real time | m12 |
| T12 a–f | yes | yes, one term at a time as listed | |
| T13 | yes (source check) | yes | |
| T14 | yes | yes | also assert NodeLink's reference is cleared (m9) |
| T15 | yes | yes | |
| T16 a, b | yes | yes | |
| T16 c | yes | yes | `dispose()` waits up to 5 s real time in `_dropAll` while the link is lent; the test must answer the request without awaiting `dispose()` first |
| T17 | yes | yes | |
| T19 | yes with the real prober | yes on the session assertion | m2, m3 |
| T20 a, b, c | yes | yes (`_open` stays true after a down, `ble_gate.dart:74-83`) | |
| T21 | yes (page test with a fake console) | yes | |

Defined behaviour with no row:
- `_run`: "`keepFor` no longer true → destroy" (m2, unreachable).
- `reusable`: "no request waiting", "`_busy` false", "wait not ended by its limit" (m4).
- `loginFor` fast path refused by `pass` and then the slow path: covered by T20 (c). Fine.
- `refresh()` during an early round with a read in flight (§4.4 ⚠️): no row. The outcome is recorded in the
  new round by design; a row would only pin it. Optional.
- `acquire` refused at `:260` "touches nothing" with a parked link: no row; one assertion in T2 would do
  (a second `acquire` while the first lease is held returns null and the link is still parked).
- The 120 s timer stopped by a later `pass` (parked → reading → parked resets it): implied by T4 (a) at
  "advance 60 s, then 130 s" only if the test checks the link is still there after 190 s. Say so in the row.

---

## 5. Ownership, contracts, lifecycle, security (short)

- Ownership: one owner per resource as listed in §5. The inbox handler slot has three owners in sequence
  (console, NodeLink, read); each hand-over is in one synchronous step in the plan. I found no state with two
  writers.
- Contracts: missing / stale / malformed all end in "close and take the slow path". The one place that does
  not close is the error code on the kept link (B6), stated with its cost.
- Lifecycle: the matrix is complete for the app. Additions suggested: m10 (after a send), m11 (provd row).
- Security, by actor:
  - Radio range: no new input; the cost is the node not advertising while the page is open (stated).
  - Other app on the phone: the plan's ⚠️ line is honest (not checked, no test). Frames are encrypted; worst
    case found is a broken session and a reconnect.
  - Compromised node: a frame on a parked link is not parsed and closes it. It can hold the phone's single
    link by keeping a valid session alive, which it can do today for the length of an operation; now for the
    page's lifetime. Availability only.
  - Physical capture of an unlocked phone with the page open: today's rights minus the login wait (stated).
    Screen lock → `background()` → link closed.
  - Our own mistake: the gate's 120 s timer; and the `keep` path it does not cover is closed by T19.
- Fail-secure: yes, throughout. Negative tests: T1 (GATT call on a parked link refused), T15, T16, T20.
- Over-design: m2 and m4 (conditions that cannot change the result). Deleted-but-needed: none found; the
  1.5 s wait and `keysOk()` in the hook were removed with reasons that hold in source.

---

## 6. Overlap with earlier reviews

M-M1 / N-M1 (park off the node page) and M-M2 (N1) are fixed in v5 as far as I can read: `onPage` is in the
hook with per-term controls (T12), and §2 / §7 carry the N1 dependency. m4 here is the same class as L-M2;
m1 touches L-m9's area but is a different point (the scan, not the 2' timing).

---

## 7. Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 0 MAJOR, 13 MINOR. The plan can be implemented as written; the changes
asked for are text and test-table edits (m1, m3–m8, m10, m13 are the ones worth doing before coding; m2 and m4
remove or justify conditions; m9, m11, m12 are notes).
