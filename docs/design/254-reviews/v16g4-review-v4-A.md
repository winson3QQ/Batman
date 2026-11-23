# Review A, round 4: `docs/design/254-v16-group4.md` v4 (harness PR A)

Reviewer: A (independent, adversarial). Tree `C:\src\Batman-g4h`, HEAD 985de1d (= main b885a2c + the design; nothing
under `scripts/`, `feed/` or `tests/` differs). The whole v4 was read, together with the v1–v3 reports and
`v16g4-sites.md`. Line numbers are b885a2c.

Method:
- read-only `grep` / `sed` / `git show` in the worktree; `gh issue view 254` (body, read only);
- scratch experiments in my own scratchpad only (no repo file touched except this report):
  - `git apply` of the misc patches onto `git show b885a2c:…/batman-autocommit` in a fresh `mktemp -d` on Git Bash
    (git 2.53.0.windows.2, system `core.autocrlf=true`), with the v4 flags, with and without `-p4`, with a CRLF
    output, with a user attributes file, and inside a throwaway `git init` repository;
  - `sha256sum -c` with extra provenance lines;
  - in WSL (Ubuntu-24.04, kernel 6.6.114.1-microsoft-standard-WSL2) as the **unprivileged** user `yello`:
    `unshare -Urm --propagation private` (user + mount namespace, no host privilege), a tmpfs mounted with the source
    `/dev/mmcblk0p5`, a tmpfs over `/dev`, `dd iflag=direct` on tmpfs, and the `/dev` fs type as `stat -f` and
    `/proc/self/mounts` report it. Nothing ran as root; no `unshare` as root;
- the lint (3) regex over the lint (3) scope.

No ssh, no harness script against a node.

**Verdict: APPROVE-WITH-CHANGES.** No BLOCKER, no MAJOR.
- All three v3 MAJORs (A M1–M3) and B's two v3 MAJORs are resolved in substance. My experiments confirm the
  mechanisms the design relies on:
  - `git -c core.autocrlf=false -c core.eol=lf apply` outside a work tree writes LF on Git Bash;
  - `git apply -R --check` works outside a repository and discriminates;
  - a tmpfs mounted with the source `/dev/mmcblk0p5` shows in the namespace's `/proc/mounts` exactly as prov-base's
    `grep "^$P5 "` expects;
  - the fake `/dev/mmcblk0p5` stays inside the namespace.
- Nine MINORs remain. Each has a local fix, and none needs another full round. The most useful ones:
  - m1: the `derive_misc` spec as written cannot apply the patch (wrong path level), and the SHA256SUMS format must
    stay readable by `prov-misc-254.sh:33`;
  - m3: the sandbox's "refuse unless `/dev` is the tmpfs" check is vacuous if written the obvious way (`stat -f`
    reports `tmpfs` for WSL's devtmpfs);
  - m7: pty-commit's new settle-failed path brings back the "bad-slot blocks every later run" harm that the code
    comment at `:37-38` exists to prevent.

## v3 findings: resolution check

