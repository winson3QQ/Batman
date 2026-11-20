# Review r7-A — 329-takeover.md v7 (129184f)

Reviewer A, round 7. Read-only: the design (whole), r6-A / r6-B, `a2lib-v2.sh`, `a2repro2-v2.sh`, `a2size-v2.sh`,
`node_link.dart` (whole), `core.dart:190–909`, `op_session.dart:55–174`, `prober.dart` (whole), `app_link.dart:170–270`,
`settings_pages.dart:20–200, 370`, `more_pages.dart:125–140`, `net_pages.dart:195–228`, `secure_screen.dart`,
`ble_gate.dart:185–312`, both logcat captures (BMAPP lines), `a1-home-c1.png`. Nothing was run on a phone or a node.

Scope items 1–3 are taken as fixed. Main's behaviour is the baseline.

**Verdict: APPROVE-WITH-CHANGES** — 0 BLOCKER, 1 MAJOR, 5 MINOR. The mechanism (1.1–1.3), ownership, contracts and
the lifecycle matrix hold against source; no stuck state, double completion or leak found with the v7 wording. The
MAJOR is in §7's device rules only (one definition), and its fix is one clause.

---

## MAJOR

### M1. "End of a login" (§7 device rules) counts a per-attempt line as an end: a correct build fails D5 on a path the design allows

