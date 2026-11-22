# Review A, round 5 — §12 v2 (group TERM grace, then KILL), 2026-11-21

Reviewer A, independent. I re-checked the rewritten §12 against `provstore/exec.go`, the new
`exec_group_test.go` hunk, the other process-group killer in the tree (`node/peers.go` `runCapped`), the children's
TERM handling, and the rest of the design. Read-only, no node access. The probe results I was given (2026-11-21): on
04 and 02, `pid_max` 32768, `/dev/vcio` `crw-------` root, and the GET word 5 = `0x80000004`.

**Verdict: APPROVE-WITH-CHANGES.** My v4 M1 is closed: every member now keeps the full TERM grace (poll the group,
then KILL only a non-empty group), and test (2) is the right negative control for the "immediate KILL" mutant. The
findings below are MINOR text and test fixes; none needs another review round.

## v4 findings: status

| v4 | Status |
|---|---|
| M1 (immediate KILL cuts the cleanup) | closed: step 2 polls up to 10 s from the TERM; test (2) with an "immediate KILL" mutant |
| m1 (pgid reuse) | mostly closed. The reasoning is right; the stated window is too narrow (m1 below) |
| m2 (silent unkillable member) | closed: step 5 line |
| m3 (interactions) | closed: §2, ExecSplit cancel, setsid children, docs |
| m4 (children verified) | closed in "Evidence about the children". One stale sentence remains (m2) |

Checked and correct:

- Linux keeps a pgid's number allocated while any task still has it as its process group, so a live member pins the
  id.
- The helper is not a child subreaper and runs without a jail (`batman-provhelper.init:11-15`; no `PR_SET_CHILD`
  anywhere in the tree). Orphaned members are reaped by procd, so zombies do not keep the poll busy.
- `execsplit_test.go:36` (a cancel returns in ≤ 5 s) still holds in the normal case.

---

## MINOR

### m1. The reuse window is "one poll gap", not "microseconds", and the tree already has a zero-window pattern

- Step 2 checks the group every 100 ms. Suppose the last member exits right after a check that saw it, and a new
  group leader receives the same id before the next check. The next check then sees a non-empty group, which is the
  wrong one. Polling continues, and step 3 KILLs that group at 10 s.
- So the window is each 100 ms gap, not only the microseconds between the last check and the kill.
- It still needs a pid wrap inside 100 ms (`pid_max` 32768), so the risk stays negligible. But the text claims
  something stronger than the code gives.
- `node/peers.go:73-99` (`runCapped`, code review B-m4) already avoids reuse fully: it waits for the leader with
  `WNOWAIT`, so the leader stays a zombie and the id cannot be reused, and it reaps the leader only after the KILL.
- **Fix.** Either correct the sentence ("a pid wrap within one 100 ms poll interval; accepted"), or adopt the
  zombie-leader pattern. With that pattern, "group empty" must be read from `/proc/*/stat` `pgrp` (excluding the
  leader), because a zombie leader makes `kill(-pgid, 0)` always succeed. I recommend the text fix: the extra
  complexity is not worth it.
- Also note in one line that `runCapped` has the immediate-KILL shape (1 s TERM grace measured on the leader only,
  `peers.go:93-95`). Its commands do not trap TERM, so it is not affected, but say so (or put it on the #254
  checklist) so the two killers are not read as the same contract.

### m2. A stale sentence contradicts the new evidence

- The **Cause** section still says: "Field likelihood: ⚠️ low. Those children do not trap TERM, as far as known (not
  verified per child)."
- That is now verified, and wrong in its wording: `batman-config-save:140` and `batman-slot:186` **do** trap TERM;
  nothing **ignores** it.
- Replace it with a pointer to "Evidence about the children".

### m3. Step 5: put the new line before the timeout line, not after it

- `Exec` returns `out + "\n" + name + ": timed out after …"`, and callers log `lastLine(out)`. Examples:
  `CheckRestorable`'s transient error (`cmd/batman-provhelper/main.go:259`) and `update.go:142`.
- If "group member(s) outlived TERM: killed" is appended last, the helper log's one-line reason loses "timed out".
- Nothing in the product parses that text (I grepped: only tests use `Contains`), but an operator reading the log,
  and the §2 `boot finish retry N: <reason>` line, should still show the timeout.
- **Fix.** Insert the new line before the final "timed out after …" / "canceled" line, or put it on the same line.
  Test (1) keeps working with `Contains`.

### m4. Step 4 when no KILL was sent

- Step 4 says "up to 10 s after the KILL, or at once if it already returned".
- When the group emptied in step 2 but `Wait` has not returned yet, `Wait` is bounded by `WaitDelay` (5 s): a
  `setsid` daemon outside the group still holds the pipe, as in `TestExecDeadline`'s daemonised case.
- State that bound for the no-KILL path, so the `ExecSplit` cancel timing (≤ 5 s test) is explicit.

### m5. Record the probe results in §1 and §8

- §1 Security still says `/dev/vcio` is "root 0660, to be checked". The probe found `crw-------` root (0600), which
  is stricter.
- §1 Evidence still says the capture is "in implementation", but word 5 = `0x80000004` on 04 and 02 is now captured.
- Write both with the date and the raw lines. §8 step 1 can then be marked ✅ for the probes.

## Re-checked and fine (no finding)

- **Test (2)** fails on the "immediate KILL" mutant and passes with the poll: the marker is written 2 s after TERM,
  inside the 10 s grace.
- **Test (3)** pins the normal-case latency.
- **(4)** covers both ExecSplit rc 124 and rc 125.
- **The new test hunk** (`exec_group_test.go`, `TestExecKillsTheGroupThatTrapsTERM`) fails on current main by
  construction: no group KILL after the leader dies on TERM. It cleans up its survivor.
- **§2 interaction.** rc 124 stays not retried; the class is unchanged; the extra mutex hold is ≤ 10 s, deadline
  path only. A member that cannot be killed and holds the setkey lock gives rc 2 on the next try, which is retried
  within the bound.
- **OTA ExecSplit cancel.** batman-slot leads and runs its own EXIT / TERM cleanup (`:185-186`), and its `NewNS`
  mounts die with it. Its `setsid` children (`:954`, `:1058`) are outside the group, as today.

## Summary

| # | Sev | One line |
|---|---|---|
| m1 | MINOR | the reuse window is a 100 ms poll gap, not µs (still needs a pid wrap: accepted); fix the text; note `peers.go` `runCapped`'s WNOWAIT pattern and its immediate-KILL shape |
| m2 | MINOR | the stale "do not trap TERM, as far as known" sentence in Cause contradicts the evidence (config-save and batman-slot do trap it) |
| m3 | MINOR | put "outlived TERM" before the "timed out" / "canceled" line so `lastLine` still says timeout |
| m4 | MINOR | step 4: state the `WaitDelay` 5 s bound when no KILL was sent |
| m5 | MINOR | record the 2026-11-21 probes (`/dev/vcio` 0600, word 5 on 04 and 02) in §1 and §8 |
