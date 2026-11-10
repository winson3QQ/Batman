package node

import (
	"crypto/ecdsa"
	"testing"

	"batman-prov/cbor"
	"batman-prov/provstore"
)

// docs/design/254-net-update-members.md §6: network/update in the CDDL shape (219-protocol.cddl update-step), the
// net_secrets version binding (§2.2-5, the round-1 BLOCKER), net_id per step, the country (D9), member_list per step.

// v2Of / v3Of: the next versions of v1 with the same admin (overrides via mod)
func (r *rig) next(prev *netv, ver uint64, mod func(v *netv)) *netv {
	v := &netv{nid: prev.nid, ver: ver, meshID: "m" + string(rune('0'+ver)), ch: 36, sae: "sae-v" + string(rune('0'+ver)) + "-pass",
		admins: prev.admins, signer: prev.admins[0], prev: prev.cfg}
	if mod != nil {
		mod(v)
	}
	return r.mkNet(v)
}

// nuState: what a refusal must leave untouched (the record, .txn, setkey calls, saves)
type nuState struct {
	gen     uint64
	state   string
	version uint64
	txn     bool
	setkeys int
	saves   int
}

func (r *rig) nuSnap() nuState {
	rec, _, err := provstore.LoadOverlay(r.n.P)
	if err != nil {
		r.t.Fatalf("overlay: %v", err)
	}
	var v uint64
	if rec.Net != nil {
		v = rec.Net.Version
	}
	return nuState{rec.Generation, rec.State, v, provstore.TxnPresent(r.n.P), len(r.sys.setkeys), len(r.sys.saveTxns)}
}

// refused: code want, and nothing changed (record, .txn, setkey, wireless)
func (r *rig) refused(t *testing.T, what string, got, want int, before nuState, wl string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: code %d, want %d", what, got, want)
	}
	if after := r.nuSnap(); after != before {
		t.Fatalf("%s: state changed on a refusal: %+v -> %+v", what, before, after)
	}
	if r.wl() != wl {
		t.Fatalf("%s: wireless %s, want %s", what, r.wl(), wl)
	}
}

func otherNid() []byte { return make32(7)[:16] }

// U1 / U2: one step and a two-step chain apply; the record follows the last version
func TestUpdateCDDLShape(t *testing.T) {
	r, v1 := memberRig(t)
	v2 := r.next(v1, 2, nil)
	if c := r.applyUpdate(v2); c != OK {
		t.Fatalf("one step: %d", c)
	}
	if rec := r.rec(); rec.Net.Version != 2 || r.wl() != "sae-v2-pass/m2/36" {
		t.Fatalf("after v2: version %d wl %s", rec.Net.Version, r.wl())
	}
	v3 := r.next(v2, 3, nil)
	v4 := r.next(v3, 4, nil)
	if c := r.applyUpdate(v3, v4); c != OK {
		t.Fatalf("two steps: %d", c)
	}
	if rec := r.rec(); rec.Net.Version != 4 || r.wl() != "sae-v4-pass/m4/36" || rec.Members != nil {
		t.Fatalf("after v3+v4: version %d wl %s members %v", rec.Net.Version, r.wl(), rec.Members != nil)
	}
}

// U11 / U12: a new net_config with this node's OLDER secrets (the reviewers' PoC: before the fix code 0, the node kept
// the old SAE the removed member knows and reported the new version), with another network's secrets, and a join
// whose secrets are of another version — all refused, nothing changed
func TestUpdateSecretsBoundToVersion(t *testing.T) {
	r, v1 := memberRig(t)
	v2 := r.next(v1, 2, nil)
	b := r.nuSnap()
	c := r.applyUpdateBody(cbor.M(1, []any{cbor.M(1, v2.cfg, 2, v2.members, 3, v1.secrets)}))
	r.refused(t, "v2 cfg + v1 secrets", c, EBadObject, b, "sae-v1-pass/m1/28")

	v2s := r.next(v1, 2, func(v *netv) { v.secVer = 1 })
	r.refused(t, "v2 cfg + secrets of version 1", r.applyUpdate(v2s), EBadObject, b, "sae-v1-pass/m1/28")
	v2n := r.next(v1, 2, func(v *netv) { v.secNid = otherNid() })
	r.refused(t, "secrets of another network", r.applyUpdate(v2n), EBadObject, b, "sae-v1-pass/m1/28")

	j := claimedRig(t)
	a := newKey()
	bad := j.mkNet(&netv{nid: make32(4)[:16], ver: 1, meshID: "m1", ch: 28, sae: "sae-v1-pass", admins: []*ecdsa.PrivateKey{a}, signer: a, secVer: 2})
	jb := j.nuSnap()
	if c := j.applyJoin(bad); c != EBadObject {
		t.Fatalf("join with version-2 secrets: %d", c)
	}
	if j.nuSnap() != jb {
		t.Fatal("join refusal changed state")
	}
}

