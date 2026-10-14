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
gw_log() { fssh "$1" 30 'docker exec ots_eud_gateway sh -c "grep -c '"'"'"'"$2"'"'"'"' /app/ots/logs/eud_gateway.log 2>/dev/null"' | tr -d ' \r'; }
gw_logl() { fssh "$1" 30 'docker exec ots_eud_gateway sh -c "grep '"'"'"'"$2"'"'"'"' /app/ots/logs/eud_gateway.log 2>/dev/null | tail -'"${3:-5}"'"' | tr -d '\r'; }
gw_snap() { fssh "$1" 20 'docker exec ots_eud_gateway cat /tmp/gateway/sessions.json 2>/dev/null' | tr -d '\r'; }
gw_counter() { gw_snap "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["counters"].get("'"$2"'", 0))' 2>/dev/null; }
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
# gw_users <ots> <prefix> <n>: n non-admin test users + 1-day certs at ots_cot_parser:/tmp/<prefix>-u<k>.{pem,key}
gw_users() { local ots=$1 p=$2 n=$3 k o
  for k in $(seq 1 "$n"); do
    echo "delete from \"user\" where username='$p-u$k'; insert into \"user\" (username, active, fs_uniquifier) values ('$p-u$k', true, md5(random()::text));" | ots_sql "$ots" >/dev/null
    o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i -e CN=$p-u$k ots_cot_parser python3 -" < "$REPO/scripts/node/ots-test-client-cert.py" 2>&1 | tr -d '\r')
    echo "$o" | grep -q '^OK test client cert' || { echo "FAIL could not issue the test cert for $p-u$k: $o"; return 1; }
    fssh "$ots" 15 "docker exec ots_cot_parser sh -c 'mv /tmp/dv-client.pem /tmp/$p-u$k.pem; mv /tmp/dv-client.key /tmp/$p-u$k.key'"
  done; echo "$n test user(s) $p-u1..$n with 1-day certs (node clock)"; }
# gwc <ots> <ctr> <timeout> <env...>: run gw-client-289.py inside <ctr> with the given -e assignments
gwc() { local ots=$1 ctr=$2 to=$3; shift 3; local e="" v
  for v in "$@"; do e="$e -e $v"; done
  timeout "$to" ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i $e -e TARGET=$GW -e CA=/app/ots/ca/ca.pem ots_cot_parser python3 -" < "$REPO/scripts/node/gw-client-289.py" 2>&1 | tr -d '\r'; }
gw_bh() { timeout 30 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$1" "ACTION=$2 PORT=${3:-0} sh -s" < "$REPO/scripts/node/gw-blackhole-289.sh" 2>&1 | tr -d '\r'; }
# gw_cleanup <ots> <run-prefix> <user-prefix> <n-users>: rows (RESTRICT order), users, certs, queues; FAIL on leftovers
gw_cleanup() { local ots=$1 run=$2 p=$3 n=$4 o rc=0
  ots_sql "$ots" <<SQL >/dev/null
begin; delete from cot where sender_uid like '$run-%' or uid like '$run-%'; delete from points where device_uid like '$run-%'; delete from geochat where sender_uid like '$run-%'; delete from euds where uid like '$run-%'; delete from "user" where username like '$p-u%'; commit;
SQL
  o=$(echo "select (select count(*) from euds where uid like '$run-%') || ' ' || (select count(*) from \"user\" where username like '$p-u%');" | ots_sql "$ots")
  [ "$o" = "0 0" ] || { echo "FAIL cleanup left rows/users: [$o]"; rc=1; }
  fssh "$ots" 20 "docker exec ots_cot_parser sh -c 'rm -f /tmp/$p-u*.pem /tmp/$p-u*.key'" >/dev/null
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
  ( gwc "$ots" ots_cot_parser 200 ACTION=readcount UID="$run-B" CS="$run-B" CERT=/tmp/GWP-u2.pem KEY=/tmp/GWP-u2.key EXPECT="$run-A" N=1 HOLD=170 > "$DIR/presence-289.B" ) &
  sleep 3
  # A (user 1) identifies and stops reading; its port is black-holed on the node
  ( gwc "$ots" ots_cot_parser 260 ACTION=noread UID="$run-A" CS="$run-A" CERT=/tmp/GWP-u1.pem KEY=/tmp/GWP-u1.key HOLD=230 > "$DIR/presence-289.A" ) &
  for t0 in 1 2 3 4 5 6 7 8; do sleep 1; port=$(sed -n 's/^PORT \([0-9]*\)$/\1/p' "$DIR/presence-289.A" 2>/dev/null); [ -n "$port" ] && break; done
  isint "$port" || { echo "FAIL A did not report its port — not verified"; wait; return 1; }
  st=$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots"); echo "A identified (port $port), row [$st]"
  [ "$st" = Connected ] || { echo "FAIL A's row is not Connected after identification"; rc=1; }
  o=$(gw_bh "$ots" add "$port"); echo "$o"; echo "$o" | grep -q "^BLACKHOLE $port 1$" || { echo "FAIL black hole not installed — not verified"; rc=1; }
  t0=$SECONDS
  while [ $((SECONDS - t0)) -lt 160 ]; do sleep 10; st=$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots"); [ "$st" = Disconnected ] && break; done
  echo "A's row after the black hole: [$st] after $((SECONDS - t0)) s (expect Disconnected within 150 s)"
  [ "$st" = Disconnected ] || { echo "FAIL the stale phone's row stayed $st (ghost; overlay 8088: for ever)"; rc=1; }
  cnt=$(gw_log "$ots" "ended $run-A"); [ "${cnt:-0}" -ge 1 ] && echo "gateway logged the end of $run-A" || { echo "FAIL no 'ended $run-A' line"; rc=1; }
  wait
  o=$(cat "$DIR/presence-289.B"); echo "B: $o"
  echo "$o" | grep -q '^GOT [1-9]' && echo "B received the t-x-d-d for A" || { echo "FAIL B did not receive A's t-x-d-d"; rc=1; }
  gw_bh "$ots" del >/dev/null
  # the phone comes back: its row flips to Connected
  o=$(gwc "$ots" ots_cot_parser 60 ACTION=hold UID="$run-A" CS="$run-A" CERT=/tmp/GWP-u1.pem KEY=/tmp/GWP-u1.key HOLD=8); echo "A back: $(echo "$o" | tail -1)"
  st=$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots")
  sleep 3; echo "A's row after it left again: [$(echo "select last_status from euds where uid='$run-A';" | ots_sql "$ots")] (Connected while held: [$st])"
  gw_cleanup "$ots" "$run" GWP 2 || rc=1
  return $rc; }

# same device, new connection (zombie / same-uid-end): A stops reading (black-holed); B (same user+uid) connects:
# downlink goes to B only (10/10 from C), A's socket is closed by the supersede deadline (<= 120 s), no cot_parser
# disconnect for the uid while B lives, the row stays Connected. Overlay: the downlink was split round-robin.
chk_zombie_289() { local ots=$1 run o rc=0 port t0 d0 d1 cnt
  gw_pre "$ots" || return $?
  gw_users "$ots" GWZ 2 || return 1
  run=DVZ$(date +%H%M%S)
  d0=$(fssh "$ots" 20 'docker exec ots_cot_parser sh -c "grep -c \"Sending disconnect cot to '"$run-A"'\$\" /app/ots/logs/cot_parser.log 2>/dev/null"' | tr -d ' \r'); isint "$d0" || d0=0
  ( gwc "$ots" ots_cot_parser 260 ACTION=noread UID="$run-A" CS="$run-A" CERT=/tmp/GWZ-u1.pem KEY=/tmp/GWZ-u1.key HOLD=200 > "$DIR/zombie-289.A" ) &
  for t0 in 1 2 3 4 5 6 7 8; do sleep 1; port=$(sed -n 's/^PORT \([0-9]*\)$/\1/p' "$DIR/zombie-289.A" 2>/dev/null); [ -n "$port" ] && break; done
  isint "$port" || { echo "FAIL A did not report its port"; wait; return 1; }
  o=$(gw_bh "$ots" add "$port"); echo "A (port $port) black-holed: $o"
  # B: the same device reconnects (same user, same uid) and reads what C sends
  ( gwc "$ots" ots_cot_parser 120 ACTION=readcount UID="$run-A" CS="$run-A" CERT=/tmp/GWZ-u1.pem KEY=/tmp/GWZ-u1.key EXPECT="$run-C-p" N=10 HOLD=60 > "$DIR/zombie-289.B" ) &
  sleep 4
  cnt=$(gw_log "$ots" "superseded $run-A"); [ "${cnt:-0}" -ge 1 ] && echo "gateway logged the supersede" || { echo "FAIL no 'superseded $run-A' line"; rc=1; }
  o=$(gwc "$ots" ots_cot_parser 60 ACTION=stream UID="$run-C" CS="$run-C" CERT=/tmp/GWZ-u2.pem KEY=/tmp/GWZ-u2.key N=10 DELAY=1 HOLD=3); echo "C: $o"
  wait
  o=$(cat "$DIR/zombie-289.B"); echo "B: $o"
  echo "$o" | grep -q '^GOT 10' && echo "B got 10/10 (downlink to the new connection only)" || { echo "FAIL B got $(echo "$o" | sed -n 's/^GOT \([0-9]*\).*/\1/p')/10 (split with the zombie?)"; rc=1; }
  # A's socket is closed by the supersede deadline (outage + 20 s, <= 120 s after the supersede)
  t0=$SECONDS; cnt=0
  while [ $((SECONDS - t0)) -lt 130 ]; do sleep 10; cnt=$(gw_log "$ots" "connection of $run-A .* closed (superseded: deadline)"); [ "${cnt:-0}" -ge 1 ] && break; done
  [ "${cnt:-0}" -ge 1 ] && echo "A's stale connection closed by the deadline after $((SECONDS - t0)) s" || { echo "FAIL A's connection was not closed by the supersede deadline within 130 s"; rc=1; }
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
  kept=$(cat "$DIR"/cap-289.[1-6] | grep -c '^KEPT'); closed=$(cat "$DIR"/cap-289.[1-6] | grep -c '^CLOSED')
  echo "6 devices of one user at once: kept $kept, refused $closed (expect 4 / 2)"
  [ "$kept" = 4 ] && [ "$closed" = 2 ] || { echo "FAIL per-user device cap not enforced"; rc=1; }
  cnt=$(gw_log "$ots" "refusing device $run-u1-.*: per-user device cap"); [ "${cnt:-0}" -ge 1 ] && echo "refusal logged" || { echo "FAIL no 'per-user device cap' refusal line"; rc=1; }
  # cycling: user 2 identifies 8 fresh uids one after the other (the 4 already seen above do not count for user 2)
  kept=0; closed=0
  for k in 1 2 3 4 5 6 7 8; do o=$(gwc "$ots" ots_cot_parser 30 ACTION=hold UID="$run-u2-$k" CS="$run-u2-$k" CERT=/tmp/GWC-u2.pem KEY=/tmp/GWC-u2.key HOLD=2 | tail -1); case "$o" in KEPT*) kept=$((kept+1)) ;; *) closed=$((closed+1)) ;; esac; done
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
chk_admission_289() { local ots=$1 run o rc=0 p0 p1 pend
  gw_pre "$ots" || return $?
  gw_users "$ots" GWA 1 || return 1
  run=DVA$(date +%H%M%S)
  ( gwc "$ots" ots_cot_parser 60 ACTION=rawflood N=300 HOLD=15 > "$DIR/admission-289.raw" ) &
  sleep 2
  o=$(gwc "$ots" ots_cot_parser 40 ACTION=hold UID="$run-P" CS="$run-P" CERT=/tmp/GWA-u1.pem KEY=/tmp/GWA-u1.key HOLD=8 | tail -1)
  pend=$(gw_snap "$ots" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending"])' 2>/dev/null)
  wait; echo "raw flood: $(cat "$DIR/admission-289.raw"); phone during it: $o; pending in the snapshot: $pend"
  case "$o" in KEPT*) ;; *) echo "FAIL the phone was not kept during the pre-TLS flood"; rc=1 ;; esac
  isint "$pend" && [ "$pend" -le 1024 ] || { echo "FAIL pending [$pend] not within MAX_PENDING"; rc=1; }
  p0=$(gw_counter "$ots" uplink_paused); isint "$p0" || p0=0
  o=$(gwc "$ots" ots_cot_parser 60 ACTION=pingflood UID="$run-F" CERT=/tmp/GWA-u1.pem KEY=/tmp/GWA-u1.key N=3000 | tail -1); echo "ping flood: $o"
  sleep 2; p1=$(gw_counter "$ots" uplink_paused); isint "$p1" || p1=0
  echo "$o" | grep -q 'open=1' && [ "$p1" -gt "$p0" ] && echo "flood paused ($((p1 - p0)) pause(s)), socket kept" || { echo "FAIL ping flood not bounded by the message bucket (paused $p0 -> $p1, $o)"; rc=1; }
  o=$(gwc "$ots" ots_cot_parser 40 ACTION=oversize UID="$run-O" CS="$run-O" CERT=/tmp/GWA-u1.pem KEY=/tmp/GWA-u1.key SIZE=70000 | tail -1); echo "oversize: $o"
  echo "$o" | grep -q '^PONG 1' && echo "70 KiB message discarded, session kept (pong)" || { echo "FAIL oversize message closed the session or no pong"; rc=1; }
  gw_cleanup "$ots" "$run" GWA 1 || rc=1
  return $rc; }

# ownership (M4): another user's uid refused (closed, row unchanged); an unowned row with history refused; an
# unowned row without history adopted. Overlay: the second user took the row (wsl.10) / was recorded.
chk_owner_289() { local ots=$1 run o rc=0 uid
  gw_pre "$ots" || return $?
  gw_users "$ots" GWO 2 || return 1
  run=DVO$(date +%H%M%S); uid="$run-X"
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=hold UID="$uid" CS="$uid" CERT=/tmp/GWO-u1.pem KEY=/tmp/GWO-u1.key HOLD=3 | tail -1); echo "user 1 owns $uid: $o"
  u1=$(echo "select user_id from euds where uid='$uid';" | ots_sql "$ots")
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=refused UID="$uid" CS="$uid" CERT=/tmp/GWO-u2.pem KEY=/tmp/GWO-u2.key HOLD=5 | tail -1); echo "user 2 claims it: $o"
  echo "$o" | grep -q '^CLOSED' && [ "$(echo "select user_id from euds where uid='$uid';" | ots_sql "$ots")" = "$u1" ] && echo "refused, row kept by user 1" || { echo "FAIL another user's device was not refused / the row changed"; rc=1; }
  [ "$(gw_log "$ots" "refusing device $uid from .*: owned by user")" -ge 1 ] || { echo "FAIL no 'owned by user' refusal line"; rc=1; }
  ots_sql "$ots" <<SQL >/dev/null
