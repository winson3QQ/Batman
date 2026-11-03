#!/usr/bin/env python3
"""tests/judges/h4/test-judges.py — offline cases for tests/judges/h4/judges.py (254-h4 §16: every judge gets a bad log
that must FAIL / be INVALID, next to the good one that must PASS). Fixtures are in the formats the tools print:
tcpdump -nn -l text (as prov-ethsim-254.sh cap-start records it; its counts matched on 04, 2026-11-03: 1326 SYN /
1326 RST), peer.py JSON lines (peer.py out()). Prints "N PASS / M FAIL"; rc 1 on any FAIL."""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
J = os.path.join(HERE, "judges.py")
W = tempfile.mkdtemp(prefix="h4judges.")
res = {"p": 0, "f": 0}


def f(name, text):
    p = os.path.join(W, name)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    return p


def case(label, want, *args):
    r = subprocess.run([sys.executable, J, *args], capture_output=True, text=True)
    got = r.stdout.split()[1] if r.stdout.startswith("VERDICT ") else f"rc{r.returncode}:{r.stderr.strip()[:80]}"
    rc_ok = {"PASS": 0, "FAIL": 1, "INVALID": 2}.get(want) == r.returncode
    if got == want and rc_ok:
        print(f"ok   {label}: {r.stdout.strip()}"); res["p"] += 1
    else:
        print(f"FAIL {label}: want {want}, got [{r.stdout.strip()}] rc {r.returncode}"); res["f"] += 1


SYN = "09:31:00.%06d IP 10.41.250.144.%d > 10.41.1.3.8095: Flags [S], seq 1, win 64240, options [mss 1460,sackOK,TS val 1 ecr 0,nop,wscale 7], length 0\n"
RST = "09:31:00.%06d IP 10.41.1.3.8095 > 10.41.250.144.%d: Flags [R.], seq 0, ack 2, win 0, length 0\n"
SA = "09:31:00.%06d IP 10.41.1.3.8095 > 10.41.250.144.%d: Flags [S.], seq 7, ack 2, win 65160, length 0\n"
syn100 = "".join(SYN % (i, 40000 + i) for i in range(100))

# ---- cap
case("cap: 100 SYN, counter +100, nothing back", "PASS", "cap", "--cap", f("c1", syn100), "--sent", "100", "--ctr-before", "5", "--ctr-after", "105")
case("cap: one SYN-ACK -> FAIL", "FAIL", "cap", "--cap", f("c2", syn100 + SA % (1, 40001)), "--sent", "100", "--ctr-before", "0", "--ctr-after", "100")
case("cap: RSTs (E-H15 run-3 shape: port closed) -> FAIL", "FAIL", "cap", "--cap", f("c3", syn100 + "".join(RST % (i, 40000 + i) for i in range(100))), "--sent", "100", "--no-counter")
case("cap: 80 of 100 SYN seen -> INVALID (traffic did not arrive)", "INVALID", "cap", "--cap", f("c4", "".join(SYN % (i, 40000 + i) for i in range(80))), "--sent", "100", "--ctr-before", "0", "--ctr-after", "80")
case("cap: counter +50 of 100 SYN -> FAIL", "FAIL", "cap", "--cap", f("c5", syn100), "--sent", "100", "--ctr-before", "0", "--ctr-after", "50")
case("cap: counter went back -> INVALID", "INVALID", "cap", "--cap", f("c6", syn100), "--sent", "100", "--ctr-before", "900", "--ctr-after", "3")
case("cap: empty capture -> INVALID", "INVALID", "cap", "--cap", f("c7", ""), "--sent", "100", "--no-counter")
case("cap: nothing sent -> INVALID", "INVALID", "cap", "--cap", f("c8", syn100), "--sent", "0", "--no-counter")
case("cap: no capture file -> INVALID", "INVALID", "cap", "--cap", os.path.join(W, "absent"), "--sent", "100", "--no-counter")
case("cap: pre-P3 clean capture with --no-counter -> PASS", "PASS", "cap", "--cap", f("c9", syn100), "--sent", "100", "--no-counter")

