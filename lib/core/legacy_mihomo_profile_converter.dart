import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'vless_reality_profile.dart';

/// Converts app-generated legacy profiles, never arbitrary native Mihomo YAML.
///
/// Returns a new JSON document (also valid YAML). The caller must retain the
/// original stored text, including subscription and inline-rule metadata.
/// [selectedProxies] supplies the separately persisted selector choices.
///
/// Supports plain/TLS/REALITY VLESS over TCP, WS and gRPC without flow; version
/// 3 routing with concrete single-node policies; domain, CIDR, private-network
/// and domain/network/port conjunctions, including expanded rule providers.
/// The legacy DIRECT UDP override is retained when its automatic pool has one
/// node. Original provider group graphs were never stored and are not invented.
///
/// Throws [FormatException] for malformed, modified or ambiguous profiles.
/// In particular, leastPing pools, old/incomplete routing metadata, unsupported
/// display rules, external geodata, XHTTP, flow, unrecognized link options and
/// rule modifiers must be reimported as native configuration instead.
///
/// This is a profile converter, not an Android runtime builder: socket
/// protection, TUN, DNS interception, LAN exclusions and routing mode belong
/// to the hosting runtime. Generated DNS and disabled-TUN settings are retained.
class LegacyMihomoProfileConverter {
  const LegacyMihomoProfileConverter._();

  static const _link = '# proxima-vless-reality-link:';
  static const _routing = VlessRealityProfile.routingMetadataPrefix;
  static const _inline = VlessRealityProfile.inlineRulesPrefix;
  static const _subscription = '# proxima-subscription-url:';
  static const _reserved = {
    'DIRECT',
    'REJECT',
    'REJECT-DROP',
    'PASS',
    'COMPATIBLE',
    'PROXY',
    'GLOBAL',
  };

