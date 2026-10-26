#!/bin/bash
# scripts/dv/pty-commit-254.sh <node> normal|flip — #254 B12-m4 (254-p1-impl.md §13.8.2, B10-M1): `batman-slot commit` run as a
# PTY command must still release the address-reservation deferral, because addr_defer_release() sends the openmanetd
# `start` under setsid, out of the session that the PTY hangup kills.
# Scope (review M2): this models a NON-interactive PTY command (`ssh -tt node batman-slot commit`: the command is the
# session leader) — the harshest case. An interactive shell (job control) and closing the window while the commit is
# still running are NOT covered (residuals). The race between the parent's exit and the child's setsid() is measured
# separately, without an OTA (setsid-race-254.sh, review M1).
#   normal: held-trial OTA of the running version into the other slot -> on the trial assert deferral ON ->
#           joinwatch stopped (so its reconcile cannot help) -> `sleep 90 | ssh -tt node batman-slot commit` ->
#           within 20 s: committed, want=stock env=absent, openmanetd up.
#   flip:   same, but a bind-mounted batman-slot whose release start has NO setsid -> env must STAY present.
#           Restore: joinwatch start -> its reconcile clears it.
# Runs from Git Bash on the Windows host. Each run moves the node to the other slot (both slots carry V).
set -u
NODE=${1:?node}; MODE=${2:?normal|flip}; case "$MODE" in normal|flip) ;; *) echo "mode?"; exit 2;; esac
V=${V:?version}; PAY=${PAY:-/opt/batdata/ota-1.5.13-wsl.1.tar.gz}; PSH16=${PSH16:?payload sha16}
SSHO="-o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o LogLevel=ERROR"
say(){ echo "[$(date +%H:%M:%S) pty-commit $MODE $NODE] $*"; }
fails=0; ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
q(){ local o rc; for _ in 1 2 3 4 5 6; do o=$(timeout 120 ssh $SSHO root@$NODE "$@" 2>/dev/null); rc=$?; case $rc in 255|124) sleep 10;; *) printf '%s' "$o" | tr -d '\r'; [ -n "$o" ] && echo; return $rc;; esac; done; return 255; }
bid(){ timeout 20 ssh $SSHO root@$NODE 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n '; }
waitboot(){ local b0=$1 t0=$SECONDS b; while [ $((SECONDS-t0)) -lt 900 ]; do b=$(bid); [ -n "$b" ] && [ "$b" != "$b0" ] && return 0; sleep 10; done; return 1; }
settle(){ local t0=$SECONDS u; while [ $((SECONDS-t0)) -lt 600 ]; do u=$(q 'cut -d. -f1 /proc/uptime'); [ "${u:-0}" -ge 90 ] && return 0; sleep 10; done; return 1; }
FP='echo "apkey=$(uci -q get wireless.default_radio0.key | sha256sum | cut -c1-12) meshkey=$(uci -q get wireless.default_radio1.key | sha256sum | cut -c1-12) lock=$(cat /opt/batdata/state/lock-status) ak=$(sha256sum < /etc/dropbear/authorized_keys | cut -c1-12) host=$(uci -q get system.@system[0].hostname) ip=$(uci -q get network.ahwlan.ipaddr) prov=$(sed -n "s/.*state=\([a-z]*\).*/\1/p" /etc/batman-prov/prov.meta)"'
ST='echo "slot=$(batman-slot active) ver=$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build) trial_rc=$(batman-slot is-trial >/dev/null 2>&1; echo $?) dt_try=$(hexdump -v -e "1/1 \"%02x\"" /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null) held=$(ls /tmp/run/batman/autocommit.ctl/hold-commit 2>/dev/null | wc -l) badslot=[$(cat /opt/batdata/state/bad-slot 2>/dev/null)] up=$(cut -d. -f1 /proc/uptime)"'
AD='/usr/libexec/batman-addr-defer status'
# joinwatch running? from procd's own record (pgrep -f would match the ssh `sh -c` line itself, review B1)
# ubus failure = JW-UNKNOWN (never "down"); ps with the [/] pattern cross-checks (review round 2 m2)
JW='o=$(ubus call service list "{\"name\":\"joinwatch\"}" 2>/dev/null) || { echo JW-UNKNOWN; exit 0; }; p=$(ps w | grep -c "[/]usr/bin/joinwatch"); case "$o" in *"\"running\": true"*) echo JW-UP;; *) [ "$p" = 0 ] && echo JW-DOWN || echo JW-UP-ps;; esac'
EVN='logread | grep -cE "netifd.*bat0|openmanetd.*(start|Starting)"'
cleanup_node(){	# never leaves a bind mount or a stopped joinwatch behind
	q 'grep -q " /usr/sbin/batman-slot " /proc/mounts && umount /usr/sbin/batman-slot; /etc/init.d/joinwatch start >/dev/null 2>&1; sleep 2; echo "cleanup: bind=$(grep -c " /usr/sbin/batman-slot " /proc/mounts) starts=$(cat /tmp/run/batman/addr-defer.starts 2>/dev/null)"'
	q "$JW"
}
LANDED=0
# a stop after the landing commits the trial with the NORMAL batman-slot (both slots carry V): a deadline revert would
# leave bad-slot behind and block every later run (review M3); before the landing, the unused hold flag is removed
stop(){ say "STOP: $*"; cleanup_node
	if [ "$LANDED" = 1 ]; then q 'batman-slot is-trial >/dev/null 2>&1 && batman-slot commit 2>&1 | tail -1' | sed 's/^/    stop-commit: /'; else q 'rm -f /opt/batdata/state/autocommit-hold-commit'; fi
	s=$(q "$ST"); say "state at stop: $s"; echo "RESULT pty-commit $MODE FAIL ($*)"; exit 1; }
trap 'echo "host interrupted"; stop "interrupted"' INT TERM

# --- 0. preconditions
PH=$(q "sha256sum $PAY | cut -c1-16"); [ "$PH" = "$PSH16" ] || stop "payload sha [$PH] != $PSH16"
s=$(q "$ST"); say "pre: $s"; case "$s" in *"ver=$V trial_rc=1 "*"badslot=[]"*) ;; *) stop "precondition (committed $V, no bad-slot)";; esac
case "$s" in slot=A*) TGT=B;; slot=B*) TGT=A;; *) stop "slot?";; esac
a=$(q "$AD"); [ "$a" = "want=stock env=absent openmanetd=up" ] || stop "decider not at rest: $a"
# stable: reserved address, and up long enough that no reservation reboot is pending (review m4)
u=$(q 'echo "dhcp=$(uci -q get openmanetd.config.dhcpconfigured) up=$(cut -d. -f1 /proc/uptime)"'); say "stability: $u"
case "$u" in "dhcp=1 up="*) ;; *) stop "dhcpconfigured != 1";; esac
while [ "$(q 'cut -d. -f1 /proc/uptime')" -lt 150 ] 2>/dev/null; do sleep 10; done
before=$(q "$FP"); say "before: $before"

