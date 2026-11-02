"""peer_core — the session layer of peer.py (docs/design/254-h23-harness.md §4.8): one connection to the node's
batman-provd as the provisioning app would make it (Noise initiator, GATT framing, request envelopes).

Implemented independently of provd: Noise = noiseprotocol (provd uses flynn/noise), CBOR = cbor2 + verify.det_dumps.
"""
import cbor2
from noise.connection import Keypair, NoiseConnection

import transport_sock as ts
import verify

NX = b"Noise_NX_25519_ChaChaPoly_SHA256"
NXPSK = b"Noise_NXpsk0_25519_ChaChaPoly_SHA256"


def prologue(hint=""):
    """219 §3.2: "batman-prov/1" 0 "ble" 0 device_hint."""
    return b"batman-prov/1\x00ble\x00" + hint.encode()


class ProtocolError(Exception):
    pass


class Peer:
    def __init__(self, t, frame=20):
        self.t, self.frame = t, frame
        self.r = ts.Reassembler()
        self.id, self.h, self.cert, self.noise, self.msg2 = 0, None, None, None, None

    def read_ctl(self, which):
        """CTRL / STATUS over the frame socket (before the handshake)."""
        self.t.send(bytes([which]))
        b = self.t.recv(5)
        if b[0] == ts.CTL_ERROR:
            return {"att_error": b[1]}
        if b[0] != which:
            raise ProtocolError("control reply 0x%02x" % b[0])
        return cbor2.loads(b[1:])

    def send_msg(self, m):
        for f in ts.split(m, self.frame):
            self.t.send(f)

    def recv_msg(self, timeout=10.0):
        while True:
            m = self.r.push(self.t.recv(timeout))
            if m is not None:
                return m

    def handshake(self, psk=None, hint="", e_priv=None):
        """True = the session opened; False = msg2 did not decrypt (the node's same-length decoy for a wrong key)."""
        c = NoiseConnection.from_name(NXPSK if psk else NX)
        c.set_as_initiator()
        c.set_prologue(prologue(hint))
        if psk:
            c.set_psks(psk)
        if e_priv:
            c.set_keypair_from_private_bytes(Keypair.EPHEMERAL, e_priv)
        c.start_handshake()
        self.send_msg(c.write_message(b""))
        self.msg2 = self.recv_msg()
        try:
            payload = c.read_message(self.msg2)
        except Exception:  # noqa: BLE001 — an unopened msg2 is a result, not a crash
            return False
        self.noise, self.h, self.cert = c, c.get_handshake_hash(), cbor2.loads(payload)
        return True

    def envelope(self, typ, body=None, extra=None):
        self.id += 1
        env = {0: [1, 0], 1: self.id, 2: typ, 3: body if body is not None else {}}
        env.update(extra or {})
        return verify.det_dumps(env)

    def send_env(self, raw):
        self.send_msg(self.noise.encrypt(raw))

    def recv_env(self, timeout=10.0):
        return cbor2.loads(self.noise.decrypt(self.recv_msg(timeout)))

    def request(self, typ, body=None, extra=None, timeout=10.0):
        """(status, body-or-error) of one request."""
        raw = self.envelope(typ, body, extra)
        self.last_env = raw
        self.send_env(raw)
        resp = self.recv_env(timeout)
        if resp.get(1) != self.id:
            raise ProtocolError("response id %r, request %d" % (resp.get(1), self.id))
        return resp.get(4), resp.get(3, resp.get(5))

    @property
    def device_id(self):
        return self.cert[7].hex()
