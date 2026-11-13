// Command overlay adds the reviewed error-returning raw-FD engine seam.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"strings"
)

var pins = map[string]string{
	"hub/executor/executor.go":    "183595fd58704d60d2137463e751938c1a02a23b57ef1d977b647e3640b64849",
	"listener/listener.go":        "1a11cda3fb4a87875d817fe29f1e79973cb8cb6eeccc0ae5e22db15df1277758",
	"listener/config/tun.go":      "4428cefc29ecabc08ea01fe5d0b6c107e6b383b95f07aad7d4f7f6dcb5116fe1",
	"listener/sing_tun/server.go": "6aec285afd721a40a859dac8b6539c1c481d2c53c7ca33eb10e2f40eb992e7a1",
	"tunnel/tunnel.go":            "bd0818dddd04779aad3f078819b3ca050bd8bdce29ba57e5a377770539278596",
	"config/config.go":            "14d577a607eb5fff79513057bc16052520b62731d9af9817481f3baf980e8653",
	"tunnel/dns_dialer.go":        "1324413474edc70c52510cb44576ae084f3f7875e5ecf4b34ddbfce97f6a0003",
	"dns/doh.go":                  "978559eb93b791a4269c1993c866322b2851f20e75657b246dc6dd63cc9f0073",
}

