package provd

// The app's update fixtures, second half (Batman-app docs/design/254-app-update.md v0.4 §8): the helper replies of
// node's TestCaptureAppUpdateReplies sent through a real provd session (fake helper answering with them, a Go phone on
// psk_owner + auth/owner, owner-ops with key 31) -> the response envelopes the app receives; provd's own answers
// (E_RATE per connection, E_BUSY "outcome unknown" when the helper does not answer in time); and the PUT's HTTP
// answers on the TCP level (status line + headers, with or without the body read).
// Without BATMAN_CAPTURE_DIR it runs a built-in set of helper replies (each kind the app tells apart) and asserts the
// envelopes; with it, it reads $BATMAN_CAPTURE_DIR/node-helper.json (missing = FAIL) and writes provd-wire.json:
//
//	d=$(mktemp -d); BATMAN_CAPTURE_DIR=$d go test ./node -run TestCaptureApp && BATMAN_CAPTURE_DIR=$d go test ./provd -run TestCaptureApp

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"batman-prov/cbor"
)

type helperCase struct {
	Name string `json:"name"`
	Verb string `json:"verb"`
	Code int    `json:"code"`
	Body string `json:"body"`
}

// wireCase: what the app reads: Status = envelope key 4; Body = key 3 (ok) or key 5 (error), hex CBOR
type wireCase struct {
	Name   string `json:"name"`
	Verb   string `json:"verb"`
	Status uint64 `json:"status"`
	Body   string `json:"body"`
}

var appHelperVerb = map[string]string{"update/check": "update.check", "update/status": "update.status",
	"update/prepare": "update.prepare", "update/apply": "update.apply", "bulk/open": "bulk.open", "bulk/close": "bulk.close"}

