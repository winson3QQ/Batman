# Review r5-B: `329-takeover.md` v5 (ad2a3c2)

Reviewer B, round 5, independent. Whole document read; this round's weight is on §1.3 (variant without a button),
§1.2 wording, §7 device checks D1–D7 with the rule above D1, and §0's numbers. Checked against the worktree source
(`app/`, code = main 99d156a), the two captures in `Desktop\Batman\a1\` and the two device scripts in the session
scratchpad. Read-only: no device, node, adb, flutter, cargo or git state was touched; nothing was run. Baseline
documents and the three product decisions were not re-reviewed.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 1 MAJOR, 8 MINOR.**
The MAJOR is one device pass criterion (D6) that names log lines a correct build need not print; a one-sentence
text fix. m1 must be applied before any device run (it is about the secure page). No mechanism change is asked for.

## 1. What was checked and holds

"Holds" = traced on source or found in the capture files by reading; nothing was executed.

**r4 fixes (§9 last table).** Every row was looked up in the v5 text and is there: B-M1 (variant has no button),
B-M2 (D5 in `round N cancelled` / `loginFor` lines), A-m1 (T18 removed), A-m2 / B-m4 (D1 reworded), A-m3 (D5
0.6–1.5 s), A-m4 (8 s sentence), A-m5 (T14c defensive), A-m7 (O2 for all `once` callers), B-m3 (rule above D1),
B-m5 / B-m6 (D4 dropped, D3 precondition), B-m8 (1.2 wording), cites of A-m6. Open points on three of them are m1,
m2 and m6 below.

**§1.3, the variant without a button.**
- `HomeAction.none` → `actionText` is null (`home_page.dart:321–331`, `_ => null`) → `extra` is null (`:346–360`) →
  the hero has exactly the kept lines of 「一切正常」 (`widgets.dart:104–107, 115–120, 140–155`). The steady-height
  claim is true for a name whose `next` fits two lines. (Line count at 360 dp: inferred from the 296 dp inner width;
  the font metrics were not opened.)
- `heroTime(about: h.node)` with `node == null` (`home_page.dart:319`) behaves as rule 14 today.
- H7 can pass as written, and its mutation fails: with `HomeAction.seeNode` a `BatButton` is drawn in `extra` even
  when `node` is null (`_act` guards only the tap, `:219–220`), so the y of 「我的節點」 moves.
- The user is still told where to tap: the `next` line 「…點節點看。」, the row's 「有一則提醒」 and the row's chevron
  (`widgets.dart:162–205`; `onTap` at `home_page.dart:412–416`). The row hint does not depend on which hero rule
  wins, so it also shows under rules 8 / 10 / 12 when the node itself is fresh.
- Readers of `warning`, Dart (`app/lib`, generated code excluded): `home_logic.dart:155, 158`; `node_page.dart:213`;
  `more_pages.dart:192, 211`; `member_ui.dart:186`. All are in the §1.3 table; none is missing.
- Readers of `warning`, Rust (`app/rust`): `batman-proto/src/statuspage.rs:118, 314–336, 358`;
  `bridge/src/api/owner.rs:461, 2579, 2792`; tests `batman-proto/tests/statuspage.rs:185, 258, 294, 390`; generated
  `frb_generated.rs`. All covered by the table and R1. The design's path `rust/bridge/src/api/owner.rs` is
  `app/rust/bridge/…` (cite nit only).
- Joined-critical is `code == None && plinks >= 1 && k2 == 2` (`statuspage.rs:332`); its colour is green only for
  `Row::Linked` (snr ≥ 20), yellow for `Row::LinkedWeak` (`:247–250, 271–277`). With the note moved out, a weak
  joined-critical node goes to rule 12 with its *sentence* (`home_logic.dart:158`), which is right. See m5 for what
  this means for D3.

**§1.2 against `settings_pages.dart`.** Cites 25–37, 41, 126, 133, 148, 153–156, 163, 178, 182, 190, 255, 289–303,
307–314, 324–326, 340, 346, 370 all say what the design says. 「手機 Wi-Fi」 is inside `SecureScreen` (`:182`),
「國家」 is not. Two wording limits: m7.

**§0 against the captures.** Row 1 (`a2-step1`): 736 ms at 12:21:13.530, 1696 ms at 12:23:00.864, 2201 ms at
12:23:37.418, each after a `round N full […7d2c]` line and with a second `connect()`; 11 `result=body after` lines,
2907–4802 ms; the three 02-in-flight taps at 12:21:48, 12:22:24, 12:24:14. Row 2 (`a2-repro`): 3.5 s, 6.1 s, 25.7 s,
4.0 s; the quoted 02 line at 11:47:27.135; first connect to 04 at 11:47:40.775; cancelled attempts 524 / 465 /
104 ms; `kept link` count 0 in both files. "0.1 s" is in the PR #366 body (test results, D3 line). Open: m4, m8.

**Log lines the device criteria use.** `round N full/cancelled/end` (`core.dart:421, 427, 723`), `kept … -> body`
(`core.dart:623`), `attempt …×… connected= result= after` (`node_link.dart:1028`), `loginFor … -> ok (kept link)`
(`node_link.dart:451`), `loginFor … result=` (`:592`) exist. D2, D3, D5, D7 are evaluable from them (with m2–m5);
D5 and D6 say honestly that they have no failing state on main and rest on unit negative controls plus a main
baseline.

**Mechanism (1.1), ownership, contracts, lifecycle matrix, security.** v5 does not change 1.1; r4-A and r4-B traced
it and I did not re-trace the interleavings this round (only `acquire`, `_loginFor`, `_lend`, `_giveBack`,
`background` were re-read, `node_link.dart:303–510, 739–763`, `core.dart:267–290`). No new missing lifecycle path or
second writer found. Security: no new radio input; the memo holds no passphrase and never fills a field.

## 2. MAJOR

### M1 — D6's pass criterion names lines a correct build need not print

Scenario: D6 = 「手機 Wi-Fi」 mid-connect → background 8 s → back. Pass is "within 40 s of the return a round for 04
ends (`result=body` or a failure line) and the page's `loginFor` has ended". `result=body` exists only on an
*attempt* line (`node_link.dart:1028`), not on a round. One correct course: the login is still running when the app
returns (it has 60 s, `node_link.dart:408`), logs in, the page reads and closes its session in the foreground, the
link is parked again (`_giveBack`, `node_link.dart:754–759`: `reusable && core.blocked == null && core.fg`), and the
next round reads over the parked link. That round prints `kept …7d2c -> body` and `round N end {…7d2c: read}` and
no `attempt … result=body` line at all. A correct build then cannot show the named line; and "a failure line" is
not defined, so a tester can pass or fail the same log. Same class as r4 B-M2.

Evidence: `node_link.dart:1028` (the only source of `result=body`), `core.dart:623, 723`, `node_link.dart:754–759`;
`core.dart:279–283` (a round starts on the return only when eligible, i.e. not under the page's lease).
The course above is traced on source, not seen on a device.

Smallest fix (text): "Pass: after the return there is a `loginFor …7d2c` end line (`-> ok (kept link)`,
`result=…` or `-> <end>`) and, within 40 s of the return, a `round N end {…7d2c: …}` line (any conclusion); no
`round` or `attempt` line for 04 is left without its end line at the end of the capture; Back then shows the node
page." State that the 40 s count from the `lifecycle resumed` line.

## 3. MINOR

### m1 — the scripts D1 / D2 name do not obey the rule above D1 (apply before any device run)

The rule says: no dump when the `secure` check says secure *or the screencap fails*; no dump of 「手機 Wi-Fi」.
`a2step1.sh` and `a2repro2.sh`, named by D1 / D2 without "changed", both do
`log "…: $(secure && echo secure-page || descs)"` with
`secure(){ … n=$(stat -c %s …); …; [ "$n" -lt 30000 ]; }`. A failed screencap or `stat` gives an empty `n`, the test
errors, the `||` branch runs `descs` (a `uiautomator dump`). `a2repro2.sh` evaluates this while 「手機 Wi-Fi」 is on
screen ("after 16 s"). `/sdcard/ui.xml` is never deleted on the phone.
What could leak today is limited (read on source, not tested): `descs` prints content-desc only, 160 characters;
the node never sends the passphrase (`owner.dart:573–574`), the script types none. So this is the AP name at most —
but the rule is the user's hard constraint and the text now claims a guard the scripts do not have.
Fix (text, one sentence under the rule): "both scripts are changed before use: `secure` answers secure on any error
or non-numeric size; after a 「手機 Wi-Fi」 tap no `secure`/`descs` call is made at all (D2 is judged from logcat);
`ui.xml` is deleted on the phone after each dump; the changed scripts are attached to the PR."

### m2 — D1 wording

"no second `connect()` followed by an `attempt …7d2c` line" is hard to apply: the first `connect()` can be before
or after the tap, and `connect()` lines cannot be tied to a node (as the rule itself says). Clearer and
discriminating: "between the tap and `round N end {…7d2c: read}` there is exactly one `attempt …×…7d2c` line, it
is `result=body`, and its `after` ms is longer than the time from the tap to that line; the page's round prints
`kept …7d2c -> body`". On main the same window has a `noResponse` attempt line plus a second one, and the round
prints `…×…7d2c -> body` (not `kept`), so the control still flips.

### m3 — D7 cannot be done with the scripts' `descs`, and one way to a false "not shown"

`descs` keeps 4 content-descs and 160 characters; 「<國家>（確認中…）」 on the country page will not be in it. D7
needs its own untruncated dump of 「國家」 (allowed: not a secure page), still after the `secure` check. The check
plus the dump take 1–3 s, so "while the read runs" will often be missed; the design already allows "not shown"
after 3 tries, keep that. Add: a try in which the app process was restarted during the 8 s in the background (no
`lifecycle resumed`, a fresh start in the log) is not counted, since the memo is memory-only.

### m4 — taps by coordinate are not confirmed; §0 row 2 omits the fifth iteration

`a2repro2.sh` runs five iterations (delays 0.3, 1.5, 2.5, 3.5, 4.5 s); §0 says "4 taps". In the fifth
(11:48:44–50) the attempt to 04 ended with a body at 11:48:49.039 before the 04 tap at 11:48:49.696, round 38 read
over the kept link, and there is **no** `loginFor` line at all although a parked link existed — so the 「手機 Wi-Fi」
tap seems to have missed (inferred from the absence of the line; not otherwise verifiable from the file).
Fix: §0 names the fifth iteration as "tap not registered, not counted"; D2 / D5 / D6 count a try only when the log
shows the page was reached (a `loginFor …7d2c` line after the tap), and the PR's tap list marks the rest "missed".

### m5 — D3 precondition is one condition short

The variant is drawn only when rule 14 is reached: every node fresh and green, no todo. A joined-critical 02 with
snr < 20 or unknown is `LinkedWeak` = yellow (`statuspage.rs:247–250, 275`) and home is then rule 12 with the weak
sentence, correctly. D3's "if 02 is not in that state or not fresh → not run" should add "or any row on home is not
green / a todo is listed", otherwise a correct build fails D3. Same for H1's fixture (`sv('green')` plus the note).

### m6 — H7 as it will be written in `home_steady_test.dart`

The test's premise is `find.textContaining(title)` inside the hero (`home_steady_test.dart:66`). 「可以使用」 is
also part of 「一切正常，可以使用」, so the variant's premise must be 「有一則提醒」 (or the exact title), else the
premise holds when the variant is not drawn. `sv()` (`layout_test.dart:47–63`) builds `StatusView` with
`warning: ''` and needs a `note` parameter. Also say in 1.3 that the steady claim is for the y of 「我的節點」 only:
the hint line makes that node's row taller when it appears, so rows *below* it move by one small line at the first
fresh read (unavoidable; just not claimed).

### m7 — §1.2, two sentences true only for the first read of a page

- "After a failed read the name field is empty, so 「送出」 is disabled" (also W5): true when the page's first read
  fails. After a successful read followed by a failed 「重新讀取」, or after the user typed, the field is not empty
  and `can` (`settings_pages.dart:178`) is as today. Say "when the page's first read fails".
- 「上次讀到：」 replaces the row's right side only while the page has no value of its own: on the Wi-Fi page `_now`
  survives a failed re-read (`:163`), on the country page `_cc` is cleared (`:300`). One clause each is enough.

### m8 — nits

- §0 row 1: "about 1–2.5 s were left" — by the row's own range (2.9–4.8 s) and the last two ages (1.7 / 2.2 s) it
  is about 0.7–3.1 s; it is marked inferred, fix the number or drop it.
- §1.3 table, bridge row: path is `app/rust/bridge/src/api/owner.rs`.
- D2 "logged in no later than 1 s after the attempt's end": name the two lines (`attempt …×…7d2c … result=body`
  and `loginFor …7d2c -> ok (kept link)`); both exist.

## 4. Negative controls

H1–H7, W1–W6, T1–T17, O1–O4, R1: each names a mutation or fails on main (H7's checked on source above; the others
as r4, text unchanged). Device: D1 / D2 / D3 / D7 have a captured or main-APK failing state; D5 / D6 state plainly
that they have none and rest on T15 / T15c / T7b — acceptable once M1 makes D6 decidable.

## 5. Not verified

- Nothing was run: no test, no build, no device. All "holds" are from reading.
- 1.1's interleavings were not re-traced this round (unchanged text; traced in r4 by both reviewers).
- Font metrics behind "one line at 1.0, two at 1.3" for the variant's `next` line; H7 decides it.
- `more_pages.dart:313`, `member_ui.dart:205`, `net_pages.dart:548`, `secure_screen.dart` were not opened this
  round (r4-A lists them as checked).
- Whether a `uiautomator dump` of the secure page would contain the name field's value (m1 is rated on what the
  script prints, not on a test).
- m4's "tap missed" and M1's course are inferences from the log / source, not observations.

## 6. Verdict

APPROVE-WITH-CHANGES. M1 open → per the rules the text is revised and looked at once more; m1 before any device
run; m2–m8 are text edits.
