package main

// net.go — the owner operations of the #254 tier-B units (docs/design/254-h23-harness.md §4.6; 219-protocol §5.3, §7):
// network/join and network/update (net.apply), network/leave, owner/add, owner/remove, diag/bundle. COSE objects are
// built here from the spec (219 §7.1–§7.3), independently of the helper:
//
//	net_config  COSE_Sign1 (tag 18), protected {1: -7, 3: "batman/netcfg"}, external_aad "batman-netcfg-v1", signed
//	            by the owner (the network's admin) on the WSL host ("SIGN cose <Sig_structure>")
//	net_secrets COSE_Sign1 of {1 net_id, 2 version, 3 SHA-256(DAC pub), 4 COSE_Encrypt}, the plaintext encrypted ON
//	            THE NODE to the helper's ECDH key: ECDH-ES P-256 ephemeral, HKDF-SHA256 over the COSE KDF context,
//	            ChaCha20-Poly1305 — so a mesh key never leaves the node (254-p1-impl §4.2)
//
// Secrets come in on fd 3 (opened by the root shell that starts provclient, read before the privilege drop), one
// "key=value" per line: mesh_id, channel, bw, sae (>= 8 bytes); nothing secret is ever printed (sha prefixes only).

import (
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"golang.org/x/crypto/chacha20poly1305"
)

const (
	labelNetcfg  = "batman-netcfg-v1"
	labelSecrets = "batman-secrets-v1"
)

// netInput: the values read from fd 3 (before the drop)
type netInput struct {
	meshID  string
	channel uint64
	bw      uint64
	sae     string
}

func readFd3() *netInput {
	f := os.NewFile(3, "fd3")
	if f == nil {
		die("net: fd 3 is not open (mesh_id / channel / bw / sae)")
	}
	b, err := io.ReadAll(io.LimitReader(f, 4096))
	f.Close()
	if err != nil {
		die("net: fd 3: %v", err)
	}
	in := &netInput{bw: 2}
	for _, l := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(strings.TrimRight(l, "\r"), "=")
		if !ok {
			continue
		}
		switch k {
		case "mesh_id":
			in.meshID = v
		case "channel":
			in.channel, _ = strconv.ParseUint(v, 10, 32)
		case "bw":
			in.bw, _ = strconv.ParseUint(v, 10, 8)
		case "sae":
			in.sae = v
		}
	}
	if in.meshID == "" || in.channel == 0 || len(in.sae) < 8 {
		die("net: fd 3 lacks mesh_id / channel / an sae of >= 8 bytes")
	}
	return in
}

func u32be(n uint64) []byte { return []byte{byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)} }

// sigStructure = cbor(["Signature1", protected, external_aad, payload]) (RFC 9052 §4.4; 219 §7.1)
func sigStructure(prot []byte, label string, payload []byte) []byte {
	return cEnc([]any{"Signature1", prot, []byte(label), payload})
}

func coseProt(ctype string) []byte { return cEnc(cmap{{uint64(1), -7}, {uint64(3), ctype}}) }

// sign1 asks the host to sign and returns the encoded COSE_Sign1 item (tag 18)
func (cl *client) sign1(ctype, label string, payload []byte) []byte {
	prot := coseProt(ctype)
	sig := cl.sign("cose", sigStructure(prot, label, payload))
	return cEnc(ctag{18, []any{prot, cmap{}, payload, sig}})
}

// objectHash = SHA-256(Sig_structure) of an encoded COSE_Sign1 (219 §7.1)
func objectHash(raw []byte) []byte {
	x, _, err := cDec(raw)
	if err != nil {
		die("object hash: %v", err)
	}
	t, ok := x.(ctag)
	a, ok2 := t.v.([]any)
	if !ok || !ok2 || len(a) != 4 {
		die("object hash: not a COSE_Sign1")
	}
	prot, _ := a[0].([]byte)
	payload, _ := a[2].([]byte)
	pm, _, _ := cDec(prot)
	ct, _ := pm.(cmap).get(3).(string)
	label := map[string]string{"batman/netcfg": labelNetcfg, "batman/secrets": labelSecrets}[ct]
	if label == "" {
		die("object hash: content type %q", ct)
	}
	return sha(sigStructure(prot, label, payload))
}

