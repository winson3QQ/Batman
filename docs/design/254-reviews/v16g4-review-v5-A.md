# Review A, round 5: `docs/design/254-v16-group4.md` v5 (harness PR A)

Reviewer: A (independent, adversarial). Tree `C:\src\Batman-g4h`, HEAD 1780502 (= main b885a2c + the design; nothing
under `scripts/`, `feed/` or `tests/` differs). I read the whole v5, the v4 reports from both reviewers and
`v16g4-sites.md`. §13 is treated as binding. Line numbers are from b885a2c.

Method:
- read-only `grep` / `sed` / `git show` in the worktree, and `gh issue view 254` (body only, read only);
- scratch experiments, only in my own scratchpad:
  - Git Bash (git 2.53.0.windows.2, system `core.autocrlf=true`): `derive_misc` exactly as §13.4 specifies, plus a
    hostile `HOME` with `~/.gitconfig` (`autocrlf=true`, `apply.whitespace=fix`) and `~/.config/git/attributes`
    (`* text eol=crlf`);
  - WSL Ubuntu-24.04 (kernel 6.6) **as the non-root user yello**: the §13.6 sandbox (`unshare -Urm`, tmpfs `/dev` with
    bind-mounted `null` / `zero` / `urandom`, a tmpfs with the source `/dev/mmcblk0p5`, the marker check through
    `/proc/1/root`), and the §13.1 refusal shape (`lock()` on fd 9 + `exit 3` inside the role function) under `dash`.
- No ssh, no harness script against a node, nothing as root, no repo file touched except this report.

**Verdict: APPROVE-WITH-CHANGES.** No BLOCKER, no MAJOR.
- v4 B's MAJOR (the dead-man refusal did not keep the lease) is resolved in substance. `exit 3` really stops both
  callers, and the lock really is released (evidence below).
- Every v4 MINOR from both reviewers is addressed in §13. Some fixes are incomplete or introduce small new problems;
  these are the nine MINORs below. Each has a local fix and none needs another full round.
