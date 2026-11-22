# Review A: `docs/design/254-v16-group4.md` v1 (harness PR A)

Reviewer: A (independent, adversarial). Tree: `C:\src\Batman-g4h`, branch `test/254-v16-group4`, HEAD 325fad1 (= main b885a2c + the design). I worked from source only: no ssh, no harness run, no device. Device evidence cited by the design was checked only where a local copy exists (`Desktop/Batman/v16/g1/prov-ac-flap-254-wsl35.log`).

**Verdict: REJECT (revise to v2 and re-review the whole document).** There is no BLOCKER. The direction is sound: the P3 premise for ac-flap, a waiting-but-not-re-reading mutant, a slot-aware restore and guarded reboots are all the right fixes. But 8 MAJOR findings are open. Three are scope gaps that will fail the wsl.37 full validation the design targets (M1, M2, M5), and three are negative controls or proofs that do not prove what they claim (M3, M4, M6).

## What was verified

| Design claim | Result | Evidence |
|---|---|---|
| `health_ok` §3.7.6(a) "svc batman-provhelper down" | ✅ | `feed/batman-provision/files/usr/bin/batman-autocommit:500-503` |
| 99zz wait loop at :441-443 (the design's text; the loop line itself is :443) | ✅ | `batman-autocommit:443` `while [ "${pr%% *}" = 99zz ] … pr=$(prov_read); done` |
| why file = `$RUNDIR/autocommit.why` (non-dry) | ✅ | `:49` `ACD=$RUNDIR`; rewritten every poll at `:597` |
| Revert reason = the last poll's why | ✅ | watchdog `:245-247` reads `autocommit.why` at the deadline |
| Helper respawns forever, 5 s delay | ✅ | `feed/batman-prov/files/batman-provhelper.init:13` `respawn 3600 5 0` |
| provd-stable never written under helper-flap | ✅ (inferred from source) | `stable.go`: needs a provd connection open 60 s; the mutant exits 5 s after serving (`tests/wbox/helper-flap.patch`) |
| hold-commit does not stop the deadline revert | ✅ | the watchdog checks only `held` (hold-once, `:100-106`, `:211`, `:243`); `held_commit` (`:65`) is used only in the poll loop |
| misc-l38 deletes the whole loop | ✅ | `tests/wbox/gen/edits.pl:185-188` |
| `pr_restore_cycle` A-only, bare reboot at :480 | ✅ | `scripts/dv/prov-254.sh:465`, `:480` |
| `back_to_a` "already on A" for an A trial | ✅ | `prov-254.sh:398` (no trial_rc check) |
| Lint regex without `reboot` | ✅ (at :283, not :282) | `scripts/dv/test-slot-guard-254.sh:283` |
| `slot=` in snap identity at node `:230` | ⚠️ | written at `scripts/node/prov-base-254.sh:112`; `:230` is the overlay-restore *reader* |
| test-all.sh :81/:82/:88 | ✅ | `app/rust/batman-proto/test-all.sh:81,82,88` |
| prober `:227-230`, test `:145-146`, `:275-279` | ✅ | `app/lib/src/nodelink/prober.dart:228-230`; `app/test/nodelink/prober_test.dart:144-147,274-279` |
| wsl.35 flap log | ✅ | log lines 13 (not HELD), 14 (43 exits), 21 (no dry decision), 22 (`back_to_a: already on A`), 23 (`lease renew +1800:` empty) |

## Findings

### MAJOR-1: 02 on B committed is a fleet state the rest of the suite does not accept; only the restore is fixed

**Scenario.** §3 / §8 say that 02 "lands on B by itself after the second wsl.37 OTA", and that from then on the restore keeps 02 on B. But other units require 02 to be on A committed:
- `prov-ac-fleetchan-254` part 1 fails at once with "02 precondition: A committed on V". Evidence: `scripts/dv/prov-ac-fleetchan-254.sh:26`.
- Its end check is "02 committed on A at the end" (`:77`). Its part 1 rolls 02 back to A with `rb_guarded "$b0" B any` (`:44`). So a run that starts with 02 on B ends with 02 on A, and the next netjoin-fleet snapshot sees a different slot.
- `pr_peer_after`'s WARN branch expects 02 at `"A 1"` (`prov-254.sh:613`).

The wsl.37 full validation is the target of this PR, and in it fleetchan will FAIL on a precondition this design creates and documents.

**Fix.** Decide the 02 slot policy fleet-wide, either:
- normalise 02 to A committed (a `pr_normalise` for 02, or a P9 step), so that every unit keeps its A premise; or
- make every 02-touching unit slot-agnostic.

Then list the 02-touching units (fleetchan, netjoin-fleet, ble-254 / bt-uart-305 on 02, `pr_peer_after`) in the lifecycle matrix with before/after and a proof.

### MAJOR-2: "The product reboots the node under a unit" is a generic path; the design fixes it only for ac-flap

**Scenario.** hold-commit never stops the watchdog: a held trial is reverted at its deadline (600 s on the Pi 4, `batman-autocommit:435`, `:209-213`, `:243`). Any unit that keeps a held B trial past the deadline gets rebooted by the product. After that reboot:
- the lease, the deadman and the run dir are gone (tmpfs; compare `scripts/dv/bt-uart-305.sh:73`);
- `back_to_a` answers "already on A" and returns 0 (`prov-254.sh:398`);
- `pr_restore_cycle` → `pr_lease_renew` fails (`:219`), and the result is NEEDS-PERSON.

This is exactly the wsl.35 sequence (log lines 22-24). The design's change to `back_to_a` adds trial_rc = 1, but a product-reverted node is A with trial_rc = 1, so it still says "already on A" with a lost lease. The node also ran without a deadman for the time in between.

**Fix.**
- `back_to_a` / `pr_restore_cycle` compare the current boot with `PR_LAND_BOOT` (or the last known boot).
- On a change, report "product reboot under the unit (boot X → Y)" as a FAIL with the revert line, then re-acquire through `pr_find` (`prov-254.sh:226-240` re-stages and re-acquires) instead of renewing a lease that no longer exists.
- Add a row to the lifecycle matrix for all units, with an offline negative control: stub `qr` returns a new boot on A committed; main → NEEDS-PERSON, fix → FAIL + restore proceeds.

### MAJOR-3: §4 "every host reboot is guarded and linted" is not true; the site list and the lint are incomplete

**Evidence.** These plain `reboot` sites are not in §0 / §4, and the new regex (`batman-slot … reboot`) cannot see them:
- `scripts/dv/prov-ac-noarm-254.sh:37`, `scripts/dv/prov-chain0-254.sh:68`, `scripts/dv/chain1-254.sh:189`, `scripts/dv/prov-bench-s0-254.sh:425`. These are intentional entries *into* an armed tryboot; they must be allowlisted with that reason.
- `scripts/fault-injection.sh:173` (F1 loop: `sync; reboot`, 3×).
- `scripts/dv/prov-base-254.sh:63` (sysrq b, on purpose).
- `scripts/node/halow-fi-263.sh:28,35-37,61` (node-side, no disarm).
- `scripts/daily-validation.sh:2322,2340,2481,2631,2656,2667,2680` (`reboot_and_wait … reboot` / `reboot -f`). This is the release-gate runner itself, and it is out of the lint scope.

`batman-slot:1033-1050` falls back to `exec reboot` when the flag is armed: a plain reboot has the same hazard the design is closing.

The regex also misses indirect calls inside the new scope:
- `scripts/node/prov-rbarm-254.sh:48` (`"$BS" rollback`);
- `:54` and `scripts/node/prov-rbfix-254.sh:24` (`"$R/usr/sbin/batman-slot" commit`: a quote between `batman-slot` and the verb does not match `batman-slot[[:space:]]+`).

The design's negative control ("the extended lint on b885a2c FAILs and names *exactly* the sites of §0") is also wrong in the other direction. It will additionally flag:
- `chain1-254.sh:156` (`reboot committed ch1-deadman`, not allowlisted for reboot);
- `scripts/node/prov-p9-254.sh:54` and `scripts/node/prov-rbarm-254.sh:61` (person text);
- the existing pty-commit / fault-injection allowlist lines.

**Fix.**
- Classify every reboot path: `batman-slot reboot`, plain `reboot` / `reboot -f`, sysrq, and `$VAR` / quoted-path calls of batman-slot. For each, say guard or allowlist with a reason (intentional tryboot entry, deliberate power-loss).
- Extend the lint to plain reboot and to quoted / variable invocation, or state precisely what the lint does not cover.
- Decide `daily-validation.sh` (in scope, or the reason it is not).
- Restate the negative control as the exact expected FAIL list.

### MAJOR-4: The l38nega offline negative control is tautological

**Scenario.** §2 proposes `tests/prov-p1/misc-dry.sh` "with a stub autocommit that does not re-read: arm a must FAIL". That test drives only the node-side machinery (`scripts/node/prov-misc-254.sh` start / inloop / judge) against a stub whose output is fixed text (`misc-dry.sh:24-36`).
- A stub that "does not re-read" just prints `required: 0`, so it proves nothing about the real autocommit or about the misc-l38r mutant.
- The arm-a verdict is judged on the host (`scripts/dv/prov-misc-254.sh:105-106`), which misc-dry never runs.

A real offline harness for exactly this already exists: `tests/prov-p1/autocommit-mesh-arm.sh`. It runs the REAL prov/arm block, including the wait loop, with `sleep` stubbed. Case `:32` "L38 helper comes at poll 5" is arm a; its header says the misc-* mutants make it FAIL. CI runs it only on the real file (`.github/workflows/ci.yml:123`); no job runs it against a mutant.

**Fix.** The negative control for misc-l38r is:
1. apply `edits.pl misc-l38r` to a throwaway copy;
2. run `autocommit-mesh-arm.sh <mutant>`: case "L38 helper comes at poll 5" FAILs (`NEED_MESH=0 sleeps=60`), and the real file PASSes.

Also check that misc-l38 *passes* the "helper never comes" case only through the missing wait, which separates the two mutants. Best, add a CI loop "each misc-* patch makes autocommit-mesh-arm FAIL" (it is claimed today but not enforced). Keep the on-device l38nega as the second control.

### MAJOR-5: Adding misc-l38r to `helpers.list` breaks the wsl.36 tools and the "misc device run on wsl.36" planned in §8

**Scenario.**
- `scripts/dv-prov-tools.sh:47-55,73-74` extracts each misc-* autocommit from the `V.dirty.wbox-<name>` payload and FAILs when the count read differs from `helpers.list`. No wsl.36 misc-l38r payload exists, so dv-prov-tools FAILs on wsl.36 as soon as PR A merges.
- In the unit, `bindac misc-l38r` fails "no verified … autocommit" (`scripts/dv/prov-misc-254.sh:30`). Then `dr … || return 1` (`:107`) aborts `dryarms`, so L42 / L43 / L51 and every service arm (L11, L9/L10, L27, L3) never run.
- §8 says the misc unit runs on wsl.36 in this PR "except l38nega". The code has no way to skip one arm.

**Fix.** Pick one, and state it in §8 with how the misc device run proves the other arms:
- an explicit skip: l38nega NOT-JUDGED when the variant is absent for V, with dv-prov-tools tolerating a variant missing from V only for a named pre-wsl.37 V; or
- land the helpers.list row with the firmware re-pin; or
- derive the misc autocommit on the host from the release autocommit plus the patch. This is a policy change: the tools are currently "taken from the -wbox payloads of rc V and nothing else" (`dv-prov-tools.sh:3`).

Also state the window between the PR A merge and wsl.37 during which main cannot validate wsl.36.

### MAJOR-6: The firmware re-pin identity check (`git diff b885a2c <main> -- feed/`) does not cover what the image ships

**Evidence.** Feed Makefiles install files from outside `feed/`:
- `../../deploy/…` (15 references, e.g. `feed/batman-payload-host/Makefile:165-182`);
- `../../scripts/verify-profile.sh` (`:184`).

Also, the wbox images are built from `tests/wbox/*.patch` of the pinned commit. If PR B, or anything merged between, touches `deploy/` or `scripts/verify-profile.sh`, wsl.37's product differs from what was reviewed, while the `feed/`-only diff is empty.

**Fix.**
- The firmware PR shows `git diff b885a2c <main> -- feed/ deploy/ scripts/verify-profile.sh` empty, plus every reference found by `grep -rhoE '\.\./\.\./[^ ]+' feed/*/Makefile`, generated rather than hand-listed.
- It also shows that `tests/wbox/*.patch` other than the new one are byte-identical.
- If PR B is not harness-only, say so here.

### MAJOR-7: The p5 unmount rule has no reproduction and states a wrong premise

**Scenario.** §3 adds an unmount by pattern, but the reality check names no observed p5 mount (no `/proc/mounts` capture from a failed restore). The user rule is "a bug is reproduced before it is fixed". And the premise is wrong:
- `*cfgsave-mnt.*` is *not* a product read-only mount. It is batman-config-save's rw write mount (`feed/batman-provision/files/usr/bin/batman-config-save:358-366`, verified rw).
- It is safe to unmount only because the restore holds the config-save lock first (`scripts/node/prov-base-254.sh:218-219`, lock_take then mount check; config-save mounts only under its lock, `batman-config-save:273`). In that case such a mount can only be a leftover of a dead process.
- Its fallback is `/tmp/cfgsave-mnt.XXXXXX` (`:124`), not `/tmp/run`, which contradicts §9 "fixed strings under /tmp/run".
- `*autocommit.p5*` is mounted *without* any lock (`batman-autocommit:450-452`). Unmounting it under a live autocommit can flip its `.seeded` read (`expected_in_mesh` returns 1 → NEED_MESH=0), so the harness would change the product's decision.

A likely real source is documented in the tree: `--prov-get` leaves its ro mount behind on an error path (`scripts/dv/prov-legacy-upgrade-254.sh:47-48` comment, "#254 checklist").

**Fix.**
- Reproduce, or cite the captured mount line, first.
- Unmount only under the held lock and only mounts whose owner process is gone, or only `cfgsave-mnt` + `pbm`, and leave `autocommit.p5` as NEEDS-PERSON unless autocommit is not running.
- Correct §3 / §9 (rw vs ro, the `/tmp` fallback).
- A failed `umount` (busy) dies naming it.

### MAJOR-8: The `PB_MOUNTS` seam test runs p5-restore as root with `P5=/dev/mmcblk0p5` hard-wired

**Scenario.**
- `prov-base-254.sh` refuses non-root (`:26`).
- `PROV_BASE_TEST_ROOT` prefixes BASE / ST / rundir only; `P5=/dev/mmcblk0p5` stays absolute (`:33`).
- A test that passes the mount check under the seam reaches `dd … of="$P5" conv=fsync` (`:220`):
  - on CI or WSL it creates a regular file in `/dev` as root;
  - on a host with an SD reader, or on a Pi, it writes a real partition.

That is "our own mistake damaging the lab".

**Fix.** Under `PROV_BASE_TEST_ROOT`, P5 must also be redirected (e.g. `P5=${PROV_BASE_TEST_P5:-/dev/mmcblk0p5}`, honoured only with the test root), or the test must assert exit before the dd line. Add a guard test: with the seam set and P5 not redirected, the script refuses.

### MINOR-1: ac-flap determinism; state the argument and match on substrings

The assertions are deterministic given the product.
- With the helper running, `health_ok` stops at (b), because provd-stable is never written under the mutant (stable.go needs 60 s). So the why is always either (a) or (b), HELD can never occur, and the final reason is (a) or (b) by phase.
- Step 4 sees (a) with probability ≈ 1 − 0.5^40 (cycle ≈ 11 s from 43 exits by uptime ~480; POLL = 10 s, `:30`).

Three changes are still needed:
- (i) Match as `case … in "svc batman-provhelper down"*`, not equality. With NEED_MESH = 1 the why is compound (`"$why; mesh not joined…"`, `:595-596`), and radio1off already uses substring match (`prov-ac-radio1off-254.sh:24`).
- (ii) Bound the step-4 polling by `$RUNDIR/autocommit.deadline` − margin, not a fixed 480: a p6 `autocommit.timeout` of 300 (`:436-437`) reverts before 480.
- (iii) Record the per-sample why histogram in the log as evidence.

### MINOR-2: ac-flap negative controls

The "AC HELD → FAIL" control exercises `pr_wait_reverted`'s branch, not the new step 4. Add a fed sequence where every sample is (b) and none is (a). It must FAIL "the helper gate never fired": that is the control for a product without §3.7.6(a) but with (b). Also state that the new unit FAILs on a pre-P3 image (a downgrade path of the harness).

### MINOR-3: "E-H5 #2 timing is measured by prov-autocommit-p3-254" is not true

`scripts/dv/prov-autocommit-p3-254.sh:26-31` only bounds the dry run (INVALID with no decision within 180 s); it prints no time to the decision. Either carry over the `+Ns` stamp or say that the measurement is dropped.

### MINOR-4: `back_to_a` on an A trial

After `rb_guarded <b> A 0` the node lands on B committed, so `back_to_a` then returns 1 by its own post-check (`prov-254.sh:403`). That is an extra reboot that ends in the same NEEDS-PERSON (for example a legacy-upgrade abort between `pr_ota_b V A` and `release_commit A`, `prov-legacy-upgrade-254.sh:32-35`). Name this outcome per caller. Also note that the `pr_ota_b` missed-landing path (`:390`) ignores the return value.

### MINOR-5: Converting individual sites (§4.1)

- (a) `_sg_cmd` has no delay hook, and inside `setsid sh -c 'sleep 2; …'` the SENT is invisible (`fault-injection.sh:462,503`). Specify the form, e.g. the guard runs synchronously and its rb part is `(sleep 2; batman-slot reboot …) &`.
- (b) `prov-overlay-wipe-254.sh:25` runs `firstboot -y` before the reboot. A WRONG-STATE then leaves a wiped, unrebooted node. Put `firstboot -y` in the guarded command after the checks.
- (c) `ble-254.sh:294`, `bt-uart-305.sh:55` and `addr-defer-reconcile-254.sh:13` do not source `slot-guard-254.sh` and read neither the slot nor a boot8 (ble reads a full boot_id). Say where slot + boot8 come from (one ssh).
- (d) Removing the pty-commit `:40` allowlist row is required, or the lint FAILs with "allowlist entry no longer found".

### MINOR-6: Node-side dead-man disarm

Say what happens when the flag stays armed: no reboot means the leaked IRK or the dirty UART stays. Give the fail-secure argument and how it reaches a person. Add a stub negative test (armed flag → no reboot, a log line), as `test-slot-guard-254.sh:96-106` does for the host guard.

### MINOR-7: Ownership table (§7)

The guard's `DISARM` is a second writer of the tryboot flag (vcmailbox, outside batman-slot's `slot_lock`), and §4 adds more call sites plus asynchronous node-side dead-man writers. State why that is safe against a concurrent `batman-slot apply` arming the flag (e.g. units never reboot during their own OTA; dead-men fire only after lease loss), or add a slot-lock-free condition (`pr_slot_free` exists, `prov-254.sh:114`).

