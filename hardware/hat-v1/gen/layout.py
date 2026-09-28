#!/usr/bin/env python3
"""Placement v2 + routing for the Batman HAT (M4).

1. Fixed mechanics and hand-chosen IC anchors (ANCHORS).
2. Every other part is placed as close as possible to the pads it connects to
   (nearest free spot inside the regions it is allowed in: height limit under
   the card, switching cores on the bottom edge, probe pads on the back...).
3. Net classes + stack-up written to the project, GND plane on In1.Cu.
4. Specctra DSN -> Freerouting (headless) -> SES back into KiCad.
5. Power tracks widened as far as clearance allows, GND pours filled, DRC.

Run: python3 gen/layout.py [--no-route]
"""
import json
import math
import os
import subprocess
import sys

import numpy as np
import pcbnew

sys.path.insert(0, os.path.dirname(__file__))
import design as D  # noqa: E402
import gen_pcb as G  # noqa: E402

HERE, OUT, MM = G.HERE, G.OUT, G.MM
OX, OY, BW, BH = G.OX, G.OY, G.BW, G.BH
PCB = os.path.join(HERE, "batman-hat.kicad_pcb")
FREEROUTING = os.environ.get("FREEROUTING_JAR", os.path.join(
    "/tmp/claude-0/-home-user-Batman/dc2ddc38-1fcc-5979-a1bd-ee87db5d8e02/scratchpad/fr", "freerouting-2.1.0.jar"))

# Hand-placed ICs: ref -> (x, y, rotation)  [board mm, origin top-left, y down]
ANCHORS = {
    # --- left column, battery enters bottom-left and flows up (user decision: 5 V buck at the header) ---
    "D1": (4.1, 38.9, 0), "Q1": (2.3, 34.3, 0), "Q2": (6.3, 34.3, 0),
    "C8": (2.6, 30.6, 0), "C33": (2.6, 27.2, 0), "R19": (6.65, 29.3, 90), "C1": (7.3, 25.85, 90),
    "U1": (3.6, 22.3, 0), "R9": (2.6, 18.55, 0), "C4": (7.3, 17.9, 90), "C6": (2.6, 15.75, 0),
    # --- top-left: 5 V buck right next to header pins 2/4 ---
    "L1": (15.0, 13.9, 0), "U3": (21.2, 14.4, 180), "C10": (27.0, 14.4, 90),
    "Q3": (15.0, 8.45, 0), "U4": (19.6, 8.4, 0),
    "TP2": (31.5, 8.0, 0), "TP1": (31.5, 11.2, 0), "TP4": (31.5, 14.4, 0),
    "J5": (39.3, 9.0, 0), "U15": (45.5, 14.5, 0),
    # --- bottom edge: OR-ing -> 3.3 V buck -> shunt -> ferrite -> socket ---
    "C22": (19.0, 51.4, 0), "C23": (19.0, 54.6, 0), "U7": (23.7, 52.6, 0), "L2": (28.5, 52.6, 0),
    "C27": (33.2, 51.3, 0), "C28": (33.2, 54.3, 0), "R22": (37.5, 51.4, 0), "C31": (37.5, 54.4, 0),
    "FB1": (42.4, 51.4, 0), "JP1": (42.4, 54.4, 0), "TP3": (47.0, 51.3, 0), "J6": (52.6, 53.2, 90),
    # --- under the card: measurement, soft power, trust chain ---
    "U2": (17.2, 22.3, 0), "U9": (20.0, 30.0, 0), "U13": (28.0, 23.5, 0), "U12": (36.5, 25.0, 0),
    "U11": (46.5, 25.5, 0), "U8": (41.0, 44.5, 0),
}
BIG_NETS = 10          # nets with more nodes than this do not pull parts together
PWR_NETS = ["VBAT_RAW", "VBAT_DAMP", "EF_IN", "EF_OUT", "VSYS", "SW_5V", "5V_BUCK", "5V_PI",
            "SW_3V3", "3V3_BUCK", "3V3_SH", "3V3_FILT", "3V3_MPCIE", "3V3_PI", "3V3_SEC", "3V3_GNSS"]
