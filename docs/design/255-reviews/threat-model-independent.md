# Independent threat model — key-management plane (#255)

Status: independent analysis, written blind. Base: worktree `C:/src/Batman-255`, main `4eba26d`.
The author did NOT read `255-threat-model.md`, `255-key-authority.md`, or any file under `255-reviews/`
(only the file names `review-v1-A.md`, `review-v1-B.md`, `v2-changes.md` were seen in a directory listing; no content).
Method: STRIDE per trust boundary and per flow, attack trees, likelihood x impact. Decision level, not code level.
Out of scope (already in `docs/threat-model.md`): jamming, batman-adv routing attacks, TAK CoT injection.

Evidence marks: **[V file:line]** verified in this worktree; **[D file:line]** stated in a design doc (not code);
**[A]** assumed or from general knowledge, not verified here. ATECC608B behaviour is [A] throughout — check each
item against the datasheet and on a development chip before the configuration zone is locked.

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
       | app + Keystore |          (Noise; phone <-> provd)             | NODE (Pi, OpenWrt, no secure boot)   |
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
| B2 | Operators / automation <-> issuing station | console, mTLS, FIDO2 unlock | sister product: unlock at boot, key live in memory afterwards **[D ICS threat_model §8.8]** |
| B3 | Issuing station <-> phone (person enrolment) | station LAN / QR | does not exist yet |
| B4 | Issuing station <-> node (equipment enrolment) | phone as courier, or direct | does not exist yet |
| B5 | Phone <-> provd | BLE GATT; HTTP 8095 from phone-AP clients only **[V feed/batman-prov/files/batman-http.nft]** | Noise NX / NXpsk0, owner-op per verb **[D docs/design/219-protocol.md §3, §5.7]** |
| B6 | provd <-> provhelper | unix socket; provd uid 471, no capabilities, `requirejail` **[V feed/batman-prov/files/batman-provd.init:34-36]** | helper recomputes challenges and verifies owner-op on the raw body **[D 219-protocol.md §5.4, §5.7]** |
| B7 | root on the node <-> SE | I2C, shared bus | none: root may issue any chip command |
| B8 | Anyone with a card reader <-> SD card | physical | none: p5/p6 plaintext by decision **[D docs/design/219-field-provisioning.md:27]**; record integrity is a bare SHA-256 in `prov.meta` **[V feed/batman-prov/src/provstore/provstore.go:10]** |
| B9 | Factory / reseller / repair <-> node and label | physical, tooling | does not exist yet (file backend creates the identity on the card **[V feed/batman-prov/src/keystore/keystore.go:1-5]**) |
| B10 | Paper and human channels | body QR, recovery sheet, chat images, voice | QR = 256-bit claim secret; SAS = 6 digits |
| B11 | Phone-AP clients <-> node LAN | WPA-PSK | phone AP, `eth0` and `bat0` are ports of one bridge **[D docs/design/254-p3-impl.md:62]** — the AP password or the Ethernet jack is L2 access to the mesh |
| B12 | Node <-> node, org <-> org | HaLow SAE, batman-adv | one shared password; no per-node admission |
| B13 | App / OS update channel <-> phone | store, sideload, MDM | app signing key gates the Keystore keys |
| B14 | Release pipeline <-> node | signed manifest carried by the app | root key in squashfs, min-serial, downgrade list **[V release/release.go:26-31,57-58]** |

---

## 3. Assumptions per build, and what is verified

