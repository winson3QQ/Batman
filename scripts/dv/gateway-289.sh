# gateway-289.sh — the #289 EUD gateway suites (sourced by scripts/daily-validation.sh when the OTS node runs the
# gateway build: container ots_eud_gateway present). Design: docs/design/289-eud-gateway.md §7.
#
# Every client runs INSIDE an OTS container on the OTS node (python3 + ssl; scripts/node/gw-client-289.py) over
# mTLS to 172.20.0.10:8089 with 1-day test certs issued on the node (ots-test-client-cert.py, node clock): the
# members' path. One test USER per simulated phone where the per-user caps matter (design §7). A stale phone is
# simulated by a black hole on the OTS node's forward hook (scripts/node/gw-blackhole-289.sh): no FIN, no RST.
# Every suite removes its rows (cot/points/geochat first: RESTRICT), users, certs and queues and FAILs if anything
# is left; an unreadable snapshot/log/counter is a FAIL, never a pass.
# Negative controls: on the overlay build the gateway is absent and these suites SKIP (not a pass); the behaviour
# each one asserts was shown to be absent on the pre-fix gateway by deploy/ots/gateway/tests (offline) and, for the
# #264-era mechanisms, by the -264 suites' recorded negative controls (see the #264 register).

GW=172.20.0.10
# gw_log <ots> <fixed string>: count the gateway log lines containing it. The pattern travels on STDIN (grep -F -f -)
# so no shell on the node ever sees it (parens, quotes and spaces broke the nested quoting on the first run).
gw_log() { printf '%s\n' "$2" | timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" 'docker exec -i ots_eud_gateway grep -c -F -f /dev/stdin /app/ots/logs/eud_gateway.log 2>/dev/null' | tr -d ' \r'; }
gw_logl() { printf '%s\n' "$2" | timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "docker exec -i ots_eud_gateway sh -c 'grep -F -f /dev/stdin /app/ots/logs/eud_gateway.log 2>/dev/null | tail -${3:-5}'" | tr -d '\r'; }
gw_snap() { fssh "$1" 20 'docker exec ots_eud_gateway cat /tmp/gateway/sessions.json 2>/dev/null' | tr -d '\r'; }
# the snapshot is rewritten every 10 s: a counter read right after an action can be up to 10 s stale — wait first
gw_counter() { sleep "${3:-11}"; gw_snap "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["counters"].get("'"$2"'", 0))' 2>/dev/null; }
gw_devices() { gw_snap "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["devices"]))' 2>/dev/null; }
gw_mem() { fssh "$1" 20 'c=$(docker inspect -f "{{.Id}}" ots_eud_gateway 2>/dev/null); cat /sys/fs/cgroup/docker/$c/memory.current 2>/dev/null' | tr -d ' \r'; }
gw_health() { fssh "$1" 20 'docker exec ots_eud_gateway curl -s -m 3 http://localhost:8090/healthz' | tr -d '\r'; }
# gw_pre <ots>: the gateway build is there and healthy, else SKIP-REASON (rc 3) / FAIL
gw_pre() { local o
  o=$(fssh "$1" 20 'docker inspect -f "{{.State.Running}}" ots_eud_gateway 2>/dev/null' | tr -d '\r')
  [ "$o" = true ] || { echo "SKIP-REASON: no ots_eud_gateway container on $1 (overlay build?)"; return 3; }
  o=$(gw_health "$1"); case "$o" in *'"ok": true'*) ;; *) echo "FAIL gateway healthz not ok: [$o]"; return 1 ;; esac
  o=$(gw_devices "$1"); isint "$o" || { echo "FAIL snapshot unreadable ([$o])"; return 1; }
  echo "gateway up: healthz ok, $o device(s) before the test"; }
# gw_users <ots> <prefix> <n>: n non-admin test users + 1-day certs at $GWC:/tmp/<prefix>-u<k>.{pem,key}
# GWC = the container the clients and their certs live in (default ots_cot_parser; the suites that stop the broker
# or restart cot_parser use opentakserver, which survives both — cot_parser exits on a broker loss and is restarted)
GWC=${GWC:-ots_cot_parser}
gw_users() { local ots=$1 p=$2 n=$3 k o
  for k in $(seq 1 "$n"); do
    echo "delete from \"user\" where username='$p-u$k'; insert into \"user\" (username, active, fs_uniquifier) values ('$p-u$k', true, md5(random()::text));" | ots_sql "$ots" >/dev/null
    o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i -e CN=$p-u$k $GWC python3 -" < "$REPO/scripts/node/ots-test-client-cert.py" 2>&1 | tr -d '\r')
    echo "$o" | grep -q '^OK test client cert' || { echo "FAIL could not issue the test cert for $p-u$k: $o"; return 1; }
    fssh "$ots" 15 "docker exec $GWC sh -c 'mv /tmp/dv-client.pem /tmp/$p-u$k.pem; mv /tmp/dv-client.key /tmp/$p-u$k.key'"
  done; echo "$n test user(s) $p-u1..$n with 1-day certs (node clock)"; }
# gwc <ots> <ctr> <timeout> <env...>: run gw-client-289.py inside <ctr> with the given -e assignments.
# No `tr` on the output: a pipe would buffer a backgrounded client's "PORT n" line until it exits (the first run
# never saw A's port); readers strip the CRs themselves (rd).
gwc() { local ots=$1 ctr=$2 to=$3; shift 3; local e="" v
  for v in "$@"; do e="$e -e $v"; done
  timeout "$to" ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i $e -e TARGET=$GW -e CA=/app/ots/ca/ca.pem $ctr python3 -" < "$REPO/scripts/node/gw-client-289.py" 2>&1; }
rd() { tr -d '\r' < "$1" 2>/dev/null; }
gw_bh() { timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "ACTION=$2 PORTS='${3:-}' sh -s" < "$REPO/scripts/node/gw-blackhole-289.sh" 2>&1 | tr -d '\r'; }
# gw_bh_bites <ots>: the drop counters moved (the stale client keeps sending pings) — else the scenario was not made
gw_bh_bites() { local d; sleep "${2:-12}"; d=$(gw_bh "$1" count | sed -n 's/^DROPPED \([0-9]*\)$/\1/p'); echo "black hole dropped ${d:-?} packet(s)"; isint "$d" && [ "$d" -gt 0 ]; }
# gw_cleanup <ots> <run-prefix> <user-prefix> <n-users>: rows (RESTRICT order), users, certs, queues; FAIL on leftovers
gw_cleanup() { local ots=$1 run=$2 p=$3 n=$4 o rc=0 i c err sql
  # the run's last goodbyes are still on their way to cot_parser when the clients have just left: a cot row inserted
  # between our delete of cot and of euds makes RESTRICT abort the whole transaction (rc 1 run: "[2 2]" left)
  for i in 1 2 3 4 5 6 7 8 9 10; do o=$(gw_snap "$ots" | grep -c "\"$run-"); [ "${o:-1}" = 0 ] && break; sleep 2; done
  # the goodbyes land in cot through cot_parser a few seconds after the gateway logged the end: wait until the
  # run's cot row count has not moved for 4 s (rc 3: the fixed sleep lost the race twice, "[2 2]")
  o=$(echo "select count(*) from cot where sender_uid like '$run-%' or uid like '$run-%';" | ots_sql "$ots")
  for i in 1 2 3 4 5 6 7 8; do sleep 4; c=$(echo "select count(*) from cot where sender_uid like '$run-%' or uid like '$run-%';" | ots_sql "$ots"); [ "$c" = "$o" ] && break; o=$c; done
  sql="begin; delete from cot where sender_uid like '$run-%' or uid like '$run-%' or sender_uid in (select uid from euds where user_id in (select id from \"user\" where username like '$p-u%')); delete from points where device_uid like '$run-%' or device_uid in (select uid from euds where user_id in (select id from \"user\" where username like '$p-u%')); delete from geochat where sender_uid like '$run-%' or sender_uid in (select uid from euds where user_id in (select id from \"user\" where username like '$p-u%')); delete from euds where uid like '$run-%' or user_id in (select id from \"user\" where username like '$p-u%'); delete from \"user\" where username like '$p-u%'; commit;"
  err=$(printf '%s\n' "$sql" | ots_sql "$ots" 2>&1 | grep -i "error" | head -2 | tr '\n' ' ')
  o=$(echo "select (select count(*) from euds where uid like '$run-%') || ' ' || (select count(*) from \"user\" where username like '$p-u%');" | ots_sql "$ots")
  if [ "$o" != "0 0" ]; then
    sleep 6; err=$(printf '%s\n' "$sql" | ots_sql "$ots" 2>&1 | grep -i "error" | head -2 | tr '\n' ' ')
    o=$(echo "select (select count(*) from euds where uid like '$run-%') || ' ' || (select count(*) from \"user\" where username like '$p-u%');" | ots_sql "$ots")
  fi
  [ "$o" = "0 0" ] || { echo "FAIL cleanup left rows/users: [$o]; psql: [${err:-no error text}]; cot rows of the run still there (timestamp uid): $(echo "select timestamp || ' ' || coalesce(sender_uid, uid) from cot where sender_uid like '$run-%' or uid like '$run-%' order by timestamp desc limit 5;" | ots_sql "$ots" | tr '\n' ';')"; rc=1; }
  fssh "$ots" 20 "docker exec $GWC sh -c 'rm -f /tmp/$p-u*.pem /tmp/$p-u*.key'" >/dev/null
  o=$(fssh "$ots" 60 'n=0; for q in $(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep "^'"$run"'"); do docker exec rabbitmq rabbitmqctl -q delete_queue "$q" >/dev/null 2>&1 && n=$((n+1)); done; echo "deleted=$n left=$(docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep -c "^'"$run"'")"' | tr -d '\r')
  echo "cleanup: rows/users removed; queues $o"; case "$o" in *left=0) ;; *) rc=1 ;; esac
  return $rc; }

