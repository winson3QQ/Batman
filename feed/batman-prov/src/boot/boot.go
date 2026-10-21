// Package boot is `batman-provhelper --boot` (docs/design/254-stage1-impl.md §4.2 rc table, §4.4 steps 6–7;
// 254-p1-impl.md §4.8): reconcile the overlay copy of the provisioning record and identity with p5, generate an
// identity only on a provably new card, and record this boot's verdict in p6 prov-state.
//
// Order matters (254-p1-impl §4.8, review B-N5): the IDENTITY comparison comes before any generation comparison.
// When overlay and p5 both hold a complete identity and they differ, nothing is written anywhere — the verdict is
// unknown(identity-mismatch) and the node stays as it is (P-U6: frozen until the owner acts or the card is reflashed).
package boot

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"batman-prov/keystore"
	"batman-prov/provstore"
)

// Env is everything --boot touches; Default wires the node, tests inject fakes.
type Env struct {
	P        provstore.Paths
	GetP5    func(dir string) (int, string)
	Persist  func(record, meta, identity string) (int, string)
	Bypass   func() bool
	BootID   func() string
	MeshKey  func() string // live mesh key (for "claimed + placeholder"); "" if unknown
	Log      func(format string, a ...any)
	Generate func(dir string) error
	Sleep    func(time.Duration)
}

// Result is the outcome of one --boot run.
type Result struct {
	RC      int    // --prov-get rc that decided
	Verdict string // legacy|unclaimed|claimed|member|unknown(<why>)
	Action  string // what was done, for the log and the tests
}

const placeholder = "CHANGE-ME-NOW"

func identSum(dir string) ([]byte, bool) {
	if _, err := keystore.Load(dir); err != nil {
		return nil, false
	}
	b, err := os.ReadFile(filepath.Join(dir, "sha256"))
	return b, err == nil
}

// Run performs the reconciliation.
func Run(e Env) Result {
	res := run(e)
	e.Log("boot rc=%d verdict=%s action=%s", res.RC, res.Verdict, res.Action)
	writeProvState(e, res)
	return res
}

