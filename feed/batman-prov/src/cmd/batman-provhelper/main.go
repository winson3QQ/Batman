// batman-provhelper — the root half of the #254 provisioning service (docs/design/254-stage1-impl.md §2–§4;
// 254-p1-impl.md). Holds the node identity, persists the provisioning record through batman-config-save, applies
// state changes, and answers the unprivileged provd (PR-P2) on a SEQPACKET socket.
//
//	batman-provhelper                  daemon (procd S89): --boot, then health + socket
//	batman-provhelper --boot           reconcile overlay / p5 once and exit
//	batman-provhelper --apply-state [--firstboot]   finish pending transitions (99zz passes --firstboot)
//	batman-provhelper --persist-now    re-write the overlay record to p5 (P5_STALE_HINT)
//	batman-provhelper qr               print the claim QR payload (legacy: dev-open or a real console only)
//	batman-provhelper --version        line 1 "batman-provhelper <BATMAN_VERSION>"; a prov_test build adds the marker line
package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/syslog"
	"os"
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
	"batman-prov/seam"
	"batman-prov/shacrypt"
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
		logw.Info(msg) // procd also captures stderr: write it only when syslog is unavailable (no duplicate lines)
		return
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

// keyguardMark: what halow-keyguard / halow-setkey blocked (tests point it elsewhere)
var keyguardMark = "/etc/halow-keyguard.blocked"

// cleanEnv: the environment of every command (tests point PATH at stubs)
var cleanEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C"}

// run: every subprocess has a deadline (254-wireless-txn §3, code review B MAJOR-1) — halow-setkey and
// batman-config-save may legitimately take minutes (wifi reload + verify, a p5 write); anything else gets 60 s.
// A timeout returns provstore.RCTimeout (124): outcome unknown, a wireless transaction keeps .txn.
func run(stdin []byte, name string, args ...string) (int, string) {
	t := 60 * time.Second
	switch filepath.Base(name) {
	case "halow-setkey":
		t = 300 * time.Second
	case "batman-config-save":
		t = provstore.ConfigSaveTimeout
	}
	return provstore.Exec(t, cleanEnv, stdin, name, args...)
}

func uciGet(k string) string {
	_, out := run(nil, "uci", "-q", "get", k)
	return strings.TrimSpace(out)
}

// uciRaw: a value as uci holds it — only the trailing newline is cut (a key may start or end with a blank; §15.6)
func uciRaw(k string) string {
	_, out := run(nil, "uci", "-q", "get", k)
	return strings.TrimSuffix(out, "\n")
}

// meshIface: the mesh interface on the morse (HaLow) radio — the same radio halow-setkey's morse_radio() picks
// (`type='morse'`, the first one), so the helper and setkey act on one radio (§15.6, A m8 / B m11).
func meshIface() string { i, _ := meshIfaceErr(); return i }

// meshIfaceErr: "" + nil = no mesh interface on the morse radio (the config says so); an error = uci itself failed.
func meshIfaceErr() (string, error) {
	rc, out := run(nil, "uci", "-q", "show", "wireless")
	if rc != 0 {
		return "", fmt.Errorf("uci show wireless rc=%d", rc)
	}
	radio := ""
	for _, l := range strings.Split(out, "\n") {
		if strings.HasSuffix(l, ".type='morse'") && radio == "" {
			radio = strings.Split(strings.TrimPrefix(l, "wireless."), ".")[0]
		}
	}
	if radio == "" {
		return "", nil
	}
	for _, l := range strings.Split(out, "\n") {
		if strings.HasSuffix(l, ".mode='mesh'") {
			i := strings.Split(strings.TrimPrefix(l, "wireless."), ".")[0]
			if uciGet("wireless."+i+".device") == radio {
				return i, nil
			}
		}
	}
	return "", nil
}

// ---- the real Sys ----------------------------------------------------------------------------------------------

type realSys struct{ p provstore.Paths }

// IsTrial fails closed: anything but "committed" (rc 1) counts as a trial — unknown (rc 2) included (round-6 B-m1)
func (s realSys) IsTrial() bool { rc, _ := run(nil, "batman-slot", "is-trial"); return rc != 1 }
func (s realSys) Persist(r, m, id, txn string) (int, string) {
	return provstore.PersistP5(s.p, r, m, id, txn)
}
func (s realSys) GetP5(dir string) (int, string) { return provstore.GetP5(s.p, dir) }
func (s realSys) Save() (int, string)            { return run(nil, s.p.ConfigSave, "--save") }

