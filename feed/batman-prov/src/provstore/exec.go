package provstore

import (
	"bytes"
	"errors"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

// RCTimeout is what Exec returns when the command outlived its deadline (outcome unknown; callers treat it like any
// other failure — a wireless transaction keeps .txn).
const RCTimeout = 124

// Exec runs a command with a hard deadline (docs/design/254-wireless-txn.md §3 "no subprocess may keep the helper
// from serving", code review B MAJOR-1): the command runs in its own process group; at the deadline the whole group
// gets SIGTERM, 10 s later SIGKILL (nothing it starts may keep the pipe open). stdin may be nil.
func Exec(timeout time.Duration, env []string, stdin []byte, name string, args ...string) (int, string) {
	c := exec.Command(name, args...)
	c.Env = env
	if stdin != nil {
		c.Stdin = bytes.NewReader(stdin)
	}
	var out bytes.Buffer
	c.Stdout, c.Stderr = &out, &out
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	c.WaitDelay = 5 * time.Second // a daemonised grandchild holding the pipe must not hold Wait
	if err := c.Start(); err != nil {
		return 127, err.Error()
	}
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	var err error
	select {
	case err = <-done:
	case <-time.After(timeout):
		syscall.Kill(-c.Process.Pid, syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
			<-done
		}
		return RCTimeout, out.String() + "\n" + filepath.Base(name) + ": timed out after " + timeout.String()
	}
	if errors.Is(err, exec.ErrWaitDelay) && c.ProcessState != nil {
		// the command exited; only a daemonised grandchild still held the pipe (closed after WaitDelay)
		return c.ProcessState.ExitCode(), out.String()
	}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode(), out.String()
		}
		return 127, err.Error()
	}
	return 0, out.String()
}
