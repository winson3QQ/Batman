# v1.6 group 4 (harness PR A) design review v2 — reviewer B

Design: `docs/design/254-v16-group4.md` v2 (commit d1a60cd on base main b885a2c), worktree `C:\src\Batman-g4h`, read as a
whole; round-1 reports `v16g4-review-v1-{A,B}.md`, per-site facts `v16g4-sites.md`.
Method: read-only `grep` / `sed` / `git show` in the worktree; read-only reads of the firmware checkout the wsl.36 build
pins (`\\wsl.localhost\Ubuntu-24.04\home\yello\firmware-2710`, HEAD 302c80b1 "pin(#254): Batman main b885a2c — 1.5.14-wsl.36")
and of the host-local set builder `~/eh2-wsl21.sh`. One scratch experiment: `patch --dry-run` of the four misc patches
against a copy of `git show b885a2c:…/batman-autocommit` in my scratchpad (no repo file touched). No ssh, no harness run,
no node touched. Line numbers are b885a2c.

**Verdict: REJECT (v2).** The direction is right and most round-1 findings are genuinely closed (list below). But v2
introduces a §3.2 rule that, as written, misfires in `pr_restore_cycle` of every REVERT unit — including the new ac-flap
this PR delivers — and its re-acquire step cannot succeed as specified; and §2's new `host` kind breaks a cross-repo
contract the firmware enforces. With the other MAJORs (02 remedy / recurrence, derivation untested, node dead-men
untested, a false allowlist premise) a v3 and a whole-document re-review are needed. No BLOCKER.

## Round-1 dispositions checked (✅ = resolved as stated, with evidence)

- ✅ B M1 (FI :462 in a trial): row 11 uses trial `0`; `fault-injection.sh:458-462` (`committed; it=$?`, `it=1` = trial).
- ✅ B M3 / A M7 (p5 unmount premise): every harness p5 mountpoint is `mktemp -d /tmp/run/batman-dv/<pfx>.XXXXXX`
  (`fresh-254.sh:45` ch1, `prov-base-254.sh:27` pbm, `prov-downgrade*-254.sh` p5d, `prov-lib-254.sh:68` /
  `prov-lock-failsecure-254.sh:18` p5s, `prov-overlay-wipe-254.sh:21` / `prov-sshkeys-cut-254.sh:57` p5k, node
  `prov-base-254.sh:95,270` p5ro/p5w under `$DVD` = `$RUNDIR-dv` = the same `/tmp/run/batman-dv`). Product mounts are
  never touched. (Small text point: §3.3 speaks of "two harness dirs"; it is one.)
- ✅ A M4 (tautological l38 control): `tests/prov-p1/autocommit-mesh-arm.sh:32` ("L38 helper comes at poll 5", expects
  `sleeps=5`, not `prov=unclaimed`) runs the real block; with only `pr=$(prov_read);` removed the loop never sees the
  helper line → `sleeps=60`, `prov=unclaimed` → the case FAILs. It discriminates.
- ✅ A M6 / B m3: moot (no re-pin).
- ✅ B M6 / A M5 in their original form (wbox payload missing on wsl.36) — replaced by host derivation; but see MAJOR-3,
  MAJOR-4, MINOR-4 for what that derivation now needs.
- ✅ A m1/m2, B m1 (ac-flap judge + offline cases), A m3/B m2 (E-H5 #2 moved), A m5/B m5 (pty-commit without a boot →
  no commit), A m7/B m8 (DISARM second writer stated), B m4 (shared prober helper), B m9 Pi 3 wording (but see MAJOR-6).
- ✅ The 02-on-A premise is consistent with every unit that touches 02: fleetchan part 1 requires and ends with 02 A
  committed on V (`prov-ac-fleetchan-254.sh:26,43-45,77`), `pr_peer_after` WARN branch expects `A 1` (`prov-254.sh:608`),
  `pr_p9` already makes 02 a hard dependency (`:656` neighbour) and `pr_begin` requires it reachable (`:668-671`). Only
  `prov-bench-s0-254.sh slota|toa 02` is built for 02 on B, and it does not go through `pr_begin`. But see MAJOR-5.