// SetKeyNoPersist: the key goes over stdin (`--mesh -`), never on a command line. rc 2 = nothing changed.
func (s realSys) SetKeyNoPersist(key, id, ch string) error {
	args := []string{"--mesh", "-"}
	if id != "" {
		args = append(args, "--mesh-id", id)
	}
	if ch != "" {
		args = append(args, "--channel", ch)
	}
	rc, out := run([]byte(key+"\n"), "halow-setkey", append(args, "--no-persist")...)
	if rc != 0 {
		return &node.SetkeyError{RC: rc, Msg: lastLine(out)}
	}
	return nil
}

// ForgetMesh: placeholder key + the radio blocked by the keyguard, verified down (halow-setkey --forget-mesh).
func (s realSys) ForgetMesh() error {
	rc, out := run(nil, "halow-setkey", "--forget-mesh", "--no-persist")
	if rc != 0 {
		return &node.SetkeyError{RC: rc, Msg: lastLine(out)}
	}
	return nil
}

// SaveTxn: the p5 save of a wireless transaction, allowed only while the run-dir marker and .txn carry the token.
func (s realSys) SaveTxn(token string) (int, string) {
	return run(nil, s.p.ConfigSave, "--save", "--txn", token)
}

// RadioState: the morse radio's uci `disabled`, and whether the keyguard mark lists it (blocked by us, not by hand).
func (s realSys) RadioState() (bool, bool, error) {
	i := meshIface()
	if i == "" {
		return false, false, errors.New("no mesh interface")
	}
	dev := uciGet("wireless." + i + ".device")
	if dev == "" {
		return false, false, errors.New("mesh interface without a radio")
	}
	in := false
	if b, err := os.ReadFile(keyguardMark); err == nil {
		// the first line only, as halow-setkey and halow-keyguard read it (`read -r`)
		for _, f := range strings.Fields(strings.SplitN(string(b), "\n", 2)[0]) {
			if f == dev {
				in = true
			}
		}
	}
	return uciGet("wireless."+dev+".disabled") == "1", in, nil
}
func (s realSys) CurrentWireless() (string, string, string, error) {
	i := meshIface()
	if i == "" {
		return "", "", "", errors.New("no mesh interface")
	}
	dev := uciGet("wireless." + i + ".device")
	return uciRaw("wireless." + i + ".key"), uciGet("wireless." + i + ".mesh_id"), uciGet("wireless." + dev + ".channel"), nil
}

// CheckRestorable (§15.1): could halow-setkey put these values back? Its own validation (`--check-only`, no lock, no
// write; the key over stdin) plus the encryption it would force (sae): an operator mesh with another encryption, or
// an empty key, cannot be restored by it.
// A refusal is definitive (*node.RestoreRefused: Finish forgets); a timeout / exec failure is transient (a plain
// error: Finish keeps .txn and retries — §16.3, review 2 B m1).
func (s realSys) CheckRestorable(key, id, ch string) error {
	i, err := meshIfaceErr()
	if err != nil {
		return err // transient: uci itself failed
	}
	if i == "" {
		return &node.RestoreRefused{Why: "no mesh interface on the morse radio"}
	}
	switch rc, out := run(nil, "uci", "-q", "get", "wireless."+i+".encryption"); {
	case rc == 0 && strings.TrimSpace(out) == "sae":
	case rc == 0 || rc == 1: // set to something else, or not set (open)
		return &node.RestoreRefused{Why: fmt.Sprintf("encryption %q is not sae", strings.TrimSpace(out))}
	default:
		return fmt.Errorf("uci get encryption rc=%d", rc) // transient
	}
	if key == "" {
		return &node.RestoreRefused{Why: "no mesh key (open mesh)"}
	}
	args := []string{"--check-only", "--mesh", "-"}
	if id != "" {
		args = append(args, "--mesh-id", id)
	}
	if ch != "" {
		args = append(args, "--channel", ch)
	}
	switch rc, out := run([]byte(key+"\n"), "halow-setkey", args...); rc {
	case 0:
		return nil
	case 2:
		return &node.RestoreRefused{Why: "halow-setkey --check-only: " + lastLine(out)}
	default:
		return fmt.Errorf("halow-setkey --check-only rc=%d: %s", rc, lastLine(out))
	}
}

// LiveMeshUp (§15.4): the HaLow radio is up on the uci mesh id (meshjoin_radio_up: wpa_supplicant's ssid).
func (s realSys) LiveMeshUp() bool {
	rc, _ := run(nil, "sh", "-c", ". /usr/lib/batman/meshjoin.sh && meshjoin_radio_up")
	return rc == 0
}

// ---- the lock: ONE implementation, prov_apply_lock in prov-lock.sh (docs/design/254-claim-lock-fix.md §5.3) ----

const provLockLib = "/usr/lib/batman/prov-lock.sh"

