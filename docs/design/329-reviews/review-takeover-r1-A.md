# Review r1-A — 329-takeover.md (whole document)

Reviewer A, independent. Source read at main 99d156a (worktree `C:\src\Batman-a2`). Read-only; no device, no test run.
Marks: ✅ = checked in source at the cited line; ⚠️ = inferred from the design text (the design does not say, so the
outcome depends on how it is implemented).

Baseline (329-link-per-node, 329-ux-speed-plan, 329-honest-errors) not re-reviewed; it is cited only where this design
changes or contradicts it.

## Findings

### 1. MAJOR — §1.3 reverses a reviewed baseline decision without saying so; home says 「一切正常」 while the node reports CRIT

Scenario: node 02 joined, health CRIT. Today home shows rule 12 (yellow/warning). After the change home falls to rule 14:
「一切正常」 + 「你的節點連上了隊伍網路。現在沒有需要你處理的事。」 with a small reminder line.

Evidence ✅
- `docs/design/329-honest-errors.md:29–41` (C1): JOINED+CRIT is not only the default Wi-Fi password; the same verdict
  comes from critical battery, a core service down, mesh key. The neutral line was reviewed on that basis.
- `docs/design/329-honest-errors.md:158`: "home cannot show 「一切正常」 while 02 is in the F1 state".
- `docs/design/254-app-status-page.md:60`: the ⚠️ line must stay visible, not be removed as noise; k2 CRIT masks other
  CRIT (power, services).
- `app/lib/ui/home_logic.dart:155–160` (rule 12 reads `warning.isNotEmpty`), `:171–172` (rule 14 text).

The design says the cost is "agreed with the user" but does not cite or amend these three places, and the rule-14 body
text 「現在沒有需要你處理的事」 is false in the same sentence as a reminder that asks the user to do something.

Fix: (a) state in §0/§1.3 that this supersedes honest-errors C4 (:158) and 254-app-status-page :28/:60/:73, and update
those documents in the same PR; (b) when any node carries a note, rule 14 must not print 「現在沒有需要你處理的事」 —
give it its own body line (or its own rule row between 13 and 14); (c) define which node is named when two or more nodes
carry a note; (d) H-test: note present → the text 「沒有需要你處理的事」 is absent (negative control: fails with the
plain rule-14 text).

### 2. MAJOR — readers and tests of `warning` missing from §1.3's place table

Evidence ✅
- `app/lib/ui/more_pages.dart:189–192` (`leaveFieldsOf`) and `:211`, `:313` — LeavePage prints `⚠️ ${f.warning}`. After
  the move the Leave page silently loses the line. Not in the table; no decision recorded (show note / drop on purpose).
- `app/lib/member_ui.dart:186, 205` — `StatusFields.warning`.
- Tests pinning the old behaviour, not listed in §7 as "to change":
  `app/rust/batman-proto/tests/statuspage.rs:305` (exact string, with 「請到這台節點的」), `:390`
  (`got.warning == Some(WARN_JOINED_CRIT)`), `app/rust/bridge/src/api/owner.rs:2792`,
  `app/test/ui/home_logic_test.dart:135, 172–174` (row 12 on warning).
- Every `StatusView(` constructor in the Dart tests needs the new `note` field (frb-generated class, required field).
- The note wording changes 「請到」→「請用」 without being called out; it is pinned at `tests/statuspage.rs:305` and
  `254-app-status-page.md:28/:73`.
- §5 row "nothing outside the app parses the warning text" is marked "to check before implementing" — that is an
  unverified assumption in an approved design. My grep: the string occurs only in `statuspage.rs`,
  `tests/statuspage.rs` and docs (no harness hit) ✅ — record that as the evidence.

Fix: add LeavePage and StatusFields to the place table with the decision; list the pinned tests under "tests that
change"; close the §5 row with the grep result.

### 3. MAJOR — §1.1 acquire wait: order against `core.acquireLease`, and a second acquire during the wait, are unspecified

