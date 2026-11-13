#!/usr/bin/env python3
"""scripts/dv/gen-p3-units.py — #254 H4 §6.3: appendix A of docs/design/254-h4-harness.md is the ONLY source of the
P3 test rows; this turns it into scripts/dv/data/p3-units.tsv (one line per row).

  gen-p3-units.py            write the TSV
  gen-p3-units.py --check    the committed TSV equals what appendix A gives now (CI / test-h4-offline); rc 1 if not
  gen-p3-units.py --list [unit]   print "<unit> <row> <arm> <vehicle> <negative kinds>"

Columns: unit  row  source  arm  vehicle  assertion  negative  neg_kinds  sha
  neg_kinds = the kinds named in the "negative" cell, in order, comma-separated: W S P G or "-" (§6.2)
  sha       = sha256 (first 12 hex) of the row's cells with whitespace normalised: a design edit shows as a diff
A row with an empty arm / vehicle / negative cell, a duplicate row id, or an unknown vehicle is an error (rc 2):
a table that cannot be read must not look like "no tests".
"""
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = os.path.join(HERE, "..", "..", "docs", "design", "254-h4-harness.md")
OUT = os.path.join(HERE, "data", "p3-units.tsv")
VEHICLES = {"R", "RB", "RD", "T", "W", "F", "L", "C"}   # §2


def die(msg):
    sys.stderr.write("gen-p3-units: FAIL %s\n" % msg)
    sys.exit(2)


def cells(line):
    # split a markdown table row on unescaped pipes outside backticks
    out, cur, tick = [], "", False
    for i, ch in enumerate(line):
        if ch == "`":
            tick = not tick
        if ch == "|" and not tick and (i == 0 or line[i - 1] != "\\"):
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [c.strip() for c in out[1:-1]]


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def vehicles(cell):
    # "RB(T 窗)", "F + RB(`x`)", "R(`run/`)" -> the vehicle letters in order
    v = re.findall(r"(?<![A-Za-z`/])(RB|RD|R|T|W|F|L|C)(?![A-Za-z])", re.sub(r"`[^`]*`", "", cell))
    return v


def neg_kinds(cell):
    c = re.sub(r"`[^`]*`", "", cell)
    if c.startswith("—") or c.startswith("-") or c == "":
        return ["-"]
    k = []
    if "NEEDS-PERSON" in c:
        k.append("N")   # a row a person runs (h4-manual-cases.md / on site)
        c = c.replace("NEEDS-PERSON", "")
    for m in re.finditer(r"(?<![A-Za-z])([WSPG])(?![A-Za-z])", c):
        if m.group(1) not in k:
            k.append(m.group(1))
    return k or ["?"]


