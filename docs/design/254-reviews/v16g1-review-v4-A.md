# Review A, round 4 — §12 addendum (Exec / ExecSplit group SIGKILL), 2026-11-21

Reviewer A, independent. I reviewed §12 against `feed/batman-prov/src/provstore/exec.go`, its callers and the
children they run, and against the rest of the design (§2's retry classes, the OTA cancel, the abandoned case).
Read-only, no node access.

**Verdict: APPROVE-WITH-CHANGES.** The cause analysis is right, and closing the contract gap is worth doing, since it
was found by the A4 m3 test this design asked for. But the change as worded ("after SIGTERM and up to 10 s of
waiting, the group ALWAYS gets SIGKILL") kills the group **as soon as the direct child's `Wait` returns**. That cuts
the TERM cleanup of grandchildren that do trap TERM, which is a real regression on the owner's settings path (M1).
Fix M1, then re-check only the revised §12 text.

## Cause: verified

- `Exec` `:39-53` and `ExecSplit` `stop` `:104-116` send SIGKILL only in the branch where `done` did not fire within
  10 s. When the direct child dies on TERM, `Wait` returns: at once if no survivor holds the pipe, or after
  `WaitDelay` (5 s, `:30`, `:98`) if one does. The SIGKILL branch is then skipped, and every TERM-ignoring member
  survives.
- The doc comment at `:18-20` ("10 s later SIGKILL") is therefore not what the code does. §12's description is
  correct.

---

## MAJOR

### M1. An immediate group SIGKILL after `Wait` cuts a TERM-trapping grandchild's cleanup, and the owner's settings path has one

- **Scenario.** The owner changes the country or the phone AP from the app. `settings.set` runs
  `halow-setkey --country … --rollback` under `Exec` with a 300 s deadline (`cmd/batman-provhelper/main.go:84-89,
  170, 178`). halow-setkey runs `p3_persist` = `batman-config-save --save >/dev/null 2>&1 9>&-`
  (`deploy/provisioning/halow-setkey:228`, used at `:251, 257, 309`).
  1. At the deadline the group gets TERM.
  2. halow-setkey has no TERM trap (only `trap '' PIPE`, `:236`), so it dies at once.
  3. Its grandchild `batman-config-save` traps TERM on purpose: `trap 'exit 143' TERM` → EXIT trap → `sync;
     umount "$MNT"` (`batman-config-save:131-140`, which explains why: "Trap TERM … unmount p5").
  4. The grandchild's output goes to `/dev/null`, so it does not hold the pipe, and `Wait` returns immediately.
  5. Under §12 the group is then SIGKILLed while config-save is still in `sync; umount`.
  6. p5 stays mounted rw in the host mount namespace (`Exec` has no `NewNS`), and on a LUKS card the mapper stays
     open.
- **Today.** The cleanup completes, because nothing kills it.
- **After.** The cleanup is cut. The next save meets an already-mounted p5. A second mount of the same ext4 is the
  #202 T11 "silently read-only" trap (`batman-config-save:36-37`). Saves, and with them the OTA freshness gate, can
  fail until a reboot.
- **Fix.** Keep the TERM grace for the **group**, not only for the direct child:
  1. After TERM, wait for `Wait` **and** for the group to empty: poll `kill(-pgid, 0)` until ESRCH, up to 10 s from
     the TERM.
  2. Then SIGKILL whatever is left, ignoring ESRCH.
  3. Then the existing 10 s wait for `Wait` and the abandoned case.

  This keeps the documented contract (TERM, then 10 s, then KILL) for every member. It adds no latency when the group
  empties promptly. At most it adds the rest of the 10 s, which the contract already allows.
- **Test** (negative control included):
  - a direct child that dies on TERM, and a grandchild with stdout to `/dev/null` that traps TERM, sleeps 2 s, then
    writes a marker file;
  - after `Exec` returns, the marker exists, and `Exec` returned within TERM + 10 s + ε;
  - the immediate-kill variant of §12 fails this test, and the poll-then-kill variant passes;
  - add an `ExecSplit` twin.

---

## MINOR

### m1. pgid reuse: "the same as today" is not correct

- **Today.** The SIGKILL is sent only while `Wait` has **not** returned. The leader is unreaped then, so its pid, and
  with it the pgid, cannot be reused.
- **§12.** It also sends SIGKILL **after** `Wait` reaped the leader. If the group is empty by then, the pgid number
  can in principle belong to a new group leader. The likeliest one is another `Exec` / `ExecSplit` child of the
  helper itself, which runs concurrent subprocesses (status ticker, update tick); for example a `batman-slot` slot
  write.
- **Probability.** About zero: a pid wrap within 10 s, with `pid_max` 32768 on a 4-core Pi 4. But the claim is
  false, and the target is the worst possible one.
- **Fix.** The M1 poll already gives the guard: send SIGKILL only when `kill(-pgid, 0)` reported members during the
  grace. Also, once the leader is reaped, check that `/proc/<pgid>` is absent, or has a start time ≤ the child's.
  State it, and correct the "same as today" sentence.

### m2. A survivor that the KILL cannot end is silent

- If `Wait` returned and a grandchild is in D-state, the SIGKILL cannot end it, and the function returns normally.
  Today's abandoned message only covers a direct child that cannot be killed.
- Log one line when the group is still non-empty 10 s after the KILL ("group member(s) survive KILL — abandoned"),
  so the §2 retry log and the field logs can explain a later rc 2 (lock held, `halow-setkey:153`).

### m3. Interactions with §2 and the OTA paths: no change in class, but say so in §12

- **§2 retry classes.**
  - rc 124 (setkey / save deadline) stays not retried. It now has a more definite outcome: the group is really dead,
    after its cleanup grace.
  - The returned rc and text are unchanged, so `lastFinishCause` is unchanged.
  - The worst-case mutex hold grows by at most the rest of the 10 s grace, and only on the deadline path.
- **ExecSplit cancel / timeout** (`update.go:118, 130`, `NewNS` for slot writes).
  - The direct child is batman-slot, which traps TERM (`batman-slot:185-186`): EXIT trap → `sync; umount`. `Wait`
    returns only after its own cleanup, so batman-slot itself is not cut.
  - Its mounts die with the private namespace anyway.
  - The M1 poll keeps any of its children's cleanup intact too.
- **Abandoned case.** Unchanged.
- Add these as rows to §12's lifecycle, with the existing units as evidence (`TestExecKillsTheGroup`,
  `TestExecDeadline` with the `setsid` case, the ExecSplit cancel tests).

### m4. §12 "field likelihood low, not verified per child": verified here

- No direct or indirect child of `Exec` / `ExecSplit` in this tree ignores TERM. Only `PIPE` (`halow-setkey:236`)
  and `HUP` (`batman-slot:953`) are ignored.
- Two children **trap** TERM and clean up: `batman-config-save:140` and `batman-slot:186`. That trapping is exactly
  what M1 is about.
- Write that into §12 instead of "as far as known".

## Summary

| # | Sev | One line |
|---|---|---|
| M1 | MAJOR | §12 SIGKILLs the group as soon as `Wait` returns → cuts `batman-config-save`'s TERM cleanup (`sync; umount` p5) under `halow-setkey --rollback` (settings.set) → p5 left mounted rw; fix: poll the group for the rest of the 10 s grace, then KILL; test with a TERM-trapping grandchild |
| m1 | MINOR | pgid reuse is new (today KILL only before the leader is reaped); guard with the poll + a `/proc/<pgid>` start-time check; fix the "same as today" claim |
| m2 | MINOR | log a group member that survives KILL (D-state) after `Wait` returned |
| m3 | MINOR | state the §2 / ExecSplit-cancel / abandoned interactions: rc and class unchanged, at most +10 s hold on the deadline path, batman-slot's own trap unaffected |
| m4 | MINOR | replace "not verified per child" with the verified list: nothing ignores TERM; `batman-config-save` and `batman-slot` trap it |
