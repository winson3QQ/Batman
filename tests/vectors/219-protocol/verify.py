#!/usr/bin/env python3
"""Independently verify vectors.json against docs/design/219-protocol.md / .cddl (v0.6).

Uses implementations that are DIFFERENT from gen.py wherever possible:
  * Noise: dissononce (gen.py uses noiseprotocol) — reproduces msg1, reads msg2,
    compares the handshake hash, decrypts the first transport message.
  * ECDSA / ECDH: python-ecdsa (gen.py uses cryptography).
  * HKDF: stdlib hmac.
  * COSE Sign1: pycose (independent COSE library) AND a hand-built Sig_structure.
  * Schema: pycddl validates objects against 219-protocol.cddl.
Signature inputs are REBUILT from labels and components, not taken from the vector file.
Negative tests check that bad input is rejected.

    python verify.py vectors.json        # exit code 0 = all checks passed
"""
import hashlib
import hmac
import json
import pathlib
import re
import sys

import cbor2
import ecdsa
import pycddl
from cryptography import x509
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305   # AEAD primitive only
from dissononce.cipher.chachapoly import ChaChaPolyCipher
from dissononce.dh.x25519.private import PrivateKey as X25519Priv
from dissononce.dh.x25519.x25519 import X25519DH
from dissononce.hash.sha256 import SHA256Hash
from dissononce.processing.handshakepatterns.interactive.NX import NXHandshakePattern
from dissononce.processing.impl.cipherstate import CipherState
from dissononce.processing.impl.handshakestate import HandshakeState
from dissononce.processing.impl.symmetricstate import SymmetricState
from dissononce.processing.modifiers.psk import PSKPatternModifier
import collections.abc
from pycose.keys import EC2Key
from pycose.keys.curves import P256
from pycose.messages import CoseMessage
from pycose.messages.context import CoseKDFContext, PartyInfo, SuppPubInfo


class _ChaCha:              # minimal algorithm descriptor for pycose's KDF context
    identifier = 24
    fullname = "ChaCha20Poly1305"


def _plain(x):
    if isinstance(x, (tuple, list)):
        return [_plain(i) for i in x]
    if isinstance(x, collections.abc.Mapping):
        return {k: _plain(val) for k, val in x.items()}
    return x


def pycose_decode(raw):
    t = cbor2.loads(raw)
    return CoseMessage._COSE_MSG_ID[t.tag].from_cose_obj(_plain(t.value), True)

HERE = pathlib.Path(__file__).resolve().parent
CDDL_NORMATIVE = (HERE / "../../../docs/design/219-protocol.cddl").resolve().read_text(encoding="utf-8")
# pycddl 0.6 mis-handles ".cbor" inside arrays (false rejects / panics). Containers are validated with
# ".cbor" relaxed to plain bstr; every embedded payload is then validated separately with its strict rule.
CDDL = re.sub(r"bstr \.cbor [A-Za-z0-9-]+", "bstr",
              re.sub(r"bstr \.cbor \{[^}]*\}", "bstr", CDDL_NORMATIVE))
v = json.load(open(sys.argv[1] if len(sys.argv) > 1 else HERE / "vectors.json", encoding="utf-8"))
b = bytes.fromhex
K = v["keys"]
N = ecdsa.NIST256p.order
fails = []
count = 0


def check(name, cond):
    global count
    count += 1
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def H(x):
    return hashlib.sha256(x).digest()


def es256_ok(pub65, msg, sig):
    """Receivers accept only low-s signatures (§7.1)."""
    if int.from_bytes(sig[32:], "big") > N // 2:
        return False
    try:
        return ecdsa.VerifyingKey.from_string(pub65, curve=ecdsa.NIST256p).verify(sig, msg, hashfunc=hashlib.sha256)
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


