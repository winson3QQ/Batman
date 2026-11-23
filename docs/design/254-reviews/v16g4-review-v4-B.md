# v1.6 group 4 (harness PR A) design review v4 — reviewer B

Design: `docs/design/254-v16-group4.md` v4 (HEAD 985de1d of `test/254-v16-group4`, base main b885a2c), worktree
`C:\src\Batman-g4h`, read as a whole together with `v16g4-review-v{1,2,3}-{A,B}.md` and `v16g4-sites.md`.
Method: read-only `grep` / `sed` / `git show` in the worktree (line numbers are b885a2c; nothing under `scripts/`,
`tests/`, `feed/` differs at HEAD). Scratch experiments in my scratchpad only:
- `git apply` of `tests/wbox/misc-l38.patch` onto `git show b885a2c:…/batman-autocommit` placed at `usr/bin/` outside any
  work tree (Git Bash, git 2.53);
- WSL Ubuntu-24.04 **as yello (non-root)**: `unshare -Urm --propagation private` with tmpfs over `/tmp` and `/dev`, a
  tmpfs mounted with the source `/dev/mmcblk0p5`, `/proc/mounts`, `/dev/null` redirections, `umount`, `dd iflag=direct`;
- `command -v getent` and the venv path on Git Bash; `wsl.exe -d Ubuntu-24.04 -- whoami`.

No ssh, no harness script against a node, nothing as root, no repo file touched except this report.

**Verdict: REJECT (v4) — small revision, then a whole-document re-review.** No BLOCKER. Every v3 finding of mine is
addressed in the text (table below), and the 42-row site table is fully covered by §4.2 (rows 1–42 each in exactly one
group). One MAJOR remains: the rows 36–38 dead-man refusal does not keep the lease as claimed, because the callers of
`role_fire_restore` remove it, and the specified test cannot see that; the bt305-dirty precondition is placed where
BLE runs on the same controller do not read it. Ten MINORs, mostly wrong rationales or spec gaps that would surface
as a red test, not as a wrong verdict.

## v3 findings (reviewer B) — resolution check

