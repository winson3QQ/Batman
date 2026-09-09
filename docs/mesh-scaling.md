# Mesh scaling — how many nodes fit?

**The answer is a limit per collision domain, not a limit on network size.** A MANET
spread over kilometres can hold hundreds of nodes; what saturates is any one radio's
neighbourhood. Roughly **40–50 nodes in mutual earshot** is where the 4 MHz channel runs
out of airtime, and **beacons are over half of that cost**.

Model: [`../scripts/mesh-scale-model.py`](../scripts/mesh-scale-model.py) — re-run it with
different parameters rather than trusting the table below.

## Measured inputs

Every constant comes from this link, not a datasheet. Measurements in
[`field-test-log.md`](field-test-log.md).

| quantity | value | how it was measured |
|---|---|---|
| unicast data airtime | `240 us + L_bits / 14.5 Mbps` | fitted to a 5-point payload sweep; predicts 988 pps at 1400 B against 991 measured |
| beacon size | **189 B**, 0.92/s | captured off-air in monitor mode, constant across 35 frames |
| mgmt frame bandwidth | **1 MHz** | driver log: `find_tx_bw_for_mgmt_frame: considering 1 MHz for mgmt frame` |
| 1 MHz MCS0 rate | 0.30 Mbps | `mmrc_table` index 0 |
| 4 MHz MCS0 rate | 1.35 Mbps | `mmrc_table` index 4 |
| `elp_interval` | 500 ms | `/sys/class/net/wlan1/batman_adv/elp_interval` |
| `orig_interval` | 1000 ms | `batctl orig_interval` |
| `beacon_int` | 1000 TU (1.024 s) | `mesh-wlan1.conf` |

Derived per-frame airtime:

```
beacon  5680 us      <- 189 B at 1 MHz MCS0
OGM      833 us
ELP      684 us
1400 B unicast data   1012 us
```

**One beacon costs the airtime of 5.6 full-size data frames.** That single line explains
most of what follows.

## Result

Nodes in one collision domain, control traffic capped at 50% of airtime:

| scenario | nodes |
|---|---|
| mesh control only (beacon + ELP + OGM) | **54** |
| + 1 CoT position report/s per node | 52 |
| + #14 all-to-all poll every 60 s | 46 |
| + #14 all-to-all poll every 30 s | **42** |
| + #14 all-to-all poll every 10 s | 33 |
| + #14 all-to-all poll every 5 s | 27 |
| worst case: OGM rebroadcast network-wide | **18** |

Where the airtime goes at n=50, `beacon_int` 1000 TU, polling every 30 s:

```
beacon         27.7% of a second   53% of control overhead
#14 poll       11.1%               21%
batman ELP      6.8%               13%
batman OGM      4.2%                8%
CoT             2.0%                4%
               -----
total          51.9%
```

## What this changes

**Beacons dominate, not application traffic.** CoT is 4% of overhead — position reporting
is free at this scale. An earlier reading of #14 as the main scaling risk was wrong: at a
30 s poll interval it is 21%, real but affordable. It only becomes crippling below ~10 s.

**`beacon_int` is the single biggest lever.** Doubling it from 1000 to 2000 TU takes the
ceiling from 42 to 54 nodes — a 29% gain from one config value. Tracked separately, because
it trades against node discovery and link-loss detection latency, which matters for mobile
nodes.

| `beacon_int` | period | nodes |
|---|---|---|
| 1000 TU (today) | 1.02 s | 42 |
| 2000 TU | 2.05 s | 54 |
| 5000 TU | 5.12 s | 64 |
| 10000 TU | 10.24 s | 68 |

**Design rules that fall out of this:**

- Poll interval for #14 should be **>= 30 s**, and gossip rather than all-to-all once the
  neighbourhood is large — the O(N^2) term is what bites, not the per-poll cost.
- Anything periodic and broadcast is expensive. Budget in **packets per second and airtime**,
  never in kbps — see the packet-rate ceiling in `field-test-log.md`.
- 40 nodes spread over a valley is fine. **40 nodes in one square is the problem**, and
  rallies and exercises are exactly that case.

## Assumptions, and the one that needs verifying

- **Beacons are sent at 1 MHz MCS0.** This term is over half the answer. It rests on the
  driver's own log line about management frames using 1 MHz plus the `mmrc_table` rate — the
  beacon's airtime was **not** measured directly. If beacons actually go out faster, the
  ceiling rises substantially.
- ELP and OGM are modelled at the 4 MHz basic rate. `enable_mcast_rate_control=Y` is set, so
  the driver may do better than MCS0 here.
- Single collision domain, no spatial reuse — conservative for airtime, but it also means no
  OGM forwarding is needed. A spread-out multi-hop network pays the forwarding cost and gets
  spatial reuse back; the two pull in opposite directions.
- 85% of a second is assumed usable after CSMA overhead.

**To verify the beacon assumption**: raise `beacon_int` to 5000 TU on both ends and check
whether throughput and airtime improve by the predicted margin. It needs both ends changed
and there is currently no wired lifeline if the node does not come back, so do it with
physical access — see the same warning in #39.