# ---- suites ----------------------------------------------------------------------------------------------------
# e2e on the members' path: the #264 SSL generator (P1/P2/P3 phases) to the gateway, sent == stored per phase
chk_cot_289() { local ots=$1 run o rc=0
  gw_pre "$ots" || return $?
  gw_users "$ots" GWE 1 || return 1
  run=DVS$(date +%Y%m%d%H%M%S); echo "run id $run; generator ots_cot_parser -> gateway:8089 (mTLS, user GWE-u1)"
  o=$(timeout 400 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" \
    "docker exec -i -e TARGET=$GW -e RUN=$run -e CA=/app/ots/ca/ca.pem -e CERT=/tmp/GWE-u1.pem -e KEY=/tmp/GWE-u1.key ots_cot_parser python3 -" \
    < "$REPO/scripts/node/cot-e2e-gen-ssl.py" 2>&1 | tr -d '\r')
  echo "$o"; cot_judge "$ots" "$run" "$o" || rc=1
  gw_cleanup "$ots" "$run" GWE 1 || rc=1
  return $rc; }

# presence (P1): a stale phone (black hole, no FIN) -> its row Disconnected and a teammate receives t-x-d-d within
# 150 s (TCP_USER_TIMEOUT 120 s); when it comes back its row is Connected again; a reconnect while its old socket
# is stale supersedes it (downlink to the new one only). Overlay: 8088 rows stayed Connected for ever (A6-5).
chk_presence_289() { local ots=$1 run o rc=0 port t0 st dis0 dis1 cnt
  gw_pre "$ots" || return $?
  gw_users "$ots" GWP 2 || return 1
  run=DVP$(date +%H%M%S)
  # B (user 2) reads for 170 s and counts the t-x-d-d naming A (its uid appears in <link uid=...>)
  ( gwc "$ots" ots_cot_parser 200 ACTION=readcount UID="$run-B" CS="$run-B" CERT=/tmp/GWP-u2.pem KEY=/tmp/GWP-u2.key EXPECT="$run-A" N=1 TXDD=1 HOLD=170 > "$DIR/presence-289.B" ) &
  sleep 3
  # A (user 1) identifies and stops reading; its port is black-holed on the node
  ( gwc "$ots" ots_cot_parser 260 ACTION=noread UID="$run-A" CS="$run-A" CERT=/tmp/GWP-u1.pem KEY=/tmp/GWP-u1.key HOLD=230 KEEPSEND=5 > "$DIR/presence-289.A" ) &
  for t0 in 1 2 3 4 5 6 7 8; do sleep 1; port=$(rd "$DIR/presence-289.A" | sed -n 's/^PORT \([0-9]*\)$/\1/p'); [ -n "$port" ] && break; done
  isint "$port" || { echo "FAIL A did not report its port — not verified"; wait; return 1; }
  st=$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots"); echo "A identified (port $port), row [$st]"
  [ "$st" = Connected ] || { echo "FAIL A's row is not Connected after identification"; rc=1; }
  o=$(gw_bh "$ots" add "$port"); echo "$o"; echo "$o" | grep -q "^BLACKHOLE 1$" || { echo "FAIL black hole not installed — not verified"; rc=1; }
  gw_bh_bites "$ots" || { echo "FAIL the black hole does not bite — the stale phone was not made, not verified"; rc=1; }
  t0=$SECONDS
  while [ $((SECONDS - t0)) -lt 160 ]; do sleep 10; st=$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots"); [ "$st" = Disconnected ] && break; done
  echo "A's row after the black hole: [$st] after $((SECONDS - t0)) s (expect Disconnected within 150 s)"
  [ "$st" = Disconnected ] || { echo "FAIL the stale phone's row stayed $st (ghost; overlay 8088: for ever)"; rc=1; }
  cnt=$(gw_log "$ots" "ended $run-A"); [ "${cnt:-0}" -ge 1 ] && echo "gateway logged the end of $run-A" || { echo "FAIL no 'ended $run-A' line"; rc=1; }
  wait
  o=$(rd "$DIR/presence-289.B"); echo "B: $o"
  echo "$o" | grep -q '^GOT [1-9]' && echo "B received the t-x-d-d naming A" || { echo "FAIL B did not receive a t-x-d-d naming A"; rc=1; }
  gw_bh "$ots" del >/dev/null
  # the phone comes back: its row flips to Connected
  ( gwc "$ots" ots_cot_parser 60 ACTION=hold UID="$run-A" CS="$run-A" CERT=/tmp/GWP-u1.pem KEY=/tmp/GWP-u1.key HOLD=10 > "$DIR/presence-289.A2" ) &
  sleep 5; st=$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots"); wait
  echo "A back: $(rd "$DIR/presence-289.A2" | tail -1); its row while held: [$st]"
  [ "$st" = Connected ] || { echo "FAIL the returned phone's row is not Connected while it is held"; rc=1; }
  sleep 3; st=$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots"); echo "A's row after it left again: [$st]"
  [ "$st" = Disconnected ] || { echo "FAIL the row is not Disconnected after the phone left"; rc=1; }
  gw_cleanup "$ots" "$run" GWP 2 || rc=1
  return $rc; }

# same device, new connection (zombie / same-uid-end): A stops reading (black-holed); B (same user+uid) connects:
# downlink goes to B only (10/10 from C), A's socket is closed by the supersede deadline (<= 120 s), no cot_parser
# disconnect for the uid while B lives, the row stays Connected. Overlay: the downlink was split round-robin.
chk_zombie_289() { local ots=$1 run o rc=0 port t0 d0 d1 cnt sq
  gw_pre "$ots" || return $?
  gw_users "$ots" GWZ 2 || return 1
  run=DVZ$(date +%H%M%S)
  d0=$(fssh "$ots" 20 'docker exec ots_cot_parser sh -c "grep -c \"Sending disconnect cot to '"$run-A"'\$\" /app/ots/logs/cot_parser.log 2>/dev/null"' | tr -d ' \r'); isint "$d0" || d0=0
  ( gwc "$ots" ots_cot_parser 260 ACTION=noread UID="$run-A" CS="$run-A" CERT=/tmp/GWZ-u1.pem KEY=/tmp/GWZ-u1.key HOLD=220 KEEPSEND=5 > "$DIR/zombie-289.A" ) &
  for t0 in 1 2 3 4 5 6 7 8; do sleep 1; port=$(rd "$DIR/zombie-289.A" | sed -n 's/^PORT \([0-9]*\)$/\1/p'); [ -n "$port" ] && break; done
  isint "$port" || { echo "FAIL A did not report its port"; wait; return 1; }
  o=$(gw_bh "$ots" add "$port"); echo "A (port $port) black-holed: $o"
  echo "$o" | grep -q "^BLACKHOLE 1$" && gw_bh_bites "$ots" 8 || { echo "FAIL the black hole does not bite — not verified"; rc=1; }
  # B3 H-1: 24 x 60 KiB (~1.4 MiB) to the stale socket first: the kernel send buffer, the raw transport (256 KiB)
  # and the TLS layer (256 KiB) fill (~0.9 MiB measured on loopback) and the gateway's writer blocks on it
  # (pause_writing). The pre-fix gateway (C1A-2/C1B-1) stayed stuck there and B below got nothing. 12 x 60 KiB
  # did NOT reach pause_writing (B3 closure): the leg asserts the stale device's sendq > 0 before the reconnect.
  # paced at 60 KiB / 2 s, under the gateway's per-session uplink bucket (32 KiB/s, burst 256 KiB, M1): at 0.2 s
  # the gateway read only ~640 KiB of the 1.4 MiB before the filler closed and sendq stayed 0 (rc 4 run)
  o=$(gwc "$ots" ots_cot_parser 120 ACTION=stream UID="$run-F" CS="$run-F" CERT=/tmp/GWZ-u2.pem KEY=/tmp/GWZ-u2.key N=24 DELAY=2 PAD=60000 HOLD=5 | tr -d '\r' | tail -1); echo "filler to the stale socket: $o"
  echo "$o" | grep -q '^SENT 24' || { echo "FAIL the filler stream was not sent — the stuck-writer scenario was not made"; rc=1; }
  sq=$(sleep 11; gw_snap "$ots" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(x["sendq"] for x in d["devices"] if x["uid"] == "'"$run-A"'"))' 2>/dev/null)
  echo "stale device's sendq before the reconnect: [${sq:-?}] (> 0: its writer is blocked on the black-holed socket)"
  isint "$sq" && [ "$sq" -gt 0 ] || { echo "FAIL the writer is not blocked on the stale socket (sendq [$sq]) — the stuck-writer scenario was not made, not verified"; rc=1; }
  # B: the same device reconnects (same user, same uid) and reads what C sends
  # B stays for the whole test: if it left early, A (still draining) would be promoted to current by design (B2-10)
  ( gwc "$ots" ots_cot_parser 230 ACTION=readcount UID="$run-A" CS="$run-A" CERT=/tmp/GWZ-u1.pem KEY=/tmp/GWZ-u1.key EXPECT="$run-C-p" N=10 STAY=1 HOLD=200 > "$DIR/zombie-289.B" ) &
  sleep 4; t0=$SECONDS
  cnt=$(gw_log "$ots" "superseded $run-A"); [ "${cnt:-0}" -ge 1 ] && echo "gateway logged the supersede" || { echo "FAIL no 'superseded $run-A' line"; rc=1; }
  o=$(gwc "$ots" ots_cot_parser 60 ACTION=stream UID="$run-C" CS="$run-C" CERT=/tmp/GWZ-u2.pem KEY=/tmp/GWZ-u2.key N=10 DELAY=1 HOLD=3 | tr -d '\r'); echo "C: $o"
  # A's stale socket ENDS <= 120 s after the supersede while B lives. Design decision 4 / §M3: a superseded
  # connection is read until supersede + min(outage + 20 s, 120 s), and any of FIN/RST, TCP_USER_TIMEOUT or that
  # deadline ends it. Here the filler's unacked downlink makes the kernel's TCP_USER_TIMEOUT (120 s from the first
  # unacked byte, M11) fire BEFORE the gateway's deadline (outage ~75 s + 20 s): "[Errno 110]" is the expected
  # reason, "superseded: deadline" the other legal one. Until 2026-10-16 only the deadline string counted: the rc 5
  # PASSes came from a stale black-hole table deleter (gw-blackhole-289.sh, fixed the same day) un-black-holing A
  # seconds before the supersede (fresh last_rx -> short deadline) — a race, not the product. On rc 6 with the hole
  # intact: ETIMEDOUT at filler + 120 s = supersede + 54 s, no deadline line, the same gateway code.
  cnt=0; why=""
  while [ $((SECONDS - t0)) -lt 130 ]; do sleep 5; why=$(gw_logl "$ots" "connection of $run-A from" | grep -E 'closed \((superseded: deadline|\[Errno 110\])' | head -1 | sed -n 's/.*closed (\(.*\))$/\1/p'); [ -n "$why" ] && { cnt=1; break; }; done
  [ "$cnt" = 1 ] && echo "A's stale connection ended ~$((SECONDS - t0 + 4)) s after the supersede ($why)" || { echo "FAIL A's stale connection was not ended within 130 s of the supersede (neither the supersede deadline nor TCP_USER_TIMEOUT)"; rc=1; }
  wait
  o=$(rd "$DIR/zombie-289.B"); echo "B: $o"
  echo "$o" | grep -q '^GOT 10 open' && echo "B got 10/10 and was kept (downlink to the new connection only)" || { echo "FAIL B: $o (expected GOT 10 open)"; rc=1; }
  d1=$(fssh "$ots" 20 'docker exec ots_cot_parser sh -c "grep -c \"Sending disconnect cot to '"$run-A"'\$\" /app/ots/logs/cot_parser.log 2>/dev/null"' | tr -d ' \r'); isint "$d1" || d1=0
  [ "$d1" = "$d0" ] && echo "no cot_parser disconnect for the live device" || { echo "FAIL a disconnect went through cot_parser for the live device"; rc=1; }
  gw_bh "$ots" del >/dev/null
  gw_cleanup "$ots" "$run" GWZ 2 || rc=1
  return $rc; }

# caps (M2.5): per-user device cap 4 (6 devices of one user at once -> 4 kept, 2 refused) and the new-device bucket
# (burst 4: the 5th+ fresh uid of a user refused `new-device rate`, no row, no queue). Overlay: admitted all.
chk_cap_289() { local ots=$1 run o rc=0 k kept closed cnt q
  gw_pre "$ots" || return $?
  gw_users "$ots" GWC 2 || return 1
  run=DVC$(date +%H%M%S)
  for k in 1 2 3 4 5 6; do ( gwc "$ots" ots_cot_parser 60 ACTION=hold UID="$run-u1-$k" CS="$run-u1-$k" CERT=/tmp/GWC-u1.pem KEY=/tmp/GWC-u1.key HOLD=20 > "$DIR/cap-289.$k" ) & sleep 0.3; done
  wait
  kept=$(cat "$DIR"/cap-289.[1-6] | tr -d '\r' | grep -c '^KEPT'); closed=$(cat "$DIR"/cap-289.[1-6] | tr -d '\r' | grep -c '^CLOSED')
  echo "6 devices of one user at once: kept $kept, refused $closed (expect 4 / 2)"
  [ "$kept" = 4 ] && [ "$closed" = 2 ] || { echo "FAIL per-user device cap not enforced"; rc=1; }
  cnt=$(gw_log "$ots" "per-user device cap"); [ "${cnt:-0}" -ge 1 ] && echo "refusal logged" || { echo "FAIL no 'per-user device cap' refusal line"; rc=1; }
  # cycling: user 2 identifies 8 fresh uids one after the other (the 4 already seen above do not count for user 2)
  kept=0; closed=0
  for k in 1 2 3 4 5 6 7 8; do o=$(gwc "$ots" ots_cot_parser 30 ACTION=hold UID="$run-u2-$k" CS="$run-u2-$k" CERT=/tmp/GWC-u2.pem KEY=/tmp/GWC-u2.key HOLD=2 | tr -d '\r' | tail -1); case "$o" in KEPT*) kept=$((kept+1)) ;; *) closed=$((closed+1)) ;; esac; done
  echo "8 fresh uids of one user in a row: kept $kept, refused $closed (expect 4 / 4: burst 4, 10 per hour)"
  [ "$kept" = 4 ] && [ "$closed" = 4 ] || { echo "FAIL new-device rate bound not enforced"; rc=1; }
  q=$(fssh "$ots" 30 'docker exec rabbitmq rabbitmqctl -q list_queues name 2>/dev/null | grep -c "^'"$run-u2-"'"' | tr -d ' \r')
  cnt=$(echo "select count(*) from euds where uid like '$run-u2-%';" | ots_sql "$ots")
  echo "rows for user 2's uids: $cnt, queues: $q (expect 4 / 4: nothing for a refused uid)"
  [ "$cnt" = 4 ] && [ "$q" = 4 ] || { echo "FAIL a refused uid left a row or a queue"; rc=1; }
  gw_cleanup "$ots" "$run" GWC 2 || rc=1
  return $rc; }

