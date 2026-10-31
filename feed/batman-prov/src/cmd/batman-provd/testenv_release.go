//go:build !prov_test

package main

import "batman-prov/provd"

// A release provd has no test switches and no frame socket: the names do not exist in the binary (release gate:
// strings batman-provd | grep -c -e SOCK_ONLY -e ADV_LEN_TEST -e provd-test = 0).
func testEnv(func(string, ...any)) provd.TestEnv { return provd.TestEnv{} }

func serveSock(*provd.Server, func(string, ...any)) error { panic("unreachable") }
