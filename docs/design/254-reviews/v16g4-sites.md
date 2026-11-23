# v1.6 group 4 §4: every slot-changing / rebooting call site in `scripts/`, one row each

Input to the v2 of `docs/design/254-v16-group4.md` §4 (reviews `v16g4-review-v1-A.md` M3 / MINOR-5, `-B.md` MAJOR-1 /
MAJOR-2 / MAJOR-4). Tree `C:\src\Batman-g4h`, HEAD 325fad1 (= main b885a2c + the design; nothing under `scripts/` or
`feed/` differs). Method: read-only `grep` / `sed` over `scripts/` (all files, not only `*.sh`) and the product
`feed/batman-provision/files/usr/sbin/batman-slot` / `usr/lib/batman/bootfacts.sh`. Nothing was run, no node touched.
Line numbers are b885a2c.

Search patterns used (each hit read in context):
- `batman-slot["']?[[:space:]]+["']?(rollback|commit|reboot)` and `\$\{?BS\}?"?[[:space:]]+(rollback|commit|reboot)`
  (catches `"$BS" rollback` and `"$R/usr/sbin/batman-slot" commit`);
- `autocommit["']?[[:space:]]+["']?release`;
- plain reboot: `reboot`, `reboot -f`, `busybox reboot`, `(sleep 1; reboot)`, the `reboot_and_wait <node> reboot` argument form;
- `sysrq-trigger` (b = reset, c = panic → `panic=10` reset);
- variables assigned a `batman-slot` path (`BS=$R/usr/sbin/batman-slot` in rbarm / rbfix only).

## 1. The guards (scripts/dv/slot-guard-254.sh, read in full)

| Guard | Arguments | Node-side checks, in order | Action | Output |
|---|---|---|---|---|
| `rb_guarded` | `<boot8> <A\|B> <0\|1\|any> <reason> [extra]` | boot8 = `cut -c1-8 boot_id` (non-empty), `batman-slot active` = slot, `batman-slot is-trial` rc = trial (rc 2 only matches `any`); then `{ extra; } && DISARMED` | `batman-slot rollback`; on rc 0 `(batman-slot reboot committed <reason> </dev/null >/dev/null 2>&1 &)` | `SENT` / `REFUSED` (rollback rc ≠ 0, no reboot) / `WRONG-STATE boot=… active=… trial=… extra=-` (boot/slot/trial mismatch, extra not run) / `… extra=0` (extra or DISARMED false) |
| `reboot_guarded` | same | same | only the background `batman-slot reboot committed <reason>` | `SENT` / `WRONG-STATE …` |
| `release_guarded` | `<boot8> <A\|B> [wait\|nowait] [extra]` | boot, slot, trial fixed to `0`; **no DISARM** | `batman-autocommit release --wait` (or without `--wait`, then `rc=N`) | the release's own output / `WRONG-STATE …` |

Argument sanitising (`_sg_cmd`, `slot-guard-254.sh:39-43`): boot8 must be 8 lower-case hex (else never matches), slot
A|B, trial 0|1|any, reason `[A-Za-z0-9._-]+`. Every reason string named below passes (`adr-254`, `ble-254`,
`bt305-restore`, `bt305-boot-<i>`, `prov-dv-254`, `prov-claim`, `p5-ap-restore`, `p5-ap-placeholder`).

DISARM (`:30`): `vcmailbox 0x00038064 4 4 0` (clear), then GET `0x00030064`; `tryboot_flag=<n>` only when word 2 =
`0x80000000` **and** word 5 = `0x80000004` and word 6 present, else `tryboot_flag=unknown`. DISARMED (`:36`) requires
exactly `tryboot_flag=0`. It is ANDed into every `rollback` / `reboot` action (`:47`), never into release.

There is **no pre-action hook** (something to run after every check passed and before the reboot — needed by
overlay-wipe, row 10) and **no delay hook** (FI rows 11-12 today use `setsid sh -c 'sleep 2; …'`; the guard already
backgrounds the reboot with fds closed, so the delay can be dropped). There is **no `commit` action**; rows 13 / 15 need
a new `commit_guarded <boot8> <slot> 0` (`_sg_cmd` action `commit`: `batman-slot commit 2>&1`, output passed through,
no DISARM needed since nothing reboots). Lint (2)'s regex `((rb|reboot|release)_guarded|_sg_cmd)`
(`test-slot-guard-254.sh:281`) must be extended to `commit_guarded` (review B MAJOR-4.4).

Offline proof today (`test-slot-guard-254.sh`): stub node, every output above, the 2026-11-08 incident line, armed /
unanswered / error-response DISARM, busybox-ash parsing (`:166-172`). ✅ by source read; I did not run it.

### Pi 3 (bcm2710)

