# Review of the v5 design set — Reviewer A (security, protocol, chip behaviour)

Target: `255-608b-config.md` v5 + `255-phase1-impl.md` v3, worktree `C:/src/Batman-255` @ 8c6e069.
Read in this order: REVIEW.md; both targets in full; key-authority K13–K21 and §94; threat model (T-SE1…T-SE9, phase table);
`608b-facts.md` (§1.2, §1.3, §2, §5, §8, §9, §12, §16, §17); the cited source (provd `server.go`, `noise.go`, `session.go`;
helper `main.go`, `boot.go`, `node.go`, `wtxn.go`, `readonly.go`, `keystore.go`, PR 1 `identity.go`; `proto.go`;
`prov-lock.sh`, `96-batman-config-migrate`, `batman-config-save`; app `nodecert.rs`, `claimflow.rs`, `loginflow.rs`,
`replayflow.rs`, `approve.rs`, `claim.rs`, `sig.rs`; `bridge/cargokit.yaml`; `check-field-build.sh`; `provclient`,
`tests/tools/peer`; `batpower`); then `review-v4set-A.md`, `review-v4set-B.md` and `v5set-changes.md`.
No device or network contact. Nothing was run.

Counts: **BLOCKER 0 / MAJOR 3 / MINOR 16.**

## 1. Config bytes, decoded again (§4 final image, §8.1 variant)

| Field | Value | Decode | OK |
|---|---|---|---|
| 16 | `0xC0` | 7-bit 0x60, bit 0 = 0 | yes |
| 18 CountMatch | `0x00` | disabled | yes |
| 19 ChipMode | `0x00` | bit 0 = 0 (byte 85 never the address); bit 1 = 0 (fixed input levels); bit 2 = 0 (1.3 s watchdog); bits 7–3 = 0 (M0) | yes |
| 0 SlotConfig | `0x2081` | WriteConfig `0010`: bit 13 GenKey 1, bit 14 PrivWrite 0; WriteKey 0; IsSecret 1; EncryptRead 0; LimitedUse 0; NoMac 0; ReadKey `0001` ExtSign | yes |
| 1 SlotConfig | `0x2082` | as slot 0, ReadKey `0010` IntSign only | yes |
| 2 SlotConfig | `0x2084` | as slot 0, ReadKey `0100` ECDH, bit 3 = 0 (clear output, not to slot 3) | yes |
| 0–2 KeyConfig | `0x0073` | Private 1, PubInfo 1, KeyType `100` P-256, Lockable 1, ReqRandom 1, ReqAuth 0, AuthKey 0, PersistentDisable 0 | yes |
| 5 + unused SlotConfig | `0x8F9F` | WriteConfig `1000` (Write never; bit 13 = 0 so never a DeriveKey target); WriteKey 15; IsSecret 1; EncryptRead 0; NoMac 1; ReadKey 15 (≠ 0, no Copy) | yes |
| 5 + unused KeyConfig | `0x001C` | Private 0, PubInfo 0, KeyType `111`, Lockable 0, ReqRandom 0, ReqAuth 0 | yes |
| 8 | `0x0F0F` / `0x003C` | Always-write, WriteKey 15, IsSecret 0 (clear read), NoMac 0, ReadKey 15 / KeyType 7, Lockable 1 | yes |
| 68–83 | all `0x00` | UseLock, VolatileKey, SecureBoot, KdfIv off; 75–83 reserved 0 | yes |
| 88–89 | `FF FF` | no slot pre-locked | yes |
| 90–91 ChipOptions | `0x0000` | POST 0, IO-protection 0, KDF-AES 0, HTF auto-clear 0, bits 7–4 0, ECDHPROT 0 (clear output allowed), KDFPROT 0, IO key slot 0 (unused while bit 1 = 0) | yes (= AN3539 Table 4-1 default) |
| 92–95 | `0x00` | X509format off | yes |
| var. 3 | `0x0F8F` / `0x003C` | Always-write, IsSecret 1, NoMac 0, ReadKey 15; KeyType 7, Lockable | yes |
| var. 4 | `0x2083` / `0x0073` | private, GenKey 1, PrivWrite 0, Ext+IntSign, Lockable | yes |
| var. 6 | `0x0F0F` / `0x003C` | same as slot 8 | yes |

