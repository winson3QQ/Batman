# Review v6 — reviewer A — `docs/design/254-v16-ud.md` v6 (4e3adea)

I read the whole document. The new §7.1 block was checked step by step against `scripts/dv/prov-254.sh`,
`scripts/dv/slot-guard-254.sh`, `scripts/node/prov-lease-254.sh`, `ble-lib-254.sh`, `prov-base-254.sh`,
`prov-undo-lib-254.sh` and `prov-p9-254.sh`, because P9 prints it to a person. Read-only: no node, no ssh, nothing
committed. The mesh-id history is not a finding.

## 1. Were the v5 findings fixed?

### A v5 M1, point by point

| Point | State in v6 | Checked against |
|---|---|---|
| 1 `PR_WROTE_B` reset at source | Fixed: set after sourcing, inside step 2. | `prov-254.sh:47`; filter at `:494-496` |
| 2 a node on B goes back to A before the replay | **Not fixed in effect: step 0c replays before `back_to_a` → M1** | `prov-254.sh:205-214` |
| 3 a failed step 1 leaves a live lease | Fixed (`pl release` is unconditional). `cmd_release` refuses a lease that is not ours (`ble-lib-254.sh:338`), so it is safe when acquire failed. | — |
| 4 host death in the same boot | Fixed (step 0b: lease expiry + 60 s, tryboot-refusal line, ble-recover). See m2 for the missing command. | `ble-lib-254.sh:302-307, 350-362` (dm-fire removes the lease after acting) |
| 5 spurious deadman FAIL | Fixed (`PR_DM_BASE` from the current count). Same grep pattern as `:569-571`; `qr` prints `0` when grep finds nothing. | — |
| 6 stale host lock | Fixed (step 0a). | `:181-188` |

### B v5 M1

| Point | State in v6 |
|---|---|
| M1-1 | fixed (= A 1) |
| M1-2 | release fixed; the ordering is not → M1 |
| M1-3 | fixed |
| M1-4 | fixed (only a `pupdate254…` flag gets the block); see m1 for validation |
| M1-5 | fixed (pidfile + cmdline; step 3 checks the status and `NO-WATCHER`) |

### v5 MINORs (A)

| Finding | State in v6 | Where |
|---|---|---|
| m1 p3 read failure | fixed | §1.5, §9 stub |
| m2 encode on the node | fixed | §4.3 `HEX= RT=` |
| m3 `.enc.z` record | fixed | §1.4 |

### Step 2 traced against the library: correct
- `PR_V`, `PR_BASE` and `PR_S0_STATE` survive sourcing; only `pr_begin` sets them.
- `pr_acquire` with `RUN=@DEAD@`:
  - after step 1's acquire, `gc_rundirs` has removed the dead run's staging dir (no lease, no live deadman), or 0b
    removed it;
  - the dead run's journal was marked done by step 1's replay, so `undo-pending` is empty.
- `pr_restore_cycle` handles a trial itself (`:464`).
- `PR_BASE=member` skips `pr_make_legacy`.
- `pr_finish_snap` → `nb finish` removes the snapshot and the dirty flag (`prov-base-254.sh:332-336`).
- `pr_release` runs the dead run's journal (empty) and segment 1, then releases.

Step 3 is sound: `H0` is expanded inside the inner shell after `pr_h0`. Step 1 is sound.

---

## 2. Findings

### MAJOR

**M1. Step 0c replays the dead run's journal on B before `back_to_a`, which is exactly what its own comment forbids. In the case it exists for, it fails without moving the node.**
- Scenario. Step 0c is `pr_lock; …; pr_acquire 3600; r=$?; [ $r = 0 ] && { back_to_a; r=$?; }; pl release; …`.
  `pr_acquire` reads `undo-pending` and, if it is not empty, runs `undo-replay` for every other run, the dead run
  included (`prov-254.sh:209-213`; `prov-lease-254.sh:100`). On B:
  - lines bound `p6 slot:A` (`rm-hold`, `ssid-restore`, `uci-restore`) are left as "NEEDS-PERSON … bound to slot:A,
    running B" (`prov-undo-lib-254.sh:242-243`);
  - unbound lines still run on B: `p5-save` is `p6 -` and `svc-start` is `tmp -` (`uwhere`, `:76`). So `p5-save` saves
    p5 from B's live config;
  - `undo-pending` is then not empty → `FAIL undo still left` (`:213`) → `r≠0` → `back_to_a` is skipped.

  The node stays on B, and the person is told to repeat a step that cannot succeed.
