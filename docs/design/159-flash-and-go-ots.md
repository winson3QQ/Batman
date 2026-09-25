# #159 flash-and-go payloads + #215 first-boot grow fix

Status: proposed (#216). Firstboot grow + happy-path flash-and-go were hardware-validated on manet04;
the firstload orchestration was reworked after three rounds of independent adversarial review — see
"Layered health model" and "Re-validation". Companion issues: #159 (docker-in-image), #215 (first-boot
grow bug), #202 (config survival), #201 (first-boot grow), #211 (autocommit), #192/#167/#156/#151
(payload lifecycle / confinement).

## Problem
A freshly-flashed card should boot into a working payload host (e.g. OTS) with **zero operator steps**
("插上卡即可用"). Two gaps blocked this:

1. **#215 — the ext4 never grew.** #201's `95-batman-storage` grows the GPT p6 to fill the card with
   `sgdisk -e`, then resizes the ext4. On a **pre-populated p6** (the OTS golden ships a 1.8 GiB p6
   holding ~1.2 GB of docker image tars), the offline `resize2fs` ran in the early uci-default phase
   **before the kernel had re-read the grown partition** (`partprobe`'s `BLKRRPART` is refused while
   the root partition p2 on the same disk is mounted), so it no-op'd and the fs stuck at ~1.7 GiB.
   (session-23 only tested an EMPTY 200 MiB p6, which masked it.) Docker loads then ran out of space.

2. **#159 — the container images were never baked / loaded.** The engine + memcg shipped, but the
   payload container images (~3.3 GB for OTS) were not, so a bare offline node could not obtain them.

## Fix
### #215 grow (95-batman-storage)
- step1b: after `sgdisk`, `partx -u "$DISK"` (updates the single partition's kernel size while
  siblings are mounted, unlike `partprobe`) in addition to `partprobe`.
