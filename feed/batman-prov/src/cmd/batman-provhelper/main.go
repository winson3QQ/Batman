// batman-provhelper — the root half of the #254 provisioning service (docs/design/254-stage1-impl.md §2–§4;
// 254-p1-impl.md). Holds the node identity, persists the provisioning record through batman-config-save, applies
// state changes, and answers the unprivileged provd (PR-P2) on a SEQPACKET socket.
//
//	batman-provhelper                  daemon (procd S89): --boot, then health + socket
//	batman-provhelper --boot           reconcile overlay / p5 once and exit
//	batman-provhelper --apply-state [--firstboot]   finish pending transitions (99zz passes --firstboot)
//	batman-provhelper --persist-now    re-write the overlay record to p5 (P5_STALE_HINT)
//	batman-provhelper qr               print the claim QR payload (legacy: dev-open or a real console only)
package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"log/syslog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"batman-prov/boot"
	"batman-prov/cbor"
	"batman-prov/health"
	"batman-prov/keystore"
	"batman-prov/node"
	"batman-prov/provstore"
	"batman-prov/sock"
)

const (
	provdUID    = 471
	provdGID    = 471
	sockDir     = "/tmp/run/batman-prov"
	placeholder = "CHANGE-ME-NOW"
)

var logw *syslog.Writer

func logf(format string, a ...any) {
	msg := fmt.Sprintf(format, a...)
	if logw != nil {
		logw.Info(msg)
	}
	fmt.Fprintln(os.Stderr, "batman-provhelper: "+msg)
}

func bootID() string {
	b, _ := os.ReadFile("/proc/sys/kernel/random/boot_id")
	return strings.TrimSpace(string(b))
}

func uptime() int {
	b, _ := os.ReadFile("/proc/uptime")
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[0], 64)
	return int(v)
}

var cleanEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C"}

func run(stdin []byte, name string, args ...string) (int, string) {
	c := exec.Command(name, args...)
	c.Env = cleanEnv
	if stdin != nil {
		c.Stdin = bytes.NewReader(stdin)
	}
	out, err := c.CombinedOutput()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode(), string(out)
		}
		return 127, err.Error()
	}
	return 0, string(out)
}

func uciGet(k string) string {
	_, out := run(nil, "uci", "-q", "get", k)
	return strings.TrimSpace(out)
}

func meshIface() string {
	_, out := run(nil, "uci", "-q", "show", "wireless")
	for _, l := range strings.Split(out, "\n") {
		if strings.HasSuffix(l, ".mode='mesh'") {
			p := strings.Split(strings.TrimPrefix(l, "wireless."), ".")
			return p[0]
		}
	}
	return ""
}

// ---- the real Sys ----------------------------------------------------------------------------------------------

type realSys struct{ p provstore.Paths }

func (s realSys) IsTrial() bool { rc, _ := run(nil, "batman-slot", "is-trial"); return rc == 0 }
func (s realSys) Persist(r, m, id, txn string) (int, string) {
	return provstore.PersistP5(s.p, r, m, id, txn)
}
func (s realSys) GetP5(dir string) (int, string) { return provstore.GetP5(s.p, dir) }
func (s realSys) Save() (int, string)            { return run(nil, s.p.ConfigSave, "--save") }

// SetKeyNoPersist: the key goes over stdin (`--mesh -`), never on a command line.
func (s realSys) SetKeyNoPersist(key, id, ch string) error {
	rc, out := run([]byte(key+"\n"), "halow-setkey", "--mesh", "-", "--mesh-id", id, "--channel", ch, "--no-persist")
	if rc != 0 {
		return fmt.Errorf("halow-setkey rc=%d: %s", rc, lastLine(out))
	}
	return nil
}
func (s realSys) CurrentWireless() (string, string, string, error) {
	i := meshIface()
	if i == "" {
		return "", "", "", errors.New("no mesh interface")
	}
	dev := uciGet("wireless." + i + ".device")
	return uciGet("wireless." + i + ".key"), uciGet("wireless." + i + ".mesh_id"), uciGet("wireless." + dev + ".channel"), nil
}

