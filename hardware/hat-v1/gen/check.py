#!/usr/bin/env python3
"""Verify the generated schematic.

1. Connectivity: export KiCad's own netlist (kicad-cli) and compare every
   pin against design.py. Catches generator bugs (labels not touching pins,
   wrong pin numbers, accidental merges).
2. Design rules taken from docs/design/hat-v1-spec.md:
   GPIO table, I2C addresses, no test points on TPM nets, pin voltage limits,
   single-pin nets, resistor-divider set points.
Writes out/check-report.md; exit code 1 on any error.
"""
import os
import re
import subprocess
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
import design as D  # noqa: E402

HERE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUTDIR = os.path.join(HERE, "out")
errors, warns, infos = [], [], []


def err(m):
    errors.append(m)


def warn(m):
    warns.append(m)


def info(m):
    infos.append(m)


def kicad_netlist():
    os.makedirs(OUTDIR, exist_ok=True)
    path = os.path.join(OUTDIR, "batman-hat.net")
    subprocess.run(["kicad-cli", "sch", "export", "netlist", "-o", path,
                    os.path.join(HERE, f"{D.PROJECT}.kicad_sch")], check=True, capture_output=True)
    txt = open(path).read()
    pin_net = {}
    for m in re.finditer(r'\(net \(code "\d+"\) \(name "([^"]*)"\)(.*?)\)\s*(?=\(net |\)\s*\)\s*$)', txt, re.S):
        name = m.group(1)
        for ref, pin in re.findall(r'\(node \(ref "([^"]+)"\) \(pin "([^"]+)"\)', m.group(2)):
            pin_net[(ref, pin)] = name
    comps = set(re.findall(r'\(comp \(ref "([^"]+)"\)', txt))
    return pin_net, comps


def strip(net):
    if net.startswith("unconnected-"):
        return None
    return net.rsplit("/", 1)[-1]


def check_connectivity():
    pin_net, comps = kicad_netlist()
    want = {}
    for p in D.PARTS:
        if p.ref.startswith("#"):
            continue
        if p.ref not in comps:
            err(f"{p.ref} missing from KiCad netlist")
        for pin, net in p.pins.items():
            want[(p.ref, pin)] = net
    for key, net in want.items():
        got = strip(pin_net.get(key, "unconnected-"))
        if got != net:
            err(f"connectivity {key[0]} pin {key[1]}: design={net} kicad={got}")
    extra = {k for k in pin_net if k not in want and not k[0].startswith("#")}
    for k in sorted(extra):
        err(f"KiCad has pin {k} that design.py does not list")
    # merged nets: two design nets mapped to one KiCad net name
    by_kicad = defaultdict(set)
    for key, net in want.items():
        if net:
            by_kicad[strip(pin_net.get(key, ""))].add(net)
    for k, s in by_kicad.items():
        if len(s) > 1:
            err(f"KiCad merged nets {sorted(s)} into {k}")
    info(f"connectivity: {len(want)} pins compared against KiCad's netlist export")


def nets():
    m = defaultdict(list)
    for p in D.PARTS:
        for pin, net in p.pins.items():
            if net:
                m[net].append((p.ref, pin))
    return m


def check_single_pin_nets():
    for net, nodes in nets().items():
        real = [n for n in nodes if not n[0].startswith(("#", "TP"))]
        if len(real) < 2 and net in D.SINGLE_PIN_OK:
            info(f"single-pin net {net}: {D.SINGLE_PIN_OK[net]}")
        elif len(real) < 2:
            err(f"net {net} has only {nodes} (floating / dangling)")


def check_gpio():
    j2 = next(p for p in D.PARTS if p.ref == "J2")
    for bcm, net in D.SPEC_GPIO.items():
        phys = str(D.BCM_TO_PHYS[bcm])
        got = j2.pins.get(phys)
        if got != net:
            err(f"GPIO{bcm} (pin {phys}): spec={net} design={got}")
    info("GPIO table (spec 4.2) matches J2 for all 28 GPIOs")


