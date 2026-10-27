package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"batman-prov/seam"
)

func TestVersion(t *testing.T) {
	stamp := filepath.Join(t.TempDir(), "batman-build")
	os.WriteFile(stamp, []byte("BATMAN_BOARD=ekh-bcm2711\nBATMAN_VERSION=1.5.14-wsl.5+abc1234.fwdef5678\nBATMAN_DIRTY=0\n"), 0o644)
	var b bytes.Buffer
	if rc := version(&b, stamp); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	lines := strings.Split(strings.TrimSpace(b.String()), "\n")
	if lines[0] != "batman-provhelper 1.5.14-wsl.5+abc1234.fwdef5678" {
		t.Fatalf("line 1 = %q", lines[0])
	}
	if seam.Enabled {
		if len(lines) != 2 || lines[1] != "BATMAN_PROV_TEST_BUILD_7f3a" {
			t.Fatalf("prov_test build: lines %q", lines)
		}
	} else if len(lines) != 1 {
		t.Fatalf("release build printed %d lines: %q", len(lines), lines)
	}
}

func TestVersionNoStamp(t *testing.T) {
	var b bytes.Buffer
	if rc := version(&b, filepath.Join(t.TempDir(), "missing")); rc != 0 || !strings.HasPrefix(b.String(), "batman-provhelper unknown\n") {
		t.Fatalf("rc %d out %q", rc, b.String())
	}
}
