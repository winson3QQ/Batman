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

| # | Gate | How |
|---|---|---|
| 1 | **Traceability / SoT** | issue per change; PR `Closes/Refs #N`; no direct-to-main |
| 2 | **pre-commit** | `pre-commit install`; shellcheck, **LF line-endings**, secrets (gitleaks), large-file guard |
| 3 | **CI** | `.github/workflows/ci.yml` — shellcheck + LF check + Trivy fs scan + SBOM |
| 4 | **SBOM + CVE** | CycloneDX SBOM (Syft) as a CI artifact; Trivy CVE scan; triage / VEX; gate criticals (#45) |
| 5 | **Smoke test** | image change → flash → boot → mesh peers → key services up |
| 6 | **Dogfood** | runtime change → run on real hardware (manet01/manet02) before release |
| 7 | **Signed artifacts** | sign image + SBOM (cosign); provenance — see verified-boot #74 |
| 8 | **Supply-chain red line** | no China-origin deps (#46) |
| 9 | **Version discipline** | image versioning (milestone = image release), changelog |

## Local setup

```bash
pipx install pre-commit      # or: pip install pre-commit
pre-commit install           # runs on every commit
pre-commit run --all-files   # check everything now
```

## Notes

- **Line endings:** `.gitattributes` forces LF; CI rejects CRLF in scripts. This exists
  because a CRLF shebang once gave `sh: not found` on a node.
- CI security is **informational first** (Trivy `exit-code: 0`); flip to blocking once
  the backlog of findings is triaged (the first FTS-container scan will light up — old
  pinned `cryptography` etc., #45).
