package provd

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// vector gatt_framing: noise_nx.msg1 in 20 B frames
func TestSplitVector(t *testing.T) {
	fr := Split(vhex(t, "noise_nx.msg1"), 20)
	g := vecs["gatt_framing"].(map[string]any)["frames"].([]any)
	if len(fr) != len(g) {
		t.Fatalf("%d frames", len(fr))
	}
	for i := range fr {
		if hex.EncodeToString(fr[i]) != g[i].(string) {
			t.Fatalf("frame %d: %x", i, fr[i])
		}
	}
	var r Reassembler
	var got []byte
	for i, f := range fr {
		m, done, err := r.Push(f)
		if err != nil || done != (i == len(fr)-1) {
			t.Fatalf("push %d: %v %v", i, done, err)
		}
		got = m
	}
	if !bytes.Equal(got, vhex(t, "noise_nx.msg1")) {
		t.Fatal("reassembly")
	}
}

func TestReassemblerAborts(t *testing.T) {
	f := Split(bytes.Repeat([]byte{7}, 100), 20)
	cases := map[string][][]byte{
		"seq jump":                {f[0], f[2]},
		"no start while idle":     {f[1]},
		"start while active":      {f[0], f[0]},
		"start with seq 1":        {{FlagStart, 0, 1, 9}},
		"unknown flag bit":        {{0x05, 0, 0, 9}},
		"frame shorter than head": {{FlagStart, 0}},
		"frame > 512":             {append([]byte{FlagStart | FlagEnd, 0, 0}, make([]byte, 510)...)},
	}
	for name, seq := range cases {
		var r Reassembler
		var err error
		for _, x := range seq {
			if _, _, err = r.Push(x); err != nil {
				break
			}
		}
		if err == nil {
			t.Fatalf("%s accepted", name)
		}
	}
	// accumulated > max_msg aborts
	var r Reassembler
	var err error
	for _, x := range Split(make([]byte, MaxMsg+1), MaxFrame) {
		if _, _, err = r.Push(x); err != nil {
			break
		}
	}
	if err == nil {
		t.Fatal("a message over max_msg accepted")
	}
	// exactly max_msg passes; 1 B and an exact multiple of the frame size too
	for _, n := range []int{1, 17, 34, MaxMsg} {
		var r Reassembler
		var got []byte
		for _, x := range Split(bytes.Repeat([]byte{3}, n), 20) {
			m, done, err := r.Push(x)
			if err != nil {
				t.Fatalf("%d B: %v", n, err)
			}
			if done {
				got = m
			}
		}
		if len(got) != n {
			t.Fatalf("%d B reassembled to %d", n, len(got))
		}
	}
}
