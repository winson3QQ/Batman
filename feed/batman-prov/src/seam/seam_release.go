//go:build !prov_test

// Package seam: the release half. No strings, no file access — the test seams do not exist in a release build
// (docs/design/254-h23-harness.md §4.1.2). The build gate checks the binary for that.
package seam

// Marker is empty in a release build.
const Marker = ""

// Enabled reports whether this binary carries the test seams.
const Enabled = false

// Arm does nothing in a release build.
func Arm(func(string, ...any)) {}

// At does nothing in a release build.
func At(Point, func(string, ...any)) {}
