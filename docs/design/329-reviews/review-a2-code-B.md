# #329 A2 code review — reviewer B

Scope: `git diff 99d156a..7019e1d -- app` (39 files), against `docs/design/329-takeover.md` v8 (FROZEN @ eee3ebb).
Worktree: detached `C:/src/Batman-a2-revB` @ 7019e1d (removed at the end).

## What I ran (raw results)

- `flutter test test/nodelink test/flows test/ui` -> `01:04 +1766: All tests passed!` (rc=0)
- `flutter analyze lib test` -> `No issues found! (ran in 41.5s)`
- WSL `cargo test --test statuspage` (batman-proto) -> `test result: ok. 13 passed; 0 failed`
- WSL `cargo test --lib member_tests` (bridge) -> `test result: ok. 4 passed; 0 failed; ... 94 filtered out`
- Mutation, mine: wake path `if (_disposed || me.gone()) return null;` -> `if (_disposed) return null;`
  -> `T15c ... [E]`, `+35 -1: Some tests failed.` (T15c is a real negative control.)
- Mutation, mine: remove `_d.memo.drop(widget.id)` from the country set (`settings_pages.dart:362`)
  -> `settings_pages_test.dart`: `+47: All tests passed!` (no test fails: MINOR-1 below).

## Verified against source (no finding)

