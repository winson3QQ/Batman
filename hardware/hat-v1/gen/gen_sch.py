#!/usr/bin/env python3
"""Generate the KiCad 7 schematic (root + one sheet per block) from design.py.

Every pin gets a net label on its connection point (label-based schematic):
nets used on one sheet get a local label, nets used on several sheets a
global label. Intentionally unconnected pins get a no-connect flag.
UUIDs are derived from names, so regenerating gives a stable diff.
"""
import os
import sys
import uuid
from collections import defaultdict

sys.path.insert(0, os.path.dirname(__file__))
import design as D  # noqa: E402
import symbols as S  # noqa: E402

OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
NS = uuid.UUID("6f0c1c1e-0b7e-4f5e-9a57-ba7a4a7e0001")
PAPERS = [("A4", 297, 210), ("A3", 420, 297), ("A2", 594, 420), ("A1", 841, 594)]
MARGIN, TB_H = 15.0, 40.0
CHAR = 1.05  # mm per character at 1.27 mm font (estimate for spacing)
STUB = 2.54  # wire from the pin end to its label


def uid(*k):
    return str(uuid.uuid5(NS, "/".join(map(str, k))))


def q(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def f(v):
    return f"{v:.4f}".rstrip("0").rstrip(".")


def snap(v, g=1.27):
    return round(v / g) * g


ROOT_UUID = uid("root")
SHEET_UUID = {name: uid("sheet", name) for name, _ in D.SHEETS}


def net_sheets():
    m = defaultdict(set)
    for p in D.PARTS:
        for n in p.pins.values():
            if n:
                m[n].add(p.sheet)
    return m


NET_SHEETS = net_sheets()


def is_global(net):
    return len(NET_SHEETS[net]) > 1 or net in D.POWER_NETS


def label_len(net):
    return len(net) * CHAR + (4.0 if is_global(net) else 1.0)


def extents(p):
    g = S.geometry(p.sym)
    left = right = 0.0
    for nums, _pn, _t, x, _y, _a, side in g["pins"]:
        net = p.pins.get(nums[0])
        ln = label_len(net) + STUB if net else 1.5
        if side == "L":
            left = max(left, -x + ln)
        else:
            right = max(right, x + ln)
    # room for reference / value / note text
    txt = max(len(p.ref), len(p.value)) * CHAR * 0.5
    left, right = max(left, txt + 2), max(right, txt + 2)
    return left, right, g["top"] + 3.0, -g["bottom"] + 3.0, g


def layout(parts, width):
    """Row packing; returns [(part, sx, sy, geom)] and total height."""
    placed, x, y, row_h = [], MARGIN, MARGIN + 8, 0.0
    for p in parts:
        left, right, up, down = extents(p)[:4]
        w = left + right + 4
        if x + w > width - MARGIN and x > MARGIN:
            x, y, row_h = MARGIN, y + row_h + 4, 0.0
        sx, sy = snap(x + left), snap(y + up)
        placed.append((p, sx, sy, extents(p)[4]))
        x += w
        row_h = max(row_h, up + down)
    return placed, y + row_h


def props(p, sx, sy, g):
    top, bottom = g["top"], g["bottom"]
    if p.sym in S.IC:
        ref_xy, ref_j = (sx - g["w"] / 2, sy - top - 1.27), "left bottom"
        val_xy, val_j = (sx - g["w"] / 2, sy - bottom + 2.54), "left top"
    else:
        ref_xy, ref_j = (sx, sy - 2.54), "bottom"
        val_xy, val_j = (sx, sy + 2.54), "top"
    fields = [
        ("Reference", p.ref, ref_xy, ref_j, False),
        ("Value", p.value, val_xy, val_j, False),
        ("Footprint", p.fp, (sx, sy), "", True),
        ("Datasheet", "", (sx, sy), "", True),
        ("MPN", p.mpn, (sx, sy), "", True),
        ("Manufacturer", p.mfr, (sx, sy), "", True),
        ("Tier", p.tier, (sx, sy), "", True),
        ("LCSC", p.lcsc, (sx, sy), "", True),
        ("Note", p.note, (sx, sy), "", True),
    ]
    out = []
    for k, v, (x, y), j, hide in fields:
        just = f" (justify {j})" if j else ""
        out.append(f"    (property {q(k)} {q(v)} (at {f(x)} {f(y)} 0) "
                   f"(effects (font (size 1.27 1.27)){just}{' hide' if hide else ''}))")
    return "\n".join(out)


def symbol_instance(p, sx, sy, g, path):
    pins = []
    for nums, *_ in g["pins"]:
        for n in nums:
            pins.append(f"    (pin {q(n)} (uuid {uid(p.ref, 'pin', n)}))")
    return (f'  (symbol (lib_id {q("batman:" + p.sym)}) (at {f(sx)} {f(sy)} 0) (unit 1) '
            f'(in_bom {"no" if p.ref.startswith("#") or D.footprint_only(p) else "yes"}) '
            f'(on_board {"no" if p.ref.startswith("#") else "yes"}) '
            # Tier A = trust-chain parts: never assembled by JLC (spec 5.9) -> DNP in KiCad exports
            f'(dnp {"yes" if p.dnp or p.tier == "A" else "no"}) (uuid {uid(p.ref)})\n'
            f"{props(p, sx, sy, g)}\n" + "\n".join(pins) +
            f'\n    (instances (project {q(D.PROJECT)} (path {q(path)} (reference {q(p.ref)}) (unit 1))))\n  )')


def pin_items(p, sx, sy, g):
    items = []
    for nums, _pn, _t, x, y, _a, side in g["pins"]:
        px, py = sx + x, sy - y
        net = p.pins.get(nums[0], "__missing__")
        assert net != "__missing__", f"{p.ref}: pin {nums[0]} not in design"
        for n in nums[1:]:
            assert p.pins.get(n) == net, f"{p.ref}: stacked pin {n} must share net {net}"
        key = (p.ref, nums[0])
        if net is None:
            items.append(f"  (no_connect (at {f(px)} {f(py)}) (uuid {uid(*key, 'nc')}))")
            continue
        ang, just = (180, "right") if side == "L" else (0, "left")
        lx = px - STUB if side == "L" else px + STUB
        items.append(f"  (wire (pts (xy {f(px)} {f(py)}) (xy {f(lx)} {f(py)})) "
                     f"(stroke (width 0) (type default)) (uuid {uid(*key, 'w')}))")
        px = lx
        if is_global(net):
            items.append(
                f"  (global_label {q(net)} (shape passive) (at {f(px)} {f(py)} {ang}) (fields_autoplaced) "
                f"(effects (font (size 1.27 1.27)) (justify {just})) (uuid {uid(*key, 'gl')})\n"
                f'    (property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {f(px)} {f(py)} 0) '
                f"(effects (font (size 1.27 1.27)) hide)))")
        else:
            items.append(f"  (label {q(net)} (at {f(px)} {f(py)} {ang}) (fields_autoplaced) "
                         f"(effects (font (size 1.27 1.27)) (justify {just} bottom)) (uuid {uid(*key, 'lb')}))")
    return items


def lib_symbols(parts):
    syms = sorted({p.sym for p in parts})
    return "  (lib_symbols\n" + "\n".join(S.lib_symbol(s) for s in syms) + "\n  )"


def notes_text(parts, x, y, width):
    lines = [f"{p.ref}: {p.note}" for p in parts if p.note and not p.ref.startswith("#")]
    if not lines:
        return "", 0
    text = "NOTES\\n" + "\\n".join(l.replace('"', "'") for l in lines)
    h = (len(lines) + 1) * 2.2
    return (f"  (text {q('')[:-1]}{text}\" (at {f(x)} {f(y)} 0) "
            f"(effects (font (size 1.27 1.27)) (justify left top)) (uuid {uid('notes', x, y)}))"), h


def page_for(parts):
    for name, w, h in PAPERS:
        placed, bottom = layout(parts, w)
        nlines = sum(1 for p in parts if p.note and not p.ref.startswith("#")) + 1
        if bottom + 6 + nlines * 2.2 < h - MARGIN - TB_H:
            return name, w, h, placed, bottom
    name, w, h = PAPERS[-1]
    placed, bottom = layout(parts, w)
    return name, w, h, placed, bottom


def title_block(title, page_no):
    return (f"  (title_block (title {q(D.TITLE)}) (date {q(D.DATE)}) (rev {q(D.REV)}) "
            f"(company \"Batman project - generated by hardware/hat-v1/gen/gen_sch.py, do not edit by hand\") "
            f"(comment 1 {q(title)}) (comment 2 \"Label-based schematic: same net name = connected\"))")


def write_sheet(stem, title, page_no):
    parts = [p for p in D.PARTS if p.sheet == stem]
    paper, w, h, placed, bottom = page_for(parts)
    path = f"/{ROOT_UUID}/{SHEET_UUID[stem]}"
    body = []
    for p, sx, sy, g in placed:
        body.append(symbol_instance(p, sx, sy, g, path))
        body += pin_items(p, sx, sy, g)
    note, _ = notes_text(parts, MARGIN, bottom + 6, w)
    if note:
        body.append(note)
    txt = (f'(kicad_sch (version 20230121) (generator eeschema)\n  (uuid {SHEET_UUID[stem]})\n'
           f'  (paper {q(paper)})\n{title_block(title, page_no)}\n{lib_symbols(parts)}\n'
           + "\n".join(body) + "\n)\n")
    with open(os.path.join(OUT, f"{stem}.kicad_sch"), "w") as fh:
        fh.write(txt)
    return paper


ROOT_TEXT = """BATMAN HAT v1 for Raspberry Pi 4 - schematic generated from hardware/hat-v1/gen/design.py
Design spec: docs/design/hat-v1-spec.md (sections referenced in the part notes)

Blocks (one sheet each):
  1 power_in   battery pads, SMBJ20CA TVS, TPS26631 eFuse + reverse FET, INA226 #1 (0x40), BAT_PRESENT
  2 power_5v   LMR33640 5.17 V / 4 A with hardware UVLO on EN, LM74700 ideal diode to the Pi 5 V pins
  3 power_3v3  TPS62933F FCCM 3.33 V from the Pi 5 V rail, INA226 #2 (0x41), pi filter
  4 softpower  LTC2955-2 push-button controller, AUTO-ON jumper, GPIO27 -> KILL, GPIO26 <- INT
  5 pi_header  40-pin header (no ID EEPROM: overlays in config.txt), mounting holes
  6 halow      mPCIe 5.2H socket for Wio-WM6108, bulk capacitors
  7 security   SLB9672 TPM 2.0 on SPI1, ATECC608C-TFLXTLS (0x36), RV-3028-C7 RTC (0x52) + supercap
  8 gnss       u-blox MAX-M10S on UART5 + PPS, active antenna bias, U.FL
  9 debug      Tag-Connect TC2050 (UART0 + HaLow SPI), test points with expected values, power flags

Enable logic: 5 V buck runs when (LTC2955 on) AND (eFuse PGOOD) AND (VSYS > 6.40 V).
              HaLow 3.3 V buck: input = Pi 5 V (HAT buck or Pi USB-C), runs while the Pi 3.3 V is up.
Tier A parts (TPM, ATECC608C, RTC, GNSS) are not assembled by JLCPCB: fitted in Taiwan (spec 5.9).
No test points on TPM / SPI1 nets (spec 5.1)."""


def write_root():
    body, x, y = [], MARGIN, MARGIN + 95
    for i, (stem, title) in enumerate(D.SHEETS):
        col, row = i % 3, i // 3
        sx, sy = MARGIN + col * 130, y + row * 30
        body.append(
            f"  (sheet (at {f(sx)} {f(sy)}) (size 110 16) (fields_autoplaced) "
            f"(stroke (width 0.1524) (type solid)) (fill (color 0 0 0 0.0000)) (uuid {SHEET_UUID[stem]})\n"
            f"    (property \"Sheetname\" {q(stem)} (at {f(sx)} {f(sy - 0.7)} 0) "
            f"(effects (font (size 1.27 1.27)) (justify left bottom)))\n"
            f"    (property \"Sheetfile\" {q(stem + '.kicad_sch')} (at {f(sx)} {f(sy + 16.6)} 0) "
            f"(effects (font (size 1.27 1.27)) (justify left top)))\n"
            f"    (instances (project {q(D.PROJECT)} (path {q('/' + ROOT_UUID)} (page {q(str(i + 2))}))))\n  )")
        body.append(f"  (text {q(title)} (at {f(sx + 2)} {f(sy + 9)} 0) "
                    f"(effects (font (size 1.27 1.27)) (justify left bottom)) (uuid {uid('roottxt', stem)}))")
    root_txt = ROOT_TEXT.replace('"', "'").replace("\n", "\\n")
    body.append(f"  (text \"{root_txt}\" (at {f(MARGIN)} {f(MARGIN + 8)} 0) "
                f"(effects (font (size 1.524 1.524)) (justify left top)) (uuid {uid('roottext')}))")
    txt = (f'(kicad_sch (version 20230121) (generator eeschema)\n  (uuid {ROOT_UUID})\n  (paper "A3")\n'
           f'{title_block("Root: block overview", 1)}\n  (lib_symbols)\n' + "\n".join(body) +
           '\n  (sheet_instances (path "/" (page "1")))\n)\n')
    with open(os.path.join(OUT, f"{D.PROJECT}.kicad_sch"), "w") as fh:
        fh.write(txt)


def write_project():
    import json
    pro = {"meta": {"filename": f"{D.PROJECT}.kicad_pro", "version": 1},
           "sheets": [[ROOT_UUID, ""]] + [[SHEET_UUID[s], s] for s, _ in D.SHEETS],
           "text_variables": {}}
    with open(os.path.join(OUT, f"{D.PROJECT}.kicad_pro"), "w") as fh:
        json.dump(pro, fh, indent=2)
    # project symbol library (same symbols, for editing in KiCad)
    with open(os.path.join(OUT, "batman.kicad_sym"), "w") as fh:
        fh.write("(kicad_symbol_lib (version 20220914) (generator batman_gen)\n")
        for s in sorted(set(S.IC) | set(S.TWO) | set(S.ONE)):
            fh.write(S.lib_symbol(s).replace('(symbol "batman:', '(symbol "', 1) + "\n")
        fh.write(")\n")
    with open(os.path.join(OUT, "sym-lib-table"), "w") as fh:
        fh.write('(sym_lib_table\n  (lib (name "batman")(type "KiCad")(uri "${KIPRJMOD}/batman.kicad_sym")(options "")(descr "Batman HAT"))\n)\n')


def main():
    for i, (stem, title) in enumerate(D.SHEETS):
        paper = write_sheet(stem, title, i + 2)
        print(f"{stem}.kicad_sch  {paper}  {sum(1 for p in D.PARTS if p.sheet == stem)} parts")
    write_root()
    write_project()


if __name__ == "__main__":
    main()
