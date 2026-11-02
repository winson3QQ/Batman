package main

// proxy (254-h23 §4.6, §4.8.2): after the privilege drop, relay one SEQPACKET socket to stdin / stdout — one line of
// hex = one packet each way — so a host-side tool can reach a uid-provd socket (the prov_test frame socket
// /tmp/run/batman-provd-test/gatt.sock) through `ssh node provclient node sock-as 471 -- proxy <path>`.
// The socket closing ends the proxy (exit 0); stdin EOF only shuts the write side, answers still come back.

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"strings"
)

func cmdProxy(path string) {
	c, err := net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: path, Net: "unixpacket"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "CONN-ERR %v\n", err)
		os.Exit(3)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 1<<16)
		w := bufio.NewWriter(os.Stdout)
		for {
			n, err := c.Read(buf)
			if err != nil || n == 0 {
				w.Flush()
				return
			}
			w.WriteString(hex.EncodeToString(buf[:n]) + "\n")
			w.Flush()
		}
	}()
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<17), 1<<17)
	go func() {
		for in.Scan() {
			b, err := hex.DecodeString(strings.TrimSpace(in.Text()))
			if err != nil {
				die("proxy: stdin line is not hex")
			}
			if _, err := c.Write(b); err != nil {
				return
			}
		}
		c.CloseWrite() // the peer sees EOF; its last packets still come back until it closes
	}()
	<-done
	c.Close()
}
