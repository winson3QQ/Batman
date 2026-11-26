"""gattjudge — the verdicts of prov-gatt-254 (the prov-gatt-254 design §4.3, §5, §6), stdlib only. The unit script
(scripts/dv/prov-gatt-254.sh) is the one judge; this is its library: it reads what peer.py printed (GATTR lines) and
04's btmon text (`btmon -r`, decoded on 04 as uid 65534) and prints PASS / FAIL / INVALID lines and one
"VERDICT case=<id> <PASS|FAIL|INVALID|RETRY|NA>" line. Nothing here talks to a node.

  gattjudge.py case  --case <id> --central <addr|-> [--target <addr>] [--pids <prev>,<before>,<after>] [--retry]
                     [--real-seen] [--gatt <file>] [--btmon <file>]
  gattjudge.py live  --log <file>                    (bluetoothd liveness during B1 / B1x)
  gattjudge.py e2    --central <addr|-> --msg2len <n> --rw <file> --rw-btmon <file> --read-btmon <file>
  gattjudge.py post  --obs <file>                    (post-check: bonds, orphans, leftovers)
  gattjudge.py --selftest

btmon facts used (BlueZ 5.72 monitor/): the central's address is `Peer address` of 04's LE (Enhanced) Connection
Complete (packet.c:11080-11083, 11209-11214); ACL headers carry `Handle <n>` (packet.c:12495); event / command
fields print `Handle: <n>` (packet.c:815-828); a 04-initiated drop is `< HCI Command: Disconnect (0x01|0x0006)` then
Disconnect Complete Reason 0x16 (packet.c:9004, 11958); encryption on a peripheral shows as the LE Long Term Key
Request event (0x05, packet.c:11807), its reply / negative reply commands 0x08|0x001a / 0x08|0x001b (packet.c:9635,
9638; btmon shortens their names, so they are matched by opcode) and Encryption Change (packet.c:11964); ATT
discovery prints `Value Handle: 0x....` + `Value UUID: … (<uuid>)` (att.c:602-603) and Find Information `Handle:` +
`UUID: … (0x2902)` (att.c:3478-3479).
"""
import argparse
import re
import sys

RX = "540aa38c-0086-4d59-a9c0-c7c9d1e1bd42"
TX = "540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42"
CTRL = "540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42"
STATUS = "540aa38c-0086-4d5c-a9c0-c7c9d1e1bd42"
ACCEPT = {"m1", "s1a", "s3b", "s512a", "s8192", "t1", "t2", "t4", "b1", "b1x"}
REJECT = {"q1", "q2", "q3", "q4", "q5", "q6", "q7a", "q7b", "s512b", "s8193"}
DROP_MAX_S = 6.0
MAC = r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}"


# ---- btmon text -> records ----------------------------------------------------------------------------------------

class Rec:
    def __init__(self, head, t):
        self.head, self.t, self.body = head, t, []

    def text(self):
        return "\n".join([self.head] + self.body)

    def field(self, name):
        for b in self.body:
            m = re.match(r"\s+%s:\s*(.*)$" % re.escape(name), b)
            if m:
                return m.group(1).strip()
        return None

    def handle(self):
        m = re.search(r"ACL Data [RT]X: Handle (\d+)", self.head)
        if m:
            return int(m.group(1))
        for b in self.body:
            m = re.match(r"\s+Handle: (\d+)\b", b)
            if m:
                return int(m.group(1))
        return None


def parse(text):
    recs = []
    for ln in text.splitlines():
        if re.match(r"^[<>@=] ", ln):
            m = re.search(r"(\d+\.\d+)\s*$", ln)
            recs.append(Rec(ln, float(m.group(1)) if m else None))
        elif recs and ln.strip():
            recs[-1].body.append(ln)
    return recs


def conns(recs):
    """[(handle, peer address, local rpa or None, record index)] of the successful connections."""
    out = []
    for i, r in enumerate(recs):
        if not any("LE Connection Complete" in b or "LE Enhanced Connection Complete" in b for b in r.body[:1]):
            continue
        st = r.field("Status") or ""
        if "0x00" not in st:
            continue
        pa = re.search(MAC, r.field("Peer address") or "")
        lr = re.search(MAC, r.field("Local resolvable private address") or "")
        h = r.handle()
        out.append((h, pa.group(0).upper() if pa else None, lr.group(0).upper() if lr else None, i))
    return out


def gatt_handles(recs, h):
    """ATT handles of the provd service from the discovery on connection h: {rx, tx, ctrl, status, ccc}."""
    out, vals = {}, []
    for r in recs:
        if r.handle() != h or "ACL Data" not in r.head:
            continue
        cur = None
        for b in r.body:
            m = re.match(r"\s+Value Handle: 0x([0-9a-f]{4})", b)
            if m:
                cur = int(m.group(1), 16)
                continue
            m = re.match(r"\s+Value UUID: .*\(([0-9a-f-]{36})\)", b)
            if m and cur is not None:
                vals.append((cur, m.group(1)))
                cur = None
                continue
            m = re.match(r"\s+Handle: 0x([0-9a-f]{4})$", b)
            if m:
                cur = int(m.group(1), 16)
                continue
            m = re.match(r"\s+UUID: .*\(0x2902\)", b)
            if m and cur is not None:
                out.setdefault("_ccc", []).append(cur)
                cur = None
    names = {RX: "rx", TX: "tx", CTRL: "ctrl", STATUS: "status"}
    for hv, u in vals:
        if u in names:
            out[names[u]] = hv
    if "tx" in out:
        later = sorted(x for x, _u in vals if x > out["tx"])
        nxt = later[0] if later else 0x10000
        ccc = [c for c in out.get("_ccc", []) if out["tx"] < c < nxt]
        if ccc:
            out["ccc"] = ccc[0]
    out.pop("_ccc", None)
    return out


