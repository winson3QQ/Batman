package node

// The upload window (254-p3-impl §3.8.2): bulk.open / bulk.close (owner-ops, under n.mu) and the poll's http field.

import (
	"crypto/rand"
	"crypto/subtle"

	"batman-prov/cbor"
)

const (
	windowSecs   = 900 // bulk.open reply key 5
	windowGrace  = 300 // the pending lives until the window's end + 5 min
	httpPort     = 8095
	purposeImage = 0
)

// BulkSys is what the upload window needs from the system (the helper's real one runs ubus / nft / fstatfs).
type BulkSys interface {
	// HTTPAddr: br-ahwlan's IPv4, only while the helper's background check (every 4 s, fresh <= 10 s) saw both nft
	// tables, their rules and the phy* premise (§3.8.1). The poll path reads it: no child process (readonly.go).
	HTTPAddr() (string, bool)
	// AP: the phone AP (network.wireless status: radio0 up with an AP iface) and its ssid / passphrase (ops path)
	AP() (up bool, ssid, pass string)
	// BulkTmpfs: the bulk dir is provd's tmpfs and a mount point of its own (fstatfs on a fresh dirfd, st_dev != the
	// parent's), else nil means OK
	BulkTmpfs() error
}

// SetBulkSource wires bulk.open / bulk.close and the poll's http field (nil = E_UNSUPPORTED, no http field).
func (n *Node) SetBulkSource(b BulkSys) { n.bulk = b }

// bulkOpen: bulk.open {1: purpose 0, 2: sha, 31: owner-op}
func (n *Node) bulkOpen(signer []byte, body cbor.Map) (cbor.Map, *Error) {
	u := n.upd
	if u == nil || u.fs == nil || n.bulk == nil {
		return nil, fail(EUnsupported, "bulk verbs not wired")
	}
	if e := onlyKeys(body, 1, 2, 31); e != nil {
		return nil, e
	}
	if p, ok := getUint(body, 1); !ok || p != purposeImage {
		return nil, fail(ESchema, "body key 1: purpose 0")
	}
	sha, ok := getBytes(body, 2)
	if !ok || len(sha) != 32 {
		return nil, fail(ESchema, "body key 2: a sha256")
	}
	owner := ownerID(signer)
	// the checks that run a child process: before updMu (the tick and the poll must not wait on them)
	up, ssid, pass := n.bulk.AP()
	addr, httpOK := n.bulk.HTTPAddr()
	tmpErr := n.bulk.BulkTmpfs()
	u.updMu.Lock()
	defer u.updMu.Unlock()
	now := u.sys.Uptime()
	if w := u.window; w != nil && now >= w.Expiry { // expired, the tick has not cleared it yet
		u.window = nil
	}
	p := u.validPending()
	if p == nil || subtle.ConstantTimeCompare(p.R.SumsSha, sha) != 1 || subtle.ConstantTimeCompare(p.Owner, owner) != 1 {
		return nil, failR(EReject, 15, "no pending update of this owner for this sha")
	}
	if u.working {
		return nil, fail(EBusy, "the worker is running")
	}
	if w := u.window; w != nil && subtle.ConstantTimeCompare(w.Owner, owner) != 1 {
		return nil, fail(EBusy, "another owner's upload window is open")
	}
	if !up {
		return nil, failR(EReject, 16, "the phone AP is off")
	}
	if tmpErr != nil {
		n.Log("bulk.open: %v", tmpErr)
		return nil, failR(EReject, 21, "the upload tmpfs is not mounted")
	}
	if !httpOK {
		return nil, failR(EReject, 21, "the HTTP firewall rules are not in place")
	}
	if u.window == nil {
		b := make([]byte, 16)
		if _, err := rand.Read(b); err != nil {
			return nil, fail(EApply, "bearer: %v", err)
		}
		u.window = &window{Owner: owner, Bearer: b}
		u.uploaded = 0
	}
	u.window.Expiry = now + windowSecs // the same owner again = extend the same window, the same bearer
	if p.Expiry < u.window.Expiry+windowGrace {
		p.Expiry = u.window.Expiry + windowGrace
	}
	return cbor.M(1, ssid, 2, pass, 3, addr, 4, uint64(httpPort), 5, uint64(windowSecs), 6, append([]byte(nil), u.window.Bearer...)), nil
}

// bulkClose: bulk.close {31: owner-op}: closes the caller's window (none open = done). Another owner's: reason 15.
func (n *Node) bulkClose(signer []byte, body cbor.Map) (cbor.Map, *Error) {
	u := n.upd
	if u == nil || u.fs == nil || n.bulk == nil {
		return nil, fail(EUnsupported, "bulk verbs not wired")
	}
	if e := onlyKeys(body, 31); e != nil {
		return nil, e
	}
	u.updMu.Lock()
	defer u.updMu.Unlock()
	if w := u.window; w != nil {
		if subtle.ConstantTimeCompare(w.Owner, ownerID(signer)) != 1 {
			return nil, failR(EReject, 15, "the upload window is another owner's")
		}
		u.window = nil
	}
	return cbor.M(), nil
}

// windowOpen: otaBusy counts an open window (§3.1-7)
func (u *updater) windowOpen() bool {
	u.updMu.Lock()
	defer u.updMu.Unlock()
	return u.window != nil && u.sys.Uptime() < u.window.Expiry
}

// httpField: health.get key 2 (§2, §3.8.2) — {2: bind address} only while the firewall check holds; the window keys
// {3: owner key id, 4: seconds left, 5: payload size, 6: bearer, 7: expiry (uptime)} only while it is open; {8: true}
// while the worker runs. Missing keys = no window, no PUT (fail-closed in provd).
func (n *Node) httpField(uploaded uint64, haveUp bool, bindFailed bool) cbor.Map {
	if n.bulk == nil {
		return nil
	}
	n.httpBindFailed.Store(bindFailed)
	m := cbor.M()
	addr, ok := n.bulk.HTTPAddr()
	if ok {
		m = append(m, cbor.Entry{K: uint64(2), V: addr})
	}
	u := n.upd
	if u == nil || u.fs == nil {
		return m
	}
	u.updMu.Lock()
	defer u.updMu.Unlock()
	now := u.sys.Uptime()
	if w := u.window; w != nil && now < w.Expiry && ok {
		if p := u.validPending(); p != nil {
			if haveUp {
				u.uploaded = min(uploaded, p.R.Size)
			}
			m = append(m, cbor.Entry{K: uint64(3), V: append([]byte(nil), w.Owner...)},
				cbor.Entry{K: uint64(4), V: uint64(w.Expiry - now)}, cbor.Entry{K: uint64(5), V: p.R.Size},
				cbor.Entry{K: uint64(6), V: append([]byte(nil), w.Bearer...)}, cbor.Entry{K: uint64(7), V: uint64(w.Expiry)})
		}
	}
	if u.working {
		m = append(m, cbor.Entry{K: uint64(8), V: true})
	}
	return m
}
