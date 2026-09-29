#!/usr/bin/env python3
"""Escape proof for the layout-v2 sketch (PLAN G0.5), run in WSL with KiCad 7 pcbnew.

Builds an experiment board from the current board's footprints (nets intact), keeps only the
parts in sketch.json at their sketch positions, adds the planned power pours (escape.json),
places a GND via next to every listed GND pad, then routes the listed nets with the deterministic
grid A* router (closeout/router.py) under the JLC 2 oz outer-layer rules, and runs KiCad DRC.
The main board file is only read. Output: escape.kicad_pcb, escape-drc.rpt, escape-*.png, stdout.
"""
import collections
import json
import os
import re
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
HAT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HAT, "closeout"))
import router  # noqa: E402
import rt  # noqa: E402

MM = pcbnew.FromMM
O = 100.0
RULE = dict(width=0.2, clr=0.21, via_d=0.8, via_h=0.3)   # JLC 2 oz outer: >= 0.15/0.15, via ring >= 0.254


def pt(x, y):
    return pcbnew.VECTOR2I(MM(x + O), MM(y + O))


def rect_zone(board, net, layer, r, name, prio=1):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNetCode(board.GetNetcodeFromNetname(net))
    z.SetZoneName(name)
    z.SetAssignedPriority(prio)
    z.SetLocalClearance(MM(RULE["clr"]))
    z.SetMinThickness(MM(0.2))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    ol = z.Outline()
    ol.NewOutline()
    for x, y in ((r[0], r[1]), (r[2], r[1]), (r[2], r[3]), (r[0], r[3])):
        ol.Append(MM(x + O), MM(y + O))
    board.Add(z)
    return z


def keepout(board, r, name):
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    z.SetDoNotAllowTracks(True)
    z.SetDoNotAllowVias(True)
    z.SetDoNotAllowPads(True)
    z.SetDoNotAllowCopperPour(True)
    z.SetDoNotAllowFootprints(False)
    z.SetLayerSet(pcbnew.LSET.AllCuMask())
    z.SetZoneName(name)
    ol = z.Outline()
    ol.NewOutline()
    for x, y in ((r[0], r[1]), (r[2], r[1]), (r[2], r[3]), (r[0], r[3])):
        ol.Append(MM(x + O), MM(y + O))
    board.Add(z)


def layer_id(name):
    return {"F": pcbnew.F_Cu, "In1": pcbnew.In1_Cu, "In2": pcbnew.In2_Cu, "B": pcbnew.B_Cu}[name]


def necks(board, es):
    # 6. neck width of each planned current path, per layer: morphological opening keeps copper
    #    at least w wide; pads are added back (pad entries are set by the package, PLAN §1-A)
    from shapely.geometry import Point
    from shapely.ops import unary_union
    geo, _h = rt.geometry(board, with_zones=True)
    fpd = {f.GetReference(): f for f in board.GetFootprints()}

    def padgeom(rp, layer):
        ref, num = rp.split(".")
        gs = [rt.pad_geom(p, layer) for p in fpd[ref].Pads() if p.GetNumber() == num and p.IsOnLayer(layer)]
        gs = [g for g in gs if g is not None]
        return unary_union(gs) if gs else None
    print("\nneck widths (outer layers; pads exempt):")
    for net, a, b in es.get("paths", []):
        res = []
        for lname, layer in (("F", pcbnew.F_Cu), ("In2", pcbnew.In2_Cu), ("B", pcbnew.B_Cu)):
            cu = unary_union([g for n, g, k, o in geo[layer] if n == net])
            ga, gb = padgeom(a, layer), padgeom(b, layer)
            if layer == pcbnew.In2_Cu and not cu.is_empty:
                vias = [g for n, g, k, o in geo[layer] if n == net and k == "via"]
                pa, pb = padgeom(a, pcbnew.F_Cu), padgeom(b, pcbnew.F_Cu)
                if vias and pa is not None and pb is not None:
                    ga = min(vias, key=lambda v: v.distance(pa))
                    gb = min(vias, key=lambda v: v.distance(pb))
            if cu.is_empty or ga is None or gb is None:
                continue
            lo, hi = 0.0, 6.0
            for _ in range(22):
                w = (lo + hi) / 2
                # erosion only: a corridor >= w wide exists iff the eroded copper still joins the pads.
                # (an opening re-dilates and merges blobs across short necks -> over-reports; r3 review)
                op = cu.buffer(-w / 2, 8)
                # pad-entry exemption: the pad plus its own w/2 neighbourhood of same-net copper
                ea = ga.buffer(w / 2 + 0.01, 8).intersection(cu)
                eb = gb.buffer(w / 2 + 0.01, 8).intersection(cu)
                sh = unary_union([op, ea, eb])
                parts = list(sh.geoms) if hasattr(sh, "geoms") else [sh]
                ca = [i for i, pp in enumerate(parts) if pp.intersects(ga.representative_point())]
                cb = [i for i, pp in enumerate(parts) if pp.intersects(gb.representative_point())]
                if ca and cb and ca[0] == cb[0]:
                    lo = w
                else:
                    hi = w
            res.append(f"{lname} {lo:.2f} mm" if lo < 5.9 else f"{lname} short hop (pads adjacent)")
        print(f"  {net:9s} {a:>6s} -> {b:<6s}: " + (", ".join(res) or "NOT ON F/B"))


