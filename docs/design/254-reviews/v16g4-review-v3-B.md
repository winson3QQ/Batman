# v1.6 group 4 (harness PR A) design review v3 — reviewer B

Design: `docs/design/254-v16-group4.md` v3 (commit 6075463 on base main b885a2c), worktree `C:\src\Batman-g4h`, read as a
whole together with `v16g4-review-v{1,2}-{A,B}.md` and `v16g4-sites.md`.
Method: read-only `grep` / `sed` / `git show` in the worktree; read-only reads of the bench store
(`\\wsl.localhost\Ubuntu-24.04\home\yello\.batman-dv\bench\{toa,slota}.txt`), of `Desktop/Batman/v16/g4/{ota36.log,plan.md}`
and of the #254 issue body (`gh issue view 254`, read only). Scratch experiments in my scratchpad only: `git apply` of the
four misc patches onto `git show b885a2c:…/batman-autocommit` outside and inside a git work tree; the four derived mutants
and a hand-made `misc-l38r` run through `tests/prov-p1/autocommit-mesh-arm.sh`; `command -v git` in WSL. No ssh, no harness
script against a node, no repo file touched except this report. Line numbers are b885a2c.

**Verdict: REJECT (v3) — small revision, then a whole-document re-review.** No BLOCKER. Every v2 finding of mine is
addressed in substance (list below), and the per-site conversions check out against the code. Two MAJORs remain, both
in §3: the remedy that the new 02 check prints cannot be executed in the very case the lifecycle row names, and the
§3.2 negative control "on main" cannot be built as written (run naively it `dd`s as root to `/dev/mmcblk0p5` on the test
host and then reports success). Both are fixed with a paragraph each. Nine MINORs.

## v2 findings (reviewer B) — resolution check

| v2 | v3 | Status |
|---|---|---|
| M1 (§3.2 stale `PR_LAND_BOOT`, double acquire) | §3.2 product-reboot recognition removed | ✅ removed. ⚠️ the "recorded open line" does not exist yet (MINOR-8) |
| M2 (`host` kind breaks firmware readers) | list format unchanged, branch on `misc-` prefix | ✅ `dv-prov-tools.sh:47` already branches on the name; `misc-l38r release same` is what `lint-wbox.sh:98-107` derives for an autocommit-only patch |
| M3 (raw-rollback remedy, recurrence, `PR_V`) | §3.1 after the retry and after `PR_V`; remedy `slota` / `toa`; §8 row | ✅ placement and `PR_V`; ❌ the remedy is not executable (MAJOR-1) |
| M4 (derivation untested, fuzz, CI) | `git apply`, `test-derive-misc.sh` in `ci.yml` prov-p1 | ✅ — my scratch run: all four patches apply with `git apply` (offset 39, rc 0); each derived mutant FAILs `autocommit-mesh-arm.sh` (l38 2, l42 3, l43 1, l51 1 fails of 10), the real file 0 of 10; a hand-made l38r (only `pr=$(prov_read);` removed in the loop) FAILs "L38 helper comes at poll 5" with `prov=unclaimed … sleeps=60`. ⚠️ `git apply` silently skips inside a work tree (MINOR-5) |
| M5 (node dead-men untested; row 42) | extracted runs with `STUB_DISARM_FAIL`; row 42 allowlisted | ✅; ⚠️ the bt305 "next run fails its precondition" claim is false (MINOR-4) |
| M6 (rows 24–29 false premise) | `reboot_and_wait` precheck | ✅ `chk_trybootget_209`'s GET (`daily-validation.sh:740-754`) is read-only; it runs before `t0` (`:2298`); ⚠️ lint/row-30 consistency (MINOR-6) |
| m7 (`pre=`) | 6th positional, today's ordering | ✅ (`_sg_cmd` `x=${5:-true}` must map `-` to `true`, as §4.1 says) |
| m8 (seam vs root) | root kept, gated on `PROV_BASE_TEST_ROOT` + files under it | ✅ for the new code; ❌ the negative control on main (MAJOR-2) |
| m9 (lint patterns) | inventory-based lint (3) | ✅ in principle; ⚠️ substring rows without cardinality (MINOR-6) |
| m10 (prov-misc aborts mid-unit) | up-front check | ✅ (say "before `pr_begin`", so a missing tool costs no snapshot/restore) |
| m11, m12 | moot | ✅ |

