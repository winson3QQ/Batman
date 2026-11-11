package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// the nft listing as `nft list table` prints a loaded batman-http.nft (comments are kept verbatim)
const nftBridgeOut = `table bridge batman_http {
	chain input {
		type filter hook input priority -10; policy accept;
		iifname != "phy*" meta mark set meta mark & 0xfeffffff comment "batman-http: clear"
		iifname "phy*" meta mark set meta mark | 0x01000000 comment "batman-http: mark"
	}
}
`
const nftInetOut = `table inet batman_http_in {
	chain input {
		type filter hook input priority filter - 10; policy accept;
		tcp dport 8095 iifname != "br-ahwlan" counter packets 0 bytes 0 drop comment "batman-http: iif"
		tcp dport 8095 meta mark & 0x01000000 == 0x00000000 counter packets 0 bytes 0 drop comment "batman-http: mark-drop"
	}
}
`

// the 04 capture's shape (network.wireless status), with the phone AP up on phy0-ap0
const wifiUp = `{"radio0": {"up": true, "interfaces": [{"section": "default_radio0", "ifname": "phy0-ap0"}]},
 "radio1": {"up": true, "interfaces": [{"section": "default_radio1", "ifname": "wlh0"}]}}`
const wifiOff = `{"radio0": {"up": true, "interfaces": []}, "radio1": {"up": true, "interfaces": []}}`

type bulkEnv struct {
	t   *testing.T
	bin string
	net string
}

// bulkStubs: nft / ubus / uci stubs whose output comes from files the test rewrites, and a fake /sys/class/net
func bulkStubs(t *testing.T) *bulkEnv {
	t.Helper()
	d := t.TempDir()
	e := &bulkEnv{t: t, bin: filepath.Join(d, "bin"), net: filepath.Join(d, "net")}
	os.MkdirAll(e.bin, 0o755)
	write(t, e.bin, "nft", `#!/bin/sh
f="`+e.bin+`/nft.$3.$4"
[ -f "$f" ] || { echo "Error: No such file or directory" >&2; exit 1; }
cat "$f"
`, 0o755)
	write(t, e.bin, "ubus", "#!/bin/sh\ncat "+e.bin+"/wifi.json\n", 0o755)
	write(t, e.bin, "uci", `#!/bin/sh
case "$3" in wireless.default_radio0.ssid) echo "batman-ap" ;; wireless.default_radio0.key) echo " pass with blanks " ;; esac
`, 0o755)
	e.set("nft.bridge.batman_http", nftBridgeOut)
	e.set("nft.inet.batman_http_in", nftInetOut)
	e.set("wifi.json", wifiUp)
	e.port("br-ahwlan", "bat0")
	e.port("br-ahwlan", "eth0")
	e.port("br-ahwlan", "phy0-ap0")
	e.port("br-ots", "veth182d7db")
	old := cleanEnv
	cleanEnv = []string{"PATH=" + e.bin + ":/usr/bin:/bin", "LANG=C"}
	t.Setenv("PATH", e.bin+":"+os.Getenv("PATH"))
	oldIP := lanIPv4
	lanIPv4 = func() (string, error) { return "10.41.80.13", nil }
	t.Cleanup(func() { cleanEnv, lanIPv4 = old, oldIP })
	return e
}

func (e *bulkEnv) set(name, body string) { write(e.t, e.bin, name, body, 0o644) }
func (e *bulkEnv) rm(name string)        { os.Remove(filepath.Join(e.bin, name)) }
func (e *bulkEnv) port(br, p string) {
	os.MkdirAll(filepath.Join(e.net, br, "brif", p), 0o755)
}
func (e *bulkEnv) unport(br, p string) { os.RemoveAll(filepath.Join(e.net, br, "brif", p)) }

