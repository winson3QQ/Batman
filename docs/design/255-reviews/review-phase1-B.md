# Review of `255-phase1-impl.md` v1: Reviewer B (feasibility, lifecycle, testing)

Reviewer: independent (B). Base: worktree `C:/src/Batman-255`, main 4eba26d. Read: `REVIEW.md`, the target,
`255-608b-config.md` v3 (§2, §5, §7, §8, §9), `255-key-authority.md` v3.1 (K13–K16, K20, K21), plus the source and
harness cited below. Read-only; no device contact, no builds.

Verdict: **REJECT** (2 BLOCKER, 10 MAJOR, 12 MINOR). The direction is right: an interface first, a pure-Go driver,
a build-time backend and a per-session proof. The PR plan, the harness plan and the lifecycle matrix cannot be carried
out as written. **PR 1 can start first**, narrowed as described in B1, after its harness PR (H0).

---

## BLOCKER

### B1. PR 1 is not "behaviour unchanged". The protocol changes sit in the wrong PR, and PR 1 carries harness changes.

- **Scenario.** PR 1 implements the `Identity` interface of §2.1: `SignPurpose` without `Static`, with `Peer` routed
  through `SignSession`, plus `Endorsements()`. Today's provd builds `node_cert` by calling `sign.static` and
  `sign.ecdh_proof` (`provd/server.go:337, :343`). It does not serve until `node_cert` exists
  (`server.go:530-532`, `readyLocked`). Today's app rejects a `node_cert` without a valid `sig_static`
  (`nodecert.rs:107-112`, `common`). So PR 1 either breaks every login with today's app, or does not implement §2.1.
  Separately, §9 PR 1 says "腳本改用它" (the scripts switch to `identity-info`). Those scripts are
  `scripts/dv/*`, `scripts/node/*` and `daily-validation.sh` (§4 rows 1–2). Under the project's one-validation-set
  rule they go to main in their own harness PR, before the product PR.
- **Evidence.** `keystore.go:71-90` (`PurposeStatic` / `PurposeECDH` / `PurposePeer`); `node/node.go:290, 390-430`;
  `server.go:304-363`; `nodecert.rs:89-123`. P6 ("the file backend also drops `sig_static`") changes the protocol.
  It is not a refactor.
- **Fix.** Split by what each change does:
  - **H0, harness, first.** Changes that keep working against both the old and the new product. A `node_cert`
    v1/v2 dispatch in the peer tools, `provclient` and the vectors; the claim-secret path (B2); the node-type
    detection used by preflight; the Go CI step for the new tag (M2).
  - **PR 1.** A pure refactor: `Identity` interface plus the file backend with today's methods, including
    `SignPurpose(Static|ECDH|Peer)`. No `identity-info` (m1), no script changes. Its proof is a `node_cert` from
    before and after that is byte-identical apart from signature randomness, checked by the existing app tests
    against a node built from the PR.
  - **PR 3.** All the protocol changes: `Static` and `boot_id` removed, `id/prove`, v2, and the app.

### B2. The harness gets the claim secret from somewhere that does not exist, and the design contradicts the config doc.

- **Scenario.** A DV unit claims a chip node. Every claiming unit drives `provclient node claim`, which runs on the
  node as root and reads `/etc/batman-prov/identity/claim.secret` (`tests/tools/provclient/main.go:517`). It is used
  through `prov-254.sh:769` and `prov-lib-254.sh` by about 25 units (`grep -l provclient scripts/dv` lists 27 files,
  for example `chain1`, `fresh`, `prov-netjoin`, `prov-owner`, `prov-update`, `prov-powerloss`, `claim-lock`). On
  a chip node the file does not exist (§2.4), so every claiming unit fails before it judges anything.
  - §4 mentions only `prov-claim-254` and puts `provclient` under "peer tools: support `node_cert` v2". The real
    work is a new secret path in `provclient`.
  - §4 / §6 keep the claim secret in a burn record on the developer's machine for the DV to use. Config §5 step 8
    says the secret is **deleted** from the burn record once the QR is printed.
  - The leak canaries read the secret on the node. `prov-claim-254.sh:49-51` greps logread for the first 16 hex
    characters of `claim.secret`, read on the node; `scripts/node/prov-p1-254.sh:63-66` does the same. With the
    chip backend there is nothing on the node to read. Shipping the secret to the node to run the canary would undo
    C4 / R5.