- **Takeover (a)**: `setPage` takes `a = _attempt` before `core.setPage` and detaches only when `identical(_attempt, a)`,
  `!identical(core.running, a)`, `_link != null` and `_wanted(a)` (`node_link.dart:323-327`). `_pump`'s abort line is the
  design's line in full (`node_link.dart:940`). `_wanted` = `_onPage(id) && core.blocked == null &&
  core.states.containsKey(id)` (`:293`, `_onPage` `:678`, which includes `core.fg`). Every change of what `_wanted`
  reads goes through `_pump` (`background` `:330-334`, `radio` `:358-364`, `setPage`), so a detached attempt is
  aborted at the transition (T7–T10 cover background, Bluetooth, record, home).
- **Detached end**: `accepted = det ? (body|errorCode) && core.keptRead(...) : core.result(...)` (`:1097-1099`);
  `keptRead` returns false with no round / record (`core.dart:603-607`) and only records body / errorCode, with no retry
  (`core.dart:608-626`). `_noteRead` returns for anything but a body (`node_link.dart:858-859`), so an accepted error
  code writes no team / wall time. The park condition is main's with `(det && !_wanted(a))` added (`:1105-1112`).
- **Per-attempt completer**: `ended` is local, `end()` nulls the field only `if (identical(_ended, ended))`
  (`:1040-1043`); `_abort` completes and nulls the field (`:1127-1132`); tail order `end()` then `_pump()` (`:1116-1117`),
  `finally end()` backstop (`:1118-1120`). An aborted A's late end cannot touch B's completer (T17 exercises it).
  `_det` is cleared by `_abort` and on the normal end path (`:1093-1094`); the early returns only happen after `_abort`
  (they test `identical(_attempt, a)` / `cancel.isCompleted`), so this matches the design's rule.
- **Wait (b)**: condition before `core.acquireLease` (`:383-398`); one waiter, a gone waiter replaced, the replaced or
  disposed or gone waiter returns null without `acquireLease` (`:391-397`); 8 s on NodeLink's `after`, stopped on wake;
  `dispose` clears `_waiter` before `_dropAll` -> `_abort` wakes it (`:1155`, `_dropAll` `:1139-1140`). `_park` is
  synchronous (`Future<void>? _park`, `:684`), so the parked link exists when the waiter wakes; `acquire` keeps a parked
  link for a session lease (`:401-405`).
- **Callers of `OpDeps.acquire`** (grep `OpDeps(`): the only app maker is `opDeps` (`settings_pages.dart:26-27`), which
  forwards `forNode` / `gone`; `once` passes `id` / `gone` (`op_session.dart:117`), `OpenSession.open` passes neither
  (`:177`). `OfflineDeps` (`team_deps.dart:23-24`) is a different type and unchanged. Test rigs: `kept_link_test`
  forwards to the real `NodeLink.acquire`; the others are fakes that ignore the new named args (fine: they model the
  lease, not the wait). All 12 `once` call sites (grep) pass `gone: () => !mounted` or their flow's `gone`; the new
  "lease given after gone -> release" (`op_session.dart:119-122`) only ends earlier what main ended after the login.
- **Callers of `NodeLink.acquire` without `forNode`**: `raw_use.dart:74,88`, `dev_pages.dart:459`, `more_pages.dart:84`,
  `net_pages.dart:271,342,917`, `team_deps.dart:24` — byte-for-byte main's path.
- **`StatusView.note`**: Rust `note()` = `warning(p).is_none() && <old JOINED_CRIT condition>` (`statuspage.rs:340-342`),
  text unchanged (R1 asserts the literal). FRB: field order identical in Rust `into_dart` (`frb_generated.rs:3251-3253`),
  Rust sse (`:4002-4004`), Dart sse encode / decode (`frb_generated.dart:7868-7870`, `:6698-6700`) and the dco array
  (index 5, length 15); content hash equal on both sides (-1473740958). Every Dart reader of `.warning`
  (grep): rule 12 reads `warning` only (`home_logic.dart:165-168`), node page and `leaveFieldsOf` use `lineOf`
  (`node_page.dart:213`, `more_pages.dart:192`); `StatusFields` has no other maker.
- **What the user sees**:
  - 手機 Wi-Fi: the label is inside `SecureScreen` (`settings_pages.dart:202-210`); the field is filled only from the
    page's own read (`:149`); `can` (what enables 送出) does not read the memo (`:198`). The memo holds a
    `SettingsView` (no passphrase field). No new log line anywhere in the diff.
  - 國家: `_cc` is set only from the page's own read or a confirmed set (`:320`, `:370-373`); the memo country goes only
    through `_countryName` into the row's text (`:388-402`). W3 asserts the menu disabled and nothing checked with a
    memo and a failed read.
  - Home: the variant has no action (`home_logic.dart:182-186`), so no hero button; the row hint is set only for a fresh
    joined node with a note (`:39-42`); rule 10 (stale) and rule 12 (power) come first.
- **Tests that would fail if the code were wrong** (read, plus the two mutations above): T1b (`_link != null`),
  T2/T4(c)(e) (`pageNode`), T3 (wait before `acquireLease`), T4(d) (`_wanted` in the wait), T5/T6 (end / 8 s bound),
  T7–T10 (line 940), T11b, T12 (`kept Y1 -> errorCode` = 1), T14 (round's own attempt cut), T14b/c, T15/T15b/T15c,
  T17, O1/O2/O4, O3 (through `opBusyName`), W1–W6 (Wi-Fi), H1–H6, H7 (y of 「我的節點」).

## Findings

No BLOCKER. No MAJOR.

**MINOR-1 — the country page's `memo.drop` has no negative control.**
Scenario: a country set is sent and its answer is lost (結果不明); the next opening must show 「讀取中…」, not the old
country as 「（確認中…）」 / 「上次讀到」. Evidence: I removed `_d.memo.drop(widget.id)` at `settings_pages.dart:362`; the
whole `settings_pages_test.dart` passes (`+47: All tests passed!`). Only the Wi-Fi page's drop is pinned (W4 "the answer
lost -> gone"). The design's W4 names "set whose answer is lost -> entry gone" without limiting it to one page.
Fix: add the country twin of W4 "the answer lost -> gone" (`f.rigs[1].radio.silent = true; drop()` under the 改 tap,
then `expect(f.d.memo[id], isNull)`), and run it against the mutation above.

**MINOR-2 — the hero's reminder line puts a literal space after the name instead of using `nameIn`.**
Scenario: a node nicknamed in Chinese (e.g. 「山腰中繼」) gets the note: home prints 「山腰中繼 有一則提醒，點節點看。」 with a
space between two CJK characters. Evidence: `home_logic.dart:184-185` builds `'${noted.first.name} 有一則提醒，點節點看。'`;
the project's rule for a name inside a Dart sentence (`home_logic.dart:92-98`, #329 PR 7 T16: a space only where an ASCII
letter/digit meets CJK) is applied by every other hero (`fillX` / `_many`). The tests only use 「節點 0001」, where the
space happens to be right, so nothing fails. Fix: `fillX('X有一則提醒，點節點看。', noted.first.name)` (gives the same text for
「節點 0001」), and add one H1 case with a CJK nickname.

**MINOR-3 — two design items have no test that fails without them; say so in the PR.**
(a) T13 is not implemented; the header of `takeover_test.dart:4-6` says its conditions cannot be reached through
NodeLink's interface. I agree from source: no kept read or new attempt starts while `_attempt != null`
(`node_link.dart:952, 970`) and room is made before the connect (`_makeRoom`), so neither "a kept link of the same node"
nor "no room" can arise during a detached attempt. (b) the new park guard `(det && !_wanted(a))` (`:1107`) is defensive
for the same reason (every change of `_wanted` runs `_pump`, which aborts first); removing it would fail no test. Both
are fine as code; the PR's test section should list them as "defensive, no reachable negative control" rather than
leave §7's T13 looking covered.

**MINOR-4 — T12(a)'s name says more than its assertion pins.**
`takeover_test.dart` T12(a) "the round's own logins, as many as without the detached attempt" compares the total
`attempt a1×Y1` lines (detached + own) of the run with a control page round: 2 = 2. With the fake (2' on the first
session, body on the next) the run has the detached error + 1 own login, the control 2 own logins, so it pins the total,
not the round's own count the design text describes ("up to the round's usual number of logins … one login more than
today"). It does pin what matters for safety (`kept Y1 -> errorCode` = 1, session disposed, a body read by the round
afterwards). Fix: rename to what it checks ("the same number of logins in all"), or make the fake answer 2' on two
sessions and assert the own-login count.

## Verdict

**APPROVE-WITH-CHANGES** (MINOR only): fix MINOR-1 (add the missing negative control) and MINOR-2 (the name spacing);
MINOR-3 / MINOR-4 are wording in the PR / test name. No re-review needed for these.
