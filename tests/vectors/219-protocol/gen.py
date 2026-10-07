#!/usr/bin/env python3
"""Generate test vectors for docs/design/219-protocol.md (v0.6).

Everything is deterministic: keys are derived from fixed seeds and every ECDSA
signature uses RFC 6979 (deterministic_signing=True), so running this script
again produces byte-identical output.

    python gen.py > vectors.json

Requires: cryptography >= 44, cbor2, noiseprotocol (see requirements.txt).
These vectors use the PRODUCTION labels and prologue; they are not secrets
and must never be used as real keys.
"""
import hashlib
import json
import sys

import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, x25519
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.x509.oid import NameOID
import datetime
from noise.connection import Keypair, NoiseConnection

P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


# ------------------------------------------------------------------ helpers
def H(b: bytes) -> bytes:
    return hashlib.sha256(b).digest()


def seed(name: str) -> bytes:
    return H(b"batman-test-vector/" + name.encode())


def p256(name: str) -> ec.EllipticCurvePrivateKey:
    d = int.from_bytes(seed(name), "big") % (P256_N - 1) + 1
    return ec.derive_private_key(d, ec.SECP256R1())


def pub65(k) -> bytes:
    pk = k.public_key() if hasattr(k, "public_key") else k
    return pk.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def es256(k: ec.EllipticCurvePrivateKey, msg: bytes) -> bytes:
    der = k.sign(msg, ec.ECDSA(hashes.SHA256(), deterministic_signing=True))
    r, s = decode_dss_signature(der)
    if s > P256_N // 2:          # low-s (§7.1): high-s signatures are rejected by receivers
        s = P256_N - s
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def x25519_key(name: str):
    sk = x25519.X25519PrivateKey.from_private_bytes(seed(name))
    raw_sk = sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                              serialization.NoEncryption())
    raw_pk = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return raw_sk, raw_pk


def hkdf(ikm: bytes, info: bytes, length: int = 32) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=None, info=info).derive(ikm)


def cb(obj) -> bytes:
    """Deterministic CBOR (all maps in this protocol use small integer keys)."""
    return cbor2.dumps(obj, canonical=True)


def item(raw: bytes):
    """Embed an already-encoded COSE object as a nested CBOR item (not as a bstr)."""
    return cbor2.loads(raw)


def hx(b: bytes) -> str:
    return b.hex()


def u32be(n: int) -> bytes:
    return n.to_bytes(4, "big")


# ------------------------------------------------------------------ fixed inputs
DEVICE_ID = "BATMAN-TEST01"
SN = bytes.fromhex("0123a5f0c3e1b74dee")          # 608B serial (9 B): 01 23 .. EE like a real ATECC608; synthetic (#267: must not contain the lab-key literal the leak canary blocks)
BOOT_ID = seed("boot_id")[:16]
NET_ID = seed("net_id")[:16]
NET_VERSION = 1
CLAIM_SECRET = seed("claim_secret")
OWNER_TAG_KEY = seed("owner_tag_key")
ADV_OWNER_KEY = seed("adv_owner_key")
NET_ROOT = seed("net_root")
OTHER_DATA = bytes([0x08, 0, 0, 0]) + bytes(9)   # §5.4, 13 B

root_key = p256("dev-root-ca")
dac_key = p256("dac")
node_ecdh = p256("node-ecdh")
owner_sign = p256("owner-sign")
owner_enc = p256("owner-enc")
admin_key = p256("admin")
cose_eph = p256("cose-ephemeral")
cose_eph_member = p256("cose-ephemeral-member")

s_node_sk, s_node_pk = x25519_key("s_node")
phone_e_sk, phone_e_pk = x25519_key("phone-ephemeral")
node_e_sk, node_e_pk = x25519_key("node-ephemeral")
fake_e_sk, fake_e_pk = x25519_key("fake-ephemeral")

out = {"meta": {
    "spec": "docs/design/219-protocol.md v0.6",
    "note": "Deterministic test vectors. Keys derive from SHA-256('batman-test-vector/' + name). Not real keys.",
}}

