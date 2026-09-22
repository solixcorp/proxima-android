import 'dart:convert';

/// A single VLESS share link using REALITY transport settings.
///
/// Proxima deliberately accepts a narrow link format.  This keeps every saved
/// profile compatible with the bundled Xray core instead of accepting a
/// broader link and failing later while connecting.
class VlessRealityProfile {
  const VlessRealityProfile({
    required this.sourceLink,
    required this.name,
    required this.server,
    required this.port,
    required this.uuid,
    required this.serverName,
    required this.publicKey,
    required this.shortId,
    required this.fingerprint,
    required this.flow,
    required this.network,
    this.path,
    this.host,
    this.serviceName,
  });

  factory VlessRealityProfile.parse(String value) {
    final source = value.trim();
    if (source.isEmpty) throw const FormatException('VLESS 링크를 입력해 주세요.');

    late final Uri uri;
    try {
      uri = Uri.parse(source);
    } on FormatException {
      throw const FormatException('유효한 VLESS 링크가 아닙니다.');
    }
    if (uri.scheme.toLowerCase() != 'vless') {
      throw const FormatException('VLESS 링크만 지원합니다.');
    }
    if (uri.userInfo.isEmpty || !_uuid.hasMatch(uri.userInfo)) {
      throw const FormatException('VLESS UUID를 확인해 주세요.');
    }
    if (uri.host.isEmpty || uri.port <= 0 || uri.port > 65535) {
      throw const FormatException('서버 주소 또는 포트를 확인해 주세요.');
    }

    String query(String key, {String fallback = ''}) =>
        uri.queryParameters[key]?.trim() ?? fallback;
    if (query('encryption', fallback: 'none').toLowerCase() != 'none') {
      throw const FormatException('VLESS encryption=none만 지원합니다.');
    }
    if (query('security').toLowerCase() != 'reality') {
      throw const FormatException('VLESS + REALITY 링크만 지원합니다.');
    }
    final publicKey = query('pbk');
    if (publicKey.isEmpty || !_realityPublicKey.hasMatch(publicKey)) {
      throw const FormatException('REALITY public key(pbk)를 확인해 주세요.');
    }
    final shortId = query('sid');
    if (shortId.isNotEmpty && !_shortId.hasMatch(shortId)) {
      throw const FormatException('REALITY short ID(sid)를 확인해 주세요.');
    }

    final type = query('type', fallback: 'tcp').toLowerCase();
    final network = switch (type) {
      'tcp' || 'raw' => 'tcp',
      'ws' => 'ws',
      'grpc' => 'grpc',
      _ => throw const FormatException('tcp, ws, grpc 전송 방식만 지원합니다.'),
    };
    final path = query('path');
    final host = query('host');
    final serviceName = query('serviceName');
    if (network == 'ws' && path.isEmpty) {
      throw const FormatException('WebSocket VLESS 링크에는 path가 필요합니다.');
    }
    if (network == 'grpc' && serviceName.isEmpty) {
      throw const FormatException('gRPC VLESS 링크에는 serviceName이 필요합니다.');
    }

    final fragment = _decodeFragment(uri.fragment.trim());
    final serverName = query('sni');
    return VlessRealityProfile(
      sourceLink: uri.toString(),
      name: fragment.isEmpty ? 'VLESS REALITY · ${uri.host}' : fragment,
      server: uri.host,
      port: uri.port,
      uuid: uri.userInfo,
      serverName: serverName.isEmpty ? uri.host : serverName,
      publicKey: publicKey,
      shortId: shortId,
      fingerprint: query('fp', fallback: 'chrome'),
      flow: query('flow'),
      network: network,
      path: path.isEmpty ? null : path,
      host: host.isEmpty ? null : host,
      serviceName: serviceName.isEmpty ? null : serviceName,
    );
  }

  final String sourceLink;
  final String name;
  final String server;
  final int port;
  final String uuid;
  final String serverName;
  final String publicKey;
  final String shortId;
  final String fingerprint;
  final String flow;
  final String network;
  final String? path;
  final String? host;
  final String? serviceName;

  String toMihomoYaml({required String profileName}) {
    return profilesToMihomoYaml([this], profileName: profileName);
  }

  static String profilesToMihomoYaml(
    List<VlessRealityProfile> profiles, {
    required String profileName,
  }) {
    if (profiles.isEmpty) {
      throw const FormatException('VLESS 링크를 입력해 주세요.');
    }
    final nodeNames = _uniqueNodeNames(profiles, profileName: profileName);
    final lines = <String>[
      for (final profile in profiles)
        '# proxima-vless-reality-link: ${_encodeLink(profile.sourceLink)}',
      'mixed-port: 7890',
      'allow-lan: false',
      'mode: rule',
      'log-level: info',
      'find-process-mode: off',
      'ipv6: true',
      'unified-delay: true',
      'tcp-concurrent: true',
      '',
      'tun:',
      '  enable: false',
      '',
      'dns:',
      '  enable: true',
      '  ipv6: true',
      '  enhanced-mode: fake-ip',
      '  fake-ip-range: 198.18.0.1/16',
      '  nameserver:',
      '    - 1.1.1.1',
      '    - 8.8.8.8',
      '',
      'proxies:',
      for (var index = 0; index < profiles.length; index++) ...[
        ...profiles[index]._proxyYaml(nodeNames[index]),
        '',
      ],
      'proxy-groups:',
      '  - name: PROXY',
      '    type: select',
      '    proxies:',
      for (final node in nodeNames) '      - ${_yaml(node)}',
      '  - name: GLOBAL',
      '    type: select',
      '    proxies:',
      for (final node in nodeNames) '      - ${_yaml(node)}',
      '',
      'rules:',
      '  - MATCH,PROXY',
      '',
    ];
    return lines.join('\n');
  }

