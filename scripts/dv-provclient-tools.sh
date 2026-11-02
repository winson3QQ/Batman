#!/bin/bash
# scripts/dv-provclient-tools.sh — build the #254 provclient test tool (tests/tools/provclient) reproducibly, in WSL:
# vendored modules only (-mod=vendor, GOTOOLCHAIN=local), -trimpath; the amd64 build's selftest against the 219
# protocol vectors must pass first. Writes provclient-amd64 (WSL signer side) + provclient-arm64 (pushed to the node)
# + SHA256SUMS + SOURCE (the commit and tree state they were built from) to both:
#   $DV_PROV_TOOLS_WSL (default /home/yello/batman-dv-tools/prov)  and  $DV_PROV_TOOLS (default
#   /mnt/c/Users/yello/batman-dv-tools/prov, the Git Bash harness's DV_PROV_TOOLS).
# GO = the firmware tree's Go by default (the same toolchain as the helper).
set -eu
REPO=$(cd "$(dirname "$0")/.." && pwd)
GO=${GO:-/home/yello/firmware-2710/staging_dir/hostpkg/lib/go-1.26/bin/go}
OUTW=${DV_PROV_TOOLS_WSL:-/home/yello/batman-dv-tools/prov}; OUTH=${DV_PROV_TOOLS:-/mnt/c/Users/yello/batman-dv-tools/prov}
[ -x "$GO" ] || { echo "FAIL no Go at $GO"; exit 1; }
export GOTOOLCHAIN=local GOFLAGS=-mod=vendor CGO_ENABLED=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$REPO/tests/tools/provclient"
"$GO" vet . || { echo "FAIL go vet"; exit 1; }
"$GO" build -trimpath -ldflags='-s -w' -o "$T/provclient-amd64" .
GOARCH=arm64 "$GO" build -trimpath -ldflags='-s -w' -o "$T/provclient-arm64" .
"$T/provclient-amd64" selftest "$REPO/tests/vectors/219-protocol/vectors.json" | tail -1 | grep -qx 'selftest: pass=11 fail=0' \
	|| { echo "FAIL provclient selftest"; "$T/provclient-amd64" selftest "$REPO/tests/vectors/219-protocol/vectors.json" | grep FAIL; exit 1; }
d=$(git -C "$REPO" status --porcelain -- tests/tools/provclient | wc -l)
{ echo "commit=$(git -C "$REPO" rev-parse HEAD)"; echo "provclient_uncommitted_files=$d"; echo "go=$("$GO" version)"; } > "$T/SOURCE"
(cd "$T" && sha256sum provclient-amd64 provclient-arm64 SOURCE > SHA256SUMS)
for o in "$OUTW" "$OUTH"; do
	mkdir -p "$o"
	cp "$T"/provclient-amd64 "$T"/provclient-arm64 "$T"/SOURCE "$T"/SHA256SUMS "$o"/
	(cd "$o" && sha256sum -c --quiet SHA256SUMS) || { echo "FAIL copy to $o does not verify"; exit 1; }
	chmod 755 "$o"/provclient-amd64 "$o"/provclient-arm64 2>/dev/null || true   # /mnt/c (DrvFs) keeps its own modes; the node copy is chmod-ed there
done
echo "provclient tools: $(cut -c1-16 "$T/SHA256SUMS" | tr '\n' ' ') -> $OUTW, $OUTH ($(cat "$T/SOURCE" | tr '\n' ' '))"
