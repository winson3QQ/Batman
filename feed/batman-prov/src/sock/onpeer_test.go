package sock

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"batman-prov/cbor"
)

// OnPeer gets the peer's SO_PEERCRED pid / uid and a channel closed when the connection ends (254-p3-impl §3.7.6)
func TestOnPeer(t *testing.T) {
	needRoot(t)
	dir := filepath.Join(t.TempDir(), "batman-prov")
	if err := PrepareDir(dir, 0); err != nil {
		t.Fatal(err)
	}
	type peer struct {
		pid, uid int
		done     <-chan struct{}
	}
	got := make(chan peer, 1)
	s := &Server{Path: filepath.Join(dir, "helper.sock"), PeerUID: os.Getuid(), GID: 0, Idle: 5 * time.Second, Log: t.Logf,
		OnPeer: func(pid, uid int, done <-chan struct{}) { got <- peer{pid, uid, done} }}
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	go s.Serve(func(m cbor.Map) cbor.Map { id, _ := m.Get(2); return cbor.M(1, id, 2, uint64(0), 3, cbor.M()) })
	c := dial(t, s.Path)
	if id, err := roundTrip(t, c, 1); err != nil || id != 1 {
		t.Fatalf("round trip: %v", err)
	}
	var p peer
	select {
	case p = <-got:
	case <-time.After(2 * time.Second):
		t.Fatal("OnPeer not called")
	}
	if p.pid != os.Getpid() || p.uid != os.Getuid() {
		t.Fatalf("peer pid %d uid %d, want %d %d", p.pid, p.uid, os.Getpid(), os.Getuid())
	}
	select {
	case <-p.done:
		t.Fatal("done closed while the connection is open")
	default:
	}
	c.Close()
	select {
	case <-p.done:
	case <-time.After(3 * time.Second):
		t.Fatal("done not closed when the connection ended")
	}
}
