import 'dart:convert';

import 'package:yaml/yaml.dart';

/// The Xray-oriented representation of a Clash.Meta subscription.
///
/// Clash selectors do not have a direct Xray equivalent. For rule mode we
/// preserve the concrete nodes behind each policy group, so a regional group
/// does not collapse into the global fastest-node pool when translated to
/// Xray. A `select` group follows its provider-default (first) choice while
/// url-test/fallback/load-balance groups retain all of their candidates.
class ClashSubscriptionConversion {
  const ClashSubscriptionConversion({
    required this.links,
    required this.routing,
  });

  final List<String> links;
  final Map<String, Object?> routing;
}

class ClashSubscriptionParser {
  const ClashSubscriptionParser._();

  /// Optional Clash-style rules placed after a plain VLESS link list.
  /// A share link only describes a server, so destination rules must be
  /// supplied separately when the subscription is not Clash YAML.
  static Map<String, Object?>? rulesForLinks(
    String source,
    List<String> nodeNames,
  ) {
    final lines = source.split(RegExp(r'\r?\n')).map((line) => line.trim());
    final ruleLines = lines
        .where(
          (line) => RegExp(
            r'^[A-Z][A-Z0-9-]*,',
            caseSensitive: false,
          ).hasMatch(line),
        )
        .toList(growable: false);
    if (ruleLines.isEmpty) return null;
    String resolveTarget(String value) {
      final target = value.trim();
      if (target.toUpperCase() == 'DIRECT') return 'direct';
      if (target.toUpperCase() == 'REJECT' ||
          target.toUpperCase() == 'REJECT-DROP') {
        return 'block';
      }
      if (target == 'PROXY' || nodeNames.contains(target)) return 'proxy';
      throw FormatException('규칙의 노드 "$target"를 찾을 수 없습니다.');
    }

    List<String> resolveCandidates(String value) {
      final target = value.trim();
      if (target == 'PROXY') return nodeNames;
      return nodeNames.contains(target) ? [target] : const [];
    }

    final rules = <Map<String, Object?>>[];
    final displayRules = <Map<String, Object?>>[];
    for (final line in ruleLines) {
      final rule = _parseRule(line, resolveTarget, resolveCandidates);
      if (rule != null) rules.add(rule);
      displayRules.add(_displayRule(line, rule));
    }
    if (!rules.any((rule) => rule['match'] == true)) {
      rules.add({
        'match': true,
        'target': 'proxy',
        'policy': 'PROXY',
        'candidates': nodeNames,
      });
    }
    return {
      'version': 2,
      'source': 'vless-links',
      'autoTestUrl': 'https://www.gstatic.com/generate_204',
      'rules': rules,
      'displayRules': displayRules,
    };
  }

  static ClashSubscriptionConversion? tryParse(String source) {
    if (!source.contains('proxies:') || !source.contains('proxy-groups:')) {
      return null;
    }
    final Object? document;
    try {
      document = loadYaml(source);
    } on YamlException {
      return null;
    }
    final root = _stringMap(document);
    if (root == null) return null;
    final proxyRows = _list(root['proxies']);
    final groupRows = _list(root['proxy-groups']);
    final rawRules = _list(root['rules']);
    if (proxyRows == null || groupRows == null || rawRules == null) return null;

    final links = <String>[];
    final realProxyNames = <String>{};
    for (final row in proxyRows) {
      final proxy = _stringMap(row);
      if (proxy == null || proxy['type']?.toString().toLowerCase() != 'vless') {
        continue;
      }
      final link = _vlessLink(proxy);
      if (link == null) continue;
      final name = proxy['name']?.toString().trim() ?? '';
      if (_isInformationNode(name)) continue;
      links.add(link);
      realProxyNames.add(name);
    }
    if (links.isEmpty) {
      throw const FormatException('Clash 구독에서 지원되는 VLESS 노드를 찾지 못했습니다.');
    }

    final groups = <String, Map<String, Object?>>{};
    for (final row in groupRows) {
      final group = _stringMap(row);
      final name = group?['name']?.toString().trim();
      if (group != null && name != null && name.isNotEmpty) {
        groups[name] = group;
      }
    }

    String resolveTarget(String value, [Set<String>? visited]) {
      final target = value.trim();
      final upper = target.toUpperCase();
      if (upper == 'DIRECT') return 'direct';
      if (upper == 'REJECT' || upper == 'REJECT-DROP') return 'block';
      if (realProxyNames.contains(target)) return 'proxy';
      final group = groups[target];
      if (group == null) return 'proxy';
      final type = group['type']?.toString().toLowerCase() ?? '';
      if (type == 'url-test' || type == 'load-balance' || type == 'fallback') {
        return 'proxy';
      }
      final seen = {...?visited};
      if (!seen.add(target)) return 'proxy';
      final choices = _list(group['proxies']);
      if (choices == null || choices.isEmpty) return 'proxy';
      return resolveTarget(choices.first.toString(), seen);
    }

    List<String> resolveCandidates(String value, [Set<String>? visited]) {
      final target = value.trim();
      if (realProxyNames.contains(target)) return [target];
      final group = groups[target];
      if (group == null) return const [];
      final seen = {...?visited};
      if (!seen.add(target)) return const [];
      final choices = _list(group['proxies']);
      if (choices == null || choices.isEmpty) return const [];
      final type = group['type']?.toString().toLowerCase() ?? '';
      final selected = type == 'select' ? choices.take(1) : choices;
      final result = <String>[];
      for (final choice in selected) {
        for (final node in resolveCandidates(choice.toString(), seen)) {
          if (!result.contains(node)) result.add(node);
        }
      }
      return result;
    }

    final rules = <Map<String, Object?>>[];
    final displayRules = <Map<String, Object?>>[];
    for (final item in rawRules) {
      final source = item.toString();
      final parsed = _parseRule(
        source,
        resolveTarget,
        resolveCandidates,
      );
      if (parsed != null) rules.add(parsed);
      displayRules.add(_displayRule(source, parsed));
    }
    if (!rules.any((rule) => rule['match'] == true)) {
      rules.add(const {'match': true, 'target': 'proxy'});
    }
    return ClashSubscriptionConversion(
      links: List.unmodifiable(links),
      routing: {
        'version': 2,
        'source': 'clash-meta',
        'autoTestUrl': _automaticTestUrl(groups),
        'rules': rules,
        'displayRules': displayRules,
      },
    );
  }