- **Fix.**
  - Define the contract: the burn record's path and mode on the WSL host, kept out of the repo and out of run logs,
    with who reads it.
  - Change `provclient` so the host answers a `MAC <clientChal> <sn>` line from the burn record, as it already does
    for `SIGN` lines (`main.go:9-10`). The secret then never reaches the node.
  - Run the canaries on the host: copy logread back and grep it there.
  - Amend config §5 step 8 (keep the secret on the bench host, or say why the two documents differ).
  - All of this goes in H0, and the burn record format becomes an interface in §6.

## MAJOR

### M1. The PR order ignores the gate set by E7 and E8, and the walking skeleton is upside down.

- **Scenario.** PR 2 (backend, boot flow, burn mode, `se-sign`) and PR 3 (endorsements in `node_cert`, the app
  verifier, vectors) are built and merged before the chip exists. Then E7 fails. Config §8.2 E7 says
  "停. K16 無法由設定達成 → 第 1 期不用背書, 回到設計" (stop; phase 1 drops endorsements and goes back to design).
  E8 failing likewise sends the design back. Field 9, the slot-2 trust for `ecdh_pub`, the `Endorsements()` method,
  P5 and half of `se-sign` are then rework. Meanwhile §9 lists `se-lab` (PR 4) last, although E0–E3 are the first
  thing done after soldering and they gate the config re-review.
- **Evidence.** Config §8.2 (E7 and E8 "停"); §8 last paragraph ("E4 以後要等本文件再審過": E4 onwards waits for
  this document to be reviewed again); target §9 row "—".
- **Fix.** Order the work as:
  1. H0;
  2. PR 1 (pure refactor);
  3. the `se608` driver core plus vectors plus `se-lab` (E0–E3 with no lock commands);
  4. on the chip: E0–E3, the config re-review, E4–E16;
  5. only then PR 2 (backend, burn) and PR 3 (protocol), written against what E7 and E11 actually showed.

  Write down which parts of PR 2 and PR 3 depend on E7, E8, E11 and E15.

### M2. The build-time backend flag (P2) is not fitted into the build, the release gate, the harness or CI. It also silently overturns config §9-5.

- **Scenario and evidence.**
  - (a) The flag is an environment variable, like `BATMAN_PROV_TEST` (`feed/batman-prov/Makefile:26-30`). OpenWrt's
    rebuild stamp does not include environment variables (`h23-review-v1-A.md:17`: `STAMP_PREPARED` is computed by
    `find_md5 ${CURDIR}`). After a chip build, a normal build reuses the stale chip helper, and the reverse. The
    `BATMAN_PROV_TEST` precedent needed `build-board.sh` stamp-and-clean logic, a version marker and a release gate
    (`254-h23-harness.md:173-177, 630, 654`). None of that is specified for `BATMAN_PROV_SE`.
  - (b) `/etc/batman-build` is written by the firmware fork's `stamp-batman-build.sh`, whose key list is fixed
    (`254-p2-impl.md:76`, F-P53). It has no key for the backend. The version string, the payload name and the
    OTA manifest do not tell the two images apart, so the harness cannot tell which image a node runs.
  - (c) CI runs `go test` with no tags and with `-tags prov_test` (`.github/workflows/ci.yml:146-155`; any SKIP is a
    FAIL). Code behind a new tag is compiled and tested nowhere unless a step for `prov_se` and for
    `prov_se,prov_test` is added. `dv-sbx.sh:69-81` builds only `prov_test` helpers.
  - (d) `dv-preflight.sh:101` refuses a `prov_test` helper; it has no rule for a chip image on a node the suite
    treats as a file node.
  - (e) Config §9-5 (reviewed) chose a **runtime** marker in the data partition, "so the same dev image can sit on
    both kinds of machine without violating K20 (review v2-B)". Config §7 says a reflashed card's burn mode "writes
    back the marker". P2 replaces both without saying so.