- ⚠️ Partly open: B M2 (pre= semantics, MINOR-1), B M4 / B m10 (node dead-men, MAJOR-6; lint patterns, MINOR-3),
  A M2 (product reboot, MAJOR-1), A M8 (seam vs root check, MINOR-2), B M5 / A M1 (02 on B, MAJOR-5).

## Findings

### MAJOR-1 — §3.2 compares against a stale boot, re-acquires twice, and misstates the undo replay: as written it breaks `pr_end` of every REVERT unit, the new ac-flap included

**Scenario (real use: the new ac-flap, §1).** `pr_ota_b` sets `PR_LAND_BOOT=X` (`prov-254.sh:376`). The product reverts
at the deadline; `pr_wait_reverted` notices the new boot and calls `pr_find 900 "$b0"` (`:435`), which re-stages and
re-acquires (`pr_find` → `pr_acquire "$rem"`, `:239`). The node is now in boot Y with a live lease. `pr_end revert` →
`pr_restore` → `pr_restore_cycle` (`:487`, `:592`). §3.2 now makes `pr_restore_cycle` compare the current boot (Y) with
`PR_LAND_BOOT` (X): they differ, so the harness announces "product rebooted the node (X → Y)" for a reboot it already
handled, and runs `pr_find` + `pr_acquire` again. Both re-acquire paths then fail: `pr_stage` refuses when the run's
staging dir exists in this boot (`prov-254.sh:194`: `[ -e "$d" ] && { echo "FAIL $d exists"; exit 1; }`), and it does
exist (created by the first `pr_find`). Result: lease FAIL → `pr_restore_cycle` rc 1 → `pr_end` NEEDS-PERSON — on
ac-flap, radio1off, fleetchan part 2, and every unit whose restore follows a harness-driven reboot after a landing
(leave-ota and prov-ota `back_to_a` → `pr_find`, `pr_restore` between halves, `pr_member`'s reboot). `as02` does not swap
`PR_LAND_BOOT` either (`prov-netjoin-fleet-254.sh:29-36`), so 02's restore compares 02's boot with 04's landing boot.

Separately, "pr_find, then pr_acquire" (§3.2 bullet 2) is a double acquire even on the true path: `pr_find` already
acquires (`:239`), the second `pr_acquire` hits the same `:194` refusal.

And "this also replays the undo journal" is not what `pr_acquire` does: `undo-replay` skips the current run
(`scripts/node/prov-lease-254.sh:100`: `[ "$_ur_" = "$RUN_ID" ] && continue`), while `undo-pending` lists every run,
the current one included (`prov-undo-lib-254.sh:266-270`). A run with its own p6 journal entries (`uwhere`:
`uci-restore|svc-enable|p5-save` → p6, `:76`) would get "FAIL undo still left after the replay" (`prov-254.sh:213`) after
a product reboot. No prov unit registers p6 actions today (only `eh13-pre-254.sh:47`, tmpfs), so this is latent, but the
design's claim is false.

**Fix.**
- Compare against the boot the harness *last knew*, not the landing boot: e.g. `PR_KNOWN_BOOT`, set by `pr_acquire`
  (i.e. every `pr_begin`, `pr_find`, landing) and swapped by `as02`. A differing boot is then by definition one the
  harness did not cause.
- On a recognised product reboot call `pr_find` only (it re-stages and re-acquires); never a second `pr_acquire`.
- State precisely what the undo replay covers; for the current run's own leftovers either run `pl undo` (host mode, own
  run) after the re-acquire or say why none can exist.
- Negative controls: add "harness reboot after landing (pr_find moved the boot) → `pr_restore_cycle` does NOT announce a
  product reboot and does not re-acquire" and "pr_find already acquired → no second `pl acquire` call" (stub counts
  calls). Both FAIL on the v2 text as written.

### MAJOR-2 — §2's new `helpers.list` kind `host` breaks the firmware's wbox contract and the set build

**Scenario.** v2: "helpers.list gets a `host` kind for them". The firmware that builds the wbox set reads the same file
and accepts only two kinds:
- `firmware-2710/scripts/lib-wbox.sh:58` `case "$kind" in helper|same) ;; *) … exit 1` (`wbox_apply`, called by
  `build-board.sh:126`);