// U4: net_id per step (the secrets match their own net_config, so only the net_id check can refuse — §6 construction),
// members version / net_id, in the only step and in the middle step of a chain
func TestUpdateNetIDAndMembers(t *testing.T) {
	r, v1 := memberRig(t)
	b := r.nuSnap()
	wl := "sae-v1-pass/m1/28"
	cases := []struct {
		name string
		mod  func(v *netv)
	}{
		{"net_config net_id", func(v *netv) { v.nid, v.memNid = otherNid(), v1.nid }},
		{"members version", func(v *netv) { v.memVer = 9 }},
		{"members net_id", func(v *netv) { v.memNid = otherNid() }},
		{"members by a non-admin", func(v *netv) { v.memSigner = newKey() }},
	}
	for _, tc := range cases {
		bad := r.next(v1, 2, tc.mod)
		r.refused(t, tc.name+" (only step)", r.applyUpdate(bad), EBadObject, b, wl)
		good3 := r.next(bad, 3, func(v *netv) { v.nid = v1.nid })
		r.refused(t, tc.name+" (first of two steps)", r.applyUpdate(bad, good3), EBadObject, b, wl)
		good2 := r.next(v1, 2, nil)
		bad3 := r.next(good2, 3, func(v *netv) {
			tc.mod(v)
			if v.memNid != nil && v.nid[0] != v1.nid[0] { // the net_id case: keep the members on the stored network
				v.memNid = v1.nid
			}
		})
		r.refused(t, tc.name+" (second of two steps)", r.applyUpdate(good2, bad3), EBadObject, b, wl)
	}
	// members of an OLDER version (v1's own list) carried in step v2 (review A R08)
	v2 := r.next(v1, 2, nil)
	r.refused(t, "v1 members in step v2", r.applyUpdateBody(cbor.M(1, []any{cbor.M(1, v2.cfg, 2, v1.members, 3, v2.secrets)})), EBadObject, b, wl)
}

// a handover INSIDE one request (review A R11): v2 hands the network to nb (signed by v1's admin), v3 is signed by nb
// with its members by nb -> applies; members always checked with the stored admins would refuse v3
func TestUpdateHandoverInsideOneRequest(t *testing.T) {
	r, v1 := memberRig(t)
	nb := newKey()
	v2 := r.mkNet(&netv{nid: v1.nid, ver: 2, meshID: "m2", ch: 36, sae: "sae-v2-pass", admins: []*ecdsa.PrivateKey{nb},
		signer: v1.admins[0], prev: v1.cfg})
	v3 := r.mkNet(&netv{nid: v1.nid, ver: 3, meshID: "m3", ch: 28, sae: "sae-v3-pass", admins: []*ecdsa.PrivateKey{nb},
		signer: nb, prev: v2.cfg})
	if c := r.applyUpdate(v2, v3); c != OK {
		t.Fatalf("v2 (handover) + v3 in one request: %d", c)
	}
	if r.wl() != "sae-v3-pass/m3/28" {
		t.Fatalf("wl %s", r.wl())
	}
}

// U4b: the handover step's member_list is checked with the PREVIOUS version's admins (§7.1), not the new ones
func TestUpdateHandoverMembersByPreviousAdmins(t *testing.T) {
	r, v1 := memberRig(t)
	nb := newKey()
	b := r.nuSnap()
	byNew := r.mkNet(&netv{nid: v1.nid, ver: 2, meshID: "m2", ch: 36, sae: "sae-v2-pass", admins: []*ecdsa.PrivateKey{nb},
		signer: v1.admins[0], prev: v1.cfg, memSigner: nb})
	r.refused(t, "handover members by the new admin", r.applyUpdate(byNew), EBadObject, b, "sae-v1-pass/m1/28")
	byPrev := r.mkNet(&netv{nid: v1.nid, ver: 2, meshID: "m2", ch: 36, sae: "sae-v2-pass", admins: []*ecdsa.PrivateKey{nb},
		signer: v1.admins[0], prev: v1.cfg})
	if c := r.applyUpdate(byPrev); c != OK {
		t.Fatalf("handover members by the previous admin: %d", c)
	}
}

