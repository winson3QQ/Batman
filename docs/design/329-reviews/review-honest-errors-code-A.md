# #329 honest-errors — code review A (adversarial)

Reviewed: the uncommitted diff of `app/` in `C:\src\Batman-msg` (branch feat/329-honest-errors, base 5999dae), against
design `docs/design/329-honest-errors.md` v3.1 (baseline; design decisions not re-reviewed).
Date: 2026-11-20. Reviewer A. No file under `app/` was changed; no mutation was run by me.

## What I did

- Read the whole diff (copy `a1-code.diff`, 926 lines) and the changed sources around it.
- Listed every caller: `loginLine` (net_run.dart:245, :414; settings_pages.dart:42), `LoginForResult(`
  (node_link.dart:414-512 only), `OpReply(` (op_session.dart only; `RekeySent.notReached` passes the object on,
  rekey_send.dart:127/:146), every `StatusHero(` (30 users; only home_page.dart:346 sets `steady`), every place that
  holds the old texts (lib, tests, docs).
- Ran, on the tree as it was at 11:14–11:20:
  - `test/ui/home_steady_test.dart` + `test/nodelink/login_found_test.dart` → `+13: All tests passed!`
  - `test/ui/pr6_dev_test.dart` + `test/swupdate_test.dart` → `+55: All tests passed!`
- Not run by me: the whole suite, the Rust tests (`cargo test`), any mutation, anything on a device.

## What holds (checked against source)

- **C1.** One constant (`statuspage.rs:125`), one user (`:333`), literal test (`tests/statuspage.rs:305`), the two
  lines of `254-app-status-page.md` (:28, :73). No Dart code compares this text (`home_logic.dart:155-159` only
  prints it). No other copy of the old text is left outside review files.
- **C2, core.** `near` changes only in `LoginFor.result` (core.dart:887-924), exactly as the design lists. The
  driver contract for `refusedOther` / `broken` is real: prober.dart:28-29 and :125 give them only when `loggedIn`.
  A result that arrives after the 60 s cut is dropped (`running = null` in `tick`, then `identical(running, a)` is
  false, core.dart:876, :928), so nothing is added after the end.
- **C2, wording only.** `found` is read in exactly five places, all pass-through or wording: net_run.dart:55, :245,
  :414; op_session.dart:110, :175; settings_pages.dart:42; node_link.dart:512. No branch, no memo, no retry, no
  state depends on it. `loginLine` reads it only under `LoginForEnd.notFound` (pattern guard, net_run.dart:55).
  No log line carries it; nothing secret is added to a log.
- **C2, no text matching broken.** Nothing in `lib` compares the old `notFound` sentence (`grep 沒有找到` → only
  net_run.dart:56 and an unrelated line join_pages.dart:765). `runWaitFor` / `needsNewInvite` do not key on it.
- **C3.** `T_REVERTED` contains 「退回」 and not 「回到原本的版本」; `T_REVERTED_18` the reverse (swupd.rs:77-78), so the
  two branches of `swNext` (swupdate.dart:100-105) cannot cross today. `swHero` is unchanged (:83).
- **C4.** `steady` defaults to false and `two()` returns the same widget when it is false (widgets.dart:115-120), so
  the 29 other users are untouched. The placeholder is excluded from semantics and follows the text scaler.
- **C5.** The lines shown and the lines sent are the same list object: `_send(lines)` → `prints` from `lines`
  (dev_pages.dart:154) → `c.sshKeys(lines)` (:182). The text field cannot change under a modal dialog. A barrier
  tap or back gives `null` → `yes != true` → nothing sent (:177). Fingerprints are public; nothing is logged.
- **Tests are real.** They drive the interface and assert the result (row line, reply field, widget text, `asked(f)`
  list, y position); each new "found" test has a "not found" twin; premises are asserted (`handshakes`, probes,
  hero title of the state). I found no presence-only check.

## Findings

