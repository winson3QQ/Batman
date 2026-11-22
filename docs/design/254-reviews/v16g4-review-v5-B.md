# v1.6 group 4 (harness PR A) design review v5 — reviewer B

Design: `docs/design/254-v16-group4.md` v5 (HEAD 1780502 of `test/254-v16-group4`, base main b885a2c), read as a whole
with `v16g4-review-v{1,2,3,4}-{A,B}.md` and `v16g4-sites.md`. §13 taken as binding.

Method: read-only `grep` / `sed` / `git show` in `C:\src\Batman-g4h` (line numbers are b885a2c; nothing under
`scripts/` or `feed/` differs at HEAD). Scratch experiments in my scratchpad only:
- a shell model of `cmd_dm_fire` / `cmd_recover` with `exit 3` in `role_fire_restore` (Git Bash `sh`);
- `git apply` of `tests/wbox/misc-l38.patch` with the §13.4 hermetic options on the repo path, outside any work tree
  (Git Bash git);
- WSL Ubuntu-24.04 **as yello (uid 1000), kernel 6.6.114.1**: `unshare -Urm --propagation private`, tmpfs over
  `/dev`, the host `/dev/null` bind-mounted in, `/proc/1/root/dev` read from inside.

No ssh, no harness script against a node, nothing as root, no repo file touched except this report.

**Verdict: APPROVE-WITH-CHANGES.** No BLOCKER, no MAJOR. My v4 MAJOR is resolved: `exit 3` inside `role_fire_restore`
really skips the lease `rm` in both callers, and the specified test drives the real callers, so it can see a
regression. Eight MINORs. Most are spec gaps that would show up as a red test. Two are wrong or vacuous safety
details that should be fixed in the text before coding: the p5 sandbox (MINOR-3) and pty-commit's non-commit paths
(MINOR-4).

## v4 findings — resolution check

### Reviewer B (mine)

| v4 | v5 | Status |
|---|---|---|
| M1 refused dead-man drops the lease | §13.1 `exit 3` in `role_fire_restore`; test drives `cmd_dm_fire` / `cmd_recover` | ✅ see focus check 1. ⚠️ ordering text, test harness, `RECOVER-REFUSED` owner (MINOR-1, MINOR-2) |
| M1b `bt305-dirty` in `ble_state` | §13.1 | ✅ consistent with every `ble_state` parser (focus check 2) |
| m1 offline tests "on the Windows host" | §13.5 withdrawn; one Git Bash smoke run for the PR | ✅ |
| m2 sandbox `/dev/null`; use userns | §13.6 userns first, bind host nodes | ❌ a bind-mounted `/dev/null` cannot be written in the userns (probe, MINOR-3) |
| m3 "twice" from B; `PR_USES_02` enforcement; `pr_acquire` | §13.3 | ✅ texts and `pr_acquire`. ⚠️ the grep keys on helper names, not on 02 operations (MINOR-5) |
| m4 `:575` rationale | §13.10 | ✅ (body §4.2 not marked, MINOR-8) |
| m5 `-p4` / case names | §13.4 repo path + default `-p1`; exact strings read from the file | ✅ scratch: `--check` rc 0, apply rc 0, `-R --check` rc 0, 0 CR bytes (output below) |
| m6 rows 36–38 lint-invisible; generator; `*.sh` | §13.1 same line; §13.8 | ✅. ⚠️ "exactly those rows" (MINOR-7) |
| m7 DISARM in trials | §13.9 | ✅ in §13.9; ❌ §13.9 says "§7 is corrected" but §7 is unchanged (MINOR-8) |
| m8 pty-commit bad-slot | §13.2 | ⚠️ partly (MINOR-4) |
| m9 precheck form / output / device run | §13.7 if/else, output captured | ✅. ⚠️ wrong reason for not blocking (MINOR-6) |
| m10 §10 / §11 history | §13.11 | ✅ the §10 and §11 cells are marked |

### Reviewer A

