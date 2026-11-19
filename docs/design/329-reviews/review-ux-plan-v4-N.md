# Review N of `329-ux-speed-plan.md` v4 (whole document; angle: concurrency and state machine)

Reviewer N, independent, 2026-11-19. Source: worktree `C:\src\Batman-b8` (main 6760b78) and, for the node's
`linkGrace`, branch `fix/329-n1`. Read only.

- ✅ = I read the source line myself. Nothing was run: no suite, no prototype, no phone, emulator, node, adb, gradle or ssh.
- ⚠️ = inferred from source. Every finding below is ⚠️ in this sense: a walk through the code, not a run.
- ❌ = not done: F1 (the device timing log) was not read; L's prototype and its logs were not opened.

The v3 reviews K and L were read only after sections 1–3 below were formed.

Verdict: **APPROVE-WITH-CHANGES** — 0 BLOCKER, 1 MAJOR, 11 MINOR.

The state machine for a link that starts on the node page (first read → parked → reading / lent → parked) is
defined, has one owner at each moment and I found no leak in it. The one MAJOR is a state the plan does not
list: a login in flight. A link that comes out of it is "born lent", and v4 removed the only conditions that
kept such a link from being parked off the node page or in the background.

## 1. Findings

### BLOCKER

None.

### MAJOR

**M1. A link that is born lent (source 2, a slow-path login) is parked on any page and in the background; on the
home / team page with one node it then stays for as long as the page is open.**

v4 deleted the hook's page and foreground conditions (§4.3, §9) because "the forget events of 4.5 already cover
them". A forget needs an event **while the link is lent**. For a link lent from the start (§4.1 source 2) the
page may never have been the node's page, or the event came while the login was still running, when NodeLink
held nothing to forget. The hook then has: `reusable`, still lent, `core.blocked == null`, `keysOk()` — all
true — and parks.

Scenario A (page). Read-only flows run `OpSession.once(… c.info())` from pages that are not the node's page:
- `ui/remove_pages.dart:102` (the remove page, one login per own node),
- `ui/join_pages.dart:721` (`_list()`, every node record; the join pages set `Page.home`, F7),
- and any later read-only flow added outside the node page.

Each is a slow-path login (no kept link on those pages), every request is `info` (on the allow-list of §4.3), so
`reusable` is true and the link is parked with `core.page != Page.node`. What ends it:
- more than one record: the round 6 s after the release has targets ≠ `{kept id}` → closed (§4.5). Up to 6 s
  parked, and this is the only row of §4.5 that has no test (see m2).
- exactly one record (the usual owner: one node): on `Page.home` / `Page.team` the round's targets are
  `{that id}` (`core.dart` `_pageTargets`: `Page.home || Page.team => _recs.keys`), which **is** "exactly
  `{kept id}`", so §4.4 reads on the parked link every 60 s and parks it again. The link stays until the next
  `setPage` call. Nothing bounds it in time.
- `Page.other`, or a session lease still held: no round; the gate's 120 s timer.

Scenario B (background). On the node page, no kept link yet (first read still running, or closed after a send).
The owner taps a sub-page; `acquire` returns; the slow-path login runs (about 4 s, F1); the owner presses home.
`background()` finds no kept link and nothing lent. The login is not cut (`node_link.dart:216-219` only cancels
the round), the read is answered (F13), the console closes with `reusable` true, the hook parks **in the
background**. No round runs in the background, so nothing reads or closes it until the gate's 120 s timer.

What the plan says against this:
- §2 "Does not handle: home / team pages"; §2 cost "until the owner leaves the page or the app".
- §5 Security "Background closes a parked link at once" — false in scenario B.
- §4.1 source 1 guards exactly this with `keepFor` (foreground, `Page.node`, `pageNode == id`); source 2 has no
  such guard.
- T12 page / background only tests an event during *lent*; T5 only starts from T1. No row starts from a login
  off the node page or a `background()` during a login.

