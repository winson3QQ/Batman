#!/usr/bin/env python3
"""tests/tools/peer/noise_responder.py — the node side of the Noise handshake, written with dissononce (the library
verify.py uses; the Rust core of the app uses snow, provd uses flynn/noise). For the live handshake of
docs/design/254-app-s1.md §8 item 5: the Rust core as initiator against this, on the host, with fresh ephemerals on
both sides. It is not a node and not an owner client: one handshake, one message each way.

  noise_responder.py <nx|nxpsk0> <prologue hex> <psk hex | -> <static priv hex> <msg2 payload hex>

The key material goes in argv (any local process can read it): only public test values belong there — the node static
key published in tests/vectors/219-protocol/vectors.json and a PSK made from a constant of the test. Never a real key.

stdin / stdout, one hex line each:
  in  msg1                     out msg2          (or "ERR <what>" and exit 1: msg1 did not read)
                               out handshake hash
  in  transport message        out its plaintext (or "ERR <what>" and exit 1)
                               out a transport message of our own: b"pong:" + that plaintext
"""
import sys

from dissononce.cipher.chachapoly import ChaChaPolyCipher
from dissononce.dh.x25519.private import PrivateKey as X25519Priv
from dissononce.dh.x25519.x25519 import X25519DH
from dissononce.hash.sha256 import SHA256Hash
from dissononce.processing.handshakepatterns.interactive.NX import NXHandshakePattern
from dissononce.processing.impl.cipherstate import CipherState
from dissononce.processing.impl.handshakestate import HandshakeState
from dissononce.processing.impl.symmetricstate import SymmetricState
from dissononce.processing.modifiers.psk import PSKPatternModifier


def out(s):
    sys.stdout.write(s + "\n")
    sys.stdout.flush()


def line():
    s = sys.stdin.readline()
    if not s.strip():
        out("ERR no input")
        sys.exit(1)
    return bytes.fromhex(s.strip())


def main(argv):
    if len(argv) != 6 or argv[1] not in ("nx", "nxpsk0"):
        sys.stderr.write(__doc__)
        return 2
    mode, prologue, payload = argv[1], bytes.fromhex(argv[2]), bytes.fromhex(argv[5])
    psk = None if argv[3] == "-" else bytes.fromhex(argv[3])
    if (mode == "nxpsk0") != (psk is not None):
        sys.stderr.write("nxpsk0 needs a psk, nx takes none\n")
        return 2
    dh = X25519DH()
    pattern = NXHandshakePattern()
    if psk is not None:
        pattern = PSKPatternModifier(0).modify(pattern)
    st = HandshakeState(SymmetricState(CipherState(ChaChaPolyCipher()), SHA256Hash()), dh)
    st.initialize(pattern, False, prologue, s=dh.generate_keypair(X25519Priv(bytes.fromhex(argv[4]))),
                  psks=[psk] if psk else None)
    try:
        st.read_message(line(), bytearray())
    except Exception as e:   # noqa: BLE001 — a msg1 made with another PSK / prologue is a refusal, not a crash
        out(f"ERR msg1 {type(e).__name__}")
        return 1
    buf = bytearray()
    recv, send = st.write_message(payload, buf)   # responder: (initiator -> responder, responder -> initiator)
    out(bytes(buf).hex())
    out(st.symmetricstate.get_handshake_hash().hex())
    try:
        pt = recv.decrypt_with_ad(b"", line())
    except Exception as e:   # noqa: BLE001
        out(f"ERR transport {type(e).__name__}")
        return 1
    out(bytes(pt).hex())
    out(bytes(send.encrypt_with_ad(b"", b"pong:" + bytes(pt))).hex())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
