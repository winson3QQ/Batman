# #329 A2 code review brief (two independent reviewers)

## What to review

- Design: `docs/design/329-takeover.md` v8, FROZEN at `eee3ebb` (the user ended design review after round 7). Review the
  code against it; a design point you disagree with is a MINOR note, not a reason to re-open the design.
- Code: `git diff 99d156a..HEAD -- app` on branch `feat/329-takeover` (worktree `C:/src/Batman-a2`). 99d156a = main
  after #367. The whole diff, not the last commit only.
- Baseline (already reviewed, not re-reviewed): main's behaviour. Review only what the diff changes, and what it
  changes for its callers (every caller of a changed signature or field).

## Three parts

1. NodeLink takeover (§1.1): `app/lib/src/nodelink/node_link.dart` (`_det`, `_ended`, `_waiter`, `setPage`,
   `acquire(forNode, gone)`, `_pump`, `_run`, `_abort`, `dispose`); `OpSession.once` / `OpDeps` / `opDeps` /
   `opBusyName`.
2. SettingsMemo (§1.2): `op_session.dart` `SettingsMemo`, `app_link.dart` `memo`, `settings_pages.dart` (`memoLabel`,
   Wi-Fi and country pages).
3. Note (§1.3): Rust `statuspage.rs` `Verdict.note` / `NOTE_JOINED_CRIT`, bridge `StatusView.note` (FRB generated
   files), `home_logic.dart` (`lineOf`, `nodeRowHint`, rule 14 variant), `widgets.dart` `NodeRow.hint`,
   `home_page.dart`, `node_page.dart`, `more_pages.dart`.

Tests: `test/nodelink/takeover_test.dart` (T1–T17, O3), `test/flows/op_session_test.dart` (O1, O2, O4),
`test/ui/settings_pages_test.dart` (group "329-takeover", W1–W6), `test/ui/home_logic_test.dart` (H1–H4, H6),
`test/ui/takeover_note_test.dart` (H4 page, H5), `test/ui/home_steady_test.dart` and `test/ui/layout_test.dart` (H7),
`app/rust/batman-proto/tests/statuspage.rs` (R1). Each named negative control was run as a mutation (the author's
runner, results in the PR); you may re-run any.

## Rules (the user's, apply them)

- Start from what happens in real use (a person opening a node page while home is still connecting, 手機 Wi-Fi /
  國家 opened and left at once, the phone going to the background, Bluetooth off, the node out of range, two pages
  in quick succession), not from this brief's list.
- Ownership: each resource touched has one writer; two writers on one resource is a finding.
- Contracts: for each changed interface (acquire's new parameters, `waitingName`, `OpDeps.memo`, `StatusView.note`),
  who writes / reads it, when valid, what happens when missing or stale.
- Lifecycle: page open / close, background / foreground, Bluetooth off / on, dispose, app restart, a node removed.
- Verify every assumption against the source (file:line); "should be" is not evidence.
- Security: the 手機 Wi-Fi page is a secure screen; nothing in the memo may hold the AP passphrase (check
  `SettingsView`); nothing new in logs.
- Require a negative control for each claimed fix: say which test would not fail if the code were wrong.
- Report numbered BLOCKER / MAJOR / MINOR findings, each with scenario, evidence (file:line, or a test you ran),
  and fix; then a verdict: APPROVE / APPROVE-WITH-CHANGES / REJECT.

## Limits

- Do not edit the worktree `C:/src/Batman-a2` or push anything. To run tests, make your own detached worktree
  (`git -C C:/src/Batman-a2 worktree add --detach C:/src/Batman-a2-rev<X> HEAD`), run
  `C:/src/flutter/bin/flutter test <files>` there (Git Bash: `cd` into its `app` first; never `dart format`), and
  remove it at the end (`git -C C:/src/Batman-a2 worktree remove --force C:/src/Batman-a2-rev<X>`). Rust tests only in
  WSL (`wsl -d Ubuntu-24.04 -u yello`), with your own `CARGO_TARGET_DIR`.
- No phone (adb), no node (ssh), no network access to devices.
- Write your report to `C:/src/Batman-a2-rev<X>-report.md` (outside the repo) and return its full text.
