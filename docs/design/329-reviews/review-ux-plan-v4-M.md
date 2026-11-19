# Review M of `329-ux-speed-plan.md` v4 (whole document)

Reviewer M, independent, 2026-11-19. Source: `C:\src\Batman-b8` (main 6760b78), read only. Nothing was run: no
suite, no prototype, no phone, emulator, node, adb, gradle or ssh. Every finding is from reading source. The v3
reviews K and L were read only after my own pass. The only file written is this report.

Legend: ✅ checked by me against the source line; ⚠️ inferred or from platform knowledge, not checked; ❌ not done.

Verdict: **APPROVE-WITH-CHANGES** — 0 BLOCKER, 2 MAJOR, 12 MINOR.

The design is the same sound one K and L approved (one kept link, null token while parked, lent under the
lease's token, a lent link only forgotten). The three v3 MAJORs about `acquire`, `_run` and `up` are really
fixed. The two MAJORs below are (1) a hole that v4 opened when it deleted the hook's page / foreground
conditions, and (2) a dependency on the node plan that v4 does not state.

## 1. MAJOR

### M1. A slow-path login parks its link with no node page open, or in the background (v4 deleted the only check)

v4 §4.3: "The hook has no page, foreground or lease condition. A page change, the background … all **forget** a
lent link (4.5)". That is true only when the event comes **after** the link is lent. Source 2 of §4.1 (a flow's
slow-path login) is "lent from the start" on any page, and nothing checks the page or the foreground when the
hook parks it. L's control did not fail (L-M2) because L's T12 delivered the event after the lending.

Scenarios (all read from source ✅, none run ❌):

- **(a) Background during the login.** Owner taps Wi-Fi with no kept link (first read still running, or after a
  send). `OpSession.once` logs in by the slow path, 4–8 s (F1). The owner locks the phone in that time.
  `background()` only cancels the round (`node_link.dart:216-219`, `core.dart:241-251`); there is no kept link to
  forget yet, and the login is not cut (`_loginFor` has no foreground check, `node_link.dart:315-377`; `blocked`
  is Bluetooth / permission / keys only, `core.dart:353`). The page is still mounted, so `gone()` is false. The
  login ends `ok`, the console reads settings, `_close` passes `reusable: true`, the hook's conditions all hold
  → **parked while the app is in the background.** No round runs there (`core.dart:196`, `:308`), so the only
  closer is the gate's 120 s timer. §5 Security says "Background closes a parked link at once"; §2 says the
  cost applies "with the app in the foreground". Both are false on this path.
- **(b) A reusable read from a page that is not a node page.** 「查看節點設定」 is pushed from the app settings
  page (`ui/settings_page.dart:88`), where `core.page == Page.other` (`ui/home_page.dart:340`). It runs
  `OpSession.once(… c.settings())` (`ui/dev_pages.dart:244`): reusable. The link is parked on `Page.other`,
  where no round runs (`core.dart:196`). It stays up to 120 s, or until the owner goes back (`setPage(home)`).
  Deterministic on every use of that page (dev builds).
- **(c) The same from the team pages** (`ui/remove_pages.dart:102`, `ui/join_pages.dart:721`: `c.info()`,
  reusable; `Page.team` / `Page.home`). Here the link is parked until the round 6 s after the release, and the
  only closer is the §4.5 row "a round whose targets are not exactly `{kept id}` → close". That row has **no
  test and no control** in §6.

Consequence: the plan's own definition ("the kept link … for the node whose page is open"), its cost statement
and its security statement do not hold; a node stays hidden from other phones for up to 120 s after the owner
locked the phone or with no node page open. No GATT call can pass (null token), so this is not a way in; it is a
stated invariant that is not enforced, with the 120 s "our own bug" timer as the normal closer.