- `firmware-2710/scripts/check-prov-test-gate.sh:126-131` `*) fail "helpers.list helper column '$KIND' … (want helper or same)"`;
- design `254-h23-harness.md:643` ("其他值 = FAIL (build-board 與 gate 都擋)").
The set builder iterates **every** name: `~/eh2-wsl21.sh:43` `for v in $(grep -v '^#' feeds/batman/tests/wbox/helpers.list | awk '$1 != "test" {print $1}'); do build $v; done`.
So the next wbox set build after a re-pin (the v1.6 release, wsl.37 if ever) fails five builds (`misc-l38/l42/l43/l51/l38r`),
and the E-H2 judgement that reads the list (`eh2-wsl21.sh:51`) sees a kind it does not know. In this repo,
`tests/wbox/test-lint-wbox.sh:64-69` fixtures (`misc-ok release same` with `want PASS`) would also need rewriting once
lint-wbox derives `host`, which §2 does not list. This is a cross-repo interface change with no owner, contract or test
in the design (§7 has no row for helpers.list).

**Fix.** Do not change the column. `dv-prov-tools.sh` already branches on the name (`:47` `case "$name" in misc-*)`);
let it derive every `misc-*` on the host and ignore misc wbox payloads, and keep `helpers.list` / lint-wbox / the firmware
unchanged (the firmware may keep building misc variants — harmless — or the host-local set builder skips `misc-*` by
name, recorded as a one-line note in #254). If a new kind is really wanted, it needs a firmware PR (lib-wbox, gate,
`test-build-board-wbox.sh`, `test-prov-test-gate.sh`) and a re-pin, which contradicts "no rebuild" — say which.

### MAJOR-3 — §3.1: the P9 remedy text is a raw `batman-slot rollback`, and "02 on B" recurs on every RC upgrade

**Scenario.** Any upgrade OTA lands on the *other* slot and commits it, so a 02 that is on A now lands on B at the next
RC (this is why 04 needs `pr_normalise` before every prov run: `daily-validation.sh:325`, `prov-254.sh:871-895`). The
bench is "02 on A" today by circumstance (§3.1 last line). At the next RC every prov unit FAILs P9 until a person moves 02.
The v2 FAIL text tells that person: "roll 02 to A first (batman-slot rollback on two identical slots)". That is the exact
unguarded slot command this PR removes elsewhere; it is only harmless when both slots really are identical (nothing
checks that), and for a cable-less 02 the bench's own tool documents why it is the wrong way: `prov-bench-s0-254.sh:12-15`
("the first version used `batman-slot rollback` on B, which has no way back: review 2026-11-06, both reviewers") and
`:26-28` (02 has no cable; a trial without a mesh is invisible and ends at its deadline). A rollback onto an A whose
overlay does not mesh leaves 02 unreachable: a person at the bench.

Also: "02 … A committed with version V" is checked inside `pr_p9`, but `PR_V` is set only after it (`prov-254.sh:663-665`);
V must come from 04's `ver` in the same `pr_p9`.

**Fix.** Message: `02 not A committed on V (<state>): bash scripts/dv/prov-bench-s0-254.sh slota 02, then toa 02 (04 first)`.
Add a lifecycle row "RC upgrade of the bench (02 lands on the other slot)": before = fleetchan precondition FAIL /
restore NEEDS-PERSON; after = P9 FAIL before any change, remedy toa 02; proof = offline P9 stub with 02 `slot=B`. A
`pr_normalise`-for-02 suite is a one-line extension idea in #254, not this PR.

### MAJOR-4 — §2's host derivation has no regression test, and `patch` differs from what the firmware and the equivalence proof use

**Evidence.**
- No test exercises `scripts/dv-prov-tools.sh` today (`grep -rln dv-prov-tools scripts tests .github` → only its callers
  and docs). §2's only proofs are a one-time byte equivalence on wsl.36 and the l38r discrimination case; nothing pins
  "a patch that does not apply cleanly is a FAIL, never a partial file", which is the new failure-mode contract (§7 row).