def deterministic(raw):
    """RFC 8949 §4.2.1: map keys sorted by their encoded bytes, shortest forms (re-encode must match)."""
    def walk(o):
        if isinstance(o, dict):
            enc = [cbor2.dumps(k) for k in o]
            if enc != sorted(enc):
                return False
            return all(walk(x) for x in o.values())
        if isinstance(o, (list, tuple)):
            return all(walk(x) for x in o)
        if isinstance(o, cbor2.CBORTag):
            return walk(o.value)
        return True
    obj = cbor2.loads(raw)
    return walk(obj) and cbor2.dumps(obj, canonical=True) == raw


def cddl_ok(rule, raw):
    try:
        pycddl.Schema(f"__root = {rule}\n" + CDDL).validate_cbor(raw)
        return True
    except BaseException:   # noqa: BLE001  (pycddl panics surface as BaseException)
        return False


# ------------------------------------------------------------------ certificates
root = x509.load_der_x509_certificate(b(K["root_ca_cert_der"]))
dac = x509.load_der_x509_certificate(b(K["dac_cert_der"]))
try:
    dac.verify_directly_issued_by(root)
    ok = True
except Exception:   # noqa: BLE001
    ok = False
check("DAC is issued by the test root", ok)
check("DAC subject CN == device_id (§3.3)",
      dac.subject.get_attributes_for_oid(x509.oid.NameOID.COMMON_NAME)[0].value == K["device_id"])
check("DAC subject serialNumber == lowercase hex(sn) (§3.3)",
      dac.subject.get_attributes_for_oid(x509.oid.NameOID.SERIAL_NUMBER)[0].value == K["sn"])

# ------------------------------------------------------------------ node_cert
NC_RAW = b(v["node_cert"]["cbor"])
nc = cbor2.loads(NC_RAW)
check("node_cert deterministic CBOR", deterministic(NC_RAW))
check("node_cert CDDL", cddl_ok("node-cert", NC_RAW))
check("node_cert chain has no root", len(nc[1]) == 1 and nc[1][0] == b(K["dac_cert_der"]))
check("sig_static (rebuilt input)", es256_ok(b(K["dac_pub"]), b"batman-node-static-v1" + nc[2] + nc[3], nc[5]))
check("sig_ecdh (rebuilt input)", es256_ok(b(K["dac_pub"]), b"batman-node-ecdh-v1" + nc[4], nc[6]))
check("sig_static rejected under the wrong label",
      not es256_ok(b(K["dac_pub"]), b"batman-node-ecdh-v1" + nc[2] + nc[3], nc[5]))
hs = nc[5][:32] + (N - int.from_bytes(nc[5][32:], "big")).to_bytes(32, "big")
check("high-s variant of sig_static is rejected", not es256_ok(b(K["dac_pub"]), b"batman-node-static-v1" + nc[2] + nc[3], hs))

# ------------------------------------------------------------------ HKDF
did, nid, nroot = K["device_id"].encode(), b(K["net_id"]), b(K["net_root"])
u1 = (1).to_bytes(4, "big")
check("psk_owner", hkdf(b(K["owner_tag_key"]), b"batman-psk-owner-v1" + did).hex() == v["hkdf"]["psk_owner"])
check("psk_member", hkdf(nroot, b"batman-psk-member-v1" + nid + u1).hex() == v["hkdf"]["psk_member"])
check("adv_owner", hkdf(b(K["adv_owner_key"]), b"batman-adv-owner-v1" + did).hex() == v["hkdf"]["adv_owner"])
check("adv_member", hkdf(nroot, b"batman-adv-member-v1" + nid + u1).hex() == v["hkdf"]["adv_member"])


# ------------------------------------------------------------------ Noise interop (dissononce)
def noise_initiator(prologue, psk):
    dh = X25519DH()
    e = dh.generate_keypair(X25519Priv(b(K["phone_ephemeral_priv"])))
    real = dh.generate_keypair
    dh.generate_keypair = lambda privatekey=None: e if privatekey is None else real(privatekey)
    pattern = NXHandshakePattern()
    if psk is not None:
        pattern = PSKPatternModifier(0).modify(pattern)
    st = HandshakeState(SymmetricState(CipherState(ChaChaPolyCipher()), SHA256Hash()), dh)
    st.initialize(pattern, True, prologue, psks=[psk] if psk else None)
    return st


