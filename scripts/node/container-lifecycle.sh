# container-lifecycle.sh — node-side container stack regression (#268 B1; from the #252/#247-2 dogfood).
# Sent by daily-validation.sh as `ssh root@node sh -s < this`. busybox ash; no network needed:
# the test image is imported from this rootfs's own busybox + musl (same recipe as the autocommit
# canary). Every item is PASS or FAIL — there is no "info" escape that would silently shrink the
# count; the HARNESS owns the expected count and checks `RESULT pass=N fail=M` against it.
# Does NOT restart dockerd (that is dockerd-restart.sh, only on nodes without tenants) and never
# touches a container it did not create (all names start with dv-).
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS $*"; }
no(){ F=$((F+1)); echo "  FAIL $*"; }
# busybox has no `timeout` applet: run "$@" for at most $1 s
to(){ n=$1; shift; "$@" & p=$!; ( sleep "$n"; kill "$p" 2>/dev/null ) & w=$!; wait "$p"; r=$?; kill "$w" 2>/dev/null; return $r; }
B=/bin/busybox
echo "== $(uci -q get system.@system[0].hostname) $(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build) | $(runc --version 2>&1 | head -1)"

cleanup(){
	for c in $(docker ps -aq --filter name=^dv- 2>/dev/null); do docker rm -f "$c" >/dev/null 2>&1; done
	[ -n "${IMG:-}" ] && docker rmi "$IMG" >/dev/null 2>&1
	rm -rf /tmp/dv-lc.* /tmp/dv-bundle /tmp/dv-cp.*
}
cleanup
trap cleanup EXIT

# 1 import (always — a cached image would hide a broken import path)
IMG=dv-lc:$(cat $B /lib/ld-musl-*.so.1 /lib/libc.so 2>/dev/null | sha256sum | cut -c1-12)
docker rmi "$IMG" >/dev/null 2>&1
t=/tmp/dv-lc.$$; mkdir -p $t/bin $t/lib; cp $B $t/bin/; for a in sh cat tr sleep echo true; do ln -s busybox $t/bin/$a; done
cp -P /lib/ld-musl-*.so.1 $t/lib/; cp /lib/libc.so $t/lib/; [ -e /lib/libgcc_s.so.1 ] && cp /lib/libgcc_s.so.1 $t/lib/
tar -C $t -cf - . | docker import - "$IMG" >/dev/null 2>&1 && ok "import image" || no "import image"; rm -rf $t

# 2 memory + cpu limits visible inside (cgroup v2)
o=$(docker run --rm --name dv-lim --memory 32m --cpus 0.5 "$IMG" $B sh -c 'echo ok; cat /sys/fs/cgroup/memory.max; cat /sys/fs/cgroup/cpu.max' 2>&1)
case "$o" in *ok*33554432*"50000 100000"*) ok "run --rm --memory 32m --cpus 0.5 (limits visible inside)" ;; *) no "run with limits: [$o]" ;; esac

# 3 detached + 4 exec (runc setns path)
docker run -d --name dv-lc "$IMG" $B sleep 600 >/dev/null 2>&1 && ok "run -d" || no "run -d"
o=$(docker exec dv-lc $B sh -c 'echo exec-ok; tr "\0" " " < /proc/1/cmdline' 2>&1)
case "$o" in *exec-ok*sleep*) ok "exec into running container" ;; *) no "exec: [$o]" ;; esac

# 5 OOM inside a 16m limit is contained (container killed, node fine)
o=$(docker run --rm --name dv-oom --memory 16m --memory-swap 16m "$IMG" $B sh -c 'x=a; while :; do x=$x$x; done' 2>&1; echo "rc=$?")
case "$o" in *rc=137*) ok "OOM inside 16m limit -> container killed (137)" ;; *) no "OOM test: [$o]" ;; esac

# 6 restart policy
docker run -d --name dv-rp --restart=on-failure:3 "$IMG" $B sh -c 'sleep 2; exit 1' >/dev/null 2>&1
sleep 25; rc=$(docker inspect -f '{{.RestartCount}}' dv-rp 2>/dev/null)
case "$rc" in ''|*[!0-9]*) no "restart policy: RestartCount unreadable [$rc]" ;; *) [ "$rc" -ge 2 ] && ok "restart policy on-failure (RestartCount=$rc)" || no "restart policy RestartCount=$rc" ;; esac

# 7 exeseal (CVE-2025-52881 class): plain runc --debug on a bundle exported from the image
cid=$(docker create "$IMG" $B true 2>/dev/null); d=/tmp/dv-bundle; mkdir -p $d/rootfs
docker export "$cid" 2>/dev/null | tar -C $d/rootfs -xf - 2>/dev/null; docker rm "$cid" >/dev/null 2>&1
( cd $d && runc spec >/dev/null 2>&1 && sed -i 's/"terminal": true/"terminal": false/; s/"sh"/"\/bin\/busybox","true"/' config.json )
o=$(cd $d && runc --debug run dv-exeseal </dev/null 2>&1); runc delete -f dv-exeseal >/dev/null 2>&1; rm -rf $d
case "$o" in *"using overlayfs for sealed /proc/self/exe"*) ok "exeseal: overlayfs" ;;
	*) no "exeseal: no 'using overlayfs' message [$(echo "$o" | grep -oE 'could not use overlayfs[^;]*|cloning [^ ]+ binary' | head -1)]" ;; esac

