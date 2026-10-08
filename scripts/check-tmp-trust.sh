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
PAT='/tmp([^/[:alnum:]_]|/|$)|/var/(run|lock|tmp)([^[:alnum:]_]|$)|/run/batman([^-[:alnum:]_.]|$)|/dev/shm|[[:alnum:]_./-]\$\$|\$\$[./[:alnum:]_-]|mkdir +-p +/tmp/'

files(){
	git ls-files -- 'feed/**' 'deploy/**' 'scripts/node/**' 'scripts/*.sh' \
	  | grep -vE '\.(md|png|jpg|svg|pdf|kicad.*|json|csv|txt)$' \
	  | grep -vE '^scripts/(check-tmp-trust\.sh|test-tmp-trust\.sh)$'
}

bad=0; n=0
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
		ok=0
		while IFS=$'\t' read -r glob re _why; do
			case "$glob" in ''|'#'*) continue;; esac
			# shellcheck disable=SC2254
			case "$f" in $glob) printf '%s\n' "$line" | grep -qE -- "$re" && { ok=1; break; };; esac
		done < "$ALLOW"
		[ "$ok" = 1 ] || echo "UNTRUSTED $f:$ln: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-160)"
	done
done < <(files) > "$OUT" 2>&1
n=$(grep -c "^UNTRUSTED" "$OUT")
cat "$OUT"
[ "$n" = 0 ] || bad=1

# inline waivers must say why
w=$(files | xargs grep -nE 'tmp-trust: ok *$' 2>/dev/null)
[ -z "$w" ] || { echo "$w" | sed 's/^/WAIVER WITHOUT REASON /'; bad=1; }

echo "check-tmp-trust: $n untrusted line(s)"
exit $bad
