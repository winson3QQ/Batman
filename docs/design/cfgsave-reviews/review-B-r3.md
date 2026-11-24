# Review B, round 3 — cfgsave-stage-enospc (4eba26d..ec8b79a, design v3)

Reviewer: independent adversarial review (B), round 3. I reviewed the whole change again:
- the script (`feed/` and `deploy/` copies identical);
- `batman-slot`;
- design v3, including §8-§10;
- all touched tests;
- the CI step.

I did not change the product code; I only read it. All runs were on a fresh clone `<home>/rev-cfgB3` (HEAD ec8b79a) in
WSL Ubuntu-24.04 as root (kernel 6.6.114.1, busybox 1.36.1, dm `flakey` present). No node was touched. No tool was pointed
at `/dev/null` (it was `character special file 1,3` before and after).

**Verdict: APPROVE-WITH-CHANGES.**
- No BLOCKER and no MAJOR.
- MINOR-1 should be fixed in this PR, or at least the design's claim corrected. The round-2 MINOR-2 fix (`--check` rc 5
  on a failing card) does not trigger in the most common way a card fails: its reads fail. In that case `--check` stops
  earlier, at the superblock magic, and returns rc 3 `SKIP not-ext4`. The OTA gate lets rc 3 through.
- Everything else is verified.

---

## Evidence

| # | What | Result |
|---|---|---|
| R1 | `cfgsave-stage-enospc.sh` at HEAD, `CFGSAVE_REQUIRE_DM=1` | ✅ `rc=0 PASS=91 FAIL=0` |
| R2 | Same test, product 6d65ecd | ✅ negative control `rc=1 PASS=68 FAIL=23` (the coordinator saw 70/21; see MINOR-3) |
| R3 | Same test, product 4eba26d | ✅ `rc=1 PASS=13 FAIL=78` (same as the coordinator) |
| R4 | Other config-save loop tests at HEAD (now with an `fsync` shim) | ✅ identity-freeze `PASS=8 FAIL=0`, frozen-nomount `PASS`, provget-rc10 `PASS`, txn-save `PASS=59 FAIL=0`, prov-p3 cfgsave-ssid `PASS=7 FAIL=0` |
| R5 | `slot-p5gate-txn.sh` with the HEAD and the 6d65ecd `batman-slot` | ✅ HEAD `cases=21 fails=0`; 6d65ecd `cases=21 fails=2` |
| R6 | `deploy/` vs `feed/` at HEAD | ✅ identical |
| R7 | dv-sbx (CI only) runs `--save/--on-join/--seed` on the pinned base rootfs. Now that a missing `fsync` fails the save, that rootfs must have `fsync`. I checked the local copies of both pinned payloads (sha equal to `tests/prov-p1/sbx/base.env`: `73300d1b…`, `21088a8f…`) | ✅ both have `bin/fsync -> busybox`. Together with round 2 (`CONFIG_FSYNC=y` in both SoC builds) and the existing daily check `prov-tools-254` ("…fsync… behave on" the nodes, `scripts/daily-validation.sh:268`), fail-closed-without-fsync cannot hit a shipped node or the sandbox |
| R8 | **New experiment:** `--check` on a p5 whose **reads** fail (dm `error`, caches dropped), with and without `cfgsave-save.failed` | ❗ both give `rc=3 :: p5 SKIP not-ext4` → MINOR-1 |

Cleanup: my loop and dm devices are gone. The device `cfgenospc3169144` I saw belongs to reviewer A's concurrent run
(`<home>/rev-cfgA3/…`), and I left it alone.

---

## The coordinator's questions

### Round-2 MINOR-2 disposition: rc 5 only when the ro mount fails AND the marker exists, else rc 1

**The rule itself is acceptable as a policy.** #202 says "no evidence, no block". For a card that reaches the mount step,
here is what happens to a dying card after a reboot that has had no failed save:
- **The node joins.** `--on-join` runs within one 15 s tick. Its rw mount fails 5× and writes `cfgsave-mount.failed`
  (`batman-config-save:390`). `batman-slot:581-587` then refuses with `die_c 18`. The evidence turns up by itself within
  about a minute.