| Guard | Pi 3 | Evidence |
|---|---|---|
| `rb_guarded`, `reboot_guarded` | ⚠️ **unknown — fail-closed**. They need word 5 = `0x80000004` from the Pi 3 firmware. No Pi 3 GET line has ever been captured (`docs/design/254-v16-group1.md:59`: "No Pi 3 word 5 has ever been captured"; P-U14 "Pi 3 is not supported", manet03 retired). If the Pi 3 firmware answers like the Pi 4 they work; if not, DISARM prints `unknown` and every call is `WRONG-STATE … extra=0`, nothing sent. The product itself on a Pi 3 only checks word 2 (`batman-slot:433-439`) and `batman-slot reboot committed` there is always a plain reboot (`batman-slot:1039` "not a Pi 4 A/B card"). | source only; the read-only probe asked for in `v16g1-review-v1-A.md:104,192` was never run |
| `release_guarded` | ✅ by source: no DISARM; `active` / `is-trial` are layout-independent (`batman-slot:914-920`, `is_trial` reads `committed_fw`). Already used on the Pi 3 R3/R4 path (`fault-injection.sh:258,316,394`, run on `H261` = first bcm2710 node, `daily-validation.sh:406-413`). | no captured Pi 3 run of the guarded form found |
| `commit_guarded` (new) | ✅ by the same reasoning as release (no DISARM). | design only |

Sites that can meet a Pi 3 in code (none on today's bench, which is Pi 4 only): `ab-selftest.sh` (both layouts,
`:21-24`), `fault-injection.sh` P5 on `MESH_NODE` (rows 11-12, `rb_guarded` at `:575`), `daily-validation.sh` faketime /
ramoops on `DNODE` (rows 24, 32), `halow-fi-263.sh` on `DV_T263_NODE` (row 43). BLE / bt305 / OTS / claim-lock / prov
units are bcm2711-gated or 04-only (`daily-validation.sh:247,252`, `:390-392`, prov `pr_p9`).

## 2. Code sites (one row per site)

Columns: **H/N** = host-sent or node-side. **Node**: 04 = `NODE`/`DNODE0`/`BLE_PERIPH`, 02 = `PEER`/`BLE_CENTRAL`.
**State** = the node's expected state when the line runs, with the evidence line. **boot8 / slot** = what is in scope
(variable) or must be read (best in the same ssh as the boot id). **Pinned by** = a test / assertion that pins the
current text, reason or timing. **Hazard** = ordering (a destructive step before the reboot, a delayed reboot, an
unchecked empty boot id). **Rec.** = recommendation.

### 2a. Host-sent `batman-slot reboot committed` (design §0 list; all 12 confirmed at these lines)

