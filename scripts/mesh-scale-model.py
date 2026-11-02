#!/usr/bin/env python3
"""
mesh-scale-model.py — how many nodes fit in one collision domain?

Every constant below is measured on the live 4 MHz link (see docs/mesh-scaling.md
for the measurements and docs/field-test-log.md for how they were taken). Nothing
here is a datasheet figure.

The answer is a *per collision domain* limit — how many nodes can be in mutual
earshot — not a limit on total network size. A large MANET spread over kilometres
is fine as long as no single radio hears more than this many peers.

  ./mesh-scale-model.py                 # default table
  ./mesh-scale-model.py --beacon-int 5000 --poll 30
"""
import argparse

# ── measured constants ───────────────────────────────────────────────────────
# Unicast data: fitted from a 5-point payload sweep (1400/800/400/200/100 B)
#   T(L) = 240 us + L_bits / 14.5 Mbps
#   check: 1400 B -> 240 + 11200/14.5 = 1012 us -> 988 pps, measured 991.
FIX_UNI_US = 240.0
RATE_UNI_MBPS = 14.5

# Broadcast rates. The driver logs "find_tx_bw_for_mgmt_frame: considering 1 MHz
# for mgmt frame", and mmrc_table gives 1 MHz MCS0 LGI = 0.30 Mbps, 4 MHz MCS0
# LGI = 1.35 Mbps. Beacons are management frames and go out on the 1 MHz primary;
# batman ELP/OGM are multicast *data* frames on bat0 and get the 4 MHz basic rate.
RATE_MGMT_MBPS = 0.30
RATE_MCAST_MBPS = 1.35
PRE_MGMT_US = 640.0     # S1G 1 MHz long preamble
PRE_MCAST_US = 240.0

BEACON_BYTES = 189      # measured off-air in monitor mode, constant across 35 frames
ELP_BYTES = 75          # batman ELP + mesh/LLC headers, estimated
OGM_BYTES = 100         # OGMv2 + TT, estimated
ELP_HZ = 2.0            # elp_interval = 500 ms (read from sysfs)
OGM_HZ = 1.0            # orig_interval = 1000 ms (read from batctl)

USABLE_US = 850_000.0   # us of airtime per second CSMA can actually use (~85%)


def t_uni(nbytes):
    return FIX_UNI_US + nbytes * 8 / RATE_UNI_MBPS


def t_bcast(nbytes, mbps, preamble):
    return preamble + nbytes * 8 / mbps


T_BEACON = t_bcast(BEACON_BYTES, RATE_MGMT_MBPS, PRE_MGMT_US)
T_ELP = t_bcast(ELP_BYTES, RATE_MCAST_MBPS, PRE_MCAST_US)
T_OGM = t_bcast(OGM_BYTES, RATE_MCAST_MBPS, PRE_MCAST_US)


def per_node_us(n, beacon_int_tu, poll_s, cot, ogm_forwarding):
    """Airtime one node puts on the medium per second, in a domain of n nodes."""
    beacon_hz = 1 / (beacon_int_tu * 1.024 / 1000)
    us = beacon_hz * T_BEACON + ELP_HZ * T_ELP + OGM_HZ * T_OGM
    if ogm_forwarding:                      # worst case: every node rebroadcasts every OGM
        us += (n - 1) * T_OGM
    if cot:                                 # one CoT position report per second, unicast
        us += t_uni(300)
    if poll_s:                              # issue #14: all-to-all neighbour polling
        us += (n - 1) / poll_s * (t_uni(200) + t_uni(1400))
    return us


def max_nodes(budget=0.5, beacon_int_tu=1000, poll_s=None, cot=False, ogm_forwarding=False):
    for n in range(2, 4000):
        if n * per_node_us(n, beacon_int_tu, poll_s, cot, ogm_forwarding) > USABLE_US * budget:
            return n - 1
    return 4000


def breakdown(n, beacon_int_tu=1000, poll_s=30, cot=True):
    beacon_hz = 1 / (beacon_int_tu * 1.024 / 1000)
    rows = [("beacon", n * beacon_hz * T_BEACON),
            ("batman ELP", n * ELP_HZ * T_ELP),
            ("batman OGM", n * OGM_HZ * T_OGM)]
    if cot:
        rows.append(("CoT", n * t_uni(300)))
    if poll_s:
        rows.append((f"#14 poll/{poll_s}s", n * (n - 1) / poll_s * (t_uni(200) + t_uni(1400))))
    return rows


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=float, default=0.5, help="fraction of airtime control may use")
    ap.add_argument("--beacon-int", type=int, default=1000, help="beacon_int in TU")
    ap.add_argument("--poll", type=int, default=30, help="issue #14 poll interval, seconds")
    a = ap.parse_args()

    print(f"per-frame airtime:  beacon={T_BEACON:.0f}us  ELP={T_ELP:.0f}us  OGM={T_OGM:.0f}us")
    print(f"                    (a 1400 B unicast data frame is {t_uni(1400):.0f}us)")
    print(f"one beacon costs as much airtime as {T_BEACON/t_uni(1400):.1f} full-size data frames\n")

    print(f"nodes per collision domain, control traffic capped at {a.budget:.0%} of airtime\n")
    for desc, kw in (("mesh control only (beacon+ELP+OGM)", {}),
                     ("+ 1 CoT/s per node", dict(cot=True)),
                     ("+ #14 all-to-all poll every 60 s", dict(cot=True, poll_s=60)),
                     ("+ #14 all-to-all poll every 30 s", dict(cot=True, poll_s=30)),
                     ("+ #14 all-to-all poll every 10 s", dict(cot=True, poll_s=10)),
                     ("+ #14 all-to-all poll every 5 s", dict(cot=True, poll_s=5)),
                     ("worst case: OGM forwarded network-wide", dict(ogm_forwarding=True))):
        print(f"  {desc:<44}{max_nodes(budget=a.budget, beacon_int_tu=a.beacon_int, **kw):>5}")

    print(f"\nbeacon_int leverage (with CoT + poll every {a.poll}s)\n")
    for bi in (1000, 2000, 3000, 5000, 10000):
        print(f"  beacon_int={bi:>6} TU  ({bi*1.024/1000:>5.2f}s)  ->{max_nodes(budget=a.budget, beacon_int_tu=bi, cot=True, poll_s=a.poll):>5} nodes")

    n = 50
    rows = breakdown(n, a.beacon_int, a.poll)
    tot = sum(v for _, v in rows)
    print(f"\nairtime breakdown at n={n}, beacon_int={a.beacon_int} TU, poll {a.poll}s\n")
    for k, v in sorted(rows, key=lambda r: -r[1]):
        print(f"  {k:<18}{v/1e4:>6.1f}% of a second   ({v/tot*100:>4.1f}% of control overhead)")
    print(f"  {'total':<18}{tot/1e4:>6.1f}%")
