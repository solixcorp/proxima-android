import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/mihomo_config_assembly.dart';

void main() {
  const subscription = '''
proxies:
  - {name: one, type: socks5, server: one.example, port: 1080}
  - {name: two, type: http, server: two.example, port: 8080}
proxy-groups:
  - {name: regional, type: select, proxies: [one, two]}
rules:
  - DOMAIN,example.com,regional
''';

  Map<String, dynamic> build(String mode, {String? selected}) => jsonDecode(
    MihomoConfigAssembly.build(
      source: subscription,
      mode: mode,
      mtu: 1400,
      ipv6: true,
      selectedNode: selected,
    ),
  ) as Map<String, dynamic>;

  test('keeps admitted proxies and groups and prioritizes selection', () {
    final result = build('rule', selected: 'two');
    expect(result['proxies'], hasLength(2));
    expect(result['proxy-groups'][0]['name'], 'regional');
    expect(result['proxy-groups'][1]['proxies'], ['two', 'one']);
    expect(result['rules'], ['DOMAIN,example.com,regional', 'MATCH,PROXY']);
    expect(result['tun']['mtu'], 1400);
    expect(result['tun']['inet6-address'], isEmpty);
    expect(result['ipv6'], true);
  });

  test('missing selection uses first node; modes use explicit match', () {
    expect(build('global', selected: 'gone')['proxy-groups'][1]['proxies'], [
      'one',
      'two',
    ]);
    expect(build('global')['rules'], ['MATCH,PROXY']);
    expect(build('direct')['rules'], ['MATCH,DIRECT']);
  });

  test('subscription rules can target the app-owned PROXY selector', () {
    final result = jsonDecode(
      MihomoConfigAssembly.build(
        source: '$subscription\n  - MATCH,PROXY\n',
        mode: 'rule',
        mtu: 1500,
        ipv6: false,
      ),
    ) as Map<String, dynamic>;
    expect(result['rules'], contains('MATCH,PROXY'));
    expect(
      (result['rules'] as List).where((r) => r == 'MATCH,PROXY'),
      hasLength(2),
    );
  });

  test('preserves providers and rejects unsafe URLs', () {
    const source = '''
proxies: [{name: one, type: socks5, server: one.example, port: 1080}]
proxy-groups: [{name: group, type: select, use: [provider]}]
proxy-providers:
  provider: {type: http, url: 'https://example.com/proxies'}
rule-providers:
  domains: {type: inline, behavior: domain, payload: [example.com]}
rules: ['RULE-SET,domains,group']
''';
    String buildSource(String input) => MihomoConfigAssembly.build(
      source: input,
      mode: 'rule',
      mtu: 1500,
      ipv6: false,
    );
    final config = jsonDecode(buildSource(source)) as Map<String, dynamic>;
    expect(
      config['proxy-providers']['provider']['url'],
      'https://example.com/proxies',
    );
    expect(config['rule-providers']['domains']['behavior'], 'domain');
    expect(config['rules'].first, 'RULE-SET,domains,group');
    for (final url in [
      'http://example.com/proxies',
      'https://user@example.com/proxies',
    ]) {
      expect(
        () => buildSource(
          source.replaceFirst('https://example.com/proxies', url),
        ),
        throwsFormatException,
      );
    }
  });

  test('accepts a direct or legacy stored VLESS link', () {
    const link =
        'vless://12345678-1234-1234-1234-123456789abc@example.com:443?security=tls#node';
    final encoded = base64UrlEncode(utf8.encode(link)).replaceAll('=', '');
    for (final source in [link, '# proxima-vless-reality-link: $encoded\n{}']) {
      final result = jsonDecode(
        MihomoConfigAssembly.build(
          source: source,
          mode: 'global',
          mtu: 1500,
          ipv6: false,
        ),
      ) as Map<String, dynamic>;
      expect(result['proxies'][0]['type'], 'vless');
    }
  });
}
