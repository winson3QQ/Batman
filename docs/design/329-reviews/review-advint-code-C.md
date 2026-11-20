# #329 adv interval harness — code review, round 2, reviewer C

Range: `git diff f89f2e8..9b17237` (branch `harness/329-adv-interval`, worktree `C:/src/Batman-a4`).
Design held as fixed: `docs/design/329-adv-interval.md` §8 T1a/T1b, §11.
Nothing on a node, the phone, adb or the network was touched. All runs were on a WSL clone
(`/tmp/revC`, cloned from a git bundle of 9b17237) or on copies of the evidence files.

## Verdict: APPROVE-WITH-CHANGES

No BLOCKER, no MAJOR. Six MINOR findings. The mutation run was not complete when this was written
(31 of 36 mutants have a result; see "Not finished").

## Round-1 findings

| Round-1 finding | State | Evidence |
|---|---|---|
| BLOCKER: `btmon -T` shortens the header ("Command Comp.."), judge matched by name | closed | Judge matches opcode `(0x08\|0x0006)` and event `(0x0e)`. Mutant `M-hdr` (match by name again) -> `121 passed, 3 failed`. Real capture `advint-live-1.txt` through busybox ash+awk gives the fixed old-image line. Device logs carry the line (below). |
| MAJOR: tests only checked presence | closed for the judges; still presence-only for the call sites | 26 of 31 judged mutants are detected. The 5 survivors are all call-site wiring or the timeout wrapper (MINOR 1, 2). |

## Findings

### MINOR 1 — the call sites in `prov-p2-254.sh` are held offline only by a line count
- Scenario: someone later disables a call or drops the `dep-power` guard. The offline tests stay green. On a fixed image the suite then loses a PASS line and nothing reports it; with the guard dropped, the judge also runs for `power-bondable` (design says it must not).
- Evidence (run): mutants `M16` (`[ "$a" = dep-power ] && adv_int_arm` -> `adv_int_arm`), `M12a` and `M14a` (`adv_int_arm` -> `: adv_int_arm`) all give `ble rc=0 [124 passed, 0 failed]`. The check is `scripts/test-dv-ble-254.sh:367`: `grep -c '^[[:space:]].*adv_int_arm'` = 3.
- Why not MAJOR: the device logs show the wiring works today (5 arm lines, none for power-bondable), and the old-image lines are FAIL lines, so a lost call cannot turn a FAIL into a PASS silently while the image is old.
- Fix (no new mechanism): tighten the three greps to the exact lines — `^\tadv_int_arm$`, `^\t\tadv_int_arm$`, and the literal `[ "$a" = dep-power ] && adv_int_arm` — instead of a count of any line containing the name.

### MINOR 2 — the call site in `bt-uart-305.sh` and the DET line: same weakness
- Evidence (run): `S7b` (`false && adv_sys_check && pass ... || no ...`) -> `54 checks, fails=0`, because `scripts/test-dv-bt-uart-305.sh:144` uses an unanchored `grep -q`. `S-det` (DET line removed) -> `fails=0`. `S-lim` (`adv_sys_read` without `lim 4`) -> `fails=0`.
- `S-flip` (the `--flip` exclusion removed) IS detected (`fails=1`).
- Fix: anchor the line (`^\t\t\tadv_sys_check && ...`), add one grep for the DET line, and one for `lim 4` in `adv_sys_read`. The timeout itself works: by hand, a hanging `bluetoothctl` gave `adv sysconfig unreadable`, tries=5 unr=5, 33 s, 0 leftover processes.

### MINOR 3 — two device runs are one commit behind
- `boot-provd-after.log` and `dep-restart-after.log` were taken at 6cfcd8c. `git diff 6cfcd8c..9b17237` on the node scripts changes one line (the `st[n]` status line in `adv_int_check`). Only adv-data was run again at 9b17237.
- Fix: say so in the PR test section, or run dep-restart once more at 9b17237.

### MINOR 4 — rebind logs have no duration and no RESULT line
- Design §8 says the harness PR reports the rebind suite's duration with the judge added. `rebind-04-after.log` / `rebind-02-after.log` carry the 10 FAIL + 10 DET lines but no total time.
- Fix: put the measured duration in the PR body (from the host log), or mark it as not measured.

### MINOR 5 — `adv-data-final.log` classifies as NEW
- Evidence (run): `kf_classify` on it -> `new (unmatched ...)`, because the by-hand unit prints the prefix `prov-adv-data-254`, not the suite's. Inside the suite (`boot-provd-after.log`) the same line is `known #329`.
- Fix: one sentence in the PR body, so nobody reads that file as suite evidence.