// provApplyLock runs `prov_apply_lock <flags>` with field (if any) on stdin and maps its last line
// "LOCK <step> rc=<n>" to an error naming the step. The hash never goes on a command line.
func provApplyLock(field string, flags ...string) error {
	var in []byte
	if field != "" {
		in = []byte(field + "\n")
	}
	rc, out := run(in, "sh", append([]string{"-c", `. ` + provLockLib + ` && prov_apply_lock "$@"`, "prov_apply_lock"}, flags...)...)
	if rc != 0 {
		return fmt.Errorf("prov_apply_lock %s: %s", strings.Join(flags, " "), lastLine(out))
	}
	return nil
}

// ApplyLock: lock the doors (every dropbear section key-only, ttylogin=1, dropbear reloaded and read back) and only
// then write the new root hash; any failure leaves shadow at its previous value (an empty root becomes "!").
// ApplyLock("") locks the doors without a hash (an empty root becomes "!") — used when no hash could be made.
func (s realSys) ApplyLock(hash string) error {
	if hash == "" {
		return provApplyLock("")
	}
	if !shacrypt.ValidNew(hash) {
		provApplyLock("") // still lock the doors (fail-secure, review A-m1)
		return errors.New("ApplyLock: not a $6$ hash of the expected shape")
	}
	return provApplyLock(hash, "--hash-stdin")
}

// RestoreRoot writes root's previous shadow field back (after a failed --save, §5.3 restore rule); "" -> "!".
func (s realSys) RestoreRoot(prev string) error {
	// a previous field that is neither a hash nor a lock marker ("", "*", "x", ...) comes back as "!" — never the
	// never-delivered hash and never an empty (open) root (review B-m1)
	if !strings.HasPrefix(prev, "$") && !strings.HasPrefix(prev, "!") {
		prev = "!"
	}
	return provApplyLock(prev, "--restore-stdin", "--no-reload")
}

// RootField: root's current shadow field ("" when empty).
func (s realSys) RootField() (string, error) {
	b, err := os.ReadFile("/etc/shadow")
	if err != nil {
		return "", err
	}
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "root:") {
			return strings.Split(l, ":")[1], nil
		}
	}
	return "", errors.New("no root line in /etc/shadow")
}

// MarkLockIncomplete: p6 lock-status = LOCK-INCOMPLETE (tmp + rename), so a person sees it (halow-status).
func (s realSys) MarkLockIncomplete() {
	if fi, err := os.Stat(s.p.State); err != nil || !fi.IsDir() {
		return
	}
	t := filepath.Join(s.p.State, ".lock-status.helper")
	if os.WriteFile(t, []byte("LOCK-INCOMPLETE\n"), 0o644) == nil {
		os.Rename(t, filepath.Join(s.p.State, "lock-status"))
	}
}

