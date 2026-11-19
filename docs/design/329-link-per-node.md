# #329 — one kept link per node (v2)

Status: v2, for review (v1 f558a4c: review A REJECT, review B APPROVE-WITH-CHANGES; §10). Baseline:
`docs/design/329-ux-speed-plan.md` v5.1 ("the UX plan", frozen, shipped in main 6e326fc). Everything in the UX
plan stays as it is except the changes listed in §3. Paths are under `app/lib/src/nodelink/` unless they start
with another directory.

## 1. Facts (checked for this plan)

App, main 6e326fc:

- A1. The gate allows one link in the whole app: `ble_gate.dart:257` refuses a connect when any link exists.
  A link that is closing stays in the gate's set until the stack reports it gone, at most 5 s
  (`ble_gate.dart:121-144`).
- A2. NodeLink keeps one link (`_kept`, `_ks`), only in the foreground and only on that node's page:
  `node_link.dart:298` closes it on any other page, `:304` closes it on `background()`, `:600` `_onPage`.
- A3. While a kept link is parked or reading, `_pump` starts no scan and no attempt (`node_link.dart:807-834`);
  an attempt starts only when `gate.links == 0` (`:465`, `:823`; the wait at `:479`).
- A4. A parked link the gate hears nothing of for 120 s is closed by the gate (`ble_gate.dart:179`, `:280`).
  A kept read parks the link again, which restarts that timer.
- A5. Rounds: `Page.home` / `Page.team` target every record, `Page.node` only its node, `Page.other` none
  (`core.dart:208-212`); a full round every 60 s (`Params.interval`); none in the background or under a lease
  (`core.dart:214`). `keptNeeds(id)` / `keptRead(...)` are already per node id (`core.dart:585-614`).
- A6. `core.next()` books the attempt it returns (`core.dart:502-508`); a target whose kept read ended with an
  error code still has candidates (`_candidates`, `core.dart:464-480`, returns none only for a body or a
  reason). Today no attempt can follow because of A3.
- A7. One lease in the app (`lease.dart`). `loginFor(id)` under a session lease takes the parked link of the
  same id and closes a parked link of another id (`node_link.dart:406-440`). A raw lease closes the kept link
  (`:352`) and `_dropAll` waits until the gate has no link (`:963-975`). Raw leases are taken only by
  `openRawPage` / `openRawPageFor` (`raw_use.dart:74`, `:88`; called from `ui/home_page.dart:60`, `:77`: the
  older claim / scan pages), which use the plugin themselves, not the gate. Every other operation takes a
  session lease (`ui/net_pages.dart:271`, `:342`, `:917`, `ui/more_pages.dart:84`, `ui/dev_pages.dart:429`,
  `ui/settings_pages.dart:26`, `ui/team_deps.dart:24`).
- A8. A kept read whose answer is not fresh — the node answered `E_RATE` — is no read
  (`prober.dart:272`): the link is closed and the round connects again.
- A9. The BLE plugin (`third_party/reactive_ble_mobile`, review B read the Kotlin; not opened by the author):
  one connector per address (`ReactiveBleClient.kt:50`, `:291`); the connection queue holds a device only
  until its first connection event (`DeviceConnector.kt:107`, `:135`, `:214-219`); disconnect, MTU, read,
  write, notify all take the device id (`ReactiveBleClient.kt:136-268`). Two paths tear down every device:
  the last Dart listener of the connection-state stream cancelling (`DeviceConnectionHandler.kt:27-46`) and
  the last listener of the notification stream cancelling (`CharNotificationHandler.kt:31-33`, `:77-80`).
  Neither is reached today: the gate listens to `linkStates` until `dispose` (`ble_gate.dart:150`) and every
  held link keeps its tx subscription (`prober.dart:240`).
- A10. The Rust owner session is an object per login (`rust/bridge/src/api/owner.rs`; no static state found by
  grep for `static`, `OnceLock`, `lazy_static`).

Node (read from source by agents for this plan and by both reviewers; ✔ = also opened by the author):

- N1. 2 session slots per node, counted per connection (`provd/server.go:35` ✔, `:819-823`). This plan uses
  one slot per node, as today. An owner's session is never evicted (`session.go:155-167`).