# ---- hs
L = lambda *ls: "".join(l + "\n" for l in ls)
scan = '{"candidates": 2, "step": "scan"}'
idok = '{"addr": "AA", "device_id": "f340bce177cd895cfc", "frame": 244, "result": "ok", "rssi": -58, "step": "identify"}'
wt0 = '{"addr": "BB", "result": "wrong-target", "rssi": -70, "sent_after_msg1": 0, "step": "identify", "why": "dac"}'
wt3 = '{"addr": "BB", "result": "wrong-target", "rssi": -70, "sent_after_msg1": 3, "step": "identify", "why": "dac"}'
fake = '{"addr": "CC", "result": "fake", "rssi": -60, "step": "handshake"}'
cerr = '{"addr": "AA", "result": "ERR connect timeout", "rssi": -58, "step": "connect"}'
case("hs ok: wrong target skipped (nothing sent), then the target", "PASS", "hs", "--want", "ok", "--log", f("h1", L(scan, wt0, idok)))
case("hs ok: a wrong target got frames after msg1 -> FAIL", "FAIL", "hs", "--want", "ok", "--log", f("h2", L(scan, wt3, idok)))
case("hs ok: only connect errors (refused) -> INVALID", "INVALID", "hs", "--want", "ok", "--log", f("h3", L(scan, cerr)))
case("hs ok: only fake -> FAIL", "FAIL", "hs", "--want", "ok", "--log", f("h4", L(scan, fake)))
case("hs not-ok: fake -> PASS", "PASS", "hs", "--want", "not-ok", "--log", f("h5", L(scan, fake)))
case("hs not-ok: identify ok -> FAIL", "FAIL", "hs", "--want", "not-ok", "--log", f("h6", L(scan, fake, idok)))
case("hs not-ok: refused only -> INVALID (refused is no evidence)", "INVALID", "hs", "--want", "not-ok", "--log", f("h7", L(scan, cerr)))
case("hs: budget -> INVALID", "INVALID", "hs", "--want", "not-ok", "--log", f("h8", L(scan, '{"result": "budget", "step": "handshake"}')))
case("hs: empty log -> INVALID", "INVALID", "hs", "--want", "ok", "--log", f("h9", ""))
case("hs: broken JSON -> INVALID", "INVALID", "hs", "--want", "ok", "--log", f("h10", L(scan, '{"step": "identify", "res')))

# ---- secrets
sec_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
sec_txt = "C0-test-passphrase-7"
secf = f("s.list", sec_txt + "\n" + sec_hex + "\n")
import base64, binascii  # noqa: E402
raw = binascii.unhexlify(sec_hex)
case("secrets: clean logs -> PASS", "PASS", "secrets", "--secrets", secf, f("l1", "provd: session open\nkey fp 3a1f9c\n"), f("l2", "nothing\n"))
case("secrets: the passphrase as text -> FAIL", "FAIL", "secrets", "--secrets", secf, f("l3", "ap psk=" + sec_txt + "\n"))
case("secrets: the key as UPPER hex -> FAIL", "FAIL", "secrets", "--secrets", secf, f("l4", "k=" + sec_hex.upper() + "\n"))
case("secrets: the key's bytes as base64 -> FAIL", "FAIL", "secrets", "--secrets", secf, f("l5", "blob " + base64.b64encode(raw).decode() + "\n"))
case("secrets: the key's bytes as colon hex -> FAIL", "FAIL", "secrets", "--secrets", secf, f("l6", ":".join("%02x" % b for b in raw) + "\n"))
case("secrets: the passphrase as hex -> FAIL", "FAIL", "secrets", "--secrets", secf, f("l7", sec_txt.encode().hex() + "\n"))
case("secrets: no log given -> FAIL (nothing to check)", "FAIL", "secrets", "--secrets", secf)
case("secrets: empty secrets list -> FAIL (nothing to check)", "FAIL", "secrets", "--secrets", f("s0", "\n"), f("l8", "x\n"))
case("secrets: unreadable log -> FAIL", "FAIL", "secrets", "--secrets", secf, os.path.join(W, "absent"))
o = subprocess.run([sys.executable, J, "secrets", "--secrets", secf, f("l9", sec_txt + "\n")], capture_output=True, text=True).stdout
if sec_txt in o or sec_hex in o:
    print("FAIL secrets: the verdict line prints the secret"); res["f"] += 1
else:
    print("ok   secrets: the verdict names the file / line, never the value"); res["p"] += 1

import shutil  # noqa: E402
shutil.rmtree(W)
print(f"{res['p']} PASS / {res['f']} FAIL")
sys.exit(1 if res["f"] else 0)
