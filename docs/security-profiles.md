# Per-tenant security profiles (#153)

> **Self-assessed posture, NOT certified.** Citing a control (CIS / PSS / NIST 800-190) records our *intent and design*; it is not a third-party assessment. Formal certification (FedRAMP/RMF, Common Criteria, FIPS 140-3) has external gatekeepers and is tracked separately at #93. Every claim of `implemented` here must carry evidence and be kept honest by the drift-check (§5).

The node is a multi-app payload host (#68). This file is the **spec**; each app carries its own `deploy/<app>/profile.yaml`. It is *not* the enforcement engine — enforcement is `run.sh` flags (#98), local admission (#151), and attestation (#97). SoT: #75.

## 1. What a profile is
One `deploy/<app>/profile.yaml` per containerized payload. It separates **values** (machine-readable, consumed by run.sh/#98 and admission/#151) from **assessment metadata** (per-axis control citation + self-assessed status + evidence, consumed by the compliance rollup/#93). This split (F8) means #151 can sum `resources.cpus`/`memory` without parsing prose.

```yaml
tenant: <name>
archetype: network-service | hardware-payload
co_scheduled_with: [<other tenant>]      # apps sharing a netns / loopback (R7); optional
values:                                   # machine-readable, enforcement consumes these
  network:  {mode: host|bridged}
  user:     {run_as: <uid> | root}
  no_new_privileges: true|false
  caps:     {drop: [ALL], add: []}
  rootfs:   {read_only: true|false, tmpfs: [<path>, ...]}
  resources:{cpus: <float>, memory: <bytes|MiB>, pids: <int>}
  devices:  [<--device spec>, ...]        # [] for network-service
  seccomp:  {profile: default|<file>}
  privileged: false
  docker_socket_mounted: false
  secrets:  [{name, delivery: env|file|store, exposure}]   # F5
assessment:                               # per-axis; compliance rollup consumes these
  <axis>: {control: "<std §>", status: implemented|planned|blocked:#N|na, evidence: "<ref>"}
exceptions:                               # any axis that cannot meet the target level
  - {axis, reason, compensating_control, status}
target: {level: PSS-Baseline|PSS-Restricted, note: "rollup reports N/M axes, never 'level achieved' (F9)"}
```

## 2. Archetypes (a project grouping — each control still cites a real standard, the *grouping* is not itself a standard)
- **network-service** (FTS, fts-ui, MQTT, TAK-bridge, EMS collector) → target **PSS Restricted**; `network=host` only as a documented, compensated exception.
- **hardware-payload** (SDR/camera/drone/sensor — #68 "things") → target **Restricted + a minimal `--device` grant**; cannot be pure-Restricted (must reach `/dev`). **Blocked on #109** — the current kernel has no `CONFIG_CGROUP_DEVICE`, so device-cgroup enforcement is not buildable. Template only; no on-node app yet.

## 3. Standards mapping (corrected citations)
| Axis | Control | Standard |
|---|---|---|
| user (non-root) | run as non-root UID | CIS Docker 4.1 · PSS Restricted `runAsNonRoot` |
| no_new_privileges | `--security-opt=no-new-privileges` | CIS Docker 5.25 · PSS Restricted `allowPrivilegeEscalation=false` |
| caps | `--cap-drop=ALL` + minimal add | CIS Docker 5.3 · PSS Restricted `capabilities` |
| rootfs | `--read-only` + tmpfs | CIS Docker 5.12 |
| resources.cpus | `--cpus` (CFS hard quota — **note:** CIS 5.11 documents `--cpu-shares`, a *relative weight*; we use a hard cap) | CIS Docker 5.11 (adapted) · NIST SP 800-190 §4.4.2 |
| resources.memory | `--memory` | CIS Docker 5.10 · NIST SP 800-190 §4.4.2 |
| resources.pids | `--pids-limit` | CIS Docker 5.28 · NIST SP 800-190 §4.4.2 |
| network | net namespace / isolation | NIST SP 800-190 §4.4.2 (Container runtime countermeasures) |
| seccomp | default profile, not `unconfined` | CIS Docker 5.21 |
| privileged | `--privileged=false` | CIS Docker 5.4 · PSS Baseline |
| docker_socket | socket not mounted | CIS Docker 5.31 |
| secrets | no secret in image/env where avoidable | NIST SP 800-190 §4.3.4 / §3.2.2 |
| devices | minimal `--device` | OCI runtime-spec `linux.devices` · (k8s Device-Plugins pattern, for reference) |

**PSS is a Kubernetes-native ladder; this node runs plain docker with no PSS admission controller.** PSS is used here only as the level vocabulary, realised via `docker run` flags. Host-network fails PSS **Baseline** (`hostNetwork=false`), so an app on host-net does not "achieve Baseline" on that axis — the exception mechanism records it explicitly (F9).

## 4. Kernel/runtime ceiling (verified on-node 2026-09-15, manet01/02)
Enforceable **now (v1.1, current image)**: seccomp · cap-drop · read-only · non-root · no-new-privileges · `--cpus` · `--pids-limit` · **`--memory`** (needs dropping `cgroup_disable=memory` from the golden cmdline — `CONFIG_MEMCG=y` is compiled). Gated on **#109 (v2.0)**: AppArmor/SELinux LSM (none active today) · device-cgroup (`CONFIG_CGROUP_DEVICE` not compiled → the hardware-payload archetype).

## 5. Drift-check contract (R6 — the assert that keeps `implemented` honest; implemented in #98)
`status: implemented` is only permitted for an axis once this assert exists and passes. Map `docker inspect` → axis:
| Axis | `docker inspect` field | implemented iff |
|---|---|---|
| user | `.Config.User` | non-empty / matches `values.user.run_as` |
| no_new_privileges | `.HostConfig.SecurityOpt[]` | contains `no-new-privileges` |
| caps | `.HostConfig.CapDrop` / `CapAdd` | Drop=[ALL], Add ⊆ values |
| rootfs | `.HostConfig.ReadonlyRootfs` | true |
| resources | `.HostConfig.NanoCpus`/`Memory`/`PidsLimit` | all non-zero, = values |
| privileged | `.HostConfig.Privileged` | false |
| seccomp | `.HostConfig.SecurityOpt[]` | not `seccomp=unconfined` |
Runs in `deploy/<app>/functional-test.sh` or an on-node assert (#98). Until it exists, axes stay `planned`.

## 6. Rollup (compliance evidence for #93)
Report per app: `N/M axes implemented-with-evidence`, list `planned`/`blocked` with their gating issue. **Never** emit "PSS-Restricted achieved". This file + the per-app profiles + the SBOM/CVE gate (#45) + `threat-model.md` are the self-assessed package that grows per image version.
