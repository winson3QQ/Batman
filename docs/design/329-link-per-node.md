# #329 — one kept link per node (v1)

Status: v1, for review. Baseline: `docs/design/329-ux-speed-plan.md` v5.1 ("the UX plan", frozen, shipped in
main 6e326fc). Everything in the UX plan stays as it is except the changes listed in §3. Paths are under
`app/lib/src/nodelink/` unless they start with another directory.

## 1. Facts (checked for this plan)

App, main 6e326fc:

- A1. The gate allows one link in the whole app: `ble_gate.dart:257` refuses a connect when any link exists.
- A2. NodeLink keeps one link (`_kept`, `_ks`), only in the foreground and only on that node's page:
  `node_link.dart:298` closes it on any other page, `:304` closes it on `background()`, `:600` `_onPage`.
- A3. While a kept link is parked or reading, `_pump` starts no scan and no attempt (`node_link.dart:807-834`);
  an attempt starts only when `gate.links == 0` (`:465`, `:823`).
- A4. A parked link the gate hears nothing of for 120 s is closed by the gate (`ble_gate.dart:179`, `:280`).
  A kept read parks the link again, which restarts that timer.
- A5. Rounds: `Page.home` / `Page.team` target every record, `Page.node` only its node, `Page.other` none
  (`core.dart:208-212`); a full round every 60 s (`Params.interval`); none in the background or under a lease
  (`core.dart:214`). `keptNeeds(id)` / `keptRead(...)` are already per node id (`core.dart:585-614`).
- A6. One lease in the app (`lease.dart`); session leases on `loginFor(id)` take the parked link of the same id
  and close a parked link of another id (`node_link.dart:406-440`). A raw lease closes the kept link (`:352`).
- A7. The BLE plugin keeps one connector per address (`third_party/reactive_ble_mobile/PATCHED.md`, patch 2);
  `ble_backend.dart` takes the address in every call. Nothing in it is single-link.
- A8. The Rust owner session is an object per login (`rust/bridge/src/api/owner.rs`; no static state found by
  grep for `static`, `OnceLock`, `lazy_static`).

Node (read from source by an agent for this plan; the lines marked ✔ were also opened by the author):

- N1. 2 session slots per node, counted per connection (`provd/server.go:35`, `:819-823`). This plan uses one
  slot per node, as today.
- N2. The node does not advertise while any link or session is open (`cmd/batman-provd/bluez.go:852-854`).
- N3. An authenticated session with no message for 300 s is ended and the link dropped (`provd/server.go:31`
  ✔, `session.go:290-297`). Any message that decrypts restarts the 300 s (`session.go:332`).
- N4. A link-layer drop ends the session at once (`bluez.go:374`). A phone that goes silent without a drop:
  the node is dark for about 350 s, at worst about 650 s (`329-n1-plan.md:34`, read from code, not measured).
- N5. Nothing on the node forbids two sessions of one owner on two nodes; sessions are per node process.
- N6. `status` is limited to 1/s per session (`session.go:868-874`). One session per node: unchanged.

Measured earlier (#329, S20 + 04/02): one read by a new connect ≈ 4.1 s, of which 0.6 s is the read itself
(UX plan F1); the home page reads two nodes one after the other in 7–8 s every round; a return from the
background to a sub-page reconnects, 5.5 s; about 1 connect in 10 fails on the phone side.

Not known (⚠️):

- U1. How many GATT links the S20 holds at once. Android's stack is generally built for 7 or more; not checked
  on this phone. Only two nodes exist on the bench, so only 2 can be checked.
- U2. Whether a connect to node B fails more often while a link to node A is held. To be counted (§7).
- U3. Battery cost of held links on phone and node. Not measured (the user: battery later).
- U4. Whether Android freezes the app's timers in the background on the S20. The design does not depend on it
  (§4.4).

## 2. What this handles, what it costs, what it does not handle

Handles:

- Home / team page: every round after a node's first read is a read on its kept link (≈ 0.6 s per node, no
  scan, no connect) instead of a new connect per node per round.
- Opening a node's page, and a sub-page of it, after the home page has read the node: the link is already
  there (today the node page connects again).
- Return from the background within 120 s: the links are still there.
- Fewer connects in total, so fewer chances of the 1-in-10 connect failure.

