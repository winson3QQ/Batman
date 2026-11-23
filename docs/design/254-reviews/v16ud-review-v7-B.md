# Review v7 (reviewer B) — `docs/design/254-v16-ud.md` at d4a876e

I read the whole document again. I looked first at what v7 changed: §7.1 step 0c, step 0b / 0b2, the removed `rm -rf`,
the P9 here-doc and the validated `sed`, `@NODE@` filled on the host, the hex encode fix, the designer's disagreement
on `ble-recover`, and the dry-run asserts and negative controls.

I checked these against:
- `prov-254.sh` (`:40, 46-47, 62-63, 194, 205-246, 312, 343-351, 395-405`);
- `ble-lib-254.sh` (`:106-111, 129-137, 297-346, 349-377`);
- `prov-lease-254.sh` (`:29, 38-50, 86-113`);
- `prov-undo-lib-254.sh` (`:76, 216, 237-262`);
- `slot-guard-254.sh`;
- `tmp-trust-allowlist.txt:13`;
- `test-slot-guard-254.sh:453-460`.

Read-only: no node, no ssh. The mesh-id history is not a finding.

## v6 findings: fixed in source terms?

| Finding | State | Checked |
|---|---|---|
| **A M1 / B m1** step 0c replayed on B | **Fixed.** `pr_stage && pl acquire 3600 \| grep -q '^LEASE '` takes the lease and arms the dead-man with **no** replay: `cmd_acquire` has none (`ble-lib-254.sh:297-314`); only the host's `pr_acquire` replays (`prov-254.sh:209-214`). Then `back_to_a`: `pr_trial_guard_end` returns early on the empty `PR_AB_MT` (`:312, 345-347`); `rb_guarded` is self-contained; its `pr_find` → `pr_acquire` replays **after the reboot, on A** (`:237`). Any failure path still releases: `cmd_release` checks ownership first (`ble-lib-254.sh:337-338`), so a release after a refused acquire can never drop another run's lease. Dry-run assert 2 + the v6 text as its negative control. | as listed |
| B m2 manual `rm -rf` | **Fixed by removal.** `gc_rundirs` removes the dead run's staging dir only once no lease and no live dead-man names it, and prints its listing first (`ble-lib-254.sh:317-326`). Dry-run assert 8 checks that the block has no `rm -rf …/bt/`. | — |
| B m3 watcher kill as a command | **Command added (0b2), with the right guard:** pidfile under root 0700 `/tmp/run/batman-dv/<run>/`; a numeric pid; `/proc/<pid>/stat` field 5 = pid; cmdline contains `ud9-watch-254.sh`; same boot only. **The kill syntax is wrong for this busybox: MINOR-1.** | `ble-lib-254.sh:129-131` |
| B m4 / A m1 run-id validation; `@NODE@` | **Fixed.** Exactly `pupdate254` + 10 digits, which is what `prov-254.sh:40` generates for this unit (`p` + `update254` + `%m%d%H%M%S`). `@V@` is restricted to `[A-Za-z0-9.+-]{1,80}`, so no `/`, `&` or newline can reach `sed`. `@NODE@` is filled on the host by `pr_p9` / `dv-preflight` with their own validated address. The block is a quoted here-doc (`<<'UDREC'`), so the node's `sh -s` expands nothing in it. | — |
| B m5 trailing newline | **Fixed:** `v=$(uci -q get …); printf %s "$v" \| hexdump …` | — |
| B m6 dry-run cases | **Fixed:** assert 2 (B committed + a pending `slot:A` line, no replay before the rollback); assert 6 (a live `lease-prov` of @DEAD@ → every step stops at its acquire); assert 7 (empty, `pupdate254x/../..`, too short, too long → the generic line). Negative controls: v5 fails 2–5; v6 fails 2. | — |
| A m2 `ble-recover` — **the designer disagrees** | **I agree with the designer.** `cmd_recover` removes only `$BT/lease`, the BLE lease (`ble-lib-254.sh:367-377`). `prov-lease-254.sh` dispatches no `recover` (`:86-113`). The prov dead-man (`cmd_dm_fire`) always ends with `rm -f "$LEASE"` after its restore (`ble-lib-254.sh:360-362`). For a `pupdate254` run, printing `ble-recover` would be a wrong instruction. Stopping with NEEDS-PERSON on "lease expired, no deadman left" and recording the missing prov recover on #254 is the honest answer. | as listed |
| A m3 lints with the block in `scripts/node` | **Holds:** lint (1)'s regex does not match `batman-slot active` / `is-trial` / `pl release`; lint (3) skips `^[[:space:]]*#` lines, and no non-comment line of the block contains the word `reboot` or `sysrq-trigger`; the block's `/tmp/run/batman-dv/…` literals match row 13 (`scripts/*`, `/tmp/run/batman-dv([^-a-z]\|$)`). | as listed |
| A m4 negative control incl. assert 5 | fixed | — |

Privileged steps against lower-privileged paths:
- §7.1 now touches only the pidfile and `/proc/<pid>/*` (in 0b2), the root 0700 staging and lease files (through
  `cmd_acquire` / `cmd_release` / `gc_rundirs`), and p6 state.
- None of these can be written by uid 471 or an unprivileged process. `/tmp/run` is root 0755 from procd, and
  `/tmp/run/batman-dv` is root 0700.
- The values substituted into host commands are validated whole, not by prefix.

I find no exposure.

Nothing else in v7 changes the rows, guards, lints, ownership, the `update-last` restore or the watcher. I found nothing
that v7 broke beyond MINOR-1.

## Findings

### MINOR-1 — step 0b2's `kill -TERM -- -$p` is not accepted by this busybox

The harness records this fact itself: `pg_kill` says "busybox kill takes no `--`, E25" and uses `kill -TERM "-$1"`
(`ble-lib-254.sh:129-131`), and `ustop_host` uses the same form (`prov-undo-lib-254.sh:216`). As printed, the step
fails to signal the group, and the person sees `STILL-ALIVE`. That is visible and fail-safe, but it is a wrong
instruction in a block printed to a person.

Also, the check after `sleep 1` looks only at the leader pid. The watcher's group can include a short-lived child (its
`dd` log writer, its `/proc` reads). `pg_kill` waits up to 10 s for **every** group member.

**Fix.**
- Use `kill -TERM "-$p"`, and wait as `pg_kill` does: scan `/proc/[0-9]*/stat` field 5 = p for up to 10 s, then print
  `KILLED` or `STILL-ALIVE`. Or call `pg_kill` from the staged `ble-lib-254.sh` if a staging dir exists.
- Dry-run assert 9 runs over a stub `ssh`, so it cannot see this. Let it assert the exact command text: no `--`, and the
  group wait present.

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER, 0 MAJOR, 1 MINOR.

Every v6 finding of both reviewers is fixed in source terms, and the designer's `ble-recover` disagreement is right on
the evidence. MINOR-1 is a one-line fix to the printed watcher-kill command plus one assert in
`test-ud-recover-254.sh`. It can be made during implementation without another design round.