| # | Site | Node | State (evidence) | boot8 / slot | Pinned by | Hazard | Rec. |
|---|---|---|---|---|---|---|---|
| 1 | `dv/addr-defer-reconcile-254.sh:13` (`reboot_c`, called twice `:29`) | 04 (`DNODE0`, `daily-validation.sh:356`) | committed, **either slot** (`:30` checks only `is-trial` rc 1; after pty-commit the node may be on B) | `b0=$(bid)` full UUID → `${b0:0:8}`; slot **not in scope** (read `batman-slot active` with the boot id) | — | `bid` empty → `b0=""`, then `[ "$b" != "$b0" ]` passes on the first answer: a "reboot" is accepted with no proof. The guard fixes it (empty boot = WRONG-STATE). File does not source slot-guard. | `reboot_guarded "${b0:0:8}" "$sl" 1 adr-254`; non-SENT → `no` + return 1 |
| 2 | `dv/ble-254.sh:294` (`ble_reboot_committed`; callers `:207` and `:262` = 02, `:263` and `:313` = 04) | 02 and 04 | committed, slot not asserted anywhere in ble-254 (no `is-trial` in `dv/ble-254.sh`, `node/ble-*.sh`); BLE tier B runs before any slot-switching suite (`daily-validation.sh:245`) | `b0` full UUID read at `:290` (checked `????????-*` at `:293`) → `${b0:0:8}`; slot must be read in the same ssh | — (reason `ble-254` asserted nowhere) | the command is single-quoted (`'batman-slot …'`), must become the generated string; `sleep 20` after it stays. Reboot purpose is security (void the IRK): a refusal must keep `irk-exposed` (tmpfs mark, `ble-lib-254.sh:253` fails the next preflight on it) | `reboot_guarded "${b0:0:8}" "$sl" 1 ble-254`. Trial 1, not `any`: these suites never run in a trial, so a trial is an unexpected state to stop and name; the IRK mark keeps the consequence visible. (`any` is defensible — DISARMED still holds — if the owner prefers "always get a new boot".) |
| 3 | `dv/bt-uart-305.sh:55` (`bt305_reboot`; callers `:73` restore after NEEDS-REBOOT, `:106` T4 loop ×`BT305_BOOTS`) | 04 (`BLE_PERIPH`) for T2/T3b/T4; 02 or 04 (`BLE_A_NODES`) for the T3 rebind restore | committed; header says "back onto the committed slot" (`:51`); not asserted | `b0` full UUID `:54` → `${b0:0:8}`; slot must be read | — | `b0` never checked non-empty (`:54`): empty → no reboot proof (same as row 1). Reboot result is discarded (`>/dev/null 2>&1`). | `reboot_guarded "${b0:0:8}" "$sl" 1 "$2"`; read b0+slot in one ssh, `[ "$o" = SENT ]` |
| 4 | `dv/prov-254.sh:480` (`pr_restore_cycle`) | 04; also 02 via `restore02` (`prov-netjoin-fleet-254.sh:76`) | today: A committed only (`:465`); design §3: the snapshot slot `want`, committed | `b0=$(field "$s" boot)` 8 hex ✓; slot: `want` (design) / `field "$s" slot` ✓ | prov-misc L3 is a different site; none here | p5-restore **and** overlay-restore are already done on the live system (`:470-473`) before the reboot: a refusal leaves a restored-but-not-rebooted node → must be NEEDS-PERSON (fail-closed, acceptable; say so) | `reboot_guarded "$b0" "$want" 1 prov-dv-254` (design §3) |
| 5 | `dv/prov-254.sh:855` (`pr_member`; 11 callers, e.g. `prov-ota-254.sh:19`, `prov-netupdate-254.sh:43,84,101`) | 04 | A committed: `pr_p9` at `pr_begin` (`:642` "FAIL 04 not A committed"); later calls follow a `pr_restore` that ends A committed (`:465`) or `back_to_a` | `b0` ✓ (`:854`); slot `field "$s" slot` ✓ | — | the join (member state) is done before the reboot; a refusal → `return 1` → caller's `pr_abort` restores | `reboot_guarded "$b0" A 1 prov-dv-254` |
| 6 | `dv/prov-leave-ota-254.sh:39` | 04 | A committed (half 1 after `pr_begin`; half 2 after `pr_restore` `:56`) | `s`, `b0` ✓ (`:38`) | — | after `leave` (network forgotten, radio1 blocked); refusal → `return 1` → abort/restore | `reboot_guarded "$b0" A 1 prov-dv-254` |
| 7 | `dv/prov-lib-254.sh:99` (`pl_restore`; used by `prov-claim-254.sh`, `PL_NAME=prov-claim`) | 04 (`DNODE0`) | committed **either slot** (`:74` `trial=1 state=legacy`) | `b0=$(bid)` full UUID → `${b0:0:8}`; slot: `pl_prep`'s global `$s` holds `slot=` but is stale by then — read again | — | p5 + overlay restore done before (`:97-98`), node is LOCKED (publickey only, `:96`); `waitboot "$b0"` with empty `b0` returns at once (no proof). prov-lib does not source slot-guard (prov-claim sources only prov-lib, `prov-claim-254.sh:12`) | `reboot_guarded "${b0:0:8}" "$sl" 1 "$PL_NAME"` + source slot-guard |
| 8 | `dv/prov-misc-254.sh:160` (L3) | 04 | A committed (no OTA in prov-misc; `pr_begin` `:166`) | `o`, `b0` ✓ (`:159`); slot `field "$o" slot` | **yes**: `:163` asserts `prev=CLEAN … trigger=prov-dv-254` in boot-reasons → the reason string must stay `prov-dv-254` (the guard keeps it: same `batman-slot reboot committed <reason>`) | none | `reboot_guarded "$b0" A 1 prov-dv-254` |
| 9 | `dv/prov-overlay-corrupt-254.sh:19` | 04 | A committed (`pr_begin` `:15`) | `s`, `b0` ✓ | — | garbage written over A's `prov.cbor` just before (`:18`); refusal → `pr_abort` → restore | `reboot_guarded "$b0" A 1 prov-dv-254` |
| 10 | `dv/prov-overlay-wipe-254.sh:25` | 04 | A committed, claimed (`:15-16`) | `s`, `b0` ✓ (`:24`) | — | **`firstboot -y` in the same command before the reboot** (review B MAJOR-2): `firstboot -y; <guard>` would wipe the upper and then refuse → wiped, unrebooted, maybe unreachable node. `firstboot` cannot be the extra condition (it runs before DISARMED). | `reboot_guarded "$b0" A 1 prov-dv-254` **with a new pre-action argument** run only after every check: `… then firstboot -y >/dev/null 2>&1; (batman-slot reboot …&); echo SENT`. Offline test: `STUB_DISARM_FAIL=y` → firstboot not run |
| 11 | `fault-injection.sh:462` (`p5_ap_back`, trial branch) | `MESH_NODE` (02 or 04; lab default `daily-validation.sh:2236`) | **an uncommitted trial** (`:459` `committed; it=$?` → `it=1`); the reboot leaves it via the one-shot tryboot | `b2` full UUID `:461` → `${b2:0:8}`; slot `s` ✓ (`:459`, the trial slot) | **`scripts/dv/test-bench-p5-254.sh`** stubs `n` (`:40`, prints nothing) and `bootid` = `b1` (`:48`): a guarded form needs the stub to answer `SENT` and a hex boot id | `setsid sh -c 'sleep 2; …'` (delay; drop it); refusal → `p5_person` | `reboot_guarded "${b2:0:8}" "$s" 0 p5-ap-restore` (review B MAJOR-1: trial **0**; trial 1 would always refuse) |
| 12 | `fault-injection.sh:503` (`p5_ap_back`, placeholder branch) | `MESH_NODE` | committed on the baseline slot `$3` (`:466` `[ "$it" = 0 ] && [ "$s" = "$3" ]`) | `b2` full UUID `:502` → `${b2:0:8}`; slot `$3` ✓ | `test-bench-p5-254.sh` (as row 11) | placeholder + keyguard block written and saved (`:477-489`, `save_rc=0` checked `:500`) before the reboot; the reboot only confirms keyguard at boot. Refusal → `p5_person`. `sleep 2` delay (drop). | `reboot_guarded "${b2:0:8}" "$3" 1 p5-ap-placeholder` |

