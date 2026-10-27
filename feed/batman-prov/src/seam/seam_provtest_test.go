//go:build prov_test

package seam

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type rec struct{ lines []string }

func (r *rec) logf(f string, a ...any) { r.lines = append(r.lines, fmt.Sprintf(f, a...)) }
func (r *rec) has(s string) bool {
	for _, l := range r.lines {
		if strings.Contains(l, s) {
			return true
		}
	}
	return false
}

// setup makes a valid killpoint dir + file owned by the test's own uid (wantUID follows it).
func setup(t *testing.T, content string) string {
	t.Helper()
	wantUID = os.Geteuid()
	d := filepath.Join(t.TempDir(), "kp")
	if err := os.Mkdir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	os.Chmod(d, 0o700)
	Dir = d
	f := filepath.Join(d, "killpoint")
	if err := os.WriteFile(f, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Chmod(f, 0o600)
	return f
}

func TestArmedLineIsTheGateLiteral(t *testing.T) {
	f := setup(t, "txn-2\n")
	var r rec
	Arm(r.logf)
	if len(r.lines) != 1 || r.lines[0] != "killpoint txn-2: armed" {
		t.Fatalf("log = %q, want exactly [killpoint txn-2: armed]", r.lines)
	}
	if _, err := os.Lstat(f); !os.IsNotExist(err) {
		t.Fatal("killpoint file not deleted after Arm")
	}
	if armed != "txn-2" {
		t.Fatalf("armed = %q", armed)
	}
}

func TestAtFiresOnlyTheArmedPoint(t *testing.T) {
	setup(t, "txn-3")
	var r rec
	Arm(r.logf)
	fired := ""
	old := reboot
	reboot = func(name string, _ func(string, ...any)) { fired = name }
	defer func() { reboot = old }()
	At("txn-2", r.logf)
	if fired != "" {
		t.Fatalf("txn-2 fired while txn-3 armed")
	}
	At("txn-3", r.logf)
	if fired != "txn-3" {
		t.Fatalf("txn-3 did not fire (fired %q)", fired)
	}
}

func TestNoFileNothingArmedNoLog(t *testing.T) {
	f := setup(t, "txn-1")
	os.Remove(f)
	var r rec
	Arm(r.logf)
	if armed != "" || len(r.lines) != 0 {
		t.Fatalf("armed %q, log %q", armed, r.lines)
	}
}

func TestRefusals(t *testing.T) {
	cases := []struct {
		name string
		mess func(dir, file string)
		why  string
	}{
		{"dir 0777", func(d, f string) { os.Chmod(d, 0o777) }, "has mode"},
		{"file 0644", func(d, f string) { os.Chmod(f, 0o644) }, "has mode"},
		{"file symlink", func(d, f string) {
			tgt := filepath.Join(filepath.Dir(d), "elsewhere")
			os.WriteFile(tgt, []byte("txn-1"), 0o600)
			os.Remove(f)
			os.Symlink(tgt, f)
		}, "symlink"},
		{"second hardlink", func(d, f string) { os.Link(f, filepath.Join(filepath.Dir(d), "extra")) }, "more than one link"},
		{"dir is a symlink", func(d, f string) {
			real := d + ".real"
			os.Rename(d, real)
			os.Symlink(real, d)
		}, "symlink"},
		{"unknown point", func(d, f string) { os.WriteFile(f, []byte("txn-9"), 0o600) }, "unknown point"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := setup(t, "txn-1")
			c.mess(Dir, f)
			var r rec
			Arm(r.logf)
			if armed != "" {
				t.Fatalf("armed %q despite %s", armed, c.name)
			}
			if !r.has("killpoint: refused (") || !r.has(c.why) {
				t.Fatalf("log %q: want a refusal mentioning %q", r.lines, c.why)
			}
		})
	}
}

func TestWrongOwnerRefused(t *testing.T) {
	setup(t, "txn-1")
	wantUID = os.Geteuid() + 1 // the files are ours, the rule wants someone else (= root for a non-root test run)
	var r rec
	Arm(r.logf)
	if armed != "" || !r.has("not owned by root") {
		t.Fatalf("armed %q, log %q", armed, r.lines)
	}
}

func TestMarker(t *testing.T) {
	if Marker != "BATMAN_PROV_TEST_BUILD_7f3a" || !Enabled {
		t.Fatalf("prov_test build: Marker %q Enabled %v", Marker, Enabled)
	}
}