Pointer rule: no WriteKey / ReadKey / AuthKey points at slot 5 (private slots: WriteKey 0, ReadKey = sign/ECDH bits;
data/secret slots: 15). Slot 5 is odd, ReadKey 15. The bytes are correct, including the new ChipOptions `0x0000`.
OtherData starts with `0x08` (`claim.rs:6`), so the claim response has exactly the MAC-command layout. NoMac on slot 5 is
therefore the one bit that stops a bus master from computing claim responses; E8's MAC row tests it.

## 2. Findings

### MAJOR

**M1. The list of `sn` / `ecdh_pub` consumers is still incomplete; two app paths break for every chip node.**
- Scenario 1 (owner replay). `replayflow.rs:176-204` takes `sn = v.sn` from `verify_pinned` and computes the claim
  response with it. Under v2, field 7 = device_id, not the chip serial. The chip's CheckMac uses its own SN[8], SN[0:1]
  (`01 23 EE`), the app uses device_id bytes → every `claim/replay` on a chip node fails. §3.2 names only
  `claimflow.rs:172`.
- Scenario 2 (member join). `approve.rs:518-526` (`import`) builds the joiner's own member entry with
  `ecdh_pub: arr(nc, 4, "ecdh_pub")` — a raw read of node_cert key 4 from the pending join request. A chip-profile
  node_cert must not have key 4 (§3.1) → `Invalid("ecdh_pub")` → a chip node can never import its member secrets.
  §3.2 says the trusted `ecdh_pub` source is the extension, but this reader bypasses `Verified`.
- Host side: H0's `provclient mac <record>` must also pick the SN per profile (file record: node `sn`; chip record:
  chip serial). Today `provclient` takes SN from `info.cert` key 2 (`provclient/main.go:603-610, 632-634`), which is
  device_id on a chip node. The `MAC` / `MACR` contract (§6) does not say where SN comes from.
- Status of v4set-A M1: the main fix is done (sn = device_id everywhere), but the "list every reader" part is reworded,
  not closed. Fails closed, but it breaks two real-use paths in the acceptance full suite.
- Fix: `Verified` gets `claim_sn`; both `claimflow` and `replayflow` use it. `approve::import` takes `ecdh_pub` from the
  `verify_offline` result, never from key 4. §6 lists every reader of node_cert keys 4 and 7 and of `Verified.sn`
  (grep `get(4)`, `get(7)`, `.sn` in `app/rust`, `tests/tools`, `app/tools`). §3.4 adds a chip-profile replay vector
  and a chip-profile join-request import vector; both FAIL on today's code (negative control).

**M2. A chip failure inside an ECDH path is swallowed and latched; §2.4 / §7 claim the opposite.**
- Scenario. provd fetches `psks.get` once per state/gen change (`server.go:485-511`). `psks()` (`node.go:438-455`)
  computes `psk_replay` only `if z, err := n.KS.ECDH(...); err == nil` and `psk_member` only if `netRoot` (ECDH inside
  `openStoredSecrets`) is non-nil; otherwise it leaves them out and still answers OK. provd stores the set and clears
  `needPSK`. One chip hiccup at that moment → members and owner replay cannot log in until the next state change or
  helper restart. On a file node `ECDH` never fails, so this was harmless; with a chip it is a real path.
- Same class: `parseNet` → `openSecrets` returns `EBadObject "net_secrets"` (`node.go:1089-1091`) for a chip hiccup
  during `network/join` / `network/update`, i.e. the app is told the object is bad. At boot Finish, `storedNet`
  (`wtxn.go:88-90`) fails and is classed `causeDesired`, not transient (`wtxn.go:328-336`); safe (.txn kept) but the
  retry class is wrong.
- Evidence against the design text: §2.4 "該請求回錯誤，下一個請求重試晶片一次（不閂鎖）"; §7 "服務中無回應 → 恢復後照常".
  H1's `se-fail` list has no case where the chip fails during the PSK fetch.
- Fix (no new mechanism): `Identity.ECDH` errors from the chip are a transient error. `psks.get` returns an error code
  when any ECDH fails (provd already retries any non-OK on the next tick, `server.go:513`, and keeps the old set);
  `openSecrets` maps a chip error to a retryable code, not `EBadObject`; Finish wraps it as `transientCheck`. Add an H1
  `se-fail` case "chip silent during the PSK fetch → member logs in after recovery"; it FAILs on today's `psks()`.

