"""Small hand edits on the routed board: move / remove / add vias and tracks."""
import pcbnew

import rt

MM, TO = rt.MM, rt.TO
TOL = 0.01


def _near(p, xy):
    return abs(TO(p.x) - xy[0]) < TOL and abs(TO(p.y) - xy[1]) < TOL


def find_via(board, net, xy):
    for t in board.GetTracks():
        if t.GetClass() == "PCB_VIA" and t.GetNetname() == net and _near(t.GetPosition(), xy):
            return t
    raise KeyError(f"no {net} via at {xy}")


def move_via(board, net, old, new):
    """Move a via; every track end of the same net sitting on it follows."""
    v = find_via(board, net, old)
    v.SetPosition(pcbnew.VECTOR2I(MM(new[0]), MM(new[1])))
    n = 0
    for t in board.GetTracks():
        if t.GetClass() == "PCB_VIA" or t.GetNetname() != net:
            continue
        if _near(t.GetStart(), old):
            t.SetStart(pcbnew.VECTOR2I(MM(new[0]), MM(new[1])))
            n += 1
        if _near(t.GetEnd(), old):
            t.SetEnd(pcbnew.VECTOR2I(MM(new[0]), MM(new[1])))
            n += 1
    return n


def remove_via(board, net, xy, with_tracks=True):
    """Remove a via and (optionally) the tracks of that net that end on it."""
    v = find_via(board, net, xy)
    gone = [v]
    if with_tracks:
        gone += [t for t in board.GetTracks() if t.GetClass() != "PCB_VIA" and t.GetNetname() == net
                 and (_near(t.GetStart(), xy) or _near(t.GetEnd(), xy))]
    for t in gone:
        board.Remove(t)
    return len(gone)


def add_via(board, net, xy, d=0.6, h=0.3):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(pcbnew.VECTOR2I(MM(xy[0]), MM(xy[1])))
    v.SetWidth(MM(d))
    v.SetDrill(MM(h))
    v.SetLayerPair(pcbnew.F_Cu, pcbnew.B_Cu)
    v.SetNet(board.FindNet(net))
    board.Add(v)
    return v


LAYER = {"F": pcbnew.F_Cu, "In2": pcbnew.In2_Cu, "B": pcbnew.B_Cu}


def add_track(board, net, layer, pts, w=0.2):
    out = []
    for a, b in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(pcbnew.VECTOR2I(MM(a[0]), MM(a[1])))
        t.SetEnd(pcbnew.VECTOR2I(MM(b[0]), MM(b[1])))
        t.SetWidth(MM(w))
        t.SetLayer(LAYER[layer])
        t.SetNet(board.FindNet(net))
        board.Add(t)
        out.append(t)
    return out


def set_track_end(board, net, layer, old, new):
    n = 0
    for t in board.GetTracks():
        if t.GetClass() == "PCB_VIA" or t.GetNetname() != net or t.GetLayer() != LAYER[layer]:
            continue
        if _near(t.GetStart(), old):
            t.SetStart(pcbnew.VECTOR2I(MM(new[0]), MM(new[1])))
            n += 1
        if _near(t.GetEnd(), old):
            t.SetEnd(pcbnew.VECTOR2I(MM(new[0]), MM(new[1])))
            n += 1
    return n


def remove_track(board, net, layer, a, b):
    for t in list(board.GetTracks()):
        if t.GetClass() != "PCB_VIA" and t.GetNetname() == net and t.GetLayer() == LAYER[layer] and \
                ((_near(t.GetStart(), a) and _near(t.GetEnd(), b)) or (_near(t.GetStart(), b) and _near(t.GetEnd(), a))):
            board.Remove(t)
            return 1
    raise KeyError(f"no {net} track {a}-{b} on {layer}")


def rip_group(board, net, xy):
    """Remove every track / via of `net` in the connected group touching point xy (pads stay)."""
    from shapely.geometry import Point
    groups = rt.clusters(board, net)
    p = Point(xy)
    g = min(groups, key=lambda grp: min(it[1].distance(p) for it in grp))
    objs = {}
    for l, geom, kind, obj in g:
        if kind in ("track", "via"):
            objs[obj.m_Uuid.AsString()] = obj
    for o in objs.values():
        board.Remove(o)
    return len(objs)


