# Code review A, re-check (2026-11-22)

Reviewer A. Read-only. This re-checks my code review (`v16g1-code-review-A.md`) against:

- product 2cb38dd (`exec.go` `cleaningUp` and the early return; `killedNote` re-look; tests);
- product 8568a78 (dry-lock take-over and traps; `BATMAN_LIB` file check; tests; design text);
- harness 3511544 (run-anchored log; RDF).

**Run here (Windows / Git Bash)**

- ✅ `tests/prov-p1/tryboot-ack.sh` on HEAD: `cases=22 fails=2`. Both FAILs are the two `BATMAN_LIB` group-writable
  cases (the directory, and now the file), which this host cannot set up. Flip test: `chmod 664 <file>` and
  `chmod 775 <dir>` leave `-rw-r--r--` / `drwxr-xr-x` here (`ls -l` output checked), so the precondition never
  exists on NTFS. That is the same attribution as in round 1, and it is not a product finding. Every other case
  passes, including "pi4 disarm no lib" and "pi4 arm no lib".
- ❌ Go tests not run: no toolchain on this host. The commit message reports `go test ./provstore` and root
  `-tags prov_test` passing in WSL, with the D-state case at 23.2 s. That is ⚠️ their evidence, not mine.
- ❌ `autocommit-dry.sh` not run: rundir.sh refuses NTFS.

**Verdict: APPROVE.** The MAJOR is closed and I found no regression. The four MINORs below are optional polish; none
blocks merge.

## M1 (the TERM handler's cleanup children): CLOSED

- **The code.** `exec.go` `cleaningUp` walks the ppid chain inside the member map.
  - The ppid is `stat` field 2 after the last `)`, which is correct: `f[0]` state, `f[1]` ppid, `f[2]` pgrp.
  - A member whose ancestor in the group has a TERM handler is spared at 10 s together with the handler. So
    `sync` / `umount` run by `batman-config-save`'s trap get the 30 s bound.
  - Members outside any handler subtree still get SIGKILL at 10 s. That includes the TERM-ignoring grandchild of
    `TestExecKillsTheGroupThatTrapsTERM`, whose parent died and which was reparented outside the group.
  - The chain walk is bounded at 64 steps.
- **The test now discriminates.** `TestExecHandlerGetsMoreThan10s` uses `sleep 15 && touch` and asserts
  `el >= 15 s`. Under the round-1 `stopGroup` the `sleep` is KILLed at 10 s, `&&` skips the `touch`, and the test
  fails ("cut at 11 s", per the commit). That is a valid negative control.
- **D-state timing (my m1).** If nothing is cleaning up after the 10 s round, `stopGroup` returns, so a blocked
  member without a handler is abandoned at deadline + 10 + 10 s. `TestExecAbandonsDState` now pins ≤ 26 s (2 s
  deadline + 24 s). Closed.
- **`killedNote` (my m2).** It re-scans for up to 1 s before reporting "could not be killed". Closed.

## Other round-1 findings

| # | Status |
|---|---|
| m3 (dry lock) | TERM / INT traps → the EXIT trap runs on a kill, tested (busybox sh in CI). The take-over is rm + mkdir. Mostly closed: see n1 |
| m4 (portability) | CI runs `autocommit-dry.sh` under dash **and** `busybox sh` (`ci.yml` new line). Closed. I still recommend the read-only `busybox find /tmp -maxdepth 0 -mmin +1` probe on 04 once, because CI's busybox may not have the node's applet config |
| m5 (retry tests) | `TestBootRetryPostponedWhileOTA` (real slot flock) and `TestBootRetryWaitsForTheMutex` were added. The wall-clock-step case was handled by correcting the §11 text instead (the code uses `time.Sleep`, which is monotonic). Accepted |
| m6 (harness anchoring) | The `logger -t batman-dv-run "$RUN start"` marker is in, and every judgement reads `sed -n "/$MARK/,\$p"`. `RUN` is `[a-z0-9]` + digits (`prov-254.sh:40`), so it is safe in the sed address. The design §2 device steps were updated to match the unit as built. Closed |
| m7 (`BATMAN_LIB` file) | `lib_ok` checks both the directory and `bootfacts.sh` (exists, not a link, `-O`, not group- or other-writable). Closed |

Not regressed:

- the production autocommit names (`ACD=$RUNDIR`) are unchanged;
- the dry watchdog subshell does not inherit the main's EXIT / TERM traps (a subshell resets caught traps), so it
  never removes the main's lock;
- the Pi 3 paths in `batman-slot` are untouched;
- the RDF no longer restores `autocommit.dry.lock`, which is right: a dead pid would be planted back.

---

## MINOR (new or remaining, none blocking)

### n1. The dry-lock take-over can still let two dry runs through

- **Code:** `batman-autocommit`, the DRY block, `rm -rf "$DLOCK"; mkdir "$DLOCK"`.
- **The interleaving:** A and B both find the stale lock dead (`dry_alive` false). A runs `rm`, then `mkdir`, which
  succeeds. B's `rm -rf` then removes **A's new** lock, and B's `mkdir` succeeds as well. Both proceed. The
  comment's claim "only one mkdir wins" does not hold for that interleaving.
- **Impact:** test seam only, and the harness serialises its runs, so the impact is negligible.
- **Fix (simplest and fully robust):** `exec 8>"$RUNDIR/autocommit.dry.flock"; flock -n 8 || exit 1`. busybox
  `flock` is on the node; it is in `RAMFS_COPY_BIN`, `platform-ab.sh:40`. A kernel lock dies with its holder, so no
  stale-lock logic is needed. Otherwise, correct the comment.

### n2. `tryboot-ack.sh` "no lib" rows now test the default path, not the override

- `BATMAN_LIB=$T/nolib` (no `bootfacts.sh`) now fails `lib_ok`, so `BATLIB` falls back to `/usr/lib/batman`.
- The rows pass only because the test host has no `/usr/lib/batman/bootfacts.sh`. On a host that has one, they
  would load it and fail for the wrong reason.
- **Fix:** after `eval "$loader"`, set `BATLIB=$T/nolib` directly for those rows, or assert that
  `/usr/lib/batman/bootfacts.sh` is absent as a precondition and FAIL (not pass) otherwise.

### n3. No test for a TERM-ignoring member *under* a handler shell

- Round 1 asked for this case (spared at 10 s, killed by the 30 s bound). It was not added.
- The code path exists: the `el >= 30*time.Second` branch, which kills every member still there.
- The case: `sh -c 'trap "sleep 1; exit 0" TERM; sh -c "trap \"\" TERM; while :; do sleep 1; done" & while :; do sleep 1; done'`.
  The inner child is a member under the handler, ignores TERM, and is not killed when the outer shell exits,
  because after reparenting it is no longer under a handler. So the next round kills it. Worth a case, so that the
  10 s / 30 s split stays pinned for "ignores TERM but sits under a handler".

### n4. 30 s worst case under a handler: say it in the `Exec` doc comment

- A handler process that never exits (a trap that loops) now holds the helper's mutex up to 30 s + 10 s.
- `exec.go:20-23` mentions "30 s later for all". Add that this is the worst case per deadline, so the §2 mutex-hold
  text (≈ +10 s) and this line agree. The §13 text already says "up to 20 s longer, only in that case".
