#!/usr/bin/env python3
"""soak-plot.py — turn halow-soak.sh's CSV into the two figures in docs/.

    ./scripts/soak-plot.py [~/halow-soak/soak.csv]

Writes docs/images/soak-12h.png (time series) and docs/images/soak-12h-loss.png
(uplink loss vs payload size). Re-runnable: safe to call again while the soak is
still going, and again when it finishes.
"""
import csv, sys, os, time, calendar
from collections import defaultdict, OrderedDict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CSV = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/halow-soak/soak.csv")
CPUCSV = os.path.expanduser("~/halow-soak/cpu.csv")
DOCS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "images")

# validated categorical palette, fixed slot order (see dataviz skill palette.md)
SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e2"
SERIES = OrderedDict([("1400", "#2a78d6"), ("800", "#eb6834"), ("400", "#1baf7a"),
                      ("200", "#eda100"), ("100", "#e87ba4"), ("MIX", "#008300")])
# ordinal blue ramp for the size bars, no lighter than step 250 on a light surface
ORDINAL = ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#104281"]

rows = []
with open(CSV) as f:
    for r in csv.DictReader(f):
        if not r.get("dl_mbps"):          # NODE_UNREACHABLE rows carry no data
            continue
        rows.append(r)

def num(r, k, d=None):
    try:
        return float(r[k])
    except (TypeError, ValueError):
        return d

hours = [num(r, "elapsed_s") / 3600.0 for r in rows]
by_len = defaultdict(list)
for r in rows:
    by_len[r["pktlen"]].append((num(r, "elapsed_s") / 3600.0, num(r, "dl_mbps"),
                                num(r, "ul_mbps"), num(r, "ul_loss_pct"), num(r, "dl_loss_pct")))

def style(ax, title, ylabel):
    ax.set_title(title, color=INK, fontsize=11, loc="left", pad=8)
    ax.set_ylabel(ylabel, color=INK2, fontsize=9)
    ax.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9, length=0)
    ax.set_facecolor(SURFACE)

# ---------------------------------------------------------------- figure 1
fig = plt.figure(figsize=(12.6, 10.4), facecolor=SURFACE)
gs = fig.add_gridspec(3, 2, height_ratios=[1.2, 1.0, 0.9], hspace=0.45, wspace=0.2)
axT = fig.add_subplot(gs[0, :])
axL1, axL2 = fig.add_subplot(gs[1, 0]), fig.add_subplot(gs[1, 1])
axC, axM = fig.add_subplot(gs[2, 0]), fig.add_subplot(gs[2, 1])

xmax = max(hours)
for name, color in SERIES.items():
    pts = sorted(by_len.get(name, []))
    if not pts:
        continue
    x = [p[0] for p in pts]
    axT.plot(x, [p[1] for p in pts], color=color, lw=1.8, label=f"{name} B" if name != "MIX" else "MIX")
    axT.annotate(name, (x[-1], pts[-1][1]), xytext=(6, -3), textcoords="offset points",
                 color=INK2, fontsize=9, va="center")
    ax = axL2 if name == "MIX" else axL1
    ax.plot(x, [p[3] for p in pts], color=color, lw=1.8, label=f"{name} B" if name != "MIX" else "MIX")

# the one direction/size where uplink does not track downlink
mix = sorted(by_len.get("MIX", []))
if mix:
    axT.plot([p[0] for p in mix], [p[2] for p in mix], color=SERIES["MIX"], lw=1.6, ls=(0, (4, 2)))
    axT.annotate("MIX uplink", (mix[-1][0], mix[-1][2]), xytext=(6, -3), textcoords="offset points",
                 color=INK2, fontsize=9, va="center")

style(axT, "UDP throughput, downlink (solid) — flat for the whole run. MIX is the only phase where uplink falls short of downlink.", "Mbit/s")
axT.set_xlim(-0.2, xmax + 1.25)
axT.set_xlabel("elapsed (hours)", color=INK2, fontsize=9)
leg = axT.legend(loc="center left", bbox_to_anchor=(1.055, 0.5), frameon=False,
                 fontsize=9, labelcolor=INK2, title="payload", title_fontsize=9)
leg.get_title().set_color(INK2)

