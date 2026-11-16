import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/clash_subscription.dart';
import 'package:proxima/core/mihomo_proxy_admission.dart';

void main() {
  test('shared native admission behavior cases', () {
    final cases = jsonDecode(
      File('test/fixtures/mihomo_admission_parity.json').readAsStringSync(),
    ) as List<dynamic>;
    for (final row in cases.cast<Map<String, dynamic>>()) {
      final proxy = row['proxy'] as Map<String, dynamic>;
      expect(
        MihomoProxyAdmission.proxyError(proxy) == null,
        row['allowed'],
        reason: '$proxy',
      );
    }
  });
  test('all audited types pass admission with minimal options', () {
    expect(MihomoProxyAdmission.proxyOptions.length, 17);
    for (final type in MihomoProxyAdmission.proxyOptions.keys) {
      final proxy = <String, Object?>{'name': type, 'type': type};
      if (type == 'ssh') proxy['host-key'] = ['pinned'];
      expect(MihomoProxyAdmission.proxyError(proxy), isNull, reason: type);
      proxy['skip-cert-verify'] = true;
      expect(MihomoProxyAdmission.proxyError(proxy), isNotNull, reason: type);
    }
  });
  test('dangerous audited option branches are rejected', () {
    for (final proxy in <Map<String, Object?>>[
      {'type': 'hysteria', 'protocol': 'faketcp'},
      {'type': 'ss', 'plugin': 'v2ray-plugin'},
      {'type': 'snell', 'version': 2},
      {'type': 'ssh'},
      {
        'type': 'ssh',
        'host-key': ['pin'],
        'private-key': '/key',
      },
      {
        'type': 'wireguard',
        'ip-stack': {'mode': 'system'},
      },
      {'type': 'vless', 'network': 'ws', 'reality-opts': {}},
      {'type': 'trojan', 'network': 'h2'},
      {
        'type': 'vmess',
        'ws-opts': {'unknown': true},
      },
      {'type': 'unknown'},
    ]) {
      expect(
        MihomoProxyAdmission.proxyError(proxy),
        isNotNull,
        reason: '$proxy',
      );
    }
  });
  test(
    'preview skips unknown nodes and geodata, cleans references, keeps MRS',
    () {
      final result = ClashSubscriptionParser.admit('''
proxies:
  - {name: a, type: ss, server: example.com, port: 443}
  - {name: bad, type: sudoku, server: example.com, port: 443}
proxy-groups:
  - {name: g, type: select, proxies: [bad, a]}
rule-providers:
  domains: {type: http, format: mrs, behavior: domain, url: 'https://example.com/a'}
rules:
  - GEOIP,CN,DIRECT
  - RULE-SET,domains,g
  - MATCH,g
''')!;
      expect(result.proxies.single['type'], 'ss');
      expect(result.groups.single['proxies'], ['a']);
      expect(result.rules, ['RULE-SET,domains,g', 'MATCH,g']);
      expect(result.skipped.length, 3);
    },
  );
}
