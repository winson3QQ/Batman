# Review A, round 3: cfgsave-stage-enospc (design v3, 4eba26d..ec8b79a)

Reviewer A. I re-reviewed the whole change, not only v2 to v3. Code was read-only. The runs were on my own fresh clone `<home>/rev-cfgA3` (cloned from `Batman-app`, branch `fix/cfgsave-stage-enospc`, HEAD checked to be `ec8b79a`), in WSL Ubuntu-24.04 as root. No node touched; no commit, stash or push. No editing tool pointed at `/dev/null`; before the run my experiment scripts were grepped for `sed -i` / `mv` / `cp` onto `/dev/null`, and none were found. At the end, `/dev/null` was still `character special file 1:3`. The two copies of `batman-config-save` (feed and deploy) are byte-identical (`cmp` ✅).

**Verdict: APPROVE.** No BLOCKER or MAJOR finding. The three MINOR findings below can go into the original issue's checklist. Every finding from my v1 and v2 rounds has been handled and has a negative control.

## 1. Runs

| # | Run | Result |
|---|---|---|
| H ×3 | HEAD test, HEAD script, `CFGSAVE_REQUIRE_DM=1` | ✅ `PASS=91 FAIL=0` ×3 (93 / 94 / 90 s). The intermittent "may be PARTLY" FAIL from r2 (my F1) did not show up again. |
| V1 | HEAD test, script from 6d65ecd | ✅ `PASS=69 FAIL=22` (see §1.1) |
| B | HEAD test, script from 4eba26d | ✅ `PASS=13 FAIL=78`, same as the coordinator's run |
| S | `slot-p5gate-txn.sh`: HEAD / 6d65ecd / 4eba26d `batman-slot` | ✅ `21/0`; `21/2`; `21/2`. Both old versions fail the same two cases: `verdict=stale:unverifiable out=DIE: … is STALE … (unverifiable)` and `the refusal still shows P5_STALE_HINT` |
| M | Mutant: the fsync loop in the script made always false (`for f in $flist; do false \|\| not_saved …`), run through the four harnesses that now carry an fsync shim | `cfgsave-identity-freeze` `7/1` (HEAD `8/0`); `cfgsave-txn-save` `44/15` (HEAD `59/0`); `cfgsave-ssid` `3/4` (HEAD `7/0`); `cfgsave-frozen-nomount` PASS / PASS (see §2 (2)) |
| Z | Save with no identity file at all (no dropbear files, no `config.yml`, root locked `root:!`), on the stage-enospc harness setup | ✅ `--save rc=0 saved`, `--on-join rc=0 saved`. The count check (`nwant = 0 + 2 + LKG`) does not get in the way. |

### 1.1 Why my 6d65ecd run is 69/22 and yours is 70/21

My run has one extra FAIL: `--if-healthy EIO (all I/O) after staging + 6 s: … last-stderr-line:[rm: can't remove …]`. It is the same v1 eio6 "last line is `rm:`" case I described in r2: it fails only sometimes (0 of 9 times in r2, 1 of 3 here), because it depends on whether the cleanup `rm` has to read blocks from the failed device. The other 21 FAILs are the same in both runs.

v3 adds a fixed `chattr +i` control for "the last stderr line is the explanation" (`last-line control`). It FAILs on 6d65ecd (`rm: can't remove … Operation not permitted`) and PASSes on HEAD. So the negative control for that rule no longer depends on the eio6 timing ✅.

## 2. The four points you asked about

### (1) `--check` returns rc 5 only when the read-only mount fails AND this boot has a save-failed marker. Is rc 1 without the marker still fail-open in a case that matters?