Costs (stated to the user; the first is an extension of what was accepted for the node page on 2026-11-18):

- C1. While the owner's app is open on the home, team or a node page — and up to 120 s after it goes to the
  background or to a page without reads — every node it reads does not advertise. Another phone (a member, a
  phone that wants to join through that node) cannot find those nodes during that time. If the phone leaves
  radio range the link drops and the node advertises again at once (N4); if the phone goes silent the node is
  dark as in N4.
- C2. One of the node's 2 slots is taken for that time (as today on the node page).
- C3. Battery, U3.

Does not handle (and why):

- The first read of each node after the app starts, or after a link was lost, is still a scan and a connect,
  one node after the other (≈ 4 s each). Connecting to several nodes at the same moment is not in this plan:
  U2 is not known and the baseline's one-attempt-at-a-time timing rules would all change.
- A sub-page tapped while that first connect is still running: the operation aborts the attempt and connects
  again, as today (UX plan §2). After this plan it can happen only in the first seconds after start or after
  a link loss, not on every visit to a node page.
- On a node's page for more than 120 s, the other nodes' links are closed by A4 (they are not read there).
  The next home round connects to them again.
- More than `keptMax` nodes: the rest are read by connect–read–close, as today.

## 3. The change

Unchanged: one lease; one scan; one attempt (connect + login) at a time; one request at a time on the radio
from NodeLink (a kept read or an attempt, never both); every rule of the UX plan about a single kept link
(park, lend, give back, read, forget, the 5 s read limit, `fresh`, error codes, the hook) — now per link.
No node change. No UI change. No change in `core.dart`, `lease.dart`, `handoff.dart`, `prober.dart`.

### 3.1 Gate (`ble_gate.dart`)

`connect` is refused (as today, `Refused`) when:

- a link to the same address exists; or
- a link exists that is not parked (token not null): a connecting link, or one held by a lease or by NodeLink
  for a read; or
- `links == maxLinks` (`maxLinks = keptMax + 1`).

New getter `active` = number of links whose token is not null. Everything else in the gate is as it is: the
per-link 120 s timer, `pass`, `revoked`, `released`, `linkStates`, the scan rules.

### 3.2 NodeLink (`node_link.dart`)

1. `_kept` becomes a map id → kept link; the state (`parked` / `reading` / `lent`), the lending lease, the
   state subscription and the read's cancel move into the entry. Entry gets `usedAt` (set at park).
2. `keepFor(id)` = no entry for `id`, and the record exists, and `core.blocked == null`, and there is room
   (3.3). The page and foreground terms are gone. The hook's give-back condition (`_giveBack`) is the same
   predicate without "no entry".
3. `setPage` and `background` no longer close anything. What ends a kept link is: the gate's 120 s (A4), link
   down, a failed or late read, `radio()` leaving `core.blocked` set (all entries not lent), its record
   removed, a raw lease (5), eviction (3.3), `dispose`.
4. `_pump`, in a round:
   - first, each parked entry with `core.keptNeeds(id)` is read, one after the other, in map order;
   - no attempt starts while an entry is reading or while a parked entry still `keptNeeds`;
   - the scan runs only when a round target has no entry (when every target has one there is nothing to
     find, N2);
   - `gate.links == 0` (`:465`, `:823`) becomes `gate.active == 0`.
5. `acquire`: a reading entry is closed (as today). Raw lease: every parked entry is closed (today's rule for
   the one link; a raw user drives the radio itself). Session lease: parked entries stay. `_dropAll` waits
   until `gate.active == 0` (today: until only the parked link is left).
6. `loginFor(id)`: the parked entry of `id` is lent (as today). "A parked link of another id is closed" is
   deleted. The slow path (scan + attempt) runs with other entries parked.
7. `released`, link down, `_keptRecordCheck`, the read limit: as today, on the entry concerned.
8. An attempt is never started for an id that has an entry (it can only be asked for by the core when a
   device shows an address the core still remembers for that node; the read on the entry answers the round).

### 3.3 Room

`keptMax = 4` (U1: a constant; raised only after a check with more nodes). When a link to X could be kept and
there are already `keptMax` entries: if the page is X's node page, the parked entry with the oldest `usedAt`
is closed and X is kept; if no entry is parked, or on any other page, X's link is not kept (read, close).

### 3.4 Background