  List<String> _proxyYaml(String nodeName) => [
    '  - name: ${_yaml(nodeName)}',
    '    type: vless',
    '    server: ${_yaml(server)}',
    '    port: $port',
    '    uuid: ${_yaml(uuid)}',
    '    udp: true',
    '    tls: true',
    '    servername: ${_yaml(serverName)}',
    '    client-fingerprint: ${_yaml(fingerprint)}',
    '    network: $network',
    '    reality-opts:',
    '      public-key: ${_yaml(publicKey)}',
    if (shortId.isNotEmpty) '      short-id: ${_yaml(shortId)}',
    if (flow.isNotEmpty) '    flow: ${_yaml(flow)}',
    if (network == 'ws') ...[
      '    ws-opts:',
      '      path: ${_yaml(path!)}',
      if (host != null) '      headers:',
      if (host != null) '        Host: ${_yaml(host!)}',
    ],
    if (network == 'grpc') ...[
      '    grpc-opts:',
      '      grpc-service-name: ${_yaml(serviceName!)}',
    ],
  ];

  static String? linkFromStoredConfig(String content) {
    final links = linksFromStoredConfig(content);
    return links.isEmpty ? null : links.first;
  }

  static List<String> linksFromStoredConfig(String content) {
    final match = RegExp(
      r'^# proxima-vless-reality-link: ([A-Za-z0-9_-]+)\s*$',
      multiLine: true,
    ).allMatches(content);
    return match
        .map((item) => _decodeLink(item.group(1)!))
        .whereType<String>()
        .toList(growable: false);
  }

  static String linkFromSubscription(String value) {
    final links = linksFromSubscription(value);
    if (links.length != 1) {
      throw const FormatException('한 프로필에는 VLESS REALITY 링크 하나만 사용할 수 있습니다.');
    }
    return links.single;
  }

  static List<String> linksFromSubscription(String value) {
    final directLinks = _vlessLines(value);
    final decodedLinks = directLinks.isNotEmpty
        ? directLinks
        : _vlessLines(_decodeSubscription(value));
    if (decodedLinks.isEmpty) {
      throw const FormatException('구독에서 VLESS 링크를 찾지 못했습니다.');
    }
    return decodedLinks;
  }

  /// Accepts either plain VLESS URI lines or Base64/Base64URL-wrapped links.
  /// QR providers commonly wrap even a single URI this way.
  static String normalizeLinkInput(String value) =>
      linksFromSubscription(value).join('\n');

  static List<VlessRealityProfile> parseMany(String value) =>
      linksFromSubscription(value)
          .map(VlessRealityProfile.parse)
          .toList(growable: false);

  static List<String> nodeNamesFromStoredConfig(
    String content, {
    required String profileName,
  }) {
    final profiles = linksFromStoredConfig(content)
        .map(VlessRealityProfile.parse)
        .toList(growable: false);
    return _uniqueNodeNames(profiles, profileName: profileName);
  }

  static List<String> _vlessLines(String value) => value
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.toLowerCase().startsWith('vless://'))
      .toList(growable: false);

  static String _decodeSubscription(String value) {
    final compact = value.replaceAll(RegExp(r'\s'), '');
    if (compact.isEmpty) return '';
    try {
      final padded = compact.padRight((compact.length + 3) ~/ 4 * 4, '=');
      return utf8.decode(base64Url.decode(padded));
    } on FormatException {
      try {
        return utf8.decode(base64.decode(base64.normalize(compact)));
      } on FormatException {
        return '';
      }
    }
  }

  static List<String> _uniqueNodeNames(
    List<VlessRealityProfile> profiles, {
    required String profileName,
  }) {
    if (profiles.length == 1) {
      final singleName = profileName.trim().isEmpty
          ? profiles.single.name
          : profileName.trim();
      return [singleName];
    }
    final counts = <String, int>{};
    return profiles
        .map((profile) {
          final base = profile.name.trim().isEmpty
              ? profile.server
              : profile.name;
          final next = (counts[base] ?? 0) + 1;
          counts[base] = next;
          return next == 1 ? base : '$base $next';
        })
        .toList(growable: false);
  }

  static String _encodeLink(String value) =>
      base64UrlEncode(utf8.encode(value)).replaceAll('=', '');

  static String? _decodeLink(String encoded) {
    try {
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      return utf8.decode(base64Url.decode(padded));
    } on FormatException {
      return null;
    }
  }

  static String _yaml(String value) => jsonEncode(value);

  static String _decodeFragment(String value) {
    if (value.isEmpty) return value;
    try {
      return Uri.decodeComponent(value);
    } on FormatException {
      return value;
    }
  }

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _realityPublicKey = RegExp(r'^[A-Za-z0-9_-]{20,}$');
  static final _shortId = RegExp(r'^[0-9a-fA-F]{1,16}$');
}
