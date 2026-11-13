package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// a real child of this test plays provd: its exe is the sleep binary, its PPid this process; the stub ubus reports
// the "batman-provd instance" pid
func provdChild(t *testing.T, instance string) int {
	t.Helper()
	sl, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("no sleep")
	}
	c := exec.Command(sl, "30")
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Process.Kill(); c.Wait() })
	exe, _ := os.Readlink("/proc/" + strconv.Itoa(c.Process.Pid) + "/exe")
	oldE := provdExe
	provdExe = exe
	d := t.TempDir()
	write(t, d, "ubus", "#!/bin/sh\ncat "+d+"/svc.json\n", 0o755)
	write(t, d, "svc.json", instance, 0o644)
	old := cleanEnv
	cleanEnv = []string{"PATH=" + d + ":/usr/bin:/bin", "LANG=C"}
	t.Setenv("PATH", d+":"+os.Getenv("PATH"))
	t.Cleanup(func() { cleanEnv, provdExe = old, oldE })
	return c.Process.Pid
}

func svc(pids ...int) string {
	s := `{"batman-provd": {"instances": {`
	for i, p := range pids {
		if i > 0 {
			s += ","
		}
		s += `"instance` + strconv.Itoa(i+1) + `": {"running": true, "pid": ` + strconv.Itoa(p) + `}`
	}
	return s + "}}}"
}

func TestIsProvd(t *testing.T) {
	me := os.Getpid()
	pid := provdChild(t, svc(me))
	if !isProvd(pid) {
		t.Fatal("the child of the instance with the provd exe not recognised")
	}
	if isProvd(me) {
		t.Fatal("a process with another exe recognised")
	}
	other := exec.Command("cat") // a child of the same parent (PPid matches) with another exe
	pr, pw, _ := os.Pipe()
	other.Stdin = pr
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pw.Close(); other.Wait() })
	if isProvd(other.Process.Pid) {
		t.Fatal("a child of the instance with another exe recognised")
	}
	write(t, filepath.Dir(lookUbus(t)), "svc.json", svc(me+1), 0o644)
	if isProvd(pid) {
		t.Fatal("PPid != the instance pid recognised")
	}
	write(t, filepath.Dir(lookUbus(t)), "svc.json", svc(me, me), 0o644) // two instances (even the same pid)
	if isProvd(pid) {
		t.Fatal("two instances: recognised anyway")
	}
	write(t, filepath.Dir(lookUbus(t)), "svc.json", `{"batman-provd": {"instances": {"instance1": {"running": false, "pid": `+strconv.Itoa(me)+`}}}}`, 0o644)
	if isProvd(pid) {
		t.Fatal("an instance that is not running recognised")
	}
	write(t, filepath.Dir(lookUbus(t)), "svc.json", "garbage", 0o644)
	if isProvd(pid) {
		t.Fatal("unreadable ubus answer recognised")
	}
}

func lookUbus(t *testing.T) string {
	p, err := exec.LookPath("ubus")
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestStableWriter(t *testing.T) {
	pid := provdChild(t, svc(os.Getpid()))
	old := stableAfter
	stableAfter = 200 * time.Millisecond
	t.Cleanup(func() { stableAfter = old })
	path := filepath.Join(t.TempDir(), "provd-stable")
	w := &stableWriter{path: path}
	closed := make(chan struct{})
	close(closed)
	w.onPeer(pid, provdUID, closed) // gone before 60 s
	w.onPeer(pid, provdUID+1, make(chan struct{}))
	time.Sleep(400 * time.Millisecond)
	if _, err := os.Stat(path); err == nil {
		t.Fatal("written for a connection that ended early or a wrong uid")
	}
	w.onPeer(pid, provdUID, make(chan struct{}))
	time.Sleep(50 * time.Millisecond)
	if _, err := os.Stat(path); err == nil {
		t.Fatal("written before the connection was open for stableAfter")
	}
	time.Sleep(350 * time.Millisecond)
	b, err := os.ReadFile(path)
	if err != nil || string(b) != bootID()+"\n" {
		t.Fatalf("provd-stable = %q %v, want this boot_id", b, err)
	}
	if !w.done.Load() {
		t.Fatal("not marked done")
	}
}

// a connection of something that is not provd (uid 471 but another exe) never writes it
func TestStableWriterNotProvd(t *testing.T) {
	provdChild(t, svc(os.Getpid()))
	old := stableAfter
	stableAfter = 100 * time.Millisecond
	t.Cleanup(func() { stableAfter = old })
	path := filepath.Join(t.TempDir(), "provd-stable")
	w := &stableWriter{path: path}
	w.onPeer(os.Getpid(), provdUID, make(chan struct{}))
	time.Sleep(300 * time.Millisecond)
	if _, err := os.Stat(path); err == nil {
		t.Fatal("written for a process that is not provd")
	}
}
