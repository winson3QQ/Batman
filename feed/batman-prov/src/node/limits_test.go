package node

import (
	"testing"
	"time"

	"batman-prov/cbor"
)

// prov-unit-auth (254-p1-impl §5.1): the global signing rate — 2 signatures per second, whatever the arguments (the limit
// is checked before them), and free again once a second has passed.
func TestSigningRateGlobal2PerSecond(t *testing.T) {
	r := claimedRig(t)
	for i := 0; i < 2; i++ {
		if _, e := r.n.sign("sign.static", cbor.M()); e != nil && e.Code == ERate {
			t.Fatalf("call %d within the limit refused for rate", i+1)
		}
	}
	if _, e := r.n.sign("sign.static", cbor.M()); e == nil || e.Code != ERate {
		t.Fatalf("third signature within one second: %v (want E_RATE %d)", e, ERate)
	}
	r.sys.now = r.sys.now.Add(time.Second)
	if _, e := r.n.sign("sign.static", cbor.M()); e != nil && e.Code == ERate {
		t.Fatal("still rate-limited one second later")
	}
}

// claim.replay: 10 failed attempts in an hour, then every attempt — a valid one too — is refused with E_RATE until the
// oldest failure is an hour old.
func TestReplayFailuresLimit10PerHour(t *testing.T) {
	r := claimedRig(t)
	for i := 0; i < 10; i++ {
		c, _ := r.call("claim.replay", cbor.M(1, r.h, 2, []byte{0x01, 0x02, 0x03}))
		if c == OK || c == ERate {
			t.Fatalf("garbage replay %d: code %d (want a refusal that counts)", i+1, c)
		}
		r.sys.now = r.sys.now.Add(time.Minute)
	}
	if c, _ := r.replay(); c != ERate {
		t.Fatalf("a valid replay after 10 failures in the hour: code %d (want E_RATE %d)", c, ERate)
	}
	r.sys.now = r.sys.now.Add(time.Hour)
	if c, _ := r.replay(); c != OK {
		t.Fatalf("a valid replay once the failures are an hour old: code %d", c)
	}
}
