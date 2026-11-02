// Package health writes $RUNDIR/batman-prov.health every 15 s — THE health contract (docs/design/254-stage1-impl.md
// §3): one line
//
//	boot_id=<this boot> ts=<uptime> bluetoothd=0|1 hci0_powered=0|1 adv_registered_once=0|1 privacy=0|1 sc=0|1 sc_file=0|1 bondable=0|1
//
// privacy / sc / bondable / powered come from the kernel's mgmt READ_INFO current settings (unprivileged opcode,
// D26); sc_file=1 only when /var/lib/bluetooth/batman-sc names this boot, the live bluetoothd pid, index 0, mode 2,
// status 0 (D27). adv_registered_once=1 once the kernel has reported an advertising instance on hci0 during this
// helper's lifetime (mgmt Read Advertising Features num_instances >= 1, latched; 254-p2-impl §1.3: measured here, never
// reported by provd). health.get (provd) gets the same line computed on demand, plus num_instances. Readers treat a missing / stale
// (> 60 s) / malformed line as all zero (fail-closed). It also writes p6 ble-ok when the §6.4 conditions hold.
package health

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

// mgmt current-settings bits (linux include/net/bluetooth/mgmt.h)
const (
	SetPowered    = 1 << 0
	SetBondable   = 1 << 4
	SetLE         = 1 << 9
	SetSecureConn = 1 << 11
	SetPrivacy    = 1 << 13
)

// Info is what READ_INFO tells about hci0.
type Info struct{ Current uint32 }

// ParseReadInfo decodes a mgmt Command Complete event for READ_INFO (opcode 0x0004).
func ParseReadInfo(ev []byte) (Info, error) {
	// event header: opcode(2) index(2) len(2); Command Complete: cmd opcode(2) status(1) then params
	if len(ev) < 6+3+6+1+2+4+4 {
		return Info{}, errors.New("health: short mgmt event")
	}
	if binary.LittleEndian.Uint16(ev[0:2]) != 0x0001 || binary.LittleEndian.Uint16(ev[6:8]) != 0x0004 {
		return Info{}, errors.New("health: not a READ_INFO completion")
	}
	if ev[8] != 0 {
		return Info{}, fmt.Errorf("health: READ_INFO status %d", ev[8])
	}
	p := ev[9:]
	// bdaddr(6) version(1) manufacturer(2) supported(4) current(4)
	return Info{Current: binary.LittleEndian.Uint32(p[6+1+2+4 : 6+1+2+4+4])}, nil
}

// ParseAdvFeatures decodes a mgmt Command Complete event for Read Advertising Features (opcode 0x003D) and returns
// num_instances (mgmt.h: supported_flags(4) max_adv_data_len(1) max_scan_rsp_len(1) max_instances(1) num_instances(1)).
func ParseAdvFeatures(ev []byte) (int, error) {
	if len(ev) < 6+3+8 {
		return 0, errors.New("health: short mgmt event")
	}
	if binary.LittleEndian.Uint16(ev[0:2]) != 0x0001 || binary.LittleEndian.Uint16(ev[6:8]) != 0x003D {
		return 0, errors.New("health: not a Read Advertising Features completion")
	}
	if ev[8] != 0 {
		return 0, fmt.Errorf("health: Read Advertising Features status %d", ev[8])
	}
	return int(ev[9+7]), nil
}

// ReadInfo queries hci0 over the mgmt control channel.
func ReadInfo() (Info, error) {
	var inf Info
	err := mgmtQuery(0x0004, func(ev []byte) bool {
		i, err := ParseReadInfo(ev)
		inf = i
		return err == nil
	})
	return inf, err
}

// ReadAdvInstances: hci0's advertising instances as the kernel counts them (added = counted, paused or not; F-P28).
func ReadAdvInstances() (int, error) {
	n := 0
	err := mgmtQuery(0x003D, func(ev []byte) bool {
		v, err := ParseAdvFeatures(ev)
		n = v
		return err == nil
	})
	return n, err
}

// mgmtQuery sends one parameterless command for index 0 and waits (2 s) for the completion done() accepts.
func mgmtQuery(opcode uint16, done func([]byte) bool) error {
	const afBluetooth, btprotoHCI, hciChannelControl = 31, 1, 3
	fd, err := syscall.Socket(afBluetooth, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, btprotoHCI)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	// struct sockaddr_hci { sa_family_t family; unsigned short dev; unsigned short channel; }
	sa := [6]byte{}
	binary.LittleEndian.PutUint16(sa[0:], afBluetooth)
	binary.LittleEndian.PutUint16(sa[2:], 0xffff) // HCI_DEV_NONE
	binary.LittleEndian.PutUint16(sa[4:], hciChannelControl)
	if _, _, e := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa[0])), uintptr(len(sa))); e != 0 {
		return e
	}
	cmd := []byte{byte(opcode), byte(opcode >> 8), 0x00, 0x00, 0x00, 0x00} // opcode, index 0, len 0
	if _, err := syscall.Write(fd, cmd); err != nil {
		return err
	}
	tv := syscall.Timeval{Sec: 2}
	syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	buf := make([]byte, 512)
	for i := 0; i < 8; i++ {
		n, err := syscall.Read(fd, buf)
		if err != nil {
			return err
		}
		if done(buf[:n]) {
			return nil
		}
	}
	return fmt.Errorf("health: no completion for mgmt opcode 0x%04x", opcode)
}