def noise_check(tag, vec, psk):
    st = noise_initiator(b(vec["prologue"]), psk)
    buf = bytearray()
    st.write_message(b"", buf)
    check(f"{tag}: msg1 byte-identical across implementations (payload empty)", bytes(buf) == b(vec["msg1"]))
    payload = bytearray()
    cs = st.read_message(b(vec["msg2"]), payload)
    check(f"{tag}: msg2 payload == node_cert", bytes(payload) == NC_RAW)
    check(f"{tag}: handshake hash identical", st.symmetricstate.get_handshake_hash() == b(vec["handshake_hash"]))
    check(f"{tag}: remote static == s_node_pub", st.rs.data == b(K["s_node_pub"]))
    ct = cs[0].encrypt_with_ad(b"", b(v["envelope"]["request_info"]))
    check(f"{tag}: first transport message identical", ct == b(vec["first_transport_message"]))


noise_check("NX", v["noise_nx"], None)
noise_check("NXpsk0", v["noise_nxpsk0_owner"], b(v["hkdf"]["psk_owner"]))

# negative: wrong PSK / wrong prologue must fail to read msg2
for tag, prologue, psk in [("wrong PSK", b(v["noise_nxpsk0_owner"]["prologue"]), b(v["hkdf"]["psk_member"])),
                           ("dev prologue", b"batman-prov-dev/1\x00ble\x00", b(v["hkdf"]["psk_owner"]))]:
    st = noise_initiator(prologue, psk)
    st.write_message(b"", bytearray())
    try:
        st.read_message(b(v["noise_nxpsk0_owner"]["msg2"]), bytearray())
        rejected = False
    except Exception:   # noqa: BLE001
        rejected = True
    check(f"NXpsk0 with {tag} is rejected", rejected)

# ------------------------------------------------------------------ auth / claim / peer (inputs rebuilt)
H_NX, H_PSK = b(v["noise_nx"]["handshake_hash"]), b(v["noise_nxpsk0_owner"]["handshake_hash"])
okid = H(b(K["owner_sign_pub"]))
check("owner_key_id = SHA-256(owner_pub 65 B)", okid.hex() == v["auth_owner"]["owner_key_id"])
check("auth/owner sig (rebuilt input)",
      es256_ok(b(K["owner_sign_pub"]), b"batman-owner-auth-v1" + H_PSK + okid, b(v["auth_owner"]["sig"])))
check("auth/owner sig does not verify against the NX hash",
      not es256_ok(b(K["owner_sign_pub"]), b"batman-owner-auth-v1" + H_NX + okid, b(v["auth_owner"]["sig"])))
check("sig_enc (rebuilt input)",
      es256_ok(b(K["owner_sign_pub"]), b"batman-owner-enc-v1" + b(K["owner_enc_pub"]), b(v["owner_enc"]["sig_enc"])))
pc = v["peers_challenge"]
check("peers/challenge sig (rebuilt input)",
      es256_ok(b(K["dac_pub"]), b"batman-peer-v1" + b(pc["nonce_app"]) + b(pc["nonce_node"]) + H_PSK, b(pc["sig"])))

