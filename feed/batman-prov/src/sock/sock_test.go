package sock

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"batman-prov/cbor"
)

func needRoot(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root (chown of the socket dir); run in the WSL root / sandbox job")
	}
}

func start(t *testing.T, peer int) (string, *Server) {
	dir := filepath.Join(t.TempDir(), "batman-prov")
	if err := PrepareDir(dir, 0); err != nil {
		t.Fatal(err)
	}
	s := &Server{Path: filepath.Join(dir, "helper.sock"), PeerUID: peer, GID: 0, Idle: 2 * time.Second, Log: t.Logf}
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	go s.Serve(func(m cbor.Map) cbor.Map { id, _ := m.Get(2); return cbor.M(1, id, 2, uint64(0), 3, cbor.M(1, "pong")) })
	t.Cleanup(func() { s.Close() })
	return s.Path, s
}

func dial(t *testing.T, p string) *net.UnixConn {
	c, err := net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: p, Net: "unixpacket"})
	if err != nil {
		t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(3 * time.Second))
	return c
}

func TestAllowedPeer(t *testing.T) {
	needRoot(t)
	p, _ := start(t, os.Getuid())
	c := dial(t, p)
	defer c.Close()
	req, _ := cbor.Encode(cbor.M(1, "info.state", 2, uint64(5), 3, cbor.M()))
	c.Write(req)
	buf := make([]byte, 4096)
	n, err := c.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	x, err := cbor.Decode(buf[:n])
	if err != nil {
		t.Fatal(err)
	}
	if id, _ := x.(cbor.Map).Get(1); id != uint64(5) {
		t.Fatalf("resp %v", x)
	}
	fi, _ := os.Stat(p)
	if fi.Mode().Perm() != 0o660 {
		t.Fatalf("socket mode %o", fi.Mode().Perm())
	}
}

func TestWrongPeerClosed(t *testing.T) {
	needRoot(t)
	p, _ := start(t, 471) // provd; we are root -> refused
	c := dial(t, p)
	defer c.Close()
	req, _ := cbor.Encode(cbor.M(1, "info.state", 2, uint64(1), 3, cbor.M()))
	c.Write(req)
	if _, err := c.Read(make([]byte, 100)); err == nil {
		t.Fatal("a non-provd peer got an answer")
	}
}

func TestOversizeAndMalformedClose(t *testing.T) {
	needRoot(t)
	p, _ := start(t, os.Getuid())
	c := dial(t, p)
	c.Write(make([]byte, MaxRequest+10))
	if _, err := c.Read(make([]byte, 100)); err == nil {
		t.Fatal("oversize request answered")
	}
	c.Close()
	c = dial(t, p)
	defer c.Close()
	c.Write([]byte{0xa2, 0x02, 0x01, 0x01, 0x01}) // unsorted keys: not deterministic
	buf := make([]byte, 100)
	n, _ := c.Read(buf)
	x, _ := cbor.Decode(buf[:n])
	if code, _ := x.(cbor.Map).Get(2); code != uint64(20) {
		t.Fatalf("malformed: %v", x)
	}
	if _, err := c.Read(buf); err == nil {
		t.Fatal("connection kept after a malformed packet")
	}
}

func TestPrepareDirRefusals(t *testing.T) {
	needRoot(t)
	base := t.TempDir()
	// a symlink in place of the dir
	os.Symlink(base, filepath.Join(base, "link"))
	if err := PrepareDir(filepath.Join(base, "link"), 0); err == nil {
		t.Fatal("symlinked socket dir accepted")
	}
	// a foreign-owned dir
	d := filepath.Join(base, "foreign")
	os.Mkdir(d, 0o755)
	os.Chown(d, 65534, 65534)
	if err := PrepareDir(d, 0); err == nil {
		t.Fatal("foreign-owned socket dir accepted")
	}
	// an unexpected entry (e.g. a planted file) in our dir
	d2 := filepath.Join(base, "ours")
	os.Mkdir(d2, 0o750)
	os.WriteFile(filepath.Join(d2, "helper.sock"), []byte("x"), 0o644)
	if err := PrepareDir(d2, 0); err == nil {
		t.Fatal("a planted regular file named helper.sock was accepted / removed")
	}
}

