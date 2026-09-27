#!/usr/bin/env python3
"""First placement (floorplan) of the Batman HAT -- M4 step 1, no routing.

Fixed mechanical parts are placed from drawings (Pi HAT outline, 40-pin
header, mPCIe socket + card outline, mounting holes). Everything else is
shelf-packed into functional regions with a height limit per region, so
the result answers "does it fit?" with real footprints. Output:
batman-hat.kicad_pcb + out/floorplan.png + out/floorplan-report.md.
"""
import math
import os
import re
import subprocess
import sys

import pcbnew

sys.path.insert(0, os.path.dirname(__file__))
import design as D  # noqa: E402

HERE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(HERE, "out")
STOCK = "/usr/share/kicad/footprints"
OX, OY = 100.0, 100.0          # board origin inside the KiCad sheet
BW, BH = 65.0, 56.5            # Raspberry Pi HAT outline
MM = pcbnew.FromMM

# mPCIe socket: origin = 1.60 mm locating hole; rotated so the card lies toward -x
J3_X, J3_Y = 59.0, 46.3
CARD = (J3_X - 49.45, J3_Y - 27.5, J3_X + 1.5, J3_Y + 2.5)   # x0, y0, x1, y1 (approx.)
CARD_HOLES = [(J3_X - 48.04, J3_Y - 0.40), (J3_X - 48.04, J3_Y - 24.60)]
WIFI_KEEPOUT = (0.0, 0.0, 12.0, 14.0)  # Pi 4 PCB antenna corner -- INFERENCE, verify vs Pi 4 drawing

REGIONS = {  # name: (x0, y0, x1, y1, max component height mm)
    "top": (12.5, 7.0, 64.5, 18.5, 99),
    "under": (12.5, 19.8, 52.8, 45.8, 1.9),
    "left": (0.6, 14.5, 9.2, 48.8, 99),
    "bottom": (7.2, 49.2, 57.8, 56.0, 99),
    "back": (7.5, 8.0, 57.5, 48.0, 0),   # B side (faces the Pi): flat probe pads only (user decision)
}
PREF = {
    "power_in": ["left", "bottom", "top", "under"],
    "power_5v": ["bottom", "top", "left", "under"],
    "power_3v3": ["bottom", "under", "top", "left"],
    "softpower": ["under", "top", "bottom"],
    "pi_header": ["top", "under"],
    "halow": ["under", "bottom"],
    "security": ["under", "top"],
    "gnss": ["top", "left", "under"],
    "debug": ["top", "left", "bottom", "under"],
}
NOT_UNDER = ("TP", "J5", "D2", "D3", "SW1", "J6")  # must stay reachable / visible
# Power-stage parts stay outside the card (heat, switching noise, hot loops next to their IC)
POWER_STAGE = {"U1", "Q1", "Q2", "D1", "C1", "C2", "C8", "C9", "R19", "C4", "R9", "C6", "C7",
               "U3", "L1", "C10", "C11", "C12", "C13", "C14", "C15", "C16", "U4", "Q3", "C18", "C19",
               "U5", "U6", "Q4", "Q5", "C20", "C21", "C22", "C23", "C24", "U7", "L2", "C25", "C26",
               "C27", "C28", "R22", "FB1", "C31"}


def height(fp_name):
    rules = [(r"L_Coilcraft_XxL4030", 3.1), (r"ublox_MAX", 2.5), (r"D_SMB", 2.45),
             (r"_1210_", 2.5), (r"_1206_", 1.8), (r"_0805_", 1.4), (r"_0603_", 0.9),
             (r"_0402_", 0.6), (r"SOT-23", 1.15), (r"TSOT-23", 1.0), (r"SOT-583", 0.6),
             (r"SOIC-8", 1.75), (r"VSSOP", 1.1), (r"HSOP", 1.7), (r"QFN", 1.0), (r"NexFET", 1.1),
             (r"7343-20", 1.9), (r"U\.FL", 1.25), (r"JST_SH", 2.95), (r"EVQP7A", 3.6),
             (r"Keystone_5015", 1.6), (r"TestPoint_Pad", 0), (r"SolderJumper", 0),
             (r"Tag-Connect", 0), (r"CPH3225A", 0.9), (r"RV-3028", 0.8), (r"BattPads", 0)]
    for pat, h in rules:
        if re.search(pat, fp_name):
            return h
    return 2.0


