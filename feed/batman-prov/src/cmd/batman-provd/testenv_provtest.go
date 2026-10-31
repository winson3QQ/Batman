//go:build prov_test

package main

// prov_test only (a -wbox image, h23 §4.8.3): the switches batman-provd-test.init read as root from
// /tmp/run/batman-prov-test/provd.env and passed as environment variables, and the frame socket
// /tmp/run/batman-provd-test/gatt.sock (h23 §4.8.2) that stands in for BLE under SOCK_ONLY=1.

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"batman-prov/provd"
)

const sockDir = "/tmp/run/batman-provd-test"

func testEnv(logf func(string, ...any)) provd.TestEnv {
	var te provd.TestEnv
	var set []string
	atoi := func(k string) int { n, _ := strconv.Atoi(os.Getenv(k)); return n }
	if os.Getenv("SOCK_ONLY") == "1" {
		te.SockOnly = true
		set = append(set, "SOCK_ONLY=1")
	}
	if n := atoi("FAST_FAKE_DELAY_MS"); n > 0 {
		te.FastFakeDelayMS = n
		set = append(set, fmt.Sprintf("FAST_FAKE_DELAY_MS=%d", n))
	}
	if os.Getenv("NO_BRUTE_LIMIT") == "1" {
		te.NoBruteLimit = true
		set = append(set, "NO_BRUTE_LIMIT=1")
	}
	if os.Getenv("GATT_ENCRYPT_CTRL") == "1" {
		te.GattEncryptCtrl = true
		set = append(set, "GATT_ENCRYPT_CTRL=1")
	}
	if n := atoi("ADV_LEN_TEST"); n > 0 {
		te.AdvLenTest = n
		set = append(set, fmt.Sprintf("ADV_LEN_TEST=%d", n))
	}
	if len(set) > 0 {
		logf("provd: test env %s", strings.Join(set, " "))
	}
	return te
}

// checkSockDir: the dir the test init made for us — owned by our uid, 0700, a real directory (O_NOFOLLOW + fstat);
// anything else is a refusal (h23 §4.8.2, F-P42).
func checkSockDir(dir string) error {
	fd, err := syscall.Open(dir, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("%s: %v", dir, err)
	}
	defer syscall.Close(fd)
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return err
	}
	if int(st.Uid) != os.Getuid() || st.Mode&0o777 != 0o700 {
		return fmt.Errorf("%s: owner %d mode %o (want %d 0700) — refusing to bind", dir, st.Uid, st.Mode&0o777, os.Getuid())
	}
	return nil
}

type sockConn struct{ c *net.UnixConn }

func (s *sockConn) ReadFrame() ([]byte, error) {
	b := make([]byte, provd.MaxFrame+1)
	n, err := s.c.Read(b)
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, errors.New("empty packet")
	}
	return b[:n], nil
}
func (s *sockConn) WriteFrame(f []byte) error { _, err := s.c.Write(f); return err }
func (s *sockConn) FrameLimit() int           { return provd.OutFrame }
func (s *sockConn) Close()                    { s.c.Close() }
func (s *sockConn) Kind() string              { return "sock" }

func serveSock(srv *provd.Server, logf func(string, ...any)) error {
	if err := checkSockDir(sockDir); err != nil {
		return err
	}
	p := filepath.Join(sockDir, "gatt.sock")
	os.Remove(p)
	ln, err := net.ListenUnix("unixpacket", &net.UnixAddr{Name: p, Net: "unixpacket"})
	if err != nil {
		return err
	}
	os.Chmod(p, 0o600)
	logf("provd: frame socket %s (SOCK_ONLY)", p)
	go func() {
		for {
			c, err := ln.AcceptUnix()
			if err != nil {
				logf("frame socket: %v", err)
				return
			}
			srv.Accept(&sockConn{c})
		}
	}()
	return nil
}