RF_NETS = ["GNSS_ANT", "GNSS_RFIN"]


def build_board():
    board = pcbnew.BOARD()
    board.GetDesignSettings().SetCopperLayerCount(4)
    nets, fps = {}, {}
    for p in D.PARTS:
        if p.ref.startswith("#"):
            continue
        fp = G.load(p.fp)
        fp.SetReference(p.ref)
        fp.SetValue(p.value)
        board.Add(fp)
        for pad in fp.Pads():
            net = p.pins.get(pad.GetNumber())
            if not pad.GetNumber() and p.sym == "NMOS_SON8" and pad.IsOnLayer(pcbnew.F_Cu):
                net = p.pins.get("5")   # stock NexFET footprint leaves the drain leads unnumbered
            if net:
                if net not in nets:
                    nets[net] = pcbnew.NETINFO_ITEM(board, net)
                    board.Add(nets[net])
                pad.SetNet(nets[net])
        fps[p.ref] = (p, fp)
    G.outline(board)
    return board, nets, fps


def bbox_mm(fp):
    b = G.courtyard(fp)
    return (pcbnew.ToMM(b.GetLeft()) - OX, pcbnew.ToMM(b.GetTop()) - OY,
            pcbnew.ToMM(b.GetRight()) - OX, pcbnew.ToMM(b.GetBottom()) - OY)


def place_fixed(fps):
    J3_X, J3_Y = G.J3_X, G.J3_Y
    G.fit_fixed(fps["J2"][1], "1", (8.37, 4.77), "2", (8.37, 2.23), flip=True)
    G.fit_fixed(fps["J3"][1], "53", (J3_X + 3.5, J3_Y + 2.15), "54", (J3_X + 3.5, J3_Y - 27.15), flip=False)
    for ref, (x, y) in zip(("H1", "H2", "H3", "H4"), ((3.5, 3.5), (61.5, 3.5), (3.5, 52.5), (61.5, 52.5))):
        G.place_at(fps[ref][1], x, y)
    for ref, (x, y) in zip(("H5", "H6"), G.CARD_HOLES):
        G.place_at(fps[ref][1], x, y)
    G.place_at(fps["J1"][1], 4.15, 43.9, 0)          # battery wires enter bottom-left
    G.place_at(fps["J4"][1], 62.0, 12.0)
    G.place_at(fps["U14"][1], 53.5, 11.9)
    for ref, (x, y, r) in ANCHORS.items():
        G.place_at(fps[ref][1], x, y, r)
    return {"J2", "J3", "H1", "H2", "H3", "H4", "H5", "H6", "J1", "J4", "U14"} | set(ANCHORS)


PREF = dict(G.PREF, power_in=["left", "under", "top"], power_5v=["top", "under"],
            power_3v3=["bottom", "under_edge", "under"], softpower=["under", "top"])


def gap(p):
    """Free ring around a part's courtyard (mm): routing channels. v1 packed everything at 0.2 mm
    and left fine-pitch ICs no room to fan out (68 unconnected after routing, 2026-09-28)."""
    if p.sym == "TP":
        return 0.2
    ic = p.ref[0] in "UQJ" and len([n for n in p.pins.values() if n]) >= 5
    return GAP_IC if ic else GAP_PASSIVE


GAP_IC, GAP_PASSIVE = 1.0, 0.5


