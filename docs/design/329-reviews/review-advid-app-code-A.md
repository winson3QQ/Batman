# Code review A — rotating identifier, phone app (step 6 of §10)

- Reviewed: uncommitted change in worktree `C:\src\Batman-advid-app` (branch `feat/329-adv-id-app`, base `680081f`):
  `git diff 680081f` plus the untracked files.
- Against: `docs/design/329-rotating-id-plan.md` v6.1 — §3.3, §3.4 items 9–16, §4.2 R-A1..R-A6, §8 (R1, R2, S1–S7, S9).
- Not re-reviewed (baseline): the design and its accepted limits, the node side, the scheduling of `329-app-uiux.md`
  §4.3.3 that existed before this change.
- Reviewer: A (independent). Nothing in the worktree was changed except this file. No phone, emulator or node was
  touched. Tests ran only in my own copy `~/advid-rev-A` (WSL Ubuntu-24.04).

## Verdict

**APPROVE-WITH-CHANGES** — 0 BLOCKER, 0 MAJOR, 6 MINOR.

The change does what the design says. The hint only orders attempts; I found no path where it sets 「是 Y」, skips a
check, or costs more than the two attempts per target the design allows. None of the MINOR findings has to block the
merge; M-1 to M-3 are worth doing in this PR because they are small.

## Findings

### MINOR

**M-1. `AdvResolver::new` leaves a decoded copy of every record's secrets in freed memory.**
- Scenario: the resolver is rebuilt at start and after every lease release. Each build decodes each record's
  plaintext into a CBOR value tree. The input buffers are zero-filled, and the kept `adv_owner` keys are wiped on
  drop, but the decoded tree (which holds its own copies of every field of the record, the other keys and the node
  password field included) is dropped without wiping. The task brief asks that key material be zeroed.
- Evidence: `app/rust/bridge/src/api/owner.rs:217-232` (`new`: `plain.fill(0)` at :227 covers the input only);
  `wipe` at :200-205 covers `self.keys` only. The baseline `parse_record` in the same file does the same, so this is
  not a regression, but this change adds a second place and runs it far more often (every lease release).
- Fix: do not build a general value tree. Walk the map and copy out only key 1 and key 6, or wipe the byte strings
  of the decoded tree before it is dropped (a small recursive `fill(0)` over `Value::Bytes` / `Value::Text`).

