package main

// netquiet_test.go — PROVCLIENT_NET_QUIET (254-v16-ud §3.1): with the flag, a net-apply line names no mesh id or hash of
// it and NETCFG is not printed; without it the output is as before (mesh_id_sha=, NETCFG).

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"
)

func capture(f func()) string {
	r, w, _ := os.Pipe()
	old := os.Stdout
	os.Stdout = w
	f()
	w.Close()
	os.Stdout = old
	var b bytes.Buffer
	io.Copy(&b, r)
	return b.String()
}

func TestNetQuiet(t *testing.T) {
	const id = "bench-mesh-id-xyz"
	cfg := []byte("signed config naming " + id)
	t.Setenv("PROVCLIENT_NET_QUIET", "1")
	q := meshField(id) + capture(func() { printNetcfg(cfg) })
	if q != "mesh_id=withheld" || strings.Contains(q, id) || strings.Contains(q, short([]byte(id))) {
		t.Fatalf("quiet output %q", q)
	}
	t.Setenv("PROVCLIENT_NET_QUIET", "")
	l := meshField(id)
	n := capture(func() { printNetcfg(cfg) })
	if l != "mesh_id_sha="+short([]byte(id)) || !strings.HasPrefix(n, "NETCFG ") {
		t.Fatalf("default output changed: %q / %q", l, n)
	}
}