def allowed_regions(p):
    prefs = list(PREF[p.sheet])
    if p.sheet.startswith(("power", "soft")) and p.ref not in G.POWER_STAGE:
        prefs = ["under"] + [r for r in prefs if r != "under"]
    if p.ref in G.POWER_STAGE:
        prefs = [r for r in prefs if r != "under"]
    if p.sheet == "power_in" and p.ref in G.POWER_STAGE:
        prefs = ["left", "top"]
    if p.ref in G.POWER_HOT or p.ref in G.POWER_NEAR:
        prefs = {"power_5v": ["top", "under"], "power_3v3": ["bottom", "under_edge", "under"]}.get(
            p.sheet, prefs)
    if p.sym == "TP" and "Keystone" not in p.fp:
        return ["back_L", "back_R", "back_B"]
    if p.sheet in ("security", "halow", "debug") and "under" not in prefs:
        prefs.append("under")
    h = G.height(p.fp)
    out = []
    for r in prefs + [r for r in ("top", "under", "left", "bottom", "under_edge") if r not in prefs]:
        if r in G.BACK:
            continue
        if h > G.REGIONS[r][4] or (r.startswith("under") and p.ref.startswith(G.NOT_UNDER)):
            continue
        out.append(r)
    return out


def main(route=True):
    board, nets, fps = build_board()
    fixed = place_fixed(fps)
    Gd = 0.25
    NX, NY = int(BW / Gd) + 1, int(BH / Gd) + 1
    occ = {"top": np.zeros((NY, NX), np.int32), "back": np.zeros((NY, NX), np.int32)}

    def mark(side, x0, y0, x1, y1):
        occ[side][max(0, int(y0 / Gd)):min(NY, int(math.ceil(y1 / Gd))),
                   max(0, int(x0 / Gd)):min(NX, int(math.ceil(x1 / Gd)))] = 1

    overlaps = []
    for ref in fixed:
        b = bbox_mm(fps[ref][1])
        sub = occ["top"][max(0, int(b[1] / Gd)):int(math.ceil(b[3] / Gd)), max(0, int(b[0] / Gd)):int(math.ceil(b[2] / Gd))]
        if ref in ANCHORS and sub.any():
            overlaps.append(ref)
        mark("top", *b)
    mark("top", *G.WIFI_KEEPOUT)
    mark("top", *G.WIFI_KEEPOUT2)
    for hx, hy in G.CARD_HOLES:
        mark("top", hx - 2.9, hy - 2.9, hx + 2.9, hy + 2.9)
    for ref in ("J1", "J5", "H1", "H2", "H3", "H4"):
        mark("back", *bbox_mm(fps[ref][1]))
    for box in (G.WIFI_KEEPOUT, G.WIFI_KEEPOUT2):   # rule areas cover all copper layers
        mark("back", *box)
    for ref in ("U14", "J4"):                        # GNSS module / U.FL keep-outs reach B.Cu
        mark("back", *bbox_mm(fps[ref][1]))
    for ref in [r for r in fixed if r.startswith("U")]:   # thermal pads / vias that reach B.Cu (e.g. the eFuse QFN) keep probe pads away
        if any(pd.IsOnLayer(pcbnew.B_Cu) for pd in fps[ref][1].Pads()):
            x0, y0, x1, y1 = bbox_mm(fps[ref][1])
            mark("back", x0 - 0.5, y0 - 0.5, x1 + 0.5, y1 + 0.5)
    mark("back", 0, 0, BW, 7.0)                                   # header pins
    for hx, hy in ((G.J3_X, G.J3_Y), (G.J3_X, G.J3_Y - 25.0)):
        mark("back", hx - 1.5, hy - 1.5, hx + 1.5, hy + 1.5)

    # connectivity for the "pull" towards related pads
    net_nodes = {}
    for p in D.PARTS:
        if p.ref.startswith("#"):
            continue
        for pin, n in p.pins.items():
            if n:
                net_nodes.setdefault(n, []).append((p.ref, pin))
    placed = set(fixed)

    def pad_pos(ref, pin):
        fp = fps[ref][1]
        for pd in fp.Pads():
            if pd.GetNumber() == pin:
                v = pd.GetPosition()
                return pcbnew.ToMM(v.x) - OX, pcbnew.ToMM(v.y) - OY
        return None

    def target(p):
        pts = []
        for pin, n in p.pins.items():
            if not n or n == "GND" or len(net_nodes[n]) > BIG_NETS:
                continue
            for ref, pn in net_nodes[n]:
                if ref in placed and ref != p.ref:
                    q = pad_pos(ref, pn)
                    if q:
                        pts.append(q)
        if not pts:
            return None
        return sum(x for x, _ in pts) / len(pts), sum(y for _, y in pts) / len(pts)

    todo = [ref for ref in fps if ref not in fixed]
    # parts with more links to already-placed parts go first
    failed = []
    while todo:
        def score(ref):
            p = fps[ref][0]
            return -sum(1 for n in p.pins.values() if n and n != "GND" and len(net_nodes[n]) <= BIG_NETS
                        for r, _ in net_nodes[n] if r in placed)
        todo.sort(key=score)
        ref = todo.pop(0)
        p, fp = fps[ref]
        tgt = target(p)
        back = p.sym == "TP" and "Keystone" not in p.fp
        side = "back" if back else "top"
        best = None
        for rot in (0, 90):
            fp.SetOrientationDegrees(rot)
            cy = G.courtyard(fp)
            w, h = pcbnew.ToMM(cy.GetWidth()) + gap(p), pcbnew.ToMM(cy.GetHeight()) + gap(p)
            cw, ch = int(math.ceil(w / Gd)), int(math.ceil(h / Gd))
            pre = np.pad(occ[side], ((1, 0), (1, 0))).cumsum(0).cumsum(1)
            for r in (["back_L", "back_R", "back_B"] if back else allowed_regions(p)):
                rx0, ry0, rx1, ry1, _ = G.REGIONS[r]
                gx0, gy0 = int(math.ceil(rx0 / Gd)), int(math.ceil(ry0 / Gd))
                gx1, gy1 = int(rx1 / Gd) - cw, int(ry1 / Gd) - ch
                if gx1 < gx0 or gy1 < gy0:
                    continue
                ys = np.arange(gy0, gy1 + 1)[:, None]
                xs = np.arange(gx0, gx1 + 1)[None, :]
                tot = pre[ys + ch, xs + cw] - pre[ys, xs + cw] - pre[ys + ch, xs] + pre[ys, xs]
                free = np.argwhere(tot == 0)
                if not len(free):
                    continue
                cx = (gx0 + free[:, 1]) * Gd + w / 2
                cyy = (gy0 + free[:, 0]) * Gd + h / 2
                if tgt:
                    d = np.hypot(cx - tgt[0], cyy - tgt[1])
                else:
                    d = cyy * 0.01 + cx * 0.001          # no pull: top-left first
                i = int(np.argmin(d))
                # prefer earlier (preferred) regions unless much closer elsewhere
                cand = (float(d[i]) + 3.0 * (allowed_regions(p).index(r) if r in allowed_regions(p) else 0),
                        rot, float((gx0 + free[i, 1]) * Gd), float((gy0 + free[i, 0]) * Gd), w, h, r)
                if best is None or cand[0] < best[0]:
                    best = cand
        if best is None:
            failed.append(ref)
            continue
        _, rot, x, y, w, h, r = best
        fp.SetOrientationDegrees(rot)
        if back and not fp.IsFlipped():
            fp.Flip(fp.GetPosition(), False)
        cy = G.courtyard(fp)
        pos = fp.GetPosition()
        fp.SetPosition(pcbnew.VECTOR2I(pos.x + MM(OX + x + gap(p) / 2) - cy.GetLeft(), pos.y + MM(OY + y + gap(p) / 2) - cy.GetTop()))
        mark(side, x, y, x + w, y + h)
        placed.add(ref)

    # drawings (card outline, keep-outs, regions)
    G.rect(board, G.CARD, pcbnew.Dwgs_User, 0.25)
    G.keepout(board, G.WIFI_KEEPOUT, "Pi4_WiFi_antenna_keepout_VERIFY")
    G.keepout(board, G.WIFI_KEEPOUT2, "Pi4_WiFi_antenna_keepout2_VERIFY")
    board.Save(PCB)
    print(f"placed {len(placed)}/{len(fps)}; anchor overlaps: {overlaps or 'none'}; failed: {failed or 'none'}")
    return failed, overlaps


