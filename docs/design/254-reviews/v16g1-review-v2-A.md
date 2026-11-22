# Review A, round 2 — `254-v16-group1.md` v2 (2026-11-21)

Reviewer A, independent. I re-read the whole v2 against the worktree (`C:/src/Batman-g1`, HEAD 4b61b3c). I did not
only check §9; I re-did the lifecycle, resource and actor passes. Read-only, no node access.

**Verdict: APPROVE-WITH-CHANGES.** There is no BLOCKER. Two MAJORs remain, both with small and specific fixes; under
the owner's rules they must be fixed and the document re-reviewed before implementation. All v1 findings of mine
are closed or correctly dispositioned, except where noted below.

## v1 findings: status

| v1 | Status |
|---|---|
| B1 (§4 L18) | closed: removed, moved to #255 |
| M1 (`otaBusy`) | closed: §2 gate before each try, unit (f) |
| M2 (mutex / backoff) | mostly closed. The curable-only set and the separate backoff are right, but the curable classification contradicts itself (new **M2** below) |
| M3 (Pi 3) | closed: layout-gated. Pi 3 is unsupported (P-U14, `254-p1-impl.md:1195`) |
| M4 (dry run) | partly closed. The marker set is now complete, but the dry directory's lifecycle across runs and the harness snapshot are missing (new **M1** below) |
| M5 (reproduction) | closed as a plan: the wsl.34 negative runs first, owner approval pending. Not yet evidence |
| m1–m8 | closed |

---

## MAJOR

### M1. §3: `autocommit.dry.d/` is never reset, and the harness snapshot does not know it — §7 "nothing needed" is wrong

- **Scenario.** `prov-misc-254` runs several dry runs in one boot. Today, between runs, it saves and restores the
  dry run's run-dir state by name. After §3, run 1 leaves `autocommit.dry.d/{wd,decided,hold-consumed,canary-ok,…}`
  behind. Run 2 in the same boot then:
  - cannot `mkdir dry.d/wd`, so its watchdog exits 0 silently (`batman-autocommit:200` pattern);
  - cannot `claim` (`dry.d/decided` already exists);
  - sees `held()` true from run 1's `hold-consumed`;
  - skips the canary because of run 1's latch.

  The unit then reaches its verdict without exercising the watchdog. It is non-discriminating rather than failing.
  The same happens to an operator's second dry run.
- **Evidence.**
  - `scripts/node/prov-misc-254.sh:35`:
    `RDF="autocommit.wd autocommit.decided autocommit.why autocommit.hold-consumed autocommit.hold-discarded autocommit.ctl.dry autocommit-dryrun.log canary-ok"`.
  - That list is snapshotted at `:65`, and restored with `rm -rf` and a copy at `:139-145`. It lists the real names
    and `autocommit.ctl.dry`, which §3 moves into `dry.d`. `dry.d` is in none of save, restore or `snapls`.
  - `prov-ac-flap-254.sh:11` documents `autocommit.ctl.dry (:53)` as the dry control dir. After §3 that comment is
    wrong.
  - §3 says nothing about when `dry.d` is created fresh or emptied. §7 says "§3: nothing needed".
- **Fix.**
  1. Each dry run starts from an empty `dry.d`: at DRY start, run the planted-dir check, then `rm -rf` and `mkdir -m
     700`. State "one dry run at a time" as the seam's contract; the harness already serialises its runs.
  2. If `dry.d` cannot be made a root-owned directory, the dry run exits non-zero. It never falls back to the real
     names.
  3. Harness PR: add `autocommit.dry.d` to `prov-misc-254` RDF, replacing `autocommit.ctl.dry`, and fix the
     `prov-ac-flap-254.sh:11` comment.
  4. Offline test: two consecutive DRY + FORCE_TRIAL + TIMEOUT=1 runs. **Both** print the watchdog's
     `DRYRUN decision: REVERT` line. Negative control: without the reset, the second run lacks it.

### M2. §2: the "curable" classification contradicts itself, so the A4 m1 fix would never be retried

- **Scenario.** §5 A4 m1 makes a transient `uci get <i>.device` failure a transient `CheckRestorable` error. §2 says
  "a transient `CheckRestorable` error" is curable, but also "a `desired()` error" is **not** curable. A transient
  CheckRestorable error is returned *through* `desired()`.
- **Evidence.**
  - `wtxn.go:187-191`: `desired()` wraps the non-`RestoreRefused` error as
    `fmt.Errorf("cannot check the pre-change settings now (%v)")`.
  - `finish()` turns every `desired()` error into `EState` (`wtxn.go:313-317`).
  - Taken literally, the most likely implementation (classify by `desired()` error → not curable) never retries the
    one case A4 m1 exists for.

  The list also leaves other cases open:
  - finish's other exits: `WriteTxn` rewrite and `WriteTxnMarker`, both `EApply` (`wtxn.go:303-311`);
  - `resolve`'s "record does not decode" and "no usable record" (`wtxn.go:262-288`);
  - `SaveTxn` rc 124 (a save deadline of 300 s + 20 s). It sits in "EStorage save failure = curable", but it is the
    same long hold that "rc 124 not curable" was meant to exclude.
