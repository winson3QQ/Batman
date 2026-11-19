# #329 UX speed: one kept link while a node's page is open (plan v5.1)

Refs #329 (issuecomment-6981729272). Reviews: v1 rejected (`329-reviews/review-ux-plan-v1-A.md`, `-B.md`); v2 APPROVE-WITH-CHANGES twice (`-v2-G.md` 5 MAJOR, `-v2-H.md` 6 MAJOR; H built a prototype outside the worktree: with a fake reader the whole suite passed, `+2090`, and T1–T3 failed on main); v3 APPROVE-WITH-CHANGES twice (`-v3-K.md` 3 MAJOR, read only; `-v3-L.md` 2 MAJOR, L built v3 as a prototype outside the worktree: base suite `+2080`, prototype `+2115` = 2080 existing + 35 new, no existing assertion changed); v4 APPROVE-WITH-CHANGES twice (`-v4-M.md` 2 MAJOR, `-v4-N.md` 1 MAJOR; both read only, nothing run). v5 keeps the design, puts one predicate back into the hook, and deletes six things the v4 reviews showed to be unneeded or unreachable: the 1.5 s wait in `acquire`, `keysOk` in the hook, the inbox check at lending, the round-targets row with `keptOnly`, the round check in `keptRead` with `roundId`, and the "forget" of a lent link on a page change, the background and link down. §10 lists the changes. v5 passed review twice with no BLOCKER and no MAJOR (`-v5-P.md` 8 MINOR, `-v5-Q.md` 13 MINOR; both read only); v5.1 folds those MINORs and adds no mechanism (§11). The node-side fix N1 is a separate plan (`329-n1-plan.md`); it ships before this plan's app change (§2, §7).

L's results are from a prototype of v3, not of v4, v5 or v5.1. In this plan "✅ L" means L ran it on that prototype; it is a lead, and every row and control is run again on the real implementation (§7 step 2). ⚠️ = read from source or inferred, not run. ❌ = not done.

The user (2026-11-18): every action on a node takes more than 2 s.

## 1. Facts (main 6760b78; app paths are under `app/lib/src/` unless they start with `ui/`, which is `app/lib/ui/`, or with `app/`; node paths under `feed/batman-prov/src/`)

