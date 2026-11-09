package main

// status.get's sources (docs/design/254-p3-impl.md §3.4): `halow-status json` and `batman-config-save --check`, run
// in the background by node's status cache (never on a request path).

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"batman-prov/provstore"
)

const halowStatusTimeout = 20 * time.Second // 04 (wsl.22): ~0.5 s

func halowStatusJSON() ([]byte, error) {
	rc, out := provstore.Exec(halowStatusTimeout, cleanEnv, nil, "halow-status", "json")
	if rc != 0 {
		return nil, fmt.Errorf("halow-status json: rc %d", rc)
	}
	return []byte(out), nil
}

func p5Fresh() (bool, error) {
	rc, out := provstore.Exec(provstore.ConfigSaveTimeout, cleanEnv, nil, "batman-config-save", "--check")
	return parseCheck(rc, out)
}

// parseCheck: batman-config-save --check says "p5 fresh" (rc 0) or "p5 stale: …" (rc 5); anything else — lock busy
// (rc 8), a timeout, an error — is not an answer (the cache keeps what it had; status omits key 4 when that is old).
func parseCheck(rc int, out string) (bool, error) {
	switch {
	case rc == 0 && strings.Contains(out, "p5 fresh"):
		return true, nil
	case rc == 5 && strings.Contains(out, "p5 stale"):
		return false, nil
	}
	return false, errors.New("batman-config-save --check: no answer (rc " + fmt.Sprint(rc) + ")")
}
