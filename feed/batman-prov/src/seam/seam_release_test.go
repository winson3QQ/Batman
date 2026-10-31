//go:build !prov_test

package seam

import (
	"os"
	"path/filepath"
	"testing"
)

// A release build never reads, deletes or acts on a killpoint file, and carries no marker. Documentation more than
// proof: the release Arm cannot know the test path. The real guarantee is the firmware build gate
// (check-prov-test-gate.sh: no prov_test tag, no marker, no "killpoint" string in the shipped helper).
func TestReleaseIsANoOp(t *testing.T) {
	if Marker != "" || Enabled {
		t.Fatalf("release build: Marker %q Enabled %v", Marker, Enabled)
	}
	d := filepath.Join(t.TempDir(), "kp")
	os.Mkdir(d, 0o700)
	f := filepath.Join(d, "killpoint")
	os.WriteFile(f, []byte("txn-1"), 0o600)
	var lines []string
	logf := func(string, ...any) { lines = append(lines, "x") }
	Arm(logf)
	At(Txn1, logf)
	if len(lines) != 0 {
		t.Fatalf("release build logged %d lines", len(lines))
	}
	if _, err := os.Stat(f); err != nil {
		t.Fatalf("release build touched the file: %v", err)
	}
}
