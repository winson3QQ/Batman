//go:build prov_test

package se608

import "sync/atomic"

// The se-fail seam (255-608b-impl.md §2.2, review v5set-B m12): only in prov_test builds. The white-box chip image
// of PR 2 reads `se-fail=<N>` from the killpoint file (seam.Arm) and calls FailSequences(N); this is the driver's
// half of it.
var failSeq atomic.Int32

// FailSequences makes the next n command sequences (Do calls) fail with ErrNoResponse without touching the bus, as
// a chip that does not answer would; after that the chip is reached again.
func FailSequences(n int) { failSeq.Store(int32(n)) }

func failPending() bool {
	for {
		v := failSeq.Load()
		if v <= 0 {
			return false
		}
		if failSeq.CompareAndSwap(v, v-1) {
			return true
		}
	}
}
