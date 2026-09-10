<!-- Dev-infra release gates — see #73 and docs/dev-process.md -->

## What & why

<!-- one-paragraph summary -->

Closes #<!-- issue number — every PR references its issue (SoT) -->

## Release-gate checklist
- [ ] Branch off `main`; this PR **references the issue** (`Closes/Refs #N`)
- [ ] `pre-commit` passes (shellcheck, LF line-endings, secrets)
- [ ] CI green (lint + security scan)
- [ ] **SBOM / CVE** reviewed — no unresolved criticals (VEX-suppress with a reason) — #45
- [ ] **Smoke test** (flash → boot → mesh peers → key services up) — if image-affecting
- [ ] **Dogfood** on real hardware (manet01 / manet02) — if runtime-affecting
- [ ] No **China-origin** deps added (#46)
- [ ] Version / changelog updated — if release-affecting
