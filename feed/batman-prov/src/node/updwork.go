package node

// Software update, node side, part 2 (docs/design/254-p3-impl.md v7.12 §3.7.4–§3.7.5): update.prepare, the worker,
// update.apply, update.status, update-last, and the tick (disarm rule, slot-info retries, upload-file deletion).

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"batman-prov/cbor"
	"batman-prov/release"
)

// UpdateFS is the part of the update's side effects that are files and slot writes (the real one in cmd/).
type UpdateFS interface {
	BulkDir() string                                                              // /tmp/run/batman-provd-bulk (provd's tmpfs)
	WorkDir() string                                                              // /tmp/run/batman/update (root 0700)
	ProvdUID() int                                                                // the upload's expected owner (471)
	P6State() (string, bool)                                                      // /opt/batdata/state when /opt/batdata is a mount point
	AutocommitLog() string                                                        // /opt/batdata/log/autocommit.log
	SlotWrite(cancel <-chan struct{}, dir string, rootfs io.Reader) (int, string) // batman-slot write <dir> (private namespace, 600 s)
	SlotBusy() bool                                                               // the slot flock is held (otaBusy's rule)
	IsTrial() bool                                                                // the cached batman-slot is-trial
	Reboot() error                                                                // batman-slot reboot committed (init namespace)
}

const (
	fSetLease  = 1024 // F_SETLEASE (F_LINUX_SPECIFIC_BASE + 0)
	maxSums    = 256 << 10
	maxMeta    = 64 << 10
	writeTries = 4 // the first try + 3 retries 10 s apart on rc 14 (§3.7.5-7)
)

var retryWait = 10 * time.Second  // tests shorten it
var rebootDelay = 2 * time.Second // the reply first, then batman-slot reboot committed

// updateLast: p6 state/update-last (§3.7.4), CBOR, root 0600, tmp + fsync + rename + fsync(dir).
type updateLast struct {
	Sha                   []byte
	FromSlot, FromVersion string
	ToSlot, ToVersion     string
	ApplyBootID           string
	AclogOff              uint64
	Rebooting             bool
}

func (ul *updateLast) encode() ([]byte, error) {
	return cbor.Encode(cbor.M(0, uint64(1), 1, ul.Sha, 2, ul.FromSlot, 3, ul.FromVersion, 4, ul.ToSlot, 5, ul.ToVersion,
		6, ul.ApplyBootID, 7, ul.AclogOff, 8, ul.Rebooting))
}

func decodeUpdateLast(b []byte) *updateLast {
	it, err := cbor.Decode(b)
	m, ok := it.(cbor.Map)
	if err != nil || !ok {
		return nil
	}
	if f, ok := getUint(m, 0); !ok || f != 1 {
		return nil // unknown format -> as if there were none (§3.7.4)
	}
	ul := &updateLast{}
	var ok1, ok2, ok3, ok4, ok5, ok6, ok7 bool
	ul.Sha, ok1 = getBytes(m, 1)
	ul.FromSlot, ok2 = getString(m, 2)
	ul.FromVersion, ok3 = getString(m, 3)
	ul.ToSlot, ok4 = getString(m, 4)
	ul.ToVersion, ok5 = getString(m, 5)
	ul.ApplyBootID, ok6 = getString(m, 6)
	ul.AclogOff, ok7 = getUint(m, 7)
	rb, ok8 := m.Get(8)
	ul.Rebooting, _ = rb.(bool)
	if !ok1 || len(ul.Sha) != 32 || !ok2 || !ok3 || !ok4 || !ok5 || !ok6 || !ok7 || !ok8 {
		return nil
	}
	return ul
}

func getUint(m cbor.Map, k int) (uint64, bool) {
	v, ok := m.Get(k)
	u, ok2 := v.(uint64)
	return u, ok && ok2
}
func getBytes(m cbor.Map, k int) ([]byte, bool) {
	v, ok := m.Get(k)
	b, ok2 := v.([]byte)
	return b, ok && ok2
}
func getString(m cbor.Map, k int) (string, bool) {
	v, ok := m.Get(k)
	s, ok2 := v.(string)
	return s, ok && ok2
}