### MAJOR-1 — the tree changed after the diff copy, the mutation log and (probably) the start of the full suite

- Scenario: the PR reports "16 mutations caught" and "whole suite green" for code that is not the code in the PR.
- Evidence: `lib/ui/widgets.dart` mtime 11:12:51; `a1-code.diff` 11:11:40; `mutA1.log` 11:10:14. `git diff -- app`
  now differs from the copy in the `StatusHero` hunk: `two(double size, double height, Widget? w)` became
  `two(TextStyle st, Widget? w)` with `heroSt` / `nextSt` (the placeholder now also carries `FontWeight.w700`).
  The file was edited while the full suite was running in the same tree.
- Assessment of the new code: equivalent or better (one style object, no second copy to drift). With an explicit
  `height` the line box does not depend on the weight. `home_steady_test` passes on the new file (my run, above).
- Fix: after the last edit, run again and report from that state: M12 (and at least M13/M13b are unaffected), the
  whole suite (or at minimum every test that pumps `HomePage`: `layout_test`, `retest_p_layout_test`, `pages_test`,
  `key_abilities_test`, `retest_s_boards_test`, `home_steady_test`). State in the PR which commit the numbers are
  for. Do not edit `lib/` again while a run that will be reported is in progress.

### MINOR-2 — missing negative control: a hint for ANOTHER node must not count

- Scenario: the user owns two nodes. Y1 is off; Y2 is near and its address (no 「是」 memo yet, hint 「像 Y2」) is
  tried by the login for Y1 as an unknown address (`open` list, core.dart:860-864) and stays silent. The line for Y1
  must stay 「沒有找到」.
- Evidence: the code is right (`like[a.addr] == id`, core.dart:917). But every test that has a hint uses the login's
  own id; (d) has no hint at all. The mutation below survives all 11 tests of `login_found_test.dart` by reading.
- Mutation to run: core.dart:917 `like[a.addr] == id` → `like[a.addr] != null`.
- Fix: one test in `login_found_test.dart`: `NodeLinkCore([Rec('Y1',1), Rec('Y2',1)])`, scan `{'a1': 'Y2'}`, every
  answer `noResponse` → `(notFound, found: false)`, with the premise `handshakes > 0`.

### MINOR-3 — missing negative control: `found` only with `notFound` at the NodeLink boundary

- Scenario: one address answers "busy" (in `near`), then another address ends the login with `identity` (or
  Bluetooth goes off: `precondition`). The contract (node_link.dart:86-87, "Only with `notFound`") says
  `LoginForResult.found` is false.
- Evidence: node_link.dart:512 `l.end == LoginEnd.notFound && l.found`. No test has a non-empty `near` together
  with another ending at this level (`login_found_test` "certificate is refused" empties `near` by the same
  address; (h) guards `loginLine`, not the result).
- Mutation to run: node_link.dart:512 → `l.found);`. Expected today: not caught.
- Fix: in `login_for_test.dart`, `Rig({'a1': 'busy', 'a2': 'cert'})` → `(identity, found: false)`. Harm today is
  nil (the line is guarded twice), so this is a guard for the next reader of `found`.

### MINOR-4 — C5: no test that leaving the dialog without an answer sends nothing

- Scenario: the user taps outside the dialog or presses back.
- Evidence: dev_pages.dart:177 `if (yes != true || !mounted) return;` is right. The tests only tap 取消 (pops
  `false`). Mutation `yes != true` → `yes == false` survives: `null` would send the keys.
- Fix: in the "取消 sends nothing" test (or a new one) dismiss with `await t.tapAt(const Offset(5, 5))` (or
  `t.pageBack` equivalent), then `expect(asked(f), isEmpty)` and `f.logins == 0`.

### MINOR-5 — C3 depends on two substrings of Rust texts that no test pins as literals

