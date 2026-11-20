# #329 A2 — take over the connection in progress; known values first; the "joined but critical" line leaves home's hero

Status: v2, for review (v1 reviews: `329-reviews/review-takeover-r1-A.md`, `-B.md`; what changed is in §9). App only
(Dart + the status verdict in `batman-proto` + one bridge field). No node, firmware or harness change.

Baseline (reviewed, not re-reviewed here): `329-link-per-node.md` (#366: one kept link per node, lend / park /
give back, gate rules), `329-ux-speed-plan.md` §4, `329-honest-errors.md` (#367), `254-app-status-page.md`.
Everything below is a change against main 99d156a. §1.3 **supersedes** two reviewed lines on the user's request
(2026-11-20); they are named there and edited in the same PR.

## 0. What the user sees today (reproduced, phone S20, main-equivalent APK, 2026-11-20 11:42–11:49)

Evidence: `Desktop\Batman\a1\a2-repro-2026-11-20.logcat` (script `a2repro2.sh`: background 8 s → launch → tap 04 →
tap 「手機 Wi-Fi」 after 0.3 / 1.5 / 2.5 / 3.5 s).

| Step | Seen |
|---|---|
| Home → node page of 04 while the home round's attempt to 04 is in flight | The attempt is cancelled (`attempt …7d2c connected=1616ms result=noResponse after 2728ms`), a new round scans and connects again; body 9.2 s after the tap. Left alone, that attempt would have ended about 1.5 s after the tap. |
| Node page still connecting → 「手機 Wi-Fi」 | 4 of 4: the attempt in flight is cancelled, the sub-page logs in from the start: 3.5 s, 6.1 s, 25.7 s, 4.0 s until logged in. With a parked kept link (#366) the same step is about 0.1 s. |
| Home, 02 joined but `k2 = 2` | The yellow hero: 「02：節點回報異常，可能是手機 Wi-Fi 還沒設定 — …」 while 02's row is green (user, 2026-11-20: a reminder that belongs in the node; on home it alarms). |
| 「手機 Wi-Fi」 / 「國家」 opened a second time | 「讀取中…」 again, although the app read the same value a moment ago (user, same message). |

Causes, from source:
- `core.setPage` (`core.dart:244`) cancels the round on any change but home ↔ team and starts a new one for the node
  page; `NodeLink._pump` (`node_link.dart:900`) aborts the attempt the core no longer owns.
- `NodeLink.acquire` (`node_link.dart:352`) cancels the round (`core.acquireLease`, :360) and calls `_abort()` (:369)
  before the lease is given; `_loginFor` lends a kept link only if one is already parked (`node_link.dart:446`).
- `home_logic.dart:155`: any non-empty `warning` makes the hero yellow; `statuspage.rs:332` returns
  `WARN_JOINED_CRIT` as a warning.
- The status read carries neither the AP name nor the country (`StatusView`, `owner.dart:628`); they come from
  `settings/get`, which only the two sub-pages send (`settings_pages.dart:126, 295`), and nothing remembers the answer.

## 1. Changes

### 1.1 The attempt in flight is taken over, not cancelled (NodeLink only; the core is not changed)

Two places, and only these two. Every other way an attempt loses its round (cap, `refresh`, early → full, another
page, background, radio blocked) aborts it as today.

**New NodeLink state** (all cleared in `_abort` and when `_run` ends):
- `_det`: the attempt that was detached (`Attempt?`, compared by identity with `_attempt`). Not a bare flag: the
  next attempt can never inherit it.
- `_ended`: a completer made at the top of `_run`, completed in `_abort` and in a `finally` around the body of
  `_run` (every exit: the return after `_makeRoom`, the superseded return, the normal end, an exception).

    wanted(a) = _onPage(a.id) && core.blocked == null && core.states.containsKey(a.id)
    (_onPage = core.fg && core.page == Page.node && core.pageNode == id, node_link.dart:639)

**(a) Entering the node's page.** `NodeLink.setPage` (`node_link.dart:303`): with `a = _attempt` taken before
`core.setPage`, after it: if `a` is still `_attempt`, the core no longer runs it, its connect has started
(`_link != null`) and `wanted(a)` → `_det = a`. `_pump` line 900 becomes: abort unless `identical(_det, a) &&
wanted(a)`. So a detached attempt is aborted the moment the page is left, the app goes to the background, the radio
is blocked or the record goes. While `_attempt != null` nothing else starts (`node_link.dart:911, 928`, unchanged).

When a detached attempt ends in `_run` (the branch `core.result` would take is skipped; the core does not know it):
- `Res.body` or `Res.errorCode`: `taken = core.keptRead(now, a.id, a.addr, o)`: the existing entry for "an answer
  without an attempt of this round" (`core.dart:603`); it records only when the active round has the node as a
  target and the record is there. `_noteRead` when taken and a body, as `_keptRead` does today.
- The open session (`Outcome.keep`), if any: parked when `taken`, `wanted(a)` and today's conditions hold
  (`core.blocked == null`, `core.fg`, no kept link for the node, `_kept.length < keptMax`); else destroyed. This is
  line 1051 with `taken` in the place of `accepted`.
- Anything else (`noResponse`, refused, exception): nothing recorded, link closed; the round makes its own attempt.

Bound: a detached attempt has exactly the limits of a round's attempt (8 s to msg2, then the prober's answer
limits), and it is detached only after its connect started (no `_makeRoom` wait is taken over). The node page's
round has that node as its only target (`core.dart:255`), so the attempt it delays is the one to the same node,
which would have the same limits.

**(b) A session lease asked from the node's page.** `acquire(name, kind)`, after the `_releasing` wait and the
first `reg.current` check and **before `core.acquireLease`**: if `kind == session` and there is an attempt `a` (the
round's own or `_det`) with `_link != null` and `wanted(a)`, wait for `a`'s `_ended`, at most 8 s on NodeLink's own
timer (`after`). Then go on with today's code unchanged from the `reg.current` check (repeated) on:
`core.acquireLease`, closing `reading` kept links, `_abort()` (a no-op when the attempt ended; the cut at 8 s),
`_dropAll()`, `reg.acquire`, `gate.revoked(mine)`.
- Because the round is still there during the wait, a round's own attempt ends by the unchanged path
  (`core.result`, park at :1051) and a detached one by (a). No third path.
- The parked link has gate token null, so `_dropAll`'s wait and the revoke do not touch it (`ble_gate.dart:195,
  302–309`); `_loginFor` lends it (`node_link.dart:446`, unchanged).
- One waiter: a counter `_waitGen`. A second `acquire` that reaches the wait takes its place; the first returns
  null when it wakes and sees another generation. `OpSession.once` (`op_session.dart:94`): a null lease with
  `gone()` true is `OpEnd.gone`, not busy; a lease obtained with `gone()` true is released at once (`OpEnd.gone`).
  So 「手機 Wi-Fi」 → back → 「國家」 inside the wait gives the lease to 「國家」.
- The wait ends early whenever the attempt ends or is aborted (page left, background, Bluetooth off: `_pump` →
  `_abort` → `_ended`).

A raw lease, a session lease while another page is open, an attempt to another node, an attempt still in
`_makeRoom`: no wait, `_abort()` as today.

Not changed: what a round reads, the core, the lend / give-back rules, the gate, `keptMax`, `keepFor`, the 60 s
login budget (it starts after `acquire`, as today).

Cost: when the attempt taken over does not end with a body, the sub-page's own login starts later than today by the
time waited, at most 8 s (in the reproduction the failing attempt ended after 5.0 s). A device that answers on a
node's old address without being the node costs each sub-page opening up to those 8 s; nothing is parked, recorded
or shown from it. When the attempt succeeds the step is its remaining time plus about 0.1 s in place of 3.5–25 s.

Not handled (listed in #329): a kept link in state `reading` is still closed by `acquire` (about 0.35 s per round;
not reproduced); the 12 s gap before a connect in the 25.7 s run (inside the radio stack, cause unknown).

### 1.2 The settings sub-pages show the last value read, as a label

`SettingsMemo`: node id → the last `SettingsView` with `read == true` that a settings page got in this app run. In
memory only, one object created with the app's dependencies; its only callers are the two settings pages.

- `put(id, view)` after a successful read and after a set whose answer was read back; `drop(id)` right before any
  set is sent (so an unclear set leaves nothing remembered).
- 「手機 Wi-Fi」: while the page's own read runs, 「目前的名稱」 shows 「<名稱>（確認中…）」 in place of 「讀取中…」. **The
  text field is not prefilled from the memo**; it is filled only from the page's own read, as today (`:133`). If
  the read fails: today's failure line plus 「上次讀到：<名稱>」; the field stays as today.
- 「國家」: the shown country the same way. `_cc` (which enables the menu, `:307–314`) is set only by the page's own
  read, never from the memo.
- Sending stays disabled while the page's read runs (unchanged).
- The memo holds what `SettingsView` holds: no passphrase (the node never sends one, `owner.dart:570`). The name is
  shown only on 「手機 Wi-Fi」 (inside `SecureScreen`, `:182`), the country only on 「國家」.
- An entry is never used for anything but these two labels, so an entry of a node whose record went is never read
  (pages open only for nodes with a record); no pruning, no NodeLink dependency.

Why it is still wanted after 1.1: the user asked that a value the app has already read is on screen at once
(2026-11-20). 1.1 makes the read short (about the kept-link time plus one request); the label covers that time
and the case where the read fails. Premise corrected from the first proposal: the home round does not read these
values, so the first opening in an app run still shows 「讀取中…」.

### 1.3 "Joined but critical" is a note of the node, not home's warning

Rust: `Verdict` gets `note: Option<&'static str>`. In `warning()` (first match: power, heat, AP, joined-critical)
the last branch moves out: `note` is `Some(NOTE_JOINED_CRIT)` exactly when `warning` would be `WARN_JOINED_CRIT`
today (so never together with a warning: one line per node, as today). The constant is renamed; **its text is
unchanged**. The bridge's `StatusView` gets `note: String` (generated code regenerated; no wire change).

Dart: one helper `lineOf(v) = v.warning.isNotEmpty ? v.warning : v.note`.

| Reader of `warning` today | After |
|---|---|
| Home hero rule 12 (`home_logic.dart:155, 158`) | reads `warning` only: the note does not make home yellow |
| Home hero rule 14 (`:171`) | no fresh node with a note: unchanged. Else: `HomeHero(14, Look.ok, '可以使用', next: …, action: …)` with, for one such node, `next` 「<名稱> 有一則提醒，點進去看。」 and `HomeAction.seeNode` to it; for more, 「N 台節點有提醒，點節點看。」 and `HomeAction.showList`. Neither 「一切正常」 nor 「現在沒有需要你處理的事」 is printed then. |
| Home node row (`nodeRowWords`, `:179`) | a fourth value `hint`: 「有一則提醒」 when the row is the fresh-with-view branch, the node is in a network and the note is not empty; else empty. Shown as one small line under the sentence. |
| Node page (`node_page.dart:213`) | `lineOf(v)`: the same place and style as today |
| Leave page and status fields (`more_pages.dart:192, 211, 313`; `member_ui.dart:186, 205`) | `lineOf(v)`: unchanged on screen |
| Bridge (`rust/bridge/src/api/owner.rs:461, 2579`) | fills `note` beside `warning` |

`WARN_POWER`, `WARN_HOT`, `WARN_AP` (not joined) are unchanged and stay in home's hero.

Superseded on the user's request, edited in this PR:
- `329-honest-errors.md:158` ("home cannot show 「一切正常」 while 02 is in the F1 state"): home is green and says
  「可以使用」 with the reminder line; it still does not say 「一切正常」.
- `254-app-status-page.md:28, 60, 73` (the ⚠️ line of this state on home): it stays visible on the node page,
  the leave page and the status fields; on home it is the row's small line and the hero's `next` line.

Cost (told to the user, agreed): the node gives only the level "critical", not the reason; critical battery or a
core service down give the same state (`329-honest-errors.md:29–41`). Until the node reports a reason, such a fault
shows on home as a green hero with 「<名稱> 有一則提醒」, not as yellow.

## 2. Ownership

| Resource | Owner (only writer) | Readers |
|---|---|---|
| `_attempt`, `_cancel`, `_link`, `_det`, `_ended`, `_waitGen` | NodeLink (`setPage`, `_pump`, `_run`, `_abort`, `acquire`) | — |
| `_kept` | NodeLink (`_park`, `_lend`, `_forget`), unchanged | core via `setKept` |
| Round state, node states, memos | Core; a detached answer enters only through `core.keptRead` | NodeLink, UI |
| Gate links and tokens | Gate; `pass` only by NodeLink, unchanged | — |
| Lease | `LeaseRegistry`, unchanged | — |
| `SettingsMemo` entries | `SettingsMemo` (`put` / `drop`), called by the two settings pages | the same two pages |
| `Verdict.note` | `statuspage::link_verdict_for` | bridge → home, node page, leave page, status fields |

## 3. Contracts

| Interface | Writer → reader | Valid when | Missing / stale / wrong |
|---|---|---|---|
| `_det` | `setPage` → `_pump`, `_run`, `acquire` | identical to `_attempt` and `wanted` | not wanted: `_abort()` (link closed, nothing recorded) |
| detached answer → round | `_run` → `core.keptRead` | body or error code; the active round has the node as a target; record present | false: nothing recorded, no read time, session destroyed |
| detached session → kept link | `_run` → `_park` | taken, `wanted`, fg, not blocked, no kept link for the node, room | destroyed, link closed |
| `_ended` | `_run` (finally), `_abort` → `acquire` | completed once per attempt | never completed is not possible by construction; `acquire` has its own 8 s timer anyway, then `_abort()` |
| `_waitGen` | `acquire` → `acquire` | the waiter's own value | another value: return null (the caller's page is gone or a newer call took over) |
| `SettingsMemo[id]` | settings pages → settings pages | same app run, `read == true`, no set sent since | none: 「讀取中…」. Stale (another phone changed it): shown with 「（確認中…）」 / 「上次讀到」, never put in a field, never enables a change |
| `StatusView.note` | Rust verdict → Dart | a status body | "": no line |

Trust: every string shown still comes from static text or through `statuspage::shown` (unchanged). Note and warning
are compile-time constants.

## 4. Lifecycle matrix

| Path | Today | After | Test |
|---|---|---|---|
| First run / no records | no round, no attempt | same | existing suite |
| Home → tap a node mid-attempt (connect started) | cancel + new scan / connect | attempt finishes, body in the page's round, parked | T1 (device D1) |
| Same, attempt still in `_makeRoom` | cancel | cancel | T1b |
| Tap another node's page mid-attempt | cancel | cancel | T2 |
| Detached attempt answers with an error code | — | recorded by `keptRead`, nothing parked | T12 |
| Detached attempt: no response / refused / exception | — | nothing recorded; the round's own attempt follows | T12 |
| Detached body, node already has a kept link or no room | — | recorded, session destroyed | T13 |
| Back to home / other page while detached | — | aborted at once | T10 |
| Background / screen off while detached | cancelled | aborted at once | T7 |
| Bluetooth off / permission / keys while detached | cancelled | aborted at once | T8 |
| Record removed while detached | result dropped | aborted at the next `_pump`; else not taken by `keptRead`, destroyed | T9 |
| Round cap / `refresh` / early → full with an attempt in flight on the node page | abort | abort (not detached: only `setPage` detaches) | T14 |
| Node page connecting → sub-page (session lease) | cancel + login from start | wait, parked link lent, one connect | T3 (device D2) |
| Same, attempt fails | — | lease given when it ends; own login | T5 |
| Same, attempt silent after connect | — | 8 s, `_abort()`, own login | T6 |
| Same, attempt in `_makeRoom` | abort | abort, no wait | T6b |
| Second `acquire` during the wait (Wi-Fi → back → 國家) | — | the first returns null → `OpEnd.gone`; the second gets the lease | T15, O1 |
| Page closed during the wait, no second call | — | lease obtained, released at once (`OpEnd.gone`) | O2 |
| Background / Bluetooth off / page left during the wait | — | attempt aborted → wait ends at once → today's path (login ends as today) | T7b, T8b |
| Raw lease; session lease from another page | abort | abort | T4 |
| A lease is held (update, claim) | no round, no attempt | same: nothing to detach or wait for | existing lease tests |
| Two nodes, one unreachable | — | home round unchanged; the node page's round has one target | T1 |
| `dispose` | `_dropAll` | same (`_abort` clears `_det`, completes `_ended`) | T11 |
| Node reboot / link loss mid-attempt | attempt fails | same; a parked link that drops is closed by its listener | existing kept-link tests |
| App killed / phone reboot | all state gone | same; `SettingsMemo` gone | n/a: memory only |
| App upgrade / downgrade; node older / newer | — | no stored format, no wire change | n/a |
| iOS | none exists | n/a | n/a |
| Settings page, first opening / second opening / failed read / after a set / unclear set | 「讀取中…」 each time | W1–W6 | W1–W6 |
| Home: note on one node / several / stale node / with a power warning | yellow rule 12 | H1–H6 | H1–H6 |

## 5. Evidence for what the change relies on

| Assumption | Evidence |
|---|---|
| `core.keptRead` records a body or an error code for a target of the active round, returns false with no round | `core.dart:603–625` |
| `setPage(Page.node)` leaves a new round with that node as its only target | `core.dart:244–258` (X33), log `round N full […7d2c]` in the reproduction |
| `core.acquireLease` cancels the round (so the wait must come before it) | `core.dart:285–290`, `node_link.dart:360` |
| A parked link is not counted by `gate.active` and not closed by `revoked(token)` | `ble_gate.dart:195`, `:302–309` |
| `_loginFor` lends a parked link when the node's page is open | `node_link.dart:446–452` |
| Sub-pages leave `core.page == Page.node` for their node | they never call `setPage`; its only callers are `home_page.dart:208, 280, 288, 295, 340`, `net_pages.dart:203, 224`, `team_status_page.dart:62` (grep); #366 device runs show `loginFor … -> ok (kept link)` from 「手機 Wi-Fi」 |
| No new attempt or kept read starts while `_attempt != null` | `node_link.dart:911, 928` |
| After the probe, `_run`'s tail to `_park` is synchronous | `node_link.dart:1040–1056`, `_park` `:644` (one synchronous step) |
| `_abort` is the only place that ends an attempt from outside | `node_link.dart:1060–1069`; called from `_pump:900`, `acquire:369`, `_dropAll` |
| An attempt's limits: `_makeRoom` ≤ 6 s before the connect; 8 s connect → msg2; then the prober's answer limits | `node_link.dart:716–735`, `prober.dart:129–132, 233` |
| An attempt left alone usually ends in 1.5–4.5 s | reproduction log |
| A settings page fills its field only when it is empty, from its own read | `settings_pages.dart:133` |
| The node never sends the passphrase in `settings` | `owner.dart:570`, 254-p3-impl §3.3 |
| Nothing outside the app reads the warning text | grep of the repository for 「節點回報異常」: `statuspage.rs`, `tests/statuspage.rs`, `254-app-status-page.md`, `329-honest-errors.md` only |
| `OpEnd.busy` prints `reg.current?.name ?? ''` | `settings_pages.dart:27, 41` (why a superseded waiter must not end as busy) |

## 6. Security

- Assets: the node's owner session, the AP passphrase, what the screen claims about a node.
- Attack-surface delta: no new input, port, file or message.
- Nearby device replaying a node's address: the link taken over is made by the same authenticated login
  (`prober.probe` for `a.id`) as every kept link; a failed login parks and records nothing (T12). Its effect is the
  bounded delay in 1.1's cost.
- Compromised node: it can already answer its own status; note / warning are constants chosen by the app; a memo
  value is its own `SettingsView` and is only printed as a label on its own pages.
- Second phone: it can change the AP name; this phone then shows the old name marked 「確認中」 / 「上次讀到」 and never
  sends it (the field is not prefilled, W5).
- Our mistakes: `_det` by identity, `_ended` in a `finally`, the 8 s timer and the generation counter each have a
  test that fails without them (T6, T7b, T15, T16).
- A lease holder gets a link only through `_loginFor`'s existing checks. The wait gives no lease earlier than today.
- `SettingsMemo`: memory only, never logged, no passphrase; it cannot enable a change.
- Failure mode: every non-success path closes the link and records nothing. Stated cost of 1.3 in 1.3.

## 7. Tests (each new test is run against main, or against the change with its condition removed, and must fail there)

NodeLink (`test/nodelink`, fake gate / prober):
T1 enter the node page mid-attempt (connected): one connect, body in the new round, `_noteRead`, parked; a second
node unreachable in the home round changes nothing. T1b the same in `_makeRoom`: aborted. T2 other node's page:
aborted. T3 session `acquire` on the node's page mid-attempt: returns after the attempt, state recorded,
`loginFor` gives the kept link, one connect (negative control: wait placed after `core.acquireLease` → nothing
recorded, second connect). T4 raw lease / other page: aborted, no wait. T5 attempt fails: lease given at its end.
T6 silent after connect: lease after 8 s, attempt aborted. T6b in `_makeRoom`: no wait. T7 background while
detached; T7b during the wait: wait ends within one tick. T8 / T8b radio blocked, the same two. T9 record gone.
T10 back to home. T11 dispose. T12 detached error code: recorded, not parked; no response / cert rejected:
nothing recorded, the round attempts. T13 detached body with a kept link present / no room: recorded, destroyed.
T14 cap / `refresh` on the node page: aborted. T15 second `acquire` during the wait: first null, second the lease.
T16 after a detached attempt was aborted, the next ordinary attempt's result goes through `core.result` (the round
ends normally; fails if `_det` is a flag that is not cleared).

