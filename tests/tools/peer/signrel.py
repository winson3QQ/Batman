"""signrel — the harness's TEST release signer (docs/design/254-h4-harness.md §8.1; P3 254-p3-impl.md §3.7.1–§3.7.2,
§3.7.4; 219-protocol.cddl `update-manifest`). It makes what a release build makes, with TEST keys only:

  T       test root        (the product trusts it only in prov_test builds; a release image must never contain it)
  K_test  test signing key (endorsed by T)
  other   a signing key T did NOT endorse (negative objects)

The private keys are derived deterministically from fixed names (netobj._vector_key), so CI recomputes them and no key
file is committed; tests/keys/*.pub hold only the 65 B public points.

  E = COSE_Sign1(T), content type batman/relkey,  label batman-relkey-v1,  payload {1: K pub 65 B, 2: serial}
  S = COSE_Sign1(K), content type batman/release, label batman-release-v1, payload {1 version, 2 board, 3 payload
      size, 4 sha256(SHA256SUMS), ?6 downgrade-from, ?7 min_from, ?8 bootcfg sums, 9 boot total}
  update-manifest = {1..4, 6 as in S, 5: bstr(CBOR [E, S])}

  signrel.py <payload.tar.gz> --board B [--serial N] [--downgrade-from v ...] [--min-from v] [--bootcfg-sha h ...]
             [--key other] [--bad-sig] [--mismatch-size N] [--wrong-board] [--unparsable-version]
             [--out DIR] [--print-hex]
  signrel.py --verify manifest.cbor [--root T.pub] [--board B]      the harness's own judge (independent parse)
  signrel.py --write-pubs DIR                                        write T.pub / K_test.pub
  signrel.py --selftest

Output is deterministic for the same inputs (canonical CBOR, RFC 6979 nonces via netobj.es256).
The selftest prints the `signrel selftest: N checks, 0 failed` line the module loop in scripts/test-h4-offline-254.sh
and .github/workflows/ci.yml match on; `signrel` still has to be added to those two lists (not done here).
"""
import argparse
import hashlib
import os
import pathlib
import re
import sys
import tarfile

import cbor2
import ecdsa

import netobj

LABEL_RELKEY = b"batman-relkey-v1"
LABEL_RELEASE = b"batman-release-v1"
CTYPE_RELKEY = "batman/relkey"
CTYPE_RELEASE = "batman/release"
KEY_NAMES = {"T": "release-root-T", "K_test": "release-key-K_test", "other": "release-key-other"}
# ⚠️ design: BATMAN_VERSION grammar is given by example only (`1.5.14-wsl.2+f2f2bf6.fw9d87d02`; "1.5.14-wsl" = no
# build N = unparsable; "+..." ignored) — this regex is the simplest reading of P3 §3.7.1.
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+-[A-Za-z0-9]+\.\d+(\+[A-Za-z0-9.]+)?$")
KEYS_DIR = pathlib.Path(__file__).resolve().parents[2] / "keys"


def key(name):
    """The test private key for T / K_test / other (deterministic; never printed)."""
    return netobj._vector_key(KEY_NAMES[name])


def pub(name):
    return netobj.pub65(key(name))


# ---- payload ----

def read_payload(path):
    """SHA256SUMS bytes, metadata dict, boot members' total size — via tarfile, members taken by name (P3 F57)."""
    boot_total, sums, meta = 0, None, {}
    with tarfile.open(path, "r:gz") as tf:
        for m in tf.getmembers():
            if m.name == "SHA256SUMS" and m.isreg():
                sums = tf.extractfile(m).read()
            elif m.name == "metadata" and m.isreg():
                for line in tf.extractfile(m).read().decode().splitlines():
                    if "=" in line:
                        k, v = line.split("=", 1)
                        meta[k.strip()] = v.strip()
            elif m.name.startswith("boot/") and m.isreg():
                # ⚠️ design: key 9 counted as the sum of every regular `boot/` member's tar size (P3 §3.7.5 step 4 only
                # says "boot 成員累計 ≤ key 9"); not restricted to the ones listed in SHA256SUMS.
                boot_total += m.size
    if sums is None:
        raise SystemExit("signrel: payload has no SHA256SUMS member")
    return sums, meta, boot_total


def unparsable(version):
    """Drop the build N (`1.5.14-wsl.2+x` -> `1.5.14-wsl+x`); append `-bad` if there was none."""
    v, n = re.subn(r"^(\d+\.\d+\.\d+-[A-Za-z0-9]+)\.\d+", r"\1", version)
    return v if n else version + "-bad"


