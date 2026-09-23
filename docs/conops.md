# CONOPS & access matrix

The concrete operational layer under [`#52`](https://github.com/winson3QQ/Batman/issues/52)
(the abstract RBAC/ABAC *architecture*) and [`personas-and-roles.md`](personas-and-roles.md)
(the generic role sketch). Neither of those states the **real operational use-cases** — who
actually does what, on what hardware, in which lifecycle phase. This document enumerates them
as an access matrix:

> **subject (who) × platform (what hardware) × action (what task) × resource → access**

That matrix **is** the ABAC policy. It is the artefact [`#52`](https://github.com/winson3QQ/Batman/issues/52)
enforces, and it surfaces the cert-attribute schema that [`#13`](https://github.com/winson3QQ/Batman/issues/13)
(node/user PKI) and [`#48`](https://github.com/winson3QQ/Batman/issues/48) (TAK client mTLS)
must carry.

Companion to [`threat-model.md`](threat-model.md) (the trust spine) and
[`productization.md`](productization.md) (the *transport fabric for people **and** things*
positioning that makes machine subjects first-class here).

> **Scope & honesty (read this first).** This is an **M1 paper deliverable**: the reviewed
> use-case set and the derived matrix. **Enforcement is downstream and mostly deferred** — it
> rides the [`#13`](https://github.com/winson3QQ/Batman/issues/13) PKI (M2), the
> [`#52`](https://github.com/winson3QQ/Batman/issues/52) enforcement points, and app-layer
> checks per the CRL-infeasible reality. Nothing here ships a running feature; it makes the
> architecture buildable the moment identity is in place. Every §3 row carries a **Status**
> (`arch` = decided-on-paper here / `deferred → #x` = not enforceable until that issue lands).

> **One root cause to keep in view.** The powers that dominate everything else are (1) the
> authority to **create or modify identities** and (2) the authority to **author the code**
> that enforces access. This CONOPS keeps both *separate from the authority to read mission
> data* — §6 states that as testable invariants, and B-class rows below are written to make it
> hold rather than merely assert it.

---

## 1. The model

Access is **not** decided by role alone. Following [`#52`](https://github.com/winson3QQ/Batman/issues/52),
tactical access is mission/unit/clearance-driven (need-to-know), so the model is **hybrid
RBAC + ABAC**:

- **People → roles.** A human subject carries a role (operator, admin, deployer, maintainer,
  commander, developer, auditor, CA authority). Roles are coarse and stable.
- **Things → attributes.** A machine subject ([`#68`](https://github.com/winson3QQ/Batman/issues/68))
  is the *clean* ABAC case: a cert attribute `type=drone` maps directly to **publish-only, no
  general read, no command**. No human role fits a drone.
- **Everyone → contextual attributes.** `unit`, `mission`, `clearance` (need-to-know) refine
  both people and things.
- **Lifecycle phase is an attribute too.** What a subject/device may do is gated by *which
  phase* it is in — see §4. A node in `provision` accepts enrolment writes it must refuse once
  `operate`.

All attributes live in the **per-device / per-user certificate** ([`#13`](https://github.com/winson3QQ/Batman/issues/13)/[`#48`](https://github.com/winson3QQ/Batman/issues/48))
and the policy is evaluated against them at each enforcement point (console, TAK server,
provisioning tool, signed config channel, CLI). This is the [`#52`](https://github.com/winson3QQ/Batman/issues/52)
"one model, enforced consistently" requirement stated in terms an implementer can code
against.

**Trust framing — attribute-based least privilege, *not* full zero-trust yet.** An admitted
node is *not* trusted by default: the threat model's core adversary is a captured-but-admitted
node. But be honest about what §3 actually decides on — **static cert attributes**, evaluated
per enforcement point, plus fast revocation via short-lived certs. That is not SP 800-207
"per-request, continuously-evaluated" trust: a captured operator device keeps operator rights
until its cert expires or is revoked. The one dynamic signal we *do* wire in is
**quarantine** (§3, routing subject): the behavioural detection substrate
([`threat-model.md`](threat-model.md) L2, [`#14`](https://github.com/winson3QQ/Batman/issues/14)/[`#49`](https://github.com/winson3QQ/Batman/issues/49))
publishes a per-node `quarantined` state that the access decision treats as a denying
attribute. Full per-request evaluation is **deferred**; §8 maps 800-207 accordingly.

---

## 2. Subjects (the roster)

| Subject | Kind | One-line role | Distinct from |
|---|---|---|---|
| **CA / PKI authority** | person (offline) | Holds the root key; sets issuance **policy** (what attribute tuples may ever be signed) | deployer (defines policy vs. requests certs) |
| **Issuing CA / renewal signer** | service (online, bounded) | Signs **attribute-preserving** renewals within the root-authorized envelope | root CA (recurring field renewal vs. offline policy root) |
| **Field operator** | person | Responder/soldier: sees SA, sends own position/chat | — |
| **Comms officer / net-admin** | person | Keeps the fleet's network healthy and defended; quarantines misbehaving nodes | operator (no policy write) |
| **Deployer / provisioner (RA)** | person | Registration authority: flash, enrol within a pre-authorized envelope, key-fill, zeroize | CA (cannot mint arbitrary attrs); maintainer (bring-up vs. sustainment) |
| **Maintainer** | person | Sustains the *fielded* fleet: **deploys signed** OTA, renews certs, HW swap, EMS | deployer (initial vs. ongoing); developer (field vs. lab) |
| **Commander / COP** | person | Authors missions; owns the authoritative COP for their echelon | operator (authors vs. consumes SA) |
| **Developer (lab)** | person | Builds images, tunes RF, profiles, tracks SBOM/CVE | release signer (authors vs. signs) |
| **Release signer** | person | Signs a built image for release; authors none | developer (dual-control: build ≠ sign) |
| **Auditor** | person | Reads the attribution/audit log; authors nothing | commander (accountability vs. mission authority) |
| **Routing node** | node (L2) | batman-adv forwarder: forwards + originates OGMs | app subjects (routes packets, not data authority) |
| **Payload consumer** | person | Reads thing-published payload (video/imagery/survey) scoped by `unit`/`mission` | operator (payload streams vs. CoT SA) |
| **Drone** | thing | Publishes video + flight telemetry; reads own C2 | camera (has autopilot C2) |
| **Camera / sensor** | thing | Publishes imagery / sensor data; optional own C2 | drone (no autopilot) |
| **SDR** | thing | Publishes RF survey; reads own tasking | camera (RF survey + tasking channel) |

**Subjects the first draft missed, and why they matter:**

- **CA / PKI authority** — [`threat-model.md`](threat-model.md) centres on *a single
  offline/air-gapped root CA*. Someone holds that key and decides *which attribute tuples may
  ever be signed*. Without this subject the deployer silently **is** the CA, and issuance
  authority collapses into data authority (see B1/§6).
- **Routing node** — the threat model's **primary adversary** is an admitted node that lies
  about its batman-adv metric and grey-holes traffic. That subject has to appear in the matrix,
  with the **quarantine** action that stops routing through it (distinct from cert revocation).
- **Auditor / Payload consumer** — attribution needs a reader (else §6 #5 is write-only);
  thing-published data needs an authorized reader (else §3 things are either useless or
  default-open).
- **Release signer vs. developer, and an online issuing CA** — build ≠ sign is only real if the
  **release signer** is a separate subject from the developer who authored the image (else
  invariant #2 repeats the B1 flaw it fixed). And because short-lived certs make renewal a
  recurring *field* op, an **online issuing CA** signs attribute-preserving renewals within the
  root's envelope — the offline root cannot be in the loop each time.

---

## 3. The access matrix

Read `write X` as "may create/modify X"; `read X` as "may view X"; absence = denied.
"Mission data" = authoritative missions/orders authored at the command echelon. "SA" =
situational-awareness CoT (positions, chat). "Network policy" = channel/frequency, node/client
revocation, broadcast-governance toggles. **Telemetry** here means the *scrubbed* health schema
(metrics/topology only) — SA-bearing data (PLI in the alfred feed, packet buffers in crash
dumps) is classified as SA, not telemetry (see M2 note below the tables).

### Identity & code authorities (the powers that dominate)

| Subject | Platform | Task | Access | Status |
|---|---|---|---|---|
| **CA / PKI authority** | offline signer | define issuance policy; sign the attribute envelopes a device may hold | **write** issuance policy; **sign** root/envelope; **no** field access, **no** data read | deferred → [`#13`](https://github.com/winson3QQ/Batman/issues/13) |
| **Issuing CA / renewal signer** | online, bounded | sign **attribute-preserving** renewals within the root-authorized envelope | **sign** renewals only (**cannot** alter attributes, **cannot** widen the envelope); **no** data read | deferred → [`#13`](https://github.com/winson3QQ/Batman/issues/13) |
| **Deployer / provisioner (RA)** | provisioning kit + USB-C/M12 | flash + auto-onboard ([`#11`](https://github.com/winson3QQ/Batman/issues/11)); **request/bind** a cert **within the CA-authorized envelope**; key-fill; zeroize ([`#47`](https://github.com/winson3QQ/Batman/issues/47)) | **bind** identity to devices (attrs limited to the envelope); **revoke**; **no** SA/mission **read**; **cannot** mint `role`/`clearance` above the envelope | deferred → [`#13`](https://github.com/winson3QQ/Batman/issues/13) |
| **Developer (lab)** | bench / CI | build images; RF tuning; profiling; SBOM/CVE ([`#45`](https://github.com/winson3QQ/Batman/issues/45)) | **author** artifacts (**cannot sign** for release); lab **read** logs/RF; **no** standing access to a *fielded* node | deferred → [`#73`](https://github.com/winson3QQ/Batman/issues/73) |
| **Release signer** | offline/HSM signer | sign a built image for release | **sign** release artifacts only (dual-control: build ≠ sign, [`#73`](https://github.com/winson3QQ/Batman/issues/73)); **cannot** author; **no** data read | deferred → [`#73`](https://github.com/winson3QQ/Batman/issues/73) |

Elevation of `role`/`clearance` beyond a device's pre-authorized envelope requires the **CA
authority**, not the deployer — this is what stops a captured provisioning kit from minting a
`commander` cert for itself (B1).

### Operations (people)

| Subject | Platform | Task | Access | Status |
|---|---|---|---|---|
| **Field operator** | ATAK/iTAK phone | see team SA; send own PLI + chat | **read** CoT for own `unit` **and** `mission` (deny-by-default distribution); **write** own PLI/chat; **no** admin, **no** mission authorship | deferred → [`#48`](https://github.com/winson3QQ/Batman/issues/48) |
| **Comms officer / net-admin** | laptop / [`#14`](https://github.com/winson3QQ/Batman/issues/14) console + OTS UI + CLI | fleet health; change channel; revoke a node/client; **quarantine** a misbehaving node; broadcast toggles; TAK-server config | **read** scrubbed telemetry; **write** network policy **(signed)**; **set** quarantine; **no** SA read, **no** mission authorship | `arch` (policy shape) · enforcement deferred → [`#12`](https://github.com/winson3QQ/Batman/issues/12)/[`#14`](https://github.com/winson3QQ/Batman/issues/14) |
| **Maintainer** | mgmt console + OTA + spares | **deploy signed** OTA/patch; trigger cert renewal; swap failed HW + re-provision; decommission/**zeroize**; run EMS ([`#67`](https://github.com/winson3QQ/Batman/issues/67)) | **deploy** signed firmware only (**cannot author or sign** images); **request attribute-preserving renewal** via the issuing CA (**cannot** alter attrs); **write** config; **read** scrubbed telemetry/logs; **no** SA read, **no** mission authorship | deferred → [`#13`](https://github.com/winson3QQ/Batman/issues/13)/[`#73`](https://github.com/winson3QQ/Batman/issues/73) |
| **Commander / COP** | ICS_COMMAND (command post) | author missions; authoritative COP | **read** all for **own echelon/mission set**; **write** missions | deferred → app layer |
| **Auditor** | mgmt console (read-only) | review attribution/audit log | **read** audit log; **write** nothing | deferred → [`#13`](https://github.com/winson3QQ/Batman/issues/13) |

### Routing / L2 (the core-adversary subject)

| Subject | Platform | Task | Access | Status |
|---|---|---|---|---|
| **Routing node** | batman-adv node | forward packets; originate OGMs | **forward** + **originate OGMs**; **not trusted** for metric honesty; a `quarantined` node is dropped from routing regardless of a valid cert | `arch` · detection/quarantine → [`#49`](https://github.com/winson3QQ/Batman/issues/49) |

Quarantine is **separate from cert revocation**: a node can be a valid member (cert good) yet
be quarantined for *behaviour* (metric lies, OGM flood, grey-hole). Net-admin sets it; it
propagates as a signed state and denies routing/access as a dynamic attribute (§1).

### Things (machine subjects — the clean ABAC case)

| Subject | Platform | Task | Access | Status |
|---|---|---|---|---|
| **Drone** | node + camera/autopilot | publish video + flight telemetry; receive C2 | **write** video/telemetry; **read** its **own addressed C2 only**; **no** general SA read; **no** command *issue* to others | deferred → [`#68`](https://github.com/winson3QQ/Batman/issues/68) |
| **Camera / sensor** | node + sensor | publish imagery/data; optional C2 | **write** data; **read** own addressed control only (if any); else read none | deferred → [`#68`](https://github.com/winson3QQ/Batman/issues/68) |
| **SDR** | node + SDR | publish RF survey; receive tasking | **write** survey; **read** its **own addressed tasking only** | deferred → [`#68`](https://github.com/winson3QQ/Batman/issues/68) |
| **Payload consumer** (person) | ATAK / analyst station | view thing-published payload | **read** drone video / imagery / survey scoped by `unit`/`mission`; **no** write | deferred → [`#68`](https://github.com/winson3QQ/Batman/issues/68) |

**Thing C2 / tasking is a distinct authorised write, not an ambient channel.** A drone's
waypoint, a camera's PTZ, an SDR's tasking are **addressed to that thing** and written by an
authorised subject (commander/net-admin per deployment), attributed and signed. "reads its own
tasking only" is enforceable **only** because tasking is per-thing addressed, never a shared
broadcast topic. C2 may also be carried **out of band** for armed/EO platforms — declare which
per deployment.

> **M2 — telemetry is not SA-free by default.** The alfred health feed can carry positions/
> topology and crash/pstore dumps ([`#61`](https://github.com/winson3QQ/Batman/issues/61)) can
> capture live packet buffers = raw CoT. So "read telemetry, no SA" is only true against a
> **scrubbed** schema (metrics + up/down + link quality, no PLI, no payload). Crash dumps are
> classified **SA-bearing** and gated to the developer/maintainer under an incident, not part of
> routine telemetry read. Until the scrubbed schema exists this row's "no SA read" is a
> requirement, not a fact.

---

## 4. Lifecycle axis

Access is also gated by **which phase** the device/identity is in. The phase is an ABAC
attribute; the same subject has different rights against the same device across phases.

```
provision ─▶ deploy ─▶ operate ─▶ maintain ─▶ decommission
                                      │
                          (HW swap re-enters provision
                           for that one device, authorised)
```

| Phase | What it is | Who acts | Phase-gated access |
|---|---|---|---|
| **provision** | image burned, identity bound, keys filled | deployer (RA) | node **accepts** enrolment writes it must **refuse** in `operate`. `CHANGE-ME-NOW` guard ([`#13`](https://github.com/winson3QQ/Batman/issues/13)) blocks leaving with a default key. |
| **deploy** | placed in field, auto-onboards ([`#11`](https://github.com/winson3QQ/Batman/issues/11)) | deployer | converges to current signed fleet policy; no further local identity writes. |
| **operate** | forwarding + carrying payloads | operator, net-admin | steady-state matrix (§3). Enrolment surface **closed**. |
| **maintain** | in-field sustainment | maintainer | deploy signed OTA, renew certs, config; a failed HW component re-enters `provision` for that device only. |
| **decommission** | end of life | maintainer / deployer | **zeroize + revoke + wipe** (NIST SP 800-88). |

> **M7 — the phase gate is only a control once transitions are authorised.** A gate a captured
> node can self-promote through is not a gate. **Requirement (not yet built):** a `lifecycle`
> transition must be **signed by an authorised subject** — maintainer for operate↔maintain,
> and **physically gated** (local key-fill / button, not a network message) for any re-entry
> into `provision`. Until [`#13`](https://github.com/winson3QQ/Batman/issues/13) attests
> transitions, §4 is a **design intent, not an enforced control** — do not cite "enrolment
> surface closed" as if it holds today.

Three lifecycles run inside this:

- **Cert / key lifecycle** — issue → **renew** → revoke → zeroize. Short-lived certs (the
  CRL-infeasible decision, [`threat-model`](threat-model.md)) make **renewal a recurring
  maintainer task**.
- **Hardware lifecycle** — SD/radio wear-out → maintainer swap → **re-provision** the new
  board **and revoke + zeroize the removed component** (M8: a discarded board under model (a),
  §7, still holds valid key material = harvestable identity; revocation of the removed part is
  **mandatory in the swap**, not deferred to end-of-life).
- **Software lifecycle** — image versions, OTA cadence, SBOM/CVE ([`#45`](https://github.com/winson3QQ/Batman/issues/45)),
  dependency EOL.

**Decommission has two cases (M10):**

- **Cooperative EOL** — zeroize + revoke + wipe runs on the device; identity retired cleanly.
- **Compromise / capture** — zeroize **never runs**. The only lever is revocation, which is
  **best-effort under contested RF** (the captured node can jam the signed revocation set and
  ignores its own revocation) and honest nodes enforce it. **Residual exposure window = the
  short-cert lifetime.** This, not cooperative zeroize, is the case the threat model actually
  cares about — keep cert lifetimes short.

---

## 5. Cert-attribute schema (requirements this drives)

The matrix is only enforceable if the subject attributes it keys on actually live in the cert.
This is the requirement fed to [`#13`](https://github.com/winson3QQ/Batman/issues/13) (issuance)
and [`#48`](https://github.com/winson3QQ/Batman/issues/48) (TAK client certs):

| Attribute | Applies to | Example values | Used by |
|---|---|---|---|
| `role` | people | ca, issuing-ca, operator, net-admin, deployer, maintainer, commander, developer, release-signer, auditor | RBAC rows (§3) |
| `type` | things | drone, camera, sensor, sdr | publish-only / read-scope decisions |
| `unit` | both | team/section id | SA group scoping, need-to-know |
| `mission` | both | mission id | **required** read-scope (deny-by-default distribution) |
| `clearance` | both | R/C/S (NATO-style) | classification / need-to-know overlay |
| `lifecycle` | device | provision/deploy/operate/maintain/decommission | §4 phase gating |
| `quarantined` | node | true/false (signed, dynamic) | §3 routing subject — denies regardless of a valid cert |

Enforcement is **app-layer against these attributes**, consistent with the CRL-infeasible
reality: revocation is by short-lived cert expiry + a signed revocation set, not a live CRL
lookup. `role` and `clearance` values a deployer may bind are **bounded by the CA-signed
envelope** (§3, B1).

---

## 6. Separation-of-duties invariants

These must hold in any enforcement implementation. They are the *testable* claims of this
CONOPS. Each is written so the §3 matrix actually satisfies it — not merely asserts it.

1. **Identity authority ≠ data authority.** The deployer binds identities only *within a
   CA-authorized envelope* and cannot mint `role`/`clearance` above it, so it cannot self-issue
   a mission-reading cert. Arbitrary attribute grants require the offline **CA authority**,
   which has no field/data access.
2. **Code authority ≠ data authority.** OTA images are **authored by the developer and
   separately signed by the release signer** (two distinct subjects — build ≠ sign); the
   maintainer may only **deploy signed** artifacts. Firmware authority is a trust ceiling —
   mitigated by dual-control signing + reproducible builds ([`#73`](https://github.com/winson3QQ/Batman/issues/73)),
   not by an access rule.
3. **Data consumer ≠ network authority.** Operator reads mission/SA but cannot change network
   policy.
4. **Network authority ≠ mission authority.** Net-admin changes network policy but cannot
   author missions; net-admin/maintainer read only **scrubbed** telemetry, not SA (§3 M2 note).
5. **Every network-policy, identity, and quarantine write is signed and attributable** to an
   individual key — no anonymous fleet-wide change — **and an auditor can read that log** (else
   attribution is write-only).
6. **A thing never reads general SA and never issues commands** — publish-only, except its own
   *addressed* C2/tasking read.
7. **Dynamic SoD (mutual exclusion).** One human must not simultaneously hold conflicting
   certs (e.g. net-admin **and** commander) — that would collapse invariants 3/4 at the person
   layer. Conflicting roles are mutually exclusive per identity.
8. **Dual-control for high-blast-radius revocation *and quarantine*.** Both net-admin and
   deployer hold `revoke`; a captured either could revoke the commander's client = command DoS
   (N3). Revoking **or quarantining** a **command-echelon** cert/routing node requires two
   authorised approvers — a single net-admin must not be able to isolate the commander by
   either lever.

---

## 7. Key-unlock CONOPS (surfaced by storage design)

A who × hardware × task decision raised by the at-rest encryption design
([`#88`](https://github.com/winson3QQ/Batman/issues/88) B3 / [`#47`](https://github.com/winson3QQ/Batman/issues/47)):
the **key-unlock model is per node class / mission**, and it determines both the encryption
guarantee and whether a node can cold-boot without a human.

| Model | Node class | Protects against | Cost |
|---|---|---|---|
| **(a) Unattended auto-unlock** | relay left in the field | SD-card **theft** only (key material still on the board) | can cold-boot unattended; a **captured board** is readable → feeds the M8 swap-zeroize + M10 compromise case |
| **(b) Operator key-fill + zeroize-on-tamper** | operator-carried node | board **capture** (no key at rest; tamper wipes) | **cannot** cold-boot without an operator to key-fill |

This is a CONOPS choice, not a pure engineering one: it is decided by whether the node is
*attended*. It feeds the [`#47`](https://github.com/winson3QQ/Batman/issues/47) encryption
guarantee and the [`#88`](https://github.com/winson3QQ/Batman/issues/88) boot design.

---

## 8. Standards map

Design against these now; certify later (per [`productization`](productization.md), *implement
the capability, defer the paperwork*):

| Standard | What it covers | Where it lands here |
|---|---|---|
| **NIST SP 800-53** AC family (AC-2/3/5/6) | account mgmt, enforcement, separation of duties, least privilege | §3 matrix + §6 invariants |
| **NIST SP 800-162** | ABAC | attribute model (§1, §5) |
| **NIST SP 800-207** | Zero Trust | **partial** — attribute-based least privilege + fast revocation + one dynamic signal (quarantine); full per-request continuous evaluation is **deferred** (§1) |
| **ANSI/INCITS 359** | the RBAC standard (role model) | the people roles (§2) |
| **NIST SP 800-88** | media sanitization | decommission (§4, cooperative case) |
| **NATO** (Restricted/Confidential/Secret + need-to-know) | classification overlay | `clearance`/`mission`/`unit` ABAC attrs (§5) |

---

## 9. Enforcement status & scope

| Layer | Status | Owner |
|---|---|---|
| Reviewed use-case set + access matrix (this doc) | **M1 — this deliverable** | [`#69`](https://github.com/winson3QQ/Batman/issues/69) |
| RBAC/ABAC architecture + role-aware console views | M1 | [`#52`](https://github.com/winson3QQ/Batman/issues/52) |
| Per-device/user identity + CA/RA split + transition attestation | **deferred → M2** | [`#13`](https://github.com/winson3QQ/Batman/issues/13) |
| TAK client attributes + revocation + mission-group distribution | deferred | [`#48`](https://github.com/winson3QQ/Batman/issues/48) |
| Signed config propagation (network-policy writes) | deferred | [`#12`](https://github.com/winson3QQ/Batman/issues/12) + [`#14`](https://github.com/winson3QQ/Batman/issues/14) L2 |
| Behavioural detection + quarantine (dynamic attribute) | deferred | [`#49`](https://github.com/winson3QQ/Batman/issues/49) |
| Signed / reproducible OTA (code authority) | deferred | [`#73`](https://github.com/winson3QQ/Batman/issues/73) |
| Thing-subject publish-only transport + QoS + addressed C2 | deferred | [`#68`](https://github.com/winson3QQ/Batman/issues/68) |

**The matrix is buildable-against now; it becomes enforceable when [`#13`](https://github.com/winson3QQ/Batman/issues/13)
lands.**

---

## 10. Open decisions

- **Cert-less relay tier vs. attribution.** [`productization`](productization.md) makes the
  Base/relay (Zero 2 W) *carry no certificates* — deliberately expendable ("lose a board, not
  the network"). A cert-less node is admitted only by the shared SAE key = anonymous /
  unattributable / unrevocable — the exact `CHANGE-ME-NOW` hole the project kills. **The relay
  tier is currently parked** (Zero 2 W removed from roadmap, [`#102`](https://github.com/winson3QQ/Batman/issues/102),
  2026-09-17). **If it returns**, reconcile: a relay should still carry a **node cert**
  (attribution/revocation) even with **no** payload/TAK cert, or the mesh's admission strength
  drops to its weakest node. Decision deferred with the tier.
- **Mission read-scope granularity confirmed as `mission`-required** (was open) — CoT
  distribution is **deny-by-default per mission group** from day one, not unit-only broadcast.
  Remaining: whether a unit may span missions and how a subject switches active mission.
- **Maintainer vs. net-admin config overlap** — draw the exact line: config *of a device*
  (maintainer) vs. *network policy* (net-admin).
- **Lifecycle transition authority** — who signs each transition (M7), and the physical gate
  for `provision` re-entry. Blocking for §4 to be a real control.
- **Thing C2 in-band vs. out-of-band** — per-platform, especially armed/EO.
- **Payload-stream scoping mechanism** — CoT has deny-by-default mission groups, but bulk
  RTP/IQ/imagery has no named equivalent filter (harder for streams). Enforcement asymmetry to
  resolve in [`#68`](https://github.com/winson3QQ/Batman/issues/68).
- **Audit-log read scoping** — the auditor reads who-authored-which-mission metadata; that read
  should itself be `clearance`/`mission`-scoped, not blanket. Fold into [`#13`](https://github.com/winson3QQ/Batman/issues/13).