def load(fpid):
    lib, name = fpid.split(":")
    path = os.path.join(HERE, "batman.pretty") if lib == "batman" else os.path.join(STOCK, lib + ".pretty")
    fp = pcbnew.FootprintLoad(path, name)
    if fp is None:
        raise SystemExit(f"footprint not found: {fpid}")
    return fp


def courtyard(fp):
    fp.BuildCourtyardCaches()
    poly = fp.GetCourtyard(pcbnew.F_CrtYd)
    if poly.OutlineCount() == 0:
        poly = fp.GetCourtyard(pcbnew.B_CrtYd)
    if poly.OutlineCount() == 0:
        return fp.GetBoundingBox(False, False)
    return poly.BBox()


def place_at(fp, x, y, rot=0, flip=False):
    fp.SetPosition(pcbnew.VECTOR2I(MM(OX + x), MM(OY + y)))
    fp.SetOrientationDegrees(rot)
    if flip and not fp.IsFlipped():
        fp.Flip(fp.GetPosition(), False)


def pad_xy(fp, num):
    for p in fp.Pads():
        if p.GetNumber() == num:
            v = p.GetPosition()
            return pcbnew.ToMM(v.x) - OX, pcbnew.ToMM(v.y) - OY
    return None


def fit_fixed(fp, anchor, target1, num2, target2, flip):
    """Try every orientation; keep the one that puts pad 1 and pad num2 on target."""
    for rot in (0, 90, 180, 270):
        fp.SetOrientationDegrees(0)
        if fp.IsFlipped():
            fp.Flip(fp.GetPosition(), False)
        place_at(fp, 0, 0, rot, flip)
        p1 = pad_xy(fp, anchor)
        dx, dy = target1[0] - p1[0], target1[1] - p1[1]
        pos = fp.GetPosition()
        fp.SetPosition(pcbnew.VECTOR2I(pos.x + MM(dx), pos.y + MM(dy)))
        p2 = pad_xy(fp, num2)
        if abs(p2[0] - target2[0]) < 0.05 and abs(p2[1] - target2[1]) < 0.05:
            return rot
    raise SystemExit("no orientation fits " + fp.GetReference())


def outline(board):
    r = 3.0
    pts = [((r, 0), (BW - r, 0)), ((BW, r), (BW, BH - r)), ((BW - r, BH), (r, BH)), ((0, BH - r), (0, r))]
    for (x0, y0), (x1, y1) in pts:
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(pcbnew.VECTOR2I(MM(OX + x0), MM(OY + y0)))
        s.SetEnd(pcbnew.VECTOR2I(MM(OX + x1), MM(OY + y1)))
        s.SetLayer(pcbnew.Edge_Cuts)
        s.SetWidth(MM(0.1))
        board.Add(s)
    for cx, cy, a0 in ((r, r, 180), (BW - r, r, 270), (BW - r, BH - r, 0), (r, BH - r, 90)):
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(pcbnew.SHAPE_T_ARC)
        s.SetCenter(pcbnew.VECTOR2I(MM(OX + cx), MM(OY + cy)))
        s.SetStart(pcbnew.VECTOR2I(MM(OX + cx + r * math.cos(math.radians(a0))),
                                   MM(OY + cy + r * math.sin(math.radians(a0)))))
        s.SetArcAngleAndEnd(pcbnew.EDA_ANGLE(90, pcbnew.DEGREES_T), True)
        s.SetLayer(pcbnew.Edge_Cuts)
        s.SetWidth(MM(0.1))
        board.Add(s)


