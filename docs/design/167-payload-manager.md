# Design: #167 — generic payload manager (state layout, arbiter, secrets) + orchestrator generalization

Status: **SOUND-WITH-CHANGES (adversarial review R1 applied — see §11).** Parent: **#68** (generic payload host) ·
Owner issue: **#167** · Consumes the approved architecture in
[`payload-framework.md`](payload-framework.md) (R2 PASS-WITH-CHANGES) and its *Implementation
gate*. Relates: #98 (hardening emitter, DONE), #156 (runtime owner, DONE), #151 (safe swap),
#97 (admission, prod-lock), #162 (OTS = tenant #1), #13/#47 (secrets at rest), #116 (fleet OTA).
Date: 2026-09-23

## 0. Why this doc (scope boundary vs payload-framework.md)

`payload-framework.md` already decided the **architecture** and passed two review rounds: the
descriptor grows in place on `profile.yaml`; the mechanism is an *assembly of existing tools*
(no new resident daemon); the orchestrator is a **thin ordering-wrapper**, not compose; #156's
procd guardian owns anti-bypass. That doc then **explicitly deferred three gaps to #167** and
listed 5 *Implementation-gate* proofs to demonstrate "at first build."

This doc designs **only those deferred gaps** plus the one refactor they force, and nothing
else:

