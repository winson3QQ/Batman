# Review v5 (reviewer B) — `docs/design/254-v16-ud.md` at 3ab6d27

I read the whole document again. I looked first at what v5 changed: §0.5 (E-UD2), the UD4 rule, the cut sub-arm's
p3, the `ssid-restore` value rule plus its round trip, the observe key, the printing of the watcher log, §7 and the new
§7.1. Then I checked the §7.1 manual sequence step by step against `prov-254.sh`, `prov-base-254.sh` and
`prov-undo-lib-254.sh`. Read-only: no node, no ssh. The mesh-id history is not a finding (owner).

## v4 findings: fixed in source terms?

| v4 finding | State | Evidence |
|---|---|---|
| **B M1** no automatic recovery | **The disposition is right** (option b: NEEDS-PERSON, stated in §1.7 / §7; #254 checklist line; P9 prints the procedure). **The printed procedure itself does not work: MAJOR-1.** | `prov-254.sh:46, 181-246, 460-498, 527-545`; `prov-base-254.sh:145, 157, 332-336` |
| B m1 stale §9 test | fixed (line removed) | — |
| B m2 / A m2 `ssid-restore` rule | **Fixed.** One rule (1–32 bytes, no NUL, no newline) at registration and at replay, plus a byte-for-byte round trip at `undo-add` → INVALID before the change. Tests cover `'`, `%`, `\`, `*`, a blank, empty and a newline. | `prov-undo-lib-254.sh:239-240`; `batman-config-save:52-58` |
| B m3 / A m1 cut margin | **Fixed.** p3 is re-read with no I/O before `b`, and `late` means no cut. The margin argument is stated (BAD clears only after the `dd`'s own fsync, the boot copy and an uncached read-back, `batman-slot:735-775, 856`). `fsync_s` is logged. See MINOR-1 for the host side of "no cut". | — |
| B m4 observe key | fixed (version + eth MAC + date) | — |
| B m5 print before delete | fixed (non-blank lines + sha, then delete) | — |
| **A M1** pstore is a module | **Correctly overturned** by `v16ud-eud2.log`, which I read: nothing in `/proc/modules`; `CONFIG_PSTORE=y`, `CONFIG_PSTORE_RAM=y`; built-in ramoops parameters (`record_size=16384`, `mem_address=184549376`); dmesg `pstore: Registered ramoops as persistent store backend` at 0.016706 s; DT node `ramoops@b000000`; `/sys/fs/pstore` mounted. Whether this particular panic leaves a record is still run-proven only, and the doc says so (⚠️). | `v16ud-eud2.log` |
| A m3 UNCLEAN at UD4 | fixed (INVALID with the line attached) | `95-batman-storage:657-687` |
| A m4 stale ap-on text | fixed | — |

## Findings

### MAJOR-1 — the §7.1 recovery block, which P9 will print for a person, does not work as written

Each problem below is in the exact block of §7.1 (lines 538-545).

1. **`PR_WROTE_B=1` passed in the environment is wiped by sourcing the library.** `prov-254.sh:46` runs
   `PR_WROTE_B=0; PR_RESTORING=0; PR_DEADLINE=0; …` at source time. Step 2's `pr_restore` then judges the compare with
   `PR_WROTE_B=0` (`:494`). After any write, kill or trial arm, `begin_write` has removed `slot-B.protected`
   (`batman-slot:479`), so the identity DIFF on `protB` makes `pr_restore` FAIL "S0 not restored". The `&&` chain
   stops before `pr_brewrite` and `pr_finish_snap`, and the dirty flag stays. This is exactly the case the block exists
   for. Set `PR_WROTE_B=1` **inside** the `-c` string after the `.` (as is already done for `PR_BEGUN` /
   `PR_SNAPPED`). `PR_V`, `PR_BASE` and `PR_S0_STATE` are not reset at source time, so passing them in the environment
   works.
2. **The "node on B" case is ordered wrong.**
   - Step 1's replay runs first. `ssid-restore` and `rm-hold` are bound to `slot:A`, so on B the executor leaves them
     `LEFT` (`prov-undo-lib-254.sh:241-242`). Then `pr_acquire` FAILs "undo still left after the replay"
     (`prov-254.sh:214`).
   - Because of `&&`, step 1's `pl release` never runs, so its lease and dead-man stay armed for 3600 s. Step 2's
     `pl acquire` then refuses for an hour.
   - The note "run `back_to_a` first, inside step 2's shell" comes after step 1 has already failed.
   - Also, `back_to_a` itself calls `pr_find` → `pr_acquire` (`:401, 237`), so it needs the sourced shell and a run.
   - Fix: make the slot check the first step. If the node is on B, run `back_to_a` in its own sourced shell with a new
     run id, release, then go on. In step 1, release unconditionally (`pr_acquire 3600; pl release`) so a failed replay
     cannot lock out step 2.
3. **Host death without a reboot.**
   - Step 2 reuses `RUN=$DEAD`. `pr_stage` refuses if `$BT/$DEAD` exists (`prov-254.sh:194`, "FAIL … exists"), and that
     directory survives a host death on the same boot.
   - The dead run's own lease also blocks any `acquire` until its dead-man has fired, because a live lease of another
     run makes acquire FAIL (`prov-lease-254.sh` header).
   - The block covers only the reboot case. Fix: either state "only after a reboot, or after the dead run's dead-man
     has fired", plus a command to check it (`pl state`), or add the removal of the stale `$BT/$DEAD` staging dir as an
     explicit step (it is root 0700 and holds only staged copies of repo scripts; print its listing first, per the
     owner's rule).
4. **P9 prints this block for any dirty run.** The dirty-flag line in `prov-p9-254.sh:71` is fleet- and unit-wide.
   The block hard-codes `PR_UNIT=prov-update-254`, `PR_BASE=member`, `PR_S0_STATE=member` and a B rewrite. For a
   legacy-base unit, `pr_finish_snap` would then compare against the wrong S0 state (`:528-536`). Print the block only
   when the flag names a `pupdate…` run (the run id's prefix); keep a generic line otherwise.
5. **Smaller items in the same block.**
   - "`pidof` it first": the watcher runs as `sh ud9-watch-254.sh …`, so `pidof ud9-watch-254.sh` finds nothing.
     Use the pidfile plus `/proc/<pid>/cmdline`, or `ps w | grep '[u]d9-watch'`.
   - The block does not run §4.1's `PR_UST0` status compare or the "no watcher alive" check. Add both as the last
     read-only step, so the person ends with the same evidence `pr_end` gives.

**Fix overall.** Correct the block as above. Add an offline test that runs the **exact text P9 prints**, after
substituting `DEAD`, against the sourced library with stubbed `ssh` / `scp` / `q` (the `test-restore-254.sh`
extraction pattern). Assert:
- the call order;
- that `PR_WROTE_B` is 1 when `pr_restore` runs;
- a release after a failed step 1;
- refusal on a non-`pupdate` dirty flag.

It is still ⚠️ never run on a device; the test only removes the mechanical errors.

### MINOR-1 — the host must handle "watcher declined to cut" without waiting for a reboot that never comes

With v5, the cut sub-arm can end in `UD9-MISS late p3=…` with no sysrq. If the host, as `pr_killpoint` does, then
waits with `pr_find <secs> <old boot8>` (`prov-254.sh:226-246`, which excludes the old boot), it never finds the node
and ends in NEEDS-PERSON "no node after the sysrq", instead of INVALID.

Define the host flow: after the prepare, poll the p6 log over ssh (`UD9-FIRE` / `UD9-PRE-B` / `UD9-MISS`). If a `MISS`
line appears, stop waiting and judge INVALID. Treat a lost connection as "cut sent" and only then `pr_find` with the
boot exclusion. Add an offline fixture for `MISS late` → INVALID, with no `pr_find`.

## Other v5 changes, checked and sound

- **§0.5 matches `v16ud-eud2.log` line for line.** The `docs/crash-debug.md:54` staleness goes onto the #254 checklist.
- **UD4.** The kernel is V's (`badpayload` changes only `root.squashfs`), so B's boot carries the same built-in ramoops
  at the same reserved address. A PANIC record on the A boot is therefore real evidence of B's boot. A missing record
  stays CLEAN → INVALID, never a false PASS.
- **`ssid-restore` round trip at registration.** It uses the same decoder (`--decode-only`), so nothing accepted at
  `undo-add` can CRIT at replay.
- **The cut sequence: p3 read → `echo b > /proc/sysrq-trigger` (builtin `echo`).** That leaves no other I/O between the
  read and the reset, as stated.
- **`pr_release` prints the watcher log before removing it.** The log holds positions, sizes and uptimes only.
- **Nothing in v5 changes the guards, the lints, the ownership table or the restore of `update-last`.**

## Verdict

**REJECT for this round under the owner's rule (one MAJOR open).** 0 BLOCKER, 1 MAJOR, 1 MINOR.

Every v4 finding of both reviewers is fixed in source terms, and A's v4 M1 is correctly overturned by E-UD2. The open
MAJOR is confined to §7.1 and its P9 printout. The rest of the design I would approve as it stands. Once the block is
corrected and covered by the offline test of the exact printed text, I expect APPROVE.