def att(recs, h, op, handle=None):
    """The records on connection h whose ATT line is <op> (and, when given, whose attribute Handle is <handle>)."""
    out = []
    for r in recs:
        if r.handle() != h or "ACL Data" not in r.head:
            continue
        if not any(re.match(r"\s+ATT: %s \(" % re.escape(op), b) for b in r.body):
            continue
        if handle is not None:
            hs = [int(m.group(1), 16) for b in r.body for m in [re.match(r"\s+Handle: 0x([0-9a-f]{4})", b)] if m]
            if handle not in hs:
                continue
        out.append(r)
    return out


def encryption_lines(recs, h):
    """Every sign of encryption / pairing on connection h, as seen by a peripheral."""
    out = []
    for r in recs:
        txt = r.text()
        if r.handle() != h:
            continue
        if "ACL Data" in r.head and any(re.match(r"\s+SMP: ", b) for b in r.body):
            out.append("SMP: " + next(b.strip() for b in r.body if "SMP:" in b))
        if "LE Meta Event" in r.head and "LE Long Term Key Request" in txt:
            out.append("LE Long Term Key Request event")
        if re.search(r"\(0x08\|0x001[ab]\)", r.head):
            out.append("LTK reply command " + re.search(r"\(0x08\|0x001[ab]\)", r.head).group(0))
        if "HCI Event: Encryption Change" in r.head:
            out.append("Encryption Change")
    return out


def disconnect(recs, h):
    """(reason code or None, 04 sent HCI Disconnect, time of Disconnect Complete)"""
    cmd, reason, t = False, None, None
    for r in recs:
        if r.head.startswith("< HCI Command: Disconnect (0x01|0x0006)") and r.handle() == h:
            cmd = True
        if r.head.startswith("> HCI Event: Disconnect Complete") and r.handle() == h:
            m = re.search(r"\(0x([0-9a-f]{2})\)", r.field("Reason") or "")
            reason, t = (int(m.group(1), 16) if m else None), r.t
    return reason, cmd, t


def mtu_at_ccc(recs, h, ccc):
    """min(Client RX MTU, Server RX MTU) of the last exchange before the TX CCC write; 23 without one."""
    cli = srv = None
    for r in recs:
        if r.handle() != h or "ACL Data" not in r.head:
            continue
        if ccc is not None and any(re.match(r"\s+ATT: Write Request \(", b) for b in r.body) and \
                any(re.match(r"\s+Handle: 0x%04x" % ccc, b) for b in r.body):
            break
        v = r.field("Client RX MTU")
        if v and v.isdigit():
            cli = int(v)
        v = r.field("Server RX MTU")
        if v and v.isdigit():
            srv = int(v)
    if cli is None or srv is None:
        return 23
    return min(cli, srv)


# ---- the peer-only shape (also what gatt.py's selftest checks) -------------------------------------------------------

def frac(s):
    try:
        a, b = s.split("/")
        return int(a), int(b)
    except Exception:  # noqa: BLE001
        return -1, -1


def peer_shape(case, d, crashed=False):
    """The verdict the peer's observation alone supports (btmon / pid rules are added by judge_case)."""
    if not d:
        return "INVALID"
    if d.get("skip", "-") not in ("-", ""):
        return "NA"
    if d.get("conn") != "ok":
        return "FAIL" if d.get("conn", "").endswith(("0x05", "0x0f")) else "INVALID"
    if d.get("hs") != "real":
        return "INVALID"
    if crashed:
        return "FAIL"
    k, n = frac(d.get("answered", ""))
    lost = d.get("lost") == "yes"
    if case in ACCEPT:
        if case != "s1a" and d.get("warm") != "1":
            return "INVALID"
        if case in ("b1", "b1x"):
            return "PASS" if (k == n and n > 0 and d.get("order") == "ok" and not lost) else "FAIL"
        if lost:
            return "FAIL"       # the node dropped a valid exchange (judge_case refines with btmon's direction)
        return "PASS" if (k == n and n > 0) else "FAIL"
    if case in REJECT:
        if d.get("warm") != "1":
            return "INVALID"
        if k >= 1:
            return "FAIL"       # a lax provd answered the frames that break one rule
        return "PASS" if lost else "FAIL"     # spec: a bad sequence not dropped = FAIL
    return "INVALID"


# ---- full verdicts ------------------------------------------------------------------------------------------------

class V:
    def __init__(self, case):
        self.case, self.lines, self.v = case, [], "PASS"

    def _rank(self, x):
        return {"PASS": 0, "NA": 1, "RETRY": 2, "INVALID": 3, "FAIL": 4}[x]

    def say(self, kind, msg):
        self.lines.append("%s gatt %s: %s" % ("PASS" if kind == "PASS" else kind, self.case, msg))
        if kind != "PASS" and self._rank(kind) > self._rank(self.v):
            self.v = kind

    def done(self):
        self.lines.append("VERDICT case=%s %s" % (self.case, self.v))
        return self.lines


def gattr(text):
    g = [ln for ln in text.splitlines() if ln.startswith("GATTR ")]
    if not g:
        return {}
    return dict(kv.split("=", 1) for kv in g[-1].split()[1:] if "=" in kv)


