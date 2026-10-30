# target: boot/boot.go
# prov-unit-helper mutant: the identity-mismatch check is skipped (generations compared first)
s/^	if ovIdent && p5Ident && !bytes.Equal(ovSum, p5Sum) {$/	if false \&\& ovIdent \&\& p5Ident \&\& !bytes.Equal(ovSum, p5Sum) {/
