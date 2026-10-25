#!/bin/bash
# scripts/dv-bt305-tools.sh — build the #305 test tools for ONE firmware commit into the harness's own directory, with
# SHA256SUMS (docs/design/305-mini-uart-flow.md §8 / §8a). They are test tools: never part of an image.
#
#   scripts/dv-bt305-tools.sh <firmware tree> [dest]          (run where the firmware tree builds: WSL / Linux)
#
#   btprobe, hciflood            static arm64 Go binaries (tools/bt305/)
#   r305raw.ko                   CNTL reader / writer (tools/bt305/r305raw), built against the tree's kernel
#   hci_uart-noP2.ko             hci_uart WITHOUT patch 999-batman-hci_bcm-close-flow-305 — the negative control of
#                                T3 / T3b. Built OUT OF TREE from a copy of build_dir/.../drivers/bluetooth with only
#                                P2 reversed; the product build_dir is never touched (A v6 m3).
#   FWCOMMIT                     the firmware commit these were built from. There are no MODVERSIONS: vermagic
#                                ("6.6.138 SMP mod_unload aarch64") cannot tell two trees apart, so the harness only
#                                insmods a module whose FWCOMMIT equals the node's BATMAN_FW_COMMIT (B v5 m3).
#
# dest defaults to ${DV_BT305_TOOLS_ROOT:-$HOME/batman-dv-tools}/bt305-<fwcommit>. Refuses to overwrite a different copy.
set -euo pipefail
fw=${1:?usage: dv-bt305-tools.sh <firmware tree> [dest]}
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$fw"
fwc=$(git rev-parse --short=7 HEAD)
[ -z "$(git status --short -- target package include)" ] || { echo "FAIL $fw has uncommitted changes in target/package/include"; exit 1; }
P2=target/linux/bcm27xx/patches-6.6/999-batman-hci_bcm-close-flow-305.patch
[ -f "$P2" ] || { echo "FAIL $P2 missing: this firmware commit carries no #305 patch"; exit 1; }
K=$(ls -d "$fw"/build_dir/target-aarch64_cortex-a72_musl/linux-bcm27xx_bcm2711/linux-6.* | head -1)
[ -d "$K" ] || { echo "FAIL no bcm2711 kernel build dir under $fw/build_dir"; exit 1; }
grep -q 'Batman #305' "$K/drivers/bluetooth/hci_bcm.c" || { echo "FAIL $K/drivers/bluetooth/hci_bcm.c does not carry P2 — build the board first"; exit 1; }
grep -q 'dev_groups = bcm2835aux_groups' "$K/drivers/tty/serial/8250/8250_bcm2835aux.c" || { echo "FAIL build_dir 8250_bcm2835aux.c is not the frozen P1"; exit 1; }
dst=${2:-${DV_BT305_TOOLS_ROOT:-$HOME/batman-dv-tools}/bt305-$fwc}
GO=$(ls -d "$fw"/staging_dir/hostpkg/lib/go-*/bin | tail -1)
TC=$(ls -d "$fw"/staging_dir/toolchain-aarch64_cortex-a72_*_musl/bin | head -1)
export PATH=$GO:$TC:$fw/staging_dir/host/bin:$PATH STAGING_DIR=$fw/staging_dir GOTOOLCHAIN=local GOFLAGS=-mod=mod
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

for t in btprobe hciflood; do
	mkdir "$W/$t"; cp "$here/tools/bt305/$t/main.go" "$W/$t/"
	(cd "$W/$t" && go mod init "$t" >/dev/null 2>&1 && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags=-s -o "$t" .)
done

mkdir "$W/r305raw"; cp "$here/tools/bt305/r305raw/r305raw.c" "$W/r305raw/"; echo 'obj-m := r305raw.o' > "$W/r305raw/Makefile"
make -s -C "$K" M="$W/r305raw" ARCH=arm64 CROSS_COMPILE=aarch64-openwrt-linux-musl- modules >/dev/null

mkdir "$W/bt"; cp -a "$K/drivers/bluetooth/." "$W/bt/"; rm -f "$W"/bt/*.o "$W"/bt/*.ko "$W"/bt/.*.cmd "$W"/bt/*.mod* "$W"/bt/modules.order
# reverse only the hci_bcm.c part of P2 (the patch touches no other file)
patch --batch -R -s "$W/bt/hci_bcm.c" < "$fw/$P2"
grep -q 'Batman #305' "$W/bt/hci_bcm.c" && { echo "FAIL could not reverse P2 in the copy"; exit 1; }
make -s -C "$K" M="$W/bt" ARCH=arm64 CROSS_COMPILE=aarch64-openwrt-linux-musl- modules >/dev/null 2>&1 || true
[ -f "$W/bt/hci_uart.ko" ] || { echo "FAIL out-of-tree hci_uart.ko did not build"; exit 1; }

mkdir -p "$W/out"
cp "$W/btprobe/btprobe" "$W/hciflood/hciflood" "$W/r305raw/r305raw.ko" "$W/out/"
cp "$W/bt/hci_uart.ko" "$W/out/hci_uart-noP2.ko"
echo "$fwc" > "$W/out/FWCOMMIT"
(cd "$W/out" && sha256sum btprobe hciflood r305raw.ko hci_uart-noP2.ko FWCOMMIT > SHA256SUMS)
# (no `grep -q` under pipefail: it exits early, strings gets SIGPIPE and the pipeline "fails")
for m in r305raw.ko hci_uart-noP2.ko; do strings "$W/out/$m" | grep '^vermagic=6\.6\.' >/dev/null || { echo "FAIL $m has no 6.6 vermagic"; exit 1; }; done

if [ -f "$dst/SHA256SUMS" ]; then
	cmp -s "$dst/SHA256SUMS" "$W/out/SHA256SUMS" && { echo "ok   $dst already holds these tools (firmware $fwc)"; exit 0; }
	echo "FAIL $dst holds different tools for $fwc — move it away first"; exit 1
fi
mkdir -p "$dst"; cp "$W/out/"* "$dst/"
cat "$dst/SHA256SUMS"; echo "ok   #305 tools for firmware $fwc in $dst"