func roundTrip(t *testing.T, c *net.UnixConn, id uint64) (uint64, error) {
	req, _ := cbor.Encode(cbor.M(1, "x", 2, id, 3, cbor.M()))
	if _, err := c.Write(req); err != nil {
		return 0, err
	}
	buf := make([]byte, 4096)
	n, err := c.Read(buf)
	if err != nil {
		return 0, err
	}
	x, err := cbor.Decode(buf[:n])
	if err != nil {
		return 0, err
	}
	got, _ := x.(cbor.Map).Get(1)
	v, _ := got.(uint64)
	return v, nil
}

// 254-p2-impl §1.3 / L71: a second connection is answered while the first one runs a long verb. Negative control: the
// pre-P2 Serve (one connection at a time) answers the second only after the first closes -> the 1 s deadline fails.
func TestSecondConnectionNotBlocked(t *testing.T) {
	needRoot(t)
	dir := filepath.Join(t.TempDir(), "batman-prov")
	if err := PrepareDir(dir, 0); err != nil {
		t.Fatal(err)
	}
	s := &Server{Path: filepath.Join(dir, "helper.sock"), PeerUID: os.Getuid(), GID: 0, Idle: 5 * time.Second, Log: t.Logf}
	if err := s.Listen(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	release := make(chan struct{})
	go s.Serve(func(m cbor.Map) cbor.Map {
		id, _ := m.Get(2)
		if id == uint64(1) {
			<-release // the "long verb"
		}
		return cbor.M(1, id, 2, uint64(0), 3, cbor.M())
	})
	slow := dial(t, s.Path)
	defer slow.Close()
	req, _ := cbor.Encode(cbor.M(1, "x", 2, uint64(1), 3, cbor.M()))
	slow.Write(req)
	time.Sleep(100 * time.Millisecond)
	fast := dial(t, s.Path)
	defer fast.Close()
	fast.SetDeadline(time.Now().Add(time.Second))
	if id, err := roundTrip(t, fast, 2); err != nil || id != 2 {
		t.Fatalf("second connection blocked behind the first: %v %d", err, id)
	}
	close(release)
}

// the fifth connection is closed at once; a slot frees when a connection ends
func TestFifthConnectionClosed(t *testing.T) {
	needRoot(t)
	p, _ := start(t, os.Getuid())
	var cs []*net.UnixConn
	for i := 0; i < MaxConns; i++ {
		c := dial(t, p)
		defer c.Close()
		if _, err := roundTrip(t, c, uint64(i+1)); err != nil {
			t.Fatalf("conn %d: %v", i, err)
		}
		cs = append(cs, c)
	}
	c5 := dial(t, p)
	if _, err := roundTrip(t, c5, 9); err == nil {
		t.Fatal("a fifth connection was served")
	}
	c5.Close()
	cs[0].Close()
	time.Sleep(1100 * time.Millisecond) // the slot goes when the goroutine ends; the accept window empties
	c6 := dial(t, p)
	defer c6.Close()
	if _, err := roundTrip(t, c6, 10); err != nil {
		t.Fatalf("slot not freed: %v", err)
	}
}

// more than AcceptPerSec admitted connections in a second -> closed (a per-connection quota cannot be reset by churn).
// Mutant: admit() always true -> the sixth answers -> FAIL.
func TestAcceptRate(t *testing.T) {
	needRoot(t)
	p, _ := start(t, os.Getuid())
	ok := 0
	for i := 0; i < AcceptPerSec+1; i++ {
		c := dial(t, p)
		if _, err := roundTrip(t, c, uint64(i+1)); err == nil {
			ok++
		}
		c.Close()
	}
	if ok != AcceptPerSec {
		t.Fatalf("%d of %d churned connections served (want %d)", ok, AcceptPerSec+1, AcceptPerSec)
	}
	time.Sleep(1100 * time.Millisecond)
	c := dial(t, p)
	defer c.Close()
	if _, err := roundTrip(t, c, 99); err != nil {
		t.Fatalf("not admitted after the window: %v", err)
	}
}
