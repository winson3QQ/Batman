package release

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"math/big"
	"testing"

	"batman-prov/cbor"
)

// A Go-side test signer for objects signrel.py cannot make (extra keys in a signed payload). Keys are derived exactly
// as the harness does (tests/tools/peer/netobj.py _vector_key): d = sha256("batman-test-vector/" + name) mod (n-1) + 1.
func vectorKey(name string) *ecdsa.PrivateKey {
	c := elliptic.P256()
	h := sha256.Sum256([]byte("batman-test-vector/" + name))
	n1 := new(big.Int).Sub(c.Params().N, big.NewInt(1))
	d := new(big.Int).Mod(new(big.Int).SetBytes(h[:]), n1)
	d.Add(d, big.NewInt(1))
	k := &ecdsa.PrivateKey{D: d}
	k.PublicKey.Curve = c
	k.PublicKey.X, k.PublicKey.Y = c.ScalarBaseMult(d.Bytes())
	return k
}

func pub65(k *ecdsa.PrivateKey) []byte {
	return elliptic.Marshal(elliptic.P256(), k.PublicKey.X, k.PublicKey.Y) //nolint:staticcheck // test only
}

func sign1(t *testing.T, k *ecdsa.PrivateKey, payload cbor.Map, ct, label string) []byte {
	t.Helper()
	prot, _ := cbor.Encode(cbor.M(1, int64(-7), 3, ct))
	pl, _ := cbor.Encode(payload)
	ss, _ := cbor.Encode([]any{"Signature1", prot, []byte(label), pl})
	h := sha256.Sum256(ss)
	r, s, err := ecdsa.Sign(rand.Reader, k, h[:])
	if err != nil {
		t.Fatal(err)
	}
	half := new(big.Int).Rsh(elliptic.P256().Params().N, 1)
	if s.Cmp(half) > 0 { // low-s
		s.Sub(elliptic.P256().Params().N, s)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	b, _ := cbor.Encode(cbor.Tag{Num: 18, V: []any{prot, cbor.M(), pl, sig}})
	return b
}

func manifestOf(t *testing.T, ePayload, sPayload cbor.Map) []byte {
	t.Helper()
	e := sign1(t, vectorKey("release-root-T"), ePayload, CTRelKey, LabelRelKey)
	s := sign1(t, vectorKey("release-key-K_test"), sPayload, CTRelease, LabelRelease)
	pair, _ := cbor.Encode([]any{e, s})
	m := cbor.M(5, pair)
	for _, k := range []int{1, 2, 3, 4, 6} {
		if v, ok := sPayload.Get(k); ok {
			m = append(m, cbor.Entry{K: uint64(k), V: v})
		}
	}
	b, err := cbor.Encode(m)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestGoSignerMatchesHarnessKeys(t *testing.T) {
	if got, want := pub65(vectorKey("release-root-T")), readPub(t, "T.pub"); string(got) != string(want) {
		t.Fatal("Go-derived T differs from the harness T.pub")
	}
}

func TestVerifyRefusesExtraSignedKeys(t *testing.T) {
	kpub := pub65(vectorKey("release-key-K_test"))
	sums := make([]byte, 32)
	good := cbor.M(1, "1.5.14-wsl.30", 2, "ekh-bcm2711", 3, uint64(100), 4, sums, 9, uint64(10))
	if _, e := Verify(manifestOf(t, cbor.M(1, kpub, 2, uint64(2)), good), trustT(t, 1)); e != nil {
		t.Fatalf("Go-signed baseline refused: %v", e)
	}
	if _, e := Verify(manifestOf(t, cbor.M(1, kpub, 2, uint64(2), 3, "extra"), good), trustT(t, 1)); e == nil || e.Reason != ReasonBad {
		t.Fatalf("E with an extra key: %v (want 11)", e)
	}
	bad := append(cbor.Map{}, good...)
	bad = append(bad, cbor.Entry{K: uint64(10), V: "extra"})
	if _, e := Verify(manifestOf(t, cbor.M(1, kpub, 2, uint64(2)), bad), trustT(t, 1)); e == nil || e.Reason != ReasonBad {
		t.Fatalf("S with an extra key: %v (want 11)", e)
	}
	// E's serial 0
	if _, e := Verify(manifestOf(t, cbor.M(1, kpub, 2, uint64(0)), good), trustT(t, 0)); e == nil || e.Reason != ReasonBad {
		t.Fatalf("E serial 0: %v", e)
	}
}
