# Review P of `329-ux-speed-plan.md` v5 (whole document)

Reviewer P, independent, 2026-11-19. Source: worktree `C:\src\Batman-b8` (main 6760b78), read only.

- ✅ = I read the source line myself.
- ⚠️ = inferred from reading. Every finding below is ⚠️ in this sense: nothing was run (no suite, no prototype,
  no phone, emulator, node, adb, gradle, ssh).
- ❌ = not done: F1 (the device timing log in a scratchpad) was not opened; `fix/329-n1` was not read (N1 is
  taken as given; only the numbers in `329-n1-plan.md:34` were compared); the Android Keystore settings of the
  owner key were not read.

The v3 reviews (K, L) and v4 reviews (M, N) were read only after sections 1–3 were formed. The only file
written is this report.

Verdict: **APPROVE** — 0 BLOCKER, 0 MAJOR, 8 MINOR.

I looked hardest at the six deletions and the predicate put back in the hook. I found no reachable scenario in
which a deletion gives wrong behaviour, leaks a link, a timer or a session, or weakens security. The MINORs
are one control that cannot fail as written (1), three statements about cases that cannot be reached (2, 3, 6),
one missing test case on a real path (4), and text.

## 1. Findings

### BLOCKER

None.

### MAJOR

None.

### MINOR

**1. T12: the control "`onPage` with the *page* term removed" cannot fail for (c), (d) and (e) `setPage(home)`.**
§6 T12 says the terms are removed "one term at a time … page for (c), (d), (e) `setPage(home)`". But
`core.setPage` stores `pageNode = node` on every call (`core.dart:218-231` ✅), and no caller passes a node with
a page other than `Page.node`: `ui/home_page.dart:208,280,288` (home, no node), `:340` (other, no node),
`ui/net_pages.dart:203` (home), `:224` (`widget.back` / `widget.backNode`; the only callers that set `backNode`
are `ui/node_page.dart:83,121` with `back: Page.node`; `ui/team_hub.dart:51` passes `back: Page.other` and no
node), `ui/team_status_page.dart:62` (team) ✅. So off a node page `pageNode` is null, `pageNode == id` is
already false, and removing only `core.page == Page.node` still gives 0 links. This is the L-M2 class again
(a control that cannot fail), for one term. The behaviour is right; only the promised control is not.
Fix (either): (a) the control for (c), (d), (e) `setPage(home)` removes the page term **and** the page-node
term together (it then leaves 1 parked link); or (b) say the page term is a defence with no control, as §6
already does for `keptNeeds`. Foreground ((b), (e) `background()`) and page node ((e) other id) can fail as
written ✅.

**2. §4.4 "⚠️ `refresh()` while a round started early is active … a read in flight then records into the new
round" cannot be reached; say so, and say what `keptRead` does with no round.** A kept read runs only when a
round begins with a parked link. An early round begins only from `earlyDue` (`core.dart:575-577` ✅), which
`_end` sets for a target that ended `notFound` / `notYet` (`:615-623`, `:636-640` ✅). A round that had a
parked link ends `read` or `unchanged` (error code) or, on any other end, has closed the link first (§4.4), so
the early round after it starts with no kept link. Its own attempt gets the body, `core.result` sets `t.body`
(`:481-486` ✅) and only then `_run` parks, so `keptNeeds` is false for the rest of that round. A link parked
by the hook was lent under a lease, and `acquireLease` clears `earlyDue` (`:259-264` ✅); the round after the
release is a full one (`leaseDue`, `:573-574` ✅). The same holds for `tick`'s "full timer wins over an early
round" (`:550-554`). So there is no early round with a kept read in flight, and no test can show the
paragraph's claim.
Fix: replace the ⚠️ paragraph by "cannot happen" with this reason. And one line for the contract in §5:
`keptRead` returns false and records nothing when no round is active or the id is not a target of it (as
`result` does at `core.dart:471`, `:478`); no control, unreachable. Without that line an implementer who
takes "no round check" literally writes `_round!`.