- The firmware applies with `git apply --check && git apply` (`firmware-2710/scripts/lib-wbox.sh:~82`), lint-wbox with
  `git apply --check` (`lint-wbox.sh:49`). GNU `patch` (present: Git Bash `/usr/bin/patch` 2.7.6, WSL `/usr/bin/patch`)
  defaults to fuzz 2: a hunk whose context drifted applies "with fuzz" and rc 0, `--dry-run` included. git apply refuses.
  The misc patches were generated on another base (`index 51187c2..`, `misc-l38.patch:3,5`; b885a2c's file is
  `4ef7470f…`): my scratch `patch --dry-run` against `git show b885a2c:…/batman-autocommit` applies all four with
  "Hunk #2 succeeded at 441/455 (offset 39 lines)" — fine today, but the harness checkout (newest main) and V (an older
  pin) will drift, and "differs from release + witness present" cannot detect a hunk applied in the wrong place.
- The CI mutant control is manual: `autocommit-mesh-arm.sh:10` says "the four misc-* mutants each make this test FAIL",
  but CI runs it only on the real file (`.github/workflows/ci.yml:123`).

**Fix.** One function `misc_derive <release-ac> <patch> <out>` (used by dv-prov-tools): scratch tree
`feed/batman-provision/files/usr/bin/batman-autocommit` = V's file, `git apply --check` then `git apply` (no fuzz,
same as firmware/lint), witness, differs-from-release, differs-from-others. A CI test runs it on b885a2c's autocommit for
every `misc-*`: each result FAILs `autocommit-mesh-arm.sh` (the automated negative control, l38r included), a patch with
one context line changed → FAIL "does not apply", an empty / no-witness patch → FAIL, and zero variants → FAIL.
Record the patch blob id (`git rev-parse HEAD:tests/wbox/<name>.patch`) next to the SHA256SUMS so a run log says which
patch made the mutant (a dirty harness checkout would otherwise produce an unreviewed mutant silently).

### MAJOR-5 — the node dead-man conversions (rows 36–38, 42) have no behaviour test and are invisible to the lint; row 42 contradicts §4.1's Pi 3 rule

**Evidence.**
- §4.3's behaviour proof covers "each converted host site". The node dead-men get none, although round 1 asked for an
  extracted run with `STUB_DISARM_FAIL` like chain1's (`test-slot-guard-254.sh:174-190`; review B MAJOR-4.2, MINOR-10).
- After conversion rows 36–38 still contain the literal `batman-slot reboot committed` (`ble-central-254.sh:102`,
  `ble-periph-254.sh:197`, `bt-uart-305.sh:297`), so they stay allowlisted text: the lint sees the same line before and
  after and cannot tell a prefixed reboot from a bare one. Row 42 (`node/halow-fi-263.sh:28,35,36,37,62`, plain `reboot`
  in a node script) is not "inside a node command string" (§4.3 pattern 2), so no pattern sees it at all. Hence §4.3's
  negative ("names exactly the rows that §4.2 converts") cannot hold for 36–38 and 42.
- Row 42 runs on `${DV_T263_NODE:-$BENCH_NODE}` (`daily-validation.sh:2773`), any SoC (`v16g4-sites.md` row 42). On a
  Pi 3 the DISARM reads `unknown` (§4.1), so every halow-fi-263 run would end with the FI module loaded and no reboot
  (the stock driver was `rmmod`ed at `:35`). §4.1 says Pi-3-reachable sites stay allowlisted; row 42 is converted.

**Fix.** One shared node helper (`dm_reboot <reason>`: disarm, `bf_get`-equivalent read = 0, then reboot, else the
`deadman: tryboot not cleared — no reboot` line) used by 36–38, so the lint pins one function name and the allowlist
row names the helper; an extracted-run test per caller with `STUB_DISARM_FAIL` (refused → no reboot, lease file and
`irk-exposed` / `bt305-dirty` kept) and a negative control (the b885a2c line reboots under `STUB_DISARM_FAIL`). Row 42:
allowlist with the #263 reason (or gate it on bcm2711), consistent with §4.1.

### MAJOR-6 — rows 24–29 are allowlisted on a false premise ("flag checked clear fleet-wide")

