# Review r4-B — `329-takeover.md` v4 (3ab7e4b), code = main 99d156a

Reviewer B, round 4. Whole document reviewed; emphasis on the user-visible side (§1.2, §1.3), the tests (§7) and the
evidence (§0, §5). Read-only: source, the two logcats, the two device scripts, PR #366 body. Nothing was run on a
phone or a node; no test was executed (all statements about tests are from reading source).

**Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER, 2 MAJOR, 10 MINOR.**
Both MAJORs are one-paragraph edits (a false layout statement with a test that cannot pass as written; a device
pass criterion that names log content that does not exist). The 1.1 mechanism was traced again from source and I
found no stuck state, leak or second writer.

## What was checked and held

- **§0 against the logcats.** `a2-step1-2026-11-20.logcat`: the three cancellations (12:21:13.530 / 736 ms,
  12:23:00.864 / 1696 ms, 12:23:37.418 / 2201 ms), each followed by `round N full […7d2c]` and a second
  `connect()`; body 4.5 / 4.0 / 4.8 s after the tap; 11 `result=body after` lines, 2907–4802 ms; the three taps
  with 02 in flight (12:21:48, 12:22:24, 12:24:14). `a2-repro-2026-11-20.logcat`: four Wi-Fi taps, 3.5 / 6.1 /
  25.7 / 4.0 s; `11:47:27.135 attempt …5A×…880c connected=1633ms result=noResponse after 2163ms`; first connect to
  04 at 11:47:40.775; no `kept link` line in either file (count 0). PR #366 body: "login on the kept link 0.1 s".
  All present. Slips only (m1).
- **§5 cites.** `node_link.dart` 303, 352, 360, 369, 446–452, 639, 644, 716–735, 900, 911, 928, 996, 999, 1008,
  1038, 1051, 1057, 1060–1069; `core.dart` 244–258, 285–290, 472–480, 603–626; `prober.dart` 129–132, 233;
  `ble_gate.dart` 195, 302–309; `update_route.dart` 28–36; every `setPage` caller (grep equals the list); every
  `OpSession.once` / `acquire` caller (grep equals the list); `OpDeps(` has one maker in `lib`; `owner.dart`
  573–574, 616, 630; `statuspage.rs` 333; `tests/statuspage.rs` 305–307, 390; `owner.rs` 461, 2579, 2792; the doc
  lines of 254 / 329-app-uiux / 329-honest-errors. All say what the design says, except the slips in m2.
- **Every reader of `warning`.** Dart (`grep "\.warning|warning:" lib`, generated code aside): `home_logic.dart`
  155, 158; `node_page.dart` 213; `more_pages.dart` 192, 211; `member_ui.dart` 186. Rust: `statuspage.rs` 118,
  358; `owner.rs` 461, 2579, 2792. The table in §1.3 has all of them. `nodeRowWords` and the stored look
  (`_remember`) do not read it. Nothing else in the repository holds the sentence.
- **1.1 mechanism.** Traced `setPage` → `_pump:900` → `_run` tail → `acquire` for: detach then leave / background /
  blocked; waiter woken by end, abort, dispose, timer; a non-`forNode` lease arriving during a wait (it aborts the
  attempt, the waiter wakes, finds `reg.current` set, returns null → busy with a real name); late end of an aborted
  attempt (identity checks). The UI reads no `core.running`, so a detached attempt shows on the node page exactly as
  an attempt of the round does.
- **Security.** Nearby replay device: bounded delay only, nothing parked or recorded without the authenticated
  login. Compromised node: its own `SettingsView` on its own two pages, as a label. Second phone: old name shown
  marked, never put in the field. Own mistakes: see M1, M2, m3.

## MAJOR

### M1 — §1.3 says the steady hero "already keeps the button's place"; it does not, and H7's steady assertion cannot pass as written