  static String convert(
    String content, {
    Map<String, String> selectedProxies = const {},
  }) {
    final metadata = <String, List<String>>{};
    for (final line in const LineSplitter().convert(content)) {
      final text = line.trim();
      if (!text.startsWith('# proxima-')) continue;
      final prefix = [
        _link,
        _routing,
        _inline,
        _subscription,
      ].where(text.startsWith).firstOrNull;
      if (prefix == null) _fail('metadata', 'Unknown Proxima metadata.');
      metadata
          .putIfAbsent(prefix, () => [])
          .add(_decode(text.substring(prefix.length).trim(), prefix));
    }
    final links = metadata[_link];
    if (links == null || links.isEmpty) {
      _fail('profile', 'Not a generated legacy profile; use native import.');
    }
    for (final entry in metadata.entries) {
      if (entry.key != _link && entry.value.length != 1) {
        _fail(entry.key, 'Duplicate metadata.');
      }
    }
    final profiles = links.map(VlessRealityProfile.parse).toList();
    final document = _map(loadYaml(content), 'profile');
    final proxies = _list(
      document['proxies'],
      'proxies',
    ).map((value) => _map(value, 'proxies')).toList();
    if (proxies.length != profiles.length) {
      _fail('proxies', 'Link and proxy counts differ.');
    }
    final names = proxies.map((p) => _atom(p['name'], 'proxies.name')).toList();
    if (names.toSet().length != names.length || names.any(_reserved.contains)) {
      _fail(
        'proxies.name',
        'Duplicate or reserved node names; reimport natively.',
      );
    }
    final expected = loadYaml(
      VlessRealityProfile.profilesToMihomoYaml(
        profiles,
        profileName: names.first,
      ),
    );
    if (!_equal(document, expected)) {
      _fail(
        'profile',
        'Generated YAML was modified; use native import to retain it.',
      );
    }
    for (var index = 0; index < profiles.length; index++) {
      proxies[index].addAll(_transport(profiles[index], 'links[$index]'));
      // The old Dart generator invented chrome even when libXray received no fp.
      if (!Uri.parse(links[index]).queryParameters.containsKey('fp')) {
        proxies[index].remove('client-fingerprint');
      }
    }
    final groups = <String, Map<String, Object?>>{
      for (final name in ['PROXY', 'GLOBAL'])
        name: {
          'name': name,
          'type': 'select',
          'proxies': [...names],
        },
    };
    final rules = <String>[];
    if (metadata[_routing] case final List<String> values) {
      final routing = _map(jsonDecode(values.single), 'routing');
      _keys(routing, {
        'version',
        'source',
        'autoTestUrl',
        'rules',
        'displayRules',
      }, 'routing');
      if (routing['version'] != 3 ||
          !const {'clash-meta', 'vless-links'}.contains(routing['source'])) {
        _fail(
          'routing.version',
          'Only complete version 3 metadata can be migrated; reimport natively.',
        );
      }
      final testUrl = routing['autoTestUrl'];
      if (testUrl is! String || Uri.tryParse(testUrl)?.scheme != 'https') {
        _fail('routing.autoTestUrl', 'Invalid automatic probe URL metadata.');
      }
      final displays = _list(routing['displayRules'], 'routing.displayRules');
      final raw = <String>[];
      for (final value in displays) {
        final display = _map(value, 'routing.displayRules');
        _keys(
          display,
          _ruleKeys.union({'raw', 'supported'}),
          'routing.displayRules',
        );
        if (display['supported'] != true || display['raw'] is! String) {
          _fail(
            'routing.displayRules',
            'Contains unsupported or incomplete rules; reimport natively.',
          );
        }
        final text = display['raw'] as String;
        // These flags were discarded by the legacy parser. Neither restoring
        // them nor silently omitting them is a faithful migration.
        final fields = text.split(',').map((part) => part.trim()).toList();
        final expectedLength = fields.first.toUpperCase() == 'MATCH' ? 2 : 3;
        if (!text.toUpperCase().startsWith('AND,') &&
            fields.length != expectedLength) {
          _fail(
            'routing.displayRules',
            'Rule modifiers were not retained in executable metadata.',
          );
        }
        raw.add(text);
      }
      if (metadata[_inline] case final List<String> inline) {
        if (inline.single != raw.join('\n')) {
          _fail('inlineRules', 'Inline rules disagree with routing metadata.');
        }
      }
      final stored = _list(routing['rules'], 'routing.rules');
      if (stored.isEmpty ||
          !stored.any((r) => r is Map && r['match'] == true)) {
        _fail('routing.rules', 'Missing terminal MATCH route.');
      }
      for (var index = 0; index < stored.length; index++) {
        final path = 'routing.rules[$index]';
        final rule = _map(stored[index], path);
        _keys(rule, _ruleKeys, path);
        final target = switch (rule['target']) {
          'direct' => 'DIRECT',
          'block' => 'REJECT',
          'proxy' => _policy(rule, names, groups),
          _ => _fail('$path.target', 'Unknown routing target.'),
        };
        final conditions = _conditions(rule, path);
        if (target == 'DIRECT' && rule['network'] != 'tcp') {
          if (names.length != 1) {
            _fail(
              path,
              'DIRECT UDP uses an unrecoverable leastPing pool; reimport native rules.',
            );
          }
          rules.add(_emit([...conditions, 'NETWORK,UDP'], names.single));
          if (rule['network'] == 'udp') continue;
          rules.add(_emit([...conditions, 'NETWORK,TCP'], target));
        } else {
          rules.add(_emit(conditions, target));
        }
      }
    } else {
      if (metadata.containsKey(_inline)) {
        _fail('inlineRules', 'Executable routing metadata is missing.');
      }
      rules.add('MATCH,PROXY');
    }
    for (final entry in selectedProxies.entries) {
      final group = groups[entry.key];
      if (group == null || !(group['proxies'] as List).contains(entry.value)) {
        _fail('selectedProxies', 'Selection is not a member of its group.');
      }
      group['default-selected'] = entry.value;
    }
    // Xray's manual rule mode falls back to the saved GLOBAL selection.
    if (!selectedProxies.containsKey('PROXY') &&
        selectedProxies.containsKey('GLOBAL')) {
      groups['PROXY']!['default-selected'] = selectedProxies['GLOBAL'];
    }
    return const JsonEncoder.withIndent('  ').convert({
      ...document,
      'proxies': proxies,
      'proxy-groups': groups.values.toList(),
      'rules': rules,
    });
  }

