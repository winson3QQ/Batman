// provclient — the #254 PR-H2 test client of batman-provhelper's socket (docs/design/254-p1-impl.md §2.2, §4.2).
// An INDEPENDENT implementation (own minimal CBOR, own protocol computations; nothing shared with the helper), so
// a wrong helper and a wrong client cannot agree by construction. It plays the part of a (possibly compromised)
// provd: it can only talk to the socket as uid provd.
//
//	provclient node <op> [args]   on the node, started as ROOT: reads its secrets first (claim.secret file, fd 3,
//	                              fd 4), never stdin; then drops to uid/gid 471 with no supplementary groups and
//	                              dumpable=0; only then connects to /tmp/run/batman-prov/helper.sock.
//	                              Signatures the owner must make are requested on stdout ("SIGN <purpose> <hex>")
//	                              and read back from stdin ("SIG <hex>"), so the owner key never reaches the node.
//	provclient sign <keyfile>     on the WSL host: answers SIGN lines with an ES256 (low-s) signature.
//	provclient keygen <keyfile>   a fresh P-256 owner key (0600) — one per run; prints the public key hex.
//	provclient selftest <vectors.json>
//
// Output never contains a secret: secret values are printed as the first 16 hex chars of their SHA-256.
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
)

const sockPath = "/tmp/run/batman-prov/helper.sock"

func die(f string, a ...any) { fmt.Fprintf(os.Stderr, "provclient: "+f+"\n", a...); os.Exit(2) }

func short(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:8]) }

func sha(parts ...[]byte) []byte {
	h := sha256.New()
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

// ---- minimal CBOR (only what the helper socket and the protocol need) -------------------------------------------

type kv struct {
	k any
	v any
}
type cmap []kv

func cHead(major byte, n uint64) []byte {
	switch {
	case n < 24:
		return []byte{major<<5 | byte(n)}
	case n < 1<<8:
		return []byte{major<<5 | 24, byte(n)}
	case n < 1<<16:
		return []byte{major<<5 | 25, byte(n >> 8), byte(n)}
	case n < 1<<32:
		return []byte{major<<5 | 26, byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)}
	}
	b := []byte{major<<5 | 27}
	for i := 7; i >= 0; i-- {
		b = append(b, byte(n>>(8*uint(i))))
	}
	return b
}

func cEnc(v any) []byte {
	switch x := v.(type) {
	case nil:
		return []byte{0xf6}
	case bool:
		if x {
			return []byte{0xf5}
		}
		return []byte{0xf4}
	case int:
		if x < 0 {
			return cHead(1, uint64(-x-1))
		}
		return cHead(0, uint64(x))
	case uint64:
		return cHead(0, x)
	case []byte:
		return append(cHead(2, uint64(len(x))), x...)
	case string:
		return append(cHead(3, uint64(len(x))), x...)
	case []any:
		out := cHead(4, uint64(len(x)))
		for _, e := range x {
			out = append(out, cEnc(e)...)
		}
		return out
	case cmap:
		// core deterministic: sort by encoded key bytes (insertion sort; maps here are tiny)
		type ent struct{ k, v []byte }
		es := make([]ent, 0, len(x))
		for _, e := range x {
			es = append(es, ent{cEnc(e.k), cEnc(e.v)})
		}
		for i := 1; i < len(es); i++ {
			for j := i; j > 0 && string(es[j].k) < string(es[j-1].k); j-- {
				es[j], es[j-1] = es[j-1], es[j]
			}
		}
		out := cHead(5, uint64(len(es)))
		for _, e := range es {
			out = append(out, e.k...)
			out = append(out, e.v...)
		}
		return out
	case int64:
		if x < 0 {
			return cHead(1, uint64(-x-1))
		}
		return cHead(0, uint64(x))
	case ctag:
		return append(cHead(6, x.n), cEnc(x.v)...)
	case rawCBOR:
		return x
	}
	die("cannot encode %T", v)
	return nil
}

type rawCBOR []byte

type ctag struct {
	n uint64
	v any
}