if __name__ == "__main__":
    main(route="--no-route" not in sys.argv)


# ------------------------------------------------------------------------------------------------
# Routing
# ------------------------------------------------------------------------------------------------
NETCLASSES = [  # name, track, clearance, via dia, via drill
    ("Default", 0.20, 0.127, 0.60, 0.30),
    ("PWR", 0.35, 0.127, 0.80, 0.40),   # widened after routing (fatten_power)
    ("RF", 0.36, 0.30, 0.60, 0.30),    # ~50 ohm microstrip over In1 GND on JLC 7628 prepreg (inference)
]


def write_rules():
    pro = os.path.join(HERE, "batman-hat.kicad_pro")
    d = json.load(open(pro))
    base = dict(bus_width=12, diff_pair_gap=0.25, diff_pair_via_gap=0.25, diff_pair_width=0.2, line_style=0,
                microvia_diameter=0.3, microvia_drill=0.1, pcb_color="rgba(0, 0, 0, 0.000)",
                schematic_color="rgba(0, 0, 0, 0.000)", wire_width=6)
    d["net_settings"] = {
        "classes": [dict(base, name=n, track_width=w, clearance=c, via_diameter=vd, via_drill=vh)
                    for n, w, c, vd, vh in NETCLASSES],
        "meta": {"version": 3}, "net_colors": None, "netclass_assignments": None,
        "netclass_patterns": [{"netclass": "PWR", "pattern": n} for n in PWR_NETS] +
                             [{"netclass": "RF", "pattern": n} for n in RF_NETS]}
    r = d.setdefault("board", {}).setdefault("design_settings", {}).setdefault("rules", {})
    r.update(min_clearance=0.127, min_track_width=0.127, min_via_diameter=0.5, min_through_hole_diameter=0.2,
             min_copper_edge_clearance=0.3, min_hole_clearance=0.25, min_via_annular_width=0.1)
    json.dump(d, open(pro, "w"), indent=2)


