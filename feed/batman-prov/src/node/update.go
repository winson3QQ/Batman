package node

// Software update, node side (docs/design/254-p3-impl.md v7.12 §3.7.4). This file: update.check, the pending
// record, the slot-info cache (batman-slot bootinfo) and the batman-slot exit-code mapping. Lock order (§3.7.4):
// n.mu -> slotMu -> updMu; nothing holding updMu waits for slotMu or the worker. update.check does not take n.mu
// (design D-12): it runs batman-slot precheck-node, which can take seconds.

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strconv"
	"strings"
	"sync"
	"time"

	"batman-prov/cbor"
	"batman-prov/release"
)

// UpdateSys is every side effect of the update verbs (the real one lives in cmd/, tests fake it).
type UpdateSys interface {
	Trust() release.Trust                                     // the image's root key from /rom (read once)
	Build() (version, board string)                           // /etc/batman-build BATMAN_VERSION / BATMAN_BOARD (full, e.g. ekh-bcm2711)
	MemAvailable() (uint64, bool)                             // /proc/meminfo MemAvailable, bytes
	Uptime() int                                              // s
	BootID() string                                           // /proc/sys/kernel/random/boot_id
	ActiveSlot() string                                       // "A" | "B"
	PreSave()                                                 // §3.3 F63: a p5 stale only in P3's new keys is saved once
	Slot(timeout time.Duration, args ...string) (int, string) // batman-slot (write/arm/disarm/bootinfo/precheck-node in a private mount namespace)
}

const (
	updCheckEvery   = 10 * time.Second // helper-wide, on top of provd's per-connection quota (§3.7.4, A5-m4)
	pendingTTL      = 30 * 60          // s of uptime
	ramReserve      = 64 << 20
	slotInfoRetry14 = 60  // s: a busy bootinfo (an orphan write of the previous helper) is re-read soon
	slotInfoRetry   = 600 // s: a broken bootinfo is re-read at most every 10 minutes
	tBootinfo       = 30 * time.Second
	tPrecheck       = 120 * time.Second // precheck-node runs batman-config-save --check
)

// slot-op exit classes (batman-slot header, §3.7.3) -> reason codes; 14 is E_BUSY (busy = true)
func slotReason(rc int) (reason uint64, busy bool) {
	switch rc {
	case 0:
		return 0, false
	case 10:
		return 1, false
	case 11:
		return 12, false
	case 12:
		return 17, false
	case 13:
		return release.ReasonBad, false
	case 14:
		return 0, true
	case 15:
		return release.ReasonBootCfg, false
	case 16:
		return 2, false
	}
	return 21, false // 17 / 18 / 124 / 127 / killed / anything else: the node cannot write a slot now
}

// slotInfo is one slot's `batman-slot bootinfo` (the helper never mounts a FAT itself, §3.7.3).
type slotInfo struct {
	Verified     string // "<64 hex> <boot_id>" or ""
	Bad          bool
	BootCfg      string // sha256(config.txt ‖ distroconfig.txt), hex
	Distroconfig string
}

// parseBootinfo: stdout only; every header line exactly once, before "--", hex where hex is due (§3.7.3).
func parseBootinfo(out string) (slotInfo, bool) {
	var si slotInfo
	head, body, ok := strings.Cut(out, "\n--\n")
	if !ok {
		return si, false
	}
	seen := map[string]bool{}
	for _, l := range strings.Split(head, "\n") {
		k, v, ok := strings.Cut(l, "=")
		if !ok || seen[k] {
			return si, false
		}
		seen[k] = true
		switch k {
		case "verified":
			if v != "-" {
				f := strings.Fields(v)
				if len(f) != 2 || !isHex(f[0], 64) || len(f[1]) != 36 {
					return si, false
				}
				si.Verified = v
			}
		case "bad":
			if v != "0" && v != "1" {
				return si, false
			}
			si.Bad = v == "1"
		case "bootcfg":
			if !isHex(v, 64) {
				return si, false
			}
			si.BootCfg = v
		default:
			return si, false
		}
	}
	if !seen["verified"] || !seen["bad"] || !seen["bootcfg"] {
		return si, false
	}
	si.Distroconfig = body
	return si, true
}

func isHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil && strings.ToLower(s) == s
}

// pending: the release an owner checked (tmpfs, this boot only).
type pending struct {
	R      *release.Release
	Owner  []byte
	BootID string
	Expiry int // uptime s
}

type updater struct {
	sys    UpdateSys
	slotMu sync.Mutex // every batman-slot call of the helper
	updMu  sync.Mutex // pending, window, worker state, update-last

	sigCache  map[string]*release.Release // manifest sha256 -> verified release (pure, §3.7.4)
	lastCheck time.Time
	pend      *pending
	window    *window
	working   bool
	failSha   []byte // the last worker failure of this helper lifetime, and its sha (§3.7.4 row 3)
	failWhy   uint64

	slots    map[string]slotInfo
	slotsAt  map[string]int // uptime of the last attempt
	slotsBad map[string]int // 0 = fresh; else the retry interval
}

// window is the upload window (§3.8.2); defined here, used by bulk.open (slice 3).
type window struct {
	Owner  []byte
	Expiry int
	Bearer []byte
}

// SetUpdateSource wires the update verbs; nil (tests that do not care) = E_UNSUPPORTED.
func (n *Node) SetUpdateSource(s UpdateSys) {
	n.upd = &updater{sys: s, sigCache: map[string]*release.Release{}, slots: map[string]slotInfo{},
		slotsAt: map[string]int{}, slotsBad: map[string]int{}}
}

func other(s string) string {
	if s == "A" {
		return "B"
	}
	return "A"
}

// slotInfoOf reads (or returns the cached) bootinfo of slot s. Caller holds slotMu.
func (u *updater) slotInfoOf(s string, refresh bool) (slotInfo, bool) {
	now := u.sys.Uptime()
	if si, ok := u.slots[s]; ok && !refresh && u.slotsBad[s] == 0 {
		return si, true
	}
	if !refresh && u.slotsBad[s] != 0 && now-u.slotsAt[s] < u.slotsBad[s] {
		si, ok := u.slots[s]
		return si, ok
	}
	u.slotsAt[s] = now
	rc, out := u.sys.Slot(tBootinfo, "bootinfo", s)
	if rc != 0 {
		if rc == 14 {
			u.slotsBad[s] = slotInfoRetry14
		} else {
			u.slotsBad[s] = slotInfoRetry
		}
		si, ok := u.slots[s]
		return si, ok
	}
	si, ok := parseBootinfo(out)
	if !ok {
		u.slotsBad[s] = slotInfoRetry
		old, had := u.slots[s]
		return old, had
	}
	u.slots[s], u.slotsBad[s] = si, 0
	return si, true
}