# admission (M2.1 / M1): (i) 300 pre-TLS sockets from another container while a phone identifies: the phone is
# kept, the pool stays <= MAX_PENDING; (i2) a ping flood from one session is paused (counter), the socket kept;
# (j) a 70 KiB message is discarded and the session answers the next ping.
chk_admission_289() { local ots=$1 run o rc=0 p0 p1 pend c0 c1 m0 m1
  gw_pre "$ots" || return $?
  c0=$(gw_snap "$ots" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("conns", -1), d["pending"])' 2>/dev/null); m0=$(gw_mem "$ots")
  gw_users "$ots" GWA 1 || return 1
  run=DVA$(date +%H%M%S)
  ( gwc "$ots" ots_cot_parser 60 ACTION=rawflood N=300 HOLD=15 > "$DIR/admission-289.raw" ) &
  sleep 2
  o=$(gwc "$ots" ots_cot_parser 40 ACTION=hold UID="$run-P" CS="$run-P" CERT=/tmp/GWA-u1.pem KEY=/tmp/GWA-u1.key HOLD=8 | tr -d '\r' | tail -1)
  pend=$(gw_snap "$ots" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending"])' 2>/dev/null)
  wait; echo "raw flood: $(rd "$DIR/admission-289.raw"); phone during it: $o; pending in the snapshot: $pend"
  case "$o" in KEPT*) ;; *) echo "FAIL the phone was not kept during the pre-TLS flood"; rc=1 ;; esac
  isint "$pend" && [ "$pend" -le 1024 ] || { echo "FAIL pending [$pend] not within MAX_PENDING"; rc=1; }
  rd "$DIR/admission-289.raw" | grep -q '^RAW 300 open=0$' || { echo "FAIL the raw sockets were not all closed by the handshake timeout"; rc=1; }
  # B2 H1: once the flood's handshakes timed out, the pool and the held sockets are back to the baseline
  sleep 12; c1=$(gw_snap "$ots" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("conns", -1), d["pending"])' 2>/dev/null); m1=$(gw_mem "$ots")
  echo "conns/pending before [$c0] after [$c1]; memory $((${m0:-0}/1048576)) -> $((${m1:-0}/1048576)) MiB"
  [ "${c1#* }" = "${c0#* }" ] && [ "${c1%% *}" -le "$(( ${c0%% *} + 1 ))" ] 2>/dev/null || { echo "FAIL the flood's dead sockets are still held (B2 C2B-1)"; rc=1; }
  p0=$(gw_counter "$ots" uplink_paused 11); isint "$p0" || p0=0
  o=$(gwc "$ots" ots_cot_parser 90 ACTION=pingflood UID="$run-F" CS="$run-F" CERT=/tmp/GWA-u1.pem KEY=/tmp/GWA-u1.key N=500 | tr -d '\r' | tail -1); echo "ping flood (identified session, 500 pings, a ping 12 s later): $o"
  p1=$(gw_counter "$ots" uplink_paused 12); isint "$p1" || p1=0
  echo "$o" | grep -q 'open=1 pong=1' && [ "$p1" -gt "$p0" ] && echo "flood paused ($((p1 - p0)) pause(s)), socket kept and served after the pause" || { echo "FAIL ping flood not bounded by the message bucket / session not served after it (paused $p0 -> $p1, $o)"; rc=1; }
  o=$(gwc "$ots" ots_cot_parser 40 ACTION=oversize UID="$run-O" CS="$run-O" CERT=/tmp/GWA-u1.pem KEY=/tmp/GWA-u1.key SIZE=70000 | tr -d '\r' | tail -1); echo "oversize: $o"
  echo "$o" | grep -q '^PONG 1' && echo "70 KiB message discarded, session kept (pong)" || { echo "FAIL oversize message closed the session or no pong"; rc=1; }
  gw_cleanup "$ots" "$run" GWA 1 || rc=1
  return $rc; }

