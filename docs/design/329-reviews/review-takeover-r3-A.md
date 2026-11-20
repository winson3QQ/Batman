# Review r3-A — `329-takeover.md` v3 (branch feat/329-takeover @ 920db89, code = main 99d156a)

Reviewer: independent, first sight of the design. Whole document reviewed; baseline (#366 NodeLink / core / gate /
kept links, honest-errors texts, home hero rules, status page) only as far as the delta touches it.

Method: source read only. Nothing was run (no app, no test, no device, no git write). Every interleaving below is a
hand trace of `node_link.dart`, `core.dart`, `op_session.dart`, `lease.dart`, `ble_gate.dart`, `prober.dart` at
99d156a with the v3 changes applied as the design words them. "Traced" = followed in source; it is not a test result.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 0 MAJOR, 12 MINOR.**

No trace found a stuck state, a double completion, a lease given while an attempt holds the link, a leaked link or
a security regression. The findings are one wrong statement about what the round does after a detached error code
(m1), one unneeded side effect with a one-line fix (m2), places where the text leaves the implementation a choice
that matters (m3–m6), unstated paths (m7–m9) and cite offsets / test wording (m10–m12).

---

## 1. What was traced and holds

| Question (from the brief) | Result | Where |
|---|---|---|
| `_link != null` means "the current attempt's connect has started" | Holds. `_link` is set only at `gate.connect` (`node_link.dart:1008`), nulled by `_abort` (:1065–1066) and by the attempt's own `_run` (:1035, identity-guarded). During `_makeRoom` it is null. | :994–1008, :1035, :1060–1069 |
| Detach in `setPage` cannot mark an attempt the core still runs | Holds. `core.setPage` returns early for the same page (`core.dart:245`) and for home ↔ team (:246–251); else `_cancel` (:252) drops `running`. Design tests "the core no longer runs it". | `core.dart:244–265` |
| While detached, the core does not start a second attempt and does not believe one is running | Holds. `core.next` is the only place that sets `r.running` (`core.dart:512`) and `_pump` calls it only with `_attempt == null` (`node_link.dart:928`). The new round's `running` stays null, so no cap-cut bookkeeping touches the detached attempt. | |
| Double completion of `ended` | None if `isCompleted` is checked as stated: `_abort` then the aborted `_run`'s `finally`. | design 1.1 |
| A's late end touches B's completer / mark | No: local `ended`, field nulled by identity, `_det` cleared by identity. `_run`'s existing early return for an aborted attempt (:1036–1039) runs before any shared state. | |
| Waiter never woken | No path found: `_run` finally; `_abort` (from `_pump:900`, `acquire:369`, `_dropAll:1072`, hence `dispose:1099`); plus the waiter's own 8 s timer. The early returns of `_run` (:999 after `_makeRoom`, :1038 aborted) are both reached only after an `_abort`, which completes. A waiter never waits on an attempt still in `_makeRoom` (`_link == null`). | |
| Lease given while the attempt still holds its link | No. On wake the unchanged path runs `_abort()` (:369) and `_dropAll()` (:372), which waits for `gate.active == 0` (:1080–1082). The parked link has token null and is not counted (`ble_gate.dart:195`) nor closed by `revoked(mine)` (:302–309). | |
| Re-entrancy between the `finally` and `_pump` | The waiter continues in a microtask after `_run`'s synchronous tail, i.e. after the `_pump()` at :1057 whatever the order of `complete()` and `_pump()` (see m3). In that pump: round's own body → `core.result` → `t.body` → `tick` ends the one-target round (`core.dart:647–651`), no kept read (`keptNeeds` false, :594–597), `_park` already done synchronously (:644–661). Detached body → the same through `keptRead`. So the waiter finds the link parked and no round. | |
| A kept read starts between park and the waiter | No: needs `core.keptNeeds`, false after a body; and no timer can fire between `_run`'s tail and the waiter's microtask. | `node_link.dart:905–916` |
| Second waiter | One slot; a live waiter keeps it, a gone one is replaced and returns null by identity. Traced Wi-Fi → Back → 國家: the first returns null → `OpEnd.gone` (new check in `once`), the second waits on the same attempt. | |
| Background / Bluetooth off / page left / dispose during the wait | `core.background` / `setRadio` / `setPage` → `_pump:900` → `_abort` → wake → today's path; `dispose` → `_dropAll` → `_abort` → wake → null. | |
| Nearby device replaying an address | The detached attempt is `prober.probe(link, a.id, …)` (:1019), the same authenticated login; only `Res.body` / `Res.errorCode` (both after a login as that node) reach `keptRead` (`core.dart:603–625`); everything else records and parks nothing. Cost = the bounded delay, stated. | |
| Compromised node / second phone | Note and warning are constants; the memo is a label that enables nothing and is never put in the field (current fill is `:133`, unchanged). | |
| Fail-secure | Every non-success path closes the link and records nothing; a waiter that times out falls to today's `_abort()` path. | |
| "Joined but critical" row is green today, so the variant of rule 14 is reachable | Holds from source: colour comes from the row only (`statuspage.rs:353–358`, `color_of(row)`), the warning does not change it; rule 12's second operand is the only thing that made home yellow (`home_logic.dart:155`). | |
| `note` exactly when `warning` would be `WARN_JOINED_CRIT` | `warning()` is first-match (`statuspage.rs:313–336`); the last branch is `code none && plinks ≥ 1 && k2 == 2` (:332–334). Moving it out keeps "one line per node". | |
| `once` releasing a lease when `gone()` is already true changes other callers | Same end as today (`OpEnd.gone`), without the login that main does first (`op_session.dart:107–115`). No caller relies on that login. | |

