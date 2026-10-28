#!/bin/bash
# lint-wbox.sh [REPO] — the #254 -wbox variants (docs/design/254-h23-harness.md §4.2, §16.15, §16.23) are well formed:
#   every tests/wbox/<name>.patch
#     - carries "# wbox <name>: <what>" and "# wbox-witness: WBOX-<name>-<8 hex>"; the witness appears >= 2 times, and
#       in a .go hunk only inside a string literal (so it is in the binary the gate greps);
#     - applies to this tree (git apply --check);
#     - touches only feed/batman-prov/ and feed/batman-provision/ (the packages the build cleans), and renames / copies
#       nothing (a rename's source would escape that check);
#     - names a new uci-defaults file 99zz-wbox-* (runs after 99zz-batman-prov-state) and a new init script wbox-*;
#   tests/wbox/helpers.list == the list derived from the patches: "<name> <tag> <kind>", tag prov_test when the patch
#   touches feed/batman-prov/src/ (and for `test`), else release; kind helper when it touches feed/batman-prov/src/ or
#   replaces the helper install (GoPackage/Package/Install/Bin removed), else same; plus "test prov_test helper".
#   protected set (§23.9): misc-* touch only usr/bin/batman-autocommit, the others none of batman-slot / -autocommit
#   (+ init) / the otatrace, rundir, bootfacts, meshjoin libs, nor name one (or autoboot.txt) in an added line; no
#   variant removes a wbox-gate line; every touched shell file parses in busybox sh (missing busybox = FAIL);
#   scripts/dv/: `nohold` only in the unit prov-wbox-nocommit-254 (pr_ota_b() in prov-254.sh exempt).
# No patch at all is a FAIL, never a pass.
set -u
R=$(cd "${1:-$(dirname "$0")/..}" && pwd)
D=$R/tests/wbox
bad=0; n=0
PROT="usr/sbin/batman-slot usr/bin/batman-autocommit etc/init.d/batman-autocommit usr/lib/batman/otatrace.sh usr/lib/batman/rundir.sh usr/lib/batman/bootfacts.sh usr/lib/batman/meshjoin.sh"
GATEPAT='wbox_stamp|wbox_gate_|WBOX_STATE|WBOX-NOCOMMIT|STAMP-UNREADABLE|holds a -wbox test image|wbox test image|(^|[^A-Za-z0-9_])_wf([^A-Za-z0-9_]|$)'
say(){ echo "lint-wbox: $*"; }
err(){ say "FAIL: $*"; bad=$((bad+1)); }
command -v busybox >/dev/null || { say "FAIL: no busybox (the sh -n check needs the node's ash; apt-get install busybox)"; exit 1; }
[ -f "$D/helpers.list" ] || { say "FAIL: no $D/helpers.list"; exit 1; }
want=$(mktemp); ns=$(mktemp); trap 'rm -f "$want" "$ns"' EXIT
echo "test prov_test helper" > "$want"
for p in "$D"/*.patch; do
	[ -f "$p" ] || continue
	n=$((n+1)); name=$(basename "$p" .patch)
	case "$name" in *[!a-z0-9-]*|test) err "$name: bad variant name"; continue ;; esac
	head -1 "$p" | grep -q "^# wbox $name: ." || err "$name: first line is not '# wbox $name: <what>'"
	wit=$(sed -n 's/^# wbox-witness: //p' "$p" | head -1)
	case "$wit" in WBOX-"$name"-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) err "$name: witness '$wit' is not WBOX-$name-<8 hex>"; wit="" ;; esac
	if [ -n "$wit" ]; then
		[ "$(grep -c -- "$wit" "$p")" -ge 2 ] || err "$name: witness appears < 2 times"
		# inside a string literal = an odd number of unescaped double quotes before the witness on that line
		gobad=$(awk -v w="$wit" '/^\+\+\+ /{f=$2} f ~ /\.go$/ && /^\+/ && (i = index($0, w)) {
			pre = substr($0, 1, i - 1); gsub(/\\\\/, "", pre); gsub(/\\"/, "", pre); q = gsub(/"/, "", pre); if (q % 2 == 0) print }' "$p")
		[ -z "$gobad" ] || err "$name: witness outside a string literal in a .go hunk: $gobad"
		goany=$(awk -v w="$wit" '/^\+\+\+ /{f=$2} f ~ /\.go$/ && /^\+/ && index($0, w) {c++} END{print c+0}' "$p")
		if grep -q '^+++ b/.*\.go$' "$p" && [ "$goany" = 0 ]; then err "$name: touches .go files but no .go line carries the witness"; fi
	fi
	git -C "$R" apply --check "$p" 2>/dev/null || err "$name: does not apply to this tree"
	git -C "$R" apply --numstat --summary "$p" > "$ns" 2>/dev/null || { err "$name: git apply cannot read it"; continue; }
	grep -qE '^(rename|copy) (from|to) ' "$p" && err "$name: renames / copies a file (not allowed: a rename's source escapes the scope check)"
	paths=$(awk -F'\t' 'NF >= 3 {print $3}' "$ns")
	[ -n "$paths" ] || err "$name: changes no file"
	for f in $paths; do
		case "$f" in feed/batman-prov/*|feed/batman-provision/*) ;; *) err "$name: touches $f (only feed/batman-prov{,ision}/)" ;; esac
	done
	# protected set (design 254-h23 §22.4 / §23.9): the two programs that decide the default slot and the files they
	# source. A misc-* variant may touch batman-autocommit only; every other variant none of them — and its added lines
	# may not name one of them or autoboot.txt either (a uci-defaults / init mutant runs as root at first boot and could
	# rewrite the gate in the overlay)
	for f in $paths; do
		case "$name" in
			misc-*) [ "$f" = feed/batman-provision/files/usr/bin/batman-autocommit ] || err "$name: a misc-* variant touches $f (only usr/bin/batman-autocommit)" ;;
			*) for q in $PROT; do [ "$f" = "feed/batman-provision/files/$q" ] && err "$name: touches the protected $q"; done ;;
		esac
	done
	case "$name" in misc-*) ;; *)
		added=$(grep '^+' "$p" | grep -v '^+++ ')
		for q in $PROT autoboot.txt; do
			echo "$added" | grep -qF -- "$q" && err "$name: an added line names the protected ${q##*/}"
		done ;;
	esac
	# no variant may remove, change or add a line of the wbox gate itself, its stamp detection (_wf) included
	# (a mutant must not take the gate out, nor override WBOX_STATE after it is set; review A-m2 / B-m2)
	gl=$(grep -E '^[-+]' "$p" | grep -vE '^(---|\+\+\+) ' | grep -E "$GATEPAT" | head -3)
	[ -z "$gl" ] || err "$name: removes / changes / adds a wbox-gate line: $(echo "$gl" | tr '\n' ' ' | cut -c1-160)"
	# every touched shell file still parses in busybox ash (the node's sh; CI's sh is dash): applied to a scratch copy
	sx=$(mktemp -d)
	for f in $paths; do mkdir -p "$sx/$(dirname "$f")"; [ -f "$R/$f" ] && cp "$R/$f" "$sx/$f"; done
	if (cd "$sx" && git apply "$p" 2>/dev/null); then
		for f in $paths; do
			[ -f "$sx/$f" ] || continue
			case "$f" in *.go) continue ;; esac
			case "$f" in */etc/uci-defaults/*|*/etc/init.d/*|*.sh) ;; *) head -c 9 "$sx/$f" | grep -q '^#!/bin/sh' || continue ;; esac
			o=$(busybox sh -n "$sx/$f" 2>&1) || err "$name: $f does not parse in busybox sh: $(echo "$o" | head -1)"
		done
	else
		err "$name: cannot apply to a scratch copy for the sh -n check"
	fi
	rm -rf "$sx"
	for f in $(grep '^+++ b/' "$p" | sed 's#^+++ b/##'); do
		grep -q -- "^--- /dev/null" <(grep -B1 -F "+++ b/$f" "$p") || continue   # only NEW files
		case "$f" in
			*/files/etc/uci-defaults/*) case "${f##*/}" in 99zz-wbox-*) ;; *) err "$name: new uci-defaults file ${f##*/} (want 99zz-wbox-*)" ;; esac ;;
			*/files/etc/init.d/*) case "${f##*/}" in wbox-*) ;; *) err "$name: new init script ${f##*/} (want wbox-*)" ;; esac ;;
		esac
	done
	tag=release; kind=same
	echo "$paths" | grep -q '^feed/batman-prov/src/' && { tag=prov_test; kind=helper; }
	grep -q '^-.*GoPackage/Package/Install/Bin' "$p" && kind=helper
	echo "$name $tag $kind" >> "$want"
done
[ "$n" -gt 0 ] || err "no tests/wbox/*.patch at all"
have=$(grep -v '^[[:space:]]*#' "$D/helpers.list" | sed '/^[[:space:]]*$/d' | awk '{print $1, $2, $3}' | sort)
exp=$(sort "$want")
if [ "$have" != "$exp" ]; then err "tests/wbox/helpers.list differs from the patches:"; diff <(echo "$exp") <(echo "$have") | sed 's/^/  /'; fi
# nohold (§21 / §23.9): `pr_ota_b … nohold` (a trial without the hold flag) only in the unit prov-wbox-nocommit-254.
# Exempt: the body of pr_ota_b() in scripts/dv/prov-254.sh (its definition). Any other use in scripts/dv/ FAILs; a
# use counts as in the unit when the nearest function / case arm above it is named prov-wbox-nocommit-254.
if [ -d "$R/scripts/dv" ]; then
	nh=$(awk '
		FNR == 1 { infn = 0; owner = "" }
		/^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/ { owner = $1; if (FILENAME ~ /\/prov-254\.sh$/ && $1 ~ /^pr_ota_b/) infn = 1 }
		/^[[:space:]]*[a-z0-9-]+\)[[:space:]]/ { owner = $1 }
		infn && /^}/ { infn = 0; next }
		/^[[:space:]]*#/ { next }
		/(^|[^A-Za-z0-9_-])nohold([^A-Za-z0-9_-]|$)/ && !infn && owner !~ /^prov[-_]wbox[-_]nocommit[-_]254/ { print FILENAME ":" FNR }
	' "$R"/scripts/dv/*.sh 2>/dev/null)
	[ -z "$nh" ] || err "nohold used outside the unit prov-wbox-nocommit-254: $(echo "$nh" | sed "s#$R/##" | tr '\n' ' ')"
fi
if [ $bad = 0 ]; then say "ok ($n patches + test; helpers.list matches)"; exit 0; fi
say "$bad problem(s)"; exit 1