Harm: not a safety break (the token is null, the session is the owner's own). It is the plan's own cost and
security statement broken: the node stops advertising and holds one of 2 slots while the owner is on the home or
team page (scenario A, unbounded with one record), and an authenticated session outlives the background by up
to 120 s (scenario B).

Fix (small; puts back one condition, with a control that can fail this time):
1. The hook's synchronous step 3 also requires the predicate of `keepFor` without its last term: foreground,
   `core.page == Page.node`, `core.pageNode == id`. Else `destroy()`. (Or: the slow path attaches the hook only
   when that holds at `loginFor`'s return, **and** step 3 checks it again; the check in step 3 alone is enough.)
2. Two test rows: (a) `Page.home`, one record, `OpSession.once` (info) → 0 links after the close;
   (b) `Page.node`, no kept link, `OpSession.once` (info) started, `background()` before the login ends → the
   request is answered, 0 links after the close. Control for both: that predicate removed from the hook. This is
   the reachable control L could not find in v3: L's rows started from a link that was already lent.
3. T3 states its page (`Page.node`, that id); it is the positive case for the same predicate.

### MINOR

**m1. T4 (e): the control "round check in `keptRead` removed" may not be able to fail.** v4 reworded T4 (e) to
"Bluetooth off then on during the read" (K-m2 / L-m3) and, in the same revision, added "`radio()` leaves
`core.blocked` set → reading: close" (K-m4). So in v4 Bluetooth off closes the reading link and cancels the read.
I went through every way the round can change during *reading*: `setPage` (closes), `background()` (closes),
`acquireLease` (`acquire` ended the read first), `setRadio` to blocked (closes), `refresh` (returns,
`core.dart:314-315` ✅), `setRecords` (drops the target, no new round, `core.dart:268-289` ✅). Each one also
closes the kept link. The round check is reached only if NodeLink passes the outcome of a read it has already
cancelled to `keptRead` (a cancelled `probe` can still return its body: `prober.dart:131`,
`done(read ?? noResponse)`). The plan does not say whether it does.
Fix: state the rule "when `read` returns, NodeLink first checks that this kept link is still its own and still
*reading*; if not, the outcome is dropped" and then either delete the round check or keep it as a defence and
write in §6 "control: none, unreachable", as T13 does. Not MAJOR: one sub-case, no behaviour at risk, and step 2
would show it; but §6 promises a failing control for every row.

**m2. §4.5 row "a round whose targets are not exactly `{kept id}` → close" has no test row,** and from T1 it
cannot be reached (`setPage` has closed the link before the targets can change). It is reachable only through
M1's scenario A. After M1's fix decide: unreachable → delete the row; or keep it and test it from scenario A
with several records.

**m3. "Closing" is a state the plan does not name.** `setPage`, `background()`, `radio()`, a link-state event and
a frame are synchronous; "close … wait until gone" is not. Say in §4.5: (1) the kept reference is cleared in the
same synchronous step as the event, so `keepFor` and `loginFor` see "no kept link" at once; (2) the closing link
still counts in `gate.links` and in `_dropAll` (so `acquire` and the next attempt wait for it, as for any
link); (3) `_pump()` runs when the close ends, as `_abort` does today (`node_link.dart:661`); (4) a second close
on the same handoff is a no-op (Bluetooth off gives both `radio(bluetooth: false)` and a link-down event).
Without (1) a `setPage(home)` followed at once by `setPage(node, id)` can find the old link still "kept".

**m4. Which states have a NodeLink link-state listener is not stated.** §4 says NodeLink listens while parked.
§4.5 says "link down × lent → forget", which needs a listener while lent, and for a link lent from the start
NodeLink has never subscribed. The outcome is the same either way: `pass` refuses a link that is not `up` when
the holder gives it back (T20 b). So either write the cell as "nothing; `pass` refuses at giving back", or say
that NodeLink subscribes at lending. As written, the forget in that cell has no control that can fail (the L-M2
class). Also say: one state subscription per kept link, cancelled on close and on forget, not added again on
each park (park → lend → park must not stack listeners).

**m5. The 120 s gate timer and a link closed by NodeLink.** "Any later `pass` stops it" (§4.5). A close is not a
`pass`. Say that closing the link cancels the timer (or that expiry on a closed link does nothing:
`GateLink.close` returns at once when `!_open`, `ble_gate.dart:111-131` ✅). Same for the 1.5 s wait in `acquire`
and the 5 s read limit: cancelled when the read ends. Otherwise 4.4's reads leave one dead timer per round.

**m6. §4.5 "⚠️ No such flow was looked for" — they exist** (✅ read):
- `OpenSession.open` takes the lease when the update page opens and logs in at the first `run`
  (`flows/op_session.dart:146-149`, `:155-190`; `ui/update_route.dart:28`);
- `ui/more_pages.dart:84` (移除節點), `ui/dev_pages.dart:429`, `ui/net_pages.dart:342` and `:917` take a session
  lease and never call `loginFor`.
Result as the plan says (parked up to 120 s, or read 6 s after the release); fail-closed. Replace the ⚠️ line by
this list. It also gives T14 a real path (m7).

**m7. T14 needs no "test-only skip".** A session lease held for 120 s with no `loginFor` (m6) is a real path on
which NodeLink never touches the parked link: take the lease, advance 120 s, expect 0 links and a `connect` that
succeeds. Control unchanged (gate timer removed). A black-box row is better than a switch in product code.

**m8. Hook step 3: say what "subscribe to the inbox" does with a held frame.** The console cleared its handler in
`_close` (`owner_console.dart:675-693` ✅), so a frame that came during the 10 s wait or during
`await keysOk()` is held in the `FrameInbox` and is delivered when a handler is set (`handoff.dart` ✅). That
closes the link inside step 3, before `pass(link, null)`; `pass` then throws `Refused` and `destroy()` runs on a
handoff already being closed. Simplest: step 3 checks "inbox holds no frame" first (the same check §4.2 has at
lending) and destroys otherwise. The §4.2 check itself ("parked … inbox holds no frame") cannot be met while
NodeLink's handler is set (a frame closes the link, T7): say it is a defence with no control, or drop it.

**m9. Order in `acquire`: the kept-link step is before the `reg.current` check** (§4.2), so an `acquire` that
will be refused (`node_link.dart:260` ✅) still closes a parked link when it is raw. Reachable only with a lease
already held and a link parked under it (m6) — rare, only speed lost. Cleaner: check `reg.current` first (it is
synchronous and changes nothing), then the kept-link step, then the existing line again.

**m10. Reading-state closes are tested only by T4 (b) and T11 (hang).** T5 starts from T1 (parked). Add one
reading case to T5 (for example `background()` between the `status` and the `info` request): 0 links, no call
into the disposed session, the cancelled read's outcome is neither recorded nor parked (this row also carries
m1's rule). Likewise "`dispose()` × lent" (§4.5: forget, then `_dropAll`) has no row; T16 covers `background()`
and `setPage` only.

**m11. Smaller points.**
- §2 "Does not handle" lacks: a sub-page tapped during the **first** read (page just opened, about 4 s): `acquire`
  aborts the attempt (`core.acquireLease`, `_dropAll`) and the flow logs in from scratch — today's cost, and the
  first read's work is thrown away. It is the most likely quick tap. State it and time it in the device pass.
- `loginFor` same id × *lent*: §4.2's "otherwise → close the kept link" contradicts "a lent link is only
  forgotten". Today's callers await the close before the next login (`op_session.dart:109-115`, `:171`,
  `:126` ✅), so it cannot happen; write "cannot happen" in §4.5 with that reason.
- `keysOk()` in the hook is the only `await` in giving back, and the reason step 3 must check everything twice.
  The next lending checks the key before any use (T15) and `radio(keyOk: false)` closes a parked link. Dropping
  it makes the hook one synchronous step. The plan's reason for keeping it is fair and its control fails (L);
  author's choice.
- §5 Security names no attacker in radio range. One line is enough: no new input; the kept link is the same
  authenticated session as today's, held longer; what it can cause is what §2 already states (the node does not
  advertise).