# ------------------------------------------------------------------ certificates (DER)
T0 = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
T1 = datetime.datetime(2046, 1, 1, tzinfo=datetime.timezone.utc)
root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Batman Test Root")])
root_cert = (x509.CertificateBuilder()
             .subject_name(root_name).issuer_name(root_name)
             .public_key(root_key.public_key()).serial_number(1)
             .not_valid_before(T0).not_valid_after(T1)
             .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
             .sign(root_key, hashes.SHA256(), ecdsa_deterministic=True))
dac_cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([
                x509.NameAttribute(NameOID.COMMON_NAME, DEVICE_ID),
                x509.NameAttribute(NameOID.SERIAL_NUMBER, SN.hex()),
            ]))
            .issuer_name(root_name)
            .public_key(dac_key.public_key()).serial_number(2)
            .not_valid_before(T0).not_valid_after(T1)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .sign(root_key, hashes.SHA256(), ecdsa_deterministic=True))
ROOT_DER = root_cert.public_bytes(serialization.Encoding.DER)
DAC_DER = dac_cert.public_bytes(serialization.Encoding.DER)
DAC_PUB = pub65(dac_key)
DAC_PUB_HASH = H(DAC_PUB)

out["keys"] = {
    "root_ca_cert_der": hx(ROOT_DER),
    "dac_cert_der": hx(DAC_DER),
    "dac_pub": hx(DAC_PUB),
    "dac_pub_hash": hx(DAC_PUB_HASH),
    "node_ecdh_pub": hx(pub65(node_ecdh)),
    "owner_sign_pub": hx(pub65(owner_sign)),
    "owner_enc_pub": hx(pub65(owner_enc)),
    "admin_pub": hx(pub65(admin_key)),
    "s_node_priv": hx(s_node_sk), "s_node_pub": hx(s_node_pk),
    "phone_ephemeral_priv": hx(phone_e_sk), "phone_ephemeral_pub": hx(phone_e_pk),
    "node_ephemeral_priv": hx(node_e_sk), "node_ephemeral_pub": hx(node_e_pk),
    "claim_secret": hx(CLAIM_SECRET),
    "owner_tag_key": hx(OWNER_TAG_KEY),
    "adv_owner_key": hx(ADV_OWNER_KEY),
    "net_root": hx(NET_ROOT),
    "net_id": hx(NET_ID),
    "sn": hx(SN),
    "boot_id": hx(BOOT_ID),
    "device_id": DEVICE_ID,
    "p256_private_scalars_note": "d = (int(SHA-256('batman-test-vector/'+name)) mod (n-1)) + 1 for names "
                                 "dev-root-ca, dac, node-ecdh, owner-sign, owner-enc, admin, cose-ephemeral, "
                                 "cose-ephemeral-member",
}

# ------------------------------------------------------------------ node_cert (§3.3)
sig_static = es256(dac_key, b"batman-node-static-v1" + s_node_pk + BOOT_ID)
sig_ecdh = es256(dac_key, b"batman-node-ecdh-v1" + pub65(node_ecdh))
node_cert = {1: [DAC_DER], 2: s_node_pk, 3: BOOT_ID, 4: pub65(node_ecdh),
             5: sig_static, 6: sig_ecdh, 7: SN}
NODE_CERT = cb(node_cert)
out["node_cert"] = {
    "sig_static_input": hx(b"batman-node-static-v1" + s_node_pk + BOOT_ID),
    "sig_static": hx(sig_static),
    "sig_ecdh_input": hx(b"batman-node-ecdh-v1" + pub65(node_ecdh)),
    "sig_ecdh": hx(sig_ecdh),
    "cbor": hx(NODE_CERT),
}

# ------------------------------------------------------------------ HKDF (§6)
PSK_OWNER = hkdf(OWNER_TAG_KEY, b"batman-psk-owner-v1" + DEVICE_ID.encode())
PSK_MEMBER = hkdf(NET_ROOT, b"batman-psk-member-v1" + NET_ID + u32be(NET_VERSION))
ADV_OWNER = hkdf(ADV_OWNER_KEY, b"batman-adv-owner-v1" + DEVICE_ID.encode())
ADV_MEMBER = hkdf(NET_ROOT, b"batman-adv-member-v1" + NET_ID + u32be(NET_VERSION))
out["hkdf"] = {
    "psk_owner": hx(PSK_OWNER), "psk_member": hx(PSK_MEMBER),
    "adv_owner": hx(ADV_OWNER), "adv_member": hx(ADV_MEMBER),
    "note": "HKDF-SHA256, salt empty, L = 32; info = label || fields (device_id ASCII, last)",
}