func hkdf32(ikm, info []byte) []byte {
	prk := hmac.New(sha256.New, make([]byte, 32)) // salt absent = HashLen zero bytes (RFC 5869)
	prk.Write(ikm)
	m := hmac.New(sha256.New, prk.Sum(nil))
	m.Write(info)
	m.Write([]byte{1})
	return m.Sum(nil)
}

// encryptTo builds the COSE_Encrypt (tag 96) of plain for the node: ECDH-ES (alg -25) with a fresh ephemeral key,
// content alg 24 (ChaCha20-Poly1305). eph / iv are parameters only for the selftest (vectors); nil = random.
func encryptTo(plain []byte, label string, nodePub, targetHash, netID []byte, version uint64, eph *ecdh.PrivateKey, iv []byte) (any, []byte) {
	np, err := ecdh.P256().NewPublicKey(nodePub)
	if err != nil {
		die("encrypt: node ECDH key: %v", err)
	}
	if eph == nil {
		if eph, err = ecdh.P256().GenerateKey(rand.Reader); err != nil {
			die("encrypt: %v", err)
		}
	}
	if iv == nil {
		iv = make([]byte, 12)
		rand.Read(iv)
	}
	z, err := eph.ECDH(np)
	if err != nil {
		die("encrypt: ecdh: %v", err)
	}
	bodyProt := cEnc(cmap{{uint64(1), 24}})
	recProt := cEnc(cmap{{uint64(1), -25}})
	epk := eph.PublicKey().Bytes() // 65 B uncompressed
	coseKey := cmap{{uint64(1), 2}, {-1, 1}, {-2, epk[1:33]}, {-3, epk[33:65]}}
	ctx := cEnc([]any{24, []any{nil, nil, nil}, []any{targetHash, nil, nil}, []any{256, recProt, append(append([]byte{}, netID...), u32be(version)...)}})
	cek := hkdf32(z, ctx)
	aead, err := chacha20poly1305.New(cek)
	if err != nil {
		die("encrypt: %v", err)
	}
	aad := cEnc([]any{"Encrypt", bodyProt, []byte(label)})
	ct := aead.Seal(nil, iv, plain, aad)
	return ctag{96, []any{bodyProt, cmap{{uint64(5), iv}}, ct, []any{[]any{recProt, cmap{{-1, coseKey}}, []byte{}}}}}, cek
}

// nodeKeys: the helper's ECDH public key and SHA-256 of its DAC public key (from info.cert)
func (cl *client) nodeKeys() (ecdhPub, dacHash []byte) {
	code, r := cl.call("info.ecdh_pub", cmap{})
	if code != 0 {
		die("info.ecdh_pub: code %d", code)
	}
	ecdhPub, _ = r.get(1).([]byte)
	code, r = cl.call("info.cert", cmap{})
	if code != 0 {
		die("info.cert: code %d", code)
	}
	der, _ := r.get(1).([]byte)
	c, err := x509.ParseCertificate(der)
	if err != nil {
		die("info.cert: %v", err)
	}
	pk, err := c.PublicKey.(interface {
		ECDH() (*ecdh.PublicKey, error)
	}).ECDH()
	if err != nil {
		die("info.cert: DAC key: %v", err)
	}
	return ecdhPub, sha(pk.Bytes())
}

// netObjects: net_config (version ver, prev hash prev or nil) + net_secrets for this node
func (cl *client) netObjects(in *netInput, ownerPub, netID []byte, ver uint64, prev []byte) (cfg, sec []byte) {
	var p3 any
	if prev != nil {
		p3 = prev
	}
	payload := cEnc(cmap{{uint64(1), netID}, {uint64(2), ver}, {uint64(3), p3}, {uint64(4), "dv-test"}, {uint64(5), "TW"},
		{uint64(6), cmap{{uint64(1), in.meshID}, {uint64(2), in.channel}, {uint64(3), in.bw}}}, {uint64(8), []any{ownerPub}}})
	cfg = cl.sign1("batman/netcfg", labelNetcfg, payload)
	ep, dh := cl.nodeKeys()
	root := make([]byte, 32)
	rand.Read(root)
	plain := cEnc(cmap{{uint64(1), in.sae}, {uint64(2), root}})
	enc, _ := encryptTo(plain, labelSecrets, ep, dh, netID, ver, nil, nil)
	sec = cl.sign1("batman/secrets", labelSecrets, cEnc(cmap{{uint64(1), netID}, {uint64(2), ver}, {uint64(3), dh}, {uint64(4), enc}}))
	return cfg, sec
}