insert into euds (uid, last_status) values ('$run-H', 'Disconnected'), ('$run-N', 'Disconnected'); insert into cot (uid, sender_uid, timestamp, how, type, start, stale, xml) values ('$run-H-c', '$run-H', now(), 'h-e', 'a-f', now(), now(), '<event/>');
SQL
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=refused UID="$run-H" CS="$run-H" CERT=/tmp/GWO-u2.pem KEY=/tmp/GWO-u2.key HOLD=5 | tail -1); echo "unowned row WITH history: $o"
  echo "$o" | grep -q '^CLOSED' && [ "$(echo "select coalesce(user_id::text,'NULL') from euds where uid='$run-H';" | ots_sql "$ots")" = NULL ] && echo "refused, still unowned" || { echo "FAIL an unowned device with history was taken"; rc=1; }
  o=$(gwc "$ots" ots_cot_parser 30 ACTION=hold UID="$run-N" CS="$run-N" CERT=/tmp/GWO-u2.pem KEY=/tmp/GWO-u2.key HOLD=3 | tail -1); echo "unowned row WITHOUT history: $o"
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
  wait; k=$(cat "$DIR"/eud-mem-289.* | grep -c '^KEPT'); [ "$k" = 16 ] && echo "16/16 kept" || { echo "FAIL only $k/16 kept"; rc=1; }
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
  wait; o=$(cat "$DIR/amqp-close-289.S"); echo "client: $o"
  echo "$o" | grep -q CONNLOST && { echo "FAIL the client session was cut by a broker-side loss (overlay R13 behaviour)"; rc=1; }
  sent=$(echo "$o" | sed -n 's/^SENT \([0-9]*\).*/\1/p'); [ "$sent" = 60 ] || { echo "FAIL sent [$sent] != 60"; rc=1; }
  sleep 20; st=$(echo "select count(distinct uid) from cot where uid like '$run-S-p%';" | ots_sql "$ots")
  echo "stored distinct: $st / 60"; [ "$st" = 60 ] || { echo "FAIL lost $((60 - ${st:-0})) CoT across the broker-side loss"; rc=1; }
  l1=$(gw_log "$ots" "AMQP open"); [ "${l1:-0}" -gt "$l0" ] && echo "reconnect logged" || { echo "FAIL no 'AMQP open' after the close"; rc=1; }
  gw_cleanup "$ots" "$run" GWQ 1 || rc=1
  return $rc; }