# ------------------------------------------------------------------ Noise (§3)
def noise_run(name: bytes, prologue: bytes, psk: bytes | None, payload2: bytes, first_request: bytes):
    ini = NoiseConnection.from_name(name)
    res = NoiseConnection.from_name(name)
    ini.set_as_initiator()
    res.set_as_responder()
    for c in (ini, res):
        c.set_prologue(prologue)
        if psk is not None:
            c.set_psks(psk)
    ini.set_keypair_from_private_bytes(Keypair.EPHEMERAL, phone_e_sk)
    res.set_keypair_from_private_bytes(Keypair.STATIC, s_node_sk)
    res.set_keypair_from_private_bytes(Keypair.EPHEMERAL, node_e_sk)
    ini.start_handshake()
    res.start_handshake()
    m1 = ini.write_message(b"")
    res.read_message(m1)
    m2 = res.write_message(payload2)
    p2 = ini.read_message(m2)
    assert p2 == payload2 and ini.handshake_finished and res.handshake_finished
    h = ini.get_handshake_hash()
    assert h == res.get_handshake_hash()
    t1 = ini.encrypt(first_request)
    assert res.decrypt(t1) == first_request
    return m1, m2, h, t1


PROLOGUE_UNCLAIMED = b"batman-prov/1\x00ble\x00" + DEVICE_ID.encode()
PROLOGUE_CLAIMED = b"batman-prov/1\x00ble\x00"
REQ_INFO = cb({0: [1, 0], 1: 1, 2: "info", 3: {}})

m1, m2, H_NX, t1 = noise_run(b"Noise_NX_25519_ChaChaPoly_SHA256", PROLOGUE_UNCLAIMED, None, NODE_CERT, REQ_INFO)
out["noise_nx"] = {
    "protocol": "Noise_NX_25519_ChaChaPoly_SHA256",
    "prologue": hx(PROLOGUE_UNCLAIMED),
    "msg1": hx(m1), "msg2": hx(m2),
    "msg2_payload": "node_cert.cbor",
    "handshake_hash": hx(H_NX),
    "first_transport_plaintext": hx(REQ_INFO),
    "first_transport_message": hx(t1),
}

m1p, m2p, H_PSK, t1p = noise_run(b"Noise_NXpsk0_25519_ChaChaPoly_SHA256", PROLOGUE_CLAIMED, PSK_OWNER,
                                 NODE_CERT, REQ_INFO)
out["noise_nxpsk0_owner"] = {
    "protocol": "Noise_NXpsk0_25519_ChaChaPoly_SHA256",
    "prologue": hx(PROLOGUE_CLAIMED),
    "psk": "hkdf.psk_owner",
    "msg1": hx(m1p), "msg2": hx(m2p),
    "handshake_hash": hx(H_PSK),
    "first_transport_message": hx(t1p),
}

# ------------------------------------------------------------------ owner auth / claim / peer (§3.5, §5.4)
OWNER_KEY_ID = H(pub65(owner_sign))
auth_input = b"batman-owner-auth-v1" + H_PSK + OWNER_KEY_ID
out["auth_owner"] = {"owner_key_id": hx(OWNER_KEY_ID), "input": hx(auth_input),
                     "sig": hx(es256(owner_sign, auth_input)), "uses": "noise_nxpsk0_owner.handshake_hash"}

CLAIM_NONCE = seed("claim-nonce")
client_chal = H(b"batman-claim-v1" + CLAIM_NONCE + H_NX + H(DAC_DER) + pub65(owner_sign))
od = OTHER_DATA
checkmac_input = (CLAIM_SECRET + client_chal + od[0:4] + bytes(8) + od[4:7] + SN[8:9]
                  + od[7:11] + SN[0:2] + od[11:13])
