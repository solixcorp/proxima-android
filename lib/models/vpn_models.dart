import 'dart:convert';
import 'dart:collection';

enum VpnConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error;

  static VpnConnectionState fromWire(Object? value) {
    return values.firstWhere(
      (state) => state.name == value,
      orElse: () => VpnConnectionState.disconnected,
    );
  }
}

enum OutboundMode {
  rule('rule', '규칙', '프로필의 규칙에 따라 경로를 선택합니다.'),
  global('global', '전역', '모든 트래픽을 GLOBAL 정책 그룹으로 보냅니다.'),
  direct('direct', '직접', '프록시 없이 직접 연결합니다.');

  const OutboundMode(this.wireName, this.label, this.description);

  final String wireName;
  final String label;
  final String description;

  static OutboundMode fromWire(Object? value) => values.firstWhere(
    (mode) => mode.wireName == value,
    orElse: () => OutboundMode.rule,
  );
}

class VpnSnapshot {
  const VpnSnapshot({
    required this.state,
    this.profileId,
    this.profileName,
    this.startedAt,
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.totalUpload = 0,
    this.totalDownload = 0,
    this.activeNode,
    this.activeMode,
    this.error,
  });

  factory VpnSnapshot.fromMap(Map<Object?, Object?> map) {
    final startedAtMs = _integer(map['startedAt']);
    return VpnSnapshot(
      state: VpnConnectionState.fromWire(map['state']),
      profileId: map['profileId'] as String?,
      profileName: map['profileName'] as String?,
      startedAt: startedAtMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(startedAtMs)
          : null,
      uploadSpeed: _integer(map['uploadSpeed']),
      downloadSpeed: _integer(map['downloadSpeed']),
      totalUpload: _integer(map['totalUpload']),
      totalDownload: _integer(map['totalDownload']),
      activeNode: map['activeNode'] as String?,
      activeMode: map['activeMode'] as String?,
      error: map['error'] as String?,
    );
  }

  final VpnConnectionState state;
  final String? profileId;
  final String? profileName;
  final DateTime? startedAt;
  final int uploadSpeed;
  final int downloadSpeed;
  final int totalUpload;
  final int totalDownload;
  final String? activeNode;
  final String? activeMode;
  final String? error;

  bool get isConnected => state == VpnConnectionState.connected;
  bool get isBusy =>
      state == VpnConnectionState.connecting ||
      state == VpnConnectionState.disconnecting;
}

class VpnProfile {
  const VpnProfile({
    required this.id,
    required this.name,
    required this.updatedAt,
    required this.isActive,
    this.sourceUrl,
    this.subscriptionInfo,
  });

  factory VpnProfile.fromMap(Map<Object?, Object?> map) {
    return VpnProfile(
      id: map['id']! as String,
      name: map['name']! as String,
      sourceUrl: map['sourceUrl'] as String?,
      subscriptionInfo: map['subscriptionInfo'] is Map
          ? SubscriptionInfo.fromMap(
              (map['subscriptionInfo'] as Map).cast<Object?, Object?>(),
            )
          : null,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        _integer(map['updatedAt']),
      ),
      isActive: map['isActive'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final String? sourceUrl;
  final SubscriptionInfo? subscriptionInfo;
  final DateTime updatedAt;
  final bool isActive;

  /// A legacy subscription can have quota metadata even when an older app
  /// version did not preserve the refresh URL.  Do not mislabel it as local.
  bool get isSubscription =>
      sourceUrl?.trim().isNotEmpty == true || subscriptionInfo != null;

  String get sourceLabel {
    final source = sourceUrl;
    if (source == null || source.trim().isEmpty) {
      return isSubscription ? '구독 프로필' : '로컬 프로필';
    }
    final uri = Uri.tryParse(source);
    return uri?.host.isNotEmpty == true ? uri!.host : '구독 프로필';
  }
}

class SubscriptionInfo {
  const SubscriptionInfo({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire,
    this.planName,
  });

  factory SubscriptionInfo.fromMap(Map<Object?, Object?> map) {
    final expireSeconds = _integer(map['expire']);
    return SubscriptionInfo(
      upload: _integer(map['upload']),
      download: _integer(map['download']),
      total: _integer(map['total']),
      expire: expireSeconds > 0
          ? DateTime.fromMillisecondsSinceEpoch(expireSeconds * 1000)
          : null,
      planName: map['planName']?.toString().trim().isEmpty == true
          ? null
          : map['planName']?.toString().trim(),
    );
  }

  final int upload;
  final int download;
  final int total;
  final DateTime? expire;
  final String? planName;

  int get used => upload + download;
  int get remaining => total > used ? total - used : 0;
  bool get hasTraffic => total > 0;
  bool get hasDetails => hasTraffic || expire != null || planName != null;

  Map<String, Object> toMap() => {
    'upload': upload,
    'download': download,
    'total': total,
    'expire': (expire?.millisecondsSinceEpoch ?? 0) ~/ 1000,
    'planName': planName ?? '',
  };
}

String formatSubscriptionExpiry(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}.${two(local.month)}.${two(local.day)}';
}

class ImportedProfile {
  const ImportedProfile({required this.name, required this.content});