# ---- signing ----

def endorse(serial, k_name="K_test"):
    return netobj.sign1(key("T"), netobj.cb({1: pub(k_name), 2: serial}), CTYPE_RELKEY, LABEL_RELKEY)


def release_fields(version, board, size, sums_sha, boot_total, downgrade_from=(), min_from=None, bootcfg=()):
    f = {1: version, 2: board, 3: size, 4: sums_sha, 9: boot_total}
    if downgrade_from:
        f[6] = list(downgrade_from)
    if min_from:
        f[7] = min_from
    if bootcfg:
        # ⚠️ design: key 8 omitted when empty ("空 = 不檢查" — absent and [] read the same; absent is simplest).
        f[8] = list(bootcfg)
    return f


def release(k_name, fields):
    return netobj.sign1(key(k_name), netobj.cb(fields), CTYPE_RELEASE, LABEL_RELEASE)


def flip_sig(s_raw):
    """Flip one byte of the COSE_Sign1 signature (negative object; everything else unchanged)."""
    prot, unprot, payload, sig = cbor2.loads(s_raw).value
    sig = sig[:-1] + bytes([sig[-1] ^ 0x01])
    return cbor2.dumps(cbor2.CBORTag(18, [prot, unprot, payload, sig]), canonical=True)


def manifest(e_raw, s_raw, fields, size_override=None):
    m = {k: fields[k] for k in (1, 2, 3, 4, 6) if k in fields}
    if size_override is not None:
        m[3] = size_override
    # ⚠️ design: key 5 = CBOR array of two bstr (each the encoded COSE_Sign1), "CBOR [E_i, S] 的編碼" (P3 §3.7.1).
    m[5] = netobj.cb([e_raw, s_raw])
    return netobj.cb(m)


def build(args):
    """Returns (E, S, manifest bytes, fields)."""
    sums, meta, boot_total = read_payload(args.payload)
    board = args.board or meta.get("board")
    if not board:
        raise SystemExit("signrel: no board (--board or metadata board=)")
    version = meta.get("release") or args.version
    if not version:
        raise SystemExit("signrel: no version (metadata release= or --version)")
    if args.unparsable_version:
        version = unparsable(version)
    if args.wrong_board:
        board = board + "-wrong"
    # ⚠️ design: key 3 = byte size of the .tar.gz file as given (P3 §3.7.1 "壓縮後的 .tar.gz").
    size = os.path.getsize(args.payload)
    fields = release_fields(version, board, size, netobj.H(sums), boot_total,
                            args.downgrade_from, args.min_from, [bytes.fromhex(h) for h in args.bootcfg_sha])
    e = endorse(args.serial)
    s = release(args.key, fields)
    if args.bad_sig:
        s = flip_sig(s)
    return e, s, manifest(e, s, fields, args.mismatch_size), fields


def write_out(outdir, e, s, m):
    d = pathlib.Path(outdir)
    d.mkdir(parents=True, exist_ok=True)
    (d / "E.cbor").write_bytes(e)
    (d / "S.cbor").write_bytes(s)
    (d / "manifest.cbor").write_bytes(m)
    (d / "manifest.hex").write_text(m.hex() + "\n")


# ---- verify (the judge: its own parse, `ecdsa` not `cryptography`) ----

class Bad(Exception):
    pass


def _open_sign1(raw, ctype, label, pub65):
    """Parse a COSE_Sign1 by hand and check its ES256 signature with the `ecdsa` package; returns the payload bytes."""
    try:
        t = cbor2.loads(raw)
    except Exception:  # noqa: BLE001
        raise Bad("%s: not CBOR" % ctype) from None
    if not isinstance(t, cbor2.CBORTag) or t.tag != 18 or not isinstance(t.value, (list, tuple)) or len(t.value) != 4:
        raise Bad("%s: not a COSE_Sign1" % ctype)
    prot, unprot, payload, sig = t.value
    if not all(isinstance(x, bytes) for x in (prot, payload, sig)) or unprot != {}:
        raise Bad("%s: bad COSE_Sign1 fields" % ctype)
    if cbor2.loads(prot) != {1: -7, 3: ctype}:
        raise Bad("%s: protected header is not {alg ES256, content type %s}" % (ctype, ctype))
    if len(sig) != 64 or int.from_bytes(sig[32:], "big") > netobj.P256_N // 2:
        raise Bad("%s: signature is not 64 B low-s" % ctype)
    to_be_signed = cbor2.dumps(["Signature1", prot, label, payload], canonical=True)
    try:
        vk = ecdsa.VerifyingKey.from_string(pub65, curve=ecdsa.NIST256p)
        vk.verify_digest(sig, hashlib.sha256(to_be_signed).digest())
    except Exception:  # noqa: BLE001 — any failure is "does not verify"
        raise Bad("%s: signature does not verify" % ctype) from None
    return payload