// readUL / writeUL: caller holds updMu (read-modify-write in the lock).
func (u *updater) readUL() *updateLast {
	dir, ok := u.fs.P6State()
	if !ok {
		return nil
	}
	f, err := os.OpenFile(filepath.Join(dir, "update-last"), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 4096))
	if err != nil {
		return nil
	}
	return decodeUpdateLast(b)
}

func (u *updater) writeUL(ul *updateLast) error {
	dir, ok := u.fs.P6State()
	if !ok {
		return errors.New("p6 is not mounted")
	}
	b, err := ul.encode()
	if err != nil {
		return err
	}
	d, err := os.OpenFile(dir, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	defer d.Close()
	tmp := filepath.Join(dir, ".update-last.tmp")
	os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	f.Close()
	if err == nil {
		err = os.Rename(tmp, filepath.Join(dir, "update-last"))
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return d.Sync()
}

func ownerID(pub []byte) []byte { h := sha256.Sum256(pub); return h[:] }

func (u *updater) progress(phase uint64, pct uint64, reason uint64, sha []byte, ver string) cbor.Map {
	m := cbor.M(1, phase, 2, pct)
	if reason != 0 {
		m = append(m, cbor.Entry{K: uint64(3), V: reason})
	}
	if len(sha) == 32 {
		m = append(m, cbor.Entry{K: uint64(4), V: sha})
	}
	if ver != "" {
		m = append(m, cbor.Entry{K: uint64(5), V: ver})
	}
	return m
}

func shaArg(body cbor.Map) ([]byte, *Error) {
	v, ok := body.Get(1)
	b, ok2 := v.([]byte)
	if !ok || !ok2 || len(b) != 32 {
		return nil, fail(ESchema, "body key 1: a sha256")
	}
	return b, nil
}

// ---- update.prepare (owner-op; under n.mu) -----------------------------------------------------------------

func (n *Node) updatePrepare(signer []byte, body cbor.Map) (cbor.Map, *Error) {
	u := n.upd
	if u == nil || u.fs == nil {
		return nil, fail(EUnsupported, "update verbs not wired")
	}
	sha, e := shaArg(body)
	if e != nil {
		return nil, e
	}
	// the orphan check needs the slot lock's state: slotMu first (lock order), then updMu
	u.slotMu.Lock()
	defer u.slotMu.Unlock()
	u.updMu.Lock()
	defer u.updMu.Unlock()
	if u.working {
		return nil, fail(EBusy, "the worker is running")
	}
	p := u.validPending()
	if p == nil || subtle.ConstantTimeCompare(p.R.SumsSha, sha) != 1 {
		return nil, failR(EReject, 15, "no pending update for this sha")
	}
	if u.window == nil || subtle.ConstantTimeCompare(u.window.Owner, ownerID(signer)) != 1 {
		return nil, failR(EReject, 15, "the caller does not hold the upload window")
	}
	fi, err := os.Lstat(filepath.Join(u.fs.BulkDir(), "payload"))
	if err != nil || !fi.Mode().IsRegular() || uint64(fi.Size()) != p.R.Size {
		return nil, failR(EReject, 15, "the upload is missing or incomplete")
	}
	// an orphan `batman-slot write` of the previous helper still running (§3.7.4 prepare row)
	wd := u.fs.WorkDir()
	if _, err := os.Lstat(filepath.Join(wd, "boot")); err == nil {
		if u.fs.SlotBusy() {
			return nil, fail(EBusy, "a previous helper's slot write is still running")
		}
		os.RemoveAll(wd)
	}
	ver, _ := u.sys.Build()
	act := u.sys.ActiveSlot()
	ul := &updateLast{Sha: sha, FromSlot: act, FromVersion: ver, ToSlot: other(act), ToVersion: p.R.Version}
	if err := u.writeUL(ul); err != nil {
		return nil, fail(EStorage, "update-last: %v", err)
	}
	u.failSha, u.failWhy = nil, 0
	u.working, u.window = true, nil
	u.workPct = 0
	u.cancel = make(chan struct{})
	p.Expiry = 1 << 31 // until the worker ends (+ 30 min then)
	go n.worker(p.R, u.cancel)
	n.Log("update.prepare: %s: worker started", p.R.Version)
	return u.progress(2, 0, 0, sha, p.R.Version), nil
}

// ---- the worker (§3.7.5) -------------------------------------------------------------------------------------

type werr struct {
	reason uint64
	why    string
}

func (n *Node) worker(r *release.Release, cancel chan struct{}) {
	u := n.upd
	reason, why := n.work(r, cancel)
	os.RemoveAll(u.fs.WorkDir())
	u.slotMu.Lock()
	if reason == 0 {
		u.slotInfoOf(other(u.sys.ActiveSlot()), true) // VERIFIED of this boot is on the target now
	}
	u.slotMu.Unlock()
	u.updMu.Lock()
	u.working = false
	if p := u.pend; p != nil {
		p.Expiry = u.sys.Uptime() + pendingTTL
	}
	if reason != 0 {
		u.failSha, u.failWhy = r.SumsSha, reason
		n.Log("update worker: %s refused, reason %d (%s)", r.Version, reason, why)
	} else {
		n.Log("update worker: %s written and verified", r.Version)
	}
	u.updMu.Unlock()
}

func (n *Node) work(r *release.Release, cancel chan struct{}) (uint64, string) {
	u := n.upd
	// 1. open, check, unlink, take it away from provd, lease (§3.7.5-1)
	dir, err := os.OpenFile(u.fs.BulkDir(), os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return 15, "bulk dir: " + err.Error()
	}
	defer dir.Close()
	fd, err := syscall.Openat(int(dir.Fd()), "payload", syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return 15, "open: " + err.Error()
	}
	f := os.NewFile(uintptr(fd), "payload")
	defer f.Close()
	var st syscall.Stat_t
	if syscall.Fstat(fd, &st) != nil || st.Mode&syscall.S_IFMT != syscall.S_IFREG || st.Nlink != 1 ||
		int(st.Uid) != u.fs.ProvdUID() || uint64(st.Size) != r.Size {
		return 15, "the upload is not a single-link regular file of provd with the signed size"
	}
	if fl, err := fcntl(fd, syscall.F_GETFL, 0); err == nil {
		fcntl(fd, syscall.F_SETFL, fl&^syscall.O_NONBLOCK)
	}
	if err := syscall.Unlinkat(int(dir.Fd()), "payload"); err != nil {
		return 15, "unlink: " + err.Error()
	}
	if os.Geteuid() == 0 {
		syscall.Fchown(fd, 0, 0)
		syscall.Fchmod(fd, 0o400)
	}
	if _, err := fcntl(fd, fSetLease, syscall.F_RDLCK); err != nil {
		if errors.Is(err, syscall.EINVAL) {
			return 21, "F_SETLEASE: leases disabled (fs.leases-enable = 0)"
		}
		return 15, "F_SETLEASE: someone still holds the upload open for writing"
	}
	defer fcntl(fd, fSetLease, syscall.F_UNLCK)
	if syscall.Fstat(fd, &st) != nil || st.Nlink != 0 || uint64(st.Size) != r.Size {
		return 15, "the upload changed after it was taken"
	}
	wd := u.fs.WorkDir()
	if err := os.Mkdir(wd, 0o700); err != nil {
		return 21, "work dir: " + err.Error()
	}
	if err := os.Mkdir(filepath.Join(wd, "boot"), 0o700); err != nil {
		return 21, "work dir: " + err.Error()
	}
	// 2.–5. first pass: verify everything, write the boot members to the work dir, never touch a slot
	var sums []byte
	if we := n.scan(f, r, wd, nil, &sums); we != nil {
		return we.reason, we.why
	}
	u.updMu.Lock()
	u.workPct = 50
	u.updMu.Unlock()
	// 6. second pass: the same checks again (never assume the bytes are the first pass's), stream the rootfs
	for try := 1; ; try++ {
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return 21, "seek: " + err.Error()
		}
		pr, pw := io.Pipe()
		res := make(chan [2]any, 1)
		go func() {
			rc, out := u.fs.SlotWrite(cancel, wd, pr)
			pr.CloseWithError(io.ErrClosedPipe)
			res <- [2]any{rc, out}
		}()
		we := n.scan(f, r, wd, pw, &sums)
		if we != nil {
			pw.CloseWithError(errors.New(we.why))
		} else {
			pw.Close()
		}
		out := <-res
		rc, msg := out[0].(int), out[1].(string)
		if we != nil {
			return we.reason, we.why
		}
		if rc == 14 && try < writeTries { // busy before begin_write: nothing was written (§3.7.5-7)
			select {
			case <-cancel:
				return 22, "canceled"
			case <-time.After(retryWait):
			}
			continue
		}
		if rc != 0 {
			reason, busy := slotReason(rc)
			if busy {
				reason = 21
			}
			return reason, "batman-slot write rc " + strconv.Itoa(rc) + ": " + lastLineOf(msg)
		}
		return 0, ""
	}
}

func fcntl(fd int, cmd, arg int) (int, error) {
	r, _, e := syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), uintptr(cmd), uintptr(arg))
	if e != 0 {
		return 0, e
	}
	return int(r), nil
}

