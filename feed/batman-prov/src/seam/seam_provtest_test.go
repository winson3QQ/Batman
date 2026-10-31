//go:build prov_test

package seam

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type rec struct{ lines []string }

func (r *rec) logf(f string, a ...any) { r.lines = append(r.lines, fmt.Sprintf(f, a...)) }

// refusedWith: exactly one log line, a refusal whose reason ENDS with want (the reason starts with a path that holds
// the test's own name, so a plain substring match could hit the path instead of the reason — r2 A-m1).
func (r *rec) refusedWith(want string) bool {
	return len(r.lines) == 1 && strings.HasPrefix(r.lines[0], "killpoint: refused (") && strings.HasSuffix(r.lines[0], want+")")
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
	if armed != Txn2 {
		t.Fatalf("armed = %v", armed)
	}
}

func TestEveryNameMapsToItsPoint(t *testing.T) {
	want := map[string]Point{"txn-1": Txn1, "txn-2": Txn2, "txn-3": Txn3, "txn-4": Txn4, "txn-5": Txn5,
		"claim-after-persist": ClaimAfterPersist, "claim-before-shadow": ClaimBeforeShadow}
	if len(names) != len(want) {
		t.Fatalf("%d names, want %d", len(names), len(want))
	}
	for n, p := range want {
		setup(t, n)
		var r rec
		Arm(r.logf)
		if armed != p || nameOf(p) != n {
			t.Fatalf("%s: armed %v, nameOf %q", n, armed, nameOf(p))
		}
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
	At(Txn2, r.logf)
	At(None, r.logf)
	if fired != "" {
		t.Fatalf("%s fired while txn-3 armed", fired)
	}
	At(Txn3, r.logf)
	if fired != "txn-3" {
		t.Fatalf("txn-3 did not fire (fired %q)", fired)
	}
}

func TestNothingArmedNothingFires(t *testing.T) {
	setup(t, "txn-1")
	os.Remove(filepath.Join(Dir, "killpoint"))
	var r rec
	Arm(r.logf)
	fired := false
	old := reboot
	reboot = func(string, func(string, ...any)) { fired = true }
	defer func() { reboot = old }()
	for p := None; p <= ClaimBeforeShadow; p++ {
		At(p, r.logf)
	}
	if fired || armed != None || len(r.lines) != 0 {
		t.Fatalf("fired %v armed %v log %q", fired, armed, r.lines)
	}
}

func TestRefusals(t *testing.T) {
	cases := []struct {
		name string
		mess func(dir, file string)
		why  string
	}{
		{"dir 0777", func(d, f string) { os.Chmod(d, 0o777) }, "has mode " + os.FileMode(0o777).String()},
		{"file 0644", func(d, f string) { os.Chmod(f, 0o644) }, "has mode " + os.FileMode(0o644).String()},
		{"file setgid", func(d, f string) { os.Chmod(f, 0o600|os.ModeSetgid) }, "has mode " + (0o600 | os.ModeSetgid).String()},
		{"dir sticky", func(d, f string) { os.Chmod(d, 0o700|os.ModeSticky) }, "has mode " + (os.ModeSticky | 0o700).String()},
		{"file symlink", func(d, f string) {
			tgt := filepath.Join(filepath.Dir(d), "elsewhere")
			os.WriteFile(tgt, []byte("txn-1"), 0o600)
			os.Remove(f)
			os.Symlink(tgt, f)
		}, "too many levels of symbolic links"}, // O_NOFOLLOW: ELOOP
		{"second hardlink", func(d, f string) { os.Link(f, filepath.Join(filepath.Dir(d), "extra")) }, "has more than one link"},
		{"dir is a symlink", func(d, f string) {
			real := d + ".real"
			os.Rename(d, real)
			os.Symlink(real, d)
		}, "is a symlink"},
		{"unknown point", func(d, f string) { os.WriteFile(f, []byte("txn-9"), 0o600) }, `unknown point "txn-9"`},
		{"file too long", func(d, f string) { os.WriteFile(f, []byte("txn-1"+strings.Repeat(" ", 70)), 0o600) }, "longer than 64 bytes"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := setup(t, "txn-1")
			c.mess(Dir, f)
			var r rec
			Arm(r.logf)
			if armed != None {
				t.Fatalf("armed %v despite %s", armed, c.name)
			}
			if !r.refusedWith(c.why) {
				t.Fatalf("log %q: want one refusal ending in %q", r.lines, c.why)
			}
		})
	}
}

func TestWrongOwnerRefused(t *testing.T) {
	setup(t, "txn-1")
	wantUID = os.Geteuid() + 1 // the files are ours, the rule wants someone else (= root for a non-root test run)
	var r rec
	Arm(r.logf)
	if armed != None || !r.refusedWith("is not owned by root") {
		t.Fatalf("armed %v, log %q", armed, r.lines)
	}
}

