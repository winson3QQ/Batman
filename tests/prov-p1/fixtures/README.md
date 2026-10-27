# tests/prov-p1/fixtures

- `batman-slot.1.5.12-wsl.9` — `/usr/sbin/batman-slot` as shipped in 1.5.12-wsl.9 (sha256 `31fcf430…ee5aba`), copied
  from that image's rootfs. `scripts/dv/chain1-254.sh` step 6 bind-mounts it as the negative control of the stage-1
  "not seeded" gate (L44): that version has no gate, so a gated OTA must go through with it. Never install it.
