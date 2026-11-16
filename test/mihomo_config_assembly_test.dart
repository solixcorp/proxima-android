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
    expect(result['tun'].containsKey('inet6-address'), isFalse);
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

  test('mixed and Hysteria2-only base64 subscriptions preserve all nodes', () {
    const reality =
        'vless://12345678-1234-1234-1234-123456789abc@edge.example:443?security=reality&sni=cdn.example&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&sid=1a2b#Reality';
    const hy2 =
        'hy2://user%3Apass%40word@hy.example/?sni=hy.example&obfs=salamander&obfs-password=ob%2Bfs#HY2';
    for (final text in ['$reality\n$hy2', hy2]) {
      for (final source in [text, base64Encode(utf8.encode(text))]) {
        final preview = MihomoConfigAssembly.preview(source);
        expect(preview.proxies.length, text == hy2 ? 1 : 2);
        final result = jsonDecode(
          MihomoConfigAssembly.build(
            source: source,
            mode: 'global',
            mtu: 1400,
            ipv6: true,
            selectedNode: 'HY2',
          ),
        ) as Map;
        expect(result['proxy-groups'].last['proxies'].first, 'HY2');
        final hy = (result['proxies'] as List).last;
        expect(hy['type'], 'hysteria2');
        expect(hy['port'], 443);
        expect(hy['password'], 'user:pass@word');
        expect(hy['obfs-password'], 'ob+fs');
        if (text != hy2) {
          expect(result['proxies'].first['reality-opts']['short-id'], '1a2b');
          expect(result['proxies'].first['servername'], 'cdn.example');
          final realitySelected = jsonDecode(
            MihomoConfigAssembly.build(
              source: source,
              mode: 'global',
              mtu: 1400,
              ipv6: true,
              selectedNode: 'Reality',
            ),
          ) as Map;
          expect(realitySelected['proxy-groups'].last['proxies'], [
            'Reality',
            'HY2',
          ]);
        }
      }
    }
  });

  test('YAML Hysteria2 certificate choice survives preview and assembly', () {
    const source = '''
proxies:
  - {name: default, type: hysteria2, server: hy.example, port: 443, password: pw}
  - {name: verified, type: hysteria2, server: hy.example, port: 443, password: pw, skip-cert-verify: false}
  - {name: explicit-insecure, type: hysteria2, server: hy.example, port: 443, password: pw, skip-cert-verify: true}
  - {name: invalid, type: hysteria2, server: hy.example, port: 443, password: pw, skip-cert-verify: 'true'}
  - {name: reality, type: vless, server: reality.example, port: 443, uuid: 12345678-1234-1234-1234-123456789abc, network: tcp, tls: true, reality-opts: {public-key: key}}
''';
    final preview = MihomoConfigAssembly.preview(source);
    expect(preview.proxies.map((p) => p['name']), [
      'default',
      'verified',
      'explicit-insecure',
      'reality',
    ]);
    final result = jsonDecode(
      MihomoConfigAssembly.build(
        source: source,
        mode: 'global',
        mtu: 1400,
        ipv6: false,
      ),
    ) as Map<String, dynamic>;
    final proxies = result['proxies'] as List;
    expect(proxies[0].containsKey('skip-cert-verify'), isFalse);
    expect(proxies[1]['skip-cert-verify'], isFalse);
    expect(proxies[2]['skip-cert-verify'], isTrue);
    expect(proxies[3]['type'], 'vless');
  });
}
