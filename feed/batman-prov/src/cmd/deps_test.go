// Package cmd_test keeps the rig-only code out of what ships (255-608b-impl.md §2.8 "出貨閘門", §9 PR D2).
package cmd_test

import (
	"os/exec"
	"strings"
	"testing"
)

func deps(t *testing.T, tags string, pkgs ...string) map[string]bool {
	t.Helper()
	args := []string{"list", "-deps"}
	if tags != "" {
		args = append(args, "-tags", tags)
	}
	out, err := exec.Command("go", append(args, pkgs...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("go %v: %v\n%s", args, err, out)
	}
	m := map[string]bool{}
	for _, l := range strings.Fields(string(out)) {
		m[l] = true
	}
	if !m["batman-prov/proto"] {
		t.Fatalf("go list -deps %v does not even list batman-prov/proto: the check would pass on nothing\n%s", pkgs, out)
	}
	return m
}

// The two shipped binaries link none of: the experiment commands (se608/lab), the fake chip, or — until PR 2 puts
// the chip backend behind the prov_se tag — the driver itself. When PR 2 lands, the se608 line moves to "only with
// -tags prov_se"; the other two stay for every tag set.
func TestShippedBinariesDoNotLinkRigCode(t *testing.T) {
	shipped := []string{"batman-prov/cmd/batman-provhelper", "batman-prov/cmd/batman-provd"}
	for _, tags := range []string{"", "prov_test"} {
		d := deps(t, tags, shipped...)
		for _, banned := range []string{"batman-prov/se608/lab", "batman-prov/se608/fakechip", "batman-prov/se608", "batman-prov/secert"} {
			if d[banned] {
				t.Errorf("tags %q: a shipped binary links %s", tags, banned)
			}
		}
	}
	// control: the same listing does see the packages where they are linked
	d := deps(t, "", "batman-prov/cmd/se-lab")
	for _, want := range []string{"batman-prov/se608/lab", "batman-prov/se608"} {
		if !d[want] {
			t.Fatalf("control: se-lab's dependencies do not list %s", want)
		}
	}
	if d["batman-prov/se608/fakechip"] {
		t.Error("se-lab itself links the fake chip (only its tests may)")
	}
}
