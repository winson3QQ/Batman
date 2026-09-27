#!/usr/bin/env python3
"""Generate the project footprints (batman.pretty).

MiniPCIe_Lianxin_XDMP-052-A01_H5.2 is drawn from the Lianxin XDMP-052-A01
drawing (recommended PCB layout, sheet 3). The others are PLACEHOLDERS
sized from package outlines only (except RV-3028-C7, drawn from the Application
Manual); each placeholder carries a 'PLACEHOLDER' fab note
and must be redrawn from the manufacturer land pattern before fab.
Origin of the mPCIe footprint = centre of the 1.60 mm locating hole
(pin-1 side); pads face +y, the card extends toward -y.
"""
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "batman.pretty")


def f(v):
    return f"{v:.4f}".rstrip("0").rstrip(".")


def pad(num, x, y, w, h, shape="roundrect", layers='"F.Cu" "F.Paste" "F.Mask"', kind="smd", drill=None):
    d = f" (drill {f(drill)})" if drill else ""
    rr = " (roundrect_rratio 0.25)" if shape == "roundrect" else ""
    return f'  (pad "{num}" {kind} {shape} (at {f(x)} {f(y)}) (size {f(w)} {f(h)}){d} (layers {layers}){rr})\n'


def rect(layer, x0, y0, x1, y1, w=0.05):
    return (f"  (fp_rect (start {f(x0)} {f(y0)}) (end {f(x1)} {f(y1)}) (stroke (width {w}) (type solid)) "
            f'(fill none) (layer "{layer}"))\n')


def text(kind, val, x, y, layer, hide=False):
    return (f'  (fp_text {kind} "{val}" (at {f(x)} {f(y)}) (layer "{layer}"){" hide" if hide else ""}\n'
            f"    (effects (font (size 0.8 0.8) (thickness 0.12))))\n")


def write(name, body, descr, attr="smd", h=None):
    s = (f'(footprint "{name}" (version 20221018) (generator batman_gen) (layer "F.Cu")\n'
         f'  (descr "{descr}")\n  (attr {attr})\n')
    if h is not None:
        s += f'  (property "Height" "{h}")\n'
    s += text("reference", "REF**", 0, -1.5, "F.SilkS") + text("value", name, 0, 1.5, "F.Fab") + body + ")\n"
    with open(os.path.join(OUT, name + ".kicad_mod"), "w") as fh:
        fh.write(s)


def mpcie():
    b = ""
    for n in range(1, 52, 2):     # odd row, +y side (away from the card)
        x = 0.70 + (n - 1) / 2 * 0.8 if n <= 15 else 10.30 + (n - 17) / 2 * 0.8
        b += pad(n, x, 4.10, 0.60, 2.00)
    for n in range(2, 53, 2):     # even row, card side
        x = 1.10 + (n - 2) / 2 * 0.8 if n <= 16 else 10.70 + (n - 18) / 2 * 0.8
        b += pad(n, x, -4.10, 0.60, 2.00)
    b += pad(53, -2.15, 3.50, 2.30, 3.20)
    b += pad(54, 27.15, 3.50, 2.30, 3.20)
    b += pad("", 0, 0, 1.60, 1.60, "circle", '"*.Cu" "*.Mask"', "np_thru_hole", 1.60)
    b += pad("", 25.0, 0, 1.10, 1.10, "circle", '"*.Cu" "*.Mask"', "np_thru_hole", 1.10)
    b += rect("F.Fab", -2.7, -4.6, 27.7, 2.0, 0.1)              # socket body (approx.)
    b += rect("F.CrtYd", -3.6, -5.4, 28.6, 5.4)
    # full-mini card outline + hold-down keep-outs (drawing sheet 3), on User.Drawings
    b += rect("Dwgs.User", -2.5, -50.95 + 1.5, 27.5, 1.5, 0.15)
    for x in (0.40, 24.60):
        b += rect("Dwgs.User", x - 2.9, -48.04 - 2.9, x + 2.9, -48.04 + 2.9, 0.1)
    b += text("user", "card 30x50.95 / holes at -48.04", 12.5, -25, "Dwgs.User")
    write("MiniPCIe_Lianxin_XDMP-052-A01_H5.2", b,
          "Mini PCIe 52P 0.8 mm, 5.2 mm high, Lianxin XDMP-052-A01 (LCSC C7498130)", h=5.2)


def placeholder(name, w, h, pads, height, descr):
    b = "".join(pad(*p) for p in pads)
    b += rect("F.Fab", -w / 2, -h / 2, w / 2, h / 2, 0.1)
    b += rect("F.CrtYd", -w / 2 - 0.25, -h / 2 - 0.25, w / 2 + 0.25, h / 2 + 0.25)
    b += text("user", "PLACEHOLDER", 0, 0, "F.Fab")
    write(name, b, "PLACEHOLDER - redraw from manufacturer land pattern before fab: " + descr, h=height)


def main():
    os.makedirs(OUT, exist_ok=True)
    mpcie()
    # RV-3028-C7: Application Manual Rev 1.4 section 8.1 "recommended solder pad layout" (top view,
    # counter-clockwise numbering): pads 0.5 x 0.8 mm, pitch 0.9 mm, rows 0.4 mm apart (centres +/-0.6 mm).
    b = ""
    xs = (-1.35, -0.45, 0.45, 1.35)
    for i, x in enumerate(xs):
        b += pad(i + 1, x, 0.6, 0.5, 0.8)          # pins 1-4, left to right
        b += pad(8 - i, x, -0.6, 0.5, 0.8)         # pins 8-5 above them
    b += rect("F.Fab", -1.6, -0.75, 1.6, 0.75, 0.1)
    b += rect("F.CrtYd", -1.85, -1.25, 1.85, 1.25)
    b += (f'  (fp_line (start -1.85 1.35) (end -1.1 1.35) (stroke (width 0.12) (type solid)) (layer "F.SilkS"))\n')
    write("MicroCrystal_RV-3028-C7", b,
          "Micro Crystal RV-3028-C7 3.2x1.5 mm, land pattern per Application Manual Rev 1.4 sec 8.1; lid = VSS",
          h=0.8)
    placeholder("Seiko_CPH3225A", 3.2, 2.5, [(1, -1.25, 0, 1.0, 2.2), (2, 1.25, 0, 1.0, 2.2)],
                0.9, "Seiko CPH3225A 3.2x2.5 mm")
    b = pad(1, -2.75, 0, 3.0, 5.0) + pad(2, 2.75, 0, 3.0, 5.0)
    for x in (-2.75, 2.75):
        b += pad("", x, 4.2, 2.2, 2.2, "circle", '"*.Cu" "*.Mask"', "np_thru_hole", 2.2)
    b += rect("F.CrtYd", -4.5, -2.75, 4.5, 5.6)
    write("BattPads_2x_3x5mm_StrainRelief", b, "Battery wire pads 3x5 mm + zip-tie holes", h=0)
    b = pad(1, 0, 0, 4.2, 4.2, "circle") + rect("F.CrtYd", -2.6, -2.6, 2.6, 2.6)
    b += text("user", "PLACEHOLDER", 0, 3, "F.Fab")
    write("SMT_Standoff_M2_TBD", b, "PLACEHOLDER M2 SMT standoff ~3.1 mm; part TBD after V14", h=3.1)


if __name__ == "__main__":
    main()
