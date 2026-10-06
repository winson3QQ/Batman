#!/usr/bin/env python3
"""Independently verify vectors.json against docs/design/219-protocol.md / .cddl.

Uses implementations that are DIFFERENT from gen.py wherever possible:
  * Noise: dissononce (gen.py uses noiseprotocol) — reproduces msg1, reads msg2,
    compares the handshake hash and decrypts the first transport message.
  * ECDSA: python-ecdsa (gen.py uses cryptography) — verifies every raw r||s signature.
  * ECDH + HKDF: python-ecdsa ECDH + stdlib hmac (gen.py uses cryptography).
  * COSE Sign1: rebuilt Sig_structure, verified with python-ecdsa.
  * CBOR schema: pycddl validates each object against 219-protocol.cddl.
Exit code 0 = all checks passed.

    python verify.py vectors.json
"""
import hashlib
import hmac
import json
import pathlib
import sys

import cbor2
import ecdsa
import pycddl
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305   # AEAD primitive only
from cryptography import x509
from dissononce.cipher.chachapoly import ChaChaPolyCipher
from dissononce.dh.x25519.x25519 import X25519DH
from dissononce.dh.keypair import KeyPair
from dissononce.dh.x25519.public import PublicKey as X25519Pub
from dissononce.dh.x25519.private import PrivateKey as X25519Priv
from dissononce.hash.sha256 import SHA256Hash
from dissononce.processing.handshakepatterns.interactive.NX import NXHandshakePattern
from dissononce.processing.modifiers.psk import PSKPatternModifier
from dissononce.processing.impl.handshakestate import HandshakeState
from dissononce.processing.impl.symmetricstate import SymmetricState
from dissononce.processing.impl.cipherstate import CipherState

HERE = pathlib.Path(__file__).resolve().parent
CDDL = (HERE / "../../../docs/design/219-protocol.cddl").resolve().read_text(encoding="utf-8")

v = json.load(open(sys.argv[1] if len(sys.argv) > 1 else HERE / "vectors.json", encoding="utf-8"))
b = bytes.fromhex
K = v["keys"]
fails = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def H(x):
    return hashlib.sha256(x).digest()


def vk(pub65):
    return ecdsa.VerifyingKey.from_string(pub65, curve=ecdsa.NIST256p)


def es256_ok(pub65, msg, sig):
    try:
        return vk(pub65).verify(sig, msg, hashfunc=hashlib.sha256)
    except ecdsa.BadSignatureError:
        return False


def hkdf(ikm, info, L=32):
    prk = hmac.new(b"\x00" * 32, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < L:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:L]


# ------------------------------------------------------------------ certificates
root = x509.load_der_x509_certificate(b(K["root_ca_cert_der"]))
dac = x509.load_der_x509_certificate(b(K["dac_cert_der"]))
try:
    dac.verify_directly_issued_by(root)
    ok = True
except Exception:
    ok = False
check("DAC certificate is issued by the test root", ok)
sn_attr = dac.subject.get_attributes_for_oid(x509.oid.NameOID.SERIAL_NUMBER)[0].value
check("DAC subject serialNumber == sn", sn_attr == K["sn"])

# ------------------------------------------------------------------ node_cert
nc = cbor2.loads(b(v["node_cert"]["cbor"]))
check("node_cert re-encodes deterministically", cbor2.dumps(nc, canonical=True) == b(v["node_cert"]["cbor"]))
check("node_cert root not included in chain", len(nc[1]) == 1)
check("sig_static verifies (python-ecdsa)",
      es256_ok(b(K["dac_pub"]), b"batman-node-static-v1" + nc[2] + nc[3], nc[5]))
check("sig_ecdh verifies", es256_ok(b(K["dac_pub"]), b"batman-node-ecdh-v1" + nc[4], nc[6]))

# ------------------------------------------------------------------ HKDF
did = K["device_id"].encode()
nid, root_key = b(K["net_id"]), b(K["net_root"])
check("psk_owner", hkdf(b(K["owner_tag_key"]), b"batman-psk-owner-v1" + did).hex() == v["hkdf"]["psk_owner"])
check("psk_member",
      hkdf(root_key, b"batman-psk-member-v1" + nid + (1).to_bytes(4, "big")).hex() == v["hkdf"]["psk_member"])
check("adv_owner", hkdf(b(K["adv_owner_key"]), b"batman-adv-owner-v1" + did).hex() == v["hkdf"]["adv_owner"])
check("adv_member",
      hkdf(root_key, b"batman-adv-member-v1" + nid + (1).to_bytes(4, "big")).hex() == v["hkdf"]["adv_member"])


