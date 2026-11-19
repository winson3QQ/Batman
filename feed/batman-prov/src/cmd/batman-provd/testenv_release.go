//go:build !prov_test

package main

import "batman-prov/provd"

// A release provd has no test switches and no frame socket: this file, built without the prov_test tag, reads no
// environment. The firmware build's check-prov-test-gate refuses an image whose provd or helper has a test seam.
func testEnv(func(string, ...any)) provd.TestEnv { return provd.TestEnv{} }

func serveSock(*provd.Server, func(string, ...any)) error { panic("unreachable") }
