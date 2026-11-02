#!/bin/bash
# tests/prov-p1/addr-defer.sh — see the header below; takes the decider and the PATCHED openmanetd init (INIT_STOCK=<stock init> adds the negative control)
# tests/prov-p1/addr-defer.sh <batman-addr-defer> <openmanetd.init (patched)> — #254 B-M4 (254-p1-impl.md §13.8.2).
# Stubbed, no root, no node: fake hexdump (DT tryboot), ubus (procd env), pidof, logger, setsid; a fake
# /etc/init.d/openmanetd (sed'd into a COPY of the decider) that records each start and can be made to hang.
#   decision:  tryboot=0 -> stock; tryboot=1 -> defer; tryboot=1 + slot-committed -> stock; no run dir -> defer
#   status:    want/env/openmanetd fields
#   reconcile: stock+present -> exactly one start; singleton while it runs; cap 3/boot then HUNG rc 2;
#              defer+present -> nothing; stock+absent -> nothing; env unknown -> nothing
#   init hook: the patched init under a stub rc.common sets the env iff the decider says defer; the stock init never does
set -u
DEC=$1; INIT=${2:-}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"; chmod 700 "$T/run"; fails=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
# stubs driven by files: $T/dt (tryboot byte), $T/ubus.out, $T/pidof.rc
cat > "$T/bin/hexdump" <<EOF
#!/bin/sh
cat $T/dt
EOF
cat > "$T/bin/ubus" <<EOF
#!/bin/sh
[ "\$1" = -t ] || exit 1          # a call without a timeout is wrong (A12-m5)
[ -f $T/ubus.fail ] && exit 1
cat $T/ubus.out
EOF
cat > "$T/bin/pidof" <<EOF
#!/bin/sh
exit \$(cat $T/pidof.rc)
EOF
printf '#!/bin/sh\necho "$*" >> %s/logger.out\n' "$T" > "$T/bin/logger"
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/setsid"
# the fake init: records a start; hangs while $T/hang exists
cat > "$T/omd.init" <<EOF
#!/bin/sh
echo "\$1 \$\$ LEAK=\${BATMAN_FAULT_INJECT:-none}" >> $T/starts
while [ -f $T/hang ]; do sleep 1; done
EOF
chmod +x "$T"/bin/* "$T/omd.init"
printf 'batman_rundir(){ [ -f %s/nornd ] && return 1; return 0; }\nbatman_tmp(){ mktemp %s/run/t.XXXXXX; }\nRUNDIR=%s/run\n' "$T" "$T" "$T" > "$T/rundir.sh"
sed -e "s#/usr/lib/batman/rundir.sh#$T/rundir.sh#g" -e "s#/etc/init.d/openmanetd#$T/omd.init#g" -e "s#env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin #env -i PATH=$T/bin:/usr/bin:/bin #" "$DEC" > "$T/dec"; chmod +x "$T/dec"
D="$T/dec"; export PATH="$T/bin:$PATH"
tryboot(){ printf '%s' "$1" > "$T/dt"; }
envp(){ case "$1" in present) printf '{"openmanetd":{"instances":{"instance1":{"running":true,"pid":5,"env":{"ALFRED.DATATYPES.ADDRESSRESERVATION":"false"}}}}}' > "$T/ubus.out";;
	absent) printf '{"openmanetd":{"instances":{"instance1":{"running":true,"pid":5}}}}' > "$T/ubus.out";;
	noinst) printf '{"openmanetd":{}}' > "$T/ubus.out";; esac; rm -f "$T/ubus.fail"; }
reset(){ rm -f "$T/run"/* "$T/starts" "$T/hang" "$T/nornd" "$T/logger.out"; echo 0 > "$T/pidof.rc"; }

# --- decision
reset; tryboot 00000000; "$D" >/dev/null 2>&1; [ $? = 1 ] && ok "tryboot=0 -> stock" || no "tryboot=0 should be stock"
reset; tryboot 00000001; e=$("$D" 2>&1 >/dev/null); rc=$?; [ $rc = 0 ] && ok "tryboot=1 -> defer" || no "tryboot=1 should defer"
[ -z "$e" ] && [ "$(grep -c deferring "$T/logger.out" 2>/dev/null)" = 1 ] && ok "decision logged once via logger, nothing on stderr (procd relays stderr)" || no "decision logging: stderr=[$e] logger=$(grep -c deferring "$T/logger.out" 2>/dev/null)"
reset; tryboot 00000001; : > "$T/run/slot-committed"; "$D" >/dev/null 2>&1; [ $? = 1 ] && ok "tryboot=1 + slot-committed -> stock" || no "slot-committed should make it stock"
reset; tryboot 00000001; : > "$T/nornd"; "$D" >/dev/null 2>&1; [ $? = 0 ] && ok "tryboot=1, run dir unusable -> defer (fail-closed)" || no "unusable run dir should defer"
reset; tryboot ""; "$D" >/dev/null 2>&1; [ $? = 1 ] && ok "no DT node -> stock (an ordinary boot)" || no "missing DT should be stock"
# the decider must not touch a disk: no mount/umount/batman-slot anywhere in it
sed "s/#.*//" "$DEC" | grep -qE "(^|[^a-z-])(mount|umount|batman-slot)([^a-z-]|$)" && no "decider calls mount/umount/batman-slot" || ok "decider code never mounts or calls batman-slot (comments excluded)"

