package provstore

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// review 3 A m5: at the deadline the WHOLE process group goes, not only the direct child (a grandchild — e.g. the
// `wifi reload` of a halow-setkey — must not run on after the helper gave up)
func TestExecKillsTheGroup(t *testing.T) {
	pf := filepath.Join(t.TempDir(), "gc.pid")
	rc, _ := Exec(time.Second, testEnv, nil, "sh", "-c", "sleep 600 & echo $! > "+pf+"; wait")
	if rc != RCTimeout {
		t.Fatalf("rc %d", rc)
	}
	b, err := os.ReadFile(pf)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	for i := 0; i < 50; i++ {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	syscall.Kill(pid, syscall.SIGKILL)
	t.Fatalf("the grandchild %d survived the deadline", pid)
}

// review 3 B m9: an uppercase token is refused (config-save --txn accepts [0-9a-f] only)
func TestTxnTokenLowercaseOnly(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, ".txn"), []byte(strings.Repeat("AB", 16)+" 1 2 network/join\nprev - - -\n"), 0o600)
	if TxnToken(Paths{Dir: d}) != "" {
		t.Fatal("uppercase token accepted")
	}
}

// #254 L112 A4 m3 / v16-group1 §12-§13: a member that IGNORES SIGTERM is killed (10 s after the TERM) even when the
// leader died on TERM at once; the note goes before the "timed out" line (callers log the last line). Fails on main
// (the KILL branch ran only while the leader was alive).
func TestExecKillsTheGroupThatTrapsTERM(t *testing.T) {
	pf := filepath.Join(t.TempDir(), "gc.pid")
	rc, out := Exec(time.Second, testEnv, nil, "sh", "-c", "sh -c 'trap \"\" TERM; echo $$ > "+pf+"; while :; do sleep 1; done' >/dev/null 2>&1 & wait")
	if rc != RCTimeout {
		t.Fatalf("rc %d", rc)
	}
	if !alive(t, pf, 2*time.Second) {
		if !strings.Contains(out, "outlived TERM: killed") || !strings.HasSuffix(strings.TrimSpace(out), "timed out after 1s") {
			t.Fatalf("output %q: want the kill note before a last 'timed out' line", out)
		}
		return
	}
	t.Fatal("the TERM-ignoring member survived the deadline")
}

// §13 (review v4 A-M1): a member WITH a TERM handler finishes its cleanup (here 2 s) before anything is killed, even
// though the leader died on TERM at once. Fails on an "immediate KILL when the leader exits" mutant.
func TestExecGivesMembersTheTERMGrace(t *testing.T) {
	d := t.TempDir()
	mk := filepath.Join(d, "cleaned")
	rc, out := Exec(time.Second, testEnv, nil, "sh", "-c", "sh -c 'trap \"sleep 2; touch "+mk+"; exit 0\" TERM; while :; do sleep 1; done' >/dev/null 2>&1 & wait")
	if rc != RCTimeout {
		t.Fatalf("rc %d", rc)
	}
	if _, err := os.Stat(mk); err != nil {
		t.Fatalf("the member's TERM cleanup did not finish before Exec returned (%q)", out)
	}
	if strings.Contains(out, "outlived TERM") {
		t.Fatalf("a member that finished its cleanup was reported killed: %q", out)
	}
}

// §13: a member with a TERM handler that needs 15 s is not killed at 10 s (the 30 s bound applies to it)
func TestExecHandlerGetsMoreThan10s(t *testing.T) {
	d := t.TempDir()
	mk := filepath.Join(d, "cleaned")
	t0 := time.Now()
	rc, _ := Exec(time.Second, testEnv, nil, "sh", "-c", "sh -c 'trap \"sleep 15; touch "+mk+"; exit 0\" TERM; while :; do sleep 1; done' >/dev/null 2>&1 & wait")
	if rc != RCTimeout {
		t.Fatalf("rc %d", rc)
	}
	if _, err := os.Stat(mk); err != nil {
		t.Fatalf("killed before its 15 s cleanup ended (returned after %s)", time.Since(t0).Round(time.Second))
	}
}

// review v4 B m1: a group whose members all die on TERM returns at once (not after 10 s)
func TestExecReturnsPromptlyWhenTheGroupDies(t *testing.T) {
	t0 := time.Now()
	rc, _ := Exec(time.Second, testEnv, nil, "sh", "-c", "sleep 600 & sleep 600 & wait")
	if rc != RCTimeout || time.Since(t0) > 3*time.Second {
		t.Fatalf("rc %d after %s (want %d within 3 s)", rc, time.Since(t0), RCTimeout)
	}
}

// §13 (review v5 B m3): a zombie member does not count — a leader that catches TERM, lives 12 s and never reaps its
// dead child: at 10 s nothing is killed (without the zombie rule the zombie would be "killed" and reported)
func TestExecZombieIsNotAMember(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not installed (needed for a leader that does not reap)")
	}
	py := "import signal,subprocess,time\nsignal.signal(signal.SIGTERM, lambda *a: None)\nsubprocess.Popen(['sleep','600'])\ntime.sleep(14)\n"
	rc, out := Exec(time.Second, testEnv, nil, "python3", "-c", py)
	if rc != RCTimeout {
		t.Fatalf("rc %d (%q)", rc, out)
	}
	if strings.Contains(out, "outlived TERM") {
		t.Fatalf("the dead, unreaped child was counted and killed: %q", out)
	}
}

// ExecSplit (OTA batman-slot) has the same stop: timeout and cancel twins of the TERM-ignoring case
func TestExecSplitKillsTERMIgnoringMember(t *testing.T) {
	for _, c := range []string{"timeout", "cancel"} {
		t.Run(c, func(t *testing.T) {
			pf := filepath.Join(t.TempDir(), "gc.pid")
			o := Opts{Timeout: time.Second, Env: testEnv}
			want := RCTimeout
			if c == "cancel" {
				ch := make(chan struct{})
				o.Timeout, o.Cancel, want = 60*time.Second, ch, RCCanceled
				go func() { time.Sleep(time.Second); close(ch) }()
			}
			rc, _, se := ExecSplit(o, "sh", "-c", "sh -c 'trap \"\" TERM; echo $$ > "+pf+"; while :; do sleep 1; done' >/dev/null 2>&1 & wait")
			if rc != want {
				t.Fatalf("rc %d (%q)", rc, se)
			}
			if alive(t, pf, 2*time.Second) {
				t.Fatal("the TERM-ignoring member survived")
			}
			if !strings.Contains(se, "outlived TERM: killed") {
				t.Fatalf("stderr %q: no kill note", se)
			}
		})
	}
}

// alive: the pid in file pf still runs after d (the caller fails; a survivor is killed so it does not leak)
func alive(t *testing.T, pf string, d time.Duration) bool {
	t.Helper()
	b, err := os.ReadFile(pf)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	for i := 0; i < int(d/(100*time.Millisecond)); i++ {
		if syscall.Kill(pid, 0) != nil {
			return false
		}
		time.Sleep(100 * time.Millisecond)
	}
	syscall.Kill(pid, syscall.SIGKILL)
	return true
}
