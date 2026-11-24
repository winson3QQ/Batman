# Review B — cfgsave-stage-enospc (fix/cfgsave-stage-enospc @ 6d65ecd, base 4eba26d)

Reviewer: independent adversarial review (B). Scope: the whole design `docs/design/cfgsave-stage-enospc.md` v1, the script
diff (`feed/…/batman-config-save`, `deploy/` byte-identical — `cmp` clean), `tests/prov-p1/cfgsave-stage-enospc.sh`, and
the wiring (`.github/workflows/ci.yml`, `scripts/test-prov-p1-stubs.sh`). I only read the code. I ran tests on a fresh clone
(`<home>/rev-cfgB`, HEAD 6d65ecd) in WSL Ubuntu-24.04 (kernel 6.6.114.1, busybox 1.36.1, dm `flakey`/`error`/`linear`
available). No node was touched.

**Verdict: APPROVE-WITH-CHANGES** (2 MAJOR, 5 MINOR, no BLOCKER).

The core fix is right and I verified it: the stage is checked step by step, the publish only renames, and a failed save
leaves p5 byte-identical to what it was. My concerns are about what happens around it in the field: (1) a node whose
p5 stays full or failing now retries every 15 s and can leave stage dirs behind; (2) the only negative control for the
post-sync probe is silently optional.

---

## Evidence I produced

