# Review of the v4 design set: Reviewer B (feasibility, lifecycle, testing, field use)

Target: `255-608b-config.md` v4 and `255-phase1-impl.md` v2, reviewed together, at commit 594e6dd
(branch `design/255-key-authority`). PR 1 base read from `C:/src/Batman-255pr1` where noted.
Method: read REVIEW.md, both targets, K13–K21, then the source and harness. Earlier reviews and change maps were read
last, only to check whether their findings are closed. Nothing was run on any node.

Counts: **0 BLOCKER / 7 MAJOR / 9 MINOR**.

## Summary

The bench scope, the stateful fake chip, the host-kept claim secret and the resumable burn table close most of the
round-1 and round-3 findings for real, not by rewording. What is still weak is the seam between the chip and the
code that exists today:

- the new boot pre-step and the "lock held for life" do not fit the helper's other duties and CLI modes;
- the identity-cache layout breaks shell checks and DV units that H0 does not touch;
- the harness plan breaks the "one validation set" order and, as written, breaks the v1.6 runs;
- the validation matrix (which image on which node, with which bench) is not stated;
- the experiment rig has no defined OS with `/dev/i2c-1`.

None of these blocks E4 or PR D. Most of them must be settled before PR 2 is written.

## MAJOR

### M1. The chip pre-step and the "lock held for life" do not fit the helper as it is today.

- **Scenario A (boot order).** §2.3 step 1 reads the chip *before* `boot.Run` and loops every 10 s without serving.
  Today `daemon()` runs `boot.Run` first (`main.go:631`), which reconciles overlay and p5, writes this boot's
  `prov-state` verdict (`boot.go:278-304`) and hands the `.txn` result to `BootFinish` (`main.go:703`). It then runs
  `applyState` (`main.go:637`), the health writer (`:656`) and the update / HTTP-firewall ticks (`:686`).
  With a chip that does not answer for a while (a bus glitch, a loose hand-soldered U3), none of this runs. A
  claimed node with an unfinished wireless change stays half-changed until the chip answers. The design says only
  "write log and a `prov-state` line"; it does not say which verdict, nor what happens to reconciliation, `.txn`,
  apply-state and health during the loop. No test covers it.
- **Scenario B (CLI modes).** `batman-provhelper --boot` (`main.go:571-575`) and `--persist-now` (`boot.go:324-350`,
  which calls `identSum`) are separate processes. `batman-slot` tells the operator to run `--persist-now`
  (`batman-slot:575`). §2.3 step 4 defines chip-image `identSum` as "sha list correct **and** `device_id` equals the
  chip's", which needs a chip read. The daemon holds the chip lock for life (§2.2), so `--persist-now` either fails
  or must skip the chip check. The design does not say which. The ownership table names only the daemon and the burn
  mode as chip users.
- **Evidence.** `main.go:566-640, 686, 703`; `boot.go:51-57, 324-350`; `batman-slot:575`.
- **Fix (no new mechanism).** Keep today's order. Use the existing `Env.Generate` seam for rc 7 / 9: in the chip
  image, `Generate(dir)` = "read the chip, write the cache", and a non-answering chip gives `unknown(generate-failed)`
  exactly like today. Compare the cache with the chip at the identity-load step (`main.go:632`), where today's
  `select {}` sits, and make only that step retry. Define `identSum` in the chip image as "cache well-formed" (no
  chip read), so `--boot` and `--persist-now` need no chip. Add the CLI modes to the §6 ownership table as
  chip-free. Add a matrix row and a `se-fail` DV case: claimed node, chip silent at boot, `.txn` present.

### M2. The identity-cache layout breaks shell checks and DV units that no PR plans to change.

- **Scenario.** P3 names the cache files `backend`, `device_id`, `chip_sn`, `cert`. Today:
  - `prov-lock.sh:7, 38-44` requires the 6 file names and exactly 6 lines in `sha256`. `batman-config-save --prov-get`
    then returns rc 13 for a chip cache (`batman-config-save:521-524`), and `--prov-identity` refuses it
    (`:229`, "7 files").
  - `boot.go:247-258` (rc 13) compares the file `sn`. The cache has no `sn`, so every rc 13 freezes as
    `identity-lost`. §2.3 says "same (sn = the chip's device_id)" but does not say the code or the file changes.
  - DV units read the file layout directly: `identity/sn` (`chain1-254.sh:164, 205`, `prov-provd-254.sh:82`,
    `prov-provd-wbox-254.sh:82`, `prov-bench-s0-254.sh:529, 533`), `node.cert` (`prov-overlay-wipe-254.sh:14`,
    `fresh-254.sh:45`), `node.key` (`prov-chain0-254.sh:76`; `prov-sec-254.sh:20-27` and `scripts/node/prov-sec-254.sh:26`
    judge its mode, and the key-perms negative control bind-mounts over it), `claim.secret`
    (`scripts/node/prov-p1-254.sh:39, 64`).
  On a chip node these units FAIL, lose their negative control, or pass for the wrong reason. H0 changes only the
  claim path and the two leak canaries. §4.2 excludes only three units.
