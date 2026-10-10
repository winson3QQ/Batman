#!/bin/sh
# test-payload-guardian.sh — offline white-box test of the payload guardian body (#274 §12 v8.2,
# feed/batman-provision/files/usr/lib/batman/payload-guardian-run.sh) and start_service's shutdown check.
# A docker STUB and a payload-run STUB on PATH model containers as files; time is a fake /proc/uptime the test
# advances (PAYLOAD_UPTIME_FILE), the loop polls every real second (PAYLOAD_POLL=1, PAYLOAD_INTERVAL=1).
# Exit 0 = all pass.
# shellcheck disable=SC2034
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
L="$REPO/feed/batman-provision/files/usr/lib/batman"
G="$L/payload-guardian-run.sh"
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
S="$T/stub"; A="$T/apps"; R="$T/run"; UPF="$T/uptime"
mkdir -p "$S/c" "$T/bin" "$A/t" "$R" "$T/golden"
PASS=0; FAIL=0
ok(){ echo "PASS $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); }
setup(){ echo "$1.00 1.00" > "$UPF"; }
adv(){ u=$(cut -d. -f1 "$UPF"); echo "$((u + $1)).00 1.00" > "$UPF"; }
BBP=""
if [ "${BUSYBOX:-0}" = 1 ]; then
	bb=$(command -v busybox) || { echo "FAIL BUSYBOX=1 but no busybox on PATH"; exit 1; }
	mkdir -p "$T/bb"; for a in $("$bb" --list); do ln -s "$bb" "$T/bb/$a"; done
	BBP="$T/bb:"; echo "== busybox mode: $("$bb" | head -1)"
fi
export DOCKER_STUB="$S" APPS_DIR="$A" PAYLOAD_RUNDIR="$R" PAYLOAD_LIB="$L/payload-lib.sh" PAYLOAD_GOLDEN_ROOT="$T/golden" \
	PAYLOAD_RUN="$T/bin/payload-run" PAYLOAD_UPTIME_FILE="$UPF" PAYLOAD_POLL=1 PAYLOAD_INTERVAL=1 PATH="$T/bin:$BBP$PATH"

cat > "$T/bin/docker" <<'STUB'
#!/bin/sh
S=$DOCKER_STUB; echo "$*" >> "$S/calls"
c(){ cat "$S/c/$1/$2" 2>/dev/null; }
case "$1" in
info) [ -f "$S/down" ] && exit 1; case "$*" in *LiveRestore*) cat "$S/liverestore" 2>/dev/null || echo false ;; esac; exit 0 ;;
volume) exit 0 ;;
update) [ "$2" = --restart ] && echo "$3" > "$S/c/$4/policy"; exit 0 ;;
inspect) shift; fmt=""; [ "$1" = -f ] && { fmt=$2; shift 2; }; n=$1; d="$S/c/$n"; [ -d "$d" ] || exit 1
	case "$fmt" in
		*HostConfig.Privileged*) if [ -f "$d/danger" ]; then echo 'true|host||private|||private|1|0|SYS_ADMIN |seccomp=unconfined |0'
		                         else echo 'false|t-net||private|||private|0|0||no-new-privileges |0'; fi ;;
		*Mounts*) cat "$d/mounts" 2>/dev/null ;;
		*RestartPolicy*) echo "/$n $(c $n policy) $(c $n rcount) $(c $n label) $(c $n started)" ;;
		*State.Status*Restarting*) echo "$(c $n status) false $(c $n label)" ;;
		*batman.cfg*) c $n label ;;
		*Name*) echo "/$n" ;;
		"") echo "{}" ;;
	esac ;;
