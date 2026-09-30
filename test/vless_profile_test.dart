import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/vless_reality_profile.dart';
import 'package:yaml/yaml.dart';

const _base =
    'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:8080';
// Same transport options and unusual fm parameter as the reported link.
const _ws =
    '$_base?security=none&type=ws&host=cdn.example.com&path=/&fm={#%5BOpenRay%5D%20%F0%9F%87%A8%F0%9F%87%A6%20CA-28717';
const _reality =
    '$_base?security=reality&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Reality';

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
}
