# gateway-289b.sh — the #289 gateway suites for dependency failures and tier B (sourced by gateway-289.sh;
# design docs/design/289-eud-gateway.md §4/§7; reviewer B2 H2 / B3 H-2: these were missing).
#
# Conventions as gateway-289.sh: clients run inside ots_cot_parser over mTLS with 1-day test certs; at most 4
# clients at once (dropbear's ssh limit); every suite removes its rows/users/certs/queues; an unreadable count
# is a FAIL. The dependency is hurt from INSIDE its container where possible (rabbitmqctl stop_app / docker
# pause) so the guardian sees nothing and no DRIFT window is opened; the ones that do open one (amqp-down:
# exit 3 + guardian restart; fresh-volumes) are tier B and run last.

# stored distinct uids of a stream: <ots> <uid prefix>
gw_stored() { echo "select count(distinct uid) from cot where uid like '$2%';" | ots_sql "$1" | tr -d ' \r'; }
# a client's output file -> its last line
gw_last() { rd "$1" | tail -1; }

# dbdown-289 (tier B by design, no DRIFT: `docker pause ots-db`): ots-db unreachable for 20 s while 4 devices
# (4 users) stream 1 event / 0.5 s for 60 s. Asserted: no client session cut (no CONNLOST); every CoT stored
# after (4 x 120 distinct); the 4 rows Connected again within one reconcile cycle; gateway not restarted.
# Negative control: offline tests/test_review3.py (end with the DB down) + design (overlay: FK-dropped CoT).
chk_dbdown_289() { local ots=$1 run o rc=0 k st0 st1 n paused=0
  gw_pre "$ots" || return $?
  gw_users "$ots" GWB 4 || return 1
  run=DVB$(date +%H%M%S); st0=$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_gateway' | tr -d '\r')
  for k in 1 2 3 4; do ( gwc "$ots" ots_cot_parser 150 ACTION=stream UID="$run-u$k" CS="$run-u$k" CERT=/tmp/GWB-u$k.pem KEY=/tmp/GWB-u$k.key N=120 DELAY=0.5 HOLD=20 > "$DIR/dbdown-289.$k" ) & sleep 0.3; done
  sleep 10
  o=$(fssh "$ots" 20 'docker pause ots-db >/dev/null 2>&1 && echo PAUSED || echo "pause failed"' | tr -d '\r'); echo "t=10 s: ots-db $o"
  [ "$o" = PAUSED ] && paused=1 || { echo "FAIL could not pause ots-db — not verified"; rc=1; }
  sleep 20
  o=$(fssh "$ots" 20 'docker unpause ots-db >/dev/null 2>&1 && echo UNPAUSED || echo "unpause failed"' | tr -d '\r'); echo "t=30 s: ots-db $o"
  [ "$o" = UNPAUSED ] || { echo "FAIL could not unpause ots-db"; rc=1; }
  wait
  for k in 1 2 3 4; do o=$(gw_last "$DIR/dbdown-289.$k"); echo "client $k: $o"
    echo "$o" | grep -q '^SENT 120' || { echo "FAIL client $k did not send 120 ($o)"; rc=1; }
    rd "$DIR/dbdown-289.$k" | grep -q CONNLOST && { echo "FAIL client $k's session was cut while the DB was away"; rc=1; }; done
  sleep 40
  n=$(gw_stored "$ots" "$run-"); echo "stored distinct uids: $n / 480 (4 x 120, cached while the DB was away, flushed after)"
  isint "$n" && [ "$n" = 480 ] || { echo "FAIL $((480 - ${n:-0})) CoT lost across the DB outage"; rc=1; }
  o=$(echo "select count(*) from euds where uid like '$run-%' and last_status='Disconnected';" | ots_sql "$ots" | tr -d ' \r')
  echo "rows Disconnected after the clients left: $o / 4"; [ "$o" = 4 ] || { echo "FAIL presence not re-asserted / ended after the outage ($o of 4 Disconnected)"; rc=1; }
  st1=$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_gateway' | tr -d '\r')
  [ "$st0" = "$st1" ] && echo "gateway not restarted" || { echo "FAIL the gateway restarted during the DB outage ($st0 -> $st1)"; rc=1; }
  [ "$paused" = 1 ] && fssh "$ots" 20 'docker unpause ots-db >/dev/null 2>&1; true' >/dev/null
  gw_cleanup "$ots" "$run" GWB 4 || rc=1
  return $rc; }

