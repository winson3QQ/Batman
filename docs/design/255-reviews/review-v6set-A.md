# Review v6set-A: 608B config v6 + phase-1 implementation v4

Reviewer A (security, protocol, chip behaviour). Read-only on `C:/src/Batman-255` at e9eca58 and PR 1 in
`C:/src/Batman-255pr1` (85e1086). No device or network contact. Read order: REVIEW.md, both targets in full,
key-authority K13–K21, threat model, the cited source, then review-v5set-A/B and v6set-changes.

Result: **0 BLOCKER / 2 MAJOR / 15 MINOR.**

## 1. Config bytes, decoded again

I decoded §4 and §8.1 myself (SlotConfig: ReadKey 0–3, NoMac 4, LimitedUse 5, EncryptRead 6, IsSecret 7,
WriteKey 8–11, WriteConfig 12–15; KeyConfig: Private 0, PubInfo 1, KeyType 2–4, Lockable 5, ReqRandom 6, ReqAuth 7).

| Slot | SlotConfig | KeyConfig | Decoded | Matches the text |
|---|---|---|---|---|
| 0 | `0x2081` | `0x0073` | ext-sign only; IsSecret; WriteConfig 0010 = GenKey yes, PrivWrite no; P-256 private, PubInfo, lockable, ReqRandom | yes |
| 1 | `0x2082` | `0x0073` | int-sign only; same | yes |
| 2 | `0x2084` | `0x0073` | ECDH, bit 3 = 0 (clear); same | yes |
| 5 | `0x8F9F` | `0x001C` | ReadKey F, NoMac, IsSecret, WriteConfig 1000 never; KeyType 7, not lockable, no ReqRandom | yes |
| 8 | `0x0F0F` | `0x003C` | clear read, Always write; KeyType 7, lockable | yes |
| unused | `0x8F9F` | `0x001C` | as slot 5 | yes |
| 3 (variant) | `0x0F8F` | `0x003C` | IsSecret, no NoMac, Always write; differs from slot 5 in NoMac, WriteConfig, Lockable | yes |
| 4 (variant) | `0x2083` | `0x0073` | ext + int sign, same WriteConfig as 0–2 | yes |
| 6 (variant) | `0x0F0F` | `0x003C` | as slot 8 | yes |

Bytes 16 `0xC0`, 18 `0x00`, 19 `0x00`, 68–83 `0`, 88–89 `FFFF`, 90–91 `0000`, 92–95 `0` all decode as stated.
No WriteKey / ReadKey / AuthKey points at slot 5 in either image (slot 4's WriteKey is 0). Slot 5 is odd, so its
CheckMac/Copy target is itself (ReadKey F). The post-burn values 86 = 87 = `00`, 88 = `F8`, 89 = `FF` are right for
"both zones locked, slots 0–2 locked, slot 8 not". The experiment order (§8.1) respects every dependency I can
find: E8/E10/E15 after E6's data lock; E9 needs slot 4 locked (E17) and slot 0 empty (before E10); E13 locks slot 6
only after E9 used it as a control.

## 2. Findings

### MAJOR

**M1. The chip-profile certificate does not fit in slot 8.**
- Scenario. PR D's first job is "先算憑證大小". The profile in impl §3.1 (issuer = dev root, subject CN `se:<id>` +
  serialNumber `<id>`, P-256 SPKI, validity 2020 → 9999-12-31, BasicConstraints CA:FALSE, a private OID with CBOR
  `{0: 33 B, 2: 33 B, 7: 9 B}`) is larger than 416 bytes. E15 then sends the design back ("放不下 → 回到設計"),
  after PR D has built `se-sign`'s cert part, the fake chip's slot 8 and the H2 vectors around it.
- Evidence. I built the profile with Python `cryptography` 49.0.0, serial 1, issuer CN `batman-dev-root`, OID
  `1.3.6.1.4.1.99999.255.1`, 200 keys: **448–450 bytes**. The CBOR extension alone is 84 bytes. Trimmed hard (issuer
  CN `d`, no BasicConstraints, a shorter OID): **418–420 bytes**, still over. Slot 8 is 416 bytes (F§13). The
  subject repeats `device_id` twice (CN and serialNumber, ~60 bytes) because `common()` requires serialNumber
  (`nodecert.rs:118-121`).
