package provstore

import (
	"os"
	"testing"

	"batman-prov/cbor"
)

// docs/design/254-wireless-txn.md §2 (Left, canonical form) and §3 (.txn = presence + snapshot)

func leftRecord() *Record {
	return &Record{Generation: 5, State: Claimed, RadioManaged: true, ClaimedCounter: 1,
		Owners: []Owner{{Pub: b(65, 4), EncPub: b(65, 5), TagKey: b(32, 6)}}, AdvOwnerKey: b(32, 7), Left: true}
}

func TestLeftRoundTripAndOldReaderShape(t *testing.T) {
	r := leftRecord()
	enc, err := r.Encode()
	if err != nil {
		t.Fatal(err)
	}
	r2, err := Decode(enc)
	if err != nil || !r2.Left {
		t.Fatalf("left record: %v left=%v", err, r2 != nil && r2.Left)
	}
	// a record that has NOT left encodes to exactly 11 keys: an older image (Decode demands 11) still reads it
	r.Left = false
	enc, _ = r.Encode()
	x, _ := cbor.Decode(enc)
	if n := len(x.(cbor.Map)); n != 11 {
		t.Fatalf("a non-left record has %d keys, want 11 (older images' Decode)", n)
	}
}

func TestLeftEncodeRefusesNonCanonical(t *testing.T) {
	r := leftRecord()
	r.State = Member
	r.Net = &Net{Config: []byte{0xd2}, Secrets: []byte{0xd2}, Version: 1, NetID: b(16, 9)}
	if _, err := r.Encode(); err == nil {
		t.Fatal("Encode wrote Left on a member with a network (every later read would reject it)")
	}
	r = leftRecord()
	r.State = Unclaimed
	r.Owners = nil
	if _, err := r.Encode(); err == nil {
		t.Fatal("Encode wrote Left on an unclaimed record")
	}
}

func TestLeftDecodeRefusesNonCanonical(t *testing.T) {
	base, _ := leftRecord().Encode()
	x, _ := cbor.Decode(base)
	m := x.(cbor.Map).Without(12)
	// key 12 = false is not canonical (absent = false)
	e, _ := cbor.Encode(append(append(cbor.Map{}, m...), cbor.Entry{K: uint64(12), V: false}))
	if _, err := Decode(e); err == nil {
		t.Fatal("key 12 = false accepted")
	}
	// key 12 not a bool
	e, _ = cbor.Encode(append(append(cbor.Map{}, m...), cbor.Entry{K: uint64(12), V: uint64(1)}))
	if _, err := Decode(e); err == nil {
		t.Fatal("key 12 = 1 accepted")
	}
	// Left on a member (a corrupt or hand-made record must not make Finish forget a live network)
	mem := &Record{Generation: 3, State: Member, RadioManaged: true, ClaimedCounter: 1,
		Owners: []Owner{{Pub: b(65, 4), EncPub: b(65, 5), TagKey: b(32, 6)}}, Admins: [][]byte{b(65, 8)},
		Net: &Net{Config: []byte{0xd2}, Secrets: []byte{0xd2}, Version: 1, NetID: b(16, 9)}}
	me, _ := mem.Encode()
	y, _ := cbor.Decode(me)
	e, _ = cbor.Encode(append(append(cbor.Map{}, y.(cbor.Map)...), cbor.Entry{K: uint64(12), V: true}))
	if _, err := Decode(e); err == nil {
		t.Fatal("Left on a member accepted")
	}
}

func TestTxnSnapshotRoundTrip(t *testing.T) {
	p := Paths{Dir: t.TempDir()}
	if TxnPresent(p) {
		t.Fatal("present before any write")
	}
	// empty fields (a fresh card has no channel recorded, a legacy node may have no mesh id) are written "-"
	if err := WriteTxn(p, "tok", 4, 5, "net.apply", "CHANGE-ME-NOW", "", "", true); err != nil {
		t.Fatal(err)
	}
	tx, ok := ReadTxn(p)
	if !ok || !TxnPresent(p) {
		t.Fatalf("not read back: ok=%v", ok)
	}
	if tx.Token != "tok" || tx.Verb != "net.apply" || tx.PrevKey != "CHANGE-ME-NOW" || tx.PrevID != "" || tx.PrevChannel != "" || !tx.PrevDisabled || !tx.HasRadio {
		t.Fatalf("read back %+v", tx)
	}
	if err := WriteTxn(p, "t2", 5, 6, "network.leave", "secretkey123", "mesh one", "40", false); err != nil {
		t.Fatal(err)
	}
	tx, ok = ReadTxn(p)
	if !ok || tx.PrevKey != "secretkey123" || tx.PrevID != "mesh one" || tx.PrevChannel != "40" || tx.PrevDisabled {
		t.Fatalf("read back %+v ok=%v", tx, ok)
	}
	if fi, _ := os.Stat(p.Txn()); fi.Mode().Perm() != 0o600 {
		t.Fatalf(".txn mode %v", fi.Mode().Perm())
	}
}

func TestTxnShippedFormats(t *testing.T) {
	p := Paths{Dir: t.TempDir()}
	// a shipped well-formed two-line file still reads (no radio line)
	os.WriteFile(p.Txn(), []byte("tok 4 5 net.apply\nprev 6b6579 6d657368 40\n"), 0o600)
	tx, ok := ReadTxn(p)
	if !ok || tx.PrevKey != "key" || tx.PrevID != "mesh" || tx.PrevChannel != "40" || tx.HasRadio {
		t.Fatalf("shipped format: %+v ok=%v", tx, ok)
	}
	// a shipped file with an empty field (unreadable) is still PRESENT: the change stays unfinished, never ignored
	os.WriteFile(p.Txn(), []byte("tok 4 5 net.apply\nprev 6b6579 6d657368 \n"), 0o600)
	if _, ok := ReadTxn(p); ok {
		t.Fatal("a shipped file with an empty field parsed")
	}
	if !TxnPresent(p) {
		t.Fatal("an unreadable .txn is not present")
	}
	RemoveTxn(p)
	if TxnPresent(p) {
		t.Fatal("present after RemoveTxn")
	}
}