c = v["claim_checkmac"]
chal = H(b"batman-claim-v1" + b(c["nonce"]) + H_NX + H(b(K["dac_cert_der"])) + b(K["owner_sign_pub"]))
od, sn = bytes.fromhex("08000000000000000000000000"), b(K["sn"])       # OtherData fixed by §5.4
inp = b(K["claim_secret"]) + chal + od[0:4] + bytes(8) + od[4:7] + sn[8:9] + od[7:11] + sn[0:2] + od[11:13]
check("claim: OtherData constant matches §5.4", c["other_data"] == od.hex())
check("claim: ClientChal", chal.hex() == c["client_chal"])
check("claim: CheckMac input 88 B", len(inp) == 88 and inp.hex() == c["checkmac_input_88B"])
check("claim: response", H(inp).hex() == c["response"])
# NOTE: this re-derives the same formula; the authoritative cross-check is cryptoauthlib atcah_check_mac
#       or a real 608B (spec §11 / B1).

# ------------------------------------------------------------------ COSE
LABELS = {"batman/netcfg": b"batman-netcfg-v1", "batman/members": b"batman-members-v1",
          "batman/secrets": b"batman-secrets-v1", "batman/msecrets": b"batman-msecrets-v1",
          "batman/invite": b"batman-invite-v1", "batman/joinreq": b"batman-joinreq-v1"}
PAYLOAD_RULE = {"batman/netcfg": "net-config", "batman/members": "member-list", "batman/secrets": "net-secrets",
                "batman/msecrets": "member-secrets", "batman/invite": "invite", "batman/joinreq": "join-request"}


def pub_to_pycose(pub65):
    return EC2Key(crv=P256, x=pub65[1:33], y=pub65[33:65])


def object_hash(raw):
    prot, _u, payload, _s = cbor2.loads(raw).value
    return H(cbor2.dumps(["Signature1", prot, LABELS[cbor2.loads(prot)[3]], payload], canonical=True))


def sign1_ok(raw, signer_pub, name):
    t = cbor2.loads(raw)
    check(f"{name}: tagged COSE_Sign1 (18), deterministic", isinstance(t, cbor2.CBORTag) and t.tag == 18
          and deterministic(raw))
    prot, unprot, payload, sig = t.value
    ph = cbor2.loads(prot)
    check(f"{name}: ES256 and empty unprotected header", ph.get(1) == -7 and unprot == {})
    label = LABELS[ph[3]]
    tbs = cbor2.dumps(["Signature1", prot, label, payload], canonical=True)
    check(f"{name}: signature (python-ecdsa, label {label.decode()})", es256_ok(signer_pub, tbs, sig))
    msg = pycose_decode(raw)
    msg.key = pub_to_pycose(signer_pub)
    msg.external_aad = label
    try:
        pc_ok = msg.verify_signature()
    except Exception:   # noqa: BLE001
        pc_ok = False
    check(f"{name}: signature (pycose)", pc_ok)
    wrong = b"batman-invite-v1" if label != b"batman-invite-v1" else b"batman-netcfg-v1"
    check(f"{name}: rejected under another label",
          not es256_ok(signer_pub, cbor2.dumps(["Signature1", prot, wrong, payload], canonical=True), sig))
    check(f"{name}: payload CDDL ({PAYLOAD_RULE[ph[3]]})", cddl_ok(PAYLOAD_RULE[ph[3]], payload))
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
check("in-person invite carries the SAE password, remote does not", 6 in inv_p and 6 not in inv_r)
check("invite admin_pub is one of net_config.admins", inv_r[5] in netcfg[8])
check("join_request binds the OBJECT HASH of the remote invite", jr[1] == object_hash(b(co["invite_remote"])))

# malleability: changing the signature encoding or the unprotected header must not change the object hash
t = cbor2.loads(b(co["member_list"]["sign1"]))
prot, unprot, payload, sig = t.value
mall = cbor2.dumps(cbor2.CBORTag(18, [prot, {4: b"x"}, payload,
                                      sig[:32] + (N - int.from_bytes(sig[32:], "big")).to_bytes(32, "big")]))
check("object hash ignores signature and unprotected header", object_hash(mall) == object_hash(b(co["member_list"]["sign1"])))
check("malleated object (non-empty unprotected, high-s) is rejected",
      not (cbor2.loads(mall).value[1] == {} and es256_ok(admin, cbor2.dumps(["Signature1", prot, b"batman-members-v1", payload], canonical=True), cbor2.loads(mall).value[3])))