| v3 finding | v4 | Status, with evidence |
|---|---|---|
| A M1, B m7 (CRLF; skip inside a work tree) | §2 `derive_misc` | ✅ Scratch, Git Bash: with the v4 flags, outside a repo, the output has 0 CR bytes and `diff` against the base is exactly the patch's +/− lines; `git -c core.autocrlf=true apply` gives 644 CRs (the trap is real); `apply -R --check` on the output rc 0, on the base rc 1, on a CRLF output rc 1. Inside a work tree: `Skipped patch 'usr/bin/batman-autocommit'.` rc 0, sha unchanged (so the `rev-parse` refusal and the `Skipped patch` FAIL are both needed). ⚠️ m1 (patch path level, attributes override, SHA256SUMS format), m2 (where the host test really runs). |
| A M2, B m8 (lint (3)) | §4.3 exact text + count; precheck pinned in lint (2); scope | ✅ Measured: 169 non-comment hits in scope at b885a2c, excluding `dv/data/`; one duplicated line (`reboot_and_wait "$n" reboot 240 \|\| rc=1`, ×2 in `daily-validation.sh`), which the count column handles. ⚠️ m5 (TSV with tabs; rows 36–38 are not in the negative set; how the expected set is generated). |
| A M3, B M2 (p5 negative control touched the host) | §3.2 `unshare -m` sandbox, no seam | ✅ in principle. Scratch, unprivileged userns in WSL: `mount -t tmpfs /dev/mmcblk0p5 $M/pbm.T` → `/proc/mounts` line `/dev/mmcblk0p5 …/pbm.T tmpfs …`; `grep -q "^/dev/mmcblk0p5 " /proc/mounts` matches; after `mount -t tmpfs none /dev`, a write to `/dev/mmcblk0p5` creates a regular file in the namespace only (outside: "No such file"); `umount` works. ⚠️ m3 (refuse check, `/dev/null`, prefix, privilege). |
| B M1 (`slota`/`toa 02` refused) | §3.1 per-state texts | ✅ Each text names a path that works. ⚠️ "twice" is right only from A (m6). |
| B m3 (02 check blocks every unit) | `PR_USES_02` | ✅ grep: `as02` / `restore02` exist only in `prov-netjoin-fleet-254.sh` (`:29`, `:74`); 02's slot is changed only there and in fleetchan part 1 (`:30-45`). ⚠️ Enforcement and the trial state for other units (m6). |
| A m1, B m4 (Pi 3) | §4 one rule, no SoC exemptions | ✅ Consistent across rows now. ⚠️ m8: the "same verdict as trybootget-209" claim is false for a DNODE, and the open line is not in #254. |
| A m2, B m8 (row 30) | prechecked | ✅ |
| A m3 (precheck TOCTOU, second ssh) | same ssh command | ✅ The spurious-FAIL point and the TOCTOU are gone. An ssh failure now ends as today's "reboot did not happen" (rc 255 + same boot id), which is correctly attributed. ⚠️ m4: the `&& { trigger; } \|\| echo` shape misattributes a failing trigger; v3's "lasting mark" point is not answered. |
| A m4 (`/mnt/dv-p5`) | §3.2 | ✅ |
| A m5, B m6 (dead-man IRK, lease order, bt305-dirty) | §4.2 rows 36–38, §9 | ✅ The trade-off is stated as an owner decision. The node-side reader the prefix reuses (`bf_get`) already checks word 5 (`bootfacts.sh:19-31`, #376). |
| A m6 (blob id, provenance, older V, named case) | §2, §8 | ✅ |
| A m7 (direct `pr_p9` callers; check before acquire) | §3.1 | ✅ `eh15-ethsim-254.sh:18` does not touch 02 (grep). The insertion point is between `prov-254.sh:670` and `:671`. Nit: the design says `pl acquire`; the host function is `pr_acquire`. |
| A m8 (`<pre>`, `-`, output) | §4.1 | ✅ |
| A m9, B m10 (open line) | #254 | ✅ The body's line 117 (under L116) records it. |
| B m5 (pty-commit) | §4.2 rows 13, 15 | ⚠️ The wording is fixed, but the consequence is new (m7). |
| B m9 (owners of 02's slot) | §7 | ✅ |
| B m11 (test wiring) | §4.3 | ⚠️ m2 |

## Findings

### MINOR-1: `derive_misc` as specified cannot apply the patch; the LF "forcing" can be overridden by an attributes file; the SHA256SUMS contents are unspecified, and the obvious form breaks prov-misc

**Evidence (scratch, Git Bash).**

1. **Path level.**
   - §2 step 1 copies the base in as `usr/bin/batman-autocommit`.
   - The patches name `a/feed/batman-provision/files/usr/bin/batman-autocommit` (`tests/wbox/misc-l38.patch:4`).
   - With the default `-p1`:
     ```
     Checking patch feed/batman-provision/files/usr/bin/batman-autocommit...
     error: feed/batman-provision/files/usr/bin/batman-autocommit: No such file or directory   rc=1
     ```
   - With `-p4` it applies:
     ```
     Hunk #2 succeeded at 441 (offset 39 lines). Applied patch usr/bin/batman-autocommit cleanly.   rc=0
     ```
   - The failure is fail-closed, but the spec is wrong. State `-p4`, or copy the base to the full
     `feed/batman-provision/files/usr/bin/batman-autocommit` path.
2. **The "LF forced" claim does not hold against attributes.**
   - Outside a repository, git still reads the user attributes file (`core.attributesFile`, default
     `~/.config/git/attributes`).
   - With a file containing `* text eol=crlf`:
     `git -c core.attributesFile=<it> -c core.autocrlf=false -c core.eol=lf apply -p4 …` → rc 0, **644 CR bytes**.
   - None is configured on this host today. The no-CR assertion and the reverse-check catch it (reverse-check on a CRLF
     output gives rc 1), so this stays fail-closed.
   - The fix is cheap and makes the "LF forced" claim true. Run git hermetically:
     - `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c core.attributesFile=/dev/null -c core.autocrlf=false apply --whitespace=nowarn …`;
     - this also neutralises a user `apply.whitespace=fix`, which would otherwise rewrite added lines.
3. **SHA256SUMS.**
   - `bindac` verifies the derived file with `(cd "$d" && sha256sum -c --quiet SHA256SUMS)` (`scripts/dv/prov-misc-254.sh:33`).
   - If `derive_misc` writes the base sha as a normal sums line (`<sha>  base`), the check fails on every arm:
     ```
     sha256sum: base: No such file or directory   base: FAILED open or read   rc=1
     ```
   - A comment-style line (`# base … patch …`) is tolerated (rc 0).
   - **Fix:** say so, or put the provenance in a separate `PROVENANCE` file. Add a CI case: `bindac`'s exact check
     passes on `derive_misc`'s output.

### MINOR-2: where the offline tests really run: no daily run exercises Git Bash's git; the p5 test should follow the existing namespace pattern

- **The delegation.** `self_test` (`daily-validation.sh:198-206`) delegates the whole `test-h4-offline-254.sh` into
  WSL when the repo is a `//wsl.localhost` checkout.
  - In practice that is the only working configuration. The existing `tests/judges/h4/test-undo-lib.sh:12-15` needs
    `unshare`, which Git Bash does not have.
  - So `test-derive-misc.sh` "on the Windows host inside `test-h4-offline-254.sh`, where the CRLF trap lives" (§2,
    §4.3, §8 "Hosts") runs with Linux git, without the system `autocrlf=true`. **No regular run exercises Git Bash's
    git.**
  - The real defence is the runtime no-CR / reverse-check inside `derive_misc`, which runs wherever `dv-prov-tools.sh`
    runs. Say that, and drop the claim. Or add an explicit Git Bash invocation and label it.
- **"Refused elsewhere".** `p5-restore-ns.sh` "WSL, as root … (refused elsewhere)" should copy `test-undo-lib.sh:14-15`:
  - real root → `unshare --mount --propagation private`;
  - otherwise → `unshare --user --map-root-user --mount`;
  - and a refusal is a FAIL, never a skip.
- **Least privilege.** Prefer the user-namespace form even under root. prov-base's root check
  (`node/prov-base-254.sh:26`, `id -u` = 0) passes inside it; mounts work (scratch, as `yello`); and a broken sandbox
  then cannot write any real device node, whatever goes wrong.

### MINOR-3: sandbox details that decide whether the §3.2 control is safe and discriminating

1. **The refuse check is vacuous if written the obvious way.**
   - In WSL, `stat -f -c %T /dev` reports `tmpfs` for the host's **devtmpfs**:
     ```
     statfs: tmpfs 1021994
     none /dev devtmpfs rw,nosuid,…
     ```
   - "Refuse unless the namespace's `/dev` is the tmpfs" must instead check:
     - the last `/dev` line of `/proc/self/mounts` has the type `tmpfs` (not `devtmpfs`);
     - `/proc/self/ns/mnt` ≠ `/proc/1/ns/mnt`;
     - `/dev/mmcblk0p5` is a regular file (`[ -f ] && [ ! -b ]`).
2. **`/dev/null`.**
   - After a tmpfs over `/dev`, `</dev/null` fails ("cannot open /dev/null"), and a background command with that
     redirect never starts (scratch).
   - Main's `lock_take` survives only by accident: `mkdir "$LOCK" 2>/dev/null` (`:49`) first creates `/dev/null` as a
     root-only regular file, so the holder's `</dev/null` (`:55`) then opens it.
   - The test's own `sh "$PB" … </dev/null` inside the namespace would fail.
   - **Fix:** bind the host's `/dev/null` and `/dev/zero` into the tmpfs before running anything.
   - Assert main's exact die text `FAIL p5 is mounted`, not "dies without a name". Otherwise a die anywhere else, for
     example `lock holder cmdline does not match`, passes the negative control.
3. **Prefix.** §3.2 gives both a literal `/tmp/run/batman-dv/` and "via `$DVD`".
   - Under `PROV_BASE_TEST_ROOT`, `DVD=$RUNDIR-dv` is test-root-prefixed (`prov-base-statecmp.sh:5` sets
     `RUNDIR=$R/tmp/run/batman`).
   - State which one the fix matches. The node path is the literal one. The sandbox's leftover mounts must then sit at
     the real `/tmp/run/batman-dv/…` inside the namespace (tmpfs over `/tmp/run`), not under the test root.
4. **Host residue.**
   - `mkdir -p /tmp/run` for the mountpoint is a host change if it is absent. Minor, but "nothing outside is writable"
     is not literally true.
   - The read-back's fallback `echo 3 > /proc/sys/vm/drop_caches` (`:223`) is host-global. It runs only where tmpfs
     lacks `O_DIRECT`. Scratch: `dd iflag=direct` on tmpfs works on WSL 6.6.114, so the fallback is not taken there.
     Say so.
   - The "busy" case's process must be killed at the end of the test.

### MINOR-4: the precheck shape `<GET>; [ answered ] && [ flag = 0 ] && { <trigger>; } || echo TRYBOOT-NOT-CLEAR` misattributes a failing trigger

- **The shape.** `a && b && { c; } || d` runs `d` when `c` fails.
  - A trigger that returns non-zero (a `reboot` that errors; `echo c > /proc/sysrq-trigger` refused) would print
    `TRYBOOT-NOT-CLEAR`.
  - The suite would then FAIL "tryboot flag armed or not answered", which is false evidence (#270 is about exactly this
    kind of attribution).
  - Use `if [ answered ] && [ flag = 0 ]; then <trigger>; else echo "TRYBOOT-NOT-CLEAR flag=<v>"; fi`.
  - Print the flag value, so "armed" (1) and "not answered" (`unknown`) give different FAIL texts (see m8).
- **Output capture.** `reboot_and_wait` discards the trigger's output today (`daily-validation.sh:2300`,
  `>/dev/null 2>&1`). State that it is now captured and that the `trc` evidence line stays.
- **Residual from v3 m3, unanswered.** An armed flag on DNODE is left for the next product reboot. Every later D suite
  refuses separately, and nothing marks the node.
  - Either write the `dnode_blocked` NEEDS-PERSON line, or state the decision not to.
- The precheck stays effective for ramoops: the trigger runs only after the GET in the same shell.

### MINOR-5: lint (3) inventory format and the negative control

1. **Tabs.** 14 of the in-scope hit lines contain an internal TAB after trimming. Examples:
   - `dv/prov-254.sh` `pr_peer_after(){<TAB># 02: …`;
   - `node/ble-central-254.sh` `role_fire_restore() {<TAB># deadman …`.

   A TSV whose second column is "the exact trimmed line text" cannot hold them unescaped. Define the escaping, or put
   the text column last and take the remainder of the line.
2. **Rows 36–38 are not in the b885a2c FAIL set.**
   - The conversion puts the DISARMED prefix on new lines before the `rm` (as `chain1-254.sh:150-152`).
   - The `batman-slot reboot committed ble-dm-254; exit 0` / `bt305-dm` lines (`ble-central:102`, `ble-periph:197`,
     `bt-uart-305:297`) stay byte-identical.
   - So they match their lint (1) allowlist and lint (3) rows on b885a2c, and §4.3 "lint (3) names … rows 36–38 on
     the node" will not happen.
   - Their only negative control is the extracted-run test with `STUB_DISARM_FAIL`, which is fine. Say so.
   - Separately, lint (1) on b885a2c also names rows 11 and 12 (`setsid … batman-slot reboot committed …`), which
     §4.3 omits.
3. **The expected FAIL set must not be computed from the inventory the lint reads.** §4.3: "generated from the
   inventory and the pin table". A lint matching bug would then be mirrored in its own expectation.
   - Check the generated set against an independent, hand-written list of site numbers: rows 1–12 and 19 (lint 1/3);
     the pins of 1–13, 15, 19 and the precheck (lint 2).
   - The control FAILs if any listed row is missing from the actual output.

### MINOR-6: the 02 contract: enforcement, the trial state for the other units, and `pr_peer_after`

- **`PR_USES_02` is a convention, not enforced.** A future unit that calls `as02` / `restore02` without setting it gets
  no check.
  - Make `as02`, `restore02` and fleetchan's part-1 OTA assert `PR_USES_02=1` (FAIL otherwise). Add one stub case.
- **"In a trial" should FAIL for every unit, not NOTE.**
  - A 02 in a trial reverts or commits within its deadline, and reboots.
  - `pr_peer_after` (`prov-254.sh:606-609`) then FAILs "02 rebooted (boot … -> …)" in whichever unit the reboot
    lands. That FAIL is misattributed to the unit.
  - "On B committed" and "older version" can stay a NOTE for units that do not use 02.
- **`pr_peer_after`'s WARN branch hardcodes `A 1`** (`:608`). With 02 legitimately on B committed (now allowed with a
  NOTE), a joinwatch reboot in a run over 3600 s FAILs instead of WARNing. Compare with 02's slot recorded at
  `pr_begin`.