# ------------------------------------------------------------------ Noise interop (dissononce)
def noise_check(tag, vec, psk):
    dh = X25519DH()
    e = dh.generate_keypair(X25519Priv(b(K["phone_ephemeral_priv"])))
    real_gen = dh.generate_keypair
    dh.generate_keypair = lambda privatekey=None: e if privatekey is None else real_gen(privatekey)  # fixed test ephemeral
    pattern = NXHandshakePattern()
    if psk is not None:
        pattern = PSKPatternModifier(0).modify(pattern)
    hs = HandshakeState(SymmetricState(CipherState(ChaChaPolyCipher()), SHA256Hash()), dh)
    hs.initialize(pattern, True, b(vec["prologue"]), psks=[psk] if psk else None)
    buf = bytearray()
    hs.write_message(b"", buf)
    check(f"{tag}: msg1 identical across implementations", bytes(buf) == b(vec["msg1"]))
    payload = bytearray()
    cs = hs.read_message(b(vec["msg2"]), payload)
    check(f"{tag}: msg2 payload == node_cert", bytes(payload) == b(v["node_cert"]["cbor"]))
    check(f"{tag}: handshake hash identical", hs.symmetricstate.get_handshake_hash() == b(vec["handshake_hash"]))
    check(f"{tag}: remote static == s_node_pub", hs.rs.data == b(K["s_node_pub"]))
    send = cs[0]
    ct = send.encrypt_with_ad(b"", b(v["envelope"]["request_info"]))
    check(f"{tag}: first transport message identical", ct == b(vec["first_transport_message"]))


noise_check("NX", v["noise_nx"], None)
noise_check("NXpsk0", v["noise_nxpsk0_owner"], b(v["hkdf"]["psk_owner"]))

# ------------------------------------------------------------------ auth / claim / peer
a = v["auth_owner"]
check("owner_key_id", H(b(K["owner_sign_pub"])).hex() == a["owner_key_id"])
check("auth/owner input", (b"batman-owner-auth-v1" + b(v["noise_nxpsk0_owner"]["handshake_hash"])
                           + b(a["owner_key_id"])).hex() == a["input"])
check("auth/owner sig", es256_ok(b(K["owner_sign_pub"]), b(a["input"]), b(a["sig"])))

c = v["claim_checkmac"]
chal = H(b"batman-claim-v1" + b(c["nonce"]) + b(v["noise_nx"]["handshake_hash"]) + H(b(K["dac_cert_der"]))
         + b(K["owner_sign_pub"]))
od, sn = b(c["other_data"]), b(K["sn"])
inp = b(K["claim_secret"]) + chal + od[0:4] + bytes(8) + od[4:7] + sn[8:9] + od[7:11] + sn[0:2] + od[11:13]
check("claim ClientChal", chal.hex() == c["client_chal"])
check("claim CheckMac input is 88 B and matches", len(inp) == 88 and inp.hex() == c["checkmac_input_88B"])
check("claim response", H(inp).hex() == c["response"])

check("sig_enc", es256_ok(b(K["owner_sign_pub"]), b(v["owner_enc"]["sig_enc_input"]), b(v["owner_enc"]["sig_enc"])))
p = v["peers_challenge"]
check("peers/challenge sig", es256_ok(b(K["dac_pub"]), b(p["input"]), b(p["sig"])))

# ------------------------------------------------------------------ COSE
LABELS = {"batman/netcfg": b"batman-netcfg-v1", "batman/members": b"batman-members-v1",
          "batman/secrets": b"batman-secrets-v1", "batman/msecrets": b"batman-msecrets-v1",
          "batman/invite": b"batman-invite-v1", "batman/joinreq": b"batman-joinreq-v1"}


def sign1_ok(raw, signer_pub, name):
    t = cbor2.loads(raw)
    check(f"{name}: tagged COSE_Sign1 (18)", isinstance(t, cbor2.CBORTag) and t.tag == 18)
    prot, _unprot, payload, sig = t.value
    ph = cbor2.loads(prot)
    check(f"{name}: alg ES256", ph.get(1) == -7)
    label = LABELS[ph[3]]
    tbs = cbor2.dumps(["Signature1", prot, label, payload], canonical=True)
    check(f"{name}: signature verifies with label {label.decode()}", es256_ok(signer_pub, tbs, sig))
    check(f"{name}: payload deterministic", cbor2.dumps(cbor2.loads(payload), canonical=True) == payload)
    return cbor2.loads(payload)


admin = b(K["admin_pub"])
co = v["cose"]
netcfg = sign1_ok(b(co["net_config"]["sign1"]), admin, "net_config")
members = sign1_ok(b(co["member_list"]["sign1"]), admin, "member_list")
secrets = sign1_ok(b(co["net_secrets"]["sign1"]), admin, "net_secrets")
msecrets = sign1_ok(b(co["member_secrets"]["sign1"]), admin, "member_secrets")
inv_r = sign1_ok(b(co["invite_remote"]), admin, "invite_remote")
inv_p = sign1_ok(b(co["invite_in_person"]), admin, "invite_in_person")
jr = sign1_ok(b(co["join_request"]), b(K["owner_sign_pub"]), "join_request")
check("in-person invite carries SAE password; remote does not", 6 in inv_p and 6 not in inv_r)
check("join_request binds the complete remote invite", jr[1] == H(b(co["invite_remote"])))


