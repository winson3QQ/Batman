#!/bin/bash
# app/tools/check-field-build.sh [tree|so|all] [<lib.so> ...] — X3 (docs/design/254-app-s1.md §4.1 / §6): a field
# build of the BRIDGE crate (the library the app loads) carries no dev-trust.
#   tree  `cargo tree --target all` (the deps of every target platform: an android-only dep counts too) of batman-proto
#         and of the bridge with the field feature set (no features): no package may have
#         `dev-trust` or `test-vectors` enabled. Format `{p}|{f}` (each package's enabled features): the earlier
#         `cargo tree -e features,no-dev | grep dev-trust` prints 0 lines even with `--features dev-trust` (a feature
#         that enables no dependency is not an edge; measured 2026-11-14, cargo 1.99.1) — it could never fail.
#   so    builds the bridge's release library for the HOST twice (field feature set, and dev-trust as the control) and
#         looks for byte strings that only dev-gated code carries. With <lib.so> arguments it judges those files
#         instead of building (e.g. lib/arm64-v8a/libbatman_bridge.so out of a field APK).
# Each check has its control inside: the same judge on a dev-trust build must find the feature / the markers, else the
# check is blind and FAILs. FIELD_CARGO_ARGS replaces the field feature set (negative control:
# FIELD_CARGO_ARGS="--features dev-trust" must FAIL both checks).
# NOT covered: the .so inside an APK built from this tree. app/rust/bridge/cargokit.yaml passes `--features dev-trust`
# for every flavor until #255 wires the feature per flavor, so a field APK's library is a dev-trust one today (the
# startup cross-check refuses to run it); judging it here would be red by design. Printed as a NOTE, never as a PASS.
set -u
cd "$(dirname "$0")/../rust" || exit 2
CARGO=${CARGO:-cargo}
read -r -a FIELD <<< "${FIELD_CARGO_ARGS:-}"
# byte strings of dev-gated code (2026-11-14, host release build: field 0 / dev-trust >0 each):
#   "[IMPORT] "  bridge api/member.rs — the remote-invite import texts, behind dev_gate()
#   "dev:"       batman-proto nodecert.rs — the dev DAC subject prefix, compared only when DEV_TRUST
MARKERS=("[IMPORT] " "dev:")
fail=0
what=${1:-all}; [ $# -gt 0 ] && shift

feat(){ # <crate dir> [cargo args] -> the `package|features` lines with dev-trust / test-vectors enabled; rc 2 = cargo failed
	local d=$1 out; shift
	out=$(cd "$d" && $CARGO tree --target all -e no-dev -f '{p}|{f}' --prefix none "$@" 2>/dev/null) || return 2
	[ -n "$out" ] || return 2
	awk -F'|' '$NF ~ /(^|,)(dev-trust|test-vectors)(,|$)/' <<< "$out" | sort -u
}
tree(){
	local d hit ctl
	for d in batman-proto bridge; do
		hit=$(feat "$d" ${FIELD[@]+"${FIELD[@]}"}) || { echo "FAIL field feature tree ($d): cargo tree failed"; fail=1; continue; }
		ctl=$(feat "$d" --features dev-trust) || { echo "FAIL field feature tree ($d): cargo tree failed (control)"; fail=1; continue; }
		if [ -z "$ctl" ]; then echo "FAIL field feature tree ($d): the control (--features dev-trust) shows no dev-trust: the check is blind"; fail=1
		elif [ -n "$hit" ]; then echo "FAIL field feature tree ($d): $(wc -l <<< "$hit") package(s) with dev-trust / test-vectors:"; sed 's/^/  /' <<< "$hit"; fail=1
		else echo "PASS field feature tree ($d): no dev-trust / test-vectors (control: $(wc -l <<< "$ctl") package(s) with it)"; fi
	done
}
count(){ grep -c -a -F -- "$2" "$1"; } # <file> <marker> -> lines of the file holding the byte string
judge(){ # <name> <lib>: PASS only if the file is a non-empty library and holds none of the markers
	local name=$1 lib=$2 m n bad=""
	[ -s "$lib" ] || { echo "FAIL $name: no library at $lib"; fail=1; return; }
	for m in "${MARKERS[@]}"; do n=$(count "$lib" "$m"); [ "$n" = 0 ] || bad="$bad \"$m\"=$n"; done
	if [ -n "$bad" ]; then echo "FAIL $name: dev-only strings in $lib:$bad"; fail=1
	else echo "PASS $name: none of ${#MARKERS[@]} dev-only strings in $lib ($(wc -c < "$lib") bytes)"; fi
}
build(){ # <target dir> [cargo args] -> path of the built library
	local t=$1 out; shift
	out=$(cd bridge && $CARGO build --release --target-dir "$t" "$@" 2>&1) || { tail -5 <<< "$out" >&2; return 1; }
	echo "$t/release/libbatman_bridge.so"
}
so(){
	local base dev field m n blind=""
	base=$(cd bridge && pwd)/target/x3
	# the control first: a dev-trust library must hold every marker, else the markers prove nothing
	dev=$(build "$base/dev" --features dev-trust) || { echo "FAIL field .so strings: the dev-trust control did not build"; fail=1; return; }
	[ -s "$dev" ] || { echo "FAIL field .so strings: no control library at $dev"; fail=1; return; }
	for m in "${MARKERS[@]}"; do n=$(count "$dev" "$m"); [ "$n" -gt 0 ] || blind="$blind \"$m\""; done
	if [ -n "$blind" ]; then echo "FAIL field .so strings: the dev-trust control lacks$blind: the check is blind"; fail=1; return; fi
	if [ $# -gt 0 ]; then
		for field in "$@"; do judge "field .so strings ($field)" "$field"; done
	else
		field=$(build "$base/field" ${FIELD[@]+"${FIELD[@]}"}) || { echo "FAIL field .so strings: the field library did not build"; fail=1; return; }
		judge "field .so strings (host release build${FIELD_CARGO_ARGS:+, $FIELD_CARGO_ARGS})" "$field"
		if grep -qE '^\s*extra_flags:.*dev-trust' bridge/cargokit.yaml; then
			echo "NOTE field .so strings: cargokit.yaml builds every flavor with dev-trust (#255) — the .so inside a field APK is NOT judged here"
		fi
	fi
}
case $what in
	tree) tree ;;
	so) so "$@" ;;
	all) tree; so "$@" ;;
	*) echo "usage: $0 [tree|so|all] [<lib.so> ...]"; exit 2 ;;
esac
exit "$fail"