func patch(path string, source []byte) ([]byte, error) {
	if fmt.Sprintf("%x", sha256.Sum256(source)) != pins[path] {
		return nil, fmt.Errorf("engine source checksum mismatch: %s", path)
	}
	text := string(source)
	replace := func(old, next string) {
		if strings.Count(text, old) != 1 {
			panic("ambiguous engine anchor: " + old)
		}
		text = strings.Replace(text, old, next, 1)
	}
	switch path {
	case "tunnel/dns_dialer.go":
		replace(`"context"`, "\"context\"\n\"io\"\n\"sync\"")
		replace("func (d *DNSDialer) DialContext(", "func (d *DNSDialer) proximaDialContext(")
		replace("func (d *DNSDialer) ListenPacket(", "func (d *DNSDialer) proximaListenPacket(")
		text += dnsDialerSeam
	case "dns/doh.go":
		// No redirect may downgrade HTTPS, change authority or select another
		// upstream. Keep upstream TLS verification and its protected transport.
		replace("client := &http.Client{", "client := &http.Client{\nCheckRedirect: func(*http.Request, []*http.Request) error { return fmt.Errorf(\"DNS upstream redirects are forbidden\") },")
	case "config/config.go":
		replace("func ParseRawConfig(rawCfg *RawConfig) (*Config, error) {", `func ParseRawConfig(rawCfg *RawConfig) (*Config, error) { return parseRawConfig(rawCfg, false) }
func ParseRawConfigWithError(rawCfg *RawConfig) (*Config, error) { return parseRawConfig(rawCfg, true) }
func parseRawConfig(rawCfg *RawConfig, cleanup bool) (result *Config, resultErr error) {`)
		replace("config := &Config{}", `config := &Config{}
defer func() {
 if cleanup && resultErr != nil {
  for _, provider := range config.Providers { if closer, ok := provider.(interface{ Close() error }); ok { resultErr = errors.Join(resultErr, closer.Close()) } }
  for _, proxy := range config.Proxies { resultErr = errors.Join(resultErr, proxy.Close()) }
 }
}()`)
	case "tunnel/tunnel.go":
		replace("go handleUDPToLocal(writeBackProxy, pc, sender, key, oAddrPort)", "proximaPumps.Add(1)\ngo func() { defer proximaPumps.Done(); handleUDPToLocal(writeBackProxy, pc, sender, key, oAddrPort) }()")
		replace("\t\tgo func() {\n\t\t\tpc, proxy, err := dial()", "\t\tproximaDials.Add(1)\n\t\tgo func() {\n\t\t\tdefer proximaDials.Done()\n\t\t\tpc, proxy, err := dial()")
		replace("\t\t\tsender.Process(pc, proxy)", "\t\t\tproximaPumps.Add(1)\n\t\t\tgo func() { defer proximaPumps.Done(); sender.Process(pc, proxy) }()")
		replace("\tpeekMutex := sync.Mutex{}", "\tpeekMutex := sync.Mutex{}\nvar peekWG sync.WaitGroup\ndefer func() { conn.Close(); peekWG.Wait() }()")
		replace("\t\tpeekMutex.Lock()\n\t\tgo func() {", "\t\tpeekMutex.Lock()\n\t\tpeekWG.Add(1)\n\t\tgo func() {\ndefer peekWG.Done()")
		text += `
// Avoid the unjoined process-wide UDP queues for this single-session adapter.
// Runtime Close first drains all synchronous calls into this boundary.
type proximaTunnel struct { tunnel }
func (t proximaTunnel) HandleUDPPacket(packet C.UDPPacket, metadata *C.Metadata) {
 handleUDPConn(C.NewPacketAdapter(packet, metadata))
}
func ProximaTunnel() C.Tunnel { return proximaTunnel{Tunnel} }
var proximaDials sync.WaitGroup
var proximaPumps sync.WaitGroup
func ProximaStopPackets() {
 // No dispatch can enter after the runtime stack's admission gate drained.
 proximaDials.Wait()
 statistic.DefaultManager.Range(func(c statistic.Tracker) bool { c.Close(); return true })
 proximaPumps.Wait()
}
`
	case "listener/config/tun.go":
		replace("type Tun struct {", "type Tun struct {\n// ProximaRawFD is an app capability, never configurable through YAML/JSON.\nProximaRawFD bool `yaml:\"-\" json:\"-\"`")
	case "listener/sing_tun/server.go":
		replace("\"context\"", "\"context\"\n runtimepacket \"proxima.local/mihomo-runtime\"")
		replace("type Listener struct {", "type Listener struct {\nrawPackets *runtimepacket.Session")
		replace("func New(options LC.Tun, tunnel C.Tunnel, additions ...inbound.Addition) (l *Listener, err error) {", `func New(options LC.Tun, tunnel C.Tunnel, additions ...inbound.Addition) (l *Listener, err error) {
// The Android-owned descriptor has already been established. Do not pass it to
// platform tun.New: adoption/close-on-failure differs across OS constructors.
// OpenBorrowed owns its own duplicate and joins the real sing-tun packet loops.
if options.ProximaRawFD {
	var dnsTargets []netip.AddrPort
	for _, target := range options.DNSHijack {
	 addr, parseErr := netip.ParseAddrPort(target)
	 if parseErr != nil { return nil, fmt.Errorf("parse dns-hijack: %w", parseErr) }
	 dnsTargets = append(dnsTargets, addr)
	}
  packets, openErr := runtimepacket.OpenBorrowed(options.FileDescriptor, runtimepacket.Options{
   Stack: strings.ToLower(options.Stack.String()), MTU: options.MTU,
   TCPCongestionControl: options.CongestionController,
	 DNSHijack: dnsTargets,
 }, tunnel)
 if openErr != nil { return nil, openErr }
 return &Listener{options: options, rawPackets: packets, addrStr: "PROXIMA-RAW-TUN"}, nil
}`)
		replace("func (l *Listener) Close() error {", "func (l *Listener) Close() error {\nif l.rawPackets != nil { return l.rawPackets.Close() }")
		text += `
// ProximaReadDone is only available for the app-owned raw packet path.
func (l *Listener) ProximaReadDone() <-chan struct{} { return l.rawPackets.ReadDone() }
func (l *Listener) ProximaReadError() error { return l.rawPackets.ReadError() }
`
	case "listener/listener.go":
		text += `
// ReCreateTunWithError is a single-use, caller-owned alternative to the legacy
// log-only singleton recreation. The caller must close the returned listener.
func ReCreateTunWithError(options LC.Tun, tunnel C.Tunnel) (*sing_tun.Listener, error) {
 if !options.Enable || !options.ProximaRawFD { return nil, fmt.Errorf("app-owned raw TUN required") }
 return sing_tun.New(options, tunnel)
}
`
	case "hub/executor/executor.go":
		replace(`"github.com/metacubex/mihomo/listener"`, "\"errors\"\n\"github.com/metacubex/mihomo/listener\"\n\"github.com/metacubex/mihomo/listener/sing_tun\"")
		text += executorSeam
	}
	return format.Source([]byte(text))
}

