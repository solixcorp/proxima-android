/// Mirror of native/mihomo-engine/protocol_admission.go, audited against
/// Mihomo v1.19.33 (see native/mihomo-engine/DIALERS.md). Go is authoritative.
///
/// Mapping: protocolKeys -> proxyOptions; transportKeys -> nestedOptions;
/// admitProxy/admitSimpleObfs -> proxyError; admitRouting -> groupError and
/// ruleTypes. This is admission only, not upstream constructor validation.
class MihomoProxyAdmission {
  const MihomoProxyAdmission._();

  static const proxyOptions = <String, String>{
    'direct': '',
    'reject': '',
    'http': 'server port username password tls sni headers',
    'socks5': 'server port username password tls udp',
    'ss': 'server port password cipher udp udp-over-tcp udp-over-tcp-version plugin plugin-opts client-fingerprint',
    'ssr': 'server port password cipher obfs obfs-param protocol protocol-param udp',
    'vmess': 'server port uuid alterId cipher udp network tls alpn servername client-fingerprint ws-opts http-opts h2-opts grpc-opts packet-addr xudp packet-encoding global-padding authenticated-length reality-opts',
    'vless': 'server port uuid flow udp network tls alpn servername client-fingerprint ws-opts http-opts h2-opts grpc-opts packet-addr xudp packet-encoding reality-opts',
    'trojan': 'server port password udp network alpn sni client-fingerprint ws-opts grpc-opts reality-opts',
    'snell': 'server port psk udp version obfs-opts',
    'hysteria': 'server port up down up-speed down-speed auth auth-str obfs sni alpn protocol recv-window-conn recv-window disable-mtu-discovery fast-open',
    'hysteria2': 'server port password up down obfs obfs-password obfs-min-packet-size obfs-max-packet-size sni alpn cwnd bbr-profile udp-mtu handshake-timeout initial-stream-receive-window max-stream-receive-window initial-connection-receive-window max-connection-receive-window',
    'tuic': 'server port token uuid password ip heartbeat-interval alpn reduce-rtt request-timeout udp-relay-mode congestion-controller max-udp-relay-packet-size fast-open max-open-streams cwnd bbr-profile recv-window-conn recv-window disable-mtu-discovery max-datagram-frame-size sni udp-over-stream udp-over-stream-version',
    'wireguard': 'server port ip ipv6 private-key public-key pre-shared-key reserved mtu udp workers persistent-keepalive ip-stack',
    'ssh': 'server port username password private-key private-key-passphrase host-key host-key-algorithms',
    'anytls': 'server port password alpn sni client-fingerprint udp client-metadata idle-session-check-interval idle-session-timeout min-idle-session disable-reuse',
    'mieru': 'server port port-range transport udp username password multiplexing handshake-mode traffic-pattern',
  };
  static const nestedOptions = <String, String>{
    'ws-opts': 'path headers max-early-data early-data-header-name v2ray-http-upgrade v2ray-http-upgrade-fast-open',
    'http-opts': 'method path headers',
    'h2-opts': 'host path',
    'grpc-opts': 'grpc-service-name grpc-user-agent ping-interval max-connections min-streams max-streams',
    'reality-opts': 'public-key short-id support-x25519mlkem768',
    'ip-stack': 'mode congestion-controller',
  };
  static const groupTypes = {'select', 'url-test', 'fallback', 'load-balance'};
  static const ruleTypes = {
    'DOMAIN',
    'DOMAIN-SUFFIX',
    'DOMAIN-KEYWORD',
    'DOMAIN-REGEX',
    'DOMAIN-WILDCARD',
    'MATCH',
    'IP-CIDR',
    'IP-CIDR6',
    'SRC-IP-CIDR',
    'DST-PORT',
    'SRC-PORT',
    'NETWORK',
    'RULE-SET',
  };
  static const rejectedTypes = {
    'sudoku',
    'trusttunnel',
    'masque',
    'openvpn',
    'tailscale',
    'zerotier',
    'easytier',
    'shadowquic',
    'gost-relay',
  };
  static const reservedNames = {
    'DIRECT',
    'REJECT',
    'REJECT-DROP',
    'COMPATIBLE',
    'PASS',
    'PASS-RULE',
  };

  static String? _unknown(Map mapping, String allowed) {
    final keys = allowed.split(' ').toSet();
    for (final key in mapping.keys) {
      if (key is! String || !keys.contains(key)) return '허용되지 않은 옵션: $key';
    }
    return null;
  }

