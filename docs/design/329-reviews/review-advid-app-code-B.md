# Code review B — rotating identifier, phone app (step 6 of §10)

Reviewed: the uncommitted change of worktree `C:\src\Batman-advid-app` (branch `feat/329-adv-id-app`, base 680081f),
against `docs/design/329-rotating-id-plan.md` v6.1 §3.3, §3.4 (9–16), §4.2, §8 (R1, R2, S1–S7, S9).
Emphasis: resolver lifecycle and concurrency, the vendored plugin path, and regression with `hint == null`.
Not reviewed (baseline): the design, the node side, the scheduling of `329-app-uiux.md` §4.3.3.

Tests were run only in my own copy `~/advid-rev-B` (WSL Ubuntu-24.04, rsync of `app`, `tests`, `docs`).
Nothing under the worktree was changed except this file. No phone, emulator or node was touched.

## Findings

No BLOCKER. No MAJOR.

### MINOR-1 — a replaced or disposed resolver keeps its keys until the Dart GC runs

Scenario: the owner removes node Y (or re-claims it). The lease release rebuilds the resolver
(`node_link.dart:758`) and `_resolve = r` (`:143`) drops the last reference to the old closure, which holds the old
Rust `AdvResolver` (`app_link.dart:186-189`). The Rust `Drop` that zeroes the keys (`owner.rs` `impl Drop for
AdvResolver`) runs only when the Dart finalizer of the opaque object runs, which is at some later GC, or never
before the process ends. The same holds for `NodeLink.dispose()` (`node_link.dart:958-969`), which does not clear
`_resolve`, and for a build that finishes after dispose (`:141` returns and leaves the new object to the GC).
So `adv_owner` keys of a removed node, and one extra copy of every key during each rebuild, stay in memory for an
unbounded time. Design §3.3 says "zeroised on drop"; that is true in Rust, but the drop is not driven.

Evidence: `node_link.dart:128`, `:141-143`, `:958-969`; `app_link.dart:186-189` (no `dispose()` call anywhere:
`grep -n "dispose\|_resolve" node_link.dart`). The test `the_keys_are_zeroed_when_dropped` proves the Rust side only.

Impact: low. The key only links adverts to a node (it gives no login), and the same process holds the sealed
record's other secrets while a login runs. It is still a stated property that the code does not deliver in time.

Fix: let the builder return the resolver together with a `void Function() dispose` (the app: `r.dispose()` of the
frb opaque object). Call it (a) on the old resolver when a new one is installed, (b) in `NodeLink.dispose()`,
(c) on a build result that is dropped at `:141`. One host test: after a rebuild the old resolver's dispose was
called once; after `dispose()` the current one's was.

### MINOR-2 — a resolver built while the records cannot be opened stays empty until the next lease release

Scenario: at app start one `open` fails for every record (a transient Keystore error, the service not ready).
`buildResolver` leaves each such record out (`app_link.dart:24-40`, as designed) and the build "succeeds" with no
keys, so `_built` advances and `_resolve` gives no hint. A rebuild is started only at `start()` (`node_link.dart:263`)
and at a lease release whose record read succeeded (`:758`). Rounds take no lease, so a user who only watches the
status pages keeps the old 30 s behaviour until some operation takes a lease, possibly for the whole session.
The same happens for one record left out: that node gets no hint and nothing says so (the trace line prints
`ids.length`, the number asked for, not the number opened: `:144`).