def check_tpm_testpoints():
    bad = [(p.ref, n) for p in D.PARTS if p.sym == "TP" for n in p.pins.values()
           if n and (n.startswith("TPM_") or n.startswith("SPI1_"))]
    for r, n in bad:
        err(f"{r} is a test point on security net {n} (spec 5.1 forbids)")
    j5 = next(p for p in D.PARTS if p.ref == "J5")
    for n in j5.pins.values():
        if n and (n.startswith("TPM_") or n.startswith("SPI1_")):
            err(f"Tag-Connect exposes {n}")
    if not bad:
        info("no test points on TPM_* / SPI1_* nets")


def check_i2c():
    addr = {}
    for p in D.PARTS:
        if p.value.startswith("INA226"):
            a0, a1 = p.pins["2"], p.pins["1"]
            code = {"GND": 0, "3V3_PI": 1}
            a = 0x40 + code[a0] + 4 * code[a1]
            addr.setdefault(a, []).append(p.ref)
        elif p.value.startswith("ATECC608C-TFLXTLS"):
            addr.setdefault(0x36, []).append(p.ref)
        elif p.value.startswith("RV-3028"):
            addr.setdefault(0x52, []).append(p.ref)
    for a, refs in addr.items():
        if len(refs) > 1:
            err(f"I2C1 address 0x{a:02x} used by {refs}")
    info("I2C1 addresses: " + ", ".join(f"0x{a:02x}={'/'.join(r)}" for a, r in sorted(addr.items())))
    want = {0x40, 0x41, 0x36, 0x52}
    if set(addr) != want:
        err(f"I2C1 address set {sorted(map(hex, addr))} != spec {sorted(map(hex, want))}")


def check_voltages():
    n = 0
    for p in D.PARTS:
        for (prefix, pin), vmax in D.PIN_VMAX.items():
            if not p.value.startswith(prefix):
                continue
            if prefix == "BSS138" and p.pins["2"] != "GND":
                # Vgs / Vds are relative to a floating source: model does not apply
                info(f"{p.ref}: source on {p.pins['2']}, ground-referenced limit skipped (see note)")
                continue
            net = p.pins.get(pin)
            if not net:
                continue
            if net not in D.NET_VMAX:
                err(f"{p.ref} pin {pin} ({prefix}, abs max {vmax} V) on net {net} with no NET_VMAX")
                continue
            n += 1
            if D.NET_VMAX[net] > vmax:
                err(f"{p.ref} pin {pin}: net {net} reaches {D.NET_VMAX[net]:.2f} V > abs max {vmax} V")
    # every net on a Pi GPIO must be a 3.3 V net
    j2 = next(p for p in D.PARTS if p.ref == "J2")
    for bcm, phys in D.BCM_TO_PHYS.items():
        net = j2.pins[str(phys)]
        if net and net in D.NET_VMAX and D.NET_VMAX[net] > 3.4:
            err(f"GPIO{bcm} net {net} can reach {D.NET_VMAX[net]} V")
    info(f"pin voltage limits: {n} datasheet limits checked")


def val(ref):
    p = next(p for p in D.PARTS if p.ref == ref)
    m = re.match(r"([\d.]+)\s*([kKM]?)", p.value)
    mult = {"": 1, "k": 1e3, "K": 1e3, "M": 1e6}[m.group(2)]
    return float(m.group(1)) * mult