def judge_case(case, gatt_text, btmon_text, central, target=None, pids=None, retry=False, real_seen=False):
    v = V(case)
    d = gattr(gatt_text)
    if not d or "GATTEND case=%s" % case not in gatt_text:
        v.say("INVALID", "no GATTR / GATTEND from peer.py (cut off?)")
        return v.done()
    if re.search(r"GATTEND case=\S+ rc=124", gatt_text):
        v.say("INVALID" if case != "b1x" else "FAIL", "peer.py hit its deadline (rc 124)%s" % (
            " — B1x stalled: bluetoothd / provd stopped answering (judge the liveness log)" if case == "b1x" else ""))
    if d.get("skip", "-") not in ("-", ""):
        v.say("NA", "skipped (%s) — not reachable on this central" % d["skip"])
        return v.done()
    # pid rules (§6.3)
    if pids:
        prev, before, after = (pids + ["", "", ""])[:3]
        if not before or not after:
            v.say("INVALID", "provd pid unreadable (%s)" % ",".join(pids))
        elif prev and prev != before:
            v.say("INVALID", "provd pid changed BETWEEN cases (%s -> %s): not this stimulus" % (prev, before))
        elif before != after:
            v.say("FAIL", "provd pid changed during the case (%s -> %s): provd crashed on this stimulus (remote DoS)" % (before, after))
    recs = parse(btmon_text)
    cs = conns(recs)
    if not recs:
        v.say("INVALID", "btmon capture empty")
        return v.done()
    if not any(r.head.startswith("= New Index") or r.head.startswith("= Index Info") for r in recs):
        v.say("INVALID", "btmon capture has no New Index / Index Info: not known to cover the connection's start")
    mine = [c for c in cs if central in ("-", None) or c[1] == central.upper()]
    foreign = [c for c in cs if central not in ("-", None) and c[1] != central.upper()]
    if foreign:
        v.say("INVALID", "another central connected during the case: %s" % ",".join(str(c[1]) for c in foreign))
    if central in ("-", None) and len(cs) > 1:
        v.say("INVALID", "%d connections in the window and no known central address to tell them apart" % len(cs))
    if len(mine) != 1:
        v.say("INVALID", "%d Connection Complete from the central %s (want exactly 1)" % (len(mine), central))
        return v.done()
    h, peer_addr, lrpa, _i = mine[0]
    if central in ("-", None) and peer_addr:
        v.lines.append("INFO gatt %s: central %s" % (case, peer_addr))
    if lrpa and lrpa != "00:00:00:00:00:00" and target and target != "-" and lrpa != target.upper():
        v.say("INVALID", "Local RPA %s is not the target %s" % (lrpa, target))
    reason, cmd04, t_disc = disconnect(recs, h)
    if reason is None:
        v.say("INVALID", "no Disconnect Complete for handle %d: the capture does not cover the whole link" % h)
    enc = encryption_lines(recs, h)
    if enc:
        v.say("FAIL", "pairing / encryption on an unpaired link: %s" % "; ".join(sorted(set(enc))[:4]))
    else:
        v.say("PASS", "no SMP, no LTK request, no Encryption Change on handle %d (E1)" % h)
    hd = gatt_handles(recs, h)
    if "rx" not in hd:
        v.say("INVALID", "no GATT discovery of RX on handle %d in the capture (cached services?)" % h)
    # the peer's own observation
    if d.get("conn") != "ok":
        c = d.get("conn", "")
        if c.endswith(("0x05", "0x0f")):
            v.say("FAIL", "the node refused a read / subscription with ATT %s (encryption required)" % c[-4:])
        else:
            v.say("INVALID", "connection: %s" % c)
        return v.done()
    if d.get("hs") == "none":
        st = (d.get("status0"), d.get("status1"))
        if "att:0x0e" in st:
            v.say("INVALID", "no msg2, and STATUS said not fresh (0x0E): the helper / cache was not ready")
            return v.done()
        writes = att(recs, h, "Write Command", hd.get("rx"))
        if not writes:
            v.say("INVALID", "no msg2, and msg1 never reached 04's RX handle")
            return v.done()
        if not retry:
            v.say("RETRY", "no msg2: quiet 61 s under a continuous btmon, then the same case again")
            return v.done()
        if foreign:
            v.say("INVALID", "no msg2 again, but another central was in the window (handshake quota)")
        elif not real_seen:
            v.say("INVALID", "no msg2 again, and this provd pid had no real handshake in the run (nodeCert unproven)")
        else:
            v.say("FAIL", "no msg2 twice, 04 got msg1 both times, no other central, this provd pid did real handshakes")
        return v.done()
    if d.get("hs") != "real":
        v.say("INVALID", "handshake %s (wrong node / claimed?)" % d.get("hs"))
        return v.done()
    shape = peer_shape(case, d)
    k, n = frac(d.get("answered", ""))
    lost = d.get("lost") == "yes"
    if case in ACCEPT:
        if lost:
            if cmd04 and reason == 0x16:
                v.say("FAIL", "04 dropped a valid exchange before the peer's CLOSE (HCI Disconnect, reason 0x16)")
            else:
                v.say("INVALID", "the link went before CLOSE, not by 04 (reason %s)" % reason)
        elif shape == "PASS":
            v.say("PASS", "answered %s%s" % (d.get("answered"), ", in order" if case.startswith("b1") else ""))
        else:
            v.say("FAIL", "answered %s, order %s" % (d.get("answered"), d.get("order")))
        if case == "m1":
            L = min(244, mtu_at_ccc(recs, h, hd.get("ccc")) - 3)
            bad = []
            for m in d.get("nlen", "-").split("/"):
                if m in ("-", ""):
                    continue
                fl = [int(x) for x in m.split(",")]
                if any(x != L for x in fl[:-1]) or fl[-1] > L:
                    bad.append(m)
            if d.get("nlen", "-") in ("-", ""):
                v.say("INVALID", "no node frames recorded")
            elif bad:
                v.say("FAIL", "outbound frames not min(244, MTU-3) = %d: %s" % (L, ";".join(bad)))
            else:
                v.say("PASS", "every non-final outbound frame = %d (MTU at subscription %d; not discriminating at 244)" % (L, L + 3))
    elif case in REJECT:
        if k >= 1:
            v.say("FAIL", "the node ANSWERED frames that break one framing rule (lax Reassembler)")
        elif not lost:
            v.say("FAIL", "the node neither dropped the link nor answered within the window")
        elif not (cmd04 and reason == 0x16):
            v.say("INVALID", "the link went, but not by 04 (HCI Disconnect %s, reason %s)" % (cmd04, reason))
        else:
            ws = att(recs, h, "Write Command", hd.get("rx"))
            tw = ws[-1].t if ws else None
            if tw is not None and t_disc is not None:
                dt = t_disc - tw
                if dt <= DROP_MAX_S:
                    v.say("PASS", "04 dropped the link %.1f s after the bad frame (reason 0x16)" % dt)
                else:
                    v.say("FAIL", "04 dropped the link only %.1f s after the bad frame (> %.0f s: not the framing rule)" % (dt, DROP_MAX_S))
            else:
                v.say("PASS", "04 dropped the link (reason 0x16); no timestamps to time it")
    return v.done()