Second effect, on the tests: where the round-targets row is implemented, it also closes the link in the same
`_pump()` that `setPage` calls (`node_link.dart:211-212`; `core.setPage` begins a round at once for a node page,
`core.dart:232`). Then T5's control for `setPage(node, other id)` ("that event's line removed") cannot fail: the
other row closes it. One of the two is a redundant-condition control.

Fix (smallest): the hook's step 1 and step 3 use the same predicate as `keepFor` without "no kept link":
foreground, `core.page == Page.node`, `core.pageNode == id`. This is one predicate that already exists, not a
new mechanism. Then:
- T12 gets the cases that make its control real: `background()` **during** the slow-path login (before the
  handoff exists), and a reusable read from `Page.other`; expect 0 links after the close; control = the
  predicate removed from the hook (it fails without also removing a forget).
- T3 says it runs on the node's page.
- The row "a round whose targets are not exactly `{kept id}`" becomes unreachable (on `Page.node` the targets
  are `{pageNode}` or empty, `core.dart:190-194`; a page change and a removed record close first). Delete the
  row and `keptOnly`'s part in it, or keep it and say "unreachable, no control". T5's controls are then sound.

### M2. The plan makes "a link that goes silent during a session" the common case, and does not say that this needs N1 on the node

Scenario: the owner has a node's page open and walks out of range, or the phone dies, or the app is killed.
Today a session is up for a few seconds per operation; after this change one is up for as long as the page is
open.

Evidence:
- `329-n1-plan.md` §2 "Not handled here": a link that goes silent during a session is dark for "usually about
  350 s … at worst about 650 s", and "becomes the common one once the app keeps a session per node page; **the
  idle limit is decided in that plan, not here**". Its lifecycle row "link silent during a session": **today**
  "dark until the session idles out, then forever".
- n1 F1: 04 was invisible for more than 39 min after the S20 had torn every link down; cause unknown ❓, never
  reproduced; candidates "out of range, Bluetooth off, app killed".
- This plan, §5 lifecycle: "app killed, phone crash, Bluetooth off, out of range → link drops; the node ends
  the session (F8; a silent link: `329-n1-plan.md`)". §2 Cost names only "until the owner leaves the page or
  the app". §3: "the node" unchanged. §6: device pass on wsl.26 "no node change" (an image without N1; N1 is
  not merged, the plan file is untracked).

So the row's "After" rests on a node change that is not in the image this plan is tested on, and on images
without N1 the app change multiplies the exposure to F1 (a node dark until someone reboots it) from seconds per
operation to the whole time a page is open. The plan decides "no idle limit" without the number that decision
costs.

Fix (text and one check, no new mechanism):
- §2 Cost: add "if the phone goes silent with the page open, the node is hidden for about 350 s (worst about
  650 s) with N1, and can stay hidden until a reboot without N1 (n1 F1)".
- §7: state the order as a point the user decides: the app change ships with or after N1 in the node image, or
  the user accepts the exposure on older images in words.
- §6 device: one on-site check next to n1's manual one: node page open, airplane mode on (and one "walk out of
  range"); a second device scans; record the time until the node is seen again, with the image version. It does
  not have to gate the PR, but "Not tested" must list it.

## 2. MINOR

1. **§4.4 "the only flow that sends a `status` request through a console is the leave page's re-read" is wrong.**
   Also: the software-update flow's entry read (`app/rust/batman-proto/src/swupd.rs:902-905`: `E_RATE` → wait
   `STATUS_RATE_MS`, the comment at `:49` says 1.5 s, then again); the link check after a join
   (`owner.rs:1457-1459`, `flows/owner_console.dart:656`; any error → `LinkState::Unknown`, `owner.rs:999-1005`);
   the address read before make-network / join when `WRITE_MESH_ADDR` is on (`owner.rs:1381-1383`, retry
   `:1077-1083`). Each handles `E_RATE` itself, so nothing breaks. But the update page is in scope
   (`OpenSession`, §2): opened less than 1 s after a kept read it waits 1.5 s more, which misses §6's "under
   1.5 s". Fix: correct the sentence, list the three, add the update page to the device timing or to "does not
   handle".