**Evidence.** `trybootget-209` checks one node: `suite trybootget-209 … "chk_trybootget_209 $BENCH_NODE"`
(`daily-validation.sh:2258`, function `:740-754`). Rows 24–29 reboot `DNODE` / `OTS_NODE` (`:446-448`; lab
`OTS_NODE=DESTRUCTIVE_NODE=10.41.238.222`, `:2236`) while `BENCH_NODE` defaults to `10.41.254.1` (`:48`). So the
destructive node's flag is never read before these plain reboots, and the destructive suites between `:2258` and
`:2322-2680` (FI P5, OTA suites) are exactly the ones that arm tryboots. `batman-slot:1040` then plain-reboots into the
tryboot slot — the hazard §4 exists to close, on the release gate's destructive node.

**Fix.** Correct the reason, and add a cheap read-only guard inside `reboot_and_wait` right before `fssh "$n" … "$cmd"`:
a GET of the flag on `$n` (no clear, no change of command or timing); `1` → FAIL "tryboot armed — not rebooting";
`unknown` → refuse on bcm2711, WARN on bcm2837 (keeps Pi 3 working). Negative control: stub node answering
`tryboot_flag=1` → b885a2c reboots, the fix refuses.

### MINOR-1 — `pre=` is unspecified as an API and changes overlay-wipe's failure path

`reboot_guarded`'s 5th argument is the extra *condition* (`slot-guard-254.sh:55`, run as `{ $x; }` at `:52`). §4.2 row
10 writes `reboot_guarded … pre='firstboot -y'` without saying which argument; passed as arg 5 it would run as
`pre=firstboot -y` (an assignment + command `-y`) → `WRONG-STATE … extra=0`, a silent never-wipe. Also: today
`firstboot -y; reboot` reboots whatever `firstboot` returns; v2's "rc ≠ 0 → PRE-FAILED, no slot command" leaves a
possibly half-wiped, unrebooted node. Define `pre` as a 6th argument (and pin it in lint (2)); for a destructive pre,
once it has *started* the reboot is the recovery — answer `PRE-RC=<n> SENT`, or state why not.

### MINOR-2 — §3.3's seam needs non-root, but `prov-base-254.sh` refuses non-root

`prov-base-254.sh:26` `[ "$(id -u)" = 0 ] || { echo "FAIL root only"; exit 2; }`; the existing seam tests run as root
under `PROV_BASE_TEST_ROOT` (`tests/prov-p1/prov-base-statecmp.sh:3`, `prov-base-stateset.sh:3`). §3.3 gates `PB_*` on
`id -u ≠ 0` without saying that `:26` changes. State the new rule (non-root allowed only when every `PB_*` condition
holds, else the same FAIL) and that a root run with `PROV_BASE_TEST_ROOT` and no `PB_P5` still FAILs before `dd`
(A M8's remaining half: `P5` is absolute, `:33`).

### MINOR-3 — §4.3 lint patterns regress today's lint and are under-specified

- Pattern 1 drops the `["']?` before the verb and the release form that today's lint (1) has
  (`test-slot-guard-254.sh:283`: `batman-slot[[:space:]]+[\"']?(rollback|commit)|batman-autocommit[[:space:]]+[\"']?release`).
  Use the union (sites file pattern + release).
- Pattern 2 ("inside a node command string") does not match rows 24–29's shape (`reboot_and_wait "$n" reboot`, default
  `cmd=${2:-reboot}`, `daily-validation.sh:2292`) nor row 42; and "plus 3 pinned text lines" undercounts the text lines a
  `reboot` pattern hits (`v16g4-sites.md` §4: `ble-254.sh:285,296`, `daily-validation.sh:787,2634,2640,2643,2724`,
  `halow-fi-263.sh` log text). Give the exact regex and the generated expected hit list.
- Lint (2)'s extractor regex `((rb|reboot|release)_guarded|_sg_cmd)` (`test-slot-guard-254.sh:320`) must include
  `commit_guarded`, or the new sites are unpinned (§4.3 says "pinned" but not the regex change).

### MINOR-4 — prov-misc still aborts mid-unit when the misc tools are stale

After the merge, until `dv-prov-tools.sh <wsl.36>` is re-run, `$PR_TOOLS/$PR_V/misc-l38r` is missing → `bindac` `no`
(`prov-misc-254.sh:33`) → `dr` rc 1 (`:47`) → `dryarms` returns at l38nega (`:94`) → svcarms and L3 (the converted
reboot, row 8) never run — round-1 B M6's symptom by another route. Check every `misc-*` of `helpers.list` for `PR_V`
before `pr_begin` (FAIL "run dv-prov-tools.sh $PR_V" before anything changes), and add "re-run dv-prov-tools" to §8
delivery step 3.