| v4 A | v5 | Status |
|---|---|---|
| m1 apply path, attributes, SHA256SUMS | §13.4 | ✅ verified; one `SHA256SUMS` line fits `prov-misc-254.sh:33` (`sha256sum -c --quiet`) |
| m2 where the tests run; namespace pattern | §13.5, §13.6 | ✅ / ⚠️ MINOR-3 |
| m3 sandbox check, `/dev/null`, prefix, residue | §13.6 | ⚠️ the chosen check and the chosen `/dev/null` both fail in the userns (MINOR-3); prefix and residue ✅ |
| m4 precheck shape | §13.7 | ✅ |
| m5 tabs, rows 36–38, independent expectation | §13.8 base64, same line, `slot-sites-converted.txt` | ✅ |
| m6 02 enforcement, trial FAILs, `pr_peer_after` | §13.3 | ✅ / ⚠️ MINOR-5 |
| m7 pty-commit | §13.2 | ⚠️ A's own fix (slot = TGT, `held=1`, NEEDS-PERSON otherwise) was only partly adopted (MINOR-4) |
| m8 Pi 3 | §13.7, §14 | ✅ |
| m9 flag writers | §13.9 | ✅ (§7 itself not edited, MINOR-8) |

## Focus checks

### 1. Does `exit 3` in `role_fire_restore` skip the `rm` in both callers? Yes

- Both callers call the function in the main shell, with no subshell, pipeline or `$( )`:
  - `cmd_dm_fire` (`ble-lib-254.sh:341`, then `:342-343` `provd_start; rm -f "$LEASE" "$ST/dm" "$ST/dm.new"`);
  - `cmd_recover` (`:354`, then `:355-357` `provd_start; rm -f "$BT/lease" …; echo "RECOVERED"`).
- The dispatchers call `cmd_dm_fire` / `cmd_recover` directly:
  - `ble-central-254.sh:108,118`;
  - `ble-periph-254.sh:205,215`;
  - `bt-uart-305.sh:306,318`.
- `dm_arm` launches the dead-man as `setsid sh "$3" dm-fire …` (`:148`), its own process. So the `exit` ends exactly
  the dead-man or the `recover` invocation.
- The lock is `exec 9>>"$BT/lock"` + `flock` (`:100-101`), and is released with the process.
- Scratch model (the functions as in the callers, `role_fire_restore` refusing with `exit 3`):
  ```
  deadman: tryboot not cleared — no reboot, lease kept
  rc=3
  lease            <- dm-fire: still there
  deadman: tryboot not cleared — no reboot, lease kept
  rc=3
  lease            <- recover: still there, no RECOVERED
  ```
- What the next run sees: the lease is of this boot, expired, and its dead-man is dead.
  - `ble_state` FAILs "leftover: BLE lease of run X" (`:254-256`), which stops preflight P6 (`dv-preflight.sh:83-86`).
  - `cmd_acquire` dies with "run X did not clean up … run ble-recover first" (`:288`). That stops the next tier-B
    run (`ble_begin`, `scripts/dv/ble-254.sh:29`) and the next bt305 run (`bt305_leased`, `scripts/dv/bt-uart-305.sh:69`).

  So the kept lease alone fails closed on both paths.
- Negative control: on b885a2c the `STUB_DISARM_FAIL` case reboots and the lease goes, so the specified test FAILs
  there. A `return 3` variant FAILs "lease still there" through the real `cmd_dm_fire`. ✅ discriminating.

### 2. `bt305-dirty` in `ble_state` vs its parsers: consistent

- `mark_set` writes `"<bootid> <text>"` (`:120`) and `mark_here` checks the boot (`:121`). A `fail` line in
  `ble_state` prints `FAIL …` and sets `r=1`, so `STATE clean` is suppressed (`:273`).
- The parsers:
  - preflight P6 (`dv-preflight.sh:83-86`): `^STATE clean` → ok; `^FAIL` → one `f` per line. It runs on every bcm2711
    in `$ALL`, so it covers the bt305 node too;
  - `ble-privacy-254.sh:47`: `ble_state || rc=1`;
  - the tail of `cmd_recover` (`:357`).
- None of them runs while a legitimate `bt305-dirty` of the same boot is expected:
  - bt305's own host flow never calls `state`;
  - a marker left by a failed flip restore (`bt-uart-305.sh:211`) now stops the next BLE preflight. That is the
    intended fail-closed outcome.

### 3. The host's reaction to rc 3 / `RECOVER-REFUSED`: no host code exists. See MINOR-2.

### 4. §13.4: verified on Git Bash

