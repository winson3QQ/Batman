package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"batman-prov/keystore"
	"batman-prov/provstore"
)

// prov-unit-auth (254-p1-impl §5.1) "qr limits": the claim QR (device id + claim secret) is printed only for an unclaimed
// node; claimed / member refuse; legacy refuses unless dev-open or a physical console (here: stdin is not a console and
// the host has no /etc/batman-dev-open). Each record must LOAD first, so a refusal is qr's decision and not a record
// the store rejects (first version: an owner-less claimed record never loaded and the claimed case passed vacuously —
// the flip "qr lets claimed through" was not caught).
func TestQRLimits(t *testing.T) {
	if _, err := os.Stat("/etc/batman-dev-open"); err == nil {
		t.Skip("this host has /etc/batman-dev-open: the legacy case cannot be judged")
	}
	pub := append([]byte{4}, bytes.Repeat([]byte{7}, 64)...)
	for _, c := range []struct {
		state string
		want  int
	}{{provstore.Unclaimed, 0}, {provstore.Claimed, 1}, {provstore.Member, 1}, {provstore.Legacy, 1}} {
		root := t.TempDir()
		p := provstore.Paths{Dir: filepath.Join(root, "prov"), RunDir: filepath.Join(root, "run")}
		os.MkdirAll(p.Dir, 0o700)
		if err := keystore.Generate(p.Identity()); err != nil {
			t.Fatal(err)
		}
		r := &provstore.Record{Generation: 1, State: c.state}
		if c.state == provstore.Claimed || c.state == provstore.Member {
			r.Owners = []provstore.Owner{{Pub: pub, EncPub: pub, TagKey: bytes.Repeat([]byte{9}, 32)}}
			r.ClaimedCounter = 1
		}
		if c.state == provstore.Member { // a member also has a network (provstore schema)
			r.Net = &provstore.Net{Config: []byte{0xa0}, Secrets: []byte{0xa0}, Version: 1, NetID: bytes.Repeat([]byte{3}, 16)}
		}
		if _, _, err := provstore.WriteOverlay(p, r); err != nil {
			t.Fatal(err)
		}
		if got, _, err := provstore.LoadOverlay(p); err != nil || got == nil || got.State != c.state {
			t.Fatalf("the %s record does not load (%v) — the qr verdict would prove nothing", c.state, err)
		}
		if got := qr(p); got != c.want {
			t.Errorf("qr on a %s node: rc %d, want %d", c.state, got, c.want)
		}
	}
	// no record at all: refused
	if got := qr(provstore.Paths{Dir: filepath.Join(t.TempDir(), "none")}); got != 1 {
		t.Errorf("qr without a record: rc %d, want 1", got)
	}
}
