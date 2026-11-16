# #329 PR 1 (winson3QQ/Batman#339, feat/329-pr1 @ 75683ab) — independent review B

Emphasis: security per actor, the prober's trust boundary and secrets, concurrency between NodeLink / BleGate /
leases / the older pages, negative controls run in my own copy.

Scope reviewed: lease.dart, record_writer.dart, ble_gate.dart, ble_backend.dart, node_link.dart, prober.dart,
app_link.dart, node_list.dart, main.dart / scan.dart changes, owner.rs `login_end_kind` + frb glue, the four new test
files, PR body. The scheduler core (core.dart) was read only where the driver uses it.

Copy used: `scratchpad/core/pr1B/app` (lib identical to the PR: `diff -r lib` empty). Reviewer tests are in
`scratchpad/core/pr1B/keep/` (`rb_negative_test.dart`, `rb_prober_test.dart`, `rb_loop_test.dart`); nothing in
`C:/src/Batman-329pr1` was modified.

Baseline in my copy: `flutter test --no-pub test/nodelink/node_link_test.dart lease_test ble_gate_test prober_test`
→ `00:03 +29: All tests passed!`

## Verdict: REJECT (revise and re-review)

Counts: BLOCKER 0 / MAJOR 6 / MINOR 8.

The building blocks (registry, gate, RecordWriter, Rust pass-through) are sound and the prober's mapping respects the
trust boundary. The problems are in the seams: the stated reason why the deviation "older pages under a raw lease"
is safe does not hold, the driver can let NodeLink run while a lease is held, it has an overlap between a cut attempt
and the next one, the prober has no deadline before msg2, a gate refusal turns into a microtask livelock, and the
radio preconditions (Bluetooth / permission / keys) are not connected at all.

---

## MAJOR

### M-1 The raw lease ends when the page is popped, but the older pages' Bluetooth and record work goes on afterwards: two Bluetooth users and an unleased record writer

**Scenario.** The user starts 「認領」 in ClaimPage and presses back while it waits for the node (up to 90 s), or
presses back while 「我的節點」 is in its 60 s login loop. `_open` (main.dart, new) calls `lease.pageGone()` after
`Navigator.push` returns. A raw lease is never `busy` (no page calls `lease.run`), so `pageGone` releases at once
(lease.dart:56-61). `NodeLink.released` reads the records at once and starts a round 6 s later. The older page's
work is still running:

- ClaimPage `dispose` does not stop a claim on purpose (claim.dart:84 comment "a claim/finish in flight is not
  interrupted"; `_claim` claim.dart:313-462 goes on with `_find`, connect, the 90 s wait and
  `records.claimed(...)` writes the node record).
- NodesPage `_login` (nodes.dart:352-408) keeps scanning and connecting for up to 60 s after `dispose` (`_drop()`
  only cancels the current `_conn`). A connection that comes up after `dispose` is never cancelled.

What happens:
1. Two scans on the one shared `FlutterReactiveBle`. flutter_reactive_ble 5.6.0 `device_scanner.dart`
   `_scanStreamDisposable.set(scanRepeater)` disposes the previous scan's repeater when a new scan starts, so
   NodeLink's scan silently ends the older page's scan (or the other way round). `GateScan` has no `onDone`, so
   NodeLink does not notice when its own scan is ended.
2. Two GATT users. Cancelling a connect subscription calls `_blePlatform.disconnectDevice(id)` (device_connector.dart:74),
   which drops the platform link for that device for everyone on the instance.
3. A record written with no lease. The claim writes `node/<id>` after the release. NodeLink has already re-read the
   records, so the newly claimed node does not appear in the list until the next lease release or app restart.
4. A login that completes after `dispose` keeps a connection open. The node does not advertise while it is
   connected (N1), so NodeLink shows it as 「手機連不到節點」 until the node's 300 s idle timeout (N2).

