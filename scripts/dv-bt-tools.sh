#!/bin/bash
# scripts/dv-bt-tools.sh — copy the BLE test tools (btmgmt, btmon) out of a firmware build tree into the harness's
# own fixed directory, with SHA256SUMS (#254 PR-H1 §2). They are test tools: never part of an image.
#   scripts/dv-bt-tools.sh <bluez build dir> [dest]
#   e.g. //wsl.localhost/Ubuntu-24.04/home/yello/firmware-2710/build_dir/target-aarch64_cortex-a72_musl/bluez-5.72
# dest defaults to $DV_BT_TOOLS or ~/batman-dv-tools/bluez-5.72. Refuses to overwrite a different existing copy.
set -eu
src=${1:?usage: dv-bt-tools.sh <bluez build dir> [dest]}
dst=${2:-${DV_BT_TOOLS:-$HOME/batman-dv-tools/bluez-5.72}}
for f in tools/btmgmt monitor/btmon; do [ -f "$src/$f" ] || { echo "FAIL $src/$f missing"; exit 1; }; done
mkdir -p "$dst"
if [ -f "$dst/SHA256SUMS" ]; then
	new=$( (cd "$src" && sha256sum tools/btmgmt monitor/btmon) | awk '{print $1}' | tr '\n' ' ')
	old=$(awk '{print $1}' "$dst/SHA256SUMS" | tr '\n' ' ')
	[ "$new" = "$old" ] && { echo "ok   $dst already holds these tools"; exit 0; }
	echo "FAIL $dst holds different tools — move it away first (old: $old new: $new)"; exit 1
fi
cp "$src/tools/btmgmt" "$src/monitor/btmon" "$dst/"
(cd "$dst" && sha256sum btmgmt btmon > SHA256SUMS && cat SHA256SUMS)
echo "ok   tools copied to $dst"