`background()` leaves parked entries alone. No rounds run in the background (A5), so nothing restarts the
gate's 120 s: a parked link ends at most 120 s after its last use. If the app's timers are frozen (U4) the
link ends when the node's 300 s runs out (N3) or when the timer fires at the thaw. On `foreground()` the core
starts a round (as today); it reads the entries that are left, the others by scan and connect.

A link lent to an operation that goes on in the background is not touched (UX plan F13); when the operation
ends, the hook parks it by 3.2-2 and the 120 s starts.

## 4. Ownership

| Resource | Owner (only writer) | Readers |
|---|---|---|
| Set of open links, each link's token, the 120 s timer | BleGate | NodeLink (`links`, `active`, `up`) |
| Kept entries and their state | NodeLink | tests (existing getters, now per id) |
| The lease | LeaseRegistry | NodeLink, gate (listeners, order unchanged) |
| A lent link's session | the operation holding the lease | — |
| Round, targets, node states | NodeLinkCore | NodeLink, UI |
| Node session, idle limit, advertising | the node (provd) | — |

No resource gets a second writer. A link is in exactly one of: connecting (attempt's), parked (nobody's;
gate timer), reading (NodeLink's), lent (the lease's).

## 5. Contracts

- Gate `connect`: refusal is a thrown `Refused` at once; callers already treat it as a failed attempt.
- `gate.active == 0` ⇔ nobody is using the radio for a link: the only condition under which NodeLink starts
  an attempt or a kept read, and what `_dropAll` waits for (bounded as today: 5 s real time).
- A parked link may be down without the app knowing (UX plan T-6). First use finds out: a kept read fails
  within 5 s and the round goes on by scan and connect; a lent link costs the operation its own 15 s wait
  (accepted in the UX plan; with background keeping it is more likely — measured in §7 D4).
- Node side: missing or stale = the node drops the link (N3/N4); the app sees link down and forgets the
  entry. Fail-closed on both sides: no entry is ever used without `GateLink.up` and a session answer.

## 6. Lifecycle

| Path | Today | After | Test |
|---|---|---|---|
| First start, no records | no links | same | existing |
| Start with n records, home | n connects per round, each closed | first round: n connects, kept (≤ keptMax); later rounds: kept reads | L1 |
| Home → node page → sub-page | page connects again; sub-page takes the page's link | page reads on the kept link; sub-page takes it | L2 |
| Node page ≥ 120 s, back to home | other node: connect (always) | other node: connect (its link ended by A4) | L3 |
| `Page.other` (settings) | kept link closed at once | links end by A4 after ≤ 120 s | L4 |
| Background < 120 s, return | all closed; reconnect | kept; first round is kept reads | L5 |
| Background ≥ 120 s, return | reconnect | links ended by A4 (or N3); reconnect | L5 |
| Session lease on X, Y kept | Y cannot be kept at all | Y stays parked; ends by A4 if the lease lasts > 120 s | L6 |
| Raw lease (claim, join) | kept link closed | all parked entries closed | L7 |
| Bluetooth off / permission lost / keys | kept link closed | all not-lent entries closed | L8 |
| Link down (out of range, node reboot, node idle limit) | entry forgotten | that entry forgotten, others untouched | L9 |
| Record removed | its kept link closed | same, per entry | L10 |
| More than `keptMax` nodes | — | 3.3 | L11 |
| App killed / crash | Android closes the links; node advertises (N4) | same, for each | not tested (OS) |
| Phone goes silent (no drop) | node dark ≈ 350 s for the page's node | same for every kept node (C1) | on-site check, open in #329 |
| Node restart / power loss | link down | link down → L9 | L9 |
| provd restart only | UX plan row (⚠️) | same, per link | — |
| Upgrade / rollback of the app | no stored state | no stored state (links are not persisted) | n/a |
| Old node image | — | no node change; N1 rule needed as before (shipped in wsl.31+) | n/a |
| iOS | no iOS app | n/a | n/a |

## 7. Tests

All in `app/test/nodelink/` on the existing rig (`sim.dart`, fake backend, fake clock). Each row has a
control: the named line removed or reverted makes it fail. Existing tests that assert "closed on leaving the
page / on background" (`kept_link_test.dart`) change to the new rule; the list goes in the PR body.