## Focus checks

**(1) Converted sites.** Every cited line exists at b885a2c (`addr-defer-reconcile-254.sh:13`, `ble-254.sh:294`,
`bt-uart-305.sh:55`, `prov-254.sh:480,855`, `prov-leave-ota-254.sh:39`, `prov-lib-254.sh:99`, `prov-misc-254.sh:160`,
`prov-overlay-corrupt-254.sh:19`, `prov-overlay-wipe-254.sh:25`, `pty-commit-254.sh:40`, `fault-injection.sh:173,426`,
`node/ble-central-254.sh:102`, `node/ble-periph-254.sh:197`, `node/bt-uart-305.sh:297`). Boot sources in scope: rows 4–6,
8–10 read `boot=` from `$ST` (8 hex); rows 1, 2, 3, 7 have a full UUID (`${b0:0:8}`) and must read the slot (sites table
says so); row 13 needs the landing boot added to `ST`; rows 15/19 have `HB` / `b`. Reasons pass `_sg_cmd`'s sanitizer
(`bt305-boot-$i`, `prov-claim`). Unit assertions are unchanged: L3 keeps `prov-dv-254` (`prov-misc-254.sh:163`); rows
24–29 keep their command and timing; C2 still sends a plain `batman-slot commit` and judges `COMMITTED-BY-OPERATOR`.
SoC gating: prov units are 04-only (`pv_pre` → `is_node04`, `prov-dv-254.sh:28`; `pr_p9` MAC check); BLE tier B needs
bcm2711 (`daily-validation.sh:247-252`); bt305's node gate returns NA off bcm2711 (`node/bt-uart-305.sh:40`). **But the
claim-lock tier-B suites (rows 1, 7, 13) are not SoC-gated at all** — MINOR-2.

**(2) "pty-commit runs on DNODE0 Pi 4" / "FI C2, F1 need a tenant so OTS Pi 4".**
- pty-commit: ❌ as a code fact. `CL_B` (`daily-validation.sh:347-359`) is gated only on `--destructive` and an eth0
  carrier; `bchk_pty_commit_254` (`claim-lock-254.sh:44-46`) has no SoC or 04 check. `DNODE0=${DESTRUCTIVE_NODE:-…}`
  (`:130`) and the runner explicitly allows `DESTRUCTIVE_NODE` to be a bcm2710 (`H261` loop, `:403`). Harmless for row 13
  (`commit_guarded` has no DISARM), but the same premise is wrong for rows 1 and 7 (MINOR-2).
- FI F1 / C2: ✅. `need_tenant` (`fault-injection.sh:153-154`) FAILs before any reboot or commit on a node without the
  tenant, and the runner FAILs `ots-node-209` and skips every FI case when `OTS_SOC=bcm2710` (`daily-validation.sh:390-392`).

**(3) The 02 check.** `pr_begin` callers: 40 unit scripts (+ `eh13-pre-254.sh`); none legitimately starts with 02 off A.
Only `prov-ac-fleetchan-254.sh` and `prov-netjoin-fleet-254.sh` touch 02's slot (`grep as02|qp "$ST"`). `as02` /
`restore02` go through `pr_acquire` / `pr_restore`, never `pr_begin`, so they are unaffected; `restore02` keeps
`pr_restore_cycle`'s A-only precondition (`prov-254.sh:465`). `test-restore-254.sh:101-105` checks only the line order
"state read before snapshot" and still holds. `prov-bench-s0-254.sh` has `slota` and `toa` (`:78-80`, `:187-330`) and does
not call `pr_begin`, **but neither verb is usable in the cases the check fires** — MAJOR-1.

**(4) derive_misc.** Git exists where `dv-prov-tools.sh` runs: Git Bash (`git 2.53.0.windows.2`) and WSL (`/usr/bin/git`,
2.43.0). `.gitattributes` forces `eol=lf` for the patches (`git check-attr`: `eol: lf`), and V's file comes LF from the
squashfs, so CRLF is not an issue. `git apply` works outside a repository (scratch: rc 0, patched). CI: `prov-p1` job,
`ubuntu-latest`, next to `ci.yml:123` — fine. Firmware set builders keep reading the unchanged columns; the new
`misc-l38r` row is one more harmless build there.

