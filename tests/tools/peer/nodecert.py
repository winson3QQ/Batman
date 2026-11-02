"""nodecert — check the node_cert carried in Noise msg2 (219-protocol §3.3) and decide whether this connection reached
the node the harness meant to reach (docs/design/254-h4-harness.md §4.2).

Every arm checks the node_cert of ITS OWN handshake before it sends any request: the Noise static key s_node is new
at every provd start (memory only, F-H45), so a stored key can never identify a node — the DAC can.

  identify(cert, rs, pinned_dac_der)            -> device_id (hex) or raises NotTarget
    1. dac_chain[0] == pinned_dac_der           (psk_member is shared by every member: only the DAC tells them apart)
    2. sig_static = ES256_DAC("batman-node-static-v1" || rs || boot_id) and cert[2] == rs (rs = the remote static
       of THIS handshake)
    3. sn (key 7) == the DAC's subject serialNumber; device_id = hex(sn)
  first_contact(cert, rs, expected_device_id)   -> DAC DER to pin (the unclaimed / provisioning path, §3.1 step 3-4)
    a dev (file backend) DAC must be self-signed with CN "dev:<device_id>" AND device_id == hex(SHA-256(pub)[:9]);
    the device_id must equal the one read over ssh from the node (identity/sn).
"""
import hashlib
import sys

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import netobj


class NotTarget(Exception):
    """This connection did not reach the intended node (or the node_cert does not hold together)."""


def _dac_pub65(der):
    c = x509.load_der_x509_certificate(der)
    return c, c.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def _attr(c, oid):
    a = c.subject.get_attributes_for_oid(oid)
    return a[0].value if a else None


def _common(cert, rs):
    """Checks that do not depend on which node was wanted; returns (dac_der, device_id)."""
    if not isinstance(cert, dict) or not isinstance(cert.get(1), list) or not cert[1]:
        raise NotTarget("no node_cert / no DAC chain (fake path?)")
    dac_der = cert[1][0]
    c, pub = _dac_pub65(dac_der)
    if cert.get(2) != rs:
        raise NotTarget("node_cert key 2 is not the remote static of this handshake")
    if not netobj.es256_verify(pub, b"batman-node-static-v1" + rs + cert.get(3, b""), cert.get(5, b"")):
        raise NotTarget("sig_static does not verify under the DAC for this handshake's s_node / boot_id")
    sn = cert.get(7, b"")
    if _attr(c, x509.oid.NameOID.SERIAL_NUMBER) != sn.hex():
        raise NotTarget("sn does not match the DAC serialNumber")
    return dac_der, sn.hex()


def identify(cert, rs, pinned_dac_der):
    dac_der, device_id = _common(cert, rs)
    if dac_der != pinned_dac_der:
        raise NotTarget("DAC is not the pinned target (device %s)" % device_id)
    return device_id


def first_contact(cert, rs, expected_device_id):
    dac_der, device_id = _common(cert, rs)
    c, pub = _dac_pub65(dac_der)
    if device_id != expected_device_id:
        raise NotTarget("device_id %s is not the node read over ssh (%s)" % (device_id, expected_device_id))
    cn = _attr(c, x509.oid.NameOID.COMMON_NAME) or ""
    if cn.startswith("dev:"):
        if cn != "dev:" + device_id or hashlib.sha256(pub).digest()[:9].hex() != device_id:
            raise NotTarget("dev DAC: device_id is not SHA-256(DAC pub)[:9] (a forged self-signed cert)")
        try:
            c.public_key().verify(c.signature, c.tbs_certificate_bytes, ec.ECDSA(c.signature_hash_algorithm))
        except Exception:  # noqa: BLE001
            raise NotTarget("dev DAC is not self-signed") from None
    else:
        raise NotTarget("a production DAC needs the root chain (not used on the bench)")
    return dac_der


def selftest(path=None):
    import json
    import pathlib
    import cbor2
    p = pathlib.Path(path or pathlib.Path(__file__).resolve().parents[2] / "vectors" / "219-protocol" / "vectors.json")
    v = json.loads(p.read_text())
    k = v["keys"]
    cert = cbor2.loads(bytes.fromhex(v["node_cert"]["cbor"]))
    rs = bytes.fromhex(k["s_node_pub"])
    dac = bytes.fromhex(k["dac_cert_der"])
    fails, n = [], 0

    def check(name, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(name)

    def raises(fn):
        try:
            fn()
            return False
        except NotTarget:
            return True

    check("identify: the vector node_cert with its DAC pinned", identify(cert, rs, dac) == k["device_id"])
    check("negative: another pinned DAC -> NotTarget", raises(lambda: identify(cert, rs, bytes.fromhex(v["identity_file"]["dev_cert_der"]))))
    check("negative: rs of another handshake -> NotTarget", raises(lambda: identify(cert, bytes(32), dac)))
    bad = dict(cert)
    bad[3] = bytes(16)
    check("negative: boot_id changed -> sig_static fails", raises(lambda: identify(bad, rs, dac)))
    bad = dict(cert)
    bad[7] = bytes(9)
    check("negative: sn not the DAC's -> NotTarget", raises(lambda: identify(bad, rs, dac)))
    check("negative: fake path (msg2 that is not a node_cert) -> NotTarget", raises(lambda: identify(None, rs, dac)))

    # first contact with a dev DAC: build a node_cert around the vectors' identity_file dev cert is not possible
    # (no private key in the vectors), so the dev rule is checked on the certificate itself
    idf = v["identity_file"]
    devc = x509.load_der_x509_certificate(bytes.fromhex(idf["dev_cert_der"]))
    _, dpub = _dac_pub65(bytes.fromhex(idf["dev_cert_der"]))
    check("dev rule holds for the genuine dev cert", hashlib.sha256(dpub).digest()[:9].hex() == idf["device_id"]
          and _attr(devc, x509.oid.NameOID.COMMON_NAME) == "dev:" + idf["device_id"])
    _, fpub = _dac_pub65(bytes.fromhex(idf["forged_dev_cert_der"]))
    check("negative: dev rule fails for the forged dev cert", hashlib.sha256(fpub).digest()[:9].hex() != idf["device_id"])
    check("negative: first_contact refuses a production DAC without the root chain",
          raises(lambda: first_contact(cert, rs, k["device_id"])))
    check("negative: first_contact refuses another device_id", raises(lambda: first_contact(cert, rs, "00" * 9)))

    for f in fails:
        print("FAIL nodecert selftest:", f)
    print("nodecert selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:2] == ["--selftest"] else 2)
