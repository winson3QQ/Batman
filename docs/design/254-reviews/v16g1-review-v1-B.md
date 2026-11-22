# Review B — `254-v16-group1.md` draft v1 (2026-11-21)

Reviewer B, independent adversarial design review. Scope: the whole document, checked against the worktree
`C:/src/Batman-g1` (branch `fix/254-v16-group1`, HEAD `4b61b3c`, same as main). Read-only; no node was touched.
Probes I could not run are listed as exact read-only commands.

**Verdict: REJECT (revise to v2).** One BLOCKER (§4 breaks every join/update DV unit and every bench network) and
five MAJORs. §1, §2, §3, §5 and §6 are sound in direction and should survive with the changes below; §4 should
shrink or go to #255.

---

## What I checked first (field paths, missing resources)

- Field paths walked: first boot, slow boot with netifd still busy, helper respawn, clean stop / `batman-slot reboot`,
  OTA stage 1 / stage 2 (ramfs), trial + autocommit, the operator override `allow-unfinished-txn`, power loss, the
  owner's phone app doing join / update, the bench harness (provclient, DRY runs), Pi 3 (bcm2710) A/B.
- Resources the document does not name: the slot flock / `otaBusy()` (§2), the stage-2 ramfs copy of `batman-slot` and
  `platform-ab.sh` (§1 upgrade path), `autocommit.canary-ok` / `autocommit.hold-discarded` / `autocommit.ble-warned`
  and `scripts/rundir-paths.txt` (§3), the halow-setkey stdout line as a parsed interface (§4), every stored bench
  net_config (§4), the provclient defaults (§4).

---

## BLOCKER

### B-1 §4 — the bandwidth check refuses every DV join / update and every bench network

**Scenario.** After §4, a `network/join` or `network/update` whose net_config key 3 ≠ the regdb bandwidth of the
channel is refused with `EBadObject "bandwidth"`. The whole DV harness builds net_configs with `bw=2` and the node's
live channel, and the bench nodes run channel 40 (= 4 MHz).

**Evidence.**
- `tests/tools/provclient/net.go:57` default `in := &netInput{bw: 2, country: "TW"}`; `:196` writes it as key 3.
- Every join / update DV unit passes `bw=2` with `channel=$(uci -q get wireless.radio1.channel)`:
  `scripts/dv/prov-254.sh:847`, `prov-netupdate-254.sh:36`, `prov-netjoin-254.sh:23`,
  `prov-netjoin-fleet-254.sh:24`, `prov-powerloss-254.sh:51`, `prov-powerloss-legacyjoin-254.sh:36`,
  `prov-powerloss-rejoin-254.sh:41`, `prov-leave-after-join-254.sh:44`, `prov-leave-ota-254.sh:17`,
  `prov-downgrade-left-254.sh:37`, `prov-country-join-254.sh:31`, `prov-bench-s0-254.sh:470`.
- 04 is on channel 40: `feed/batman-prov/src/node/testdata/halow-status-04-wsl22.json` (`"channel":"40"`);
  `halow-setkey:34` "US: ch40 = 4 MHz".
- The design's own claim (§4 Tests) "Device: existing join/update DV units pass (the app's values match)" is false:
  these units do not use the app.
- Consequence beyond the harness: every network already formed on the bench carries a signed v1 net_config with
  key 3 = 2. Stored records are not re-checked (§4 says so), but a `network/update` of such a network
  (`node.go:1227`, parses the LAST version, which a harness again builds with bw=2) and a new member joining it are
  refused for good. The same would hold in the field for any network whose creator ever disagreed with the node's
  regdb — the net_config is immutable and signed, so the refusal cannot be repaired by the user.

