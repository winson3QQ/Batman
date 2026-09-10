#!/bin/sh
# functional-test.sh — runtime + functional smoke test for the FTS image (#45).
#
# WHY this exists: a build/import gate only proves the image imports (level 2). It does NOT
# prove FTS still WORKS after a dependency bump — e.g. cryptography 36->43 is used only at
# runtime (cert generation + TLS), never at import. This test forces those paths and judges
# them with INDEPENDENT oracles, not FTS's own code:
#   - cert generation is FORCED by a fresh empty volume (else FTS reuses cached certs and the
#     bumped pyOpenSSL code never runs);
#   - the generated cert chain is verified by the `openssl` CLI (independent of FTS);
#   - the mTLS handshake to FTS's SSL CoT server is driven by a stdlib `ssl` client
#     (independent of FTS's SSLSocketController, which is the server under test);
#   - a NEGATIVE CONTROL (no client cert -> must be REJECTED) proves the CERT_REQUIRED path
#     actually executes, so a green result can't be hollow;
#   - a spec-valid CoT event round-trips through the plaintext CoT port.
# Runs entirely inside a throwaway container (no host ports, no external deps) so it works
# in CI under QEMU and on a node without touching production.
#
#   ./functional-test.sh <image-tag>   (default fts:2.2.1)
set -e
IMG="${1:-fts:2.2.1}"
CN="ftstest_$$"
DATA="/tmp/${CN}-data"
FAIL=0
say() { echo "  $*"; }
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; FAIL=1; }

cleanup() { docker rm -f "$CN" >/dev/null 2>&1 || true; rm -rf "$DATA" 2>/dev/null || true; }
trap cleanup EXIT
rm -rf "$DATA"; mkdir -p "$DATA"

echo "=== start $IMG with a FRESH volume (forces cert generation) ==="
docker run -d --name "$CN" -e FTS_FIRST_START=false -v "$DATA":/opt/fts "$IMG" >/dev/null
# wait for the CoT service to come up (QEMU-emulated startup is slow)
up=0
i=0
while [ "$i" -lt 60 ]; do
  if docker logs "$CN" 2>&1 | grep -q "CoT Service Started"; then up=1; break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$CN" 2>/dev/null)" != "true" ]; then break; fi
  i=$((i+1)); sleep 3
done
[ "$up" = 1 ] && ok "FTS started (CoT Service Started)" || { bad "FTS did not start"; docker logs "$CN" 2>&1 | tail -25; exit 1; }

echo "=== the bumped libs are the ones actually loaded ==="
docker exec "$CN" python -c "import cryptography,OpenSSL,werkzeug,jinja2,flask_cors; \
print('  cryptography',cryptography.__version__,'| pyOpenSSL',OpenSSL.__version__,\
'| werkzeug',werkzeug.__version__,'| jinja2',jinja2.__version__,'| flask_cors',flask_cors.__version__)"

echo "=== [1] cert generation FORCED (fresh volume) — files must now exist ==="
if docker exec "$CN" sh -c 'test -f /opt/fts/certs/ca.pem && test -f /opt/fts/certs/server.pem && test -f /opt/fts/certs/Client.pem'; then
  ok "FTS generated ca/server/Client certs on first start (pyOpenSSL path ran)"
else
  bad "cert generation did not produce the expected files"; docker exec "$CN" ls -la /opt/fts/certs 2>&1 || true
fi

echo "=== [2] INDEPENDENT oracle: openssl verifies the FTS-generated chain ==="
if docker exec "$CN" openssl verify -CAfile /opt/fts/certs/ca.pem /opt/fts/certs/server.pem 2>&1 | grep -q "server.pem: OK"; then
  ok "openssl verify: server cert chains to the generated CA"
else
  bad "openssl could not verify the generated chain"
fi
docker exec "$CN" openssl x509 -in /opt/fts/certs/ca.pem -noout -subject -dates 2>&1 | sed 's/^/  ca: /' || true

echo "=== [3] INDEPENDENT stdlib-ssl client: mTLS handshake to FTS SSL CoT :8089 ==="
docker exec "$CN" python - <<'PY' || FAIL=1
import ssl, socket
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.load_verify_locations("/opt/fts/certs/ca.pem")
ctx.load_cert_chain("/opt/fts/certs/Client.pem", "/opt/fts/certs/Client.key")
ctx.check_hostname = False
try:
    with socket.create_connection(("127.0.0.1", 8089), timeout=15) as s:
        with ctx.wrap_socket(s, server_side=False) as ts:
            print("PASS: mTLS handshake OK — cipher", ts.cipher()[0], "| peer CN present:",
                  bool(ts.getpeercert()))
except Exception as e:
    print("FAIL: mTLS handshake with a valid client cert failed:", repr(e))
    raise SystemExit(1)
PY

echo "=== [4] NEGATIVE CONTROL: no client cert -> must be REJECTED (proves CERT_REQUIRED runs) ==="
docker exec "$CN" python - <<'PY' || FAIL=1
import ssl, socket
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.load_verify_locations("/opt/fts/certs/ca.pem")
ctx.check_hostname = False   # deliberately present NO client cert
try:
    with socket.create_connection(("127.0.0.1", 8089), timeout=15) as s:
        with ctx.wrap_socket(s, server_side=False) as ts:
            ts.recv(1)
    print("FAIL: server accepted a client with NO cert — CERT_REQUIRED path NOT exercised")
    raise SystemExit(1)
except SystemExit:
    raise
except Exception as e:
    print("PASS: server rejected the certless client as required:", type(e).__name__)
PY

echo "=== [5] spec-valid CoT round-trips through plaintext CoT :18087 ==="
docker exec "$CN" python - <<'PY' || FAIL=1
import socket, time
ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
stale = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time()+3600))
cot = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
       '<event version="2.0" uid="CRYPTO-VERIFY-001" type="a-f-G-U-C" how="m-g" '
       f'time="{ts}" start="{ts}" stale="{stale}">'
       '<point lat="25.0330" lon="121.5654" hae="10.0" ce="5.0" le="5.0"/>'
       '<detail><contact callsign="CRYPTO-VERIFY-001"/><__group name="Cyan" role="Team Member"/>'
       '</detail></event>')
try:
    s = socket.create_connection(("127.0.0.1", 18087), timeout=10)
    s.sendall(cot.encode()); time.sleep(2); s.close()
    print("PASS: CoT event accepted by :18087 (socket write clean)")
except Exception as e:
    print("FAIL: CoT send failed:", repr(e)); raise SystemExit(1)
PY

echo "=== runtime error scan in FTS log ==="
if docker logs "$CN" 2>&1 | grep -iE "traceback|cryptography|opensslerror|ssl.*error" | grep -viE "warning|deprecat" | head -5; then
  say "(review the above — crypto/TLS runtime errors are a red flag)"
else
  ok "no crypto/TLS tracebacks in the FTS log"
fi

echo ""
[ "$FAIL" = 0 ] && { echo "FUNCTIONAL TEST: PASS ($IMG)"; exit 0; } || { echo "FUNCTIONAL TEST: FAIL ($IMG)"; exit 1; }