**M3. The post-burn compare rule refuses every correctly burned chip (v4set-A m4 reworded, not closed).**
- Scenario. §4: "84–87 為 E1 的空白值". After S1 both zones are locked: LockValue (86) and LockConfig (87) are `0x00`;
  blank is `0x55` (F§1.2). As written, `se-burn` (S4 check) and `se-sign` refuse every good chip — or, worse, the two
  independent implementations the design asks for (§4) "fix" it differently. The same bullet says "16–83 identical"
  and "52–67 not compared", which contradict each other (counters are inside 16–83).
- This rule is the gate for the dev-root signature, so it must be exact before PR D writes the fake chip and the
  `se-sign` check.
- Fix: compare 16–51, 68–83, 90–127 with the image; 84–85 = E1 blank; 86 = 87 = `0x00`; 88 = `F8`, 89 = `FF`;
  52–67 not compared. The fake chip models lock bytes per F§1.2. Tests: a correct fake burn passes; a chip with
  86 = `0x55` (data not locked) or 88 = `FF` (keys not locked) is refused.

### MINOR

- **m1. E10 has no key in slot 2 and its control differs in two variables.** On the variant, slots 0–2 never get a
  key (E9 even relies on slot 0 being empty). E10's control "slot 2 clear ECDH succeeds" needs a key; "slots 0, 1
  refuse ECDH" then differs from the control in both the ReadKey bit and key presence. Fix: E10 first GenKeys slots
  1 and 2 (bit 13 = 1 allows it after data lock) and runs after E9; slot 0 stays empty for E9.
- **m2. The order rule covers only E6 → E17 → E9 → E13.** E8 must run after E6's data lock: "All restrictions apply
  when the data zone is locked" (F§2). Run earlier, MAC on slot 5 would succeed and trigger "停，回到設計" for nothing.
  State: E8, E10, E15 after E6; E10 after E9 (m1).
- **m3. E17 must sign the way the product does.** "以槽 4 外部簽章仍成功" should use passthrough Nonce (mode 0x03) +
  Sign 0x80, else it is not the control that E14 cites.
- **m4. 4-byte writes before data lock are assumed, not tested by name.** Slots 3–7 are 36 bytes and IsSecret = 1;
  "4-byte reads/writes prohibited" (F§2.1), while "most write restrictions are ignored when the data zone is unlocked"
  is 508A wording. S1 needs the last word written so the data-lock CRC is known. E6's locked-with-CRC step covers it on
  chip 1; say so in E6's pass condition, and what to do if the 4-byte write is refused.
- **m5. ChipOptions rationale cites the wrong fact.** F§12's "failure state until the next wake" is about POST /
  SelfTest, not the RNG health-test failure that bit 3 clears. `0x0000` is still the right value (AN3539 Table 4-1
  default). Fix the citation; E16 stays record-only.
- **m6. `se-sign begin` re-run can destroy the only copy of a burned secret.** If S1 dies after the data lock and the
  developer re-runs `begin`, a new secret replaces the pending one, while slot 5 is now never-write with the old one →
  automation can never claim that chip. Rule: `begin` reuses the pending record's secret for that serial, refuses if a
  record for the serial exists and is not pending, and never overwrites a secret. PR 2 test: crash after data lock,
  re-run `begin` → same secret.
- **m7. Re-running `boot.Run` every 10 s contradicts "prov-state only on change".** `Run` calls `writeProvState`
  unconditionally (`boot.go:66, 278-303`), mounts p5 through `--prov-get` (up to 3 tries) and logs a line each time.
  Fix: on retry, rerun only `Generate` + load, or make the retry's state write change-only.
- **m8. Interface gaps on the chip backend.** §2.1 omits `DACPub()`; it must be slot 1 (net_secrets target,
  `wtxn.go:132`). `PurposePeer` is unused (`peers/challenge` refused, `session.go:62`), and on the chip it would sign
  with slot 0 while any verifier would take the cert key; refuse it on the chip backend instead of carrying it.
- **m9. How provd learns the profile is unstated.** `buildNodeCert` needs `len(ecdh) == 65` and always signs
  `sign.ecdh_proof` (`server.go:337-350`). Say how it knows to omit keys 4 and 6 (e.g. `info.cert` key 3 = backend).
  Fails closed (app rejects a wrong field set), so this is text.
- **m10. The byte form of `Cert()` is unstated.** Slot 8 is 416 bytes, zero-padded. `x509-cert` rejects trailing data,
  and the app pins the exact DER. State: `Cert()` = bytes up to the outer DER length; non-zero padding = not burned.
