#!/usr/bin/env python3
"""gw-crl-289.py — write a test CRL for cert-reload-289 (#289 M14), run INSIDE an OTS container on the OTS node:
    docker exec -i -e LEG=<expired|future|valid|restore> [-e REVOKE=/tmp/<user>.pem] ots_cot_parser python3 - < this
LEG=expired  lastUpdate now-2d, nextUpdate now-1d (node clock): must be IGNORED by the gateway
LEG=future   lastUpdate now+15 months (a CRL issued with real time on a node whose clock is 2025-07): IGNORED
LEG=valid    lastUpdate now-1h, nextUpdate now+1y, listing REVOKE's serial: HONOURED, that cert refused
LEG=restore  put the original back (saved on the first call to /app/ots/ca/ca.crl.dv289-orig, on the volume)
Signed with the OTS CA key (password from /app/ots/config.yml, never printed). Prints "OK CRL <leg> ..." or FAIL.
"""
import datetime
import os
import re
import shutil

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization

CRL = "/app/ots/ca/ca.crl"
ORIG = CRL + ".dv289-orig"
LEG = os.environ.get("LEG", "")
now = datetime.datetime.now(datetime.timezone.utc)

if LEG == "restore":
    if not os.path.exists(ORIG):
        raise SystemExit("FAIL no saved original %s" % ORIG)
    shutil.copyfile(ORIG, CRL)
    os.remove(ORIG)
    print("OK CRL restore: original back at %s (%d bytes)" % (CRL, os.path.getsize(CRL)))
    raise SystemExit(0)
if LEG not in ("expired", "future", "valid"):
    raise SystemExit("FAIL LEG must be expired|future|valid|restore")
if not os.path.exists(ORIG):
    shutil.copyfile(CRL, ORIG)          # first leg of the run: keep the original on the volume
cfg = open("/app/ots/config.yml").read()
m = re.search(r"^OTS_CA_PASSWORD:\s*['\"]?([^'\"\n]*)", cfg, re.M)
if not m:
    raise SystemExit("FAIL OTS_CA_PASSWORD not found in /app/ots/config.yml")
cak = serialization.load_pem_private_key(open("/app/ots/ca/ca-do-not-share.key", "rb").read(), m.group(1).encode())
cac = x509.load_pem_x509_certificate(open("/app/ots/ca/ca.pem", "rb").read())
if LEG == "expired":
    last, nxt = now - datetime.timedelta(days=2), now - datetime.timedelta(days=1)
elif LEG == "future":
    last, nxt = now + datetime.timedelta(days=456), now + datetime.timedelta(days=456 + 365)
else:
    last, nxt = now - datetime.timedelta(hours=1), now + datetime.timedelta(days=365)
b = x509.CertificateRevocationListBuilder().issuer_name(cac.subject).last_update(last).next_update(nxt)
revoked = ""
if LEG == "valid":
    rev = x509.load_pem_x509_certificate(open(os.environ["REVOKE"], "rb").read())
    b = b.add_revoked_certificate(x509.RevokedCertificateBuilder().serial_number(rev.serial_number)
                                  .revocation_date(now - datetime.timedelta(minutes=5)).build())
    revoked = " revoking serial %x" % rev.serial_number
crl = b.sign(cak, hashes.SHA256())
tmp = CRL + ".dv289-new"
open(tmp, "wb").write(crl.public_bytes(serialization.Encoding.PEM))
os.replace(tmp, CRL)                    # atomic: the gateway sees a complete file or the old one
print("OK CRL %s: lastUpdate %s nextUpdate %s%s -> %s" % (LEG, last.strftime("%Y-%m-%d"), nxt.strftime("%Y-%m-%d"), revoked, CRL))
