# Review of the v6 design set: Reviewer B (feasibility, lifecycle, testing, field use)

Targets: `255-608b-config.md` v6 and `255-phase1-impl.md` v4, at commit e9eca58 (branch design/255-key-authority).
Base code: main tree in C:/src/Batman-255, plus PR 1 in C:/src/Batman-255pr1 (85e1086).
Read order: REVIEW.md, both targets in full, key-authority (K13–K21), threat model (§1, §3, §5.1), then the source and
harness, then review-v5set-A/B and v6set-changes.md. Read-only. No node contact. One local computation (cert size, M1)
in the scratchpad with Python `cryptography` 49.0.

Source checked: `boot/boot.go` (whole), `cmd/batman-provhelper/main.go:540-763`, `stable.go`, `trial.go`,
`keystore/keystore.go`, `provstore/provstore.go:436-452`, `provd/server.go:300-420, 495-540, 597, 638, 747`,
`node/node.go:330-345, 430-455, 1082-1094`, `node/wtxn.go:160-200, 320-340`, `node/updwork.go:968-998`,
`batman-autocommit:430-530`, `batman-config-save` (prov paths, `:170-240, 400-545`), `96-batman-config-migrate:130-200`,
`prov-lock.sh:1-80`, `batpower`, `tests/tools/provclient/main.go` (whole cmdNode / cmdSign), `scripts/dv/prov-lib-254.sh:1-90`,
`fresh-254.sh:1-100`, `prov-bench-s0-254.sh` (pcn, claim, nodes.txt), `chain1-254.sh:195-205, 289`, `prov-chain0-254.sh:60-80`,
`prov-claim-254.sh`, `scripts/node/prov-p1-254.sh` (whole), `scripts/node/prov-sec-254.sh`, `scripts/node/prov-wbox-254.sh:70-76`,
`scripts/dv/bench-254.sh`, `scripts/dv-preflight.sh:1-90`, `scripts/dv-sbx.sh:55-95`, `tests/prov-p1/sbx/cases/helper.sh`,
`scripts/fault-injection.sh:125-150`, `.github/workflows/ci.yml:140-200`, `docs/boards-and-builds.md:110-140`.

## Summary

| Severity | Count |
|---|---|
| BLOCKER | 0 |
| MAJOR | 4 |
| MINOR | 16 |

The v5-set BLOCKER (PR order) is closed in principle: the PR 2 chip image may run on the bench chip node for
helper-level units. The boot design (foreign-backend check, `Generate` only in the daemon, retry by re-running
`boot.Run`) holds against the source. What is left:
- the slot-8 cert as specified does not fit in slot 8 (computed now, not after PR D);
- "helper-level full suite" on the PR 2 chip node is not defined, and the provd units cannot pass there;
- the H0 contract misses a fourth SIGN loop and turns any missed loop into a hang;
- the per-unit table still has a vacuous row and a missing row.

## MAJOR

### M1. The chip-style cert of §3.1 does not fit in slot 8 (416 bytes).

- **Scenario.** PR D is to "compute the cert size first"; E15 says "does not fit → back to design". I built the cert
  exactly as §3.1 describes: X.509 v3, CN `se:<18 hex>`, subject serialNumber `<18 hex>`, BasicConstraints CA:FALSE,
  one private non-critical extension holding CBOR `{0: 33 B, 2: 33 B, 7: 9 B}` (84 B), validity 2020-01-01 to
  9999-12-31, ecdsa-with-SHA256, signed by a P-256 dev root.
- **Evidence (⚠️ my own build, not the final encoder).**

  | Variant | DER size |
  |---|---|
  | As specified; 20-byte random serial; issuer CN `batman-dev-root` | 467–469 B |
  | Same, issuer CN 29 characters | 481–483 B |
  | 1-byte serial, issuer CN `dev`, BasicConstraints kept | 438 B |
  | No subject serialNumber, 8-byte serial, BasicConstraints kept | 428 B |
  | 1-byte serial, 1-char issuer, no BasicConstraints, OID `2.25.1` | 413 B |

  Only the last one fits, with 3 bytes to spare, and it drops a field §3.1 requires. The slot size is 416 B
  (config §3, F§3). The load step compares the cache with slot 8 (impl §2.3 step 3), so "keep the cert off the chip"
  is a design change, as E15 already says.
