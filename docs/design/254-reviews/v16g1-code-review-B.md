# Code review B — v1.6 group 1 implementation (2026-11-21)

Reviewer B. I reviewed the product branch `fix/254-v16-group1` (worktree `C:/src/Batman-g1`, the 11 commits in
`origin/main..HEAD`) and the harness branch `test/254-v16-group1` (worktree `C:/src/Batman-g1h`, `b1417a0`) against
`docs/design/254-v16-group1.md` v3 + §11–§13.

Read-only, except this file. No ssh and no device command. Offline runs were made in WSL Ubuntu 24.04 (busybox
1.36.1, dash), with scripts and outputs in the session scratchpad.

**Verdict: APPROVE-WITH-CHANGES.** I found no BLOCKER and no MAJOR. The code follows the design closely. Every new
offline test I could run passes, and its negative control on main fails (output below). There are 9 MINORs: three
small deviations from the binding text in §11 / §13, two shell / harness robustness gaps, and three missing unit
cases. None of them changes behaviour in the field paths that were reviewed. They can be fixed in this PR, or the
design text can be adjusted where the code is the better choice.

## What I ran (offline)

| Run | Result |
|---|---|
| `tests/prov-p1/tryboot-ack.sh` on the branch's `batman-slot` + `bootfacts.sh` | `TRYBOOT-ACK cases=21 fails=0` |
| the same on `origin/main`'s pair (negative control) | `fails=6`: `bf_get unacknowledged: [0]`, `pi4 disarm unacked: [CLEARED]`, `pi4 disarm no lib`, `pi4 arm unacked: [DIE tryboot flag did not arm (GET returned 0x00000000)…]`, `pi4 arm no lib: [ARMED]`, `BATMAN_LIB group-writable honoured` |
| `tests/prov-p1/autocommit-dry.sh` on the branch, `sh` = dash (as in CI) | `AUTOCOMMIT-DRY cases=10 fails=0` |
| the same with `sh` = **busybox ash** (the node's shell) | `cases=10 fails=0` |
| the same on `origin/main`'s `batman-autocommit` (negative control) | `fails=8`: real `autocommit.decided` / `autocommit.wd` created, `ota-armed.mesh` removed, `AC START` otalog line, second dry run gets no REVERT, the concurrent run is not refused, the planted symlink is not replaced |
| busybox ash: an EXIT trap in the main shell, and `exit` inside a `( … ) &` subshell | the trap ran once (main only): the dry watchdog subshell does not inherit `dry_end` |
| `scripts/lint-install-mode.sh` (harness) on the product branch | `LINT-INSTALL-MODE files=46 bad=0` |
| Go tests (`provstore`, `node` bootretry, `cmd/batman-provhelper`) | ⚠️ **not run**: WSL has go 1.22.2 and `go.mod` requires ≥ 1.26.4 (`GOTOOLCHAIN=local`). I did not download a toolchain. The Go findings below come from reading the code and tests. |

## Checked and OK

- **L175**
  - `bf_vc_ack` (`bootfacts.sh:19`) uses positional parameters only.
  - `bf_get` uses it.
  - In `batman-slot`, `disarm_tryboot` (`:421-439`) and `arm_tryboot` (`:791-825`) apply it only on `layout = pi4`;
    the Pi 3 branch is byte-for-byte the old logic.
  - Library missing: arm dies (`:807`) and disarm warns "cleared blind". The `type` check is done under `set -u`.
  - `layout()` is safe to call unconditionally now, because every verb that reaches arm / disarm runs
    `detect_layout` first (`:1070`).
- **L96**
  - Production `ACD=$RUNDIR`, so every real marker keeps its name.
  - In DRY, every marker goes to `autocommit.dry.d`; `otalog` / `otalog_k` are no-ops (`:121`); and
    `rm ota-armed.mesh` moved after the DRY exit (`:249`).
  - `held()` reads the real `hold-consumed` without writing it (`:103`).
  - The lock (`:262-281`): pids are written via temp file + rename; takeover happens only when all pids are gone or
    the empty pid file is older than 1 min; a dir that is not ours ends the run; the `rm -rf` + `mkdir -m 700` +
    ownership check never falls back to the real names.
- **L111** (`wtxn.go`)
  - Every `return fail(...)` in `finish()` sets `lastFinishCause`.
  - `retryable()` matches the §2 table, and unknown / rc 1 / 137 / 143 / 124 are not retried.
  - The tries run under `n.mu`.
  - The gates are `.txn` gone → stop, then `otaBusy()` / `IsTrial()` → postpone without counting, logged once.
  - A failed retry does not call `noteFinish`; a successful one resets the backoff.
  - The clock is `time.Sleep` (monotonic).
  - Tests (a), (b), (c), (e), (e'), (e''), (f-trial), (g) and (h) exist in `node/bootretry_test.go`. (g) is now the
    member-role invalid-chain case, as review v3 asked.
- **L112**
  - A4 m1: `main.go:125-133` with `TestRealSysDeviceReadFailureIsTransient`.
  - The encryption rc classes, `TestHandOffNotOnRC124`, χ² 119.9, and the `exec_dstate_test` comment.
  - A4 m4 inode test (`cfgsave-txn-save.sh:142-154`): it FAILs on an empty before/after list, and rename-replace
    always allocates the new inode before the old one is freed, so it discriminates.
- **§12/§13 `stopGroup`** (`exec.go:140-229`, `stopGroup` from `:145`)
  - Kills go to the pids just scanned, never to `-pgid`.
  - Zombies are excluded.
  - The `stat` parsing splits at the last `)`, so it is safe against a crafted `comm`.
  - `SigCgt` bit 14 is SIGTERM.
  - The "outlived" / "could not be killed" note goes before the "timed out" line, so `lastLine` callers keep the
    timeout text.
  - A local unprivileged process cannot join the helper's children's process group: `setpgid` across sessions is
    EPERM, and procd starts the helper in its own session. So the member list is trustworthy.
- **L75.** All 46 `INSTALL_BIN` sources are 100755, including the two provd init scripts.

## MINOR

1. **The D-state / abandoned path now takes 30 + 10 s, not "10 + 10 s as today" (§13 deviation).**
   - `stopGroup` (`exec.go:145-171`, soft round at `:162-168`) sends the soft KILL at 10 s. An unkillable member (state D, no handler) stays
     in the group, so the loop runs on until the 30 s branch, then `Exec` waits another 10 s (`:46-50`).
   - `TestExecAbandonsDState` still passes, because its limit is 60 s (`exec_dstate_test.go:93`). But under `n.mu`
     the helper is held about 20 s longer than §13 states.
   - Fix: after the soft round, if no remaining member catches TERM, return at 20 s (10 s after the KILL). Or
     correct §13's sentence.
2. **The 10 s soft round can kill the cleanup helpers of a TERM-handling member.**
   - A process forked *after* the initial `kill(-pgid, TERM)` never received TERM and has no handler, for example
     the `sync` or `umount` that `batman-config-save`'s trap runs (`batman-config-save:131-141`). If it is running
     at the 10 s scan, it is SIGKILLed (`exec.go:162-168`).
   - That defeats part of the 30 s grace §13 gives that handler (A's v4 M1 scenario, narrowed to the slow-storage
     case the 30 s exists for). Killing a `sync` does not stop the kernel flush, so the realistic loss is an
     `umount` cut before its syscall.
   - Fix: in the soft round, spare a member whose parent (`stat` field 4, ppid) catches TERM. The ppid is already
     in the parsed fields.
   - Test: a handler that forks a 12 s non-handler child inside its trap; the child is not killed at 10 s.
3. **A dry main killed by a signal leaves its lock and its watchdog (§11 deviation).**
   - busybox ash runs no EXIT trap when TERM kills it (the reason `batman-config-save:136-141` traps TERM / INT).
     So `dry_end` (`batman-autocommit:270, 278`) does not run when the harness kills the main.
   - The harness was not changed to "kill both through the session" as §11 says. `prov-ac-flap-254.sh:32`,
     `prov-autocommit-p3-254.sh:28` and `chain1-254.sh:320` still `kill $p` (the main only).
   - Result: the watchdog subshell lives on and its pid keeps the lock "alive", so a following dry unit in the same
     boot exits 1 ("another dry run is running") until that watchdog ends. This is not unsafe, but it is a spurious
     refusal.
   - Fix: add `trap 'exit 143' TERM; trap 'exit 130' INT` next to `trap dry_end EXIT` (the existing precedent), or
     make the harness kill the session as §11 says.
   - Test: in `autocommit-dry.sh`, kill a dry main with TERM, then check that the lock is gone and the watchdog pid
     is dead.
4. **Missing unit cases that §2 / §11 name.**
   - The `otaBusy` arm of the postpone gate: only `IsTrial` is tested (`TestBootRetryPostponedWhileTrial`). Hold the
     slot flock, or set the updater's worker or window, and assert there is no try and no count.
   - (d) a try never overlaps a verb. It is structurally true (the try runs under `n.mu`), but §2 lists it.
   - §11 B m6's "unit test steps the wall clock back mid-wait". With `time.Sleep` plus a sleep seam the wall clock
     plays no part. Either drop that sentence from §11 or add a test that changes `r.sys.now` between steps and
     shows the schedule unchanged.
5. **§11 contradicts §2 on save rc 1 / 143, and the code follows §2.**
   - §11 B m7 says "any setkey / forget / **save** rc outside {2, 3} and {124} … is unknown and not retried".
   - The code (`wtxn.go:370-374`, `retryable()` includes `causeSave`) retries every save rc except 124, which is
     what the §2 table says.
   - Fix the §11 sentence: setkey / forget only. The code is the better choice: a save rc 1 / 8 (lock busy) is
     curable.
6. **`BATMAN_LIB` checks the directory but not the file it sources** (`batman-slot:46-53`).
   - `bootfacts.sh` inside a root-owned, non-writable directory can still be a symlink to anywhere, or a file
     writable by others, and parent directories are not checked.
   - Only root can set root's environment, so this is not an escalation. But the stated rule (#280) is "nothing
     another user can write".
   - Either check `[ ! -L "$BATLIB/bootfacts.sh" ] && [ -O "$BATLIB/bootfacts.sh" ]` and the file's mode, or reuse
     `rundir.sh`'s `_rd_mode` instead of a second `ls -ld` glob implementation.
7. **The CI runs the new shell tests under bash / dash, not busybox ash.**
   - `tryboot-ack.sh` evaluates the extracted functions in bash. `autocommit-dry.sh` runs `sh` (dash on
     ubuntu-latest).
   - The node shell is busybox ash, and the CI job already installs busybox (`ci.yml:113`). I ran the dry test under
     busybox and it passes.
   - Add a busybox pass to CI, as `addr-defer.sh` already does (`ci.yml:120`). This covers `[ -O ]`, `find -mmin`,
     the `ls -ld` glob and the trap semantics.
8. **The harness unit `prov-bootfinish-retry-254` differs from §2's device steps.** The unit injects a leave plus a
   forget rc 3 (two injections), then restarts the helper. §2 specifies a txn-2 sysrq, rc 2 and helper init disabled.
   - The implemented unit is simpler and better (no sysrq, no disabled init). Update §2 / §8 to match, including
     the side effects stated in its header.
   - Its judgement is not anchored to this run:
     - `inj` counts every `batman-dv-inj` line in `logread`, including a previous run in the same boot.
     - `tf` takes the first `boot finish:` line found, which can be an old one.
     - The PASS grep searches the last 14 helper lines for `finished (boot retry N)`.
   - On a re-run in one boot, stale lines can satisfy the gates. Fix: log a `RUN=$RUN start` marker and judge only
     lines after it.
9. **Lock removal by the harness restore.** `prov-misc-254.sh` now snapshots and restores `autocommit.dry.lock`
   (`RDF`, `:37`). Restoring a lock captured while a dry run was live re-plants dead pids. That is harmless, because
   the next run takes over. Excluding `.lock` from the restore would be cleaner; it only needs removing.

## Security summary (per actor)

- **Local unprivileged process.** It cannot reach `/tmp/run/batman` (root 0700), so `autocommit.dry.d`, the dry
  lock and `.txn` are out of reach. It cannot join the helper's process groups, so `stopGroup`'s member list cannot
  be spoofed into killing it or sparing it. `/dev/vcio` is 0600 root (probe, §13).
- **Root environment** (`BATMAN_LIB`): MINOR-6.
- **Compromised member-role peer.** The Finish rate is unchanged, and test (g) asserts it.
- **Our own mistakes.** MINOR-1, -2 and -3 are the places where the implementation's timing or trap semantics
  differ from what the design states. Each has a cheap fix and a test.