# ownership (M4): another user's uid refused (closed, row unchanged); an unowned row with history refused; an
# unowned row without history adopted. Overlay: the second user took the row (wsl.10) / was recorded.
chk_owner_289() { local ots=$1 run o rc=0 uid
  gw_pre "$ots" || return $?
  gw_users "$ots" GWO 2 || return 1
  run=DVO$(date +%H%M%S); uid="$run-X"
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=hold UID="$uid" CS="$uid" CERT=/tmp/GWO-u1.pem KEY=/tmp/GWO-u1.key HOLD=3 | tr -d '\r' | tail -1); echo "user 1 owns $uid: $o"
  u1=$(echo "select user_id from euds where uid='$uid';" | ots_sql "$ots")
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=refused UID="$uid" CS="$uid" CERT=/tmp/GWO-u2.pem KEY=/tmp/GWO-u2.key HOLD=5 | tr -d '\r' | tail -1); echo "user 2 claims it: $o"
  echo "$o" | grep -q '^CLOSED' && [ "$(echo "select user_id from euds where uid='$uid';" | ots_sql "$ots")" = "$u1" ] && echo "refused, row kept by user 1" || { echo "FAIL another user's device was not refused / the row changed"; rc=1; }
  [ "$(gw_log "$ots" "refusing device $uid from")" -ge 1 ] 2>/dev/null && [ "$(gw_log "$ots" "owned by user")" -ge 1 ] 2>/dev/null || { echo "FAIL no 'owned by user' refusal line"; rc=1; }
  ots_sql "$ots" <<SQL >/dev/null
