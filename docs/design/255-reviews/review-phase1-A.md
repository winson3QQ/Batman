# Review of `255-phase1-impl.md` v1 — Reviewer A (security and protocol)

Base: main 4eba26d, worktree `C:/src/Batman-255`. Read: `REVIEW.md`, the target, `255-608b-config.md` v3, `255-key-authority.md` v3.1, `255-reviews/608b-facts.md`, and the code cited below. Read-only; no node or network contact.

Verdict: **REJECT** (1 BLOCKER / 7 MAJOR / 14 MINOR). The direction (build-time backend, per-session proof over `h`, endorsements rebuilt from constants, dev root kept off the node) is sound. The blocker has a one-line fix. Most of the majors come from the same gap: the design describes the new chip path, but not how it fits the existing boot reconciliation, trial and commit, persistence, and the single-owner rule for the chip.

PR 1 answer is at the end.

---

## BLOCKER

### B1. File profile: field 8 (`session_pub`) is not bound to anything, so the per-session proof can be forged from a replayed `node_cert`

- **Scenario.** `node_cert` is public. On an unclaimed node anyone gets it in the NX msg2, and any login sees it. §3.1 gives the file profile a field 8, "DAC 公鑰（與憑證相同）". §3.2 then says: "以第 8 欄驗 `batman-node-session-v1 ‖ h`". The only checks listed for a profile are "欄位組合必須完全符合該樣式", which is about which fields are present, plus the profile-specific checks; none of them says field 8 must equal the cert key. An attacker replays node X's file-profile `node_cert` with field 8 replaced by its own key, then signs the `id/prove` for its own `h`. The pinned DER matches (`nodecert.rs:128`), `sig_ecdh` still verifies with the cert key, and the proof verifies with field 8. The result is full impersonation of X, including the owner-auth flow that follows. This is the exact case K20's "proof is live" is meant to stop. Today it is stopped because `sig_static` is checked against the cert key (`nodecert.rs:107-112`); v2 deletes that check (P6).
- **Evidence.** `255-phase1-impl.md` §3.1 row 8, §3.2 bullets 1 and 3; `nodecert.rs:89-123` (all of today's signatures are verified with `dac_pub` taken from the cert, `:97`).
- **Fix (narrow).** Delete field 8 from the file profile and verify `id/prove` with the cert's own key. In the chip profile, field 8 is accepted only as the key that the slot-0 endorsement covers, rebuilt with the slot-0 constants (slot number, SlotConfig, KeyConfig). State the rule as "the proof key is always derived (file: cert key; chip: endorsed slot-0 key), never taken from an unverified field".
- **Negative control.** File `node_cert` with field 8 present (or replaced) → rejected. Chip `node_cert` with field 8 replaced by a key that is not endorsed → rejected. A naive implementation of §3.2 as written passes both, so the test discriminates.

## MAJOR

### M1. `id/prove` shares the helper's 2/s global signing limit, so members and strangers can deny owners' logins

- **Scenario.** `n.sign` rejects with `ERate` once two signatures are made in a rolling second, globally (`node.go:376-388`). §2.6 lets every role, anonymous included, send `id/prove` once per connection; §6 says that if `id/prove` is missing, the app rejects the connection.
  - Every network member knows `psk_member` (`node.go:449-451`). It is derived from `net_root`, there is no revocation (key-authority §2-9), and a removed member keeps it.
  - On unclaimed nodes anyone gets NX.
  - provd has 2 BLE+sock slots plus 2 HTTP slots, with eviction of the oldest session (`session.go` ~812-830, `http.go:31`).
  - A member script that connects, sends `id/prove` and reconnects keeps the global budget used up. The owner's `id/prove` then gets `ERate` and the app drops the login. The same limiter also starves `buildNodeCert` after a provd restart: 5 tries, then give up (`server.go:323-335`).
  - "登入只多一次簽章" (§2.1) counts signatures but ignores contention. K15 (phase 1 bound) requires the login-time delta to be measured (config §9-13); §4 and §9 contain no such measurement.
- **Fix.**
  - Take `id/prove` out of the global limiter. Bound it structurally instead: one per session (already planned), plus the existing slot cap and handshake cost. The chip itself caps signing at about 8/s (Sign ≤ 115 ms, F§9).
  - Or keep a limiter but reserve it by role, so that owner and replay sessions are never starved by member or anonymous ones.
  - The app retries `ERate` with backoff inside the login budget, rather than treating it as rejection.
  - Add the K15 measurement against the #329 baseline (`329-app-uiux.md:998, 1021`) to §4.
- **Negative control.** Two member sessions hammer `id/prove` while an owner logs in. The owner login must succeed within the baseline. It fails with the current limiter.

### M2. K20 is waived by the author rather than met; P2 drops the base design's marker; the build variant cannot be identified on the artifact; the downgrade row is missing

- **K20 is waived, not met.** K20 says "任何情況下都不產生或退回軟體身分" (key-authority §3; binding on phase 1, §3 last paragraph). §7 row 4 records a K20 violation (a file image on a chip machine generates a file identity) and declares it a developer error. The author cannot waive a binding rule. The user has to accept it as a deviation, or the design has to narrow it.
- **The base design's marker is dropped silently.** `255-608b-config.md` §9-5 specified a chip-identity marker on the data partition so that one dev image works on both kinds of machine without violating K20 (review v2-B). P2 replaces it without saying so.
- **Wrong image, same version.** `BATMAN_PROV_SE` is an environment build flag, like `BATMAN_PROV_TEST` (`Makefile:23-30`).
  - The two variants share `PKG_VERSION` and the image version.
  - The OpenWrt package cache can reuse a helper built with the other flag.
  - One tree builds two boards with the same version (bcm2711 and bcm2710; project memory, build-3aplus).

  A "chip" image can therefore ship the file-backend helper, and nothing on the artifact shows it.
- **Downgrade and rollback row is missing** (REVIEW.md §3). Two cases:
  - A chip node is OTA'd, or reverted, to a file-backend or pre-#255 image (both A/B slots are not guaranteed to hold a chip image). The old helper's `keystore.Load` refuses `backend=se` (`keystore.go:266-267`), so `identSum` fails (`boot.go:51-57`). Depending on the `--prov-get` rc, the node either serves nothing (`main.go:632-636`), which violates K13 "回退時仍可登入", or reaches `generate()` on rc 7 or 9 (`boot.go:207, 231`), which produces a software identity on a chip machine and violates K20.
  - `prov_ident_ok` in the old scripts requires the 7-file sha list (`prov-lock.sh:7, 37-38`; `96-batman-config-migrate:160`), so the se directory is never restored into the overlay.
- **Fix.**
  1. Record the deviation from config §9-5 and from K20, and ask the user to accept it (Q3).
  2. Or narrow it: a post-#255 file-backend `Generate` refuses when a chip-identity marker exists on p5. The marker is written by burn stage 2 or by reconciliation. This only ever refuses; it never makes a software identity appear on a chip machine.
  3. Make the backend visible on the artifact: `--version` and `/etc/batman-build`. The release gate checks it the same way it checks the `prov_test` strings.
  4. Set the flag per board.
  5. Add the downgrade and rollback rows with tests. A chip image must not be installable over A/B with a non-chip other slot, or the revert target must be stated.
- **Negative controls.**
  - A file image whose p5 carries the marker → no `node.key` is created.
  - A chip-flag build artifact is checked to contain the se backend; this fails on a stale build.

### M3. §2.3 does not fit the existing boot reconciliation, and the "30 s retry" is new behaviour that can break the commit gate

- **Scenario.**
  - `boot.Run` runs before the identity load (`main.go:631`). It decides everything from `identSum` = `keystore.Load` plus the `sha256` file (`boot.go:51-57`): restore from p5, persist, the identity-mismatch freeze (`boot.go:149-151`), and generation on rc 7 or 9. §2.3 replaces none of this and does not say what `Generate` is in a chip image.
  - The se directory (§2.4) has no `sha256` and no private key. As written, `identSum` would be false for every se node, which leads into the generate and restore branches.
  - §2.3 says "沿用今天的機制，不新增". But today a helper without an identity blocks forever (`main.go:632-636`, `select {}`); it never retries.
  - The planned 30 s retry and the "回報狀態" output need a loop and some reporting channel. The commit gate needs only a 60 s provd connection to the helper socket (`stable.go:30-51`, wired at `main.go:705-707`; `batman-autocommit:500-505`). It does not check the identity. If the implementation opens the helper socket to report "燒錄未完成" or "身分不可用", provd connects, `provd-stable` is written, and a trial whose chip path is broken gets committed. That is precisely the outcome config §7 (review v2-B) forbids.
- **Fix.**
  - Specify per backend: `identSum` for se means the directory is well-formed, `device_id` = SHA-256(slot-1 pub)[:9] read from the chip, and the cert key equals the slot-1 pub. `Generate` is nil in the chip image, and rc 7 or 9 with no identity → `unknown(no-identity)`.
  - Keep the identity-mismatch freeze.
  - The helper socket is not opened, and `stableWriter` is not armed, until the identity is ready. Status goes only to the log and the p6 `prov-state` line.
  - The retry loop sits before `srv.Listen`.
- **Negative control.** A trial boot with the chip held off the bus but the status channel open → must revert. A naive implementation that "reports status" over the socket commits, so the test discriminates.

### M4. A HAT swap automatically voids the record ("舊紀錄作廢 → 未認領"): an unauthenticated state reset by a 5-minute physical actor

- **Scenario.**
  - §2.3 step 3 and §7 "換 HAT": a node id mismatch voids the record and the node becomes unclaimed. Anyone with five minutes and a screwdriver resets ownership without any owner signature.
  - Nothing says what happens to what the record governed: mesh keys in uci, `authorized_keys`, the root password, the p5 copy, and the network membership. The next claimer of the "unclaimed" node may inherit them; claim gives root and SSH (`node.go` ~460-600).
  - With a genuine chip moved from node A into node B's Pi, B's Pi becomes A. Board binding is deferred (config §10), but the automatic void makes it silent.
  - Today's rule for the equivalent case is the opposite: an identity mismatch freezes the node until the owner acts or the card is reflashed (`boot.go:5-7, 149-151`, P-U6).
  - The base config §9-6 also says "作廢". That is a base-design issue this review flags too.
- **Fix (remove).** A node id mismatch → `unknown(identity-mismatch)`, frozen and not serving, exactly as today. Recovery is a reflash, which already clears the record.
- **Negative control.** Swap HATs between two claimed bench nodes → both are frozen, no record is rewritten, and the mesh keys and SSH keys are untouched. With the §2.3 text, the node becomes claimable.

### M5. The chip has more than one writer: the daemon, `--se-burn`, `se-lab` and possibly `identity-info` all reach the bus

- **Scenario.**
  - §6 makes the helper, "含燒錄模式", the single owner. But `--se-burn` is a separate process of the same binary, run while the daemon runs (the daemon is waiting on an unburned chip, and per §2.3 retries a non-responding one every 30 s).
  - `se-lab` is a third program that opens `/dev/i2c-1` on the node (§5).
  - `identity-info` does not say whether it reads the directory or the chip.
  - The 608's TempKey is shared, volatile state:
    - a wake, sleep or Nonce from one process between another's Nonce and Sign, GenDig and Sign, or Nonce and GenKey changes or clears it (F§ watchdog and sleep, `608b-facts.md:293`);
    - burn sequences can then fail midway (keys generated but not locked = a wasted chip, §2.5);
    - more seriously, E7 and E8 "should fail" results can fail for the wrong reason (TempKey invalidated by the daemon) and be read as "K16 holds". E7 is the experiment that decides whether K16 is achievable at all. A control on slot 4 only helps when the interference does not land on it.
  - K21 and C9 ("節點上只有 helper 能對晶片下指令…不另開程式") are bound on phase 1. `se-lab` violates them and no exception is recorded.
- **Fix.**
  - One owner: every chip access takes an exclusive `flock` on a root-only run-dir file (`/var/run/batman` from #280, not `/tmp`).
  - `--se-burn` and `se-lab` refuse to run unless the daemon is stopped (procd) and the lock is free.
  - `identity-info` reads only the directory.
  - Record a K21/C9 exception for `se-lab` on sacrificial chips, approved by the user.
  - Experiments assert the exact status code (config §8 asks for it) and run with the daemon stopped.
- **Negative control.** Run `--se-burn` or `se-lab` while the daemon holds the lock → refused. Without the lock, the test shows interleaved commands (recorded by the fake chip).

### M6. The burn flow has irreversible single points of failure that the design does not handle

- **(a) The claim secret can be lost forever.** The secret is written to slot 5 and the data zone is locked before stage 1 prints its output (§2.5: the output comes after key generation). Slot 5 is IsSecret, cannot be read, and is permanent. An SSH drop, a timeout or a power loss after the data lock loses the claim secret forever, and the "resume from the lock state" rule cannot recover it. The chip can never be claimed.
- **(b) The secret comes from the chip's RNG.** Before the config lock, the RNG returns the test pattern `FF FF 00 00…` (`608b-facts.md:339`). The 608's behaviour has not been confirmed. Any ordering mistake or misread lock state burns a public constant into slot 5 permanently. The chip RNG gives no benefit here, because the secret crosses the bus in the clear on Write.
- **(c) Stage 2 can lock the wrong certificate into slot 8.** Stage 2 writes slot 8, reads it back and locks it, without checking that the cert's key equals this chip's slot-1 public key (§2.5 step 3). If certs from two chips burned in one session are swapped, a wrong cert is locked into slot 8 and the chip is wasted.
- **(d) The trial watchdog can reboot the node mid-burn.** If the chip image is on a trial slot (an OTA instead of a reflash), the helper never serves, so the trial reverts. The revert watchdog reboots the node partway through the burn (`batman-autocommit:192-255`).
- **(e) The secret can leak into logs.** The stage 1 output, and the burn record that DV reads (§4 row 1), contain the claim secret. The project's habit is to attach raw output to PRs and issues. The secret can end up in a harness log or a PR body, and it can never be rotated.
- **Fix.**
  - The developer machine generates the secret with its own CSPRNG and passes it to stage 1 on **stdin**, not argv (`/proc/*/cmdline` is world-readable). Stage 1 writes the secret only after the developer machine has persisted it.
  - Stage 2 verifies the cert key == slot-1 pub, the issuer == the dev root, and CN == `se:<device_id>` before the lock.
  - The burn refuses on a trial slot (`trial.go` `execIsTrial`).
  - Output goes to a 0600 file on the developer machine, never to the terminal or a log, with a redaction rule in the harness.
- **Negative controls.**
  - Kill the SSH session after the data lock (fake chip): the secret is still recoverable from the developer machine.
  - A wrong cert in stage 2 → refused before the lock.
  - The burn on a trial slot → refused.

### M7. Non-root and tenant access to `/dev/i2c-1` is only listed as unverified (§11); nothing enforces it

- **Scenario.** Anyone who can open `/dev/i2c-1` gets:
  - a slot-0 oracle, which forges `id/prove` live;
  - a slot-2 ECDH oracle: with the stored `net_secrets` ciphertext (wtxn.go:131-146, KDF via `n.KS.ECDH`) or the owner enc pub (`node.go:445`, `psk_replay`), this yields network secrets and replay PSKs. That is network-root-equivalent.

  The actors are a local non-root process, and a tenant container with devices or `--privileged`. Config §9-8 requires that only the helper opens the chip. The impl turns that into an E0 observation rather than an enforced property.
- **Fix.**
  - The chip backend refuses to start unless `/dev/i2c-1` is a character device, not a symlink, owned root:root with mode 0600 (`lstat`). This is set by a hotplug rule shipped in the chip image.
  - The tenant runtime denies the device. State the actor analysis in §8.
- **Negative control.** As the provd uid, and inside a tenant container: `open("/dev/i2c-1")` → EACCES. With default permissions it succeeds, so the test discriminates.

## MINOR

1. **Low-s normalisation.** Chip ECDSA output is high-s about 50% of the time. The project rejects high-s (`proto.go:117`; `219-protocol.md:321`; `sig.rs:121`). The helper must normalise `s` for both `id/prove` and the endorsements. Otherwise the helper's own endorsement self-check (§2.3 step 3) fails on about half of all boots, and trials revert at random. Add a vector with a high-s chip signature.
2. **`SignSession(label, h)` takes a free label.** Make it a fixed enum of purposes. The future `peers/challenge` (§2.6) must use a distinct label and include `nonce_node`, like today's `PurposePeer` (`keystore.go:75, 88-91`). Otherwise an `h` supplied by a peer becomes a cross-session `id/prove` oracle.
3. **A compromised provd is a live oracle.** It supplies `h` to the helper, so it can obtain `id/prove` for any `h` (the helper cannot check `h`) and relay proofs live. This matches today's `sign.static` exposure, but it contradicts the wording of config §2 "由 helper 組成" and must be stated as a residual risk. Endorsements and proofs cannot be replayed across sessions; the test for that is listed.
4. **The dev-root signature attests only burn-time custody.** `se-sign`'s checks (the config readback and the endorsements) are reported by the node. A compromised node can present a software "slot-1" key with self-made endorsements. State this, and require burning only from a freshly flashed card.
5. **`verify_offline` without `h`** (the three-step join) is a K20 "live" deviation in phase 1. Record it with user acceptance; it ends with Q5. It is not "照舊": `sig_static` is gone and the key-set check at `nodecert.rs:164` changes.
6. **Claim persists before the proof.** `claimflow.rs:168-182` persists the pending record at msg2, before `id/prove`. Move `PersistPending` after the proof.
7. **Endorsement rebuild needs stated inputs and negative vectors.** State that `sn` = field 7 and that the full-SN mode is required, so `sn` is authenticated by the endorsements. Add negative vectors:
   - a mutation of each byte of the 55-byte message;
   - endorsements 0 and 2 swapped;
   - a chip cert with field 6 present;
   - a chip cert that is self-signed, or a `dev:` CN signed by the dev root;
   - a field build (no `dev-trust`) given a valid chip `node_cert`, through both `verify_first_contact` and `verify_offline` → `Untrusted`.
8. **`CounterInc` placement.** It must run only after a successful CheckMac (`node.go:574`), inside the claim transaction (`node.go:592`). `Counter()` on `Identity` mixes ownership with the record: `claimed_counter` is a provstore field, not an identity file.
9. **Ownership table misses identity-directory writers.** `96-batman-config-migrate:160-163` and `batman-config-save` (persist, `:521-536`) also write the identity directory. The `backend` file now chooses its own integrity list. Define the integrity check for the se directory, for example a sha list of its four files.
10. **Missing lifecycle rows** (REVIEW.md §3):
    - OTA stage 1 and 2 between chip images;
    - autocommit commit;
    - helper restart (the endorsements are regenerated; provd's node_cert rebuild trigger was `boot_id`, which v2 deletes, `server.go` pollLoop);
    - crash loop mid-sequence;
    - power loss during claim (counter versus commit);
    - dependency restart (i2c kmod and `dtparam`);
    - the bcm2710 build from the same tree.
11. **Test-only code must not reach a release image.** The release gate must reject the fake chip, the no-lock build and the `prov_test` × SE combination. `se-lab` runs only from `/tmp` (tmpfs), and DV checks that it is absent from the overlay. Its refusal rule as written ("拒絕…E7–E13 以外的寫入") **allows** E7–E13 on an identity chip: E11 increments the permanent counter, and E7(j) or E9 destroy the chip if an expectation is wrong. Refuse any chip whose SN is not on a sacrificial allow-list that the developer machine passes in.
12. **No K15 timing measurement** in §4 or §9 (config §9-13).
13. **Dev root and burn record custody.** The dev root private key must be encrypted at rest and covered by gitleaks. The burn record keeps the claim secret, which contradicts config §5 step 8 ("印成機身 QR 後從燒錄紀錄刪除"). The QR image file is another copy.
14. **Field 2 (`s_node`) in v2 is now redundant,** because `h` covers `rs`. Either drop it or keep the `rs` check explicitly. Do not leave it as an unchecked field.

## Wrong or unsupported facts

- §1 cites `server.go:16` for "provd 只透過 helper 拿結果". That line is the `flynn/noise` import.
- §1 and §2.1 say "檔案欄位（今天的 `claimed_counter`）". It is a provstore record field (`node.go:592`), not an identity file.
- §2.3 says the trial path "沿用今天的機制，不新增". The 30 s retry is new: today the helper `select {}`s forever (`main.go:632-636`).
- P2 says "K20 由構造保證", while §7 row 4 records a K20 violation. P2 also silently reverses config v3 §9-5.
- §3.2 says `verify_offline` "檔案樣式照舊". It is not: `sig_static` is gone and the exact-key-set check changes.
- §2.5 and §6 keep the claim secret in the burn record, which contradicts config §5 step 8.
- §2.1 says "槽 0 簽（外部簽章，含亂數 nonce）". This is ambiguous. ReqRandom does not list external Sign (`608b-facts.md:145`), and an external Sign signs the digest the host loads (pass-through). Say exactly which digest is signed: SHA-256(label ‖ h), loaded by pass-through Nonce, plus the RNG seed refresh.

## Verified correct (spot-checked)

`keystore.go:34-40, 69, 266-267`; `main.go:484, 598-623, 632-636`; `boot.go:189-231`; `server.go:306-363`, readiness at about `:528-532`; `nodecert.rs:89-123, 146-156, 161-170`; `proto.go:48-70`; `claimflow.rs:172`; `wtxn.go:132-135`; `session.go:68-69`; `node.go:376-388, 412-430`; `stable.go:30-51`; `batman-autocommit:192-255, 500-515`; `noise.go:105`; `Makefile:23-30`; `dv-sbx.sh:69, 80`; `gen.sh:40`; the ecdh_pub users in joinflow, rekey, join2flow and updflow. The handshake hash `h` is the same value on both sides (`noise.go:105` ChannelBinding; `noise.rs:117` `get_handshake_hash`) and is already used for claim and owner-auth with vectors. A field build still rejects both profiles **if** the new chip branch is gated on `DEV_TRUST` and is evaluated after the existing `dev:` / `Untrusted` logic (`nodecert.rs:146-156`). There is no test for this yet (minor 7). `verify_pinned` has no trust gate (`nodecert.rs:126-132`), which is safe only while a field build can never pin a record.

## PR 1: may it start now?

**Yes, narrowed.** PR 1 may start as a pure mechanical extraction: an `Identity` interface carrying exactly today's methods (`SN`, `DeviceID`, `Cert`, `DACPub`, `ECDHPub`, `ECDH`, `CheckMac`, `SignPurpose`, `Backend`). The negative control is that every existing Go test and protocol vector is unchanged, byte for byte.

Not in PR 1:
- `SignSession`, `Endorsements`, `Counter`, `ChipSN`: their shape depends on B1, minor 2 and minor 8.
- `identity-info` and the script and DV changes: by the project's one-validation-set rule, the harness change goes into main first as its own PR, and its design depends on M2, M3 and minor 9.