# 8 five execs must not grow the container's memory.peak (a fallback exe copy adds ~12 MB each)
id=$(docker run -d --name dv-mp --memory 64m "$IMG" $B sleep 600 2>/dev/null); cg=/sys/fs/cgroup/docker/$id
p0=$(cat $cg/memory.peak 2>/dev/null); for i in 1 2 3 4 5; do docker exec dv-mp $B true </dev/null; done; p1=$(cat $cg/memory.peak 2>/dev/null)
case "$p0$p1" in ''|*[!0-9]*) no "memory.peak unreadable [$p0] [$p1]" ;;
	*) [ $((p1 - p0)) -lt 8388608 ] && ok "5 execs grew memory.peak by $(( (p1-p0)/1024 )) KiB (< 8 MiB)" || no "memory.peak grew $(( (p1-p0)/1024 )) KiB over 5 execs" ;; esac

# 9 run -t / 10 exec -t return (runc#5176)
o=$(to 25 docker run --rm --name dv-tty -t "$IMG" $B echo tty-run-ok 2>&1); case "$o" in *tty-run-ok*) ok "run -t returns" ;; *) no "run -t: [$o]" ;; esac
o=$(to 25 docker exec -t dv-mp $B echo tty-exec-ok 2>&1); case "$o" in *tty-exec-ok*) ok "exec -t returns" ;; *) no "exec -t: [$o]" ;; esac

# 11 docker cp both ways
echo cp-ok > /tmp/dv-cp.in; docker cp /tmp/dv-cp.in dv-mp:/dv-cp.txt >/dev/null 2>&1; docker cp dv-mp:/dv-cp.txt /tmp/dv-cp.out >/dev/null 2>&1
[ "$(cat /tmp/dv-cp.out 2>/dev/null)" = cp-ok ] && ok "docker cp in + out" || no "docker cp"
docker rm -f dv-mp >/dev/null 2>&1

# 12 logs -f streams to the end
docker run -d --name dv-log "$IMG" $B sh -c 'for i in 0 1 2 3 4; do echo line$i; sleep 1; done' >/dev/null 2>&1
o=$(to 15 docker logs -f dv-log 2>&1); case "$o" in *line4*) ok "logs -f streams to the end" ;; *) no "logs -f: [$o]" ;; esac

# 13 healthcheck (exec loop)
docker run -d --name dv-hc --health-cmd "$B true" --health-interval 2s --health-retries 1 "$IMG" $B sleep 600 >/dev/null 2>&1; sleep 15
h=$(docker inspect -f '{{.State.Health.Status}} streak={{.State.Health.FailingStreak}} n={{len .State.Health.Log}}' dv-hc 2>/dev/null)
case "$h" in healthy*streak=0*) ok "healthcheck exec: $h" ;; *) no "healthcheck: [$h]" ;; esac

# 14 pids-limit + stop (SIGTERM -> SIGKILL after the timeout)
id=$(docker run -d --name dv-pl --pids-limit 32 "$IMG" $B sleep 600 2>/dev/null); pl=$(cat /sys/fs/cgroup/docker/$id/pids.max 2>/dev/null)
docker stop -t 2 dv-pl >/dev/null 2>&1; st=$(docker inspect -f '{{.State.Status}}' dv-pl 2>/dev/null)
[ "$pl" = 32 ] && [ "$st" = exited ] && ok "--pids-limit 32 + stop -t 2 (status=$st)" || no "pids-limit/stop: pids.max=[$pl] status=[$st]"

# 15 stop of a detached container
t0=$(date +%s); docker stop -t 3 dv-lc >/dev/null 2>&1; dt=$(( $(date +%s) - t0 ))
st=$(docker inspect -f '{{.State.Status}}' dv-lc 2>/dev/null); [ "$st" = exited ] && ok "stop -t 3 (${dt}s, status=$st)" || no "stop: status=[$st]"

# 16 `runc features` works — dockerd probes it at start; runc 1.1.x lacked it and dockerd logged a failure.
#    Checked directly, not via logread (a RAM ring buffer: the boot line may already be gone = false green).
runc features >/dev/null 2>&1 && ok "runc features (dockerd's runtime probe) answers" || no "runc features failed"

# 17 the dockerd-managed containerd keeps CRI disabled (no CRI socket / plugin on a node)
cfg=/var/run/docker/containerd/containerd.toml; c=$(grep -i 'disabled_plugins' $cfg 2>/dev/null | head -1)
case "$c" in *cri*) ok "containerd disables CRI ($c)" ;; *) no "containerd CRI line: [$c] in $cfg" ;; esac

echo "RESULT pass=$P fail=$F"
