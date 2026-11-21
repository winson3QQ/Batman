# Review A — `254-v16-group1.md` draft v1 (2026-11-21)

Reviewer A, independent. Reviewed the whole document against the worktree `C:/src/Batman-g1` (branch
`fix/254-v16-group1`, HEAD 4b61b3c = main). Read-only; no node access. Every claim below cites source I read; device
facts I could not check are listed as read-only probes.

**Verdict: REJECT (v1).** One BLOCKER (§4) and five MAJORs. §1, §3, §5, §6 and §7 are close to approvable once the
findings below are fixed; §4 should leave this group.

---

## BLOCKER

### B1. §4 breaks the existing validation suite, has no field trigger, and can split a mixed-version fleet

- **Scenario.** After §4, any `network/join` / `network/update` whose net_config key 3 differs from the regdb bandwidth
  of its channel is refused with `EBadObject "bandwidth"`.
- **Evidence.**
  - Every harness unit that joins or updates builds net_config with a hard-coded `bw=2` and the node's **live**
    channel: `scripts/dv/prov-netjoin-254.sh:23`, `prov-netupdate-254.sh:36`, `prov-254.sh:847`,
    `prov-powerloss-254.sh:51`, `prov-leave-after-join-254.sh:44`, `prov-leave-ota-254.sh:17`,
    `prov-downgrade-left-254.sh:37`, `prov-country-join-254.sh:31`, `prov-netjoin-fleet-254.sh:24`,
    `prov-bench-s0-254.sh:470`. The image default channel is 40 (`deploy/provisioning/meshpoint-1.8.0.sh:29`), which is
    4 MHz (`halow-setkey:34`, and the design's own probe "channel 40 = 4 MHz"). On a ch40 node these units would all be
    refused. The design's claim "existing join / update DV units pass (the app's values match)" is false. The app is
    not the only producer: provclient + harness is a second one, and the design does not list it.
  - No field trigger. The node never uses key 3. `halow-setkey` derives the bandwidth from the channel
    (`halow-setkey:113-118`), and the app says the same (`joinflow.rs:22`, "the bandwidth … follows from the
    channel"). A mismatched key 3 changes nothing on the air today, so there is no "silent mismatch" harm to stop.
    Per the owner's rule ("scope comes from the field"), there is no actor that produces this case.
  - Mixed-version fleet. An update that an old member accepts and a new member refuses leaves the members on different
    net versions. If that update changes the key, mesh id or channel, the result is a mesh partition. A check that
    refuses a field which does not change behaviour turns a cosmetic inconsistency into an availability failure.
  - The contract is undefined. `Sys.ChannelBW` would parse a human echo line (`halow-setkey:118`) that has never been
    an interface. `--check-only` rc 2 (illegal channel, unset country, missing regdb: `halow-setkey:109-115`) is not
    mapped (the design names only "exec failure → EApply").
  - #255 rewrites join / net_config handling (the design says so). This is the one section that is certainly thrown
    away or redone.
- **Fix.** Drop §4 from group 1 and put one line in the #255 checklist ("validate halow key 3 against the channel, or
  remove it from the CDDL"). If the owner wants it now anyway, then all of the following are needed: log-only (WARN)
  rather than refusal; harness `bw=` fixed to the channel's value in the harness PR; a machine-readable bandwidth
  source (not the echo line) with a stated rc 2 mapping; and a mixed-version analysis.

---

## MAJOR

### M1. §2: the background retry bypasses the "no wireless change during an OTA" rule

- **Scenario.** The boot Finish fails. Twenty minutes later the owner starts an OTA upload (the 126 MB upload window),
  or `batman-slot` is writing the other slot. The retry fires, `finish()` runs `SetKeyNoPersist` (a wifi reload), and
  the reload cuts the upload or the mesh in the middle of the OTA.
- **Evidence.**
  - Verbs are refused while `n.otaBusy()` (`node/node.go:259-265`). `otaBusy` covers the upload window and the slot
    flock (`node/wtxn.go:457-463`).
  - `finish()` itself has no such check (`wtxn.go:293-366`), and the retry calls `n.finish` directly (design §2
    bullet 2).
  - Today this bypass cannot be reached: `BootFinish` runs before `Listen` (`main.go:696-699`), so no upload window
    can be open yet. The retry makes it reachable.
  - The comment at `node.go:259-262` explains why the rule exists: a change failing during an OTA leaves a `.txn` the
    new slot never sees.
- **Fix.** Before each try (under `n.mu`): if `n.otaBusy()` or `n.Sys.IsTrial()`, skip without counting the try and
  re-check after a short delay. Add a unit test: upload window open → no Finish runs. Negative control: the test fails
  without the check. Add the row to the lifecycle table.

### M2. §2: the retries hold the helper mutex for long stretches and change the verbs' backoff

- **Scenario.** HaLow is dead (the case in `254-wireless-txn.md:143`), so every Finish fails slowly.
  - Each attempt holds `n.mu` for up to ≈ 11 min: setkey 300 s (+20) plus save 300 s (+20), from
    `254-wireless-txn.md:92-93`. The retry has no radio wait.
  - Twelve attempts can therefore hold the mutex for a large part of the ≈ 3.5 h window.
  - `owner.add` / `owner.remove` are meant to "always work, even with a dead radio" (`254-wireless-txn.md:68-71`, 143).
    Behind a background attempt they now wait minutes, for example when the owner urgently removes a co-owner from
    the phone app.
  - A second effect: retry failures feed the shared `finishFails`, so `backoff()` reaches 30 min
    (`wtxn.go:373-382`). If the cause clears just after a failed retry, a saving verb gets `EState 22` for up to
    30 min (`wtxn.go:394-397`). Today the same verb would get an immediate, successful Finish whenever the count is
    still low.
- **Evidence.** As cited above. The design's lifecycle table has no "dead radio" row and no statement of the worst-case
  mutex hold.
- **Fix.**
  - Retry only the failure classes that a retry can actually cure: setkey rc 2 (settle / lock busy, fast), a transient
    `CheckRestorable`, and a p5 read / save error. Do not retry rc 3 or a timeout (dead radio): there the next verb or
    boot stays the exit, as today.
  - Either keep the retry's failures out of the verb backoff, or state the 30-min `EState` window as an accepted
    regression.
  - State the worst-case mutex hold in the design.
  - Add unit tests: (e) a dead-radio failure → no retry scheduled; (f) after N retry failures, a verb arriving after
    the cause cleared is not blocked longer than today.

### M3. §1: wrong Pi 3 evidence, and no Pi 3 in the lifecycle or the delivery

- **Scenario.** On a Pi 3, §1 changes disarm behaviour: an unacknowledged GET now dies instead of reading as
  "cleared". If the pinned bcm2710 firmware printed word 5 differently, every Pi 3 OTA would be refused.
- **Evidence.**
  - The design says "Pi 3 firmware answers the tag (chain1 DV prints word 5 `0x80000004` on 04)". manet04 is a Pi 4;
    the only Pi 3 is manet03 (`docs/boards-and-builds.md:13-14`).
  - The real Pi 3 evidence is indirect. `209-ab-on-pi3.md:17` shows the GET read back 1→0 on a Pi 3, which implies the
    tag is handled, but the raw line with word 5 was not captured.
  - The Pi 4 raw line does exist ("… 0x80000004 0x00000000" on 04 / 02, `scripts/dv/slot-guard-254.sh:31`,
    `test-slot-guard-254.sh:48`).
  - §8 builds only `ekh-bcm2711` and runs only 04 and 02.
- **Fix.**
  - Before approval, run the read-only probe on manet03: `vcmailbox 0x00030064 4 4 0` (GET only, no SET). Attach the
    raw line.
  - Add a Pi 3 row to the §1 lifecycle.
  - In §8, either build bcm2710 and run the A/B DV on 03, or state "Pi 3: not run" in ⚠️ together with the captured
    line.

### M4. §3: the DRY isolation list is incomplete, and the harness claim is wrong

- **Scenario.** A dry run (run by the bench, possibly during a real trial in the same boot) still writes real state.
- **Evidence.** These writes are not in the design's list:
  - `autocommit.canary-ok` (`CANARY_LATCH`, `batman-autocommit:449`, written at its loop line ~490). A real run in
    the same boot skips the pre-commit canary when the latch exists. That is safety relevant.
  - `autocommit.warn-*` (`:448`) and `autocommit.ble-warned` (~`:536`).
  - `otalog` / `otalog_k` into the real OTA flight recorder: `AC START` `:431`, `HOLD-CONSUMED` `:103`,
    `UNHEALTHY` / `HELD`, and so on. `ACLOG` is diverted in DRY (`:44`, "a dry run must not show up as LAST OTA"),
    but the OTA trace is not.

  `held()` also writes the real `$HOLDC` in DRY (`:100`). The design lists that one, and it is the worst: a real
  watchdog in the same boot then stands down.

  The harness claim is wrong. `scripts/node/prov-misc-254.sh:83` plants the **real**
  `$RUNDIR/autocommit.hold-consumed` to make the DRY watchdog stand down. After the rename, the DRY run reads
  `.hold-consumed.dry`, so the plant no longer works, and the plant itself is the kind of "real" write §3 removes.
  "Harness units … keep working" is unverified and, for this unit, wrong.
- **Fix.**
  - Derive every run-dir name from one DRY-aware prefix variable instead of a hand list.
  - In DRY, route `otalog` / `otalog_k` to the dry-run log or drop them.
  - Change `prov-misc-254 start` to plant the `.dry` name (harness PR).
  - Make the offline test snapshot the run dir and `$ST` before and after a DRY + FORCE_TRIAL + TIMEOUT=1 run. The
    only difference allowed is `*.dry` entries plus `autocommit-dryrun.log`, and no new `ota-trace.log` lines.
    Negative control: the test fails on main.

### M5. Process: §2 and §4 have no reproduction on the real system before the fix

- **Evidence.**
  - L111 (§2) cites `254-wireless-txn.md:661` (a statement in the design text) and "e.g. setkey rc 2 on a slow boot".
    No captured stuck `.txn` from a node is attached. The reproduction (the wsl.34 negative) is scheduled after
    implementation.
  - L18 (§4) has no trigger at all (B1).
  - The owner's rule: the reproduction comes before the design and becomes the negative control.
- **Fix.** Run the §2 DV negative on the current bench image now: block setkey's settle once, cut at txn-2, boot,
  then show `.txn` is still present after 5 min. Attach the output to the design as the reproduction. Record §1 as
  "not reproducible on supported firmware (defensive, fail-closed)" with the probe outputs.

---

## MINOR

1. **§1 rationale is factually wrong.** bootfacts.sh **is** in the stage-2 ramfs (`RAMFS_COPY_DATA`,
   `platform-ab.sh:42`) and is sourced at `platform-ab.sh:50`. Keeping the checks inline is still acceptable, but the
   predicate would then exist four times: `bf_get`, disarm, arm, and `slot-guard-254.sh:33`. Add one offline test
   that feeds the same vectors to all four, or source bootfacts in batman-slot.
2. **§1 table gaps.**
   - Missing harness callers whose behaviour changes: `scripts/dv/chain1-254.sh:151` and `fresh-254.sh:136`
     (unacknowledged → `unknown` → "needs a person").
   - `otatrace.sh:40` `ota_get` (raw word 6, log only) is unchanged; say so.
   - The arm path with code ≠ `0x80000000` (Pi 4 "armed blind", `batman-slot:788-789`) is unchanged; state the three
     classes explicitly.
   - Missing upgrade row: the stage 2 of the OTA that **installs** the fix runs the old image's bootfacts (ramfs copy
     of the running system), so the fix takes effect from the following OTA.
