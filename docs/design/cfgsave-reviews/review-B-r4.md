# Review B, round 4 — cfgsave-stage-enospc (8763011..4a93ba2, design v4)

Reviewer: independent adversarial review (B), round 4.
- **In full:** the round-4 change (45f47e2 product + tests + CI, 4a93ba2 design v4).
- **Re-checked:** the whole design v4, for statements the new behaviour now contradicts.

I did not change the product code; I only read it. All runs were on a fresh clone `<home>/rev-cfgB4` (HEAD 4a93ba2) in
WSL Ubuntu-24.04 as root (kernel 6.6.114.1, busybox 1.36.1, dm `flakey` present). No node was touched. No tool was pointed
at `/dev/null` (it was `character special file 1,3` at the end).

**Verdict: APPROVE-WITH-CHANGES** (1 MAJOR, 2 MINOR).
- **What works.** My round-3 MINOR-1..4 are fixed and each has a negative control. The `--prov-get` deviation is right.
- **The MAJOR.** The coordinator asked whether blocking an OTA on a p5 that does not mount can block a healthy node. It
  can. A `ro,noload` mount of an ext4 that is **mounted read-write elsewhere** fails with EBUSY. `--check` now turns that
  into rc 5 "unverifiable", and the OTA is refused on a node whose saves still work.
- **Why it matters for the design.** Design v4 §3 (and the code comment at `batman-config-save:425-428`) rests the
  "no marker needed" decision on the opposite claim. The claim holds only when the other mount is read-only.

---

## Evidence

