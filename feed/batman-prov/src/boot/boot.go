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
	// Unfinished: a .txn is present (a wireless change did not finish). P5Read: p5 was read (--prov-get rc 0/7/9/13),
	// so the reconciled record is one p5 confirmed. The daemon runs Finish before serving only when both hold and the
	// verdict is known (254-wireless-txn §3, §4.3).
	Unfinished bool
	P5Read     bool
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
	res.Unfinished = provstore.TxnPresent(e.P)
	switch res.RC {
	case 0, 7, 9, 13:
		res.P5Read = true
	}
	if res.Unfinished {
		res.Action += "; a wireless change is unfinished (.txn): the helper finishes it"
	}
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

	// an unfinished wireless change (.txn) is NOT decided here (docs/design/254-wireless-txn.md §3): the record is
	// reconciled as on any boot and the helper's Finish makes the wireless the previous state of that record.

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
		// round-8 A-m10 / B-m1: re-persist only when p5's generation is KNOWN (its meta still parses) and not newer
		// than the overlay's — a rolled-back older slot must not replace a claimed record whose cbor went bad. An
		// unreadable generation is fail-closed: no write, the verdict freezes state-changing verbs (owner / reflash).
		// (The identity check above already ran: --prov-get rc 10 now copies p5's identity and raw meta.)
		if ovIdent && ovRec != nil {
			if g, ok := metaGen(dir); ok && g <= ovRec.Generation {
				prc, _ := persistAll(!p5Ident)
				return Result{RC: rc, Verdict: ovRec.State, Action: fmt.Sprintf("p5 record corrupt (p5 gen %d <= overlay %d): re-persisted the overlay one, rc=%d", g, ovRec.Generation, prc)}
			}
		}
		return Result{RC: rc, Verdict: "unknown(prov-corrupt)", Action: "none (p5 generation unknown or newer than the overlay: no write)"}
	case 13: // p5 has prov but identity/prov is missing / incomplete — re-persist ONLY the identity, and only when it is
		// provably the same node: overlay sn == the sn left on p5, and overlay gen >= p5 gen (round-6 B-M3). Never the
		// record: p5's (possibly claimed) record must not be replaced by an older / other slot's one.
		if ovIdent && ovRec != nil && p5Rec != nil && ovRec.Generation >= p5Rec.Generation {
			ovSN, _ := os.ReadFile(filepath.Join(e.P.Identity(), "sn"))
			p5SN, err := os.ReadFile(filepath.Join(dir, "identity", "sn"))
			if err == nil && len(ovSN) > 0 && bytes.Equal(bytes.TrimSpace(ovSN), bytes.TrimSpace(p5SN)) {
				prc, _ := e.Persist(e.P.Record(), e.P.Meta(), e.P.Identity())
				return Result{RC: rc, Verdict: ovRec.State, Action: fmt.Sprintf("re-persisted the identity (same sn, overlay gen %d >= p5 gen %d), rc=%d", ovRec.Generation, p5Rec.Generation, prc)}
			}
		}
		return Result{RC: rc, Verdict: "unknown(identity-lost)", Action: "none (cannot prove the overlay identity is p5's: no write)"}
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
	me := MeshExpect(res.Verdict, e.MeshKey)
	members := "-"
	line := fmt.Sprintf("%s helper %s %s %s %s\n", e.BootID(), lks, res.Verdict, members, me)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(line), 0o600); err == nil {
		os.Rename(tmp, path)
	}
}

// metaGen reads the generation from a --prov-get copy of p5's prov.meta; ok=false when absent or malformed.
func metaGen(dir string) (uint64, bool) {
	mb, err := os.ReadFile(filepath.Join(dir, "prov.meta"))
	if err != nil {
		return 0, false
	}
	m, err := provstore.ParseMeta(mb)
	if err != nil {
		return 0, false
	}
	return m.Gen, true
}