def check_setpoints():
    rows = []

    def row(name, got, lo, hi, unit, src):
        ok = lo <= got <= hi
        rows.append(f"| {name} | {got:.3f} {unit} | {lo}-{hi} | {'OK' if ok else 'FAIL'} | {src} |")
        if not ok:
            err(f"set point {name} = {got:.3f} {unit}, expected {lo}-{hi}")

    div = lambda top, bot: (val(top) + val(bot)) / val(bot)  # noqa: E731
    row("eFuse UVLO rising", 1.2 * div("R1", "R2"), 5.7, 5.9, "V", "TPS2663 1.2 V")
    row("eFuse UVLO falling", 1.122 * div("R1", "R2"), 5.3, 5.5, "V", "TPS2663 1.122 V")
    row("eFuse OVP trip", 1.2 * div("R3", "R4"), 19.0, 19.4, "V", "TPS2663 1.2 V")
    row("eFuse OVP release (min)", 1.09 * div("R3", "R4"), 17.0, 99, "V", "OVPF min 1.09 V > 4S full 16.8 V")
    row("eFuse OVP trip (max)", 1.224 * div("R3", "R4"), 0, 20.0, "V", "LTC2955 VIN <=20 V without RC")
    row("eFuse current limit", 18e3 / val("R5"), 4.8, 5.2, "A", "I = 18 kOhm*A / R_ILIM")
    row("PGOOD threshold", 1.2 * div("R6", "R7"), 5.7, 5.9, "V", "PGTH 1.2 V (rising)")
    row("5 V buck output", 1.0 * div("R13", "R14"), 5.10, 5.25, "V", "LMR33640 VFB 1.0 V")
    row("5 V buck EN on", 1.231 * div("R15", "R16"), 6.3, 6.5, "V", "EN 1.231 V")
    row("5 V buck EN off", (1.231 - 0.1) * div("R15", "R16"), 5.8, 6.0, "V", "hysteresis 100 mV")
    row("3.3 V buck output", 0.8 * div("R20", "R21"), 3.28, 3.38, "V", "TPS62933F VFB 0.8 V")
    row("AUTO-ON threshold", 0.8 * div("R31", "R32"), 6.9, 7.3, "V", "LTC2955 ON 0.8 V")
    row("AUTO-ON min - 5V EN-on max", 0.76 * div("R31", "R32") - 1.26 * div("R15", "R16"), 0.1, 99, "V",
        "ON min 0.76 V vs LMR EN max 1.26 V: LTC must never turn on before the buck can")
    row("5 V out worst case high", 1.015 * (val("R13") * 1.005 + val("R14") * 0.995) / (val("R14") * 0.995), 0, 5.30,
        "V", "VFB max 1.015 V, 0.5% resistors")
    row(f"LTC EN-bar gate @{D.VBAT_MAX} V", D.VBAT_MAX * val("R30") / (val("R30") + 900e3), 0, 12, "V", "900k internal")
    row("LTC EN-bar gate @5.8 V", 5.8 * val("R30") / (val("R30") + 900e3), 2.0, 99, "V", "BSS138 Vth max 1.5 V")
    row("BAT_PRESENT gate @5.4 V", 5.4 * val("R11") / (val("R10") + val("R11")), 2.0, 99, "V", "BSS138 Vth max 1.5 V")
    row("BAT_PRESENT gate @22 V", 22.2 * val("R11") / (val("R10") + val("R11")), 0, 20, "V", "Vgs max 20 V")
    return rows


def main():
    check_connectivity()
    check_single_pin_nets()
    check_gpio()
    check_tpm_testpoints()
    check_i2c()
    check_voltages()
    rows = check_setpoints()
    parts = [p for p in D.PARTS if not p.ref.startswith("#")]
    tiers = defaultdict(int)
    for p in parts:
        tiers[p.tier] += 1
    rep = ["# Batman HAT v1 - schematic check report", "",
           f"Generated by `hardware/hat-v1/gen/check.py` for rev {D.REV}. "
           f"{len(parts)} parts, {len(nets())} nets, tiers: "
           + ", ".join(f"{k}={v}" for k, v in sorted(tiers.items())), "",
           f"**Result: {'PASS' if not errors else 'FAIL'}** - {len(errors)} errors, {len(warns)} warnings", ""]
    rep += ["## Errors"] + ([f"- {e}" for e in errors] or ["- none"]) + [""]
    rep += ["## Warnings"] + ([f"- {w}" for w in warns] or ["- none"]) + [""]
    rep += ["## Checks passed"] + [f"- {i}" for i in infos] + [""]
    rep += ["## Set points computed from the resistor values", "",
            "| item | computed | expected | result | basis |", "|---|---|---|---|---|"] + rows + [""]
    os.makedirs(OUTDIR, exist_ok=True)
    with open(os.path.join(OUTDIR, "check-report.md"), "w") as fh:
        fh.write("\n".join(rep) + "\n")
    print("\n".join(rep))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
