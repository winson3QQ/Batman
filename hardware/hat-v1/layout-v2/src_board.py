#!/usr/bin/env python3
"""Write layout-v2/src-board.kicad_pcb: the main board with footprints swapped to match design.py.

The main board (batman-hat.kicad_pcb) is the frozen DRC-clean baseline and is only read. Where
design.py names a different footprint than the board has (e.g. H5/H6 standoffs), the new footprint
is loaded from batman.pretty and put at the old one's position/side with the same pad nets.
export_fp.py and escape.py read this file when SRC_BOARD points at it.

Run in WSL with KiCad 7's pcbnew. FootprintLoad is called BEFORE LoadBoard (it segfaults after).
"""
import os
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
HAT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HAT, "gen"))
import design as D  # noqa: E402

LIB = os.path.join(HAT, "batman.pretty")


def main():
    want = {p.ref: p.fp.split(":", 1) for p in D.PARTS if getattr(p, "fp", None)}
    # 1. load every batman: footprint design.py asks for, before any board is open
    loaded = {}
    for ref, (lib, name) in want.items():
        if lib == "batman" and name not in loaded and os.path.exists(os.path.join(LIB, name + ".kicad_mod")):
            loaded[name] = pcbnew.FootprintLoad(LIB, name)
    board = pcbnew.LoadBoard(os.path.join(HAT, "batman-hat.kicad_pcb"))
    swapped = []
    for old in list(board.GetFootprints()):
        ref = old.GetReference()
        if ref not in want:
            continue
        lib, name = want[ref]
        if str(old.GetFPID().GetLibItemName()) == name or name not in loaded:
            continue
        nets = {p.GetNumber(): p.GetNet() for p in old.Pads()}
        new = pcbnew.Cast_to_FOOTPRINT(loaded[name].Duplicate())
        new.SetFPID(pcbnew.LIB_ID(lib, name))
        new.SetReference(ref)
        new.SetValue(old.GetValue())
        board.Add(new)
        if old.IsFlipped():
            new.Flip(new.GetPosition(), False)
        new.SetOrientation(old.GetOrientation())
        new.SetPosition(old.GetPosition())
        for p in new.Pads():
            if p.GetNumber() in nets:
                p.SetNet(nets[p.GetNumber()])
        swapped.append(f"{ref}: {old.GetFPID().GetLibItemName()} -> {name}")
        board.Delete(old)
    out = os.path.join(HERE, "src-board.kicad_pcb")
    pcbnew.SaveBoard(out, board)
    print("\n".join(swapped) or "nothing to swap")
    print("wrote", out)


if __name__ == "__main__":
    main()