def judge_live(text, max_ok=2.0, gap_max=3.0, hang_s=10.0):
    v = V("live")
    rows = []
    for ln in text.splitlines():
        p = ln.split()
        if len(p) >= 3 and p[0].isdigit():
            rows.append((int(p[0]), p[1], p[2], p[3] if len(p) > 3 else "?"))
    if len(rows) < 2:
        v.say("INVALID", "liveness log has %d rows" % len(rows))
        return v.done()
    gaps = [b[0] - a[0] for a, b in zip(rows, rows[1:])]
    if max(gaps) > gap_max * 1000 + 2500:
        v.say("INVALID", "liveness log has a %d ms gap (the watcher itself stalled)" % max(gaps))
    to = [r for r in rows if r[1] != "ok"]
    run, best = 0, 0
    for r in rows:
        run = run + 1 if r[1] != "ok" else 0
        best = max(best, run)
    pids = sorted(set(r[2] for r in rows))
    if best * 1.0 >= hang_s:
        v.say("FAIL", "bluetoothd did not answer for %d s in a row: hang (remote DoS)" % best)
    elif to:
        v.say("FAIL", "bluetoothd answered slower than %.0f s %d time(s)" % (max_ok, len(to)))
    else:
        v.say("PASS", "bluetoothd answered every probe within %.0f s (%d probes)" % (max_ok, len(rows)))
    if len(pids) > 1:
        v.say("FAIL", "bluetoothd pid changed during the case: %s" % ",".join(pids))
    rss = [r[3] for r in rows if r[3].isdigit()]
    if rss:
        v.lines.append("INFO gatt live: bluetoothd VmRSS %s -> %s kB" % (rss[0], rss[-1]))
    return v.done()


def judge_e2(rw_text, rw_btmon, read_btmon, central, msg2len):
    v = V("e2")
    nv = [ln.split()[1] for ln in rw_text.splitlines() if ln.startswith("NVAL ")]
    vals = [bytes.fromhex(x) for x in nv if re.fullmatch(r"[0-9a-f]*", x) and len(x) % 2 == 0]
    total, ok_frames = 0, True
    for f in vals:
        if len(f) < 3:
            ok_frames = False
            continue
        total += len(f) - 3
    if not vals:
        v.say("FAIL", "02 got no notification after subscribing and writing msg1 unencrypted (RX or TX needs encryption?)")
    elif not ok_frames or total != msg2len:
        v.say("FAIL", "02's notifications carry %d B, M1's msg2 is %d B" % (total, msg2len))
    else:
        v.say("PASS", "02 (not paired) subscribed TX, wrote msg1 to RX and got msg2 (%d B in %d frames)" % (total, len(vals)))
    if central in ("-", None):
        # no U17 address: 02's own address is the one connection of the read capture, and the rw capture must match it
        rc = conns(parse(read_btmon))
        if len(rc) != 1 or not rc[0][1]:
            v.say("INVALID", "02's address unknown and the read capture has %d connections" % len(rc))
            return v.done()
        central = rc[0][1]
        v.lines.append("INFO gatt e2: 02's address from the read capture: %s" % central)
    for label, txt, want in (("rw", rw_btmon, True), ("read", read_btmon, False)):
        recs = parse(txt)
        cs = [c for c in conns(recs) if central in ("-", None) or c[1] == central.upper()]
        if len(cs) != 1:
            v.say("INVALID", "%s: %d connections from 02 (%s) in its capture" % (label, len(cs), central))
            continue
        h = cs[0][0]
        hd = gatt_handles(recs, h)
        enc = encryption_lines(recs, h)
        if enc:
            v.say("FAIL", "%s: encryption on 02's link: %s" % (label, "; ".join(sorted(set(enc)))))
        ccc = att(recs, h, "Write Request", hd.get("ccc")) if "ccc" in hd else []
        ntf = att(recs, h, "Handle Value Notification")
        mtu = mtu_at_ccc(recs, h, hd.get("ccc"))
        if want:
            if mtu < 38:
                v.say("INVALID", "rw: ATT MTU %d < 38: a 35 B write does not fit" % mtu)
            if not ccc or not ntf or not att(recs, h, "Write Command", hd.get("rx")):
                v.say("INVALID", "rw: the capture lacks the CCC write / RX write / notification on handle %d" % h)
        else:
            if ccc or ntf:
                v.say("FAIL", "read control: a CCC write or a notification on a read-only link")
            else:
                v.say("PASS", "read control: no subscription, no notification (the notifications are E2's doing)")
    return v.done()


