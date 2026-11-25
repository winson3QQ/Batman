# Review of the v4 design set — Reviewer A (security, protocol, chip behaviour)

Target: `255-608b-config.md` v4 + `255-phase1-impl.md` v2, worktree `C:/src/Batman-255` @ 594e6dd.
Read: REVIEW.md, both targets in full, key-authority K13–K21, threat model §3.0 / T-SE2, `608b-facts.md` in full,
the cited source (provd, helper, boot, keystore, PR 1 `identity.go`, `nodecert.rs`, `proto.go`, 96 / config-save,
`check-field-build.sh`, `cargokit.yaml`), then the earlier reviews and change maps. No device or network contact.

Counts: **BLOCKER 0 / MAJOR 4 / MINOR 13.**

## 1. Config bytes, decoded bit by bit (against F§2.1, F§2.2, F§5, F§9)

| Slot / field | Value | Decode | Matches intent |
|---|---|---|---|
| 0 SlotConfig | `0x2081` | WriteConfig `0010`: bit 13 GenKey = 1, bit 14 PrivWrite = 0; WriteKey 0; IsSecret 1; EncryptRead 0; LimitedUse 0; NoMac 0; ReadKey `0001` = ExtSign only | yes |
| 1 SlotConfig | `0x2082` | as 0, ReadKey `0010` = IntSign only | yes |
| 2 SlotConfig | `0x2084` | as 0, ReadKey `0100` = ECDH, bit 3 = 0 (clear output) | yes |
| 0–2 KeyConfig | `0x0073` | Private 1, PubInfo 1, KeyType `100` (P-256), Lockable 1, ReqRandom 1, ReqAuth 0, AuthKey 0 | yes |
| 5, unused SlotConfig | `0x8F9F` | WriteConfig `1000` (Never; bit 13 = 0, not a DeriveKey target); WriteKey 15; IsSecret 1; EncryptRead 0; NoMac 1; ReadKey 15 (≠ 0, no Copy) | yes |
| 5, unused KeyConfig | `0x001C` | Private 0, KeyType `111`, Lockable 0, ReqRandom 0, ReqAuth 0 | yes |
| 8 | `0x0F0F` / `0x003C` | Always-write, WriteKey 15, IsSecret 0 (clear read), NoMac 0, ReadKey 15; KeyType 7, Lockable 1 | yes |
| var. 3 | `0x0F8F` / `0x003C` | Always-write, IsSecret 1, NoMac 0, ReadKey 15; KeyType 7, Lockable | yes (MAC control) |
| var. 4 | `0x2083` / `0x0073` | private, GenKey 1, PrivWrite 0, Ext+IntSign; lockable | yes |
| var. 6 | `0x0F0F` / `0x003C` | same as slot 8 | yes |
| ChipMode (19) | `0x00` | bit 0 alt-address off, bit 1 fixed levels, bit 2 watchdog 1.3 s, divider 0 (M0) | yes |
| ChipOptions (90–91) | `08 00` | bit 3 HTF auto-clear only; POST 0, IO-prot 0, KDF-AES 0, ECDHPROT 0, KDFPROT 0, IO slot 0 | yes (see m6) |
| 68–83 | all 0 | UseLock, VolatileKey, SecureBoot, KdfIv off | yes |

Pointer check: no SlotConfig.WriteKey / ReadKey and no KeyConfig.AuthKey names slot 5 (private slots' WriteKey = 0 and
their ReadKey is sign/ECDH bits, not a pointer). Slot 5 is odd, so its Copy target is itself, ReadKey 15. Both rules hold.
I agree with both earlier rounds: the bytes are correct. Findings below are about experiments, protocol and lifecycle.

## 2. Findings

### MAJOR

**M1. "SN = device_id" is baked into provd and the app; the chip profile breaks it and the design does not list the consumers.**
- Scenario: a chip node returns `info.cert` = {cert, SN() = chip serial} (phase-1 §2.1). provd sets
  `deviceID = hex(sn)` (`server.go:357`) and uses it for the Noise prologue (`server.go:747`), the info answer
  (`:597`) and the advertisement suffix (`:638-639`). The app derives `device_id = hex(sn)` and requires the subject
  `serialNumber` = that value (`nodecert.rs:118` and the check after it). The chip cert profile has CN only and
  sn = chip serial. Result: prologue uses the chip serial while the phone uses SHA-256(slot 1)[:9] → every handshake
  fails; PSKs are derived from `KS.DeviceID()` on the node (`node.go:438`) but from hex(sn) in the app.
