#!/usr/bin/env python3
"""G2 preview on the escape board (run in WSL with KiCad 7 pcbnew): is the current placement routable?

  export : copy escape.kicad_pcb -> frprev/frprev.kicad_pcb, keep only the planned power copper
           (escape.json routes / hand tracks / vias / pours / GND vias), strip every other signal
           track the greedy router left, export Specctra DSN (In1 = GND power layer).
  import : load frprev.kicad_pcb, import the Freerouting .ses, refill, KiCad DRC, report the nets
           still unconnected. Writes frprev/frprev-<tag>.kicad_pcb and frprev/drc-<tag>.rpt.
escape.kicad_pcb, sketch.json and the main board are only read.
"""
import collections
import json
import os
import re
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
HAT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HAT, "gen"))
OUT = os.path.join(HERE, "frprev")
BRD = os.path.join(OUT, "frprev.kicad_pcb")


def planned_nets(es):
    nets = {"GND"}
    nets |= {r["net"] for r in es.get("routes", [])}
    nets |= {p["net"] for p in es.get("pours", [])}
    nets |= {t["net"] for t in es.get("tracks", [])}
    nets |= {v["net"] for v in es.get("vias", [])}
    return nets


def export():
    os.makedirs(OUT, exist_ok=True)
    es = json.load(open(os.path.join(HERE, "escape.json"), encoding="utf-8"))
    keep = planned_nets(es)
    board = pcbnew.LoadBoard(os.path.join(HERE, "escape.kicad_pcb"))
    items = [t for t in board.GetTracks() if t.GetNetname() not in keep]
    stripped = collections.Counter(t.GetNetname() for t in items)
    for t in items:
        board.Delete(t)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.Save(BRD)
    board = pcbnew.LoadBoard(BRD)
    dsn = os.path.join(OUT, "frprev.dsn")
    ok = pcbnew.ExportSpecctraDSN(board, dsn)
    txt = open(dsn).read()
    txt = txt.replace("(layer In1.Cu\n      (type signal)", "(layer In1.Cu\n      (type power)")
    open(dsn, "w").write(txt)
    print("kept planned nets:", len(keep), "| stripped signal nets:", len(stripped), "items:", sum(stripped.values()))
    print("DSN:", dsn, "export ok:", ok)
    print("DSN planes:", len(re.findall(r"\(plane ", txt)), "keepouts:", len(re.findall(r"\(keepout ", txt)),
          "wires kept:", len(re.findall(r"\(wire ", txt)), "vias kept:", len(re.findall(r"\(via ", txt)))


def unconnected_nets(rpt):
    nets = collections.Counter()
    txt = open(rpt).read()
    for block in re.split(r"\n(?=\[)", txt):
        if block.startswith("[unconnected_items]"):
            found = re.findall(r"\[([^\]]+)\] of", block) or re.findall(r"\[([A-Za-z0-9_+\-]+)\]", block.split("\n", 1)[-1])
            if found:
                nets[found[0]] += 1
    return txt, nets


def do_import(tag, ses):
    import layout as L
    board = pcbnew.LoadBoard(BRD)
    n_tr, n_via = L.import_ses(board, ses)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    out = os.path.join(OUT, f"frprev-{tag}.kicad_pcb")
    rpt = os.path.join(OUT, f"drc-{tag}.rpt")
    board.Save(out)
    pcbnew.WriteDRCReport(board, rpt, pcbnew.EDA_UNITS_MILLIMETRES, True)
    txt, nets = unconnected_nets(rpt)
    cats = collections.Counter(re.findall(r"^\[(\w+)\]", txt, re.M))
    print(f"[{tag}] imported tracks {n_tr}, vias {n_via}")
    print(f"[{tag}] DRC:", {k: v for k, v in cats.items() if not k.startswith(("silk", "lib_"))})
    print(f"[{tag}] unconnected by net:", dict(nets.most_common()) or "none")


if __name__ == "__main__":
    if sys.argv[1] == "export":
        export()
    else:
        do_import(sys.argv[2], sys.argv[3])
