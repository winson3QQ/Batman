#!/bin/bash
# tests/prov-p1/rbarm.sh — offline test of the rollback arm, its launcher and the recovery script (254-h23 §20.3, §22.1,
# §23.1, §23.2): scripts/node/prov-rbarm-254.sh, prov-rbarm-launch-254.sh, prov-rbfix-254.sh against a stub batman-slot,
# a fixture autoboot.txt, a stub vcgencmd / batpower / openmanetd. busybox sh when present (the node's shell).
#   arm: PASS / every INVALID precondition (pre-gate, not A, not committed, [all] != fw-part A — the a0 = B case — B not
#        the wbox, vcgencmd missing / unreadable / under-voltage, batpower CRIT) / FAIL-RECOVERED with openmanetd up or
#        down / FAIL-NEEDS-PERSON / another refusal; own pid file; T lines in order.
#   rbfix: not on A / rebooted / a batman-slot process running -> INVALID, nothing committed; FIXED; FAIL.
#   pty (§23.1, emulated with util-linux `script`): the session dies 1 s after the start — the launched arm still writes
#        its RESULT; a harmless arm started with a plain `&` through the same launcher (`neg`) dies (the negative control).
# Zero cases = FAIL; a missing `script` = FAIL (not a skip).
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); N=$REPO/scripts/node
ARM=$N/prov-rbarm-254.sh; LAUNCH=$N/prov-rbarm-launch-254.sh; FIX=$N/prov-rbfix-254.sh
SH=$(command -v busybox >/dev/null 2>&1 && echo "busybox sh" || echo sh)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; f=0
WV=1.5.14-wsl.9+825a239.fw4d19709.dirty.wbox-96-noprov
mk(){	# <gate 0|1> <rollback: refuse-wbox|accept|refuse-other|move-and-fail> <commit: ok|fail> [active] [is-trial rc]
	rm -rf "$T/r" "$T/bin" "$T/d"; mkdir -p "$T/r/usr/sbin" "$T/r/usr/lib/batman" "$T/r/etc/init.d" "$T/r/boot" "$T/st" "$T/bin" "$T/d" "$T/run"
	printf 'bf_ab_all() { sed -n "/^\\[all\\]/,/^\\[/s/^boot_partition=//p" "%s/r/boot/autoboot.txt" | head -n 1; }\n' "$T" > "$T/r/usr/lib/batman/bootfacts.sh"
	echo "RUNDIR=$T/run" > "$T/r/usr/lib/batman/rundir.sh"
	printf '[all]\nboot_partition=1\n[tryboot]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"
	echo "$WV" > "$T/st/slot-B.protected"
	printf '#!/bin/sh\necho "throttled=0x0"\n' > "$T/bin/vcgencmd"; chmod 755 "$T/bin/vcgencmd"
	printf '#!/bin/sh\n[ "$1" = running ] && exit 0\n' > "$T/r/etc/init.d/openmanetd"; chmod 755 "$T/r/etc/init.d/openmanetd"
	printf '#!/bin/sh\n[ "$1" = running ] && exit 0\n' > "$T/r/etc/init.d/batpower"; chmod 755 "$T/r/etc/init.d/batpower"
	echo "OK 4.1" > "$T/run/batpower.state"
	{ echo '#!/bin/sh'
	  [ "$1" = 1 ] && echo '# die "slot $1 holds a -wbox test image (...): never made the default"'
	  echo "A=$T/r/boot/autoboot.txt"
	  echo "case \"\$1\" in active) echo ${4:-A} ;; is-trial) exit ${5:-1} ;; fw-part) [ \"\$2\" = A ] && echo 1 || echo 2 ;;"
	  case "$2" in
		refuse-wbox) echo ' rollback) echo "batman-slot: slot B holds a -wbox test image (BATMAN_WBOX=96-noprov): never made the default" >&2; exit 1 ;;' ;;
		accept) echo ' rollback) sed -i "1,2s/boot_partition=1/boot_partition=2/" $A; echo rolled back; exit 0 ;;' ;;
		refuse-other) echo ' rollback) echo "batman-slot: slot B build stamp unreadable — refusing to make it the default" >&2; exit 1 ;;' ;;
		move-and-fail) echo ' rollback) sed -i "1,2s/boot_partition=1/boot_partition=2/" $A; echo "read-back mismatch" >&2; exit 1 ;;' ;;
	  esac
	  case "$3" in
		ok) echo ' commit) sed -i "1,2s/boot_partition=2/boot_partition=1/" $A; exit 0 ;;' ;;
		fail) echo ' commit) exit 1 ;;' ;;
	  esac
	  echo 'esac'; } > "$T/r/usr/sbin/batman-slot"; chmod 755 "$T/r/usr/sbin/batman-slot"
}
ENV(){ env PATH="$T/bin:$PATH" PRB_ROOT="$T/r" PRB_STATE="$T/st" PRB_BOOT="$T/r/boot" PRB_SLEEP=0 PRB_OMD_WAIT=2 "$@"; }
run(){ ENV $SH "$ARM" "${1:-$WV}" "$T/d" > "$T/out" 2>&1; grep '^RESULT=' "$T/out" | tail -1; }
# shellcheck disable=SC2254  # $3 is a glob on purpose
want(){ n=$((n + 1)); case "$2" in $3) echo "ok   $1 ($2)" ;; *) echo "FAIL $1: [$2] want $3"; f=$((f + 1)) ;; esac; }
mk 1 refuse-wbox ok;   want "rollback refused by the gate"            "$(run)" 'RESULT=PASS rc=1 a0=1 a1=1 tryboot=2>2 *'
want "the arm wrote its own pid file"  "$(cat "$T/d/rbarm.pid" 2>/dev/null)" '[0-9]*'
want "T lines: start, awake, rollback, rolled in order" "$(grep -o '^T [a-z]*' "$T/out" | tr '\n' ' ')" 'T start T awake T rollback T rolled '
mk 0 refuse-other ok;  want "pre-gate image"                          "$(run)" 'RESULT=INVALID pre-gate image'
mk 1 refuse-wbox ok;   want "B is not the wbox"                       "$(run 1.5.14-wsl.9)" 'RESULT=INVALID slot-B.protected*'
mk 1 refuse-wbox ok;   printf '[all]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"; want "a0 = B: [all] 2 != fw-part A 1" "$(run)" 'RESULT=INVALID bf_ab_all ?2? != fw-part A ?1?'
mk 1 refuse-wbox ok;   printf '[all]\nboot_partition=7\n' > "$T/r/boot/autoboot.txt"; want "[all] unreadable value" "$(run)" 'RESULT=INVALID bf_ab_all ?7?*'
mk 1 refuse-wbox ok B; want "not running on A"                        "$(run)" 'RESULT=INVALID not running on A'
mk 1 refuse-wbox ok A 0; want "A not committed (is-trial rc 0)"       "$(run)" 'RESULT=INVALID A is not committed*'
mk 1 refuse-wbox ok;   rm "$T/bin/vcgencmd"; want "vcgencmd missing -> INVALID (fail-closed)" "$(ENV env PATH="$T/bin:/usr/bin:/bin" $SH "$ARM" "$WV" "$T/d" 2>&1 | grep '^RESULT=' | tail -1)" 'RESULT=INVALID vcgencmd missing*'
mk 1 refuse-wbox ok;   printf '#!/bin/sh\necho "throttled=0x50005"\n' > "$T/bin/vcgencmd"; want "under-voltage now" "$(run)" 'RESULT=INVALID under-voltage*'
mk 1 refuse-wbox ok;   printf '#!/bin/sh\necho "error"\n' > "$T/bin/vcgencmd"; want "get_throttled unreadable" "$(run)" 'RESULT=INVALID get_throttled unreadable*'
mk 1 refuse-wbox ok;   echo "CRIT 3.2" > "$T/run/batpower.state"; want "batpower CRIT" "$(run)" 'RESULT=INVALID batpower reports CRIT*'
mk 1 refuse-wbox ok;   echo "CRIT 3.2" > "$T/run/batpower.state"; printf '#!/bin/sh\nexit 1\n' > "$T/r/etc/init.d/batpower"; want "CRIT ignored when batpower is not running (batman-slot's rule)" "$(run)" 'RESULT=PASS*'
mk 1 accept ok;        want "rollback accepted -> recovered, openmanetd up" "$(run)" 'RESULT=FAIL-RECOVERED rc=0 a0=1 a1=2 a2=1 tryboot=2>2 omd=ok*'
mk 1 accept ok;        printf '#!/bin/sh\nexit 1\n' > "$T/r/etc/init.d/openmanetd"; want "recovered, openmanetd not back in time -> omd=down" "$(run)" 'RESULT=FAIL-RECOVERED*omd=down*'
mk 1 move-and-fail ok; want "[all] moved with rc != 0 -> recovered"   "$(run)" 'RESULT=FAIL-RECOVERED rc=1 a0=1 a1=2 a2=1*'
mk 1 accept fail;      want "commit cannot put [all] back"            "$(run)" 'RESULT=FAIL-NEEDS-PERSON*do NOT reboot*'
mk 1 refuse-other ok;  want "another refusal message"                 "$(run)" 'RESULT=INVALID rc=1 msg=*build stamp unreadable*'
# --- rbfix (§23.2)
fx(){ ENV env PRB_BOOTID="$T/bootid" PRB_PROC="${1:-/proc}" $SH "$FIX" "${2:-aaaabbbb}" "$T/d" 2>&1 | grep '^RESULT=' | tail -1; }
mk 1 accept ok; echo "aaaabbbb-1111" > "$T/bootid"; printf '[all]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"
want "rbfix: [all] put back to fw-part A" "$(fx)" 'RESULT=FIXED a=1 fw-part-A=1'
want "rbfix wrote its own pid file" "$(cat "$T/d/rbfix.pid" 2>/dev/null)" '[0-9]*'
mk 1 accept fail; echo "aaaabbbb-1111" > "$T/bootid"; printf '[all]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"
want "rbfix: commit fails -> FAIL" "$(fx)" 'RESULT=FAIL a=2*'
mk 1 accept ok B; echo "aaaabbbb-1111" > "$T/bootid"; printf '[all]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"
want "rbfix: not on A -> INVALID, nothing committed" "$(fx)" 'RESULT=INVALID not running on A'
want "rbfix: ... and [all] untouched" "$(sed -n 2p "$T/r/boot/autoboot.txt")" 'boot_partition=2'
mk 1 accept ok; echo "ccccdddd-1111" > "$T/bootid"; printf '[all]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"
want "rbfix: rebooted since the arm -> INVALID, no commit" "$(fx)" 'RESULT=INVALID rebooted since the arm started*'
mk 1 accept ok; echo "aaaabbbb-1111" > "$T/bootid"; printf '[all]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"
mkdir -p "$T/proc/4242"; printf 'sh\0/usr/sbin/batman-slot\0apply\0' > "$T/proc/4242/cmdline"
want "rbfix: a batman-slot process running -> INVALID (slot_lock)" "$(fx "$T/proc")" 'RESULT=INVALID a batman-slot process is running (pid 4242)*'
want "rbfix: ... and [all] untouched" "$(sed -n 2p "$T/r/boot/autoboot.txt")" 'boot_partition=2'
# --- §23.1 under a pty: 1 s after the start the session's process group gets SIGHUP (worst case of the hangup) and the
#     session is torn down (as when the harness kills `ssh -tt`). Without the SIGHUP the plain child survived (output to
#     a file): the session teardown alone does not discriminate.
if ! command -v script >/dev/null 2>&1; then echo "FAIL no util-linux script(1) — the pty cases cannot run"; n=$((n + 1)); f=$((f + 1)); else
	mk 1 refuse-wbox ok; cp "$ARM" "$T/d/rbarm.sh"; printf 'sleep 3; echo RESULT=PASS harmless\n' > "$T/d/harm.sh"
	pty(){ ENV env PRB_SLEEP=3 script -qfec "$SH $LAUNCH $1 $T/d; sleep 30" /dev/null > "$T/pty.out" 2>&1 & sp=$!; sleep 1; g=$(tr -d '\r' < "$T/pty.out" | sed -n 's/.*LAUNCH pid=[0-9]* pgid=\([0-9]*\).*/\1/p'); [ -n "$g" ] && kill -HUP -- "-$g" 2>/dev/null; kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; }
	rm -f "$T/d/rbarm.out"; pty "$WV"; i=0; while [ $i -lt 30 ] && ! grep -q '^RESULT=' "$T/d/rbarm.out" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
	want "pty: session gone after 1 s, the launched arm still writes its RESULT" "$(grep '^RESULT=' "$T/d/rbarm.out" 2>/dev/null)" 'RESULT=PASS*'
	want "pty: the launcher printed its session shell pid and pgid" "$(grep -o 'LAUNCH pid=[0-9]* pgid=[0-9]*' "$T/pty.out")" 'LAUNCH pid=[0-9]* pgid=[0-9]*'
	rm -f "$T/d/harm.out"; pty neg; sleep 5
	want "pty negative control: a harmless arm with a plain & dies with the session" "$(grep '^RESULT=' "$T/d/harm.out" 2>/dev/null || echo none)" none
fi
echo "RBARM cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]