Evidence: `node_link.dart:131-149`, `:263`, `:758`; `app_link.dart:24-40`. Fail-open (today's behaviour), and design
§4.3 only promises "built in the background", so this is not a breach of the design.

Fix (small): make the trace line say how many records opened (`k of n`), so a field log shows why there is no hint;
optionally start one more build at `foreground()` when the last build opened fewer records than it was given.

### MINOR-3 — the hint log line has no rate bound

Scenario: a radio attacker replays one captured payload of Y from one address and alternates it with an advert
without Manufacturer Data (or with a payload of own node Z captured elsewhere). Each scan result changes
`r.like[a]`, so `onScan` logs `'<a> like <id or ->'` and returns true each time (`core.dart:356-374`), and the driver
calls `_pump()` / `_lfPoke()` each time (`node_link.dart:845-847`, `:421-441`). With a low-latency scan that is many
lines a second into the 500-line ring (`core.dart:180`) and into logcat, which pushes the lines a field diagnosis
needs out of the ring. No attempt is added: the cap of 2 and the memos still hold (checked: `_likes` reads
`likeTried`, not the log).

Evidence: `core.dart:356-374`, `:180`.

Fix: log a like change only the first time an address gets a given value in the round (a `Set<(addr, id)>` in
`_Round` / `LoginFor`), still return true so the plan is redone. One test: 100 toggles give at most 2 log lines.

### MINOR-4 — the negative control named for R2 does not test R2's claim

`adv-id-app-nc.py` "R1/R2: keyed by the device id only" (`adv_owner(&[0u8; 32], id)`) makes six tests fail, but
all through their positive assertions (my run: `r1_...` at `owner.rs:1933`, `:1944`, ...). R2's own claim — the
old record does not resolve the payload of the re-claimed node — still holds under this mutant only because the
positive line before it fails first. A mutant that keeps positives working but ignores a key change (for example
keys cached by device id across `new`) is not possible in the present code, so there is no hole in the product;
the control list just claims more than it shows.

Fix: either rename the control to R1 only, or add to the R2 test a first assertion that stands alone
(`old.resolve(mfr(Y, &k_new, n)) == None` before any positive) and a mutant that drops key 6 from the derivation
input in `resolve` only.

### Test gaps (no finding on the code; named as the task asks)

- **Dispose during a build** (`node_link.dart:141`, the `_disposed` branch): no test. Read: correct (nothing is
  installed, no trace after dispose).
- **`ReactiveBackend.scan()` empty → null** (`ble_backend.dart:26-28`) and the plugin's byte layout
  (`ManufacturerDataConverter.kt`): no host test; checked by reading only. The first end-to-end proof is device
  run D2. A one-line pure function `mfrOf(Uint8List) → Uint8List?` with a test would close the Dart half.
- **S4** has no test that compares traces; it rests on the existing suite passing and on the mutation
  "a null hint counts as like of the target", which in my run made 7 tests fail, 3 of them pre-existing
  (`core_test.dart` T-L2(e) and "wait for the known address", `core2_test.dart` T-L11(j)). That is a real control.
- **§3.4 consequence** "another target Z's attempt may be spent on an address that looks like Y": stated in the
  design, not tested.
- **S5 (round)** does not assert what Y's conclusion is at the end of the round, only the attempt times.

## What I verified, and how

Run by me in `~/advid-rev-B` (output kept in my scratchpad):

- `flutter test test/nodelink`: `00:36 +391: All tests passed!`
- `cargo test adv` in `rust/batman-proto`: `test adv_id_vector ... ok`; in `rust/bridge`: 7 `adv_tests` ok
  (`test result: ok. 7 passed; 0 failed`).
- All 29 negative controls of `adv-id-app-nc.py` (root changed to my copy): each `rc != 0` with an `[E]` /
  `FAILED` line of the named test (not a compile error, not "no tests"); `not discriminating / not applied: 0`.
  After the run `diff -rq` of `lib`, `rust/bridge/src`, `kdf.rs` against the worktree: no difference.
  Note: the script's `PATH` line expands only the first `~`; without `~/.cargo/bin` already on `PATH` the Rust
  controls stop with `FileNotFoundError: 'cargo'` (my first run). Harmless, worth one `expanduser` per entry.

By reading the source (not run):

- **A hint never identifies.** `isY` is written only in the success branches of `result()`; `onScan` writes
  `lastSeen`, `r.seen`, `r.like` only. `_likes` in the round and in `LoginFor` both require
  `isY[a] == null && !isNot(a, id)`, so a memo wins (§3.4-12). No check is skipped on a like address: the attempt is
  the normal login.
- **Cap.** At most 2 addresses per target per round / login (`likeTried`); a replay attacker with many addresses
  gets 2 attempts per target per round, after that the addresses are unknown addresses as today. A silent like
  address is retried within `perAddr` only (§3.4-15); `wakeAt` covers its `freeAt`.
- **`hint == null` everywhere.** `r.like` stays empty, `_likes` is false, the like list is empty; `_candidates`,
  `next`, `result` and the return of `onScan` then take the same branches as `git show 680081f:.../core.dart`.
  The one difference is the stated one (during `loginFor` every scan result refreshes `lastSeen`). ⚠️ by reading and
  by the unchanged old tests passing; no trace-level diff was made.
- **Resolver lifecycle.** Built after the first record read; rebuilt at a release whose read succeeded; overlapping
  builds: the newer installed one stays (`n < _built`), a failed newer build leaves the older result (stale by one
  record list at most, corrected at the next release); a build failure traces the type only; a throwing resolver
  gives null. Scan results before the first build give null and the next advert gives the hint. `loginFor`: hints
  seen before the login object exists are kept in `early` and replayed; a result of an older login generation is
  dropped (`gen != _lfGen`). Background: no scan runs, nothing to resolve. BLE off/on: the resolver is independent
  of the adapter.
- **Plugin path.** Android converter: company id low byte, high byte, then the data, of the entry with the lowest
  company id only; empty when there is none. With a second manufacturer entry below 0xFFFF the result is simply no
  hint (fail-open). `ble_backend.dart` maps empty to null; `ble_gate.dart` passes it on. Every `scan()` override in
  `test/` uses the new record type (grep). `claim.dart`, `claim_recovery.dart`, `scan.dart` use the plugin directly
  and are not affected.
- **Rust.** `resolve` takes exactly 8 bytes, checks the CID little-endian, compares all 3 tag bytes without an early
  exit, returns none on two matches; no index or unwrap can panic on any input. `new` skips a record that does not
  decode or lacks key 1 / a 32-byte key 6 and zeroes the input. The decoded `Value` tree is dropped without
  zeroing, as in the baseline `parse_record` (`owner.rs:181-189`), so not raised.
- **Secrets in logs.** Log lines carry an address suffix and a device id, never payload bytes, keys or error text.
  The Android `open` answer is wiped after delivery (`MainActivity.kt:138`, `wipe = true`); Dart zeroes its copies in
  `buildResolver`'s `finally`.

Not done: no device run (forbidden here; D2 is the design's device proof); no trace-level differential for S4.

## Verdict

**APPROVE-WITH-CHANGES** — 0 BLOCKER, 0 MAJOR, 4 MINOR. The code does what §3.3, §3.4 and §4.2 say, the hint
cannot identify a node or skip a check, and every negative control discriminates in my own run. MINOR-1 (drive the
key zeroing instead of leaving it to the GC) is the one I would fix before the PR; the others may go into the
PR's checklist.
