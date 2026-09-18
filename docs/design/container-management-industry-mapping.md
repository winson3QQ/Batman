# Container-app management — mapping to industry standards

**Purpose.** Batman runs payload apps (TAK server, and future drone/camera/SDR/sensor tenants — #68) as Docker containers on an OpenWrt edge node. We are not inventing a management model; we are hand-rolling a resource-constrained version of established industry practice. This doc maps each Batman artifact back to the standard it mirrors, so the design stays auditable and the gaps stay honest.

**Load-bearing principle (why the mapping splits in two).** Container-app management is not one SOP — it is a stack of standards per *concern*, and those concerns fall into two classes:

- **Generic runtime confinement** — uniform across every app, profile-driven: cap-drop, non-root, resource limits, read-only rootfs, no-new-privileges, restart enforcement. Industry owns this with the **Pod Security Standards / CIS Benchmark / NIST 800-190** stack.
- **App-internal operations** — inherently per-app: OTS's RabbitMQ queue lifecycle, Postgres vacuum, a camera's device grant. Industry owns this with the **Operator pattern** (or the app's own config). It must **not** leak into the generic framework (see #171 — the reverted blanket queue policy was exactly this leak).

Batman's own split — `profile.yaml` (generic) vs each app's `deploy/<app>/` config (app-specific) — is this same line.

## The five concern layers

### 1. Management plane — declarative desired-state + a reconciler
| Industry | Batman today | Status |
|---|---|---|
| Kubernetes (Deployment/Pod + controller reconcile); edge: Podman **Quadlet**, k3s, Nomad | per-app `deploy/<app>/run.sh` + a procd guardian (`batman-ots.init`) | **home-grown, not yet declarative.** The industry pattern is desired-state reconciled by a supervisor, not a hand-run script. This is the main gap — tracked as **#156** (init-owned runtime owner: procd/Quadlet enforces the flags every boot/restart so a hand-run `docker run` can't bypass hardening). |

*Why not just run k8s:* OpenWrt uses **procd, not systemd** (Quadlet isn't native), and k3s is too heavy for a Pi-class edge node. So we mirror the *shape* (declarative + reconciler) in procd, and keep it mappable to the standard.

### 2. Security hardening — the auditable SOP layer
| Industry | Batman | Status |
|---|---|---|
| **NIST SP 800-190** (Application Container Security Guide) — the authoritative reference | cited as the confinement rationale in `docs/security-profiles.md` (#153) | referenced |
| **CIS Docker / Kubernetes Benchmark** — checklist SOP, automatable (`docker-bench-security`, kube-bench) | not yet run as a formal self-assessment | **gap — highest-value next step** (feeds #93) |
| **K8s Pod Security Standards** (Privileged / Baseline / **Restricted**) — graduated scale | adopted as vocabulary; profiles target Restricted (network-service) / Restricted+device-grant (hardware-payload) — #153 | adopted as the scale |
| **DISA STIG (Container SRG / K8s STIG) + Iron Bank** — defense ceiling | out of scope now; the ceiling for a future assurance track (#93) | future |

Reachable on the current image (verified on-node): cap-drop=ALL, no-new-privileges, non-root, `--pids`, `--cpus`, `--memory` (kernel has `MEMCG=y`; only the golden cmdline `cgroup_disable=memory` blocked it — dropped). Deferred to v2.0 (kernel gate #109): **AppArmor/SELinux LSM + device-cgroup** (`CONFIG_CGROUP_DEVICE`). Remaining v1.1 axis: **read-only rootfs** (#98 — Postgres is already ready; the Python tenants need `PYTHONDONTWRITEBYTECODE=1` + tmpfs, per the `docker diff` audit).

### 3. App design — is the app even manageable?
| Industry | Batman | Status |
|---|---|---|
| **12-Factor App** (logs→stdout, config→env, stateless, disposable) + **OCI** image/runtime specs | used as the yardstick that flagged FTS/OTS writing logs into their package dir (violates Factor XI) — #158 | applied as a gate; some tenants are not cloud-native and get a documented exception + remediation ladder |

12-Factor is why a tenant can *block* generic hardening (a non-12-Factor app that writes into its rootfs breaks read-only). The industry remedy ladder — fix upstream → adapt packaging (entrypoint symlink / vendored patch) → documented exception (POA&M) → sandbox harder → replace — is exactly the ladder recorded in #158.

### 4. Supply chain — image provenance & integrity
| Industry | Batman | Status |
|---|---|---|
| **Sigstore / cosign** signing | cosign-signed images in CI | **have it** |
| **SBOM** (Syft, SPDX/CycloneDX) + vuln scan (**Trivy / Grype / Clair**) | grype scan as a blocking CI gate; SBOM/CVE gate #45 | **have it** |
| **SLSA** build provenance; distroless / Chainguard-Wolfi minimal bases | not adopted | future (feeds #93) |

### 5. App-specific operations — the Operator layer
| Industry | Batman | Status |
|---|---|---|
| **Operator pattern** (an app-specific controller encodes that app's ops knowledge — e.g. a RabbitMQ/Postgres operator manages its own internals) | OTS-specific concerns (RabbitMQ queue bounding #171, cert lifecycle) live in `deploy/ots/` config, **not** in the generic profile | correct separation; keep it there |

The #171 lesson is the canonical example: queue lifecycle is an *app-internal* concern → it belongs in OTS's own config (an Operator would own it), never as a cluster-wide `.*` policy.

## Batman's position, honestly
- We are **mirroring** the industry stack at edge-appropriate weight, not running the reference implementations. Claims are **self-assessed, not certified** — formal certification (FedRAMP / Common Criteria / FIPS) is a separate track (#93).
- The clean mental model (matches how the codebase is already split):
  - **generic confinement** = PSS/CIS/800-190 → `profile.yaml` (uniform, framework)
  - **app-specific ops** = Operator/app-config → `deploy/<app>/` (per-app)
  - **management plane** = declarative reconciler → #156 (the current gap)
- **Highest-value next step:** run the **CIS Docker Benchmark** as a self-assessment (`docker-bench-security`) and turn its findings into the `profile.yaml` gap list + compliance posture for #93 — this is the closest thing to a ready-made, auditable container SOP.

## References
- NIST SP 800-190 — Application Container Security Guide
- CIS Docker Benchmark; CIS Kubernetes Benchmark
- Kubernetes Pod Security Standards (Privileged / Baseline / Restricted)
- DISA Container Platform SRG; Kubernetes STIG; DoD Iron Bank
- NSA/CISA Kubernetes Hardening Guidance
- The Twelve-Factor App; OCI Image & Runtime Specifications
- Sigstore/cosign; SLSA; SPDX / CycloneDX SBOM
- Kubernetes Operator pattern
- Internal: `docs/security-profiles.md` (#153), `docs/design/98-container-hardening.md` (#98), `docs/design/payload-framework.md` (#178); issues #68 #93 #109 #156 #158 #171
