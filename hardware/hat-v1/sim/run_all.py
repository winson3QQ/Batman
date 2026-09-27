#!/usr/bin/env python3
"""Pre-fab simulations for Batman HAT v1 (run: python3 sim/run_all.py).

S1 hot-plug ringing of the battery leads      -- ngspice (passives + TVS model)
S2 HaLow 3.3 V rail: pi filter + TX bursts     -- ngspice (behavioural buck)
S3 power sequencing scenarios                  -- behavioural model of LTC2955 / LMR33640 / eFuse
S4 slowly recovering battery (AUTO-ON window)  -- same model, Monte Carlo over tolerances

Every number that is an assumption (not from a datasheet or design.py) is
listed in ASSUMPTIONS and printed in the report, so the conclusions can be
re-checked when better data exists (e.g. real lead length, HaLow TX current).
"""
import os
import random
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "gen"))
import design as D  # noqa: E402
import spice  # noqa: E402

OUT = os.path.join(HERE, "..", "out", "sim")
C1, C2, C3, C4 = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"   # categorical slots 1-4 (dataviz ref palette)
INK, MUTED, SURF = "#1f1f1e", "#8a8a85", "#fcfcfb"
REPORT = []

ASSUMPTIONS = {
    "battery source resistance (pack + BMS FETs)": "30 mOhm",
    "battery lead inductance (wire pair)": "0.3 / 0.7 / 1.5 uH (~0.3 / 0.7 / 1.5 m of wire)",
    "MLCC capacitance left under DC bias": "50 % for 50 V X7R at 17 V; 60 % for 6.3-10 V parts at 3.3 V",
    "SMBJ20CA model": "breakdown 23.3 V, dynamic R 0.49 Ohm (Vc 32.4 V @ 18.5 A)",
    "ferrite FB1 low-frequency model": "20 mOhm + (0.5 uH || 600 Ohm)",
    "TPS62933F closed loop": "3.33 V behind 5 mOhm + 84 nH (~100 kHz crossover with 30 uF)",
    "HaLow TX burst on 3V3_MPCIE": "0.25 A idle -> 1.2 A, 1 us edge, 1 ms bursts every 2 ms (27 dBm FEM via on-card boost; pessimistic)",
    "Pi 4 3.3 V rail delay after 5 V is valid": "2-50 ms",
    "LTC2955 ON edge during the 0.6-1.4 s enable lockout": "ignored (worst case; datasheet silent)",
}


def val(ref):
    p = next(p for p in D.PARTS if p.ref == ref)
    import re
    m = re.match(r"([\d.]+)\s*([kKM]?)", p.value)
    return float(m.group(1)) * {"": 1, "k": 1e3, "K": 1e3, "M": 1e6}[m.group(2)]


def style(ax, title, xlabel, ylabel):
    ax.set_title(title, loc="left", fontsize=11, color=INK)
    ax.set_xlabel(xlabel, color=MUTED)
    ax.set_ylabel(ylabel, color=MUTED)
    ax.grid(True, color="#e6e6e3", linewidth=0.6)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(MUTED)
    ax.tick_params(colors=MUTED)
    ax.set_facecolor(SURF)


def hline(ax, y, text, x=None):
    ax.axhline(y, color=MUTED, linestyle="--", linewidth=1)
    xl = ax.get_xlim()
    ax.text(x if x is not None else xl[0] + 0.01 * (xl[1] - xl[0]), y, " " + text, color=INK,
            fontsize=8, va="bottom")


