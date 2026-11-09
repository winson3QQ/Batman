#!/bin/bash
# scripts/dv/prov-owner-254.sh — #254 H4 appendix A.2, the helper-level rows that need only the bench owner (p3-how "h"):
#   OW4  remove the last owner -> E_FORBIDDEN (helper 3, node.go "cannot remove the last owner"); still 1 owner, state
#        unchanged (the member base has exactly one owner, H0; the design's OW4 removes Hx and H0b first - those two
#        need a second owner key: OW1 / OW2, below)
#   OW5  remove an owner that is not there (a resend of a remove) -> E_FORBIDDEN (3); owners unchanged
# Not here: OW1 / OW2 (owner.add needs the NEW owner's key to sign sig_enc on the host - a second signer; with the
# update tooling), OW3 / OW6 (provd sessions: p3-manual-rows.md).
# These helper verbs exist since P2 (F3), so this unit is expected to PASS on wsl.22 as well: it is not a W control,
# it guards P3 from changing P2's owner rules.
# Type: R. Side effects: none beyond the unit's snapshot and restore (one reboot): a remove that WRONGLY succeeded
# would be undone by the restore (p5 + overlay back).
set -u
PR_UNIT=prov-owner-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 1200 || { pr_result; exit 1; }
# the bench owner H0 signs (the run's own keys are not an owner of this node): a copy in the run's key dir
pr_h0 && pr_pc_place || { pr_abort "provclient / bench owner key"; pr_result; exit 1; }
code(){ sed -n 's/.* code=\([0-9]*\).*/\1/p' <<< "$1" | head -1; }
info(){ pr_pc h0.pem -- info | sed -n 's/^RESULT info.state code=0 state=\([a-z]*\) gen=\([0-9]*\) owners=\([0-9]*\) rm=\([a-z0-9]*\).*/state=\1 gen=\2 owners=\3 rm=\4/p'; }
i0=$(info); say "before: $i0"
case "$i0" in "state=member "*"owners=1 "*) ok "precondition: member with one owner (H0)";; *) inv "precondition: want a member with exactly one owner: [$i0]"; pr_end; pr_result; exit 2;; esac
# ---- OW4 the last owner
r=$(pr_pc h0.pem -- owner-remove "$H0" | grep '^RESULT owner.remove'); say "OW4: $r"
[ "$(code "$r")" = 3 ] && ok "OW4: removing the last owner -> E_FORBIDDEN" || no "OW4: removing the last owner: code $(code "$r") (want 3)"
i1=$(info); [ "$i1" = "$i0" ] && ok "OW4: owners / state unchanged ($i1)" || no "OW4: info changed: [$i0] -> [$i1]"
# ---- OW5 a remove of an owner that is not there (resend)
GHOST=04$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')   # a syntactically valid P-256 point prefix + random: not an owner
r=$(pr_pc h0.pem -- owner-remove "$GHOST" | grep '^RESULT owner.remove'); say "OW5: $r"
[ "$(code "$r")" = 3 ] && ok "OW5: removing an owner that is not there -> E_FORBIDDEN" || no "OW5: code $(code "$r") (want 3)"
i2=$(info); [ "$i2" = "$i0" ] && ok "OW5: owners / state unchanged" || no "OW5: info changed: [$i0] -> [$i2]"
# the node still answers the real owner
r=$(pr_pc h0.pem -- info | grep '^RESULT info.state'); case "$r" in "RESULT info.state code=0 state=member "*) ok "the node still answers (info.state 0, member)";; *) no "after the refused removes: [$r]";; esac
pr_end
pr_result