# the record (M10): the three FKs are RESTRICT; a device with history cannot be deleted; a resumed retention job is
# seen by the gateway within 35 s and by the guardian's record check (DRIFT), and goes quiet when re-paused.
chk_fk_289() { local ots=$1 run o rc=0 t0 v
  gw_pre "$ots" || return $?
  run=DVF$(date +%H%M%S)
  o=$(echo "select string_agg(conname||'='||confdeltype||convalidated::text, ',' order by conname) from pg_constraint where conname in ('cot_eud','point_eud','geochat_eud');" | ots_sql "$ots")
  echo "FKs: $o"; [ "$o" = "cot_eud=rtrue,geochat_eud=rtrue,point_eud=rtrue" ] || { echo "FAIL record FKs not RESTRICT+validated"; rc=1; }
  ots_sql "$ots" <<SQL >/dev/null
insert into euds (uid, last_status) values ('$run-D', 'Disconnected'); insert into cot (uid, sender_uid, timestamp, how, type, start, stale, xml) values ('$run-D-c', '$run-D', now(), 'h-e', 'a-f', now(), now(), '<event/>');
SQL
  o=$(echo "delete from euds where uid='$run-D';" | ots_sql "$ots" 2>&1); echo "delete of a device with history: $(echo "$o" | head -1)"
  echo "$o" | grep -qi "violates foreign key" && [ "$(echo "select count(*) from cot where sender_uid='$run-D';" | ots_sql "$ots")" = 1 ] && echo "refused, history intact" || { echo "FAIL the delete was not refused / history lost"; rc=1; }
  echo "update apscheduler_jobs set next_run_time = 4102444800 where id='delete_old_data';" | ots_sql "$ots" >/dev/null   # year 2100: never fires
  t0=$SECONDS; v=""
  while [ $((SECONDS - t0)) -lt 70 ]; do sleep 5; v=$(gw_health "$ots"); case "$v" in *'"jobs_resumed": ["delete_old_data"]'*) break ;; esac; done
  echo "healthz after the resume: $v ($((SECONDS - t0)) s)"
  case "$v" in *'"jobs_resumed": ["delete_old_data"]'*) echo "the gateway saw the resumed job" ;; *) echo "FAIL the gateway did not report the resumed job within 70 s"; rc=1 ;; esac
  [ "$(gw_log "$ots" "RESUMED job delete_old_data")" -ge 1 ] || { echo "FAIL no 'RESUMED job' line"; rc=1; }
  o=$(fssh "$ots" 20 "$RDR"'sleep 35; grep -c "verify-profile-ots-record: DRIFT retention job RESUMED" "$R"/batman-payload-opentakserver-verify.log 2>/dev/null' | tr -d ' \r')
  [ "${o:-0}" -ge 1 ] && echo "the guardian's record check reported DRIFT" || { echo "FAIL verify-profile-ots-record did not report the resumed job (count [$o])"; rc=1; }
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
  o=$(fssh "$ots" 30 'docker exec ots_cot_parser python3 -c "
import socket
try:
    s = socket.create_connection((\"'"$GW"'\", 8088), timeout=3); print(\"OPEN\"); s.close()
except Exception as e:
    print(\"REFUSED\", type(e).__name__)"' | tr -d '\r'); echo "8088 on the gateway: $o"
  echo "$o" | grep -q '^REFUSED' || { echo "FAIL 8088 accepts connections with an empty allowlist"; rc=1; }
  [ "$(gw_log "$ots" "8088 not bound (allowlist empty)")" -ge 1 ] || { echo "FAIL no '8088 not bound' line"; rc=1; }
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
  sleep 5; o=$(pubg "$run-G1"); echo "publish 1: $o"; wait; o=$(cat "$DIR/rebind-289.1"); echo "A with the group enabled: $o"
  echo "$o" | grep -q '^GOT 10' || { echo "FAIL A did not receive the group (10 expected) — the bindings were not placed"; rc=1; }
  echo "update groups_users set enabled=false where group_id=(select id from groups where name='$g');" | ots_sql "$ots" >/dev/null
  ( gwc "$ots" ots_cot_parser 120 ACTION=readcount UID="$uid" CS="$uid" CERT=/tmp/GWR-u1.pem KEY=/tmp/GWR-u1.key EXPECT="$run-G2-" N=10 HOLD=60 > "$DIR/rebind-289.2" ) &
  sleep 40; o=$(pubg "$run-G2"); echo "publish 2 (membership disabled 40 s ago): $o"; wait; o=$(cat "$DIR/rebind-289.2"); echo "A: $o"
  echo "$o" | grep -q '^GOT 0' && echo "unbound within the reconcile cycle" || { echo "FAIL A kept receiving a disabled group's traffic"; rc=1; }
  [ "$(gw_log "$ots" "rebind $uid +0 -1")" -ge 1 ] || echo "note: no 'rebind $uid +0 -1' line (the unbind may have been logged with other deltas)"
  ots_sql "$ots" <<SQL >/dev/null
delete from groups_users where group_id=(select id from groups where name='$g'); delete from groups where name='$g';
SQL
  gw_cleanup "$ots" "$run" GWR 1 || rc=1
  return $rc; }

# registration (called from daily-validation.sh when OTS_EUD=gateway)
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
}