- F7's ⚠️ can become ✅: the only `setPage` calls are `ui/home_page.dart:208,280,288,295,340`,
  `ui/net_pages.dart:203,224`, `ui/team_status_page.dart:62` and the `back:` of `ui/team_hub.dart:51` (grep).
- §4.9 cites `member_ui.dart:267-282`; the file is `app/lib/member_ui.dart`, outside the path rule of §1.

## 2. State × event table

States: **none**; **login** (a `loginFor` slow path in flight — not in the plan); **reading**; **parked**;
**lent**; **returning** (the hook's `await keysOk()`; the holder waits in `close()`); **closing** (not in the
plan). "ok" = outcome defined, one owner, no leak found. Tests in brackets; "no test" = a defined cell with no row.

| Event | none | login | reading | parked | lent | returning | closing |
|---|---|---|---|---|---|---|---|
| pump tick / round starts | attempt as today | no round (lease) | ok: no second read, no scan (4.4) | ok: read if targets = `{id}`, else close (T4; "else close" **no test, m2**) | no round | no round | no attempt while `gate.links > 0`; pump after close **not stated (m3)** |
| read ends: body / error code / other / 5 s | — | — | ok: park / park / close / close (T4 a–d); outcome of a cancelled read **not stated (m1)** | — | — | — | dropped (m1) |
| session `acquire` | as today; aborts a first read (**m11**) | refused (`reg.current`) | ok: waits ≤ 1.5 s, then parked or closed (T11) | stays (T2) | refused | refused | waits in `_dropAll` as today |
| raw `acquire` | as today | refused | close (T10) | close (T10); also when it is then refused (**m9**) | refused | refused | as today |
| second `acquire` during the 1.5 s wait | — | — | ok ⚠️: both wait, `reg.acquire` refuses the later (`lease.dart:136` ✅) | — | — | — | — |
| `loginFor` same id | slow path → lent | refused (`_lfBusy`, `:304` ✅) | cannot happen | ok: lend (T2), after the checks (T15) | **wording conflict, cannot happen (m11)** | cannot happen (close is awaited) | waits until gone (4.2) |
| `loginFor` other id | slow path | refused | cannot happen | close (T10) | cannot happen | cannot happen | waits |
| lease released, holder closed first | — | login ends (today) | — | stays; read 6 s later | — | — | — |
| lease released / taken back, holder still open | — | today | — | not touched (null token) | ok: gate closes, forget (T8) | ok: gate closes, forget; step 3 fails → destroy (⚠️ no own row; same code as T8 + T20 b) | — |
| link down / stream ends | — | login fails (today) | close (**no test in this state, m10**) | close (T6) | "forget": listener **not stated (m4)**; `pass` refuses later (T20 b) | `pass` refuses (T20 b) | no-op needed (m3) |
| link down between the prober's answer and the park | — | — | — | — | — | — | ok: `pass` refuses → destroy (T19, T20 a) |
| frame with no request out | — | — | the read's | close (T7) | the console's | held, delivered in step 3 (**m8**) | ignored |
| `radio` → blocked | today | precondition (today) | close (**no test in this state**; conflicts with T4 e, m1) | close (T5) | stays; hook sees blocked (T12) | step 3 recheck (T12) | no-op |
| radio on again | new round | — | — (was closed) | — | — | — | attempt after gone |
| key lost (`keysOk` false) | — | precondition | — | closed at the next login (T15) | not parked (T12) | not parked | — |
| `setPage` away / other node | today | **nothing to forget → parked later (M1 A)** | close (**no test in this state, m10**) | close (T5) | forget (T12, T16) | forget → destroy | must already read as "none" (**m3**) |
| `background()` | today | **nothing to forget → parked later (M1 B)** | close (**no test in this state, m10**) | close (T5) | forget (T12, T16) | forget → destroy | no-op |
| `foreground()` | new round, read kept | — | cannot happen (closed in background) | only via M1 B: read on it | — | — | attempt after gone |
| record of this id removed | today | today | close; `keptRead` false | close (T5) | forget; seen in `released` | forget | no-op |
| `dispose()` | today | cancelled (today) | close (no test in this state) | close (T5) | forget, `_dropAll` waits ≤ 5 s as today (**no test, m10**) | forget → destroy | waits |
| parked 120 s, no `pass` | — | — | — | gate closes (T14, **m7**); timer after a NodeLink close **not stated (m5)** | — | — | — |
| app killed / phone crash | — | — | process gone; the OS drops the link; the node ends the session (F8) | same | same | same | same |
| node cuts a sessionless link after 30 s (`linkGrace`, `fix/329-n1` `bluez.go:799-819` ✅) | — | a login slower than 30 s fails as a link down (n1 plan, not this one) | does not apply: a kept link always has a session | does not apply | does not apply | does not apply | — |
| node ends the session (300 s idle, error) | — | — | read fails → close | frame or link down → close (T7); cannot idle 300 s on the node page (reads every 60 s; an error-code round ends at its 30 s window, so reads are at most 90 s apart ✅ `core.dart:547-579`) | the console's, as today | `reusable` false or `pass` refuses | — |

