# target: boot/boot.go
# prov-unit-helper mutant: rc 10 generates when the overlay has no identity
/^	case 10: \/\/ p5 prov incomplete/a\
		if !ovIdent { if r, ok := generate(provstore.Unclaimed); ok { return r } }
