# Review v12 — reviewer A — `docs/design/254-v16-ud.md` v12 note (§25, e7209eb) with the implementation (97d8e87, HEAD 79ee722)

Read the whole document again, then §25 against the implementation (`scripts/dv/prov-update-254.sh`,
`scripts/dv/prov-254.sh`) and the device log `ud36d/trial.log`. Read-only: no node, no ssh, nothing committed.

## 1. What the run shows, and whether §25 follows from it

`trial.log`:
- UD2 applied at 19:12:49 and landed at 19:14:48 (uptime about 2 min). The landing grep with the boot window passed:
  the ring still started at this boot.
- The last-HELD grep (deadline − 60 s, uptime about 9 min) gave `LEAK-NOWINDOW ring start`.

So the ring wrapped between about 2 and 9 min of uptime. A boot window can never hold for a late grep. §25's
diagnosis is right, and so is the change to a landing mark .. now window for the late grep.

## 2. The asked points, against the code

- **Is the mark in the ring when the landing grep runs?** Yes. `ud_mark` (`prov-update-254.sh:157`) writes it seconds
  before the landing grep, and the landing grep checks the boot window (ring start = this boot), which then contains it.
  A wrap within those seconds would also fail the ring-start check → INVALID. Fail-closed.
- **A wrap between the mark and the late grep.** The mark is gone, so `ud_leak_cmd mark` prints `LEAK-NOWINDOW mark`
  (`:314-317`) and the judge gives INVALID (`:328`). Never a 0 / PASS. Whether that will happen routinely is
  unmeasured → m1.
- **A forged mark through `logger`.** Not exploitable to hide anything:
  - The window is `sed -n '/batman-dv-ud: mark <M>$/,$p'`, which starts at the **first** matching line (`:315`).
  - `<M>` = `ud-<RUN>-<host ns timestamp>` exists only from landing on, so a copy can appear only **after** the real
    mark. That leaves the window's start unchanged, and only adds lines.
  - Flooding the ring to push the mark out gives INVALID (denial of a verdict, not a false PASS).
- **Forged helper lines: a different exposure, through the same channel** → m2.
- **NOT-RUN gate.** UD4 / UD5 / UD1 / UD10 are `nj` NOT-RUN unless `UD2OK=1` (`:733`). `nj` does not change the UNIT
  verdict, so the gate is acceptable only because UD2's own failure is already a FAIL or INVALID line. One path loses
  that line → m3.
- **`PR_HELD_OK=1`** (`prov-254.sh:428-440`) is used only by UD2. The REVERT units keep "HELD = no effect".
- **provclient re-placement** after any boot (`ud_pc_replace` inside `ud_pc`): it addresses the stale-tool INVALIDs of
  ud36d (`trial.log`, "printed no caps line"). The negative control is the existing caps rule: an old binary still
  gives INVALID.

## 3. Findings

No BLOCKER, no MAJOR.

### MINOR

1. **The late window can still be lost by construction, and that is unmeasured.**
   - In ud36d the ring wrapped within about 7 min after landing. The mark survives only if the post-landing volume is
     below the whole ring size. The run shows only that it exceeded ring size minus the pre-landing content.
   - If UD2's late grep ends up INVALID on most runs, the design has bought an INVALID by construction.
   - Fix (both cheap):
     - a read-only probe of the ring size (`uci -q get system.@system[0].log_size`; `logread | wc -c` at two uptimes)
       for the log rate;
     - **rolling marks** in the held trial: grep mark_k .. now and write mark_{k+1}, every N s with N well below the
       measured wrap time. Each window then starts at the previous mark, and the chain covers landing .. last
       controllable point even when the ring wraps several times.
   - Fixture: a ring that wraps between two rolling greps still holds each window's mark → judged, not INVALID. Negative
     control: the single-mark window of v12 on the same stub → INVALID.
2. **Syslog lines are unauthenticated, and the evidence that reads them should say so.**
   - Several assertions read `logread` lines by tag only: the why-string rule (`ud_log`, `:158`, `grep -E
     'batman-provhelper\[…'`), 02's state-changing-line check, and the mesh-id-in-our-tags check.
   - logd does not record the sender's uid. Any process that can write `/dev/log` can emit
     `batman-provhelper[<pid>]: …` lines with chosen text.
   - [redacted in the committed copy: a local-exposure detail of a product component, kept locally — owner rule of 4028325]
   - So a compromised provd could forge a matching why line, and mask a wrong-why refusal. It could also forge lines that
     make a row FAIL.
   - This does not affect the primary assertions: codes and phases come from the helper socket through provclient, and
     02's proof is `prov.meta`.
   - Fix: say in §8 that the log-derived checks are evidence against our own mistakes, not against a hostile local
     process. Optionally pin the helper pid (from `ubus call service list`) in the `batman-provhelper\[<pid>\]` match;
     that narrows forgery, but a jailed process may still guess the pid.
3. **UD2's phase-6 judgement depends on the A-boot leak check.** At `prov-update-254.sh:727` the chain is
   `pr_wait_reverted && pr_pc_place && ud_g && ud_leak_ring "UD2: the A boot after the revert, at landing" … &&
   { ud_phase … 6 … UD2OK=1 } || no …`. If that leak grep returns non-zero, for example on an INVALID window, UD2's
   phase / slot assertion is never made. The `|| no` branch may then print a misleading "UD2: after the revert" FAIL
   (depending on `ud_verdicts`' return code). Either way the leak result decides UD2's own verdict, and every dependent
   row is NOT-RUN. Fix:
   - judge UD2's phase 6 + A committed independently of the leak check's outcome;
   - let only a FAIL / INVALID of UD2 itself gate the dependents.

   Fixture: an INVALID leak window on the A boot still produces UD2's phase-6 PASS line.

## 4. Verdict: **APPROVE**

0 BLOCKER, 0 MAJOR, 3 MINOR.
- §25 is the right correction of a design error the device run exposed: the boot window can never hold late.
- The mark window fails closed, and forging the mark cannot hide lines.
- The minors cover one unmeasured premise (the late window's survival), one honest limit of log-based evidence, and one
  coupling in the UD2 code that can hide UD2's own verdict.