- Evidence: phase-1 §3.2 cites `nodecert.rs:177-180 不變` as the device_id rule. That is `dev_rule`; the rule actually
  used for every node is `common()` line 118. §2.6 lists no provd change for device_id.
- Fails closed, but it is the identity-binding contract and it is wrong on paper.
- Fix: `info.cert` returns device_id separately (or provd computes it from the cert key); `common()` derives
  device_id from the cert subject key for both profiles and checks the subject serialNumber only for the file profile;
  list prologue, advid, PSK derivation, `Verified.sn` users as readers in §6; add a vector where sn ≠ device_id.
  The fake chip (PR D) must use a serial ≠ device_id so this shows in CI.

**M2. Re-running S3 (the stated remedy for cert-format change or dev-root loss) locks the owner out; the rows are missing.**
- Scenario: config §5.3 / §5.4 say "re-run S3" after a cert-format change or dev-root rotation. The app pins the full
  DER (`verify_pinned`, `nodecert.rs:126-133`). After a new cert is written to slot 8, a claimed node presents a new
  DER → `NotPinned` → the owner cannot log in, and the node is still "claimed", so nobody can re-claim it. Only a card
  reflash (record lost) recovers. The identity cache `cert` on overlay and p5 also goes stale (step 2 reads slot 8,
  scripts read the cache; nothing says which wins or who rewrites the cache).
- Second part: §2.3 step 2 / §5.2 S4 make the node verify the dev-root signature. That needs the dev-root public key
  in the node image (resource not listed). After a dev-root rotation, every chip image must be rebuilt, and an OTA
  across the rotation makes every not-yet-re-burned chip node stop serving ("burn unfinished").
- Fix: (a) §7 rows "S3 rewrite on a claimed node" and "dev-root rotation × OTA", with the honest consequence
  (reflash + re-claim) or a rule: `se-burn cert` refuses unless the record is unclaimed; (b) the node checks only the
  structural binding (subject key = slot 1, extension keys = slots 0/2, serial), not the issuer signature — trust is the
  app's job; this removes the dev-root key from the image and the rotation coupling; (c) say how the cache cert is
  refreshed (boot rewrites it from slot 8 when the subject key matches).

**M3. Several experiments do not test what they claim, and one "documentation only" claim has no document.**
- E6: the post-lock negative is "明文 Write on a private slot". Write to a private slot is refused always (F§2.2
  KeyConfig.Private: "never written with Write"; before data lock too, F§1.3 "written only with PrivWrite"). It passes
  without the data lock, so it proves nothing. The pair that discriminates is clear **PrivWrite** on slot 4: success
  before data lock (already the control), failure after.
- E9: target "已鎖定的槽", but E9 must run before E13 locks slot 6, and no other slot is locked at that time on chip 1
  (the variant never GenKeys / locks slots 0–2 or 4). The row has no target. Also the case that matters for the real
  image is not tested: ECDH / KDF "store to slot" into a **private-key slot with bit 13 = 1** (slots 0–2), which F§11
  does not list among the commands that SlotLocked blocks (it names PrivWrite, Write, GenKey, DeriveKey only).
- S2 relies on "GenKey works on an unlocked bit-13 slot after data lock, and fails once the slot is locked". No
  experiment tests it on a private slot (E13 locks a data slot). Slot 4 of the variant is the exact control:
  GenKey(slot 4) after data lock → success; Lock(slot 4); GenKey(slot 4) → fail; GenKey public + Sign still work.
  This also gives E9 its locked target.