| # | Statement | Civil | Tactical | Evidence |
|---|---|---|---|---|
| S1 | No secure / measured boot: whoever holds the node can boot any OS and drive the SE | true | assumed false (secure boot planned) | task statement; tactical is [A] |
| S2 | The SD partitions holding the provisioning record are plaintext | true | [A] unknown | **[D 219-field-provisioning.md:27, :492]** |
| S3 | The node has no trusted clock | true | RTC later; trustworthy only if set by an authenticated source | task statement |
| S4 | Node identity today = a P-256 key file on the card; a reflash makes a new identity | true | n/a | **[V keystore/keystore.go:1-5]**, **[D 219-field-provisioning.md:335]** |
| S5 | Purpose labels ("the node never signs a caller's value") are enforced by helper software, not by the key store | true | true unless the SE configuration enforces it | **[V keystore/keystore.go:76-103]** |
| S6 | At most 4 owners and 4 admins per node; the last owner cannot be removed except by reflash | true | same | **[V provstore/provstore.go:147,181]**, **[V node/node.go:954,983]** |
| S7 | Version v+1 of a network is accepted on ONE signature by ANY admin of version v and may replace the whole admin set | true | same | **[V node/node.go:1192,1227]** |
| S8 | Only a contiguous chain is accepted; a node that applied one v+1 cannot move to a competing v+1 | true in code | same | **[V node/node.go:1200]**; the spec says "smaller hash wins, nodes switch" **[D 219-protocol.md:367]** — code and spec differ |
| S9 | The node neither stores nor consults the member list; membership = knowing the password | true | same | **[V node/node.go:1214]** |
| S10 | Removing an owner does not remove the SSH keys that owner installed, nor change the root password | true | same | **[V node/node.go:966-995]** (only `Owners` and `AdvOwnerKey` change) |
| S11 | Claim hands the node's root password to the claimant | true | same | **[V node/node.go:609]** |
| S12 | The "claimed before" counter is a field in the plaintext record, not hardware | true | SE counter planned | **[V node/node.go:592]** |
| S13 | Factory reset over the protocol does not exist (`reset` -> E_UNSUPPORTED) | true | — | **[V provd/session.go:641-642]** |
| S14 | Phone keys: StrongBox preferred, TEE fallback, the ECDH key can be SOFTWARE on some phones; **no key is bound to user authentication**; no key attestation is requested | true | same app | **[V app/android/app/src/main/kotlin/dev/batman/batman_app/keystore/Keys.kt:79-98]** (grep for `setUserAuthenticationRequired` / `setAttestationChallenge`: no hit), **[V app/android/app/src/test/kotlin/dev/batman/batman_app/keystore/KeyPolicyTest.kt:50-53]** |
| S15 | App data is excluded from cloud backup and device-to-device transfer | true | same | **[V app/android/app/src/main/AndroidManifest.xml:29-30]** |
| S16 | `node_cert` (the SE-signed binding of the per-boot Noise key and of the ECDH public key) has no verifier freshness and never expires | by design | same | **[D 219-protocol.md:78]** |
| S17 | The ECDH slot gives the shared secret to the host | planned | planned | **[D 219-protocol.md §7.3]**, chip [A] |
| S18 | Planned recovery of a lost owner phone = body QR + button on the node, network settings kept | planned | — | **[D 219-field-provisioning.md:432]** |
| S19 | A shared `team_ap_psk` travels in each node's secrets bundle | true | same | **[D 219-protocol.md:341]** |
| S20 | The issuing station holds its CA key live after a boot-time FIDO2 unlock and already co-hosts a TAK CA | true | same | **[D ICS threat_model §8.3, §8.8]** (reference only) |
| S21 | provd terminates the Noise session, so every plaintext that crosses it is visible to provd | true | same | **[V provd/noise.go:38-39]** |

Consequence of S1 + S2 + B7, stated once: **on the civil build, physical possession of a node equals root on that
node plus unrestricted use of its SE.** No design changes that. What a design *can* guarantee is: (i) SE keys
cannot be copied out; (ii) possession of one node gives no authority over any other node; (iii) what was obtained
during possession stops being useful once the node is revoked or returned. Every requirement below is written
against those three properties, never against "the node protects its secrets".

---

## 4. Actors

| Id | Actor | Capabilities |
|---|---|---|
| X1 | Remote RF attacker | BLE / HaLow / Wi-Fi range; records advertisements, handshakes, WPA handshakes of phone APs; replays; no keys |
| X2 | Captor of a node | S1+S2: root, SE as an oracle for as long as held; may keep it or return it (evil maid) |
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
regains authority over that node; a "reset" node can be un-reset. -> **R11.** Res: on civil, the attacker with
the card also has the chip and can bypass any check in software; the requirement is that *other parties*
(phones, other nodes) can detect a rolled-back node, not that the node resists.

**T-SE8 (T, E) Record edit instead of protocol.** B8: add an owner key, an admin key, or an SSH key to
`prov.cbor` / overlay offline and fix the hash. Node-local takeover without any credential. -> same boundary as
S1; **R12** (possession of a node never yields authority over others) and **R13** (a tampered node's statements
are not trusted beyond its own identity).

**T-SE9 (I) Bus and at-rest disclosure.** Shared-secret output and any slot read cross I2C in clear unless the
chip encrypts them, and an IO-protection key stored on the same SD card protects against nobody who has the
card. -> do not count bus encryption as a control on civil; decide it for tactical (**§8.2**).

**T-SE10 (T, X11) Injected rather than generated keys.** If the configuration allows writing a private key,
the factory (or an interdictor before lock) can ship nodes whose "hardware" keys are known. -> **R14.**

**T-SE11 (X12) Irreversible mistake.** The configuration zone lock cannot be undone and there are few spare
chips. A wrong bit in one slot's policy silently enables T-SE1/2/4/10 for every unit of the batch.
-> **R15** and the list in **§8.2**.

**T-SE12 (S) SE attests the chip, not the software.** Without measured boot the chip signs for any firmware. A
"status" or "I applied the new password" statement signed by the node key proves presence of the chip only.
-> **R13.**

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

### 5.5 Mesh and inter-organisation (B12)

