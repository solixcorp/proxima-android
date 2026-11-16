import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/clash_subscription.dart';
import 'package:proxima/core/legacy_mihomo_profile_converter.dart';
import 'package:proxima/core/vless_reality_profile.dart';

const _base =
    'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443';
const _plain = '$_base?security=none&type=tcp#Edge';
const _reality =
    '$_base?security=reality&type=tcp&sni=cover.example&fp=chrome'
    '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef#Reality';

String _stored(String source, {String name = 'Saved'}) =>
    VlessRealityProfile.storedConfigFromInput(source, profileName: name);

Map<String, dynamic> _convert(
  String content, {
  Map<String, String> selected = const {},
}) => jsonDecode(
  LegacyMihomoProfileConverter.convert(content, selectedProxies: selected),
) as Map<String, dynamic>;

String _routing(String content, void Function(Map<String, dynamic>) change) {
  const prefix = VlessRealityProfile.routingMetadataPrefix;
  final lines = content.split('\n');
  final index = lines.indexWhere((line) => line.startsWith(prefix));
  final encoded = lines[index].substring(prefix.length).trim();
  final map = jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
  ) as Map<String, dynamic>;
  change(map);
  lines[index] = '$prefix ${encodeRoutingMetadata(map)}';
  return lines.join('\n');
}

Matcher _error(String field) => throwsA(
  isA<FormatException>().having(
    (error) => error.message,
    'conversion error',
    contains(field),
  ),
);