// cDec decodes one item (lenient: the client only reads helper responses; strictness is the helper's job).
func cDec(b []byte) (any, []byte, error) {
	if len(b) == 0 {
		return nil, nil, errors.New("eof")
	}
	ib := b[0]
	maj, ai := ib>>5, ib&31
	b = b[1:]
	var n uint64
	switch {
	case ai < 24:
		n = uint64(ai)
	case ai >= 24 && ai <= 27:
		l := 1 << (ai - 24)
		if len(b) < l {
			return nil, nil, errors.New("short")
		}
		for i := 0; i < l; i++ {
			n = n<<8 | uint64(b[i])
		}
		b = b[l:]
	default:
		return nil, nil, errors.New("indefinite")
	}
	switch maj {
	case 0:
		return n, b, nil
	case 1:
		return -int64(n) - 1, b, nil
	case 2, 3:
		if uint64(len(b)) < n {
			return nil, nil, errors.New("short str")
		}
		if maj == 2 {
			return append([]byte(nil), b[:n]...), b[n:], nil
		}
		return string(b[:n]), b[n:], nil
	case 4:
		a := []any{}
		for i := uint64(0); i < n; i++ {
			var v any
			var err error
			if v, b, err = cDec(b); err != nil {
				return nil, nil, err
			}
			a = append(a, v)
		}
		return a, b, nil
	case 5:
		m := cmap{}
		for i := uint64(0); i < n; i++ {
			var k, v any
			var err error
			if k, b, err = cDec(b); err != nil {
				return nil, nil, err
			}
			if v, b, err = cDec(b); err != nil {
				return nil, nil, err
			}
			m = append(m, kv{k, v})
		}
		return m, b, nil
	case 6:
		v, rest, err := cDec(b)
		return ctag{n, v}, rest, err
	case 7:
		switch ai {
		case 20:
			return false, b, nil
		case 21:
			return true, b, nil
		case 22:
			return nil, b, nil
		}
	}
	return nil, nil, errors.New("unsupported")
}

func (m cmap) get(k uint64) any {
	for _, e := range m {
		if e.k == k {
			return e.v
		}
	}
	return nil
}

// ---- protocol computations (219-protocol §5.4, §5.7) — written from the spec, independently of the helper ----------

func clientChal(nonce, h, dacDER, ownerPub []byte) []byte {
	return sha([]byte("batman-claim-v1"), nonce, h, sha(dacDER), ownerPub)
}

func checkMac(k, cc, sn []byte) []byte {
	od := make([]byte, 13)
	od[0] = 0x08
	in := append(append([]byte{}, k...), cc...)
	in = append(in, od[0:4]...)
	in = append(in, make([]byte, 8)...)
	in = append(in, od[4:7]...)
	in = append(in, sn[8])
	in = append(in, od[7:11]...)
	in = append(in, sn[0:2]...)
	in = append(in, od[11:13]...)
	return sha(in)
}

func opInput(h, nonceHelper []byte, verb string, argsHash []byte) []byte {
	in := append([]byte("batman-owner-op-v1"), h...)
	in = append(in, nonceHelper...)
	in = append(in, byte(len(verb)))
	in = append(in, verb...)
	return append(in, argsHash...)
}

// ---- signing on the host -----------------------------------------------------------------------------------------

func loadKey(path string) *ecdsa.PrivateKey {
	b, err := os.ReadFile(path)
	if err != nil {
		die("key: %v", err)
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		die("key: not PEM")
	}
	k, err := x509.ParseECPrivateKey(blk.Bytes)
	if err != nil {
		die("key: %v", err)
	}
	return k
}

func signLowS(k *ecdsa.PrivateKey, msg []byte) []byte {
	r, s, err := ecdsa.Sign(rand.Reader, k, sha(msg))
	if err != nil {
		die("sign: %v", err)
	}
	n := elliptic.P256().Params().N
	if s.Cmp(new(big.Int).Rsh(n, 1)) > 0 {
		s.Sub(n, s)
	}
	out := make([]byte, 64)
	r.FillBytes(out[:32])
	s.FillBytes(out[32:])
	return out
}

func pub(k *ecdsa.PrivateKey) []byte {
	return elliptic.Marshal(elliptic.P256(), k.PublicKey.X, k.PublicKey.Y) //nolint:staticcheck // SEC1 65 B, test tool
}

