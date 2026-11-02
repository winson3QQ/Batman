package health

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readInfoEvent(current uint32, status byte) []byte {
	ev := []byte{0x01, 0x00, 0x00, 0x00, 0, 0, 0x04, 0x00, status}
	p := make([]byte, 6+1+2+4+4+3+249+11)
	binary.LittleEndian.PutUint32(p[6+1+2:], 0xffff)
	binary.LittleEndian.PutUint32(p[6+1+2+4:], current)
	ev = append(ev, p...)
	binary.LittleEndian.PutUint16(ev[4:6], uint16(len(ev)-6))
	return ev
}

func TestParseReadInfo(t *testing.T) {
	inf, err := ParseReadInfo(readInfoEvent(SetPowered|SetPrivacy|SetSecureConn|SetLE, 0))
	if err != nil || inf.Current&SetPrivacy == 0 || inf.Current&SetBondable != 0 {
		t.Fatalf("%v %x", err, inf.Current)
	}
	if _, err := ParseReadInfo(readInfoEvent(0, 1)); err == nil {
		t.Fatal("failed status accepted")
	}
	if _, err := ParseReadInfo([]byte{1, 0}); err == nil {
		t.Fatal("short event accepted")
	}
}

func env(t *testing.T, cur uint32, pid int) *Env {
	d := t.TempDir()
	return &Env{
		BootID: func() string { return "bootA" }, Uptime: func() int { return 77 },
		ReadInfo: func() (Info, error) { return Info{Current: cur}, nil }, BTDPid: func() int { return pid },
		ScFile: filepath.Join(d, "batman-sc"), Out: filepath.Join(d, "health"),
		Committed: func() bool { return true }, ConfigOK: func() bool { return true }, BleOK: filepath.Join(d, "ble-ok"),
	}
}

func TestLineAndScFile(t *testing.T) {
	e := env(t, SetPowered|SetPrivacy|SetSecureConn, 321)
	os.WriteFile(e.ScFile, []byte("boot_id=bootA pid=321 index=0 mode=2 status=0\n"), 0o600)
	l := e.Tick(15)
	want := "boot_id=bootA ts=77 bluetoothd=1 hci0_powered=1 adv_registered_once=0 privacy=1 sc=1 sc_file=1 bondable=0\n"
	if l != want {
		t.Fatalf("got  %q\nwant %q", l, want)
	}
	if b, _ := os.ReadFile(e.Out); string(b) != want {
		t.Fatal("file content")
	}
	// batman-sc from another bluetoothd pid / another boot -> sc_file=0
	os.WriteFile(e.ScFile, []byte("boot_id=bootA pid=999 index=0 mode=2 status=0\n"), 0o600)
	if !strings.Contains(e.Tick(15), "sc_file=0") {
		t.Fatal("stale pid accepted")
	}
	os.WriteFile(e.ScFile, []byte("boot_id=old pid=321 index=0 mode=2 status=0\n"), 0o600)
	if !strings.Contains(e.Tick(15), "sc_file=0") {
		t.Fatal("stale boot accepted")
	}
}

func TestBleOkNeedsTenMinutesPowered(t *testing.T) {
	e := env(t, SetPowered, 5)
	for i := 0; i < 39; i++ { // 39 * 15 s = 585 s
		e.Tick(15)
	}
	if _, err := os.Stat(e.BleOK); err == nil {
		t.Fatal("ble-ok before 10 minutes")
	}
	e.Tick(15)
	if b, err := os.ReadFile(e.BleOK); err != nil || strings.TrimSpace(string(b)) != "bootA" {
		t.Fatal("ble-ok not written after 10 minutes")
	}
	// a power drop resets the run; a node whose config is wrong never gets it
	e2 := env(t, SetPowered, 5)
	e2.ConfigOK = func() bool { return false }
	for i := 0; i < 60; i++ {
		e2.Tick(15)
	}
	if _, err := os.Stat(e2.BleOK); err == nil {
		t.Fatal("ble-ok without the boot config (02 p3 case)")
	}
}

func advEvent(num byte, status byte) []byte {
	ev := []byte{0x01, 0x00, 0x00, 0x00, 0, 0, 0x3D, 0x00, status}
	p := []byte{0, 0, 0, 0, 31, 31, 5, num}
	for i := byte(0); i < num; i++ {
		p = append(p, i+1)
	}
	ev = append(ev, p...)
	binary.LittleEndian.PutUint16(ev[4:6], uint16(len(ev)-6))
	return ev
}

func TestParseAdvFeatures(t *testing.T) {
	if n, err := ParseAdvFeatures(advEvent(2, 0)); err != nil || n != 2 {
		t.Fatalf("%d %v", n, err)
	}
	if _, err := ParseAdvFeatures(advEvent(1, 3)); err == nil {
		t.Fatal("failed status accepted")
	}
	if _, err := ParseAdvFeatures(readInfoEvent(0, 0)); err == nil {
		t.Fatal("a READ_INFO completion accepted as Read Advertising Features")
	}
}

// adv_registered_once is measured from the kernel (254-p2-impl §1.3): 0 until an instance is seen, then latched for the
// helper's lifetime (provd unregistering while a phone is connected must not clear it). Mutant: write the current
// num_instances instead of the latch -> the third Tick reads 0 -> FAIL.
func TestAdvRegisteredOnceLatch(t *testing.T) {
	e := env(t, SetPowered|SetPrivacy|SetSecureConn, 321)
	inst := 0
	e.ReadAdv = func() (int, error) { return inst, nil }
	if !strings.Contains(e.Tick(15), "adv_registered_once=0") {
		t.Fatal("no instance yet but latched")
	}
	inst = 1
	if !strings.Contains(e.Tick(15), "adv_registered_once=1") {
		t.Fatal("instance seen, not latched")
	}
	inst = 0
	if !strings.Contains(e.Tick(15), "adv_registered_once=1") {
		t.Fatal("latch cleared when the instance went away")
	}
}

// a provd that never registers (or a failing query) leaves it 0 forever (L2 negative control)
func TestAdvRegisteredOnceNeverRegistered(t *testing.T) {
	e := env(t, SetPowered, 321)
	e.ReadAdv = func() (int, error) { return 3, os.ErrDeadlineExceeded }
	for i := 0; i < 3; i++ {
		if !strings.Contains(e.Tick(15), "adv_registered_once=0") {
			t.Fatal("a failed query latched")
		}
	}
}

// health.get: the line now + num_instances, nothing written (provd reads the kernel count from it, F-P28 / F-P60)
func TestGet(t *testing.T) {
	e := env(t, SetPowered|SetPrivacy|SetSecureConn, 321)
	os.WriteFile(e.ScFile, []byte("boot_id=bootA pid=321 index=0 mode=2 status=0\n"), 0o600)
	e.ReadAdv = func() (int, error) { return 2, nil }
	want := "boot_id=bootA ts=77 bluetoothd=1 hci0_powered=1 adv_registered_once=1 privacy=1 sc=1 sc_file=1 bondable=0 num_instances=2\n"
	if got := e.Get(); got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
	if _, err := os.Stat(e.Out); err == nil {
		t.Fatal("health.get wrote the health file")
	}
}
