# Review B, round 5 — cfgsave-stage-enospc (d0c3f7e..3781b00, design v5)

Reviewer: independent adversarial review (B), round 5.
- **In full:** the round-5 change (e30f746 product + tests, 3781b00 design v5).
- **Re-checked:** the whole design v5, for statements the new behaviour now contradicts.

I did not change the product code; I only read it. All runs were on a fresh clone `<home>/rev-cfgB5` (HEAD 3781b00) in
WSL Ubuntu-24.04 as root (kernel 6.6.114.1, busybox 1.36.1). Reviewer A's runs were active on the same WSL at the same
time. No tool was pointed at `/dev/null` (`character special file 1,3` at the end).

**Verdict: APPROVE** (no BLOCKER, no MAJOR; 4 MINOR).
- **Fixed, with negative controls:**
  - my round-4 MAJOR-1 (a busy healthy p5) and MINOR-1/2;
  - the `--seed` refusal on an unreadable superblock.
- **Probes against the mountinfo lookup.** They only succeed for a root actor. Root can already write p5 directly, so
  this is robustness, not a security hole (MINOR-1, MINOR-2).
- **The fixer's ❓ setup abort.** I reproduced it: 1 of my 3 back-to-back runs failed the same way and leaked its
  devices. I could not attribute it (MINOR-4). It can only produce a FAIL, never a false PASS.

---

## Evidence