**(5) Negative controls on b885a2c** — table at the end.

## Findings

### MAJOR-1 — §3.1: the remedy `slota 02, then toa 02` is refused in every case the new check fires

**Scenario (real use, the §8 row "Run start, 02 on B").** The next RC V2 is installed the way wsl.36 was: two plain
`sysupgrade -n` per node by hand (`v16/g4/ota36.log`; `plan.md` step 3). One OTA too few or too many on 02 leaves it on B
committed with V2. `prov-normalise-254` moves 04 to A (`daily-validation.sh:325`). Every prov unit now FAILs
`02 not A committed on V (…): run prov-bench-s0-254.sh slota 02, then toa 02`. The person runs it:
- `prov-bench-s0-254.sh:192`: for node 02 both verbs first require a line `node=04 <mode>=PASS v=$V` in the bench store's
  `<mode>.txt`; otherwise "`$MODE 02 runs only after $MODE 04 passed with $V`" and exit 1. The bench store today
  (`~/.batman-dv/bench/toa.txt`, `slota.txt`, read 2026-11-22) has 04 lines only for wsl.22 / wsl.24 / wsl.25 — none for
  wsl.36, and none will exist for V2.
- `toa 04` / `slota 04` cannot produce that line: they require 04 on **B** committed on V (`:194` `wait_find … "slot=B
  ver=$V trial_rc=1 "`), and 04 is on A after `pr_normalise`.
- Second case: 02 on **A** committed but on an older version (02 not upgraded). The check FAILs ("not … on V") and names
  `slota` / `toa`, which need 02 on B with V (`:194`): not applicable at all.

So the person is sent into a refusal (fail-closed, nothing written — no damage), and then has to invent the real
procedure at 3 a.m. Also: `slota` then `toa` is two OTAs into A where `toa` alone does the job (`toa` = "slota with
another last step", `:11-12`), and both need `PAY` / `PSHA` / `V` in the environment, which the message does not say.

**Evidence.** `prov-bench-s0-254.sh:78-80,192,194`; bench store contents above; `ota36.log` (02 = 10.41.85.110 ends
`active=A … trial-rc=1`, 04 = 10.41.19.24 ends on B); `plan.md` "OTA wsl.36 ✅ … 04 停在 B，02 停在 A".

**Fix.** Make the FAIL text distinguish the two states and name a path that works from them:
- 02 on B committed on V → "OTA V into 02 once more (`sysupgrade -n`, the product commits a healthy trial; as
  `ota36.log`)", or, if the bench-store route is preferred, "`toa 04` first while 04 is on B (before `prov-normalise`),
  then `toa 02`", with the env it needs.
- 02 on another version → "upgrade 02 to V first".
- Add the case to the §3.1 offline stub tests (02 `slot=B ver=V`, 02 `slot=A ver=old`: two different FAIL texts), and
  state in §8 which remedy was actually exercised on the bench (none is today).

### MAJOR-2 — §3.2: the negative control "main → no names, plain die" cannot be built; run naively it writes as root to `/dev/mmcblk0p5` on the test host and passes

**Scenario.** The §3.2 tests run as root under `PROV_BASE_TEST_ROOT` (as `tests/prov-p1/prov-base-statecmp.sh:3`). On
main the `PB_*` seams do not exist, so main's `p5-restore` (`node/prov-base-254.sh:213-223`) uses the absolute
`P5=/dev/mmcblk0p5` (`:33`) and the host's real `/proc/mounts`: `svc stop` (host has no such init scripts), `lock_take`
(test-root `RUNDIR`, works), `grep -q "^/dev/mmcblk0p5 " /proc/mounts` → false on WSL / CI → `dd if=$D/p5.img
of=/dev/mmcblk0p5 conv=fsync` as root. On WSL / a CI runner that creates a regular file in devtmpfs, the read-back sha
matches and main prints `P5-RESTORED` — the control does not FAIL, so it proves nothing. On a Linux machine with an SD
reader as `mmcblk0` it overwrites a real partition. This is exactly the v1 A-M8 hazard, moved from the new code (now
gated) into the control that runs the old code.