# --- 1. held-trial OTA into the other slot
q "echo '$V' > /opt/batdata/state/autocommit-hold-commit; sync"
b0=$(bid); q "setsid sh -c 'sysupgrade -n $PAY >/opt/batdata/sysup-ptyc.log 2>&1' </dev/null >/dev/null 2>&1 &"
waitboot "$b0" || stop "no reboot (sysup: $(q 'tail -3 /opt/batdata/sysup-ptyc.log'))"
settle || { LANDED=1; stop "not reachable after the OTA reboot"; }
s=$(q "$ST"); say "landed: $s"
case "$s" in *"slot=$TGT ver=$V trial_rc=0 dt_try=00000001 held=1 "*) LANDED=1; ok "held trial of $V on $TGT";;
	*"trial_rc=0 "*) LANDED=1; stop "landing (want held trial on $TGT)";; *) stop "landing (want held trial on $TGT)";; esac
a=$(q "$AD"); [ "$a" = "want=defer env=present openmanetd=up" ] && ok "trial: deferral on ($a)" || stop "trial deferral: $a"

# --- 2. joinwatch off (its reconcile would mask a lost start); the flip variant
q '/etc/init.d/joinwatch stop >/dev/null 2>&1; sleep 1' >/dev/null
q "$JW" | grep -q JW-DOWN && ok "joinwatch stopped (procd: no running instance)" || stop "joinwatch did not stop"
if [ "$MODE" = flip ]; then
	# no diff on the node (review B2): the one setsid line must go and nothing else (line count equal)
	o=$(q 'set -e; d=/tmp/run/batman-dv; mkdir -p -m 0700 $d; sed "s|PATH=/usr/sbin:/usr/bin:/sbin:/bin setsid /etc/init.d/openmanetd start|PATH=/usr/sbin:/usr/bin:/sbin:/bin /etc/init.d/openmanetd start|" /usr/sbin/batman-slot > $d/batman-slot.nosetsid; chmod 755 $d/batman-slot.nosetsid
		o1=$(grep -c "setsid /etc/init.d/openmanetd start" /usr/sbin/batman-slot); n1=$(grep -c "setsid /etc/init.d/openmanetd start" $d/batman-slot.nosetsid || true)
		l0=$(wc -l < /usr/sbin/batman-slot); l1=$(wc -l < $d/batman-slot.nosetsid)
		if [ "$o1" = 1 ] && [ "$n1" = 0 ] && [ "$l0" = "$l1" ]; then echo changed=1; mount --bind $d/batman-slot.nosetsid /usr/sbin/batman-slot; echo "binds=$(grep -c " /usr/sbin/batman-slot " /proc/mounts)"; else echo "changed=0 o1=$o1 n1=$n1 l0=$l0 l1=$l1"; fi')
	echo "$o" | sed 's/^/    /'
	case "$o" in *"changed=1"*"binds=1"*) ok "flip variant: the setsid line removed, bind-mounted";; *) stop "flip variant not built";; esac