Evidence ✅ `app/lib/src/nodelink/node_link.dart:352–380`: today `reg.current` check (359) → `core.acquireLease(now())`
(360) → `_abort()` (369) → `_dropAll()` → `reg.acquire` (374). `core.acquireLease` cancels the round
(`core.dart:285–290`); `core.keptRead` returns false with no round (`core.dart:603–606`).

a) ⚠️ If the new wait sits after line 360 (today's order), the detached attempt's body is never recorded by
   `core.keptRead`, and the D-tests that expect "read recorded" cannot pass. If it sits before 360, the round keeps
   ticking for up to 8 s and may start/abort things under the waiting acquire. The design must name the position.
b) ✅ "parked under today's conditions" — today's condition includes `accepted` (`node_link.dart:1051`), which a detached
   attempt does not have (it skips `core.result`). The design must state the park condition for a detached attempt
   explicitly.
c) ✅ The wait opens a window of up to 8 s between the `reg.current` check (359) and `reg.acquire` (374). Quick taps:
   Wi-Fi → back → 國家 inside the wait. Both acquires wait on the same attempt. The first then takes the lease for a
   page that is gone — `OpSession.once` checks `gone()` only before `acquire` and after login
   (`app/lib/src/flows/op_session.dart`) — and the second gets null → 「另一個操作還在進行：手機 Wi-Fi」 for a page the
   user already left. Not in the lifecycle matrix.

Fix: state the order (recommend: wait first, then re-check `reg.current`, then `core.acquireLease`); state the detached
park condition; one waiter at a time (a second acquire during the wait returns null immediately, or queues behind
`_releasing`-style future); `OpSession.once` re-checks `gone()` right after `acquire` returns and releases. Tests: second
acquire during the wait; page closed during the wait (negative control: both fail without the re-check).

### 4. MAJOR — §1.2 a remembered SSID can be sent unchanged after a failed read

Scenario: phone A has memo SSID "team-old". Phone B renames the AP. A opens 手機 Wi-Fi, the field is prefilled from the
memo, the page's own read fails (node far). `can` only needs `!_reading && !_sending && ssidBad == null && pass ok`
(`app/lib/ui/settings_pages.dart:178`) ✅ — the user types a password and Send writes "team-old" back. Today the field is
empty after a failed read (`:120–139`), so the user must type a name.

This contradicts §1.2's own rule "a remembered value never enables a change", which the design enforces only for country
(`_cc`, `:307–314`).

Also ⚠️: the memo is not dropped after a set whose outcome is unclear or whose read-back failed (`:163–168`,
`:345–352`), nor after a join changes the country. It then shows 「上次讀到」 a value the app itself just tried to change.

Fix: show the remembered SSID as a label (「上次讀到：…」), not as field content; or clear an unedited prefill when the
read fails. Drop the node's memo entry on every set attempt that does not end with a confirmed read-back, and on
join/leave. W-test: memo + failed read → Send disabled or field empty (negative control: fails with plain prefill).

### 5. MAJOR — the detached attempt's completer is only completed on the success path

Evidence ✅ `node_link.dart:999` (`_run` returns early after `_makeRoom`), `:1036–1039` (returns when
`!identical(_attempt, a)`), `:1060–1069` (`_abort` nulls `_attempt`). The design says "`_run` completes the completer".
With Bluetooth off / app backgrounded / page left during the acquire wait (T7/T8 paths) the attempt is aborted, `_run`
leaves through one of the early returns, and acquire sits the full 8 s.

⚠️ The "detached" mark must belong to the Attempt object. If it is a field on NodeLink and is not cleared in `_abort`,
the next ordinary attempt skips `core.result`, and the round stays `running` until the 90 s cap (`core.dart:496`,
`:651–662`).

Fix: complete in a `finally` of `_run` and in `_abort` and `dispose`; store the mark and the completer on the attempt
record created at `:994`. Test: abort during the wait → acquire continues within one tick (negative control: completer
only on the success path → 8 s).

