<!-- Dev-infra release gates — see #73 and docs/dev-process.md -->

## What & why

<!-- one-paragraph summary -->

Closes #<!-- issue number — every PR references its issue (SoT) -->

## Validated (test results — what was run, on which node, outputs/numbers; mark ⚠️ simulated / ❌ not done)

<!-- table or raw output; docs-only PRs: "docs only, n/a" -->

## Review

<!-- Level per docs/design/REVIEW.md § Review level. Fill every line; write "n/a" where the level does not need it. -->
- **Level:** L0 docs / L1 presentation or rule-file sync / L2 normal / L3 critical — <!-- and why; which L3 trigger, if any -->
- **Design review:** <!-- doc, reviewers × rounds, final verdicts, where saved (docs/design/<issue>-reviews/); L0/L1: n/a -->
- **Code review:** <!-- /code-review medium (L1) or high (L2, L3): findings and what was done about each; "none" is a valid answer -->
- **Security review:** <!-- /security-review (L3, always): findings and what was done; L0–L2: n/a -->

## Release-gate checklist
- [ ] Branch off `main`; this PR **references the issue** (`Closes/Refs #N`)
- [ ] **Validated** section filled (dogfood on real hardware when available); **Review** section filled — gate 12
- [ ] `pre-commit` passes (shellcheck, LF line-endings, secrets)
- [ ] CI green (lint + security scan)
- [ ] **SBOM / CVE** reviewed — no unresolved criticals (VEX-suppress with a reason) — #45
- [ ] **Smoke test** (flash → boot → mesh peers → key services up) — if image-affecting
- [ ] **Dogfood** on real hardware (manet01 / manet02) — if runtime-affecting
- [ ] No **China-origin** deps added (#46)
- [ ] Version / changelog updated — if release-affecting