The base was placed at `feed/batman-provision/files/usr/bin/batman-autocommit` in a non-repo dir (`fatal: not a git
repository`), with the hermetic env + `-c core.autocrlf=false -c core.eol=lf -c core.attributesFile=/dev/null`.
Output:
```
Checking patch feed/batman-provision/files/usr/bin/batman-autocommit...
Hunk #2 succeeded at 441 (offset 39 lines).
rc=0
Applied patch feed/batman-provision/files/usr/bin/batman-autocommit cleanly.
rc=0
rrc=0          (-R --check)
0              (CR bytes in the output)
```

## Findings

### MINOR-1 — §13.1: the order "check before any `rm`" vs "`DISARMED && reboot` on one line" is ambiguous; the test harness is unspecified

**Evidence.** Today the `rm` is on the line *before* the reboot:
- `ble-central-254.sh:100-101`, `ble-periph-254.sh:195-196`, `bt-uart-305.sh:296-297`:
  `rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"` / `batman-slot reboot committed …; exit 0`.

Read literally, "`DISARMED && reboot`" on line 101 leaves the `rm` before the check: the v4 MAJOR again. The test
would catch that, which is why this is a MINOR.

**Test harness.**
- `H`, `BT` and `ST` are hard-set in `ble-lib-254.sh:8-10`, so they cannot be overridden.
- `ble-central` / `ble-periph` cannot be sourced without dispatching: `*) die "unknown command"` at the end. Only
  bt305 has `BT305_LIB_ONLY`.
- The reboot is `batman-slot reboot committed`, not `reboot`.

So "stubs `vcmailbox`, `reboot`, `bootid`, `up_s`" does not say how the real scripts are run off-node. The obvious
way writes the host's `/tmp/run/batman-dv`.

**Fix.**
1. Write the line out, for example:
   `dm_disarmed || dm_refuse "$1"; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed ble-dm-254; exit 0`
   where `dm_refuse` does the print, the `logger` and `exit 3`.
2. Run the test in `unshare -Urm` with a tmpfs over `/tmp` (the §13.6 pattern), staging the real files.
3. Stub `batman-slot` and `vcmailbox` on PATH, and write the marker and the lease with the real boot id.
4. Cover 3 roles × 2 callers.

### MINOR-2 — §13.1: `RECOVER-REFUSED` has no owner; the operator path loops

**Evidence.**
- "The caller sees rc 3 … It prints `RECOVER-REFUSED`, and the host FAILs." On the node the caller cannot: the process
  has exited.
- On the host, `ble_recover` (`scripts/lib/ble-254.sh:68`) has **no caller** in any script (grep). It is a manual tool
  that P6 points at.
- bt305 has no host recover at all: `ble_n` runs `ble-$role-254.sh`, so it cannot address `bt-uart-305.sh`.

**Also inaccurate or missing in §13.1.**
- "`dm`, `dm.new` stay" is false for `recover`: `cmd_recover` removes them first (`:350`).
- provd stays stopped after the refusal (`provd_start` is skipped). v4 fix item 1 asked for this to be stated, and
  it is not.
- After a refusal, the next run sees only "leftover: BLE lease of run X" (`:256`) or "run ble-recover first" (`:288`).
  `ble-recover` refuses again for the same cause, which is persistent (word 5 unanswered), so the operator is sent in
  a loop with no cause named.

**Fix.**
1. `dm_refuse` prints `RECOVER-REFUSED <reason>` itself when `$1 = recover`.
2. `dm_refuse` also writes `dm_log` (the p6 record the reboot branches already use) and `mark_set dm-refused
   "<reason>"`.
3. `ble_state` names `dm-refused` with the remedy: check the flag, reboot by hand.
4. State that provd stays stopped.
5. State that there is no automatic host caller of `recover`.

### MINOR-3 — §13.6: a bind-mounted host `/dev/null` cannot be written in the user namespace, and the `/proc/1/root` check is vacuous there

**Probe** (WSL as yello, `unshare -Urm --propagation private`, tmpfs over `/dev`, host `/dev/null` bind-mounted onto a
file in it):
```
A: bind-mounted host /dev/null:
sh: 1: cannot create /dev/null: Permission denied
rc=2                      <- `echo … 2>/dev/null`: the command did NOT run
read-rc=0                 <- `</dev/null` works
B: regular file /dev/null:
rc=0
C: /proc/1/root/dev from inside:
test -e says absent       <- vacuous
ls rc=2 ls: cannot access '/proc/1/root/dev': Permission denied
```

**Consequence.**
- Every `cmd >/dev/null` / `2>/dev/null` in `prov-base-254.sh` would be skipped. So main dies elsewhere (INVALID), and
  the fix's cases FAIL: a red test, not a false pass.