insert into euds (uid, last_status) values ('$run-H', 'Disconnected'), ('$run-N', 'Disconnected'); insert into cot (uid, sender_uid, timestamp, how, type, start, stale, xml) values ('$run-H-c', '$run-H', now(), 'h-e', 'a-f', now(), now(), '<event/>');
SQL
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=refused UID="$run-H" CS="$run-H" CERT=/tmp/GWO-u2.pem KEY=/tmp/GWO-u2.key HOLD=5 | tr -d '\r' | tail -1); echo "unowned row WITH history: $o"
  echo "$o" | grep -q '^CLOSED' && [ "$(echo "select coalesce(user_id::text,'NULL') from euds where uid='$run-H';" | ots_sql "$ots")" = NULL ] && echo "refused, still unowned" || { echo "FAIL an unowned device with history was taken"; rc=1; }
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=hold UID="$run-N" CS="$run-N" CERT=/tmp/GWO-u2.pem KEY=/tmp/GWO-u2.key HOLD=3 | tr -d '\r' | tail -1); echo "unowned row WITHOUT history: $o"
  echo "$o" | grep -q '^KEPT' && [ "$(echo "select coalesce(user_id::text,'NULL') from euds where uid='$run-N';" | ots_sql "$ots")" != NULL ] && echo "adopted by user 2" || { echo "FAIL an unowned device without history was not adopted"; rc=1; }
  gw_cleanup "$ots" "$run" GWO 2 || rc=1
  return $rc; }

# memory (M12): 16 idle devices (4 users x 4) <= EUD_MEM_MAX_MB (4) each, back within 15 MiB after they leave
chk_eud_mem_289() { local ots=$1 run m0 m1 m2 d rc=0 k u
  gw_pre "$ots" || return $?
  gw_users "$ots" GWM 4 || return 1
  run=DVM$(date +%H%M%S); m0=$(gw_mem "$ots"); isint "$m0" || { echo "FAIL memory.current unreadable"; return 1; }
  for u in 1 2 3 4; do for k in 1 2 3 4; do ( gwc "$ots" ots_cot_parser 90 ACTION=hold UID="$run-u$u-$k" CS="$run-u$u-$k" CERT=/tmp/GWM-u$u.pem KEY=/tmp/GWM-u$u.key HOLD=45 > "$DIR/eud-mem-289.$u.$k" ) & sleep 0.2; done; done
  sleep 30; m1=$(gw_mem "$ots"); isint "$m1" || m1=$m0
  d=$(( (m1 - m0) / 16 ))
  echo "memory.current: before $((m0/1048576)) MiB, with 16 idle devices $((m1/1048576)) MiB -> $((d/1024)) KiB per device (limit ${EUD_MEM_MAX_MB:-4} MiB; overlay 23 MiB)"
  [ "$d" -le $(( ${EUD_MEM_MAX_MB:-4} * 1048576 )) ] || { echo "FAIL $((d/1048576)) MiB per device"; rc=1; }
  wait; k=$(cat "$DIR"/eud-mem-289.* | tr -d '\r' | grep -c '^KEPT'); [ "$k" = 16 ] && echo "16/16 kept" || { echo "FAIL only $k/16 kept"; rc=1; }
  sleep 15; m2=$(gw_mem "$ots"); isint "$m2" || m2=$m1
  echo "after they left: $((m2/1048576)) MiB"; [ $(( (m2 - m0) / 1048576 )) -le 15 ] || { echo "FAIL memory did not return within 15 MiB of the baseline"; rc=1; }
  gw_cleanup "$ots" "$run" GWM 4 || rc=1
  return $rc; }