- Why MAJOR, not a PR detail: §3.1 is the protocol contract that PR D, H2 and PR 3 all build on, and the number is
  computable now. The design's own fallback ("not on the chip needs a redesign") is the expensive branch.
- Fix (pick one now, write it in §3.1 and remove the ⚠️ in §11):
  1. Chip profile without the subject serialNumber attribute (`common()` keeps the serialNumber rule for the file
     profile only; chip profile already pins `device_id = SHA-256(subject key)[:9]` and CN), no BasicConstraints
     (the app never builds chains), short issuer CN. My estimate: ~390 bytes, about 25 bytes of margin for the
     ECDSA length and the OID. Confirm with the same script in PR D before anything else.
  2. Or keep the profile and store it in slot 8 + one 72-byte slot (9 or 10) made Always-write in the final image.
     This changes the final image (not the variant), so it does not touch E4.
  Either way, PR D computes the size as its first commit, and E15's stop rule stays.

**M2. `CheckMac` still swallows chip errors; the "chip errors are transient" rule does not hold for claims.**
- Scenario 1 (owner replay). The chip hiccups during `claim.replay`. The chip backend can only return `false`
  (`identity.go:21-22`: `CheckMac(clientChal, response []byte) bool`). `claimReplay` then calls `failOnce(EForbidden,
  "CheckMac")` (`node.go:662-663`), which adds to `replayF`; ten such failures in an hour lock the owner out of the
  recovery path for an hour (`node.go:624-634`). The app is told its secret is wrong.
- Scenario 2 (first claim). Same in `claimVerify` (`node.go:574-575`): EForbidden "CheckMac"; the node nonce is
  already consumed (`takeNodeNonce`). The user is told the QR is wrong.
- Evidence against the text. Impl §2.4: "晶片錯誤一律回「暫時失敗」"; §2.1 keeps `CheckMac` without an error;
  §2.4 lists only ECDH callers. v6set-changes closes A-M2 for ECDH only. H1's `se-fail` case uses `claim.verify` as
  the "chip request after the fault" (§4.2), which would today report a wrong secret, not a chip fault.