### 2b. Host-sent commit / rollback outside the guards

| # | Site | Node | State (evidence) | boot8 / slot | Pinned by | Hazard | Rec. |
|---|---|---|---|---|---|---|---|
| 13 | `dv/pty-commit-254.sh:40` (`stop()` after landing) | 04 (`DNODE0`, `daily-validation.sh:358`) | held trial on `TGT` (`:58-59` landing case, `LANDED=1`); also reached from `:56` (settle failed) **before any state line of the landed boot** | slot `TGT` ✓ (`:45`); **no boot**: `ST` here has no `boot=` field (`:26`), `waitboot` does not keep the new id | `test-slot-guard-254.sh:239` allowlist row (must be removed, review A MINOR-5d) | `is-trial && commit` is checked in the same command but not bound to a boot; reachable from the trap (`:42`) | **`commit_guarded <b8> "$TGT" 0`** with the boot recorded at landing (add `boot=` to `ST`, keep it in `LB`); on the `:56` path read it in `stop()` (review B MINOR-5) |
| 14 | `dv/pty-commit-254.sh:84` | 04 | held trial on `TGT` (`:58`) | `TGT` ✓; no boot | allowlist `test-slot-guard-254.sh:237`; the assertion `:87` reads the commit's own output "committed slot $TGT as default" | none (the command under test) | **allowlist** (reason: the bare `ssh -tt … batman-slot commit` from a PTY is what #254 B12-m4 tests; wrapping it in `sh -c` + checks changes the PTY/setsid case under test). Optionally a boot check in a separate ssh just before (logged, not binding) |
| 15 | `fault-injection.sh:426` (C2) | OTS_NODE (04-class Pi 4; `need_tenant`) | held trial on `tr`, boot `HB` (`:421` `held_trial`) | `${HB:0:8}`, `$tr` ✓ (already used by release_guarded `:258`) | allowlist `test-slot-guard-254.sh:240` ("the command under test"); the judgement reads `COMMITTED-BY-OPERATOR` in autocommit.log (`:443`) | none | **`commit_guarded "${HB:0:8}" "$tr" 0`** (the product sees the same `batman-slot commit`; C2 tests that the commit *stands*, not how it was typed) — or keep the allowlist if the owner wants the literal operator command |
| 16 | `ab-selftest.sh:370` (`sshn 'batman-slot rollback'`, unexpected "B booted and committed") | `BENCH_NODE` (Pi 3 or Pi 4, `:21-24`) | committed on B — an error path (`:367` checks `is-trial` in a *separate* ssh) | `S=$(slot)` = B; boot: `BID0` is the pre-reboot id (stale) → must read | `test-ab-selftest-254.sh` stubs commands by text | rollback then `rb plain` (`:372`) = plain reboot `:121` | **allowlist** (review/design: the A/B self-test owns its node and its tryboot; Pi 3 layout where DISARM is unverified). Cheap improvement: put the `is-trial` check in the same ssh as the rollback |
| 17 | `negctl-old-slot-254.sh:33` (rollback + `reboot committed negctl-254` in one node-side command) | the BLE node (04) | held trial on B of an OLD build (`:2-10`) | `b0=$(bootid)` full; slot checked node-side (`= B`) | `test-negctl-old-slot-254.sh:24,95` match `batman-slot rollback` / `ROLLBACK-RC=` | rc-14 retry ×5 node-side (old pre-S5 `batman-slot`); no boot binding, no DISARM | **allowlist** (one-off PR evidence tool, not in daily-validation `:4`; slot-checked in the same command; the retry loop cannot be expressed through `rb_guarded`, which answers REFUSED on rc 14). Residual: no boot bind, no disarm — say so |