def judge_post(obs):
    """obs: key=value lines — pnp_before / pnp_after (comma lists), bond04 (ls of the adapter dir), paired02 (count),
    btmon04 (pids of harness btmon), pcd (exists 0/1), orphan_wsl / orphan_win (counts), connected04 (count)."""
    d = {}
    for ln in obs.splitlines():
        if "=" in ln:
            k, _, x = ln.partition("=")
            d[k.strip()] = x.strip()
    v = V("post")
    need = ["pnp_before", "pnp_after", "bond04", "paired02", "btmon04", "pcd", "orphan_wsl", "orphan_win", "connected04"]
    miss = [k for k in need if k not in d]
    if miss:
        v.say("INVALID", "post-check observations missing: %s" % ",".join(miss))
        return v.done()
    unread = [k for k in ("paired02", "pcd", "orphan_wsl", "orphan_win", "connected04") if not d[k].isdigit()]
    if unread:
        v.say("INVALID", "post-check observations unreadable (never taken as 0): %s" % ",".join(
            "%s=%s" % (k, d[k] or "''") for k in unread))
        return v.done()
    new = sorted(set(filter(None, d["pnp_after"].split(","))) - set(filter(None, d["pnp_before"].split(","))))
    v.say("FAIL", "Windows has new BLE devices (a bond?): %s — remove by hand" % ",".join(new)) if new else \
        v.say("PASS", "Windows: no new BLE device (PnP diff empty)")
    extra = [x for x in d["bond04"].split() if re.fullmatch(MAC, x)]
    v.say("FAIL", "04 keeps a device directory (a bond?): %s" % ",".join(extra)) if extra else \
        v.say("PASS", "04: no device directory under the adapter")
    v.say("PASS", "02: no paired device") if d["paired02"] == "0" else v.say("FAIL", "02: %s paired device(s)" % d["paired02"])
    v.say("PASS", "04: no harness btmon left") if d["btmon04"] in ("", "-") else v.say("FAIL", "04: harness btmon still running: %s" % d["btmon04"])
    v.say("PASS", "04: this run's provclient dir is gone") if d["pcd"] == "0" else v.say("FAIL", "04: this run's provclient dir is still there")
    v.say("PASS", "host: no orphan peer / bridge") if d["orphan_wsl"] == "0" and d["orphan_win"] == "0" else \
        v.say("FAIL", "host: orphan peer.py %s / blebridge %s" % (d["orphan_wsl"], d["orphan_win"]))
    v.say("PASS", "04: no connected device") if d["connected04"] == "0" else v.say("FAIL", "04: %s connected device(s)" % d["connected04"])
    return v.done()


# ---- selftest ------------------------------------------------------------------------------------------------------

CENTRAL = "02:00:00:00:00:01"   # a made-up (locally administered) address (the real one comes from U7 / the environment)
OTHER = "5A:11:22:33:44:55"


def sample(case_kind="reject", central=CENTRAL, h=64, extra_conn=None, discovery=True, disc_reason=0x16,
           disc_cmd=True, enc=False, index=True, mtu=(517, 517), dt=1.2, disc=True, lrpa=None):
    """A btmon -r text in BlueZ 5.72's format (the shapes of tests/fixtures/btmon-254/*.txt, values unmasked)."""
    L = []
    if index:
        L += ["= New Index: 00:00:00:00:00:00 (Primary,UART,hci0)  [hci0] 0.000001",
              "= Index Info: 00:00:00:00:00:00 (Cypress Semiconductor)  [hci0] 0.000002"]

    def cc(hh, addr, t):
        if lrpa is None:
            return ["> HCI Event: LE Meta Event (0x3e) plen 19  #3 [hci0] %.6f" % t,
                    "      LE Connection Complete (0x01)", "        Status: Success (0x00)", "        Handle: %d" % hh,
                    "        Role: Peripheral (0x01)", "        Peer address type: Public (0x00)",
                    "        Peer address: %s (OUI 00-00-00)" % addr]
        return ["> HCI Event: LE Meta Event (0x3e) plen 31  #3 [hci0] %.6f" % t,
                "      LE Enhanced Connection Complete (0x0a)", "        Status: Success (0x00)", "        Handle: %d" % hh,
                "        Role: Peripheral (0x01)", "        Peer address type: Public (0x00)",
                "        Peer address: %s (OUI 00-00-00)" % addr,
                "        Local resolvable private address: %s (Resolvable)" % lrpa]
    L += cc(h, central, 1.0)
    if extra_conn:
        L += cc(h + 1, extra_conn, 1.5)
    L += ["> ACL Data RX: Handle %d flags 0x02 dlen 7  #5 [hci0] 1.100000" % h,
          "      ATT: Exchange MTU Request (0x02) len 2", "        Client RX MTU: %d" % mtu[0],
          "< ACL Data TX: Handle %d flags 0x00 dlen 7  #6 [hci0] 1.110000" % h,
          "      ATT: Exchange MTU Response (0x03) len 2", "        Server RX MTU: %d" % mtu[1]]
    if discovery:
        L += ["< ACL Data TX: Handle %d flags 0x00 dlen 27  #7 [hci0] 1.200000" % h,
              "      ATT: Read By Type Response (0x09) len 22", "        Attribute data length: 21",
              "        Attribute data list: 4 entries", "        Handle: 0x0010",
              "            Properties: 0x04", "            Write Without Response (0x04)",
              "            Value Handle: 0x0011",
              "            Value UUID: Vendor specific (%s)" % RX, "        Handle: 0x0012",
              "            Properties: 0x10", "            Value Handle: 0x0013",
              "            Value UUID: Vendor specific (%s)" % TX, "        Handle: 0x0015",
              "            Properties: 0x02", "            Value Handle: 0x0016",
              "            Value UUID: Vendor specific (%s)" % CTRL, "        Handle: 0x0017",
              "            Properties: 0x02", "            Value Handle: 0x0018",
              "            Value UUID: Vendor specific (%s)" % STATUS,
              "< ACL Data TX: Handle %d flags 0x00 dlen 10  #8 [hci0] 1.210000" % h,
              "      ATT: Find Information Response (0x05) len 5", "        Format: UUID-16 (0x01)",
              "        Handle: 0x0014", "        UUID: Client Characteristic Configuration (0x2902)"]
    L += ["> ACL Data RX: Handle %d flags 0x02 dlen 9  #9 [hci0] 1.300000" % h,
          "      ATT: Write Request (0x12) len 4",
          "        Handle: 0x0014 Type: Client Characteristic Configuration (0x2902)", "          Data: 0100",
          "> ACL Data RX: Handle %d flags 0x02 dlen 42  #10 [hci0] 2.000000" % h,
          "      ATT: Write Command (0x52) len 37", "        Handle: 0x0011 Type: Vendor specific (%s)" % RX,
          "          Data: 010000",
          "< ACL Data TX: Handle %d flags 0x00 dlen 250  #11 [hci0] 2.100000" % h,
          "      ATT: Handle Value Notification (0x1b) len 245", "        Handle: 0x0013 Type: Vendor specific (%s)" % TX]
    if enc:
        L += ["> ACL Data RX: Handle %d flags 0x02 dlen 11  #12 [hci0] 2.200000" % h,
              "      SMP: Pairing Request (0x01) len 6", "        IO capability: NoInputNoOutput (0x03)"]
    tw = 3.0
    L += ["> ACL Data RX: Handle %d flags 0x02 dlen 40  #13 [hci0] %.6f" % (h, tw),
          "      ATT: Write Command (0x52) len 35", "        Handle: 0x0011 Type: Vendor specific (%s)" % RX,
          "          Data: 070000"]
    if disc:
        if disc_cmd:
            L += ["< HCI Command: Disconnect (0x01|0x0006) plen 3  #14 [hci0] %.6f" % (tw + dt - 0.05),
                  "        Handle: %d Address: %s (OUI 00-00-00)" % (h, central),
                  "        Reason: Remote User Terminated Connection (0x13)"]
        L += ["> HCI Event: Disconnect Complete (0x05) plen 4  #15 [hci0] %.6f" % (tw + dt),
              "        Status: Success (0x00)", "        Handle: %d Address: %s (OUI 00-00-00)" % (h, central),
              "        Reason: %s (0x%02x)" % ("Connection Terminated By Local Host" if disc_reason == 0x16
                                             else "Remote User Terminated Connection", disc_reason)]
    return "\n".join(L) + "\n"