### MINOR-8: The netjoin-fleet device proof needs a legacy 02

The unit is INVALID unless 02 is legacy (`prov-netjoin-fleet-254.sh:104-105`). The bench S0 is an N0 member (`prov-254.sh:672-674`). State 02's prov state on the bench, with evidence, or the §3 device proof will be NOT-JUDGED.

### MINOR-9: wbox details

- §7 "lint-wbox fails on a hand edit" is overclaimed. `scripts/lint-wbox.sh:2-18` checks form, apply and witnesses, not equality with edits.pl output.
- Place the misc-l38r witness log line outside the loop (once). With the header comment it reaches the ≥ 2 occurrences lint-wbox requires.

### MINOR-10: Citation drift

The lint regex is at `test-slot-guard-254.sh:283` (not :282). The snapshot `slot=` is written at `prov-base-254.sh:112`.

### MINOR-11: prober test

Assert that at least one fragment reached the prober before the 50 ms budget. Otherwise a Windows timer stall makes the fixed test pass vacuously, and the negative control (mutated `:228`) silently stops discriminating.

## Missing from scope or the lifecycle matrix (summary)

- 02 slot policy across units (M1).
- The product rebooting under *any* unit (M2).
- Plain or indirect reboots and daily-validation (M3).
- The pre-wsl.37 window for dv-prov-tools and prov-misc (M5).
- Downgrade: the new ac-flap / l38nega against older images (MINOR-2, M5).
- The device evidence plan for converted sites that no device run in this PR exercises (all of §4.1, the node dead-men). State them as "first exercised in the wsl.37 full validation" or "stub only".
