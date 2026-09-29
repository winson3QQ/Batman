"""Local routing toolkit for the Batman HAT (KiCad 7 pcbnew + shapely).

geometry(board)      -> per-copper-layer list of (netname, shapely geom, kind, obj)
clusters(board, net) -> connected groups of copper items of one net
gaps(board)          -> for every net split into >1 group: nearest point pair between groups
render(board, box, nets, path)  -> PNG of a window, all copper layers, highlight nets
"""
import math
import os

import pcbnew
from shapely.geometry import LineString, Point, Polygon, box as sbox
from shapely.ops import nearest_points, unary_union

MM = pcbnew.FromMM
TO = pcbnew.ToMM
CU = [pcbnew.F_Cu, pcbnew.In1_Cu, pcbnew.In2_Cu, pcbnew.B_Cu]
LNAME = {pcbnew.F_Cu: "F", pcbnew.In1_Cu: "In1", pcbnew.In2_Cu: "In2", pcbnew.B_Cu: "B"}
PCB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "batman-hat.kicad_pcb")


def polyset_to_shapely(ps):
    polys = []
    for i in range(ps.OutlineCount()):
        o = ps.Outline(i)
        pts = [(TO(o.CPoint(j).x), TO(o.CPoint(j).y)) for j in range(o.PointCount())]
        if len(pts) >= 3:
            holes = []
            for h in range(ps.HoleCount(i)):
                ho = ps.Hole(i, h)
                holes.append([(TO(ho.CPoint(j).x), TO(ho.CPoint(j).y)) for j in range(ho.PointCount())])
            polys.append(Polygon(pts, holes))
    return unary_union(polys) if polys else None


def pad_geom(pad, layer):
    ps = pcbnew.SHAPE_POLY_SET()
    pad.TransformShapeToPolygon(ps, layer, 0, MM(0.005))  # default ERROR_INSIDE
    return polyset_to_shapely(ps)


def track_geom(t):
    s, e = t.GetStart(), t.GetEnd()
    w = TO(t.GetWidth())
    if s == e:
        return Point(TO(s.x), TO(s.y)).buffer(w / 2, 16)
    return LineString([(TO(s.x), TO(s.y)), (TO(e.x), TO(e.y))]).buffer(w / 2, 16)


def geometry(board, with_zones=False):
    """Returns {layer: [(net, geom, kind, obj)]} and holes [(center Point, radius, obj)]."""
    g = {l: [] for l in CU}
    holes = []
    for fp in board.GetFootprints():
        for pd in fp.Pads():
            for l in CU:
                if pd.IsOnLayer(l):
                    geom = pad_geom(pd, l)
                    if geom is not None and not geom.is_empty:
                        g[l].append((pd.GetNetname(), geom, "pad", pd))
            if pd.HasHole():
                p = pd.GetPosition()
                ds = pd.GetDrillSize()
                holes.append((Point(TO(p.x), TO(p.y)), TO(max(ds.x, ds.y)) / 2, pd))
    for t in board.GetTracks():
        if t.GetClass() == "PCB_VIA":
            p = t.GetPosition()
            c = Point(TO(p.x), TO(p.y))
            for l in CU:
                g[l].append((t.GetNetname(), c.buffer(TO(t.GetWidth()) / 2, 16), "via", t))
            holes.append((c, TO(t.GetDrillValue()) / 2, t))
        else:
            g[t.GetLayer()].append((t.GetNetname(), track_geom(t), "track", t))
    if with_zones:
        for z in board.Zones():
            if z.GetIsRuleArea() or z.GetNetname() == "GND":
                continue
            for l in CU:
                if z.IsOnLayer(l) and z.HasFilledPolysForLayer(l):
                    geom = polyset_to_shapely(z.GetFilledPolysList(l))
                    if geom is not None and not geom.is_empty:
                        # KiCad stores fills "fractured": each hole joined to the outline by a
                        # zero-width slit. Close the slits or erosion-based neck checks split there.
                        geom = geom.buffer(0.002).buffer(-0.002)
                        g[l].append((z.GetNetname(), geom, "zone", z))
    return g, holes


