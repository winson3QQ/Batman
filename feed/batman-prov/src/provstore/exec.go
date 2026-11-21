package provstore

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// RCTimeout is what Exec returns when the command outlived its deadline (outcome unknown; callers treat it like any
// other failure — a wireless transaction keeps .txn).
const RCTimeout = 124

// Exec runs a command with a hard deadline (docs/design/254-wireless-txn.md §3 "no subprocess may keep the helper
// from serving", code review B MAJOR-1): the command runs in its own process group; at the deadline stopGroup ends the
// whole group (TERM; 10 s later KILL for members without a TERM handler, 30 s later for all; #254 L112, v16-group1
// §12-§13), so nothing it started runs on after the helper gave up. stdin may be nil.
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
		pg := c.Process.Pid
		killed := stopGroup(pg)
		select {
		case <-done: // bounded by WaitDelay (5 s) when only a pipe holder outside the group is left
		case <-time.After(10 * time.Second):
			// unkillable (uninterruptible sleep, e.g. a wedged driver): abandoned — its Wait goroutine stays, the
			// caller is free (254-wireless-txn §16.1). Its output is not read: the copier may still be writing.
			return RCTimeout, filepath.Base(name) + ": timed out after " + timeout.String() + " and could not be killed (abandoned)"
		}
		return RCTimeout, out.String() + "\n" + killedNote(pg, killed) + filepath.Base(name) + ": timed out after " + timeout.String()
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
		pg := c.Process.Pid
		killed := stopGroup(pg) // #254 L112, v16-group1 §12-§13 (see Exec)
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			return rc, "", filepath.Base(name) + ": " + why + " and could not be killed (abandoned)"
		}
		return rc, so.String(), se.String() + "\n" + killedNote(pg, killed) + filepath.Base(name) + ": " + why
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

// BulkDir is provd's upload tmpfs (254-p3-impl §3.8.2): mounted by root in batman-provd's init before the jail starts
// (never stacked, never through a symlink, mode 0700 provd), the jail's only rw mount. It is outside the root-only
// run dir on purpose — provd (uid 471) writes the upload there; the helper opens it O_NOFOLLOW, checks it is that
// tmpfs (fstatfs + its own mount point) and takes the file over (unlink, chown, lease) before it reads a byte.
const BulkDir = "/tmp/run/batman-provd-bulk"

// stopGroup ends the process group pgid at a deadline or a cancel (#254 L112 / docs/design/254-v16-group1.md §12, §13):
// SIGTERM to the group, then its members are polled every 100 ms (a /proc scan; a zombie does not count) until none is
// left. 10 s after the TERM every member without a TERM handler gets SIGKILL (it ignores TERM, or it is blocked with the
// default action pending); 30 s after it, every member that is still there. Kills go to the pids just seen, never to
// -pgid, so a group id reused after the group emptied is never hit. Returns how many members were killed.
func stopGroup(pgid int) int {
	syscall.Kill(-pgid, syscall.SIGTERM)
	t0, killed, soft := time.Now(), 0, false
	for {
		m := groupMembers(pgid)
		if len(m) == 0 {
			return killed
		}
		el := time.Since(t0)
		if el >= 30*time.Second {
			for p := range m {
				if syscall.Kill(p, syscall.SIGKILL) == nil {
					killed++
				}
			}
			return killed
		}
		if el >= 10*time.Second && !soft {
			soft = true
			for p, handles := range m {
				if !handles && syscall.Kill(p, syscall.SIGKILL) == nil {
					killed++
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// groupMembers: the live (not zombie) pids whose process group is pgid -> whether each has a SIGTERM handler.
func groupMembers(pgid int) map[int]bool {
	m := map[int]bool{}
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/stat")
		if err != nil {
			continue
		}
		s := string(b)
		i := strings.LastIndexByte(s, ')') // comm may contain spaces and parentheses
		if i < 0 {
			continue
		}
		f := strings.Fields(s[i+1:]) // state ppid pgrp ...
		if len(f) < 3 || f[0] == "Z" {
			continue
		}
		if g, err := strconv.Atoi(f[2]); err != nil || g != pgid {
			continue
		}
		m[pid] = catchesTERM(pid)
	}
	return m
}

// catchesTERM: SIGTERM (15) is in the process's caught-signal mask (/proc/<pid>/status SigCgt, hex, bit 14).
func catchesTERM(pid int) bool {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return false
	}
	for _, l := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(l, "SigCgt:"); ok {
			x, err := strconv.ParseUint(strings.TrimSpace(v), 16, 64)
			return err == nil && x&(1<<(uint(syscall.SIGTERM)-1)) != 0
		}
	}
	return false
}

// killedNote: the line that goes BEFORE the "timed out" / "canceled" line (callers log the last line; §13)
func killedNote(pgid, killed int) string {
	s := ""
	if killed > 0 {
		s = "group member(s) outlived TERM: killed (" + strconv.Itoa(killed) + ")\n"
	}
	if n := len(groupMembers(pgid)); n > 0 {
		s += "a group member could not be killed (" + strconv.Itoa(n) + ")\n"
	}
	return s
}
