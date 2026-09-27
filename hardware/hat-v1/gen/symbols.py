"""Schematic symbols for the Batman HAT, generated as KiCad 7 lib_symbols.

Pin tuples: (name, [pad numbers], type). The first number is the visible
pin; extra numbers are stacked, hidden pins on the same point (e.g. GND
pads, exposed pads). Pin maps were cross-checked against the KiCad 7
stock libraries (TPS2663x, LMR33640, TPS62933, LM74700, INA226, AT24CS32,
ATECC608, MAX-M10S) and the datasheets (LTC2955 TS8, SLB9672, RV-3028).
"""

G = 2.54
TYPES = {"in": "input", "out": "output", "bi": "bidirectional", "pwr": "power_in",
         "pout": "power_out", "pas": "passive", "oc": "open_collector", "nc": "no_connect"}

IC = {
    "TPS26631RGE": dict(left=[
        ("IN", ["1", "2"], "pwr"), ("IN_SYS", ["5"], "pwr"), ("UVLO", ["6"], "in"),
        ("OVP", ["7"], "in"), ("~{SHDN}", ["12"], "in"), ("MODE", ["11"], "in"),
        ("dVdT", ["9"], "pas"), ("ILIM", ["10"], "pas"), ("GND", ["8", "25"], "pwr")],
        right=[("OUT", ["17", "18"], "pout"), ("B_GATE", ["3"], "out"), ("DRV", ["4"], "out"),
               ("PGTH", ["15"], "in"), ("PGOOD", ["16"], "oc"), ("~{FLT}", ["14"], "oc"),
               ("IMON", ["13"], "out")]),
    "INA226": dict(left=[
        ("VS", ["6"], "pwr"), ("IN+", ["10"], "in"), ("IN-", ["9"], "in"), ("VBUS", ["8"], "in"),
        ("A0", ["2"], "in"), ("A1", ["1"], "in"), ("GND", ["7"], "pwr")],
        right=[("SDA", ["4"], "bi"), ("SCL", ["5"], "in"), ("~{ALERT}", ["3"], "oc")]),
    "LMR33640": dict(left=[
        ("VIN", ["2"], "pwr"), ("EN", ["3"], "in"), ("FB", ["5"], "in"), ("GND", ["1", "9"], "pwr")],
        right=[("SW", ["8"], "pout"), ("BOOT", ["7"], "pas"), ("VCC", ["6"], "pout"),
               ("PG", ["4"], "oc")]),
    "LM74700": dict(left=[("ANODE", ["6"], "pwr"), ("EN", ["3"], "in"), ("GND", ["2"], "pwr")],
                    right=[("CATHODE", ["4"], "pas"), ("GATE", ["5"], "out"), ("VCAP", ["1"], "pas")]),
    "TPS62933F": dict(left=[
        ("VIN", ["3"], "pwr"), ("EN", ["2"], "in"), ("RT", ["1"], "in"), ("SS", ["7"], "pas"),
        ("GND", ["4"], "pwr")],
        right=[("SW", ["5"], "pout"), ("BST", ["6"], "pas"), ("FB", ["8"], "in")]),
    "LTC2955TS8": dict(left=[
        ("VIN", ["6"], "pwr"), ("~{PB}", ["5"], "in"), ("ON", ["1"], "in"), ("~{KILL}", ["2"], "in"),
        ("TMR", ["3"], "pas"), ("GND", ["4"], "pwr")],
        right=[("~{EN}", ["7"], "out"), ("~{INT}", ["8"], "oc")]),
    "EEPROM_24": dict(left=[
        ("VCC", ["8"], "pwr"), ("A0", ["1"], "in"), ("A1", ["2"], "in"), ("A2", ["3"], "in"),
        ("WP", ["7"], "in"), ("GND", ["4"], "pwr")],
        right=[("SDA", ["5"], "bi"), ("SCL", ["6"], "in")]),
    "SLB9672": dict(left=[
        ("VDD", ["1", "14", "22"], "pwr"), ("NCI8 (VDD)", ["8"], "pas"), ("~{RST}", ["17"], "in"),
        ("PP10 (pull-up)", ["10"], "pas"), ("NCI16 (GND)", ["16"], "pas"),
        ("GND", ["2", "9", "23", "32", "33"], "pwr")],
        right=[("SCLK", ["19"], "in"), ("~{CS}", ["20"], "in"), ("MOSI", ["21"], "in"),
               ("MISO", ["24"], "out"), ("~{PIRQ}", ["18"], "oc")]),
    "ATECC608": dict(left=[("VCC", ["8"], "pwr"), ("GND", ["4"], "pwr")],
                     right=[("SDA", ["5"], "bi"), ("SCL", ["6"], "in")]),
    "RV3028": dict(left=[
        ("VDD", ["7"], "pwr"), ("VBACKUP", ["6"], "pas"), ("EVI", ["8"], "in"), ("VSS", ["5"], "pwr")],
        right=[("SCL", ["3"], "in"), ("SDA", ["4"], "bi"), ("~{INT}", ["2"], "oc"),
               ("CLKOUT", ["1"], "out")]),
    "MAXM10S": dict(left=[
        ("VCC", ["8"], "pwr"), ("VCC_IO", ["7"], "pwr"), ("V_BCKP", ["6"], "pwr"),
        ("VCC_RF", ["14"], "pout"), ("RF_IN", ["11"], "in"), ("GND", ["1", "10", "12"], "pwr")],
        right=[("TXD", ["2"], "out"), ("RXD", ["3"], "in"), ("TIMEPULSE", ["4"], "out"),
               ("EXTINT", ["5"], "in"), ("~{RESET}", ["9"], "in"), ("~{SAFEBOOT}", ["18"], "in"),
               ("LNA_EN", ["13"], "out"), ("VIO_SEL", ["15"], "in"), ("SDA", ["16"], "bi"),
               ("SCL", ["17"], "in")]),
    "TC2050": dict(left=[(str(n), [str(n)], "pas") for n in (1, 3, 5, 7, 9)],
                   right=[(str(n), [str(n)], "pas") for n in (2, 4, 6, 8, 10)]),
    "CONN2": dict(left=[("1", ["1"], "pas"), ("2", ["2"], "pas")], right=[]),
    "COAX": dict(left=[("SIG", ["1"], "pas"), ("SHIELD", ["2"], "pas")], right=[]),
    "NMOS": dict(left=[("G", ["1"], "in")], right=[("D", ["3"], "pas"), ("S", ["2"], "pas")]),
    "NMOS_SON8": dict(left=[("G", ["4"], "in")],
                      right=[("D", ["5", "6", "7", "8", "9"], "pas"), ("S", ["1", "2", "3"], "pas")]),
}