- This is what my v4 m2 reported. §13.6 took A's bind suggestion instead.
- The marker check through `/proc/1/root/dev` needs ptrace access to PID 1. That is denied in any child userns, also
  for real root under `unshare -Urm`, so `[ ! -e … ]` passes whatever happened.
- Not probed as real root: that is outside my rules.

**Fix.**
1. Make `null` / `zero` regular files (`chmod 666`), or `mknod` only on the real-root `unshare -m` path. `urandom` can
   be a file of random bytes.
2. Replace the sandbox check with A's v4 list:
   - `[ -f /dev/mmcblk0p5 ] && [ ! -b /dev/mmcblk0p5 ]`;
   - the last `/dev` line of `/proc/self/mounts` is `tmpfs`;
   - any `EACCES` in the check is a FAIL, never "absent".

### MINOR-4 — §13.2: the commit is bound to the boot only, and the unreachable / reverted paths still have no NEEDS-PERSON

**Evidence.**
- The settle-failed path is `pty-commit-254.sh:59`: the node was *unreachable* for 600 s.
- `stop()`'s read through `q` (`:21`, 6 × 120 s) then returns nothing. With no boot there is no `commit_guarded`
  answer, and §13.2 writes `needs-person.txt` only on a guard refusal.
- The same holds when the landing trial has already reverted: not in a trial, `bad-slot` set. Every later prov unit
  is then blocked by `pr_p9` "bad-slot present", and pty-commit by `:46`, with no `dnode_blocked` line.
- The commit uses the slot that was *read*, not `TGT`. `stop()` knows `TGT`, `V` and `held`. v4 A m7's fix used them.

**Fix.**
1. Commit only if boot ≠ `b0`, slot = `TGT`, `ver = V`, `held=1` and in a trial: `commit_guarded <boot> "$TGT"`.
2. Every outcome other than SENT followed by a read-back "committed" writes the NEEDS-PERSON line. That covers no
   answer, an empty read, not in a trial, `bad-slot` present and WRONG-STATE.
3. Add one stub case per outcome.

### MINOR-5 — §13.3: the enforcement keys on helper names, not on the operations that change 02's slot

**Evidence.**
- `as02` and `restore02` are local functions of `prov-netjoin-fleet-254.sh` (`:29`, `:74`). Fleetchan part 1 is
  inline in its own unit.
- "Refuse unless `PR_USES_02=1`" inside the very scripts that set it guards nothing new.
- A future unit that OTAs or rolls back 02 the way fleetchan does would not be caught by a grep for those names:
  - `qp "setsid sh -c 'sysupgrade …`, `prov-ac-fleetchan-254.sh:34`;
  - `qp "$(rb_guarded …`, `:41`;
  - `scp … root@$PEER`, `:30`.

**Fix.** Grep `scripts/dv/prov-*.sh` for those operations, including `reboot_guarded` / `commit_guarded` sent through
`qp`, as well as for `as02` / `restore02`. A file with a hit must set `PR_USES_02=1`. Zero matching files → FAIL.

### MINOR-6 — §13.7: "daily-validation has no NEEDS-PERSON list" is false

`daily-validation.sh:86-87` runs `dnode_blocked`, which reads `$DIR/needs-person.txt`, before every D suite.
- Not writing it on a refused precheck may still be right: every later D suite FAILs with its own clear text, and
  nothing on the node changed.
- But state that as the reason, and drop the false one.

### MINOR-7 — §13.8: "must name exactly those rows" ignores the new text rows

This PR adds lines that contain `\breboot\b`:
- the dead-man refusal text;
- the `reboot_and_wait` FAIL texts "not rebooting";
- pty-commit messages, if any.

Each is a lint (3) `text` row with no hit on b885a2c, so the b885a2c run names more than the converted-site list, and
an "exactly" comparison is red.

**Fix:** compare only the site rows, and require the extra named rows to be `text` rows added by this PR. Or list them
in `slot-sites-converted.txt`.

### MINOR-8 — the body still contradicts §13, and §13.9 claims an edit that was not made

§13 wins by rule. But an implementer working from §4.2's table or §7 gets the old behaviour, and §13.9 says "§7 is
corrected" while §7 is unchanged.