  static Map<String, Object?> _transport(
    VlessRealityProfile profile,
    String path,
  ) {
    final uri = Uri.parse(profile.sourceLink);
    final query = uri.queryParameters;
    final allowed = {
      'encryption',
      'security',
      'type',
      'flow',
      'sni',
      'fp',
      if (profile.security == 'reality') ...['pbk', 'sid'],
      if (profile.security == 'tls') 'alpn',
      if (profile.network == 'ws') ...['path', 'host'],
      if (profile.network == 'grpc') 'serviceName',
    };
    if (query.keys.any((key) => !allowed.contains(key)) ||
        uri.queryParametersAll.values.any((values) => values.length != 1) ||
        uri.path.isNotEmpty) {
      _fail(
        path,
        'Unknown, duplicate or transport-incompatible URI options; reimport natively.',
      );
    }
    if (profile.network == 'xhttp' || profile.flow.isNotEmpty) {
      _fail(
        path,
        'XHTTP/flow migration is unsupported; Vision UDP/443 behavior differs. Reimport natively.',
      );
    }
    if (query['security'] != null && query['security'] != profile.security ||
        query['type'] != null &&
            !const {
              'tcp',
              'raw',
              'ws',
              'websocket',
              'grpc',
            }.contains(query['type'])) {
      _fail(
        path,
        'Noncanonical security or transport spelling cannot be migrated.',
      );
    }
    if (!const {null, '', 'none'}.contains(query['encryption'])) {
      _fail(path, 'VLESS encryption cannot be migrated.');
    }
    if (profile.security == 'reality' &&
        ((query['sni'] ?? '').isEmpty || (query['fp'] ?? '').isEmpty)) {
      _fail(
        path,
        'REALITY requires explicit SNI and fingerprint for migration.',
      );
    }
    if (query.containsKey('fp') &&
        !const {
          '',
          'chrome',
          'firefox',
          'safari',
          'ios',
          'android',
          'edge',
          'random',
          'randomized',
        }.contains(query['fp'])) {
      _fail(path, 'Unsupported TLS fingerprint; reimport natively.');
    }
    if (query.values.any((v) => v != v.trim())) {
      _fail(path, 'Whitespace in URI options has ambiguous legacy semantics.');
    }
    final alpn = query['alpn']?.split(',');
    if (alpn != null && alpn.any((value) => value.isEmpty)) {
      _fail(path, 'Invalid ALPN list.');
    }
    return {
      'alpn': ?alpn,
      if (profile.security == 'tls')
        'servername': query['sni']?.isNotEmpty == true
            ? query['sni']
            : profile.network == 'ws' && profile.host != null
            ? profile.host
            : profile.server,
    };
  }

  static String _policy(
    Map<String, Object?> rule,
    List<String> names,
    Map<String, Map<String, Object?>> groups,
  ) {
    final candidates = rule.containsKey('candidates')
        ? _list(
            rule['candidates'],
            'routing.candidates',
          ).map((v) => _atom(v, 'routing.candidates')).toList()
        : names.length == 1
        ? names
        : <String>[];
    if (candidates.length != 1 || !names.contains(candidates.single)) {
      _fail(
        'routing.candidates',
        'Missing, unknown or multiple candidates: leastPing cannot be reproduced. Reimport native groups.',
      );
    }
    final node = candidates.single;
    final value = rule['policy'];
    if (value == null) return node;
    final policy = _atom(value, 'routing.policy');
    if (policy == 'PROXY' || policy == 'GLOBAL' || policy == node) return node;
    if (_reserved.contains(policy) || names.contains(policy)) {
      _fail('routing.policy', 'Policy collides with a node or built-in name.');
    }
    final group = groups[policy];
    if (group != null && !_equal(group['proxies'], [node])) {
      _fail('routing.policy', 'One policy has conflicting candidate lists.');
    }
    groups[policy] = {
      'name': policy,
      'type': 'select',
      'proxies': [node],
    };
    return policy;
  }

  static const _ruleKeys = {
    'domain',
    'ip',
    'network',
    'port',
    'match',
    'target',
    'policy',
    'candidates',
  };

