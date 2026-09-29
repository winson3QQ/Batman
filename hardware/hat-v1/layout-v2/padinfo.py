#!/usr/bin/env python3
"""Print world pad rectangles (x0, y0, x1, y1, net) of refs in sketch.json -- a helper for planning escapes."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sketch import Board, rot  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    fp = json.load(open(os.path.join(HERE, "fpdata.json")))
    sk = json.load(open(os.path.join(HERE, "sketch.json"), encoding="utf-8"))
    B = Board(fp, sk)
    for ref in sys.argv[1:]:
        x, y, r = B.pos[ref][:3]
        c = B.cy(ref)
        print(f"## {ref} at ({x},{y}) rot {r}  courtyard {tuple(round(v, 2) for v in c)}")
        seen = set()
        for p in fp[ref]["pads"]:
            if (p["n"], p["net"]) in seen and p["th"]:
                continue
            seen.add((p["n"], p["net"]))
            cx, cy = rot(p["x"], p["y"], r)
            w, h = (p["w"], p["h"]) if r % 180 == 0 else (p["h"], p["w"])
            print(f"   {p['n']:>3} {p['net']:<14} x {cx + x - w / 2:6.2f}-{cx + x + w / 2:6.2f}  y {cy + y - h / 2:6.2f}-{cy + y + h / 2:6.2f}")


if __name__ == "__main__":
    main()