_PI = {1: "3V3", 2: "5V", 3: "GPIO2 SDA1", 4: "5V", 5: "GPIO3 SCL1", 6: "GND", 7: "GPIO4",
       8: "GPIO14 TXD0", 9: "GND", 10: "GPIO15 RXD0", 11: "GPIO17", 12: "GPIO18", 13: "GPIO27",
       14: "GND", 15: "GPIO22", 16: "GPIO23", 17: "3V3", 18: "GPIO24", 19: "GPIO10 MOSI0",
       20: "GND", 21: "GPIO9 MISO0", 22: "GPIO25", 23: "GPIO11 SCLK0", 24: "GPIO8 CE0",
       25: "GND", 26: "GPIO7 CE1", 27: "GPIO0 ID_SD", 28: "GPIO1 ID_SC", 29: "GPIO5", 30: "GND",
       31: "GPIO6", 32: "GPIO12 TXD5", 33: "GPIO13 RXD5", 34: "GND", 35: "GPIO19 MISO1",
       36: "GPIO16", 37: "GPIO26", 38: "GPIO20 MOSI1", 39: "GND", 40: "GPIO21 SCLK1"}
IC["PI_GPIO40"] = dict(
    left=[(_PI[n], [str(n)], "pwr" if _PI[n] in ("3V3", "5V", "GND") else "bi")
          for n in range(1, 41, 2)],
    right=[(_PI[n], [str(n)], "pwr" if _PI[n] in ("3V3", "5V", "GND") else "bi")
           for n in range(2, 41, 2)])
