"""netobj — the network objects the owner client hands to `network/join` (219-protocol §7; docs/design/254-h4-harness.md
§4.1): net_config (owner-signed COSE_Sign1), member_list, and the per-node net_secrets (COSE_Encrypt to the node's
ECDH key, wrapped in a COSE_Sign1).

Written for the harness, NOT imported from gen.py (gen.py runs every vector at import and keeps NET_ID / NET_VERSION at
module level). The layout follows the node's reader, node/wtxn.go:125-150 + cose.Decrypt (cose.go:193, 201):
  target  = SHA-256(the node's DAC public key, SEC1 65 B)          -> KDF context PartyV
  other   = net_id || u32be(version)                                -> KDF context SuppPubInfo
  AAD     = Enc_structure ["Encrypt", protected, label]             (label = "batman-secrets-v1")
  key     = the node's node_cert key 4 (ecdh_pub), checked against sig_ecdh BEFORE anything is encrypted to it.

`python netobj.py --selftest` rebuilds the vectors' net_config, member_list and net_secrets byte for byte from the
vectors' inputs (the vector keys are derived from their names, gen.py p256()).
"""
import hashlib
import os
import sys

import cbor2
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

LABEL_NETCFG = b"batman-netcfg-v1"
LABEL_MEMBERS = b"batman-members-v1"
LABEL_SECRETS = b"batman-secrets-v1"


def H(b):
    return hashlib.sha256(b).digest()


def u32be(n):
    return n.to_bytes(4, "big")


def _det(o):
    """RFC 8949 §4.2.1 deterministic encoding (map keys sorted by their encoded bytes)."""
    if isinstance(o, dict):
        items = sorted(((cbor2.dumps(_det(k)), _det(k), _det(v)) for k, v in o.items()), key=lambda t: t[0])
        return {k: v for _, k, v in items}
    if isinstance(o, (list, tuple)):
        return [_det(x) for x in o]
    if isinstance(o, cbor2.CBORTag):
        return cbor2.CBORTag(o.tag, _det(o.value))
    return o


def cb(o):
    return cbor2.dumps(_det(o))


def pub65(k):
    pk = k.public_key() if hasattr(k, "public_key") else k
    return pk.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def es256(k, msg):
    """ES256 raw r||s, deterministic (RFC 6979), low-s (219 §7.1)."""
    r, s = decode_dss_signature(k.sign(msg, ec.ECDSA(hashes.SHA256(), deterministic_signing=True)))
    if s > P256_N // 2:
        s = P256_N - s
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def es256_verify(pub, msg, sig):
    if len(sig) != 64:
        return False
    try:
        key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), pub)
        key.verify(encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")),
                   msg, ec.ECDSA(hashes.SHA256()))
        return True
    except Exception:  # noqa: BLE001 — any failure is "does not verify"
        return False


def hkdf(ikm, info, length=32):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=None, info=info).derive(ikm)


def sign1(key, payload, ctype, label):
    protected = cb({1: -7, 3: ctype})
    sig = es256(key, cb(["Signature1", protected, label, payload]))
    return cbor2.dumps(cbor2.CBORTag(18, [protected, {}, payload, sig]), canonical=True)


def object_hash(raw, label):
    prot, _u, payload, _s = cbor2.loads(raw).value
    return H(cb(["Signature1", prot, label, payload]))


def encrypt(plain, label, target_pub65, target_hash, other, eph_key=None, iv=None):
    """COSE_Encrypt (ECDH-ES + HKDF, ChaCha20-Poly1305) to target_pub65 — the node's ecdh_pub."""
    eph_key = eph_key or ec.generate_private_key(ec.SECP256R1())
    iv = iv or os.urandom(12)
    body_prot, rec_prot = cb({1: 24}), cb({1: -25})
    epk = pub65(eph_key)
    target = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), target_pub65)
    z = eph_key.exchange(ec.ECDH(), target)
    ctx = cb([24, [None, None, None], [target_hash, None, None], [256, rec_prot, other]])
    ct = ChaCha20Poly1305(hkdf(z, ctx)).encrypt(iv, plain, cb(["Encrypt", body_prot, label]))
    return cbor2.CBORTag(96, [body_prot, {5: iv}, ct,
                              [[rec_prot, {-1: {1: 2, -1: 1, -2: epk[1:33], -3: epk[33:65]}}, b""]]])


# ---- the objects ----

def net_config(owner_key, net_id, version, prev_hash, name, country, mesh_id, channel, bw, admins):
    """net_config v<version>; admins = owner public keys (key 8) — net_secrets' signer must be one of them."""
    payload = cb({1: net_id, 2: version, 3: prev_hash, 4: name, 5: country,
                  6: {1: mesh_id, 2: channel, 3: bw}, 8: list(admins)})
    return sign1(owner_key, payload, "batman/netcfg", LABEL_NETCFG)


def member_list(owner_key, net_id, version, prev_hash, members):
    """members = [{1: dac_pub_hash, 2: ecdh_pub, 3: name, 4: owner_sign_pub, 5: owner_enc_pub}, ...]"""
    payload = cb({1: net_id, 2: version, 3: prev_hash, 4: list(members), 5: [], 6: [], 7: []})
    return sign1(owner_key, payload, "batman/members", LABEL_MEMBERS)