- **Why it matters now.** §3.1 is the input to H2's vectors, to `nodecert.rs` in PR 3, and to `se-sign` in PR D.
  Starting PR D on the current format means writing `se-sign` and the vectors twice.
- **Fix (pick before PR D writes `se-sign`).** Either trim the format and write the exact field list with a size
  budget (for example: 1–8 byte serial, short issuer CN, drop the subject serialNumber for the se style and let
  `common()` use CN for that style, drop BasicConstraints because no verifier in this design builds a chain), or
  keep X.509 for the slot-8 copy but move the three extension values out of the cert into a separately signed small
  CBOR object (that needs its own design). Add a CI test in PR D: the largest possible se cert DER (72-byte
  signature, maximum serial) ≤ 416 B, failing above.

### M2. "Helper-level full suite" on the PR 2 chip node is not defined, and the table says provd units run "as is".

- **Scenario.** P7 and §9 say the PR 2 chip image runs "helper-level units" on the bench chip node. In PR 2, provd is
  unchanged (sig_static goes away only in PR 3, P6). provd's `buildNodeCert` calls `sign.static` first
  (`server.go:337`). The chip backend accepts only `Session` (§2.1), so the call fails and provd loops in "backoff
  reason=identity" forever (`server.go:380-392`). With no `nodeCert`, `readyLocked` is false (`server.go:531`), so
  provd never advertises. Results on the PR 2 chip node:
  - `prov-provd-254` and `prov-provd-wbox-254` (BLE advertising, GATT reads, STATUS key 5) FAIL. The per-unit table
    says "as is".
  - H1's case "PSK fetch fails, after recovery a member can log in" cannot run: member login is a BLE/app path.
  - `provd-stable` is still written (provd connects to `helper.sock`), so trial commits still work.
  "Helper-level full suite" therefore has no list, and the rule "full validation is not trimmed without asking"
  has nothing to hold on to.
- **Fix.** In §9 (or §4.2), list the DV units that run on the PR 2 chip node, the units that are not run there and
  why (provd/BLE: no node_cert until PR 3), and get the user's consent for that list once. State what the PR 2 chip
  helper answers to `sign.static` / `sign.ecdh_proof` (a fixed refusal code, not "temporary failure", so provd's
  backoff log says why). Rephrase the H1 PSK case at helper level: `provclient node verb psks.get` (as uid 471)
  returns an error while `se-fail` is armed and the full set after recovery; the member-login part moves to PR 3.

### M3. The H0 contract misses a SIGN loop, and any missed loop hangs instead of failing.

- **Scenario.**
  1. There are **four** SIGN → signer loops, not three: `prov-lib-254.sh:52-68` (`pc`), `prov-254.sh:808-` (`pr_pc`),
     `fresh-254.sh:77-93` (`pc`), and `prov-bench-s0-254.sh:335-352` (`pcn`). `pcn` makes the bench owner's claim
     (`prov-bench-s0-254.sh:457`). review-v5set-B M4 (mine) also said three; that was wrong.
  2. A loop with no `MAC` branch puts the `MAC …` line into its output buffer and never answers. `provclient` then
     blocks on stdin (`cl.signIn.Scan()`; the loop keeps the FIFO open with `exec {W}<>"$f"`), and the `ssh` in these
     loops has no `timeout`. The unit hangs until someone notices. That breaks "a test that finds nothing must FAIL",
     and the DV runs unattended.
  3. The "node list" that picks the host record is not defined anywhere: no file, owner, key or format. The closest
     existing thing is the bench store `~/.batman-dv/bench/nodes.txt` (written only by `prov-bench-s0-254.sh`, read
     by `bench-254.sh`), keyed by node name with `ip`, `mac`, `sn`. Units reach nodes at changing addresses
     (`FIP` after a fresh slot, `as02` in `prov-netjoin-fleet-254.sh:68`), so an IP key does not work.
