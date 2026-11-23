# Review v12 (reviewer B) — `docs/design/254-v16-ud.md` at e7209eb (HEAD 79ee722)

I read the whole design again, with the v12 note (§25). I checked it against the implementation in 97d8e87
(`scripts/dv/prov-update-254.sh`, `scripts/dv/prov-254.sh`, the tests) and the device log
`Desktop/Batman/v16/g4/ud36d/trial.log`. I started from what the device run actually did.

Read-only: no node touched, nothing committed. This file holds no local-only product detail.

## What the run shows, and what v12 changes

`trial.log` shows the arm working end to end:
- S0 scan;
- make-legacy;
- H0 claim;
- member join (`mesh_id=withheld`), with the pre-row checks;
- the join leak grep (PASS);
- UD2 to phase 3, apply, held B trial, landing leak grep (PASS; 7 system-daemon lines → INFO);
- the restore (`diffs=0`) and the B rewrite.

It also shows three defects, which v12 addresses:
1. The late grep was INVALID "ring start" after the trial's ring wrapped (`trial.log:31`). v12 replaces the boot window
   with landing mark .. now.
2. "FAIL the trial is HELD — the mutant had no effect": UD2's expected HELD state was judged with the REVERT units'
   rule. v12: `PR_HELD_OK=1 pr_wait_reverted`.
3. After `back_to_a`, UD4 and UD1 ran with no provclient on the node. v12: re-placement after any boot, and NOT-RUN
   unless UD2 ended A-committed at phase 6.

Checked in source and tests:
- **The late window is the right fix.**
  - At landing, the unit writes `ud_mark` and then runs the boot-window grep over boot start .. landing, which includes
    the mark.
  - The late grep reads from the mark's **first** occurrence (`sed -n '/…mark M$/,$p'`, `prov-update-254.sh:316`) to now.
  - The two windows overlap at the mark.
  - logread is a FIFO ring, so any line after the mark can roll out only after the mark itself has. A lost line
    therefore always shows as "mark gone" → INVALID, never as a hidden 0.
  - Fixtures: wrapped ring with the mark (FAIL with a key, PASS without); mark gone → INVALID; v11's boot window as the
    negative control (`test-prov-update-254.sh:304, 322-324`).
- **`PR_HELD_OK` is scoped to UD2 only** (`prov-254.sh:428-440`). The REVERT units keep "HELD = no effect", and there is
  a fixture (`test-prov-update-254.sh:403-413`).
- **The NOT-RUN gate** (`prov-update-254.sh` after UD2) has its fixture (`:375-377, 416`).
- **Re-placement:** `pr_pc_place` records the boot it placed for in a file; `ud_pc` re-places the tool when the boot
  differs (`:160-180`). It uses a file, not a variable, so it also works inside `$(…)`.

## Findings

### MAJOR-1 — a tool or ssh failure inside `$(…)` still turns into a row FAIL: the INVALID is printed but not counted, and the caller FAILs

**Scenario.** This is exactly what ud36d shows:

```
INVALID prov-update-254: provclient printed no caps line (sha 444a2bf21e1bd54e): a stale tool — rebuild …
FAIL prov-update-254: UD4: check []
```

`ud_pc` reports the tool problem with `inv` and returns 2 (`prov-update-254.sh:160-167`). But every row calls it inside a
command substitution or a pipeline:
- `r=$(ud_pc … | grep '^RESULT update.check')` (`:191`);
- `ud_status` / `ud_poll`;
- `ud_prepare`, `ud_apply`, `ud_window`.

There, `inv`'s `invalid=$((invalid + 1))` (`prov-254.sh:51`) runs in a subshell and is lost. The caller then sees an
empty `RESULT` and calls `no` in the main shell (`ud_to3`: `no "$4: check [$r]"`). `pr_result` judges only the
variables (`prov-254.sh:678-680`), so the unit ends **FAIL**, with an INVALID line that was never counted.

