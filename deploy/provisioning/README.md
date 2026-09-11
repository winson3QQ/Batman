# Storage provisioning skeleton (#88) — test plan

Validates the **storage mechanics** of the #88 partition scheme on real hardware, decoupled
from the deferred security layers (verity #74 / real key #47). See
[storage-architecture.md](../../docs/storage-architecture.md).

## What it proves
1. Carve a data partition in the SD's **free space** (never touching boot/root).
2. **LUKS** format + open (with a **placeholder** key — not production).
3. **ext4** + **expand-to-fill** (partition = all free space, so it auto-sizes to the card).
4. **Reboot persistence** (a boot hook unlocks + mounts).
5. **Idempotency** (re-run = no-op) and a clean **teardown**.

## Setup (you do this)
1. Flash the OpenMANET image onto the **spare SD card**.
2. Power down **manet01**, remove its own card (**set it aside** — untouched), insert the spare.
3. Boot manet01 on the spare card. It comes up like a fresh node (p1 boot, p2 root, free space).
4. Tell me it's up (or give SSH); the target board is **Pi 4** (manet01's Pi). **manet02 is never touched.**

## Run (I do this, on the spare card)
```sh
opkg update && opkg install parted cryptsetup e2fsprogs   # deps (needs 借網)
sh firstboot-provision.sh --status      # dry look
sh firstboot-provision.sh --yes         # provision
# reboot, then:
sh firstboot-provision.sh --status      # expect: data part + LUKS yes + mounted yes (auto)
sh firstboot-provision.sh --yes         # expect: all steps "skipping (idempotent)"
```

## Pass criteria
- [ ] data partition created in free space; p1/p2 untouched
- [ ] LUKS opens with the key; ext4 fills the partition (= card capacity, expand-to-fill)
- [ ] survives reboot: boot hook auto-unlocks + mounts, marker file intact
- [ ] second run is a clean no-op (idempotent)
- [ ] `--teardown --yes` removes it cleanly (test card is disposable anyway)

