# Review r7-B: `329-takeover.md` v7 (129184f)

Reviewer B, round 7, independent. Whole document reviewed against main 99d156a (`app/`), the two captures and the
screenshot in `Desktop\Batman\a1\`, and the three device scripts in this folder (`a2lib-v2.sh`, `a2repro2-v2.sh`,
`a2size-v2.sh`; written, never run). Read-only: no device, node, adb, flutter, cargo or state-changing git command
was used; nothing was run. Baseline documents, the existing behaviour of main and the three scope items were not
re-reviewed.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 0 MAJOR, 10 MINOR.**
Five are test or criterion wording (a named mutation or case that cannot fail as written), four are about the device
scripts and how D1/D2 count a tap, one is a count. None changes the mechanism of 1.1–1.3 and none asks for a new
mechanism. No further whole-document round is required by the rules.

## 1. What was checked and holds

Method: the design in full (619 lines); then every file named in this round's emphasis, opened at the cited lines
and around them; both captures searched for each number and each log line format the design names; the three
scripts read line by line.

### 1.1 against `node_link.dart` and `core.dart`

`setPage` (`node_link.dart:303–311`) calls `core.setPage` and then `_pump()`, so line 900
(`if (a != null && !identical(core.running, a)) _abort();`) runs directly after any change of page. `acquire`
`:352–380`, `_pump` `:893–`, `core.setPage` `core.dart:244–265` (X33 `:258`), `foreground` `:279–283`, `refresh`
`:337–345`, `_pageTargets` / `_eligible` `:216–222` are as the design describes them. The trace lines the design
names exist in the stated format: `node_link.dart:451, 502, 592, 1028`; `core.dart:421, 427, 534, 623, 655, 723,
786, 832, 880`; `app_link.dart:184, 266`. I found no interleaving in 1.1 (a) / (b) that the text leaves undefined;
see m2 for one mutation that the mechanism itself makes equivalent.

### 1.2 against `settings_pages.dart` and `op_session.dart`

Every cite is correct (`can` `:178`, right side `:190`, `_cc` `:300`, `_blocked` `:307–314`, row `:370`, radio
`:376`, `enabled` `:378`; `once` `op_session.dart:91–`, `gone` `:93` and `:112`, `acquire` `:94`, busy `:95`).
`SettingsView` has no passphrase field (`owner.dart:573–574`), so `SettingsMemo` holding a label only keeps nothing
secret. `OpDeps`'s constructor is `const` (`op_session.dart:60`) but no call site constructs it `const` (grep), so
a per-instance default memo is possible.

### 1.3: readers of `warning`

Rust: `Verdict` `statuspage.rs:111`, `warning` `:118`, texts `:122–125`, `warning()` `:314–336` (`WARN_JOINED_CRIT`
`:333`), `link_verdict_for` `:344`; pins `tests/statuspage.rs:303–305, 390`; bridge `owner.rs:461, 2579, 2792`.
Dart readers (grep): `home_logic.dart:155, 158`, `node_page.dart:213`, `more_pages.dart:192, 211, 313`,
`member_ui.dart:186, 205`. This is the table in 1.3; none is missing. (The file is `lib/member_ui.dart`, not under
`lib/ui/`.) The text 「節點回報異常」 exists outside reviews only in `statuspage.rs`, `tests/statuspage.rs`,
`254-app-status-page.md` and `329-honest-errors.md`, as the design says.

### §0 and the captures

`a2-step1-2026-11-20.logcat`: the four 7d2c attempts (file lines 1065, 2696, 18662, 23648; 3594 / 736 / 1696 /
2201 ms) each have `round N cancelled` and `round N full […7d2c]` in the same millisecond; 11 `result=body after`
lines (2907–4802); line 25725 is a real `noResponse after 1609ms` to 880c with `gate link … down fail=133`.
`a2-repro-2026-11-20.logcat`: lines 4689–4692 as quoted; 0 `kept link` lines; aborted attempts at the three
counted Wi-Fi taps 524 / 465 / 104 ms; the fourth launch's attempt in flight was to 880c and its
`loginFor … result=noResponse after 5030ms`; the fifth launch has its body at 11:48:49.039, before the tap at
11:48:49.696, and no `loginFor`. `a1-home-c1.png` shows main with the yellow hero 「注意 / 02：節點回報異常…」, button
「看這台節點」, and both rows green: D3's negative control exists on main.

### §2–§6

Cites spot-checked and correct: `update_route.dart:28`, `dev_pages.dart:183, 274, 459`, `join_pages.dart:117, 721`,
`rekey_send.dart:112, 139`, `remove_pages.dart:102`, `offline_op.dart:118`, `raw_use.dart:74, 88`,
`net_pages.dart:271, 342, 917`, `team_deps.dart:23–25`, `ble_gate.dart:195, 302–309`, `prober.dart:129–132, 233`,
`more_pages.dart:84, 136, 258`, `home_logic.dart:155–159, 171, 179`, `home_page.dart:43, 295, 321–331, 340, 361,
414–415`, `widgets.dart:30–36, 162–163`; documents `254-app-status-page.md:28, 60, 73`, `329-app-uiux.md:682, 716,
976`, `329-honest-errors.md:14, 158`. The "today" columns I checked are true except the two places in m1 and m10.
I found no lifecycle path or resource missing from §2–§4.

### §9, round-6 table

A-M1, A-M2, A-m1 … A-m4, A's note and B-m1 … B-m6 are each applied in the section the table names (1.1, §4, §5,
§7), and I found no place where the older wording is left over.

### Tests that hold

T1b, T3–T17, O1, O2, O4, W1–W4, W6, R1, H1–H7 each have an assertion that fails on main or under the named
mutation (for example H7: the `seeNode` mutation adds `extra` and so height, `widgets.dart` `...?extra`; W3: the
mutation enables the rows through `_blocked()`). The exceptions are m1–m4.

### Device criteria that hold

D2 passes on a correct build with either node in flight at the 04 tap (both occur in the repro capture) and fails
on main (three aborted attempts above). D3 fails on main (screenshot). D5: one `loginFor` end on a correct build;
main gives busy or two logins. D6 and D7 are consistent with 1.2 and 1.3. See m5, m6 for how a tap is counted.

### Secure page: the scripts

`capsize` never pulls and deletes the file; it returns 1 on an error or a non-numeric size, and `secure()` treats
that as secure (fail-closed). `dump()` refuses when `WIFI=1` or `secure`; `_dump` deletes `ui.xml`. `tap_wifi` sets
`WIFI=1` before the tap; `back()` clears it only when not secure. Taps in the two scripts are the 04 card, the
Wi-Fi entry and Back only (KEYCODE_HOME and the monkey launch are not taps). With the size threshold holding and
the script started from Batman's home, I found no path that dumps, pulls or keeps the 「手機 Wi-Fi」 page. The
precondition is m8.

## 2. Findings

### m1 (MINOR, false statement in a test and in §4) — T1's second case names `Page.other`

Scenario: T1 (§7, lines 360–362) says the second case detaches "from `Page.other` (the net pages' way back)", and
§4's row for "back from a net page" (line 269) reads the same way. A net form page is not on `Page.other`.
Evidence: `net_pages.dart:203` sets `Page.home` in `initState`; `:224` `dispose` calls `setPage(widget.back, node:)`.
On `Page.other` there is no round at all (`core.dart:216–222`), so no attempt can be in flight and the case cannot
be built as worded. Only settings uses `Page.other` (`home_page.dart:340`).
Fix: write "from `Page.home` as set by the net page (`net_pages.dart:203`), back to the node page (`:224`)" in T1
and in §4's row.

### m2 (MINOR, negative control) — T2's mutation is equivalent

Scenario: T2 names the mutation "detach without `wanted`". With it, the attempt is detached wrongly, but
`setPage` calls `_pump()` at once and line 900 with `&& wanted(a)` aborts it in the same turn. The result T2
observes is the same as on a correct build, so T2 cannot fail under its named mutation.
Evidence: `node_link.dart:310` (`_pump()` after `core.setPage`), `:900`; design 1.1 (a) line 65.
Fix: name the mutation "`wanted` without the `core.pageNode == id` test (so both the detach and line 900 use it)",
or mark T2 as a regression pin with no mutation.

### m3 (MINOR, negative control) — O3 cannot fail at the level it is written

Scenario: O3 asserts "refused during a wait → a non-empty name". Every `OpDeps` rig in the tests supplies its own
fake `busyName` (`op_session_test.dart:56` returns `'建立網路'`; `kept_link_test.dart:379`, `join_pages_test.dart:219`,
`layout_test.dart:101`), so a build whose real `opDeps` lacks `?? a.link.waitingName` passes O3. The other half,
"while a lease is held", passes on main today (`op_session_test.dart:105`).
Fix: run the waiting half through the real `opDeps(AppLink)` (`settings_pages.dart:25–37`; `AppLink.create` is
usable in tests), or say O3's waiting half is covered by T15b plus one test of `opDeps`; mark the lease half as a pin.

### m4 (MINOR, negative control) — W5's "「送出」 is disabled" half

Scenario: W5's mutation is "the memo prefills the passphrase". 「送出」 is disabled whenever the field is empty or
the passphrase is invalid, and the mutation fills the field, so the button assertion fails only if the prefilled
value happens to be valid; with an empty memo value it passes. The "field is empty" assertion is the one that
catches the mutation.
Evidence: `settings_pages.dart:178` (`can = … && _pass.text.isNotEmpty && passBad == null`).
Fix: keep "the field is empty" as the assertion that must fail under the mutation; drop the button half or state
that it is not the discriminating one.

### m5 (MINOR, device criterion) — the 0.3 s rule is below the measured tap delivery

Scenario: the device rules count a tap when the attempt was in flight 0.3 s before it. The design's own numbers put
the delivery of a scripted tap at 0.31–0.37 s (four gaps of 1.01–1.07 s for a scripted 0.7 s). An attempt that
ended with a body just before the tap arrived can therefore be counted, and that try passes D1 on main as well (the
page's round reads the kept link). It does not let a wrong build pass overall, because the other counted taps fail
on main, but one counted try would be a false pass.
Fix: for D1 take the `round N full […7d2c]` line as the tap's arrival and require the attempt's end line after it,
not in the same millisecond; for D2 and D5 use a margin above the measured delivery (0.5 s).

### m6 (MINOR, device criterion) — a counted tap during `_makeRoom`

Scenario: on a correct build an attempt that is still waiting for room when the page changes is aborted (T1b, §8).
If a counted tap lands there, D1 / D2 read it as a fail of a correct build. The attempt's end line cannot tell the
two apart (`connected=-1ms` in both).
Evidence: logcat has `D/BluetoothGatt connect() - device: …` about 5 ms after each attempt's start (repro capture
lines 3690, 11092, 25035), so the start of the connect is visible.
Fix: count a tap only when that `connect()` line for the attempt precedes the tap; otherwise the try is "not this
case" and is repeated.

### m7 (MINOR, evidence) — `a2size-v2.sh` does not check which page it measured

Scenario: the script starts from calm home, taps (540, 1563), waits 20 s, and records "node page size", then taps
the Wi-Fi entry and records "wifi page size". Nothing confirms that either page was reached. On main today, with 02
joined-but-critical, calm home has the tall yellow hero; its bottom is at about y 1590 px and 04's row centre at
about y 2178 px, so (540, 1563) is inside the hero and both sizes would be home's.
Evidence: `a1-home-c1.png` (1080×2400); `a2size-v2.sh` (no dump, no check). The error is in the safe direction
(sizes look alike, so the fallback applies), but §5's ⚠️ row (line 331) would be filled with wrong numbers.
Fix: dump home and the node page before the Wi-Fi tap (both are not secure, so the rules allow it) and stop if the
node page's title is not there, or tap inside the steady window after a launch as `a2repro2-v2.sh` does; accept the
Wi-Fi size only with a `loginFor …7d2c` line after the tap.

### m8 (MINOR, secure-page rule, precondition) — the scripts assume Batman's home is in front

Scenario: `home()` and `a2size-v2.sh` never check the foreground app. Started with the launcher or another app in
front, `secure` says not secure, the dump is of that app, and `back` taps (84, 163) there: a tap outside the
allowed list. Also `WIFI` is 0 at start, so a script started while the 「手機 Wi-Fi」 page is open relies on the
size threshold alone, which §5 still marks ⚠️ unverified.
Evidence: `a2lib-v2.sh` `home()` (line 55 and after), `back()`; `a2size-v2.sh` start.
Fix: begin each script with the background and monkey launch that the loop already uses (or check the focused
package and stop), and add "started from Batman's home" to the device rules.

### m9 (MINOR, device rule "scripts are replaced before any run") — names and missing scripts

Scenario: D1 names `a2step1.sh` and D2 names `a2repro2.sh`; the files are `a2repro2-v2.sh` and `a2size-v2.sh`, and
there is no `-v2` of `a2step1.sh`. D5, D6 and D7 have no script. These four criteria could not be checked against
the secure-page rules.
Fix: name the `-v2` files in D1 / D2; attach the D1, D5, D6, D7 scripts (sourcing `a2lib-v2.sh`) before the first
run, or state that those steps are done by hand and by whom the Wi-Fi page is never captured.

### m10 (MINOR, count) — "all 11 `once` callers"

Evidence: §4 (line 295) says 11. Grep gives 12 `OpSession.once(` call sites: `settings_pages.dart:126, 148, 295,
340`; `dev_pages.dart:183, 274`; `more_pages.dart:258`; `join_pages.dart:117, 721`; `rekey_send.dart:112, 139`;
`remove_pages.dart:102`. §5's own list has these 12.
Fix: write 12.

Notes, no finding: `NodeRow`'s docstring says "home, team, pick" while its only user is `home_page.dart:415`; the
device header lists taps only, and D6 / D7 also background and launch the app (not taps).

## 3. Negative controls

- D1, D2, D3, D5: main fails each (captures and screenshot above). D6, D7: main fails by construction (no memo, no
  row note).
- T2, O3 (waiting half), W5 (button half), T1 second case: no failing control as written (m1–m4).
- All other T / O / W / R / H: the named mutation or main fails the assertion, by reading; none was run.

## 4. Verified / inferred / not verified

Verified (read at the cited lines or found in the captures):
- every cite listed in section 1; the 1.3 reader table; the 12 `once` call sites;
- every log line format named in D1–D7;
- §0's numbers in both captures;
- the three scripts' paths against the secure-page rules;
- the round-6 table's edits.

Inferred (by reading, not by running):
- that each test in "Tests that hold" fails under its mutation;
- that D2, D5, D6, D7 pass on a correct build;
- the hero and row positions in m7 (measured on the screenshot by eye, about ±20 px).

Not verified:
- anything on a device: nothing was run; the screencap size threshold stays ⚠️ as the design says;
- T14's "early round on the node page" can be built in a test;
- the four tap gaps of 1.01–1.07 s (taken from the design);
- the v1 scripts and PR #366's body (0.1 s).

## 5. Only necessary changes

All ten fixes are edits of wording, of a named mutation, of a counting rule, or of a script's first lines. None
adds a mechanism to the app.

## 6. Verdict

**APPROVE-WITH-CHANGES — 0 BLOCKER, 0 MAJOR, 10 MINOR.** Apply m1–m10; m7–m9 before the first device run.