  static List<String> _conditions(Map<String, Object?> rule, String path) {
    final conditions = <String>[];
    for (final key in ['domain', 'ip']) {
      if (!rule.containsKey(key)) continue;
      final alternatives = <String>[];
      for (final item in _list(rule[key], '$path.$key')) {
        final value = _atom(item, '$path.$key');
        if (key == 'domain') {
          if (value == 'geosite:private') {
            alternatives.addAll([
              'DOMAIN-SUFFIX,lan',
              'DOMAIN-SUFFIX,local',
              'DOMAIN,localhost',
              'DOMAIN-SUFFIX,home.arpa',
            ]);
          } else {
            final separator = value.indexOf(':');
            final kind = separator < 0 ? '' : value.substring(0, separator);
            final payload = separator < 0
                ? value
                : value.substring(separator + 1);
            final type = switch (kind) {
              'full' => 'DOMAIN',
              'domain' => 'DOMAIN-SUFFIX',
              'keyword' || 'plain' || '' => 'DOMAIN-KEYWORD',
              'regexp' => 'DOMAIN-REGEX',
              _ => _fail(
                '$path.domain',
                'External geodata or unknown domain semantics.',
              ),
            };
            alternatives.add('$type,${_atom(payload, path)}');
          }
        } else {
          final networks = value == 'geoip:private' || value == 'geoip:lan'
              ? _privateNetworks
              : [value];
          for (final network in networks) {
            final parts = network.split('/');
            final address = InternetAddress.tryParse(parts.first);
            final prefix = parts.length == 2 ? int.tryParse(parts.last) : null;
            if (address == null ||
                prefix == null ||
                prefix < 0 ||
                prefix >
                    (address.type == InternetAddressType.IPv4 ? 32 : 128)) {
              _fail(
                '$path.ip',
                'Only literal IPv4/IPv6 CIDRs and private ranges are supported.',
              );
            }
            alternatives.add('IP-CIDR,$network');
          }
        }
      }
      if (alternatives.isEmpty) _fail('$path.$key', 'Empty condition list.');
      conditions.add(_combine('OR', alternatives));
    }
    if (rule.containsKey('network')) {
      final network = rule['network'];
      if (!const {'tcp', 'udp', 'tcp,udp'}.contains(network)) {
        _fail('$path.network', 'Unsupported network condition.');
      }
      if (network != 'tcp,udp') {
        conditions.add('NETWORK,${(network as String).toUpperCase()}');
      }
    }
    if (rule.containsKey('port')) {
      final port = rule['port'];
      if (port is! String ||
          !RegExp(r'^\d+([:-]\d+)?(,\d+([:-]\d+)?)*$').hasMatch(port)) {
        _fail('$path.port', 'Invalid destination port list.');
      }
      for (final range in port.split(',')) {
        final values = range.split(RegExp('[:-]')).map(int.parse).toList();
        if (values.any((v) => v < 1 || v > 65535) ||
            values.first > values.last) {
          _fail('$path.port', 'Invalid destination port range.');
        }
      }
      conditions.add(
        'DST-PORT,${port.replaceAll(':', '-').replaceAll(',', '/')}',
      );
    }
    if (rule.containsKey('match') && rule['match'] != true ||
        rule['match'] == true && conditions.isNotEmpty ||
        rule['match'] != true && conditions.isEmpty) {
      _fail(path, 'Missing or conflicting routing conditions.');
    }
    if (rule['target'] != 'proxy' &&
        (rule.containsKey('policy') || rule.containsKey('candidates'))) {
      _fail(path, 'Non-proxy route contains a proxy policy.');
    }
    return conditions;
  }

  static const _privateNetworks = [
    '0.0.0.0/8',
    '10.0.0.0/8',
    '100.64.0.0/10',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '224.0.0.0/4',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
  ];

  static String _emit(List<String> conditions, String target) =>
      '${conditions.isEmpty ? 'MATCH' : _combine('AND', conditions)},$target';

  static String _combine(String operation, List<String> conditions) =>
      conditions.length == 1
      ? conditions.single
      : '$operation,(${conditions.map((c) => '($c)').join(',')})';

  static String _decode(String encoded, String path) {
    try {
      if (encoded.isEmpty) _fail(path, 'Empty metadata.');
      return utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    } on FormatException {
      _fail(path, 'Malformed base64/UTF-8 metadata.');
    }
  }

  static Map<String, Object?> _map(Object? value, String path) {
    if (value is! Map || value.keys.any((k) => k is! String)) {
      _fail(path, 'Expected an object with string keys.');
    }
    return value.cast<String, Object?>().map(
      (key, item) => MapEntry(key, item),
    );
  }

  static List<Object?> _list(Object? value, String path) {
    if (value is! List) _fail(path, 'Expected a list.');
    return value.cast<Object?>();
  }

  static String _atom(Object? value, String path) {
    if (value is! String ||
        value.isEmpty ||
        value != value.trim() ||
        RegExp(r'[,\r\n()]').hasMatch(value)) {
      _fail(path, 'Empty or unrepresentable rule/name token.');
    }
    return value;
  }

  static void _keys(Map<String, Object?> value, Set<String> keys, String path) {
    if (value.keys.any((key) => !keys.contains(key))) {
      _fail(path, 'Unknown metadata fields; reimport natively.');
    }
  }

  static bool _equal(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every(
            (key) => right.containsKey(key) && _equal(left[key], right[key]),
          );
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          Iterable<int>.generate(left.length)
              .every((i) => _equal(left[i], right[i]));
    }
    return left == right;
  }

  static Never _fail(String path, String message) =>
      throw FormatException('$path: $message');
}