- **"Twice" holds only from A.** "02 runs <ver>, not V: upgrade 02 to V twice" lands on A only when 02 starts on A.
  From B, two OTAs end on B, and the next run asks for a third.
  - Say "until it is A committed on V (two OTAs from A, one or three from B)".

### MINOR-7: pty-commit's settle-failed path now leaves the bad-slot that the code comment exists to prevent

- **The code comment.** `pty-commit-254.sh:37-38`: "a stop after the landing commits the trial … a deadline revert would
  leave bad-slot behind and block every later run (review M3)".
- **v4 on the `:59` path.** v4 (§4.2 rows 13, 15) prints "landing boot unknown — not committing; the trial is left to
  its autocommit deadline revert".
  - After that revert, `pr_p9` FAILs `hold flag / bad-slot present` (`prov-254.sh:641`) for every later prov unit.
  - pty-commit's own precondition (`:46`, `badslot=[]`) FAILs too.
  - That is fail-closed and loud, but it is exactly the harm M3 removed, and the trade-off is not stated.
- **Fix: bind the commit to the state that was judged.** The pre-OTA boot `b0` is known (`:55`).
  - In `stop()`, read boot id + slot + trial + `held` in **one** ssh.
  - If the boot ≠ `b0`, slot = `TGT`, trial and `held=1`, call `commit_guarded <that boot8> "$TGT" 0`. That is the
    landing boot by construction.
  - Otherwise (unreachable, or another state), append a NEEDS-PERSON line naming the expected deadline revert and the
    bad-slot consequence.
  - Add a stub case for each.

