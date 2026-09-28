#!/usr/bin/env python3
"""Export every footprint's courtyard box, pads and height (at rot 0, origin 0,0) -> fpdata.json.

Run in WSL with KiCad 7's pcbnew. The board file is only read (never saved).
sketch.py uses this so the layout plan is checked with real sizes, without pcbnew.
"""
import json
import os
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
HAT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HAT, "gen"))
import design as D  # noqa: E402
import gen_pcb as G  # noqa: E402


def mm(v):
    return round(pcbnew.ToMM(v), 3)


def main():
    board = pcbnew.LoadBoard(os.path.join(HAT, "batman-hat.kicad_pcb"))
    sheet = {p.ref: p.sheet for p in D.PARTS}
    out = {}
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        flipped = fp.IsFlipped()
        fp.SetOrientationDegrees(0)
        fp.SetPosition(pcbnew.VECTOR2I(0, 0))
        cy = G.courtyard(fp)
        pads = []
        for pad in fp.Pads():
            pos, size = pad.GetPosition(), pad.GetSize()
            pads.append({"n": pad.GetNumber(), "net": pad.GetNetname(),
                         "x": mm(pos.x), "y": mm(pos.y), "w": mm(size.x), "h": mm(size.y),
                         "th": pad.GetAttribute() == pcbnew.PAD_ATTRIB_PTH})
        name = str(fp.GetFPID().GetLibItemName())
        out[ref] = {"fp": name, "value": fp.GetValue(), "sheet": sheet.get(ref, "?"),
                    "back": flipped, "height": G.height(name),
                    "cy": [mm(cy.GetLeft()), mm(cy.GetTop()), mm(cy.GetRight()), mm(cy.GetBottom())],
                    "pads": pads}
    for part in D.PARTS:   # parts added to design.py after the board was generated (e.g. C34)
        if part.ref.startswith("#") or part.ref in out:
            continue
        name = part.fp.split(":")[1]
        src = next(f for f in board.GetFootprints() if str(f.GetFPID().GetLibItemName()) == name)
        fp = src.Duplicate()   # FootprintLoad segfaults after LoadBoard here; clone a same-footprint part
        fp.SetOrientationDegrees(0)
        fp.SetPosition(pcbnew.VECTOR2I(0, 0))
        cy = G.courtyard(fp)
        pads = []
        for pad in fp.Pads():
            pos, size = pad.GetPosition(), pad.GetSize()
            pads.append({"n": pad.GetNumber(), "net": part.pins.get(pad.GetNumber(), ""),
                         "x": mm(pos.x), "y": mm(pos.y), "w": mm(size.x), "h": mm(size.y),
                         "th": pad.GetAttribute() == pcbnew.PAD_ATTRIB_PTH})
        out[part.ref] = {"fp": part.fp.split(":")[1], "value": part.value, "sheet": part.sheet, "back": False,
                         "height": G.height(part.fp), "new": True,
                         "cy": [mm(cy.GetLeft()), mm(cy.GetTop()), mm(cy.GetRight()), mm(cy.GetBottom())],
                         "pads": pads}
    with open(os.path.join(HERE, "fpdata.json"), "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
    print(len(out), "footprints")


if __name__ == "__main__":
    main()
