#!/usr/bin/env python3
"""deep-cpu-sample.py — per-process + per-IRQ + per-softirq CPU sampler.

Goes deeper than soak-cpu-sample.py: instead of only the aggregate /proc/stat
breakdown, it attributes CPU time to individual processes, hardware IRQs and
softirqs, so a saturated-traffic soak can show *where* the sys/softirq time goes
and whether there is room to optimise.

Writes 4 CSVs into OUTDIR (put it on tmpfs to avoid perturbing the disk):
  sys.csv      one row/sample: per-CPU user/sys/irq/softirq/idle/iowait %
  proc.csv     long: ts,pid,comm,cpu_pct (one core = 100%), only active pids
  irq.csv      long: ts,irq,total_delta,per-cpu deltas   (hardware interrupts)
  softirq.csv  long: ts,kind,total_delta,per-cpu deltas

Self-measuring: the sampler's own PID appears in proc.csv, so its cost can be
subtracted. Pin it to one core with --cpu so it stays off the packet path.

    ./deep-cpu-sample.py --out /tmp/soakprof --ivl 10 --cpu 3
    touch /tmp/soakprof/STOP     # clean stop
"""
import os, sys, time, argparse

ap = argparse.ArgumentParser()
ap.add_argument("--out", default="/tmp/soakprof")
ap.add_argument("--ivl", type=float, default=10.0)
ap.add_argument("--cpu", type=int, default=-1, help="pin sampler to this core (-1 = don't)")
ap.add_argument("--min-jiffies", type=int, default=1,
                help="only log a process whose (dutime+dstime) >= this")
args = ap.parse_args()

HZ = os.sysconf("SC_CLK_TCK") or 100
NCPU = os.cpu_count() or 4
os.makedirs(args.out, exist_ok=True)

if args.cpu >= 0:
    try:
        os.sched_setaffinity(0, {args.cpu})
    except Exception as e:
        print("affinity set failed:", e, file=sys.stderr)

def read_stat():
    """per-cpu jiffies: {cpu_name: [user,nice,sys,idle,iowait,irq,softirq,steal]}"""
    out = {}
    with open("/proc/stat") as f:
        for line in f:
            if not line.startswith("cpu"):
                break
            k, *v = line.split()
            out[k] = [int(x) for x in v[:8]] + [0] * max(0, 8 - len(v))
    return out

def read_matrix(path):
    """parse /proc/interrupts or /proc/softirqs into {name: [c0..cN], ...}."""
    out = {}
    with open(path) as f:
        header = f.readline()
        ncol = len(header.split())  # CPU0..CPUk
        for line in f:
            parts = line.split()
            if not parts or not parts[0].endswith(":"):
                continue
            name = parts[0][:-1]
            nums = []
            for p in parts[1:1 + NCPU]:
                if p.isdigit():
                    nums.append(int(p))
                else:
                    break
            if nums:
                # keep trailing description for IRQs (e.g. 'DMA IRQ mmc1')
                desc = " ".join(parts[1 + len(nums):]) if path.endswith("interrupts") else ""
                out[name] = (nums, desc)
    return out

def read_procs():
    """{pid: (comm, utime+stime)} for all processes."""
    out = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/stat") as f:
                data = f.read()
            # comm may contain spaces/parens -> split on last ')'
            r = data.rfind(")")
            comm = data[data.find("(") + 1:r]
            rest = data[r + 2:].split()
            utime = int(rest[11]); stime = int(rest[12])  # fields 14,15 (0-based after comm: 11,12)
            out[int(pid)] = (comm, utime + stime)
        except Exception:
            continue
    return out

def pct(cur, prev):
    d = [c - p for c, p in zip(cur, prev)]
    tot = sum(d) or 1
    return dict(user=100.0*(d[0]+d[1])/tot, sys=100.0*d[2]/tot, idle=100.0*d[3]/tot,
                iowait=100.0*d[4]/tot, irq=100.0*d[5]/tot, softirq=100.0*d[6]/tot, busy=100.0*(tot-d[3])/tot)

sys_f = open(f"{args.out}/sys.csv", "a", buffering=1)
proc_f = open(f"{args.out}/proc.csv", "a", buffering=1)
irq_f = open(f"{args.out}/irq.csv", "a", buffering=1)
sirq_f = open(f"{args.out}/softirq.csv", "a", buffering=1)
if os.path.getsize(f"{args.out}/sys.csv") == 0:
    cols = ["ts", "dt_s"]
    for who in ["all"] + [f"cpu{i}" for i in range(NCPU)]:
        cols += [f"{who}_{m}" for m in ("busy", "user", "sys", "irq", "softirq", "iowait")]
    sys_f.write(",".join(cols) + "\n")
    proc_f.write("ts,pid,comm,cpu_pct,dj\n")
    irq_f.write("ts,irq,desc,total," + ",".join(f"c{i}" for i in range(NCPU)) + "\n")
    sirq_f.write("ts,kind,total," + ",".join(f"c{i}" for i in range(NCPU)) + "\n")

p_stat = read_stat(); p_irq = read_matrix("/proc/interrupts")
p_sirq = read_matrix("/proc/softirqs"); p_proc = read_procs()
t_prev = time.time()
time.sleep(args.ivl)

while True:
    if os.path.exists(f"{args.out}/STOP"):
        break
    now = time.time(); dt = now - t_prev
    ts = time.strftime("%F %T")
    c_stat = read_stat(); c_irq = read_matrix("/proc/interrupts")
    c_sirq = read_matrix("/proc/softirqs"); c_proc = read_procs()

    # --- sys.csv: per-cpu mode % ---
    row = [ts, f"{dt:.1f}"]
    for who in ["cpu"] + [f"cpu{i}" for i in range(NCPU)]:
        if who in c_stat and who in p_stat:
            p = pct(c_stat[who], p_stat[who])
            row += [f"{p['busy']:.2f}", f"{p['user']:.2f}", f"{p['sys']:.2f}",
                    f"{p['irq']:.2f}", f"{p['softirq']:.2f}", f"{p['iowait']:.2f}"]
        else:
            row += ["", "", "", "", "", ""]
    sys_f.write(",".join(row) + "\n")

    # --- proc.csv: per-process CPU (% of one core) ---
    denom = HZ * dt or 1
    for pid, (comm, j) in c_proc.items():
        if pid in p_proc:
            dj = j - p_proc[pid][1]
            if dj >= args.min_jiffies:
                cpu_pct = 100.0 * dj / denom
                proc_f.write(f"{ts},{pid},{comm},{cpu_pct:.2f},{dj}\n")

    # --- irq.csv / softirq.csv: deltas ---
    for name, (nums, desc) in c_irq.items():
        if name in p_irq:
            d = [c - p for c, p in zip(nums, p_irq[name][0])]
            tot = sum(d)
            if tot > 0:
                irq_f.write(f"{ts},{name},{desc.replace(',',' ')},{tot}," + ",".join(str(x) for x in d) + "\n")
    for name, (nums, _d) in c_sirq.items():
        if name in p_sirq:
            d = [c - p for c, p in zip(nums, p_sirq[name][0])]
            tot = sum(d)
            if tot > 0:
                sirq_f.write(f"{ts},{name},{tot}," + ",".join(str(x) for x in d) + "\n")

    p_stat, p_irq, p_sirq, p_proc, t_prev = c_stat, c_irq, c_sirq, c_proc, now
    time.sleep(args.ivl)

print("stopped")
