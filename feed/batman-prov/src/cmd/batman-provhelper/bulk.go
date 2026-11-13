package main

// The real node.BulkSys (254-p3-impl §3.8): the phone AP, the HTTP firewall check (every 4 s, cached), provd's tmpfs.

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	apSection   = "default_radio0" // the phone AP (radio0 = the Pi's own Wi-Fi)
	lanBridge   = "br-ahwlan"
	fwFresh     = 10 * time.Second
	tmpfsMagic  = 0x01021994
	nftBridge   = "bridge batman_http"
	nftInet     = "inet batman_http_in"
	sysClassNet = "/sys/class/net"
)

// nftRules: the comment of every rule batman-http.nft loads, by table — the check wants each of them listed
var nftRules = map[string][]string{
	nftBridge: {"batman-http: clear", "batman-http: mark"},
	nftInet:   {"batman-http: iif", "batman-http: mark-drop"},
}

type wifiStatus map[string]struct {
	Up         bool `json:"up"`
	Interfaces []struct {
		Section string `json:"section"`
		Ifname  string `json:"ifname"`
	} `json:"interfaces"`
}

type realBulk struct {
	netDir string // /sys/class/net (tests point it elsewhere)

	mu   sync.Mutex
	addr string
	at   time.Time
}

// apIface: the phone AP's ifname when radio0 is up and default_radio0 has one ("" = off)
func apIface() (string, error) {
	rc, out := run(nil, "ubus", "call", "network.wireless", "status")
	if rc != 0 {
		return "", fmt.Errorf("ubus network.wireless status rc %d", rc)
	}
	var ws wifiStatus
	if err := json.Unmarshal([]byte(out), &ws); err != nil {
		return "", err
	}
	r, ok := ws["radio0"]
	if !ok || !r.Up {
		return "", nil
	}
	for _, i := range r.Interfaces {
		if i.Section == apSection && i.Ifname != "" {
			return i.Ifname, nil
		}
	}
	return "", nil
}

func (b *realBulk) AP() (bool, string, string) {
	i, err := apIface()
	if err != nil || i == "" {
		return false, "", ""
	}
	return true, uciGet("wireless." + apSection + ".ssid"), uciRaw("wireless." + apSection + ".key")
}

// HTTPAddr: the last check's address, if that check is at most 10 s old
func (b *realBulk) HTTPAddr() (string, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.addr == "" || time.Since(b.at) > fwFresh {
		return "", false
	}
	return b.addr, true
}

// check (every 4 s): both nft tables with all their rules, the phy* premise, br-ahwlan's IPv4 (§3.8.1). Any failure
// clears the cache: no http.2, provd does not listen (fail-closed).
func (b *realBulk) check() {
	addr, err := b.checkOnce()
	b.mu.Lock()
	defer b.mu.Unlock()
	if err != nil {
		if b.addr != "" {
			logf("http: not serving: %v", err)
		}
		b.addr = ""
		return
	}
	b.addr, b.at = addr, time.Now()
}

func (b *realBulk) checkOnce() (string, error) {
	for _, tbl := range []string{nftBridge, nftInet} {
		// a missing table prints no listing: the hook and every rule comment must be in it
		_, out := run(nil, "nft", append([]string{"list", "table"}, strings.Fields(tbl)...)...)
		if !strings.Contains(out, "hook input") {
			return "", fmt.Errorf("nft table %s missing or without its input hook", tbl)
		}
		for _, c := range nftRules[tbl] {
			if !strings.Contains(out, `comment "`+c+`"`) {
				return "", fmt.Errorf("nft table %s: rule %q missing", tbl, c)
			}
		}
	}
	ap, err := apIface()
	if err != nil {
		return "", err
	}
	// every bridge port named phy* must be the phone AP, and the AP must be a port of br-ahwlan (D-13)
	ports, err := filepath.Glob(filepath.Join(b.netDir, "*", "brif", "*"))
	if err != nil {
		return "", err
	}
	apOnLan := false
	for _, p := range ports {
		port, br := filepath.Base(p), filepath.Base(filepath.Dir(filepath.Dir(p)))
		if strings.HasPrefix(port, "phy") && port != ap {
			return "", fmt.Errorf("bridge port %s on %s is not the phone AP", port, br)
		}
		if port == ap && ap != "" {
			if br != lanBridge {
				return "", fmt.Errorf("the phone AP %s is on %s, not %s", ap, br, lanBridge)
			}
			apOnLan = true
		}
	}
	if ap != "" && !apOnLan {
		return "", fmt.Errorf("the phone AP %s is not a port of %s", ap, lanBridge)
	}
	return lanIPv4()
}

var lanIPv4 = func() (string, error) {
	i, err := net.InterfaceByName(lanBridge)
	if err != nil {
		return "", err
	}
	as, err := i.Addrs()
	if err != nil {
		return "", err
	}
	for _, a := range as {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil {
			return n.IP.To4().String(), nil
		}
	}
	return "", errors.New(lanBridge + " has no IPv4 address")
}

// BulkTmpfs: provd's upload dir is a tmpfs mounted there itself (D-15): a plain directory would let a compromised
// provd fill the shared tmpfs under it.
func (b *realBulk) BulkTmpfs() error { return bulkTmpfsAt(bulkDir) }

// BulkCapacity: the upload tmpfs's size (only when it is the tmpfs BulkTmpfs accepts)
func (b *realBulk) BulkCapacity() (uint64, bool) { return bulkCapacityAt(bulkDir) }

func bulkCapacityAt(dir string) (uint64, bool) {
	if bulkTmpfsAt(dir) != nil {
		return 0, false
	}
	var fs syscall.Statfs_t
	if syscall.Statfs(dir, &fs) != nil {
		return 0, false
	}
	return fs.Blocks * uint64(fs.Bsize), true
}

func bulkTmpfsAt(dir string) error {
	fd, err := syscall.Open(dir, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("%s: %v", dir, err)
	}
	defer syscall.Close(fd)
	var fs syscall.Statfs_t
	if err := syscall.Fstatfs(fd, &fs); err != nil || fs.Type != tmpfsMagic {
		return fmt.Errorf("%s is not a tmpfs", dir)
	}
	var st, pst syscall.Stat_t
	if syscall.Fstat(fd, &st) != nil || syscall.Stat(filepath.Dir(dir), &pst) != nil || st.Dev == pst.Dev {
		return fmt.Errorf("%s is not a mount point of its own", dir)
	}
	return nil
}
