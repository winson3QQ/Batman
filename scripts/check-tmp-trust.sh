#!/bin/bash
# scripts/check-tmp-trust.sh — #280 static guard: nothing that runs as root on a node may trust a world-writable path.
#
# /tmp (and /var/lock, /var/tmp, /dev/shm = /tmp/shm) is 1777 on the nodes: any non-root process can pre-create a
# name there. Decision state lives in the root-only run dir /tmp/run/batman (usr/lib/batman/rundir.sh); temp files
# come from `batman_tmp` / `mktemp`. This check makes that rule enforced instead of remembered
# (docs/design/280-tmp-trust.md D6 + §9 N4):
#   * every line in node code (feed/**, deploy/** that lands on a node, scripts/node/**) and in the harness's
#     node-side snippets (scripts/*.sh) that names a world-writable path, a predictable temp name ($$), a
#     /var/run/batman or /run/batman spelling (fresh in the stage-2 ramfs — design B1) or `mkdir -p /tmp/`
#     must match an entry in scripts/tmp-trust-allowlist.txt (file-glob <TAB> line-ERE <TAB> reason);
#   * the run dir literal may appear ONLY in rundir.sh and the harness resolver.
# Exit 0 = clean. CHECK_TMP_TRUST_ROOT overrides the repo root (mutation tests).
set -u
ROOT=${CHECK_TMP_TRUST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
ALLOW=$ROOT/scripts/tmp-trust-allowlist.txt
cd "$ROOT" || exit 2
[ -f "$ALLOW" ] || { echo "missing $ALLOW"; exit 2; }

# world-writable dirs; predictable names next to a path; stage-2-unsafe spellings of the run dir; mkdir -p in /tmp
# /var is a symlink to tmp on the nodes, so ANY /var/<x> lands in world-writable /tmp — except the root-only dirs
# OpenWrt creates there at boot (review 3 #10): every /var/<x> is a hit, and the allowlist names the safe ones.
PAT='/tmp([^/[:alnum:]_]|/|$)|/var/[[:alnum:]_.-]+|/run/batman([^-[:alnum:]_.]|$)|/dev/shm|[[:alnum:]_./-]\$\$|\$\$[./[:alnum:]_-]|mkdir +-p +/tmp/'

files(){
	# safe.directory: run from any checkout/user (the 2026-10-09 full suite ran it on a WSL worktree from Git Bash)
	git -c safe.directory='*' ls-files -- 'feed/**' 'deploy/**' 'scripts/node/**' 'scripts/*.sh' \
	  | grep -vE '\.(md|png|jpg|svg|pdf|kicad.*|json|csv|txt)$' \
	  | grep -vE '^scripts/(check-tmp-trust\.sh|test-tmp-trust\.sh)$'
}

bad=0; n=0
# no files listed = git failed: that is an error, never "nothing untrusted" (the false green found 2026-10-09)
nf=$(files | wc -l)
[ "$nf" -gt 100 ] || { echo "check-tmp-trust: ERROR only $nf files listed from $ROOT (git failed?) — refusing to report clean"; exit 2; }
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
while IFS= read -r f; do
	[ -f "$f" ] || continue
	grep -nE -- "$PAT" "$f" 2>/dev/null | while IFS= read -r hit; do
		ln=${hit%%:*}; line=${hit#*:}
		case "$line" in *'tmp-trust: ok'*) continue;; esac   # inline waiver, must carry a reason after it
		# comments never execute: drop a whole-line comment and a trailing " # ..." before judging
		code=$(printf '%s\n' "$line" | sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^"'"'"']*$//')
		printf '%s\n' "$code" | grep -qE -- "$PAT" || continue
		line=$code
		# per HIT, not per line (review 2 #6): every allowlisted construct is cut out of the line, and the line
		# is untrusted if anything world-writable is left — an allowed mktemp must not waive a decision path
		# that happens to share its line
		rest=$line
		while IFS=$'\t' read -r glob re _why; do
			case "$glob" in ''|'#'*) continue;; esac
			# shellcheck disable=SC2254
			case "$f" in $glob) rest=$(printf '%s\n' "$rest" | sed -E "s"$'\001'"$re"$'\001'$'\001'"g");; esac
		done < "$ALLOW"
		printf '%s\n' "$rest" | grep -qE -- "$PAT" && echo "UNTRUSTED $f:$ln: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-160)"
	done
done < <(files) > "$OUT" 2>&1
n=$(grep -c "^UNTRUSTED" "$OUT")
cat "$OUT"
[ "$n" = 0 ] || bad=1