# broker-side loss (M6): the gateway's AMQP connection is closed by the broker under a stream: the client session is
# KEPT (the overlay ended it, R13), every CoT stored at least once, reconnect logged.
chk_amqp_close_289() { local ots=$1 run o rc=0 sent st l0 l1
  gw_pre "$ots" || return $?
  gw_users "$ots" GWQ 1 || return 1
  run=DVQ$(date +%H%M%S); l0=$(gw_log "$ots" "AMQP open"); isint "$l0" || l0=0
  ( gwc "$ots" ots_cot_parser 120 ACTION=stream UID="$run-S" CS="$run-S" CERT=/tmp/GWQ-u1.pem KEY=/tmp/GWQ-u1.key N=60 DELAY=0.5 HOLD=5 > "$DIR/amqp-close-289.S" ) &
  sleep 12
  o=$(fssh "$ots" 45 'n=$(docker exec rabbitmq rabbitmqctl -q list_connections pid client_properties 2>/dev/null | grep "batman-eud-gateway" | cut -f1 | head -1); [ -n "$n" ] && docker exec rabbitmq rabbitmqctl -q close_connection "$n" "amqp-close-289" >/dev/null 2>&1 && echo "closed $n" || echo "no gateway connection found"' | tr -d '\r'); echo "broker: $o"
  echo "$o" | grep -q '^closed' || { echo "FAIL could not close the gateway's AMQP connection — not verified"; rc=1; }
  wait; o=$(rd "$DIR/amqp-close-289.S"); echo "client: $o"
  echo "$o" | grep -q CONNLOST && { echo "FAIL the client session was cut by a broker-side loss (overlay R13 behaviour)"; rc=1; }
  sent=$(echo "$o" | sed -n 's/^SENT \([0-9]*\).*/\1/p'); [ "$sent" = 60 ] || { echo "FAIL sent [$sent] != 60"; rc=1; }
  sleep 20; st=$(echo "select count(distinct uid) from cot where uid like '$run-S-p%';" | ots_sql "$ots")
  echo "stored distinct: $st / 60"; [ "$st" = 60 ] || { echo "FAIL lost $((60 - ${st:-0})) CoT across the broker-side loss"; rc=1; }
  l1=$(gw_log "$ots" "AMQP open"); [ "${l1:-0}" -gt "$l0" ] && echo "reconnect logged" || { echo "FAIL no 'AMQP open' after the close"; rc=1; }
  gw_cleanup "$ots" "$run" GWQ 1 || rc=1
  return $rc; }

# the record (M10): the three FKs are RESTRICT; a device with history cannot be deleted; a resumed retention job is
# seen by the gateway within 35 s and by the guardian's record check (DRIFT), and goes quiet when re-paused.
chk_fk_289() { local ots=$1 run o rc=0 t0 v dr0
  gw_pre "$ots" || return $?
  run=DVF$(date +%H%M%S)
  o=$(echo "select string_agg(conname||'='||confdeltype::text||convalidated::text, ',' order by conname) from pg_constraint where conname in ('cot_eud','point_eud','geochat_eud');" | ots_sql "$ots")
  echo "FKs: $o"; [ "$o" = "cot_eud=rtrue,geochat_eud=rtrue,point_eud=rtrue" ] || { echo "FAIL record FKs not RESTRICT+validated"; rc=1; }
  ots_sql "$ots" <<SQL >/dev/null
insert into euds (uid, last_status) values ('$run-D', 'Disconnected'); insert into cot (uid, sender_uid, timestamp, how, type, start, stale, xml) values ('$run-D-c', '$run-D', now(), 'h-e', 'a-f', now(), now(), '<event/>');
SQL
  o=$(echo "delete from euds where uid='$run-D';" | ots_sql "$ots" 2>&1); echo "delete of a device with history: $(echo "$o" | head -1)"
  echo "$o" | grep -qi "violates" && [ "$(echo "select count(*) from cot where sender_uid='$run-D';" | ots_sql "$ots")" = 1 ] && echo "refused, history intact" || { echo "FAIL the delete was not refused / history lost"; rc=1; }
  dr0=$(fssh "$ots" 30 "$RDR"'grep -c "verify-profile-ots-record: DRIFT retention job RESUMED" "$R"/batman-payload-opentakserver-verify.log 2>/dev/null' | tr -d ' \r'); isint "$dr0" || dr0=0
  echo "update apscheduler_jobs set next_run_time = 4102444800 where id='delete_old_data';" | ots_sql "$ots" >/dev/null   # year 2100: never fires
  t0=$SECONDS; v=""
  while [ $((SECONDS - t0)) -lt 70 ]; do sleep 5; v=$(gw_health "$ots"); case "$v" in *'"jobs_resumed": ["delete_old_data"]'*) break ;; esac; done
  echo "healthz after the resume: $v ($((SECONDS - t0)) s)"
  case "$v" in *'"jobs_resumed": ["delete_old_data"]'*) echo "the gateway saw the resumed job" ;; *) echo "FAIL the gateway did not report the resumed job within 70 s"; rc=1 ;; esac
  [ "$(gw_log "$ots" "RESUMED job delete_old_data")" -ge 1 ] 2>/dev/null || { echo "FAIL no 'RESUMED job' line"; rc=1; }
  sleep 35
  o=$(fssh "$ots" 30 "$RDR"'grep -c "verify-profile-ots-record: DRIFT retention job RESUMED" "$R"/batman-payload-opentakserver-verify.log 2>/dev/null' | tr -d ' \r')
  [ "${o:-0}" -gt "$dr0" ] && echo "the guardian's record check reported DRIFT ($dr0 -> $o)" || { echo "FAIL verify-profile-ots-record did not report the resumed job (count $dr0 -> [$o]; last record line: $(fssh "$ots" 20 "$RDR"'grep verify-profile-ots-record "$R"/batman-payload-opentakserver-verify.log 2>/dev/null | tail -1' | tr -d '\r'))"; rc=1; }
  echo "update apscheduler_jobs set next_run_time = NULL where id='delete_old_data';" | ots_sql "$ots" >/dev/null
  sleep 35; v=$(gw_health "$ots"); case "$v" in *'"jobs_resumed": []'*) echo "re-paused: healthz clean" ;; *) echo "FAIL still reported after the re-pause: $v"; rc=1 ;; esac
  o=$(fssh "$ots" 20 "$RDR"'tail -1 "$R"/batman-payload-opentakserver-verify.log 2>/dev/null; grep "verify-profile-ots-record" "$R"/batman-payload-opentakserver-verify.log 2>/dev/null | tail -1' | tr -d '\r'); echo "record check now: $o"
  ots_sql "$ots" <<SQL >/dev/null
