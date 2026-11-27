//go:build !prov_test

package se608

// failPending is the se-fail seam's hook (fail_provtest.go). A release build has no way to arm it.
func failPending() bool { return false }