  factory ImportedProfile.fromMap(Map<Object?, Object?> map) => ImportedProfile(
    name: map['name']?.toString() ?? '가져온 프로필.yaml',
    content: map['content']?.toString() ?? '',
  );

  final String name;
  final String content;
}

class QrProfileResult {
  const QrProfileResult({
    required this.content,
    this.sourceUrl,
    this.subscriptionInfo,
  });

  final String content;
  final String? sourceUrl;
  final SubscriptionInfo? subscriptionInfo;
}

class VpnSettings {
  const VpnSettings({
    this.stack = 'mixed',
    this.ipv6 = true,
    this.mtu = 1400,
    this.mode = OutboundMode.rule,
  });

  factory VpnSettings.fromMap(Map<Object?, Object?> map) {
    return VpnSettings(
      stack: map['stack'] as String? ?? 'mixed',
      ipv6: map['ipv6'] as bool? ?? true,
      mtu: _integer(map['mtu'], fallback: 1400),
      mode: OutboundMode.fromWire(map['mode']),
    );
  }

  final String stack;
  final bool ipv6;
  final int mtu;
  final OutboundMode mode;

  VpnSettings copyWith({
    String? stack,
    bool? ipv6,
    int? mtu,
    OutboundMode? mode,
  }) {
    return VpnSettings(
      stack: stack ?? this.stack,
      ipv6: ipv6 ?? this.ipv6,
      mtu: mtu ?? this.mtu,
      mode: mode ?? this.mode,
    );
  }

  Map<String, Object> toMap() => {
    'stack': stack,
    'ipv6': ipv6,
    'mtu': mtu,
    'mode': mode.wireName,
  };
}

class RoutingRule {
  const RoutingRule({
    required this.destination,
    required this.target,
    required this.candidates,
    this.network,
    this.port,
    this.supported = true,
  });

