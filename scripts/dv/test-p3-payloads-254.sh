#!/bin/bash
# scripts/dv/test-p3-payloads-254.sh [GEN] — offline test of the UD payload generators (254-v16-ud.md §3.3, §9):
# a small V in build-ab-payload order (a real squashfs from mksquashfs, boot/, boot/overlays/*.dtbo, SHA256SUMS,
# metadata) is fed to every generator of GEN (default: this checkout's scripts/dv/data/p3-payloads.sh). Each output must
# pass its own acceptance and FAIL every other kind's; the negative controls — a `tar -C dir .` repack of V, V itself,
# an empty file — must FAIL every kind; badpayload's sums_sha must differ from V's (the check FAILs on V's own SUMS).
# WSL / Linux (GNU tar, mksquashfs, python3). Prints "test-p3-payloads: N passed, M failed"; zero cases = FAIL.
set -u
H=$(cd "$(dirname "$0")/../.." && pwd)
G=${1:-$H/scripts/dv/data/p3-payloads.sh}
ACC=$H/scripts/dv/data/p3-accept.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=0; F=0; ok(){ echo "ok   $*"; P=$((P + 1)); }; no(){ echo "FAIL $*"; F=$((F + 1)); }
for c in mksquashfs tar python3 gzip; do command -v $c >/dev/null || { no "no $c"; echo "test-p3-payloads: $P passed, $F failed"; exit 1; }; done
# ---- V
mkdir -p "$T/r/etc" "$T/v/boot/overlays"; head -c 300000 /dev/urandom > "$T/r/etc/blob"; echo 'BATMAN_VERSION=1.5.14-wsl.36' > "$T/r/etc/batman-build"
mksquashfs "$T/r" "$T/v/root.squashfs" -quiet -noappend -comp gzip >/dev/null || { no mksquashfs; exit 1; }
printf 'arm_64bit=1\n' > "$T/v/boot/config.txt"; head -c 5000 /dev/urandom > "$T/v/boot/kernel8.img"
for o in a b c; do head -c 700 /dev/urandom > "$T/v/boot/overlays/$o.dtbo"; done
( cd "$T/v" && sha256sum root.squashfs && find boot -type f | sort | while read -r f; do sha256sum "$f"; done ) > "$T/v/SHA256SUMS"
printf 'board=ekh-bcm2711\nversion=x\nsize=%s\nrelease=1.5.14-wsl.36\n' "$(wc -c < "$T/v/root.squashfs")" > "$T/v/metadata"
tar -C "$T/v" -czf "$T/V.tar.gz" SHA256SUMS metadata boot root.squashfs; VS=$(sha256sum "$T/V.tar.gz" | cut -d' ' -f1)
KINDS="mal1 mal2 mal3 mal4 mutate badpayload"
acc(){ python3 -I "$ACC" "$1" "$T/V.tar.gz" "$2" > "$T/acc.out" 2>&1; }
gen(){	# <kind> -> $T/<kind>.tar.gz; the generator's last line must be PAYLOAD-SHA of the file
	local k=$1 o=$T/$1.tar.gz l
	case "$k" in mal[1-4]) l=$(bash "$G" malicious "${k#mal}" "$T/V.tar.gz" "$VS" "$o" 2>&1) ;; *) l=$(bash "$G" "$k" "$T/V.tar.gz" "$VS" "$o" 2>&1) ;; esac
	if [ "$(tail -1 <<< "$l")" = "PAYLOAD-SHA $(sha256sum "$o" 2>/dev/null | cut -d' ' -f1)" ] && grep -q "^ACCEPT $k ok$" <<< "$l"; then ok "$k: generated, accepted, PAYLOAD-SHA last"
	else no "$k: generator output [$(tail -4 <<< "$l" | tr '\n' '|')]"; fi
}
for k in $KINDS; do gen "$k"; done
# every output fails every OTHER kind (a delta of the wrong kind is no delta of this kind)
for k in $KINDS; do for j in $KINDS; do [ "$j" = "$k" ] && continue
	acc "$j" "$T/$k.tar.gz" && no "$k's output passes $j's acceptance: $(tail -2 "$T/acc.out" | tr '\n' '|')"
done; done; ok "no output passes another generator's acceptance (30 pairs)"
# negative controls: each must FAIL every kind
mkdir "$T/x"; tar -xzf "$T/V.tar.gz" -C "$T/x"; tar -C "$T/x" -czf "$T/dot.tar.gz" .
: > "$T/empty.tar.gz"; cp "$T/V.tar.gz" "$T/same.tar.gz"
for n in dot same empty; do
	c=0; for k in $KINDS; do acc "$k" "$T/$n.tar.gz" || c=$((c + 1)); done
	[ "$c" = 6 ] && ok "negative control '$n' FAILs all 6 acceptances" || no "negative control '$n' failed only $c of 6"
done
grep -q 'first two members are' <<< "$(acc mal1 "$T/dot.tar.gz"; cat "$T/acc.out")" && ok "the tar -C dir . repack FAILs on its member order (./…)" || no "dot repack: $(cat "$T/acc.out" | tr '\n' '|')"
acc badpayload "$T/same.tar.gz"; grep -q 'FAIL sums_sha equals V' "$T/acc.out" || grep -q 'FAIL root.squashfs: same sha' "$T/acc.out" \
	&& ok "badpayload check FAILs with V's own SHA256SUMS" || no "badpayload on V: $(cat "$T/acc.out" | tr '\n' '|')"
# the generators refuse an input that does not match its sha, and an empty input
l=$(bash "$G" malicious 2 "$T/V.tar.gz" 0000 "$T/z.tar.gz" 2>&1); grep -q 'FAIL p3-payloads: .*does not match the given sha' <<< "$l" && [ ! -s "$T/z.tar.gz" ] && ok "a wrong input sha is refused, nothing written" || no "wrong sha: $l"
l=$(bash "$G" mutate "$T/empty.tar.gz" "$(sha256sum "$T/empty.tar.gz" | cut -d' ' -f1)" "$T/z2.tar.gz" 2>&1); grep -q '^FAIL' <<< "$l" && ! grep -q PAYLOAD-SHA <<< "$l" && ok "an empty input is refused" || no "empty input: $l"
echo "test-p3-payloads: $P passed, $F failed"; [ $F = 0 ] && [ $P -gt 0 ]