def parse():
    try:
        text = open(DOC, encoding="utf-8").read()
    except OSError as e:
        die("cannot read %s: %s" % (DOC, e))
    m = re.search(r"^## 附錄 A\..*?$(.*?)^## 附錄 B", text, re.S | re.M)
    if not m:
        die("appendix A not found in %s" % DOC)
    rows, unit, seen, other = [], None, set(), False
    for line in m.group(1).split("\n"):
        h = re.match(r"^### A\.\d+ (.*)$", line)
        if h:
            u = re.findall(r"`([a-z0-9-]+-254)`", h.group(1))
            # "A.11 其他": rows that belong to other units / tools (its third column names them); kept under one
            # name, and its free-form vehicle / negative cells are recorded as X instead of being an error
            other = not u
            unit = u[0] if u else "p3-other-254"
            # a vehicle named in the heading ("prov-upload-254(RB,T pending)") is the default of a table without
            # a vehicle column
            hv = vehicles(re.sub(r"`[^`]*`", "", h.group(1)))
            col = None
            continue
        if not line.startswith("|") or unit is None:
            continue
        c = cells(line)
        if c and c[0] == "#":
            # the header row: columns by NAME (the tables do not all have the same columns)
            names = {"來源": "src", "臂": "arm", "單位": "arm", "載": "veh", "斷言": "asr", "負": "neg"}
            col = {}
            for i, n in enumerate(c):
                if n in names:
                    col[names[n]] = i
                elif n != "#":
                    die("section %s: unknown table column [%s]" % (unit, n))
            for need in ("src", "asr", "neg"):
                if need not in col:
                    die("section %s: its table has no %s column" % (unit, need))
            continue
        if not c or set(c[0]) <= set("-: "):
            continue
        if col is None:
            die("section %s: a table row before any header row: %s" % (unit, line[:60]))
        if len(c) <= max(col.values()):
            die("section %s row %s: %d cells, the header has more" % (unit, c[0], len(c)))
        rid, src, asr, neg = c[0], c[col["src"]], c[col["asr"]], c[col["neg"]]
        arm = c[col["arm"]] if "arm" in col else rid.lower()
        veh = c[col["veh"]] if "veh" in col else "+".join(hv)
        c = [rid, src, arm, veh, asr, neg]
        if (unit, rid) in seen:
            die("duplicate row %s %s" % (unit, rid))
        seen.add((unit, rid))
        vs = vehicles(veh)
        if other and not vs:
            vs = ["X"]
        if not arm or not vs or not neg:
            die("row %s %s: empty arm / vehicle / negative cell (arm=[%s] vehicle=[%s] negative=[%s])" % (unit, rid, arm, veh, neg))
        for v in vs:
            if v not in VEHICLES and not other:
                die("row %s %s: unknown vehicle %s" % (unit, rid, v))
        nk = neg_kinds(neg)
        if nk == ["?"] and neg.startswith("同上") and rows and rows[-1][0] == unit:
            nk = rows[-1][7].split(",")   # "同上" (as above): the kinds of the row before it, same unit
        if nk == ["?"] and other:
            nk = ["X"]
        if nk == ["?"]:
            die("row %s %s: the negative cell names no kind (W / S / P / G or —): [%s]" % (unit, rid, neg))
        sha = hashlib.sha256("\x1f".join(norm(x) for x in c[:6]).encode("utf-8")).hexdigest()[:12]
        rows.append([unit, rid, norm(src), norm(arm), "+".join(vs), norm(asr), norm(neg), ",".join(nk), sha])
    if not rows:
        die("appendix A has no rows")
    return rows


def render(rows):
    head = "# generated by scripts/dv/gen-p3-units.py from docs/design/254-h4-harness.md appendix A — do not edit\n"
    head += "# unit\trow\tsource\tarm\tvehicle\tassertion\tnegative\tneg_kinds\tsha\n"
    return head + "".join("\t".join(x.replace("\t", " ") for x in r) + "\n" for r in rows)


MANUAL = os.path.join(HERE, "..", "..", "docs", "validation", "p3-manual-rows.md")


def read_how():
    hw = {}
    for ln in open(os.path.join(HERE, "data", "p3-how.tsv"), encoding="utf-8"):
        if ln.startswith("#") or not ln.strip():
            continue
        f = ln.rstrip("\n").split("\t")
        hw[(f[0], f[1])] = (f[2], f[3] if len(f) > 3 else "")
    return hw


def manual_doc(rows):
    """the rows (or parts of rows) a person runs with the app / the phone, as a checklist (generated)"""
    hw = read_how()
    out = ["# P3 測項裡由人執行的列(由 `scripts/dv/gen-p3-units.py --manual` 產生,不要手改)", "",
           "來源:`docs/design/254-h4-harness.md` 附錄 A + `scripts/dv/data/p3-how.tsv`。主機端沒有能經 provd 開擁有者連線的測試",
           "client(#254 留言 6697703967,使用者 2026-11-07 決定不寫),所以這些列要用**正式的 provisioning app / 手機**執行。",
           "",
           "- 執行時機:app 第一版之後,以及每次發版前。前置與記錄格式同 `h4-manual-cases.md` 第 0 節與「紀錄格式」。",
           "- 「部分」= 該列的自動化部分由測項跑;表中「人要做的」是剩下的那一段。",
           "- 沒有證據(app 截圖、節點唯讀輸出、時間)= 沒跑,不算 PASS。", ""]
    cur = None
    n_m = n_p = 0
    for r in rows:
        h, note = hw.get((r[0], r[1]), ("", ""))
        if "m" not in h.split("+"):
            continue
        if r[0] != cur:
            cur = r[0]
            out += ["", "## `%s`" % cur, "", "| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |", "|---|---|---|---|---|"]
        part = "全部" if h == "m" else "部分"
        n_m += h == "m"
        n_p += h != "m"
        out.append("| %s | %s | %s | %s | %s |" % (r[1], r[2].replace("|", "\\|"), part, note.replace("|", "\\|"), (r[5] or "—").replace("|", "\\|")))
    out += ["", "合計:全部由人執行 %d 列,部分 %d 列(共 %d 列中的 %d 列)。" % (n_m, n_p, len(rows), n_m + n_p), ""]
    return "\n".join(out)


