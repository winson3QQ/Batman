# Review r6-A: 329-takeover.md v6 (0b594d0)

Reviewer A, round 6. Read-only: no adb, flutter, cargo, device or node command was run; nothing but this file was
written. The whole document was read again, not only the v6 edits. Code read: main 99d156a in `C:\src\Batman-a2\app`
(`lib/src/nodelink/node_link.dart`, `core.dart`, `lease.dart`, `ble_gate.dart:192–195`, `app_link.dart:137, 184, 260–268`,
`lib/src/flows/op_session.dart:60–165`, `lib/ui/settings_pages.dart:26–27, 182`, `lib/secure_screen.dart:1–12`), both
captures (every `BMAPP nl round|attempt|loginFor` and `lifecycle` line), both scripts.

Not reviewed, as told: the baseline documents, main's behaviour, the three scope items.

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 2 MAJOR, 4 MINOR.

The mechanism in 1.1 holds; I found no stuck state, double completion, leaked link or leaked timer (trace below).
Both MAJOR findings are in the device criteria and are of the class that was MAJOR in rounds 4 and 5: a criterion a
correct build cannot meet, because the log line it names is not printed on the path the design itself expects.
Both are text changes to §7; no code or mechanism is asked for.

## What was checked and holds

Mechanism (1.1), traced against `node_link.dart` and `core.dart`:

1. **Order at the end of `_run`.** `_park` is synchronous up to `gate.pass(h.link, null)` (`node_link.dart:644–669`),
   so the link is in `_kept` as `parked` before `ended` completes; the tail `_pump()` then ends the round at once
   (`core.tick`, `allDone`, `core.dart:649–664`). The waiter resumes as a microtask after that synchronous tail.
   When it runs `_dropAll`, `gate.active` does not count the parked link (`ble_gate.dart:195`: open and token null),
   so there is no 100 ms polling, and `_loginFor` finds `parked` and `_onPage` (`:446–452`).
2. **Double completion.** `ended` is completed by `_abort` (through the field) or by `_run`, each behind
   `isCompleted`; the `finally` covers `:999` and `:1038`, which return without a pump. An attempt aborted in
   `_makeRoom` returns at `:999` after `_abort` already completed its `ended`: one completion.
3. **Late end of an aborted attempt.** `_run` of A after B started: `!identical(_attempt, a)` → `keep?.destroy()`,
   return; the field `_ended` is nulled only `if (identical(_ended, ended))` and `_det` only `if (identical(_det,
   a))`. B is untouched (T17).
4. **Attempt ends without a body during a wait.** `core.result` → tail `_pump` → `_run(next)` runs synchronously to
   its first `await` (`_makeRoom`), so `_attempt` is B before the waiter's microtask; the waiter's lease path
   aborts B (`:369`); B's `_run` returns at `:999`. No second wait, no link (B never reached `gate.connect`).
5. **8 s timer.** Fires → the waiter takes today's path → `_abort()` completes `ended` with no listener left. A
   replaced waiter whose timer fires returns null without `_abort` (it is replaced), so the second waiter's attempt
   goes on. A gone, not replaced waiter whose timer fires returns null and the attempt goes on with no waiter.
   Each timer is stopped on wake.
6. **Call without `forNode` during a wait (v6).** C: `core.acquireLease` → `_abort()` → `ended`. C then suspends at
   `await Future.wait(closes)`. The waiter W wakes at `reg.current == null`, calls `core.acquireLease` again
   (no round left: `_cancel` returns, `core.dart:424–426`; `lease = true` again), `_abort()` (no-op), and both sit
   in `_dropAll`. `LeaseRegistry.acquire` (`lease.dart:135–136`) gives one lease and one null. This is main's
   behaviour for two concurrent calls. In real use a live waiter's page covers the node page, so C can only come
   after Back, when W is gone and returns null: T4b is a defensive pin, correctly labelled.
