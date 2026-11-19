package provd

import (
	"bytes"
	"testing"
	"time"

	"batman-prov/cbor"
)

// #329 rotating identifier (docs/design/329-rotating-id-plan.md §9, G5): Server.AdvID — one adv.id on ro, never
// waiting for ro, never on ctl.

func advHelper(t *testing.T, h func() (int, cbor.Map)) (*Server, *fakeHelper) {
	f := newFakeHelper(t)
	f.set(func(f *fakeHelper) {
		f.handler = func(verb string, _ cbor.Map) (int, cbor.Map, bool) {
			if verb != "adv.id" {
				return 0, nil, false
			}
			c, b := h()
			return c, b, true
		}
	})
	return startServer(t, f, TestEnv{}), f
}

func TestAdvIDAnswer(t *testing.T) {
	want := []byte{1, 2, 3, 4, 5, 6}
	s, f := advHelper(t, func() (int, cbor.Map) { return 0, cbor.M(1, want) })
	id, err := s.AdvID(2 * time.Second)
	if err != nil || !bytes.Equal(id, want) {
		t.Fatalf("%x %v", id, err)
	}
	if a := f.last("adv.id"); len(a) != 0 {
		t.Fatalf("adv.id sent with arguments %v", a)
	}
}

// anything but code 0 with exactly {1: 6 bytes} is an error (the advert then carries no field)
func TestAdvIDBadAnswers(t *testing.T) {
	for name, h := range map[string]func() (int, cbor.Map){
		"EUnsupported": func() (int, cbor.Map) { return 9, cbor.M() },
		"5 bytes":      func() (int, cbor.Map) { return 0, cbor.M(1, make([]byte, 5)) },
		"7 bytes":      func() (int, cbor.Map) { return 0, cbor.M(1, make([]byte, 7)) },
		"a string":     func() (int, cbor.Map) { return 0, cbor.M(1, "abcdef") },
		"an extra key": func() (int, cbor.Map) { return 0, cbor.M(1, make([]byte, 6), 2, make([]byte, 32)) },
		"empty":        func() (int, cbor.Map) { return 0, cbor.M() },
	} {
		s, _ := advHelper(t, h)
		if id, err := s.AdvID(2 * time.Second); err == nil {
			t.Fatalf("%s: accepted as %x", name, id)
		}
	}
}

// G5: a helper that does not answer costs AdvID its wait and no more; ro is closed (the next call reconnects) and
// the ctl poll goes on meanwhile
func TestAdvIDHelperStall(t *testing.T) {
	stall := make(chan struct{})
	n := 0
	s, f := advHelper(t, func() (int, cbor.Map) {
		n++
		if n == 1 {
			<-stall
		}
		return 0, cbor.M(1, make([]byte, 6))
	})
	defer close(stall)
	polls := f.count("health.get")
	t0 := time.Now()
	_, err := s.AdvID(2 * time.Second)
	if d := time.Since(t0); err != ErrTimeout || d > 2100*time.Millisecond {
		t.Fatalf("stalled helper: %v after %s", err, d)
	}
	if got := f.count("health.get"); got < polls+5 {
		t.Fatalf("ctl poll during the stall: %d -> %d health.get", polls, got)
	}
	if !s.Ready() {
		t.Fatal("the server is not ready after the stall")
	}
	// ro was closed: the next call is answered on a new connection (the old one's handler is still stalled)
	if id, err := s.AdvID(2 * time.Second); err != nil || len(id) != 6 {
		t.Fatalf("after the stall: %x %v", id, err)
	}
}

// G5: a session's read holds ro -> ErrBusy at once, and adv.id is not sent
func TestAdvIDRoBusy(t *testing.T) {
	s, f := advHelper(t, func() (int, cbor.Map) { return 0, cbor.M(1, make([]byte, 6)) })
	s.roMu.Lock()
	t0 := time.Now()
	_, err := s.AdvID(2 * time.Second)
	d := time.Since(t0)
	s.roMu.Unlock()
	if err != ErrBusy || d > 200*time.Millisecond {
		t.Fatalf("ro held: %v after %s", err, d)
	}
	if f.count("adv.id") != 0 {
		t.Fatal("adv.id was sent while ro was held")
	}
}
