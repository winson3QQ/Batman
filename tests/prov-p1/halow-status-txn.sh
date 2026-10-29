#!/bin/bash
# tests/prov-p1/halow-status-txn.sh <halow-status> — #254 wireless-txn §4 / §11: halow-status prints
# "unfinished network change: yes|no" from /etc/batman-prov/.txn when run as root, and "unknown" when not root (the
# directory is 0700: a non-root caller cannot tell, so it must never say "no"). Runs the product under busybox ash;
# no root. Test-only edits of the copy: the .txn path in the test dir; `id` shadowed by a function (busybox applet).
# Negative control: the shipped halow-status has no such line -> every case FAILs. Zero cases run = FAIL.
set -u
HS=$(readlink -f "${1:?usage: $0 <halow-status>}")
command -v busybox >/dev/null || { echo "FAIL busybox missing"; echo "HALOW-STATUS-TXN cases=0 fails=1"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/prov" "$T/bin"
printf 'id(){ if [ "${1:-}" = -u ]; then cat "%s/uid"; else command id "$@"; fi; }\n' "$T" > "$T/fns.sh"
sed -e "1r $T/fns.sh" -e "s#^PROVTXN=/etc/batman-prov/.txn#PROVTXN=$T/prov/.txn#" "$HS" > "$T/hs"
cases=0; fails=0
ok(){ cases=$((cases + 1)); echo "PASS $*"; }; no(){ cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
line(){ PATH="$T/bin:$PATH" busybox sh "$T/hs" 2>/dev/null | grep 'unfinished network change:'; }
want(){ local d=$1 w=$2 got; got=$(line); if [ "$got" = "NETCHANGE unfinished network change: $w" ]; then ok "$d -> $w"; else no "$d: want '$w', got '$got'"; fi; }
echo 0 > "$T/uid"
rm -f "$T/prov/.txn"; want "root, no .txn" no
printf 'abc 1 2 network/join\nprev - - -\n' > "$T/prov/.txn"; want "root, .txn present" yes
: > "$T/prov/.txn"; want "root, empty .txn (presence decides)" yes
echo 1000 > "$T/uid"
want "non-root, .txn present" unknown
rm -f "$T/prov/.txn"; want "non-root, no .txn (cannot tell)" unknown
echo "HALOW-STATUS-TXN cases=$cases fails=$fails"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
