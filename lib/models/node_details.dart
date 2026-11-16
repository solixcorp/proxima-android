/// Public connection metadata extracted from an admitted Mihomo proxy.
/// Credentials and the original proxy mapping are deliberately not retained.
class NodeDetails {
  const NodeDetails({
    required this.protocol,
    required this.server,
    required this.port,
    required this.network,
    required this.security,
    this.serverName,
    this.fingerprint,
    this.flow,
    this.host,
    this.path,
    this.serviceName,
    this.publicKey,
    this.shortId,
  });

  factory NodeDetails.fromProxy(Map<String, Object?> proxy) {
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    Map options(String key) => proxy[key] is Map ? proxy[key] as Map : const {};

    final protocol = text(proxy['type']) ?? '';
    final reality = options('reality-opts');
    final ws = options('ws-opts');
    final headers = ws['headers'] is Map ? ws['headers'] as Map : const {};
    final security = reality.isNotEmpty
        ? 'reality'
        : switch (protocol) {
            'trojan' ||
            'hysteria' ||
            'hysteria2' ||
            'tuic' ||
            'anytls' => 'tls',
            'ssh' => 'ssh',
            'wireguard' => 'wireguard',
            'ss' || 'ssr' => text(proxy['cipher']) ?? '',
            'vless' ||
            'http' ||
            'socks5' => proxy['tls'] == true ? 'tls' : 'none',
            'vmess' =>
              proxy['tls'] == true ? 'tls' : text(proxy['cipher']) ?? '',
            _ => '',
          };
    final server = text(proxy['server']);
    return NodeDetails(
      protocol: protocol,
      server: server,
      port: proxy['port'] is int ? proxy['port'] as int : null,
      network:
          text(proxy['network']) ??
          text(proxy['transport']) ??
          switch (protocol) {
            'hysteria' => text(proxy['protocol']) ?? 'udp',
            'hysteria2' || 'tuic' || 'wireguard' => 'udp',
            'direct' || 'reject' => '',
            _ => 'tcp',
          },
      security: security,
      serverName:
          text(proxy['servername']) ??
          text(proxy['sni']) ??
          (security == 'tls' || security == 'reality' ? server : null),
      fingerprint: text(proxy['client-fingerprint']),
      flow: text(proxy['flow']),
      host: text(headers['Host']) ?? text(headers['host']),
      // Query strings and fragments can contain authentication tokens.
      path: text(ws['path'])?.split(RegExp(r'[?#]')).first,
      serviceName: text(options('grpc-opts')['grpc-service-name']),
      publicKey: text(reality['public-key']),
      shortId: text(reality['short-id']),
    );
  }

  final String protocol;
  final String? server;
  final int? port;
  final String network;
  final String security;
  final String? serverName;
  final String? fingerprint;
  final String? flow;
  final String? host;
  final String? path;
  final String? serviceName;
  final String? publicKey;
  final String? shortId;
}
