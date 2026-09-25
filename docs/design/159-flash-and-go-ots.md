# #159 flash-and-go OTS + #215 first-boot grow fix

Status: proposed (validated as a dev bake on manet04; see "Validation"). Needs adversarial review
before merge. Companion issues: #159 (docker-in-image), #215 (first-boot grow bug), #202 (config
survival), #201 (first-boot grow).

## Problem
A freshly-flashed card should boot into a working OTS host with **zero operator steps** ("插上卡即
可用"). Two gaps blocked this:

1. **#215 — the ext4 never grew.** #201's `95-batman-storage` grows the GPT p6 to fill the card with
   `sgdisk -e`, then resizes the ext4. On a **pre-populated p6** (the OTS golden ships a 1.8 GiB p6
   holding ~1.2 GB of docker image tars), the offline `resize2fs` ran in the early uci-default phase
   **before the kernel had re-read the grown partition** — `partprobe`'s `BLKRRPART` is refused while
   the root partition (p2) on the same disk is mounted — so it no-op'd, and the one-shot hook was
   consumed with the fs stuck at ~1.7 GiB. (session-23 only tested an EMPTY 200 MiB p6, which masked
   it.) Docker loads then ran out of space.

2. **#159 — the container images were never baked / loaded.** docker-in-image (#159 layer 1: the
   engine + memcg) shipped, but the OTS container images (~3.3 GB) were not, so a bare offline node
   could not obtain them.

## Fix
### #215 grow (95-batman-storage, feed + deploy copies)
- step1b: after `sgdisk`, use `partx -u "$DISK"` (updates the single partition's size in the kernel
  and works while siblings are mounted, unlike `partprobe`) in addition to `partprobe`.
- **Move the ext4 grow to an ONLINE resize in `batdata-mount` `boot()`, right after a successful
  mount, every boot, idempotent.** A successful mount proves the kernel sees the partition, so the
  online `resize2fs` reliably grows to the partition size; running it every boot self-heals across
  the reboot that the GPT grow may need. This does not depend on early-boot re-read timing.

### #159 flash-and-go image
- The OTS golden bakes the 3 OTS docker image tars into p6 at `/opt/batdata/otsimg/` and the tenant
  config + guardian init into `/opt/batdata/apps/opentakserver/` (restored to `/etc/init.d` by
  #192). `scripts/build-ab-image.sh` gains an optional `P6_PAYLOAD=<dir>` that populates p6 at build.
- `batman-ots-firstload` (new, batman-payload-host, START=95 — after dockerd, before the guardian at
  START=99, enabled via a baked rc.d link): once p6 has tars, it **stops+disables the guardian**
  (removing the confirmed race — the guardian's concurrent respawn/docker churn broke the slow
  ~2.5 min batman/ots load), loads the tars in a **setsid-detached** subshell (survives boot,
  never blocks network), removes each tar only on a successful load, then re-enables+starts the
  guardian once ALL images are loaded. Per-boot and idempotent: no tars -> no-op; incomplete ->
  retries next boot.
- `payload-run`: `docker run --pull=never` — offline fleet nodes must never attempt a registry pull;
  a missing image now fails fast/clean instead of hanging on an offline pull.

## Validation (dev bake, manet04, 2026-09-25)
Fresh flash of the OTS golden, then reboot ×2 and sysupgrade ×2 (same version), all zero-touch:
- #215: boot trace `batdata-mount: p6 ext4 online-resized`; p6 -> 25.4 G on first boot.
- firstload: loaded all 3 images (self-healed across an external reboot mid-load), guardian held off,
  OTS 6/6 + postgres.
- config + OTS survived both A/B OTA cycles (#202 seed in p5; images in p6); #211 autocommit each.
- daily-validation (OTS=04, MESH=02) = 17 pass / 0 fail / 1 skip; ab-card (WSL) 22/0.

## Open items / review asks
- firstload was validated as a firmware-fork `files/` overlay; this PR moves it into the feed —
  re-validate a from-feed build before merge.
- guardian disable/enable by firstload deviates from #192's "always restore guardian running" on the
  first-load boot(s); confirm the interaction is acceptable.
- `--pull=never` changes the GENERIC payload manager for all tenants (correct for the offline fleet;
  documented here).
- add a daily-validation regression: pre-populated-p6 first-boot grow (only empty-p6 is covered).