- Fix (no new mechanism). Change the interface to `CheckMac(...) (bool, error)` while PR 1 (#379) is still unmerged;
  file backend returns `nil` error. `claimVerify` / `claimReplay` map a chip error to the same retryable code as
  `openSecrets` and do **not** call `failOnce`. Same for `SignPurpose` errors in the new session-sign verb (today's
  sign verbs map every error to `ESchema`, `node.go:398-410`). Fake chip models a CheckMac error. Tests: `se-fail`
  during `claim.replay` → retryable code, `replayF` unchanged (FAILs on today's code: the counter grows); same for
  `claim.verify`.

### MINOR

- **m1. All stored-secret ECDH goes through one function that returns nil for every failure.** `decryptSecrets`
  (`wtxn.go:130-146`) returns `nil` both for "not for this node / cannot decrypt" and for an `n.KS.ECDH` error
  (passed to `cose.Decrypt`). Its callers are `openSecrets` (apply), `openStoredSecrets` → `netRoot` (inside
  `psks()`, `node.go:450, 997-998`) and → `storedNet` → `desired()`, which is called by `finish()` **and** by
  `finishWantsRadio()` (`wtxn.go:576-588`, at boot, before `waitRadio`). §1/§2.4 name three paths; the fix has to
  be made once in `decryptSecrets` (return an error that carries "transient"), and `finishWantsRadio` should be
  named (a chip error there only skips the radio wait; Finish then fails transiently, which is fine). Implementation
  detail for PR 2; the §2.4 tests cover it if the PSK case also injects the fault on the `netRoot` path (member PSK),
  not only on `psk_replay`.

- **m2. "Freeze" must mean "do not listen" for the OTA claim in §2.8 to hold.** §2.8 says all three wrong-backend
  OTAs never open the socket. Today a frozen verdict still serves: `daemon()` stops only when `keystore.Load` fails
  (`main.go:631-636`); `unknown(identity-mismatch)` with a loadable overlay identity reaches `Listen` (`:708`), so
  provd connects and `provd-stable` gets written. For the chip image this holds only if the chip `Load` refuses a
  `backend=file` cache and every §2.3 "凍結" branch stays before `Listen`. State it as a rule in §2.3 and add
  "`backend-mismatch` → helper never listens → `provd-stable` absent" to the H1 assertion (today's rc 0 / rc 7 tests
  only check "nothing written").

- **m3. The file image's `boot.Run` can generate a software identity over a chip cache.** The "foreign backend =
  present" rule (§2.3 item 1) is written for the chip image. `identSum` is shared code (`boot.go:51-57`); in the file
  image a `backend=se` cache fails `keystore.Load`, so `ovIdent = p5Ident = false`, and an rc 7 / 9 boot reaches
  `generate()` (`boot.go:207, 231`) — a K20 violation that overwrites the overlay cache. Rare (needs rc 7/9
  on a chip node), but the fix costs nothing: apply the same rule in both builds (PR 2 changes `identSum` anyway).

- **m4. `se-burn cert`'s "no identity cache" check must include p5.** After an overlay wipe (`prov-overlay-wipe-254`
  does this), the overlay has no cache but p5 has one. If `se-burn cert` checks only the overlay, it writes a new
  cert; the next boot restores the old cache from p5 (rc 0, `restoreFromP5`) and freezes `identity-mismatch`.
  Fail-closed, but the contract in config §5.2 / §7 should say "neither overlay nor p5" (se-burn can use
  `--prov-get`), and the PR 2 refusal test should cover the p5-only case.

- **m5. The S0 "independent CRC" has no channel, and se-sign's CRC recompute proves nothing.** Config §4: an
  independent implementation on the developer PC must agree before the config lock, per chip. But §5.2: stdin is
  read only in S1 / S3, so nothing from the PC reaches `se-burn` at S0. And §5.1: se-sign "自己重算設定區校驗值"
  from the bytes the node reported — a CRC of reported bytes cannot disagree with itself. Simplest fix: drop both;
  the chip's lock-with-CRC already proves config = what `se-burn` sent, and se-sign's byte-for-byte compare against
  the image catches a wrong image before signing (worst case: one lost $1 chip).

- **m6. Who decides "S3 must redo CheckMac" is unstated.** Config §5.2 S3: "若燒錄紀錄仍是「待寫入」" — the record
  lives on the PC; `se-burn` cannot see it. And `se-sign begin` refuses any record that is not new / pending, so it
  cannot drive the normal S2 / S3 resume (record already "已鎖定"). Write the contract: `se-sign` passes secret +
  a "verify first" flag to `se-burn` at S3 only for a pending record; for a locked record S3 reads no secret; which
  `se-sign` subcommand drives S2 / S3 resume. The §4.4 interrupt tests then pin it. PR-level detail, but it is the
  burn interface.

- **m7. The compare rule: bytes 84 / 85 and 0–15.** (a) 84–85 "= E1's blank" uses chip 1's blank for every chip.
  (b) Any bus master may UpdateExtra byte 84 once (F§9), so if the helper's runtime "非本設定" check uses this rule,
  one root mistake bricks a bench node for good. (c) Bytes 0–15 are not covered: the bundle's separate "serial" field
  should equal config bytes 0–3 ‖ 8–12, and 4–7 = `00 00 60 03`. Fix: se-sign checks (c); the helper's runtime check
  ignores 84–85 (they have no security meaning with ChipMode bit 0 = 0); 84–85 compare against "this chip's S0
  read" if kept at all.

- **m8. Missing lifecycle rows (review-v5set-B listed them; not in v6set-changes, not in §7).** Power loss during
  the chip `Generate` / cache write (say it keeps today's tmp-and-rename, `keystore.go:173-220`); `sysupgrade -n`
  on a chip node (overlay gone, p5 restores the cache, compare with chip); p5 unreadable (rc 1 / 8: today's "kept
  the overlay" path, then the chip compare). One line each.

- **m9. The retry loop re-runs `boot.Run`, which re-persists on some paths.** On rc 7 / 9 with an overlay identity
  and on rc 0 "overlay newer", every `boot.Run` calls `Persist` (`boot.go:183, 196, 213, 220`). With a dead
  chip that is a p5 write every ≤ 5 min, forever. Re-run `boot.Run` only when the last verdict was
  `generate-failed`; otherwise retry only the load. PR 2 detail.

- **m10. A dead chip makes provd call `psks.get` every 500 ms.** `opsLoop` retries any non-OK on the next tick
  (`server.go:483-513`). Each try wakes the chip and waits for its timeout under the helper's sequencer, and the
  helper's node mutex. Let the chip backend fail fast while it is known to be silent (e.g. reuse the boot back-off
  state) or let provd back off. PR 2 detail; the §2.4 test can assert the try rate.

- **m11. `prov-p2-254.sh` parses a provd log line that P6 makes misleading.** `scripts/node/prov-p2-254.sh:264-273,
  443` waits for "helper boot_id changed: re-signing node_cert" (`server.go:448`). With no `sig_static` / boot_id in
  node_cert v2, the line either stays with a wrong meaning or changes and the unit FAILs. Name it in H2 (keep the
  line text or update the unit), per REVIEW.md item 2 "log line another tool parses".

- **m12. Reader list: complete for the app, two harness consumers unnamed.** My grep (`get(4)`, `get(7)`, `.sn`,
  `ecdh_pub`, `read_msg2`) over `app/rust`, `tests/tools`, `app/tools`, `tests/vectors`, `scripts`: app readers are
  exactly `nodecert.rs` `common()`, `approve.rs:525`, `claimflow.rs:172`, `replayflow.rs:182/204`; the three
  `read_msg2` sites (`claimflow.rs:163`, `loginflow.rs:161`, `replayflow.rs:171`) match §3.2. Harness: `peer/nodecert.py:50`
  (key 7, and keys 3 / 5 for `sig_static`), `peer/netobj.py:133-139` (keys 4 / 6), `gen.py` / `verify.py`,
  `synth-joinreq/src/main.rs:111-132` — all under H2's "peer/*". Not named: `prov-p2-254.sh` (m11) and
  `tests/tools/peer/owner.py:52` (`checkmac_response` takes an `sn`; if any peer-tool claim path is used on a chip
  node it needs the chip serial). So the list is complete enough; §3.2's "PR 3 greps and lists" can start from this.

- **m13. Peer public keys for the chip's ECDH.** The file backend validates the point (`proto.ECDHX` →
  `ecdh.P256().NewPublicKey`, `proto.go:191-197`). Whether the 608B rejects an off-curve point is not in any source
  read (F§5). Keep the `Identity.ECDH` contract equal across backends: the chip backend validates in software
  before sending. Inputs are owner- or admin-signed, so the risk is small. PR 2 detail.

- **m14. Actor list in impl §8 has no supply-chain line.** A counterfeit or pre-configured part could fake E1's
  answers and report a key someone else knows; the dev root would then sign it. Bench: accepted (Digi-Key parts,
  E1 version and "unlocked" check), but say so; the pure-Go driver (P1) is the supply-chain gain worth stating.

- **m15. Small text and experiment items.**
  - Config §8.0 "E4 以後要等本文件 v5 審過" → v6 (this round).
  - E10 failure branch "第 3 顆起" — chip 2 is burned in F1, after E10, so a changed ChipOptions applies from chip 2.
  - E12: read byte 85 back after the UpdateExtra; "寫入成功" by status code alone does not show the byte changed.
  - E0a checks the wake general call only on the rig's bus. Repeat it in E0b on a node with its real bus devices
    (the `batpower` sensor at uci `i2c_addr`, default 0x40, `batpower:44-45`).
  - §3.1: name the private OID (it is part of the size budget, M1) and the certificate serial.

## 3. Facts in the targets that are wrong or unsupported

| Where | Text | What the source says |
|---|---|---|
| impl §3.1 | chip cert "≤ 416 位元組" as a format property | the stated profile is 448–450 B (M1) |
| impl §2.4 | "晶片錯誤一律回「暫時失敗」" | `CheckMac` returns `bool` (`identity.go:21-22`); errors become EForbidden and count in `replayF` (M2) |
| impl §1, §2.4 | ECDH used in psks / openSecrets / Finish | also `finishWantsRadio`, and `netRoot` inside psks, all through `decryptSecrets` (m1) |
| impl §2.8 | wrong-backend OTA never opens the socket | true only if the chip `Load` fails on a file cache; a frozen verdict listens today (`main.go:631-708`) (m2) |
| config §4 / §5.1 | independent CRC before lock; se-sign recomputes the CRC | no channel at S0; recompute of reported bytes is vacuous (m5) |
| config §8.0 | "v5 審過" | stale |

Checked and correct: `server.go:357, 505, 513, 747`; `node.go:438-455, 1089-1091`; `wtxn.go:132, 328-336`;
`nodecert.rs:58-63, 104, 118-121, 126-133`; `proto.go:107-121` (node rejects high-s, `SignES256` normalises low-s);
`keystore.go:40, 45-46, 210, 266-267`; `main.go:631-636, 703, 708`; `stable.go:30-50`; `noise.go:105-109`;
`approve.rs:525`; `claimflow.rs:168-182`; `replayflow.rs:204`; `batman-autocommit:509-513`; `batpower:44-45, 61`.

## 4. Security walk

| Actor | What I tried | Result |
|---|---|---|
| Remote (BLE / mesh) | replay `node_cert`; swap the slot-0 key; present a self-signed `se:` or dev-root `dev:`; high-s | blocked by key-from-cert, profile rule and vectors (§3.4). Many anonymous `id/prove` = chip busy ≤ 8/s; covered by the contention test |
| Local non-root | open `/dev/i2c-1`; take the chip lock | 0600 root + root-only run dir; negative tests in H1 |
| Tenant | device in container | ENOENT; ok |
| Compromised provd | sign any `h` with slot 0; relay; hammer the session verb | same power as today's `sign.static` (it takes `s_node` as an argument); provd already holds every PSK. Residual, stated |
| Root on a bench node | overwrite / lock slot 8; UpdateExtra 84; ECDH and CheckMac oracles; plaintext ECDH on I2C | DoS or "node compromised", accepted for bench; m7(b) removes one self-inflicted brick |
| Root at burn time | lie in the bundle | accepted (developer present); slot-1 uniqueness stops cert theft of another node |
| Test harness host | `MAC` lines from a compromised test node | host picks the record from the node list; the oracle is that node's own secret only |
| Supply chain | fake chip | not stated (m14) |
| Our mistakes | wrong chip, wrong node, `batpower` at 0x60, chip image shipped | serial lists, serial check, code refusal, ship gate. Chip errors misreported as "wrong secret" (M2) |

Secrets: claim secret only on the PC (WSL ext4 0600) and in the chip, stdin once; dev root key encrypted and
separate; file-node secrets per-user temp dir, trap-deleted. No secret in node logs, argv or the run log — the run-log
check in H0 is the negative test. Fine for bench.

## 5. Earlier findings (review-v5set-A) — closed or reworded

| v5set-A | Status |
|---|---|
| M1 sn / ecdh_pub readers | closed in the text (`claim_sn`, `approve::import` from `verify_offline`, vectors); grep list in m12 |
| M2 chip ECDH swallowed | closed for ECDH; the same class remains for `CheckMac` → M2 |
| M3 compare rule | closed (exact values right); residue m7 |
| m1–m4 experiments | closed (E10 GenKey, order, E17 product-style sign, E6 4-byte fallback) |
| m6 begin re-run | closed (pending secret reused); S3 contract residue m6 |
| m7 retry writes prov-state | closed for prov-state; `Persist` residue m9 |
| m8–m11 | closed |
| m12–m16 | closed |
| B's lifecycle rows (power cut in Generate, `-n`, p5 unreadable) | not carried into §7 → m8 |

## 6. Verdicts

- **(a) E4 on the first sacrificial variant chip: APPROVE-WITH-CHANGES.** The variant bytes are right (§1) and
  nothing in M1 / M2 touches them (M1's option 2 changes only the final image). Change "v5" to "v6" in §8.0 and add
  the E12 read-back (m15) before E12.
- **(b) PR D starting now: APPROVE-WITH-CHANGES.** Start the driver core, packet / CRC vectors, fake chip and
  `se-lab` now. The `se-sign` cert part waits until §3.1 names a profile that fits (M1); the fake chip and the
  `Identity` interface carry a `CheckMac` error (M2 — change it in #379 before it merges).
- **(c) The design set as a whole: APPROVE-WITH-CHANGES.** Two MAJORs with small, local fixes; no new mechanism is
  needed for either. Per REVIEW.md, revise and review the whole set again before PR 2 / PR 3 code.