2. **Quick tap before the first read ends is not in "Does not handle".** Open the page, tap Wi-Fi within the
   4–8 s of the first read: `acquire` → `_dropAll` aborts that read (`node_link.dart:262`, `:664-675`); the
   operation pays a full F1, as today (the 1.5 s wait covers a *kept* read only). After that operation the link
   is kept (source 2). Probably the most common tap. State it; the device pass should time it once.
3. **"inbox holds no frame" at lending (§4.2) is a redundant condition with no test.** While parked NodeLink has
   the inbox handler, so the inbox holds nothing; a console clears its handler first in `_close`
   (`owner_console.dart:680`), frames are held, and the park's subscribe delivers them at once
   (`handoff.dart:38`), which closes the link. Delete the condition, or give it a row whose control fails.
4. **§4.5 "⚠️ No such flow was looked for" — they exist and are easy to list** (✅ grep of `app/lib`): session
   leases with no `loginFor`: 「移除節點」 `ui/more_pages.dart:84`; `ui/net_pages.dart:271`, `:342`, `:917`;
   `ui/dev_pages.dart:429`; `flows/offline_op.dart:118`. `OpenSession` (`ui/update_route.dart:28`) logs in only
   in `run`. All end as the paragraph says (parked, then read 6 s after the release or closed at 120 s);
   `more_pages.dart:84` removes the record, which closes the link. Replace the ⚠️ with the list. These callers
   also take the 1.5 s wait for a read they do not use; harmless.
5. **Error code on the kept link: no retry, where the baseline retries in the same round**
   (`core.dart:487-491`, `r.retry.add(key)`). A passing `E_BUSY` (the node's `status.get` call failed,
   `provd/session.go:876-879`) now costs a whole round without a fresh status, and 2' after the second. The plan
   states the behaviour but not that it differs from the baseline or why. Say why, or retry once on the kept
   link at least 1 s later (F8).
6. **"Link down" has two sources in the gate and only one reaches NodeLink's listener.** `_on(false)` emits on
   `state` (`ble_gate.dart:74-77`); the `linkStates` listener calls only `_downNow()` (`:137-149`, `:79-84`),
   which sets `_down` and emits nothing. A parked link can so be not `up` with no event; it is closed by the next
   `pass` (refused) or the 120 s timer. Fail-closed, and `up` covers it; say so under the 4.5 row, and let T20
   or T6 have one case driven through `linkStates` only.
7. **Security, "other app on the phone": the answer covers the session object, not the radio link.** ⚠️ From
   Android's behaviour, not checked here: another app with the Bluetooth permission can open its own GATT client
   on a device that is already connected, without a scan, and write to the same characteristic; the node sees
   one device. Today that window is seconds; now it is the page's lifetime. ⚠️ Session frames are encrypted
   (`Res.undecryptable`, `batman-proto/src/cose.rs`), so the worst case should be a broken session and a
   reconnect. One line in §5 with that evidence; no new test asked.
8. **T13's control.** "Adding a call in another file makes it fail" is a control; run it once and record it like
   the others. The pattern must not match `bypass(` or a method of another class named `pass`.
9. **`keysOk()` false at giving back (4.3 step 2): does the hook call `radio(keyOk: false)` as `_loginFor` does
   (`node_link.dart:317-324`)?** Not stated. Without it the page shows nothing until the next read finds the key
   unusable. One line.
