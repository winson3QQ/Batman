package provstore

import (
	"strings"
	"testing"
	"time"
)

var testEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C"}

// code review B MAJOR-1: a subprocess that never returns must not keep the helper from serving.
func TestExecDeadline(t *testing.T) {
	cases := []struct{ name, sh string }{
		{"sleeps", "sleep 600"},
		{"grandchild holds the pipe", "(sleep 600 &) ; sleep 600"},
		{"ignores SIGTERM", "trap '' TERM; sleep 600"},
		{"daemonised grandchild holds the pipe after the parent exits", "setsid sleep 600 & exit 0"},
	}
	for _, c := range cases {
		t0 := time.Now()
		to := time.Second
		if strings.HasPrefix(c.name, "daemonised") {
			to = 15 * time.Second // the parent exits at once; WaitDelay (5 s) must end the wait, not the deadline
		}
		rc, out := Exec(to, testEnv, nil, "sh", "-c", c.sh)
		d := time.Since(t0)
		if d > 20*time.Second {
			t.Fatalf("%s: returned after %s", c.name, d)
		}
		if c.name == "daemonised grandchild holds the pipe after the parent exits" {
			if rc != 0 {
				t.Fatalf("%s: rc %d (%q)", c.name, rc, out)
			}
			continue
		}
		if rc != RCTimeout || !strings.Contains(out, "timed out") {
			t.Fatalf("%s: rc %d out %q (want %d)", c.name, rc, out, RCTimeout)
		}
	}
}

func TestExecPassthrough(t *testing.T) {
	rc, out := Exec(10*time.Second, testEnv, []byte("hello\n"), "sh", "-c", "read x; echo got:$x; echo err >&2; exit 3")
	if rc != 3 || !strings.Contains(out, "got:hello") || !strings.Contains(out, "err") {
		t.Fatalf("rc %d out %q", rc, out)
	}
	if rc, _ := Exec(10*time.Second, testEnv, nil, "/nonexistent/x"); rc != 127 {
		t.Fatalf("missing binary rc %d", rc)
	}
}