The PR body says 「整頁持有原始佔用：這段時間自動讀取完全停下，所以仍然只有一個藍牙使用者、一個寫入者」. That holds only
while the page is open. Design §4.4 already covers this case: the 原始佔用的頁面 row asks that every Bluetooth or
record-writing async task be wrapped in `lease.run(…)`, and that ClaimPage get a `PopScope` while a claim runs,
precisely because of F41. The deviation removed both measures without replacing them.

**Evidence.** lease.dart:56-61. main.dart `_open` (`lease.pageGone()` right after `push`). claim.dart:84 and
:313-462. nodes.dart:165-172 and :352-408. pub-cache flutter_reactive_ble-5.6.0 lib/src/device_scanner.dart (the
`_scanStreamDisposable.set` line) and lib/src/device_connector.dart:74.

**Fix (minimal, no rewrite of the old pages).** Pass the lease into the three pages and wrap their long-running
async entry points (`_claim`, `_recover`, `_login`, `_ask`, ScanPage's scan) in `lease.run(...)`. `pageGone` then
keeps the lease until the work ends (X19), with the 420 s cap. Add the design's `PopScope` to ClaimPage while
`_busy`. Correct the PR body. **Negative control:** a widget test that pushes ClaimPage with a fake claim that
never completes, pops it, and asserts that `reg.current` is still non-null and that NodeLink did not scan 7 s later.
It fails on the current code because the lease is gone at the pop.

### M-2 A release whose record read finishes after a new lease was taken un-leases the core; NodeLink scans during the new lease, and the gate lets it

**Scenario.** Lease L1 is released, and `NodeLink.released` starts `readRecords()` (an async FFI `listNodes` plus
file stats). Before that read returns, L2 is acquired (another page, or in PR 3 a flow that chains leases).
`core.acquireLease` sets `lease = true`. The read then returns and `core.releaseLease` sets `lease = false` and
`leaseDue = now + 6 s` (core.dart:243-260, unconditional). Six seconds later NodeLink starts a round while L2 holds
the radio. The gate does not stop it, because NodeLink passes `reg.token` (node_link.dart:146, :163) and `reg.token`
is whatever token is current, here L2's. The token check in BleGate therefore never separates NodeLink from the
lease holder (design §4.1: NodeLink's token only when no lease is held).

**Negative control (mine, `keep/rb_negative_test.dart` RB-1)**, on the PR's code:
```
RB-1 ... [E]  Expected: true  Actual: <false>  the core must still know a lease is held
(variant asserting (core.lease, extra scans, roundsRun)):  Expected: (true, 0, -1)  Actual: (false, 1, 2)
```
So NodeLink starts a real scan while 新增節點 holds the lease.

**Fix.** In `released`, after the read: if `reg.current != null`, only `core.setRecords(recs)` and return. Also take
NodeLink's token only when `reg.current == null` (or keep a NodeLink-owned token that the registry invalidates on
acquire), so that the gate also refuses. **Flip:** with the guard (1 line) RB-1 passes, and all 164 nodelink tests
plus my RB tests pass (`00:06 +164: All tests passed!`).

### M-3 SessionProber has no deadline before msg2: a device that accepts the connection and then stalls GATT holds the one link until the 90 s cap

**Scenario (nearby attacker or misbehaving device).** A device advertising the provd UUID accepts the connection.
`probe` then awaits `openRecord`, `requestMtu`, `read(ctrl)`, `frameLimit` and `ownerPub` (prober.dart:247-251)
with no timeout and without watching `cancelled`. The 8 s msg2 timer (:307) starts only after all of these. If the
MTU exchange or the ctrl read is never answered, the probe never returns. NodeLink's `_run` (node_link.dart:176)
has no outer deadline either, so the attempt ends only when the core cuts it at the round cap (90 s). Each round,
one stalling address uses up the whole round. Design §4.3.3-3 and §4.3.7 say "從開始連線到收到 msg2 最多 8 s" and
"不回應的位址每輪最多花 8 s". §8's claim that recognised own nodes are not affected (T-L14: 12 silent fake
addresses, both own nodes read within 40 s) relies on that driver contract. On a real stack the ATT transaction
timeout (30 s, Bluetooth spec) may end it sooner. That is still about 4× the budget, and whether
flutter_reactive_ble then fails the pending future is ⚠️ not verified.