  factory RoutingRule.fromMap(Map<String, Object?> map) {
    final raw = map['raw']?.toString();
    final parts = raw?.split(',');
    final compoundRule = parts != null &&
        const {'AND', 'OR', 'NOT'}.contains(parts.first.toUpperCase());
    final simpleRule = parts != null &&
        parts.length >= 3 &&
        !compoundRule;
    final destinations = [
      ...?map['domain'] as List?,
      ...?map['ip'] as List?,
    ];
    final policy = simpleRule
        ? parts[2].trim()
        : map['policy']?.toString() ?? (compoundRule ? parts.last.trim() : null);
    final target = switch (map['target'] ?? policy) {
      'direct' || 'DIRECT' => '직접 연결',
      'block' || 'REJECT' || 'REJECT-DROP' => '차단',
      _ => policy ?? '자동 선택',
    };
    return RoutingRule(
      destination: destinations.isNotEmpty
          ? destinations.join('\n')
          : map['match'] == true
          ? '나머지 모든 트래픽'
          : simpleRule
          ? [...parts.take(2), ...parts.skip(3)].join(',')
          : raw ?? '',
      target: target,
      candidates: (map['candidates'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      network: map['network']?.toString(),
      port: map['port']?.toString(),
      supported: map['supported'] != false,
    );
  }

  final String destination;
  final String target;
  final List<String> candidates;
  final String? network;
  final String? port;
  final bool supported;
}

class ProxyGroup {
  const ProxyGroup({
    required this.name,
    required this.type,
    required this.selected,
    required this.proxies,
  });

  final String name;
  final String type;
  final String selected;
  final List<String> proxies;
}

String displayProxyName(String value) {
  if (!value.contains('%')) return value;
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}

class ActiveConnection {
  const ActiveConnection({
    required this.id,
    required this.host,
    required this.destinationIp,
    required this.destinationPort,
    required this.network,
    required this.type,
    required this.process,
    required this.rule,
    required this.rulePayload,
    required this.chains,
    required this.upload,
    required this.download,
    required this.startedAt,
  });

  factory ActiveConnection.fromMap(Map<String, dynamic> map) {
    final metadata = _stringMap(map['metadata']);
    final rawChains = map['chains'];
    return ActiveConnection(
      id: map['id']?.toString() ?? '',
      host: metadata['host']?.toString().isNotEmpty == true
          ? metadata['host'].toString()
          : metadata['sniffHost']?.toString() ?? '',
      destinationIp: metadata['destinationIP']?.toString() ?? '',
      destinationPort: _integer(metadata['destinationPort']),
      network: metadata['network']?.toString().toUpperCase() ?? '',
      type: metadata['type']?.toString() ?? '',
      process: metadata['process']?.toString() ?? '',
      rule: map['rule']?.toString() ?? '',
      rulePayload: map['rulePayload']?.toString() ?? '',
      chains: rawChains is List
          ? rawChains.map((item) => item.toString()).toList(growable: false)
          : const [],
      upload: _integer(map['upload']),
      download: _integer(map['download']),
      startedAt: DateTime.tryParse(map['start']?.toString() ?? ''),
    );
  }

  final String id;
  final String host;
  final String destinationIp;
  final int destinationPort;
  final String network;
  final String type;
  final String process;
  final String rule;
  final String rulePayload;
  final List<String> chains;
  final int upload;
  final int download;
  final DateTime? startedAt;

  String get destination {
    final address = host.isNotEmpty ? host : destinationIp;
    if (address.isEmpty) return '알 수 없는 목적지';
    return destinationPort > 0 ? '$address:$destinationPort' : address;
  }

  String get route => chains.isEmpty ? 'DIRECT' : chains.join(' → ');
}

class ConnectionOverview {
  const ConnectionOverview({
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.memory = 0,
    this.connections = const [],
  });

  factory ConnectionOverview.fromMap(Map<String, dynamic> map) {
    final rawConnections = map['connections'];
    final connections = rawConnections is List
        ? rawConnections
              .whereType<Map>()
              .map(
                (item) => ActiveConnection.fromMap(
                  item.map((key, value) => MapEntry(key.toString(), value)),
                ),
              )
              .toList()
        : <ActiveConnection>[];
    connections.sort((a, b) {
      final left = a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right = b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return right.compareTo(left);
    });
    return ConnectionOverview(
      uploadTotal: _integer(map['uploadTotal']),
      downloadTotal: _integer(map['downloadTotal']),
      memory: _integer(map['memory']),
      connections: connections,
    );
  }

  final int uploadTotal;
  final int downloadTotal;
  final int memory;
  final List<ActiveConnection> connections;
}

class CoreProvider {
  const CoreProvider({
    required this.name,
    required this.type,
    required this.vehicleType,
    required this.count,
    required this.path,
    this.updatedAt,
  });

  factory CoreProvider.fromMap(Map<String, dynamic> map) => CoreProvider(
    name: map['name']?.toString() ?? '',
    type: map['type']?.toString() ?? '',
    vehicleType: map['vehicle-type']?.toString() ?? '',
    count: _integer(map['count']),
    path: map['path']?.toString() ?? '',
    updatedAt: DateTime.tryParse(map['update-at']?.toString() ?? ''),
  );

  final String name;
  final String type;
  final String vehicleType;
  final int count;
  final String path;
  final DateTime? updatedAt;
}

class PublicIpInfo {
  const PublicIpInfo({
    required this.ip,
    this.city = '',
    this.region = '',
    this.country = '',
    this.organization = '',
    this.rejected = false,
  });

  factory PublicIpInfo.fromMap(Map<String, dynamic> map) => PublicIpInfo(
    ip: map['ip']?.toString() ?? '',
    city: map['city']?.toString() ?? '',
    region: map['region']?.toString() ?? '',
    country: map['country']?.toString() ?? '',
    organization: map['org']?.toString() ?? '',
    rejected: map['status'] == 'REJECT',
  );

  final String ip;
  final String city;
  final String region;
  final String country;
  final String organization;
  final bool rejected;

  String get location =>
      [city, region, country].where((part) => part.isNotEmpty).join(', ');
}

class NetworkInfo {
  const NetworkInfo({
    this.transport = '알 수 없음',
    this.dnsServers = const [],
    this.metered = false,
    this.validated = false,
  });

  factory NetworkInfo.fromMap(Map<Object?, Object?> map) => NetworkInfo(
    transport: map['transport']?.toString() ?? '알 수 없음',
    dnsServers:
        (map['dnsServers'] as List?)
            ?.map((item) => item.toString())
            .toList(growable: false) ??
        const [],
    metered: map['metered'] as bool? ?? false,
    validated: map['validated'] as bool? ?? false,
  );

  final String transport;
  final List<String> dnsServers;
  final bool metered;
  final bool validated;
}

List<ProxyGroup> parseProxyGroups(
  String actionResult, {
  OutboundMode mode = OutboundMode.rule,
}) {
  final decoded = _corePayload(actionResult);
  final proxies = _stringMap(decoded)['proxies'];
  if (proxies is! Map) return const [];

  final groups = <ProxyGroup>[];
  final nodeNames = <String>[];
  for (final entry in proxies.entries) {
    final value = entry.value;
    if (value is! Map) continue;
    final group = value.map((key, item) => MapEntry(key.toString(), item));
    final all = group['all'];
    if (all is! List && _isProxyNode(group)) {
      nodeNames.add(entry.key.toString());
    }
    if (all is! List || all.isEmpty) continue;
    groups.add(
      ProxyGroup(
        name: entry.key.toString(),
        type: group['type']?.toString() ?? 'Selector',
        selected: group['now']?.toString() ?? all.first.toString(),
        proxies: all.map((item) => item.toString()).toList(growable: false),
      ),
    );
  }

  if (mode == OutboundMode.direct) return const [];

  if (mode == OutboundMode.global && nodeNames.isNotEmpty) {
    final uniqueNodes = LinkedHashSet<String>.of(nodeNames).toList();
    final existingIndex = groups.indexWhere((group) => group.name == 'GLOBAL');
    final existing = existingIndex >= 0 ? groups[existingIndex] : null;
    final selected = existing?.selected;
    final globalGroup = ProxyGroup(
      name: 'GLOBAL',
      type: existing?.type ?? 'Selector',
      selected: selected != null && uniqueNodes.contains(selected)
          ? selected
          : uniqueNodes.first,
      proxies: uniqueNodes,
    );
    return [globalGroup];
  }

  if (mode == OutboundMode.global) {
    return groups.where((group) => group.name == 'GLOBAL').toList();
  }

  final ruleGroups = groups
      .where((group) => group.name != 'GLOBAL')
      .toList(growable: false);
  ruleGroups.sort((a, b) => a.name.compareTo(b.name));
  return ruleGroups;
}

bool _isProxyNode(Map<String, Object?> proxy) {
  final type = proxy['type']?.toString().toLowerCase();
  if (type == null || type.isEmpty) return false;
  return !{
    'selector',
    'urltest',
    'loadbalance',
    'fallback',
    'relay',
    'direct',
    'reject',
    'compatible',
    'pass',
  }.contains(type);
}

ConnectionOverview parseConnections(String actionResult) {
  final payload = _corePayload(actionResult);
  return ConnectionOverview.fromMap(_stringMap(payload));
}

List<CoreProvider> parseProviders(String actionResult) {
  final payload = _corePayload(actionResult);
  if (payload is! List) return const [];
  final providers = payload
      .whereType<Map>()
      .map(
        (item) => CoreProvider.fromMap(
          item.map((key, value) => MapEntry(key.toString(), value)),
        ),
      )
      .toList();
  providers.sort((a, b) => a.name.compareTo(b.name));
  return providers;
}

PublicIpInfo parsePublicIp(String actionResult) {
  final payload = _corePayload(actionResult);
  return PublicIpInfo.fromMap(_stringMap(payload));
}

int parseCoreInteger(String actionResult) =>
    _integer(_corePayload(actionResult));

String formatCoreVersion(Object? value) {
  if (value == null) return 'unknown';
  final raw = value is Map && value['version'] != null
      ? value['version'].toString()
      : value.toString();
  final version = RegExp(r'\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?')
      .firstMatch(raw);
  if (version != null) return version.group(0)!;
  final fallback = raw.trim().replaceFirst(RegExp(r'^[vV*\s]+'), '');
  return fallback.isEmpty ? 'unknown' : fallback;
}

dynamic _corePayload(String actionResult) {
  final envelope = jsonDecode(actionResult) as Map<String, dynamic>;
  if (envelope['code'] != 0) {
    throw FormatException(envelope['data']?.toString() ?? '코어 요청 실패');
  }
  final payload = envelope['data'];
  if (payload is String && payload.isNotEmpty) {
    try {
      return jsonDecode(payload);
    } on FormatException {
      return payload;
    }
  }
  return payload;
}

void ensureCoreSuccess(String actionResult) {
  final envelope = jsonDecode(actionResult) as Map<String, dynamic>;
  if (envelope['code'] != 0) {
    throw StateError(envelope['data']?.toString() ?? '코어 요청 실패');
  }
  final data = envelope['data'];
  if (data is String && data.isNotEmpty) throw StateError(data);
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, item) => MapEntry(key.toString(), item));
}

int _integer(Object? value, {int fallback = 0}) => switch (value) {
  int() => value,
  num() => value.toInt(),
  String() => int.tryParse(value) ?? fallback,
  _ => fallback,
};

String formatBytes(int bytes, {bool perSecond = false}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final precision = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}${perSecond ? '/s' : ''}';
}
