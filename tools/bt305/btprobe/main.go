// btprobe (#305 harness tool, never in an image): is the Bluetooth controller on hci0 really answering over its UART?
//
// mgmt READ_INFO is the kernel's cached view (it stays "powered" while the UART is wedged); HCI
// Read_Local_Version_Information (0x1001) over a raw HCI socket is a real round trip through the UART.
// One line on stdout:
//
//	readinfo_powered=<0|1|err> settings=<comma list> hci_version=<statusN|noreply|sockerr:..> ms=<round trip>
//
// settings lists the mgmt current-settings bits the #305 tests judge: powered, bondable, le, secure-conn, privacy.
// Exit status 0 only when the HCI round trip returned status 0.
package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	afBluetooth = 31
	btprotoHCI  = 1
	chanRaw     = 0
	chanControl = 3
	devNone     = 0xffff
)

func hciSocket(dev, channel uint16) (int, error) {
	fd, err := syscall.Socket(afBluetooth, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, btprotoHCI)
	if err != nil {
		return -1, err
	}
	sa := [6]byte{}
	binary.LittleEndian.PutUint16(sa[0:], afBluetooth)
	binary.LittleEndian.PutUint16(sa[2:], dev)
	binary.LittleEndian.PutUint16(sa[4:], channel)
	if _, _, e := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa[0])), uintptr(len(sa))); e != 0 {
		syscall.Close(fd)
		return -1, e
	}
	return fd, nil
}

// readInfo returns the mgmt current-settings word of index 0.
func readInfo() (uint32, error) {
	fd, err := hciSocket(devNone, chanControl)
	if err != nil {
		return 0, err
	}
	defer syscall.Close(fd)
	if _, err := syscall.Write(fd, []byte{0x04, 0, 0, 0, 0, 0}); err != nil { // READ_INFO, index 0
		return 0, err
	}
	tv := syscall.Timeval{Sec: 2}
	syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	b := make([]byte, 512)
	for i := 0; i < 16; i++ {
		n, err := syscall.Read(fd, b)
		if err != nil {
			return 0, fmt.Errorf("noreply")
		}
		// mgmt Command Complete (0x0001) for READ_INFO (0x0004): hdr 6, opcode 2, status 1, then
		// bdaddr 6, version 1, manufacturer 2, supported 4, current 4
		if n >= 9+17 && binary.LittleEndian.Uint16(b[0:]) == 1 && binary.LittleEndian.Uint16(b[6:]) == 4 {
			if b[8] != 0 {
				return 0, fmt.Errorf("status%d", b[8])
			}
			return binary.LittleEndian.Uint32(b[9+13:]), nil
		}
	}
	return 0, fmt.Errorf("nomatch")
}

func settingsList(cur uint32) string {
	names := []struct {
		bit  uint
		name string
	}{{0, "powered"}, {4, "bondable"}, {9, "le"}, {11, "secure-conn"}, {13, "privacy"}}
	var out []string
	for _, n := range names {
		if cur&(1<<n.bit) != 0 {
			out = append(out, n.name)
		}
	}
	if len(out) == 0 {
		return "none"
	}
	return strings.Join(out, ",")
}

func main() {
	pw, set := "err", "unknown"
	if cur, err := readInfo(); err == nil {
		pw, set = fmt.Sprint(cur&1), settingsList(cur)
	} else {
		pw = "err(" + err.Error() + ")"
	}

	res, ms := "noreply", int64(0)
	fd, err := hciSocket(0, chanRaw)
	if err != nil {
		res = "sockerr:" + err.Error()
	} else {
		// struct hci_ufilter is 16 bytes after alignment: type_mask, event_mask[2], opcode (+pad)
		f := make([]byte, 16)
		binary.LittleEndian.PutUint32(f[0:], 1<<4)               // HCI_EVENT_PKT
		binary.LittleEndian.PutUint32(f[4:], 1<<0x0e|1<<0x0f)     // Command Complete, Command Status
		if _, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, uintptr(fd), 0 /*SOL_HCI*/, 2 /*HCI_FILTER*/, uintptr(unsafe.Pointer(&f[0])), 16, 0); e != 0 {
			res = "filtererr:" + e.Error()
		} else {
			t0 := time.Now()
			syscall.Write(fd, []byte{0x01, 0x01, 0x10, 0x00}) // H4 command 0x1001, no parameters
			tv := syscall.Timeval{Usec: 250000}
			syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
			b := make([]byte, 300)
			for time.Since(t0) < 5*time.Second {
				n, err := syscall.Read(fd, b)
				if err != nil || n < 7 {
					continue
				}
				if b[0] == 0x04 && b[1] == 0x0e && binary.LittleEndian.Uint16(b[4:]) == 0x1001 {
					res, ms = fmt.Sprintf("status%d", b[6]), time.Since(t0).Milliseconds()
					break
				}
			}
			if res == "noreply" {
				ms = time.Since(t0).Milliseconds()
			}
		}
		syscall.Close(fd)
	}
	fmt.Printf("readinfo_powered=%s settings=%s hci_version=%s ms=%d\n", pw, set, res, ms)
	if res != "status0" {
		os.Exit(1)
	}
}
