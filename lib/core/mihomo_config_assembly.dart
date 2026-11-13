import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'clash_subscription.dart';
import 'mihomo_proxy_admission.dart';
import 'share_link_parsers.dart';
import 'vless_reality_profile.dart';

/// The only executable Mihomo configuration producer. Source stays immutable.
class MihomoConfigAssembly {
  const MihomoConfigAssembly._();

  static ClashAdmissionResult preview(String source, {String? profileName}) {
    final legacy = VlessRealityProfile.linksFromStoredConfig(source);
    if (legacy.isEmpty) {
      final clash = ClashSubscriptionParser.admit(source);
      if (clash != null) return clash;
    }
    var links = legacy.isEmpty ? source : legacy.join('\n');
    if (!links.contains('://')) {
      try {
        links = VlessRealityProfile.linksFromSubscription(source).join('\n');
      } on FormatException {
        // Other share-link formats are handled by the generic parser below.
      }
    }
    final parsed = ShareLinkParsers.parseMany(links);
    final skipped = parsed.errors
        .map((e) => ClashSkippedItem('link', '', e.message))
        .toList();
    final proxies = <Map<String, Object?>>[];
    for (final proxy in parsed.proxies) {
      final error = MihomoProxyAdmission.proxyError(proxy);
      if (error != null) {
        skipped.add(ClashSkippedItem(proxy['type'] as String, '', error));
      } else {
        proxies.add(proxy);
      }
    }
    if (legacy.isNotEmpty &&
        profileName != null &&
        proxies.length == legacy.length) {
      final names = VlessRealityProfile.nodeNamesFromStoredConfig(
        source,
        profileName: profileName,
      );
      for (var i = 0; i < names.length; i++) {
        proxies[i]['name'] = names[i];
      }
    }
    return ClashAdmissionResult(proxies, [], [], skipped);
  }

  static String build({
    required String source,
    required String mode,
    required int mtu,
    required bool ipv6,
    String? selectedNode,
    String? profileName,
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
    final preview = MihomoConfigAssembly.preview(
      source,
      profileName: profileName,
    );
    final proxies = preview.proxies;
    if (proxies.isEmpty) {
      throw const FormatException('사용 가능한 프록시가 없습니다.');
    }
    final groups = preview.groups;
    final providers = <String, Object?>{};
    if (legacyLinks.isEmpty && ClashSubscriptionParser.admit(source) != null) {
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
    final sourceRules = mode != 'rule'
        ? <String>[]
        : legacyLinks.isNotEmpty
        ? _legacyRules(source, names, groups)
        : preview.rules.isNotEmpty
        ? preview.rules
        : source
              .split(RegExp(r'\r?\n'))
              .map((line) => line.trim())
              .where((line) => RegExp(r'^[A-Z][A-Z0-9-]*,').hasMatch(line))
              .toList();
    final rules = switch (mode) {
      'global' => <String>['MATCH,PROXY'],
      'direct' => <String>['MATCH,DIRECT'],
      _ => <String>[...sourceRules, 'MATCH,PROXY'],
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
    final config = <String, Object?>{
      'mode': 'rule',
      'ipv6': ipv6,
      'log-level': 'warning',
      'find-process-mode': 'off',
      'profile': {'store-selected': false, 'store-fake-ip': false},
      ...providers,
      'tun': {'enable': true, 'stack': 'mips', 'mtu': mtu},
      'proxies': _plain(proxies),
      'proxy-groups': [
        ...groups.map(_plain),
        {'name': 'PROXY', 'type': 'select', 'proxies': choices},
      ],
      'rules': rules,
    };
    final error = MihomoProxyAdmission.configurationError(config);
    if (error != null) throw FormatException('Mihomo 최종 설정 검증 실패: $error');
    final yaml = jsonEncode(config);
    if (utf8.encode(yaml).length > 8 * 1024 * 1024) {
      throw const FormatException('Mihomo 실행 설정은 8MB 이하여야 합니다.');
    }
    return yaml;
  }

  /// Old generated YAML only contained MATCH. Reuse the saved routing parser,
  /// including expanded rule-provider rows, without changing a byte on disk.
  static List<String> _legacyRules(
    String source,
    List<String> names,
    List<Map<String, Object?>> groups,
  ) {
    final metadata = VlessRealityProfile.routingMetadataFromStoredConfig(
      source,
    );
    if (metadata == null) {
      if (source.contains(VlessRealityProfile.routingMetadataPrefix)) {
        throw const FormatException('레거시 라우팅 메타데이터를 읽을 수 없습니다. 구독을 갱신해 주세요.');
      }
      return VlessRealityProfile.inlineRulesFromStoredConfig(source)
              ?.split('\n') ??
          [];
    }
    if (metadata['rules'] is! List) {
      throw const FormatException('레거시 라우팅 규칙이 올바르지 않습니다. 구독을 갱신해 주세요.');
    }
    final rules = <String>[];
    for (final row
        in (metadata['rules'] as List? ?? const []).whereType<Map>()) {
      String target;
      if (row['target'] == 'direct') {
        target = 'DIRECT';
      } else if (row['target'] == 'block') {
        target = 'REJECT';
      } else {
        final candidates = (row['candidates'] as List? ?? const [])
            .whereType<String>()
            .toList();
        if (candidates.any((name) => !names.contains(name))) {
          throw const FormatException('레거시 규칙의 노드 참조가 유효하지 않습니다. 구독을 갱신해 주세요.');
        }
        target = candidates.isEmpty ? 'PROXY' : candidates.first;
        if (candidates.length > 1) {
          target = '__legacy_policy_${groups.length}';
          while (names.contains(target) ||
              groups.any((g) => g['name'] == target)) {
            target = '${target}_';
          }
          groups.add({'name': target, 'type': 'select', 'proxies': candidates});
        }
      }
      if (row.containsKey('network') || row.containsKey('port')) {
        throw const FormatException(
          '레거시 복합 규칙은 Mihomo에서 허용되지 않습니다. 구독을 갱신해 주세요.',
        );
      }
      if (row['match'] == true) rules.add('MATCH,$target');
      for (final domain
          in (row['domain'] as List? ?? const []).whereType<String>()) {
        final split = domain.indexOf(':');
        final kind = switch (split < 0 ? '' : domain.substring(0, split)) {
          'full' => 'DOMAIN',
          'domain' => 'DOMAIN-SUFFIX',
          'keyword' => 'DOMAIN-KEYWORD',
          'regexp' => 'DOMAIN-REGEX',
          _ => null,
        };
        if (kind == null) {
          throw const FormatException(
            '레거시 도메인 규칙은 Mihomo에서 허용되지 않습니다. 구독을 갱신해 주세요.',
          );
        }
        rules.add('$kind,${domain.substring(split + 1)},$target');
      }
      for (final ip in (row['ip'] as List? ?? const []).whereType<String>()) {
        if (ip.startsWith('geoip:')) {
          throw const FormatException(
            '레거시 GEOIP 규칙은 Mihomo에서 허용되지 않습니다. 구독을 갱신해 주세요.',
          );
        }
        rules.add('${ip.contains(':') ? 'IP-CIDR6' : 'IP-CIDR'},$ip,$target');
      }
    }
    return rules;
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
