# Review r2-B — 329-takeover.md v2 (whole document, commit 511c472)

Reviewer B, round 2. Angle: the user and the field first, then the document. Read-only: source in
`C:\src\Batman-a2\app`, the reproduction log `Desktop\Batman\a1\a2-repro-2026-11-20.logcat`. No phone, node or git
state touched; nothing was run on a device. Every `file:line` below was read by me in this worktree. The round-1
reviews were read only after the findings were formed.

Legend: ✅ checked against source / log; ⚠️ inferred from reading (not executed); ❌ not checked.

## Verdict

**APPROVE-WITH-CHANGES.** No BLOCKER. Two MAJOR (1, 2) are open; both have small fixes that make the design
smaller, not larger. Direction (detach instead of abort; wait before `core.acquireLease`; label-only memo; note
instead of warning) is sound and the round-1 answers in §9 hold except where findings 1 and 2 say otherwise.

---

## Findings

### 1. MAJOR — the superseded waiter gets a null lease with its page alive: an empty 「另一個操作還在進行：」, and 「軟體更新」 becomes a dead tap for up to 8 s

The design gives exactly one caller a meaning for "null because a newer `acquire` took my place":
`OpSession.once` with `gone()` true (§1.1 (b), "One waiter"). It has more callers than that, and the first waiter's
page is not always gone.

Callers of a session lease that are reachable while `core.page == Page.node` and the node's attempt is in flight
(✅ all read):

| Caller | Where | On null today |
|---|---|---|
| `openSwUpdate` → `OpenSession.open` | `ui/update_route.dart:28`, `flows/op_session.dart:149–152` | SnackBar `'另一個操作還在進行：${a.reg.current?.name ?? ''}'` (`update_route.dart:34`); no `gone` at all |
| 「移除節點」 | `ui/more_pages.dart:84–88` | same string, same `?? ''` |
| `OpSession.once` when `gone()` is false | `op_session.dart:95` | `OpEnd.busy` with `d.busyName()` → `opLine` (`settings_pages.dart:41`) |
| `SendKeyButton` on the node page (dev builds) | `ui/rekey_send.dart:112, 139` | `OpSession.once` |

Scenarios (⚠️ traced, not run):

a. **Dead tap.** Node page still connecting, the user taps 「軟體更新」. `openSwUpdate` awaits the lease *before*
   any page is pushed (`update_route.dart:28` then `:40`). Today the lease returns at once (the attempt is
   aborted) and the page opens; with the wait the screen does not change for up to 8 s. This is "slower than
   today" and looks like a missed tap. The settings pages do not have this problem (they push first and show
   「讀取中…」).
b. **Double tap.** The user taps 「軟體更新」 again (natural after (a)), or taps 「手機 Wi-Fi」. The second
   `acquire` takes the waiter's place; the first wakes, sees another generation, returns null. Its context is
   mounted, `reg.current` is null (nobody holds a lease yet) → SnackBar 「另一個操作還在進行：」 with an empty
   name. If the first was 「軟體更新」 and the second 「手機 Wi-Fi」, the Wi-Fi page shows that SnackBar's
   sibling: nothing is in progress that the user can name.
c. **Same inside one page.** `WifiPage._read` is in `initState` (`settings_pages.dart:120`); if the user presses
   the send button while that read's `acquire` is still waiting, the read is superseded with `gone()` false →
   `OpEnd.busy` with `busyName()` null. (Whether the button is enabled during `_reading` decides reachability; ❌
   not traced to the end. The design must say.)

§5's last matrix row says a null lease must not show a wrong busy line; (b) and (c) are that line. No test in §7
covers `OpenSession.open`, the direct `acquire` callers, or a superseded waiter whose page is alive (T-series cover
`once` + `gone()` only).

Also in scope of this finding: 「移除節點」 (`more_pages.dart:84`) is a records-only operation that never logs
in. `core.page` is still `Page.node` under `MorePage`, so the new wait applies and delays it up to 8 s for a link
it will not use.

