"""benchstore — the harness's own key store for the bench baseline S0-pre / S0 (docs/design/254-h4-harness.md §3.2).

Layout (WSL ext4, so the mode bits hold):
  ~/.batman-dv/bench/                 0700   S0: kept across runs
      node-<name>.json                0600   DAC (DER hex), device_id, eth MAC, ssh host key, owners, tag keys, ...
      net-<name>.json                 0600   net_root, net_id, version, SAE key, net_config (hex), C0 / ALT
      owner-<name>.pem                0600   an owner signing key (H0, H0b)
      journal.cbor                    0600   append-only intent / applied records, fsync'd before the node is touched
  ~/.batman-dv/bench/run/<run>/       0700   per-run scope (Hx, HF, snapshot-scoped actions): deleted at run end

Writes are atomic (tmp + fsync + rename + fsync of the directory). Secrets never leave this module except as the
values a caller asked for; nothing here prints a secret (callers print short()).

Journal (§3.2): before an action that rotates a node-side secret, append {"t": time, "op": ..., "node": ...,
"intent": {...new values...}} and fsync; after the node confirmed, append {"op": ..., "applied": seq}. pending()
lists intents with no applied record — the next run tries both the old and the new values for them.
"""
import json
import os
import pathlib
import stat
import time

import cbor2

DEFAULT = pathlib.Path.home() / ".batman-dv" / "bench"


class StoreError(Exception):
    pass


class Store:
    def __init__(self, root=None):
        self.root = pathlib.Path(root or DEFAULT)

    # ---- directory / file safety ----
    def _ensure_dir(self, d):
        d.mkdir(mode=0o700, parents=True, exist_ok=True)
        st = d.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
            raise StoreError("%s is not a private (0700, mine, not a symlink) directory" % d)

    def _write(self, path, data):
        self._ensure_dir(path.parent)
        tmp = path.with_name(".%s.tmp%d" % (path.name, os.getpid()))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)

    def _read(self, path):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
                raise StoreError("%s is not a private regular file" % path)
            return os.read(fd, st.st_size + 1)
        finally:
            os.close(fd)

    # ---- records ----
    def get(self, kind, name, run=None):
        b = self._read(self._path(kind, name, run))
        return json.loads(b) if b is not None else None

    def put(self, kind, name, rec, run=None):
        self._write(self._path(kind, name, run), json.dumps(rec, sort_keys=True).encode())

    def _path(self, kind, name, run):
        if kind not in ("node", "net", "owner") or not name.replace("-", "").isalnum():
            raise StoreError("bad record name %s/%s" % (kind, name))
        base = self.root / "run" / run if run else self.root
        return base / ("%s-%s.json" % (kind, name))

    def drop_run(self, run):
        d = self.root / "run" / run
        if d.is_dir() and not d.is_symlink():
            for f in d.iterdir():
                f.unlink()
            d.rmdir()

    # ---- journal ----
    def _journal(self):
        return self.root / "journal.cbor"

    def journal(self):
        b = self._read(self._journal())
        out, rest = [], b or b""
        while rest:
            obj, n = _one(rest)
            out.append(obj)
            rest = rest[n:]
        return out

    def intend(self, op, node, intent):
        """Append an intent BEFORE touching the node; returns its sequence number."""
        seq = len(self.journal())
        self._append({"seq": seq, "t": int(time.time()), "op": op, "node": node, "intent": intent})
        return seq

    def applied(self, seq):
        self._append({"t": int(time.time()), "applied": seq})

    def pending(self):
        j = self.journal()
        done = {r["applied"] for r in j if "applied" in r}
        return [r for r in j if "intent" in r and r["seq"] not in done]

    def _append(self, rec):
        self._ensure_dir(self.root)
        fd = os.open(self._journal(), os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, cbor2.dumps(rec))
            os.fsync(fd)
        finally:
            os.close(fd)


def _one(buf):
    """Decode one CBOR item from buf; return (obj, bytes used)."""
    import io
    f = io.BytesIO(buf)
    obj = cbor2.CBORDecoder(f).decode()
    return obj, f.tell()


def selftest():
    import tempfile
    fails, n = [], 0

    def check(name, cond):
        nonlocal n
        n += 1
        if not cond:
            fails.append(name)

    with tempfile.TemporaryDirectory() as td:
        s = Store(pathlib.Path(td) / "bench")
        s.put("node", "04", {"device_id": "aa", "dac": "3082"})
        check("put / get round trip", s.get("node", "04") == {"device_id": "aa", "dac": "3082"})
        check("store dir is 0700", stat.S_IMODE(s.root.stat().st_mode) == 0o700)
        check("record file is 0600", stat.S_IMODE((s.root / "node-04.json").stat().st_mode) == 0o600)
        check("missing record -> None", s.get("node", "02") is None)
        s.put("owner", "Hx", {"k": 1}, run="r1")
        check("run scope is separate", s.get("owner", "Hx") is None and s.get("owner", "Hx", run="r1") == {"k": 1})
        s.drop_run("r1")
        check("drop_run removes the run scope", not (s.root / "run" / "r1").exists())
        a = s.intend("owner/add", "04", {"owner": "H0b"})
        b = s.intend("key20", "04", {"ssid": "x"})
        s.applied(a)
        check("pending lists intents without an applied record", [r["seq"] for r in s.pending()] == [b])
        try:
            s.put("node", "../x", {})
            check("negative: a path-like name is refused", False)
        except StoreError:
            check("negative: a path-like name is refused", True)
        os.chmod(s.root / "node-04.json", 0o644)
        try:
            s.get("node", "04")
            check("negative: a group/world-readable record is refused", False)
        except StoreError:
            check("negative: a group/world-readable record is refused", True)
        os.chmod(s.root / "node-04.json", 0o600)
        (s.root / "node-lnk.json").symlink_to(s.root / "node-04.json")
        try:
            s.get("node", "lnk")
            check("negative: a symlinked record is refused", False)
        except (StoreError, OSError):
            check("negative: a symlinked record is refused", True)
    for f in fails:
        print("FAIL benchstore selftest:", f)
    print("benchstore selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    import sys
    sys.exit(selftest() if sys.argv[1:2] == ["--selftest"] else 2)