1. **Generic N-tenant state layout + teardown/zeroize** (#167 item 1)
2. **Port / subnet / zone arbiter** (#167 item 2)
3. **Secrets delivery mechanism** (#167 item 3)
4. **Orchestrator/guardian generalization** — the refactor that turns bespoke
   `run.sh` + `batman-ots.init` into `payload-run <tenant>` + a tenant-parameterized guardian,
   so "different app later = write a descriptor" is actually true. (Not a new #167 gap, but
   items 1–3 are untestable until the manager is generic; this is the vehicle for the gate proofs.)

Non-goals (unchanged from the parent): not a new epic; **not a resident reconcile daemon**
(stays in #151's scale-gate); not re-specifying #97 (only admission direction-1 consumed); not
app↔app workload identity (#97 dir-3, flagged unowned); not the delivery UI / fleet push (#116).

## 1. Ground truth (verified in the repo + on manet01 history, 2026-09-23)

What already exists and is reused unchanged:

- `scripts/profile-to-flags.py` — `values:`/`infra_values:` → `<container>.hardening.env`
  (`$HARDEN_FLAGS`). App-agnostic. **Keep.**
- `scripts/profile-to-fw4.py` — `network:` → `<app>.fw4.uci` (design-B zone + DNAT). Already
  generates `deploy/ots/ots.fw4.uci`. **Generalize naming only** (see §4).
- `deploy/ots/profile.yaml` — carries populated operational siblings
  (`images / network / lifecycle / volumes / secrets`). The descriptor schema is real.
- `deploy/ots/batman-ots.init` — #156 procd guardian: waits for dockerd, applies fw4, calls
  `run.sh` if the app container is down, then an **alarm-only** reconcile loop
  (`reconcile-resources.sh` in-place `docker update` + `verify-profile-ots.sh` → drift.json).
  **Generalize (see §4); its DoD and behaviour are preserved.**

What is bespoke / missing (this doc's work):

- `deploy/ots/run.sh` — 85 lines, hardcodes image refs, static IPs (172.20.0.2/3/5/10/12),
  the `$CM` common-env string, per-role `--entrypoint python3 /app/venv/bin/…`, `--hostname`,
  the volume-chown pre-steps, and per-service health polls. **These facts already live in
  `profile.yaml` except per-container `env / entrypoint / ip / hostname`, which the schema does
  not yet carry** → §4 schema growth.
- **No arbiter.** Nothing refuses a second tenant that reuses host `:8443`, subnet
  `172.20.0.0/24`, or zone name `dockert`. → §3.
- **State path** = `/opt/batdata/deploy/ots` (guardian's `DEPLOY=`). The parent doc says unify
  to `apps/<tenant>/`; not done. → §2.
- **No secrets delivery.** `values.secrets` only *declares* `eud-ssl-cert`; `eud_handler_ssl`
  crashed in the spike for a missing cert. → §5.
- **No teardown/zeroize.** The guardian's `stop_service()` only `docker rm -f`s the 6 OTS
  containers by hardcoded name; no state/zone/secret removal, no zeroize. → §2.

## 2. State layout + teardown/zeroize (#167 item 1)

### 2.1 Convention — pick ONE (resolves the parent doc's drift note)

**Decision: `/opt/batdata/apps/<tenant>/` on p6** (the persistent ext4 data partition, same
disk as the docker data-root, survives reboot; **not** in the OS overlay so it is not wiped by
A/B reflash — the guardian re-installs from p6, mirroring #192).

```
/opt/batdata/apps/<tenant>/
  manifest.env         # rendered from profile.yaml (dev/CI, §4) — flat, node-sourceable
  <container>.hardening.env   # from profile-to-flags.py (one per app + infra container)
  <tenant>.fw4.uci     # from profile-to-fw4.py
  net.alloc            # arbiter record: PORTS=... SUBNET=... ZONE=... (flat, §3)
  secrets/<name>       # 0600 root, bind-mounted ro (§5); NOT world/other readable
  volumes/             # docker named volumes live in docker data-root, NOT here; this dir holds
                       # only bind-style state a tenant needs outside a volume (usually empty)
```

Rationale for reusing the **existing `/opt/batdata`** rather than a bare new tree: docker
data-root, `deploy/ots` state, and `/opt/batdata/crash` already live there; p6 has 23 G free
(session-12b), and the guardian already mounts + guards `/opt/batdata`. `apps/<tenant>/`
replaces `deploy/<app>/` as the **on-node** location; the repo keeps authoring under
`deploy/<app>/` (dev/CI renders → ships to `apps/<tenant>/`).

**Migration of OTS:** `apps/opentakserver/` is populated; `deploy/ots` on-node becomes a compat
symlink for one release, then removed. Guardian `DEPLOY=` derives from tenant name.

### 2.2 Teardown / zeroize — the operation #151 punted

`payload-teardown <tenant> [--zeroize]`:

1. Stop the tenant's guardian (`/etc/init.d/batman-payload-<tenant> stop`, disable).
2. `docker rm -f` the tenant's containers (names from `manifest.env`, **not** a hardcoded list).
3. Remove the tenant's fw4 objects (revert the uci sections named `<zone>_*`, `fw4 reload`).
4. Free the arbiter record (`rm apps/<tenant>/net.alloc`).
5. Remove docker named volumes **only with `--zeroize`** (default keeps state for re-install —
   swap vs retire are different, per #151). `--zeroize` = `docker volume rm` **after** an
   overwrite pass on the underlying dirs, and `shred`/overwrite `apps/<tenant>/secrets/*` then
   `rm -rf apps/<tenant>`.

**Zeroize honesty (threat model, actor E "node capture / SD pull"):** on flash storage
`shred`/overwrite is *best-effort* — wear-levelling + FTL remapping mean overwrite does **not**
guarantee the old blocks are unreachable. True zeroize of secrets requires **encryption at rest
(#47 LUKS)** so that discarding the key makes ciphertext unrecoverable. This design labels
`--zeroize` as *logical* removal + best-effort overwrite, and records "cryptographic zeroize →
#47" rather than claiming secure erase. (Same discipline as #137's "provisioning is trusted-bench,
not offline-injection" honesty.)

## 3. Port / subnet / zone arbiter (#167 item 2)

### 3.1 What must not collide, and who fixes each

| resource | fixed by | can auto-derive? | collision handling |
|---|---|---|---|
| **host published ports** (8088/8089/8443) | protocol/client (ATAK expects these) | **No** — client-facing, cannot hash | arbiter **refuses** the 2nd claimant |
| **bridge subnet** (172.20.0.0/24) | internal only | **Yes** — deterministic from tenant | derive; refuse only on hash clash |
| **fw4 zone name** (`dockert`) | internal only | **Yes** — `<tenant-slug>t` | derive; refuse on clash |
| **kernel bridge name** (`br-ots`) | internal + fw4 `iifname` | **Yes** — `br-<slug>` | derive; refuse on clash |

**Resolves parent Open-Q3** ("uci config vs deterministic-from-name"): **both, split by
resource type.** Internal names/subnets are **derived deterministically** from the tenant slug
(no registry to drift); host ports are **declared** in the descriptor and the arbiter's only job
there is **collision refusal**.

### 3.2 Mechanism — a stateless check over installed descriptors (no new daemon)

The "registry" is **not** a separate stateful file that can drift — it is the **union of
installed tenants' `net.alloc` records** under `apps/*/net.alloc`. Each tenant's `net.alloc` is
rendered at admission from its descriptor:

```
# apps/opentakserver/net.alloc  (flat, busybox-greppable — node has no YAML)
TENANT=opentakserver
PORTS=8088 8089 8443
SUBNET=172.20.0.0/24
ZONE=dockert
BRIDGE=br-ots
```

`payload-arbiter <tenant>` (runs at admission, **before** install, on-node; also mirrored as a
dev/CI lint over `deploy/*/profile.yaml`):

1. Compute the candidate's `{PORTS, SUBNET, ZONE, BRIDGE}` (declared ports; derived
   subnet/zone/bridge from slug).
2. `grep` every **other** `apps/*/net.alloc`. If any PORT, SUBNET, ZONE, or BRIDGE intersects →
   **exit non-zero with the specific clash** (admission refuses; nothing installed).
3. On success, write the candidate's `net.alloc` (the commit point for its network allocation).

Subnet derivation: `172.20.<N>.0/24` where `N = 1 + (order of tenant slug among installed)`,
recorded in `net.alloc` so it is stable across reboots; a hash-based `N` is rejected (birthday
collisions at small N are silly — a deterministic small counter with an explicit refusal on the
(impossible-in-practice) 254-tenant overflow is simpler and auditable).

**Gate proof 4 (arbiter refusal):** install a 2nd descriptor claiming host `:8443` → arbiter
exits non-zero, tenant not installed, OTS untouched.

## 4. Orchestrator + guardian generalization (§0 item 4)

### 4.1 Descriptor schema growth (per-container operational facts)

`run.sh` hardcodes what the descriptor cannot yet express. Grow the **emitter-ignored**
operational siblings (safe: `profile-to-flags.py` reads only `values:`/`infra_values:` — verified
§1) so each role/container carries its runtime facts:

```yaml
images:
  - ref: batman/ots:1.7.13-arm64
    containers:                    # NEW: explicit per-container spec (was implicit in run.sh)
      - {name: opentakserver,       ip: 172.20.0.5,  hostname: opentakserver}
      - {name: ots_cot_parser,      entrypoint: [python3, /app/venv/bin/cot_parser]}
      - {name: ots_eud_handler,     ip: 172.20.0.10, entrypoint: [python3, /app/venv/bin/eud_handler]}
      - {name: ots_eud_handler_ssl, ip: 172.20.0.12, entrypoint: [python3, /app/venv/bin/eud_handler, --ssl]}
env_common:                        # NEW: the run.sh $CM block, declarative
  SQLALCHEMY_DATABASE_URI: "postgresql+psycopg://ots:password@ots-db/ots"
  OTS_RABBITMQ_SERVER_ADDRESS: rabbitmq
  # ...
volumes:
  - {name: ots-appdata, path: /app/ots, chown: "1000:1024"}   # chown pair, not run.sh hardcode
```

`env_common` carrying a DB password is a **secret smell** — see §5; the password moves to a
secret and `env_common` references it. Recorded, not hand-waved.

### 4.2 `scripts/profile-to-manifest.py` (NEW, dev/CI)

Same pattern as the two existing emitters: **YAML parsed on dev/CI, node gets a flat file.**
Renders `images/env_common/lifecycle/volumes` → `apps/<tenant>/manifest.env`, a flat,
busybox-sourceable description of the container list, their per-container args, volumes, chowns,
and the ordered lifecycle + health commands. The node **never parses YAML** (busybox), preserving
the established contract.

### 4.3 `payload-run <tenant>` (NEW, generic on-node runner, busybox sh)

Replaces bespoke `run.sh`. Reads `apps/<tenant>/manifest.env` + sources each
`<container>.hardening.env` + applies `<tenant>.fw4.uci` → sequential `docker run` on the
derived bridge, health-gated between lifecycle steps (the parent doc's chosen wrapper). `run.sh`
becomes a two-line shim: `exec payload-run opentakserver`. **Behaviour must be byte-for-byte
equivalent on OTS** (gate proofs 1+2: exact `br-ots` name so fw4 `iifname` matches; every
container carries `$HARDEN_FLAGS`).

### 4.4 Generic guardian (generalize `batman-ots.init`)

`batman-payload-<tenant>` init generated from a template with `TENANT=` + `DEPLOY=apps/<tenant>`.
The #156 loop (wait dockerd → fw4 → `payload-run` if down → alarm-only reconcile → drift.json) is
**unchanged in behaviour**; only the hardcoded name/paths are parameterized. The keepalive watches
the tenant's **primary** container (from `manifest.env`, not the literal `opentakserver`). #192's
"guardian survives A/B flash via batdata-mount restore" keeps working because the generated init
still lands under `deploy/*/*.init` on p6.

## 5. Secrets delivery (#167 item 3)

### 5.1 Reality: air-gapped tactical node, no vault, no network CA

Options weighed:

- **docker/swarm secrets** — needs swarm mode. Rejected (not running swarm; adds a control plane).
- **env-var secrets** — visible in `docker inspect` + `/proc/<pid>/environ`, leaks to any
  container that can read the socket (none can, socket unmounted) but still poor hygiene, and
  can't be `--read-only`-friendly for rotation. Rejected as the mechanism (kept only for
  non-secret config).
- **file drop, bind-mounted read-only** — a `apps/<tenant>/secrets/<name>` file (0600 root),
  bind-mounted `:ro` at the container's declared mount path. **Chosen** — matches the node's
  actual capabilities and the read-only-rootfs model (secret is a mount, not a rootfs write).

### 5.2 Descriptor + delivery paths

`values.secrets[]` grows a `mount` (in-container path) and `source`:

```yaml
values:
  secrets:
    - {name: eud-ssl-cert, source: self-signed, mount: /app/ots/ca, exposure: "TLS for eud --ssl"}
    - {name: db-password,  source: seed,        env: SQLALCHEMY_DATABASE_URI, exposure: "DB cred"}
```

`source` ∈:
- **`self-signed`** — generated by the app's `init_once` (OTS already creates its CA on first
  run; this simply *declares* it and points the mount at the volume, closing the
  `eud_handler_ssl` crash without a manual step). No delivery needed.
- **`seed`** — provisioned via the existing **p5 identity partition** (`batman-config-save
  --seed` path, #137/#191) and restored by `96-batman-config-migrate` into
  `apps/<tenant>/secrets/` before the guardian starts. Reuses the #137 mechanism; no new channel.
- **`ota`** — pushed by fleet OTA (#116) as an encrypted blob; **deferred to #116**, declared so
  the schema is forward-compatible.

**At rest (#13/#47):** `apps/<tenant>/secrets/` is plaintext-on-p6 until LUKS (#47) lands — same
honesty as §2.3. Recorded as residual, not solved here.

### 5.3 The env-var secret smell (§4.1)

`env_common.SQLALCHEMY_DATABASE_URI` embeds the DB password. Minimal fix in scope: move it to a
`db-password` secret file and have the app/entrypoint read it, OR (pragmatic v1.1) keep the
internal-only DB password as config but **document it as internal-bridge-only** (ots-db is not
published, reachable only from br-ots which is `input=DROP` from the mesh). Chosen: **document as
internal-only for v1.1**, migrate to a secret when #47 lands (over-engineering a bridge-internal
cred before at-rest encryption exists buys little). Flagged for the reviewer to challenge.

## 6. Threat model (field triggers × actors) — scope from the field, not shippability

Per the project's scoping rule, each mechanism is justified by a concrete field trigger and the
actor it defends against, **not** by "it makes N-tenant look done."

| Field trigger | Actor | Without this design | With it |
|---|---|---|---|
| Operator installs a 2nd payload (camera) that also wants `:8443` | B (our own mis-packaging) | silent DNAT overwrite → ATAK or camera randomly unreachable, no error | arbiter refuses at admission, names the clash (§3) |
| Two payloads on one node; camera app is buggy/compromised | F (untrusted future tenant) | camera container can reach OTS DB on the shared bridge | per-tenant bridge+zone, inter-zone DROP; `peer_allow: []` default (gate proof 3) |
| App retired/swapped; node later repurposed or lost | E (node capture / SD pull) | secrets + tenant state linger in plaintext | `payload-teardown --zeroize` logical-removes + best-effort overwrite; true erase → #47 (§2.3) |
| `eud_handler_ssl` needs its TLS cert on an air-gapped node | B / operator | container crash-loops (the spike) | secret declared, delivered by file-mount (§5) |
| A hand-run `docker run` bypasses the profile | A (remote payload RCE) / operator error | unhardened container runs unnoticed | **unchanged from #156** — guardian re-asserts + drift alarm (not re-designed here) |

Actors A (remote RCE) and C (supply chain) are **small-but-nonzero** and handled by #97/#115 at
the admission/boot layers, not here — this design consumes admission direction-1 only and does
not claim to stop a compromised deployer from listing an over-privileged descriptor (that is
#97). Same boundary the parent doc drew.

## 7. Alternatives considered

- **Keep bespoke per-app scripts** (write a new `run.sh` per app). Rejected — the user confirmed
  "different apps later"; N copies of a 85-line script drift and re-introduce the hardcoded-name
  class of bug (#194's meshtest `wlan0` lesson: bespoke duplication hides breakage).
- **A stateful arbiter registry** (`/etc/config/payload` the manager mutates). Rejected — a
  mutable registry drifts from the installed descriptors (the actual truth) and needs its own
  reconcile. The union-of-`net.alloc` derivation has no independent state to rot.
- **Deterministic host ports** (hash tenant→port). Rejected — client-facing ports are fixed by
  protocol; you cannot hash 8089 and still have ATAK connect.
- **compose / k3s / balena for orchestration.** Rejected upstream in `payload-framework.md`
  (random `br-<hash>` misses fw4 `iifname`; control-plane dep on an air-gapped node) — not
  re-litigated.
- **Encrypt secrets now (roll #47 into this).** Rejected as scope — #47 is a build-gated kernel
  change (dm-crypt); doing a half version here would be theater. Declared as the residual.

## 8. Failure modes

- **Manifest ↔ hardening.env drift** — a descriptor change re-renders one file but not the
  other. Mitigation: the existing `check-hardening-env.sh` CI gate extends to also assert
  `manifest.env` and `net.alloc` are regenerated (regenerate-and-diff, HARD gate) — mirrors the
  #191 provisioning-sync guard.
- **Arbiter false-negative (missed clash)** — a tenant published a port outside its `net.alloc`.
  Mitigation: `payload-run` refuses to `docker run` a `-p`/DNAT not present in the tenant's
  `net.alloc` (the manifest is the only source of published ports).
- **Guardian watches the wrong container after generalization** — mitigation: gate proof 1 on
  OTS is byte-equivalence (same containers up, same drift.json OK), run before any 2nd tenant.
- **Teardown leaves fw4 orphans** — mitigation: teardown reverts by the tenant's zone-name prefix
  and asserts `nft list table inet fw4` no longer references the bridge (gate check).
- **Best-effort zeroize oversold** — mitigation: §2.3 labels it; runbook says true erase needs #47.

## 9. Implementation increments (each reviewed before it touches manet01)

The user authorized increments 1→3; each block still passes review + on-node proof before the
next. **Order revised in R1 (MINOR-1/Q4): prove the generic path on a clean NEW tenant first;
migrate OTS LAST** — OTS carries baked IPs, a manual guardian, and the declared/frozen-subnet
special case, so it is the worst possible debut of the generic runner.

- **Increment 1 (foundation, NEW tenant only — OTS untouched):** state convention (§2.1) +
  `profile-to-manifest.py` (§4.2) + `payload-run` (§4.3) + generic guardian template (§4.4,
  restored by the existing #192 glob, §11-C1) + arbiter with admission lock (§3, §11-M3) +
  fw4/manifest CI gate (§8, §11-m3). Prove on a **new minimal `network-service` dummy** (static
  `nginx`, derived subnet `172.20.1.0/24`, one published port). **DoD = gate proofs 1, 2, 4**
  (dummy comes up hardened on the derived bridge; `$HARDEN_FLAGS` present; arbiter refuses a 2nd
  descriptor claiming the dummy's port). OTS stays on its validated bespoke `run.sh`/`batman-ots`.
- **Increment 2:** a 2nd dummy tenant → **gate proof 3** (N=2 isolation: dummy-A cannot reach
  dummy-B, one auditable `nft` table) + secrets delivery (§5) proven end-to-end.
- **Increment 3 (migrate OTS + retire bespoke):** port OTS to the generic runner via the
  **declared/frozen** path (§11-C2: subnet+IPs declared, not derived), behavioural-equivalence
  DoD (§11-M2), rename `batman-ots`→`batman-payload-opentakserver` (safe per §11-C1) with old-init
  cleanup, then `payload-teardown --zeroize` (§2.2) + swap atomicity handed to #151. This is where
  #162 ④ actually closes.

## 10. Open questions for the reviewer

1. §5.3 — is documenting the bridge-internal DB password as "internal-only, migrate at #47"
   acceptable for v1.1, or must it become a secret file now?
2. §4.1 — growing `images[].containers[]` with `entrypoint/ip/hostname` is a real schema
   expansion. Is per-container static `ip` even needed, or can we rely on docker DNS
   (127.0.0.11) + the DNAT targeting container *names*? (fw4 DNAT needs an IP, not a name — but
   could a fixed `--ip` per *published* container only, others name-resolved, shrink the schema?)
3. §3.2 — subnet counter `N` recorded in `net.alloc`: what happens on teardown of a middle
   tenant then re-add — reuse the freed `N` or monotonic? (reuse = tighter, but a stale
   container on the old subnet could clash; monotonic = simpler, wastes /24s slowly.)
4. Is migrating OTS off `/opt/batdata/deploy/ots` worth the churn now, or should `apps/<tenant>/`
   apply only to *new* tenants and OTS stay put until the next image bake (v2.0)?

## 11. Review R1 — findings & resolution (independent adversarial reviewer, 2026-09-23)

Verdict returned: **SOUND-WITH-CHANGES.** Architecture direction confirmed correct and consistent
with `payload-framework.md`. Resolutions below; the reviewer worked against a **stale checkout**
(local clone was at `9cd33ff` / pre-#192; origin/main was `4c36c30`), which produced one false
critical — verified and rejected with evidence.

- **C1 "the #192 guardian-restore mechanism does not exist" → REJECTED (stale-tree artifact).**
  On current main (`4c36c30`) the mechanism is `restore_payload_guardians()` in
  `feed/batman-provision/files/etc/uci-defaults/95-batman-storage:123-138` (mirrored in
  `deploy/provisioning/uci-defaults/95-batman-storage`), called from `boot()`. It **globs
  `$MOUNT/deploy/*/*.init`** (tenant-agnostic), installs each root-owned init to
  `/etc/init.d/<name>`, `enable`s and `start`s it, idempotently, every boot after p6 mounts.
  Therefore the per-tenant `batman-payload-<tenant>` rename is **safe and already supported** —
  the reviewer's own suggested fix (glob-restore keyed on no hardcoded name) is what ships.
  **New integration point the reviewer missed (real):** #192 globs `deploy/*/*.init`, but §2.1
  chose `apps/<tenant>/`. **Resolution:** keep each tenant's guardian init under
  `/opt/batdata/deploy/<tenant>/<name>.init` (compat with #192 as-is) OR extend the glob to also
  scan `apps/*/*.init`. **Chosen: extend the #192 glob to `apps/*/*.init`** (one-line change in
  both 95-batman-storage copies, keeps all tenant state under one `apps/<tenant>/` root) — and the
  provisioning-sync CI guard already enforces the two copies stay byte-identical.
- **C2 subnet derivation contradiction + incompatible with OTS baked IPs → ACCEPTED.** Confirmed:
  `profile-to-fw4.py` bakes literal DNAT `dest_ip`s and never reads `subnet`; OTS hardcodes
  `172.20.0.{2,3,5,10,11,12}`. **Resolution:** two paths — **(a) declared/frozen** (OTS): subnet +
  per-container IPs are declared in the descriptor and the arbiter *validates+records*, never
  derives; **(b) derived** (new tenants): the manager assigns the `/24` AND per-container offsets
  together, so IPs live inside the derived subnet by construction. Only DNAT-target (published)
  containers get a static `--ip` (Q2 answer); the rest resolve by docker DNS. The §3.2 example's
  `172.20.0.0/24` is the *declared* OTS value, not a derivation — annotate it so the N-counter
  contradiction disappears (derivation starts new tenants at `172.20.1.0/24`).
- **C-fact: `profile-to-fw4.py` needs NO change (already fully tenant-parameterized), zone name is
  DECLARED not derived → ACCEPTED.** §4's "generalize naming only" overstated; the file is
  untouched. Zone name stays **declared** in the descriptor (OTS keeps `dockert`); do not derive
  `<slug>t`. Corrected.
- **M1 §4.1 schema insufficient → ACCEPTED.** Grow the descriptor with: `containers[].env`
  (per-container, distinct from `env_common`, with an explicit note of which containers
  `env_common` covers — the 4 app containers only), the rabbitmq **cookie** (per-node secret,
  §5), `volumes[].chown_image` (OTS image runs all three chowns), a `mounts[]` section for
  read-only config-file bind-mounts (the `rabbitmq-extra.conf` → `/etc/rabbitmq/conf.d/…:ro`
  case), `containers[].hostname` for every container (incl. the `ots-cot_parser` dash-vs-underscore
  quirk — carry it literally, don't "fix" it), infra `--ip` `.2/.3` **only if published** (they
  are not → drop them, docker DNS), and a `restart:` → `--restart on-failure:5` mapping.
  Acceptance test: **diff the generated command set against `run.sh` line-by-line** before writing
  `payload-run`.
- **M2 "byte-for-byte equivalent" DoD unfalsifiable → ACCEPTED.** Redefine Increment-3 (OTS
  migration) DoD as **behavioural equivalence**: `verify-profile-ots.sh` PASS on all 6 +
  `docker inspect` equal on the confinement/network/IP/entrypoint axes + full CoT round-trip (the
  profile's own evidence standard). Drop "byte-for-byte."
- **M3 arbiter TOCTOU + N is mutable state → ACCEPTED.** Serialize admission under
  `flock apps/.arbiter.lock`; **N is monotonic, never reused**, refuse at the /24 overflow. Drop
  the rhetorical "no state to drift" — `net.alloc` is state; the honest claim is "race-free by the
  admission lock, drift-caught by the CI regenerate-and-diff gate."
- **m1 increment order inverts risk → ACCEPTED** — §9 reordered (OTS last).
- **m2 DB password ships as the literal `password` on every node → ACCEPTED.** Make it
  **per-node random at provisioning** now (like the rabbitmq cookie); keep it as internal-bridge
  config (ots-db unpublished, `input=DROP`) rather than a secret file until #47; document the
  plaintext-in-`manifest.env` residual. Fixes the shipped-constant, defers the encryption honestly.
- **m3 fw4 not CI-gated today → ACCEPTED.** Fold `*.fw4.uci` into the same regenerate-and-diff
  gate alongside the new `manifest.env` / `net.alloc` (extends `check-hardening-env.sh`).
- **Honesty audit:** §2.3 zeroize and §5.2 secrets-at-rest labeled honestly (defer true erase to
  #47) — upheld. The two overclaims (C1 "#192 restore works", M2 "byte-for-byte") are corrected
  above.

§10 open questions are now answered: **Q1** defer secret-file to #47 *but* per-node-random now
(m2); **Q2** static `--ip` for published containers only, rest by docker DNS; **Q3** monotonic N +
admission lock (M3); **Q4** migrate OTS **last** (m1). All fold into §9.

## 12. Increment 1 — ON-NODE PROOF (manet01, 2026-09-23) = PASS

Proven live on manet01 (Pi4, aarch64, docker 27.3.1, BATMAN 1.4.7) against the **throwaway
`dummy-nginx` tenant** (`nginxinc/nginx-unprivileged:1.27-alpine` arm64, sideloaded from WSL) with
the **production OTS stack running and untouched throughout** (6 containers up + API healthy +
3 fw4 DNAT rules intact, verified before/after).

- **Gate 1 (bring-up on the exact bridge) PASS** — `payload-run dummy-nginx` created
  `dummy-nginx-net` with kernel bridge **`br-dummy`** (verified `com.docker.network.bridge.name`),
  container on `172.20.1.10`; the fw4 `dummyz` zone + DNAT `8090→172.20.1.10:8080` landed in the
  single `inet fw4` table (`accept_to_dummyz` / `dnat ip to 172.20.1.10:8080`); nginx served
  (health rc=0).
- **Gate 2 (hardening applied) PASS** — `docker inspect dummy-web`: `ReadonlyRootfs=true`,
  `User=101`, `CapDrop=[ALL]`, `SecurityOpt=[no-new-privileges]`, `NanoCpus=500000000` (0.5),
  `Memory=67108864` (64m), `PidsLimit=64` — all 7 axes from `$HARDEN_FLAGS`.
- **Gate 4 (arbiter refusal) PASS** — with the real OTS tenant registered, `dummy-nginx`
  coexists (disjoint) → OK; a candidate claiming host `:8090` → **REFUSED**; a candidate reusing
  OTS's `dockert` zone → **REFUSED** (correctly attributed to `opentakserver`).
- **Bonus — generic guardian PASS** — the 4-line `batman-payload-dummy-nginx` init (sourcing the
  shared `payload-guardian.sh`) enabled + started under procd, kept the container up, and its
  reconcile loop published `/tmp/batman-payload-dummy-nginx-drift.json` = `{"status":"OK",…}`.
- **Teardown clean** — node restored pristine (OTS 6/6 + API healthy + 0 dummy refs anywhere).

**Two real bugs the on-node test caught (both fixed + re-rendered):**
1. **uci hyphen** — `profile-to-fw4.py` used the tenant slug directly as the uci *section id*
   (`firewall.dummy-nginx_zone`), and uci rejects hyphens (`uci: Invalid argument`). OTS (`ots`)
   never hit it. Fix: sanitize the section-id prefix `[^A-Za-z0-9_]→_` (display `name=` keeps the
   raw slug); OTS output unchanged (no drift).
2. **health `localhost`→IPv6** — busybox `wget http://localhost:8080` resolves `::1` first and
   nginx is IPv4-only → "Connection refused" → 120 s health timeout. Fix: `127.0.0.1` in the
   descriptor.

**Teardown lesson for Increment 3 (`payload-teardown`):** `fw4 reload` leaves the removed zone's
now-empty named chains (`input_dummyz`, `accept_to_dummyz`, …); only `fw4 restart` fully flushes
them. `payload-teardown` must `fw4 restart` (or explicitly flush the tenant's chains), not just
`reload`.

## 13. Increment 2 — ON-NODE PROOF (manet01, 2026-09-23) = PASS

Proven live with a **second tenant `dummy-nginx-b`** (172.20.2.0/24 / `br-dummyb` / zone
`dummybz` / port 8091) alongside tenant A, OTS untouched (6/6 + API healthy throughout).

**Node config fix (authorized):** manet01 had **drifted to `dockerd.globals.iptables=1`** (docker
managing its own iptables → 3 nft tables), not the design-B `iptables=0` validated in #164/#165.
Set back to `iptables=0` + `dockerd restart`; **OTS survived via `live_restore=true`** (verified 6/6
+ API healthy before and after). The stale `ip nat`/`ip filter` docker tables linger inert under
iptables=0 and clear on the next reboot. **The node is now on the correct design-B config.**

- **Gate 3 (N=2 isolation) PASS, cleanly fw4-attributed** — A→B and B→A both **blocked**
  (`Connection refused`), each container still reaches its own service. Attribution is clean
  *because* iptables=0: `nft list table ip filter` has **0** refs to the dummy bridges (docker adds
  nothing), while `inet fw4` carries the two zones with **no cross-zone forward** → the isolation is
  the design's fw4 zones, not docker. **Single auditable table:** `ip nat`/`ip filter` = 0 dummy
  refs, `inet fw4` = 34 — only fw4 governs the tenants.
- **Secrets delivery (§5) PASS** — a `source: seed` file secret (`apps/dummy-nginx-b/secrets/
  test-token`, placed 0600 root) is bind-mounted **read-only** at `/token`; the container reads its
  content end-to-end; A (no secret) has no `/token`; writing `/token` fails (`Read-only file
  system`). Closes the delivery gap that crashed OTS's `eud_handler_ssl`.

**Two more real bugs the on-node test caught (both fixed):**
1. **`payload-run` accumulator scope** — the per-container `-e`/`-v`/secret args were accumulated
   in the **main shell's `$@`**, but `finish_block` is a *function* with its own `$@`, so a bare
   `finish_block` dropped every accumulated arg. Increment 1 (tenant A, no `-e`/`-v`) passed by
   luck. Fix: pass the accumulator — `finish_block "$@"` — and `set --` (clear) in the main shell,
   not inside `reset_block` (whose `set --` only cleared the function's params).
2. **secret unreadable by non-root container** — a 0600 root secret is `Permission denied` for the
   container's `--user 101`. Fix: the `SECRET` manifest line carries the target container's
   `run_as` uid; `payload-run` `chown`s the secret to that uid + `chmod 0400` before mounting
   (readable by that user only, not world).

**Increment 1+2 net:** the generic manager (emitter + `payload-run` + `payload-arbiter` +
`payload-guardian` + #192 glob + CI gate) is proven on real hardware for bring-up, hardening,
arbiter refusal, guardian, **N=2 fw4-native isolation, and secrets delivery** — with OTS
production untouched. Remaining: **Increment 3** = migrate OTS onto this path (declared/frozen,
behavioural-equivalence DoD) + `payload-teardown --zeroize` → closes #162 ④.

## 14. Increment 3 — OTS MIGRATION (manet01, 2026-09-23) = PASS · closes #162 ④

The production OTS 6-container stack was migrated off the bespoke `deploy/ots/run.sh` onto the
generic `payload-run opentakserver` path, on the live node.

**Phase 1 (behavioural equivalence, dev-side):** grew `deploy/ots/profile.yaml`'s operational
siblings to fully capture what `run.sh` hardcoded — `env_common` (the `$CM` block), per-container
`env` (DB creds, rabbitmq cookie), `entrypoint`/`ip`/`hostname`, `volumes` with `chown`+
`chown_image` (the OTS-image chown vehicle), the `rabbitmq-extra.conf` read-only `mounts` entry,
pinned `rabbitmq:4.3.6`, and `network.docker_name: ots-net` (reuse the live network). A docker-stub
dry-run of `payload-run opentakserver` produced the **3 volume pre-chowns + 6 container `docker run`
commands behaviourally identical to run.sh** (flag order aside).

**Phase 2 (live migration):** stopped+disabled the old `batman-ots` guardian (its `stop_service`
rm'd the 6 containers), then `payload-run opentakserver` recreated them via the generic path
(reusing `ots-net`/`br-ots`). **DoD met:**
- `verify-profile-ots: ok=6 drift=0 unknown=0 → OK` — identical hardening to the pre-migration
  baseline, all 6 containers.
- **CoT round-trip PASS** — injected a CoT to `eud_handler` 172.20.0.10:8088; `cot` table 729→730,
  the event's uid found in postgres → the full `eud → rabbitmq → cot_parser → postgres` chain works.
- API healthy; `ots-net`/`br-ots` reused (no network re-create); fw4 DNAT unchanged.
- New generic guardian `batman-payload-opentakserver` enabled+started, drift.json `OK`; old
  `batman-ots.init` removed from **both** `/etc/init.d` and its p6 source (else the #192 glob would
  restore it → a duplicate guardian).

**Bug #3 the migration caught (fixed):** the generic guardian globbed `verify-profile*.sh` and so
also ran the low-level helper `verify-profile.sh` (which needs an `<app>` arg) → `usage:` error →
**false DRIFT alarm**. Fix: glob `verify-profile-*.sh` (the dash-suffixed rollup only), not the
helper.

**Also:** `deploy/ots/run.sh` reduced to a two-line shim (`exec payload-run opentakserver`); the
bespoke logic is in git history. `payload-teardown <tenant> [--zeroize]` added (§2.2): default
keeps state (swap), `--zeroize` removes volumes + tenant dir after a best-effort secret overwrite
(true erase → #47); it reads fw4 section ids from the tenant's `*.fw4.uci` (decoupling the app-dir
vs tenant naming) and uses `fw4 restart` (§12 lesson). Rollback path left on the node
(`/opt/batdata/deploy/ots/run.sh` unchanged).

**#162 ④ CLOSED:** OTS deploys via the app-agnostic runtime owner (#156 guardian) + generic runner,
not a bespoke script — TAK is now genuinely "tenant #1" of the payload framework (#68).

**Node state change:** manet01 now runs OTS under the generic manager with `dockerd iptables=0`
(design-B). Increments 1–3 total: **8 files of new mechanism, 3 tenants proven, 6 real bugs found
& fixed on hardware** (uci hyphen, health IPv6, accumulator scope, secret ownership, guardian
verify glob, network-name reuse). Ready to commit + PR.