func cmdKeygen(path string) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		die("%v", err)
	}
	der, _ := x509.MarshalECPrivateKey(k)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		die("%v", err)
	}
	pem.Encode(f, &pem.Block{Type: "EC PRIVATE KEY", Bytes: der})
	f.Close()
	fmt.Println(hex.EncodeToString(pub(k)))
}

// cmdSign answers SIGN lines: "SIGN <purpose> <hex>" -> "SIG <hex>". Purposes are a closed list.
func cmdSign(keyPath string) {
	k := loadKey(keyPath)
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 1<<20)
	for in.Scan() {
		f := strings.Fields(strings.TrimRight(in.Text(), "\r"))
		if len(f) != 3 || f[0] != "SIGN" {
			fmt.Println("ERR")
			continue
		}
		msg, err := hex.DecodeString(f[2])
		if err != nil || !(f[1] == "owner-op" && strings.HasPrefix(string(msg), "batman-owner-op-v1") ||
			f[1] == "owner-enc" && strings.HasPrefix(string(msg), "batman-owner-enc-v1")) {
			fmt.Println("ERR")
			continue
		}
		fmt.Println("SIG " + hex.EncodeToString(signLowS(k, msg)))
	}
}

// ---- node side ----------------------------------------------------------------------------------------------------

type client struct {
	c      *net.UnixConn
	id     uint64
	h      []byte
	signIn *bufio.Scanner
}

// callTimeout: PROVCLIENT_TIMEOUT_S (default 30). The claim-lock fix's busy path (a held config-save lock) makes one
// call take ~35 s (--save 10 s + one retry 10 s + the best-effort --save after the restore 10 s + the lock steps).
func callTimeout() time.Duration {
	s := 30
	if v := os.Getenv("PROVCLIENT_TIMEOUT_S"); v != "" {
		if _, err := fmt.Sscanf(v, "%d", &s); err != nil || s < 1 || s > 600 {
			die("PROVCLIENT_TIMEOUT_S=%q: want 1..600", v)
		}
	}
	return time.Duration(s) * time.Second
}

func (cl *client) call(verb string, args cmap) (uint64, cmap) {
	cl.id++
	req := cEnc(cmap{{uint64(1), verb}, {uint64(2), cl.id}, {uint64(3), args}})
	cl.c.SetDeadline(time.Now().Add(callTimeout()))
	if _, err := cl.c.Write(req); err != nil {
		die("write: %v", err)
	}
	buf := make([]byte, 1<<17)
	n, err := cl.c.Read(buf)
	if err != nil {
		return 999, nil // connection closed by the helper
	}
	x, _, err := cDec(buf[:n])
	if err != nil {
		die("bad response: %v", err)
	}
	m, _ := x.(cmap)
	code, _ := m.get(2).(uint64)
	res, _ := m.get(3).(cmap)
	return code, res
}

func (cl *client) sign(purpose string, msg []byte) []byte {
	fmt.Printf("SIGN %s %s\n", purpose, hex.EncodeToString(msg))
	if !cl.signIn.Scan() {
		die("signer gone")
	}
	f := strings.Fields(strings.TrimRight(cl.signIn.Text(), "\r"))
	if len(f) != 2 || f[0] != "SIG" {
		die("signer refused")
	}
	b, err := hex.DecodeString(f[1])
	if err != nil || len(b) != 64 {
		die("bad signature")
	}
	return b
}

func (cl *client) nonce() (node, helper []byte) {
	code, r := cl.call("nonce", cmap{{uint64(1), cl.h}})
	if code != 0 {
		die("nonce: code %d", code)
	}
	a, _ := r.get(1).([]byte)
	b, _ := r.get(2).([]byte)
	return a, b
}

// ownerOp builds a request envelope of type typ with body + owner-op (key 31) signed by the host.
func (cl *client) ownerOp(typ string, body cmap) []byte {
	_, nh := cl.nonce()
	ah := sha(cEnc(body))
	sig := cl.sign("owner-op", opInput(cl.h, nh, typ, ah))
	full := append(cmap{}, body...)
	full = append(full, kv{uint64(31), cmap{{uint64(1), typ}, {uint64(2), sig}}})
	return cEnc(cmap{{uint64(0), []any{uint64(1), uint64(0)}}, {uint64(1), uint64(1)}, {uint64(2), typ}, {uint64(3), full}})
}