def rect(board, box, layer, width=0.15):
    x0, y0, x1, y1 = box
    for (ax, ay), (bx, by) in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1)), ((x1, y1), (x0, y1)), ((x0, y1), (x0, y0))):
        s = pcbnew.PCB_SHAPE(board)
        s.SetShape(pcbnew.SHAPE_T_SEGMENT)
        s.SetStart(pcbnew.VECTOR2I(MM(OX + ax), MM(OY + ay)))
        s.SetEnd(pcbnew.VECTOR2I(MM(OX + bx), MM(OY + by)))
        s.SetLayer(layer)
        s.SetWidth(MM(width))
        board.Add(s)


def label(board, txt, x, y, layer, size=1.0):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(txt)
    t.SetPosition(pcbnew.VECTOR2I(MM(OX + x), MM(OY + y)))
    t.SetLayer(layer)
    t.SetTextSize(pcbnew.VECTOR2I(MM(size), MM(size)))
    t.SetTextThickness(MM(size * 0.12))
    board.Add(t)


def keepout(board, box, name):
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    z.SetDoNotAllowCopperPour(True)
    z.SetDoNotAllowTracks(True)
    z.SetDoNotAllowVias(True)
    z.SetDoNotAllowPads(True)
    z.SetDoNotAllowFootprints(True)
    ls = pcbnew.LSET()
    for layer in (pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu, pcbnew.B_Cu):
        ls.AddLayer(layer)
    z.SetLayerSet(ls)
    z.SetZoneName(name)
    x0, y0, x1, y1 = box
    o = z.Outline()
    o.NewOutline()
    for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        o.Append(MM(OX + x), MM(OY + y))
    board.Add(z)


