# Review v4 — reviewer A — `docs/design/254-v16-ud.md` v4 (8fdd143)

I read the whole document. I first looked at what the v4 changes could have broken: watcher logging, the kill judge,
the UD4 PANIC/CLEAN rule, the hex `ssid-restore`, the removal of ap-on, and the observe gate. Then I checked every v3
finding of both reviewers against source. Read-only: no node, no ssh, nothing committed. The mesh-id history is not a
finding (the commits are squashed before push).

## 1. Were the v3 findings fixed?

| v3 finding | State in v4 | Checked against |
|---|---|---|
| A M1 kill judge vs SIGPIPE | Fixed. The judge is now: orphan gone + `pr_slot_free` + `bad=1` + 0 + 22 + `pos_final`. VERIFY counts as supporting evidence; DIE is INFO. | `batman-slot:54-65, 765-770` |
| A M2 UD4 boot-reasons / panic value | The text is fixed: cmdline `panic=10`, PANIC → PASS, CLEAN → INVALID. **But the rule cannot reach PASS on this kernel → M1 below.** | `95-batman-storage:639-687` |
| A m1–m10 | Fixed. Minor 2 below finds one contradiction in the m5 fix. | `prov-254.sh:205-214` (`pr_acquire` replays a pending journal); `prov-undo-lib-254.sh:238-245` |
| B M1 global `sync` | Fixed: one sync at start, then the log is written in place with `dd conv=notrunc,fsync` (`batman-slot:752` uses the same on the node). Kill acts first and logs after. One residual gap for the cut sub-arm → minor 1. | — |
| B M2 unquoted `set --` | Fixed with the hex argument, constant-format decode and quoted apply. One contradiction → minor 2. | `prov-undo-lib-254.sh:239-240`; `settingsset.go:66` |
| B m1–m5 | Fixed. | — |

Other v4 items, checked and sound:
- **Watcher start.** In a non-interactive busybox `sh`, the `&` child is not a group leader, so `setsid` does `setsid()`
  in-process, and `$!` = pid = pgid. The `ud9.go` gate and the `pgid == pid` self-check close the registration gap.
  `kill-pg` passes `uvalid` (`prov-undo-lib-254.sh:68`) and is boot-bound.
- **Kill `pos_final`.** The orphan `dd` drains at most the pipe plus the helper's in-flight buffers after the kill, far
  under 8 MiB. Sampling until `dd` exits gives a value within one pipe-full of the true final position.
- **Removal of ap-on.** It left only a stale line: §15 row 13 still says "a `hexdump` passphrase producer". The rest is
  consistent; §1.2 step 1 makes an AP that is off INVALID.
- **Observe gate.** The result is keyed by the full `BATMAN_VERSION`, which carries the git and firmware shas. It is
  sound.

---

## 2. Findings

### MAJOR

**M1. UD4's new evidence rule cannot reach PASS: ramoops / pstore are kernel modules, so a panic before userspace leaves no dmesg record.**
- Scenario.
  - The UD4 panic happens in B's kernel at root mount, before any userspace.
  - `docs/design/crash-debug.md:54` records the kernel config: `CONFIG_PSTORE=m`, `CONFIG_PSTORE_RAM=m`. They are
    loaded by userspace (kmodloader), after root is mounted, so nothing captures this panic.
  - On the A fallback boot, `95-batman-storage:639-668` then finds no dmesg record (n = 0) but finds A's own shutdown
    marker from the `update.apply` reboot. The result is `clean=1` → `CLEAN: …`, and the console record is deleted on a
    clean boot (`:646`).
  - Under v4's rule that is INVALID "B boot not proven" — on every run.
- Consequence. The design spends the riskiest step of the PR on a row that can only end INVALID: the first panicking
  trial on the device, ~20 min, and NEEDS-PERSON if 04 does not come back. UD5 (i) rides on it.
- The owner's rule: "Probe unverified assumptions read-only before the design is approved." A8 was never probed for
  this point; the design now gates the row on it.
- Fix.
  - Add a read-only probe before approval:
    `grep -E '^(ramoops|pstore)' /proc/modules; ls /sys/module/ramoops/parameters/ 2>&1; cat /sys/module/ramoops/parameters/record_size`,
    plus `grep -i pstore /proc/config.gz`-style evidence if the image has it, or the firmware repo's kernel config for
    wsl.36.
  - If they are modules, choose one:
    - (a) a different, honest P. For example the boot-time gap: apply answer → A reachable, compared with the same run's
      restore reboot, with a threshold that covers B's firmware load + kernel boot + `panic=10`. Label it ⚠️ inferred.
    - (b) accept UD4 / UD5 (i) as not provable on this image, state it in §11, and skip the panic trial (less device
      risk).
  - Either way, the INVALID-forever outcome must be known before the run, not after it.

### MINOR

1. **Cut sub-arm: p2 is not the position at the cut.** The order is: read p1 → `dd … conv=notrunc,fsync` FIRE line →
   read p2 → `dd … fsync` PRE-B line → `echo b`. The second log fsync goes to the same mmc device while B's dirty pages
   are being written back, so it can wait behind them. The stream keeps going meanwhile, so the cut lands after p2 by
   an unknown amount. Fix:
   - read pos **once more right before** `echo b`, with no I/O in between (a `read` from fdinfo only);
   - fire only if that value is < SQ − 8 MiB, else write `UD9-MISS late` and do not cut;
   - log p2 and the fsync durations (uptime before / after) so the bound is visible.

   BAD stays 1 either way; this only makes the "mid-stream" claim true.
2. **`ssid-restore` contradicts itself.**
   - §9 promises an exact restore of the recorded ssid `x'y`.
   - §4.3's decode check requires every character to be in `apChars`, which has no `'` (`settingsset.go:66`), so the
     replay CRITs.
   - Real S0 ssids can hold characters outside `apChars`: an operator using LuCI or uci — P3's own SKIP_UNSAFE exists
     for "Tom's AP".
   - Fix: apply the **same** rule at `undo-add` (registration) as at replay. Either a ssid outside the rule makes the
     arm INVALID before the change, or the rule becomes "1–32 bytes, no NUL / newline" (the value is quoted, so that is
     safe). Then fix the §9 cases to match.
   - Also note that `$(…)` strips a trailing newline, so the pair-loop decode cannot carry a newline. The rule must
     exclude it explicitly.
3. **UD4 "any other line → FAIL".** An `UNCLEAN` line on the fallback boot means A's own `update.apply` reboot left no
   shutdown marker (`95-batman-storage:735`, written by `stop()`; `batman-slot reboot committed` is a procd `reboot`).
   That is an anomaly of the A shutdown, not evidence about the update path. Make it INVALID with the line attached, or
   FAIL with that attribution stated, rather than an unattributed FAIL.
4. **Stale text.** §15 row 13 ("a `hexdump` passphrase producer") and §0.3 #13's "Settles: passphrase producer" refer to
   the removed ap-on. Reword them.

---

## 3. Verdict: **APPROVE-WITH-CHANGES**

0 BLOCKER, 1 MAJOR, 4 MINOR.
- Every v3 finding of both reviewers is fixed in source terms, and nothing in the watcher, kill judge, hex restore or
  observe gate is broken beyond minors 1–2.
- M1 is an unprobed premise that makes UD4 (and UD5 i) INVALID by construction on this kernel. It needs a read-only probe
  and a decision before approval, not a redesign of the rest.
