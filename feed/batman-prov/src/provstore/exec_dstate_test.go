//go:build prov_test

package provstore

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// docs/design/254-wireless-txn.md §16.1 / §17 (review 3 A MAJOR-1): a command in uninterruptible sleep (a wedged
// driver) survives SIGKILL; Exec must give up on it and return. Reproduced with a suspended device-mapper device: a
// direct read blocks in D state until the device is resumed. Root only (the prov_test root run of CI and DV); as root
// a missing dmsetup / losetup FAILS (the test must not report clean without having tested).
func TestExecAbandonsDState(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root (CI and DV run -tags prov_test as root)")
	}
	for _, c := range []string{"dmsetup", "losetup", "dd"} {
		if _, err := exec.LookPath(c); err != nil {
			t.Fatalf("%s missing: the D-state test cannot run", c)
		}
	}
	// a dd that does O_DIRECT reads of a block device: GNU dd. Ubuntu 26.04's dd is uutils coreutils 0.10.0, which
	// fails such a read at once ("dd: IO error: Invalid input", CI diagnostic run 43563599271) and keeps GNU's as gnudd.
	// PROVTEST_DD names another dd (the negative control of the precondition: PROVTEST_DD=dd on 26.04 must FAIL it).
	dd := "dd"
	if _, err := exec.LookPath("gnudd"); err == nil {
		dd = "gnudd"
	}
	if v := os.Getenv("PROVTEST_DD"); v != "" {
		dd = v
	}
	img := filepath.Join(t.TempDir(), "dm.img")
	if err := os.WriteFile(img, make([]byte, 8<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("losetup", "-f", "--show", img).Output()
	if err != nil {
		t.Fatalf("losetup: %v", err)
	}
	loop := strings.TrimSpace(string(out))
	name := "batmanexec" + strconv.Itoa(os.Getpid())
	t.Cleanup(func() {
		exec.Command("dmsetup", "resume", name).Run()
		time.Sleep(time.Second)
		exec.Command("dmsetup", "remove", name).Run()
		exec.Command("losetup", "-d", loop).Run()
	})
	if b, err := exec.Command("dmsetup", "create", name, "--table", "0 16384 linear "+loop+" 0").CombinedOutput(); err != nil {
		t.Fatalf("dmsetup create: %v %s", err, b)
	}
	if b, err := exec.Command("dmsetup", "suspend", name).CombinedOutput(); err != nil {
		t.Fatalf("dmsetup suspend: %v %s", err, b)
	}
	t0 := time.Now()
	done := make(chan string, 1)
	go func() {
		rc, out := Exec(2*time.Second, testEnv, nil, dd, "if=/dev/mapper/"+name, "of=/dev/null", "bs=4096", "count=1", "iflag=direct")
		done <- strconv.Itoa(rc) + " " + out
	}()
	// the precondition, watched while Exec runs: the dd must reach D state (block on the suspended device). A dd that
	// errors out at once never does, and the test must say that, not judge Exec on a command that never hung.
	sawD := make(chan bool, 1)
	stop := make(chan struct{})
	go func() {
		for {
			if dState(dd, name) == "D" {
				sawD <- true
				return
			}
			select {
			case <-stop:
				sawD <- false
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	select {
	case r := <-done:
		close(stop)
		if !<-sawD {
			t.Fatalf("precondition: %s never blocked in D state on the suspended device (it ended after %s: %q) — this dd cannot do an O_DIRECT read of a block device, so Exec was not tested", dd, time.Since(t0).Round(time.Millisecond), r)
		}
		if !strings.HasPrefix(r, strconv.Itoa(RCTimeout)+" ") || !strings.Contains(r, "abandoned") {
			t.Fatalf("Exec returned %q (want rc %d, abandoned)", r, RCTimeout)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("Exec still waiting for an unkillable command after 60 s")
	}
	// the precondition held: the command really was unkillable (still in D state when Exec returned)
	if st := dState(dd, name); st != "D" {
		t.Fatalf("precondition: dd state %q when Exec returned after %s (want D — else this test proves nothing)", st, time.Since(t0).Round(time.Second))
	}
}

// dState: the state letter of the <dd> (by argv[0]) reading /dev/mapper/<name>, "" if none.
func dState(dd, name string) string {
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		if _, err := strconv.Atoi(e.Name()); err != nil {
			continue
		}
		cl, _ := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline"))
		argv0, _, _ := strings.Cut(string(cl), "\x00")
		if !strings.Contains(string(cl), "/dev/mapper/"+name) || filepath.Base(argv0) != dd {
			continue
		}
		st, _ := os.ReadFile(filepath.Join("/proc", e.Name(), "stat"))
		if i := strings.LastIndexByte(string(st), ')'); i > 0 && len(st) > i+2 {
			return string(st[i+2])
		}
	}
	return ""
}
