package seam

// Point names one killpoint (254-h23 §4.1.1). An integer on purpose: the call sites in node/ compile into the
// release binary too, and a string there would put the point names into it (code review r1 A-m8). The names
// exist only in the prov_test half (seam_provtest.go).
type Point uint8

// The closed list of points; None = no point (commit paths without a killpoint).
const (
	None              Point = iota
	Txn1                    // markers + .txn written, wireless untouched
	Txn2                    // wireless changed (not persisted), p5 not yet
	Txn3                    // p5 holds the new generation (also after --prov-only rc != 0 + read-back), overlay not
	Txn4                    // p5 + overlay committed, .txn gone, --save not done
	Txn5                    // everything written, the reply not sent
	ClaimAfterPersist       // claim: p5 holds the claimed record, the overlay does not
	ClaimBeforeShadow       // claim: claimed in p5 + overlay + p6, not locked, no shadow-root
)
