# Review A, round 3: `docs/design/254-v16-group4.md` v3 (harness PR A)

Reviewer: A (independent, adversarial). Tree `C:\src\Batman-g4h`, HEAD 6075463 (= main b885a2c + the design; nothing
under `scripts/`, `feed/` or `tests/` differs). The whole v3 was read, not only the delta, together with the v1 and v2
reports and `v16g4-sites.md`.

Method: read-only `grep` / `sed` / `git show` at b885a2c. I also ran three scratch experiments in my own temp dir (no repo
file touched):
- `git apply` of the four misc patches against `git show b885a2c:…/batman-autocommit`, outside any repository;
- the same run inside a subdirectory of a throwaway `git init` repository;
- the lint (3) regex over the lint (3) scope.

I read `gh issue view 254` (body only), and `Desktop/Batman/v16/g4/ota36.log`. No ssh, no harness script, no node touched.

**Verdict: REJECT (revise to v4, then re-review the whole document).** No BLOCKER.
- Most v2 findings are really resolved:
  - the removal of v2 §3.2 is justified;
  - the 02 check sits in the right place;
  - the `helpers.list` format stays unchanged;
  - the `reboot_and_wait` precheck is sound in principle;
  - `<pre>` keeps today's ordering;
  - the dead-man behaviour tests are specified.
- Three new MAJOR problems remain, each with a local fix:
  - **M1.** `derive_misc` on the real host (Git Bash) writes a CRLF mutant that every downstream check accepts. Inside a
    git work tree it silently writes nothing. CI (Linux) cannot see either.
  - **M2.** The lint (3) group model does not fit the regex. Its negative control cannot behave as stated.
  - **M3.** The p5-restore negative control on main cannot produce "plain die", and as written it would `dd` to the
    test host's `/dev/mmcblk0p5`.

## v2 findings: resolution check

| v2 finding | v3 | Status, with evidence |
|---|---|---|
| A M1 / B M1 (`PR_LAND_BOOT`, double acquire) | v2 §3.2 removed | ✅ The removal is justified: the only observed trigger (ac-flap) now goes through `pr_wait_reverted`, which already re-finds the node (`prov-254.sh:433-436`). A held trial past its deadline in another unit ends in NEEDS-PERSON, the same as today. ⚠️ v3 says the case "is recorded as an open line in #254 L116". The issue body at line 116 (`gh issue view 254`) is the p5 / A-slot line and says nothing about a product reboot or a held trial past its deadline. Not yet recorded (m9). |
| B m11, m12, A m5 | moot | ✅ |
| A M2 / B M3 (P9 timing, `PR_V`, raw rollback) | §3.1 | ✅ After the 12 × 10 s retry (`prov-254.sh:667`) and after `PR_V` (`:664`), before `pr_acquire` (`:671`). The remedy names `slota` / `toa`, which exist for 02 (`prov-bench-s0-254.sh:6-9`). ⚠️ The remedy does not fit every failing state (m7). |
| A M3 / B M2 (`host` kind) | §2: format unchanged, branch on `misc-` | ✅ `dv-prov-tools.sh:47` already branches on the name. Firmware readers are unaffected; `misc-l38r release same` is a valid row for `check-prov-test-gate.sh:126-131`. ⚠️ The owner decision on the provenance change (`dv-prov-tools.sh:2-3`, "taken from the -wbox payloads of rc V and nothing else") is still not recorded (m6). |
| A M4 / B m9 (lint pattern 2) | §4.3 inventory lint (3) | ⚠️ New problems (M2). |
| A M5 / B M6 (false trybootget premise) | §4.2 precheck in `reboot_and_wait` | ✅ The premise is corrected. The check is implementable: `chk_trybootget_209` is already an `fssh` (`daily-validation.sh:740-756`), and `reboot_and_wait` already calls `fssh`/`bootid` (`:2291-2306`). Timings are unchanged: cleanstop's ≤ 90 s and k08 / k09 are measured on the node (`:2445-2450`, `:2672`), not from the host's `t0`. ⚠️ m1, m2, m3. |
| B M4 / A m1 (derivation test, fuzz, CI) | §2 `git apply`, `test-derive-misc.sh` | ⚠️ `git apply` is the right tool. It is wrong in two host conditions (M1). A m1's "diff of result vs base = the patch's −/+ lines" check was dropped; it would have caught M1. B M4's patch blob id record was dropped without a word (m6). |
| B M5 / A m4 (dead-men untested, row 42, Pi 3) | §4.2 rows 36–38 extracted runs; row 42 allowlisted | ✅ The test is specified. ⚠️ The security statement is changed by it (m5). Pi 3 consistency: m1. |
| A m2 / B m7 (`pre=`) | §4.1 6th positional, today's ordering | ✅ In principle. ⚠️ The output and sentinel details are unstated (m8). |
| A m3 / B m8 (seam vs root, one dir, `p5h.`, lock) | §3.2 | ✅ The root check is kept, the match is on the `/tmp/run/batman-dv/` prefix, and the dies are wrapped in `lock_drop`. ⚠️ Not every harness mount is under the prefix (m4), and the negative control is broken (M3). |
| A m6 (counts, naming, bench evidence) | inventory; `prov-normalise-254`; `ota36.log` | ✅ `ota36.log:29` shows `10.41.85.110 … wsl.36 … active=A … trial-rc=1`. The node name is not given next to the IP; add it. ⚠️ The "about 120 text rows" figure is off (M2). |
| A m7 (Pi 3 inconsistency) | §4 Pi 3 rule | ⚠️ Still inconsistent, by a different route (m1). |
| B m10 (prov-misc aborts on missing tools) | §2 up-front check | ✅ |