- **Code** (`batman-config-save:413-425`): three mount tries (i = 0, 1, 2), the same count as before. Only then: if the marker exists and is owned by root, rc 5 `p5 stale: unverifiable (p5 does not mount read-only, and a save failed earlier this boot: <step>)`. Otherwise rc 1, as before. The test case `--check unmountable` (a corrupted `s_log_block_size`) passes on HEAD with rc 1 then rc 5. On 6d65ecd it returns `rc 1 / 1`, which is its negative control ✅.
- **rc 1 without the marker is still fail-open, and there is a field case where it matters.** Take a joined node whose config does not change. Its `--on-join` hits the fingerprint cache every tick and never mounts p5 (#263 M0), so a p5 that breaks after the last good save leaves neither `cfgsave-save.failed` nor `cfgsave-mount.failed`.
  - At OTA time, `--check` gets rc 1, and `batman-slot:581-588` writes `skip:error` ("not blocking") and lets the OTA through.
  - The new slot's 96 logs `p5 mount failed — image defaults` (`96-batman-config-migrate:146`).
  - The safety net is batman-autocommit: a node with `mesh-expected` / `mesh-joined` must join the mesh in its trial boot (`batman-autocommit:429,452`). With image defaults it cannot, so it rolls back.
  - ⚠️ All of this is from reading the source, not from a run. Whether the node runs with image defaults (lock state, keys) during that trial boot is an exposure I did not check.
- **This was not introduced here.** `batman-slot`'s rc-1 branch already had this fail-open rule before this change ("refuse only with evidence that saves are failing this boot"), and this change only adds one more piece of evidence. See F1 (MINOR, leftover item).

### (2) The fsync fail-closed path and the four harnesses' fsync shims: does any shim hide a product failure?

- **The script:** `command -v fsync || not_saved "fsync of the stage (no fsync tool on this system)"`. The `sync FILE` fallback is gone.
  - The `no fsync tool` case passes on HEAD. On 6d65ecd it FAILs with `rc 0 p5 CHANGED`, which is its negative control ✅.
  - The shipped rootfs for both SoCs has `/bin/fsync -> busybox` (checked in r2) ✅.
- **The shims:** all four are `printf '#!/bin/sh\nexec /bin/sync -- "$@"\n' > $W/bin/fsync`, i.e. coreutils `sync FILE`, which is fsync per file and reports errors.
  - **This is a real fsync, not a no-op, so it cannot hide an fsync failure.**
  - Mutant M shows that `identity-freeze`, `txn-save` and `ssid` really go through the script's fsync step: once it fails, their saves fail too.
  - `frozen-nomount` PASSes with or without the mutant, because its scenario (a frozen node does not remount) never reaches a save. Its shim is simply unused, which does no harm.
  - None of these four harnesses injects an I/O fault, so they cannot test whether fsync catches an error. That job is covered by the `datafail` ×6 cases in stage-enospc ✅.
- Residual risk: the shim relies on the host's `/bin/sync` being coreutils. That holds on Ubuntu (WSL and CI). If a host's `/bin/sync` were a busybox without SYNC_FANCY, the shim would become a no-op. Not filed as a finding: the stage-enospc `datafail` cases would then fail loudly, so the problem would not stay hidden.

### (3) The file-count check (identity files + 2 + lkg + `.seeded`): can a legitimate state fail it on every save?

- **Code** (`:688-690`): `nwant` = number of identity files (`ids`, from `find -type f`) + 2 (overrides, schema) + `LKG` + 1 if `$STAGE/.seeded` exists. `flist` = `find . -type f` over the whole stage, and `find`'s rc is checked.
- **Everything in the stage is counted:** `stage_overrides` writes only the identity files, `overrides.uci` and `schema_version`, and after that only `lkg.uci` (when `LKG=1`) and `.seeded` (when `$MNT/.seeded` is missing) are added. `.seeded` is counted with the same condition (whether `$STAGE/.seeded` exists) ✅.
  - Between `ids` and `flist` the only extra step is `mkd`, which creates directories on p5, not files ✅.
  - A symlinked identity source would be left out of both counts by `-type f`, so the two counts stay equal ✅. (Whether such a file is published at all is old behaviour, unchanged here.)
  - With no identity file at all, `printf '%s\n' "" | grep -c .` gives 0 → `nwant = 2 + LKG` (run Z: rc 0 for both modes) ✅.
  - Unseeded `--seed` (`.seeded`), `--on-join` (LKG) and `--save` (no LKG) all pass in H ✅.
- **Negative control:** the `stage-list count` case (hook 4 deletes `lkg.uci`) → rc 15 `listing the stage for fsync (7 files, want 8) … p5 is unchanged`. On 6d65ecd it FAILs (no hook-4 anchor) ✅.
- I could not find a legitimate state that fails this check.

### (4) The ci.yml step

- **Structure:** the stage-enospc test now has its own step, `if: ${{ !cancelled() }}`, and is no longer run inside the loop-device step. So a runner without dm-flakey fails only this step, and the loop-device tests before it still run ✅. Because of `!cancelled()`, it also runs when an earlier step failed; a cancelled job does not run it. The job's final result is still red ✅.
- **Fallback:** `modprobe dm_flakey || { apt-get install linux-modules-extra-$(uname -r) && modprobe dm_flakey; } || echo ::warning::`. After that, `CFGSAVE_REQUIRE_DM=1` makes the test FAIL when dm-flakey is missing (verified in r2: `die` under REQUIRE_DM). So it fails closed ✅.
- See F2: `apt-get install` without `apt-get update`.
- ❌ Not run on GitHub Actions. Whether the runner's kernel can load `dm_flakey` is unverified.

## 3. Findings

### F1: MINOR (old behaviour, leftover item): `--check` rc 1 on an unmountable p5 without the marker still lets the OTA through

- **Scenario and evidence:** §2 (1) (source reading). The new rc 5 only helps when there is evidence from this boot. The most likely field case (joined, cache hits, never mounts) has no such evidence.
- **Fix (not for this PR):** one line in the issue checklist.
  - Have `batman-slot` treat `p5 error mount` as a block when p6 has `mesh-expected` / `mesh-joined` (that is, p5 should exist and should be readable). Or have `--on-join` do a cheap read-only mount check once per boot on a cache hit, so it can write a marker.
  - Also check how locked the node is during an image-default trial boot.

### F2: MINOR (CI): `apt-get install` without `apt-get update`

- On a runner whose package index is stale, the install fails, and the step goes straight to `::warning::` and then a test FAIL. That is still fail-closed, but it produces red runs that have nothing to do with the product.
- **Fix:** `sudo apt-get update -qq && sudo apt-get install -y -qq …`.

### F3: MINOR (test documentation): the fsync shim in `cfgsave-frozen-nomount` is never used

- Mutant M shows the harness never reaches a save, so the shim has no effect.
- **Fix:** either leave it with a comment saying so, or remove it. No impact on the product.

## 4. Per-item confirmation (r2 findings → v3)

- **A-r2 F1 (MAJOR):**
  - The text after `PUB=1` is now `may be PARTLY updated (each file whole; an I/O error may have kept the last committed state)`.
  - The I/O-error cases accept "p5 unchanged + may be PARTLY"; the `ro` case stays strict.
  - New fixed cases at hook 3 (`ro` ×2, `eiow` ×2) check that every published file is a whole OLD or NEW copy. On 6d65ecd the two `ro` cases FAIL ✅.
  - H ×3 did not fail intermittently ✅.
- **F2:** CR is no longer UNSAFE; the CR case expects rc 0 with the bytes kept as they were. The node's `uci` / `valid_batch` evidence is in design §6 ✅.
- **F3:** fail-closed ✅ (§2 (2)).
- **F4:** the `chattr +i` control ✅ (§1.1).
- **F5:** `find` rc + count ✅ (§2 (3)).
- **F6:** `batman-slot` has its own refusal text and does not show `P5_STALE_HINT`. `allow-stale-p5` can still override. S `21/0` vs old `21/2` ✅. Its `sed` pulls the reason out of the last `(…)` in the message ✅.
- **F7:** all dm switches are load → suspend → resume, with `resume` on failure ✅ (no hangs in H ×3).
- **The /dev/null incident:** design §8 now attributes it to me, with the flip evidence ✅.
- **Not changed and still holding:** the callers' handling of rc 15 / rc 5, the backoff marker (root 0700 tmpfs, `-O`, `/proc/uptime`), and the cleanup of leftover `.stage.*` / `.wprobe.*` (lock held, private mount, `rm` uses `lstat`). All checked in r2 against code that v3 did not change.

## 5. Wrap-up

- ✅ `losetup -a` and `dmsetup ls` are both empty (`No devices found`). `/dev/null` is `character special file 1:3`.
- ❌ Not done:
  - no run on a node;
  - no run of the node's busybox under qemu this round (it gave 83/0 in r2; the r3 product delta is small);
  - no GitHub CI;
  - no sbx cases;
  - F1's chain (OTA → image defaults → autocommit rollback) was only read in the source, not run.
