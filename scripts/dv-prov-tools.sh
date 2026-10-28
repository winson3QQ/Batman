#!/bin/bash
# scripts/dv-prov-tools.sh <V> — #254 (docs/design/254-h23-harness.md §2.2, §4.2): the test helpers the prov units push
# (prov-wbox-254.sh push-helper / upper-helper), taken from the -wbox payloads of rc V and nothing else:
#   for every variant of tests/wbox/helpers.list (+ test): <out>/<V>.dirty.wbox-<name>/ekh-bcm2711 must match its
#   SHA256SUMS; its rootfs's usr/bin/batman-provhelper is read (WSL unsquashfs; F44: needs a seekable file);
#     kind helper -> written to $DEST/<V>/<name>/batman-provhelper + SHA256SUMS, and its sha must differ from the
#                    release helper (the normal build V) and from every other helper variant;
#     kind same   -> its sha must EQUAL the release helper (nothing written).
# DEST defaults to ~/batman-dv-tools/prov-test. Any payload missing / not matching = FAIL (never a partial set).
# Runs from Git Bash (or WSL); unsquashfs runs in WSL.
set -u
V=${1:?usage: dv-prov-tools.sh <V = the normal rc version, e.g. 1.5.14-wsl.8+eee3f3a.fwccd0974>}
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
OUT=${PR_OUT:-//wsl.localhost/Ubuntu-24.04/home/yello/out}; OUTW=${PR_OUT_WSL:-/home/yello/out}
DEST=${DV_PROV_TEST:-$HOME/batman-dv-tools/prov-test}
REPO_WSL=${REPO#//wsl.localhost/Ubuntu-24.04}   # scripts/dv/wsl-rootfs.sh as WSL sees it
fails=0; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
wslx(){ if command -v wsl.exe >/dev/null 2>&1; then MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-24.04 -u yello -- "$@"; else "$@"; fi; }
# helper_of <version> <file>: the payload's helper into <file>; rc 1 when the payload / sums / extraction fail
helper_of(){
	local v=$1 d="$OUT/$1/ekh-bcm2711" p s
	p=$d/batman-$v-ekh-bcm2711-ab-payload.tar.gz
	[ -f "$p" ] && [ -f "$d/SHA256SUMS" ] || { no "$v: no payload / SHA256SUMS in $d"; return 1; }
	s=$(sha256sum < "$p" | cut -c1-64)
	grep -q "^$s  batman-$v-ekh-bcm2711-ab-payload\.tar\.gz\$" "$d/SHA256SUMS" || { no "$v: payload does not match its SHA256SUMS"; return 1; }
	# a script file, not an inline bash -c: wsl.exe expands the $variables of an inline command (run 1 on wsl.9,
	# 2026-10-28: $t came out empty -> "root.squashfs: Cannot open")
	wslx bash "$REPO_WSL/scripts/dv/wsl-rootfs.sh" cat "$OUTW/$v/ekh-bcm2711/batman-$v-ekh-bcm2711-ab-payload.tar.gz" usr/bin/batman-provhelper < /dev/null > "$2" \
		&& [ -s "$2" ] || { no "$v: cannot read usr/bin/batman-provhelper from its rootfs"; return 1; }
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
helper_of "$V" "$T/release" || { echo "PROV-TOOLS fails=$fails"; exit 1; }
REL=$(sha256sum < "$T/release" | cut -c1-64); echo "release helper ($V): ${REL:0:16}"
L=$REPO/tests/wbox/helpers.list; [ -f "$L" ] || { no "no $L"; echo "PROV-TOOLS fails=$fails"; exit 1; }
n=0; seen=" "
# the list on fd 3: wsl.exe reads stdin, and on fd 0 it ate the rest of the list (wsl.9 run 2, 2026-10-28: variants=1, fails=0)
while read -r name tag kind <&3; do
	case "$name" in ''|\#*) continue ;; esac
	case "$name" in misc-*) continue ;; esac   # dry-run only: never installed, no helper pushed (§19.3)
	n=$((n + 1)); v="$V.dirty.wbox-$name"
	helper_of "$v" "$T/$name" || continue
	h=$(sha256sum < "$T/$name" | cut -c1-64)
	case "$kind" in
		same) [ "$h" = "$REL" ] && echo "ok   $name ($tag same): helper == release" || no "$name is 'same' but its helper ${h:0:16} != release ${REL:0:16}" ;;
		helper)
			[ "$h" != "$REL" ] || { no "$name is a helper variant but its helper == release"; continue; }
			case "$seen" in *" $h "*) no "$name: helper ${h:0:16} equals another variant's"; continue ;; esac; seen="$seen$h "
			mkdir -p "$DEST/$V/$name" && cp "$T/$name" "$DEST/$V/$name/batman-provhelper" \
				&& (cd "$DEST/$V/$name" && sha256sum batman-provhelper > SHA256SUMS && sha256sum -c --quiet SHA256SUMS) \
				&& echo "ok   $name ($tag helper): ${h:0:16} -> $DEST/$V/$name" || no "$name: write to $DEST/$V/$name" ;;
		*) no "$name: helpers.list kind [$kind]" ;;
	esac
done 3< "$L"
want=$(grep -cvE "^(#|$|misc-)" "$L")
[ "$n" -gt 0 ] && [ "$n" = "$want" ] || no "read $n variants of $want in $L"
echo "PROV-TOOLS $V variants=$n fails=$fails"; [ "$fails" = 0 ]