10. **Ownership list (§5) omits three resources:** the 5 s limit of a kept read, the 1.5 s wait in `acquire`
    (both NodeLink's, on `after`), and the inbox's single handler slot (the console while lent, cleared at
    `owner_console.dart:680`; NodeLink while parked). One line each.
11. **Lifecycle rows missing:** `inactive` (split screen, notification shade, a system dialog): `lifecycle`
    does nothing (`node_link.dart:234-235`), so the link stays and rounds go on for as long as that lasts; state
    it as intended. "Bluetooth off, then on" has tests (T5, T4 (e)) but shares a row with "app killed"; give it
    its own row with those tests, since T6 cannot show an app kill.
12. **Over-design candidate: the 1.5 s wait in `acquire` (B5).** It changes a reviewed baseline, adds a timer and
    T11's two controls, to save one reconnect when a tap lands inside a read of about 0.6 s (once per 60 s, and
    6 s after each operation). L offered the simpler rule "reading + session lease = close, slow path". Not
    harmful as written (✅ the placement is right, see §3); keep it only if the device timing shows the case
    matters.

## 3. v3 findings: fixed or not

Checked against the v4 text and the source.

| v3 finding | State in v4 |
|---|---|
| K-M1 / L-M1 (the wait for a running read was in `loginFor`) | ✅ fixed. The wait is in `acquire` after the `_releasing` wait (`node_link.dart:256-259`) and before `reg.current` (`:260`), `core.acquireLease` (`:261`), `_dropAll` (`:262`), `reg.acquire` (`:264`), `gate.revoked` (`:267`). The token is unchanged during the wait, so the second request (`owner.rs:963-969`) passes. §4.2, §4.5, §4.6, B5, T11 agree. T11's rig answers in two requests. |
| K-M2 (`_run` closes before the abort check; no test) | ✅ fixed. §4.1 gives the new shape against `:632`, `:634`, `:639`; T19 with a control per branch; the gate timer is said not to cover it. |
| K-M3 ("link up" had no source) | ✅ fixed. `GateLink.up`, `pass` throws `Refused`, park = subscribe then `pass` in one step, T20. Its control can fail: `_downNow` sets only `_down`, `_open` stays true until `close()` (`ble_gate.dart:79-84`, `:107-109`). See MINOR 6 for the second down source. |
| L-M2 (controls of T8, T12 page / background, T18 could not fail) | ⚠️ fixed as asked (conditions deleted, T8 rewritten, T18 removed), but the deletion of the page / foreground condition opened **M1**: it was redundant only for events after the lending. |
| K-m1 (two requests; rate limit per session) | ⚠️ partly: the text is right now, but the added sentence "the only flow … is the leave page's re-read" is wrong (MINOR 1). |
| K-m2 / L-m3 (`refresh` cannot start a round during the read) | ✅ fixed (`core.dart:311-319`; T4 (e) uses Bluetooth off / on). |
| K-m3 (lease released while lent, holder never closes) | ✅ fixed (4.5 row; T8). Listener order ✅ (`ble_gate.dart:136`, `lease.dart:146-148`). |
| K-m4 (`radio()` while parked) | ✅ fixed (4.5 row, T5 `radio`). |
| K-m5 / L-m2 (`reusable` after the chain wait, from `_session`) | ✅ fixed; matches `owner_console.dart:675-693`. |
| K-m6 (provd restart only) | ✅ stated as ⚠️ not known, accepted, ❌ not tested. |
| K-m7 (list of existing tests) | ✅ fixed. I checked: `_FakeHandoff` at `net_run_test.dart:143`; the five hook-less `LoginHandoff(` users are at the lines named; `SessionProber(` appears in tests only in `prober_test`, `prober_hint_test`, `prober_team_test`, `handoff_test`. |
| K-m8 (T11 / T13 columns) | ✅ fixed; T13's control: MINOR 8. |
| K-m9 / L §4 (citations) | ✅ fixed; see §4 below. |
| L-m1 (`keysOk` is a `Future`) | ✅ fixed (4.3 steps 1–3). |
| L-m2 (interfaces L invented) | ✅ written into §4 / §5. Three small resources still unnamed: MINOR 10. |
| L-m4 (T2 real time) | ✅ fixed. |
| L-m5 (leave re-read rate-limited) | ✅ fixed (4.9, T21); `ui/more_pages.dart:267-273` and `owner.rs:953-956` match. |
| L-m6 (lease with no `loginFor`) | ⚠️ stated, but "no such flow was looked for": MINOR 4. |
| L-m7 (send on a silent dead link) | ✅ stated in §5. |
| L-m8 (`gone` / lease-lost closes) | ✅ stated in 4.3. |
| L-m9 (error code: 2' not at once) | ✅ fixed; T4 (d) has a control. See MINOR 5 for the baseline difference. |
| L-m10 (over-design in the hook) | ✅ lease condition gone; `keysOk` / `blocked` kept with a reason. Page / foreground: M1. |

## 4. Line references and claimed behaviour

| Fact | Result |
|---|---|
| F1 | ❌ not checked (a device log in a scratchpad). Still one measurement. |
| F2, F3, F4, F5, F6, F9, F10, F11, F13 | ✅ lines and behaviour match (`op_session.dart:89-131`; `node_link.dart:253-270`, `:301-326`, `:533`, `:632-639`, `:664-675`; `ble_gate.dart:62-69`, `:239-242`, `:252-266`; `lease.dart:131`, `:135-140`; `core.dart:19`, `:196`, `:218-232`, `:259`, `:469-492`; `prober.dart:163-166`, `:175`, `:256-269`; `op_session_test.dart:207`). |
| F7 | ✅ and the ⚠️ can go: the only `setPage` calls in `app/lib` are `ui/home_page.dart:208`, `:280`, `:288`, `:295`, `:340`; `ui/net_pages.dart:203`, `:224`; `ui/team_status_page.dart:62`. No sub-page of a node's page calls it. |
| F8 | ✅ `server.go:31`, `:35`; `bluez.go:772-776`, `:412-418`; `session.go:868-874` (per session, counts `status` only). |
| F12 | ✅ `owner.rs:894`, `:949-972`, `:953-956`, `:353`, `:1077-1083`, `:1383`. |
| §4.9 | ✅ `ui/more_pages.dart:271` and the stale line near `:314`; `member_ui.dart:267` is `leaveFlow` (⚠️ I did not read to `:282`). |
| §4.4 "only the leave re-read sends `status`" | ❌ wrong: MINOR 1. |

## 5. Whole-design walk (real use)

| Path | Result |
|---|---|
| open page, wait, sub-page read, send | sound by reading; tests T1–T3, T17 |
| open page, tap at once | pays one F1 as today, then kept: MINOR 2 |
| lock the phone during a login | parked in the background up to 120 s: **M1 (a)** |
| reusable read from settings / team pages | parked off the node page: **M1 (b), (c)** |
| walk away / phone dies / app killed with the page open | node hidden 350–650 s with N1, maybe until reboot without: **M2** |
| Bluetooth off and on | closes at once (`radio()`), new round on return; T5, T4 (e) |
| node reboot, link down, frame while parked | T6, T7; second down source: MINOR 6 |
| second phone | cannot find the node while the page is open; stated, by the user's direction; ❌ not tested |
| second operation while one runs | refused as today (`lease.dart:136`); the wait in `acquire` does not change the order |
| lease taken back at 420 s | gate closes first, NodeLink forgets; T8 control can fail |
| two writers | none found: token only through `pass`; `keptRead` is the core's; the hook is the only parker of a lent link |
| compromised node | can only make the app close and reconnect (frame not parsed; 5 s limit); as today per round |
| person with the unlocked phone | today's rights without the wait; the owner key is not bound to user authentication (L, n1 F9), so nothing new |

## 6. Verdict

**APPROVE-WITH-CHANGES.** Before implementation: M1 (put the `keepFor` predicate back into the hook with the
two cases that make its control fail; delete the round-targets row) and M2 (state the cost and the order
against N1, add the on-site check). The MINORs are text, except 1 (device criterion for the update page) and 5
(decide the retry).