v12 removes the trigger seen in ud36d (the tool missing after a boot), but not the mechanism. `ud_pc`'s own "no output
at all (… or no ssh answer)" branch (`:165`) fires on any ssh drop or timeout. A network blip during a check, a status
poll or a prepare therefore still ends as an unattributed product FAIL. The owner's rules forbid that ("every FAIL gets
an attribution with evidence"; a tool fault is INVALID).

**Fix.**
- Record tool INVALIDs where a subshell can reach them: a file, as `UDPLF` already does for the placement.
  - `ud_pc` appends one line per tool INVALID to `$UDINVF`.
  - `pr_result` (or the unit's end) adds that file's line count to `invalid`.
  - Every caller that builds a row verdict from a `ud_pc` result first checks whether a tool INVALID was recorded since
    its own call. If so, the row is INVALID, not `no`. A small helper (`ud_row_fail <msg>`) can do both.
- Negative control (offline):
  - a stub `ssh` that answers nothing to one `update-check` (and, separately, one with no caps line). Today's code ends
    `fails=1 invalid=0` "UD…: check []".
  - With the fix it must end `fails=0`, `invalid ≥ 1`, and the row line marked INVALID.
- Also audit `ud_status` / `ud_poll`: a poll that never sees its phase because every status read was a tool failure must
  end INVALID, not "phase X not observed" FAIL.

### MINOR-1 — the late window trusts any `batman-dv-ud: mark <M>` line; require exactly one

- The mark value is `ud-$RUN-<host ns>` (`prov-update-254.sh:157`), and the check is "the line is present" (`grep -q`).
  Any local process can write a line with that tag through `logger`, if it knows or replays the value. The value
  appears in the ring itself.
- **Attack:** a process that wants a late key line hidden can, after the real mark has rolled out, write a copy of the
  mark. The window then starts at the copy and reads as complete: a fail-open where the design promises INVALID.
- The same applies to our own mistakes: a duplicated `ud_mark` (a retry) would silently shift the window.
- **Fix:**
  - require that the mark occurs **exactly once** in the ring, else INVALID "mark not unique";
  - add random bytes made on the host to the mark value, so it cannot be guessed before it is written;
  - fixtures: two copies → INVALID; a single copy that sits after lines it should precede (a replay after the real
    mark rolled out) → INVALID by uptime order. The count rule alone covers the duplicate case.

### MINOR-2 — UD2's late grep runs once at deadline − 60 s; the deferral can add up to 600 s that is never grepped

`batman-autocommit` may defer the revert by up to `DEFER_MAX` = 600 s ("revert deferred: …",
`batman-autocommit:35, 232-238`), and `pr_wait_reverted` already loops every 10 s while the boot is unchanged
(`prov-254.sh:433-447`). Lines from deadline − 60 s to the actual revert (up to about 11 minutes) are not covered. §25
says "seconds".

**Fix (either):**
- re-run the late grep (mark .. now) in that loop each time it sees the trial boot unchanged, keeping the last verdict;
- or correct §25's "seconds" to "up to deadline + DEFER_MAX" and list it in §11.

Add a fixture: a key line logged in the deferral window → caught, or the gap stated.

## Whole document, other paths

These are unchanged by v12, and I re-checked that nothing regressed:
- lifecycle (host death and §7.1 with `@S0@`; the H0 claim and the join; the restore to member gen 15, which the run's
  `COMPARE … diffs=0` confirms);
- the guards and the runtime refusal;
- the lints;
- the masked compare;
- 02's record equality (the run: "02's record unchanged over the arm"; "logged no state-changing line");
- the watcher.

## Verdict

**REJECT for this round under the owner's rule (one MAJOR open).** 0 BLOCKER, 1 MAJOR, 2 MINOR.

§25's window change is correct and well controlled. `PR_HELD_OK` and the NOT-RUN gate fix two of the run's defects. The
open MAJOR is the attribution mechanism behind the third: as it stands, an ssh drop during any row becomes a product
FAIL. Once the tool-INVALID is counted and blocks the row FAIL, with the stub negative control, I expect APPROVE.
