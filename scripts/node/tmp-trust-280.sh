#!/bin/sh
# scripts/node/tmp-trust-280.sh — runtime check that a NON-ROOT process cannot steer the node through /tmp (#280).
# Run on a node as root: ssh root@node 'sh -s' < scripts/node/tmp-trust-280.sh. docs/design/280-tmp-trust.md D6 + §9.
# Safe by construction (§9 N2): the planted battery reading lives at most (CONFIRM-1)*INTERVAL-5 s and a root guard
# removes it unconditionally at that deadline, so even a fully regressed batpower can never see CONFIRM readings
# in a row — it cannot reach CRIT, so it cannot halt the node. Version-gated: never plants on a pre-#280 image.
# Exit: 0 pass, 1 FAIL, 3 + SKIP-REASON when it does not apply.
[ -r /usr/lib/batman/rundir.sh ] || { echo "SKIP-REASON: pre-#280 image (no /usr/lib/batman/rundir.sh) — nothing planted"; exit 3; }
# shellcheck source=/dev/null
. /usr/lib/batman/rundir.sh
rc=0
bad(){ echo "FAIL $*"; rc=1; }
ok(){ echo "ok   $*"; }
NB(){ start-stop-daemon -S -c nobody -n tmptrust280 -a /bin/sh -- -c "$1"; }   # busybox has no su
lsm(){ ls -ld "$1" 2>/dev/null | awk '{print $1, $3}'; }
PLANTS="/tmp/batpower.mock /tmp/batman-autocommit.hold /tmp/batman-fw-override /tmp/autocommit.committed /tmp/batman-reboot.want /tmp/autocommit.decided"
cleanup(){ for p in $PLANTS; do rm -rf "$p"; done; uci -q revert batpower; }
trap cleanup EXIT

