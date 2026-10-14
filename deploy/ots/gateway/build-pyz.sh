#!/bin/sh
# build-pyz.sh — pack batman_eud_gateway into ONE regular file (payload-run's MOUNT rule, review A1-2).
# Reproducible: fixed mtimes, sorted entries, no compression (sha256 recorded by payload-run as a fact).
#   build-pyz.sh [out]      default: deploy/ots/eud-gateway.pyz
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-"$HERE/../eud-gateway.pyz"}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp -r "$HERE/batman_eud_gateway" "$T/"
find "$T" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$T" -type f -exec sed -i 's/\r$//' {} +
cat > "$T/__main__.py" <<'EOF'
import sys
from batman_eud_gateway.app import main
sys.exit(main(sys.argv[1:]))
EOF
export SOURCE_DATE_EPOCH=1700000000
python3 - "$T" "$OUT" <<'EOF'
import os, sys, zipfile, time
src, out = sys.argv[1], sys.argv[2]
fixed = time.gmtime(int(os.environ["SOURCE_DATE_EPOCH"]))[:6]
names = []
for root, dirs, files in os.walk(src):
    dirs.sort()
    for f in sorted(files):
        p = os.path.join(root, f)
        names.append((os.path.relpath(p, src), p))
names.sort()
with open(out, "wb") as fh:
    fh.write(b"#!/usr/bin/env python3\n")
    with zipfile.ZipFile(fh, "w", compression=zipfile.ZIP_STORED) as z:
        for arc, p in names:
            zi = zipfile.ZipInfo(arc.replace(os.sep, "/"), date_time=fixed)
            zi.external_attr = 0o644 << 16
            with open(p, "rb") as f:
                z.writestr(zi, f.read())
os.chmod(out, 0o644)
print(out)
EOF
sha256sum "$OUT"
