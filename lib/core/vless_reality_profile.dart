import 'dart:convert';

import 'clash_subscription.dart';

/// A single VLESS share link using REALITY transport settings.
///
/// Proxima deliberately accepts a narrow link format.  This keeps every saved
/// profile compatible with the bundled Xray core instead of accepting a
/// broader link and failing later while connecting.
class VlessRealityProfile {
  static const routingMetadataPrefix = '# proxima-routing-rules:';
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
      'xhttp' || 'splithttp' => 'xhttp',
      'grpc' => 'grpc',
      'ws' || 'websocket' => throw const FormatException(
        'REALITY는 WebSocket 전송을 지원하지 않습니다.',
      ),
      _ => throw const FormatException('RAW(TCP), XHTTP, gRPC 전송 방식만 지원합니다.'),
    };
    final path = query('path');
    final host = query('host');
    final serviceName = query('serviceName');

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

  /// Converts either a share-link list or a Clash.Meta subscription into the
  /// app-owned profile format consumed by the Android Xray runtime.
  static String storedConfigFromInput(
    String input, {
    required String profileName,
  }) {
    final clash = ClashSubscriptionParser.tryParse(input);
    final sourceLinks = clash?.links ?? linksFromSubscription(input);
    final profiles = sourceLinks
        .map(VlessRealityProfile.parse)
        .toList(growable: false);
    var config = profilesToMihomoYaml(profiles, profileName: profileName);
    if (clash != null) {
      final encoded = encodeRoutingMetadata(clash.routing);
      config = '$routingMetadataPrefix $encoded\n$config';
    }
    return config;
  }

  static bool hasRoutingMetadata(String content) =>
      routingMetadataVersion(content) != null;

  /// Version 2 preserves each Clash policy group's node candidates. Version 1
  /// collapsed all non-regional policies into a single automatic pool.
  static bool hasCurrentRoutingMetadata(String content) =>
      (routingMetadataVersion(content) ?? 0) >= 2;

  static int? routingMetadataVersion(String content) {
    final metadataLine = content
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere(
          (line) => line.startsWith(routingMetadataPrefix),
          orElse: () => '',
        );
    if (metadataLine.isEmpty) return null;
    final encoded = metadataLine.substring(routingMetadataPrefix.length).trim();
    if (encoded.isEmpty) return null;
    try {
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      return decoded is Map ? decoded['version'] as int? : null;
    } on FormatException {
      return null;
    }
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
    if (network == 'xhttp' && path != null) ...[
      '    xhttp-opts:',
      '      path: ${_yaml(path!)}',
    ],
    if (network == 'grpc' && serviceName != null) ...[
      '    grpc-opts:',
      '      grpc-service-name: ${_yaml(serviceName!)}',
    ],
  ];

  static String? linkFromStoredConfig(String content) {
    final links = linksFromStoredConfig(content);
    return links.isEmpty ? null : links.first;
  }

  /// Keep the refresh URL alongside the generated configuration as well as in
  /// Android metadata. This lets a profile survive metadata migrations.
  static String attachSubscriptionSource(String config, String? sourceUrl) {
    final source = sourceUrl?.trim();
    if (source == null || source.isEmpty) return config;
    final bytes = utf8.encode(source);
    final encoded = base64UrlEncode(bytes).replaceAll('=', '');
    return '# proxima-subscription-url: $encoded\n$config';
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
    final clash = ClashSubscriptionParser.tryParse(value);
    if (clash != null) return clash.links;
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

  /// Finds a human-facing provider name without treating a transport label
  /// such as "VLESS REALITY" or a single country/node suffix as a profile
  /// name. Providers commonly put their branding in the VLESS fragment
  /// (`#Provider | Japan 01`), while subscriptions expose it in their host.
  static String suggestedProfileName(
    String input, {
    String? sourceUrl,
    String? fallbackName,
  }) {
    final fromSource = _providerFromHost(sourceUrl);
    if (fromSource != null) return fromSource;

    final profiles = parseMany(input);
    final fromLabels = _providerFromLabels(
      profiles.map((profile) => profile.name),
    );
    if (fromLabels != null) return fromLabels;

    final fromFileName = _cleanProviderLabel(
      _withoutExtension(fallbackName ?? ''),
    );
    if (fromFileName != null) return fromFileName;

    return _providerFromHost(profiles.first.server) ?? 'VLESS REALITY';
  }

  static bool isAutomaticProfileName(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(
      RegExp(r'[\s._|·:/\\-]+'),
      ' ',
    );
    return normalized.isEmpty ||
        normalized == 'vless' ||
        normalized == 'vless reality' ||
        normalized.startsWith('vless reality ');
  }

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

  static String? _providerFromLabels(Iterable<String> labels) {
    final values = labels
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && !isAutomaticProfileName(value))
        .toList(growable: false);
    if (values.isEmpty) return null;
    if (values.length == 1) return _cleanProviderLabel(values.single);

    final parts = values
        .map((value) => value.split(RegExp(r'[\s|·:/\\_-]+')))
        .toList(growable: false);
    final common = <String>[];
    for (var index = 0; ; index++) {
      final candidate = parts.first.length > index ? parts.first[index] : null;
      if (candidate == null || candidate.isEmpty) break;
      if (parts
          .skip(1)
          .any(
            (other) =>
                other.length <= index ||
                other[index].toLowerCase() != candidate.toLowerCase(),
          )) {
        break;
      }
      common.add(candidate);
    }
    return _cleanProviderLabel(common.join(' '));
  }

  static String? _cleanProviderLabel(String value) {
    var label = value.trim();
    if (label.isEmpty || isAutomaticProfileName(label)) return null;
    label = label
        .replaceFirst(
          RegExp(
            r'^(?:(?:vless|reality|vmess|trojan|ss|ssr)(?:[\s._|·:/\\-]+|$))',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    final parts = label
        .split(RegExp(r'[\s|·:/\\_-]+'))
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    final provider = parts
        .takeWhile((part) => !_isNodeOrRegionToken(part))
        .join(' ')
        .trim();
    if (provider.isEmpty || isAutomaticProfileName(provider)) return null;
    return provider.length > 80 ? provider.substring(0, 80) : provider;
  }

  static bool _isNodeOrRegionToken(String value) {
    final token = value.toLowerCase();
    return RegExp(r'^\d+$').hasMatch(token) ||
        RegExp(
          r'^(?:jp|kr|us|usa|uk|hk|tw|sg|de|fr|cn|japan|korea|korean|japanese|america|usa|hongkong|taiwan|singapore|germany|france|일본|한국|미국|홍콩|대만|싱가포르|독일|프랑스|중국)\d*$',
        ).hasMatch(token);
  }

  static String? _providerFromHost(String? source) {
    final host = Uri.tryParse(source ?? '')?.host.toLowerCase();
    if (host == null || host.isEmpty) return null;
    final labels = host.split('.');
    if (labels.length < 2) return _cleanProviderLabel(host);
    const ignored = {
      'www',
      'my',
      'sub',
      'subscribe',
      'subscription',
      'api',
      'cdn',
      'edge',
      'proxy',
      'vpn',
      'vless',
      'com',
      'net',
      'org',
      'io',
      'co',
      'kr',
      'jp',
      'us',
      'uk',
      'cn',
      'de',
      'fr',
    };
    String? candidate;
    for (final label in labels.take(labels.length - 1)) {
      if (!ignored.contains(label)) candidate = label;
    }
    return candidate == null ? null : _cleanProviderLabel(candidate);
  }

  static String _withoutExtension(String value) {
    final slash = value.lastIndexOf(RegExp(r'[/\\]'));
    final file = slash >= 0 ? value.substring(slash + 1) : value;
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
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
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _realityPublicKey = RegExp(r'^[A-Za-z0-9_-]{20,}$');
  static final _shortId = RegExp(r'^[0-9a-fA-F]{1,16}$');
}