// Env lets tests replace the node.
type Env struct {
	BootID     func() string // kernel boot_id
	Uptime     func() int
	ReadInfo   func() (Info, error)
	ReadAdv    func() (int, error) // the kernel's advertising instances on hci0; nil = 0
	BTDPid     func() int          // live bluetoothd pid, 0 if none
	ScFile     string              // /var/lib/bluetooth/batman-sc
	Out        string              // $RUNDIR/batman-prov.health
	Committed  func() bool
	ConfigOK   func() bool // both boot FATs' [pi4] have miniuart-bt + core_freq_min=500 and vcgencmd >= 500
	BleOK      string      // /opt/batdata/state/ble-ok
	poweredFor int
	advOnce    atomic.Bool // this helper lifetime saw num_instances >= 1
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// scFileOK checks batman-sc: boot_id=<this boot> pid=<live bluetoothd> index=0 mode=2 status=0 (D27).
func scFileOK(path, boot string, pid int) bool {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() || pid == 0 {
		return false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	kv := map[string]string{}
	for _, f := range strings.Fields(string(b)) {
		k, v, _ := strings.Cut(f, "=")
		kv[k] = v
	}
	return kv["boot_id"] == boot && kv["pid"] == strconv.Itoa(pid) && kv["index"] == "0" && kv["mode"] == "2" && kv["status"] == "0"
}

// compute builds the health line now (the two mgmt queries run in parallel: worst case ~2 s) and latches advOnce.
// Tick (file + ble-ok) and Get (health.get, lock-free) share it; it writes nothing.
func (e *Env) compute() (line string, inst int, powered bool, pid int) {
	boot := e.BootID()
	pid = e.BTDPid()
	var inf Info
	var ierr, aerr error
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); inf, ierr = e.ReadInfo() }()
	if e.ReadAdv != nil {
		inst, aerr = e.ReadAdv()
	}
	wg.Wait()
	cur := uint32(0)
	if ierr == nil {
		cur = inf.Current
	}
	if aerr != nil {
		inst = 0
	}
	if inst >= 1 {
		e.advOnce.Store(true)
	}
	powered = cur&SetPowered != 0
	line = fmt.Sprintf("boot_id=%s ts=%d bluetoothd=%d hci0_powered=%d adv_registered_once=%d privacy=%d sc=%d sc_file=%d bondable=%d\n",
		boot, e.Uptime(), b2i(pid != 0), b2i(powered), b2i(e.advOnce.Load()), b2i(cur&SetPrivacy != 0),
		b2i(cur&SetSecureConn != 0), b2i(scFileOK(e.ScFile, boot, pid)), b2i(cur&SetBondable != 0))
	return line, inst, powered, pid
}

// Get is health.get: the line computed now plus the kernel's num_instances (provd's foreign-instance check); no file is
// written.
func (e *Env) Get() string {
	line, inst, _, _ := e.compute()
	return strings.TrimSuffix(line, "\n") + fmt.Sprintf(" num_instances=%d\n", inst)
}

// Tick computes and writes one health line (atomic rename) and the ble-ok marker; returns the line.
func (e *Env) Tick(interval int) string {
	line, _, powered, pid := e.compute()
	boot := e.BootID()
	tmp := e.Out + ".tmp"
	if err := os.WriteFile(tmp, []byte(line), 0o600); err == nil {
		os.Rename(tmp, e.Out)
	}
	// ble-ok (§6.4): committed AND the boot config is right AND Powered for >= 10 minutes in a row
	if powered && pid != 0 {
		e.poweredFor += interval
	} else {
		e.poweredFor = 0
	}
	if e.BleOK != "" && e.poweredFor >= 600 && e.Committed() && e.ConfigOK() {
		if b, err := os.ReadFile(e.BleOK); err != nil || strings.TrimSpace(string(b)) != boot {
			os.MkdirAll(filepath.Dir(e.BleOK), 0o755)
			os.WriteFile(e.BleOK+".tmp", []byte(boot+"\n"), 0o600)
			os.Rename(e.BleOK+".tmp", e.BleOK)
		}
	}
	return line
}

// Run ticks every 15 s until stop is closed.
func (e *Env) Run(stop <-chan struct{}) {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	e.Tick(15)
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			e.Tick(15)
		}
	}
}