def add_zone(board, net, layer, box=(0.3, 0.3, BW - 0.3, BH - 0.3), prio=0, clearance=0.2, name=""):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    if net:
        z.SetNet(net)
    z.SetAssignedPriority(prio)
    z.SetLocalClearance(MM(clearance))
    z.SetMinThickness(MM(0.2))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(MM(0.25))
    z.SetThermalReliefSpokeWidth(MM(0.35))
    if name:
        z.SetZoneName(name)
    x0, y0, x1, y1 = box
    o = z.Outline()
    o.NewOutline()
    for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        o.Append(MM(OX + x), MM(OY + y))
    board.Add(z)
    return z


def track_keepout(board, layer, name):
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    z.SetDoNotAllowTracks(True)
    z.SetDoNotAllowVias(False)
    z.SetDoNotAllowPads(False)
    z.SetDoNotAllowFootprints(False)
    z.SetDoNotAllowCopperPour(False)
    z.SetLayer(layer)
    z.SetZoneName(name)
    o = z.Outline()
    o.NewOutline()
    for x, y in ((0, 0), (BW, 0), (BW, BH), (0, BH)):
        o.Append(MM(OX + x), MM(OY + y))
    board.Add(z)


def edge_ring(board, w=0.45):
    """Tracks / vias stay >= w from the board edge (JLC copper-to-edge; Freerouting only knows 0.2)."""
    for i, box in enumerate(((0, 0, BW, w), (0, BH - w, BW, BH), (0, 0, w, BH), (BW - w, 0, BW, BH))):
        z = pcbnew.ZONE(board)
        z.SetIsRuleArea(True)
        z.SetDoNotAllowTracks(True)
        z.SetDoNotAllowVias(True)
        z.SetDoNotAllowCopperPour(False)
        z.SetDoNotAllowPads(False)
        z.SetDoNotAllowFootprints(False)
        ls = pcbnew.LSET()
        for layer in (pcbnew.F_Cu, pcbnew.In2_Cu, pcbnew.B_Cu):
            ls.AddLayer(layer)
        z.SetLayerSet(ls)
        z.SetZoneName(f"edge_ring_{i}")
        o = z.Outline()
        o.NewOutline()
        x0, y0, x1, y1 = box
        for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
            o.Append(MM(OX + x), MM(OY + y))
        board.Add(z)