**Scenario.** D5: the taken-over attempt to 04 ends without a body during the 「國家」 wait (row "Same, attempt
fails" / T5; seen on the device, the design's own "taken over, no answer" case). 「國家」 gets the lease and logs in
from the start. That login's first attempt gets no response, its second logs in. One login, correct behaviour,
「國家」 shows its value, no busy line. The log between the 「手機 Wi-Fi」 tap and the value has **two** lines that
v7 defines as "end of a login": `loginFor …9E×…7d2c result=noResponse after …ms` and
`loginFor …9E×…7d2c result=body after …ms`. D5's "exactly one end of a login for 04" fails.

The "taken over, no answer" exemption is written for D1 / D2 only, so D5 has no way out, and by the global rule
this FAIL would then need an attribution.

**Evidence.**
- The line is printed once per **attempt**, not per login: `_lfAttempt`, `node_link.dart:592`; the login loop calls
  it again after a failed attempt (`:476–486`, `continue`).
- One login with two such lines is in the capture: `a2-repro-2026-11-20.logcat`
  `11:47:45.800 … loginFor …9E×…7d2c result=noResponse after 5030ms` and
  `11:47:53.851 … loginFor …9E×…7d2c result=body after 2048ms`, with one core start line between them
  (`nl 1065.4 loginFor …7d2c`). That is 1 of the 4 logins in that capture.
- A login that fails altogether prints N `result=…` lines **and** the `:502` line: also more than one "end".
- The third form, "`loginFor …7d2c -> <end>` (`:502`)", is not separable by eye from the core's per-attempt line
  `  loginFor …9E×…7d2c -> noResponse` (`core.dart:880`; capture `11:47:50.235 … nl 1083.0`), which is not an end
  either. The two differ only in `…7d2c` against `…9E×…7d2c` and in the `nl` number.
- Not every end prints a line: `LoginForEnd.noLease` (`node_link.dart:438, 473, 477`) and `precondition` before the
  scan (`:441`) return without a trace. For D6 ("the page's login has an end") a `result=noResponse` line of a
  first attempt satisfies the clause while the login is still running.

r6-A's fix text was `result=body|errorCode`; v7 wrote `result=<res>`.

**Fix (text only, §7 "End of a login").** An end is exactly one of:
1. trace `loginFor <addr×id> result=body after Nms` (`:592`; the login returns at `:491`);
2. trace `loginFor …7d2c -> ok (kept link)` (`:451`);
3. trace `loginFor …7d2c -> <end>` with **no `nl` number and no `×`** (`:502`), for an end that is not ok.

A `result=` line with any other value is one attempt of a login that goes on, not an end. Add one sentence: a login
that ends `noLease` or an early `precondition` prints no end line; if D6 meets that, it is reported as such with the
log, not as a pass.

---

## MINOR

### m1. D1 / D2: the `after` comparison is the definition of "in flight at the tap", but it stands under Pass

"Counted: taps where the attempt in flight is to 04" has no log rule of its own; the only way to tell is the one in
Pass ("its `after` ms is greater than the time from the tap to that line"). Two correct-build tries then read as
FAIL instead of "not counted":
- the attempt to 04 was still in `_makeRoom` at the tap: aborted without any `attempt` line (`_run` returns at
  `node_link.dart:999`, before the trace at `:1028`), the round's own attempt follows, the round prints
  `…×…7d2c -> body`, not `kept` (rows T1b / T6b: "cancel", by design);
- no attempt was running at the tap, or it started in the about 0.3 s between the script's clock read and the tap's
  delivery (`after` counts from the connect start, `t0` at `:1003`).

Fix: move the comparison into Counted ("counted when the first `attempt …×…7d2c` line after the tap has `after` ms
greater than the tap-to-line time, and comes more than 0.3 s after the tap"), and say that a try with no such line
is "not counted", listed in the tap table. Main still fails: its aborted attempt prints `noResponse` in the same
millisecond as `round N full` (step1 capture lines 2694–2696), which the 0.3 s rule and "exactly one attempt line"
both catch.

### m2. The scripts for D1, D5, D6, D7 do not exist, and the shared part cannot run D5 as written

Only `a2repro2-v2.sh` (D2) and `a2size-v2.sh` are in `329-reviews`. §7 says the scripts "are replaced before any
run"; D1 still names `a2step1.sh`. For D5 the library is short of two things:
- `back()` sleeps 2 s (`a2lib-v2.sh:49`); D5 needs 「更多」 0.6–1.5 s after Back.
- `WIFI` is cleared only inside `back()`, which taps Back again (`:48–51`). After a Back sent by hand the flag
  stays 1, `dump()` refuses (`:37`), and D5 is "counted" only when a dump shows the 「國家」 page: no try can count.

Fix: a Back without the sleep, and a check-only function (`[ "$WIFI" = 1 ] && { secure || WIFI=0; }`, no tap), used
once on the 「國家」 page before its dump. That keeps the rule as written ("a Back after which the size check says
not secure"). Also: every `dump()` runs `secure` first, so D5 and D7 depend on a screencap of 「更多」 / 「國家」 being
over the threshold; `a2size-v2.sh` measures home, the node page and 「手機 Wi-Fi」 only. Add those two sizes to it
(it fails closed today: a small 「國家」 picture would make D5 / D7 "not shown", never a leak).

### m3. D6 has no "counted" condition

D6 passes when the attempt had already ended and the kept-link login was over before the HOME key, i.e. without a
wait in progress at the background. A build whose waiter is not woken by the abort (it sits out its 8 s timer) also
passes all three clauses. The design names T7b as the negative control, which is right; the device text should say
what it shows. Fix: count a D6 try only when an `attempt …×…7d2c … result=noResponse` line stands within about
0.3 s of the `nodelink lifecycle` hidden / paused lines (the abort at `background`, as step1 capture line 1065 on
main) and no `loginFor` line precedes it; otherwise "not counted", and with fewer than 2 counted D6 is reported as
"smoke only (T7b)".

### m4. T1's second case cannot be built as written ("from `Page.other`")

On `Page.other` no round is eligible (`core.dart:222`) and `setPage(Page.other)` → `_pump` aborts the attempt
(`node_link.dart:900`), so no attempt is in flight to take over. The net pages set `Page.home` when they open
(`net_pages.dart:203`), and that home round is what can be mid-attempt at `dispose` → `setPage(back, node)`
(`:224`). Fix: T1 second case and the §4 row say "from `Page.home` (a net page's round)". From `Page.other` the test
can only pin "nothing to detach".

### m5. Fixed tap coordinates against a home whose hero changes height with this change

The scripts tap 04's card at y = 1563 (`a2repro2-v2.sh:16`, `a2size-v2.sh:6`). In `a1-home-c1.png` (main, 02
joined-critical, yellow hero with the sentence and the button) 04's card is at about y = 2110–2260 and y = 1563 is
empty hero space. D3 needs 02 in exactly that state, and 1.3 makes the hero short on the new build only, so "the
same script on the main APK first" (D5, D6, D7 baselines) taps a different place than on the new APK while 02 is
in that state. The "missed" rule keeps this from becoming a false pass, but the baseline would be all misses. Fix:
state for each script which home state it assumes (02 not critical for D1 / D2 / D5–D7, or D3 run last), or take
the card's y from a home dump (home is not a secure page).

---

## §7 device rules and D1–D7: (a) correct build passes, (b) main / control fails, (c) lines exist as named

| Item | (a) | (b) | (c) |
|---|---|---|---|
| Clock rule | — | — | yes: trace lines have no `nl` number (`app_link.dart:184`); core lines of a login arrive together (repro 11:46:13.229, `nl` 986.9–990.4) |
| End of a login | no — M1 | — | `:592`, `:451`, `:502` exist; the definition is too wide |
| 0.3 s rule, "no answer" rule | yes | yes | aborted attempt in the same ms as `round N full`: step1 2694–2696 |
| Secure-page rule | scripts follow it (below) | — | — |
| D1 | yes on the takeover path; `_makeRoom` / late-start paths ambiguous — m1 | yes (§0 row 1: `noResponse` line, second attempt, no `kept`) | `attempt … connected=…ms result=… after …ms` `:1028`; `  kept …7d2c -> body green` `core.dart:623`; `round N end {…7d2c: read}` `:723` |
| D2 | yes (own-round and detached paths both give one 04 attempt line; a stale-address detached failure falls under "no answer"); the 1 s bound holds: nothing between the attempt's end and `:451` waits on the radio (`_park` synchronous `:644`, parked link not counted by `gate.active` `ble_gate.dart:195`) | yes (no `kept link` line in either capture; logins from the start) | `:451` format confirmed in source; no capture of it on this pair of files (count 0) |
| D3 | yes if 02 is in the state (the "not run" rule covers the rest) | yes: `a1-home-c1.png` shows the yellow hero, the sentence, 「看這台節點」 | screenshots, no log |
| D5 | expected path yes; "attempt fails → own login with a retry" no — M1; cannot be run with the library — m2 | unit controls T15 / T15c as stated | busy text `settings_pages.dart:41` |
| D6 | yes, or "no pass claimed" by the main comparison | not by itself — m3 | `BMAPP nodelink lifecycle resumed` `app_link.dart:266` (no `nl` prefix) |
| D7 | yes when a dump lands in the read; else "not shown" | yes: main prints 「讀取中…」 `settings_pages.dart:370`; 「國家」 is outside `SecureScreen` (`:182` is the Wi-Fi page only) | dump text, no log |

## The three scripts against the secure-page rules

- No path dumps the 「手機 Wi-Fi」 page: `tap_wifi` sets `WIFI=1` before the tap (`a2lib-v2.sh:46`); `dump` refuses
  on `WIFI=1` and again on `secure` (`:37–38`); `descs` only goes through `dump`; `home` backs out instead of
  dumping while `WIFI=1` (`:55`). `a2size-v2.sh` has no dump at all. `a2repro2-v2.sh` dumps only in `home` (start
  of each loop, end).
- Fail-closed: `capsize` returns 1 on a screencap error or a non-numeric size, `secure` then answers "secure"
  (`:17–20, 26`). A stuck flag ends as `STOP: not home`, not as a dump.
- Nothing is kept: `a2chk.png` and `ui.xml` are removed on the phone after each use (`:17, 19, 33`); the picture is
  never pulled.
- The one fail-open is the threshold itself: if a screencap of the secure page were 30000 bytes or more on the
  S20, `back()` would clear the flag while the page is still up. The design says so (§5 ⚠️) and puts
  `a2size-v2.sh` first; that order must hold, and the PR must carry both numbers before any other script runs.

## Mechanism 1.1, traced once more (v7 wording)

- Stuck: while `_attempt != null` the pump starts nothing (`:911, 928`); every way out of `_run` completes `ended`
  (`finally`), `_abort` completes it through the field; the waiter also has its own 8 s timer. No path leaves a
  waiter without a wake.
- Double completion: `isCompleted` is checked on both sides; a late `_run` of an aborted attempt nulls the field
  only `if (identical(_ended, ended))` and clears `_det` only by identity.
- Link: a detached attempt's link is closed at `:1034` (no keep) or parked / destroyed by the `:1051` rule with
  `taken`; on abort `_abort` closes `_link` and the late `_run` destroys a keep at `:1037`.
- Timer: stopped on wake; `dispose` clears the waiter.
- Lease: none is taken before the wake; a gone or replaced waiter returns null without `core.acquireLease`, so the
  round is not cancelled for a closed page.
- After a body the tail `_pump` cannot start a kept read on the link just parked (the round has its read), so the
  waiter's `acquire` finds it `parked`, not `reading`.

---

## Verified / inferred / not verified

**Verified (source or capture read by me):** every file:line above; the per-attempt `result=` line and the
two-line login in the capture; `attempt`, `round`, `kept`, `loginFor`, `lifecycle` line formats and their clocks;
`setPage` callers; `Page.other` runs no round; the scripts' paths as listed; the D3 negative-control screenshot;
main's 「讀取中…」 on 「國家」.

**Inferred:** D2's 1 s bound (from the code path, no capture of a kept-link login in these two files; the 0.1 s
figure is the #366 PR's); that D5 will seldom be "counted" (the 「國家」 tap comes about 3–4 s after the 04 tap,
attempts take 2.9–4.8 s) — the design's "not shown on the device" exit covers it; m5's baseline misses (from one
screenshot; I do not know the home state during the 11:46 and 12:21 captures, where y = 1563 did open 04).

**Not verified:** anything on a device (sizes of secure and non-secure screencaps, D1–D7 themselves); the old
`a2step1.sh` / `a2repro2.sh` (not found in the folders given); `home_logic.dart`, `node_page.dart` and the Rust
side for 1.3 beyond what r6 covered; `KeyAbilities.read` latency.
