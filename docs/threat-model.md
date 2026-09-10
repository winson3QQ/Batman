# Threat model & trust architecture

Where cryptography helps, where it does **not**, and what we do about the parts it
can't cover. This is the security spine the productization work hangs off.

The one-line version: **membership crypto decides *who is allowed on the network and
trusted for routing/data*. It does not stop an admitted-or-captured node from
degrading the shared RF medium, and it does nothing for PHY jamming.** A serious
tactical mesh therefore needs *admission + attribution + detection + revocation +
PHY agility*, not "we encrypted it, so it's secure."

## Why this matters — the Meshtastic critique

Meshtastic (and any shared-PSK design) hands every participant **one channel key**.
Consequences:

- everyone with the key is **anonymous and equal** — you cannot tell *which* node did
  something;
- **no revocation** — kicking one node means re-keying the whole network;
- a joined node can misbehave with no attribution.

This is exactly the `CHANGE-ME-NOW` shared-key hole tracked in
[#13](https://github.com/winson3QQ/Batman/issues/13). Replacing it with **per-node
PKI** is our primary differentiator — but it is only the *admission + attribution*
half of the problem.

## Layered threat model

| Layer | Threat | Does PKI/crypto help? | Real mitigation |
|---|---|---|---|
| **PHY / RF** | External SDR **or an admitted node** keys up on 920–925 MHz and saturates airtime (CSMA: one greedy TX starves everyone); malformed-frame flooding | ❌ **No** — you cannot encrypt your way out of a jammed medium | Frequency agility / channel hop (**#15**), directional antennas, TX-power control, **detect → hop / locate & remove**; low-duty-cycle coexistence |
| **L2 mesh (batman-adv)** | Admitted-but-malicious node floods OGMs, **lies about throughput metric to attract traffic then black/grey-holes it**, broadcast storm, MAC/claim spoofing | ⚠️ Partial — identity can *sign* OGMs, but batman-adv does not authenticate them itself | **Behavioural detection**: watch per-originator OGM rate, **measured delivery vs. advertised metric**, bridge-loop-avoidance (**#10**, confirmed enabled) → quarantine |
| **L3 / admission** | Random/anonymous node joins the mesh | ✅ **Yes** — PKI admission + attribution | **#13** per-node certs |
| **App / TAK** | Unauthorised client injects forged CoT (position, chat, orders) | ✅ **Yes** — mutual-TLS client certs | TAK mTLS (below) |

## Trust architecture: one PKI, two certificate populations

A single offline/air-gapped **root CA** signs:

1. **Node certificates** — each mesh node has a unique identity used for admission,
   attribution, and (future) signed routing / WireGuard peer identity (**#16**).
2. **TAK client certificates** — each ATAK/iTAK device is enrolled with its own cert.

Benefits over a shared key: per-entity attribution, **revocation of one entity
without re-keying the fleet** (CRL / short-lived certs), and a clean provisioning
story (**#11**: enrol identity at first boot).

### TAK client authentication (current gap)

Today FTS on manet02 accepts **plaintext CoT on TCP 18087** — anyone who can reach
the port can read or inject CoT. Acceptable for bring-up, **not for production**.

Target: **mutual TLS on SSL CoT (8089)** with per-device client certificates issued
by the mesh/FTS CA, data-package enrolment for ATAK, and API auth on the RestAPI.
Disable the plaintext CoT port in the production profile.

## The honest boundary (state this to customers)

> You can make *who is allowed on the network* strong — stronger than Meshtastic's
> shared PSK — and you can **detect and quickly revoke** a misbehaving node. You
> **cannot** use cryptography to stop an admitted or captured node from degrading the
> RF medium. That is inherent to shared-spectrum mesh. The defence is: don't admit
> untrusted nodes, detect anomalies fast, revoke fast, and stay agile on the PHY.

## Detection substrate — we already have the raw material

- **PHY jamming / channel health**: `morse_cli … stats` exposes RSSI, noise floor,
  FCS-fail rate and airtime → a jammer shows up as noise-floor rise + throughput
  collapse + one station hogging airtime.
- **L2 misbehaviour**: `batctl` per-neighbour stats + `alfred` (already running) give
  per-originator OGM rates and let us compare **advertised metric vs. actually
  delivered** — a metric-liar / black-holer is detectable.

Feeding this into the decentralised health console (**#14**) turns it from "dashboard"
into **anomaly detection + quarantine**: on detection, publish a revocation / stop
routing through the offending node, and (PHY) trigger a channel hop.

## Maps to issues

- **#13** — per-node PKI; single root also signs TAK client certs. *Foundation.*
- **TAK mTLS client auth** (new) — 8089 mutual TLS, kill plaintext CoT in prod.
- **Node misbehaviour detection + quarantine/revocation** (new) — feeds #14, eats
  `morse_cli`/`batctl`/`alfred`.
- **#14** — decentralised health console = the detection/quarantine substrate.
- **#15** — frequency agility = the *only* PHY-layer answer to jamming; promote.
- **#10** — BLA confirmed enabled (loop/claim protection).
