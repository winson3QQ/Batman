#!/bin/sh
# run.sh — (re)create the FTS + FTS-UI containers on a payload-host node (#119).
#
# Tenant layout (docs/storage-architecture.md, p5 sub-layout v1):
#   /opt/batdata/docker            docker data-root  (uci dockerd.globals.data_root)
#   /opt/batdata/apps/fts          FTS state: DBs, certs, FTSConfig.yaml, data packages  -> container /opt/fts
#   /opt/batdata/apps/fts-ui       UI state: FTSServer-UI.db, api-key                    -> container /opt/ftsui-data
# Images are shared in docker/; every tenant owns only its apps/<name>/ directory.
#
#   run.sh [--image fts:2.2.1-slim] [--ui-image fts-ui:2.2.1] [--no-ui]
#
# Ports (--network host, on the node's mesh address): CoT TCP 18087, SSL CoT 8089, HTTPS API 8443,
# REST 19023, UI 5000 (openmanetd owns 8080/8087, hence the moved ports — see README).
# The UI needs the FTS API token: put it in apps/fts-ui/api-key (mode 600) — one line, the raw
# token, no "Bearer ". Nothing here creates users; that stays a deliberate admin step (README).
set -e
BAT=/opt/batdata
IMG=fts:2.2.1-slim
UI_IMG=fts-ui:2.2.1
UI=1
while [ $# -gt 0 ]; do
	case "$1" in
		--image) IMG=$2; shift 2;; --ui-image) UI_IMG=$2; shift 2;; --no-ui) UI=0; shift;;
		*) echo "usage: run.sh [--image I] [--ui-image I] [--no-ui]"; exit 2;;
	esac
done
command -v docker >/dev/null || { echo "docker not installed (deploy/fts/README.md: payload-host packages)"; exit 1; }
[ "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)" = "$BAT/docker" ] || echo "WARN: docker data-root is not $BAT/docker (uci dockerd.globals.data_root)"
mkdir -p "$BAT/apps/fts" "$BAT/apps/fts-ui"

echo "==> fts ($IMG)"
docker rm -f fts >/dev/null 2>&1 || true
docker run -d --name fts --restart unless-stopped --network host \
	-v "$BAT/apps/fts:/opt/fts" -e FTS_FIRST_START=false "$IMG" >/dev/null
echo "    started; CoT :18087, SSL CoT :8089, REST :19023"

if [ "$UI" = 1 ]; then
	KEYF="$BAT/apps/fts-ui/api-key"
	if [ ! -s "$KEYF" ]; then
		echo "==> fts-ui SKIPPED: $KEYF missing (raw FTS API token, mode 600)"; exit 0
	fi
	TOKEN=$(head -1 "$KEYF" | tr -d '\r\n')
	echo "==> fts-ui ($UI_IMG)"
	docker rm -f fts-ui >/dev/null 2>&1 || true
	docker run -d --name fts-ui --restart unless-stopped --network host \
		-v "$BAT/apps/fts-ui:/opt/ftsui-data" \
		-e FTS_UI_EXPOSED_IP=0.0.0.0 -e FTS_IP=127.0.0.1 -e FTS_API_PORT=19023 -e FTS_API_PROTO=http \
		-e "FTS_API_KEY=Bearer $TOKEN" \
		-e FTS_UI_SQLALCHEMY_DATABASE_URI=sqlite:////opt/ftsui-data/FTSServer-UI.db \
		-w /usr/local/lib/python3.11/site-packages/FreeTAKServer-UI "$UI_IMG" python run.py >/dev/null
	echo "    started; UI http://<node>:5000"
fi
docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}'