def measure_only():
    es = json.load(open(os.path.join(HERE, "escape.json"), encoding="utf-8"))
    board = pcbnew.LoadBoard(os.path.join(HERE, "escape.kicad_pcb"))
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    necks(board, es)


def main():
    if os.environ.get("MEASURE_ONLY"):
        return measure_only()
    sk = json.load(open(os.path.join(HERE, "sketch.json"), encoding="utf-8"))
    es = json.load(open(os.path.join(HERE, "escape.json"), encoding="utf-8"))
    src = os.environ.get("SRC_BOARD") or os.path.join(HAT, "batman-hat.kicad_pcb")
    print("source board:", src, flush=True)
    board = pcbnew.LoadBoard(src)
    pos = {**sk["fixed"], **sk["place"]}
    # 1. strip copper, old rule areas (keep the edge ring), unplaced footprints
    for t in list(board.GetTracks()):
        board.Delete(t)
    for z in list(board.Zones()):
        if not (z.GetIsRuleArea() and z.GetZoneName().startswith("edge_ring")):
            board.Delete(z)
    for fp in list(board.GetFootprints()):
        ref = fp.GetReference()
        if ref not in pos:
            board.Delete(fp)
        elif ref != "J2":
            x, y, r = pos[ref][:3]
            fp.SetPosition(pt(x, y))
            fp.SetOrientationDegrees(r)
    sys.path.insert(0, os.path.join(HAT, "gen"))
    import design as D
    import gen_pcb as G
    have = {f.GetReference() for f in board.GetFootprints()}
    for part in D.PARTS:
        if part.ref in pos and part.ref not in have:
            name = part.fp.split(":")[1]
            src = next(f for f in board.GetFootprints() if str(f.GetFPID().GetLibItemName()) == name)
            fp = pcbnew.Cast_to_FOOTPRINT(src.Duplicate())   # FootprintLoad segfaults after LoadBoard
            fp.SetReference(part.ref)
            fp.SetValue(part.value)
            board.Add(fp)
            for pad in fp.Pads():
                net = part.pins.get(pad.GetNumber())
                if net:
                    ni = board.FindNet(net)
                    if ni is None:
                        ni = pcbnew.NETINFO_ITEM(board, net)
                        board.Add(ni)
                    pad.SetNet(ni)
            x, y, r = pos[part.ref][:3]
            fp.SetPosition(pt(x, y))
            fp.SetOrientationDegrees(r)
    keepout(board, (0.0, 0.0, 6.3, 20.0), "antenna_strip")
    # 2. 2 oz outer design rules
    ds = board.GetDesignSettings()
    ds.m_MinClearance = MM(0.15)
    ds.m_TrackMinWidth = MM(0.15)
    ds.m_ViasMinSize = MM(0.8)
    ds.m_ViasMinAnnularWidth = MM(0.25)
    ns = ds.m_NetSettings
    for nc in [ns.m_DefaultNetClass] + [v for k, v in ns.m_NetClasses.items()]:
        nc.SetClearance(MM(max(0.2, pcbnew.ToMM(nc.GetClearance()))))
        nc.SetViaDiameter(MM(0.8))
        nc.SetViaDrill(MM(0.3))
    _ra = router.rule_areas

    def rule_areas_with_fp(b):
        out = _ra(b)
        for f in b.GetFootprints():
            for z in f.Zones():
                if not z.GetIsRuleArea():
                    continue
                poly = rt.polyset_to_shapely(z.Outline())
                ls = [l for l in rt.CU if z.IsOnLayer(l)]
                out.append((ls, z.GetDoNotAllowTracks(), z.GetDoNotAllowVias(), poly, f"{f.GetReference()}:{z.GetZoneName()}"))
        return out
    router.rule_areas = rule_areas_with_fp
    # provisional standoff drill keep-outs (all layers)
    for cx, cy, r in es.get("standoff_keepouts", []):
        z = pcbnew.ZONE(board)
        z.SetIsRuleArea(True)
        z.SetDoNotAllowTracks(True)
        z.SetDoNotAllowVias(True)
        z.SetDoNotAllowCopperPour(True)
        z.SetDoNotAllowPads(False)
        z.SetDoNotAllowFootprints(False)
        z.SetLayerSet(pcbnew.LSET.AllCuMask())
        z.SetZoneName("standoff_npth")
        ol = z.Outline()
        ol.NewOutline()
        import math as _m
        for k in range(24):
            ol.Append(MM(cx + O + r * _m.cos(k * _m.pi / 12)), MM(cy + O + r * _m.sin(k * _m.pi / 12)))
        board.Add(z)
    # no via under a standoff pad (solder wicks into the via -> spacer tilts / height off; review 2026-09-29 M3)
    vr = es.get("standoff_via_keepout_r")
    for cx, cy, _r in (es.get("standoff_keepouts", []) if vr else []):
        z = pcbnew.ZONE(board)
        z.SetIsRuleArea(True)
        z.SetDoNotAllowTracks(False)
        z.SetDoNotAllowVias(True)
        z.SetDoNotAllowCopperPour(False)
        z.SetDoNotAllowPads(False)
        z.SetDoNotAllowFootprints(False)
        z.SetLayerSet(pcbnew.LSET.AllCuMask())
        z.SetZoneName("standoff_novia")
        ol = z.Outline()
        ol.NewOutline()
        for k in range(24):
            ol.Append(MM(cx + O + vr * _m.cos(k * _m.pi / 12)), MM(cy + O + vr * _m.sin(k * _m.pi / 12)))
        board.Add(z)
    # 3. planned pours + the In1 GND plane
    for p in es["pours"]:
        for i, r in enumerate(p["rects"]):
            rect_zone(board, p["net"], layer_id(p.get("layer", "F")), r, f"{p['net']}_{p.get('layer', 'F')}_{i}")
    rect_zone(board, "GND", pcbnew.In1_Cu, (0.5, 0.5, 64.5, 56.0), "GND_In1", prio=0)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    log = []
    # 4b. hand-planned escape tracks and vias (the corners the plan fixes explicitly)
    for tk in es.get("tracks", []):
        pts = tk["pts"]
        for a, b in zip(pts, pts[1:]):
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(pt(*a))
            t.SetEnd(pt(*b))
            t.SetWidth(MM(tk.get("width", RULE["width"])))
            t.SetLayer(layer_id(tk.get("layer", "F")))
            t.SetNetCode(board.GetNetcodeFromNetname(tk["net"]))
            board.Add(t)
    for vv in es.get("vias", []):
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(pt(*vv["at"]))
        v.SetWidth(MM(RULE["via_d"]))
        v.SetDrill(MM(RULE["via_h"]))
        v.SetNetCode(board.GetNetcodeFromNetname(vv["net"]))
        board.Add(v)
    # 4. a GND via beside every listed GND pad (they compete for the same space as escapes)
    fps = {f.GetReference(): f for f in board.GetFootprints()}
    nvia = es.get("gnd_vias_n", {})
    # GND vias must not land in another net's planned pour (the refill would carve / sever it)
    _geo = rt.geometry
    rt.geometry = lambda b, with_zones=True: _geo(b, with_zones=True)
    for ref in es["gnd_vias"]:
        for pad in [p for p in fps[ref].Pads() for _ in range(nvia.get(ref, 1))]:
            if pad.GetNetname() != "GND" or pad.HasHole():
                continue
            c = pad.GetPosition()
            geom = rt.pad_geom(pad, pcbnew.F_Cu)
            spots = router.via_spots(board, "GND", (pcbnew.ToMM(c.x), pcbnew.ToMM(c.y)), radius=2.4 if nvia.get(ref, 1) > 1 else 1.6,
                                     clr=RULE["clr"], via_d=RULE["via_d"], via_h=RULE["via_h"])
            ok = False
            for d, x, y in spots:
                v = pcbnew.PCB_VIA(board)
                v.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
                v.SetWidth(MM(RULE["via_d"]))
                v.SetDrill(MM(RULE["via_h"]))
                v.SetNetCode(board.GetNetcodeFromNetname("GND"))
                board.Add(v)
                r = None
                try:
                    r = router.route(board, "GND", (pcbnew.ToMM(c.x), pcbnew.ToMM(c.y)), (x, y),
                                     layers=[pcbnew.F_Cu], margin=1.5, **RULE)
                except Exception:
                    r = None
                if r is not None:
                    ok = True
                    break
                board.Delete(v)
            log.append(("gnd-via", f"{ref}.{pad.GetNumber()}", "ok" if ok else "NO SPOT"))
    rt.geometry = _geo
    # 5. route the listed nets, most constrained first
    for item in es["routes"]:
        net = item["net"]
        kw = dict(RULE)
        kw.update(item.get("rule", {}))
        if "layers" in item:
            kw["layers"] = [layer_id(l) for l in item["layers"]]
        try:
            n = router.connect_all(board, net, max_iter=40, margin=item.get("margin", 3.0), **kw)
            log.append(("route", net, f"ok ({n} links)"))
        except Exception as e:
            log.append(("route", net, f"FAIL {e}"))
    # 5b. every remaining multi-pad net (G2 pre-check), shortest span first
    rest = es.get("route_rest")
    if rest:
        done = {i["net"] for i in es["routes"]} | set(rest.get("skip", []))
        span = {}
        for f in board.GetFootprints():
            for p in f.Pads():
                n = p.GetNetname()
                if n and n not in done:
                    span.setdefault(n, []).append((pcbnew.ToMM(p.GetPosition().x), pcbnew.ToMM(p.GetPosition().y)))
        nets = [n for n, pts in span.items() if len(pts) > 1]
        nets.sort(key=lambda n: max(abs(a[0] - b[0]) + abs(a[1] - b[1]) for a in span[n] for b in span[n]))
        first = [n for n in rest.get("first", []) if n in nets]
        nets = first + [n for n in nets if n not in first]
        for net in nets:
            kw = dict(RULE)
            if net in rest.get("wide", {}):
                kw["width"] = rest["wide"][net]
            try:
                n = router.connect_all(board, net, max_iter=60, margin=rest.get("margin", 10.0), **kw)
                log.append(("rest", net, f"ok ({n} links)"))
            except Exception as e:
                log.append(("rest", net, f"FAIL {e}"))
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    out = os.path.join(HERE, "escape.kicad_pcb")
    rpt = os.path.join(HERE, "escape-drc.rpt")
    pcbnew.WriteDRCReport(board, rpt, pcbnew.EDA_UNITS_MILLIMETRES, True)
    board.Save(out)
    txt = open(rpt).read()
    kinds = collections.Counter(re.findall(r"^\[(\w+)\]", txt, re.M))
    routed = {i["net"] for i in es["routes"]}
    blocks = re.split(r"\n(?=\[)", txt)
    unconn = collections.Counter()
    for b in blocks:
        if b.startswith("[unconnected_items]"):
            for n in re.findall(r"\[([^\]]+)\] ", b):
                pass
            m = re.findall(r"Net ([^\s\]]+)|\[([^\]]+)\]", b)
    for line in log:
        print(" | ".join(line))
    fails = [l for l in log if l[2].startswith(("FAIL", "NO SPOT"))]
    print("\nDRC:", dict(sorted(kinds.items())))
    for k in ("clearance", "shorting_items", "tracks_crossing", "hole_clearance", "copper_edge_clearance",
              "courtyards_overlap", "items_not_allowed", "via_diameter", "annular_width", "track_width"):
        if kinds.get(k):
            print(f"  DRC {k}: {kinds[k]}")
    print(f"\n{len(fails)} escape/via failures; see escape-drc.rpt")
    necks(board, es)
    for name, win in es.get("render", {}).items():
        rt.render(board, (win[0] + O, win[1] + O, win[2] + O, win[3] + O), sorted(routed),
                  os.path.join(HERE, f"escape-{name}.png"), title=name)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