  /// Null means admitted by this mirror; upstream may reject invalid values.
  static String? proxyError(Map<String, Object?> proxy) {
    final kind = proxy['type'];
    final allowed = proxyOptions[kind];
    if (allowed == null) return '지원하지 않거나 안전성 검증이 완료되지 않은 프록시 유형: $kind';
    final unknown = _unknown(proxy, 'name type ip-version tfo $allowed');
    if (unknown != null) return unknown;
    for (final entry in nestedOptions.entries) {
      if (!proxy.containsKey(entry.key)) continue;
      final value = proxy[entry.key];
      if (value is! Map) return '${entry.key} 옵션은 매핑이어야 합니다.';
      final error = _unknown(value, entry.value);
      if (error != null) return '${entry.key}: $error';
      if (entry.key == 'ip-stack' && value['mode'] != 'mips') {
        return 'wireguard ip-stack.mode는 mips여야 합니다.';
      }
    }
    if (proxy.containsKey('network')) {
      final network = proxy['network'];
      if (!const {'tcp', 'ws', 'http', 'h2', 'grpc'}.contains(network) ||
          (kind == 'trojan' && (network == 'http' || network == 'h2'))) {
        return '검증되지 않은 전송 방식: $network';
      }
    }
    if (proxy.containsKey('reality-opts') && proxy['network'] == 'ws') {
      return 'REALITY와 WebSocket은 함께 사용할 수 없습니다.';
    }
    if (kind == 'ss' &&
        proxy.containsKey('plugin') &&
        proxy['plugin'] != 'obfs') {
      return 'ss는 obfs 플러그인만 허용합니다.';
    }
    if (kind == 'snell' &&
        proxy.containsKey('version') &&
        !const {1, 3, 4, 5}.contains(proxy['version'])) {
      return 'snell 버전 또는 재사용 풀이 허용되지 않습니다.';
    }
    if (kind == 'ss' || kind == 'snell') {
      final key = kind == 'ss' ? 'plugin-opts' : 'obfs-opts';
      if (proxy.containsKey(key)) {
        final value = proxy[key];
        if (value is! Map) return '$key 옵션은 매핑이어야 합니다.';
        final error = _unknown(value, 'mode host');
        if (error != null) return '$key: $error';
        if (value.containsKey('mode') &&
            !const {'http', 'tls', ''}.contains(value['mode'])) {
          return '$key는 http/tls만 허용합니다.';
        }
      }
    }
    if (kind == 'hysteria' &&
        proxy.containsKey('protocol') &&
        !const {'udp', 'wechat-video'}.contains(proxy['protocol'])) {
      return 'hysteria fakeTCP 등 검증되지 않은 프로토콜은 허용되지 않습니다.';
    }
    if (kind == 'ssh') {
      final hosts = proxy['host-key'];
      if (hosts is! List || hosts.isEmpty) return 'ssh 호스트 키 고정이 필요합니다.';
      if (proxy.containsKey('private-key') &&
          (proxy['private-key'] is! String ||
              !(proxy['private-key'] as String).contains('PRIVATE KEY'))) {
        return 'ssh 개인 키는 인라인 PEM이어야 합니다.';
      }
    }
    return null;
  }

