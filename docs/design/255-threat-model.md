# #255 threat model: key-management plane (v2.2, self-assessed)

v2.1 → v2.2: network segmentation and audit, checked against IEC 62443-4-2 FR5 (restricted data flow) and FR6
(timely response to events), and STRIDE R (repudiation). v2.1 already had the segmentation *property* (R45, R46,
R103) and accountability as an asset (A11) with an open question (§8.1-13); it had no threat for maintenance
services on the bridge and no node-side requirement for an audit record. Added: T-ND9 … T-ND11, R118–R125, two
residual risks (§10-16, §10-17); §8.1-13 now points to them. One adversarial review of the draft and one of the merged
text (APPROVE-WITH-CHANGES, 0 / 5 / 4) were folded in. Draft with the code evidence: `255-reviews/v2.2-segmentation-audit-draft.md`. Not re-reviewed.

v2 → v2.1: review v3-B = APPROVE-WITH-CHANGES (0 / 1 / 7). §3.0 now states the platform state per version (secure boot ON for all shipping builds; #255 (v2.0) is OFF with a chip) and the overlay assumption; stale citations to the key-authority document updated. MINOR findings not yet applied: see `255-reviews/review-v3-B.md` Part 3.

**Status**

- **v2** = the independent threat model (`255-reviews/threat-model-independent.md`, written blind) as the base,
  merged with the design author's v1 (the previous content of this file, Traditional Chinese, now replaced) and with
  the threats found by two adversarial review rounds of the design (`255-reviews/review-v1-A.md`, `review-v1-B.md`,
  `review-v2-A.md`, `review-v2-B.md`). What was added from which source, what was dropped and every corrected
  citation: `255-reviews/threat-model-merge-notes.md`.
- **Self-assessed, not externally validated. A red-team pass is planned once #423 (v2.0) has something to attack.**
  No negative test in §9 has been run; "requirement" here means "what a design must make true", not "what is true".
- Method: STRIDE per trust boundary and per flow, attack trees, likelihood x impact. Method reference: ICS_COMMAND
  `docs/compliance/threat_model.md` (STRIDE). That repository is not in this worktree: every statement quoted from
  it is marked "[D ICS …]" and could not be re-opened during this merge.
- Base: worktree `C:/src/Batman-255`, main `4eba26d`. Decision level, not code level. No device was contacted.
- Out of scope (already in `docs/threat-model.md`, which this document does not change): jamming, batman-adv
  routing attacks, TAK CoT injection. Also out of scope: weaknesses in the cryptographic primitives themselves
  (P-256, ES256, AES-GCM, HKDF, Noise) [author v1 §3].
- **User decisions recorded after the merge (2026-11-23), which settle points this document leaves open:**
  - Secure boot is **ON for all builds** (#255 issuecomment-7091487388). "Platform state OFF" in §3 therefore
    describes development units and the period before #115 / #47 / #111 land, not a shipping product state.
  - No anti-theft (activation) lock for now; the app shows how many times a unit has been enrolled
    (#255 issuecomment-7091605653). Fixed versus replaceable body-QR secret is decided in `255-608b-config.md`.
  - FIPS: checked on 2026-11-23 against the NIST CMVP validated-modules search — no active module certificate
    matches "ATECC608"; the chip has algorithm validations only (CAVP A4280 / A4285, per Microchip). CMVP
    certificate 5371 is the Microchip **TA101** (FIPS 140-3, overall level 2), not the 608B. This supersedes the
    [A] marker on residual risk 11 in §10.
  - SSH by build (2026-11-23): **customer (production) builds keep SSH closed by default** — R118 as written;
    **development builds may keep it open**. Nothing else differs between the two builds. This settles the K15
    trade noted under T-ND9.
  - Hardware roadmap: nodes get an RTC from **v2.0 (#174)**; the production secure element is not settled: #414 (v2.3) plans the
    608B bound to the CM4, while `255-608b-config.md` (user, 2026-11-23) says the production chip is not a blank 608B
    and is chosen later. Until v2.0 (#174), residual risk 3 holds as
    written; after it, the node has a clock that a holder of the node can set (R41 and R113 still apply).
- Follow-up outside this file, not done here (v2.2): devices on the bridged segment can act as a rogue DHCP server,
  send IPv6 router advertisements, or forge alfred / openmanetd address-reservation data. That is network-layer and
  belongs in `docs/threat-model.md`; it is not a management-plane threat and is not scored here.
- Follow-up outside this file, not done here: `docs/threat-model.md:38` describes a single root CA that signs both
  node and TAK client certificates; that conflicts with R24 and R97 and should be corrected when this document is
  approved [author v1, header note].

**Markers**

- **[V file:line]** verified in source in this worktree; every [V] below was re-opened during the merge.
- **[D file:line]** stated in a design document only (not code).
- **[A]** assumed, or from general knowledge; not verified here. **Every ATECC608B chip-behaviour statement is [A]
  until checked against the datasheet and on a sacrificial chip.**
- Paths: node code is relative to `feed/batman-prov/src/` unless a longer path is given; app code is under `app/`.

**Identifiers**

- The base's identifiers are stable: A-n, B-n, S-n, X-n, T-*, F-n, L-n, AT-n, R1–R80 are unchanged in number and
  meaning. New items are appended at the end of their lists with their source in brackets, for example
  [author v1 R6], [review v1-A M3], [review v2-B B1].
- The author's v1 used R1–R21 for a different set of requirements. Where this document refers to them they are
  written **v1-R1 … v1-R21**; the mapping is in the merge notes.

**Premise corrected in v2 (applies throughout).** The base and the author's v1 both said "the civil build has no
secure boot". That was a statement about the Pi 3A+. Production is the CM4, which supports secure boot, so secure
boot is a product **choice**, not a hardware limit. Assumptions and residual risks are therefore given for two
platform states (§3), not for "civil" and "tactical".

---

## 1. Scope and assets

The key-management plane = everything that decides **who may command a node, who is in a network, and which keys
prove it**: organisation root, issuing station, administrator and member credentials on phones, per-node identity
in the secure element (SE), the node's provisioning record, the mesh password and its distribution, recovery
material, factory provisioning, and the firmware-update trust that can override all of it.

Assets, ranked by loss (worst first):

| # | Asset | Loss means | Recoverable? |
|---|---|---|---|
| A1 | Organisation root key and its recovery material | Attacker is the organisation: enrols admins, takes every node and network, revokes the real people | Only by touching every node; if nodes pin the root irreversibly, not at all |
| A2 | Firmware release root / signing key (`Trust.Root` **[V feed/batman-prov/src/release/release.go:57-58]**) and the app signing key | A signed image or app update bypasses every rule in this document | Card reflash of every node; a new app identity loses every phone key |
| A3 | Issuing-station issuing key and its enrolment database (ICS_COMMAND) | Unlimited valid admin / member / node credentials until nodes learn of the revocation | Root revokes the station; stale nodes keep trusting it (no clock) |
| A4 | Factory secrets: manufacturer CA key, the table of per-node claim secrets, label print data | Counterfeit nodes with valid certificates; claim of any unclaimed node; if the claim secret is static, of any node after every reset | CA: no (pinned in the app). Claim table: only if the secret can be rotated in the chip |
| A5 | An administrator's signing key on an unlocked phone | Everything one admin may do — today that includes replacing the whole admin set (S7) | Revocation, only as fast as it reaches each node |
| A6 | Mesh password (`sae_password`), `net_root`, `team_ap_psk`, LoRa PSK | L2 membership, traffic visibility, BLE member role | Rekey — must reach every node, including switched-off ones |
| A7 | Per-node SE keys (identity, ECDH) — their **use**, not extraction | While held: impersonate the node, decrypt everything addressed to it | Revoke the node; statements pre-signed during custody may outlive custody (T-SE1, T-SE2) |
| A8 | Per-node record on the SD card (`prov.cbor`, overlay copy, `/etc/shadow`, SSH keys, Wi-Fi config) | Node-local takeover, mesh password disclosure, roster disclosure | Physical re-enrolment of that node |
| A9 | Manageability: the legitimate organisation's ability to change anything | Network frozen with a known-compromised password; nodes unmanageable | Physical visit to each node |
| A10 | Privacy: which nodes / people belong to which organisation, where they are, the roster | Tracking, targeting, unit attribution after one capture | None after disclosure |
| A11 | Accountability: who did what (no shared accounts) | Insider actions cannot be attributed; agency baseline failed | — |
| A12 | Boot-chain signing key — exists only in state ON (§3) [A] [merge: secure-boot premise] | A boot image signed with it runs on every node of that state: equivalent to A2, below the update path. Its *loss* means no new boot image can ever be accepted by those nodes (the anchor is one-time programmable) | Compromise: no. Loss: no |
| A13 | Per-node recognition / identification secrets, and any directory of them (administrator phone, issuing station, sync packages) [author v1 V9; review v2-A m13, m14] | Whoever holds one can pick that node out of the air and open a handshake with it; a directory does that for every node it lists | Rotation, one node at a time, by someone who can still reach the node |

Note the inversion against the network-layer model: here **integrity and availability of authority** outrank
confidentiality of the mesh password. A leaked password is fixed by a rekey; a lost or hijacked authority is not.

---

## 2. Components and trust boundaries

```
              (offline, never in the field)                        FACTORY / SUPPLY
              +--------------------------+                +---------------------------------+
              |  ORG ROOT KEY            |                | SE config+lock, key generation, |
              |  + recovery material     |                | device cert (mfr CA), claim     |
              +------------+-------------+                | secret, QR label printing       |
                    B1     | certifies / revokes          +----------------+----------------+
              +------------v-------------+                         B9      | ships
              |  ISSUING STATION         |   B2  operators (FIDO2),        |
              |  (ICS_COMMAND sealed box)|<----- automation / AI agent,    |
              |  issues people + devices |       backups, co-hosted TAK CA |
              +------+-------------+-----+                                 |
             B3      | enrol       | B4 enrol node (phone as courier)      |
       +-------------v--+          |                                       v
       | ADMIN PHONE    |----------+----- B5: BLE / HTTP:8095 --------> +--------------------------------------+
       | app + Keystore |          (Noise; phone <-> provd)             | NODE (CM4, OpenWrt; boot state: §3)  |
       | (+ TAK client) |                                               |  provd (uid 471, jailed)   -- B6 --  |
       +-------+--------+                                               |  provhelper (root)         -- B7 --  |
          B10  | paper / QR / chat images / spoken codes                |  SE (ATECC608B on I2C)               |
       +-------v--------+   B5                                          |  SD card p5 / p6 / overlay -- B8 --  |
       | MEMBER PHONE   |---------------------------------------------->|  phone AP + eth0 + bat0 = one bridge |
       | app (+ TAK)    |   B11: Wi-Fi AP (WPA-PSK)                     +------------------+-------------------+
       +----------------+                                                      B12         | HaLow mesh (shared SAE)
                                                                                           v  other nodes, other orgs
   B13: app store / APK channel and phone OS -> phone.     B14: firmware release pipeline -> node (image carried by the app).
```

| Id | Boundary | Link / carrier | Trust today |
|---|---|---|---|
| B1 | Root <-> issuing station | offline ceremony, removable media | does not exist yet |
| B2 | Operators / automation <-> issuing station | console, mTLS, FIDO2 unlock | sister product: unlock at boot, key live in memory afterwards **[D ICS threat_model §8.8]** (not in this worktree) |
| B3 | Issuing station <-> phone (person enrolment) | station LAN / QR | does not exist yet |
| B4 | Issuing station <-> node (equipment enrolment) | phone as courier, or direct | does not exist yet |
| B5 | Phone <-> provd | BLE GATT; HTTP 8095 from phone-AP clients only **[V feed/batman-prov/files/batman-http.nft]** | Noise NX / NXpsk0, owner-op per verb **[D docs/design/219-protocol.md §3, §5.7]** |
| B6 | provd <-> provhelper | unix socket; provd uid 471, no capabilities, `requirejail` **[V feed/batman-prov/files/batman-provd.init:34-36, 39]**, **[V feed/batman-prov/files/batman-provd.json]**, **[V feed/batman-prov/Makefile:40]** | helper recomputes challenges and verifies owner-op on the raw body **[D 219-protocol.md §5.4, §5.7]** |
| B7 | root on the node <-> SE | I2C, shared bus | none: root may issue any chip command |
| B8 | Anyone with a card reader <-> SD card | physical | none in state OFF (§3): p5/p6 plaintext by decision **[D docs/design/219-field-provisioning.md:27]**; record integrity is a bare SHA-256 in `prov.meta` **[V feed/batman-prov/src/provstore/provstore.go:10]** |
| B9 | Factory / reseller / repair <-> node and label | physical, tooling | does not exist yet (file backend creates the identity on the card **[V feed/batman-prov/src/keystore/keystore.go:1-5]**) |
| B10 | Paper and human channels | body QR, recovery sheet, chat images, voice | QR = 256-bit claim secret; SAS = 6 digits |
| B11 | Phone-AP clients <-> node LAN | WPA-PSK | phone AP, `eth0` and `bat0` are ports of one bridge **[D docs/design/254-p3-impl.md:62]** — the AP password or the Ethernet jack is L2 access to the mesh |
| B12 | Node <-> node, org <-> org | HaLow SAE, batman-adv | one shared password; no per-node admission |
| B13 | App / OS update channel <-> phone | store, sideload, MDM | app signing key gates the Keystore keys |
| B14 | Release pipeline <-> node | signed manifest carried by the app | root key in squashfs, min-serial, downgrade list **[V release/release.go:30, 54-58]** |
| B15 | Other local code on the node <-> helper socket and SE device node [review v2-A m1; `docs/design/REVIEW.md` item 5] | unix socket; `/dev/i2c-*`; containers (docker0 and br-ots exist on the node **[D docs/design/254-p3-impl.md:62]**) | socket: peer uid must be provd's **[V sock/sock.go:2, 189]**. SE: no SE code exists yet (the only backend is "file" **[V keystore/keystore.go:68-69, 266-267]**), so nothing restricts the bus today; bus 1 is already configured for `batpower` (INA226, default address 0x40) **[V feed/batman-provision/files/usr/bin/batpower:44-45]** |
| B16 | Issuing station <-> phone synchronisation (rosters, revocations, recognition secrets) [review v2-A m14; review v1-B M12] | not chosen (station LAN, mesh IP, QR) | does not exist yet |

---

## 3. Assumptions, the two platform states, and what is verified

### 3.0 Two platform states instead of "civil / tactical"

Production hardware is the CM4 (user decision 2026-10-23; `255-608b-config.md` §7.3). The CM4 supports secure boot
(issues #115, #74). **User decision 2026-11-23: secure boot ON for all builds, and nothing ships to customers before
the chain (#115 / #74 / #47 / #41 / #111) is complete** (`255-key-authority.md` §6). The states below therefore
describe versions, not products:

| Period | State | What it may claim |
|---|---|---|
| #255 (v2.0, 608B bring-up), development and bench units | OFF, with chip | R2, R3, R5, R14 (partly), R84 by chip configuration; R102 against non-root processes only. Nothing that relies on the node resisting a holder (R4 against a holder, Appendix A item 19) |
| Between the first and the last link of the chain | mixed | As OFF, except: secure boot without encrypted data = S2 as OFF; encrypted data without secure boot = OFF |
| Shipping | ON | Everything marked "ON" below, subject to the overlay assumption |

Two states are analysed:

- **State OFF** — secure boot off and the data partition in plaintext. This is every node today
  (**[D docs/design/219-field-provisioning.md:27]**: p5 / p6 not encrypted, by decision).
- **State ON** — secure boot on **and** the data partition encrypted (#111). **Assumption, unverified (#111 has no design yet):** the writable overlay (init scripts, configuration) is covered by the encryption and by the verified chain; if it is not, a card reader gives code execution on an ON node and S1-ON is false.

All that is assumed about the Pi secure-boot mechanism, and nothing more [A]: a public-key hash is programmed into
one-time-programmable memory; the bootloader then verifies a signed boot image; this is irreversible; the
verification chains to the root filesystem **only if dm-verity or an equivalent continues it**. No rollback
protection of the boot chain is assumed, and where the key of the encrypted partition is kept is not decided here.
Mixed states (the table above) are the period between the first and last link: secure boot without #111 leaves S2 as in OFF; #111 without secure boot is
treated as OFF, because whoever boots their own OS on the node is inside whatever unlocks the partition [A].

### 3.1 Assumptions

"Differs?" says whether the statement changes between the two states. S1–S21 are the base's; S22–S31 were added in
the merge.

| # | Statement | Differs between OFF and ON? | Evidence |
|---|---|---|---|
| S1 | Whoever holds the node can boot any OS on it and drive the SE from that OS | **Yes.** OFF: true. ON: the holder cannot boot their own OS — as far as the chain reaches (root filesystem included only with dm-verity or equivalent). Driving the SE from *another* host wired to the HAT is not prevented by secure boot [A] | OFF: task statement; ON: [A] |
| S2 | The SD partitions holding the provisioning record are plaintext | **Yes.** OFF: true. ON: encrypted (#111, design not written [A]) | **[D 219-field-provisioning.md:27, :492]** |
| S3 | The node has no trusted clock | No. An RTC (#174) is a separate product choice and is trustworthy only if set by an authenticated source. [v2.2] Decided: RTC from v2.0 (#174) (header), still settable by the holder | task statement |
| S4 | Node identity today = a P-256 key file on the card; a reflash makes a new identity | No (changes with the SE backend, not with the boot state) | **[V keystore/keystore.go:1-5]**, **[D 219-field-provisioning.md:335]** |
| S5 | Purpose labels ("the node never signs a caller's value") are enforced by helper software, not by the key store | No: true in both unless the SE configuration enforces it | **[V keystore/keystore.go:78-98]** |
| S6 | At most 4 owners and 4 admins per node; the last owner cannot be removed except by reflash | No | **[V provstore/provstore.go:147, 181]**, **[V node/node.go:954, 983-984]** |
| S7 | Version v+1 of a network is accepted on ONE signature by ANY admin of version v and may replace the whole admin set | No | **[V node/node.go:1192, 1227]** |
| S8 | Only a contiguous chain is accepted; a node that applied one v+1 cannot move to a competing v+1 | No | **[V node/node.go:1200-1202]**; the spec says "smaller hash wins, nodes switch" **[D 219-protocol.md:367]** — code and spec differ |
| S9 | The node neither stores nor consults the member list; membership = knowing the password | No | **[V node/node.go:1214]** |
| S10 | Removing an owner does not remove the SSH keys that owner installed, nor change the root password | No | **[V node/node.go:966-995]** (only `Owners` and `AdvOwnerKey` change) |
| S11 | Claim hands the node's root password to the claimant | No | **[V node/node.go:587, 609]** |
| S12 | The "claimed before" counter is a field of the record, not hardware | Partly. OFF: editable with a card reader. ON: not editable without the partition key, but the whole card image can still be put back (encryption is not freshness [A]). An SE counter is planned | **[V node/node.go:592]** |
| S13 | Factory reset over the protocol does not exist (`reset` -> E_UNSUPPORTED) | No | **[V provd/session.go:641-642]** |
| S14 | Phone keys: StrongBox preferred, TEE fallback, the ECDH key can be SOFTWARE on some phones; **no key is bound to user authentication**; no key attestation is requested | No | **[V app/android/app/src/main/kotlin/dev/batman/batman_app/keystore/Keys.kt:79-98]** (grep of `app/android` for `setUserAuthentication` / `setAttestationChallenge`: no hit, re-run in the merge), **[V app/android/app/src/test/kotlin/dev/batman/batman_app/keystore/KeyPolicyTest.kt:50-53]** |
| S15 | App data is excluded from cloud backup and device-to-device transfer | No | **[V app/android/app/src/main/AndroidManifest.xml:29-30]**, **[V app/android/app/src/main/res/xml/data_extraction_rules.xml]** |
| S16 | `node_cert` (the SE-signed binding of the per-boot Noise key and of the ECDH public key) has no verifier freshness and never expires | No (by design) | **[D 219-protocol.md:78]** |
| S17 | The ECDH slot gives the shared secret to the host | No (planned in both) | **[D 219-protocol.md §7.3]**, chip [A] |
| S18 | Planned recovery of a lost owner phone = body QR + button on the node, network settings kept | No (planned) | **[D 219-field-provisioning.md:432]** |
| S19 | A shared `team_ap_psk` travels in each node's secrets bundle | No | **[D 219-protocol.md:341]** |
| S20 | The issuing station holds its CA key live after a boot-time FIDO2 unlock and already co-hosts a TAK CA | No | **[D ICS threat_model §8.3, §8.8]** (reference only; not in this worktree) |
| S21 | provd terminates the Noise session, so every plaintext that crosses it is visible to provd | No | **[V provd/noise.go:38-39]**, **[V provd/session.go:390-392]** |
| S22 | Secure boot is available on the production board and is ON for all shipping builds (user, 2026-11-23; §3.0) [merge: premise correction] | — | **[D 255-key-authority.md v3.1 §6]**; issues #115, #74 [A] |
| S23 | Today a node *enters* a network only on a fresh, in-session owner authorisation; only updates of the network it already holds travel without one, and a member-role session may send them [author v1 R9; review v1-A B3; review v1-B B1] | No | **[V node/node.go:778-787, 1106-1113]**, **[V provd/session.go:82]** |
| S24 | The network version is capped at 32 bits today [review v1-B M1] | No | **[V node/node.go:1057]** |
| S25 | An image older than a record format refuses it: exactly 11 or 12 keys and `v == 1`, otherwise a schema error or "too new", reported as `unknown(too-new)`; state-changing verbs are refused while the slot is a trial [review v1-A M8; v1-B M7; v2-A m6; v2-B M7] | No | **[V provstore/provstore.go:59-61, 112-131]**, **[V boot/boot.go:270-271]**, **[V node/node.go:251-259]** |
| S26 | Secret-bearing replies to the phone (root password, owner tag key, advert key) pass through provd in clear today; the mesh password does not — it arrives wrapped to the node's ECDH key and that key is used only inside the helper [review v2-A M1 and its "facts" item 1] | No | **[V node/node.go:609, 672]**, **[V provd/session.go:71-73, 390-392]**, **[V keystore/keystore.go:60-61]** |
| S27 | The handshake tries exactly 6 pre-shared-key candidates and maps the index to a role (4 owner, 1 member, 1 replay) [review v1-A M5; v1-B M5] | No | **[V provd/noise.go:20-21, 74-76]**, **[V provd/server.go:738-781]** |
| S28 | A stored network configuration is not re-verified against the current admin set [review v1-B M2] | No | **[V node/node.go:1169-1171]** |
| S29 | The identity backend is fixed by a marker file; anything but "file" is refused today; on the file backend the device id is the hash of the identity public key, so a move to the chip is a new identity. An earlier decision says an SE backend whose chip does not answer makes the helper refuse to start [review v1-A m7; v2-A m12; v2-B M8] | No | **[V keystore/keystore.go:42-46, 266-267]**, **[D docs/design/254-stage1-impl.md:215]** |
| S30 | The rekey flow in the app refuses unless this phone is the sole admin, and the first network version lists only its creator [review v1-B B2] | No | **[V app/rust/batman-proto/src/rekey.rs:102-103]**, **[V app/rust/batman-proto/src/joinflow.rs:157]** |
| S31 | The provisioning record is capped at 64 KiB and has one commit point (the hash in `prov.meta`) [author v1 R7; review v2-A m4] | No | **[V provstore/provstore.go:10, 66]** |

### 3.2 What possession of a node gives, per state

Consequence of S1 + S2 + B7, stated once.

**State OFF: physical possession of a node equals root on that node plus unrestricted use of its SE.** No design
changes that.

**State ON: physical possession gives neither a root shell nor the card's contents by itself — but three things do
not change** [A]:

1. The SE sits on a HAT. A holder can wire it to a host of their own and issue any command the chip's
   configuration allows, unless use of the chip's keys is tied to something only the verified node software holds
   (Appendix A item 19). T-SE1 … T-SE6 therefore remain in state ON until that is decided.
2. The whole card can be imaged and written back. Encryption hides and prevents editing; it does not prevent
   returning the node to an earlier state (T-SE7) unless freshness is anchored outside the card.
3. A bug in the verified software (X7 reaching root, or any local escalation) gives, for as long as it lasts, what
   OFF gives permanently.

State ON also adds things to protect: the boot-chain signing key (A12), and the fact that the step is irreversible
(X12: a wrong key hash or a lost signing key cannot be corrected on that unit).

What a design *can* guarantee in **both** states is: (i) SE keys cannot be copied out; (ii) possession of one node
gives no authority over any other node; (iii) what was obtained during possession stops being useful once the node
is revoked or returned. Every requirement below is written against those three properties, never against "the node
protects its secrets". State ON is defence in depth on top of them, not a substitute.

### 3.3 Threats and residual risks whose answer differs between the states

| Item | State OFF | State ON |
|---|---|---|
| S1 / S2 / §10-1 capture of a node (X2) | Root, card contents and SE use at once; the mesh password in use is lost | No root and no card contents by possession alone; SE still usable from another host unless Appendix A item 19 is decided; a software bug restores the OFF outcome. The password must still be treated as lost once the node is reported: the report cannot tell which case applies |
| T-SE1 … T-SE4 SE as signing / decryption / proof oracle (X3, X11) | Reachable from the node's own OS or from another host | Reachable from another host wired to the HAT [A]; not from the node's own OS without a software bug |
| T-SE6 counter and key destruction | By root on the node or any bus master | By any bus master [A]; from the node only through a software bug |
| T-SE7 record rollback | Restore an old image; valid bare hash | Restore an old encrypted image: same effect unless freshness is anchored outside the card |
| T-SE8 record edit | Edit `prov.cbor`, fix the hash | Not possible without the partition key |
| T-SE9 bus disclosure | A host-side key on the card protects against nobody | A host-side key held by verified software is a real control; decide it (Appendix A item 10) |
| T-MS1 (c), AT5-1, F12 member reads the password from the card they carry | Yes | Not with a card reader; yes through any member-reachable software path that returns it (R68 must hold) |
| T-SE12 / R13 node-signed reports | Prove presence of the chip only | Still not proof of software state: nothing here assumes measured boot or attestation of the running image |
| L9 physical downgrade | Any image, signed or not, by reflashing | Only an image the boot chain accepts; an *older validly signed* image still boots (no boot-chain rollback protection is assumed), so R71 / R77 are needed in both states |
| F11 / R67 buyer verifies factory state | Reflash a new card and trust nothing on the old one | The buyer cannot run their own image to inspect; verification must come through the product itself, and an ON node can never be repurposed with other firmware |
| L11 decommissioning | Chip keeps identity and claim secret | Same, plus the OTP anchor is permanent |
| R11, R12, R55 "detectable by others" wording | Required because the node itself cannot resist | Still required (items 1–3 of §3.2); the attacker's cost is higher |
| A12, X12 | n/a | New asset and a new irreversible mistake |

---

## 4. Actors

| Id | Actor | Capabilities |
|---|---|---|
| X1 | Remote RF attacker | BLE / HaLow / Wi-Fi range; records advertisements, handshakes, WPA handshakes of phone APs; replays; no keys |
| X2 | Captor of a node | S1+S2 (state OFF; for state ON see §3.2): root, SE as an oracle for as long as held; may keep it or return it (evil maid) |
| X3 | Brief-access attacker (minutes): repair shop, reseller, courier, colleague | photographs the body QR; images the SD card; runs chip commands; presses the button; plugs into `eth0` |
| X4 | Thief of an unlocked admin phone | every key the app holds (S14) until revocation reaches each node |
| X5 | Removed member / removed admin / former employee | old passwords, AP passwords, root passwords they were shown, SSH keys they installed, old signed objects, the roster; possibly an SD image of a node |
| X6 | Malicious or coerced current administrator | full admin rights used deliberately; coercion happens in the field, offline |
| X7 | Compromised provd (BLE / HTTP parser bug) | S21: reads all session plaintext, holds the per-boot static key, talks to the helper socket |
| X8 | Compromised issuing station (host, operator session, stolen backup) | signs with the issuing key; reads the enrolment database; withholds or rolls back revocations |
| X9 | Privileged automation / AI agent on the issuing host or a maintainer's machine | whatever the host user can do without a hardware gesture; fast, at scale, steerable by data it reads |
| X10 | Paper thief | reads recovery material or a body QR once, leaves no trace |
| X11 | Factory / supply chain / interdiction | chooses the SE configuration, may inject known keys instead of generating, keeps the claim-secret table, pre-signs statements with the chip, swaps chips |
| X12 | The maintainers' own mistakes | dev-trust build shipped, test root in a release image, config zone locked wrong, label / secret mismatch, a migration that leaves the old authority alive |
| X13 | Compromised phone OS / malicious app update / repackaged app | uses Keystore keys in-app, phishes enrolment, exfiltrates cached secrets |
| X14 | Another organisation (colluding, hostile, or look-alike) | valid credentials under its own root; legitimate presence during mutual aid; identical display names |
| X15 | TAK-side attacker on the same phone or AP | malware in another app; any device on the phone-AP LAN (port 8095 and the bridge) |
| X16 | Insider at the vendor | release signing, manufacturer CA, any support "unlock" tooling |
| X17 | Seizure / inspection of a low-privilege member's unlocked phone | roster, cached passwords, node list |
| X18 | Current holder of a valid low-privilege credential (member, viewer) [author v1 T3] | logs in legitimately; tries verbs, scopes and objects above the role; replays what the role let them read |
| X19 | Local non-root process on the node [`docs/design/REVIEW.md` item 5; review v2-A m1] | whatever a non-root uid can open: sockets, device nodes with loose modes, world-readable files, `/tmp` |
| X20 | Compromised tenant / container on the node (the node has container bridges, **[D docs/design/254-p3-impl.md:62]**) [`REVIEW.md` item 5] | as X19 plus whatever devices, mounts and networks the container was given; a network position on a local bridge |
| X21 | Holder of a delegated issuing right below the root (registrar, equipment officer, a station's issuing phone) acting beyond it, or whoever steals that credential [review v1-A B1, B2; review v1-B M4] | issues credentials; signs anything the verifier rules do not explicitly forbid an intermediate to sign |

Coverage of the actor list in `docs/design/REVIEW.md` item 5: remote attacker over the mesh or Wi-Fi = X1, X5, X15;
local non-root process = X19 (and X7 for provd itself); compromised tenant or container = X20; physical capture of a
node or SD card = X2, X3; supply chain = X11, X16; our own mistakes = X12.

---

## 5. STRIDE threats and requirements

Format: threat -> **R** what any acceptable design must make true -> **Res** what cannot be solved.
Requirement numbers refer to the checklist in §9.

### 5.1 Secure element and node hardware (B7, B8) — the part that becomes irreversible

**T-SE1 (S, E) Pre-signed node identity outlives custody.** Today the identity key signs
`label ‖ s_node_pub ‖ boot_id` once per boot and the result never expires (S16). With the chip in hand for five
minutes, X3/X11 generates their own Noise static key, has the chip sign it, and can then pose as that node
indefinitely with no chip — a software clone of a "hardware" identity. The software rule that prevents this today
(S5) does not exist at the chip boundary (B7).
-> **R1, R2.** Res: while the attacker still holds the chip, relay to it always works.

**T-SE2 (I, E) Forged binding of the encryption key.** The same oracle signs `"…ecdh…" ‖ attacker_public_key`.
An administrator who trusts that signature then encrypts every future password bundle for "that node" to a key
the attacker owns. Brief access becomes permanent, passive knowledge of every future mesh password, surviving the
return of the node. This is the highest-value use of a signing oracle in this system.
-> **R1, R3** (the binding between "identity" and "decryption key" must be something the chip itself can attest
only for keys that live in the chip, e.g. an internal-only attestation path; an identity key that signs arbitrary
external digests cannot give this). Res: none if R3 holds; total if it does not.

**T-SE3 (I) Decryption oracle and no forward secrecy.** S17: whoever drives the chip decrypts any bundle ever
addressed to the node, including ones recorded earlier from a courier phone or chat. -> **R4, R20.**
Res: bundles issued before the loss was reported are readable by the captor; mitigated only by rekey.

**T-SE4 (S) Claim-proof oracle.** The claim proof is `SHA-256(K ‖ challenge ‖ …)` in the chip's CheckMac layout
**[D 219-protocol.md §5.4]**. If the slot holding K also answers the chip's MAC / digest-derivation commands
[A], anyone driving the chip produces valid proofs without ever seeing the QR. Then "proved knowledge of the body
QR" means only "had bus access", and any flow that shows this proof to a third party (issuing station, another
admin) is forgeable by X2/X3/X7-with-root. -> **R5.**

**T-SE5 (E, I) The claim secret is forever.** A secret that is printed on the body and fixed in a locked chip is
known for the life of the hardware to everyone who ever saw the unit: factory, reseller, repair, previous owner,
anyone who photographed a firefighter's kit. Today a reflash invalidates it (S4); with the SE it survives
(**[D 219-field-provisioning.md:512]** "QR still valid after reflash"). Combined with S18 (QR + button replaces the
owner and keeps the network settings), a found or seized node yields ownership *and* the network configuration.
-> **R6, R7, R8.** Res: a QR on the body is a secret an adversary with the node always has.

**T-SE6 (D) Counter and key destruction.** A monotonic counter that any bus master can increment [A] lets
X2/X7-with-root burn it to its ceiling (about 2 million [A]) or advance it past the value the record expects. If
the design treats "counter ahead of record" as tamper and locks, any root-level bug becomes a permanent brick;
if it treats it as benign, the counter protects nothing. The same question applies to any slot that allows key
regeneration: a regenerable identity is a privacy feature at resale and a destruction primitive in the field.
-> **R9, R10.** Res: per-node denial by whoever has root on that node is unavoidable; it must stay per-node and
be repairable by the organisation.

**T-SE7 (T) Rollback of the plaintext record.** B8: restore an old card image and the node returns to an older
admin set, older password, older owner list, with a valid bare hash. A removed admin who kept an image of a node
regains authority over that node; a "reset" node can be un-reset. -> **R11.** Res: in state OFF (and in state ON by restoring an older, still valid image, §3.3) the attacker with
the card also has the chip and can bypass any check in software; the requirement is that *other parties*
(phones, other nodes) can detect a rolled-back node, not that the node resists.

**T-SE8 (T, E) Record edit instead of protocol.** B8: add an owner key, an admin key, or an SSH key to
`prov.cbor` / overlay offline and fix the hash. Node-local takeover without any credential. -> same boundary as
S1; **R12** (possession of a node never yields authority over others) and **R13** (a tampered node's statements
are not trusted beyond its own identity).

**T-SE9 (I) Bus and at-rest disclosure.** Shared-secret output and any slot read cross I2C in clear unless the
chip encrypts them, and an IO-protection key stored on the same SD card protects against nobody who has the
card. -> do not count bus encryption as a control in state OFF; decide it for state ON (**§8.2** item 10, §3.3).

**T-SE10 (T, X11) Injected rather than generated keys.** If the configuration allows writing a private key,
the factory (or an interdictor before lock) can ship nodes whose "hardware" keys are known. -> **R14.**

**T-SE11 (X12) Irreversible mistake.** The configuration zone lock cannot be undone and there are few spare
chips. A wrong bit in one slot's policy silently enables T-SE1/2/4/10 for every unit of the batch.
-> **R15** and the list in **§8.2**.

**T-SE12 (S) SE attests the chip, not the software.** Without measured boot the chip signs for any firmware. A
"status" or "I applied the new password" statement signed by the node key proves presence of the chip only.
-> **R13.**

**Added in the merge (T-SE13 … T-SE16).**

**T-SE13 (S) The printed secret does not commit to the chip's identity key.** [review v2-B M1; review v2-A m10]
If the label carries only an identifier and the claim secret, anyone who photographed it (X3, X10) can stand next to
the buyer, answer as that node with a software key, pass the claim proof (they know the secret), be enrolled, and
later receive a node credential and the network password. An account with the enrol right at the station (X8, X9)
can likewise obtain an organisation credential for a key that is in no chip. Today the device id is the hash of the
identity public key (S29), which is what stops this; a chip-serial identifier would silently remove it.
-> **R84, R3.** Res: none if R84 holds.

**T-SE14 (D, E) The SE is absent, silent, swapped or blank.** [author v1 R21; review v2-B M8; review v2-A m12]
Transient bus failure at boot, a replaced HAT under a card that still holds the old enrolment, a card moved to
another node, a blank or unlocked chip, a marker file that disagrees with the hardware. The dangerous outcomes are:
the node quietly makes itself a software identity; the node accepts new authority while unable to prove who it is;
or a healthy network is taken down because one chip did not answer once. The sources disagree on the intended
behaviour (S29: "helper refuses to start" vs v1-R21: "keeps its network, refuses new settings") — see the merge
notes; the requirement is that the behaviour is decided, stated and tested, and never a fallback identity.
-> **R101.** Res: a node whose chip is dead cannot prove its identity and drops out at the next rekey.

**T-SE15 (S, I, D) Local non-root code or a container reaches the SE bus.** [review v2-A m1; `REVIEW.md` item 5]
The chip moves the node's secrets from mode-0600 files to a device node. Whoever can open it (X19, X20) can do what
T-SE1 … T-SE6 describe without being root and without touching the card: sign caller-chosen digests, use the ECDH
key as a decryption oracle, step the counter, or simply hold the bus so that no signature is ever produced. The bus
is already shared with another tool (B15).
-> **R102.** Res: a process that is root on the node has the bus in state OFF; in state ON see §3.2 item 3.

**T-SE16 (I, S) The printed secret used as a standing key.** [review v2-A M4, M5; review v2-B B1(a)]
Any design that derives a handshake or recognition secret from the body label (for example to let a recovered phone
find its nodes) creates an identifier that is per node, permanent and not rotatable, known to everyone who ever saw
the label — every enrolling administrator, the factory, a repair shop. A successful handshake under it is a yes/no
oracle for "this advertiser is device X". It also contradicts a chip slot that only answers a comparison: the
derived value must then either come out of the chip (a derivation oracle for any bus master, T-SE4) or live on the
card (lost at reflash; readable in state OFF).
-> **R94, R5, R6**, Appendix A items 5 and 17. Res: if such a path is kept for any build, R53 / R54 do not hold
against label holders for the life of the hardware; say so.

### 5.2 Organisation root and issuing station (B1, B2, B3, B4)

**T-OR1 (E) Root compromise / root loss.** Either ends the organisation's authority (A1). Offline storage shifts
the risk to the ceremony, the backup copies and the recovery material. -> **R16, R17, R18.**
Res: a root holder acting maliciously cannot be stopped by cryptography in a single-root design.

**T-OR2 (E) Issuing station as a live signing oracle.** S20: after boot-time unlock the issuing key is usable by
every process on the host — an operator's browser session, a container escape, an automation or AI agent (X9), a
restored backup on other hardware. One call = a valid administrator for any network of the organisation, valid
offline in the field with no way for nodes to phone home. -> **R19, R21, R22.**
Res: a compromised station can mis-issue until someone notices; nodes cannot tell.

**T-OR3 (T, R) Revocation is not monotonic across restore.** Restoring the station from a backup forgets
revocations and issued serials: the stolen phone is trusted again, and the audit trail forks. -> **R23.**

**T-OR4 (S) Cross-purpose credentials.** The station issues login certificates, TAK client certificates and now
mesh-authority credentials. If any two share an issuer or a format that the other verifier accepts, a TAK client
certificate (handed to many low-privilege devices) becomes an admin credential or vice versa. The sister
product already found that two CAs had to be isolated **[D ICS threat_model §8.3]**. -> **R24.**

**T-OR5 (S) Enrolment of the wrong phone / wrong key.** Remote or relayed enrolment (photo of the enrolment QR
sent to an accomplice), enrolment of a software key on a rooted phone (then copied — a shared account in
practice), enrolment through a repackaged app. -> **R25, R26.**
Res: offline, the station cannot check Google's attestation revocation list; a phone compromised below the
keystore is out of reach.

**T-OR6 (S, X14) Look-alike organisation.** An organisation is a public key; its name is self-asserted. A hostile
"Fire Bureau — Station 3" root enrols a member's phone or a spare node, or presents itself during mutual aid.
-> **R27.**

**T-OR7 (R) Shared signing identity.** If administrators of one network share a key (or a key derived from a
shared secret) no action is attributable, and removal of one admin means re-keying all. -> **R28.**

**T-OR8 (E) Family build: the root is a phone in the field.** The "one mechanism" must allow root = everyday
phone. Then theft of one unlocked phone (X4) is root compromise, and the recovery material (paper or a second
device) is a second root that sits in a drawer (X10). -> **R17, R18, R29.**
Res: in the family build, root security equals the phone's lock screen plus the drawer.

**T-OR9 (D) Station unreachable for days.** Anything that *requires* the station (renewal, revocation, adding a
node, replacing a phone) fails in the field; anything that does not require it is done by a field credential
that must therefore be powerful and long-lived. This tension is the centre of the design. -> **R30, R31.**

**Added in the merge (T-OR10 … T-OR14).**

**T-OR10 (E) An intermediate issuer reaches beyond its delegation.** [review v1-A B1, B2; review v1-B M4;
author v1 R1, R2] Three shapes, all found in the first design draft: (a) a registrar may sign the object that names
the organisation's root, so one branch registrar (X21) replaces the root on every node it walks past and the root's
revocation of that registrar no longer verifies there — a registrar compromise costs the same as a root compromise;
(b) "permissions are a subset of the parent's" without an issuer rule lets any directly issued person or node
credential issue further credentials, including a captured node using its chip as the signer (T-SE1); (c) a scope
written in prose ("this station only") that no node can check because the node does not know which station it
belongs to.
-> **R81, R55, R31, R104.** Res: a compromised intermediate can mis-issue leaf credentials within its real scope
until the root revokes it.

**T-OR11 (E, T) Revocation does not survive re-enrolment, or its floor is self-referential.** [author v1 R6, R7;
review v1-A M1; review v2-A B1; review v2-B M10] (a) A freshly enrolled or factory-reset node holds no revocation
data; if "no list" is read as "nothing revoked", a stolen and revoked credential is fully valid on every spare and
every reset node until an honest administrator happens to visit it — a race the attacker can win. (b) If the
minimum acceptable revocation state is carried to the node by an object signed by the very issuer the list would
revoke, a compromised issuer supplies its own low minimum. (c) If minimums only rise and a party below the top
authority can set one, it can set the maximum: no list ever reaches it and every node refuses all credentials
until physically reset — the cost of a root leak, reached from the daily host. (d) Without a clock nothing can be
pruned: the list grows inside a 64 KiB record (S31), and an "invalidate everything issued before generation N"
escape means re-issuing every person and visiting every node. (e) Serial numbers allocated by a counter that does
not survive a station restore repeat (T-OR3).
-> **R85, R86, R87, R23.** Res: the window until revocation data first reaches a node.

**T-OR12 (E) Rights that amount to root on a node, and the authority to update software.** [review v1-A M6;
review v2-A M8; review v2-B M9; author v1 R3] A credential that may set SSH keys, reset the root password or change
any setting that leads to code execution is top authority over that node in state OFF (root reads every stored
secret and rewrites the authority record) and nearly so in state ON, whatever the role is called. If such rights
can be issued by an intermediate, or organisation-wide, the role model is decoration. The opposite failure: if
*starting a software update* is put in that class and that class needs the offline root per node, either every
update round is a root ceremony or the ceremony signs one long-lived all-nodes credential that sits on a field
phone and never expires (S3).
-> **R82, R115, R34.** Res: whoever legitimately holds root-equivalent rights on a node is trusted with it.

**T-OR13 (E) The root is on, or derivable from, the daily host; the ceremony signs what that host prepared.**
[review v1-A M7; review v2-A m11; author v1 R10] If the organisation root is a software key derived from the issuing
station's master secret, compromise of the station (X8, X9, a stolen backup) is root compromise and any other key
derived from the same master (the co-hosted TAK CA, T-OR4) is separated in name only; rolling the root by changing
a derivation label does not recover from a leaked master. Even with a properly separate root, the custodians sign
inputs the daily host prepared (an issuer public key, the anchor list, "last version used"): an attacker already on
that host gets its own key certified as a second issuer nobody knows to revoke.
-> **R97, R98, R19, R24.** Res: a compromised ceremony machine.

**T-OR14 (D, E) Replacing the top authority orphans what exists; recovery material outranks its owner.**
[review v1-A M9, m10; review v2-A M6, m9; review v2-B B2, m2; author v1 R16] (a) If the organisation's identifier
is derived from the top key, or each network records "the key I was created under", then after a planned roll-over
or a recovery nobody can update or rekey the existing networks — in exactly the case (lost phone that knows the
password) where a rekey is the required next step — and during a node-by-node roll-over no single update is
acceptable to both rotated and not-yet-rotated members. (b) A thief with the unlocked top phone removes the
recovery path before the owner uses it. (c) Whoever holds a *copy* of the recovery material can replace the top
authority **and** the recovery entry; the owner cannot "switch back with the card" (the author's v1 said they
could; both round-2 reviewers showed otherwise) and is left with a physical reset of every node. (d) Paper holding
a private key is in practice a screenshot in a cloud photo library.
-> **R114, R96, R16, R17, R29.** Res: a holder of the recovery material is the root (§10-5, §10-12).

### 5.3 Phone and app (B5, B10, B13)

**T-PH1 (E) Stolen unlocked admin phone.** S14: no per-use authentication. Today's blast radius, verified: one
admin signature replaces the admin set (S7) and issues a new password to nodes of the thief's choice; `owner`
rights give `ssh_keys/set` and `root_password/reset` (**[D 219-protocol.md §5.3]**), i.e. persistent root on every
node that phone owns. -> **R32, R33, R34.**

**T-PH2 (T, E) Admin set seizure by one admin.** Same mechanism used by a malicious admin (X6) or a removed one
with a head start (X5): publish v+1 that removes everyone else. S8 makes it worse: nodes that took the hostile
v+1 cannot take the legitimate one, so the legitimate admins lose those nodes until a physical visit; if the
spec's "smaller hash wins" rule were implemented instead, the attacker grinds the hash and wins deterministically.
-> **R33, R35.**

**T-PH3 (I) Member phone as a secret store.** Member apps hold `net_root` for every version and couriers hold
other nodes' bundles **[D 219-protocol.md §7.4, §7.5]**. A seized low-privilege phone (X17) discloses the roster
and lets the holder act as a member; bundles are encrypted per node but reveal who is in the network.
-> **R36, R37.**

**T-PH4 (S) Human-channel substitution.** Invite / request / approve images travel in a chat; the 6-digit code
is the only binding and its strength rests on certificates being unforgeable **[D 219-protocol.md:260]** — which
T-SE1/2 and a factory CA leak (A4) undermine. Under time pressure people skip the comparison. -> **R38.**

**T-PH5 (E, X13) App update or OS compromise.** A signed app update is authority (A2). A repackaged app cannot use
the keys but can run the enrolment ceremony and capture what the user types or scans. -> **R26, R39.**
Res: the app publisher is trusted; state it.

**T-PH6 (I) Secrets shown to people.** Root passwords, Wi-Fi passwords, recovery words displayed on a phone are
photographed, screenshotted on other devices, typed into notes. S11: every claimant has seen a root password.
-> **R40.**

**T-PH7 (R) No trusted time on either side.** Phone clocks are user-settable; nodes have none. Anything ordered
by timestamp (audit, "latest wins", expiry) is forgeable by setting a clock. -> **R41.**

**T-PH8 (D) Phone replacement / loss with partial state.** A new phone has no version history. If catching up a
stale node needs every intermediate version (S8), a network whose admins all replaced phones can never update a
node that was off for a year. -> **R42.**

**Added in the merge (T-PH9 … T-PH11).**

**T-PH9 (I, E) A node, phone or station that hands out the current network secret is an oracle for revoked
people.** [review v2-A M1, M2; review v1-B B2] A second administrator must be able to take over a network without
the first one's phone (S30: today's code refuses instead of solving this). The tempting answer is a request that
returns the current password to any holder of an administrator credential. Two consequences: (a) the reply crosses
provd (S21, S26), so a compromised provd obtains the mesh password, which it cannot today; if the key the reply is
wrapped to comes from the request without being covered by the signed part, provd simply substitutes its own;
(b) rekeying stops excluding a revoked administrator unless the revocation reached every node first — one node
that has the new state but not the new revocation list answers the revoked credential with the *new* password, so
the prescribed remedy for a stolen phone is void. The baseline needed nothing delivered: a removed party simply
never received the new password.
-> **R105, R106, R107, R43.** Res: a still-valid administrator can read the secrets of the networks they
administer; that is the role.

**T-PH10 (D) User presence per use makes ordinary work impossible, or silently destroys the key.**
[review v2-B M4] If every use of an authority key needs a biometric or PIN and every login is a use, viewing eight
nodes is eight prompts and a rekey sixteen (the reviewer's count, not measured); people will defeat it. On Android,
enrolling a new fingerprint invalidates authentication-bound keys by default and a phone without a secure lock
screen cannot create one [A — platform behaviour as reported by the reviewer, not verified here]: for a family that
silently destroys the trust anchor.
-> **R109, R32.** Res: a coerced unlock (§10-8).

**T-PH11 (T) A stale or concurrent edit silently undoes a removal.** [review v1-B m6; review v2-B M5(a)]
Two administrators at two ends of a partitioned mesh both edit from the same version: one removes a lost node, the
other, unaware, removes someone else. If network state is a full snapshot ordered by a deterministic tie-break, the
nodes converge — possibly on the snapshot in which the lost node is still a member and receives the new password.
Neither administrator is told that their edit lost. Today's contiguous chain refuses the second edit (S8) at the
price of the fork in T-PH2.
-> **R93, R35, R58.**

### 5.4 Node daemons (B5, B6, B11)

**T-ND1 (I, S) Compromised provd reads enrolment traffic.** S21. Anything delivered *to the phone* in a session
(today: root password, owner tag key, AP password, upload bearer) and anything delivered *to the node* that is
not separately sealed for the helper is visible to X7, who also holds the per-boot static key and can impersonate
the node to later sessions. In the new design the tempting shortcut is to send a credential, a recovery share or
a new trust anchor "over the secure channel". -> **R43, R44.**

**T-ND2 (E) provd as confused deputy.** Mitigated today by owner-op over the raw body. The new design adds more
kinds of authorisers (organisation, station, admin, member). Each new authorisation that is checked in provd
rather than in the helper, or that is bound to a session rather than to the request body, reopens it. -> **R44.**

**T-ND3 (E, X15) The AP LAN is inside the trust boundary.** B11: a device on the phone AP is on the mesh bridge
and can reach port 8095. A member may set the phone Wi-Fi of the node they carry (wanted flow): a weak or reused
password, or one that an ex-member still knows (S19: shared `team_ap_psk`), is a standing entry to the mesh that
survives a mesh-password change. The Ethernet jack is the same with no password at all. -> **R45, R46.**

**T-ND4 (D) Lockout through the management path.** Rate limits, single-session rules and "claim window" timers
are shared resources; an X1 in BLE range can keep them busy while an administrator tries to push a revocation.
-> **R47.** Res: an attacker in radio range can always delay management of nodes within that range.

**T-ND5 (I) Member status.** The member flow (see status, set phone Wi-Fi) needs a credential on a low-trust
phone. If that credential is the network-wide member secret (today's `psk_member`), every member can query every
node and learn topology and positions. -> **R48.**

**Added in the merge (T-ND6 … T-ND8).**

**T-ND6 (D, I) Management inputs reachable from the mesh or from any bridged host.** [review v1-A m8;
review v1-B M8] If signed management objects are forwarded over the mesh, the node gains a listener on the mesh
bridge. "Only sources inside the current network" is not a property a layer-2 mesh can give: the reachable set is
every IP host bridged in (B11) — member nodes, AP clients, the Ethernet jack, a captured node. Any of them can make
the node spend CPU on signature checks, feed it oversized objects, or replay what it once saw (T-MS5). The listener
must also survive the mesh interface going down and up at every password change.
-> **R103, R46.** Res: T-ND4 applies to this path too.

**T-ND7 (E) Verbs nobody assigned to an authority.** [review v2-A m7; review v2-B m3] The existing verb set is
larger than any role table drawn so far (`diag/bundle`, `diag/summary`, `reset`, `peers/challenge`, `owner/add`,
`owner/remove`, `update/check`, `update/status`, `settings/get`, … **[V provd/session.go:60-65]**). A diagnostic
export is a file of whatever the node knows. A verb left out of the table ends up allowed by whatever default the
code has. -> **R116, R68.**

**T-ND8 (E) A cached "this credential verified", and revocation meeting stored state.** [author v1 R8;
review v1-B M2] (a) Recording that a credential passed, and letting later actions in the session or after a daemon
restart ride on that record, turns revocation into something that takes effect at the next login at best (the
sister product was caught by this, per the author's v1). (b) The opposite error: re-verifying *applied* state when
a revocation arrives makes every node drop its running network in the middle of an incident because the
administrator who built it lost a phone; and a node that learns of the revocation before it has the state can then
never accept that state. The existing code already met this and chose "stored state is not re-verified" (S28).
-> **R88, R89.**

**Added in v2.2 (T-ND9 … T-ND11).** [v2.2: IEC 62443-4-2 FR5 / FR6 check]

**T-ND9 (E, X5, X15) Maintenance services on the bridge, reachable from every node.** B11 has three entries, not
two: the phone AP, the Ethernet jack, and HaLow, because `bat0` is a port of the same bridge as the AP and `eth`
**[V feed/batman-provision/files/usr/bin/meshpoint-1.8.0:66-69, 112-113]**; batman-adv AP isolation is off
**[V meshpoint-1.8.0:93]** and the bridge's firewall zone accepts input and forward **[V meshpoint-1.8.0:137-139]**.
On that segment the node offers, besides provd's 8095: SSH, listening on every interface [A], key-only once the node
is claimed **[V feed/batman-provision/files/etc/init.d/batman-prov-lock:24-28]**; LuCI / rpcd with root-password login (the
password is random, 24 characters **[D docs/design/254-claim-lock-fix.md:45]**, but X5 may have been shown it);
the landing page and `/cgi-bin/mesh`; OTS via DNAT **[V deploy/ots/ots.fw4.uci:14-40]**. A host on node A's AP reaches node
B's SSH through B's `bat0`, so a control that looks only at a node's own AP and Ethernet ports misses it. Only 8095 is
restricted today, by ingress port and fail-closed **[V feed/batman-prov/files/batman-http.nft]**,
**[V cmd/batman-provhelper/bulk.go:89-120]** — a working pattern for the rest. Combined with S10 (SSH keys and root passwords
left behind by removed people), this turns T-MS1's "removed party keeps the password" into "removed party keeps a
shell on every node". Maintainers use SSH across the mesh today; R118 removes that by default. Decided (header, 2026-11-23):
closed by default in customer builds, may stay open in development builds, nothing else differs. -> **R118, R46, R103, R45.** Res: none for management once R118 holds; user-to-user traffic on
the segment is network-layer (header follow-up).

**T-ND10 (R) No attributable record of management actions on a node.** A11. provd and the helper write
operational messages to syslog **[V cmd/batman-provd/main.go:61]**, **[V cmd/batman-provhelper/main.go:48-51, 559]**; no
record names which credential signed which change. The ring is saved to p6 only on a clean shutdown, last ten copies
**[V feed/batman-provision/files/etc/uci-defaults/95-batman-storage:730-739]**: a power cut loses everything since
the last clean shutdown. p6 is encrypted only where the image ships cryptsetup
**[V feed/batman-provision/files/etc/uci-defaults/95-batman-storage:112-115]** and is shared with tenants
**[D docs/storage-architecture.md:26, 147]**.
So T-PH1 (stolen phone replaces the admin set), §10-6 (mis-issue found after the fact) and §10-8 (coerced
administrator, "after-the-fact attribution") have nothing to be found with. -> **R119, R121, R122, R124, R125.**

**T-ND11 (R, D) The record is erased, flushed or mis-timed.** (a) Whoever gains root (T-PH1's planted SSH key, X2)
deletes or edits the node's record; a hash chain does not help, because root can recompute it. (b) Anyone in BLE
range sends invalid requests until a bounded record has dropped the real changes. (c) Before v2.0 (#174) the node's time is
only monotonic (`batman-faketime`, #174); after it, a holder of the node can set the RTC; a forward jump is then kept.
-> **R120, R123, R119 (records ordered independently of any clock), R41, R113.** Res: §10-16.

### 5.5 Mesh and inter-organisation (B12)

**T-MS1 (E) Shared password = no individual removal.** Stated in the existing docs
**[D 219-protocol.md:315]**. Consequences that the new design must face: (a) removing a person or a node *is* a
rekey of the network; (b) the removed party keeps access to every node that has not yet rekeyed, and those nodes
are exactly the ones that are hard to reach; (c) a member physically holding a node can read the password from
the card (S2; state OFF — for state ON see §3.3) whatever role the app gives them. -> **R49, R50.**

**T-MS2 (T) The transition window.** To reach switched-off nodes after a rekey, something must still speak the
old password or a rendezvous secret. Whatever that is, the removed party speaks it too, and can use it to feed a
stale node a hostile but validly-signed-by-an-old-admin update (T-PH2 against stale nodes). -> **R35, R50, R51.**

**T-MS3 (E, X14) Mutual aid.** Station A's nodes join station B's network for an incident. Afterwards A knows B's
password, B's roster and (if admins were shared) holds signing rights. A compromise of the weaker station is a
compromise of the stronger one's network. -> **R52.**

**T-MS4 (I) Tracking.** See attack tree AT4. Identifiers visible without any key: HaLow SSID / mesh ID / MAC
addresses, phone-AP SSID and BSSID, BLE advertisement (rotating tag for claimed nodes
**[D 219-protocol.md §4.1]**, last 4 characters of the device id for unclaimed ones). Identifiers visible to
any member or ex-member: whatever recognition key lets an app find "our nodes". Identifiers in credentials:
organisation and person names in certificates presented in handshakes. -> **R53, R54.**

**Added in the merge (T-MS5 … T-MS9).**

**T-MS5 (T, S) Replay of a bearer object after leave, reset, re-enrolment or eviction.** [review v1-A B3, M3;
review v1-B B1; author v1 R9] An object that is valid by its signature alone and can be delivered by anyone is
protected against replay only by "newer than what I store". Every path that deletes what the node stores removes
that protection: leaving the network, a remote wipe, factory reset followed by re-enrolment under the same
organisation, eviction from a limited set of stored networks. Then: (a) a removed member or the holder of a captured
node replays the old network state and the node joins a network whose password the attacker knows — cut off from
its team, traffic on the attacker's mesh; (b) a remote "wipe / inhibit" object that carries no order is a permanent
keyless off-switch, replayable each time the node is re-added; (c) the intermediate "old root + new root" anchor
object of a past roll-over, replayed to a reset node, brings a retired — possibly compromised — root back.
Today (a) is impossible: entering a network needs a fresh in-session authorisation (S23).
-> **R90, R58, R51.** Res: none if R90 holds.

**T-MS6 (D) Version exhaustion, stranding, and honest devices spreading the damage.** [review v1-A M2;
review v1-B M1; review v2-A M3; review v2-B M5(b)] Any monotonic version has a top. A stolen administrator key (X4,
or X5 before revocation lands) signs the maximum version once; no higher version exists, any tie-break value can be
ground by the attacker as well as by the owner, and that network identifier is frozen on every node that saw the
object. If honest phones forward "the latest state" they read from a node, the attacker injects into one node and
does not walk anywhere. The first attempt to prevent exhaustion — a window on how far a version may jump —
strands every node that slept through more changes than the window, does not stop exhaustion (jump, jump, jump),
and gives the attacker a tool to split the nodes. The same shape applies to the version of the organisation's
anchor object against the recovery path.
-> **R92, R35, R42.** Res: unless the design avoids a ceiling altogether, a network-level credential holder can
burn a network identifier and the organisation must rebuild that network on every node (§10-13).

**T-MS7 (E) Authority that crosses its context.** [review v1-A M3, M4, m1; review v2-A M7, m8; review v1-B m5;
author v1 R4, R11] (a) A node that admits a second authority for one purpose (a club's network on a member's own
node; a mutual-aid host) lets that authority act on the node's other networks, wipe "all", or obtain node-level
rights, if scope is attached to the key and not to what a credential chain under it may carry. (b) A signed object
that does not name its kind, organisation, network, target node and signer inside the signature is accepted where
it was not meant: organisation A's credential on organisation B's node, network X's state on network Y, a list
taken for a certificate. (c) A network joined from another team by the human-compared code has no common root with
the node: who may later rekey it on this node is undefined, so either nobody can (a removed member is never locked
out) or a foreign key gains standing on the node.
-> **R83, R91, R52, R57.**

**T-MS8 (D) Delivering the new password breaks the mesh, or is slower than what it replaces.** [review v1-B M8;
review v2-B M2] Forward-then-switch over a multi-hop mesh that can hold one password at a time: the only bridge to
a far cluster switches before the cluster has the object, and everything behind it is cut off with nobody to hear
it; recovery is a person walking to each node during the incident. Carried by phones instead: a member's phone can
open a session only with its own node, so only administrators can deliver — a serial walk (reviewer's estimate:
5–10 minutes for 8 nodes, 15–30 for 30, unmeasured) with the mesh split throughout — where today each person
presses one button at their own node in parallel.
-> **R112, R60, R61, R50.** Res: §10-2; partition between updated and stale nodes is inherent, only its duration
and visibility are designable.

**T-MS9 (I) The change object tells the removed party what changed.** [review v1-A m5; review v2-B m5] A full
network state delivered in clear to every node on the old mesh gives the node being removed the new roster and the
new wireless parameters; a view-level credential that can read the signed state reads the whole roster.
-> **R108, R36, R37.**

### 5.6 Flows

| Flow | Threat (STRIDE) | Requirement | Residual |
|---|---|---|---|
| **F1 Enrol a node into the organisation** | (S) Enrol someone else's node from a photographed QR; (S) enrol a counterfeit or software "node" (A4, T-SE1); (E) first-come enrolment by shop / courier; (T) node enrolled into a look-alike org (T-OR6); (I) the enrolment secret transits provd (T-ND1) | R6, R7, R27, R43, R55: enrolment needs fresh proof of *current physical custody* and of the organisation's authority, bound to each other and to the chip; the node ends up pinning the organisation in a way a card edit cannot silently change for third parties | A node enrolled by its legitimate holder into the wrong org by deception |
| **F2 Enrol a person's phone** | T-OR5, T-OR4; (R) one person, two phones, or two people, one credential; (E) role inflation at enrolment (member issued as admin by a hurried operator or an agent, X9) | R24, R25, R26, R28, R19 | Phone compromised below the keystore |
| **F3 Create a network by ticking nodes** | (S) the list shows names an attacker chose (a node named like a colleague's); (E) admin includes nodes they have no right over; (T) a ticked node is a clone (T-SE1) and receives the password | R56, R3, R57: selection is by verified identity; adding a node needs authority over *that node* as well as over the network | A legitimately enrolled but captured node, not yet reported |
| **F4 Add a node** | as F3; (T) replay of an old "add" after removal re-admits a removed node | R58 | — |
| **F5 Remove a node / person** | T-MS1; (D) removal by a malicious admin of everyone else (T-PH2); residual credentials (S10: SSH keys, root password, AP password, LoRa PSK, TAK certificate, recognition keys) | R49, R59, R35 | The removed party keeps what they copied while legitimate, until every node rekeys |
| **F6 Change the mesh password, reach every node** | T-MS2; (I) bundles for a lost-but-unreported node (T-SE3); (T) courier replays an older bundle to keep a node on a password the attacker knows; (D) half the network rekeyed, half not = partition at the worst moment; (D) a rekey that cannot be undone when a node fails to apply | R20, R50, R51, R60, R61 | Partition between rekeyed and stale nodes is inherent; only its duration and visibility are designable |
| **F7 Report a lost node** | (S) false report as denial (anyone removes anyone's node); (D) report cannot propagate offline; (I) captor reads everything on the card at capture time | R62, R49 | Everything on the card at capture is lost; the window until rekey completes |
| **F8 Report a lost phone** | (S) false report to evict an admin; (E) the thief revokes the *other* admins first (race); the reporter has no credential left to authenticate the report | R35, R63 | Race between thief and report in a partitioned network |
| **F9 Replace a phone** | (S) "I have a new phone, add me" social engineering; old phone not wiped keeps keys; (E) replacement used to upgrade role | R64, R25 | — |
| **F10 Recovery (family: top phone lost; org: root media lost)** | T-OR8; (E) recovery material used silently; (D) recovery material lost too = orphaned hardware; (E) a vendor "rescue" path = vendor master key (X16) | R17, R18, R29, R65 | A holder of the recovery material is the root |
| **F11 Factory reset and resale** | T-SE5; (I) seller's secrets remain on flash (wear levelling **[D 219-field-provisioning.md:492]**); (E) seller keeps a credential that still works after the buyer enrols (old owner key, SSH key, pre-signed statements T-SE1/2, card image T-SE7); (D) an organisation-locked node is unsellable / an unlocked one is worth stealing; (I) buyer learns the seller's organisation, roster, network name | R7, R8, R59, R66, R67 | Data remanence on the old card; the buyer must trust the reset unless they reflash |
| **F12 Member: status and phone Wi-Fi of their node** | T-ND3, T-ND5; (E) member verb set creeps upward (diagnostics bundle, SSH, update) | R45, R48, R68 | A member holding the node has root on it anyway in state OFF (S1; §3.3) |
| **F13 A second administrator takes over a network** [review v1-B B2; review v2-A M1, M2] | T-PH9; (D) the only copy of the member list and of the nodes' encryption keys is on the lost phone; (T) the takeover edit undoes the first administrator's last change (T-PH11) | R105, R106, R107, R93 | A still-valid administrator reads what they administer |
| **F14 Update the software of the organisation's nodes** [review v2-A M8; review v2-B M9] | T-OR12; (E) the right to start an update used to downgrade or to keep nodes rebooting; (E) a member updates or downgrades the node they carry; (D) no one in the field holds the right | R115, R77, R82 | The release signer is trusted (§10-7) |
| **F15 A member picks up a node at turn-out** [review v1-B M9; review v2-B M3] | (D) the member's phone lacks what it needs for *this* node (recognition secret, a credential scoped to it, the access-point password) because assignment is delivered by a station that is unreachable; (E) the workaround is a shared password by voice | R111, R48, R45 | — |

### 5.7 Lifecycle

| Lifecycle path | Threat | Requirement | Residual |
|---|---|---|---|
| **L1 Factory provisioning** | T-SE10, T-SE11; claim-secret table and label images retained (print spooler, thermal ribbon, CI artefacts); label on the wrong unit; dev chip shipped | R14, R15, R69 | Factory insider before lock |
| **L2 First enrolment / migration from today's owner model** | The one-time move of existing nodes from "owner phone" to "organisation" is authorised by today's owner key — whoever holds it (or a card image) can bind the node to *their* organisation; old owner keys left in the record as a fallback remain a second authority | R70, R71 | — |
| **L3 Renewal** | Expiry cannot be enforced by a clockless node; a renewal that needs the station fails in the field (T-OR9); automatic renewal renews the thief's phone too | R30, R41, R72 | A stale node accepts an expired credential |
| **L4 Revocation** | Reaches only the nodes it reaches; can itself be replayed, withheld by a courier, or rolled back (T-OR3, T-SE7); revoking the revoker (T-PH2) | R23, R35, R62, R73 | Unreached nodes |
| **L5 Key roll-over** (admin key, issuing key, root, node keys, claim secret, mesh password, release key) | Each has a different owner and reach; roll-over of the root or the issuing key strands every node that was off; "periodic key change" (agency baseline) applied to keys locked in a chip is impossible unless decided now | R74, R16, §8.2 | Root roll-over needs every node visited or a pre-committed successor |
| **L6 Recovery** | see F10 | | |
| **L7 Factory reset** | see F11; a reset triggered by a card marker file or button is available to X3 | R8, R66 | |
| **L8 Upgrade / trial boot / automatic revert** | New image writes a record the old image cannot read (already a known constraint **[V provstore/provstore.go:59-61, 112-131]**); after revert the old image must fail closed, not "unclaimed"; SE state (counter, slots) written by the trial image is *not* reverted with the slot — one-way door inside a two-way update | R75, R76 | — |
| **L9 Downgrade** to an image without organisation authority | Old image honours only the old owner model; an attacker with the card flashes an old, validly signed image (physical downgrade is outside the manifest's downgrade rule) and uses a retained owner key or the QR + first-come claim | R71, R77 | Physical downgrade cannot be prevented in state OFF and is limited to older validly signed images in state ON (§3.3); in both it can only be made useless to others |
| **L10 Restore from backup** | Phone: excluded (S15), so every restore is a re-enrolment — good, but then recovery must not depend on it. Station: T-OR3. Node card image: T-SE7 | R11, R23 | — |
| **L11 Decommissioning** (node scrapped, organisation dissolved, station retired) | Chips in scrapped HATs keep identity and claim secret; a retired station's disks hold the issuing key; a dissolved organisation's nodes are locked forever or free for anyone | R66, R78 | — |
| **L12 Crash / power loss mid-change** | A change of authority (new admin set, new root pin, SE counter step) that is half-applied: record says new, chip says old, or the reverse | R76 | — |
| **L13 Identity backend change (key file -> chip)** [review v1-A m7; review v1-B M11; review v2-A m12; review v2-B M1] | A new identity, device id, encryption key, claim secret and label for every node (S29); enrolments, member lists and phone records made before do not carry over; a node that can come up on either backend has two identities | R101, R84 | Every node enrolled before the change is enrolled again |
| **L14 SE failure, HAT replaced, card moved to another node** [review v2-B M8] | T-SE14 | R101 | A dead chip = a new identity = a new enrolment |
| **L15 Enrolment or factory reset interrupted** [review v1-B M6; review v2-B M6; review v2-A m3, m4] | A chip counter and a file commit are two writes: a power cut between them leaves "counter stepped, node not enrolled" (the claim window then stays shut until a physical action the current HATs have no button for **[D 219-field-provisioning.md:78, :333]**) or "record committed, counter not stepped" (a later step invalidates what was issued in between; the pre-reset credential can be replayed). Several separately replaced files instead of one record give combinations nobody defined (anchor gone, network still present). An enrolled node that has not yet received its own credential and accepts only the top authority is, for an agency, manageable only by the offline root | R110, R76 | — |
| **L16 Automatic revert during the trial boot** (the normal safety path, not an operator's downgrade) [author v1 R18; review v1-A M8; review v1-B M7; review v2-A m6; review v2-B M7] | The trial image converts the shared record; the slot reverts on its own; the previous image refuses the record (S25) and the node keeps its mesh but can no longer be managed — a bench visit. The automatic commit branch only commits, writes its marker and logs — no hook to hang a conversion on — and a commit can also be made by hand by an operator **[V feed/batman-provision/files/usr/bin/batman-autocommit:621-622, 629-631]** | R99, R75 | — |

---

## 6. Attack trees

### AT1 — Take over an organisation's nodes

```
GOAL: command nodes of organisation O without being authorised by O
├─ 1 Become O
│   ├─ 1.1 obtain root key or recovery material (X10 drawer, X16, ceremony laptop malware)           [T-OR1, T-OR8]
│   ├─ 1.2 family build: steal the unlocked top phone                                                [T-OR8, T-PH1]
│   └─ 1.3 make nodes accept a different root
│        ├─ 1.3.1 look-alike organisation at enrolment                                               [T-OR6]
│        ├─ 1.3.2 "recover / replace root" flow reachable with less than root (QR + button, vendor)  [T-SE5, F10]
│        └─ 1.3.3 downgrade to an image that predates the pin, then first-come claim                 [L9]
├─ 2 Be issued authority
│   ├─ 2.1 drive the issuing station: operator session, agent with host access, restored backup      [T-OR2, T-OR3]
│   ├─ 2.2 get enrolled as admin: operator error, role inflation, relayed enrolment                  [T-OR5]
│   └─ 2.3 cross-purpose credential accepted (TAK / login certificate as admin)                      [T-OR4]
├─ 3 Use someone else's authority
│   ├─ 3.1 unlocked admin phone (no per-use auth) -> replace admin set -> install SSH keys           [T-PH1, T-PH2]
│   ├─ 3.2 coerce an admin in the field                                                              [X6]
│   └─ 3.3 malicious app update signs on the admin's behalf                                          [T-PH5]
├─ 4 Bypass authority
│   ├─ 4.1 signed firmware (release key, or test root left in an image)                              [A2, X12]
│   └─ 4.2 node by node: card edit / own OS (always possible in state OFF, per node)                 [T-SE8]
└─ 5 Stale authority
    └─ 5.1 revoked admin key + nodes that have not heard -> hostile v+1 they then cannot leave       [T-PH2, T-MS2]
```
Cheapest paths today: 3.1 and 5.1 (single signature, verified S7/S8), then 2.1.

### AT2 — Stay in the network after being removed

```
GOAL: keep L2 access and/or node control after removal
├─ 1 Keep a network-wide secret that is not rotated on removal
│   ├─ 1.1 shared phone-AP password (team_ap_psk), or the AP password of the node I carried          [T-ND3, S19]
│   ├─ 1.2 Ethernet jack of any node                                                                 [B11]
│   ├─ 1.3 LoRa PSK / TAK client certificate / recognition key                                       [F5]
│   └─ 1.4 old mesh password + nodes that have not rekeyed (and the transition mechanism)            [T-MS1, T-MS2]
├─ 2 Keep a per-node backdoor planted while legitimate
│   ├─ 2.1 SSH key installed as owner; root password seen at claim                                   [S10, S11]
│   ├─ 2.2 extra owner / admin key added to a node record                                            [T-SE8]
│   └─ 2.3 pre-signed identity or ECDH binding for a node I handled -> read every future bundle      [T-SE1, T-SE2]
├─ 3 Undo the removal
│   ├─ 3.1 replay an older bundle / "add" object to a node or to a courier                           [F4, F6]
│   ├─ 3.2 restore a card image from when I was a member / admin                                     [T-SE7]
│   ├─ 3.3 station restored from a backup that predates my revocation                                [T-OR3]
│   └─ 3.4 win the fork: publish my own v+1 first                                                    [T-PH2]
└─ 4 Be re-admitted
    ├─ 4.1 "new phone" social engineering against another admin                                      [F9]
    └─ 4.2 get the new password from a node I can still touch (card read)                            [S2]
```

### AT3 — Make the network unmanageable

```
GOAL: legitimate organisation can no longer change its network
├─ 1 Remove the managers
│   ├─ 1.1 one admin (stolen phone, insider) removes all others                                      [T-PH2]
│   ├─ 1.2 false "lost phone" reports                                                                [F8]
│   └─ 1.3 all admin phones replaced / lost and no recovery material                                 [T-PH8, F10]
├─ 2 Split the nodes
│   ├─ 2.1 competing v+1 -> two populations that reject each other's chain (verified S8)             [T-PH2]
│   └─ 2.2 partial rekey: stale nodes unreachable, no one holds a bundle or the history they need    [F6, T-PH8]
├─ 3 Poison monotonic state
│   ├─ 3.1 advance a counter / epoch to its maximum (SE counter, any "highest seen" value)           [T-SE6]
│   ├─ 3.2 make nodes pin a root or station key whose private half nobody holds                      [F10, L5]
│   └─ 3.3 trial image steps SE state, slot reverts, record and chip disagree -> fail-closed forever [L8, L12]
├─ 4 Lose the top
│   ├─ 4.1 root key and recovery both lost; nodes are organisation-locked                            [T-OR1, F11]
│   └─ 4.2 issuing station destroyed, field credentials expire with no renewal path                  [T-OR9, L3]
└─ 5 Occupy the path
    └─ 5.1 BLE-range attacker holds sessions / rate limits during an urgent revocation               [T-ND4]
```

### AT4 — Track or locate the organisation's nodes and people

```
GOAL: tell where O's nodes / members are, or that a given node belongs to O
├─ 1 No key needed
│   ├─ 1.1 HaLow SSID / mesh ID / MAC, phone-AP SSID / BSSID (stable, long range)                    [T-MS4]
│   ├─ 1.2 BLE: fixed service UUID = "this is a Batman node"; unclaimed nodes show id fragment       [D 219-protocol §4.1]
│   ├─ 1.3 member-chosen phone Wi-Fi name identifies the person or unit                              [F12]
│   └─ 1.4 state leak: "claimed / updating" readable by anyone -> spot fresh or mid-change nodes     [D 219-protocol §4.1]
├─ 2 With one member-level secret (ex-member, seized member phone, one captured node)
│   ├─ 2.1 recognition key lets me resolve every node's rotating BLE identifier                      [T-MS4, X5]
│   ├─ 2.2 member status queries return topology / neighbours / positions                            [T-ND5]
│   └─ 2.3 roster with names and public keys from a phone or a card                                  [T-PH3, A8]
├─ 3 From credentials on the wire
│   ├─ 3.1 certificates naming organisation / station / person presented before the peer is authenticated
│   └─ 3.2 stable public keys reused across networks link one person's roles
└─ 4 From the back office
    ├─ 4.1 issuing-station enrolment database (who carries which node)                               [A3]
    └─ 4.2 factory table: device id <-> customer                                                     [A4]
```

### AT5 — Read the mesh password without being a member

```
GOAL: learn the current mesh password of O's network
├─ 1 Any node's card (S2) — one captured or briefly accessed node (state OFF; §3.3 for ON)
├─ 2 Be an addressee: forged ECDH binding (T-SE2) -> every future bundle, no further access needed
├─ 3 Decrypt recorded bundles with a later-captured node (T-SE3)
├─ 4 In-person invite QR that contains the password, photographed                [D 219-protocol §7.6]
├─ 5 Compromised provd on a node during an operation that carries it in session plaintext (T-ND1)
└─ 6 Phone AP: capture a WPA handshake, crack a weak member-chosen password -> on the bridge, no mesh password needed
```

### AT additions from the merge

New leaves, given against the base trees without redrawing them.

| Tree | New leaf | Threat |
|---|---|---|
| AT1 §1.3 "make nodes accept a different root" | 1.3.4 an intermediate issuer signs the object that names the root | T-OR10 |
| AT1 §1.3 | 1.3.5 replay the "old + new root" object of a past roll-over to a reset node | T-MS5 |
| AT1 §2 "be issued authority" | 2.4 get a key certified at a ceremony whose inputs the daily host prepared | T-OR13 |
| AT1 §2 | 2.5 obtain root-equivalent node rights from an intermediate, or a standing all-nodes update credential | T-OR12 |
| AT1 §5 "stale authority" | 5.2 revoked credential used on a freshly enrolled or reset node that holds no revocation data | T-OR11 |
| AT2 §3 "undo the removal" | 3.5 replay the pre-removal network state after the node left / was reset | T-MS5 |
| AT2 §3 | 3.6 a concurrent edit by another administrator wins and re-lists me | T-PH11 |
| AT2 §4 "be re-admitted" | 4.3 ask a node that has the new state but not my revocation for the new password | T-PH9 |
| AT3 §3 "poison monotonic state" | 3.4 sign the maximum version of a network or of the anchor object | T-MS6 |
| AT3 §3 | 3.5 raise a revocation minimum beyond any list that will ever exist | T-OR11 |
| AT3 §4 "lose the top" | 4.3 replace the top authority and find no existing network can be updated | T-OR14 |
| AT3 §4 | 4.4 a copy of the recovery material replaces the top authority and the recovery entry | T-OR14 |
| AT3 §5 "occupy the path" | 5.2 hold the SE bus from a non-root process or container | T-SE15 |
| AT4 §2 | 2.4 the body label as a permanent recognition key | T-SE16 |
| AT4 §2 | 2.5 one stolen administrator phone = the recognition secret of every node it lists | A13, R104 |
| AT5 | 7 call the "give me the current password" request with any credential a node still believes | T-PH9 |
| AT5 | 8 from a non-root process or container: use the chip's decryption key on a recorded bundle | T-SE15 |

---

## 7. Top 15 threats, likelihood x impact

Scale 1–5 each; score = L x I. Likelihood is judged for a deployed agency customer over the product's life.

| Rank | Threat | L | I | Score | Why |
|---|---|---|---|---|---|
| 1 | T-PH1/T-PH2 One unlocked or malicious admin phone replaces the admin set and plants SSH keys | 4 | 5 | 20 | Phones get lost; verified single-signature rule (S7), no per-use authentication (S14) |
| 2 | T-MS1/AT2 Removed member or admin keeps access (un-rotated AP password, SSH key, root password, stale nodes) | 5 | 4 | 20 | Staff turnover is routine; several residual credentials verified (S10, S11, S19) |
| 3 | T-SE2 Forged ECDH binding via the SE as signing oracle -> permanent read of every future password | 3 | 5 | 15 | Needs minutes of access (repair, resale, shared storeroom); silent; irreversible once the chip is locked wrong |
| 4 | T-OR2 Issuing station used as an oracle (session, agent, backup) | 3 | 5 | 15 | Live key after unlock; sister product documents the same class |
| 5 | T-SE5 Permanent body QR + physical reset = takeover of a found / seized node with network settings kept | 3 | 5 | 15 | Planned recovery path (S18); QR is on the object the adversary holds |
| 6 | T-PH2/AT3-2 Fork: nodes split into populations that cannot converge | 3 | 5 | 15 | Verified code behaviour (S8); also reachable by honest mistake of two admins |
| 7 | T-MS2/F6 Rekey does not reach switched-off nodes; transition mechanism keeps the removed party in | 5 | 3 | 15 | Certain to occur operationally |
| 8 | T-OR1/T-OR8 Root or recovery material compromised or lost (family build especially) | 2 | 5 | 10 | Low frequency, total impact; family root lives on an everyday phone |
| 9 | T-SE11 Wrong SE configuration locked for a batch | 2 | 5 | 10 | One-shot, few spare chips, complex bit fields |
| 10 | T-ND3 Phone-AP password / Ethernet as un-managed entry to the mesh bridge | 4 | 3 | 12 | Member-chosen passwords; verified bridge layout |
| 11 | T-SE1 Software clone of a node identity from brief chip access | 3 | 4 | 12 | Same access as rank 3, lower consequence if fresh proofs are demanded |
| 12 | T-SE7/L9 Rollback / downgrade restores an older authority on a node | 3 | 3 | 9 | Needs the card; per-node |
| 13 | T-OR4/T-OR5 Cross-purpose or mis-issued credential (TAK / login / mesh; software key; wrong role) | 3 | 4 | 12 | Three credential families from one station |
| 14 | T-MS4/AT4 Tracking through stable radio identifiers and a shared recognition key | 4 | 3 | 12 | Passive, cheap, long range on sub-GHz |
| 15 | T-OR3/L8 Non-monotonic state after restore or revert (station backup, SE state vs slot revert) | 2 | 4 | 8 | Rare but silent and hard to diagnose remotely |

(Ranks 10–14 are ordered by judgement of exploit cost, not strictly by score.)

**Threats added in the merge, scored by the merging author (self-assessed, same scale).** They are threats against
*classes of design*: each exists only if the design has the feature in question, which is why the independent
author, who saw no design, did not rank them. They are not folded into the ranks above.

| Threat | L | I | Score | Why |
|---|---|---|---|---|
| T-OR11 Revoked credential valid on a fresh or reset node; revocation minimum poisoned | 3 | 5 | 15 | Spares and resets are routine; the lock-out variant costs a physical reset per node |
| T-MS5 Bearer-object replay after leave / reset | 3 | 4 | 12 | Needs only an old object; every member node has seen it |
| T-PH9 Revoked administrator reads the new password; provd sees it | 3 | 4 | 12 | Voids the remedy for rank 1 |
| T-MS6 Version exhaustion / stranding | 3 | 4 | 12 | One signature by a stolen key; spread by honest phones |
| T-OR14 Top-authority replacement orphans networks; recovery copy locks the owner out | 3 | 4 | 12 | Every family phone loss walks this path |
| T-OR10 Intermediate issuer over-reach | 2 | 5 | 10 | Makes the offline root as weak as the weakest registrar phone |
| T-OR12 Root-equivalent rights / standing update credential | 3 | 4 | 12 | Routine operation (updates) pushes toward the standing credential |
| T-MS8 Rekey delivery splits the mesh or is slower than today | 4 | 3 | 12 | Happens at every removal |
| T-SE15 SE bus reachable by non-root code or a container | 2 | 4 | 8 | Needs a foothold on the node; silent |
| T-SE13 / T-SE16 Label does not commit to the chip key / label as a standing key | 2 | 4 | 8 | Label is visible on the body; irreversible once chips are locked around it |
| T-ND9 Maintenance services reachable from every entry and every node [v2.2] | 4 | 4 | 16 | Ethernet needs no password and HaLow only the shared mesh key; removed people keep SSH keys and root passwords (S10), which overlaps rank 2. Refines rank 10 |
| T-ND10 No attributable record of management actions [v2.2] | 5 | 2 | 10 | Certain today; harmless by itself, but leaves ranks 1, 2, 4 and §10-6, §10-8 undetectable |
| T-ND11 Record erased, flushed or mis-timed [v2.2] | 3 | 3 | 9 | Flushing needs nothing; erasing needs root first |

---

## 8. Questions that are easy to overlook

### 8.1 Design questions

1. **What does a node do when the only statement it has is signed by an authority it has not been told is
   revoked?** (There is no clock; "expired" is not available.) Name the rule and the worst case.
2. **Who can change the set of administrators** — one admin, a quorum, or only a higher level? What stops the
   revoked admin from doing it first?
3. **Can a higher authority always override a lower one's fork**, offline, on a node that already applied the
   wrong branch? If not, how does such a node come back without a physical reset?
4. **What exactly is rotated when a person is removed?** List every credential class: mesh password, `net_root`,
   phone-AP password(s), LoRa PSK, SSH authorised keys, root password, owner tag keys, BLE recognition keys,
   upload bearers, TAK client certificate, station login certificate. Any not rotated is a residual access.
5. **Is the phone-AP password inside or outside the key-management plane?** It is on the mesh bridge.
6. **Does "member of a network" on the app mean anything a card reader cannot defeat?** If not, say so in the
   UI wording (roles are for convenience and accountability, not confidentiality of the password).
7. **Family build: where is the root, physically, on an ordinary day**, and what is the recovery material made
   of, given Keystore keys cannot be exported? When recovery is used, who is told?
8. **Is a physically reset node free for anyone, or still the organisation's?** Either answer has a victim
   (theft market vs. orphaned hardware / vendor master key). Decide per product, and separately for platform
   state ON, where the node can never run other firmware (§3.3).
9. **What authorises a firmware update in the organisation model**, and can a member-held node be updated or
   downgraded by its carrier?
10. **Which proofs are fresh?** For every place a node key signature is accepted: does it include a verifier
    nonce and the session binding, and would a signature made last year by a repair shop pass?
11. **What crosses provd in plaintext** in each new flow (enrolment tokens, new trust anchors, recovery shares)?
12. **How does a brand-new or replaced admin phone catch up a node that is 200 versions behind?**
13. **What is the audit record, where does it live, and who can alter it?** Node logs are on the plaintext card;
    phone clocks are settable. [v2.2] Node side: T-ND10, T-ND11 and R119–R125 state what must be true; where the
    record lives and its size are #423 (v2.0) design. Issuing-station side: still R21, R98.
14. **Mutual aid:** how does a guest node leave, and what did the guest organisation learn that must be rotated?
15. **How does the organisation's identity appear to a human** such that two organisations with the same name
    are distinguishable at enrolment?
16. **Can the issuing station be revoked by the root in a way a field node learns without the station?**
17. **What happens to credentials issued by a station whose backup is restored** (serial reuse, revocation loss)?
18. **Agency baseline "periodic key change":** which keys does it apply to here, and how is the period enforced
    without a node clock? What about keys locked in a chip?
19. **"No shared accounts":** does any role rely on a secret known to more than one person (shared admin key,
    one FIDO2 token for several operators, a station-wide enrolment PIN)?
20. **MFA at high level:** which exact actions count as high-level in the field, where the only factors are the
    phone and the person?
21. **Does the same phone running TAK and this app share anything** (certificate store, VPN profile, AP
    credentials) that lets a TAK-side compromise reach admin keys or the reverse?
22. **What does the member see when their node was revoked or the network forked?** A silent failure invites
    workarounds (sharing passwords by voice).
23. **Upgrade/revert:** which SE-side effects can a trial image cause before it is committed?
24. **What is the smallest set of things an attacker needs to enrol a never-claimed node** fresh from the box,
    and is the answer different for a returned / refurbished unit?
25. **Is there any vendor-side capability** (support unlock, re-provisioning tool, manufacturer CA) that works on
    a customer's enrolled node? If yes it is a master key and belongs in §1.
26. **Can a brand-new node be enrolled at the scene with the issuing station unreachable**, and if so who holds
    that right and where is the inventory's second writer? [review v1-B M12]
27. **Phone key attestation is produced at key generation over a verifier's challenge**: is the enrolled key a new
    key, how does the (multi-kilobyte) evidence travel, and what does an offline station do about attestation
    revocation? [review v1-A m2; review v1-B m2]
28. **What does a node accept while it is enrolled but has not yet received its own organisation credential**, and
    from whom? [review v2-B M6; review v2-A B1]
29. **What does the node do when its SE does not answer** — refuse to start, or run its existing network and refuse
    new authority? Two documents say different things (S29, T-SE14).
30. **Between the first release that has the new authority model and the last that still has the old flows, which
    model governs a given node?** Never both (two writers on one record). [review v1-B B3]
31. **Who may make a stored-but-inactive network the active one**, and can anything delivered without a session do
    it? [review v1-B B1; review v1-A M10]
32. **What are the contract bounds** — members per network, revocations per issuer, stored networks per node — and
    what happens at each bound, given the 64 KiB record (S31) and one-message limits? [review v1-B m1; review v2-B M10]
33. **State ON: who holds the boot-chain signing key (A12), how does it relate to the release root (A2), and what
    happens to an ON node at resale or when the organisation dissolves?** [merge: secure-boot premise]
34. **What does a credential with a validity period mean on a phone whose clock is wrong**, and can it ever lock out
    the legitimate holder while not affecting a thief? [review v1-B m3]

### 8.2 To decide before the secure element's configuration zone is locked

All chip behaviours here are [A]; each line needs a datasheet reference and a test on a sacrificial chip.
Items 1–14 are the base's; 15–19 were added in the merge. Appendix A indexes every item against the requirements
it serves, for the separate chip-configuration design.

1. **Slot map and count of keys.** One identity key cannot be both an arbitrary-message signer and a trustworthy
   attester (T-SE1/2). Decide whether there is (a) an attestation key that can sign only chip-internal
   content (public keys of slots in this chip, chip state) and (b) a separate operational signing key, itself
   attested by (a). If the protocol's `label ‖ value` signatures cannot be produced by an internal-only signature,
   the wire format has to change — decide this *before* lock, not after.
2. **External-sign permission per key slot.** For each private key: may it sign a digest supplied by the host?
3. **ECDH slot policy.** Enabled or not; shared secret in clear to the host or encrypted / kept in the chip;
   whether the ECDH key can be regenerated (gives rotation and resale privacy, costs a destruction primitive).
4. **Private keys generated in-chip only.** No slot holding a private key may be writable from outside, and
   this must be checkable afterwards by reading the configuration zone of any unit (T-SE10).
5. **Claim / enrolment secret slot.** Which commands may use it: comparison only, or also MAC / digest /
   derivation outputs (T-SE4)? Is it rewritable after lock, by whom, authorised by which key — and is that
   authorising key a fleet-wide secret (then it is asset A4)? Or is the design free of any long-lived printed
   secret?
6. **Is any per-slot lock deferred?** Slots can be left individually lockable later [A]; decide which decisions
   can be postponed that way and who is allowed to perform the later lock (anyone with root can, T-SE6).
7. **Monotonic counter(s).** What each counts, its ceiling against the worst-case rate, whether a key's use is
   tied to it, and the node's behaviour when the counter is ahead of / behind the record (T-SE6, L8).
8. **Storage for a trust anchor.** Does the organisation root (or its hash), or the "enrolled / not enrolled"
   state, live in the chip so that a card edit alone cannot change it? Slot sizes (one large slot, several
   72-byte slots [A]) constrain what fits; who may rewrite it and with what authorisation?
9. **Device certificate storage and the manufacturer CA model** (compressed certificate in the chip vs on the
   card; one CA or per-batch intermediates so a batch can be distrusted).
10. **IO-protection key / encrypted reads**: used or not, and where the host half lives (useless on the card in
    state OFF; meaningful only in state ON, §3.3).
11. **I2C address, watchdog / timing mode, bus sharing** with the RTC and power monitor: a peripheral or a
    mis-wired HAT that can hold the bus is a denial of every signature.
12. **Key validity / revocation features of the chip** (disable a key permanently): wanted for decommissioning
    (L11), dangerous as a field brick.
13. **Dev vs production separation at chip level**: a visibly different root / prefix for development chips so
    a dev-configured chip can never pass as production (the software equivalent exists today as the `dev:`
    certificate rule **[D 219-protocol.md §9]**).
14. **Batch procedure**: lock one, run the full negative test list (§9 tests marked SE) against it, only then
    lock the rest; record the configuration zone dump of every unit.
15. **Every slot, used or "reserved", needs its access policy chosen now.** [review v2-B B1(b)] Whether a slot is
    secret or host-readable, how it may be written after the data zone is locked, which commands may use it and
    whether it can be locked individually are configuration-zone bits [A]. A slot "reserved for later" with no
    policy cannot later become what the later use needs. Reserve by policy class, not by number.
16. **The second monotonic counter.** [review v2-B B1(c)] The chip has two [A]. Say what the unused one is left
    as (not attached to any key-use limit), so a later use — for example a freshness anchor for the card (T-SE7) —
    is still possible.
17. **Any host-usable value derived from the printed secret.** [review v2-A M4; review v2-B B1(a)] A slot that only
    answers a comparison cannot give the host a key derived from the secret. If any flow needs such a value
    (T-SE16), decide before the lock whether it exists at all, and if it does, where it lives and who can read it;
    do not discover the contradiction in #423 (v2.0) / v2.5.
18. **What commits the label to the chip's identity key, and where the identity certificate lives.** [review v2-B M1,
    B1(c)] How the device identifier is derived for the chip backend; whether what is printed commits to the
    identity public key (T-SE13); where the certificate or public-key commitment is stored so that it survives a
    card reflash (the chip's signatures are randomised, so a regenerated certificate has different bytes [A]).
19. **Is use of the chip's keys tied to a secret only the node's verified software holds?** [merge: secure-boot
    premise] In state ON this is the difference between "the SE can be driven from any host wired to the HAT" and
    not (§3.2 item 1). In state OFF it buys nothing (the secret is on the card). The slot and option bits it needs
    are fixed at lock time [A], so the decision is needed now even if state ON ships later.

Note on item 11 [review v2-B B1(c)]: the clock / watchdog mode and the I2C address are configuration-zone bytes; a
"to be measured" mark on them has to be closed **before** the lock, not in the first step after it.

---

## 9. Requirements checklist with negative tests

A reviewer ticks each item only with the named test's output attached. "NT" = negative test (must fail without
the control). Tests marked **SE** must be run on a real locked chip, not a software stand-in.

R1–R80 are the base's, unchanged. R81–R117 were added in the merge; each carries its source in brackets. R118–R125
were added in v2.2. For the rows listed in §11 the property wording given there is the requirement. Total: 125.
None has been tested.

| # | Requirement | Negative test |
|---|---|---|
| R1 | Every acceptance of a node-key signature that leads to trust (identity, secret release, membership) includes a verifier-chosen nonce and the session binding; long-lived node-signed statements grant nothing by themselves | NT: replay a `node_cert`-style statement recorded earlier from a chip that has since been removed from the bus; the phone must refuse to release a bundle |
| R2 | A statement obtained from the chip during brief custody cannot be used after custody ends to impersonate the node | NT **SE**: with bus access, sign an attacker-chosen static key; return the node; the forged identity must be rejected by a phone and by the station |
| R3 | The binding "this decryption key belongs to this device" can only be produced for a key that resides in the device's chip | NT **SE**: ask the chip to endorse an externally generated public key by every command path available; all must fail, or the resulting statement must be rejected by the verifier |
| R4 | Compromise of one node reveals only secrets addressed to that node, and nothing issued after it is reported lost | NT: mark node N lost, rekey, try to decrypt the new bundle set with N's chip; and assert no bundle for N exists in any courier's store |
| R5 | A proof of knowledge of a printed / enrolment secret cannot be produced by someone who can drive the chip but has not seen the secret | NT **SE**: without the QR, try every chip command on that slot to obtain a value the verifier accepts |
| R6 | No authority over an enrolled node derives from a secret printed on the node alone | NT: with only the QR photo (no button, no credential), attempt every flow against an enrolled node; all refused and logged |
| R7 | Enrolling or re-enrolling a node requires fresh proof of current physical custody **and** of authority; neither alone is enough | NT: (a) valid org credential, node not in hand; (b) node in hand + QR, no org credential — both must fail to enrol into O |
| R8 | A physical reset never preserves or exposes the previous network's secrets or authority, and the build's stated policy (free vs organisation-locked after reset) is enforced as stated | NT: reset by button/marker, then read back network settings and try the previous admin's credential |
| R9 | Exhausting or advancing any monotonic value on one node affects that node only and is repairable by the organisation without the vendor | NT **SE**: as root, increment the counter far ahead; the organisation must be able to bring the node back; other nodes unaffected |
| R10 | No protocol-reachable action (BLE/HTTP, any role below the node's top authority) destroys or regenerates a chip key or steps a counter | NT: fuzz all verbs as member and as admin; counter and public keys unchanged |
| R11 | A node whose record was rolled back is detectable by phones and by the station before it is trusted with anything new | NT: restore a card image two versions old; the next admin session must flag it and refuse to treat it as current |
| R12 | Nothing stored on any single node (card + chip) grants authority over another node or over the network's admin set | NT: dump one node completely; using only that material, try to change another node — must fail (L2 access via the password is expected and documented) |
| R13 | Node-signed reports (status, "applied") are treated as claims by possibly hostile software; no security decision depends on them alone | Review item + NT: a node running modified firmware reports "rekeyed"; the admin UI must not show the network as safe on that basis alone |
| R14 | Private keys are generated inside the chip; the configuration that guarantees it is readable and recorded per unit | NT **SE**: attempt to write a private key to each key slot after lock; verify config dump matches the golden one |
| R15 | The configuration is validated on sacrificial chips with the full SE test list before any production lock; the lock tool refuses a configuration that differs from the reviewed one | NT: feed the lock tool a one-bit-different config; it must refuse |
| R16 | The root can be replaced on a planned basis and after suspected compromise, with a defined procedure for nodes that were offline during the change | NT: roll the root with one node powered off; bring it back; it must converge without the old root being trusted again by others |
| R17 | Recovery material is at least as hard to use silently as the root: its use is visible to every remaining authority holder and to members | NT: use the recovery path; every other admin phone must show it at next contact; absence of the notice = fail |
| R18 | Loss of the root **and** its recovery material has a documented, tested outcome (what still works, what is lost) | Exercise: destroy both in a test organisation; record what is still possible |
| R19 | Issuing an administrator-level credential requires a per-issuance human gesture on a hardware factor; no process on the station host can issue one by itself | NT: with a live unlocked station and operator session, script the issuance API without touching the token — must fail |
| R20 | No secret bundle is created for a node that has been reported lost or removed, on any admin's phone, including phones that were offline when the report was made — or the design states the window | NT: admin B offline during the report by admin A; B rekeys; assert whether N receives a bundle; outcome must match the documented rule |
| R21 | Everything the issuing station issues is recorded in a log the station's own software cannot rewrite, and field devices carry enough of it to detect a mis-issue later | NT: issue, then delete the record on the station; the next sync from a field phone must expose the gap |
| R22 | The root can revoke an issuing station, and a field node can learn this from an admin phone with no station contact | NT: revoke station S at the root; present an S-issued admin credential to a node that has been told; refused |
| R23 | Revocation state is monotonic across station restore and across node card restore | NT: revoke phone P, restore the station from yesterday's backup, present P — still refused, or the station refuses to operate until re-synchronised |
| R24 | Credentials of one purpose (TAK client, station login, mesh admin, mesh member, node identity, firmware release) are not accepted for another | NT: present each credential type to each other verifier; all cross pairs refused |
| R25 | Phone enrolment binds: a hardware-backed key, the genuine app, a named person, a role; one person's credential cannot exist on two phones | NT: enrol with a software-backed key / repackaged app / second phone for the same person without revoking the first — refused or first one revoked |
| R26 | The station verifies what it can about the phone key offline and the document states what it cannot (attestation revocation) | Review item with the verified attestation fields listed |
| R27 | A human enrolling a phone or a node into an organisation sees an identity that a look-alike cannot reproduce, and first contact uses an out-of-band anchor | NT: create a second organisation with an identical display name; the enrolment UI must distinguish them without the user reading a hex string unaided |
| R28 | Every authority-bearing action is signed by a key held by exactly one person; no role is exercised with a shared secret | Review: enumerate keys per role; NT: remove one admin, confirm no other admin's key changed and old actions remain attributable |
| R29 | In the single-phone (family) build, loss or theft of the top phone can be recovered from **and** the stolen phone can be cut off, without that requiring the stolen phone | NT: take the top phone away while unlocked; from recovery material, re-establish authority and verify the old phone's signatures are refused by a node that was told |
| R30 | Every field operation needed during an incident (add / remove node, rekey, report loss) works with the issuing station unreachable for the stated number of days | NT: run the full flow list with the station powered off |
| R31 | The power a field credential needs for R30 is bounded: it cannot change the organisation, enrol new administrators, or outlive a stated limit without re-contact — and the document states how the limit is enforced on a clockless node | NT: field admin attempts to create another admin / change the root pin — refused |
| R32 | Use of an administrator key requires user authentication bound to the key (not just an unlocked screen) | NT: on an unlocked phone with the app open, trigger a signing operation without the second factor — refused by the keystore, not by UI code |
| R33 | Changing who the administrators are needs more than one administrator's single signature | NT: one admin key signs "remove all other admins"; nodes refuse |
| R34 | An administrator cannot plant a credential on a node that survives their own removal (SSH key, password, extra key) without it being listed and removed with them | NT: admin installs an SSH key, is removed; key must be gone or the removal must be shown as incomplete |
| R35 | When two valid-looking branches of a network exist, every node can be brought to the branch chosen by the higher authority, offline, without a physical reset; the choice cannot be won by speed or by brute force | NT: produce two v+1 from two admins; apply A to node 1, B to node 2; resolve with the higher authority; both converge. NT2: grind the tie-break value — must not help |
| R36 | A member phone holds the minimum: no other node's secrets, no roster beyond what its role needs | NT: dump a member app's storage after a rekey; list what is there against the stated minimum |
| R37 | Couriered objects are useless and uninformative to the courier | NT: inspect a courier's stored bundle: no plaintext names / roster / target identities beyond an opaque handle |
| R38 | Human comparison steps cannot be skipped by default and their strength does not depend on device certificates being unforgeable | NT: substitute the request object in transit with one carrying a valid but different node certificate; approval must not complete without a mismatch being shown |
| R39 | The document states that the app publisher and the release signer are trusted, and how a customer organisation can verify what it runs (reproducible hash, pinned version under MDM) | Review item |
| R40 | No long-lived secret is displayed to a person as part of a routine flow | NT: walk every flow; any screen showing a reusable secret is a finding |
| R41 | No security decision depends on the wall-clock of a phone or node unless that time is authenticated; ordering uses signed counters | NT: set the admin phone's clock one year back / forward and repeat revocation and renewal; results unchanged |
| R42 | A freshly enrolled admin phone can update a node that is arbitrarily far behind, with bounded data | NT: node at version 1, network at version 300, brand-new admin phone — converge |
| R43 | Secrets and trust anchors delivered to a node are sealed for the root helper / chip, not just for the session; secrets delivered to a phone are either sealed to a phone key or the exposure to provd is documented | NT: instrument provd (test build) to log session plaintext during each new flow; no reusable secret or anchor appears |
| R44 | Every state-changing request is authorised by a signature over the exact request, verified by the root helper against the node's pinned authority, for every authoriser kind the new design introduces | NT: compromised-provd simulation swaps verb / body / authoriser level after signing — refused by the helper |
| R45 | The phone-AP credential and the Ethernet port are treated as entries to the mesh: per node, generated or strength-checked, rotated on removal of the person who knew them, and the member's power over them is limited to their own node | NT: ex-member connects to the AP of the node they used to carry after removal — refused; member sets a 8-character dictionary password — refused |
| R46 | A device on the phone-AP LAN gains nothing in the management plane beyond what a BLE stranger has | NT: from an AP client without credentials, attempt every 8095 request and bridge-local service |
| R47 | An unauthenticated party in radio range cannot block an authenticated administrator's session for longer than a stated bound | NT: hold maximum unauthenticated sessions / handshake rate; admin revocation still completes within the bound |
| R48 | A member's credential works only on the node(s) assigned to that member and only for the listed verbs; it is not a network-wide secret | NT: member A queries node B; member tries each admin verb |
| R49 | Removing a person or node is defined as complete only when every credential class in §8.1-4 has been rotated or proven absent on every node; the UI shows incomplete removal per node | NT: remove a member with one node powered off; the network must be shown as "removal incomplete" until that node is handled |
| R50 | The mechanism that lets a stale node catch up after a rekey cannot be used by the removed party to learn the new password, to push configuration to the stale node, or to keep it on the old password indefinitely without that being visible | NT: removed party with the old password and old member secrets meets the stale node first; then the legitimate admin arrives — node converges to the legitimate state and the interference is reported |
| R51 | An older bundle or membership object cannot be applied after a newer one, including across a card restore on the courier's phone | NT: replay bundle v to a node at v+1 — refused |
| R52 | Temporary membership (mutual aid) has a defined end that restores both organisations to a state where the guest holds nothing usable, and the guest never held admin rights by default | NT: guest joins, leaves; guest's retained material fails against the host network after the stated close-out step |
| R53 | A party without current credentials cannot link two observations of the same node, or a node to its organisation, from the management plane's own emissions; residual radio-layer identifiers are listed | NT: record BLE management advertisements / handshakes of two nodes over a day; a classifier without keys cannot pair them above chance. List of non-management identifiers attached |
| R54 | Credentials presented before the peer is authenticated carry no organisation, station or person names; a removed member loses the ability to recognise the organisation's nodes within a stated bound | NT: capture a handshake as a stranger — no names; ex-member's recognition fails after the stated rotation |
| R55 | After enrolment the node's pinned organisation cannot be changed by any party below that organisation's root except through the documented physical reset, and third parties can detect a card-level change | NT: field admin / member / stranger attempts to re-pin; card edit of the pin is detected by the next admin session |
| R56 | Node selection in the UI is by verified identity; names are labels that an attacker cannot make collide unnoticed | NT: two nodes with the same display name in range — UI distinguishes and shows which is enrolled |
| R57 | Adding a node to a network requires authority over that node as well as over the network | NT: admin of network X adds an enrolled node of the same organisation that is assigned elsewhere / of another organisation — refused |
| R58 | "Add" and "remove" objects are not replayable out of order | NT: replay the original "add N" after "remove N" |
| R59 | No credential held by a previous owner, seller, repairer or removed admin works after the hand-over / removal procedure has completed on that node | NT: before hand-over collect everything a seller could keep (keys, passwords, card image, statements signed by the chip); after buyer enrolment each must fail |
| R60 | A rekey has a defined, visible state per node (pending / applied / unreachable) derived from fresh proofs, and a node that fails mid-apply returns to its previous working state | NT: power-cut a node during apply; it comes back on the old or new password consistently, and the admin view matches reality |
| R61 | The administrator is told before a rekey which nodes will be cut off | NT: rekey with one node offline — UI lists it before confirmation |
| R62 | Reporting a node or phone lost requires authority proportionate to the damage a false report does, works offline, and propagates through any member's phone | NT: member tries to report an admin phone lost — handled per the stated rule; report made on a partitioned sub-network reaches the rest when any phone crosses |
| R63 | A person whose only phone is gone has a way to authenticate the loss report that the thief does not have | NT: thief with the unlocked phone tries to pre-empt by reporting the *owner's* other credentials lost |
| R64 | Replacing a phone revokes the old one in the same step; a replacement cannot raise the role | NT: complete a replacement; old phone's signatures refused by a node that was told; role unchanged |
| R65 | No vendor-held secret or tool can take authority over a customer's enrolled node; if one exists it is listed as an asset with its custody rules | Review + NT: run the vendor re-provisioning tool against an enrolled node without the customer's authority |
| R66 | Factory reset / decommissioning removes every secret from the card that the software can remove, changes or disables whatever in the chip would let the previous holder be recognised or re-enter, and the manual states the remanence limit | NT: after reset, forensic read of the card for the old password, roster, keys; previous holder's recognition and credentials fail |
| R67 | The buyer of a used node can verify it is in the factory state without trusting the seller | NT: seller leaves an extra authority / SSH key; the buyer's first enrolment detects it or erases it |
| R68 | The member verb list is closed and reviewed: status of own node, phone Wi-Fi of own node; nothing that reveals the mesh password, changes mesh membership, installs code or opens a shell | NT: enumerate verbs with a member credential |
| R69 | Factory secrets (claim table, label images, CA key) have a stated custody and destruction rule; the production line is tested for label/unit mismatch | NT: scan label, compare against the unit's live proof, for 100 % of a batch; search build artefacts for secrets |
| R70 | Migration of an already-claimed node to organisation authority is authorised by the organisation and by fresh physical custody, not by the old owner key alone | NT: old owner key (or a card image) alone tries to bind the node to organisation X |
| R71 | After migration no old-model authority (owner key, claim-by-QR, SSH key from the old owner) remains valid on the node, including after downgrade to an older signed image | NT: migrate, then boot the previous image from the other slot / a reflashed card; old owner phone must not regain control, or the node must be visibly out of the organisation to every other party |
| R72 | Renewal cannot be obtained by the holder of a stolen credential more easily than by its owner | NT: stolen phone attempts the renewal path |
| R73 | A courier cannot suppress a revocation without the next honest contact revealing it | NT: courier drops the revocation for node N; the next admin session with N delivers it and reports the gap |
| R74 | Each key class has a stated rotation trigger, period, owner and reach (including "cannot be rotated — locked in chip"), and the customer-facing statement for the agency baseline matches | Review table; NT: rotate each rotatable class in a test organisation with one node offline |
| R75 | An image that cannot interpret the node's authority state fails closed (not manageable, not claimable) and says so | NT: boot an older image against a new-format record — no claim window, no legacy owner access |
| R76 | Any change that touches the chip is ordered so that a power cut or an automatic image revert leaves record and chip consistent, or leaves a state the committed image repairs | NT: kill-point tests at each step of each chip-touching flow, then boot both slots |
| R77 | A downgrade through the update path requires the same authority as an upgrade and cannot go below the first organisation-aware version | NT: admin pushes a pre-#255 signed image — refused |
| R78 | Dissolving an organisation or retiring a station has a procedure that leaves no usable issuing key and a defined fate for its nodes | Exercise in a test organisation |
| R79 | Development trust (self-signed `dev:` identities, test release root, bench builds) cannot be present in a customer build of the app or the image | NT: customer build meets a dev node and a test-root-signed update — both refused; build pipeline check that fails when the test root is in the image |
| R80 | Security events (failed authorisations, recovery use, fork detected, rollback detected, incomplete removal) are surfaced to an administrator and exportable to the station; absence of data is shown as unknown, never as OK | NT: suppress one node's status; the summary must not show green |
| R81 | Delegated authority cannot be re-delegated: a credential issued to a person or to a node can never make another credential valid, an intermediate can issue only what the top authority explicitly gave it and never its own kind, and nothing signed by a node's key confers authority on anyone [author v1 R2; review v1-A B2; review v1-B M4] | NT: a person credential, a node credential (signed with the node's chip), and an intermediate each sign a credential for a third key; an intermediate issues another intermediate — every resulting credential is refused by a node |
| R82 | Any right that amounts to root on a node (shell access, root password, settings that lead to code execution) is granted only by that node's top authority, names the nodes it applies to, and is listed as root-equivalent in the role description [author v1 R3; review v1-A M6] | NT: an intermediate issues such a right; a holder uses it on a node it does not name — both refused. Review: every settable key checked for a path to code execution |
| R83 | Every signed authority object is bound, inside the signature, to its kind, its organisation, its network and target node where it has one, and its signer; it is refused in any other context [author v1 R4; review v1-A m1; review v2-A m8] | NT: present organisation A's credential to B's node; network X's state to a node for network Y; one object kind where another is expected; an object for node 1 to node 2 — all refused |
| R84 | An organisation credential for a node is issued only for a key freshly proven to be inside the chip of the unit in the enroller's custody; knowing the printed secret, or holding an enrol right at the station, is not enough to have a software key accepted as a node [author v1 R5; review v2-A m10; review v2-B M1] | NT **SE**: with a photographed label and a software key, answer an enrolment as that node — the enroller's phone refuses. NT: a station account with the enrol right requests a node credential for a key not in a chip — refused |
| R85 | A revoked credential is refused by a freshly enrolled node and by a factory-reset-and-re-enrolled node from its first action; a node that has no revocation data does not treat that as "nothing revoked" [author v1 R6; review v1-A M1] | NT: revoke P; factory-reset and re-enrol node N (and enrol a spare); present P to both before any other administrator visits — refused |
| R86 | The minimum revocation state a node insists on cannot be supplied by the party that state would revoke, cannot be lowered by replay, and cannot be raised by anyone below the top authority to a value that shuts out legitimate credentials; recovery from a bad value needs no physical reset [review v2-A B1] | NT: a revoked issuer delivers its own low minimum to a fresh node — its credentials stay refused. NT: an issuer sets the maximum minimum on a node; the top authority restores management without touching the node physically |
| R87 | Revocation state has a stated size bound derived from the stated organisation size; the behaviour at the bound is defined and fail-closed, and reaching it in ordinary operation does not mean re-issuing every credential or visiting every node [author v1 R7; review v1-A M1; review v2-B M10] | NT: fill revocation state to the bound, then revoke one more; the result matches the documented rule and no previously revoked credential becomes valid. Review: sizing against expected phone turnover |
| R88 | Every action is authorised against the node's current state at the moment of the action; no earlier "verified" result is reused across actions, sessions or daemon restarts [author v1 R8] | NT: open a session with credential P; deliver P's revocation through another session; P's next action in the still-open session is refused without restarting anything |
| R89 | What revocation does to state that is already applied and to objects still in transit is defined: a working network is not taken down because the person who built it was revoked; the administrators are shown every network whose last signer is revoked and told it must be rekeyed; nothing new signed by the revoked credential is accepted [review v1-B M2] | NT: revoke the administrator who built network X during operation — nodes stay on X (also after reboot); the admin view flags X; a late node offered X's last state by a courier behaves as documented |
| R90 | A replayable object (valid by signature alone) can only *update* something the node currently holds. It can never make a node enter a network, accept an authority, become active on a network or change its regulatory domain; objects from before a leave, a wipe, a reset, a re-enrolment or an eviction are refused afterwards [author v1 R9; review v1-A B3, M3; review v1-B B1; review v2-B m6] | NT: record every signed object a node sees; make it leave / wipe it / reset and re-enrol it; replay each recorded object over every delivery path — nothing is applied. NT: replay a "wipe" after the node was re-added — refused |
| R91 | Each network on a node is bound to the authority it was created or joined under; a second authority admitted to a node for one network (a club, a mutual-aid host, a team joined by human-compared code) cannot act on any other network, on the node's settings, or issue anything valid on it; the node's own top authority can always make it leave any network [author v1 R11; review v1-A M3, M4; review v2-A M7] | NT: the secondary authority updates the node's home network, sends "wipe all", issues a node-scoped right — all refused; the top authority removes the secondary's network — accepted |
| R92 | No holder of a credential below the top authority can put a network's or a node's version state into a condition from which the higher authority cannot recover it offline and without a physical reset; a node that missed any number of changes is not stranded by an ordering rule; devices do not automatically forward a state they would not themselves have signed or chosen [author v1 R12, corrected; review v1-A M2; review v1-B M1; review v2-A M3; review v2-B M5(b)] | NT: with an administrator key sign the highest representable version (and a ground tie-break), inject it into one node, let ordinary phones sync — the organisation restores every node by the documented procedure, and the object did not spread unprompted. NT: node asleep through 1000 changes converges |
| R93 | When two administrators change the same network from the same starting state, the outcome never re-admits a node or person that either of them removed, and the administrator whose edit did not prevail is told at next contact [review v1-B m6; review v2-B M5(a)] | NT: A removes lost node X, B (partitioned) removes Y from the same version; merge — X is not a member under any outcome, and the losing phone shows it |
| R94 | No symmetric secret is shared by the whole organisation, and no identifier or recognition secret of a node is both long-lived and impossible to rotate for a party that once legitimately saw it (former member, former administrator, anyone who saw the body label); any exception is listed in §10 with who can track what for how long [author v1 R14; review v1-A M5; review v2-A M4, M5] | NT: with everything a former administrator and a label photographer hold, try to recognise or confirm node N after N's secrets were rotated — fails. NT: material from node 1 recognises node 2 — fails |
| R95 | Rotating a recognition or handshake secret never leaves a legitimate authority unable to find and open a session with a node (or a phone unable to reach nodes) that missed one or more rotations, other than by physical reset [review v1-B M5] | NT: rotate three times with node N switched off and with phone Q unsynchronised; N is still found and managed; Q regains access by the documented step |
| R96 | Recovery material can do one thing — replace the top authority. It cannot be used for everyday operations; it cannot be removed or replaced by the top authority's key alone; after it has been used it is itself replaced and every secret the lost device knew is scheduled for rotation. The document states plainly that a copy of the material is permanent ability to take the organisation (§10-12) [author v1 R16, residual corrected; review v1-A M9, m10; review v1-B M6; review v2-A m9; review v2-B m2] | NT: use the recovery key for an administrator action — refused. NT: with only the top key, remove the recovery path — refused. NT: after a recovery, the old recovery material no longer works |
| R97 | For an organisation with an issuing station, the top-authority key is not usable on, stored on, or derivable from anything on the daily issuing host or its backups; it shares no parent secret with any other key (station issuing key, TAK CA); full compromise of the daily host does not yield it [author v1 R10; review v1-A M7] | NT / exercise: give a red team the running issuing host, its memory and its backups; they must fail to sign as the root. Review: key derivation tree |
| R98 | What the top authority signs in a ceremony is checked by its custodians against a record the daily host cannot alter, and every signature it makes is entered in a log the custodians keep; an attacker present on the daily host before a ceremony cannot get a key certified unnoticed [review v2-A m11] | NT: tamper with the prepared inputs on the daily host (swap the issuer public key) before a rehearsal ceremony — the custodians' check catches it |
| R99 | Until a new image has been committed, nothing it does makes the previous image unable to manage the node: after an automatic revert the node is still enrolled, still in its network, and still manageable by the same authorities [author v1 R18; review v1-A M8; review v1-B M7; review v2-A m6; review v2-B M7] | NT: update, exercise every authority-touching flow that the trial image allows, force the trial to fail; on the reverted slot log in, read status, apply a change. Also by the manual-commit path |
| R100 | When authority data is missing, stale, unreadable or of an unknown kind or version, the node refuses; every case where it proceeds instead is listed with its reason [author v1 R20] | NT: delete / corrupt / version-bump each authority item in turn and attempt each action class; results equal the published table, with no unlisted acceptance |
| R101 | The node's behaviour when its SE is absent, silent, transiently failing, blank, or not the chip its record was made with is decided, stated and tested. In no case does it create or fall back to a software identity, accept new authority, or present another unit's enrolment as its own; what keeps working (the existing network or nothing) is stated to the user [author v1 R21; review v2-B M8; review v2-A m12; review v1-A m7] | NT **SE**: remove the chip after boot; hold the bus at boot; swap the HAT; move the card to another unit; fit a blank chip — each ends in the documented state, with no new identity file and no accepted change |
| R102 | Only the node's root authority component can cause the SE to do anything; a local non-root process and a container cannot open, address, or starve the bus the SE is on, and no other user of that bus can be made to do it for them [review v2-A m1; `docs/design/REVIEW.md` item 5] | NT **SE**: as a non-root uid and from inside each container the image ships, attempt to open the bus device and to run one chip command; attempt to hold the bus — all fail; the counter and a test signature are unchanged |
| R103 | Any management input reachable from the mesh, the access-point LAN or the Ethernet port has stated size and rate limits applied before any expensive check, and being on that layer-2 segment gives nothing in the management plane beyond what an unauthenticated stranger in radio range has [review v1-A m8; review v1-B M8] | NT: from a bridged host, flood maximum-size invalid objects at the listener; CPU and memory stay within the stated bound and an administrator's session completes (R47's bound) |
| R104 | The reach of one administrator credential, and of one administrator phone's stored data, is bounded and stated as numbers (nodes that can be changed with and without being near them; nodes that become recognisable); every scope a credential claims is enforced by the nodes themselves, not by an honest app [review v1-B M3; review v1-A B2; review v2-A m13; review v2-B m5] | NT: with a station-1 administrator credential act on a station-2 node — refused by the node (app bypassed). NT: dump an administrator phone; the nodes it can recognise equal the stated set |
| R105 | Changing a network's secret excludes a revoked or removed party even where the revocation itself has not yet arrived: no node, phone or station gives the current secret to a requester merely because a credential still verifies locally [review v2-A M2] | NT: revoke administrator B; rekey; deliver the new state but not the revocation to node N; B asks N (every verb) for the secret — B does not obtain it |
| R106 | A network secret reaches a person only encrypted to a key that the organisation has certified as that person's, with the choice of key covered by the authorisation; it never crosses the node's radio-facing process in readable form — the baseline (S26) is not lowered [review v2-A M1] | NT: on a test build log everything provd can read during every new flow, and let provd rewrite any unsigned request field — neither the mesh password nor `net_root` appears |
| R107 | Another administrator of the same organisation can take over an existing network — add, remove, rekey — with nothing from the first administrator's phone and with the issuing station unreachable [review v1-B B2] | NT: destroy the phone that built the network; station off; a second administrator who never synchronised with the first adds a node and then rekeys — every remaining node follows |
| R108 | An object that changes a network discloses the new roster and the new radio parameters only to parties that remain in the network; a view-level credential reads no more of the roster than its role needs [review v1-A m5; review v2-B m5] | NT: as the node being removed, and as a view-level phone, capture the change object — no new member list, no new parameters |
| R109 | Which operations need the user to prove presence is stated per operation, is enforced outside app code, and lets one deliberate act cover one operation across all the nodes it concerns; reading status needs none. Events that invalidate an authority key (new biometric, lock screen removed, app reinstalled) have a stated outcome that is never the silent loss of the top authority [review v2-B M4] | NT: rekey 30 nodes — count the prompts against the stated number. NT: enrol a new fingerprint on the top phone; the outcome equals the documented one and the organisation is still manageable |
| R110 | Enrolment and factory reset are all-or-nothing as seen by the next boot: after a power cut at any point the node is either as before or fully in the new state, never enrolled-but-unmanageable, never "unenrolled but refusing enrolment", and never in a state only an offline top authority can leave. All parts of the node's authority state change together [review v1-B M6; review v2-B M6; review v2-A m3, m4] | NT **SE**: kill-point at every step of enrolment and of reset, on a unit with no button; then complete the flow with only what the enroller had before the cut |
| R111 | A member can see the status of, and connect a phone to, whichever node they were handed, with the issuing station unreachable since before the hand-over — including a different node from last time; what a member cannot do in that situation is stated [review v1-B M9; review v2-B M3] | NT: station off for a week; hand a member a node they never held; count the steps until status and the node's Wi-Fi work |
| R112 | Delivering a changed network secret never, by itself, leaves a node cut off from a working mesh while its neighbours have moved on, unless the administrator was told so beforehand (R61); and reaching N nodes takes no longer, and no more walking, than the hand-over it replaces — with the numbers stated for 8 and 30 nodes [review v1-B M8; review v2-B M2] | NT: 8 nodes in a 3-hop line, rekey from one end — every node ends on the new secret or is listed in advance. Timed run against the v1.6 baseline |
| R113 | A validity period or any clock comparison never locks a legitimate administrator out during an incident while leaving a thief unaffected: where time is not authenticated it warns and does not block [review v1-B m3] | NT: set the administrator phone a year ahead and take the station offline; every incident flow still completes, with a warning |
| R114 | Replacing the top authority — planned or through recovery — leaves every existing network updatable by the new authority and by nobody acting for the old one, keeps the organisation's identity as nodes see it, and keeps networks rekeyable while the replacement is only partly rolled out [review v2-A M6; review v2-B B2; review v1-A M9] | NT: replace the top authority on half the nodes of a network; rekey — all nodes follow. Complete the replacement; the old top key's update is refused, the new one's accepted, no node was reset |
| R115 | The authority to start installation of an already release-signed image is separate from root-equivalent rights (R82): it gives nothing beyond what the release signer authorised, exercising it needs neither a top-authority ceremony per round nor a standing root-equivalent credential on a field device, and it follows R77 [review v2-A M8; review v2-B M9] | NT: with the update right only, attempt shell / root-password / settings verbs — refused. Exercise: update 30 nodes and one newly enrolled node without the offline root |
| R116 | Every request type the node understands is assigned to exactly one authority class in a reviewed table, and one that is not in the table is refused; an export of diagnostics is classed by the most sensitive thing it can contain [review v2-A m7; review v2-B m3] | NT: enumerate every request type with each credential class and compare with the table; add an unlisted type on a test build — refused |
| R117 | Whatever channel carries rosters, revocations or recognition secrets between the issuing station and a phone is confidential and authenticated to the individual account, and releases each recognition secret only to those the role gives it to [review v2-A m14] | NT: observe and replay a synchronisation as another enrolled account; a member account requests another node's recognition secret — refused |
| R118 | No interface that gives a shell, changes configuration or reads management state is reachable on a node by a party that does not currently hold authority over that node; making such an interface reachable is a request type in the R116 table, and that reach ends without further action. A development build may keep a shell reachable without that request; this exemption is development trust under R79 and is the only difference between the builds [v2.2: T-ND9; user decision 2026-11-23] | NT: as a party without authority over node N — a client of N's AP, a host on N's Ethernet port, a client of another node's AP, a host on the mesh — scan N over IPv4 and IPv6: no shell, configuration or management-state interface answers. Holding authority, make one reachable through its R116 request; it works; take no further action — after the stated bound, and after a reboot, it is unreachable again. On a customer build, no setting, file or card edit turns the development exemption on |
| R119 | Every management event on a node produces at least one attributable record that names the credential (not the person): applied changes of every R116 class, attempts refused for lack of authority, maintenance opened and closed, shell and web-administration logins, secure-element events (provisioned, frozen for a swapped HAT or a mismatched backend, no answer at boot, claim or replay refused), boot reason, update and revert. Each record carries the node's time and, where the request is signed, the time the request states; records are ordered independently of any clock, and both times are informational — no decision uses them (R41, R113) [v2.2: T-ND10, T-ND11] | NT: trigger each event type once; at least one attributable record each, every field present. Set the node's clock a year back and forward between events — the order of records is unchanged |
| R120 | An unauthenticated party cannot cause records of applied changes to be lost [v2.2: T-ND11] | NT: send invalid requests over BLE and over 8095 until the allowance for refused attempts has been exceeded twice; every earlier record of an applied change is still there |
| R121 | A record contains no secret, password or location [v2.2: T-ND10; T-MS4] | NT: search all records for the test passwords, keys and coordinates used during the R119 test |
| R122 | Records survive reboot and power loss; when space runs out, what was dropped is itself recorded [v2.2: T-ND10] | NT: cut power right after the app reports a change applied with recording available — the record is there. Fill the store — the oldest surviving record and the "dropped up to" record agree |
| R123 | After an administrator has read a node's records, deleting or rolling back those records on the node is detected by that administrator without any network service, and does not destroy what was already read; a restart of the record raises no warning only when the node has also lost its enrolment and network state (factory reset, re-image) [v2.2: T-ND11] | NT on a bench node: delete one record; restore an older copy of the store; as root, declare a restart while keeping the network; factory reset — the first three warn on the administrator's next read, the last does not, and the earlier records are still readable on the phone |
| R124 | Failure to write a record never blocks a management action; the administrator is told that recording is unavailable [v2.2: T-ND10] | NT: make the record store full or unmounted; send a change — it is applied and the app shows recording unavailable |
| R125 | Reading a node's R119 records (not the operational syslog) is a request type in the R116 table at administrator class; no unauthenticated or member path reveals them [v2.2: T-ND10] | NT: request the records with no credential and with a member credential — refused; over the AP LAN without a session — nothing |

---

## 10. Residual risks that no design removes (state them to customers)

1. **State OFF: holding a node is owning that node** — its card secrets immediately, its chip for as long as
   it is held. The mesh password in use at the time of capture is lost.
2. **Shared mesh password**: removal of one party is a rekey of all, and is only as complete as the least
   reachable node. Until per-node link credentials exist, "removed" is a process with a duration.
3. **No clock**: nothing expires on a node by itself. Authority ends when the node is told, not when the paper
   says. [v2.2] Holds until v2.0 (#174); from v2.0 (#174) the node has an RTC, but a holder of the node can set it, so time is
   still not authenticated (R41, R113).
4. **A node that has not heard of a revocation obeys the revoked authority.** The design can make this
   recoverable; it cannot make it impossible.
5. **The top authority is a single point**: its holder (or the holder of its recovery material) can do anything;
   its loss without recovery orphans the hardware or frees it for anyone, depending on the reset policy.
6. **The issuing station can mis-issue while unlocked**; detection is after the fact.
7. **The app publisher, the release signer and the factory are trusted.**
8. **A coerced administrator** can do whatever an administrator can do; only the bound on field authority (R31)
   and after-the-fact attribution limit the damage.
9. **Radio-layer identifiers** (HaLow, Wi-Fi) let an observer track nodes regardless of the management plane.
10. **Anyone in radio range can delay management** of the nodes in that range.
11. **No FIPS 140 module validation is claimed for the ATECC608B.** [author v1 §6 item 7] [A — the author's v1
    says the chip is not found in the NIST CMVP list; the first design draft cited a CMVP certificate number that
    reviewer v1-A listed as unchecked. Neither was verified in this merge; check before any customer statement.]
    [v2.2] Superseded by the header (no 608B module certificate). Ends for the chip only when the production secure element (still open, see the header) replaces the 608B; the product
    itself still has no certification of its own.
12. **A copy of the recovery material is permanent, silent ability to take the organisation**, including replacing
    the recovery path itself; the legitimate owner cannot take it back with their own copy and is left with a
    physical reset of every node. R17 makes its *use* visible; nothing makes the *copy* visible.
13. **A holder of a network-level credential can damage that network's state** (T-MS6, T-PH11) up to forcing the
    organisation to rebuild that network on every node. R92 bounds this to "recoverable without a physical reset";
    it does not make it free.
14. **An older image does not know about anything decided after it was built**: revocations, removed authorities, a
    new authority model. Booted by physical downgrade it enforces only what it knew (R71 limits what that is worth
    to others; it does not make the old image enforce new rules). True in both platform states (§3.3, L9).
15. **State ON adds a trusted party and an irreversible step**: whoever holds the boot-chain signing key (A12) is
    trusted like the release signer, and a unit whose anchor was programmed wrongly, or whose signing key is lost,
    cannot be corrected.

16. **Root on a node can delete its records since an administrator last read them** [v2.2: T-ND11]. R123 makes
    the deletion visible and keeps what was read; nothing recovers what was not yet read.
17. **A record attributes an action to a credential, not to a person** [v2.2]. A stolen phone or a coerced
    administrator is recorded as its rightful holder (item 8, T-PH1).

How items 1–10 read per platform state: item 1 is the state-OFF statement; in state ON see §3.2 (possession alone
gives less, the three exceptions remain). Items 2–10 are the same in both states. Items 16–17 hold in both; in state
ON item 16 first needs root, that is, a software flaw.

---

## 11. Design-neutral requirements vs design choices

The requirements must say **what has to be true**, not how. A requirement that names a mechanism quietly approves
one design and hides the property a different design would have to meet. The base (written without seeing any
design) is mostly clean; the rows below are the ones in R1–R80 that prescribe a mechanism. For these, **the property
wording in this table is the requirement**; the §9 text is kept unchanged for traceability and its negative test
still applies. R81–R125 were written as properties from the start.

| # | Mechanism named in §9 | The property needed |
|---|---|---|
| R1 | "includes a verifier-chosen nonce and the session binding" | A node-key signature is accepted as proof only if it could not have been made before this verification started and could not have been made for a different conversation |
| R14 | "generated inside the chip" | No party — factory included — ever possessed a node's private keys, and this can be checked on any unit afterwards |
| R15 | "the lock tool refuses a configuration that differs" | No unit leaves with an irreversible chip configuration other than the reviewed and tested one |
| R19 | "a per-issuance human gesture on a hardware factor" | Nothing running on the issuing host, including under an operator's live session, can cause an administrator-level credential to be issued without a deliberate act by an authorised person that the host cannot simulate |
| R21 | "a log the station's own software cannot rewrite" | Whoever controls the station cannot hide or alter, after the fact, what it issued: field devices can detect a missing or changed issuance record |
| R25 | "a hardware-backed key, the genuine app" | A person's credential cannot be copied to a second device, and cannot be exercised by software other than the published app |
| R32 | "user authentication bound to the key … refused by the keystore" | Holding an unlocked phone is not enough to exercise administrator authority, and the check is not one the app's own code (or a modified app) can skip |
| R33 | "more than one administrator's single signature" | No single administrator-level credential can change who the administrators are |
| R41 | "ordering uses signed counters" | Order and freshness cannot be forged by setting a clock |
| R43 | "sealed for the root helper / chip" | A compromised radio-facing process cannot read a secret or trust anchor on its way to the node, nor (unless stated) one on its way to a phone |
| R44 | "a signature over the exact request, verified by the root helper against the node's pinned authority" | A compromised radio-facing process cannot create, alter, retarget or raise the authority level of a state-changing request |
| R45 | "per node, generated or strength-checked, rotated on removal" | Local-access credentials of one node give no access through another node, cannot be guessed offline at feasible cost, and stop working for a person once that person is removed |
| R60 | "derived from fresh proofs" | The per-node rekey state shown to an administrator reflects what the node is actually doing, not what possibly hostile software on it reports |
| R62 | "propagates through any member's phone" | A loss report spreads across partitions without an administrator having to reach each partition |
| R76 | "is ordered so that" | No power cut and no automatic revert leaves the record and the chip in a state the committed image cannot repair |

Design choices that are **not** requirements, and must stay out of §9: certificates versus signed lists; the shape
and depth of a chain; the names and number of roles; whether network state is a chain or a snapshot; how versions
are compared; whether objects travel by phone, by mesh or on paper; which chip slot holds what; one record or
several. Each of them is constrained by the requirements; none is required by them. Two places where the sources
slide from property to mechanism and where this document deliberately stops at the property: v1-R2 ("the chain is
anchor -> at most one issuer -> leaf") became R81; v1-R6 ("the floor travels with enrolment") became R85 / R86.

---

## Appendix A. Requirements that must be settled before the secure element's configuration zone is locked

This is §8.2 as an index for the separate chip-configuration design: each item with the requirements it serves and
the threats it answers. The lock is irreversible and there are few spare chips; an item left open here is a
requirement that can no longer be met by this hardware. All chip behaviour is [A].

| §8.2 item | Decision | Requirements served | Threats |
|---|---|---|---|
| 1 | Slot map; an attestation key separate from an operational signing key | R1, R2, R3, R84 | T-SE1, T-SE2, T-SE13 |
| 2 | External-sign permission per private key | R1, R2, R3, R81 | T-SE1, T-SE2 |
| 3 | ECDH slot policy: enabled, where the shared secret goes, regenerable or not | R4, R20, R66, R10 | T-SE3, T-SE6, F11 |
| 4 | Private keys generated in-chip only, checkable per unit | R14 | T-SE10 |
| 5 | Claim / enrolment secret: which commands may use it; rewritable or not, by whom | R5, R6, R7, R59, R66, R69, R94 | T-SE4, T-SE5, T-SE16 |
| 6 | Deferred per-slot locks: which, and who may perform them later | R10, R15 | T-SE6, T-SE11 |
| 7 | Monotonic counter(s): what each counts, ceiling, behaviour when ahead of / behind the record | R9, R10, R11, R76, R110 | T-SE6, T-SE7, L8, L15 |
| 8 | Storage for a trust anchor or the "enrolled" state in the chip | R11, R12, R55 | T-SE7, T-SE8 |
| 9 | Device certificate storage; manufacturer CA model (per-batch distrust) | R84, R69, R79 | T-SE13, L1, A4 |
| 10 | IO-protection key / encrypted reads, and where the host half lives | R102, R106 | T-SE9; differs by platform state (§3.3) |
| 11 | I2C address, clock / watchdog mode, bus sharing — closed before the lock | R101, R102 | T-SE14, T-SE15 |
| 12 | Key disable / revocation features of the chip | R66, R78, R10 | L11, T-SE6 |
| 13 | Development vs production separation at chip level | R79 | X12 |
| 14 | Batch procedure: lock one, run every **SE** test, then the rest; keep each unit's configuration dump | R15, R14 | T-SE11 |
| 15 | Access policy for every slot, including reserved ones | R15 | T-SE11 |
| 16 | Second counter left unattached | R9, R11 | T-SE7 |
| 17 | Whether any host-usable value derived from the printed secret exists | R5, R94 | T-SE4, T-SE16 |
| 18 | What commits the label to the chip's identity key; where the identity certificate lives; device-id derivation | R84 | T-SE13, L13 |
| 19 | Chip use tied to a secret only verified node software holds | R2, R4, R102 | T-SE1 … T-SE6 in state ON (§3.2) |

Requirements with a negative test marked **SE** (must be run on a real locked chip before the batch is locked):
R2, R3, R5, R9, R14, R84, R101, R102, R110.

---

## Appendix B. Open problems for the trust-model design (#423, v2.0)

These are **problems**, with the pitfalls two review rounds already found. No solution is proposed here; a
#423 (v2.0) design must show how it avoids each pitfall, or accept one explicitly in §10. "Estimate" marks a reviewer's
unmeasured number.

**B1. Keeping revocation state across factory reset and re-enrolment without a self-referential floor.**
(T-OR11; R23, R85, R86, R87)
- "No list = empty list" makes a revoked credential valid on every spare and every reset node [review v1-A M1].
- A minimum carried in an object signed by the issuer that the list would revoke lets that issuer supply its own
  minimum [review v2-A B1(a)].
- Minimums that only rise, settable by an issuer, can be set to the maximum: every node refuses everything until
  physically reset [review v2-A B1(b)]. Minimums that may fall are a rollback [B1(c)].
- If a node's own credential stops being valid when its issuer is revoked or a generation is raised, the defender's
  remedy freezes management of every node at the moment a rekey is needed [B1(d)]. A newly certified issuer has no
  minimum at all on existing nodes [B1(e)].
- Without a clock nothing is ever pruned; the state shares a 64 KiB record (S31); a "generation" escape re-issues
  every person and visits every node [review v2-B M10].
- In state OFF a card restore rolls back anything kept only on the card (T-SE7); on the file backend a counter kept
  beside the identity rolls back with it [review v2-A m12].
- Serial numbers from a counter do not survive a station restore or a recovered root [review v1-A M9].

**B2. Letting a second administrator obtain the current network secret and member list without exposing it to the
node's radio-facing daemon and without letting a revoked administrator read a new secret.** (T-PH9; R105–R107)
- Today the code refuses the situation rather than solving it (S30).
- "Every change by a different administrator is a rekey" turns each add or remove into a mesh-wide password change.
- "The node returns the secret to any administrator credential": the reply crosses provd (S21, S26); "wrapped to
  this connection" means wrapped to a key provd holds; a wrapping key taken from an unsigned request field is
  provd's to replace [review v2-A M1].
- The same request answers a revoked administrator wherever the revocation has not arrived, so a rekey no longer
  excludes anyone by itself [review v2-A M2]; and a stolen administrator phone can then read the secret of any
  network from any node it gets near.
- "Wrap the secret for administrators too" needs a closed administrator set, which the takeover requirement
  forbids [review v1-B B2].
- The next signer also needs every member's encryption key, and that key's binding to the node identity is exactly
  what T-SE2 attacks.

**B3. Recovering a family's nodes after the top-authority phone is lost, without a permanent non-rotatable secret
on the body.** (T-SE5, T-SE16, T-OR8, T-OR14; R6, R29, R94, R96)
- A new phone holds no recognition secret, so it can neither find nor open a session with an enrolled node; it also
  lacks the inventory, the network secrets and the nodes' root passwords [review v1-B M6].
- Deriving a handshake secret from the label contradicts a comparison-only chip slot; the alternatives are a chip
  that derives for any bus master, or a value on the card that a reflash loses [review v2-A M4; review v2-B B1(a)].
- A label-derived secret is a permanent recognition key for everyone who ever saw the label, and a yes/no oracle
  for "is this device X" [review v2-A M5]. What a session opened that way may do before login must be "nothing".
- The planned "label + button, network settings kept" path (S18) hands a finder the network configuration (T-SE5);
  the HATs on hand have no button **[D 219-field-provisioning.md:78]**.
- Recovery material on paper is a software key the moment it is scanned, and a photograph of it is forever
  (§10-12); a thief with the top phone must not be able to delete the recovery path first [review v1-A M9].
- After recovery the lost phone still knows the mesh password: recovery is not complete until a rekey is.

**B4. Delivering a changed mesh password to every node including switched-off ones, without splitting a multi-hop
mesh and without being slower than today's parallel hand-over.** (T-MS2, T-MS8, F6; R50, R51, R60, R61, R73, R112)
- Forward-then-switch with one password per mesh: the bridge to a far cluster switches first and the cluster is
  stranded; dual-password operation of the mesh was assumed and never probed [review v1-B M8] [A].
- No acknowledgement, no pending / commit step, no bound on "wait a little".
- A mesh-side listener is reachable by every bridged host and must rate-limit before verifying (T-ND6).
- Carried by phones: a member's phone can open a session only with its own node, so delivery is serial and
  administrator-bound — estimate 5–10 min for 8 nodes, 15–30 min for 30, mesh split throughout — against one
  button per person in parallel today [review v2-B M2].
- Whatever lets a stale node catch up is also spoken by the removed party (T-MS2, R50).
- A node off for months must need only the latest state, not the history (R42), and must not be stranded by a rule
  about version distance [review v1-A M2]; if it was removed meanwhile it must not be re-admitted by an old object
  (T-MS5).
- A courier can drop or replay (R51, R73); bundles must not exist for a node reported lost (R20).

**B5. Convergence when two administrators change the same network concurrently, including version exhaustion.**
(T-PH2, T-PH11, T-MS6; R35, R92, R93)
- Today: contiguous chain, first applied wins per node, no way back (S8); the written spec says "smaller hash
  wins", which an attacker can grind.
- A total order on (version, hash) converges on bytes but lets a stale edit silently re-admit a removed node, and
  tells neither administrator [review v2-B M5(a)]. Two halves on different passwords do not merge by radio: a
  person carries the winner.
- A window on version distance strands sleepers, does not stop exhaustion and is itself a splitting tool
  [review v1-A M2; review v1-B M1].
- No window: one signature at the maximum version freezes the identifier for good; the tie-break can be ground by
  both sides [review v2-A M3]. The version is 32 bits today (S24).
- Honest phones that forward "the newest state seen on a node" spread the attacker's object for them.
- Escape by a new network identifier is an in-person visit to every node.
- A "conflict report" with no defined reader is not a control.
- The same ceiling exists for the organisation's anchor object against the recovery path.

**B6. Replacing the top authority (planned roll-over or recovery) without orphaning existing networks.**
(T-OR14, L5; R16, R114)
- Organisation identifier = hash of the top key: it changes on replacement, and every object bound to it (R83)
  stops matching [review v2-A M6; review v2-B B2].
- Network authority recorded as a key: the new authority cannot update or rekey it — exactly when a rekey is due.
- "Add the new, then remove the old" needs a free slot that a family (top + recovery) does not have.
- Node-by-node roll-over over weeks: no single update is acceptable to both rotated and unrotated members.
- Every credential under the old top dies at once; each node's own credential must be re-delivered
  [review v1-A M9].
- The intermediate "old + new" object is a replayable way to bring the old root back (T-MS5).
- Nodes that were off during the change (R16); the base's residual stands: every node visited, or a pre-committed
  successor — which is a second root in a drawer.

**B7. Which operations need user presence on the phone without a prompt per node.** (T-PH1, T-PH10; R32, R109)
- Today: none (S14).
- Per use, with login counted as a use: 8 prompts to look at 8 nodes, 16 for a rekey, 60 for 30 nodes — estimate
  [review v2-B M4].
- New-biometric invalidation and "no secure lock screen" (platform behaviour [A]) can silently destroy a family's
  top authority.
- A validity window after one unlock is, for its duration, the unlocked-phone problem again.
- Exempting status needs a separate low-privilege key and credential, not a flag in the app.
- A check in app code is not a control (R32's negative test); coercion is out of reach of all of this.

**B8. Software-update authority that is neither a standing root-equivalent credential on a field phone nor a root
ceremony per update.** (T-OR12, F14; R82, R115, R77)
- Update classed with shell and root password + that class issued only by the top authority per node + an offline
  root = a ceremony per round and per new node, or one all-nodes credential that never expires (S3)
  [review v2-A M8; review v2-B M9].
- The image is already authorised by the release chain **[V release/release.go:1-4]**; the open part is who may
  *start* it, on which nodes, and whether that includes a permitted downgrade or repeated reboots.
- A member-carried node: may its carrier update it (§8.1 question 9)?
- A fixed, closed set of rights in a signed format makes a later split a format break.
- An update in progress is tied to the key that started it **[V node/node.go:832-838]** (the signer is passed to
  the update verbs): who continues when that administrator is gone? [review v1-B M10]

**B9. The issuing station as a live signing oracle (operator session, privileged automation / AI agent on the
host, restore from backup).** (T-OR2, T-OR3, T-OR13; R19, R21, R22, R23, R97, R98, R117)
- After the boot-time unlock the issuing key serves every process on the host (S20, [D ICS], not checkable here).
- An operator's browser session, a container escape, or an automation / AI agent with host access (X9) — fast, at
  scale, steerable by the data it reads — each need one call.
- Restore from backup forgets revocations and issued serials; a restored station signs a list with a version nodes
  have already passed, and they ignore it [review v1-A M10].
- A root derived from the same master as the station's other keys is separate in name only [review v1-A M7].
- Ceremony inputs prepared by the daily host [review v2-A m11].
- An account with the enrol right obtains an organisation credential for a key that is in no chip
  [review v2-A m10].
- The co-hosted TAK CA (T-OR4).
- The station-to-phone channel carries secrets, not only signed objects [review v2-A m14], and has no chosen link
  [review v1-B M12].
- Nodes cannot phone home: detection is after the fact (§10-6).
