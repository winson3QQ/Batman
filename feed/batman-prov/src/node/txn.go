package node

import (
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"batman-prov/provstore"
)

// commit persists a new record to p5 and then the overlay (no wireless side effect: claim, owners, ssh keys, leave).
func (n *Node) commit(next *provstore.Record, what string) *Error {
	return n.commitTxn(next, "")
}

// commitTxn = §4.4 steps 3–4: stage, --prov-only, on rc != 0 read the generation back to decide, then the overlay.
func (n *Node) commitTxn(next *provstore.Record, token string) *Error {
	stage := n.P.Stage()
	os.RemoveAll(stage)
	if err := os.MkdirAll(stage, 0o700); err != nil {
		return fail(EApply, "stage: %v", err)
	}
	defer os.RemoveAll(stage)
	sp := provstore.Paths{Dir: stage}
	if _, _, err := provstore.WriteOverlay(sp, next); err != nil {
		return fail(EApply, "stage: %v", err)
	}
	rc, out := n.Sys.Persist(sp.Record(), sp.Meta(), "", token)
	if rc != 0 {
		g, ok := n.p5Generation()
		if !ok || g != next.Generation {
			return fail(EStorage, "--prov-only rc=%d (%s); p5 generation %d", rc, strings.TrimSpace(out), g)
		}
		n.Log("--prov-only rc=%d but p5 holds generation %d: committed", rc, g)
	}
	if _, _, err := provstore.WriteOverlay(n.P, next); err != nil {
		// p5 is ahead now; the next --boot rebuilds the overlay from it (§4.4 step 7)
		n.Log("overlay write after a committed p5 write failed: %v", err)
	}
	return nil
}

func (n *Node) p5Generation() (uint64, bool) {
	d, err := os.MkdirTemp(n.P.RunDir, "provget.")
	if err != nil {
		return 0, false
	}
	os.Remove(d)
	defer os.RemoveAll(d)
	if rc, _ := n.Sys.GetP5(d); rc != 0 && rc != 13 {
		return 0, false
	}
	b, err := os.ReadFile(filepath.Join(d, "prov.meta"))
	if err != nil {
		return 0, false
	}
	m, err := provstore.ParseMeta(b)
	if err != nil {
		return 0, false
	}
	return m.Gen, true
}

// .txn (overlay, 0600 in the 0700 dir, fsync'd), two lines (§3, §4.4 step 1):
//
//	<token> <gen_from> <gen_to> <verb>
//	prev <hex mesh key> <hex mesh id> <channel>     — the wireless values to restore if the txn did not commit
//
// Read by --boot (§4.4 step 6); config-save's --on-join yields while it exists.
func writeTxn(p provstore.Paths, token string, from, to uint64, verb, prevKey, prevID, prevCh string) error {
	if err := os.MkdirAll(p.Dir, 0o700); err != nil {
		return err
	}
	tmp := p.Txn() + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	fmt.Fprintf(f, "%s %d %d %s\nprev %s %s %s\n", token, from, to, verb,
		hex.EncodeToString([]byte(prevKey)), hex.EncodeToString([]byte(prevID)), prevCh)
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

func removeTxn(p provstore.Paths) { os.Remove(p.Txn()) }

// Txn is a parsed .txn.
type Txn struct {
	Token           string
	From, To        uint64
	Verb            string
	PrevKey, PrevID string
	PrevChannel     string
}

// ReadTxn parses .txn; ok=false when absent or malformed.
func ReadTxn(p provstore.Paths) (Txn, bool) {
	b, err := os.ReadFile(p.Txn())
	if err != nil {
		return Txn{}, false
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 2 {
		return Txn{}, false
	}
	f, g := strings.Fields(lines[0]), strings.Fields(lines[1])
	if len(f) != 4 || len(g) != 4 || g[0] != "prev" {
		return Txn{}, false
	}
	a, e1 := strconv.ParseUint(f[1], 10, 64)
	c, e2 := strconv.ParseUint(f[2], 10, 64)
	k, e3 := hex.DecodeString(g[1])
	id, e4 := hex.DecodeString(g[2])
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
		return Txn{}, false
	}
	return Txn{Token: f[0], From: a, To: c, Verb: f[3], PrevKey: string(k), PrevID: string(id), PrevChannel: g[3]}, true
}
