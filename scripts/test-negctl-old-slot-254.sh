#!/bin/bash
# scripts/test-negctl-old-slot-254.sh — offline test of scripts/negctl-old-slot-254.sh (#254 PR-H1 §4.10 N3).
# A fake `ssh` simulates one node (slot, version, trial, hold flag, boot_id) by matching the commands the script and
# fault-injection's helpers send. Every rollback the script sends is logged with whether it carried the
# node-side "only on slot B" guard. Cases: success, hold not effective, tryboot lands on A, interrupts in each
# PHASE, a pre-existing flag. Exit 0 = all cases behaved.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"; chmod +x "$W/bin/sleep"
cat > "$W/bin/ssh" <<'FAKE'
#!/bin/bash
cmd=""; while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; root@*) shift; cmd="$*"; break;; *) shift;; esac; done
[ -n "$cmd" ] && [ "$cmd" != "sh -s" ] || cmd=$(cat)
D=$SIM; g() { cat "$D/$1"; }; p() { echo "$2" > "$D/$1"; }
log() { echo "$*" >> "$D/log"; }
kill_if() { [ -n "${SIM_KILL_ON:-}" ] && [ ! -e "$D/killed" ] && grep -q -- "$SIM_KILL_ON" <<< "$cmd" && { : > "$D/killed"; kill -TERM "$NEGCTL_MAINPID"; }; }
newboot() { p boot "b$(( $(cat "$D/n") + 1 ))"; p n $(( $(cat "$D/n") + 1 )); }
out=""; rc=0
case "$cmd" in
	*"PASS ble-privacy-254"*) if [ "$(g ver)" = V2 ]; then out="FAIL batman-sc missing or not a root regular file"; rc=1; else out="PASS ble-privacy-254"; fi ;;
	*"PASS prov-tools-254"*) out="PASS prov-tools-254" ;;
	*"batman-slot rollback"*)
		case "$cmd" in *'$(batman-slot active)" = B'*) g=guarded;; *) g=UNGUARDED;; esac
		log "ROLLBACK $g on=$(g slot)"
		if [ "$g" = guarded ] && [ "$(g slot)" = B ]; then p slot A; p ver V9; p trial 1; newboot; out=SENT
		elif [ "$g" = UNGUARDED ]; then if [ "$(g slot)" = A ]; then p slot B; p ver V2; p trial 1; else p slot A; p ver V9; p trial 1; fi; newboot; out=SENT
		else out=NOT-ON-B; fi ;;
	*"sysupgrade -n"*)
		log OTA; l=$(g land)
		if [ "$l" = B ]; then p slot B; p ver V2; p trial 0
			if [ "$(g flag)" = V2 ] && [ "$(g holdok)" = yes ]; then p held yes; p flag ""; else p held no; fi
		else p slot A; p ver V9; p trial 1; p held no; fi
		newboot ;;
	*"RR-OK"*) out=RR-OK ;;
	*"mount -t squashfs"*) out="V=V2 P=V2 SAME=yes VERIFY=ok T=default" ;;
	*"p5="*) out=$'p5=aa\nuci=bb/cc\nstate slot-A.protected 11\noverlayA=dd' ;;
	*"rm -f /opt/batdata/state/autocommit-hold-commit"*) log RMFLAG; p flag "" ;;
	*"> /opt/batdata/state/autocommit-hold-commit"*) log SETFLAG; p flag V2 ;;
	*'[ ! -e /opt/batdata/state/autocommit-hold-commit ]'*) [ -z "$(g flag)" ] || rc=1 ;;
	"cat /opt/batdata/state/autocommit-hold-commit") out=$(g flag) ;;
	*'held=$('*) out="slot=$(g slot) ver=$(g ver) trial_rc=$(g trial) committed=no held=$(g held) p6flag=$([ -n "$(g flag)" ] && echo yes || echo no) deadline=600 discarded=0" ;;
	*'slot=$(batman-slot active) ver='*) out="slot=$(g slot) ver=$(g ver) trial_rc=$(g trial) hold=[$(g flag)] boot=$(g boot)" ;;
	*'boot_id) $(cut'*) out="$(g boot) 999" ;;
	*"cat /proc/sys/kernel/random/boot_id"*) out=$(g boot) ;;
	*"BATMAN_VERSION=//p /etc/batman-build"*) out=$(g ver) ;;
	*"batman-slot active"*) out=$(g slot) ;;
	*"batctl n"*) out="" ;;