# N3: every run-dir basename the tree uses must be in the path table — node code ($RUNDIR, $_R, $PSTOP_RUN) and
# the harness ($R from the RDR resolver) must agree on the names, or a reader polls a file nobody writes
TABLE=$ROOT/scripts/rundir-paths.txt
if [ -f "$TABLE" ]; then
	nt=0
	# code only (comments dropped), then: $RUNDIR/<n>, ${RUNDIR}/<n>, ${RUNDIR:-default}/<n> (same for _R, PSTOP_RUN,
	# R), where <n> may contain $var / ${var} / <t>; plus names written through `mark <name> <value>` (review 3 #9)
	N='([A-Za-z0-9_.<>-]|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)+'
	while IFS= read -r nm; do
		case "$nm" in ''|'$'*) continue;; esac          # "$RUNDIR/$1": a generic writer, its callers are checked
		g=$(printf '%s' "$nm" | sed -E 's/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|<[a-z]+>/*/g')   # $t / ${T} / <t> -> *
		hit=0
		while IFS= read -r pat; do
			case "$pat" in ''|'#'*) continue;; esac
			# shellcheck disable=SC2254
			case "$g" in $pat) hit=1; break;; esac
			[ "$g" = "$pat" ] && { hit=1; break; }
		done < "$TABLE"
		[ "$hit" = 1 ] || { echo "NOT IN PATH TABLE: run-dir name '$nm' (add it to scripts/rundir-paths.txt with its writer/reader)"; nt=$((nt+1)); }
	done < <( { files | grep -vE '^scripts/(check|test)-tmp-trust\.sh$' | xargs sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^"'"'"']*$//' 2>/dev/null \
		| grep -oE "(\\\$(RUNDIR|_R|PSTOP_RUN|R)|\\\$\\{(RUNDIR|_R|PSTOP_RUN|R)(:-[^}]*)?\\})/$N([^/A-Za-z0-9_.<>\${}-]|\$)" \
		| sed -E 's#^\$\{?[A-Z_]+(:-[^}]*)?\}?/##; s#[^A-Za-z0-9_.<>${}-]$##'
		# `mark` = the run-dir marker helper only where 95-batman-storage defines it (the harness has an unrelated mark)
		files | grep -E '/95-batman-storage$' | xargs sed -e 's/^[[:space:]]*#.*$//' 2>/dev/null \
		| grep -oE '(^|[^A-Za-z0-9_])mark [A-Za-z0-9_.-]+' | sed -E 's#^.*mark ##'; } | sort -u)
	[ "$nt" = 0 ] || bad=1
else echo "missing $TABLE"; bad=1; fi

# review 2 BLOCKER 1: an init generated from a quoted heredoc is its OWN process — nothing of the generating
# script is inherited, so it must source rundir.sh and define every run-dir helper it calls itself
for f in feed/batman-provision/files/etc/uci-defaults/95-batman-storage deploy/provisioning/uci-defaults/95-batman-storage; do
	[ -f "$f" ] || continue
	body=$(awk "/<<'INITBODY'/{f=1;next} /^INITBODY\$/{f=0} f" "$f")
	for h in mark tmpd tmpf; do
		printf '%s\n' "$body" | grep -qE "(^|[;&|({[:space:]=])$h " || continue
		printf '%s\n' "$body" | grep -qE "^$h\(\)" || { echo "INIT HELPER MISSING: $f INITBODY calls $h but does not define it"; bad=1; }
	done
	if printf '%s\n' "$body" | grep -q 'RUNDIR' && ! printf '%s\n' "$body" | grep -q '\. /usr/lib/batman/rundir\.sh'; then
		echo "INIT HELPER MISSING: $f INITBODY uses RUNDIR without sourcing /usr/lib/batman/rundir.sh"; bad=1
	fi
done

# review 3 #3: the sysupgrade protections must be WIRED IN, not just defined — RAM_ROOT moved into the run dir at
# include time, and platform_check_image calling the input guard before anything else
PA=feed/batman-provision/files/usr/lib/batman/platform-ab.sh
if [ -f "$PA" ]; then
	grep -qE '^if batman_rundir 2>/dev/null; then RAM_ROOT=\$RUNDIR/ramroot; fi' "$PA" \
		|| { echo "GUARD NOT WIRED: $PA no longer moves RAM_ROOT into the run dir at include time"; bad=1; }
	awk '/^platform_check_image\(\) \{/{f=1} f&&/^\}/{exit} f' "$PA" | grep -qE '_ab_ramroot_guard "\$@" && _ab_check_image "\$@"' \
		|| { echo "GUARD NOT WIRED: platform_check_image does not run _ab_ramroot_guard before _ab_check_image"; bad=1; }
fi

# inline waivers must say why
w=$(files | xargs grep -nE 'tmp-trust: ok *$' 2>/dev/null)
[ -z "$w" ] || { echo "$w" | sed 's/^/WAIVER WITHOUT REASON /'; bad=1; }

echo "check-tmp-trust: $n untrusted line(s)"
exit $bad
