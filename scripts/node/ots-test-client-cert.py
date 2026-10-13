#!/usr/bin/env python3
"""ots-test-client-cert.py — issue a short-lived OTS client certificate for the 8089 (SSL) CoT test (#264).

Runs INSIDE an OTS container (python3 + cryptography; /app/ots = the ots-appdata volume):
    docker exec -i ots_cot_parser python3 - < ots-test-client-cert.py
Writes /tmp/dv-client.pem + /tmp/dv-client.key in the CONTAINER's tmpfs (gone on restart; the harness
deletes them right after the test). CN = an existing OTS user (default 'administrator'; the SSL handler maps
the certificate CN to a user and drops unknown ones), EKU clientAuth, valid 1 day, signed by the OTS CA.
The CA key password is read from /app/ots/config.yml here and never printed.
"""
import datetime
import os
import re

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

CN = os.environ.get("CN", "administrator")
cfg = open("/app/ots/config.yml").read()
m = re.search(r"^OTS_CA_PASSWORD:\s*['\"]?([^'\"\n]*)", cfg, re.M)
if not m:
    raise SystemExit("FAIL OTS_CA_PASSWORD not found in /app/ots/config.yml")
cak = serialization.load_pem_private_key(open("/app/ots/ca/ca-do-not-share.key", "rb").read(), m.group(1).encode())
cac = x509.load_pem_x509_certificate(open("/app/ots/ca/ca.pem", "rb").read())
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, CN)]))
        .issuer_name(cac.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), critical=False)
        .sign(cak, hashes.SHA256()))
old = os.umask(0o077)
open("/tmp/dv-client.pem", "wb").write(cert.public_bytes(serialization.Encoding.PEM))
open("/tmp/dv-client.key", "wb").write(key.private_bytes(serialization.Encoding.PEM,
                                                         serialization.PrivateFormat.TraditionalOpenSSL,
                                                         serialization.NoEncryption()))
os.umask(old)
print("OK test client cert CN=%s, 1 day, container /tmp/dv-client.{pem,key}" % CN)