# 1 permissions + sysctls
[ "$(lsm /tmp/run)" = "drwxr-xr-x root" ] && ok "/tmp/run root 0755" || bad "/tmp/run is [$(lsm /tmp/run)]"
batman_rundir 2>/dev/null && [ "$(lsm "$RUNDIR")" = "drwx------ root" ] && ok "$RUNDIR root 0700" || bad "run dir is [$(lsm "$RUNDIR")]"
for k in fs.protected_symlinks fs.protected_hardlinks; do [ "$(sysctl -n $k 2>/dev/null)" = 1 ] && ok "$k=1" || bad "$k=$(sysctl -n $k 2>/dev/null)"; done
# D5: whatever 90-batman.conf sets must be live (a shipped-but-not-applied sysctl protects nothing)
if [ -f /etc/sysctl.d/90-batman.conf ]; then
	for kv in $(grep -E '^fs\.[a-z_.]+=[0-9]+$' /etc/sysctl.d/90-batman.conf); do
		k=${kv%%=*}; v=${kv#*=}
		[ "$(sysctl -n "$k" 2>/dev/null)" = "$v" ] && ok "$k=$v (90-batman.conf)" || bad "$k=$(sysctl -n "$k" 2>/dev/null), 90-batman.conf wants $v"
	done
else bad "/etc/sysctl.d/90-batman.conf missing on a #280 image"; fi
# 2 a non-root process cannot create anything in /tmp/run or the run dir
NB "mkdir /tmp/run/tt280 2>/dev/null && echo MADE" | grep -q MADE && { bad "nobody created /tmp/run/tt280"; rmdir /tmp/run/tt280; } || ok "nobody cannot create in /tmp/run"
NB ": > $RUNDIR/tt280 2>/dev/null && echo MADE" | grep -q MADE && bad "nobody wrote into $RUNDIR" || ok "nobody cannot write into the run dir"
NB "id -u" | grep -qx 65534 || bad "start-stop-daemon did not run as nobody — the non-root steps verified nothing"

# 3 old /tmp markers planted by nobody are ignored; an operator flag planted by nobody is TAMPER, not honoured
NB "for p in /tmp/batman-autocommit.hold /tmp/batman-fw-override /tmp/autocommit.committed /tmp/batman-reboot.want; do echo 2 > \$p; done; mkdir /tmp/autocommit.decided"
s=$(halow-status 2>/dev/null)
echo "$s" | grep -q 'TAMPER: /tmp/batman-autocommit.hold' && ok "planted hold shown as TAMPER" || bad "planted hold not flagged by halow-status"
j=$(halow-status json 2>/dev/null)
echo "$j" | grep -q '"fw_override":""' && ok "planted /tmp/batman-fw-override ignored" || bad "fw_override not empty with only a planted /tmp file: $(echo "$j" | grep -o '"fw_override":"[^"]*"')"
u=$(cut -d. -f1 /proc/uptime)
o=$(AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$((u + 20)) batman-autocommit run 2>&1)
echo "$o" | grep -q 'TAMPER: /tmp/batman-autocommit.hold' && ok "autocommit reports the planted hold as TAMPER" || bad "autocommit did not report the planted hold"
echo "$o" | grep -q 'hold present' && bad "autocommit HONOURED a hold planted by nobody" || ok "autocommit did not honour the planted hold"

# 4 batpower: never a reading from a world-writable file (N1 oracle on both configs, N2 bounded plant)
CONF=$(uci -q get batpower.main.confirm || echo 3); IVL=$(uci -q get batpower.main.interval || echo 10)
if [ "$CONF" -lt 3 ] || [ "$IVL" -lt 10 ]; then echo "SKIP-REASON: batpower confirm=$CONF interval=$IVL — the bounded plant needs confirm>=3, interval>=10"; exit 3; fi
LIFE=$(( (CONF - 1) * IVL - 5 ))
NB "echo 1000 > /tmp/batpower.mock"
reading(){ batpower once 2>/dev/null | awk '{print $2}'; }   # "STATE V I T" -> V
[ "$(reading)" = - ] && ok "default config: planted mock not read (UNKNOWN)" || bad "default config read a value: $(batpower once)"
uci -q set batpower.main.source=mock; uci -q set batpower.main.mock_ok=1   # staged only, reverted on exit
v=$(reading); [ "$v" = 1000 ] && bad "mock config READ the planted /tmp value (old code path)" || ok "mock config: /tmp plant not read (reads the run dir: $v)"
# negative control: point the once-only seam at the planted file — the oracle must see it
[ "$(BATPOWER_MOCK_PATH=/tmp/batpower.mock batpower once 2>/dev/null | awk '{print $2}')" = 1000 ] \
	&& ok "negative control: the seam reads the plant (the oracle can tell)" || bad "negative control did not read the plant — oracle unproven"
# daemon under the staged mock config, plant alive at most $LIFE s (guard deletes it whatever happens)
G=$(mktemp); setsid sh -c "end=\$(( \$(cut -d. -f1 /proc/uptime) + $LIFE )); while [ \$(cut -d. -f1 /proc/uptime) -lt \$end ]; do
	for s in /tmp/batpower.state $RUNDIR/batpower.state; do [ \"\$(cut -d' ' -f2 \$s 2>/dev/null)\" = 1000 ] && { rm -f /tmp/batpower.mock; echo HIT > $G; }; done
	dmesg | tail -20 | grep -q 'LOW BATTERY' && { rm -f /tmp/batpower.mock; echo LOW >> $G; }
	sleep 1; done; rm -f /tmp/batpower.mock" </dev/null >/dev/null 2>&1 &
/etc/init.d/batpower restart >/dev/null 2>&1
sleep $((LIFE + 3))
[ -e /tmp/batpower.mock ] && { rm -f /tmp/batpower.mock; bad "guard did not remove the plant"; }
[ -s "$G" ] && bad "batpower daemon read the planted value ($(tr '\n' ' ' < "$G"))" || ok "batpower daemon never read the planted value over ${LIFE}s"
rm -f "$G"
uci -q revert batpower; /etc/init.d/batpower restart >/dev/null 2>&1
echo "== tmp-trust-280: $([ $rc = 0 ] && echo PASS || echo FAIL)"
exit $rc