- **Fix.** Keep today's names where the meaning is the same: `sn` = device_id hex (as today), `node.cert` = the cert
  copy, `backend`; add only `chip_sn`. Then `boot.go` rc 13 and five DV units need no change. Make
  `prov_ident_ok` / `PROV_IDFILES` depend on `backend` (shell-side change, in PR 2). Give a per-unit table: on a chip
  node, run as is / adapted / not applicable with the reason. `prov-sec-254` key-perms needs a chip equivalent with
  its own negative control (`/dev/i2c-1` mode judged; a 0644 dummy must FAIL).

### M3. The chip-node DV units are placed in product PRs, against the one-validation-set rule.

- **Scenario.** §4.2 puts the real chip-node units (`se-fail` boot / trial / in-service, `/dev/i2c-1` EACCES,
  "never a `node.key`", burn refusals, release-gate checks) into PR 2 and PR 3. The project rule: every harness change
  goes to main in its own PR, before the product PR, with "FAIL on the old product, PASS on the rc" evidence; product
  PRs do not touch `daily-validation.sh` / `scripts/dv/`. Only H0 is planned, and H0 contains none of these units.
  The mutant in §4.2 (wbox patch that reverts the chip image to the file backend) is the right negative control,
  but it has no home.
- **Fix.** Add a second harness PR (H1) after PR D: the chip-node units, the per-unit table from M2, and the wbox
  mutant. H1 merges before PR 2 merges and shows FAIL on the mutant and on the pre-PR-2 product, PASS on the PR 2 rc.
  Name each unit, its node and its tier.

### M4. H0 as written breaks the v1.6 runs, and two of its checks have nothing to check.

- **Scenario.** H0 is "first into main, usable for v1.6 and later". But:
  - §6 says a missing `BATMAN_PROV_BACKEND` = "unknown, preflight refuses". The key is added by the firmware stamp
    change, which comes with PR 2 (§2.8, §9). Every v1.6 image lacks it (`dv-preflight.sh:32` reads only
    `BATMAN_VERSION` today). Once H0 merges, preflight refuses 02 and 04, and the other session's v1.6 validation
    stops.
  - "CI adds `-tags prov_se` (two steps)" before any `prov_se` file exists: the steps compile the same code and pass.
    By the project rule, a check that finds nothing to check must FAIL, not pass.
  - "`check-field-build.sh`: field build has no dev-root public key" before the dev root exists (`se-sign`, PR 2):
    there is no key to look for.
  - The file-node "record" is `claim.secret` copied from the node to the host. Where it is kept, its mode, and when it
    is deleted are not stated. Today the secret never leaves the node except in the QR.
  - H0 changes `provclient` claim behaviour mid-cycle. The other session pulls main before each run. When H0 lands
    relative to the v1.6 final full run is not stated.
- **Fix.** Missing key = `file` (every image without the key predates the chip image); a chip node is identified by
  the node list, and a mismatch with the stamp is refused only when the key is present. Move the `prov_se` CI steps
  and the dev-root check into H1 / PR 2, each with a sentinel that FAILs when no `prov_se` test or no key is found.
  Keep file-node secrets in the run's 0600 scratch directory, deleted at the end. Agree with the v1.6 session that H0
  merges after the v1.6 tag, or before its final full run, and say which.

### M5. The validation matrix and the bench resources are not stated.