**Fix.** See M-4: drop the equality refusal (or defer it to #255). If an equality check is kept at all, first change
provclient's default and all twelve units to derive bw from the node (`halow-setkey --check-only --channel N`), and
list that harness change plus the "existing bench networks with key 3 = 2" path in the lifecycle. Negative control
must be shown on the real DV units, not on the app's values.

---

## MAJOR

### M-1 §1 — the Pi 3 evidence is a Pi 4 capture; the change can stop every Pi 3 OTA

**Scenario.** §1 makes `arm_tryboot` die on BOTH layouts when word 5 ≠ `0x80000004`, and Pi 3 disarm die. If the Pi 3
firmware (1.20250915, `209-ab-on-pi3.md:22`) answers this tag with any other word 5, every Pi 3 OTA dies at arm.

**Evidence.** §1 Lifecycle: "Pi 3 firmware answers the tag (chain1 DV prints word 5 `0x80000004` on 04)". 04 is a Pi 4
(`halow-status-04-wsl22.json`: `"node":"BCM2711-6c89"`, `last_arm … get=… 0x80000004 0x00000001`). `chain1-254.sh:151`
prints only `bf_get`'s 0/1, not word 5. For the Pi 3 the repo has only "GET 讀回 1→0" (`209-ab-on-pi3.md:17`) — a
read-back of 1 is strong *inference* that the tag is handled, not a capture of word 5. The delivery (§8) has no Pi 3
step at all, although "every supported platform" is a required lifecycle path and `batman-slot` runs on Pi 3.

**Fix.** Capture it before approval. Read-only probe on the Pi 3 bench node:
`tr '\0' ' ' < /proc/device-tree/compatible; vcmailbox 0x00030064 4 4 0; grep 'SLOT ARM' /opt/batdata/log/ota-trace.log | tail -n 1`.
Cite the Pi 4 evidence by the testdata file above instead of chain1. Add an offline test with `layout=pi3` for arm and
disarm, and a Pi 3 row (or a stated, evidenced n/a) in §8.

### M-2 §1/§8 — the planned device run does not execute the new arm / disarm code

**Scenario.** The OTA onto the bench image runs stage 1/2 of the RUNNING (old) slot: `RAMFS_COPY_BIN` copies the
running `/usr/sbin/batman-slot` into the ramfs and stage 2 uses the running `platform-ab.sh`
(`platform-ab.sh:40-50`). So "OTA to 04 then 02" (§8) arms and disarms with main's code; the §1 change is exercised on
hardware only by an OTA *from* the bench image. The upgrade path (first OTA after install = old logic) is also
missing from §1's lifecycle.

**Evidence.** `platform-ab.sh:40` `RAMFS_COPY_BIN='… /usr/sbin/batman-slot …'`, `:42` `RAMFS_COPY_DATA='…
/usr/lib/batman/bootfacts.sh …'`, `:50` sources bootfacts.sh; `ota_s2_explicit_restart_if_not_armed` `:303-325`.

**Fix.** §8: after the bench image is committed, one more OTA from it (bench → bench rebuild or → wsl.34 and back),
recording `SLOT ARM … get=` and `S2 … get=` from `ota-trace.log`; plus one `batman-slot reboot committed` on the bench
image with `SLOT REBOOT mode=explicit` in the trace (K90 path via `bf_get`). State the upgrade row: "the OTA that
installs this is armed by the old code; the change is live from the next OTA".

### M-3 §2 — the retry bypasses the "no wireless change while batman-slot writes" rule

**Scenario.** Verbs refuse a wireless change while `otaBusy()` (`node.go:263-265`, §18.4 / B4 m9,
`TestNoWirelessChangeDuringOTA`). The background retry calls `finish()` directly — `SetKeyNoPersist` / `ForgetMesh`
and `SaveTxn` (p5 write) — without that gate. `.txn` normally blocks an OTA (`batman-slot:543-554`), but the operator
override `allow-unfinished-txn` (`batman-slot:534-538`) runs exactly while `.txn` exists, and any other
`batman-slot` verb (commit, rollback, bootinfo) holds the same flock. A retry then reloads the HaLow radio and writes
p5 in the middle of a slot write / stage 2 — the interleaving the §18.4 rule was added to exclude. Today this cannot
happen (only the boot Finish, before the socket listens, and verbs, which are gated).

**Evidence.** `wtxn.go:420-433` (BootFinish has no gate), `wtxn.go:457-462` (`otaBusy`), `node.go:263`.

**Fix.** Each try: `if n.otaBusy() || n.Sys.IsTrial() { reschedule, do not count }`. Unit test: flock held → no
Finish, retried after release; negative control = the test without the gate.

### M-4 §4 — not shown to be necessary; new refusal path with an undefined parsed-output contract; #255 replaces it

**Scenario / evidence.**
- No field harm is shown. The node never uses key 3: the on-air bandwidth is derived from the channel by the regdb
  on every node (`halow-setkey:113-118`), so a mismatching key 3 changes nothing on the air. The only effect of the
  check is a new refusal that the owner cannot fix (the net_config is signed by the app). That contradicts the
  owner's scope ("nothing here lowers … user experience") and "minimal changes"; #255 rewrites join/leave anyway
  (§0 says §4 is the one item on that path).
- Contract gaps (owner rule 2): `Sys.ChannelBW` parses a human line `channel 40 = 4 MHz @ 922.0 MHz (US)`
  (`halow-setkey:118`) — format, owner, and behaviour on a changed / missing line are not stated; `--check-only`
  rc 2 (country unset, channel illegal, regdb missing: `halow-setkey:109-115`) is neither "exec failure" nor
  "mismatch" — unmapped; a regdb `bw` that is not an integer is unmapped. Today the same rc 2 surfaces as `EApply`
  from `SetKeyNoPersist` (`node.go:1279-1284`); mapping it to `EBadObject` would mislead the app.
- Country: the regdb lookup uses the node's uci country, the app's table is US-only (`joinflow.rs:17-29`).

**Fix.** Minimum that stops a *silent* mismatch: require key 3 present and a uint (CDDL conformance, refuse
otherwise — the app always sends it, `joinflow.rs:150-156`; provclient too) and **log** a WARN line when it differs
from the regdb bandwidth; no refusal, no new exec on the join path. If the owner wants the refusal, put it in #255
with B-1's harness migration and a defined contract (machine-readable output or a documented line regex; rc 2 →
`EApply` as today).

