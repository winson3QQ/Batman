# Review of the v5 design set: Reviewer B (feasibility, lifecycle, testing, field use)

Targets: `255-608b-config.md` v5 and `255-phase1-impl.md` v3, at commit 8c6e069 (branch design/255-key-authority).
Base code: main tree in C:/src/Batman-255 plus PR 1 in C:/src/Batman-255pr1 (85e1086).
Read: REVIEW.md, both targets in full, key-authority K13–K21, the source and harness below. Then review-v4set-A/B and
v5set-changes.md. Read-only; no node contact.

Source checked: `boot/boot.go` (whole), `cmd/batman-provhelper/main.go:540-763`, `stable.go`, `trial.go`,
`keystore/keystore.go`, `keystore/identity.go`, `release/release.go:120-300`, `node/update.go:280-330`,
`node/updwork.go:500-530, 968-998`, `provd/server.go:355-358, 440-450, 745-748`, `provd/noise.go:103-110`,
`proto/proto.go:52-70, 107`, `app/rust/batman-proto/src/nodecert.rs:100-135`, `batman-autocommit:490-530`,
`batman-config-save` (prov paths), `96-batman-config-migrate:140-175`, `prov-lock.sh:1-60`, `batman-provhelper.init`,
`feed/batman-prov/Makefile:23-30, 58`, `tests/tools/provclient/main.go:300-660`, `scripts/dv/prov-lib-254.sh`,
`scripts/dv/fresh-254.sh:40-100`, `scripts/dv/chain1-254.sh:160-210`, `scripts/dv/prov-bench-s0-254.sh`,
`scripts/dv-preflight.sh:1-80`, `scripts/dv-sbx.sh:65-82`, `.github/workflows/ci.yml:140-175`, `batpower`.

## Summary

| Severity | Count |
|---|---|
| BLOCKER | 1 |
| MAJOR | 7 |
| MINOR | 15 |

The v4-set boot findings are really closed: today's order is kept, `Env.Generate` is the seam, and the cache keeps
today's names. The experiment rig now has an OS. What is left is mostly about **whether the plan can be carried out
in the stated order on this bench**, and about the shell/harness layer that the cache change touches.

## BLOCKER

### B1. The PR order cannot be carried out: P7 forbids the chip image on any node before PR 3, but H1 and PR 2 need it there first.