def prepare_routing():
    write_rules()
    board = pcbnew.LoadBoard(PCB)
    gnd = board.FindNet("GND")
    add_zone(board, gnd, pcbnew.In1_Cu, name="GND_PLANE_In1")
    edge_ring(board)
    board.Save(PCB)
    board = pcbnew.LoadBoard(PCB)
    dsn = os.path.join(OUT, "route", "batman-hat.dsn")
    os.makedirs(os.path.dirname(dsn), exist_ok=True)
    ok = pcbnew.ExportSpecctraDSN(board, dsn)
    # In1 = solid GND plane: declare it a Specctra power layer so the router never puts signal
    # wires there but still drops vias onto it for GND pads.
    txt = open(dsn).read()
    txt = txt.replace("(layer In1.Cu\n      (type signal)", "(layer In1.Cu\n      (type power)")
    open(dsn, "w").write(txt)
    return ok, dsn


def sexp(text):
    """Tiny s-expression parser (enough for Specctra SES)."""
    import re as _re
    toks = _re.findall(r'\(|\)|"[^"]*"|[^\s()]+', text)
    stack, cur = [], []
    for t in toks:
        if t == "(":
            stack.append(cur)
            cur = []
        elif t == ")":
            done = cur
            cur = stack.pop()
            cur.append(done)
        else:
            cur.append(t.strip('"'))
    return cur[0]


def find(node, key):
    return [c for c in node if isinstance(c, list) and c and c[0] == key]


def import_ses(board, ses_path):
    tree = sexp(open(ses_path).read())
    routes = find(tree, "routes")[0]
    res = find(routes, "resolution")[0]
    scale = {"um": 1e-3, "mm": 1.0, "mil": 0.0254, "inch": 25.4}[res[1]] / float(res[2])  # -> mm
    layers = {board.GetLayerName(l): l for l in (pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu, pcbnew.B_Cu)}
    vias = {}
    for ps in find(find(routes, "library_out")[0], "padstack") if find(routes, "library_out") else []:
        name = ps[1]
        import re as _re
        m = _re.search(r"_(\d+):(\d+)_um", name)
        if m:
            vias[name] = (int(m.group(1)) / 1000, int(m.group(2)) / 1000)
    n_tr = n_via = 0
    for net in find(find(routes, "network_out")[0], "net"):
        ni = board.FindNet(net[1])
        for w in find(net, "wire"):
            path = find(w, "path")[0]
            layer, width = layers[path[1]], float(path[2]) * scale
            pts = [(float(path[i]) * scale, -float(path[i + 1]) * scale) for i in range(3, len(path) - 1, 2)]
            for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                t = pcbnew.PCB_TRACK(board)
                t.SetStart(pcbnew.VECTOR2I(MM(x0), MM(y0)))
                t.SetEnd(pcbnew.VECTOR2I(MM(x1), MM(y1)))
                t.SetWidth(MM(width))
                t.SetLayer(layer)
                t.SetNet(ni)
                board.Add(t)
                n_tr += 1
        for v in find(net, "via"):
            dia, drill = vias.get(v[1], (0.6, 0.3))
            via = pcbnew.PCB_VIA(board)
            via.SetPosition(pcbnew.VECTOR2I(MM(float(v[2]) * scale), MM(-float(v[3]) * scale)))
            via.SetWidth(MM(dia))
            via.SetDrill(MM(drill))
            via.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
            via.SetNet(ni)
            board.Add(via)
            n_via += 1
    return n_tr, n_via


