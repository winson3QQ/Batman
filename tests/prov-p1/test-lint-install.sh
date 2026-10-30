#!/bin/bash
# tests/prov-p1/test-lint-install.sh [repo] — negative self-test of scripts/lint-install.sh (254-p1-impl §5.1): on a copy of
# feed/batman-provision, the real tree passes, and each defect FAILs: an install line removed, a line for a missing file,
# a file installed twice. Zero cases = FAIL.
set -u
R=${1:-$(cd "$(dirname "$0")/../.." && pwd)}; L=$R/scripts/lint-install.sh; n=0; f=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fresh(){ rm -rf "$T/r"; mkdir -p "$T/r/feed"; cp -a "$R/feed/batman-provision" "$T/r/feed/"; }
want(){	# <rc> <label>
	local rc; bash "$L" "$T/r" > "$T/out" 2>&1; rc=$?; n=$((n + 1))
	if [ "$rc" = "$1" ]; then echo "ok   $2 (rc $rc)"; else echo "FAIL $2: rc $rc want $1 :: $(head -2 "$T/out" | tr '\n' ' ')"; f=$((f + 1)); fi
}
MK=$T/r/feed/batman-provision/Makefile
fresh; want 0 "the real tree"
fresh; l=$(grep -n 'INSTALL_BIN) ./files/' "$MK" | head -1 | cut -d: -f1); sed -i "${l}d" "$MK"; want 1 "one install line removed"
fresh; l=$(grep -n 'INSTALL_DATA) ./files/' "$MK" | head -1); sed -i "$(echo "$l" | cut -d: -f1)p" "$MK"; want 1 "a file installed twice"
fresh; l=$(grep -n 'INSTALL_BIN) ./files/' "$MK" | head -1 | cut -d: -f1); sed -i "${l}a\\	\$(INSTALL_BIN) ./files/usr/bin/no-such-file \$(1)/usr/bin/no-such-file" "$MK"; want 1 "an install line for a missing file"
fresh; : > "$T/r/feed/batman-provision/files/usr/bin/dv-orphan"; want 1 "a file without an install line"
echo "TEST-LINT-INSTALL cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]