  static String? _vlessLink(Map<String, Object?> proxy) {
    final reality = _stringMap(proxy['reality-opts']);
    final uuid = proxy['uuid']?.toString().trim() ?? '';
    final server = proxy['server']?.toString().trim() ?? '';
    final port = _integer(proxy['port']);
    final publicKey = reality?['public-key']?.toString().trim() ?? '';
    if (uuid.isEmpty ||
        server.isEmpty ||
        port == null ||
        (reality != null && publicKey.isEmpty)) {
      return null;
    }
    final network = proxy['network']?.toString().trim().toLowerCase();
    final parameters = <String, String>{
      'encryption': 'none',
      'security': reality != null
          ? 'reality'
          : proxy['tls'] == true
          ? 'tls'
          : 'none',
      'type': network == null || network.isEmpty ? 'tcp' : network,
      if (reality != null) 'pbk': publicKey,
      'sni': proxy['servername']?.toString().trim().isNotEmpty == true
          ? proxy['servername'].toString().trim()
          : server,
      'fp': proxy['client-fingerprint']?.toString().trim().isNotEmpty == true
          ? proxy['client-fingerprint'].toString().trim()
          : 'chrome',
    };
    void add(String outputKey, String inputKey) {
      final value = proxy[inputKey]?.toString().trim();
      if (value != null && value.isNotEmpty) parameters[outputKey] = value;
    }

    add('flow', 'flow');
    final shortId = reality?['short-id']?.toString().trim();
    if (shortId != null && shortId.isNotEmpty) parameters['sid'] = shortId;
    final alpn = _list(proxy['alpn']);
    if (alpn != null && alpn.isNotEmpty) parameters['alpn'] = alpn.join(',');
    if (proxy['skip-cert-verify'] == true) parameters['allowInsecure'] = '1';
    final ws = _stringMap(proxy['ws-opts']);
    final xhttp = _stringMap(proxy['xhttp-opts']);
    final grpc = _stringMap(proxy['grpc-opts']);
    void addOption(String key, Object? value) {
      final text = value?.toString();
      if (text != null && text.isNotEmpty) parameters[key] = text;
    }

    if (network == 'ws' || network == 'websocket') {
      addOption('path', ws?['path']);
      final headers = _stringMap(ws?['headers']);
      for (final entry in headers?.entries ?? <MapEntry<String, Object?>>[]) {
        if (entry.key.toLowerCase() == 'host') addOption('host', entry.value);
      }
    } else if (network == 'xhttp' || network == 'splithttp') {
      addOption('path', xhttp?['path']);
      addOption('host', xhttp?['host']);
      addOption('mode', xhttp?['mode']);
    } else if (network == 'grpc') {
      addOption('serviceName', grpc?['grpc-service-name']);
    }
    final name = proxy['name']?.toString().trim() ?? server;
    return Uri(
      scheme: 'vless',
      userInfo: uuid,
      host: server,
      port: port,
      queryParameters: parameters,
      fragment: name,
    ).toString();
  }

  static Map<String, Object?> _displayRule(
    String source,
    Map<String, Object?>? parsed,
  ) => {
    ...?parsed,
    'raw': source,
    'supported': parsed != null && supportsRule(parsed),
  };

