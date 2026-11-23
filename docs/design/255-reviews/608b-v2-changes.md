# 608B configuration v1 → v2: handling of review findings

Round: Reviewer A (review-608b-A.md) = REJECT 2 / 6 / 12; Reviewer B Part 1 (review-v3-B.md) = REJECT 1 / 7 / 11.
Approach: remove, do not add. Every BLOCKER was a mechanism added in v1 for a user wish; all three are removed.

| Finding | Handling in v2 |
|---|---|
| A-B1 claim-slot rewrite contradicts NoMac (cryptoauthlib host model) | QR rotation removed; claim secret = one never-write slot (5); fixed QR stated as a limitation and put to the user (§6.2, Q1) |
| A-B2 / B-C-B1 ReqAuth binding (replayable, brick by any bus master, TempKey survival unknown) | Removed; key slots `0x0073`; slots 3 / 14 never-write (§6.3) |
| A-M1 verifier under-specified; host-supplied fields | Verifier rebuilds the 55-byte message from constants, never parses the node's; `sig_static` / `sig_ecdh` deleted (§2); E7 lists the bypass attempts |
| A-M2 experiments: order, vacuous passes, budget | Three sacrificial chips: variant chip, final chip, repeat chip; every negative test has a positive control; E0 bus inventory; data lock writes every non-private slot and OTP (§5, §8) |
| A-M3 ChipOptions bit 3 | Set (`0x0008`), reason stated (§4.1); E16 |
| A-M4 / B-C-M7 counter claims | Restated as "cannot go down", increment before commit, app nonce, ⚠️ on signing the counter, fallback wording (§6.5, E11) |
| A-M5 / B-C-M1 no ownership, contracts, lifecycle | §7.1–7.3 added |
| A-M6 C1 over-claims | C1 restated; generation rests on the factory (§1, §6.1) |
| B-C-M2 file backend / first boot / bench conversion | Production images have no file backend; no in-place file→chip upgrade; bench re-provisioning steps (§7.3, §7.4, §9-4) |
| B-C-M3 QR replacement orphans units | Removed (as A-B1) |
| B-C-M4 chip-silent state latches; worse than today | Not latched (re-try at each login attempt); loss of management put to the user (§6.7, Q2) |
| B-C-M5 option for slots 3 / 6 not exercisable in the field | Options removed (§6.3, §6.4) |
| B-C-M6 phase-1 scope | §9 lists node_cert, trust gate, claim proof with chip serial, offline flows, dev root custody; field build still rejects all nodes |
| A-m1 / A-m2 spare and reserved slots | Never-write (§3, C10) |
| A-m3 IO protection half-enabled | Off; slot 6 unused (§6.4) |
| A-m4 device_id vs chip serial | Split stated (§2, §9-3) |
| A-m5 node_cert change understated | §9-1 |
| A-m6 ReqRandom consequences | §4.2 note |
| A-m7 current-slot marker | Gone with the second claim slot |
| A-m8 Appendix A items 8, 12, 17, 3 | §6.8 (trust anchor: nothing protects it before secure boot), §6.3 (no key-disable), §6.2 (no host-usable value from the printed secret), §7.3 (no resale privacy) |
| A-m9 slot 8 size | E15 with a size criterion |
| A-m10 the artefact is the 128-byte image | §4 header, E1 |
| A-m11 wording of bytes 52–67, 84–85 | §4.1 |
| A-m12 factory exposure | §5 last paragraph |
| B-C-m1 §5.5 wrong bullet | Section removed with the binding |
| B-C-m2 / m3 experiment order with ReqAuth | Moot |
| B other config MINORs | Folded into §7 and §9 where they still apply |
