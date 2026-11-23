"""scripts/dv/data/p3-accept.py — the payload generators' acceptance and the UD8c mutant (254-v16-ud.md §3.3), called
by p3-payloads.sh. python3 -I, stdlib only.

  p3-accept.py <kind> <V.tar.gz> <out>   kind = mal1 | mal2 | mal3 | mal4 | mutate | badpayload: the defined delta of
                                          that generator against V, and nothing else; "ACCEPT <kind> ok|FAIL" last
  p3-accept.py mutate-make <V> <out>      V's own tar stream with a region of root.squashfs past the superblock zeroed
                                          ("hsqs" kept, same size), deflated again; the file is made exactly V's length
                                          by a gzip FEXTRA field (2 B XLEN + data: a gap g = 0 or 2 <= g <= 65537)

Every output must also have SHA256SUMS and metadata as its first two members (the worker reads them by position,
updwork.go scan). A missing / empty output, a `tar -C dir .` repack and V itself fail every kind.
"""
import hashlib
import io
import os
import struct
import subprocess
import sys
import tarfile
import zlib

REG, SYM, DIR = tarfile.REGTYPE, tarfile.SYMTYPE, tarfile.DIRTYPE


def listing(p):
    with tarfile.open(p, "r:gz") as tf:
        return [(m.name, m.type, m.mode, m.size) for m in tf.getmembers()]


def data(p, name):
    with tarfile.open(p, "r:gz") as tf:
        return tf.extractfile(name).read()


