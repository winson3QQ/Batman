#!/bin/sh
# CI drift guard (#159, review M2): the batman-payload-host meta-package DEPENDS closure
# and deploy/fts/payload-host-packages.txt describe the SAME set of packages but live in
# different places (a package Makefile vs a captured runtime manifest) and are consumed by
# different repos (this feed vs the firmware fork's board seed). If they drift, the image
# either omits a package the node needs or bakes in one nobody vetted. This asserts they
# match exactly, modulo cgroupfs-mount (intentionally excluded from the image — see the
# meta-package header, review B1).
#
# Exit 0 = in sync; exit 1 = drift (prints the diff).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="$ROOT/feed/batman-payload-host/Makefile"
TXT="$ROOT/deploy/fts/payload-host-packages.txt"

[ -f "$MK" ]  || { echo "FAIL: missing $MK"; exit 1; }
[ -f "$TXT" ] || { echo "FAIL: missing $TXT"; exit 1; }

tmp_mk="$(mktemp)"
tmp_txt="$(mktemp)"
trap 'rm -f "$tmp_mk" "$tmp_txt"' EXIT

# Packages the meta-package DEPENDS on: the "+pkg" tokens (drop the @TARGET_* gate and any
# +CONFIG:pkg conditionals, which none are used here but guard anyway).
grep -oE '\+[A-Za-z0-9._-]+' "$MK" \
  | sed 's/^+//' \
  | sort -u > "$tmp_mk"

# The captured runtime manifest, minus comments, cgroupfs-mount (excluded by design,
# review B1) and the ABI-versioned auto-split libraries. The latter are not buildable
# package symbols (opkg generates them with a soname suffix from util-linux/lzo/iptables)
# so they cannot appear in a DEPENDS list; they are pulled in transitively. See the
# meta-package header.
AUTOLIBS='^(cgroupfs-mount|libmount1|liblzo2|libxtables12|libiptext0|libiptext6-0|libiptext-nft0)$'
grep -v '^#' "$TXT" \
  | awk 'NF{print $1}' \
  | grep -vE "$AUTOLIBS" \
  | sort -u > "$tmp_txt"

if diff -u "$tmp_txt" "$tmp_mk" >/tmp/ph_sync_diff 2>&1; then
  echo "OK: batman-payload-host DEPENDS matches payload-host-packages.txt (minus cgroupfs-mount + auto-split libs)"
  echo "    $(wc -l < "$tmp_mk") packages in sync"
  exit 0
fi

echo "FAIL: batman-payload-host DEPENDS drifted from payload-host-packages.txt"
echo "  (< = only in payload-host-packages.txt, > = only in meta-package DEPENDS)"
cat /tmp/ph_sync_diff
exit 1
