"""Widest-path (max-min width) between two pads of a net: which segment limits the current path.

Graph: track segments (edge weight = width), vias join all copper layers (weight = VIA_EQ mm, a
0.3 mm drill ~ a 0.8 mm outer track for current), pads and filled zones are wide nodes. Two items
are adjacent when their copper overlaps on a shared layer.
usage: bottleneck.py NET REF.PAD REF.PAD [REF.PAD ...]
"""
import heapq
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pcbnew  # noqa: E402

import rt  # noqa: E402
from shapely.ops import unary_union  # noqa: E402

VIA_EQ = 0.8
b = pcbnew.LoadBoard(os.environ.get("HAT_PCB", rt.PCB))
net = sys.argv[1]
geo, _ = rt.geometry(b, with_zones=True)
items = []   # (layer, geom, kind, obj, width)
for l, lst in geo.items():
    for n, g, k, o in lst:
        if n != net:
            continue
        w = {"track": lambda: rt.TO(o.GetWidth()), "via": lambda: VIA_EQ}.get(k, lambda: 99.0)()
        items.append((l, g, k, o, w))
key = lambda it: it[3].m_Uuid.AsString() if it[2] != "zone" else f"zone{id(it[3])}{it[0]}"
nodes = {}
for it in items:
    nodes.setdefault(key(it), []).append(it)
adj = {k: set() for k in nodes}
lst = list(items)
for i in range(len(lst)):
    for j in range(i + 1, len(lst)):
        a, c = lst[i], lst[j]
        if a[0] == c[0] and a[1].distance(c[1]) < 1e-3:
            adj[key(a)].add(key(c))
            adj[key(c)].add(key(a))
width = {k: min(it[4] for it in v) for k, v in nodes.items()}


def pad_key(s):
    ref, num = s.split(".")
    for k, v in nodes.items():
        it = v[0]
        if it[2] == "pad" and it[3].GetParent().GetReference() == ref and it[3].GetNumber() == num:
            return k
    raise KeyError(s)


def describe(k):
    it = nodes[k][0]
    l, g, kind, o, w = it
    if kind == "pad":
        return f"{o.GetParent().GetReference()}.{o.GetNumber()}"
    if kind == "zone":
        return f"zone {rt.LNAME[l]}"
    c = g.centroid
    return f"{kind} {rt.LNAME[l]} w{w:.2f} @({c.x:.2f},{c.y:.2f})"


src = pad_key(sys.argv[2])
for dst_s in sys.argv[3:]:
    dst = pad_key(dst_s)
    best = {src: 99.0}
    prev = {}
    pq = [(-99.0, src)]
    while pq:
        negw, k = heapq.heappop(pq)
        if -negw < best.get(k, -1):
            continue
        for m in adj[k]:
            w = min(-negw, width[m])
            if w > best.get(m, -1):
                best[m] = w
                prev[m] = k
                heapq.heappush(pq, (-w, m))
    if dst not in best:
        print(f"{net} {sys.argv[2]} -> {dst_s}: NOT CONNECTED")
        continue
    path, k = [], dst
    while k != src:
        path.append(k)
        k = prev[k]
    path.append(src)
    bn = best[dst]
    # pours count as 99 mm in the search; measure their real neck between the path neighbours:
    # the widest w for which the pour eroded by w/2 still joins entry and exit copper
    necks = []
    for i, k in enumerate(path):
        if nodes[k][0][2] != "zone" or i == 0 or i == len(path) - 1:
            continue
        zg = nodes[k][0][1]
        a = unary_union([it[1] for it in nodes[path[i + 1]]])
        c = unary_union([it[1] for it in nodes[path[i - 1]]])
        lo, hi = 0.0, 4.0
        for _ in range(12):
            w = (lo + hi) / 2
            er = zg.buffer(-w / 2)
            parts = getattr(er, "geoms", [er])
            ok = any(p.intersects(a.buffer(w / 2)) and p.intersects(c.buffer(w / 2)) for p in parts if not p.is_empty)
            lo, hi = (w, hi) if ok else (lo, w)
        # locate the neck: just above it the eroded pour splits; the gap between the piece touching
        # the entry and the piece touching the exit is where it pinches
        er = zg.buffer(-(lo + 0.05) / 2)
        parts = [p for p in getattr(er, "geoms", [er]) if not p.is_empty]
        pa = [p for p in parts if p.intersects(c.buffer((lo + 0.05) / 2))]
        pb = [p for p in parts if p.intersects(a.buffer((lo + 0.05) / 2))]
        where = ""
        if pa and pb:
            from shapely.ops import nearest_points
            q1, q2 = nearest_points(unary_union(pa), unary_union(pb))
            where = f" near ({(q1.x + q2.x) / 2 - 100:.2f},{(q1.y + q2.y) / 2 - 100:.2f}) board-rel"
        necks.append((round(lo, 2), describe(k) + where))
        bn = min(bn, lo)
    narrow = [describe(k) for k in path if width[k] <= bn + 1e-6] + [f"{d} neck {w}" for w, d in necks if w <= bn + 1e-6]
    print(f"{net} {sys.argv[2]} -> {dst_s}: bottleneck {bn:.2f} mm at {narrow[:4]}")
    if os.environ.get("HAT_BN_PATH"):
        print("    path:", [(describe(k), round(width[k], 2)) for k in path], "necks:", necks)
    if os.environ.get("HAT_BN_DETAIL"):
        thin = [(width[k], nodes[k][0]) for k in path if width[k] < 1.0 and nodes[k][0][2] == "track"]
        L = sum(rt.TO(it[3].GetLength()) for w, it in thin)
        print(f"    segments < 1.0 mm on this path: {len(thin)}, total {L:.1f} mm; vias on path: "
              f"{sum(1 for k in path if nodes[k][0][2] == 'via')}")
        for w, it in thin:
            s0, e0 = it[3].GetStart(), it[3].GetEnd()
            print(f"      w{w:.2f} {rt.LNAME[it[0]]:3s} ({rt.TO(s0.x) - 100:.2f},{rt.TO(s0.y) - 100:.2f})->"
                  f"({rt.TO(e0.x) - 100:.2f},{rt.TO(e0.y) - 100:.2f}) len {rt.TO(it[3].GetLength()):.2f}")