## Explicitly NOT tested here (deferred)
- **GPT 5-partition scheme** — skeleton makes ONE data partition (MBR-safe, free space only);
  the full p1..p5 GPT layout + boot-disk conversion is the next layer (#88 §B1).
- **dm-verity signed rootfs** (#74 / §B2) and **repackaging code into the signed slot**.
- **Real key sealing** (#47 / §B3) — uses a placeholder key on rootfs (would be "theatre" in
  prod); replaced by SE-sealed release once the hardware exists.

## Safety
The script refuses to run unless the disk has exactly 2 partitions (p1/p2) + free space,
only ever creates/removes its own partition in the free space, and is idempotent. Worst case
it damages the **disposable spare card**, never manet02.

---

# Production integration (golden-master, **no rebuild**)

The interactive `firstboot-provision.sh` above is for *validating* the mechanics. Production
bakes the same logic into the image the OpenWrt way — **no OpenWrt source build**, just files
captured into the golden image (the same model Batman already uses for meshled/meshtest):

- **`uci-defaults/95-batman-storage`** — the productionised first-boot hook (OpenWrt runs
  `/etc/uci-defaults/*` once on first boot, then deletes each on success). It carves the data
  partition, expands to fill, ext4 (never reformats an existing filesystem), and installs the
  persistent **`batdata-mount`** init (S11, before logd) — with no operator. That init also
  carries the crash/reboot capture (#61): pstore records → `/opt/batdata/crash/`, a per-boot
  reason line + clean-shutdown syslog dump → `/opt/batdata/log/` (see
  docs/storage-architecture.md "Logs & crash"). `depersonalise.sh` installs the hook into
  `/etc/uci-defaults/` on the golden node, alongside the existing `99-halow-identity` hook, so
  every flashed card self-provisions.
- **`fix-ramoops-dtbo.sh`** (#61) — fixes the malformed ramoops reserved-memory `reg` in the
  image's `/boot/overlays/ramoops.dtbo` so kernel panics get captured (needs `dtc` while
  running; remove it afterwards). A boot-partition file edit, **no kernel rebuild**.
- **`meshpoint-1.8.0.sh`** — the post-wizard **Mesh Point + bridge** baseline for OpenMANET 1.8.0
  without the LuCI wizard (HaLow mesh on `radio1`, batman-adv `bat0`/`batmesh0`, `br-ahwlan`,
  mesh11sd trio, firewall zone, dnsmasq). Parameters: mesh id, key, channel (40 = 4 MHz), country.
  Addressing stays OpenMANET's two-stage scheme (bootstrap 10.41.254.x, openmanetd reserves the
  real IP on first boot and reboots once) — #11 decision; nodes are found by `<hostname>.local`.
- **`halow-keyguard.init`** (#103) — S18 guard: while the mesh SAE key or an onboarding-AP key is
  still the public placeholder `CHANGE-ME-NOW`, that radio/AP is kept disabled (committed) and
  meshled shows red; Ethernet is never touched. **`halow-setkey`** is the one door: sets/rotates
  the keys, releases exactly what the guard disabled, reloads wifi. Batch keys are normally baked
  at image time (`depersonalise.sh --mesh-key/--ap-key`); the guard only catches "public image
  flashed, no key set".
- **`batpower` + `batpower.init`** (#122, S95) — battery watchdog: reads pack voltage/current
  (`hwmon` via the kernel ina2xx driver, raw `i2c`, or `mock` for the bench), per-cell WARN /
  CRIT thresholds with confirm count + hysteresis; WARN → syslog/kmsg/`/tmp/batpower.state`,
  CRIT → shutdown marker (so `boot-reasons.log` says `low-battery Vbat=…`) then `halt`
  (`crit_action=reboot` on the bench). No steady-state SD writes. uci `batpower.main.*`;
  `batpower status`. Ships with `source=mock` until the INA226 is fitted — then set `source`
  to `hwmon` (+ `kmod-hwmon-ina2xx`, `dtoverlay=i2c-sensor,ina226`) or `i2c`.
- **`flightrec` + `flightrec.init`** (#105, S99) — flight recorder: a heartbeat line every
  60 s (uci `flightrec.main.interval`) into `/dev/kmsg` (load, free memory, batman peers,
  802.11s plinks, battery state, throttle flags, SoC temperature). With ramoops console capture
  on (`fix-ramoops-dtbo.sh` step 1, the single owner of that edit; `depersonalise.sh` calls it
  with `--console-only`) the kernel log — heartbeats included — survives a warm reset, and the
  next boot saves it under `crash/` and classifies the boot (crash-debug.md §1/§3b). The
  software stand-in for the USB-UART serial console. Zero SD writes in steady state.
- **No steady-state SD writes (#104):** `depersonalise.sh` sets openmanetd's `dbFile:` to
  `/tmp/openmanetd.db` — its SQLite WAL was the only steady writer on the rootfs overlay.
- **`joinwatch` + `joinwatch.init`** (#127, S98) — "a node that cannot join must say why".
  Polls the join layers (radio up / mesh mode / key SET-PLACEHOLDER-NONE / keyguard / plinks /
  stations heard / batman neighbours / mesh11sd / address stage) and, only while NOT joined,
  writes a one-line diagnosis with a human verdict (e.g. *radio meshing, NO PEER HEARD* or
  *peers seen but no plink — key/mesh_id mismatch likely*) to `/opt/batdata/log/join.log`
  `t_short` (60 s — before an impatient user power-cycles) and `t_full` (5 min) **into an
  unjoined episode** (measured from the first unjoined poll, so a node that drops after hours
  of service is diagnosed the same way; at most 3 episodes per boot), then a `JOINED` line
  closing the episode — also when the episode was left open by an earlier boot the user
  power-cycled out of. Never touches the radio config. Automatic reboot: only after
  `t_reboot` (60 min) into the episode, **only when the verdict is something a reboot can
  fix** (a placeholder key, a disabled radio/mesh11sd, or a lone node that hears nobody are
  not — the first node switched on at a site is not a fault), **never when ≥
  `unjoined_boots_max` (3) consecutive boots did not join** (a human is already
  power-cycling), and at least `reboot_gap_boots` (5) boots after the previous automatic one
  (found by its `AUTOREBOOT` boot id in `boot-reasons.log`). **No RTC / no NTP in the field →
  every decision is made on boot ids/counts and uptime deltas, never on wall-clock time**
  (timestamps in the logs are decoration). Writes only when `/opt/batdata` is mounted
  (otherwise syslog/kmsg only — never the rootfs overlay). uci `joinwatch.main.*`;
  `joinwatch status|diag`. **Already-provisioned nodes:** the shutdown-reason reader lives in
  the *generated* `batdata-mount` init, so after updating the hook run
  `umount /opt/batdata && sh /etc/uci-defaults/95-batman-storage` once (fresh cards get it
  on first boot).
- **`halow-status`** — the one-page incident report (node, image, boot id, last boot reason,
  JOIN state + last diagnosis, battery/throttle/temp, boots since the last join (and how
  many of them were power loss — the "user keeps power-cycling" signature), last 3 boot
  reasons, evidence counts). No secrets (keys shown as SET/PLACEHOLDER). `halow-status json`.
- **`www/status`, `www/bundle`** → `/www/cgi-bin/status`, `/www/cgi-bin/bundle` — the same
  report over HTTP for a **phone on the onboarding AP** (SSID = hostname) or a laptop on the
  M12/Ethernet port: `http://<hostname>.lan/cgi-bin/status` (mobile page, 15 s refresh,
  `?json` for #14/EMS/a future PWA or ATAK plugin) and `/cgi-bin/bundle` (tar.gz with
  status, boot-reasons, join.log, last crash records, last shutdown dumps, dmesg, logread —
  the attachment for a field report). Read-only, generated on request, no SD writes; write
  actions stay behind SSH/Ethernet until #52 RBAC.

## What golden-master files can and cannot do

| Change | Mechanism | Rebuild? |
|---|---|---|
| First-boot storage provisioning (#88) | `uci-defaults` file in the image | **No** |
| ramoops DT fix (#61) | `dtoverlay=` + .dtbo on the boot partition | **No** |
| **LUKS at-rest encryption (#47)** | **`CONFIG_DM_CRYPT` — a kernel feature** | **Yes** — kernel/image rebuild (or OpenMANET upstream). Until then the first-boot hook provisions **unencrypted** (loud syslog warning). |

## Golden-master flow
1. Configure a reference node; stage this repo on it.
2. Run `scripts/depersonalise.sh` — installs the identity + storage first-boot hooks, strips
   secrets, resets defaults.
3. Run `fix-ramoops-dtbo.sh` (fixes `/boot/overlays/ramoops.dtbo` in place).
4. Power off (don't reboot), `dd` the card, `pishrink` → the release image. (Full SOP incl. the
   no-card-reader flash trick: docs/golden-image.md.)
5. Every card flashed from it self-provisions storage + captures panics + logs a reason for
   every reboot, from first boot.

> Validated end-to-end on a fresh flash of a golden image (OpenMANET 1.8.0 / Pi 4, 2026-09-11):
> the uci-defaults first-boot run, ramoops on the reflashed card, pstore flush, clean-shutdown
> dump + boot reason. Still gated on a dm-crypt image: the **LUKS** path (#47).
