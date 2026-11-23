#!/bin/bash
# tests/tools/provclient/blackbox.sh [SRC] — provclient's stdout / stderr contract, black-box (254-v16-ud §3.1, §9):
#   1. `provclient node exec /bin/echo x` writes exactly "x\n" to stdout and nothing to stderr (exec's stdout belongs
#      to the program it runs);
#   2. `provclient node sock-as 471 -- proxy <sock>` relays packets byte-identically over a SEQPACKET echo fixture,
#      nothing on stderr (proxy's stdout is its data channel, prov-provd-wbox-254.sh decodes it line by line);
#   3. a helper-socket op (update-status, no helper here) prints exactly "PROVCLIENT caps=uc2,bo2,rk1,pg2,nopsk" on
#      STDERR and nothing of it on stdout.
# SRC = the provclient source dir to build (default: this one). The negative control builds the pre-UD source
# (git archive 4eba26d tests/tools/provclient): it must FAIL case 3. Root only (node mode drops to uid 471 itself);
# Go 1.26: GO, else the go1.26.4 toolchain in the repo owner's module cache, else `go` (GOTOOLCHAIN=local). Prints "provclient-blackbox: N passed, M failed".
set -u
SRC=${1:-$(cd "$(dirname "$0")" && pwd)}
[ "$(id -u)" = 0 ] || { echo "FAIL root only (node mode starts as root and drops to 471)"; echo "provclient-blackbox: 0 passed, 1 failed"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; chmod 755 "$T"
P=0; F=0; ok(){ echo "ok   $*"; P=$((P + 1)); }; no(){ echo "FAIL $*"; F=$((F + 1)); }
OH=$(getent passwd "$(stat -c %U "$(dirname "$0")")" | cut -d: -f6)
TC=$OH/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.26.4.linux-amd64/bin/go
[ -n "${GO:-}" ] || { [ -x "$TC" ] && GO=$TC; } || GO=go
( cd "$SRC" && GOFLAGS=-mod=vendor GOTOOLCHAIN=local GOCACHE=$T/gocache CGO_ENABLED=0 "$GO" build -trimpath -o "$T/pc" . ) > "$T/build.log" 2>&1 \
	|| { no "build of $SRC: $(tail -3 "$T/build.log" | tr '\n' '|')"; echo "provclient-blackbox: $P passed, $F failed"; exit 1; }
chmod 755 "$T/pc"
# 1. exec
"$T/pc" node exec /bin/echo x > "$T/o1" 2> "$T/e1"; rc=$?
if [ $rc = 0 ] && [ "$(od -An -tx1 "$T/o1" | tr -d ' \n')" = 780a ] && [ ! -s "$T/e1" ]; then ok "exec /bin/echo x: stdout exactly 'x\\n', stderr empty"
else no "exec: rc=$rc stdout=[$(od -An -tx1 "$T/o1" | tr -d '\n')] stderr=[$(head -c 200 "$T/e1")]"; fi
# 2. proxy over a SEQPACKET echo server (the fixture socket is 0777 in a 0755 dir: reachable by uid 471)
python3 -I - "$T/s.sock" > "$T/srv.log" 2>&1 <<'PY' &
import os, socket, sys
p = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); s.bind(p); os.chmod(p, 0o777); s.listen(1)
c, _ = s.accept()
while True:
    b = c.recv(65536)
    if not b:
        break
    c.send(b)
c.close(); s.close()
PY
sp=$!
i=0; while [ ! -S "$T/s.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
printf '0102\nff00aa\n%s\n' "$(head -c 300 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$T/in2"
timeout 20 "$T/pc" node sock-as 471 -- proxy "$T/s.sock" < "$T/in2" > "$T/o2" 2> "$T/e2"; rc=$?
wait $sp 2>/dev/null
if [ $rc = 0 ] && cmp -s "$T/in2" "$T/o2" && [ ! -s "$T/e2" ]; then ok "proxy: 3 packets relayed byte-identically, stderr empty"
else no "proxy: rc=$rc cmp=$(cmp "$T/in2" "$T/o2" 2>&1 | head -1) stderr=[$(head -c 200 "$T/e2")] server=[$(head -c 200 "$T/srv.log")]"; fi
# 3. a helper-socket op: caps on stderr only
[ -S /tmp/run/batman-prov/helper.sock ] && no "case 3 needs a host without /tmp/run/batman-prov/helper.sock"
"$T/pc" node update-status 04 > "$T/o3" 2> "$T/e3"; rc=$?
if [ "$(cat "$T/e3")" = "PROVCLIENT caps=uc2,bo2,rk1,pg2,nopsk" ] && ! grep -q PROVCLIENT "$T/o3" && grep -q '^CONN-ERR ' "$T/o3"; then
	ok "helper-socket op: exactly the caps line on stderr, none on stdout (stdout: $(head -1 "$T/o3" | cut -c1-60))"
else no "helper-socket op: rc=$rc stderr=[$(head -c 200 "$T/e3")] stdout=[$(head -c 200 "$T/o3")]"; fi
echo "provclient-blackbox: $P passed, $F failed"; [ $F = 0 ] && [ $P = 3 ]