- E12: writes **byte 84** and checks the address. Byte 84 (UserExtra) never affects the address; byte 85
  (UserExtraAdd) does when ChipMode bit 0 = 1 (F§1.2, F§9). The test cannot fail, so it shows nothing about ChipMode
  bit 0. Write byte 85 with a non-0x60 value (sacrificial chip 1 only) and check the address after a power cycle. Then
  F1 must **not** run E12 on chip 2 (it would be a permanent write on a bench chip). Earlier rounds (v3-A m5,
  v3-B m1) fixed the control but not the byte; still open.
- AES on slot 5 is listed as structural "只靠文件" (KeyType 7). F§4 says the opposite: "NOT FOUND whether KeyType 7
  slots are rejected" by AES. And a control exists: slot 3 (KeyType 7, NoMac 0). Add AES(slot 5) vs AES(slot 3) to E8
  (or record byte 13 AES_Enable = 0 from E1, which disables AES and KDF-AES per AN3539, and cite that).
- Fix: rewrite these four rows. None needs a config change, so this does not block E4.

**M4. The protocol flag day breaks K13 at the PR 2 / PR 3 boundary, and §7 claims the opposite.**
- Scenario 1: P7 has no compatibility. A node trial-boots the first PR 3 image and reverts automatically to the
  previous image (v1 protocol). The phone already runs the v2 app, which rejects v1 `node_cert` → after an automatic
  revert the node cannot be logged into. K13 ("升級後試用失敗自動回退時，節點仍可登入") is one of the rules that does
  not yield (key-authority "其餘規則不讓步").
- Scenario 2: between PR 2 and PR 3 a chip image speaks protocol v1, whose `sig_static` is checked with the cert key
  (slot 1, IntSign only, `nodecert.rs` `common()`). No chip node built from that main can be logged into. §7 row
  "回退到上一個晶片映像（K13）… 可登入" is false when the previous chip image is PR 2-level.
- Fix: either the dev app keeps the v1 file-profile verifier for one release (dev builds only), or chip images are
  not built/shipped before PR 3 and the K13 exception for the PR 3 boundary is put to the user in §10 with the
  recovery step. Correct the §7 row.

### MINOR

- **m1. Daemon needs GenKey.** §2.2 says Write / Lock / GenKey are burn-only, but §2.3 step 2 reads slot 0/1/2
  public keys at every boot; private slots cannot be read, so this is GenKey mode "public" (PubInfo = 1). State it, and
  make the driver refuse GenKey "create" outside the burn mode (defence against our own bug regenerating a key slot
  that is not yet locked).
- **m2. The burn guard's console branch cannot be reached.** `qr`'s rule reads `/proc/self/fd/0` (`main.go:607-608`).
  `se-burn` gets the secret on stdin over ssh, so stdin is never the console: `/etc/batman-dev-open` is always
  required. Say so, or use the controlling tty; do not claim two paths.
- **m3. se-sign ↔ se-burn contract is under-specified.** (a) `se-sign begin` must know the serial before it creates
  the "pending" record: add a read-only `se-burn status`, and pass the expected serial to `se-burn` so it refuses a
  secret for a different chip (two bench nodes, wrong host). (b) A crash after data lock and before the CheckMac leaves
  the record "pending" forever; S2 never revisits it. Let S3 run the CheckMac (secret again via stdin) before the
  bundle is signed. (c) `se-sign sign` must refuse a bundle whose record is not "locked", whose serial differs from the
  record, or whose slot-1 key / device_id already belongs to another record. Without (c), root on a bench node during a
  burn can report another node's (public) slot-1 key with its own slot-0/slot-2 keys and get a dev-root cert that lets
  it pass first contact as that node (T-SE2 in the dev app). The check is a few lines and also catches our own mix-ups.
- **m4. "逐位元組比對影像" will fail on a correct chip.** After S2, byte 88 = `F8` (slots 0–2 locked), not the
  image's `FF`; 86/87 = `00`. Define the expected post-burn values for 84–91 and the counters (§4 says "不碰" but the
  image is "16–127 fixed"): which bytes are compared to the image, which to fixed post-burn values, and that slot 8's
  bit must still be 1.