- **Fix.**
  - Classify at the source with a typed cause set by `finish()`: `setkeyRC2`, `restoreTransient`, `p5Unreadable`
    (`resolve` rc ≠ 0/7/9/13), `saveFailed` (rc ≠ 0/6/124) → curable. Everything else, including any timeout and
    the default, → not curable.
  - Write that table into §2.
  - Add unit tests:
    - (a′) transient CheckRestorable through `desired()` → retried;
    - (e′) save rc 124 → not retried;
    - (e″) an unknown or new error → not retried (fail toward today's behaviour).

---

## MINOR

1. **§1: sourcing `bootfacts.sh` at the arm and disarm sites has no stated missing-lib behaviour.**
   - `batman-slot` runs with `set -u` (`:38`). `cmd_reboot` guards the lib with `type bf_get` (`:1008`); arm and
     disarm need the same guard.
   - State it: lib missing → arm dies, disarm dies on Pi 4 too. A missing lib means a broken image or ramfs, so
     fail closed.
   - Offline `batman-slot` tests (`tests/ab-card-invariants.sh`, the stub-vcmailbox table) run off-device, where
     `/usr/lib/batman/bootfacts.sh` does not exist. Name the lib-path override the tests use. Otherwise the new
     table tests exercise the "missing lib" path instead of the predicate.
2. **§2 tests (g) and (h) conflict as worded.**
   - (h): after a failed retry, a verb is NOT refused, so it does run a Finish.
   - (g): unauthenticated verbs during the window cause "no extra Finish".
   - Reword (g): verb-triggered Finishes are rate-limited exactly as on main (same `finishFails` / `lastFinishFail`
     sequence from the same verb sequence). Retries add at most 8 Finishes per boot and are never triggered or
     shortened by a verb.
3. **§2: postponement is unbounded.**
   - `otaBusy` fails closed ("cannot tell = busy", `wtxn.go:465-470`), so an unreadable `batman-slot.flock` keeps the
     goroutine waking every 60 s, taking `n.mu`, for the rest of the process.
   - The cost is harmless, but the claim "bounded" is not true. State it, or cap postponement (for example 24 h, then
     give up with the CRIT line).
4. **§2 lifecycle: "SIGTERM mid-try = like a power loss" is imprecise.**
   - `os.Exit` abandons the setkey child, which keeps running and holds `halow-setkey.lock`.
   - The respawned helper's BootFinish can then meet a lock wait of up to 90 s (`halow-setkey:153`), giving rc 2,
     which is curable and so retried. The outcome is fine, but write it as it is.
5. **§2 device unit: the one-shot `halow-setkey` wrapper must match only the helper's write call.**
   - It should match `--no-persist`, and not `--check-only`. A `--check-only` call answered with rc 2 is
     `RestoreRefused`, so Finish **forgets** (`main.go:256-257`).
   - It must also not match any other boot-time caller.
   - Name the verb cut at txn-2 (an update from member: previous state = the committed network, no check-only on
     that path) and assert the wrapper fired exactly once on a `--no-persist` call.
6. **§3 "writes nothing real": the pre-commit canary still runs in DRY.**
   - It runs at `batman-autocommit:562-571`, before the DRY exit at `:572`.
   - `canary_run` imports a `batman-canary:<tag>` image into the p6 docker store and `docker rmi`s older tags
     (`:128-143`).
   - This is a deliberate shared cache (`:121`), but list it as the one accepted real effect, or the before/after
     listing test (p6) has to exclude `/opt/batdata/docker` explicitly.
   - Also `log()` still writes syslog and kmsg in DRY (`:62`). No product reader parses those lines (grep of
     `feed/*/files`), so that is fine, but say it.
7. **§1 security probe.** `/dev/vcio` 0660 root is "to be checked in implementation". Make it a listed read-only
   probe (`ls -l /dev/vcio` on 04), so the "local unprivileged process cannot reach it" claim carries evidence in
   the PR.

## Re-checked and fine (no finding)

- §1 consumers of `bf_get` are all Pi 4-gated: `batman-slot:1009`, `platform-ab.sh:307`, and K90 via the want-file.
  `bootfacts.sh` is in `RAMFS_COPY_DATA` (`platform-ab.sh:42`). Its functions are `set -u`-safe (`${n:-}`), and there
  are no name collisions with `batman-slot` (`bf_*` only).
- The §1 upgrade / second-OTA rows correctly show that the new arm is exercised only from a bench → bench OTA.
- §3 p6 audit lines: `:99`, `:292`, `:299-300` are guarded; `:196` / `:245` come after a DRY exit (`:195`, `:241`);
  `:238` is the fix; `:583` comes after `:572`. Verified.
- §4: 39 files across all feeds, verified (`batman-provision` 37 + `batman-payload-host` 2).
- §5 references verified (v1). The chi-square cutoff 119.9 is correct.
- The §0 #255 overlap statement is honest (⚠️ inferred).

## Summary

| # | Sev | One line |
|---|---|---|
| M1 | MAJOR | §3 `dry.d` never reset → a 2nd dry run in a boot silently skips the watchdog / claim / canary; prov-misc-254 RDF (`:35`) still snapshots the old names; §7 "nothing needed" is wrong |
| M2 | MAJOR | §2 "transient CheckRestorable = curable" vs "`desired()` error = not curable" contradict (`wtxn.go:187-191`); save rc 124 and the default class are unspecified → typed cause table + tests |
| m1 | MINOR | §1 arm / disarm: missing-lib behaviour (`set -u`, `:38`) and the offline lib path are unstated |
| m2 | MINOR | §2 tests (g) and (h) contradict as worded |
| m3 | MINOR | §2 postponement is unbounded (`otaBusy` fail-closed) — say so or cap it |
| m4 | MINOR | §2 SIGTERM row: the abandoned setkey holds the lock → the respawned helper gets rc 2 → retried |
| m5 | MINOR | §2 device wrapper must fail only the `--no-persist` write (a check-only rc 2 → forget) |
| m6 | MINOR | §3 the DRY canary still imports / prunes the docker image on p6; syslog lines — list them as accepted |
| m7 | MINOR | §1 `/dev/vcio` mode → an explicit read-only probe |
