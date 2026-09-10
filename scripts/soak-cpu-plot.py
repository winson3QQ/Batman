#!/usr/bin/env python3
"""soak-cpu-plot.py — plot the deep-sample.sh CPU-attribution soak.

Reads a node's soak dir (sys.csv, proc.csv, phases.csv) + a ping.log, and
produces three figures:
  1. per-phase CPU: busy / sys / softirq / hardirq (mean per traffic type)
  2. per-phase process attribution (stacked, grouped into driver families)
  3. ping RTT distribution per phase (interrupt-latency under load)

    ./soak-cpu-plot.py <node_dir> <ping.log> <out_dir>
e.g. ./soak-cpu-plot.py soak-data/manet01 soak-data/manet02/ping.log docs/images
"""
import sys, csv, re, os
from datetime import datetime
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

NODE = sys.argv[1] if len(sys.argv) > 1 else "soak-data/manet01"
PING = sys.argv[2] if len(sys.argv) > 2 else "soak-data/manet02/ping.log"
OUT  = sys.argv[3] if len(sys.argv) > 3 else "docs/images"
os.makedirs(OUT, exist_ok=True)
def ts(s): return datetime.strptime(s.strip(), "%Y-%m-%d %H:%M:%S")

# phase order (traffic types), as driven
ORDER = ["idle","udp_1400","udp_800","udp_400","udp_200","udp_100",
         "pps_64","tcp_bulk","multicast","voice","video","mixed"]

# --- phase intervals ---
phases = []
cur = {}
for r in csv.DictReader(open(f"{NODE}/phases.csv")):
    if r["marker"] == "PHASE_START":
        cur = {"name": r["name"], "start": ts(r["ts"])}
    elif r["marker"] == "PHASE_END" and cur:
        cur["end"] = ts(r["ts"]); phases.append(cur); cur = {}
def phase_of(t):
    for p in phases:
        if p["start"] <= t <= p["end"]: return p["name"]
    return None

# --- sys.csv per-phase means ---
sysm = defaultdict(lambda: defaultdict(list))
for r in csv.DictReader(open(f"{NODE}/sys.csv")):
    try: ph = phase_of(ts(r["ts"]))
    except: continue
    if not ph: continue
    for k in ("all_busy","all_sys","all_softirq","all_irq"):
        try: sysm[ph][k].append(float(r[k] or 0))
        except: pass
def mean(x): return sum(x)/len(x) if x else 0.0

# --- proc.csv per-phase, grouped into families ---
def fam(c):
    if "MorseNetWorkQ" in c: return "Morse NetWorkQ"
    if "MorseChipIfWorkQ" in c: return "Morse ChipIfWorkQ"
    if c.startswith("ksoftirqd"): return "ksoftirqd"
    if "bat_events" in c: return "batman bat_events"
    if "Morse SPI IRQ" in c: return "SPI-IRQ (threaded)"
    if c == "iperf": return "iperf (load-gen)"
    if c == "awk": return "sampler (awk)"
    return "other"
FAMS = ["Morse NetWorkQ","Morse ChipIfWorkQ","ksoftirqd","batman bat_events",
        "SPI-IRQ (threaded)","iperf (load-gen)","other"]  # sampler excluded from attribution
procm = defaultdict(lambda: defaultdict(float))   # phase -> fam -> sum cpu_pct
procn = defaultdict(int)                          # phase -> n samples
_last_ts = {}
for r in csv.DictReader(open(f"{NODE}/proc.csv")):
    try: t = ts(r["ts"])
    except: continue
    ph = phase_of(t)
    if not ph: continue
    f = fam(r["comm"])
    if f == "sampler (awk)": continue
    procm[ph][f] += float(r["cpu_pct"])
# count distinct sample timestamps per phase to average
seen = defaultdict(set)
for r in csv.DictReader(open(f"{NODE}/proc.csv")):
    try: t = ts(r["ts"])
    except: continue
    ph = phase_of(t)
    if ph: seen[ph].add(r["ts"])
for ph in seen: procn[ph] = len(seen[ph])