### MINOR-8: Pi 3 policy: one claim is false, the open line is not recorded, and the FAIL text should name the Pi 3 cause

- **"Same verdict trybootget-209 gives that node" (§4) is false for a DNODE.**
  - trybootget-209 runs only on `BENCH_NODE` (`daily-validation.sh:2258`).
  - faketime-174 and ramoops-173 run on `DNODE`, which may be a Pi 3: guardian-192 is explicitly N/A for a bcm2710
    DNODE (`:2692-2695`), so a Pi 3 DNODE is a supported configuration.
  - With a Pi 4 `BENCH_NODE` and a Pi 3 DNODE whose firmware does not answer word 5, trybootget-209 PASSes, while
    faketime-174, ramoops-173, adr-reconcile and prov-claim FAIL every run. That is a harness-only FAIL of product
    suites that pass today.
  - The product itself checks only word 2 on a Pi 3 (group 1 kept the Pi 3 parse unchanged: `254-v16-group1.md:57-61`).
    So the harness becomes stricter than the product on that board.
- **Unaffected (good).** The other Pi 3 path in the daily run, `hold-261` R3/R4 on `H261` (`daily-validation.sh:404-413`),
  uses only `release_guarded`, which has no DISARM. State this.
- **The open line is not recorded.** "⚠️ Word 5 has never been captured on a Pi 3 … Recorded as an open line in #254":
  `gh issue view 254` (body, 205 lines) has no such line. The only Pi 3 items are lines 61, 78 and 102 (P-U14,
  checked off), and the DoD at line 226 still names "2 台 3A+". This is the same class as v3 m9.
