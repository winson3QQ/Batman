# Review B — `254-v16-group1.md` v2 (2026-11-21)

Reviewer B, round 2. I reviewed the whole v2 document again, not only the §9 dispositions, against the worktree
`C:/src/Batman-g1` (HEAD `4b61b3c`). Read-only; no node touched.

**Verdict: APPROVE-WITH-CHANGES.** The v1 BLOCKER is resolved: §4 L18 was removed and moved to #255. Most v1 MAJORs
are fixed as stated (checked below). Two new MAJORs remain. Both are local, and both need a short v3 plus a
re-review of §2 and §3:

- §2 does not retry rc 3, yet the wireless-txn design names a retry as the recovery for an rc 3 forget. That leaves a
  node that has left the network still on its old mesh.
- §3's new dry directory has no lifecycle. It also falls outside the harness snapshot/restore, which today cleans
  between dry units. So "§7: nothing needed" is wrong.

## v1 findings — checked

| v1 | Status in v2 | Check |
|---|---|---|
| B-1 / M-4 (§4) | ✅ removed, L18 → #255 | §0 row L18 |
| M-1 (Pi 3 evidence) | ✅ Pi 3 is layout-gated and unchanged; stated as unsupported (P-U14) | the `bf_get` consumers are Pi 4-gated: `batman-slot:1009`, `platform-ab.sh:307`. K90's want file is written only at `batman-slot:1022` after `bf_pi4`; `batpower:91` only removes it |
| M-2 (device run never exercised the new arm) | ✅ second OTA bench → bench | a same-version reinstall is allowed: `release/release.go:400` (`c >= 0`, "the same = a reinstall") |
| M-3 (retry vs `otaBusy`) | ✅ postponed, not counted | gate as in `node.go:254,263` |
| M-5 (dry run writes real state) | ⚠️ partly. Markers moved, otalog off, `:238` moved. The new dir's lifecycle is missing → MAJOR-2 below | — |
| m1–m12 | ✅ handled as §9 says (119.9 ✅, `provstore/exec_dstate_test.go` ✅, 39 files ✅ [37 + 2, verified with `git ls-files -s` in round 1]) | — |

---

## MAJOR

### MAJOR-1 §2: rc 3 counts as "not curable", but the documented recovery for an rc 3 forget is a retry

**Scenario (field).**

1. A `network/leave` commits, then the node loses power before the forget is saved (or the forget never verified).
2. At the next boot, uci still holds the old network, and netifd brings the old mesh up from it.
3. The boot Finish wants `wantForget`. `finishWantsRadio` does not wait for the radio on a forget (`main.go:693-697`,
   `wtxn.go:437-452`), so the forget starts while netifd is still bringing the radio up on a slow boot.
4. `--forget-mesh` returns rc 3 when netifd is `up=true` or `pending=true` at its deadline (254-wireless-txn §19.2
   rule 3, `254-wireless-txn.md:561-566`).
5. v2 classifies rc 3 as not curable, so nothing retries. The node the owner removed stays on the old mesh with
   the network key until somebody sends a verb or reboots it.

**Why this is wrong.** It is the fail-secure property of a leave ("nothing of the network stays on the air", §19.3),
and §19.2 itself gives the recovery: "a retry after the backoff (60 s, doubling), which runs the forget again, now
on a settled radio".

**The stated reason does not hold.** v2 excludes rc 3 because a retry would "repeat the same long failure" (A-M2).
That is true for rc 124 (300 s exec deadline, `main.go:84-85`), not for rc 3. An rc 3 costs at most the lock wait
(90 s), the settle wait (30 s) and the read-back (`READBACK_WAIT=60`, `halow-setkey:39-41`) or the forget wait
(`FORGET_WAIT` 30 s plus 10 s escalation). That is the same order as rc 2, which v2 does retry.

**Fix.**