### 2c. Host-sent plain `reboot` / `reboot -f` / sysrq

| # | Site | Node | State (evidence) | boot8 / slot | Pinned by | Hazard | Rec. |
|---|---|---|---|---|---|---|---|
| 18 | `ab-selftest.sh:121` (`reboot_wait`: `(sleep 1; reboot)`, after `vcmailbox … 1` in tryboot mode `:120`) | `BENCH_NODE` (Pi 3/4) | tryboot mode: committed A, flag armed on purpose; plain mode: committed (after a fallback / rollback) | `before` full UUID ✓; slot not | `test-ab-selftest-254.sh:37` matches the literal `'(sleep 1; reboot)'` | delayed `sleep 1` | **allowlist** (tryboot mode is the intended entry into an armed tryboot; plain mode exercises the plain-reboot path the self-test checks; Pi 3 support) |
| 19 | `fault-injection.sh:173` (F1, `n 'sync; reboot'` ×3) | OTS_NODE (Pi 4) | committed (`:590` WARN only; FI assumes a committed start) | `b` full ✓ (`:172`, checked non-empty); slot via `slot()` | — | none (decoy tar planted before, wanted across the reboot) | **`reboot_guarded "${b:0:8}" "$(slot)" 1 fi-f1`**: F1 tests the firstload quarantine across a clean reboot; `batman-slot reboot committed` does the same procd shutdown and avoids the Pi 4 partition-walk of a plain reboot (`batman-slot:1027-1031`) |
| 20 | `dv/chain1-254.sh:189` (`reboot -f` after dockerd stop) | 04 | A committed with a tryboot armed by `apply` just before (`:186` "armed as one-shot tryboot") | `B0` 8 hex ✓ (`:188`) | the 150 s landing assertions `:191-193` | `sleep 1; reboot -f` | **allowlist**: intentional entry into the armed tryboot (DISARMED would defeat it). Option for v2: a guard action `enter` that requires boot + A committed + `tryboot_flag=1` |
| 21 | `dv/prov-bench-s0-254.sh:425` | 04 | same as 20 (`:423` apply armed) | `B0` ✓ (`:424`) | landing `:426-428` | same | **allowlist** (as 20) |
| 22 | `dv/prov-chain0-254.sh:68` (`(sync; reboot)`) | 04 | A committed, bypass trial armed (`:59`) | `b0` ✓ (`:67`) | bypass assertions `:70-80` | none | **allowlist** (as 20) |
| 23 | `dv/prov-ac-noarm-254.sh:37` | 04 | A committed (after `pr_member`), tryboot armed (`:33`) | `b0` ✓ (`:36`) | landing `:40-41` | none | **allowlist** (as 20) |
| 24 | `daily-validation.sh:2322` (faketime-174, `reboot_and_wait "$n" reboot`) | `DNODE` (`DESTRUCTIVE_NODE`/`OTS_NODE`, `:448`); **can be a Pi 3** (`:2691` not SoC-gated) | committed (fleet check `autocommit-211` `:2253`; flag clear check `chk_trybootget_209` `:754`) | `b0` full inside `reboot_and_wait` (`:2293`); slot must be read | `DV_TEST_NOREBOOT=1` (`:2294`) and `DV_TEST_FAKETIME_NOSAVE` negative controls must keep working | `reboot_and_wait` discards the command's output (`:2300`): a guarded form needs a variant that captures and checks `SENT` | **`reboot_guarded <b8> <sl> 1 dv-174`** via a `reboot_and_wait_guarded` variant (sources slot-guard). On a Pi 3 DNODE this refuses (DISARM unverified) → FAIL with the WRONG-STATE line; state that |
| 25 | `daily-validation.sh:2340` (guardian-192) | `DNODE`, bcm2711 only (`:2692-2695`) | committed | as 24 | as 24 | overlay guardian removed before the reboot (`:2339`) | **`reboot_guarded`** trial 1, as 24 |
| 26 | `daily-validation.sh:2481` (cleanstop-274) | OTS_NODE (Pi 4) | committed | as 24 | **timing**: "boot-to-ready <= 90 s" and the stop record (`:2723` suite text, `:2445-2450`) | none | **`reboot_guarded`** trial 1. Note: the explicit restart adds `K90batman-reboot` after the K08/K09 stop tiers; the asserted stop timings are measured before it, boot-to-ready after → re-baseline once |
| 27 | `daily-validation.sh:2656` (hold-274 reboot 1) | OTS_NODE | committed | as 24 | — | bad tar planted before (`:2655`) — intended | **`reboot_guarded`** trial 1 |
| 28 | `daily-validation.sh:2667` (hold-274 reboot 2, "during the hold") | OTS_NODE | committed (the "hold" is the firstload hold, not an A/B hold) | as 24; `pb` = boot8 ✓ (`:2666`) | **timing**: k08 / k09 each < 15 s (`:2672`) | — | **`reboot_guarded`** trial 1 (same caveat as 26) |
| 29 | `daily-validation.sh:2680` (hold-274 cleanup) | OTS_NODE | committed | as 24 | — | — | **`reboot_guarded`** trial 1 |
| 30 | `daily-validation.sh:2631` (unclean-boot-274, `'sync; reboot -f'`) | OTS_NODE | committed | `b0` 8 ✓ (`:2630`) | the suite asserts "as on power loss" behaviour | — | **allowlist** (deliberate power-loss proxy: no K scripts). Optional: prefix a DISARMED check — `reboot -f` honours an armed flag, a real power cut does not |
| 31 | `daily-validation.sh:2355` (ramoops-173, sysrq `c` → panic → `panic=10` reset) | `DNODE` (Pi 3 possible) | committed | in `reboot_and_wait` | the suite asserts PANIC classification | — | **allowlist** (deliberate panic). Same optional DISARMED prefix |
| 32 | `dv/prov-base-254.sh:63` (sysrq `b` while the p5 `dd` runs) | 04 | A committed (`pr_begin`), inside a restore | `b0` ✓ (`:60`) | `:65-68` (INVALID if dd finished; boot-reasons shows sysrq) | the p5 write is cut on purpose | **allowlist** (deliberate power-loss proxy). Note: sysrq-b is a reset, so an armed tryboot *would* be taken, unlike a power cut; a DISARMED prefix would make it closer to a real cut |
| 33 | `dv/prov-sshkeys-cut-254.sh:105` (sysrq `b` from the node-side `batman-config-save` wrapper) | 04 | A committed, member/claim flow (`pr_begin`) | node-side, same boot | `:150-152` (dv-cut log line, boot-reasons UNCLEAN sysrq) | — | **allowlist** (as 32) |