**3. Three cells / cases describe "record removed" or "`core.result` returned false" where NodeLink cannot get
there.** NodeLink gives the core a record list at `node_link.dart:200` (start), `:499` and `:505` (both inside
`released`) ✅. At `:505` the core is still leased until that same call, so no round and no attempt is active;
`:499` needs a second lease taken during the record read, which `acquire` prevents by waiting for `_releasing`
(`:256-259` ✅). So: (a) §4.5 "record removed × reading → close" cannot be met (T5 rightly has no reading case
for it); (b) T19's cases "`core.result` returns false" and "the record is removed" are not reachable through
NodeLink's own events. Fix: mark (a) "cannot happen (F14)" like the lent cell next to it; for (b) say how the
rig reaches the branch (a direct `core.setRecords` call on the real core, between the prober's return and
`_run`'s resume) and that it is a defence, or drop those two cases and keep the branch as untested defence.
Also F14 cites `:200` and `:499`; the main path is `:505` (`core.releaseLease(… recs:)`), so "two places" is
three call sites, two of them in `released`.

**4. T19 should include the one real path on which an abort meets a returned `keep`: a cancel during the
hint / team step.** In `probe`, a cancel after the status page was read still returns that body
(`prober.dart:129-131` ✅: `done(read ?? noResponse)`). With `keepFor` true that outcome carries the `keep`
(built at the `answer` step, before the hint / team step with its 2 s budget). So "page left / background /
sub-page tapped during the 2 s after the answer" is the everyday form of T19's abort branch. T19 as written
("the attempt is aborted before `_run` resumes") can be built with a fake prober and would not show the prober
side. Fix: one T19 case with the real `SessionProber`: cancel between the answer and the end of the hint /
team step → 0 links, session disposed, no call into the session after the dispose. And one line in §4.1:
the prober skips its cleanup **only** when the outcome it returns carries the `keep` (the same `identical`
rule as F11, `prober.dart:256-257`), so there is no "cleanup skipped, no `keep` returned" path.

**5. T20 (b) must be built with no request in flight, or its control cannot fail.** "Link down during a
console's `_close` wait" reads as "while a step is in progress". In that case `_close` has already set
`_session = null` (`owner_console.dart:682-687` ✅) and `reusable` is false whatever `pass` checks. The case
that reaches `pass` is: no request out, the down event arrives after `_close` cancelled the console's state
subscription (`:679`) and before the hook runs. Reword T20 (b) to that.

**6. `statusPage` on the allow-list of §4.3 cannot make a difference today.** The only console call of
`statusPage` is the leave page's re-read (`ui/more_pages.dart:271` ✅; grep of `app/lib` for `.statusPage(`),
and that console has sent a leave, so it is never reusable. Harmless. Either drop it from the list or say it is
there for a later read-only flow; if kept, the Rust test of §6 already covers the sequence.

**7. T16 (c) and real time.** `dispose()` with a link lent and a request out runs `_dropAll`, which waits up to
5 s of **real** time for `gate.links == 0` (`node_link.dart:664-675`, `:677-686` ✅; today's behaviour for a
lease holder's link). The row is right; say that this case takes up to 5 s of wall time or that the rig
answers the request and closes inside that wait, so nobody "fixes" the wait away.

**8. Small text.**
- §5 "A send lent on [a silent dead link] ends 'outcome unknown' after the console's wait": when the phone's
  own supervision timeout fires first the request ends by link down (`_lost`, `owner_console.dart:391-397`),
  sooner than the wait. Same answer shown; wording only.
- §4.5 last paragraph lists `ui/more_pages.dart:84`, `ui/net_pages.dart:342`, `ui/dev_pages.dart:429`,
  `flows/offline_op.dart:118` and `OpenSession` ✅ all match. `net_pages.dart:917` (check network) does log in
  through `flowDeps` (`:77-79` ✅), as v5 says; it is pushed from the node page, so it is lent the kept link and
  its console is not reusable — worth one word in the lifecycle table ("check-network page: first step on the
  kept session, link closed after").
- B6: checked whether an error code can be tied to the session, so that "no retry by a new connect" would keep
  a bad session for as long as the page is open. ✅ `provd/session.go:856-885`, `:586-601`: the `status` errors
  are bad object, unsupported, `E_RATE` (handled as not fresh), `E_BUSY` and the helper's own codes; none
  depends on the session. No finding; one sentence in §4.4 with this evidence would close the question.

## 2. The six deletions and the predicate put back

For each: the real-use scenarios I walked, and the result. All ⚠️ by reading.

| v5 change | Scenarios walked | Result |
|---|---|---|
| 1.5 s wait in `acquire` deleted | sub-page tapped in the ~0.6 s of a 60 s read; tapped between the read's `status` and `info`; raw lease in the same moment; second `acquire` at once | read cancelled, reference cleared, link closed, `_dropAll` waits for it as for any link; the cancelled read's body is dropped by the "still its own and still reading" rule; the flow logs in by the slow path. No token change under a running read any more (that was K-M1 / L-M1), so nothing reopened. Cost = one reconnect, stated in §2. |
| `keysOk()` in the hook deleted | key becomes unusable while lent; while parked | lent: nothing notices before the close either way; after the park the null token lets no GATT call through; the next login runs `keysOk()` first (`node_link.dart:317-324`), calls `radio(keyOk: false)`, which closes the parked link. The only use before that is NodeLink's own status read on the already authenticated session. Not less secure in a way anyone can use. |
| inbox check at lending deleted | frame from the node while parked; frame between lending and the console's handler being set; frame held at the park after a console | parked: NodeLink's handler closes the link. Between lending and the console: the inbox holds it and the console gets it first (`handoff.dart:38-49` ✅), exactly as after a slow-path login. At the park: delivered inside the step, link closed, `pass` refuses, second close is a no-op (T7 b). |
| round-targets row and `keptOnly` deleted | page changes with a link parked; one record on home / team; record removed | a link is parked only where `onPage(id)` holds; on `Page.node` the targets are `{pageNode}` or empty (`core.dart:190-194` ✅); every way off that page is a `setPage` (close) and the record going is a close. The M1 / N-M1 path (parked off the node page) is closed by the hook's `onPage`. Unreachable row, rightly deleted. |
| round check in `keptRead` and `roundId` deleted | every event that ends or replaces a round during a kept read: `setPage`, `background`, `acquireLease`, `setRadio`, `setRecords`, `refresh`, the 30 s window, the 90 s cap | all but `refresh` close the link, so the "still reading" rule drops the outcome. `refresh` during a full round returns (`core.dart:314`); during an early round it cannot meet a kept read (MINOR 2). Window and cap: a kept read starts at the round's start and ends within 5 s. Sound; one guard line asked (MINOR 2). |
| forget of a **lent** link on `setPage` / `background()` / link down deleted | lent, then: leave the page; leave and come back before the close; open another node's page; background; background and back before the close; link down by event; link down through `linkStates` only; link down during `_close`; lease taken back with the holder open; holder never closes | page away / other node / background at the close → `onPage` false → `destroy()`. Came back to the same node's page in the foreground before the close → parked, which is the state the plan allows (page open, foreground, session still good). Link down by event → the console's own listener ends the session (`_lost`), not reusable; unseen or during `_close` → `pass` refuses (`up`). Lease gone → the gate closes the link, `released` forgets, the late close destroys the old object and cannot touch a newer kept link (new object per lending). No leaked link, timer or session found. While lent NodeLink holds no subscription and no timer, so there is nothing to leak on these events. |
| `onPage(id)` back in the hook | slow-path login from app settings (`Page.other`), from the join / remove pages (`Page.home` / `Page.team`, one record and several), background during the login, lock during the request | all end `destroy()` at the close. M-M1 / N-M1 closed. Controls: see MINOR 1 for the one term that cannot fail. |

## 3. Whole-design walk (real use)

| Path | Result |
|---|---|
| open the page, wait, sub-page read, send | sound; T1–T3, T17 |
| tap during the first read | one F1 as today, then kept; stated in §2 |
| 60 s on the page | read on the kept link; an error-code round ends at its 30 s window (no scan, so no candidates: `core.dart:426-437`, `:556-558` ✅), so reads are at most 90 s apart, inside the gate's 120 s and the node's 300 s |
| walk away, screen locks | `paused` → `background()` closes a parked or reading link; a lent one is destroyed at its close |
| split screen / shade (`inactive`) | link stays, reads go on; stated as intended |
| Bluetooth off / on | closed in `radio()`; second close from the link-down event is a no-op |
| node reboot / out of range | link down or the next read's 5 s limit closes it; silent phone: N1's bound, on-site check ❌ listed |
| second phone | cannot find the node while the page is open; stated cost, the user's direction; ❌ not tested, listed |
| app killed | process gone; node side is F8 + N1 |
| second operation while one runs | refused at `node_link.dart:260` before anything is touched (N-m9 fixed) |
| lease that never logs in (remove node, forget join, update page before its first step) | parked link untouched; read after the release or closed by the gate at 120 s |
| update page (`OpenSession`) | first `run` is lent the link (`op_session.dart:155-171` ✅); console lives until the page goes; not reusable → destroyed; a dead console is closed before the next login, so "lent cannot be met in `loginFor`" holds |
| two writers | none found: token only through `pass` (T13); `keptRead` only from NodeLink with no attempt beside it; the inbox slot has one owner per state |
| attacker in radio range | no new input; parked frames are not parsed |
| other app on the phone | ⚠️ stated, no test; session frames are encrypted; acceptable as stated |
| compromised node | can make the app close and reconnect, or hold the link while the page is open (same as answering reads) |
| physical capture | unlocked with the page open: today's rights without the wait; locked: parked link already closed |

Rules check: ownership (§5) names every new resource, including the three M and N asked for; contracts state
writer, reader and the fail-closed result; the lifecycle table has today / after / test for each path, with the
untested ones marked ❌; assumptions carry file:line and I found them right except the notes in MINOR 3 and 8;
security names the four actors, the surface delta (none), fail-secure (null token, lending after the checks)
and negative tests (T1, T13, T15). Over-design: nothing beyond MINOR 6; the gate's 120 s timer earns its place
(one owner, one test, and a real path that ends at it).

## 4. v4 findings: fixed or not

| v4 finding | State in v5 | Note |
|---|---|---|
| M-M1 / N-M1 (a slow-path login parks off the node page or in the background) | ✅ fixed | `onPage(id)` in the hook (§4.3); T12 (b)–(e); T3 states its page. One term's control: MINOR 1 |
| M-M2 (silent phone needs N1; cost not stated) | ✅ fixed | §2 dependency and both costs; §7 step 0; device pass on an N1 image; on-site check listed ❌. Numbers match `329-n1-plan.md:34` ✅ |
| M-m1 (other flows send `status`) | ✅ fixed | §4.4 list; `swupd.rs:49-50`, `:902-905` ✅; update page in §2 and §6 |
| M-m2 / N-m11 (tap during the first read) | ✅ fixed | §2, lifecycle row, device timing |
| M-m3 / N-m8 (inbox check at lending; held frame at park) | ✅ fixed | check deleted; park delivers the held frame; T7 (b) |
| M-m4 / N-m6 (leases that never log in) | ✅ fixed | list checked ✅; v5 is right that `net_pages.dart:271` and `:917` do log in |
| M-m5 (error code: no retry differs from baseline) | ✅ fixed | B6 and §4.4 give reason and cost; see MINOR 8, last point |
| M-m6 (second down source) | ✅ fixed | F4, §4.5, T20 (c); `ble_gate.dart:74-84`, `:137-149` ✅ |
| M-m7 / N-m11 (security lines) | ✅ fixed | §5 |
| M-m8 (T13 control) | ✅ fixed | — |
| M-m9 / N-m11 (`keysOk` in the hook) | ✅ settled by deleting it | §2 above: no wrong scenario found |
| M-m10 / N-m4 (ownership of the 5 s limit, inbox slot, state subscription) | ✅ fixed | §5 |
| M-m11 (lifecycle rows) | ✅ fixed | `inactive`, Bluetooth off / on, silent phone, first-read tap, update page, read-only flow off the page |
| M-m12 (1.5 s wait is over-design) | ✅ fixed by deleting it | B5, §4.2, T11 rewritten; nothing reopened |
| N-m1 (T4 (e) control could not fail) | ✅ fixed | the "still its own and still reading" rule is written and is the control; it can fail (the old body is recorded by `keptRead` in the new round) |
| N-m2 (round-targets row untested) | ✅ fixed by deleting it | unreachable, §2 above |
| N-m3 / N-m5 (closing state; timers after a close) | ✅ fixed | §4.5 rules 1–5 |
| N-m4 (listener per state; link down × lent) | ✅ fixed | §4.1, §4.5 cell "nothing; `pass` refuses" |
| N-m7 (T14 on a real path) | ✅ fixed | — |
| N-m9 (order in `acquire`) | ✅ fixed | after the refusal at `:260` |
| N-m10 (reading-state rows; `dispose()` × lent) | ✅ fixed | T5 reading cases, T16 (c); note MINOR 7 |
| N-m11 (`loginFor` × lent wording; F7; `member_ui.dart` path) | ✅ fixed | — |

v3 findings after v5's deletions: K-M1 / L-M1 not reopened (no wait, and the read is cancelled before the token
changes); K-M2 kept (T19; MINOR 3, 4 sharpen it); K-M3 kept (`up`, T20; `_open` stays true after a down until
`close()`, `ble_gate.dart:79-84`, `:111-113` ✅, so the control can fail); L-M2 class: one new instance, MINOR 1.

## 5. Citations checked

✅ match: F2, F3, F4, F5, F6, F7 (all `setPage` calls), F8 (`server.go:31`, `:35`; `session.go:868-879`;
`bluez.go:412-418`, `:772-776`), F9, F10, F11, F12 (`owner.rs:353`, `:894`, `:949-972`, `:1077-1083`, `:1383`),
F13 (`op_session_test.dart:207`), §4.9 (`ui/more_pages.dart:268-274`, `:313-316`; `app/lib/member_ui.dart:267`),
§4.5's list. F14: see MINOR 3. ❌ F1 not checked.

## 6. Verdict

**APPROVE.** No BLOCKER, no MAJOR. Fold MINOR 1–5 into the plan text or the test file before the controls are
run in step 2 (1 and 5 are controls that cannot fail as worded; 2 and 3 are unreachable cases to mark as such;
4 is one test case on a real path). 6–8 are wording.