# broker-restart-289 (tier B by design; `rabbitmqctl stop_app` 15 s then start_app: the container stays, the
# guardian sees nothing): 4 held devices. Asserted: all 4 sessions KEPT; after the broker is back a teammate's
# 10-event stream reaches each of the 4 (10/10: queues re-declared, bindings re-placed); `AMQP open` logged
# again. Negative control: design (overlay ended every session on a broker loss; amqp-close-289 covers the
# single-close case on the gateway).
chk_broker_restart_289() { local ots=$1 run o rc=0 k l0 l1
  gw_pre "$ots" || return $?
  gw_users "$ots" GWK 5 || return 1
  run=DVK$(date +%H%M%S); l0=$(gw_log "$ots" "AMQP open"); isint "$l0" || l0=0
  for k in 1 2 3 4; do ( gwc "$ots" ots_cot_parser 200 ACTION=readcount UID="$run-u$k" CS="$run-u$k" CERT=/tmp/GWK-u$k.pem KEY=/tmp/GWK-u$k.key EXPECT="$run-T-p" N=10 STAY=1 HOLD=110 > "$DIR/broker-restart-289.$k" ) & sleep 0.3; done
  sleep 8
  o=$(fssh "$ots" 60 'docker exec rabbitmq rabbitmqctl stop_app >/dev/null 2>&1 && echo STOPPED || echo "stop_app failed"' | tr -d '\r'); echo "t=8 s: broker app $o"
  [ "$o" = STOPPED ] || { echo "FAIL could not stop the broker app — not verified"; rc=1; }
  sleep 15
  o=$(fssh "$ots" 90 'docker exec rabbitmq rabbitmqctl start_app >/dev/null 2>&1 && echo STARTED || echo "start_app failed"' | tr -d '\r'); echo "t=23 s: broker app $o"
  [ "$o" = STARTED ] || { echo "FAIL could not start the broker app"; rc=1; }
  sleep 45   # the gateway reconnects with backoff, re-declares, re-places; the 30 s reconcile re-binds
  o=$(gwc "$ots" ots_cot_parser 60 ACTION=stream UID="$run-T" CS="$run-T" CERT=/tmp/GWK-u5.pem KEY=/tmp/GWK-u5.key N=10 DELAY=1 HOLD=3 | tr -d '\r' | tail -1); echo "teammate after the restart: $o"
  wait
  for k in 1 2 3 4; do o=$(gw_last "$DIR/broker-restart-289.$k"); echo "device $k: $o"
    echo "$o" | grep -q '^GOT 10 open' || { echo "FAIL device $k: $o (expected GOT 10 open: session kept and re-bound after the broker restart)"; rc=1; }; done
  l1=$(gw_log "$ots" "AMQP open"); [ "${l1:-0}" -gt "$l0" ] && echo "reconnect logged (AMQP open $l0 -> $l1)" || { echo "FAIL no 'AMQP open' after the restart"; rc=1; }
  gw_cleanup "$ots" "$run" GWK 5 || rc=1
  return $rc; }