# 5V pins are where the HAT *feeds* the Pi: make them passive so ERC does not
# demand a second driver.
IC["PI_GPIO40"]["right"] = [(n, p, "pas" if n.startswith("5V") else t) for n, p, t in IC["PI_GPIO40"]["right"]]
IC["PI_GPIO40"]["left"] = [(n, p, "pas" if "3V3" in n else t) for n, p, t in IC["PI_GPIO40"]["left"]]

_MP = {1: "WAKE#", 3: "COEX1", 5: "COEX2", 7: "CLKREQ#", 9: "GND", 11: "REFCLK-", 13: "REFCLK+",
       15: "GND", 17: "UIM_C8", 19: "UIM_C4", 21: "GND", 23: "PERn0", 25: "PERp0", 27: "GND",
       29: "GND", 31: "PETn0 / MOD_BUSY", 33: "PETp0 / MOD_WAKEUP", 35: "GND", 37: "GND",
       39: "+3.3Vaux", 41: "+3.3Vaux", 43: "GND", 45: "PCM_CLK / SCK", 47: "PCM_DOUT / MISO",
       49: "PCM_DIN / MOSI", 51: "PCM_SYNC / CS", 2: "+3.3Vaux", 4: "GND", 6: "+1.5V",
       8: "UIM_PWR", 10: "UIM_DATA / MOD_INT", 12: "UIM_CLK", 14: "UIM_RESET", 16: "UIM_VPP",
       18: "GND", 20: "W_DISABLE#", 22: "PERST# / MOD_RESET", 24: "+3.3Vaux", 26: "GND",
       28: "+1.5V", 30: "SMB_CLK", 32: "SMB_DATA", 34: "GND", 36: "USB_D-", 38: "USB_D+",
       40: "GND", 42: "LED_WWAN#", 44: "LED_WLAN#", 46: "LED_WPAN#", 48: "+1.5V", 50: "GND",
       52: "+3.3Vaux"}
IC["MPCIE52"] = dict(
    left=[(_MP[n], [str(n)], "pas") for n in range(1, 52, 2)] + [("MP", ["53"], "pas")],
    right=[(_MP[n], [str(n)], "pas") for n in range(2, 53, 2)] + [("MP", ["54"], "pas")])

TWO = ["R", "C", "CP", "L", "FB", "LED", "TVS_BI", "TVS_UNI", "SJ", "SW_PUSH"]
ONE = ["TP", "MH", "PWR_FLAG"]
REF_PREFIX = {"R": "R", "C": "C", "CP": "C", "L": "L", "FB": "FB", "LED": "D", "TVS_BI": "D",
              "TVS_UNI": "D", "SJ": "JP", "SW_PUSH": "SW", "TP": "TP", "MH": "H",
              "PWR_FLAG": "#FLG"}


def ic_geometry(name):
    s = IC[name]
    n = max(len(s["left"]), len(s["right"]), 1)
    lw = max([len(p[0]) for p in s["left"]] + [0])
    rw = max([len(p[0]) for p in s["right"]] + [0])
    w = max(4 * G, round(((lw + rw) * 1.3 + 6) / G) * G)
    if name.startswith("NMOS"):
        w = 4 * G
    h = (n + 1) * G
    top = (n - 1) / 2 * G  # y of the first pin (lib coords, y up)
    top = round(top / 1.27) * 1.27
    pins = []  # (numbers, name, type, x, y, angle, side)
    for i, (pn, nums, t) in enumerate(s["left"]):
        pins.append((nums, pn, t, -(w / 2 + G), top - i * G, 0, "L"))
    for i, (pn, nums, t) in enumerate(s["right"]):
        pins.append((nums, pn, t, (w / 2 + G), top - i * G, 180, "R"))
    return dict(w=w, h=h, top=top + G, bottom=top - n * G, pins=pins)