| # | Test | Control |
|---|---|---|
| L1 | home, 2 records: round 1 = 2 connects; round 2 = 0 scans, 0 connects, 2 reads, both bodies | gate rule of A1 restored → round 2 connects |
| L2 | home read → node page → `loginFor`: 0 new connects, the link is lent | close in `setPage` restored |
| L3 | node page X for 130 s: Y's link closed by the gate at 120 s, X's still kept | read Y on X's page → Y never closes (shows the row is real) |
| L4 | `Page.other`: links open at 119 s, closed at 121 s | gate timer removed |
| L5 | background 60 s → foreground: 0 connects; background 130 s → 2 connects | close in `background` restored (first half); timer removed (second) |
| L6 | session lease on X for 30 s, Y parked the whole time; round after release reads Y on its link | "close another id" restored |
| L7 | raw lease: every parked entry closed before the lease is given | raw branch removed → raw user's connect is refused |
| L8 | `radio(bluetooth:false)` with 2 parked: both closed | loop over entries → first only |
| L9 | link down on X: X forgotten, Y read on its link in the same round, X by scan + connect | forget-all on link down |
| L10 | record of X removed: X closed, Y kept | — (existing control, per entry) |
| L11 | 5 records, keptMax 4: 5th read by connect–close each round; on the 5th's page the oldest parked is closed and the 5th kept; with all 4 lent/reading the 5th is not kept | eviction removed; cap removed |
| L12 | gate: connect to an address that has a link → refused; connect while another link is connecting or lent → refused; with 2 parked → allowed | each rule removed |
| L13 | round with X kept and Y not: X read first, then scan, then Y's attempt; never a read and an attempt at once | "no attempt while keptNeeds" removed |
| L14 | all targets kept: no scan started in the round | scan rule removed |
| L15 | kept read of X fails (5 s): X closed, round reads X by connect; Y untouched | — (UX plan T4, per entry) |

Full suite: `flutter test`, `dart analyze`, `cargo test`, `test-all.sh` (no Rust change expected).

Device pass (S20, 04 + 02, dev APK by `adb install -r`; timings from the app's trace ring and logcat):

- D1. Both links held at once for 5 minutes on the home page: node logs show one session each, no drop.
- D2. Home rounds after the first: each node read in < 1.5 s (today ≈ 4 s each).
- D3. Home → node page → Wi-Fi sub-page: < 1.5 s (today 4–7.6 s).
- D4. Background 30 s → return to a sub-page: < 1.5 s (today 5.5 s). Background 150 s → return: reads work
  again by reconnect; note what the first operation on a dead parked link costs.
- D5. Connect to 02 while 04 is held, 20 times: count failures (U2), against the 1-in-10 known today.
- D6. Negative: with the APK from main, D2–D4 show today's numbers (taken from the #329 record if unchanged).
- ❌ Not possible on the bench: more than 2 links (U1); a second phone looking for a held node (C1).

## 8. Security

- Assets: owner control of a node through an authenticated session. Unchanged: who can log in, what a session
  may do, how keys are stored. No new input, port, file, config key or message.
- Change in exposure: an authenticated session per node stays open while the app is open and up to 120 s in
  the background (today: one node, foreground only). It can be used only through the app's own Rust session
  object (Noise keys in memory); another app sharing the GATT link cannot read or write it (UX plan §5, same
  ⚠️ line). The phone's lock screen and the app's own gates are unchanged.
- Local unprivileged process / compromised peer: a member's or stranger's phone cannot find a held node (C1).
  That is availability for others, not access: it gains nothing. An attacker in radio range can already hold
  a node's link for 30 s at a time without a key (#255, `219-protocol.md:532`); the owner's held session
  displaces that, it does not add to it.
- Physical capture of an unlocked phone with the app open: same as today.
- Failure mode: every loss (link down, timer, failed read) ends in "no entry" and the baseline path; a dead
  link is never shown as a fresh read (`fresh` rule unchanged).
- Verification: L12 (gate refuses a second link to one address and a connect during another's use); L15.

## 9. Steps

1. This design: two reviewers, whole document, until no BLOCKER / MAJOR.
2. Implement gate, then NodeLink, with L1–L15 and their controls.
3. Full suite; dev APK; device pass D1–D6.
4. PR with before / after numbers; CI; the user merges.