Two owners at once: none found. The token is NodeLink's (reading), null (parked) or the lease's (lent), and only
`pass` writes it. During the 1.5 s wait the lease does not exist yet. During *returning* the holder has stopped
(its `close()` is awaiting) and NodeLink has not parked. `core.keptRead` is the second writer into a round, but
only NodeLink calls it and no attempt runs beside a kept read.

Leaks: none found on the paths from T1. The paths that end at the 120 s timer by design: a lease that never logs
in (m6) and M1's scenario B. M1's scenario A with one record has no end at all.

## 3. Test table: can each control fail?

⚠️ All from reading; none run.

| Row | Control fails? | Note |
|---|---|---|
| T1, T2, T3, T4 a–d | yes (L ran a–c; d is new and plausible: the error falls to "anything else" → a second connect) | T3 must state its page (M1 fix 3) |
| T4 e | **doubtful** | m1 |
| T5 ×7 | yes | `radio` is new; in the fake no link-down event comes with it, so the line's removal leaves 1 link |
| T6, T7, T9, T10, T15, T16, T17 | yes (L) | — |
| T8 | yes ⚠️ | without the forget NodeLink still counts a kept link → `keepFor` false → the round's read is not kept → "1 parked link" fails |
| T11 | yes ⚠️ | wait removed → `gate.revoked(NodeLink's token)` closes the reading link → 2 connects; limit removed → 4.8 s (L's number) |
| T12 page / background | yes ⚠️ | but it only covers an event **during** lent; the cell before lent is M1 |
| T12 key, blocked | yes (L) | — |
| T13 | none, stated | fine |
| T14 | yes (L) | use the real path instead of a skip (m7) |
| T19 | yes ⚠️ | on the abort branch the link is closed by `_abort` anyway; it is the "session disposed" assertion that fails, so that assertion must be in every T19 case |
| T20 a, b | yes ⚠️ | `open` instead of `up` parks a link that is down → 1 link |
| T21 | yes ⚠️ | — |

Defined cells with no row: the six marked "no test" in §2 (m2, m10), and the two M1 cells.

## 4. v3 findings: fixed or not

| Finding | State in v4 | Note |
|---|---|---|
| K-M1 / L-M1 (the 1.5 s wait in the wrong place) | fixed | §4.2, §4.5, §4.6, B5, T11, §9 say one thing; the token and the round do not change during the wait, so the second request passes ✅ `node_link.dart:253-270` |
| K-M2 (`keep` neither parked nor destroyed) | fixed | §4.1 gives `_run`'s new shape; T19 |
| K-M3 ("link up" has no source) | fixed | `GateLink.up`, `pass` throws, T20; one loose cell (m4) |
| L-M2 (three controls could not fail) | fixed for T8 and T18; **T12 page / background: the fix opened M1** | deleting the hook's page and foreground conditions was right only for links that were on the node page when lent |
| K-m1 (two requests, per-session rate) | fixed | §4.4 |
| K-m2 / L-m3 (T4 `refresh`) | reworded, **now conflicts with K-m4's new row** | m1 |
| K-m3 (lease released, holder open) | fixed | §4.5 row, T8 |
| K-m4 (`radio()` while parked) | fixed | §4.5 row, T5 |
| K-m5 / L-m2 (where `reusable` is computed) | fixed | §4.3; matches `owner_console.dart:675-693` ✅ |
| K-m6 (provd restart) | stated as accepted, not tested | acceptable |
| K-m7 (existing tests list) | fixed | — |
| K-m8 (T11 / T13 columns) | fixed | — |
| K-m9 / L §4 (citations) | fixed | ✅ re-checked: F2–F13 lines match, incl. `owner.rs:894`, `:949-972`, `:953-956`, `:353`, `:1077-1083`, `:1383`; `bluez.go:412-418`, `:772-776`; `server.go:31`, `:35`; `session.go:868-874`; `op_session_test.dart:207`; `net_run_test.dart:143`. ❌ F1 not checked |
| L-m1 (`keysOk` is a `Future`) | fixed | §4.3 steps 2–3 |
| L-m2 (invented interfaces) | fixed | §5; still missing: the listener's life (m4), the closing state (m3) |
| L-m4 (real time in T2) | fixed | — |
| L-m5 (leave re-read) | fixed | §4.9, T21; ✅ `ui/more_pages.dart:268-274`, `app/lib/member_ui.dart:267-282` |
| L-m6 (lease that never logs in) | stated; "not looked for" is now answered | m6 |
| L-m7, L-m8, L-m9 | fixed (stated) | — |
| L-m10 (over-design) | page / foreground / lease conditions removed (see M1); `keysOk` kept with a reason | m11 |

## 5. Rules check (ownership, contracts, lifecycle, evidence, security)

- Ownership: stated and single for the kept link, the token, the gate timer and `keptRead`. Missing: the
  link-state listener (m4).
- Contracts: stated. Missing: the outcome of a cancelled read (m1), a held frame at park (m8).
- Lifecycle: the table covers the listed paths. Missing: a login off the node page or with the app going to the
  background (M1); a tap during the first read (m11).
- Evidence: every citation I opened matches. One ⚠️ can be closed (F7), one must be replaced by facts (m6).
- Security: fail-secure holds for the token (null while parked, lending after the checks). The claim
  "Background closes a parked link at once" has a hole (M1 B) and no negative test for it. No attacker-in-range
  line (m11).
- Over-design: the gate's timer is worth keeping (one owner, one test). `keysOk` in the hook and the
  "inbox holds no frame" check at lending are candidates (m11, m8). Nothing else.

## 6. Verdict

**APPROVE-WITH-CHANGES.** Before implementation: fix M1 (one predicate back in the hook's synchronous step, two
rows whose control can fail). The MINOR items are wording, one doubtful control (m1) and missing rows; m1, m3,
m4 and m8 are worth settling in the plan because an implementer has to decide them anyway.