def stream(p):
    """The first gzip member, decompressed, and what follows it."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    with open(p, "rb") as f:
        raw = f.read()
    return d.decompress(raw) + d.flush(), d.unused_data


def gzip_t(p):
    r = subprocess.run(["gzip", "-t", p], capture_output=True)
    return r.returncode, (r.stderr or b"").decode(errors="replace")


def accept(kind, vp, op):
    fails = []

    def ok(m):
        print("ok   " + m)

    def bad(m):
        print("FAIL " + m)
        fails.append(m)

    try:
        if not os.path.isfile(op) or os.path.getsize(op) == 0:
            raise ValueError("output %s missing or empty" % op)
        V, O = listing(vp), listing(op)
    except Exception as e:  # noqa: BLE001
        print("FAIL %s" % e)
        print("ACCEPT %s FAIL" % kind)
        return 1
    names = [x[0] for x in O]
    if names[:2] == ["SHA256SUMS", "metadata"]:
        ok("first two members SHA256SUMS, metadata")
    else:
        bad("first two members are %s" % names[:2])
    if kind == "mal1":
        d = [i for i in range(min(len(V), len(O))) if V[i] != O[i]]
        if len(V) == len(O) and len(d) == 1 and V[d[0]][0] == O[d[0]][0] and V[d[0]][1] == REG and O[d[0]][1] == SYM \
                and V[d[0]][0].startswith("boot/overlays/") and V[d[0]][0].endswith(".dtbo"):
            ok("exactly one member changed - -> l, same name: %s" % O[d[0]][0])
        else:
            bad("not exactly one dtbo turned into a symlink (diffs at %s, %d vs %d members)" % (d[:3], len(V), len(O)))
    elif kind == "mal2":
        if O[:-1] == V and O[-1][1] == REG and V[-1][0] == "root.squashfs":
            ok("exactly one extra regular member after root.squashfs: %s" % O[-1][0])
        else:
            bad("not V + one regular member after root.squashfs (%d vs %d members)" % (len(V), len(O)))
    elif kind == "mal3":
        sv, _ = stream(vp)
        so, tail = stream(op)
        if O == V:
            ok("listing identical")
        else:
            bad("listing differs")
        if so == sv:
            ok("the tar stream is V's, byte for byte")
        else:
            bad("the tar stream differs from V's")
        if os.path.getsize(op) == os.path.getsize(vp) + 4096 and len(tail) == 4096:
            ok("exactly 4096 bytes after the gzip stream")
        else:
            bad("size %d vs V %d + 4096 (trailing %d)" % (os.path.getsize(op), os.path.getsize(vp), len(tail)))
        rc, err = gzip_t(op)
        if "trailing garbage" in err:
            ok("gzip -t reports trailing garbage")
        else:
            bad("gzip -t: rc %d [%s]" % (rc, err.strip()))
    elif kind == "mal4":
        r = [i for i, x in enumerate(O) if x[0] == "root.squashfs"]
        if len(O) == len(V) + 1 and r and O[:r[0] - 1] + O[r[0]:] == V and O[r[0] - 1][0].rstrip("/") == "boot/overlays" \
                and O[r[0] - 1][1] == DIR:
            ok("exactly one extra boot/overlays/ directory entry, just before root.squashfs")
        else:
            bad("not V + one boot/overlays/ directory entry before root.squashfs (%d vs %d members)" % (len(V), len(O)))
    elif kind in ("mutate", "badpayload"):
        if O == V:
            ok("listing identical (names, order, types, modes, sizes)")
        else:
            bad("listing differs from V's")
        if O == V:
            rv, ro = data(vp, "root.squashfs"), data(op, "root.squashfs")
            if hashlib.sha256(rv).digest() != hashlib.sha256(ro).digest() and ro[:4] == b"hsqs" and len(ro) == len(rv):
                ok("root.squashfs: sha differs from V's, hsqs kept, same size")
            else:
                bad("root.squashfs: same sha as V, or magic / size changed")
            sv, so = data(vp, "SHA256SUMS"), data(op, "SHA256SUMS")
            if kind == "mutate":
                same = all(data(vp, n) == data(op, n) for n, t, _, _ in V if t == REG and n != "root.squashfs")
                if same:
                    ok("SHA256SUMS, metadata and boot/* byte-identical")
                else:
                    bad("a member other than root.squashfs changed")
                if os.path.getsize(op) == os.path.getsize(vp):
                    ok("same total length as V (%d)" % os.path.getsize(op))
                else:
                    bad("length %d != V's %d" % (os.path.getsize(op), os.path.getsize(vp)))
                rc, err = gzip_t(op)
                if rc == 0 and not err.strip():
                    ok("gzip -t ok")
                else:
                    bad("gzip -t: rc %d [%s]" % (rc, err.strip()))
            else:
                lv, lo = sv.decode().splitlines(), so.decode().splitlines()
                nr = hashlib.sha256(ro).hexdigest()
                kept = [x for x in lv if not x.endswith("  root.squashfs")] == [x for x in lo if not x.endswith("  root.squashfs")]
                if ("%s  root.squashfs" % nr) in lo and kept and len(lv) == len(lo):
                    ok("SHA256SUMS: the root.squashfs line updated, every other line kept")
                else:
                    bad("SHA256SUMS: root line not updated or other lines changed")
                if hashlib.sha256(sv).digest() != hashlib.sha256(so).digest():
                    ok("sums_sha differs from V's (UD20c's Y)")
                else:
                    bad("sums_sha equals V's")
    else:
        bad("unknown kind %s" % kind)
    print("ACCEPT %s %s" % (kind, "FAIL" if fails else "ok"))
    return 1 if fails else 0


def mutate_make(vp, op):
    raw = open(vp, "rb").read()
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    s0 = d.decompress(raw) + d.flush()
    if d.unused_data:
        sys.exit("V has data after its gzip stream")
    with tarfile.open(fileobj=io.BytesIO(s0)) as tf:
        m = tf.getmember("root.squashfs")
        off, size = m.offset_data, m.size
    if s0[off:off + 4] != b"hsqs" or size < 64 << 10:
        sys.exit("root.squashfs: no hsqs, or smaller than 64 KiB")
    L = len(raw)
    start = off + max(4096, size // 4)
    room = off + size - start

    def gz(z, extra=None):   # extra = the FEXTRA data (b"" is a field of 2 B: XLEN 0); None = no field
        s = bytearray(s0)
        s[start:start + z] = bytes(z)
        s = bytes(s)
        c = zlib.compressobj(9, zlib.DEFLATED, -15)
        body = c.compress(s) + c.flush()
        hdr = b"\x1f\x8b\x08" + bytes([4 if extra is not None else 0]) + b"\0\0\0\0" + b"\x02\x03"
        if extra is not None:
            hdr += struct.pack("<H", len(extra)) + extra
        return hdr + body + struct.pack("<II", zlib.crc32(s) & 0xffffffff, len(s) & 0xffffffff)

    # the target is a gap of at least 2 B (an FEXTRA field costs 2 B + data, so a gap of exactly 1 B cannot be filled —
    # aiming at <= L - 2 instead of <= L: 1 in 40 offline runs landed on gap 1 and FAILed, 2026-11-23)
    T = L - 2
    if len(gz(room)) > T:
        sys.exit("even zeroing %d bytes leaves the stream longer than V - 2" % room)
    lo, hi = 0, room
    while lo < hi:
        mid = (lo + hi) // 2
        if len(gz(mid)) <= T:
            hi = mid
        else:
            lo = mid + 1
    out = None
    for z in range(lo, min(lo + 4096, room) + 1):   # the deflate length is not strictly monotone in z: step on
        g = L - len(gz(z))
        if g == 0:
            out = gz(z)
        elif 2 <= g <= 65537:
            out = gz(z, b"\0" * (g - 2))
        if out is not None:
            break
    if out is None or len(out) != L:
        sys.exit("no zeroed length gives a gap of 0 or 2..65537 bytes")
    with open(op, "wb") as f:
        f.write(out)
    print("ok   root.squashfs: %d bytes zeroed at +%d, gap %d B filled with FEXTRA" % (z, start - off, g))
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "mutate-make":
        sys.exit(mutate_make(sys.argv[2], sys.argv[3]))
    if len(sys.argv) != 4:
        sys.exit("usage: p3-accept.py <kind> <V> <out> | mutate-make <V> <out>")
    sys.exit(accept(*sys.argv[1:4]))
