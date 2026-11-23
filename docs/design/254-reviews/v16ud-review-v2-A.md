# Review v2 — reviewer A — `docs/design/254-v16-ud.md` v2 (commit 89b06a7)

Whole document re-read, then every fix checked against source myself. Read-only; no node, no ssh, nothing committed.

## 1. v1 findings — are they really fixed?

| v1 finding | Status in v2 | Checked against |
|---|---|---|
| A B1 reason at key 1 | fixed (§3.1, §9-1/2, device flip) | `node.go:75-81`; `main.go:652` reads key 1 (ssh-keys) |
| A B2 uncommitted uci | fixed: commits + undo; p5 writers listed (§5) | `batman-config-save:143-146, 462-468, 486-497`; `status.go:64-85, 134-144`; `joinwatch:155-164` |
| A B3 generator order | fixed (§3.3 shared repack, listing acceptance, `tar -C .` negative) | `updwork.go:454-467`; `build-ab-payload.sh:90`; `signrel.py:68` |
| A M1 UD10 | fixed: 0+23 → re-check → 3, no worker; UD10b 23/23 + apply 15 | `updwork.go:878-882, 905-917, 693-705` |
| A M2 observability | fixed: `sha=` / `version=`; `bulk-open X` / `bulk-open Y` probes; second arm status phase 1 | `updwork.go:860-882`; `bulk.go:63-66` |
| A M3 reason-11 discrimination | fixed: why-string rule; UD8 (4) = directory entry | `updwork.go:524-547` (members = list + 4 for V; one more dir entry trips the bound at `root.squashfs`) |
| A M4 guards | fixed (§2), probes included | `slot-guard-254.sh:46-69` (`release_guarded` exists) |
| A M5 UD9 | resolved differently (position watcher), reasoning sound — see m10 for one unproven premise | `batman-slot:406-411, 717, 760-771, 856`; `provstore/exec.go:93`; no `RemoveAll(WorkDir)` at helper start (only `updwork.go:225, 280`), so the orphan keeps its payload dir |
| A M6 UD1 race | fixed (hold + `release_guarded … wait`) | `batman-autocommit:160-185` |
| A M7 negative control | fixed (flip + out-of-tree module; E-UD1 strictly read-only) | — (see m7) |
| A M8 AP | fixed in principle (Q6, §4.3) — see m4, m5 | `settingsset.go:136-151`; `halow-setkey:261-322` |
| A m1–m12 | all addressed | spot-checked: UD1-in-trial reason 1 is reachable (`batman-slot:616-617` rc 10 precedes the p5 gate; PreSave returns in a trial, `status.go:135`); `--unsafe-serial`, `--size-of` |
| B BLOCKER-1 `update-last` | fixed (`STATEFILES` + `PR_UST0` compare + offline negative) | `prov-base-254.sh:36` |
| B M7 abort | fixed; trial abort already handled by `pr_restore_cycle` → `back_to_a` | `prov-254.sh:462-466, 575-584` |
| B M8 P9 / journal / dead-man | journal + budgets fixed; the P9 additions introduce a new problem → **M2** | `prov-undo-lib-254.sh:59-75, 106-145` |
| B m1–m11 | addressed | — |

