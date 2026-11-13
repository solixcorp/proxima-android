package engine

import (
	"bytes"
	"fmt"
	"reflect"
	"strings"

	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// An explicit capability subset, not a config rewriter. Reject before invoking
// the semantic parser: factories can already create workers/load assets before
// ParseRawConfig returns an error. Extend admission only with a reviewed rollback
// and teardown path. Raw Decode itself continues to retain arbitrary YAML.
var topLevel = map[string]bool{
	"mode": true, "ipv6": true, "log-level": true, "rules": true, "tun": true,
	"find-process-mode": true, "dns": true, "profile": true,
	"proxy-providers": true, "rule-providers": true,
}

var nestedKeys = map[string]map[string]bool{
	"tun": {"enable": true, "stack": true, "mtu": true, "auto-route": true, "auto-detect-interface": true, "dns-hijack": true, "inet6-address": true, "congestion-controller": true, "disable-icmp-forwarding": true},
	"dns": {"enable": true, "enhanced-mode": true, "nameserver": true, "default-nameserver": true,
		"fallback": true, "ipv6": true, "ipv6-timeout": true, "prefer-h3": true,
		"use-hosts": true, "use-system-hosts": true, "respect-rules": true,
		"cache-algorithm": true, "cache-max-size": true},
	"profile": {"store-selected": true, "store-fake-ip": true},
}

func admit(source []byte, raw *config.RawConfig) error {
	if raw.DNS.EnhancedMode.String() == "fake-ip" {
		return fmt.Errorf("dns enhanced-mode fake-ip: not supported yet")
	}
	var node yaml.Node
	if err := yaml.NewDecoder(bytes.NewReader(source)).Decode(&node); err != nil {
		return err
	}
	for i := 0; i < len(node.Content[0].Content); i += 2 {
		key := node.Content[0].Content[i].Value
		if !topLevel[key] {
			return fmt.Errorf("engine capability not implemented: %s", key)
		}
		if allowed, ok := nestedKeys[key]; ok {
			value := node.Content[0].Content[i+1]
			if value.Kind != yaml.MappingNode {
				return fmt.Errorf("%s must be an explicit mapping", key)
			}
			explicitStack := false
			for j := 0; j < len(value.Content); j += 2 {
				child := value.Content[j].Value
				if !allowed[child] {
					return fmt.Errorf("engine capability not implemented: %s.%s", key, child)
				}
				if child == "stack" {
					explicitStack = true
				}
			}
			if key == "tun" && !explicitStack {
				return fmt.Errorf("tun.stack must explicitly select mips")
			}
		}
	}
	if err := admitDNS(node.Content[0], raw); err != nil {
		return err
	}
	if err := admitProviders(raw); err != nil {
		return err
	}
	defaults := config.DefaultRawConfig()
	if raw.Profile.StoreFakeIP || raw.Profile.StoreSelected {
		return fmt.Errorf("profile persistence not implemented")
	}
	// Prevent process metadata inspection from opening platform resources.
	if raw.FindProcessMode.String() != "off" {
		return fmt.Errorf("find-process-mode must explicitly be off")
	}
	// Packet runtime is mips-only; all VpnService interface/routing configuration
	// belongs to the caller. A file-descriptor in imported YAML is never trusted.
	if !raw.Tun.Enable || strings.ToLower(raw.Tun.Stack.String()) != "mips" || raw.Tun.MTU == 0 {
		return fmt.Errorf("tun.enable, explicit tun.stack: mips and tun.mtu are required")
	}
	allowedTun := config.RawTun{Enable: true, Stack: raw.Tun.Stack, MTU: raw.Tun.MTU, CongestionController: raw.Tun.CongestionController, DisableICMPForwarding: raw.Tun.DisableICMPForwarding}
	// These two upstream defaults apply only to platform/batch/gvisor paths,
	// never to the raw os.File mips path. Non-default requests are still rejected.
	allowedTun.RecvMsgX = defaults.Tun.RecvMsgX
	allowedTun.ProcessorsPerChannel = defaults.Tun.ProcessorsPerChannel
	allowedTun.DNSHijack = raw.Tun.DNSHijack
	if len(raw.Tun.Inet6Address) == 0 {
		allowedTun.Inet6Address = raw.Tun.Inet6Address
	}
	if !reflect.DeepEqual(raw.Tun, allowedTun) {
		return fmt.Errorf("TUN routing/device/DNS options not implemented for an app-owned raw fd")
	}
	for _, rule := range raw.Rule {
		kind, _, _ := strings.Cut(rule, ",")
		switch strings.ToUpper(strings.TrimSpace(kind)) {
		case "MATCH", "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "DST-PORT", "SRC-PORT", "NETWORK":
		default:
			return fmt.Errorf("rule %q requires an unimplemented geodata/DNS/process lifecycle", kind)
		}
	}
	return nil
}