- **Scenario.** P2 makes Pi 4 two images (file and chip). Today there are two bench Pi 4 nodes, both busy until v1.6
  ends. The rig has no HaLow (§6: E-series "does not need HaLow"), so it cannot run the mesh part of the suite.
  Consequences the design does not state:
  - PR 2's full validation on a chip node cannot happen until 02 / 04 are converted, after v1.6. §9 only says that
    PR 3 waits.
  - After conversion, if both 02 and 04 are chip nodes, the Pi 4 **file** image (which deployed Pi 4 nodes keep
    using) has no bench. If one of each, every mesh unit runs on a mixed pair, and neither image gets a full
    same-image run.
  - §4.2 drops three units on chip nodes and calls it "coverage loss written into #255". The rule says a cut to the
    full suite is asked first. It is not in §10.
  - Is the chip image a release artifact in phase 1? Field apps reject it, and the scope says dev only. If it is not
    released, the release-gate direction "a chip image's helper must be se" has no present use. If it is released,
    each release needs a full run on it.
- **Fix.** Add a table: image × node × which suite tiers, per PR and per release. State whether the chip image is
  released in phase 1. Put the cut units and the hardware need (a third Pi 4 with HaLow, or a time-shared plan) to
  the user in §10.

### M6. Lifecycle rows that are missing or wrong.

- **(a) App-driven OTA picks the image by board only.** `node/update.go:311-313` compares `r.Board` with
  `BATMAN_BOARD`; both Pi 4 images are `ekh-bcm2711`. A chip node can be offered the file image and the reverse.
  On an A/B card the trial reverts (no `provd-stable`); on a card without A/B the node stays frozen. Not in §7, no
  test. Fix: give the chip image its own board string or a backend field the update check compares; add the row and
  a DV case with a signed wrong-variant payload.
- **(b) Converting an existing file node to a chip node** (Q1: 02 / 04 after v1.6). OTA file → chip freezes (§7),
  so the only way is reflash + burn + reclaim. The steps, what happens to p6 tenants and the app's old owner record,
  and the deployed-role rule ("simulate deployed = sysupgrade only") are not covered. Fix: a row and a short
  procedure.
- **(c) The downgrade row states a wrong fact.** "A pre-#255 image will generate a software identity" holds only
  after a *reflash* (new p5 → rc 7 → `generate`, `boot.go:188-210`). After a *sysupgrade* to a pre-#255 image, p5
  keeps the chip cache: the old `prov_ident_ok` fails (`prov-lock.sh:38-44`), `--prov-get` returns 13
  (`batman-config-save:521-524`), and the old helper freezes as `identity-lost` (`boot.go:247-260`), then the trial
  reverts. So K20 is at risk only on a manual reflash. `prov-downgrade-254` may then run on a chip node as a
  negative test instead of being dropped. Fix the row and Q3; re-check which of the three excluded units really
  must be excluded.