# queue-gone-289: cot_parser restarted (`docker restart`, the guardian records it: run in the tier-B block)
# under a 4-device stream: sessions kept, every CoT stored (the cot_parser queue is durable; bodies unacked at
# the restart are redelivered). Negative control: design (the overlay re-declared + retried; upstream lost).
chk_queue_gone_289() { local ots=$1 run o rc=0 k n
  gw_pre "$ots" || return $?
  gw_users "$ots" GWG 4 || return 1
  run=DVG$(date +%H%M%S)
  for k in 1 2 3 4; do ( gwc "$ots" ots_cot_parser 150 ACTION=stream UID="$run-u$k" CS="$run-u$k" CERT=/tmp/GWG-u$k.pem KEY=/tmp/GWG-u$k.key N=100 DELAY=0.5 HOLD=20 > "$DIR/queue-gone-289.$k" ) & sleep 0.3; done
  sleep 12
  o=$(fssh "$ots" 90 'docker restart -t 5 ots_cot_parser >/dev/null 2>&1 && echo RESTARTED || echo "restart failed"' | tr -d '\r'); echo "t=12 s: cot_parser $o"
  [ "$o" = RESTARTED ] || { echo "FAIL could not restart cot_parser — not verified"; rc=1; }
  wait
  for k in 1 2 3 4; do o=$(gw_last "$DIR/queue-gone-289.$k"); echo "client $k: $o"
    echo "$o" | grep -q '^SENT 100' || { echo "FAIL client $k did not send 100 ($o)"; rc=1; }
    rd "$DIR/queue-gone-289.$k" | grep -q CONNLOST && { echo "FAIL client $k's session was cut by the cot_parser restart"; rc=1; }; done
  sleep 30
  n=$(gw_stored "$ots" "$run-"); echo "stored distinct uids: $n / 400"
  isint "$n" && [ "$n" = 400 ] || { echo "FAIL $((400 - ${n:-0})) CoT lost across the cot_parser restart"; rc=1; }
  gw_cleanup "$ots" "$run" GWG 4 || rc=1
  return $rc; }

# slowreader-289: one phone that reads 512 B every 0.2 s (≈ 20 kbit/s) under a teammate's 40 x 30 KiB burst
# while 3 normal phones read: the slow one's session is KEPT (bounded sendq, drops counted, never closed for
# being slow), the 3 others get 40/40. Negative control: design (overlay: TCP_USER_TIMEOUT only; by code).
chk_slowreader_289() { local ots=$1 run o rc=0 k sq
  gw_pre "$ots" || return $?
  gw_users "$ots" GWS 5 || return 1
  run=DVW$(date +%H%M%S)
  ( gwc "$ots" ots_cot_parser 200 ACTION=slowread UID="$run-S" CS="$run-S" CERT=/tmp/GWS-u1.pem KEY=/tmp/GWS-u1.key HOLD=120 CHUNK=512 PAUSE=0.2 > "$DIR/slowreader-289.S" ) &
  for k in 2 3 4; do ( gwc "$ots" ots_cot_parser 200 ACTION=readcount UID="$run-u$k" CS="$run-u$k" CERT=/tmp/GWS-u$k.pem KEY=/tmp/GWS-u$k.key EXPECT="$run-T-p" N=40 STAY=1 HOLD=115 > "$DIR/slowreader-289.$k" ) & sleep 0.3; done
  sleep 6
  o=$(gwc "$ots" ots_cot_parser 120 ACTION=stream UID="$run-T" CS="$run-T" CERT=/tmp/GWS-u5.pem KEY=/tmp/GWS-u5.key N=40 DELAY=0.5 PAD=30000 HOLD=3 | tr -d '\r' | tail -1); echo "burst: $o"
  sleep 12; sq=$(gw_snap "$ots" | python3 -c 'import json,sys; d=json.load(sys.stdin); x=[(v["sendq"], v["sendq_dropped"]) for v in d["devices"] if v["uid"]=="'"$run-S"'"]; print(x[0][0], x[0][1]) if x else print("absent")' 2>/dev/null)
  echo "slow phone during the burst: sendq / dropped = [$sq] (bounded: <= 200 entries; the device is still in the table)"
  case "$sq" in absent|"") echo "FAIL the slow phone's device is gone from the table (closed for being slow?)"; rc=1 ;; esac
  wait
  o=$(gw_last "$DIR/slowreader-289.S"); echo "slow phone: $o"
  echo "$o" | grep -q '^SLOW .* open' || { echo "FAIL the slow phone's session was cut ($o)"; rc=1; }
  for k in 2 3 4; do o=$(gw_last "$DIR/slowreader-289.$k"); echo "phone $k: $o"
    echo "$o" | grep -q '^GOT 40 open' || { echo "FAIL phone $k: $o (expected GOT 40 open: unaffected by the slow reader)"; rc=1; }; done
  gw_cleanup "$ots" "$run" GWS 5 || rc=1
  return $rc; }

