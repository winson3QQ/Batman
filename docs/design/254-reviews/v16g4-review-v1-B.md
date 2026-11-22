# v1.6 group 4 (harness PR A) design review v1 — reviewer B

Design: `docs/design/254-v16-group4.md` v1 (commit 325fad1 on base main b885a2c), worktree `C:\src\Batman-g4h`.
Method: read the whole design, then every cited file at b885a2c; read-only greps / `git show` only; issue bodies of #254 and
#329 read with `gh issue view` (read-only). No node touched, nothing run against a device. Line numbers are b885a2c.

**Verdict: REJECT (v1)** — the direction is right and most of §0 checks out, but six MAJOR findings need a v2: one
converted site would break a self-healing path, one would leave a node wiped and unreachable, the p5 unmount is argued
from a wrong premise, the lint extension is blind to forms present in its new scope, and the device plan for §2 / §3 /
§4 cannot run as written on the bench. No BLOCKER.

## What I verified as stated (✅, with evidence)

- §0 ac-flap premise: `batman-autocommit:504-507` (`running batman-provhelper || { echo "svc batman-provhelper down"; return 1; }`);
  wsl.35 run log `Desktop/Batman/v16/g1/prov-ac-flap-254-wsl35.log:13-29` (not HELD, 43 exits, `back_to_a: already on A`,
  `lease renew +1800:` empty, NEEDS-PERSON); recovery log `recover-flap.log` (bad-slot = the wbox trial, V trial HELD).
- `provd-stable` can never be written under helper-flap: `feed/batman-prov/src/cmd/batman-provhelper/stable.go:30-47`
  requires one provd connection of one helper instance open 60 s; the mutant exits 5 s after serving (`edits.pl:22`). So
  the flapping trial can never log "is healthy and HELD" (which `batman-autocommit:585-587` logs on a single healthy
  poll, no dwell). The design should cite this — it is the reason step 5's HELD branch cannot fire spuriously.
- §0 l38nega: `edits.pl:185-188` deletes the loop of `batman-autocommit:443`; node `inloop` `scripts/node/prov-misc-254.sh:110-113`
  (TOOFAST after 3 s); host `scripts/dv/prov-misc-254.sh:55-59` turns it into `inv`. Structural, as stated.
- §0 L116: `prov-254.sh:465` (A committed only), `:480` (bare reboot), `prov-netjoin-fleet-254.sh:76` (`restore02` =
  `as02 pr_restore`), `pr_p9` `:642` checks 04 only. Node p5-restore dies unnamed at `node/prov-base-254.sh:219`
  ("p5 is mounted"); host prints `tail -1` at `prov-254.sh:470`. (The identity `slot=` is written at
  `node/prov-base-254.sh:112`, read at `:230` — the design cites :230 as the writer; trivial.)
- §0 guards: `slot-guard-254.sh:39-56`; lint regex `test-slot-guard-254.sh:283` has no `reboot`; scope `:263`.
  `batman-slot:1040` (`bf_get` != 0 → plain reboot). All 12 host sites listed in §0 exist at the stated lines.
- §0 L220: `test-all.sh:81` computes names, `:82` prints counts, `:88` prints `failed=`. No consumer parses
  test-all's lines (`.github/workflows/app-tests.yml:98` runs it; `judge-test-output.sh` does not judge it).
- §0 #329 L196: `prober_test.dart:144-149` awaits 99 × 1 ms before returning; the stopwatch `:275-279`.
- §6 negative control discriminates: with `prober.dart:228` mutated to `if (!gotMsg2)`, the empty FakeSession script
  (`prober_test.dart:67`, `onFrame` returns null) sets `gotMsg2` on the first fragment, so `due` (`prober.dart:130-132`)
  no longer ends the attempt and the 20 s `answer` timer does → ~20 s → FAIL; real code ends at 50 ms.