7. **Detach while the link is closing (v6).** At `:1034` `keep == null` and `_link` is still this attempt's. A
   `setPage` or an `acquire(forNode)` in that `await` sees `_link != null`; after the close the attempt is still
   `_attempt`, goes down the detached branch (or `core.result` if it is the round's own), completes `ended`.
   Nothing to park. No stuck state.
8. **`refresh` on a full round (v6).** `core.dart:341` returns before `_cancel`; `notY.clear()` on the line before
   does not touch the attempt. The row and T14b are right.
9. **Bound of a detached attempt.** While `_attempt != null` the pump starts neither a kept read (`:911`) nor an
   attempt (`:928`); the scan of the new round may start (`:923`), which is harmless. The attempt is bounded by
   `msg2` (8 s timer at `:1002`) and the prober's limits.
10. **Leaving the page / background / radio during a wait.** `background()` → `core.background` (`fg = false`) →
    `_pump` → line 900: `wanted` false → `_abort` → `ended`. `_loginFor` does not ask `core.fg`
    (`node_link.dart:425–441`), so the waiter's login then runs in the background, as a login does on main.
11. **`dispose`.** `_disposed = true` before `_dropAll` → `_abort` → the waiter wakes, sees disposed, returns null.

Text against code:

- `busyName` is defined at `settings_pages.dart:27` as stated; `opDeps` at `:26` is where `forNode` / `gone` go.
- `OpSession.once` (`op_session.dart:94–137`): `gone()` before `acquire`, after the login, before the requests. The
  new "null lease with `gone()` true → `OpEnd.gone`" and "lease with `gone()` true → released" fit in the two
  lines after `:96`.
- §0's numbers were read again in both captures and match (step1: 736 / 1696 / 2201 ms cancelled attempts with
  `round 46 / 55 / 58 full […7d2c]`; repro: 524 / 465 / 104 ms, logins `result=body after 2824 / 4060 / 2799 ms`,
  the fourth launch's `noResponse after 5030ms` then `body after 2048ms`; fifth launch body at 11:48:49.039, round
  37 cancelled at .696, round 38 `kept …7d2c -> body`, no `loginFor`).
- Clock rule: trace lines go straight to `debugPrint('BMAPP nl $l')` (`app_link.dart:184`); core lines are
  forwarded only in `_pump` (`_forwardLog`, `node_link.dart:937`). Repro lines 4689–4692, 12107–12110, 20212–20215,
  26033–26036 show the core's `loginFor` lines of one login at one logcat time, after the trace `result=` line.
- D1 is decidable and discriminating as written: a detached answer is logged by `core.keptRead` as `  kept <id> ->
  body <view>` (`core.dart:623`), a round's own as `  <addr×id> -> body <view>` (`:534`); an attempt aborted at
  the tap prints its `attempt` line in the same millisecond as `round N full […7d2c]` (step1 lines 2694–2696,
  18660–18662, 23646–23648). On main a `kept` line in the page's round needs the attempt to have ended before the
  tap (repro round 38), which D1's `after` rule excludes.
- D2's two branches at the 04 tap both give one `attempt …×…7d2c` line on a correct build (tap during the attempt
  to 04: detached; tap during the attempt to 02: `…×…880c` line, then the round's own attempt, waited for).
- D3, D7: nothing new. 「國家」 is not inside `SecureScreen` (`settings_pages.dart:182` is the only one in that
  file), so D7's dump is allowed.
- Security: the memo holds no passphrase; the name is printed only inside `SecureScreen`; the device rules forbid
  any dump from a 「手機 Wi-Fi」 tap to the Back that leaves it, and make `secure` fail closed. No new input.

## Findings

### MAJOR

**M1. D6 names login end lines that a successful login does not print, and requires them after `resumed`, where
the login has usually already ended.**

D6 pass: "after the `nodelink lifecycle resumed` line of the return there is an end line of the page's login
(`loginFor …7d2c -> ok (kept link)` or `loginFor …7d2c -> <end>`)".

- `loginFor <id> -> <end>` is the trace at `node_link.dart:502`. It is reached only when the loop breaks without a
  handoff. A login that succeeds returns at `:491` and never prints it. Its only end lines are the trace
  `loginFor <addr×id> result=body after Nms` (`:592`) and the core's indented `  loginFor <addr×id> -> body`
  (`core.dart:880`). All four successful logins in the repro capture show this (lines 4662 / 4692, 12082 / 12110,
  21184 / 21190, 26009 / 26036); the capture has no `loginFor …7d2c -> ` line at all.