func run(e Env) Result {
	_ = os.RemoveAll(e.P.Stage()) // §4.4 step 7: a .stage/ left over is always discarded
	if e.Bypass() {
		return Result{RC: 3, Verdict: "unknown(bypass)", Action: "none (bypass boot: no generation, no persist)"}
	}
	ovSum, ovIdent := identSum(e.P.Identity())
	ovRec, _, ovErr := provstore.LoadOverlay(e.P)
	if ovErr != nil {
		e.Log("overlay record unusable: %v", ovErr)
		ovRec = nil
	}

	var dir string
	rc := 1
	for i := 0; i < 3; i++ {
		d, err := os.MkdirTemp(e.P.RunDir, "provget.")
		if err != nil {
			return Result{RC: 1, Verdict: "unknown(no-rundir)", Action: "none"}
		}
		os.Remove(d) // --prov-get creates it itself (refuses an existing path)
		rc, _ = e.GetP5(d)
		dir = d
		if rc != 1 && rc != 8 {
			break
		}
		os.RemoveAll(d)
		e.Sleep(time.Second)
	}
	defer os.RemoveAll(dir)

	p5Sum, p5Ident := identSum(filepath.Join(dir, "identity"))
	var p5Rec *provstore.Record
	if rb, err := os.ReadFile(filepath.Join(dir, "prov.cbor")); err == nil {
		p5Rec, _ = provstore.Decode(rb)
	}

	// 1) identity mismatch FIRST — before any generation comparison or write
	if ovIdent && p5Ident && !bytes.Equal(ovSum, p5Sum) {
		return Result{RC: rc, Verdict: "unknown(identity-mismatch)", Action: "none (frozen: overlay and p5 hold different identities)"}
	}

	persistAll := func(withIdentity bool) (int, string) {
		id := ""
		if withIdentity {
			id = e.P.Identity()
		}
		return e.Persist(e.P.Record(), e.P.Meta(), id)
	}
	restoreFromP5 := func() error {
		if !ovIdent {
			if err := copyDir(filepath.Join(dir, "identity"), e.P.Identity()); err != nil {
				return err
			}
		}
		if p5Rec != nil {
			_, _, err := provstore.WriteOverlay(e.P, p5Rec)
			return err
		}
		return nil
	}
	generate := func(state string) (Result, bool) {
		if err := os.MkdirAll(e.P.Dir, 0o700); err != nil {
			return Result{}, false
		}
		if err := e.Generate(e.P.Identity()); err != nil {
			e.Log("identity generation failed: %v", err)
			return Result{}, false
		}
		r := &provstore.Record{Generation: 1, State: state}
		if _, _, err := provstore.WriteOverlay(e.P, r); err != nil {
			return Result{}, false
		}
		prc, _ := persistAll(true)
		return Result{RC: rc, Verdict: state, Action: fmt.Sprintf("generated identity, %s, persist rc=%d", state, prc)}, true
	}

	switch rc {
	case 0: // p5 has a complete prov + identity
		if p5Rec == nil {
			return Result{RC: rc, Verdict: "unknown(prov-corrupt)", Action: "none (p5 record does not match the schema)"}
		}
		if !ovIdent {
			if err := restoreFromP5(); err != nil {
				return Result{RC: rc, Verdict: "unknown(restore-failed)", Action: err.Error()}
			}
			return Result{RC: rc, Verdict: p5Rec.State, Action: "restored identity + record from p5"}
		}
		switch {
		case ovRec == nil || p5Rec.Generation > ovRec.Generation:
			if _, _, err := provstore.WriteOverlay(e.P, p5Rec); err != nil {
				return Result{RC: rc, Verdict: "unknown(restore-failed)", Action: err.Error()}
			}
			return Result{RC: rc, Verdict: p5Rec.State, Action: "p5 newer: rebuilt the overlay record"}
		case ovRec.Generation > p5Rec.Generation:
			prc, _ := persistAll(false)
			e.Log("p5 lost a committed prov write (overlay gen %d > p5 gen %d)", ovRec.Generation, p5Rec.Generation)
			return Result{RC: rc, Verdict: ovRec.State, Action: fmt.Sprintf("overlay newer: re-persisted, rc=%d", prc)}
		}
		return Result{RC: rc, Verdict: ovRec.State, Action: "in sync"}
	case 7: // ext4, unseeded, no prov: a new / reflashed card
		if ovIdent {
			if ovRec == nil {
				r := &provstore.Record{Generation: 1, State: provstore.Unclaimed}
				provstore.WriteOverlay(e.P, r)
				ovRec = r
			}
			prc, _ := persistAll(true)
			return Result{RC: rc, Verdict: ovRec.State, Action: fmt.Sprintf("persisted the overlay identity, rc=%d", prc)}
		}
		if p5Ident { // p5 has an identity but no record: restore it, never generate a second one
			copyDir(filepath.Join(dir, "identity"), e.P.Identity())
			r := &provstore.Record{Generation: 1, State: provstore.Unclaimed}
			provstore.WriteOverlay(e.P, r)
			prc, _ := persistAll(false)
			return Result{RC: rc, Verdict: provstore.Unclaimed, Action: fmt.Sprintf("restored p5 identity, record persisted rc=%d", prc)}
		}
		if r, ok := generate(provstore.Unclaimed); ok {
			return r
		}
		return Result{RC: rc, Verdict: "unknown(generate-failed)", Action: "none"}
	case 9: // seeded, no prov: legacy upgrade (or an operator --seed wiped prov)
		if ovIdent && ovRec != nil {
			prc, _ := persistAll(true)
			return Result{RC: rc, Verdict: ovRec.State, Action: fmt.Sprintf("re-persisted the whole overlay record, rc=%d", prc)}
		}
		if ovIdent {
			r := &provstore.Record{Generation: 1, State: provstore.Legacy}
			provstore.WriteOverlay(e.P, r)
			prc, _ := persistAll(true)
			return Result{RC: rc, Verdict: provstore.Legacy, Action: fmt.Sprintf("persisted identity, legacy, rc=%d", prc)}
		}
		if p5Ident {
			copyDir(filepath.Join(dir, "identity"), e.P.Identity())
			r := &provstore.Record{Generation: 1, State: provstore.Legacy}
			provstore.WriteOverlay(e.P, r)
			prc, _ := persistAll(false)
			return Result{RC: rc, Verdict: provstore.Legacy, Action: fmt.Sprintf("restored p5 identity, legacy record persisted rc=%d", prc)}
		}
		if r, ok := generate(provstore.Legacy); ok {
			return r
		}
		return Result{RC: rc, Verdict: "unknown(generate-failed)", Action: "none"}
	case 10: // p5 prov incomplete / sha mismatch / meta missing
		if ovIdent && ovRec != nil {
			prc, _ := persistAll(true)
			return Result{RC: rc, Verdict: ovRec.State, Action: fmt.Sprintf("p5 record corrupt: re-persisted the overlay one, rc=%d", prc)}
		}
		return Result{RC: rc, Verdict: "unknown(prov-corrupt)", Action: "none (no generation)"}
	case 13: // p5 has prov but identity/prov is missing / incomplete
		if ovIdent {
			prc, _ := persistAll(true)
			st := "unknown(identity-lost)"
			if ovRec != nil {
				st = ovRec.State
			} else if p5Rec != nil {
				st = p5Rec.State
			}
			return Result{RC: rc, Verdict: st, Action: fmt.Sprintf("re-persisted the identity, rc=%d", prc)}
		}
		return Result{RC: rc, Verdict: "unknown(identity-lost)", Action: "none (no generation)"}
	case 1, 8:
		if ovRec != nil && ovIdent {
			return Result{RC: rc, Verdict: ovRec.State, Action: "p5 unreadable: kept the overlay (persist will fail E_PERSIST)"}
		}
		return Result{RC: rc, Verdict: "unknown(p5-unreadable)", Action: "none"}
	case 3:
		return Result{RC: rc, Verdict: "unknown(bypass)", Action: "none"}
	case 11:
		return Result{RC: rc, Verdict: "unknown(no-p5)", Action: "none"}
	case 12:
		return Result{RC: rc, Verdict: "unknown(p5-not-ext4)", Action: "none"}
	case 14:
		return Result{RC: rc, Verdict: "unknown(too-new)", Action: "none"}
	}
	return Result{RC: rc, Verdict: fmt.Sprintf("unknown(rc-%d)", rc), Action: "none"}
}

