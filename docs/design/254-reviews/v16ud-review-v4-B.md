# Review v4 (reviewer B) — `docs/design/254-v16-ud.md` at 8fdd143

I read the whole document again. I looked first at what the v4 changes could break: the watcher's sync / log / kill
order, the `kill-pg $!` + `ud9.go` start, the hex `ssid-restore` in the root executor, the reboot-during-UD6 (b) path,
the removal of ap-on, and the host-side observe gate. Read-only: no node, no ssh. The mesh-id history is not a finding
(owner).

## v3 findings: fixed in source terms?

| v3 finding | State | Evidence I checked |
|---|---|---|
| **B M1** global `sync` before acting | **Fixed.** The log is pre-created and synced once before any stream exists. Each line is then written with `dd … conv=notrunc,fsync`, which flushes the log file only; that `dd` form is proven on the node (`batman-slot:752`). Kill acts first and logs afterwards. `pos_final` is sampled from `/proc/<dd>/fdinfo/1` until the orphan `dd` is gone, so it is the byte count the orphan actually wrote: a strong judge. Cut logs `UD9-FIRE`, re-reads pos and logs `UD9-PRE-B`, then the sysrq. See MINOR-3 for the margin wording. | `batman-slot:752, 756-775`; `provstore/exec.go:93` |
| **B M2** unquoted `set --` | **Fixed.** The argument is hex only (`[0-9a-f]`, even length, or `-`), so nothing that globs or splits reaches `prov-undo-lib-254.sh:239-240`. The decode uses constant formats and the apply is quoted. See MINOR-2 for a validation mismatch. | `prov-undo-lib-254.sh:237-252`; `settingsset.go:66, 77-79` |
| B m1 `kill-pg` order | **Fixed.** Start, `$!`, `undo-add kill-pg $! ud9-watch` and `ud9.go` happen in one ssh call. The watcher does nothing before `ud9.go`, and it exits `UD9-MISS pgid` unless pgid = pid. The busybox `setsid` path is right: in a non-interactive shell the background child is not a group leader, so setsid() runs in-process and `$!` = pid = pgid. `kill-pg` checks that the leader's cmdline contains the tag (`ud9-watch`), and the entry is boot-bound. | `prov-undo-lib-254.sh:66-68, 76, 182-196` |
| B m2 §7 order, p6 binding, reboot detection | Order and binding **fixed** (`ssid-restore` → `p5-save` → `svc-start`; `p6 slot:A`). **The claimed repair after a reboot does not happen: MAJOR-1.** | `prov-undo-lib-254.sh:238` |
| B m3 inline `p5-save` | **Fixed** (`--save`, then `--check` rc 0 within 30 s, before `undo-done`) | — |
| B m4 ap-on untested | **Fixed by removal.** AP off at `pr_begin` → INVALID. `ap-restore` stays refused (`prov-undo-lib-254.sh:70`). No dangling references left (§5, §8). | — |
| B m5 wsl.35 `update-last` | **Fixed:** #255 checklist line (§12) | — |
| **A M1** kill judge relied on `SLOT DIE` | **Fixed.** The judge is: orphan gone, `pr_slot_free`, `bad=1`, 0 + 22, and `pos_final`. VERIFY is supporting evidence only; DIE is INFO. | `batman-slot:54-65, 765-770` |
| **A M2** UD4 boot-reasons | **Fixed.** Checked: B panics before userspace, so the cmdline `panic=10` applies, not the sysctl. On the A boot, `95-batman-storage` reports `PANIC` when a pstore dmesg record exists, and otherwise `CLEAN` from A's own pre-apply shutdown marker. So `CLEAN` → INVALID "B boot not proven" is the honest mapping, including #270's "pstore dump skipped" case. | `95-batman-storage:657-687` |
| A m1–m10 | Fixed as dispositioned (§16), spot-checked: row 11 carries `ul.Sha` (`updwork.go:884-887, 917`); the observe gate; `umask 022` + mode check; Q12 offline control cited | — |

## Findings

### MAJOR-1 — after a reboot (or host death) mid-arm, the stated automatic repair cannot run: P9 stops `pr_begin` before `pr_acquire`, and P9's remedy names a command that does not exist

**Scenario.** §7's last row:
- 04 reboots (power) while UD6 (b) has `dv-s<run8>` committed.
- The AP comes up on air under the test SSID, and joinwatch saves p5 fresh with it.
- §7 then claims: "Repair: the next prov unit's `pr_acquire` replays the p6 `ssid-restore` line … then the snapshot
  restore."

That path is unreachable:
- `pr_begin` runs P9 first and returns on any FAIL (`prov-254.sh:689`). `pr_acquire`, which holds the journal replay
  (`:209-214`), comes later (`:698`).
- After any interrupted arm, the prov dirty flag is still set. P9 FAILs on it (`prov-p9-254.sh:71`), so the next prov
  unit never reaches the replay.
- The remedy that P9 prints, "run `scripts/dv/prov-254.sh restore` for that run", has no entry point. `prov-254.sh` is
  a sourced library with no command dispatch, and no `scripts/dv/*restore*` script exists (only the offline
  `test-restore-254.sh`).
- `pr_normalise` also refuses while the dirty flag is present (`:906-907`).

**Result.** The AP stays on air under the test SSID, and the journal stays pending, until a person works out the steps
by hand. The new P9 WARN tells the person that something is wrong, but not what to run. The same gap applies to every
interrupted write / kill / trial arm (B left written, the lease journal, the snapshot), so this PR's recovery
statements in §7 are not met.