- N2. The node does not advertise while any link or session is open (`cmd/batman-provd/bluez.go:852-854`).
- N3. An authenticated session with no message for 300 s is ended and the link dropped (`provd/server.go:31`
  ✔, `session.go:290-297`). Any message that decrypts restarts the 300 s (`session.go:332`).
- N4. A link-layer drop ends the session at once (`bluez.go:374`). A phone that goes silent without a drop:
  the node is dark for about 350 s, at worst about 650 s (`329-n1-plan.md:34`, read from code, not measured).
- N5. Sessions are per node process; nothing found that lets an operation on node B end the owner's session
  on node A (`reconcile` `server.go:666-700` ends only sessions whose key left; `killOthers` `:876-888` after
  a claim / replay ends the others on that node — the phone sees link down).
- N6. `status` is limited to 1/s per session (`session.go:868-874`).
- N7. An idle session holds no `ops` slot (`session.go:607-615`); the message counter allows 2^20 messages
  (`session.go:334`), years at one read a minute.

Measured earlier (#329, S20 + 04/02): one read by a new connect ≈ 4.1 s, of which 0.6 s is the read itself
(UX plan F1); the home page reads two nodes one after the other in 7–8 s every round; about 1 connect in 10
fails on the phone side.

Not known (⚠️):

- U1. How many GATT links the S20 holds at once, and how many of them other apps and devices (watch,
  earphones, a Meshtastic radio) already use. Not checked. Hence `keptMax = 2` (§3.3).
- U2. Whether a connect to node B fails more often while a link to node A is held. Counted in §7 D5.
- U3. Battery cost of held links on phone and node. Not measured (the user: battery later).
- U4. That Android closes an app's GATT links when its process is killed. Checked in §7 D7.
- U5. RxAndroidBle's internals (whether connect and scan share a queue): source not in the repo.
- U6. Effect of held BLE links on the node's Wi-Fi (same chip on the Pi). D1 runs with the phone on the
  node's Wi-Fi.

## 2. What this handles, what it costs, what it does not handle

Handles:

- Home / team page: every round after a node's first read is a read on its kept link (≈ 0.6 s per node, no
  scan, no connect) instead of a new connect per node per round — for up to `keptMax` nodes.
- Opening a node's page, and a sub-page of it, after the home page has read the node: the link is already
  there (today the node page connects again).
- Fewer connects in total. Whether that means fewer failed reads is counted (D1), not assumed.

Costs:

