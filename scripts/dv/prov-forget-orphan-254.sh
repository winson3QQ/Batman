#!/bin/bash
# scripts/dv/prov-forget-orphan-254.sh — #254 tier-B unit prov-forget-orphan-254 (docs/design/254-wireless-txn.md
# §19.3 / §19.6, deterministic white-box): the orphan of §19.1 rebuilt by hand on 04 (scripts/node/prov-orphan-254.sh:
# the morse radio down the way a forget does it, then a mesh netdev of the same name on the morse phy, named in
# netifd's /var/state splist, with a root wpa_supplicant_s1g on it), then
#   arm 1 (verdict):  halow-setkey --forget-mesh -> the escalation (kill the s1g by /proc exe+Uid, `iw dev del`) ->
#                     rc 0, "forgotten after escalation" logged, netdev + process gone; then the rebuild on hardware:
#                     setkey puts the node's own network back -> rc 0, netifd up=true pending=false, meshjoin_radio_up,
#                     02 a neighbour within 180 s (= netifd's next setup tolerates the splist entry setkey deleted)
#   arm 2 (recorded): `prov-forget-orphan-254.sh noforget` — a separate unit run (its own snapshot / restore, so it
#                     never starts from arm 1's leftovers): the same orphan, NO forget, the setkey rebuild alone: does
#                     netifd's own setup clean an orphan it has in its splist? (§19.3: the roles-swapped join is "not
#                     self-healing" until this says otherwise). Verdict: PASS when the orphan was built and the rebuild
#                     ran (the outcome is in the log); INVALID when the orphan could not be built.
#   negative control: the same arm 1 on wsl.15 -> forget rc 3 (no escalation), and the unit asserts the orphan exists
#                     before the forget (else INVALID — the first probe created nothing).
# Type: — / A / F. Side effects: 04 off the fleet mesh ~4 min; the stray wlh0 really joins the lab mesh with the lab
# key (02 sees 04 peer / leave / peer; joinwatch, meshled lines) — the same id and key the node beacons every day;
# the key copied into the root-only 0700 run dir (removed by the node script); a /var/state splist line; the node
# script's cleanup + S0 restore (reboot) on EVERY exit, INVALID and abort included. B untouched.
set -u
ARM=${1:-forget}; case "$ARM" in forget) PR_UNIT=prov-forget-orphan-254 ;; noforget) PR_UNIT=prov-forget-orphan-noforget-254 ;; *) echo "usage: $0 [forget|noforget]" >&2; exit 2 ;; esac
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
ORPH=$REPO/scripts/node/prov-orphan-254.sh
ND=/tmp/run/batman-dv   # root 0700 (pr_begin makes it)
cleanup(){ q "sh $ND/orphan.sh cleanup" | sed 's/^/    /'; }
arm(){   # <forget|noforget>: runs the node script, prints its lines, judges arm 1
	local o
	o=$(QT=420 q "sh $ND/orphan.sh $1 2>&1"); echo "$o" | sed 's/^/    /'
	if grep -q '^INVALID' <<< "$o"; then inv "arm $1: $(grep -m1 '^INVALID' <<< "$o")"; return 1; fi
	grep -q '^ORPHAN ok dev=' <<< "$o" || { inv "arm $1: no ORPHAN line (the node script did not get there)"; return 1; }
	if [ "$1" = forget ]; then
		local f; f=$(grep -m1 '^FORGET rc=' <<< "$o")
		grep -q '^FORGET rc=0 ' <<< "$o" && ok "forget on the orphan: rc 0 ($f)" || no "forget on the orphan: $f (want rc 0 — wsl.15 gives rc 3: no escalation)"
		local a; a=$(grep -m1 '^FORGET-AFTER' <<< "$o")
		case "$a" in *"meshdev= "*"s1g=[]"*"pidalive=no"*"escalation-logged="[1-9]*) ok "after the forget: netdev and s1g gone, escalation logged ($a)" ;; *) no "after the forget: $a (want meshdev empty, s1g gone, escalation logged)" ;; esac
	else
		say "arm 2 (recorded, no verdict): $(grep -m1 '^RESTORE-AFTER' <<< "$o")"
	fi
	local r; r=$(grep -m1 '^RESTORE rc=' <<< "$o")
	if [ "$1" = forget ]; then
		grep -q '^RESTORE rc=0 ' <<< "$o" && ok "rebuild by setkey after the escalation: rc 0 ($r)" || no "rebuild by setkey after the escalation: $r"
		a=$(grep -m1 '^RESTORE-AFTER' <<< "$o")
		case "$a" in *"up=true dis=false pend=false meshdev="[a-z]*) ok "after the rebuild netifd reports the radio up, not pending ($a)" ;; *) no "after the rebuild: $a (want up=true dis=false pend=false, a mesh netdev)" ;; esac
		grep -q '^MESHUP yes' <<< "$o" && ok "meshjoin_radio_up after the rebuild ($(grep -m1 '^MESHUP' <<< "$o"))" || no "meshjoin_radio_up after the rebuild: $(grep -m1 '^MESHUP' <<< "$o")"
		local t=0; while [ $t -lt 18 ]; do nb02 && break; sleep 10; t=$((t + 1)); done
		[ $t -lt 18 ] && ok "02 is a neighbour again within $((t * 10)) s of the rebuild" || no "02 not a neighbour within 180 s of the rebuild"
	else
		say "arm 2 outcome: $r; $(grep -m1 '^MESHUP' <<< "$o")"
	fi
	return 0
}
pr_begin 2400 || { pr_result; exit 1; }
scp -q $SSHO "$ORPH" root@$NODE:$ND/orphan.sh || { pr_abort "stage"; pr_result; exit 1; }
q "chmod 700 $ND/orphan.sh"
arm "$ARM"; cleanup
# the key never reaches the host: the unit's own log must not carry it (the node script prints no key); and no key in
# the node logs either (the §19.6 canary: the node's key from uci against logread + p6 logs)
c=$(qr 'umask 077; k=$(mktemp -p /tmp/run/batman-dv); uci -q get wireless.default_radio1.key > $k; n=0; { logread; cat /opt/batdata/log/*.log 2>/dev/null; } | grep -qF -f $k && n=1; rm -f $k; echo leaks=$n')
[ "$c" = leaks=0 ] && ok "the mesh key is in no node log (logread, p6 logs)" || no "mesh key canary: $c"
pr_end
pr_result
