# #329 N1: a node drops a connected device that never talks (plan v5.1, node part only)

Refs #329 (issuecomment-6981729272). Reviews so far: v2 (`329-reviews/review-n1-plan-v2-A.md`, `-B.md`) and v3 (`-v3-C.md`, `-v3-D.md`), all APPROVE-WITH-CHANGES; then v4 (`-v4-E.md`, `-v4-F.md`), also APPROVE-WITH-CHANGES. The reviewers of v3 and v4 found no fault in the product change (§3); their MAJORs were in the tests. F built §3 and the unit tests in a copy: `go vet` clean, `go test -race` PASS. v5 (`-v5-I.md`, `-v5-J.md`): APPROVE-WITH-CHANGES, no BLOCKER / MAJOR; J's own build of §3 passes T1–T10 under `-race`, with a mutation table. v5.1 folds their MINORs in. §7 lists what changed. N3 (advertise while connected) is dropped: an ordinary Bluetooth device is not discoverable while connected either. The app part (kept session) is a separate plan.

## 1. Facts

| # | Fact | Evidence |
|---|---|---|
| F1 | 04 was invisible from 21:57 to past 22:36 on 2026-11-18 with nobody using it. provd logged `adv withdrawn reason=connect` and then no `connection ble` and no `adv registered`; BlueZ showed the S20 `Connected: yes`; the S20 had torn every ACL down (`dumpsys bluetooth_manager`, last `teardown_time` 21:59:26). | #329 comment above; session log |
| F2 | `converge` keeps the advert withdrawn while `len(b.links)+len(b.devConn) > 0 \|\| Sessions() > 0`. | `bluez.go:733`, `:772-776` |
| F3 | `devConn[p]` is set / cleared only from BlueZ's `Device1` signals, sender-checked (`:691`), in the run loop; it is reset at `:491`. | `bluez.go:688-729`, `:491` |
| F4 | A `links` entry is made only on an RX write / AcquireWrite / AcquireNotify (`link()`), and removed in `bleLink.Close` (`:412`), which also calls `Device1.Disconnect` and ignores its result (`:416-418`). A STATUS / ctrl read makes none. `Close` can run on the fd-watch goroutine (`:322-334`), so its order against the `Connected=false` signal is not fixed. | source |
| F5 | `register()` calls `staleLinks()` first; `staleLinks()` disconnects every `Connected` device that is not in `links` (no age check), outside `b.mu`, up to 3 rounds × 5 s; it logs `disconnected N stale link(s)` unlimited. | `bluez.go:583-600`, `:518-567` |
| F6 | The converge loop runs on every device signal, server change, kick, and at least every 5 s. | `bluez.go:656-681` |
| F7 | `bluetoothctl disconnect` (= `Device1.Disconnect`) cleared F1's state on 04: `Successful disconnected`, `Connected: no`, `provd: adv registered reason=disconnect`, `ActiveInstances: 0x01`. One occurrence; raw output is posted to #329 with the PR. | session log 2026-11-18 ~23:40 |
| F8 | When the controller does not answer a disconnect, the kernel drops the connection itself after about 2 s and reports it (`hci_abort_conn_sync`); with no kernel connection mgmt answers ENOTCONN and BlueZ still marks the device disconnected. | kernel 6.6.138 `hci_sync.c:5651-5701`; BlueZ 5.72 `src/adapter.c:8496-8519` (review B) |
| F9 | Every app client writes RX within seconds of connecting: the prober allows 8 s to msg2 (`app/lib/src/nodelink/prober.dart:123`); the claim page has no user step between its STATUS read and msg1 (`app/lib/claim.dart:335-370`, `:497-530`; the owner-key signature does not prompt: no key in the app is bound to user authentication, review E); no page in `app/lib` connects and then waits for a person (the old console page is gone, `app/lib/ui/settings_page.dart:2`). Measured on the S20: below 9 s. | source; #329 comment (4.1 s / 8.6 s) |
| F10 | Harness centrals that keep a link without a session: `prov-p2-central-254.sh` `hold` (first `pick`, which does one full `read_one` connection of 23–26 s and drops it, `:156`, `:133-137`; then its own connect with retries, returning up to 16 s after the connect command; the held link's real age is then anywhere in 0–16 s and is not printed, `:155-167`. So one `hold` makes 2 or more `adv withdrawn reason=connect` lines on 04) and `read` (`read_one`, about 23–26 s, `:112-124`). Users: `prov-provd-254.sh` (`hold02` at 99–106, 125–137, 192–200; `read` in several arms), `prov-netjoin-254.sh:63`, `chain1-254.sh:168`, boot-provd, sec-dbus, rpa, wbox. The L80 control arm (125–127) needs the link still up after `watch 15`: up to about 32 s old. `read`'s 8 s after CTRL is measured and needed by the wbox encrypt-read arm (`:116-117`). | source (reviews A, B) |
| F12 | A link with no session still makes provd log `adv withdrawn reason=connect`: `converge` counts `devConn` (`bluez.go:733`, `:772-776`), and the existing arm `prov-provd-254.sh:99-102` asserts the line for a `hold`. | source; existing arm |
| F11 | sock and BLE sessions share `Sessions()` (`server.go:835-845`); sock and BLE serving are exclusive in `main.go:88-100`. | source |

Not known ❓: why BlueZ / the BCM43455 never saw the disconnect in F1. Nothing was tried to reproduce it (§5 "Not tested"). The node must recover without that answer.

## 2. Scope (from the field)

"A device is `Connected` on the node and holds no session":
1. A phone whose link dropped without the node hearing it (F1). Cause unknown; candidates are out of range, Bluetooth off, app killed.
2. A stranger or a scanner app that connects and idles.
3. A phone whose session ended but `Close`'s Disconnect failed (F4).

After the change the node is dark for at most **about 50 s** in these cases (30 s grace + up to 5 s tick + up to 15 s `staleLinks`), instead of forever.

Not handled here, stated plainly:
- A link that goes silent **during** a session: the session's own limits run first (`IdleAnon` 30 s; `IdleAuthed` 300 s, counted again after a request in flight ends, `session.go:287-289`, `:611-615`; a helper wait up to 330 s), then this rule. Usually about 350 s dark, at worst about 650 s (read from the code, not measured). Today every page but one closes its session within seconds (`OpSession.once`); the software-update page keeps one for as long as it is open (`OpenSession`, `update_route.dart:28`). So this case exists today on that page, and becomes the common one once the app keeps a session per node page; the idle limit is decided in that plan, not here.
- A peer that reconnects every 30 s keeps the node dark (today one connect does it forever).
- bluetoothd itself hung: Disconnect never returns; the existing retry goes on (below).

## 3. Change (provd, `cmd/batman-provd/bluez.go` only)

1. `devConn` becomes `map[dbus.ObjectPath]*devEnt`, `devEnt{since time.Time; logged bool}`. One map, so a time without a device (or a device without a time) cannot exist. `since` comes from `time.Now()` and is compared with `time.Since` (monotonic; the node's wall clock jumps when GPS / NTP sets it).
   - `Connected` turns true for a path with no entry → new entry, `since = now`. An entry that exists is not touched.
   - `Connected` false / interface removed → entry deleted. `:491` reset → empty map. (Unchanged places, new value type.)
   - `bleLink.Close` (`:412`): **if** the device still has an entry, `since = now`, `logged = false`. No entry → nothing is written. The refresh is needed: `Close`'s own Disconnect takes up to 2 s (F4, BlueZ timer), and without it a session that lasted over 30 s would be logged as "without session" in that window. It gives a peer nothing: a device with a `links` entry counts at any age anyway.
   - The `:491` reset becomes a small function (`resetDevs`) so the test can call it.
2. `liveLinks(links, devConn, now) (n int, stale []dbus.ObjectPath)`: `n` = devices in `links` + devices in `devConn` that have no `links` entry and are younger than `linkGrace = 30 s` (each device once; today's `len+len` counts a device with a link twice, which only matters as zero / non-zero); a `devConn` device with no link and older is stale. `converge` uses `n` instead of `len(b.links)+len(b.devConn)`. `countLocked(now)` (called by `converge` and by `register()` under `b.mu`) calls `liveLinks`, sets `logged` on each stale entry that is not yet logged and returns how many it set; the caller prints `provd: link without session for 30 s` (no address) that many times after unlocking. So the line comes once each time an entry becomes stale (`Close` starts the time again).
3. With `n == 0` and no session, `converge` reaches the existing `!advOn` case → `register()` → `staleLinks()` (existing; disconnects it outside `b.mu`). After `staleLinks()` returns, `register()` counts again and returns without registering if a device now counts (a client that wrote RX in that window; the next tick handles it as a normal connect). This recount has no test (❌, §5). When that happens on the `rpa_timeout` path, the later register is logged with `reason=disconnect`; noted in the log contract.

Nothing else changes: no new Disconnect call site, no new timer. A stale device while another session is live (BLE or sock, F11) is left until that session ends: it holds no slot, the advert is withdrawn for the live session anyway, and `register()` is where the existing disconnect lives. (v1's reviewers asked for "per device, not global `Sessions()`": the age is per device; only the moment of the disconnect follows the global state, for this reason.)

If Disconnect does not clear it (bluetoothd hung; F8 says the kernel side cannot keep it): `register()` still tries `RegisterAdvertisement`; if the kernel accepts, the node advertises again and the leftover device is tried again at the next register (`rpa_timeout`, 930–1020 s); if the kernel refuses (F-P41, not measured on this chip) `advOn` stays false and each tick repeats `staleLinks` (up to 15 s) + register: one `disconnected N stale link(s)` line about every 20 s (the register-failed line is already deduplicated by `logLimit`). That is 3 lines a minute, inside the existing contract ("連線事件 log 同 reason 每 60 s 最多 10 行", `254-p2-impl.md` §4.4), so the log code is not changed (v3's `logLimit` idea is dropped: `logLimit` keeps one slot, `bluez.go:617-625`, and would have hidden legitimate repeats). No escalation is added.

## 4. Interfaces

**Ownership.** `devConn` (with its `since` / `logged`), `links`, the advert: `bleSide` only, under `b.mu`. Writers of `devConn`: `deviceChanged` (run loop), the `:491` reset, `bleLink.Close` (only `since` / `logged` of an existing entry), `countLocked` (only `logged`). BlueZ is the only source of `Device1.Connected`.

**Contracts.**
- New log line `provd: link without session for 30 s`: written once each time an entry becomes stale; read by the new harness arm and by the L80 arm's INVALID rule. Added to the log contract in `254-p2-impl.md` §4.4 (`:227`) in the product PR.
- `adv withdrawn reason=connect` / `adv registered reason=disconnect`: unchanged for any link that writes RX within 30 s or lives less than 30 s.
- A dropped or reordered signal (godbus under load) leaves a wrong entry for at most the grace time, then the stale path cleans it. Today it is dark forever.

**Lifecycle.**

| Path | Today | After | Test |
|---|---|---|---|
| first run / provd start with a leftover link | `staleLinks` on app register | same | existing |
| connect → session → close | withdraw; `Close` disconnects; register | same | existing `prov-provd-254.sh` |
| connect, no RX write, link stays (STATUS read or nothing) | dark forever | dropped; advert back within about 50 s | unit T2; device arm §5.2 |
| session ended, `Close`'s Disconnect failed, link stays | dark until the phone lets go | one more grace, then dropped | unit T4 |
| `Connected=false` before `Close` (other goroutine), same path connects again later | — | new entry, fresh grace (no orphan time) | unit T5 |
| link silent during a session | dark until the session idles out, then forever | session limits (usually ≤ 300 s, worst about 600 s) + about 50 s | not changed here; unit T6 covers the count only |
| stale device + another live session (BLE / sock) | dark (correct) | dark; cleaned after the session | unit T7 |
| Disconnect does not clear the device | dark | advert accepted: visible again, the device retried at the next register; advert refused: dark, retried each tick, 3 log lines a minute | ❌ not tested (cannot be induced) |
| clean stop (`quit`) | advert withdrawn, links closed | same; map dies with the process | existing |
| bluetoothd restart | map reset, app re-registered | same | unit T8 |
| dbus restart / signal lost | stale `devConn` may stay: dark forever | self-heals after the grace | unit T2 (same state) |
| provd restart / crash loop | `staleLinks` at start | same; no state on disk | existing |
| node reboot / power loss | nothing kept | same | — |
| a `Connected=false` signal lost, the device really gone | entry stays: dark forever | entry goes stale; `staleLinks` asks BlueZ, which no longer lists it as connected, so nothing is cut; the entry stays `logged` and uncounted until the path connects again or the map is reset | unit T2 (same state) |
| stale device while provd's health is not OK / serving is off | dark | the line is logged; no cut until `converge` next reaches `register()` | ❌ not tested |
| OTA / rollback / downgrade | — | old version = today's behaviour; no stored state | device: the image 04 runs before the OTA is the negative control |
| old app / new app, sock / HTTP clients | — | no protocol change | existing suites |
| bcm2711 | — | same code | device (04) |
| bcm2710 | — | not run: Pi 3 not supported for now (2026-10-23) | — |

**Assumptions.** F2–F6, F8–F11 are source lines. F7 is one observation of a link in F1's state. The device arm (§5.2) uses a live link held by 02; it shows the grace and the cut, not F1's cause.

**Security.**
- Asset: the node's availability to its owner. Actors: a remote radio peer, a local unprivileged process, our own mistakes.
- Attack-surface delta: none. No new input; `Connected` still comes only from the sender-checked BlueZ name (`:691`), so a local process cannot fake it. Privilege unchanged (provd already calls `Device1.Disconnect`).
- A remote peer: one idle link no longer darkens the node for good; it must reconnect every 30 s. It can be cut 30 s after connecting if it never writes RX. With one map there is no state a peer can pile up beyond BlueZ's own device list.
- No legitimate client waits 30 s before its first RX write (F9). The Windows test bridge subscribes to TX right after connecting (`tests/tools/peer/blebridge.py:77-78`), so it has a link at once.
- Fail mode: every error path ends in "still counted" or "retry", never in a session being cut: a device with a `links` entry is never stale.
- Negative test: the device arm with a non-owner central (02 holds no owner key for 04's session).

## 5. Tests (each fails without its part of the change)

1. **Go unit tests** in `cmd/batman-provd` (run by CI `go test ./...`, `ci.yml:141`). A `bleSide` from `newBLE` with no bus connection (`Close` does not touch D-Bus when `conn == nil`, `:414-418`). The test sets `bluezName` and each signal's `Sender` itself (otherwise `deviceChanged` drops the signal at `:691` and the test passes empty; each row first asserts the entry it expects exists). Events in order: hand-made `*dbus.Signal` to `deviceChanged`; a `links` entry inserted directly (calling `link()` would need `srv.Accept`); `bleLink.Close`; `resetDevs`; then `liveLinks` at a given time.
   - Time is moved by passing `now` to `liveLinks` / `countLocked` or by setting an entry's `since` back; no clock interface.
   - T1 fresh device, no link → counted. T2 31 s later → stale; `countLocked` returns 1, then 0 on the next call. T3 device with a link → counted at any age, n = 1 (not 2).
   - T4 link closed, device still connected → counted for 30 s more, then stale. At the end of T4 the entry's `logged` is false again (control: `Close` not clearing `logged`). T5 `Connected=false`, then `Close` → asserts there is no entry for the path; then the same path connects 60 s later → counted (control: an unconditional write at `:412` makes this FAIL).
   - T10 a second `Connected=true` signal for an existing entry at 20 s → stale at 31 s (control: overwriting the entry makes this FAIL; review F's mutation showed no other row catches it).
   - T6 a link whose session is still open → counted at any age. T7 stale device + a link of another device → n = 1, stale listed. T8 `refreshOwner` with a changed owner → empty (control: `resetDevs` emptied, or not called). T9 a link with no `devConn` entry (signal lost) → counted.
   - T11 a `Connected=true` signal from another sender → no entry (control: the sender check removed; J's mutation showed no other row catches it).
   - Controls: each row is run once with its write point or the age rule removed and must FAIL; the mutation table is in the PR.
   - Not covered by unit tests: `link()` itself (no harness central writes RX; the S20 step in item 5 covers it), `converge → register → staleLinks` (the device arm), that `converge` uses `n` and prints the line (the device arm), the recount in `register()` and "Disconnect fails, advert still tried" (both ❌ not tested: they need a bus and a server).
2. **Harness PR first (#290)**, `scripts/dv/prov-provd-254.sh`, unit `boot-provd` (suite `prov-boot-provd-254`; its description at `scripts/daily-validation.sh:310` is updated with it). New arm "link without session". The grace is judged on 04's own log, where both ends are timestamped by the same clock (F12); the central only confirms. The arm's and the unit's measured run time (old image and rc) go into the PR, and `lease` (`:80`) is raised if the unit then leaves under 300 s spare.
   - Place: after the existing hold arm (`:99-106`), before `j stop` / `j flip`. A log mark is taken on 04, then 02 `hold`s 04 and `watch 70` runs; 04's log is read once after that. Times are taken from `logread` lines as seconds of the day; a run that crosses midnight is handled as at `:251`.
   - The line is matched with the anchored ERE `provd: link without session for 30 s$`.
   - t1 = the new `link without session for 30 s` line. Exactly one is expected. Two or more on an rc = FAIL (a product fault: the line must come once per stale entry), not a rerun.
   - t0 = the last `adv withdrawn reason=connect` line before t1 (F10: the earlier ones belong to `hold`'s own read and retries). An `adv registered` line between t0 and t1 = INVALID. No t1 and an `adv registered` line less than 29 s after the last withdraw = INVALID (02's link dropped by itself), on any image.
   - PASS needs 29 ≤ t1 − t0 ≤ 37 s (30 s grace; the entry's time starts just before the t0 line is written and `logread` prints whole seconds, so 29 can show; + up to 5 s tick + rounding). Under 29 = the grace is not there, over 37 = the claim in §2 is wrong. The 29 relies on the withdraw taking under 1 s; if a run shows 28, stop and report instead of widening. The log's clock is the wall clock: a clock step during the arm gives a FAIL that prints both lines; the 5 runs' values are in the PR.
   - Then `adv registered reason=disconnect` within 20 s of t1 (`staleLinks` ≤ 15 s), then one advertising instance (checked after that line), and 02's `watch 70` printed GONE (`Connected: no` or the object gone).
   - Then `c02 read` succeeds: the node can be found and connected again, which is the user's symptom.
   - No `link without session` line: on an image whose version is in `scripts/dv/pre-n1-versions.txt` (the existing `pre-*-versions.txt` way, `prov-p3-verbs-254.sh:50-55`) the arm prints the one fixed line `no 'link without session' line in 70 s (pre-N1 image)`, which is what the known-failures entry matches, and it is the arm's only FAIL line there: the t0 / t1 timing, `adv registered reason=disconnect`, `watch`'s GONE and the later `c02 read` are not judged (on that image the link stays until the drop). On any other image it prints a different plain FAIL, so an rc that lost the change is never KNOWN. The drop and the one-instance check below always run. A version alone is enough to tell: every image on that list was built before the change existed. The list holds every pre-N1 version 04 can run during this work (its current image and main's pin); at each pin bump before N1 ships, the new version is added in a harness PR.
   - Offline cases for the arm's exits (PASS, under 29, over 37, two lines, INVALID by `adv registered`, pre-N1 fixed line, unknown-image FAIL, midnight) go into `scripts/test-dv-ble-254.sh` with canned log text, as its existing good / bad cases.
   - Every exit path runs `c02 drop` (harmless after `watch`, which drops by itself) and checks 04 is back at one instance (a leftover link breaks later suites, central script `:33-36`).
3. Same harness PR, existing arms (F10). Nothing that an arm was written to prove is removed:
   - `read` is not changed (its link lives about 23–26 s, under the grace; its sleeps are measured ones).
   - Guard, one shared function in `scripts/dv/prov-254.sh`, for every arm that makes a sessionless link: the `hold` arms (`boot-provd` `:99-106`, L80 control and kill, `sec-dbus`'s hold `:192-200`) and the `read` users (the arms of this file, `prov-provd-wbox-254.sh:112`, `:119`, `:229`, `prov-netjoin-254.sh:63`; a `read` link is 4–7 s under the grace). `chain1-254.sh:168` does not source `prov-254.sh` and runs its reader in the background, so it gets no guard; its reads are the same 23–26 s `read`. The guard takes a log mark before the arm and reads after it: if 04 logged a new `link without session` line during the arm, the arm is INVALID with that reason, never a silent pass or fail.
   - L80 control arm: `watch 15` → a shorter watch. With 15 the link can be 32 s old at the STILL assertion, past the grace. The value is the larger of 8 and 5 whose measured worst link age (5 runs, below) stays at or under 25 s; if 5 does not fit either, stop and report. `sec-dbus`'s hold (`:192-200`) also uses `watch 15` and gets the same value. The arm's job is "an untouched provd does not drop the link", which 5 s still shows; the kill arm's own checks (GONE within 15 s of the kill and the new process's `disconnected N stale link` line) are unchanged.
   - L80 kill arm: covered by the shared guard (a `link without session` line before the kill means N1 cut the link, not the restart); its `disconnected N stale link` line must be later than the kill.
   - The link age of `hold` + the watch (at `:99-106`, the L80 arm and `:192-200`) and of `read` is measured 5 times on 04, as the time from the arm's last `adv withdrawn reason=connect` line in 04's log to the moment the arm's assertion reads the link state (the harness prints both), and the maximum goes into the PR (02's bluetoothctl retries make one run unrepresentative).
   - `scripts/dv/data/p3-units.tsv:11` and `tests/tools/peer/blebridge.py:16-17` quote `bluez.go` line numbers. The harness PR does not need them changed; after the product PR merges, a harness PR (the one that removes the known-failures entry) updates both (comment-only line references; nothing parses them).
4. **Order (#290: a new check FAILs on the old image and PASSes on the rc).** The product branch is built to an rc first (unmerged). The harness branch is run on 04 **before the OTA** on the image it has then (read from the node; expected wsl.26, which goes into `scripts/dv/pre-n1-versions.txt`): the new arm FAILs with the fixed line. Then the OTA, then the same branch on the rc: PASS. Both outputs are in the harness PR. Until the product PR merges and the pin moves, the arm has a known-failures entry (#329, expiry 14 days; the FAIL text avoids the NEVER_KNOWN words). After the pin bump a harness PR removes the entry. #329 stays open until then.
5. Full `daily-validation` on 04 with the rc; then on the S20: read 04 from the app, and keep the software-update page of 04 open for 90 s or more (a session that outlives the grace, through `link()`). PASS: 04 logged no `link without session` and no `stale link` line in that time (this is the part that decides), and the page stayed connected. This is the only check of "a link with a session is not cut" on a device.

Not tested, stated plainly:
- A phone that really goes radio-silent. It cannot be made by script: the node image has no `hciconfig` / `btmgmt` / `rfkill`, and `bluetoothctl power off` disconnects cleanly. For provd the input is the same as the arm's (a `Connected` device with no session). One manual check goes on the on-site list (the user's phone connected, then out of range or Bluetooth cut by airplane mode); it does not gate the PR.
- Disconnect failing; the kernel refusing the advert while a zombie link exists (F-P41, `le_states`).
- The #329 checklist line is ticked ⚠️ ("stand-in central"), not ✅.

## 6. Steps

this plan → two reviewers (whole document) → provd change + unit tests on a branch → rc image → harness branch on 04's current image (new arm FAIL) → 04 OTA (asks the user first) → harness branch on the rc (PASS, timings) → harness PR with a known-failures entry → the user merges it → full suite on the rc + the S20 step → product PR (with `254-p2-impl.md` contract lines, F7 raw output on #329) → the user merges → pin bump validation → harness PR removing the known-failures entry and updating line refs → tick #329 ⚠️.

## 7. Changes

From v5 (reviews I, J; MINOR only):
- New arm: INVALID when 02's link drops by itself; what is skipped on a pre-N1 image; anchored match; two lines on an rc = FAIL; place and time handling; offline cases; the 29 s bound's condition (I-m1, m2, m9; J-m5, m6, m8, m9).
- Guard: lives in `prov-254.sh`, lists the wbox lines, not on `chain1`; replaces the kill arm's pid rule; `sec-dbus`'s watch; how link age is measured (I-m3, m4, m5; J-m7).
- Unit rows: T11 sender, T8 through `refreshOwner`, `logged` cleared in T4, T5's middle assertion (I-m6; J-m1, m2, m3).
- `pre-n1-versions.txt` content and upkeep (I-m7; J-m4). Lifecycle rows for a lost `Connected=false` and for health not OK (I-m8; J-m10). Wording (I-m10; J-m10).

From v4 (reviews E, F):
- New arm: t0 is the last withdraw line before the one stale line, with INVALID rules; lower bound 29; one log read after the watch (E-M1, F-M1, m1).
- The fixed FAIL line only on images in `pre-n1-versions.txt`; the entry is removed by a harness PR (E-M2). FAIL run before the OTA (E-m5, F-m5).
- `countLocked` named as the place that marks `logged`; T2 tests it; contract wording (F-M2, E-m3, E-m9).
- S20 step: update page open 90 s, as the device check of a link with a session (F-M3). The `register()` recount is marked not tested (E-m4).
- T10 for "an existing entry is not touched" (F-m6). Guard shared with the `read` users (E-m6). L80 watch value from measurement (F-m2). Run times measured, not estimated (E-m2, F-m3).
- Lifecycle row for a Disconnect that does not clear (E-m7); `blebridge.py` line refs (E-m8); F9 / Windows client ⚠️ closed by E; F10 says `hold` reads first.

From v3 (reviews C, D):
- New arm: the grace is measured on 04's log (30–37 s between two of its own lines), not as a link age from the central, which the central cannot report (C-M2, D-M1). Unit name, one fixed FAIL line, lease budget.
- `read` is left alone; an INVALID guard is added to the hold arms instead (D-M2, C-m1, C-m2). `watch 8` reason written (C-m3, D-m4).
- §2: the update page keeps a session today; the bound is about 350 s usual, 650 s worst (D-M3).
- The `logLimit` change is dropped; the repeat rate is inside the existing contract (C-M1, D-m1).
- The `hciconfig` reproduction is dropped: not possible on the image, and `power off` is a clean disconnect (C-M3). A manual on-site check replaces it.
- Unit tests: links inserted directly, sender set by the test, union count rows T3 / T9, `resetDevs` listed as a product change (C-m4, C-m6, D-m6). `Close`'s refresh: why it is needed and why it gives a peer nothing (C, D).
- F8 line, F9 path, F10 wording, F12 added.

From v2 (reviews A, B):
- One map with the time inside; `:412` writes only an existing entry; T5 is its control.
- Unit tests drive the write points in event order.
- Lifecycle rows corrected and added; time bound about 50 s.
- Harness: L80 arms, drop on every exit, final `read`, #290 order with a known-failures entry.
- Recount after `staleLinks`; monotonic time; log contract line; the dev raw console sentence removed.
- No reproduction of F1 was tried before this plan.
