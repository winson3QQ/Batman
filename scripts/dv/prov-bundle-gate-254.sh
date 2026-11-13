#!/bin/bash
# scripts/dv/prov-bundle-gate-254.sh — #254 H4 appendix A.6 (p3-how "n": plain HTTP from the host, no owner session):
#   BG1  a claimed / member node: GET /cgi-bin/bundle -> 403 (254-p3 D19: the bundle is for unclaimed / legacy nodes with
#        /etc/batman-dev-open only)
#   BG4  GET /cgi-bin/status still 200 (the gate is on the bundle, not on status)
#   BG3  (the dev-open half on THIS node): the flag alone does not open it on a claimed node -> still 403; the flag
#        is removed again (P: the unit proves the flag was there while it asked)
# BG2 / BG3's legacy and unclaimed halves need the L / F vehicles: with those units. The CGI reads p6's prov-state
# (254-p3 §5.3: "<boot_id> helper <state> ..."; a missing / stale line -> 403).
# W (pre-P3 image): the CGI has no gate (F15) -> BG1 and BG3 get 200 -> FAIL.
# Type: R. Side effects: /etc/batman-dev-open created and removed inside the unit (the restore would remove it too).
set -u
PR_UNIT=prov-bundle-gate-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 900 || { pr_result; exit 1; }
hget(){ curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://$NODE/cgi-bin/$1" 2>/dev/null; }
st=$(qr "sed -n 's/.*state=\([a-z]*\).*/\1/p' /etc/batman-prov/prov.meta"); say "node state: $st"
case "$st" in claimed|member) ;; *) inv "the node is not claimed / member [$st]: BG1 does not apply"; pr_end; pr_result; exit 2;; esac
c=$(hget status); [ "$c" = 200 ] && ok "BG4: /cgi-bin/status -> 200" || no "BG4: /cgi-bin/status -> [$c] (want 200)"
c=$(hget bundle); [ "$c" = 403 ] && ok "BG1: /cgi-bin/bundle on a $st node -> 403" || no "BG1: /cgi-bin/bundle on a $st node -> [$c] (want 403)"
# BG3 on this node: dev-open does not open a claimed node's bundle
q "touch /etc/batman-dev-open" >/dev/null; f=$(qr '[ -e /etc/batman-dev-open ] && echo flag=y || echo flag=n')
c=$(hget bundle); q "rm -f /etc/batman-dev-open" >/dev/null; g=$(qr '[ -e /etc/batman-dev-open ] && echo y || echo n')
[ "$f" = flag=y ] || inv "BG3: the dev-open flag could not be set for the check"
[ "$f" = flag=y ] && { [ "$c" = 403 ] && ok "BG3: dev-open on a $st node -> bundle still 403" || no "BG3: dev-open on a $st node -> bundle [$c] (want 403: dev-open opens it for unclaimed / legacy only)"; }
[ "$g" = n ] && ok "BG3: the flag removed again" || no "BG3: /etc/batman-dev-open still there"
pr_end
pr_result