delete from cot where sender_uid like '$run-%'; delete from euds where uid like '$run-%';
SQL
  [ "$(echo "select count(*) from euds where uid like '$run-%';" | ots_sql "$ots")" = 0 ] || { echo "FAIL cleanup"; rc=1; }
  return $rc; }

# allowlist (P4): the allowlist is empty on the shipped profile -> 8088 is NOT bound; nothing on the node listens
chk_allowlist_289() { local ots=$1 o rc=0
  gw_pre "$ots" || return $?
  o=$(timeout 30 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" 'docker exec -i ots_cot_parser python3 -' <<EOF | tr -d '\r'
import socket
try:
    s = socket.create_connection(("$GW", 8088), timeout=3); print("OPEN"); s.close()
except Exception as e:
    print("REFUSED", type(e).__name__)
EOF
); echo "8088 on the gateway: $o"
  echo "$o" | grep -q '^REFUSED' || { echo "FAIL 8088 accepts connections with an empty allowlist"; rc=1; }
  [ "$(gw_log "$ots" "8088 not bound")" -ge 1 ] 2>/dev/null || { echo "FAIL no '8088 not bound' line"; rc=1; }
  echo "the allowlisted-relay leg needs a profile override (no override path on the node): covered offline (tests/test_config_bucket.py, test_integration.py)"
  return $rc; }

