# v1 → v2: how each round-1 finding was handled

Round 1: Reviewer A = REJECT (3 BLOCKER / 10 MAJOR / 10 MINOR), Reviewer B = REJECT (3 BLOCKER / 12 MAJOR / 7 MINOR).
Approach for v2: write the threat model first (`255-threat-model.md`, requirements R1–R21), cut scope, and remove new mechanisms instead of patching them. "Removed" below means the mechanism is no longer decided in this document.
User decision between rounds (2026-11-23): order is v1.6 → 608B bring-up → trust model; 10 × 608B and 4 × HAT on hand.

## Reviewer A

| Finding | Handling in v2 |
|---|---|
| B1 registrar can sign `trust` | Registrar level removed. `trust` accepted only from the PRIMARY anchor key itself (§3.2, R1) |
| B2 no issuer constraint; branch scope unenforceable | Chain shape fixed: anchor → at most one "issuer" certificate → leaf; leaf never issues; issuer signed only by the anchor (§3.3 rules 2–3, R2). No branch notion: squad enrolment goes through ICS accounts (§5.1, §11) |
| B3 `net_state` as bearer object performs first join | Entering a network the node does not hold needs a fresh in-session NET op, as today; bearer objects only update (§3.4, R9) |
| M1 revocation floors lost on enrolment / reset; unbounded CRL | Floors travel in the node certificate, which is bound to the chip's enrolment counter; no valid node certificate → only PRIMARY itself is accepted; fail-open removed. CRL capped at 128 ids + generations (§3.5, R6, R7) |
| M2 +16 window | Removed. 64-bit version; total order (version, then object hash) (§3.4, R12) |
| M3 network not bound to its authority; `inhibit` replay / scope | Each stored network records its authority; only that authority's chain updates it (§3.4, R11). `inhibit` removed from this document (phase 5) |
| M4 SAS join "kept unchanged" contradicts removal of key 8 | Corrected: the three-step flow (dev-only today) is removed in phase 2; ad-hoc cross-authority join is designed in phase 5 under the same "authority recorded at first join by a fresh local op" rule (§3.4, Q5) |
| M5 unit identification key | Removed. One BLE identification key per node, helper-held, provd gets derived values only, fits the existing 6 PSK candidates (§3.6, R14, A7) |
| M6 MAINT = root | Stated (threat model V3). MAINT only by chain length 1 from the anchor, node-scoped (§3.3 rule 3, R3) |
| M7 squad root on the daily host, same master as TAK CA | Root exists only during a ceremony, restored from the mnemonic on an offline machine; ICS holds a separate issuer key (D11, §3.1, R10). Where ICS physically runs → Q4 |
| M8 downgrade / auto-revert | A6 marked ✅. New helper reads the old format and converts only after autocommit; auto-revert leaves the old format intact; in-place downgrade after commit unsupported (§6.2, R18, R19). Missing rows added |
| M9 root roll-over / anchor replacement | One-step "replace PRIMARY"; RECOVERY can only replace PRIMARY and cannot be removed without its own signature; random 128-bit certificate ids (§3.2, §3.3, §6.1, R16) |
| M10 missing resources / lifecycles | §5.1 and §6 extended: node certificate, CRL bodies, network authority record, root password, in-flight update ownership, inventory single writer, phone loss / reinstall, ICS restore |
| m1 signer not bound into signed bytes | Unit id and signer key id are inside the signed content (§3.3, §3.4, A4, R4) |
| m2 attestation over a QR | Station-first challenge, chain over BLE or mutual scan (§6.1) |
| m3 where `auth` is verified | In the helper (§3.3, §3.6, R17) |
| m4 "cannot add outside node" is app-enforced | Stated (threat model R13 residual; §3.4 carries the node certificate hash per member) |
| m5 roster in clear | Accepted and stated; not broadcast over the mesh any more (§3.4) |
| m6 guest "mission epoch" undefined | Guest certificates removed from this document (phase 5) |
| m7 phase 1 → 2 changes identity | Resolved by the new order: 608B first (§4, D12) |
| m8 relay split | Relay removed from the decided scope; bench probe before phase 3 (§3.6) |
| m9 missing negative controls | Threat model §7 lists one per requirement |
| m10 recovery card photo | R16; threat model T7 |
| Wrong citations 1–8 | Fixed in §1 (facts 3, 7, 10, 11) and §5.1 (provd does not read `prov.cbor`) |
| Citation 9 (ICS, external references unverifiable in this worktree) | ICS statements marked ⚠️ "not verified in this repo" (A8, §7.4) |