- **m11. High-s: P9's evidence is half wrong, and the vector has no expected result.** The node rejects high-s
  (`proto.go:107-117`). The app's node-signature check `es256_verify` (`nodecert.rs:58-63`) calls p256 `verify` with
  no `is_low_s` check; `sig.rs:121` is only used for `sig_enc` (`approve.rs:65`). ⚠️ p256 accepts high-s (RustCrypto;
  inferred, not run). Decide: the `id/prove` verifier requires low-s, and the §3.4 vector expects reject.
- **m12. Preflight blind spot.** "鍵存在且與清單不符才拒絕" lets inventory = se with a file image (no key) through.
  Compare the effective value (missing = file) with the inventory; v1.6 runs are unaffected because their inventory
  says file.
- **m13. H0's "0600 temp dir" for copied `claim.secret`.** Node units run from Git Bash on NTFS, where `chmod` is a
  no-op — the same reason the design moved burn records to WSL ext4. Say where the dir lives and that a `trap` deletes
  it on every exit.
- **m14. Per-flavor `dev-trust` wiring has no evidence.** `bridge/cargokit.yaml:1-3`: cargokit builds one `.so` per
  build type for every flavor. §3.2 promises PR 3 wires flavors, but no mechanism is shown, and no field APK is built
  in phase 1 (the startup cross-check already refuses a mismatched one). Either show the mechanism or drop the claim and
  keep the cross-check + the existing NOTE. As written it is a mechanism with no present use.
- **m15. E8's stop rule is wider than C4 needs.** Only an output equal to the MAC-format hash forges a claim (MAC on
  slot 5, or a MAC over a TempKey equal to the slot). HMAC / KDF / AES on slot 5 give keyed functions of K, not
  claim responses. Keep "stop" for the MAC rows; for the others record and decide, so a surprise there does not stall
  the plan for no attack.
- **m16. Small text and handling items.** key-authority §94 says "C1–C10"; config has C1–C9. `se-sign` writes a QR
  image that contains the secret: say it is written under the WSL ext4 directory and removed after printing.
  "SEC1 未壓縮" for the node id: say the 65 bytes include the `04` prefix (the chip returns 64), as the file backend does
  (`keystore.go:40`).

## 3. Facts in the targets that are wrong or unsupported

| Where | Claim | Finding |
|---|---|---|
| config §4 | after burn, 84–87 = blank values | 86 / 87 = `0x00` after both locks (M3) |
| config §4 | "16–83 identical" and "52–67 not compared" | contradictory (M3) |
| config §4 | ChipOptions: without bit 3 the failure lasts until next wake (F§12) | F§12 describes POST, not the RNG health test (m5) |
| impl §3.2 | claim serial change at `claimflow.rs:172` only | `replayflow.rs:204` too (M1) |
| impl §3.2 | `ecdh_pub` taken only from the trusted source | `approve.rs:525` reads key 4 raw (M1) |
| impl §2.4, §7 | service-time chip failure: next request retries, no latch | PSK set is latched in provd (M2) |
| impl §2.3 | retry reruns `boot.Run`; prov-state written only on change | `Run` writes prov-state every time (m7) |
| impl P9 | the app rejects high-s (`sig.rs:121`) | not in `nodecert.rs` ⚠️ (m11) |
| impl §3.2 | PR 3 wires `dev-trust` per flavor | `cargokit.yaml:1-3` says cargokit cannot (m14) |
| key-authority §94 | C1–C10 | C1–C9 (m16) |

Spot-checked correct: `server.go:357, 597, 638-639, 747`; `nodecert.rs:118-121, 126-133`; `proto.go:54-77` (layout,
`sn[8]`, `sn[0:2]`); `keystore.go:40-46` (file sn = SHA-256(DAC pub 65 B)[:9]), `:102-104`, `:266-267`;
`main.go:631-636`; `boot.go:33, 207-233` (rc 7 / 9 via `generate`), `:247-258` (rc 13 compares file `sn`);
`prov-lock.sh:7, 38-44`; `96-batman-config-migrate:157-163`; `batman-config-save:229, 521-536`; `node/update.go:311-313`
(board only); `wtxn.go:132-135`; `noise.go:105, 108-109`; `claimflow.rs:168-182`; `Makefile:23-30`; `batpower` reads
`i2c_addr` from uci (code-level refusal of 0x60 is warranted: an `i2cget … 0x02` to 0x60 would send the 608 "idle").

