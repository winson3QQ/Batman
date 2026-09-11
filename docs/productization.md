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

### Hardware tiers × security models (decision 2026-09-11)

The fleet has two boards — **Pi 4 / CM4** and **Pi Zero 2 W** (on order) — and they do **not**
support the same security chain. Neither has a secure element on board: Pi 4's OTP can hold a
signed-boot key *hash* but is readable by root (`vcgencmd otp_dump`) — it is not a key vault.
A real SE (ATECC608 on I2C-1, or a TPM on a spare SPI CS — SPI0 is the HaLow radio) is an
**add-on on both boards**. What each board can honestly reach:

| Capability | Pi 4 / CM4 (`bcm2711`) | Zero 2 W (`bcm2710`) | Why |
|---|---|---|---|
| LUKS data partition (#47) | ✅ | ✅ | kernel feature; neither has ARMv8 crypto ext (software AES), SD is the bottleneck anyway |
| dm-verity rootfs (#41/#74) | ✅ tamper-evident | ⚠️ corruption-proof only | root hash lives in cmdline on the FAT boot partition; without signed boot anyone with the card rewrites it |
| **Signed boot** (#74 link 1) | ✅ EEPROM bootloader + OTP | ❌ **impossible** | Zero's bootloader is ROM + `bootcode.bin` on SD — no EEPROM, no root of trust |
| A/B OTA (#89) | ✅ full: `tryboot_a_b`, **boot partition is A/B too** | ⚠️ `tryboot.txt`-level only | basic tryboot exists on all models; switching the *boot partition* needs the Pi 4+ bootloader. A bad boot-partition write on Zero is unrecoverable in the field |
| hung-task / ramoops / serial console (#61) | ✅ | ✅ | kernel + UART (verify the bcm2710 DT carries the ramoops node) |
| SE-held key, released only to a trusted OS | ✅ with add-on SE | ⚠️ SE without signed boot: a swapped kernel can ask the SE for the key | measured boot (TPM PCR) does not exist on Pi bootloaders at all — the reachable form is *signed boot + SE authenticates the node* |
| FTS / docker payload host | ✅ | ❌ 512 MB RAM | relay-class node |

**Mapping to the models above:**
- **Base** → Zero 2 W's natural level. Cheap, light, expendable **relay**: carries no
  certificates, is not a payload host; losing one loses a board, not the network.
- **Secure — attended** → the **highest honest level for Zero 2 W**: LUKS key on the operator's
  dongle, never on the board, so the missing root of trust does not matter.
- **Secure — unattended** → **Pi 4 / CM4 (and up) only**. The only tier that may be left
  unattended holding identity (#13), TAK certs (#48) or a payload.

Consequence for CONOPS (#69): the two boards are **two roles, not two sizes of the same role**.
Zero 2 W = relay / expendable; Pi 4 = identity-bearing node. Pi 5 would be stronger (crypto
ext, signed boot) but the HaLow SPI bring-up on RP1 is unresolved (`pi5-rp1-bringup.md`).

### Image strategy — one recipe, N builds, runtime profile (decision 2026-09-11)

OpenWrt (and therefore OpenMANET) builds Pi 4 and Zero 2 W as **separate subtargets** —
`bcm2711` (cortex-a72) and `bcm2710` (cortex-a53) — each with its own kernel config and package
architecture. A single binary image for both would mean a custom unified target diverging from
upstream; **not worth the maintenance**. Instead:

1. **One recipe** — the same package list, the same provisioning files (`95-batman-storage`,
   identity hook, ramoops fix), the same golden SOP, built for both subtargets from one branch.
   The kernel config diff for the security chain (`DM_CRYPT`/`DM_VERITY`/`DETECT_HUNG_TASK`…)
   is applied to **both** boards' configs.
2. **Runtime profile by board**: the first-boot hooks read `/proc/device-tree/model` (or
   `compatible`) and select the profile — security model ceiling (above), A/B mode
   (`tryboot_a_b` vs `tryboot.txt`), payload tenants on/off, resource budgets (#81).
3. **Board-specific only where physics forces it**: boot-partition layout for A/B (#88: two boot
   partitions on Pi 4, one on Zero), signed-boot artifacts (Pi 4 only), the DT overlays.

So "does one image fit all hardware?" — **one *source of truth* fits all; one *artifact* per
subtarget.** Release = the set of per-board images built from the same commit, sharing one
SBOM lineage and one signature identity (#73).
