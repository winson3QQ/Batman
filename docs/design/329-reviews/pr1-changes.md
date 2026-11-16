# #329 PR 1 — review fixes (review-pr1-A.md, review-pr1-B.md)

PR winson3QQ/Batman#339, reviewed at 75683ab, fixed in e2292f0. Each finding: what changed, the test that guards
it, and the mutation that shows the test can fail (`scratchpad/core/pr1fix/mutations.txt`, run with `mutate2.pl`
over all of `test/nodelink`).

| Finding | Fix | Guarding test (review_pr1_test.dart unless noted) | Mutation |
|---|---|---|---|
| A-M1 / B-M1 an older page's work goes on after the pop with no lease | `Lease.hold()`; the pages' `_busy` is `RawBusy.rawBusy` (held while busy, released by `rawIdle()` also after the page is gone; 420 s cap unchanged). A login that ends after the pop drops its link (nodes.dart). **ClaimPage gets no `PopScope`**: the hold keeps the radio exclusive; a PopScope would only trap the user for up to 90 s | `A-M1 / B-M1` group, `A-M1: an older page that is gone while busy…` (widget) | M-P, M-Y |
| A-M2 records written under a raw lease not reported | NodeLink compares the record list (id, mtime) before / after a raw lease and treats the difference as written | `RA-2 / A-M2` | M-C |
| A-M3 / B-M5 Bluetooth / permission / keys not wired, scan errors unhandled | AppLink: `ble.statusStream` → `bleStatusToRadio` → `NodeLink.radio`; startup `keys.login` → `keyOk`; prober `keyError` → `KeyAbilities.refusedBy` → `keyOk: false`; the gate's scan has `onError` / `onDone` (`ended`), NodeLink retries 2 s later | `RA-3 / B-M5 / T-L4`, `T-L5`, prober_test `B-M5` | M-E, M-O, M-S, M-T |
| A-M4 / B-M3 no single 8 s to msg2 | NodeLink starts one deadline at the connect (`due`), the connect and every step before msg2 race it and the cancel; `probe` no longer awaits the first write before the result | prober_test `RB-4 / RA-4`, `no frame … at the budget` (elapsed < 1 s), `A-M4: one 8 s budget…` | M-I, M-J, M-K |
| A-M5 / B-M2 a late record read un-leases the core; NodeLink uses the holder's token | `released`: when a lease is held again only `setRecords`, written ids wait; `LeaseRegistry.nodeLinkToken` is null while a lease is held | `RA-5 / RB-1` | M-A, M-B |
| B-M4 refused scan → microtask livelock | Refused → retry after 500 ms on the injected clock; the gate's refusal log keeps the last 200 | `RB-5 / B-M4` | M-F |
| B-M6 rules whose tests could not fail | slow-disconnect radio; msg2 test asserts the time | `B-M6a`, prober_test msg2 | M-X, M-J |
| A-m1 / B-m1 cut attempt overlaps the next | an attempt starts only when `gate.links == 0`, re-plans when the cut link is closed; `_run` closes only its own link | `RA-1 / RB-2`, `RB-3 / B-m1` | M-G, M-H |
| A-m2 / B-m5 M10 / M14 gate token checks unguarded | tests | `B-m5 / M10 / M14` | M-V, M-W |
| A-m3 / B-m7 lifecycle mapping untested | `NodeLink.lifecycle(AppLifecycleState)`; one app-wide observer in AppLink | `T20` | M-Q |
| A-m4 lease kept when the page is gone | released | — (main.dart; not unit-tested) | — |
| A-m5 NodeLink start failure → endless spinner | try / catch, the startup result stays | — (main.dart) | — |
| A-m6 release read without catchError | unreadable → the old list | `A-m6` | M-D |
| A-m7 older pages' scans not counted | `BleGate.noteScanStart()` from the pages and the recovery | `B-m5 / M10 / M14` | M-U |
| A-m8 monotonic 「上次讀取」 | `NodeLink.readWall` (wall time of each read) | — | — |
| A-m9 / B-m3 pump per advertisement | `core.onScan` returns whether the address is new this round; only then re-plan | `A-m9 / B-m3` | M-R |
| A-m10 exception after login = noResponse | `failed()` = broken after the login | prober_test `A-m10` | M-N |
| B-m2 session / record not freed | `s.dispose()`, record zeroed in `finally` | prober_test `B-m2` | M-M |
| B-m4 no message while acquiring | PR 2's `openUnderLease` shows 「正在結束上一個讀取…」 after 300 ms | — (PR 2) | — |
| B-m6 prober branches before login | tests | prober_test `B-m6` | — |
| B-m8 scan-slot wait outlives a cancelled round | not changed: costs one scan start, stopped one pump later (reviewer: harmless) | — | — |
| A-m11 PR body deviations incomplete | PR body rewritten | — | — |
