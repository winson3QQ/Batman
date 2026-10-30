package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"batman-prov/node"
)

// review 2 (A/B: realSys untested; cmd-layer mutants survived): the real Sys against stub `uci` / `halow-setkey`
// on PATH. The stub uci serves a fixture of `uci show wireless` / `uci -q get` like the real one.
func stubs(t *testing.T, show string, setkeyRC string) string {
	t.Helper()
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "show"), []byte(show), 0o600)
	uci := `#!/bin/sh
[ "$1" = -q ] && shift
case "$1" in
show) cat "` + d + `/show" ;;
get) v=$(sed -n "s/^$2='\(.*\)'$/\1/p" "` + d + `/show"); [ -n "$v" ] || exit 1; printf '%s\n' "$v" ;;
esac
`
	os.WriteFile(filepath.Join(d, "uci"), []byte(uci), 0o755)
	sk := "#!/bin/sh\ncat > " + d + "/stdin\necho \"$@\" > " + d + "/args\necho \"stub says no\"\nexit " + setkeyRC + "\n"
	os.WriteFile(filepath.Join(d, "halow-setkey"), []byte(sk), 0o755)
	old := cleanEnv
	cleanEnv = []string{"PATH=" + d + ":/usr/bin:/bin", "LANG=C"}
	t.Setenv("PATH", d+":"+os.Getenv("PATH")) // exec.Command resolves the name with the process's PATH
	t.Cleanup(func() { cleanEnv = old })
	return d
}

const twoMesh = `wireless.radio0=wifi-device
wireless.radio0.type='mac80211'
wireless.default_radio0=wifi-iface
wireless.default_radio0.device='radio0'
wireless.default_radio0.mode='mesh'
wireless.default_radio0.key='brcm-key-1'
wireless.default_radio0.encryption='sae'
wireless.radio1=wifi-device
wireless.radio1.type='morse'
wireless.radio1.channel='28'
wireless.radio1.disabled='1'
wireless.default_radio1=wifi-iface
wireless.default_radio1.device='radio1'
wireless.default_radio1.mode='mesh'
wireless.default_radio1.mesh_id='halow-mesh'
wireless.default_radio1.key=' spaced key '
wireless.default_radio1.encryption='sae'
`

func TestRealSysPicksTheMorseRadio(t *testing.T) {
	stubs(t, twoMesh, "0")
	if i := meshIface(); i != "default_radio1" {
		t.Fatalf("meshIface = %q (want the morse radio's mesh iface, not radio0's)", i)
	}
	k, id, ch, err := realSys{}.CurrentWireless()
	if err != nil || k != " spaced key " || id != "halow-mesh" || ch != "28" {
		t.Fatalf("CurrentWireless = %q %q %q %v (the key must keep its blanks)", k, id, ch, err)
	}
}

func TestRealSysCheckRestorable(t *testing.T) {
	d := stubs(t, twoMesh, "2")
	err := realSys{}.CheckRestorable("op&erator1", "halow-mesh", "28")
	var rr *node.RestoreRefused
	if !errors.As(err, &rr) {
		t.Fatalf("setkey --check-only rc 2: %v (want RestoreRefused)", err)
	}
	if b, _ := os.ReadFile(filepath.Join(d, "stdin")); string(b) != "op&erator1\n" {
		t.Fatalf("the key did not go over stdin: %q", b)
	}
	if a, _ := os.ReadFile(filepath.Join(d, "args")); strings.Contains(string(a), "op&erator1") || !strings.Contains(string(a), "--check-only") {
		t.Fatalf("argv %q (the key must never be in argv)", a)
	}
	stubs(t, twoMesh, "124")
	if err := (realSys{}).CheckRestorable("operator-key", "halow-mesh", "28"); err == nil || errors.As(err, &rr) {
		t.Fatalf("rc 124: %v (want a transient, plain error)", err)
	}
	stubs(t, strings.Replace(twoMesh, "default_radio1.encryption='sae'", "default_radio1.encryption='psk2'", 1), "0")
	if err := (realSys{}).CheckRestorable("operator-key", "halow-mesh", "28"); !errors.As(err, &rr) {
		t.Fatalf("psk2: %v (want RestoreRefused)", err)
	}
	stubs(t, twoMesh, "0")
	if err := (realSys{}).CheckRestorable("", "halow-mesh", "28"); !errors.As(err, &rr) {
		t.Fatalf("empty key: %v (want RestoreRefused)", err)
	}
	if err := (realSys{}).CheckRestorable("operator-key", "halow-mesh", "28"); err != nil {
		t.Fatalf("accepted value: %v", err)
	}
}

func TestRealSysRadioStateFirstLineOnly(t *testing.T) {
	stubs(t, twoMesh, "0")
	m := filepath.Join(t.TempDir(), "mark")
	old := keyguardMark
	keyguardMark = m
	t.Cleanup(func() { keyguardMark = old })
	os.WriteFile(m, []byte("default_radio0\nradio1\n"), 0o600)
	dis, in, err := realSys{}.RadioState()
	if err != nil || !dis || in {
		t.Fatalf("dis=%v in=%v err=%v (radio1 only on line 2: not in the mark)", dis, in, err)
	}
	os.WriteFile(m, []byte(" radio1\n"), 0o600)
	if _, in, _ = (realSys{}).RadioState(); !in {
		t.Fatal("radio1 on the first line: in the mark")
	}
}

// review 3 A m1 / B m1: uci itself failing is transient (Finish keeps .txn), not "cannot be restored" (forget)
func TestRealSysUciFailureIsTransient(t *testing.T) {
	d := stubs(t, twoMesh, "0")
	os.WriteFile(filepath.Join(d, "uci"), []byte("#!/bin/sh\nexit 124\n"), 0o755)
	err := realSys{}.CheckRestorable("operator-key", "halow-mesh", "28")
	var rr *node.RestoreRefused
	if err == nil || errors.As(err, &rr) {
		t.Fatalf("uci rc 124: %v (want a transient, plain error)", err)
	}
}
