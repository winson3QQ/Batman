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
  partition, expands to fill, ext4, and installs the persistent `batdata-mount` init — with no
  operator. `depersonalise.sh` installs it into `/etc/uci-defaults/` on the golden node,
  alongside the existing `99-halow-identity` hook, so every flashed card self-provisions.
- **`../../overlays/ramoops-fix-overlay.dts`** (#61) — fixes the malformed ramoops
  reserved-memory `reg` so kernel panics get captured. Enabled with a `dtoverlay=ramoops-fix`
  line in the boot partition's config (config.txt / distroconfig.txt) — a boot-partition file,
  **no kernel rebuild**.

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
3. Add `dtoverlay=ramoops-fix` to the boot config; drop the compiled `ramoops-fix.dtbo`.
4. Power off (don't reboot), `dd` the card, `pishrink` → the release image.
5. Every card flashed from it self-provisions storage + captures panics on first boot.

> Still validated only as mechanism (not end-to-end on a golden image): the uci-defaults
> first-boot run, the ramoops overlay on a reflash, and — gated on a dm-crypt image — the LUKS
> path. These are the remaining productization steps for #88/#61/#47.
