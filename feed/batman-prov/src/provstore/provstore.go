// Package provstore is the provisioning record (docs/design/254-stage1-impl.md §4.3; 254-p1-impl.md §2.1):
// its CBOR schema (internal to the helper — no other program parses prov.cbor), the one-line prov.meta, the
// overlay copy under /etc/batman-prov, and the two p5 calls into batman-config-save (--prov-only, --prov-get).
//
//	prov.cbor = { 1: v(=1), 2: generation, 3: state, 4: radio_managed, 5: claimed_counter,
//	              6: [ {1: owner_pub, 2: owner_enc_pub, 3: owner_tag_key} ... (<= 4) ],
//	              7: adv_owner_key / null, 8: [admin_pub ...], 9: net / null, 10: member_list Sign1 / null,
//	              11: [ssh key line added by ssh_keys.set ...] }
//	net       = { 1: net_config Sign1 (raw), 2: net_secrets Sign1 (raw), 3: net_version, 4: net_id }
//	prov.meta = "v=1 state=<s> gen=<n> sha=<hex64 of prov.cbor> rm=<0|1>"
package provstore

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"batman-prov/cbor"
)

// States of the record (254-stage1-impl §1.4).
const (
	Legacy    = "legacy"
	Unclaimed = "unclaimed"
	Claimed   = "claimed"
	Member    = "member"
)

// Owner is one owner of a claimed node.
type Owner struct {
	Pub, EncPub, TagKey []byte
}

// Net is the node's current network (raw signed objects + their identity).
type Net struct {
	Config, Secrets []byte
	Version         uint64
	NetID           []byte
}

// Record is the decoded prov.cbor.
type Record struct {
	Generation     uint64
	State          string
	RadioManaged   bool
	ClaimedCounter uint64
	Owners         []Owner
	AdvOwnerKey    []byte
	Admins         [][]byte
	Net            *Net
	Members        []byte
	SSHKeysAdded   []string
	// Left: the node left its network (network/leave) — its mesh wireless is forgotten (docs/design/254-wireless-txn.md
	// §2). Encoded as key 12 ONLY when true, and only on a claimed record without a network: older images' Decode
	// demands exactly 11 keys, so every other record stays readable by them (review r5 MAJOR-1).
	Left bool
}

// MaxRecord is the size limit of prov.cbor (the same as config-save's PROV_MAX).
const MaxRecord = 65536

// Encode serialises r as core deterministic CBOR.
func (r *Record) Encode() ([]byte, error) {
	owners := []any{}
	for _, o := range r.Owners {
		owners = append(owners, cbor.M(1, o.Pub, 2, o.EncPub, 3, o.TagKey))
	}
	admins := []any{}
	for _, a := range r.Admins {
		admins = append(admins, a)
	}
	keys := []any{}
	for _, k := range r.SSHKeysAdded {
		keys = append(keys, k)
	}
	var adv any
	if r.AdvOwnerKey != nil {
		adv = r.AdvOwnerKey
	}
	var net any
	if r.Net != nil {
		net = cbor.M(1, r.Net.Config, 2, r.Net.Secrets, 3, r.Net.Version, 4, r.Net.NetID)
	}
	var members any
	if r.Members != nil {
		members = r.Members
	}
	m := cbor.M(1, uint64(1), 2, r.Generation, 3, r.State, 4, r.RadioManaged, 5, r.ClaimedCounter,
		6, owners, 7, adv, 8, admins, 9, net, 10, members, 11, keys)
	if r.Left {
		// the same rule Decode applies: a record every later read would reject is never written (review r7 MINOR-1)
		if r.State != Claimed || r.Net != nil {
			return nil, errors.New("provstore: Left only on a claimed record without a network")
		}
		m = append(m, cbor.Entry{K: uint64(12), V: true})
	}
	b, err := cbor.Encode(m)
	if err == nil && len(b) > MaxRecord {
		return nil, errors.New("provstore: record exceeds 64 KiB")
	}
	return b, err
}

var errSchema = errors.New("provstore: prov.cbor does not match the schema")