- **Fix.**
  - Add a P2 section covering: the Makefile tag; the `build-board.sh` and stamp changes in the firmware fork (a
    cross-repo PR, listed); a `BATMAN_SE=` key; a `--version` marker; release-gate assertions both ways; the payload
    and version naming; CI steps; `dv-sbx`; preflight.
  - Record P2 as a change to config §9-5 and §7, and update that document.
  - State the cost: one more image variant for bcm2711 to build, pin and validate.

### M3. The chip boot flow (§2.3) ignores the reconciliation that exists today and its p5 persistence. One of the rules contradicts a reviewed baseline.

- **Scenario.** §2.3 is a four-step flow. The real boot path (`boot/boot.go:75-290`) branches on the p5 return code
  (0, 7, 9, 10, 13, 1/8, 3, 11). It decides whether an identity is present with `identSum`, which calls
  `keystore.Load` and reads the `sha256` list (`boot.go:51-57`). It restores the identity from p5, persists it to
  p5 (`persistAll`) and generates in case 7 and case 9 (`:207, :231`).
  - The shell side hard-codes a 7-file identity with a sha list: `prov-lock.sh:7, :37`; `batman-config-save`
    `prov_ident_ok`, `identity_mismatch` and the `--prov-only` identity check (`:175-185, :229, :429-436`);
    `96-batman-config-migrate`, which carries the identity across sysupgrade; and the init `batman-prov-lock`.
    §2.4 says "four scripts, the list depends on `backend`".
  - Rule clash. §2.3 step 3 says "node id differs (HAT swapped) → old record void, unclaimed". The reviewed
    baseline P-U6 says an identity mismatch between overlay and p5 is **frozen**, "owner action or reflash needed"
    (`boot.go:113-115`; `batman-config-save:181-182, :429-432`). Two behaviours for one event.
  - Case 7 (new card, no prov) in a chip image: the design does not say whether the identity directory is written
    and persisted to p5. Case 9 (legacy; `prov-legacy-upgrade-254` drives this path deliberately) has no chip
    behaviour at all.
- **Fix.**
  - Write the chip backend as a column of the existing return-code table: per rc, what happens to the identity
    directory, to p5 and to the record.
  - Decide HAT swap against P-U6 explicitly. It is a change to the reviewed baseline, so it needs the user's
    approval.
  - Add p5 `identity/prov/`, `batman-config-save` and `96-batman-config-migrate` to the ownership table.
  - Simplest option: treat the chip image's identity directory as a cache derived from the chip, rewritten by the
    helper on every boot and never compared by sha. Only the record carries the device id binding.

### M4. The lifecycle matrix (§7) is missing the rows REVIEW.md requires and the rows the harness actually exercises.

Missing (behaviour today / after / test):

- **OTA chip image to chip image** (the normal path on the bench), including identity migration through
  `96-batman-config-migrate`, which hard-codes the file list.
- **OTA trial revert to the previous chip slot** (K13: still able to log in after the revert).
- **Autocommit commit and revert.** Commit requires the helper running and `provd-stable`
  (`batman-autocommit:500-515`), which is written only when provd connects to a serving helper
  (`stable.go:29-50`). With the 30 s retry, a chip that answers at 40 s commits the trial. Is that intended?
