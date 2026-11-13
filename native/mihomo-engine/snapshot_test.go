package engine

import (
	"bytes"
	"context"
	"errors"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestActualRawDecodePreservesEffectiveYAML(t *testing.T) {
	source := []byte("# effective document\nmode: global\nipv6: false\nmixed-port: 9180\nx-extra: &extra {keep: this}\nproxies:\n  - {name: local, type: direct}\nproxy-groups:\n  - {name: select, type: select, proxies: [local]}\nrules: [MATCH,local]\n")
	original := bytes.Clone(source)
	home, path := C.Path.HomeDir(), C.Path.Config()
	snapshot, err := Decode(context.Background(), source, RevisionOf(source))
	if err != nil {
		t.Fatal(err)
	}
	source[0] = '!'
	if !bytes.Equal(snapshot.Bytes(), original) {
		t.Fatal("caller mutation changed source")
	}
	copy := snapshot.Bytes()
	copy[0] = '!'
	if !bytes.Equal(snapshot.Bytes(), original) {
		t.Fatal("returned source aliases storage")
	}
	raw, err := snapshot.Raw(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if raw.Mode.String() != "global" || raw.IPv6 || raw.MixedPort != 9180 || !raw.Profile.StoreSelected {
		t.Fatalf("actual upstream decode/defaults: %#v", raw)
	}
	raw.Proxy[0]["name"] = "mutated"
	again, err := snapshot.Raw(context.Background())
	if err != nil || again.Proxy[0]["name"] != "local" {
		t.Fatalf("raw object aliases snapshot: %v", err)
	}
	if C.Path.HomeDir() != home || C.Path.Config() != path {
		t.Fatal("raw decoding changed process paths")
	}
}

func TestRawDecodeRejectsMalformedTypedAndMultipleDocuments(t *testing.T) {
	for _, source := range []string{
		"", "# only a comment", "null\n", "{}\n", "[a,b]\n",
		"mode: [broken\n", "mode: not-a-mode\n", "mixed-port: nope\n",
		"mode: rule\n---\nmode: global\n", "mode: rule\n---\n",
		"mode: rule\nmode: global\n", "-----BEGIN AGE ENCRYPTED FILE-----\nbogus\n",
	} {
		t.Run(source, func(t *testing.T) {
			data := []byte(source)
			snapshot, err := Decode(context.Background(), data, RevisionOf(data))
			if err == nil || snapshot != nil {
				t.Fatalf("invalid document accepted: %q", source)
			}
		})
	}
}

func TestRawDecodeCancelsAndRejectsStaleBytes(t *testing.T) {
	data := []byte("mode: rule\n")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Decode(ctx, data, RevisionOf(data)); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if _, err := Decode(context.Background(), data, RevisionOf([]byte("mode: global\n"))); !errors.Is(err, ErrStale) {
		t.Fatal(err)
	}
}

func TestRawDecodeDoesNotInitializeGeodataProvidersOrListeners(t *testing.T) {
	// All paths/hosts below would fail or require I/O during semantic startup.
	// Raw decoding must preserve them without opening a path, fetching a URL,
	// constructing a listener, or pretending they have been validated.
	data := []byte("geox-url:\n  geoip: https://127.0.0.1:1/geoip.dat\nproxy-providers:\n  remote: {type: http, url: https://127.0.0.1:1/provider}\nrule-providers:\n  absent: {type: file, behavior: domain, path: /does-not-exist.yaml}\ntun: {enable: true}\nrules: [GEOIP,CN,DIRECT]\n")
	snapshot, err := Decode(context.Background(), data, RevisionOf(data))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := snapshot.Raw(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !raw.Tun.Enable || raw.RuleProvider["absent"]["path"] != "/does-not-exist.yaml" {
		t.Fatal("raw options were silently removed")
	}
}