| Section | Says | Superseded by |
|---|---|---|
| §7 tryboot row | "cleared only on a committed node" | §13.9 |
| §7 misc row | "SHA256SUMS records the base sha and the patch blob id"; "CI and the Windows host" | §13.4, §13.5 |
| §2 | step 1 `usr/bin/` copy; step 4 SHA256SUMS contents; "on the Windows host"; "L38 a / L38 b" | §13.4, §13.5 |
| §3.1 | trial / unreachable → NOTE for other units; "twice"; `pl acquire` | §13.3 |
| §3.2 | "as root, inside `unshare -m`"; "nothing outside … writable" | §13.6 |
| §4.1 | "clears the flag only on a committed node" | §13.9 |
| §4.2 row 11/12 | `:575` reason | §13.10 |
| §4.2 row 13 | "landing boot unknown — not committing" | §13.2 |
| §4.2 rows 24–31 | the `&& … \|\|` form | §13.7 |
| §4.2 rows 36–38 | prefix before the `rm`; bt305 dv-start precondition; body extraction | §13.1 |
| §4.3 | test locations; "172 hits" | §13.5, §13.8 |
| §8 delivery step 1 | "v4 review" | — |
| §12 row A M1 | "also runs on the Windows host" | §13.5 |

**Fix:** fold §13 into the body before the code PR, or mark each cell "superseded by §13.x" as was done for §10 / §11.

## Lifecycle and security, re-checked (delta only)

- **Dead-man refusal** (crash of the host, node alive):
  - the lease, the markers and the run dir are kept;
  - provd is stopped;
  - the IRK stays live until a person reboots (§9 trade-off).

  Every next run stops at P6 or at `acquire`. ✅ fail-closed. Operator path: MINOR-2.
- **Power loss / reboot after a refusal:** tmpfs clears the lease and the markers. Boot-scoped `mark_here` and the
  lease's boot id make an earlier boot's records void. ✅ unchanged.
- **Downgrade** (an old image without `bootfacts.sh` / word 5): `bf_get` → unknown → the node dead-men refuse,
  persistently. This is consistent with "old image refuses closed" (§8), but every BLE tier-B host death on such an
  image needs a person. Worth one line in §8.
- **Security:**
  - The new inputs are the `PR_USES_02` grep and base64 inventory rows. Both are repo content.
  - The sandbox safety check: MINOR-3 (vacuous in the userns, where an unprivileged run cannot reach host devices
    anyway; the real-root path needs the non-vacuous check).

## Summary

| # | Sev | Area | One line |
|---|---|---|---|
| — | — | v4 B MAJOR | resolved: `exit 3` skips the `rm` in `cmd_dm_fire` and `cmd_recover` (no subshell callers; scratch rc 3, lease kept), and the test drives the real callers |
| 1 | MINOR | §13.1 | "before any `rm`" vs "`DISARMED && reboot` same line": today the `rm` is on the line before the reboot; spell out the line; the test needs a namespace (`H` hard-set, central/periph not sourceable), a `batman-slot` stub, and 3 roles × 2 callers |
| 2 | MINOR | §13.1 | `RECOVER-REFUSED` cannot come from the exited node caller; `ble_recover` has no caller and bt305 has none; `dm` records are not kept on recover; provd stays stopped (unstated); add `dm_log` + a `dm-refused` marker named by `ble_state` |
| 3 | MINOR | §13.6 | probe: bind-mounted `/dev/null` in `unshare -Urm` → "cannot create /dev/null: Permission denied" and the command does not run; `/proc/1/root/dev` is EACCES → the marker check is vacuous; use regular files and `[ -f ] && [ ! -b ]` + mounts |
| 4 | MINOR | §13.2 | pty-commit: bind to `TGT`/`V`/`held`/boot ≠ `b0`; unreachable (the `:59` path itself) and already-reverted outcomes still write no NEEDS-PERSON |
| 5 | MINOR | §13.3 | the grep keys on `as02`/`restore02` (local functions); a new unit OTAing 02 via `qp sysupgrade` / `qp rb_guarded` is not caught |
| 6 | MINOR | §13.7 | "daily-validation has no NEEDS-PERSON list" is false (`daily-validation.sh:86-87` `dnode_blocked`) |
| 7 | MINOR | §13.8 | "exactly those rows" breaks on the new `text` rows containing "reboot" |
| 8 | MINOR | body | §2/§3/§4/§7/§8/§12 still state superseded behaviour; §13.9 says "§7 is corrected" but it is not |