- **(d) Chip retry writes.** §2.3 writes a `prov-state` line on p6 on each failed step 1, and step 1 repeats every
  10 s. That is a steady-state SD write (#104). Fix: write once per state change.

### M7. The experiment rig has no defined OS or image with `/dev/i2c-1`, so E0–E16 cannot start as planned.

- **Scenario.** E0–E16 run on the rig before PR 2 (§9). The kernel modules and `dtparam=i2c_arm=on` arrive with the
  chip image (§2.8), after PR 2 and a firmware-fork PR. Today's images list `kmod-i2c-brcmstb` only
  (`docs/boards-and-builds.md:136`); §11 itself leaves "does today's image have I2C" open. E0 also reads `uci`
  (`batpower`), so it assumes an OpenWrt image. And `se-burn` refuses unless `batman-slot is-trial` returns
  "committed" (rc 1); on a card without A/B it returns 2, which the helper treats as a trial (`trial.go:31-35`), so F1
  cannot burn on a non-A/B rig card.
- **Fix.** State the rig OS. Simplest: Raspberry Pi OS Lite (64-bit) for E1–E16. `se-lab` is a static Go binary
  (`CGO_ENABLED=0`), so it runs there, and the Batman images are untouched. Split E0 into a rig part (bus scan, wake
  pulse vs. the RTC at 0x68) and a Batman-image part done on the chip image before F1. F1 runs on an A/B card with
  the chip image.

## MINOR

1. **Cert validity starts at the burn date** (§3.1). Bench Pis have no RTC yet, so a boot clock can be earlier than
   the burn. If any verifier uses `x509.Verify` with the current time, the node rejects its own cert. Use the fixed
   2020-01-01 start of `DevCert` (`keystore.go:102-104`), or state that no verifier checks time.
2. **`se-burn` / `se-sign` interface.** `se-sign begin` must know the chip serial and the state before it sends a
   secret. Add a read-only `se-burn status` (JSON: state S0–S4, serial) and say what `se-burn` does with stdin when
   the state is not S1.
3. **"Console or `/etc/batman-dev-open`" is not a gate against root over ssh** (root can create the file). Say it is a
   deliberate-step marker, not a security control.
4. **Makefile tags are either / or** (`Makefile:23-30`). The `se-fail` DV units need a `prov_test` + `prov_se`
   (wbox chip) build. §2.8 bans that pair only in shipping images; say the wbox chip image exists, and update
   `build-board.sh --wbox`, `lint-wbox.sh` and the gate.
5. **P1 rationale.** The test builds use `CGO_ENABLED=0` (true: `dv-sbx.sh:69, 80`; `gen.sh:40`), but the product
   helper is built by OpenWrt with cgo external linking (`254-p2-impl.md:590`, captured on 04). This does not affect
   a pure-Go driver; correct the sentence.
6. **`provd-stable` withdrawal** needs its own latch next to `stableWriter.done` (`stable.go:26-50`). Say that a chip
   failure after autocommit has committed is out of scope (the commit stands).
7. **Fake-chip formats are provisional.** Until E1 / E8 / E14 captures exist, the status codes come from
   cryptoauthlib. Mark the PR D vectors provisional and make PR 2 fail if the marker is still there.
8. **`se-lab` module layout.** It shares packet code with `feed/batman-prov/src/se608`, which is a vendored module
   (`GOFLAGS=-mod=vendor`). State how `tools/se-lab` imports it.
9. **No present use:** the "two directions" release gate only matters if the chip image is released (M5). If it is
   not, keep one direction (file image has no `se`, fake, `se-lab`).

## Earlier findings: closed or reworded

| Earlier | Status |
|---|---|
| phase1-B B2 (claim secret source) | Closed in design (host MAC lines). New gaps in M4 |
| phase1-B M3 (boot reconciliation) | Partly. The rc column exists, but the pre-step and the cache layout break it (M1, M2) |
| phase1-B M4 (lifecycle rows) | Mostly closed. (a), (b), (c) of M6 are new or still wrong |
| phase1-B M5 / v3-B M1 (secret loss) | Closed (host-generated, "pending" record, stdin) |
| phase1-B M6 (fake / regular suite) | Fake closed. Regular-suite placement reworded, not closed (M3) |
| phase1-B M9 (inventory) | Reworded ("H0 re-greps"). The DV units that read the layout are still unplanned (M2) |
| phase1-B M10 (flag day) | Closed for PR 3. H0 timing open (M4) |
| v3-B M7 (rig feasibility) | Partly. Chip budget and E14 settled; OS / I2C not (M7) |
| v3-B M2 / M3 (burn contract, slot 8) | Closed |

## Facts in the target that are wrong or unsupported

- §7 downgrade row: a pre-#255 image generates a software identity only after a reflash; after a sysupgrade it
  freezes (M6 c).
- §2.3 rc 13 "same": `boot.go:247-258` compares the file `sn`, which the P3 cache does not have.
- P1 "CGO_ENABLED=0" applies to the test builds, not the product build (MINOR 5).
- §6 "missing `BATMAN_PROV_BACKEND` → preflight refuses" contradicts "H0 usable for v1.6" (M4).
- Checked and correct: `keystore.go:266-267`; `main.go:632-636`; `trial.go:31-35`; `stable.go:30-50`;
  `batman-autocommit:508-512`; `Makefile:23-30`; `dv-sbx.sh:69, 80`; `gen.sh:40`; `ci.yml:93` (`MIN_CHECKS=195`);
  `provclient/main.go:517` (also used by `claim-attacker`, `claim-attacker-chal`, `replay`, which H0 must cover too).

## Verdicts

| Item | Verdict | Conditions |
|---|---|---|
| (a) E4 on the first sacrificial variant chip | **APPROVE-WITH-CHANGES** | M7 settled (rig OS with `/dev/i2c-1`); E1 result attached and the 112-byte variant image plus its CRC recomputed by a second, independent implementation on the dev PC before the lock; `se-lab` lock build bound to the SN allow-list |
| (b) H0 starting now | **APPROVE-WITH-CHANGES** | Fix M4 before merge; include `claim-attacker`, `claim-attacker-chal`, `replay`; merge timing agreed with the v1.6 session |
| (c) PR D starting now | **APPROVE-WITH-CHANGES** | MINOR 7 and 8. No shared state, no node contact |
| (d) The design set as a whole | **REJECT** (no BLOCKER) | Revise §2.3, §4, §7, §9 and §10 for M1–M6 before PR 2 / PR 3 are written; then review the whole set again |
