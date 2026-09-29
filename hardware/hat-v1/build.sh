#!/bin/sh
# Regenerate everything from gen/design.py. Needs KiCad 7 (kicad-cli) and python3.
set -e
cd "$(dirname "$0")"
python3 gen/gen_sch.py
python3 gen/check.py > /dev/null || { cat out/check-report.md; exit 1; }
python3 gen/bom.py
kicad-cli sch export pdf -o out/batman-hat-schematic.pdf batman-hat.kicad_sch > /dev/null
rm -f out/batman-hat.net
echo "OK: schematic, check report, BOM draft and PDF regenerated"