| # | What | Result |
|---|---|---|
| R1 | `cfgsave-stage-enospc.sh` at HEAD, `CFGSAVE_REQUIRE_DM=1`, product HEAD | ✅ `rc=0 PASS=96 FAIL=0` |
| R2 | Same test, product ec8b79a (round-3 negative control) | ✅ `rc=1 PASS=92 FAIL=4`. Exactly the four new cases: `--check unmountable without the marker: rc 1`, `--check unreadable superblock (no marker): rc 3`, `(marker): rc 3`, `--prov-get unreadable superblock: rc 12` |
| R3 | Same test, products 6d65ecd / 4eba26d | ✅ `PASS=70 FAIL=26` / `PASS=14 FAIL=82` |
| R4 | `cfgsave-txn-save.sh` at HEAD / `slot-p5gate-txn.sh` with the HEAD `batman-slot` | ✅ `PASS=59 FAIL=0` / `cases=21 fails=0` |
| R5 | `deploy/` vs `feed/` | ✅ identical |
| R6 | **Mount semantics on kernel 6.6**: a loop ext4 mounted rw at A, then a second mount at B, with util-linux and busybox `mount` | rw at A + `ro,noload` at B: **util-linux rc 32 "already mounted"; busybox rc 255 "Device or resource busy"**. busybox `-o ro` at B: also EBUSY. ro,noload at A + `ro,noload` at B: rc 0 (shared, `ro,…,norecovery`). ro at A + rw at B: EBUSY (T11's case) |
| R7 | **False-positive probes on a healthy p5**, using the real script under the test harness. The copy is named `batman-config-save`, so the lock's cmdline check works as it does on the node | see the table below |

R7, HEAD (4a93ba2) compared with ec8b79a and 4eba26d:

| State of a healthy p5 | HEAD | ec8b79a / 4eba26d |
|---|---|---|
| p5 mounted **rw** elsewhere (a writer killed with SIGKILL before its EXIT trap, a no-lock `RDOK=0` writer, or an operator's debug mount) | **`--check` rc 5 `p5 stale: unverifiable (p5 does not mount read-only)`**. Meanwhile `--save` rc 0 `saved` (the rw mount shares the rw superblock); after `umount`, `--check` rc 0 `fresh` | `--check` rc 1 `p5 error mount (ro,noload failed 3x)` |
| p5 mounted **ro** elsewhere (96 / chanfix / prov-lock style reader) | ✅ normal verdict (rc 5 with the real stale keys) | same |
| a concurrent save holding the lock | ✅ `--check` rc 8 `lock-busy` (no mount attempted) | same |
| first boot, zeroed p5 (before `--seed`) | ✅ rc 3 `SKIP not-ext4` | same |
| first boot, ext4 but unseeded | ✅ rc 7 `unseeded` | same |

Note on the harness: with the copy named `cs` instead, the lock's cmdline check does not recognise the running writer
and `--check` takes over its lock. That is a harness artifact. On the node the cmdline contains `batman-config-save`. I
re-ran with the real name, as above.

Cleanup: no loop or dm device of mine is left.

---

## The coordinator's questions

- **Unreadable superblock → `--check` rc 5; rc 3 only for a magic that was read: ✅.**
  - A readable device always prints 4 hex digits; the zeroed-p5 probe gives rc 3. The dm `error` cases give rc 5 with and
    without the marker.
  - Negative control: ec8b79a FAILs all three of these cases (R2).
- **Deviation: `--prov-get` rc 1 on an unreadable superblock: acceptable, and better than rc 5.**
  - rc 1 is `--prov-get`'s documented "mount failed / unreadable" class.
  - The helper maps rc 1 to "p5 unreadable: kept the overlay" (or `unknown(p5-unreadable)`) at `boot.go:259-263`, and its
    persist precheck refuses with "p5 cannot take the record" (`boot.go:341-346`). Both are the right reactions for a
    failing card.
  - rc 5 is not in `--prov-get`'s table and would fall through to `unknown(rc-5)`.
  - Previously rc 12 was reported as `unknown(p5-not-ext4)`, which was wrong for a dying card. ✅
- **ext4 but the ro mount fails 3× → rc 5 without the marker.**
  - Correct for a corrupt or failing card (test, R2).
  - A false positive on a healthy node whose p5 is mounted rw elsewhere → **MAJOR-1**.
- **No false positive from the lock:** a concurrent writer makes `--check` return rc 8 before any mount (R7).
- **No false positive on a first boot before `--seed`:** rc 3 / rc 7 (R7). ✅
- **`apt-get update` in CI: ✅.** The runner is still unverified (the branch is not pushed); §9 says so.
- **§8 wording:** now a deterministic list plus timing cases. ✅ This round's 6d65ecd count, 26, is above the range
  written there (16–25); see MINOR-2.

## Design v4 contradictions found

1. **§3 and the code comment (`batman-config-save:425-428`):** "`ro,noload` 掛載一個已掛載的 ext4 會共用 superblock,不會失敗"
   ("a `ro,noload` mount of an already-mounted ext4 shares its superblock and does not fail"). R6 shows this is false when
   the existing mount is rw. → MAJOR-1.
2. **§7 failure mode:** "讀不到的 p5 與掛不上的 ext4 p5 都回 rc 5" ("an unreadable p5 and an unmountable ext4 p5 both return rc 5")
   is presented as covering only broken p5s. It also catches a healthy, busy one. → MAJOR-1.
3. Nothing else I checked contradicts the new behaviour:
   - the rc table (header, §3);
   - the callers table;
   - lifecycle (§5): first seed, downgrade (the marker is in tmpfs; older versions return rc 1 / 3 as before), power cut;
   - the stage-2 gate (it uses the stage-1 verdict `stale:unverifiable`, refused unless overridden, as in round 3).

---

## Findings

### MAJOR-1 — A healthy p5 that is mounted rw elsewhere is reported "unverifiable" and blocks the OTA with "the card needs attention"

- **Scenario.** p5 is mounted rw outside the current `--check`, while every save still works. How that happens in the field:
  - **A writer killed with SIGKILL before its EXIT trap unmounted p5.** The helper's `stopGroup` sends SIGKILL 30 s after
    TERM to a member still running (`provstore/exec.go:139-160`); the OOM killer can do the same. Its lock is taken over
    later because the pid is gone, but its rw mount stays until reboot.
  - **An operator mounts p5 rw** to look at it during field support.
  - **A writer running without the run dir (`RDOK=0`),** which takes no lock.

  `--check` then fails `ro,noload` 3× (EBUSY), returns rc 5 `unverifiable (p5 does not mount read-only)`, and
  `batman-slot:576-579` refuses the OTA with "if p5 does not mount, the card needs attention". Meanwhile `--save` succeeds
  on the same p5.
- **Before this round:** rc 1, so not blocking unless there was mount or lock evidence.
- **Evidence.** R6: kernel 6.6, util-linux rc 32 "already mounted" and busybox rc 255 EBUSY. R7: HEAD rc 5 while
  `--save` rc 0, and `fresh` after `umount`; ec8b79a and 4eba26d rc 1. The new test only corrupts the superblock and has
  no "healthy but busy" control, so nothing catches this.
- **Impact.** The gate fails closed, the override exists, and a reboot or `umount` clears it. So no data is at risk. But
  the OTA is refused on a healthy node with a misleading diagnosis, and the design's justification for dropping the
  marker rests on a false assumption (owner rule: "should be" is not evidence).
- **Fix (small).**
  1. Before declaring "does not mount", look at `/proc/mounts` for `^$DEV `. If p5 is mounted elsewhere, either:
     - compare through that mount (it is readable; for example a `mount --bind` read-only of that mountpoint, or read
       the files in place); or
     - return a distinct verdict, `p5 error busy (mounted at <mnt>)` rc 1, which is the previous behaviour.
  2. Keep rc 5 for "not mounted anywhere and does not mount".
  3. Fix the sentence in §3 and in the code comment.
  4. Add a control to the test: p5 mounted rw at another mountpoint → `--check` is not "unverifiable". HEAD fails it
     today; that is its negative control.

### MINOR-1 — The test has no healthy-but-busy control for the new rc 5 paths

This is part of MAJOR-1's fix. Every new rc-5 case uses a broken device (corrupted superblock, dm `error`). Both rc-5
branches need a control that shows they do not fire on a healthy p5 in a busy state:
- p5 mounted rw elsewhere → not rc 5 (fails at HEAD);
- p5 mounted ro elsewhere → normal verdict (passes);
- a concurrent writer with the real name → rc 8 (passes).

### MINOR-2 — §8's observed 6d65ecd range is out of date again

This round: `PASS=70 FAIL=26`; §8 says "16–25". The deterministic list is the real claim. Drop the observed total, or
write "≥ <deterministic count>".

---

## Not done

- ❌ No CI run (the branch is local), no node, and no qemu run with the node's busybox `mount`. R6 used WSL's busybox
  1.36.1 and util-linux. The EBUSY comes from the kernel (a second mount that would change the RO state of an existing
  superblock is refused), so I expect the same on the node's 6.6 kernel, but I did not run it there ⚠️.
- ⚠️ The SIGKILL-with-a-leftover-mount path is inferred from the helper's `stopGroup` code and OOM behaviour. I did not
  reproduce it end to end; R7 emulates its end state with a plain rw mount.
