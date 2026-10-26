package node

import (
	"errors"
	"strings"
	"testing"

	"batman-prov/cbor"
	"batman-prov/proto"
	"batman-prov/provstore"
)

// docs/design/254-claim-lock-fix.md §5.3 / §11.2: the password is handed out only once p5 holds it; a failed lock
// or --save never leaves a never-delivered hash on the node.

const busy = "batman-config-save: another batman-config-save is writing p5 (pid 123) — try again"

func noPassword(t *testing.T, res interface{ Get(any) (any, bool) }) {
	t.Helper()
	if _, ok := res.Get(3); ok {
		t.Fatal("a password was handed out")
	}
}

func TestClaimLockFailure(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.lockErr = errors.New("LOCK uci rc=1")
	c, res := r.claim()
	if c != ELockIncomplete {
		t.Fatalf("code %d, want %d", c, ELockIncomplete)
	}
	noPassword(t, res)
	if r.sys.root != "!" || r.sys.saves < 1 || r.sys.lastKnown != string(provstore.Claimed) {
		t.Fatalf("root %q saves %d lastKnown %q", r.sys.root, r.sys.saves, r.sys.lastKnown)
	}
	if rec, _, _ := provstore.LoadOverlay(r.n.P); rec.State != provstore.Claimed {
		t.Fatalf("not committed: %s", rec.State)
	}
}

func TestClaimCryptFailure(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.cryptErr = errors.New("no entropy")
	c, res := r.claim()
	if c != ELockIncomplete || r.sys.locked != "" {
		t.Fatalf("code %d locked %q", c, r.sys.locked)
	}
	noPassword(t, res)
}

func TestClaimSaveBusyOnceThenOK(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.saveOut = []saveRC{{1, busy}}
	c, res := r.claim()
	if c != OK || r.sys.saves != 2 {
		t.Fatalf("code %d saves %d", c, r.sys.saves)
	}
	if pw, ok := res.Get(3); !ok || !strings.HasSuffix(r.sys.root, pw.(string)) {
		t.Fatal("password / root")
	}
}

func TestClaimSaveFailureRestoresRoot(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.saveOut = []saveRC{{1, busy}, {1, busy}} // the retry fails too; the best-effort save after the restore is 0
	c, res := r.claim()
	if c != ELockIncomplete {
		t.Fatalf("code %d", c)
	}
	noPassword(t, res)
	if len(r.sys.restored) != 1 || r.sys.restored[0] != "!" || r.sys.root != "!" {
		t.Fatalf("restore %v root %q (an empty root comes back as \"!\", never empty, never the new hash)", r.sys.restored, r.sys.root)
	}
	if r.sys.saves != 3 {
		t.Fatalf("saves %d, want 3 (save, retry, best-effort after the restore)", r.sys.saves)
	}
	if r.sys.marked {
		t.Fatal("marked LOCK-INCOMPLETE although the restore succeeded")
	}
}

func TestSetPasswordRestoresPreviousHash(t *testing.T) {
	r := newRig(t, provstore.Claimed)
	old := "$6$oldoldoldoldoldo$x"
	r.sys.root = old
	r.sys.saveOut = []saveRC{{6, "rejected"}} // not busy: no retry
	if e := r.n.setPassword("newpassword", EStorage); e == nil || e.Code != EStorage {
		t.Fatalf("got %v, want EStorage", e)
	}
	if r.sys.root != old || len(r.sys.restored) != 1 || r.sys.saves != 2 {
		t.Fatalf("root %q restored %v saves %d", r.sys.root, r.sys.restored, r.sys.saves)
	}
}

func TestSetPasswordRestoreFailureMarks(t *testing.T) {
	r := newRig(t, provstore.Claimed)
	r.sys.saveOut = []saveRC{{6, "x"}}
	r.sys.restoreErr = errors.New("LOCK shadow rc=3")
	if e := r.n.setPassword("pw", ELockIncomplete); e == nil || e.Code != ELockIncomplete {
		t.Fatalf("got %v", e)
	}
	if !r.sys.marked {
		t.Fatal("a failed restore must mark LOCK-INCOMPLETE")
	}
}

// a failure BEFORE the commit is not ELockIncomplete (the app must not take it for "committed")
func TestPreCommitFailureIsNotLockIncomplete(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.persistRC = 1
	c, _ := r.claim()
	if c == ELockIncomplete || c == OK {
		t.Fatalf("code %d", c)
	}
	if r.sys.lastKnown != "" {
		t.Fatal("last_known_state written before a commit")
	}
}

func TestGenPasswordUniform(t *testing.T) {
	counts := map[byte]int{}
	const n = 20000
	for i := 0; i < n; i++ {
		p := genPassword()
		if len(p) != 24 {
			t.Fatalf("length %d", len(p))
		}
		for j := 0; j < len(p); j++ {
			if !strings.ContainsRune(pwAlpha, rune(p[j])) {
				t.Fatalf("character %q outside the alphabet", p[j])
			}
			counts[p[j]]++
		}
	}
	if len(counts) != len(pwAlpha) {
		t.Fatalf("%d distinct characters, want %d", len(counts), len(pwAlpha))
	}
	exp := float64(n*24) / float64(len(pwAlpha))
	chi := 0.0
	for _, c := range counts {
		d := float64(c) - exp
		chi += d * d / exp
	}
	// 55 degrees of freedom: p = 0.001 at ~93.2. The old modulo version gives chi ~ 1000+ here.
	if chi > 93.2 {
		t.Fatalf("chi-square %.1f > 93.2: not uniform", chi)
	}
}