- **Fix.**
  - Record the line and quote it in §12.
  - Correct the sentence.
  - Make the precheck / guard FAIL text say `tryboot GET not answered (word 5) on <soc>` separately from `armed`.
    On bcm2710, append "Pi 3 word 5 unproven (P-U14, #254 line N)", so a daily report on a Pi 3 fleet does not read as
    a product regression.

### MINOR-9: §7 ownership of the tryboot flag omits two existing writers

The §7 row lists the product, the guard's DISARM and the node dead-men. It omits:
- `ab-selftest.sh:120` (`vcmailbox 0x00038064 4 4 1`): the harness **arms** the flag directly, in tryboot mode;
- the chain1 dead-man (`chain1-254.sh:151`): it disarms.

Both are allowlisted, so there is no conflict. List them, so the "cleared only on a committed node right before a reboot"
contract is not read as covering every writer.

## Lifecycle and security, re-checked

- **Install / start / restart / crash.**
  - §3.1 stops before `pr_acquire`, which changes nothing on a node ✅.
  - `derive_misc` failures are INVALID before any arm ✅.
  - An interrupted p5-restore drops the lock on every die ✅.
  - An interrupted precheck has no window: the GET and the trigger run in one shell ✅.
- **Upgrade / older V.**
  - `git apply` takes offsets, not fuzz. An older V whose context still matches yields a valid mutant of *that* V.
    Otherwise FAIL → INVALID ✅.
  - The witness ids are a fixed table (`tests/wbox/gen/edits.pl:43`), so regenerating the patches keeps the
    equivalence proof meaningful ✅.
