"""Post-route clean-up on the board finish() just wrote: solid EP-via connections, then delete the
items KiCad's DRC reports as dangling -- one at a time, kept deleted only if KiCad's own
connectivity says the unconnected count did not go up. Ends with a DRC report."""
import collections
import re
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pcbnew  # noqa: E402

import ops  # noqa: E402
import rt  # noqa: E402

RPT = os.path.join(os.path.dirname(rt.PCB), "out", "route", "drc.txt")


def drc(b):
    pcbnew.WriteDRCReport(b, RPT, pcbnew.EDA_UNITS_MILLIMETRES, True)
    return open(RPT).read()


def unconnected(b):
    b.BuildConnectivity()
    return b.GetConnectivity().GetUnconnectedCount(True)


def dangling_items(b, txt):
    """(kind, net, x, y) of every track_dangling / via_dangling entry."""
    out = []
    for m in re.finditer(r"^\[(track|via)_dangling\].*?\n.*?\n\s+@\((\S+) mm, (\S+) mm\): (Track|Via) \[([^\]]+)\]",
                         txt, re.M):
        out.append((m.group(1), m.group(5), float(m.group(2)), float(m.group(3))))
    return out


def find(b, kind, net, x, y):
    for t in b.GetTracks():
        if t.GetNetname() != net or (t.GetClass() == "PCB_VIA") != (kind == "via"):
            continue
        pts = [t.GetPosition()] if kind == "via" else [t.GetStart(), t.GetEnd()]
        if any(abs(rt.TO(p.x) - x) < 0.002 and abs(rt.TO(p.y) - y) < 0.002 for p in pts):
            return t
    return None


b = pcbnew.LoadBoard(rt.PCB)
n = 0
for ref, num in (("U1", "25"), ("J2", "25")):
    for p in b.FindFootprintByReference(ref).Pads():
        if p.GetNumber() == num:
            p.SetZoneConnection(pcbnew.ZONE_CONNECTION_FULL)
            n += 1
print("solid zone connection on pads:", n)
ops.fill(b)

base = unconnected(b)
removed = kept = 0
for _ in range(6):
    items = dangling_items(b, drc(b))
    progress = False
    for kind, net, x, y in items:
        t = find(b, kind, net, x, y)
        if t is None:
            continue
        clone = t.Duplicate()
        b.Delete(t)
        if unconnected(b) > base:
            b.Add(clone)          # it was carrying a connection after all
            kept += 1
        else:
            removed += 1
            progress = True
    if not progress:
        break
print(f"dangling items removed: {removed}, kept (would disconnect): {kept}, unconnected before/after: "
      f"{base}/{unconnected(b)}")
ops.fill(b)
b.Save(rt.PCB)
b = pcbnew.LoadBoard(rt.PCB)
txt = drc(b)
for line in txt.splitlines():
    if line.startswith("** Found"):
        print(line)
print({k: v for k, v in collections.Counter(re.findall(r"^\[(\w+)\]", txt, re.M)).items()
       if not k.startswith(("silk", "lib_"))})
