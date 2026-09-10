# Productization: standards map & technical roadmap

Recorded now so the **capabilities** get built into the architecture early; formal
**certification is deliberately deferred** (no US-gov sale planned yet). The rule:
*implement the technical capability a standard demands, defer the paperwork.*

Security architecture lives in [`threat-model.md`](threat-model.md).

## Platform positioning — a transport fabric for people *and* things

Think of Batman not as a single product (a tactical radio for people) but as a
**载台 / carrier platform**: a resilient HaLow + batman-adv **data-transport fabric**
with **pluggable payload services**.

- **This phase — for people:** HaLow + PTT + TAK. TAK/FreeTAKServer is **one payload
  service** (situational awareness for humans).
- **Next phase — for things:** drones, cameras, SDR, other sensors. **Machines generate
  data** (imagery, SDR captures, sensor logs), not just CoT position blips — so **bulk /
  file / stream transport is a baseline requirement, not an add-on.**

Architectural consequences:

1. **The edge node is a generic payload host** — which is the strategic reason for
   Docker on the node. FTS is the first tenant; a video relay, an SDR service, or an
   MQTT sensor broker are future tenants in their own containers.
2. **The mesh may carry non-TAK machine data** (RTP video, SDR IQ, MQTT telemetry)
   alongside TAK. The transport must not assume TAK.
3. **Edge partition-survival is Tier A + B** (live CoT **and** data packages / bulk
   transfer), decided on this platform basis — see the ICS_COMMAND epic. Heavy
   collaborative state (missions) stays at the command echelon.
4. **The node must not fall over under multi-tenant data load** — see the carrier-grade
   node & EMS epic and the load/stability work (#61, #63).

## Standards map (record only — certification later)

> The per-use-case mapping — which standard governs each *subject × action* in the
> CONOPS matrix, i.e. the implementation reference spec — is in
> [`standards-crosswalk.md`](standards-crosswalk.md).

Four separate things people lump under "compliance":

### (a) Interoperability — so FEMA/NATO will actually use it
- **TAK / Cursor-on-Target (CoT)** — the de-facto standard in this domain; DHS/FEMA
  and NATO consume it. We have it (FreeTAKServer, #44). Next: TAK **federation**,
  NATO **NFFI / STANAG 4677**, MIP.
- **P25 / FirstNet (Band 14)** — LMR/public-safety-LTE interop; not our RF, but buyers
  ask "how does it bridge to existing radios."

### (b) Security accreditation — so it *can* be sold to government
- **FIPS 140-2/140-3 validated crypto** — hard gate for US federal. All crypto
  (WireGuard #16, disk encryption, TLS) should be able to run on a **FIPS-validated
  module**. ⚠️ FTS ships `cryptography 36.0.2` — not FIPS-validated and old.
- **NIST 800-171 / CMMC / RMF-ATO** — process accreditation for DoD supply chain.
- **NATO Restricted+** — NATO-approved crypto (beyond FIPS); possibly **TEMPEST**.

### (c) Type approval — so it can legally transmit / ship
- **FCC Part 15.247 / CE RED** — 902–928 MHz type approval. ⚠️ `hardware.md` notes the
  OpenMANET BCF pushes ~27 dBm, which may exceed local limits — needs a per-region
  regulatory build and lock before sale.
- **MIL-STD-810 / IP67** — ruggedization buyers expect (ties to the V3 enclosure).
- **UN 38.3** — Li-battery shipping (ties to the V3 power system).

### (d) Supply chain ⚠️ most-overlooked, can hard-block a market
- **NDAA §889 / FCC Covered List** — the radio module is **Quectel FGH100M**; Quectel
  is a Chinese company. Morse Micro (die, AU) and Raspberry Pi (UK) are fine, but
  **Quectel may bar US federal / public-safety sales**. This is an *architecture-level*
  risk → evaluate a non-Chinese HaLow module now, before it's baked in.

## Technical roadmap — dependency-ordered

```
Layer 0  (no dependencies — start now)
  ⓐ SBOM + CVE in CI            Syft→CycloneDX + Trivy/Grype/OSV; gate; publish SBOM.
                                First scan of the FTS container will light up (old pins).
  ⓑ Supply-chain / NDAA         Evaluate a non-Chinese HaLow module vs Quectel FGH100M.

Layer 1  (security foundation)
  ⓒ #13  per-device PKI         One root CA signs BOTH node certs AND TAK client certs.
                                Kills the shared CHANGE-ME-NOW key (anti-Meshtastic).
  ⓓ Secure element (HW)         ATECC608 / TPM SLB9670 — the key vault that makes
                                "pull the SD, can't decrypt" real. Feeds ⓔ and ⓒ.

Layer 2
  ⓔ Data-at-rest encryption     Model-split: LUKS data partition + dm-verity rootfs +
                                key sealed in ⓓ + USB-C/M12 key-fill & zeroize.
                                (needs ⓓ; relates ⓒ)
  ⓕ #41  immutable rootfs +     A/B partitions + health-gated OTA rollback (RAUC/
         A/B OTA rollback       Mender / Pi tryboot). Overlaps ⓔ's partition layout.
                                Critical: you upgrade a mesh you're standing on.

Layer 3
  ⓖ #11  zero-touch provision   First-boot MAC→IPv4 + PKI enrolment (needs ⓒ).
  ⓗ #16  WireGuard              Mark FIPS-validated requirement (needs ⓒ).
  ⓘ #14  decentralised health   via alfred; also the substrate for misbehaviour
         console                 detection + quarantine (see threat-model).
  ⓙ #15  frequency agility      The only PHY-layer answer to jamming — promote from
                                "long-term."
  + TAK mTLS client auth        8089 mutual TLS, per-device certs, kill plaintext CoT
                                in prod (extends ⓒ).
  + Node misbehaviour detect    OGM-flood / metric-lying black-hole / PHY jam →
    + quarantine/revoke          quarantine; eats morse_cli/batctl/alfred; feeds ⓘ.
```

### Data-at-rest, split by model
| Model | Encryption | Port role |
|---|---|---|
| **Base** (civil / exercise) | none, or dm-verity (tamper-evident, not confidential) | USB-C/M12 = console/provision |
| **Secure — attended** (base/vehicle node) | LUKS + **USB security dongle required to unlock**; operator holds it | pull dongle → no decrypt (only for manned nodes) |
| **Secure — unattended** (field node) | LUKS, key **sealed in soldered secure element**, released by measured boot | USB-C/M12 only for **fill / rotate / zeroize**; USB **disabled at runtime** (BadUSB/DMA surface) |

Note: the V3 enclosure already plans an **M12 8-pin panel connector** (⌀15.5 mm flange).
USB or UART console/key-fill can ride the M12 pins — more waterproof than a bare USB-C
hole. A dedicated USB-C is only needed for the attended "dongle-to-unlock" model.