func TestHTTPCheck(t *testing.T) {
	e := bulkStubs(t)
	b := &realBulk{netDir: e.net}
	ok := func(want bool, why string) {
		t.Helper()
		b.check()
		addr, got := b.HTTPAddr()
		if got != want || (want && addr != "10.41.80.13") {
			t.Fatalf("%s: HTTPAddr = %q %v, want %v", why, addr, got, want)
		}
	}
	ok(true, "everything in place")
	e.rm("nft.bridge.batman_http")
	ok(false, "bridge table missing (firewall stop)")
	e.set("nft.bridge.batman_http", nftBridgeOut)
	ok(true, "back")
	e.set("nft.inet.batman_http_in", strings.Replace(nftInetOut, `comment "batman-http: mark-drop"`, "", 1))
	ok(false, "the mark-drop rule missing")
	e.set("nft.inet.batman_http_in", strings.Replace(nftInetOut, "hook input", "hook forward", 1))
	ok(false, "no input hook")
	e.set("nft.inet.batman_http_in", nftInetOut)
	e.port("br-ots", "phy1-sta0")
	ok(false, "a phy* port that is not the phone AP")
	e.unport("br-ots", "phy1-sta0")
	e.unport("br-ahwlan", "phy0-ap0")
	e.port("br-ots", "phy0-ap0")
	ok(false, "the phone AP on another bridge")
	e.unport("br-ots", "phy0-ap0")
	ok(false, "the phone AP up but not a port of br-ahwlan")
	e.set("wifi.json", wifiOff)
	ok(true, "AP off, no phy* port (the rules alone; bulk.open refuses with 16)")
	e.set("wifi.json", "not json")
	ok(false, "ubus answer unreadable")
	e.set("wifi.json", wifiUp)
	e.port("br-ahwlan", "phy0-ap0")
	lanIPv4 = func() (string, error) { return "", os.ErrNotExist }
	ok(false, "br-ahwlan without IPv4")
}

func TestHTTPAddrStale(t *testing.T) {
	b := &realBulk{addr: "10.41.80.13", at: time.Now().Add(-11 * time.Second)}
	if _, ok := b.HTTPAddr(); ok {
		t.Fatal("an 11 s old check still gives an address")
	}
	b.at = time.Now().Add(-9 * time.Second)
	if _, ok := b.HTTPAddr(); !ok {
		t.Fatal("a 9 s old check gives no address")
	}
}

func TestAPInfo(t *testing.T) {
	e := bulkStubs(t)
	b := &realBulk{netDir: e.net}
	up, ssid, pass := b.AP()
	if !up || ssid != "batman-ap" || pass != " pass with blanks " {
		t.Fatalf("AP: %v %q %q", up, ssid, pass)
	}
	e.set("wifi.json", wifiOff)
	if up, _, _ := b.AP(); up {
		t.Fatal("AP up with no AP interface (04 today)")
	}
	e.set("wifi.json", `{"radio0": {"up": false, "interfaces": [{"section": "default_radio0", "ifname": "phy0-ap0"}]}}`)
	if up, _, _ := b.AP(); up {
		t.Fatal("AP up on a radio that is down")
	}
	e.set("wifi.json", `{"radio0": {"up": true, "interfaces": [{"section": "other", "ifname": "phy0-ap1"}]}}`)
	if up, _, _ := b.AP(); up {
		t.Fatal("another section counted as the phone AP")
	}
}

func TestBulkTmpfs(t *testing.T) {
	d := t.TempDir()
	plain := filepath.Join(d, "bulk")
	os.Mkdir(plain, 0o700)
	if err := bulkTmpfsAt(plain); err == nil {
		t.Fatal("a plain directory accepted")
	}
	os.Symlink(plain, filepath.Join(d, "link"))
	if err := bulkTmpfsAt(filepath.Join(d, "link")); err == nil {
		t.Fatal("a symlink followed")
	}
	if os.Geteuid() != 0 {
		t.Skip("root only: tmpfs mounts")
	}
	mnt := func(p string) {
		if out, err := exec.Command("mount", "-t", "tmpfs", "-o", "size=1m", "none", p).CombinedOutput(); err != nil {
			t.Fatalf("mount: %v %s", err, out)
		}
		t.Cleanup(func() { exec.Command("umount", p).Run() })
	}
	mnt(plain)
	if err := bulkTmpfsAt(plain); err != nil {
		t.Fatalf("its own tmpfs refused: %v", err)
	}
	if err := bulkTmpfsAt(filepath.Join(d, "link")); err == nil {
		t.Fatal("a symlink to a real tmpfs mount followed")
	}
	sub := filepath.Join(plain, "sub")
	os.Mkdir(sub, 0o700)
	if err := bulkTmpfsAt(sub); err == nil {
		t.Fatal("a directory inside a tmpfs (not a mount point of its own) accepted")
	}
	r := filepath.Join(d, "ramfs")
	os.Mkdir(r, 0o700)
	if out, err := exec.Command("mount", "-t", "ramfs", "none", r).CombinedOutput(); err != nil {
		t.Fatalf("mount ramfs: %v %s", err, out)
	}
	t.Cleanup(func() { exec.Command("umount", r).Run() })
	if err := bulkTmpfsAt(r); err == nil {
		t.Fatal("a ramfs (no size limit) accepted")
	}
}