// U5: shapes — every wrong shape is E_BAD_OBJECT (not ESchema: no CRIT, no E_REJECTED{} clash)
func TestUpdateShape(t *testing.T) {
	r, v1 := memberRig(t)
	v2 := r.next(v1, 2, nil)
	v3 := r.next(v2, 3, nil)
	b := r.nuSnap()
	wl := "sae-v1-pass/m1/28"
	for name, body := range map[string]cbor.Map{
		"secrets in a non-last step": cbor.M(1, []any{step(v2, true), step(v3, true)}),
		"no secrets in the last":     cbor.M(1, []any{step(v2, false)}),
		"no members":                 cbor.M(1, []any{cbor.M(1, v2.cfg, 3, v2.secrets)}),
		"no net_config":              cbor.M(1, []any{cbor.M(2, v2.members, 3, v2.secrets)}),
		"old shape":                  cbor.M(1, []any{v2.cfg}, 2, v2.secrets),
		"chain not an array":         cbor.M(1, "x"),
		"empty chain":                cbor.M(1, []any{}),
		"no chain":                   cbor.M(),
	} {
		r.refused(t, name, r.applyUpdateBody(body), EBadObject, b, wl)
		if _, e := r.n.netUpdate(r.rec(), body); e == nil || e.Reason != "update shape" {
			t.Fatalf("%s: refused by %v, want the shape check (\"update shape\")", name, e)
		}
	}
}

// U7: the country (D9) — a different one in the only step or in the middle step, a missing one, a stored config without
// one: E_REJECTED reason 14, nothing written
func TestUpdateCountry(t *testing.T) {
	r, v1 := memberRig(t)
	b := r.nuSnap()
	wl := "sae-v1-pass/m1/28"
	reason := func(body cbor.Map) (int, uint64) {
		raw, _ := cbor.Encode(cbor.M(0, []any{uint64(1), uint64(0)}, 1, uint64(9), 2, "network/update", 3, body))
		c, rb := r.call("net.apply", cbor.M(1, r.h, 2, raw))
		return c, reasonOf(rb)
	}
	jp := r.next(v1, 2, func(v *netv) { v.cc = "JP" })
	if c, why := reason(cbor.M(1, []any{step(jp, true)})); c != EReject || why != ReasonCountryJoin {
		t.Fatalf("JP in the only step: %d reason %d", c, why)
	}
	us3 := r.next(jp, 3, nil)
	if c, why := reason(cbor.M(1, []any{step(jp, false), step(us3, true)})); c != EReject || why != ReasonCountryJoin {
		t.Fatalf("JP in the middle step: %d reason %d", c, why)
	}
	// the other country in the SECOND of two steps (code review R02: a check limited to step 0 survived)
	us2 := r.next(v1, 2, nil)
	jp3 := r.next(us2, 3, func(v *netv) { v.cc = "JP" })
	if c, why := reason(cbor.M(1, []any{step(us2, false), step(jp3, true)})); c != EReject || why != ReasonCountryJoin {
		t.Fatalf("JP in the second step: %d reason %d", c, why)
	}
	lower := r.next(v1, 2, func(v *netv) { v.cc = "us" })
	r.refused(t, "lower-case country", r.applyUpdate(lower), EReject, b, wl)
	none := r.next(v1, 2, func(v *netv) { v.noCC = true })
	r.refused(t, "no country", r.applyUpdate(none), EReject, b, wl)
	if c := r.applyUpdate(r.next(v1, 2, nil)); c != OK {
		t.Fatalf("same country: %d", c)
	}

	s := claimedRig(t)
	a := newKey()
	old := s.mkNet(&netv{nid: make32(4)[:16], ver: 1, meshID: "m1", ch: 28, sae: "sae-v1-pass", admins: []*ecdsa.PrivateKey{a}, signer: a, noCC: true})
	if c := s.applyJoin(old); c != OK {
		t.Fatalf("join without a country: %d", c)
	}
	sb := s.nuSnap()
	s.refused(t, "stored config without a country", s.applyUpdate(s.next(old, 2, nil)), EReject, sb, "sae-v1-pass/m1/28")
}