**Negative control (mine, `keep/rb_prober_test.dart` RB-4)**: a radio whose `requestMtu` never completes, msg2 = 50 ms:
```
Expected: not 'HUNG'   Actual: 'HUNG'   probe still running 2 s after a 50 ms msg2 budget
```

**Fix.** Start the msg2 deadline when the link is up: race the whole pre-msg2 sequence against the timer and
against `cancelled` (for example a `Future.any` over the pre-steps, the result completer and the deadline). Or,
more simply, give `_run` one deadline per attempt measured from connect: connect plus pre-steps plus msg2 ≤ 8 s.
The 8 s connect budget at :166 and the prober's own 8 s also add up to 16 s; the design budget is a single 8 s.

### M-4 A gate refusal of NodeLink's scan becomes a microtask livelock that freezes the app

**Scenario.** `_startScan` catches `Refused` and then `finally` → `_pump()` → `_startScan()` again, with no await on
a timer in between. `gate.scan` throws synchronously inside an async function, so the loop is made only of
microtasks. Timers and platform replies never run, including the platform reply that would finish the previous
scan's `stop()` and clear the condition. `gate.refused` also grows by one line per turn. The trigger is any
`Refused` from `gate.scan` while a round is active, for example "a scan is already running" while the previous
`GateScan.stop()` is still waiting for the platform's cancel reply: background/foreground in quick succession, or
a Bluetooth stack that is slow or wedged on stopping a scan when the next round starts.

**Negative control (mine, `keep/rb_loop_test.dart` RB-5)**: the scan's cancel takes 20 ms; `background(); foreground();`
then `await Future.delayed(100 ms)`:
```
01:56 +0: Some tests failed.      (killed by my outer `timeout 120`; the test's own 30 s timeout never fired,
                                   the 100 ms delay never completed, and the "RB-5 waited" line was never printed)
```
Control with 100 ms between background and foreground: `RB-5 waited 102 ms; refusals logged: 0; scans 2 / +1: All
tests passed!`. The hang comes only from the refusal loop.

**Fix.** On `Refused` from `scan` (and from `connect`), do not re-pump synchronously. Schedule a retry with
`after(…)` (e.g. 500 ms), or let the round go without a scan. Also bound or ring `gate.refused`.

### M-5 Bluetooth off, permission revoked and keys unusable are never reported to NodeLink: the overlay (§4.3.3-1, 2.2 / 2.3 / 2.4) is dead code, and a scan error is unhandled

`NodeLink.radio(...)` has no caller in `lib/` (grep: only its definition, node_link.dart:85). Nothing listens to
`ble.statusStream` or checks permissions for NodeLink. `GateScan` subscribes with `backend.scan().listen(seen)`
without `onError` or `onDone` (ble_gate.dart:366).

User-visible result:
- Bluetooth off: scans error out (unhandled async error) and every connect fails. After two rounds each node shows
  the orange 「手機連不到節點：可能沒開機、還在開機、離太遠…」 instead of 「藍牙沒有打開」 (§7: 「立刻顯示 2.3」).
- Permission revoked while records exist: the same wrong reason (§7 T-L5: 2.2). The design's 「`BleGate` 在權限沒了的
  期間拒絕新的掃描與連線」 is not implemented either.
- Keys become unusable (X26): Kotlin's key gate refuses `signOwner`, the prober turns that into an empty DER, Broken
  and then noResponse. The node shows 「連不到」, not 2.4.