- **Fix.**
  - List all four loops, and add a CI lint: every `SIGN\ *)` branch in `scripts/dv` has a `MAC\ *)` branch next to
    it (a missing one FAILs CI).
  - `provclient` dies with a clear message if no `MACR` / `SIG` line arrives within a bound (for example 60 s; the
    helper's nonce lives 60 s, `node.go:340`).
  - Define the node list: where it lives, who writes it, the key (eth MAC or node name, not IP), the fields
    (backend; for chip nodes the chip serial and the burn-record id), and "no entry → FAIL".
  - Name the re-fetch points (after the fresh-slot boot in `chain1` and `prov-bench-s0 fresh`) and fetch `sn` with
    `claim.secret`, because the host needs the file node's `sn` for the MAC.

### M4. The per-unit table still has a vacuous row and misses checks that FAIL on a chip node.

- **Scenario.**
  - `prov-chain0-254`: the table says "change: assert `node.key` does not exist". That is exactly today's check
    (`prov-chain0-254.sh:76`). On a chip image `node.key` never exists, so the check always passes. It no longer
    tests "no identity made on a bypass boot". This is a check that cannot fail.
  - `prov-p1-254` (`scripts/node/prov-p1-254.sh:39-41`) asserts `node.key`, `ecdh.key` and `claim.secret` are 0600. On
    a chip node all three are missing, so it FAILs. The table only mentions `claim.secret` (moved to H0).
  - `prov-sec-254`'s negative control uses a bind mount that `prov-wbox-254.sh:74-75` allows only for
    `identity/node.key`. The `/dev/i2c-1` 0644 fake device needs that allow-list changed. Not listed.
  - The provd rows are wrong for PR 2 (M2).
- **Fix.** `prov-chain0`: on a chip node assert that `/etc/batman-prov/identity` has no `sha256` (and no `backend`),
  with a negative control (a mutant whose bypass boot writes the cache). `prov-p1`: per backend, check the cache file
  modes (dir 0700, files 0600, `node.cert` 0644) and that no `node.key` exists. Add the `prov-wbox` allow-list
  change to H1. Before H1 is written, go through every unit that `grep -l 'node\.key\|ecdh\.key\|claim\.secret\|
  prov_files\|identity/'` finds (list in the review's appendix) and give each a row.

## MINOR

1. **Trial: one transient chip error reverts the OTA.** In service a chip error is retried with no latch (§2.4), but in
   a trial the first error after serving deletes `provd-stable` for the whole boot. One I2C glitch during a trial
   then reverts the OTA. Say this is intended (it fits "a failed change goes back"), and count chip errors in E14
   and in the PR 2 chip-node run, so a false revert rate is known.
2. **Foreign-backend check only in the chip helper.** The post-#255 **file** helper still sees a `backend=se` dir as
   "no identity" (`keystore.Load` fails at the missing `node.key`, `keystore.go:255-258`, before `:266`). Case: a chip
   node whose p5 holds the identity but no record (power cut between the identity rename and `prov.meta` on the
   first persist, `batman-config-save:532-543`) gets a file-image OTA before the next chip boot repairs it. 96 copies
   nothing (no record), the new slot has no overlay identity, rc 7 → `generate` → a software identity that serves
   and commits (K20). Rare, bench only, but the fix is free: the shared `identSum` treats any backend other than the
   build's own as foreign, in both builds. Add the rc 7 case to H1 for the file image too.
3. **`copyDir` calls `keystore.Load`** (`boot.go:425`), also from `--boot` and `--persist-now`. If the se `Load`
   reads the chip, CLI modes touch the chip. Say that `copyDir` and `identSum` use the structural cache check only.
   (Implementation detail; the PR 2 test "`--boot` does not touch the chip" catches it if it covers the rc 0
   no-overlay restore path.)
4. **What `backend-mismatch` does in the daemon.** §2.3 says retry for "no answer / not burned" and freeze for
   `identity-mismatch`. `backend-mismatch` is neither. Say freeze (no retry).
5. **The retry re-runs `--prov-get` (a p5 mount) every ≤ 5 min for as long as the chip is out.** `batman-config-save`
   already handles a concurrent ro reader (`:36-37`), so it is safe, but the only path that needs `boot.Run` again
   is `generate-failed`. Re-running only the load step otherwise is simpler. Implementation detail.
6. **`dtparam=i2c_arm=on` is not a diffconfig item.** It lives in `distroconfig.txt`, a firmware file shared by both
   boards and both images (`boards-and-builds.md:113`), and the OTA payload never carries `config.txt` /
   `distroconfig.txt` (`boards-and-builds.md:135`). So: (a) it reaches a node only by a card flash, which matches the
   "convert = reflash" plan, but say it; (b) putting it in the shared file changes the file image and the A/B-shared
   file rules apply; a chip-only file needs build machinery. Decide which in the firmware PR row, and say it under
   `[pi4]` only.
7. **H1 negative controls per case.** "FAIL on the pre-PR 2 product" does not exist as a chip image. Name one mutant
   per H1 case (for example: helper that keeps `provd-stable`; `psks` that omits; no foreign-backend check; `se-burn
   cert` without the cache check), as done for `node.key` and EACCES.
8. **`dv-sbx.sh` builds only a `prov_test` helper** (`dv-sbx.sh:69-81`). The chip cases in `sbx/cases/helper.sh` need a
   `prov_se,prov_test` build, and in the sbx there is no chip, so only "cache already present" rc paths apply. Put
   the dv-sbx change in H1.
9. **H0 negative control.** Moving `claim.secret` aside is safe only while the helper is not restarted (the file
   helper loads it at start; `boot.Run` would then see no identity and stop with `restore-failed`). Move it back
   before `pl_restore`'s reboot, and assert it is back.
10. **Q8 hardware steps.** The user solders. State per option which HAT carries which chip, whether a HaLow module
    moves between HATs, and that the rig's HAT keeps chip 1 (variant) while F1 needs chip 2 on a second HAT.
11. **Q8(a) also affects PR 2 / PR 3.** The matrix applies the "one file node left" caveat only to "every release".
    The PR 2 and PR 3 file-image full-suite rows need the same caveat.
12. **Lifecycle rows still missing** (also in review-v5set-B): `sysupgrade -n` on a chip node (expected = OTA);
    power cut during the first `Generate` / first persist (identity on p5, no record → next chip boot persists; see
    MINOR 2); p5 unreadable at boot with a cache (today's rc 1 "kept the overlay", then the chip compare).
13. **Stale text.** Config §8.0 says "E4 waits for v5 of this document to be reviewed"; it is v6 now. Impl §9 says
    "this design reviewed". Make them one rule.
14. **Name clash.** `prov-bench-s0-254.sh` calls the bench owner key "H0"; the design calls a harness PR "H0". Rename
    one in the design text.
15. **`--version`.** Line 2 is the prov_test marker that dv-sbx and the preflight grep for (`main.go:10`,
    `dv-sbx.sh:71`). Put the backend on its own new line, and keep lines 1–2 as they are.
16. **PSK fetch error blocks owner login too.** `psks()` computes owner PSKs without ECDH (`node.go:438-443`); returning
    an error for the whole set when only the replay ECDH fails means no one can log in until the chip answers. That
    is fail-closed and fine for the bench; say it in §2.4.

## Lifecycle matrix: check against REVIEW.md

| Path | Status in v4 |
|---|---|
| First boot / firstload | Present (burned, unburned, no chip) |
| Boot | Present |
| Clean shutdown, reboot, mid-sequence stop | Present |
| OTA stage 1 / 2 | chip→chip present; wrong-backend rows present; `sysupgrade -n` missing (m12) |
| Autocommit commit / revert | Trial rows present; transient-error revert not stated (m1) |
| Power loss | Burn and claim present; first-persist half state missing (m12, m2) |
| Restart of the component | Present (helper ×10) |
| Restart of dependencies | provd / bluetoothd present; I2C module present; p5 unreadable missing (m12) |
| Crash loop | Present |
| Downgrade | Present (pre-#255 → identity-lost; post-#255 → load refused) |
| Both boards | bcm2710 N/A with reason |

Ownership: complete except two harness resources: the node list (M3) and the chip lock file on the rig (Raspberry
Pi OS has no Batman run dir; say where `se-lab` puts it). Two-writer check: the overlay cache has 96 then the helper,
in sequence (S10, S89), and the helper's own `copyDir` / `Generate`; no overlap. `provd-stable` stays single-writer.

## Earlier findings: closed or reworded

| Earlier (v5set-B) | Status |
|---|---|
| B1 PR order | Closed in principle (P7 reworded). The chip-node scope is still undefined (M2) |
| M1 cert rewrite freezes | Closed: `se-burn cert` only with no cache; reflash otherwise |
| M2 shell changes | Closed: §2.8 shell row, H1 lists the CI tests and wbox patches |
| M3 per-unit table | Partly: chain1, bench-s0, fresh fixed; chain0 now vacuous, prov-p1 missing, provd wrong for PR 2 (M4, M2) |
| M4 H0 contract | Partly: re-fetch, serial from record, run-log check, negative control are in. Fourth loop, hang, node-list definition missing (M3) |
| M5 v2 data | Closed (H2) |
| M6 Q8 deferred | Closed as a precondition of H1; hardware steps missing (m10) |
| M7 OTA backend field | Closed (dropped; trial revert) |
| m1 `--boot` | Closed for `Generate`; `copyDir` path open (m3) |
| m2 retry details | Closed (result replaces; prov-state on change; back-off) |
| m3 trial failure on use | Closed |
| m4 foreign backend | Closed for the chip build; file build open (m2) |
| m5–m15 | Closed |

## Facts in the target that are wrong or unsupported

| Where | Claim | What the source shows |
|---|---|---|
| impl §4.1 | Three `SIGN` loops | Four: `prov-bench-s0-254.sh:335-352` `pcn` also answers SIGN (M3) |
| impl §3.1 / config §8.2 E15 | The cert fits in 416 B | As specified ≈ 467 B (⚠️ computed, M1) |
| impl §4.2 table | `prov-provd-254`, `prov-provd-wbox-254` "as is" on a chip node | In PR 2 provd cannot build node_cert: `server.go:337` `sign.static`, `:531` not ready (M2) |
| impl §4.2 table | `prov-chain0`: "change: assert no `node.key`" | That is today's assertion (`prov-chain0-254.sh:76`); vacuous on a chip node (M4) |
| impl §4.2 table | `prov-p1-254`: only `claim.secret` matters | `:39-41` also asserts `node.key`, `ecdh.key` modes (M4) |
| impl §4.2 H1 | Member login after PSK recovery is an H1 case | Needs BLE/app; not possible on the PR 2 chip node (M2) |
| impl §2.8 | `dtparam=i2c_arm=on` via board diffconfig | It is `distroconfig.txt`, shared, never in an OTA payload (m6) |
| impl P3 | Old helper refuses `backend=se` at `keystore.go:266-267` | It fails earlier, at the missing `node.key` (`:255-258`). Same result |
| config §8.0 | E4 waits for v5 review | Stale (m13) |

Checked and correct: `boot.go:51-57, 80, 105, 112-114, 138-152, 188-234, 247-258, 278-303, 395-430`;
`main.go:571-575, 623-637, 700-712`; `stable.go:24-51`; `trial.go:31-35`; `keystore.go:31, 173-176, 210, 238-305`;
`provstore.go:443-449`; `server.go:357, 505, 513-514, 747`; `node.go:340, 438-455, 1089-1091`; `wtxn.go:166, 328-336`;
`batman-autocommit:441-443, 505-513`; `batman-config-save:176-178, 229, 429-436, 490-536`; `96:155-165`;
`prov-lock.sh:7, 38-44`; `provclient/main.go:511-520, 568-600`; `prov-lib-254.sh:12`; `dv-preflight.sh:32, 41-42`;
`dv-sbx.sh:69, 80`; `ci.yml:146, 149-155, 172`; `fault-injection.sh:139-145` (the FI precheck compares rootfs sha, so
a chip node with the same `BATMAN_VERSION` cannot be OTA'd with a file payload by FI).

## Security (B's pass)

No BLOCKER or MAJOR. Notes:
- The `MAC` / `MACR` channel makes the host a MAC oracle for the node's own claim secret. The only verifier of that
  MAC is the node itself, so a compromised test node gains nothing it does not already have as root.
- File-node secrets on NTFS temp: the run log (`$HT/out.log`) sits in the same per-run dir. The run-log secret check
  covers it. Fine for the bench.
- `batpower` uses `i2cget` as root on the same bus without the chip lock (`batpower:61`). It never addresses 0x60
  after the §2.7 refusal, and kernel I2C transfers are atomic, so it cannot break a chip sequence. E0a / E0b cover the
  wake pulse's effect on other devices (an INA226 acknowledges a general call but resets only on second byte 0x06).
- Negative tests per attack: EACCES for the provd uid with a 0644 control; ENOENT in a container; burn refusals;
  slot-8 change after the cache → freeze. Adequate for the bench.

## Verdicts

| Item | Verdict | Conditions |
|---|---|---|
| (a) E4 on the first sacrificial variant chip | **APPROVE-WITH-CHANGES** | E1 (version `00 00 60 03`), E2, E3 done; the variant 112-byte image and lock CRC recomputed by an independent implementation on the dev PC; the `se-lab` lock path code-reviewed and run against the fake chip from the PR D branch; lock bound to the serial allow-list; the 3.3 V power-cut method and the user's consent per cut; fix the stale "v5" gate text (m13). Nothing in M1–M4 touches chip 1's bytes |
| (b) H0 starting now (merge after the v1.6 tag) | **APPROVE-WITH-CHANGES** | M3 before merge: four loops + CI lint, `provclient` timeout on `MACR` / `SIG`, the node list defined (key, fields, owner, missing → FAIL), re-fetch points named with `sn`; m9; full suite on the v1.6 image |
| (c) PR D starting now | **APPROVE-WITH-CHANGES** | Settle the §3.1 format and its size budget first (M1), with the "largest cert ≤ 416 B" CI test; no shared state, no node contact; formats marked provisional |
| (d) The design set as a whole | **APPROVE-WITH-CHANGES** | M1–M4 are bounded fixes (a format budget, a unit list, a harness contract, table rows); none changes the boot or burn architecture. Per REVIEW.md the set is reviewed again as a whole once they are fixed |

## Appendix: units that read identity files (for M4)

`grep -l 'node\.key\|ecdh\.key\|claim\.secret\|prov_files\|identity/sn\|identity/prov\|PROV_IDFILES\|prov_ident_ok'`
over `scripts`, `tests`: `scripts/daily-validation.sh` (description only), `scripts/dv/chain1-254.sh`, `fresh-254.sh`,
`prov-bench-s0-254.sh`, `prov-chain0-254.sh`, `prov-claim-254.sh`, `prov-downgrade-254.sh`, `prov-provd-254.sh`,
`prov-provd-wbox-254.sh`, `prov-sec-254.sh`, `scripts/node/prov-base-254.sh`, `prov-p1-254.sh`, `prov-sec-254.sh`,
`prov-wbox-254.sh`, `tests/prov-p1/cfgsave-frozen-nomount.sh`, `cfgsave-identity-freeze.sh`, `cfgsave-provget-rc10.sh`,
`prov-lock-init.sh`, `sbx/cases/cfgsave.sh`, `sbx/cases/helper.sh`, `tests/tools/peer/nodecert.py`,
`tests/tools/provclient/main.go`, `tests/wbox/96-noprov.patch`, `96-norestore.patch`. Not in the table today:
`scripts/node/prov-p1-254.sh` (beyond `claim.secret`), `scripts/node/prov-wbox-254.sh`, `scripts/node/prov-base-254.sh`
(`strip-p5-prov`, used by `prov-legacy-upgrade`), `tests/tools/peer/nodecert.py`.