assert len(checkmac_input) == 88
out["claim_checkmac"] = {
    "nonce": hx(CLAIM_NONCE), "uses": "noise_nx.handshake_hash",
    "client_chal": hx(client_chal), "other_data": hx(od),
    "checkmac_input_88B": hx(checkmac_input), "response": hx(H(checkmac_input)),
}
sig_enc = es256(owner_sign, b"batman-owner-enc-v1" + pub65(owner_enc))
out["owner_enc"] = {"sig_enc_input": hx(b"batman-owner-enc-v1" + pub65(owner_enc)), "sig_enc": hx(sig_enc)}

NONCE_APP, NONCE_NODE = seed("peer-nonce-app"), seed("peer-nonce-node")
peer_input = b"batman-peer-v1" + NONCE_APP + NONCE_NODE + H_PSK
out["peers_challenge"] = {"nonce_app": hx(NONCE_APP), "nonce_node": hx(NONCE_NODE), "input": hx(peer_input),
                          "sig": hx(es256(dac_key, peer_input)), "uses": "noise_nxpsk0_owner.handshake_hash"}


# ------------------------------------------------------------------ COSE (§7)
def sign1(key, payload: bytes, ctype: str, label: bytes):
    protected = cb({1: -7, 3: ctype})
    to_sign = cb(["Signature1", protected, label, payload])
    sig = es256(key, to_sign)
    return cbor2.dumps(cbor2.CBORTag(18, [protected, {}, payload, sig]), canonical=True), to_sign


LABEL_OF = {"batman/netcfg": b"batman-netcfg-v1", "batman/members": b"batman-members-v1",
            "batman/secrets": b"batman-secrets-v1", "batman/msecrets": b"batman-msecrets-v1",
            "batman/invite": b"batman-invite-v1", "batman/joinreq": b"batman-joinreq-v1"}


def object_hash(raw: bytes) -> bytes:
    """§7.1 OBJECT HASH = SHA-256(cbor(Sig_structure)); independent of signature and unprotected header."""
    prot, _unprot, payload, _sig = cbor2.loads(raw).value
    label = LABEL_OF[cbor2.loads(prot)[3]]
    return H(cb(["Signature1", prot, label, payload]))


def encrypt(plain: bytes, label: bytes, target_pub_key, target_hash: bytes, eph_key, iv: bytes):
    body_prot = cb({1: 24})
    rec_prot = cb({1: -25})
    epk = pub65(eph_key)
    cose_key = {1: 2, -1: 1, -2: epk[1:33], -3: epk[33:65]}
    z = eph_key.exchange(ec.ECDH(), target_pub_key)
    ctx = cb([24, [None, None, None], [target_hash, None, None], [256, rec_prot, NET_ID + u32be(NET_VERSION)]])
    cek = hkdf(z, ctx)
    aad = cb(["Encrypt", body_prot, label])
    ct = ChaCha20Poly1305(cek).encrypt(iv, plain, aad)
    obj = cbor2.CBORTag(96, [body_prot, {5: iv}, ct, [[rec_prot, {-1: cose_key}, b""]]])
    return obj, {"ecdh_z": hx(z), "kdf_context": hx(ctx), "cek": hx(cek), "enc_structure": hx(aad)}


NETCFG_PAYLOAD = cb({1: NET_ID, 2: NET_VERSION, 3: None, 4: "家裡網路", 5: "TW",
                     6: {1: "batman-test", 2: 40, 3: 4}, 8: [pub65(admin_key)]})
NETCFG, netcfg_tbs = sign1(admin_key, NETCFG_PAYLOAD, "batman/netcfg", b"batman-netcfg-v1")

MEMBERS_PAYLOAD = cb({1: NET_ID, 2: NET_VERSION, 3: None,
                      4: [{1: DAC_PUB_HASH, 2: pub65(node_ecdh), 3: "客廳", 4: pub65(owner_sign),
                           5: pub65(owner_enc)}],
                      5: [], 6: [], 7: []})
MEMBERS, members_tbs = sign1(admin_key, MEMBERS_PAYLOAD, "batman/members", b"batman-members-v1")

SECRETS_PLAIN = cb({1: "correct-horse-battery", 2: NET_ROOT, 4: "team-ap-pass"})
enc_obj, enc_detail = encrypt(SECRETS_PLAIN, b"batman-secrets-v1", node_ecdh.public_key(), DAC_PUB_HASH,
                              cose_eph, seed("iv-secrets")[:12])