// Decode parses prov.cbor strictly: exact key set, exact types, known states, sizes. v != 1 -> ErrTooNew / schema.
func Decode(b []byte) (*Record, error) {
	if len(b) > MaxRecord {
		return nil, errSchema
	}
	x, err := cbor.Decode(b)
	if err != nil {
		return nil, errSchema
	}
	m, ok := x.(cbor.Map)
	if !ok || (len(m) != 11 && len(m) != 12) {
		return nil, errSchema
	}
	get := func(k int) any { v, _ := m.Get(k); return v }
	if v, ok := get(1).(uint64); !ok || v != 1 {
		if ok && v > 1 {
			return nil, ErrTooNew
		}
		return nil, errSchema
	}
	r := &Record{}
	var ok2 bool
	if r.Generation, ok = get(2).(uint64); !ok {
		return nil, errSchema
	}
	if r.State, ok = get(3).(string); !ok || !ValidState(r.State) {
		return nil, errSchema
	}
	if r.RadioManaged, ok = get(4).(bool); !ok {
		return nil, errSchema
	}
	if r.ClaimedCounter, ok = get(5).(uint64); !ok {
		return nil, errSchema
	}
	ol, ok := get(6).([]any)
	if !ok || len(ol) > 4 {
		return nil, errSchema
	}
	for _, o := range ol {
		om, ok := o.(cbor.Map)
		if !ok || len(om) != 3 {
			return nil, errSchema
		}
		var ow Owner
		p, _ := om.Get(1)
		e, _ := om.Get(2)
		t, _ := om.Get(3)
		if ow.Pub, ok = p.([]byte); !ok || len(ow.Pub) != 65 {
			return nil, errSchema
		}
		if ow.EncPub, ok2 = e.([]byte); !ok2 || len(ow.EncPub) != 65 {
			return nil, errSchema
		}
		if ow.TagKey, ok2 = t.([]byte); !ok2 || len(ow.TagKey) != 32 {
			return nil, errSchema
		}
		r.Owners = append(r.Owners, ow)
	}
	switch a := get(7).(type) {
	case nil:
	case []byte:
		if len(a) != 32 {
			return nil, errSchema
		}
		r.AdvOwnerKey = a
	default:
		return nil, errSchema
	}
	al, ok := get(8).([]any)
	if !ok || len(al) > 4 {
		return nil, errSchema
	}
	for _, a := range al {
		ab, ok := a.([]byte)
		if !ok || len(ab) != 65 {
			return nil, errSchema
		}
		r.Admins = append(r.Admins, ab)
	}
	switch n := get(9).(type) {
	case nil:
	case cbor.Map:
		c, _ := n.Get(1)
		s, _ := n.Get(2)
		v, _ := n.Get(3)
		id, _ := n.Get(4)
		net := &Net{}
		var ok3, ok4 bool
		net.Config, ok = c.([]byte)
		net.Secrets, ok2 = s.([]byte)
		net.Version, ok3 = v.(uint64)
		net.NetID, ok4 = id.([]byte)
		if len(n) != 4 || !ok || !ok2 || !ok3 || !ok4 || len(net.NetID) != 16 {
			return nil, errSchema
		}
		r.Net = net
	default:
		return nil, errSchema
	}
	switch mb := get(10).(type) {
	case nil:
	case []byte:
		r.Members = mb
	default:
		return nil, errSchema
	}
	kl, ok := get(11).([]any)
	if !ok || len(kl) > 8 {
		return nil, errSchema
	}
	for _, k := range kl {
		ks, ok := k.(string)
		if !ok {
			return nil, errSchema
		}
		r.SSHKeysAdded = append(r.SSHKeysAdded, ks)
	}
	// state invariants
	switch r.State {
	case Legacy, Unclaimed:
		if len(r.Owners) != 0 || r.Net != nil {
			return nil, errSchema
		}
	case Claimed:
		if len(r.Owners) == 0 {
			return nil, errSchema
		}
	case Member:
		if len(r.Owners) == 0 || r.Net == nil {
			return nil, errSchema
		}
	}
	// key 12 (Left): canonical form — absent = false; present must be true, on a claimed record without a network
	if len(m) == 12 {
		l, ok := get(12).(bool)
		if !ok || !l || r.State != Claimed || r.Net != nil {
			return nil, errSchema
		}
		r.Left = true
	}
	return r, nil
}

// ErrTooNew = the record's v is newer than this helper understands (rc 14 / unknown(too-new)).
var ErrTooNew = errors.New("provstore: record version too new")

// ValidState is one of the four record states.
func ValidState(s string) bool { return s == Legacy || s == Unclaimed || s == Claimed || s == Member }

// Meta is the parsed prov.meta.
type Meta struct {
	State string
	Gen   uint64
	SHA   string
	RM    bool
}

// MetaLine renders prov.meta for a record and its encoding.
func MetaLine(r *Record, enc []byte) string {
	s := sha256.Sum256(enc)
	rm := 0
	if r.RadioManaged {
		rm = 1
	}
	return fmt.Sprintf("v=1 state=%s gen=%d sha=%s rm=%d\n", r.State, r.Generation, hex.EncodeToString(s[:]), rm)
}

