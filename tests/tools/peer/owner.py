"""owner — what the provisioning app computes as the node's owner (219-protocol §3.5, §5.4, §5.7, §6), with
python-ecdsa (provd / the helper use Go crypto). Secrets stay in the harness's own 0600 state file on the host.
"""
import hashlib
import json
import os
import pathlib

import ecdsa

import verify

N = ecdsa.NIST256p.order
OTHER_DATA = bytes.fromhex("08000000000000000000000000")


def H(*parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(p)
    return h.digest()


def short(b):
    """How a secret appears in output: the first 16 hex of its SHA-256."""
    return H(b)[:8].hex()


def es256_sign(sk, msg):
    """ES256, raw r‖s, low-s (219 §7.1)."""
    sig = sk.sign_deterministic(msg, hashfunc=hashlib.sha256, sigencode=ecdsa.util.sigencode_string)
    r, s = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
    if s > N // 2:
        s = N - s
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def pub65(sk):
    return b"\x04" + sk.get_verifying_key().to_string()


def ecdh_x(sk, peer65):
    e = ecdsa.ECDH(curve=ecdsa.NIST256p, private_key=sk)
    e.load_received_public_key_bytes(peer65)
    return e.generate_sharedsecret_bytes()


def client_chal(nonce, h, dac_der, owner_pub):
    return H(b"batman-claim-v1", nonce, h, H(dac_der), owner_pub)


def checkmac_response(k, chal, sn):
    """The 608B CheckMac mode 0 layout (219 §5.4), computed in software as the file backend does."""
    od = OTHER_DATA
    return H(k + chal + od[0:4] + bytes(8) + od[4:7] + sn[8:9] + od[7:11] + sn[0:2] + od[11:13])


def owner_op(sk, h, nonce_helper, typ, body):
    """key 31 of an owner-op request (219 §5.7): signed over h, nonce_helper, the type and args_hash."""
    ah = H(verify.det_dumps({k: v for k, v in body.items() if k != 31}))
    return {1: typ, 2: es256_sign(sk, verify.op_input(h, nonce_helper, typ, ah))}


def auth_owner_body(sk, h):
    kid = H(pub65(sk))
    return {1: kid, 2: es256_sign(sk, b"batman-owner-auth-v1" + h + kid)}


def load_key(path):
    return ecdsa.SigningKey.from_pem(pathlib.Path(path).read_text())


def keygen(path):
    sk = ecdsa.SigningKey.generate(curve=ecdsa.NIST256p)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(sk.to_pem().decode())
    return pub65(sk)


# ---- the owner session state (host side, 0600) ----

def save_state(path, st):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(st, f)


def load_state(path):
    return json.loads(pathlib.Path(path).read_text())


def psk_owner(st):
    return verify.hkdf(bytes.fromhex(st["tag_key"]), b"batman-psk-owner-v1" + st["device_id"].encode())


def psk_replay(st, node_ecdh_pub):
    z = ecdh_x(ecdsa.SigningKey.from_pem(st["enc_pem"]), node_ecdh_pub)
    return verify.hkdf(z, b"batman-psk-replay-v1" + st["device_id"].encode())
