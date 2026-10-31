package provstore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// review 2 (txntoken-no-len, readtxn-radio-lenient survivors): TxnToken returns only a 32-hex token (it goes into
// argv); ReadTxn refuses a radio line it does not know.
func TestTxnTokenAndRadioLine(t *testing.T) {
	d := t.TempDir()
	p := Paths{Dir: d}
	for tok, want := range map[string]bool{
		strings.Repeat("ab", 16):       true,
		strings.Repeat("ab", 15):       false, // 30 hex
		strings.Repeat("ab", 16) + "a": false, // 33
		strings.Repeat("zz", 16):       false, // not hex
		"-":                            false,
	} {
		os.WriteFile(filepath.Join(d, ".txn"), []byte(tok+" 1 2 network/join\nprev - - -\nradio disabled=0\n"), 0o600)
		if got := TxnToken(p) != ""; got != want {
			t.Fatalf("token %q: accepted=%v", tok, got)
		}
	}
	tok := strings.Repeat("ab", 16)
	for line, ok := range map[string]bool{"radio disabled=0": true, "radio disabled=1": true, "radio disabled=7": false, "radio x": false} {
		os.WriteFile(filepath.Join(d, ".txn"), []byte(tok+" 1 2 network/join\nprev - - -\n"+line+"\n"), 0o600)
		if _, got := ReadTxn(p); got != ok {
			t.Fatalf("radio line %q: ok=%v", line, got)
		}
	}
}
