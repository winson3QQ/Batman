# Frequency hopping — bottom-to-top feasibility test record

Issue: [#177](https://github.com/winson3QQ/Batman/issues/177). Date: 2026-09-18. Nodes: manet01 (BCM2711-47ee, live OTS host) + manet02 (BCM2711-45d7). Radio: Morse Micro MM6108 HaLow on `wlh0`, 8 MHz BW, US regdomain. Mesh: batman-adv 2025.4 (BATMAN_V) over the HaLow link.

**Question.** The fast-retune primitive (`morse_cli channel`) is known to work; does the **whole stack** (PHY → mac80211 → batman-adv → IP → app) follow a retune, and does a **coordinated hop drop packets** under a continuous voice-like stream?

**Answer.** GO for *slow coordinated channel agility* (< ~10 hops/s). The stack is transparent to a `morse_cli channel` retune, mesh peering is frequency-agnostic and survives a coordinated hop, and per-hop packet loss equals the **hop-alignment skew** — nothing else. It is not fast FHSS (the real retune costs ~170 ms).

## Method

- **Retune primitive only:** `morse_cli -i wlh0 channel -c <freq_kHz> -o <opBW> -p <primBW> -n <idx>`. **Never `wifi reload`** (that is a different vif-teardown path, suspected in an earlier hard hang — see #177).
- **Home / rendezvous channel:** 924 MHz / 8 MHz (`-c 924000 -o 8 -p 2 -n 3`). **Hop target:** 916 MHz / 8 MHz (non-overlapping 8 MHz passband → a clean partition when only one node is there).
- **Out-of-band control:** manet01 is driven over **ahwlan** (10.41.167.12, the AP interface), which is independent of `wlh0`, so SSH control survives the mesh partition a hop creates.
- **Safety:** every script traps EXIT/INT/TERM and restores 924, plus an explicit final restore; the 2-node script adds a hard re-assert after reconnect.
- **On-node timing constraint:** the image has no `usleep`, no compiler, no python/perl, and busybox `sleep` rejects fractional seconds and its arithmetic rejects `base#n` radix. Sub-second dwell is therefore done with a `/proc/uptime` busy-wait timer (10 ms resolution; `1`-prefix trick to avoid octal parsing of the centisecond field).

Scripts (in `scripts/`, run on the node):

| Script | What it does |
|---|---|
| `hop_single.sh` | single node: move manet01 924→916→924, sample every layer (PHY / mac80211 / dmesg / batman-adv / IP / OTS) + data-plane ping to the peer |
| `hop2node.sh` | runs on **each** node: self-scheduled coordinated 924→916→924 hop with triple restore net; paired with an iperf2 UDP voice-like stream to measure per-hop loss |
| `dwell_sweep.sh` | single node: `/proc/uptime` busy-wait timer; 30 rapid real channel changes per dwell tier (1000/500/200/100/50 ms); checks dmesg errors + mesh-vif survival after each tier |

## Results

### A. Single node — the stack is transparent to a retune

| Layer | Observation | Meaning |
|---|---|---|
| L0 PHY | retune returns in ~0.07 s (incl. readback); freq lands correctly | chip retune ≈ instant for a same-freq set |
| L2 mac80211 | `iw dev wlh0 info` reports a bogus **channel 161 / 5805 MHz / 160 MHz** (a 5 GHz value HaLow cannot use), unchanged before/after | **`morse_cli channel` never touches cfg80211**; mac80211's channel is a frozen placeholder, not the source of truth |
| L1 driver | dmesg delta **empty** across the retune (no `morse/wlh0/batman/sae/crypt/peer`) | pure register op; no re-init, no SAE/crypto re-handshake |
| L2.5 batman-adv | peer originator **never purged** over ~120 s off-channel (last-seen grew 1.6 → 121 s) | tolerance ≫ any hop guard → would not notice a real hop |
| recovery | on return to 924, **first data-plane ping = OK** (< 0.1 s); `batctl o` last-seen counter lagged ~10 s but forwarding did not wait | forwarding resumes as soon as both radios share a channel |
| L3 app/mgmt | OTS 6 containers up throughout; ahwlan SSH never dropped | app/control plane decoupled from the HaLow channel |

### B. Two-node coordinated hop — peering survives; loss = skew only

Voice-like UDP (iperf2 UDP, 200-byte datagrams @ ~62 pps ≈ 16 ms spacing), manet02 → manet01. Both nodes self-scheduled a 924→916→(2 s)→924 hop, launched near-simultaneously via parallel SSH (**no time sync — hops hand-aligned**).

| Window | Event | Loss | Note |
|---|---|---|---|
| 0–6 s | both on 924 | 0 % | baseline |
| **6–7 s** | hop → 916 | **4 pkts ≈ 64 ms** | alignment error of the two "away" retunes |
| 7–8 s | **both on 916** | **0 %** | **mesh fully operational on the NEW channel** |
| **8–9 s** | hop → 924 | **18 pkts ≈ 288 ms**, jitter 19.5 ms | alignment error of the two "back" retunes |
| 9–20 s | both on 924 | 0 % | fully recovered |
| **total** | | **22 / 1253 = 1.8 %** | all loss at the two transition edges |

Internally consistent: manet01 away-dwell 2.29 s vs manet02 2.02 s → **270 ms skew** ≈ the 288 ms back-hop loss. **dmesg on both nodes: zero `sae/peer/crypt/deauth/disassoc`.** Both restored to 924; peer re-converged (last-seen 0.45 s, throughput 31, peers=2); OTS healthy.

### C. Dwell sweep — real retune cost + rapid-hop robustness

| dwell | 30 real hops, wall | achieved hop rate | mesh vif | dmesg errors |
|---|---|---|---|---|
| 1000 ms | 35.3 s | 0.85 /s | ok | 0 |
| 500 ms | 21.2 s | 1.42 /s | ok | 0 |
| 200 ms | 11.5 s | 2.61 /s | ok | 0 |
| 100 ms | 7.6 s | 3.97 /s | ok | 0 |
| **50 ms** | **6.1 s** | **4.95 /s** | ok | **0** |

- **Same-freq set ≈ 6 ms; a real frequency change blocks ~150–205 ms (avg ~170 ms, PLL relock).** The earlier "~1 ms retune" figure was a no-op set, not a real channel change.
- **Rapid hopping is driver-robust:** 30 consecutive real hops at every dwell down to 50 ms → **0 dmesg errors, mesh vif intact, clean return**. The `morse_cli channel` path does **not** reproduce the `wifi reload` wedge even under rapid hammering — reverse evidence that the earlier hang lives in the vif-teardown path, not in retuning.
- **Hop-rate ceiling ≈ 5 hops/s**, bounded by the ~170 ms retune, not by dwell.

## Synthesis (two numbers, do not conflate)

- **Retune command blocks ~170 ms** (single node, PLL relock).
- **Coordinated-hop blackout ≈ 64 ms = alignment skew**, *not* 170 ms — because both radios retune **in parallel**; the 170 ms is paid concurrently, so link-down time ≈ the nodes' misalignment, not one retune.

Therefore:
- **Packet loss** is governed by **alignment skew** → minimise with time sync (#174 / GPS-PPS).
- **Hop rate** is governed by the **~170 ms retune** → single-radio HaLow ceiling ≈ 5 hops/s. Faster needs a second radio (make-before-break).
- Design shape: **slow coordinated channel agility** (coexistence / DFS-like avoidance / slow jam-evasion), not Bluetooth-style fast FHSS.

**To not drop packets under continuous voice:** (a) shrink skew via a shared time base (GPS/PPS) so hops land together; (b) absorb the residual with a de-jitter buffer ≥ residual skew (20–60 ms is inaudible) + codec FEC/PLC (Opus/Codec2) for the few edge packets.

## Reproduce

```sh
# single-node layer walk (control via ahwlan; auto-restores 924)
scp scripts/hop_single.sh root@<ahwlan-ip>:/tmp/ && ssh root@<ahwlan-ip> sh /tmp/hop_single.sh

# dwell sweep (single node)
scp scripts/dwell_sweep.sh root@<ahwlan-ip>:/tmp/ && ssh root@<ahwlan-ip> sh /tmp/dwell_sweep.sh

# 2-node coordinated hop: orchestrator runs from the management host (drives m01 via
# ahwlan out-of-band, m02 via mesh); stages hop2node.sh on both, runs the iperf UDP
# stream, launches the hops near-simultaneously, collects loss.
M01=<m01-ahwlan-ip> M02=<m02-mesh-ip> bash scripts/run_2node.sh
```

The 2-node coordination here is deliberately crude (parallel SSH launch, no shared clock)
— it emulates an imperfect schedule so the loss reveals the alignment skew. A production
mechanism replaces this with a shared-clock schedule (see "Not tested", item 2).

## Not tested (honest gaps → next steps)

1. **Time sync (#174 → GPS/PPS).** Hops were hand-aligned via SSH (skew ~hundreds of ms). A shared clock would push skew to sub-ms and loss toward zero. This is the primary lever; the skew→loss relationship measured here quantifies why.
2. **Real shared-clock schedule + multi-hop endurance.** Only one hop pair was run. A production mechanism derives the same channel sequence on both nodes from `f(shared seed + common time index)` and runs continuously; endurance (hundreds/thousands of hops) would measure drift-to-desync time and any sustained-hopping degradation. A no-sync "drift-rate" pre-phase can bound the sync budget without GPS.
3. **Range / marginal SNR + sub-100 ms dwell.** All tests were near-field best-case (RSSI −37…−43 dBm). At marginal SNR re-acquisition after a hop may be slower/unreliable. Sub-100 ms dwell was shown not to *crash* the driver, but throughput/voice quality under fast dwell is unmeasured — rate-control and A-MPDU need on-channel settle time.
4. **Use case** (jam-resistance / coexistence / DFS) not yet fixed — it sets the required dwell, sequence, and whether a second radio is warranted.