# ------------------------------------------------------------------------------------------------
# S1 hot-plug
# ------------------------------------------------------------------------------------------------
def s1_hotplug():
    ovp_min = 1.176 * (val("R3") + val("R4")) / val("R4")
    rd = val("R19")
    n_cd = sum(1 for p in D.PARTS if p.sym == "C" and "VBAT_DAMP" in p.pins.values())
    cd = n_cd * 10e-6 * 0.5          # 10 uF 50 V X7R keeps ~50 % at 17 V
    rows, curves = [], {}
    for vbat in (8.4, 12.6, 16.8):
        for lw in (0.3e-6, 0.7e-6, 1.5e-6):
            for damper in (False, True):
                net = f"""hotplug
Vb src 0 PWL(0 0 1u 0 1.02u {vbat})
Rb src a 30m
Lw a b {lw}
Rw b vbat 20m
C1 vbat c1 0.5u
Rc1 c1 0 5m
C2 vbat 0 100n
{f'R19 vbat d {rd}' if damper else '*'}
{f'C8 d 0 {cd}' if damper else '*'}
Dt1 m vbat DZ
Dt2 m 0 DZ
.model DZ D(BV=23.3 IBV=1m RS=0.49 CJO=1n)
.tran 5n 40u"""
                spice.run(net, "run")
                t, v = spice.vec("time"), spice.vec("v(vbat)")
                pk = max(v)
                above = sum(t[i + 1] - t[i] for i in range(len(t) - 1) if v[i] > ovp_min)
                rows.append((vbat, lw, damper, pk, above))
                if lw == 0.7e-6 and vbat == 16.8:
                    curves[damper] = ([x * 1e6 for x in t], v)
    fig, ax = plt.subplots(figsize=(7.5, 3.6), facecolor=SURF)
    ax.plot(*curves[False], color=C2, linewidth=2, label="without damper (R19/C8)")
    ax.plot(*curves[True], color=C1, linewidth=2, label="with 1 ohm + 10 uF damper")
    style(ax, "S1  Plugging a full 4S pack (16.8 V) through 0.7 uH of wire", "time (us)", "VBAT_RAW (V)")
    hline(ax, ovp_min, f"eFuse OVP min {ovp_min:.1f} V")
    hline(ax, 16.8, "pack 16.8 V")
    ax.legend(frameon=False, fontsize=8, loc="lower right")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "s1-hotplug.png"), dpi=160)
    plt.close(fig)
    REPORT.append("## S1 Hot-plug ringing (ngspice)\n")
    REPORT.append(f"eFuse OVP trips at {ovp_min:.2f} V minimum (R3/R4, OVPR min 1.176 V). "
                  "Peak VBAT_RAW when the pack is plugged in:\n")
    REPORT.append(f"Damper in the design: R19 = {rd} Ohm + {n_cd} x 10 uF (~{cd * 1e6:.0f} uF under DC bias). "
                  "The eFuse needs the overvoltage to last 8.5 us (min, OVP_tOFF(dly)) before it reacts.\n")
    REPORT.append("| pack | lead L | damper | peak | margin to OVP min | time above OVP |")
    REPORT.append("|---|---|---|---|---|---|")
    for vb, lw, dmp, pk, ab in rows:
        REPORT.append(f"| {vb} V | {lw * 1e6:.1f} uH | {'yes' if dmp else 'no'} | {pk:.1f} V | {ovp_min - pk:+.1f} V "
                      f"| {ab * 1e6:.1f} us |")
    trip = [(vb, lw) for vb, lw, dmp, pk, ab in rows if dmp and pk > ovp_min]
    REPORT.append("")
    REPORT.append(f"![S1](s1-hotplug.png)\n")
    return trip, rows


# ------------------------------------------------------------------------------------------------
# S2 HaLow rail
# ------------------------------------------------------------------------------------------------
def s2_halow_rail(with_polymer=True, bead_l=0.5e-6):
    poly = "C62 s c62 132u\nR62 c62 c62b 15m\nL62 c62b 0 2n" if with_polymer else "*"
    net = f"""halow rail
Vref r 0 3.33
Rl r l 5m
Ll l buck 84n
C27 buck c27 36u
R27 c27 0 3m
R22 buck sh 20m
C31 sh c31 6u
R31 c31 0 5m
Rfb sh fb 20m
Lfb fb filt {bead_l}
Rfbp fb filt 600
Rjp filt s 1m
C60 s c60 50u
R60 c60 c60b 3m
L60 c60b 0 1n
{poly}
C63 s 0 200n
Iload s 0 PWL(0 0.25 1m 0.25 1.001m 1.2 2m 1.2 2.001m 0.25 3m 0.25 3.001m 1.2 4m 1.2 4.001m 0.25 5m 0.25 5.001m 1.2 6m 1.2 6.001m 0.25 8m 0.25)
.tran 0.5u 8m"""
    spice.run(net, "run")
    t, v = spice.vec("time"), spice.vec("v(s)")
    net_ac = net.replace(net.splitlines()[-2], "Iload s 0 AC 1").replace(".tran 0.5u 8m", ".ac dec 50 100 10meg")
    spice.run(net_ac, "run")
    f, z = spice.vec("frequency"), [abs(x) for x in spice.vec("v(s)")]
    return t, v, f, z