# --- status
reset; tryboot 00000001; envp present; [ "$("$D" status)" = "want=defer env=present openmanetd=up" ] && ok "status trial+deferred" || no "status: $("$D" status)"
reset; tryboot 00000000; envp present; echo 1 > "$T/pidof.rc"; [ "$("$D" status)" = "want=stock env=present openmanetd=down" ] && ok "status committed+deferred+down" || no "status: $("$D" status)"
reset; tryboot 00000000; envp absent; : > "$T/ubus.fail"; [ "$("$D" status)" = "want=stock env=unknown openmanetd=up" ] && ok "status ubus failure -> env=unknown" || no "status: $("$D" status)"
reset; tryboot 00000000; envp noinst; [ "$("$D" status)" = "want=stock env=absent openmanetd=up" ] && ok "status no instance -> env=absent" || no "status: $("$D" status)"

# --- reconcile
starts(){ if [ -f "$T/starts" ]; then wc -l < "$T/starts"; else echo 0; fi; }
reset; tryboot 00000000; envp present; "$D" reconcile >/dev/null 2>&1; r=$?; sleep 1; [ "$r" = 0 ] && [ "$(starts)" = 1 ] && ok "stock+present -> one start (rc 0)" || no "stock+present: rc=$r starts=$(starts)"
"$D" reconcile >/dev/null 2>&1; sleep 1; [ "$(starts)" = 2 ] && ok "second tick, previous start finished -> second start" || no "second start: starts=$(starts)"
reset; tryboot 00000000; envp present; : > "$T/hang"; "$D" reconcile >/dev/null 2>&1; sleep 1; "$D" reconcile >/dev/null 2>&1; r=$?; "$D" reconcile >/dev/null 2>&1; sleep 1
[ "$(starts)" = 1 ] && [ "$r" = 0 ] && ok "singleton: a hung start is not stacked (still within its time, rc 0)" || no "singleton: starts=$(starts) rc=$r"
# the same start, pretended to have been sent long ago -> HUNG rc 2, logged ONCE (B12-m1, A12-m7)
u=$(cut -d. -f1 /proc/uptime); [ "$u" -lt 61 ] && sleep $((61 - u))   # the decider measures from /proc/uptime (a fresh WSL VM is young)
read -r hp _ < "$T/run/addr-defer.start.pid"; echo "$hp 1" > "$T/run/addr-defer.start.pid"
"$D" reconcile >/dev/null 2>&1; r1=$?; "$D" reconcile >/dev/null 2>&1; r2=$?; sleep 1
[ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$(starts)" = 1 ] && ok "a start still running after 60 s -> HUNG rc 2, no new start" || no "hung start: rc=$r1/$r2 starts=$(starts)"
[ "$(grep -c HUNG "$T/logger.out" 2>/dev/null)" = 1 ] && ok "HUNG logged once per boot (two ticks, one line)" || no "HUNG log lines: $(grep -c HUNG "$T/logger.out" 2>/dev/null)"
rm -f "$T/hang"; sleep 2
grep -q 'LEAK=none' "$T/starts" && ok "reconcile start: caller environment not leaked (env -i)" || no "reconcile env leak: $(cat "$T/starts")"
reset; tryboot 00000000; envp present; for i in 1 2 3; do "$D" reconcile >/dev/null 2>&1; sleep 1; done; "$D" reconcile >/dev/null 2>&1; r=$?; sleep 1
[ "$r" = 2 ] && [ "$(starts)" = 3 ] && ok "cap: 3 starts per boot, 4th -> HUNG rc 2" || no "cap: rc=$r starts=$(starts)"
reset; tryboot 00000001; envp absent; "$D" reconcile >/dev/null 2>&1; "$D" reconcile >/dev/null 2>&1
[ "$(grep -c 'reservation ON' "$T/logger.out" 2>/dev/null)" = 1 ] && ok "trial without the deferral: WARN once per boot" || no "trial WARN lines: $(grep -c 'reservation ON' "$T/logger.out" 2>/dev/null)"
reset; tryboot 00000001; envp present; "$D" reconcile >/dev/null 2>&1; r=$?; sleep 1; [ "$r" = 0 ] && [ "$(starts)" = 0 ] && ok "defer+present -> nothing" || no "defer+present: rc=$r starts=$(starts)"
reset; tryboot 00000000; envp absent; "$D" reconcile >/dev/null 2>&1; r=$?; sleep 1; [ "$r" = 0 ] && [ "$(starts)" = 0 ] && ok "stock+absent -> nothing" || no "stock+absent: starts=$(starts)"
reset; tryboot 00000000; envp present; : > "$T/ubus.fail"; "$D" reconcile >/dev/null 2>&1; r=$?; sleep 1; [ "$r" = 0 ] && [ "$(starts)" = 0 ] && ok "env unknown -> nothing" || no "env unknown: starts=$(starts)"
reset; tryboot 00000000; envp present; : > "$T/nornd"; "$D" reconcile >/dev/null 2>&1; r=$?; sleep 1; [ "$r" = 0 ] && [ "$(starts)" = 0 ] && ok "run dir unusable -> report only, no start" || no "nornd: starts=$(starts)"

# --- the init hook (patched init under a stub rc.common): env set iff the decider defers
if [ -n "$INIT" ]; then
	mkdir -p "$T/root/usr/libexec"; cp "$D" "$T/root/usr/libexec/batman-addr-defer"
	cat > "$T/rc.common" <<EOF
#!/bin/sh
procd_open_instance(){ :; }; procd_close_instance(){ :; }
procd_set_param(){ [ "\$1" = env ] && echo "ENV \$2" >> $T/env.out; :; }
procd_add_reload_trigger(){ :; }; procd_add_interface_trigger(){ :; }
. "\$1"
start_service
EOF
	runinit(){ rm -f "$T/env.out"; sed "s#/usr/libexec/batman-addr-defer#$T/root/usr/libexec/batman-addr-defer#g" "$1" > "$T/init.run"; sh "$T/rc.common" "$T/init.run"; cat "$T/env.out" 2>/dev/null; }
	reset; tryboot 00000001; [ "$(runinit "$INIT")" = "ENV ALFRED.DATATYPES.ADDRESSRESERVATION=false" ] && ok "patched init: trial -> env set" || no "patched init trial: [$(runinit "$INIT")]"
	reset; tryboot 00000000; [ -z "$(runinit "$INIT")" ] && ok "patched init: committed -> no env" || no "patched init committed set env"
	reset; tryboot 00000001; rm -f "$T/root/usr/libexec/batman-addr-defer"; [ -z "$(runinit "$INIT")" ] && ok "patched init without the decider -> stock" || no "init without decider set env"
	if [ -n "${INIT_STOCK:-}" ]; then reset; tryboot 00000001; cp "$D" "$T/root/usr/libexec/batman-addr-defer"; [ -z "$(runinit "$INIT_STOCK")" ] && ok "stock init (negative control): never sets env" || no "stock init set env"; fi
fi
echo "ADDR-DEFER fails=$fails"; [ $fails = 0 ]
