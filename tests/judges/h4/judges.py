#!/usr/bin/env python3
"""tests/judges/h4/judges.py — #254 H4 offline judges (docs/design/254-h4-harness.md §16): the node / peer output of an
arm is fetched first, judged here. Stdlib only. Every judge prints one line "VERDICT PASS|FAIL|INVALID <reason>" and
exits 0 / 1 / 2. Nothing found to judge is never a PASS (INVALID or FAIL, per judge).

  judges.py cap --cap <tcpdump text> --sent <n> (--ctr-before <a> --ctr-after <b> | --no-counter)
      §4.5: SYN seen < 0.9 x sent -> INVALID (the traffic never arrived); counter delta < 0 -> INVALID (a fw reload
      reset it); delta < 0.9 x SYN seen -> FAIL; any SYN-ACK or RST on the capture -> FAIL; else PASS.
      --no-counter only before P3 (no named counters yet): the counter clause is skipped and said so.
  judges.py hs --log <peer JSON lines> --want ok|not-ok
      §4.1 classification: a request sent after msg1 to a wrong target -> FAIL (never allowed); `refused` (connect
      error) / `budget` -> INVALID; want ok: an identify ok -> PASS; want not-ok: fake / wrong-target only -> PASS,
      an ok -> FAIL; no handshake line -> INVALID.
  judges.py secrets --secrets <file: one secret per line> <log>...
      §12 / §16: each secret as text, and as lowercase / uppercase hex, colon hex, base64 / base64url of its bytes (a
      64-hex secret also as its raw bytes' encodings) -> FAIL on any hit (the file and line are named, never the value).
      No secret or no log file -> FAIL ("nothing to check").
"""
import argparse
import base64
import binascii
import json
import re
import sys

RC = {"PASS": 0, "FAIL": 1, "INVALID": 2}


def verdict(v, why):
    print(f"VERDICT {v} {why}")
    return RC[v]


# ---- cap ----------------------------------------------------------------------------------------------------------
FLAGS = re.compile(r"Flags \[([^\]]*)\]")


def cap_counts(text):
    syn = synack = rst = 0
    for line in text.splitlines():
        m = FLAGS.search(line)
        if not m:
            continue
        f = m.group(1)
        if "R" in f:
            rst += 1
        elif "S" in f and "." in f:
            synack += 1
        elif "S" in f:          # S, SE, SEW (ECN): a SYN
            syn += 1
    return syn, synack, rst