**T-MS1 (E) Shared password = no individual removal.** Stated in the existing docs
**[D 219-protocol.md:315]**. Consequences that the new design must face: (a) removing a person or a node *is* a
rekey of the network; (b) the removed party keeps access to every node that has not yet rekeyed, and those nodes
are exactly the ones that are hard to reach; (c) a member physically holding a node can read the password from
the card (S2) whatever role the app gives them. -> **R49, R50.**

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
| **F12 Member: status and phone Wi-Fi of their node** | T-ND3, T-ND5; (E) member verb set creeps upward (diagnostics bundle, SSH, update) | R45, R48, R68 | A member holding the node has root on it anyway (S1) |

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
| **L8 Upgrade / trial boot / automatic revert** | New image writes a record the old image cannot read (already a known constraint **[V provstore/provstore.go:55-58]**); after revert the old image must fail closed, not "unclaimed"; SE state (counter, slots) written by the trial image is *not* reverted with the slot — one-way door inside a two-way update | R75, R76 | — |
| **L9 Downgrade** to an image without organisation authority | Old image honours only the old owner model; an attacker with the card flashes an old, validly signed image (physical downgrade is outside the manifest's downgrade rule) and uses a retained owner key or the QR + first-come claim | R71, R77 | Physical downgrade on civil cannot be prevented, only made useless to others |
| **L10 Restore from backup** | Phone: excluded (S15), so every restore is a re-enrolment — good, but then recovery must not depend on it. Station: T-OR3. Node card image: T-SE7 | R11, R23 | — |
| **L11 Decommissioning** (node scrapped, organisation dissolved, station retired) | Chips in scrapped HATs keep identity and claim secret; a retired station's disks hold the issuing key; a dissolved organisation's nodes are locked forever or free for anyone | R66, R78 | — |
| **L12 Crash / power loss mid-change** | A change of authority (new admin set, new root pin, SE counter step) that is half-applied: record says new, chip says old, or the reverse | R76 | — |

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
│   └─ 4.2 node by node: card edit / own OS (always possible on civil, does not scale)               [T-SE8]
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
├─ 1 Any node's card (S2) — one captured or briefly accessed node
├─ 2 Be an addressee: forged ECDH binding (T-SE2) -> every future bundle, no further access needed
├─ 3 Decrypt recorded bundles with a later-captured node (T-SE3)
├─ 4 In-person invite QR that contains the password, photographed                [D 219-protocol §7.6]
├─ 5 Compromised provd on a node during an operation that carries it in session plaintext (T-ND1)
└─ 6 Phone AP: capture a WPA handshake, crack a weak member-chosen password -> on the bridge, no mesh password needed
```

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
   (theft market vs. orphaned hardware / vendor master key). Decide per build.
9. **What authorises a firmware update in the organisation model**, and can a member-held node be updated or
   downgraded by its carrier?
10. **Which proofs are fresh?** For every place a node key signature is accepted: does it include a verifier
    nonce and the session binding, and would a signature made last year by a repair shop pass?
11. **What crosses provd in plaintext** in each new flow (enrolment tokens, new trust anchors, recovery shares)?
12. **How does a brand-new or replaced admin phone catch up a node that is 200 versions behind?**
13. **What is the audit record, where does it live, and who can alter it?** Node logs are on the plaintext card;
    phone clocks are settable.
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

### 8.2 To decide before the secure element's configuration zone is locked

All chip behaviours here are [A]; each line needs a datasheet reference and a test on a sacrificial chip.

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
10. **IO-protection key / encrypted reads**: used or not, and where the host half lives (useless on the card for
    civil; meaningful only with secure boot).
11. **I2C address, watchdog / timing mode, bus sharing** with the RTC and power monitor: a peripheral or a
    mis-wired HAT that can hold the bus is a denial of every signature.
12. **Key validity / revocation features of the chip** (disable a key permanently): wanted for decommissioning
    (L11), dangerous as a field brick.
13. **Dev vs production separation at chip level**: a visibly different root / prefix for development chips so
    a dev-configured chip can never pass as production (the software equivalent exists today as the `dev:`
    certificate rule **[D 219-protocol.md §9]**).
14. **Batch procedure**: lock one, run the full negative test list (§9 tests marked SE) against it, only then
    lock the rest; record the configuration zone dump of every unit.

---

## 9. Requirements checklist with negative tests

A reviewer ticks each item only with the named test's output attached. "NT" = negative test (must fail without
the control). Tests marked **SE** must be run on a real locked chip, not a software stand-in.

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

---

## 10. Residual risks that no design removes (state them to customers)

1. **Civil build: holding a node is owning that node** — its card secrets immediately, its chip for as long as
   it is held. The mesh password in use at the time of capture is lost.
2. **Shared mesh password**: removal of one party is a rekey of all, and is only as complete as the least
   reachable node. Until per-node link credentials exist, "removed" is a process with a duration.
3. **No clock**: nothing expires on a node by itself. Authority ends when the node is told, not when the paper
   says.
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