def net_secrets(owner_key, net_id, version, dac_pub65, ecdh_pub65, plain, eph_key=None, iv=None):
    """plain = cb({1: SAE key, 2: net_root, ...}); encrypted for ONE node (its DAC hash + its ecdh_pub)."""
    target = H(dac_pub65)
    enc = encrypt(plain, LABEL_SECRETS, ecdh_pub65, target, net_id + u32be(version), eph_key, iv)
    return sign1(owner_key, cb({1: net_id, 2: version, 3: target, 4: enc}), "batman/secrets", LABEL_SECRETS)


def ecdh_pub_from_cert(cert, dac_pub65):
    """node_cert key 4, only after sig_ecdh (key 6) verifies under the node's DAC (219 §3.3) — never encrypt to an
    ecdh key the DAC did not sign."""
    ecdh_pub = cert[4]
    if not es256_verify(dac_pub65, b"batman-node-ecdh-v1" + ecdh_pub, cert[6]):
        raise ValueError("sig_ecdh does not verify under the pinned DAC: refusing to encrypt to this key")
    return ecdh_pub


def psk_member(net_root, net_id, version):
    return hkdf(net_root, b"batman-psk-member-v1" + net_id + u32be(version))


# ---- selftest against tests/vectors/219-protocol/vectors.json ----

def _vector_key(name):
    d = int.from_bytes(H(b"batman-test-vector/" + name.encode()), "big") % (P256_N - 1) + 1
    return ec.derive_private_key(d, ec.SECP256R1())


def _seed(name):
    return H(b"batman-test-vector/" + name.encode())


def selftest(path=None):
    import json
    import pathlib
    p = pathlib.Path(path or pathlib.Path(__file__).resolve().parents[2] / "vectors" / "219-protocol" / "vectors.json")
    v = json.loads(p.read_text())
    k, cose = v["keys"], v["cose"]
    fails, n = [], 0

    def check(name, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(name)

    admin = _vector_key("admin")
    check("admin key = vectors", pub65(admin).hex() == k["admin_pub"])
    net_id, ver = bytes.fromhex(k["net_id"]), 1
    dac_pub, ecdh_pub = bytes.fromhex(k["dac_pub"]), bytes.fromhex(k["node_ecdh_pub"])

    cfg = net_config(admin, net_id, ver, None, "家裡網路", "TW", "batman-test", 40, 4, [pub65(admin)])
    check("net_config payload", cbor2.loads(cfg).value[2].hex() == cose["net_config"]["payload"])
    check("net_config sign1 byte for byte", cfg.hex() == cose["net_config"]["sign1"])

    ml = member_list(admin, net_id, ver, None, [{1: H(dac_pub), 2: ecdh_pub, 3: "客廳",
                                                 4: bytes.fromhex(k["owner_sign_pub"]),
                                                 5: bytes.fromhex(k["owner_enc_pub"])}])
    check("member_list sign1 byte for byte", ml.hex() == cose["member_list"]["sign1"])

    plain = bytes.fromhex(cose["net_secrets"]["plaintext"])
    sec = net_secrets(admin, net_id, ver, dac_pub, ecdh_pub, plain,
                      eph_key=_vector_key("cose-ephemeral"), iv=_seed("iv-secrets")[:12])
    check("net_secrets sign1 byte for byte", sec.hex() == cose["net_secrets"]["sign1"])
    inner = cbor2.loads(cbor2.loads(sec).value[2])
    check("net_secrets target = SHA-256(DAC pub)", inner[3] == H(dac_pub))

    # negative: encrypting to the wrong key (the node's DAC key, or anything that is not ecdh_pub) must differ
    wrong = net_secrets(admin, net_id, ver, dac_pub, dac_pub, plain,
                        eph_key=_vector_key("cose-ephemeral"), iv=_seed("iv-secrets")[:12])
    check("negative: encrypted to a non-ecdh key -> differs from the vector", wrong.hex() != cose["net_secrets"]["sign1"])
    # negative: other (net_id||version) is bound — another version must not reproduce the vector
    wrong_v = net_secrets(admin, net_id, ver + 1, dac_pub, ecdh_pub, plain,
                          eph_key=_vector_key("cose-ephemeral"), iv=_seed("iv-secrets")[:12])
    check("negative: version is bound into the object", wrong_v.hex() != cose["net_secrets"]["sign1"])

    cert = cbor2.loads(bytes.fromhex(v["node_cert"]["cbor"]))
    check("ecdh_pub_from_cert accepts the vector cert", ecdh_pub_from_cert(cert, dac_pub) == ecdh_pub)
    bad = dict(cert)
    bad[4] = pub65(_vector_key("cose-ephemeral"))
    try:
        ecdh_pub_from_cert(bad, dac_pub)
        check("negative: a swapped ecdh_pub is refused", False)
    except ValueError:
        check("negative: a swapped ecdh_pub is refused", True)

    check("psk_member = vectors.hkdf", psk_member(bytes.fromhex(k["net_root"]), net_id, ver).hex()
          == v["hkdf"]["psk_member"])

    for f in fails:
        print("FAIL netobj selftest:", f)
    print("netobj selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:2] == ["--selftest"] else 2)
