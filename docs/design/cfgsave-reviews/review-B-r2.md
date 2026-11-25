# Review B, round 2 — cfgsave-stage-enospc (4eba26d..b869e61, design v2)

Reviewer: independent adversarial review (B), round 2. I reviewed the whole change, not only the 6d65ecd..b869e61 delta:
- the script (`feed/` and `deploy/` copies identical, checked with `git show` + `diff`);
- design v2 including §10;
- the test;
- the CI and stubs wiring.

I only read the product code and did not change it. All runs were on a fresh clone `<home>/rev-cfgB2` (HEAD b869e61) in
WSL Ubuntu-24.04 (kernel 6.6.114.1, busybox 1.36.1, dm `flakey` present). No node was touched.

**Verdict: APPROVE.** No BLOCKER and no MAJOR is open. Round 1's MAJOR-1 and MAJOR-2 are fixed, and each fix has a
negative control. The four MINORs below can go to the issue checklist. One thing should be in the PR before merge: a CI
log showing that the dm and dm-flakey cases actually ran on the GitHub runner (MINOR-1).

---

## Evidence

| # | What | Result |
|---|---|---|
| R1 | Test at HEAD, `CFGSAVE_REQUIRE_DM=1`, product HEAD | ✅ `rc=0 PASS=83 FAIL=0` |
| R2 | Same test, product 6d65ecd (round-1 negative control) | ✅ `rc=1 PASS=65 FAIL=18`. It FAILs every new case: data-only ×5, run dir full, backoff, leftover ×2, newline/CR ×3, white-box `batch_ok`, plus last-stderr-line cases |
| R3 | Same test, product 4eba26d (pre-fix negative control) | ✅ `rc=1 PASS=12 FAIL=71` (same as the coordinator) |
| R4 | `deploy/` vs `feed/` at HEAD | ✅ identical |
| R5 | Power cut: dm table switched to `error` (all later I/O lost), then `kill -9` of the script. Cut at hook 2 (after the stage fsync, before the first rename) and at an extra hook 3 I inserted before `# sentinel LAST` (after all renames, before `sync`); modes `--on-join` and `--save`. Then remount (journal replay), a "reboot" (run dir wiped, dead writer's lock included), and `--save` | ✅ 4/4: p5 unchanged, no 0-byte file, every p5 file is the OLD copy, reader picks `overrides.uci@1`. The stage dir stays after the cut. The next `--save` returns rc 0, removes it, and p5 = NEW. dmesg: 4× `recovery complete` |
| R6 | Node busybox source (`<home>/firmware-2710/…/busybox-1.36.1`) | ✅ Both a53 and a72 builds: `CONFIG_FSYNC=y`, `# CONFIG_FEATURE_SYNC_FANCY is not set`. `coreutils/sync.c`: `fsync(fd) != 0 → ret = EXIT_FAILURE` |
| R7 | bash passes prefix assignments to a function's children (`CFGSAVE_REQUIRE_DM=1 … stub …` in `test-prov-p1-stubs.sh`) | ✅ `X=1 f` → child sees `X=1` |

Notes on the evidence:
- R2 varies from run to run: 65/18 here, 66/17 for the fixer, 67/16 for the coordinator. The difference is the
  last-stderr-line cases (`ro`, `eiow`, `eio`), where a timing-dependent `rm:` line from the round-1 product decides the
  result. HEAD passed every run I know of (mine, the coordinator's 2, the fixer's 5). See MINOR-4.
- A concurrent run by reviewer A (`rev-cfgA2`) was using loop and dm devices at the same time as mine. I left its devices
  alone. My own devices are all gone.
- `/dev/null` is still `crw-rw-rw- 1,3`. **Own mistake:** my power-cut script had a stray `cp <file> /dev/null` line
  (busybox `cp` through the harness PATH). I checked afterwards: the device is intact. It ran at 00:42 today, so it cannot
  explain the replacement found last night at 23:40.

---

## Round-1 findings re-checked

### MAJOR-1 (on-join retries every tick, stage dirs pile up) → fixed ✅

- **Marker ownership.** `$RUNDIR/cfgsave-save.failed` has one owner and one writer: `not_saved` writes it, only when
  `RDOK=1` and under umask 077. It is cleared by every successful exit: the `unchanged` path (`:634`) and the saved path
  after umount (`:692`). Rc 6 also reaches the saved path. Only `--on-join` reads it, and only if it is owned by root (`-O`).
- **Failure paths that keep it.** The lock-busy, txn, rate-limit and mount-fail exits leave it alone. They are not
  successes, so that is correct.
- **Cached verdict while the marker is set.** This cannot happen: `not_saved` also removes `$ST`.
- **Stale across reboot / clock jump.** The time base is `/proc/uptime`, which is monotonic and unaffected by an RTC-less
  wall-clock jump. The file is in the run dir, which is tmpfs and empty after a reboot. A marker from an earlier boot
  therefore cannot exist, so it cannot hold the backoff into the next boot.
- **Can a failing join still hammer p5?**
  - joinwatch only calls `--on-join` while JOINED. The backoff check comes before any mount, and the test proves it
    with the ext4 mount count (3→3 while backing off, then a retry after 301 s).
  - A join that flaps does not get around it: the check runs on every call.
  - Other write callers are bounded by themselves: the operator, halow-setkey, the helper's `bootRetry`, `upgradeSave` once.
  - An operator `--save` is never held back, and it clears the marker when it succeeds (test).
- **Stage dirs.** They are removed under the lock right after the verified rw mount (`:396-398`). R5 confirms that a stage
  left by a power cut is cleaned up by the next save. Negative controls: the two leftover cases FAIL on 6d65ecd.
- **Residual (not a finding).** If the run dir is full, the marker write fails silently and on-join goes back to trying
  every tick. That is the only effect.

### MAJOR-2 (dm cases could be skipped and still pass) → fixed in the harness ✅; the runner is unverified ⚠️ (MINOR-1)

`CFGSAVE_REQUIRE_DM=1` is set in both `ci.yml:140` and `test-prov-p1-stubs.sh`. A host without dm or dm-flakey now exits
`FAIL setup … PASS=0 FAIL=1` with rc 1 (the design §8 shim run; the `die` path is plain).

### Round-1 MINORs

- **MINOR-1 (newline / CR):** fixed. UNSAFE now includes `\n` and `\r`, `batch_ok` has its own rc and message, and the
  nlcase ×3 and white-box cases FAIL on 6d65ecd.
- **MINOR-2 (cache-drop test):** fixed. There is now a case for it, and the mutant result is in the design.
- **MINOR-3 (`batman-slot` evidence):** deferred to §9. Still open; see MINOR-2 below.
- **MINOR-4 (message guessed "p5 full"):** fixed. The message names the step and gives free KiB as data.
- **MINOR-5 (overclaims):** fixed. The wording now says "compare (page cache)", and the `ci.yml` comment is accurate.

## Lifecycle paths asked for

- **OTA gate via `--check`.**
  - After a failed save, `--check` returns 5 (stale) in every case; the test runs it after each case.
  - When `--check` cannot build its comparison, it now returns 5 `unverifiable` instead of 1.
    - `batman-slot:577` blocks on that.
    - Helper `parseCheck` (`status.go:52-58`) reads it as "stale".
    - `onlyP3Stale` (`status.go:67-80`) does not auto-save, because the prose item is not a P3 key.
  - What is still open: a `--check` whose ro mount fails, which falls into `batman-slot:581-587` (MINOR-2).
- **Downgrade to a version without the marker.** The marker lives in tmpfs and the old version ignores it. The on-p5
  format is unchanged. The new temporary names exist only during one run, or are cleaned by the next new-version save.
  After a downgrade the old behaviour comes back (per-tick retry, no stage cleanup), and nothing on p5 trips it.
- **Power cut between fsync and rename.** R5 hook 2: p5 is OLD, the stage stays, and the next save cleans it and succeeds.
  - Cut after the renames, before `sync` (R5 hook 3): in this emulation the renames were not yet committed, so p5 came
    back fully OLD.
  - If they had been committed, each file is whole because its data was already fsynced. I did not produce that state.
    It follows from rename atomicity plus the fsync, and is not tested.
- **fsync error reporting.**
  - busybox `fsync` opens the file again; R6 shows it returns failure on an fsync error.
  - Writeback errors not seen before are reported to a new opener on kernel 4.16 and later (errseq "report once"). This
    is from kernel history, not something I ran.
  - The datafail cases cover the normal ordering, where the data is still dirty when `fsync` runs.

## Security (each actor, whole change)

- **Local unprivileged process.**
  - The new marker sits in the root-only 0700 run dir and is checked with `-O`. Only a numeric uptime is parsed from it.
  - The stage and probe names live inside the private mount.
  - The cleanup glob runs only under the lock, and `rm -rf` does not follow symlinks.
  - Nothing new is reachable.
- **Compromised peer or helper.** It only has the CLI, as before. The worst it can do is trigger a failing save and
  delay `--on-join` by 300 s. A successful `--save` lifts that, and an attacker who can already run `--save` as root
  gains nothing from it.
- **Physical capture or hostile p5 content.** New input: names matching `.stage.*` / `.wprobe.*` are deleted. Planting
  them only gets them deleted. The rest of how p5 content is trusted is unchanged by this diff and was not reviewed again.
- **Our own mistakes.**
  - The `sync FILE` fallback is fail-open on a busybox without the `fsync` applet and without SYNC_FANCY. The design
    states this; see MINOR-3.
  - Stage dirs that outlive a key rotation are now cleaned up.
- **Secrets in logs.** Only step names, stage-relative file names and KiB values are logged.

---

## Findings (round 2)

### MINOR-1 — It is unknown whether the GitHub runner has dm-flakey; if not, the whole loop-device step stops at this line

- **Scenario.** The branch is local, so there is no CI run. Nothing else in `.github/` uses `dmsetup` (grep), so there is
  no earlier proof that the runner's kernel provides `dm_flakey`.
- **What happens if it does not.** The test prints `FAIL setup: CFGSAVE_REQUIRE_DM=1: no dm-flakey target` and exits 1.
  The step runs under GitHub's default `bash -e`, so the step stops there. The three `prov-base-*` tests after it in the
  same step (`ci.yml:141-143`) then do not run until this is fixed.
- **Assessment.** This is loud, fail-closed and not silent, so it is acceptable. But it hides unrelated results.
- **Fix.**
  1. Push and attach the CI log line showing the EIO cases ran (part of the PR's test results anyway).
  2. Either give this test its own step, or use the `|| rc=1` pattern the file already uses (`ci.yml:230`), so the later
     tests still report.
  3. If the runner lacks the module, try `sudo modprobe dm_flakey`, or install `linux-modules-extra-$(uname -r)` in the step.

### MINOR-2 — `--check` failing to mount on a dying card still lets an OTA through (round-1 MINOR-3, still deferred)

- **Scenario.** A save fails with rc 15, then the card also fails reads.
  - `--check` returns rc 1 `p5 error mount`.
  - `batman-slot:581` blocks only on `cfgsave-mount.failed` / `cfgsave-lock.busy`.
  - Result: `skip:error … not blocking`.
- **Why fix it now.** The evidence file exists now (`cfgsave-save.failed`). Adding it to the condition at `:581` is one
  line plus one test, cheaper than a checklist item that has to be picked up again.
- **Fix.** Add the marker to that condition, with a case `--check` rc 1 + marker → `die_c 18`.

### MINOR-3 — CI and WSL never run the `fsync` applet; the product's `sync FILE` fallback is untested and fail-open

- **Evidence.** My HEAD run prints `note: busybox has no fsync applet: shim = coreutils sync FILE (fsync)`. The harness
  always provides a `fsync` in PATH, so the product's `else fsync_cmd=sync` branch is never exercised.
  - The node path (the busybox applet) is tested only by the design §8 qemu run, which I did not repeat ⚠️. R6 confirms
    the applet's source and config.
- **Fix.**
  - Keep the qemu run in the PR's evidence.
  - Make a missing `fsync` fail closed instead of falling back (`not_saved "no fsync"`); the offline harness already
    ships a shim, so nothing legitimate depends on the fallback.

### MINOR-4 — The negative-control count against 6d65ecd is not stable; record it as a range

R2 gave 65/18, against 66/17 (fixer) and 67/16 (coordinator). The cases that move are the last-stderr-line ones, which
depend on when the round-1 product's `rm:` line lands. This does not affect HEAD, which was stable in 8 known runs.
§8 should say "16–18 FAIL, always including <the deterministic list>" rather than give one exact number.

---

## Not done

- ❌ Not run on a node, and not run under qemu with the node busybox (I relied on the design §8 for that, plus R6 for the source).
- ❌ No CI run exists (branch not pushed).
- ⚠️ R5 is my own emulation of a power cut: dm `error` plus SIGKILL, with page cache dropped by device errors. It is not a
  real power loss of an SD card.
