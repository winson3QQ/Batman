# tests/keys — TEST release keys (public points only)

These are the harness's **test** release keys (254-h4-harness §8.1; 254-p3-impl §3.7.1). They stand in for the
production root R and signing key K_i so the harness can sign payloads exactly the way a release build does.

| file | key | role |
|---|---|---|
| `T.pub` | test root T | signs endorsements E (`batman/relkey`) |
| `K_test.pub` | test signing key K_test | signs release objects S (`batman/release`); endorsed by T |

Format: one line, the 65-byte uncompressed SEC1 point (P-256) as hex.

**Derivation.** There is no private-key file. Each private scalar is derived from a fixed name by
`tests/tools/peer/netobj._vector_key(name)` = `SHA-256("batman-test-vector/" + name) mod (n-1) + 1`, with the names
`release-root-T`, `release-key-K_test` (and `release-key-other`, the un-endorsed key used for negative objects). Anyone
can recompute them: `python tests/tools/peer/signrel.py --write-pubs <dir>` regenerates these files, and
`signrel.py --selftest` asserts the committed files equal the derived keys.

**Trust.** T is trusted only by a **bench build** (`build-board.sh --bench`: `BATMAN_BENCH_TRUST=T` in the stamp; a
prov_test image built with `--bench` too) — bench nodes such as 02 / 04, never released. Ordinary `wsl` / `ci` images
carry no root key at all (the app update answers reason 24); a release image carries R and never T; the release gate
asserts the image does not carry it (254-p3-impl §3.7.1). Treat anything signed under T as a bench artifact.
