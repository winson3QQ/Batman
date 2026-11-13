package main

// status.get's sources (docs/design/254-p3-impl.md §3.4): `halow-status json` and `batman-config-save --check`, run
// in the background by node's status cache (never on a request path).

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"syscall"
	"time"

	"batman-prov/node"
	"batman-prov/provstore"
)

const halowStatusTimeout = 20 * time.Second // 04 (wsl.22): ~0.5 s

func halowStatusJSON() ([]byte, error) {
	rc, out := provstore.Exec(halowStatusTimeout, cleanEnv, nil, "halow-status", "json")
	if rc != 0 {
		return nil, fmt.Errorf("halow-status json: rc %d", rc)
	}
	return []byte(out), nil
}

const regdbPath = "/usr/share/morse-regdb/channels.csv" // the table halow-setkey and netifd use

// readSettings: settings.get's source (§3.3) — uci values, and the regdb for the bandwidth (read per refresh, not per
// request). uci prints nothing for a missing option: the cache then omits that key.
func readSettings() (node.Settings, error) {
	s := node.Settings{
		Hostname: uciGet("system.@system[0].hostname"),
		Country:  uciGet("wireless.radio1.country"),
		Channel:  uciGet("wireless.radio1.channel"),
		SSID:     uciGet("wireless.default_radio0.ssid"),
	}
	if b, err := os.ReadFile(regdbPath); err == nil {
		s.RegdbBW = node.RegdbLookup(string(b))
	}
	return s, nil
}

func p5Fresh() (bool, error) {
	rc, out := provstore.Exec(provstore.ConfigSaveTimeout, cleanEnv, nil, "batman-config-save", "--check")
	return parseCheck(rc, out)
}

// parseCheck: batman-config-save --check says "p5 fresh" (rc 0) or "p5 stale: …" (rc 5); anything else — lock busy
// (rc 8), a timeout, an error — is not an answer (the cache keeps what it had; status omits key 4 when that is old).
func parseCheck(rc int, out string) (bool, error) {
	switch {
	case rc == 0 && strings.Contains(out, "p5 fresh"):
		return true, nil
	case rc == 5 && strings.Contains(out, "p5 stale"):
		return false, nil
	}
	return false, errors.New("batman-config-save --check: no answer (rc " + fmt.Sprint(rc) + ")")
}

// p3NewPreserve: the PRESERVE keys P3 added (batman-config-save). A node upgraded to P3 has a p5 without them, so
// --check says stale and an OTA would be refused (254-p3-impl §3.3, F63).
var p3NewPreserve = map[string]bool{"wireless.default_radio0.ssid": true}

// onlyP3Stale: --check said "p5 stale: <keys>" (rc 5) and every key is one P3 added — the one case the helper saves by
// itself. Anything else stale (a real difference, unpersistable, .txn, identity) is left as it is.
func onlyP3Stale(rc int, out string) bool {
	if rc != 5 {
		return false
	}
	i := strings.Index(out, "p5 stale: ")
	if i < 0 {
		return false
	}
	keys := strings.TrimSpace(out[i+len("p5 stale: "):])
	// every item must be a P3 key: prose ("(unpersistable …)", "(.txn)") never is
	for _, k := range strings.Split(keys, ",") {
		if !p3NewPreserve[k] {
			return false
		}
	}
	return true
}

// uciStaged: packages with staged (uncommitted) uci changes — what makes a settings.set answer E_BUSY (design D-12)
func uciStaged() []string { return uciStagedIn("/tmp/.uci") }

// uciStagedIn: the save dir must be root's 0700 directory (not a symlink); anything else is not trusted and counts as
// staged (settings.set answers E_BUSY), never read — a decision input in a world-writable path is owner-checked (#280)
var uciOwner uint32 = 0 // root; tests use their own uid

func uciStagedIn(dir string) []string {
	fi, err := os.Lstat(dir)
	if err != nil {
		return nil
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !fi.IsDir() || fi.Mode().Perm() != 0o700 || !ok || st.Uid != uciOwner {
		return []string{"uci-savedir-untrusted"}
	}
	es, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range es {
		if fi, err := e.Info(); err == nil && fi.Mode().IsRegular() && fi.Size() > 0 {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// trialOrTxn: wait while the boot is a trial or a wireless change is unfinished (.txn) — upgradeSave skips both (A r2 m6)
func trialOrTxn(trial, txn func() bool) func() bool { return func() bool { return trial() || txn() } }

// saveAfterCommit (design D-9): wait while the boot is a trial (every `every`), then save once; stop ends the wait
func saveAfterCommit(isTrial func() bool, stop <-chan struct{}, every time.Duration, save func()) {
	for isTrial() {
		select {
		case <-stop:
			return
		case <-time.After(every):
		}
	}
	save()
}

// upgradeSave runs once at the daemon start of a committed boot without an unfinished change: when p5 is stale only
// in keys P3 added, --save once (a joined node's joinwatch would save on its next tick; an unjoined one never would).
func upgradeSave(p provstore.Paths, trial bool) {
	if trial || provstore.TxnPresent(p) {
		return
	}
	rc, out := provstore.Exec(provstore.ConfigSaveTimeout, cleanEnv, nil, "batman-config-save", "--check")
	if !onlyP3Stale(rc, out) {
		return
	}
	rc, out = provstore.Exec(provstore.ConfigSaveTimeout, cleanEnv, nil, "batman-config-save", "--save")
	logf("p5 stale only in keys P3 added: --save rc %d (%s)", rc, strings.TrimSpace(out))
}
