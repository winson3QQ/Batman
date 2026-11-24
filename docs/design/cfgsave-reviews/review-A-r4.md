# Review A, round 4: cfgsave-stage-enospc (8763011..4a93ba2, design v4 re-checked as a whole)

Reviewer A. Scope: the round-4 change `8763011..4a93ba2` in full (45f47e2 product + tests + CI, 4a93ba2 design v4). I also re-read design v4 end to end, looking for anything the new behaviour now contradicts.

Ground rules for this round:
- Code read-only; runs on my own fresh clone `<home>/rev-cfgA4` (cloned from `Batman-app`, HEAD checked to be `4a93ba2`), WSL Ubuntu-24.04, root.
- No node touched; no commit, no stash.
- Nothing was aimed at `/dev/null`: before the run, my scripts were grepped for `sed -i` / `mv` / `cp` / `> /dev/null` used as a target, and none was found.
- `cmp` confirms the feed and deploy copies of `batman-config-save` are identical ✅.

**Verdict: APPROVE.** No BLOCKER or MAJOR. Two MINOR items, both for the checklist.

## 1. Runs

| # | What | Result |
|---|---|---|
| H ×2 | HEAD test on HEAD script, `CFGSAVE_REQUIRE_DM=1` | ✅ `PASS=96 FAIL=0` ×2 (83 s, 91 s) |
| V1 | HEAD test on the 6d65ecd script | ✅ `PASS=71 FAIL=25`, same as your run. It includes all five round-4 cases (unmountable ×2, unreadable ×3). |
| B | HEAD test on the 4eba26d script | ✅ `PASS=14 FAIL=82`, same as yours |
| R3 | HEAD test on the 8763011 script (round 3, the round-4 negative control) | ✅ `PASS=92 FAIL=4`. Exactly the round-4 cases fail: `--check unmountable without the marker: rc 1`, `--check unreadable superblock (no marker) / (marker): rc 3 SKIP not-ext4`, `--prov-get unreadable superblock: rc 12` |
| S | `slot-p5gate-txn.sh` on HEAD `batman-slot` | ✅ `21/0` |
| T | `cfgsave-txn-save.sh`: HEAD / 8763011 script / mutant | HEAD `59/0`. 8763011 `58/1`: `control unmountable: rc=1 … p5 error mount (ro,noload failed 3x)`. Mutant `53/6`, see §2 (3). |
| X | hexdump probe: host busybox 1.36.1 and the node's busybox (a53 build under qemu-user) | §2 (1) |
| P | The real `--check` / `--prov-get` (host busybox) on those devices | §2 (1) |
| N | The full test under the node's busybox | §4 |

## 2. Your points

### (1) Can the hexdump-based "unreadable" check misfire?

The product command is `magic=$(hexdump -s 1080 -n 2 -e '2/1 "%02x"' "$DEV" 2>/dev/null); mrc=$?`, and the device counts as unreadable if `mrc != 0` or `magic` is empty.

Probe (X) results, **identical on the host busybox and the node's busybox**:

| Device | magic | rc | stderr |
|---|---|---|---|
| zeroed 8 MiB loop | `0000` | 0 | — |
| ext4 loop | `53ef` | 0 | — |
| 1 KiB loop (shorter than the superblock) | empty | **1** | `Invalid argument` |
| dm `error` (whole device) | empty | **0** | `Input/output error` (node: `I/O error`) |
| dm: sectors 0-1 readable, **sector 2 (magic) error**, rest readable | empty | **0** | I/O error |
| dm: sectors 0-1 readable, everything after error | empty | **0** | I/O error |

What this shows:
- **busybox hexdump returns rc 0 on an I/O error.** The `mrc` check alone would never fire on EIO; it is the empty-output check that catches it. The design's sentence "`hexdump` fails or prints nothing" is right; the rc part only helps for the short-device case.
- I found no case where a read error produces output, so an unreadable device cannot be mistaken for "readable, not ext4" ✅.
- **The node's output format is the same as the host's** (`0000` / `53ef`, no address column, no `*`) ✅.
- **A p5 of a different size:**
  - a larger device makes no difference;
  - a device shorter than 1082 bytes gives rc 1 and empty output, so it is "unreadable" → rc 5 (fail-closed, and a real p5 is 512 MiB);
  - since a block device is read in whole pages, an error in another sector of the same page also makes the magic "unreadable" → rc 5. That is the conservative direction ✅.
- **The real script (P):**

  | Device | `--check` | `--prov-get` |
  |---|---|---|
  | zeroed | rc 3 `SKIP not-ext4` | rc 12 |
  | 1 KiB / dm error / sector-2 error | rc 5 `p5 unreadable: the superblock read failed` | rc 1 `p5 error unreadable` |

  Matches the design ✅.

### (2) The deviation: `--prov-get` on an unreadable superblock returns rc 1, not rc 5