def clusters(board, net, geo=None):
    geo = geo or geometry(board)[0]
    items = []   # (layerset, geom, kind, obj)
    for l, lst in geo.items():
        for n, geom, kind, obj in lst:
            if n == net:
                items.append((l, geom, kind, obj))
    # union-find; items on the same layer that touch are joined; the same pad / via object on
    # several layers is one conductor
    parent = list(range(len(items)))

    def f(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def u(i, j):
        parent[f(i)] = f(j)
    byobj = {}
    for i, (l, geom, kind, obj) in enumerate(items):
        k = (kind, id(obj) if kind == "track" else (obj.m_Uuid.AsString()))
        if k in byobj and kind in ("pad", "via"):
            u(i, byobj[k])
        byobj.setdefault(k, i)
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            if items[i][0] == items[j][0] and items[i][1].distance(items[j][1]) < 1e-3:
                u(i, j)
    groups = {}
    for i in range(len(items)):
        groups.setdefault(f(i), []).append(items[i])
    return list(groups.values())


def describe(item):
    l, geom, kind, obj = item
    if kind == "pad":
        return f"{obj.GetParent().GetReference()}.{obj.GetNumber()}"
    return kind


def gaps(board, nets=None):
    geo = geometry(board)[0]
    allnets = sorted({n for lst in geo.values() for n, *_ in lst if n})
    out = []
    for net in (nets or allnets):
        if net == "GND":
            continue
        gs = clusters(board, net, geo)
        if len(gs) < 2:
            continue
        # pair every group with its nearest other group (same layer or via-able: report per-layer)
        for a in range(len(gs)):
            for b in range(a + 1, len(gs)):
                best = None
                for ia in gs[a]:
                    for ib in gs[b]:
                        d = ia[1].distance(ib[1])
                        if best is None or d < best[0]:
                            pa, pb = nearest_points(ia[1], ib[1])
                            best = (d, ia, ib, pa, pb)
                out.append((net, a, b, best[0], describe(best[1]), LNAME[best[1][0]], (round(best[3].x, 3), round(best[3].y, 3)),
                            describe(best[2]), LNAME[best[2][0]], (round(best[4].x, 3), round(best[4].y, 3)),
                            [sorted({describe(i) for i in g if i[2] == "pad"}) for g in (gs[a], gs[b])]))
    return out


def render(board, bx, nets, path, marks=(), title=""):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Polygon as MPoly
    geo, holes = geometry(board)
    x0, y0, x1, y1 = bx
    win = sbox(x0, y0, x1, y1)
    fig, axes = plt.subplots(1, 3, figsize=(27, 13))
    zc = {"VBAT_RAW": "#ff9900", "EF_IN": "#33aa33", "EF_OUT": "#aa33aa", "GND": "#dddddd"}
    for ax, l in zip(axes, (pcbnew.F_Cu, pcbnew.In2_Cu, pcbnew.B_Cu)):
        for z in board.Zones():
            if z.GetIsRuleArea() or not z.IsOnLayer(l) or not z.HasFilledPolysForLayer(l):
                continue
            zg = polyset_to_shapely(z.GetFilledPolysList(l))
            if zg is None:
                continue
            for p in getattr(zg, "geoms", [zg]):
                if p.intersects(win):
                    ax.add_patch(MPoly(list(p.exterior.coords), closed=True, fc=zc.get(z.GetNetname(), "#88ccff"),
                                       ec="none", alpha=0.35 if z.GetNetname() != "GND" else 0.5))
        for n, geom, kind, obj in geo[l]:
            if not geom.intersects(win):
                continue
            hi = n in nets
            col = {"pad": "#c08030", "track": "#3060c0", "via": "#606060"}[kind]
            if hi:
                col = "#e02020"
            for p in getattr(geom, "geoms", [geom]):
                ax.add_patch(MPoly(list(p.exterior.coords), closed=True, fc=col, ec="k", lw=0.2,
                                   alpha=0.9 if hi else 0.45))
            if kind == "pad":
                c = geom.centroid
                if win.contains(c):
                    ax.text(c.x, c.y, f"{obj.GetParent().GetReference()}.{obj.GetNumber()}\n{n[:10]}",
                            fontsize=5, ha="center", va="center")
        for c, r, obj in holes:
            if win.contains(c):
                ax.add_patch(plt.Circle((c.x, c.y), r, fc="white", ec="k", lw=0.3))
        for m in marks:
            ax.plot([m[0][0], m[1][0]], [m[0][1], m[1][1]], "m--", lw=1)
        ax.set_xlim(x0, x1)
        ax.set_ylim(y1, y0)
        ax.set_aspect("equal")
        ax.grid(True, lw=0.2)
        ax.set_title(f"{title} {LNAME[l]}")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    import sys
    b = pcbnew.LoadBoard(PCB)
    for gap in gaps(b):
        print(gap)
