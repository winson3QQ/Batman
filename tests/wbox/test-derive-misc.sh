#!/bin/bash
# tests/wbox/test-derive-misc.sh [<V-autocommit>] — #254 g4 §2 / §13.4 / §13.5: the host-derived misc-* autocommit
# mutants (scripts/lib/wbox-derive.sh derive_misc) discriminate, each on ITS case of tests/prov-p1/autocommit-mesh-arm.sh.
#   base = <V-autocommit> (default: this tree's feed/batman-provision/files/usr/bin/batman-autocommit, as in CI).
#   For every misc-* row of tests/wbox/helpers.list:
#     - derive_misc succeeds;
#     - autocommit-mesh-arm.sh <derived> FAILs, and the FAIL line is the case named for that mutant (the case string is
#       read from autocommit-mesh-arm.sh by its key below; a key with no / several matching cases is a FAIL), so a
#       broken extraction cannot pass vacuously;
#   the real base PASSes autocommit-mesh-arm.sh.
#   Negative fixtures (each must FAIL for its own reason): an output with a CR byte; a run whose work dir is inside a
#   git work tree; a patch that does not fit the base; zero misc rows; a misc row with no named case; a mutant that
#   does not make its case FAIL.
# Runs in CI (ci.yml, next to autocommit-mesh-arm) and in WSL from scripts/test-h4-offline-254.sh.
#   -> "TEST-DERIVE-MISC: N passed, M failed", rc 1 on any FAIL
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/wbox-derive.sh
. "$R/scripts/lib/wbox-derive.sh"
BASE=${1:-$R/$WBOX_DERIVE_PATH}
MA=$R/tests/prov-p1/autocommit-mesh-arm.sh
L=$R/tests/wbox/helpers.list
P=0; F=0
tok(){ echo "ok   $*"; P=$((P + 1)); }
tbad(){ echo "FAIL $*"; F=$((F + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# the case each mutant must FAIL: a unique prefix of its case string in autocommit-mesh-arm.sh
casekey(){ case "$1" in
	misc-l38) echo "L38 helper never comes -> 60 polls" ;;        # the wait loop deleted: 0 polls
	misc-l38r) echo "L38 helper comes at poll 5" ;;               # waits, never re-reads: the helper's line is not adopted
	misc-l42) echo "L42 member without an arm file" ;;
	misc-l43) echo "L43 arm file of another boot" ;;
	misc-l51) echo "L51 arm file saying joined" ;;
	*) return 1 ;;
esac; }
# caseof <name> -> the full case string read from autocommit-mesh-arm.sh; rc 1 (with a reason) when not exactly one
caseof(){ local k m n
	k=$(casekey "$1") || { echo "no case named for $1 in test-derive-misc.sh"; return 1; }
	m=$(grep -oE "expect \"[^\"]*\"" "$MA" | sed 's/^expect "//; s/"$//' | grep -F -- "$k" | grep -E "^$(printf '%s' "$k" | sed 's/[][\.*^$()|+?{}]/\\&/g')")
	n=$(grep -c . <<< "$m")
	[ -n "$m" ] && [ "$n" = 1 ] || { echo "case key [$k] of $1 matches $n case(s) in $MA"; return 1; }
	echo "$m"; }
