# Code review B — #329 honest errors (C1–C5)

- Reviewed: uncommitted change in `C:\src\Batman-msg` (`feat/329-honest-errors`, base origin/main 5999dae), whole `app/` diff
  (copy `a1-code.diff`, 926 lines) plus the live tree, against `docs/design/329-honest-errors.md` v3.1 (baseline, not re-reviewed).
- Date: 2026-11-20. Reviewer B, independent of reviewer A (A's report was not read).
- Limits kept: no adb / ssh / node / phone / network, no git state change, no file under `app/` edited, mutation runner not run.
  My only test file lived in the session scratchpad (`revB/revb_probe_test.dart`).

## Verdict: APPROVE-WITH-CHANGES

No BLOCKER, no MAJOR. Eight MINOR findings; 1–3 should be done before the PR (they are about negative controls and about the
evidence being older than the code), the rest are small hardening or notes.

## What was checked, and how

### Verified (with output)

- `flutter test test/nodelink/login_found_test.dart test/ui/home_steady_test.dart` on the live tree:
  `00:01 +13: All tests passed!`
- Reviewer probe, 10 tests, `+10: All tests passed!`, printed values:
  - P1 address hinted as another node (Y2), silent, login for Y1 -> `found=false hs=10` (correct).
  - P2 address liked as Y1, silent, then its hint changes to Y2 -> `found=true near={a1}` (finding 5).
  - P3 address picked as liked, hint is null when the result arrives -> `found=false` (finding 5).
  - P4 `refusedOther` once, then silent for the rest of the budget -> `found=true isY={}` (as designed: the node did answer).
  - P5 known a1 silent + stranger a2 undecryptable -> `found=true near={a1}` (correct: the stranger does not clear a1).
  - Steady hero, every `Look`, light and dark, text scale 1.0 and 2.0: `textContrastGuideline`, `androidTapTargetGuideline`,
    `labeledTapTargetGuideline` all pass, no overflow or exception. Heights at 1.0 = `[237, 237]` (both states equal);
    at 2.0 = `[371, 448]` (not equal; outside the design's stated limit, see finding 8).
  - Semantics labels of the steady hero contain no blank / `"\n"` label (placeholder is under `ExcludeSemantics`):
    `進行中\n正在找你的節點…`, `進行中\n一切正常，可以使用\n…\n讀取於 10:00`, `重新整理`.
  - Default `StatusHero` (steady false): `stacks=0 rows=1 h=85` -> tree is the old one.
- C1: literal in `rust/batman-proto/src/statuspage.rs:125` and in `rust/batman-proto/tests/statuspage.rs:305` compared
  byte for byte: SAME. No other consumer of the old text in `app/` or `docs/` besides the two doc lines the diff updates.

### Read against source (no run)

- `LoginFor` (`lib/src/nodelink/core.dart:781-960`), every `Res`:
  - `undecryptable` / `certRejected` -> `near.remove` (:888, :898): the address proved it is not this node. Correct.
  - `refusedOther` / `broken` -> `near.add` (:913). The driver contract (`prober.dart` `loginOutcome`) only yields these
    after the certificate verified, so a non-node cannot reach this line.
  - `noResponse` -> `near.add` only if `c.isY[addr] == id || like[addr] == id` (:917), read before the memo is dropped.
  - `refusedForbidden`, `body`, `errorCode` end the login with an end other than `notFound`; `node_link.dart:512` masks
    `found` with `l.end == LoginEnd.notFound`.
  - A result for a dropped attempt (`!identical(running, a) || !c.lease`) changes nothing.
  - Can `near` be non-empty for a non-node: only through an unauthenticated `like` hint (design accepts this; the line says
    "possibly"), and through finding 5 (P2). Can it be empty when the node clearly answered: only finding 5 (P3).
- All login-failure lines on screen: `loginLine` (`lib/flows/net_run.dart:54-60`) is the only place that words
  `notFound`; callers `NetRun` (:245), `CheckRun` (:414), `OpSession` (`op_session.dart:110`, :175), and `opLine`
  (`lib/ui/settings_pages.dart:42`) all pass `found`. Every page goes through `opLine` (dev_pages :191/:282,
  join_pages :137/:782, more_pages :291, remove_pages :407, send_key :62, settings_pages :131/:163/:297/:345). The only
  wrappers of `loginFor` (net_pages.dart:77, settings_pages.dart:28) hand the result through unchanged. Early returns in
  `_loginFor` (no lease, precondition) carry `found=false`, which is right: nothing was tried.
  One place does not show the login line at all: `update_route.dart:45` `failed: (_) => link.noLink(h.now())` (baseline,
  prints the Rust no-link sentence; see finding 8).
- `swNext` (`lib/swupdate.dart:100-105`) against `rust/batman-proto/src/swupd.rs`: `T_REVERTED` (:77, contains `退回`,
  not `回到原本的版本`), `T_REVERTED_18` (:78, contains `回到原本的版本`, not `退回`). The only `Action::Done` texts are
  `T_LATER`, `更新完成：{version}` (:1084), `T_REVERTED_18` (:1085), `T_REVERTED` (:1086), `T_CANCELLED` (:1167,
  `已取消，目前版本不變`). `reason_text(18)` (:128) and `T_LAST…` (:946) are `Show`, not `Done`. No fixed text misfires;
  the one open door is the node-supplied version string (finding 6).
- New on-screen texts and `splitCode` (`lib/say.dart:29-49`): it only splits on U+001E / U+001F; none of the new texts
  carries them, so nothing is moved into the technical fold.
- C5 `_send` (`lib/ui/dev_pages.dart:128-193`): `id` and `lines` are captured before the dialog; `if (yes != true ||
  !mounted) return;` — dismissing by back / outside tap sends nothing. Dialog is scrollable.
- Tests: all new tests drive the interface and assert results (lines on screen, sizes, calls sent), with their premises
  asserted. `-` lines of the test diff: no assertion weakened. `retest_s_boards_test` replaces a constant with a literal
  (stronger). `key_abilities_test` / `pages_test` change the view to 1080x2400@3 because the home hero is taller — an
  adaptation, not a weakening.

### Not done

- `cargo test` for C1 was not run by me (only the literal comparison above).
- The whole Flutter suite and the mutation runner were not run (per the brief).
- Nothing on a phone or a node: C4 at real font scale / TalkBack and C2 against a busy node are simulated only.

## Findings

### MINOR-1 — the evidence is older than the code (`widgets.dart` changed after the mutation run)

- Scenario: `lib/ui/widgets.dart` has mtime 11:12:51; the mutation log is from about 11:10 and the diff copy from 11:11.
  The live file differs from the diff: the placeholder is now `two(TextStyle st, Widget? w)` with
  `st.copyWith(color: const Color(0x00000000))` and the full style (including `fontWeight: w700`) (:115).
  So mutation M12 and any suite result quoted for C4 were taken on a different file.
- Evidence: `stat` output above; `home_steady_test` passes on the live file (my run), but M12 was not re-run on it.
- Fix: re-run `home_steady_test` and the C4 mutation(s) on the final file, and refresh the diff copy, before quoting them
  in the PR.

### MINOR-2 — no negative control for "a hint for another node does not count"

- Scenario: the user owns two nodes (02 and 04). Logging in to 04 while 02's address is in range and silent must still
  say "not found". The code is right (`like[a.addr] == id`, core.dart:917; probe P1 `found=false`).
- Evidence: mutation `core.dart:917` `like[a.addr] == id` -> `like[a.addr] != null` is caught by no test: every test in
  `login_found_test.dart` hints only the node being logged in to.
- Fix: add to `login_found_test.dart` "(i) an address hinted as another node, silent -> found false / plain not-found
  line". It must fail under the mutation above.

### MINOR-3 — no negative control for the `notFound` mask in NodeLink

- Scenario: one address is near (busy node), another ends the login as identity / refused. `LoginForResult.found` must
  be false so no caller can show the "found but no reply" line for a different end.
- Evidence: mutation `node_link.dart:512` `l.end == LoginEnd.notFound && l.found` -> `l.found` is caught by no
  NodeLink-level test; only `loginLine`'s own switch (test h) keeps the wording right today.
- Fix: one case in `login_for_test.dart`, e.g. `{'a1': 'busy', 'a2': 'cert'}` -> end identity and `found == false`.

### MINOR-4 — no negative control for the `steady` default

- Scenario: the design promises every other `StatusHero` user is pixel-identical.
- Evidence: mutation `widgets.dart:96` `this.steady = false` -> `true`: I found no test that must fail
  (`home_steady_test` only looks at the home page). My probe shows the property is cheap to pin: default hero has
  0 `Stack`, height 85.
- Fix: one small test: a default `StatusHero` with text only has no `Stack` and the old height.

### MINOR-5 — `near` and hint changes (two edge cases)

- Scenario a (P2): an address is liked as Y1 and silent once (`near.add`), then its advertisement resolves to Y2.
  `near` keeps it, so the login for Y1 ends "found but no reply" for an address now known to be another node.
- Scenario b (P3): an address is picked because it was liked; when the silent result arrives the hint is null (scan
  result without manufacturer data, or the resolver was rebuilt). `near` is not added -> plain "not found" although the
  attempt was made on a liked address.
- Evidence: probe output P2 `found=true near={a1}`, P3 `found=false`; `near` is decided from `like` at result time
  (core.dart:917), not at pick time, and is only removed on undecryptable / certRejected.
- Impact: wording only, both need the rotating identifier to change within one 60 s login; the line already says
  "possibly".
- Fix: remember "picked as liked/known" on the attempt in `next()` and use that at result time; drop the address from
  `near` when its hint moves to another id. Or write both down as limits in the design's residual list.
- Related note: the comment "before the memo below is dropped" (:917) is not load-bearing at `perAddr = 2` (the first
  silence already adds); moving the line below the drop is an equivalent mutation. Keep the order, no action.

### MINOR-6 — `swNext` matches with `contains`, without `swHero`'s `startsWith('更新完成')` guard

- Scenario: `Done` text is `更新完成：{p.version}` (swupd.rs:1084); the version is node-supplied. A version string
  containing `退回` (or `回到原本的版本`) gives an OK hero with the "reverted" advice under it.
- Evidence: `lib/swupdate.dart:100-105` vs `swHero` in the same file. Baseline for the first branch; the diff adds the
  second `contains`.
- Impact: low (needs a paired node with a hostile or odd version string; advice text only).
- Fix: check `startsWith('更新完成')` first in `swNext`, or compare against the two whole texts.

### MINOR-7 — C3 test is not where the design puts it, and nothing ties the Dart literals to the Rust constants

- Scenario: design §4 lists reason 18 in `retest_s_boards_test`. The diff tests it only as a pure-function case in
  `swupdate_test.dart` with a hand-typed copy of `T_REVERTED_18`. If the Rust text is reworded, `swNext` silently stops
  matching and all tests stay green.
- Evidence: test diff; `swupd.rs:77-78`.
- Fix: add a board that drives the Rust machine to `T_REVERTED_18` (e.g. `9.x_reverted_18`) and asserts the next line
  on screen; that also covers the constant.

### MINOR-8 — notes (no change needed, or one line in the PR body)

- `update_route.dart:45` drops the login `OpReply` and prints the Rust no-link sentence, so the update route never shows
  the new "found but no reply" line. Baseline; say so under "not handled".
- C4 at text scale 2.0 the two home states differ by 77 dp (371 vs 448). The design states its limit at 1.3 (42 dp);
  the PR body should give the 2.0 number too. Contrast and tap-target guidelines pass at 2.0 in both themes.
- C5 dialog does not name the node being written to (not in the design; the page header does).
- C1 has no Dart-level test and only takes effect after the Rust library / APK is rebuilt; `cargo test` output should be
  in the PR body.
- The 1080x2400 view in two tests could be `ensureVisible` instead; cosmetic.