### 2d. Node-side

| # | Site | Node | State (evidence) | Pinned by | Hazard | Rec. |
|---|---|---|---|---|---|---|
| 34 | `dv/chain1-254.sh:153` (dead-man `batman-slot rollback`, written by the host as `ch1-deadman.sh`) | 04 | slot B, held fresh trial or B (`:134` acts only when active = B) | `test-slot-guard-254.sh:135-151` extracted run incl. `STUB_DISARM_FAIL`; allowlist `:231` | p5-restore first (`:146-148`), disarm + `bf_get` = 0 required (`:151-152`) | **allowlist** (as today; already disarm-checked and tested) |
| 35 | `dv/chain1-254.sh:156` (dead-man `batman-slot reboot committed ch1-deadman`) | 04 | after the rollback above (runs even when rollback rc ≠ 0 — on a trial the one-shot tryboot still returns to A) | same extracted test | the disarm at `:151-152` precedes it in the same script | **allowlist** (new regex hits it; reason: same script, after the disarm check) |
| 36 | `node/ble-central-254.sh:102` (02 dead-man, IRK exposed) | 02 | committed (BLE never runs in a trial, row 2) | none | `rm -f "$BT/lease" …` **before** the reboot (`:101`): a refused reboot leaves no lease; `irk-exposed` (tmpfs) stays and fails the next preflight (`ble-lib-254.sh:253`) | **node-side DISARMED prefix** (design §4.2): disarm + `bf_get` = 0, else log NEEDS-PERSON and keep the lease file; one shared helper for 36-38 (+43), extracted-run test with `STUB_DISARM_FAIL` like `:147` |
| 37 | `node/ble-periph-254.sh:197` (04 dead-man) | 04 | committed | none | same (`:196`) | **node-side DISARMED prefix** |
| 38 | `node/bt-uart-305.sh:297` (bt305 dead-man, `bt305-dirty`) | 02/04 (bcm2711) | committed | none | same (`:296`); the dirty UART stays until a reboot | **node-side DISARMED prefix** |
| 39 | `node/prov-rbarm-254.sh:48` (`o=$("$BS" rollback 2>&1)`) | 04 | A committed, B = the wbox (`:30-35`, INVALID otherwise) | `prov-wbox-nocommit-254.sh` judges RESULT | the rollback is expected to be *refused* (the wbox gate) | **allowlist** (the command under test; preconditions checked in-process, same boot, no reboot follows) |
| 40 | `node/prov-rbarm-254.sh:54` (`"$R/usr/sbin/batman-slot" commit` ×3) | 04 | A committed, only after an accepted rollback or a moved `[all]` (`:52`) | RESULT lines | recovery; "do NOT reboot" (`:61`) | **allowlist** (recovery on the running committed slot, same process) |
| 41 | `node/prov-rbfix-254.sh:24` (commit ×3) | 04 | A, same boot as the arm (`:18` boot8 compared), no batman-slot running (`:19-22`) | RESULT lines | — | **allowlist** (already boot-bound node-side) |
| 42 | `node/halow-fi-263.sh:28,35,36,37,62` (plain `reboot`: trap, rmmod/insmod failures, end) | `DV_T263_NODE` (any SoC) | committed (not checked; joinwatch stopped `:31`) | `daily-validation.sh:851-866` waits for a new boot | the stock driver is removed before (`:35`); the reboot is the recovery | **node-side DISARMED prefix** + `batman-slot reboot committed fi-263` (plain reboot on a Pi 4 may walk to the wrong partition); a refusal leaves the FI module loaded → log + the host's "did not reboot within 15 min — check it by hand" (`:866`) is the person path. Or allowlist with that reason (#263, outside #254) |