def s2():
    t, v, f, z = s2_halow_rail(True)
    t_np, v_np, _, z_np = s2_halow_rail(False)
    _, _, _, z_l1 = s2_halow_rail(True, 1.0e-6)
    vmin, vmax = min(v[len(v) // 10:]), max(v[len(v) // 10:])
    band = [i for i, x in enumerate(f) if x.real <= 1e6]     # filter resonance, not the ESL rise
    zpk = max(z[i] for i in band)
    fpk = f[z.index(zpk)].real
    zpk_np = max(z_np[i] for i in band)
    fpk_np = f[z_np.index(zpk_np)].real
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 3.6), facecolor=SURF)
    a1.plot([x * 1e3 for x in t_np], v_np, color=C2, linewidth=1.5, label="without polymer")
    a1.plot([x * 1e3 for x in t], v, color=C1, linewidth=2, label="with 220 uF polymer (design)")
    style(a1, "S2a  3V3_MPCIE during 1.2 A TX bursts", "time (ms)", "V at socket")
    hline(a1, 3.0, "mPCIe min 3.0 V (3.3 V -9 %)")
    a1.set_ylim(2.95, 3.42)
    a1.legend(frameon=False, fontsize=8, loc="upper right")
    a2.loglog([x.real for x in f], z, color=C1, linewidth=2, label="design (bead 0.5 uH)")
    a2.loglog([x.real for x in f], z_l1, color=C3, linewidth=2, label="bead 1.0 uH")
    a2.loglog([x.real for x in f], z_np, color=C2, linewidth=2, label="without polymer")
    style(a2, "S2b  Impedance seen by the card", "frequency (Hz)", "|Z| (ohm)")
    a2.legend(frameon=False, fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "s2-halow-rail.png"), dpi=160)
    plt.close(fig)
    REPORT.append("## S2 HaLow 3.3 V rail: pi filter + TX bursts (ngspice)\n")
    REPORT.append(f"- Voltage at the socket during 1.2 A bursts: **{vmin:.3f}-{vmax:.3f} V** "
                  f"(without the polymer cap: {min(v_np[len(v_np) // 10:]):.3f} V min). mPCIe allows 3.0-3.6 V.")
    REPORT.append(f"- Resonance of bead + bulk caps: **{zpk * 1000:.0f} mOhm at {fpk / 1e3:.1f} kHz** "
                  f"(without polymer: {zpk_np * 1000:.0f} mOhm at {fpk_np / 1e3:.1f} kHz). "
                  f"A 1 A step at that frequency would move the rail by about {zpk:.2f} V.")
    REPORT.append("\n![S2](s2-halow-rail.png)\n")
    return vmin, zpk, fpk


# ------------------------------------------------------------------------------------------------
# S3/S4 behavioural sequencing model
# ------------------------------------------------------------------------------------------------
class Corner:
    """One sample of every tolerance that matters for sequencing."""

    def __init__(self, rng=None, r31=None):
        u = (lambda a, b: rng.uniform(a, b)) if rng else (lambda a, b: (a + b) / 2)
        tol = (lambda x, p: x * u(1 - p, 1 + p))
        self.r31 = tol(r31 or val("R31"), 0.01)
        self.r32 = tol(val("R32"), 0.01)
        self.von = u(0.76, 0.84)
        self.r15, self.r16 = tol(val("R15"), 0.01), tol(val("R16"), 0.01)
        self.ven = u(1.20, 1.26)
        self.ven_hys = 0.100
        self.r1, self.r2 = tol(val("R1"), 0.01), tol(val("R2"), 0.01)
        self.uvlo_r, self.uvlo_f = u(1.176, 1.224), u(1.09, 1.15)   # TPS2663 UVLO spread ~ OVP spread (inference)
        self.blank = u(0.304, 0.720)
        self.lockout = u(0.6, 1.4)
        self.debounce = u(0.019, 0.045)
        self.pi_delay = u(0.002, 0.050)

    def on_level(self):
        return self.von * (self.r31 + self.r32) / self.r32

    def en_level(self):
        return self.ven * (self.r15 + self.r16) / self.r16