SECRETS_PAYLOAD = cb({1: NET_ID, 2: NET_VERSION, 3: DAC_PUB_HASH, 4: enc_obj})
SECRETS, _ = sign1(admin_key, SECRETS_PAYLOAD, "batman/secrets", b"batman-secrets-v1")

OWNER_ENC_HASH = H(pub65(owner_enc))
MS_PLAIN = cb({2: NET_ROOT})
ms_enc, ms_detail = encrypt(MS_PLAIN, b"batman-msecrets-v1", owner_enc.public_key(), OWNER_ENC_HASH,
                            cose_eph_member, seed("iv-msecrets")[:12])
MS_PAYLOAD = cb({1: NET_ID, 2: NET_VERSION, 3: OWNER_ENC_HASH, 4: ms_enc})
MSECRETS, _ = sign1(admin_key, MS_PAYLOAD, "batman/msecrets", b"batman-msecrets-v1")

INVITE_ID = seed("invite-id")[:16]
INVITE_REMOTE_PAYLOAD = cb({1: NET_ID, 2: INVITE_ID, 3: 1, 4: item(NETCFG), 5: pub65(admin_key)})
INVITE_REMOTE, _ = sign1(admin_key, INVITE_REMOTE_PAYLOAD, "batman/invite", b"batman-invite-v1")
INVITE_INPERSON_PAYLOAD = cb({1: NET_ID, 2: seed("invite-id-2")[:16], 3: 0, 4: item(NETCFG), 5: pub65(admin_key),
                              6: "correct-horse-battery"})
INVITE_INPERSON, _ = sign1(admin_key, INVITE_INPERSON_PAYLOAD, "batman/invite",
                           b"batman-invite-v1")

JOINREQ_PAYLOAD = cb({1: object_hash(INVITE_REMOTE), 2: node_cert, 3: pub65(owner_sign), 4: pub65(owner_enc),
                      5: sig_enc, 6: "客廳"})
JOINREQ, _ = sign1(owner_sign, JOINREQ_PAYLOAD, "batman/joinreq", b"batman-joinreq-v1")

APPROVAL = cb({2: item(MEMBERS), 3: item(SECRETS), 4: item(MSECRETS)})   # net_config omitted: the joiner already has it from the invite
QR_INVITE = cb({1: 1, 2: INVITE_REMOTE})
QR_APPROVAL = cb({1: 3, 2: APPROVAL})

SAS_DIGEST = H(b"batman-sas-v1" + object_hash(INVITE_REMOTE) + object_hash(JOINREQ))
SAS = f"{int.from_bytes(SAS_DIGEST, 'big') % 1_000_000:06d}"     # §5.5: big-endian integer mod 10^6, zero-padded

# ------------------------------------------------------------------ version chain (§7.1, §7.5)
admin2 = p256("admin2")
NETCFG_V2_PAYLOAD = cb({1: NET_ID, 2: 2, 3: object_hash(NETCFG), 4: "家裡網路", 5: "TW",
                        6: {1: "batman-test", 2: 40, 3: 4}, 8: [pub65(admin_key), pub65(admin2)]})
NETCFG_V2, _ = sign1(admin_key, NETCFG_V2_PAYLOAD, "batman/netcfg", b"batman-netcfg-v1")   # signed by a v1 admin
NETCFG_V3_PAYLOAD = cb({1: NET_ID, 2: 3, 3: object_hash(NETCFG_V2), 4: "家裡網路", 5: "TW",
                        6: {1: "batman-test", 2: 40, 3: 4}, 8: [pub65(admin2)]})
NETCFG_V3, _ = sign1(admin2, NETCFG_V3_PAYLOAD, "batman/netcfg", b"batman-netcfg-v1")       # admin2 is a v2 admin
out["version_chain"] = {
    "rule": "version v+1 is verified against version v's admins; prev_hash = OBJECT HASH of version v",
    "admin2_pub": hx(pub65(admin2)),
    "v1_object_hash": hx(object_hash(NETCFG)),
    "v2": hx(NETCFG_V2), "v2_object_hash": hx(object_hash(NETCFG_V2)),
    "v3": hx(NETCFG_V3),
    "note": "v3 is valid (admin2 is in v2.admins) but would be INVALID if checked against v1.admins",
}