The gap is partly pre-existing (the missing restore command), but this design relies on it for its own lifecycle row,
and the user-visible side effect (a renamed AP) is new.

**Fix (either):**
- (a) Add a recovery entry point, e.g. `prov-update-254.sh recover <run>`, which:
  1. takes the lock and lease without the dirty-flag precondition;
  2. runs `undo-replay`;
  3. runs `pr_restore` with `PR_WROTE_B` decided from the snapshot's `protB` vs live;
  4. rewrites B;
  5. runs `pr_finish_snap`.

  Point P9's dirty-flag remedy at it, and add an offline stubbed test: a pending `ssid-restore` + dirty flag →
  recover → journal empty, flag gone.
- (b) Or state plainly in §7 and §1.7 that a mid-arm reboot or host death is NEEDS-PERSON. List the exact manual
  commands (`RUN_ID=<run> sh …/prov-lease-254.sh undo-replay`, then the snapshot restore and the B rewrite). Make the
  P9 WARN / FAIL lines print them. Record the missing restore entry on #254's checklist.

### MINOR-1 — §9 still lists v3's watcher test "write + `sync` happen before the action"

It contradicts v4's kill rule, "kill writes its line **after** the stubbed `kill`", listed a few lines lower in §9, and
the "no global `sync` after the start" test. Delete the stale line so the offline suite does not encode both orders.

### MINOR-2 — `ssid-restore`'s decode validation rejects ssids the product allows, and contradicts its own test

- §4.3 says the decoded value must be "1–32 characters, all from `apChars`", else CRIT.
- §9 expects the replay to restore `x'y` exactly. `'` is not in `apChars` (`settingsset.go:66`), and P3 explicitly
  designs for operator ssids with `'` (`SKIP_UNSAFE`, `batman-config-save:52-58`).
- An S0 ssid like "Tom's AP" would register fine (hex passes `uvalid`) and then fail to restore (CRIT), leaving the test
  ssid committed.

Hex already removes the injection risk, so the value check can be what uci holds: 1–32 bytes, no NUL and no newline.
Check it **at `undo-add`** by decoding the hex and comparing with the value just read; a mismatch is INVALID before the
change. Then the replay cannot CRIT on a value it accepted. Add `%` and `\` to the offline cases, because the decode goes
through `printf`.

### MINOR-3 — the cut sub-arm's "too late" bound needs its margin argument stated

`p2` is read **before** the `UD9-PRE-B` log write, and that write fsyncs the p6 log. The SD card is busy with B's
writeback, so that fsync can take up to about a second. So `p2 < SQ − 8 MiB` does not by itself prove where the stream
was when `b` landed.

It is still safe, because BAD is cleared only after the stream `dd` ends with its own full `conv=fsync` of tens of MB,
the boot files are copied, and an uncached read-back of about 112 MB finishes (`batman-slot:856, 735-775`). That is many
seconds, against one log fsync. Write that argument into §1.5 (or read `p2` after the log write and send `b` at once).
Otherwise the judge claims a precision it does not have.

### MINOR-4 — the observe gate is keyed by image version only

`~/.batman-dv/ud9-observe/<V>.txt` also needs the node identity (04's eth MAC, which the unit already checks) and the
date. Then an observation from another node or another card with the same image cannot open the kill arm.

### MINOR-5 — `pr_release` deletes the watcher's p6 log after printing only its sha

The owner's rule is that nothing is deleted from a live node's logs without printing exactly what goes. The file is at
most 4 KiB of result lines and no secret: print its content (non-blank lines) into the unit log, then remove it.

## What I looked for and found sound in v4

- **Watcher.**
  - The pre-sized file plus in-place `dd` never truncates or grows.
  - The watcher's own `dd` cannot match its stream filter: its parent is the watcher, not `batman-slot write`.
  - It starts only after `ud9.go`, so a host death before registration leaves a harmless watcher, bounded by the 900 s
    `/proc/uptime` deadline.
  - The kill check `pos_final` is measured after the fact, which is exactly what the "orphan got short data" claim
    needs.
- **Hex `ssid-restore`:** `uvalid` admits hex only; `uwhere` = `p6 slot:A`; the apply is quoted; `-` → `uci delete`.
- **Restore / compare:** the S0 `update-last` is kept byte-identical. The precondition is phase 0, no reason and no sha.
  `pl undo` runs before `pr_restore`, and `pr_release`'s undo must find nothing.
- **Runtime guard:** `pr_pc` refuses an unguarded prepare / apply whatever way the op name was built.
- **Security:**
  - A 471 process cannot create a uid-0 `batman-slot write` parent.
  - The helper pid comes from procd and is checked by exe and uid.
  - The new p6 log and the journal are root 0600.
  - ap-on is gone, so the unit creates no secret.
  - The pre-existing 0644 `/etc/config/wireless` goes to a #254 checklist line, and the unit checks it does not make
    it worse (`umask 022` + mode compare).

## Verdict

**REJECT for this round under the owner's rule (one MAJOR open).** 0 BLOCKER, 1 MAJOR, 5 MINOR.

All v3 BLOCKER / MAJOR findings of both reviewers are fixed in source terms. MAJOR-1 is about recovery honesty: either
add the recovery entry point, or state NEEDS-PERSON with exact commands. Once it is fixed, I expect APPROVE.