- **Scenario.** The order is H1 → PR 2 → PR 3 (§9). H1 must merge before PR 2, with evidence "FAIL on the mutant and
  the pre-PR-2 product, PASS on the PR 2 rc" (§4.2 last line). The PR 2 rc is a chip image. Its chip units (`se-fail`,
  EACCES, burn refusals, no `node.key`, OTA backend) can only PASS on a node that runs it. The §9 matrix even has the row
  "PR 2 / PR 3 development | white-box chip image | the node converted to a chip node". But P7 says "the chip image is
  not installed on any node before PR 3 merges". PR 3 merges after PR 2. So:
  - either H1 merges without its PASS evidence (breaks the one-validation-set rule), or
  - PR 2 merges with its boot, trial and burn paths run only against the fake chip (breaks "full validation before
    the PR"), or
  - P7 is broken.
  E0b, F1 and E14, the first contact of the real driver with a Batman image, are placed in "acceptance", after both
  PRs have merged. A driver bug found there means a fix PR after the merge.
- **Evidence.** impl P7 (line 24), §4.2 (line 195), §9 order (lines 283-292) and matrix (line 298); config §6
  (line 140: "wait for the chip image, PR 2").
- **Why P7 exists.** review-v4set-A M4: a PR 2 chip image speaks v1, whose `sig_static` the app checks with the slot-1
  key, which is internal-sign only, so no app can log in. That is a K13 risk only for a node an app logs into. The
  harness does not log in through the app: `provclient` talks to `helper.sock` directly (`provclient/main.go:575-600`),
  and the chip units are helper-level.
- **Fix (no new mechanism).** Pick one and write it into §9:
  1. Reword P7: the PR 2 chip image may run on the bench chip node for helper-level units only; no app logs into it;
     K13 is not at stake because no node in the deployed role runs it. Or
  2. Validate PR 2 and PR 3 as one stacked rc (PR 3 branch on top of PR 2), run H1 and the full suite on that rc, then
     merge PR 2 and PR 3 back to back.
  In either case, move E0b and the real-chip parts of F1 / E14 before the PR 2 merge, and say on which node (see M6).

## MAJOR

### M1. Changing the slot-8 cert on an unclaimed node freezes the node; the "rewrite the cache from slot 8" path does not work.

- **Scenario.** §2.3 step 2: if slot 8 differs from the cached `node.cert` but matches the chip, the helper rewrites the
  cache "and persists it to p5". The persist goes through `batman-config-save --prov-only --prov-identity`. That
  refuses any identity whose `sha256` differs from p5's: "refusing --prov-only: the identity offered is not the one
  on p5 (identities are written once)" (`batman-config-save:435-436`). Now the overlay and p5 hold different `sha256`
  files:
  - every later `batman-config-save` write refuses with "identity mismatch (frozen)" (`batman-config-save:429-431`);
  - at the next boot, `boot.Run` returns `unknown(identity-mismatch)` before anything else (`boot.go:112-114`).
  So the documented recovery for a cert-format or dev-root change (config §5.3, impl §7 row "在未認領的節點換憑證")
  freezes the node instead. The PR 2 test for that row would find this. The design claims the row works.
- **Fix (less machinery).** Allow `se-burn cert` only while the node has no identity cache (burn S3, before the first
  `Generate`). A later cert change = reflash the card, `se-burn cert`, claim again. That is the same recovery the design
  already accepts for a HAT swap. Then drop the "rewrite from slot 8" branch from §2.3. The load step then only
  compares the cert with the chip. Correct §5.3, §7 and the dev-root rotation text.

### M2. P3's "same file names, so the shell does not change" is wrong; the shell, its CI tests and the wbox patches are unplanned.

- **Scenario.** P3 says reusing the names means `96-batman-config-migrate` and the shell need no change. But the cache
  has 5 files (`backend sn node.cert chip_sn sha256`). Today:
  - `prov-lock.sh:7` fixes `PROV_IDFILES` at 6 names, and `prov_ident_ok` (`:38-44`) wants all 6 plus exactly 6 lines in
    `sha256`;
  - `96-batman-config-migrate:158-161` copies the p5 identity only if `prov_ident_ok` passes;
  - `batman-config-save:229` refuses `--prov-identity` that is not "7 files", `:521-523` returns rc 13 for it, and
    `:532-536` copies `$PROV_IDFILES` one by one.
  So without a change the chip cache is never persisted to p5 and never restored. §6 does say "the list depends on
  `backend`", so the author knows. But no PR row and no test names the change. These CI tests encode the 6-file
  rule and need backend variants: `tests/prov-p1/cfgsave-identity-freeze.sh`, `cfgsave-provget-rc10.sh`,
  `cfgsave-frozen-nomount.sh`, `tests/prov-p1/sbx/cases/cfgsave.sh`, `sbx/cases/helper.sh`, `prov-lock-init.sh`.
  The wbox patches `tests/wbox/96-noprov.patch` and `96-norestore.patch` patch 96 by text and may stop applying.
- **Fix.** In PR 2's scope, name `prov-lock.sh`, `batman-config-save`, `96-batman-config-migrate` and the exact
  `prov_ident_ok` rule for `backend=se`. In H1, name the CI tests above and the wbox patches: each gets a chip-cache
  case, with FAIL on today's product and PASS on the PR 2 rc. Correct P3's rationale.

### M3. The per-unit table says "as is" for units that assert the file layout or a new identity.

- **Scenario.** On a chip node:
  - `chain1-254.sh:201` asserts `prov_files=7` (computed in `fresh-254.sh:45` as `ls identity/prov | wc -l`). A chip
    cache has 5 files, so it FAILs. The table says chain1 is "as is".
  - `chain1-254.sh:162-207` and `prov-bench-s0-254.sh:44, 68` treat p5 mkfs as "a fresh card, so a NEW identity", and
    store "the new serial". On a chip node, p5 mkfs gives the **same** `device_id` (that is C5). Any assertion or
    bookkeeping that expects a change goes wrong. The table says `prov-bench-s0` is "as is".
  - The same p5-mkfs units also claim the new identity. Where its claim secret comes from is M4.
  "H1 will grep for the rest" leaves the table open. A wrong "as is" row also passes review.
- **Fix.** Replace "as is" with a result per unit, from reading each unit. For each unit that reads the layout,
  counts the files, or expects a new serial after a fresh card, say: adapted (how), or not applicable (why, and Q8
  asks the user). Count the units that a chip node cannot run.

### M4. H0's host-side claim answer does not fit the harness as it is.

- **Scenario.**
  1. **Fresh-identity units.** H0: the file-node record = `claim.secret` copied to the host "at the start of the
     run". `prov-bench-s0`, `chain1` and the `fresh-254` path mkfs p5 in the middle of the run, which makes a new
     identity, and then claim it. So the copy from the start has the wrong secret.
  2. **Three wirings.** The `SIGN` → signer loop exists three times: `prov-lib-254.sh:52-68`, `prov-254.sh`, and
     `fresh-254.sh:77-93`. Each needs a `MAC` branch. H0 names only the provclient side.
  3. **Serial for the MAC.** `CheckMacInput` uses `sn[8]`, `sn[0:2]` (`proto.go:54-70`). A file node uses its node `sn`.
     A chip node uses the chip serial, which is not in `info.cert` (it returns the node `sn`,
     `provclient/main.go:590-593`). The `MAC <ClientChal>` line has no serial. The host must take it from the record.
     Write this into the contract now, so H1 does not have to redesign it.
  4. **Secret into the run log.** `prov-lib-254.sh:12` tees all stdout into `$RUNLOG`. A naive `q 'cat claim.secret'`
     puts the secret in the log. Say how it is fetched (to a 0600 file, never echoed) and add a log check.
  5. **Negative control.** "Old tool FAIL in the target case" has no target case on a file node, because the old
     tool works there. Use: `claim.secret` moved aside on the node (old tool dies "claim.secret", new tool PASSes from
     the host record), restored after.
- **Fix.** Contract: the host fetches the file-node secret **after each identity generation** (every point where the
  unit makes a fresh card), into the per-run 0600 directory, without echo. List all three `pc()` copies. `MAC` line
  = `MAC <ClientChal hex>`; the host takes the serial from its record (file: node `sn`; chip: chip serial). Use the
  negative control above.

### M5. Protocol test data and peer tools are put in PR 3, against the one-validation-set rule, and H0's v2 parsing has nothing to test.

- **Scenario.** §3.4 adds v2 vectors to `tests/vectors/219-protocol/`. §9 puts "peer tools and vectors" in PR 3. Both
  are harness (node clients, CI checks). The project rule: harness goes to main in its own PR first; product PRs do not
  touch it. Meanwhile H0 adds v1/v2 detection to `tests/tools/peer/*`, `provclient`, `synth-joinreq`, `netobj.py` and
  splits `MIN_CHECKS` by version. Until v2 vectors exist, that v2 code and the v2 count check nothing. A check that
  finds nothing to check must FAIL.
- **Fix.** Move the v2 vectors (`gen.py` / `verify.py` and the negative cases of §3.4) and the peer-tool v2 support
  into a harness PR before PR 3 (H1, or a short H2). Keep H0 to the claim path, the log checks and the preflight key.
  H0's v2 code and the v2 `MIN_CHECKS` arrive with the vectors, with a sentinel that FAILs at zero v2 checks.

### M6. The bench hardware (Q8) and the rig's Pi model decide H1 and PR 2, but are deferred to "before acceptance".

- **Scenario.** 02 and 04 are locked until v1.6 ends. The rig runs Raspberry Pi OS and its Pi model is "to be
  confirmed". H1's evidence, PR 2's chip-node runs (B1), E0b, E14 (needs a Pi 4), and F1 (Batman chip image, A/B card)
  all need a Pi 4 that can run a Batman image with a burned chip. If the rig is not a Pi 4, it cannot do any of them.
  If it is a Pi 4, using it means reflashing the rig away from Raspberry Pi OS, and the plan does not say so.
  Q8 says "before acceptance", but the decision blocks H1. In addition, Q8(a) (convert 02 or 04) leaves the file image
  without a same-image pair, while the §9 row "every release: file image, as today" assumes the two-node suite stays.
- **Fix.** Make Q8 and the rig model preconditions of H1 in §9. State the node for each of: H1 evidence, PR 2 chip
  runs, E0b / E14 / F1. If option (a), correct the "every release, as today" row and list which mesh units lose
  same-image coverage (asked first, per the full-validation rule).

### M7. The OTA `backend` check is a release-format change with no present use.

- **Scenario.** §2.8: "add `backend` to the release info and compare it in `update.go`". The signed S payload rejects
  unknown keys: `onlyKeys(p, 1, 2, 3, 4, 6, 7, 8, 9)` → "S: unknown key" (`release.go:262-264`). So this is a new S key
  in `release.go`, in the harness signer `tests/tools/peer/signrel.py` (needed by H1's "signed wrong-backend package"),
  in the firmware fork's release builder, and in the release CDDL. None is in a PR row. What it prevents: an
  app-pushed OTA of the wrong variant. App updates exist only on A/B cards (`main.go:644-648`), and every wrong
  combination already ends in a trial revert:
  - chip image on a file node → `backend-mismatch` (§2.3);
  - post-#255 file image on a chip node → `keystore.go:266-267` refuses `se`;
  - pre-#255 image on a chip node → `identity-lost` (`boot.go:247-258`).
  In each case the helper never listens, so `provd-stable` is never written and autocommit reverts. Chip images are
  not released in phase 1. Only T-signed bench images exist.
- **Fix.** Drop the release field and the H1 unit. Rely on the trial revert, which `prov-downgrade-254` (as a negative
  test) and the "OTA file → chip" row already exercise. If the author keeps it, list all four components with their
  PRs (signrel.py in H1), and give the failure it prevents that the revert does not.

## MINOR

1. **`--boot` is not chip-free.** §2.3 says `--boot` and `--persist-now` never touch the chip. But `--boot` runs
   `boot.Run` (`main.go:575`), which calls `Env.Generate` on rc 7 / 9 (`boot.go:142, 207, 231`). In the chip build that
   reads the chip without the chip lock. The sbx harness runs `--boot` (`tests/prov-p1/sbx/cases/helper.sh:38`). Fix:
   in the chip build, `--boot`'s `Generate` returns an error ("daemon only"), and the doc says so.
2. **Load-step retry details.** When the retry re-runs `boot.Run`, its new `Result` (Verdict, Unfinished, P5Read)
   must replace the one used for `n.Verdict` and `BootFinish` (`main.go:661, 702`). "Write `prov-state` only on change"
   needs a compare in `writeProvState` (`boot.go:278-303` writes on every Run). `--prov-get` mounts p5 every 10 s while
   a chip stays unburned. Add a back-off (for example 10 s → 5 min).
3. **Trial chip failure is seen only on use.** `Cert`, `SN`, `DACPub`, `ECDHPub` come from the cache. Only
   `SignPurpose`, `ECDH` and `CheckMac` touch the chip. A trial with no app login after the load step never sees a
   failure. Say so. The DV case must send a request (`id/prove` or `claim.verify`) after injecting the fault and before
   autocommit's poll.
4. **Foreign-backend identity on rc 7 / 9 / 13.** The "OTA file → chip: freeze" row holds for rc 0. If the chip build's
   `identSum` treats a `backend=file` directory as absent, then on rc 7 / 9 `boot.Run` calls `Generate`. That writes a
   chip cache whose persist p5 refuses (`batman-config-save:435`), so the node freezes on the next boot, not on this
   one. Say that `identSum` reports a foreign backend as "present, foreign", and that `boot.Run` maps it to
   `unknown(backend-mismatch)` before the rc switch. Test rc 0 and rc 7 with a p5 identity but no record.
5. **`se-sign begin` re-run.** After a power cut between the data lock and the CheckMac, a re-run of `begin` must reuse
   the pending secret for that serial, never make a new one. Otherwise slot 5 and the record differ forever and the
   chip can never be claimed. State the rule. Add the fake-chip test "begin after a lock-interrupt sends the same
   secret".
6. **`se-burn cert` "unclaimed".** During burn S3 the node has no record (`generate-failed`). Define "unclaimed" as "no
   record, or a record in state unclaimed". After M1 this becomes "no identity cache".
7. **Tenant-container negative test.** A container gets no `/dev/i2c-1`, so `open` returns ENOENT, not EACCES. Accept
   ENOENT there. The EACCES case is the provd uid on the host.
8. **E4 power cycle.** "Address still 0x60 after power-off" needs the 3.3 V rail cut. A Pi reboot does not cut it. Say
   how: shutdown, then unplug or the Shelly plug, with the user's consent. Also say that the independent recompute in
   §4 covers the **variant** image used by E4, not only the final image.
9. **`check-field-build.sh` dev-root check.** §4.2 says the dev root "exists in PR 2". The dev-root public key enters
   the app in PR 3 (`DEV_TRUST`, §3.2). The node never holds it (§2). Tie the check to PR 3.
10. **H1 red steps on main.** H1's `prov_se` sentinel and the chip wbox patches have no target on main until PR 2.
    That is the accepted precedent (`ci.yml:172`, "expected red until … lands"), but say it. Also say whether PR D's
    tests carry the `prov_se` tag, because that decides whether the sentinel is red. PR D's merge timing is not
    stated (the PR 1 and H0 rows have one).
11. **`BATMAN_VERSION` of the chip image.** Preflight P3 requires one version across the fleet (`dv-preflight.sh:41-42`).
    For mixed-pair runs, state that the chip image carries the same `BATMAN_VERSION` as the file image from the same
    commit.
12. **The fault-injection seam in the real driver.** `se-fail` on the white-box chip image needs a seam inside
    `se608` (fail N sequences, then recover), armed through the existing killpoint file (`seam.Arm`, `main.go:629`).
    Name it. PR D's fake chip covers only CI.
13. **E15 fallback.** "Cert not on the chip, only in the record and p5" contradicts the load step, which compares
    the cert with slot 8. It is fine as a contingency, but mark it as one that would need a design change.
14. **`sn` format.** The `sn` file is 18 hex characters plus a newline (`keystore.go:210`), not 9 bytes. Say so for the
    chip cache too, so that rc 13's `TrimSpace` compare (`boot.go:251-253`) and the DV `tr -d '\n'` reads still work.
15. **Validation matrix vs Q8.** The "every release: file image, as today" row and Q8(a) contradict each other (see M6).

## Lifecycle matrix: what is missing

| Path | Status in v3 |
|---|---|
| Cert change on an unclaimed node | Listed, but wrong (M1) |
| OTA to the wrong backend, rc 7 / 9 | Only rc 0 is covered (MINOR 4) |
| Trial: chip fails after the load step, with no request | Not stated (MINOR 3) |
| `--boot` CLI on rc 7 / 9 | Contradicts §2.3 (MINOR 1) |
| Re-running a burn after an interrupted lock | Secret reuse not stated (MINOR 5) |
| Power cut during `Generate` or the cache write | Covered by today's tmp-and-rename (`keystore.go:173-220`); say the chip `Generate` keeps it |
| sysupgrade `-n` (no keep) on a chip node | Missing. Expected the same as OTA (96 copies from p5). Add the row |
| Restart of each dependency (I2C module, p5) | I2C covered (E0b). p5 unreadable: today's rc 1 / 8 path, say so |
| bcm2710 | N/A, reason given |

The other rows (first boot, boot, stop and reboot, helper crash loop, trial ×3, chip→chip OTA, revert, downgrade by
sysupgrade, reflash, HAT swap, conversion, burn and claim power loss) are present and testable, given B1 and M6.

## Earlier findings: closed or reworded

| Earlier (v4set-B) | Status |
|---|---|
| M1 boot order / CLI modes | Closed for the daemon. The `--boot` CLI claim is still wrong (MINOR 1) |
| M2 cache names | Names closed. The shell side is acknowledged in §6 but has no scope, tests or PR (M2); the per-unit table has wrong rows (M3) |
| M3 chip units in product PRs | Closed for DV units (H1). Vectors and peer tools reopened (M5) |
| M4 H0 vs v1.6 | Closed: missing key = file, merge after the tag, per-run 0600 dir. New fit problems (M4) |
| M5 validation matrix | Matrix added. Hardware deferred too late (M6); B1 |
| M6a OTA by board | Addressed with a mechanism that has no present use (M7) |
| M6b conversion | Closed (row + procedure + role-rule exception) |
| M6c downgrade facts | Closed (`boot.go:247-258`, `batman-config-save:521-523` match the new row) |
| M6d retry writes | Stated. Implementation note in MINOR 2 |
| M7 rig OS | Closed (Raspberry Pi OS Lite, E0a / E0b). Pi model still open (M6) |
| m1–m9 | Closed, except m4 (wbox chip image named, but the seam is not: MINOR 12) |

## Facts in the target that are wrong or unsupported

| Where | Claim | What the source shows |
|---|---|---|
| impl P3 | Same names mean 96 and the shell need no change | `prov-lock.sh:7, 38-44`, `96:158`, `batman-config-save:229, 521-536` all fix 6 files (M2) |
| impl §4.2 table | chain1, prov-bench-s0 "as is" | `chain1-254.sh:201` `prov_files=7`; bench-s0 expects a new identity (M3) |
| impl §2.3 | `--boot` needs no chip | `main.go:575` → `boot.go:142` `Generate` (MINOR 1) |
| impl §2.3 / config §5.3 | Cert change on an unclaimed node rewrites and persists the cache | `batman-config-save:435-436` refuses, then `boot.go:112` freezes (M1) |
| impl §2.8 | OTA check = an `update.go` change | `release.go:262-264` rejects unknown S keys; it is a release-format change (M7) |
| impl §4.2 | Dev root exists in PR 2 | The app pin is in PR 3; the node never holds it (MINOR 9) |
| impl P7 vs §9 | Both hold | They cannot both hold (B1) |

Checked and correct: `main.go:571-575, 631-637, 703, 708`; `boot.go:33, 112-114, 142, 188-258`; `keystore.go:31, 45-46,
102-104, 266-267`; `stable.go:30-50`; `trial.go:31-35`; `batman-autocommit:509-512`; `update.go:311-313`;
`96-batman-config-migrate:157-163`; `prov-lock.sh:7, 38-44`; `provclient/main.go:517`; `dv-preflight.sh:32`;
`dv-sbx.sh:69, 80`; `Makefile:26-27`; `server.go:357, 442-449, 747`; `noise.go:105, 108-109`; `nodecert.rs:104, 118-121,
126-133`; `proto.go:54-70, 107`.

## Security (B's pass)

No new BLOCKER or MAJOR. Notes:
- The host-side secret must stay out of the tee'd run log (M4.4).
- Root can still reach 0x60 with i2c-tools if they are in the image. That is the same as "root = helper" and is
  accepted under C8 / K21. Say that `batpower`'s 0x60 refusal (§2.7) guards against our own mistakes, not a root
  attacker.
- The slot-8 overwrite by root is a denial of service only (cert checked against the dev root). It is accepted for
  the bench.
- Burn on a node: `/etc/batman-dev-open` is correctly stated as a marker, not a control.

## Verdicts

| Item | Verdict | Conditions |
|---|---|---|
| (a) E4 on the first sacrificial variant chip | **APPROVE-WITH-CHANGES** | E1 done on the rig with version `00 00 60 03`; E2 / E3 done; the variant 112-byte image and the lock CRC recomputed by a second, independent implementation on the dev PC; the `se-lab` lock build bound to the serial allow-list; the power-cut method written (MINOR 8); the user's consent. Nothing in B1 / M1–M7 depends on chip 1 |
| (b) H0 starting now (merge after the v1.6 tag) | **APPROVE-WITH-CHANGES** | Before merge: M4 (fetch after each generation, all three `pc()` copies, serial from the record, no echo into `$RUNLOG`, moved-aside negative control); M5 (no v2 parsing or v2 `MIN_CHECKS` without v2 vectors); full suite on the v1.6 image |
| (c) PR D starting now | **APPROVE-WITH-CHANGES** | No shared state, no node contact. State the merge timing and whether its tests carry `prov_se` (MINOR 10); compute the cert size first (E15); formats marked provisional |
| (d) The design set as a whole | **REJECT** | B1 (the PR order) and M1–M7. Revise §2.3, §2.8, §4, §7, §9, §10 Q8 and config §5.3, then review the whole set again |
