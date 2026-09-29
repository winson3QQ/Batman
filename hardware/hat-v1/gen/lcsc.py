#!/usr/bin/env python3
"""Fill LCSC part numbers for the JLCPCB assembly BOM (M3).

Sources (none of them is JLC's live site, which this environment cannot reach):
  --db     jlcparts full cache.sqlite3 (github.com/yaqwsx/jlcparts, gh-pages data/cache.zip).
           Snapshot 2026-09-27 16:21 UTC. It currently only holds LCSC ids >= C6374508,
           so older parts (most JLC basic parts, most TI ICs) are simply absent.
  --basic  CDFER/jlcpcb-parts-database scraped/ComponentList.csv: ids of every JLC
           basic / preferred part, scraped 2026-09-27 (ids only, no descriptions).
  BASIC_FROM_MEMORY below: value -> basic id pairs from memory. Only used when the id is
           confirmed in the --basic list; the value mapping itself is flagged "verify".

Output: out/bom-jlc.csv (JLC upload format) and out/lcsc-report.md.
Status per line: DB (found in the snapshot, with stock and price), BASIC-verify,
SEARCH (not in the snapshot: search JLC by the MPN given), NOT-JLC (Tier A or
footprint only), DNP.
"""
import argparse
import csv
import json
import os
import re
import sqlite3
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(__file__))
import design as D  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "out")

BASIC_FROM_MEMORY_RAW = {  # (kind, value in base units, package) -> (lcsc, what it should be)
    ("R", 10e3, "0402"): ("C25744", "UNI-ROYAL 0402WGF1002TCE 10k 1%"),
    ("R", 100e3, "0402"): ("C25741", "UNI-ROYAL 0402WGF1003TCE 100k 1%"),
    ("R", 4.7e3, "0402"): ("C25900", "UNI-ROYAL 0402WGF4701TCE 4.7k 1%"),
    ("R", 2.2e3, "0402"): ("C25879", "UNI-ROYAL 0402WGF2201TCE 2.2k 1%"),
    ("R", 1e6, "0402"): ("C26083", "UNI-ROYAL 0402WGF1004TCE 1M 1%"),
    ("R", 0.0, "0402"): ("C17168", "UNI-ROYAL 0402WGF0000TCE 0R"),
    ("C", 100e-9, "0402"): ("C1525", "Samsung CL05B104KO5NNNC 100n 16V X7R"),
    ("C", 1e-6, "0402"): ("C52923", "Samsung CL05A105KA5NQNC 1u 25V X5R"),
    ("C", 10e-9, "0402"): ("C15195", "Samsung CL05B103KB5NNNC 10n 50V X7R"),
    ("C", 22e-12, "0402"): ("C1555", "Samsung CL05C220JB5NNNC 22p 50V C0G"),
    ("C", 1e-6, "0603"): ("C15849", "Samsung CL10A105KB8NNNC 1u 50V X5R"),
    ("C", 10e-6, "0603"): ("C19702", "Samsung CL10A106KP8NNNC 10u 10V X5R"),
    ("C", 22e-6, "0805"): ("C45783", "Samsung CL21A226MAQNNNE 22u 25V X5R"),
}
BASIC_FROM_MEMORY = {(a, float(f"{b:.4e}"), c): v for (a, b, c), v in BASIC_FROM_MEMORY_RAW.items()}
# Voltage rating assumed for the memory entries (checked against the design's need)
BASIC_VRATING = {"C1525": 16, "C52923": 25, "C15195": 50, "C1555": 50, "C15849": 50, "C19702": 10, "C45783": 25}

ORIGIN = {  # manufacturer -> where the company is headquartered (user rule: flag China)
    "YAGEO": "Taiwan", "UNI-ROYAL(Uniroyal Elec)": "Taiwan HQ, China fabs", "Samsung Electro-Mechanics": "Korea",
    "Murata Electronics": "Japan", "Coilcraft": "USA", "Wurth Elektronik": "Germany", "Vishay Intertech": "USA",
    "ROHM Semicon": "Japan", "KEMET": "USA (Yageo group)", "TDK": "Japan", "Panasonic": "Japan",
    "Walsin Tech Corp": "Taiwan", "FOJAN": "China", "SURGING": "China", "hongjiacheng": "China",
    "FH(Guangdong Fenghua Advanced Tech)": "China", "Lian Xin Technology": "China", "RALEC": "Taiwan",
    "Ever Ohms Tech": "Taiwan", "Littelfuse": "USA", "onsemi": "USA", "Texas Instruments": "USA",
    "TE Connectivity": "Switzerland", "KOA": "Japan", "Bourns": "USA", "Sunlord": "China", "CCTC": "China",
    "Kyocera AVX": "Japan/USA", "Samsung Electro Mechanics": "Korea", "PANASONIC": "Japan", "Taiyo Yuden": "Japan",
    "Chinocera": "China", "Keystone Electronics": "USA", "Everlight Elec": "Taiwan", "Lite-On": "Taiwan",
    "Hubei KENTO Elec": "China", "XINGLIGHT": "China", "OSRAM Opto Semicon": "Germany", "Kingbright": "Taiwan",
    "ROHM": "Japan",
}