void main() {
  test('emits real REALITY credentials and TLS options from stored links', () {
    final stored = _stored(_reality, name: 'My VPN');

    final config = _convert(stored);

    expect(config['proxies'], [
      {
        'name': 'My VPN',
        'type': 'vless',
        'server': 'edge.example.com',
        'port': 443,
        'uuid': '123e4567-e89b-42d3-a456-426614174000',
        'udp': true,
        'tls': true,
        'servername': 'cover.example',
        'client-fingerprint': 'chrome',
        'network': 'tcp',
        'reality-opts': {
          'public-key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          'short-id': '0123456789abcdef',
        },
      },
    ]);
    expect(config['rules'], ['MATCH,PROXY']);
  });

  test('restores TLS WebSocket ALPN and legacy Host-derived SNI', () {
    final stored = _stored(
      '$_base?security=tls&type=ws&host=cdn.example&path=%2Fws'
      '&alpn=h2%2Chttp%2F1.1#WebSocket',
    );

    final proxy = (_convert(stored)['proxies'] as List).single;

    expect(proxy['servername'], 'cdn.example');
    expect(proxy['alpn'], ['h2', 'http/1.1']);
    expect(proxy['client-fingerprint'], isNull);
    expect(proxy['ws-opts'], {
      'path': '/ws',
      'headers': {'Host': 'cdn.example'},
    });
  });

  test('keeps gRPC service name and explicit TLS fingerprint', () {
    final stored = _stored(
      '$_base?security=tls&type=grpc&serviceName=Tunnel&sni=grpc.example'
      '&fp=firefox#RPC',
    );

    final proxy = (_convert(stored)['proxies'] as List).single;

    expect(proxy['network'], 'grpc');
    expect(proxy['grpc-opts'], {'grpc-service-name': 'Tunnel'});
    expect(proxy['client-fingerprint'], 'firefox');
    expect(proxy['servername'], 'grpc.example');
  });

  test('retains every manual selector choice and saved selection', () {
    final stored = _stored('$_plain\n${_plain.replaceFirst('#Edge', '#West')}');
    final selections = Map<String, String>.unmodifiable({'GLOBAL': 'West'});

    final config = _convert(stored, selected: selections);

    expect(config['proxy-groups'], [
      {
        'name': 'PROXY',
        'type': 'select',
        'proxies': ['Edge', 'West'],
        'default-selected': 'West',
      },
      {
        'name': 'GLOBAL',
        'type': 'select',
        'proxies': ['Edge', 'West'],
        'default-selected': 'West',
      },
    ]);
  });

  test('does not override an explicit PROXY choice with GLOBAL', () {
    final stored = _stored('$_plain\n${_plain.replaceFirst('#Edge', '#West')}');

    final config = _convert(
      stored,
      selected: {'PROXY': 'Edge', 'GLOBAL': 'West'},
    );

    expect((config['proxy-groups'] as List).first['default-selected'], 'Edge');
    expect((config['proxy-groups'] as List).last['default-selected'], 'West');
  });

  test('preserves concrete regional policies and expanded provider order', () {
    final stored = _stored('''
proxies:
  - {name: East, type: vless, server: east.example, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000}
  - {name: West, type: vless, server: west.example, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000}
proxy-groups:
  - {name: Regional, type: select, proxies: [East, West]}
  - {name: Default, type: select, proxies: [West, East]}
rule-providers:
  sites:
    type: inline
    behavior: domain
    payload: [exact.example, +.suffix.example]
rules:
  - RULE-SET,sites,Regional
  - IP-CIDR6,2001:db8::/32,REJECT
  - MATCH,Default
''');

    final config = _convert(stored);

    expect(config['rules'], [
      'OR,((DOMAIN,exact.example),(DOMAIN-SUFFIX,suffix.example)),Regional',
      'IP-CIDR,2001:db8::/32,REJECT',
      'MATCH,Default',
    ]);
    expect((config['proxy-groups'] as List).skip(2), [
      {
        'name': 'Regional',
        'type': 'select',
        'proxies': ['East'],
      },
      {
        'name': 'Default',
        'type': 'select',
        'proxies': ['West'],
      },
    ]);
  });

  test('retains AND conditions and the legacy DIRECT UDP proxy override', () {
    final stored = _stored('''
$_plain
AND,((DOMAIN-SUFFIX,example.com),(NETWORK,TCP),(DST-PORT,8000-8080)),DIRECT
DOMAIN-KEYWORD,private,DIRECT
MATCH,PROXY
''');

    final config = _convert(stored);

    expect(config['rules'], [
      'AND,((DOMAIN-SUFFIX,example.com),(NETWORK,TCP),(DST-PORT,8000-8080)),DIRECT',
      'AND,((DOMAIN-KEYWORD,private),(NETWORK,UDP)),Saved',
      'AND,((DOMAIN-KEYWORD,private),(NETWORK,TCP)),DIRECT',
      'MATCH,Saved',
    ]);
  });

  test('expands private geodata to the exact legacy local ranges', () {
    final stored = _stored('''
$_plain
GEOSITE,private,REJECT
GEOIP,private,REJECT
MATCH,PROXY
''');

    final config = _convert(stored);

    expect(config['rules'], [
      'OR,((DOMAIN-SUFFIX,lan),(DOMAIN-SUFFIX,local),(DOMAIN,localhost),(DOMAIN-SUFFIX,home.arpa)),REJECT',
      'OR,((IP-CIDR,0.0.0.0/8),(IP-CIDR,10.0.0.0/8),(IP-CIDR,100.64.0.0/10),(IP-CIDR,127.0.0.0/8),'
          '(IP-CIDR,169.254.0.0/16),(IP-CIDR,172.16.0.0/12),(IP-CIDR,192.168.0.0/16),'
          '(IP-CIDR,224.0.0.0/4),(IP-CIDR,::1/128),(IP-CIDR,fc00::/7),(IP-CIDR,fe80::/10)),REJECT',
      'MATCH,Saved',
    ]);
  });

  test('keeps expanded single-label domain regular expressions intact', () {
    final stored = _stored('''
proxies:
  - {name: Edge, type: vless, server: edge.example, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000}
proxy-groups:
  - {name: PROXY, type: select, proxies: [Edge]}
rule-providers:
  sites: {type: inline, behavior: domain, payload: ["*.example.com"]}
rules:
  - RULE-SET,sites,REJECT
  - MATCH,PROXY
''');

    final config = _convert(stored);

    expect(
      (config['rules'] as List).first,
      r'DOMAIN-REGEX,^[^.]+\.example\.com$,REJECT',
    );
  });

  for (final source in [
    'proxies: []\nproxy-groups: []\nrules: [MATCH,DIRECT]',
    '{"proxies":[],"rules":["MATCH,DIRECT"]}',
  ]) {
    test('requires legacy link metadata for native input $source', () {
      expect(() => _convert(source), _error('native import'));
    });
  }

  for (final query in [
    'security=none&type=xhttp&path=/x',
    'security=none&type=tcp&flow=xtls-rprx-vision',
    'security=tls&type=tcp&allowInsecure=1',
    'security=none&type=ws&fm=%7B%7D',
    'security=none&type=grpc&mode=multi',
    'security=none&type=tcp&type=ws',
    'security=none&type=tcp&encryption=new-encryption',
  ]) {
    test('rejects transport options that cannot be migrated: $query', () {
      final stored = _stored('$_base?$query#Edge');

      expect(() => _convert(stored), _error('links[0]'));
    });
  }

  for (final (source, message) in [
    (
      '$_plain\n${_plain.replaceFirst('#Edge', '#West')}\nMATCH,PROXY',
      'leastPing',
    ),
    ('$_plain\nGEOIP,cn,PROXY\nMATCH,PROXY', 'unsupported'),
    ('$_plain\nPROCESS-NAME,example.app,PROXY\nMATCH,PROXY', 'unsupported'),
    ('$_plain\nIP-CIDR,10.0.0.0/8,REJECT,no-resolve\nMATCH,PROXY', 'modifiers'),
  ]) {
    test('rejects routing loss rather than using MATCH: $message', () {
      final stored = _stored(source);

      expect(() => _convert(stored), _error(message));
    });
  }

  for (final (field, change) in <(String, void Function(Map<String, dynamic>))>[
    ('version', (m) => m['version'] = 2),
    ('routing.rules', (m) => m['rules'] = []),
    (
      'routing.rules[0]',
      (m) => (m['rules'] as List).first['sourcePort'] = '80',
    ),
    (
      'routing.candidates',
      (m) => (m['rules'] as List).last['candidates'] = ['Missing'],
    ),
    ('routing.displayRules', (m) => m['displayRules'] = null),
    (
      'routing.rules[0].ip',
      (m) => (m['rules'] as List).first['ip'] = ['192.0.2.1/99'],
    ),
  ]) {
    test('rejects malformed metadata at $field', () {
      final stored = _routing(
        _stored('$_plain\nIP-CIDR,10.0.0.0/8,REJECT\nMATCH,PROXY'),
        change,
      );

      expect(() => _convert(stored), _error(field));
    });
  }

  test('rejects native extensions attached to legacy generated YAML', () {
    final stored = '${_stored(_plain)}\nscript: {code: native-feature}\n';

    expect(() => _convert(stored), _error('modified'));
  });

  test('rejects invalid selections without editing caller-owned state', () {
    final stored = _stored(_plain);
    final selected = Map<String, String>.unmodifiable({'PROXY': 'Missing'});

    expect(
      () => _convert(stored, selected: selected),
      _error('selectedProxies'),
    );
  });

  test('rejects corrupted link metadata rather than dropping a node', () {
    final stored = '# proxima-vless-reality-link: @@@\n${_stored(_plain)}';

    expect(() => _convert(stored), _error('Malformed base64'));
  });

  test('rejects duplicate routing documents instead of choosing one', () {
    final stored = _stored('$_plain\nMATCH,PROXY');
    final routing = stored
        .split('\n')
        .firstWhere(
          (line) => line.startsWith(VlessRealityProfile.routingMetadataPrefix),
        );

    expect(() => _convert('$routing\n$stored'), _error('Duplicate metadata'));
  });
}