### M-5 §3 — "a dry run touches nothing real" is not true after the change, and the harness claim is unverified

**Scenario / evidence.**
- Other real run-dir names are still written by a DRY run and are not in the list: `autocommit.hold-discarded`
  (`batman-autocommit:290`, shown by `halow-status:151` as real state), `autocommit.canary-ok`
  (`CANARY_LATCH`, `:449`), `autocommit.ble-warned` (`:528-536`). The proposed negative test ("no un-suffixed marker
  created") either misses these or fails.
- The harness workaround the design says "keeps working" changes meaning: `scripts/node/prov-misc-254.sh:83` creates
  the REAL `$RUNDIR/autocommit.hold-consumed` so the DRY watchdog stands down. After §3 the DRY watchdog reads
  `….hold-consumed.dry`, so it no longer stands down (with `AUTOCOMMIT_TIMEOUT=1` it now proceeds to the claim and
  prints `DRYRUN decision: REVERT`), while the harness still plants a real hold-consumed that suppresses a real
  revert for the rest of that boot — the class of hazard L96 is about. `tests/prov-p1/misc-dry.sh:47-53` asserts on
  that real file.
- New run-dir basenames must be added to `scripts/rundir-paths.txt` (#280 N3 lint, `scripts/check-tmp-trust.sh`) and
  `280-tmp-trust.md §11.2`; not mentioned.

**Fix.** Suffix every run-dir name a DRY run can write (one `SFX` variable used for all, including the three above),
or guard those writes with `DRY`. Test: after a DRY+FORCE_TRIAL+TIMEOUT=1 run, `ls $RUNDIR` diff is only `*.dry` /
`autocommit-dryrun.log`, and `ota-armed.mesh` / `autocommit-hold-commit` are unchanged. Harness PR: drop the real
hold-consumed workaround in `prov-misc-254.sh` / `misc-dry.sh` (or move it to `.dry`), and show the units' output
before/after. Update `rundir-paths.txt`.

---

## MINOR

1. **§1 stated reason for inlining is wrong.** "RAMFS_COPY_BIN copies binaries, not the lib" — `bootfacts.sh` IS in
   the ramfs (`platform-ab.sh:42`, sourced `:50`, and by `batman-slot:1006`). Inline still works, but it makes three
   copies of the predicate (bootfacts, batman-slot ×2) plus the harness one (`slot-guard-254.sh:33`). Either source
   the lib in `batman-slot` (missing lib → arm dies, disarm per layout) or keep inline and run one offline test that
   feeds the same vectors to all copies.
2. **§1 arm classification is underspecified.** One predicate `bf_vc_ok` cannot give the table's three outcomes: code
   ≠ `0x80000000` → today's Pi 4 "armed blind" warn (kept?), code ok + word 5 wrong → die on both, ok → value check.
   Write the three branches. Also the text says "reqresp bit 31" but the predicate is an exact string
   `0x80000004`; say which (bit 31 + length ≥ 4 is more robust to a firmware update; exact string matches the
   capture). Our firmware is pinned, so either is acceptable once stated.
3. **§1 other consumers with the same gap**: `scripts/daily-validation.sh:743-753` (`chk_trybootget_209`) checks
   word 2 only — harness PR item. `otatrace.sh:40` `ota_get` prints word 6 blind (logging only; say so).
4. **§2 counting is ambiguous.** "12 tries" — does the boot try count, and does a verb's failed `finishGated` (which
   bumps the shared `finishFails`, `wtxn.go:385-392`) count toward 12 or only stretch the backoff? Pin it in the
   test (b). The ≈4 h arithmetic (60+120+240+480+960+7×1800 s) is right if the boot try is not counted.
5. **§2 lifecycle rows missing**: clean stop (SIGTERM → `os.Exit(0)` at `main.go:706` while a try holds `n.mu` and a
   setkey child runs) and the max mutex hold per try (setkey timeout + config-save timeout) with its effect on a
   phone-app verb that arrives then (state-changing verbs block on `n.mu`, `node.go:237`; read-only ones do not).
   Also state that a try does NOT call `waitRadio` (the pseudo-code implies so; say it).
6. **§2 doc contract**: `254-wireless-txn.md:660-662` (§19.5 "no retry timer") and §4.3 must be updated in the same PR.
7. **§2 #255 survival** is asserted, not argued: Finish is the join/leave transaction that #255 redesigns. One
   sentence on why the retry is kept (generic to any wireless txn) or accepted as throw-away minimum.
8. **§2 field trigger not reproduced.** The premise "setkey rc 2 on a slow boot" is from §19.5 text; no node log of a
   failed boot Finish is cited. Acceptable as a robustness change with an induced fault (the DV plan does that), but
   say it is induced, not observed, and give the read-only probe used to look for it:
   `logread | grep -E 'boot finish|finish \(boot\)'` on 04/02 after a cold boot.
9. **§5 lint scope**: other feeds have the same issue (`feed/batman-payload-host/files/etc/uci-defaults/99-batman-payload-docker`,
   `…/etc/init.d/batman-ots-firstload` are 100644 under INSTALL_BIN). Lint all `feed/*/Makefile`, or state the scope.
   Count 37/41 verified (`git ls-files -s`).
10. **§6 A4 m5 number**: χ² critical value for 55 dof at p = 1e-6 is ≈ 119.9 (scipy `chi2.isf(1e-6,55)`), not 119.0;
    p = 1e-3 is 93.17 (matches the code). Also the A4 m8 path is `provstore/exec_dstate_test.go:21`, not `node/`.
11. **§6 "254-reviews holds only §19 rounds v12–v14"** — it holds `wtxn-review-v12…v14` for wireless-txn; say
    "wtxn-review-*" so the reader does not look for a missing directory.
12. **Ownership / contract tables** are given for §1 and §2 only. §3 (run-dir names are a contract with the harness and
    `halow-status`) and §4 (halow-setkey output) need theirs (see M-4, M-5).

---

## Assumptions I verified (✅) and could not (⚠️)

- ✅ `bf_get` / disarm / arm check word 2 only (`bootfacts.sh:18-24`, `batman-slot:415-425`, `:780-790`).
- ✅ The callers of `bf_get` are exactly K90 (`batman-reboot:38`), stage 2 (`platform-ab.sh:308`), `cmd_reboot`
  (`batman-slot:1010`) in product code; harness: `chain1-254.sh:151`, `fresh-254.sh:136`.
- ✅ Pi 4 word 5 = `0x80000004` for SET and GET (04 testdata, wsl.22).
- ⚠️ Pi 3 word 5 — not captured (M-1).
- ✅ `BootFinish` runs once (`wtxn.go:420-433`); backoff 60 s doubling to 30 min (`:369-392`); helper respawn
  `3600 5 0` (`feed/batman-prov/files/batman-provhelper.init:13`); BootFinish on every start with `.txn`
  (`main.go:696-698`).
- ✅ `.txn` blocks OTA except the override (`batman-slot:543-581`); `update.check` runs `precheck-node`
  (`update.go:317-318`).
- ✅ L96: watchdog `rm -f $ST/ota-armed.mesh` at `:238` before the DRY exit at `:241`; claims real `autocommit.wd`
  (`:200`) and `autocommit.decided` (`:45,83`).
- ✅ `parseNet` ignores halow key 3 (`node.go:1068-1081`); join `:1114`, update `:1227`; stored records go through
  `storedNet` (`wtxn.go:64-98`), not `parseNet`, so "stored records not re-checked" holds structurally.
- ✅ A4 m1: `uciGet` drops rc (`main.go:92-95`), compared at `:125`, empty → `RestoreRefused` (`:233-235`) → Finish
  forgets (`wtxn.go:184-190`).
- ✅ 37 of 41 INSTALL_BIN sources are 100644.

## Security

- §1: input is the firmware mailbox (root, trusted). Removes a fail-open. No new surface. OK.
- §2: no new input; a local unprivileged process cannot trigger tries. With M-3 fixed, the retry adds no state change
  a verb could not make. Bounded wifi reloads (≤ 12) are the availability cost; state it. Negative test: (d) and M-3's.
- §3: `AUTOCOMMIT_DRYRUN` is an env var on a root-only tool; procd never sets it. OK.
- §4: argv exec, no shell; channel is a formatted uint. The real risk is availability (B-1), not injection.
- §5: none.
- Actor "our own mistakes" is the dominant one here: B-1 and M-5 are both "the harness and the node disagree
  silently" — the exact failure class the review rules target.