## 2. Findings

### m1 (MINOR, wrong statement; fix the text and T12) — a detached error code is *not* "no retry in that round"

1.1 (a): "An error code is recorded as a kept read's is today (`t.err`, no retry in that round)."

For a kept read that is true only because the node's id is in `_keptIds`, which empties `_candidates`
(`core.dart:475`). After a detached error code nothing is parked (no `Outcome.keep` without a body,
`prober.dart:182`), so the id is not in `_keptIds`; the new round never counted the attempt, so `'addr|id'` is not in
`r.tried` and `_canTry` is true (`core.dart:456–459`); `keptRead` has just set `isY[addr] = id` (:616). As soon as
the address is in the round's `seen`, `core.next` hands out an attempt to it with no `freeAt` gap, and after that
one `core.result`'s own error-code branch adds a retry (`core.dart:542–546`). So the node that has just answered
with an error code is logged in to again at once, and possibly a third time 6 s later: up to three logins where the
sentence says one.

Not user-visible (the conclusion is `unchanged` either way, `core.dart:744`) and no worse than main, which also
reconnects at once after the cancel (§0 row 1). But the contract in §3 and T12 ("detached error code: recorded, not
parked") would pass while the stated property is false.

Fix: say what really happens (the round goes on with its own attempts, as after a detached no-response) and assert
the count in T12; or, if "no retry" is wanted, it needs a core change, which 1.1 excludes. The first is enough.

### m2 (MINOR, one-line fix recommended) — a waiter whose page is gone still takes the whole lease path

Matrix row "Page closed during the wait, no second call → lease obtained, released at once (O2)".

Scenario A: node page connecting → 「手機 Wi-Fi」 → Back → home, inside the wait. `setPage(home)` cancels the node
round, `_pump:900` aborts the attempt, the waiter wakes with `gone()` true and runs today's path:
`core.acquireLease` cancels the home round that has just begun (`core.dart:285–290`), `_dropAll` stops the scan
(:1073–1077), the lease is taken and released at once, and `released` sets `leaseDue = now + 6 s`
(`core.dart:334`). Home shows nothing new for about 6 s plus a round, for a page that no longer exists.

Scenario B: Wi-Fi → Back → 「軟體更新」 inside the wait. The update's `acquire` (no `forNode`) calls `_abort()`
(:369), which wakes the gone waiter while the update call is in `_dropAll`. Both calls are then past the
`reg.current` check; the waiter has no scan to stop, so it can reach `reg.acquire` first. Traced: it releases in the
same event-loop turn, so the update call most likely still gets the lease; but the result depends on timer order,
and `update_route.dart:35` prints `reg.current?.name ?? ''` directly (not `busyName`), so a loss would print
「另一個操作還在進行：」 with an empty name. (Not run; main has the same two-callers race and holds the lease far
longer there, so this is not a regression.)

Fix: on wake, `if (gone()) return null` before `core.acquireLease` (`once` already maps null + gone to
`OpEnd.gone`, O1). The matrix row then reads "returns null, nothing cancelled", O2 stays as the guard for a page
that goes between the wake and the lease, and T15 gets a sibling: gone waiter, no second call → round not
cancelled, no lease taken.

### m3 (MINOR, wording that decides the implementation) — "completed … before the `_pump()`" and "a `finally` around its body"

- A `finally` around the whole body of `_run` would contain the last `_pump()` (:1057), so "in a finally" and
  "before the pump" contradict unless the pump moves out. Say where the `try` ends.
- The order gives nothing by itself: a completer's listeners run in a later microtask, so the waiter always
  continues after that `_pump()` (which is what makes the design work: the round is ended and the link parked by
  then). State the property the design needs instead: "the waiter continues only after `_run`'s synchronous tail,
  park and pump included", and let T3 assert it (kept link lent, no round active, one connect).
- The two early returns (:999, :1038) must still not pump (today they do not); a `finally` that pumps would start
  an attempt from an aborted `_run`.

### m4 (MINOR) — `_pump` line 900: write the whole condition

"`_pump` line 900 becomes: abort unless `identical(_det, a) && wanted(a)`" drops today's first operand if read
literally, and would abort every ordinary attempt. Intended:
`a != null && !identical(core.running, a) && !(identical(_det, a) && wanted(a))`. T16 only catches the opposite
mistake.

### m5 (MINOR) — `dispose` leaves `_waiter` set

"on wake: return null if replaced or disposed; clear `_waiter`": in that order a disposed waiter returns without
clearing, and `waitingName` keeps returning its name. Harmless after dispose, but T11b says "null, no timer left";
add "no waiter left" and clear first.

### m6 (MINOR) — how `forNode` / `gone` reach `NodeLink.acquire` is not stated

`OpDeps.acquire` is `Future<Lease?> Function(String name)` (`op_session.dart`, used at :94 and :150) and is built
in `settings_pages.dart:26`. The design says only that `once` passes the two arguments. Needed: the new `OpDeps`
signature, that `OpenSession.open` (:150) passes neither (O4 tests exactly this), and that the test rigs that build
an `OpDeps` (`test/flows/op_session_test.dart:46`, `rekey_send_test.dart:43`) change with it.
Also: §1.1 and §5 cite `team_deps.dart:24–25` as an `OpDeps` path to `op_session.dart:94, 150`. Those two lines are
`OfflineDeps` (`offlineDeps`, used by `OfflineOp.run`, `offline_op.dart:118`), a caller that never waits. Changing
its `busyName` is harmless but is not "through `op_session`"; correct the row.

### m7 (MINOR, unstated path) — an attempt that is already detached survives `refresh`

Line 38–39: "Every other way an attempt loses its round (cap, `refresh`, early → full, …) aborts it as today", and
the matrix row with T14. True for the round's own attempt. A detached attempt is no round's: 「重新整理」 on the node
page cancels and restarts the round, `_det` is still identical and `wanted`, so it is not aborted and its body goes
to the new round through `keptRead`. That is the better behaviour; state it and add it to T14 (or T10's group).

### m8 (MINOR, unstated edge) — the page's round can end while the detached attempt is still in flight

With no candidate address in the new round's `seen`, the round ends at its 30 s window (`core.dart:649–651`,
`window = 30000`). A detached attempt can last 8 s + 20 s (`prober.dart:233`) + 2 s (`hintMax`, :58, :289) from a
connect that started before the round. Only the extreme reaches it, and the result is the contract's own "no round →
not taken, destroyed" (`core.dart:606`). One sentence in the bound paragraph is enough; no test needed beyond T9's
"not taken" branch.

### m9 (MINOR, unstated edge) — the update hint of the node page when the tap lands late in the attempt

`HintSource.wanted(id)` is evaluated once, after the status body (`prober.dart:367`), and `setHint` drops a hint
unless that node's page is open (`node_link.dart:262–263`). A tap that lands after that point and before the
attempt's end takes over an attempt that carries no hint; main's fresh attempt would have produced one. The hint
then comes with the next read. Narrow window (local work, ≤ 2 s); list it under "Not handled".

### m10 (MINOR) — `SettingsMemo.drop`: "the line before the set request is sent"

In 「手機 Wi-Fi」 the `requests` callback can return `notSent` without sending (`settings_pages.dart:153–155`).
`drop` must sit after that check, directly before `c.setAp` (:156); before it, a refused input would drop a value
that is still true. For 「國家」 the callback is the request itself (:340). W4 should have the `notSent` case:
entry kept.

### m11 (MINOR) — test and device-check wording

- T9 "record gone while detached": in the app the records change only at start and after a lease release
  (`node_link.dart:857–863`), and any lease other than (b) aborts the attempt first. It is a defence, reachable only
  in a unit test; say so in the matrix.
- T12 "one extra attempt, asserted" is an assertion, not a negative control; its control is m1's count.
- D5 passes only when the 「國家」 tap lands inside the wait. If the attempt has failed and 「手機 Wi-Fi」's own
  login is running, Back does not release the lease before that login ends (`op_session.dart:107–115`, unchanged),
  and 「國家」 prints busy as on main. Count D5 runs the way D1 / D2 are counted, and record main's result for the
  same taps as the negative control (none is cited for D5 / D6).
- Rule 14's variant with one node: `HomeHero(… action: HomeAction.seeNode, node: <id>)`; the table omits `node:`,
  without which the tap does nothing. H1 should assert the id.
- The hero keeps a fixed height for its short texts (`widgets.dart:106`, `test/ui/home_steady_test.dart:26, 36`);
  the variant drops 「一切正常」 from the title. H7 should include the steady-height test's case, not only overflow.

### m12 (MINOR) — cite offsets (each checked against 99d156a)

| Design says | Source |
|---|---|
| `_link` set at `node_link.dart:1009` (1.1, §5) | `:1008`; `:1009` is the `Future.any` |
| `statuspage.rs:332` returns `WARN_JOINED_CRIT` | the `if` is `:332`, the return `:333` |
| `StatusView, owner.dart:628` | class at `:616`, `warning` at `:630` |
| "no passphrase", `owner.dart:570` | the comment is `:573–574`, class `SettingsView` `:575` |
| "the country changes when the node joins", `settings_pages.dart:334` | the text is `:326` |
| `team_deps.dart:24, 25` as the second `OpDeps` | `OfflineDeps` (m6) |

Verified as cited: `core.dart:218, 244–258, 285–290, 603–625`; `node_link.dart:303, 352, 360, 369, 446–452, 639,
644, 716–735, 900, 911, 928, 996, 1040–1056, 1051, 1060–1069`; `ble_gate.dart:195, 302–309`;
`prober.dart:129–132, 233`; `op_session.dart:94, 150`; `update_route.dart:28–36`; `widgets.dart:30–36, 133`;
`settings_pages.dart:26, 27, 41, 126, 133, 148, 182, 295, 307–314, 340`; `home_logic.dart:155, 158, 171`;
`home_page.dart:208, 280, 288, 295, 340, 361, 414`; `more_pages.dart:84, 192, 211`; `member_ui.dart:186, 205`;
`node_page.dart:213`; `owner.rs:461, 2579`; `tests/statuspage.rs:305, 390`; `254-app-status-page.md:28, 60, 73`;
`329-app-uiux.md:682, 716, 976`; `329-honest-errors.md:158, 29–41`; the three greps (`.acquire(` callers,
`setPage(` callers, 「節點回報異常」).

Not verified by me: the two logcat files of §0 and the #366 device runs (outside the repository), and
254-p3-impl §3.3.

## 3. Negative controls (§7)

| Test | Fails on main / without the condition? |
|---|---|
| T1, T3, D1, D2 | Yes: main cancels and connects again (source: `core.dart:252`, `node_link.dart:900`, `:369`; device: §0). T3's stated control (wait after `core.acquireLease`) is right: `keptRead` returns false with no round (`core.dart:606`). |
| T1b, T2, T4, T6b, T14 | Pass on main (they pin "unchanged"); each needs its mutation named: detach without `_link != null`, without `_onPage`, wait without `forNode` / for another node, wait in `_makeRoom`, detach in `_pump`. §7's last line promises one per condition; list them. |
| T6, T7b / T8b, T15 / T15b, T16, T17, T11b | Yes, against the mutations the design names (no timer, `_abort` not completing, no single waiter, flag in place of identity, shared completer, no dispose check). |
| T12, T13 | T13 yes (park without the conditions). T12: see m1. |
| O1–O4, W1–W6, R1, H1–H7 | Yes on main (new behaviour); W4 lacks the `notSent` case (m10), H1 the node id (m11). |
| D5, D6 | No control recorded (m11). |

## 4. Only necessary changes

Nothing found that should be removed. `_det`, the per-attempt completer, the single waiter and the 8 s timer each
answer a trace that fails without them. The memo is small and enables nothing. The one place the design does more
than it needs is the gone waiter's lease round trip (m2), where returning null is both less code and less effect.

## 5. Verdict

**APPROVE-WITH-CHANGES.** No BLOCKER, no MAJOR. Before the design is frozen: correct m1 (statement and T12), take
m2's `gone()` check, and settle m3–m6 in the text so the implementation has one reading. m7–m12 are additions to
the matrix, the "Not handled" list, the tests and the cites.
