package engine

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/proxydialer"
	C "github.com/metacubex/mihomo/constant"
	wireguard "github.com/metacubex/sing-wireguard"
	"github.com/metacubex/ssh"
	"go.yaml.in/yaml/v3"
	"golang.org/x/sys/unix"
	foundation "proxima.local/mihomo"
	"proxima.local/mihomo/session"
)

func protocolFixtures(t *testing.T) []map[string]any {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	host, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []map[string]any
	for _, value := range []string{
		"type: direct", "type: reject", "type: http", "type: socks5, udp: true",
		"type: ss, cipher: aes-128-gcm, password: secret, udp: true",
		"type: ssr, cipher: aes-128-cfb, password: secret, obfs: plain, protocol: origin, udp: true",
		"type: vmess, uuid: 90d4903e-4bc6-4146-b67a-290c83bdd96a, alterId: 0, cipher: auto, udp: true",
		"type: vless, uuid: 90d4903e-4bc6-4146-b67a-290c83bdd96a, udp: true",
		"type: trojan, password: secret, udp: true",
		"type: snell, psk: secret, version: 3, udp: true",
		"type: hysteria, auth-str: secret, up: 10 Mbps, down: 10 Mbps",
		"type: hysteria2, password: secret",
		"type: tuic, uuid: 90d4903e-4bc6-4146-b67a-290c83bdd96a, password: secret",
		"type: anytls, password: secret, udp: true",
		"type: mieru, username: test, password: secret, transport: TCP, udp: true",
		"type: mieru, username: test, password: secret, transport: UDP, udp: true",
		"type: wireguard, ip: 10.0.0.2, private-key: AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=, public-key: AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=, udp: true, ip-stack: {mode: mips}",
		fmt.Sprintf("type: ssh, username: test, password: secret, host-key: [%q]", strings.TrimSpace(string(ssh.MarshalAuthorizedKey(host)))),
	} {
		var mapping map[string]any
		if err := yaml.Unmarshal([]byte("{name: fixture, server: 127.0.0.1, port: 29473, "+value+"}"), &mapping); err != nil {
			t.Fatal(err)
		}
		if mapping["type"] == "direct" || mapping["type"] == "reject" {
			delete(mapping, "server")
			delete(mapping, "port")
		}
		fixtures = append(fixtures, mapping)
	}
	return fixtures
}

func TestHysteria2SkipCertVerifyAdmission(t *testing.T) {
	for _, tc := range []struct {
		name, option string
		allowed      bool
	}{
		{"default", "", true},
		{"false", ", skip-cert-verify: false", true},
		{"true", ", skip-cert-verify: true", true},
		{"string", ", skip-cert-verify: 'true'", false},
		{"null", ", skip-cert-verify: null", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var mapping map[string]any
			if err := yaml.Unmarshal([]byte("{type: hysteria2"+tc.option+"}"), &mapping); err != nil {
				t.Fatal(err)
			}
			if err := admitProxy(mapping); (err == nil) != tc.allowed {
				t.Fatalf("admission: %v", err)
			}
		})
	}
}