- `-> ok (kept link)` cannot be printed in D6: the background closes every kept link (`_closeIdle`,
  `node_link.dart:315`) and `:448` needs `_onPage`, which needs `core.fg`.
- Timing on a correct build: the wait ends at the `hidden` line (finding 10 above), the lease follows when the
  aborted link is gone, the login runs in the background and takes 2.0–4.1 s when its first attempt answers
  (capture), so it ends about 2–6 s into the 8 s. Its end line is then before `resumed`, not after.

So the likely correct course (login succeeds in the background) fails D6 twice over. A course that passes as
written is a login that ends `notFound` / `precondition` after the return. This is r5-B M1 again; the v6 wording
did not fix it.

Smallest fix (text): define "the end of a login" once in the rules block and use it in D5 and D6: the first of
(a) trace `loginFor …×…7d2c result=body|errorCode after …`, (b) trace `loginFor …7d2c -> ok (kept link)`,
(c) trace `loginFor …7d2c -> identity|refused|notFound|precondition`; a login that ends `noLease` prints none.
D6 then reads: after the 「手機 Wi-Fi」 tap there is one login start (`loginFor …7d2c`, core line) and its end,
before or after `resumed`; the 40 s `round N end {…7d2c: …}` clause stays as it is (if the lease is released in
the background `core.foreground` begins the round at `resumed`, `core.dart:279–283`; if it is still held, the round
comes 6 s after the release, `:334`).

**M2. D5 requires exactly one `round N cancelled` between the 「手機 Wi-Fi」 tap and the value; on the path D5
itself expects (the attempt ends with a body) a correct build prints none.**