**Fix.** Specify the main-side control so that it is safe and actually dies on "p5 is mounted":
- run main in a private mount namespace (`unshare -m`, CI and WSL tests already run root): mount a tmpfs over `/dev`,
  create `/dev/mmcblk0p5` as a node of a loop device carrying a small ext4 image, mount it at a harness-like dir → main
  must die `FAIL p5 is mounted` with no `P5-MOUNTED` line; the new code names the mount;
- every §3.2 test refuses to start if the host's `/dev/mmcblk0p5` exists outside such a namespace;
- or, if no namespace is wanted, drop the "main" control and state the negative control as a flip of the new code
  (`PB_MOUNTS` with a `pbm.` line → the unmount branch removed by `sed` → the test FAILs), labelled as such.

### MINOR-1 — the 02 check blocks all ~40 units; only 2 need 02 on A

Only fleetchan and netjoin-fleet read or change 02's slot (see (3)). `pr_peer_after` reads `A 1` only in its WARN
branch (`prov-254.sh:608`). With the check in `pr_begin`, one 02 slip turns the whole prov block of a full validation
into "preconditions" FAILs, although most units would be valid. Either justify the global check in one line (e.g.
"mixed versions invalidate mesh results") or gate it on the units that need it (a `PR_NEED_02A=1` set before
`pr_begin` in the two scripts) and report 02's state once in `prov-normalise-254`.

### MINOR-2 — rows 1 and 7 (and 13) are not Pi 4-only units; the §4 Pi 3 rule is violated as written

`adr-reconcile-254` (row 1) and `prov-claim-254` (row 7) run on `DNODE0` without an SoC check (focus (2)). On a bcm2710
`DESTRUCTIVE_NODE` — a configuration the runner supports for `hold-261` (`daily-validation.sh:403`) — DISARM reads
`unknown` and the guard refuses: adr-reconcile FAILs with WRONG-STATE; prov-claim leaves a node whose p5 and overlay were
restored live but not rebooted (`prov-lib-254.sh:97-99`). Fail-closed, no Pi 3 on the bench (P-U14), so MINOR; but the
sentence "All of these are Pi 4-only units" is false. Fix: gate `CL_B` on `soc_of "$DNODE0" = bcm2711` (`na` otherwise,
P-U14) or state the Pi 3 outcome of rows 1 and 7; correct "pty-commit runs on DNODE0 Pi 4" to "harmless on any SoC:
`commit_guarded` has no DISARM".

### MINOR-3 — row 13: "NEEDS-PERSON with the state" has no mechanism in pty-commit, and "no boot landed" is wrong

- `pty-commit-254.sh` only prints `RESULT … FAIL` (`:41`). Nothing writes `$DIR/needs-person.txt`, which is what blocks
  later D suites on DNODE0 (`dnode_blocked`, `prov-dv-254.sh:20-24`). A held trial left behind becomes a deadline revert
  plus a `bad-slot` mark (the reason `:37-38` commits today), and the next suites run on that node. Say how the
  NEEDS-PERSON is raised (append to `$DV_DIR/needs-person.txt`, as the prov units do) and test it.
- On the `:59` path `waitboot` *did* see a new boot; only `settle` failed. Write "the landing boot was not identified".

### MINOR-4 — rows 36–38: the bt305 marker is checked by nobody, and the lease goes before the refusal

- §4.2 says a refused dead-man reboot leaves "the dirty marker … so the next run fails its precondition". True for BLE
  (`irk-exposed`, `ble-lib-254.sh:253`). False for bt305: `bt305-dirty` is read only by `role_fire_restore`
  (`node/bt-uart-305.sh:294`); `gate` (`:39-47`) and `ble_state` (`ble-lib-254.sh:250-262`) never look at it. The next
  bt305 / BLE run would measure a UART with `hci_uart-noP2` loaded or a raw-written CNTL.
- In all three dead-men `rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"` precedes the reboot (`ble-central:101`,
  `ble-periph:196`, `bt-uart-305:296`). State that the DISARMED check goes **before** the `rm`, so a refusal keeps the
  lease (the next acquire then refuses: "leftover: BLE lease", `ble-lib-254.sh:256`).
- Fix: add `mark_here bt305-dirty` to the bt305 gate (or to `ble_state`), and add both to the extracted-run cases.

### MINOR-5 — `git apply` reports success and changes nothing when run inside a git work tree

