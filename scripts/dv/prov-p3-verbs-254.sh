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
while IFS=: read -r verb rows; do
	[ -n "$verb" ] || continue
	r=$(pr_pc owner.pem -- verb "$verb" | grep "^RESULT $verb code=")
	c=$(sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$r")
	case "$c" in
		6) no "$rows: $verb E_UNSUPPORTED (helper code 6)"; old=$((old + 1)) ;;
		''|*[!0-9]*) inv "$rows: $verb could not be called [$r]" ;;
		*) ok "$rows: $verb exists (helper code $c for a bare call)"; new=$((new + 1)) ;;
	esac
done <<< "$VERBS"
say "image $V_NOW: $new of $((old + new)) P3 helper verbs exist"
[ "$old" -gt 0 ] && [ "$new" = 0 ] && say "all of them are missing: a pre-P3 image (254-h4 §6.1)"
pr_end
pr_result
