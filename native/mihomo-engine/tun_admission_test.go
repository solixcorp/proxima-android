package engine

import (
	"context"
	"strings"
	"testing"
)

func TestTunAdmissionAppOwnedDefaults(t *testing.T) {
	const generated = "find-process-mode: off\nprofile: {store-selected: false}\ntun: {enable: true, stack: mips, mtu: 1400}\nrules: ['MATCH,DIRECT']\n"
	tests := []struct {
		name, tun string
		wantError bool
	}{
		{"omitted upstream defaults", "enable: true, stack: mips, mtu: 1400", false},
		{"explicit safe values", "enable: true, stack: mips, mtu: 1400, auto-route: false, auto-detect-interface: false, inet6-address: []", false},
		{"explicit auto route", "enable: true, stack: mips, mtu: 1400, auto-route: true", true},
		{"explicit interface detection", "enable: true, stack: mips, mtu: 1400, auto-detect-interface: true", true},
		{"explicit upstream IPv6 address", "enable: true, stack: mips, mtu: 1400, inet6-address: ['fdfe:dcba:9876::1/126']", true},
		{"explicit device", "enable: true, stack: mips, mtu: 1400, device: tun0", true},
		{"explicit file descriptor", "enable: true, stack: mips, mtu: 1400, file-descriptor: 123", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			source := []byte(strings.Replace(generated, "enable: true, stack: mips, mtu: 1400", tt.tun, 1))
			snapshot, err := Decode(context.Background(), source, RevisionOf(source))
			if err != nil {
				t.Fatal(err)
			}
			raw, err := snapshot.Raw(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if tt.name == "omitted upstream defaults" && (!raw.Tun.AutoRoute || !raw.Tun.AutoDetectInterface || len(raw.Tun.Inet6Address) == 0) {
				t.Fatalf("upstream defaults changed: %+v", raw.Tun)
			}
			err = admit(source, raw)
			if (err != nil) != tt.wantError {
				t.Fatalf("admit error = %v, want error %v", err, tt.wantError)
			}
			if err == nil && (raw.Tun.AutoRoute || raw.Tun.AutoDetectInterface || len(raw.Tun.Inet6Address) != 0) {
				t.Fatalf("system TUN configuration reached semantic parser: %+v", raw.Tun)
			}
		})
	}
}

// Dart emits JSON (a YAML subset), rather than the block YAML above.
func TestTunAdmissionGeneratedJSON(t *testing.T) {
	source := []byte(`{"mode":"rule","ipv6":false,"log-level":"warning","find-process-mode":"off","profile":{"store-selected":false,"store-fake-ip":false},"tun":{"enable":true,"stack":"mips","mtu":1400},"rules":["MATCH,DIRECT"]}`)
	snapshot, err := Decode(context.Background(), source, RevisionOf(source))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := snapshot.Raw(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := admit(source, raw); err != nil {
		t.Fatal(err)
	}
	if raw.Tun.AutoRoute || raw.Tun.AutoDetectInterface || len(raw.Tun.Inet6Address) != 0 {
		t.Fatalf("system TUN configuration reached semantic parser: %+v", raw.Tun)
	}
}
