# Personas, roles & access control (RBAC)

Who uses the system, what each role **sees** vs **sets**, and the access-control
architecture that spans every surface (console, TAK server, provisioning, config
propagation, CLI). Companion to [`threat-model.md`](threat-model.md) and
[`productization.md`](productization.md).

Core principle: **one data model, four role-projected views.** The same underlying
data (the alfred health feed + the TAK server) is projected into a surface built for
each role. Do **not** leak mesh internals to the field operator, and do **not** force
the network admin into ATAK.

## The four personas

| Role | **Sees (read)** | **Sets / acts (write)** | **Tool** |
|---|---|---|---|
| **① Field operator** (ATAK phone: responder / soldier) | Team positions & chat, **am I connected / in coverage**, battery | Almost nothing (callsign at most; rest baked at provisioning) | **ATAK/iTAK** + a node **status light** (meshled: green = mesh **and** server up). Infrastructure is invisible — they need not know it's a mesh. |
| **② Network admin** / comms officer | Fleet up/down, per-link SNR/throughput, topology, battery, **jamming/misbehaviour alerts**, TAK-server status, connected clients | Channel/frequency (react to jamming), **revoke a node/client**, reposition relays, broadcast-governance toggles, TAK-server config | **#14 fleet console** (log into any node/laptop) + **FTS Web UI** + CLI (meshtest/batctl) |
| **③ Deployer / provisioner** | Which nodes/clients are enrolled, image version per node | **Flash image (auto-onboard #11)**, **enrol a new ATAK client** (issue cert / data package #48), zeroize/decommission (#47), assign identity (#13) | Provisioning flow: burn image + a **field enrolment tool** + USB-C/M12 key-fill |
| **④ Developer / maintainer** | Logs, RF stats, CPU profiling, SBOM/CVE | Image builds, RF tuning, OTA rollout | SSH, meshtest/soak scripts, CI (#45), A/B OTA (#41) |

## Settings — where they live, who may change them

- **Operator settings**: none of substance — baked at provisioning.
- **Admin settings** = network policy (channel, revocation, broadcast rules). Must be
  **signed config that propagates** across the mesh — otherwise one captured node can
  rewrite fleet-wide policy. Ties to #13 (signing identity) and #49 (detection).
- **Deployer settings** = identity / enrolment, set at provisioning time only.

## RBAC architecture (cross-cutting)

RBAC is not a console login screen; it is **one access-control model enforced
consistently** across the console, the TAK server, the provisioning/enrolment tool,
the config-propagation channel, and the CLI — all bound to the per-device / per-user
identity from the **#13 PKI**. Tactical access is often mission/unit/clearance-driven
(need-to-know), so expect **hybrid RBAC + ABAC** (roles *plus* attributes: unit,
mission, clearance), not roles alone.

**Separation of duties** (illustrative): the deployer can enrol devices but not read
mission data; the operator reads mission data but cannot change network policy; the
admin changes policy but every policy change is **signed** and attributable.

### Standards to design against (certify later, per productization.md)

- **ANSI/INCITS 359** — the RBAC standard (role model).
- **NIST SP 800-53** Access Control (AC) family — **AC-2** account mgmt, **AC-3**
  enforcement, **AC-5** separation of duties, **AC-6** least privilege. This is the
  federal baseline FEMA/DHS are assessed against under RMF.
- **NIST SP 800-162** — ABAC, for the attribute/need-to-know dimension.
- **NIST SP 800-207** — Zero Trust ("never trust, always verify; least privilege;
  per-request"), which aligns cleanly with our threat model's "don't trust an admitted
  node by default."
- **FIPS 201 / PIV** — federal identity-credential model; our per-device certs (#13)
  are the fielded analog.
- **NATO** typically maps access control to NIST plus **classification + need-to-know**
  handling (NATO Restricted/Confidential/Secret) — an ABAC-flavoured overlay.

The point (consistent with productization.md): **design the RBAC/ABAC capability into
the architecture now**; the formal accreditation (RMF/ATO, NATO) is deferred.

## Maps to milestones

- **M1** (self-forming, observable): serves **admin** (#14 console) + **deployer**
  (#11 auto-onboard); **operator** already served by ATAK (#44). Adds: RBAC
  architecture + role-aware console views, and the operator status light.
- **M2** (trusted, secure): deepens **deployer** (#13/#48 enrolment, #47 zeroize) +
  **admin** (revocation); cryptographic RBAC **enforcement** hardens here with #13.

New scope this raises: **RBAC/ABAC architecture** (cross-cutting), a **field enrolment
tool** (deployer), and an **operator connectivity status indicator** (meshled
extension).
