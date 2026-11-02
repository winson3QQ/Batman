#!/bin/bash
# scripts/dv-cryptprobe-tools.sh — build the #254 claim-lock test probe (tools/cryptprobe) for ONE firmware commit into
# the harness's own directory, with SHA256SUMS (docs/design/254-claim-lock-fix.md §11.3). A test tool: never in an image.
#
#   scripts/dv-cryptprobe-tools.sh <firmware tree> [dest]          (run where the firmware tree builds: WSL / Linux)
#
#   cryptprobe-arm64   static aarch64, linked against the tree's OWN musl (the libc the image ships)
#   MUSL               the toolchain's musl version (e.g. 1.2.5); the harness refuses a node whose /lib/libc.so differs
#   FWCOMMIT           the firmware commit it was built from
# dest defaults to ${DV_CRYPTPROBE_ROOT:-$HOME/batman-dv-tools}/cryptprobe-<fwcommit>. Refuses to overwrite a different copy.
set -euo pipefail
fw=${1:?usage: dv-cryptprobe-tools.sh <firmware tree> [dest]}
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$fw"
fwc=$(git rev-parse --short=7 HEAD)
TC=$(ls -d "$fw"/staging_dir/toolchain-aarch64_cortex-a72_*_musl | head -1)
[ -d "$TC/bin" ] || { echo "FAIL no aarch64 musl toolchain under $fw/staging_dir — build the board first"; exit 1; }
MUSL=$(ls -d "$fw"/build_dir/toolchain-aarch64_cortex-a72_*_musl/musl-* 2>/dev/null | sed -n 's/.*\/musl-\([0-9.]*\)$/\1/p' | head -1)
[ -n "$MUSL" ] || { echo "FAIL cannot tell the toolchain's musl version"; exit 1; }
dst=${2:-${DV_CRYPTPROBE_ROOT:-$HOME/batman-dv-tools}/cryptprobe-$fwc}
export STAGING_DIR=$fw/staging_dir
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir "$W/out"
"$TC/bin/aarch64-openwrt-linux-musl-gcc" -static -O2 -Wall -Werror -o "$W/out/cryptprobe-arm64" "$here/tools/cryptprobe/cryptprobe.c"
"$TC/bin/aarch64-openwrt-linux-musl-strip" "$W/out/cryptprobe-arm64"
echo "$MUSL" > "$W/out/MUSL"; echo "$fwc" > "$W/out/FWCOMMIT"
(cd "$W/out" && sha256sum cryptprobe-arm64 MUSL FWCOMMIT > SHA256SUMS)
if [ -f "$dst/SHA256SUMS" ]; then
	cmp -s "$dst/SHA256SUMS" "$W/out/SHA256SUMS" && { echo "ok   $dst already holds this probe (firmware $fwc, musl $MUSL)"; exit 0; }
	echo "FAIL $dst holds a different probe for $fwc — move it away first"; exit 1
fi
mkdir -p "$dst"; cp "$W/out/"* "$dst/"
echo "ok   $dst (firmware $fwc, musl $MUSL)"; cat "$dst/SHA256SUMS"