- **m5. Node-side dev-root key** — see M2(b). If kept, list it as a resource with an owner and a rotation row.
- **m6. ChipOptions bit 3 (HTF auto-clear) has no stated use and touches the RNG that makes ECDSA nonces.** Its
  semantics are known only by name from 608A-TFLX (F§5). Without it a health failure lasts until the next wake (F§12),
  and the driver wakes on every sequence. Decide before E4 (this byte is frozen by E4): set 0, or state why it is needed
  and what E16 must show.
- **m7. Cert profile gaps.** State: the profile is chosen by verifying the signature against the pinned dev-root key,
  never by issuer DN text; CN must equal the computed device_id (or is ignored); signature algorithm ecdsa-with-SHA256
  and match of the two AlgorithmIdentifiers; BasicConstraints CA:FALSE; any critical extension other than the expected
  set is rejected (x509-cert does not do this by itself); compressed points are decompressed with curve validation.
- **m8. Field APKs carry the dev root today.** `cargokit.yaml:1-11` builds every flavor with `dev-trust`; the
  field APK is protected only by the startup cross-check; `check-field-build.sh` judges host builds and prints the APK
  as a NOTE. C6 / §4.1 "field 版不含開發根公鑰" is therefore not enforced on an APK. Put per-flavor wiring (a #255 item
  per `cargokit.yaml:4`) into PR 3, or state the gap.
- **m9. Downgrade row is wrong for a reflash.** A reflash wipes p5 (§7 "重燒 SD 卡… 紀錄沒了"), so `--prov-get`
  gives rc 7 and **any** file image, post-#255 included, generates a software identity (`boot.go` case 7 →
  `generate`). The "p5 has backend=se → refuse" protection holds only for OTA. Fix the row and widen Q3.
- **m10. Ownership of the overlay identity.** `96-batman-config-migrate:157-163` writes the **overlay** identity from
  p5 (not p5). So the overlay cache has two sequential writers (96 at S10, helper at S89); say so. Its
  `chmod 644 …/node.cert` in the `&&` chain fails for an se cache (no `node.cert`), so the copy silently does not happen;
  the file list change must cover that line.
- **m11. `/dev/i2c-1` lstat/owner/mode check guards nothing present.** Only root can create nodes in `/dev`. The check
  adds a brick path (helper never serves if the hotplug mode is 0660). Keep the EACCES negative test as the control;
  either drop the check or make E0 record the real mode and test the image's rule.
- **m12. Host MAC oracle.** `provclient mac` must pick the record from the harness inventory for the target host,
  never from anything the node prints; otherwise a compromised node under test can get responses with another
  node's secret for a ClientChal it built from a live session with that node. Also keep claim secrets and the dev-root
  key in separate directories (the harness needs the first, never the second), and say where "0600" applies on
  DSKT-MOONLIGHT (WSL ext4, or the NTFS ACL — `chmod` is a no-op there under Git Bash).
- **m13. Weak controls on E2 / E4.** E4's "亂數不再是測試樣式" has no before-value: capture Random in E2 (se-lab has
  Random). E2's control is a config-zone write; the discriminating one is the same data-zone Write after config lock
  (S1/E6) — reference it.

## 3. Facts in the targets that are wrong or unsupported

| Where | Claim | Finding |
|---|---|---|
| phase-1 §3.2 | device_id rule is `nodecert.rs:177-180`, unchanged | device_id comes from sn at `nodecert.rs:118` and `server.go:357` (M1) |
| phase-1 §2.2 | GenKey is called only by the burn mode | boot reads public keys of private slots (m1) |
| phase-1 §6 | 96-batman-config-migrate writes p5's identity | it writes the overlay's (m10) |
| phase-1 §7 | post-#255 file image refuses on a chip node | only after OTA; not after reflash (m9) |
| phase-1 §7 | revert to previous chip image is loginable | not across PR 2 / PR 3 (M4) |
| config §8.2 | AES refusal is documented structurally; no control possible | F§4: NOT FOUND; slot 3 is a control (M3) |
| config §8.2 E12 / §7 | writing byte 84 shows ChipMode bit 0 = 0 keeps the address | byte 85 is the address byte (M3) |
| config §8.2 E6 | clear Write on a private slot is a lock test | refused regardless of lock (M3) |
| config §5.3 | re-run S3 is enough after format / root change | pinned DER locks the owner out (M2) |
| config E14 ⚠️ | ReqRandom vs external sign unknown | not wrong, but evidence exists: TFLX/TNG slot 0 KeyConfig `0x0053` has ReqRandom with ExtSign and is used for TLS signing (F§2.1); cite it |

