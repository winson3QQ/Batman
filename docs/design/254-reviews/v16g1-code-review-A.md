# Code review A — v1.6 group 1 implementation (2026-11-21)

Reviewer A, independent. Read-only.

**Scope**

- Product: `C:/src/Batman-g1`, `fix/254-v16-group1`, `origin/main..HEAD`, 11 commits.
- Harness: `C:/src/Batman-g1h`, `test/254-v16-group1`, b1417a0.
- Reviewed against `docs/design/254-v16-group1.md` v3 + §11–§13.

**What I ran on this host (Windows, Git Bash)**

- ✅ `bash tests/prov-p1/tryboot-ack.sh` on the branch: 20 ok, 1 FAIL, as follows.
  - The FAIL is `BATMAN_LIB group-writable honoured`. I attribute it to the host, with a flip test: on this host
    `chmod 775 <dir>` leaves `drwxr-xr-x` (checked with `ls -ld` on the scratch dir), so the test's precondition
    cannot be built here. This is not a product finding. CI on Linux decides.
  - ✅ Negative control: the same test on `origin/main`'s `batman-slot` + `bootfacts.sh` gives `cases=21 fails=6`
    (bf_get unacked → 0; pi4 disarm unacked / no lib → CLEARED; pi4 arm unacked → the old reason; pi4 arm no lib →
    ARMED). The test discriminates.
- ❌ Go tests not run: there is no Go toolchain on this host.
- ❌ `tests/prov-p1/autocommit-dry.sh` not run: rundir.sh refuses the NTFS scratch dir ("not a private directory of
  ours"). Both need CI or Linux.

**Verdict: APPROVE-WITH-CHANGES.** One MAJOR (M1, `provstore/exec.go`) must be fixed before merge. After the fix,
`exec.go` and its tests need a re-check, nothing else. L175, L96, L111, L75 and the rest of L112 match the design;
the MINORs below can go in with the fix.

---

## MAJOR

### M1. `stopGroup` SIGKILLs a TERM handler's own cleanup children at 10 s, and the test meant to guard this cannot see it

- **Where:** `feed/batman-prov/src/provstore/exec.go` `stopGroup`, the `el >= 10*time.Second && !soft` branch; and
  `groupMembers` / `catchesTERM`.
- **Design.** §13 says: "Members with a TERM handler (config-save's `sync; umount` of p5 on a slow card) get up to
  30 s."
- **Code.** At 10 s every member with no TERM bit in `SigCgt` gets SIGKILL. A shell's trap runs its commands as
  **new child processes with default dispositions**, in the same group.
  - `batman-config-save:131` cleanup runs `grep`, `sync`, `umount`, `rmdir`, `rm`.
  - If the slow step (the `sync` on a slow card, or the `umount`) is running at the 10 s mark, it is SIGKILLed. The
    shell, which has the handler, is spared, but the work it is waiting for is the thing killed.
  - A KILLed `umount` that had not yet entered `umount2` leaves p5 mounted rw. That is the exact outcome review v4
    A-M1 was about.
- **The test cannot see it.** `TestExecHandlerGetsMoreThan10s` (`exec_group_test.go`) uses
  `trap "sleep 15; touch $mk; exit 0" TERM`. At 10 s, `sleep 15` (no handler) is SIGKILLed, `;` goes on, `touch`
  runs, and the marker exists. The test passes even though the handler's step was cut at 10 s. It would also pass
  for a "kill every non-handler at 10 s" mutant, which is today's code.
- **Fix.**
  - At 10 s, spare every member whose parent chain inside the group reaches a live member with a TERM handler. The
    ppid is field 2 after `)` in `/proc/<pid>/stat`, which `groupMembers` already parses. Those members get the 30 s
    bound with their handler.
  - SIGKILL at 10 s only the members that ignore TERM, or that have no handler anywhere above them in the group.
- **Test.**
  - Change it to `trap "sleep 15 && touch $mk" TERM`, so the marker means "the step ran to its end", and assert
    `Exec` took ≥ 15 s.
  - Negative control: the current code fails it.
  - Keep a separate case: a TERM-ignoring child **under** a handler shell is still killed by 30 s.

---

## MINOR

1. **`exec.go` `stopGroup`: the unkillable (D-state) case now takes ≈ 40 s, not "10 + 10 s as today" (§13).**
   - A leader in D with TERM pending has no handler, so it gets SIGKILL at 10 s. It stays in D, so the loop keeps
     polling until 30 s and sends SIGKILL again. Then `Exec` waits another 10 s for `done` before "abandoned".
   - The helper mutex is held about 20 s longer in the §16.1 case.
   - `TestExecAbandonsDState` (`exec_dstate_test.go`) caps at 60 s, so it cannot see this.
   - Fix: remember the pids already SIGKILLed. Once only those remain and no handler member is left, stop polling.
     Pin the bound in the D-state test (abandoned ≤ 25 s after the deadline).
2. **`exec.go` `killedNote`: possible false "a group member could not be killed".**
   - It rescans right after `stopGroup`'s 30 s KILL. A member KILLed microseconds earlier can still be listed (not
     yet a zombie).
   - Fix: re-scan for up to about 1 s before reporting a survivor.