// ApplyLock: §6.2 — network key-only, serial via the per-node password, lock-status LOCKED. Shadow edited surgically.
func (s realSys) ApplyLock(hash string) error {
	if !(strings.HasPrefix(hash, "$") || hash == "!") || strings.ContainsAny(hash, ":\n") {
		return errors.New("bad hash") // a crypt hash, or "!" = locked without a password (root:!)
	}
	b, err := os.ReadFile("/etc/shadow")
	if err != nil {
		return err
	}
	var out []string
	found := false
	for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		if strings.HasPrefix(l, "root:") {
			f := strings.Split(l, ":")
			f[1] = hash
			l = strings.Join(f, ":")
			found = true
		}
		out = append(out, l)
	}
	if !found {
		return errors.New("no root line in /etc/shadow")
	}
	if err := os.WriteFile("/etc/shadow.prov", []byte(strings.Join(out, "\n")+"\n"), 0o600); err != nil {
		return err
	}
	if err := os.Rename("/etc/shadow.prov", "/etc/shadow"); err != nil {
		return err
	}
	for _, kv := range [][2]string{{"dropbear.@dropbear[0].PasswordAuth", "off"}, {"dropbear.@dropbear[0].RootPasswordAuth", "off"}, {"system.@system[0].ttylogin", "1"}} {
		if rc, o := run(nil, "uci", "set", kv[0]+"="+kv[1]); rc != 0 {
			return fmt.Errorf("uci set %s: %s", kv[0], o)
		}
	}
	run(nil, "uci", "commit", "dropbear")
	run(nil, "uci", "commit", "system")
	run(nil, "/etc/init.d/dropbear", "reload")
	if fi, err := os.Stat(s.p.State); err == nil && fi.IsDir() {
		os.WriteFile(filepath.Join(s.p.State, "lock-status"), []byte("LOCKED\n"), 0o644)
	}
	return nil
}

// CryptPassword: busybox cryptpw, password on stdin (-s), SHA-512.
func (s realSys) CryptPassword(pw string) (string, error) {
	rc, out := run([]byte(pw+"\n"), "cryptpw", "-s", "-m", "sha512")
	h := strings.TrimSpace(out)
	if rc != 0 || !strings.HasPrefix(h, "$6$") {
		return "", fmt.Errorf("cryptpw rc=%d", rc)
	}
	return h, nil
}

const akPath = "/etc/dropbear/authorized_keys"

func (s realSys) AuthorizedKeys() ([]string, error) {
	b, err := os.ReadFile(akPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "ssh-") || strings.HasPrefix(t, "ecdsa-") || strings.HasPrefix(t, "sk-") {
			out = append(out, t)
		}
	}
	return out, nil
}
func (s realSys) SetAuthorizedKeys(lines []string) error {
	tmp := akPath + ".prov"
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, akPath)
}
func (s realSys) DevOpen() bool { _, err := os.Stat("/etc/batman-dev-open"); return err == nil }
func (s realSys) WriteTxnMarker(token string) error {
	return os.WriteFile(filepath.Join(s.p.RunDir, "prov-txn"), []byte(token), 0o600)
}
func (s realSys) ClearTxnMarker() { os.Remove(filepath.Join(s.p.RunDir, "prov-txn")) }