Spot-checked correct: `main.go:632-636` (`select {}`), `stable.go` single writer and latch, `trial.go` rc≠1 = trial,
`keystore.go:266-267`, `proto.go` ClientChal binds nonce, h, SHA-256(cert DER), owner_pub (so the claim proof is
session- and cert-bound in both profiles), `noise.go:105` h after msg2, NX pattern (h covers s_node, so dropping
`sig_static` is safe once `id/prove` is mandatory), `node.go:633` claim failure limit, `wtxn.go:132-135` target =
SHA-256(DACPub).

## 4. Security walk (actors)

- Remote / stranger: `node_cert` replay is stopped by `id/prove` with the key taken from the verified cert; a forged
  field 4/6 on a chip profile is rejected by the strict field set. `id/prove` signs `label ‖ h`, 54 bytes, a fixed label
  no other verifier accepts. OK.
- Local non-root / tenant: EACCES on `/dev/i2c-1` with a negative test. OK.
- Compromised provd: can get any `h` signed and starve the chip at ~8 signs/s; equal to a compromised provd today.
  Accepted, stated.
- Root / bus: can sign, ECDH, lock slot 8 (Lockable, no auth) or overwrite it → DoS only, since the cert binds the
  keys; replacing a key slot breaks the cert binding (DoS, not impersonation). Accepted for bench.
- Burn-time root: can get a dev-root cert for false keys; m3(c) closes the cross-node case cheaply.
- Our mistakes: M2 (owner lockout), m3 (wrong chip / stuck record), m9 (K20 by reflash).
- Supply chain / physical capture: out of phase-1 scope, stated.

No mechanism in the set lacks a present use except ChipOptions bit 3 (m6), the node-side issuer check (M2 b) and the
`/dev` lstat check (m11).

## 5. Earlier findings — closed or reworded

| Earlier | Status |
|---|---|
| phase1-A B1 (field 8 unbound) | closed (P4, §3.4 vector) |
| phase1-A M1 (shared rate limit) | closed (P5 + contention test) |
| phase1-A M4 (HAT swap auto-void) | closed (freeze) |
| phase1-A M5 / B-M8 (chip writers) | closed (lock + sequencer; batpower refuses 0x60 in code) |
| phase1-A M6 (burn SPOF) | mostly closed; residue in m3 |
| phase1-A M7 (i2c access) | closed; extra check m11 |
| phase1-B M10 (flag day) | v1.6 side closed; K13 side open (M4) |
| v3-A M1 / v3-B M6 (variant controls) | partly: E6, E9, AES rows still wrong (M3) |
| v3-A m5 / v3-B m1 (E12) | reworded; still the wrong byte (M3) |
| v3-B M3 (slot 8 locked) | closed; its remedy creates M2 |
| v3-A M2 / M4 (endorsements) | closed by removal; K16 now holds by construction |

## 6. Verdicts

- **(a) E4 on the first sacrificial variant chip: APPROVE-WITH-CHANGES.** The variant and final bytes decode
  correctly and none of M3's fixes needs a config change. Before E4: decide ChipOptions bit 3 (m6). Before E5: fix the
  E6 / E9 / E12 / AES rows and add the slot-4 GenKey/lock row (M3) and the E2 Random capture (m13).
- **(b) PR D (driver core + fake chip + se-lab) starting now: APPROVE-WITH-CHANGES.** The driver must restrict GenKey
  to "public" outside the burn mode (m1); se-lab must include UpdateExtra on byte 85, AES, Random and the slot-4
  GenKey/Lock sequence (M3); the fake chip must have serial ≠ device_id (M1) and treat every not-yet-captured status
  code as provisional.
- **(c) The design set as a whole: APPROVE-WITH-CHANGES.** No blocker. M1–M4 are text and contract fixes, none adds
  machinery; they must be closed (and the set re-reviewed as a whole, per REVIEW.md) before PR 2 or PR 3 code starts.