3. **§2 arithmetic and coverage.**
   - Twelve tries have 11 waits: 60+120+240+480+960+1800×6 = 12 660 s ≈ 3.5 h, not ≈ 4 h. Say whether the boot
     attempt counts as try 1 (test (b) depends on it).
   - The retry does not cover the boot where `BootFinish` is skipped (`!res.P5Read` or an unknown verdict,
     `main.go:696`); the "node nobody talks to" case also occurs there. State it.
4. **§2 lifecycle: clean stop / restart.** SIGTERM is `os.Exit(0)` (`main.go:713`), which can land mid-try. An
   abandoned setkey child keeps running and holds `halow-setkey.lock`, the same as for a verb today. Add the row.
5. **§5 lint scope.** `feed/batman-payload-host/Makefile` has 2 more `INSTALL_BIN` sources at 100644; across all feeds
   main has 39, not 37. Either scope the lint to `feed/batman-provision` explicitly or fix all 39. Otherwise the lint
   still fails after this PR.
6. **§6 details.**
   - A4 m5: `chi2.isf(1e-6, 55)` = 119.90 (scipy), not ≈ 119.0. Use 119.9.
   - A4 m8: the comment is at `provstore/exec_dstate_test.go:20`, not `:21`.
   - Verified correct: A4 m1 (`main.go:92-94, 125, 233-235`), B4 m2 (`:109-111`), B4 m7 (`batman-slot:537` hint;
     markers removed only by `RemoveMeshMarkers`, `main.go:442`), A4 m3 (`wtxn.go:331` rc 3 only).