- **Platforms.**
  - Git Bash and WSL: m1, m2.
  - Pi 3: m8.
  - CM4 (the production board, P-U14) is bcm2711 and shares the guard path; no hardware, as the rest of #254.
- **Security.**
  - No new port, secret or node input ✅.
  - The derived mutant is repo content plus V's sha-checked file. It is bound only in a dry run ✅.
  - The p5 fix unmounts only root-created harness mountpoints matched in `/proc/mounts` ✅.
  - The sandbox should drop real root (m2/m3: user namespace, a non-vacuous `/dev` check).
- **Our own mistakes.** Each has a check that would catch it:
  - a mutant built with CRLF: the runtime no-CR / reverse-check ✅;
  - a lint that cannot fail: exact text + count, pinned precheck ✅; but see m5.3;
  - a control that passes for the wrong reason: m3.2.

## Summary

| # | Sev | One line |
|---|---|---|
| m1 | MINOR | `derive_misc`: base copied to `usr/bin/…` but the patches are `-p1` on `feed/…` → "No such file" (needs `-p4`); a user attributes file `eol=crlf` beats `-c core.autocrlf=false` (644 CRs; caught by the asserts) → run git hermetically; SHA256SUMS provenance must not break `prov-misc-254.sh:33` `sha256sum -c` |
| m2 | MINOR | `test-h4-offline` is delegated into WSL, so no daily run exercises Git Bash's git; the p5 test should use `test-undo-lib.sh`'s root / userns pattern (prefer userns), and a refusal is a FAIL |
| m3 | MINOR | sandbox: `stat -f` says `tmpfs` for WSL's devtmpfs (vacuous refuse check); `/dev/null` is missing under a tmpfs `/dev` (main works by accident); assert the exact `FAIL p5 is mounted`; literal prefix vs `$DVD`; host residue |
| m4 | MINOR | `&& { trigger; } \|\| echo TRYBOOT-NOT-CLEAR` blames the flag for a failing trigger; use if/else and print the flag value; capture the output; v3's "lasting mark" unanswered |
| m5 | MINOR | lint (3): 14 hit lines contain tabs (TSV escaping); rows 36–38 lines are unchanged, so they are not in the b885a2c FAIL set; lint (1) also names rows 11–12; the expected set must be checked against an independent site list |
| m6 | MINOR | `PR_USES_02` not enforced in `as02` / `restore02` / fleetchan; a 02 in a trial should FAIL for every unit (else misattributed "02 rebooted"); `pr_peer_after` WARN hardcodes `A 1`; "twice" holds only from A |
| m7 | MINOR | pty-commit settle-failed path leaves a deadline revert + bad-slot that blocks every later run (`:37-38`, review M3); commit with the boot read in the same ssh as the state, else NEEDS-PERSON |
| m8 | MINOR | Pi 3: trybootget-209 runs only on BENCH_NODE, so "same verdict" is false for a Pi 3 DNODE (faketime / ramoops / adr / claim FAIL, product passes); the word-5 open line is not in #254; name "not answered (Pi 3)" separately from "armed" |
| m9 | MINOR | §7: `ab-selftest.sh:120` arms the flag and the chain1 dead-man disarms it; neither is listed |
