import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/clash_subscription.dart';
import 'package:proxima/core/vless_reality_profile.dart';
import 'package:yaml/yaml.dart';

const _base =
    'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:8080';
// Same transport options and unusual fm parameter as the reported link.
const _ws =
    '$_base?security=none&type=ws&host=cdn.example.com&path=/&fm={#%5BOpenRay%5D%20%F0%9F%87%A8%F0%9F%87%A6%20CA-28717';
const _reality =
    '$_base?security=reality&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Reality';

Map<String, dynamic> _routingMetadata(String config) {
  final line = config.split('\n').firstWhere(
    (line) => line.startsWith(VlessRealityProfile.routingMetadataPrefix),
  );
  final encoded = line
      .substring(VlessRealityProfile.routingMetadataPrefix.length)
      .trim();
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))))
      as Map<String, dynamic>;
}

void main() {
  test('imports and exports plain WebSocket links with original options', () {
    final profile = VlessRealityProfile.parse(_ws);
    expect(profile.security, 'none');
    expect(profile.network, 'ws');
    expect(profile.name, '[OpenRay] 🇨🇦 CA-28717');
    final config = VlessRealityProfile.storedConfigFromInput(
      _ws,
      profileName: 'OpenRay',
    );
    final node = (loadYaml(config)['proxies'] as YamlList).single;
    expect(node['tls'], false);
    expect(node['reality-opts'], isNull);
    expect(node['servername'], isNull);
    expect(node['ws-opts']['path'], '/');
    expect(node['ws-opts']['headers']['Host'], 'cdn.example.com');
    final restored = Uri.parse(
      VlessRealityProfile.linkFromStoredConfig(config)!,
    );
    expect(restored, Uri.parse(_ws));
    expect(restored.queryParameters['fm'], '{');
  });

  test('defaults missing or empty security to none', () {
    for (final query in [
      'type=tcp',
      'type=ws&security=',
      'type=grpc',
      'type=xhttp',
    ]) {
      final profile = VlessRealityProfile.parse('$_base?$query');
      expect(profile.security, 'none');
      expect(
        profile.toMihomoYaml(profileName: 'Plain'),
        contains('tls: false'),
      );
    }
  });

  test('preserves TLS and encoded WebSocket settings through storage', () {
    const link =
        '$_base?security=tls&type=ws&sni=tls.example.com&host=cdn.example.com&path=%2Fsocket%3Fed%3D2048&alpn=http%2F1.1#TLS';
    final profile = VlessRealityProfile.parse(link);
    final config = profile.toMihomoYaml(profileName: 'TLS');
    expect(profile.security, 'tls');
    final node = (loadYaml(config)['proxies'] as YamlList).single;
    expect(node['tls'], true);
    expect(node['servername'], 'tls.example.com');
    expect(node['ws-opts']['path'], '/socket?ed=2048');
    expect(node['reality-opts'], isNull);
    expect(VlessRealityProfile.linkFromStoredConfig(config), link);
  });

  test('imports mixed security subscriptions including Base64', () {
    const input = '$_ws\n$_base?security=tls&type=ws#TLS\n$_reality';
    final encoded = base64Encode(utf8.encode(input));
    final config = VlessRealityProfile.storedConfigFromInput(
      encoded,
      profileName: 'Mixed',
    );
    final profiles = VlessRealityProfile.linksFromStoredConfig(config)
        .map(VlessRealityProfile.parse);
    expect(profiles.map((profile) => profile.security), [
      'none',
      'tls',
      'reality',
    ]);
    expect(
      VlessRealityProfile.nodeNamesFromStoredConfig(
        config,
        profileName: 'Mixed',
      ),
      ['[OpenRay] 🇨🇦 CA-28717', 'TLS', 'Reality'],
    );
  });

  test('keeps REALITY validation and rejects unsupported security', () {
    for (final query in [
      'security=reality',
      'security=reality&pbk=bad',
      'security=unknown',
      'security=reality&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&sid=xyz',
    ]) {
      expect(
        () => VlessRealityProfile.parse('$_base?$query'),
        throwsFormatException,
      );
    }
    expect(
      () => VlessRealityProfile.parse('$_base?security=none&type=invalid'),
      throwsFormatException,
    );
  });

  test('imports plain and TLS WebSocket nodes from Clash subscriptions', () {
    for (final tls in [false, true]) {
      final config = VlessRealityProfile.storedConfigFromInput('''
proxies:
  - name: WebSocket
    type: vless
    server: edge.example.com
    port: 8080
    uuid: 123e4567-e89b-42d3-a456-426614174000
    tls: $tls
    servername: tls.example.com
    network: ws
    ws-opts:
      path: /socket?ed=2048
      headers:
        Host: cdn.example.com
proxy-groups:
  - name: PROXY
    type: select
    proxies: [WebSocket]
rules:
  - MATCH,PROXY
''', profileName: 'Clash');
      final link = VlessRealityProfile.linkFromStoredConfig(config)!;
      final profile = VlessRealityProfile.parse(link);
      expect(profile.security, tls ? 'tls' : 'none');
      expect(profile.host, 'cdn.example.com');
      expect(profile.path, '/socket?ed=2048');
      expect(profile.serverName, 'tls.example.com');
      expect(VlessRealityProfile.hasCurrentRoutingMetadata(config), true);
    }
  });

  test('labels geo rules according to native local support without loss', () {
    const sourceRules = [
      'GEOSITE,cn,DIRECT',
      'GEOSITE,private,DIRECT',
      'GEOIP,cn,DIRECT',
      'GEOIP,private,DIRECT',
      'GEOIP,lan,DIRECT',
      'MATCH,PROXY',
    ];
    final inputs = [
      '$_base\n${sourceRules.join('\n')}',
      '''
proxies:
  - name: Edge
    type: vless
    server: edge.example.com
    port: 8080
    uuid: 123e4567-e89b-42d3-a456-426614174000
proxy-groups:
  - name: PROXY
    type: select
    proxies: [Edge]
rules:
${sourceRules.map((rule) => '  - $rule').join('\n')}
''',
    ];
    for (final input in inputs) {
      final config = VlessRealityProfile.storedConfigFromInput(
        input,
        profileName: 'Geo',
      );
      final displayed = VlessRealityProfile.routingRulesFromStoredConfig(config);
      expect(displayed.map((rule) => rule.supported), [
        false, true, false, true, true, true,
      ]);
      final metadata = _routingMetadata(config);
      expect(
        (metadata['displayRules'] as List).map((rule) => rule['raw']),
        sourceRules,
      );
      final rules = metadata['rules'] as List;
      expect(rules, hasLength(sourceRules.length));
      expect(rules[0]['domain'], ['geosite:cn']);
      expect(rules[1]['domain'], ['geosite:private']);
      expect(rules[2]['ip'], ['geoip:cn']);
      expect(rules[3]['ip'], ['geoip:private']);
      expect(rules[4]['ip'], ['geoip:lan']);
    }
  });

  test('checks geo capabilities for previously saved rule metadata', () {
    const rules = [
      {'domain': ['geosite:cn'], 'target': 'direct', 'supported': true},
      {'domain': ['geosite:private'], 'target': 'direct', 'supported': true},
      {'ip': ['geoip:cn'], 'target': 'direct', 'supported': true},
      {'ip': ['geoip:lan'], 'target': 'direct', 'supported': true},
    ];
    for (final key in ['rules', 'displayRules']) {
      final encoded = encodeRoutingMetadata({
        'version': 2,
        'source': 'clash-meta',
        key: rules,
      });
      final config =
          '${VlessRealityProfile.routingMetadataPrefix} $encoded\n'
          '${VlessRealityProfile.storedConfigFromInput(_base, profileName: 'Old')}';
      expect(
        VlessRealityProfile.routingRulesFromStoredConfig(config)
            .map((rule) => rule.supported),
        [false, true, false, true],
      );
    }
  });

  test('preserves ordered unsupported inline rules through storage round trips',
      () {
    const sourceRules = [
      'PROCESS-NAME,game.exe,PROXY',
      'DOMAIN-SUFFIX,example.com,DIRECT',
      'RULE-SET,private_domain,DIRECT',
      'IP-CIDR,192.0.2.0/24,PROXY,no-resolve',
      'PROCESS-NAME,other.exe,UnknownPolicy',
      'MATCH,PROXY',
    ];
    final config = VlessRealityProfile.storedConfigFromInput(
      '# ignored comment\n$_base\n${sourceRules.join('\n')}',
      profileName: 'Inline',
    );
    final restoredSource = VlessRealityProfile.inlineRulesFromStoredConfig(
      config,
    );
    expect(restoredSource, sourceRules.join('\n'));
    final restored = VlessRealityProfile.storedConfigFromInput(
      '${VlessRealityProfile.linkFromStoredConfig(config)}\n$restoredSource',
      profileName: 'Inline',
    );
    expect(_routingMetadata(restored), _routingMetadata(config));
    final metadata = _routingMetadata(restored);
    final displayRules = metadata['displayRules'] as List;
    expect(displayRules.map((rule) => rule['raw']), sourceRules);
    expect(
      VlessRealityProfile.routingRulesFromStoredConfig(restored)
          .map((rule) => rule.supported),
      [false, true, false, true, false, true],
    );
    final rules = metadata['rules'] as List;
    expect(rules, hasLength(3));
    expect(rules[0]['domain'], ['domain:example.com']);
    expect(rules[0]['target'], 'direct');
    expect(rules[1]['ip'], ['192.0.2.0/24']);
    expect(rules[1]['target'], 'proxy');
    expect(rules[2]['match'], true);
  });

  test('keeps fallback routing for unsupported-only inline rules', () {
    const rule = 'RULE-SET,private_domain,DIRECT';
    final config = VlessRealityProfile.storedConfigFromInput(
      '$_base\n$rule',
      profileName: 'Inline',
    );
    final metadata = _routingMetadata(config);
    expect(metadata['displayRules'], [
      {'raw': rule, 'supported': false},
    ]);
    final rules = metadata['rules'] as List;
    expect(rules.single['match'], true);
    expect(rules.single['target'], 'proxy');
    expect(VlessRealityProfile.inlineRulesFromStoredConfig(config), rule);
  });

  test('still rejects invalid targets on supported inline rules', () {
    for (final rule in [
      'DOMAIN,example.com,Missing',
      'GEOIP,cn,Missing',
      'MATCH,Missing',
      'AND,((DOMAIN-SUFFIX,example.com),(NETWORK,TCP),(DST-PORT,443)),Missing',
    ]) {
      expect(
        () => VlessRealityProfile.storedConfigFromInput(
          '$_base\n$rule',
          profileName: 'Inline',
        ),
        throwsFormatException,
      );
    }
  });
}