# bindings reconcile (P2 / M9): a device whose group membership is disabled by the admin stops receiving the group
# within 35 s; re-enabled, it receives again. The publisher is a direct publish to the `groups` exchange from
# inside ots_cot_parser (pika is there). Overlay: kept receiving until reconnect (A1-10).
chk_rebind_289() { local ots=$1 run o rc=0 gid uid g
  gw_pre "$ots" || return $?
  gw_users "$ots" GWR 1 || return 1
  run=DVR$(date +%H%M%S); g="DVG$run"; uid="$run-A"
  ots_sql "$ots" <<SQL >/dev/null
insert into groups (name, type, bitpos, created) values ('$g', 'SYSTEM', (select coalesce(max(bitpos),0)+1 from groups), now());
insert into groups_users (user_id, group_id, direction, enabled) select u.id, g.id, 'OUT', true from "user" u, groups g where u.username='GWR-u1' and g.name='$g';
SQL
  pubg() { fssh "$ots" 40 'docker exec -i ots_cot_parser python3 - <<EOF
import pika, json, datetime, time
c = pika.BlockingConnection(pika.ConnectionParameters(host="rabbitmq", credentials=pika.PlainCredentials("guest", "guest")))
ch = c.channel()
for i in range(1, 11):
    n = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    body = json.dumps({"uid": None, "cot": "<event version=\\"2.0\\" uid=\\"'"$1"'-%d\\" type=\\"b-t-f\\" how=\\"h-e\\" time=\\"%s\\" start=\\"%s\\" stale=\\"%s\\"><point lat=\\"0\\" lon=\\"0\\" hae=\\"0\\" ce=\\"1\\" le=\\"1\\"/><detail/></event>" % (i, n, n, n)})
    ch.basic_publish(exchange="groups", routing_key="'"$g"'.OUT", body=body)
    time.sleep(0.2)
c.close(); print("PUBLISHED 10")
EOF' | tr -d '\r'; }
  ( gwc "$ots" ots_cot_parser 120 ACTION=readcount UID="$uid" CS="$uid" CERT=/tmp/GWR-u1.pem KEY=/tmp/GWR-u1.key EXPECT="$run-G1-" N=10 HOLD=25 > "$DIR/rebind-289.1" ) &
  sleep 5; o=$(pubg "$run-G1"); echo "publish 1: $o"; wait; o=$(rd "$DIR/rebind-289.1"); echo "A with the group enabled: $o"
  echo "$o" | grep -q '^GOT 10' || { echo "FAIL A did not receive the group (10 expected) — the bindings were not placed"; rc=1; }
  echo "update groups_users set enabled=false where group_id=(select id from groups where name='$g');" | ots_sql "$ots" >/dev/null
  ( gwc "$ots" ots_cot_parser 120 ACTION=readcount UID="$uid" CS="$uid" CERT=/tmp/GWR-u1.pem KEY=/tmp/GWR-u1.key EXPECT="$run-G2-" N=10 HOLD=60 > "$DIR/rebind-289.2" ) &
  sleep 40; o=$(pubg "$run-G2"); echo "publish 2 (membership disabled 40 s ago): $o"; wait; o=$(rd "$DIR/rebind-289.2"); echo "A: $o"
  echo "$o" | grep -q '^GOT 0' && echo "unbound within the reconcile cycle" || { echo "FAIL A kept receiving a disabled group's traffic"; rc=1; }
  [ "$(gw_log "$ots" "rebind $uid +0 -1")" -ge 1 ] 2>/dev/null || echo "note: no 'rebind $uid +0 -1' line (the unbind may have been logged with other deltas)"
  ots_sql "$ots" <<SQL >/dev/null
delete from groups_users where group_id=(select id from groups where name='$g'); delete from groups where name='$g';
SQL
  gw_cleanup "$ots" "$run" GWR 1 || rc=1
  return $rc; }

# registration (called from daily-validation.sh when OTS_EUD=gateway)
# shellcheck source=scripts/dv/gateway-289b.sh
. "$REPO/scripts/dv/gateway-289b.sh"
gw_register() {
  suite ots-cot-e2e-289 "CoT sent == stored per phase on the gateway's 8089 (mTLS, a non-admin test user): P1 / P2 truncation / P3 burst (#289 M1/M5/M6)" "chk_cot_289 $OTS_NODE"
  suite presence-289 "a stale phone (black-holed, no FIN) -> row Disconnected and a teammate gets t-x-d-d within 150 s; back -> Connected (#289 P1/M8; overlay 8088: ghost for ever)" "chk_presence_289 $OTS_NODE"
  suite zombie-289 "the same device reconnects while its old socket is stale: downlink to the new connection only (10/10), the old one closed by the supersede deadline, no cot_parser disconnect (#289 M3/M7; overlay: split)" "chk_zombie_289 $OTS_NODE"
  suite cap-289 "per-user device cap 4 (6 at once -> 4 kept) and the new-device rate (8 fresh uids -> 4), refused uids leave no row/queue (#289 M2.5)" "chk_cap_289 $OTS_NODE"
  suite admission-289 "300 pre-TLS sockets hold up no phone (pool bounded), a ping flood is paused not cut, a 70 KiB message is discarded and the session kept (#289 M1/M2)" "chk_admission_289 $OTS_NODE"
  suite owner-8089-289 "another user's device uid refused (row kept), an unowned row with history refused, one without adopted (#289 M4)" "chk_owner_289 $OTS_NODE"
  suite eud-mem-289 "16 idle devices (4 users x 4) <= 4 MiB each, back to baseline after (#289 M12; overlay 23 MiB)" "chk_eud_mem_289 $OTS_NODE"
  suite amqp-close-289 "the broker closes the gateway's AMQP connection under a stream: client session kept, 60/60 stored, reconnect logged (#289 M6; overlay R13 ended the session)" "chk_amqp_close_289 $OTS_NODE"
  suite fk-restrict-289 "record FKs RESTRICT, a device with history cannot be deleted, a resumed retention job is reported by the gateway and the guardian's record check within 35 s (#289 P3/M10)" "chk_fk_289 $OTS_NODE"
  suite allowlist-289 "8088 is not bound with an empty allowlist (#289 P4)" "chk_allowlist_289 $OTS_NODE"
  suite rebind-289 "a disabled group membership stops the device's group traffic within the 30 s reconcile (#289 P2/M9; overlay: until reconnect)" "chk_rebind_289 $OTS_NODE"
  suite rto-289 "the RTO walks out and back: 16 phones stale (black-holed) + the same 16 reconnecting, a teammate streams, the RTO phone stays: 16 supersedes, 16/16 + RTO 10/10 kept, stale sockets closed by the deadline, no restart/OOM (#289 B1, M3/M7)" "chk_rto_289 $OTS_NODE"
  gw_register_b
}

# THE field scenario (design §0 / #289 B1, review B2 H2): the RTO walks out of range and comes back. 16 phones (4 users
# x 4) go stale at once (black-holed, still sending — dropped), the same 16 reconnect while their old sockets are
# stale, a teammate streams 10 events, the RTO's own phone (17th client, never stale) stays connected throughout.
# Asserted: 16 supersedes, every returned phone 10/10 and kept, the RTO phone kept and 10/10, the 16 stale sockets
# closed by the supersede deadline (<= 120 s), the gateway not restarted, no OOM kill, 17 devices then 0 left.
# One process on the node runs all 33 connections (scripts/node/gw-rto-289.py): the node's ssh limit.
chk_rto_289() { local ots=$1 run o rc=0 ports n i d0 d1 st0 st1 oom0 oom1 c0 c1 cg
  gw_pre "$ots" || return $?
  gw_users "$ots" GWT 5 || return 1
  run=DVT$(date +%H%M%S)
  cg='$(docker inspect -f "{{.Id}}" ots_eud_gateway)'
  st0=$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_gateway' | tr -d '\r')
  oom0=$(fssh "$ots" 20 "grep oom_kill /sys/fs/cgroup/docker/$cg/memory.events | cut -d' ' -f2" | tr -d ' \r')
  d0=$(gw_log "$ots" "closed (superseded: deadline)"); isint "$d0" || d0=0
  ( timeout 330 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" \
      "docker exec -i -e TARGET=$GW -e RUN=$run -e 'USERS=GWT-u1 GWT-u2 GWT-u3 GWT-u4' -e RTO=GWT-u5 -e PER=4 -e T1=40 -e HOLD2=170 ots_cot_parser python3 -" \
      < "$REPO/scripts/node/gw-rto-289.py" > "$DIR/rto-289.out" 2>&1 ) &
  for i in $(seq 1 20); do sleep 1; n=$(rd "$DIR/rto-289.out" | grep -c '^PORT '); [ "$n" = 16 ] && break; done
  ports=$(rd "$DIR/rto-289.out" | sed -n 's/^PORT [^ ]* \([0-9]*\)$/\1/p' | tr '\n' ' ')
  echo "16 phones connected and identified: $n port(s)"
  [ "$n" = 16 ] || { echo "FAIL only $n/16 phones reported a port — not verified"; rc=1; }
  o=$(gw_bh "$ots" add "$ports"); echo "black hole: $o"
  echo "$o" | grep -q '^BLACKHOLE 16$' && gw_bh_bites "$ots" 10 || { echo "FAIL the black hole does not bite — the storm was not made, not verified"; rc=1; }
  # PHASE2 at T1 = 40 s: the 16 return
  for i in $(seq 1 40); do sleep 1; rd "$DIR/rto-289.out" | grep -q '^PHASE2' && break; done
  sleep 12
  # the teammate streamer ($run-T) is a device of the run too while it streams (rc 3: counted 18): not counted here
  c0=$(gw_snap "$ots" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for x in d["devices"] if x["uid"].startswith("'"$run"'-") and x["uid"] != "'"$run"'-T"))' 2>/dev/null)
  o=$(gw_log "$ots" "superseded $run-"); echo "after the return: $c0 device(s) of the run, $o supersede line(s)"
  [ "$c0" = 17 ] || { echo "FAIL expected 17 devices of the run (16 + the RTO phone), got [$c0]"; rc=1; }
  [ "${o:-0}" = 16 ] || { echo "FAIL expected 16 supersedes, got [$o]"; rc=1; }
  # the 16 stale sockets are closed by the supersede deadline while the returned phones live
  for i in $(seq 1 14); do sleep 10; d1=$(gw_log "$ots" "closed (superseded: deadline)"); isint "$d1" || d1=0; [ $((d1 - d0)) -ge 16 ] && break; done
  echo "stale sockets closed by the deadline: $((d1 - d0)) / 16 after ~$((i * 10)) s"
  [ $((d1 - d0)) -ge 16 ] || { echo "FAIL not every stale socket was closed by the supersede deadline"; rc=1; }
  wait
  o=$(rd "$DIR/rto-289.out"); echo "$o" | grep -E '^(GOT|RTO|OLD|STREAM|STALE-ERR)' | sed 's/^/  /'
  n=$(echo "$o" | grep -c '^GOT .* 10 kept'); echo "returned phones with 10/10 and kept: $n / 16"
  [ "$n" = 16 ] || { echo "FAIL $((16 - n)) returned phone(s) missed downlink or were cut"; rc=1; }
  echo "$o" | grep -q '^RTO GOT 10 kept' || { echo "FAIL the RTO's own phone missed the stream or was cut"; rc=1; }
  echo "$o" | grep -q '^OLD 0/16 still open here' || { echo "FAIL a stale socket is still open on the client side (the deadline close is an abort: RST expected)"; rc=1; }
  st1=$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_gateway' | tr -d '\r')
  oom1=$(fssh "$ots" 20 "grep oom_kill /sys/fs/cgroup/docker/$cg/memory.events | cut -d' ' -f2" | tr -d ' \r')
  [ "$st0" = "$st1" ] && [ "$oom0" = "$oom1" ] && echo "gateway not restarted (StartedAt $st1), oom_kill $oom1" || { echo "FAIL the gateway restarted or was OOM-killed (StartedAt $st0 -> $st1, oom_kill $oom0 -> $oom1)"; rc=1; }
  gw_bh "$ots" del | sed 's/^/  /'
  gw_cleanup "$ots" "$run" GWT 5 || rc=1
  return $rc; }