# cert-reload-289: (a) an EXPIRED CRL by the node clock and (b) a FUTURE one (lastUpdate 15 months ahead, the
# real-time case on a node whose clock is 2025-07) are ignored (healthz crl_honoured false + reason) and a phone
# still connects; (c) a VALID CRL listing the test cert refuses it before identification; the original CRL is
# restored and honoured again. The CRLs are signed on the node with the OTS CA (node clock). Negative control:
# the v3 design failed every handshake on (b) (reviewer B3, openssl); upstream has no CRL at all.
chk_cert_reload_289() { local ots=$1 run o rc=0 leg v
  gw_pre "$ots" || return $?
  gw_users "$ots" GWL 1 || return 1
  run=DVL$(date +%H%M%S)
  v=$(gw_health "$ots"); case "$v" in *'"crl_honoured": true'*) echo "before: the node's CRL is honoured" ;; *) echo "FAIL precondition: the CRL is not honoured before the test ($v)"; gw_cleanup "$ots" "$run" GWL 1; return 1 ;; esac
  for leg in expired future valid; do
    o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i -e LEG=$leg -e REVOKE=/tmp/GWL-u1.pem ots_cot_parser python3 -" < "$REPO/scripts/node/gw-crl-289.py" 2>&1 | tr -d '\r')
    echo "CRL leg $leg: $o"; echo "$o" | grep -q '^OK CRL' || { echo "FAIL could not write the $leg CRL — not verified"; rc=1; continue; }
    sleep 35   # the context is rebuilt on the next 30 s cycle (mtime changed)
    v=$(gw_health "$ots"); echo "  healthz: $(echo "$v" | tr -d '\n' | sed 's/.*\("crl_honoured": [a-z]*\).*/\1/')"
    o=$(gwc "$ots" ots_cot_parser 40 ACTION=hold UID="$run-$leg" CS="$run-$leg" CERT=/tmp/GWL-u1.pem KEY=/tmp/GWL-u1.key HOLD=3 | tr -d '\r' | tail -1); echo "  phone with the test cert: $o"
    case $leg in
      expired|future)
        case "$v" in *'"crl_honoured": false'*) ;; *) echo "FAIL the $leg CRL is honoured (every handshake would fail once the listing is real)"; rc=1 ;; esac
        echo "$o" | grep -q '^KEPT' || { echo "FAIL the phone could not connect with the $leg CRL in place ($o)"; rc=1; } ;;
      valid)
        case "$v" in *'"crl_honoured": true'*) ;; *) echo "FAIL a valid CRL is not honoured"; rc=1 ;; esac
        echo "$o" | grep -q '^KEPT' && { echo "FAIL the REVOKED test cert was admitted"; rc=1; }
        [ "$(echo "select count(*) from euds where uid='$run-valid';" | ots_sql "$ots" | tr -d ' \r')" = 0 ] || { echo "FAIL a revoked cert left a row"; rc=1; } ;;
    esac
  done
  o=$(timeout 60 ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=8 "root@$ots" "docker exec -i -e LEG=restore ots_cot_parser python3 -" < "$REPO/scripts/node/gw-crl-289.py" 2>&1 | tr -d '\r'); echo "restore: $o"
  echo "$o" | grep -q '^OK CRL' || { echo "FAIL could not restore the original CRL — CHECK /app/ots/ca/ca.crl ON THE NODE"; rc=1; }
  sleep 35; v=$(gw_health "$ots"); case "$v" in *'"crl_honoured": true'*) echo "after: the original CRL is honoured again" ;; *) echo "FAIL the original CRL is not honoured after the restore ($v)"; rc=1 ;; esac
  o=$(gwc "$ots" ots_cot_parser 40 ACTION=hold UID="$run-after" CS="$run-after" CERT=/tmp/GWL-u1.pem KEY=/tmp/GWL-u1.key HOLD=3 | tr -d '\r' | tail -1); echo "phone after the restore: $o"
  echo "$o" | grep -q '^KEPT' || { echo "FAIL the test cert is refused after the restore ($o)"; rc=1; }
  gw_cleanup "$ots" "$run" GWL 1 || rc=1
  return $rc; }