// dropPrivileges: secrets already read; then uid/gid 471, no supplementary groups, not dumpable (254-p1-impl §2.2).
func dropPrivileges() {
	if os.Geteuid() != 0 {
		die("node mode starts as root (it reads root-only secrets, then drops)")
	}
	if err := syscall.Setgroups([]int{}); err != nil {
		die("setgroups: %v", err)
	}
	if err := syscall.Setgid(471); err != nil {
		die("setgid: %v", err)
	}
	if err := syscall.Setuid(471); err != nil {
		die("setuid: %v", err)
	}
	if syscall.Getuid() != 471 || syscall.Geteuid() != 471 || syscall.Getgid() != 471 {
		die("privilege drop did not take")
	}
	if g, _ := syscall.Getgroups(); len(g) != 0 {
		die("supplementary groups left: %v", g)
	}
	const prSetDumpable, prGetDumpable = 4, 3
	syscall.RawSyscall(syscall.SYS_PRCTL, prSetDumpable, 0, 0)
	if d, _, _ := syscall.RawSyscall(syscall.SYS_PRCTL, prGetDumpable, 0, 0); d != 0 {
		die("still dumpable")
	}
}

func cmdNode(args []string) {
	if len(args) == 0 {
		die("node: op missing")
	}
	op := args[0]
	// secrets first, as root (never stdin: stdin is the signer channel)
	var claimSecret []byte
	if op == "claim" || op == "claim-attacker" || op == "replay" {
		b, err := os.ReadFile("/etc/batman-prov/identity/claim.secret")
		if err != nil || len(b) != 32 {
			die("claim.secret: %v", err)
		}
		claimSecret = b
	}
	// #254 claim-lock fix §11.3: PROVCLIENT_PW_FILE = a root-only file (created here, as root, O_EXCL 0600) that
	// receives the password the helper returned, so a node-side musl crypt() probe can check it against shadow —
	// the password never reaches stdout, a log or the host. Opened before the privilege drop; written after.
	var pwOut *os.File
	if p := os.Getenv("PROVCLIENT_PW_FILE"); p != "" {
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			die("PROVCLIENT_PW_FILE: %v", err)
		}
		pwOut = f
	}
	savePw := func(pw string) {
		if pwOut != nil && pw != "" {
			pwOut.WriteString(pw + "\n")
		}
		if pwOut != nil {
			pwOut.Close()
		}
	}
	dropPrivileges()
	c, err := net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: sockPath, Net: "unixpacket"})
	if err != nil {
		die("connect: %v", err)
	}
	h := make([]byte, 32)
	rand.Read(h)
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 1<<20)
	cl := &client{c: c, h: h, signIn: in}
	hexArg := func(i int) []byte {
		if len(args) <= i {
			die("%s: argument %d missing", op, i)
		}
		b, err := hex.DecodeString(args[i])
		if err != nil {
			die("%s: argument %d not hex", op, i)
		}
		return b
	}
	switch op {
	case "info":
		code, r := cl.call("info.state", cmap{})
		fmt.Printf("RESULT info.state code=%d state=%v gen=%v owners=%v rm=%v\n", code, r.get(1), r.get(2), r.get(3), r.get(4))
		code, r = cl.call("info.cert", cmap{})
		cert, _ := r.get(1).([]byte)
		sn, _ := r.get(2).([]byte)
		fmt.Printf("RESULT info.cert code=%d cert_sha=%s sn=%x\n", code, short(cert), sn)
	case "claim", "claim-attacker":
		ownerPub := hexArg(1)
		encPub := hexArg(2)
		code, r := cl.call("info.cert", cmap{})
		if code != 0 {
			die("info.cert %d", code)
		}
		cert, _ := r.get(1).([]byte)
		sn, _ := r.get(2).([]byte)
		nn, _ := cl.nonce()
		bound := ownerPub
		if op == "claim-attacker" { // the buyer's response, the attacker's owner_pub (§4.1 negative test)
			bound = hexArg(3)
		}
		resp := checkMac(claimSecret, clientChal(nn, h, cert, bound), sn)
		sigEnc := cl.sign("owner-enc", append([]byte("batman-owner-enc-v1"), encPub...))
		code, r = cl.call("claim.verify", cmap{{uint64(1), h}, {uint64(2), resp}, {uint64(3), ownerPub}, {uint64(4), encPub}, {uint64(5), sigEnc}})
		tag, _ := r.get(1).([]byte)
		adv, _ := r.get(2).([]byte)
		pw, _ := r.get(3).(string)
		savePw(pw)
		fmt.Printf("RESULT claim.verify code=%d tag=%s adv=%s pw=%s\n", code, short(tag), short(adv), short([]byte(pw)))
	case "replay": // claim.replay with the STORED owner_pub (hex arg 1): one nonce gives both the CheckMac nonce and
		// the owner-op's nonce_helper (a second `nonce` call would make the helper pick the newer node nonce)
		ownerPub := hexArg(1)
		code, r := cl.call("info.cert", cmap{})
		if code != 0 {
			die("info.cert %d", code)
		}
		cert, _ := r.get(1).([]byte)
		sn, _ := r.get(2).([]byte)
		nn, nh := cl.nonce()
		resp := checkMac(claimSecret, clientChal(nn, h, cert, ownerPub), sn)
		body := cmap{{uint64(1), resp}}
		sig := cl.sign("owner-op", opInput(h, nh, "claim/replay", sha(cEnc(body))))
		full := append(cmap{}, body...)
		full = append(full, kv{uint64(31), cmap{{uint64(1), "claim/replay"}, {uint64(2), sig}}})
		env := cEnc(cmap{{uint64(0), []any{uint64(1), uint64(0)}}, {uint64(1), uint64(1)}, {uint64(2), "claim/replay"}, {uint64(3), full}})
		code, r = cl.call("claim.replay", cmap{{uint64(1), h}, {uint64(2), env}})
		tag, _ := r.get(1).([]byte)
		pw, _ := r.get(3).(string)
		savePw(pw)
		fmt.Printf("RESULT claim.replay code=%d tag=%s pw=%s\n", code, short(tag), short([]byte(pw)))
	case "ssh-keys":
		var keys []any
		for _, k := range args[1:] {
			keys = append(keys, k)
		}
		env := cl.ownerOp("ssh_keys/set", cmap{{uint64(1), keys}})
		code, _ := cl.call("ssh_keys.set", cmap{{uint64(1), h}, {uint64(2), env}})
		fmt.Printf("RESULT ssh_keys.set code=%d\n", code)
	case "root-reset":
		env := cl.ownerOp("root_password/reset", cmap{})
		code, r := cl.call("root_password.reset", cmap{{uint64(1), h}, {uint64(2), env}})
		pw, _ := r.get(1).(string)
		savePw(pw)
		fmt.Printf("RESULT root_password.reset code=%d pw=%s\n", code, short([]byte(pw)))
	case "rename":
		env := cl.ownerOp("settings/set", cmap{{"hostname", "x"}})
		code, _ := cl.call("settings.set", cmap{{uint64(1), h}, {uint64(2), env}})
		fmt.Printf("RESULT settings.set(hostname) code=%d\n", code)
	case "verb": // a bare verb with no args, for the schema / forbidden-verb tests
		code, _ := cl.call(args[1], cmap{})
		fmt.Printf("RESULT %s code=%d\n", args[1], code)
	default:
		die("unknown op %q", op)
	}
}

func main() {
	if len(os.Args) < 2 {
		die("usage: provclient node <op> … | sign <key> | keygen <key> | selftest <vectors.json>")
	}
	switch os.Args[1] {
	case "node":
		cmdNode(os.Args[2:])
	case "sign":
		cmdSign(os.Args[2])
	case "keygen":
		cmdKeygen(os.Args[2])
	case "selftest":
		selftest(os.Args[2])
	default:
		die("unknown mode %q", os.Args[1])
	}
}