**M-2. A replaced resolver's keys are wiped only when the Dart garbage collector gets to it.**
- Scenario: a claim or a removal ends, `_rebuildResolver` installs the new resolver and drops the reference to the
  old one. The old `AdvResolver` (with the removed node's `adv_owner`) stays in memory until the finalizer of the
  opaque object runs, which may be never before the process ends. Same on `dispose()`.
- Evidence: `app/lib/src/nodelink/node_link.dart:141-143` (`_resolve = r`, nothing is released); the `AdvResolve`
  closure type hides the object's `dispose()`. Rust wipes on `Drop` (`owner.rs:207`), which only runs then.
- Fix: let the builder return the resolve function together with a disposer (or return the object), and call it when
  a resolver is replaced, when a late build is discarded (:141), and in `NodeLink.dispose()`.

**M-3. A device that alternates a valid payload and none floods the log ring and re-pumps the scheduler.**
- Scenario (remote radio attacker, or simply a node whose scan response arrives without the manufacturer data every
  other time): one address reports hint Y, then null, then Y… Each change makes `onScan` write a log line and return
  true, and the driver pumps. With several such addresses the 500-line diagnostic ring holds nothing else, so the
  record of a real problem is lost. No extra connection attempt results (the cap is per target per round, verified
  below), so this is a diagnostics and wasted-work issue only.
- Evidence: `app/lib/src/nodelink/core.dart:369-373` (round), `:809-812` (loginFor); ring size `logMax = 500`;
  `node_link.dart:847`.
- Fix: log only the first hint per address per round (keep a set), or do not clear `like[a]` on a null result within
  a round (a missing field in one scan result is normal on Android; the design's §3.4-11 「last scan result」 can be
  kept by replacing a hint only with another non-null hint — if that reading is not wanted, rate-limit the log).

**M-4. S5 does not assert that Y ends 「as today」.**
- Scenario: the test proves there is no third attempt at the 「像 Y」 addresses, but not what Y's conclusion is after
  the cap, nor that the look-around continues with the remaining addresses after the window. A change that made Y
  stop early (no look-around at all once two 像 addresses failed) would pass.
- Evidence: `app/test/nodelink/adv_hint_test.dart`, test S5 (round) and S5L (loginFor): assertions are on the
  attempt list only.
- Fix: in S5 add a third, unhinted address and assert that it is tried after the window and that the round's
  conclusion for Y is the same as in the run without hints.

**M-5. §8 items with no direct test.**
- S4 (「no hint = today's behaviour, trace identical」): shown only indirectly — all 551 existing tests pass and the
  null-hint mutations are caught. There is no test that runs one scenario with and without the resolver and compares
  the scheduler log. I verified the equivalence by reading (see below), so this is a test gap, not a defect.
- §3.4 second consequence (another target may spend an attempt on an address that is 「像 Y」): no test; the design
  says so and accepts it.
- Resolver build while another lease is current, and the build time on a phone (D2): not measured anywhere in this
  change. This needs the device session, not a unit test.
- Fix: add the S4 golden comparison (cheap with `sim.dart`); list the other two under 「not tested」 in the PR body.

**M-6. The negative-control record holds two runs.**
- Evidence: `adv-id-app-negative-controls.txt` prints the summary line 「not discriminating / not applied: 0」 twice.
- Fix: write the file fresh on each run (open with `w`), so the record is one run of the code as it is.

## What was verified, and how

Run in `~/advid-rev-A` (a copy of the worktree made with rsync; nothing run in `~/advid-app-test`):

| Check | Result |
|---|---|
| `cargo test --test vectors` (batman-proto) | 37 passed, 0 failed (includes `adv_id_vector`: tag, CID, whole AD, two negatives) |
| `cargo test adv_tests` (bridge) | 7 passed, 0 failed |
| `flutter test test/nodelink test/flows` | `+551: All tests passed!` |
| `flutter analyze lib test` | `No issues found!` |
| flutter_rust_bridge content hash, Rust side vs Dart side | equal (`-1473740958`) |

Verified by reading the source (file:line in the worktree, `app/` prefix omitted):

1. **The hint never sets 「是 Y」 and never skips a check.** `isY` is written only in `result` after a verified
   login, as before; `onScan` (`lib/src/nodelink/core.dart:359-374`) writes only `r.like`. `_likes` (:454-458)
   returns false when the address already has a 「是」 memo or a 「不是 Y」 memo, so the order of precedence is
   是 > 不是 > 像 (§3.4-10, -13). The prober and the login path are not in the diff.
2. **Cap of two (§3.4-12, S5).** `likeTried[id]` gets an address only in `next` (:507); `_likes` refuses a third
   address; `result` retries a silent 「像」 address only while `count < perAddr` (:570). loginFor: :819-820 and
   :832-838. A replay attacker therefore costs one target at most two addresses × two attempts per round — the
   limit the design accepts.
3. **Null hint = old behaviour (S4).** With `r.like` empty, `_likes` is false everywhere, the `like` list in
   `_candidates` (:469-473) is empty, `next` (:493) sorts as before, and the new branch in `result` (:570) cannot be
   taken. Same for `LoginFor` (:829-838). Until the first build ends `_resolve` is null and `_hint` returns null
   (`lib/src/nodelink/node_link.dart:128, 152-160`), so app start before the resolver exists is the old behaviour.
4. **Resolver life cycle (§3.4-14/-15/-16, S7, S9).** Built in `start()` and in `released()` before the
   `reg.current` check, so a removal or a claim while scanning takes effect at the lease's end; a slow older build
   cannot replace a newer one (`if (_disposed || n < _built) return;`, :141); a failed build leaves the previous
   resolver and traces only the error's type. `buildResolver` (`lib/src/nodelink/app_link.dart`) skips a record that
   does not open (Keystore error, damaged file) and zero-fills every opened plaintext in `finally`; it uses
   `openSealedRecord` only, so no Keystore failure is reported to the user from here (test 3 of
   `adv_resolver_build_test.dart`).
5. **`resolve` on hostile input.** `rust/bridge/src/api/owner.rs:236-…`: length must be exactly 8
   (`try_into::<&[u8; 8]>`), CID compared as little-endian `0xFFFF`, the three tag bytes compared by OR of XOR
   without an early exit, a second matching record gives `None` (S3). No indexing that can panic; `adv_tests` cover
   short, long, wrong CID, wrong tag, two owners.
6. **What the plugin hands over.** `ManufacturerDataConverter.kt` (pub cache 5.6.0 and the vendored
   `third_party/reactive_ble_mobile`, identical) returns the first manufacturer entry as CID (LE) + payload — the
   8 bytes `resolve` expects. An empty field becomes null in `ble_backend.dart`. An old-image node (no field) and
   an unclaimed node (short field) therefore give a null hint.
7. **Nothing secret is logged.** The new log lines carry an address and a device id (`core.dart:371, 811`); the
   build-failure trace carries `e.runtimeType` only.
8. **Negative controls.** Read `adv-id-app-nc.py`: 28 mutations, each a one-line change of the new code (hint
   ignored, cap raised, precedence dropped, build counter rule, zeroing removed, CID check removed, tag compare
   shortened…), each run against the named tests; the record shows 28 × 「FAIL (as wanted)」. ⚠️ I did not re-run the
   mutations myself; I checked that each mutation's target string exists in the source and that the named test
   asserts the behaviour the mutation removes.

Not verified:

- ❌ Anything on a phone or a node (out of my limits): the real scan path, the build time, behaviour with the real
  Keystore.
- ⚠️ The diffs of the test fakes in `ble_gate_test`, `connect_fail_test`, `kept_link_test`, `node_link_test`,
  `prober_test`, `retest_h_unseal_test`, `review_pr1_test`, `owner_console_test` were not read line by line; they
  are signature updates for the new scan pair, and they compile and pass.

## §8 coverage

| Item | Test | Note |
|---|---|---|
| R1 (vector) | `tests/vectors.rs` `adv_id_vector` | ok |
| R2 (resolve) | `owner.rs` `adv_tests` (7) | ok |
| S1, S2, S3, S6 | `adv_hint_test.dart` (round and loginFor) | ok |
| S4 | existing suite + mutations | no direct golden comparison — M-5 |
| S5 | `adv_hint_test.dart` S5 / S5L | conclusion not asserted — M-4 |
| S7 | `adv_hint_link_test.dart` (4) | ok |
| S9 | `adv_hint_link_test.dart` (5), `adv_resolver_build_test.dart` (3) | ok |
