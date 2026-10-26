package main

import (
	"os"
	"path/filepath"
	"testing"

	"batman-prov/provstore"
)

// SetLastKnown rewrites ONLY field 3 of p6 prov-state (claim-lock fix §5.4): field 6 (mesh_expect) is read by
// autocommit's OTA gate and must survive; the file stays 0600; a short / missing file is left alone.
func TestSetLastKnownOnlyField3(t *testing.T) {
	d := t.TempDir()
	f := filepath.Join(d, "prov-state")
	os.WriteFile(f, []byte("bootid helper legacy legacy - 1\n"), 0o600)
	s := realSys{provstore.Paths{State: d}}
	if err := s.SetLastKnown("claimed"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(f)
	if string(b) != "bootid helper claimed legacy - 1\n" {
		t.Fatalf("got %q", b)
	}
	if fi, _ := os.Stat(f); fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", fi.Mode().Perm())
	}
	os.WriteFile(f, []byte("short line\n"), 0o600)
	if err := s.SetLastKnown("claimed"); err == nil {
		t.Fatal("a malformed prov-state was rewritten")
	}
	if b, _ := os.ReadFile(f); string(b) != "short line\n" {
		t.Fatalf("malformed file changed: %q", b)
	}
	os.Remove(f)
	if err := s.SetLastKnown("claimed"); err == nil {
		t.Fatal("a missing prov-state was created")
	}
}
