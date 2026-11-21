# Review B — `254-v16-group1.md` §12 v2 (round 5, 2026-11-21)

Reviewer B. Scope: the rewritten §12 (TERM, then poll `kill(-pgid, 0)` for up to 10 s, then SIGKILL only a non-empty
group) against `provstore/exec.go`, its callers and children, and the whole design. Read-only; no node touched. The
2026-11-21 probes the coordinator relayed (`pid_max` 32768, `/dev/vcio` `crw-------` root, GET word 5 `0x80000004`
on 04 and 02) are taken as given.

**Verdict: APPROVE-WITH-CHANGES.** The poll-then-kill rule fixes reviewer A's v4 M1 (a member's TERM cleanup is no
longer cut short) and my v4 m1 (it returns promptly when the group empties). It keeps the pgid reuse argument sound.
There is no BLOCKER and no MAJOR. Five MINORs follow.

## Checked

- **The grace for members.** In A's case, `halow-setkey` is the leader and has no TERM trap. The member
  `batman-config-save` has `trap 'exit 143' TERM`, which runs its EXIT cleanup (`sync; umount "$MNT"`), at
  `batman-config-save:131-141`. The poll waits for it (step 2). Test (2) discriminates against the immediate-KILL
  mutant.
  - busybox ash runs the trap after the foreground command ends. That command got the group TERM too, so the trap
    runs promptly unless it is in `sync` (MINOR-1).
- **Pinning.** While any member is alive, its pgid refers to the group, so `-pgid` cannot name another group. The
  leader is reaped at once by the `Wait` goroutine (`exec.go:35`, `:103`), and after that the members pin the id.
  - The codebase already has the stricter pattern: `node/peers.go:73-101` `runCapped` keeps the leader a zombie with
    WNOWAIT, so `-pgid` is pinned for sure. §12 cannot use it as is: a zombie leader keeps `kill(-pgid, 0)` succeeding,
    so "empty" could never be seen.
  - So the reap-then-poll choice is right. The window is stated in MINOR-2.
- **§2.** Only the deadline / cancel path changes. rc 124 stays not retried. The hold grows by at most the rest of the
  10 s, on that path only, and after it no setkey writer and no setkey lock is left over.
- **OTA cancel.** The `ExecSplit` cancel path still returns within 5 s when the group dies on TERM
  (`execsplit_test.go:36`), and only a TERM-ignoring member makes it take the full 10 s.
  - batman-slot's cleanup (`:185-186`) runs in the leader, and the poll waits for it.
  - The private mount namespace dies with the last member.
  - The `setsid` children (`:954`, `:1058`) are outside the group.
- **The D-state test** (`exec_dstate_test.go:90`). When the unkillable process is the leader, the sequence is TERM,
  poll 10 s (non-empty), KILL, wait 10 s, then "abandoned". That is the same total as today, and the text still
  carries "abandoned".
- **Orphan reaping on the node.** The helper is not jailed and runs in no PID namespace
  (`feed/batman-prov/files/batman-provhelper.init`). Orphaned members are reparented to procd, which reaps them.

## MINOR

1. **The assumption "a TERM handler finishes within 10 s" has no evidence. It is also the one place where §12 is
   worse than today.**
   - When does the deadline fire? A 300 s `halow-setkey` overrun (the trigger) is most likely when storage is slow.
     That is the same condition that makes config-save's `sync` (all filesystems, p6 included) slow.
   - Past 10 s the KILL cuts the cleanup, and p5 stays mounted, as in A-M1. Today nothing kills the member, and the
     cleanup finishes eventually.
   - Fix (pick one):
     - (a) Give the evidence: time config-save's TERM → EXIT path on 04 with p6 busy, with a read-only probe such as
       a timed `batman-config-save --check` during a docker load. Then state the residual.
     - (b) Kill only what the bug is about. After the 10 s, read `/proc/<pid>/status` `SigIgn` for the members of
       the group, KILL at once those that ignore TERM, and give the ones that catch it a longer bound (for example
       30 s) before the KILL.
   - Either way, record what happens when p5 is left mounted: the next save hits the #202 T11 rw verification until
     a reboot.
2. **The reuse window is not "microseconds between check and kill".**
   - After the group empties, the next `kill(-P, 0)` comes up to 100 ms later. If P has become a new pgid by then,
     every later poll succeeds, and at 10 s the KILL hits that group. The likeliest such group is one of the helper's
     own concurrent `Exec` children.
   - What makes this negligible is cyclic pid allocation (`alloc_pid` → `idr_alloc_cyclic`). P comes back only
     after 32768 further allocations (`pid_max` on 04 and 02) within ≤ 100 ms.
   - State the window and the bound in those terms.
3. **The poll counts zombies.** `kill(-pgid, 0)` succeeds on a group whose only members are unreaped zombies.
   - On the node, procd reaps orphans, so this is fine.
   - In a test or CI environment whose PID 1 or subreaper does not reap promptly (a container without an init),
     test (3) "returns within 2 s" would wait 10 s. It would also print a false "group member(s) outlived TERM:
     killed".
   - Fix: state the dependency on a reaping init (evidence: the init file above). Optionally, before reporting
     "outlived", scan `/proc/*/stat` for members of the group and ignore state `Z`.
4. **Where the new text line goes.** The callers keep only the last line: `SetkeyError{Msg: lastLine(out)}`
   (`cmd/batman-provhelper/main.go:154-157,180-186`) and `CheckRestorable` (`:257-259`). Appending "group member(s)
   outlived TERM: killed" after "…: timed out after 5m0s" makes the helper's CRIT log and the EApply reason lose the
   timeout fact. Put the note on the same line as the timeout text, or before it.
5. **Correct §1's `/dev/vcio` line with the probe.** §1 Security (`254-v16-group1.md:111`) still says "root 0660, to be
   checked". The probe shows `crw------- root` (0600), which is stricter. Update the text and tick A m7 / §8 step 1 with
   the captured lines. Likewise, cite the word 5 capture on 02 in §1 Evidence.

## Tests

(1)–(4) are adequate. Two notes:

- (1) should assert that the returned text still contains "timed out" (MINOR-4).
- Add a test for the zombie case only if MINOR-3's `/proc` filter is adopted.