esac
[ -n "$out" ] && printf '%s\n' "$out"
kill_if
exit $rc
FAKE
chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH"
P=0; F=0
setup() {	# <land A|B> <holdok yes|no> [initial flag]
	[ -f "${SIM:-/nonexistent}/log" ] && cat "$SIM/log" >> "$W/all.log"
	export SIM=$W/sim; rm -rf "$SIM"; mkdir -p "$SIM"
	echo A > "$SIM/slot"; echo V9 > "$SIM/ver"; echo 1 > "$SIM/trial"; echo "${3:-}" > "$SIM/flag"; echo b0 > "$SIM/boot"; echo 0 > "$SIM/n"
	echo "$1" > "$SIM/land"; echo "$2" > "$SIM/holdok"; echo no > "$SIM/held"; : > "$SIM/log"
}
run() { FI_PAYLOAD=/opt/batdata/ota.tar.gz NEGCTL_MAXWAIT=60 bash "$REPO/scripts/negctl-old-slot-254.sh" n2 > "$W/out" 2>&1; echo $?; }
chk() { if eval "$2"; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1"; F=$((F + 1)); sed 's/^/      /' "$SIM/log"; tail -5 "$W/out" | sed 's/^/      /'; fi; }
final() { echo "$(cat "$SIM/slot") $(cat "$SIM/ver") $(cat "$SIM/trial") [$(cat "$SIM/flag")]"; }

setup B yes; r=$(run)
chk "1 success: rc 0, back on A/V9 committed, no flag" '[ "$r" = 0 ] && [ "$(final)" = "A V9 1 []" ]'
chk "1 success: exactly one rollback, guarded, issued on B" '[ "$(grep -c ROLLBACK "$SIM/log")" = 1 ] && grep -q "ROLLBACK guarded on=B" "$SIM/log"'
chk "1 success: the old build FAILed the judge (NEGCTL line)" 'grep -q "NEGCTL: ble-privacy-254 FAILs on V2" "$W/out"'

setup B no; r=$(run)
chk "2 hold not effective: rc 2, back on A, never PASS/FAIL" '[ "$r" = 2 ] && [ "$(final | cut -c1-6)" = "A V9 1" ] && ! grep -q NEGCTL "$W/out"'

setup A yes; r=$(run)
chk "3 tryboot lands on A: rc 2, still A/V9, only guarded rollbacks" '[ "$r" = 2 ] && [ "$(final | cut -c1-6)" = "A V9 1" ] && ! grep -q UNGUARDED "$SIM/log"'
chk "3 tryboot lands on A: a guarded rollback sent there did nothing" '[ "$(cat "$SIM/slot")" = A ]'

setup B yes; SIM_KILL_ON="sysupgrade -n" r=$(SIM_KILL_ON="sysupgrade -n" run)
chk "4 interrupt right after the OTA was sent: the hold flag is NOT deleted" '! grep -q RMFLAG "$SIM/log"'
chk "4 interrupt after OTA: node brought back to A (guarded)" '[ "$(final | cut -c1-6)" = "A V9 1" ] && ! grep -q UNGUARDED "$SIM/log"'

setup B yes; r=$(SIM_KILL_ON="> /opt/batdata/state/autocommit-hold-commit" run)
chk "5 interrupt in PHASE=pre after writing the flag: flag deleted + read back, no OTA" 'grep -q RMFLAG "$SIM/log" && ! grep -q OTA "$SIM/log" && [ "$(final)" = "A V9 1 []" ]'

setup B yes; r=$(SIM_KILL_ON="batctl n" run)
chk "6 interrupt after the return to A: no second rollback" '[ "$(grep -c ROLLBACK "$SIM/log")" = 1 ] && [ "$(final | cut -c1-6)" = "A V9 1" ]'

setup B yes OLD; r=$(run)
chk "7 a pre-existing hold flag: precondition FAIL, that flag is left alone, no OTA" '[ "$r" = 1 ] && ! grep -q RMFLAG "$SIM/log" && ! grep -q OTA "$SIM/log" && [ "$(cat "$SIM/flag")" = OLD ]'

cat "$SIM/log" >> "$W/all.log"
chk "every rollback the script sent, in every case, carried the slot-B guard" '[ -s "$W/all.log" ] && ! grep -q UNGUARDED "$W/all.log"'
echo "$P passed, $F failed"
[ "$F" = 0 ] && [ "$P" -gt 0 ]