| v3 | v4 | Status |
|---|---|---|
| M1 remedy `slota`/`toa 02` refused | §3.1 per-state texts: "one more OTA of V to 02 lands it on A" | ✅ an OTA writes the inactive slot (`batman-slot:7`, `target` = `other_slot "$(active_slot)"` `:1070`) and is refused in a trial (`:617`), so from B committed one OTA lands A. ⚠️ the "older version" text is wrong when 02 starts on B (MINOR-3) |
| M2 p5 control writes `/dev/mmcblk0p5` on the host | §3.2 `unshare -m` sandbox, refuse unless `/dev` is the tmpfs | ✅ in principle (my probe: a tmpfs mounted with the source `/dev/mmcblk0p5` appears as `^/dev/mmcblk0p5 ` in the namespace's /proc/mounts). ⚠️ as specified it dies before the check under test, and real root is not needed (MINOR-2) |
| m3 check blocks every unit | `PR_USES_02` | ✅ fleetchan and netjoin-fleet are the only units that change 02's slot (`grep as02\|qp`); ⚠️ nothing keeps a future unit honest (MINOR-3) |
| m4 rows 1, 7, 13 not SoC-gated | §4 Pi 3 policy: one rule, no SoC exemptions | ✅ consistent now. ⚠️ the cited FI evidence is wrong (MINOR-4) |
| m5 pty-commit NEEDS-PERSON / wording | row 13: "landing boot unknown — not committing" | ⚠️ wording fixed; the bad-slot consequence and NEEDS-PERSON still unstated (MINOR-8) |
| m6 bt305 marker unchecked; lease `rm` order | DISARMED before the `rm`; bt305 dv-start precondition | ❌ the callers remove the lease anyway; placement misses BLE runs (MAJOR-1) |
| m7 `git apply` inside a work tree | refuse inside a work tree, `Skipped patch` = FAIL, reverse check | ✅; ⚠️ the path strip is missing (MINOR-5) |
| m8 lint (3) counts / prechecked blind / row 30 | exact text + count; precheck pinned in lint (2); row 30 prechecked | ✅; ⚠️ rows 36–38 stay invisible to lint (1)/(3) on b885a2c (MINOR-6) |
| m9 §7 02 writers | §7 lists fleetchan, restore02, bench-s0, OTAs | ✅ |
| m10 open line in #254 | added under L116 | ✅ (taken from §12; not re-read) |
| m11 stale test sentence; wiring | §4.2 / §4.3 "where the offline tests run" | ✅ for the list; ⚠️ the "Windows host" claim is false (MINOR-1) |

## Findings

### MAJOR-1 — rows 36–38: a refused dead-man reboot does not keep the lease, and the specified test cannot see it

**Scenario (real use).** A BLE tier-B or bt305 run on 04 dies on the host (laptop sleep, ssh drop). The node dead-man
fires (`cmd_dm_fire`), and the tryboot clear fails (firmware hiccup, or a flag armed by an earlier OTA step). §4.2 says:
"no reboot, the lease and the dirty markers stay".

**Evidence.** The DISARMED prefix is planned inside `role_fire_restore`, before its `rm -f "$BT/lease" …`
(`node/ble-central-254.sh:101`, `ble-periph-254.sh:196`, `bt-uart-305.sh:296`). But both callers remove the lease again
after `role_fire_restore` returns:
- `node/ble-lib-254.sh:341-343` (`cmd_dm_fire`): `role_fire_restore "$run"; provd_start; rm -f "$LEASE" "$ST/dm" "$ST/dm.new"`;
- `node/ble-lib-254.sh:353-357` (`cmd_recover`, the person's `ble-recover`): `role_fire_restore recover; provd_start;
  rm -f "$BT/lease"; … echo "RECOVERED"`.

So unless the refusal path **exits** the script, the lease goes, and `ble-recover` prints `RECOVERED` over a node it did
not recover. For bt305 a `return` also falls through into the soft restore (`rmmod r305raw`, rebind,
`bt-uart-305.sh:299-300`), on a UART whose module may be `hci_uart-noP2`.

With the lease gone, the next `acquire` succeeds (`ble-lib-254.sh:283-292` refuses only on an existing lease).
- For BLE, `irk-exposed` still stops the run: `ble_state` checks it (`ble-lib-254.sh:253`).
- For bt305, the planned `bt305-dirty` precondition sits in "bt-uart-305's dv start" only. A BLE tier-B run on the same
  04 controller reads `ble_state`, which does not look at `bt305-dirty` (`:250-262`). It then measures BLE on a dirty
  UART, with nothing in its log to explain it.

The specified test cannot catch this. It extracts "each body" as `test-slot-guard-254.sh:135-151` does (chain1's
dead-man, a standalone script whose refusal is `exit 1`, `chain1-254.sh:152`). Extracting only `role_fire_restore` does
not run the caller's `rm`, so the test passes whether or not the lease survives.

**Fix.**
1. Specify the refusal as `dm_log …; exit 3` inside `role_fire_restore`, before the lease `rm`, `provd_start` and any
   soft restore. `exit` releases the flock (`ble-lib-254.sh:100-103`), so the lock does not stick. State that provd
   stays stopped until a person reboots the node.
2. In `cmd_recover`, a refusal must not print `RECOVERED`.
3. Put the `bt305-dirty` check in `ble_state`, next to `irk-exposed`. It is the shared preflight of the BLE and bt305
   runs, so both stop on it. Keep the bt305 dv-start check as well if wanted.
4. Change the test to drive `cmd_dm_fire` and `cmd_recover` (sourced `ble-lib-254.sh` plus the role script, `vcmailbox`
   and `batman-slot` stubbed), with and without `STUB_DISARM_FAIL`. Assert:
   - the lease file still exists;
   - the markers still exist;
   - no reboot was sent;
   - no `RECOVERED` line;
   - `ble_state` FAILs on `bt305-dirty`.

   Negative control: the same test on a role script with the prefix but `return` instead of `exit` FAILs on "lease
   still exists".

### MINOR-1 — §2 / §4.3: `test-derive-misc` does not run "on the Windows host" through `test-h4-offline-254.sh`

On Git Bash, `scripts/test-h4-offline-254.sh` exits 1 at its first check:
- `getent` is absent (`command -v getent` → nothing), so `OWNER_HOME` is empty;
- `PY=~/.batman-dv/peer-venv/bin/python` does not exist on Windows (`/c/Users/yello/.batman-dv`: no such directory);
- `:17` `[ -x "$PY" ] || { tbad …; exit 1; }`.

Its own header says "WSL / Linux only", because the undo executor needs namespaces. daily-validation's `self_test`
(`daily-validation.sh:198-206`) delegates it to WSL when the repo is under `//wsl.localhost/`. There it runs as the
distro default user: `wsl.exe -d Ubuntu-24.04 -- whoami` → `root`.

So the claim "also on the Windows host … where the CRLF trap lives" (§2, §4.3, §12 row A M1) is false.

The real risk is small, which is why this is a MINOR:
- `.gitattributes` has `* text=auto eol=lf` (`git check-attr`: `eol: lf` for the patches, `helpers.list` and
  `batman-autocommit`, and 0 CR bytes in the Windows checkout);
- `derive_misc` asserts "no CR byte" at run time, so a CRLF slip turns into INVALID up front, not a bad mutant.

**Fix:** correct the text (WSL, as root, through `self_test`). If Git Bash coverage of `dv-prov-tools.sh` is wanted,
run `bash tests/wbox/test-derive-misc.sh` directly from Git Bash as its own step (it needs only git, sh and bash), and
say where.

### MINOR-2 — §3.2 sandbox: no `/dev/null` in the tmpfs `/dev`, so main and the fix die early; real root is not needed

**Probe** (WSL, as yello): `unshare -Urm --propagation private` gives `id -u` = 0 inside.
- A tmpfs over `/dev` and `/tmp` mounts, and a tmpfs with the source `/dev/mmcblk0p5` shows in /proc/mounts.
- `umount` works, and `dd iflag=direct` on a tmpfs file works (kernel 6.6.114).
- But the fresh `/dev` has no `null`: `sh: cannot open /dev/null: No such file`.

`prov-base-254.sh` needs `/dev/null` on this path. `lock_take` starts the holder with `"$HOLDER" </dev/null`
(`:56-57`), so with no `/dev/null` both scripts die at "lock holder cmdline does not match" before the mount check:
- main's negative control "dies with no name" passes for the wrong reason;
- the fix case fails.

Bind-mounting the host's `/dev/null` into the userns tmpfs gave "Permission denied" on write in my probe. A regular
file at `/dev/null` (and `/dev/zero`) works for these scripts.

**Fix:**
1. The sandbox creates `/dev/null` (a regular file in a user namespace, or `mknod` if run as root).
2. Main's control asserts the exact text `FAIL p5 is mounted` and no `P5-` line.
3. The fix's cases assert `P5-MOUNTED`, `P5-RESTORED` and the read-back.
4. Use `unshare -Urm` (user + mount namespace) instead of real root, which removes the v3 host-`dd` hazard
   structurally. `test-undo-lib.sh` already relies on user namespaces in WSL.

   As root, "nothing outside the namespace is writable" is not true anyway. The PID namespace is shared, and
   `echo 3 > /proc/sys/vm/drop_caches` (`:221`, the fallback when direct I/O fails) is global. In a user namespace
   that write is refused, and my probe got "Permission denied".
5. State that `test-h4-offline-254.sh` then needs no root for this item.

### MINOR-3 — §3.1: "upgrade 02 to V twice" lands on B when 02 starts on B; nothing enforces `PR_USES_02`

**The text.** 02 on B with an older version: two OTAs go to A, then B, so 02 ends on B. The next run FAILs with the
"on B committed on V" text and needs a third OTA. One OTA from B lands A on V, which is all the check needs.
- Make the text depend on the slot: "from A: two OTAs of V; from B: one".
- Add the two older-version cases to the §3.1 stub test (02 on A old, 02 on B old).

**Enforcement.** `PR_USES_02=1` is set by hand in two scripts. A future unit that calls `as02`, or OTAs or rolls back
02 through `qp`, without it gets a NOTE and later a NEEDS-PERSON from `pr_restore_cycle`'s A-only check
(`prov-254.sh:465`), after it has mutated 02.
- Add a grep test to the extended `test-slot-guard-254.sh`: any `scripts/dv/prov-*.sh` that contains `as02`, `restore02`
  or `qp "…sysupgrade` / `qp "$(rb_guarded` must assign `PR_USES_02=1` before its `pr_begin`. Today that is 2 files;
  zero matches → FAIL.
- Note: §3.1 says "before `pl acquire`". In `pr_begin` the lease is `pr_acquire` (`:668`), which calls `pl acquire`
  (`:207`). Say `pr_acquire`, and on the FAIL path `PR_BEGUN=0; pr_unlock`, as the neighbouring exits do (`:667`).

### MINOR-4 — row 11/12 rationale: `fault-injection.sh:575` is not a Pi 3 refusal

`:575` is the step-6 `rb_guarded "${b1:0:8}" B 1 p5-back-to-A`, reached only when the reflash landed on B. `p5()`
(`:529-533`) has no SoC check: it checks only "committed" and "no hold flag".

The trial branch of `p5_ap_back` (row 11) is reached from `ota_boot`'s failure (`:546`), **before** step 6. So on a
Pi 3 nothing has "already refused" when row 11 runs.

The outcome is still fail-closed and the same as the §4 policy: the guard refuses, `p5_person` writes NEEDS-PERSON.
Only the cited evidence is wrong. **Fix:** replace "FI P5 already refuses on a Pi 3 (`:575`)" with "on a Pi 3 whose
firmware does not answer word 5, rows 11/12 refuse (WRONG-STATE) and `p5_person` raises NEEDS-PERSON, as `:575`
already does at step 6".

### MINOR-5 — §2 `derive_misc`: the patch path needs `-p4`; "L38 a / L38 b" do not exist

**The patch path.** The misc patches name `a/feed/batman-provision/files/usr/bin/batman-autocommit`
(`tests/wbox/misc-l38.patch:4`). With the base copied to `usr/bin/batman-autocommit` (§2 step 1), the default `-p1`
fails. Scratch: `error: feed/…/batman-autocommit: No such file or directory`, rc 1. `-p4` applies: `Checking patch
usr/bin/batman-autocommit... Hunk #2 succeeded at 441 (offset 39 lines)`, rc 0.
- This fails closed, and CI would catch it at once.
- Write `-p4` (or "the base at its repo path") into the spec, for `--check`, the apply and the `-R --check`.

**The case names.** `tests/prov-p1/autocommit-mesh-arm.sh` names its cases by text (`:32-44`: "L38 helper comes at
poll 5 …", "L38 helper never comes -> 60 polls …"). There is no "L38 a" or "L38 b". Name the exact case string each
mutant must FAIL:
- l38r: FAILs "comes at poll 5" and PASSes "60 polls";
- l38: FAILs "60 polls".

Otherwise "the failing case is the one named" is not implementable as written.

### MINOR-6 — §4.3: rows 36–38 are invisible to lint (1)/(3) on b885a2c unless the prefix shares the reboot's line; generator and file-type scope

**Rows 36–38.** The node dead-men keep the text `batman-slot reboot committed ble-dm-254; exit 0` (and
`bt305-dm`). If the DISARMED check sits on the line before it, then:
- the lint (1) allowlist row and the lint (3) inventory row for that line are the same on b885a2c and after the change;
  the §4.3 negative control "lint (3) names … rows 36–38 on the node" does not hold;
- deleting the prefix later passes every lint. Only the behaviour test sees it.

**Fix:** put the check and the reboot on one line (`dm_disarmed && batman-slot reboot committed …`), so the exact-text
row binds them, or pin the node helper in lint (2).

**Scope.**
- `scripts/dv/gen-slot-sites.sh` will contain the lint (3) regex itself. Exclude it with the inventory, or give it rows.
- Today's lint is `--include='*.sh'` (`test-slot-guard-254.sh:302`). The new scope lists directories that also hold
  `.tsv`, `.py` and `.patch` files. `scripts/dv/data/p3-units.tsv` has one hit. Say whether lint (3) is `*.sh`-only.
- My count with the stated scope and exclusions (`*.sh` and others, minus `^\s*#` lines, `test-*.sh`,
  `slot-guard-254.sh`) is **169** hits in 41 files, not 172. The generator decides the count, so this is only a note.

### MINOR-7 — §7 / §4.1: "DISARM clears the flag only on a committed node" contradicts the guard

`slot-guard-254.sh:47` appends `$DISARMED` to **every** `rollback` / `reboot` action, whatever the trial argument. The
following calls disarm in a trial:
- row 11 (`reboot_guarded … 0`);
- `rb_guarded "$b0" B any` (`prov-254.sh:401`, `prov-ac-fleetchan-254.sh:41`);
- `reboot_guarded "$b" "$sl" 0` (`fresh-254.sh`).

It is harmless: in a trial the one-shot flag is already consumed. But the §7 contract, which is meant to be the
ownership statement, is false against the code. **Fix:** "cleared before every guarded rollback or reboot, in any trial
state; a failed clear → nothing sent".

### MINOR-8 — row 13: the settle-failed path leaves `bad-slot` behind, which the code comment calls the reason to commit

`pty-commit-254.sh:37-38`: "a deadline revert would leave bad-slot behind and block every later run (review M3)". v4
now deliberately leaves that path to the deadline revert, and prints only a FAIL. Then:
- the next DNODE0 suites see `badslot=[…]`, e.g. `pr_p9` "FAIL hold flag / bad-slot present" (`prov-254.sh:644`);
- there is no `needs-person.txt` line, so `dnode_blocked` does not stop them early.

**Fix**, either:
- in `stop()`, read `boot` + `ST` in one ssh. A trial on `TGT` with `held=1` in this boot can only be the landing
  (exactly one OTA was sent). Then `commit_guarded` with that boot; or
- append `NEEDS-PERSON pty-commit-254 ($NODE): trial left to its deadline revert; bad-slot follows` to
  `$DV_DIR/needs-person.txt`, as `p5_person` does (`fault-injection.sh:453`), and say so in §4.2.

### MINOR-9 — `reboot_and_wait` precheck: the `&& … ||` form misattributes a failing trigger; device coverage before merge

**The form.** `<GET>; [ answered ] && [ flag = 0 ] && { <trigger>; } || echo TRYBOOT-NOT-CLEAR` also prints
`TRYBOOT-NOT-CLEAR` when the trigger itself returns non-zero after it started. The host then reports "flag armed" for a
node that may be going down. Use `if … then <trigger>; else echo TRYBOOT-NOT-CLEAR; fi`.

**Output.** `reboot_and_wait` discards the trigger's output today (`daily-validation.sh:2298`, `>/dev/null 2>&1`). Say
that the precheck variant captures it, and that the existing `trigger … ssh rc=` line stays.

**Device coverage.** `reboot_and_wait` is shared by 8 D-suites (`:2322, 2340, 2355, 2481, 2631, 2656, 2667, 2680`), and
§8 delivery step 3 runs none of them before the merge. Add one (e.g. `guardian-192` or the hold-274 cleanup reboot) to
step 3, or state in the PR that the first device run of the precheck is the post-merge full validation (#290).

### MINOR-10 — §10 / §11 contradict §4.2 v4

- §10 row "A m7 … rows 11, 12, 42 allowlisted" and §11 "FI :462 (now allowlisted under the Pi 3 rule instead of
  trial 0)": §4.2 v4 guards rows 11 and 12 (trial 0 / trial 1).
- §10 row "A M2, B M3 … remedy = `slota` / `toa`": replaced by the §3.1 v4 texts.

A reader of the kept history gets the opposite of the current design. **Fix:** mark these cells "superseded by v4 §4.2
/ §3.1".

## Focus checks (as asked)

1. **§3.1 paths.** ✅ An OTA writes the inactive slot (`batman-slot:7,1070`) and is refused in a trial (`:617`).
   "One more OTA of V" from B committed lands A, as in `ota36.log` step 3.
   - ⚠️ The "older version" text: MINOR-3.
   - `PR_USES_02`: units that change 02's slot are `prov-ac-fleetchan-254.sh` (OTA `:33`, `rb_guarded` `:41`) and
     `prov-netjoin-fleet-254.sh` (`as02` `:29-32`, `restore02` `:74-85`).
   - `prov-provd*`, `prov-netjoin-254`, `prov-status-diag` reach `$PEER` only over BLE / reads, and do not need A.
   - `chain1` reads 02 (`:100, :334`) without `pr_begin`.
2. **Row 11/12, rows 36–38, bt305.**
   - `:575` is not a Pi 3 refusal (MINOR-4).
   - The DISARMED-before-`rm` ordering is defeated by the callers (MAJOR-1). The chain1 prefix (`bf_get`) does check
     word 5 now (`bootfacts.sh:19,26`, `bf_vc_ack`).
   - The bt305 precondition placement: MAJOR-1.
3. **Lint.** Exclusions are sound for `test-*.sh` and the guard; the generator and the non-`.sh` files are open
   (MINOR-6). The generated negative-control set is fine, but rows 36–38 are not in it unless the line text changes
   (MINOR-6).
4. **test-derive-misc.**
   - CI ✅: ubuntu-latest has git; `mktemp -d` is under `/tmp`, outside `$GITHUB_WORKSPACE`; the step sits next to
     `autocommit-mesh-arm.sh` (`ci.yml:123`).
   - Windows host: ❌ (MINOR-1).
   - Path strip: MINOR-5.
5. **Root.** `test-h4-offline-254.sh` runs as root today only through daily-validation's WSL delegation (default user
   root). A release-gate run gets the same through `self_test`. A manual run as yello would FAIL the p5 item ("refused
   elsewhere"). MINOR-2 removes the need for root.
6. **Contradictions.** §7 vs the guard (MINOR-7); §10 / §11 vs §4.2 / §3.1 (MINOR-10). §0, §8 and §9 are consistent with
   §1–§4 otherwise. The §9 dead-man trade-off holds only once MAJOR-1 is fixed (the "kept markers" are what make the
   case visible).

## Negative controls — would each fail on b885a2c / without the fix?

| Claim | Holds? | Note |
|---|---|---|
| §1 `acflap_judge` synthetic + wsl.35 device FAIL | ✅ | unchanged from v3 |
| §2 `test-derive-misc` (CI) | ✅ once `-p4` is in (MINOR-5) | the mutant half is real (v3 scratch runs) |
| §3.1 stub: `pl acquire` called on main | ✅ main `pr_begin` never reads 02's slot | add the older-version cases (MINOR-3) |
| §3.2 main dies, no name | ⚠️ vacuous until `/dev/null` exists and the exact die text is asserted (MINOR-2) | — |
| §4.2 host guarded sites, stub node | ✅ | — |
| `reboot_and_wait` precheck, stub `fssh` | ✅ main triggers with the flag armed | MINOR-9 |
| dead-men 36–38, `STUB_DISARM_FAIL` | ❌ body-only extraction cannot see the caller's lease `rm` | MAJOR-1 |
| §4.3 lint (1)–(3) | ✅ rows 1–10, 19, pins, precheck; ⚠️ rows 36–38 not (MINOR-6) | — |
| §5, §6 | ✅ as in earlier rounds | — |

## Summary

| # | Sev | Area | One line |
|---|---|---|---|
| 1 | MAJOR | §4.2 rows 36–38 | `cmd_dm_fire` / `cmd_recover` remove the lease after `role_fire_restore` returns (`ble-lib-254.sh:343,356`); the body-only test cannot see it; `bt305-dirty` must go in `ble_state` |
| 2 | MINOR | §2/§4.3 | `test-h4-offline-254.sh` cannot run on Git Bash (no getent, no venv, exits at `:17`); it runs in WSL as root; CRLF is defused by `.gitattributes` |
| 3 | MINOR | §3.2 | the tmpfs `/dev` has no `/dev/null`, so `lock_take` dies first and main's control passes vacuously; `unshare -Urm` works without root (probe) |
| 4 | MINOR | §3.1 | "twice" from B lands on B; no grep test enforces `PR_USES_02`; say `pr_acquire` |
| 5 | MINOR | §4.2 rows 11/12 | `:575` is the step-6 `rb_guarded`, not a Pi 3 refusal; P5 has no SoC gate |
| 6 | MINOR | §2 | patch paths need `-p4` (scratch rc 1 vs rc 0); "L38 a/b" are not case names in mesh-arm |
| 7 | MINOR | §4.3 | rows 36–38 lint-invisible unless the prefix shares the reboot line; generator self-hit; `*.sh`-only?; 169 vs 172 |
| 8 | MINOR | §7/§4.1 | "DISARM only on a committed node" is false: `slot-guard-254.sh:47` disarms in trials too |
| 9 | MINOR | §4.2 row 13 | the settle-failed path leaves `bad-slot` (the reason `:37-38` commits) with no NEEDS-PERSON |
| 10 | MINOR | §4.2 rows 24–31 | the `&&…\|\|` precheck misattributes a failing trigger; output is discarded today; no device run before merge |
| 11 | MINOR | §10/§11 | the kept history says rows 11/12 allowlisted and remedy `slota`/`toa`, contradicting v4 |

(MINOR-1 … MINOR-10 in the text are rows 2 … 11 here.)
