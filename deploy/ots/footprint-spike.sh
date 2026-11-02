#!/bin/sh
# OTS footprint spike — brings the core stack up on a node and measures idle RAM/CPU.
#
# THIS IS A MEASUREMENT SPIKE, NOT A PRODUCTION DEPLOYMENT.
# Production networking is design-gated (#162 design-review): on our OpenWrt nodes
# docker bridge networks are rejected by fw3, and host-net collides with node
# services (openmanetd 8081/8080/8087, uhttpd 80/443). This spike uses host-net and
# therefore can only run the DB + broker + ONE OTS service at a time without a port
# remap — it exists to reproduce the measured footprint, see README.md.
#
# Prereq: node has docker + memcg, and the three arm64 images loaded:
#   batman/ots:1.7.13-arm64  imresamu/postgis:18-3.6  rabbitmq:latest
set -e
OTS_IMG="batman/ots:1.7.13-arm64"
DB_IMG="imresamu/postgis:18-3.6"
MQ_IMG="rabbitmq:latest"

cleanup() { for c in ots_eud_handler_ssl ots_eud_handler ots_cot_parser opentakserver rabbitmq ots-db; do docker rm -f "$c" 2>/dev/null || true; done; }
cleanup

echo "## postgis (host-net, ephemeral)"
docker run -d --name ots-db --network host \
  -e POSTGRES_USER=ots -e POSTGRES_PASSWORD=password -e POSTGRES_DB=ots -e PGUSER=ots "$DB_IMG" >/dev/null
printf "   wait pg"; for i in $(seq 1 60); do docker exec ots-db pg_isready -q 2>/dev/null && { echo " ok"; break; }; printf "."; sleep 2; done

echo "## rabbitmq (host-net; --user rabbitmq + cookie avoids .erlang.cookie eacces)"
docker run -d --name rabbitmq --network host --user rabbitmq \
  -e RABBITMQ_ERLANG_COOKIE=batmanspikecookie "$MQ_IMG" >/dev/null
printf "   wait mq"; for i in $(seq 1 90); do docker exec rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1 && { echo " ok"; break; }; printf "."; sleep 2; done

echo "## one OTS worker (representative python service)"
docker run -d --name ots_eud_handler --network host \
  -e SQLALCHEMY_DATABASE_URI=postgresql+psycopg://ots:password@localhost/ots \
  -e OTS_RABBITMQ_SERVER_ADDRESS=localhost -e OTS_LISTENER_ADDRESS=0.0.0.0 -e OTS_FQDN=_ \
  --entrypoint python3 "$OTS_IMG" /app/venv/bin/eud_handler >/dev/null

echo "## settle 120s"; sleep 120

echo "## FOOTPRINT (idle, no clients) ============================"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}'
free -m | awk 'NR==2{printf "node mem: used=%dMiB free=%dMiB total=%dMiB\n",$3,$4,$2}'
cleanup
echo "SPIKE-DONE (containers cleaned)"
