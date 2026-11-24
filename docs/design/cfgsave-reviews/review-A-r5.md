# Review A, round 5 — cfgsave-stage-enospc (d0c3f7e..3781b00, the whole design v5 re-checked)

Reviewer A. Scope: the round-5 change `d0c3f7e..3781b00` (e30f746 product + tests, 3781b00 design v5), then a re-read of the whole design v5 looking for contradictions.

Ground rules for this round:
- The code was read only. Runs were on my own fresh clone `<home>/rev-cfgA5`, cloned from `Batman-app` with HEAD checked to be `3781b00`, in WSL Ubuntu-24.04 as root.
- No node was touched. No commit, no stash.
- Before running, I grepped my scripts for `sed -i`, `mv`, `cp` and `of=` aimed at `/dev/null` and found none.
- `cmp` shows the feed and deploy copies of `batman-config-save` are identical ✅.

**Verdict: APPROVE-WITH-CHANGES.** There is no BLOCKER and no product MAJOR. There is one test MAJOR (F1): the test's teardown leaks dm and loop devices, it is the likely cause of the fixer's ❓, and it was reproduced 40/40. The product changes are correct and each one has a negative control.

## 1. Runs

| # | What | Result |
|---|---|---|
| H ×3 | HEAD test on the HEAD script, `CFGSAVE_REQUIRE_DM=1`, back to back (two of B's runs and one of my own ran at the same time) | ✅ `PASS=103 FAIL=0` ×3 (105 / 110 / 112 s) |
| R4 | HEAD test on the d0c3f7e (v4) script, the round-5 negative control | ✅ `PASS=97 FAIL=6`. The six fails are exactly the round-5 cases: unmountable text ×2 (no mount error), healthy busy p5 ×3 (`rc 5 unverifiable`), and `--seed unreadable` (`formatting … mkfs.ext4 failed`: the old code really tries to mkfs) |
| V1 / B | HEAD test on the 6d65ecd / 4eba26d scripts | ✅ `74/29` / `17/86`, matching your runs |
| MA | Mutant: `busy=""` (busy detection removed) | ✅ `100/3` (healthy busy p5 ×3 → `unverifiable (p5 does not mount read-only: mount: mounting … )`) |
| MB | Mutant: `p5_matches` keeps using `$P5R/.seeded` but compares `overrides.uci` against `$MNT` | ✅ `102/1`: `healthy p5 mounted rw elsewhere, p5 == live: rc 5 … identity-or-schema`. So the test does catch a compare that reads the wrong tree |
| S | `slot-p5gate-txn.sh` (HEAD) | ✅ `21/0` |
| ST | The test's setup and teardown sequence repeated 40 times (§2 (5)) | ❌ `dmsetup remove` gets **EBUSY 40/40** right after mkfs |
| N | Full test with the node's busybox | §4 |

## 2. Your points

### (1) `--seed` now refuses an unreadable superblock: can a first boot or a fresh card fail to seed for good?

- **Who calls `--seed`:** I grepped feed/, deploy/ and scripts/. Only a person runs `--seed`: at deployment (`scripts/depersonalise.sh:116`) and as the `--seed --reformat` hint in `batman-slot:590`. No boot hook and no daemon calls it automatically. The automatic first-seed paths are `--on-join` and `--save` (#202 G4), and they did not change. If the magic cannot be read they still stop at "not plain ext4" with rc 1, and joinwatch tries again next tick, as before.
- **What the operator sees:** stderr `refusing --seed: p5's superblock cannot be read (I/O error?) — not formatting it; check the card`, rc 1. Nothing is written and nothing on p5 changes (the case checks the hashes are identical).
- **Is there a retry?** Running it again is the retry. A transient read error passes on the next try. A persistent one never formats, which is the point: a card that cannot be read must not be mkfs'd (lkg, identity and the prov record would be lost).
- **A fresh card from the build:** `build-ab-image.sh` already formats p5 as ext4 (`mkfs.ext4 … -L batconfig`). Its magic is `53ef`, so it never reaches this branch. Only a readable raw or zeroed p5 is still formatted; the control case passes (`--seed on a readable zeroed p5 formats and seeds (rc 0)`).
- **`--seed --reformat`:** that branch is only taken when the magic reads `53ef`, so an unreadable p5 hits the refusal first. Also correct.
- No finding.

### (2) The P5R refactor: can a write path now read the wrong tree?

- **Assignment:** `P5R` is set to another process's mount point only inside the `--check` mount branch (the `else` branch). After the mount block, `[ -n "$P5R" ] || P5R=$MNT`, so in every write mode and in `--prov-get` / `--prov-only`, `P5R` equals `$MNT`.
- **Every `$MNT` use after the mount block** (lines 493-741):
  - `identity_mismatch "$MNT"` and the pi3 gate run only when WRITE=1;
  - `--prov-get` / `--prov-only` keep their own mount;
  - all write-mode stage, rename and probe steps use `$MNT`, which equals `P5R`;
  - the `--check` section uses only `$P5R` (`prov_compare`, `.seeded`, `p5_matches`, `diff_keys`).

  No path mixes the two trees ✅.
- **Negative control:** MB.
- **Cleanup in the busy case:** our `$MNT` was never mounted, so `cleanup` only runs `rmdir` on it. It never unmounts or writes to the other process's mount ✅ (the case asserts `umount "$mp"` itself and then checks).
- **Who can create the "other" mount?** `/proc/self/mountinfo` lists only our own mount namespace. Mounting an ext4 block device needs root (ext4 is not `FS_USERNS_MOUNT`), so an unprivileged process cannot point `--check` at a tree it controls.
- **The match is narrow:** major:minor (`ls -lnL` gives `179,` and `5`; checked on both busybox builds in round 4), plus `$4 == "/"` (no bind mounts of a subdirectory), plus not our own mount point. A path that mountinfo escapes (`\040`) fails `[ -d ]` → rc 5 "busy … could not be compared" (fail-closed, and tested).

### (3) The rc 5 text now carries the mount error (one line, 160 characters): can it leak something or break a parser?

- **Content:** the last non-empty line of `mount`'s stderr, with CR removed and cut to 160 characters. With util-linux or busybox that is `mount: mounting <DEV> on <our tmpd mount point> failed: <errno text>` or `… already mounted or mount point busy`. It holds only the device name, our own run-dir path and the errno text. No secret, no config value, no user input ✅.
- **`batman-slot`:**
  - The `keys` sed takes the first word after `p5 stale: `, which gives `unverifiable`.
  - The `*"p5 stale: prov-identity"*` / `*"p5 stale: prov"*` patterns cannot match, because the line starts `p5 stale: unverifiable (` and the mount text contains neither string.
  - The unverifiable branch `sed 's/.*p5 stale: unverifiable (\(.*\))$/\1/p'` is greedy. The product appends the closing `)` after the 160-character cut, so the line always ends in `)` and `why` gets the whole text ✅.
  - The two failing cases (`unmountable without / with the marker`) check this text exactly.
- **Go `parseCheck` / `onlyP3Stale` (`status.go:53-82`):**
  - rc 5 plus `p5 stale` gives "stale".
  - `onlyP3Stale` takes everything after `p5 stale: `. `unverifiable (…)` is not a P3 key, so the result is false ✅.
- **The new informational line in the busy case** (`p5 is mounted at X by another process — compared through that mount (read-only)`) is printed before the verdict line:
  - batman-slot's sed is anchored to the `p5 stale:` line;
  - `parseCheck` uses `Contains`;
  - `onlyP3Stale` uses `Index("p5 stale: ")`, which still lands on the verdict line because the informational line does not contain that string;
  - `halow-setkey:130` prints both lines with the `persist:` prefix, which is only cosmetic ✅.

### (4) The busy path itself

- The fix for B-r4 MAJOR-1 is verified by the busy cases (rw fresh → rc 0, rw stale → the real stale verdict, ro → fresh, escaped path → rc 5) and by the negative controls R4 and MA ✅.
- The comparison reads a tree that another process may have mounted rw, possibly while it is writing to it. `--check` holds `cfgsave.lock`, so config-save's own writers are excluded. A writer that does not take the lock (an operator's shell) can make the verdict a snapshot of a moving tree. That is the same as any read, and the OTA gate decides on it once. No finding.

### (5) The fixer's ❓ run: is there a race in the test's setup or teardown?

**Teardown: yes, a deterministic leak.** It is reproduced and attributed with evidence, but not flip-tested.
- ST runs the test's own sequence 40 times: `losetup -f --show` → `dmsetup create` → `mkfs.ext4` on the dm device → `dmsetup remove`.
- `dmsetup remove` fails **40/40** with `remove ioctl … failed: Device or resource busy`.
- WSL runs `systemd-udevd` (`pgrep -a udevd` → `/usr/lib/systemd/systemd-udevd`), which probes the new filesystem right after mkfs closes it.
- In ST, `dmsetup remove --retry` succeeded every time, and the later `losetup -d` never failed.
- The test's `cleanup()` runs `dmsetup remove "$DMN" 2>/dev/null` with no retry and no check, then `losetup -d`, which on a loop still held by dm only sets autoclear. The test's last step before exit is the product's `--seed` (mkfs) on the zeroed p5, the same pattern as ST. The likely result is a leaked dm device plus its loop: the "left its own dm/loop devices" half of the ❓.
- **Seen in the field:** after my runs, `cfgenospc62504` was left with `open=0` and no living owner, table `linear 7:1`, on `/dev/loop1` whose backing file is `/tmp/tmp.wap3NVNBOa/p5.img (deleted)`. So the run's `rm -rf $W` ran but the dm remove failed. ⚠️ The owner is inferred from the PID order: most likely my H2 or H3. I did not delete it, because I cannot prove it is mine (see §5).

**Setup EBUSY (PASS=3 FAIL=95 within 2 s): still ❓.** I could not reproduce it (ST had 0 setup errors in 40 cycles, and H ×3 passed). The symptoms (K=1 setup: the mount says "already mounted or mount point busy", mkfs says "in use by the system") mean the run's own dm device was already mounted when the next case started. Two candidates, neither proven:
- a product `umount` that failed silently in the previous case (`cleanup`: `umount "$MNT" 2>/dev/null`, which fails with EBUSY if any process has a file or cwd in that mount);
- concurrent runs in the shared WSL. While my H runs were going, B was running two instances in parallel, and the coordinator and the fixer use the same WSL. dm names are global and are built from `$$`. A run under another PID namespace (one live W directory had no matching PID visible to me) could reuse the same name.

See F1 and F2.

## 3. Findings

### F1 — MAJOR (test): `cleanup()` leaks the dm device and its loop (`dmsetup remove` gets EBUSY from udev's probe after mkfs)

- **Evidence:** §2 (5): ST 40/40, and an orphan `cfgenospc62504` / `loop1 (deleted)` left behind.
- **Effects:**
  - every run can leave devices behind (loop and dm numbers pile up, the next run sees an unexpected `dmsetup ls`);
  - the suite reports PASS while leaving the host dirty;
  - by the owner's rule, a test whose own setup or teardown fails must not stay silent.
- **Fix:**
  - in `cleanup`, run `udevadm settle` first, then `dmsetup remove --retry "$DMN"`, then `losetup -d`;
  - afterwards check that `dmsetup info "$DMN"` fails and that `losetup -j $W/p5.img` is empty; otherwise print `FAIL teardown: …` (the trap can raise rc);
  - run `udevadm settle` after `dmsetup create` and before every `mkfs` / `dmtab` as well.
- **Negative control:** run the test back to back 10 times; after each run, `dmsetup ls | grep cfgenospc` must list only living owners.

### F2 — MINOR (test): make setup failures attributable, and make dm names unique

- At the start of each `case_run` / `fresh`, assert that `$DEV` is not mounted (`grep "^$DEV " /proc/mounts`). If it is, print the holder (`fuser -vm`, or the mountinfo line) and FAIL that case only, instead of letting every later case collapse.
- Name the dm device after `$W` (for example `cfgenospc-$(basename $W)`) instead of `$$`, which is not unique across PID namespaces or concurrent runs.
- Optionally, take a host-wide `flock` so that two instances of this test never run at the same time. This is in the spirit of the owner's rule that long-running orchestrators take a host-side lock.

### F3 — MINOR (product, information only): the product's own `umount` failure is silent

- `cleanup()` and the publish path use `umount "$MNT" 2>/dev/null`. If it fails, p5 stays mounted rw under the run dir. That is exactly the "healthy busy p5" that v5 now handles, so it is safe now.
- Still, a `logger` line when `umount` fails would make the cause visible (it is one candidate for the ❓ above).
- Not required for this PR.

## 4. The whole design v5, and N

- **§3:** v5 corrects v4's sentence that "ro,noload next to a mounted ext4 does not fail" (it fails when the existing mount is rw). The busy path and the "does not mount: <error>" text match the code ✅.
- **§7:** the failure-mode text (a healthy busy p5 is judged through its mount; only "not mounted anywhere and does not mount" gives rc 5) matches ✅.
- **§9:** the `--seed` mkfs item was removed because it is now fixed ✅.
- **§8:**
  - The fixer's ❓ is recorded honestly as unattributed. With F1, its "left devices" half now has a likely cause.
  - The "6d65ecd = deterministic list + timing-dependent cases" description is consistent with my V1 `74/29`.
- I found no remaining contradiction.

**N (full test, node busybox):** ✅ `CFGSAVE_BB="qemu-aarch64-static -L <root-bcm27xx> …/bin/busybox"` (a53 build), `CFGSAVE_REQUIRE_DM=1`: `PASS=103 FAIL=0`, 736 s. Several of B's runs were going at the same time.

## 5. Wrap-up

- I did not delete the orphan `cfgenospc62504` (open 0, owner gone, its loop's backing file deleted), because I could not prove it was mine.
- When my last run finished, `dmsetup ls` printed `No devices found` and `losetup -a` was empty, so someone else had removed it in the meantime.
- `/dev/null` is still `character special file 1:3`.
- My stress loop removed its own devices with `--retry`; every `losetup -d` succeeded.
- ❌ Not done:
  - no node;
  - no GitHub CI;
  - no sbx;
  - F1 has no flip test: no run with `--retry` / `settle` in the test's `cleanup` showing the leak goes away;
  - the setup EBUSY in the ❓ was not reproduced.
