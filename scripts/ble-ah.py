#!/usr/bin/env python3
"""scripts/ble-ah.py — resolve BLE resolvable private addresses against a node's IRK (#254 PR-H1 §4.8).

    ble-ah.py --selftest
    <node> ble-periph-254.sh irk | ble-ah.py <addr> [<addr> ...]

The IRK is read from STDIN only (one line, 32 hex = the string BlueZ stores in /var/lib/bluetooth/<a>/identity),
so it never appears in argv, a file or a log. Nothing read from stdin is ever printed, not even on a parse error.
BlueZ stores the IRK least-significant byte first; ah() (Core spec Vol 3 Part H §2.2.2) takes it MSB first, so
the string is byte-reversed before use (the PR-F air test matched only that way).

Output per address: "<addr> rpa=<yes|no> match=<yes|no>". rpa = the two top bits are 01.
Exit 0 = every address is an RPA that resolves; 1 = at least one does not; 2 = bad input or self-test failure.
"""
import re
import sys

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
except ImportError:
    print("ble-ah: the Python module 'cryptography' is missing (DV_PY must point at the venv)")
    sys.exit(2)

ADDR = re.compile(r"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$")


def e(key: bytes, pt: bytes) -> bytes:
    c = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return c.update(pt) + c.finalize()


def ah(irk_msb: bytes, prand: bytes) -> bytes:
    return e(irk_msb, bytes(13) + prand)[-3:]


def irk_from_identity_string(s: str) -> bytes:
    """BlueZ identity-file string (LSB first) -> MSB-first IRK for ah()."""
    return bytes.fromhex(s)[::-1]


def resolve(irk_msb: bytes, addr: str):
    a = bytes.fromhex(addr.replace(":", ""))        # as printed: MSB first
    prand, hsh = a[:3], a[3:]
    is_rpa = (a[0] >> 6) == 0b01
    return is_rpa, is_rpa and ah(irk_msb, prand) == hsh


def make_rpa(irk_msb: bytes, prand_low22: int) -> str:
    prand = bytes([0x40 | ((prand_low22 >> 16) & 0x3F), (prand_low22 >> 8) & 0xFF, prand_low22 & 0xFF])
    return ":".join(f"{x:02X}" for x in prand + ah(irk_msb, prand))


def selftest() -> bool:
    ok = True
    # Core spec Vol 3 Part H appendix D.7: IRK ec0234a357c8ad05341010a60a397d9b, prand 708194 -> 0dfbaa
    spec = ah(bytes.fromhex("ec0234a357c8ad05341010a60a397d9b"), bytes.fromhex("708194"))
    print(f"selftest spec vector: {'ok' if spec.hex() == '0dfbaa' else 'MISMATCH'}")
    ok &= spec.hex() == "0dfbaa"
    # Synthetic, through the identity-file parse path (fake IRK — never a real one)
    fake_identity = bytes(range(0x10, 0x20)).hex()                 # built at run time: no key-shaped literal in the repo
    irk = irk_from_identity_string(fake_identity)
    addr = make_rpa(irk, 0x123456)
    r1 = resolve(irk_from_identity_string(fake_identity), addr)
    flipped = addr[:-1] + format(int(addr[-1], 16) ^ 1, "X")
    r2 = resolve(irk_from_identity_string(fake_identity), flipped)
    wrong_order = resolve(bytes.fromhex(fake_identity), addr)       # forgetting the byte reversal must NOT match
    static = resolve(irk, "C" + addr[1:])                           # top bits 11 = static random, not an RPA
    for name, got, want in (("synthetic RPA resolves", r1, (True, True)),
                            ("one flipped bit does not", r2, (True, False)),
                            ("unreversed IRK does not", wrong_order, (True, False)),
                            ("static random is not an RPA", static, (False, False))):
        print(f"selftest {name}: {'ok' if got == want else 'MISMATCH'}")
        ok &= got == want
    return ok


def main() -> int:
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return 0 if selftest() else 2
    if not args or not all(ADDR.match(a) for a in args):
        print("usage: ble-ah.py --selftest | ble-ah.py <AA:BB:CC:DD:EE:FF>... (IRK on stdin)")
        return 2
    line = sys.stdin.readline().strip()
    if not re.fullmatch(r"[0-9A-Fa-f]{32}", line):
        print("ble-ah: stdin did not carry exactly one 32-hex IRK line (content not shown)")
        return 2
    irk = irk_from_identity_string(line)
    del line
    rc = 0
    for a in args:
        is_rpa, match = resolve(irk, a)
        print(f"{a.upper()} rpa={'yes' if is_rpa else 'no'} match={'yes' if match else 'no'}")
        rc |= 0 if match else 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