### 6. MINOR — "8 s = the attempt's own budget" is not what the source says

✅ `app/lib/src/nodelink/prober.dart:129–132`: `due` bounds connect→msg2 only. Before it: `_makeRoom` up to 60×100 ms
(`node_link.dart:716–735`). After it: status read, then hint/team step (`hintMax` 2 s, `prober.dart:58, 289`). The 8 s
timeout followed by `_abort` is a sound bound; the stated reason is wrong, and so is the cost line in §4.

Security note: a nearby device replaying a known address makes the in-flight attempt a dead connect; every sub-page
open then pays the full wait. Bounded, no data exposure — state it in §6. Cheaper: wait only when the attempt's link is
already connected (`_link != null`), otherwise abort as today.

### 7. MINOR — detach in `_pump` covers more causes than the lifecycle matrix lists

✅ `node_link.dart:900` aborts for any `core.running` change. With the new rule every such change while on that node's
page detaches instead: round end at cap (`core.dart:651–662`), early→full switch (`:643–646`), `refresh`
(`:337–345`). With no round, `core.keptRead` returns false (`:603–606`): link parked, body dropped, no read time shown.
None of these have a matrix row or a test.

Also: §1.1-2 says a detached result without `keep` is "dropped", T13 says "destroyed" — say whether the body is still
recorded (it should be; `keepFor` false only means no parking, `node_link.dart:113–120`).

Simpler: detach only at the two places the goals need — `setPage(node X)` while the attempt targets X, and session
acquire. Everything else keeps today's abort. This removes the unlisted paths.

### 8. MINOR — §2 ownership: SettingsMemo has three writers

The table lists WifiPage, CountryPage and "NodeLink's record check drops entries" while claiming one owner. NodeLink
would need a reference to a UI-layer object; `_keptRecordCheck` only runs after a lease release
(`node_link.dart:869, 876`) ✅, so removal is late. Fix: one writer API (`put`/`drop`) owned by AppLink; prune on read
with `core.states.containsKey(id)`.

### 9. MINOR — two wrong facts in §5/§6

- "route observer keeps page = node on sub-pages": there is no RouteObserver/NavigatorObserver in `app/lib` ✅ (grep
  empty). The assumption still holds, for a different reason: sub-pages never call `setPage`
  (`node_page.dart` has no call; callers are `home_page.dart:208, 280, 288, 295, 340`, `net_pages.dart:203, 224`,
  `team_status_page.dart:62`). Cite that.
- §6 "shown on the same secure screen as today": CountryPage is not inside `SecureScreen`
  (`settings_pages.dart:363`; only WifiPage at `:182`) ✅. Harmless as long as the memo's SSID is rendered only on
  WifiPage — say so, and keep the passphrase out of the memo explicitly.

## Checked, no finding ✅

- §5 rows for `core.dart:603–620`, `:255/:258`, `ble_gate.dart:195`, `:302–309`, `node_link.dart:446–452`, `:911/:928`
  match the source.
- A link parked by the detached attempt has token null, so `gate.revoked(mine)` (374–376) does not close it.
- `_run`'s tail after the probe is synchronous when `keep != null`, so the park lands before acquire resumes.
- `_dropAll` / `dispose` reach a detached attempt through `_abort`. No double park, given the "no kept link for X yet"
  condition.
- `WARN_AP` and the note condition are mutually exclusive (`statuspage.rs:314–336`); the row for joined + CRIT stays
  green.

## Missing tests (each with a negative control)

Second acquire during the wait (3c); page closed during the wait (3c); abort during the wait (5); cap end / refresh
while on the node page (7); failed read with a memo present (4); Leave page with a note (2); rule-14 text with a note
(1).

## Verdict

**APPROVE-WITH-CHANGES.** No BLOCKER. MAJOR 1–5 are open: revise the design and review the whole document again before
implementation.
