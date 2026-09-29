"""Grid A* router for closing single gaps on an already-routed board.

route(board, net, src_pt, dst_pt, width, ...) connects the copper group of `net` touching
src_pt to the group touching dst_pt, on F.Cu / In2.Cu / B.Cu (In1 = GND plane, never routed),
with through vias. Obstacles: every other-net pad / track / via (+ clearance), drill holes
(hole clearance), the 0.45 mm board-edge ring and rule areas that forbid tracks / vias.
Adds PCB_TRACK / PCB_VIA items to the board and returns them (caller saves + runs DRC).
"""
import heapq
import math

import numpy as np
import pcbnew
import shapely
from shapely.geometry import LineString, Point, box as sbox
from shapely.ops import unary_union

import rt

MM, TO = rt.MM, rt.TO
LAYERS = [pcbnew.F_Cu, pcbnew.In2_Cu, pcbnew.B_Cu]
EDGE = 0.45
HOLE_CLR = 0.25


def rule_areas(board):
    """[(layerset, forbid_tracks, forbid_vias, polygon)]"""
    out = []
    for z in board.Zones():
        if not z.GetIsRuleArea():
            continue
        poly = rt.polyset_to_shapely(z.Outline())
        ls = [l for l in rt.CU if z.IsOnLayer(l)]
        out.append((ls, z.GetDoNotAllowTracks(), z.GetDoNotAllowVias(), poly, z.GetZoneName()))
    return out