- Issue scope (#254 L116 / L117 / L128 / L178 / L179 / L181 / L220, #329 L196) is stated correctly; the line drift
  note is right. §4.2 (node-side dead-man reboots) goes beyond L178 (host-sent only) — fine, but say so.

## Findings

### MAJOR-1 — §4.1's uniform template `reboot_guarded "$b0" "$slot" 1` is wrong for `fault-injection.sh:462` (and unstated for others)

**Scenario.** P5's AP restore finds the node left in a trial (`ota_boot` failed) and reboots it "back to the committed
slot" (`fault-injection.sh:447-466`; `committed` returns 1 for a trial, `:80`). With trial=1 the guard answers
`WRONG-STATE … trial=0 extra=-` on every such run, so the path that used to heal itself becomes `p5_person`
NEEDS-PERSON and blocks the later D suites on that node (`p5_person` writes `needs-person.txt`). A unit that worked
before breaks — the case the review brief asked about.
**Evidence.** `fault-injection.sh:458-463`; guard semantics `slot-guard-254.sh:24` (trial 0 = uncommitted trial).
The guard's own header (`:12-14`) says the reboot is exactly the way out of an uncommitted trial.
**Also unstated per site:** `ble-254.sh:288-297` reboots 02 *and* 04 (`:262-263`), `bt-uart-305.sh:52-63` is "back onto
the committed slot" and may meet a trial; neither has a stated trial argument. `fault-injection.sh:503` (`sleep 2;`
inside `setsid sh -c`) cannot "keep the delay inside the guarded command": `_sg_cmd` (`:48-52`) has no hook before the
reboot, and wrapping the whole guard in `setsid … >/dev/null` loses the `SENT` the caller must check.
**Fix.** Replace §4.1's one-line template with a per-site table: site, node (02/04), expected trial state and why,
slot source, boot8 source (`ble`/`bt305` read full UUIDs: `${b0:0:8}`), reason string (prov-misc L3 needs
`prov-dv-254`, `prov-misc-254.sh:163`), ordering with commands before it (see MAJOR-2), delay (drop it: the guard
already backgrounds the reboot with fds closed, as `prov-254.sh:480` does today), and the non-SENT action. FI:462 =
trial `0`; decide `any` vs `1` for ble / bt305 with a reason.

### MAJOR-2 — `prov-overlay-wipe-254.sh:25`: `firstboot -y` followed by a refusing guard leaves 04 wiped, up and possibly unreachable

