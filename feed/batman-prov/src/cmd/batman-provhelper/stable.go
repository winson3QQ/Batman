package main

// provd-stable (254-p3-impl §3.7.6 (b)): when a connection of THE provd (F11: its PPid is the batman-provd procd
// instance — ujail —, its uid 471, its exe /usr/bin/batman-provd) has been open for 60 s, write
// $RUNDIR/provd-stable = this boot_id. autocommit reads it before it commits a trial.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

var (
	provdExe     = "/usr/bin/batman-provd"
	procDir      = "/proc"
	stableAfter  = 60 * time.Second
	provdService = "batman-provd"
)

type stableWriter struct {
	path string // $RUNDIR/provd-stable
	done atomic.Bool
}

// onPeer: sock.Server.OnPeer
func (w *stableWriter) onPeer(pid, uid int, closed <-chan struct{}) {
	if w.done.Load() || uid != provdUID {
		return
	}
	after, exe := stableAfter, provdExe // taken now: the goroutine never reads a setting that may change under it
	go func() {
		select {
		case <-closed:
			return
		case <-time.After(after):
		}
		if w.done.Load() || !isProvdExe(pid, exe) {
			return
		}
		if err := writeStable(w.path, bootID()); err != nil {
			logf("provd-stable: %v", err)
			return
		}
		w.done.Store(true)
		logf("provd stable for %s: %s written", after, w.path)
	}()
}

// isProvd: exe = /usr/bin/batman-provd and PPid = the batman-provd instance pid procd reports
func isProvd(pid int) bool { return isProvdExe(pid, provdExe) }

func isProvdExe(pid int, want string) bool {
	exe, err := os.Readlink(filepath.Join(procDir, strconv.Itoa(pid), "exe"))
	if err != nil || exe != want {
		return false
	}
	b, err := os.ReadFile(filepath.Join(procDir, strconv.Itoa(pid), "status"))
	if err != nil {
		return false
	}
	ppid := -1
	for _, l := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(l, "PPid:"); ok {
			ppid, _ = strconv.Atoi(strings.TrimSpace(v))
		}
	}
	ip := instancePid()
	return ppid > 0 && ip > 0 && ppid == ip
}

// instancePid: ubus call service list {"name": "batman-provd"} -> the running instance's pid (0 = none / unknown)
func instancePid() int {
	rc, out := run(nil, "ubus", "call", "service", "list", `{"name":"`+provdService+`"}`)
	if rc != 0 {
		return 0
	}
	var sl map[string]struct {
		Instances map[string]struct {
			Running bool `json:"running"`
			Pid     int  `json:"pid"`
		} `json:"instances"`
	}
	if json.Unmarshal([]byte(out), &sl) != nil {
		return 0
	}
	pid := 0
	for _, in := range sl[provdService].Instances {
		if in.Running && in.Pid > 0 {
			if pid != 0 {
				return 0 // more than one instance: not the layout F11 describes
			}
			pid = in.Pid
		}
	}
	return pid
}

func writeStable(path, boot string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(boot+"\n"), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
