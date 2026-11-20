# #329 A2 — take over the connection in progress; known values first; the "joined but critical" line leaves home's hero

Status: v4, for review (reviews so far: `329-reviews/review-takeover-r1-A.md`, `-r1-B.md`, `-r2-A.md`, `-r2-B.md`, `-r3-A.md`, `-r3-B.md`; what changed is in §9). App only
(Dart + the status verdict in `batman-proto` + one bridge field). No node, firmware or harness change.

Baseline (reviewed, not re-reviewed here): `329-link-per-node.md` (#366: one kept link per node, lend / park /
give back, gate rules), `329-ux-speed-plan.md` §4, `329-honest-errors.md` (#367), `254-app-status-page.md`.
Everything below is a change against main 99d156a. §1.3 **supersedes** two reviewed lines on the user's request
(2026-11-20); they are named there and edited in the same PR.

## 0. What the user sees today (reproduced, phone S20, main-equivalent APK, 2026-11-20)

Evidence: `Desktop\Batman\a1\a2-step1-2026-11-20.logcat` (script `a2step1.sh`: background 8 s → launch → tap 04 after
1.0–3.5 s; phone clock 12:22–12:25) and `Desktop\Batman\a1\a2-repro-2026-11-20.logcat` (script `a2repro2.sh`: the same,
then 「手機 Wi-Fi」 0.7 s later; 11:45–11:49).

| Step | Seen |
|---|---|
| Home → node page of 04 while the home round's attempt to 04 is in flight | 3 of 3 such taps in the file: the attempt is cancelled 0.7 s / 1.7 s / 2.2 s after it started (`attempt …9B×…7d2c connected=-1ms result=noResponse after 736ms` at 12:21:13.530, `1696ms` at 12:23:00.864, `2201ms` at 12:23:37.418, each with `round N full […7d2c]` and a second `connect()` to the same device); body 4.5 s / 4.0 s / 4.8 s after the tap. Attempts left alone in the same log take 2.9–4.8 s from start to body (11 lines `result=body after …ms`: 2907–4802), so about 1–2.5 s were left in the last two (inferred, not measured). Three other taps fell while the attempt in flight was to 02 (12:21:48, 12:22:24, 12:24:14): not this case, unchanged by this design. |
| Node page still connecting → 「手機 Wi-Fi」 | 4 taps. In 3 an attempt to 04 was in flight: it is cancelled and the sub-page logs in from the start: 3.5 s, 6.1 s, 4.0 s until logged in. In the fourth (25.7 s) the attempt in flight was to 02 (`11:47:27.135 attempt …5A×…880c connected=1633ms result=noResponse after 2163ms`), the first connect to 04 came 12 s later (11:47:40.775) and the first login got no response: **not this case, not improved by this design** (§8). Neither capture has a `kept link` line; with a parked kept link (#366) the same step logged in 0.1 s (PR #366 body, test results, D3). |
| Home, 02 joined but `k2 = 2` | The yellow hero: 「02：節點回報異常，可能是手機 Wi-Fi 還沒設定 — …」 while 02's row is green (user, 2026-11-20: a reminder that belongs in the node; on home it alarms). |
| 「手機 Wi-Fi」 / 「國家」 opened a second time | 「讀取中…」 again, although the app read the same value a moment ago (user, same message). |

Causes, from source:
- `core.setPage` (`core.dart:244`) cancels the round on any change but home ↔ team and starts a new one for the node
  page; `NodeLink._pump` (`node_link.dart:900`) aborts the attempt the core no longer owns.
- `NodeLink.acquire` (`node_link.dart:352`) cancels the round (`core.acquireLease`, :360) and calls `_abort()` (:369)
  before the lease is given; `_loginFor` lends a kept link only if one is already parked (`node_link.dart:446`).
- `home_logic.dart:155`: any non-empty `warning` makes the hero yellow; `statuspage.rs:333` returns
  `WARN_JOINED_CRIT` as a warning.
- The status read carries neither the AP name nor the country (`StatusView`, `owner.dart:616`; its `warning` `:630`); they come from
  `settings/get`, which only the two sub-pages send (`settings_pages.dart:126, 295`), and nothing remembers the answer.

## 1. Changes

### 1.1 The attempt in flight is taken over, not cancelled (NodeLink only; the core is not changed)

Two places, and only these two. Every other way an attempt loses its round (another page, background, radio
blocked, any other lease; cap, `refresh` and early → full for an attempt that is not detached) aborts it as today.

**New NodeLink state**
- `_det`: the attempt that was detached (`Attempt?`). Used only as `identical(_det, _attempt)`. Cleared in `_abort`
  and, when an attempt's `_run` ends, only `if (identical(_det, a))`: a late end of an aborted attempt cannot clear
  the next one's mark.
- A completer **per attempt**, made at the top of `_run` as a local `ended` and also held in the field `_ended` (as
  `_cancel` is today, `node_link.dart:996`). Completed at most once (`isCompleted` checked): by `_abort` through the
  field, and by `_run`. Order at `_run`'s end, written out: complete `ended` → null the field `if
  (identical(_ended, ended))` → then the tail `_pump()` (`:1057`). A `finally` around the body completes it on the
  early returns (`:999`, `:1038`, which do not pump) and on an exception; it is the backstop, not the ordering. A
  completer's listeners run as microtasks, so the waiter always resumes after `_run`'s synchronous tail; it then
  runs today's lease path, which aborts whatever the pump started (as today's `acquire` does).
- `_waiter`: the one `acquire` call that is waiting (its name, its `gone`), or null. `dispose` clears it.

    wanted(a) = _onPage(a.id) && core.blocked == null && core.states.containsKey(a.id)
    (_onPage = core.fg && core.page == Page.node && core.pageNode == id, node_link.dart:639)

**(a) Entering the node's page.** `NodeLink.setPage` (`node_link.dart:303`): with `a = _attempt` taken before
`core.setPage`, after it: if `a` is still `_attempt`, the core no longer runs it, its connect has started
(`_link != null`, set at `gate.connect`, `:1008`) and `wanted(a)` → `_det = a`. `_pump` line 900 becomes, in full:

    if (a != null && !identical(core.running, a) && !(identical(_det, a) && wanted(a))) _abort();

So a detached attempt is aborted the moment the page is left, the app goes to the background, the radio is blocked
or the record goes. While `_attempt != null` nothing else starts (`node_link.dart:911, 928`, unchanged). A lease
other than (b) aborts it (`acquire` → `_abort()`, unchanged).

A detached attempt is tied to the page, not to one round. `refresh`, early → full or a new round on the same node
page do not abort it (it is still `_det` and wanted); its answer goes to the round that is active when it ends
(below). If no round is active then (the page's round ended at its window while the attempt ran), it is not taken.

When a detached attempt ends in `_run` (the `core.result` branch is skipped; the core does not know the attempt):
- `Res.body` or `Res.errorCode`: `taken = core.keptRead(now, a.id, a.addr, o)`, the existing entry for "an answer
  without an attempt of this round" (`core.dart:603`); it records only when the active round has the node as a
  target and the record is there. `_noteRead` when taken and a body, as `_keptRead` does today.
- The open session (`Outcome.keep`), if any: parked when `taken`, `wanted(a)` and today's conditions hold
  (`core.blocked == null`, `core.fg`, no kept link for the node, `_kept.length < keptMax`); else destroyed. This is
  line 1051 with `taken` in the place of `accepted`.
- An error code: recorded (`t.err`, the error line on the page), nothing parked. `_candidates` stops only on a body
  or a reason (`core.dart:475`), so the round then makes its own attempts as if the detached one had not been: up
  to the round's usual number of logins, each of which can replace the recorded code. One login more than today.
- Anything else (`noResponse`, refused, exception): nothing recorded, link closed; the round then makes its own
  first attempt at once (the core never counted the detached one: no `freeAt` gap, no per-address count for it).
  One login more than today in that round. Both counts are asserted in T12.

Bound: a detached attempt keeps its own limits (8 s from its connect to msg2, then the prober's answer limits); it
is detached only after its connect started (no `_makeRoom` wait is taken over). `wanted(a)` does not ask whether a
round has the node as a target; it need not: a node page's round has that node as its only target (`core.dart:218,
258`), and with no such round `keptRead` takes nothing.

**(b) A settings-type session asked for the node whose page is open.** `NodeLink.acquire(name, kind, {String?
forNode, bool Function()? gone})`. `OpDeps.acquire` (`op_session.dart:68`) becomes `Future<Lease?> Function(String
name, {String? forNode, bool Function()? gone})`; `OpSession.once` (`:94`) passes its `id` and its `gone`,
`OpenSession.open` (`:150`) passes neither; `opDeps` (`settings_pages.dart:26`, the only maker of `OpDeps` in the
app) forwards them; the test rigs that build `OpDeps` follow the new signature. After the `_releasing` wait and
the first `reg.current` check and **before `core.acquireLease`**: if `forNode != null`, there is an attempt `a` (the
round's own or `_det`) with `a.id == forNode`, `_link != null` and `wanted(a)`:
- if `_waiter` is set and its `gone()` is false → return null (the caller prints busy; `busyName` falls back to the
  waiter's name, below). If its `gone()` is true → it is replaced: when it wakes it returns null.
- become `_waiter`; wait for `a`'s `ended`, at most 8 s on NodeLink's own timer (`after`, stopped on wake);
- on wake: if replaced, disposed or its own `gone()` is true → clear `_waiter` if it is still this call, return
  null (a closed page's call does not cancel the round or take a lease; `OpSession.once` ends as `OpEnd.gone`).
  Else clear `_waiter`, then **today's code unchanged** from the `reg.current` check (repeated) on:
  `core.acquireLease`, closing `reading` kept links, `_abort()`, `_dropAll()`, `reg.acquire`, `gate.revoked(mine)`.
  No second wait: if the attempt ended without a body and the round has already started another, that one is
  aborted as today.

What this gives:
- The round is still there during the wait, so a round's own attempt ends by the unchanged path (`core.result`,
  park at :1051) and a detached one by (a). No third path.
- The parked link has gate token null, so `_dropAll`'s wait and the revoke do not touch it (`ble_gate.dart:195,
  302–309`); `_loginFor` lends it (`node_link.dart:446`, unchanged).
- `OpSession.once` (`op_session.dart:94`): a null lease with `gone()` true is `OpEnd.gone`; a lease obtained with
  `gone()` true is released at once (`OpEnd.gone`; only the no-wait path can still give one). So 「手機 Wi-Fi」 →
  back → 「國家」 inside the wait gives the lease to 「國家」 and the closed page shows nothing.
- `OpDeps.busyName` (`settings_pages.dart:27`, its only definition) becomes `a.reg.current?.name ??
  a.link.waitingName ?? ''`, so a live page refused during a wait names the waiting operation, never an empty name.
  (`team_deps.dart:25` is `OfflineDeps`, which never waits: unchanged.)
- The wait ends early whenever the attempt ends or is aborted (page left, background, Bluetooth off, `dispose`:
  `_pump` / `_dropAll` → `_abort` → `ended`).
- Every `once` caller already has its page (or its progress line) on screen before `once` runs, so the wait shows as
  that page's own 「讀取中…」 / progress, as the login does today.

**Who waits**: a `once` whose `forNode` is the node of the open node page, with an attempt to it past its connect
start. That is the two settings pages and the node page's other `once` flows (`more_pages.dart:258`,
`dev_pages.dart:183, 274`, `rekey_send.dart:112, 139`, `join_pages.dart:117, 721` when they run for the node whose
page is under them: they do not call `setPage`). Each shows its progress line first and then gets the kept link as
the settings pages do.

**Who does not wait** (today's `_abort()` path, byte for byte): every caller that passes no `forNode` —
`OpenSession.open` (「軟體更新」: it asks for the lease before its page is pushed, `update_route.dart:28`, so a wait
would be a dead tap), 「移除節點」 (`more_pages.dart:84`), `OfflineOp.run` (`offline_op.dart:118`), the net pages
(`net_pages.dart:271, 342, 917`), dev forget-join (`dev_pages.dart:459`), raw leases (`raw_use.dart:74, 88`) — and a
`once` whose `forNode` is not the open page's node (the remove flow reading other nodes, `remove_pages.dart:102`)
or whose attempt is still in `_makeRoom`.

Not changed: what a round reads, the core, the lend / give-back rules, the gate, `keptMax`, `keepFor`, the 60 s
login budget (it starts after `acquire`, as today).

Cost: when the attempt taken over does not end with a body, the sub-page's own login starts later than today by the
time waited, at most 8 s. A device that answers on a node's old address without being the node costs one connect
more per entry to that node's page and each sub-page opening up to those 8 s; nothing is parked, recorded or shown
from it. When the attempt succeeds the step is its remaining time plus the kept-link login (0.1 s in the #366
run) in place of the 3.5–6.1 s of §0.

Not handled (listed in #329): a kept link in state `reading` is still closed by `acquire` (about 0.35 s per round;
not reproduced); a sub-page tapped while the attempt in flight is to another node, and the 12 s gap before a
connect seen in that run (§0, the 25.7 s case; inside the radio stack, cause unknown); 「軟體更新」 opened mid-connect
logs in from the start as today; an answer taken over carries no software-update hint, so the node page's update
card waits for the page's next read.

### 1.2 The settings sub-pages show the last value read, as a label

`SettingsMemo`: node id → the last `SettingsView` with `read == true` that a settings page got in this app run. In
memory only. One object, a field of `AppLink` (`app_link.dart:80`); `opDeps` hands it to the pages as
`OpDeps.memo` (default: an empty one, so a test passes its own). Its only callers are the two settings pages.

- `put(id, view)` after a successful read and after a set whose answer was read back. `drop(id)` inside the
  `requests` callback of a set, after the page's own `notSent` check and on the line before the set request is
  sent (`c.setAp`, `settings_pages.dart:156`; the country set the same way): a login that fails or a value the
  page refuses keeps the entry (nothing was sent); a set whose answer is lost leaves no entry.
- 「手機 Wi-Fi」: while the page's own read runs, 「目前的名稱」 shows 「<名稱>（確認中…）」 in place of 「讀取中…」. **The
  text field is not prefilled from the memo**; it is filled only from the page's own read, as today (`:133`). If
  the read fails: today's failure line plus 「上次讀到：<名稱>」; the field stays as today.
- 「國家」: the shown country the same way. `_cc` (which enables the menu, `:307–314`) is set only by the page's own
  read, never from the memo.
- A label is shown only for a non-empty value (an empty name or country in the memo: 「讀取中…」 as today).
- Sending stays disabled while the page's read runs (unchanged).
- The memo holds what `SettingsView` holds: no passphrase (the node never sends one, `owner.dart:573–574`). The name is
  shown only on 「手機 Wi-Fi」 (inside `SecureScreen`, `:182`), the country only on 「國家」.
- An entry is used for nothing but these two labels. It can be old: the country changes when the node joins a
  network (`settings_pages.dart:326`), another phone can rename the AP, a node can be removed and claimed again in
  the same app run. In each case the label is marked 「確認中…」 or 「上次讀到」, is replaced by the page's read, and
  enables nothing. No pruning, no NodeLink dependency, no time shown.

Why it is still wanted after 1.1: the user asked that a value the app has already read is on screen at once
(2026-11-20). 1.1 makes the read short; the label covers that time and the case where the read fails. Premise
corrected from the first proposal: the home round does not read these values, so the first opening in an app run
still shows 「讀取中…」.

### 1.3 "Joined but critical" is a note of the node, not home's warning

Rust: `Verdict` gets `note: Option<&'static str>`. In `warning()` (first match: power, heat, AP, joined-critical)
the last branch moves out: `note` is `Some(NOTE_JOINED_CRIT)` exactly when `warning` would be `WARN_JOINED_CRIT`
today (so never together with a warning: one line per node, as today). The constant is renamed; **its text is
unchanged**. The bridge's `StatusView` gets `note: String` (generated code regenerated; no wire change).

Dart: one helper `lineOf(v) = v.warning.isNotEmpty ? v.warning : v.note`, and `nodeRowHint(n)` (below).
`nodeRowWords` and its three readers (`home_page.dart:414`, `node_page.dart:208`, `net_pages.dart:548`) are not
changed.

| Reader of `warning` today | After |
|---|---|
| Home hero rule 12 (`home_logic.dart:155, 158`) | reads `warning` only: the note does not make home yellow |
| Home hero rule 14 (`:171`) | no fresh node with a note: unchanged. Else: `HomeHero(14, Look.ok, '可以使用', next: …, action: …, node: …)` with, for one such node, `next` 「<名稱> 有一則提醒，點進去看。」 and `HomeAction.seeNode` with `node:` its id; for more, 「N 台節點有提醒，點節點看。」 and `HomeAction.showList`. Neither 「一切正常」 nor 「現在沒有需要你處理的事」 is printed then. The hero's small word above stays `Look.ok`'s 「正常」 (`widgets.dart:31, 133`): home is normal, with a reminder. The variant has a button where 「一切正常」 has none; the steady hero already keeps the button's place (rule 10 「還沒讀到」 has one), and the variant is added to `home_steady_test` (H7). |
| Home node row | `nodeRowHint(n)`: 「有一則提醒」 when the node's read is fresh, it is in a network and its note is not empty; else empty (a stored view after an app restart is not fresh: no hint). `NodeRow` (`widgets.dart:162`) gets an optional `hint` (default empty: the other lists that use `NodeRow` are unchanged); home prints it as one small line under the row's sentence (one line, ellipsis). |
| Home tip card (`home_page.dart:361`, shown once on row 14) | unchanged: it can first appear on the variant with a reminder (its text is about the page, not the state) |
| Node page (`node_page.dart:213`) | `lineOf(v)`: the same place and style as today |
| Leave page and status fields (`more_pages.dart:192, 211, 313`; `member_ui.dart:186, 205`) | `lineOf(v)`: unchanged on screen |
| Bridge (`rust/bridge/src/api/owner.rs:461, 2579`) | fills `note` beside `warning`; the tuple assertion at `:2792` gets `note` |

`WARN_POWER`, `WARN_HOT`, `WARN_AP` (not joined) are unchanged and stay in home's hero.

Documents edited in this PR (reviewed lines superseded on the user's request):
- `254-app-status-page.md:28, 60, 73` (the ⚠️ line of this state on home): it stays on the node page, the leave
  page and the status fields; on home it is the row's small line and the hero's `next` line.
- `329-app-uiux.md:682` (rule 14's row: add the variant), `:716` and `:976` (they say 「一切正常」 of a home that may
  now be the variant).
- `329-honest-errors.md:14` (the F1 row: where the sentence is shown) and `:158` (a device-check note saying home
  cannot be green while 02 is in this state): no longer true; each gets a pointer to this design.

Cost (told to the user, agreed): the node gives only the level "critical", not the reason; critical battery or a
core service down give the same state (`329-honest-errors.md:29–41`). Until the node reports a reason, such a fault
shows on home as a green hero with 「<名稱> 有一則提醒」, not as yellow.

## 2. Ownership

| Resource | Owner (only writer) | Readers |
|---|---|---|
| `_attempt`, `_cancel`, `_link`, `_det`, `_ended`, `_waiter` | NodeLink (`setPage`, `_pump`, `_run`, `_abort`, `acquire`) | — |
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
| detached answer → round | `_run` → `core.keptRead` | body or error code; a round is active and has the node as a target; record present | false: nothing recorded, no read time, session destroyed. An error code is recorded and the round still makes its own attempts |
| detached session → kept link | `_run` → `_park` | taken, `wanted`, fg, not blocked, no kept link for the node, room | destroyed, link closed |
| an attempt's `ended` | `_run` (before its tail `_pump()`; `finally` as backstop), `_abort` → `acquire` | one per attempt, completed once | `acquire` has its own 8 s timer, then today's path (`_abort()`) |
| `_waiter` | `acquire`, `dispose` → `acquire`, `busyName` (`waitingName`) | while that call waits | a live waiter: the new call gets null and the waiter's name as busy name; a gone waiter is replaced; a waiter that wakes replaced, disposed or gone returns null |
| `acquire(forNode, gone)` | `OpSession.once` → `OpDeps.acquire` → NodeLink | optional | absent (`open`, every direct caller): no wait, today's path |
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
| Detached attempt answers with an error code | — | recorded by `keptRead`, nothing parked; the round's own attempts follow | T12 |
| Detached attempt: no response / refused / exception | — | nothing recorded; the round's own attempt follows | T12 |
| Detached body, node already has a kept link or no room | — | recorded, session destroyed | T13 |
| Back to home / other page while detached | — | aborted at once | T10 |
| Background / screen off while detached | cancelled | aborted at once | T7 |
| Bluetooth off / permission / keys while detached | cancelled | aborted at once | T8 |
| Record removed while detached | result dropped | aborted at the next `_pump`; else not taken by `keptRead`, destroyed | T9 |
| Round cap / `refresh` / early → full with the round's own attempt in flight on the node page | abort | abort (not detached: only `setPage` detaches) | T14 |
| `refresh` / early → full on the node page while a detached attempt runs | — | not aborted; its answer is recorded in the round active when it ends | T14b |
| The page's round ends at its window while a detached attempt runs | — | not taken: nothing recorded, session destroyed | T14c |
| Node page connecting → sub-page (session lease) | cancel + login from start | wait, parked link lent, one connect | T3 (device D2) |
| Same, attempt fails | — | lease given when it ends; own login | T5 |
| Same, attempt silent after connect | — | 8 s, `_abort()`, own login | T6 |
| Same, attempt in `_makeRoom` | abort | abort, no wait | T6b |
| Second `once` during the wait, first page gone (Wi-Fi → back → 國家) | — | the first returns null → `OpEnd.gone`; the second gets the lease | T15, O1 |
| Second `once` during the wait, first page alive | — | the second gets busy with the waiter's name; the first goes on | T15b, O3 |
| A caller without `forNode` mid-attempt on the node page (軟體更新, 移除節點, 隊員名單, net pages, raw) | abort, no wait | same | T4, O4 |
| `once` for another node than the open page (remove flow) | abort, no wait | same | T4 |
| Attempt A aborted, B started, A's `_run` ends late | A's link closed | same; B's `ended` and `_det` untouched | T17 |
| Attempt ends without a body during the wait and the round starts another | — | the lease path aborts it as today; no second wait | T5 |
| `dispose` during the wait | — | waiter returns null, `_waiter` cleared, timer stopped | T11b |
| Page closed during the wait, no second call | — | on wake the call returns null: no lease, the round is not cancelled (`OpEnd.gone`) | T15c, O1 |
| Page closed before a lease given without a wait | lease, login | lease released at once (`OpEnd.gone`) | O2 |
| Background / Bluetooth off / page left during the wait | — | attempt aborted → wait ends at once → today's path (login ends as today) | T7b, T8b |
| A lease is held (update, claim) | no round, no attempt | same: nothing to detach or wait for | existing lease tests |
| Two nodes, one unreachable | — | home round unchanged; the node page's round has one target | T1 |
| `dispose` | `_dropAll` | same (`_abort` clears `_det`, completes the attempt's `ended`) | T11 |
| Node reboot / link loss mid-attempt | attempt fails | same; a parked link that drops is closed by its listener | existing kept-link tests |
| App killed / phone reboot | all state gone | same; `SettingsMemo` gone | n/a: memory only |
| App upgrade / downgrade; node older / newer | — | no stored format, no wire change | n/a |
| iOS | none exists | n/a | n/a |
| Settings page, first opening / second opening / failed read / after a set / unclear set | 「讀取中…」 each time | W1–W6 | W1–W6 |
| Home: note on one node / several / stale node / after an app restart / with a power warning | yellow rule 12 | H1–H7 | H1–H7 |

## 5. Evidence for what the change relies on

| Assumption | Evidence |
|---|---|
| `core.keptRead` records a body or an error code for a target of the active round, returns false with no round | `core.dart:603–626` |
| An error code (`t.err`) does not stop the round's further candidates; a body or a reason does | `core.dart:472–480` |
| `_run`'s tail `_pump()` is its last statement; the early returns do not pump | `node_link.dart:1057`, `:999`, `:1038` |
| `setPage(Page.node)` leaves a new round with that node as its only target | `core.dart:218, 244–258` (X33), log `round N full […7d2c]` in the reproduction |
| `core.acquireLease` cancels the round (so the wait must come before it) | `core.dart:285–290`, `node_link.dart:360` |
| A parked link is not counted by `gate.active` and not closed by `revoked(token)` | `ble_gate.dart:195`, `:302–309` |
| `_loginFor` lends a parked link when the node's page is open | `node_link.dart:446–452` |
| Sub-pages leave `core.page == Page.node` for their node | they never call `setPage`; its only callers are `home_page.dart:208, 280, 288, 295, 340`, `net_pages.dart:203, 224`, `team_status_page.dart:62` (grep); #366 device runs show `loginFor … -> ok (kept link)` from 「手機 Wi-Fi」 |
| No new attempt or kept read starts while `_attempt != null` | `node_link.dart:911, 928` |
| After the probe, `_run`'s tail to `_park` is synchronous | `node_link.dart:1040–1056`, `_park` `:644` (one synchronous step) |
| `_abort` is the only place that ends an attempt from outside | `node_link.dart:1060–1069`; called from `_pump:900`, `acquire:369`, `_dropAll` |
| An attempt's limits: `_makeRoom` ≤ 6 s before the connect; 8 s connect → msg2; then the prober's answer limits | `node_link.dart:716–735`, `prober.dart:129–132, 233` |
| An attempt left alone takes 2.9–4.8 s from start to body | `a2-step1-2026-11-20.logcat` (11 `result=body after …ms` lines, 2907–4802) |
| `_link` is set when the connect starts, not when it is up | `node_link.dart:1008` |
| A login on a parked kept link takes about 0.1 s | PR #366 body, test results D3 |
| Every `once` caller has its page or progress on screen first; `open` does not | `settings_pages.dart:126, 148, 295, 340`, `dev_pages.dart:183, 274`, `more_pages.dart:258`, `join_pages.dart:117, 721`, `rekey_send.dart:112, 139`, `remove_pages.dart:102`; `update_route.dart:28–36` |
| All callers of `NodeLink.acquire` | grep: `op_session.dart:94, 150` (through `settings_pages.dart:26`; `team_deps.dart:23–25` builds `OfflineDeps`, not `OpDeps`), `offline_op.dart:118`, `raw_use.dart:74, 88`, `dev_pages.dart:459`, `more_pages.dart:84`, `net_pages.dart:271, 342, 917` |
| The hero prints the look's word above the text | `widgets.dart:30–36, 133` |
| 「國家」 is not inside `SecureScreen` (a dump of it is possible); 「手機 Wi-Fi」 is | `settings_pages.dart:290–380`, `:182` |
| A settings page fills its field only when it is empty, from its own read | `settings_pages.dart:133` |
| The node never sends the passphrase in `settings` | `owner.dart:573–574`, 254-p3-impl §3.3 |
| Nothing outside the app reads the warning text | grep of the repository for 「節點回報異常」: `statuspage.rs`, `tests/statuspage.rs`, `254-app-status-page.md`, `329-honest-errors.md` only |
| `OpEnd.busy` prints `busyName()`, today `reg.current?.name ?? ''` | `settings_pages.dart:27, 41` (why a call refused during a wait needs the waiter's name) |

## 6. Security

- Assets: the node's owner session, the AP passphrase, what the screen claims about a node.
- Attack-surface delta: no new input, port, file or message.
- Nearby device replaying a node's address: the link taken over is made by the same authenticated login
  (`prober.probe` for `a.id`) as every kept link; a failed login parks and records nothing (T12). Its effect is the
  bounded delay in 1.1's cost: one connect more per entry to the node's page and up to 8 s per sub-page opening,
  for as long as that device is in range.
- Compromised node: it can already answer its own status; note / warning are constants chosen by the app; a memo
  value is its own `SettingsView` and is only printed as a label on its own pages.
- Second phone: it can change the AP name; this phone then shows the old name marked 「確認中」 / 「上次讀到」 and never
  sends it (the field is not prefilled, W5).
- Our mistakes: `_det` by identity, the per-attempt completer in a `finally`, the 8 s timer and the single waiter
  each have a test that fails without them (T6, T7b, T15, T16, T17).
- A lease holder gets a link only through `_loginFor`'s existing checks. The wait gives no lease earlier than today.
- `SettingsMemo`: memory only, never logged, no passphrase; it cannot enable a change.
- Failure mode: every non-success path closes the link and records nothing. Stated cost of 1.3 in 1.3.

## 7. Tests (each new test is run against main, or against the change with its condition removed, and must fail there)

Tests that pass on main because they pin "still aborted" name the mutation of the change that makes them fail.

NodeLink (`test/nodelink`, fake gate / prober):
T1 enter the node page mid-attempt (connect started): one connect, body in the new round, `_noteRead`, parked; a
second node unreachable in the home round changes nothing. T1b the same in `_makeRoom`: aborted [mutation: detach
without `_link != null`]. T2 other node's page: aborted [mutation: detach without `wanted`]. T3 `acquire(forNode)`
on the node's page mid-attempt: returns after the attempt, state recorded, `loginFor` gives the kept link, one
connect (negative control: wait placed after `core.acquireLease` → nothing recorded, second connect). T4 no wait
and the attempt aborted for: no `forNode` (session and raw), `forNode` of another node, another page open
[mutation: wait without the `a.id == forNode` test]. T5 attempt fails during the wait: lease given at its end; a
new attempt the round started meanwhile is aborted, no second wait. T6 silent after connect: lease after 8 s,
attempt aborted. T6b in `_makeRoom`: no wait [mutation: wait without `_link != null`]. T7 background while
detached; T7b during the wait: wait ends within one tick. T8 / T8b radio blocked, the same two. T9 record gone
while detached: aborted at the next pump (defensive: the app has no way to remove a node from its own page while
an attempt runs). T10 back to home. T11 dispose while detached; T11b dispose during the wait: null, no timer left,
no waiter left (`waitingName` null). T12 detached error code: recorded, not parked, then the round's own logins
(their number asserted, equal to a round without the detached attempt); detached no response / cert rejected:
nothing recorded, the round's own attempt starts at once (one extra attempt, asserted). T13 detached body with a
kept link present / no room: recorded, destroyed. T14 cap / `refresh` / early → full with the round's own attempt
on the node page: aborted [mutation: line 900 with `wanted(a)` in place of `identical(_det, a) && wanted(a)`].
T14b `refresh` on the node page while a detached attempt runs: not aborted, one connect, its body recorded in the
new round, parked. T14c the page's round ended before a detached attempt answers: nothing recorded, session
destroyed. T15 second `acquire(forNode)` during the wait with the first `gone`: first null, second the lease.
T15b first not gone: second null, `waitingName` is the first's name, the first gets the lease. T15c the only
waiter's `gone` turns true during the wait: on wake null, the round is not cancelled, no lease taken or released,
`waitingName` null (fails if the wake path does not ask `gone()`). T16 after a detached attempt was aborted, the
next ordinary attempt's result goes through `core.result` (fails if `_det` is a flag that is not cleared). T17
attempt A aborted while its probe is pending, attempt B started and detached, then A's `_run` ends: B is still
detached, a waiter on B is still waiting, no exception (fails with one shared completer or an unconditional clear).
T18 a waiter on the round's own attempt that ends with a body: when `acquire` goes on, the state is recorded and
the link parked (fails if `ended` is completed only after the tail pump has started the next attempt and that
attempt is what `acquire` aborts — asserted by: exactly one connect, none aborted).

OpSession: O1 null lease with `gone()` → `OpEnd.gone`; O2 lease with `gone()` → released, `OpEnd.gone`, no login;
O3 null lease, page alive → busy with a non-empty name; O4 `OpenSession.open` passes no `forNode`, `once` passes
its id and its `gone`.

Widgets: W1 Wi-Fi page with a memo: the name with 「（確認中…）」 at once, then the read value; W2 failed read:
「上次讀到」; W3 country shown from the memo, menu disabled until the page's read; W4 `put` after a read and after a
confirmed set; set with a failed login → entry kept; set the page refuses (`notSent`) → entry kept; set whose
answer is lost → entry gone; W5 with a memo and a failed read the name field is empty and sending is disabled;
with a memo and a read that returns another name the field has the read name; W6 no memo, or an empty value in it:
「讀取中…」 as today.

Verdict / home: R1 Rust: joined + `k2 = 2` → `warning` none, `note` set, text equal to the old constant; with the
power bit → `warning` power, `note` none. `tests/statuspage.rs:305–307, 390` change (they pin the old place of the
text); the bridge test at `owner.rs:2792` asserts `note` beside `warning`. Every `StatusView(` in the Dart tests
gets `note`. H1 one node with a note: rule 14, `Look.ok`, 「可以使用」, the reminder line, `seeNode` with that
node's id, and neither 「一切正常」 nor 「現在沒有需要你處理的事」. H2 two nodes with notes: the count line,
`showList`. H3 a power warning: rule 12 as today. H4 `nodeRowHint`: set only for a fresh, joined node with a note;
a stale node and a stored view after a restart (not fresh) → empty. H5 node page, leave page and status fields
print the note where the warning was. H6 no note: rule 14 text as today. H7 layout: home with the variant and the
row hint at text scale 1.0 / 1.3 / 2.0 and a 32-character node name: no overflow (the existing layout test's
method); in `home_steady_test` the variant's 「我的節點」 is at the y of 「還沒讀到」 (the state that already has a
button).

Whole suite, `dart analyze`, `cargo test` (statuspage, bridge), a mutation for each changed condition.

Device (S20, 04 / 02, no node change; taps: node card, sub-page entry, Back). For every scripted run the PR lists
**every** tap with its time and which attempt was in flight, counted or not.
- D1 `a2step1.sh`, at least 6 launches. Counted: taps where the attempt in flight is to 04. Pass: in each, no
  second `connect()` to 04 between the tap and the body, one `attempt …7d2c … result=body`, and the next round logs
  `kept …7d2c`. At least 2 counted taps, else repeat. Negative control: §0 row 1 (3 of 3 cancelled).
- D2 `a2repro2.sh`. Counted the same way at the 「手機 Wi-Fi」 tap. Pass: `loginFor …7d2c -> ok (kept link)`, one
  `connect()`, logged in no later than 1 s after the attempt's end. At least 2 counted. Negative control: §0 row 2
  (3 of 3 logged in from the start, no `kept link` line).
- D3 home with 02 joined-critical (it is now): screenshot of home (green, 「可以使用」, the reminder line, 02's row
  hint) and of 02's page (the full text). Negative control: `Desktop\Batman\a1\a1-home-c1.png` (main: the yellow
  hero with the sentence).
- D4 「手機 Wi-Fi」 opened twice: time to logged in from logcat only (secure page: no screenshot, no dump).
- D5 mid-connect: 「手機 Wi-Fi」 → Back → 「國家」 within 1 s. Counted as D2, at least 2. Pass: 「國家」 reads; its dump
  has no 「另一個操作還在進行」; the log has one lease for 「國家」 and none for 「手機 Wi-Fi」. This is new code with no
  failing state on main to flip: the negative controls are T15 / T15c with their mutations; the same script is run
  on the main APK first and what main shows is reported as the baseline.
- D6 mid-connect: 「手機 Wi-Fi」 → app to the background 8 s → back. Pass, from logcat (secure page): within 40 s of
  the return a round for 04 ends (`result=body` or a failure line) and the page's `loginFor` has ended; a tap on
  Back then shows the node page. Baseline on main reported the same way; negative control T7b.
- D7 (the label, scope item 2; 「國家」 is not a secure page): 「國家」 opened and read once, Back, home, background
  8 s, launch, 04's card, 「國家」 at once, `uiautomator dump` while the read runs. Pass: the dump has
  「<國家>（確認中…）」 and no 「讀取中…」; a later dump has the read value. Negative control: the same steps on the
  main APK before the new one is installed: 「讀取中…」. If no dump lands inside the read in 3 tries, reported as
  not shown on the device (W3 only). Never done on 「手機 Wi-Fi」.
- On-site list (cannot be done remotely or by a secure-page dump): what 「手機 Wi-Fi」 shows the second time (W1–W6
  cover it); a node out of range while its page opens; Bluetooth off during the wait.

## 8. What this does not do

- The node still does not report the reason (#329, 誠實的錯誤訊息 leftovers).
- A kept link being read when a sub-page opens is still closed (1.1).
- A sub-page tapped while the attempt in flight is to another node logs in from the start as today; the 25.7 s
  case of §0 is of this kind and is not improved (1.1, #329 leftover).
- An attempt still waiting for room when the page opens is cancelled as today (1.1).
- 「軟體更新」 and every operation other than a settings-type session for the open node behave as today (1.1).
- The node page's status area still changes height while connecting (#329 line 233 leftover).
- The first opening of a settings page in an app run still reads (1.2).
- Later work on the same code: A3 (records cleanup) touches `team_pages.dart` only; a node-side reason field would
  replace the note's text, not its place; nothing planned replaces 1.1.

## 9. Changes from v1 (reviews r1-A, r1-B)

| Finding | Change |
|---|---|
| A1, B11: home text contradicts the reminder; no action; several nodes; stale | 1.3: own rule-14 text and action, count form, fresh only; superseded lines named and edited |
| A2, B12, B13: readers and pinned tests missing; text change; note beside a warning | 1.3 table lists every reader; text unchanged; note only when there is no warning; §7 lists the tests that change |
| A3, B1, B2: wait after the round is cancelled; park condition; second acquire | 1.1 (b): wait before `core.acquireLease`; one waiter (v3: `_waiter`); `OpSession.once` checks `gone()` |
| A4, B8: remembered name sent back | 1.2: label only, never in the field; `drop` before a set |
| A5, B5: completer only on success; flag inherited | `_ended` in `_abort` and a `finally`; `_det` by identity; T7b, T16 |
| A6, B3: 8 s is not the attempt's limit | own 8 s timer in `acquire`; only attempts whose connect started; limits stated from source |
| A7, B4: `_pump` detaches on cap / refresh | detach only in `setPage`; T14 |
| A8, B9: memo with three writers | one object, two callers, no pruning |
| A9: wrong facts (route observer, secure screen) | §5, 1.2 corrected |
| B6, B7: error code / no keep; lease held | 1.1 (a) results, matrix rows |
| B10: is the memo needed | kept, as a label, with the reason in 1.2 |

Round 2 (r2-A, r2-B) → v3:

| Finding | Change |
|---|---|
| A-M1, B-M1: the wait hit callers that never log in to the node; 「軟體更新」 a dead tap | the wait only for `acquire(forNode)` = `OpSession.once` on the open node; everyone else as today; list in 1.1, T4, O4 |
| A-M2, B-M1: superseded / refused caller prints busy with an empty name | `_waiter` with `gone` in place of the counter: a live waiter keeps its place, the refused call gets its name; a gone waiter is replaced; T15, T15b, O3 |
| B-M2, A-4: shared completer / mark across overlapping attempts; completion after the pump | per-attempt completer, guarded; `_det` cleared by identity; completed before `_pump`; T17 |
| B-3: §0 quote not in the cited capture | step 1 captured again (`a2-step1-2026-11-20.logcat`), §0 rewritten from it |
| B-4: device checks without criteria | D1–D6 with counts and pass conditions |
| A-3, B-7: detached result outside the core's counting; error code; second attempt during the wait | stated in 1.1; T5, T12 |
| A-5: dispose / timer during the wait | 1.1 (b), T11b |
| A-6, B-5: readers, documents, tests, the word 「正常」, layout | `nodeRowHint` in place of a fourth tuple value; documents listed; test list corrected; H7 |
| A-7, B-6: where `drop` sits; empty values; old entries | 1.2 |
| A-8: wrong cite; `wanted` and the round's target | §5, 1.1 bound |

Round 3 (r3-A: 0 MAJOR; r3-B: 2 MAJOR) → v4. The mechanism of 1.1–1.3 is as in v3; the changes are evidence, device
criteria and things v3 left unstated.

| Finding | Change |
|---|---|
| B-M1: §0 row 2 counted a run that is not this case; "0.1 s" not in the cited captures; row 1 count and range | §0 rewritten from the files (3 of 3; 3 of 4, the fourth named as not improved; 2.9–4.8 s); 0.1 s cited from PR #366; cost line 3.5–6.1 s; D1 / D2 list every tap |
| B-M2: no device criterion for the labels; D3–D6 without negative controls or limits | D7 (「國家」 dump, main as negative control); D3 negative control; D5 counted, baseline on main; D6 40 s limit |
| A-m1: "error code: no retry in that round" is wrong | 1.1 (a), §3, T12: the round's own attempts follow, counts asserted |
| A-m2, B-m1: a gone waiter went on to cancel the round and take a lease | on wake `gone()` → null; T15c |
| A-m3, B-m5: `finally` vs "before `_pump()`" | order written out; `finally` is the backstop; T18 |
| A-m4: line 900 condition incomplete | written in full |
| A-m5: `_waiter` on dispose | cleared; T11b |
| A-m6, B-m3, B-m4: `OpDeps.acquire` signature, `team_deps` is `OfflineDeps`, `NodeRow` parameter, where the memo lives | 1.1 (b), 1.2, 1.3 |
| A-m7, A-m8, B-m2: detached attempt meeting `refresh` / the round's end | 1.1 (a), matrix, T14b, T14c |
| A-m9: no update hint on an answer taken over | 1.1 Not handled |
| A-m10: `drop` and the `notSent` check | 1.2, W4 |
| A-m11: T9 unreachable; mutations for tests that pass on main; `seeNode` without `node:`; steady hero | §7 (mutations named, T9 marked defensive), 1.3, H1, H7 |
| B-m7: other `once` callers on the node page | 1.1 "Who waits" |
| B-m8: the variant's button and the steady hero | 1.3, H7 |
| B-m9, B-m10, B-m11: `owner.rs:2792`, `tests/statuspage.rs:307`, `329-honest-errors.md:14`, restart | 1.3, R1, H4 |
| A-m12, B-m3: cites | corrected (`:1008`, `statuspage.rs:333`, `owner.dart:616 / 630`, `:573–574`, `settings_pages.dart:326`, `core.dart:603–626`) |
| B-m12: cost of an address that answers without being the node | 1.1 cost, §6 |
