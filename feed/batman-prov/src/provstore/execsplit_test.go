package provstore

import (
	"io"
	"strings"
	"testing"
	"time"
)

var shEnv = []string{"PATH=/usr/bin:/bin"}

// 254-p3-impl §3.7.5-6: stdout and stderr apart, a streamed stdin, an abort.
func TestExecSplit(t *testing.T) {
	rc, so, se := ExecSplit(Opts{Timeout: 5 * time.Second, Env: shEnv}, "sh", "-c", "echo out; echo err >&2; exit 3")
	if rc != 3 || so != "out\n" || se != "err\n" {
		t.Fatalf("rc %d stdout %q stderr %q", rc, so, se)
	}
	// stdin streamed: 8 MiB through a pipe, never held whole by the caller
	pr, pw := io.Pipe()
	go func() {
		buf := make([]byte, 1<<20)
		for i := 0; i < 8; i++ {
			pw.Write(buf)
		}
		pw.Close()
	}()
	rc, so, _ = ExecSplit(Opts{Timeout: 10 * time.Second, Env: shEnv, Stdin: pr}, "sh", "-c", "wc -c")
	if rc != 0 || strings.TrimSpace(so) != "8388608" {
		t.Fatalf("streamed stdin: rc %d %q", rc, so)
	}
	// cancel: TERM to the group, rc 125, quickly
	cancel := make(chan struct{})
	go func() { time.Sleep(200 * time.Millisecond); close(cancel) }()
	t0 := time.Now()
	rc, _, se = ExecSplit(Opts{Timeout: 30 * time.Second, Env: shEnv, Cancel: cancel}, "sh", "-c", "sleep 20")
	if rc != RCCanceled || time.Since(t0) > 5*time.Second || !strings.Contains(se, "canceled") {
		t.Fatalf("cancel: rc %d after %s (%q)", rc, time.Since(t0), se)
	}
	// timeout
	rc, _, _ = ExecSplit(Opts{Timeout: 200 * time.Millisecond, Env: shEnv}, "sh", "-c", "sleep 20")
	if rc != RCTimeout {
		t.Fatalf("timeout: rc %d", rc)
	}
	// a missing command
	if rc, _, _ = ExecSplit(Opts{Timeout: time.Second, Env: shEnv}, "/nonexistent/x"); rc != 127 {
		t.Fatalf("missing: rc %d", rc)
	}
}
