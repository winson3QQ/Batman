# target: boot/boot.go
# prov-unit-helper mutant: rc 9 generates a NEW identity even with a complete overlay (254-p1-impl §5.1). The identity is
# removed first: generate() refuses to overwrite one (run 1: a plain generate() call fell through and the mutant was inert)
/^	case 9: \/\/ seeded, no prov/a\
		os.RemoveAll(e.P.Identity()); if r, ok := generate(provstore.Legacy); ok { return r }
