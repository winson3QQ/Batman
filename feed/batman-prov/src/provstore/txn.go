package provstore

import (
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// .txn (overlay, 0600 in the 0700 dir, fsync'd) = "a change of the mesh wireless is unfinished" (docs/design/
// 254-wireless-txn.md §3). Its PRESENCE is what matters: batman-config-save refuses saves while it exists and the
// helper finishes the change (Finish) before anything else. Content:
//
//	<token> <gen_from> <gen_to> <verb>                 — the generations are informational only (never used to decide)
//	prev <hex mesh key|-> <hex mesh id|-> <channel|->   — the live wireless before the change (the snapshot, §2)
//	radio disabled=<0|1>                                — the morse radio's uci `disabled` then (checked / logged only)
//
// An empty field is written "-" (a shipped writer left it out, which made the file unreadable — review v1 A-M4 / B-M1).
// A shipped two-line file (no radio line) still reads.
func WriteTxn(p Paths, token string, from, to uint64, verb, prevKey, prevID, prevCh string, prevDisabled bool) error {
	if err := os.MkdirAll(p.Dir, 0o700); err != nil {
		return err
	}
	tmp := p.Txn() + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	dis := 0
	if prevDisabled {
		dis = 1
	}
	fmt.Fprintf(f, "%s %d %d %s\nprev %s %s %s\nradio disabled=%d\n", token, from, to, verb,
		dashHex(prevKey), dashHex(prevID), dash(prevCh), dis)
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	f.Close()
	if err := os.Rename(tmp, p.Txn()); err != nil {
		return err
	}
	d, err := os.Open(p.Dir)
	if err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func dashHex(s string) string {
	if s == "" {
		return "-"
	}
	return hex.EncodeToString([]byte(s))
}

func undashHex(s string) (string, error) {
	if s == "-" {
		return "", nil
	}
	b, err := hex.DecodeString(s)
	return string(b), err
}

// RemoveTxn removes .txn durably (the directory fsync'd, as WriteTxn does; 254-wireless-txn §15.6, review B m6): a
// sysrq right after must not bring it back.
func RemoveTxn(p Paths) {
	if err := os.Remove(p.Txn()); err != nil {
		return
	}
	if d, err := os.Open(p.Dir); err == nil {
		d.Sync()
		d.Close()
	}
}

// TxnPresent: a .txn exists (readable or not) — the only thing that decides "a change is unfinished".
func TxnPresent(p Paths) bool {
	_, err := os.Lstat(p.Txn())
	return err == nil
}

// Txn is a parsed .txn.
type Txn struct {
	Token           string
	From, To        uint64
	Verb            string
	PrevKey, PrevID string
	PrevChannel     string
	PrevDisabled    bool
	HasRadio        bool // the radio line was present (a shipped file has none)
}

// ReadTxn parses .txn; ok=false when absent or unreadable (presence is TxnPresent's question).
func ReadTxn(p Paths) (Txn, bool) {
	b, err := os.ReadFile(p.Txn())
	if err != nil {
		return Txn{}, false
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 2 && len(lines) != 3 {
		return Txn{}, false
	}
	f, g := strings.Fields(lines[0]), strings.Fields(lines[1])
	if len(f) != 4 || len(g) != 4 || g[0] != "prev" {
		return Txn{}, false
	}
	a, e1 := strconv.ParseUint(f[1], 10, 64)
	c, e2 := strconv.ParseUint(f[2], 10, 64)
	k, e3 := undashHex(g[1])
	id, e4 := undashHex(g[2])
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
		return Txn{}, false
	}
	ch := g[3]
	if ch == "-" {
		ch = ""
	}
	t := Txn{Token: f[0], From: a, To: c, Verb: f[3], PrevKey: k, PrevID: id, PrevChannel: ch}
	if len(lines) == 3 {
		switch strings.TrimSpace(lines[2]) {
		case "radio disabled=0":
		case "radio disabled=1":
			t.PrevDisabled = true
		default:
			return Txn{}, false
		}
		t.HasRadio = true
	}
	return t, true
}

// TxnToken is .txn's token even when the rest of the file is unreadable (Finish needs it for the run-dir marker and
// ). Only a 32-hex token is returned: it ends up in a command's argv.
func TxnToken(p Paths) string {
	b, err := os.ReadFile(p.Txn())
	if err != nil {
		return ""
	}
	f := strings.Fields(strings.SplitN(string(b), "\n", 2)[0])
	if len(f) == 0 || len(f[0]) != 32 {
		return ""
	}
	if _, err := hex.DecodeString(f[0]); err != nil {
		return ""
	}
	return f[0]
}