# unknown key inside a signed payload must be rejected
bad = dict(netcfg)
bad[99] = 1
check("unknown key inside a signed payload is rejected by CDDL", not cddl_ok("net-config", cbor2.dumps(bad, canonical=True)))


def decrypt(enc, recipient_name, target_hash, label, detail):
    prot, unprot, ct, recips = enc.value
    rprot, runprot, _ = recips[0]
    check(f"{label.decode()}: ChaCha20/Poly1305 (24) and ECDH-ES+HKDF-256 (-25)",
          cbor2.loads(prot) == {1: 24} and cbor2.loads(rprot) == {1: -25} and len(unprot[5]) == 12)
    epk = runprot[-1]
    eph = ecdsa.VerifyingKey.from_string(b"\x04" + epk[-2] + epk[-3], curve=ecdsa.NIST256p)
    d = int.from_bytes(H(b"batman-test-vector/" + recipient_name.encode()), "big") % (N - 1) + 1
    z = ecdsa.ECDH(curve=ecdsa.NIST256p, private_key=ecdsa.SigningKey.from_secret_exponent(d, curve=ecdsa.NIST256p),
                   public_key=eph).generate_sharedsecret_bytes()
    ctx = cbor2.dumps([24, [None, None, None], [target_hash, None, None], [256, rprot, nid + u1]], canonical=True)
    cek = hkdf(z, ctx)
    pc_ctx = CoseKDFContext(_ChaCha, SuppPubInfo(32, cbor2.loads(rprot), other=nid + u1),  # pycose: bytes in, 256 bits out
                            PartyInfo(), PartyInfo(identity=target_hash)).encode()
    check(f"{label.decode()}: KDF context identical to pycose's encoding", pc_ctx == ctx)
    check(f"{label.decode()}: ECDH z (python-ecdsa)", z.hex() == detail["ecdh_z"])
    check(f"{label.decode()}: KDF context and CEK", ctx.hex() == detail["kdf_context"] and cek.hex() == detail["cek"])
    aad = cbor2.dumps(["Encrypt", prot, label], canonical=True)
    try:
        ChaCha20Poly1305(cek).decrypt(unprot[5], ct[:-1] + bytes([ct[-1] ^ 1]), aad)
        tamper_ok = False
    except Exception:   # noqa: BLE001
        tamper_ok = True
    check(f"{label.decode()}: tampered ciphertext is rejected", tamper_ok)
    return ChaCha20Poly1305(cek).decrypt(unprot[5], ct, aad)


plain = decrypt(secrets[4], "node-ecdh", b(K["dac_pub_hash"]), b"batman-secrets-v1", co["net_secrets"])
check("net_secrets plaintext + CDDL", plain.hex() == co["net_secrets"]["plaintext"]
      and cddl_ok("net-secrets-plain", plain))
check("net_secrets target == SHA-256(DAC pub 65 B)", secrets[3] == H(b(K["dac_pub"])))
mplain = decrypt(msecrets[4], "owner-enc", H(b(K["owner_enc_pub"])), b"batman-msecrets-v1", co["member_secrets"])
check("member_secrets carries net_root; PartyV = SHA-256(owner_enc_pub)", cbor2.loads(mplain)[2] == nroot
      and msecrets[3] == H(b(K["owner_enc_pub"])))

# ------------------------------------------------------------------ SAS
sd = H(b"batman-sas-v1" + object_hash(b(co["invite_remote"])) + object_hash(b(co["join_request"])))
check("SAS = int(digest, big-endian) mod 10^6, zero-padded (§5.5)", f"{int.from_bytes(sd, 'big') % 10**6:06d}" == v["sas"]["sas"])