**Scenario.** Today: `q "firstboot -y …; (batman-slot reboot committed …&)"` — wipe and reboot in one command, 96 restores
from p5 on the next boot. After §4.1 as written, the command becomes `firstboot -y; <guard>`. If the guard refuses
(armed flag that will not disarm, word 5 unanswered, boot/slot mismatch), the upper is already wiped on the live system
(the running dropbear's `authorized_keys` and host keys live in the upper) and no reboot follows; `pr_find 900` times
out, `pr_abort` then tries to reach a node whose lab-key login may be gone (the unit itself guards the opposite risk at
`:18-22`). That is "leaves the lab broken", and it is new.
**Evidence.** `prov-overlay-wipe-254.sh:19-26`; guard order `slot-guard-254.sh:47,52` (the extra condition and DISARMED
run before the action, so `firstboot` cannot be passed as "extra" either: it would run before the disarm check).
**Fix.** Check first, act second, in one boot-bound command: e.g. a guard variant with a `pre-action` that runs only
after every check (boot, slot, trial, DISARMED) passed — `… then firstboot -y >/dev/null 2>&1; (batman-slot reboot …&); echo SENT` —
and an offline test (extracted command, stub node with `STUB_DISARM_FAIL=y`) that shows `firstboot` is NOT run on
WRONG-STATE. Negative control: the naive `firstboot -y; <guard>` FAILs that test.

### MAJOR-3 — §3 p5 unmount: `cfgsave-mnt` is the product's **rw** save mount, the harness patterns are incomplete, and the ordering vs the config-save lock is not stated

**Scenario.** The design calls `*cfgsave-mnt.*` and `*autocommit.p5*` "product, read-only mounts" and argues "no umount of
an unknown mount: that could be a product save in progress". But `cfgsave-mnt` *is* the save in progress:
`batman-config-save:358-366` mounts p5 rw there for `--save`. If the new unmount ran before `lock_take`, it could
unmount a live save between two file operations (umount succeeds when no file is open at that instant) and
config-save would go on writing into the bare tmpfs directory: a silently lost save. It is safe only while prov-base
holds the config-save lock (`node/prov-base-254.sh:43-62`, taken at `:218` before the check at `:219`), because then any
`cfgsave-*` mount belongs to a process that no longer holds the lock. `autocommit.p5` (`batman-autocommit:433-435`,
`-o ro`, not under that lock) is a few-ms mount of a *running* autocommit; unmounting it mid-check makes
`expected_in_mesh` return "not expected" (fail-open). The restore runs on committed nodes, but the same node script is
also run by chain1's dead-man (`chain1-254.sh:146`) and `fresh-254.sh:129,146`, whose trial state the design does not
discuss.
The harness's own temp mounts are not only `pbm.*`: `p5ro.` (`node/prov-base-254.sh:95`), `p5w.` (`:270`), `p5k.`
(`prov-overlay-wipe-254.sh:21`, `prov-sshkeys-cut-254.sh:57`), `p5d.` (`prov-downgrade*-254.sh`), `p5s.`
(`prov-lib-254.sh:68`), `ch1.` (`fresh-254.sh:45`; restore_all already unmounts those itself at `:129`). Other product
p5 mount names exist (`cfgsave-ro` `batman-config-save:301`, `/mnt/cfgpart` 96-migrate, `/tmp/p5-chanfix.*`
99-chanfix, `/mnt/p5seed.$$` `batman-slot:630`); they correctly stay "unknown → NEEDS-PERSON".
**Fix.** (a) Correct the premise in §3 and §9. (b) State the order: unmount only after `lock_take`, and only `cfgsave-*`
whose owner is gone (no live `batman-config-save` process, as `chain1-254.sh:175` checks). (c) Do not touch
`autocommit.p5.*` while a `batman-autocommit run` is alive; otherwise wait a few seconds and re-read (it is transient).
(d) Harness pattern = everything under `/tmp/run/batman-dv/` (DVD, `node/prov-base-254.sh:34`), not `pbm.*` only.
(e) Anchor product patterns to `$RUNDIR/` (plus the `/tmp/<name>.` fallback of `tmpd`) and require the device field to
be `/dev/mmcblk0p5`. (f) Offline test cases: a live `cfgsave-mnt` (holder alive) → named, not unmounted; a dead one → unmounted.

### MAJOR-4 — The lint extension: blind to forms in its own new scope, cannot check the node-side conversions, and its negative control is mis-stated

**Scenario / evidence.**
1. The new regex `batman-slot[[:space:]]+["']?(rollback|commit|reboot)` misses the forms used in `scripts/node`:
   `"$BS" rollback` (`node/prov-rbarm-254.sh:48`) and `"$R/usr/sbin/batman-slot" commit` (`node/prov-rbarm-254.sh:54`,
   `node/prov-rbfix-254.sh:24`) — the quote sits *after* the name. Bringing `scripts/node` into scope while these real
   slot-changing calls stay invisible gives false assurance.
2. After §4.2 the node dead-man lines still contain the literal `batman-slot reboot committed` (`ble-central-254.sh:102`,
   `ble-periph-254.sh:197`, `bt-uart-305.sh:297`, and `chain1-254.sh:156` which the design does not mention). They must be
   allowlisted, and an allowlist line only proves presence — nothing checks that the disarm + `bf_get` actually precedes
   the reboot. The chain1 dead-man has a real extracted-run test (`test-slot-guard-254.sh:174-190`, incl.
   `STUB_DISARM_FAIL`); the three new ones get none.
3. "The extended lint on b885a2c FAILs and names exactly the sites of §0" is false. Running the proposed regex over the
   proposed scope also hits `chain1-254.sh:156`, `node/prov-p9-254.sh:54`, `node/prov-rbarm-254.sh:61` (texts),
   `negctl-old-slot-254.sh:33,36`, `ab-selftest.sh:370`. The design's allowlist names only three text lines.
4. Lint (2) pins guarded sites with `((rb|reboot|release)_guarded|_sg_cmd)` (`test-slot-guard-254.sh:320`): the new
   `commit_guarded` (§4.3) would be unpinned unless that regex changes.
**Fix.** Regex covering `batman-slot["']?[[:space:]]+["']?(rollback|commit|reboot)` and `\$\{?BS\}?"?[[:space:]]+(rollback|commit|reboot)`
(or: any word `rollback|commit|reboot` following an expansion that ends in `batman-slot`); allowlist rbarm / rbfix with
reasons; give the node dead-man reboots one shared function (or extract and run each like the chain1 test, with
`STUB_DISARM_FAIL`); state the exact expected hit list of the b885a2c run; extend lint (2) to `commit_guarded`.

### MAJOR-5 — §3's device proof cannot run on the current bench, and other units still require 02 on A

**Scenario.** The only caller that restores 02 through `pr_restore_cycle` is `prov-netjoin-fleet-254` (`restore02`,
`:74-87`). That unit refuses up front unless 02 is **legacy** (`prov-netjoin-fleet-254.sh:107-110`: "the bench S0 is an
N0 member now (254-h4 §3.1) … refused up front, 02 untouched"), so on today's member bench it ends INVALID before
`pr_begin` and never reaches the restore. The §3 device run ("netjoin-fleet with 02 on B committed") therefore proves
nothing; the wsl.16 event was on a legacy 02. Meanwhile §8's plan puts 02 on B on purpose ("02 lands on B by itself after
the second wsl.37 OTA") and claims "02's slot no longer matters", but:
`prov-ac-fleetchan-254.sh:25` FAILs its precondition unless 02 is A committed (part 1 OTAs 02 into B), `:71` expects
02 on A at the end, and `pr_peer_after` (`prov-254.sh:608`) only downgrades a 02 reboot to WARN when 02 is "A 1". So the
wsl.37 full validation would FAIL fleetchan for a reason this PR creates.
**Fix.** Reality-check 02's prov state read-only before v2 and say which vehicle proves §3 on a device (or mark the 02
path ⚠️ offline-only). Either normalise 02 to A before the run (as `pr_normalise` does for 04; `prov-bench-s0-254.sh
slota 02` exists) or make fleetchan and `pr_peer_after` slot-aware; add both to the lifecycle matrix row "node starts on B
committed".

### MAJOR-6 — Merging §2 before wsl.37 breaks the wsl.36 device runs the design relies on

**Scenario.** After the merge, `helpers.list` names `misc-l38r`, but the wsl.36 wbox set has no
`V.dirty.wbox-misc-l38r`. `dv-prov-tools.sh <wsl.36>` then FAILs (`:48` `file_of … || continue` counts a `no`, and
`:73` "read $m misc variants of $wantm"), and in `prov-misc-254` the `l38nega` arm calls `bindac misc-l38r` →
`no "no verified misc-l38r autocommit"` (`prov-misc-254.sh:33`) → `dr` returns 1 → `dryarms` fails →
`pr_abort "dry-run arms"` (`:168`). `svcarms` and L3 — the converted reboot at `prov-misc-254.sh:160` that §4 needs to
prove on a device — never run. §8 says misc runs on wsl.36 "except l38nega", but nothing implements that exception.
**Fix.** Make the arm conditional on the tools: no `misc-l38r` for this V → the arm is reported NOT-JUDGED (never PASS,
counted in `notjudged`) and the unit goes on; `dv-prov-tools.sh` reports a missing variant for a V built before it as
such (or takes the list from the V's own pin). Negative control: on wsl.36 tools the unit still runs svcarms and L3 and
prints l38nega NOT-JUDGED; with the tools present the arm runs.

### MINOR-1 — ac-flap step 4 samples a file the product overwrites every poll

`autocommit.why` is rewritten each 10 s poll (`batman-autocommit:597`) and alternates between "svc batman-provhelper down"
and "batman-provd not stable …" as the helper respawns. "Never seen = FAIL" is a sampling bet with no measured duty
cycle; wsl.35 recorded no `why` samples, so the offline "fed the wsl.35 boot … PASSes" fixture for step 4 would be
synthetic, not captured. Use a deterministic product record as well (`otalog AC UNHEALTHY first_why=`, `:581`; the
`TRIAL-REVERTED … reason=` line already judged in step 6), or count the helper's down windows and justify the bound.

### MINOR-2 — The E-H5 #2 claim used to justify dropping the dry run is false at b885a2c

§1 says the time-to-decision "is measured by `prov-autocommit-p3-254` on a healthy trial". Its `dry()` (`prov-autocommit-p3-254.sh:26-32`)
has no `+Ns` stamps and prints no timing; ac-flap (`prov-ac-flap-254.sh:32-35`) was the only collector. E-H5 #2 is still
an open checklist item (`254-h23-harness.md:989-993`, "pre-commit canary time on an OTS node"). Add the stamps to p3's
AC1, or record the item as no longer collected.

### MINOR-3 — Product-equality check for wsl.37 is too narrow

`git diff b885a2c <main> -- feed/` empty does not prove the image is unchanged: feed packages install files from outside
`feed/` — `deploy/ots/*` (15 refs) and `scripts/verify-profile.sh` (`feed/batman-payload-host/Makefile:156-184`). Diff
those paths too (better: list them from the Makefiles in the check). Also state whether wsl.37 is driven by l38r alone or
by PR B as well; if only by l38r, the owner could instead let `dv-prov-tools.sh` derive misc-* autocommits by applying the
patch to V's own release autocommit (verified to apply cleanly and to carry the witness) — no product rebuild, at the
cost of the §17.2 "from the -wbox payloads only" provenance. That is the owner's call; the design should present it.

### MINOR-4 — §6 changes a helper 25 tests share to fix one test

Stopping the feeder when `f` completes removes the implicit check that frames arriving after the end are harmless (the
old helper kept feeding ~1 s after completion; an exception there would surface as an uncaught zone error). No current
assertion depends on post-completion frames (checked: `signs`, `disposed`, `errors` are all set before completion), so it
is not a lost assertion, but it is lost exercise. Prefer measuring `f` directly in the D-2 test (time to `f`'s
completion, feeder left as is), or keep feeding after `f` completes and only exclude it from the time.

### MINOR-5 — pty-commit `stop()` after a failed settle has no recorded boot

`settle || { LANDED=1; stop …; }` (`pty-commit-254.sh:59`) reaches `stop()` before any state line of the landed boot is
read, so "the boot recorded when the trial landed" does not exist there → `commit_guarded` refuses → the deadline revert
leaves bad-slot (the very review-M3 case `stop()` exists for). Record the boot in `waitboot`, or read it in `stop()` and
bind to it with trial=0.

### MINOR-6 — Leaving a trial: prefer `reboot_guarded <boot> <slot> 0` over `rb_guarded`, and handle REFUSED

`batman-slot rollback` runs `rollback_lock_gate` (`batman-slot:994-1006`, mounts the other slot's squashfs, can die on a
claimed node) and `slot_is_bad`; `prov-chain0-254.sh:85-86` already had to fall back to a reboot on REFUSED. For an
uncommitted trial the one-shot tryboot makes a plain guarded reboot the simpler, product-defined exit
(`slot-guard-254.sh:12-14`). If rollback is kept, REFUSED must fall back to `reboot_guarded … 0`, not NEEDS-PERSON.

### MINOR-7 — Node-side dead-man failure path unspecified

§4.2 says "prepend the disarm + bf_get check" but not what happens when the flag will not clear. chain1 keeps
`ch1.running` for a person (`chain1-254.sh:151-152`). For the BLE dead-man the reboot is a security action (a leaked IRK,
`ble-central-254.sh:98-103`): state that the `irk-exposed` mark stays, how the next preflight sees it, and that the lease
is not silently dropped (`rm -f "$BT/lease"` currently precedes the reboot).

### MINOR-8 — Ownership: DISARM is a write to the product-owned tryboot flag

§7 says "no new writer". Every guarded rollback / reboot clears the tryboot flag (`slot-guard-254.sh:33,47`); this PR adds
~15 such writes, three of them unattended on the node. State it: the harness clears the flag only under its lease, and the
node dead-man only after its own lease was lost (a product-armed tryboot of a concurrent OTA would be cancelled).

### MINOR-9 — Platforms and wording

- `fault-injection.sh` also runs on a Pi 3 (`daily-validation.sh:403-412`, R3/R4). The converted FI sites are P5 only
  (OTS node, Pi 4), but on a Pi 3 `DISARM` reads `unknown` and every guarded reboot is WRONG-STATE. Say so in the
  platform row.
- "CI `test-h4-offline-254.sh`": it is not in `.github/workflows`; it is the daily-validation suite `harness-h4-254`
  (`daily-validation.sh:210`). Only `misc-dry.sh` runs in CI (`ci.yml:61`).
- §4's title "Every host reboot … is guarded" overclaims: plain `reboot -f` (`chain1-254.sh:189`,
  `prov-bench-s0-254.sh:425`, deliberately into an armed tryboot), sysrq (`prov-base-254.sh:63`,
  `prov-sshkeys-cut-254.sh:105`) and Shelly cuts stay unguarded by design. Say "every `batman-slot` rollback / commit /
  reboot", and list the deliberate others.

### MINOR-10 — Converted sites are proven by lint (presence) only

Per the owner's rules a presence check is not a test. Sites with non-trivial semantics need an extracted run against
the stub node, as `test-slot-guard-254.sh:115-160` does for s0 / chain0 / brewrite / back_to_a: FI:462 (trial path),
overlay-wipe (ordering, MAJOR-2), pty-commit `stop()`, `pr_restore_cycle` (planned), and each node dead-man.

### MINOR-11 — Lifecycle matrix gaps

Missing rows: harness merged but node on the previous image (wsl.36 tools without l38r — MAJOR-6); dependency restart
(02 reboots by joinwatch while 04 restores; 02 on B — MAJOR-5); ssh dropped after `SENT` (the caller says FAIL while the
node rebooted — fine, but say the restore then runs in the new boot and why that is safe); crash of the node-side
p5-restore between `umount` and `dd` (lock held by a dead holder: the next run's `lock_take` dies "busy" — who clears it).

## Summary table

| # | Sev | Area | One line |
|---|---|---|---|
| 1 | MAJOR | §4.1 | trial=1 template breaks FI:462's trial exit; per-site table needed (ble/bt305 trial, FI:503 delay) |
| 2 | MAJOR | §4.1 | overlay-wipe: `firstboot -y; <guard>` → wiped, unrebooted, possibly unreachable node on a refusal |
| 3 | MAJOR | §3 node | `cfgsave-mnt` is the rw save mount; unmount only under the lock with a dead owner; harness names ≠ `pbm.*` only |
| 4 | MAJOR | §4.4 lint | misses `"$BS" rollback` / `batman-slot" commit`; node dead-man unchecked; "exactly §0" false; `commit_guarded` unpinned |
| 5 | MAJOR | §3/§8 | netjoin-fleet INVALIDs on a member bench; fleetchan / `pr_peer_after` still need 02 on A |
| 6 | MAJOR | §2/§8 | on wsl.36 dv-prov-tools FAILs and prov-misc aborts at l38nega before L3 |
| 7 | MINOR | §1 | `autocommit.why` sampling unbounded; wsl.35 has no why samples for the offline fixture |
| 8 | MINOR | §1 | E-H5 #2 not measured by prov-autocommit-p3 |
| 9 | MINOR | §8 | `-- feed/` diff misses `deploy/ots`, `scripts/verify-profile.sh`; rebuild alternative not presented |
| 10 | MINOR | §6 | shared probe helper changed for one test |
| 11 | MINOR | §4.3 | pty-commit stop after failed settle has no boot |
| 12 | MINOR | §3 | prefer reboot_guarded … 0 to leave a trial; handle REFUSED |
| 13 | MINOR | §4.2 | dead-man failure path (IRK) unspecified |
| 14 | MINOR | §7 | DISARM is a flag write; ownership row wrong |
| 15 | MINOR | §8/§9 | Pi 3 refusal, "CI" wording, §4 title overclaim |
| 16 | MINOR | tests | converted sites proven by lint only |
| 17 | MINOR | §8 | lifecycle rows missing |

(Findings 7-17 are MINOR-1 … MINOR-11 above, in order.)
