package main

import "testing"

func TestRejectDifferentSource(t *testing.T) {
	if _, err := patched([]byte("package tun\n")); err == nil {
		t.Fatal("accepted source outside the exact pinned checksum")
	}
}