### MINOR 6 — colour codes and empty fields give an unclear FAIL (fail-safe)
- Evidence (run, Ubuntu busybox 1.36.1): a readout with an ESC sequence right after the value -> `a000[0m / f000 after 5 tries` (FAIL). The pre-existing `clean` uses `\x1b` in sed, which this busybox sed does not interpret. Whether the node's sed does is not verified. The device logs show `tries=1 unreadable=0` on both nodes, so it does not happen there today. An empty version file gives `image without the interval []`, which does not match the entry -> NEW (correct direction).
- Fix: none required for this PR; it never passes wrongly.

## Requirements checked

| Requirement | Result |
|---|---|
| Negative control for each fix | Yes for the judges and the three known-failures entries (mutants below). Not for the call sites (MINOR 1, 2). |
| A test that finds nothing must FAIL | Yes: no file, empty file, no block, no Command Complete all FAIL (`M-emptyfile`, `M-status` detected). |
| Empty / unreadable never passes | Yes: `S-unr`, `S-vals` detected; hang -> unreadable; "unreadable" is in `NEVER_KNOWN`. |
| KNOWN line never on an image with the key | Yes: `M-oldwithkey`, `M-oldany`, `S-oldkey`, `M-old1/2`, `S11/S11b` detected. By hand: with the key the message is `... main.conf has the key` / `0008 / 0008 after 5 tries`, neither matches the entries. |
| Read-only on the node, no secrets | Read only: the judges grep/sed two files and run one mgmt read; the readout is captured, only the two hex values are printed. |
| No silent skip | Read only: boot-provd and dep-restart hard-fail without btmon (`prov-provd-254.sh:187`, `:221`); the rebind judge is skipped only for `--flip` and when the rebind itself failed (already a FAIL). |

## What was run (with output)

- 9b17237 on WSL: `test-dv-ble-254.sh` -> `124 passed, 0 failed`; `test-dv-bt-uart-305.sh` -> `54 checks, fails=0`.
- `kf_classify` (KF_NO_GH=1, date 2026-11-20) on the real logs:
  - `boot-provd-after.log` (1 FAIL) -> `known #329`
  - `dep-restart-after.log` (4 FAIL) -> `known #329`
  - `rebind-04-after.log`, `rebind-02-after.log` (10 FAIL each) -> `known #329`
  - same with date 2026-12-21 -> `new (the entry for #329 2026-12-20 has expired ...)`
- Device evidence counts: adv-data 1 line; dep-bluetoothd, dep-bluetoothd-kill, dep-dbus, dep-power 1 line each; power-bondable 8 PASS lines and no interval line; rebind 04 and 02: 10 FAIL + 10 `DET ... tries=1 unreadable=0` each; the before-logs have none.
- Judges under busybox ash/awk on the real capture and readout: results as in the table above; CRLF capture -> FAIL.
- Offline tests with busybox tools first in PATH: `120 passed, 4 failed` — the same 4 fail on the parent f89f2e8 (`82 passed, 4 failed`), so they do not come from this change.
- Fixtures: all 38 lines of `btmon-04-wsl32-dated.txt` are in the real capture; `btmon-edited-pass.txt` differs from the real one only in the two interval lines.
- Mutants (each on its own clone, both test files run):

| Mutant | Result |
|---|---|
| M11 status from any Command Complete | detected (2 fails) |
| M12 / M13 drop max / min check | detected (2 each) |
| M-old1 / M-old2 old-image line on one value | detected (1 each) |
| M-hdr match Command Complete by name | detected (3) |
| M-nokeyPASS, M-oldwithkey, M-oldany | detected (1 each) |
| M-type, M-status, M-mgmt, M-rc0, M-emptyfile | detected (1, 3, 3, 15, 3) |
| M15 arm maps to ok, M17 arm reads the wrong variable | detected (2 each) |
| S7 / S7c PASS on one value | detected (1 each) |
| S11 / S11b old-image line on one value | detected (1 each) |
| S-oldkey, S-unr, S-vals | detected (3, 2, 3) |
| S-flip | detected (1) |
| K1, K2 entries loosened | detected (2, 4) |
| **M16, M12a, M14a** | **survived** (MINOR 1) |
| **S7b, S-det, S-lim** | **survived** (MINOR 2) |

## Not finished

- (Added after the run ended.) K3 (dep entry matches any arm): detected (`123 passed, 1 failed`). K4 (first entry's expiry moved to 2027-12-20) and K5 (rebind entry accepts an empty version `[]`): survived, both `124 passed, 0 failed` / `fails=0`. Both are MINOR: the expiry is data that a reviewer reads in the list, and for K5 a one-line `kfc` case "empty version -> NEW" would hold it. No change to the verdict.
- `S-pidof`: my mutant was invalid (the pattern occurs twice); the `pidof bluetoothd` guard was checked only by hand with a stub.
- Whether the node's own busybox sed strips ESC sequences (MINOR 6): not checked, no node access in this review.
