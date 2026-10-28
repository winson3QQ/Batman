#!/bin/bash
# tests/prov-p1/card-wbox.sh <repo> — #254 code review B-M2: the card writers refuse a -wbox TEST rootfs
# (scripts/lib/wbox-stamp.sh card_wbox_check) — run on real squashfs images built here with mksquashfs — and both
# writers call it before they write anything. Needs squashfs-tools. A run with zero cases FAILs.
# Negative control: a repo without scripts/lib/wbox-stamp.sh (pre-P1b) -> FAIL "missing".
set -u
R=$(cd "${1:?usage: $0 <repo>}" && pwd); L=$R/scripts/lib/wbox-stamp.sh
fails=0; cases=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
[ -f "$L" ] || { echo "FAIL $L missing"; echo "CARD-WBOX cases=0 fails=1"; exit 1; }
command -v mksquashfs >/dev/null && command -v unsquashfs >/dev/null || { echo "FAIL squashfs-tools missing"; echo "CARD-WBOX cases=0 fails=1"; exit 1; }
# shellcheck source=/dev/null
. "$L"
img(){ local d=$T/$1; rm -rf "$d"; mkdir -p "$d/etc" "$d/usr/bin"; echo x > "$d/usr/bin/x"
	case "$1" in
		release)  printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\n' > "$d/etc/batman-build" ;;
		wbox)     printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb.dirty.wbox-chan\nBATMAN_WBOX=chan\n' > "$d/etc/batman-build" ;;
		wboxonly) printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\nBATMAN_WBOX=chan\n' > "$d/etc/batman-build" ;;
		veronly)  printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb.dirty.wbox-chan\n' > "$d/etc/batman-build" ;;
		wboxempty) printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\nBATMAN_WBOX=\n' > "$d/etc/batman-build" ;;
		nostamp)  ;;
		symlink)  printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\n' > "$d/etc/real"; ln -s /etc/real "$d/etc/batman-build" ;;
	esac
	mksquashfs "$d" "$T/$1.sq" -all-root -noappend -quiet >/dev/null 2>&1 || { echo "mksquashfs $1 failed"; exit 1; }; }
want(){ local exp=$1 k=$2 m=$3 o rc; cases=$((cases+1)); o=$(card_wbox_check "$T/$k.sq" "$m" 2>&1); rc=$?
	if { [ "$exp" = write ] && [ $rc = 0 ]; } || { [ "$exp" != write ] && [ $rc != 0 ] && grep -q -- "$exp" <<< "$o"; }; then ok "$m $k -> ${exp} ($o)"; else no "$m $k: want [$exp], rc=$rc [$o]"; fi; }
for k in release wbox wboxonly veronly wboxempty nostamp symlink; do img $k; done
for m in strict lenient; do
	want write release $m; want write wboxempty $m
	for k in wbox wboxonly veronly; do want "is a -wbox TEST image" $k $m; done
done
want "no readable etc/batman-build" nostamp strict; want "no readable etc/batman-build" symlink strict
want write nostamp lenient; want write symlink lenient
cases=$((cases+1)); o=$(card_wbox_check "$T/none.sq" strict 2>&1) && no "a missing squashfs was accepted" || ok "missing squashfs -> refused ($o)"
# both writers call it before they write anything
BA=$R/scripts/build-ab-image.sh; BG=$R/scripts/build-gpt-ab-card.sh
c=$(grep -n 'card_wbox_check "$TMP/root.squashfs" strict' "$BA" | head -1 | cut -d: -f1); g=$(grep -n '^sgdisk ' "$BA" | head -1 | cut -d: -f1)
cases=$((cases+1)); [ -n "$c" ] && [ -n "$g" ] && [ "$c" -lt "$g" ] && ok "build-ab-image checks (line $c) before the GPT (line $g)" || no "build-ab-image: check [$c] not before sgdisk [$g]"
c=$(grep -n 'card_wbox_check "$SQUASH_SRC" lenient' "$BG" | head -1 | cut -d: -f1); g=$(grep -nE '^[[:space:]]*(sudo +)?(sgdisk|dd|wipefs|mkfs[.a-z0-9]*|parted)[[:space:]]' "$BG" | head -1 | cut -d: -f1)
cases=$((cases+1)); [ -n "$c" ] && [ -n "$g" ] && [ "$c" -lt "$g" ] && ok "build-gpt-ab-card checks (line $c) before it writes (line $g)" || no "build-gpt-ab-card: check [$c] not before the first write [$g]"
[ "$cases" -gt 0 ] || { echo "FAIL no case ran"; exit 1; }
echo "CARD-WBOX cases=$cases fails=$fails"; [ "$fails" = 0 ]
