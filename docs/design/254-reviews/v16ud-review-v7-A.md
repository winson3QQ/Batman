# Review v7 — reviewer A — `docs/design/254-v16-ud.md` v7 (d4a876e)

I read the whole document. The §7.1 block was checked step by step against `scripts/dv/prov-254.sh`,
`scripts/dv/slot-guard-254.sh`, `scripts/node/ble-lib-254.sh`, `prov-lease-254.sh`, `prov-undo-lib-254.sh`,
`prov-p9-254.sh`, `scripts/dv-preflight.sh` and the lint scripts. Read-only: no node, no ssh, nothing committed. The
mesh-id history is not a finding.

## 1. Were the v6 findings fixed?

**A v6 M1 (step 0c): fixed.** Checked in source:
- `pl acquire` reaches `cmd_acquire` (`prov-lease-254.sh:102` → `ble-lib-254.sh:298-315`). That is lock, other-lease
  check, `gc_rundirs`, `lease_write`, `dm_arm`, and nothing more. No `undo-pending` and no `undo-replay`: the replay
  exists only in the host's `pr_acquire` (`prov-254.sh:209-213`). So nothing is replayed on B before the rollback.
- `back_to_a` works in a fresh sourced shell under `set -u`:
  - `ST`, `PROT_NODE` (`:311`) and `PR_AB_MT` (`:312`) are set at source;
  - `pr_trial_guard_end` only reads, and returns early on the empty `PR_AB_MT`;
  - `rb_guarded` prints a self-contained node command (`slot-guard-254.sh:46-66`) and needs no staged script;
  - `pr_find` → `pr_acquire` runs after the reboot on A. The tmpfs is new there, so `pr_stage` and `pl acquire` start
    clean, and the replay happens on the right slot.
- If that replay leaves something, `back_to_a` returns 1 with the node already on A. The final `pl release` releases the
  lease taken after the reboot.
- The pre-reboot deadman dies with the reboot. If the rollback is refused (WRONG-STATE), `pl release` releases the
  pre-reboot lease.
- Dry-run assert 2 now has a pending `slot:A` line, and the v6 text is its negative control. That closes the "check that
  cannot fail" gap.

**A v6 m1 run-id validation: fixed.** It is an exact `case` pattern for `pupdate254` + 10 digits, plus a validated `V`.
Fixtures cover an empty id, `pupdate254x/../..`, too short and too long. Neither substituted value can carry `/`, `&`
or a newline into `sed`.

**A v6 m2 ble-recover: the designer's disagreement is correct, and I withdraw m2.**
- `cmd_recover` removes only the BLE lease, `$BT/lease` (`ble-lib-254.sh:367-377`).
- The prov deadman always ends with `rm -f "$LEASE" "$ST/dm" "$ST/dm.new"` (`:362`) after `role_fire_restore`, and the
  prov role's version of that always returns 0 (`prov-lease-254.sh:44-80`).
- The "tryboot not cleared, lease kept" refusal belongs to the BLE roles only.
- So for a prov run, the only stuck state is "expired, no deadman left". Stopping there as NEEDS-PERSON, with a checklist
  line, is the honest answer.

**A v6 m3 here-doc and lints: fixed.**
- The quoted `<<'UDREC'` stops expansion on the node.
- Lint (1)'s regex (`test-slot-guard-254.sh:453-455`) does not match `pl release` or `batman-slot active` / `is-trial`.
- Lint (3) skips comment lines (`gen-slot-sites.sh:23`), and the block's command lines contain no `reboot` or
  `sysrq-trigger`.
- The tmp-trust row `scripts/*` / `/tmp/run/batman-dv` (`tmp-trust-allowlist.txt:13`) covers the literals.

**A v6 m4: fixed** (assert 5 is in the v5 negative control).

**B v6 m1–m6: fixed.**
- No manual `rm -rf` of the staging dir: `gc_rundirs` removes it.
- The watcher kill is a command: stat field 5 = pgrp = pid, a cmdline check, then `kill -TERM -- -pid`. It reports
  `STILL-ALIVE` / `KILLED` / `NOT-THE-WATCHER`, so a busybox `kill` that misbehaved would be visible.
- `@NODE@` is filled on the host.
- The hex no longer gets a trailing newline.
- Dry-run cases 2, 6 and 7 are added.

## 2. Findings

No BLOCKER, no MAJOR.

### MINOR

1. **Step 2 run too early takes over the dead run's live lease; dry-run assert 6 does not model this.**
   - Step 2 runs with `RUN=@DEAD@`. If the dead lease is still live, `pr_acquire` refuses as intended, but the chain
     continues: `…; r=$?; pr_release`.
   - `pr_release` then calls `pl renew` and `pl undo` and `pl release` **as the dead run**. `lease_valid_for @DEAD@` is
     true (`ble-lib-254.sh:107-109`), so it renews the dead run's lease, runs its journal in host mode and cancels its
     deadman (`:338-345`).
   - The deadman's own restore (provd, radio, joinwatch, openmanetd, `prov-lease-254.sh:72-79`) is replaced by
     `pr_release`'s partial one.
   - So assert 6 ("steps 0c–3 end at their acquire refusal, no replay call") is false for step 2 against the real
     library. It passes only if the stubbed `renew` refuses.
   - 0b tells the person not to proceed, so this needs a mistake to happen. Still:
     - step 2 should be `pr_acquire 7200 || { pr_unlock; exit 1; }` before the restore chain, so `pr_release` runs only
       for a lease this shell took;
     - the stub must model `lease_valid_for`, so that a renew of the dead run's own live lease succeeds. Assert 6 then
       tests the real behaviour.
2. **`dv-preflight` will not show the block.** `dv-preflight.sh:104-107` keeps only the `^FAIL` lines of P9's output
   (`f "P9 $n ${l#FAIL }"`) and drops everything else. The here-doc lines, and the `@NODE@` substitution the design
   adds there, never reach the person. Only a unit's `pr_begin` (`o=$(pr_p9); echo "$o"`) shows it. Make dv-preflight
   print the block when P9 emits it (between the `UD-RECOVER` markers), or have the FAIL line name where to read it.
   Add a dv-preflight fixture.

## 3. Verdict: **APPROVE**

0 BLOCKER, 0 MAJOR, 2 MINOR. The two MINORs can be fixed during implementation:
- step 2 must not release a lease it did not take;
- dv-preflight must show the block.

Every v6 finding of both reviewers is fixed in source terms. The designer's ble-recover disagreement holds, and my v6 m2
is withdrawn.