Trace: the 04 tap's `round N cancelled` is before the 「手機 Wi-Fi」 tap. 「手機 Wi-Fi」 waits, Back, 「國家」
replaces the waiter. The attempt ends with a body → `keptRead` / `core.result` → parked → tail `_pump` →
`core.tick`: `allDone` → `round N+1 end {…7d2c: read}` (`core.dart:649–664, 723`). The waiter then calls
`core.acquireLease` → `_cancel` with no round → no line (`core.dart:424–426`). Count: 0. Main shows the same
shape in the repro capture's fifth launch (round 38 ends, no `cancelled` follows). The count is 1 only when the
attempt ends without a body and the round has started another attempt. D5's next clause ("one `-> ok (kept
link)` line (when the attempt ended with a body)") expects the path on which the count is 0.

The reason given for the count is also not true: "two would mean the closed page took the lease". After the first
lease there is no round until 6 s after its release (`core.dart:334`, `afterLease = 6000`), so a second lease in
that window never prints a second `cancelled`. The line count cannot show who took the lease in either direction.

Smallest fix (text): drop the `cancelled` count. What does discriminate is already in D5: no 「另一個操作還在進行」
in the dump, and exactly one login for 04 (a closed page that took the lease and logged in gives two starts or a
busy line). If a round line is wanted: "`round N end {…7d2c: read}` and no `cancelled` when the attempt line is
`result=body`; one `cancelled` otherwise". "The closed page took no lease" stays with T15c, where it is asserted.

### MINOR

**m1. D2 / D5 / D6 "counted" at the sub-page tap has no margin for the tap's delivery; a try where the attempt
ended just before the tap landed is counted and passes on main.**
The sub-page tap has only the adb clock (no app line is printed when a call starts to wait). In the repro capture
the gap between the two taps as the app saw them is 1.01–1.07 s for a scripted 0.7 s, so reading the clock and
delivering a tap takes about 0.3 s (inferred from those four gaps). An attempt that ends with a body inside that
0.3 s is "in flight at the tap" by the script's time, but the tap finds a parked link: one `attempt …×…7d2c
result=body` line, then `-> ok (kept link)` — D2 passes, on main too (the fifth repro launch is this shape, except
that its tap did not register). Fix (text): at a sub-page tap a try is counted only if the attempt's line comes
more than 0.3 s after the tap time, the same band D1 already has.

**m2. D1 / D2: a taken-over attempt that ends by itself without a body fails "exactly one attempt line,
`result=body`" on a correct build.**
This is the designed path of T12 (the round's own attempt follows), and attempts do end that way by themselves:
step1 line 25725, `attempt …AF×…880c connected=-1ms result=noResponse after 1609ms`, in a round nobody cancelled.
It is decidable from the log: an attempt aborted at the tap prints its line in the same millisecond as `round N
full […7d2c]` (all three main cases); one that ended by itself prints later. Fix (text): such a try is listed as
"taken over, no answer" and is neither a pass nor a fail of D1 / D2.

**m3. D6 "every `round N` start line in the capture has its `end` or `cancelled` line" fails for a round still
running when `logcat -d` is taken.**
Home rounds start every 15–20 s and take 3–5 s when a node needs an attempt (both captures), so the capture's end
falls inside one about one time in four. Fix (text): the last round is exempt when the capture ends less than
90 s (the cap) after its start line.

**m4. §4 row and 1.1: "the page's round ends at its window while a detached attempt runs" is not what the core
does once the node's address is seen in that round.**
`core.tick` ends a round at the window only when `!pending` (`core.dart:650–651`); the core never counted the
detached attempt, so the node's address is still a candidate (`_candidates`, `:472–489`) and the round runs to
the cap (90 s). The row's outcome is right either way and it is marked defensive; only the words "at its window"
(1.1, §4, and how T14c brings the round to its end) should read "at its window or cap".

Note, not a finding: the clock rule says it is not known whether `-> ok (kept link)` is printed when it happens.
From source it is: `:451` is a direct `trace?.call`, the same sink as the `attempt` line (`app_link.dart:184`).
The planned check in the first D2 run costs nothing and can stay.

## Negative controls

| Claim | Can it fail? |
|---|---|
| T1 / D1 take-over | Yes: main prints a `noResponse` line and `…×…7d2c -> body`, not `kept` (step1, 3 of 3) |
| T3 / D2 wait then kept link | Yes: main has no `kept link` line in 3 of 3 (repro). See m1 for the one shape that passes on main |
| T14 mutation (`wanted(a)` alone on line 900) | Yes: the round's own cut attempt would live on |
| T14b | Fails without the exception on line 900 (same as T1); passes on any build that has it. A pin, not a separate control |
| T14c | Reachable only with a fake prober that ignores `due`; defensive, labelled so |
| T4b | Passes by `LeaseRegistry.acquire` alone; its own content is "no waiter and no timer left" |
| T15c | Yes: without the `gone()` test on wake the round is cancelled and a lease is taken |
| D5 | As written: a correct build fails on the body path (M2) |
| D6 | As written: a correct build fails (M1) |
| D7 | Yes: main shows 「讀取中…」; honest fallback when no dump lands in the read |

## Verified / inferred / not verified

Verified (source or capture opened this round): every `file:line` cited above; the log formats of `core.dart:421,
427, 534, 623, 655, 723, 786, 880` and `node_link.dart:451, 502, 592, 1028`; §0's numbers in both captures; the
late, grouped arrival of the core's `loginFor` lines; M1 and M2 from source plus the repro capture.

Inferred: the 0.3 s tap delivery time (from four tap gaps in one capture); that a login started in the background
on the S20 scans and connects as it does in the foreground (main does the same; D6's main baseline run will show
it); the timing of M1's correct course (2–6 s into the 8 s); that `SecureScreen` shows its child only once the flag
is set (header comment of `secure_screen.dart`, body not read).

Not verified: anything on the device; the changed scripts (they do not exist yet: both scripts are still the
captures' versions, `secure` still fails open on an empty size and `a2repro2.sh` still calls `descs` 16 s after the
「手機 Wi-Fi」 tap; the rules block says both are changed before any run, and no D5 / D6 / D7 flow is written
yet); `debugPrint` throttling under heavy output (the captures show no reordering); 1.2 and 1.3 against
`home_logic.dart`, `widgets.dart`, `statuspage.rs` were not opened again this round (unchanged since r5, where
they were checked).

## Only necessary changes

All six findings are wording in §7 (five) and §4 / 1.1 (one). None asks for a mechanism, a test or a code change.

## Verdict

APPROVE-WITH-CHANGES: fix M1 and M2 in the text of D5 / D6 (one definition of a login's end; drop or correct the
`cancelled` count); m1–m4 in the same edit.