def place(board, ref, x, y, rot=None):
    """Move a footprint to board-relative (x, y) mm (origin = board top-left), optional rotation."""
    fp = board.FindFootprintByReference(ref)
    fp.SetPosition(pcbnew.VECTOR2I(MM(100 + x), MM(100 + y)))
    if rot is not None:
        fp.SetOrientationDegrees(rot)
    return fp


def rip_region(board, nets, box):
    """Remove tracks / vias of `nets` lying fully inside box (x0, y0, x1, y1) in board-relative mm."""
    x0, y0, x1, y1 = box

    def inside(p):
        return x0 <= TO(p.x) - 100 <= x1 and y0 <= TO(p.y) - 100 <= y1
    gone = [t for t in board.GetTracks() if t.GetNetname() in nets and inside(t.GetStart()) and inside(t.GetEnd())]
    n = len(gone)
    for t in gone:
        board.Delete(t)
    return n


def pads_of(board, ref):
    fp = board.FindFootprintByReference(ref)
    return [(p.GetNumber(), p.GetNetname(), round(TO(p.GetPosition().x) - 100, 3), round(TO(p.GetPosition().y) - 100, 3))
            for p in fp.Pads()]


def courtyard_poly(fp):
    from shapely.geometry import box as sbox
    layer = pcbnew.B_CrtYd if fp.IsFlipped() else pcbnew.F_CrtYd
    cy = fp.GetCourtyard(layer)
    g = rt.polyset_to_shapely(cy) if cy.OutlineCount() else None
    if g is None or g.is_empty:
        bb = fp.GetBoundingBox(False, False)
        g = sbox(TO(bb.GetLeft()), TO(bb.GetTop()), TO(bb.GetRight()), TO(bb.GetBottom()))
    return g


def courtyard_overlaps(board, refs):
    """Courtyard overlaps involving any of refs (same side only)."""
    board.BuildListOfNets()
    fps = list(board.GetFootprints())
    for fp in fps:
        fp.BuildCourtyardCaches()
    polys = {fp.GetReference(): (fp.IsFlipped(), courtyard_poly(fp)) for fp in fps}
    out = []
    for r in refs:
        side, g = polys[r]
        for o, (s2, g2) in polys.items():
            if o != r and s2 == side and g.intersection(g2).area > 1e-4:
                out.append((r, o, round(g.intersection(g2).area, 3)))
    return out


