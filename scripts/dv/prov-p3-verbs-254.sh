#!/bin/bash
# scripts/dv/prov-p3-verbs-254.sh — #254 H4 appendix A, the W control of the helper-level rows (p3-how.tsv "h"):
# every helper verb that P3 adds must EXIST. Each is called bare (no arguments) by provclient on the helper socket:
#   a pre-P3 helper answers EUnsupported (6)  -> FAIL <row>: <verb> E_UNSUPPORTED   (the W line of that row, §6.2)
#   a P3 helper answers anything else (a bare call is a schema error there)        -> PASS: the verb is there
# A verb that cannot be called at all (provclient / socket error, no RESULT line) is INVALID, never a PASS.
# This is the first thing to turn green on a P3 image; the rows' real arms (prov-settings-254 …) come after it.
# Type: R (the member base state as it is, nothing is changed: the calls carry no arguments and no owner-op).
# Side effects: the unit's snapshot and its restore (one reboot of 04).
set -u
PR_UNIT=prov-p3-verbs-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
# <verb> <the rows of appendix A whose first P3 verb it is>
VERBS="settings.get:ST1
status.get:SD1
diag.summary:SD2
diag.read:SD4
update.status:UD10
update.check:UD7
update.prepare:UD8
update.apply:UD1
bulk.open:UP1
bulk.close:UP9"
pr_begin 900 || { pr_result; exit 1; }
pr_keys && pr_pc_place || { pr_abort "provclient"; pr_result; exit 1; }
V_NOW=$(field "$(qr "$ST")" ver)
# the call path itself: a verb every helper has must answer 0 (else nothing below means anything)
r=$(pr_pc owner.pem -- info | grep '^RESULT info.state'); case "$r" in "RESULT info.state code=0 state=member "*) ok "the call path works (info.state code 0, member)";; *) inv "the call path: [$r]";; esac
old=0; new=0
for vr in $VERBS; do	# not `while read` over a here-string: the ssh calls inside would eat it (2026-11-07: one verb judged)
	verb=${vr%%:*}; rows=${vr#*:}
	# the code alone does not tell: an unknown verb AND a known verb called without its arguments both answer
	# ESchema (20; node.go:256 vs :141). The helper's log line does ("verb X refused: code 20 (unknown verb "X")"
	# vs "(missing arg N)"): read the line this call produced (04 wsl.22 2026-11-07: a first version judged by the
	# code and called all ten verbs present).
	u0=$(qr 'cut -d. -f1 /proc/uptime')
	r=$(pr_pc owner.pem -- verb "$verb" | grep "^RESULT $verb code=")
	c=$(sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$r")
	l=$(qr "logread | grep -F 'batman-provhelper' | grep -F 'verb $verb refused' | tail -1")
	case "$c:$l" in
		*":"*"unknown verb"*) no "$rows: $verb E_UNSUPPORTED (the helper has no such verb: code $c, '$(sed 's/.*refused: //' <<< "$l" | cut -c1-60)')"; old=$((old + 1)) ;;
		0:*) ok "$rows: $verb exists (code 0 for a bare call)"; new=$((new + 1)) ;;
		20:*"missing arg"*|20:*"unexpected arg"*|[1-9]*:*"refused"*) ok "$rows: $verb exists (code $c for a bare call: '$(sed 's/.*refused: //' <<< "$l" | cut -c1-60)')"; new=$((new + 1)) ;;
		*) inv "$rows: $verb — no RESULT line or no helper log line to judge by [$r] [$l] (uptime at the call: $u0)" ;;
	esac
done
say "image $V_NOW: $new of $((old + new)) P3 helper verbs exist"
# 254-h4 §6.1: "pre-P3" is said only of a version on the list AND without the feature marker; anything else that
# lacks the verbs is a plain FAIL (the lines above)
feat=$(qr "sed -n 's/^BATMAN_FEATURES=//p' /etc/batman-build")
if grep -qxF "$V_NOW" "$REPO/scripts/dv/pre-p3-versions.txt" && ! grep -q 'provd-p3(#254)' <<< "$feat"; then
	[ "$old" -gt 0 ] && no "pre-P3 image ($V_NOW)"
	[ "$new" -gt 0 ] && no "$V_NOW is on the pre-P3 list but $new P3 verb(s) exist: the list (scripts/dv/pre-p3-versions.txt) is wrong"
elif [ "$old" -gt 0 ]; then say "$V_NOW is not a listed pre-P3 version (or carries provd-p3(#254)): the missing verbs are plain FAILs"; fi
pr_end
pr_result