Row assertions re-traced and correct: UD7 why strings (`release.go` Verify: "S: does not verify against the endorsed key" for both `--bad-sig` and `--key other`; "E: payload is not {1: K 65 B, 2: serial >= 1}"; "S: version unparsable"; `update.go:313`, `Decide` texts); UD13 (a)/(b) and UD6 (b) mechanics (REJECTED → `unpersistable` → `batman-slot:582` rc 12 → 17; prose in the stale list keeps `onlyP3Stale` false; worker's precheck is before `begin_write`, `batman-slot:849-853`); UD20c both arms (`update.go:279-282, 362-366`); UD20 neg `code=3` "owner-op signature / nonce"; UD8b; UD10b (`verified` carries the old boot id); UD2/UD4/UD5 (bad-slot only on non-tryboot boots, `batman-autocommit:400`; cleared `:622`; restored by `STATEFILES`).

No BLOCKER remains.

---

## 2. Findings

### MAJOR

**M1. The capability line "every op prints `PROVCLIENT caps=…` first" breaks the upload and an existing unit.**
- Scenario. (a) §1.1 step 4 says the upload's first output line must be `471`, else INVALID; with the caps line printed
  first by the `exec` op, every upload is INVALID. (b) The `proxy` op uses stdout as its data channel, one hex line per
  packet (`tests/tools/provclient/proxy.go:1-40`); `prov-provd-wbox-254.sh:61` drives `provclient node sock-as … -- proxy`
  and decodes every line. A caps line there is read as a packet.
- Evidence. `main.go:540-565` (`proxy` and `exec` run after `dropTo`, inside `cmdNode`); `proxy.go`.
- Fix. Print the caps line on **stderr**, or only for ops that talk to the helper socket (not `exec`, `proxy`, `sign`).
  Add an offline test: `exec /bin/echo x` stdout is exactly `x`; a proxy round-trip is byte-identical.

**M2. The P9 additions are fleet-wide preflight changes that will FAIL healthy nodes and other units.**
- Scenario. `prov-p9-254.sh` runs on every bcm2711 node in `scripts/dv-preflight.sh:100-107`, as well as in every
  prov unit's `pr_begin`. Each new line is a FAIL:
  - `batman-config-save --check` rc ≠ 0. rc 8 (lock busy, `batman-config-save:263`) happens whenever joinwatch's 15 s
    `--on-join` is saving. rc 3 means "not applicable" (no p5, bypass). rc 5 happens on any node with a pending real
    change.
  - `update-last` exists. After any real app OTA it stays until the next prepare ("保留到下一次 `update.prepare`
    覆寫", `254-p3-impl.md:400`). No product command removes it, so the "restore command" in the FAIL line would be a
    hand edit of product state.
  - Inactive slot `bad=1`. This is the normal product state after a failed or cut OTA (P3 row 9).
  - `uci changes` non-empty. Anyone may have staged changes.
- Evidence. `dv-preflight.sh:104-107`; P9 is described as "what an earlier prov run may have left behind"
  (`prov-p9-254.sh:2-3`). These conditions can be legitimate product states.
- Fix. Either keep these checks unit-local (`prov-update-254`'s `pr_begin`, FAIL there), or make them FAIL in P9 only
  when the prov dirty flag / run marker shows a prov run left them, and WARN otherwise. Retry once on `--check` rc 8.
  State the impact on other units and on preflight, and run the P9 fixtures for the WARN cases too.

**M3. Q11: `openmanetd.config.roipconfigured` has a second writer and a reboot-deciding reader that the design does not list.**
- Scenario.
  - openmanetd itself writes this key and reboots on it: 202 close-out T5 says openmanetd flips `dhcpconfigured` /
    `roipconfigured`, changes `ahwlan.ipaddr`, then reboots (`docs/design/202-config-survival-closeout.md:18, 59`).
  - Its two-stage address reservation is gated by `dhcpconfigured=1` + `roipconfigured`
    (`docs/design/p5-config-partition.md:40`, N-R3: "must suppress the two-stage reboot").
  - So "not read by joinwatch / halow-status / meshpoint (grep)" misses the main consumer, which is outside this tree.
- Two failure paths are not in §7:
  1. **openmanetd restart during the window.** A restart while `"0'q"` is committed may re-address and reboot 04 in
     the middle of an arm. Triggers in-tree: `batman-addr-defer reconcile` `start`s openmanetd from joinwatch every
     tick on a committed boot that still carries the deferral (`joinwatch:142-144`). Out of tree: any reload trigger
     in `/etc/init.d/openmanetd`.
  2. **Node reboot before the undo runs.** Examples: host death, or power loss with no executor. openmanetd then
     boots with the bad value. P9 only notices afterwards (and see M2).
- Owner's provisional "yes" is not supported by evidence yet.
- Fix.
  - E-UD1 (read-only) must establish: `/etc/init.d/openmanetd` reload triggers; whether openmanetd ever re-reads or
    writes the key at runtime (the shipped binary or its source for the image's version); and the deferral state on 04.
  - Bound the window (commit → check → restore, seconds) and say that no reboot or reload can happen inside it.
  - Add the two lifecycle rows. Add `openmanetd` to the §5 writers of `/etc/config/openmanetd`.
  - If the evidence shows openmanetd reacts at runtime, choose another PRESERVE key with all readers in-tree. Show the
    grep of its readers in the same way.

### MINOR

1. **`update.check` EBusy from the config-save lock right after a commit.** After the UD13 (a)/(b) commits, joinwatch's
   next `--on-join` does a real save (`joinwatch:164`). A check that overlaps it gets `--check` rc 8 → precheck-node
   rc 14 → `code=7` "batman-slot busy (…)" (`update.go:328-329`; `batman-slot:578`). The contract table treats any
   code ≠ 0 as FAIL. Retry once after 20 s when the why names config-save, then INVALID. The worker path already
   retries rc 14 (`updwork.go:403-411`).
2. **UD9 watcher lifetime.** The kill and cut sub-arms both run `batman-slot write`. A watcher left over from a missed
   sub-arm would match the next sub-arm's `dd` and fire the wrong action (kill vs sysrq) on a run it was not started
   for. Make it one-shot and bounded (exit at its deadline or once the worker leaves phase 2). Accept only a `dd`
   younger than the watcher (`/proc/<dd>/stat` starttime). Register a `kill-pg` undo, and kill it in the trap.
3. **Q10 reserve.** If the cut sub-arm falls back to `write-hang`, the row proves "after `begin_write`, nothing
   streamed", not mid-stream. The result line must say so. The kill sub-arm has no reserve, so two INVALIDs there leave
   UD9 kill uncovered; §11 should say that.
4. **ap-on's FD3 snippet relies on node tools not shown to exist.** `base64` (busybox applet, not always built) and a
   **builtin** `printf`. If `printf` is an external applet, the passphrase sits in
   `/proc/<pid>/cmdline`, which every local process can see, for the duration — exactly what P3 tests against (`254-p3-impl.md:729`). Add to E-UD1:
   `type printf` = builtin, `command -v base64`. Alternatively, generate the passphrase with a builtin-only loop over
   `/dev/urandom` via `hexdump`. hexdump is an applet, but the secret is on its stdout, not its argv.
5. **The new AP passphrase lands in p6.** UD13 (a)'s `uci-restore wireless` export is taken *after* ap-on, so the
   journal file `uci.wireless.<id>` on p6 holds the random AP passphrase. The export for ap-on holds the old one. §4.3
   and §8 mention only the latter. State both: root 0600, deleted with the journal, never printed.
6. **Q9.** Agree: a #254 checklist line is enough for the `pw=` prefixes. `genPassword` gives 24 random characters
   (`node.go:463-473`), so a 64-bit sha prefix is not a usable verifier. Add `prov-settings-254.sh:27`'s
   `ap_key_sha=` (16-hex prefix of the **human-chosen** AP key, printed to the log) to that same line; it is the v1 m9
   class.
7. **The device flip needs the old binary kept.** `pr_pc_place` places one `$TOOLS/provclient-arm64`
   (`prov-254.sh:793-800`). Say where the pinned old binary lives (its own file + SHA256SUMS entry) and how `pr_pc`
   selects it.
8. **The generic acceptance contradicts two generators.** "Equals V's listing except one named delta" plus the negative
   "V unchanged → FAIL (no delta)" gives `mutate` and `malicious 3` a listing delta of zero. They differ in content and
   trailing bytes, not in the listing. Define the delta per generator (listing / content sha / trailing length). Also
   the FEXTRA arithmetic: the field costs 2 B + data, so a gap of 1 B cannot be filled. The valid range is g = 0 or
   2 ≤ g ≤ 65 537, not "0 ≤ g ≤ 65 531".
9. **`write-arm` UD6 (b) why text.** The worker's why is `batman-slot write rc 12: ` + the **last line of stderr**
   (`updwork.go:415-417`). The "forbidden characters" text is the `die_c 12` message (`batman-slot:582`). Confirm it is
   the last stderr line (no `warn` after it in `precheck`). Otherwise match on the line set, not the last line. The
   same applies to UD13 (b) (`update.go:331` `lastLineOf(out)`).
10. **UD9 watcher premise without evidence.** It reads `/proc/<dd>/fdinfo/1` and assumes busybox `dd` moves `of=` onto
    fd 1 and that `pos:` advances per write on a block device. That is plausible (busybox `dd` uses
    `xmove_fd(…, ofd=STDOUT_FILENO)`) but not cited. Prove it in E-UD1 with a harmless
    `dd if=/dev/zero of=/tmp/run/batman-dv/x bs=1M count=64` plus a concurrent fdinfo read, or cite the shipped
    busybox source. Otherwise every kill and cut run is `UD9-MISS`.

---

## 3. Owner's provisional answers

| Q | Verdict |
|---|---|
| Q9 | Agree (m6), and add `ap_key_sha` to the same checklist line. |
| Q10 | Agree, with the result labelled as the weaker point (m3). |
| Q11 | Not yet: evidence about openmanetd first (M3). |

## 4. Verdict: **APPROVE-WITH-CHANGES**

0 BLOCKER, 3 MAJOR, 10 MINOR. The v1 BLOCKERs and MAJORs (both reviewers) are fixed and check out against source. The
three new MAJORs are local fixes:
- provclient output channel (M1);
- P9 scope (M2);
- the UD13 / UD6 key's openmanetd evidence (M3).

Under the owner's rule they must be fixed and the whole document reviewed again before implementation.
