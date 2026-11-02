package cose

import (
	"bytes"
	"testing"

	"batman-prov/cbor"
	"batman-prov/proto"
)

// docs/design/254-wireless-txn.md §2: the stored network objects are decoded without re-verifying their signature —
// after an admin handover they are signed by admins that are no longer in the record's admin set.
func TestSign1PayloadStoredObject(t *testing.T) {
	v := vec(t)
	vc := v["version_chain"]
	v1 := dec(t, h(t, v["cose"]["net_config"].(map[string]any)["sign1"]))
	s1, err := VerifySign1(v1, CTNetcfg, proto.LabelNetcfg, [][]byte{h(t, v["keys"]["admin_pub"])})
	if err != nil {
		t.Fatal(err)
	}
	admins := func(s *Sign1) [][]byte {
		var out [][]byte
		for _, e := range s.Payload {
			if e.K == uint64(8) {
				for _, a := range e.V.([]any) {
					out = append(out, a.([]byte))
				}
			}
		}
		return out
	}
	s2, err := VerifySign1(dec(t, h(t, vc["v2"])), CTNetcfg, proto.LabelNetcfg, admins(s1))
	if err != nil {
		t.Fatal(err)
	}
	v3 := dec(t, h(t, vc["v3"]))
	good, err := VerifySign1(v3, CTNetcfg, proto.LabelNetcfg, admins(s2))
	if err != nil {
		t.Fatal(err)
	}
	// the stored v3 re-verified against an admin set that did not sign it fails (the handover case) ...
	if _, err := VerifySign1(v3, CTNetcfg, proto.LabelNetcfg, admins(s1)); err == nil {
		t.Fatal("precondition: v3 verified against v1's admins")
	}
	// ... while Sign1Payload returns the same payload and OBJECT_HASH
	p, err := Sign1Payload(v3, CTNetcfg, proto.LabelNetcfg)
	if err != nil {
		t.Fatal(err)
	}
	pb, _ := cbor.Encode(p.Payload)
	gb, _ := cbor.Encode(good.Payload)
	if !bytes.Equal(pb, gb) || !bytes.Equal(p.ObjectHash, good.ObjectHash) || p.SignerPub != nil {
		t.Fatal("Sign1Payload differs from the verified object")
	}
	// the structure checks stay: another content type or label is refused
	if _, err := Sign1Payload(v3, CTMembers, proto.LabelNetcfg); err == nil {
		t.Fatal("accepted under another content type")
	}
	if _, err := Sign1Payload(cbor.Tag{Num: 17, V: v3.(cbor.Tag).V}, CTNetcfg, proto.LabelNetcfg); err == nil {
		t.Fatal("accepted a non-Sign1 tag")
	}
	// by design it does NOT check the signature (only for objects the helper stored after verifying them)
	arr := append([]any(nil), v3.(cbor.Tag).V.([]any)...)
	arr[3] = bytes.Repeat([]byte{1}, 64)
	if _, err := Sign1Payload(cbor.Tag{Num: 18, V: arr}, CTNetcfg, proto.LabelNetcfg); err != nil {
		t.Fatal("a stored object with another signature did not parse")
	}
	if _, err := VerifySign1(cbor.Tag{Num: 18, V: arr}, CTNetcfg, proto.LabelNetcfg, admins(s2)); err == nil {
		t.Fatal("VerifySign1 accepted a bad signature")
	}
}