- Treat rc 3 as curable: at least for `wantForget`, and preferably also for `wantNet`. An rc 3 on a slow boot is
  "applied, not verified" (`halow-setkey:497-499`): the radio came up late, and the next try is satisfied once it is
  up (`satisfied()`, `wtxn.go:213-225`).
- Keep only rc 124 and the definitive `desired()` causes as not curable.
- Add unit (e'): forget rc 3, then ok on retry 1, `.txn` gone, markers removed. Negative control: v2-as-written gives
  no retry.

### MAJOR-2 §3: `autocommit.dry.d/` is never cleaned, and the harness no longer cleans it between dry units

**Today.** The harness's `save` / `restore` handle every dry-run artifact by name and wipe them between units
(`scripts/node/prov-misc-254.sh`):

- `RDF` at `:35` lists them, including `autocommit.ctl.dry`;
- `:65` snapshots them;
- `:143` removes them and puts the snapshot back.

Several dry units run in one boot: `prov-misc` t1 / t1b, `prov-ac-flap-254`, `prov-autocommit-p3-254`,
`payload-274.sh:78` and `tmp-trust-280.sh:71`.

**After v2.**

- All markers and `CTL` move into `autocommit.dry.d/`, which is not in `RDF`, and v2 has no cleanup of its own.
- A second dry run in the same boot finds the first run's `dry.d/wd` (`mkdir … || exit 0`, `batman-autocommit:200`),
  so its watchdog exits at once.
- It also finds a stale `decided`, `hold-consumed` (which makes `held()` stand down), and stale `canary-ok` /
  `warn-*`.
- The units' outcome then depends on the order they run in. The dry log can show "hold present" or a missing
  REVERT decision for reasons the unit did not set up.
- Comments and snapshots that name `autocommit.ctl.dry` go stale: `prov-ac-flap-254.sh:11` and
  `prov-misc-254.sh:9,35`.

So §7's "§3: nothing needed" is not true.

**Fix (pick one, and state ownership and lifecycle).**

- (a) Each dry run starts with a fresh dir: rename the old one away, or use `rm -rf` only when no other dry run is
  alive (`pid_is` on a `dry.d/run/pid`).
- (b) A per-run dir `autocommit.dry.d/<pid>/`, removed at exit, with the watchdog subshell inheriting it.

In either case, add `autocommit.dry.d` to `RDF` in the harness PR and update the two comments. Test: two dry runs
back to back in one boot both produce the same decision lines. Negative control: v2-as-written, where the second
run's watchdog exits at once.

---

## MINOR

1. **§1: missing-lib behaviour of arm / disarm.** `batman-slot` will source `bootfacts.sh` at the arm and disarm
   sites, but v2 does not say what happens if it is absent or fails to define `bf_vc_ack`. `cmd_reboot`'s precedent
   is to fall back to "plain" (`:1008`). For arm the fail-closed answer is to die, and for disarm the layout's
   "unreadable" path. Add the case to the offline table.
2. **§1: global-name hygiene.** `bootfacts.sh` functions assign unprefixed globals (`h`, `v` in `bf_preq` /
   `bf_dtnum`, `bootfacts.sh:30-37`), and `batman-slot` uses a global `v` (`:525, :575, :870`). It is harmless today,
   because arm and disarm would call only the new predicate. Require `bf_vc_ack` to use only its positional
   parameters (local in an ash function) and not call `bf_preq` / `bf_dtnum` from `batman-slot`, or prefix the lib's
   variables.
3. **§1 lifecycle text.** The device check expects "trace shows `tryboot flag is 0` path". That string is printed only
   for a NON-zero flag (`batman-slot:1010`, `why="tryboot flag is $g"`, plain mode). With a cleared flag the trace
   shows `SLOT REBOOT mode=explicit to=<n>` (`:1020`), and K90 writes `batman-reboot: explicit restart to firmware
   partition <n>` to kmsg (`batman-reboot:40`). Assert those two lines.
4. **§2: cause classification overlaps.** "A transient `CheckRestorable` error" (curable) reaches `finish()` only
   wrapped as a `desired()` error: `wtxn.go:184-187` returns `fmt.Errorf("cannot check the pre-change settings now
   …")`, which `finish` turns into the generic `EState` CRIT (`:317-320`). Yet "a `desired()` error" is listed as not
   curable. `lastFinishCause` must be set at the source:
   - `desired`: definitive (`storedNet` malformed) vs transient (CheckRestorable non-`RestoreRefused`);
   - `SaveTxn`: say whether a save rc 124 (`ConfigSaveTimeout` 300 s, `provstore.go:458`) counts as the curable
     "EStorage save failure". If it does, 8 × 5-min holds are possible, and that contradicts the "long hold never
     repeated" claim.
5. **§2 device unit: injection precision and dead-man.**
   - The one-shot wrapper "returns rc 2 on its first call". Other callers of `halow-setkey` can consume that call
     first: `--status` (e.g. via `halow-status`) or the helper's own `--check-only`. Match the write invocation only
     (`--no-persist` with `--mesh`/`--forget-mesh`), and make the unit INVALID if the injected call was not the
     Finish's.
   - "Helper init disabled" persists across the sysrq reboot. State who re-enables it if the harness or ssh dies, so
     the node is not left without a helper (the app cannot manage it then).
6. **§2: postponement is unbounded.** `SlotLockHeld` reports busy on any open error except ENOENT
   (`wtxn.go:465-470`), so a broken flock file postpones forever, taking `n.mu` briefly every 60 s. That is harmless,
   but give it one log line per postponement episode, not one per minute (log noise in `logread`'s ring).
7. **§2: platform row.** Add "Pi 4 only (bench 02 / 04); Pi 3 unsupported (P-U14)" to the lifecycle, as §1 does.
8. **§3: "no code path changes when DRY ≠ 1" is a claim about a refactor.** Every marker variable is touched, so
   production paths change textually. The existing real-run units (autocommit commit / revert, `fw-boot-254`, which
   reads `$RUNDIR/autocommit.run/pid`) must be listed as the regression evidence, not only the dry units.
9. **§8 step 1** still says "owner approval pending" for 3 reboots and ~35 min off-mesh. It is fine as a gate, but
   the PR must not report §2 as reproduced until that run exists (owner rule: reproduce before fixing).

## Assumptions checked this round

- ✅ A same-version OTA is a reinstall, not refused (`release.go:399-401`).
- ✅ `bootfacts.sh` is in `RAMFS_COPY_DATA` (`platform-ab.sh:42`).
- ✅ Only `cmd_reboot` writes `batman-reboot.want` (`batman-slot:1022`); `batpower:91` removes it.
- ✅ The rc 3 forget recovery is a retry (`254-wireless-txn.md:561-566`).
- ✅ The read-back and forget waits bound an rc 3 (`halow-setkey:39-41`).
- ✅ A forget Finish does not wait for the radio (`wtxn.go:437-452`).
- ✅ The harness snapshot/restore list `RDF` and its wipe (`prov-misc-254.sh:35,65,143`).
- ✅ No dry unit relies on DRY otalog lines (only `prov-misc-254` counts them, as `TRACE-ADDED`, `:148`).
- ⚠️ `/dev/vcio` mode: v2 defers this to implementation. Read-only probe: `ls -l /dev/vcio` on 04 and 02.

## Security (per actor)

- **Remote / BLE peer and compromised provd.** No new input in §1–§3. MAJOR-1 is itself a security item: a node that
  has left keeps the network key on the air until an interaction.
- **Local unprivileged process.** It cannot reach the run dir (#280), `.txn` or the slot flock. The `dry.d` ownership
  check is as `CTL`. ✅
- **Our own mistakes.** MAJOR-2 is the harness and the node drifting apart silently: the class #280's
  `rundir-paths.txt` lint exists for. Add `autocommit.dry.d` there (v2 does) and to `RDF` (v2 does not).
