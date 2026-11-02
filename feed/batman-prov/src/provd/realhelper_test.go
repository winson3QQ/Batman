package provd

// provd against the REAL helper code (node.Node, in this test process) instead of the fake helper: the argument
// shapes provd builds (claim.verify's 5 fields, the forwarded envelope, the nonce pair) are judged by the code that
// runs on the node, with its real CheckMac / owner-op / nonce rules. Only the side effects outside the helper's own
// files are stubbed (p5 = a directory, the lock / password steps succeed).

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"batman-prov/cbor"
	"batman-prov/keystore"
	"batman-prov/node"
	"batman-prov/provstore"
)

type stubSys struct{ p5 string }

func cpFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o600)
}

func (s *stubSys) IsTrial() bool { return false }
func (s *stubSys) Persist(r, m, id, txn string) (int, string) {
	os.MkdirAll(s.p5, 0o700)
	if cpFile(r, filepath.Join(s.p5, "prov.cbor")) != nil || cpFile(m, filepath.Join(s.p5, "prov.meta")) != nil {
		return 1, "persist"
	}
	return 0, ""
}
func (s *stubSys) GetP5(dir string) (int, string) {
	os.MkdirAll(dir, 0o700)
	if cpFile(filepath.Join(s.p5, "prov.meta"), filepath.Join(dir, "prov.meta")) != nil {
		return 9, ""
	}
	cpFile(filepath.Join(s.p5, "prov.cbor"), filepath.Join(dir, "prov.cbor"))
	return 0, ""
}
func (s *stubSys) Save() (int, string)                  { return 0, "" }
func (s *stubSys) SetKeyNoPersist(_, _, _ string) error { return errors.New("not in this test") }
func (s *stubSys) CurrentWireless() (string, string, string, error) {
	return "", "", "", errors.New("not in this test")
}
func (s *stubSys) SaveTxn(string) (int, string) { return 0, "" }
func (s *stubSys) ForgetMesh() error            { return errors.New("not in this test") }
func (s *stubSys) RadioState() (bool, bool, error) {
	return false, false, errors.New("not in this test")
}
func (s *stubSys) SetMeshExpect(string) error              { return nil }
func (s *stubSys) CheckRestorable(_, _, _ string) error    { return nil }
func (s *stubSys) LiveMeshUp() bool                        { return false }
func (s *stubSys) ApplyLock(string) error                  { return nil }
func (s *stubSys) RestoreRoot(string) error                { return nil }
func (s *stubSys) RootField() (string, error)              { return "!", nil }
func (s *stubSys) MarkLockIncomplete()                     {}
func (s *stubSys) SetLastKnown(string) error               { return nil }
func (s *stubSys) CryptPassword(pw string) (string, error) { return "$6$x$" + pw, nil }
func (s *stubSys) AuthorizedKeys() ([]string, error)       { return nil, nil }
func (s *stubSys) SetAuthorizedKeys([]string) error        { return nil }
func (s *stubSys) DevOpen() bool                           { return true }
func (s *stubSys) WriteTxnMarker(string) error             { return nil }
func (s *stubSys) ClearTxnMarker()                         {}
func (s *stubSys) DiagBundle() ([]byte, error)             { return nil, errors.New("not in this test") }
func (s *stubSys) RemoveMeshMarkers() error                { return nil }
func (s *stubSys) Now() time.Time                          { return time.Now() }

// realHelper serves node.Node on a SEQPACKET socket (one goroutine per connection, as sock.ServeConns)
func realHelper(t *testing.T) (path string, claimSecret []byte) {
	root := t.TempDir()
	p := provstore.Paths{Dir: filepath.Join(root, "prov"), RunDir: filepath.Join(root, "run")}
	os.MkdirAll(p.RunDir, 0o700)
	os.MkdirAll(p.Dir, 0o700)
	if err := keystore.Generate(p.Identity()); err != nil {
		t.Fatal(err)
	}
	ks, err := keystore.Load(p.Identity())
	if err != nil {
		t.Fatal(err)
	}
	provstore.WriteOverlay(p, &provstore.Record{Generation: 1, State: provstore.Unclaimed})
	n := node.New(p, ks, &stubSys{p5: filepath.Join(root, "p5")}, t.Logf)
	n.Verdict = provstore.Unclaimed
	n.Health = func() string {
		return "boot_id=b ts=1 bluetoothd=1 hci0_powered=1 privacy=1 sc=1 sc_file=1 bondable=0 num_instances=0\n"
	}
	path = filepath.Join(root, "helper.sock")
	ln, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: path, Net: "unixpacket"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.AcceptUnix()
			if err != nil {
				return
			}
			go func(c *net.UnixConn) {
				defer c.Close()
				h := n.NewConn()
				buf := make([]byte, 70000)
				for {
					k, err := c.Read(buf)
					if err != nil {
						return
					}
					x, err := cbor.Decode(buf[:k])
					if err != nil {
						return
					}
					out, _ := cbor.Encode(h(x.(cbor.Map)))
					if _, err := c.Write(out); err != nil {
						return
					}
				}
			}(c)
		}
	}()
	sec, err := os.ReadFile(filepath.Join(p.Identity(), "claim.secret"))
	if err != nil {
		t.Fatal(err)
	}
	return path, sec
}