## 4. Security walk (actors)

- **Remote / stranger.** `id/prove` signs `label ‖ h`; `h` covers `s_node`, so a node_cert copied from another node
  fails (the copier cannot get the victim's chip to sign its `h`). Dropping `sig_static` is safe because nothing offline
  reads key 2 (checked: only the three handshake verifiers use `rs`). Strict field sets per profile. OK.
- **Local non-root / tenant.** `/dev/i2c-1` 0600 with an EACCES test and a 0644 negative control; the lock file is in
  the root-only run dir; containers are `privileged: false` and get no device. OK.
- **Compromised provd.** Can get any `h` signed by slot 0 and keep the chip busy (~8/s). Same as today's
  `sign.static`. Stated. The claim oracle stays closed (CheckMac only verifies).
- **Root / bus master.** Can sign, ECDH, overwrite or lock slot 8 (DoS only; the cert binds the keys), write bytes
  84/85 once (no effect with ChipMode bit 0 = 0; may make `se-sign` refuse a later re-sign, fail-closed). Cannot read
  slot 5 or compute claim responses (NoMac; E8). Accepted for bench.
- **Burn-time root.** Can make the dev root sign false keys for its own serial. Accepted and stated; `se-sign`
  refuses duplicate slot-1 keys. m6 adds the one missing "our own mistake" guard.
- **Compromised node under test vs the host MAC oracle.** The record is chosen by inventory; the oracle answers only
  with the node's own secret, and the node is the only verifier of that secret, so the oracle gives it nothing new. OK.
- **Field build.** `trust_gate` rejects both profiles without `DEV_TRUST`; the dev root key compiles only under it;
  vectors cover first contact and offline. OK. m14 is about the build wiring claim only.
- **Supply chain / physical capture.** Out of phase-1 scope, stated (config §10).

Mechanisms with no present use: chip-backend `PurposePeer` (m8), per-flavor wiring as written (m14).

## 5. Earlier findings (review-v4set-A) — closed or reworded

| Earlier | Status |
|---|---|
| M1 sn = device_id | main part closed; reader list still incomplete → M1 |
| M2 S3 rewrite / node-side dev root | closed (unclaimed only, structural check, rotation steps, cache refresh) |
| M3 experiments | E6, E9, E12, AES, E17 closed; residue in m1–m3 |
| M4 K13 at PR 2 / PR 3 | closed (no chip image on nodes before PR 3; Q7) |
| m1 daemon GenKey | closed |
| m2 console branch | closed |
| m3 se-sign ↔ se-burn | closed; `begin` re-run gap → m6 |
| m4 post-burn compare | reworded with wrong values → M3 |
| m5 node dev-root key | closed |
| m6 ChipOptions bit 3 | closed (`0x0000`); citation → m5 |
| m7 cert profile | closed; byte form → m10, high-s → m11 |
| m8 field APK | partly; feasibility → m14 |
| m9 reflash row | closed (Q3) |
| m10 overlay writers | closed |
| m11 lstat check | closed |
| m12 MAC oracle / dirs | closed; NTFS temp dir → m13 |
| m13 E2 / E4 controls | closed |

## 6. Verdicts

- **(a) E4 on the first sacrificial variant chip: APPROVE-WITH-CHANGES.** Every byte of §4 and §8.1 decodes as
  intended, ChipOptions `0x0000` included; no finding needs a byte change. Conditions as the design states (E1–E3 done,
  image attached, independent recomputation equal). Before E5: fix the order rule and E10 / E17 / E6 rows (m1–m4).
- **(b) PR D starting now: APPROVE-WITH-CHANGES.** The fake chip and the `se-sign` compare must use the corrected
  rule (M3); `Cert()` trims slot 8 at the DER length (m10); `se-lab` needs passthrough Nonce + external Sign for E17 and
  GenKey on slots 1–2 for E10 (m1, m3); the fake chip keeps serial ≠ device_id with SN[0:1] = `01 23`, SN[8] = `EE`.
- **(c) The design set as a whole: APPROVE-WITH-CHANGES.** No blocker. M1–M3 are contract and text fixes inside
  work already planned; none adds machinery. Close them, and re-review the whole set per REVIEW.md, before PR 2 or
  PR 3 code starts.
