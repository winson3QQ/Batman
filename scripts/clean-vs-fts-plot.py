#!/usr/bin/env python3
"""clean-vs-fts-plot.py — the 'other half': manet01 (clean, no FTS) vs manet02 (FTS)
under the SAME sustained heavy load.

manet01's soak sampler kept running (STOP-bug) through the whole stress run, so it is a
free clean-node counterpart: identical Morse driver + batman + iperf load, but no FTS.
Comparing the two isolates FTS's true cost on the packet-path baseline.

Two figures:
  1. CPU-over-time, both nodes overlaid across the stress window.
  2. per-process attribution, manet01 vs manet02 side by side.

  ./clean-vs-fts-plot.py <manet01_dir> <manet02_boot_dir> <out_dir> [start_ts_m01]
"""
import sys, csv, os
from collections import defaultdict
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

M1 = sys.argv[1] if len(sys.argv) > 1 else "../soak-data/manet01-full"
M2 = sys.argv[2] if len(sys.argv) > 2 else "../soak-data/manet02-stress/boot-1789010950"
OUT = sys.argv[3] if len(sys.argv) > 3 else "docs/images"
# manet01 clock ~8 min behind; stress ~12:13 in manet01 clock. manet02 boot dir already
# only spans the stress boot, so use it whole.
M1_START = sys.argv[4] if len(sys.argv) > 4 else "2026-09-09 12:13:00"
os.makedirs(OUT, exist_ok=True)

def load_sys(path, start=None):
    ts=[]; busy=[]; syscpu=[]; soft=[]
    for r in csv.DictReader(open(path)):
        if start and r["ts"] < start: continue
        try:
            busy.append(float(r["all_busy"] or 0)); syscpu.append(float(r["all_sys"] or 0))
            soft.append(float(r["all_softirq"] or 0))
        except: pass
    return busy, syscpu, soft

b1,s1,sq1 = load_sys(f"{M1}/sys.csv", M1_START)
b2,s2,sq2 = load_sys(f"{M2}/sys.csv")
n1,n2 = len(b1), len(b2)

# --- fig 1: CPU over time, both nodes ---
fig,ax=plt.subplots(figsize=(11,4.2))
x1=[i*10/60 for i in range(n1)]; x2=[i*10/60 for i in range(n2)]
ax.plot(x1,b1,label=f"manet01 busy — NO FTS (avg {sum(b1)/n1:.1f})",color="#2da44e",lw=.9)
ax.plot(x2,b2,label=f"manet02 busy — FTS (avg {sum(b2)/n2:.1f})",color="#bc4c00",lw=.9)
ax.plot(x1,s1,label="manet01 sys",color="#2da44e",lw=.6,ls="--",alpha=.6)
ax.plot(x2,s2,label="manet02 sys",color="#bc4c00",lw=.6,ls="--",alpha=.6)
ax.set_xlabel("minutes of sustained heavy load"); ax.set_ylabel("% of 4-core total")
ax.set_title("Same load, two nodes: clean (manet01) vs FTS (manet02) — the FTS delta is the gap")
ax.legend(fontsize=8,ncol=2,loc="upper right"); ax.grid(alpha=.3)
ax.set_ylim(0,max(30,max(max(b1),max(b2))+3))
plt.tight_layout(); plt.savefig(f"{OUT}/clean-vs-fts-timeseries.png",dpi=110); plt.close()

# --- fig 2: attribution side by side ---
def fam(c):
    if "MorseNetWorkQ" in c: return "Morse NetWorkQ"
    if "MorseChipIfWorkQ" in c: return "Morse ChipIfWorkQ"
    if c.startswith("ksoftirqd"): return "ksoftirqd"
    if "bat_events" in c: return "batman bat_events"
    if "Morse SPI IRQ" in c: return "SPI-IRQ (threaded)"
    if c=="iperf": return "iperf (load-gen)"
    if c=="python": return "FTS (python)"
    if c=="awk": return "sampler (awk)"
    return "other"

def attrib(path, n, start=None):
    fs=defaultdict(float)
    for r in csv.DictReader(open(path)):
        if start and r["ts"] < start: continue
        try: fs[fam(r["comm"])]+=float(r["cpu_pct"])
        except: pass
    return {k:v/n for k,v in fs.items()}

a1=attrib(f"{M1}/proc.csv", n1, M1_START)
a2=attrib(f"{M2}/proc.csv", n2)
fams=["FTS (python)","Morse NetWorkQ","Morse ChipIfWorkQ","ksoftirqd",
      "batman bat_events","iperf (load-gen)","SPI-IRQ (threaded)"]
import numpy as np
y=np.arange(len(fams)); h=0.38
fig,ax=plt.subplots(figsize=(9.5,5))
ax.barh(y+h/2,[a1.get(f,0) for f in fams],height=h,color="#2da44e",label="manet01 (no FTS)")
ax.barh(y-h/2,[a2.get(f,0) for f in fams],height=h,color="#bc4c00",label="manet02 (FTS)")
for i,f in enumerate(fams):
    ax.text(a1.get(f,0)+.1,i+h/2,f"{a1.get(f,0):.1f}",va="center",fontsize=7)
    ax.text(a2.get(f,0)+.1,i-h/2,f"{a2.get(f,0):.1f}",va="center",fontsize=7)
ax.set_yticks(y); ax.set_yticklabels(fams); ax.invert_yaxis()
ax.set_xlabel("avg CPU under sustained load (% of one core)")
ax.set_title("Per-process CPU: clean node vs FTS node, same load")
ax.legend(fontsize=9); ax.grid(axis="x",alpha=.3)
plt.tight_layout(); plt.savefig(f"{OUT}/clean-vs-fts-attribution.png",dpi=110); plt.close()

print(f"manet01 n={n1}  manet02 n={n2}")
print(f"busy:    manet01={sum(b1)/n1:5.1f}   manet02={sum(b2)/n2:5.1f}   delta={sum(b2)/n2-sum(b1)/n1:+.1f} (% of 4-core)")
print(f"FTS on manet02 = {a2.get('FTS (python)',0):.1f} %/core  (= {a2.get('FTS (python)',0)/4:.1f} % of 4-core) — matches the busy delta")
print("driver families (should be ~equal, same load):")
for f in ["Morse NetWorkQ","Morse ChipIfWorkQ","ksoftirqd","batman bat_events","iperf (load-gen)"]:
    print(f"  {f:22} m01={a1.get(f,0):5.1f}  m02={a2.get(f,0):5.1f}")
print("wrote clean-vs-fts-timeseries.png, clean-vs-fts-attribution.png")