// updateCheck: update.check {1: manifest, 2: owner key id (provd's session owner; only used to keep two owners'
// pendings apart — prepare / apply / bulk.open are owner-ops)}.
func (n *Node) updateCheck(a cbor.Map) (cbor.Map, *Error) {
	u := n.upd
	if u == nil {
		return nil, fail(EUnsupported, "update verbs not wired")
	}
	if e := onlyKeys(a, 1, 2); e != nil {
		return nil, e
	}
	mf, e := bytesArg(a, 1, 0)
	if e != nil {
		return nil, e
	}
	owner, e := bytesArg(a, 2, 0)
	if e != nil {
		return nil, e
	}
	if len(mf) > 64<<10 {
		return nil, fail(ESchema, "manifest larger than 64 KiB")
	}
	no := func(reason uint64, ram uint64, why string) (cbor.Map, *Error) {
		n.Log("update.check: refused, reason %d (%s)", reason, why)
		return cbor.M(1, false, 2, reason, 3, ram), nil
	}
	// the helper-wide rate (1 / 10 s) and the busy states first: nothing below runs for a refused caller
	u.updMu.Lock()
	now := n.now()
	if !u.lastCheck.IsZero() && now.Sub(u.lastCheck) < updCheckEvery {
		u.updMu.Unlock()
		return nil, fail(ERate, "update.check: 1 / 10 s")
	}
	u.lastCheck = now
	if u.working || u.window != nil {
		u.updMu.Unlock()
		return nil, fail(EBusy, "an update is being uploaded or written")
	}
	if p := u.pend; p != nil && p.BootID == u.sys.BootID() && u.sys.Uptime() < p.Expiry &&
		subtle.ConstantTimeCompare(p.Owner, owner) != 1 {
		u.updMu.Unlock()
		return nil, fail(EBusy, "another owner's update is pending")
	}
	// 1. the signature chain — cached by the sha256 of the WHOLE manifest (pure: no node state in it, A10-m2)
	sumHex := shaHex(mf)
	r := u.sigCache[sumHex]
	u.updMu.Unlock()
	var ram uint64
	if r == nil {
		var re *release.Error
		r, re = release.Verify(mf, u.sys.Trust())
		if re != nil {
			return no(re.Reason, 0, re.Why)
		}
		u.updMu.Lock()
		if len(u.sigCache) >= 8 {
			u.sigCache = map[string]*release.Release{}
		}
		u.sigCache[sumHex] = r
		u.updMu.Unlock()
	}
	ram = r.Size + r.BootTotal
	// 2. P3's new PRESERVE keys may leave p5 stale on a node upgraded by ssh: save once (§3.3 F63)
	u.sys.PreSave()
	// 3. + 4. node checks (every call — they change: .txn, p5, trial) and the target's boot config, inside slotMu
	ver, board := u.sys.Build()
	if r.Board != board {
		return no(release.ReasonBoard, ram, "payload for "+r.Board+", this node is "+board)
	}
	if reason, why := release.Decide(ver, r); reason != 0 {
		return no(reason, ram, why)
	}
	u.slotMu.Lock()
	rc, out := u.sys.Slot(tPrecheck, "precheck-node")
	var si slotInfo
	okSI := true
	if rc == 0 && len(r.BootCfg) > 0 {
		si, okSI = u.slotInfoOf(other(u.sys.ActiveSlot()), true)
	}
	u.slotMu.Unlock()
	if reason, busy := slotReason(rc); busy {
		return nil, fail(EBusy, "batman-slot busy (%s)", lastLineOf(out))
	} else if reason != 0 {
		return no(reason, ram, "precheck-node rc "+itoa(rc)+": "+lastLineOf(out))
	}
	if len(r.BootCfg) > 0 {
		if !okSI {
			return no(21, ram, "the target slot's boot config is unreadable")
		}
		match := false
		for _, h := range r.BootCfg {
			if hex.EncodeToString(h) == si.BootCfg {
				match = true
			}
		}
		if !match {
			return no(release.ReasonBootCfg, ram, "the target slot's boot config "+si.BootCfg+" is not one this release allows")
		}
	}
	// 5. RAM: MemAvailable - 64 MiB >= payload + boot members (§3.7.4)
	if avail, ok := u.sys.MemAvailable(); !ok || avail < ramReserve || avail-ramReserve < ram {
		return no(8, ram, "not enough RAM for the upload")
	}
	// 6. pending (the state may have changed while the checks ran: re-check under updMu)
	u.updMu.Lock()
	defer u.updMu.Unlock()
	if u.working || u.window != nil {
		return nil, fail(EBusy, "an update is being uploaded or written")
	}
	if p := u.pend; p != nil && p.BootID == u.sys.BootID() && u.sys.Uptime() < p.Expiry &&
		subtle.ConstantTimeCompare(p.Owner, owner) != 1 {
		return nil, fail(EBusy, "another owner's update is pending")
	}
	u.pend = &pending{R: r, Owner: append([]byte(nil), owner...), BootID: u.sys.BootID(), Expiry: u.sys.Uptime() + pendingTTL}
	n.Log("update.check: %s accepted, pending until uptime %d", r.Version, u.pend.Expiry)
	return cbor.M(1, true, 3, ram), nil
}

// validPending: the pending of this boot, unexpired. Caller holds updMu.
func (u *updater) validPending() *pending {
	p := u.pend
	if p == nil || p.BootID != u.sys.BootID() || u.sys.Uptime() >= p.Expiry {
		return nil
	}
	return p
}

func shaHex(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func itoa(i int) string      { return strconv.Itoa(i) }

func lastLineOf(s string) string {
	l := strings.Split(strings.TrimSpace(s), "\n")
	return l[len(l)-1]
}