out["cose"] = {
    "net_config": {"payload": hx(NETCFG_PAYLOAD), "sig_structure": hx(netcfg_tbs), "sign1": hx(NETCFG)},
    "member_list": {"payload": hx(MEMBERS_PAYLOAD), "sig_structure": hx(members_tbs), "sign1": hx(MEMBERS)},
    "net_secrets": {"plaintext": hx(SECRETS_PLAIN), **enc_detail, "sign1": hx(SECRETS)},
    "member_secrets": {"plaintext": hx(MS_PLAIN), **ms_detail, "sign1": hx(MSECRETS)},
    "invite_remote": hx(INVITE_REMOTE),
    "invite_in_person": hx(INVITE_INPERSON),
    "join_request": hx(JOINREQ),
    "approval_bundle": hx(APPROVAL),
    "qr_invite_object": hx(QR_INVITE),
    "qr_approval_object": hx(QR_APPROVAL),
    "qr_sizes_bytes": {"invite": len(QR_INVITE), "join_request": len(cb({1: 2, 2: JOINREQ})),
                       "approval": len(QR_APPROVAL)},
}
out["sas"] = {"digest": hx(SAS_DIGEST), "sas": SAS,
              "rule": "first 6 decimal digits = int(SHA-256('batman-sas-v1'||H(invite)||H(join_request))) mod 10^6"}


# ------------------------------------------------------------------ GATT framing (§4.1)
def frames(msg: bytes, frame_limit: int):
    data_max = frame_limit - 3
    chunks = [msg[i:i + data_max] for i in range(0, len(msg), data_max)]
    res = []
    for i, c in enumerate(chunks):
        flags = (1 if i == 0 else 0) | (2 if i == len(chunks) - 1 else 0)
        res.append(bytes([flags]) + (i & 0xFFFF).to_bytes(2, "big") + c)
    return res


fr = frames(m1, 20)
out["gatt_framing"] = {
    "input": "noise_nx.msg1", "frame_limit": 20, "data_per_frame": 17,
    "frames": [hx(f) for f in fr],
    "invalid_cases": [
        "seq jumps (0, 2): abort connection",
        "reassembled length > 65535: abort connection",
        "frame without start flag while idle: abort connection",
    ],
}

# ------------------------------------------------------------------ envelope examples (§5.1)
_upd_body = cb({1: [{1: item(NETCFG), 2: item(MEMBERS), 3: item(SECRETS)}]})
_half = len(_upd_body) // 2
out["chunking"] = {
    "rule": "chunks share id; 3 = bstr slice of the encoded body; 6 = {1: n, 2: total}",
    "body": hx(_upd_body),
    "chunk1": hx(cb({0: [1, 0], 1: 5, 2: "network/update", 3: _upd_body[:_half], 6: {1: 1, 2: 2},
                     7: seed("idem-upd")[:16]})),
    "chunk2": hx(cb({0: [1, 0], 1: 5, 2: "network/update", 3: _upd_body[_half:], 6: {1: 2, 2: 2},
                     7: seed("idem-upd")[:16]})),
}
out["envelope"] = {
    "request_info": hx(REQ_INFO),
    "response_info": hx(cb({1: 1, 4: 0, 3: {1: DEVICE_ID, 2: "C3", 3: "bcm2710", 4: "1.6.0", 5: [1, 0],
                                            6: ["halow", "gps", "ptt", "lora", "se"], 7: 0, 8: True}})),
    "response_error_unsupported": hx(cb({1: 7, 4: 6, 5: {1: "lora", 2: 7}})),
    "request_reset_with_idem": hx(cb({0: [1, 0], 1: 9, 2: "reset", 3: {1: 1}, 7: seed("idem")[:16]})),
}

# fake msg2 for a failed PSK (§3.4): same length, real ephemeral, random payload
out["fake_msg2_rule"] = {
    "length_equals_real_msg2": len(m2p),
    "note": "Real fresh ephemeral (e.g. fake_e_pub) || random bytes; responder performs the same DH count and "
            "waits for the session timeout before closing.",
    "fake_e_pub": hx(fake_e_pk),
}

sys.stdout.reconfigure(encoding="utf-8", newline="\n")   # identical bytes on every OS
json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