  static String? groupError(Map<String, Object?> group) {
    final kind = group['type'];
    if (!groupTypes.contains(kind)) return '지원하지 않는 그룹 유형: $kind';
    final extra = kind == 'url-test'
        ? 'tolerance'
        : kind == 'load-balance'
        ? 'strategy'
        : '';
    final unknown = _unknown(
      group,
      'name type proxies use url interval timeout lazy disable-udp expected-status max-failed-times $extra',
    );
    if (unknown != null) return unknown;
    if (group.containsKey('url')) {
      final value = group['url'];
      final uri = value is String ? Uri.tryParse(value) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        return '그룹 검사 주소는 HTTPS여야 합니다.';
      }
    }
    for (final key in [
      'interval',
      'timeout',
      'max-failed-times',
      'tolerance',
    ]) {
      if (!group.containsKey(key)) continue;
      final value = group[key];
      if (value is! int || value < 0 || value > 31536000) {
        return '잘못된 그룹 옵션: $key';
      }
    }
    if (kind == 'select' &&
        group.containsKey('interval') &&
        group['interval'] != 0) {
      return 'select 그룹의 interval은 0이어야 합니다.';
    }
    return null;
  }

  /// Recheck the executable document, not a sanitizing import preview. Go's
  /// constructors remain authoritative for values and upstream semantics.
  static String? configurationError(Map<String, Object?> config) {
    final tun = config['tun'];
    if (tun is! Map ||
        tun['stack'] != 'mips' ||
        tun.containsKey('inet4-address') ||
        tun.containsKey('inet6-address')) {
      return 'TUN 주소는 Android 빌더가 소유하며 스택은 mips여야 합니다.';
    }
    if (config.containsKey('dns') ||
        config.keys.any((k) => k.startsWith('external-controller'))) {
      return '앱 실행 설정에 DNS/controller 덮어쓰기를 사용할 수 없습니다.';
    }
    final proxies = config['proxies'];
    final groups = config['proxy-groups'];
    if (proxies is! List || proxies.isEmpty || groups is! List) {
      return '프록시/그룹이 없습니다.';
    }
    final names = {...reservedNames};
    for (final row in [...proxies, ...groups]) {
      if (row is! Map<String, Object?>) return '프록시/그룹 형식이 올바르지 않습니다.';
      final name = row['name'];
      if (name is! String || name.isEmpty || !names.add(name)) {
        return '예약되었거나 중복된 프록시/그룹 이름입니다.';
      }
    }
    for (final row in proxies) {
      final error = proxyError(row as Map<String, Object?>);
      if (error != null) return error;
    }
    final proxyProviders = config['proxy-providers'] as Map? ?? const {};
    final ruleProviders = config['rule-providers'] as Map? ?? const {};
    for (final section in [proxyProviders, ruleProviders]) {
      for (final provider in section.values) {
        if (provider is! Map) return 'provider는 매핑이어야 합니다.';
        final error = providerError(
          provider,
          rule: identical(section, ruleProviders),
        );
        if (error != null) return error;
      }
    }
    for (final row in groups.cast<Map<String, Object?>>()) {
      final error = groupError(row);
      if (error != null) return error;
      for (final name in row['proxies'] as List? ?? const []) {
        if (!names.contains(name)) return '그룹의 프록시 참조가 없습니다.';
      }
      for (final name in row['use'] as List? ?? const []) {
        if (!proxyProviders.containsKey(name)) return '그룹의 provider 참조가 없습니다.';
      }
    }
    final groupMap = {
      for (final row in groups.cast<Map<String, Object?>>()) row['name']: row,
    };
    bool cyclic(Object? name, Set<Object?> ancestors) {
      if (!ancestors.add(name)) return true;
      for (final next in groupMap[name]?['proxies'] as List? ?? const []) {
        if (groupMap.containsKey(next) && cyclic(next, {...ancestors})) {
          return true;
        }
      }
      return false;
    }

    if (groupMap.keys.any((name) => cyclic(name, {}))) return '그룹 참조가 순환합니다.';
    for (final rule in config['rules'] as List? ?? const []) {
      if (rule is! String) return '규칙 형식이 올바르지 않습니다.';
      final fields = rule.split(',').map((s) => s.trim()).toList();
      final kind = fields.first.toUpperCase();
      final targetIndex = kind == 'MATCH' ? 1 : 2;
      if (!ruleTypes.contains(kind) ||
          fields.length <= targetIndex ||
          !names.contains(fields[targetIndex])) {
        return '규칙 유형 또는 대상이 유효하지 않습니다.';
      }
      if (kind == 'RULE-SET' && !ruleProviders.containsKey(fields[1])) {
        return '규칙 provider 참조가 없습니다.';
      }
    }
    return null;
  }

  /// Mirror provider_admission.go. Fetch/redirect/cache checks remain native.
  static String? providerError(Map provider, {required bool rule}) {
    final unknown = _unknown(
      provider,
      rule
          ? 'type path url interval size-limit header behavior format payload'
          : 'type path url interval size-limit header health-check payload',
    );
    if (unknown != null) return 'provider: $unknown';
    final type = provider['type'];
    if (!const {'http', 'file', 'inline'}.contains(type)) {
      return 'provider 유형이 허용되지 않습니다.';
    }
    bool safeUrl(Object? raw) {
      final uri = raw is String ? Uri.tryParse(raw) : null;
      return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty;
    }

    if ((type == 'http' || provider.containsKey('url')) &&
        !safeUrl(provider['url'])) {
      return 'provider 주소는 사용자 정보가 없는 HTTPS여야 합니다.';
    }
    if (provider.containsKey('path')) {
      final path = provider['path'];
      if (path is! String ||
          path.isEmpty ||
          path.startsWith('/') ||
          path.contains('\\') ||
          path.split('/').contains('..')) {
        return 'provider 경로는 앱 전용 루트 아래 상대 경로여야 합니다.';
      }
    } else if (type == 'file') {
      return 'file provider에는 상대 경로가 필요합니다.';
    }
    bool validSeconds(Object? n) => n is int && n >= 0 && n <= 31536000;
    if (provider.containsKey('interval') &&
        !validSeconds(provider['interval'])) {
      return 'provider interval이 올바르지 않습니다.';
    }
    if (rule &&
        (!const {'domain', 'ipcidr'}.contains(provider['behavior']) ||
            (provider.containsKey('format') &&
                !const {'yaml', 'text', 'mrs'}.contains(provider['format'])))) {
      return '규칙 provider의 behavior/format이 허용되지 않습니다.';
    }
    final health = provider['health-check'];
    if (health != null) {
      if (health is! Map) return 'provider health-check는 매핑이어야 합니다.';
      final error = _unknown(
        health,
        'enable url interval timeout lazy expected-status',
      );
      if (error != null) return error;
      if (health.containsKey('url') && !safeUrl(health['url'])) {
        return 'provider 검사 주소는 HTTPS여야 합니다.';
      }
      for (final key in ['interval', 'timeout']) {
        if (health.containsKey(key) && !validSeconds(health[key])) {
          return 'provider health-check $key 값이 올바르지 않습니다.';
        }
      }
    }
    return null;
  }
}