const executorSeam = `
// ApplyConfigWithError deliberately excludes unjoined/void startup paths. The
// adapter admits only the subset checked before semantic parsing. No legacy
// ApplyConfig call may follow this one (that would initialize providers twice).
// TUN packet admission is last; OnRunning is never reached on startup failure.
func ApplyConfigWithError(cfg *config.Config) (*sing_tun.Listener, error) {
 mux.Lock()
 defer mux.Unlock()
 tunnel.OnSuspend()
 log.SetLevel(cfg.General.LogLevel)
 updateUsers(cfg.Users)
 updateProxies(cfg.Proxies, cfg.Providers)
 updateRules(cfg.Rules, cfg.SubRules, cfg.RuleProviders)
 updateHosts(cfg.Hosts)
  updateGeneral(cfg.General, true)
	if err := tunnel.ProximaStartDNS(); err != nil { return nil, err }
	updateDNS(cfg.DNS, cfg.General.IPv6)
 dispatcher, err := sniffer.NewDispatcher(cfg.Sniffer)
 if err != nil { return nil, fmt.Errorf("sniffer: %w", err) }
 tunnel.UpdateSniffer(dispatcher)
 for name, provider := range cfg.Providers {
  if err := provider.Initial(); err != nil { return nil, fmt.Errorf("provider %s: %w", name, err) }
 }
 packets, err := listener.ReCreateTunWithError(cfg.General.Tun, tunnel.ProximaTunnel())
 if err != nil { return nil, fmt.Errorf("start TUN: %w", err) }
 tunnel.OnRunning()
 return packets, nil
}

// StopConfig suspends packet routing and closes constructed providers/proxies.
// It is NOT a join of upstream global workers; the registry is retired before
// parsing and a supervisor must terminate/reap this one-session process.
func StopConfig(cfg *config.Config) error {
 mux.Lock()
 defer mux.Unlock()
 tunnel.OnSuspend()
  tunnel.ProximaStopPackets()
	tunnel.ProximaStopDNS()
 Shutdown()
 var result error
 for _, provider := range cfg.Providers { if closer, ok := provider.(interface{ Close() error }); ok { result = errors.Join(result, closer.Close()) } }
 for _, provider := range cfg.RuleProviders { if closer, ok := provider.(interface{ Close() error }); ok { result = errors.Join(result, closer.Close()) } }
 for _, proxy := range cfg.Proxies { result = errors.Join(result, proxy.Close()) }
 tunnel.UpdateRules(nil, nil, nil)
 tunnel.UpdateProxies(nil, nil)
 return result
}
`

func main() {
	if len(os.Args) != 3 {
		panic("usage: overlay <verified-mihomo> <out>")
	}
	root, _ := filepath.Abs(os.Args[1])
	out, _ := filepath.Abs(os.Args[2])
	if err := os.MkdirAll(out, 0o755); err != nil {
		panic(err)
	}
	mapping := map[string]string{}
	for path := range pins {
		source, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			panic(err)
		}
		source, err = patch(path, source)
		if err != nil {
			panic(err)
		}
		source, err = format.Source(source)
		if err != nil {
			panic(err)
		}
		dest := filepath.Join(out, strings.ReplaceAll(path, "/", "_"))
		if err := os.WriteFile(dest, source, 0o600); err != nil {
			panic(err)
		}
		mapping[filepath.Join(root, path)] = dest
	}
	data, _ := json.MarshalIndent(struct{ Replace map[string]string }{mapping}, "", "  ")
	if err := os.WriteFile(filepath.Join(out, "overlay.json"), data, 0o600); err != nil {
		panic(err)
	}
}
