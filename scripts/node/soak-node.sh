# soak-node.sh — node side of the release-gate load soak (#268 B3; from the #247-2 30-min dogfood).
#   ssh root@node "ROLE=<role> [vars] sh -s" < this
#   ROLE=web-up   IMG=<image with python3>        start dv-web (host net :8098, 256m) serving a 64 KiB blob
#   ROLE=httpgen  TARGET=<ip> LABEL=<l> DUR=<s>   3 GET/s of the blob, counters in /tmp/dv-http-<l>.cnt
#   ROLE=cotgen   TARGET=<ots ip> RUN=<id> DUR=<s> 5 CoT/s on one long connection (reconnects counted),
#                                                 5 fixed uids <RUN>-S-0..4, dest'd to nobody (no fan-out)
#   ROLE=sample   one line of key=value facts (see below)
#   ROLE=down     stop generators, remove dv-web and every /tmp/dv-* file
# Prints "ERR ..." and exits 1 when a role cannot do its job, so the harness never mistakes it for load.
case "$ROLE" in
web-up)
	docker image inspect "$IMG" >/dev/null 2>&1 || { echo "NOIMAGE $IMG"; exit 3; }
	docker rm -f dv-web >/dev/null 2>&1
	docker run -d --name dv-web --network host --memory 256m --entrypoint python3 "$IMG" -c \
		"import os,http.server,functools; os.makedirs('/srv',exist_ok=True); open('/srv/blob','wb').write(os.urandom(65536)); h=functools.partial(http.server.SimpleHTTPRequestHandler,directory='/srv'); http.server.ThreadingHTTPServer(('',8098),h).serve_forever()" >/dev/null 2>/tmp/dv-web.err \
		|| { echo "ERR dv-web did not start: $(tail -2 /tmp/dv-web.err)"; exit 1; }   # stderr kept aside: docker warns about swap limits on every run
	for i in 1 2 3 4 5 6 7 8 9 10; do wget -q -T 3 -O /dev/null http://127.0.0.1:8098/blob && { echo "OK dv-web up"; exit 0; }; sleep 2; done
	echo "ERR dv-web not answering on :8098"; exit 1 ;;
httpgen)
	cat > /tmp/dv-httpgen-$LABEL.sh <<'EOS'
end=$(( $(date +%s) + DUR )); ok=0; fail=0
while [ "$(date +%s)" -lt "$end" ]; do
  for k in 1 2 3; do if wget -q -T 10 -O /dev/null "http://$TARGET:8098/blob"; then ok=$((ok+1)); else fail=$((fail+1)); fi; done
  echo "$ok $fail" > /tmp/dv-http-$LABEL.cnt; sleep 1
done
EOS
	echo "0 0" > /tmp/dv-http-$LABEL.cnt
	DUR=$DUR TARGET=$TARGET LABEL=$LABEL setsid sh /tmp/dv-httpgen-$LABEL.sh </dev/null >/dev/null 2>&1 &
	echo "OK httpgen $LABEL -> $TARGET for ${DUR}s" ;;
cotgen)
	cat > /tmp/dv-cotgen.sh <<'EOS'
end=$(( $(date +%s) + DUR )); echo 0 > /tmp/dv-cot.sent; echo 0 > /tmp/dv-cot.reconn
ts(){ date -u -d @$1 +%Y-%m-%dT%H:%M:%S.000Z; }
while [ "$(date +%s)" -lt "$end" ]; do
  { while [ "$(date +%s)" -lt "$end" ]; do
      n=$(date +%s); T=$(ts $n); S=$(ts $((n+60))); c=""
      for k in 0 1 2 3 4; do c="$c$(printf '<event version="2.0" uid="%s-S-%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s-S-%s"/><marti><dest callsign="dv-nobody"/></marti></detail></event>' $RUN $k $T $T $S $RUN $k)"; done
      printf '%s' "$c" || break
      echo $(( $(cat /tmp/dv-cot.sent) + 5 )) > /tmp/dv-cot.sent; sleep 1
    done; } | nc "$TARGET" 8088
  [ "$(date +%s)" -lt "$end" ] && echo $(( $(cat /tmp/dv-cot.reconn) + 1 )) > /tmp/dv-cot.reconn && sleep 2
done
EOS
	DUR=$DUR TARGET=$TARGET RUN=$RUN setsid sh /tmp/dv-cotgen.sh </dev/null >/dev/null 2>&1 &
	echo "OK cotgen -> $TARGET:8088 for ${DUR}s" ;;
sample)
	r(){ s=0; for p in $(pidof $1 2>/dev/null); do v=$(sed -n 's/^VmRSS:[^0-9]*\([0-9]*\).*/\1/p' /proc/$p/status 2>/dev/null); s=$((s + ${v:-0})); done; echo $s; }
	rs=0; for id in $(docker ps -aq 2>/dev/null); do c=$(docker inspect -f '{{.RestartCount}}' $id 2>/dev/null); rs=$((rs + ${c:-0})); done
	oom=0; for f in /sys/fs/cgroup/docker/*/memory.events; do v=$(sed -n 's/^oom_kill //p' $f 2>/dev/null); oom=$((oom + ${v:-0})); done
	h=""; for f in /tmp/dv-http-*.cnt; do [ -f "$f" ] || continue; l=${f#/tmp/dv-http-}; l=${l%.cnt}; set -- $(cat $f); h="$h http_${l}_ok=$1 http_${l}_fail=$2"; done
	cs=""; [ -f /tmp/dv-cot.sent ] && cs="cot_sent=$(cat /tmp/dv-cot.sent) cot_reconn=$(cat /tmp/dv-cot.reconn 2>/dev/null)"
	echo "up=$(cut -d. -f1 /proc/uptime) avail_kb=$(sed -n 's/^MemAvailable:[^0-9]*\([0-9]*\).*/\1/p' /proc/meminfo) dockerd_kb=$(r dockerd) containerd_kb=$(r containerd) shims_kb=$(r containerd-shim-runc-v2) restarts=$rs oom_kill=$oom ctr=$(docker ps -q 2>/dev/null | wc -l)$h $cs" ;;
down)
	for p in $(ps w | grep -E "[d]v-httpgen-|[d]v-cotgen.sh" | awk '{print $1}'); do kill -TERM $p 2>/dev/null; done
	for p in $(ps w | grep -E "[n]c [0-9.]+ 8088|[w]get -q -T 10 -O /dev/null http://[0-9.]+:8098" | awk '{print $1}'); do kill -TERM $p 2>/dev/null; done
	docker rm -f dv-web >/dev/null 2>&1; rm -f /tmp/dv-web.err /tmp/dv-httpgen-*.sh /tmp/dv-http-*.cnt /tmp/dv-cotgen.sh /tmp/dv-cot.sent /tmp/dv-cot.reconn
	left=$(ps w | grep -cE "[d]v-httpgen-|[d]v-cotgen.sh"); web=$(docker ps -a --format '{{.Names}}' | grep -c '^dv-web$')
	[ "$left" = 0 ] && [ "$web" = 0 ] && echo "OK down" || { echo "ERR down: $left generators, $web dv-web left"; exit 1; } ;;
*) echo "ERR unknown ROLE=$ROLE"; exit 1 ;;
esac