def zone(board, net, layer, pts, prio=2, clearance=0.2, name=""):
    """Solid (full pad connection) copper zone of `net`; pts board-relative mm."""
    z = pcbnew.ZONE(board)
    z.SetLayer(LAYER[layer])
    z.SetNet(board.FindNet(net))
    z.SetAssignedPriority(prio)
    z.SetLocalClearance(MM(clearance))
    z.SetMinThickness(MM(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    z.SetZoneName(name or f"{net}_{layer}")
    o = z.Outline()
    o.NewOutline()
    for x, y in pts:
        o.Append(MM(100 + x), MM(100 + y))
    board.Add(z)
    return z


def fill(board):
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())


def via_array(board, net, box, n, spacing=0.9, d=0.6, h=0.3, clr=0.15):
    """Greedy: up to n legal vias of `net` inside box (board-relative), >= spacing apart."""
    import router
    x0, y0, x1, y1 = box
    c = (100 + (x0 + x1) / 2, 100 + (y0 + y1) / 2)
    r = max(x1 - x0, y1 - y0)
    cand = [(xx, yy) for _, xx, yy in router.via_spots(board, net, c, r, clr=clr, via_d=d, via_h=h, grid=0.1)
            if x0 <= xx - 100 <= x1 and y0 <= yy - 100 <= y1]
    chosen = []
    for p in sorted(cand, key=lambda p: (p[0], p[1])):
        if all((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 >= spacing ** 2 for q in chosen):
            chosen.append(p)
            if len(chosen) >= n:
                break
    for p in chosen:
        add_via(board, net, p, d, h)
    return chosen


def prune_dangling(board, nets, tol=0.02):
    """Repeatedly delete tracks of `nets` with an end touching nothing of their net on their layer,
    and vias of `nets` touching no track / pad of the net. Returns the number deleted."""
    from shapely.geometry import Point, LineString
    total = 0
    # zero-length and duplicate segments keep each other "connected": drop them first
    seen, dup = set(), []
    for t in board.GetTracks():
        if t.GetNetname() not in nets or t.GetClass() == "PCB_VIA":
            continue
        a = (round(TO(t.GetStart().x), 3), round(TO(t.GetStart().y), 3))
        c = (round(TO(t.GetEnd().x), 3), round(TO(t.GetEnd().y), 3))
        key = (t.GetNetname(), t.GetLayer(), min(a, c), max(a, c))
        if a == c or key in seen:
            dup.append(t)
        seen.add(key)
    for t in dup:
        board.Delete(t)
    total += len(dup)
    while True:
        geo, _h = rt.geometry(board)
        items = [(l, g, k, o) for l, lst in geo.items() for (n, g, k, o) in lst if n in nets]
        dead = []
        for t in board.GetTracks():
            if t.GetNetname() not in nets:
                continue
            if t.GetClass() == "PCB_VIA":
                p = Point(TO(t.GetPosition().x), TO(t.GetPosition().y)).buffer(TO(t.GetWidth()) / 2)
                if not any(o is not t and o.GetNetname() == t.GetNetname() and k != "via" and g.intersects(p)
                           for l, g, k, o in items):
                    dead.append(t)
                continue
            for e in (t.GetStart(), t.GetEnd()):
                probe = Point(TO(e.x), TO(e.y)).buffer(tol)
                if not any(o.m_Uuid.AsString() != t.m_Uuid.AsString() and o.GetNetname() == t.GetNetname()
                           and (l == t.GetLayer() or k == "via") and g.intersects(probe) for l, g, k, o in items):
                    dead.append(t)
                    break
        if not dead:
            return total
        uu = {}
        for t in dead:
            uu[t.m_Uuid.AsString()] = t
        for t in uu.values():
            board.Delete(t)
        total += len(uu)


def rip_colliding(board, refs, clr=0.127):
    """Delete tracks / vias of other nets that now overlap (or violate clearance to) pads of refs."""
    geo, _h = rt.geometry(board)
    pads = []
    for r in refs:
        for p in board.FindFootprintByReference(r).Pads():
            for l in rt.CU:
                if p.IsOnLayer(l):
                    pads.append((l, p.GetNetname(), rt.pad_geom(p, l).buffer(clr)))
    dead = {}
    for l, lst in geo.items():
        for n, g, k, o in lst:
            if k not in ("track", "via"):
                continue
            for pl, pn, pg in pads:
                if pl == l and pn != n and g.intersects(pg):
                    dead[o.m_Uuid.AsString()] = o
                    break
    for o in dead.values():
        board.Delete(o)
    return len(dead)


def keepout(board, layer, pts, tracks=True, vias=False, name="keepout"):
    """Rule area on one layer (board-relative pts): forbids tracks (and optionally vias) of all nets;
    copper pours stay allowed."""
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    z.SetDoNotAllowTracks(tracks)
    z.SetDoNotAllowVias(vias)
    z.SetDoNotAllowPads(False)
    z.SetDoNotAllowFootprints(False)
    z.SetDoNotAllowCopperPour(False)
    z.SetLayer(LAYER[layer])
    z.SetZoneName(name)
    o = z.Outline()
    o.NewOutline()
    for x, y in pts:
        o.Append(MM(100 + x), MM(100 + y))
    board.Add(z)
    return z


def via_to_pour(board, net, pad_xy, radius=1.3, width=0.4):
    """Drop a via of `net` next to a pad (nearest legal spot) and route a short F stub to it."""
    import router
    for _, sx, sy in router.via_spots(board, net, pad_xy, radius):
        v = add_via(board, net, (sx, sy))
        try:
            r = router.route(board, net, (sx, sy), pad_xy, width=width, clr=0.15, grid=0.05, margin=1.0,
                             layers=[pcbnew.F_Cu])
        except AssertionError:
            r = []
        if r is not None:
            return (sx, sy)
        board.Delete(v)
    raise RuntimeError(f"via_to_pour {net} {pad_xy}: no spot")