# ------------------------------------------------------------------ version chain
vc = v["version_chain"]
v2, v3 = b(vc["v2"]), b(vc["v3"])
p2 = cbor2.loads(cbor2.loads(v2).value[2])
p3 = cbor2.loads(cbor2.loads(v3).value[2])
check("v2.prev_hash == OBJECT HASH(v1)", p2[3] == object_hash(b(co["net_config"]["sign1"])))
check("v3.prev_hash == OBJECT HASH(v2)", p3[3] == object_hash(v2))


def signed_by_any(raw, admins):
    prot, _u, payload, sig = cbor2.loads(raw).value
    tbs = cbor2.dumps(["Signature1", prot, b"batman-netcfg-v1", payload], canonical=True)
    return any(es256_ok(a, tbs, sig) for a in admins)


check("v2 is signed by a v1 admin", signed_by_any(v2, netcfg[8]))
check("v3 is signed by a v2 admin", signed_by_any(v3, p2[8]))
check("v3 is NOT acceptable under v1 admins (rule: v+1 checked against v)", not signed_by_any(v3, netcfg[8]))

# ------------------------------------------------------------------ QR, framing, envelope, CDDL
for k_, n in co["qr_sizes_bytes"].items():
    check(f"QR object '{k_}' ({n} B) fits QR version 25-L binary (1273 B)", n <= 1273)
check("qr-object CDDL", cddl_ok("qr-object", b(co["qr_invite_object"])))
check("approval-bundle CDDL (net_config omitted)", cddl_ok("approval-bundle", b(co["approval_bundle"])))

g = v["gatt_framing"]
re_ = b""
for i, f in enumerate(b(x) for x in g["frames"]):
    flags, seq = f[0], int.from_bytes(f[1:3], "big")
    check(f"GATT frame {i}: seq restarts at 0 per message, start/end flags",
          seq == i and bool(flags & 1) == (i == 0) and bool(flags & 2) == (i == len(g["frames"]) - 1))
    re_ += f[3:]
check("GATT frames reassemble to msg1", re_ == b(v["noise_nx"]["msg1"]))

env = v["envelope"]
for name in ["request_info", "request_reset_with_idem"]:
    check(f"CDDL request: {name}", cddl_ok("request", b(env[name])))
for name in ["response_info", "response_error_unsupported"]:
    check(f"CDDL response: {name}", cddl_ok("response", b(env[name])))
ch = v["chunking"]
c1, c2 = cbor2.loads(b(ch["chunk1"])), cbor2.loads(b(ch["chunk2"]))
check("chunks: same id, CDDL ok, reassemble to the body",
      c1[1] == c2[1] and cddl_ok("request", b(ch["chunk1"])) and cddl_ok("request", b(ch["chunk2"]))
      and c1[3] + c2[3] == b(ch["body"]))
# negative: msg-type / body mismatch, error + body together
check("CDDL rejects 'reset' with a claim/begin body",
      not cddl_ok("request", cbor2.dumps({0: [1, 0], 1: 1, 2: "reset", 3: {1: b(K["owner_sign_pub"])}})))
check("CDDL rejects claim/finish with a bad body",
      not cddl_ok("request", cbor2.dumps({0: [1, 0], 1: 1, 2: "claim/finish", 3: {1: "zzz"}})))
check("CDDL accepts unknown extra keys in a message body",
      cddl_ok("request", cbor2.dumps({0: [1, 0], 1: 1, 2: "info", 3: {42: 1}})))
# pycddl 0.6 accepts a value for a type choice even when every alternative rejects it, so check each one.
both = cbor2.dumps({1: 1, 4: 6, 3: {}, 5: {1: "lora"}})
check("CDDL: no response alternative accepts both body and error",
      not any(cddl_ok(r, both) for r in ["ok-response", "error-response", "chunk-response"]))

print(f"\n{count} checks: " + ("ALL PASSED" if not fails else f"{len(fails)} FAILED"))
sys.exit(1 if fails else 0)
