import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'clash_subscription.dart';
import 'mihomo_proxy_admission.dart';
import 'share_link_parsers.dart';
import 'vless_reality_profile.dart';

/// A preliminary, offline projection. This is not yet wired to VPN startup.
class MihomoConfigAssembly {
  const MihomoConfigAssembly._();

  static String build({
    required String source,
    required String mode,
    required int mtu,
    required bool ipv6,
    String? selectedNode,
  }) {
    if (!const {'global', 'direct', 'rule'}.contains(mode)) {
      throw const FormatException('지원하지 않는 연결 모드입니다.');
    }
    if (!const {1280, 1400, 1500, 9000}.contains(mtu)) {
      throw const FormatException('지원하지 않는 MTU입니다.');
    }
    if (utf8.encode(source).length > 8 * 1024 * 1024) {
      throw const FormatException('프로필은 8MB보다 작아야 합니다.');
    }
    final legacyLinks = VlessRealityProfile.linksFromStoredConfig(source);
    final preview = legacyLinks.isEmpty
        ? ClashSubscriptionParser.admit(source)
        : null;
    final proxies =
        preview?.proxies ??
        ShareLinkParsers.parseMany(
          legacyLinks.isEmpty ? source : legacyLinks.join('\n'),
        ).proxies;
    if (proxies.isEmpty) {
      throw const FormatException('사용 가능한 프록시가 없습니다.');
    }
    final groups = preview?.groups ?? <Map<String, Object?>>[];
    final providers = <String, Object?>{};
    if (preview != null) {
      final document = loadYaml(source);
      if (document is Map) {
        for (final section in ['proxy-providers', 'rule-providers']) {
          final value = document[section];
          if (value == null) continue;
          if (value is! Map) throw FormatException('$section 형식이 올바르지 않습니다.');
          for (final entry in value.entries) {
            if (entry.key is! String || entry.value is! Map) {
              throw FormatException('$section 항목이 올바르지 않습니다.');
            }
            final provider = entry.value as Map;
            void checkUrl(Object? raw) {
              final uri = raw is String ? Uri.tryParse(raw) : null;
              if (uri == null ||
                  uri.scheme != 'https' ||
                  uri.host.isEmpty ||
                  uri.userInfo.isNotEmpty) {
                throw FormatException('$section 주소는 사용자 정보가 없는 HTTPS여야 합니다.');
              }
            }

            if (provider['type'] == 'http' || provider.containsKey('url')) {
              checkUrl(provider['url']);
            }
            final health = provider['health-check'];
            if (health is Map && health.containsKey('url')) {
              checkUrl(health['url']);
            }
          }
          providers[section] = _plain(value);
        }
      }
    }
    final names = proxies.map((proxy) => proxy['name'] as String).toList();
    if (names.contains('PROXY') || groups.any((g) => g['name'] == 'PROXY')) {
      throw const FormatException('PROXY 이름은 앱 선택기에 예약되어 있습니다.');
    }
    for (final proxy in proxies) {
      final error = MihomoProxyAdmission.proxyError(proxy);
      if (error != null) throw FormatException('프록시 검증 실패: $error');
    }
    for (final group in groups) {
      final error = MihomoProxyAdmission.groupError(group);
      if (error != null) throw FormatException('그룹 검증 실패: $error');
    }
    final choices = [
      if (selectedNode != null && names.contains(selectedNode)) selectedNode,
      ...names.where((name) => name != selectedNode),
    ];
    final rules = switch (mode) {
      'global' => <String>['MATCH,PROXY'],
      'direct' => <String>['MATCH,DIRECT'],
      _ => <String>[...?preview?.rules, 'MATCH,PROXY'],
    };
    for (final rule in rules) {
      if (!MihomoProxyAdmission.ruleTypes.contains(
        rule.split(',').first.trim().toUpperCase(),
      )) {
        throw const FormatException('규칙 검증 실패');
      }
    }
    // JSON is a YAML subset. Android owns the TUN addresses; native admission
    // rejects inet4-address and nonempty inet6-address in engine configuration.
    return jsonEncode({
      'mode': 'rule',
      'ipv6': ipv6,
      'log-level': 'warning',
      'find-process-mode': 'off',
      'profile': {'store-selected': false, 'store-fake-ip': false},
      ...providers,
      'tun': {
        'enable': true,
        'stack': 'mips',
        'mtu': mtu,
        'auto-route': false,
        'auto-detect-interface': false,
        'dns-hijack': ['172.19.0.2:53'],
        'inet6-address': <String>[],
      },
      'proxies': _plain(proxies),
      'proxy-groups': [
        ...groups.map(_plain),
        {'name': 'PROXY', 'type': 'select', 'proxies': choices},
      ],
      'rules': rules,
    });
  }

  static Object? _plain(Object? value) {
    if (value is Map) {
      return value.map((key, item) {
        if (key is! String) throw const FormatException('YAML 키는 문자열이어야 합니다.');
        return MapEntry(key, _plain(item));
      });
    }
    if (value is List) return value.map(_plain).toList();
    return value;
  }
}