def k(v):
    return None if v is None else float(f"{v:.4e}")


def num(s):
    m = re.match(r"\s*([\d.]+)\s*([pnuµmkKMR]?)", s)
    if not m:
        return None
    v = float(m.group(1))
    return v * {"p": 1e-12, "n": 1e-9, "u": 1e-6, "µ": 1e-6, "m": 1e-3, "k": 1e3, "K": 1e3, "M": 1e6,
                "R": 1, "": 1}[m.group(2)]


def pkg_of(fp):
    m = re.search(r"_(0201|0402|0603|0805|1206|1210|2512)_", fp)
    return m.group(1) if m else None


def db_resistors(db, ohms, pkg, tol):
    rows = db.execute("select lcsc,mfr,manufacturer,library_type,preferred,stock,price,attributes,description "
                      "from jlc_components where subcategory like 'Chip Resistor%' and package=? and stock>=50",
                      (pkg,)).fetchall()
    out = []
    for r in rows:
        a = json.loads(r[7])
        v = a.get("Resistance", "").replace("Ω", "").replace("Ohm", "")
        v = 0.0 if v.strip() in ("0", "0R") else num(v)
        t = a.get("Tolerance", "±5%").replace("±", "").replace("%", "")
        try:
            t = float(t)
        except ValueError:
            t = 5.0
        if v is not None and abs(v - ohms) <= 1e-9 + ohms * 1e-6 and t <= tol:
            out.append(r)
    return out


def db_caps(db, farads, pkg, vmin):
    rows = db.execute("select lcsc,mfr,manufacturer,library_type,preferred,stock,price,attributes,description "
                      "from jlc_components where subcategory like 'Multilayer Ceramic%' and package=? and stock>=50",
                      (pkg,)).fetchall()
    out = []
    for r in rows:
        a = json.loads(r[7])
        v = num(a.get("Capacitance", "").replace("F", ""))
        vr = num(a.get("Voltage Rating", "0V").replace("V", "")) or 0
        if v and abs(v - farads) <= farads * 1e-6 and vr >= vmin:
            out.append(r)
    return out


def rank(rows):
    pref = ["Samsung", "Murata", "YAGEO", "TDK", "Wurth", "Vishay", "Panasonic", "KEMET", "Walsin", "UNI-ROYAL",
            "ROHM", "KOA", "RALEC", "Ever Ohms"]

    def key(r):
        m = next((i for i, p in enumerate(pref) if p.lower() in (r[2] or "").lower()), len(pref))
        return (r[3] != "base", not r[4], m, -r[5])
    return sorted(rows, key=key)