// scan reads the tar.gz once (§3.7.5-2..5). root == nil: the first pass (writes SHA256SUMS, metadata and the boot
// members into wd and hashes root.squashfs); root != nil: the second pass (re-checks, compares the boot members,
// streams root.squashfs into root). sums is the first pass's SHA256SUMS (the second must be byte-identical).
func (n *Node) scan(f *os.File, r *release.Release, wd string, root io.Writer, sums *[]byte) *werr {
	u := n.upd
	bad := func(why string) *werr { return &werr{release.ReasonBad, why} }
	br := bufio.NewReader(f)
	gz, err := gzip.NewReader(br) // br is a ByteReader: gzip adds no buffer of its own
	if err != nil {
		return bad("not gzip")
	}
	gz.Multistream(false)
	tr := tar.NewReader(gz)
	readSmall := func(name string, max int64) ([]byte, *werr) {
		h, err := tr.Next()
		if err != nil || h.Name != name || h.Typeflag != tar.TypeReg || h.Size > max {
			return nil, bad("member " + name + " missing / not first / too big")
		}
		b, err := io.ReadAll(io.LimitReader(tr, max+1))
		if err != nil || int64(len(b)) != h.Size {
			return nil, bad("member " + name + " short")
		}
		return b, nil
	}
	s, we := readSmall("SHA256SUMS", maxSums)
	if we != nil {
		return we
	}
	if h := sha256.Sum256(s); !bytes.Equal(h[:], r.SumsSha) {
		return bad("sha256(SHA256SUMS) != the signed key 4")
	}
	if root != nil && !bytes.Equal(s, *sums) {
		return bad("SHA256SUMS changed between the passes")
	}
	list, ok := parseSums(s)
	if !ok {
		return bad("SHA256SUMS names refused")
	}
	meta, we := readSmall("metadata", maxMeta)
	if we != nil {
		return we
	}
	_, board := u.sys.Build()
	mBoard, mRel, mSize := "", "", int64(-1)
	for _, l := range strings.Split(string(meta), "\n") {
		k, v, _ := strings.Cut(l, "=")
		switch k {
		case "board":
			mBoard = v
		case "release":
			mRel = v
		case "size":
			mSize, _ = strconv.ParseInt(v, 10, 64)
		}
	}
	if mBoard != r.Board || r.Board != board || mRel != r.Version || mSize <= 0 {
		return bad("metadata board / release / size do not match S")
	}
	if root == nil {
		*sums = s
		if os.WriteFile(filepath.Join(wd, "SHA256SUMS"), s, 0o600) != nil || os.WriteFile(filepath.Join(wd, "metadata"), meta, 0o600) != nil {
			return &werr{21, "work dir write"}
		}
	}
	var bootTotal int64
	members := 2
	seen := map[string]bool{}
	for {
		h, err := tr.Next()
		if err != nil {
			return bad("no root.squashfs member")
		}
		members++
		if members > len(list)+4 {
			return bad("too many members")
		}
		switch {
		case h.Typeflag == tar.TypeDir && (h.Name == "boot/" || h.Name == "boot/overlays/"):
			continue
		case h.Typeflag != tar.TypeReg:
			return bad("member " + h.Name + " is not a regular file")
		case seen[h.Name]:
			return bad("member " + h.Name + " repeats")
		}
		seen[h.Name] = true
		want, listed := list[h.Name]
		if h.Name == "root.squashfs" {
			if !listed || h.Size != mSize {
				return bad("root.squashfs not listed / size != metadata size")
			}
			hs := sha256.New()
			var dst io.Writer = hs
			if root != nil {
				dst = io.MultiWriter(hs, root)
			}
			nb, err := io.Copy(dst, io.LimitReader(tr, h.Size))
			if err != nil || nb != h.Size || hex.EncodeToString(hs.Sum(nil)) != want {
				return bad("root.squashfs does not match SHA256SUMS")
			}
			break
		}
		if !listed || !bootClass(h.Name) {
			return bad("member " + h.Name + " not listed or not a boot file the slot takes")
		}
		bootTotal += h.Size
		if uint64(bootTotal) > r.BootTotal {
			return bad("boot members exceed the signed total")
		}
		dst := filepath.Join(wd, h.Name)
		hs := sha256.New()
		if root == nil {
			os.MkdirAll(filepath.Dir(dst), 0o700)
			out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
			if err != nil {
				return &werr{21, "work dir: " + err.Error()}
			}
			nb, err := io.Copy(io.MultiWriter(out, hs), io.LimitReader(tr, h.Size))
			out.Close()
			if err != nil || nb != h.Size {
				return bad("member " + h.Name + " short")
			}
		} else if nb, err := io.Copy(hs, io.LimitReader(tr, h.Size)); err != nil || nb != h.Size {
			return bad("member " + h.Name + " short")
		}
		if hex.EncodeToString(hs.Sum(nil)) != want {
			return bad("member " + h.Name + " does not match SHA256SUMS")
		}
	}
	// nothing after root.squashfs: the tar's end, then nothing after the gzip stream
	if _, err := tr.Next(); err != io.EOF {
		return bad("members after root.squashfs")
	}
	if _, err := io.Copy(io.Discard, gz); err != nil {
		return bad("gzip stream corrupt")
	}
	if rest, _ := io.Copy(io.Discard, br); rest > 0 { // what bufio already holds + the rest of the file
		return bad("data after the gzip stream")
	}
	return nil
}