- When it bites. The dead run's journal holds a slot:A line while the node is on B. Example: the trial arm dies between
  the `rm-hold` registration and its inline `undo-done` after landing. A held trial reverts by itself (0c says wait), but
  a hold flag that was written while the apply was refused or lost leaves `rm-hold` pending. Any such line on B
  triggers it.
- Evidence that the step can do without the lease. `back_to_a` needs no staged script and no lease before its reboot:
  - `qr "$ST"` reads state;
  - `rb_guarded` prints a self-contained node command (`slot-guard-254.sh:46-66`);
  - its `pr_find` acquires the lease **after** the reboot, on A (`prov-254.sh:226-240`), where the replay is correct.
- Fix.
  - Step 0c = `pr_lock; PR_DEADLINE=$(( $(mono) + 3600 )); back_to_a; r=$?; pl release; pr_unlock; exit $r`, with no
    `pr_acquire` before it. Its own `pr_find` then performs the replay on A, and step 1 finds nothing.
  - Add a dry-run case that would have caught this: node on B committed, plus a stubbed `undo-pending` that returns a
    `slot:A` line. Assert that `rb_guarded`'s rollback is sent and that no `undo-replay` call happens before it.
  - Today's assert 2 ("rollback before the replay acquire") passes on the v6 text only because the stub journal is
    empty, which makes it a check that cannot fail.

### MINOR

1. **Validate the placeholder P9 fills in.** `@DEAD@` comes from the dirty flag and lands in a printed `rm -rf
   /tmp/run/batman-dv/bt/@DEAD@`. An empty or odd value would make that `rm -rf …/bt/`, which removes `lease-prov`
   and every run's staging. Gating on the `pupdate254` prefix is not enough. P9 should print the block only if the id
   matches `^pupdate254[0-9]{10}$` (the `RUN` format, `prov-254.sh:40`), else the generic line. Add a P9 fixture with
   `pupdate254/../x` and an empty id.
2. **Step 0b "run ble-recover" gives no command.** The person needs the exact one. ble-recover is
   `ble-central-254.sh recover` (`scripts/node/ble-central-254.sh:118`), and it must be staged first (the scripts live
   in a per-run tmpfs dir). Print the staging + call.
3. **How P9 carries the block.** P9 runs on the node via `sh -s` (`dv-preflight.sh:104`). The block is full of `$(…)`,
   `$r` and quotes, so it must be emitted from a quoted here-doc (`<<'EOF'`), with only the three `@…@` placeholders
   replaced (by `sed` with validated values). Otherwise the node's shell expands it. Also confirm that the lints stay
   green with the block inside a `scripts/node` file:
   - slot lint (1) counts `release`, and the block has `pl release`;
   - tmp-trust: the block contains `/tmp/run/batman-dv/bt/…` literals, which the existing allowlist row probably
     covers.
4. **Dry-run negative control.** It is shown only for asserts 2–4. The v5 text also fails assert 5 (no `PR_DM_BASE`):
   list it, so the deadman-count fix is controlled too.

---

## 3. Verdict: **APPROVE-WITH-CHANGES**

0 BLOCKER, 1 MAJOR, 4 MINOR.
- Everything else in v6 holds against source, including steps 1–3 of the recovery block, the release-on-failure fix,
  `PR_WROTE_B` and `PR_DM_BASE`.
- M1 is a one-line change to step 0c (drop its `pr_acquire`; `back_to_a` acquires on A after the reboot) plus one
  dry-run case with a non-empty journal.
- No test-design change is needed.