- C1. While the owner's app is in the foreground on the home, team or a node page, the (up to `keptMax`)
  nodes it holds do not advertise (N2). Today that is one node, and only while its page is open. Another
  phone — a member, a second owner, a phone that wants to join through that node — and the bench's BLE test
  items cannot find those nodes while the owner's app is on screen. In the settings (no reads) the links end
  120 s after their last read (A4). In the background they are closed at once, as today. If the phone
  leaves radio range the link drops and the node advertises again (N4); a phone that goes silent: N4.
  **Decision record:** the user accepted the node-page case on 2026-11-18 ("how an ordinary Bluetooth device
  behaves while its app is open"). The extension to the home page was put to the user on 2026-11-20 (twice);
  the answer was to go on, with no objection and no explicit yes. It is stated again in the PR body; if the
  user says no, `keptMax = 1` plus the node-page term in `keepFor` restores today's cost.
- C2. Battery, U3.

Does not handle (and why):

- The first read of each node after the app starts, after a return from the background, or after a link was
  lost, is still a scan and a connect, one node after the other (≈ 4 s each). Connecting to several nodes at
  the same moment is not in this plan (U2; every one-attempt-at-a-time rule of the baseline would change).
- Keeping links in the background. v1 had it; dropped: with no foreground service Android may freeze the
  app's timers, and every pocketed phone would then keep its nodes dark for up to 300 s (N3).
- An operation started from the home, team or settings pages still logs in by a new connect, as today
  (§3.2-6): only a node's own page lends the kept link, so no operation gets an already-open session that
  does not get one today.
- A sub-page tapped while a node's first connect is still running: the operation aborts the attempt and
  connects again, as today (UX plan §2).
- On a node's page for more than 120 s, the other node's link is closed by A4. The next home round connects.
- A home round that runs to its 90 s cap (a target that cannot be reached): the next read of the kept nodes
  is 150 s after the last, so A4 closes their links and that round connects again.
- More than `keptMax` nodes: the rest are read by connect–read–close, as today.
- A second owner's or a member's phone that needs a held node: C1.

## 3. The change

Unchanged: one lease; one scan; one attempt (connect + login) at a time; one request at a time on the radio
from NodeLink (a kept read or an attempt, never both); every rule of the UX plan about a single kept link
(park, lend, give back, read, forget, the 5 s read limit, `fresh`, error codes, the hook) — now per link.
No node change. No UI change. No change in `lease.dart`, `handoff.dart`, `prober.dart`.

### 3.1 Gate (`ble_gate.dart`)

New getter `active` = number of links that are not (open and parked): a connecting link, a link held by a
lease or by NodeLink for a read, and any link that is closing (A1).

`connect` is refused (as today, `Refused`) when a link to the same address exists, or `active > 0`.

Everything else in the gate is as it is: the per-link 120 s timer, `pass`, `revoked`, `released`,
`linkStates` (listened to until `dispose`, A9), the scan rules.

### 3.2 NodeLink (`node_link.dart`)

1. `_kept` becomes a map id → entry; the state (`parked` / `reading` / `lent`), the lending lease, the state
   subscription, the read's cancel and `readEnd` (clock time the last read on it ended) are in the entry.
   Every rule below that walks the map works on a copy of its keys. After every change of the key set
   NodeLink calls `core.setKept(ids)` (3.4).
2. `keepFor(id)` (a round's attempt ended with a body; synchronous) = no entry for `id`, the record exists,
   `core.blocked == null`, `core.fg`, and there is room (3.3). The page term is gone. `_giveBack` (the holder
   closed a lent link) parks it on the same terms without "no entry", and `reusable` as today.
3. `setPage` closes nothing. `background()` closes every entry that is not lent (today's rule, per entry).
   What else ends an entry: the gate's 120 s (A4), link down, a failed or late read, `radio()` leaving
   `core.blocked` set (every entry not lent), its record removed, a raw lease (5), 3.3, `dispose` (all).
4. `_pump`, in a round:
   - if no entry is reading and `gate.active == 0`: the first parked entry with `core.keptNeeds(id)` whose
     `readEnd` is at least 1.1 s ago is read (N6 / A8); one whose `readEnd` is newer gets a wake-up timer;
   - an attempt starts only when `gate.active == 0` and no parked entry `keptNeeds` (so kept reads come
     first; a closing link is waited for, as today);
   - the scan is started when a round target has no entry (`core.roundTargets`, 3.4) and then runs until
     the round ends, as today; a round whose targets all have entries starts none;
   - a read in progress when the round is cancelled or replaced ends normally: `core.keptRead` takes it
     into the round that is active then, or not at all (it returns false; the entry is parked). The data is
     the node's answer of that moment either way. (The baseline closed the link on every such change, so
     this could not happen there.)
5. `acquire`: a reading entry is closed (as today). Raw lease: every parked entry is closed (today's rule
   for the one link; the raw page uses the plugin itself, A7). Session lease: parked entries stay.
   `_dropAll` waits until `gate.active == 0`, bounded as today — for a raw lease that includes the closing
   entries, so the lease is given with no link left, as today.
6. `loginFor(id)`: the parked entry of `id` is lent when `id`'s node page is open (`_onPage(id)`, as today);
   on any other page it is closed and the login takes the existing path (as today: there was no kept link
   there). "A parked link of another id is closed" is deleted: the existing path runs with other entries
   parked. Its two conditions `gate.links == 0` (`:465`) and `gate.links > 0` (`:479`) become
   `gate.active == 0` / `> 0`. The early returns: lease not mine → the parked entry of `id` is closed;
   `core.blocked` → every entry not lent (as `radio()`).
7. `released`, link down, `_keptRecordCheck`, the read limit: as today, on the entry concerned. Test getters
   `kept(id)` / `keptState(id)`.

### 3.3 Room

`keptMax = 2` (the number the bench can check; U1). There is room for X when fewer than `keptMax` entries
other than X exist. When there is none: on X's node page the first parked entry in map order is closed and
X is kept (its close is counted in `active`, so the next attempt waits for it); on any other page, or if no
other entry is parked, X is not kept (read, close). A link lent from the start (a login by the existing
path) is an entry and counts.

### 3.4 Core (`core.dart`)

- `setKept(Set<String> ids)`: the ids that have an entry. `_candidates` returns none for them, so `next()`
  never books an attempt for a node that has an entry and `tick`'s `pending` does not wait for one (A6).
  When an entry ends, NodeLink calls `setKept` again and the node is a normal target: the round goes on by
  scan and connect.
- `roundTargets`: the active round's targets (read-only), for the scan rule.

Nothing else changes in the core: a kept target with an error code ends the round at its 30 s window, as
today on a node page.

## 4. Ownership

| Resource | Owner (only writer) | Readers |
|---|---|---|
| Set of open links, each link's token, the 120 s timer | BleGate | NodeLink (`links`, `active`, `up`) |
| Kept entries and their state, `readEnd` | NodeLink | tests |
| `core` kept-id set | NodeLink (through `setKept`) | NodeLinkCore |
| The lease | LeaseRegistry | NodeLink, gate (listeners, order unchanged) |
| A lent link's session | the operation holding the lease | — |
| Round, targets, node states | NodeLinkCore | NodeLink, UI |
| Node session, idle limit, advertising | the node (provd) | — |

No resource gets a second writer. A link is in exactly one of: connecting (attempt's), parked (nobody's;
gate timer), reading (NodeLink's), lent (the lease's), closing (nobody's; counted in `active`).

## 5. Contracts

- Gate `connect`: refusal is a thrown `Refused` at once. With 3.1 and 3.2-4/6 NodeLink never asks for a
  connect that is refused for these reasons; if it does, it is a failed attempt as today.
- `gate.active == 0` ⇔ nobody is using the radio for a link and none is closing: the only condition under
  which NodeLink starts an attempt or a kept read, and what `_dropAll` waits for (5 s real time).
- Plugin (A9): a parked link keeps its tx subscription; the gate's `linkStates` subscription lasts until
  `dispose`. These two hold today and must keep holding: without them the plugin drops every device.
- Node `status` 1/s per session (N6): NodeLink leaves 1.1 s between two reads on one entry. A lent session
  is its operation's (as today on a node page).
- A parked link may be down without the app knowing (UX plan T-6): a kept read fails within 5 s and the
  round goes on by scan and connect; a lent link costs the operation its own 15 s wait (accepted in the UX
  plan; lending happens only on the node page, as today).
- Node side: missing or stale = the node drops the link (N3/N4); the app sees link down and forgets the
  entry. Fail-closed on both sides: no entry is used without `GateLink.up` and a session answer.

## 6. Lifecycle

| Path | Today | After | Test |
|---|---|---|---|
| First start, no records | no links | same | existing |
| Start with n records, home | n connects per round, each closed | first round: n connects, ≤ keptMax kept; later rounds: kept reads | L1 |
| Home → node page → sub-page | page connects again; sub-page takes the page's link | page reads on the kept link; sub-page takes it | L2 |
| Node page ≥ 120 s, back to home | other node: connect | other node: connect (its link ended by A4) | L3 |
| `Page.other` (settings) | kept link closed at once | links end by A4 after ≤ 120 s | L4 |
| Background, any length | closed at once; reconnect on return | same, every entry | L5 |
| Operation from a node page (session lease on X), Y kept | Y cannot be kept at all | X's entry lent; Y stays parked; ends by A4 if the lease lasts > 120 s | L6 |
| Operation from home / team / settings | new connect | X's entry closed, new connect; other entries stay | L6b |
| Raw lease (older claim / scan page) | kept link closed, waited for | every parked entry closed, waited for | L7 |
| Bluetooth off / permission lost / keys | kept link closed | every not-lent entry closed | L8 |
| Link down (out of range, node reboot, node idle limit, `killOthers` after a claim / replay by someone else, owner removed) | entry forgotten | that entry forgotten, others untouched | L9 |
| Record removed | its kept link closed | same, per entry | L10 |
| More than `keptMax` nodes | — | 3.3 | L11 |
| OTA of a held node (lease > 120 s, node reboots) | — | other entry ended by A4; the node's link down → L9 | L6, L9 |
| Node ends the session but its disconnect fails (N1 rule, 30 s) | parked link looks alive; first use finds out | same, per entry (§5) | L15 |
| App killed / crash | Android closes the link (U4) | same, for each | D7 |
| Phone goes silent (no drop) | node dark ≈ 350 s for the page's node | same for each held node (C1) | on-site check, open in #329 |
| Another phone needs a held node | waits while the owner is on that node's page | waits while the owner's app is on screen (C1) | D1 (node log: no advert) |
| Node restart / power loss | link down | link down → L9 | L9 |
| provd restart only | UX plan row (⚠️) | same, per link | not tested (as the baseline) |
| Upgrade / rollback of the app | no stored state | no stored state (links are not persisted) | n/a |
| Old node image | — | no node change | n/a |
| iOS | no iOS app | n/a | n/a |

## 7. Tests

In `app/test/nodelink/`. Rig work needed first: `kept_link_test.dart`'s `KRadio` holds one connection
(`conn`, `addr`); it becomes a map by address with `drop(addr)` / `linkDown(addr)`, so several links exist at
once. Existing tests that assert "closed on leaving the page" change to the new rule; the list goes in the
PR body. Each row's control is the named change reverted, run once, shown failing.

| # | Test | Control |
|---|---|---|
| L1 | home, 2 records: round 1 = 2 connects; round 2 = 0 scans, 0 connects, 2 reads, both bodies | gate refuses when `links > 0` (A1) → round 2 connects |
| L2 | home read → node page → `loginFor`: 0 new connects, the link is lent | close in `setPage` restored |
| L3 | node page X for 130 s: Y's link closed by the gate at 120 s, X's still kept | gate timer off → Y still open at 130 s |
| L4 | `Page.other`: links open at 119 s, closed at 121 s | gate timer off |
| L5 | background with 2 parked and with 1 reading: all closed at once; foreground → 2 connects | close in `background` limited to the first entry |
| L6 | node page X, session lease, X lent 30 s, Y parked the whole time; the home round after release reads Y on its link | "close another id" restored |
| L6b | home, `loginFor(X)` with X and Y parked: X's entry closed, login by a new connect, Y still parked | lend without `_onPage` → 0 connects |
| L7 | raw lease with 2 parked: when `acquire` returns, `gate.links == 0` | `active` without closing links → `links > 0` at return |
| L8 | `radio(bluetooth:false)` with 2 parked: both closed | only the first entry closed |
| L9 | link down on X: X forgotten, Y read on its link in the same round, X by scan + connect | every entry forgotten on a link down |
| L10 | record of X removed: X closed, Y kept | check only the first entry |
| L11 | 3 records, keptMax 2: the 3rd is read by connect–close each round; on the 3rd's page the first parked entry is closed and the 3rd kept | room check removed (3 kept); eviction removed (3rd not kept on its page) |
| L12 | gate: connect to an address that has a link → refused; while another link is connecting, lent or closing → refused; with 2 parked → allowed | each term removed |
| L13 | round with X kept and Y not: X read first, then Y's attempt; never a read and an attempt at once | "no parked entry keptNeeds" removed |
| L14 | all targets kept: no scan started in the round; X's entry dies mid-round → the scan starts | scan rule → always scan |
| L15 | kept read of X fails (5 s): X closed; the attempt for X starts only after its link is gone and is not refused; Y untouched | `active` without closing links → attempt refused, counted as failed |
| L16 | kept read of X ends with an error code while Y is still looked for: no attempt for X, the round ends at its window | `setKept` not applied in `_candidates` → an attempt for X |
| L17 | round ends, page change starts a new round 0.3 s after X's read: the next read on X starts at 1.1 s, not before | wait removed → read at 0.3 s |
| L18 | home → node page while X's entry is reading: the read ends, the entry is parked, the node page shows the body | — (no line to revert; asserts 3.2-4 last point) |

Full suite: `flutter test`, `dart analyze`, `cargo test`, `test-all.sh` (no Rust change expected).

Device pass (S20, 04 + 02, phone on 04's Wi-Fi; timings from the app's trace ring and logcat; node side from
the provd log lines for link up / down and advert register / withdraw):

- D0. Before installing: with the main APK now on the phone, home page for 30 min: count connects and
  failed connects, time per round. (The same-session "before".)
- D1. Dev APK, home page for 30 min: both links held; count link drops per node, connects, failed connects,
  time per round; node logs show no advert for that time (C1) and one session each.
- D2. Home rounds after the first: each node read in < 1.5 s (D0 ≈ 4 s each).
- D3. Home → node page → Wi-Fi sub-page: < 1.5 s (earlier record 4–7.6 s; repeated with the main APK in D0's
  session). Once tapping the node within 1 s of a round's read (L17 on the device).
- D4. Screen off 30 s → on: node logs show both links dropped at screen-off and the adverts back; reads
  return by reconnect. Settings page 130 s: links dropped at ≈ 120 s (L4 on the device).
- D5. Connect to 02 while 04 is held, 20 times (node page 02 → home → wait for 02's link to end …): count
  failures. D0 gives the rate without a held link. More than 4 of 20: 20 more; 8 or more of 40 = worse, and
  the PR says so. A small sample: ⚠️ either way.
- D6. Open the older scan page (raw lease) with both held: node logs show both links dropped within 6 s.
  Nothing is tapped on that page.
- D7. `am force-stop` with both held: node logs show both links dropped and the adverts back (U4).
- D8. A build with `keptMax = 1` (local, not committed): 02 read by connect–close on home; on 02's page 04's
  link is dropped and 02 kept (3.3 on the device).
- ❌ Not on the bench now: more than 2 links (U1 — needs more peripherals); a second phone looking for a
  held node; Bluetooth off / on (a phone setting: with the user on site).

## 8. Security

- Assets: owner control of a node through an authenticated session. Unchanged: who can log in, what a session
  may do, how keys are stored. No new input, port, file, config key or message.
- Change in exposure: an authenticated session per held node stays open while the app is in the foreground
  (today: one node, on its page). It can be used only through the app's own Rust session object (Noise keys
  in memory).
- Another app on the phone with the Bluetooth permission can open its own GATT client on a connected device
  and write a junk frame. The node's AEAD check fails and it ends the session (`session.go:320-328`):
  fail-secure, no access gained, but that node's reads fall back to a 4 s reconnect. Today that reach is one
  node while its page is open; after: every held node while the app is on screen. Not tested (the UX plan
  carries the same ⚠️ line). No mechanism added.
- `keysOk` is checked at `loginFor` only (`node_link.dart:407-416`), as today; with kept reads the home page
  can go a long time without a login, so a key that stopped being usable is noticed at the next operation,
  not by a round. Rounds only read status.
- A member's or stranger's phone cannot find a held node (C1). That is availability for others, not access.
  An attacker in radio range can already hold a node's link for 30 s at a time without a key (#255,
  `219-protocol.md:532`); the owner's held session displaces that.
- Physical capture of an unlocked phone with the app open: same as today.
- Failure mode: every loss (link down, timer, failed read) ends in "no entry" and the baseline path; a dead
  link is never shown as a fresh read (`fresh` rule unchanged).
- Negative tests: L12 (the gate refuses a second link to one address and a connect during another's use or
  close); L7 (a raw user never gets the radio with a link left).

## 9. Steps

1. This design: two reviewers, whole document, until no BLOCKER / MAJOR.
2. Implement: rig (`KRadio`), gate, core, NodeLink, with L1–L18 and their controls.
3. Full suite; D0 with the main APK; dev APK by `adb -s … install -r`; D1–D8.
4. PR with before / after numbers and C1 stated; CI; the user merges.

## 10. Changes from v1 (reviews A and B; ✔ = verified against source by the author)

- `active` counts closing links ✔ (A-1, B-1); the `maxLinks` gate rule is deleted (A-10).
- The core changes after all: `setKept`, `roundTargets` ✔ (A-2, A-3). The scan rule is one condition.
- Background keeping dropped (B-3, A-4): closed at once, as today. U4 of v1 and §3.4 of v1 are gone.
- C1 rewritten with its real reach and the decision record (A-4, B-3).
- Lending stays on the node page only, so no operation gets an open session it does not get today (A-5);
  "join" is a session lease, not raw ✔.
- `keptMax = 2`; `usedAt` deleted, eviction = first parked entry in map order (B-2, B-7, A-10).
- 1.1 s between reads on one entry ✔ (A-8, N6 / A8).
- Tests: rig change named; controls of L7, L8, L10, L11, L15 replaced; L6b, L16–L18 added (A-6, B-1).
- Device pass: same-session baseline, 30 min, node logs, raw page, force-stop, eviction build, thresholds
  (B-4, B-2).
- Plugin invariants in §5; unknowns U4–U6; lifecycle rows added (B-5, B-6, B-10); §8 exposure lines (A, B-9).
- Not taken: U1 measured with 5 peripherals now (B-2) — no such peripherals on the bench; `keptMax = 2`
  needs no such measurement. 90 s-cap rounds (A-7): stated in §2, no mechanism.
