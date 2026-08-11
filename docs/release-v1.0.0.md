# HaLow mesh node — v1.0.0 (flash-and-go image)

A ready-to-flash SD-card image for a **Wi-Fi HaLow (802.11ah) mesh node**.
Flash it, plug it into the exact hardware below, change a few settings, and two
or more nodes form a self-healing `batman-adv` mesh. **No compiling** — the
firmware, driver, LED indicator and mesh test are all baked in.

> Based on prebuilt [OpenMANET](https://github.com/OpenMANET/firmware) 1.7.0
> (OpenWrt + Morse Micro driver). This repo adds the LED indicator (`meshled`),
> the layered self-test (`meshtest`), and the provisioning/imaging tooling.

---

## 1. Hardware BOM (must match)

The image is locked to this exact combination — a different Pi or radio will not
boot correctly.

| # | Part | Notes |
|---|------|-------|
| 1 | **Raspberry Pi 4 Model B** (BCM2711) | Pi 5 / Pi 3 not supported by this image |
| 2 | **Seeed WM1302 Pi HAT** | mPCIe → 40-pin carrier |
| 3 | **Seeed Wio-WM6108** (mPCIe) | Quectel FGH100M-H, chip MM6108A1, 902–928 MHz, **SPI** variant |
| 4 | **900 MHz antenna** | matched to the sub-GHz ISM band you deploy in |
| 5 | **microSD card ≥ 8 GB** | class 10 / A1 recommended (32 GB fine) |
| 6 | **5 V power supply, ≥ 3 A** | see ⚠️ below — HaLow TX peaks brown out weak supplies |
| 7 | *(optional)* USB 2.4 GHz Wi-Fi dongle | 2.4 GHz AP is **disabled by default** |

The WM6108 talks to the Pi over **SPI** through the WM1302 HAT; the image's
device-tree overlay already has the correct GPIO mapping (reset=GPIO17,
irq=GPIO5, cs=GPIO8, 50 MHz). No wiring changes needed — seat the HAT and card.

⚠️ **Power:** battery packs and thin cables can't hold the current spike when the
HaLow PA transmits (the red PWR LED will flash 5 Hz = undervoltage, latched).
Use a solid 5 V/3 A mains supply for bring-up.

---

## 2. What's baked in

- **OpenMANET 1.7.0** (rpi4-mm6108-spi): Morse driver, S1G `wpa_supplicant`/`hostapd`, `morse_cli`, `batman-adv` (BATMAN_V), `openmanetd` web UI on :8080.
- **`meshled`** — two-colour status LED (see §6), enabled at boot (`START=99`).
- **`meshtest`** — one-shot six-layer health report at `/root/meshtest` (or `scripts/`).
- Mesh preconfigured: 802.11s + batman, `mesh_fwding=0`, channel 42 = **923 MHz @ 2 MHz**.
- Unique hostname derived from the HaLow MAC on first boot (`halow-c6d3`, …).
- Fresh SSH host keys generated per device on first boot.

### Default values (⚠️ change these before real use)

| Setting | Default | Change to |
|---|---|---|
| root password | **(empty)** | **set one immediately** (`passwd`) |
| mesh id | `halow-mesh` | your own — **identical on every node** |
| mesh SAE key | `halow-changeme` | your own — **identical on every node** |
| 5 GHz onboarding AP SSID | `halow-setup` | optional |
| 5 GHz AP key | `halow-changeme` | your own |
| regdomain / channel | `US` / ch 42 (923 MHz) | **your country — legal requirement** |
| hostname | `halow-<mac4>` (auto) | optional |
| `meshled` `SNR_WEAK` | `20` dB (placeholder) | calibrate by walk-test (§6) |

The image ships with **no authorized SSH keys** — add your own after first login.

---

## 3. Flash the card

1. Download `halow-node-v1.0.0.img.gz` from this release and verify it:
   ```
   sha256sum halow-node-v1.0.0.img.gz   # compare to the value in this release
   ```
2. Write it to the card:
   - **Raspberry Pi Imager** → *Choose OS* → *Use custom* → select the `.img.gz` → *Write*, **or**
   - **balenaEtcher** (select the `.gz` directly), **or** command line:
     ```
     gunzip -c halow-node-v1.0.0.img.gz | sudo dd of=/dev/mmcblk0 bs=4M status=progress conv=fsync
     ```
     (replace `/dev/mmcblk0` with your card device — double-check it!)
3. Insert the card into the Pi (HAT + WM6108 seated), attach antenna, power on.

First boot takes ~30 s. The LEDs do a self-test (both **off 1 s → on 1 s**), then
settle into the live state.

---

## 4. First login & get on your mesh

Reach the node either way:

- **Wi-Fi:** join `halow-setup` / `halow-changeme`, then
  `ssh root@halow-XXXX.local` — **the root password is empty, just press Enter**.
  The `XXXX` is the last 4 of the HaLow MAC; if unsure, `ping halow-*.local`
  won't wildcard — instead connect Ethernet (below) or check your phone's AP list.
- **Ethernet:** patch eth0 to your laptop; the node runs DHCP and hands you a
  `10.41.x.y` — its gateway IP is the node.

**Minimum changes to be secure and join *your* mesh** (run on the node):

```sh
passwd                                   # 1. change root password

uci set wireless.default_radio3.mesh_id='YOUR-MESH-ID'      # 2. your mesh id
uci set wireless.default_radio3.key='YOUR-STRONG-KEY'       #    your SAE key
uci set wireless.radio3.country='TW'                        # 3. your region (legal!)
uci commit wireless

wifi reload                              # apply (or: reboot)
```

Do the **same mesh id + key + region** on every node — that's what makes them
peer. Everything else (hostname, MACs, ULA, IP) is already unique per device.

Add your SSH key so you don't need the password again:
```sh
# from your laptop:
ssh-copy-id root@halow-XXXX.local        # or paste your pubkey into
                                         # /etc/dropbear/authorized_keys
```

---

## 5. Verify the mesh

Power on **two** nodes (flashed from this same image), 3–5 m apart — **not**
side by side (at 27–30 dBm within a metre they overload each other's front end).
Then on either node:

```sh
sh /root/meshtest        # six-layer report; last section that prints = the layer that works
```

Expect: `802.11s plink ESTAB`, `batman 鄰居 1`, `batctl ping 5/5`, and a
`✅ 組網成功` verdict. `batctl tp` shows real throughput (~2–3 Mbps at 2 MHz BW).

Being able to `ssh root@<other-node>.local` **through** one node is itself proof
the mesh formed.

---

## 6. LED indicator (`meshled`)

One rule: **solid = good, faster blink = worse.** Red = system layer, green =
HaLow layer; green stays dark until red is OK.

| 🔴 PWR | meaning | 🟢 ACT | meaning |
|---|---|---|---|
| solid | all checks pass | solid | **LINKED** — peer up, SNR strong |
| 1 Hz | booting (<90 s) | 100/1900 (5 %) | WEAK — linked but low SNR → adjust antenna |
| 2.5 Hz | system fault | 1 Hz | NO_BATMAN — peered but no batman route |
| 5 Hz (latched) | undervoltage | 2.5 Hz | ALONE — radio up, no peer found |
| wink (dip/5 s) | meshled not managing | 5 Hz | RF_DEAD — radio down |
| — | — | off | system layer not OK |

**Green is SNR-driven** (per-peer signal − noise). To calibrate the WEAK/LINKED
threshold for your antennas: walk one node away, note the SNR
(`meshled status`) where green goes solid→blinking, and set `SNR_WEAK` a couple
dB above it:
```sh
sed -i 's/^SNR_WEAK=.*/SNR_WEAK=<dB>/' /usr/bin/meshled && /etc/init.d/meshled restart
```

---

## 7. Two- (or more-) node quick start

1. Flash N cards from this one image.
2. On each: `passwd`, set the **same** `mesh_id` + `key`, set your `country`, `wifi reload`.
3. Power them on, spaced out. They auto-peer (unique hostnames happen by themselves).
4. `sh /root/meshtest` on any one to confirm.

---

## 8. License & attribution

- **This repo's scripts/docs:** MIT (patches GPL-2.0-or-later as noted).
- **Bundled firmware:** OpenMANET 1.7.0 → OpenWrt (GPL-2.0) + Morse Micro
  driver. The image redistributes their GPL binaries; corresponding sources are
  at <https://github.com/OpenMANET/firmware> and the OpenWrt project. Credit and
  thanks to OpenMANET and Morse Micro.

## 9. Known limitations

- **Hardware-locked** to the BOM in §1.
- **Ships open** — the root password is **empty** and no SSH keys are baked in
  (OpenMANET factory style), and the mesh key is a shared default. Until you set
  a password (§4 step 1) and your own mesh key, anyone on the network can root a
  freshly-booted node. Do it immediately; treat first boot as a provisioning
  step on a trusted network.
- **`SNR_WEAK` is an uncalibrated placeholder** (20 dB) — fine to run, calibrate
  per antenna set for accurate WEAK warnings.
- **Regulatory:** channel 42 / country `US` is a default, not advice. Setting the
  correct regdomain and confirming TX power limits for your country is your
  responsibility.
- HaLow at 2 MHz tops out around 2–3 Mbps goodput — this is a low-rate, long-
  range link, not a Wi-Fi replacement.