Scratch evidence: the b885a2c autocommit placed under a subdirectory of a git repo; `git apply misc-l38.patch` → rc 0,
sha unchanged (`b4b6706d…` → `b4b6706d…`); `git apply -v` prints `Skipped patch 'feed/…/batman-autocommit'.` (git
2.53.0.windows.2). If `derive_misc`'s scratch tree ever lands inside a work tree (a `TMPDIR` under a checkout, a CI temp
under `$GITHUB_WORKSPACE`), "applies" is a no-op. Today's backstops catch it (dv-prov-tools: "== release", missing
witness; CI: the unchanged file PASSes mesh-arm → "mutant passes" FAIL), so MINOR. Fix: `derive_misc` itself FAILs when
the output equals the input or lacks the witness, and runs `git apply -v` and FAILs on `Skipped patch`. Also correct
"lint-wbox.sh already recomputes them": lint-wbox recomputes the list columns and runs `git apply --check`
(`lint-wbox.sh:49`); regeneration is `tests/wbox/gen/gen.sh <tree> <out> misc-l38 …`.

### MINOR-6 — lint (3): substring rows without a count; the `prechecked` group is blind on b885a2c; row 30

- A row is "a substring of the line". With ~120 `text` rows, a short substring (`say "`, `echo "`) also accepts a new real
  `reboot` added on a matching line in the same file (v2 A M4's concern). Give each row an exact hit count (or match the
  whole trimmed line) and FAIL on any other count.
- `prechecked` = "the line is inside `reboot_and_wait` or calls it". On b885a2c those call sites look the same, so lint
  (3) passes them; the "negative control on b885a2c … checked against the guarded / prechecked rows" cannot FAIL on
  them. Pin the precheck line inside `reboot_and_wait` in lint (2), so its absence FAILs.
- Row 30 (`daily-validation.sh:2631`, `reboot_and_wait "$n" 'sync; reboot -f'`) is listed as allowlisted but goes
  through `reboot_and_wait` and is therefore prechecked too. Say which group the inventory gives it.
- Optional: do the GET and the trigger in one ssh (`<GET>=0 && <cmd>`) to drop the two-session gap; it does not move `t0`.

### MINOR-7 — §7 ownership of "02's slot" omits two harness writers

§7 says the harness writes 02's slot "through `prov-bench-s0 slota / toa` only". `prov-ac-fleetchan-254.sh` part 1
OTAs 02 into B and rolls it back with `rb_guarded` (`:33,44`), and `restore02` reboots 02 through `pr_restore_cycle`.
All run under the same host lock (`pr_lock`), so there is no conflict; list them.

### MINOR-8 — the product-revert case is not recorded in #254 yet, and its signature is hard to attribute

§"What v3 removes" says the case "is recorded as an open line in #254 L116". The #254 body read today has the L116
harness line about `pr_restore_cycle` / p5 only; no line about a held trial reverted mid-unit. Record it (routine) and
change "is recorded" to the link. Real-use note for that line: after a deadline revert `back_to_a` returns 0
("already on A", `prov-254.sh:394`); the unit then fails at `pr_lease_renew` (lease lost with tmpfs, `:219`) and ends
NEEDS-PERSON, which blocks every later DNODE suite of the night. The NEEDS-PERSON text names only the lease. Cheap
improvement, in scope or as one checklist line: on a lease-renew failure print `autocommit.log | grep TRIAL-REVERTED |
tail -1` and the boot-reasons tail, so the cause is attributable.

### MINOR-9 — stale "tests pinned to today's wording"; regression-suite wiring not stated

- §4.2 last paragraph: `test-bench-p5-254.sh:40,48`, `test-ab-selftest-254.sh:37`, `test-negctl-old-slot-254.sh:24,95`
  pin rows 11/12, 18 and 17, which v3 allowlists unchanged. Nothing there changes; the tests that do change are the
  lint (2) table and allowlist in `test-slot-guard-254.sh` (rows 13, 15 removed; `commit_guarded` added).
- Name where each new offline test runs: `test-acflap-254.sh`, the §3.1 stub, the §3.2 seam tests (root), the dead-man
  extracted runs, the `reboot_and_wait` stub, lint (3). Today `test-h4-offline-254.sh:28-30` (daily-validation
  `harness-h4-254`, `:210`) runs only bench-p5 / slot-guard / restore, and `test-slot-guard-254.sh` is not in `ci.yml`.