// DiagBundle: status + logs, never secrets (no uci wireless / shadow / identity).
func (s realSys) DiagBundle() ([]byte, error) {
	var b bytes.Buffer
	for _, c := range [][]string{{"halow-status"}, {"batman-slot", "verify"}, {"logread", "-l", "300"}} {
		_, out := run(nil, c[0], c[1:]...)
		fmt.Fprintf(&b, "=== %s\n%s\n", strings.Join(c, " "), out)
	}
	return b.Bytes(), nil
}
func (s realSys) RemoveMeshMarkers() error {
	for _, f := range []string{"mesh-expected", "mesh-joined"} {
		if err := os.Remove(filepath.Join(s.p.State, f)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}
func (s realSys) Now() time.Time { return time.Now() }

func lastLine(s string) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	return l[len(l)-1]
}

// ---- modes ---------------------------------------------------------------------------------------------------------

func bootEnv(p provstore.Paths) boot.Env {
	sys := realSys{p}
	return boot.Env{
		P:       p,
		GetP5:   sys.GetP5,
		Persist: func(r, m, id string) (int, string) { return sys.Persist(r, m, id, "") },
		Bypass: func() bool {
			b, _ := os.ReadFile("/proc/cmdline")
			return strings.Contains(string(b), "batman_bypass=1")
		},
		BootID: bootID,
		MeshKey: func() string {
			i := meshIface()
			if i == "" {
				return ""
			}
			return uciGet("wireless." + i + ".key")
		},
		Log:      logf,
		Generate: keystore.Generate,
		Sleep:    time.Sleep,
	}
}

// applyState (§4.4 step 8): finish transitions from the ACTUAL values; with firstboot (99zz, S10) also the
// unclaimed AP placeholder — the only uci write 99zz makes. No reload, no persist.
func applyState(p provstore.Paths, firstboot bool) error {
	rec, _, err := provstore.LoadOverlay(p)
	if err != nil {
		return err
	}
	if rec == nil {
		return errors.New("no provisioning record")
	}
	if firstboot {
		b, _ := os.ReadFile("/etc/.batman-prov-restore")
		f := strings.Fields(string(b))
		verdict := ""
		if len(f) >= 2 {
			verdict = f[1]
		}
		if verdict == "unseeded" && rec.State == provstore.Unclaimed {
			_, out := run(nil, "uci", "-q", "show", "wireless")
			for _, l := range strings.Split(out, "\n") {
				if strings.HasSuffix(l, ".mode='ap'") {
					sec := strings.Split(strings.TrimPrefix(l, "wireless."), ".")[0]
					run(nil, "uci", "set", "wireless."+sec+".key="+placeholder)
				}
			}
			run(nil, "uci", "commit", "wireless")
			logf("unclaimed: AP keys set to the placeholder")
		}
		me := map[string]string{provstore.Unclaimed: "0", provstore.Member: "radio"}[rec.State]
		if me == "" {
			me = "today"
		}
		if fi, err := os.Stat(p.State); err == nil && fi.IsDir() {
			os.WriteFile(filepath.Join(p.State, "prov-state"), []byte(fmt.Sprintf("%s 99zz %s %s - %s\n", bootID(), rec.State, rec.State, me)), 0o600)
		}
		return nil
	}
	if rec.State == provstore.Claimed || rec.State == provstore.Member {
		// a claim interrupted after persist: the lock is judged from the real values, not lock-status
		if uciGet("dropbear.@dropbear[0].PasswordAuth") != "off" || uciGet("dropbear.@dropbear[0].RootPasswordAuth") != "off" || uciGet("system.@system[0].ttylogin") != "1" {
			sh, _ := os.ReadFile("/etc/shadow")
			hash := ""
			for _, l := range strings.Split(string(sh), "\n") {
				if strings.HasPrefix(l, "root:") {
					hash = strings.Split(l, ":")[1]
				}
			}
			if !strings.HasPrefix(hash, "$") {
				hash = "!"
			}
			logf("apply-state: completing an interrupted lock (hash present: %v)", hash != "!")
			if err := (realSys{p}).ApplyLock(hash); err != nil {
				return err
			}
		}
	}
	return nil
}

func main() {
	logw, _ = syslog.New(syslog.LOG_DAEMON|syslog.LOG_INFO, "batman-provhelper")
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "batman-provhelper: root only")
		os.Exit(2)
	}
	p := provstore.Default()
	args := os.Args[1:]
	mode := ""
	if len(args) > 0 {
		mode = args[0]
	}
	switch mode {
	case "--boot":
		if res := boot.Run(bootEnv(p)); res.Restore != nil {
			restoreWireless(p, res.Restore, 0)
		}
		return
	case "--apply-state":
		if err := applyState(p, len(args) > 1 && args[1] == "--firstboot"); err != nil {
			logf("apply-state: %v", err)
			os.Exit(1)
		}
		return
	case "--persist-now":
		r, _, err := provstore.LoadOverlay(p)
		if err != nil || r == nil {
			logf("persist-now: no usable overlay record (%v)", err)
			os.Exit(1)
		}
		if res := boot.Run(bootEnv(p)); strings.Contains(res.Verdict, "identity-mismatch") {
			logf("persist-now refused: node identity mismatch — owner action or reflash needed")
			os.Exit(1)
		}
		rc, out := provstore.PersistP5(p, p.Record(), p.Meta(), p.Identity(), "")
		logf("persist-now: rc=%d %s", rc, lastLine(out))
		os.Exit(rc)
	case "qr":
		os.Exit(qr(p))
	case "":
	default:
		fmt.Fprintln(os.Stderr, "usage: batman-provhelper [--boot | --apply-state [--firstboot] | --persist-now | qr]")
		os.Exit(2)
	}
	daemon(p)
}

func qr(p provstore.Paths) int {
	rec, _, err := provstore.LoadOverlay(p)
	if err != nil || rec == nil {
		return 1
	}
	switch rec.State {
	case provstore.Claimed, provstore.Member:
		fmt.Fprintln(os.Stderr, "qr: node is claimed")
		return 1
	case provstore.Legacy:
		tty, _ := os.Readlink("/proc/self/fd/0")
		real := tty == "/dev/console" || strings.HasPrefix(tty, "/dev/ttyAMA") || tty == "/dev/tty1"
		if _, err := os.Stat("/etc/batman-dev-open"); err != nil && !real {
			fmt.Fprintln(os.Stderr, "qr: legacy node — only with /etc/batman-dev-open or on a physical console")
			return 1
		}
	}
	ks, err := keystore.Load(p.Identity())
	if err != nil {
		return 1
	}
	sec, _ := os.ReadFile(filepath.Join(p.Identity(), "claim.secret"))
	b, _ := cbor.Encode(cbor.M(1, ks.DeviceID(), 2, sec))
	fmt.Println(hex.EncodeToString(b))
	return 0
}