fi

# --- 3. the commit as a PTY command; stdin kept open (`sleep 90 |`): an EOF on stdin makes dropbear close the pty
#        master while the commit still runs and SIGHUP the commit itself (review B3) — here the hangup comes only when
#        the command ends. openmanetd pid + bat0 events recorded around the window (review m1).
op0=$(q 'pidof openmanetd'); ev0=$(q "$EVN")
say "sleep 90 | ssh -tt root@$NODE batman-slot commit"
# `< <(sleep 90)`: bash does not wait for a process substitution, so step 4 starts when the commit returns (round 2 m1)
co=$(timeout 60 ssh -tt $SSHO root@$NODE 'batman-slot commit' < <(sleep 90) 2>&1 | tr -d '\r'; echo "SSHRC=${PIPESTATUS[0]}")
crc=$(sed -n 's/^SSHRC=//p' <<< "$co")
echo "$co" | grep -v '^SSHRC=' | sed 's/^/    commit: /'
grep -q "committed slot $TGT as default" <<< "$co" && ok "commit output (ssh rc $crc)" || no "commit output missing (ssh rc $crc)"

# --- 4. observe (no reconcile running): 20 s
i=0; a=""; while [ $i -lt 20 ]; do a=$(q "$AD"); [ "$a" = "want=stock env=absent openmanetd=up" ] && break; sleep 2; i=$((i + 2)); done
s=$(q "$ST"); say "after ${i}s: $a | $s"
case "$s" in *"slot=$TGT ver=$V trial_rc=1 "*) ok "slot $TGT committed";; *) no "not committed: $s";; esac
op1=$(q 'pidof openmanetd'); ev1=$(q "$EVN"); say "openmanetd pid $op0 -> $op1; bat0/openmanetd log events $ev0 -> $ev1"
if [ "$MODE" = normal ]; then
	[ "$a" = "want=stock env=absent openmanetd=up" ] && ok "deferral released from a PTY command within ${i}s ($a)" || no "deferral NOT released from a PTY command: $a"
	# the release itself restarted the instance (round 2 m3); log-event count is a log-ring line count: info only
	[ -n "$op1" ] && [ "$op0" != "$op1" ] && ok "openmanetd restarted by the release ($op0 -> $op1)" || no "openmanetd pid unchanged ($op0 -> $op1)"
	[ "$ev0" = "$ev1" ] && say "no bat0/openmanetd log event in the window" || say "WARN log events changed $ev0 -> $ev1 (another restart may have cleared the env)"
else
	case "$a" in *"env=present"*) echo "FLIP pty-commit VALID (no setsid -> the PTY hangup lost the start: $a; openmanetd pid unchanged: $([ "$op0" = "$op1" ] && echo y || echo n))";;
		*) echo "FLIP pty-commit INVALID (released even without setsid: $a)";; esac
fi

# --- 5. restore: bind off, joinwatch on; in flip its reconcile must clear the env
cleanup_node | sed 's/^/    /'
i=0; while [ $i -lt 60 ]; do a=$(q "$AD"); [ "$a" = "want=stock env=absent openmanetd=up" ] && break; sleep 3; i=$((i + 3)); done
if [ "$a" != "want=stock env=absent openmanetd=up" ]; then
	no "not at rest after restore: $a — sending one openmanetd start by hand"
	q 'env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin setsid /etc/init.d/openmanetd start </dev/null >/dev/null 2>&1 &'; sleep 10; a=$(q "$AD"); say "after manual start: $a"
else ok "at rest after restore (${i}s): $a"; fi
q "logread | grep -E 'batman-addr-defer|hold-commit|RELEASED' | tail -6" | sed 's/^/    log: /'
after=$(q "$FP"); say "after:  $after"
[ "$before" = "$after" ] && ok "AP key / mesh key / lock / authorized_keys / hostname / IP / prov unchanged" || no "per-node settings changed"
q 'ls -l /opt/batdata/state/autocommit-hold-commit 2>&1' | sed 's/^/    hold flag: /'
say "fails=$fails"
if [ "$MODE" = normal ]; then [ "$fails" = 0 ] && echo "RESULT pty-commit normal PASS" || echo "RESULT pty-commit normal FAIL"; else [ "$fails" = 0 ] || echo "(flip run had $fails FAIL lines in its own checks)"; fi
[ "$fails" = 0 ]