**Proposed fix (smaller than v2).** Drop `_waitGen`. Give `acquire` an optional `gone` callback, checked when the
wait ends: gone → return null and the caller maps it to `OpEnd.gone` (as designed). A live first waiter keeps its
place; a second `acquire` during the wait does not wait and gets null with a real answer to "what is busy": set a
`_waitingName` that `busyName()` / the SnackBars use, so the line reads 「另一個操作還在進行：手機 Wi-Fi」 (true).
「Wi-Fi → back → 國家」 still works: the Wi-Fi page's `gone` is true, so when the attempt ends the lease is free
and 「國家」... must then be able to wait too — so allow a second waiter only when the first's `gone()` is already
true at the time the second arrives. State this as the contract of the wait ("who may wait, what null means, what
name is shown") for every caller in the table. For (a): either push the update page first, or show a progress
state on the row during the wait. For 「移除節點」: no wait (the caller says it will not log in), or a raw-style
flag. Tests, each with its negative control: `openSwUpdate` tapped mid-attempt opens after the attempt and uses the
parked link; two live waiters → the second gets a named busy, the first proceeds; 「移除節點」 mid-attempt
returns without waiting.

### 2. MAJOR — `_ended` and `_det` are written as NodeLink fields cleared "in `_abort` and when `_run` ends"; an aborted attempt's late `finally` then acts on the next attempt

Design §1.1: "New NodeLink state (all cleared in `_abort` and when `_run` ends)"; `_ended` is "a completer made at
the top of `_run`, completed in `_abort` and in a `finally`".

Source facts (✅): `_abort` nulls `_attempt` / `_link` and schedules `_pump` after the link's close
(`node_link.dart:1060–1069`); the aborted attempt's `_run` is still alive and returns later through
`if (!identical(_attempt, a)) { await keep?.destroy(); return; }` (`:1036–1039`). `_pump` may therefore start
attempt B while A's `_run` has not reached its `finally`. The existing code already guards this for the link
("a late end never closes the next attempt's", `:1033–1035`); the design does not carry the same guard to its new
state.

Consequences if implemented as written (⚠️ traced):

- **Double complete.** Every aborted attempt completes `_ended` in `_abort` and again in its `finally` →
  `StateError` in an unawaited future unless guarded. Not a race; every abort.
- **B's completer completed by A.** If `_ended` is one field: B's `_run` replaces it, A's `finally` completes it.
  A later `acquire` on B's page sees a completed completer, does not wait, and `_abort()`s B: today's behaviour,
  silently. This is the two-node field case: in the reproduction log, 2 of the 4 taps on 04 arrived while the home
  round's attempt was to the *other* node (`…880c`, log lines 3616 and 19150 ✅), which is aborted as today — so A
  aborted / B started / sub-page tapped is the common sequence, not a corner.
- **B's `_det` cleared by A.** "Cleared when `_run` ends" without an identity check clears B's detachment; `_pump`
  line 900 then aborts B.

T16 covers the inherited-flag case only; nothing in §7 has two attempts overlapping.

**Proposed fix.** Put the completer on the attempt (local to `_run`, reachable from `acquire` through the
`Attempt` or a `(_attempt, completer)` pair), complete it with `if (!c.isCompleted)`; clear `_det` only
`if (identical(_det, a))`. One line in §2/§3 saying the state is per attempt. Test (negative control: fields
shared): abort A, let B start, then let A's `_run` unwind; `acquire` must still wait for B, and B must stay
detached.

### 3. MINOR — the line quoted as evidence in §0 is not in the cited log, and the log covers a shorter time

§0 quotes `attempt …7d2c connected=1616ms result=noResponse after 2728ms` and "body 9.2 s after the tap" from
`a2-repro-2026-11-20.logcat`, captured "11:42–11:49". In that file (34812 lines, ✅): no line contains
`connected=1616` or `after 2728ms`; the first attempt line is at 11:45:59; every cancelled attempt to `…7d2c` has
`connected=-1` (lines 3767, 11002, 11163, 24946, 25103); the only connected `…7d2c` attempt ended `result=body`
(32492). The sub-page numbers in row 2 are of the right order (logins of 2.0–5.0 s seen ✅). So the headline
example of 1.1 (a) — a *connected* attempt to the tapped node thrown away — is not shown by the file the design
cites. Either attach the capture it came from or replace the quote with lines from this one, and say plainly that
in this capture (a) would have saved attempts cancelled 0.1–2.9 s into the connect.

### 4. MINOR — D1/D2/D4 have no pass numbers, and D1 does not control which node the home attempt is on

1.1 (a) applies only when the in-flight attempt is to the tapped node (design: "an attempt to another node: no
wait, `_abort()` as today"). With two nodes that is about half the taps (finding 2's log lines). D1 must state:
the tap counted only when the log shows the attempt to the tapped node with its connect started; pass = no
`result=noResponse` for that attempt and no second scan before the body; and a number (for example body within
the attempt's own end + 1 s). D2: pass = one connect per sub-page open and login under a stated bound, against
§0's 3.5 / 6.1 / 25.7 / 4.0 s. Missing device checks: 「軟體更新」 mid-connect (finding 1), 「手機 Wi-Fi」 →
back → 「國家」 inside the wait, screen locked during the wait, a tap on the node that is out of range (must be
no slower than today).

### 5. MINOR — §1.3 carry-through

- **The hero still prints 「正常」.** `Look.ok.word` is 「正常」 (`ui/widgets.dart:30–36`) and `StatusHero` prints
  the word above the text (`:133`). With rule 14 + note the hero reads 「正常 / 可以使用 / 02 有一則提醒…」. §1.3's
  "it still does not say 「一切正常」" is literally true only. Not arguing the decision; state it in §1.3 and pin
  it in H1 / D3 so nobody "fixes" it later.
- **Doc lines not listed for editing** (✅ read): `329-app-uiux.md:682` (rule-14 table row), `:716` (the tip card
  appears the first time home shows 「一切正常」), `:976` (R-2). The tip card condition is `h.row == 14`
  (`ui/home_page.dart:361`), so it can now first appear on the noted state; say whether that is intended.
- **Tests listed as changing that do not need to.** `test/ui/home_logic_test.dart:135, 172–174` use a generic
  warning ('時間不準'), which stays rule 12. Listing them invites an edit that weakens rule 12's coverage. Replace
  with: a new case "yellow/warning + note cannot coexist" and a case for the joined-critical constant by name.
- **Layout.** No test for the new fourth row line (`hint`) and the longer `next` at text scale 2.0 with a long
  nickname. `NodeRow` has `minHeight: 84` and three lines today (`widgets.dart:162–205`); add the existing layout
  test's cases for the hint line and for 「N 台節點有提醒，點節點看。」.
- **Compile-level readers.** `nodeRowWords` is destructured as a 3-tuple at `home_page.dart:414` and
  `node_page.dart:208`, and indexed at `net_pages.dart:548`. The §1.3 table should list all three (the compiler
  catches the first two; the third keeps working and silently ignores the hint — confirm that is wanted on the
  network form).
- `_remember` (`home_page.dart:174–187`) stores 'ok' for green regardless of the note: consistent with the
  decision ✅.

### 6. MINOR — §1.2 memo

- 「上次讀到：<名稱>」 carries no time. The country changes by this phone's own join (the dialog says so,
  `settings_pages.dart:334`) and by a second phone; the AP name by a second phone. `drop` covers only this page's
  set. Either drop the node's entry on a join / leave of that node as well, or print the read time. The design's
  rule "never in a field, never enables a change" ✅ keeps this from being more than a display issue.
- Place of `drop(id)`: "right before any set" must mean inside the requests callback, after the login succeeded
  and immediately before `c.setAp` / `c.setCountry`. Dropped before the login, a failed login loses a still-true
  value; W4 should include "login failed → entry kept" and "set sent, answer lost → entry gone".
- Existing behaviour the memo now makes visible: after a set whose answer was not read back (`v.read` false),
  `_now` keeps the old value (`settings_pages.dart:141–171`). With `drop` the memo is empty, so the next opening
  reads: fine; say it in §5.

### 7. MINOR — small contract gaps in 1.1

- A detached attempt that ends with an error code goes through `core.keptRead`, which sets `t.err` and plans no
  retry (`core.dart:603–625` ✅). Same as a kept link's read today; add the sentence so the "anything else: the
  round makes its own attempt" line is not read as covering it.
- `wanted(a)` does not include "no lease held". During the wait there is none by construction; after it, the
  ordinary path applies. One sentence in §3 closes round-1 B7 explicitly (§9 answers it only by "matrix rows").
- The wait sits before `core.acquireLease`, so for up to 8 s the round keeps running under a page that is already
  showing 「讀取中…」; if the attempt ends `noResponse` the round may start a *new* attempt before `acquire`
  resumes (same microtask order question as finding 2). `acquire` then aborts it as today — correct, but T-tests
  should include "attempt ends without a body during the wait → no second wait, login from the start, total not
  longer than today + the attempt's remainder".

---

## Field walk (what the screen shows; is it true; can it stick; slower than today)

| Situation | After the change | Finding |
|---|---|---|
| Open app, tap a node at once, attempt to it in flight | page's round takes the read; no second scan ⚠️ | 4 (D1 criterion) |
| Same, attempt is to the other node | as today (abort, new scan) ✅ by design | 2, 4 |
| Tap 「手機 Wi-Fi」 at once | 「讀取中…」, waits for the attempt, parked link lent ⚠️; bound = 8 s timer then today's path ✅ | 7 |
| Wi-Fi → back → 「國家」 | lease goes to 「國家」 ⚠️ | 1 (contract), 2 |
| Tap 「軟體更新」 mid-connect | nothing for up to 8 s; double tap → empty busy line | **1** |
| 更多 → 移除節點 mid-connect | waits for a link it does not use | 1 |
| Lock screen / background during the wait | `_pump` aborts, waiter wakes, `core.fg` false → no park ✅ (`node_link.dart:900`, `:1051`) | none |
| Bluetooth off / on during the wait | abort via `core.blocked`, waiter wakes; today's blocked text ✅ | none |
| Walk out of range mid-attempt | attempt ends at its own limits (8 s to msg2, `prober.dart:129–132`; 20 s answer, `:233`); `acquire` cuts at 8 s ✅; not slower than a fresh attempt would be | none |
| Node reboots mid-connect | same as out of range; nothing parked, nothing recorded ✅ | none |
| Second phone changes the AP name | old name only as 「上次讀到」 / 「（確認中…）」, never sent ✅ | 6 (no time) |
| Joined + critical, no low power | green hero 「可以使用」 + reminder, row hint, sentence on the node page | 5 |
| Joined + critical + low power (a warning exists) | warning wins, rule 12 yellow, no note ✅ by §1.3 | 5 (test) |
| Stale view (not fresh) | no note on home ✅ by §1.3 | none |

## Security walk

- BLE replay / compromised node: no new input; the detached attempt is the same handshake with the same checks;
  its answer enters by `core.keptRead`, which records only for a target of the active round with a record present
  (`core.dart:603` ✅). A node cannot make the app wait longer than 8 s in `acquire` ✅.
- Second owner phone: finding 6; never causes a write.
- Shoulder surfer / screenshots: AP name stays inside `SecureScreen` (`settings_pages.dart:182` ✅); the memo holds
  no passphrase (✅ by the type the design names; needs the negative test "memo has no passphrase field after a
  set" — W-series has it implicitly, make it explicit). Country page is not secure today and shows nothing new.
- Fail-secure: every new failure path ends in "abort as today" or "read again" ✅, except the wrong busy line of
  finding 1 (honesty, not security).
- Logging: nothing new logged ✅ by design text; ❌ not verifiable before code.

## Evidence check of the design's citations

Verified correct ✅: `node_link.dart:303, 446, 639, 900, 911, 928, 1051`; `core.dart:255, 603`;
`ble_gate.dart:195, 302–309`; `op_session.dart:94`; `home_logic.dart:171, 179`; `statuspage.rs` joined-critical
condition (`:332`, return at `:333`); `owner.rs:2792`; `more_pages.dart:313`.
Wrong or unsupported: the §0 log quote (finding 3); `home_logic_test.dart:135, 172–174` as tests that change
(finding 5).

## Round-1 answers (§9)

A1/B11, A4/B8, A6/B3, A7/B4, A8/B9, A9, B6, B10: answered ✅. A3/B1/B2 (second acquire): answered for
`OpSession.once` only → finding 1. A5/B5 (completer, flag): answered for one attempt at a time → finding 2.
A2/B12 (readers, pinned tests): three doc lines and two readers still missing, two tests wrongly listed →
finding 5. B7: finding 7.
