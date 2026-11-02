package main

import (
	"sync"
	"time"

	"batman-prov/provstore"
)

// trialCache is `batman-slot is-trial` for info.state key 5 and the health tick's Committed() (254-p2-impl §1.3,
// F-P27 / F-P52 / F-P63): a value <= maxAge old is served as is; an older one is served while ONE refresh runs
// (stale-while-revalidate, single-flight); with no value yet the caller waits for the refresh. The exec has a 5 s
// deadline (a stuck SD card must not hold provd's ctl poll). Fail-closed like IsTrial: anything but rc 1 = trial.
type trialCache struct {
	mu       sync.Mutex
	cond     *sync.Cond
	have     bool
	trial    bool
	at       time.Time
	inflight bool
	maxAge   time.Duration
	isTrial  func() bool // the exec
}

func newTrialCache(maxAge time.Duration, isTrial func() bool) *trialCache {
	c := &trialCache{maxAge: maxAge, isTrial: isTrial}
	c.cond = sync.NewCond(&c.mu)
	return c
}

// execIsTrial: batman-slot is-trial with a 5 s deadline; rc != 1 (incl. the timeout's 124) = trial.
func execIsTrial() bool {
	rc, _ := provstore.Exec(5*time.Second, cleanEnv, nil, "batman-slot", "is-trial")
	return rc != 1
}

func (c *trialCache) refresh() {
	v := c.isTrial()
	c.mu.Lock()
	c.trial, c.at, c.have, c.inflight = v, time.Now(), true, false
	c.cond.Broadcast()
	c.mu.Unlock()
}

// Trial returns the cached is-trial.
func (c *trialCache) Trial() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.have && time.Since(c.at) <= c.maxAge {
		return c.trial
	}
	if !c.inflight {
		c.inflight = true
		go c.refresh()
	}
	if c.have {
		return c.trial
	}
	for !c.have {
		c.cond.Wait()
	}
	return c.trial
}
