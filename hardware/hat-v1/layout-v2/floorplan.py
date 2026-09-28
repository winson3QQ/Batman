#!/usr/bin/env python3
"""Draw the layout-v2 zone plan (PLAN.md section 2) over the fixed mechanics -> floorplan-A.png.

Pure matplotlib, no pcbnew: this is a planning picture, not a placement.
Coordinates are HAT coordinates (origin top-left, y down, mm).
"""
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Circle, Rectangle  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
BW, BH = 65.0, 56.5
CARD = (9.55, 18.4, 60.5, 48.4)

# (name, x0, y0, x1, y1, colour, label)
ZONES = [
    ("Z0", 0, 0, 6.3, 20, "#d62728", "Z0 antenna strip\n(keep-out, all layers)"),
    ("Z1", 6.5, 6.5, 26, 18.4, "#ff7f0e", "Z1 5 V stage\nU3 L1 Q3 U4 U2"),
    ("Z2", 0, 20, 8, 48, "#8c564b", "Z2\ninput\nQ1\nU1\nR9"),
    ("Z2b", 0, 48, 20, 56.5, "#8c564b", "Z2b J1 D1"),
    ("Z2c", 9.6, 30, 14, 40, "#bcbd22", "Z2c\ndiv"),
    ("Z3", 30, 48.5, 58, 56, "#2ca02c", "Z3 3.3 V stage  U7 L2 R22 U8 FB1"),
    ("Z3b", 46, 36, 54, 48, "#98df8a", "Z3b\nbulk\ncaps"),
    ("Z4", 44, 6.5, 65, 18, "#1f77b4", "Z4 GNSS (fixed)"),
    ("Z5", 38, 19, 54, 30, "#9467bd", "Z5 TPM RTC\n(under card)"),
    ("Z56", 26, 6.5, 44, 18, "#7f7f7f", "Z5b ATECC / Z6 soft-power\n/ Z7 Tag-Connect, clips"),
    ("Z8", 20, 49, 30, 56.5, "#e377c2", "Z8 J6\n+clips"),
]


def main():
    fig, ax = plt.subplots(figsize=(10, 8.8))
    ax.add_patch(Rectangle((0, 0), BW, BH, fill=False, lw=2, ec="k"))
    ax.add_patch(Rectangle((CARD[0], CARD[1]), CARD[2] - CARD[0], CARD[3] - CARD[1],
                           fill=False, lw=1.5, ls="--", ec="#555"))
    ax.text(30, 47.2, "HaLow card outline (under: passives <=1.9 mm, chips <=1.0 mm)",
            fontsize=7, color="#555", ha="center")
    # 40-pin header (bottom side), pins 2/4 = 5V
    for i in range(20):
        for row, y in ((0, 4.77), (1, 2.23)):
            x = 8.37 + i * 2.54
            pin = 2 * i + 1 + row
            ax.add_patch(Circle((x, y), 0.5, color="#d62728" if pin in (2, 4) else "#999"))
    ax.text(32, 0.9, "J2 40-pin (5V = pins 2/4, red)", fontsize=7, ha="center")
    # mPCIe socket and its 3.3 V pins
    ax.add_patch(Rectangle((54.0, 18.4), 10.0, 30.0, fill=False, ec="#333", lw=1))
    for x, y in ((54.9, 44.8), (54.9, 32.8), (54.9, 21.6), (63.1, 26.8), (63.1, 26.0)):
        ax.add_patch(Circle((x, y), 0.5, color="#2ca02c"))
    ax.text(59, 33, "J3\nmPCIe\n(3V3 pins\ngreen)", fontsize=7, ha="center")
    # mounting holes + card standoffs
    for x, y in ((3.5, 3.5), (61.5, 3.5), (3.5, 52.5), (61.5, 52.5), (10.96, 45.5), (10.96, 21.3)):
        ax.add_patch(Circle((x, y), 2.9, fill=False, ec="k", lw=1))
    # Pi 4 features under the HAT (from the Pi 4 mechanical drawing, pixel-measured)
    ax.add_patch(Rectangle((6.3, 6.4), 10.5, 13.2, fill=False, ec="#d62728", ls=":", lw=1.2))
    ax.text(11.5, 19.2, "Pi4 WiFi can", fontsize=6, color="#d62728", ha="center")
    ax.add_patch(Rectangle((58, 6), 6, 7, fill=False, ec="#1f77b4", ls=":", lw=1.2))
    ax.text(61, 14.5, "Pi4 PoE hdr\n(no back parts)", fontsize=6, color="#1f77b4", ha="center")
    for _, x0, y0, x1, y1, c, lab in ZONES:
        ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, color=c, alpha=0.22))
        ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, ec=c, lw=1.2))
        ax.text((x0 + x1) / 2, (y0 + y1) / 2, lab, fontsize=7, ha="center", va="center")
    # main current flow
    flow = [(3, 46), (3, 36), (3, 26), (5, 21), (12, 16), (18, 12), (11, 7), (10, 2.3)]
    ax.annotate("", xy=flow[-1], xytext=flow[0])
    xs, ys = zip(*flow)
    ax.plot(xs, ys, color="#d62728", lw=3, alpha=0.7)
    ax.text(0.8, 40, "3.5 A", fontsize=7, color="#d62728", rotation=90)
    ax.plot([14, 30, 48], [12, 46, 50], color="#ff7f0e", lw=2, ls="--", alpha=0.8)
    ax.text(26, 32, "5V_PI <=1 A on In2", fontsize=7, color="#ff7f0e", rotation=-62)
    ax.plot([50, 55, 55], [50, 47, 44.8], color="#2ca02c", lw=2, alpha=0.8)
    # antenna connectors: HaLow card U.FL (user photo, +-2 mm) and GNSS J4 (fixed)
    for (x, y), lab, c in (((11.5, 37.7), "HaLow U.FL\n(on card)", "#d62728"), ((62.0, 12.0), "GNSS\nU.FL J4", "#1f77b4")):
        ax.plot(x, y, marker="*", ms=16, color=c, mec="k")
        ax.text(x + 1.2, y + 1.8, lab, fontsize=7, color=c, weight="bold")
    ax.plot(15, 12, marker="x", ms=10, mew=2.5, color="k")
    ax.text(15.8, 10.2, "SW node", fontsize=6)
    ax.set_xlim(-1, BW + 1)
    ax.set_ylim(BH + 1, -1)
    ax.set_aspect("equal")
    ax.set_title("Batman HAT v1 - layout v2 plan A (zones, not placement)", fontsize=10)
    fig.tight_layout()
    fig.savefig(os.path.join(HERE, "floorplan-A.png"), dpi=130)


if __name__ == "__main__":
    main()