**Justified.** rc 5 is not in `--prov-get`'s rc table at all, and rc 12 ("not ext4") would put the helper on the wrong path. Every reader of `--prov-get` (I read them all):
- **`boot.go:85-100`** retries 3 times on rc 1 / 8, then (`:259-263`):
  - overlay present → keeps it (`p5 unreadable: kept the overlay (persist will fail E_PERSIST)`);
  - otherwise → `unknown(p5-unreadable)`, and does not write.

  With rc 12 it was `unknown(p5-not-ext4)` and also no write. For a transient EIO, rc 1 (retry, keep this slot's own overlay) is the correct class, and it is the same one a mount failure already used (`p5 error mount` rc 1).
- **`boot.go:341-347`** (persisting the record): anything other than 0/7/9/10/13 → `p5 cannot take the record`. 1 and 12 lead to the same thing ✅.
- **`node/txn.go:61`** (`rc != 0 && rc != 13` → no answer) and **`node/wtxn.go:262-266`** (anything other than 0/7/9/13 → `EStorage p5 unreadable`): 1 and 12 behave the same ✅.

No caller gets less safe.

### (3) The changed control in `cfgsave-txn-save` (old rc 1, now rc 5): justified, or does it hide something?

- **Justified:** the control's image is an ext4 whose superblock counters before the magic are zeroed, so the magic is read as ext4 but the read-only mount fails. In v4, that is rc 5 `unverifiable (p5 does not mount read-only)`, by design. The control checks both the rc and the text. On the 8763011 script it FAILs (`rc=1`), so it measures the round-4 change ✅.
- **Does it hide something?** That section of the test exists to show the `.txn` check runs before every p5 check. With `.txn` present, the "bad" p5 now also gives rc 5, so rc alone no longer proves the order. But the loop checks the text `^batman-config-save: p5 stale: an unfinished network change (.txn)`.
  - **Mutant check:** I deleted the early `.txn` block (3 lines) in the script.
  - Result: the test FAILs 6 times, including `.txn + bad p5: rc=5 :: … p5 stale: unverifiable (p5 does not mount read-only)`, plus `.txn + raw: rc=3` and `.txn + nop5: rc=3`.
  - So the ordering property is still tested and nothing is hidden ✅.

### (4) The rest of round 4

- **CI:** `apt-get update -qq && apt-get install …` ✅ (my r3 F2). Not run on GitHub ❌.
- **The ext4 p5 whose read-only mount fails 3 times is now rc 5 without the marker:**
  - This closes my r3 F1 (a joined node with cache hits that never mounts p5).
  - The design's claim that "`ro,noload` next to a mounted ext4 shares the superblock and does not fail" matches what I know of ext4, but I did not test it in this round.
  - **However**, an ext4 p5 that is *held exclusively by someone else* (claimed by dm) also fails the read-only mount, and it now gets rc 5 with the same text as a corrupt one. Verified: a loop device under a dm linear map, `mount -o ro,noload` → `rc=32 … already mounted or mount point busy`; in run P, the real script's `--check` on that device gave rc 5 `does not mount read-only`.
  - On the node I know of no exclusive holder of a plain-ext4 p5 (the LUKS tier has no ext4 magic on the raw p5). The fresh slot's 96 could not mount it either, so rc 5 is the right verdict. Only the text cannot tell the causes apart (F1).

## 3. Findings

### F1 — MINOR: the `--check` "does not mount read-only" message drops the mount error

- **Scenario:** an operator sees `p5 stale: unverifiable (p5 does not mount read-only)` and cannot tell a corrupt superblock, an unsupported feature or a busy device apart (P / the busy test above).
- **Fix:** keep the last mount's stderr (`e=$(mount … 2>&1)`, as the `--reformat` path does) and append its first line to the message.

### F2 — MINOR: `mrc` adds nothing for EIO; make the comment say so

- **Evidence:** X. busybox hexdump returns 0 on an I/O error. The check works only because of `-z "$magic"`.
- **Fix:** change the comment to "busybox hexdump exits 0 on a read error and prints nothing — the empty output is what marks it; rc ≠ 0 covers a device shorter than the superblock". This keeps a later edit from dropping the `-z` test because it "looks redundant".

## 4. The design v4 as a whole

Things I checked against the new behaviour:
- **§3 / §7 failure mode:** the v3 fail-open ("ro mount fails, no marker → rc 1") is now removed. §7 says so. I found no leftover text that still claims rc 1 for that case ✅.
- **§9** keeps "`--seed` mkfs on an unreadable superblock" as an existing issue.
  - `MAGIC_UNREADABLE` now exists in the script, so the fix is one line (`[ "$MAGIC_UNREADABLE" = 1 ] && refuse` in the `--seed` branch).
  - The consequence is a reformatted p5 (lkg, identity, prov record). It was already like this before, and the item is in the checklist, so I am not raising it. I suggest doing it in the next change.
- **§8:** its 6d65ecd negative control is now a "deterministic list + timing-dependent cases". My V1 run is 71/25, inside the range it gives (16–25), and its deterministic list matches my FAIL lines ✅.

### N: the full test under the node's busybox

✅ `CFGSAVE_BB="qemu-aarch64-static -L <root-bcm27xx> …/bin/busybox"` (a53 build), `CFGSAVE_REQUIRE_DM=1`: `PASS=96 FAIL=0`, 687 s.

## 5. Wrap-up

- ✅ After the runs, `losetup -a` and `dmsetup ls` are both empty, and `/dev/null` is still `character special file 1:3`.
- My own process slip:
  - a wait loop I started (`pgrep -f "hexdump|rev4"` inside `bash -c`) matched its own command line and never ended;
  - I stopped that background task by its task ID, and it touched no device.
- ❌ Not done:
  - no node run;
  - no GitHub CI (`apt-get update` + whether `dm_flakey` loads is unverified);
  - no sbx;
  - the claim that a `ro,noload` mount next to an already-mounted ext4 does not fail was not tested this round;
  - I did not rerun the fixer's v4 mutants (`93/3`, `95/1`). R3 serves as the negative control for the round-4 cases instead.