// netOp runs one of the net / owner operations of cmdNode; returns false for an op it does not know
func netOp(cl *client, op string, args []string, in *netInput, hexArg func(int) []byte) bool {
	switch op {
	case "net-apply": // net-apply --first <owner_pub> | net-apply --update <owner_pub> <prev net_config hex>
		if len(args) < 3 {
			die("usage: net-apply --first <owner_pub> | --update <owner_pub> <prev-net_config-hex>")
		}
		ownerPub := hexArg(2)
		switch args[1] {
		case "--first":
			netID := make([]byte, 16)
			rand.Read(netID)
			cfg, sec := cl.netObjects(in, ownerPub, netID, 1, nil)
			env := cl.ownerOp("network/join", cmap{{uint64(1), rawCBOR(cfg)}, {uint64(3), rawCBOR(sec)}})
			code, _ := cl.call("net.apply", cmap{{uint64(1), cl.h}, {uint64(2), env}})
			fmt.Printf("RESULT net.apply code=%d version=1 net_id=%x mesh_id_sha=%s\n", code, netID, short([]byte(in.meshID)))
			fmt.Printf("NETCFG %s\n", hex.EncodeToString(cfg)) // not secret: the signed config (no keys)
		case "--update":
			prev := hexArg(3)
			x, _, err := cDec(prev)
			if err != nil {
				die("prev net_config: %v", err)
			}
			pl, _ := x.(ctag).v.([]any)[2].([]byte)
			pm, _, _ := cDec(pl)
			netID, _ := pm.(cmap).get(1).([]byte)
			ver, _ := pm.(cmap).get(2).(uint64)
			cfg, sec := cl.netObjects(in, ownerPub, netID, ver+1, objectHash(prev))
			// network/update: a version chain; the helper checks it against the stored version's admins (219 §5.3)
			env := cl.ownerOp("network/update", cmap{{uint64(1), []any{rawCBOR(cfg)}}, {uint64(2), rawCBOR(sec)}})
			code, _ := cl.call("net.apply", cmap{{uint64(1), cl.h}, {uint64(2), env}})
			fmt.Printf("RESULT net.apply(update) code=%d version=%d mesh_id_sha=%s\n", code, ver+1, short([]byte(in.meshID)))
			fmt.Printf("NETCFG %s\n", hex.EncodeToString(cfg))
		default:
			die("net-apply: --first or --update")
		}
	case "leave":
		env := cl.ownerOp("network/leave", cmap{})
		code, _ := cl.call("network.leave", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Printf("RESULT network.leave code=%d\n", code)
	case "owner-add": // owner-add <pub> <enc_pub> <sig_enc>: sig_enc made by the NEW owner's key on the host
		env := cl.ownerOp("owner/add", cmap{{uint64(1), hexArg(1)}, {uint64(2), hexArg(2)}, {uint64(3), hexArg(3)}})
		code, _ := cl.call("owner.add", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Printf("RESULT owner.add code=%d\n", code)
	case "owner-remove": // owner-remove <pub>: removes the owner whose SHA-256(pub) is the kid
		env := cl.ownerOp("owner/remove", cmap{{uint64(1), sha(hexArg(1))}})
		code, _ := cl.call("owner.remove", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		fmt.Printf("RESULT owner.remove code=%d\n", code)
	case "diag":
		env := cl.ownerOp("diag/bundle", cmap{})
		code, r := cl.call("diag.bundle", cmap{{uint64(1), cl.h}, {uint64(2), env}})
		b, _ := r.get(1).([]byte)
		fmt.Printf("RESULT diag.bundle code=%d bytes=%d sha=%s\n", code, len(b), short(b))
	default:
		return false
	}
	return true
}