def simulate(c, vbat_fn, t_end, auto_on=True, pb_at=(), halt_at=None, usbc=False, dt=0.001):
    """Return a list of (t, vbat, ltc_on, buck5_on, pi3v3, kill_ok) samples."""
    st = dict(ltc=False, blank_until=-1, lock_until=-1, buck=False, pi_since=None, efuse=False,
              on_prev=False, on_edge_at=None, halted=False)
    trace = []
    t = 0.0
    while t <= t_end:
        vb = vbat_fn(t)
        # eFuse UVLO with hysteresis
        if not st["efuse"] and vb > c.uvlo_r * (c.r1 + c.r2) / c.r2:
            st["efuse"] = True
        elif st["efuse"] and vb < c.uvlo_f * (c.r1 + c.r2) / c.r2:
            st["efuse"] = False
        vsys = vb if st["efuse"] else 0.0
        ltc_powered = vsys > 1.0
        if not ltc_powered:
            st.update(ltc=False, on_prev=False, on_edge_at=None)
        # ON rising edge (TS8: falling edge ignored), debounced
        on = auto_on and vsys > c.on_level()
        if on and not st["on_prev"] and ltc_powered:
            st["on_edge_at"] = t
        st["on_prev"] = on
        want_on = False
        if st["on_edge_at"] is not None and t - st["on_edge_at"] >= c.debounce:
            st["on_edge_at"] = None
            want_on = on
        if any(abs(t - p) < dt / 2 for p in pb_at) and ltc_powered:
            want_on = True
        if want_on and not st["ltc"] and t >= st["lock_until"]:
            st.update(ltc=True, blank_until=t + c.blank, halted=False)
        # 5 V buck: EN = divider AND eFuse PGOOD AND LTC on (Q7)
        en_v = vsys * c.r16 / (c.r15 + c.r16)
        thr = c.ven if not st["buck"] else c.ven - c.ven_hys
        st["buck"] = st["ltc"] and st["efuse"] and en_v > thr * (1 if not st["buck"] else 1)
        # Pi 3.3 V appears a little after 5 V; with USB-C the Pi is powered anyway
        if st["buck"] or usbc:
            st["pi_since"] = st["pi_since"] if st["pi_since"] is not None else t
        else:
            st["pi_since"] = None
        pi_up = st["pi_since"] is not None and t - st["pi_since"] >= c.pi_delay
        if halt_at is not None and t >= halt_at:
            st["halted"] = True
        kill_ok = pi_up and not st["halted"]           # R33 pull-up to 3V3_PI; GPIO27 high on halt
        if st["ltc"] and t >= st["blank_until"] and not kill_ok:
            st.update(ltc=False, lock_until=t + c.lockout)
        trace.append((t, vb, st["ltc"], st["buck"], pi_up, kill_ok))
        t += dt
    return trace


def final(trace):
    return trace[-1][2], trace[-1][3]


def s3():
    c = Corner()
    rows = []
    step = lambda v, t0=0.1: (lambda t: v if t >= t0 else 0.0)  # noqa: E731
    sc = [
        ("2S pack inserted (7.4 V), AUTO-ON closed", dict(vbat_fn=step(7.4), t_end=3), (True, True)),
        ("2S pack inserted (7.4 V), AUTO-ON open", dict(vbat_fn=step(7.4), t_end=3, auto_on=False), (False, False)),
        ("AUTO-ON open, button pressed at 1 s", dict(vbat_fn=step(7.4), t_end=3, auto_on=False, pb_at=(1.0,)), (True, True)),
        ("running, Linux halt at 3 s", dict(vbat_fn=step(12.0), t_end=5, halt_at=3.0), (False, False)),
        ("4S full pack (16.8 V), AUTO-ON closed", dict(vbat_fn=step(16.8), t_end=3), (True, True)),
        ("12 V adapter, AUTO-ON closed", dict(vbat_fn=step(12.0), t_end=3), (True, True)),
        ("battery sags to 5.7 V for 5 s, then recovers to 7.4 V",
         dict(vbat_fn=lambda t: 7.4 if t < 2 or t > 7 else 5.7, t_end=12), (True, True)),
        ("pack 6.6 V (2S nearly empty), AUTO-ON closed", dict(vbat_fn=step(6.6), t_end=3), (False, False)),
    ]
    REPORT.append("## S3 Power sequencing scenarios (behavioural model, nominal values)\n")
    REPORT.append("| scenario | expected | LTC2955 on | 5 V buck on | result |")
    REPORT.append("|---|---|---|---|---|")
    fails = []
    for name, kw, exp in sc:
        tr = simulate(c, **kw)
        got = final(tr)
        ok = got == exp
        if not ok:
            fails.append(name)
        REPORT.append(f"| {name} | {'on' if exp[1] else 'off'} | {got[0]} | {got[1]} | {'OK' if ok else 'FAIL'} |")
    REPORT.append("\nNote: 6.6 V is below AUTO-ON (7.10 V typ) by design, so a nearly empty 2S pack does "
                  "not start by itself; a button press still starts it if VSYS > 6.40 V.\n")
    REPORT.append("USB-C-only bench mode: LTC2955 has no supply, EN-bar = 0 V, so Q8 is off and the HaLow "
                  "3.3 V buck runs; the 5 V buck has no input. (Direct consequence of the schematic, "
                  "not simulated in time.)\n")
    return fails