3. **`batman-autocommit` dry lock (the `dry_alive` / `DLOCK` block): takeover is not atomic, and kills skip the
   unlock.**
   - Two dry runs that both find a stale lock both log "taking over" and proceed: neither has to win a `mkdir`.
     Fix: `rm -rf "$DLOCK" && mkdir "$DLOCK"` as the winner test, and the loser exits 1.
   - busybox ash runs no EXIT trap when a signal kills it (the `batman-config-save:136-141` comment says so). A
     harness `kill` therefore skips `dry_end`: the lock stays and the watchdog subshell lives on. Takeover recovers
     from that, but only after the watchdog ends.
   - Fix: add `trap 'exit 143' TERM; trap 'exit 130' INT` in the DRY block, as config-save does.
4. **Portability coverage.**
   - `tests/prov-p1/autocommit-dry.sh` runs the product script with `sh` (dash on CI).
   - The new DRY code relies on busybox semantics: `find "$DLOCK" -maxdepth 0 -mmin +1` (an optional busybox
     feature), `[ -O ]`, and the EXIT trap.
   - `tests/prov-p1/s5-autocommit.sh` already uses `busybox sh`. Run the dry test the same way and put busybox's
     `find` first on PATH.
   - Read-only probe I would want on 04: `busybox find /tmp -maxdepth 0 -mmin +1; echo rc=$?`. If `-mmin` is
     missing, `dry_alive` reads an empty fresh lock as alive forever.
