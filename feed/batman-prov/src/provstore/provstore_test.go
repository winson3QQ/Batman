package provstore

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"batman-prov/cbor"
)

func b(n int, c byte) []byte { return bytes.Repeat([]byte{c}, n) }

func TestRoundTripAndInvariants(t *testing.T) {
	r := &Record{Generation: 3, State: Member, RadioManaged: true, ClaimedCounter: 1,
		Owners:      []Owner{{Pub: b(65, 4), EncPub: b(65, 5), TagKey: b(32, 6)}},
		AdvOwnerKey: b(32, 7), Admins: [][]byte{b(65, 8)},
		Net:          &Net{Config: []byte{0xd2}, Secrets: []byte{0xd2}, Version: 1, NetID: b(16, 9)},
		SSHKeysAdded: []string{"ssh-ed25519 AAAA x"}}
	enc, err := r.Encode()
	if err != nil {
		t.Fatal(err)
	}
	r2, err := Decode(enc)
	if err != nil {
		t.Fatal(err)
	}
	enc2, _ := r2.Encode()
	if !bytes.Equal(enc, enc2) {
		t.Fatal("round trip differs")
	}
	// invariant: a member without a network is refused; legacy with owners is refused
	bad := *r
	bad.Net = nil
	e, _ := bad.Encode()
	if _, err := Decode(e); err == nil {
		t.Fatal("member without net accepted")
	}
	bad = Record{State: Legacy, Owners: r.Owners}
	e, _ = bad.Encode()
	if _, err := Decode(e); err == nil {
		t.Fatal("legacy with owners accepted")
	}
	// an extra key (unknown field) is refused
	x, _ := cbor.Decode(enc)
	m := append(x.(cbor.Map), cbor.Entry{K: uint64(12), V: true})
	e, _ = cbor.Encode(m)
	if _, err := Decode(e); err == nil {
		t.Fatal("unknown key accepted")
	}
	// v = 2 -> ErrTooNew
	m = x.(cbor.Map).Without(1)
	m = append(m, cbor.Entry{K: uint64(1), V: uint64(2)})
	e, _ = cbor.Encode(m)
	if _, err := Decode(e); err != ErrTooNew {
		t.Fatalf("v=2: %v", err)
	}
}

func TestMeta(t *testing.T) {
	r := &Record{Generation: 7, State: Unclaimed}
	enc, _ := r.Encode()
	line := MetaLine(r, enc)
	if !strings.HasPrefix(line, "v=1 state=unclaimed gen=7 sha=") || !strings.HasSuffix(line, " rm=0\n") {
		t.Fatalf("meta %q", line)
	}
	m, err := ParseMeta([]byte(line))
	if err != nil || m.Gen != 7 || m.State != Unclaimed {
		t.Fatalf("parse: %v", err)
	}
	for _, bad := range []string{"v=1 state=Claimed gen=1 sha=" + strings.Repeat("a", 64), "v=2 state=claimed gen=1 sha=" + strings.Repeat("a", 64),
		"v=1 state=claimed gen=x sha=" + strings.Repeat("a", 64), "v=1 state=claimed gen=1 sha=abc", "v=1 state=claimed gen=1 sha=" + strings.Repeat("a", 64) + "\nx"} {
		if _, err := ParseMeta([]byte(bad)); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}

func TestOverlayWriteLoad(t *testing.T) {
	p := Paths{Dir: filepath.Join(t.TempDir(), "batman-prov")}
	r := &Record{Generation: 1, State: Legacy}
	if _, _, err := WriteOverlay(p, r); err != nil {
		t.Fatal(err)
	}
	r2, m, err := LoadOverlay(p)
	if err != nil || r2.State != Legacy || m.Gen != 1 {
		t.Fatalf("load: %v", err)
	}
	// tamper the record -> its meta sha no longer matches
	os.WriteFile(p.Record(), []byte{0xa0}, 0o600)
	if _, _, err := LoadOverlay(p); err == nil {
		t.Fatal("tampered record loaded")
	}
	// absent -> (nil, nil, nil)
	q := Paths{Dir: filepath.Join(t.TempDir(), "none")}
	if r, m, err := LoadOverlay(q); r != nil || m != nil || err != nil {
		t.Fatal("absent overlay")
	}
}

// PersistP5 hands config-save exactly the documented arguments and a clean environment.
func TestPersistArgs(t *testing.T) {
	d := t.TempDir()
	fake := filepath.Join(d, "cs")
	os.WriteFile(fake, []byte("#!/bin/sh\necho \"$@|$(env | sort | tr '\\n' ' ')\"\nexit 0\n"), 0o755)
	t.Setenv("SECRET_SHOULD_NOT_PASS", "x")
	rc, out := PersistP5(Paths{ConfigSave: fake}, "/r", "/m", "/i", "tok")
	if rc != 0 || !strings.HasPrefix(out, "--prov-only --prov-file /r --prov-meta /m --prov-identity /i --txn tok|") {
		t.Fatalf("rc=%d out=%q", rc, out)
	}
	if strings.Contains(out, "SECRET_SHOULD_NOT_PASS") {
		t.Fatal("environment leaked into config-save")
	}
}
