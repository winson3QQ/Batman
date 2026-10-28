#!/bin/bash
# scripts/dv/prov-sec-254.sh — #254 tier A prov-sec-helper-uid-254 / -key-perms-254 / -dvpc-254 / -sockdir-254 (docs/design/
# 254-h23-harness.md §4.5, §7): the judge (scripts/node/prov-sec-254.sh) PASSes on the node as it is, and each
# white-box negative control — under a prov lease, nothing persistent touched, no reboot — makes the right thing FAIL:
#   key-perms  a harmless 0644 dummy bind-mounted over identity/node.key (never a copy of the key) -> the judge FAILs
#              ("node.key … (want -rw------- …)" / "is a mount point"); unbound at once
#   dvpc       the per-run provclient dir pre-created (a root dir, then a symlink) -> the placement refuses
#   sockdir    helper stopped; /tmp/run/batman-prov pre-made as a symlink, then as a dir owned by uid 471 -> the helper
#              refuses to start ("sock: … refusing to start"), no socket; restored -> serving again
set -u
PR_UNIT=prov-sec-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
PS=$REPO/scripts/node/prov-sec-254.sh
judge(){ timeout 120 ssh $SSHO root@$NODE sh -s < "$PS" 2>&1 | tr -d '\r'; }
o=$(judge); echo "$o" | sed 's/^/    /'
grep -qx 'PROV-SEC fails=0' <<< "$o" && ok "helper uid / socket dir / key perms as specified" || no "prov-sec judge on the untouched node: $(grep ^FAIL <<< "$o" | tr '\n' '|')"
pr_lock; PR_BEGUN=1; trap 'pr_on_exit' EXIT
PR_DEADLINE=$(( $(mono) + 900 )); o=$(pr_acquire 900) || { echo "$o"; no "lease"; pr_result; exit 1; }
# ---- key-perms: a 0644 dummy over node.key (bind; the helper keeps its loaded key, nothing restarts)
pw prep >/dev/null
q "W=/tmp/run/batman-dv/wbox/$RUN; printf 'not a key\n' > \$W/dummy.key && chmod 644 \$W/dummy.key"
h=$(qr "sha256sum < /tmp/run/batman-dv/wbox/$RUN/dummy.key | cut -c1-64")
o=$(pw bind dummy.key "$h" /etc/batman-prov/identity/node.key); say "$o"
o=$(judge); u=$(pw unbind-all); say "unbind: $(echo $u)"
grep -q '^FAIL .*node.key' <<< "$o" && ok "negative control: a 0644 thing at identity/node.key -> the judge FAILs ($(grep '^FAIL .*node.key' <<< "$o" | head -1))" || no "negative control (key-perms): the judge did not FAIL: $o"
[ "$(qr "grep -c ' /etc/batman-prov/identity/node.key ' /proc/self/mountinfo")" = 0 ] && ok "dummy unbound" || no "node.key still bind-mounted"
# ---- dvpc: the placement refuses a pre-existing dir / symlink
q "mkdir -m 0711 $PCD"; o=$(pr_pc_place 2>&1); q "rm -rf $PCD"
grep -q 'FAIL .*provclient placement' <<< "$o" && ok "negative control: a pre-created $PCD -> the placement refuses" || no "dvpc pre-created dir accepted: $o"
# the planted links point at a DECOY dir (review A-m1: they pointed at /tmp — a regressed placement / helper that
# followed the link would have chowned / chmodded /tmp on 04); the decoy's owner + mode must be unchanged afterwards
DEC=/tmp/run/batman-dv/wbox/$RUN/decoy; DECST='ls -lnd /tmp/run/batman-dv/wbox/'"$RUN"'/decoy | cut -d" " -f1,3,4'
q "mkdir -m 0700 $DEC"; d0=$(qr "$DECST")
q "ln -s $DEC $PCD"; o=$(pr_pc_place 2>&1); q "rm -f $PCD"
grep -q 'FAIL .*provclient placement' <<< "$o" && ok "negative control: a symlink at $PCD -> the placement refuses" || no "dvpc symlink accepted: $o"
# ---- sockdir: the helper refuses a socket dir it did not make
sockcase(){	# <name> <setup as root>
	local p o
	q "/etc/init.d/batman-provhelper stop >/dev/null 2>&1; rm -rf /tmp/run/batman-prov; $2"
	q "/etc/init.d/batman-provhelper start >/dev/null 2>&1"; sleep 8
	p=$(qr 'pidof batman-provhelper'); o=$(qr "logread | grep 'batman-provhelper' | grep 'sock:' | tail -1; [ -S /tmp/run/batman-prov/helper.sock ] && echo SOCKET")
	say "$1: pid=[$p] $o"
	grep -q 'refusing to start' <<< "$o" && ! grep -q SOCKET <<< "$o" && ok "negative control: helper refuses a $1 socket dir, no socket" || no "helper with a $1 socket dir: $o"
	q "/etc/init.d/batman-provhelper stop >/dev/null 2>&1; rm -rf /tmp/run/batman-prov; /etc/init.d/batman-provhelper start >/dev/null 2>&1"; sleep 8
	[ "$(qr '[ -S /tmp/run/batman-prov/helper.sock ] && pidof batman-provhelper >/dev/null && echo up')" = up ] && ok "helper serving again after the $1 case" || no "helper not back after the $1 case"
}
sockcase symlinked "ln -s $DEC /tmp/run/batman-prov"
[ "$(qr "$DECST")" = "$d0" ] && ok "the decoy behind the planted links is unchanged ($d0)" || no "the decoy changed: $d0 -> $(qr "$DECST") — something followed a planted link"
sockcase "uid-471-owned" "mkdir -m 0750 /tmp/run/batman-prov && chown 471:471 /tmp/run/batman-prov"
o=$(judge); grep -qx 'PROV-SEC fails=0' <<< "$o" && ok "judge PASSes again at the end" || no "judge at the end: $(grep ^FAIL <<< "$o" | tr '\n' '|')"
pr_release
pr_result