def main():
    board = pcbnew.BOARD()
    board.GetDesignSettings().SetCopperLayerCount(4)
    nets = {}
    fps = {}
    for p in D.PARTS:
        if p.ref.startswith("#"):
            continue
        fp = load(p.fp)
        fp.SetReference(p.ref)
        fp.SetValue(p.value)
        board.Add(fp)
        for pad in fp.Pads():
            net = p.pins.get(pad.GetNumber())
            if net:
                if net not in nets:
                    nets[net] = pcbnew.NETINFO_ITEM(board, net)
                    board.Add(nets[net])
                pad.SetNet(nets[net])
        fps[p.ref] = (p, fp)
    outline(board)

    # ---- fixed mechanical placement -------------------------------------------------
    j2 = fps["J2"][1]  # female header on the bottom side; pin 1 inner row, left end
    fit_fixed(j2, "1", (8.37, 4.77), "2", (8.37, 2.23), flip=True)
    fit_fixed(fps["J3"][1], "53", (J3_X + 3.5, J3_Y + 2.15), "54", (J3_X + 3.5, J3_Y - 27.15), flip=False)
    for ref, (x, y) in zip(("H1", "H2", "H3", "H4"), ((3.5, 3.5), (61.5, 3.5), (3.5, 52.5), (61.5, 52.5))):
        place_at(fps[ref][1], x, y)
    for ref, (x, y) in zip(("H5", "H6"), CARD_HOLES):
        place_at(fps[ref][1], x, y)
    place_at(fps["J1"][1], 4.6, 20.0, 90)       # battery wires enter at the left edge
    place_at(fps["J4"][1], 62.0, 12.0)          # GNSS U.FL, far from the HaLow card RF end
    place_at(fps["J6"][1], 1.8, 44.0, 270)      # panel button cable
    place_at(fps["SW1"][1], 2.2, 36.0, 90)
    place_at(fps["J5"][1], 22.0, 10.5)          # Tag-Connect near the header
    place_at(fps["U14"][1], 53.5, 12.8)         # GNSS next to its U.FL, far from the HaLow RF end
    fixed = {"J2", "J3", "H1", "H2", "H3", "H4", "H5", "H6", "J1", "J4", "J6", "SW1", "J5", "U14"}

    # obstacles for packing: courtyards of the fixed parts + keep-outs
    obst = []
    for ref in fixed:
        b = courtyard(fps[ref][1])
        obst.append((pcbnew.ToMM(b.GetLeft()) - OX, pcbnew.ToMM(b.GetTop()) - OY,
                     pcbnew.ToMM(b.GetRight()) - OX, pcbnew.ToMM(b.GetBottom()) - OY))
    obst.append(WIFI_KEEPOUT)
    for hx, hy in CARD_HOLES:
        obst.append((hx - 2.9, hy - 2.9, hx + 2.9, hy + 2.9))

    # ---- packing: bottom-left fill on a 0.25 mm occupancy grid -------------------------
    import numpy as np
    G = 0.25
    NX, NY = int(BW / G) + 1, int(BH / G) + 1
    occ = np.zeros((NY, NX), dtype=np.int32)

    def mark(x0, y0, x1, y1):
        occ[max(0, int(y0 / G)):min(NY, int(math.ceil(y1 / G))),
            max(0, int(x0 / G)):min(NX, int(math.ceil(x1 / G)))] = 1

    for b in obst:
        mark(*b)
    occ_top = occ
    occ_back = np.zeros((NY, NX), dtype=np.int32)
    for ref in ("J1", "J5", "J3", "H1", "H2", "H3", "H4"):   # parts with holes through the board
        b = courtyard(fps[ref][1])
        x0, y0 = pcbnew.ToMM(b.GetLeft()) - OX, pcbnew.ToMM(b.GetTop()) - OY
        x1, y1 = pcbnew.ToMM(b.GetRight()) - OX, pcbnew.ToMM(b.GetBottom()) - OY
        occ_back[max(0, int(y0 / G)):int(math.ceil(y1 / G)), max(0, int(x0 / G)):int(math.ceil(x1 / G))] = 1
    used = {r: 0.0 for r in REGIONS}
    placed_in, failed = {}, []
    order = [s for s, _ in D.SHEETS]
    GAP = 0.25

    def try_region(r, w, h):
        nonlocal occ
        occ = occ_back if r == "back" else occ_top
        rx0, ry0, rx1, ry1, _ = REGIONS[r]
        pre = np.pad(occ, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
        cw, ch = int(math.ceil((w + GAP) / G)), int(math.ceil((h + GAP) / G))
        gx0, gy0 = int(math.ceil(rx0 / G)), int(math.ceil(ry0 / G))
        gx1, gy1 = int(rx1 / G) - cw, int(ry1 / G) - ch
        if gx1 < gx0 or gy1 < gy0:
            return None
        ys = np.arange(gy0, gy1 + 1)[:, None]
        xs = np.arange(gx0, gx1 + 1)[None, :]
        tot = pre[ys + ch, xs + cw] - pre[ys, xs + cw] - pre[ys + ch, xs] + pre[ys, xs]
        free = np.argwhere(tot == 0)
        if len(free) == 0:
            return None
        iy, ix = free[0]                      # top-most, then left-most
        x, y = float((gx0 + ix) * G), float((gy0 + iy) * G)
        mark(x, y, x + w + GAP, y + h + GAP)
        return x, y

    todo = [(order.index(p.sheet), p, fp) for ref, (p, fp) in fps.items() if ref not in fixed]
    def prio(t):
        _, p, fp = t
        if p.ref in POWER_STAGE:
            k = 0
        elif "Keystone" in p.fp:
            k = 1                        # the clip-able pads the user asked to keep
        else:
            k = 2
        return (k, t[0], -courtyard(fp).GetArea())
    todo.sort(key=prio)
    for _, p, fp in todo:
        hgt = height(p.fp)
        cy = courtyard(fp)
        w, h = pcbnew.ToMM(cy.GetWidth()), pcbnew.ToMM(cy.GetHeight())
        ok = None
        prefs = PREF[p.sheet]
        if p.sheet.startswith(("power", "soft")) and p.ref not in POWER_STAGE:
            prefs = ["under"] + [r for r in prefs if r != "under"]
        if p.ref in POWER_STAGE:
            prefs = [r for r in prefs if r != "under"]
        back = p.sym == "TP" and "Keystone" not in p.fp
        if back:
            prefs = ["back"]
        for r in prefs:
            if (hgt > REGIONS[r][4] and r != "back") or (r == "under" and p.ref.startswith(NOT_UNDER)):
                continue
            ok = try_region(r, w, h)
            if ok:
                break
        if not ok:
            failed.append(p.ref)
            pos = fp.GetPosition()   # park beside the board so the picture shows what is missing
            k = len(failed) - 1
            fp.SetPosition(pcbnew.VECTOR2I(pos.x + MM(OX + BW + 4 + (k % 4) * 6) - cy.GetLeft(),
                                           pos.y + MM(OY + (k // 4) * 5) - cy.GetTop()))
            continue
        x, y = ok
        if back:
            fp.Flip(fp.GetPosition(), False)
            cy = courtyard(fp)
        pos = fp.GetPosition()
        fp.SetPosition(pcbnew.VECTOR2I(pos.x + MM(OX + x) - cy.GetLeft(), pos.y + MM(OY + y) - cy.GetTop()))
        placed_in[p.ref] = r
        used[r] += w * h

    # ---- drawings ---------------------------------------------------------------------
    rect(board, CARD, pcbnew.Dwgs_User, 0.25)
    label(board, "Wio-WM6108 card above (full-mini 30 x 51, underside ~3.1 mm)", CARD[0] + 2, CARD[1] + 1.8,
          pcbnew.Dwgs_User, 1.0)
    keepout(board, WIFI_KEEPOUT, "Pi4_WiFi_antenna_keepout_VERIFY")
    label(board, "Pi 4 Wi-Fi keep-out (verify)", 0.8, 13.0, pcbnew.Dwgs_User, 0.7)
    for r, (x0, y0, x1, y1, hmax) in REGIONS.items():
        if r != "back":
            rect(board, (x0, y0, x1, y1), pcbnew.Cmts_User, 0.1)
    for r, (x0, y0, x1, y1, hm) in [(k, v) for k, v in REGIONS.items() if k != "back"]:
        label(board, f"{r} {'(<=' + str(hm) + ' mm tall)' if hm < 99 else ''}", x0 + 0.3, y1 - 0.6, pcbnew.Cmts_User, 0.7)
    if failed:
        label(board, f"DID NOT FIT ({len(failed)})", BW + 12, -3, pcbnew.Cmts_User, 1.5)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(HERE, "batman-hat.kicad_pcb")
    board.Save(path)

    # ---- report + picture ------------------------------------------------------------
    rep = ["# Floorplan report (first placement, no routing)", "",
           f"Board {BW} x {BH} mm (Pi HAT). Placed {len(placed_in) + len(fixed)} of {len(fps)} footprints.", ""]
    rep += ["| region | limit | used courtyard mm2 | region mm2 | fill |", "|---|---|---|---|---|"]
    for r, (x0, y0, x1, y1, hm) in REGIONS.items():
        a = (x1 - x0) * (y1 - y0)
        rep.append(f"| {r} | {'<=' + str(hm) + ' mm' if hm < 99 else '-'} | {used[r]:.0f} | {a:.0f} | {used[r] / a:.0%} |")
    rep += ["", "**Did not fit:** " + (", ".join(failed) if failed else "none")]
    with open(os.path.join(OUT, "floorplan-report.md"), "w") as fh:
        fh.write("\n".join(rep) + "\n")
    print("\n".join(rep))
    svg = os.path.join(OUT, "floorplan.svg")
    subprocess.run(["kicad-cli", "pcb", "export", "svg", "-o", svg, "--page-size-mode", "2", "--exclude-drawing-sheet",
                    "--layers", "Edge.Cuts,F.Cu,F.CrtYd,F.SilkS,Dwgs.User,Cmts.User",
                    path], check=True, capture_output=True)
    import pymupdf as fitz
    doc = fitz.open(svg)
    doc[0].get_pixmap(dpi=300).save(os.path.join(OUT, "floorplan.png"))
    os.remove(svg)
    subprocess.run(["kicad-cli", "pcb", "export", "svg", "-o", svg, "--page-size-mode", "2", "--exclude-drawing-sheet",
                    "--mirror", "--layers", "Edge.Cuts,B.Cu,B.CrtYd,B.SilkS", path], check=True, capture_output=True)
    doc = fitz.open(svg)
    doc[0].get_pixmap(dpi=300).save(os.path.join(OUT, "floorplan-back.png"))
    os.remove(svg)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
