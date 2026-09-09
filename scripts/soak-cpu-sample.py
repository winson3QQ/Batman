#!/usr/bin/env python3
"""soak-cpu-sample.py — sample CPU and RAM while halow-soak.sh runs.

The soak CSV records throughput and MemAvailable but no CPU, so this fills the
gap: one row every INTERVAL seconds, joined to soak phases by timestamp later.

    ./scripts/soak-cpu-sample.py [out.csv] [interval_s]
"""
import sys, time, os

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/halow-soak/cpu.csv")
IVL = float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
NCPU = os.cpu_count() or 4

def cpu_lines():
    out = {}
    with open("/proc/stat") as f:
        for line in f:
            if not line.startswith("cpu"):
                break
            k, *v = line.split()
            out[k] = [int(x) for x in v]
    return out

def meminfo():
    m = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            m[k] = int(v.split()[0])
    return m

# user nice system idle iowait irq softirq steal
def pct(cur, prev):
    d = [c - p for c, p in zip(cur, prev)]
    tot = sum(d) or 1
    return dict(user=100.0 * (d[0] + d[1]) / tot, sys=100.0 * d[2] / tot,
                idle=100.0 * d[3] / tot, iowait=100.0 * d[4] / tot,
                irq=100.0 * d[5] / tot, softirq=100.0 * d[6] / tot)

new = not os.path.exists(OUT)
f = open(OUT, "a", buffering=1)
if new:
    f.write("ts,cpu_busy_pct,user_pct,sys_pct,softirq_pct,irq_pct,iowait_pct,"
            + ",".join(f"cpu{i}_busy_pct" for i in range(NCPU))
            + ",mem_used_mb,mem_avail_mb,cached_mb,slab_mb\n")

prev = cpu_lines()
time.sleep(IVL)
while True:
    cur = cpu_lines()
    agg = pct(cur["cpu"], prev["cpu"])
    per = []
    for i in range(NCPU):
        k = f"cpu{i}"
        per.append(100.0 - pct(cur[k], prev[k])["idle"] if k in cur else 0.0)
    m = meminfo()
    used = (m["MemTotal"] - m["MemAvailable"]) / 1024.0
    f.write("{},{:.2f},{:.2f},{:.2f},{:.2f},{:.2f},{:.2f},{},{:.1f},{:.1f},{:.1f},{:.1f}\n".format(
        time.strftime("%F %T"), 100.0 - agg["idle"], agg["user"], agg["sys"],
        agg["softirq"], agg["irq"], agg["iowait"],
        ",".join(f"{p:.2f}" for p in per),
        used, m["MemAvailable"] / 1024.0, m["Cached"] / 1024.0, m["Slab"] / 1024.0))
    prev = cur
    time.sleep(IVL)