def verify(m_raw, root_pub65, board=None):
    """Raises Bad(why); returns the decoded S fields on success."""
    try:
        m = cbor2.loads(m_raw)
    except Exception:  # noqa: BLE001
        raise Bad("manifest: not CBOR") from None
    if not isinstance(m, dict) or not isinstance(m.get(5), bytes):
        raise Bad("manifest: no key 5")
    pair = cbor2.loads(m[5])
    if not isinstance(pair, list) or len(pair) != 2 or not all(isinstance(x, bytes) for x in pair):
        raise Bad("manifest key 5: not [E, S]")
    e_pl = cbor2.loads(_open_sign1(pair[0], CTYPE_RELKEY, LABEL_RELKEY, root_pub65))
    if not isinstance(e_pl, dict) or not isinstance(e_pl.get(1), bytes) or len(e_pl[1]) != 65:
        raise Bad("E: payload has no 65 B key")
    if not isinstance(e_pl.get(2), int) or e_pl[2] < 1:
        raise Bad("E: serial is not a uint >= 1")
    s_pl = cbor2.loads(_open_sign1(pair[1], CTYPE_RELEASE, LABEL_RELEASE, e_pl[1]))
    for k in (1, 2, 3, 4, 6):
        if m.get(k) != s_pl.get(k):
            raise Bad("manifest key %d != S" % k)
    if not isinstance(s_pl.get(1), str) or not VERSION_RE.match(s_pl[1]):
        raise Bad("S: version unparsable (%r)" % s_pl.get(1))
    if board is not None and s_pl.get(2) != board:
        raise Bad("S: board %r != %r" % (s_pl.get(2), board))
    return s_pl


def read_pub(path):
    return bytes.fromhex(pathlib.Path(path).read_text().strip())


# ---- selftest ----

def _fake_payload(d, board="rpi-4", release="1.5.14-wsl.2+f2f2bf6.fw9d87d02"):
    import io
    files = {"boot/config.txt": b"arm_64bit=1\n", "boot/distroconfig.txt": b"# dc\n", "root.squashfs": b"hsqs" + bytes(60)}
    sums = "".join("%s  %s\n" % (netobj.H(v).hex(), k) for k, v in sorted(files.items())).encode()
    meta = ("board=%s\nversion=20261107-000000\nsize=%d\nrelease=%s\n" % (board, len(files["root.squashfs"]), release)).encode()
    p = pathlib.Path(d) / "payload.tar.gz"
    with tarfile.open(p, "w:gz") as tf:
        for name, data in [("SHA256SUMS", sums), ("metadata", meta)] + sorted(files.items()):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime = len(data), 0
            tf.addfile(ti, io.BytesIO(data))
    return p, sums


def _args(payload, **kw):
    a = parse([str(payload)])
    for k, v in kw.items():
        setattr(a, k, v)
    return a