## 3. Already guarded (for completeness; the lint (2) table `test-slot-guard-254.sh:256-279`)

All 23 pinned lines exist. Node and Pi 3 status:

| Site | Guard | Node | Pi 3 |
|---|---|---|---|
| `dv/brewrite-254.sh` `rb_guarded "${b0:0:8}" B any e3-254` | rb | 04 | n/a (04) |
| `dv/chain1-254.sh` `rb_guarded "$BA" A 0 ch1-b` ×2, `release_guarded "$BT" B` | rb, release | 04 | n/a |
| `dv/fresh-254.sh` `rb_guarded … ch1-restore`, `reboot_guarded "$b" "$sl" 0`, `reboot_guarded "$b" A 1` | rb, reboot | 04 | n/a |
| `dv/prov-254.sh` `rb_guarded "$b0" B any` (`back_to_a` `:401`), `release_guarded "$rb0" A` | rb, release | 04 (02 via `as02`) | n/a |
| `dv/prov-ac-fleetchan-254.sh:44` `rb_guarded "$b0" B any` | rb | **02** | n/a |
| `dv/prov-bench-s0-254.sh` rb ×1, reboot ×2, release ×2 | rb, reboot, release | 04 or 02 (`slota 02`) | n/a |
| `dv/prov-chain0-254.sh` rb + reboot on REFUSED | rb, reboot | 04 | n/a |
| `dv/prov-legacy-upgrade-254.sh` `release_guarded "$rb0" "$1" nowait` | release | 04 | n/a |
| `dv/prov-wbox-nocommit-254.sh:47` `rb_guarded "$b0" B any` | rb | 04 | n/a |
| `fault-injection.sh:258,316,394` `release_guarded "${HB:0:8}" "$tr" …` | release | OTS_NODE, **H261 = a Pi 3** (R3/R4) | ✅ by source (no DISARM) |
| `fault-injection.sh:575` `rb_guarded "${b1:0:8}" B 1 p5-back-to-A` | rb | MESH_NODE | ⚠️ refuses if DISARM is `unknown` |

Design §3 / review B MINOR-6 change `back_to_a`'s A-trial handling; for leaving an **uncommitted** trial
`reboot_guarded <b> <trial slot> 0` is the simpler product-defined exit (one-shot tryboot, `slot-guard-254.sh:12-14`) and
avoids `rollback_lock_gate` (`batman-slot:994-1006`); if `rb_guarded` is kept, REFUSED must fall back to it, as
`prov-chain0-254.sh:85-86` does.

## 4. Excluded: comments and pure text (the extended lint must allowlist or skip these)

Comments (`#` lines): `dv/addr-defer-reconcile-254.sh:5`; `dv/prov-254.sh:325,842,867,869`;
`dv/prov-bench-s0-254.sh:13,15,23,73`; `dv/prov-wbox-nocommit-254.sh:8,9,12,14`; `dv/pty-commit-254.sh:2,5,10`;
`dv/setsid-race-254.sh:3`; `fault-injection.sh:24,28,414`; `lib/wbox-stamp.sh:4`; `node/fw-boot-254.sh:40`;
`node/prov-rbarm-254.sh:11`; `node/prov-rbfix-254.sh:7`.