## Findings

### MAJOR-1: `derive_misc` + `git apply` on the Windows host writes a CRLF mutant that every downstream check accepts; inside a git work tree it writes nothing

**Scenario (real use).** The release gate runs `dv-prov-tools.sh <V>` from Git Bash (`dv-prov-tools.sh:12`: "Runs from
Git Bash (or WSL)"). Git for Windows ships `core.autocrlf=true` in its system config. Outside a repository the repo's
`.gitattributes` (`* text=auto eol=lf`) does not apply. So `git apply` writes the patched file with CRLF line
terminators.

**Evidence (my scratch run, Git 2.53.0.windows.2):**

```
$ git config --show-origin --get-all core.autocrlf
file:C:/Program Files/Git/etc/gitconfig	true
$ cd <scratch>/t && git apply …/tests/wbox/misc-l38.patch; echo rc=$?
rc=0
$ file orig.ac t/feed/…/batman-autocommit
orig.ac:            POSIX shell script, … executable, with very long lines (307)
t/feed/…/autocommit: POSIX shell script, … with very long lines (307), with CRLF line terminators
$ od -c t/feed/…/batman-autocommit | head -1
0000000   #   !   /   b   i   n   /   s   h  \r  \n   #       b   a   t
```

With `git -c core.autocrlf=false apply` the same run gives LF, and the diff against the base is exactly the patch's 1 +
1 lines (sha `4abcc3d4…`).

What then happens downstream:
- Every check in `dv-prov-tools.sh` that §2 keeps accepts the CRLF file:
  - the witness grep (`:50`);
  - differs from release (`:51`): trivially, every byte line differs;
  - differs from the others (`:52`).
- The mutant is then bound on 04 as a `#!/bin/sh\r` script. Every prov-misc arm that uses it runs a broken autocommit.
  - At best the result is FAIL or INVALID for the wrong reason.
  - At worst an arm that *expects* the mutant to misbehave sees "misbehaviour" that comes from `\r`, not from the
    mutation. That is a negative control that passes vacuously: the "test that can no longer fail" case.
- The CI test `test-derive-misc.sh` runs on Linux (no `autocrlf`), so it can never see this.
- The one-time wsl.36 equivalence proof would catch it, but only if it is run from Git Bash, and only once.

**Second trap (scratch run).** Inside any git work tree, `git apply` only patches paths below the current directory. A
file outside it is skipped silently with rc 0:

```
$ cd <tmp-repo>/sub && git apply -v …/misc-l38.patch; echo rc=$?
Skipped patch 'feed/batman-provision/files/usr/bin/batman-autocommit'.
rc=0
```

`git apply --check` also gives rc 0 there. If the scratch dir, `$TMPDIR` or `$DEST` ever lies inside a checkout, "applies"
means "did nothing". (The witness check would catch this one, but the design asserts that `git apply` gives "applies"
one meaning, and it does not.)

**Fix.**
- **The apply command.** `derive_misc` runs
  `git -c core.autocrlf=false -c core.eol=lf -c core.safecrlf=false apply --check` and then `apply`, in a fresh `mktemp -d`.
  First it asserts `! git -C "$scratch" rev-parse --is-inside-work-tree 2>/dev/null`.
- **Post-conditions,** each a FAIL:
  - no CR byte in the output;
  - `diff <base> <out>` equals the patch's own −/+ lines (v2 A m1);
  - `busybox sh -n` (or `sh -n`) on the output.
- **Where the test runs.** Run `test-derive-misc.sh` on the host as well, inside the daily-validation harness suite next to
  `test-h4-offline-254.sh`, not only in `ci.yml`.
- **Negative control:** the same derivation with `git -c core.autocrlf=true apply` must FAIL on the CR check, on Linux too.
  The control in a work tree must FAIL on the "inside a work tree" assertion.

### MAJOR-2: lint (3)'s groups do not fit its own regex, so the negative control cannot behave as stated, and substring rows can hide new real lines

**Evidence.**

1. **`guarded` rows can never have a hit.**
   - The pattern is `\breboot\b|sysrq-trigger|reboot_and_wait`. In `reboot_guarded` / `rb_guarded`, the `_` after
     `reboot` is a word character, so a guard call line is not a hit unless it carries other "reboot" text.
   - Today's guarded lines confirm it. `fresh-254.sh:117`, `:149` and `prov-chain0-254.sh:82` are not hits. Only
     `prov-chain0-254.sh:86` is, through its message text "reboot not sent".
   - So after the conversion, rows 1–10 and 19 (`q "$(reboot_guarded "$b0" A 1 prov-dv-254)"`) are not hits. A
     `guarded` inventory row for them has no hit, and "a row with no hit is a FAIL" makes the fixed tree FAIL.
   - The alternative is that the group is empty, and then "set of FAILs = guarded / prechecked rows" is meaningless.
   - The node dead-men (36–38) still hit (`batman-slot reboot committed …`). But their DISARMED prefix sits on other lines
     (as at `chain1-254.sh:151-152`), so the rule "the line must contain a guard call" cannot hold for them either.
2. **`prechecked` cannot fail on b885a2c.** The precheck is added *inside* `reboot_and_wait`. The call-site lines
   (`daily-validation.sh:2322,2340,2355,2481,2631,2656,2667,2680`) are byte-identical before and after, so they match
   their inventory rows on b885a2c. Lint (3) therefore gives no negative control for the precheck, and nothing pins it:
   deleting the GET from `reboot_and_wait` later passes every lint. "Inside `reboot_and_wait`" also needs function-scope
   parsing, which a line inventory does not have.
3. **The substring semantics are unspecified, and multiplicity is ignored.** A row is "file + a substring of the line". A
   short substring, for example `echo "` or `reboot_and_wait "$n" reboot`, matches any future line containing it in that
   file. Copying an allowlisted line (`q '(sync; reboot) </dev/null >/dev/null 2>&1 &'`) to a new place passes silently.
   This is v2 A M4's "hides new real lines in those files", carried over unaddressed.
4. **The scope is self-referential and undefined.**
   - `scripts/dv` contains the inventory itself (`scripts/dv/data/slot-sites.tsv`, whose rows contain "reboot"). It
     also contains `data/p3-units.tsv` (1 hit) and `test-*.sh` (24 hits), including the lint's own regex in
     `test-slot-guard-254.sh`.
   - The design says neither whether these are excluded nor how.
   - Measured at HEAD: **172 non-comment hits outside `test-*`** (196 with them). `daily-validation.sh` alone has 44.
     That is not "about 120 text" rows.

**Fix.**
- **Row shape.**
  - A row is `file <TAB> exact line text (trimmed) <TAB> group <TAB> count`, matched exactly.
  - The number of identical lines in the file must equal `count`.
  - Line numbers are not used, so edits elsewhere do not churn the file.
- **Scope.** Exclude `test-*.sh` and `scripts/dv/data/slot-sites.tsv` by name, and say so. Other non-`.sh` files in scope
  get rows like any file.
- **Groups.**
  - Drop `guarded` from lint (3). Guard calls are pinned by lint (2); state that a converted site leaves lint (3) and enters
    lint (2).
  - `prechecked` becomes `calls-reboot_and_wait`.
  - Add a lint (2) pin for the GET line inside `reboot_and_wait`, so removing the precheck FAILs.
- **Negative control.**
  - Generate the expected FAIL set by actually running lint (1)–(3) on b885a2c with the new inventory and lint-(2) table.
  - Commit that list to `v16g4-sites.md`.
  - The list must contain:
    - the unmatched old lines of rows 1–10, 13, 15, 19 and 36–38 (lint 3 / lint 1);
    - the "pinned line missing" lines for every new `reboot_guarded` / `commit_guarded` / precheck pin (lint 2).

### MAJOR-3: the §3.2 negative control "main → no names, plain die" cannot be produced, and as written it reaches the test host's `/dev/mmcblk0p5`

**Evidence.**
- On main, `PB_MOUNTS` and `PB_P5` do not exist. The script reads the host's real `/proc/mounts` and writes the
  hard-coded `P5=/dev/mmcblk0p5` (`scripts/node/prov-base-254.sh:33,218-221`).
- The test host (WSL, CI) has no p5 mount line. So main does **not** die at `:219`:
  - it takes the lock;
  - it runs `dd if="$D/p5.img" of=/dev/mmcblk0p5 … conv=fsync` as root (`:220`);
  - it prints `P5-RESTORED`.
- Consequences:
  - In WSL or CI, that `dd` creates a regular file in `/dev`.
  - On a Linux machine with a built-in SD reader, the card's partition 5 is overwritten.
  - In no case does the control show "no names, plain die", so it does not discriminate as claimed.
- The design's stated aim ("`/dev` is never reached", §3.2) holds for the new code only, not for the control run of the
  old code.

**Fix: run both main and the fix in a mount-namespace sandbox instead of an env seam.** This also removes the `PB_*` /
`PATH` inputs from a root node script, which shrinks the attack-surface delta of §9.
1. `unshare -m --propagation private sh -c '…'` as root (CI already has `sudo`, `ci.yml:138-139`; WSL tests run as root).
2. `mount -t tmpfs none /dev` and then `: > /dev/mmcblk0p5`, so p5 is a regular file in the sandbox.
3. `mkdir -p /tmp/run/batman-dv/pbm.T && mount -t tmpfs /dev/mmcblk0p5 /tmp/run/batman-dv/pbm.T`. A tmpfs takes any
   source string, so `/proc/mounts` shows a real `/dev/mmcblk0p5 /tmp/run/batman-dv/pbm.T tmpfs …` line, and the real
   `umount` works.
4. For the non-harness cases, mount the same way at `/tmp/run/batman/cfgsave-mnt.X`. A "busy" case holds a file open in
   the mount.

Main then dies at `:219` with "p5 is mounted" (the plain die, no name). The fix unmounts and names. Nothing can reach a
real device. If the `PB_*` seam is kept anyway, the control on main must still run inside such a sandbox. Say so.

### MINOR-1: the Pi 3 rule is still not consistent across the 42 rows

- **The precheck has the same word-5 dependency as the guard.**
  - `chk_trybootget_209` refuses unless word 2 = `0x80000000` **and** word 5 = `0x80000004` (`daily-validation.sh:748`),
    exactly as `DISARM` does (`slot-guard-254.sh:33`).
  - So rows 24 and 31 (DNODE, any SoC: `:2691`, `:2697` are not SoC-gated) fail closed on a Pi 3 exactly as a guard would.
  - "Not converted to a guard, it is prechecked" therefore buys nothing on a Pi 3; the §4 text presents it as the Pi 3
    answer.
- **Rows 1 and 7 run on a node that can be any SoC by code, yet they are converted.**
  - `adr-reconcile-254` and `prov-claim-254` run on `DNODE0` with no SoC gate (`daily-validation.sh:351-356`;
    `claim-lock-254.sh:41-43`; `DNODE0=${DESTRUCTIVE_NODE:-${OTS_NODE:-$MESH_NODE}}`, `:130`).
  - The §4.2 claim "All of these are Pi 4-only units" is not evidenced for these two.
- **Rows 11 and 12 are allowlisted "because they can run on a Pi 3".**
  - The same function already calls `rb_guarded … p5-back-to-A` on the same node (`fault-injection.sh:575`), which refuses
    on a Pi 3. Allowlisting rows 11 and 12 buys no Pi 3 function.
  - Meanwhile it leaves the release gate's Pi 4 `MESH_NODE` (02 or 04) with a plain `batman-slot reboot committed` on P5's
    error path. `p5_ap_back` is entered after an OTA that may have timed out (`:455-458`), and an armed flag there is
    #254 L178's hazard (`batman-slot:1036-1039`: an armed flag gives a plain reboot into the tryboot slot).

**Fix.** Pick one rule and apply it to every row.
- **Option (a).** "A Pi 3 is not supported (P-U14). Guards and prechecks fail closed there by design, with the line
  named." Then convert rows 11 and 12 (as v2 did) and give row 42 the bcm2711 condition.
- **Option (b).** SoC-aware everywhere: bcm2837 → today's plain behaviour, documented.

### MINOR-2: row 30 is prechecked, not allowlisted

`bchk_unclean_274` reboots through `reboot_and_wait "$n" 'sync; reboot -f' 300` (`daily-validation.sh:2631`). The
precheck therefore applies to it. That is a good thing (`reboot -f` honours an armed flag; a real power cut does not).
But §4.2 lists row 30 under "Allowlisted: a deliberate power-loss proxy", and lint (3)'s definition puts any caller of
`reboot_and_wait` in `prechecked`. Move row 30 to the prechecked row and state the change in behaviour (an armed flag now
FAILs unclean-boot-274 before the `reboot -f`).

### MINOR-3: the precheck is a separate ssh: a new spurious-FAIL point, a TOCTOU, and no lasting mark

- **A new spurious-FAIL point.** `chk_trybootget_209` is one `fssh … 12` with no retry. A transient ssh timeout right
  before cleanstop or hold-274 now FAILs the suite as "not answered — not rebooting". Today the only pre-trigger ssh is the
  `bootid` read.
  - Distinguish "ssh failed" (rc 255 / 124) from "firmware did not answer" and from "armed".
  - Retry the GET once.
- **A TOCTOU.** The GET and the trigger are two sessions.
  - Fold the check into the trigger command: `<GET check> || { echo PRECHECK-REFUSED; exit 3; }; <cmd>`.
  - Keep #270's rc evidence readable: rc 3 plus the marker means refused, rc 255 means cut.
- **No lasting mark.** An armed flag on DNODE is not a one-suite problem. The next harness or product reboot of that node
  enters the trial.
  - Write the NEEDS-PERSON line that `dnode_blocked` reads, as `p5_person` does (`fault-injection.sh:454`), so later D
    suites do not run on top of it.
  - Otherwise faketime, guardian and ramoops each FAIL separately with the same root cause.

### MINOR-4: not every harness p5 mount is under `/tmp/run/batman-dv/`

`chk_202` mounts p5 at `/mnt/dv-p5` (`daily-validation.sh:2127-2129`), inside `fssh "$1" 20`. A timeout between its
`mount` and `umount` leaves a mount that the new p5-restore names, which ends in NEEDS-PERSON. That is fail-closed, so the
only harm is a person's time, but §3.2's premise "every harness p5 mount is a `mktemp -d` there" is false. Move `chk_202`'s
mountpoint under `/tmp/run/batman-dv/` (mktemp) in this PR, or list it as a known exception. The other fixed-name mount,
`p5-follows-202.sh:10,22` (`/tmp/run/batman-dv/p5`), is under the prefix ✅.

### MINOR-5: the dead-men conversion changes the IRK exposure, contrary to §9

- **Today.** `role_fire_restore` on 02 always reboots when `irk-exposed` is set (`node/ble-central-254.sh:98-102`), armed
  flag or not, so the possibly leaked IRK is always voided.
- **After the change.** A failed clear means no reboot, and the leaked IRK stays live until a person acts. §9 "The
  dead-man IRK exposure is unchanged" is therefore false.
- **Ordering.** The lease and `dm` files are removed *before* the reboot (`:101`). The new no-reboot path must decide
  whether to keep them; v3 names only the dirty marker.

**Fix.** State the trade-off as an owner decision: a leaked bench IRK against an unintended trial of the other slot. Move
the `rm -f "$BT/lease" …` after the disarm decision. Correct §9.

### MINOR-6: derivation leftovers dropped without a word

- **B M4's patch blob id** (`git rev-parse HEAD:tests/wbox/<name>.patch` next to the SHA256SUMS). Without it a dirty
  harness checkout produces an unreviewed mutant silently.
- **A M3's owner decision** on the provenance change. `dv-prov-tools.sh:2-3` must also be rewritten.
- **A §8 row** for "harness newer than V / an older V". The patch may not apply to V's autocommit: that is fail-closed,
  INVALID before any arm (§2 up-front check).
- **The CI negative.** It must assert that *the named case* FAILs, and that `cases=` equals the real file's count. A
  mutant that breaks the block extraction "FAILs" vacuously (`tests/prov-p1/autocommit-mesh-arm.sh:15`:
  "prov / arm block not found" → `fails=1`).

### MINOR-7: 02 check: callers, remedy per state, control point

- `eh15-ethsim-254.sh:18` and `test-h4-undo.sh:42` call `pr_p9` directly. They never get the 02 check, which lives in
  `pr_begin`. Say whether they need it.
- The remedy `slota 02, then toa 02` fits "02 on B". It does not fit:
  - "02 on A committed with another version";
  - "02 in an A trial".

  Both tools start from "a kept node on B" (`prov-bench-s0-254.sh:6-9`). Give a remedy per state, or name the state and
  say "a person decides". Add "04 first" (`:18`, `:23`).
- The §3.1 offline control should assert "FAIL before the `pl acquire` stub", not only before the snapshot. The lease is
  the first change on the node (`prov-254.sh:671`).
- A 02 on B now FAILs ~40 prov units one by one. Consider the same check once in `prov-normalise-254`, so the run says it
  once.

### MINOR-8: `<pre>` and `-` details

- **The output.** `<pre>`'s stdout and stderr must be discarded in `_sg_cmd`, so the answer is exactly `SENT` or
  `PRE-FAILED SENT`. Today's call site does `firstboot -y >/dev/null 2>&1`, but v3 §4.1 does not say the guard does.
- **The `-` sentinel.** Today `reboot_guarded` passes `${5:-true}` (`slot-guard-254.sh:55`). A literal `-` would run
  `{ -; }`, rc 127, and answer `WRONG-STATE … extra=0` every time: a silent never-wipe for row 10. The mapping `-` → `true`
  must be in the code and in a stub case: `extra=-` with `<pre>` → SENT; `<pre>` false → `PRE-FAILED SENT`.
- `_sg_cmd`'s `$6` is already `act` (`:40`), so `<pre>` reaches `_sg_cmd` as `$7`. Name it there, so lint (2) pins the
  right text.

### MINOR-9: a removal recorded as done when it is not

§0 / "What v3 removes" says the held-trial-past-deadline case "is recorded as an open line in #254 L116, for #290". Line
116 of the issue body today is "harness: `pr_restore_cycle` 不該假設節點在 A 槽 … 中止時 p5 還原失敗要先 umount 殘留並報出"
(`gh issue view 254`). It does not mention this case. Add the line, give the link, and quote it in §10.

## Lifecycle and security, re-checked

- **Start / restart / crash.** These are unchanged except where §3.1 now stops a run before any change, which is right.
  - A harness interrupted inside p5-restore: `lock_drop` on every die (§3.2.5) ✅.
  - A harness interrupted between the precheck and the trigger: nothing has changed on the node ✅.
- **Upgrade / downgrade of V vs the harness.** Derivation against an older V needs a §8 row (m6). There are no node files.
- **Platforms.** Git Bash is the host the release gate runs on, and it is exactly where M1 bites. The design's host proof
  for `test-derive-misc` is CI only (§8 "Hosts").
- **Security.**
  - No new port, secret or privilege on a node.
  - The `PB_*` / `PATH` seam is new env input into a root node script. It is gated, and it becomes unnecessary with M3's
    sandbox.
  - The derived mutant is host content bound only in a dry run (`prov-misc-254.sh:30`) ✅.
  - IRK: m5.
  - "Our own mistakes" are the open items: M1 (a broken mutant that passes the harness's checks), M2 (a lint that cannot
    fail on the precheck and can absorb a copied reboot line), M3 (a negative control that writes a host block device).

## Summary

| # | Sev | One line |
|---|---|---|
| M1 | MAJOR | `git apply` on Git Bash (system `core.autocrlf=true`) writes a CRLF autocommit mutant that passes witness / differ checks; inside a work tree it skips with rc 0; CI (Linux) cannot see it. Force LF, assert outside a work tree, check no CR + diff = patch + `sh -n`, run the test on the host. |
| M2 | MAJOR | lint (3): guard-call lines are not `\breboot\b` hits, so `guarded` rows can never match; `prechecked` call sites are identical on b885a2c, so there is no negative and no pin for the precheck; substring rows hide copied lines; scope includes the inventory, `test-*` and the lint itself; 172 hits, not ~120. |
| M3 | MAJOR | p5-restore negative control on main reads the host's `/proc/mounts` and `dd`s to `/dev/mmcblk0p5`; it cannot show "plain die". Use an `unshare -m` sandbox (tmpfs `/dev`, tmpfs mounted with source `/dev/mmcblk0p5`) for both main and the fix, and drop the env seam. |
| m1 | MINOR | Pi 3 rule: the precheck has the guard's word-5 dependency; rows 1 and 7 run on an any-SoC `DNODE0`; rows 11 and 12 allowlisted although `:575` already refuses on a Pi 3 and the Pi 4 bench is left unguarded. |
| m2 | MINOR | row 30 (`unclean-boot`) goes through `reboot_and_wait`: prechecked, not allowlisted. |
| m3 | MINOR | precheck as a separate one-shot ssh: spurious FAIL, TOCTOU, no NEEDS-PERSON mark for an armed DNODE. |
| m4 | MINOR | `chk_202` mounts p5 at `/mnt/dv-p5`, outside the prefix: §3.2 premise false (fail-closed). |
| m5 | MINOR | dead-man DISARM failure keeps a leaked IRK live; §9 "unchanged" false; lease removed before the decision. |
| m6 | MINOR | patch blob id, provenance owner decision, older-V lifecycle row, and named-case CI assertion dropped. |
| m7 | MINOR | `pr_p9` direct callers skip the 02 check; remedy fits only "02 on B"; control should stop before `pl acquire`. |
| m8 | MINOR | `<pre>` output not discarded, `-` sentinel not mapped (rc 127 → silent never-wipe), `$6` is already `act`. |
| m9 | MINOR | "recorded as an open line in #254 L116": not in the issue body. |