- Scenario: someone rewords `T_REVERTED_18` to 「…已退回原本的版本」 (or `T_REVERTED` loses 「退回」). The reason-18
  screen then shows the mesh advice (or the reverted screen shows no advice / the plain one). Everything stays green.
- Evidence: `swNext` matches `contains('退回')` then `contains('回到原本的版本')` (swupdate.dart:102-103). The Dart
  tests type the node texts by hand (swupdate_test.dart:372-373, retest_s_boards_test.dart:339); the Rust tests use
  the constants, never the literals (tests/swupd.rs:361, :789, :791, :861, :910). The coupling existed before, but
  before this change both texts gave the same line; now the split is the feature.
- Fix: two asserts in `rust/batman-proto/tests/swupd.rs`: `T_REVERTED.contains("退回")`,
  `!T_REVERTED_18.contains("退回") && T_REVERTED_18.contains("回到原本的版本")`, with a comment naming
  `swupdate.dart swNext`.

### MINOR-6 — the found line inside another pair of brackets

- Scenario: the name page or the country page cannot read the current value because the login ended "near".
- Evidence: settings_pages.dart:131 and :297 wrap `opLine(r)` in 「（…）」: the result is
  「讀不到目前的名稱（附近有像是這台節點的裝置，…（可能另一支手機正在連它）；…請找維修人員。沒有送出任何東西。）」 —
  brackets inside brackets, about 100 characters in a bracket. Correct but hard to read. (「沒有送出任何東西」 after
  a read is baseline.)
- Fix (either): leave and note it; or at those two places print `opLine(r)` after a full stop instead of in
  brackets. No test covers these two places with `found`.

### MINOR-7 — the design's test list and the tests differ for C3 reason 18

- Evidence: design §4 says `retest_s_boards_test` checks the reason-18 literal. The diff checks reason 18 only in
  `swupdate_test.dart:368-382` (unit, `swNext`); the board (`9.x_reverted`) covers phase 6 only. The unit test plus
  the one widget path (`next: swNext(a)`, swupdate.dart:398) is enough as a test.
- Fix: correct §4 of the design (one clause), or add a `9.x_reverted_18` board.

### MINOR-8 — `OpenSession` carries `found`, but its only user throws the reason away

- Evidence: the only `OpenSession` user is `update_route.dart:28`; its `failed:` callback is
  `(_) => link.noLink(h.now())` (:47). So on the update page a login that ended "near" still shows the flow's
  no-link text; `found` is tested (`op_session_test`) but never shown there. Not a regression (baseline), and the
  design names `OpenSession` only as a carrier.
- Fix: none needed in code; say in the PR "what it does not handle": the update page does not show the C2 line.

### Notes (no action required)

- `login_found_test` (c): the comment "found was noted before that" and core.dart:917 "before the memo below is
  dropped": with `perAddr` = 2 the first silence already adds the address while the memo is still there, so the
  order is not what the test proves. The code order is still the safe one.
- The C5 dialog does not name the node the keys go to and does not re-check after the dialog that the node is still
  in the records (the 0-line dialog is the same; baseline).
- `trace('loginFor $id -> notFound')` (node_link.dart:502) does not say which of the two lines the user saw; it can
  be worked out from the per-attempt lines above it.
- C4 made two existing tests need a phone-sized view (`key_abilities_test.dart:342`, `pages_test.dart:436`) because
  a row left the 800 x 600 test window. That is the stated cost (design C4), and 360 x 800 is closer to a phone.
  Other home tests still on the default window are covered only by the whole-suite run (see MAJOR-1).

## Verdict

**APPROVE-WITH-CHANGES**

The code does what design v3.1 says; `found` is wording only; the C5 dialog shows what is sent; nothing else is
broken that I could find by reading and by the four test files I ran. Required before the PR: MAJOR-1 (numbers from
the final tree). Recommended in the same PR: MINOR-2, -3, -4, -5 (four small tests, three with a named mutation).
MINOR-6, -7, -8 are wording / record items.