def gl(case, **kw):
    r = dict(case=case, conn="ok", target="AA:04", mtu="517", wmax="514", frame="244", status0="ok", hs="real",
             warm="1", sent="2", answered="0/1", lost="yes", lost_at="before-close", msg2len="700",
             nlen="244,244,212/97", order="-", resp_frames="1", status1="-", skip="-")
    r.update(kw)
    return "PIDS wsl=1 win=2\nGATTR " + " ".join("%s=%s" % k for k in r.items()) + "\nGATTEND case=%s rc=0\n" % case


def selftest():
    import os
    fails, n = [], 0

    def check(name, got, want):
        nonlocal n
        n += 1
        print(("ok   " if got == want else "FAIL ") + "%s -> %s" % (name, got))
        if got != want:
            fails.append("%s: got %s want %s" % (name, got, want))

    def verdict(lines):
        return lines[-1].split()[-1]
    P = ["10", "10", "10"]
    # reject case: 04 drops within 6 s, nothing answered -> PASS
    check("Q PASS: 04 drop 1.2 s, reason 0x16", verdict(judge_case("q1", gl("q1"), sample(), CENTRAL, pids=P)), "PASS")
    check("Q lax: answered=1 -> FAIL", verdict(judge_case("q1", gl("q1", answered="1/1", lost="no"), sample(disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P)), "FAIL")
    check("Q not dropped, not answered -> FAIL", verdict(judge_case("q4", gl("q4", lost="no"), sample(disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P)), "FAIL")
    check("Q dropped by the central (0x13, no HCI Disconnect) -> INVALID", verdict(judge_case("q2", gl("q2"), sample(disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P)), "INVALID")
    check("Q dropped 9 s after the bad frame -> FAIL (not the framing rule)", verdict(judge_case("q3", gl("q3"), sample(dt=9.0), CENTRAL, pids=P)), "FAIL")
    # binding / coverage (A2-M1 / B2-M1 / B2-m3)
    check("address mismatch: the only connection is not the central's -> INVALID",
          verdict(judge_case("q1", gl("q1"), sample(central=OTHER), CENTRAL, pids=P)), "INVALID")
    check("a second (foreign) central in the window -> INVALID",
          verdict(judge_case("q1", gl("q1"), sample(extra_conn=OTHER), CENTRAL, pids=P)), "INVALID")
    check("no Disconnect Complete (capture stopped early) -> INVALID",
          verdict(judge_case("t2", gl("t2", answered="1/1", lost="no"), sample(disc=False), CENTRAL, pids=P)), "INVALID")
    check("no New Index / Index Info (start not covered) -> INVALID",
          verdict(judge_case("t2", gl("t2", answered="1/1", lost="no"), sample(index=False, disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P)), "INVALID")
    check("no GATT discovery (cached services) -> INVALID",
          verdict(judge_case("t2", gl("t2", answered="1/1", lost="no"), sample(discovery=False, disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P)), "INVALID")
    check("empty capture -> INVALID", verdict(judge_case("q1", gl("q1"), "", CENTRAL, pids=P)), "INVALID")
    check("no GATTEND (peer cut off) -> INVALID", verdict(judge_case("q1", gl("q1").replace("GATTEND", "XX"), sample(), CENTRAL, pids=P)), "INVALID")
    check("Local RPA present and not the target -> INVALID",
          verdict(judge_case("q1", gl("q1"), sample(lrpa="7B:00:00:00:00:01"), CENTRAL, target="7B:00:00:00:00:02", pids=P)), "INVALID")
    check("Local RPA = target -> PASS", verdict(judge_case("q1", gl("q1"), sample(lrpa="7B:00:00:00:00:01"), CENTRAL, target="7B:00:00:00:00:01", pids=P)), "PASS")
    check("Local RPA all zero is not compared -> PASS", verdict(judge_case("q1", gl("q1"), sample(lrpa="00:00:00:00:00:00"), CENTRAL, target="7B:00:00:00:00:02", pids=P)), "PASS")
    # accept case
    acc = sample(disc_reason=0x13, disc_cmd=False)
    check("twin answered, link held, closed by the peer -> PASS", verdict(judge_case("t1", gl("t1", answered="1/1", lost="no"), acc, CENTRAL, pids=P)), "PASS")
    check("twin dropped by 04 before CLOSE -> FAIL", verdict(judge_case("t1", gl("t1", answered="1/1"), sample(), CENTRAL, pids=P)), "FAIL")
    check("twin dropped before CLOSE by the central -> INVALID", verdict(judge_case("t1", gl("t1", answered="1/1"), acc, CENTRAL, pids=P)), "INVALID")
    check("CLOSE-ended twin with 04's reason 0x16 after CLOSE -> PASS (n2)", verdict(judge_case("t4", gl("t4", answered="1/1", lost="no"), sample(), CENTRAL, pids=P)), "PASS")
    # pid rules
    check("pid changed during the case -> FAIL", verdict(judge_case("q7a", gl("q7a", answered="0/0"), sample(), CENTRAL, pids=["10", "10", "11"])), "FAIL")
    check("pid changed between cases -> INVALID", verdict(judge_case("q7a", gl("q7a", answered="0/0"), sample(), CENTRAL, pids=["9", "10", "10"])), "INVALID")
    # encryption (E1): a real 04 capture of an encrypted pairing (the prov-sec-bond flip, masked) must FAIL
    fx = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fixtures", "btmon-254", "flip.txt")
    flip = open(fx, encoding="utf-8").read()
    flip = flip.replace("Handle: <masked>", "Handle: 64").replace("Peer address: <masked>", "Peer address: %s" % CENTRAL)
    flip = flip.replace("Status: <masked>", "Status: Success (0x00)")
    flip_recs = parse(flip)
    enc = encryption_lines(flip_recs, 64)
    check("E1 negative control: the masked flip capture (real 04 peripheral pairing) shows SMP + LTK reply + Encryption Change",
          (any(e.startswith("SMP:") for e in enc), any("0x001a" in e for e in enc), "Encryption Change" in enc), (True, True, True))
    check("E1: an SMP Pairing Request on the case's link -> FAIL",
          verdict(judge_case("t2", gl("t2", answered="1/1", lost="no"), sample(enc=True, disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P)), "FAIL")
    # hs=none (A2-M2 / A3-m8)
    hsn = gl("q1", hs="none", warm="0", answered="0/0", lost="no")
    check("hs=none first time -> RETRY", verdict(judge_case("q1", hsn, acc, CENTRAL, pids=P)), "RETRY")
    check("hs=none with STATUS 0x0E -> INVALID", verdict(judge_case("q1", gl("q1", hs="none", status0="att:0x0e", lost="no"), acc, CENTRAL, pids=P)), "INVALID")
    check("hs=none retry, no real handshake seen for this pid -> INVALID", verdict(judge_case("q1", hsn, acc, CENTRAL, pids=P, retry=True)), "INVALID")
    check("hs=none retry, real handshake seen, no foreign -> FAIL", verdict(judge_case("q1", hsn, acc, CENTRAL, pids=P, retry=True, real_seen=True)), "FAIL")
    check("hs=none retry with a foreign central -> INVALID", verdict(judge_case("q1", hsn, sample(extra_conn=OTHER, disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P, retry=True, real_seen=True)), "INVALID")
    check("conn refused with ATT 0x0f -> FAIL", verdict(judge_case("m1", gl("m1", conn="err:ctrl-0x0f"), acc, CENTRAL, pids=P)), "FAIL")
    # M1 frame lengths
    m1 = gl("m1", answered="1/1", lost="no", nlen="244,244,212/97")
    check("M1: 244-byte frames at MTU 517 -> PASS", verdict(judge_case("m1", m1, acc, CENTRAL, pids=P)), "PASS")
    check("M1: 244-byte frames when the MTU at subscription was 100 -> FAIL",
          verdict(judge_case("m1", m1, sample(mtu=(100, 517), disc_reason=0x13, disc_cmd=False), CENTRAL, pids=P)), "FAIL")
    check("S512 skipped -> NA", verdict(judge_case("s512a", gl("s512a", skip="wmax-244"), acc, CENTRAL, pids=P)), "NA")
    check("B1x deadline -> FAIL", verdict(judge_case("b1x", gl("b1x", answered="10/1001").replace("rc=0", "rc=124"), acc, CENTRAL, pids=P)), "FAIL")
    # liveness
    good = "\n".join("%d ok 900 %d" % (1000 * i, 5000 + i) for i in range(20))
    check("live: every probe ok -> PASS", verdict(judge_live(good)), "PASS")
    hang = "\n".join("%d %s 900 5000" % (1000 * i, "timeout" if 5 <= i < 17 else "ok") for i in range(20))
    check("live: 12 s of timeouts -> FAIL (hang)", verdict(judge_live(hang)), "FAIL")
    check("live: bluetoothd pid changed -> FAIL", verdict(judge_live(good + "\n21000 ok 901 5000")), "FAIL")
    check("live: a 10 s gap in the log -> INVALID", verdict(judge_live("1000 ok 900 1\n2000 ok 900 1\n12000 ok 900 1")), "INVALID")
    check("live: empty log -> INVALID", verdict(judge_live("")), "INVALID")
    # E2
    rw_ok = "NOTIFY n=3 bytes=709\n" + "\n".join("NVAL " + h for h in ("01" + "0000" + "00" * 241, "00" + "0001" + "00" * 241, "02" + "0002" + "00" * 218))
    s02 = sample(disc_reason=0x13, disc_cmd=False)
    rd02 = "\n".join(l for l in s02.splitlines() if "0x0014 Type" not in l and "Notification" not in l)
    check("E2: notifications total = msg2 length, read control clean -> PASS", verdict(judge_e2(rw_ok, s02, rd02, CENTRAL, 700)), "PASS")
    check("E2: no notification -> FAIL", verdict(judge_e2("NOTIFY n=0 bytes=0", s02, rd02, CENTRAL, 700)), "FAIL")
    check("E2: read control has a notification -> FAIL", verdict(judge_e2(rw_ok, s02, s02, CENTRAL, 700)), "FAIL")
    check("E2: MTU 23 on 02's link -> INVALID", verdict(judge_e2(rw_ok, sample(mtu=(23, 517), disc_reason=0x13, disc_cmd=False), rd02, CENTRAL, 700)), "INVALID")
    check("E2: 02's address not in the capture -> INVALID", verdict(judge_e2(rw_ok, s02, rd02, OTHER, 700)), "INVALID")
    # post-check: every branch has its own negative control (A2-m10 / B2-m7)
    base = {"pnp_before": "a,b", "pnp_after": "a,b", "bond04": "attributes identity settings cache", "paired02": "0",
            "btmon04": "-", "pcd": "0", "orphan_wsl": "0", "orphan_win": "0", "connected04": "0"}
    mk = lambda **kw: "\n".join("%s=%s" % kv for kv in dict(base, **kw).items())  # noqa: E731
    check("post: clean -> PASS", verdict(judge_post(mk())), "PASS")
    for k, bad in (("pnp_after", "a,b,BTHLE_new"), ("bond04", "attributes identity settings 02:00:00:00:00:01"),
                   ("paired02", "1"), ("btmon04", "1234"), ("pcd", "1"), ("orphan_wsl", "1"), ("orphan_win", "1"),
                   ("connected04", "1")):
        check("post negative: %s=%s -> FAIL" % (k, bad), verdict(judge_post(mk(**{k: bad}))), "FAIL")
    check("post: an observation missing -> INVALID", verdict(judge_post("pcd=0")), "INVALID")
    check("post: connected04=unk (bus call failed) -> INVALID, never 0", verdict(judge_post(mk(connected04="unk"))), "INVALID")
    check("post: an empty orphan count -> INVALID", verdict(judge_post(mk(orphan_win=""))), "INVALID")
    # central learnt from the first case's capture (no GATT_CENTRAL): printed for the unit, then required
    lines = judge_case("m1", m1, acc, "-", pids=P)
    check("central '-' with one connection: learnt and printed",
          any(ln == "INFO gatt m1: central %s" % CENTRAL for ln in lines), True)
    check("E2 without 02's address: taken from the read capture -> PASS", verdict(judge_e2(rw_ok, s02, rd02, "-", 700)), "PASS")
    check("E2 without 02's address and a rw capture from another central -> INVALID",
          verdict(judge_e2(rw_ok, sample(central=OTHER, disc_reason=0x13, disc_cmd=False), rd02, "-", 700)), "INVALID")
    for f in fails:
        print("FAIL gattjudge selftest:", f)
    print("gattjudge selftest: %d checks, %d failed" % (n, len(fails)))
    return 1 if fails else 0


def main(argv):
    if argv[1:2] == ["--selftest"]:
        return selftest()
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    c = sub.add_parser("case")
    c.add_argument("--case", required=True)
    c.add_argument("--central", default="-")
    c.add_argument("--target", default="-")
    c.add_argument("--pids", default="")
    c.add_argument("--retry", action="store_true")
    c.add_argument("--real-seen", action="store_true")
    c.add_argument("--gatt", required=True)
    c.add_argument("--btmon", required=True)
    lv = sub.add_parser("live")
    lv.add_argument("--log", required=True)
    e = sub.add_parser("e2")
    e.add_argument("--central", default="-")
    e.add_argument("--msg2len", type=int, required=True)
    e.add_argument("--rw", required=True)
    e.add_argument("--rw-btmon", required=True)
    e.add_argument("--read-btmon", required=True)
    po = sub.add_parser("post")
    po.add_argument("--obs", required=True)
    a = ap.parse_args(argv[1:])
    rd = lambda p: open(p, encoding="utf-8", errors="replace").read() if p else ""  # noqa: E731
    if a.cmd == "case":
        lines = judge_case(a.case, rd(a.gatt), rd(a.btmon), a.central, a.target,
                           a.pids.split(",") if a.pids else None, a.retry, a.real_seen)
    elif a.cmd == "live":
        lines = judge_live(rd(a.log))
    elif a.cmd == "e2":
        lines = judge_e2(rd(a.rw), rd(a.rw_btmon), rd(a.read_btmon), a.central, a.msg2len)
    elif a.cmd == "post":
        lines = judge_post(rd(a.obs))
    else:
        ap.print_help()
        return 2
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
