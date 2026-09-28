#!/usr/bin/env python3
"""Check a coordinate-level placement sketch (sketch.json) against PLAN.md, with real footprint sizes.

Input : fpdata.json (export_fp.py, real courtyards/pads at rot 0) + sketch.json (x, y, rot per ref).
Output: a pass/fail report on stdout + sketch.png. No pcbnew needed (runs on Windows or WSL).

Coordinates: HAT frame, origin top-left, y down, mm. Rotation = KiCad degrees (multiples of 90):
local (x, y) -> (x cos t + y sin t, -x sin t + y cos t), the same convention pcbnew uses.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BW, BH, EDGE = 65.0, 56.5, 0.5
CARD = (9.55, 18.4, 60.5, 48.4)
CARD_HMAX = 1.9
KEEPOUTS = {  # name: rect, applies to front parts and to copper on all layers
    "antenna": (0.0, 0.0, 6.3, 20.0),
    "J2 pins (THT, top-side solder)": (7.2, 0.4, 57.8, 6.1),
}
BACK_KEEPOUTS = {"PoE header": (58.0, 6.0, 64.0, 13.0), "antenna": (0.0, 0.0, 6.3, 20.0)}
NOT_UNDER_CARD = ("L1", "L2", "U3", "U7", "TP1", "TP2", "TP3", "TP4", "D2", "D3", "JP3", "J5", "J6")
HALOW_UFL = (11.5, 37.7)
GNSS_PTS = {"U14": (53.5, 11.9), "J4": (62.0, 12.0)}


def rot(x, y, deg):
    t = math.radians(deg)
    c, s = round(math.cos(t)), round(math.sin(t))
    return x * c + y * s, -x * s + y * c


def rect_rot(r, deg):
    xs, ys = zip(*(rot(x, y, deg) for x, y in ((r[0], r[1]), (r[2], r[3]))))
    return min(xs), min(ys), max(xs), max(ys)


def shift(r, x, y):
    return r[0] + x, r[1] + y, r[2] + x, r[3] + y


def overlap(a, b, tol=0.0):
    return a[0] < b[2] - tol and b[0] < a[2] - tol and a[1] < b[3] - tol and b[1] < a[3] - tol


def gap(a, b):
    dx = max(b[0] - a[2], a[0] - b[2], 0.0)
    dy = max(b[1] - a[3], a[1] - b[3], 0.0)
    return math.hypot(dx, dy)


def area(r):
    return max(0.0, r[2] - r[0]) * max(0.0, r[3] - r[1])


def inter(a, b):
    return (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))


class Board:
    def __init__(self, fpdata, sketch):
        self.fp = fpdata
        self.pos = {**sketch["fixed"], **sketch["place"]}
        self.sketch = sketch

    def cy(self, ref):
        x, y, r = self.pos[ref][:3]
        return shift(rect_rot(self.fp[ref]["cy"], r), x, y)

    def pads(self, ref, num=None):
        x, y, r = self.pos[ref][:3]
        out = []
        for p in self.fp[ref]["pads"]:
            if num is not None and p["n"] != str(num):
                continue
            cx, cy = rot(p["x"], p["y"], r)
            w, h = (p["w"], p["h"]) if r % 180 == 0 else (p["h"], p["w"])
            out.append((cx + x - w / 2, cy + y - h / 2, cx + x + w / 2, cy + y + h / 2))
        if not out:
            raise KeyError(f"{ref} pad {num}")
        # largest pad of that number (thermal-via children share the number)
        return max(out, key=area)

    def pad_centre(self, ref, num):
        r = self.pads(ref, num)
        return (r[0] + r[2]) / 2, (r[1] + r[3]) / 2


def ring_segments(ring):
    x0, y0, x1, y1 = ring["inner"]
    w = ring["w"]
    segs = [(x0 - w, y0 - w, x1 + w, y0), (x0 - w, y1, x1 + w, y1 + w), (x0 - w, y0, x0, y1), (x1, y0, x1 + w, y1)]
    out = []
    for sg in segs:  # cut the gaps out (gaps are rects; a segment is split along its long axis)
        pieces = [sg]
        for g in ring.get("gaps", []):
            nxt = []
            for p in pieces:
                if not overlap(p, g):
                    nxt.append(p)
                    continue
                if p[2] - p[0] >= p[3] - p[1]:
                    nxt += [q for q in ((p[0], p[1], g[0], p[3]), (g[2], p[1], p[2], p[3])) if q[2] - q[0] > 0.05]
                else:
                    nxt += [q for q in ((p[0], p[1], p[2], g[1]), (p[0], g[3], p[2], p[3])) if q[3] - q[1] > 0.05]
            pieces = nxt
        out += pieces
    return out


def main():
    fp = json.load(open(os.path.join(HERE, "fpdata.json")))
    sk = json.load(open(os.path.join(HERE, "sketch.json"), encoding="utf-8"))
    B = Board(fp, sk)
    fails, notes = [], []

    def check(ok, msg):
        (notes if ok else fails).append(("PASS " if ok else "FAIL ") + msg)

    placed = list(B.pos)
    front = [r for r in placed if not fp[r]["back"]]
    # 1. courtyard overlaps (front side)
    for i, a in enumerate(front):
        for b in front[i + 1:]:
            if overlap(B.cy(a), B.cy(b), tol=0.01):
                ov = area(inter(B.cy(a), B.cy(b)))
                check(False, f"courtyard overlap {a} x {b} ({ov:.2f} mm2)")
    # 2. board edge + keep-outs + card height
    for r in front:
        c = B.cy(r)
        if r in sk["fixed"]:
            continue
        if c[0] < EDGE or c[1] < EDGE or c[2] > BW - EDGE or c[3] > BH - EDGE:
            check(False, f"{r} courtyard beyond board edge - {EDGE} mm: {tuple(round(v, 2) for v in c)}")
        for name, k in KEEPOUTS.items():
            if overlap(c, k, tol=0.01):
                check(False, f"{r} in keep-out '{name}'")
        if overlap(c, CARD, tol=0.01):
            h = fp[r]["height"]
            if h > CARD_HMAX or r in NOT_UNDER_CARD:
                check(False, f"{r} under the card: height {h} mm / not allowed under card")
    # 2b. shield-frame pad rings (PLAN F3): a ring of GND pad around a buck; gaps let F-layer current cross.
    for ring in sk.get("rings", []):
        segs = ring_segments(ring)
        inner = tuple(ring["inner"])
        for r in ring["encloses"]:
            c = B.cy(r)
            if not (c[0] >= inner[0] - 0.01 and c[1] >= inner[1] - 0.01 and c[2] <= inner[2] + 0.01 and c[3] <= inner[3] + 0.01):
                check(False, f"ring {ring['id']}: {r} not inside the frame")
        for sg in segs:
            if overlap(sg, CARD, tol=0.01):
                check(False, f"ring {ring['id']}: frame pad under the card (frame is ~4 mm tall)")
            if sg[0] < EDGE or sg[1] < EDGE or sg[2] > BW - EDGE or sg[3] > BH - EDGE:
                check(False, f"ring {ring['id']}: frame pad beyond board edge")
            for r in front:
                if overlap(sg, B.cy(r), tol=0.01):
                    check(False, f"ring {ring['id']}: frame pad hits {r}")
        notes.append(f"PASS ring {ring['id']}: {sum(area(sg) for sg in segs):.0f} mm2 of frame pad, gaps {len(ring.get('gaps', []))}")
    # 3. distance rules
    for rule in sk["rules"]:
        kind, lim, label = rule["kind"], rule["max"] if "max" in rule else rule["min"], rule["id"]
        if kind == "pad":
            (ra, na), (rb, nb) = rule["a"], rule["b"]
            d = gap(B.pads(ra, na), B.pads(rb, nb))
        elif kind == "centre":
            (ra, na), (rb, nb) = rule["a"], rule["b"]
            pa = B.pad_centre(ra, na) if na else ((B.cy(ra)[0] + B.cy(ra)[2]) / 2, (B.cy(ra)[1] + B.cy(ra)[3]) / 2)
            pb = B.pad_centre(rb, nb) if nb else ((B.cy(rb)[0] + B.cy(rb)[2]) / 2, (B.cy(rb)[1] + B.cy(rb)[3]) / 2)
            d = math.dist(pa, pb)
        elif kind == "point":
            (ra, na), pt = rule["a"], rule["pt"]
            p = B.pads(ra, na)
            d = gap(p, (pt[0], pt[1], pt[0], pt[1]))
        else:
            raise SystemExit(f"unknown rule kind {kind}")
        ok = d <= lim if "max" in rule else d >= lim
        check(ok, f"{label}: {d:.2f} mm ({'<=' if 'max' in rule else '>='} {lim}) {rule.get('what', '')}")
    # 4. zones for parts not yet placed individually
    for name, z in sk["zones"].items():
        zr = tuple(z["rect"])
        free = area(zr)
        for r in ([] if z.get("back") else front):
            if r in sk["zones"][name].get("parts", []):
                continue
            free -= area(inter(zr, B.cy(r)))
        need = sum(area(rect_rot(fp[r]["cy"], 0)) for r in z["parts"])
        fill = need / free if free > 0 else 9.9
        lim = z.get("max_fill", 0.65)
        check(fill <= lim, f"zone {name}: {len(z['parts'])} parts need {need:.0f} mm2 of {free:.0f} mm2 free = {fill:.0%} (limit {lim:.0%})")
    # 5. fill of the individually placed regions
    for name, rr in sk.get("regions", {}).items():
        used = sum(area(inter(tuple(rr), B.cy(r))) for r in front if r not in sk["fixed"])
        notes.append(f"INFO region {name}: courtyard fill {used / area(tuple(rr)):.0%} of {area(tuple(rr)):.0f} mm2")
    unplaced = sorted(set(fp) - set(B.pos) - {p for z in sk["zones"].values() for p in z["parts"]})
    check(not unplaced, f"every footprint placed or zoned (missing: {', '.join(unplaced) or 'none'})")
    for line in fails + notes:
        print(line)
    print(f"\n{len(fails)} FAIL, {sum(1 for n in notes if n.startswith('PASS'))} PASS")
    draw(B, sk)
    return 1 if fails else 0


def draw(B, sk):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle
    fig, ax = plt.subplots(figsize=(13, 11.3))
    ax.add_patch(Rectangle((0, 0), BW, BH, fill=False, lw=2))
    ax.add_patch(Rectangle(CARD[:2], CARD[2] - CARD[0], CARD[3] - CARD[1], fill=False, ls="--", ec="#666"))
    for name, k in KEEPOUTS.items():
        ax.add_patch(Rectangle(k[:2], k[2] - k[0], k[3] - k[1], color="#d62728", alpha=0.10))
    for name, z in sk["zones"].items():
        r = z["rect"]
        ax.add_patch(Rectangle(r[:2], r[2] - r[0], r[3] - r[1], fill=False, ec="#9467bd", ls=":", lw=1.2))
        ax.text(r[0] + 0.3, r[1] + 0.9, name, fontsize=6, color="#9467bd")
    colours = {"power_in": "#8c564b", "power_5v": "#ff7f0e", "power_3v3": "#2ca02c", "softpower": "#e377c2",
               "halow": "#17becf", "security": "#9467bd", "gnss": "#1f77b4", "debug": "#7f7f7f", "pi_header": "#000"}
    netc = {"VBAT_RAW": "#d62728", "EF_IN": "#d62728", "EF_OUT": "#d62728", "VSYS": "#ff7f0e", "SW_5V": "#000",
            "SW_3V3": "#000", "5V_BUCK": "#bcbd22", "5V_PI": "#e377c2", "3V3_BUCK": "#2ca02c", "3V3_SH": "#2ca02c",
            "3V3_MPCIE": "#17becf", "GND": "#aaaaaa"}
    for ref in B.pos:
        if B.fp[ref]["back"]:
            continue
        c = B.cy(ref)
        col = colours.get(B.fp[ref]["sheet"], "#333")
        ax.add_patch(Rectangle(c[:2], c[2] - c[0], c[3] - c[1], fill=False, ec=col, lw=0.8))
        x, y, r = B.pos[ref][:3]
        for p in B.fp[ref]["pads"]:
            cx, cy = rot(p["x"], p["y"], r)
            w, h = (p["w"], p["h"]) if r % 180 == 0 else (p["h"], p["w"])
            if w * h < 0.3 and p["th"]:
                continue
            ax.add_patch(Rectangle((cx + x - w / 2, cy + y - h / 2), w, h, color=netc.get(p["net"], "#cccccc"),
                                   alpha=0.85, lw=0))
        ax.text((c[0] + c[2]) / 2, (c[1] + c[3]) / 2, ref, fontsize=5.5, ha="center", va="center")
    for ring in sk.get("rings", []):
        for sg in ring_segments(ring):
            ax.add_patch(Rectangle(sg[:2], sg[2] - sg[0], sg[3] - sg[1], color="#555", alpha=0.6, lw=0))
    ax.plot(*HALOW_UFL, marker="*", ms=14, color="#d62728", mec="k")
    ax.plot(62, 12, marker="*", ms=14, color="#1f77b4", mec="k")
    ax.set_xlim(-0.5, BW + 0.5)
    ax.set_ylim(BH + 0.5, -0.5)
    ax.set_aspect("equal")
    ax.set_title("layout v2 sketch (real courtyards/pads; zones dotted)", fontsize=10)
    fig.tight_layout()
    fig.savefig(os.path.join(HERE, "sketch.png"), dpi=120)


if __name__ == "__main__":
    sys.exit(main())