  // XrayConfig normalizes only these private-network geo conditions locally.
  // Apply the same check when reading profiles saved by older app versions.
  static bool supportsRule(Map<String, Object?> rule) =>
        rule['supported'] != false &&
        !(rule['domain'] as List? ?? const []).any(
          (value) => value.toString().startsWith('geosite:') &&
              value != 'geosite:private',
        ) &&
        !(rule['ip'] as List? ?? const []).any(
          (value) => value.toString().startsWith('geoip:') &&
              value != 'geoip:private' &&
              value != 'geoip:lan',
        );

  static Map<String, Object?>? _parseRule(
    String source,
    String Function(String value) resolveTarget,
    List<String> Function(String value) resolveCandidates,
  ) {
    final rule = source.trim();
    if (rule.isEmpty) return null;
    if (rule.toUpperCase().startsWith('AND,')) {
      final match = RegExp(
        r'^AND,\(\(DOMAIN-(SUFFIX|KEYWORD),([^\)]+)\),\(NETWORK,(TCP|UDP)\),\(DST-PORT,([^\)]+)\)\),(.+)$',
        caseSensitive: false,
      ).firstMatch(rule);
      if (match == null) return null;
      final target = resolveTarget(match.group(5)!);
      return {
        'domain': [_domainValue('DOMAIN-${match.group(1)!}', match.group(2)!)],
        'network': match.group(3)!.toLowerCase(),
        'port': match.group(4)!.trim(),
        'target': target,
        if (target == 'proxy') ...{
          'policy': match.group(5)!.trim(),
          if (resolveCandidates(match.group(5)!).isNotEmpty)
            'candidates': resolveCandidates(match.group(5)!),
        },
      };
    }

    final values = _splitCsv(rule);
    if (values.isEmpty) return null;
    final kind = values.first.toUpperCase();
    Map<String, Object?> targetFields(String source) {
      final target = resolveTarget(source);
      return {
        'target': target,
        if (target == 'proxy') ...{
          'policy': source,
          if (resolveCandidates(source).isNotEmpty)
            'candidates': resolveCandidates(source),
        },
      };
    }

    if (kind == 'MATCH' && values.length >= 2) {
      return {'match': true, ...targetFields(values[1])};
    }
    if (values.length < 3) return null;
    switch (kind) {
      case 'DOMAIN':
      case 'DOMAIN-SUFFIX':
      case 'DOMAIN-KEYWORD':
      case 'GEOSITE':
        final result = <String, Object?>{
          'domain': [_domainValue(kind, values[1])],
          ...targetFields(values[2]),
        };
        return result;
      case 'IP-CIDR':
      case 'IP-CIDR6':
        final result = <String, Object?>{
          'ip': [values[1].trim()],
          ...targetFields(values[2]),
        };
        return result;
      case 'GEOIP':
        final result = <String, Object?>{
          'ip': ['geoip:${values[1].trim().toLowerCase()}'],
          ...targetFields(values[2]),
        };
        return result;
      default:
        return null;
    }
  }

  static String _domainValue(String kind, String raw) {
    final value = raw.trim();
    return switch (kind.toUpperCase()) {
      'DOMAIN' => 'full:$value',
      'DOMAIN-SUFFIX' => 'domain:$value',
      'DOMAIN-KEYWORD' => 'plain:$value',
      'GEOSITE' => 'geosite:${value.toLowerCase()}',
      _ => value,
    };
  }

  static List<String> _splitCsv(String value) =>
      value.split(',').map((part) => part.trim()).toList(growable: false);

  static String _automaticTestUrl(Map<String, Map<String, Object?>> groups) {
    for (final group in groups.values) {
      if (group['type']?.toString().toLowerCase() == 'url-test') {
        final value = group['url']?.toString().trim();
        if (value != null && value.startsWith('https://')) return value;
      }
    }
    return 'https://www.gstatic.com/generate_204';
  }

  static bool _isInformationNode(String name) {
    final lower = name.toLowerCase();
    return name.startsWith('잔여 트래픽:') ||
        name.startsWith('만료까지:') ||
        name.contains('剩余流量') ||
        name.contains('距离下次重置') ||
        name.contains('套餐到期') ||
        lower.contains('hello-ssone.com');
  }

  static int? _integer(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    _ => int.tryParse(value?.toString() ?? ''),
  };

  static List<Object?>? _list(Object? value) => switch (value) {
    YamlList list => list.toList(growable: false),
    List<Object?> list => list,
    _ => null,
  };

  static Map<String, Object?>? _stringMap(Object? value) {
    if (value is! Map) return null;
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
}

String encodeRoutingMetadata(Map<String, Object?> value) =>
    base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
