// batman-provd — the unprivileged protocol half of the #254 provisioning service (docs/design/254-p2-impl.md): uid
// 471 in a ujail, no capabilities, read-only root. It registers one BLE advertisement and one GATT service with
// BlueZ, turns every connection into a Noise session and hands what the phone asked for to batman-provhelper (root)
// over /tmp/run/batman-prov/helper.sock. It holds no secret beyond this start's Noise static key.
//
//	batman-provd             daemon (procd S92)
//	batman-provd --version   "batman-provd <BATMAN_VERSION>"
package main

import (
	"fmt"
	"log/syslog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"batman-prov/provd"
)

const helperSock = "/tmp/run/batman-prov/helper.sock"

var logw *syslog.Writer

func logf(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	if logw != nil {
		logw.Info(msg)
		return
	}
	fmt.Fprintln(os.Stderr, "batman-provd: "+msg)
}

// stamp reads /etc/batman-build (parsed, never sourced; F-P59).
func stamp(path string) map[string]string {
	kv := map[string]string{}
	b, err := os.ReadFile(path)
	if err != nil {
		return kv
	}
	for l := range strings.Lines(string(b)) {
		k, v, ok := strings.Cut(strings.TrimSpace(l), "=")
		if ok {
			kv[k] = v
		}
	}
	return kv
}

func main() {
	st := stamp("/etc/batman-build")
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		v := st["BATMAN_VERSION"]
		if v == "" {
			v = "unknown"
		}
		fmt.Println("batman-provd " + v)
		os.Exit(0)
	}
	logw, _ = syslog.New(syslog.LOG_DAEMON|syslog.LOG_INFO, "batman-provd")
	if os.Geteuid() == 0 {
		fmt.Fprintln(os.Stderr, "batman-provd: refusing to run as root (procd starts it as provd in a ujail)")
		os.Exit(2)
	}
	te := testEnv(logf)
	cfg := provd.Config{HelperPath: helperSock, Log: logf, Model: st["BATMAN_MODEL"],
		Board: strings.TrimPrefix(st["BATMAN_BOARD"], "ekh-"), FW: st["BATMAN_VERSION"], Test: te}
	srv, err := provd.NewServer(cfg)
	if err != nil {
		logf("start: %v", err)
		os.Exit(1)
	}
	go srv.Run()
	var ble *bleSide
	if te.SockOnly {
		if err := serveSock(srv, logf); err != nil {
			logf("frame socket: %v", err)
			os.Exit(1)
		}
	} else {
		ble = newBLE(srv, te, logf)
		if code := ble.preflight(); code != 0 {
			time.Sleep(60 * time.Second) // unfixable: procd respawns forever, one line a minute (§4.4)
			os.Exit(code)
		}
		go ble.run()
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	// K10: withdraw the advertisement, disconnect everything (best effort <= 500 ms), exit
	done := make(chan struct{})
	go func() {
		if ble != nil {
			ble.stop()
		}
		srv.Stop()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
	}
	logf("provd: adv withdrawn reason=stop")
	os.Exit(0)
}