Scenario: 02 is joined-critical (the phone's state today, D3). Every launch home goes 「正在找…」 → the variant
「可以使用」. The variant has `HomeAction.seeNode` / `showList`, which is drawn as a `BatButton` in the hero's
`extra`. The node list jumps down by that button's height at the change — the jump C4 (#367) removed for
「正在找」 / 「還沒讀到」 / 「一切正常」.

Evidence:
- `home_page.dart:321–331`: `HomeAction.refresh` maps to `_ => null`, so rule 10 「還沒讀到」
  (`home_logic.dart:152`, `action: HomeAction.refresh`) draws **no** `extra` button. The design's "rule 10
  「還沒讀到」 has one" is false: its button is the 「重新整理」 button of the time row.
- `widgets.dart:105–107` (doc of `steady`): "Longer texts, [extra] and the tech fold still add height."
  `widgets.dart:146` `...?extra` is outside the kept lines; the kept 48 dp (`:149`) is for the refresh button only.
- `home_steady_test.dart:22–26`: the three steady states have no `extra`; that is why their y is equal.
- So H7's "in `home_steady_test` the variant's 「我的節點」 is at the y of 「還沒讀到」" is expected to fail by one
  `BatButton` plus the 10 dp gap (inferred from source, not run). At scale 1.3 it is also off the other way by
  the 42 dp of the three-line 「還沒讀到」 title (`home_steady_test.dart:76–78`).

Not a regression against main (rule 12 today has the same button and a taller title, `329-honest-errors.md:156–158`),
but the design states the opposite of the source as evidence and pins it with a test.

Fix (pick one, smallest first):
1. The variant has no button: `HomeAction.none`, `next` 「<名稱> 有一則提醒，點節點看。」 (the same wording as the
   several-nodes line). The row under it carries 「有一則提醒」 and is the tap target. Then the variant has exactly
   the lines of 「一切正常」, the steady claim is true, and H7 asserts y equal to 「一切正常」 at 1.0 and 1.3 with a
   short name. Mutation for H7: give the variant an action → FAIL.
2. Keep the button; delete the sentence about the kept place; say the variant is one button taller than
   「一切正常」 (as rule 12 is today); H7 asserts only "no overflow" plus the measured difference.

### M2 — D5's log criterion names a log line that does not exist

Scenario: the person running D5 must decide "the log has one lease for 「國家」 and none for 「手機 Wi-Fi」". No
log line carries a lease or an operation name, and the design adds none, so the criterion cannot be evaluated; the
result would be improvised or overclaimed.

Evidence: all `BMAPP` line kinds in `a2-repro-2026-11-20.logcat` (grouped): `round N cancelled`, `round N full`,
`round N end`, `kept … -> body`, `attempt … result=`, `loginFor …7d2c`, `loginFor …×… result=`, `gate link … down`,
`adv resolver`, lifecycle. A lease shows only as `round N cancelled` without a name (`core.dart:285–290` →
`_cancel` → `:427`); `op_session.dart:126, 186` print a name only on a failure.

Fix: state it in the lines that exist. Between the 「手機 Wi-Fi」 tap and 「國家」 showing its value: exactly one
`round N cancelled` (a gone waiter does not cancel the round — T15c — so two means the closed page took the lease),
exactly one `loginFor …7d2c` block, and it ends `ok (kept link)` when the attempt ended with a body. Baseline on
main reported with the same three counts. No new log line is needed.

## MINOR

- **m1 (§0 wording).** The step-1 capture spans 12:21:00–12:24:42, not "12:22–12:25". "12 s later" is 12.6 s after
  the Wi-Fi tap (13.6 s after the cancelled-attempt line). In the three counted row-2 cases the cancelled attempt
  was only 524 / 465 / 104 ms old (`a2-repro`, e.g. `attempt …9E×…7d2c connected=-1ms result=noResponse after
  524ms` at 11:46:09), so by §0's own 2.9–4.8 s the expected sub-page step after the change is about 2.4–4.7 s +
  0.1 s against 3.5–6.1 s today. The "Cost" paragraph does not overclaim, but say this range so D2 is read against it.
- **m2 (cites).** `op_session.dart:68` → the `acquire` field is `:69`; `core.dart:218` → `_pageTargets` is `:216`;
  `settings_pages.dart:26` → `opDeps` starts `:25`; `core.dart:475` (1.1) vs `472–480` (§5) → the condition is `:474`.
- **m3 (device scripts and the secure page).** The dump guard in both scripts is `secure && echo secure-page ||
  descs` (`a2step1.sh:9, 21`): a screencap smaller than 30 000 bytes means "secure", anything else is dumped —
  fail-open. `uiautomator dump` is not stopped by `FLAG_SECURE`. D5 (Back → 「國家」 within 1 s → dump) and D7
  (「國家」 "at once" → dump) dump right after a blind coordinate tap next to the 「手機 Wi-Fi」 entry, on a page
  whose status area still changes height while connecting (§8) — a tap that lands on, or a Back that leaves the
  phone on, 「手機 Wi-Fi」 would be dumped. Fix, one sentence in §7: every dump in D5 / D7 is preceded by the
  `secure` check and is skipped when it says secure **or** when the screencap fails; a skipped dump is "not shown",
  never a pass. (The screencap of the secure page itself is black and deleted at once; say so, since the limit
  reads "never screenshotted".)
- **m4 (D1).** "the next round logs `kept …7d2c`" is already true on main (rounds 47, 50, 53, 56, 59, 62 of the
  step-1 capture log `kept …7d2c -> body green` after the return to home): it separates nothing. Replace by what
  the change produces: inside the page's own round, a `kept …7d2c -> body` line and `round N end {…7d2c: read}`
  with no `connect()` between the tap and it. Also say how a `connect()` line is tied to 04: the device name in it
  is masked and rotates (`45CC96_B`); use the `attempt …×…7d2c` line that follows.
- **m5 (D4).** No pass criterion and no negative control. Either drop it (D2 measures the same step) or state:
  second opening logs `loginFor …7d2c -> ok (kept link)` and no `connect()`; control = §0 row 2.
- **m6 (D3 precondition).** "02 joined-critical (it is now)" is a state of a live node. Read it first (02's row on
  home / node page text); if 02 is not in that state or not fresh, D3 is "not run", not a pass. The hint needs a
  fresh read, so the screenshot is taken after 02's read time shows.
- **m7 (§7 mutations).** The header promises a mutation for tests that pass on main. T7, T8, T9, T10, T11, T13 pin
  "aborted / destroyed" and name none; one covers T7–T10: line 900 with `identical(_det, a)` alone (no
  `wanted(a)`). T13: park without the "no kept link / room" test. W5 (field empty): mutation = prefill the field
  from the memo. H3 / H6 are plain regression pins; say so.
- **m8 (§1.2 wording).** (a) Where 「上次讀到：<名稱>」 is printed is not stated: today the row's right side is
  `_reading ? '讀取中…' : (cur == null ? '讀不到' : cur.apSsid)`; say whether it replaces 「讀不到」 there or follows
  the failure line. (b) The country label must go through the same `_countryName` / `countryShown` as the read
  value (a raw code would be a second way to print it). (c) W5 "sending is disabled" holds only because the name
  field is empty (`can` needs a valid name; a failed read does not disable sending by itself): word the assertion
  as "the field is empty, so 送出 is disabled".
- **m9 (§4 row).** `net_pages.dart:224` (`dispose` → `setPage(widget.back, node: widget.backNode)`) is a second way
  into the node's page; with a home-round attempt to that node past its connect start it detaches exactly as a
  tap does. §5 lists the caller; add the matrix row "back from a net page to the node page" → T1's behaviour (one
  more case in T1, no new mechanism).
- **m10 (§1.3, long name).** With a 32-character name the one-node `next` line is longer than the two kept lines
  at scale 1.3 / 2.0; H7 checks overflow only. Fine, but say the steady height holds for short names only, as C4
  already does for its title.

## Lifecycle / ownership

No missing resource found. Rows present for every path I could reach from the UI (tap from home, sub-page, Back
during the wait, second sub-page, background, radio off, dispose, cap / refresh, record gone, late end of an
aborted attempt). One row to add (m9). Install / upgrade / downgrade / iOS rows are correctly "n/a" (memory only,
no wire or stored format; `StatusView` is not persisted — `_remember` stores the look).

## Not verified

- No test or build was run; "H7 would fail" (M1) and the T / W negative controls are from reading source.
- D1–D7 were judged on paper against the two existing scripts; the scripts for D5–D7 do not exist yet.
- `254-p3-impl §3.3` (passphrase never sent) was not opened; `owner.dart:573–574` was.
