#!/bin/bash
# scripts/dv/prov-ac-forge-254.sh — #254 tier-B unit autocommit (10) (L41; docs/design/254-h23-harness.md §6.2, §7 OTS
# row): only the real OTA validation arms the trial's radio-only mode. platform_check_image (platform-ab.sh) writes
# /opt/batdata/state/ota-armed.mesh + otalog "S1 ARMED-MESH" only when its caller is procd, $RAM_ROOT/sbin/upgraded
# exists and a root /sbin/sysupgrade runs in the host pid namespace.
#   arm a: non-root (nobody) `sysupgrade -T <V payload>` -> no arm file, no ARMED-MESH line
#   arm b (the discriminating forgery): host root sources platform.sh and calls platform_check_image directly (parent
#     = a shell, not procd) -> rc 0, the planted sentinel arm file REMOVED (proves _ab_arm_mesh ran), no new arm
#     file, no ARMED-MESH line
#   arm c (characterization, F35: the OTS container has none of these binds): container root with /lib/upgrade,
#     /opt/batdata and /tmp/run bound calls platform_check_image and _ab_arm_mesh "/sbin/procd" -> no arm file, no
#     ARMED-MESH line (pid ns differs)
#   real OTA (hold) into B -> the arm file exists: "<arm boot> B radio|joined", and the arm boot's
#     "S1 ARMED-MESH slot=B" line -> back to A
# Type: hold + back_to_a / A. Side effects: 04 ~25 min, one container start (no network), B rewritten, ~3 reboots.
set -u
PR_UNIT=prov-ac-forge-254
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
ARM=/opt/batdata/state/ota-armed.mesh
TRACE=/opt/batdata/log/ota-trace.log
XD=/opt/batdata/dv-ac10
OTSI=batman/ots:1.7.13-arm64
narm(){ qr "grep -c 'S1 ARMED-MESH' $TRACE 2>/dev/null"; }
noarm(){	# <arm> <ARMED-MESH count before>
	[ "$(qr "[ -e $ARM ] && echo present || echo absent")" = absent ] && ok "arm $1: no ota-armed.mesh" || no "arm $1: ota-armed.mesh exists: $(qr "cat $ARM")"
	[ "$(narm)" = "$2" ] && ok "arm $1: no S1 ARMED-MESH line" || no "arm $1: S1 ARMED-MESH written: $(qr "grep 'S1 ARMED-MESH' $TRACE | tail -1")"
}
forged(){
	local n o
	pr_payload "$PR_V" >/dev/null || { no "payload $PR_V"; return 1; }
	scp -q $SSHO "$PAYF" root@$NODE:$PR_PAY.part && q "mv $PR_PAY.part $PR_PAY" || { no "payload upload"; return 1; }
	[ "$(qr "sha256sum < $PR_PAY | cut -c1-64")" = "$PSHA" ] || { no "payload sha on the node"; return 1; }
	q "rm -f $ARM; sync"
	# a — the drop must really be nobody, and root's -T on the same file must pass (else the arm proves nothing)
	o=$(qr "start-stop-daemon -S -c nobody -x /usr/bin/id -- -u")
	[ "$o" = 65534 ] || { no "arm a precondition: start-stop-daemon -c nobody runs as [$o]"; return 1; }
	o=$(q "sysupgrade -T $PR_PAY >/dev/null 2>&1; echo T=\$?"); grep -q 'T=0' <<< "$o" || { no "root sysupgrade -T on V fails ($o)"; return 1; }
	q "rm -f $ARM; sync"
	n=$(narm)
	o=$(q "rm -rf $XD; mkdir -m 0755 $XD && cp $PR_PAY $XD/p.tgz && chmod 0644 $XD/p.tgz && cd / && start-stop-daemon -S -c nobody -x /sbin/sysupgrade -- -T $XD/p.tgz 2>&1 | tail -2; echo RC=\$?")
	say "arm a (nobody sysupgrade -T): $(echo $o)"
	noarm a "$n"
	# b
	q "printf 'deadbeef B radio\n' > $ARM; sync"; n=$(narm)
	o=$(q "cd / && sh -c '. /lib/functions.sh; . /lib/upgrade/common.sh; . /lib/upgrade/platform.sh; platform_check_image $PR_PAY >/dev/null 2>&1; echo RC=\$?'")
	say "arm b (root, shell parent): $(echo $o)"
	grep -q 'RC=0' <<< "$o" || { no "arm b: platform_check_image rc != 0 — the forgery never reached _ab_arm_mesh ($o)"; return 1; }
	ok "arm b: platform_check_image rc 0 (reached _ab_arm_mesh)"
	noarm b "$n"
	# c
	q "docker image inspect $OTSI >/dev/null 2>&1" || { no "arm c: image $OTSI missing"; return 1; }
	n=$(narm)
	# --user 0: the OTS image runs as uid 1000; the library binds make the code actually run (run 1: /lib/functions.sh
	# missing -> rc 127, nothing exercised). `upgraded` is planted in the bound run dir and the caller is "procd", so
	# only the pid-namespace check of _ab_live_sysupgrade is left to refuse. (With /opt/batdata bound rw a container
	# root could write the arm file itself — the boundary is F35: the OTS container has none of these binds.)
	o=$(q "docker run --rm --network none --user 0 --entrypoint sh -v /lib/upgrade:/lib/upgrade:ro -v /lib/functions.sh:/lib/functions.sh:ro -v /lib/functions:/lib/functions:ro -v /usr/lib/batman:/usr/lib/batman:ro -v /opt/batdata:/opt/batdata -v /tmp/run:/tmp/run $OTSI -c '. /lib/functions.sh; . /lib/upgrade/platform.sh; echo RR=\$RAM_ROOT; mkdir -p \$RAM_ROOT/sbin && printf \"#!/bin/sh\n\" > \$RAM_ROOT/sbin/upgraded && chmod 755 \$RAM_ROOT/sbin/upgraded && echo PLANTED; platform_check_image $PR_PAY >/dev/null 2>&1; echo PCI=\$?; _ab_arm_mesh /sbin/procd >/dev/null 2>&1; echo AM=\$?; rm -rf \$RAM_ROOT; echo UID=\$(id -u)' 2>&1 | tail -6")
	grep -q 'UID=0' <<< "$o" && grep -q PLANTED <<< "$o" && grep -q 'AM=0' <<< "$o" || { say "arm c: $(echo $o)"; no "arm c: the container arm did not run as root / plant / reach _ab_arm_mesh"; return 1; }
	[ "$(qr '. /usr/lib/batman/rundir.sh; [ -e $RUNDIR/ramroot ] && echo left || echo gone')" = gone ] || { no "arm c: planted ramroot left behind"; q '. /usr/lib/batman/rundir.sh; rm -rf $RUNDIR/ramroot'; }
	say "arm c (container root, characterization): $(echo $o)"
	noarm c "$n"
	q "rm -rf $XD; rm -f $ARM; sync"
}
real(){
	local s b0 a l
	s=$(qr "$ST"); b0=$(field "$s" boot)
	pr_ota_b "$PR_V" B || return 1
	a=$(qr "cat $ARM 2>/dev/null"); say "arm file in the trial: [$a] (arm boot $b0)"
	case "$a" in "$b0 B radio"|"$b0 B joined") ok "real OTA: ota-armed.mesh = <arm boot> B radio|joined";; *) no "real OTA: ota-armed.mesh [$a]";; esac
	l=$(qr "grep 'boot=$b0 .*S1 ARMED-MESH slot=B' $TRACE | tail -1")
	[ -n "$l" ] && ok "real OTA: ${l#* S1 }" || no "real OTA: no S1 ARMED-MESH line of the arm boot $b0"
	back_to_a || return 1
	q "rm -f $ARM; sync"
}
pr_begin 2400 || { pr_result; exit 1; }
forged || { q "rm -rf $XD; rm -f $ARM" >/dev/null; pr_abort "forged arms"; pr_result; exit 1; }
real || { pr_abort "real OTA"; pr_result; exit 1; }
pr_end
pr_result