- The most important:
  - **m1:** the p5 sandbox as specified does not work. The namespace order is the reverse of the documented one, and a
    real-root userns loses DAC on the 0750 home. The `/dev` binds give EACCES on `>/dev/null` unless the tmpfs is
    `mode=0755`. The "marker absent on the host" check is vacuous inside a user namespace.
  - **m4:** the pty-commit settle-failed path (§13.2's own title) is the unreachable-node case, and §13.2 does not
    specify it. Its NEEDS-PERSON line would also never reach `needs-person.txt`, because `DV_DIR` is not passed.
  - **m5:** §13.7 rests on a false fact ("daily-validation has no NEEDS-PERSON list").

## The specific questions

### Q1 `exit 3` inside `role_fire_restore`: does it stop the caller?

✅ Yes. It is never called in a subshell, in `$( )` or in a pipeline.
- `grep -rn role_fire_restore` finds exactly two call sites, both direct statements in the main shell:
  - `scripts/node/ble-lib-254.sh:341` (`cmd_dm_fire`);
  - `:354` (`cmd_recover`).
- The dispatchers call them directly: `ble-central-254.sh:109,118`, `ble-periph-254.sh:205,215`,
  `bt-uart-305.sh:306,318`.
- `prov-lease-254.sh:39` has its own `role_fire_restore`. It never reboots, so it is unaffected.
- No `trap … EXIT` exists in `ble-lib-254.sh`, `ble-central-254.sh`, `ble-periph-254.sh` or `bt-uart-305.sh`. The only
  trap is inside `lim`'s watchdog subshell (`:55`).

### Q2 Is the lock really an fd flock that exit releases?

✅ Yes.
- `lock()` is `exec 9>>"$BT/lock"` + `flock -n 9` (`ble-lib-254.sh:99-102`). The deadman is started with `9>&-`
  (`:148`), so it opens its own fd 9.
- Children that inherited fd 9 before the refusal (the `lim` watchdogs at `ble-periph:193`) are killed when their
  command ends (`:50-56`).
- Scratch, `dash`, same `lock()` and a `lim` child holding fd 9:
  ```
  deadman: tryboot not cleared
  rc=3
  lease kept
  lock free after exit
  ```
- With the lease kept, the next `cmd_acquire` dies with "run X did not clean up (lease expired, no deadman left): run
  ble-recover first" (`:285-290`). So the kept lease does block the next run.

### Q3 Hermetic git on Git Bash

✅ It works as specified. ⚠️ Two residuals, in m9.

Scratch, §13.4 verbatim (base at `feed/batman-provision/files/usr/bin/batman-autocommit`, default `-p1`):
```
Checking patch feed/batman-provision/files/usr/bin/batman-autocommit...
Hunk #2 succeeded at 441 (offset 39 lines).
Applied patch feed/batman-provision/files/usr/bin/batman-autocommit cleanly.   apply rc=0
CR=0 differs=1   shn-ok   revcheck rc=0
```
So the ⚠️ in §13.4 ("inferred … checked first thing") can become ✅.

- `GIT_CONFIG_GLOBAL=/dev/null` takes effect on Git Bash: `git config --global --list` is empty, rc 0.
- A hostile `~/.config/git/attributes` (`* text eol=crlf`):
  - without `core.attributesFile=/dev/null`: `rc=0 CR=644`;
  - with it: `CR=0`.
  - Both the `HOME=<work dir>` and the `attributesFile` override are needed, and the design has both.

### Q4 The base64 TSV

⚠️ It works mechanically if the encoder uses `-w0`. But it makes the allowlist unreviewable (m6).

### Q5 The independent converted-rows list

⚠️ It is independent, as v4 asked. But "exactly those rows" is brittle, and the file format and the run mode are not
specified (m6).

## Resolution check of v4 findings

| v4 finding | v5 | Status |
|---|---|---|
| B MAJOR-1: the callers drop the lease; the test is blind; bt305-dirty placement | §13.1 | ✅ in substance (Q1, Q2). ⚠️ The test as written cannot be built (m2). The refusal record and remedy are incomplete, and the bt305 claim overstates (m3). |
| A m1, B m6 (B MINOR-5): path level, attributes, SHA256SUMS, case names | §13.4 | ✅ (Q3). `SHA256SUMS` keeps one line and provenance goes to `PROVENANCE`, so `prov-misc-254.sh:33` stays valid. Case strings are read from `autocommit-mesh-arm.sh`. ⚠️ m9 (residual env) |
| A m2, B m1 / m2: where the tests run; namespace pattern | §13.5, §13.6 | ✅ Git Bash claim withdrawn; the smoke run is PR evidence. ❌ The namespace order is inverted against the cited source (m1a). |
| A m3, B m2 (B MINOR-3): sandbox details | §13.6 | ⚠️ Exact die text ✅, literal prefix ✅, `drop_caches` skip ✅. `/dev` binds fail without `mode=0755` (m1b). The marker check is vacuous in a userns (m1c). |
| A m4, B m9 (B MINOR-10): precheck shape, output, lasting mark, device coverage | §13.7 | ✅ if/else, output captured, three FAIL texts. ❌ The "lasting mark" answer rests on a false fact. The word-6 hex trap is not stated. The device coverage point is unanswered (m5). |
| A m5, B m7 (B MINOR-6): TSV tabs, rows 36–38, lint (1) rows 11–12, independent list, generator, `*.sh` | §13.8, §13.1 | ✅ Same-line form makes 36–38 visible; rows 11–12 named; generator self-excluded; `*.sh` only. ⚠️ m6 |
| A m6, B m3 (B MINOR-4): `PR_USES_02` enforcement, trial for all units, `pr_peer_after`, "twice" | §13.3 | ✅ Runtime refusal + grep test; trial FAILs every unit; remedy text is slot-dependent; `pr_acquire`. ⚠️ m7 |
| A m7, B m8 (B MINOR-9): pty-commit bad-slot | §13.2 | ⚠️ Fixed only for the reachable / boot-changed case. The titled path (unreachable) is unspecified, and the NEEDS-PERSON line is inert (m4). |
| A m8: Pi 3 claim, open line, FAIL text | §13.7, §14 | ✅ `gh issue view 254` body line 182 now records the word-5 line. Line 117 keeps the product-revert line. |
| A m9, B m8 (B MINOR-7): tryboot flag writers | §13.9 | ✅ Matches `slot-guard-254.sh:47`, `chain1-254.sh:151`, `ab-selftest.sh:120`. |
| B m4 (B MINOR-4 of v4 = rows 11/12 rationale) | §13.10 | ✅ |
| B m10 (B MINOR-11): §10 / §11 history | §13.11 | ✅ for §10/§11. ⚠️ §1–§9 carry many superseded statements, unmarked (m8). |
| B MINOR-1 (Git Bash run) | §13.5 | ✅ |

## Findings

### MINOR-1 (m1): the §13.6 sandbox as specified fails, and its safety check is vacuous in a user namespace

**a. The namespace order is inverted against the source it cites.**
- §13.6: "Follow `test-undo-lib.sh:14-15`: try `unshare -Urm` as the user …, else `unshare -m` as root."
- The cited code does the opposite, and its comment says why (`tests/judges/h4/test-undo-lib.sh:12-15`):
  - if `id -u` = 0 → `unshare --mount --propagation private`;
  - otherwise → `--user --map-root-user`;
  - the comment: "real root … a user namespace would lose DAC override on the repo owner's 0750 home ('Permission
    denied', 2026-11-03 full run)".
- daily-validation runs `test-h4-offline` as WSL root (v4 B: the WSL default user is root). There `unshare -Urm`
  *succeeds*, and then the test cannot read the repo under the owner's 0750 home. The result is a FAIL every run, not
  a skip, but it is wrong.
- **Fix:** copy the cited order (root → `-m`; non-root → `-Urm`).

**b. The `/dev` binds give EACCES on write unless the tmpfs is `mode=0755`.**

Scratch as yello, `unshare -Urm`. A default tmpfs at the staging dir, `null` / `zero` / `urandom` bind-mounted from the
host nodes, then `--rbind` over `/dev`:
```
crw-rw-rw- 1 nobody nogroup 1, 3 … /dev/null
bash: line 7: /dev/null: Permission denied        <- echo hi > /dev/null
redirect </dev/null ok                            <- reading works
```

Isolated, on a bound node:

| open flags | result |
|---|---|
| `O_WRONLY` | ok |
| `O_WRONLY\|O_TRUNC` | ok |
| `O_WRONLY\|O_CREAT` | **EACCES** |

- The cause is the kernel's `may_create_in_sticky`. The tmpfs root defaults to 1777. For a non-regular file owned by
  someone else (`nobody`) in a sticky world-writable dir, `O_CREAT` is refused.
- The same run with `mount -t tmpfs -o mode=0755`: all six opens ok.
- The shell's `>` / `2>` use `O_CREAT`. So main's `until mkdir "$LOCK" 2>/dev/null` (`node/prov-base-254.sh:30`) fails
  its redirect and never runs mkdir. main never reaches `die "p5 is mounted"`, and its negative control is INVALID on
  every run. This is the trap v4 B MINOR-3 saw ("bind … gave Permission denied on write"); §13.6 adopted the binds
  without the fix.
- **Fix:** mount the `/dev` tmpfs (and `/tmp`, `/opt`, as `test-undo-lib.sh:17` already does) with `-o mode=0755`.

**c. "Marker absent from the host `/dev`, read through `/proc/1/root/dev`" passes vacuously in a user namespace.**

Scratch as yello in `unshare -Urm`:
```
-e host null: NOT visible (would read as absent)     <- [ -e /proc/1/root/dev/null ] is false: EACCES
ns/mnt of pid 1 unreadable
```
- `[ ! -e /proc/1/root/dev/<marker> ]` is true whether or not the sandbox `/dev` is in place. So the "refuse unless
  sandboxed" backstop never refuses on the userns path.
- **Fix:**
  - record `stat -c %d /dev` on the host before `unshare` and pass it in; require the in-namespace value to differ.
    Scratch: host 5, in-ns 78;
  - require that the last `/dev` entry of `/proc/self/mountinfo` has fs type `tmpfs`, read by field after the `-`
    separator, not by position;
  - require `[ -f /dev/mmcblk0p5 ] && [ ! -b /dev/mmcblk0p5 ]`;
  - treat an unreadable `/proc/1/root` as a FAIL, never as "absent".

**d. Mountpoint residue.** A tmpfs "over `/tmp/run`" needs `/tmp/run` to exist on the host. If it is absent, `mkdir`
creates it on the host before the mount, owned by whoever runs the test. Mount the tmpfs over `/tmp` instead, as
`test-undo-lib.sh:17` does, and `mkdir -p /tmp/run` inside it.

### MINOR-2 (m2): the §13.1 behaviour test cannot be built as written, and the one-line form is ambiguous

1. **Stubbing.** "Drives … through the real `ble-lib-254.sh` … stubs `vcmailbox`, `reboot`, `bootid` and `up_s`."
   - `bootid` and `up_s` are shell functions of the lib (`ble-lib-254.sh:19-20`). A PATH stub cannot override them
     when the real role script runs.
   - `ble-central` and `ble-periph` have no lib-only guard (only `bt-uart-305.sh:303` has `BT305_LIB_ONLY`).
   - The reboot is `batman-slot reboot committed`, not `reboot`.
2. **Hard-coded paths.** `H=/tmp/run/batman-dv` and `DMLOG=/opt/batdata/log/…` are fixed (`:8-11`). Run from
   `test-h4-offline` (WSL root), the test would write into the WSL host's real `/tmp/run/batman-dv` and `/opt`.
3. **Fix for 1 and 2:** run the test inside the `test-undo-lib.sh` namespace (tmpfs `/tmp` and `/opt`, `mode=0755`),
   with PATH stubs for `vcmailbox` and `batman-slot`.
   - The real `bootid` and `up_s` are then fine: write the real boot id into the lease and markers, and an expiry
     of 0.
   - `provd_present` is false on WSL, so `provd_start` is a no-op.
   - `cmd_dm_fire` needs a `dm` record holding its own pgid. Run it under `setsid` and write the record from the child.
4. **The line form.** §4.2 says "before the lease `rm`", and §13.1 says "on the same line as the reboot (`DISARMED &&
   reboot`)".
   - An implementer can satisfy both with `rm -f "$BT/lease" …` on line 101 and `node_disarmed && batman-slot reboot
     committed ble-dm-254; exit 0` on line 102.
   - That passes lint (1)/(3), but the lease is gone and the function exits 0. This is exactly the v4 MAJOR.
   - Only the behaviour test catches it.
   - **Fix:** give the exact line in the design. For example:
     `dm_disarmed "$1" || dm_refuse "$1"; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed ble-dm-254; exit 0`,
     on one line, where `dm_refuse` exits 3. Pin that line in lint (2).
   - Name the negative control explicitly: the b885a2c role script under `STUB_DISARM_FAIL` → a reboot call and no
     lease → the test FAILs.

### MINOR-3 (m3): §13.1 refusal: the record is lost on the obvious remedy; no remedy text; two overclaims

1. **Where the line is logged.** The refusal logs with `logger`, which goes to the RAM `logread` ring. The person's next
   act is a reboot, which loses it.
   - The existing dead-man record is `dm_log` to p6 (`ble-lib-254.sh:161-166`, `/opt/batdata/log/ble-dm-254.log`).
   - Use `dm_log`, plus `logger` if wanted.
2. **No remedy text.** "deadman: tryboot not cleared — no reboot, lease kept" gives no remedy.
   - The natural person action, a plain reboot, is exactly what boots the armed trial slot.
   - The existing `ble_state` text even says "run ble-recover or reboot" (`:253`).
   - **Fix:** the line and `RECOVER-REFUSED` name the remedy: clear the flag with `vcmailbox 0x00038064 4 4 0`, check
     that the GET word 6 = 0, then `ble-recover` / reboot. State that provd stays stopped until then: `cmd_acquire`
     stopped it at `:292`, and `provd_start` is skipped.
3. **"`dm`, `dm.new` … stay in place" is false for `ble-recover`.** `cmd_recover` removes both records before
   `role_fire_restore` (`:350`). This is harmless; correct the text.
4. **"Every BLE unit on that controller then refuses a dirty UART" overstates.**
   - The tier-B units never call `ble_state`. `grep` in `dv/ble-254.sh` and `lib/ble-254.sh` finds no `state` call.
   - `ble_state` runs only in:
     - preflight P6 (`dv-preflight.sh:83`);
     - `ble-privacy-254.sh:47`;
     - the `state` commands;
     - after `RECOVERED` (`:357`).
   - What actually stops a later BLE unit is the kept lease (`cmd_acquire` `:285-290`). Say so, or call the
     `bt305-dirty` check from `cmd_acquire` as well.
   - The daily order puts the bt305 suites after BLE (`daily-validation.sh:258-296`), so there is no harm today.

### MINOR-4 (m4): §13.2 does not specify its own titled path, and its NEEDS-PERSON line is inert in the daily run

1. **The settle-failed path is the unreachable-node path.**
   - `settle` loops on `u=$(q 'cut -d. -f1 /proc/uptime')` with `${u:-0}` (`pty-commit-254.sh:24`), so it fails only
     when the node gives no uptime for 600 s.
   - In `stop()` the "boot, slot, is-trial" read then most likely fails too. §13.2 specifies only the reachable
     WRONG-STATE case.
   - Unreachable, or "no longer in a trial (already reverted)", leaves the deadline revert and `bad-slot` (`:37-38`)
     with no NEEDS-PERSON.
   - So "no path leaves a trial to its revert without saying so" is not true yet.
   - **Fix:** any `stop()` with `LANDED=1` that does not end in `SENT` from `commit_guarded` writes the NEEDS-PERSON
     line, naming the expected revert and `bad-slot`. Add a stub case for "unreachable" and one for "not in a trial".
2. **`DV_DIR` is not passed to pty-commit.**
   - `claim-lock-254.sh:46` runs `V=… PAY=… PSH16=… bash …/pty-commit-254.sh`, without `DV_DIR=$DIR`. Compare `:51`
     (chain1) and `prov-dv-254.sh:39,46`, which pass it.
   - daily-validation does not export `DV_DIR` (`grep DV_DIR daily-validation.sh` finds only `:2244`, which passes it
     inline).
   - "The way `pr_needs_person` does" (`[ -n "${DV_DIR:-}" ] && echo >> …`, `prov-254.sh:514`) therefore never writes
     `needs-person.txt`, and `dnode_blocked` never fires.
   - **Fix:** add `DV_DIR=$DIR` at `claim-lock-254.sh:46`, and test that the line lands in the file.
3. **Bind the commit to the expected landing.**
   - `commit_guarded <boot> <slot>` with whatever is read commits *any* trial, including one at the `:62` "landing
     (want held trial on TGT)" stop (wrong slot / version / not held).
   - That is today's behaviour, but §13.2 claims a binding.
   - Require `slot = $TGT`, `boot ≠ b0` and `held=1` (v4 A m7). Otherwise NEEDS-PERSON.

### MINOR-5 (m5): §13.7 rests on a false fact; the word-6 hex trap is not stated; device coverage is unanswered

1. **"daily-validation has no NEEDS-PERSON list" is false.**
   - `daily-validation.sh:84-87`: `suite()` calls `dnode_blocked … "$DIR" "${DNODE0:-}"`.
   - `prov-dv-254.sh:16-24`: `$DIR/needs-person.txt` blocks every later D suite on DNODE0.
   - FI P5, chain1 and the prov units write to it (`fault-injection.sh:452`, `chain1-254.sh:61,71`, `prov-254.sh:514`).
   - The decision not to mark an armed flag must be re-argued on the real facts, or the refusal appends a line. The
     second is cheap: the precheck output already says `armed`.
   - Note: `dnode_blocked` keys on DNODE0 only, so a DNODE ≠ DNODE0 refusal would still not block. State that too.
2. **The hex trap.** The form `f=<word6>; … [ "$f" = 0 ]` invites a raw string compare.
   - vcmailbox prints every word as `0x%08x`.
   - `slot-guard-254.sh:30-32` records that exactly this compare "never held on a real node" (round 7 B-BLOCKER-1).
   - Every `reboot_and_wait` would then refuse. That is fail-closed, but it is a full-day loss.
   - **Fix:** write `f=$(( word6 ))` and the word-5 = `0x80000004` test, or reuse `DISARM`'s parse verbatim. Add a stub
     case with `0x00000000`.
   - Also: `/proc/device-tree/compatible` is NUL-separated; `tr '\0' ' '` it.
3. **Device coverage (v4 B MINOR-10) is not answered.**
   - §8 delivery step 3 still runs no `reboot_and_wait` suite before the merge, even though 8 D suites go through the
     new precheck.
   - Add one (`guardian-192` or the hold-274 cleanup), or state in the PR that the first device run is the post-merge
     full validation.

### MINOR-6 (m6): §13.8 base64 makes the allowlist unreviewable; "exactly those rows" is brittle and underspecified

1. **Reviewability.**
   - §4.3 makes the inventory the allowlist, and "every non-`text` row is reviewed by hand".
   - In base64 the line text is opaque in every PR diff. A reviewer cannot see which line a new `allowlisted:` row
     excuses.
   - **Fix:** put the text as the **last** column and take the remainder of the line after the fixed columns
     (internal tabs then need no escaping), or escape only `\t` and `\\`.
2. **If base64 stays:** GNU `base64` wraps at 76 columns.
   - In scope, 172 non-comment hit lines are longer than 57 bytes (measured), so nearly every row would wrap.
   - The generator must use `base64 -w0`, and the lint must FAIL on a row with the wrong column count.
3. **"Must name exactly those rows" is brittle.**
   - Run against b885a2c, lint (3) names *every* hit line whose text this PR changes, including `text` lines edited
     for unrelated reasons. For example, §13.7 rewrites `reboot_and_wait`, whose header line `:2291` contains
     `reboot`.
   - Either the PR must touch no other hit line, or the control is "at least the converted rows; every extra name is
     listed with its reason in the converted file".
   - **Specify:**
     - the format of `slot-sites-converted.txt` (row, file, b885a2c line number or text), since the lint prints
       `file:line`, not site rows;
     - whether the b885a2c run is a one-off PR proof or a recurring test, and if recurring, how it obtains the
       b885a2c tree (`git archive b885a2c scripts`).

### MINOR-7 (m7): the 02 contract: ordering, the unreachable state, and `pr_peer_after`

1. **Ordering.** The runtime refusal in `as02` / `restore02` / fleetchan part 1 checks `PR_USES_02=1` at call time.
   - A unit that sets it *after* `pr_begin` passes that refusal, but `pr_begin` ran only the NOTE branch for the B and
     older-version states.
   - Have `pr_begin` record `PR_02_CHECKED=1` when it enforced, and make the helpers require that. Or make the grep
     test require the assignment before `pr_begin`, as v4 B MINOR-3 asked.
2. **Unreachable.** §3.1's table has one row for "in a trial / unreachable". §13.3 makes "in a trial" FAIL for every
   unit, but says nothing about "unreachable" for the other units.
   - If an unreachable 02 also FAILs every unit, 02 being off blocks 04-only units such as prov-base.
   - Decide, and add the stub case.
3. **`pr_peer_after`.** "Keeps `A 1` … correct because 02 is contracted to A" (`prov-254.sh:608`) holds only for
   `PR_USES_02=1` units.
   - A non-02 unit with 02 on B committed (allowed, NOTE) turns a >3600 s joinwatch reboot into FAIL "02 rebooted"
     instead of WARN.
   - Compare with the slot recorded at `pr_begin`, or state the accepted misattribution.

### MINOR-8 (m8): §1–§9 still state the superseded design in many places, with no inline marker

§13 says it wins, but the per-site table (§4.2) and the test lists (§4.3) are what an implementer works from. The
superseded statements, unmarked:
- **§2:**
  - step 1 (base at `usr/bin/…`);
  - step 4 (`SHA256SUMS` carries the base sha and blob id);
  - "also on the Windows host inside `test-h4-offline`".
- **§3.1:**
  - the "in a trial" row as a NOTE for other units;
  - the old "twice" text;
  - `pl acquire`.
- **§3.2:**
  - "as root, inside `unshare -m`";
  - "refuses unless … `/dev` is the tmpfs".
- **§4.2:**
  - rows 13 / 15 ("does not commit … left to its autocommit deadline revert");
  - rows 36–38 ("each body extracted"; `bt305-dirty` precondition at the dv start);
  - rows 11 / 12 (the `:575` reason).
- **§4.3:**
  - the negative control ("generated from the inventory"; lint (3) names rows 36–38 "on the node");
  - "Where the offline tests run" (`test-h4-offline` on the Windows host; p5 test "as root").
- **§7:**
  - the tryboot-flag row ("cleared only on a committed node");
  - the misc-mutant row (`SHA256SUMS records the base sha`; "CI and the Windows host").
- **§8:**
  - "Hosts" row;
  - delivery step 1 "v4 review".
- **§9:** "the guards fail closed … dead-man … the kept markers make the case visible" (now only with §13.1).

**Fix:** before implementation, fold §13 into §1–§9 (preferred), or put "→ §13.x" at each of these spots.

### MINOR-9 (m9): `derive_misc` hermeticity residuals (low)

- **The system attributes file.** `GIT_CONFIG_NOSYSTEM` does not cover it. `C:/Program Files/Git/etc/gitattributes`
  exists (today only `diff=astextplain` lines). Add `GIT_ATTR_NOSYSTEM=1`.
- **Inherited environment.** Unset `GIT_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT` and
  `GIT_CEILING_DIRECTORIES`. A `GIT_DIR` inherited from a hook or wrapper makes `git apply` treat the temp dir as a work
  tree. The `rev-parse` refusal catches that fail-closed, but a hermetic env should not depend on it.
- **Both are admin- or caller-controlled,** so this is fail-closed by the no-CR and reverse-check asserts. It is listed
  only so "hermetic" is literally true.
- **Nit:** `v16g4-sites.md` lines 53 and 118 still say "row 43". The halow site is row 42.

## Lifecycle and security, re-checked against §13

- **Dead-man refusal** (crash of the host mid-run, the common real trigger):
  - lease kept, lock released (Q2);
  - the next acquire refuses (`:285-290`);
  - `ble-recover` refuses again while the flag stays armed;
  - fail-closed ✅.
  - The person path needs the remedy text and a persistent record (m3).
- **Interrupted pty-commit:** the unreachable case is unspecified (m4).
- **Precheck:**
  - GET and trigger in one shell; no TOCTOU ✅;
  - an ssh drop before the GET leaves today's attribution (`trc`, same boot id) ✅;
  - the hex compare (m5.2).
- **Sandbox privilege:**
  - the userns path drops real root ✅ (as yello: `drop_caches` "Permission denied", host `/dev` not writable);
  - the root path must be the plain `-m` (m1a), which is why the non-vacuous host-`/dev` check (m1c) matters there.
- **Local unprivileged / compromised peer:**
  - no new port, secret or node input;
  - `derive_misc` uses a 0700 `mktemp -d`, and the provenance trust is unchanged (repo patch + sha-checked V file);
  - the node-side refusal adds no input.
  - ✅
- **Our own mistakes:**
  - m2.4 (a line form that passes every lint but drops the lease);
  - m5.2 (hex compare);
  - m6.1 (an unreviewable allowlist).

## Summary

| # | Sev | One line |
|---|---|---|
| m1 | MINOR | p5 sandbox: namespace order inverted vs `test-undo-lib.sh:12-15` (root + userns loses DAC on the 0750 home); bound `/dev/null` gives EACCES on `O_CREAT` unless tmpfs `mode=0755` (scratch), so main's control is INVALID; `/proc/1/root` marker check vacuous in a userns (EACCES = "absent"); `/tmp/run` mountpoint residue |
| m2 | MINOR | §13.1 test: `bootid`/`up_s` are lib functions (no PATH stub), `H`/`DMLOG` hard-coded, the reboot is `batman-slot` → run in the undo-lib namespace; the "before rm" + "same line" wording allows `rm; disarmed && reboot; exit 0`, which drops the lease → give the exact line and pin it |
| m3 | MINOR | refusal logged via `logger` (lost on the reboot the person will do; use `dm_log` to p6); no remedy text (a plain reboot boots the trial); provd stays stopped; `cmd_recover` removes `dm` records anyway; "every BLE unit refuses a dirty UART" overstates (tier B never calls `ble_state`; the kept lease is what stops it) |
| m4 | MINOR | pty-commit settle-failed = unreachable node: §13.2 specifies only the reachable case; `claim-lock-254.sh:46` does not pass `DV_DIR`, so the NEEDS-PERSON line never reaches `needs-person.txt`; bind the commit to `slot=TGT`, `boot≠b0`, `held=1` |
| m5 | MINOR | "daily-validation has no NEEDS-PERSON list" is false (`daily-validation.sh:84-87`, `prov-dv-254.sh:16-24`); `[ "$f" = 0 ]` on raw `0x%08x` word 6 is the round-7 BLOCKER trap (`slot-guard-254.sh:30-32`); no `reboot_and_wait` suite in the pre-merge device runs |
| m6 | MINOR | base64 line text makes allowlist rows unreviewable in PR diffs (text-last column instead); default `base64` wraps (172 lines > 57 B) → `-w0`; "exactly those rows" breaks on any incidental edit of a text-hit line; converted-list format and run mode unspecified |
| m7 | MINOR | `PR_USES_02` set after `pr_begin` passes the helper refusal without enforcement; "unreachable 02" undecided for other units; `pr_peer_after` `A 1` rationale holds only for `PR_USES_02` units |
| m8 | MINOR | ~20 superseded statements in §2–§9 (incl. the §4.2 per-site table and the §4.3 test lists) with no inline "→ §13.x" marker; fold §13 in before implementation |
| m9 | MINOR | `derive_misc`: add `GIT_ATTR_NOSYSTEM=1`, unset `GIT_DIR` / `GIT_WORK_TREE` / `GIT_CONFIG_PARAMETERS` / `GIT_CONFIG_COUNT`; nit: sites.md "row 43" |

Verified as asked:
- `exit 3` stops both callers (direct calls only, no EXIT trap);
- the lock is an fd-9 flock that exit releases (scratch);
- the §13.4 hermetic derive works on Git Bash with default `-p1` (scratch, CR=0, reverse-check rc 0), so the ⚠️ in
  §13.4 can become ✅.
