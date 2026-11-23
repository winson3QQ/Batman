# Review v3 — reviewer A — `docs/design/254-v16-ud.md` v3.1 (b2812b0)

The whole document was read again and the fixes were checked against source. §0.4 and §15 were checked line by line
against the raw probe `docs/design/254-reviews/v16ud-eud1.log`. Read-only: no node, no ssh, nothing committed. The mesh
id in the log is not a finding (the owner redacts it before push).

## 1. Are the v2 findings fixed?

### Reviewer A v2

| Finding | State in v3.1 | Checked against |
|---|---|---|
| M1 caps line | fixed: stderr only, helper-socket ops only; byte-identity tests for `exec` / `proxy` | `proxy.go:1-40`; `prov-provd-wbox-254.sh:61` |
| M2 P9 fleet-wide | fixed: gated on the `pupdate…` dirty flag, WARN otherwise; strict checks only in this unit's `pr_begin`; rc 8 retried | `dv-preflight.sh:100-110`; `prov-p9-254.sh:71` |
| M3 openmanetd key | fixed by removal. UD13 keeps the exempt ssid; UD6 (b) uses a safe ssid with joinwatch stopped. | see Q12 below |
| m1 EBusy retry | fixed (§1.1) | `update.go:328-329` |
| m2 watcher lifetime | fixed (§1.5 1–7), one ordering gap → m3 | — |
| m3 Q10 label | fixed (§1.5, §11) | — |
| m4 base64 / printf | fixed: `hexdump` writes the secret to a pipe; constant text only through builtins | log #13b, #14 |
| m5 passphrase in p6 | fixed: `ssid-restore` carries only the ssid; no wireless export on this bench | — |
| m6 Q9 + `ap_key_sha` | fixed (§12) | — |
| m7 old binary | fixed (`provclient-arm64.pre-ud`, `PCBIN=old`) | — |
| m8 per-generator acceptance; FEXTRA range | fixed (§3.3) | — |
| m9 last stderr line | verified by the author, and I agree for a **live** helper (`batman-slot:60-65` prints one line). The kill sub-arm is different → **M1** | — |
| m10 dd fd premise | input side shown (log #15: fd 0 = `/dev/mmcblk0p4`, pos 0 → 12582912). Output side gated by observe mode | — |

### Reviewer B v2

| Finding | State in v3.1 | Checked against |
|---|---|---|
| M1 Y = badpayload | fixed | `sums_sha` differs: the root line changes, `p3-payloads.sh:56-58`. pending / bulk / prepare compare only it (`update.go:362-366`, `bulk.go:63`, `updwork.go:208-211`). |
| M2 journal order, `undo-done` | fixed | `pl undo` before `pr_restore`; inline inverses |
| M3 watcher | fixed apart from m3 | — |
| M4 openmanetd | fixed (removed) | — |
| m1–m8 | addressed | — |

### Rows re-traced in source
- UD13: a committed `'` ssid is SKIP_UNSAFE. p5 holds the S0 ssid line (p5 fresh at S0, log #22), so `diff_keys` yields
  `wireless.default_radio0.ssid` with no REJECTED → rc 5 without "(unpersistable"
  (`batman-config-save:462-468, 486-497`). `onlyP3Stale` is then true → PreSave `--save` → precheck `fresh` → `ok=true`.
  This is deterministic with joinwatch stopped.
- UD6 (b): a safe ssid committed after the check gives rc 5 with a plain key list → `die_c 12 "p5 (config) is STALE…"`
  (`batman-slot:577`) → reason 17, before `begin_write`. No other p5 writer runs in that window:
  - `saveAfterCommit` runs only at helper start (`cmd/batman-provhelper/main.go:667-671`);
  - PreSave runs only in `update.check`.
- The S0 `update-last` (wsl.35): row 5 on wsl.36 (`updwork.go:888-890`); tick disarm inert (`apply_boot_id` is an old
  boot); prepare overwrites it. **The decision to keep it is sound.**

No BLOCKER.

---

## 2. Findings

### MAJOR

**M1. The kill sub-arm asserts an ota-trace line the orphan will usually never write (SIGPIPE).**
- Scenario.
  - After `kill -9` of the helper, the orphan `batman-slot write` still has stdout and stderr connected to pipes whose
    reader (the dead helper's Go copy goroutines) is gone.
  - `die_c` prints to stderr **first** and writes the otalog line second: `echo "batman-slot: $*" >&2; … otalog_k SLOT
    DIE …` (`batman-slot:60-65`, the same order in `die`, `:54-58`).
  - The echo raises SIGPIPE; with the default disposition the shell dies before `otalog_k`, and the EXIT trap does not
    run either.
  - Any `warn` on the way can kill it even earlier, e.g. `disarm_tryboot`'s warn lines (`:418, 427`), which run after
    `invalidate_slot` and before `die_c` in `write_slot` (`:766-770`).
  - So "`ota-trace.log` gains `SLOT DIE cmd=write rc=13`" FAILs on a correct product.
- Evidence that helper children really die this way: P3's own negative control for halow-setkey — "沒有 `trap '' PIPE`
  的 setkey 停在一半" when the helper is killed (`254-p3-impl.md:729`).
- The safety claim still holds:
  - BAD was synced at `begin_write`;
  - `invalidate_slot` (files only, `:406-411`) runs before any stderr write in the failure branch;
  - a SIGPIPE death never clears BAD.
- Fix.
  - Judge on facts that do not depend on the orphan's stderr: the `SLOT VERIFY slot=B result=<not ok>` line
    (`st VERIFY`, written to the trace file before the failure branch, `:765`), **or** simply the orphan's exit
    (pidfile / `/proc`) + `pr_slot_free` + `bootinfo B bad=1` + status 0 + 22.
  - Keep `SLOT DIE … rc=13` as INFO: present or not, it does not decide.
  - Add the SIGPIPE path to §0.2 and to the offline judge fixtures (a trace with VERIFY and no DIE → PASS).

**M2. UD4's boot-reasons expectation ("UNCLEAN") is wrong, and the A8 "3 s" correction does not apply to this panic.**
- Scenario.
  - The UD4 panic happens in B's kernel at root mount ("VFS: unable to mount root"), before any userspace.
    `/etc/sysctl.d/10-default.conf`'s `kernel.panic=3` (log #16b) is applied by userspace, so it never takes effect on
    that boot. B's cmdline carries `panic=10` (`CMDLINE_COMMON`, `batman-slot:51`; the real cmdline is restored by
    `write_slot`).
  - The A fallback boot classifies "the previous life" by the evidence present (`95-batman-storage:656-687`). Two
    outcomes are possible:
    - a pstore dmesg record → `PANIC (n pstore record(s) …)`;
    - no dmesg record → the **shutdown marker left by A's own clean reboot** at `update.apply` (`reboot committed`)
      → `CLEAN: …`. B's panic never ran userspace, so it cannot remove or write that marker.
  - "UNCLEAN" is therefore not an expected outcome. A judge requiring it FAILs on a correct product.
- Second point: the boot-reasons line is UD4's only proof that B was actually tried. Without it, "6 + 18" would also be
  the answer if the firmware had ignored the tryboot (`rebooting` true, no aclog line, `updwork.go:898-903`).
- Fix.
  - UD4 P = a `PANIC` boot-reasons line on the fallback boot plus the saved pstore dmesg containing "Unable to mount
    root" (or B's boot id in the record).
  - If the line is `CLEAN`, the trial is not shown → INVALID "B's boot not evidenced", not FAIL and not PASS.
  - Correct the §0.4 #16 row and §15: 3 s applies to userspace panics; the UD4 panic uses cmdline `panic=10`.

### MINOR

1. **Q12: accept, but cite the existing offline negative control.** The device can no longer show "a non-exempt key →
   17", but `tests/prov-p3/cfgsave-ssid.sh:61` already runs the real `batman-config-save` with an UNSAFE **mesh key**
   → rc 5 "unpersistable" (and the exempt ssid case, ibid. header lines 3-5). Name it as UD13's flip, and include it in
   the PR's offline results with its output. With that, Q12 = yes.
2. **Q13: accept.** joinwatch stopped ≤ 10 min suspends save-on-join, `joinwatch.lastjoined` and the addr-defer
   reconcile (`joinwatch:142-164`). None of these is read by the steps inside that window: the worker's
   `batman-slot write` does not read `lastjoined`, and the sysupgrade-based B rewrite runs after the restart. Add one
   line: "the restart is checked (`pidof joinwatch`) before the next row", which §4.3 already does inline.
3. **Watcher: "register before start" is not possible as written.** The pgid exists only after `setsid … &`.
   - With busybox `setsid` in a non-interactive sh, the background child is not a group leader, so `$!` = pid = pgid.
   - Say so, and close the gap: the watcher waits for a `ud9.go` file before it looks at `/proc`. The unit registers
     `kill-pg $!` and only then creates `ud9.go`.
   - Offline: a watcher without `ud9.go` never acts.
4. **§7 "04 reboots while joinwatch is stopped"** names the wrong detector.
   - After the reboot, joinwatch starts and saves p5 **with the committed test ssid**: dv-s is saved as is; dv'q is
     skipped, and PreSave / `--save` already wrote p5 without the ssid line. So `--check` is fresh and rc 5 never shows.
   - The AP also comes up on air with the test SSID.
   - The real detector is the dirty flag (`prov-p9-254.sh:71`), followed by the snapshot restore. State that, plus the
     on-air side effect.
5. **`ssid-restore` argument.** `apChars` allows a blank, `*`, `%`, `^`, `~`, `=` (`settingsset.go:66-68`), while
   journal lines are blank-separated and the replay is a root shell.
   - Specify: refuse an S0 ssid containing a blank (INVALID before the arm, since it cannot be journalled);
   - always pass it quoted (`uci set "wireless.default_radio0.ssid=$v"`), never word-split or globbed;
   - an empty or unset S0 ssid → `uci delete`, not `set ''`.
   - Offline cases: `a*b`, `a b`, empty.
6. **Inline `p5-save`.** UD13's inline restore marks `p5-save` done without running it. p5 then lacks the ssid line
   that PreSave removed, until joinwatch's next tick. Run `batman-config-save --check` until `fresh` (≤ 30 s) before
   `undo-done` of that line, else FAIL.
7. **File-mode check after `uci commit`.** The new mode depends on the umask of the committing shell and on libuci's
   temp-file handling. A harness shell under `umask 077` may turn 0644 into 0600 and trip "mode changed → FAIL".
   Commit with the product's umask (022) explicitly, or record the expected mode per commit, and say which.
8. **`pr_begin` precondition wording.** "Row 5 or row 11, with no sha" cannot be met by row 11: `st(0, 0)` carries
   `ul.Sha` (`updwork.go:884-886, 919`). Accept row 5 only (the S0 case), or accept row 11 with a sha equal to the
   snapshot's `update-last` sha.
9. **Cross-run gate.** Observe mode runs in the write arm (its own snapshot and run) and gates the kill arm (another
   run). Persist the observe verdict host-side (run id, image version, `UD9-OBS` line, file sha). The kill arm reads it
   and is INVALID if it is missing or from another image.
10. **Stale text in §4.3.** "On the bench, S0 is keyguard-blocked with a placeholder key or `disabled=1` (E-UD1 #4)"
    contradicts log #4 / #8 (AP on, nothing blocked). Reword it as the conditional case only.

---

## 3. Owner's provisional answers

| Q | Verdict |
|---|---|
| Q12 | Yes, with the offline control `tests/prov-p3/cfgsave-ssid.sh:61` named (m1). |
| Q13 | Yes (m2). |

## 4. Verdict: **APPROVE-WITH-CHANGES**

0 BLOCKER, 2 MAJOR, 10 MINOR. Every v2 finding from both reviewers is fixed and holds in source, and the E-UD1 folding
is correct except §0.4 #16 (M2). The two MAJORs are judge-level fixes that would otherwise FAIL a correct product:

- M1: the kill sub-arm's trace line under SIGPIPE;
- M2: UD4's boot-reasons expectation.

Under the owner's rule they are fixed and re-checked before implementation. A focused re-check of §1.4 UD4, §1.5 and
§0.4 #16 is enough, if the owner agrees.