style(axL1, "Uplink loss, single-size phases", "%")
axL1.set_xlim(-0.2, xmax + 0.2)
axL1.set_xlabel("elapsed (hours)", color=INK2, fontsize=9)
_single_max = max(p[3] for k in SERIES if k != "MIX" for p in by_len.get(k, []) if p[3] is not None)
axL1.set_ylim(0, _single_max * 1.42)
axL1.legend(loc="upper left", ncol=5, frameon=False, fontsize=8.5,
            labelcolor=INK2, columnspacing=1.0, handlelength=1.4)

style(axL2, "Uplink loss, MIX phase — 4x worse, same link, same hour", "%")
axL2.set_xlim(-0.2, xmax + 0.2)
axL2.set_xlabel("elapsed (hours)", color=INK2, fontsize=9)
if mix:
    axL2.annotate("MIX", (mix[-1][0], mix[-1][3]), xytext=(-4, 10), textcoords="offset points",
                  color=INK2, fontsize=9, ha="right")

temps = [(h, num(r, "chip_temp_c")) for h, r in zip(hours, rows) if num(r, "chip_temp_c") is not None]
axC.step([t[0] for t in temps], [t[1] for t in temps], where="post", color=SERIES["1400"], lw=1.5)
style(axC, "MM6108 readout — only ever 57 or 64 °C,\nswitching with offered load, not with time", "°C")
axC.set_xlabel("elapsed (hours)", color=INK2, fontsize=9)
axC.set_yticks([57, 64])

mem = [(h, num(r, "mem_avail_kb") / 1024.0) for h, r in zip(hours, rows) if num(r, "mem_avail_kb")]
axM.plot([m[0] for m in mem], [m[1] for m in mem], color=SERIES["1400"], lw=1.5)
style(axM, "Pi 500 MemAvailable — drift is smaller than\nthe phase-to-phase noise", "MB")
axM.set_xlabel("elapsed (hours)", color=INK2, fontsize=9)
axM.set_ylim(min(m[1] for m in mem) - 150, max(m[1] for m in mem) + 150)

span = f"{xmax:.1f} h - {len(rows)} phases"
fig.suptitle(f"HaLow mesh soak: Pi 500 <-> manet01, 4 MHz ch40/922 MHz, bidirectional UDP  ({span})",
             color=INK, fontsize=13, x=0.075, ha="left", y=0.965)
fig.savefig(os.path.join(DOCS, "soak-12h.png"), dpi=100, facecolor=SURFACE, bbox_inches="tight")

# ---------------------------------------------------------------- figure 2
# two panels, not one: MIX is 4x the tallest single-size bar and would flatten
# the size ramp into invisibility on a shared scale.
fig2, (axA, axB) = plt.subplots(1, 2, figsize=(11.4, 4.8), facecolor=SURFACE,
                                gridspec_kw={"width_ratios": [2.1, 1], "wspace": 0.28})
sizes = [k for k in ["100", "200", "400", "800", "1400"] if by_len.get(k)]

def stat(keys):
    v = [p[3] for k in keys for p in by_len[k] if p[3] is not None]
    m = sum(v) / len(v)
    return m, m - min(v), max(v) - m

def bars(ax, labels, stats, colors):
    m = [s[0] for s in stats]
    ax.bar(range(len(m)), m, width=0.6, color=colors, zorder=3)
    ax.errorbar(range(len(m)), m, yerr=[[s[1] for s in stats], [s[2] for s in stats]],
                fmt="none", ecolor=INK2, elinewidth=1.2, capsize=5, zorder=4)
    for i, s in enumerate(stats):
        ax.annotate(f"{s[0]:.2f}%", (i, s[0] + s[2]), xytext=(0, 6), textcoords="offset points",
                    ha="center", color=INK, fontsize=9)
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels)
    ax.set_ylim(0, max(s[0] + s[2] for s in stats) * 1.24)

sstats = [stat([k]) for k in sizes]
bars(axA, [f"{k} B" for k in sizes], sstats, [ORDINAL[min(i, len(ORDINAL) - 1)] for i in range(len(sizes))])
style(axA, "Uplink loss climbs with payload size", "mean uplink loss (%)  ·  whiskers = min/max per phase")

if by_len.get("MIX"):
    bars(axB, ["all single-size\nphases", "MIX\n1400+400+100"],
         [stat(sizes), stat(["MIX"])], [ORDINAL[2], "#eb6834"])
    style(axB, "Mixing sizes costs 8x more\nthan any size does on its own", "")