- **OTA from a file image to a chip image, and back** (an operator or harness pushing the v1.6 payload to the chip
  node). With an unclaimed node and no p5 prov, a file image reaches `boot.go` case 7 and `generate()`, so it
  **creates a file identity on a chip node** (K20) and persists it to p5. The chip image then reports "backend
  mismatch" for good. §7 calls this "developer error", but the harness does it routinely:
  - `prov-downgrade-254.sh:4-5` OTAs `DV_OLD_VERSION`;
  - `prov-legacy-upgrade-254.sh:4-6` strips the p5 prov and runs an old image;
  - `negctl-old-slot`.

  The design must either exclude these units on the chip node (and write the lost coverage into #255's checklist),
  or make it impossible.
- **Power loss during stage 2.** Slot 8 written and locked, but the identity directory not written. A re-run must
  accept a locked slot 8 whose read-back equals the cert. Stage 2's idempotency is not specified.
- **Helper restart.** Endorsements are made again with a new random nonce, so `node_cert` changes. provd's rebuild
  depends on the helper's `info.boot_id` poll (`server.go:442-449`). §3.1 deletes `boot_id` from `node_cert`
  without saying that the poll must stay (m5).
- **provd restart, helper crash loop, and bluetoothd restart** (a `node_cert` is held across a BLE stack restart).
- **The app holding records:**
  - (a) Reflashed chip node: the **same** device id, now unclaimed, while the app holds an owner record that pins
    the cert. Today a reflash gives a stranger, so this app path is new.
  - (b) HAT swap: a new id while the old record stays in "my nodes".
  - (c) A chip node's `node_cert` changing on every helper start, while `loginflow.rs:166-169` keeps
    `node_cert_raw` for join requests (`invite.rs:350, 422`). A join request made earlier carries an older cert's
    endorsements; check that `verify_offline` still passes.
- **Burn modes on a file-image node, and the chip image on a node without `/dev/i2c-1`.**

### M5. Stage 1 can lose the only copy of the claim secret and scrap the chip.

- **Scenario.** Stage 1 generates the claim secret from the chip's RNG in node memory, writes slot 5, locks the data
  zone, generates the keys, then prints the JSON over ssh (§2.5 step 1). If the ssh session drops or the node loses
  power at any point after the data lock and before the developer machine has stored the JSON, the secret is gone.
  Slot 5 cannot be read, so the chip can never be claimed. Config §8 leaves one spare chip.
- **Fix.** The host (`se-sign` / a burn wrapper) generates the claim secret, stores it first, and passes it on
  stdin to stage 1. Stage 1 writes exactly that value and echoes only its hash. Alternatively, stage 1 stops before
  the data lock until the host acknowledges. Either way, add an interrupted-ssh test to the fake-chip CI.

### M6. The fake chip is too weak, and the chip-node tests never reach the regular suite.

- **Scenario.** §4 describes the fake as "records commands, returns pre-recorded results". A replay fake cannot
  model the states CI must cover: resuming a burn from each lock state (config zone only; data zone; some key slots),
  the half-burned refusals, a locked slot 8 at stage 2 (M4), a chip that answers after N failures, or a CheckMac
  that must compare correctly.
  - §4 also promises a sandbox test "chip image never makes a file identity". `dv-sbx` runs a real helper binary,
    which has no way to load a fake I2C device. No seam is defined.
  - On the bench, every chip row of §7 says "bench" or "pull the chip", which is one-off. The project rule says each
    fix adds a real regression test to `daily-validation.sh` / `scripts/dv/`. No unit, node assignment or tier is
    defined.
  - The fake encodes the author's reading of cryptoauthlib, not the chip. This is the vcmailbox lesson (a stub in
    a different format from the real tool's output).
- **Fix.**
  - Make the fake stateful: config and data zones, lock bits, per-slot locks, real P-256 keys, the counter,
    CheckMac. Replace its status codes and byte formats with real E1/E7/E8/E14 captures once they exist.
  - Add a `prov_test` seam (for example a killpoint-style `se-fail` file) that makes the driver return "no response"
    on a real node. "Chip unresponsive at boot", "trial with a failing chip → revert" and "never a `node.key`" then
    become DV units on the chip node, not one-off pulls.
  - Name the units, the node and the tier in §4. Pulling the chip and swapping the HAT stay manual, and are listed
    as such.

### M7. K15: the login cost is neither stated nor measured, and it is not put to the user.

- **Scenario.** Every login now adds the following:
  - a GATT round trip (`id/prove`);
  - a chip nonce plus signature (up to 135 ms, config §2), or a software signature on file nodes, which today sign
    once per provd start;
  - waiting on the helper's **global** limit of 2 signatures per second (`node.go:376-388`), shared with claims and
    with other phones (#329 §4.3.7 has several phones). §2.6 does not say what provd does on `ERate` for `id/prove`.
    `buildNodeCert` retries at 1 s (`server.go:321-329`), which would add a full second;
  - a larger msg2 (two endorsements of about 116 B each, plus field 8, plus a CA-signed cert), so more BLE
    fragments.
- **Baseline.** #329: one login plus a status read takes 2.8–5.6 s; 9 of 10 logins finish in 20 s or less
  (`329-app-uiux.md:998, 1021`). §2.1 says only "登入只多一次簽章" (login adds only one signature). Config §9-13
  requires that the difference be measured and reported. K15 (`255-key-authority.md:83`) requires that any
  regression be written down and decided by the user.
- **Fix.** Add a measurement plan: the same phone (S20) and the same R-7 procedure, 10 logins on a file node and on
  the chip node, before and after. Give the expected delta. Specify the `ERate` behaviour for `id/prove`. Add a row
  to §10 for the user's decision.

### M8. `se-lab` is a second program commanding the chip. That breaks C9 / K21, and it races the helper.

- **Scenario.** `tools/se-lab` runs on the node (§5) while `batman-provhelper` is running, and both open
  `/dev/i2c-1`. The 608's TempKey and the wake/idle state are shared across I²C transactions. An `se-lab`
  GenDig or Nonce issued between the helper's Nonce and Sign corrupts the helper's signature, or makes E7 judge a
  mixed sequence. The ownership table (§6) itself names two writers for the chip. C9 (config §1: "燒錄也由 helper
  的燒錄模式做, 不另開程式", burning too is done by the helper's burn mode, no separate program) and K21 are rules
  that do not yield.
- **Fix.** Either make the experiments a helper mode built only with a lab tag, or have `se-lab` refuse to run while
  `pidof batman-provhelper` is non-empty (stop the helper's init first and check). State that the experiment node is
  not one the suite uses. Record the C9 deviation, if one is kept, as accepted by the user.

### M9. The §4 file inventory is incomplete. Several harness items are missing and some are miscounted.

Not listed, but they need changes:

- `tests/tools/provclient/main.go:517` (B2);
- `app/tools/synth-joinreq/src/main.rs` (builds `sig_static` / `boot_id`);
- `tests/tools/peer/netobj.py`;
- `tests/vectors/219-protocol/ci-check.sh` with `MIN_CHECKS=195` (`ci.yml:93`). Dropping the `sig_static` checks
  changes the count, so the gate has to change in H0;
- `app/tools/check-field-build.sh` (X3). It must assert that the **dev root public key** is absent from a field
  build;
- `app/rust/bridge/src/api/replay.rs` and `replayflow.rs:176`. §3.2 lists the call sites of `ecdh_pub` but not the
  third handshake verifier (`replayflow`), which must also send `id/prove`;
- `tests/prov-p1/{cfgsave-*,prov-lock-init,sbx/cases/{cfgsave,helper}}.sh` and `tests/wbox/96-no{prov,restore}.patch`,
  which encode the 7-file identity;
- the Go CI tag step (M2).

My own count: 47 files across `scripts/`, `tests/`, `app/` and `feed/batman-provision/` reference identity files,
`claim.secret` or the `sig_*` labels, plus about 25 units that reach `claim.secret` through `provclient`. The design
says about 35 plus 4.

### M10. PR 3 is a flag day in the middle of the v1.6 validation, and no dual-version harness is planned.

- **Scenario.** Another session is running v1.6 validation on 02 and 04 (both Pi 4, `docs/boards-and-builds.md:13`).
  Once PR 3 merges, main's product speaks `node_cert` v2. If the H0 harness speaks only v2, every run of main's
  harness against a v1.6 node fails, and the rule is that shipping is judged only by main's harness. If the phone
  app is updated (`adb install -r` only), it can no longer log in to v1.6 nodes.
- **Fix.**
  - Make H0's tools accept v1 and v2, dispatching on the key set.
  - Schedule PR 3 to merge after v1.6 is closed, or state how the phone runs two app builds.
  - Note in P7 that the file-style pins survive. The app pins the DAC DER (`nodecert.rs:126-133`), which is
    unchanged in the file style, so 02 and 04 do **not** need to be reclaimed. "bench 節點會重燒、重新認領" (the
    bench nodes will be reflashed and reclaimed) applies only to chip nodes.

## MINOR

1. **`identity-info` is a mechanism with no present need.** §2.4 already writes `backend`, `device_id`, `chip_sn`
   and `cert` as files for the shell. The scripts can read those. Drop the command, or keep it to one line of
   `backend`.
2. **The 30 s retry loop (§2.3) contradicts config §7** ("retry once on each login attempt; do not latch"). Pick one,
   and state how it interacts with the trial window (M4, autocommit).
3. **The counter has two owners.** `claimed_counter` lives in the provisioning record (`provstore.go:52, :94`;
   increments in `node.go:592`), not in the identity files. Putting `Counter()` / `CounterInc()` in `Identity`
   makes the counter owned by both the record transaction and the identity. Chip increments are not transactional
   (they survive a rolled-back claim). Give it one owner and state what `info.counter` returns after a reflash
   (record 0, chip N).
4. **Wrong fact in §3.2.** "verify_offline: 檔案樣式照舊" (file style unchanged) cannot hold: field 5 is deleted for
   both styles, and the check for exactly keys 1–7 (`nodecert.rs:164-166`) must change.
5. **Say that provd's `info.boot_id` poll stays** (`server.go:442-449`), now to rebuild `node_cert` when the
   endorsements change, even though field 3 is removed.
6. **Negative controls (§4) "first fail on the old program".** For the chip-image cases there is no old program.
   Name the mutant instead: a `wbox` patch that falls back to the file backend, which must fail the "no `node.key`"
   test.
7. **Image contents.** `kmod-i2c-bcm2835`, `kmod-i2c-dev` and `dtparam=i2c_arm` in the chip image (through the
   board diffconfig, never a bare `make defconfig`). They are not in the design; E0 depends on them.
8. **Slot 8 is locked with a cert under the dev root.** If the dev root key on DSKT-MOONLIGHT is lost or rotated,
   every burned bench chip is scrapped. Q2 should cover backup and recovery, not only where the key is kept.
9. **Q1 assumes "a spare Pi 4 and a spare HAT".** Only 02 and 04 are listed as Pi 4 (`boards-and-builds.md:13`). The
   U3 pad sits on the WM1302 carrier that also carries HaLow. Check whether a spare HAT without HaLow can join the
   mesh units. ⚠️ Unverified.
10. **`id/prove` signs any `h` that provd forwards.** A compromised provd gets an oracle for
    `"batman-node-session-v1" ‖ X`, the same exposure as `sign.peer` today (`node.go:412-430`). State it in §8.
    On an unclaimed node, anonymous `id/prove` calls consume the global 2/s budget (M7).
11. **`fakeMsg2` length.** It must stay equal to the real msg2 length (`noise.go:108-109`, F-P13) as `node_cert`
    grows. Add a test, and check the frame and MTU limits against the chip-style size.
12. **Deferred items go into the #255 checklist.** `peers/challenge`, the removal of `verify_offline` in phase 2,
    §11 and the units excluded on the chip node (M4). Do not leave them only in this document.

## Wrong or unverified facts in the target

- §1 "約 35 個檔案 + 4 支節點腳本": the count is wrong and the scope is too narrow (M9, M3).
- §2.1 `Counter()` "檔案欄位（今天的 `claimed_counter`）": it is a record field, not an identity file (minor 3).
- §2.4 "四支腳本寫死檔案清單": the hard-coded file list also lives in Go (`keystore.Files`, `boot.identSum`),
  `batman-config-save`'s `identity_mismatch` / `--prov-only` checks and `96-batman-config-migrate` (M3).
- §3.2 `verify_offline` "檔案樣式照舊": wrong (minor 4).
- §4: `provclient` is counted as a peer tool. It is the reader of the claim secret (B2).
- §7 row "檔案映像刷到有晶片的機器 = 開發者的操作錯誤": the harness does this on purpose (M4).
- §9 PR 1 "行為不變": contradicted by §2.1 and P6 (B1).
- Checked and correct: `keystore.go:69, :266-267`; `server.go:306-363, :530-532`; `nodecert.rs:89-123, 146-156,
  161-170`; `proto.go:54-70`; `claimflow.rs:172`; `noise.go:105`; `node.go:376-388, 412-430`; `main.go:598-623,
  632-636`; `stable.go:30-51`; `329-app-uiux.md:998, 1021`; `dv-sbx.sh:69, 80`; `gen.sh:40`.

## Which PR can start first

**H0 (harness, dual-version), then PR 1** narrowed to a pure refactor: `Identity` interface plus the file backend,
with today's `SignPurpose`, no `identity-info` and no script changes. The driver core with vectors and `se-lab`
(E0–E3, no locks) can follow in parallel. PR 2 and PR 3 wait for E7, E8 and E11 (M1).
