#!/bin/sh
# payload-274.sh — on-node checks of the #274 v8.2 guardian (docs/design/274-payload-converge.md §12.5/§12.7).
# Sent as `CASE=<case> sh -s < this` to the OTS node by scripts/daily-validation.sh (destructive tier only).
#   crash        L-CRASH/L-PRIMARY/L-LOOP/L-OLDCFG/L-GRD/L-RM/L-POLICY/L-OPSTOP/L-TRIAL-CRASH(dry-run)/E40
#   dockerd      L-DOCKERD: `dockerd restart` stops the tenant, the guardian brings it back in order
#   hostalarm    L-FOREIGN: dangerous foreign containers (created, never started) are a host alarm, not DRIFT
#   golden       L-GOLDEN-TAMPER: root never executes a p6 copy of a golden tenant's script
# Prints "ok …" / "FAIL …" lines and "== payload-274 <case>: PASS|FAIL". Every case cleans up what it made.
T=opentakserver; R=/tmp/run/batman; D=/opt/batdata/apps/$T; G=/usr/share/batman/payload-golden/$T
LED=$R/batman-payload-$T-restarts; DF=$R/batman-payload-$T-drift.json; VL=$R/batman-payload-$T-verify.log
AL=$R/batman-payload-$T-host-alarm
F=0; ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; F=1; }
up(){ cut -d. -f1 /proc/uptime; }
st(){ sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$DF" 2>/dev/null; }
running(){ [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
pidof_c(){ docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null; }
crash(){ p=$(pidof_c "$1"); [ -n "$p" ] && [ "$p" != 0 ] && kill -9 "$p"; }
nrec(){ grep -c "$1" "$LED" 2>/dev/null || echo 0; }
waitfor(){ i=0; while ! eval "$1"; do i=$((i + 1)); [ "$i" -ge "$2" ] && return 1; sleep 1; done; return 0; }
all_running(){ for c in $(awk '/^CONTAINER /{print $2}' "$D"/*.manifest); do running "$c" || return 1; done; }
gpid(){ pgrep -f "payload-guardian-run.sh $T" | head -1; }
quiet_ledger(){   # the 600 s window must be clear before a case that asserts OK (§12.7 order)
	w=0; while :; do
		last=$(awk '$2!="cancel"{l=$1} END{print l+0}' "$LED" 2>/dev/null); [ -n "$last" ] || last=0
		[ $(( $(up) - last )) -ge 610 ] && break
		[ "$w" = 0 ] && echo "info waiting for the 600 s ledger window to pass (last record at +${last}s)"
		w=1; sleep 20
	done; }
[ -d "$G" ] || { echo "FAIL the image has no golden copy for $T — not a v8.2 OTS node"; echo "== payload-274 ${CASE:-?}: FAIL"; exit 1; }
[ -f /usr/lib/batman/payload-guardian-run.sh ] || { echo "FAIL pre-#274-v8.2 image (no payload-guardian-run.sh)"; echo "== payload-274 ${CASE:-?}: FAIL"; exit 1; }
waitfor all_running 300 || { no "precondition: OTS not 6/6"; echo "== payload-274 $CASE: FAIL"; exit 1; }

case "${CASE:-}" in
crash)
	quiet_ledger
	# 1 a client crash: back within ~10 s, same container, RestartCount 0 (only an API start can do that), ledgered
	c=ots_eud_handler_ssl; id0=$(docker inspect -f '{{.Id}}' $c); t0=$(date +%s); r0=$(nrec "crash $c")
	crash $c
	if waitfor "running $c && [ \$(nrec 'crash $c') -gt $r0 ]" 20; then
		ev=$(docker events --since "$t0" --until "$(date +%s)" --filter "container=$c" --filter event=start --format x | wc -l)
		# shellcheck disable=SC2046  # three space-free fields
		set -- $(docker inspect -f '{{.Id}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}' $c)
		[ "$1" = "$id0" ] && [ "$2" = 0 ] && [ "$3" = no ] && [ "$ev" -ge 1 ] \
			&& ok "1 crash: $c back within 20 s, same container, a start event with RestartCount 0 + policy no (the guardian), ledgered" \
			|| no "1 crash: id same=$([ "$1" = "$id0" ] && echo y || echo n) restarts=$2 policy=$3 start-events=$ev"
	else no "1 crash: $c not back / not ledgered within 20 s"; fi
	sleep 35; [ "$(st)" = DRIFT ] && ok "1 verdict DRIFT after the restart" || no "1 verdict $(st) after the restart"
	# 2 PRIMARY crash: restarted, guardian keeps running
	gp=$(gpid); crash opentakserver
	waitfor "running opentakserver" 120 && [ "$(gpid)" = "$gp" ] && ok "2 PRIMARY crash: opentakserver back, guardian PID $gp unchanged" \
		|| no "2 PRIMARY: running=$(running opentakserver && echo y || echo n) guardian $gp -> $(gpid)"
	# 3 a fast loop: crash ots_cot_parser each time it comes back, 5 times; the spacing must follow the backoff
	c=ots_cot_parser
	for _ in 1 2 3 4 5; do waitfor "running $c" 120 || break; sleep 2; crash $c; done
	waitfor "running $c" 120
	sp=$(awk '$2=="crash"{t[n++]=$1} END{k=0; for(i=1;i<n;i++){ if (t[i]-t[i-1] >= 600) {k=0; continue}; k++; e=10; for(j=1;j<k;j++) e*=2; if (e>60) e=60; if (t[i]-t[i-1] < e-6) {print "gap", t[i]-t[i-1], "want", e; bad=1} } if (!bad) print "ok"}' "$LED")
	[ "$sp" = ok ] && ok "3 crash loop: every restart respected the backoff (0,10,20,40,60 s)" || no "3 backoff violated: $sp"
	# 4 trial policy (dry-run on this committed boot): one crash keeps the tenant DRIFT, so a trial would NOT commit
	o=$(AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$(( $(up) + 60 )) batman-autocommit run 2>&1)
	echo "$o" | grep -q 'drift not OK' && ! echo "$o" | grep -q 'DRYRUN decision: COMMIT' \
		&& ok "4 dry-run after a crash: not committed — '$(echo "$o" | grep -m1 -oE '(DRYRUN decision: [A-Z]+|NOT committed)[^—]*' | cut -c1-80)' (drift not OK)" \
		|| no "4 dry-run: $(echo "$o" | tail -2 | tr '\n' ' ')"
	# 5 old config: a crash while the stack runs on an OLD config is restarted on it (never rebuilt here)
	cp "$D/ots.manifest" /tmp/run/batman-dv274.man; echo "# dv274 config change" >> "$D/ots.manifest"
	c=ots_eud_handler; id0=$(docker inspect -f '{{.Id}}' $c); crash $c
	waitfor "running $c" 60 && [ "$(docker inspect -f '{{.Id}}' $c)" = "$id0" ] && ok "5 old config: $c restarted on its old container (no rebuild)" || no "5 old config: not restarted / rebuilt"
	sleep 35; grep -q "config changed" "$VL" && ok "5 DRIFT 'config changed'" || no "5 verify log has no 'config changed'"
	cp /tmp/run/batman-dv274.man "$D/ots.manifest"; rm -f /tmp/run/batman-dv274.man
	# 6 the guardian dies while a client is down: the respawn's converge starts it and records 'respawn' once
	r0=$(nrec respawn); gp=$(gpid); kill -9 "$gp"; crash ots_eud_handler_ssl
	waitfor "[ -n \"\$(gpid)\" ] && [ \"\$(gpid)\" != $gp ] && running ots_eud_handler_ssl" 120 \
		&& [ "$(nrec respawn)" = $((r0 + 1)) ] && ok "6 guardian respawn: the client started by its converge, one 'respawn' record" \
		|| no "6 respawn: guardian $gp -> $(gpid) running=$(running ots_eud_handler_ssl && echo y || echo n) records $(nrec respawn)"
	# 7 a removed container comes back through the respawn converge (a rebuild of the stack)
	docker rm -f ots_eud_handler_ssl >/dev/null 2>&1
	waitfor "running ots_eud_handler_ssl" 240 && grep -q "missing ots_eud_handler_ssl" "$LED" && ok "7 removed container rebuilt via respawn converge, ledger 'missing'" || no "7 removed container not back in 240 s"
	waitfor all_running 240
	# 8 a restart policy set behind the guardian's back is reset and recorded once
	r0=$(nrec "policy ots_cot_parser"); docker update --restart always ots_cot_parser >/dev/null
	waitfor "[ \"\$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' ots_cot_parser)\" = no ]" 45 && sleep 35 \
		&& [ "$(nrec 'policy ots_cot_parser')" = $((r0 + 1)) ] && ok "8 docker update --restart always: reset to no, one 'policy' record" \
		|| no "8 policy: $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' ots_cot_parser) records $(nrec 'policy ots_cot_parser') (was $r0)"
	# 9 an operator `docker stop` is treated as a crash (the supported stop is the init script)
	docker stop ots_eud_handler >/dev/null; waitfor "running ots_eud_handler" 120 && ok "9 operator docker stop: restarted" || no "9 not restarted"
	# 10 a hung health check is killed inside the container (no process left behind, E40)
	echo "sleep 30" > "$R/fault.274-health-rabbitmq"; crash rabbitmq; sleep 30
	n1=$(docker top rabbitmq 2>/dev/null | grep -c "sleep 30")
	rm -f "$R/fault.274-health-rabbitmq"; waitfor all_running 300; sleep 10
	n2=$(docker top rabbitmq 2>/dev/null | grep -c "sleep 30")
	[ "$n1" -le 1 ] && [ "$n2" = 0 ] && ok "10 hung health check: at most one in flight ($n1), none left after ($n2)" || no "10 health processes in rabbitmq: during=$n1 after=$n2"
	echo "--- ledger:"; sed 's/^/  /' "$LED"
	# leave the node as found: wait the 600 s window out (§12.7 order) and show the verdict comes back to OK
	quiet_ledger; sleep 35; [ "$(st)" = OK ] && ok "verdict OK again once the 600 s window passed" || { no "verdict $(st) after the window"; sed 's/^/  /' "$VL"; } ;;
dockerd)
	quiet_ledger; t0=$(up)
	/etc/init.d/dockerd restart >/dev/null 2>&1
	waitfor "docker info >/dev/null 2>&1" 120 || no "dockerd did not answer within 120 s"
	waitfor all_running 180 && ok "all 6 back within 180 s of a dockerd restart ($(( $(up) - t0 )) s)" || no "tenant not back within 180 s"
	[ "$(docker info -f '{{.LiveRestoreEnabled}}')" = false ] && ok "live-restore is off" || no "live-restore is on"
	grep -q crash "$LED" && ok "the guardian restarted them (ledger)" || no "no ledger record — who started them?"
	l=$(awk '$1=="CONTAINER"{if(c!="")print c, t; c=$2; t=99} $1=="STOPTIER"{t=$2} END{print c, t}' "$D/ots.manifest" | while read -r c t; do echo "$c $t $(docker inspect -f '{{.State.StartedAt}}' "$c")"; done \
		| awk '{ if ($2 == 99) { if ($3 > maxf) maxf = $3 } else { if (minr == "" || $3 < minr) minr = $3 } } END { print (minr != "" && minr < maxf) ? "bad" : "good" }')
	[ "$l" = good ] && ok "services restarted before the rest" || no "restart order: a client started before the last service"
	pg=$(docker logs ots-db 2>&1 | grep -E "database system was shut down at|not properly shut down|was interrupted" | tail -1)
	case "$pg" in *"shut down at"*) ok "postgres stopped cleanly by dockerd" ;; *) no "postgres last start: ${pg:-<none>}" ;; esac
	quiet_ledger; sleep 35; [ "$(st)" = OK ] && ok "verdict OK again once the 600 s window passed" || no "verdict $(st) after the window" ;;
hostalarm)
	img=$(docker inspect -f '{{.Config.Image}}' rabbitmq)
	cleanup(){ docker rm -f dv274a dv274b dv274c dv274d dv274e >/dev/null 2>&1; docker volume rm dv274vol >/dev/null 2>&1; }
	cleanup; trap cleanup EXIT
	docker volume create -o type=none -o o=bind -o device=/opt/batdata/log dv274vol >/dev/null
	docker create --name dv274a --network none -v /opt/batdata/state:/s "$img" >/dev/null
	docker create --name dv274b --network none -v /var/run/docker.sock:/s:ro "$img" >/dev/null
	docker create --name dv274c --network none --device /dev/mmcblk0p6 "$img" >/dev/null
	docker create --name dv274d --network host --security-opt no-new-privileges "$img" >/dev/null
	docker create --name dv274e --network none --security-opt no-new-privileges -v dv274vol:/x "$img" >/dev/null
	sleep 40
	for c in dv274a dv274b dv274c dv274d dv274e; do grep -q "foreign-container $c " "$AL" && ok "$c: host alarm" || no "$c: no host alarm"; done
	grep -q "dv274" "$VL" && no "a foreign container reached the tenant verdict" || ok "the tenant verdict ignores foreign containers"
	logread | grep -q "host alarm: foreign-container dv274a" && ok "the alarm was logged" || no "alarm not logged"
	cleanup; trap - EXIT
	batman-autocommit canary >/dev/null 2>&1; sleep 35
	grep -q foreign-container "$AL" && no "alarm left after cleanup / raised by the canary: $(cat "$AL")" || ok "no alarm after cleanup and a canary run" ;;
golden)
	cleanup(){ rm -f "$D/verify-profile-zz274.sh" "$D/zz274.fw4.uci" "$R/ge274-"*; cp "$G/reconcile-resources.sh" "$D/reconcile-resources.sh"; }
	trap cleanup EXIT
	printf '#!/bin/sh\ntouch %s/ge274-vp\n' "$R" > "$D/verify-profile-zz274.sh"; printf 'touch %s/ge274-fw4\n' "$R" > "$D/zz274.fw4.uci"
	chmod +x "$D/verify-profile-zz274.sh" "$D/zz274.fw4.uci"; echo "touch $R/ge274-rr" >> "$D/reconcile-resources.sh"
	sleep 70
	ls "$R"/ge274-* >/dev/null 2>&1 && no "a p6 script ran as root: $(ls "$R"/ge274-*)" || ok "no planted / edited p6 script ran (2 ticks)"
	grep -q "p6 file reconcile-resources.sh differs from the image" "$VL" && ok "edited golden file: DRIFT" || no "edited reconcile-resources.sh not reported"
	grep -q "verify-profile-zz274.sh is not from the image" "$AL" && grep -q "zz274.fw4.uci is not from the image" "$AL" && ok "planted files: host alarm" || no "planted files not in the host alarm"
	/etc/init.d/batman-payload-$T restart >/dev/null 2>&1; waitfor all_running 300; sleep 40
	ls "$R"/ge274-* >/dev/null 2>&1 && no "a p6 script ran at the guardian's start: $(ls "$R"/ge274-*)" || ok "nothing from p6 ran at a guardian restart either"
	cleanup; trap - EXIT ;;
*) no "unknown CASE '${CASE:-}'" ;;
esac
[ "$F" = 0 ] && echo "== payload-274 $CASE: PASS" || echo "== payload-274 $CASE: FAIL"
exit "$F"