// U14: a resend after the update applied — E_STALE_VERSION; across an admin handover — E_BAD_OBJECT (F17, fixed
// behaviour the app must not read as "bad request"); nothing changed either way
func TestUpdateResend(t *testing.T) {
	r, v1 := memberRig(t)
	v2 := r.next(v1, 2, nil)
	if c := r.applyUpdate(v2); c != OK {
		t.Fatal(c)
	}
	b := r.nuSnap()
	r.refused(t, "resend v2", r.applyUpdate(v2), EStaleVersion, b, "sae-v2-pass/m2/36")
	nb := newKey()
	v3 := r.mkNet(&netv{nid: v1.nid, ver: 3, meshID: "m3", ch: 28, sae: "sae-v3-pass", admins: []*ecdsa.PrivateKey{nb}, signer: v2.admins[0], prev: v2.cfg})
	if c := r.applyUpdate(v3); c != OK {
		t.Fatal(c)
	}
	b = r.nuSnap()
	r.refused(t, "resend the handover version", r.applyUpdate(v3), EBadObject, b, "sae-v3-pass/m3/28")
}

// U17: no panic on any body (the helper has no recover(): a panic = the helper process ends, F22). Table of wrong
// types in every position, plus the fuzz seeds (go test -fuzz=FuzzNetUpdate for a longer run).
func malformedBodies(v1, v2 *netv) []cbor.Map {
	cfgPl := func(m cbor.Map) any {
		return cbor.Tag{Num: 18, V: []any{[]byte{0xa0}, cbor.Map{}, mustEnc(m), make([]byte, 64)}}
	}
	return []cbor.Map{
		cbor.M(1, []any{nil}),
		cbor.M(1, []any{cbor.M(1, nil, 2, nil, 3, nil)}),
		cbor.M(1, []any{cbor.M(1, uint64(1), 2, "x", 3, []any{})}),
		cbor.M(1, []any{cbor.M(1, v2.cfg, 2, uint64(5), 3, v2.secrets)}),
		cbor.M(1, []any{cbor.M(1, v2.cfg, 2, v2.members, 3, uint64(5))}),
		cbor.M(1, []any{cbor.M(1, v2.cfg, 2, v2.members, 3, cbor.Tag{Num: 18, V: "x"})}),
		cbor.M(1, []any{cbor.M(1, cbor.Tag{Num: 18, V: []any{}}, 2, v2.members, 3, v2.secrets)}),
		cbor.M(1, []any{cbor.M(1, cfgPl(cbor.M(1, uint64(3), 2, "v", 5, uint64(1))), 2, v2.members, 3, v2.secrets)}),
		cbor.M(1, []any{cbor.M(1, v2.cfg, 2, v1.cfg, 3, v2.secrets)}),
		cbor.M(1, []any{cbor.M(1, v2.cfg, 2, v2.secrets, 3, v2.members)}),
	}
}

func mustEnc(m cbor.Map) []byte { b, _ := cbor.Encode(m); return b }

func TestUpdateNoPanic(t *testing.T) {
	r, v1 := memberRig(t)
	v2 := r.next(v1, 2, nil)
	for i, body := range malformedBodies(v1, v2) {
		if _, e := r.n.netUpdate(r.rec(), body); e == nil {
			t.Fatalf("malformed body %d applied", i)
		}
	}
}

func FuzzNetUpdate(f *testing.F) {
	r, v1 := memberRig(&testing.T{})
	v2 := r.next(v1, 2, nil)
	v3 := r.next(v2, 3, nil)
	for _, b := range append(malformedBodies(v1, v2), cbor.M(1, []any{step(v2, false), step(v3, true)}),
		cbor.M(1, []any{cbor.M(1, v2.cfg, 2, v2.members, 3, v1.secrets)})) {
		f.Add(mustEnc(b))
	}
	rec := r.rec()
	f.Fuzz(func(t *testing.T, raw []byte) {
		x, err := cbor.Decode(raw)
		if err != nil {
			return
		}
		body, ok := x.(cbor.Map)
		if !ok {
			return
		}
		r.n.netUpdate(rec, body) // must return, never panic; a valid chain cannot be forged without the admin key
	})
}
