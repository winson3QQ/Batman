# Review v5 — reviewer A — `docs/design/254-v16-ud.md` v5 (3ab6d27)

I read the whole document and checked it against source and against the owner's probe log
`docs/design/254-reviews/v16ud-eud2.log`. First I looked at what v5 could have broken:
- the cut sub-arm's p3 re-read;
- the `ssid-restore` rule and its round trip;
- §7.1's manual NEEDS-PERSON sequence, checked command by command against `scripts/dv/prov-254.sh`,
  `scripts/node/prov-base-254.sh`, `prov-lease-254.sh`, `ble-lib-254.sh` and `prov-undo-lib-254.sh`.

Read-only: no node, no ssh, nothing committed. The mesh-id history is not a finding.

## 0. Correction of my v4 M1

My v4 M1 was wrong. I cited `docs/crash-debug.md:54` (`CONFIG_PSTORE=m`, `CONFIG_PSTORE_RAM=m`) without checking
that it described the shipped kernel. The E-UD2 log shows the wsl.36 kernel has:
- `CONFIG_PSTORE=y` and `CONFIG_PSTORE_RAM=y`;
- nothing in `/proc/modules`;
- `pstore: Registered ramoops as persistent store backend` at 0.0167 s;
- `record_size=16384`.

The backend is therefore up long before the root mount where UD4's panic happens. v5's UD4 rule (PANIC + root-mount text
→ PASS, CLEAN → INVALID) stands. Putting the stale doc on the #254 checklist (§12) is the right correction.

## 1. Were the v4 findings fixed?

| v4 finding | State in v5 | Checked against |
|---|---|---|
| A M1 pstore is a module | Overturned by E-UD2 (§0 above). | `v16ud-eud2.log` |
| A m1 cut position | Fixed. p3 is read from `fdinfo` with no I/O before `echo b`; `UD9-MISS late` means no cut; `fsync_s` is logged; the margin argument holds. | BAD is cleared only by a successful `write_slot`: the stream `dd` must finish its `conv=fsync` of tens of MB and the full uncached read-back must pass (`batman-slot:735-775, 856`), which takes many seconds. The check runs microseconds before the cut. |
| A m2 `ssid-restore` rule | Fixed. One rule (1–32 bytes, no NUL, no newline), used at registration and at replay; a round trip at `undo-add`. | The decode is sound for `%`, `\`, `*`, `'`, a blank and bytes ≥ 0x80. The octal escape is emitted by printf's escape processing at the backslash, so it is never re-read as a conversion. |
| A m3 UNCLEAN | Fixed (INVALID with the line attached). | `95-batman-storage:664-686` |
| A m4 stale text | Fixed. | — |
| B M1 no automatic recovery | Answered with option (b): NEEDS-PERSON plus §7.1. **The §7.1 commands are wrong in several places → M1.** | below |
| B m1–m5 | Fixed (the observe key now includes the MAC; the watcher log is printed before it is deleted). | — |

No other v5 change breaks anything I can find.

---

## 2. Findings

### MAJOR

**M1. The §7.1 manual recovery sequence, as written, fails or does harm on the paths it is printed for.**

These lines are printed to a person by P9, so each defect below is a wrong instruction. Each is checked against the
library itself.

1. **`PR_WROTE_B=1` in step 2's environment is overwritten.** Sourcing `prov-254.sh` runs line 47:
   `fails=0; …; PR_BEGUN=0; PR_SNAPPED=0; PR_WROTE_B=0; …`. The shell then sets `PR_BEGUN=1; PR_SNAPPED=1`, but not
   `PR_WROTE_B`.
   - After any write, kill or trial arm, slot-B.protected was removed by `begin_write` (`batman-slot:479`).
   - `pr_restore`'s compare then does not filter the `protB` DIFF (`prov-254.sh:494-496`). It reports "S0 not restored",
     `&&` skips `pr_brewrite` and `pr_finish_snap`, and the dirty flag stays.

   Fix: set `PR_WROTE_B=1` inside the `bash -c` string after sourcing, like `PR_BEGUN` / `PR_SNAPPED`. `PR_V`,
   `PR_BASE` and `PR_S0_STATE` are not reset at source (only `pr_begin:690, 703` sets them), so passing them in the
   environment works.
2. **Order: a node on B must go back to A before step 1, not inside step 2.**
   - `ssid-restore`, `uci-restore` and `rm-hold` are bound `p6 slot:A`. On B the replay leaves them as
     `NEEDS-PERSON … bound to slot:A, running B` (LEFT, `prov-undo-lib-254.sh:242-243`).
   - `pr_acquire` then ends in `FAIL undo still left` (`prov-254.sh:213`), so step 1 fails whenever the dead run left the
     node on B. Examples: UD1 after its commit; a held trial whose deadline has not passed.
   - A trial with hold reverts by itself at its deadline; a committed B does not.
   - Fix: step 0 = if `batman-slot active` is B (trial or committed), run `back_to_a`, or wait for a held trial's revert.
     Only then run step 1.