- **The node never joins this boot** and no app action saves. `--check` gives rc 1 and the OTA is "not blocking". The
  trial slot's 96 then logs `p5 mount failed — image defaults` (`96-batman-config-migrate:145-147`).
  - The A/B trial (autocommit requires a mesh join when `mesh-expected` is on p6) is the safety net. But p6 lives on the
    same failing card.
  - That is a real, narrow gap, and it is the owner's call. My suggestion is in MINOR-4.

**But the disposition does not cover the main way a card dies (MINOR-1).**

### Lifecycle paths

- **OTA gate, stage 1:** rc 5 `unverifiable` gets its own refusal text, and allow-stale-p5 overrides it (R5).
  **Stage 2 (ramfs):** it uses the stage-1 verdict `stale:unverifiable`, and `p5_verdict_gate` refuses it unless
  overridden (R5, the `verdict=stale:unverifiable` line). ✅
  - Gap: a card whose reads fail returns rc 3 before any of this applies (MINOR-1).
- **Downgrade:** the marker lives in the tmpfs run dir and older versions ignore it. The on-p5 format is unchanged.
  - Old versions never call `fsync`, so a downgrade only brings the old silent behaviour back.
  - Older harnesses do not have the shim, which is harmless: they do not run the new product.
  - ✅
- **Power cut between fsync and rename:** round-2 R5 (my emulation) still applies, because the path did not change
  except for the added list count. p5 stays OLD; the stage is left behind and removed by the next save. ✅
  - The new count check (`:688-690`) runs before the first rename, so if it fails, p5 is unchanged. The test (hook 4)
    confirms this.
- **New hook-3 partial state (identity NEW + overrides OLD): safe for the reader.**
  - 96 restores each identity file on its own, before and independently of the overrides
    (`96-batman-config-migrate:175-195`: each dropbear file only if `-s`, `config.yml` only if `-s`, `shadow-root` only
    if it is a valid hash).
  - It then applies the OLD overrides through `valid_batch`, which still accepts them. Every file is whole: the test
    asserts each file is the OLD or the NEW copy and that there is no 0-byte file.
  - Result at next boot: the new host keys / root hash / `authorized_keys` together with the old radio config. That is a
    working node, the same state a power cut mid-publish produced before this change.
  - `--check` then says stale (rc 5), so an OTA stays blocked until a save succeeds.
  - The helper's SSH-key record invariant (every app-added key in a durable file stays listed in the record) holds:
    - adding a key commits the record before the file is written;
    - removing a key leaves the record listing it, because rc 15 means "not persisted", and listed-but-absent is allowed.
  - ✅
- **ci.yml:** the separate step with `if: ${{ !cancelled() }}` fixes the round-2 masking. The three `prov-base-*` tests
  are back in the earlier step and run whatever happens to this one. ✅ Small issue in MINOR-2.

### Round-2 findings

- **MINOR-1 (CI):** fixed in structure; the runner is still unverified ⚠️ (MINOR-2 below).
- **MINOR-2:** fixed as designed, but only for a card that still reads (MINOR-1).
- **MINOR-3:** fixed. Without `fsync` the save fails closed. The no-fsync case and its mutant are in the design (90/1).
  R7 shows no shipped or sandbox rootfs lacks `fsync`.
- **MINOR-4:** fixed in the text, but R2 is outside the stated range (MINOR-3).

### Security (each actor)

- **Local unprivileged process:** nothing new. `--check` reads the marker only with `-O`, from the 0700 run dir, and only
  echoes its text. Ownership is unchanged: `not_saved` writes the marker, a successful save clears it, `--on-join` and
  `--check` read it.
- **Compromised peer:** can still only call the CLI.
- **Our own mistakes:**
  - The CR change (kept as a byte) matches what the reader accepts (round-3 CR case).
  - Failing closed without `fsync` is safe because R7 shows every shipped and sandbox rootfs has it.

---

## Findings (round 3)

### MINOR-1 — A card whose reads fail gets `--check` rc 3 "SKIP not-ext4", so the MINOR-2 fix (and MNTFAIL) never apply, and the OTA goes ahead

