package engine

import (
	"fmt"
	"net/netip"
	"net/url"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"go.yaml.in/yaml/v3"
)

// Executable defaults intentionally differ from upstream's desktop defaults.
// IP-literal HTTPS endpoints avoid system DNS and plaintext bootstrap queries.
func admitDNS(document *yaml.Node, raw *config.RawConfig) error {
	d := config.RawDNS{Enable: true, EnhancedMode: C.DNSMapping, IPv6Timeout: 100,
		NameServer:        []string{"https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"},
		DefaultNameserver: []string{"https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"}}
	for i := 0; i < len(document.Content); i += 2 {
		if document.Content[i].Value == "dns" {
			if err := document.Content[i+1].Decode(&d); err != nil {
				return err
			}
		}
	}
	if d.EnhancedMode == C.DNSFakeIP {
		return fmt.Errorf("dns enhanced-mode fake-ip: not supported yet")
	}
	if d.EnhancedMode != C.DNSMapping {
		return fmt.Errorf("dns enhanced-mode must be redir-host")
	}
	if !d.Enable {
		return fmt.Errorf("dns.enable: false is not supported: app DNS interception requires DNS")
	}
	if d.UseSystemHosts || d.RespectRules {
		return fmt.Errorf("DNS system hosts and respect-rules are not supported yet")
	}
	if len(d.NameServer) == 0 || len(d.DefaultNameserver) == 0 {
		return fmt.Errorf("DNS nameserver and default-nameserver must not be empty")
	}
	for field, list := range map[string][]string{"nameserver": d.NameServer, "default-nameserver": d.DefaultNameserver, "fallback": d.Fallback} {
		for _, server := range list {
			if err := validateDNSServer(server, field == "default-nameserver"); err != nil {
				return fmt.Errorf("dns.%s: %w", field, err)
			}
		}
	}
	raw.DNS = d // No fake-IP pool, geodata fallback or system resolver factories.
	// Always retain the app's advertised synthetic DNS, even for legacy [] YAML.
	hijack := []string{"172.19.0.2:53"}
	var requested []string
	for i := 0; i < len(document.Content); i += 2 {
		if document.Content[i].Value != "tun" {
			continue
		}
		value := document.Content[i+1]
		for j := 0; j < len(value.Content); j += 2 {
			if value.Content[j].Value == "dns-hijack" {
				requested = raw.Tun.DNSHijack
			}
		}
	}
	for _, target := range requested {
		if scheme, after, ok := strings.Cut(target, "://"); ok {
			if scheme != "tcp" && scheme != "udp" {
				return fmt.Errorf("unsupported dns-hijack scheme %q", scheme)
			}
			target = after // Pinned upstream hijacks both protocols, even with a prefix.
		}
		target = strings.Replace(target, "any:", "0.0.0.0:", 1)
		addr, err := netip.ParseAddrPort(target)
		if err != nil || addr.Port() != 53 || addr.Addr().IsMulticast() {
			return fmt.Errorf("dns-hijack requires an IP/any destination on port 53: %q", target)
		}
		hijack = append(hijack, addr.String())
	}
	raw.Tun.DNSHijack = hijack
	return nil
}

func validateDNSServer(server string, bootstrap bool) error {
	original := server
	// Upstream treats this bare spelling specially before URL parsing.
	if server == "system" {
		return fmt.Errorf("system DNS is forbidden")
	}
	if !strings.Contains(server, "://") {
		if ip, err := netip.ParseAddr(server); err == nil && ip.Is6() {
			server = "[" + server + "]"
		}
		server = "udp://" + server
	}
	u, err := url.Parse(server)
	if err != nil {
		return fmt.Errorf("invalid DNS upstream %q", original)
	}
	switch u.Scheme {
	case "udp", "tcp", "tls", "quic", "https":
	default:
		return fmt.Errorf("DNS upstream scheme %q is not supported (HTTP plaintext, system/DHCP and custom dialers are forbidden)", u.Scheme)
	}
	if u.Hostname() == "" || u.User != nil || u.Fragment != "" || u.RawQuery != "" || u.Opaque != "" {
		return fmt.Errorf("DNS upstream requires a host and forbids credentials, query and fragment overrides: %q", original)
	}
	if u.Scheme != "https" && u.Path != "" {
		return fmt.Errorf("DNS upstream path only allowed for HTTPS")
	}
	if port := u.Port(); port != "" {
		n, err := strconv.ParseUint(port, 10, 16)
		if err != nil || n == 0 {
			return fmt.Errorf("invalid DNS upstream port")
		}
	} else if strings.HasSuffix(u.Host, ":") {
		return fmt.Errorf("empty DNS upstream port")
	}
	if ip, err := netip.ParseAddr(u.Hostname()); err == nil {
		if ip.IsUnspecified() || ip.IsMulticast() || ip.Zone() != "" {
			return fmt.Errorf("invalid DNS upstream address")
		}
	} else if bootstrap {
		return fmt.Errorf("default-nameserver must use IP literals (no system DNS bootstrap)")
	}
	return nil
}
