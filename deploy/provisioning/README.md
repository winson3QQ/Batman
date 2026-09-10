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
