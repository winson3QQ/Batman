#!/bin/bash
# scripts/lint-install.sh [repo] — #254 lint-install (254-p1-impl §5.1): every file under feed/batman-provision/files has
# exactly one Makefile install line (`$(INSTALL_BIN|DATA) ./files/<path> $(1)/<dst>`), and every install line names a
# file that exists. dv-sbx lays the files over its base by these lines, so a file without one would be tested
# but never shipped. Zero files or zero lines FAILs.
set -u
R=${1:-$(cd "$(dirname "$0")/.." && pwd)}; F=$R/feed/batman-provision; bad=0
[ -f "$F/Makefile" ] && [ -d "$F/files" ] || { echo "FAIL lint-install: no $F/Makefile or files/"; exit 1; }
lines=$(grep -oE '\$\(INSTALL_(BIN|DATA)\)[[:space:]]+\./files/[^[:space:]]+' "$F/Makefile" | awk '{print $2}' | sed 's#^\./files/##' | sort)
files=$(cd "$F/files" && find . -type f | sed 's#^\./##' | sort)
[ -n "$lines" ] && [ -n "$files" ] || { echo "FAIL lint-install: no install lines or no files"; exit 1; }
d=$(printf '%s\n' "$lines" | uniq -d); [ -z "$d" ] || { echo "FAIL lint-install: installed twice: $d"; bad=1; }
m=$(comm -23 <(printf '%s\n' "$files") <(printf '%s\n' "$lines" | sort -u)); [ -z "$m" ] || { echo "FAIL lint-install: no install line for: $(echo $m)"; bad=1; }
x=$(comm -13 <(printf '%s\n' "$files") <(printf '%s\n' "$lines" | sort -u)); [ -z "$x" ] || { echo "FAIL lint-install: install line for a missing file: $(echo $x)"; bad=1; }
[ $bad = 0 ] && echo "lint-install: ok ($(printf '%s\n' "$files" | wc -l) files, each with one install line)"
exit $bad