OpSession: O1 null lease with `gone()` → `OpEnd.gone`; O2 lease with `gone()` → released, `OpEnd.gone`, no login.

Widgets: W1 Wi-Fi page with a memo: the name with 「（確認中…）」 at once, then the read value; W2 failed read:
「上次讀到」; W3 country shown from the memo, menu disabled until the page's read; W4 `put` after a read and after a
confirmed set, `drop` before a set (unclear set → no entry); W5 with a memo and a failed read the name field is
empty and sending is disabled; with a memo and a read that returns another name the field has the read name;
W6 no memo: 「讀取中…」 as today.

Verdict / home: R1 Rust: joined + `k2 = 2` → `warning` none, `note` set, text equal to the old constant; with the
power bit → `warning` power, `note` none. The pinned tests that change: `tests/statuspage.rs:305, 390`,
`rust/bridge/src/api/owner.rs:2792`, `test/ui/home_logic_test.dart:135, 172–174`; every `StatusView(` in the Dart
tests gets `note`. H1 one node with a note: rule 14, `Look.ok`, 「可以使用」, the reminder line, `seeNode`, and
neither 「一切正常」 nor 「現在沒有需要你處理的事」. H2 two nodes with notes: the count line, `showList`. H3 a power
warning: rule 12 as today. H4 row: `hint` set only for a fresh, joined node with a note (stale → empty). H5 node
page, leave page and status fields print the note where the warning was. H6 no note: rule 14 text as today.