3. **A failed step 1 leaves a live lease and an armed deadman.** In `pr_acquire 3600 && pl release`, a FAIL (e.g. item
   2) skips `pl release`.
   - Step 1's deadman then fires up to an hour later. It runs segment 1 (unbind-all, helper / provd back to release,
     kill-pg) and, without a `restoring` marker of **its own** run, restarts provd, the radio, joinwatch and openmanetd
     (`prov-lease-254.sh:44-80`).
   - That can happen in the middle of step 2's `pr_restore`. It is exactly the "second writer on a half-restored node"
     the deadman's own comments guard against.
   - Its lease also blocks step 2's `pl acquire` until it fires: "another BLE test (run X) holds the lease"
     (`ble-lib-254.sh:302-307`).
   - Fix: `pr_acquire 3600; r=$?; pl release; [ $r = 0 ] || exit 1`.
4. **Host death without a node reboot (same boot).** The dead run's lease and deadman are still live until its budget +
   5 s, up to about 2 h for the trial arm. Until then, step 1's `pl acquire` dies with "holds the lease until uptime N"
   (`ble-lib-254.sh:305`). If the deadman refused to clear tryboot, the lease is kept and only `ble-recover` frees it
   (`:179-181, 307`). Fix: step 0 also checks `RUN_ID=x sh prov-lease-254.sh state` and says what to wait for or run.
   Note that in this case the dead run's own deadman replays its journal, so step 1 may find nothing (that is fine).
5. **Spurious FAIL at the end of step 2.** `pr_release` FAILs when `ble-dm-254.log` has more `run=$RUN prov deadman`
   lines than `PR_DM_BASE` (`prov-254.sh:569-571`). With `RUN=$DEAD`, the dead run's own deadman lines (item 4) are
   counted. Fix: set `PR_DM_BASE` to the current count before `pr_release`, and say why.
6. **Stale host lock.** After a host crash, `pr_lock` exits with "a stale lock … `rm -rf '$LOCKD'`" (`:183-187`). This
   one is self-describing, but list it as step 0 so the person is not surprised.

**Proof.** The design marks the sequence "⚠️ not run as a whole". Add an offline dry run with the stubbed `q` / `qr` /
`nb` / `pl` used by the abort tests (§4.2). It checks:
- the order back_to_a → replay → release → restore → brewrite → finish;
- that `PR_WROTE_B` is 1 inside `pr_restore`;
- that a failed step 1 still releases.

It runs for a node on A and for a node on B committed.

### MINOR

1. **Cut sub-arm: p3 read failure.** If the stream `dd` exits between p2 and p3 (the stream finished), the `fdinfo` read
   fails. Specify that a failed or empty p3 read → `UD9-MISS late`, no cut. An unset variable compared with `-lt`
   must not fall through to `echo b`. Add a stub case.
2. **`ssid-restore` round trip: encode on the node.** `q()` / `qr()` pipe through `tr -d '\r'`
   (`prov-254.sh:62-63`). An S0 ssid carried raw to the host and encoded there would lose a CR byte, which the rule
   allows. Encode with `hexdump -v -e '1/1 "%02x"'` on the node (present, E-UD1 #13b), and run the round-trip compare
   on the node too.
3. **UD4 record format.** With `CONFIG_PSTORE_COMPRESS=y` (E-UD2), a record that pstore could not decompress appears as
   `dmesg-ramoops-N.enc.z`. Grepping it for `Unable to mount root` fails, and v5 calls that "FAIL with the record
   attached". Make a `.enc.z` record INVALID "record not readable"; only a decompressed record without the text is a
   FAIL.

---

## 3. Verdict: **APPROVE-WITH-CHANGES**

0 BLOCKER, 1 MAJOR, 3 MINOR.
- My v4 M1 is withdrawn: it rested on a stale doc, and E-UD2 overturns it.
- Every other v4 finding of both reviewers is fixed in source terms, and the v5 changes to the watcher and to
  `ssid-restore` are sound.
- M1 concerns only §7.1, the manual recovery text that P9 will print to a person. As written it skips the B rewrite
  (`PR_WROTE_B` overwritten), fails for a node left on B, and can leave an armed deadman over the restore.
- Fix the commands and add the offline dry run before that text ships. The test design itself needs no change.
