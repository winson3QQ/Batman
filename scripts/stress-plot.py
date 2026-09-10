#!/usr/bin/env python3
"""stress-plot.py — plot the manet02 sustained-heavy-load stress run (reboot-repro).

Three figures:
  1. CPU over time (busy/sys/softirq/irq) — stability across the run (no ramp, no hang).
  2. per-process CPU attribution under sustained load (avg % of one core), by family.
  3. top hardware IRQs + softirqs by rate.

    ./stress-plot.py <boot_dir> <out_dir>
"""
import sys, csv, os
from collections import defaultdict
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

D = sys.argv[1] if len(sys.argv) > 1 else "soak-data/manet02-stress/boot-1789010950"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/images"
os.makedirs(OUT, exist_ok=True)

# --- sys.csv over time ---
ts=[]; busy=[]; syscpu=[]; soft=[]; irq=[]
for r in csv.DictReader(open(f"{D}/sys.csv")):
    try:
        busy.append(float(r["all_busy"] or 0)); syscpu.append(float(r["all_sys"] or 0))
        soft.append(float(r["all_softirq"] or 0)); irq.append(float(r["all_irq"] or 0))
    except: pass
n=len(busy); mins=[i*10/60 for i in range(n)]
fig,ax=plt.subplots(figsize=(11,4))
ax.plot(mins,busy,label="busy (total)",color="#57606a",lw=.8)
ax.plot(mins,syscpu,label="sys (kworkers)",color="#1f6feb",lw=.8)
ax.plot(mins,soft,label="softirq",color="#2da44e",lw=.8)
ax.plot(mins,irq,label="hardirq",color="#cf222e",lw=.8)
ax.set_xlabel("minutes into sustained heavy load"); ax.set_ylabel("% of 4-core total")
ax.set_title(f"manet02 CPU over ~{n*10//60} min of sustained heavy load — stable, no ramp, no hang")
ax.legend(fontsize=8,ncol=4,loc="upper right"); ax.grid(alpha=.3); ax.set_ylim(0,max(30,max(busy)+3))
plt.tight_layout(); plt.savefig(f"{OUT}/stress-cpu-timeseries.png",dpi=110); plt.close()

# --- proc.csv attribution ---
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
famsum=defaultdict(float)
for r in csv.DictReader(open(f"{D}/proc.csv")):
    try: famsum[fam(r["comm"])]+=float(r["cpu_pct"])
    except: pass
avg={k:v/n for k,v in famsum.items()}
order=sorted(avg,key=avg.get)
fig,ax=plt.subplots(figsize=(9,4.5))
colors={"Morse NetWorkQ":"#0969da","Morse ChipIfWorkQ":"#54aeff","ksoftirqd":"#2da44e",
        "batman bat_events":"#8250df","SPI-IRQ (threaded)":"#cf222e","iperf (load-gen)":"#bf8700",
        "FTS (python)":"#bc4c00","sampler (awk)":"#afb8c1","other":"#d0d7de"}
ax.barh(order,[avg[k] for k in order],color=[colors.get(k,"#888") for k in order])
for i,k in enumerate(order): ax.text(avg[k]+.1,i,f"{avg[k]:.1f}",va="center",fontsize=8)
ax.set_xlabel("avg CPU under sustained load (% of one core)")
ax.set_title("manet02 CPU attribution under sustained heavy load")
ax.grid(axis="x",alpha=.3)
plt.tight_layout(); plt.savefig(f"{OUT}/stress-cpu-attribution.png",dpi=110); plt.close()

# --- irq + softirq ---
irqsum=defaultdict(float); irqn=0; softsum=defaultdict(float)
for r in csv.DictReader(open(f"{D}/irq.csv")):
    try: irqsum[(r["irq"]+" "+r.get("desc","")).strip()[:34]]+=float(r["total"])
    except: pass
for r in csv.DictReader(open(f"{D}/softirq.csv")):
    try: softsum[r["kind"]]+=float(r["total"])
    except: pass
def topavg(d,k=8):
    a={x:v/n for x,v in d.items()}; return sorted(a,key=a.get)[-k:],a
ik,ia=topavg(irqsum); sk,sa=topavg(softsum,6)
fig,(a1,a2)=plt.subplots(1,2,figsize=(12,4.2))
a1.barh(ik,[ia[x] for x in ik],color="#cf222e"); a1.set_title("top hardware IRQs (avg/s·10)"); a1.grid(axis="x",alpha=.3); a1.tick_params(labelsize=7)
a2.barh(sk,[sa[x] for x in sk],color="#2da44e"); a2.set_title("softirqs (avg/s·10)"); a2.grid(axis="x",alpha=.3)
plt.tight_layout(); plt.savefig(f"{OUT}/stress-irq-softirq.png",dpi=110); plt.close()

print(f"samples={n} (~{n*10//60} min). attribution:")
for k in reversed(order): print(f"  {avg[k]:6.2f}  {k}")
print("wrote stress-cpu-timeseries.png, stress-cpu-attribution.png, stress-irq-softirq.png")
