# Code review round 2 — one link per node (3da354e..272e0e2)

Two independent reviewers (C, D), whole diff, baseline = design v4 (3da354e) and the reviewed v5.1 behaviour.
Verdict of both: APPROVE-WITH-CHANGES, no BLOCKER or MAJOR in product code.

## Findings and what was done

1. **MAJOR, test only (D-1) — the 300 ms L7 added in round 1 could not fail.** It sampled after the wait, so it
   passed with the `acquire` wait removed; the failure reported in round 1 was the plain L7 (the mutation runner
   matched both names). Rewritten: it samples at the moment the lease is given, with a 300 ms unsubscribe and a link
   that is gone 1 s after the disconnect. Round 1's table is corrected.
2. **MINOR, regression of 272e0e2 (C-1) — a round's attempt could connect while `acquire` waited for the closes.**
   `_abort()` ran only in `_dropAll`, after the new wait. One wasted connect; no link was left when the lease was
   given. Fixed: `_abort()` before the wait. New test L21 (3 records, raw lease during the eviction wait).
3. **MINOR, rig (C-2) — `KRadio.connect` counted a link as open when it was cancelled before it came up.** Fixed in
   the rig.
4. **MINOR (C-3, D-2) — conditions no test can make fail alone.** Not changed, no test added:
   - `keepFor`'s `_kept.length < keptMax` and the same check at the end of `_run`: equivalent today, `_makeRoom`
     closes one first;
   - `keepFor`'s `core.fg` / `core.blocked == null` / `states.containsKey`, the re-check after the wait in
     `_lfAttempt`, `loginFor` closing the idle links when the radio is blocked, `lastSeen` on an error reply
     (core.dart; L19 covers the body reply): defensive, each guards a state another rule already closes.
5. **MINOR (D-3) — design §7's rig rule (`goneMs > 0` in closing tests) is not followed by L5, L7, L8, L10, L20.**
   With the rig default they still fail without the change (they sample early). Not changed.
6. **Not verifiable on the rig (D-4)** — every close is now disconnect, then unsubscribe. Read in the plugin's
   source by C (unsubscribe is local and always answers); the device pass D4 / D6 / D7 runs on this commit's APK.

Not changed from round 1: B-4 (the 6 s bound in `_makeRoom`). `_loginFor`'s unbounded wait for a close is as in the
baseline.

## Negative controls (run)

| Change removed | Fails |
|---|---|
| `_abort()` before the wait in `acquire` | L21: `Actual: (1, 0, 0)` |
| the wait in `acquire` and the close-first in `_closeKept` (= 009d592) | L7 (300 ms): `Actual: (2, 2, 0, false, false)` |
| the wait in `acquire` alone | L7 (plain) |

After the fixes: `flutter test` 2198 passed, `dart analyze lib test` clean. The cargo part is not run locally (CI).