// ---- through the real dispatcher (code review B-M2 / A-m7): replay and reset share the failure semantics ----------

// replayEnv: ONE nonce gives both the CheckMac nonce and the owner-op's nonce_helper (claim.replay takes the newest
// unused node nonce for h, so r.envelope's own nonce call would break the CheckMac)
func (r *rig) replay() (int, interface{ Get(any) (any, bool) }) {
	nn, nh := r.nonce()
	body := cbor.M(1, r.claimResp(nn, pub(r.owner)))
	ah, _ := proto.ArgsHash(body)
	in, _ := proto.OwnerOpInput(r.h, nh, "claim/replay", ah)
	sig, _ := proto.SignES256(r.owner, in)
	b := append(cbor.Map(nil), body...)
	b = append(b, cbor.Entry{K: uint64(31), V: cbor.M(1, "claim/replay", 2, sig)})
	raw, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, uint64(9), 2, "claim/replay", 3, b))
	c, res := r.call("claim.replay", cbor.M(1, r.h, 2, raw))
	return c, res
}

func (r *rig) reset() (int, interface{ Get(any) (any, bool) }) {
	c, res := r.call("root_password.reset", cbor.M(1, r.h, 2, r.envelope("root_password/reset", cbor.M(), r.owner)))
	return c, res
}

func claimedRig(t *testing.T) *rig {
	r := newRig(t, provstore.Unclaimed)
	if c, _ := r.claim(); c != OK {
		t.Fatalf("claim %d", c)
	}
	return r
}

func TestReplayOK(t *testing.T) {
	r := claimedRig(t)
	before := r.sys.root
	c, res := r.replay()
	if c != OK {
		t.Fatalf("replay %d", c)
	}
	if pw, ok := res.Get(3); !ok || !strings.HasSuffix(r.sys.root, pw.(string)) || r.sys.root == before {
		t.Fatal("replay did not rotate the password")
	}
}

func TestReplayLockFailure(t *testing.T) {
	r := claimedRig(t)
	before := r.sys.root
	r.sys.lockErr = errors.New("LOCK dropbear rc=2")
	c, res := r.replay()
	if c != ELockIncomplete || r.sys.root != before {
		t.Fatalf("code %d root %q (want 23, root unchanged)", c, r.sys.root)
	}
	if _, ok := res.Get(3); ok {
		t.Fatal("password handed out")
	}
	if len(r.n.replayF) != 0 {
		t.Fatal("an authenticated replay that failed on storage counts against the 10/h limit")
	}
}

func TestReplaySaveFailureRestores(t *testing.T) {
	r := claimedRig(t)
	before := r.sys.root
	r.sys.saveOut = []saveRC{{6, "rejected"}}
	c, res := r.replay()
	if c != ELockIncomplete || r.sys.root != before || len(r.sys.restored) != 1 {
		t.Fatalf("code %d root %q restored %v", c, r.sys.root, r.sys.restored)
	}
	if _, ok := res.Get(3); ok {
		t.Fatal("password handed out")
	}
}

func TestResetLockFailure(t *testing.T) {
	r := claimedRig(t)
	before := r.sys.root
	saves := r.sys.saves
	r.sys.lockErr = errors.New("LOCK uci rc=1")
	c, res := r.reset()
	if c != ELockIncomplete || r.sys.root != before || r.sys.saves <= saves {
		t.Fatalf("code %d root %q saves %d->%d (want 23, root unchanged, --save still run)", c, r.sys.root, saves, r.sys.saves)
	}
	if _, ok := res.Get(1); ok {
		t.Fatal("password handed out")
	}
}

func TestResetSaveFailureIsEStorage(t *testing.T) {
	r := claimedRig(t)
	before := r.sys.root
	r.sys.saveOut = []saveRC{{1, busy}, {1, busy}}
	c, res := r.reset()
	if c != EStorage || r.sys.root != before || len(r.sys.restored) != 1 {
		t.Fatalf("code %d root %q restored %v (want 10, root restored)", c, r.sys.root, r.sys.restored)
	}
	if _, ok := res.Get(1); ok {
		t.Fatal("password handed out")
	}
}

func TestCryptFailureStillLocksDoors(t *testing.T) {
	r := newRig(t, provstore.Unclaimed)
	r.sys.cryptErr = errors.New("x")
	if c, _ := r.claim(); c != ELockIncomplete {
		t.Fatalf("code %d", c)
	}
	if len(r.sys.lockCalls) != 1 || r.sys.lockCalls[0] != "" || r.sys.root != "!" {
		t.Fatalf("lock calls %q root %q (want one hashless lock, root \"!\")", r.sys.lockCalls, r.sys.root)
	}
}