def selftest():
    import tempfile
    n, fails = 0, []

    def check(name, cond):
        nonlocal n
        n += 1
        print(("PASS " if cond else "FAIL ") + name)
        if not cond:
            fails.append(name)

    def expect_fail(name, m, why, board=None):
        try:
            verify(m, pub("T"), board)
            check("negative: %s -> FAIL" % name, False)
        except Bad as b:
            check("negative: %s -> FAIL (%s)" % (name, b), why in str(b))

    with tempfile.TemporaryDirectory() as d:
        p, sums = _fake_payload(d)
        e, s, m, f = build(_args(p, bootcfg_sha=[netobj.H(b"cfg").hex()], downgrade_from=["1.5.15-wsl.1"], min_from="1.5.10-wsl.1"))
        s_pl = verify(m, pub("T"), "rpi-4")
        check("positive: verify ok", s_pl[1] == "1.5.14-wsl.2+f2f2bf6.fw9d87d02")
        check("S key 3 = tar.gz size", s_pl[3] == os.path.getsize(p))
        check("S key 4 = sha256(SHA256SUMS)", s_pl[4] == netobj.H(sums))
        check("S key 9 = boot total", s_pl[9] == len(b"arm_64bit=1\n") + len(b"# dc\n"))
        check("S keys 6/7/8 carried", s_pl[6] == ["1.5.15-wsl.1"] and s_pl[7] == "1.5.10-wsl.1" and s_pl[8] == [netobj.H(b"cfg")])
        check("manifest has no key 7/8/9", not any(k in cbor2.loads(m) for k in (7, 8, 9)))
        check("deterministic: same inputs -> same bytes", build(_args(p, bootcfg_sha=[netobj.H(b"cfg").hex()],
              downgrade_from=["1.5.15-wsl.1"], min_from="1.5.10-wsl.1"))[2] == m)
        check("E serial default 2", cbor2.loads(cbor2.loads(e).value[2])[2] == 2)
        e1 = build(_args(p, serial=1))[0]
        check("--serial 1 -> E serial 1 (still verifies: min-serial is the node's rule)",
              cbor2.loads(cbor2.loads(e1).value[2])[2] == 1 and verify(build(_args(p, serial=1))[2], pub("T")) is not None)
        expect_fail("--key other", build(_args(p, key="other"))[2], "batman/release: signature does not verify")
        expect_fail("--bad-sig", build(_args(p, bad_sig=True))[2], "batman/release: signature does not verify")
        expect_fail("--mismatch-size", build(_args(p, mismatch_size=7))[2], "manifest key 3 != S")
        expect_fail("--wrong-board", build(_args(p, wrong_board=True))[2], "board 'rpi-4-wrong' != 'rpi-4'", "rpi-4")
        expect_fail("--unparsable-version", build(_args(p, unparsable_version=True))[2], "version unparsable")
        try:
            verify(m, pub("other"))
            check("negative: another root -> FAIL", False)
        except Bad as b:
            check("negative: another root -> FAIL (%s)" % b, "batman/relkey: signature does not verify" in str(b))
        if (KEYS_DIR / "T.pub").exists():
            check("tests/keys/T.pub = derived T", read_pub(KEYS_DIR / "T.pub") == pub("T"))
            check("tests/keys/K_test.pub = derived K_test", read_pub(KEYS_DIR / "K_test.pub") == pub("K_test"))
    print("signrel: pass=%d fail=%d" % (n - len(fails), len(fails)))
    print("signrel selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


# ---- CLI ----

def parse(argv):
    ap = argparse.ArgumentParser(prog="signrel.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("payload", nargs="?", help="payload .tar.gz")
    ap.add_argument("--board")
    ap.add_argument("--version", help="used only when metadata has no release=")
    ap.add_argument("--serial", type=int, default=2)
    ap.add_argument("--downgrade-from", nargs="*", default=[], metavar="V")
    ap.add_argument("--min-from", metavar="V")
    ap.add_argument("--bootcfg-sha", nargs="*", default=[], metavar="HEX")
    ap.add_argument("--key", choices=["K_test", "other"], default="K_test")
    ap.add_argument("--bad-sig", action="store_true")
    ap.add_argument("--mismatch-size", type=int, metavar="N")
    ap.add_argument("--wrong-board", action="store_true")
    ap.add_argument("--unparsable-version", action="store_true")
    ap.add_argument("--out", metavar="DIR")
    ap.add_argument("--print-hex", action="store_true")
    ap.add_argument("--verify", metavar="MANIFEST.cbor")
    ap.add_argument("--root", default=str(KEYS_DIR / "T.pub"))
    ap.add_argument("--write-pubs", metavar="DIR")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.serial < 1:
        ap.error("--serial must be >= 1")
    return a


def main(argv):
    a = parse(argv)
    if a.selftest:
        return selftest()
    if a.write_pubs:
        d = pathlib.Path(a.write_pubs)
        d.mkdir(parents=True, exist_ok=True)
        for name in ("T", "K_test"):
            (d / (name + ".pub")).write_text(pub(name).hex() + "\n")
        print("wrote %s/T.pub %s/K_test.pub" % (d, d))
        return 0
    if a.verify:
        try:
            s = verify(pathlib.Path(a.verify).read_bytes(), read_pub(a.root), a.board)
        except Bad as b:
            print("VERIFY FAIL %s" % b)
            return 1
        print("VERIFY ok version=%s board=%s size=%d" % (s[1], s[2], s[3]))
        return 0
    if not a.payload:
        print("signrel: payload, --verify, --write-pubs or --selftest required", file=sys.stderr)
        return 2
    e, s, m, f = build(a)
    if a.out:
        write_out(a.out, e, s, m)
    if a.print_hex:
        print(m.hex())
    else:
        print("MANIFEST sha=%s version=%s board=%s size=%d serial=%d" % (netobj.H(m).hex()[:16], f[1], f[2], f[3], a.serial))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