def geometry(sym):
    """Pin connection points in lib coordinates (y up)."""
    if sym in IC:
        return ic_geometry(sym)
    if sym in TWO:
        return dict(w=5.08, h=2.54, top=1.27, bottom=-1.27,
                    pins=[(["1"], "~", "pas", -3.81, 0, 0, "L"), (["2"], "~", "pas", 3.81, 0, 180, "R")])
    if sym in ONE:
        t = "pout" if sym == "PWR_FLAG" else "pas"
        return dict(w=2.54, h=2.54, top=1.27, bottom=-1.27, pins=[(["1"], "~", t, -2.54, 0, 0, "L")])
    raise KeyError(sym)


def _f(v):
    return f"{v:.4f}".rstrip("0").rstrip(".")


def _pin(t, x, y, ang, length, name, num, hide=False):
    return (f'(pin {TYPES[t]} line (at {_f(x)} {_f(y)} {ang}) (length {_f(length)}){" hide" if hide else ""} '
            f'(name "{name}" (effects (font (size 1.27 1.27)))) '
            f'(number "{num}" (effects (font (size 1.27 1.27)))))')


def _poly(pts, width=0.254, fill="none"):
    xy = " ".join(f"(xy {_f(x)} {_f(y)})" for x, y in pts)
    return f"(polyline (pts {xy}) (stroke (width {width}) (type default)) (fill (type {fill})))"


def _rect(x0, y0, x1, y1, width=0.254, fill="none"):
    return (f"(rectangle (start {_f(x0)} {_f(y0)}) (end {_f(x1)} {_f(y1)}) "
            f"(stroke (width {width}) (type default)) (fill (type {fill})))")