def decrypt(enc_tag, recipient_priv_name, target_hash, label, detail):
    prot, unprot, ct, recips = enc_tag.value
    rprot, runprot, _ = recips[0]
    check(f"{label.decode()}: body alg ChaCha20/Poly1305 (24)", cbor2.loads(prot).get(1) == 24)
    check(f"{label.decode()}: recipient alg ECDH-ES+HKDF-256 (-25)", cbor2.loads(rprot).get(1) == -25)
    epk = runprot[-1]
    eph = ecdsa.VerifyingKey.from_string(b"\x04" + epk[-2] + epk[-3], curve=ecdsa.NIST256p)
    d = int.from_bytes(hashlib.sha256(b"batman-test-vector/" + recipient_priv_name.encode()).digest(), "big")
    d = d % (ecdsa.NIST256p.order - 1) + 1
    shared = ecdsa.ECDH(curve=ecdsa.NIST256p,
                        private_key=ecdsa.SigningKey.from_secret_exponent(d, curve=ecdsa.NIST256p),
                        public_key=eph).generate_sharedsecret_bytes()
    ctx = cbor2.dumps([24, [None, None, None], [target_hash, None, None],
                       [256, rprot, b(K["net_id"]) + (1).to_bytes(4, "big")]], canonical=True)
    cek = hkdf(shared, ctx)
    check(f"{label.decode()}: ECDH z (python-ecdsa)", shared.hex() == detail["ecdh_z"])
    check(f"{label.decode()}: CEK", cek.hex() == detail["cek"])
    aad = cbor2.dumps(["Encrypt", prot, label], canonical=True)
    return ChaCha20Poly1305(cek).decrypt(unprot[5], ct, aad)


plain = decrypt(secrets[4], "node-ecdh", b(K["dac_pub_hash"]), b"batman-secrets-v1", co["net_secrets"])
check("net_secrets plaintext", plain.hex() == co["net_secrets"]["plaintext"])
check("net_secrets target == dac_pub_hash", secrets[3] == b(K["dac_pub_hash"]))
mplain = decrypt(msecrets[4], "owner-enc", H(b(K["owner_enc_pub"])), b"batman-msecrets-v1", co["member_secrets"])
check("member_secrets plaintext carries net_root", cbor2.loads(mplain)[2] == b(K["net_root"]))

sas = int.from_bytes(H(b"batman-sas-v1" + H(b(co["invite_remote"])) + H(b(co["join_request"]))), "big") % 10**6
check("SAS", f"{sas:06d}" == v["sas"]["sas"])
for k_, n in v["cose"]["qr_sizes_bytes"].items():
    check(f"QR object '{k_}' fits QR version 25-L binary (1273 B): {n} B", n <= 1273)

# ------------------------------------------------------------------ GATT framing
g = v["gatt_framing"]
re = b""
for i, f in enumerate(b(x) for x in g["frames"]):
    flags, seq = f[0], int.from_bytes(f[1:3], "big")
    check(f"frame {i}: seq/flags", seq == i and (flags & 1) == (i == 0)
          and ((flags & 2) != 0) == (i == len(g["frames"]) - 1))
    re += f[3:]
check("frames reassemble to msg1", re == b(v["noise_nx"]["msg1"]))

# ------------------------------------------------------------------ CDDL schema
schema = pycddl.Schema(CDDL)
cases = [
    ("request", v["envelope"]["request_info"]), ("response", v["envelope"]["response_info"]),
    ("response", v["envelope"]["response_error_unsupported"]),
    ("request", v["envelope"]["request_reset_with_idem"]),
    ("node-cert", v["node_cert"]["cbor"]),
    ("cose-sign1", co["net_config"]["sign1"]),
]
for rule, hx_ in cases:
    try:
        pycddl.Schema(CDDL + f"\n__root = {rule}\n").validate_cbor(b(hx_)) if False else None
        sub = pycddl.Schema(f"__root = {rule}\n" + CDDL)
        sub.validate_cbor(b(hx_))
        check(f"CDDL: {rule}", True)
    except Exception as ex:   # noqa: BLE001
        check(f"CDDL: {rule} ({ex})", False)
for rule, raw in [("net-config", cbor2.dumps(netcfg, canonical=True)),
                  ("member-list", cbor2.dumps(members, canonical=True)),
                  ("net-secrets", cbor2.dumps(secrets, canonical=True)),
                  ("member-secrets", cbor2.dumps(msecrets, canonical=True)),
                  ("invite", cbor2.dumps(inv_r, canonical=True)),
                  ("invite", cbor2.dumps(inv_p, canonical=True)),
                  ("join-request", cbor2.dumps(jr, canonical=True)),
                  ("net-secrets-plain", plain),
                  ("approval-bundle", b(co["approval_bundle"])),
                  ("qr-object", b(co["qr_invite_object"]))]:
    try:
        pycddl.Schema(f"__root = {rule}\n" + CDDL).validate_cbor(raw)
        check(f"CDDL: {rule}", True)
    except Exception as ex:   # noqa: BLE001
        check(f"CDDL: {rule} ({ex})", False)

print(f"\n{'ALL PASSED' if not fails else str(len(fails)) + ' FAILED'}")
sys.exit(1 if fails else 0)