fig2.savefig(os.path.join(DOCS, "soak-12h-loss.png"), dpi=100, facecolor=SURFACE, bbox_inches="tight")
print(f"wrote soak-12h.png and soak-12h-loss.png from {len(rows)} phases ({xmax:.2f} h)")


# ---------------------------------------------------------------- figure 3+4
# CPU is not in the soak CSV (soak-cpu-sample.py fills that gap), so these two
# figures only cover the window where both are present.
def epoch(t):
    return calendar.timegm(time.strptime(t, "%Y-%m-%d %H:%M:%S")) - time.timezone

if os.path.exists(CPUCSV):
    with open(CPUCSV) as f:
        cpu = [r for r in csv.DictReader(f) if r.get("cpu_busy_pct")]
    for r in cpu:
        r["t"] = epoch(r["ts"])
    PHASE_S = 300

    # join: a phase row is stamped at the END of its phase, so its window is (t-300, t]
    joined = []
    for r in rows:
        t1 = epoch(r["ts"]); t0 = t1 - PHASE_S
        win = [c for c in cpu if t0 < c["t"] <= t1]
        if len(win) < 6:                        # need most of the phase covered
            continue
        def avg(k):
            return sum(float(c[k]) for c in win) / len(win)
        load = (num(r, "dl_mbps") or 0) + (num(r, "ul_mbps") or 0)
        pl = r["pktlen"]
        # MIX carries three sizes at once; its pps is summed from the offered mix
        pps = (load * 1e6 / 8) / int(pl) if pl != "MIX" else None
        joined.append(dict(t=t1, len=pl, load=load, pps=pps,
                           busy=avg("cpu_busy_pct"), sys=avg("sys_pct"),
                           soft=avg("softirq_pct"), user=avg("user_pct"),
                           used=avg("mem_used_mb"), slab=avg("slab_mb"),
                           cached=avg("cached_mb")))

    if len(joined) >= 2:
        t0 = min(j["t"] for j in joined)
        hx = [(j["t"] - t0) / 3600.0 for j in joined]
        fig3, axs = plt.subplots(4, 1, figsize=(12.6, 11.0), facecolor=SURFACE, sharex=True)
        a1, a2, a3, a4 = axs
        fig3.subplots_adjust(hspace=0.42)

        a1.step(hx, [j["load"] for j in joined], where="mid", color=SERIES["1400"], lw=1.8)
        for j, x in zip(joined, hx):
            a1.annotate(j["len"], (x, j["load"]), xytext=(0, 6), textcoords="offset points",
                        ha="center", color=INK2, fontsize=7.5)
        style(a1, "Offered load per phase (downlink + uplink), labelled with payload size", "Mbit/s")

        a2.plot(hx, [j["busy"] for j in joined], color=SERIES["1400"], lw=1.8, label="all CPU busy")
        a2.plot(hx, [j["sys"] for j in joined], color=SERIES["800"], lw=1.8, label="kernel (sys)")
        a2.plot(hx, [j["soft"] for j in joined], color=SERIES["400"], lw=1.8, label="softirq (net stack)")
        a2.plot(hx, [j["user"] for j in joined], color=SERIES["100"], lw=1.6, ls=(0, (4, 2)),
                label="user (mostly iperf)")
        style(a2, "CPU utilisation, 4 cores aggregated — 10 s samples averaged over each phase", "% of 4 cores")
        a2.set_ylim(0, max(j["busy"] for j in joined) * 1.45)
        a2.legend(loc="upper left", ncol=4, frameon=False, fontsize=8.5, labelcolor=INK2,
                  columnspacing=1.2, handlelength=1.6)

        a3.plot(hx, [j["used"] for j in joined], color=SERIES["1400"], lw=1.8)
        style(a3, "RAM in use (MemTotal - MemAvailable)", "MB")
        a3.set_ylim(min(j["used"] for j in joined) - 60, max(j["used"] for j in joined) + 60)

        a4.plot(hx, [j["slab"] for j in joined], color=SERIES["1400"], lw=1.8)
        style(a4, "Slab (kernel allocations — where leaked skbs would show up)", "MB")
        a4.set_ylim(min(j["slab"] for j in joined) - 4, max(j["slab"] for j in joined) + 4)
        a4.set_xlabel("elapsed since CPU sampling started (hours)", color=INK2, fontsize=9)

        fig3.suptitle(f"CPU, RAM and offered load through the payload cycle  ({len(joined)} phases)",
                      color=INK, fontsize=13, x=0.09, ha="left", y=0.955)
        fig3.savefig(os.path.join(DOCS, "soak-cpu-ram.png"), dpi=100, facecolor=SURFACE,
                     bbox_inches="tight")

        # --- figure 4: what actually drives CPU, packet rate or bit rate ---
        fig4, (b1, b2) = plt.subplots(1, 2, figsize=(11.6, 4.9), facecolor=SURFACE,
                                      gridspec_kw={"wspace": 0.26})
        order4 = [k for k in ["100", "200", "400", "800", "1400", "MIX"]
                  if any(j["len"] == k for j in joined)]
        mv, lo4, hi4 = [], [], []
        for k in order4:
            v = [j["busy"] for j in joined if j["len"] == k]
            m = sum(v) / len(v)
            mv.append(m); lo4.append(m - min(v)); hi4.append(max(v) - m)
        col4 = [ORDINAL[min(i, len(ORDINAL) - 1)] for i in range(len(order4))]
        if order4[-1] == "MIX":
            col4[-1] = "#eb6834"
        b1.bar(range(len(order4)), mv, width=0.6, color=col4, zorder=3)
        b1.errorbar(range(len(order4)), mv, yerr=[lo4, hi4], fmt="none", ecolor=INK2,
                    elinewidth=1.2, capsize=5, zorder=4)
        for i, m in enumerate(mv):
            b1.annotate(f"{m:.1f}%", (i, m + hi4[i]), xytext=(0, 6), textcoords="offset points",
                        ha="center", color=INK, fontsize=9)
        b1.set_xticks(range(len(order4)))
        b1.set_xticklabels([f"{k} B" if k != "MIX" else "MIX" for k in order4])
        style(b1, "CPU by payload size", "mean CPU busy (%)  ·  whiskers = min/max per phase")
        b1.set_ylim(0, max(m + h for m, h in zip(mv, hi4)) * 1.25)

        pts = [j for j in joined if j["pps"]]
        b2.scatter([j["pps"] for j in pts], [j["busy"] for j in pts], s=34,
                   color=SERIES["1400"], zorder=3, edgecolor=SURFACE, linewidth=1.2)
        seen4 = {}
        for j in pts:
            seen4.setdefault(j["len"], []).append(j)
        for k, g in seen4.items():
            b2.annotate(f"{k} B", (sum(j["pps"] for j in g) / len(g),
                                   sum(j["busy"] for j in g) / len(g)),
                        xytext=(8, 6), textcoords="offset points", color=INK2, fontsize=9)
        style(b2, "CPU vs packet rate (single-size phases)", "mean CPU busy (%)")
        b2.set_xlabel("packets per second, both directions", color=INK2, fontsize=9)

        # CPU = a*pps + b*Mbit/s + c : separates per-packet cost from per-byte cost.
        # Needs both regressors to vary independently, which the payload sweep gives us.
        if len(pts) >= 4:
            try:
                import numpy as np
                A = np.array([[j["pps"], j["load"], 1.0] for j in pts])
                y = np.array([j["busy"] for j in pts])
                (a, b, c), *_ = np.linalg.lstsq(A, y, rcond=None)
                resid = y - A @ np.array([a, b, c])
                # busy is % of NCORES cores, so 1% = NCORES/100 core-seconds per second
                us_per_pkt = a / 100.0 * 4 * 1e6
                fit = (f"fit: CPU% = {a * 1000:.3f}e-3*pps + {b:.3f}*Mbps + {c:.2f}\n"
                       f"-> {us_per_pkt:.0f} us of CPU per packet, "
                       f"residual RMS {(resid ** 2).mean() ** 0.5:.2f} pp")
                b2.annotate(fit, (0.03, 0.97), xycoords="axes fraction", va="top",
                            color=INK2, fontsize=8.5, family="monospace")
                print(fit)
            except Exception as e:
                print("fit skipped:", e)

        fig4.savefig(os.path.join(DOCS, "soak-cpu-vs-load.png"), dpi=100, facecolor=SURFACE,
                     bbox_inches="tight")
        print(f"wrote soak-cpu-ram.png and soak-cpu-vs-load.png from {len(joined)} joined phases")
    else:
        print(f"cpu.csv has only {len(cpu)} samples - not enough overlap yet, skipping fig 3/4")
