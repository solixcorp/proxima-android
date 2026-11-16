package engine

import (
	"fmt"
	"strings"

	"github.com/metacubex/mihomo/config"
	"proxima.local/mihomo-provider/boundary"
)

// This is a capability list, not the upstream decoder's complete option set.
// In particular, new transport options must not become accepted implicitly.
// Socket/constructor evidence for each entry is in DIALERS.md.
var protocolKeys = map[string]string{
	"direct": "", "reject": "",
	"http":      "server port username password tls sni headers",
	"socks5":    "server port username password tls udp",
	"ss":        "server port password cipher udp udp-over-tcp udp-over-tcp-version plugin plugin-opts client-fingerprint",
	"ssr":       "server port password cipher obfs obfs-param protocol protocol-param udp",
	"vmess":     "server port uuid alterId cipher udp network tls alpn servername client-fingerprint ws-opts http-opts h2-opts grpc-opts packet-addr xudp packet-encoding global-padding authenticated-length reality-opts",
	"vless":     "server port uuid flow udp network tls alpn servername client-fingerprint ws-opts http-opts h2-opts grpc-opts packet-addr xudp packet-encoding reality-opts",
	"trojan":    "server port password udp network alpn sni client-fingerprint ws-opts grpc-opts reality-opts",
	"snell":     "server port psk udp version obfs-opts",
	"hysteria":  "server port up down up-speed down-speed auth auth-str obfs sni alpn protocol recv-window-conn recv-window disable-mtu-discovery fast-open",
	"hysteria2": "server port password up down obfs obfs-password obfs-min-packet-size obfs-max-packet-size sni alpn skip-cert-verify cwnd bbr-profile udp-mtu handshake-timeout initial-stream-receive-window max-stream-receive-window initial-connection-receive-window max-connection-receive-window",
	"tuic":      "server port token uuid password ip heartbeat-interval alpn reduce-rtt request-timeout udp-relay-mode congestion-controller max-udp-relay-packet-size fast-open max-open-streams cwnd bbr-profile recv-window-conn recv-window disable-mtu-discovery max-datagram-frame-size sni udp-over-stream udp-over-stream-version",
	"wireguard": "server port ip ipv6 private-key public-key pre-shared-key reserved mtu udp workers persistent-keepalive ip-stack",
	"ssh":       "server port username password private-key private-key-passphrase host-key host-key-algorithms",
	"anytls":    "server port password alpn sni client-fingerprint udp client-metadata idle-session-check-interval idle-session-timeout min-idle-session disable-reuse",
	"mieru":     "server port port-range transport udp username password multiplexing handshake-mode traffic-pattern",
}

var transportKeys = map[string]string{
	"ws-opts":   "path headers max-early-data early-data-header-name v2ray-http-upgrade v2ray-http-upgrade-fast-open",
	"http-opts": "method path headers", "h2-opts": "host path",
	"grpc-opts":    "grpc-service-name grpc-user-agent ping-interval max-connections min-streams max-streams",
	"reality-opts": "public-key short-id support-x25519mlkem768",
	"ip-stack":     "mode congestion-controller",
}

func onlyKeys(mapping map[string]any, allowed, where string) error {
	for key := range mapping {
		found := false
		for _, candidate := range strings.Fields(allowed) {
			if key == candidate {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("%s: option %q not admitted (socket/resource audit required)", where, key)
		}
	}
	return nil
}

func admitProxy(mapping map[string]any) error {
	kind, _ := mapping["type"].(string)
	keys, ok := protocolKeys[kind]
	if !ok {
		return fmt.Errorf("proxy type %q not admitted: independent transport/constructor lifetime not certified; see DIALERS.md", kind)
	}
	if err := onlyKeys(mapping, "name type ip-version tfo "+keys, "proxy "+kind); err != nil {
		return err
	}
	if value, exists := mapping["skip-cert-verify"]; kind == "hysteria2" && exists {
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("hysteria2 skip-cert-verify must be a boolean")
		}
	}
	for key, allowed := range transportKeys {
		if v, exists := mapping[key]; exists {
			m, ok := v.(map[string]any)
			if !ok {
				return fmt.Errorf("%s must be an explicit mapping", key)
			}
			if err := onlyKeys(m, allowed, key); err != nil {
				return err
			}
			if key == "ip-stack" && m["mode"] != "mips" {
				return fmt.Errorf("wireguard ip-stack.mode must explicitly be mips")
			}
		}
	}
	if network, exists := mapping["network"]; exists {
		s, ok := network.(string)
		if !ok || !strings.Contains(" tcp ws http h2 grpc ", " "+s+" ") || (kind == "trojan" && (s == "http" || s == "h2")) {
			return fmt.Errorf("proxy %s network %q not audited", kind, network)
		}
	}
	if _, reality := mapping["reality-opts"]; reality && mapping["network"] == "ws" {
		return fmt.Errorf("REALITY over ws is not implemented by the pinned upstream")
	}
	if kind == "ss" {
		if plugin, exists := mapping["plugin"]; exists && plugin != "obfs" {
			return fmt.Errorf("ss only the in-process obfs plugin is admitted")
		}
		if err := admitSimpleObfs(mapping, "plugin-opts"); err != nil {
			return err
		}
	}
	if kind == "snell" {
		// v2 always creates a pool; v4's reuse pool has no adapter Close override.
		if v, exists := mapping["version"]; exists && v != 1 && v != 3 && v != 4 && v != 5 {
			return fmt.Errorf("snell version 2/reuse pool is not admitted")
		}
		if err := admitSimpleObfs(mapping, "obfs-opts"); err != nil {
			return err
		}
	}
	if kind == "hysteria" {
		if p, exists := mapping["protocol"]; exists && p != "udp" && p != "wechat-video" {
			return fmt.Errorf("hysteria protocol %q not admitted: fakeTCP bypasses socket protection and needs raw privileges", p)
		}
	}
	if kind == "ssh" {
		pinned := false
		switch hosts := mapping["host-key"].(type) {
		case []any:
			pinned = len(hosts) > 0
		case []string:
			pinned = len(hosts) > 0
		}
		if !pinned {
			return fmt.Errorf("ssh requires explicit host-key pins (upstream otherwise ignores host identity)")
		}
		if key, exists := mapping["private-key"]; exists {
			s, ok := key.(string)
			if !ok || !strings.Contains(s, "PRIVATE KEY") {
				return fmt.Errorf("ssh private-key must be inline PEM; filesystem key paths are not admitted")
			}
		}
	}
	return nil
}