func TestProtocolAdmission(t *testing.T) {
	fd, _ := pair(t)
	p := &refusingProtocolProtector{t: t}
	token, err := foundation.Sessions.Prepare(fd, p)
	if err != nil {
		t.Fatal(err)
	}
	defer foundation.Sessions.Close(token)
	for _, mapping := range protocolFixtures(t) {
		if err := admitProxy(mapping); err != nil {
			t.Fatalf("%s: %v", mapping["type"], err)
		}
		if err := passiveProviderProxy(mapping); err != nil {
			t.Fatal(err)
		}
		// Exercise real constructors, including non-networking timers and cleanup.
		proxy, err := adapter.ParseProxy(mapping)
		if err != nil {
			t.Fatalf("%s constructor: %v", mapping["type"], err)
		}
		if err := proxy.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if p.calls.Load() != 0 {
		t.Fatal("constructor performed unexpected autonomous networking")
	}
	for _, mapping := range []map[string]any{
		{"type": "hysteria", "protocol": "faketcp"},
		{"type": "hysteria", "obfs-protocol": "faketcp"},
		{"type": "hysteria2", "realm-opts": map[string]any{"enable": true}},
		{"type": "hysteria2", "ports": "1000-2000"},
		{"type": "tuic", "disable-sni": true},
		{"type": "http", "skip-cert-verify": false},
		{"type": "http", "certificate": "/etc/private.pem"},
		{"type": "ss", "plugin": "kcptun"},
		{"type": "ss", "plugin": "obfs", "plugin-opts": map[string]any{"mode": "tls", "skip-cert-verify": true}},
		{"type": "snell", "version": 2},
		{"type": "snell", "reuse": true},
		{"type": "vless", "network": "xhttp"},
		{"type": "vless", "network": "ws", "reality-opts": map[string]any{}},
		{"type": "vmess", "network": "mekya"},
		{"type": "vmess", "tlsmirror-opts": map[string]any{}},
		{"type": "vless", "reality-opts": map[string]any{"download": "https://bad.test"}},
		{"type": "wireguard", "ip-stack": map[string]any{"mode": "gvisor"}},
		{"type": "wireguard", "dns": []any{"system"}},
		{"type": "ssh"},
		{"type": "ssh", "host-key": []any{"pin"}, "private-key": "/etc/key"},
		{"type": "anytls", "dialer-proxy": "unsafe"},
		{"type": "socks5", "smux": map[string]any{"enabled": true}},
	} {
		if err := admitProxy(mapping); err == nil {
			t.Fatalf("unsafe option accepted: %v", mapping)
		}
	}
	for _, kind := range []string{"sudoku", "trusttunnel", "masque", "openvpn", "tailscale", "zerotier", "easytier", "shadowquic", "gost-relay", "dns", "rematch", "invented"} {
		if err := admitProxy(map[string]any{"type": kind}); err == nil || !strings.Contains(err.Error(), "not certified") {
			t.Fatalf("%s: %v", kind, err)
		}
	}
}

type refusingProtocolProtector struct {
	t     *testing.T
	calls atomic.Int32
}

func (p *refusingProtocolProtector) Protect(fd int) bool {
	p.calls.Add(1)
	addr, err := unix.Getsockname(fd)
	if err != nil {
		p.t.Error(err)
	}
	switch a := addr.(type) {
	case *unix.SockaddrInet4:
		if a.Port != 0 {
			p.t.Errorf("protected after bind: %d", a.Port)
		}
	case *unix.SockaddrInet6:
		if a.Port != 0 {
			p.t.Errorf("protected after bind: %d", a.Port)
		}
	default:
		p.t.Errorf("unexpected socket: %T", addr)
	}
	if _, err := unix.Getpeername(fd); err == nil {
		p.t.Error("protected after connect")
	}
	return false
}
func (*refusingProtocolProtector) Close() error { return nil }

func TestProtocolSocketRefusal(t *testing.T) {
	fd, _ := pair(t)
	p := &refusingProtocolProtector{t: t}
	token, err := foundation.Sessions.Prepare(fd, p)
	if err != nil {
		t.Fatal(err)
	}
	defer foundation.Sessions.Close(token)
	fixtures := protocolFixtures(t)
	// Audit transport variants independently; refusal happens before the TLS or
	// protocol handshake, so no fake protocol server is required.
	for _, kind := range []string{"vmess", "vless", "trojan"} {
		for _, fixture := range protocolFixtures(t) {
			if fixture["type"] != kind {
				continue
			}
			for _, network := range []string{"tcp", "ws", "grpc"} {
				m := make(map[string]any)
				for k, v := range fixture {
					m[k] = v
				}
				m["network"], m["tls"], m["tfo"] = network, true, true
				if kind == "trojan" {
					delete(m, "tls")
				}
				fixtures = append(fixtures, m)
			}
		}
	}
	fixtures = append(fixtures,
		map[string]any{"name": "reality", "type": "vless", "server": "127.0.0.1", "port": 29473, "uuid": "90d4903e-4bc6-4146-b67a-290c83bdd96a", "tls": true, "client-fingerprint": "chrome", "reality-opts": map[string]any{"public-key": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}},
		map[string]any{"name": "early", "type": "tuic", "server": "127.0.0.1", "port": 29473, "token": "secret", "reduce-rtt": true})
	// ShadowQUIC remains unadmitted; test the real constructor separately to
	// establish UDP coverage, not to assert its transport lifetime is certified.
	fixtures = append(fixtures, map[string]any{"name": "shadow", "type": "shadowquic", "server": "127.0.0.1", "port": 29473, "username": "test", "password": "secret"})
	for _, mapping := range fixtures {
		kind := mapping["type"].(string)
		if kind == "reject" || kind == "wireguard" {
			continue
		}
		for _, network := range []C.NetWork{C.TCP, C.UDP} {
			if network == C.UDP && (kind == "http" || kind == "ssh") {
				continue
			}
			t.Run(fmt.Sprintf("%s/%v/%v/%v", kind, mapping["transport"], mapping["network"], network), func(t *testing.T) {
				proxy, err := adapter.ParseProxy(mapping)
				if err != nil {
					t.Fatal(err)
				}
				defer proxy.Close()
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				before := p.calls.Load()
				metadata := &C.Metadata{NetWork: network, DstIP: netip.MustParseAddr("127.0.0.1"), DstPort: 29474}
				if network == C.TCP {
					conn, dialErr := proxy.DialContext(ctx, metadata)
					err = dialErr
					if conn != nil {
						defer conn.Close()
						if err == nil {
							_, err = conn.Write([]byte("refused"))
						}
					}
				} else {
					conn, dialErr := proxy.ListenPacketContext(ctx, metadata)
					err = dialErr
					if conn != nil {
						defer conn.Close()
						if err == nil {
							_, err = conn.WriteTo([]byte("refused"), metadata.UDPAddr())
						}
					}
				}
				if err == nil || !strings.Contains(err.Error(), session.ErrProtection.Error()) || p.calls.Load() <= before {
					t.Fatalf("refusal bypassed: err=%v protects=%d -> %d", err, before, p.calls.Load())
				}
			})
		}
	}
}

type bindErrorHandler struct{}

func (bindErrorHandler) NewError(context.Context, error) {}

func TestWireGuardOuterSocketRefusal(t *testing.T) {
	fd, _ := pair(t)
	p := &refusingProtocolProtector{t: t}
	token, err := foundation.Sessions.Prepare(fd, p)
	if err != nil {
		t.Fatal(err)
	}
	defer foundation.Sessions.Close(token)
	for _, connected := range []bool{true, false} {
		bind := wireguard.NewClientBind(context.Background(), bindErrorHandler{}, proxydialer.NewSingDialer(dialer.NewDialer()), connected, netip.MustParseAddrPort("127.0.0.1:29473"), [3]byte{})
		if _, _, err := bind.Open(0); err != nil {
			t.Fatal(err)
		}
		before := p.calls.Load()
		endpoint, err := bind.ParseEndpoint("127.0.0.1:29473")
		if err != nil {
			t.Fatal(err)
		}
		err = bind.Send([][]byte{{1, 2, 3, 4}}, endpoint)
		if err == nil || !strings.Contains(err.Error(), session.ErrProtection.Error()) || p.calls.Load() <= before {
			t.Fatalf("wireguard connected=%v err=%v", connected, err)
		}
		if err := bind.Close(); err != nil {
			t.Fatal(err)
		}
	}
}