### MINOR-5 — §3.2 "continue" for every unexpected boot

A new boot on A without a `TRIAL-*` line for boot X is a watchdog / panic / power event, not a product revert.
`pr_wait_reverted` already treats that as INVALID (`prov-254.sh:445`). §3.2 should do the same (INVALID with the
boot-reasons tail) and continue only to the restore, so a unit can never PASS across an unexplained reboot.

### MINOR-6 — §8's device proof for §3.2 does not exercise §3.2

§8 row "Product reverts a held trial" cites "ac-flap on the device". The v2 ac-flap waits with `pr_wait_reverted`
(§1 step 3), which handles the revert itself; it never reaches `back_to_a`'s new branch. (It does reach the
`pr_restore_cycle` comparison — where MAJOR-1 would show.) Mark §3.2's recognition path ⚠️ offline-only or name a device
vehicle that leaves a held trial past its deadline before calling `back_to_a`.

## Negative controls — would each fail on b885a2c?

| Claim | On b885a2c | Note |
|---|---|---|
| §1 offline judge (i)–(iv) | n/a (new function); synthetic cases discriminate | device: old judgement FAILs on wsl.35 log ✅ |
| §2 l38r via `autocommit-mesh-arm.sh` | ✅ "L38 helper comes at poll 5" FAILs on the mutant (`:32`) | should be automated in CI (MAJOR-4) |
| §2 derivation fail-closed | ❌ no test exists | MAJOR-4 |
| §3.1 P9 02 check | ✅ b885a2c `pr_p9` passes a 02 on B (`:638-657` never reads 02's slot) | remedy text MAJOR-3 |
| §3.2 offline cases | ✅ both cases differ on b885a2c | missing the false-positive case (MAJOR-1) |
| §3.3 mount cases | ✅ b885a2c dies unnamed (`prov-base-254.sh:219`) | seam vs `:26` (MINOR-2) |
| §4.3 lint | ⚠️ FAILs, but not "exactly the converted rows": 36–38 / 42 unseen, pins of new sites also fail | MAJOR-5, MINOR-3 |
| §4.3 behaviour proofs | ✅ for host sites | none for node dead-men (MAJOR-5) |
| §5, §6 | ✅ as round 1 | — |

## Summary

| # | Sev | Area | One line |
|---|---|---|---|
| 1 | MAJOR | §3.2 | stale `PR_LAND_BOOT` → false "product reboot" in every REVERT unit's restore (ac-flap too); double acquire hits `pr_stage` "exists"; undo replay skips own run |
| 2 | MAJOR | §2 | `host` kind breaks firmware `lib-wbox.sh:58` / gate `:131` and the set builder; keep the column, branch on name |
| 3 | MAJOR | §3.1 | P9 remedy is a raw rollback (bench-s0 says no way back for 02); 02-on-B recurs every RC; use slota+toa 02 |
| 4 | MAJOR | §2 | derivation untested; `patch` fuzz ≠ firmware `git apply`; automate the misc negative controls in CI |
| 5 | MAJOR | §4 | node dead-men 36–38/42 untested and lint-invisible; row 42 Pi-3-reachable contradicts §4.1 |
| 6 | MAJOR | §4.2 | rows 24–29 allowlist premise false: trybootget-209 checks BENCH_NODE only; add a read-only flag check |
| 7 | MINOR | §4.1 | `pre=` argument position undefined; destructive pre with no reboot on rc ≠ 0 |
| 8 | MINOR | §3.3 | seam needs non-root but `prov-base-254.sh:26` refuses non-root |
| 9 | MINOR | §4.3 | patterns drop today's quote / release forms; pattern 2 misses rows 24–29 / 42; lint (2) regex lacks `commit_guarded` |
| 10 | MINOR | §2 | stale misc tools still abort prov-misc mid-unit; check up front |
| 11 | MINOR | §3.2 | unexplained reboot should be INVALID, not "continue" |
| 12 | MINOR | §8 | ac-flap does not exercise §3.2's back_to_a branch |
