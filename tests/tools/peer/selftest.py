"""peer.py --selftest: peer_core / owner against the vectors (gen.py's transcript, byte for byte). A loopback
"transport" plays the vector's node side: it answers msg1 with the vector msg2. Prints "<n> checks: ALL PASSED";
exit 1 on any failure (CI requires n >= MIN)."""
import cbor2
import ecdsa

import owner
import peer_core
import transport_sock as ts
import verify


class Loop:
    """Feeds back prepared frames; records what was sent."""

    def __init__(self, replies):
        self.sent, self.q = [], list(replies)
        self.frame_limit = ts.MAX_FRAME

    def send(self, pkt):
        self.sent.append(pkt)

    def recv(self, timeout=0):
        if not self.q:
            raise ts.Closed("loop empty")
        return self.q.pop(0)


def run(path=None):
    v = verify.load_vectors(path)
    b = bytes.fromhex
    K = v["keys"]
    n, fails = 0, []

    def check(name, cond):
        nonlocal n
        n += 1
        print(("PASS " if cond else "FAIL ") + name)
        if not cond:
            fails.append(name)

    req_info = b(v["envelope"]["request_info"])
    for tag, key, psk, hint in [("NX", "noise_nx", None, K["device_id"]),
                                ("NXpsk0 owner", "noise_nxpsk0_owner", b(v["hkdf"]["psk_owner"]), ""),
                                ("NXpsk0 replay", "noise_nxpsk0_replay", b(v["psk_replay"]["psk_replay"]), "")]:
        vec = v[key]
        check(f"{tag}: prologue", peer_core.prologue(hint) == b(vec["prologue"]))
        lp = Loop(ts.split(b(vec["msg2"]), 244))
        p = peer_core.Peer(lp, frame=244)
        ok = p.handshake(psk, hint, e_priv=b(K["phone_ephemeral_priv"]))
        check(f"{tag}: msg1 byte-identical", b"".join(f[3:] for f in lp.sent) == b(vec["msg1"]))
        check(f"{tag}: msg2 opens", ok)
        if not ok:
            continue
        check(f"{tag}: node_cert payload", verify.det_dumps(p.cert) == b(v["node_cert"]["cbor"]))
        check(f"{tag}: handshake hash", p.h == b(vec["handshake_hash"]))
        lp.sent.clear()
        p.send_env(req_info)
        check(f"{tag}: first transport message", b"".join(f[3:] for f in lp.sent) == b(vec["first_transport_message"]))
    # a wrong PSK: msg2 does not open (reported, not raised)
    lp = Loop(ts.split(b(v["noise_nxpsk0_owner"]["msg2"]), 244))
    check("wrong PSK: msg2 does not open", not peer_core.Peer(lp).handshake(b(v["hkdf"]["psk_member"])))
    # framing
    fr = ts.split(b(v["noise_nx"]["msg1"]), v["gatt_framing"]["frame_limit"])
    check("GATT frames == vector", [f.hex() for f in fr] == v["gatt_framing"]["frames"])
    r = ts.Reassembler()
    check("GATT reassembly", [r.push(f) for f in fr][-1] == b(v["noise_nx"]["msg1"]))
    # envelope encoding
    p = peer_core.Peer(Loop([]))
    check("request_info envelope", p.envelope("info") == req_info)
    # owner computations
    c = v["claim_checkmac"]
    chal = owner.client_chal(b(c["nonce"]), b(v["noise_nx"]["handshake_hash"]), b(K["dac_cert_der"]), b(K["owner_sign_pub"]))
    check("ClientChal", chal.hex() == c["client_chal"])
    check("CheckMac response", owner.checkmac_response(b(K["claim_secret"]), chal, b(K["sn"])).hex() == c["response"])
    st = {"tag_key": K["owner_tag_key"], "device_id": K["device_id"]}
    check("psk_owner", owner.psk_owner(st).hex() == v["hkdf"]["psk_owner"])
    # signatures verify under verify.py's independent check, and are low-s
    sk = ecdsa.SigningKey.generate(curve=ecdsa.NIST256p)
    h = b(v["noise_nxpsk0_owner"]["handshake_hash"])
    ab = owner.auth_owner_body(sk, h)
    check("auth/owner signature verifies (verify.es256_ok)",
          verify.es256_ok(owner.pub65(sk), b"batman-owner-auth-v1" + h + ab[1], ab[2]))
    check("signature is low-s", int.from_bytes(ab[2][32:], "big") <= owner.N // 2)
    body = {1: [b"x"]}
    op = owner.owner_op(sk, h, bytes(32), "network/update", body)
    ah = owner.H(verify.det_dumps(body))
    check("owner-op signature verifies", verify.es256_ok(owner.pub65(sk), verify.op_input(h, bytes(32), "network/update", ah), op[2]))
    check("STATUS examples", cbor2.loads(b(v["status_public"]["unclaimed"]))[5] == K["device_id"][-4:])
    print(f"{n} checks: " + ("ALL PASSED" if not fails else f"{len(fails)} FAILED"))
    return 0 if not fails else 1
