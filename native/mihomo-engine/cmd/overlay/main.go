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
	"hub/executor/executor.go":           "183595fd58704d60d2137463e751938c1a02a23b57ef1d977b647e3640b64849",
	"listener/listener.go":               "1a11cda3fb4a87875d817fe29f1e79973cb8cb6eeccc0ae5e22db15df1277758",
	"listener/config/tun.go":             "4428cefc29ecabc08ea01fe5d0b6c107e6b383b95f07aad7d4f7f6dcb5116fe1",
	"listener/sing_tun/server.go":        "6aec285afd721a40a859dac8b6539c1c481d2c53c7ca33eb10e2f40eb992e7a1",
	"tunnel/tunnel.go":                   "bd0818dddd04779aad3f078819b3ca050bd8bdce29ba57e5a377770539278596",
	"config/config.go":                   "14d577a607eb5fff79513057bc16052520b62731d9af9817481f3baf980e8653",
	"tunnel/dns_dialer.go":               "1324413474edc70c52510cb44576ae084f3f7875e5ecf4b34ddbfce97f6a0003",
	"dns/doh.go":                         "978559eb93b791a4269c1993c866322b2851f20e75657b246dc6dd63cc9f0073",
	"adapter/provider/provider.go":       "69cb24313f68cc457c5f4e45ecab0d1355c1f5d22e3e2ec0559a7d753ee1672f",
	"adapter/provider/healthcheck.go":    "b3108ef1530c2bb28ff75928c64dc7150e68e2bb38f4f82e110ebdaff1801c64",
	"dns/resolver.go":                    "400765c7dde15950c324ab8fce1a7dc1d7730b3c7f3bff6a85fd64e4238e2b48",
	"dns/util.go":                        "24831a2b5e10fe3b8d074d537a1512025adc298968b3afa6bdef0ac3e10bae6e",
	"dns/client.go":                      "b11cea570b82d782aa222a1fa994a91534aa845e340ffac0cc55b3fce7fad9c6",
	"dns/dot.go":                         "0c018bc055d511c0e87dfdc36c64cc4a1dcd88b6f07251a37864820749a62049",
	"component/tls/reality.go":           "6f3b5771104b79fb9c244192ac7ecc4d11a4603de0444899e703d88359f018d8",
	"adapter/outboundgroup/groupbase.go": "4f073f75e1deaff8468458adecaaf674e720200f5c056967e5ee7f9dee25fc38",
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
	case "adapter/outboundgroup/groupbase.go":
		replace(`"sync"`, `"sync"
syncatomic "sync/atomic"`)
		replace("type GroupBase struct {", "type GroupBase struct {\n proximaMu sync.Mutex\n proximaStopped bool\n proximaWorkers sync.WaitGroup")
		replace("failedTimes       int", "failedTimes       syncatomic.Int64")
		text = strings.ReplaceAll(text, "gb.failedTimes = 0", "gb.failedTimes.Store(0)")
		replace("gb.failedTimes++", "gb.failedTimes.Add(1)")
		replace("gb.failedTimes == 1", "gb.failedTimes.Load() == 1")
		replace("gb.Name(), gb.failedTimes)", "gb.Name(), gb.failedTimes.Load())")
		replace("gb.failedTimes >= gb.maxFailedTimes", "gb.failedTimes.Load() >= int64(gb.maxFailedTimes)")
		replace("go func() {\n\t\tif strings.Contains(err.Error()", "gb.proximaGo(func() {\n\t\tif strings.Contains(err.Error()")
		replace("\t}()\n}\n\nfunc (gb *GroupBase) healthCheck()", "\t})\n}\n\nfunc (gb *GroupBase) healthCheck()")
		text += `
var proximaGroupWorkers syncatomic.Int64
func ProximaGroupWorkers() int64 { return proximaGroupWorkers.Load() }
func (gb *GroupBase) proximaGo(fn func()) {
 gb.proximaMu.Lock()
 defer gb.proximaMu.Unlock()
 if gb.proximaStopped { return }
 gb.proximaWorkers.Add(1)
 proximaGroupWorkers.Add(1)
 go func(){ defer gb.proximaWorkers.Done(); defer proximaGroupWorkers.Add(-1); fn() }()
}
func (gb *GroupBase) Close() error {
 gb.proximaMu.Lock(); gb.proximaStopped = true; gb.proximaMu.Unlock()
 gb.proximaWorkers.Wait()
 return nil
}
`
	case "component/tls/reality.go":
		replace(`"github.com/metacubex/mihomo/log"`, `"github.com/metacubex/mihomo/log"
"github.com/metacubex/mihomo/component/dialer"`)
		// No unowned camouflage HTTP worker in a protected session. In particular
		// HTTPS->HTTP redirects must never select net/http's default dialer.
		replace("go realityClientFallback(uConn, uConfig.ServerName, fingerprint)", "proximaRealityClientFallback(uConn, uConfig.ServerName, fingerprint)")
		text += `
func proximaRealityClientFallback(conn net.Conn, name string, fingerprint utls.ClientHelloID) {
 if dialer.DefaultSocketHook != nil { _ = conn.Close(); return }
 go realityClientFallback(conn, name, fingerprint)
}
`
	case "adapter/provider/provider.go":
		replace("return func(buf []byte) ([]C.Proxy, error) {", "return func(buf []byte) (result []C.Proxy, resultErr error) {")
		replace("proxies := []C.Proxy{}", "proxies := []C.Proxy{}\ndefer func(){ if resultErr != nil { for _, p := range proxies { _ = p.Close() } } }()")
		replace("go bp.healthCheck.process()", "bp.healthCheck.proximaGo(bp.healthCheck.process)")
		replace("go bp.healthCheck.check()", "bp.healthCheck.proximaGo(bp.healthCheck.check)")
		replace("bp.proxies = proxies", "old := bp.proxies\nbp.proxies = proxies\ndefer func(){ for _, p := range old { _ = p.Close() } }()")
		replace("bp.healthCheck.close()\n\treturn nil", "bp.healthCheck.close()\nfor _, p := range bp.Proxies() { _ = p.Close() }\n\treturn nil")
		replace("_ = pp.baseProvider.Close()\n\treturn pp.Fetcher.Close()", "pp.Fetcher.ProximaCancel()\npp.healthCheck.close()\nerr := pp.Fetcher.Close()\n_ = pp.baseProvider.Close()\nreturn err")
		replace("proxy, err := adapter.ParseProxy(mapping,", "if ProximaProxyPolicy != nil { if err := ProximaProxyPolicy(mapping); err != nil { return nil, err } }\nproxy, err := adapter.ParseProxy(mapping,")
		text += "\n// Installed once before semantic parsing by the single-session owner.\nvar ProximaProxyPolicy func(map[string]any) error\n"
	case "adapter/provider/healthcheck.go":
		replace("\"sync\"", "\"sync\"\nsyncatomic \"sync/atomic\"")
		replace("type HealthCheck struct {", "type HealthCheck struct {\n lifeMu sync.Mutex\n stopped bool\n workers sync.WaitGroup")
		replace("go hc.check()", "hc.proximaGo(hc.check)")
		replace("hc.proxies = proxies", "hc.mu.Lock(); defer hc.mu.Unlock(); hc.proxies = proxies")
		replace("func (hc *HealthCheck) check() {", "func (hc *HealthCheck) check() {\n if !hc.proximaBegin() { return }; defer hc.proximaDone()\n hc.mu.Lock(); defer hc.mu.Unlock()")
		replace("hc.ctxCancel()", "hc.lifeMu.Lock(); hc.stopped = true; hc.ctxCancel(); hc.lifeMu.Unlock(); hc.workers.Wait()")
		text += healthCheckSeam
	case "dns/resolver.go":
		replace("\"time\"", "\"time\"\n\"sync\"\n\"io\"")
		replace("func (r *Resolver) ExchangeContext(ctx context.Context, m *D.Msg) (msg *D.Msg, err error) {", "func (r *Resolver) ExchangeContext(ctx context.Context, m *D.Msg) (msg *D.Msg, err error) {\n ctx, done, ok := proximaDNSBegin(ctx); if !ok { return nil, context.Canceled }; defer done()")
		// Every explicit resolver goroutine is covered, including refresh/retry,
		// A/AAAA siblings and fallback branches. Exact counts are source-pinned.
		if strings.Count(text, "go func() {") != 5 {
			panic("DNS resolver goroutine count changed")
		}
		text = strings.ReplaceAll(text, "go func() {", "proximaDNSAdd()\ngo func() { defer proximaDNSDone()")
		for _, method := range []string{"LookupIPPrimaryIPv4", "LookupIP"} {
			anchor := "func (r *Resolver) " + method + "(ctx context.Context, host string) (ips []netip.Addr, err error) {"
			replace(anchor, anchor+"\nctx, done, ok := proximaDNSBegin(ctx); if !ok { return nil, context.Canceled }; defer done()")
		}
		text = strings.ReplaceAll(text, "r.group.DoChan(q.String(), fn)", "r.proximaDoChan(q.String(), fn)")
		replace("context.WithTimeout(context.Background(), resolver.DefaultDNSTimeout) // reset", "context.WithTimeout(proximaDNSContext(), resolver.DefaultDNSTimeout) // reset")
		replace("context.WithTimeout(context.Background(), resolver.DefaultDNSTimeout)", "context.WithTimeout(proximaDNSContext(), resolver.DefaultDNSTimeout)")
		text += resolverSeam
	case "dns/util.go":
		replace("c = rewrapClient(c, s.Params)", "proximaDNSRegister(c)\nc = rewrapClient(c, s.Params)")
	case "dns/client.go", "dns/dot.go":
		if path == "dns/client.go" {
			replace("\"time\"", "\"time\"\n\"sync\"")
		}
		replace("go func() {", "var requestWG sync.WaitGroup\nrequestWG.Add(1)\ndefer requestWG.Wait()\ngo func() {\ndefer requestWG.Done()")
		if path == "dns/client.go" {
			replace("case <-ctx.Done():\n\t\treturn", "case <-ctx.Done():\n_ = conn.Close()\n\t\treturn")
		}
		if path == "dns/dot.go" {
			text = strings.ReplaceAll(text, "go oldConn.Close() // close in a new goroutine, not blocking the current task", "_ = oldConn.Close()")
		}
	case "tunnel/dns_dialer.go":
		replace(`"context"`, "\"context\"\n\"io\"\n\"sync\"")
		replace("func (d *DNSDialer) DialContext(", "func (d *DNSDialer) proximaDialContext(")
		replace("func (d *DNSDialer) ListenPacket(", "func (d *DNSDialer) proximaListenPacket(")
		text += dnsDialerSeam
	case "dns/doh.go":
		// No redirect may downgrade HTTPS, change authority or select another
		// upstream. Keep upstream TLS verification and its protected transport.
		replace("client := &http.Client{", "client := &http.Client{\nCheckRedirect: func(*http.Request, []*http.Request) error { return fmt.Errorf(\"DNS upstream redirects are forbidden\") },")
		replace("go doh.probeQUIC(ctx, addr, probeTLSCfg, chQuic)", "proximaDNSGo(func(){ doh.probeQUIC(ctx, addr, probeTLSCfg, chQuic) })")
		replace("go doh.probeTLS(ctx, probeTLSCfg, chTLS)", "proximaDNSGo(func(){ doh.probeTLS(ctx, probeTLSCfg, chTLS) })")
	case "config/config.go":
		replace("func ParseRawConfig(rawCfg *RawConfig) (*Config, error) {", `func ParseRawConfig(rawCfg *RawConfig) (*Config, error) { return parseRawConfig(rawCfg, false) }
func ParseRawConfigWithError(rawCfg *RawConfig) (*Config, error) { return parseRawConfig(rawCfg, true) }
func parseRawConfig(rawCfg *RawConfig, cleanup bool) (result *Config, resultErr error) {`)
		replace("config := &Config{}", `config := &Config{}
defer func() {
  if cleanup && resultErr != nil {
   for _, provider := range config.Providers { if closer, ok := provider.(interface{ Close() error }); ok { resultErr = errors.Join(resultErr, closer.Close()) } }
   for _, provider := range config.RuleProviders { if closer, ok := provider.(interface{ Close() error }); ok { resultErr = errors.Join(resultErr, closer.Close()) } }
  for _, proxy := range config.Proxies { resultErr = errors.Join(resultErr, proxy.Close()) }
 }
}()`)
		replace("providersMap = make(map[string]P.ProxyProvider)", `providersMap = make(map[string]P.ProxyProvider)
  defer func(owned map[string]P.ProxyProvider) { if err != nil { for _, p := range owned { if c, ok := p.(interface{ Close() error }); ok { _ = c.Close() } } } }(providersMap)`)
		replace("proxies = make(map[string]C.Proxy)", `proxies = make(map[string]C.Proxy)
 defer func(owned map[string]C.Proxy) { if err != nil { for _, p := range owned { _ = p.Close() } } }(proxies)`)
		replace("ruleProviders = map[string]P.RuleProvider{}", `ruleProviders = map[string]P.RuleProvider{}
 defer func(owned map[string]P.RuleProvider) { if err != nil { for _, p := range owned { if c, ok := p.(interface{ Close() error }); ok { _ = c.Close() } } } }(ruleProviders)`)
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
	 dns.ProximaStart()
	updateDNS(cfg.DNS, cfg.General.IPv6)
 dispatcher, err := sniffer.NewDispatcher(cfg.Sniffer)
 if err != nil { return nil, fmt.Errorf("sniffer: %w", err) }
 tunnel.UpdateSniffer(dispatcher)
	 for name, provider := range cfg.Providers {
  if err := provider.Initial(); err != nil { return nil, fmt.Errorf("provider %s: %w", name, err) }
	 }
	 for name, provider := range cfg.RuleProviders {
	  if err := provider.Initial(); err != nil { return nil, fmt.Errorf("rule provider %s: %w", name, err) }
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
	 dns.ProximaCancel()
		tunnel.ProximaStopDNS()
	 dns.ProximaStop()
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
