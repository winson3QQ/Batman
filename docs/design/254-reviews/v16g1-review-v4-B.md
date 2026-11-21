# Review B — `254-v16-group1.md` §12 addendum (round 4, 2026-11-21)

Reviewer B. Scope: §12 (always SIGKILL the group after the TERM grace in `provstore.Exec` / `ExecSplit`), checked
against `feed/batman-prov/src/provstore/exec.go` and against the rest of the design, §2 in particular. Read-only; no
node touched.

**Verdict: APPROVE-WITH-CHANGES.** The finding is real, and the fix is the minimum: it makes `Exec`'s documented
contract (`exec.go:18-20`) true. There is no BLOCKER and no MAJOR. Five MINORs follow, mostly the exact semantics and
the evidence the text should carry.

## The finding, confirmed in the code

In the deadline branch, `Exec` sends SIGTERM to `-pid` (`exec.go:40`) and then selects between `done` and 10 s
(`:41-43`). The SIGKILL is only in the timeout arm (`:44`).

When the direct child dies on TERM, `Wait` returns:

- at once if no member holds the pipe;
- otherwise after `WaitDelay` = 5 s (`:30`).

Either way the KILL arm never runs, and a TERM-ignoring member survives. `ExecSplit`'s `stop` (`:104-117`) has the
same structure. The new test (`exec_group_test.go:45-64`) builds exactly that case. Its pid-file quoting is right:
`$$` is single-quoted for the outer `sh`, so the inner `sh` expands it to its own pid. ⚠️ I did not run it (this host
is Windows, and `syscall.Kill` does not build there). The negative control "fails on main" rests on the author's run
plus this reading of the code.

## Interaction with the rest of the design

- **§2 retry classes.** rc 124 is not retried. After the fix, no leftover `halow-setkey` / `batman-config-save` member
  keeps writing after the helper reported rc 124. A later verb-triggered Finish therefore no longer races with it.
  The KILL also releases `halow-setkey`'s lock fd 9 (`halow-setkey:151`), so the next try does not meet a spurious
  rc 2 "busy" for the leftover's lifetime. Both effects are in §2's favour.
- **The abandoned case.** This is unchanged for an unkillable *leader* (`:47-50`). It is new for an unkillable
  *member* whose leader already exited: `Exec` returns `RCTimeout` with the normal text, not "abandoned", and the
  member may still hold the setkey lock. Then the next §2 try gets rc 2 and is retried, within the bound. That is
  acceptable, but say so (MINOR-4).
- **§2's SIGTERM-of-the-helper row** (`os.Exit` on TERM, `main.go:706`) is a different path. `Exec` is not running
  its deadline there, so §12 does not change it.
- **OTA `ExecSplit` cancel / timeout** (`update.go:118,130`).
  - `batman-slot`'s cleanup is in the leader: `trap 'exit 143' TERM` plus the EXIT trap with `sync; umount`
    (`batman-slot:185-186`). It still runs fully, because the KILL comes only after `Wait` returned or after 10 s
    (today's behaviour).
  - The cancel latency is pinned by `execsplit_test.go:36` (≤ 5 s). The fix keeps that only if the KILL is sent as
    soon as `Wait` returns (MINOR-1).
  - The `setsid` children (`batman-slot:954`, `:1058`) leave the group and are not affected.
- **Other callers.** `status.go:22,47,138,142` and `trial.go:33` (halow-status, config-save `--check` / `--save`,
  `is-trial`) get the same fix. No caller relies on a member outliving a timeout: I grepped the product children for
  TERM handling. Only the leaders trap TERM (`batman-slot:186`, `batman-config-save:140`). Elsewhere there is only
  `trap '' PIPE` (`halow-setkey:236`) and `trap '' HUP` (`batman-slot:953-955`). No product child ignores TERM.

## MINOR

1. **State the timing exactly.** Write: "after TERM, wait for `Wait` up to 10 s; then — at once, whether `Wait`
   returned or not — SIGKILL the group (ignore ESRCH); if `Wait` has not returned, wait up to 10 s more."
   - The text "up to 10 s of waiting" also reads as "always wait 10 s".
   - That reading would break `execsplit_test.go:36` (cancel must return in ≤ 5 s), slow every cancel and timeout by
     10 s, and widen the pgid-reuse window (MINOR-2).
   - Add a timing assertion for the `Exec` timeout path, like the existing cancel one.
2. **The pgid-reuse argument is not "the same as today".**
   - Today the SIGKILL is sent only while `Wait` has NOT returned. The leader is then unreaped, so its pid P is still
     pinned and cannot be reused.
   - The new KILL is sent after the leader was reaped. If the group is already empty, P is free.
   - The correct evidence:
     - Linux allocates pids cyclically (`alloc_pid` → `idr_alloc_cyclic`, kernel/pid.c). P is reused only after the
       pid space wraps.
     - With MINOR-1's semantics, the KILL follows the reap within microseconds.
     - While any member is alive, P stays pinned as the pgid.
   - Name the likeliest victim: one of the helper's own concurrent group leaders (status tick, `--check`). Add the
     read-only probe `cat /proc/sys/kernel/pid_max` on 04.
3. **The grace semantics change for members.** Members now get the TERM grace only until the leader exits, not the
   full 10 s. Replace "not verified per child" with the grep evidence above: the only TERM handlers are in the leaders.
   Record it as an assumption for future children: "cleanup on TERM belongs in the leader".
4. **Two lines in §2 / §12.**
   - rc 124 no longer leaves a writer running, and the setkey lock is released.
   - An unkillable member with a dead leader returns plain `RCTimeout`. It is not reported as "abandoned". Its lock,
     if it holds one, makes the next try rc 2, which is retried within the bound.
5. **Docs and tests.**
   - Update the `ExecSplit` doc comment (`exec.go:85`) and 254-wireless-txn §15.2 (`:240-241` "then SIGKILL 10 s
     later") to the precise rule.
   - The `ExecSplit` twin should cover cancel (rc 125) as well as timeout.
   - CI runs the provstore tests as root under `-tags prov_test` (`ci.yml:143-150`), and as a plain `go test`. The
     new test needs neither, so it runs in both. Good.
