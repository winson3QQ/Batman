# #156 runtime owner — field-worthy reframe & decision record

**Status:** DECIDED (reviewed — SOUND-WITH-CAVEATS, justification corrected per §8) — **#156 v1.1 = "Way 2" (trusted-launcher + detection + resource-correction + surface); confinement-conformance admission (authz) folded into #97's scope.** · **SoT:** #75 · **Milestone:** v1.1 DEV golden (dev-now)
**History:** `156-runtime-owner.md` (Phase 1 alarm-only, shipped PR #188) · `156-phase2-correction.md` (destructive rebuild-on-drift, REJECTED in review). This doc reset the target from "mergeable" to "handles the field," did the threat-model analysis, and records the decision.

## TL;DR
The alarm-only endpoint we had drifted toward does not *own* the runtime (a local log reaches no one on an unattended mesh-only node). Reframing on the **field**, then doing the **threat-model + roadmap analysis** (and an independent adversarial review of *this decision* — see §8), the outcome:
- The container-confinement-drift threat (#156) meaningfully bites against *our own accidental bad deploy* (T2/T3) and future untrusted multi-tenant (F). Against a capable adversary (physical capture, supply-chain, host-root) an authz plugin is removed alongside confinement — small-but-nonzero defence-in-depth only (§3).
- A confinement-authz plugin *does* structurally prevent T3 at runtime, and its on-node harness (procd service, unix socket, arm64 build, fail-open posture) is exactly what #97's admission reuses — confinement-conformance is an **additive** predicate to #97's provenance/authorization, not a throwaway. It is deferred **not** because it's worthless but because of (a) the **availability tension** (a hot-path plugin that can fail-close on an unattended node, where availability is the top field constraint) and (b) **trigger timing** — the T3 amplifier (remote OTA #116) is **v4.0 Fleet**, gated on verified boot #74; in v1.1 app-change is manual/USB, so "a bad OTA hits many nodes" barely exists yet.
- Therefore **#156 v1.1 = Way 2** (detection + resource-correction + surface + `no-new-privileges` default; no hot-path authz component). **Confinement-conformance admission is folded into #97's scope** (amended 2026-09-19 — #97 previously = provenance + authorization only, which does **not** reject a create missing `--cap-drop`/`--user`/`--read-only`; that gap is now explicitly #97's), to co-land with the OTA amplifier and #74. The v1.1 **accepted residual** is named in §5.

---

## 1. Field operating context (what the design must survive)
- **Unattended** — no operator at a keyboard on the node; nobody types `docker rm && docker run`.
- **Mesh-only backhaul** — when the mesh partitions, nothing local reaches an operator (#142).
- **Availability matters** — the payload (OTS/TAK) must keep running; a "safety" mechanism that can brick the node or kill the payload is a net loss in the field.
- **Long-lived, gets updated** — OTA (#116), first-boot provisioning (#110), in-field app-swap (#151).

## 2. Yardstick — real field triggers of confinement drift (a keyboard operator is NOT one)
| # | Trigger | Reality |
|---|---|---|
| T1 | Crash / OOM restart | docker `--restart` re-runs the *same* hardened container. **Not a real gap** (verified). |
| T2 | In-field app-swap (#151) | a *new* container launched; unhardened only if the swap path skips the profile. |
| T3 | Bad OTA / provisioning | a wrong/edited `run.sh` or profile → the launcher itself creates unhardened containers. |
| T4 | `docker update` loosening | resource axes only (security axes are create-time-fixed, can't be loosened live). Correctable in place. |
| T5 | Compromised payload | container escape → mostly **#97's threat** (identity/admission). |

**T1 handled; T4 resource-only + in-place-correctable; T2/T3 are the real confinement gap (a *new* create with wrong flags); T5 → #97.**

## 3. Threat-model analysis — WHO can un-enforce confinement, and does authz help?
Confinement (#98) exists to **contain the blast-radius of a compromised payload** (a TAK/OTS exploit or CVE puts an attacker *inside* a container; non-root / cap-drop / read-only / no-socket stop them escaping to host / mesh control plane / other tenants). It is not a defense against physical capture or network attackers reaching the node — the project's threat model (`docs/threat-model.md`) already owns those via PKI/admission/detection/revocation.

| Actor / scenario | Can it cause confinement drift? | Does authz stop it? | Real defense |
|---|---|---|---|
| **A. Remote payload compromise** (the thing confinement contains) | **Not while confinement holds** — no socket / non-root / cap-drop → can't reach dockerd. **But a container-escape CVE (runc/cgroup/kernel) breaks that**; post-escape to host it *can* create naked containers. | small-but-nonzero: an authz plugin *would* reject a post-escape naked create — but on THIS node the only path to dockerd is a full host escape (no socket exposed/mounted), where authz is removed with confinement anyway | **#98 having confinement** (raises the escape bar); #156 keeps it applied |
| **B. Our own bad deploy** (bad OTA/provision creates naked containers — the *accidental* T2/T3) | **Yes**, and over a long-lived fleet it *will* happen | ✅ yes | **single hardened launcher + CI gate (`check-hardening-env`, exists) + HIL (#113) + Phase-1 detection surfacing it** |
| **C. Partial host compromise** (socket-reachable, but no daemon-control) | Yes | ✅ small-but-nonzero — the honest boundary is **socket-reachability vs daemon-control** (an escape can yield socket access without the ability to restart/reconfigure dockerd); there authz *does* block a naked create. Value is small **for this node** because it exposes no socket. | signed images #115/#116; #97 admission |
| **D. Physical capture** (empty root pw #137 / pull SD / serial → host root) | Yes — and can disable **everything** (confinement, authz, run privileged, extract keys, rogue-join) | ❌ **authz is removed too** | **LUKS #111 / secure-boot #115 / secure element #107 / fast revocation #95** (the threat-model's "honest boundary") |
| **E. Supply-chain compromise** (attacker controls the OTA build/release) | Yes (ships anything, incl. disabling authz) | ❌ owns the pipeline that configures authz | **signed images #115/#116 + image scan #83 + provenance** |
| **F. Multi-tenant untrusted tenant (#167/#68, future)** | Yes (an untrusted payload launched naked harms co-tenants) | ✅ here authz earns its keep | **but this is #97 admission** (signed + authorized + identity), not bare confinement authz |

**Conclusion:** #156 confinement-drift bites only on **B** (our own bug) and **F** (future untrusted multi-tenant). Against capable adversaries (D/E/host-root) authz is removed with confinement → it does not harden us against them. So the "do we trust it?" question reduces to an **internal-quality** question — *do we trust our own deploy/launcher/OTA path (backed by CI + tests + detection) not to accidentally ship unhardened containers?* — not an adversary question. And **F is #97's job by the roadmap.**

## 4. Roadmap grounding — the split is already encoded
- **#68** (epic): node → generic payload host; future "things" (drone/camera/SDR/sensor) each a containerized tenant → multi-tenant is real, but *forward-phase*.
- **#97** (Workload identity, admission & mutual trust, **v3.0 PROD / prod-lock**): explicitly owns *"an admission gate in the node's container launch path (only signed+authorized images run)"* + app→node attestation + app↔app mTLS. Calls runtime hardening *"the sandboxing sibling — only limits a workload after you've decided to run it."* **Admission (authz) is #97, by design, and deliberately future.**
- **#151** (app-swap): signed-image verify is honestly gated on verified boot #74 (a root attacker bypasses it); a bespoke reconcile agent is *conditional, not committed* (needs a scale trigger; evaluate podman/Quadlet first).
- **#167** (multi-tenant plumbing, dev-now): already has a *resource/port* admission check in the payload manager — the seam #97's *security* admission extends.

**Important correction (from the §8 review):** #97 *as originally scoped* = provenance (signed image) + authorization (this payload allowlisted for this node). That does **not** reject a create missing `--cap-drop`/`--user`/`--read-only` — a signed, authorized image launched by a bad `run.sh` would pass #97 and run unhardened. Confinement-conformance is a **distinct predicate** riding the same authz mechanism, and it fell in a gap (#156 deferred it, #97 didn't own it). **#97 is amended (2026-09-19) to explicitly include confinement-conformance admission** so the gap has a home.

Confinement-authz is deferred to #97 not as a "throwaway" (its plugin harness — procd service, socket, arm64 build, fail-open — is exactly what #97 reuses; confinement-conformance is *additive* to provenance) but because: (a) **availability** — a hot-path authz plugin can fail-close and stop crash-recovery on an unattended node; (b) **timing** — the T3 amplifier (remote OTA #116) is **v4.0**, gated on #74, so the scary version of T3 and its prevention co-land with #97. Sequencing is safe: **#97 is "the core trust precondition for #68"**, so admission lands before the node is a production untrusted-multi-tenant host.

## 5. Decision — #156 v1.1 = Way 2
Three pillars, sized to the actual threat (B: our own bad deploy) and the availability constraint (no faintable hot-path component on an unattended node):

1. **Prevent — pre-deployment (honest scope):** the launcher is the single profile-applying create path; the profile↔flags **CI gate** (`check-hardening-env`, exists) + **HIL smoke test (#113)** catch a bad deploy **before it ships**. These are pre-deployment gates, not a runtime backstop — a buggy-but-CI-passing profile that reaches a fielded card is past them. Plus one *runtime structural* prevention: **daemon-wide `no-new-privileges: true`** (via uci `dockerd.globals`) — removes exactly one axis from the drift-able set for every container, for free.
2. **Correct:** **resource-axis in-place `docker update`** — verified live on manet01 (NanoCpus/Memory/PidsLimit change, StartedAt unchanged, no restart). **Honest framing:** T4 (a keyboard/automation `docker update`) has **no field trigger** on an unattended node, so this is a cheap belt-and-suspenders for the one live-mutable axis (and the in-place fix for a bad profile that set `memory=0`), **not** threat-reduction. Kept because it's cheap and non-destructive. **No destructive rebuild-on-drift** (rejected: `156-phase2-correction.md`).
3. **Surface:** the Phase-1 verdict feeds **`/cgi-bin/status` (#130)** + **`/cgi-bin/mesh` (#14)** — but these are **on-mesh only**; off-mesh delivery is **#142 (unbuilt)**. So on a partitioned/unattended node the surface is field-invisible today.

### Accepted residual (state it plainly, do not call T3 "covered")
For **T2/T3** — the triggers Way 2 does **not** prevent — a fielded v1.1 node that receives a buggy-but-CI-passing profile/provision runs an unhardened payload with **no effective runtime backstop** (the sole runtime detector is field-invisible until mesh reconnect / physical recovery). The one genuine v1.1 runtime prevention is the `no-new-privileges` default = **one axis**. This is **accepted for v1.1** because the trigger is bounded by CI+HIL and the amplifier (remote OTA #116, "one bad release hits many nodes") is **v4.0**, gated on #74 — in v1.1 app-change is manual/USB. It is recorded as *accepted residual*, not as "T3 handled."

**Confinement-conformance admission (the real runtime prevention for T3) is #97's** (scope amended 2026-09-19), to co-land with the OTA amplifier and #74.

### v1.1 work items (Way 2)
- [x] Phase-1 detection (`verify-profile.sh` hardened, reconcile loop) — shipped PR #188.
- [ ] Resource-axis `docker update` correction in the reconcile loop (non-destructive; the one correction we keep from Phase 2).
- [ ] `no-new-privileges: true` daemon default (uci `dockerd.globals` / daemon.json).
- [ ] Wire the drift verdict into `/cgi-bin/status` (#130) + `/cgi-bin/mesh` (#14).
- [ ] Off-mesh surface → tracked in #142 (not built here).

## 6. authz feasibility facts — handed to #97 (consolidated)
Gathered on manet01 (2026-09-19), recorded here and posted to #97 as design input for its admission gate. **Not used in #156.**
- **docker 27.3.1** on the node; **`dockerd --authorization-plugin <list>` IS supported**; none configured; `SecurityOptions = [seccomp=builtin, cgroupns]`.
- **No `/etc/docker/daemon.json`** — dockerd is configured via **uci `dockerd.globals`** (`data_root=/opt/batdata/docker`, `iptables=0`, `log_level=warn`). Registering an authz plugin / setting `no-new-privileges` goes through uci or a generated daemon.json.
- **No general interpreter on-node** — only **lua + busybox** (no python/go/node/perl). An authz plugin must be a **static arm64 Go binary** (this WSL build env can cross-compile it) run as a procd service, listening on a unix socket in `/run/docker/plugins/`.
- **Hot-path availability tension (design-critical for #97):** an authz plugin intercepts *every* docker API call. If it dies, docker **fail-closes** (no container can start → payload can't crash-recover on an unattended node) or **fail-opens** (protection silently gone). Needs procd respawn + a chosen posture (recommend **fail-open + loud surface** for field availability) + it must be simple/fast enough to never bottleneck.
- Natural to build **once** as #97's admission (confinement + provenance/signing + identity), not a bare confinement-only authz.

## 7. Scope boundary (restated)
#156 = *a hardened workload stays hardened at runtime, sized to our-own-deploy drift, on a single-trusted-tenant node.* NOT which workloads may run / signed+authorized admission **and confinement-conformance admission** (→ **#97**, scope amended 2026-09-19 to include rejecting a create missing the hardening flags), NOT signed-image verify (→ #151/#74), NOT trusting the on-disk profile against a root attacker (→ #97/#137/#111/#115), NOT off-mesh alarm delivery (→ #142).

## 8. Independent adversarial review of this decision (2026-09-19)
This decision record was itself put through an independent adversarial review (verdict **SOUND-WITH-CAVEATS**: the conclusion holds, the justification was motivated in three places — now corrected here):
- **[CRITICAL] "authz → #97" pointed at an empty home** — #97 as scoped = provenance + authorization, which does *not* reject an unhardened create. **Fixed:** #97 amended to own confinement-conformance admission (§4, §7); decision = option (B) amend #97 (not a new issue).
- **[HIGH] "T3 covered by Way 2" overstated** — CI/HIL are pre-deployment; the runtime backstop is field-invisible detection. **Fixed:** reframed as *accepted residual* with the honest winning justification (v1.1 manual/USB; OTA amplifier is v4.0/#74) (§5).
- **[MED] actor table drawn to minimize authz** — rows A/C over-claimed ("N/A"/"contrived"). **Fixed:** small-but-nonzero, honest boundary = socket-reachability vs daemon-control (§3).
- **[MED] Way 2 oversold vs alarm-only** for unprevented T2/T3 (surface is on-mesh-only/unbuilt). **Fixed:** §5 credits only the `no-new-privileges` default as genuine runtime prevention; residual named.
- **[LOW] resource-correction (T4) has no field trigger.** **Fixed:** §5 keeps it as cheap belt-and-suspenders, not threat-reduction.
- **[case-against] "build minimal authz now" loses** on availability + timing (not on the "throwaway" strawman, which the review flagged as itself motivated). **Fixed:** §4/TL;DR give the real reasons.