Whole suite, `dart analyze`, `cargo test` (statuspage, bridge), a mutation for each changed condition.

Device (S20, 04 / 02, no node change): D1 = the reproduction's first step; D2 = `a2repro2.sh` (negative control:
the numbers in §0); D3 home with 02 in the joined-critical state (it is now): screenshot of home and of 02's page;
D4 「手機 Wi-Fi」 opened twice: timing from logcat only (secure page, no screen dump); what it shows is covered by
W1–W6 and goes on the on-site list for the user's eyes.

## 8. What this does not do

- The node still does not report the reason (#329, 誠實的錯誤訊息 leftovers).
- A kept link being read when a sub-page opens is still closed (1.1).
- An attempt still waiting for room when the page opens is cancelled as today (1.1).
- The node page's status area still changes height while connecting (#329 line 233 leftover).
- The first opening of a settings page in an app run still reads (1.2).
- Later work on the same code: A3 (records cleanup) touches `team_pages.dart` only; a node-side reason field would
  replace the note's text, not its place; nothing planned replaces 1.1.

## 9. Changes from v1 (reviews r1-A, r1-B)

| Finding | Change |
|---|---|
| A1, B11: home text contradicts the reminder; no action; several nodes; stale | 1.3: own rule-14 text and action, count form, fresh only; superseded lines named and edited |
| A2, B12, B13: readers and pinned tests missing; text change; note beside a warning | 1.3 table lists every reader; text unchanged; note only when there is no warning; §7 lists the tests that change |
| A3, B1, B2: wait after the round is cancelled; park condition; second acquire | 1.1 (b): wait before `core.acquireLease`; one waiter by generation; `OpSession.once` checks `gone()` |
| A4, B8: remembered name sent back | 1.2: label only, never in the field; `drop` before a set |
| A5, B5: completer only on success; flag inherited | `_ended` in `_abort` and a `finally`; `_det` by identity; T7b, T16 |
| A6, B3: 8 s is not the attempt's limit | own 8 s timer in `acquire`; only attempts whose connect started; limits stated from source |
| A7, B4: `_pump` detaches on cap / refresh | detach only in `setPage`; T14 |
| A8, B9: memo with three writers | one object, two callers, no pruning |
| A9: wrong facts (route observer, secure screen) | §5, 1.2 corrected |
| B6, B7: error code / no keep; lease held | 1.1 (a) results, matrix rows |
| B10: is the memo needed | kept, as a label, with the reason in 1.2 |