| # | What | Result |
|---|---|---|
| E1 | New test vs the fixed script (6d65ecd) | ✅ `rc=0`, `PASS=61 FAIL=0`, no `note:` lines (dm and flakey both present) |
| E2 | New test vs the pre-fix script (`git show 4eba26d:…/batman-config-save`) — negative control | ✅ `rc=1`, `PASS=10 FAIL=51`; for example `--on-join K=1: saved rc=0 :: 0-byte:[./overrides.uci ./schema_version ./lkg/overrides.uci ]`, `--if-healthy EIO (all I/O) before publish: saved rc=0 …` |
| E3 | Mutant: post-sync probe line removed | `PASS=58 FAIL=3`. Only the three `EIO (writes only …)` cases (dm-flakey) catch it |
| E4 | Mutant: `rmdir $MADE` removed from `not_saved` | `PASS=60 FAIL=1` (`--seed (unseeded p5) K=12: … p5-changed:[> ./identity|]`) |
| E5 | Mutant: `batch_ok` call removed from `stage_overrides` | `PASS=61 FAIL=0`. **Not covered** (the lint only checks that the function text matches 96's) |
| E6 | Mutant: `rm -f "$ST"` removed from `not_saved` | `PASS=61 FAIL=0`. **Not covered** |
| E7 | Extra experiment: write errors on every sector **except the journal** (dm table: flakey `error_writes` / linear journal / flakey `error_writes`), no pre-sync, for `--on-join` and `--save` | ✅ both `not-saved rc=15`, p5 unchanged apart from a stage dir. dmesg: `Aborting journal on device dm-1-8`, then `.wprobe: Read-only file system`. The design's assumption "a writeback EIO aborts the journal, so the probe sees it" held even when the journal itself could still be written. **A stage dir stayed behind after the journal replay** (it is filtered out of the comparison, and nothing on the node removes it). |
| E8 | Extra experiment: a live uci value that contains a newline (ssid `ap\nNEW`), no fault on p5 | fix: `--save rc=15` and `--on-join rc=15`, both saying `p5 NOT saved: staging failed (p5 full, read-only or failing? 9992 KiB free)`; `--check rc=1 p5 error staging`. Pre-fix: `--save rc=0 saved`, `--check rc=0 p5 fresh` (and the batch it published is one that 96's `valid_batch` rejects) |
| E9 | Callers, read file:line | see the contract table below |

Cleanup: every loop and dm device my runs created is gone. The `cfgenospc578679` device and `/dev/loop1` present when I
finished belong to a concurrent run of `<home>/rev-exp.sh` on `rev-cfgA` (reviewer A), and I left them alone.

## Ownership / contracts (checked)

- **p5 writers:** write modes (`--seed/--save/--if-healthy/--on-join`) and `--prov-only`, all holding `cfgsave.lock`
  (`batman-config-save:240-275`). Read-only users: 96, `--check`, `--prov-get`, batman-slot, chanfix, prov-lock, autocommit.
  The diff adds no writer. The new names (`.stage.<pid>/lkg.uci`, `.stage.<pid>/.seeded`, `.wprobe.<pid>`) live inside
  the private mount point (`tmpd` in the 0700 run dir), and the script holds the lock while it creates them. ✅
- **The rc 15 / "saved" contract, caller by caller:**

| Caller | How it treats rc 15 | Assessment |
|---|---|---|
| `deploy/provisioning/halow-setkey:184-189` | `*)` → `persist: FAILED (<last line>)`, RC=3 | ✅ The last line is the `p5 NOT saved` line |
| `halow-setkey:228,231,257,309,323` (P3) | failure → rollback path | ✅ For a newline ssid this is actually better than before (rolled back instead of persisted unreadable) |
| `feed/batman-prov/src/node/node.go:846` `persisted()` | 0/6 only | ✅ After a partial publish it says "not persisted" when part of the data is on p5. That is the conservative direction, so the app can retry |
| `node.go:477-478` `cfgSaveBusy` | rc 1 + text only | ✅ No retry |
| `node.go:1303,1353`, `wtxn.go:369-376` | `.txn` kept; `causeSave` is retryable, with bounded `bootRetry` (`wtxn.go:483-488`, retries capped by `bootRetryWaits`) | ✅ Bounded, not a tight loop. But a p5 that stays full keeps `.txn` until someone frees space (see MAJOR-1) |
| `cmd/batman-provhelper/status.go:142` | log only | ✅ |
| `deploy/provisioning/joinwatch:164` | output discarded, no rc check, every `POLL` (default 15 s, `joinwatch:36`) | ⚠️ MAJOR-1 |
| `feed/…/usr/sbin/batman-slot:559-587` (`--check`) | rc 5 blocks. rc 1 → `*)` blocks only with `cfgsave-mount.failed` / `cfgsave-lock.busy`, otherwise `skip:error … not blocking` | ⚠️ MINOR-1, MINOR-3 |

## Lifecycle paths (my check)

- First seed on an unseeded p5: ✅ (test `--seed K=0,2,5,9,12` + control). `MADE` rmdir has a negative control (E4).
- Each write mode, `--promote-lkg`: ✅ (E1, E2).
- `--check` / OTA precheck: ✅ rc 5 after a p5-side failure (test). ⚠️ Not covered: `--check` while the device itself fails
  reads (MINOR-3) and a staging failure that is not about p5 (MINOR-1).
- Crash or power loss mid-stage: p5 is unchanged because renames come later ✅, but the leftover `.stage.<pid>` is never
  removed. That is now the **only** thing that grows on p5, and on an EIO or ro device each failed run can leave one (E7) → MAJOR-1.
- Power loss mid-publish: every file stays whole (rename). Old identity mixed with new overrides is possible, as before. ✅
- Upgrade, rollback, downgrade: the on-p5 format is unchanged, and the new names exist only while one run lasts (`.wprobe`
  can stay as a 0-byte file only if its own `rm` fails, which is harmless). ✅
- Dependency restart (joinwatch, helper): no new state. ✅
- Full / ro / EIO p5: ✅ for one run. ⚠️ For the steady state of a card that stays broken, see MAJOR-1.

## Security (by actor)

- Local unprivileged process: it cannot reach the private mount (run dir 0700) or the stage names. The new names add no
  input. ✅
- Compromised peer or helper: it can only call the CLI as before. rc 15 gives it nothing new. ✅
- Physical capture or a hostile p5: this diff adds no new input on p5. The way existing p5 content is trusted has not
  changed, and I did not review it again here.
- Our own mistakes: stage dirs that stay behind hold copies of the host keys and the shadow hash, which can outlive a key
  or password rotation (MAJOR-1 fix covers this).
- Secrets in logs: the `not_saved` line has the step name and the free KiB only. ✅

---

## Findings

### MAJOR-1 — A p5 that stays full or failing: `--on-join` retries every 15 s with no backoff, and stage dirs pile up

- **Scenario.** In the field, an SD card starts failing (or p5 is full). joinwatch calls `--on-join` on every JOINED tick
  (`joinwatch:164`, `POLL` 15 s). Before the fix, K=1..10 gave a wrong rc 0 that was cached once, so the node went quiet.
  Now every tick does this:
  1. a fresh rw mount (writes the superblock);
  2. a stage write attempt;
  3. a `daemon.err` syslog line;
  4. rc 15.

  That is about 240 mounts and log lines an hour on the card that is failing, and it pushes other logs out of the ring
  buffer. The write-amplification guard counts only successful writes (`:656-657`), and the `MNTFAIL` backoff (`:339-342`)
  covers only mount failures. On an EIO or ro device the stage cannot be removed. E7 shows a `.stage.<pid>` surviving the
  journal replay, and the test itself reports `stage left on a ro device`. Nothing ever removes these dirs (design §9
  admits it), so on a flaky card they build up tick after tick (each one is about 11 blocks and holds key and hash copies)
  until p5 really is full. That turns a short glitch into a permanent rc 15, `.txn` that never finishes, and an OTA gate
  that stays stale.
- **Evidence.** E7; test output `(stage left on a ro device: .stage.N)`; `joinwatch:36,164`; `batman-config-save:339-342,614-621,656-657`.
  The test's own `next-tick-skipped` assertion shows the next tick does the full work again.
- **Fix (small).**
  1. `not_saved` writes `$RUNDIR/cfgsave-save.failed` (`<uptime> <step>`, umask 077). `--on-join` backs off 300 s on it,
     the same way as `MNTFAIL`, and only logs when it starts backing off. Any success, or any other write mode, clears it.
  2. Right after the rw mount, while holding the lock, remove `$MNT/.stage.*` and `$MNT/.wprobe.*` (the lock proves their
     owners are dead; `rm -rf` does not follow symlinks).
  3. Add both to the test. Two `--on-join` calls on a full p5: the second backs off. A planted `.stage.99999/` is gone
     after a save and frees the room that a K=0 case then needs (negative control: today that case stays rc 15).

### MAJOR-2 — The probe's only negative control can be skipped with a `note:`, and the result still counts as a pass

- **Scenario.** In CI, or on a daily-validation host without `dm_flakey` (or device-mapper), the test prints `note: … NOT run`
  and still ends `PASS=… FAIL=0`. The stubs pattern `PASS=[1-9][0-9]* FAIL=0$` accepts that. E3 shows the post-sync probe,
  which is the part of the fix aimed at the failing-SD-card case, is caught **only** by the three `eiow` cases. So a CI
  runner without flakey would let the probe be deleted while CI stays green. I could not check whether the GitHub runner
  loads `dm_flakey` (the branch is not pushed). ⚠️ unverified.
- **Fix.** Add `CFGSAVE_REQUIRE_DM=1` to the CI step and to `test-prov-p1-stubs.sh`, so that a missing dm or flakey target
  is a FAIL there. Keep the `note:` only for ad-hoc runs. Paste the CI log line showing the `eiow` cases ran into the PR.

### MINOR-1 — A batch that 96 would reject (for example a value with a newline) is reported as "p5 full", permanently, and `--check` turns it into "not blocking"

- **Scenario.** A live value contains a newline (`UNSAFE` does not include `\n` or `\r`). `batch_ok` now refuses it, which
  is good: the old code printed `saved` and `p5 fresh` while publishing a batch that 96 rejects, falling back to an lkg
  that the same run had also overwritten (E8). But the user sees
  `p5 NOT saved: staging failed (p5 full, read-only or failing? 9992 KiB free)`. Every save fails forever (on-join every
  tick, see MAJOR-1), and `--check` returns rc 1 `p5 error staging`. In batman-slot (`:581-587`) that gives
  `skip:error … not blocking`, so an OTA goes ahead on a p5 that silently lacks every change since the value was set.
- **Fix.** Treat `\n` and `\r` as `UNSAFE`, so the value lands in `REJECTED`: rc 6 in write modes, and `--check` says
  "stale … unpersistable", which batman-slot already blocks with a clear message. The ssid stays in `SKIP_UNSAFE`. Give a
  `batch_ok` failure its own `not_saved` wording ("the batch would be rejected at boot", not "p5 full"). Add the E8 case to
  the test. That also gives `batch_ok` the negative control it lacks today (E5).

### MINOR-2 — The design says the cache drop is tested; it is not (E6)

Design §3 says that because `not_saved` removes `$ST`, failed ticks are never `unchanged (cached)` ("測試斷言", i.e. "the test
asserts this"). The test never writes a cache before the failing run (fresh run dir), so removing `rm -f "$ST"` still
passes 61/61. In practice the line is defensive: a cache hit skips the write before staging. **Fix:** either add a case
(save once with room → cache written → change live → fill → `--on-join` rc 15 → the next tick is not "cached"), or say in
§3 that it is defensive and not tested.

### MINOR-3 — An OTA gate on a failing card has no evidence that saves are failing

batman-slot's `*)` branch refuses only "with evidence that saves are failing this boot" (`MNTFAIL` / `BUSY`). An rc 15
leaves no evidence. If the card then also fails the `ro,noload` mount or reads, `--check` gives rc 1 and the OTA is
"not blocking". **Fix:** have the `cfgsave-save.failed` marker from MAJOR-1 count as such evidence in
`batman-slot:581` (a cross-component change; at least a checklist line on the issue).

### MINOR-4 — The rc 15 text blames p5 even when the cause is elsewhere

A `cmp` mismatch also happens when the source changes between `cp` and `cmp`, for example the helper's atomic
`authorized_keys` rewrite racing an on-join tick, or a non-atomic rewrite of `config.yml`. That case is short-lived and
fail-closed, which is correct, but the text says "p5 full, read-only or failing?". **Fix:** name the step and print the
free KiB as plain data, without a guessed cause; or re-read the source once on a mismatch before failing.

### MINOR-5 — Two claims say more than the evidence supports

- `ci.yml:139` comment "never 'saved' unless p5 == live": the probe catches writeback errors that abort the journal (E7
  confirms that even when the journal itself is writable). It cannot see an error at `umount` or after it (design §9
  says so). Suggest: "never 'saved' after a failed write or an aborted journal".
- Design §4.1 / script comments "讀回比對" (read back and compare) and "does not read back": `cmp` right after the write
  reads the page cache, not the card. It proves that `write()` succeeded, not what is on the medium. Reword.

---

## What I did not do

- ❌ Run anything on a node or OpenWrt busybox (design §6 already marks that ⚠️).
- ❌ Look at a CI run for this branch (not pushed), so MAJOR-2 is unverified on the runner.
- ⚠️ E7 and E8 are my own extra experiments built on the test harness (scratch copies, not committed). E8 uses a stub
  `uci` that returns a two-line value, which I inferred to be possible with real uci and did not check on a node.