def judge_cap(a):
    try:
        text = open(a.cap, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return verdict("INVALID", f"capture unreadable: {e}")
    syn, synack, rst = cap_counts(text)
    if a.sent <= 0:
        return verdict("INVALID", f"sent={a.sent}: nothing was sent")
    if syn * 10 < a.sent * 9:
        return verdict("INVALID", f"SYN seen {syn} < 0.9 x sent {a.sent}: the traffic did not arrive")
    if synack or rst:
        return verdict("FAIL", f"SYN-ACK {synack} / RST {rst} on the capture (syn {syn})")
    if a.no_counter:
        return verdict("PASS", f"syn {syn} of {a.sent}, no SYN-ACK / RST (counter clause skipped: --no-counter)")
    d = a.ctr_after - a.ctr_before
    if d < 0:
        return verdict("INVALID", f"counter went back ({a.ctr_before} -> {a.ctr_after}): reset by a fw reload")
    if d * 10 < syn * 9:
        return verdict("FAIL", f"counter +{d} < 0.9 x SYN seen {syn}: the drop rule did not take them")
    return verdict("PASS", f"syn {syn} of {a.sent}, counter +{d}, no SYN-ACK / RST")


# ---- hs -----------------------------------------------------------------------------------------------------------
def judge_hs(a):
    lines = []
    try:
        for raw in open(a.log, encoding="utf-8", errors="replace"):
            raw = raw.strip()
            if raw.startswith("{"):
                try:
                    lines.append(json.loads(raw))
                except ValueError:
                    return verdict("INVALID", f"not JSON: {raw[:60]}")
    except OSError as e:
        return verdict("INVALID", f"log unreadable: {e}")
    leak = [l for l in lines if l.get("result") == "wrong-target" and l.get("sent_after_msg1", 0)]
    if leak:
        return verdict("FAIL", f"{len(leak)} wrong target(s) got frames after msg1 (sent_after_msg1 > 0)")
    if any(l.get("result") == "budget" for l in lines):
        return verdict("INVALID", "peer's own rate limit (budget): no evidence either way")
    hs = [l for l in lines if l.get("step") in ("handshake", "identify")]
    conn = [l for l in lines if l.get("step") == "connect" and l.get("result") not in (None, "ok")]
    oks = [l for l in hs if l.get("result") == "ok"]
    if a.want == "ok":
        if oks:
            return verdict("PASS", f"identify ok ({oks[0].get('addr')})")
        if not hs:
            return verdict("INVALID", f"no handshake reached ({len(conn)} connect error(s): refused)")
        return verdict("FAIL", "handshakes, none identified the target: " + ",".join(l.get("result", "?") for l in hs))
    if oks:
        return verdict("FAIL", f"want not-ok, but identify ok ({oks[0].get('addr')})")
    if not hs:
        return verdict("INVALID", f"no handshake reached ({len(conn)} connect error(s): refused is no evidence)")
    return verdict("PASS", "only " + ",".join(sorted({l.get("result", "?") for l in hs})))


# ---- secrets ------------------------------------------------------------------------------------------------------
def spellings(sec):
    out = {sec}
    forms = [sec.encode()]
    if re.fullmatch(r"[0-9a-fA-F]{32,}", sec) and len(sec) % 2 == 0:
        forms.append(binascii.unhexlify(sec))
    for b in forms:
        h = b.hex()
        out |= {h, h.upper(), ":".join(h[i:i + 2] for i in range(0, len(h), 2)),
                base64.b64encode(b).decode().rstrip("="), base64.urlsafe_b64encode(b).decode().rstrip("=")}
    return {s for s in out if len(s) >= 8}   # shorter spellings would hit random text


def judge_secrets(a):
    try:
        secs = [l.rstrip("\n") for l in open(a.secrets, encoding="utf-8") if l.strip()]
    except OSError as e:
        return verdict("FAIL", f"secrets file unreadable: {e} (nothing to check)")
    if not secs:
        return verdict("FAIL", "no secret listed (nothing to check)")
    if not a.logs:
        return verdict("FAIL", "no log given (nothing to check)")
    pats = [(i, s) for i, sec in enumerate(secs) for s in spellings(sec)]
    hits, checked = [], 0
    for f in a.logs:
        try:
            data = open(f, "rb").read().decode("utf-8", errors="replace")
        except OSError as e:
            return verdict("FAIL", f"log {f} unreadable: {e}")
        checked += 1
        for n, line in enumerate(data.splitlines(), 1):
            for i, s in pats:
                if s in line:
                    hits.append(f"{f}:{n} secret#{i + 1}")
    if hits:
        return verdict("FAIL", f"{len(hits)} hit(s): " + " ".join(sorted(set(hits))[:10]))
    return verdict("PASS", f"{len(secs)} secret(s), {checked} log(s), 0 hits")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="judges.py")
    sub = ap.add_subparsers(dest="judge", required=True)
    c = sub.add_parser("cap")
    c.add_argument("--cap", required=True)
    c.add_argument("--sent", type=int, required=True)
    g = c.add_mutually_exclusive_group(required=True)
    g.add_argument("--no-counter", action="store_true")
    g.add_argument("--ctr-before", type=int)
    c.add_argument("--ctr-after", type=int)
    h = sub.add_parser("hs")
    h.add_argument("--log", required=True)
    h.add_argument("--want", choices=("ok", "not-ok"), required=True)
    s = sub.add_parser("secrets")
    s.add_argument("--secrets", required=True)
    s.add_argument("logs", nargs="*")
    a = ap.parse_args(argv)
    if a.judge == "cap" and not a.no_counter and a.ctr_after is None:
        ap.error("--ctr-before needs --ctr-after")
    return {"cap": judge_cap, "hs": judge_hs, "secrets": judge_secrets}[a.judge](a)


if __name__ == "__main__":
    sys.exit(main())