ps) t=$(echo "$*" | sed -n 's/.*label=batman.tenant=\([^ ]*\).*/\1/p')
	for d in "$S"/c/*/; do [ -d "$d" ] || continue; n=$(basename "$d"); ct=$(c $n tenant)
		case "$*" in
			*'{{.ID}}:{{.Names}}:'*) echo "$n:$n:$ct" ;;
			*'{{.ID}}:'*) echo "$n:$ct" ;;
			*-aq*) [ "$ct" = "$t" ] && echo "$n" ;;
			*) [ "$ct" = "$t" ] && echo "$n $(c $n status)" ;;
		esac; done ;;
esac
exit 0
STUB
cat > "$T/bin/payload-run" <<'STUB'
#!/bin/sh
S=$DOCKER_STUB; echo "$*" >> "$S/prcalls"
cfg=$(cat "$S/cfg")
case "$1" in
--cfg-hash) echo "$cfg" ;;
--converge) for n in db app; do mkdir -p "$S/c/$n"; echo running > "$S/c/$n/status"; echo "$cfg" > "$S/c/$n/label"; echo t > "$S/c/$n/tenant"
		[ -f "$S/c/$n/policy" ] || echo no > "$S/c/$n/policy"; echo 0 > "$S/c/$n/rcount"; echo "s$(date +%s%N)" > "$S/c/$n/started"; done ;;
--restart-exited) [ -f "$S/pr-rc" ] && exit "$(cat "$S/pr-rc")"
	for d in "$S"/c/*/; do n=$(basename "$d"); [ "$(cat "$d/tenant")" = "$2" ] || continue
		[ "$(cat "$d/status")" = exited ] && { echo running > "$d/status"; echo "s$(date +%s%N)" > "$d/started"; }; done ;;
