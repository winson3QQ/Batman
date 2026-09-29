"""Replayable routing close-out for HAT v1 (local take-over of PR #222, 2026-09-28).

cloud baseline board (commit 8041361, 10 unconnected) -> hand edits for the short breaks ->
input-stage re-place (eFuse U1 rotated, B-FET Q1 rotated, power pours, hand lanes for U1's
fixed pin order) -> refill -> DRC. The remaining connections are then routed by Freerouting;
run.sh drives the whole chain. See README.md in this folder.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pcbnew  # noqa: E402

import ops  # noqa: E402
import router  # noqa: E402
import rt  # noqa: E402

BASE = os.environ.get("HAT_BASE", os.path.join(os.path.dirname(rt.PCB), "out", "route", "baseline.kicad_pcb"))


def R(b, net, src, dst, **kw):
    r = router.route(b, net, src, dst, **kw)
    if r is None:
        raise SystemExit(f"NO ROUTE {net} {src} -> {dst}")
    print(f"  routed {net}: {sum(1 for x in r if x.GetClass() == 'PCB_VIA')} vias, "
          f"{sum(1 for x in r if x.GetClass() != 'PCB_VIA')} segs")
    return r


def spi1_sclk(b):
    """U11.19 is boxed in by the TPM_CS_N / TPM_PIRQ_N via column; C16.2's GND via sits on the only
    spot for a layer change. Shift CS_N via 0.13 right / 0.29 up, move the GND via off, route."""
    ops.move_via(b, "TPM_CS_N", (149.973, 125.866), (150.05, 125.62))
    # In2 CS_N used to drop straight down onto the via: keep it vertical, jog at the end
    ops.set_track_end(b, "TPM_CS_N", "In2", (150.05, 125.62), (149.973, 125.47))
    ops.add_track(b, "TPM_CS_N", "In2", [(149.973, 125.47), (150.05, 125.62)])
    # F: pad -> horizontal -> diagonal up onto the via
    ops.set_track_end(b, "TPM_CS_N", "F", (150.05, 125.62), (149.80, 125.866))
    ops.add_track(b, "TPM_CS_N", "F", [(149.80, 125.866), (150.05, 125.62)])
    ops.remove_via(b, "GND", (150.98, 126.7))
    ops.add_via(b, "SPI1_SCLK", (150.98, 126.55))
    R(b, "SPI1_SCLK", (149.345, 126.336), (150.98, 126.55), width=0.15, clr=0.14, grid=0.025,
      layers=[pcbnew.F_Cu])
    R(b, "SPI1_SCLK", (150.98, 126.55), (152.72, 127.412), width=0.2, clr=0.15, grid=0.025,
      layers=[pcbnew.B_Cu])
    # C16.2 (5 V bulk cap GND) lost its via: new one below-left, short F stub to the pad
    ops.add_via(b, "GND", (150.08, 128.70))
    R(b, "GND", (150.08, 128.70), (150.98, 127.75), width=0.3, clr=0.15, grid=0.025, layers=[pcbnew.F_Cu])


def j5_gnd(b):
    """Tag-Connect J5.3 (GND) sat in a pour fragment fenced in by the TC_* tracks: route it out."""
    # only legal spot in the pocket: a 0.5/0.25 via between J5.2 and J5.3 (tented), short F stub
    ops.add_via(b, "GND", (138.70, 110.05), d=0.5, h=0.25)
    R(b, "GND", (138.70, 110.05), (139.3, 109.65), width=0.2, clr=0.13, grid=0.025, layers=[pcbnew.F_Cu])


def buck5(b):
    """Short breaks left by rip-up / reroute around the 5 V buck U3."""
    R(b, "VCC_5V", (123.44, 110.72), (118.5, 113.765), width=0.2, clr=0.13, grid=0.025, via_cost=40)
    R(b, "5V_BUCK", (126.43, 110.71), (125.453, 109.296), width=0.2, clr=0.15, grid=0.025)
    R(b, "PG_5V", (123.9, 112.495), (120.03, 127.39), width=0.2, clr=0.15, grid=0.05, margin=2.0)


def halow_reset(b):
    """HALOW_RESET_N (J2.11 GPIO -> J3.22 PERST#) was left as two dead-end stubs after rip-up.
    Rip both and route pin to pin over the whole lower-right region."""
    print("  ripped", ops.rip_group(b, "HALOW_RESET_N", (122.778, 111.216)),
          ops.rip_group(b, "HALOW_RESET_N", (128.3542, 130.7892)))
    R(b, "HALOW_RESET_N", (121.07, 104.77), (154.9, 133.6), width=0.2, clr=0.15, grid=0.05,
      window=(112, 100.5, 160, 142), via_cost=30)

# ------------------------------------------------------------------ input stage re-place (option A)
IN_PLACE = {  # ref: (x, y, rot), board-relative mm
    "U1": (3.6, 22.3, 90),    # IN pins 1-2 face Q1 below, OUT 17-18 face R9 above, NC 19-24 face the edge
    "Q1": (2.3, 34.3, 90),    # source pins 1-3 face D1 / battery, drain + tab face U1
    "Q2": (6.3, 34.3, 0),
    "C9": (0.62, 25.9, 270), # 100 nF at the IN pins
    "R9": (2.6, 16.0, 0), "C6": (10.5, 16.35, 90), "R6": (5.3, 18.3, 180),
    "C1": (7.0, 28.4, 0),
    "C33": (10.5, 34.6, 90), "C8": (10.5, 39.5, 270), "R19": (13.3, 37.5, 90),    # hot-plug damper: VD pads face each other
}
IN_RIP = {"EF_IN", "VBAT_RAW", "VBAT_DAMP", "EF_BGATE", "EF_DRV", "EF_UVLO", "EF_OVP", "EF_DVDT",
          "EF_ILIM", "EF_SHDN", "EF_FLT_N", "EF_PGTH", "EN_5V", "EF_OUT", "VSYS", "GND"}
IN_BOX = (0, 14.2, 12.6, 41.2)


def input_stage(b):
    for r, (x, y, a) in IN_PLACE.items():
        ops.place(b, r, x, y, a)
    print("  ripped", ops.rip_region(b, IN_RIP, IN_BOX),
          ops.rip_region(b, IN_RIP - {"GND", "VSYS", "EF_OUT", "EN_5V", "EF_PGTH", "EF_FLT_N"}, (0, 24.0, 17.0, 41.2)))
    print("  ripped (collide with moved parts)", ops.rip_colliding(b, [r for r in IN_PLACE]))
    ov = ops.courtyard_overlaps(b, list(IN_PLACE))
    assert not ov, ov
    # main current path: J1 -> D1 -> Q1 source (F pour) | Q1 drain -> U1 IN 1-2 (F pour) | OUT -> R9
    ops.zone(b, "VBAT_RAW", "F", [(0.5, 35.3), (2.95, 35.3), (2.95, 36.4), (3.4, 36.7), (3.4, 42.0), (0.5, 42.0)])
    # C9 (100 nF at the IN pins) sits at the edge: its GND pad gets a via before the EF_IN pour
    # is laid, and the pour leaves a notch below C9.1 for it
    print("  C9.2 GND via:", ops.via_to_pour(b, "GND", (100.62, 126.38), radius=1.2, width=0.3))
    ops.zone(b, "EF_IN", "F", [(0.5, 24.0), (3.05, 24.0), (3.05, 32.4), (3.6, 32.4), (3.6, 33.3), (1.35, 33.3),
                               (1.35, 25.75), (0.5, 25.75)])
    ops.zone(b, "EF_OUT", "F", [(0.5, 15.0), (2.05, 15.0), (2.05, 18.9), (2.95, 19.5), (2.95, 20.25), (0.5, 20.25)])
    ops.fill(b)
    # U1 bottom row (pins 3-6) has a fixed left-to-right order: hand-drawn lanes, router for the rest
    T = lambda net, pts, w=0.2, layer="F": ops.add_track(b, net, layer, [(100 + x, 100 + y) for x, y in pts], w)
    T("EF_BGATE", [(3.35, 24.263), (3.35, 31.9), (3.85, 32.4), (3.85, 35.74), (3.27, 35.74)], 0.25)
    T("EF_BGATE", [(3.85, 35.74), (3.85, 36.35), (8.3, 36.35), (8.3, 34.3), (7.237, 34.3)], 0.25)
    T("EF_DRV", [(3.85, 24.263), (3.85, 25.0), (4.3, 25.45), (4.3, 33.35), (5.362, 33.35)])
    T("VBAT_RAW", [(4.35, 24.263), (4.35, 24.95), (4.8, 25.4), (4.8, 28.4), (6.05, 28.4)])
    T("EF_UVLO", [(4.85, 24.263), (4.85, 24.45), (5.4, 24.45), (5.4, 26.6), (8.8, 26.6)])
    # U1 top row: EN_5V drops through a via under R9's body, PGTH up to R6, FLT_N over pin 13 to a via
    T("EN_5V", [(3.35, 20.338), (3.35, 18.2), (3.0, 17.85), (3.0, 16.8)])
    ops.add_via(b, "EN_5V", (103.0, 116.8))    # clear of TP20 / TP27 on the back
    T("EF_PGTH", [(3.85, 20.338), (3.85, 19.1), (4.79, 18.3)])
    T("EF_FLT_N", [(4.35, 20.338), (4.35, 19.62), (5.8, 19.62)])
    ops.add_via(b, "EF_FLT_N", (105.8, 119.62))
    # VBAT_RAW distribution (Q2, IN_SYS, C1, damper, dividers) on an In2 pour fed from the F pour
    print("  VBAT_RAW F->In2 vias", ops.via_array(b, "VBAT_RAW", (0.6, 36.9, 3.3, 41.3), 6))
    in2 = [(3.8, 27.6), (9.0, 27.6), (9.0, 41.0), (0.6, 41.0), (0.6, 35.0), (3.8, 35.0)]   # x 9-12.6 left free for U1 control lines
    ops.zone(b, "VBAT_RAW", "In2", in2)
    ops.keepout(b, "In2", in2, name="VBAT_RAW_In2_pour_keep_tracks_out")   # the router must not split it
    ops.fill(b)
    # Q2 source and C1 (IN_SYS decoupling) join the In2 pour through their own via
    print("  VBAT_RAW vias at Q2.2 / C1.1:", ops.via_to_pour(b, "VBAT_RAW", (105.362, 135.25)),
          ops.via_to_pour(b, "VBAT_RAW", (106.05, 128.4)))
    ops.fill(b)
    # every remaining connection of these nets is left to Freerouting (run.sh)


STEPS = [spi1_sclk, j5_gnd, buck5, halow_reset, input_stage]

if __name__ == "__main__":
    upto = int(sys.argv[1]) if len(sys.argv) > 1 else len(STEPS)
    OUT = os.environ.get("HAT_OUT", rt.PCB)
    shutil.copyfile(BASE, OUT)
    b = pcbnew.LoadBoard(OUT)
    try:
        for s in STEPS[:upto]:
            print(s.__name__)
            s(b)
    except Exception as e:
        print("FAILED:", e)
        ops.fill(b)
        b.Save(OUT)
        rt.render(b, (100, 113, 117, 143), set(IN_RIP) - {"GND"},
                  os.path.join(os.path.dirname(rt.PCB), "out", "route", "fail.png"), title="fail")
        sys.exit(1)
    print(router.refill_and_drc(b, OUT, os.path.join(os.path.dirname(rt.PCB), "out", "route", "drc-closeout.txt")))
