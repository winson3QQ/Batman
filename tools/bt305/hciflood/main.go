// hciflood (#305 harness tool, never in an image): a deterministic UART receive load that does not depend on the
// radio environment and does not touch bluetoothd. It sends HCI Read_Local_Name (0x0c14, read-only; ~255-byte
// Command Complete) back to back over a raw HCI socket on hci0 for N seconds, one command in flight at a time.
//
//	hciflood <seconds>
//
// One line on stdout: hciflood secs=N ok=N miss=N rx_event_bytes=N (R B/s). A "miss" is a command without a
// Command Complete within 3 s. Exit status 0 when the socket worked (the caller judges ok/miss).
package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"strconv"
	"syscall"
	"time"
	"unsafe"
)

func main() {
	secs := 60
	if len(os.Args) > 1 {
		v, err := strconv.Atoi(os.Args[1])
		if err != nil || v <= 0 {
			fmt.Println("usage: hciflood <seconds>")
			os.Exit(2)
		}
		secs = v
	}
	fd, err := syscall.Socket(31, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, 1)
	if err != nil {
		fmt.Println("hciflood sockerr:", err)
		os.Exit(1)
	}
	sa := [6]byte{}
	binary.LittleEndian.PutUint16(sa[0:], 31) // AF_BLUETOOTH, dev 0, HCI_CHANNEL_RAW
	if _, _, e := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa[0])), 6); e != 0 {
		fmt.Println("hciflood binderr:", e)
		os.Exit(1)
	}
	f := make([]byte, 16) // struct hci_ufilter (16 bytes after alignment)
	binary.LittleEndian.PutUint32(f[0:], 1<<4)
	binary.LittleEndian.PutUint32(f[4:], 1<<0x0e|1<<0x0f)
	if _, _, e := syscall.Syscall6(syscall.SYS_SETSOCKOPT, uintptr(fd), 0, 2, uintptr(unsafe.Pointer(&f[0])), 16, 0); e != 0 {
		fmt.Println("hciflood filtererr:", e)
		os.Exit(1)
	}
	tv := syscall.Timeval{Usec: 300000}
	syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	cmd := []byte{0x01, 0x14, 0x0c, 0x00}
	b := make([]byte, 400)
	end := time.Now().Add(time.Duration(secs) * time.Second)
	ok, miss, bytes := 0, 0, 0
	for time.Now().Before(end) {
		syscall.Write(fd, cmd)
		got := false
		t0 := time.Now()
		for time.Since(t0) < 3*time.Second {
			n, err := syscall.Read(fd, b)
			if err != nil || n < 7 {
				continue
			}
			if b[1] == 0x0e && binary.LittleEndian.Uint16(b[4:]) == 0x0c14 {
				ok++
				bytes += n
				got = true
				break
			}
		}
		if !got {
			miss++
		}
	}
	fmt.Printf("hciflood secs=%d ok=%d miss=%d rx_event_bytes=%d (%.0f B/s)\n", secs, ok, miss, bytes, float64(bytes)/float64(secs))
}
