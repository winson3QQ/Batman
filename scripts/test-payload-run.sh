#!/bin/sh
# test-payload-run.sh — offline white-box test of payload-run + payload-stop.sh (#274,
# docs/design/274-payload-converge.md). A docker STUB on PATH models containers/images/networks as files,
# records every call, and flags violations (rm -f of a running container, fd 9 leaked to a child). Runs
# on any Linux with sh, flock, sha256sum, awk (CI: payload-manifest-sync). Exit 0 = all pass.
#
# BUSYBOX=1: run everything under busybox applets FIRST on PATH (sh, awk, sed, grep, flock, ...), closer to the
# node (busybox 1.36.1) than a CI runner's GNU tools; any busybox usage error in any output (invalid number /
# unrecognized option / applet not found / syntax error ...) is a FAIL. NOT a replica of the node: Ubuntu's
# busybox is built with different options (e.g. it ACCEPTS `sleep 0.1`; the node's rejects it — the bug in
# #274's first rc, caught only on the node). That class is covered by check 0 (static) and check 14 (the
# grace must really wait >= 1 s), which fail on either busybox.
# shellcheck disable=SC1090,SC2034  # payload-stop.sh is sourced from a computed path; PSTOP_* are read by it
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
PR="$REPO/feed/batman-provision/files/usr/bin/payload-run"
PS="$REPO/feed/batman-provision/files/usr/lib/batman/payload-stop.sh"
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
S="$T/stub"; A="$T/apps"; mkdir -p "$S/c" "$S/img" "$S/net" "$T/bin" "$A/t/secrets" "$T/run"
PASS=0; FAIL=0
ok(){ echo "PASS $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); }

# 0 static (host grep, before PATH changes): node scripts must not use a fractional sleep — the node's
# busybox sleep takes whole seconds only (`sleep 0.1` fails at once, so a "grace" never waits)
fs=$(grep -rnE '(^|[^.[:alnum:]_])sleep +[0-9]*\.[0-9]' "$REPO"/feed/*/files "$REPO"/deploy 2>/dev/null | grep -v '\.py:' | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')
[ -z "$fs" ] && ok "0 no fractional sleep in node scripts (busybox sleep takes whole seconds)" || { no "0 fractional sleep in a node script:"; echo "$fs"; }

BBP=""
if [ "${BUSYBOX:-0}" = 1 ]; then
	bb=$(command -v busybox) || { echo "FAIL BUSYBOX=1 but no busybox on PATH"; exit 1; }
	mkdir -p "$T/bb"; for a in $("$bb" --list); do ln -s "$bb" "$T/bb/$a"; done
	BBP="$T/bb:"; echo "== busybox mode: $("$bb" | head -1)"
fi
export DOCKER_STUB="$S" APPS_DIR="$A" PAYLOAD_RUNDIR="$T/run" PATH="$T/bin:$BBP$PATH"
ALL="$T/all-output"; : > "$ALL"

cat > "$T/bin/docker" <<'STUB'
#!/bin/sh
S=$DOCKER_STUB
echo "$*" >> "$S/calls"
[ -e /proc/$$/fd/9 ] && echo "FD9 leaked into: docker $*" >> "$S/violations"
e(){ echo "$1" | tr '/:' '__'; }
case "$1" in
info) exit 0 ;;
image) [ "$2" = inspect ] || exit 1; shift 2; [ "$1" = -f ] && shift 2; f="$S/img/$(e "$1")"; [ -f "$f" ] || exit 1; cat "$f" ;;
volume) exit 0 ;;
exec) [ -f "$S/fail-health-$2" ] && exit 1; exit 0 ;;
inspect) shift; fmt=""; [ "$1" = -f ] && { fmt=$2; shift 2; }; rc=0
	for n; do d="$S/c/$n"; [ -d "$d" ] || { rc=1; continue; }
		case "$fmt" in
			*batman.cfg*) cat "$d/label" ;;
			*batman.tenant*) cat "$d/tenant" ;;
			*State.Status*) cat "$d/status" ;;
			*State.Running*) [ "$(cat "$d/status")" = running ] && echo true || echo false ;;
			*ExitCode*) echo "/$n=0" ;;
			*) echo "{}" ;;
		esac
	done; exit $rc ;;
start) shift; for n; do [ -f "$S/fail-start-$n" ] && exit 1; [ -d "$S/c/$n" ] || exit 1; echo running > "$S/c/$n/status"; done ;;
stop) shift; [ "$1" = -t ] && shift 2; for n; do [ -d "$S/c/$n" ] && echo exited > "$S/c/$n/status"; done; exit 0 ;;
rm) shift; f=0; [ "$1" = -f ] && { f=1; shift; }
	for n; do d="$S/c/$n"; [ -d "$d" ] || continue
		if [ "$(cat "$d/status")" = running ]; then
			[ "$f" = 1 ] || exit 1
			echo "rm -f of RUNNING $n" >> "$S/violations"
		fi
		rm -rf "$d"; done ;;
ps) t=$(echo "$*" | sed -n 's/.*label=batman.tenant=\([^ ]*\).*/\1/p')
	for d in "$S"/c/*/; do [ -d "$d" ] || continue; [ "$(cat "$d/tenant")" = "$t" ] && basename "$d"; done; exit 0 ;;
network) case "$2" in
	inspect) n=$3; [ -d "$S/net/$n" ] || exit 1
		case "$*" in *bridge.name*) cat "$S/net/$n/bridge" ;; *IPAM*) cat "$S/net/$n/subnet" ;; *Containers*) echo "" ;; esac ;;
	create) sn=""; br=""; for a in "$@"; do case "$p" in --subnet) sn=$a ;; -o) br=${a#*=} ;; esac; p=$a; done
		mkdir -p "$S/net/$a"; echo "$sn" > "$S/net/$a/subnet"; echo "$br" > "$S/net/$a/bridge" ;;
	rm) rm -rf "${S:?}/net/$3" ;;
	esac ;;
run) shift; name=""; cfg=""; ten=""; rmo=0; all="$*"
	while [ $# -gt 0 ]; do case "$1" in --name) name=$2; shift ;; --label) case "$2" in batman.cfg=*) cfg=${2#batman.cfg=} ;; batman.tenant=*) ten=${2#batman.tenant=} ;; esac; shift ;; --rm) rmo=1 ;; esac; shift; done
	[ "$rmo" = 1 ] && exit 0
	[ -d "$S/c/$name" ] && { echo "Conflict: $name exists" >&2; exit 1; }
	mkdir -p "$S/c/$name"; echo "$cfg" > "$S/c/$name/label"; echo "$ten" > "$S/c/$name/tenant"
	echo running > "$S/c/$name/status"; echo "$all" > "$S/c/$name/argv" ;;
esac
exit 0
STUB
chmod +x "$T/bin/docker"

# fixture tenant "t": a stateful service (health, chown volume, relative ro mount, hardening) and a client
# (secret with uid like dummy-nginx-b, absolute mount, stop tier 1)
echo 'sha256:aaa' > "$S/img/img_db_1"; echo 'sha256:bbb' > "$S/img/img_app_1"
echo "abs v1" > "$T/abs.conf"
printf '# test\nHARDEN_FLAGS="--read-only --cap-drop=ALL"\n' > "$A/t/t.hardening.env"
echo "conf v1" > "$A/t/m.conf"
echo "token v1" > "$A/t/secrets/tok"; chmod 0644 "$A/t/secrets/tok"
cat > "$A/t/t.manifest" <<EOF
TENANT t
NETWORK_NAME t-net
BRIDGE br-t
SUBNET 172.29.0.0/24
RESTART unless-stopped

CONTAINER db
IMAGE img/db:1
IP 172.29.0.2
HARDEN t.hardening.env
ENV A=1
VOLUME vd:/data:999:999
MOUNT m.conf:/etc/m.conf:ro
HEALTH true
ENDCONTAINER

CONTAINER app
IMAGE img/app:1
IP 172.29.0.3
HARDEN t.hardening.env
SECRET tok /tok $(id -u)
MOUNT $T/abs.conf:/etc/abs.conf
ENTRYPOINT app --x
STOPTIER 1
ENDCONTAINER
EOF
pr(){ sh "$PR" "$@" >"$T/out" 2>&1; r=$?; cat "$T/out" >> "$ALL"; echo $r; }
calls(){ cat "$S/calls" 2>/dev/null; }
reset_calls(){ : > "$S/calls"; }
h(){ sh "$PR" --cfg-hash t 2>>"$ALL"; }

# 1 fresh rebuild: labels == --cfg-hash, --mount (never -v) for MOUNT, hardening flags parsed in
reset_calls; rc=$(pr t); H=$(h)
[ "$rc" = 0 ] && [ "$(cat "$S/c/db/label")" = "$H" ] && [ "$(cat "$S/c/app/label")" = "$H" ] && [ "$(cat "$S/c/db/tenant")" = t ] \
	&& ok "1 rebuild labels every container with the fingerprint + tenant" || { no "1 rebuild rc=$rc"; cat "$T/out"; }
grep -q -- "--mount type=bind,source=$A/t/m.conf,target=/etc/m.conf,readonly" "$S/c/db/argv" && ! grep -q -- "-v $A/t/m.conf" "$S/c/db/argv" \
	&& ok "1 MOUNT uses --mount (readonly), never -v" || no "1 MOUNT argv: $(cat "$S/c/db/argv")"
grep -q -- "--read-only --cap-drop=ALL" "$S/c/db/argv" && ok "1 HARDEN_FLAGS parsed into the argv" || no "1 hardening not applied"

# 2 secret owner/mode is enforced but NOT fingerprinted (#274 N2: no rebuild loop)
[ "$(stat -c %a "$A/t/secrets/tok")" = 400 ] && [ "$(h)" = "$H" ] && ok "2 secret chmod 0400 enforced; fingerprint unchanged by it" || no "2 secret mode $(stat -c %a "$A/t/secrets/tok") hash changed"
chmod 0644 "$A/t/secrets/tok"; [ "$(h)" = "$H" ] && ok "2 secret mode change does not change the fingerprint" || no "2 secret mode in hash"

# 3 converge with an unchanged stack, all stopped → start mode: start in order, no rm/run/stop
sh "$PR" t >>"$ALL" 2>&1   # (fresh again, labels current)
for c in db app; do echo exited > "$S/c/$c/status"; done
reset_calls; rc=$(pr --converge t)
[ "$rc" = 0 ] && grep -q "start mode" "$T/out" && ! calls | grep -Eq '^(rm|run|stop) ' \
	&& [ "$(calls | grep -n '^start ' | head -1 | cut -d: -f2)" = "start db" ] && [ "$(stat -c %a "$A/t/secrets/tok")" = 400 ] \
	&& ok "3 unchanged stack: start mode, ordered, nothing removed, secret mode re-enforced" || { no "3 rc=$rc"; calls; cat "$T/out"; }

# 4 config change (comment in the manifest; mounted file content) → rebuild; graceful: stop before rm, no rm -f running
echo "# changed" >> "$A/t/t.manifest"; H2=$(h)
[ "$H2" != "$H" ] && ok "4 a manifest comment changes the fingerprint" || no "4 manifest change not in hash"
reset_calls; rc=$(pr --converge t)
[ "$rc" = 0 ] && grep -q "rebuild (cfg" "$T/out" && [ "$(cat "$S/c/db/label")" = "$H2" ] && ok "4 changed config converges by rebuild" || { no "4 rc=$rc"; cat "$T/out"; }
sl=$(calls | grep -n '^stop ' | head -1 | cut -d: -f1); rl=$(calls | grep -n '^rm ' | head -1 | cut -d: -f1)
[ -n "$sl" ] && [ -n "$rl" ] && [ "$sl" -lt "$rl" ] && ! calls | grep -q '^rm -f' && ok "4 rebuild stops before removing, never rm -f" || { no "4 order stop=$sl rm=$rl"; calls; }
echo "conf v2" > "$A/t/m.conf"; [ "$(h)" != "$H2" ] && ok "4 mounted relative file content is in the fingerprint" || no "4 mount content not in hash"
sh "$PR" t >>"$ALL" 2>&1; H3=$(h)
echo "abs v2" > "$T/abs.conf"; [ "$(h)" = "$H3" ] && ok "4 absolute mount source content is NOT in the fingerprint" || no "4 abs content in hash"
chmod u+w "$A/t/secrets/tok"; echo "token v2" > "$A/t/secrets/tok"; [ "$(h)" != "$H3" ] && ok "4 secret content is in the fingerprint" || no "4 secret content not in hash"
sh "$PR" t >>"$ALL" 2>&1; H4=$(h)
echo 'sha256:bbb2' > "$S/img/img_app_1"; [ "$(h)" != "$H4" ] && ok "4 a re-tagged image (new ID) changes the fingerprint" || no "4 image id not in hash"
sh "$PR" t >>"$ALL" 2>&1; H5=$(h)

# 5 start failure → the others are still started, then rebuild
for c in db app; do echo exited > "$S/c/$c/status"; done
: > "$S/fail-start-db"; reset_calls; rc=$(pr --converge t); rm -f "$S/fail-start-db"
calls | grep -q '^start app' && grep -q "converging by rebuild" "$T/out" && [ "$rc" = 0 ] && ok "5 start failure: others started, then rebuild" || { no "5 rc=$rc"; cat "$T/out"; }

# 6 preflight refuses the WHOLE rebuild before anything is touched (missing image / hardening / mount / subnet)
pf(){ reset_calls; rc=$(pr "$@"); if [ "$rc" = 1 ] && grep -q REFUSED "$T/out" && ! calls | grep -Eq '^(stop|rm|run|start) '; then return 0; fi; cat "$T/out"; return 1; }
mv "$S/img/img_db_1" "$T/img.bak"; pf t && ok "6 missing image: refused, nothing touched" || no "6 missing image"; mv "$T/img.bak" "$S/img/img_db_1"
mv "$A/t/t.hardening.env" "$T/h.bak"; pf t && ok "6 missing hardening file: refused (never runs unhardened)" || no "6 missing hardening"; mv "$T/h.bak" "$A/t/t.hardening.env"
printf 'HARDEN_FLAGS="--x"\necho pwned\n' > "$T/h2"; cp "$A/t/t.hardening.env" "$T/h.bak"; cp "$T/h2" "$A/t/t.hardening.env"
pf t && ok "6 hardening file with code: refused (parsed, never sourced)" || no "6 hardening with code"; cp "$T/h.bak" "$A/t/t.hardening.env"
mv "$A/t/m.conf" "$T/m.bak"; pf t && ok "6 missing relative mount source: refused" || no "6 missing mount"; mv "$T/m.bak" "$A/t/m.conf"
echo 172.28.0.0/24 > "$S/net/t-net/subnet"; pf t && grep -q -- "--renet" "$T/out" && ok "6 network subnet mismatch: refused, operator pointed to --renet" || no "6 subnet"
echo 172.29.0.0/24 > "$S/net/t-net/subnet"

# 7 converge refused (config changed, image gone) with the stack stopped → start the OLD stack, exit 1 (DRIFT)
for c in db app; do echo exited > "$S/c/$c/status"; done
echo "# changed again" >> "$A/t/t.manifest"; mv "$S/img/img_app_1" "$T/img.bak"
reset_calls; rc=$(pr --converge t); mv "$T/img.bak" "$S/img/img_app_1"
[ "$rc" = 1 ] && grep -q "OLD config" "$T/out" && [ "$(cat "$S/c/db/status")" = running ] && ! calls | grep -Eq '^(rm|run) ' \
	&& ok "7 converge refused after a clean stop: old stack started, rc 1" || { no "7 rc=$rc"; cat "$T/out"; }

# 8 --start-only: changed config → exit 3, nothing started
for c in db app; do echo exited > "$S/c/$c/status"; done
reset_calls; rc=$(pr --start-only t)
[ "$rc" = 3 ] && ! calls | grep -Eq '^(start|run|rm|stop) ' && ok "8 --start-only on a changed config: rc 3, nothing done" || { no "8 rc=$rc"; calls; }
sh "$PR" t >>"$ALL" 2>&1; for c in db app; do echo exited > "$S/c/$c/status"; done
rc=$(pr --start-only t); [ "$rc" = 0 ] && [ "$(cat "$S/c/app/status")" = running ] && ok "8 --start-only on an unchanged stack starts it" || no "8b rc=$rc"

# 9 orphan: a container labelled for the tenant but no longer in the manifest is removed (graceful)
mkdir -p "$S/c/old"; echo t > "$S/c/old/tenant"; echo x > "$S/c/old/label"; echo running > "$S/c/old/status"
rc=$(pr t); [ "$rc" = 0 ] && [ ! -d "$S/c/old" ] && grep -q "orphan container old" "$T/out" && ok "9 orphan removed by tenant label" || no "9 orphan rc=$rc"

# 10 .stopping is honoured by EVERY mode (#274 P1)
: > "$T/run/batman-payload-t.stopping"
r1=$(pr t); r2=$(pr --converge t); r3=$(pr --start-only t)
[ "$r1$r2$r3" = 444 ] && ok "10 .stopping: rebuild/converge/start-only all exit 4" || no "10 got $r1 $r2 $r3"
rm -f "$T/run/batman-payload-t.stopping"

# 11 lock: a held lock makes payload-run wait, then give up (busybox has no flock -w)
( exec 9>"$T/run/batman-payload-t.lock"; flock 9; sleep 5 ) & lp=$!
held(){ i=0; while ( exec 8>"$T/run/batman-payload-t.lock"; flock -n 8 ) 2>/dev/null; do i=$((i+1)); [ $i -ge 100 ] && return 1; sleep 0.1; done; }
held || no "11 setup: the holder never took the lock in 10 s"
rc=$(PAYLOAD_LOCK_WAIT=2 pr t); kill $lp 2>/dev/null; wait $lp 2>/dev/null
[ "$rc" = 1 ] && grep -q "gave up" "$T/out" && ok "11 lock held: payload-run waits then exits 1" || { no "11 rc=$rc"; cat "$T/out"; }

# 12 no docker child ever inherited fd 9 (the lock dies with the wrapper)
[ -s "$S/violations" ] && { no "12 violations:"; cat "$S/violations"; } || ok "12 no rm -f of a running container, no fd 9 leaked (all runs above)"

# 16 start mode, two phases (D2'): the final-tier service (db) is started AND gated before any other
# container is started; the rest are started after it
sh "$PR" t >>"$ALL" 2>&1; for c in db app; do echo exited > "$S/c/$c/status"; done
reset_calls; rc=$(pr --converge t)
sd=$(calls | grep -n '^start db' | cut -d: -f1); ed=$(calls | grep -n '^exec db' | head -1 | cut -d: -f1); sa=$(calls | grep -n '^start app' | cut -d: -f1)
[ "$rc" = 0 ] && [ -n "$sd" ] && [ -n "$ed" ] && [ -n "$sa" ] && [ "$sd" -lt "$ed" ] && [ "$ed" -lt "$sa" ] \
	&& ok "16 start mode: service started + gated (phase A) before the rest (phase B)" || { no "16 order start-db=$sd gate-db=$ed start-app=$sa rc=$rc"; calls; }

# 17 a phase-A gate failure still starts phase B (no outage by design), rc 1 (DRIFT), nothing removed
for c in db app; do echo exited > "$S/c/$c/status"; done
: > "$S/fail-health-db"; reset_calls; rc=$(PAYLOAD_HEALTH_TRIES=1 pr --converge t); rm -f "$S/fail-health-db"
[ "$rc" = 1 ] && [ "$(cat "$S/c/app/status")" = running ] && ! calls | grep -Eq '^(rm|run) ' \
	&& ok "17 service gate timeout: the rest still started, rc 1, nothing removed" || { no "17 rc=$rc app=$(cat "$S/c/app/status")"; calls; }

# 13 stop: tiers in order (tier 1 first, final tier last), no rm, record written; .stopping set
sh "$PR" t >>"$ALL" 2>&1; reset_calls
( . "$PS"; PSTOP_APPS="$A"; PSTOP_RUN="$T/run"; PSTOP_LOG="$T/stop.log"; pstop_final t ) >>"$ALL" 2>&1
s1=$(calls | grep -n '^stop -t 5 app' | cut -d: -f1); s2=$(calls | grep -n '^stop -t 10 db' | cut -d: -f1)
[ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" -lt "$s2" ] && ! calls | grep -q '^rm ' && [ -e "$T/run/batman-payload-t.stopping" ] \
	&& ok "13 stop: client tier (-t 5) before the final tier (-t 10), no rm, tenant marked stopping" || { no "13 order s1=$s1 s2=$s2"; calls; }
rm -f "$T/run/batman-payload-t.stopping"

# 14 stop kills an in-flight payload-run ONLY if it holds the lock and its cmdline matches (#274 P2)
sleep 30 & sp=$!; echo "$sp" > "$T/run/batman-payload-t.pid"
( . "$PS"; PSTOP_RUN="$T/run"; pstop_kill t ) >>"$ALL" 2>&1
kill -0 "$sp" 2>/dev/null && ok "14 stale pid file (lock free): unrelated process NOT killed" || no "14 killed an unrelated process"
kill "$sp" 2>/dev/null
# a holder that IGNORES TERM: exercises the 1 s grace + KILL path (the sleep that was 0.1 and failed on busybox)
printf '#!/bin/sh\nexec 9>"$PAYLOAD_RUNDIR/batman-payload-t.lock"; flock 9; trap "" TERM; while :; do sleep 1; done\n' > "$T/bin/payload-run"
sh "$T/bin/payload-run" --converge t & fp=$!; held || no "14 setup: the TERM-ignoring holder never took the lock in 10 s"; echo "$fp" > "$T/run/batman-payload-t.pid"
t0=$(date +%s); ( . "$PS"; PSTOP_RUN="$T/run"; pstop_kill t ) >>"$ALL" 2>&1; t1=$(date +%s); sleep 1
if kill -0 "$fp" 2>/dev/null; then no "14 in-flight payload-run not killed"; kill -9 "$fp"
else ok "14 in-flight payload-run (lock held, cmdline matches, ignores TERM) killed after a $((t1 - t0)) s grace"; fi
[ $((t1 - t0)) -ge 1 ] && ok "14 the TERM grace really waited (>= 1 s)" || no "14 no TERM grace (the sleep did not wait)"
rm -f "$T/bin/payload-run"

# 15 busybox mode: no usage error from any applet in any output above
if [ -n "$BBP" ]; then
	e=$(grep -E "invalid number|unrecognized option|invalid option|applet not found|syntax error|bad substitution|unknown operand|^Usage: |^BusyBox v" "$ALL")
	[ -z "$e" ] && ok "15 busybox: no applet usage error in any output" || { no "15 busybox usage errors:"; echo "$e" | head -10; }
fi

echo "== test-payload-run: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
