#!/bin/bash
# scripts/test-prov-p1-stubs.sh — #254 product stubs (no hardware): each takes the product file from THIS checkout,
# so a product change that breaks one fails here, not on a node. daily-validation runs it through self_test, which
# under Git Bash delegates to the WSL distro: the claim-lock stubs run the product under busybox ash (the node's
# shell), and Git Bash has no busybox (and no `readlink -f` of a //wsl.localhost path) — found 2026-10-27, when the
# shipped-artifact run reached these stubs for the first time and all of them failed on the HOST, not the product.
# Every failing stub prints its own FAIL lines and one "FAIL prov-p1-stubs: <stub>: <last line>"; a stub that prints
# no summary line is a FAIL too. Loop-device tests only as root with losetup (CI's prov-p1 job runs them as root).
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd); cd "$REPO" || exit 2
F=feed/batman-provision/files; T=tests/prov-p1; r=0; n=0
# stub <want ERE in the last line> <test> <args...>
stub(){ local want=$1 t=$2 o; shift 2; n=$((n + 1))
	o=$(bash "$T/$t.sh" "$@" 2>&1)
	if printf '%s\n' "$o" | tail -1 | grep -qE "$want"; then echo "ok   $t: $(printf '%s\n' "$o" | tail -1)"
	else printf '%s\n' "$o" | grep '^FAIL'; echo "FAIL prov-p1-stubs: $t: $(printf '%s\n' "$o" | tail -1 | cut -c1-160)"; r=1; fi; }
# the harness lands before the product (#290): a pre-P1 product fails every stub (that IS the negative control).
# One explicit FAIL line -> KNOWN (#254, P-U9) in the report.
[ -f "$F/usr/libexec/batman-addr-defer" ] || { echo "FAIL prov-p1-stubs: product in this checkout is pre-P1 (no usr/libexec/batman-addr-defer) — KNOWN until feat/254-p1 lands (#254)"; exit 1; }
stub 'fails=0$' addr-defer "$F/usr/libexec/batman-addr-defer"
stub 'fails=0$' autocommit-prov-case "$F/usr/bin/batman-autocommit"
stub 'fails=0$' 99zz-mesh-expect "$F/etc/uci-defaults/99zz-batman-prov-state"
stub 'fails=0$' batman-slot-addr-defer "$F/usr/sbin/batman-slot"
# #254 claim-lock fix (docs/design/254-claim-lock-fix.md §11.2)
if [ -f "$F/etc/init.d/batman-prov-lock" ]; then
	command -v busybox >/dev/null || { echo "FAIL prov-p1-stubs: no busybox on this host — the claim-lock stubs run the product under busybox ash"; r=1; }
	stub ' 0 failed$' prov-apply-lock "$F/usr/lib/batman/prov-lock.sh"
	stub 'fails=0$' prov-root-hash "$F/usr/lib/batman/prov-lock.sh"
	stub ' 0 failed$' prov-lock-init "$F/etc/init.d/batman-prov-lock" "$F/usr/lib/batman/prov-lock.sh"
	stub 'fails=0$' batman-slot-rollback-gate "$F/usr/sbin/batman-slot" "$F/usr/lib/batman/prov-lock.sh"
	stub 'fails=0$' claim-lock-lints .
else echo "FAIL prov-p1-stubs: product in this checkout predates the claim-lock fix (no etc/init.d/batman-prov-lock) — KNOWN until fix/254-claim-lock lands (#254)"; r=1; fi
stub 'fails=0$' prov-base-names scripts/node/prov-base-254.sh   # no root needed (review A-m10)
if [ "$(id -u)" = 0 ] && command -v losetup >/dev/null 2>&1; then
	for t in cfgsave-identity-freeze cfgsave-frozen-nomount cfgsave-provget-rc10; do PROV_SRC=$REPO/$F stub 'FAIL=0|PASS$' $t "$F/usr/bin/batman-config-save"; done
	stub 'fails=0$' prov-base-statecmp scripts/node/prov-base-254.sh
	stub 'fails=0$' prov-base-stateset scripts/node/prov-base-254.sh
	stub 'fails=0$' batman-slot-stage-root "$F/usr/sbin/batman-slot" "$F/usr/lib/batman/prov-lock.sh"
else echo "note: loop-device tests (config-save, prov-base compare, stage-root) skipped here — need root + losetup (CI prov-p1 / ab-card run them)"; fi
echo "PROV-P1-STUBS stubs=$n fails=$([ $r = 0 ] && echo 0 || echo some)"; [ "$n" -gt 0 ] && [ $r = 0 ]