// parseSums: "<64 hex>  <name>" lines; the same name rules as batman-slot's sums_check (§3.7.3).
func parseSums(b []byte) (map[string]string, bool) {
	out := map[string]string{}
	seen := map[string]bool{}
	for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		h, name, ok := strings.Cut(l, "  ")
		if !ok || !isHex(h, 64) || !sumName(name) {
			return nil, false
		}
		lc := strings.ToLower(name)
		if seen[lc] {
			return nil, false
		}
		seen[lc] = true
		out[name] = h
	}
	return out, len(out) > 0
}

func sumName(n string) bool {
	if n == "root.squashfs" {
		return true
	}
	rest, ok := strings.CutPrefix(n, "boot/")
	if !ok {
		return false
	}
	rest = strings.TrimPrefix(rest, "overlays/")
	if rest == "" || rest[0] == '.' || strings.ContainsRune(rest, '/') {
		return false
	}
	for _, c := range rest {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	b := strings.ToLower(rest)
	switch b {
	case "autoboot.txt", "config.txt", "distroconfig.txt", "cmdline.txt", "bootcode.bin":
		return false
	}
	return !strings.HasPrefix(b, "batman-")
}

// bootClass: the class allow-list of batman-slot boot_class (§3.7.3)
func bootClass(n string) bool {
	if strings.HasPrefix(n, "boot/overlays/") {
		return true
	}
	rest := strings.TrimPrefix(n, "boot/")
	if strings.Contains(rest, "/") {
		return false
	}
	switch {
	case rest == "kernel8.img":
		return true
	case strings.HasPrefix(rest, "start") && strings.HasSuffix(rest, ".elf"):
		return true
	case strings.HasPrefix(rest, "fixup") && strings.HasSuffix(rest, ".dat"):
		return true
	case strings.HasSuffix(rest, ".dtb"):
		return true
	}
	return false
}

// ---- update.apply (owner-op; under n.mu; slotMu from arm to `rebooting`) ------------------------------------

func (n *Node) updateApply(signer []byte, body cbor.Map) (cbor.Map, *Error) {
	u := n.upd
	if u == nil || u.fs == nil {
		return nil, fail(EUnsupported, "update verbs not wired")
	}
	sha, e := shaArg(body)
	if e != nil {
		return nil, e
	}
	u.slotMu.Lock()
	defer u.slotMu.Unlock()
	u.updMu.Lock()
	p := u.validPending()
	if u.working || p == nil || subtle.ConstantTimeCompare(p.R.SumsSha, sha) != 1 ||
		subtle.ConstantTimeCompare(p.Owner, ownerID(signer)) != 1 {
		u.updMu.Unlock()
		return nil, failR(EReject, 15, "no written update of this owner for this sha")
	}
	r := p.R
	u.updMu.Unlock()
	boot := u.sys.BootID()
	tgt := other(u.sys.ActiveSlot())
	si, ok := u.slotInfoOf(tgt, true)
	if !ok || si.Bad || si.Verified != hex.EncodeToString(sha)+" "+boot {
		return nil, failR(EReject, 15, "the target slot is not verified for this sha in this boot")
	}
	k8 := filepath.Join(u.fs.WorkDir() + ".key8")
	var lines []string
	for _, h := range r.BootCfg {
		lines = append(lines, hex.EncodeToString(h))
	}
	if err := writeKey8(k8, lines); err != nil {
		return nil, fail(EApply, "key-8 list: %v", err)
	}
	u.updMu.Lock()
	ul := u.readUL()
	if ul == nil || !bytes.Equal(ul.Sha, sha) {
		ver, _ := u.sys.Build()
		ul = &updateLast{Sha: sha, FromSlot: u.sys.ActiveSlot(), FromVersion: ver, ToSlot: tgt, ToVersion: r.Version}
	}
	ul.ApplyBootID, ul.AclogOff, ul.Rebooting = boot, aclogSize(u.fs.AutocommitLog()), false
	if err := u.writeUL(ul); err != nil { // "arm started" is recorded BEFORE arm (A10-m3)
		u.updMu.Unlock()
		return nil, fail(EStorage, "update-last: %v", err)
	}
	u.updMu.Unlock()
	rc, out := u.sys.Slot(60*time.Second, "arm", hex.EncodeToString(sha), k8)
	if rc != 0 {
		n.disarmClear(ul)
		reason, busy := slotReason(rc)
		if busy {
			return nil, fail(EBusy, "batman-slot busy")
		}
		return nil, failR(EReject, reason, "arm rc %d: %s", rc, lastLineOf(out))
	}
	u.updMu.Lock()
	ul.Rebooting = true
	if err := u.writeUL(ul); err != nil { // armed but not recorded: do not reboot into it (A12-m4)
		u.updMu.Unlock()
		n.disarmClear(ul)
		return nil, fail(EStorage, "update-last: %v", err)
	}
	u.updMu.Unlock()
	go func() {
		time.Sleep(rebootDelay)
		if err := u.fs.Reboot(); err != nil {
			n.Log("update.apply: reboot failed (%v) — disarming", err)
			u.slotMu.Lock()
			u.updMu.Lock()
			ul.Rebooting = false
			u.writeUL(ul)
			u.updMu.Unlock()
			n.disarmClear(ul)
			u.slotMu.Unlock()
		}
	}()
	n.Log("update.apply: %s armed, rebooting", r.Version)
	return u.progress(3, 100, 0, sha, r.Version), nil
}

// disarmClear: disarm; only after it returned 0 is apply_boot_id cleared (A12-m2). Caller holds slotMu.
func (n *Node) disarmClear(ul *updateLast) {
	u := n.upd
	if rc, _ := u.sys.Slot(30*time.Second, "disarm"); rc != 0 {
		return
	}
	u.updMu.Lock()
	ul.ApplyBootID = ""
	if u.writeUL(ul) != nil {
		u.disarmedBoot = u.sys.BootID()
	}
	u.updMu.Unlock()
}

func writeKey8(path string, lines []string) error {
	os.Remove(path)
	s := strings.Join(lines, "\n")
	if s != "" {
		s += "\n"
	}
	return os.WriteFile(path, []byte(s), 0o600)
}

func aclogSize(p string) uint64 {
	fi, err := os.Lstat(p)
	if err != nil || !fi.Mode().IsRegular() {
		return 0
	}
	return uint64(fi.Size())
}

// aclogVerdict reads autocommit.log after off (<= 1 MiB, O_NOFOLLOW): "committed", "reverted" or "".
func aclogVerdict(p string, off uint64, slot, ver string) string {
	f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return ""
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() || uint64(fi.Size()) < off {
		return ""
	}
	if _, err := f.Seek(int64(off), io.SeekStart); err != nil {
		return ""
	}
	b, _ := io.ReadAll(io.LimitReader(f, 1<<20))
	verdict := ""
	for _, l := range strings.Split(string(b), "\n") {
		fl := strings.Fields(l)
		if len(fl) < 2 {
			continue
		}
		var s, v string
		for _, x := range fl[2:] {
			if k, val, ok := strings.Cut(x, "="); ok {
				switch k {
				case "slot":
					s = val
				case "version":
					v = val
				}
			}
		}
		if s != slot || v != ver {
			continue
		}
		switch fl[1] { // the word after the timestamp, whole (NOT-COMMITTED is not COMMITTED)
		case "COMMITTED", "COMMITTED-BY-OPERATOR":
			verdict = "committed"
		case "TRIAL-REVERTED":
			verdict = "reverted"
		}
	}
	return verdict
}

// ---- update.status (read-only: caches and files only) -----------------------------------------------------

func (n *Node) updateStatus() (cbor.Map, *Error) {
	u := n.upd
	if u == nil || u.fs == nil {
		return nil, fail(EUnsupported, "update verbs not wired")
	}
	u.updMu.Lock()
	defer u.updMu.Unlock()
	p := u.validPending()
	if u.window != nil && p != nil {
		var pct uint64
		if p.R.Size > 0 {
			pct = u.uploaded * 100 / p.R.Size
		}
		return u.progress(1, min(pct, 100), 0, p.R.SumsSha, p.R.Version), nil
	}
	if u.working && p != nil {
		return u.progress(2, u.workPct, 0, p.R.SumsSha, p.R.Version), nil
	}
	if p != nil && u.failSha != nil && bytes.Equal(u.failSha, p.R.SumsSha) {
		return u.progress(0, 0, u.failWhy, p.R.SumsSha, p.R.Version), nil
	}
	act := u.sys.ActiveSlot()
	tgt := other(act)
	si, haveSI := u.cachedSlot(tgt)
	boot := u.sys.BootID()
	if p != nil && haveSI && si.Verified == hex.EncodeToString(p.R.SumsSha)+" "+boot {
		return u.progress(3, 100, 0, p.R.SumsSha, p.R.Version), nil
	}
	ul := u.readUL()
	if ul == nil {
		return u.progress(0, 0, 0, nil, ""), nil
	}
	ver, _ := u.sys.Build()
	st := func(ph, reason uint64) (cbor.Map, *Error) {
		return u.progress(ph, 0, reason, ul.Sha, ul.ToVersion), nil
	}
	if ver != ul.FromVersion && ver != ul.ToVersion {
		return u.progress(0, 0, 0, nil, ""), nil // row 5: stale (an operator moved slots since)
	}
	if act == ul.ToSlot && ver == ul.ToVersion {
		if u.fs.IsTrial() {
			return st(4, 0)
		}
		return st(5, 0)
	}
	if act == ul.FromSlot {
		if ul.ApplyBootID != "" && ul.ApplyBootID != boot {
			switch aclogVerdict(u.fs.AutocommitLog(), ul.AclogOff, ul.ToSlot, ul.ToVersion) {
			case "committed":
				return st(0, 0)
			case "reverted":
				return st(6, 0)
			}
			if ul.Rebooting {
				return st(6, 18)
			}
		}
		if haveSI && si.Bad {
			return st(0, 22)
		}
		if haveSI && strings.HasPrefix(si.Verified, hex.EncodeToString(ul.Sha)+" ") {
			return st(0, 23)
		}
	}
	return st(0, 0)
}

// ---- the tick (helper start + every 4 s) ---------------------------------------------------------------------

// UpdateTick: the disarm rule (§3.7.4: TryLock slotMu first, then read update-last), the slot-info retries, and the
// one deletion rule of the upload file (§3.8.2: no window and no worker -> delete).
func (n *Node) UpdateTick() {
	u := n.upd
	if u == nil || u.fs == nil {
		return
	}
	if u.slotMu.TryLock() {
		u.updMu.Lock()
		ul := u.readUL()
		u.updMu.Unlock()
		boot := u.sys.BootID()
		if ul != nil && ul.ApplyBootID == boot && !ul.Rebooting && u.disarmedBoot != boot {
			n.Log("update: an apply of this boot did not reach its reboot — disarming")
			n.disarmClear(ul)
		}
		for _, s := range []string{"A", "B"} {
			if u.slotStale(s) {
				u.slotInfoOf(s, false)
			}
		}
		u.slotMu.Unlock()
	}
	u.updMu.Lock()
	if u.window != nil && u.sys.Uptime() >= u.window.Expiry {
		u.window = nil
	}
	if u.window == nil && !u.working {
		if d, err := os.OpenFile(u.fs.BulkDir(), os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0); err == nil {
			names, _ := d.Readdirnames(64)
			for _, nm := range names {
				syscall.Unlinkat(int(d.Fd()), nm) // never follows a symlink; a directory fails (left alone)
			}
			d.Close()
		}
	}
	u.updMu.Unlock()
}

// BootConfigOK (§6.4 ble-ok, now from the bootinfo cache: the helper never mounts a FAT, §3.7.3): both slots'
// distroconfig.txt [pi4] section has miniuart-bt and core_freq_min=500. A slot never read -> false.
func (n *Node) BootConfigSectionsOK() bool {
	u := n.upd
	if u == nil {
		return false
	}
	if !u.slotMu.TryLock() {
		a, okA := u.cachedSlot("A")
		b, okB := u.cachedSlot("B")
		return okA && okB && sectionOK(a.Distroconfig) && sectionOK(b.Distroconfig)
	}
	defer u.slotMu.Unlock()
	a, okA := u.slotInfoOf("A", false)
	b, okB := u.slotInfoOf("B", false)
	return okA && okB && sectionOK(a.Distroconfig) && sectionOK(b.Distroconfig)
}

func sectionOK(s string) bool {
	in, mb, cf := false, false, false
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if strings.HasPrefix(l, "[") {
			in = l == "[pi4]"
			continue
		}
		if in && l == "dtoverlay=miniuart-bt" {
			mb = true
		}
		if in && l == "core_freq_min=500" {
			cf = true
		}
	}
	return mb && cf
}