def fatten_power(board, max_w=1.2, steps=(1.2, 1.0, 0.8, 0.6, 0.5, 0.4)):
    """Widen every PWR-class track as far as clearance to other nets allows (shapely check)."""
    from shapely.geometry import LineString, Point, box as sbox
    from shapely.strtree import STRtree
    clear = 0.2
    per_layer = {}
    for fp in board.GetFootprints():
        for pd in fp.Pads():
            for layer in (pcbnew.F_Cu, pcbnew.In2_Cu, pcbnew.B_Cu):
                if pd.IsOnLayer(layer):
                    b = pd.GetBoundingBox()
                    per_layer.setdefault(layer, []).append(
                        (pd.GetNetname(), sbox(pcbnew.ToMM(b.GetLeft()), pcbnew.ToMM(b.GetTop()),
                                               pcbnew.ToMM(b.GetRight()), pcbnew.ToMM(b.GetBottom()))))
    tracks = [t for t in board.GetTracks()]
    for t in tracks:
        layers = (pcbnew.F_Cu, pcbnew.In2_Cu, pcbnew.B_Cu) if t.GetClass() == "PCB_VIA" else (t.GetLayer(),)
        for layer in layers:
            if t.GetClass() == "PCB_VIA":
                p = t.GetPosition()
                g = Point(pcbnew.ToMM(p.x), pcbnew.ToMM(p.y)).buffer(pcbnew.ToMM(t.GetWidth()) / 2)
            else:
                s, e = t.GetStart(), t.GetEnd()
                g = LineString([(pcbnew.ToMM(s.x), pcbnew.ToMM(s.y)), (pcbnew.ToMM(e.x), pcbnew.ToMM(e.y))]) \
                    .buffer(pcbnew.ToMM(t.GetWidth()) / 2)
            per_layer.setdefault(layer, []).append((t.GetNetname(), g))
    trees = {l: (STRtree([g for _, g in items]), items) for l, items in per_layer.items()}
    edge = sbox(OX + 0.35, OY + 0.35, OX + BW - 0.35, OY + BH - 0.35)
    wifi = [sbox(OX + x0, OY + y0, OX + x1, OY + y1) for x0, y0, x1, y1 in (G.WIFI_KEEPOUT, G.WIFI_KEEPOUT2)]
    widened = 0
    grown = {}   # layer -> [(net, geometry)] of tracks already widened: later ones must clear them too
    for t in tracks:
        if t.GetClass() == "PCB_VIA" or t.GetNetname() not in PWR_NETS:
            continue
        s, e = t.GetStart(), t.GetEnd()
        line = LineString([(pcbnew.ToMM(s.x), pcbnew.ToMM(s.y)), (pcbnew.ToMM(e.x), pcbnew.ToMM(e.y))])
        tree, items = trees[t.GetLayer()]
        for w in steps:
            if w <= pcbnew.ToMM(t.GetWidth()):
                break
            g = line.buffer(w / 2 + clear)
            if not edge.contains(line.buffer(w / 2)) or any(k.intersects(line.buffer(w / 2)) for k in wifi):
                continue
            hit = any(items[i][0] != t.GetNetname() for i in tree.query(g) if items[i][1].intersects(g)) \
                or any(n != t.GetNetname() and o.intersects(g) for n, o in grown.get(t.GetLayer(), ()))
            if not hit:
                t.SetWidth(MM(w))
                grown.setdefault(t.GetLayer(), []).append((t.GetNetname(), line.buffer(w / 2)))
                widened += 1
                break
    return widened


def finish(ses_path):
    board = pcbnew.LoadBoard(PCB)
    n_tr, n_via = import_ses(board, ses_path)
    widened = fatten_power(board)
    gnd = board.FindNet("GND")
    for layer in (pcbnew.F_Cu, pcbnew.In2_Cu, pcbnew.B_Cu):
        add_zone(board, gnd, layer, name=f"GND_{board.GetLayerName(layer)}")
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.Save(PCB)
    rpt = os.path.join(OUT, "route", "drc.txt")
    pcbnew.WriteDRCReport(board, rpt, pcbnew.EDA_UNITS_MILLIMETRES, True)
    return n_tr, n_via, widened, rpt
