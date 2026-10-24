#!/bin/bash
# scripts/bt-uart-305-flip.sh — the #305 negative controls, run BY HAND (never from daily-validation; the node script
# refuses --flip unless BT305_FLIP_OK=1, which only this script sets). docs/design/305-mini-uart-flow.md §8 pt 3, §8a.
#
#   scripts/bt-uart-305-flip.sh flip  <node> [t1 t2 t3 t3b]    on an rc (marker + autoflow): each test with --flip
#   scripts/bt-uart-305-flip.sh force <node> [t1 t2]           on a pre-#305 image (wsl.15): BT305_FORCE=1, real judges
#
# A flip is VALID only if the test failed through ITS OWN detection lines (A v6 m1):
#   T1  "FAIL autoflow missing"                          T2  "FAIL det-oe" AND "FAIL det-txto", and no "FAIL load-"
#   T3  "FAIL seq-unbind"                                 T3b "FLIP close waited", and no "flip-invalid"
# A FAIL for another reason (load guarantee, kmsg capture, staging) makes the flip INVALID = this script FAILs.
# Env: REPO (default: this checkout), BT305_LOAD_SECS (T2, default 1800), DV_BT305_TOOLS_ROOT.
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
. "$REPO/scripts/dv/bt-uart-305.sh"
mode=${1:?usage: bt-uart-305-flip.sh flip|force <node> [tests]}; node=${2:?node}; shift 2
tests=${*:-t1 t2 t3 t3b}
case "$mode" in
	flip) export BT305_FLIP_OK=1 BT305_FLIP_ARG=--flip ;;
	force) export BT305_FORCE=1 BT305_FLIP_ARG= ;;
	*) echo "FAIL mode must be flip or force"; exit 2 ;;
esac
rc=0
for t in $tests; do
	echo "===== $t ($mode on $node)"
	case "$t" in
		t1) o=$(chk_bt_uart_flow_305 "$node" 2>&1); echo "$o"; bt305_verdict T1 "$o" '' '^FAIL autoflow missing' ;;
		t2) o=$(bchk_bt_uart_load_305 "$node" 2>&1); echo "$o"; bt305_verdict T2 "$o" '^FAIL (load-|kmsg capture)' '^FAIL det-oe' '^FAIL det-txto' ;;
		t3) [ "$mode" = flip ] || { echo "t3 runs only as flip"; continue; }
		    o=$(chk_bt_uart_rebind_305 "$node" 2>&1); echo "$o"; bt305_verdict T3 "$o" '' '^FAIL seq-unbind' ;;
		t3b) [ "$mode" = flip ] || { echo "t3b runs only as flip"; continue; }
		     o=$(bchk_bt_uart_close_305 "$node" 2>&1); echo "$o"; bt305_verdict T3b "$o" 'flip-invalid' '^FLIP close waited' ;;
		*) echo "FAIL unknown test $t"; rc=1 ;;
	esac
done
exit $rc