- **ONLINE ext4 grow in `batdata-mount` `boot()`, right after a successful mount, every boot,
  idempotent, grow-only.** A successful mount proves the kernel sees the partition, so the online
  `resize2fs` reliably grows to the partition size and self-heals across the reboot the GPT grow may
  need — no dependence on early-boot re-read timing. Grows the LUKS mapper first when encrypted
  (#216 M5). The resize failure reason is LOGGED, not swallowed (an online resize refuses on a fs
  needing `e2fsck -f` after an unclean shutdown; silent no-op would be a soft #215 recurrence).

### #159 flash-and-go image (generalized over tenants — #216 decision A)
Baked-tar layout (**#216 G3**, a new convention this PR defines): each payload tenant's docker image
tars ship in p6 at `/opt/batdata/apps/<tenant>/images/*.tar`, with an `images/manifest.sha256`
(sha256sum format) beside them. Tenant config + guardian init ship in `/opt/batdata/apps/<tenant>/`
(guardian init restored to `/etc/init.d` by #192). `scripts/build-ab-image.sh`'s `P6_PAYLOAD=<dir>`
mirrors this layout onto p6 at build (with a size preflight, #216 M9). `refresh_payload_config()`
copies only top-level golden files and does NOT manage the `images/` subdir — tars are baked by the
image build, not golden-refreshed.

`batman-ots-firstload` (batman-payload-host, **START=95**) is generalized to all tenants and hardened:
- **Ordering (corrected — #216 M4):** it runs at S95, i.e. **BEFORE dockerd** (dockerd is also START=99
  and `batman-*` sorts before `dockerd` within S99). It does NOT rely on dockerd at `boot()` time; the
  detached loader **waits on `docker info`**. Do not "fix" the ordering by dropping the wait loop.
- For each tenant with baked tars it sets a **per-boot latch** synchronously in `boot()` before
  stopping that tenant's guardian (see the latch's role below), then stops+disables the guardian
  (removes the confirmed race — its concurrent respawn/docker churn broke the slow ~2.5 min load).
- A single **setsid-detached** master loader (survives boot, never blocks network) processes tenants
  serially (per-load `timeout` bounds one hung tar from starving another and caps concurrent RAM/IO
  on a 2 GB Pi4 — #216 G2/m-load-concurrency):
  - **integrity (#216 M8):** verify each tar's sha256 against `manifest.sha256` before load; a
    mismatch is quarantined immediately (a wrong-arch/substituted tar would otherwise `docker load`
    fine — this is the only defense against it).
  - **offline copy (#216 F2):** on success **`mv` the tar to `images/loaded/`**, never `rm` — on an
    offline `--pull=never` fleet the docker store (same p6, which has a corruption history) must not
    be the sole copy. Clears the tar's fail counter.
  - **bad-tar cap (#216 F1):** a load failure (non-zero / sha mismatch / archive-mv failure)
    increments a per-tar counter and **quarantines** the tar to `images/failed/` after N=3 attempts,
    so a bad tar can NEVER hold the guardian down forever. The completion predicate is "no `*.tar` in
    the images root" (loaded/ and failed/ excluded).
  - re-enables+starts the tenant's guardian once its tars are all loaded/quarantined (restores #192's
    "guardian running" contract, running whatever loaded); otherwise leaves it down to retry next boot.
  - **docker engine never up:** restores the guardian anyway (don't wedge it); the latch stays, and
    **autocommit's docker-liveness core gate — not firstload — decides commit/revert** for a
    docker-broken rootfs (below).

### Layered health model — autocommit gates OS health, not app health (#216 v3, R1/R2)
The root cause behind the review's B1/C1/F1/G1 findings was that `batman-autocommit` (#211) coupled
the OS-commit decision to payload-app drift. On a slow (~300-500 s, sequential 120 s/container)
flash-and-go cold start this is unwinnable: gate strictly → false-revert a good slot for a slow app;
gate loosely → mask a broken one. Industry separates infra-rollback from app-recovery (k8s
liveness/readiness/**startup** probes; deploy-rollback vs app-rollback are different layers). So:

- **autocommit gates ONLY on OS/infra health:** core services (`mesh11sd`/`openmanetd`/`wpad`) + no
  undervoltage + a readable `/etc/batman-build` + **docker ENGINE liveness** (**#216 R1**): when a
  docker tenant exists, `docker info` must succeed, `overlay` must be available, the `memcg`
  controller must be present, and a **canary `docker run`** (a tiny baked busybox, `--network none`)
  must succeed. `docker info` alone is insufficient — a daemon can answer it yet fail `docker run`
  because the new rootfs/kernel silently dropped overlay/memcg/runc (cf. the fleet's brcmfmac
  silent-drop history); such a slot would commit and strand the payload with no rollback. The canary
  degrades to the overlay/memcg feature-probes if its blob is absent, so a missing canary can never
  itself cause a false revert. Canary blob is staged to p6 (`/opt/batdata/canary.tar.gz`) at build,
  not committed to the feed.
- **App/payload health does NOT gate the OS commit.** A tenant that is still doing (or gave up) a
  first-load THIS boot is **non-gating**, signalled by firstload's **per-boot latch**
  `/tmp/batman-firstload-<tenant>.latch` (**#216 R2**). The latch is set synchronously in `boot()` and
  **persists for the whole boot** (tmpfs = per-boot scope), so a slow cold-start after load-done
  cannot re-arm drift-gating and false-revert a good slot. **Steady-state tenants (no latch — images
  already loaded, no first-load this boot) still gate on drift**, so a new rootfs that breaks a
  previously-working app still reverts (#211 preserved). The true first flash-and-go boot is a
  COMMITTED boot (not a trial), so autocommit doesn't run there; the latch matters for a `sysupgrade
  -n` issued during a first-load and for the multi-tenant give-up case.
- **App recovery lives at the app layer** (no reflash, no OS rollback): guardian reconcile (#206),
  firstload cross-boot self-heal, F1 quarantine + run-the-rest, in-field swap (#167/#151). A startup
  grace ("startup-probe" analog) belongs here, not in autocommit. An OS-healthy node also stays on the
  mesh and REACHABLE to receive an app fix — a wrong OS-revert could strand a node that was fine.

## Interactions with existing security-boundary work
firstload only `docker load`s + toggles the guardian; the actual `docker run` still goes through
payload-run/guardian, which carry the #98/#167/#156 fences — the "how tightly fenced once running"
layer is untouched. Intersections: **#151 (signed-image verify)** — firstload adds a new image
ingestion path from an unencrypted p6; **M8's sha manifest is the floor** so this PR doesn't regress
the trust posture (full signed-image verify remains #151). **#192** — the guardian hold-down is a
bounded deviation reconciled in every terminal path (loaded / gave-up / docker-never-up all restore
it). **#211** — refined (payload drift no longer gates during first-load), not regressed (steady-state
unchanged). **#156/#167** — red lines held by the load-only design (firstload never runs a container,
never bypasses the fw4/secret arbiter). **#182** — `PULL_POLICY=never` reinforces the rabbitmq pin.

## Re-validation (fault injection — the coverage the happy-path dogfood missed)
Happy path (reboot ×2 + sysupgrade ×2, zero-touch, daily-validation 17/0/1 + ab-card 22/0) stands.
Required NEW cases before merge:
1. corrupt tar → quarantined to `failed/` after N boots, guardian up on the rest, offline `loaded/`
   copies intact (F1+F2).
2. after a clean load, `docker rmi` one image → recover from `images/loaded/<t>` offline (F2).
3. `sysupgrade -n` during a first-load → autocommit does NOT revert on OTS-not-up; commits on
   OS+canary health (R2/F3).
4. pre-populated-p6 first-boot grow regression in daily-validation (only empty-p6 covered today).
5. from-FEED build (firstload moved overlay → feed) happy path — no regression from the relocation.
6. **docker-broken trial boot** (drop overlay/memcg on the trial slot): canary/core gate fails →
   REVERT, independent of markers/timing (R1).
7. two-tenant bake, one tenant's tar corrupt → isolation: the bad tenant quarantines and the other
   loads; a terminally-failed tenant is non-gating and does not revert a slot healthy for the rest.
8. steady-state (no-tar) sysupgrade trial onto a deliberately-broken app → still gates on drift →
   REVERT (proves #211 steady-state intact).
9. `sysupgrade -n` while a just-first-loaded app is still cold-starting → per-boot latch keeps it
   non-gating through cold-start → commits, no false-revert (R2).

## Known limitation
A steady-state (no-latch) tenant that is legitimately slow to cold-restart can still false-revert
against autocommit's 600 s deadline (pre-existing #211 behavior; the app-layer startup grace does not
cover autocommit's timeout). Documented; a bounded first-OK head-start is possible future work but is
out of scope here (it would reopen the OS/app coupling this rework removed).
