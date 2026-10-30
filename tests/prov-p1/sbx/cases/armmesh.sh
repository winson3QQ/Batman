#!/bin/sh
# tests/prov-p1/sbx/cases/armmesh.sh — L51 write half (254-h23 §19.4, §23.9): the real _ab_arm_mesh of
# /usr/lib/batman/platform-ab.sh, sourced in the sandbox (real /opt/batdata tmpfs in /proc/mounts, real run dir), with only
# its environment stubbed: _ab_live_sysupgrade (the host-pid-ns scan), `batman-slot target` (PATH stub) and meshjoin.sh
# (a bound stub whose meshjoin_joined answers per case).
#   lastjoined non-empty -> "<boot8> B joined"; empty + meshjoin_joined true -> joined (the fallback); empty + false ->
#   radio; caller not procd -> no file; no $RAM_ROOT/sbin/upgraded -> no file; no live sysupgrade -> no file; an old
#   arm file is removed first in every case. SBX_MUTANT=no-joined (the joined branch removed) must FAIL.
n=0; f=0; M=${SBX_MUTANT:--}; ARM=/opt/batdata/state/ota-armed.mesh; PA=/usr/lib/batman/platform-ab.sh
ok(){ n=$((n + 1)); }; no(){ n=$((n + 1)); f=$((f + 1)); echo "FAIL $*"; }
mkdir -p /opt/batdata/state /opt/batdata/log /sbx/run/bin
printf '#!/bin/sh\n[ "$1" = target ] && { echo B; exit 0; }\nexit 1\n' > /sbx/run/bin/batman-slot; chmod 755 /sbx/run/bin/batman-slot
printf 'meshjoin_sample(){ :; }\nmeshjoin_joined(){ [ -f /sbx/run/mj-joined ]; }\n' > /sbx/run/meshjoin.sh
mount --bind /sbx/run/meshjoin.sh /usr/lib/batman/meshjoin.sh || { echo "FAIL bind meshjoin stub"; echo "CASE armmesh cases=0 fails=1"; exit 1; }
cp $PA /sbx/run/pa.sh
[ "$M" = no-joined ] && sed -i 's/^\tif \[ -s "\$RUNDIR\/joinwatch.lastjoined" \]; then m=joined$/\tif false; then m=joined/; s/meshjoin_joined ); then m=joined; fi/false ); then m=joined; fi/' /sbx/run/pa.sh
[ "$M" != - ] && cmp -s /sbx/run/pa.sh $PA && { echo "FAIL mutant $M did not change platform-ab.sh"; echo "CASE armmesh cases=0 fails=1"; exit 1; }
BOOT8=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
one(){	# <label> <caller> <upgraded 0|1> <live 0|1> <lastjoined 0|1> <mj 0|1> <want: none|joined|radio>
	rm -rf /tmp/run/batman /sbx/run/mj-joined; echo "old stale" > $ARM
	[ "$6" = 1 ] && : > /sbx/run/mj-joined
	o=$(PATH=/sbx/run/bin:$PATH sh -c '
		C=$1; U=$2; L=$3; J=$4   # before the source: platform-ab.sh may reset the positional parameters
		. /lib/functions.sh 2>/dev/null
		. /sbx/run/pa.sh 2>/dev/null
		batman_rundir 2>/dev/null; RAM_ROOT=$RUNDIR/ramroot
		[ "$U" = 1 ] && { mkdir -p "$RAM_ROOT/sbin" && : > "$RAM_ROOT/sbin/upgraded" && chmod 755 "$RAM_ROOT/sbin/upgraded"; }
		[ "$J" = 1 ] && echo 1 > "$RUNDIR/joinwatch.lastjoined"
		_ab_live_sysupgrade(){ [ "$L" = 1 ]; }
		echo "dbg rundir=$RUNDIR ram=$RAM_ROOT up=$([ -x "$RAM_ROOT/sbin/upgraded" ] && echo y) mnt=$(grep -c " /opt/batdata " /proc/mounts) tgt=$(batman-slot target)"
		_ab_arm_mesh "$C"; echo "rc=$?"' armmesh "$2" "$3" "$4" "$5" 2>&1)
	a=$(cat $ARM 2>/dev/null)
	case "$7" in
		none) want="" ;;
		*) want="$BOOT8 B $7" ;;
	esac
	if [ "$a" = "$want" ] && echo "$o" | grep -q 'rc=0'; then ok; else no "$1: arm file [$a] want [$want] ($o)"; fi
}
one "procd, upgraded, live, lastjoined"          "/sbin/procd -s" 1 1 1 0 joined
one "procd, upgraded, live, meshjoin fallback"   "/sbin/procd -s" 1 1 0 1 joined
one "procd, upgraded, live, not joined"          "/sbin/procd -s" 1 1 0 0 radio
one "caller not procd (stale file removed too)"  "/bin/sh x"      1 1 1 1 none
one "no upgraded in RAM_ROOT"                    "/sbin/procd -s" 0 1 1 1 none
one "no live sysupgrade"                         "/sbin/procd -s" 1 0 1 1 none
umount /usr/lib/batman/meshjoin.sh
echo "CASE armmesh cases=$n fails=$f"
