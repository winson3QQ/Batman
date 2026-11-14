module batman-sigverify

go 1.26.4

require batman-prov v0.0.0

// the node's own verifier: batman-prov/proto (standard library only)
replace batman-prov => ../../../feed/batman-prov/src