// PersistNow is batman-provhelper --persist-now (the P5_STALE_HINT fix, round-7 B-M3): write the overlay record to
// p5 when that is provably safe, and nothing else. Unlike Run it touches nothing the boot path owns (.stage, .txn,
// prov-state, the overlay record). It refuses — rc 1, or 7 while a net.apply transaction is open — when:
// a bypass boot; no complete overlay record + identity; an open .txn; p5 unreadable / not ext4 / too new;
// overlay and p5 hold different identities (frozen); p5's generation >= the overlay's (a generation is never
// lowered: a legacy slot cannot overwrite a claimed p5); rc 13 without the same sn on p5.
func PersistNow(e Env) (int, string) {
	if e.Bypass() {
		return 1, "bypass boot: no persist"
	}
	ovSum, ovIdent := identSum(e.P.Identity())
	ovRec, _, err := provstore.LoadOverlay(e.P)
	if err != nil || ovRec == nil || !ovIdent {
		return 1, fmt.Sprintf("no usable overlay record + identity (%v)", err)
	}
	if _, err := os.Lstat(e.P.Txn()); err == nil { // present at all, even malformed: fail-closed
		return 7, "a net.apply transaction is open: the helper resolves it at the next boot"
	}
	d, err := os.MkdirTemp(e.P.RunDir, "provget.")
	if err != nil {
		return 1, "no run dir"
	}
	os.Remove(d)
	rc, _ := e.GetP5(d)
	defer os.RemoveAll(d)
	switch rc {
	case 0, 7, 9, 10, 13:
	default:
		return 1, fmt.Sprintf("p5 cannot take the record (--prov-get rc %d)", rc)
	}
	p5Sum, p5Ident := identSum(filepath.Join(d, "identity"))
	if p5Ident && !bytes.Equal(ovSum, p5Sum) {
		return 1, "identity mismatch: frozen (owner action or reflash)"
	}
	g, haveG := metaGen(d)
	if haveG && g >= ovRec.Generation {
		if rc == 0 && g == ovRec.Generation {
			return 0, "in sync"
		}
		return 1, fmt.Sprintf("p5 generation %d >= overlay %d: never lowered", g, ovRec.Generation)
	}
	if rc == 10 && !haveG { // round-8 A-m10 / B-m1: a corrupt record of unknown generation could be newer
		return 1, "p5 record corrupt and its generation unreadable: no write (owner / reflash)"
	}
	if rc == 13 {
		ovSN, _ := os.ReadFile(filepath.Join(e.P.Identity(), "sn"))
		p5SN, err := os.ReadFile(filepath.Join(d, "identity", "sn"))
		if err != nil || len(ovSN) == 0 || !bytes.Equal(bytes.TrimSpace(ovSN), bytes.TrimSpace(p5SN)) {
			return 1, "p5 identity damaged and not provably this node's (sn): no write"
		}
	}
	id := ""
	if !p5Ident {
		id = e.P.Identity()
	}
	prc, out := e.Persist(e.P.Record(), e.P.Meta(), id)
	return prc, fmt.Sprintf("persisted gen %d (identity too: %v): %s", ovRec.Generation, id != "", out)
}

// MeshExpect is the one mesh_expect rule for every prov-state writer (helper boot, --apply-state --firstboot, and the
// 99zz shell fallback, which mirrors it): unclaimed -> 0; member -> radio; claimed -> 0 ONLY when the live mesh key
// is the placeholder; an empty or unreadable key is NOT proof of "nothing to join" (a broken wireless config on a fleet
// node must not let it commit without neighbours: fail-closed, round-7 A-M7) -> today; anything else -> today.
func MeshExpect(verdict string, meshKey func() string) string {
	switch verdict {
	case provstore.Unclaimed:
		return "0"
	case provstore.Member:
		return "radio"
	case provstore.Claimed:
		if meshKey() == placeholder {
			return "0"
		}
	}
	return "today"
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
