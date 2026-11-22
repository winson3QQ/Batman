# Review A, round 3 — `254-v16-group1.md` v3 (2026-11-21)

Reviewer A, independent. I re-read the whole v3 against the worktree (HEAD 4b61b3c) and repeated the lifecycle,
resource, contract and actor passes. Read-only, no node access.

**Verdict: APPROVE-WITH-CHANGES.** No BLOCKER and no MAJOR is open. The MINORs below are text and test fixes that can
be folded in at implementation; under the owner's rules they do not need another full review round. m1 should be
fixed before the PR, because it corrects a false security statement.

## v2 findings: status

| v2 | Status |
|---|---|
| M1 (`dry.d` lifecycle, harness RDF) | closed: lock + empty directory per run, exit 1 rather than fall back, RDF and comments in §7, tests for two runs in a row and a planted symlink |
| M2 (curable classes contradict) | closed: the typed cause table; unknown and the 300 s classes are not retried; (e) and (e'') test it |
| m1–m7 | closed (m7 as a §8 probe) |
| B-M1 (forget rc 3 retried) | checked against `halow-setkey:384-422` (forget, escalation, exit 3) and `254-wireless-txn` §19.2: correct. A committed leave that keeps the key is a fail-open, and retrying it is right |

---

## MINOR

### m1. §2 security: "an unauthenticated verb is refused before any Finish" is not true for every peer that can reach the helper

- **Evidence.**
  - provd forwards `network/update` for **RoleMember** and `claim/replay` for **RoleReacquire**
    (`provd/session.go:74-83`, `forward` `:87-92`).
  - In the helper, `dispatch` runs `finishGated` (`node/node.go:269-273`) **before** `ownerOpVerb` (`:300`) verifies
    the owner-op signature.
  - The code says so itself: "an unauthenticated peer can cause at most one setkey + one p5 save per backoff"
    (`wtxn.go:368-369`).
  - So a member-role or reacquire session holding a bogus op does trigger a Finish today, rate-limited by the verb
    backoff. Only RoleAnon is refused earlier, by provd's role table, and (g) as worded tests only that.
- **Impact.** Nothing new: retries never shorten or reset the verb backoff on failure, so the rate is main's plus at
  most 8 per boot. But the document's security claim is false, and its negative test aims at the wrong actor.
- **Fix.**
  - Reword the actor line: member / reacquire peers can trigger a verb Finish exactly as on main (one per backoff);
    retries do not change that.
  - Change (g) to: a `net.apply` with an invalid op signature during the retry window causes the same Finish count
    and the same p5 writes as the same sequence on main, and no more.

### m2. §2: the time bounds of the retried classes are understated

- **setkey rc 3.** The bound is lock 90 + settle 30 + read-back 60 + channel verify ≤ 60 (`halow-setkey:486-516`) + ≤ 20
  (`:531`). That is ≈ 4.3 min, not ≤ 3 min.
- **forget rc 3.** The bound is lock + settle + 30 + escalation (3 s per pid) + 10 (`:385-422`).
- **Save rc ∉ {0, 6, 124}.** A failing save can end with rc ≠ 124 just before its 300 s deadline. "≤ 70 s" is the
  typical case, not the bound.
- **A whole try.** It is setkey OK followed by a failing save, so the worst case is still close to 300 + 300 s.
- All of this is still below the Exec deadlines, so the design holds. Write the bound as "< the 300 s Exec deadline
  per step; typical …".

### m3. §3: the dry lock's pid does not cover the dry watchdog subshell

- The lock records main's pid.
- The harness kills main with `kill $p` (`prov-ac-flap-254.sh:32`, `prov-autocommit-p3-254.sh:28`). The
  `( revert_watchdog ) &` subshell outlives it.
- The next dry run then sees "pid gone", takes the lock over and runs `rm -rf dry.d` under a live watchdog, which
  can later print a stray `DRYRUN decision: REVERT` into the next run's window.
- Main's many early `exit`s also skip the final unlock. The takeover handles that, but it is the same gap.
- **Fix.**
  - A stale lock is taken over only when no process with `batman-autocommit` in its cmdline has the recorded pid as
    its session or parent (or record both pids).
  - Or kill the recorded process group on takeover.
  - Unlock in an `EXIT` trap.
  - Test: kill main mid-run, start a second dry run, and check that no line from the first watchdog appears.

### m4. §1: `BATMAN_LIB` is a root code-path seam; say why it is acceptable

- It decides which file root `batman-slot` sources.
- The precedent is `BATMAN_FW_ALLOWLIST` (`batman-slot:45`), and only a root caller can set a root process's
  environment. The provhelper runs children with `cleanEnv` (`main.go:89`).
- State this in §1 Security.
- Apply the same variable to the existing `cmd_reboot` source (`:1006`), so there is one path rule, not two.

### m5. §3: `:583` "to be checked in implementation" can be closed now

- The DRY exit `if [ "$DRY" = 1 ]; then echo "DRYRUN decision: COMMIT …"; exit 0; fi` is at `:572`, before
  `claim` (`:575`) and the commit (`:582-583`). Verified.
- Write it as verified.

### m6. §2 / §8: attach the reproduction before implementation starts

- §8 says the wsl.34 run is approved, and §2 describes "the first run (2026-11-21)". The design does not yet carry
  its log.
- The owner's rule is reproduction first. Add the log excerpt to the design or the issue before the code is
  written, together with the line showing that the rc 2 hit the Finish's `--no-persist` setkey and not the
  `--status` call.

## Re-checked and fine (no finding)

- §1:
  - `bf_vc_ack` uses positional parameters only, so there is no clash with `batman-slot`'s global `v`;
  - the missing-lib paths (arm dies; disarm takes its "unreadable" path) use a `type` guard under `set -u` (`:38`);
  - every `bf_get` consumer is Pi 4-gated;
  - the lifecycle device assertions (`SLOT REBOOT mode=explicit`, K90's kmsg line) match `batman-slot:1021-1022` and
    `batman-reboot:39`.
- §2:
  - the cause table now matches `finish()`'s return paths (`wtxn.go:293-366`), and the hand-off is correctly not a
    failure (`:331-335`);
  - the gates match the verbs' (`node.go:254,263`);
  - the separate backoff prevents the 30-min `EState`;
  - the lifecycle has SIGTERM, respawn, skipped BootFinish, both platforms and dependency restarts.
- §3:
  - the marker set matches every run-dir write in `batman-autocommit` (`grep` of `$RUNDIR`, `CTL`, `CANARY_LATCH`,
    `warn_once`);
  - the p6 audit is correct;
  - the accepted canary / syslog effects are listed.
- §4 / §5 / §6 / §7: unchanged from v2 and verified there.

## Summary

| # | Sev | One line |
|---|---|---|
| m1 | MINOR | §2 security: member / reacquire peers reach `finishGated` before the op signature check (`node.go:269` vs `:300`, `session.go:74-92`); reword and retarget test (g) |
| m2 | MINOR | §2 bounds understated: setkey rc 3 ≈ 4.3 min, a failing save up to < 300 s; say "< Exec deadline per step" |
| m3 | MINOR | §3 dry lock records main only; the orphaned dry watchdog survives `kill $p` and races the next run; take over by process group, unlock on EXIT |
| m4 | MINOR | §1 `BATMAN_LIB` root code-path seam: justify it (root-only env, `cleanEnv`, `BATMAN_FW_ALLOWLIST` precedent) and use it in `cmd_reboot` too |
| m5 | MINOR | §3 `:583` reachability is verified now (DRY exits at `:572`) |
| m6 | MINOR | §2 / §8 attach the wsl.34 reproduction log before implementation |
