#!/bin/sh
# CI drift guard: the provisioning files exist in TWO trees that must stay byte-identical —
#   deploy/provisioning/*            consumed by scripts/depersonalise.sh (on-node golden prep), and
#   feed/batman-provision/files/*    baked into the firmware image by the OpenWrt package (#159).
# They deliver the SAME runtime file to the SAME destination, so a divergence means a node prepped by
# depersonalise.sh behaves differently from one running the built image — the exact class of bug that
# shipped a fix to only one tree (e.g. a halow-status edit that never reached the image). This asserts
# every pair is identical. Exit 0 = in sync; exit 1 = drift (prints the diff).
#
# When you edit a provisioning file, edit BOTH copies (or copy one to the other) — this gate enforces it.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
D="$ROOT/deploy/provisioning"
F="$ROOT/feed/batman-provision/files"

# deploy-path : feed-path  (feed path = the image destination the Makefile / depersonalise.sh install to)
PAIRS="
halow-status:usr/bin/halow-status
batman-config-save:usr/bin/batman-config-save
halow-setkey:usr/bin/halow-setkey
batpower:usr/bin/batpower
batpower.init:etc/init.d/batpower
flightrec:usr/bin/flightrec
flightrec.init:etc/init.d/flightrec
joinwatch:usr/bin/joinwatch
joinwatch.init:etc/init.d/joinwatch
halow-keyguard.init:etc/init.d/halow-keyguard
uci-defaults/95-batman-storage:etc/uci-defaults/95-batman-storage
uci-defaults/96-batman-config-migrate:etc/uci-defaults/96-batman-config-migrate
www/status:www/cgi-bin/status
www/bundle:www/cgi-bin/bundle
www/mesh:www/cgi-bin/mesh
meshpoint-1.8.0.sh:usr/bin/meshpoint-1.8.0
www/index.html:www/index-batman.html
"

rc=0; n=0
for pair in $PAIRS; do
	dp="$D/${pair%%:*}"; fp="$F/${pair##*:}"
	if [ ! -f "$dp" ]; then echo "FAIL: missing deploy copy $dp"; rc=1; continue; fi
	if [ ! -f "$fp" ]; then echo "FAIL: missing feed copy   $fp"; rc=1; continue; fi
	if ! diff -u "$dp" "$fp"; then
		echo ">> DRIFT: deploy/provisioning/${pair%%:*}  !=  feed/batman-provision/files/${pair##*:}"
		rc=1
	fi
	n=$((n + 1))
done

if [ "$rc" = 0 ]; then
	echo "OK: all $n provisioning pairs are byte-identical across deploy/ and feed/"
else
	echo "provisioning-sync: DRIFT — edit BOTH the deploy/ and feed/ copies (they ship the same runtime file)."
fi
exit "$rc"
