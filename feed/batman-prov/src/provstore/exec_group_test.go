package provstore

import (
	"os"
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
