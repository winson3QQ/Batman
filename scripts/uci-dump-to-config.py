#!/usr/bin/env python3
"""Convert `uci show` output back into /etc/config/<pkg> files.

Replicating a configured node onto a fresh one by replaying `uci set` is
awkward: anonymous sections are addressed by index, so the commands only line
up if the target already has the same sections in the same order. Writing the
config files directly sidesteps the ordering problem entirely.

Usage: uci-dump-to-config.py <dump> <outdir> <pkg> [<pkg>...]
"""
import re
import sys
import os

# `uci show` prints list values as several single-quoted words on one line.
QUOTED = re.compile(r"'((?:[^']|'\\'')*)'")


def parse(dump, packages):
    """-> {pkg: [(type, name_or_None, [(kind, key, value_or_list)])]}"""
    pkgs = {p: [] for p in packages}
    index = {}  # (pkg, section-key) -> section, so options find their section

    for line in dump.splitlines():
        line = line.rstrip()
        if not line or '.' not in line:
            continue
        head, _, raw = line.partition('=')
        parts = head.split('.')
        pkg = parts[0]
        if pkg not in pkgs:
            continue

        if len(parts) == 2:                      # section declaration
            sect = (raw.strip(), parts[1], [])
            pkgs[pkg].append(sect)
            index[(pkg, parts[1])] = sect
        elif len(parts) == 3:                    # option or list
            sect = index.get((pkg, parts[1]))
            if sect is None:                     # option before its section
                continue
            values = QUOTED.findall(raw)
            if not values:                       # unquoted scalar
                values = [raw.strip()]
            kind = 'list' if len(values) > 1 else 'option'
            sect[2].append((kind, parts[2], values))
    return pkgs


def emit(sections):
    out = []
    for stype, name, options in sections:
        # `uci show` names anonymous sections @type[N]; they have no real name.
        if name.startswith('@'):
            out.append("config %s" % stype)
        else:
            out.append("config %s '%s'" % (stype, name))
        for kind, key, values in options:
            if kind == 'list':
                for v in values:
                    out.append("\tlist %s '%s'" % (key, v))
            else:
                out.append("\toption %s '%s'" % (key, values[0]))
        out.append("")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    dump_path, outdir, packages = sys.argv[1], sys.argv[2], sys.argv[3:]
    with open(dump_path) as fh:
        dump = fh.read()
    os.makedirs(outdir, exist_ok=True)
    for pkg, sections in parse(dump, packages).items():
        if not sections:
            print("  %-12s SKIPPED (nothing in dump)" % pkg)
            continue
        path = os.path.join(outdir, pkg)
        with open(path, 'w') as fh:
            fh.write(emit(sections))
        print("  %-12s %2d sections -> %s" % (pkg, len(sections), path))


if __name__ == '__main__':
    main()