def route(board, net, src_pt, dst_pt, width=0.2, clr=0.18, via_d=0.6, via_h=0.3, grid=0.05,
          margin=3.0, via_cost=25.0, layers=None, window=None, extra_obst=(), allow_layers_src=None, debug=None, gidx=None):
    layers = layers or LAYERS
    geo, holes = rt.geometry(board, with_zones=True)
    groups = rt.clusters(board, net, geo)

    def group_at(pt):
        p = Point(pt)
        best = min(range(len(groups)), key=lambda i: min(it[1].distance(p) for it in groups[i]))
        return best
    gs, gd = gidx if gidx is not None else (group_at(src_pt), group_at(dst_pt))
    assert gs != gd, "src and dst already connected"
    if window is None:
        x0, x1 = sorted((src_pt[0], dst_pt[0]))
        y0, y1 = sorted((src_pt[1], dst_pt[1]))
        window = (x0 - margin, y0 - margin, x1 + margin, y1 + margin)
    bx0 = max(window[0], rt_ox(board) + EDGE + width / 2)
    by0 = max(window[1], rt_oy(board) + EDGE + width / 2)
    bx1 = min(window[2], rt_ox(board) + 65.0 - EDGE - width / 2)
    by1 = min(window[3], rt_oy(board) + 56.5 - EDGE - width / 2)
    xs = np.arange(bx0, bx1, grid)
    ys = np.arange(by0, by1, grid)
    X, Y = np.meshgrid(xs, ys)          # [iy, ix]
    win = sbox(bx0 - 2, by0 - 2, bx1 + 2, by1 + 2)
    areas = rule_areas(board)
    free, src_mask, dst_mask, via_ok = {}, {}, {}, None
    # via keep-clear: other-net copper on every copper layer, holes
    via_obst = []
    for li, l in enumerate(layers):
        obst = []
        wide = []   # items whose own netclass clearance exceeds clr (RF): buffered separately
        for n, g, kind, obj in geo[l]:
            if n == net or not g.intersects(win):
                continue
            oc = TO(obj.GetOwnClearance(l)) + 0.02
            if oc > clr:
                wide.append(g.buffer(oc + width / 2, 16))
            else:
                obst.append(g)
        for c, r, obj in holes:
            if c.intersects(win) and not (obj.GetNetname() == net):
                obst.append(c.buffer(r + HOLE_CLR - clr, 16))
        for ls, ft, fv, poly, name in areas:
            if ft and l in ls and poly.intersects(win):
                obst.append(poly.buffer(-clr + width / 2 * 0))   # rule area: track body must stay out
        U = unary_union(obst).buffer(clr + width / 2, 16) if obst else None
        if wide:
            U = unary_union([U] + wide) if U is not None else unary_union(wide)
        f = np.ones(X.shape, bool) if U is None else ~shapely.contains_xy(U, X, Y)
        free[li] = f
        own_s = unary_union([it[1] for it in groups[gs] if it[0] == l])
        own_d = unary_union([it[1] for it in groups[gd] if it[0] == l])
        src_mask[li] = (shapely.contains_xy(own_s, X, Y) if not own_s.is_empty else np.zeros(X.shape, bool))
        dst_mask[li] = (shapely.contains_xy(own_d, X, Y) if not own_d.is_empty else np.zeros(X.shape, bool))
        if allow_layers_src is not None and l not in allow_layers_src:
            src_mask[li][:] = False
        # starting / ending inside own copper is always allowed
        free[li] |= src_mask[li] | dst_mask[li]
    # vias: clear of other-net copper on all 4 copper layers (In1 is a GND pour -> it refills,
    # but GND pads / vias on In1 are real) + hole clearance
    vo = []
    for l in rt.CU:
        for n, g, kind, obj in geo[l]:
            if n != net and g.intersects(win) and not (l == pcbnew.In1_Cu and kind != "via" and kind != "pad"):
                vo.append(g.buffer(max(clr, TO(obj.GetOwnClearance(l)) + 0.02) + via_d / 2, 16))
            elif n == net and kind == "pad" and g.intersects(win) and not obj.HasHole():
                vo.append(g.buffer(via_d / 2 + 0.05, 16))     # no via-in-pad
    for c, r, obj in holes:
        if c.intersects(win):
            vo.append(c.buffer(r + HOLE_CLR + via_h / 2, 16))
    for ls, ft, fv, poly, name in areas:
        if fv and poly.intersects(win):
            vo.append(poly.buffer(via_d / 2, 16))
    VU = unary_union(vo)
    via_ok = ~shapely.contains_xy(VU, X, Y)
    # via ring must also stay inside the edge ring
    via_ok &= (X > rt_ox(board) + EDGE + via_d / 2) & (X < rt_ox(board) + 65 - EDGE - via_d / 2) & \
              (Y > rt_oy(board) + EDGE + via_d / 2) & (Y < rt_oy(board) + 56.5 - EDGE - via_d / 2)
    H, W = X.shape
    INF = float("inf")
    dist = {}
    prev = {}
    pq = []
    tx, ty = dst_pt
    for li in range(len(layers)):
        for iy, ix in zip(*np.nonzero(src_mask[li])):
            s = (li, iy, ix)
            dist[s] = 0.0
            heapq.heappush(pq, (math.hypot(xs[ix] - tx, ys[iy] - ty) / grid, 0.0, s))
    moves = [(1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
             (1, 1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (-1, -1, 1.4142)]
    goal = None
    while pq:
        f, d, s = heapq.heappop(pq)
        if d > dist.get(s, INF):
            continue
        li, iy, ix = s
        if dst_mask[li][iy, ix]:
            goal = s
            break
        cand = []
        for dx, dy, c in moves:
            nx, ny = ix + dx, iy + dy
            if 0 <= nx < W and 0 <= ny < H and free[li][ny, nx]:
                # diagonal: both orthogonal neighbours free keeps the segment clear
                if dx and dy and not (free[li][iy, nx] and free[li][ny, ix]):
                    continue
                # turning penalty keeps paths straight
                cand.append(((li, ny, nx), c + (0.3 if (s in prev and _dir(prev[s], s) != (dy, dx)) else 0)))
        if via_ok[iy, ix]:
            for lj in range(len(layers)):
                if lj != li and free[lj][iy, ix]:
                    cand.append(((lj, iy, ix), via_cost))
        for ns, c in cand:
            nd = d + c
            if nd < dist.get(ns, INF):
                dist[ns] = nd
                prev[ns] = s
                heapq.heappush(pq, (nd + math.hypot(xs[ns[2]] - tx, ys[ns[1]] - ty) / grid, nd, ns))
    if goal is None:
        if debug:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            fig, axes = plt.subplots(1, len(layers), figsize=(8 * len(layers), 10))
            for li in range(len(layers)):
                img = np.zeros(X.shape + (3,))
                img[..., 0] = ~free[li]
                img[..., 2] = src_mask[li] | dst_mask[li]
                vis = np.zeros(X.shape, bool)
                for (lj, iy, ix) in dist:
                    if lj == li:
                        vis[iy, ix] = True
                img[..., 1] = vis
                img[..., 1] = np.maximum(img[..., 1], 0.3 * via_ok)
                axes[li].imshow(img, extent=(xs[0], xs[-1], ys[-1], ys[0]))
                axes[li].set_title(str(layers[li]))
            fig.savefig(debug, dpi=90)
        return None
    path = [goal]
    while path[-1] in prev:
        path.append(prev[path[-1]])
    path.reverse()
    return emit(board, net, path, xs, ys, layers, width, via_d, via_h)


def _dir(a, b):
    return (b[1] - a[1], b[2] - a[2])


def emit(board, net, path, xs, ys, layers, width, via_d, via_h):
    ni = board.FindNet(net)
    added = []
    # split into same-layer runs, collapse collinear points
    runs, cur = [], [path[0]]
    for s in path[1:]:
        if s[0] != cur[-1][0]:
            runs.append(cur)
            v = pcbnew.PCB_VIA(board)
            v.SetPosition(pcbnew.VECTOR2I(MM(float(xs[s[2]])), MM(float(ys[s[1]]))))
            v.SetWidth(MM(via_d))
            v.SetDrill(MM(via_h))
            v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
            v.SetNet(ni)
            board.Add(v)
            added.append(v)
            cur = [s]
        else:
            cur.append(s)
    runs.append(cur)
    for r in runs:
        if len(r) < 2:
            continue
        pts = [r[0]]
        for a, b, c in zip(r, r[1:], r[2:]):
            if _dir(a, b) != _dir(b, c):
                pts.append(b)
        pts.append(r[-1])
        for a, b in zip(pts, pts[1:]):
            t = pcbnew.PCB_TRACK(board)
            t.SetStart(pcbnew.VECTOR2I(MM(float(xs[a[2]])), MM(float(ys[a[1]]))))
            t.SetEnd(pcbnew.VECTOR2I(MM(float(xs[b[2]])), MM(float(ys[b[1]]))))
            t.SetWidth(MM(width))
            t.SetLayer(layers[a[0]])
            t.SetNet(ni)
            board.Add(t)
            added.append(t)
    return added


def rt_ox(board):
    return 100.0


def rt_oy(board):
    return 100.0


def refill_and_drc(board, pcb_path, rpt):
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.Save(pcb_path)
    b2 = pcbnew.LoadBoard(pcb_path)
    pcbnew.WriteDRCReport(b2, rpt, pcbnew.EDA_UNITS_MILLIMETRES, True)
    import re, collections
    txt = open(rpt).read()
    c = collections.Counter(re.findall(r"^\[(\w+)\]", txt, re.M))
    return {k: v for k, v in c.items() if not k.startswith(("silk", "lib_"))}


def via_spots(board, net, center, radius=1.5, clr=0.15, via_d=0.6, via_h=0.3, grid=0.05, touch=None):
    """Legal via centres of `net` within `radius` of `center`, nearest first. With touch=(layer, geom)
    only spots whose via ring overlaps that copper (so it connects without a track)."""
    geo, holes = rt.geometry(board)
    cx, cy = center
    win = sbox(cx - radius - 2, cy - radius - 2, cx + radius + 2, cy + radius + 2)
    vo = []
    for l in rt.CU:
        for n, g, kind, obj in geo[l]:
            if n != net and g.intersects(win) and (l != pcbnew.In1_Cu or kind in ("via", "pad")):
                vo.append(g.buffer(clr + via_d / 2, 16))
            elif n == net and kind == "pad" and g.intersects(win) and not obj.HasHole():
                vo.append(g.buffer(via_d / 2 + 0.05, 16))     # no via-in-pad
    for c, r, obj in holes:
        if c.intersects(win):
            vo.append(c.buffer(r + HOLE_CLR + via_h / 2, 16))
    for ls, ft, fv, poly, name in rule_areas(board):
        if fv and poly.intersects(win):
            vo.append(poly.buffer(via_d / 2, 16))
    VU = unary_union(vo)
    out = []
    for x in np.arange(cx - radius, cx + radius + 1e-9, grid):
        for y in np.arange(cy - radius, cy + radius + 1e-9, grid):
            if math.hypot(x - cx, y - cy) > radius:
                continue
            if not (100 + EDGE + via_d / 2 < x < 165 - EDGE - via_d / 2 and 100 + EDGE + via_d / 2 < y < 156.5 - EDGE - via_d / 2):
                continue
            p = Point(x, y)
            if VU.contains(p):
                continue
            if touch is not None and not Point(x, y).buffer(via_d / 2).intersects(touch):
                continue
            out.append((math.hypot(x - cx, y - cy), round(float(x), 3), round(float(y), 3)))
    return sorted(out)


def connect_all(board, net, max_iter=20, **kw):
    """Route a multi-terminal net until it is one copper group: always join the two nearest groups."""
    from shapely.ops import nearest_points
    n = 0
    for _ in range(max_iter):
        geo, _h = rt.geometry(board, with_zones=True)
        groups = rt.clusters(board, net, geo)
        if len(groups) < 2:
            return n
        best = None
        for a in range(len(groups)):
            ua = unary_union([it[1] for it in groups[a]])
            for b in range(a + 1, len(groups)):
                ub = unary_union([it[1] for it in groups[b]])
                d = ua.distance(ub)
                if best is None or d < best[0]:
                    pa, pb = nearest_points(ua, ub)
                    best = (d, (pa.x, pa.y), (pb.x, pb.y), (a, b))
        r = route(board, net, best[1], best[2], gidx=best[3], **kw)
        if r is None:
            raise RuntimeError(f"connect_all {net}: no route {best[1]} -> {best[2]} ({len(groups)} groups)")
        n += 1
    raise RuntimeError(f"connect_all {net}: too many iterations")