def main():
    rows = parse()
    a = sys.argv[1:]
    if a and a[0] == "--manual":
        with open(MANUAL, "w", encoding="utf-8", newline="\n") as f:
            f.write(manual_doc(rows))
        print("gen-p3-units: wrote %s" % os.path.relpath(MANUAL, os.path.join(HERE, "..", "..")))
        return 0
    if a and a[0] == "--list":
        for r in rows:
            if len(a) < 2 or r[0] == a[1]:
                print(r[0], r[1], r[3].replace(" ", "_"), r[4], r[7])
        return 0
    text = render(rows)
    if a and a[0] == "--check":
        try:
            cur = open(OUT, encoding="utf-8").read()
        except OSError:
            die("%s is missing: run gen-p3-units.py" % OUT)
        if cur != text:
            a_l, b_l = cur.split("\n"), text.split("\n")
            bad = [i for i in range(max(len(a_l), len(b_l))) if (a_l[i] if i < len(a_l) else None) != (b_l[i] if i < len(b_l) else None)]
            sys.stderr.write("gen-p3-units: FAIL p3-units.tsv is not what appendix A gives (%d line(s) differ, first at line %d): run gen-p3-units.py and review the diff\n" % (len(bad), bad[0] + 1))
            return 1
        # p3-how.tsv: every row says how it is run (h / n / g / m, or a+b), and names no row that is gone
        hw = {}
        try:
            for ln in open(os.path.join(HERE, "data", "p3-how.tsv"), encoding="utf-8"):
                if ln.startswith("#") or not ln.strip():
                    continue
                f = ln.rstrip("\n").split("\t")
                if len(f) < 3 or not all(p in ("h", "n", "g", "m") for p in f[2].split("+")):
                    die("p3-how.tsv: bad line: %s" % ln.strip()[:80])
                if "m" in f[2].split("+") and (len(f) < 4 or not f[3].strip()):
                    die("p3-how.tsv: %s %s is (partly) manual and has no note saying what is left for a person" % (f[0], f[1]))
                hw[(f[0], f[1])] = f[2]
        except OSError:
            die("scripts/dv/data/p3-how.tsv is missing")
        have = {(r[0], r[1]) for r in rows}
        miss, gone = sorted(have - set(hw)), sorted(set(hw) - have)
        if miss or gone:
            sys.stderr.write("gen-p3-units: FAIL p3-how.tsv: no entry for %s; entries for rows that do not exist: %s\n" % (miss or "-", gone or "-"))
            return 1
        try:
            if open(MANUAL, encoding="utf-8").read() != manual_doc(rows):
                sys.stderr.write("gen-p3-units: FAIL docs/validation/p3-manual-rows.md is not what the tables give: run gen-p3-units.py --manual\n")
                return 1
        except OSError:
            die("docs/validation/p3-manual-rows.md is missing: run gen-p3-units.py --manual")
        cnt = {}
        for v in hw.values():
            k = "manual" if v == "m" else "partly" if "m" in v.split("+") else "auto"
            cnt[k] = cnt.get(k, 0) + 1
        print("gen-p3-units: ok, %d rows in %d units; automated %d, partly %d, by hand %d" % (len(rows), len({r[0] for r in rows}), cnt.get("auto", 0), cnt.get("partly", 0), cnt.get("manual", 0)))
        return 0
    if a:
        die("usage: gen-p3-units.py [--check | --list [unit]]")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    units = {}
    for r in rows:
        units[r[0]] = units.get(r[0], 0) + 1
    print("gen-p3-units: wrote %d rows in %d units" % (len(rows), len(units)))
    for u in units:
        print("  %-28s %3d" % (u, units[u]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
