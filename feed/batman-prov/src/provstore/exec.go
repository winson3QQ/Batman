package provstore

import (
	"bytes"
	"errors"
	"io"
	"os"
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
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				// unkillable (uninterruptible sleep, e.g. a wedged driver): abandoned — its Wait goroutine stays, the
				// caller is free (254-wireless-txn §16.1). Its output is not read: the copier may still be writing.
				return RCTimeout, filepath.Base(name) + ": timed out after " + timeout.String() + " and could not be killed (abandoned)"
			}
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

// RCCanceled is what ExecSplit returns when its Cancel channel closed first (the caller aborted it, e.g. owner/remove of
// the update's owner; 254-p3-impl §3.7.5-9).
const RCCanceled = 125

// Opts are ExecSplit's options (254-p3-impl §3.7.5-6): a streamed stdin (the rootfs is never read into memory), stdout
// and stderr apart (batman-slot bootinfo: only stdout is parsed), an abort channel, and an optional private mount
// namespace (NewNS: what the command mounts dies with it, even after SIGKILL; Go sets / rprivate, go1.26
// syscall/exec_linux.go:473-478 — root only, ignored otherwise so unit tests run unprivileged).
type Opts struct {
	Timeout time.Duration
	Env     []string
	Stdin   io.Reader
	Cancel  <-chan struct{}
	NewNS   bool
}

// ExecSplit is Exec with Opts; the same process-group / TERM -> 10 s -> KILL rule.
func ExecSplit(o Opts, name string, args ...string) (rc int, stdout, stderr string) {
	c := exec.Command(name, args...)
	c.Env = o.Env
	if o.Stdin != nil {
		c.Stdin = o.Stdin
	}
	var so, se bytes.Buffer
	c.Stdout, c.Stderr = &so, &se
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if o.NewNS && os.Geteuid() == 0 {
		c.SysProcAttr.Unshareflags = syscall.CLONE_NEWNS
	}
	c.WaitDelay = 5 * time.Second
	if err := c.Start(); err != nil {
		return 127, "", err.Error()
	}
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	stop := func(rc int, why string) (int, string, string) {
		syscall.Kill(-c.Process.Pid, syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				return rc, "", filepath.Base(name) + ": " + why + " and could not be killed (abandoned)"
			}
		}
		return rc, so.String(), se.String() + "\n" + filepath.Base(name) + ": " + why
	}
	var err error
	select {
	case err = <-done:
	case <-time.After(o.Timeout):
		return stop(RCTimeout, "timed out after "+o.Timeout.String())
	case <-o.Cancel: // a nil channel never fires
		return stop(RCCanceled, "canceled")
	}
	if errors.Is(err, exec.ErrWaitDelay) && c.ProcessState != nil {
		return c.ProcessState.ExitCode(), so.String(), se.String()
	}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode(), so.String(), se.String()
		}
		return 127, "", err.Error()
	}
	return 0, so.String(), se.String()
}