def lib_symbol(sym):
    g = geometry(sym)
    body, pins = [], []
    pnames = "(pin_names (offset 0.508))"
    if sym in IC:
        body.append(_rect(-g["w"] / 2, g["top"], g["w"] / 2, g["bottom"], fill="background"))
        for nums, pn, t, x, y, ang, side in g["pins"]:
            for k, num in enumerate(nums):
                pins.append(_pin(t, x, y, ang, G, pn, num, hide=k > 0))
        ref_at, val_at = (-g["w"] / 2, g["top"] + 1.27), (-g["w"] / 2, g["bottom"] - 1.27)
        pnums = ""
    else:
        if sym in TWO:
            for nums, pn, t, x, y, ang, side in g["pins"]:
                pins.append(_pin(t, x, y, ang, 1.27, pn, nums[0]))
            lead = [_poly([(-2.54, 0), (-0.9, 0)]), _poly([(0.9, 0), (2.54, 0)])]
            if sym == "R":
                body.append(_rect(-2.54, 1.016, 2.54, -1.016))
            elif sym in ("L", "FB"):
                body.append(_rect(-2.54, 0.762, 2.54, -0.762, fill="outline" if sym == "FB" else "none"))
                if sym == "L":
                    for k in range(4):
                        x0 = -2.54 + k * 1.27
                        body.append(f"(arc (start {_f(x0)} 0) (mid {_f(x0 + 0.635)} 0.635) (end {_f(x0 + 1.27)} 0) "
                                    f"(stroke (width 0.254) (type default)) (fill (type none)))")
                    body = [b for b in body if not b.startswith("(rectangle")]
            elif sym in ("C", "CP"):
                body += lead[:1] + lead[1:]
                body.append(_poly([(-0.508, 2.032), (-0.508, -2.032)], 0.508))
                body.append(_poly([(0.508, 2.032), (0.508, -2.032)], 0.508 if sym == "C" else 0.254))
                if sym == "CP":
                    body.append(_poly([(-2.032, 1.524), (-1.016, 1.524)]))
                    body.append(_poly([(-1.524, 2.032), (-1.524, 1.016)]))
            elif sym in ("LED", "TVS_UNI"):  # pin 1 = cathode (left)
                body.append(_poly([(1.27, 1.27), (1.27, -1.27), (-1.27, 0), (1.27, 1.27)], fill="none"))
                body.append(_poly([(-1.27, 1.27), (-1.27, -1.27)]))
                body.append(_poly([(-2.54, 0), (2.54, 0)]))
                if sym == "LED":
                    body.append(_poly([(0, 1.778), (1.016, 2.794)]))
                    body.append(_poly([(1.016, 1.778), (2.032, 2.794)]))
                else:
                    body.append(_poly([(-1.778, 1.778), (-1.27, 1.27)]))
            elif sym == "TVS_BI":
                body.append(_poly([(-2.54, 1.27), (-2.54, -1.27), (0, 0), (-2.54, 1.27)]))
                body.append(_poly([(2.54, 1.27), (2.54, -1.27), (0, 0), (2.54, 1.27)]))
                body.append(_poly([(-0.508, 1.778), (0, 1.27), (0, -1.27), (0.508, -1.778)]))
            elif sym == "SJ":
                body.append(_rect(-1.524, 1.016, -0.254, -1.016, fill="outline"))
                body.append(_rect(0.254, 1.016, 1.524, -1.016, fill="outline"))
                body += [_poly([(-2.54, 0), (-1.524, 0)]), _poly([(1.524, 0), (2.54, 0)])]
            elif sym == "SW_PUSH":
                body += [_poly([(-2.54, 0), (-1.524, 0)]), _poly([(1.524, 0), (2.54, 0)]),
                         _poly([(-1.524, 1.016), (1.524, 1.778)]), _poly([(0, 1.524), (0, 2.54)])]
            if sym == "R":
                pass
            ref_at, val_at = (0, 2.54), (0, -2.54)
        else:  # one pin
            pins.append(_pin(g["pins"][0][2], -2.54, 0, 0, 1.27, "~", "1"))
            if sym == "PWR_FLAG":
                body.append(_poly([(-1.27, 0), (0, 1.016), (1.27, 0), (0, -1.016), (-1.27, 0)]))
            else:
                body.append(f"(circle (center 0 0) (radius 1.27) (stroke (width 0.254) (type default)) "
                            f"(fill (type {'outline' if sym == 'MH' else 'none'})))")
            ref_at, val_at = (0, 2.032), (0, -2.54)
        pnums = "(pin_numbers hide) "
        pnames = "(pin_names (offset 0) hide)"
    power = "(power) " if sym == "PWR_FLAG" else ""
    props = "\n".join([
        f'(property "Reference" "{REF_PREFIX.get(sym, "U")}" (at {_f(ref_at[0])} {_f(ref_at[1])} 0) (effects (font (size 1.27 1.27))))',
        f'(property "Value" "{sym}" (at {_f(val_at[0])} {_f(val_at[1])} 0) (effects (font (size 1.27 1.27))))',
        '(property "Footprint" "" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))',
        '(property "Datasheet" "" (at 0 0 0) (effects (font (size 1.27 1.27)) hide))',
    ])
    return (f'(symbol "batman:{sym}" {power}{pnums}{pnames} (in_bom {"no" if sym == "PWR_FLAG" else "yes"}) '
            f'(on_board {"no" if sym == "PWR_FLAG" else "yes"})\n{props}\n'
            f'(symbol "{sym}_0_1" {" ".join(body)})\n(symbol "{sym}_1_1" {" ".join(pins)})\n)')
