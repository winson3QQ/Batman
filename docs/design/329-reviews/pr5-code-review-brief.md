# #329 PR 5 code review brief (round 1)

You are an independent code reviewer. Review the implementation of #329 PR 5 in the worktree `C:/src/Batman-329pr5`
(branch `feat/329-pr5`), diff `git -C C:/src/Batman-329pr5 diff 2e18de6..HEAD -- app` (2e18de6 = main before PR 5).

## What this PR is
The Flutter app's team pages: invite / join team / members / remove member / change network password (new secrets),
the 「隊伍與邀請」 hub, and the entries to them. The frozen plan is `docs/design/329-pr5-plan.md` v16 (rules R1–R19,
deviations D1–D12 in §4, and appendix B = deviations found while implementing). Read the plan's §0–§6 and appendix B.

## The baseline (do not re-review)
The old console `app/lib/nodes.dart` and the Rust crates' existing behaviour were reviewed in earlier PRs. Where the
plan says "照舊程式" (as the old code), the old code is the baseline: check that the new page does the same, do not
re-decide the old behaviour. Already-reviewed PR 3 / PR 4 code (net_pages.dart before this PR, owner_console.dart,
op_session.dart, lease / record writer) is baseline too; review only what this PR changes in them.

## Known and not to be reported
- The Rust side of R19 (`NetView.version` / `MnetView.version` in rust/bridge) is not in the tree yet: WSL is down and
  the codegen cannot run on this Windows host. The generated Dart classes have a temporary hand-added optional
  `version` field; the app shows 「版本讀不到」 until then. The Rust patch exists outside the tree. Review the Dart R19
  logic; do not report the missing Rust as a finding.
- `app/rust/bridge/src/api/rekey.rs` has an uncommitted test module (pin of R14 texts) not run yet; ignore it.

## How to review (the user's rules — follow them)
- Start from what happens in real use (a leader and members in the field, phones killed, nodes unreachable, two
  phones, a malicious member / compromised node), not from a list of points.
- Make the interfaces explicit: for each resource the change touches (records net/ mnet/ mpend/ node/, the lease,
  the clipboard, UiState, in-memory controllers InviteHolds / RemoveTicks / NodeLink.hints) — exactly one writer?
  For each interface (Rust calls, platform channel, TeamDeps) — who writes, who reads, missing / stale / malformed
  handling (fail-open or fail-closed, and why).
- Lifecycle: page closed mid-operation, app killed, lease revoked (60 s offline cap), radio blocked, retry.
- Verify each assumption against the source (`file:line`) — "should be" is not evidence. You may run
  `flutter test --no-pub <file>` (Flutter at C:\src\flutter\bin; run from C:/src/Batman-329pr5/app) and
  `dart analyze lib test`. Do NOT run anything that touches a phone (no adb, no flutter run/install), no WSL.
- Security as each actor: remote attacker (pasted / scanned codes), a malicious member, a compromised own node,
  a local unprivileged app (clipboard, screenshots), physical capture of an unlocked phone, our own mistakes.
  Secrets / codes / names must never reach logs, URLs or world-readable files.
- Tests: every fix claims a negative control. Check that tests really assert behaviour (not presence), and that
  a test that finds nothing to check would fail.
- Do not invent new mechanisms as fixes; prefer "do as the old code / the plan says".

## Output
Write your report to `C:/src/Batman-329pr5/docs/design/329-reviews/review-pr5-code-<X>.md` (X given below) with
numbered BLOCKER / MAJOR / MINOR findings, each: scenario, evidence (file:line, command output), fix. End with a
verdict: APPROVE / APPROVE-WITH-CHANGES / REJECT. Do not edit any other file. Do not commit.
