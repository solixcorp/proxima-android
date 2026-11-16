# Phase 1.4: protected socket / constructor admission audit

## Pin and meaning of the verdicts

Audited source: Mihomo **v1.19.33**, commit
`3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8`. All paths/functions below refer
to that tree, not current upstream HEAD. For example:
[dialer.go at the pin](https://github.com/MetaCubeX/mihomo/blob/3f27ef39f8c96bbfbc8b0b9bb10f5c9ef60149d8/component/dialer/dialer.go).
The existing `upstream.lock` and module sums are unchanged. Builds verify the
module graph and gate each changed complete source with SHA-256 and unique anchors.

- **(a)** The admitted option subset's **outer OS** sockets reach the permanent
  session hook *before bind/connect*. A virtual conn is not an OS descriptor and
  must not be passed to `protect`. This is not a successful protocol interop claim.
- **(b)** A bypass/unsafe background path is removed or covered by the composed
  source overlay. Both original and patched behavior are described below.
- **(c)** **Not certified / rejected**: an actual bypass, privileged transport,
  or insufficient constructor/resource/worker ownership evidence. A rejected
  boundary is not a claim that every socket inside that library is unprotected.
  Known safe callback edges are explicitly distinguished from unaudited edges.

The inventory covers socket creation in the pinned Mihomo source (including
`listener/`'s outgoing clients), and follows admitted third-party client branches
to their actual outer socket constructors. Rejected libraries are stopped at the
constructor boundary; their entire native/discovery/control-plane implementations
are **not** certified by this audit. Linked does not mean admitted. The final
admission decision includes lifecycle/resource safety, not only a dialer grep.

## Common socket-creation inventory

| Source / function | OS action or delegation | Verdict / engine reachability |
|---|---|---|
| `component/dialer/dialer.go`: `DialContext`, `parseAddr`, serial/parallel/dual-stack helpers, `dialContext` | Resolve with Mihomo resolver; native `*net.Dialer.DialContext` receives `socketHookToToDialer` | (a); IPv4/IPv6 racing does not select another native constructor |
| same: `dialContext`, `default` custom `NetDialer` branch, lines 145–154 | Calls custom `DialContext` **before** hook installation | Not generically safe; see individual virtual/QUIC edges below. No blanket rewrite/rejection of virtual sockets |
| same: `ListenPacket`, `Listen`, `listenConfig` | `net.ListenConfig.ListenPacket` / `.Listen`; hook installed by `socketHookToListenConfig` | (a), UDP family selection included |
| same: `ICMPControl` | Returns hook for caller-created raw/ICMP sockets | (a) only when caller actually supplies that control; raw engine drops ICMP, see below |
| `component/dialer/socket_hook.go`, `control.go` | Compose `ControlContext` / `Control` callbacks | Hook error reaches Go socket creation; not a post-connect protector |
| `component/dialer/tfo.go`: `dialTFO` and deferred first write | TFO dependency creates native TCP socket | (b), existing network overlay; only TCP uses deferred TFO. UDP remains concrete eager protected sockets |
| `component/dialer/bind*.go`, `mark*.go`, `reuse.go`, `options.go` | Interface/mark/reuse controls, address inspection; no independent transport | Hook takes precedence over bind/mark. Interface/mark/MPTCP profile options remain unadmitted, not silently promised |
| `adapter/inbound/listen.go`: `ListenConfig.newListenConfig` | Common inbound native TCP/UDP listener factory | (b), existing network overlay adds pre-bind hook; extra listeners still not admitted |
| `listener/redir/tcp.go`: `New` | Originally `net.Listen` | (b), existing network overlay routes through inbound factory; REDIR not admitted |
| `listener/tproxy/tproxy.go`, `udp.go`: `New` | Native TCP/UDP listener configuration | (b), existing network overlay composes protection and transparent options; TProxy not admitted |
| `listener/tproxy/udp_linux.go`: `dialUDP` | Raw `syscall.Socket`, bind/connect for writeback | (b), existing network overlay protects before options/bind/connect with single descriptor owner; TProxy not admitted |
| `transport/hysteria/conns/faketcp/tcp_linux.go`: `Dial`, `Listen` | `net.DialIP`, `net.DialTCP`, `net.ListenIP`, `net.ListenTCP`; `net.ResolveTCPAddr` | (c), raw capability plus unhooked native constructors; reject fakeTCP and its `obfs-protocol` alias before construction |
| `component/iface/anet/interface_android.go`: `indexToName`, `nameToMTU`, `nameToFlags`; `netlink_android.go`: `NetlinkRIB` | AF_INET datagram ioctl descriptors; AF_NETLINK route-query descriptors | Local interface metadata, **not IP transport traffic**. Not rewritten/protected as VPN egress; descriptor ownership remains upstream's |
| `component/process/process_linux.go`: `resolveSocketByNetlink` | `netlink.Dial(NETLINK_INET_DIAG)` | Local process inspection, not IP egress; `find-process-mode: off`, process/UID rules rejected |
| `hub/route` server startup | Management HTTP/TLS/Unix listeners | No admitted executor entry into controller startup; all controller/listener profile keys rejected |

For the existing network overlay's seven Mihomo/seven TFO source gates,
Linux raw descriptor handling and TFO fallback/control ordering, see
[`../mihomo-network/README.md`](../mihomo-network/README.md). No new competing
replacement for `component/dialer/dialer.go` is layered on top of it.

## Final outbound matrix

Every type in pinned `adapter/parser.go:ParseProxy` is listed. Files in the next
table are relative to `adapter/outbound/` unless stated otherwise.

| YAML type | Verdict | Code evidence / final admission |
|---|---|---|
| `direct` | (a) | `direct.go:DialContext` → native `dialer.DialContext`; `ListenPacketContext` → native `Dialer.ListenPacket`. Admitted |
| `http` | (a) | `http.go:DialContext` opens `h.dialer.DialContext` before CONNECT / TLS. No default HTTP transport used for CONNECT. Admitted; TLS verification cannot be disabled |
| `socks5` | (a) | `socks5.go:DialContext`, `ListenPacketContext`: TCP association uses native dialer, resolved UDP relay uses `ss.dialer.ListenPacket`; TCP-association reader closes the packet conn. Admitted |
| `ss` | (a) | `shadowsocks.go:dialContext`, `listenPacketContext` → native TCP / UDP. Cipher and UOT wrap supplied conns. Only in-process simple `obfs` (http/tls) plugin admitted; other plugin graphs rejected |
| `ssr` | (a) | `shadowsocksr.go:DialContext`, `ListenPacketContext` → native TCP / UDP; `StreamConnContext` applies cipher/obfs/protocol to supplied stream. Admitted |
| `vmess` | (a), REALITY (b) | `vmess.go:dialContext`, `StreamConnContext`, `NewVmess` supply native dial callbacks to stream/gun transports. TCP, WS, HTTP, H2, gRPC admitted; no mekya/mKCP/TLSMirror or security-wrapper options |
| `vless` | (a), REALITY (b) | `vless.go:dialContext`, `streamTLSConn`, `NewVless`: native TCP or supplied gun callback. Same admitted transports; REALITY supported on non-WS paths. XHTTP/download branches and extra encryption option rejected |
| `trojan` | (a), REALITY (b) | `trojan.go:dialContext`, `StreamConnContext`, `ListenPacketContext`, `NewTrojan`: TCP or supplied gun callback; UDP framed over that stream. TCP/WS/gRPC admitted; other wrappers rejected |
| `snell` | (a) subset; reuse (c) | `snell.go:DialContext`, `ListenPacketContext` use native TCP, including UDP-over-stream. Default v1, v3, v4 and upstream v5→v4 compatibility admitted. v2 always allocates `snell.NewPool`; adapter has no pool Close override, so v2 and `reuse` are rejected. Only simple http/tls obfs admitted |
| `hysteria` | (a) UDP; fakeTCP (c) | `hysteria.go:genHdc` installs native `h.dialer.ListenPacket`; `transport/hysteria/transport/client.go:quicPacketConn` uses it for `udp` / `wechat-video`, then supplies conn to QUIC. Those modes admitted; fakeTCP and port-hopping options rejected |
| `hysteria2` | (a) subset | `hysteria2.go:NewHysteria2` supplies native `PacketListener`, and `QuicDialer` → `transport/tuic/common.DialQuic`. sing-quic dependency detail below. Admitted without realm/discovery, hopping or ECH |
| `tuic` | (a) | `tuic.go:dial` → `transport/tuic/common.DialQuic`; custom `NetDialerFunc` calls supplied native `pDialer.ListenPacket`, **not** an independent UDP constructor. v4/v5, early and normal sockets tested. Admitted; `disable-sni` rejected because it sets `InsecureSkipVerify` |
| `wireguard` | (a) subset | `wireguard.go:NewWireGuard` → sing-wireguard `ClientBind` with `proxydialer.NewSingDialer`; its `connect` uses supplied native UDP DialContext/ListenPacket. `ipStackNetDialer.DialContext` is a **virtual mipstack** connection, not OS TCP. Single peer endpoint, default/mips stack admitted; peers, remote DNS, refresh and Amnezia configuration rejected |
| `ssh` | (a) | `ssh.go:connect` creates native TCP **before** `ssh.NewClientConn`; client `DialContext` is an SSH channel over that connection. Admitted with nonempty host-key pins; private keys inline PEM only (upstream otherwise reads files) |
| `anytls` | (a) | `anytls.go:NewAnyTLS` supplies `proxydialer.NewSingDialer`; `transport/anytls/client.go:createOutboundTLSConnection` uses that TCP dialer; UOT creates no OS UDP. Constructor starts idle cleanup, not autonomous dialing; adapter Close cancels client and closes sessions. Admitted; library actor joins still require process exit |
| `mieru` | (a) | `mieru.go:ensureClientIsRunning` sets **all three** Dialer, PacketDialer and Resolver before lazy Start. TCP/UDP outer dependency paths detailed below. Admitted |
| `shadowquic` | (a) observed UDP edge; final (c) | `shadowquic.go:NewShadowQuic` → `transport/shadowquic/dial.go:DialQuic`; custom NetDialer uses supplied native ListenPacket. Real refusal tests prove that edge (including both TCP/UDP proxy APIs); JLS-QUIC client/pool lifetime and successful transport replacement are not certified here. **Still rejected**; not mislabeled as a demonstrated socket bypass |
| `gost-relay` | (a) visible edge; final (c) | `gost_relay.go:DialContext`, `ListenPacketContext` use supplied native TCP/UDP, but full relay negotiation/UOT ownership not exercised in this unit. Rejected, not inferred safe from the dialer calls alone |
| `sudoku` | (c) | `sudoku.go:dialAndHandshake`, `getOrCreateHTTPMaskClient` supply native dial callback; `transport/sudoku/obfs/httpmask` owns HTTP polling/stream/WS and multiplex reuse (`multiplex_dialer.go`). Reconnect, reset, redirects and constructor/pool cleanup across all modes not certified. Rejected |
| `trusttunnel` | (c) | `trusttunnel.go:NewTrustTunnel` supplies native dialer, `transport/trusttunnel/client.go:NewClient` and `quic.go` own HTTP2/HTTP3 health/pool work. Known QUIC edge delegates to common protected DialQuic; complete pool/health lifetime not certified. Rejected |
| `masque` | (c) | `masque.go:NewMasque`, `dialQuic`, `startLocked`: known h2 callback uses native TCP and QUIC uses common packet callback, but constructor also allocates virtual stack/L4 client and optional resolver. `transport/masque/l4proxy.go` uses `unsafe` access to HTTP3 connection internals; IP tunnel/reconnect/stack ownership not certified. Rejected |
| `openvpn` | (c) | `openvpn.go:NewOpenVPN`, `run`, `startLocked` → `transport/openvpn.Client`; virtual `ipStackNetDialer` is not the outer transport. Independent reconnect/control/data-channel/key/DNS lifecycle not certified. Rejected |
| `tailscale` | (c) | `tailscale.go:NewTailscale` supplies tsnet SystemDialer/SystemPacketListener/LookupHook callbacks (known protected edges). `DialContext`'s custom NetDialer enters tsnet's virtual stack. `start`, `watchBackendState`, `Close` own state/control/DERP/discovery tasks, whose entire dependency graph is not certified. Rejected before tsnet construction |
| `zerotier` | (c) | `zerotier.go:wireTransportConfig` supplies `z.dialer` to zerotier-go transport; `SharedUDP`, interface discovery, native node callbacks, TCP fallback and identity recovery (`startLocked`, `recoverIdentityCollision`) are additional surfaces. Virtual zeroTierNetDialer alone proves nothing about these. Native/state/discovery coverage not certified; rejected |
| `easytier` | (c) | `easytier.go:init` → corehost with `component/easytier.Services`. Its SocketFactory's ConnectTCP/BindUDP/ListenTCP and DNSResolver use Mihomo hooks (known protected edges); FakeTCP explicitly errors. Rust/native corehost discovery/listeners/state/retry graph not certified. Rejected before constructor |
| `dns` | (c) lifecycle, not an OS bypass | `dns.go:DialContext` starts a Background-context RelayDnsConn over an in-memory pipe; not the scoped raw-TUN DNS seam. Rejected; use DNS hijack instead |
| `rematch` | (c) routing contract | `rematch.go:applyMetadata` rewrites SpecialRules/RematchName and returns nop conns, not OS sockets. Sub-rule/rematch behavior not admitted |
| `reject` | (a), no OS socket | `reject.go:DialContext` / `ListenPacketContext` are upstream reject behavior, not socket factories. Admitted, along with built-in DIRECT/REJECT routing targets |

`base.go:BasicOption.NewDialer` is crucial: without `dialer-proxy` or
`DialerForAPI`, it selects native `dialer.NewDialer`. Imported `dialer-proxy`,
`smux`, routing/interface/MPTCP options, file certificates/private keys, ECH,
ShadowTLS/Restls/JLS/TLSMirror options cannot select another network/resource graph:
the explicit key lists reject them, even on unused provider proxies. Internal
`NewAutoCloseProxyAdapter` closes each native adapter at most once.

The remaining outbound helper files (`ech.go`, `jls.go`, `reality.go`, `restls.go`,
`shadowtls.go`, `tlsmirror.go`, `singmux.go`, `util.go`) are option parsers or
wrappers, not omitted protocol factories. Apart from REALITY, these optional
graphs are unadmitted. `*_stub.go` build alternatives do not widen the policy.

## Admitted dependency branches: QUIC, WireGuard, Mieru

All versions are from the existing module graph, not new dependencies.

1. `github.com/metacubex/sing-quic`
   `v0.0.0-20260904234848-1c242664697a`,
   `hysteria2/client.go:NewClient`, `offerNew`, `ListenPacket`: retains supplied
   `PacketListener` / `QuicDialer`; racing/retry packet sockets call that
   PacketDialer. `adapter/outbound/hysteria2.go` supplies the native dialer and
   common DialQuic callback. `realm-opts` and server port hopping are **rejected**,
   not covered by an assumption about STUN/control HTTP.
2. `transport/tuic/common/dial.go:DialQuic` and
   `transport/shadowquic/dial.go:DialQuic` custom NetDialer callbacks parse the
   **already resolved numeric** address, call `pDialer.ListenPacket`, and set
   `quic.Transport.Conn`, `SetCreatedConn(true)`, `SetSingleUse(true)`. Failed
   handshakes close packetConn. They do not use `quic.DialAddr`'s default socket.
   Pinned `quic-go` `v0.61.1-0.20260727080200-2548683b76f4` and JLS fork
   `v0.0.0-20260727080412-732f2fc9a34d` `transport.go:Transport.init` reuse a
   nonnil supplied Conn; their `DialAddr` convenience constructors are not called.
3. Hysteria v1's `core/client.go` connects through supplied ClientTransport and
   PacketDialer. `transport/hysteria/conns/udp` hop sockets would use the same
   PacketDialer, but initial socket/hopping ownership is not enabled in this unit.
4. `sing-wireguard` `v0.0.0-20261002050126-e5fa1a607406`,
   `client_bind.go:connect`, `Open`, `Send`, `Close`: connected UDP uses supplied
   `N.Dialer.DialContext`; multi-endpoint UDP uses supplied `ListenPacket`.
   Wireguard-go is given this ClientBind, **not StdNetBind**. No kernel TUN is
   opened: `wireguard.go:newIPStack` selects mipstack; virtual TCP/UDP consumes
   its packets. Both outer bind modes are tested with real protection refusal,
   even though multi-peer profile admission is deliberately narrower.
5. `github.com/enfein/mieru/v3 v3.38.1`:
   `apis/client/client.go:Start` →
   `pkg/appctl/appctlcommon/client.go:NewClientMuxFromProfile` sets the three
   injected interfaces on the Mux. `pkg/protocol/mux.go:newUnderlay` selects
   `NewStreamUnderlay` / `NewPacketUnderlay`;
   `underlay_stream.go:NewStreamUnderlay` uses injected DialContext,
   `underlay_packet.go:NewPacketUnderlay` injected ListenPacket. Its resolver is
   `mieruDNSResolver`, and `BypassDialerDNS` is true. The library's default
   net.Dialer/default UDP dialer and server listen factories exist, but are
   replaced or client-inapplicable on this path. No CLI updater/server is started.

## DNS, background HTTP, listener-side egress and optional transports

- **No Go system resolver assumption.** `component/dialer.parseAddr`, outbound
  `util.go:resolveUDPAddr`, SOCKS relay lookup, Mieru and WireGuard endpoint lookup
  use Mihomo resolver interfaces. Phase 1.2 enables actual DNS before packets,
  supplies IP-literal bootstrap resolvers and rejects system/DHCP/custom upstreams.
  `component/resolver/resolver.go`'s SystemResolver fallback is a Mihomo resolver,
  not `net.DefaultResolver`; `dns/system*.go` discovers numeric nameservers then
  uses native DNS clients. The command's `main.go` net.DefaultResolver panic hook
  is **not** linked into this library and is not credited as protection.
- `dns/client.go`, `dot.go`, `doq.go`, `doh.go` use DNSDialer for TCP, UDP, TLS,
  QUIC and HTTP3 packet sockets. The existing DNS overlay scopes, denies late
  admission, closes transports and rejects DoH redirects; see [DNS.md](DNS.md).
  miekg/dns receives an existing protected conn, not a hostname plus default dial.
- Provider fetches use `component/http/http.go:HttpRequest`'s native callback and
  the existing scoped provider overlay, including every redirect and cache I/O.
  Group/provider health uses `adapter/adapter.go:Proxy.URLTest`: first obtain a
  conn from the chosen admitted proxy, return that conn to HTTP transport, and
  **do not follow redirects**. Omitted group test URL is pinned upstream's HTTPS
  `https://www.gstatic.com/generate_204`; custom URLs must pass HTTPS/no-userinfo.
  Select has no periodic health timer; other groups retain upstream defaults.
- **REALITY (new b).** `component/tls/reality.go:GetRealityConn` originally starts
  `go realityClientFallback` after certificate-valid but unauthenticated handshake.
  That helper's `http.Client` installs only DialTLSContext; a downgrade redirect
  could select the default DialContext, and its worker/sleep has no session owner.
  The engine overlay replaces the launch with `proximaRealityClientFallback`:
  when `DefaultSocketHook != nil`, close the supplied protected conn synchronously
  and launch **no HTTP worker at all**. Authentication still fails. No substitute
  protocol, forged success or post-connect protection is added. Non-hook library
  callers retain upstream fallback. Package-local regression tests execute this
  branch; every changed-source checksum is tested for rejection.
- Admitted stream transports: `transport/vmess/websocket.go:streamWebsocketConn`
  wraps/Upgrades the supplied conn; `h2.go:StreamH2Conn` supplies it to
  `Transport.NewClientConn` (not a redirect-following Client); `gun/gun.go:NewTransport`
  uses the supplied native dial callback for each HTTP2 conn. `vmess/tls.go`
  wraps the existing conn; certificate verification is unchanged except REALITY's
  upstream protocol-specific verifier. REALITY over WS is rejected because that
  upstream WS path does not apply the REALITY config.
- Unadmitted options are **not** silently certified: SS kcptun/v2ray/gost/security
  plugins (`shadowsocks.go:NewShadowSocks`), vmess mKCP/mekya
  (`vmess.go:dialContext`, `NewVmess`), VLESS XHTTP upload/download
  (`vless.go:NewVless`, `transport/xhttp/client.go:NewTransport`), TLSMirror
  (`transport/tlsmirror/traffic.go`) and JLS (`transport/jls/utls.go`) all have
  separate callback/pool/fallback or worker surfaces. Even where a callback is
  visibly supplied, lack of complete lifecycle tests keeps these options closed.
- **Do not ignore listener-side clients.** `listener/http/client.go:newClient`
  returns an in-memory pipe to `tunnel.HandleTCPConn`, not native default HTTP
  networking; `listener/inner:HandleTcp` similarly forwards through the core.
  `listener/restls`, `shadowtls`, `jls`, `reality`, `tlsmirror` builders supply
  camouflage/handshake callbacks to that inner route. `listener/sing_hysteria2`
  masquerade/realm HTTP clients also supply it (masquerade even disables TLS
  verification upstream). Extra listener creation, masquerade, realm and server
  fallback lifetimes are **not admitted** by this executor.
- `listener/sing_tun`'s legacy constructors can start platform interface/routing
  actors; this engine uses only the overlaid app-owned raw-FD branch. The
  `mihomo-runtime/session.go:flowHandler.PrepareConnection` path explicitly
  drops ICMP. It never invokes an independent sing-tun ICMP socket constructor.
- NTP, updater/UI downloads, DHCP discovery and management routes have their own
  native/helper callback paths (`ntp/`, `component/http`, `component/dhcp/conn.go`,
  `component/updater`, `hub/route`). Their configuration/startup is excluded by
  admission and the error-returning executor. They are not enabled because the
  binary happens to contain those packages.

## New overlays and ownership changes

All in `cmd/overlay/main.go`, composed conflict-free with provider/network/runtime:

1. New complete-source pin for `component/tls/reality.go`; protected sessions
   suppress the unauthenticated background HTTP fallback, as above.
2. New complete-source pin for `adapter/outboundgroup/groupbase.go`: close task
   admission and join **onDialFailed-triggered** health work. Nested health calls
   retain their upstream WaitGroups and the Phase 1.3 provider health gate.
   `failedTimes` is atomic because onDialSuccess/health completion overlap failure
   tasks upstream. `ProximaGroupWorkers` is checked after Stop; package-local
   synctest proves Close waits for an admitted task and denies late tasks.
3. Existing `config/config.go` pin now also closes locally constructed proxies
   on `parseProxies` failure (before Config owns them). Names/collisions are
   rejected before constructors. Existing provider pin now closes an entire
   partially parsed payload on **any** subsequent constructor/override/policy
   error, not just an admission-policy error. Timers must not be left to GC.

No patch treats arbitrary custom NetDialer results as raw sockets. No upstream
pin changed; no new full-core protocol-removal build tags or app edits.

## Final admitted routing/config subset

- Top-level `proxies` and every parsed provider payload use the **same** explicit
  `protocolKeys` / `transportKeys` policy in `protocol_admission.go` (provider
  policy runs after conversion/overrides and on refresh, before constructors).
  The exact option lists in that file are authoritative; type admission is not
  permission for arbitrary Mihomo transport/options. Unknown keys fail closed.
- Groups: `select`, `url-test`, `fallback`, `load-balance`; explicit `proxies`
  and/or `use` references. Safe health URL/interval/timeout/lazy/status settings,
  URLTest tolerance, LoadBalance strategy. Unknown keys, automatic include/filter
  graphs, relay, custom routing, persistence and nonzero select timers rejected.
  Upstream still performs actual semantic/reference/DAG/strategy validation.
- Rules: `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-REGEX`,
  `DOMAIN-WILDCARD`, `IP-CIDR`, `IP-CIDR6`, `SRC-IP-CIDR`, `DST-PORT`, `SRC-PORT`,
  `NETWORK`, `RULE-SET`, `MATCH`; DIRECT/REJECT or actual proxy/group targets.
  RULE-SET must name a declared domain/ipcidr provider, including MRS. Upstream
  validates CIDRs/ports/regex/targets/params; existing no-resolve/source semantics
  are not reimplemented by this adapter. `DIRECT` and `REJECT` are **targets**,
  not invented rule opcodes.
- **GEOIP/GEOSITE/IP-ASN remain rejected**, including source variants and nested
  logical-rule attempts. `rules/common/geoip.go`, `geosite.go`, `ipasn.go`
  construct/load geodata via global resource paths; those paths/downloads have
  no reviewed app capability here. `geox-url`, geodata updates and classical
  providers also remain closed. Failure is preferable to a runtime download.

## Evidence and remaining risk

`protocol_test.go` constructs real upstream adapters, tests key/constructor policy
and false protector results at real pre-bind/pre-connect native sockets. Both proxy
TCP and UDP APIs are exercised for Hysteria, Hysteria2, TUIC, ShadowQUIC; TUIC v4
early and v5 normal use the same protected edge. WireGuard's actual ClientBind
connected/unconnected outer sends fail protection; Mieru TCP **and UDP** transports
are tested. WS/gRPC/TFO and VLESS+REALITY refusal use real adapters too. A missing
server, timeout, or constructor error alone is not accepted as protection proof:
the test requires the protection error **and an increased protector call count**.

`routing_test.go` runs reaped one-session children for the four groups, actual
MRS→provider→group routing with MATCH,REJECT as the fallback, actual native domain
matchers, pending group HTTPS health cancellation and partial-parse rollback.
Raw IP/UDP request/reply passes through real mipstack, core routing and protected
native sockets. Testdata/upstream adds package-local REALITY and group-task tests
to the private staged tree, never to the immutable module cache.

See [VERIFICATION.md](VERIFICATION.md) for commands/results. Refusal coverage is
**not** authenticated successful interop for every protocol, port hopping,
QUIC migration/HTTP3 success, Android VpnService behavior, live network changes,
APK loading/alignment, or proof that every library-internal actor joined. Socket
and timer/client closure plus permanent process retirement prevent replacement
lease reuse; **terminate/reap the one-session worker** remains the final actor
fence. No Android supervisor or application integration is added.