def s4():
    """Slow recovery: 5.0 V -> 8.4 V at 0.05 V/s; count 'stuck off' across tolerance corners."""
    rng = random.Random(1)
    res = {}
    traces = {}
    for label, r31 in (("old R31 = 681k (before review)", 681e3), ("new R31 = 787k (design)", None)):
        stuck = 0
        n = 400
        worst = None
        for i in range(n):
            c = Corner(rng, r31)
            ramp = lambda t: min(8.4, 5.0 + 0.05 * t)  # noqa: E731
            tr = simulate(c, ramp, 80, dt=0.005)
            if not tr[-1][2]:
                stuck += 1
                worst = worst or tr
        res[label] = (stuck, n)
        c = Corner(None, r31)
        traces[label] = simulate(c, lambda t: min(8.4, 5.0 + 0.05 * t), 80, dt=0.005)
        if worst:
            traces[label + " (a failing corner)"] = worst
    fig, ax = plt.subplots(figsize=(8, 3.6), facecolor=SURF)
    cols = [C2, C4, C1]
    for (lab, tr), col in zip(traces.items(), cols):
        ax.step([x[0] for x in tr], [1 if x[3] else 0 for x in tr], color=col, linewidth=2, where="post",
                label=lab)
    style(ax, "S4  Battery recovering 5.0 -> 8.4 V at 0.05 V/s: is the Pi powered at the end?",
          "time (s)", "5 V buck on (1) / off (0)")
    ax.set_yticks([0, 1])
    ax.legend(frameon=False, fontsize=8, loc="center right")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, "s4-slow-recovery.png"), dpi=160)
    plt.close(fig)
    REPORT.append("## S4 Slowly recovering battery, AUTO-ON closed (behavioural model, Monte Carlo)\n")
    REPORT.append("Ramp 5.0 -> 8.4 V at 0.05 V/s (solar / cold pack warming up). Each run samples the "
                  "resistor tolerances (1 %), LTC2955 ON threshold (0.76-0.84 V), LMR33640 EN threshold "
                  "(1.20-1.26 V), blanking (304-720 ms), lockout (0.6-1.4 s) and the Pi 3.3 V delay.\n")
    REPORT.append("| AUTO-ON divider | runs that end with the node OFF |")
    REPORT.append("|---|---|")
    for lab, (s, n) in res.items():
        REPORT.append(f"| {lab} | **{s} / {n}** |")
    REPORT.append("\n![S4](s4-slow-recovery.png)\n")
    return res


def main():
    os.makedirs(OUT, exist_ok=True)
    trip, _ = s1_hotplug()
    vmin, zpk, fpk = s2()
    fails3 = s3()
    res4 = s4()
    head = ["# Batman HAT v1 - pre-fab simulation report", "",
            "Generated by `hardware/hat-v1/sim/run_all.py`. S1/S2 use ngspice (the engine inside KiCad); "
            "S3/S4 use a behavioural model written from the LTC2955, LMR33640 and TPS2663 datasheets, "
            "because no vendor SPICE model runs in ngspice. **A simulation is only as good as its "
            "assumptions** - they are listed at the end.", "", "## Summary", ""]
    new_stuck = res4["new R31 = 787k (design)"][0]
    old_stuck = res4["old R31 = 681k (before review)"][0]
    head += [f"- S1 hot-plug: with the damper, the peak exceeds the OVP minimum in {len(trip)} of 9 cases"
             + (f" ({', '.join(f'{v} V / {l * 1e6:.1f} uH' for v, l in trip)})" if trip else "")
             + ". A trip also needs >= 8.5 us above the threshold; a trip only delays start-up (auto-recovery), "
             "it does not damage anything.",
             f"- S2 HaLow rail: minimum {vmin:.3f} V at the socket during 1.2 A bursts; filter resonance "
             f"{zpk * 1000:.0f} mOhm at {fpk / 1e3:.1f} kHz.",
             f"- S3 sequencing: {len(fails3)} scenario(s) behave differently from the design intent"
             + (": " + "; ".join(fails3) if fails3 else "."),
             f"- S4 slow recovery: node stuck OFF in {new_stuck} runs with the current divider "
             f"(was {old_stuck} with the pre-review 681k).", ""]
    tail = ["## Assumptions", "", "| item | value used |", "|---|---|"]
    tail += [f"| {k} | {v} |" for k, v in ASSUMPTIONS.items()]
    with open(os.path.join(OUT, "sim-report.md"), "w") as fh:
        fh.write("\n".join(head + REPORT + tail) + "\n")
    print("\n".join(head))


if __name__ == "__main__":
    main()
