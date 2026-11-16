# Phase 1.2 DNS contract

## Admission and defaults

`Start` (not raw `Decode`) enables the actual Mihomo resolver, enhancer and
service using executor `updateDNS` **before** TUN admission. Omitted `dns:`,
`dns: {}`, or a partial mapping gets executable defaults: redir-host, IP-literal
certificate-verified DoH at `https://1.1.1.1/dns-query` and
`https://8.8.8.8/dns-query`, also used for bootstrap, no system hosts, no
plaintext/system DNS fallback, no geodata and no fake-IP pool. These endpoints
match the existing app's public DoH defaults. Raw snapshots/revisions remain
byte-exact; defaults affect only the admitted copy. Explicit empty nameserver/
bootstrap lists and `enable: false` are errors. Startup does not probe upstream
reachability: failed queries yield native SERVFAIL, not an insecure fallback or
a successful connectivity claim.

Allowed DNS keys: `enable`, `enhanced-mode`, `nameserver`, `default-nameserver`,
`fallback`, `ipv6`, `ipv6-timeout`, `prefer-h3`, `use-hosts`, `use-system-hosts`
(false only), `respect-rules` (false only), `cache-algorithm`, `cache-max-size`.
Only `redir-host` is admitted. `fake-ip` fails with **"not supported yet"** before
semantic parsing, including profiles that also request fake-IP pool settings.
Listener/policy/geodata/fake-IP/custom routing options remain fail-closed.
Fallback servers may be explicitly selected, but no GeoIP/domain filter is
implicitly enabled. DNS IPv6 answers also require general `ipv6: true`.

## Upstream security policy

Upstreams allow bare UDP addresses and `udp://`, `tcp://`, `tls://`, `quic://`
(DoQ), `https://` (DoH). Explicit UDP/TCP is plaintext and opt-in; do not describe
those choices as encrypted. Hosts and valid nonzero ports are required;
bootstrap addresses must be IP literals. HTTP, userinfo, query/fragment overrides
(including `skip-cert-verify`, custom dialers, proxy/interface selection), system,
DHCP and overlay transports are rejected. DoH redirects are rejected before any
second request, including HTTPS-to-HTTP downgrade. Certificate checks are never
disabled. Unlike providerpolicy.URL, DNS must allow explicit non-HTTP protocols;
the HTTPS/no-userinfo principle is retained for DoH. Local/private addresses are
allowed for app-selected resolvers and tests, not an SSRF isolation boundary.

## Hijack and lifetime

The app's `172.19.0.2:53` is always retained, including old `dns-hijack: []` or an
omitted field; a profile cannot accidentally forward this synthetic address.
Additional IP-literal `:53` destinations and explicit `any:53`/`0.0.0.0:53`/
`[::]:53` wildcards are accepted. As in pinned upstream sing_tun, a `tcp://` or
`udp://` prefix selects **both** transports, not protocol-specific interception.
Other ports/schemes are rejected. An omitted field does not inherit upstream's
desktop wildcard default.

Path: `sing_tun.New` raw-FD branch → runtime `flowHandler` → existing
`mihomo-dns.NewHijack` → `resolver.RelayDnsPacket`/`RelayDnsConn` → actual
`resolver.DefaultService` → native DNS transports. The seam is retained, not
replaced with synthetic DNS; its bounded EDNS/TC and TCP framing behavior is
unchanged. UDP dispatchers are owned/joined by the runtime; TCP is synchronous.
Matching is stable after Stop and cannot fall through into ordinary routing.

The checksum-gated DNSDialer lifetime wraps actual `DialContext` **and**
`ListenPacket` (DoQ/DoH3). Admitted settings select only the native protected
direct dialer. Both go through the permanent session hook before bind/connect;
false protector results fail the socket operation. Wrappers preserve UDP's
`net.PacketConn` capability, required by miekg/dns's wire framing. Stop cancels
and drains dial admission, closes tracked transport sockets and denies late
native refresh/retry dials **before** releasing the protection lease. DNS
initialization or interception-construction failure follows Start's existing
full rollback, including TUN duplicates and callback ownership/release retry.

Phase 1.3 adds a resolver job lifetime: cancel/join bootstrap/A+AAAA/fallback,
refresh, retry and real singleflight jobs, join UDP/DoT wire helpers, and close
native DoH/QUIC/DoT pools explicitly. This is still not a synchronous join proof
for every library-internal HTTP/QUIC actor: process retirement and
termination/reaping remain mandatory, as in Phase 1.1. See [PROVIDERS.md](PROVIDERS.md).
No Android
worker supervisor or application integration is included. DNS remains direct
(protected but outside the VPN), not arbitrary proxy-routed DNS. Protocol and
custom-dialer auditing is documented in [DIALERS.md](DIALERS.md).

## Host verification

DNS process tests inject actual raw UDP/TCP :53 packets through mips, use local
UDP/TCP authoritative fixtures and a locally trusted HTTPS DoH fixture, and
check A/AAAA/TXT replies, TCP length framing, wildcard selection, redirect denial,
UDP/TCP/DoH/DoQ protection refusal, packet-socket refusal, pending-query drain,
DNS-init rollback and the post-stop dial gate. Fixtures alone supply fixed
answers; production uses the pinned Mihomo DNS module. Fake-IP rejection and
upstream security-policy/FD-rollback tests run before semantic parsing.

`bash build.sh test` at the repository root covers all seven native modules;
`bash build.sh android` covers all four ABIs. Neither gate establishes Android
VpnService routes, synthetic-address collision behavior, packaging/loading or
live DNS/network transition behavior; those still need device verification.
