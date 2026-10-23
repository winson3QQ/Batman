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
