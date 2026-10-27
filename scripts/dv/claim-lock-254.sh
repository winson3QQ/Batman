# shellcheck shell=bash
# scripts/dv/claim-lock-254.sh — the #254 claim-lock fix suites (docs/design/254-claim-lock-fix.md §11), sourced by
# daily-validation.sh. Each tier-B function runs one standalone script (they also run by hand) and judges its
# PASS / FAIL lines + final RESULT; the script's whole output is the suite log.
#   tier A : chk_prov_lock_rest_254 <node...>     read-only: batman-prov-lock installed + enabled (S13), lock-status
#                                                 consistent with the provisioning state, rollback gate present
#   tier B : bchk_setsid_race_254 <node>          scripts/dv/setsid-race-254.sh (no reboot; CPU load ~12 min)
#            bchk_prov_claim_254 <node>           scripts/dv/prov-claim-254.sh  (claim + S0 restore, 1 reboot)
#            bchk_adr_reconcile_254 <node>        scripts/dv/addr-defer-reconcile-254.sh (2 reboots)
#            bchk_pty_commit_254 <node>           scripts/dv/pty-commit-254.sh normal (held-trial OTA, slot move)
#            bchk_chain1_254 <node>               scripts/dv/chain1-254.sh (04 only: 60-90 min, off the mesh, both slots)
# A pre-fix image (no /etc/init.d/batman-prov-lock) makes the fix's own suites print ONE line
# "FAIL pre-claim-lock image: <version>" and do nothing else (KNOWN #254 until the fix ships).
# Env: DV_PROV_TOOLS (host dir: provclient-arm64), DV_PROV_TOOLS_WSL, DV_CRYPTPROBE (scripts/dv-cryptprobe-tools.sh
#      output), DV_OTA_PAYLOAD (node path of THIS version's A/B payload) + DV_OTA_PAYLOAD_SHA (sha256) for pty-commit /
#      chain1. A missing one is a FAIL, never a skip.
CL_SSHO=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8)
cl_ssh() { local n=$1 t=$2; shift 2; timeout "$t" ssh "${CL_SSHO[@]}" "root@$n" "$@" | tr -d '\r'; }
cl_fixed() {   # $1 node: rc 0 when the image carries the claim-lock fix, else one FAIL line
	local v; v=$(cl_ssh "$1" 20 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build; [ -x /etc/init.d/batman-prov-lock ] && echo FIXED')
	grep -q FIXED <<< "$v" && return 0; echo "FAIL pre-claim-lock image: $1 runs $(head -1 <<< "$v") (no batman-prov-lock)"; return 1; }
cl_need() { local e; for e in "$@"; do [ -n "${!e:-}" ] || { echo "FAIL $e is not set — the suite cannot run"; return 1; }; done; }
# cl_judge <want-final-line-ERE>: stdin = the script's output; PASS when the final line matches and no FAIL line exists
cl_judge() { local o; o=$(cat); echo "$o"; grep -qE "$1" <<< "$o" || { echo "FAIL no final verdict line matching /$1/"; return 1; }; ! grep -q '^FAIL' <<< "$o"; }

chk_prov_lock_rest_254() {
	local n r=0 o
	for n in "$@"; do
		o=$(cl_ssh "$n" 30 'v=$(sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build)
			[ -x /etc/init.d/batman-prov-lock ] || { echo "FAIL pre-claim-lock image: $v (no batman-prov-lock)"; exit 1; }
			[ -e /etc/rc.d/S13batman-prov-lock ] && echo "PASS S13batman-prov-lock enabled" || echo "FAIL batman-prov-lock not enabled (no /etc/rc.d/S13batman-prov-lock)"
			grep -q "^rollback_lock_gate()" /usr/sbin/batman-slot && echo "PASS rollback lock gate present" || echo "FAIL batman-slot has no rollback_lock_gate"
			s=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta 2>/dev/null); l=$(cat /opt/batdata/state/lock-status 2>/dev/null)
			case "$s:$l" in claimed:LOCKED|member:LOCKED|legacy:UNPROVISIONED|unclaimed:*) echo "PASS state $s, lock-status $l" ;;
				*) echo "FAIL state [$s] with lock-status [$l]" ;; esac
			case "$s" in claimed|member) p=$(uci -q get dropbear.@dropbear[0].PasswordAuth); [ "$p" = off ] && echo "PASS claimed: PasswordAuth off" || echo "FAIL claimed node with PasswordAuth [$p]" ;; esac')
		# "FAIL <node>: …": the known-failures matcher only reads lines that start with FAIL
		echo "$o" | sed -E "s/^(FAIL|PASS) /\1 $n: /"; grep -q '^FAIL' <<< "$o" && r=1; grep -q '^PASS' <<< "$o" || r=1
	done; return $r; }
bchk_setsid_race_254() { cl_fixed "$1" || return 1; bash "$REPO/scripts/dv/setsid-race-254.sh" "$1" 2>&1 | cl_judge '^RESULT setsid-race-254 PASS$'; }
bchk_prov_claim_254() { cl_fixed "$1" || return 1; cl_need DV_PROV_TOOLS DV_CRYPTPROBE || return 1
	NODE=$1 bash "$REPO/scripts/dv/prov-claim-254.sh" 2>&1 | cl_judge 'prov-claim .*\] fails=0$'; }
bchk_adr_reconcile_254() { bash "$REPO/scripts/dv/addr-defer-reconcile-254.sh" "$1" 2>&1 | cl_judge '^RESULT addr-defer-reconcile-254 PASS$'; }
bchk_pty_commit_254() { local v; cl_need DV_OTA_PAYLOAD DV_OTA_PAYLOAD_SHA || return 1
	v=$(cl_ssh "$1" 20 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build')
	V=$v PAY=$DV_OTA_PAYLOAD PSH16=${DV_OTA_PAYLOAD_SHA:0:16} bash "$REPO/scripts/dv/pty-commit-254.sh" "$1" normal 2>&1 | cl_judge '^RESULT pty-commit normal PASS$'; }
bchk_chain1_254() { local v; [ "$1" = 10.41.1.3 ] || { echo "FAIL chain1-254 is 04-specific (IP / MAC / peer 02 hard-coded) and DNODE is $1"; return 1; }
	cl_need DV_OTA_PAYLOAD DV_OTA_PAYLOAD_SHA DV_PROV_TOOLS || return 1
	v=$(cl_ssh "$1" 20 'sed -n "s/^BATMAN_VERSION=//p" /etc/batman-build')
	V=$v PAY=$DV_OTA_PAYLOAD PSHA=$DV_OTA_PAYLOAD_SHA bash "$REPO/scripts/dv/chain1-254.sh" 2>&1 | cl_judge 'CHAIN1 RESULT: PASS'; }
