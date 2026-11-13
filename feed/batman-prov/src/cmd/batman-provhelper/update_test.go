package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"batman-prov/provstore"
)

func write(t *testing.T, dir, name, body string, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestMemAvailable(t *testing.T) {
	d := t.TempDir()
	v, ok := memAvailable(write(t, d, "m", "MemTotal:  8000000 kB\nMemFree: 1 kB\nMemAvailable:    3906250 kB\n", 0o644))
	if !ok || v != 3906250<<10 {
		t.Fatalf("got %d %v", v, ok)
	}
	for _, bad := range []string{"MemFree: 1 kB\n", "MemAvailable: x kB\n", "MemAvailable: 5 MB\n", "MemAvailable: 99999999999999999 kB\n"} {
		if _, ok := memAvailable(write(t, d, "b", bad, 0o644)); ok {
			t.Fatalf("%q accepted", bad)
		}
	}
	if _, ok := memAvailable(filepath.Join(d, "none")); ok {
		t.Fatal("missing file accepted")
	}
}

func TestCmdlineSlot(t *testing.T) {
	d := t.TempDir()
	for in, want := range map[string]string{
		"console=tty1 batman_slot=B root=/dev/mmcblk0p4\n": "B",
		"batman_slot=A":                "A",
		"root=/dev/mmcblk0p2 rootwait": "",
		"batman_slot=C":                "",
		"batman_slot=AB":               "",
		"xbatman_slot=A":               "",
	} {
		if got := cmdlineSlot(write(t, d, "c", in, 0o644)); got != want {
			t.Fatalf("%q: %q want %q", in, got, want)
		}
	}
	if newRealUpdate(provstore.Paths{}, func() bool { return false }) != nil && cmdlineSlot("/proc/cmdline") == "" {
		t.Fatal("update source wired without batman_slot= on the command line")
	}
}

func TestIsMountPoint(t *testing.T) {
	d := t.TempDir()
	m := write(t, d, "mounts", "/dev/root / squashfs ro 0 0\n/dev/mapper/batdata_crypt /opt/batdata ext4 rw 0 0\n", 0o644)
	if !isMountPoint(m, "/opt/batdata") {
		t.Fatal("LUKS p6 not seen")
	}
	m2 := write(t, d, "m2", "/dev/root / squashfs ro 0 0\n/dev/mmcblk0p6 /opt/batdata/x ext4 rw 0 0\n/dev/x /opt ext4 rw 0 0\n", 0o644)
	if isMountPoint(m2, "/opt/batdata") {
		t.Fatal("a sub-mount or /opt counted as /opt/batdata")
	}
}

// slotStub: a batman-slot that prints its mount namespace on stdout and a message on stderr, rc from $1
func slotStub(t *testing.T) {
	t.Helper()
	d := t.TempDir()
	write(t, d, "batman-slot", `#!/bin/sh
ns=$(readlink /proc/self/ns/mnt)
echo "out ns=$ns"
echo "msg $1 ns=$ns" >&2
case "$1" in bootinfo|precheck-node) exit 0 ;; arm) exit 14 ;; esac
exit 0
`, 0o755)
	old := cleanEnv
	cleanEnv = []string{"PATH=" + d + ":/usr/bin:/bin", "LANG=C"}
	t.Setenv("PATH", d+":"+os.Getenv("PATH")) // exec.Command resolves the name with the process PATH
	t.Cleanup(func() { cleanEnv = old })
}

func TestSlotOutput(t *testing.T) {
	slotStub(t)
	u := &realUpdate{}
	if rc, out := u.Slot(5*time.Second, "bootinfo", "B"); rc != 0 || !strings.HasPrefix(out, "out ns=") {
		t.Fatalf("bootinfo: rc %d %q (want stdout only)", rc, out)
	}
	if rc, out := u.Slot(5*time.Second, "arm", "x", "y"); rc != 14 || !strings.Contains(out, "msg arm") || strings.Contains(out, "out ns=") {
		t.Fatalf("arm: rc %d %q (want the message)", rc, out)
	}
	if rc, out := u.SlotWrite(nil, "/x", strings.NewReader("")); rc != 0 || !strings.Contains(out, "msg write") {
		t.Fatalf("write: rc %d %q", rc, out)
	}
}

// TestSlotNamespace (root only; run under sudo / wsl -u root): write/arm/disarm/bootinfo/precheck-node in a private
// mount namespace, reboot / is-trial / commit in the init one (§3.7.3).
func TestSlotNamespace(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("root only: CLONE_NEWNS")
	}
	slotStub(t)
	own, _ := os.Readlink("/proc/self/ns/mnt")
	u := &realUpdate{}
	nsOf := func(out string) string {
		_, v, _ := strings.Cut(out, "ns=")
		return strings.TrimSpace(v)
	}
	ns := func(args ...string) string { _, out := u.Slot(5*time.Second, args...); return nsOf(out) }
	for _, v := range []string{"write", "arm", "disarm", "bootinfo", "precheck-node"} {
		if got := ns(v); got == own || got == "" {
			t.Fatalf("%s ran in namespace %q (own %q): want a private one", v, got, own)
		}
	}
	for _, v := range []string{"reboot", "is-trial", "commit", "apply"} {
		if got := ns(v); got != own {
			t.Fatalf("%s ran in namespace %q: want the init one %q", v, got, own)
		}
	}
	if _, out := u.SlotWrite(nil, "/x", strings.NewReader("")); nsOf(out) == own || nsOf(out) == "" {
		t.Fatalf("SlotWrite ran in namespace %q: want a private one", nsOf(out))
	}
}

// RootBytes: the slot's root partition from sysfs (512 B sectors): A = mmcblk0p2, B = mmcblk0p4 (batman-slot's layout)
func TestRootBytes(t *testing.T) {
	d := t.TempDir()
	os.MkdirAll(filepath.Join(d, "mmcblk0p2"), 0o755)
	os.MkdirAll(filepath.Join(d, "mmcblk0p4"), 0o755)
	write(t, filepath.Join(d, "mmcblk0p2"), "size", "1048576\n", 0o644)
	write(t, filepath.Join(d, "mmcblk0p4"), "size", "2097152\n", 0o644)
	if v, ok := rootBytesIn(d, "A"); !ok || v != 512<<20 {
		t.Fatalf("A: %d %v", v, ok)
	}
	if v, ok := rootBytesIn(d, "B"); !ok || v != 1<<30 {
		t.Fatalf("B: %d %v", v, ok)
	}
	for _, s := range []string{"C", ""} {
		if _, ok := rootBytesIn(d, s); ok {
			t.Fatalf("slot %q accepted", s)
		}
	}
	for _, bad := range []string{"", "x", "0", "-5", "9999999999999"} {
		write(t, filepath.Join(d, "mmcblk0p2"), "size", bad, 0o644)
		if _, ok := rootBytesIn(d, "A"); ok {
			t.Fatalf("size %q accepted", bad)
		}
	}
	os.RemoveAll(filepath.Join(d, "mmcblk0p4"))
	if _, ok := rootBytesIn(d, "B"); ok {
		t.Fatal("a missing partition accepted")
	}
}