func daemon(p provstore.Paths) {
	os.Remove(filepath.Join(p.RunDir, "prov-txn")) // a marker of a helper that died cannot be live
	res := boot.Run(bootEnv(p))
	if res.Restore != nil {
		go restoreWireless(p, res.Restore, 120*time.Second)
	}
	ks, err := keystore.Load(p.Identity())
	if err != nil {
		logf("no usable identity (%s): serving nothing", res.Verdict)
		select {} // stay up for procd; health still matters
	}
	if err := applyState(p, false); err != nil {
		logf("apply-state: %v", err)
	}
	stop := make(chan struct{})
	h := &health.Env{
		BootID: bootID, Uptime: uptime, ReadInfo: health.ReadInfo, BTDPid: btdPid,
		ScFile: "/var/lib/bluetooth/batman-sc", Out: filepath.Join(p.RunDir, "batman-prov.health"),
		Committed: func() bool { rc, _ := run(nil, "batman-slot", "is-trial"); return rc == 1 },
		ConfigOK:  bootConfigOK, BleOK: filepath.Join(p.State, "ble-ok"),
	}
	go h.Run(stop)
	if err := sock.PrepareDir(sockDir, provdGID); err != nil {
		logf("%v", err)
		os.Exit(1)
	}
	n := node.New(p, ks, realSys{p}, logf)
	srv := &sock.Server{Path: filepath.Join(sockDir, "helper.sock"), PeerUID: provdUID, GID: provdGID, Idle: 30 * time.Second, Log: logf}
	if err := srv.Listen(); err != nil {
		logf("listen: %v", err)
		os.Exit(1)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-sig; close(stop); srv.Close(); os.Exit(0) }()
	logf("serving (%s)", res.Verdict)
	srv.Serve(n.Handle)
}

// restoreWireless (§4.4 step 6): an interrupted, NOT committed net.apply — put the recorded pre-change wireless values
// back with halow-setkey (persisting this time), then drop .txn. --on-join yields while .txn exists.
func restoreWireless(p provstore.Paths, t *provstore.Txn, wait time.Duration) {
	time.Sleep(wait)
	args := []string{"--mesh", "-"}
	if t.PrevID != "" {
		args = append(args, "--mesh-id", t.PrevID)
	}
	if t.PrevChannel != "" {
		args = append(args, "--channel", t.PrevChannel)
	}
	rc, out := run([]byte(t.PrevKey+"\n"), "halow-setkey", args...)
	logf("txn %s not committed: restored the previous wireless values, setkey rc=%d (%s)", t.Verb, rc, lastLine(out))
	if rc == 0 {
		provstore.RemoveTxn(p)
	}
}

func btdPid() int {
	ents, _ := os.ReadDir("/proc")
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, _ := os.ReadFile(filepath.Join("/proc", e.Name(), "comm"))
		if strings.TrimSpace(string(b)) == "bluetoothd" {
			return pid
		}
	}
	return 0
}

// bootConfigOK (§6.4 ble-ok): both boot FATs' [pi4] section have miniuart-bt and core_freq_min=500, and the running
// firmware reports core_freq_min >= 500.
func bootConfigOK() bool {
	sectionOK := func(b []byte) bool {
		in, mb, cf := false, false, false
		for _, l := range strings.Split(string(b), "\n") {
			l = strings.TrimSpace(l)
			if strings.HasPrefix(l, "[") {
				in = l == "[pi4]"
				continue
			}
			if in && l == "dtoverlay=miniuart-bt" {
				mb = true
			}
			if in && l == "core_freq_min=500" {
				cf = true
			}
		}
		return mb && cf
	}
	b1, err := os.ReadFile("/boot/distroconfig.txt")
	if err != nil || !sectionOK(b1) {
		return false
	}
	m, err := os.MkdirTemp("/tmp/run/batman", "p3.")
	if err != nil {
		return false
	}
	defer os.Remove(m)
	if rc, _ := run(nil, "mount", "-t", "vfat", "-o", "ro", "/dev/mmcblk0p3", m); rc != 0 {
		return false
	}
	b3, err := os.ReadFile(filepath.Join(m, "distroconfig.txt"))
	run(nil, "umount", m)
	if err != nil || !sectionOK(b3) {
		return false
	}
	_, out := run(nil, "vcgencmd", "get_config", "core_freq_min")
	v, _ := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(out), "core_freq_min=")))
	return v >= 500
}
