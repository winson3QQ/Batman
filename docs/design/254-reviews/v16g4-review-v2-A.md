# Review A, round 2: `docs/design/254-v16-group4.md` v2 (harness PR A)

Reviewer: A (independent, adversarial). Tree `C:\src\Batman-g4h`, HEAD d1a60cd (= main b885a2c + the design). Method:
the whole v2 read, then the cited code at b885a2c with read-only `grep` / `sed` / `git show`. In addition: the firmware
checkout `//wsl.localhost/Ubuntu-24.04/home/yello/firmware-2710` (HEAD 302c80b1 "pin(#254): Batman main b885a2c —
1.5.14-wsl.36"), read only, and one scratch `patch --dry-run` of the four `tests/wbox/misc-*.patch` against
`git show b885a2c:…/batman-autocommit`, done in my scratchpad. No ssh, no harness script, no node touched.

**Verdict: REJECT (revise to v3, then re-review the whole document).** There is no BLOCKER. Most round-1 findings are
really resolved: ac-flap, the `l38nega` control, overlay-wipe `pre=`, FI:462 trial 0, the p5 unmount premise, the seam
gating idea, E-H5 #2, the prober and the test-all changes. But v2 adds five MAJOR problems:
- the product-reboot recognition fires on every normal restore (M1);
- the 02 P9 check gives spurious FAILs (M2);
- the new `host` kind breaks the firmware readers of `helpers.list` (M3);
- lint pattern 2 is not implementable as written (M4);
- the daily-validation allowlist rests on a false fact (M5).

## Round-1 findings: resolution check

| Round-1 | v2 | Status |
|---|---|---|
| A M1 / B M5 (02 on B) | §3.1 P9 contract | ✅ in principle; new problem M2 |
| A M2 (product reboot) | §3.2 | ⚠️ the design is wrong as written (M1) |
| A M3 / B M4 (sites, regex, negative) | §4.2 table, §4.3 | ✅ site table complete (42 rows checked against `rg`); ⚠️ pattern 2 (M4), text-line count (m6) |
| A M4 (tautological l38 control) | §2 `autocommit-mesh-arm.sh` | ✅ discriminates: the case "L38 helper comes at poll 5" (`tests/prov-p1/autocommit-mesh-arm.sh:31`) expects `NEED_MESH=1 sleeps=5`; with `pr=$(prov_read)` removed the loop runs 60 times on the stale 99zz → `prov=unclaimed`, FAIL |
| A M5 / B M6 (wsl.36 tools) | §2 host derivation | ✅ the wsl.36 gap closes; new problem M3; m1 |
| A M6 / B m3 (feed diff) | moot (no rebuild) | ✅ |
| A M7 / B M3 (p5 unmount) | §3.3 harness dirs only | ✅; m3 |
| A M8 (seam reaches /dev) | §3.3 gating | ⚠️ contradicts the root check (m3) |
| B M1 (FI:462) | row 11, trial 0 | ✅ (`fresh-254` already uses `reboot_guarded … 0`, `v16g4-sites.md` §3) |
| B M2 (firstboot before guard) | `pre=` | ✅ ordering right (`slot-guard-254.sh:47`: DISARMED is ANDed before `$rb`); m2 |
| A m1, m2, B m1 | §1 | ✅ |
| A m3, B m2 (E-H5 #2) | moved to p3 | ✅ |
| A m4, B m6 (A trial) | §3.2 | ⚠️ the outcome per caller is still unnamed (m5) |
| A m5, B m5 | rows 12, 13 | ✅ |
| A m6, B m7 (dead-man failure) | rows 36–38, 42 | ✅ path stated; ⚠️ no behaviour test (m4) |
| A m7, B m8 (DISARM writer) | §4.1, §7 | ✅ |
| A m9, m10, m11, B m4 | | ✅ |
| B m9 (Pi 3, CI, title) | | ⚠️ the Pi 3 rule is applied inconsistently (m7) |
| B m10 (behaviour proofs) | §4.3 host sites | ⚠️ node-side sites not covered (m4) |
| B m11 (lifecycle rows) | §8 | ⚠️ "lock left by a dead holder" answers the lease lock, not the config-save lock asked about (m3) |

## Findings

### MAJOR-1: §3.2 compares against `PR_LAND_BOOT`, so every normal restore looks like a "product reboot", and the prescribed re-acquire fails

**Scenario.**
- `PR_LAND_BOOT` is set in one place only: `pr_ota_b` at landing (`scripts/dv/prov-254.sh:376`).
- Units that never OTA (prov-misc, overlay-corrupt, leave-ota, …) run in a fresh process, where it is empty.
- In every REVERT unit (ac-flap, radio1off, …), `pr_wait_reverted` itself ends on a new boot by design (`:433-437`, then `pr_find`).

So when `pr_end` → `pr_restore_cycle` runs, the current boot ≠ `PR_LAND_BOOT` on essentially every unit. v2's rule then says "product rebooted the node", `pr_find`, then `pr_acquire`. That fails twice:
- `pr_find` already calls `pr_acquire` (`:243`). The second `pr_acquire` → `pr_stage` refuses an existing run dir in the same boot: `[ -e "$d" ] && { echo "FAIL $d exists"; exit 1; }` (`:193`).
- Even with a single acquire, `pr_find` in the boot that already holds this run's lease (after `pr_wait_reverted`'s own `pr_find`) hits the same "exists".

Result: NEEDS-PERSON at the end of every unit, including the ac-flap unit this PR is meant to fix. The §3.2 offline negative control (a new boot on A → "stub `pl acquire` called") does not catch this, because it has no case for "expected reboot" or "no OTA in the unit".

Also, after a recognised unexpected reboot the design says "then continue". It never says what the unit's verdict is. A unit that did not expect the product to reboot its node should not end PASS on that run.

**Fix.**
- The reference is the boot the harness last acquired its lease in. Set a host variable in `pr_acquire` (or read the `<boot>` field of `lease-prov`, `scripts/node/prov-lease-254.sh:3`); do not use `PR_LAND_BOOT`.
- On a mismatch, call only `pr_find` (it re-acquires). Do not add a second `pr_acquire`.
- The unexpected reboot is a `no` (FAIL) with the TRIAL-* line, unless the caller declared it expected. `pr_wait_reverted` updates the reference itself.
- Offline cases to add:
  - a unit without an OTA restores normally: no "product rebooted";
  - after `pr_wait_reverted`: no message;
  - a real unexpected reboot: exactly one acquire, FAIL recorded.

### MAJOR-2: The new 02 check in `pr_p9` will FAIL spuriously right after the previous unit's restore

**Scenario.**
- `pr_p9` runs first in `pr_begin` (`prov-254.sh:663`). It reaches 02 today only through 04 (`nb02`, `:655`).
- v2 adds "02 A committed with version V", which must ssh to 02 (`qp`: a single `timeout 60 ssh`, `:64`).
- `pr_begin` itself documents that right after the previous unit's restore rebooted 04, 02 is unreachable for a while. Comment at `:665-666`: 04 up 111 s, 02 unreachable for ~16 s. That is why it retries `qp` 12 × 10 s at `:667`, *after* `pr_p9`.
- A one-shot `qp` inside `pr_p9` turns that lag into "FAIL 02 not A committed ()". The unit then fails its preconditions in the release-gate full validation, and nothing would attribute the FAIL.
- "With version V": `PR_V` is set only after `pr_p9` (`:664`), so the check has no V to compare.
- The remedy text ("roll 02 to A … `batman-slot rollback` on two identical slots") tells a person to run a raw rollback with no reboot and no way to tell that the slots are identical.

**Fix.**
- Do the 02 check after the reachability retry (or give it the same retry), and compare with 04's `ver` read in the same `pr_p9`.
- "02 unreachable" is a separate FAIL text from "02 not A committed (<state>)".
- The remedy names the guarded path (`prov-bench-s0-254.sh slota 02`, which exists per `v16g4-sites.md` §3).
- Offline stub cases: unreachable for 2 reads then on A → pass; on B → FAIL with the state.

### MAJOR-3: A `host` kind in `helpers.list` breaks the firmware readers of that file, which v2 does not list

**Evidence.** `helpers.list` is read outside this repo:
- `firmware-2710/scripts/lib-wbox.sh:58`: `case "$kind" in helper|same) ;; *) … exit 1`.
- `firmware-2710/scripts/check-prov-test-gate.sh:131`: `*) fail "helpers.list helper column '$KIND' …"`.
- The wbox set builders loop over **every** row: `~/eh2-wsl21.sh:43` (`for v in $(grep -v '^#' feeds/batman/tests/wbox/helpers.list | awk '$1 != "test" {print $1}'); do build $v; done`; same in `eh2-wsl20all.sh:36`).
- The firmware's own fixture pins `misc-l38 release same` (`firmware-2710/scripts/test-prov-test-gate.sh:53`).

So the first wbox set built after this PR merges (wsl.37+) fails on the `misc-*` rows, or someone hand-filters them. That is a contract change with three readers that v2 does not name. Its §7 "misc mutants" row lists `dv-prov-tools.sh` as the only reader.

**Fix.** Pick one and state it in §7:
- (a) Keep the column values (`misc-* release same`). Let `dv-prov-tools.sh` derive every `misc-*` row on the host by its name prefix, and let the firmware keep or skip building them. No firmware change.
- (b) Move the misc mutants to their own list (`tests/wbox/misc.list`). `lint-wbox.sh` checks that file.
- (c) Change the firmware readers and the set builder in a firmware PR that is merged first.

Whichever is chosen, `lint-wbox.sh:98-107` (which derives `kind` from the patch) has to agree. Owner decision: §17.2 provenance ("taken from the -wbox payloads of rc V and nothing else", `dv-prov-tools.sh:3`) changes. Review B m3 called this the owner's call, and v2 records no decision.

### MAJOR-4: Lint pattern 2 is not specified tightly enough to implement, and its own definition misses the sites it claims

**Evidence.**
- §4.3 defines pattern 2 as a plain `reboot` / `reboot -f` / `sysrq-trigger` "inside a node command string (the `q` / `qr` / `n` / `fssh` / `ssh … '…'` argument)". It then says "This is the pattern the 16 plain sites match". But:
  - Rows 24–29 are a bare word argument to a host function: `reboot_and_wait "$n" reboot 240` (`daily-validation.sh:2322,2340,2481,2656,2667,2680`), and the default `cmd=${2:-reboot}` (`:2292`). None of them is inside a q/qr/n/fssh/ssh string.
  - Row 42 (`scripts/node/halow-fi-263.sh:28,35-37,61`) is a node script where `reboot` is a plain command, not in a string. The other `scripts/node` files are the same.
  - So the converted node-side rows (36–38, 42) and any future plain reboot under `scripts/node` are outside pattern 2.
- A line regex cannot see "inside a string":
  - multi-line strings, e.g. `chain1-254.sh:189` via `q '(…; reboot -f) …'`;
  - commands kept in variables first (`P5RO=…`, `fresh-254.sh:45`);
  - the node-side command assembled in `prov-base-254.sh:63`.
- The naive alternative is very noisy. I ran a word-bounded `reboot|sysrq-trigger` grep over the §4.3 scope at b885a2c, minus comment lines and `test-*`: **164 hits, 143 outside pattern 1**. About 120 are text: `echo` / `say` / `no` messages, suite descriptions, `log "… -> reboot"` on the same line as a real reboot (`halow-fi-263.sh:35-37`). That would mean a 100+ row allowlist, matched by substring, which hides new real lines in those files.
- So the negative control "the new lint on b885a2c FAILs and names exactly the rows that §4.2 converts" cannot be checked until the pattern exists. That is the same defect as v1's "exactly the sites of §0" (B M4.3).

**Fix.** Write the patterns down as regexes in the design, run them on b885a2c, and put the hit list in `v16g4-sites.md`. For example:
- (2a) command position: `(^|[;&|(]|&&|\|\||'|")[[:space:]]*(sync;[[:space:]]*)?(sleep [0-9]+;[[:space:]]*)?reboot( -f)?[[:space:]]*($|[;&)'"])`;
- (2b) `reboot_and_wait[[:space:]]+[^[:space:]]+[[:space:]]+(reboot|'[^']*reboot)` and `\$\{2:-reboot\}`;
- (2c) `sysrq-trigger`.

Each needs its measured false-positive list. Then generate the negative-control list from the actual b885a2c run. It should be expected to contain both kinds of FAIL lines: unguarded hits, and the lint-(2) "pinned line missing" for every new `commit_guarded` / `pre=` pin.

### MAJOR-5: Allowlisting the daily-validation `reboot_and_wait` rows (24–29) rests on a false fact and on a reason that fits one row

**Evidence.**
- "The flag is checked clear fleet-wide earlier in the same run (`trybootget-209`, `daily-validation.sh:2258`)": false. The suite runs `chk_trybootget_209 $BENCH_NODE` only (`:2258`). The destructive target is `DNODE=${DESTRUCTIVE_NODE:-$OTS_NODE}` (`:448`), which may be a different node.
- The check also runs before the reflash / FI / OTA suites and long before the tier-B reboots (`:2690-2725`). It says nothing about the flag at reboot time.
- "Run on any SoC including a Pi 3":
  - true for faketime-174 only (row 24, `:2691`);
  - guardian-192 is bcm2711-only (`:2692-2695`);
  - cleanstop / hold-274 (rows 26–29) run on the OTS tenant node, a Pi 4.
- "Converting would shift the cleanstop ≤ 90 s and k08 / k09 < 15 s timings": that applies only to a conversion to `batman-slot reboot committed` (K90batman-reboot added). A node-side DISARMED prefix in front of the **same plain `reboot`** changes no timing.

So on the actual release-gate bench (Pi 4 nodes 02 / 04), six plain reboots by the harness stay exposed to an armed tryboot. That is exactly the hazard #254 L178 names (`batman-slot:1040`).

**Fix.** Convert `reboot_and_wait`'s command, not its call sites. Prefix it on the node with the DISARMED check of `slot-guard-254.sh:33-38`:
- on bcm2711, a failed or unknown disarm = no reboot, FAIL with the line;
- on bcm2837, the plain reboot as today, documented (the Pi 3 word 5 is unproven).

Keep the `DV_TEST_NOREBOOT` / `DV_TEST_FAKETIME_NOSAVE` negative controls (`:2294`). Add a stub test (armed → no reboot). Correct the "fleet-wide" sentence. If the owner still prefers an allowlist, the reason given has to be true for each row.

### MINOR-1: Host derivation: "applies cleanly" is undefined, and today's patches apply only with an offset

All four existing misc patches were generated on `ebb9cf4b` (their header line 3). Against b885a2c's autocommit (sha `b4b6706d…`, matches the design) `patch --dry-run` gives `Hunk #2 succeeded at 441/455 (offset 39 lines)`, rc 0 (my scratch run). GNU patch also accepts fuzz 2 by default, which can put a one-line deletion in the wrong place.

Specify:
- `--fuzz=0`; offsets allowed, or regenerate the patches on b885a2c;
- the `+++` set of a misc patch is exactly `feed/batman-provision/files/usr/bin/batman-autocommit`;
- the diff of the result against the base equals the patch's -/+ lines.

Also make the mutant control a regular test: a CI loop "each `misc-*` patch makes `autocommit-mesh-arm.sh` FAIL, the real file PASSes" (claimed in that file's header `:10`, enforced nowhere; `ci.yml:123` runs only the real file). That replaces the one-time equivalence proof as the standing regression.

### MINOR-2: The `pre=` argument has no syntax, and PRE-FAILED after a partial `firstboot` is not handled

- The guard's signature is positional: `<boot8> <slot> <trial> <reason> [extra]` (`slot-guard-254.sh:54-55`). Written as `reboot_guarded … prov-dv-254 pre='firstboot -y'`, `$5` becomes the *extra condition* `{ pre=firstboot -y; }`. It runs `-y`, rc 127, and gives WRONG-STATE every time. That is fail-closed, but the row 10 unit then never works. Define the argument (e.g. a 6th positional or an option parsed before the positionals) and pin its exact text in lint (2).
- PRE-FAILED from `firstboot -y` may leave a partly wiped upper and no reboot. Say what row 10 does then: NEEDS-PERSON with what, or reboot anyway because 96 restores from p5.

### MINOR-3: The p5-restore seam and lock details

- The seam requires `id -u ≠ 0`, but the script refuses non-root at `scripts/node/prov-base-254.sh:26` before anything else. State that the root check is relaxed only under the seam.
- The negative control "main → no names" then FAILs on main for the wrong reason ("root only"), not because main lacks the naming. Make it run as root on main with `PB_P5` set, or state the control differently.
- The existing seam tests run as root (`ci.yml:138-139`, `sudo bash tests/prov-p1/prov-base-statecmp.sh`). Say that they cannot use `PB_*`.
- "Two harness dirs": `DVD=$RUNDIR-dv` (`:34`) and `RUNDIR=/tmp/run/batman` (`rundir.sh`), so both are `/tmp/run/batman-dv/`. Match on that directory plus a trailing `/`, not on an enumerated name list. Otherwise `p5h.` (`scripts/dv/prov-netupdate-254.sh:50`) is missed. It would be fail-closed, but noisy.
- Every new `die` between `lock_take` and `lock_drop` must drop the lock first. The holder is a separate process named `batman-config-save-dvhold` (`:47-55`). A dead p5-restore leaves it running, and config-save will not take over a holder whose cmdline matches (F34). Product saves are then blocked until a reboot.
- Review B m11 asked about this lock. §8 "lock left by a dead holder" answers about the lease lock instead.

### MINOR-4: The node-side dead-man conversions (rows 36–38, 42) have no behaviour test

§4.3's behaviour proof covers host sites only. Review A m6 and B m10 asked for an extracted run per node dead-man with `STUB_DISARM_FAIL`, as `test-slot-guard-254.sh` does for the chain1 dead-man. Add it: armed or unknown → no reboot, the `deadman: tryboot not cleared` line, the lease and dirty marker kept. Without it these four sites are proven only by presence.

### MINOR-5: Leaving an A trial: the outcome per caller is still not named (A m4)

- After `reboot_guarded <b> A 0` the node is on **B committed**. In `back_to_a` the post-check (`prov-254.sh:403`) then returns 1.
  - In `pr_ota_b` that is harmless: the return value is ignored and try 2 is a valid B→A OTA, an improvement for `pr_normalise`.
  - In `pr_restore_cycle` it means NEEDS-PERSON ("restore: cannot leave the trial").
- Say this per caller, and say that rolling B→A would commit the A-trial image and is deliberately not done.

### MINOR-6: The lint's text-line count, the bench state and wording

- "Plus 3 pinned text lines": pattern 1 over the new scope also hits `node/prov-p9-254.sh:54`, `node/prov-rbarm-254.sh:61`, `negctl-old-slot-254.sh:36`, `daily-validation.sh:358` and `:387` (5 new text lines; my run of the `v16g4-sites.md` regex).
- "04 on B (normalised by P9)": the normalisation is the `prov-normalise-254` suite (`daily-validation.sh:325`, `pr_normalise`), not P9.
- "02 on A ✓": give the state line, because the user rules want evidence for every conclusion.

### MINOR-7: The Pi 3 rule is applied inconsistently

§4.1 says the Pi 3 sites "stay allowlisted". But:
- Rows 11 and 12 (FI P5 on `MESH_NODE`) are converted, and per `v16g4-sites.md` §1 they can meet a Pi 3. That is consistent with the existing `rb_guarded` at `fault-injection.sh:575`, which already refuses there.
- Row 42 (`halow-fi-263.sh` on `DV_T263_NODE`, any SoC) is converted. On a Pi 3 the unknown DISARM then means the fault-injection driver stays loaded with `enable_watchdog=0` and nothing reboots.

State the Pi 3 outcome per converted row. For row 42, prefer an SoC-aware prefix (bcm2837 → plain reboot as today), as in M5.

## Lifecycle and security, re-checked

- **Downgrade of the harness against an older V:** host derivation needs the patch to apply to V's autocommit. An old V whose autocommit differs in the hunk context fails closed (M1/m1 rules). State it in §8.
- **Security:** no new privilege on the node, and the `PB_*` gating is fail-closed. The host derivation writes `$DEST/<V>/<name>/SHA256SUMS` in the same process that writes the file, so the sums only detect corruption, not a local writer, exactly as today. The real guarantee is "only bound for a dry run". That holds: prov-misc runs on A committed and only binds (`scripts/dv/prov-misc-254.sh:30`).
- **"Our own mistakes":**
  - M1 is the one that would hit the lab: every unit ends in NEEDS-PERSON.
  - M5 leaves the release-gate runner's own reboots unguarded.
  - M4 risks a lint that passes because it cannot see what it is meant to check.

## Summary

| # | Sev | One line |
|---|---|---|
| M1 | MAJOR | §3.2 compares with `PR_LAND_BOOT`: every normal restore looks like a product reboot; the double `pr_acquire` fails at `pr_stage` "exists"; the verdict after a real unexpected reboot is unstated |
| M2 | MAJOR | the 02 check in `pr_p9` runs before the documented 120 s reachability retry, and "version V" is unknown there → spurious precondition FAILs |
| M3 | MAJOR | the `host` kind breaks the firmware readers of `helpers.list` (`lib-wbox.sh:58`, `check-prov-test-gate.sh:131`, the set-build loops) |
| M4 | MAJOR | lint pattern 2 as written excludes rows 24–29 and 42; not implementable as a line regex; 143 raw hits; the "exactly" negative is unverifiable |
| M5 | MAJOR | daily-validation allowlist: `trybootget-209` checks BENCH_NODE only, earlier in the run; the Pi 3 / timing reasons fit 1–2 of 6 rows; a DISARMED prefix keeps the timings |
| m1 | MINOR | patch "cleanly" undefined (today offset 39, fuzz default 2); no standing CI control for the misc mutants |
| m2 | MINOR | `pre=` syntax undefined (would be parsed as the extra condition); PRE-FAILED after a partial wipe |
| m3 | MINOR | seam vs the root check; the control fails for the wrong reason; one dir not two; `p5h.`; config-save lock holder on new die paths |
| m4 | MINOR | node dead-man conversions have no behaviour test |
| m5 | MINOR | A-trial exit outcome per caller still unnamed |
| m6 | MINOR | 5 new text lines, not 3; "normalised by P9" wrong; bench-state evidence missing |
| m7 | MINOR | Pi 3: rows 11, 12, 42 converted despite "Pi 3 sites stay allowlisted" |