Text inside code (not executed as a command; a line-based lint sees them):
- `dv/prov-254.sh:385` — `pr_needs_person "… run: batman-slot rollback; batman-slot reboot committed"` (allowlisted today `:234`);
- `dv/prov-bench-s0-254.sh:300` — `RESULT="FAIL … (back to B: batman-slot rollback; …)"` (allowlisted `:232`);
- `dv/prov-wbox-nocommit-254.sh:48` — NEEDS-PERSON text (allowlisted `:233`);
- `dv/pty-commit-254.sh:82` — `say "sleep 90 | ssh -tt … batman-slot commit"` (allowlisted `:238`);
- `fault-injection.sh:116` (NOTE), `:288` (`HELDWHY=` product log text), `:415` (C2 title) (allowlisted `:235,236,241`);
- `negctl-old-slot-254.sh:36` — `say "FAIL batman-slot rollback refused …"`;
- `node/prov-p9-254.sh:54` — `no "… on the release slot run: batman-slot commit"`;
- `node/prov-rbarm-254.sh:61` — `r "FAIL-NEEDS-PERSON … /usr/sbin/batman-slot commit; do NOT reboot …"`;
- `daily-validation.sh:358,387` (suite descriptions), and every `echo "… reboot …"` line in daily-validation / ble / bt305
  (e.g. `ble-254.sh:285,296`, `daily-validation.sh:787,2634,2640,2643,2724`);
- `node/halow-fi-263.sh:28,35-37,60` contain `log "… -> reboot"` text **and** a real `reboot` on the same line (row 42).

Out of scope, stated so the lint does not flag them:
- OTA reboots by the product (`sysupgrade -n` / `-F`: `prov-254.sh:372`, `brewrite-254.sh:27`, `chain1-254.sh:249,261,301`,
  `pty-commit-254.sh:56`, `prov-ac-fleetchan-254.sh:33`, `daily-validation.sh:2097`): the product's stage 2 owns that
  reboot and the arm.
- `pr_killpoint` (`prov-254.sh:906-933`): the sysrq is fired by the product's wbox helper, not the harness.
- `dv/eeprom-sbx-254.sh:106`, `dv-sbx.sh:110`: `reboot -f` inside a sandbox on the host, asserted NOT to reboot.
- `e0/reboot-part.c`, `e0/README.md`: a standalone E0 tool, not called by any script.
- `test-*.sh` files (stubs that match the strings above).

## 5. What the lint has to see (consequence for §4.4)

- Today's lint (1) regex (`test-slot-guard-254.sh:244`) misses rows 1-12 (no `reboot`), 39-41 (quote after the name /
  `"$BS"`), and every plain reboot / sysrq (18-33, 42). Its scope (`:224`) misses `scripts/node`, `ab-selftest.sh`,
  `negctl-old-slot-254.sh`, `daily-validation.sh`.
- A plain-reboot pattern must also catch the bare argument form `reboot_and_wait "$n" reboot 240` (rows 24-29) and the
  function default `cmd=${2:-reboot}` (`daily-validation.sh:2292`).
- New allowlist rows (with reasons as in the Rec. column): 14, 16, 17, 18, 20-23, 30-35, 39-41 (+42 if not converted),
  plus the text lines of §4 that the wider regex newly hits (`prov-p9:54`, `rbarm:61`, `negctl:36`, the
  daily-validation descriptions).
- Rows removed from today's allowlist: `pty-commit-254.sh:40` (`:239`) and `fault-injection.sh:426` (`:240`) once they
  become `commit_guarded`; otherwise lint (1) FAILs "allowlist entry no longer found".
- Tests that pin today's text and must change with the conversion: `test-bench-p5-254.sh:40,48` (rows 11-12),
  `test-ab-selftest-254.sh:37` (row 18, only if converted), `test-negctl-old-slot-254.sh:24,95` (row 17, only if
  converted). prov-misc L3 (`prov-misc-254.sh:163`) pins the reason `prov-dv-254` (row 8, kept). Timing-asserting
  suites touched: rows 26 and 28.

## Summary

42 code rows (row 42 covers 5 lines of one node script; row 2 is one function with 4 callers on 02 and 04). Recommended:
**`reboot_guarded` 19** (rows 1-12 and 19 with trial 1 except **row 11 = trial 0**, row 10 additionally needs a new
pre-action hook for `firstboot -y`, and rows 24-29 need a `reboot_and_wait` variant that checks `SENT`); **new
`commit_guarded` 2** (rows 13, 15; row 13 needs the landing boot recorded); **`rb_guarded` 0** new (all existing rollbacks
are already guarded or allowlisted); **node-side DISARMED prefix 4** (rows 36-38 and 42); **allowlist with reason 17**
(rows 14, 16, 17, 18, 20-23, 30-35, 39-41: intentional tryboot entries, deliberate power-loss / panic proxies, commands
under test, the A/B self-test, the one-off negctl tool, and node-side recovery that is already disarm- or boot-checked).
On a Pi 3, `rb_guarded` / `reboot_guarded` are unverified and fail closed (word 5 never captured on a Pi 3), while
`release_guarded` and a `commit_guarded` work by source; the Pi-3-reachable sites are ab-selftest, FI P5, the faketime /
ramoops DNODE suites and halow-fi-263, none on today's Pi-4-only bench.