// writeProvState: "<boot_id> helper <last_known_state> <verdict> <members_n> <mesh_expect>" (§3). last_known_state
// changes only on a definite record; an unknown verdict keeps the previous one (96 reads it to decide the lock).
func writeProvState(e Env, res Result) {
	if e.P.State == "" {
		return
	}
	if fi, err := os.Stat(e.P.State); err != nil || !fi.IsDir() {
		return
	}
	path := filepath.Join(e.P.State, "prov-state")
	prev := "-"
	if b, err := os.ReadFile(path); err == nil {
		if f := strings.Fields(string(b)); len(f) >= 3 {
			prev = f[2]
		}
	}
	lks := prev
	if provstore.ValidState(res.Verdict) {
		lks = res.Verdict
	}
	me := "today"
	switch res.Verdict {
	case provstore.Unclaimed:
		me = "0"
	case provstore.Member:
		me = "radio"
	case provstore.Claimed:
		if k := e.MeshKey(); k == "" || k == placeholder {
			me = "0"
		}
	}
	members := "-"
	line := fmt.Sprintf("%s helper %s %s %s %s\n", e.BootID(), lks, res.Verdict, members, me)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(line), 0o600); err == nil {
		os.Rename(tmp, path)
	}
}

func copyDir(src, dst string) error {
	if _, err := os.Lstat(dst); err == nil {
		return errors.New("boot: identity destination exists")
	}
	tmp := dst + ".tmp"
	os.RemoveAll(tmp)
	if err := os.MkdirAll(tmp, 0o700); err != nil {
		return err
	}
	ents, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, en := range ents {
		fi, err := os.Lstat(filepath.Join(src, en.Name()))
		if err != nil || !fi.Mode().IsRegular() {
			return errors.New("boot: identity file not regular")
		}
		b, err := os.ReadFile(filepath.Join(src, en.Name()))
		if err != nil {
			return err
		}
		mode := os.FileMode(0o600)
		if en.Name() == "node.cert" {
			mode = 0o644
		}
		if err := os.WriteFile(filepath.Join(tmp, en.Name()), b, mode); err != nil {
			return err
		}
	}
	if _, err := keystore.Load(tmp); err != nil {
		os.RemoveAll(tmp)
		return fmt.Errorf("boot: copied identity does not load: %w", err)
	}
	return os.Rename(tmp, dst)
}
