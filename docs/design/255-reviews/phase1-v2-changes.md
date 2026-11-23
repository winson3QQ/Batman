# Phase-1 implementation v1 → v2

Round 1 on v1: Reviewer A (review-phase1-A.md) = REJECT 1 / 7 / 14; Reviewer B (review-phase1-B.md) = REJECT 2 / 10 / 12.
Agreed with the user before revising: drop chip endorsements; host-generated claim secret; no automatic file fallback; keep the identity-mismatch freeze; one chip owner at a time; file profile proves with the cert key; `id/prove` outside the global limiter; K15 measurement to the user; order H0 → PR 1 → driver core + se-lab → PR 2 / PR 3 after the chip results.

| Finding | Handling in v2 |
|---|---|
| A-B1 field 8 unbound | Field 8 and 9 removed; proof key always derived from the verified cert (P4, §3.2); negative vector §3.4 |
| B-B1 PR 1 not a refactor | PR 1 narrowed and done (#379); protocol changes in PR 3; harness in H0 |
| B-B2 claim secret path | H0: `MAC` / `MACR` lines answered on the host; canaries on the host (§4.1) |
| A-M1 shared rate limit | P5; contention test (§4.2) |
| A-M2 K20 waived; marker dropped; variant not visible; downgrade | P2/P3; §2.8 version marker and release gate; per board; downgrade row (§7); remaining gap put to the user (Q3) |
| A-M3 / B-M3 boot reconciliation | §2.3 per-rc column; socket not opened until identity ready; retry before listen |
| A-M4 HAT swap auto-void | Freeze, as today (§2.3) |
| A-M5 / B-M8 multiple chip writers | Chip lock + in-process sequencer (§2.2); se-lab only on the rig with the daemon stopped and an SN allow-list (config §8.0) |
| A-M6 / B-M5 burn single points of failure | Host secret via stdin before write; cert key check before slot 8; refuse on trial; 0600 host files (§2.5, config §5) |
| A-M7 /dev/i2c-1 access | lstat check + hotplug rule + EACCES test (§2.2, §2.7, §4.2) |
| B-M1 PR order vs E7 / E8 | §9: H0 → PR 1 → PR D → chip → PR 2 / PR 3 with stated E dependencies; E7 / E11 no longer needed |
| B-M2 build flag integration | §2.8 |
| B-M4 lifecycle rows | §7 rewritten |
| B-M6 fake chip / regular suite | Stateful fake; `se-fail` prov_test seam as DV units (§4.2) |
| B-M7 / A-m12 K15 | Measurement plan (§4.2); Q5 |
| B-M9 inventory | 47 files + ~25 units noted; H0 re-greps; listed tools added (§4.1) |
| B-M10 flag day | P7: dual-version tools in H0; PR 3 merges after v1.6; 02/04 need no reclaim |
| A-m1 low-s | P9; vector |
| A-m2 free label | Fixed enum (§2.1) |
| A-m3 / B-m10 provd oracle | §8 residual |
| A-m4 dev-root attests custody only | config §2; §8 |
| A-m5 / B-m4 verify_offline | §3.2; Q4 |
| A-m6 PersistPending | §3.2 |
| A-m7 negative vectors | §3.4 (adapted: no endorsements) |
| A-m8 / B-m3 counter | Removed from Identity; record field unchanged |
| A-m9 identity-dir writers | §6; sha list over 4 files (§2.3) |
| A-m10 lifecycle rows | §7 |
| A-m11 test code in release | §2.8 release gate; se-lab SN allow-list |
| A-m13 custody | config §5.4 |
| A-m14 s_node | Kept; existing check that it equals the handshake rs (`nodecert.rs:104`) |
| B-m1 identity-info | Dropped |
| B-m2 retry contradiction | One rule: retry before listen; after listen, retry per request (§2.3–2.4) |
| B-m5 boot_id poll | Kept (§2.6) |
| B-m6 negative controls for chip image | Named mutant (§4.2) |
| B-m7 image contents | §2.8 |
| B-m8 dev-root loss scraps chips | Slot 8 not locked; re-run S3 (config §5.3) |
| B-m9 spare Pi | Dedicated rig, model confirmed at soldering (config §6) |
| B-m11 fakeMsg2 length | §3.4 |
| B-m12 deferred items to #255 checklist | Will be posted to #255 with this revision |
| Wrong facts (both) | server.go:16 removed; counter location fixed; "no new mechanism" claim removed; external-sign digest stated (§2.1) |