## Negative controls — would each fail on b885a2c?

| Claim | On b885a2c | Note |
|---|---|---|
| §1 offline `acflap_judge` | n/a (new function); synthetic cases discriminate | device: old judgement FAILed on wsl.35 ✅ |
| §2 CI `test-derive-misc` | ✅ the mutant half is real: 4/4 misc mutants FAIL mesh-arm, the real file PASSes (scratch run); l38r FAILs too | MINOR-5 backstop |
| §3.1 02 check | ✅ main `pr_begin` never reads 02's slot (`prov-254.sh:661-670`) → snapshot stub called | MAJOR-1 for the remedy text |
| §3.2 mount naming | ❌ "main → plain die" not constructible; main `dd`s to `/dev/mmcblk0p5` | MAJOR-2 |
| §4.2 host guarded sites (stub node) | ✅ main sends the bare command on another boot | — |
| `reboot_and_wait` precheck (stub `fssh`) | ✅ main triggers with the flag armed | — |
| dead-men 36–38 (`STUB_DISARM_FAIL`) | ✅ main reboots | MINOR-4 adds the bt305 marker case |
| §4.3 lint (1)–(3) | ⚠️ guarded rows FAIL; prechecked rows do not | MINOR-6 |
| §5 test-all, §6 prober | ✅ as in earlier rounds | — |

## Lifecycle and security, re-checked

- Hosts: Git Bash and WSL both have git; CRLF excluded by `.gitattributes`. ✅
- Downgrade / older V: a patch generated on a newer autocommit may not apply to V's → INVALID before any arm (with the
  up-front check). ✅ fail-closed.
- Trust: the misc mutant now comes from the harness checkout instead of a firmware build, and runs as root in a dry-run
  bind on the node. A local process able to write the checkout or `$DEST` could already change the harness scripts that
  ssh as root, so the trust level is unchanged, as §9 says. `git apply` refuses paths outside the scratch dir without
  `--unsafe-paths`, and lint-wbox (CI) limits misc patches to `batman-autocommit`. ✅
- p5 unmount: matched on the `/proc/mounts` mountpoint under `/tmp/run/batman-dv/` (root 0700, `prov-base-254.sh:34`,
  `umask 077`); a non-root process cannot add a mount there in the init namespace. ✅
- Our own mistakes: MAJOR-2 is the one that can touch a host disk; MAJOR-1 sends a person into a refusal.

## Summary

| # | Sev | Area | One line |
|---|---|---|---|
| 1 | MAJOR | §3.1 | remedy `slota 02` / `toa 02` is refused: needs a `node=04 <mode>=PASS v=V` line (none for wsl.36) and 04 on B; useless for 02 on an old version |
| 2 | MAJOR | §3.2 | "main → plain die" control not constructible; main `dd`s as root to `/dev/mmcblk0p5` on the test host and reports success |
| 3 | MINOR | §3.1 | the check blocks all ~40 units; only fleetchan / netjoin-fleet need 02 on A |
| 4 | MINOR | §4 | rows 1, 7 (and 13) run on DNODE0 with no SoC gate; "Pi 4-only" is false; gate CL_B or state the Pi 3 outcome |
| 5 | MINOR | §4.2 row 13 | pty-commit has no NEEDS-PERSON mechanism; "no boot landed" wrong |
| 6 | MINOR | §4.2 rows 36–38 | `bt305-dirty` is checked by no gate; DISARMED check must precede the lease `rm` |
| 7 | MINOR | §2 | `git apply` inside a work tree skips with rc 0; derive_misc must FAIL on output == input / `Skipped patch` |
| 8 | MINOR | §4.3 | inventory rows need exact counts; prechecked rows invisible to the lint on b885a2c; row 30 group |
| 9 | MINOR | §7 | 02-slot ownership omits fleetchan and restore02 |
| 10 | MINOR | removal note | product-revert open line not in #254 yet; NEEDS-PERSON names only the lease |
| 11 | MINOR | §4.2 / §8 | stale pinned-tests sentence; wiring of the new offline tests not stated |

(MINOR-1 … MINOR-9 in the text are rows 3 … 11 here.)