// ParseMeta parses the meta line with the same rules as prov-lock.sh's prov_meta_ok.
func ParseMeta(b []byte) (*Meta, error) {
	if len(b) > 256 {
		return nil, errors.New("provstore: meta too long")
	}
	line := strings.TrimSuffix(string(b), "\n")
	if strings.ContainsAny(line, "\n") {
		return nil, errors.New("provstore: meta has more than one line")
	}
	for _, c := range line {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '=' || c == '_' || c == ' ') {
			return nil, errors.New("provstore: meta charset")
		}
	}
	m := &Meta{}
	var v string
	for _, kv := range strings.Fields(line) {
		k, val, _ := strings.Cut(kv, "=")
		switch k {
		case "v":
			v = val
		case "state":
			m.State = val
		case "gen":
			g, err := strconv.ParseUint(val, 10, 64)
			if err != nil {
				return nil, errors.New("provstore: meta gen")
			}
			m.Gen = g
		case "sha":
			m.SHA = val
		case "rm":
			m.RM = val == "1"
		}
	}
	if n, err := strconv.Atoi(v); err != nil {
		return nil, errors.New("provstore: meta v")
	} else if n > 1 {
		return nil, ErrTooNew
	} else if n != 1 {
		return nil, errors.New("provstore: meta v")
	}
	if !ValidState(m.State) || len(m.SHA) != 64 {
		return nil, errors.New("provstore: meta fields")
	}
	return m, nil
}

// ---- on-disk locations ---------------------------------------------------------------------------------------

// Paths are the helper's files; Default() is the node layout, tests build their own.
type Paths struct {
	Dir        string // /etc/batman-prov (overlay, root 0700)
	ConfigSave string // /usr/bin/batman-config-save
	RunDir     string // /tmp/run/batman (root-only, #280)
	State      string // /opt/batdata/state
}

// Default returns the node layout.
func Default() Paths {
	return Paths{Dir: "/etc/batman-prov", ConfigSave: "/usr/bin/batman-config-save", RunDir: "/tmp/run/batman", State: "/opt/batdata/state"}
}

func (p Paths) Record() string   { return filepath.Join(p.Dir, "prov.cbor") }
func (p Paths) Meta() string     { return filepath.Join(p.Dir, "prov.meta") }
func (p Paths) Identity() string { return filepath.Join(p.Dir, "identity") }
func (p Paths) Stage() string    { return filepath.Join(p.Dir, ".stage") }
func (p Paths) Txn() string      { return filepath.Join(p.Dir, ".txn") }

// LoadOverlay reads the overlay copy: record + meta, verified against each other. (nil, nil) when absent.
func LoadOverlay(p Paths) (*Record, *Meta, error) {
	mb, err := readRegular(p.Meta())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	m, err := ParseMeta(mb)
	if err != nil {
		return nil, nil, err
	}
	rb, err := readRegular(p.Record())
	if err != nil {
		return nil, nil, err
	}
	s := sha256.Sum256(rb)
	if hex.EncodeToString(s[:]) != m.SHA {
		return nil, nil, errors.New("provstore: overlay prov.cbor does not match its meta")
	}
	r, err := Decode(rb)
	if err != nil {
		return nil, nil, err
	}
	if r.State != m.State || r.Generation != m.Gen {
		return nil, nil, errors.New("provstore: overlay meta and record disagree")
	}
	return r, m, nil
}

func readRegular(path string) ([]byte, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() || fi.Size() > MaxRecord {
		return nil, fmt.Errorf("provstore: %s not a regular file <= 64 KiB", path)
	}
	return os.ReadFile(path)
}

// WriteOverlay atomically replaces the overlay record + meta (record first, meta last = the commit point).
func WriteOverlay(p Paths, r *Record) (enc []byte, meta string, err error) {
	enc, err = r.Encode()
	if err != nil {
		return nil, "", err
	}
	meta = MetaLine(r, enc)
	if err := os.MkdirAll(p.Dir, 0o700); err != nil {
		return nil, "", err
	}
	if err := atomicWrite(p.Record(), enc, 0o600); err != nil {
		return nil, "", err
	}
	if err := atomicWrite(p.Meta(), []byte(meta), 0o600); err != nil {
		return nil, "", err
	}
	return enc, meta, nil
}

func atomicWrite(path string, b []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	_ = os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

// ---- p5, through batman-config-save ----------------------------------------------------------------------------

// cleanEnv is the environment the helper hands config-save: nothing inherited (254-p1-impl §4.1).
var cleanEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C"}

// PersistP5 = batman-config-save --prov-only. identityDir may be "" (record only). Returns config-save's rc.
func PersistP5(p Paths, recordFile, metaFile, identityDir, txn string) (int, string) {
	args := []string{"--prov-only", "--prov-file", recordFile, "--prov-meta", metaFile}
	if identityDir != "" {
		args = append(args, "--prov-identity", identityDir)
	}
	if txn != "" {
		args = append(args, "--txn", txn)
	}
	return run(p.ConfigSave, args...)
}

// GetP5 = batman-config-save --prov-get <dir>; dir must not exist. Returns the rc of 254-stage1-impl §4.2.
func GetP5(p Paths, dir string) (int, string) { return run(p.ConfigSave, "--prov-get", dir) }

func run(bin string, args ...string) (int, string) {
	c := exec.Command(bin, args...)
	c.Env = cleanEnv
	out, err := c.CombinedOutput()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode(), string(out)
		}
		return 1, err.Error()
	}
	return 0, string(out)
}