5. **L111 test gaps against §2 / §11.**
   - (f) is tested only for `IsTrial`; `otaBusy` (the upload window / slot flock) has no case.
   - The §11 B m6 test is missing ("a unit test steps the wall clock back mid-wait"). The code uses `time.Sleep`
     (monotonic), but the binding text asks for the test.
   - (d) (a try never overlaps a verb) is only implicit.
   - The rest are present and look discriminating: (a), (b), (c), (e), (e'), (e''), (g), (h). Their stated negative
     control is "remove the `bootRetry` call".
6. **Harness `scripts/dv/prov-bootfinish-retry-254.sh`.**
   - It deviates from the design's §2 device steps: forget rc 3 on a leave plus a helper restart, instead of txn-2,
     setkey rc 2 and a sysrq reboot. That is reasonable (no sysrq), but record it in the design.
   - Its log anchoring is loose:
     - `tf` is the **current** uptime when any `boot finish:` line exists in logread, not that line's time. A line
       from an earlier helper start in the same boot satisfies the wait at once.
     - The PASS grep `finished \(boot retry [0-9]+\)` in the last 14 lines can match an earlier run's line, giving a
       false PASS on a rerun in the same boot.
   - Fix: write a `logger -t batman-dv-mark <RUN>` line at `t0`, and judge only the lines after it.
7. **`batman-slot` `BATMAN_LIB` (`:46-52`).** The directory is checked: owner, not a link, not group/other-writable.
   The file `bootfacts.sh` inside it is not. Add the same checks for the file (not a link, owned by us, not
   group/other-writable). The risk is low (only root sets root's environment), but it costs one line, and the #280
   rule is about the file that gets executed.

---

## Checked and fine

- **L175.**
  - `bf_vc_ack` uses positional parameters only (`bootfacts.sh:19`).
  - Pi 4 disarm / arm branches match the §1 table, including the missing lib: arm dies; disarm warns "cleared blind".
  - The Pi 3 paths are byte-for-byte the old logic.
  - `bf_lib` is only reached on pi4.
  - `cmd_reboot` uses `$BATLIB`.
  - The `ls -ld` mode globs `?????w*` / `????????w*` hit exactly group-w / other-w.
  - Stage 2 has `/usr/lib/batman/bootfacts.sh` (`RAMFS_COPY_DATA`).
  - The B4 m7 hint text is updated.
- **L96.**
  - Production paths: `ACD=$RUNDIR`, so every real name is textually identical to main (`DECIDED`, `COMMITTED`,
    `CTL`, `RUN`, `HOLDC`, `deadline` / `start`, `why`, `wd`, `warn-*`, `canary-ok`, `ble-warned`,
    `hold-discarded`).
  - In DRY: `otalog` / `otalog_k` are no-ops; `rm ota-armed.mesh` moved after the DRY exit; `held()` reads the real
    plant and writes only its own.
  - The dry dir is `rm -rf` + `mkdir -m 700` + `-O` / `!-L`, failing with exit 1 and no fallback.
  - `s5-autocommit.sh` is adapted (`ACD`).
- **L111.**
  - The cause table matches `finish()`'s return paths (`wtxn.go` diff).
  - `retryable()` = {resolve, txn-write, restore-check-transient, setkey-rc2, setkey-rc3, save}; unknown, rc 1 /
    143 and 124 are not retried.
  - `lastFinishCause` is read under `n.mu`.
  - Retries do not call `noteFinish` on failure, and do on success.
  - The postpone path is unbounded, not counted and logged once.
  - BootFinish's unlock moved from `defer` to an explicit call; a panic would crash the process anyway.
- **L112 A4 m1** (`main.go:125-131`): `uci get .device` rc ∉ {0,1} → error; `TestRealSysDeviceReadFailureIsTransient`
  has a valid negative control.
- **The other L112 changes:**
  - A4 m4 inode test: new files are created before the old unlink, so the inode must change; the `cat >` mutant
    keeps it.
  - A4 m5: 119.9.
  - `TestHandOffNotOnRC124`.
  - The encryption rc classes.
- **L75.**
  - Mode-only changes.
  - CI runs `lint-install-mode.sh`, which lives in the harness PR (the #290 order is stated).
  - The lint parses the `$(if …)` names in both forms and FAILs on zero files.
- **`exec.go` `/proc` parsing.**
  - It uses `LastIndexByte(')')`, which is robust to a hostile `comm`.
  - It skips zombies.
  - Kills go only to pids seen in the scan, never to `-pgid` after the initial TERM. The initial TERM is the same as
    main's.
  - A lower-privileged process cannot join the group (`setpgid` is limited to its own session and its own children).

## Summary

| # | Sev | file:line | One line |
|---|---|---|---|
| M1 | MAJOR | `provstore/exec.go` `stopGroup` 10-s branch; `exec_group_test.go` `TestExecHandlerGetsMoreThan10s` | the 10-s KILL hits a handler's cleanup children (`sync` / `umount`); the test passes anyway (`sleep 15; touch`) → spare the descendants of handler members; `sleep 15 && touch` + elapsed ≥ 15 s |
| m1 | MINOR | `exec.go` `stopGroup` | a D-state leader → abandoned at ≈ 40 s, not 20 s (§13); pin it in the D-state test |
| m2 | MINOR | `exec.go` `killedNote` | a just-KILLed member can be reported as "could not be killed" |
| m3 | MINOR | `batman-autocommit` DRY lock block | the stale-lock takeover is not atomic; an ash TERM skips the EXIT trap → trap TERM / INT |
| m4 | MINOR | `tests/prov-p1/autocommit-dry.sh` | runs under dash; run it under busybox sh (`find -mmin`, `-O`, EXIT trap); probe `find -mmin` on 04 |
| m5 | MINOR | `node/bootretry_test.go` | no `otaBusy` postpone case, no wall-clock-step case (§11 B m6), no explicit mutex case |
| m6 | MINOR | harness `prov-bootfinish-retry-254.sh` | deviates from the §2 steps (record it); the log lines are not anchored to this run → an INVALID or false PASS on a rerun |
| m7 | MINOR | `batman-slot:46-52` | `BATMAN_LIB` checks the dir, not the file `bootfacts.sh` |