| # | What | Result |
|---|---|---|
| R1 | `cfgsave-stage-enospc.sh`, `CFGSAVE_REQUIRE_DM=1`, product HEAD: 3 back-to-back runs + 2 runs at once | seq1 ✅ `PASS=103 FAIL=0`; seq2 ✅ `103/0`; **seq3 ❌ `PASS=55 FAIL=43`** (MINOR-4); par1 ✅ `103/0`; par2 ✅ `103/0` (both at once, alongside reviewer A's run) |
| R2 | Same test, product 4a93ba2 (round-4 negative control) | ✅ `PASS=97 FAIL=6` |
| R3 | Same test, products 6d65ecd / 4eba26d | ✅ `PASS=69 FAIL=34` / `PASS=17 FAIL=86` |
| R4 | `deploy/` vs `feed/` | ✅ identical |
| R5 | **mountinfo attacks** (root actions), real script under the test harness | see "Attacks on the mountinfo lookup" |
| R6 | Do WSL sessions share a mount namespace? (testing whether another `wsl.exe` session copies a mount; R1 seq3 lead) | ✅ yes: `session1 ns=mnt:[4026532217] = session2 = pid 1`. The other session sees the mount and loses it after the umount; `mkfs` after the umount gives rc 0 → hypothesis rejected |

R2, the six 4a93ba2 FAILs:
- two "does not mount" texts that lack the mount error;
- the three healthy-busy cases, `rc 5 … does not mount read-only`;
- `--seed` on an unreadable superblock: rc 1, "formatting …" then `mkfs.ext4 failed`. 4a93ba2 *tried to format* it.

Cleanup: the seq3 run leaked `cfgenospc62504` over `/dev/loop1` (backing a deleted file). It was mine: its table maps
7:1, the journal shows its `tmp.wap3NVNBOa` mounts, and the process was gone with open count 0. I removed it. What is
left (`cfgenospc1007139` / `loop0`) belongs to reviewer A's run.

---

## Attacks on the mountinfo lookup (`p5_mounted_at`, `batman-config-save:388-397`)

The lookup reads `/proc/self/mountinfo`: the mount namespace of the `--check` process itself (root, init namespace).

| Attack | Who can do it | What `--check` says (R5) |
|---|---|---|
| **A. A mount stacked on top of the other p5 mountpoint.** Healthy p5 (OLD) is mounted rw at `x`; a tmpfs with a copy of a p5 is mounted on top of `x`; live = NEW | root in the init namespace | `p5 is mounted at …/x by another process — compared through that mount` and then the verdict **of the tmpfs**: `p5 stale: identity-or-schema`. The control without the tmpfs gives the real key list. The verdict comes from whatever is on top of the path; with matching content it would be `fresh` |
| **B. A non-p5 filesystem whose mount *source* is the p5 name.** `mount -t tmpfs /dev/mapper/<p5> z`; its mountinfo line is `0:81 / … - tmpfs /dev/mapper/cfgenospc…`. Real p5 corrupt | root | It is matched **by name** (`src == n`) and compared through the tmpfs (`stale: identity-or-schema` from the fake). It should have been `unverifiable (p5 does not mount read-only: …)`; the control without the alias gives exactly that. With matching content, a broken p5 would be reported `fresh` |
| **C. Only a subdirectory bind of a healthy rw p5 remains.** `mount --bind x/identity z; umount x`; mountinfo `254:2 /identity …/z` | root / operator | `$4 == "/"` correctly skips it, so `--check` finds no whole mount, `ro,noload` gets EBUSY → rc 5 `does not mount read-only: … Device or resource busy`. A healthy p5 is still reported unverifiable in this corner (MINOR-2) |
| D. A mountpoint containing a blank (mountinfo shows `\040`) | anyone who can mount | rc 5 `busy … could not be compared` (fail-closed; tested) ✅ |
| E. A **lower-privileged process** | no init-namespace mounts | Mounts it makes in its own user or mount namespace never appear in root's `/proc/self/mountinfo` (separate namespace). It cannot make a mount, so it cannot feed this lookup. The remaining path race (rename a parent directory of the found mountpoint between the lookup and the reads) needs p5 mounted under a directory that process owns. A killed writer's mountpoint is inside the 0700 run dir; an operator's is root-owned in practice. Not reachable in practice ✅ |

**Reading through another writer's live rw mount (asked).**
- **A half-written file cannot give "fresh".** `p5_matches` needs every compared file to be byte-identical to the stage
  over its whole length. A file being written in place is shorter or different until it is complete.
- **Whole-file renames:** a reader sees either the old or the new file. A mix of old and new whole files is "fresh" only
  if every compared file already equals live.
- **Who can be writing at all.** `--check` holds `cfgsave.lock`, so no locked writer can be mid-save (the concurrent-save
  case gives rc 8). Only a lockless writer or an operator remains.
- **⚠️ Caveat.** Through another rw mount, "fresh" reflects that mount's *page cache*, which may not be on the card yet
  (dirty data written back after up to about 30 s, or at umount). For a killed writer mid-publish, the card could briefly
  hold the old files. A clean reboot (the OTA path) writes them back. This is not a finding, but §3 could say it.

---

## Design v5 re-check

- **§3 (corrected claim): ✅.** It now states that a second `ro,noload` mount fails when the first mount is rw. This
  matches round-4 R6.
- **§3 "matched by major:minor (and source name)": too broad.** Attack B shows the name match accepts a non-p5
  filesystem. → MINOR-1.
- **§3 "只讀檔案,不寫、不 remount、不 bind" ("only reads files; no write, no remount, no bind"): accurate.** Because no
  bind is made, a stacked mount on the path is read instead of p5 (attack A). → MINOR-1.
- **§7 "健康但忙碌的 p5 … 不會被誤擋" ("a healthy but busy p5 … is not wrongly blocked"):** true except for a
  subdirectory-only bind (attack C). → MINOR-2.
- **§8: ✅ consistent.** It no longer quotes 6d65ecd totals (mine: 34), and the deterministic list is the claim.
- **`--seed` refusal: ✅** (`:301-304`). An unreadable superblock is refused before `seed_key_ok` and `do_mkfs`; a
  readable zeroed p5 is still formatted (control). `--seed --reformat` cannot bypass it: an unreadable magic is not
  `53ef`, so it takes the refusing branch.
- **`ls -lnL` → `major:minor`: ✅.** It works for busybox's `179,   5` layout (split on blanks), and `$3` of mountinfo is
  the filesystem's `st_dev`.
- **The other `$MNT` users** after the mount block are write-mode or `--prov-get` only (`:493-503`, `:600`). `--check`
  reads only `$P5R`. ✅

---

## Findings

### MINOR-1 — The lookup can be pointed at something that is not p5 (name match; stacked mount); verify the device after binding instead

- **Scenario.** Both are root-only. Root can already write p5, so this is robustness and "our own mistakes", not privilege.
  - Attack A: a mount stacked on the found mountpoint is read instead of p5.
  - Attack B: a filesystem whose source *string* equals `$DEV` is accepted, so a broken p5 can be reported with someone
    else's content (up to `fresh`).
- **Evidence.** R5 A/B, with controls.
- **Fix (small).**
  1. Drop the `src == n` match. `major:minor` is authoritative; aliases such as `/dev/root` have the same `$3`.
  2. Do not read through the other path. `mount --bind "$busy" "$MNT"` (a bind of an rw mount is allowed;
     `remount,bind,ro` it if wanted), then require that **our own** mountinfo line for `$MNT` has `$3 == mm` and
     `$4 == /`, and compare through `$MNT`. That removes the stacked-mount and path-race cases at once, because the
     bind captures the mount that is on top at bind time and the check then proves it is p5.
  3. Tests: A and B as negative controls (HEAD fails both today).

### MINOR-2 — A healthy p5 visible only through a subdirectory bind is still "unverifiable"

R5 C. Rare: someone has to bind a subdirectory of p5 and then unmount the whole mount. The result is fail-closed with the
real error text (`Device or resource busy`), and the override exists. **Fix:** document it in §7 as a known edge.
Optionally, when `mountinfo` shows any `$3 == mm` entry, say `p5 busy (only part of it is mounted at X)` so the operator
knows it is not the card.

### MINOR-3 — State the page-cache meaning of "compared through that mount"

See the ⚠️ caveat above. One sentence in §3 is enough: "fresh through another rw mount = that mount's current content,
not necessarily on the card yet".

### MINOR-4 — The test's own setup can fail mid-run with "device in use" and leak its devices: ❓ unattributed, reproduced 1/5 here

- **Reproduced.**
  - R1 seq3 started straight after seq2 ended. It passed 55 cases (through `--if-healthy K=12`).
  - Then every per-case `mkfs.ext4` said `/dev/mapper/cfgenospc62504 is apparently in use by the system`, and all
    remaining cases FAILed `setup mkfs`.
  - Its EXIT cleanup could not remove the dm device, which stayed with open count 0 once the hold had passed.
  - This is the fixer's signature (theirs failed at K=1).
- **What I ruled out.**
  - A mount copy in another WSL session's namespace: R6, all sessions share one namespace.
  - systemd timers: none fired at 05:58.
  - Processes in other mount namespaces: none exist.
  - No mount of the device was visible in `/proc/mounts` at the time.
- **What remains.** Something claimed the dm device exclusively for tens of seconds, outside any mount we can see. In
  both occurrences another reviewer's test was running on the same kernel at the same time. Still ❓.
- **CI impact.**
  - CI runs one instance on a fresh runner, so concurrency with another run does not exist there.
  - Whether the same hold can happen alone is unknown.
  - It can only cause a FAIL (setup failures are `bad`), never a false PASS.
- **Fix (test only, cheap).**
  1. On a setup `mkfs` / `mount` failure, print the evidence needed to attribute the next occurrence:
     `dmsetup info -c`, `ls /sys/block/<dm>/holders`, `grep -l <maj:min> /proc/*/mountinfo`, `fuser -vm $DEV`.
  2. Wait and retry a setup `mkfs` for a bounded time (for example 30 s with `udevadm settle`) when the device is **not**
     mounted in our namespace. A mount of it in our namespace is a product or test bug and must FAIL at once, so the
     retry cannot hide one.
  3. Use `dmsetup remove --retry` in cleanup, and FAIL loudly if the device still exists (today the leak is silent).

---

## Not done

- ❌ No CI run (branch local), no node, and no qemu run with the node's busybox for the new lookup (design §8 reports
  103/0 under qemu; I did not repeat it).
- ⚠️ Attacks A/B used content from a different live generation, so they produced "stale" rather than "fresh". The
  mechanism (which filesystem is read) is shown; the "fresh" outcome is inferred.
- ❓ MINOR-4 is unattributed (see above).