esac
exit 0
STUB
printf '#!/bin/sh\necho "$*" >> "%s/syslog"\n' "$T" > "$T/bin/logger"
chmod +x "$T/bin/docker" "$T/bin/payload-run" "$T/bin/logger"
printf 'NETWORK_NAME t-net\nCONTAINER db\nIMAGE i/db\nENDCONTAINER\nCONTAINER app\nIMAGE i/app\nSTOPTIER 1\nENDCONTAINER\n' > "$A/t/t.manifest"
echo CFG1 > "$S/cfg"
LED="$R/batman-payload-t-restarts"; DF="$R/batman-payload-t-drift.json"; VL="$R/batman-payload-t-verify.log"; AL="$R/batman-payload-t-host-alarm"
status(){ sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$DF" 2>/dev/null; }
waitfor(){ i=0; while ! eval "$1"; do i=$((i+1)); [ "$i" -ge "${2:-15}" ] && return 1; sleep 1; done; return 0; }
GP=""
gstart(){ sh "$G" t >> "$T/glog" 2>&1 & GP=$!; }   # sh = busybox ash in BUSYBOX=1 mode
gstop(){ [ -n "$GP" ] && kill "$GP" 2>/dev/null; wait "$GP" 2>/dev/null; GP=""; }
tick(){ rm -f "$DF"; adv "${1:-1}"; waitfor '[ -s "$DF" ]' 10; }
mkc(){ mkdir -p "$S/c/$1"; echo "${2:-running}" > "$S/c/$1/status"; echo "${3:-CFG1}" > "$S/c/$1/label"; echo "${4:-t}" > "$S/c/$1/tenant"
	echo "${5:-no}" > "$S/c/$1/policy"; echo 0 > "$S/c/$1/rcount"; echo "s$1" > "$S/c/$1/started"; }

# 1 start-up: an exited stack (as after every boot with --restart no) is converged; .up marks the instance
setup 1000; mkc db exited; mkc app exited
gstart
waitfor 'grep -q -- "--converge t" "$S/prcalls" 2>/dev/null' && [ -e "$R/batman-payload-t.up" ] || waitfor '[ -e "$R/batman-payload-t.up" ]'
grep -q -- "--converge t" "$S/prcalls" && [ -e "$R/batman-payload-t.up" ] && ok "1 start-up converge ran, .up created" || no "1 no converge/.up"
[ ! -s "$LED" ] && ok "1 the start-up converge is not a ledger record" || no "1 ledger after start-up: $(cat "$LED")"
tick 1; [ "$(status)" = OK ] && ok "1 first verdict OK (ordered start, no restarts)" || { no "1 verdict $(status)"; cat "$VL"; }

# 2 crash: restarted at once on whatever config, ledgered, DRIFT for the 600 s window, then OK
echo exited > "$S/c/app/status"; adv 1
waitfor 'grep -q "crash app" "$LED" 2>/dev/null' && [ "$(cat "$S/c/app/status")" = running ] && grep -q -- "--restart-exited t" "$S/prcalls" \
	&& ok "2 crash: restart-exited within a poll, ledger 'crash app'" || no "2 crash not restarted: $(cat "$LED" 2>/dev/null)"
tick 1; [ "$(status)" = DRIFT ] && grep -q "restarted a container" "$VL" && ok "2 DRIFT right after the restart" || no "2 verdict $(status)"
tick 590; [ "$(status)" = DRIFT ] && ok "2 still DRIFT inside the 600 s window (a crash in a trial reverts it, §12.13)" || no "2 verdict $(status) at +592"
tick 15; [ "$(status)" = OK ] && ok "2 OK once the window passed" || { no "2 verdict $(status) after the window"; cat "$VL"; }

# 3 backoff: a container that will not stay up — attempts at +0, +10, +20, +40 (fake seconds), not earlier
echo 1 > "$S/pr-rc"; adv 700; base=$(cut -d. -f1 "$UPF"); : > "$LED"
echo exited > "$S/c/app/status"
waitfor '[ "$(grep -c "crash app" "$LED")" -ge 1 ]' || no "3 no first attempt"
adv 5; sleep 3; [ "$(grep -c "crash app" "$LED")" = 1 ] && ok "3 no second attempt 5 s after the first" || no "3 early 2nd attempt: $(cat "$LED")"
adv 5; waitfor '[ "$(grep -c "crash app" "$LED")" -ge 2 ]' && ok "3 second attempt at +10" || no "3 no attempt at +10"
adv 15; sleep 3; [ "$(grep -c "crash app" "$LED")" = 2 ] && ok "3 no third attempt 15 s after the second" || no "3 early 3rd"
adv 5; waitfor '[ "$(grep -c "crash app" "$LED")" -ge 3 ]' && ok "3 third attempt at +20 after the second" || no "3 no 3rd"
adv 39; sleep 3; [ "$(grep -c "crash app" "$LED")" = 3 ] && ok "3 no fourth attempt 39 s after the third" || no "3 early 4th"
adv 1; waitfor '[ "$(grep -c "crash app" "$LED")" -ge 4 ]' && ok "3 fourth attempt at +40" || no "3 no 4th"
rm -f "$S/pr-rc"; echo running > "$S/c/app/status"

# 4 rc 4/5 (stopping, lock busy) is cancelled, not counted
adv 700; : > "$LED"; echo 5 > "$S/pr-rc"; echo exited > "$S/c/app/status"
waitfor 'grep -q cancel "$LED"' && ok "4 lock busy (rc 5): a cancel line follows the record" || no "4 no cancel: $(cat "$LED")"
rm -f "$S/pr-rc"; echo running > "$S/c/app/status"; tick 1
[ "$(status)" = OK ] && ok "4 a cancelled attempt does not make the tenant DRIFT" || { no "4 verdict $(status)"; cat "$VL"; }

# 5 .stopping / shutdown marker: an exited container is neither restarted nor recorded
: > "$LED"; : > "$R/batman-payload-t.stopping"; echo exited > "$S/c/app/status"; adv 1; sleep 3
[ "$(cat "$S/c/app/status")" = exited ] && ! grep -q "crash" "$LED" && ok "5 .stopping: no restart, no record" || no "5 restarted/recorded while stopping"
rm -f "$R/batman-payload-t.stopping"; : > "$R/batman-shutdown"; adv 1; sleep 3
[ "$(cat "$S/c/app/status")" = exited ] && ! grep -q "crash" "$LED" && ok "5 shutdown marker: no restart, no record" || no "5 restarted/recorded while shutting down"
rm -f "$R/batman-shutdown"; waitfor '[ "$(cat "$S/c/app/status")" = running ]' && ok "5 restarted once the stop flags are gone" || no "5 not restarted after"
adv 700; tick 1

# 6 bypass: a manifest-name container without our label is never started, DRIFT names it
echo other > "$S/c/app/tenant"; echo exited > "$S/c/app/status"; : > "$LED"; tick 1; sleep 2
[ "$(cat "$S/c/app/status")" = exited ] && [ "$(status)" = DRIFT ] && grep -q "app is not ours" "$VL" && ! grep -q crash "$LED" \
	&& ok "6 bypass container: not started, DRIFT 'not ours', not ledgered" || { no "6 bypass"; cat "$VL"; }
echo t > "$S/c/app/tenant"; waitfor '[ "$(cat "$S/c/app/status")" = running ]'; adv 700; tick 1

# 7 policy: `docker update --restart always` on a current-config container is reset and ledgered once; an
#   old-config container is reset but not ledgered; RestartCount > 0 ledgered once per (id, started)
: > "$LED"; echo always > "$S/c/db/policy"; tick 1
[ "$(cat "$S/c/db/policy")" = no ] && [ "$(grep -c "policy db" "$LED")" = 1 ] && ok "7 restart policy reset to no, ledgered once" || no "7 policy: $(cat "$S/c/db/policy") / $(cat "$LED")"
tick 1; [ "$(grep -c "policy db" "$LED")" = 1 ] && ok "7 not ledgered again on the next tick" || no "7 ledgered twice"
mkc old running OLDCFG t always; tick 1
[ "$(cat "$S/c/old/policy")" = no ] && ! grep -q "policy old" "$LED" && ok "7 old-config container: policy reset, not ledgered (L-OTA1)" || no "7 old: $(cat "$S/c/old/policy") / $(cat "$LED")"
rm -rf "$S/c/old"; echo 2 > "$S/c/app/rcount"; tick 1
[ "$(grep -c "policy app" "$LED")" = 1 ] && ok "7 RestartCount > 0 ledgered" || no "7 rcount not ledgered"
gstop; gstart; sleep 3; tick 1
[ "$(grep -c "policy app" "$LED")" = 1 ] && ok "7 dedupe holds across a guardian respawn (ledger, not memory)" || no "7 rcount ledgered again after respawn: $(cat "$LED")"
echo 0 > "$S/c/app/rcount"; adv 700; tick 1

# 8 missing: the guardian exits for respawn with a 'missing' record; the respawn's converge rebuilds and is ledgered
: > "$LED"; rm -rf "$S/c/app"; adv 1
waitfor 'grep -q "exiting for respawn" "$T/glog"' && grep -q "missing app" "$LED" && ok "8 missing container: ledger 'missing app', guardian exited for respawn" || no "8 missing: $(cat "$LED")"
wait "$GP" 2>/dev/null; GP=""; gstart; waitfor '[ -d "$S/c/app" ]' && waitfor 'grep -q "respawn" "$LED"' && ok "8 respawn: converge rebuilt it, ledgered 'respawn'" || no "8 respawn: $(cat "$LED")"
rm -rf "$S/c/app"; adv 1; sleep 3
kill -0 "$GP" 2>/dev/null && ok "8 a second missing within 600 s does not exit again" || no "8 exited twice"
tick 1; grep -q "app missing" "$VL" && ok "8 DRIFT 'missing'" || no "8 no missing in verify"
mkc app; adv 700; tick 1

# 9 golden tenant: scripts run from the image; a changed golden file is DRIFT; an extra p6 file is a host alarm
gstop; mkdir -p "$T/golden/t"; cp "$A/t/t.manifest" "$T/golden/t/"
printf '#!/bin/sh\nexit 0\n' > "$T/golden/t/verify-profile-t.sh"; cp "$T/golden/t/verify-profile-t.sh" "$A/t/"
printf '#!/bin/sh\ntouch "%s/p6-ran"\n' "$T" > "$A/t/verify-profile-zz.sh"; chmod +x "$T/golden/t/"*.sh "$A/t/"*.sh
gstart; sleep 2; : > "$LED"; tick 1
[ ! -e "$T/p6-ran" ] && ok "9 a planted p6 verify-profile-zz.sh is never executed" || no "9 p6 script executed"
grep -q "verify-profile-zz.sh is not from the image" "$AL" && [ "$(status)" = OK ] && ok "9 extra p6 file: host alarm, verdict stays OK" || { no "9 extra file: $(status)"; cat "$AL" "$VL"; }
echo "# p6 edit" >> "$A/t/verify-profile-t.sh"; tick 1
[ "$(status)" = DRIFT ] && grep -q "p6 file verify-profile-t.sh differs from the image" "$VL" && ok "9 changed golden file on p6: DRIFT" || { no "9 golden diff: $(status)"; cat "$VL"; }
cp "$T/golden/t/verify-profile-t.sh" "$A/t/"; rm -f "$A/t/verify-profile-zz.sh"; tick 1

# 10 host alarm: a dangerous foreign container; live-restore on — never in the verdict
mkc lora exited x "" no; : > "$S/c/lora/danger"; echo "" > "$S/c/lora/tenant"; echo true > "$S/liverestore"; tick 1
grep -q "foreign-container lora" "$AL" && grep -q "live-restore is on" "$AL" && [ "$(status)" = OK ] \
	&& ok "10 foreign dangerous container + live-restore: host alarm, verdict OK" || { no "10 alarm"; cat "$AL"; echo "status $(status)"; cat "$VL"; }
grep -q "host alarm: foreign-container lora" "$T/syslog" && ok "10 the new alarm line was logged" || no "10 not logged"
rm -rf "$S/c/lora" "$S/liverestore"; tick 1; [ ! -s "$AL" ] && ok "10 alarm cleared" || no "10 alarm not cleared: $(cat "$AL")"
# 10b a tenant label does not hide a container the manifest does not list (security review #3); a harmless
#     labelled orphan raises nothing
mkc hide running CFG1 t no; : > "$S/c/hide/danger"; mkc orph running CFG1 t no; tick 1
grep -q "foreign-container hide" "$AL" && ! grep -q "orph" "$AL" \
	&& ok "10b dangerous container labelled for the tenant but not in its manifest: host alarm; harmless orphan: none" || { no "10b"; cat "$AL"; }
rm -rf "$S/c/hide" "$S/c/orph"; tick 1; [ ! -s "$AL" ] && ok "10b alarm cleared" || no "10b alarm not cleared: $(cat "$AL")"

# 11 ledger unwritable: DRIFT (fail-closed)
gstop; rm -f "$LED"; mkdir "$LED"; gstart; sleep 2; echo exited > "$S/c/app/status"; adv 1; sleep 2; tick 1
[ "$(status)" = DRIFT ] && grep -q "ledger unwritable" "$VL" && ok "11 ledger unwritable: DRIFT" || { no "11 $(status)"; cat "$VL"; }
gstop; rmdir "$LED"

# 14 a crash is DRIFT at once, not at the next tick (fi-c1 on 1.5.8-wsl.1: a stale OK verdict < 1 min old let
#    autocommit commit a trial 21 s after a crash). Ticks are made impossible (interval 100000, fake time frozen),
#    so only the immediate publish can turn the verdict to DRIFT.
echo running > "$S/c/app/status"; echo running > "$S/c/db/status"
PAYLOAD_INTERVAL=100000 sh "$G" t >> "$T/glog" 2>&1 & GP=$!
sleep 3; echo '{"status":"OK","tenant":"t","ts":0,"detail":"x"}' > "$DF"
echo 1 > "$S/pr-rc"; echo exited > "$S/c/app/status"; sleep 3
[ "$(status)" = DRIFT ] && grep -q "container(s) down: app" "$DF" && ok "14 a down container is published DRIFT within a poll, no tick needed" || { no "14 verdict still $(status) without a tick"; cat "$DF"; }
rm -f "$S/pr-rc"; echo running > "$S/c/app/status"; gstop

# 12 start_service refuses while the shutdown marker exists (a late start never undoes a shutdown)
r=$( procd_open_instance(){ echo OPENED; }; procd_set_param(){ :; }; procd_close_instance(){ :; }
	PAYLOAD_TENANT=t; . "$L/payload-guardian.sh"; : > "$R/batman-shutdown"; start_service; echo "rc=$?" )
rm -f "$R/batman-shutdown"
case "$r" in *OPENED*) no "12 start_service started despite the marker" ;; *rc=1*) ok "12 start_service refuses with the shutdown marker" ;; *) no "12 $r" ;; esac
r=$( procd_open_instance(){ echo OPENED; }; procd_set_param(){ :; }; procd_close_instance(){ :; }
	PAYLOAD_TENANT=t; . "$L/payload-guardian.sh"; : > "$R/batman-payload-t.up"; start_service; [ -e "$R/batman-payload-t.up" ] && echo UP-KEPT )
case "$r" in *OPENED*) case "$r" in *UP-KEPT*) no "12 start_service kept .up" ;; *) ok "12 start_service removes .up (a later .up = procd respawn)" ;; esac ;; *) no "12 no start: $r" ;; esac

if [ -n "$BBP" ]; then
	e=$(grep -E "invalid number|unrecognized option|invalid option|applet not found|syntax error|bad substitution|unknown operand|^Usage: |^BusyBox v" "$T/glog")
	[ -z "$e" ] && ok "13 busybox: no applet usage error in the guardian's output" || { no "13 busybox usage errors:"; echo "$e" | head -10; }
fi
echo "== test-payload-guardian: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
