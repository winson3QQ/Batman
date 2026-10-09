#!/bin/sh
# ota-start-274.sh — the checks of fault-injection case s1 (ota-start-274, #274 §12.7), run on the OTS node
# right after a same-build OTA boot has COMMITTED. Sent as `B0=<previous boot_id> sh -s < this`.
# Prints "ok N …" / "FAIL N …" lines and a final "RESULT <0|1>". Nothing here changes node state.
#   1 every manifest container's CURRENT ID has exactly one `start` event since this dockerd started
#     (independent of the guardian's own record; a revival by a restart policy + the crash-restart = 2)
#   2 the guardian's start mode ran this boot, final tier started before every other container
#   3 no DRIFT this boot, and the commit's trace has no "drift not OK"
#   4 postgres' last start followed a clean shutdown (dockerd stopped it gracefully during the OTA)
#   5 the guardian's restart ledger is empty
#   6 the OTA really went through stage 2 (S2 END rc=0 for the old boot) and this boot is its SYSUPGRADE-REBOOT
R=/tmp/run/batman; T=opentakserver; fail=0
M=$(ls /opt/batdata/apps/$T/*.manifest 2>/dev/null | head -1)
[ -n "$M" ] || { echo "FAIL 0 no $T manifest — nothing to check"; echo "RESULT 1"; exit 0; }
e0=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
B=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
# 1
now=$(date +%s)
ev=$(docker events --since 0 --until "$now" --filter event=start --format '{{.ID}}' 2>/dev/null)
nev=$(docker events --since 0 --until "$now" --format '{{.ID}}' 2>/dev/null | wc -l)
[ "$nev" -gt 0 ] || { echo "FAIL 1 docker returned no events at all — nothing to count"; fail=1; }
[ "$nev" -lt 256 ] || { echo "FAIL 1 the event buffer holds $nev events (ring of 256) — it may have wrapped, the count is not measurable"; fail=1; }
for c in $(awk '/^CONTAINER /{print $2}' "$M"); do
	id=$(docker inspect -f '{{.Id}}' "$c" 2>/dev/null)
	[ -n "$id" ] || { echo "FAIL 1 $c does not exist"; fail=1; continue; }
	k=$(echo "$ev" | grep -c "^$id\$")
	[ "$k" = 1 ] && echo "ok 1 $c: one start event this dockerd" || { echo "FAIL 1 $c: $k start events this dockerd (want exactly 1)"; fail=1; }
done
# 2
logread | grep -q "payload-run\[$T\]: start mode" && echo "ok 2 the guardian used start mode this boot" || { echo "FAIL 2 no start-mode line this boot"; fail=1; }
l=$(awk '$1=="CONTAINER"{if(c!="")print c, t; c=$2; t=99} $1=="STOPTIER"{t=$2} END{print c, t}' "$M" | while read -r c t; do
	echo "$c $t $(docker inspect -f '{{.State.StartedAt}}' "$c")"; done | awk '{ if ($2 == 99) { if ($3 > maxf) maxf = $3 } else { if (minr == "" || $3 < minr) { minr = $3; mc = $1 } } } END { if (minr != "" && minr < maxf) print "bad " mc; else print "good" }')
[ "$l" = good ] && echo "ok 2 services started before the rest (two-phase)" || { echo "FAIL 2 order: ${l#bad } started before the last service"; fail=1; }
# 3
logread | grep -q "batman-payload-$T: confinement DRIFT detected" && { echo "FAIL 3 the guardian reported DRIFT this boot: $(logread | grep "batman-payload-$T" | grep -m1 -A0 DRIFT)"; fail=1; } || echo "ok 3 no DRIFT this boot"
tr_=$(grep " boot=$B " /opt/batdata/log/ota-trace.log 2>/dev/null)
echo "$tr_" | grep -q " AC COMMITTED " || { echo "FAIL 3 this boot has no AC COMMITTED in the OTA trace"; fail=1; }
echo "$tr_" | grep -q "drift not OK" && { echo "FAIL 3 the commit trace has 'drift not OK': $(echo "$tr_" | grep -m1 'drift not OK' | cut -c1-200)"; fail=1; } || echo "ok 3 commit trace has no 'drift not OK'"
# 4
pg=$(docker logs ots-db 2>&1 | grep -E "database system was shut down at|not properly shut down|was interrupted" | tail -1)
case "$pg" in *"shut down at"*) echo "ok 4 postgres last start after a clean shutdown" ;; *) echo "FAIL 4 postgres last start: ${pg:-<none>}"; fail=1 ;; esac
# 5
if [ -s "$R/batman-payload-$T-restarts" ]; then echo "FAIL 5 the guardian restarted containers this boot:"; sed 's/^/  /' "$R/batman-payload-$T-restarts"; fail=1
else echo "ok 5 restart ledger empty"; fi
# 6
grep " boot=${B0:-none} " /opt/batdata/log/ota-trace.log 2>/dev/null | grep -q " S2 END rc=0" && echo "ok 6 S2 END rc=0 for the old boot ${B0}" || { echo "FAIL 6 no 'S2 END rc=0' for the old boot ${B0:-?}"; fail=1; }
grep "boot_id=$B " /opt/batdata/log/boot-reasons.log 2>/dev/null | grep -q "SYSUPGRADE-REBOOT" && echo "ok 6 this boot is the sysupgrade's reboot (no watchdog reset)" || { echo "FAIL 6 boot-reasons does not say SYSUPGRADE-REBOOT for boot $B"; fail=1; }
e1=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
d=$((e1 - e0)); [ "$d" -lt 0 ] && d=$((-d))
[ "$d" -le 5 ] || { echo "FAIL 1 the clock stepped by ${d}s during the check — event times not comparable"; fail=1; }
echo "RESULT $fail"
