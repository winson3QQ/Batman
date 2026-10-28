#!/bin/bash
# tests/prov-p1/rbarm.sh — offline test of scripts/node/prov-rbarm-254.sh (254-h23 §21.1, §23.9): a stub batman-slot and
# a fixture autoboot.txt per verdict. PASS / INVALID (pre-gate, B not the wbox, [all] not 1|2, not on A) / FAIL-RECOVERED (accepted, or [all] moved with rc != 0) / FAIL-NEEDS-PERSON (commit
# cannot put [all] back) / INVALID other refusal; and the arm survives the death of the shell that started it (setsid,
# HUP ignored). busybox sh when present (the node's shell). Zero cases = FAIL.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); ARM=$REPO/scripts/node/prov-rbarm-254.sh
SH=$(command -v busybox >/dev/null 2>&1 && echo "busybox sh" || echo sh)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; f=0
WV=1.5.14-wsl.9+825a239.fw4d19709.dirty.wbox-96-noprov
mk(){	# <gate 0|1> <rollback: refuse-wbox|accept|refuse-other|move-and-fail> <commit: ok|fail> [active]
	rm -rf "$T/r"; mkdir -p "$T/r/usr/sbin" "$T/r/usr/lib/batman" "$T/r/boot" "$T/st"
	printf 'bf_ab_all() { sed -n "/^\\[all\\]/,/^\\[/s/^boot_partition=//p" "%s/r/boot/autoboot.txt" | head -n 1; }\n' "$T" > "$T/r/usr/lib/batman/bootfacts.sh"
	printf '[all]\nboot_partition=1\n[tryboot]\nboot_partition=2\n' > "$T/r/boot/autoboot.txt"
	echo "$WV" > "$T/st/slot-B.protected"
	{ echo '#!/bin/sh'
	  [ "$1" = 1 ] && echo '# die "slot $1 holds a -wbox test image (...): never made the default"'
	  echo "A=$T/r/boot/autoboot.txt"
	  echo "case \"\$1\" in active) echo ${4:-A} ;;"
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
run(){ PRB_ROOT=$T/r PRB_STATE=$T/st $SH "$ARM" "${1:-$WV}" 2>&1 | grep '^RESULT=' | tail -1; }
# shellcheck disable=SC2254  # $3 is a glob on purpose
want(){ n=$((n + 1)); case "$2" in $3) echo "ok   $1 ($2)" ;; *) echo "FAIL $1: [$2] want $3"; f=$((f + 1)) ;; esac; }
mk 1 refuse-wbox ok;   want "rollback refused by the gate"            "$(run)" 'RESULT=PASS rc=1 a0=1 a1=1*'
mk 0 refuse-other ok;  want "pre-gate image"                          "$(run)" 'RESULT=INVALID pre-gate image'
mk 1 refuse-wbox ok;   want "B is not the wbox"                       "$(run 1.5.14-wsl.9)" 'RESULT=INVALID slot-B.protected*'
mk 1 refuse-wbox ok;   printf '[all]\nboot_partition=7\n' > "$T/r/boot/autoboot.txt"; want "[all] not 1|2" "$(run)" 'RESULT=INVALID bf_ab_all*'
mk 1 refuse-wbox ok B; want "not running on A"                        "$(run)" 'RESULT=INVALID not running on A'
mk 1 accept ok;        want "rollback accepted -> recovered"          "$(run)" 'RESULT=FAIL-RECOVERED rc=0 a0=1 a1=2 a2=1*'
mk 1 move-and-fail ok; want "[all] moved with rc != 0 -> recovered"   "$(run)" 'RESULT=FAIL-RECOVERED rc=1 a0=1 a1=2 a2=1*'
mk 1 accept fail;      want "commit cannot put [all] back"            "$(run)" 'RESULT=FAIL-NEEDS-PERSON*'
mk 1 refuse-other ok;  want "another refusal message"                 "$(run)" 'RESULT=INVALID rc=1 msg=*build stamp unreadable*'
# detached: a HUP (the ssh session going away) sent straight to the running arm does not stop it (trap '' HUP, setsid)
mk 1 accept ok; sed -i 's/^ rollback) /&sleep 2; /' "$T/r/usr/sbin/batman-slot"
PRB_ROOT=$T/r PRB_STATE=$T/st setsid $SH "$ARM" "$WV" > "$T/out" 2>&1 < /dev/null & ap=$!
sleep 1; kill -HUP "$ap" 2>/dev/null
i=0; while [ $i -lt 40 ] && ! grep -q '^RESULT=' "$T/out" 2>/dev/null; do sleep 0.5; i=$((i + 1)); done
want "detached arm survives its starter" "$(grep '^RESULT=' "$T/out" 2>/dev/null)" 'RESULT=FAIL-RECOVERED*'
# flip: the same arm WITHOUT `trap '' HUP` dies from that HUP and writes no RESULT (the detached test discriminates)
mk 1 accept ok; sed -i 's/^ rollback) /&sleep 2; /' "$T/r/usr/sbin/batman-slot"; sed "s/^trap '' HUP PIPE\$/: no trap/" "$ARM" > "$T/arm-notrap.sh"
grep -q '^: no trap$' "$T/arm-notrap.sh" || { echo "FAIL flip copy did not drop the trap"; f=$((f + 1)); }
PRB_ROOT=$T/r PRB_STATE=$T/st setsid $SH "$T/arm-notrap.sh" "$WV" > "$T/out2" 2>&1 < /dev/null & ap=$!
sleep 1; kill -HUP "$ap" 2>/dev/null; sleep 4
want "flip: without the HUP trap the arm dies" "$(grep '^RESULT=' "$T/out2" 2>/dev/null || echo none)" none
echo "RBARM cases=$n fails=$f"; [ "$n" -gt 0 ] && [ "$f" = 0 ]