// An untrusted dir is not even unlinked in (root would act on a path someone else controls); a trusted dir loses
// the file whatever its content.
func TestUnlinkOnlyInTrustedDir(t *testing.T) {
	f := setup(t, "txn-1")
	os.Chmod(Dir, 0o777)
	var r rec
	Arm(r.logf)
	if _, err := os.Lstat(f); err != nil {
		t.Fatal("file removed from an untrusted dir")
	}
	f = setup(t, "txn-9")
	Arm(r.logf)
	if _, err := os.Lstat(f); !os.IsNotExist(err) {
		t.Fatal("refused file in a trusted dir not deleted")
	}
}

func TestMarker(t *testing.T) {
	if Marker != "BATMAN_PROV_TEST_BUILD_7f3a" || !Enabled {
		t.Fatalf("prov_test build: Marker %q Enabled %v", Marker, Enabled)
	}
}

// fire() writes the point to the kernel log before sysrq, and the fallback line too when sysrq did not take — the
// persistent evidence §16.1 (f) relies on (r2 A-m5 / B-m6). Run with fake paths; the fallback panics instead of
// rebooting.
func TestFireWritesKmsgThenSysrq(t *testing.T) {
	d := t.TempDir()
	km, sq := filepath.Join(d, "kmsg"), filepath.Join(d, "sysrq")
	os.WriteFile(km, nil, 0o600)
	os.WriteFile(sq, nil, 0o600)
	oldK, oldS, oldSettle, oldFB := kmsgPath, sysrqPath, settle, fallback
	defer func() { kmsgPath, sysrqPath, settle, fallback = oldK, oldS, oldSettle, oldFB }()
	kmsgPath, sysrqPath, settle = km, sq, time.Millisecond
	type stop struct{}
	fallback = func() error { panic(stop{}) }
	var r rec
	func() {
		defer func() {
			if x := recover(); x != nil {
				if _, ok := x.(stop); !ok {
					panic(x)
				}
			}
		}()
		fire("txn-4", r.logf)
	}()
	k, _ := os.ReadFile(km)
	s, _ := os.ReadFile(sq)
	want := "<4>batman-provhelper: killpoint txn-4: sysrq reboot\n<4>batman-provhelper: killpoint txn-4: fallback reboot -f\n"
	if string(k) != want {
		t.Fatalf("kmsg = %q, want %q", k, want)
	}
	if string(s) != "b" {
		t.Fatalf("sysrq got %q", s)
	}
	if len(r.lines) != 2 || r.lines[0] != "killpoint txn-4: sysrq reboot" || r.lines[1] != "killpoint txn-4: fallback reboot -f" {
		t.Fatalf("log %q", r.lines)
	}
	// sysrq not writable: the failure is logged at once (no waiting for the fallback line to tell)
	os.Remove(sq)
	os.WriteFile(km, nil, 0o600)
	sysrqPath = filepath.Join(d, "no", "sysrq")
	r = rec{}
	func() {
		defer func() { recover() }()
		fire("txn-1", r.logf)
	}()
	if len(r.lines) < 2 || !strings.HasPrefix(r.lines[1], "killpoint txn-1: sysrq write failed: ") {
		t.Fatalf("log %q: want the sysrq failure right after the first line", r.lines)
	}
}

// The prov_test unit tests run as root: nothing in them may reach a real reboot (code review r3 B-M1).
func TestMain(m *testing.M) {
	SafeForTests()
	os.Exit(m.Run())
}

// A point reached without ArmForTest panics at once (no sysrq, no reboot -f), and fire() called with the safe paths
// cannot reach the real trigger.
func TestSafeForTestsNeverReboots(t *testing.T) {
	armed = Txn1
	defer func() { armed = None }()
	func() {
		defer func() {
			x := recover()
			if s, ok := x.(string); !ok || !strings.Contains(s, "fired in a unit test that did not arm it") {
				t.Fatalf("At on an armed point without ArmForTest: recovered %v", x)
			}
		}()
		At(Txn1, func(string, ...any) {})
		t.Fatal("At returned")
	}()
	if sysrqPath == "/proc/sysrq-trigger" || kmsgPath == "/dev/kmsg" {
		t.Fatalf("real paths still set: %s %s", sysrqPath, kmsgPath)
	}
}

// One line, one name: anything after the name is refused, not trimmed away (code review r3 B-m3).
func TestKillpointFileOneNameOnly(t *testing.T) {
	for _, c := range []string{"txn-1 x", "txn-1\ntxn-2", "txn-1\tjunk", " txn-1 txn-1"} {
		setup(t, c)
		var r rec
		Arm(r.logf)
		if armed != None || len(r.lines) != 1 || !strings.HasPrefix(r.lines[0], "killpoint: refused (unknown point ") {
			t.Fatalf("%q: armed %v log %q", c, armed, r.lines)
		}
	}
}

// The refusal quotes the file's content: a newline in it cannot put a fake "killpoint …: armed" line in the log
// (security review F7).
func TestRefusalCannotForgeArmedLine(t *testing.T) {
	setup(t, "txn-9\nkillpoint txn-1: armed")
	var r rec
	Arm(r.logf)
	if armed != None || len(r.lines) != 1 || strings.Contains(r.lines[0], "\n") {
		t.Fatalf("armed %v log %q", armed, r.lines)
	}
}