§12 lists T-L* (including T-L4, T-L5) and T-X7/T-X8 as PR 1 tests. None of them exists (grep "T-L4|T-L5|T-X7" in
`test/`: nothing). This is not listed among the PR's deviations.

**Fix.** Feed `statusStream` (poweredOff / unauthorized / ready) and the permission check into `NodeLink.radio`.
Feed a key refusal from the prober (PlatformException with KeyPolicy's code) into `radio(keyOk: false)`. Add
`onError` / `onDone` to the scan subscription that ends the GateScan. Add T-L4 and T-L5 with a fake status stream.
Negative control: drop the `radio` call and the test shows `notFound` instead of `bluetoothOff`.

### M-6 Two driver rules have tests that cannot fail

(a) **「拿到之前…等斷線完成」 (§4.4).** Mutation: delete `await _dropAll();` from `NodeLink.acquire`. Result:
`nl-acquire-nodrop: 00:03 +29: All tests passed!`. The test fakes report the disconnect synchronously on cancel,
and `_pump` after `reg.acquire` aborts the link anyway, so `gate.links == 0` holds without the wait. The rule that
protects an older page from starting while NodeLink's link is still up is unguarded. Fix: use a fake whose
disconnect arrives through the injected clock (like my `SlowDiscRadio`) and assert `gate.links == 0` at the moment
`acquire` returns.

(b) **8 s to msg2 (§4.3.3-3)** in prober_test. Mutation: remove the `t1` body (prober.dart:308). Result:
`no frame from the node within the msg2 budget -> noResponse` still passes, at `00:22 +8: All tests passed!`,
because the 20 s `t2` timer gives the same `noResponse`. Fix: assert that the outcome arrives before `msg2 +
something`, far below `answerMax` (Stopwatch < 1 s with msg2 = 50 ms).

Mutations that **were** caught (each made one rule false, then the four PR test files were run):
gate token check, gate `revoked` no-op, scan limit 4/30 s, one-link check, RecordWriter check, NodeLink connect
budget, release without re-reading records, NodeLink not aborting a cut attempt, lease without the 420 s deadline,
prober row 2' → body, prober accepting a `persistNet` step. Each made at least one test FAIL. A survivor besides
(a) and (b): removing the token check from `GateLink._usable` (see m-5).

---

## MINOR

**m-1 A cut attempt overlaps the next one (spurious 「沒有回應」, and a late end closes the next link).**
(i) `_abort` closes the link without waiting. In the same pump, or on the next advertisement, `_run(next)` calls
`gate.connect` while the old link is still counted, so the gate refuses and the new attempt is recorded as
`noResponse`. An unknown address is then `exhausted` for the round and demoted next round. RB-3 (refresh during an
early round, disconnect reported 300 ms after cancel; M-1 measured 3–14 ms):
`Actual: ['connect: a link is already open']` / log `44.5 round 1 cancelled / 44.5 round 2 full / 44.6 a1×Y1 -> noResponse`.
(ii) `_run` closes **the field** `_link` after the probe (node_link.dart:183-184). When an aborted attempt's probe
returns late (stuck in `openRecord`, 130–150 ms on Keystore, or in a GATT op), it closes the *next* attempt's
link. RB-2: `Expected: true Actual: <false> A's late end closed B's link`. The two-round rule absorbs most of
this, so the result is lost tries rather than a wrong verdict. Fix: in `_pump`, start an attempt only when
`gate.links == 0`, and re-pump when the aborted link's `close()` completes. In `_run`, close the local `link` and
null `_link` only if it is still identical. **Flip:** with these four lines plus the M-2 guard, RB-1/2/3 pass and
the full nodelink suite passes (`+164: All tests passed!`).

**m-2 Decrypted record and session not freed.** `SessionProber` never calls `s.dispose()` on the `OwnerSession`,
which holds the opened record (K / psk_owner), and the `record` Uint8List is not zeroed. With an automatic read
every 60 s, these accumulate until the GC runs finalizers. The file comment says "the plain bytes are dropped with
the session". claim_recovery.dart:324/:376 shows the existing practice ("never leak a session that already holds z
/ K"). Fix: `try { … } finally { s.dispose(); record.fillRange(0, record.length, 0); }`.

**m-3 One pump and one setState per advertisement.** `onScan` → `if (_attempt == null) _pump()` → `_changed.add`,
which rebuilds NodeStatusList on every advertisement. Low-latency scanning reports each advertisement, several per
second per device, and an advertiser can flood. Pump only when `core.onScan` saw a new address this round, or
coalesce the updates.

**m-4 During the wait before a lease (up to 5 s) nothing is shown.** Design §4.4 asks for 「正在結束上一個讀取…」.
Double taps are handled correctly: the second request gets the snackbar.

**m-5 `GateLink._usable` token check is unguarded** (mutation survived). It is only reached together with `_open`
today, because revocation closes the link, so this is defence in depth. Add a GATT call made after acquire on a
NodeLink-token link that is not yet closed.

**m-6 Prober: `default` branch before login** (an unexpected step kind before `loggedIn` → noResponse) and
`loginEnd 0` with `ended` before login are not tested. The mapping is correct by reading. The trust boundary holds:
`AuthRefused` exists only in loginflow `State::Auth`, after `verify_pinned` (loginflow.rs:138-149, :160-171), and
NXpsk0 means `CertRejected` needs psk_owner. So none of 「是 Y」, 「身分不符」 or 「登入被拒」 can come from an
unverified device.

**m-7 Design tests listed for PR 1 are absent:** T-S4 (no ≥32-hex runs in NodeLink's log; core logs the full
`addr×id`, whose id length I did not establish ⚠️), T-G5 (source lock on the store write calls), lifecycle mapping
(`inactive` is not background, T20). None is in `test/`.

**m-8 The scan-slot wait outlives a cancelled round.** If a round is cancelled while `gate.scan` waits for a slot,
the scan still starts when the slot frees (NodeLink holds no reference to stop it), and is stopped one pump later.
That costs one scan start against the 4/30 s budget. Harmless.

---

## Per-actor summary

| Actor | Through this code | Status |
|---|---|---|
| Nearby attacker / malicious BLE device | Can stall an attempt until the cap (M-3) and so block a whole round; can flood pumps (m-3). Cannot plant 「是 Y」, 身分不符 or 登入被拒 (m-6 analysis), cannot get the owner key to sign anything but the handshake-bound `auth_owner_input` (signing happens only after the cert verified), cannot make anything write a record (no persist path in the prober; RecordWriter fail-closed). | M-3 open |
| Other apps on the phone | No new IPC, files or intents; nothing new is logged. | OK |
| Compromised node | Can answer any status (accepted in §8); can stall like M-3; `frameLimit` is computed by Rust from its ctrl bytes. | M-3 |
| Our own mistakes | Two Bluetooth users / unleased writer after pop (M-1), lease race (M-2), app freeze (M-4), wrong reasons shown (M-5), unguarded rules (M-6). | open |

## Raw output index
- Baseline: `00:03 +29: All tests passed!` (4 PR test files, my copy)
- RB-1/RB-2 on PR code: both `[E]`, messages quoted above. RB-3: `Actual: ['connect: a link is already open']`.
- RB-4: `Actual: 'HUNG'`. RB-5: hang until `timeout 120`; control `RB-5 waited 102 ms … All tests passed!`.
- Flip of M-2 + m-1 (5 lines in node_link.dart, my copy only): `00:06 +164: All tests passed!` (all of test/nodelink incl. RB-1..3).
- Mutation survivors: `gate-usable-token: +29 All tests passed!`, `nl-acquire-nodrop: +29 All tests passed!`,
  prober msg2 timer removed: `00:22 +8: All tests passed!`.