# rows <list> <base> <patchdir>: the per-row checks; prints ok / FAIL lines, rc 1 on any FAIL or zero rows
rows(){
	local list=$1 base=$2 pd=$3 name tag kind n=0 bad=0 c o rc
	while read -r name tag kind; do
		case "$name" in misc-*) ;; *) continue ;; esac
		n=$((n + 1))
		c=$(caseof "$name") || { echo "FAIL $name: $c"; bad=$((bad + 1)); continue; }
		o=$(derive_misc "$base" "$pd/$name.patch" "$T/out/$name") || { echo "FAIL $name: $o"; bad=$((bad + 1)); continue; }
		o=$(bash "$MA" "$T/out/$name/batman-autocommit" 2>&1); rc=$?
		if [ "$rc" != 0 ] && grep -qF -- "FAIL $c —" <<< "$o"; then echo "ok   $name: derived, and FAILs its case [$c] ($(tail -1 <<< "$o"))"
		else echo "FAIL $name: autocommit-mesh-arm rc $rc, its case [$c] did not FAIL: $(grep -E '^FAIL|AUTOCOMMIT-MESH-ARM' <<< "$o" | tr '\n' '|' | cut -c1-300)"; bad=$((bad + 1)); fi
	done < "$list"
	[ "$n" -gt 0 ] || { echo "FAIL zero misc-* rows in $list"; return 1; }
	[ "$bad" = 0 ]
}
[ -f "$BASE" ] && [ -f "$MA" ] && [ -f "$L" ] || { tbad "missing input: base $BASE / $MA / $L"; echo "TEST-DERIVE-MISC: $P passed, $F failed"; exit 1; }
echo "base: $BASE ($(sha256sum < "$BASE" | cut -c1-16))"
# ---- the real rows
o=$(rows "$L" "$BASE" "$R/tests/wbox"); rc=$?; echo "$o" | sed 's/^/  /'
nrows=$(grep -c '^misc-' "$L")
if [ "$rc" = 0 ] && [ "$(grep -c '^ok   misc-' <<< "$o")" = "$nrows" ] && [ "$nrows" -gt 0 ]; then tok "every misc-* row ($nrows) derives and FAILs its named case"; else tbad "misc-* rows (rc $rc, $nrows rows)"; fi
o=$(bash "$MA" "$BASE" 2>&1); rc=$?
if [ "$rc" = 0 ] && grep -qE '^AUTOCOMMIT-MESH-ARM cases=[1-9][0-9]* fails=0$' <<< "$o"; then tok "the real base PASSes: $(tail -1 <<< "$o")"; else tbad "the real base (rc $rc): $(tail -2 <<< "$o" | tr '\n' '|')"; fi
# ---- negative fixtures. want <label> <expected text> <cmd...>: rc != 0 AND the expected text (its own reason)
want(){ local l=$1 e=$2 o rc; shift 2; o=$("$@" 2>&1); rc=$?
	if [ "$rc" != 0 ] && grep -qF -- "$e" <<< "$o"; then tok "negative: $l -> FAIL ($(grep -F -- "$e" <<< "$o" | head -1 | cut -c1-160))"
	else tbad "negative: $l (rc $rc, want [$e]): $(tr '\n' '|' <<< "$o" | cut -c1-300)"; fi; }
mkdir -p "$T/fx"
# (1) CR in the output: the witness line of misc-l38's patch carried in with a CR
sed '/^+# WBOX-misc-l38-/s/$/\r/' "$R/tests/wbox/misc-l38.patch" > "$T/fx/crlf.patch"
[ "$(tr -dc '\r' < "$T/fx/crlf.patch" | wc -c)" = 1 ] || tbad "fixture: crlf.patch has no CR"
want "an output with a CR byte" "CR byte" derive_misc "$BASE" "$T/fx/crlf.patch" "$T/fx/o1"
[ -e "$T/fx/o1/batman-autocommit" ] && tbad "negative: a failed derive left batman-autocommit behind"
# (2) the work dir inside a git work tree (TMPDIR in a repo: mktemp -d lands there)
mkdir -p "$T/wt" && git -C "$T/wt" init -q
want "a work dir inside a git work tree" "inside a git work tree" env TMPDIR="$T/wt" bash -c '. "$1"; derive_misc "$2" "$3" "$4"' _ "$R/scripts/lib/wbox-derive.sh" "$BASE" "$R/tests/wbox/misc-l38.patch" "$T/fx/o2"
# (3) a patch that does not fit (an older V: the L38 wait loop reads differently)
sed 's/^while \[ "\${pr%% \*}" = 99zz \] && \[ "\$i" -lt 60 \]/while [ "${pr%% *}" = 99zz ] \&\& [ "$i" -lt 30 ]/' "$BASE" > "$T/fx/old-ac"
cmp -s "$BASE" "$T/fx/old-ac" && tbad "fixture: old-ac equals the base"
want "a patch that does not fit the base" "apply --check rc" derive_misc "$T/fx/old-ac" "$R/tests/wbox/misc-l38.patch" "$T/fx/o3"
# (4) zero misc rows
grep -v '^misc-' "$L" > "$T/fx/nomisc.list"
want "zero misc-* rows" "zero misc-* rows" rows "$T/fx/nomisc.list" "$BASE" "$R/tests/wbox"
# (5) a misc row with no named case
mkdir -p "$T/fx/pd"; cp "$R/tests/wbox/misc-l38.patch" "$T/fx/pd/misc-lzz.patch"; echo "misc-lzz release same" > "$T/fx/zz.list"
want "a misc row with no named case" "no case named for misc-lzz" rows "$T/fx/zz.list" "$BASE" "$T/fx/pd"
# (6) a mutant that does not make its case FAIL: misc-l42's case fed with misc-l38r's patch (that case still passes)
cp "$R/tests/wbox/misc-l38r.patch" "$T/fx/pd/misc-l42.patch"; echo "misc-l42 release same" > "$T/fx/nd.list"
want "a mutant whose named case still passes" "did not FAIL" rows "$T/fx/nd.list" "$BASE" "$T/fx/pd"
echo "TEST-DERIVE-MISC: $P passed, $F failed"; [ "$F" = 0 ] && [ "$P" -gt 0 ]