def price1(p):
    m = re.match(r"[^:]*:([\d.]+)", p or "")
    return float(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--basic", required=True)
    args = ap.parse_args()
    db = sqlite3.connect(args.db)
    basic_ids = {"C" + r["lcsc"] for r in csv.DictReader(open(args.basic))}
    groups = OrderedDict()
    for p in D.PARTS:
        if p.ref.startswith("#"):
            continue
        groups.setdefault((p.value, p.fp, p.mpn, p.dnp, p.tier), []).append(p)
    lines = []
    for (value, fp, mpn, dnp, tier), ps in groups.items():
        p = ps[0]
        refs = ",".join(x.ref for x in ps)
        row = dict(refs=refs, qty=len(ps), value=value, fp=fp.split(":")[-1], mpn=mpn, lcsc=p.lcsc,
                   status="", source="", mfr="", origin="", stock="", price="", basic="", note="")
        if D.footprint_only(p):
            row.update(status="NOT-JLC", note="copper only (pads / jumper / hole)")
        elif dnp:
            row.update(status="DNP", note="footprint only, not fitted")
        elif tier == "A":
            row.update(status="NOT-JLC", note="Tier A: bought from an authorised distributor, fitted in Taiwan")
        elif p.lcsc:
            r = db.execute("select mfr,manufacturer,library_type,stock,price from jlc_components where lcsc=?",
                           (int(p.lcsc[1:]),)).fetchone()
            row.update(status="DB" if r else "SEARCH", source="design.py",
                       **({} if not r else dict(mfr=r[1], stock=r[3], price=price1(r[4]),
                                               basic=r[2], origin=ORIGIN.get(r[1], "check"))))
        elif p.sym in ("R", "C"):
            pkg = pkg_of(fp)
            kind = p.sym
            v = 0.0 if value.startswith("0R") else num(value)
            if kind == "R":
                tol = 0.5 if "0.5%" in value else 1.0 if "1%" in value else 5.0
                vneed = 0
                cands = rank(db_resistors(db, v, pkg, tol)) if pkg else []
            else:
                vm = re.search(r"([\d.]+)V", value)
                vneed = float(vm.group(1)) if vm else 16
                tol = None
                cands = rank(db_caps(db, v, pkg, vneed)) if pkg else []
            mem = BASIC_FROM_MEMORY.get((kind, k(v), pkg))
            if mem and mem[0] in basic_ids and (kind == "R" and tol >= 1.0 or
                                                 kind == "C" and BASIC_VRATING.get(mem[0], 0) >= vneed):
                row.update(lcsc=mem[0], status="BASIC-verify", basic="base", source="memory + basic list",
                           note=f"check JLC shows: {mem[1]}")
            elif cands:
                r = cands[0]
                row.update(lcsc=f"C{r[0]}", status="DB", mfr=r[2], basic=r[3], stock=r[5], price=price1(r[6]),
                           origin=ORIGIN.get(r[2], "check"), source="jlcparts snapshot",
                           note=f"{r[1]}; {len(cands)} candidates")
            else:
                row.update(status="SEARCH", note=f"search JLC: {value} {pkg}")
        elif p.sym == "LED":
            color = {"RED": "Red", "GREEN": "Green"}.get(value.upper(), value)
            r = db.execute("select lcsc,mfr,manufacturer,library_type,stock,price from jlc_components where "
                           "subcategory like 'LED Indication%' and package='0402' and stock>=50 and "
                           "(attributes like ? or description like ?) order by stock desc limit 1",
                           (f'%"Emitted Color":"{color}%', f"%{color}%")).fetchone()
            if r:
                row.update(lcsc=f"C{r[0]}", status="DB", mfr=r[2], basic=r[3], stock=r[4], price=price1(r[5]),
                           origin=ORIGIN.get(r[2], "check"), source="jlcparts snapshot", note=r[1])
            else:
                row.update(status="SEARCH", note=f"search JLC: 0402 {color} LED")
        else:
            key = "5015" if "Keystone_5015" in fp else (mpn or value).split(" (")[0]
            mq = "Keystone%" if key == "5015" else "%"
            r = db.execute("select lcsc,mfr,manufacturer,library_type,stock,price from jlc_components "
                           "where mfr like ? and manufacturer like ? and stock>=20 order by stock desc limit 1",
                           (key + "%", mq)).fetchone()
            if r:
                row.update(lcsc=f"C{r[0]}", status="DB", mfr=r[2], basic=r[3], stock=r[4], price=price1(r[5]),
                           origin=ORIGIN.get(r[2], "check"), source="jlcparts snapshot", note=r[1])
            else:
                row.update(status="SEARCH", note=f"search JLC by MPN: {key}")
        lines.append(row)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "bom-jlc.csv"), "w", newline="") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
        for r in lines:
            if r["status"] in ("DB", "BASIC-verify", "SEARCH"):
                w.writerow([r["mpn"] or r["value"], r["refs"], r["fp"], r["lcsc"]])
    from collections import Counter
    cnt = Counter(r["status"] for r in lines)
    rep = ["# LCSC part numbers for JLCPCB assembly (M3 draft)", "",
           "Generated by `gen/lcsc.py`. Sources: jlcparts snapshot 2026-09-27 16:21 UTC (only LCSC ids >= "
           "C6374508), JLC basic/preferred id list scraped 2026-09-27, and a short value->basic-part table "
           "from memory (used only when the id is confirmed basic; the value must be checked on upload).", "",
           "| status | lines | meaning |", "|---|---|---|",
           f"| DB | {cnt['DB']} | found in the snapshot with stock >= 50 (fact as of the snapshot) |",
           f"| BASIC-verify | {cnt['BASIC-verify']} | JLC basic part (id confirmed); check that the description JLC shows matches the note |",
           f"| SEARCH | {cnt['SEARCH']} | not in the snapshot: search jlcpcb.com/parts by the MPN / value, or let JLC's BOM tool match it |",
           f"| NOT-JLC | {cnt['NOT-JLC']} | Tier A (fitted in Taiwan) or copper only |",
           f"| DNP | {cnt['DNP']} | not fitted |", "",
           "Origin column: company headquarters (user rule: flag China). All China-origin lines here are "
           "Tier C passives / discretes, allowed by spec 5.8.", "",
           "| refs | qty | value | package | LCSC | status | manufacturer | origin | stock | USD @1 | note |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in lines:
        rep.append(f"| {r['refs']} | {r['qty']} | {r['value']} | {r['fp']} | {r['lcsc']} | {r['status']} | "
                   f"{r['mfr']} | {r['origin']} | {r['stock']} | {r['price'] or ''} | {r['note']} |")
    with open(os.path.join(OUT, "lcsc-report.md"), "w") as fh:
        fh.write("\n".join(rep) + "\n")
    print(dict(cnt))


if __name__ == "__main__":
    main()