func admitSimpleObfs(mapping map[string]any, key string) error {
	if v, exists := mapping[key]; exists {
		m, ok := v.(map[string]any)
		if !ok {
			return fmt.Errorf("%s must be mapping", key)
		}
		if err := onlyKeys(m, "mode host", key); err != nil {
			return err
		}
		if mode, exists := m["mode"]; exists && mode != "http" && mode != "tls" && mode != "" {
			return fmt.Errorf("%s only http/tls stream obfuscation admitted", key)
		}
	}
	return nil
}

func admitRouting(raw *config.RawConfig) error {
	// Reject collisions before constructing timer-owning adapters/groups.
	names := map[string]bool{"DIRECT": true, "REJECT": true, "REJECT-DROP": true, "COMPATIBLE": true, "PASS": true, "PASS-RULE": true}
	for _, entries := range [][]map[string]any{raw.Proxy, raw.ProxyGroup} {
		for _, mapping := range entries {
			name, ok := mapping["name"].(string)
			if !ok || name == "" || names[name] {
				return fmt.Errorf("proxy/group name %q missing, reserved or duplicate", name)
			}
			names[name] = true
		}
	}
	for i, mapping := range raw.Proxy {
		if err := admitProxy(mapping); err != nil {
			return fmt.Errorf("proxies[%d]: %w", i, err)
		}
	}
	for i, mapping := range raw.ProxyGroup {
		kind, _ := mapping["type"].(string)
		extra := ""
		switch kind {
		case "select":
		case "url-test":
			extra = "tolerance"
		case "fallback":
		case "load-balance":
			extra = "strategy"
		default:
			return fmt.Errorf("proxy-groups[%d] type %q not admitted", i, kind)
		}
		if err := onlyKeys(mapping, "name type proxies use url interval timeout lazy disable-udp expected-status max-failed-times "+extra, "proxy-group"); err != nil {
			return err
		}
		if url, exists := mapping["url"]; exists {
			s, ok := url.(string)
			if !ok {
				return fmt.Errorf("proxy-group url must be HTTPS")
			}
			if err := boundary.URL(s); err != nil {
				return fmt.Errorf("proxy-group health check: %w", err)
			}
		}
		for _, key := range []string{"interval", "timeout", "max-failed-times", "tolerance"} {
			if value, exists := mapping[key]; exists {
				n, ok := value.(int)
				if !ok || n < 0 || n > 31536000 {
					return fmt.Errorf("proxy-group invalid %s", key)
				}
			}
		}
		if kind == "select" {
			if n, exists := mapping["interval"]; exists && n != 0 {
				return fmt.Errorf("select group interval must be zero")
			}
		}
	}
	for _, rule := range raw.Rule {
		parts := strings.Split(rule, ",")
		kind := strings.ToUpper(strings.TrimSpace(parts[0]))
		switch kind {
		case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD",
			"MATCH", "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "DST-PORT", "SRC-PORT", "NETWORK":
		case "RULE-SET":
			if len(parts) < 3 {
				return fmt.Errorf("RULE-SET requires provider and target")
			}
			if _, ok := raw.RuleProvider[strings.TrimSpace(parts[1])]; !ok {
				return fmt.Errorf("RULE-SET provider %q not declared", parts[1])
			}
		default:
			return fmt.Errorf("rule %q not admitted: geodata/resource/process lifecycle not audited", kind)
		}
	}
	return nil
}
