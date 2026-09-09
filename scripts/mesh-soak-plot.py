#!/usr/bin/env python3
import csv, sys, statistics as st
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

path = sys.argv[1] if len(sys.argv) > 1 else "soak.csv"
out  = sys.argv[2] if len(sys.argv) > 2 else "soak.png"

def f(x):
    try: return float(x)
    except: return float("nan")

ts=[]; tput=[]; cpu02=[]; ram02=[]; sig02=[]; mcs02=[]; cpu01=[]; ram01=[]; sig01=[]; mcs01=[]
with open(path) as fh:
    r=csv.DictReader(fh)
    for row in r:
        ts.append(f(row["ts"])); tput.append(f(row["tput_mbps"]))
        cpu02.append(f(row["cpu02"])); ram02.append(f(row["ram02"])); sig02.append(f(row["sig02"])); mcs02.append(f(row["mcs02"]))
        cpu01.append(f(row["cpu01"])); ram01.append(f(row["ram01"])); sig01.append(f(row["sig01"])); mcs01.append(f(row["mcs01"]))

t0=ts[0]
mins=[(x-t0)/60.0 for x in ts]

def clean(a): return [x for x in a if x==x]   # drop NaN
def stats(a):
    a=clean(a)
    if not a: return (float("nan"),)*4
    m=st.mean(a); sd=st.pstdev(a) if len(a)>1 else 0.0
    cov=100*sd/m if m else 0.0
    return m, sd, cov, (min(a), max(a))

tm=stats(tput)
dur=(ts[-1]-ts[0])/60.0

fig, ax = plt.subplots(5,1, figsize=(11,13), sharex=True)
fig.suptitle(f"HaLow 4MHz soak  manet02→manet01  ({dur:.0f} min, n={len(ts)}, TCP saturated)", fontsize=14, fontweight="bold")

ax[0].plot(mins, tput, color="#1f77b4", lw=1.2)
ax[0].axhline(tm[0], color="#1f77b4", ls="--", lw=0.8, alpha=0.6)
ax[0].set_ylabel("Throughput\n(Mbps)")
ax[0].set_ylim(0, max([x for x in tput if x==x]+[1])*1.15)
ax[0].text(0.01,0.04,f"mean {tm[0]:.2f}  σ {tm[1]:.2f}  CoV {tm[2]:.1f}%  min {tm[3][0]:.2f}  max {tm[3][1]:.2f}",
           transform=ax[0].transAxes, fontsize=9, bbox=dict(fc="white",ec="#ccc",alpha=0.8))
ax[0].grid(alpha=0.3)

ax[1].plot(mins, cpu02, label="manet02", color="#d62728", lw=1)
ax[1].plot(mins, cpu01, label="manet01", color="#ff7f0e", lw=1)
ax[1].set_ylabel("CPU (%)"); ax[1].legend(loc="upper right", fontsize=8); ax[1].grid(alpha=0.3)

ax[2].plot(mins, ram02, label="manet02", color="#9467bd", lw=1)
ax[2].plot(mins, ram01, label="manet01", color="#8c564b", lw=1)
ax[2].set_ylabel("RAM used\n(MB)"); ax[2].legend(loc="upper right", fontsize=8); ax[2].grid(alpha=0.3)

ax[3].plot(mins, sig02, label="manet02 rx", color="#2ca02c", lw=1)
ax[3].plot(mins, sig01, label="manet01 rx", color="#17becf", lw=1)
ax[3].set_ylabel("RSSI (dBm)"); ax[3].legend(loc="upper right", fontsize=8); ax[3].grid(alpha=0.3)

ax[4].step(mins, mcs02, where="post", label="manet02 tx", color="#e377c2", lw=1)
ax[4].step(mins, mcs01, where="post", label="manet01 tx", color="#7f7f7f", lw=1)
ax[4].set_ylabel("TX MCS"); ax[4].set_ylim(-0.5,8.5); ax[4].set_yticks(range(0,9))
ax[4].legend(loc="lower right", fontsize=8); ax[4].grid(alpha=0.3)
ax[4].set_xlabel("elapsed (minutes)")

plt.tight_layout(rect=[0,0,1,0.98])
plt.savefig(out, dpi=110)
print(f"wrote {out}")

# stability summary to stdout
def line(name,a,unit=""):
    m,sd,cov,mm=stats(a)
    print(f"  {name:16s} mean {m:8.2f}{unit}  σ {sd:6.2f}  CoV {cov:5.1f}%  range {mm[0]:.1f}–{mm[1]:.1f}")
print(f"=== soak stability ({dur:.1f} min, {len(ts)} samples) ===")
line("throughput", tput, " Mbps")
line("cpu manet02", cpu02, " %")
line("cpu manet01", cpu01, " %")
line("ram manet02", ram02, " MB")
line("ram manet01", ram01, " MB")
line("rssi manet02", sig02, " dBm")
line("rssi manet01", sig01, " dBm")
line("mcs manet02", mcs02)
line("mcs manet01", mcs01)