7. **#255 overlap is understated.** §2 changes the Finish of the join / leave transaction, which #255's join / leave
   rewrite may restructure. State "kept or replaced by #255" for §2 too. §2 is the minimum only if M2's narrowing is
   applied.
8. **Security sections are thin.**
   - §2 should show the negative test that an unauthenticated peer gains no extra setkey / p5 writes (a verb inside
     the retry's backoff still gets `EState`; this is test (d) extended).
   - §1 and §3: one sentence per actor is enough (root-only inputs: the firmware mailbox, a DRY env set by root), but
     state it.

---

## Read-only probes requested (not run by this reviewer)

- manet03 (Pi 3): `vcmailbox 0x00030064 4 4 0` → raw line (word 5 expected `0x80000004`).
- manet02 / manet04: the same, on the current bench image (re-confirms `trybootget-209.log`).
- Bench nodes: `uci -q get wireless.radio1.channel` → shows whether the harness `bw=2` mismatches today (B1).

## Summary table

| # | Sev | Section | One line |
|---|---|---|---|
| B1 | BLOCKER | §4 | harness sends bw=2 on ch40 → DV join/update refused; no field trigger; mixed-version partition; undefined ChannelBW contract → drop to #255 |
| M1 | MAJOR | §2 | retry bypasses `otaBusy` (node.go:263) → wifi reload during upload/slot write |
| M2 | MAJOR | §2 | ≈11 min mutex per try × 12 blocks owner.add/remove on dead radio; shared backoff → 30 min EState after recovery |
| M3 | MAJOR | §1 | Pi 3 evidence cites 04 (a Pi 4); no Pi 3 capture/lifecycle/DV |
| M4 | MAJOR | §3 | DRY still writes canary-ok/warn-*/ble-warned + real OTA trace; prov-misc-254 real hold-consumed plant breaks |
| M5 | MAJOR | process | §2/§4 not reproduced on the real system before the fix |
| m1–m8 | MINOR | various | wrong ramfs rationale; §1 caller/upgrade rows; §2 arithmetic & skipped-BootFinish; SIGTERM row; lint scope 39; chi² 119.9; #255 overlap; thin security |
