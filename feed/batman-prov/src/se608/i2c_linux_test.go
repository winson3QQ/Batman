//go:build linux

package se608

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// The chip lock: a second open of the same bus node fails with ErrBusy until the first is closed; a symlink is
// not followed.
func TestOpenI2CLock(t *testing.T) {
	p := filepath.Join(t.TempDir(), "i2c-fake")
	if err := os.WriteFile(p, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	a, err := OpenI2C(p)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenI2C(p); !errors.Is(err, ErrBusy) {
		t.Fatalf("second open: %v, want ErrBusy", err)
	}
	_ = a.Close()
	b, err := OpenI2C(p)
	if err != nil {
		t.Fatalf("after release: %v", err)
	}
	_ = b.Close()
	l := filepath.Join(filepath.Dir(p), "link")
	if err := os.Symlink(p, l); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenI2C(l); err == nil {
		t.Fatal("symlink followed")
	}
	// The same lock on a character device (i2c-dev has no flock hook of its own; the generic one applies).
	c, err := OpenI2C("/dev/null")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if _, err := OpenI2C("/dev/null"); !errors.Is(err, ErrBusy) {
		t.Fatalf("second open of /dev/null: %v, want ErrBusy", err)
	}
}