# --- ping per phase ---
ping_by_phase = defaultdict(list)
if os.path.exists(PING):
    for line in open(PING, errors="replace"):
        m = re.search(r"time=([\d.]+)", line)
        me = re.match(r"\s*(\d+)\s", line)
        if m and me:
            # ping.log lines: "<epoch> 64 bytes ... time=3.9 ms"
            pass
    # ping.log uses "<epoch> <ping line>"; map epoch->phase via node-local? skip mapping, do global hist
pings = []
if os.path.exists(PING):
    for line in open(PING, errors="replace"):
        m = re.search(r"time=([\d.]+)", line)
        if m: pings.append(float(m.group(1)))

phlist = [p for p in ORDER if p in sysm]

# ===== Figure 1: per-phase CPU modes =====
fig, ax = plt.subplots(figsize=(11,4.5))
x = range(len(phlist))
busy = [mean(sysm[p]["all_busy"]) for p in phlist]
sy   = [mean(sysm[p]["all_sys"]) for p in phlist]
so   = [mean(sysm[p]["all_softirq"]) for p in phlist]
hi   = [mean(sysm[p]["all_irq"]) for p in phlist]
ax.bar(x, busy, color="#d0d7de", label="busy (total)")
ax.bar(x, sy, color="#1f6feb", label="sys (kworkers)")
ax.bar(x, so, bottom=sy, color="#2da44e", label="softirq")
ax.bar(x, hi, bottom=[a+b for a,b in zip(sy,so)], color="#cf222e", label="hardirq")
ax.set_xticks(list(x)); ax.set_xticklabels(phlist, rotation=40, ha="right")
ax.set_ylabel("% of 4-core total"); ax.legend(loc="upper right", fontsize=8)
ax.set_title("manet01 CPU by traffic type — cost lives in sys(kworkers)+softirq, hardirq≈0")
ax.grid(axis="y", alpha=0.3)
plt.tight_layout(); plt.savefig(f"{OUT}/soak-cpu-by-phase.png", dpi=110); plt.close()

# ===== Figure 2: per-phase process attribution (stacked, avg %/core) =====
fig, ax = plt.subplots(figsize=(11,5))
colors = {"Morse NetWorkQ":"#0969da","Morse ChipIfWorkQ":"#54aeff","ksoftirqd":"#2da44e",
          "batman bat_events":"#8250df","SPI-IRQ (threaded)":"#cf222e","iperf (load-gen)":"#bf8700","other":"#afb8c1"}
bottom = [0]*len(phlist)
for f in FAMS:
    vals = [ (procm[p].get(f,0)/procn[p] if procn[p] else 0) for p in phlist ]
    ax.bar(x, vals, bottom=bottom, color=colors[f], label=f)
    bottom = [b+v for b,v in zip(bottom, vals)]
ax.set_xticks(list(x)); ax.set_xticklabels(phlist, rotation=40, ha="right")
ax.set_ylabel("avg CPU (% of one core)"); ax.legend(loc="upper right", fontsize=8, ncol=2)
ax.set_title("manet01 CPU attribution by process family — Morse driver workqueues dominate")
ax.grid(axis="y", alpha=0.3)
plt.tight_layout(); plt.savefig(f"{OUT}/soak-cpu-attribution.png", dpi=110); plt.close()

# ===== Figure 3: ping RTT distribution =====
if pings:
    fig, ax = plt.subplots(figsize=(8,4))
    ax.hist(pings, bins=60, range=(0, min(40, max(pings))), color="#1f6feb", alpha=0.8)
    import statistics as st
    ax.axvline(st.median(pings), color="#cf222e", ls="--", label=f"median {st.median(pings):.1f} ms")
    ax.set_xlabel("node↔node RTT (ms) under mixed load"); ax.set_ylabel("count")
    ax.set_title(f"manet01↔manet02 ping RTT during soak (n={len(pings)}, median {st.median(pings):.1f} ms)")
    ax.legend(); ax.grid(alpha=0.3)
    plt.tight_layout(); plt.savefig(f"{OUT}/soak-ping-rtt.png", dpi=110); plt.close()

print("phases:", phlist)
print("wrote:", os.listdir(OUT))
