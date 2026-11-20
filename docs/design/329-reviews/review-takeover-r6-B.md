# Review r6-B: `329-takeover.md` v6 (0b594d0)

Reviewer B, round 6, independent. Whole document reviewed against main 99d156a (`app/`), the two captures and the
screenshot in `Desktop\Batman\a1\`, and the two device scripts as they are today (not yet changed). Read-only: no
device, node, adb, flutter, cargo or state-changing git command was used; nothing was run. Baseline documents, the
existing behaviour of main and the three scope items were not re-reviewed.

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 0 MAJOR, 6 MINOR.**
All six are test-wording, criterion-wording or evidence fixes. None changes the mechanism of 1.1–1.3, and none asks
for a new mechanism. No further whole-document round is required by the rules.

## 1. What was checked and holds

Method: the design in full; r5-A and r5-B in full; then every file named in this round's emphasis, opened at the
cited lines and around them. 1.1 is unchanged since v5 and was traced by both r4 and r5 reviewers; this round I
checked only its v6 text edits (A-m1, A-m3, A-m4, A-m5 of r5) against the r5 findings, not the interleavings again.

### 1.2 against `settings_pages.dart`

Every cite is correct: `opDeps` `:25–37` (`busyName` `:27`), `opLine` busy `:41`, Wi-Fi read `:126`, field filled
only when empty `:133`, send `:148`, `notSent` `:153–155`, `c.setAp` `:156`, `_now` kept only on `v.read` `:163`,
`can` `:178`, `SecureScreen` `:182`, right side `:190`, `_countryName` `:255`, country read `:289–303` (`_cc`
cleared on a failed read `:300`), `_blocked` `:307–314`, dialog text `:326`, country set `:340`, row right `:370`.
`CountryPage` is not inside `SecureScreen`; `WifiPage` is. `SettingsView` has no passphrase field
(`owner.dart:571–575`). `OpDeps` (`op_session.dart:59–82`) is not `const`-constructed anywhere (7 makers, grep), so
a per-instance default memo is possible; the requests callback runs only after the lease, the login and the `gone`
checks (`op_session.dart:92–121`), so "`drop` inside the callback, after `notSent`, before the request" gives
exactly the four W4 outcomes. Neither page shows a spinner widget while reading (grep), so a `uiautomator dump`
during the read is not blocked by an animation (D7).

The statements "never prefilled", "`_cc` only from the page's read", "a failed re-read on Wi-Fi keeps the page's
own name, on 「國家」 it clears it" each match the code they sit on.

### 1.3: readers of `warning`

Dart readers under `lib/` outside generated code (grep `.warning`): `home_logic.dart:155, 158`, `node_page.dart:213`,
`more_pages.dart:192, 211`, `member_ui.dart:186` — all in the table. `nodeRowWords` and its three callers
(`home_page.dart:414`, `node_page.dart:208`, `net_pages.dart:548`) do not read `warning`. Rust: `Verdict.warning`
`statuspage.rs:118`, filled `:358`, the branch `:332–334`; pinned by `tests/statuspage.rs:303–305` (the `neutral`
lines) and `:390`; bridge `owner.rs:461, 2579`, tuple assertion `:2792`. The sentence text occurs only in
`statuspage.rs`, its test, `254-app-status-page.md:28, 73` and `329-honest-errors.md:14, 34` (grep). No reader is
missing. `StatusView(` is constructed in 16 test files (20 places) — "every `StatusView(` in the Dart tests gets
`note`" is the right scope.

Home: rule 12 `home_logic.dart:155–160`, rule 13 `:161–170`, rule 14 `:171–172`. With `warning` empty and the row
green (`row_of` gives Linked for joined without a code, `statuspage.rs:244–269`), a joined-critical node falls
through to rule 14, so the variant is reachable exactly as H1 says (fresh, green, no todo). The hero button is
drawn in `extra` only when `actionText != null` (`home_page.dart:321–331, 346–360`); `HomeAction.none` gives none.

### Tests: can each pass on a correct build and fail on main or under mutation

| Test | Passes when correct | Fails on main / under mutation | Result |
|---|---|---|---|
| W1 | rig exists (`settings_pages_test.dart`, `Fx`, `openWifi`) | main prints 「讀取中…」 (`:190`) | holds |
| W2 | yes | main prints 「讀不到」 (`:190`) | holds |
| W3 | yes | the "menu disabled" half cannot fail as worded | **m1** |
| W4 | yes | four sub-cases together pin where `drop` sits (before login → case 2 fails; before `notSent` → case 3; after the request → case 4; no `put` → case 1) | holds |
| W5 | yes | mutation named (prefill) | holds |
| W6 | yes | passes on main; no mutation named | **m2** |
| R1 | yes | main: `warning` is `Some` (`:333`) | holds |
| H1, H2 | yes | main: rule 12, yellow, `seeNode` | holds |
| H3, H6 | regression pins, marked | — | holds |
| H4 | yes | wording of the restart case | **m3** |
| H5 | yes | fails if a reader keeps `v.warning` | holds |
| H7 | `home_steady_test.dart` has the three states, premise by text in `StatusHero`, `sv()` at `layout_test.dart:47–63` | `seeNode` adds the button in `extra` → y differs | holds |

### Device criteria

- D3 is decidable: precondition (02 fresh, in that state, all rows green, no todo), five things to see on two
  screenshots. The failing state on main exists: I opened `a1-home-c1.png` (11:30): yellow hero 「注意」, 「02：節點
  回報異常，可能是手機 Wi-Fi 還沒設定 …」, button 「看這台節點」, both rows green 「已連上隊伍網路」.
- D7 is decidable: under 1.1 the label is on screen for the wait plus the login (seconds, not 0.1 s, because the
  page is opened while the node page's attempt is in flight); main shows 「讀取中…」 for that time (`:370`). The
  step list leaves a tap out: **m5**.
- D1, D2, D5, D6 were settled in round 5; I re-read the v6 wording against r5-B M1 / m1–m8 and r5-A m1–m6: each is
  applied as §9 says.

### Secure page: paths of the scripts as described after the change

Today's scripts are fail-open and `a2repro2.sh` evaluates the guard while 「手機 Wi-Fi」 is open (r5-B m1). Under
the v6 rule — any error is "secure"; a dump only right after "not secure"; no dump from a 「手機 Wi-Fi」 tap to the
Back that leaves it; `ui.xml` deleted — I walked every `descs` call that exists today: `home()` (after `secure` in
the loop), the line 16 s after the Wi-Fi tap in `a2repro2.sh` (forbidden by the "no dump at all" clause), the
final `home; log "end: $(descs)"` and the `STOP` branch (allowed only after a "not secure" answer, so they need
their own check: `home` returning 1 must not be followed by a bare `descs`). Taps are delivered in order, so a
late Wi-Fi tap cannot open the page after a later Back. `SecureScreen` builds its child only after Android
confirmed the flag (`secure_screen.dart:33–48`), so the name is never in the tree of a window that is not secure.
With the rule applied to every `descs` call no path dumps the page — provided the size check itself tells the two
kinds of page apart: **m4**.

### §2, §3, §4, §6 as a whole

No resource with two writers; no missing lifecycle path found (first run, start, background, restart, kill,
upgrade / downgrade, dependency restart = node reboot / Bluetooth off, platform). §6 covers each actor; the memo
holds no secret and enables nothing. One "Today" cell is not true for all the cases of its row: **m3**.

## 2. Findings

### m1 (MINOR, negative control) — W3 "menu disabled until the page's read" cannot fail

Scenario: the implementer sets `_cc` from the memo (the mistake W3 is there to catch: 1.2 says "`_cc` … is set
only by the page's own read, never from the memo"). While the page's read runs, the rows are disabled whatever
`_cc` is: `final no = _reading || _sending ? '' : _blocked();` (`settings_pages.dart:359`) and `enabled: no ==
null` (`:378`). So W3 as worded passes with the mistake in. The mistake shows only after a **failed** read: `_cc`
would stay set (or the radio icon `e.key == cur`, `:376`, would be checked), `_blocked()` (`:307–314`) would
return null for a node that is not in a network, and the user could pick a country on a value the page never read.

Fix (test text only): W3 adds "memo present, the page's read fails, node not in a network: every country row is
disabled, `country-why` is 「先讀到目前的國家。」, no radio is checked, the row shows 「上次讀到：<國家>」 [mutation:
`_cc` set from the memo]".

### m2 (MINOR, §7's own rule) — W6 passes on main and names no mutation

§7 says a test that passes on main names the mutation that makes it fail. W6 ("no memo, or an empty value in it:
「讀取中…」 as today") passes on main. Its second half does discriminate (a label printed for an empty value would
show 「（確認中…）」 alone), the first half is a regression pin.

Fix: "W6 … [mutation: label printed without the non-empty test; the no-memo half is a regression pin]".

### m3 (MINOR, false statements about today) — the restart case and §4's last row

- 1.3 (row "Home node row") and H4 speak of "a stored view after an app restart (not fresh)". No view is stored:
  `nodeInfo` takes the view from the core's state of this run (`home_page.dart:43`, `view: s.extra is StatusView ?
  … : null`); what survives a restart is `prev` (look and time). After a restart the node has **no** view until it
  is read. `nodeRowHint` therefore meets `view == null`, which the text does not name; a helper written as
  `n.view!.note` after a `fresh` test would still be safe, one written the other way round would throw on home at
  every launch.
- §4, row "Home: note on one node / several / stale node / after an app restart / with a power warning": the
  "Today" cell says "yellow rule 12". Rule 12 reads fresh nodes only (`home_logic.dart:155`, `fresh.where`); a
  stale node or a node after a restart is rule 10 (「還沒讀到…的狀態」, `:150–152`) today and after.

Fix (text): "after an app restart the node has no view until it is read: no hint (`view == null`)"; H4 "a stale
node and a node without a view → empty"; the §4 cell: "fresh: yellow rule 12; stale / after a restart: rule 10,
unchanged".

### m4 (MINOR, evidence for an assumption the secure rule rests on) — the screencap size test

Scenario: D5 / D6 end with "a tap on Back … (dump after the `secure` check)". If that Back does not leave 「手機
Wi-Fi」 (the tap arrives while the app is still returning from the background in D6, or misses), the page's name
is kept out of the dump by the `secure` check alone. `secure` is "screencap file smaller than 30000 bytes". That
a screencap of this page on this S20 is under 30000 bytes, and that it is so with the status and navigation bars
drawn, is nowhere evidenced: §5 has no row for it, neither capture can show it, and no script output is kept
(searched the scratchpad for the script's `secure-page` word: only the scripts themselves). The other direction
is evidenced (a normal page is far above: `a1-home-c1.png` is 256 KB). The changed rule makes errors fail closed,
but a number above the threshold is not an error.

Fix (no new mechanism, one evidence line and one run step): §5 gets the row; the first device run prints the
screencap **size only** with 「手機 Wi-Fi」 open and with the node page open (the file is deleted on the phone, as
the rule already says) and the PR quotes both numbers. If the secure page's size is not clearly under the
threshold, the runs make no dump after a 「手機 Wi-Fi」 tap until the app has been brought to home by a path that
does not depend on the check (D5 / D6's last step is then judged from the log, or reported "not shown").

### m5 (MINOR, device steps) — D5 and D7 leave out 「更多」

「國家」 is not on the node page. Its only entry is the 「更多」 page (`more_pages.dart:136`); `CountryPage(` has no
other caller (grep; 「手機 Wi-Fi」 is on the node page, `node_page.dart:247`). So "04's card, 「國家」 at once" (D7)
and "「手機 Wi-Fi」 → Back → 「國家」 0.6–1.5 s after Back" (D5) are each two taps with a route transition between
them. For D5 this decides what is counted: the counted condition is "the attempt to 04 is still in flight at the
「國家」 tap", and with an attempt of 2.9–4.8 s, a 0.7 s gap before the Wi-Fi tap, Back, 0.6–1.5 s, 「更多」, its
transition, then 「國家」, few tries will qualify — "at least 2, else repeat" covers it, but the script and the
PR's tap list need the real sequence. The mechanism is not affected (`MorePage` calls neither `setPage` nor
`once` on entry).

Fix (text): D5 "… → Back → 「更多」 → 「國家」; the 0.6–1.5 s is from Back to the 「更多」 tap"; D7 "04's card, 「更多」,
「國家」, each as soon as the page before it is up".

### m6 (MINOR, wording) — "the other lists that use `NodeRow`"

1.3: "`NodeRow` gets an optional `hint` (default empty: the other lists that use `NodeRow` are unchanged)". Home
is the only user (`home_page.dart:415`; grep `NodeRow(` over `lib/` and `test/` gives that line and the
definition, `widgets.dart:163`). Harmless, but it reads as if other screens had been checked for the taller row.

Fix: "(home is its only user)".

## 3. Negative controls

- 1.1 tests T1–T17, O1–O4: unchanged since v5 except T4b, T14, T14b, T14c, O3 (r5 text fixes); the mutations
  named still change the asserted condition. Not re-traced line by line this round.
- W, R, H: table in §1 above; open points m1, m2.
- Device: D1, D2, D3, D7 have a captured or stated failing state on main (D3's screenshot opened); D5, D6 are new
  code with unit controls and a main baseline, stated as such.

## 4. Verified / inferred / not verified

- Verified by reading source, the screenshot or the scripts myself: all of §1 "1.2", "1.3 readers", the test
  table's "fails on main" column, D3's negative control, the script paths as they are today, and the evidence
  lines of m1, m2, m3, m5, m6.
- Inferred (code or scripts that do not exist yet; nothing run): that W1–W6, H1–H7 pass on a correct build; that
  the variant's `next` line fits the two kept lines for a short name at scale 1.0 / 1.3 (H7 will show it); that
  the changed scripts, written as the rule says, leave no dump path; how many D5 tries qualify (m5).
- Not verified: the screencap size of the secure page on the S20 (m4); the `nl`-clock and "0.1 s" points left
  open in the design itself; the cited lines of `329-app-uiux.md` and of `254-app-status-page.md:60` (not opened;
  `:28`, `:73` and `329-honest-errors.md:14, 31–34` were); the 1.1 interleavings (taken from r4 / r5, not traced
  again); no test, build or device run of any kind.

## 5. Only necessary changes

v6 adds no mechanism over v5. This review asks for none: m1–m3, m5, m6 are text, m4 is one evidence row and one
printed number in a run that is already planned.

## 6. Verdict

APPROVE-WITH-CHANGES. m1 and m3 before the widget tests and `nodeRowHint` are written; m4 and m5 before the device
scripts are changed, since they decide what the scripts do and what a counted try is.