| # | Fact | Evidence |
|---|---|---|
| F1 | One status read of 02 takes 4.1 s (another run 8.6 s). The work on an open session is 0.6 s; the rest is scan 0.75 s, connect 1.26–3.8 s, GATT 0.42 s, MTU 0.82 s, discovery 0.23 s. | ⚠️ one measurement, scratchpad `ux/m1.log` 22:31:47–22:31:51 (S20 + 02); the log goes into the PR. Not checked by K, L, M or N. |
| F2 | Every operation pays all of F1: `OpSession.once` takes the lease (`acquire`), logs in (`loginFor`), closes the console (which closes the link and the session) and releases. The Wi-Fi page does it twice (read on open, then send). | `flows/op_session.dart:89-131` (`acquire` at `:91`, login at `:104`); `flows/owner_console.dart:672-693`; `nodelink/handoff.dart:79-92` |
| F3 | Entering a node's page starts a read of that node at once; the read connects, logs in, reads, disposes the session and closes the link. | `nodelink/core.dart:218-232` (`setPage`; the read begins at `:232`); `nodelink/prober.dart:258-269` (cleanup); `nodelink/node_link.dart:632` (`await mine?.close()` in `_run`) |
| F4 | The gate allows one link in the whole app. A link's token is `final` and non-null; `revoked` / `released` find a link by `identical(l.token, t)`. A link has `open` only; "a down event was seen" (`_down`) is private. Its state stream is a broadcast stream: an event before a listener subscribes is lost. "Down" has two sources: the connect stream (`_on(false)`: emits `false` on `state`) and the backend's `linkStates` (calls only `_downNow()`: sets `_down`, emits nothing). `close()` on a link that is not open returns at once. | `nodelink/ble_gate.dart:62`, `:65-69`, `:74-84`, `:111-131`, `:137-149`, `:239-242`, `:252-266` |
| F5 | Taking a lease closes NodeLink's link: `acquire` refuses when a lease exists (`:260`), runs `core.acquireLease` (`:261`), then `_dropAll()` (`:262`; waits up to 5 s of **real** time, `Future.delayed`, for `gate.links == 0`), then `reg.acquire` (`:264`, which replaces the current token), then `gate.revoked(NodeLink's old token)` (`:267`). All of this is before `loginFor` is called. While a lease is held no round runs. After release a round starts 6 s later. | `node_link.dart:253-270`, `:664-675`; `lease.dart:131`, `:135-140`; `core.dart:196`, `:259`, `afterLease = 6000` (`:19`) |
| F6 | A round's result for `Res.body`: `isY`, `notY`, `t.body = true`, `s.extra`, `_read`; for `Res.errorCode`: `isY`, `t.err = true`, `s.errExtra`, a retry (a new connect in the same round). The driver then records `readWall` / `teams`. In `_run` the abort check (`:634`) is before `core.result` (`:639`). A new attempt starts only when `gate.links == 0` (`:533`). | `core.dart:469-492`; `node_link.dart:533`, `:632-649` |
| F7 | The pages pushed from a node's page (Wi-Fi, country, leave, send key, update, check network) leave `core.page == Page.node` with that node. The make / join network pages set `Page.home` and go back to the page they came from when they close. The team page sets `Page.team`; app settings sets `Page.other`. On `Page.node` a round's targets are `{pageNode}` or nothing; on `Page.home` / `Page.team` all records; on `Page.other` nothing. | `ui/home_page.dart:295` (node), `:208,280,288` (home), `:340` (other); `ui/net_pages.dart:203`, `:224`; `ui/team_status_page.dart:62` (team); `ui/team_hub.dart:51` (the `back:` that `net_pages.dart:224` returns to); `core.dart:190-194`. ✅ grep of `app/lib` for `setPage(` (v5; M and N found the same): these are all the calls; no page pushed from a node's page makes one. |
| F8 | The node ends an authenticated session after 300 s without a request and then disconnects. One session takes one of 2 slots; the node does not advertise while a phone is connected. A session answers at most one `status` request a second (`E_RATE`); the limit is per session, and the time is taken before the node's own `status.get` call, so a `status` request right after an `E_BUSY` answer gets `E_RATE`. | `provd/server.go:31` (`IdleAuthed`), `:35` (`Slots`); `cmd/batman-provd/bluez.go:772-776` (no advertising); `:412-418` (the disconnect call); `provd/session.go:868-879` |
| F9 | A console serves several requests on one session, one at a time; an unclear answer sets `_session = null`. `_close` sets `_closed = true` first, clears its inbox handler (`:680`), may wait up to 10 s for the step in progress, then sets `_session = null` (`:691`) and closes the handoff (`:692`). A frame that arrives with no handler set is held by the inbox and given to the next handler at once, when it is set. | `owner_console.dart:233`, `:368-397`, `:411-464`, `:675-693`; `nodelink/handoff.dart` (`FrameInbox.handle`) |
| F10 | `loginFor` first refuses with `noLease` when there is no login prober, NodeLink is disposed, a login is running or the lease is not the caller's (`:304`). Then `_loginFor` checks: `keysOk()` (a `Future`; when false it calls `radio(keyOk: false)`, `:323`), the lease is the caller's, `core.blocked == null`. | `node_link.dart:301-326` |
| F11 | The read prober's `Outcome.extra` already carries the `StatusView`; a handed-over login is recognised by `identical(o.extra, handed)` and skips the cleanup. A cancelled `probe` can still return the body it had read. | `prober.dart:163-166`, `:175`, `:256-257`; `:131` |
| F12 | The Rust session keeps state between requests: `after_left`, `page_status` / `page_info` / `page_fresh` / `page_rate`, `addr_pending`. One status-page read is **two requests**: `status`, then `info`. On `E_RATE` for the `status` request, when an earlier page exists, it keeps that page and sets `page_fresh = false`; a new session has no earlier page. | `app/rust/bridge/src/api/owner.rs:894` (`after_left`), `:949-972` (status, then info), `:953-956` (`E_RATE`), `:353`, `:1077-1083`, `:1383` (`addr_pending`) |
| F13 | `background()` today only cancels the round; a request under a lease is not cut when the page or the app goes (baseline test "B m3"). A login in flight is not cut either. | `node_link.dart:216-219`, `:315-377`; `app/test/flows/op_session_test.dart:207` |
| F14 | NodeLink gives the core a new record list at three call sites only: at start (`:200`), and twice inside `released`, after a lease release (`:505`, the usual one; `:499` when another lease was taken while the records were read, which needs the record read to outlast `acquire`'s 5 s wait for it, `:256-259`). | `node_link.dart:200`, `:499`, `:505`; `core.dart:268-289` |

## 2. Scope

From the field: the owner opens a node's page, looks at its status, then opens Wi-Fi / country / send key / leave and presses the button. Today that is one F1 for the page, one per sub-page read and one per send.

After: one F1 when the page opens (in the background, as today). Reads after that, and the first send, use the same link and session: about 0.6 s each. After a send that changes the node the link is closed (F12); the next read of the page reconnects in the background 6 s later, as today.

Handles: every `OpSession.once` / `OpenSession` user on the node whose page is open (all log in through `NodeLink.loginFor`).

Does not handle:
- The first read after opening the page (one F1). A2 (§4.8) may shorten it; measured first.
- A sub-page tapped **during** that first read (the 4–8 s after the page opens; probably the most common quick tap): `acquire` aborts the read (`core.acquireLease`, `_dropAll`; `node_link.dart:261-262`) and the operation logs in from the start. One F1, as today; the first read's work is thrown away. After that operation the link is kept (4.1 source 2). Timed once in the device pass.
- Home / team pages (many nodes through one link, one after another), the make / join network pages (`Page.home`, F7: the kept link is closed when they open). A read-only flow started from one of these pages, or from app settings, logs in and closes as today; its link is not kept (4.3).
- Older pages on a raw lease (claim, recovery, 我的節點).
- Node-side waits after a send.
- A sub-page opened in the moment a 60 s read is running (about 0.6 s in every 60 s, and once 6 s after each operation): the read is cancelled, the link closed, and that one operation reconnects, as today (§4.2).
- A sub-page tapped within about 6–16 s after a send (Q-m10): the send closed the link (not reusable); the round 6 s after the release reconnects (one F1). A tap in that time finds no kept link, or aborts that reconnect, and pays a full login, as today. "Change Wi-Fi, then open the country page" is such a sequence. No mechanism is added; §6 lists it as an accepted exception.
- The software-update page opened less than 1 s after a status read on the kept session: its entry read gets `E_RATE` and waits 1.5 s before it asks again (§4.4). That entry can take about 3 s. No mechanism is added for it; §6 states the criterion.

Cost: while the owner has a node's page open with the app in the foreground, that node does not advertise and one of its 2 slots is taken (F8); another phone cannot find it until the owner leaves the page or the app. No idle limit: this is how an ordinary Bluetooth device behaves while its app is open (the user's direction, 2026-11-18).

Cost when the phone goes silent with the page open (out of range, phone dead, app killed, and the node does not hear a disconnect). Today a session is up for a few seconds per operation; after this change one is up for as long as the page is open, so this becomes the common case (`329-n1-plan.md` §2 says the same). The numbers are the N1 plan's, ⚠️ read from the node's code there, not measured:
- node **with N1**: the session ends by its own limit (300 s without a request, F8), then N1 cuts the link that holds no session. The node is hidden for usually about 350 s, at worst about 650 s.
- node **without N1**: hidden until the session idles out, and after that for as long as BlueZ keeps the dead link, which can be until someone disconnects it on the node or reboots it (N1 plan F1: 04 was invisible for more than 39 min; its lifecycle row "link silent during a session", today: "dark until the session idles out, then forever").

**Dependency (decided): N1 ships before this plan's app change.** N1 = the node cuts a connected device that holds no session after 30 s; product branch `fix/329-n1` (commit 1f74d28), implemented and being validated under its own plan; ✅ it is not in this worktree's tree (`linkGrace` is not in `feed/batman-prov/src` at 6760b78). This plan's device checks run on an image with N1 (§6), and its PR is opened after N1 is merged and in the image the nodes run (§7 step 0). On a node still on an older image the app behaves the same and the cost is the "without N1" line above.

## 3. Reviewed baseline that changes (everything else stays)

| # | Baseline today | After |
|---|---|---|
| B1 | A link's token is fixed and non-null. | `GateLink.token` is nullable and no longer `final` (a private field with a getter; written only by `BleGate.pass`). Only NodeLink changes it, with `BleGate.pass`. A null token is refused by every GATT call. `GateLink` gets a getter `up`. |
| B2 | Every end of a read, a login or a console leaves no link. | One link may stay: the kept link (§4). |
| B3 | The read prober disposes its session. | A read of the open node page returns its session to NodeLink. |
| B4 | `LoginHandoff.close()` takes no argument. | `close({bool reusable = false})`. |
| B5 | `acquire` drops every link NodeLink has. | A session-lease `acquire` leaves a **parked** kept link open (`_dropAll` does not count it, §4.6). A kept link that is reading is dropped, as today (§4.2). |
| B6 | An error code from a read is retried by a new connect in the same round (F6). | An error code from a read **on the kept link** is not retried in that round (§4.4, with the reason). |

Unchanged: one link in the app; one lease; a lease holder's link dies when the lease is taken back; `loginFor`'s checks (F10) run on every login; a request under a lease is not cut by a page change or the background (F13); record writes; pages and texts (one condition in the leave page's re-read, §4.9, which cannot be met today); the node (this plan changes nothing on it; N1 is its own plan and ships first, §2).

## 4. Design

**The kept link** = one `LoginHandoff` (link, inbox, session, subscription) for one node id. Owner: NodeLink.

States: *parked* (token null; NodeLink listens to link state and inbox), *reading* (NodeLink's token; one status read), *lent* (the lease's token; from `loginFor` returning it until the holder closes it).

A link is parked only while the app is in the foreground and that node's page is open. One predicate says so, used at every park: **`onPage(id)`** = foreground, `core.page == Page.node`, `core.pageNode == id`.

**"Link up"** in this plan has one source: `GateLink.up` = `_open && !_down` (open, and no down seen from either source of F4). `BleGate.pass` refuses a link that is not `up` (§4.7). Every park, read and lending goes through `pass`, so there is no second check anywhere else.

**4.1 Sources.**
1. A round's read: `Outcome` gets a field `keep` (`Object?`, as `extra` and `team`: `core.dart` stays free of bridge types; NodeLink casts it to `LoginHandoff`). `SessionProber` (read mode) gets `bool Function(String id)? keepFor`, set by NodeLink's constructor when its prober is a `KeptReader` (§4.4), to "`onPage(id)` and no kept link". At the `answer` step, **after** the hint / team step (the outcome is replaced there by `withTeam`), when the outcome is `Res.body` and `keepFor(id)` is true, the prober builds a `LoginHandoff` (inbox handler cleared) and puts it in `keep` (`Outcome.withKeep(handoff)`, a copy of the outcome with the field set). The prober skips its cleanup **only** when the outcome it returns carries that `keep` (`identical(o.keep, handed)`, the F11 rule). A probe cancelled during the hint / team step has already completed with the stored read, which has no `keep` (`prober.dart:131`): the cleanup runs as today, so there is no "cleanup skipped, no `keep` returned" path (T19 e). "The attempt is not cancelled" is therefore not a separate check at the build (v5 had it; with the rule above it is redundant, §11). Any other end: cleanup as today.
   `keepFor` is a settable field of the `KeptReader` interface; NodeLink's constructor sets it.
   `_run` is the only receiver, and it has to change shape (F6: today it closes `mine` at `:632` in every case and returns at `:634` before `core.result`):
   - the outcome has no `keep` → `await mine?.close()` and the rest as today;
   - the outcome has a `keep` → `mine` is **not** closed at `:632`. Then, in this order: the attempt was aborted (the return at `:634`) → `keep.destroy()`, return; `core.result` returned false (a late result, the record went) → `keep.destroy()`; else park (below); the park failed (`pass` refused: the link is not `up`) → `keep.destroy()`. (v5 had one more branch, "`keepFor(id)` is no longer true → destroy". It cannot be reached: every change of page, page node or foreground cancels the round, so `_run` takes the abort return first, and nothing else can park while an attempt holds NodeLink's token. Deleted, §11.) On a park `_run` sets `_link = null`, so a later `_abort()` does not close the parked link.
   - `destroy()` = what `LoginHandoff.close()` does today, in today's order: inbox handler cleared, subscription cancelled, link closed (waits until gone), session disposed. `destroy()` and `close()` share the one-shot `_closed`: whichever is called first wins and the other returns at once. A handoff that carries a hook is torn down by NodeLink through a hook-less copy of it (`again()`), because its own `_closed` is already set when the hook runs.
   There is no path on which a returned `keep` is neither parked nor destroyed (T19). This matters more than for a parked link: an undestroyed `keep` still has NodeLink's token, so the gate's 120 s timer (4.5) does not cover it, and no attempt starts while `gate.links > 0` (F6).
2. A flow's login by the slow path that ends `ok`: lent from the start, on whatever page the flow runs. The `HandoffProber` makes the handoff; NodeLink returns a copy that carries its hook (`LoginHandoff.again(hook:)`, the same call that makes the new object for each lending in 4.2). Whether it is parked afterwards is decided by the hook at giving back (4.3), not here.

*Park* (the same steps for `_run` and for the hook), one synchronous step: NodeLink takes the handoff as its kept link, state parked; subscribes to the link's state if it has no subscription on this link yet; sets its own inbox handler (a frame or an error closes the kept link); then `gate.pass(link, null)`. A park that fails (below, or `pass` refused) leaves NodeLink with no reference, and the caller destroys the handoff.
- A frame the inbox was holding (F9) reaches the handler at once, inside this step. The handler closes the kept link (reference cleared at once, rule 1 of 4.5); the park sees that its reference is gone and fails without calling `pass`, and the caller's `destroy()` is a second close: a no-op (4.5). (v5 said "`pass` then refuses the closed link". `destroy()` closes the link only after its first `await`, as `close()` does today, so `pass` would not refuse yet; the park looks at its own reference instead. Same result, no new check of the inbox, §11.) There is no separate "inbox is empty" check (T7 b).
- The state subscription lives from the first park until the link is lent or closed; a park after a read does not add a second one. NodeLink's inbox handler is set while parked; a read sets its own for its two requests and the park after it sets NodeLink's again; at lending both are removed (the console has its own). NodeLink listens to nothing while a link is lent.

**4.2 Lending.**

*In `acquire(name, kind)`*, after the `_releasing` wait (`node_link.dart:256-259`), after the refusal when a lease exists (`:260`) and `core.acquireLease` (`:261`), and before `_dropAll` (`:262`):
- kept link reading, either kind → the read is cancelled and the kept link closed (4.5 "close"). The flow takes the slow path. There is no wait for the read (v4 had one of up to 1.5 s; deleted, §10: only necessary mechanisms; it can be added later if device timing shows the case matters).
- kept link parked, kind raw → closed.
- kept link parked, kind session → stays.
- `_dropAll` then waits for a closing link as for any link (4.5) and does not count a parked one (4.6). `gate.revoked(NodeLink's token)` does not match a null token (4.7).
- An `acquire` that is refused at `:260` touches nothing.

*In `loginFor(lease, id)`*, **after** the first refusal at `:304` and the three checks of F10:
- a check fails → a parked kept link is closed; the result is today's `precondition` / `noLease`. (For the key, `_loginFor` already calls `radio(keyOk: false)`, which is the `radio` row of 4.5.)
- kept link parked, same id → NodeLink's state subscription and inbox handler are removed and `gate.pass(link, lease.token)` is called, in one synchronous step; refused (not `up`) → close it, slow path. Else a **new** `LoginHandoff` object over the same link / inbox / session / subscription (`again(hook:)`; the old object's `_closed` is one-shot, so a late `close()` on an old object returns at once); state lent; return `ok`.
- kept link parked, another id → close it, wait until gone, existing path.
- State reading cannot be met here: `acquire` ended it, and no round runs under a lease. State lent cannot be met here: there is one lease, `loginFor` refuses while a login runs (`:304`), and every flow awaits its console's close before it logs in again or releases (`op_session.dart:109-115`, `:126`, `:171`).

**4.3 Giving back.** A handoff made by NodeLink carries NodeLink's hook; `close({reusable})` calls it once.
- `OwnerConsole._close` works out `reusable` **after** the wait for the step in progress and **before** the line `_session = null` (`owner_console.dart:691`, F9). It is true only when both hold: `_session != null` at that point (not `alive`: `_closed` is already true); every request this console made was `info` or `settings` (a read; a console that sent anything else never gives its session back, F12). v5 listed three more conditions (no request waiting when `_close` began, `_busy` false, the wait not ended by its 10 s limit) and `statusPage` on the list; all deleted, §11: a request that is waiting when `_close` begins sets `_session = null` (`owner_console.dart:685`), so the first condition already says all three and none of them had a control that could fail; the only console call of `statusPage` is the leave page's re-read (`ui/more_pages.dart:271`), on a console that has sent a leave. Every other caller passes nothing: `OpSession.once` closes the handoff without `reusable` when the page is gone or the lease is lost before the console exists (`op_session.dart:109-115`), so a sub-page left before its read starts ends the kept link. That is intended (fail-closed).
- The hook is `Future<void> Function(LoginHandoff h, {required bool reusable})`. Its decision is one synchronous step and it returns the future of the `destroy()` it starts (a completed future after a park), which is what `close()` returns. It parks (4.1 *Park*) only when all hold: `reusable`; NodeLink still holds this handoff as lent (4.5); `core.blocked == null`; `onPage(id)`. Anything else, or `pass` refused → `destroy()`.
- `onPage(id)` is the check v4 had deleted. It is needed for a link lent from the start (4.1 source 2): a login started from app settings, the team or the join pages was never on the node's page, and a `background()` or page change **during** a slow-path login finds nothing lent yet (F13). With the predicate in the hook, those events need no rule for a lent link at all: `setPage`, `background()` and link down do nothing to a lent link (4.5), and the hook decides once, at giving back. This is also what lets the predicate's control fail (T12).
- No `keysOk()` in the hook (v4 awaited it there). No path was found where it is the only thing that notices: a key lost one moment after the park is not seen until the next login either, because nothing polls the key; every lending checks the key before any use (F10, T15); `radio(keyOk: false)` closes a parked link (4.5). A parked link has a null token and its session signs nothing new until it is lent, so a link parked with a key that has just become unusable can only run status reads (already authenticated) until the next login closes it. Without the `await` the hook needs no second check and has no "returning" state.
- `core.blocked` stays in the hook: `radio()` leaves a lent link alone (4.5), so the hook is the only place that sees Bluetooth off, permission lost or a key marked unusable during the lending (T12 f).
- `close()` returns when the link is gone or parked.

**4.4 Status reads on it.** New interface `KeptReader { Future<Outcome> read(LoginHandoff h, {required Future<void> cancelled}); }`, implemented by `SessionProber` (the 8 test doubles of `Prober` are untouched): `requestStatusPage()` on `h.session`, the `answer` step as in `probe` (same `statusView`, same hint / team step with its 2 s budget); a view with `fresh == false` is `Res.noResponse` (F12). `probe`'s `answer` step (status view, error row, hint / team) is moved to one method that `probe` and `read` both call; no behaviour change in `probe`. `read` maps an `ended` step, any other step and a thrown error to `Res.broken`, and never completes with an error. `read` sets the inbox handler for its requests and clears it when it returns.
In `_pump`, before the scan branch: round active, kept link parked, and its id is a target of the round with no body and no error yet (`core.keptNeeds(id)`) → `gate.pass(link, NodeLink's token)` (refused → close the kept link, existing path), state reading, `read` with a 5 s limit. No scan and no connect while a kept link is reading, and none while it is parked: **`_pump` does not enter the scan branch while NodeLink has a kept link that is parked or reading** (it stops a running scan as it does when no round is active; the wake timer at the end of `_pump` is set as today). This is the only rule added for it (Q-m1); T4 (d) is its control. `gate.links` at `node_link.dart:533` is behind that rule; at `:352` / `:366` it is read only after the kept link is closed (4.2). (A parked link whose id is **not** a target cannot be met: a link is parked only on its node's page, where the targets are that node or nothing (F7), and a page change or the record going closes it first. v4 had a row and a core query `keptOnly` for it; both are deleted.)
- The 5 s limit, on NodeLink's injected clock, completes the `cancelled` future NodeLink passed to `read`; the rule below is then applied to what `read` returns, and a read that returns after its limit closes the link whatever its outcome.
- **When `read` returns**, NodeLink first checks that this handoff is still its kept link and still reading. If not (an event of 4.5 closed it during the read), the outcome is dropped: not recorded, not parked. A cancelled read can still return a body (F11); this rule is what keeps it out of the round (T4 e, T5 reading cases, T11). The 5 s limit is cancelled when the read ends.
- `Res.body` → `core.keptRead(now, id, addr, o)`: what `result` does for `Res.body` (F6), without an attempt. NodeLink then records `readWall` / `teams` with the same function `_run` uses. Park again. `addr` is `GateLink.address`. `keptRead` has no round check of its own (v4's `roundId` is deleted): the rule above covers every case where the round changed because the link was closed. v5 named one case that changes the round without closing the link, `refresh()` during a round started early. It cannot happen (P-2): an early round begins only for a target that ended not found / not yet (`core.dart:575-577`, `:615-623`), a round that had a parked link ends read or unchanged or has closed the link first, a link parked by the hook was lent under a lease and `acquireLease` clears the early start (`core.dart:259-264`), and once `_run` parks, `core.result` has already set the body, so `keptNeeds` is false for the rest of that round. `keptRead` returns false and records nothing when no round is active or the id is not a target of it, as `result` does (`core.dart:471`, `:478`); unreachable, no control.
- `Res.errorCode` → `core.keptRead` records `isY`, `t.err`, `s.errExtra` as `result` does, **without a retry**; park again. No scan and no connect for the rest of that round's 30 s window; the round ends at its window as a round with an error answer does today. ✅ L: on the prototype 2' was shown after the second such round (181 s in the test), not at once.
  This differs from the baseline (B6), where the retry is a new connect in the same round. Reason: a retry on the kept session must wait at least 1 s (F8: after `E_BUSY` the next `status` gets `E_RATE`), which needs a timer and a "waiting to read again" state; a retry by a new connect means closing a session that is still good. Not retrying needs no new code. Cost: a passing `E_BUSY` costs one round (60 s) without a fresh status, and 2' after a second one in a row. No error code is tied to the session, so not reconnecting does not keep a bad session for as long as the page is open (✅ P read `provd/session.go:856-885`, `:586-601`: bad object, unsupported, `E_RATE` (handled as not fresh), `E_BUSY` and the helper's own codes).
- Anything else, the 5 s limit, or the link not up → close the kept link; the same round goes on by the existing path. 5 s leaves 25 s of the 30 s window for it.
- Closing a kept link in state reading: the read is cancelled first, then the session is disposed, so the hint / team step never calls into a disposed session (`probe` has the same guard, `prober.dart:253`).
- Rounds on the node page come every 60 s, inside F8's 300 s.
- One read is two requests (`status`, then `info`, F12); the 5 s limit covers both and the hint / team step. The rate limit of F8 is per session and counts `status` requests. The kept session is used by NodeLink's reads and by a console. Flows that send a `status` request through a console (✅ read; M found them):
  - the leave page's re-read (`ui/more_pages.dart:271`): §4.9;
  - the software-update flow's entry read: on `E_RATE` it waits 1.5 s and asks again (`app/rust/batman-proto/src/swupd.rs:49-50`, `:902-905`). Nothing breaks; the entry is 1.5 s slower when the page is opened less than 1 s after a status read on the same session (§2, §6);
  - the link check of the check-network page (`flows/owner_console.dart:640-660`, `owner.rs:1457-1459`): it waits 10 s before each request (`:75`, `:656`), so it is never within 1 s of a kept read; any error is `LinkState::Unknown` (`owner.rs:999-1005`);
  - the address read before make / join network (`owner.rs:1381-1383`, retry `:1077-1083`): ⚠️ those pages set `Page.home` (F7), where no link is kept, so this read is on a new session as today.
  None of the last three consoles is reusable (their requests are not on the allow-list of 4.3).
- The UI during a kept read: the core has no running attempt, so the page shows no "reading" state for those about 0.6 s; the status changes when the read is recorded. Accepted (Q §3 item 9).
- Two status reads less than 1 s apart on the kept session (a new round right after a read) → `fresh == false` → `Res.noResponse` → the link is closed and the round reconnects. Fail-closed: only speed is lost.

**4.5 Events × states.**
"close" = (reading: read cancelled,) session disposed, link closed. The rules of a close, for every row:
1. NodeLink's reference to the kept link is cleared in the same synchronous step as the event. `keepFor`, `onPage` users and `loginFor` see "no kept link" at once; `setPage(home)` followed at once by `setPage(node, id)` starts from no kept link.
2. The closing link still counts in `gate.links` and in `_dropAll` until it is gone, as any link does: `acquire` and the next attempt wait for it (F5, F6).
3. `_pump()` runs when the close ends, as `_abort` does today (`node_link.dart:661`).
4. A second close of the same handoff is a no-op (Bluetooth off gives `radio(bluetooth: false)` and a link-down event; a held frame at park gives a close and then a `destroy()`).
5. Closing the link cancels the gate's 120 s timer for it and NodeLink's state subscription.

"forget" = NodeLink drops its reference and will not park it on return; the holder still owns it and its `close()` destroys it.

| Event | parked | reading | lent |
|---|---|---|---|
| link-down event / state stream ends | close | close | nothing (no listener while lent, 4.1). The holder's request fails as today; `pass` refuses the link at giving back (T20 b) |
| a frame or subscription error with no request out | close | — (the read's) | — (the console's) |
| `setPage` to anything but this node's page | close | close | nothing (F13); the hook's `onPage` destroys it at giving back |
| record of this id removed (checked right after the two record calls in `released`, `node_link.dart:499` and `:505`; at `start` there is no kept link) | close | cannot happen: no round runs at either call site (F14; `acquire` has ended a read before the lease) | cannot happen while lent: records change only after a lease release (F14), which is the "lease released" row |
| `background()` | close | close | nothing (F13); the hook's `onPage` destroys it at giving back |
| `dispose()` | close | close | forget, then `_dropAll` as today |
| `radio()` leaves `core.blocked` set (Bluetooth off, permission lost, key unusable; also from a failed `keysOk()` at a login, F10) | close, at once, in `radio()` | close | stays lent; the hook sees `core.blocked` when the holder closes (4.3) |
| raw lease acquired (in `acquire`, 4.2) | close | close | cannot happen (one lease) |
| session lease acquired (in `acquire`, 4.2) | stays | close; the flow takes the slow path | cannot happen |
| `loginFor` this id | lent (4.2) | cannot happen (4.2) | cannot happen (4.2) |
| `loginFor` another id | close | cannot happen (4.2) | cannot happen |
| the lease it was lent under is released, or taken back (420 s / 900 s), in `NodeLink.released` | — | — | forget. The gate has already closed the link (`gate.revoked` / `gate.released`; the gate listens first, §5). Also when the holder never closes. |
| holder closes | — | — | 4.3 |
| parked 120 s with no `pass` | **the gate** closes it | — | — |

Two forgets remain, each with a control that can fail: the lease going (T8) and `dispose()` (T16). v4's forgets on a page change, the background and link down are gone: the hook's `onPage` and `pass` decide those at giving back.

A parked link can be not `up` with no event: a down that comes only through `linkStates` sets `_down` and emits nothing (F4). NodeLink does not hear it. The next `pass` (a read, or a lending) is refused and the link is closed; with no `pass` the gate's timer closes it. Fail-closed (T20 c).

The last row is the safety net for a path NodeLink misses: `BleGate.pass(link, null)` starts the gate's own 120 s timer for that link (two 60 s rounds); any later `pass` stops it, and so does closing the link (rule 5); on expiry the gate closes the link, so `connect` works again. NodeLink has no timer of its own for this. The timer covers parked links only: a `keep` that `_run` neither parked nor destroyed still has NodeLink's token and is not covered; that path is closed by 4.1 and T19.

One real path ends at this timer: a session lease whose holder never calls `loginFor` leaves the link parked; no round runs under a lease, so nothing calls `pass`, and after 120 s the gate closes it. If the lease is released sooner, the round 6 s later reads on the parked link. Fail-closed (T14 uses this path). The flows that do this (✅ grep of `app/lib`): 「移除節點」 `ui/more_pages.dart:84` (it removes the record, which closes the link), `ui/net_pages.dart:342`, `ui/dev_pages.dart:429`, `flows/offline_op.dart:118`; and `OpenSession` between `open` and its first `run` (`flows/op_session.dart:146-149`, `:155-190`; `ui/update_route.dart:28`). (`ui/net_pages.dart:271` and `:917`, which M and N also listed, do log in: through `flowDeps`, `net_pages.dart:77`.)

**4.6 Code that counts links.** `_dropAll` does not count a parked kept link (else every `acquire` waits 5 s of real time, F5). A reading one has been closed by `acquire` just before (4.2) and `_dropAll` waits for it to be gone, as for any closing link. `_pump`'s scan branch and `loginFor`'s slow path run only after the kept link is closed (4.2, 4.5) or not at all (4.4).

**4.7 `BleGate`.** `token` nullable; `_usable` refuses null. `GateLink.up` = `_open && !_down`. `pass(GateLink, Token?)` throws `Refused` for a link that is not `up`, and for a non-null token that is not the registry's current one; a caller that gets `Refused` closes the link. `released` / `revoked` never match a null token (the 120 s timer covers it).

**4.8 A2 (separate commit, kept only if it measures faster):** `requestConnectionPriority(highPerformance)` right after the link is up (`flutter_reactive_ble` 5.6.0). ⚠️ Effect and battery cost not known; F1's phase timing before and after decides. ❌ Not built by L (needs a phone).

**4.9 The leave page's re-read.** ⚠️ Inferred from source (L-m5), not built. After a leave the page reads the status once more on the same console (`ui/more_pages.dart:268-274`). Today that session is new, so the read is always fresh. On a lent kept session the last `status` request may be less than 1 s old (the leave was pressed right after a kept read, and the node answered fast). The node then answers `E_RATE` (F8) and Rust returns the page from **before** the leave, marked not fresh (F12). Showing that as the result of a leave is wrong.
Fix: the re-read takes a view with `fresh == false` as no value (`return v is StatusView && v.fresh ? … : null`). `leaveFlow` then marks the page stale (`app/lib/member_ui.dart:267-282`) and the page shows its existing line 「離開後沒有讀到節點的狀態，稍後回節點頁看。」 (`ui/more_pages.dart:314-316`). Chosen over delaying the re-read by 1 s because it adds no wait and no timer, uses a text the page already has, and cannot change today's behaviour (a new session never returns a not-fresh page, F12). The next round, 6 s after the release, reads the node again by a new connect (a leave is not reusable).

## 5. Interfaces

**Ownership.**
- Kept link and its state: NodeLink.
- Link token: the gate's field, written only through `pass`, called only from `node_link.dart` (source check T13).
- The 120 s parked timer: the gate.
- The 5 s limit of a kept read: NodeLink, on the injected clock (`after`); cancelled when the read ends.
- The inbox's single handler slot: the console while lent (it clears it at `owner_console.dart:680`); NodeLink while parked; the read while reading (4.1).
- NodeLink's link-state subscription: NodeLink; first park to lending or close (4.1).
- Session lease, records, the core's round: unchanged owners; `core.keptRead` is a second writer path into the round, owned by the core, called only by NodeLink, and no attempt runs beside a kept read.

**Contracts.**
- `Outcome.keep` (`Object?`): writer = `SessionProber` (read mode, `keepFor` true); reader = `_run`, which parks or destroys it (4.1). Null everywhere else.
- `keepFor`: a settable field of `KeptReader`, set once by NodeLink's constructor on a prober that is a `KeptReader`; null (never keeps) for every other prober and in the existing tests. With a prober that is not a `KeptReader` a link parked by the hook cannot be read: the round that needs it closes it and goes on by the existing path.
- `onPage(id)`: NodeLink's private predicate over the core's page, page node and foreground flag; read by `keepFor`, `_run` and the hook.
- `KeptReader.read`: caller = NodeLink in state reading; never completes with an error (as `probe`); does not close or dispose anything. Its outcome is used only if the link is still NodeLink's and still reading when it returns (4.4).
- `GateLink.up`: writer = the gate (both down sources of F4, `close`); readers = `pass` only. `pass` throws `Refused`; it never returns a value. The gate keeps the `Cancel` of the 120 s timer per link (`BleGate._timer` throws it away today).
- Core API for 4.4, owned by the core, called only by NodeLink: the read-only `keptNeeds(id)` ("this id is a target of the active round and has no body and no error yet"; false for an id that is not a target) and the writer `keptRead(now, id, addr, o)` (false, nothing recorded, with no active round or for an id that is not a target; 4.4). v4's `roundId` and `keptOnly` do not exist.
- `LoginHandoff.close({reusable})`: writer = the holder; reader = NodeLink's hook. `LoginHandoff.again(hook:)` makes the copy NodeLink hands out (slow path and each lending). No hook (tests, a handoff not from NodeLink: `owner_console_test.dart:144`, `retest_p_console_close_test.dart:32`, `login_for_test.dart:29`, `test/ui/app_link_console_test.dart:96`, `join_pages_test.dart:223`) = close as today. `reusable` wrongly true on a broken session: the parked link closes on link down or a frame, or the next read fails and closes it; a lent one fails that request with today's text.
- Listener order on a lease release: the gate, then NodeLink (`ble_gate.dart:136`); a parked link (null token) is not touched by the gate. NodeLink's `released` forgets a link lent under that lease.
- A silent dead link (out of range, no disconnect event yet): a parked link is closed by the next kept read's 5 s limit. A send lent on it ends "outcome unknown" after the console's wait, or sooner by link down when the phone's own supervision timeout fires first (`owner_console.dart:391-397`; the same answer is shown), where today the login fails and the page says "not sent". Unknown is the honest answer there; not unsafe. The node side of a silent link is N1 (§2).
- Fail-closed: any doubt closes the link and the existing slow path runs.

**Lifecycle.**

| Path | Today | After | Test |
|---|---|---|---|
| install / first run / app start | no link | same | — |
| open node page | read, link closed | read, link kept | T1, T19 |
| sub-page read, then send | 2 logins | 0 logins; after the send the link is closed | T2, T3, T17; device timing |
| a sub-page within about 6–16 s after a send | login | same (no kept link yet, or the reconnect is aborted) | — (accepted, §2) |
| sub-page tapped during the first read | read aborted, login | same; after it the link is kept | T3; device timing |
| sub-page opened while a 60 s read runs | read's link dropped, login | same: read cancelled, link closed, login | T11 |
| check-network page | login at the first step | first step on the kept session; link closed after (not reusable) | — |
| software-update page | login at the first step | first step on the kept session; up to 1.5 s more if within 1 s of a status read | device timing |
| 60 s on the node page | new connect per round | read on the kept link | T4 |
| leave the page / home / team / settings / make-join pages | — | closed at once | T5 |
| a read-only flow from app settings, the team or the join pages | login, link closed | same: not kept | T12 c, d |
| background, screen lock | round cancelled | + parked or reading link closed; a running request or login goes on (F13) and its link is not parked afterwards | T5, T12 b, T16 |
| `inactive` (split screen, notification shade, a system dialog) | nothing changes, rounds go on (`node_link.dart:234-235`) | same: the kept link stays and is read every 60 s for as long as that lasts. Intended: the app is still on screen. | — (no code changes on this path) |
| Bluetooth off, then on | round cancelled; new round when it is on | kept link closed at once in `radio()`; the new round reads by a new connect and keeps that link | T5, T4 e |
| app killed, phone crash, out of range (the node hears the disconnect) | — | link drops; the node ends the session (F8) | T6 for the app side of a link down; an app kill cannot be shown in a test |
| the same, and the node hears nothing (silent phone) | seconds of exposure per operation | exposure for as long as the page is open; node hidden about 350 s (worst about 650 s) with N1, maybe until a reboot without (§2) | on-site check, §6, ❌ |
| node reboot | next op reconnects | link down closes it; next op reconnects | T6, T20 |
| provd restart only | next op reconnects | ⚠️ not known whether BlueZ drops the link when only provd restarts (no capture from a node). If it stays up: a parked link is closed by the next kept read's 5 s limit, or, on a node with N1, by the node itself about 30–50 s after the restart (the restarted provd has no session for the link, and N1 cuts a connected device with no session); a request on a lent one ends by the console's timeout (15 s) where today a new login succeeds. Accepted; ❌ not tested. | — |
| node ends the session (300 s, an error) | — | a frame or link down closes it | T7 |
| lease taken back at 420 s, or released with the holder still open | lease's link closed | same; NodeLink forgets it and the next read is kept again | T8 |
| a session lease that never logs in | — | parked link untouched; read after the release, or closed by the gate at 120 s | T14 |
| unclear answer | console not alive | not parked | T9 |
| raw-lease page, login for another node | NodeLink's link closed | kept link closed first | T10 |
| key unusable / Bluetooth permission lost / radio off | `precondition` | same, kept link closed | T5, T12 f, T15 |
| leave network on a kept session | re-read on a new session | re-read may be rate-limited: shown as "not read" (4.9) | T21 |
| NodeLink forgets to close a parked link (our bug) | — | the gate closes it after 120 s | T14 |
| app upgrade / downgrade | — | no stored state | — |
| old node / new node | — | no node change in this plan. Node without N1: the app works the same; the silent-phone cost is the "without N1" line of §2. | device pass on an image with N1 |
| platforms | Android only | same | — |

**Security.**
- Asset: an authenticated owner session. Another app cannot reach the session object (in-process). A person holding the unlocked phone with the app open has today's rights without the wait.
- ⚠️ Another app on the phone and the radio link (M; from Android's behaviour, not checked here): an app with the Bluetooth permission can open its own GATT client on a device that is already connected and write to the same characteristic. Today that window is seconds per operation; after this change it is the page's lifetime. Session frames are encrypted (`app/rust/batman-proto/src/cose.rs`; an undecodable answer is `Res.undecryptable`, `core.dart:41`), so the expected worst case is a broken session and a reconnect. No test.
- An attacker in radio range: no new input. The kept link is the same authenticated session as today's, held longer. What holding it longer can cause is what §2 states: the node does not advertise and one slot is taken while the page is open.
- A link is parked only in the foreground on its node's page (`onPage`, at every park). `background()` closes a parked or reading link at once; a link lent or being logged in when the app goes to the background is destroyed when its holder closes (T5, T12 b, T16).
- No new input. A frame on a parked link is not parsed; it closes the link. A compromised node can only make the app close and reconnect.
- A parked link has a null token: no GATT call passes the gate (T1). Lending runs the same checks as a login (F10, T15).
- A lent session is never disposed by NodeLink (only forgotten, or left alone), so no use after dispose (T16).
- Node side: unchanged limits (F8); N1 bounds the silent-phone case (§2).
- Session keys live in the Rust `OwnerSession` longer (as the update page today); nothing new is logged; traces keep masked addresses.

## 6. Tests

Flutter, with the existing fakes plus one new combined rig (real `NodeLink`, `BleGate`, `LeaseRegistry`, `SessionProber`, `HandoffProber`, `OwnerConsole`, `OpSession.once`; fake radio, fake Rust session, fake clock; the existing `Fx` has no NodeLink). The rig's fake session answers a status read as two requests, `status` then `info`, with time between them (L's answered in one frame, which hid K-M1 / L-M1's second write), and can return a read's body after that read was cancelled (F11).

The last column is the change whose removal must make the row FAIL (run for each row and recorded in the PR). *main* = today's behaviour restored by a switch (`keepFor` always false; the slow-path handoff without the hook): the new test file does not compile on main, so "fails on main" cannot be shown on the unchanged tree. "0 links" in every row also means: the session was disposed.

| # | Test | Expect | Control |
|---|---|---|---|
| T1 | node page opened, the real `SessionProber` reads | 1 link, parked, null token; a GATT call on it is refused | main |
| T2 | T1, then `OpSession.once` (settings), twice | connect count stays 1; answered; parked again; a new handoff object each lending; `acquire` returns in under 1 s of real time (a `Stopwatch`: `_dropAll` waits with a real `Future.delayed`, which a fake clock does not see; the bound is generous on purpose: the wait it guards against is 5 s). A second `acquire` while the lease is held returns null and the link is still parked | main; `_dropAll` exception removed → the time assertion |
| T3 | on `Page.node` of that id, no kept link (the first read finds no node, so nothing is kept when the operation starts); two `OpSession.once` reads in a row | the two operations make 1 connect between them; parked after each | main |
| T4 | T1, advance 60 s, then 130 s | (a) status on the same link, no scan, no connect, state fresh, `readWall` / team section updated, and the link is still there after 190 s; (b) a hung answer → closed after 5 s and the round reads by a new connect inside its window; (c) `fresh == false` → not a read; (d) errorCode → still parked, no scan and no connect in that window, 2' when the core makes it so (after the second round on L's prototype); (e) Bluetooth off then on during the read, and the fake returns the old read's body after the cancel → nothing is recorded in the new round from the old read, and the link is not parked again | (a) main; (b) 5 s limit removed; (c) `fresh` rule removed; (d) two controls: the errorCode branch removed (it falls to "anything else": a second connect), and the `_pump` rule of 4.4 removed (a scan starts); (e) the "still its own and still reading" rule of 4.4 removed (the old body is then recorded in the new round) |
| T5 | from T1 (parked), each of: `setPage(home)`, `setPage(other)`, `setPage(node, other id)`, `background()`, record removed (driven as: a session lease is taken, the records change, the lease is released), `dispose()`, `radio(bluetooth: false)` (only `radio()` is called; the fake radio keeps the link up, so the link-down listener cannot be what closes it). And in state reading, between the `status` and the `info` request, each of: `background()`, `setPage(home)`, link down | 0 links. Reading cases also: no call into the disposed session, the read's outcome neither recorded nor parked. `setPage(home)` then at once `setPage(node, id)`: the new read connects and is kept. | that event's line removed (the link then stays: with the round-targets row gone, no other rule closes it); reading cases: that event's close for state reading removed |
| T6 | T1, link state false / stream done | 0 links; the next op succeeds by the slow path | listener removed |
| T7 | (a) T1, a frame while parked; (b) lent, the rig delivers a frame right after the console cleared its handler in `_close` (the console's `onLost` callback is that moment: `_close` calls it first, and a microtask queued there runs at `_close`'s first `await`, after the handler was cleared and before the hook), then the hook runs | (a) 0 links; (b) 0 links (the held frame closes it at the park) | NodeLink's inbox handler removed ((b): the frame stays held, 1 link) |
| T8 | on the node's page for the whole row (else nothing is kept). Lent; the lease is taken back at 420 s (one case) / released (one case) and the holder does not close; then the next round reads; then the old holder calls `close(reusable: true)` | after the lease goes: 0 links (the gate); after the round: 1 parked link (the read was kept); after the late close: that parked link is untouched | the forget in `NodeLink.released` removed → the round's read is not kept |
| T9 | console with an unclear reply closes | 0 links | `reusable` forced true |
| T10 | T1, raw lease acquired; T1, `loginFor` another id | 0 links before the other work starts | that line removed |
| T11 | a session lease is asked for while the 60 s read runs, between its `status` and its `info` request; then the flow logs in and reads | the read is cancelled and nothing of it is recorded; no call into the disposed session; 0 links when `acquire` returns; `acquire` returns in under 1 s of real time (`Stopwatch`; generous on purpose, as in T2); the flow is answered by the slow path, 2 connects | the reading case in `acquire` removed → `_dropAll` waits its 5 s of real time for a link nobody closes (the time assertion) |
| T12 | `close(reusable: true)` in each case. (a) on `Page.node` of that id, nothing wrong. (b) `Page.node`, no kept link, `OpSession.once` (info) started, `background()` before the login ends. (c) `Page.other`, `OpSession.once` (settings). (d) `Page.home`, one record, `OpSession.once` (info); then advance 60 s. (e) lent on the node's page, then one of `setPage(home)`, `setPage(node, other id)`, `background()` before the close. (f) `core.blocked` set while lent. | (a) parked. (b)–(f) the request is answered, then 0 links; (d) also: the 60 s round reads by a new connect and leaves 0 links | (b)–(e): `onPage` removed from the hook in two parts: the foreground term for (b) and (e) `background()`; the page term and the page-node term **together** for (c), (d), (e) `setPage(home)` and (e) other id → 1 parked link. (v5 removed the page term alone; with the page-node term left, (c), (d) and (e) `setPage(home)` could not fail. The two terms are one condition, "this node's page", P-1.) (f): `core.blocked` removed from the hook |
| T13 | source check: `pass(` on a `BleGate` is called only in `node_link.dart`; the pattern does not match `bypass(` or another class's `pass` | no other file calls it | a call added in another file makes it fail; run once and recorded like the others |
| T14 | T1, a session lease is taken and held with no `loginFor`; advance 120 s; release | at 120 s the gate has 0 links; after the release the next round connects, and its read is kept (NodeLink's reference to the closed link was cleared when the state stream ended) | gate timer removed |
| T15 | T1, then `keysOk` false / `core.blocked` set, `loginFor` | `precondition`, 0 links, no request sent | fast path moved before the checks |
| T16 | lent with a request out, then (a) `background()`, (b) `setPage(home)`, (c) `dispose()` (not awaited before the request is answered: `dispose()` runs `_dropAll`, which waits up to 5 s of real time for the lent link, as today for a lease holder's link; the rig answers the request and closes inside that wait) | the request is answered; the session is not disposed before the holder's close; after the close 0 links, nothing parked | (a), (b): the event closes a lent link as it does a parked one (state check removed) → the request fails; (c): the forget in `dispose()` removed → the hook parks, 1 link |
| T17 | T1, `OpSession.once` (setAp) | 1 connect; after it 0 links (not reusable) | allow-list removed |
| T19 | the real `SessionProber` (wrapped so that the test can act between its return and `_run`'s next step) returns a `keep`, then each of: (a)–(d) the attempt is aborted before `_run` resumes (`setPage`, `background()`, `acquire`, `radio` off); (f) `core.result` returns false, driven by a direct `core.setRecords` call without that record on the real core (v5's "`core.result` returns false" and "the record is removed" are this one case; NodeLink's own events cannot reach it, F14, so the branch is a defence and this is how the rig reaches it); (g) the link went down. And (e), unwrapped: a cancel (`background()`) between the answer and the end of the hint / team step | in every case: 0 links, **session disposed**, and the next round reads again (a new connect). (e) also: no call into the session after the dispose | (a)–(d), (f), (g): the `destroy()` on that branch removed (on the abort branch `_abort` closes the link anyway; it is the session assertion that fails). (e): the prober's cleanup rule "only when the returned outcome carries the `keep`" replaced by "whenever a `keep` was built" |
| T20 | link down (a) after the prober's answer and before `_run` parks, (b) with no request in flight: after `_close` cancelled the console's state subscription (`owner_console.dart:679`) and before the hook runs (a microtask queued in the console's `onLost` callback, as in T7 b; with a request in flight `_close` has already set `_session = null` and `reusable` is false whatever `pass` checks, P-5), (c) while parked, through `linkStates` only (no state event), then `OpSession.once` | (a), (b) 0 links; the next op succeeds by the slow path. (c) the lending is refused, the link closed, the op answered by the slow path | `pass` checks `open` instead of `up` |
| T21 | leave on a lent kept session; the fake node answers the re-read's `status` with `E_RATE` | the page's result is stale (the "not read" line), not the fields from before the leave | the `fresh` condition in the re-read removed |

T18 of v3 (a late `close()` on an earlier lending's handoff object) is removed: the old object's `_closed` is one-shot and each lending makes a new object, so no test can reach the hook's identity check from there (✅ L: its control did not fail). T2 keeps "a new handoff object each lending".

Rules with no control, stated as T13 was in v4: `keptNeeds(id)` false for an id that is not a target; `keptRead` false with no round or for an id that is not a target (4.4); "`loginFor` while lent" (4.2); the record check at `node_link.dart:499` (F14): none can be reached in the rig, so no row.

State of the controls. ✅ L (v3 prototype): T1, T2, T4 (a) (b) (c), T5's first six parked events, T6, T7 (a), T9, T10, T12 (a) (f), T14 with a test-only skip (not the real path used here), T15, T17. ⚠️ New or changed in v4 or v5, not run by anyone (M and N read only): T3 on the node page, T4 (d) (e), T5 `radio` and the reading cases, T7 (b), T8, T11, T12 (b)–(e), T13's control, T14 on the real path, T16, T19, T20, T21.

Rust (`owner.rs` unit test): on one session status → settings → status → info → status: each answer is its own and each status is `fresh`. ❌ Not built by L.

Existing tests: `app/test/flows/net_run_test.dart:143` (`_FakeHandoff.close`) takes the new parameter. `app/test/flows/op_session_test.dart`'s `Fx` takes a `make:` parameter (support code for T21, no assertion changed; reviews S-1, U-4). That is the whole list (✅ L, for the first: the suite passed on the prototype with only this change; no existing test drives the real `SessionProber` through NodeLink on `Page.node`). No other assertion may change.

Full suite: `flutter test`, `flutter analyze lib test` (⚠️ L: on the whole project `flutter analyze` reports 115 errors in `rust_builder/cargokit`, the same on the unchanged tree), `test-all.sh` (WSL), `cargo test` for the bridge. ❌ `test-all.sh` and `cargo test` were not run by L.

**Device (S20 + 04 on an image with N1; the image version is recorded in the PR), before = current dev APK, after = new APK (`adb -s RFCN30HMRAR install -r`).** ❌ None of this has been run.
- Timing, logcat timestamps from tap to result for: open node page; Wi-Fi page read; country page read; the same after 2 min on the node page; leave and re-enter; Wi-Fi tapped within 2 s of opening the node page (during the first read), once; the software-update page opened right after a status read.
- Pass: every read after the first is under 1.5 s, with four stated exceptions that are recorded and not failed: a tap during the first read (one F1, as before); a tap that lands in a 60 s read (one reconnect); the update page within 1 s of a status read (its entry up to about 3 s: 1.5 s of `E_RATE` wait on top); a tap within about 6–16 s after a send (no kept link yet, or the reconnect is aborted: one F1, as before; §2).
- Sends (Wi-Fi, country) change the node: timed only with the user's consent; pass = app-side time from tap to the node's answer under 1.5 s. Before-numbers are in the PR next to them.
- ❌ Not yet run, on-site check (with the user; it sits next to N1's own manual check): node page open on the S20; (1) airplane mode on, (2) in a second run, walk out of range; a second device scans for the node; record the time until the node is seen again. Expected about 350 s, at worst about 650 s (§2). The result and the image version go into the PR; if it cannot be run before the PR, the PR says ❌ for it.

Not tested: a second phone looking for the node while the page is open and the phone in range (expected not to find it, §2); battery; a restart of provd alone with the page open (§5 lifecycle); another app's GATT client on the kept link (§5 security); the silent-phone case on a node without N1.

## 7. Steps

0. N1 (`329-n1-plan.md`, branch `fix/329-n1`) is merged and in the image the nodes run. Decided (M-M2); it is that plan's work, not this one's. Steps 1–2 do not wait for it; steps 3 and 5 do.
1. This plan → two reviewers (whole document) → fix until no BLOCKER / MAJOR.
2. Implement §4 with §6; every control run on the implementation and recorded.
3. Full suite; APK on the S20; device timing and the on-site check, on an image with N1.
4. A2 measured; keep or drop.
5. PR with before / after numbers → the user merges.

## 8. Changes from v2 (reviews G, H)

- Gate-owned 120 s limit for a parked link, replacing NodeLink's 240 s; `dispose` and failed preconditions close it (G-M1, H-m6, H-m2).
- The fast path runs after `loginFor`'s checks (G-M2, H-M6).
- Events × states table; a lent link is only forgotten (G-M3, H-M4).
- The prober interface: `Outcome.keep`, `keepFor`, `KeptReader`, 5 s limit, `fresh`, errorCode, `refresh`, hint / team, no re-entry (G-M4, H-M1, H-M2). 4.4 is required, not optional (H-M3).
- A console that sent anything but a read never gives its session back; Rust test (H-M5, G-M5, G-m3, G-m4).
- Tests: a control per row, new rows T14–T18, the combined rig, the rule for existing assertions (G-M5, H-m5).
- `acquire` waits up to 1.5 s for a running read (G-m5, H-m3); a new handoff object per lending (G-m2, H-m1); no frame waiting at lending (G-m8); make / join pages (G-m1); listener order as a contract (H-m4); paths with directories; no idle limit stated as the user's direction (G-m6, H-m7); send timing in the device pass (G-m7).

## 9. Changes from v3 (reviews K, L)

MAJOR:
- The 1.5 s wait for a running read is in `acquire`, before `core.acquireLease` / `_dropAll` / `reg.acquire` / `gate.revoked`, and nowhere else; the "reading" bullet is gone from `loginFor`. A read is two requests and the wait covers the whole read. §4.2, §4.5, §4.6, B5, T11 and the rig say the same thing (K-M1, L-M1).
- `_run`'s new shape is written down: no unconditional close when the outcome has a `keep`; destroy on the abort return and on every other branch. New row T19 with its control. The gate timer is stated not to cover this path (K-M2).
- `GateLink.up` is the one source of "link up"; `pass` checks it and throws `Refused`; park = subscribe, then `pass`, in one synchronous step. New row T20 with its control (K-M3).
- The hook's page, foreground and lease conditions are deleted: the forget events of 4.5 already cover them, so their controls could not fail. T8 is rewritten around the forget in `released`; T12's page / background control is the forget; T18 is removed (L-M2, L-m10).

MINOR:
- 4.4: a status read is two requests; the rate limit is per session; what happens on two reads less than 1 s apart (K-m1).
- T4's "`refresh` during the read" cannot happen (`core.dart:314-315`); replaced by Bluetooth off / on (K-m2, L-m3).
- 4.5 row: the lease released or taken back while lent → forget in `NodeLink.released`, also when the holder never closes (K-m3).
- 4.5 row: `radio()` leaving `core.blocked` set closes a parked or reading link at once; a lent one is left to the hook. T5 gets the `radio` case (K-m4).
- `_close` works out `reusable` after the wait for the step in progress and before `_session = null`, from `_session`, not from `alive` (K-m5, L-m2).
- Lifecycle: "provd restart only" is its own row, ⚠️ not known, accepted, not tested (K-m6).
- The list of existing tests that change is stated: one (`_FakeHandoff`); the direct `LoginHandoff` users without a hook are named (K-m7).
- §6 table: T11 and T13 have their text in the right columns; T13 says why it has no control (K-m8).
- Citations: F3, F7 (path `app/lib/ui/`, `Page.team`), F8, F10 (the check at `:304`), F11, F12 (`addr_pending` lines); F4, F5, F6, F9 carry the lines the new text relies on (K-m9, L §4).
- 4.3: `keysOk()` is awaited first; the rest is checked again in one synchronous step with `pass` (L-m1).
- Interfaces L had to invent are now in the plan: how `keepFor` is set, `LoginHandoff.again(hook:)`, `up` and `Refused`, the core's `roundId` / `keptOnly` / `keptNeeds`, `Outcome.keep` as `Object?`, where `reusable` is computed, the forget in `released`, cancel-then-dispose when closing a read (L-m2).
- T2 measures real time with a `Stopwatch` (L-m4).
- 4.9: the leave page's re-read on a kept session can be rate-limited; a not-fresh view is taken as "not read". New row T21 (L-m5).
- 4.5: a session lease whose flow never logs in ends at the gate's 120 s timer; stated (L-m6).
- §5: a send on a silently dead parked link ends "outcome unknown" (L-m7).
- 4.3: `OpSession.once`'s gone / lease-lost closes end the kept link; stated as intended (L-m8).
- 4.4 and T4 (d): after an error code there is no scan or connect in that window and 2' comes when the core makes it so, not at once; T4 (d) gets a control (L-m9, L §3).
- `keysOk()` and `core.blocked` stay in the hook, with the reason (L-m10).
- §6 says what "main" means as a control and which controls nobody has run yet (L §3).

## 10. Changes from v4 (reviews M, N)

Added: one predicate. Deleted: one wait, one `await`, two checks, two core queries, one table row and three forgets.

MAJOR:
- The hook parks only when `onPage(id)` holds (foreground, `Page.node`, that node): the `keepFor` predicate without "no kept link", not a new mechanism. It covers a link lent from the start by a slow-path login off the node's page, and a `background()` or page change during that login. T12 gets the cases whose control can fail: (b) background during the login, (c) `Page.other`, (d) `Page.home` with one record, (e) events while lent; T3 states its page. Because the hook now decides, the forgets of a lent link on `setPage` and `background()` are deleted (with them in place the predicate's control could not fail in (e), the L-M2 class again). §2, §4.1, §4.3, §4.5, §5 security and lifecycle say the same thing (M-M1, N-M1).
- The 4.5 row "a round whose targets are not exactly `{kept id}` → close" and the core query `keptOnly` are deleted: unreachable once a link is parked only on its node's page (F7). T5's controls were re-checked: with that row gone, removing an event's line leaves the link open, so each can fail (M-M1, N-m2).
- N1 ships before this plan's app change: decided, not a question to the user. §2 states the dependency and the cost with and without N1 (the N1 plan's numbers); §3 and the "old node / new node" row say what "no node change" means; §7 has step 0; the device pass runs on an image with N1; the on-site silent-phone check is listed, ❌ not yet run (M-M2).

MINOR:
- 4.4: the "only flow" sentence is corrected; the four flows that send `status` through a console are listed with what each does on `E_RATE`. The update page can miss "under 1.5 s" by the swupd wait; §2 and §6 say so; no mechanism added (M-m1).
- §2 "Does not handle" and the device timing get "a sub-page tapped during the first read" (M-m2, N-m11).
- "inbox holds no frame" at lending is deleted (it cannot be false while NodeLink's handler is set). No check is added to the hook either: the park sets the handler, which gets a held frame at once and closes the link. T7 (b) tests it, with a control (M-m3, N-m8).
- 4.5: "⚠️ No such flow was looked for" is replaced by the list of lease holders that never log in; `net_pages.dart:271` and `:917` are not among them (M-m4, N-m6).
- 4.4, B6: an error code on the kept link is not retried in the same round; stated as a difference from the baseline, with the reason (a retry needs a 1 s timer and a new state, F8) and the cost. Not retrying is the choice that needs less code (M-m5).
- F4, 4.5, T20 (c): the second source of "down" (`linkStates`, no state event) is stated and tested (M-m6).
- §5 security: one ⚠️ line on another app's GATT client on the kept link; one line on an attacker in radio range; "Background closes a parked link at once" is replaced by a statement that holds (M-m7, N-m11, N-M1).
- T13: its control is run once and recorded; the pattern is pinned (M-m8).
- `keysOk()` is deleted from the hook, with the reason in 4.3 (no path where it is the only thing that notices). The hook is one synchronous step; v4's steps 1–3 and the "returning" state are gone. The question whether the hook calls `radio(keyOk: false)` no longer arises. T12's key case is removed; T15 keeps the key check at a login. 4.5's `keysOk` row is folded into the `radio` row (N-m11, M-m9).
- §5 ownership names the 5 s read limit, the inbox's handler slot and NodeLink's state subscription. The 1.5 s wait no longer exists (M-m10, N-m4).
- Lifecycle: own rows for `inactive`, for "Bluetooth off, then on", for the silent phone, for a tap during the first read, for the update page, and for a read-only flow off the node's page (M-m11, M-M1, M-M2).
- The 1.5 s wait in `acquire` is deleted. Rule: a session lease that arrives while the kept link is reading cancels the read and closes the link; slow path. Reason: only necessary mechanisms; it can be added later if device timing shows the case matters. B5, §2, 4.2, 4.5, 4.6, the lifecycle row and T11 are rewritten; v4's ⚠️ "second `acquire` during the wait" is gone with the wait (M-m12).
- T4 (e): the rule "when `read` returns, the link must still be NodeLink's and still reading, else the outcome is dropped" is written into 4.4 and is T4 (e)'s control. The round check in `keptRead` and `roundId` are deleted (N-m1).
- 4.5 names the rules of a close: reference cleared at once, the closing link still counted, `_pump()` after, a second close is a no-op, timers and subscription cancelled (N-m3, N-m5).
- 4.1 says which listener exists in which state: NodeLink's state subscription from the first park to lending or close, never stacked; none while lent. The cell "link down × lent" is "nothing; `pass` refuses at giving back" (N-m4).
- T14 uses a real path (a lease held 120 s with no login) instead of a test-only skip (N-m7).
- The kept-link step in `acquire` is after the `reg.current` refusal: a refused `acquire` touches nothing (N-m9).
- T5 gets three cases in state reading; T16 gets `dispose()` while lent; T19 asserts "session disposed" in every case (N-m10, N §3).
- 4.2 / 4.5: "`loginFor` this id while lent" is "cannot happen", with the reason (N-m11).
- F7's ⚠️ is closed by a grep done for v5; the path of `member_ui.dart` is written in full (N-m11, M §4).
- Found while writing v5, ⚠️ read not run: `refresh()` during a round started early starts a new round without closing the kept link (`core.dart:311-319`), which §9's K-m2 line did not cover; 4.4 says what the read's result does then.

## 11. Changes from v5 (reviews P, Q)

v5 was approved by both reviewers (0 BLOCKER, 0 MAJOR). v5.1 folds their MINORs. No mechanism is added. Deleted: one unreachable branch of `_run`, three redundant `reusable` conditions and one allow-list entry, one redundant check at the build of a `keep`, one ⚠️ paragraph about a case that cannot happen.

Review P:
- P-1: T12's control removes the page term and the page-node term together; the foreground term on its own.
- P-2: the `refresh()`-during-an-early-round paragraph of 4.4 is replaced by "cannot happen" with the reason; §5 and 4.4 say what `keptRead` does with no round or a non-target (false, nothing recorded; no control).
- P-3: 4.5 "record removed × reading" is "cannot happen"; T19's two cases "`core.result` false" and "record removed" are one case, driven by a direct `core.setRecords`, stated as a defence; F14 names the three call sites.
- P-4: T19 (e), with the real prober: a cancel during the hint / team step. 4.1 states that the prober skips its cleanup only when the returned outcome carries the `keep`; that rule is (e)'s control. So that the control can fail, the redundant "not cancelled" check at the build is deleted (with it in place no `keep` is ever built on that path and the rule cannot be shown).
- P-5: T20 (b) is the case with no request in flight.
- P-6: `statusPage` is dropped from the allow-list.
- P-7: T16 (c) says that `dispose()` waits up to 5 s of real time and how the rig runs inside that wait.
- P-8: §5 silent-link wording (link down may end the request sooner); a lifecycle row for the check-network page; B6's evidence that no error code is tied to the session.

Review Q:
- m1: the `_pump` rule: no scan branch while NodeLink has a kept link that is parked or reading. T4 (d) gets it as a second control.
- m2: `_run`'s branch "`keepFor` no longer true → destroy" is deleted (unreachable).
- m3: T19 as under P-3; the abort cases use the real `SessionProber`.
- m4: `reusable` is "`_session != null` after the wait, and the allow-list".
- m5: the hook's signature; its decision is synchronous and it returns the destroy's future; `destroy()` and `close()` share the one-shot `_closed`; `destroy()` keeps today's order of `close()`.
- m6: the record check sits right after the two record calls in `released`; T5 says how "record removed" is driven.
- m7: the `answer` step is one method shared by `probe` and `read`; `Outcome.withKeep`; the `keep` is attached after the hint / team step; the cleanup rule.
- m8: `GateLink.token` is no longer `final`; the gate keeps the 120 s timer's `Cancel` per link; `keepFor` is a settable field; `gate.links` at `:533` is behind the `_pump` rule.
- m9: T14 also asserts that the next round's read is kept.
- m10: a tap within about 6–16 s after a send is the fourth accepted slow case (§2, lifecycle, §6 device pass).
- m11: lifecycle "provd restart only": on a node with N1 the node cuts the session-less link after about 30–50 s.
- m12: the real-time bounds of T2 and T11 are generous on purpose.
- m13: T5 `radio(bluetooth: false)` calls `radio()` only.
- Q §3 (what an implementer had to invent), settled: 1 = m1; 2 = m5; 3 = m7; 4 = m6; 5 = m8; 6 `read` maps an `ended` step and thrown errors to `Res.broken` and never throws; 7 NodeLink's 5 s limit completes the `cancelled` future it passed to `read`, and a read that returns after its limit closes the link; 8 `addr` for `keptRead` is `GateLink.address`; 9 no "reading" state is shown during a kept read, accepted.
- Q §4 notes: T8 states its page; T2 gets the second-`acquire` assertion; T4 (a) checks the link after 190 s; T16 (c) as under P-7.

Found while writing v5.1 (text corrected, no behaviour added):
- 4.1 *Park*: a held frame's close does not make `pass` refuse (the link is closed after `destroy()`'s first `await`); the park looks at its own reference instead.
- 4.1: a handoff that carries a hook is destroyed through a hook-less copy, because the shared one-shot is already set when the hook runs.
- T3's parenthesis: nothing is kept because the first read finds no node (an aborted first read is the lifecycle row "sub-page tapped during the first read"; both start the operation with no kept link).

Found while implementing (test text corrected, no behaviour added):
- T7 (b), T20 (b): v5.1 named `keepScreen(false)` as the moment between the console's cleared handler / cancelled subscription and the hook. `OpSession.once` calls it only after `close()` returned, so that is after the hook. The moment is a microtask queued in the console's `onLost` callback (`_close` calls it before anything else; the microtask runs at `_close`'s first `await`).
- T19 (e): next to the `background()` cancel the test sweeps the cancel (`background()` and `acquire`) over every microtask turn from the answer to the end of the hint / team step.

Found in code review (reviews R and S of commit f572395; fixed in the commit after it; no mechanism added):
- S MAJOR 1: the Rust test of §6 is built (`owner.rs`, `a_kept_session_answers_each_read_with_its_own_and_every_status_is_fresh`). Controls, each a single product line: the `page_fresh = true` of the `status-page` answer removed; `request_info` tagged `info-page`; the `info-page` answer not stored. Each makes it fail. No product Rust change.
- R-1 (4.3 "`close()` returns when the link is gone or parked"): when a held frame closed the link at the park, the hook's `destroy()` was the no-op second close and `close()` returned before the link was gone. The park now hands back the future of the close it could not avoid (the held frame's, or its own after a refused `pass`), and the hook returns it. `_run` and the kept read call the same park and wait for nothing, as before. Test T7 (c): the stack reports the link gone 1 s after the disconnect; control: the park returns a completed future there → `close()` has returned at 0.5 s.
- R-2: not changed. 4.2 says "a check fails → a parked kept link is closed" for the three checks of F10, and the lease check is one of them; the plan is frozen. Its cost (one slow read when a lease is lost during `keysOk()`) is accepted. It now has a test (R-6). The close in the `core.blocked` check is the same rule and stays (control: T15 "core.blocked set" fails without it).
- R-3: the kept read has an error path: a reader that completes with an error closes the link as "anything else" does (4.4). `SessionProber.read` never does; this is the defence for another `KeptReader`. Test T4 (b3); control: the error path removed.
- R-4: accepted, no change. Records unreadable at a release keep the old list (A-m6), so a removed node's parked link stays until the page changes or the gate's 120 s; 「移除節點」 leaves the page.
- R-5: accepted, no change. `_dropAll` does not wait for a parked link the gate's timer is closing at that moment; the lending is refused (`pass`) and the slow path waits on `gate.links`.
- R-6: tests added: the lease released while `keysOk()` runs (T15, third case; control: the close in the lease check removed) and a reader that fails (R-3).
- S-1: accepted. `op_session_test.dart`'s `Fx` got a `make:` parameter for T21; support code, no assertion changed. §6's "whole list" should have named it.
- S-3: T19 (e)'s literal test (one `background()` during the hint / team step) is deleted: `background()` makes `keepFor` false, so no `keep` is built on that path and the test could not fail. The sweep is (e)'s test and control.
- S-4: the record check under another lease (`released`, first call site) has a test: T5 "record removed, and another lease is held when the records come back". §6 said it cannot be reached in the rig; it can, by taking the second lease on the registry itself (`NodeLink.acquire` waits for the record read). Control: that call removed.
- S-5: the 5 s limit's "returned after its limit" flag is not redundant with the timer's cancel: a cancelled read returns the page it had (F11). Test T4 (b2): the page is read at 3.5 s and the hint / team step is still waiting at 5 s; control: the flag removed → the late body is recorded and the link parked.
- S-6: no test change. Controls run for T15 "keysOk false": the fast path moved before the key check → fails; the `radio(keyOk: false)` line removed → fails. With the fast path between the key check and the other two (S's C14) nothing observable changes for a failed key: `radio(keyOk: false)` has already closed the parked link (4.5, the `radio` row), so no test can tell that order from the real one.
- S-7: accepted. T21 runs on the page's fake session. That a kept session really answers a `status` after other reads with its own, fresh page is the Rust test above; the lent session on a real node is the device session of §6.
- S-8: T4 (c) also asserts that the link is closed, the round reads by a new connect inside its window and that read is kept. Control: the `fresh` rule removed. (A change that parks the link again after a page that is not fresh makes the round read in a loop that never yields; the test file then does not complete. Not counted as a control.)
- S-9: accepted, no change: `probe` reaches its answer through the shared method (one more async turn); the fast path calls `pass` before it lends, in the same synchronous step; the test-only getters, the `KeptState` enum and one trace line; `keptRead` is also false for an id with no state.
- T10 "`loginFor` another id": its own control is run: the close of another node's kept link removed → the operation ends at the login.

Found in code review, round 2 (reviews T and U of commit ccd66c3, both 0 MAJOR; fixed in the commit after it; no mechanism added):
- T-1: what `_pump` throws after a kept link's close is no longer the result of that close: the futures a holder's `close()` waits for (4.3) mean "the link is gone" only, and the error goes to the zone, as it does when a timer calls `_pump`. Test T7 (d) (the rig's clock throws once in that `_pump`); control: the guard removed → `close()` ends with the error.
- T-2: an exception in the block that takes a kept read's answer (`core.keptRead`, recording the read, the park, `_pump`) closes the link as a reader that fails does (R-3), so the state is never left `reading`; the error itself still goes to the zone. Test T4 (b4) (the wall clock throws once while the read is recorded); control: that close removed → 1 link, state `reading`.
- T-3: accepted, no change. When the gate is already closing the lent link, the holder's `close()` does not wait for it; the same as before this plan, and the next `acquire` waits in `_dropAll` until no link is left.
- T-4: accepted, no change. R-2 and R-5 again: both cost one slow read and nothing else.
- T-5: accepted, no change. A holder's old `GateLink` would pass the gate under the next lending's token; `OwnerConsole` sends nothing after its `_close` (`_closed`, `_session = null`), so no path reaches it.
- T-6: accepted, no change (4.2). The fast path does not check that the link is alive before it lends: on a link that is down and not yet reported, the console waits its own 15 s. ❌ Not measured: to be looked at in the device session of §6.
- T-7 and U-3: accepted, no change. The Rust test's statuses 2 and 3 cannot be not `fresh` in that sequence; what the test discriminates is that each answer is its own (controls: `request_info` tagged `info-page`, the `info-page` answer not stored). `E_RATE` after a read is `status_page_rate_limit_keeps_the_earlier_read`'s.
- T-8: accepted, no change. A record removed while another lease is held is checked at that lease's release; until then the link is parked only while its node's page is open, and removing a node leaves the page.
- U-1: the PR body states the result of `cargo test` and `test-all.sh`, or ❌.
- U-2: the assertion lost with S-3 is back as a test of its own: T19 (e) "`background()` around the end of the hint / team step, then the foreground": the next round reads again (2 connects). Control: `foreground()` emptied.
- U-4: §6's list of changed existing tests now names `op_session_test.dart`'s `Fx`.
- U-5: accepted, no change (S-9's list, complete).