- **Scenario.** In the field, the SD card starts returning EIO on reads. A save already failed (marker present), or the
  rw mount failed (`cfgsave-mount.failed` present). Then:
  1. `--check` reads the superblock magic with `hexdump` (`:171`); the read fails and `magic` is empty.
  2. The `magic != 53ef` branch (`:297-307`) prints `p5 SKIP not-ext4` and exits 3, before the new mount-fail rc 5
     branch is ever reached.
  3. `batman-slot` handles rc 3 as `skip:not-ext4` and lets the OTA through. Its `*)` branch, which checks MNTFAIL, is
     never consulted either.
  4. The trial slot's 96 cannot read p5 and boots image defaults.
- **Evidence.** R8, a dm `error` table with caches dropped:
  - `marker=0: --check rc=3 :: batman-config-save: p5 SKIP not-ext4`;
  - `marker=1: --check rc=3 :: batman-config-save: p5 SKIP not-ext4`.

  The new test case corrupts `s_log_block_size` and keeps the magic readable, so it never reaches this path.
- **Scope.** This is not a regression: 4eba26d answers the same way. But design v3 §3 / §10 presents MINOR-2 as covering
  a failing card, and this is the most likely way a card fails.
- **Fix (small).** In `--check` (and `--prov-get`), tell "cannot read the magic" apart from "the magic is not 53ef":
  - if `hexdump` fails or prints nothing on an existing `-b $DEV`, p5 is unreadable, not "not ext4";
  - return rc 5 `p5 stale: unverifiable (p5 unreadable: …)`. A read error on p5 is evidence by itself, so it should not
    need the marker. Or at least return rc 5 when the marker or MNTFAIL is present.
  - Add the R8 case (dm `error` + `--check`) to the test; 4eba26d, 6d65ecd and ec8b79a all FAIL it today.
- **Out of scope here, one checklist line on the issue.** The write modes use the same magic read, so an unreadable
  superblock is also treated as "not plain ext4" by `--seed`, which formats such a device. That is pre-existing and not
  part of this change.

### MINOR-2 — CI step: `apt-get install` without `apt-get update`, and the runner is still unverified

- `sudo apt-get install -y -qq "linux-modules-extra-$(uname -r)"` runs without an `apt-get update` first. On a runner
  with stale package lists, the fallback can fail with "Unable to locate package" even when the package exists.
- The failure is loud: a `::warning`, then the test FAILs under `CFGSAVE_REQUIRE_DM=1`.
- **Fix:** run `sudo apt-get update -qq &&` before the install, and attach the CI log lines showing the dm-flakey cases
  ran (§9 already plans that).

### MINOR-3 — The 6d65ecd negative-control range in §8 is already exceeded

§8 says 16–21 FAIL. My run gave `PASS=68 FAIL=23`. Results seen so far: 16, 17, 18 (round 2), 21 (fixer and coordinator),
23 (mine). Write "≥ the deterministic list (N cases); the rest vary with timing", or give the observed range.

### MINOR-4 — Owner decision: should "magic readable + ro mount fails 3×" count as evidence without the marker?

- **Today:** rc 1 unless a save failed this boot. The only uncovered case is a node that never joined and never saved
  this boot (see "The coordinator's questions").
- **Why it may be safe to block.** The transient that #202 guards against is the rw mount (T11, a read-only peer). A
  `ro,noload` mount of an ext4 that is already mounted shares its superblock and does not fail. A LUKS p5 has no ext4
  magic, so it would not match.
- **Suggestion.** If the owner agrees, return rc 5 whenever the magic is 53ef and `ro,noload` fails 3×. Otherwise keep
  the current rule and say in §7 that this gap is a deliberate decision. Not a blocker either way.

---

## Not done

- ❌ No CI run (branch not pushed), no node run, no qemu run with the node busybox. I relied on design §8 for that, plus
  R7 for the rootfs contents.
- ⚠️ R8 is a dm `error` emulation of a card whose reads fail. I did not check that a real failing SD card returns EIO on
  the superblock read (it may instead fail only some sectors).
