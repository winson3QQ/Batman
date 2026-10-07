#!/bin/sh
# dockerd-restart.sh — dockerd restarts cleanly with a live container (#268 C2, split out of the lifecycle
# suite). Sent as `ssh root@node sh -s < this`. Runs ONLY on a node with no tenant containers: restarting
# dockerd on a node that carries one (OTS) is a service outage, and the 1.5.2 baseline showed an
# unless-stopped container comes back `exited` (OpenWrt dockerd stop path — tenants rely on the payload
# guardian). The precondition is the node's actual state, not its name.
#   exit 0 PASS · 1 FAIL · 3 + "SKIP-REASON:" line = not run here (the harness turns all-skipped into SKIP)
B=/bin/busybox
others=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -v '^dv-' | tr '\n' ' ')
if [ -n "$others" ]; then echo "SKIP-REASON: tenant containers present ($others) — dockerd restart would be an outage"; exit 3; fi
IMG=dv-dr:$(cat $B /lib/ld-musl-*.so.1 /lib/libc.so 2>/dev/null | sha256sum | cut -c1-12)
cleanup(){ docker rm -f dv-dr >/dev/null 2>&1; docker rmi "$IMG" >/dev/null 2>&1; rm -rf /tmp/dv-dr.*; }
cleanup; trap cleanup EXIT
t=/tmp/dv-dr.$$; mkdir -p $t/bin $t/lib; cp $B $t/bin/; for a in sh sleep; do ln -s busybox $t/bin/$a; done
cp -P /lib/ld-musl-*.so.1 $t/lib/; cp /lib/libc.so $t/lib/; [ -e /lib/libgcc_s.so.1 ] && cp /lib/libgcc_s.so.1 $t/lib/
tar -C $t -cf - . | docker import - "$IMG" >/dev/null 2>&1 || { echo "FAIL import"; exit 1; }; rm -rf $t
docker run -d --name dv-dr --restart=unless-stopped "$IMG" $B sleep 600 >/dev/null 2>&1 || { echo "FAIL run -d"; exit 1; }
sleep 2
/etc/init.d/dockerd restart >/dev/null 2>&1
back=0; for i in $(seq 1 24); do docker info >/dev/null 2>&1 && { back=1; break; }; sleep 5; done
sleep 10; st=$(docker inspect -f '{{.State.Status}}' dv-dr 2>/dev/null)
echo "info: after dockerd restart the unless-stopped container is [$st] (1.5.2 baseline: exited)"
[ "$back" = 1 ] || { echo "FAIL dockerd did not answer within 120 s of a restart"; exit 1; }
docker run --rm "$IMG" $B true >/dev/null 2>&1 || { echo "FAIL dockerd answers but cannot run a container after restart"; exit 1; }
echo "PASS dockerd back after restart and runs containers"
