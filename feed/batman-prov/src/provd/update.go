package provd

// update/check and update/status (254-p3-impl §3.1-3): the owner role, no owner-op. update/prepare, update/apply,
// bulk/open and bulk/close are owner-ops forwarded as the whole envelope (route's forward table).

import (
	"time"

	"batman-prov/cbor"
)

const checkEvery = 10 * time.Second // §3.1-9: update/check 1 / 10 s per connection

// updateCheck: update-check-req {1: update-manifest} -> the helper's update.check {1: manifest bytes, 2: owner key id}.
// provd decoded the request strictly (canonical CBOR), so re-encoding gives back the bytes the app sent: the helper
// verifies them (the signature covers S, not this encoding) and caches by their sha256.
func (ss *Session) updateCheck(id uint64, body cbor.Map) cbor.Map {
	mv, ok := body.Get(1)
	m, isMap := mv.(cbor.Map)
	if !ok || !isMap {
		return errEnv(id, EBadObject, nil)
	}
	mf, err := cbor.Encode(m)
	if err != nil {
		return errEnv(id, EBadObject, nil)
	}
	ss.mu.Lock()
	tooSoon := !ss.checkAt.IsZero() && time.Since(ss.checkAt) < checkEvery
	if !tooSoon {
		ss.checkAt = time.Now()
	}
	kid := ss.ownerKID
	ss.mu.Unlock()
	if tooSoon {
		return errEnv(id, ERate, nil)
	}
	if kid == nil {
		return errEnv(id, EForbidden, nil)
	}
	r, e := ss.ops(id, "update.check", cbor.M(1, mf, 2, kid))
	if e != nil {
		return e
	}
	if r.Code != hOK {
		return ss.mapHelperR(id, "update/check", r)
	}
	return okEnv(id, r.Body) // update-check-resp: a refusal is an ok answer {1: false, 2: reason, 3: RAM}
}

// updateStatus: update/status (empty body) -> update.status on the ro connection -> update-progress
func (ss *Session) updateStatus(id uint64, body cbor.Map) cbor.Map {
	if len(body) != 0 {
		return errEnv(id, EBadObject, nil)
	}
	r, err := ss.srv.roCall("update.status", cbor.M())
	if err != nil {
		return errEnv(id, EBusy, nil)
	}
	if r.Code != hOK {
		return ss.mapHelperR(id, "update/status", r)
	}
	return okEnv(id, r.Body)
}