# amqp-down-289 (tier B, opens the guardian's DRIFT window: run last): the broker app stopped for 330 s -> the
# gateway exits 3 (AMQP down > 300 s), the guardian restarts it (ledger), a phone identifies after the broker is
# back. Negative control: by code (the exit-3 watchdog; offline tests cover the clock).
chk_amqp_down_289() { local ots=$1 run o rc=0 st0 st1 e0 e1 t0
  gw_pre "$ots" || return $?
  gw_users "$ots" GWX 1 || return 1
  run=DVX$(date +%H%M%S); st0=$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_gateway' | tr -d '\r')
  e0=$(gw_log "$ots" "exit 3"); isint "$e0" || e0=0
  o=$(fssh "$ots" 60 'docker exec rabbitmq rabbitmqctl stop_app >/dev/null 2>&1 && echo STOPPED || echo "stop_app failed"' | tr -d '\r'); echo "broker app $o"
  [ "$o" = STOPPED ] || { echo "FAIL could not stop the broker app — not verified"; gw_cleanup "$ots" "$run" GWX 1; return 1; }
  t0=$SECONDS
  while [ $((SECONDS - t0)) -lt 400 ]; do sleep 20; st1=$(fssh "$ots" 20 'docker inspect -f "{{.State.StartedAt}}" ots_eud_gateway' | tr -d '\r'); [ -n "$st1" ] && [ "$st1" != "$st0" ] && break; done
  echo "gateway restarted by the guardian after $((SECONDS - t0)) s of broker outage: $([ "$st1" != "$st0" ] && echo yes || echo no) ($st0 -> $st1)"
  [ "$st1" != "$st0" ] || { echo "FAIL the gateway did not exit 3 / was not restarted within 400 s of the broker being down"; rc=1; }
  o=$(fssh "$ots" 90 'docker exec rabbitmq rabbitmqctl start_app >/dev/null 2>&1 && echo STARTED || echo "start_app failed"' | tr -d '\r'); echo "broker app $o"
  [ "$o" = STARTED ] || { echo "FAIL could not start the broker app — CHECK rabbitmq ON THE NODE"; rc=1; }
  e1=$(gw_log "$ots" "exit 3"); [ "${e1:-0}" -gt "$e0" ] && echo "exit 3 logged ($e0 -> $e1)" || echo "note: no 'exit 3' line found in the current log file ($e0 -> $e1)"
  sleep 60
  o=$(gwc "$ots" ots_cot_parser 60 ACTION=hold UID="$run-A" CS="$run-A" CERT=/tmp/GWX-u1.pem KEY=/tmp/GWX-u1.key HOLD=5 | tr -d '\r' | tail -1); echo "phone after the broker is back: $o"
  echo "$o" | grep -q '^KEPT' || { echo "FAIL a phone cannot identify after the broker outage ($o)"; rc=1; }
  gw_cleanup "$ots" "$run" GWX 1 || rc=1
  return $rc; }

gw_register_b() {
  suite dbdown-289 "ots-db paused 20 s under a 4-device stream: sessions kept, 480/480 stored after, rows re-asserted, gateway not restarted (#289 §4 'ots-db down during')" "chk_dbdown_289 $OTS_NODE"
  suite broker-restart-289 "the broker app stopped 15 s with 4 held devices: all kept, re-declared and re-bound (10/10 after), reconnect logged (#289 §4 'broker restart')" "chk_broker_restart_289 $OTS_NODE"
  suite slowreader-289 "a phone reading at ~20 kbit/s under a 1.2 MiB burst: session kept, sendq bounded, 3 normal phones 40/40 (#289 §4 'slow reader')" "chk_slowreader_289 $OTS_NODE"
  suite cert-reload-289 "an expired and a future CRL are ignored (phones still connect), a valid CRL listing the test cert refuses it; the original CRL honoured again after (#289 M14)" "chk_cert_reload_289 $OTS_NODE"
}
gw_register_b_destructive() {
  suite queue-gone-289 "cot_parser restarted under a 4-device stream: sessions kept, 400/400 stored (#289 §4 'cot_parser restart'; opens the guardian's ledger window)" "chk_queue_gone_289 $OTS_NODE" D
  suite amqp-down-289 "broker app down > 300 s: the gateway exits 3, the guardian restarts it, a phone identifies after (#289 §4 'exit 3'; tier B)" "chk_amqp_down_289 $OTS_NODE" D
}