// SetLastKnown rewrites ONLY field 3 (last_known_state) of p6 prov-state after a claim / replay commit, keeping
// every other field (field 6 mesh_expect is read by autocommit's OTA gate); tmp + rename, 0600. No file, or a
// malformed one, is left alone (boot.Run writes it at the next start).
func (s realSys) SetLastKnown(state string) error {
	f := filepath.Join(s.p.State, "prov-state")
	b, err := os.ReadFile(f)
	if err != nil {
		return err
	}
	fl := strings.Fields(strings.SplitN(string(b), "\n", 2)[0])
	if len(fl) < 6 {
		return fmt.Errorf("prov-state has %d fields", len(fl))
	}
	fl[2] = state
	t := f + ".helper"
	if err := os.WriteFile(t, []byte(strings.Join(fl, " ")+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(t, f)
}

// SetMeshExpect rewrites ONLY field 6 (mesh_expect) of p6 prov-state, like SetLastKnown (254-wireless-txn §3).
func (s realSys) SetMeshExpect(me string) error {
	f := filepath.Join(s.p.State, "prov-state")
	b, err := os.ReadFile(f)
	if err != nil {
		return err
	}
	fl := strings.Fields(strings.SplitN(string(b), "\n", 2)[0])
	if len(fl) < 6 {
		return fmt.Errorf("prov-state has %d fields", len(fl))
	}
	fl[5] = me
	t := f + ".helper"
	if err := os.WriteFile(t, []byte(strings.Join(fl, " ")+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(t, f)
}

// CryptPassword: SHA-512 crypt in Go (shacrypt), salt from crypto/rand — no external command (§5.1).
func (s realSys) CryptPassword(pw string) (string, error) { return shacrypt.New512([]byte(pw)) }

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
		me := boot.MeshExpect(rec.State, bootEnv(p).MeshKey)
		if fi, err := os.Stat(p.State); err == nil && fi.IsDir() {
			os.WriteFile(filepath.Join(p.State, "prov-state"), []byte(fmt.Sprintf("%s 99zz %s %s - %s\n", bootID(), rec.State, rec.State, me)), 0o600)
		}
		return nil
	}
	if rec.State == provstore.Claimed || rec.State == provstore.Member {
		// a claim interrupted after persist: the lock is judged from the real values, not lock-status
		// through the one implementation, without a hash: a $ hash is kept, an empty root becomes "!" (§5.3);
		// at firstboot (99zz, uci-defaults) dropbear is not running yet -> --no-reload
		// every dropbear section (dropbear.init starts one instance per section), not only @dropbear[0] (review A-m8)
		unlocked := uciGet("system.@system[0].ttylogin") != "1"
		_, sh := run(nil, "uci", "-q", "show", "dropbear")
		for _, l := range strings.Split(sh, "\n") {
			sec, ok := strings.CutSuffix(strings.TrimPrefix(l, "dropbear."), "=dropbear")
			if !ok || strings.Contains(sec, ".") {
				continue
			}
			// an unset option means "on" in dropbear.init: compare the value, not the presence of a line
			if uciGet("dropbear."+sec+".PasswordAuth") != "off" || uciGet("dropbear."+sec+".RootPasswordAuth") != "off" {
				unlocked = true
			}
		}
		root, _ := (realSys{p}).RootField()
		if unlocked || root == "" {
			logf("apply-state: completing an interrupted lock (hash present: %v)", strings.HasPrefix(root, "$"))
			flags := []string{}
			if firstboot {
				flags = append(flags, "--no-reload")
			}
			if err := provApplyLock("", flags...); err != nil {
				return err
			}
		}
	}
	return nil
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		os.Exit(version(os.Stdout, "/etc/batman-build"))
	}
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
		if seam.Marker != "" {
			logf("%s", seam.Marker)
		}
		boot.Run(bootEnv(p)) // an unfinished wireless change is the daemon's (Finish before serving)
		return
	case "--apply-state":
		if err := applyState(p, len(args) > 1 && args[1] == "--firstboot"); err != nil {
			logf("apply-state: %v", err)
			os.Exit(1)
		}
		return
	case "--persist-now":
		// round-7 B-M3: a side-effect-free decision, not a second boot.Run (which would race the daemon on .stage/.txn)
		rc, why := boot.PersistNow(bootEnv(p))
		logf("persist-now: rc=%d %s", rc, lastLine(why))
		os.Exit(rc)
	case "qr":
		os.Exit(qr(p))
	case "":
	default:
		fmt.Fprintln(os.Stderr, "usage: batman-provhelper [--boot | --apply-state [--firstboot] | --persist-now | qr | --version]")
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
	if seam.Marker != "" {
		logf("%s", seam.Marker)
	}
	seam.Arm(logf)                                 // the killpoint file is read once per daemon start (prov_test builds only)
	os.Remove(filepath.Join(p.RunDir, "prov-txn")) // a marker of a helper that died cannot be live
	res := boot.Run(bootEnv(p))
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
	n.Verdict = res.Verdict
	// docs/design/254-wireless-txn.md §3: an unfinished wireless change is finished BEFORE serving — the previous state
	// of the record p5 confirmed. Not on an unknown verdict or an unread p5 (then the first saving verb, or the next
	// boot, finishes it). A network to rejoin waits for the radio (up to 120 s); a forget / blocked radio does not.
	if res.Unfinished && res.P5Read && !strings.HasPrefix(res.Verdict, "unknown") {
		n.BootFinish(func() { waitRadioUp(120 * time.Second) }) // holds the mutex from here until it ends (§15.2)
	}
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

// waitRadioUp: meshjoin_radio_up (the mesh interface is up on the uci mesh id), polled until true or the deadline.
func waitRadioUp(max time.Duration) {
	end := time.Now().Add(max)
	for time.Now().Before(end) {
		if rc, _ := run(nil, "sh", "-c", ". /usr/lib/batman/meshjoin.sh && meshjoin_radio_up"); rc == 0 {
			return
		}
		time.Sleep(2 * time.Second)
	}
	logf("boot finish: radio not up after %s — finishing anyway", max)
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

// version prints "batman-provhelper <BATMAN_VERSION>" (from the image stamp) and, in a prov_test build, the marker on
// line 2. The preflight uses the exit status to tell a seam-capable image (rc 0) from an older one (usage, rc 2).
func version(w io.Writer, stamp string) int {
	v := "unknown"
	if b, err := os.ReadFile(stamp); err == nil {
		for l := range strings.Lines(string(b)) {
			l = strings.TrimSpace(l)
			if strings.HasPrefix(l, "BATMAN_VERSION=") {
				v = strings.TrimPrefix(l, "BATMAN_VERSION=")
			}
		}
	}
	fmt.Fprintln(w, "batman-provhelper "+v)
	if seam.Marker != "" {
		fmt.Fprintln(w, seam.Marker)
	}
	return 0
}