## Reviewer B

| Finding | Handling in v2 |
|---|---|
| B1 freshness of bearer objects (`net_state`, `inhibit`, `trust`) | `net_state`: R9. `inhibit`: removed. `trust`: after a factory reset the node is unenrolled and enrolment needs the body QR; the floors that matter come with the node certificate bound to the enrolment counter (§3.5) |
| B2 how a second administrator gets the password, member list, ECDH keys | New NET verb: read the current network state and the password re-wrapped to the session; the member list and node ECDH keys are in the state (§3.4) |
| B3 D11 contradicts §3.2 / §3.3; fate of shipped flows | Same as A-M4. Join / remove / update flows are replaced in phase 2; leave stays a NET op (§3.4, §9) |
| M1 +16 strands long-off nodes | Removed (as A-M2) |
| M2 effect of revocation on stored / in-flight state | Revocation affects later verification only; applied state stays; re-key after revoking an administrator (§3.5) |
| M3 one stolen NET certificate reaches every node, partly remotely | No mesh forwarding in this document, so reach = nodes the thief can get near; key needs user authentication per use (R15); limits stated (§7.2, threat model §6) |
| M4 ENROL includes changing the anchor | ENROL removed as a certificate right (D4) |
| M5 unit identification key | Removed (as A-M5) |
| M6 recovery card alone cannot reach nodes; `claim/replay` breaks | Recovery path: scan each node's body QR for a QR-derived PSK, then sign "replace PRIMARY" with the recovery key (§3.6, S2). Enrolment keeps the enroller's signing and encryption public keys as a transient field for `claim/replay` (§3.6) |
| M7 OTA / downgrade; app record migration | As A-M8. No app migration: no external users, bench re-enrols (§6.2) |
| M8 mesh delivery can split the mesh; bat0 listener reachable by bridged hosts | Mesh relay not decided here; no new listener (§3.6, §6.2 dependency row) |
| M9 "members do 0 steps" untrue | Corrected (S4): the member picks their node once; a USE certificate scoped to that node reads and sets its phone Wi-Fi; member PSK removed; status via VIEW (§3.4, §3.6) |
| M10 missing resources and lifecycle rows | As A-M10 |
| M11 phase 1 not self-contained; phase 2 not "only a backend swap" | Phases reordered: 1 = 608B with the upper protocol unchanged; 2 = whole trust model including the channel change and person certificates (§9) |
| M12 ICS links, ICS BLE client, registrar key home | No registrar key. Enrolment is done by the administrator's Batman app signed in with an ICS account, so ICS needs no BLE client (A8). Link choice is ICS-side; this document requires that create / re-key work with no link (§5.2, S8, S9, Q4) |
| MINOR sizes and round trips | Sizes quoted with a ≤ 40-node target per network (§3.4) |
| MINOR attestation flow | §6.1 |
| MINOR app-only expiry is an availability risk | Expiry is optional and not relied on (D8); yearly generation bump is the mechanism (§3.5) |
| MINOR provd `auth` / role model | Verified in the helper (§3.6) |
| MINOR interop trust path | Deferred to phase 5 (U5) |
| MINOR concurrent-admin member-list loss | Total order converges; the losing edit must be re-done — stated as the only multi-writer resource (§5.1) |
| MINOR registrar-revocation impact | No registrar level |

## Not changed

- Direction D1 (one mechanism, two deployments), COSE / CBOR, no clock dependence: both reviewers found them sound.
- ICS-side facts cannot be verified from this repository; they stay ⚠️ until the ICS-side design exists.