func TestCaptureAppWire(t *testing.T) {
	dir := os.Getenv("BATMAN_CAPTURE_DIR")
	var in struct {
		Manifest string       `json:"manifest"`
		Sha      string       `json:"sha"`
		Cases    []helperCase `json:"cases"`
	}
	if dir != "" {
		b, err := os.ReadFile(filepath.Join(dir, "node-helper.json"))
		if err != nil {
			t.Fatalf("BATMAN_CAPTURE_DIR set but no node-helper.json (run node's TestCaptureApp first): %v", err)
		}
		if err := json.Unmarshal(b, &in); err != nil || len(in.Cases) == 0 {
			t.Fatalf("node-helper.json: %v (%d cases)", err, len(in.Cases))
		}
	} else {
		// a manifest-shaped map and one reply of each kind the app tells apart
		mf, _ := cbor.Encode(cbor.M(1, "1.5.14-wsl.30", 2, "ekh-bcm2711", 3, uint64(1), 4, bytes.Repeat([]byte{3}, 32), 5, []byte{0x80}))
		in.Manifest, in.Sha = hex.EncodeToString(mf), strings.Repeat("03", 32)
		enc := func(m cbor.Map) string { b, _ := cbor.Encode(m); return hex.EncodeToString(b) }
		in.Cases = []helperCase{
			{"check-ok", "update/check", 0, enc(cbor.M(1, true, 3, uint64(9)))},
			{"bulk-open-16", "bulk/open", hEReject, enc(cbor.M(1, uint64(16)))},
			{"prepare-busy", "update/prepare", hEBusy, enc(cbor.M())},
			{"prepare-storage", "update/prepare", hEStorage, enc(cbor.M())},
			{"bulk-close-ok", "bulk/close", 0, enc(cbor.M())},
			{"status-written", "update/status", 0, enc(cbor.M(1, uint64(3), 2, uint64(100)))},
		}
	}
	mfv, err := cbor.Decode(mustHex(t, in.Manifest))
	if err != nil {
		t.Fatal(err)
	}
	sha := mustHex(t, in.Sha)

	sk, pub := ownerKey(t)
	f, psks := claimedHelper(t, pub)
	s := startServer(t, f, TestEnv{})
	var reply struct {
		code  int
		body  cbor.Map
		delay time.Duration
	}
	f.set(func(f *fakeHelper) {
		f.handler = func(verb string, args cbor.Map) (int, cbor.Map, bool) {
			for _, v := range appHelperVerb {
				if v == verb {
					f.mu.Lock()
					c, b, d := reply.code, reply.body, reply.delay
					f.mu.Unlock()
					time.Sleep(d)
					return c, b, true
				}
			}
			return 0, nil, false
		}
	})
	owner := func() *phone {
		p := dial(t, s)
		if !p.handshake("", psks[0]) {
			t.Fatal("psk_owner handshake")
		}
		if code, _ := p.do("auth/owner", cbor.M(1, kidOf(pub), 2, authSig(t, sk, p.h, kidOf(pub)))); code != 0 {
			t.Fatalf("auth/owner %d", code)
		}
		return p
	}
	// one request as the app sends it -> the response envelope (nil = the session ended)
	send := func(p *phone, verb string) cbor.Map {
		var body cbor.Map
		switch verb {
		case "update/check":
			body = cbor.M(1, mfv)
		case "update/status":
			body = cbor.M()
		case "update/prepare", "update/apply":
			body = ownerOp(t, p, sk, verb, cbor.M(1, sha))
		case "bulk/open":
			body = ownerOp(t, p, sk, verb, cbor.M(1, uint64(0), 2, sha))
		case "bulk/close":
			body = ownerOp(t, p, sk, verb, cbor.M())
		default:
			t.Fatalf("verb %s", verb)
		}
		p.sendEnv(p.env(verb, body))
		return p.resp(10 * time.Second)
	}
	var out []wireCase
	record := func(name, verb string, env cbor.Map) wireCase {
		t.Helper()
		if env == nil {
			t.Fatalf("%s: the session ended", name)
		}
		st, _ := env.Get(4)
		k := 3
		if st != uint64(0) {
			k = 5
		}
		bv, ok := env.Get(k)
		bm, isMap := bv.(cbor.Map)
		if !ok || !isMap {
			t.Fatalf("%s: envelope %v without a body map at key %d", name, env, k)
		}
		b, _ := cbor.Encode(bm)
		w := wireCase{name, verb, st.(uint64), hex.EncodeToString(b)}
		out = append(out, w)
		return w
	}
	setReply := func(code int, body cbor.Map, d time.Duration) {
		f.set(func(*fakeHelper) { reply.code, reply.body, reply.delay = code, body, d })
	}

	main := owner() // one connection for every verb but update/check (provd's handshake rate is 20 / min)
	for _, c := range in.Cases {
		if appHelperVerb[c.Verb] == "" {
			t.Fatalf("%s: verb %s", c.Name, c.Verb)
		}
		bv, err := cbor.Decode(mustHex(t, c.Body))
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		setReply(c.Code, bv.(cbor.Map), 0)
		p := main
		if c.Verb == "update/check" {
			p = owner() // update/check is 1 / 10 s per connection
		}
		w := record(c.Name, c.Verb, send(p, c.Verb))
		if p != main {
			p.c.Close()
			waitFor(t, "slot freed", func() bool { return s.Sessions() == 1 })
		}
		// the mapping the app relies on: ok -> 0 with the helper's body (bulk/close: {}); a reason -> E_REJECTED{2: r};
		// helper E_BUSY / E_STORAGE / E_RATE -> the same code
		why, hasWhy := bv.(cbor.Map).Get(1)
		switch {
		case c.Code == 0 && w.Status != 0:
			t.Fatalf("%s: ok -> %d", c.Name, w.Status)
		case c.Code == 0 && c.Verb != "bulk/close" && w.Body != c.Body:
			t.Fatalf("%s: the body changed on the way: %s -> %s", c.Name, c.Body, w.Body)
		case c.Code == hEReject && (w.Status != ERejected || !strings.Contains(w.Body, fmt.Sprintf("02%02x", why))):
			t.Fatalf("%s: reason %v -> %d %s", c.Name, why, w.Status, w.Body)
		case (c.Code == hEBusy || c.Code == hEStorage || c.Code == hERate) && (int(w.Status) != c.Code || hasWhy):
			t.Fatalf("%s: helper %d -> %d", c.Name, c.Code, w.Status)
		}
	}

	// provd's own answers: update/check twice on one connection (E_RATE), the helper not answering in time
	// (E_BUSY "outcome unknown", HelperWait is 2 s in this package's TestMain)
	setReply(0, cbor.M(1, true, 3, uint64(9)), 0)
	p := owner()
	send(p, "update/check")
	if w := record("check-rate-connection", "update/check", send(p, "update/check")); w.Status != ERate {
		t.Fatalf("second check on one connection: %d", w.Status)
	}
	p.c.Close()
	main.c.Close()
	waitFor(t, "slots freed", func() bool { return s.Sessions() == 0 })
	for _, v := range []string{"update/prepare", "update/apply", "update/check"} {
		setReply(0, cbor.M(1, uint64(2), 2, uint64(0)), HelperWait+500*time.Millisecond)
		q := owner()
		w := record(strings.ReplaceAll(v, "/", "-")+"-outcome-unknown", v, send(q, v))
		if w.Status != EBusy || !strings.Contains(w.Body, hex.EncodeToString([]byte("outcome unknown"))) {
			t.Fatalf("%s without a helper answer: %d %s", v, w.Status, w.Body)
		}
		q.c.Close()
		time.Sleep(HelperWait) // the late answer drains before the next case
	}
	setReply(0, cbor.M(), 0)

	puts := capturePUT(t)
	if dir != "" {
		sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
		b, _ := json.MarshalIndent(map[string]any{"cases": out, "put": puts}, "", " ")
		if err := os.WriteFile(filepath.Join(dir, "provd-wire.json"), append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %d envelopes and %d PUT answers to %s", len(out), len(puts), dir)
	}
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// putCase: one PUT on a raw TCP socket — the head the app sends (bearer / Content-Length varied), whether the body
// went out, and the answer's status line and header names (Date dropped: not reproducible)
type putCase struct {
	Name     string   `json:"name"`
	SentBody bool     `json:"sent_body"`
	Status   string   `json:"status"`
	Headers  []string `json:"headers"`
	Closed   bool     `json:"closed"` // the server closed the connection after the answer
}

func capturePUT(t *testing.T) []putCase {
	h := &hfield{healthy: true}
	windowField(h)
	h.size = 1 << 20
	r := newHTTPRig(t, h)
	r.waitListening(true, "window")
	good := hex.EncodeToString(h.bearer)
	var out []putCase
	do := func(name, bearer string, n int64, body bool, want string) {
		t.Helper()
		c, err := net.Dial("tcp4", "127.0.0.1:"+strconv.Itoa(r.port))
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		head := "PUT /batman/v1/bulk/0 HTTP/1.1\r\nHost: 127.0.0.1:" + strconv.Itoa(r.port) + "\r\nX-Batman-Upload: " + bearer +
			"\r\nContent-Length: " + strconv.FormatInt(n, 10) + "\r\nConnection: close\r\n\r\n"
		if _, err := io.WriteString(c, head); err != nil {
			t.Fatal(err)
		}
		if body {
			if _, err := c.Write(make([]byte, n)); err != nil {
				t.Fatalf("%s: body: %v", name, err)
			}
		}
		c.SetReadDeadline(time.Now().Add(10 * time.Second))
		br := bufio.NewReader(c)
		status, err := br.ReadString('\n')
		if err != nil {
			t.Fatalf("%s: no status line: %v", name, err)
		}
		status = strings.TrimRight(status, "\r\n")
		if !strings.HasPrefix(status, "HTTP/1.1 "+want) {
			t.Fatalf("%s: %q, want %s", name, status, want)
		}
		pc := putCase{Name: name, SentBody: body, Status: status}
		for {
			l, err := br.ReadString('\n')
			if err != nil {
				t.Fatalf("%s: headers: %v", name, err)
			}
			l = strings.TrimRight(l, "\r\n")
			if l == "" {
				break
			}
			k, v, _ := strings.Cut(l, ":")
			if k == "Date" {
				continue
			}
			pc.Headers = append(pc.Headers, k+":"+strings.TrimSpace(v))
		}
		io.Copy(io.Discard, br)
		pc.Closed = true
		out = append(out, pc)
	}
	do("put-200", good, int64(h.size), true, "200")
	do("put-403-before-body", strings.Repeat("ab", 15)+"cd", int64(h.size), false, "403")
	do("put-400-length", good, int64(h.size)-1, false, "400")
	h.set(func(h *hfield) { h.working = true })
	time.Sleep(300 * time.Millisecond)
	do("put-409-before-body", good, int64(h.size), false, "409")
	return out
}
