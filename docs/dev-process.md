# Dev process — per-version release gates

The Definition of Done for every change. Epic: **#73**. Modelled on ICS_COMMAND's
setup. The [SoT root issue is **#75**](https://github.com/winson3QQ/Batman/issues/75).

## Flow

1. **Issue first (SoT).** Work is tracked by a GitHub issue; it's the source of truth.
2. **Branch** off `main` — `type/short-desc` (e.g. `infra/pre-commit`, `fix/spi-timeout`).
3. **Commit** with the co-author trailer; small, reviewable.
4. **PR** referencing the issue (`Closes/Refs #N`). The PR template's checklist is the gate.
5. **CI** must be green. **Merge** to `main` (no direct pushes). Delete the branch.

## Gates (what every change must pass)

| # | Gate | How | State |
|---|---|---|---|
| 1 | **Traceability / SoT** | issue per change; PR `Closes/Refs #N`; no direct-to-main | ✅ |
| 2 | **pre-commit** | shellcheck, **LF line-endings**, secrets (gitleaks), large-file guard | partial |
| 3 | **CI lint** | `ci.yml` — shellcheck + LF check (blocking) | ✅ |
| 4 | **SBOM + CVE (deps)** | `ci.yml` — **grype** on `requirements.txt` (`--fail-on critical`, `.grype.yaml` VEX) + CycloneDX SBOM (Syft); NVD-authoritative OWASP Dependency-Check on release tags (`release-scan.yml`) | ✅ #45 |
| 5 | **Image build + scan** | `build-fts-image.yml` — off-node arm64 build (#85), **grype image scan** (sees base-OS, informational until #83 base swap), image SBOM | ✅ |
| 6 | **Functional gate** | `deploy/fts/functional-test.sh` in CI — runs the image under QEMU, exercises the changed paths with **independent oracles** (forced cert-gen, openssl-verify, mTLS handshake, no-cert negative control, CoT); build-pass ≠ works | ✅ |
| 7 | **Smoke test** | image change → flash → boot → mesh peers → key services up | manual |
| 8 | **Dogfood** | runtime change → run on real hardware (manet01/manet02) before release | ✅ manual |
| 9 | **Signed artifacts + provenance** | sign image + SBOM (cosign/Sigstore); SLSA provenance — see §Signing (#13) + verified-boot #74 | ❌ pending |
| 10 | **Supply-chain red line** | no China-origin deps (#46); build off-node from pinned lock | ✅ |
| 11 | **Version discipline** | image versioning (milestone = image release), changelog, rollback tag kept | ✅ |

## Signing & provenance identity (#13, gate 9)

The missing link that makes "only reviewed/signed code runs" (#74) real. Spec:

- **What is signed:** the flashable image, the container images (FTS + payload), the SBOM,
  and the OTA update bundles (#89). Signatures + SLSA provenance attached to each artifact.
- **Signing identity:** a project signing key (or per-role keys — build/release). **Private
  key never on a node**; held in the CI/release environment's secret store or an HSM/secure
  element, rotated on a schedule (#70 lifecycle). Public trust anchor burned into the node's
  verified-boot chain (#74 OTP) + the OTA verifier.
- **Tooling (industry-standard, see standards-crosswalk.md):** **cosign/Sigstore** for
  container + blob signing, **TUF/Notation** for the update trust model, **in-toto/SLSA** for
  build provenance, **SUIT** (RFC 9019) for the OTA manifest.
- **Verification points:** CI verifies provenance before publishing; the node's OTA path
  verifies the signature against the trust anchor **before** writing the inactive slot (#89);
  admission verifies payload-image signatures before running a tenant (#97).
- **Key management lifecycle:** generation → distribution of the public anchor →
  rotation/re-sign → revocation of a compromised key (offline-mesh-aware, ties #95/#49).

Threat closed: "scp a file and it runs" / an unsigned image loaded to a node — the whole
point of the verified-boot epic (#74). Until this lands, gate 9 is **not** met and prod-mode
lockdown can't be claimed.

## Release cut (milestone = flashable image)

1. All gates green on `main`. 2. Tag `vX.Y.Z` → `release-scan.yml` (NVD-authoritative CVE +
release SBOM) + signed artifacts. 3. Image + SBOM + provenance published; rollback tag kept.
4. Changelog from the issues closed since the last tag.

## Local setup

```bash
pipx install pre-commit      # or: pip install pre-commit
pre-commit install           # runs on every commit
pre-commit run --all-files   # check everything now
```

## Notes

- **Line endings:** `.gitattributes` forces LF; CI rejects CRLF in scripts. This exists
  because a CRLF shebang once gave `sh: not found` on a node.
- CI CVE scanning uses **grype** (not Trivy — the pin was unresolvable). The `requirements.txt`
  gate **blocks on Critical** and is now Critical-clean on the merits (`.grype.yaml` VEX empty).
  The **image** grype scan (`build-fts-image.yml`) stays informational while the Debian base
  Critical backlog (#83) is worked; flip it to blocking after the base swap.
- **Build off-node** (#85): the field node's storage can't hold a non-trivial build; images
  are built in CI (QEMU/buildx) and `docker load`ed onto the node. See `deploy/fts/README.md`.
