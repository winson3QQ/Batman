#!/usr/bin/env python3
"""Draft BOM from design.py (grouped by value + footprint + MPN).

This is the M2 draft: LCSC numbers are still mostly empty and get filled
in the M3 BOM step. Tier A parts are marked "fit in Taiwan" (spec 5.9).
"""
import csv
import os
import re
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(__file__))
import design as D  # noqa: E402

OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "out"))


def refkey(r):
    m = re.match(r"([A-Z#]+)(\d+)", r)
    return (m.group(1), int(m.group(2))) if m else (r, 0)


def main():
    groups = OrderedDict()
    for p in sorted(D.PARTS, key=lambda p: refkey(p.ref)):
        if p.ref.startswith("#") or p.sym in ("TP", "MH") and not p.mpn and p.fp.startswith(("TestPoint:TestPoint_Pad", "MountingHole")):
            continue
        k = (p.value, p.fp, p.mpn, p.dnp)
        g = groups.setdefault(k, dict(refs=[], p=p))
        g["refs"].append(p.ref)
    rows = []
    for (value, fp, mpn, dnp), g in groups.items():
        p = g["p"]
        assembly = "DNP" if dnp else ("fit in Taiwan (Tier A)" if p.tier == "A" else "JLCPCB")
        rows.append(dict(Refs=",".join(g["refs"]), Qty=len(g["refs"]), Value=value,
                         Footprint=fp.split(":")[-1], MPN=mpn, Manufacturer=p.mfr, Tier=p.tier,
                         LCSC=p.lcsc, Assembly=assembly, Note=p.note))
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "bom-draft.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    n = sum(r["Qty"] for r in rows)
    print(f"{len(rows)} lines, {n} placed parts -> out/bom-draft.csv")


if __name__ == "__main__":
    main()
