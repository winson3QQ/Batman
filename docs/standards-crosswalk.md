# Standards crosswalk — from the use-case matrix to the implementation spec

Each cell of the CONOPS matrix ([#69](https://github.com/winson3QQ/Batman/issues/69))
— *who/thing × hardware × task* — is governed by a standard. Mapping them gives the
**implementation reference spec**: for each payload/action you know which format or
framework to build to. Certification is deferred (see
[`productization.md`](productization.md)); the point is to **implement to the standard now.**

> ⚠️ Applicability (esp. exact STANAG/MIL-STD numbers) should be confirmed with a
> standards/compliance authority — this is an engineering map, not legal advice.

## By data / action — the "事" (payload)

| Task / payload | Subject(s) | Standard / format to implement to |
|---|---|---|
| **Position / SA (CoT)** | people, things | **Cursor-on-Target** (MITRE schema); TAK protocol; NATO **NFFI / STANAG 4677** (friendly-force info) |
| **Map symbology** | people (COP) | **MIL-STD-2525** (US) / **APP-6** (NATO) |
| **Chat / messaging** | people | TAK **GeoChat** (CoT-based) |
| **Full-motion video** (drone/camera) | things | **STANAG 4609** + **MISB** (ST 0601 KLV metadata) for FMV; **RTP/RTSP**, H.264/265; **ONVIF** for IP cameras |
| **ISR / track data** | things, COP | **STANAG 4676** (ISR tracking) |
| **UAV control/telemetry** | drone | **STANAG 4586** (UCS); **MAVLink** (de-facto); FAA **Remote ID** / Part 107 (US ops) |
| **Sensor telemetry** | sensor | **MQTT** (OASIS); **OGC SensorThings** |
| **SDR / RF survey data** | SDR | **SigMF** (Signal Metadata Format) |
| **File / data package** | people, things | TAK **Data Package** format; MIME |

## By identity & access — the "誰" + policy (#52, #69)

| Concern | Standard |
|---|---|
| **RBAC** | ANSI/INCITS **359** |
| **ABAC** (type=drone, unit, mission, clearance / need-to-know) | NIST **SP 800-162** |
| **Access control (accreditation baseline)** | NIST **SP 800-53** AC family; **SP 800-171** / **CMMC**; **RMF** |
| **Zero Trust** | NIST **SP 800-207** |
| **Machine / human identity (X.509)** | **X.509**; **FIPS 201 / PIV** (human-credential analog); NATO PKI |
| **Enrolment** | **EST** (RFC 7030) / SCEP |
| **Crypto module** | **FIPS 140-2 / 140-3** validated |

## By lifecycle — the "when" (#70)

| Phase | Standard |
|---|---|
| **Provision / enrol** | EST (RFC 7030), FIPS 201 |
| **OTA firmware update** | **SUIT** (IETF, RFC 9019 arch); **TUF / Uptane** (update security) |
| **Software supply chain (SBOM)** | **SPDX** (ISO/IEC 5962) / **CycloneDX**; NTIA minimum elements; **VEX**; EO 14028 |
| **Decommission / secure disposal** | **NIST SP 800-88** (media sanitization) |

## By transport / platform — the fabric (#68)

| Concern | Standard |
|---|---|
| **RF / PHY-MAC** | IEEE **802.11ah** (HaLow); **802.11s** (mesh) |
| **Interop / federation** | TAK federation; **MIP** (Multilateral Interoperability Programme); NFFI |
| **QoS across payloads** | DiffServ (DSCP) |

## By hardware / regulatory — the "硬體"

| Concern | Standard |
|---|---|
| **RF type approval** | **FCC Part 15.247** (US) / **CE RED** (EU) / regional |
| **Ruggedization** | **MIL-STD-810** |
| **Battery shipping** | **UN 38.3** |
| **Supply chain** | **NDAA §889** / FCC Covered List (see #46) |
| **EMC** | FCC Part 15 Class B / CISPR |

## How to use this

1. Take a row of the #69 matrix (e.g. *drone → node+camera → publish FMV*).
2. Read across: implement **STANAG 4609 + MISB KLV over RTP**, identity via **X.509 with an ABAC `type=drone` attribute (SP 800-162)**, transport over **802.11ah/s**, lifecycle via **EST enrol → SUIT OTA → 800-88 disposal**.
3. That set of standards **is the spec** for that use-case — build to it, defer the paperwork.
