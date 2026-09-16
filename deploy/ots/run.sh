#!/bin/sh
# run.sh — the OTS ordering-wrapper (payload framework app #1, #68/#162).
#
# The R2-chosen orchestrator: sequential `docker run` on a FIXED-name bridge (br-ots) with the
# emitter's $HARDEN_FLAGS applied to the OTS app containers, health-gated between steps. NOT
# docker-compose (it would build a random br-<hash> bridge that the fw4 iifname "br-ots" rules
# miss, and can't consume the run-flag $HARDEN_FLAGS string). See docs/design/payload-framework.md.
#
# Prereqs (node prep, one-time — see README):
#   - dockerd iptables=0 (uci dockerd.globals.iptables=0)      [design B single-table]
#   - fw4 rules applied: sh deploy/ots/ots.fw4.uci  (or installed as a uci-default)
#   - images loaded: batman/ots:1.7.13-arm64, imresamu/postgis:18-3.6, rabbitmq:latest
#
#   run.sh [--cookie <rabbitmq-erlang-cookie>]
set -e
BAT=/opt/batdata
NET=ots-net ; BR=br-ots ; SUBNET=172.20.0.0/24
OTS=batman/ots:1.7.13-arm64 ; DB=imresamu/postgis:18-3.6 ; MQ=rabbitmq:latest
COOKIE=batman-ots-cookie
while [ $# -gt 0 ]; do case "$1" in --cookie) COOKIE=$2; shift 2;; *) echo "usage: run.sh [--cookie C]"; exit 2;; esac; done

command -v docker >/dev/null || { echo "docker not installed (deploy/ots/README.md)"; exit 1; }
[ "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)" = "$BAT/docker" ] || echo "WARN: docker data-root is not $BAT/docker"
docker network inspect "$NET" >/dev/null 2>&1 || \
  docker network create --driver bridge --subnet "$SUBNET" -o com.docker.network.bridge.name="$BR" "$NET" >/dev/null
[ "$(docker network inspect "$NET" -f '{{index .Options "com.docker.network.bridge.name"}}')" = "$BR" ] \
  || { echo "FATAL: $NET kernel bridge is not $BR — fw4 iifname rules would miss (recreate the network)"; exit 1; }

# #98 confinement flags from the OTS tenant profile (scripts/profile-to-flags.py) — applied to the
# OTS APP containers only; postgis/rabbitmq are co-scheduled infra with their own minimal treatment.
HERE=$(cd "$(dirname "$0")" && pwd)
HARDEN=""; [ -f "$HERE/ots.hardening.env" ] && { . "$HERE/ots.hardening.env"; HARDEN="$HARDEN_FLAGS"; }

# volumes (persist on p6) + non-root ownership (spike: ots uid 1024, rabbitmq 999)
for v in ots-appdata ots-pgdata ots-mqdata; do docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v" >/dev/null; done
docker run --rm --user 0 -v ots-appdata:/app/ots --entrypoint chown "$OTS" -R 1024:1024 /app/ots
docker run --rm --user 0 -v ots-mqdata:/var/lib/rabbitmq --entrypoint chown "$OTS" -R 999:999 /var/lib/rabbitmq 2>/dev/null || true

CM="--network $NET --restart on-failure:5 \
 -e SQLALCHEMY_DATABASE_URI=postgresql+psycopg://ots:password@ots-db/ots \
 -e OTS_RABBITMQ_SERVER_ADDRESS=rabbitmq -e OTS_LISTENER_ADDRESS=0.0.0.0 -e OTS_FQDN=_ \
 -e OTS_MEDIAMTX_API_ADDRESS=http://localhost:9997 -v ots-appdata:/app/ots"

echo "==> ots-db (postgis)"
docker rm -f ots-db >/dev/null 2>&1 || true
docker run -d --name ots-db --hostname ots-db --network "$NET" --ip 172.20.0.2 --restart on-failure:5 \
  -e POSTGRES_USER=ots -e POSTGRES_PASSWORD=password -e POSTGRES_DB=ots -e PGUSER=ots \
  -v ots-pgdata:/var/lib/postgresql "$DB" >/dev/null
printf "    wait pg"; i=0; while [ $i -lt 60 ]; do docker exec ots-db pg_isready -q 2>/dev/null && { echo " ok"; break; }; printf .; sleep 2; i=$((i+1)); done

echo "==> rabbitmq (--user rabbitmq + cookie)"
docker rm -f rabbitmq >/dev/null 2>&1 || true
docker run -d --name rabbitmq --hostname rabbitmq --network "$NET" --ip 172.20.0.3 --restart on-failure:5 \
  --user rabbitmq -e RABBITMQ_ERLANG_COOKIE="$COOKIE" -v ots-mqdata:/var/lib/rabbitmq "$MQ" >/dev/null
printf "    wait mq"; i=0; while [ $i -lt 90 ]; do docker exec rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1 && { echo " ok"; break; }; printf .; sleep 2; i=$((i+1)); done

echo "==> opentakserver API  [harden: ${HARDEN:-none}]"
docker rm -f opentakserver >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name opentakserver --hostname opentakserver --ip 172.20.0.5 $CM $HARDEN "$OTS" >/dev/null
printf "    wait api"; i=0; while [ $i -lt 60 ]; do docker exec opentakserver sh -c 'curl -fsS http://localhost:8081/api/health >/dev/null 2>&1' && { echo " ok"; break; }; printf .; sleep 2; i=$((i+1)); done

echo "==> cot_parser / eud_handler / eud_handler_ssl  [harden applied]"
docker rm -f ots_cot_parser ots_eud_handler ots_eud_handler_ssl >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name ots_cot_parser --hostname ots-cot_parser $CM $HARDEN --entrypoint python3 "$OTS" /app/venv/bin/cot_parser >/dev/null
# shellcheck disable=SC2086
docker run -d --name ots_eud_handler --hostname ots_eud_handler --ip 172.20.0.10 $CM $HARDEN --entrypoint python3 "$OTS" /app/venv/bin/eud_handler >/dev/null
# shellcheck disable=SC2086
docker run -d --name ots_eud_handler_ssl --hostname ots_eud_handler_ssl --ip 172.20.0.12 $CM $HARDEN --entrypoint python3 "$OTS" /app/venv/bin/eud_handler --ssl >/dev/null
# NOTE: eud_handler_ssl needs its TLS cert (values.secrets: eud-ssl-cert; delivery unowned #167) or it exits.
# NOTE: nginx web UI (8443) is optional and NOT started in Milestone A core.

echo "==> status"
docker ps --format '{{.Names}}  {{.Status}}'
echo "publish (via fw4 DNAT, apply deploy/ots/ots.fw4.uci): ahwlan :8088->eud, :8089->eud-ssl, :8443->nginx(optional)"
