import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/native_vpn_bridge.dart';
import '../core/clash_subscription.dart';
import '../core/vless_reality_profile.dart';
import '../models/vpn_models.dart';

class SubscriptionFetchResult {
  const SubscriptionFetchResult({required this.content, this.info});

  final String content;
  final SubscriptionInfo? info;
}

class AppController extends ChangeNotifier {
  AppController(this.bridge);

  final VpnBridge bridge;
  StreamSubscription<VpnSnapshot>? _snapshotSubscription;

  VpnSnapshot snapshot = const VpnSnapshot(
    state: VpnConnectionState.disconnected,
  );
  List<VpnProfile> profiles = const [];
  List<ProxyGroup> proxyGroups = const [];
  ConnectionOverview connectionOverview = const ConnectionOverview();
  List<CoreProvider> providers = const [];
  PublicIpInfo? publicIp;
  NetworkInfo networkInfo = const NetworkInfo();
  VpnSettings settings = const VpnSettings();
  Map<Object?, Object?> core = const {};
  bool initialized = false;
  bool loadingProfiles = false;
  bool loadingProxies = false;
  bool loadingConnections = false;
  bool loadingProviders = false;
  bool loadingPublicIp = false;
  bool loadingNetwork = false;
  bool _proxyReloadPending = false;
  String? message;

  VpnProfile? get activeProfile {
    final runtimeProfileId = switch (snapshot.state) {
      VpnConnectionState.connecting ||
      VpnConnectionState.connected ||
      VpnConnectionState.disconnecting => snapshot.profileId,
      VpnConnectionState.disconnected || VpnConnectionState.error => null,
    };
    if (runtimeProfileId != null) {
      for (final profile in profiles) {
        if (profile.id == runtimeProfileId) return profile;
      }
    }
    for (final profile in profiles) {
      if (profile.isActive) return profile;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  ProxyGroup? get globalProxyGroup {
    for (final group in proxyGroups) {
      if (group.name == 'GLOBAL') return group;
    }
    return null;
  }

  String? get currentProxyGroupName => switch (settings.mode) {
    OutboundMode.global => 'GLOBAL',
    OutboundMode.rule || OutboundMode.direct => null,
  };

  ProxyGroup? get currentProxyGroup {
    final name = currentProxyGroupName;
    if (name == null) return null;
    for (final group in proxyGroups) {
      if (group.name == name) return group;
    }
    return null;
  }

  Future<void> initialize() async {
    _snapshotSubscription = bridge.snapshots.listen(
      _handleSnapshot,
      onError: (_) {},
    );
    try {
      final values = await Future.wait<Object>([
        bridge.getSnapshot(),
        bridge.listProfiles(),
        bridge.loadSettings(),
        bridge.coreInfo(),
        bridge.getNetworkInfo(),
      ]);
      snapshot = values[0] as VpnSnapshot;
      profiles = values[1] as List<VpnProfile>;
      settings = values[2] as VpnSettings;
      core = values[3] as Map<Object?, Object?>;
      networkInfo = values[4] as NetworkInfo;
      if (snapshot.isConnected) {
        _beginConnectedRefresh();
      } else if (settings.mode != OutboundMode.direct) {
        await loadProxyGroups();
      }
    } catch (error) {
      message = '초기화하지 못했습니다: $error';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  void _handleSnapshot(VpnSnapshot next) {
    final becameConnected = !snapshot.isConnected && next.isConnected;
    snapshot = next;
    if (becameConnected) {
      _beginConnectedRefresh();
    } else if (next.state == VpnConnectionState.disconnected ||
        next.state == VpnConnectionState.error) {
      connectionOverview = const ConnectionOverview();
      providers = const [];
      publicIp = null;
      if (settings.mode != OutboundMode.direct) {
        unawaited(loadProxyGroups());
      } else {
        proxyGroups = const [];
      }
    }
    notifyListeners();
  }

  void _beginConnectedRefresh() {
    unawaited(loadProxyGroups());
  }

  Future<void> toggleVpn() async {
    if (snapshot.isBusy) return;
    message = null;
    try {
      if (snapshot.isConnected) {
        await bridge.stopVpn();
        return;
      }
      var profile = activeProfile;
      if (profile == null) throw StateError('먼저 프로필을 추가해 주세요.');
      profile = await _refreshRuleSubscriptionIfNeeded(profile);
      final granted = await bridge.requestVpnPermission();
      if (!granted) throw StateError('VPN 권한이 필요합니다.');
      await bridge.startVpn(profile.id);
    } catch (error) {
      _report(error);
    }
  }

  Future<void> reloadProfiles() async {
    loadingProfiles = true;
    notifyListeners();
    try {
      profiles = await bridge.listProfiles();
    } finally {
      loadingProfiles = false;
      notifyListeners();
    }
  }

  Future<String?> validateProfile(String content) =>
      bridge.validateProfile(content);

  Future<void> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
    SubscriptionInfo? subscriptionInfo,
  }) async {
    if (snapshot.isBusy) {
      throw StateError('연결 상태가 바뀐 뒤 프로필을 저장해 주세요.');
    }
    VlessRealityProfile.parseMany(content);
    final requestedName = name.trim();
    final effectiveName =
        requestedName.isEmpty ||
            VlessRealityProfile.isAutomaticProfileName(requestedName)
        ? VlessRealityProfile.suggestedProfileName(
            content,
            sourceUrl: sourceUrl,
            fallbackName: requestedName,
          )
        : requestedName;
    final generatedConfig = VlessRealityProfile.attachSubscriptionSource(
      VlessRealityProfile.storedConfigFromInput(
        content,
        profileName: effectiveName,
      ),
      sourceUrl,
    );
    final validationError = await validateProfile(generatedConfig);
    if (validationError != null && validationError.isNotEmpty) {
      throw FormatException(validationError);
    }
    final saved = await bridge.saveProfile(
      id: id,
      name: effectiveName,
      sourceUrl: sourceUrl?.trim(),
      content: generatedConfig,
      subscriptionInfo: subscriptionInfo,
    );
    await reloadProfiles();
    if (!snapshot.isConnected && settings.mode != OutboundMode.direct) {
      await loadProxyGroups();
    }
    if (snapshot.isConnected && snapshot.profileId == saved.id) {
      await bridge.startVpn(saved.id);
    }
  }

  Future<void> selectProfile(String id) async {
    if (snapshot.isBusy) {
      throw StateError('연결 상태가 바뀐 뒤 프로필을 변경해 주세요.');
    }
    await bridge.selectProfile(id);
    await reloadProfiles();
    if (snapshot.isConnected && snapshot.profileId != id) {
      await bridge.startVpn(id);
    } else if (!snapshot.isConnected && settings.mode != OutboundMode.direct) {
      await loadProxyGroups();
    }
  }

  Future<void> deleteProfile(String id) async {
    if (snapshot.isBusy) {
      throw StateError('연결 상태가 바뀐 뒤 프로필을 삭제해 주세요.');
    }
    await bridge.deleteProfile(id);
    await reloadProfiles();
    if (!snapshot.isConnected && settings.mode != OutboundMode.direct) {
      await loadProxyGroups();
    }
  }

  Future<ImportedProfile?> pickProfileFile() => bridge.pickProfileFile();

  Future<bool> exportProfile(VpnProfile profile) async {
    final content = await readProfileLink(profile);
    return bridge.exportProfileFile(
      name: '${_safeFileName(profile.name)}.txt',
      content: content,
    );
  }

  Future<String> readProfileLink(VpnProfile profile) async {
    final config = await bridge.readProfile(profile.id);
    final links = VlessRealityProfile.linksFromStoredConfig(config);
    if (links.isNotEmpty) {
      final rules = VlessRealityProfile.inlineRulesFromStoredConfig(config);
      return [
        links.join('\n'),
        if (rules != null && rules.isNotEmpty) rules,
      ].join('\n');
    }
    throw const FormatException(
      '이전 Mihomo YAML 프로필입니다. VLESS + REALITY 링크로 새 프로필을 추가해 주세요.',
    );
  }

  String _safeFileName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^a-zA-Z0-9._\-가-힣 ]'), '_');
    return cleaned.trim().isEmpty ? 'profile' : cleaned.trim();
  }

  Future<String> fetchSubscription(String source) async =>
      (await fetchSubscriptionDetails(source)).content;

  Future<QrProfileResult> resolveQrPayload(
    String value, {
    Future<SubscriptionFetchResult> Function(String source)?
    subscriptionFetcher,
  }) async {
    final payload = value.trim();
    try {
      return QrProfileResult(
        content: VlessRealityProfile.normalizeLinkInput(payload),
      );
    } on FormatException {
      // A QR may contain a landing/subscription URL instead of the link itself.
    }

    final uri = Uri.tryParse(payload);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('이 QR 코드에서 VLESS + REALITY 정보를 찾지 못했습니다.');
    }

    // Preserve the existing behavior for landing URLs that embed the actual
    // VLESS payload in a query parameter or fragment.
    for (final candidate in [...uri.queryParameters.values, uri.fragment]) {
      if (candidate.isEmpty) continue;
      try {
        return QrProfileResult(
          content: VlessRealityProfile.normalizeLinkInput(candidate),
        );
      } on FormatException {
        // Try the next parameter, then the URL as a subscription endpoint.
      }
    }

    final subscription =
        await (subscriptionFetcher ?? fetchSubscriptionDetails)(payload);
    final links = VlessRealityProfile.linksFromSubscription(
      subscription.content,
    );
    if (links.isEmpty) {
      throw const FormatException('구독에서 VLESS + REALITY 노드를 찾지 못했습니다.');
    }
    return QrProfileResult(
      content: subscription.content,
      sourceUrl: payload,
      subscriptionInfo: subscription.info ?? const SubscriptionInfo(),
    );
  }

  Future<SubscriptionFetchResult> fetchSubscriptionDetails(
    String source,
  ) async {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('HTTPS 구독 주소를 입력해 주세요.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await fetchPreferredSubscription(
        (userAgent) => _fetchSubscriptionWithUserAgent(client, uri, userAgent),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<SubscriptionFetchResult> fetchPreferredSubscription(
    Future<SubscriptionFetchResult> Function(String userAgent) fetch,
  ) async {
    SubscriptionFetchResult? fallback;
    Object? firstRequestError;
    StackTrace? firstRequestStack;
    var receivedResponse = false;
    for (final userAgent in const [
      'clash.meta',
      'ClashForAndroid',
      'v2rayN/6.45 Proxima/1.0',
    ]) {
      // The legacy identity is only needed when neither Clash request yielded
      // a usable subscription. Some providers reject the Clash identities.
      if (userAgent == 'v2rayN/6.45 Proxima/1.0' && fallback != null) break;
      late final SubscriptionFetchResult result;
      try {
        result = await fetch(userAgent);
      } catch (error, stack) {
        firstRequestError ??= error;
        firstRequestStack ??= stack;
        continue;
      }
      receivedResponse = true;
      try {
        if (ClashSubscriptionParser.tryParse(result.content) != null) {
          return result;
        }
        VlessRealityProfile.linksFromSubscription(result.content);
        fallback ??= result;
      } on FormatException {
        // A second client identity may receive a usable VLESS or Clash format.
      }
    }
    if (fallback != null) return fallback;
    if (receivedResponse) {
      throw const FormatException('구독에서 지원되는 VLESS 링크나 Clash YAML을 찾지 못했습니다.');
    }
    if (firstRequestError != null) {
      Error.throwWithStackTrace(firstRequestError, firstRequestStack!);
    }
    throw const FormatException('구독에서 지원되는 VLESS 링크나 Clash YAML을 찾지 못했습니다.');
  }

  Future<SubscriptionFetchResult> _fetchSubscriptionWithUserAgent(
    HttpClient client,
    Uri uri,
    String userAgent,
  ) async {
    var current = uri;
    late HttpClientResponse response;
    for (var redirects = 0; ; redirects++) {
      final request = await client.getUrl(current);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/yaml, text/yaml, text/plain, */*',
      );
      response = await request.close().timeout(const Duration(seconds: 20));
      if (!response.isRedirect) break;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || redirects >= 5) {
        throw const HttpException('구독 주소의 리디렉션이 너무 많습니다.');
      }
      final redirected = current.resolve(location);
      if (redirected.scheme != 'https' || redirected.host.isEmpty) {
        throw const FormatException('HTTPS가 아닌 주소로 이동할 수 없습니다.');
      }
      current = redirected;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final statusCode = response.statusCode;
      await response.drain<void>();
      if (statusCode == HttpStatus.forbidden) {
        throw const HttpException(
          '구독 서버가 접근을 거부했습니다(403). 구독 주소나 계정 상태를 확인해 주세요.',
        );
      }
      throw HttpException('서버 응답 $statusCode');
    }
    final info = _subscriptionInfo(response.headers);
    final chunks = <int>[];
    await for (final chunk in response) {
      chunks.addAll(chunk);
      if (chunks.length > 8 * 1024 * 1024) {
        throw const FormatException('프로필은 8MB보다 작아야 합니다.');
      }
    }
    return SubscriptionFetchResult(content: utf8.decode(chunks), info: info);
  }

  Future<void> refreshProfile(VpnProfile profile) async {
    final source = profile.sourceUrl;
    if (source == null || source.isEmpty) return;
    final subscription = await fetchSubscriptionDetails(source);
    // Preserve Clash.Meta groups/rules. saveProfile normalizes them into the
    // compact metadata consumed by the native Xray runtime.
    final content = subscription.content;
    await saveProfile(
      id: profile.id,
      name: profile.name,
      sourceUrl: source,
      content: content,
      // Some providers omit usage headers on otherwise valid refreshes. Keep
      // the last known quota instead of replacing it with an empty value.
      subscriptionInfo: subscription.info ?? profile.subscriptionInfo,
    );
  }

  Future<VpnProfile> _refreshRuleSubscriptionIfNeeded(
    VpnProfile profile,
  ) async {
    if (!await _needsRuleSubscriptionRefresh(profile)) return profile;
    try {
      await refreshProfile(profile);
    } catch (error) {
      throw StateError('규칙 모드를 시작하려면 구독 업데이트가 필요합니다: $error');
    }
    return activeProfile ?? profile;
  }

  Future<bool> _needsRuleSubscriptionRefresh(VpnProfile profile) async {
    if (settings.mode != OutboundMode.rule ||
        profile.sourceUrl?.trim().isEmpty != false) {
      return false;
    }
    final content = await bridge.readProfile(profile.id);
    return !VlessRealityProfile.hasCurrentRoutingMetadata(content);
  }

  Future<void> updateSettings(VpnSettings next) async {
    settings = next;
    notifyListeners();
    await bridge.saveSettings(next);
  }

  Future<void> setMode(OutboundMode mode) async {
    if (snapshot.isBusy) {
      throw StateError('연결 상태가 바뀐 뒤 모드를 변경해 주세요.');
    }
    if (mode == settings.mode) return;
    final previous = settings;
    await updateSettings(settings.copyWith(mode: mode));
    if (!snapshot.isConnected) {
      if (mode == OutboundMode.rule) {
        final profile = activeProfile;
        if (profile != null) await _refreshRuleSubscriptionIfNeeded(profile);
      }
      await loadProxyGroups();
      return;
    }
    try {
      if (mode == OutboundMode.rule) {
        final profile = activeProfile;
        if (profile != null && await _needsRuleSubscriptionRefresh(profile)) {
          // refreshProfile restarts the active VPN using the mode already
          // saved above, so avoid issuing a second restart below.
          await refreshProfile(profile);
          return;
        }
      }
      ensureCoreSuccess(
        await bridge.invokeCore(
          'updateConfig',
          jsonEncode({'mode': mode.wireName}),
        ),
      );
      // Xray applies a mode change by restarting. Build the selector from the
      // saved links while it is connecting; the connected event will reload
      // the authoritative state after the new core is ready.
      proxyGroups = await _offlineProxyGroups();
      _clearProxyMessage();
      notifyListeners();
    } catch (_) {
      settings = previous;
      await bridge.saveSettings(previous);
      proxyGroups = await _offlineProxyGroups();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> loadProxyGroups() async {
    if (loadingProxies) {
      _proxyReloadPending = true;
      return;
    }
    loadingProxies = true;
    notifyListeners();
    try {
      if (snapshot.isConnected) {
        proxyGroups = parseProxyGroups(
          await bridge.invokeCore('getProxies'),
          mode: settings.mode,
        );
      } else {
        proxyGroups = await _offlineProxyGroups();
      }
      _clearProxyMessage();
    } catch (error) {
      message = '노드 목록을 불러오지 못했습니다: $error';
    } finally {
      loadingProxies = false;
      notifyListeners();
      if (_proxyReloadPending) {
        _proxyReloadPending = false;
        unawaited(loadProxyGroups());
      }
    }
  }

  Future<void> selectProxy(String group, String proxy) async {
    if (settings.mode != OutboundMode.global || group != 'GLOBAL') {
      throw StateError('노드는 전역 모드에서만 직접 선택할 수 있습니다.');
    }
    if (snapshot.isBusy) {
      throw StateError('연결 상태가 바뀐 뒤 노드를 변경해 주세요.');
    }
    if (snapshot.isConnected) {
      final previousGroups = proxyGroups;
      _setProxySelection(group, proxy);
      notifyListeners();
      try {
        ensureCoreSuccess(
          await bridge.invokeCore(
            'changeProxy',
            jsonEncode({'group-name': group, 'proxy-name': proxy}),
          ),
        );
        _clearProxyMessage();
        notifyListeners();
      } catch (_) {
        proxyGroups = previousGroups;
        notifyListeners();
        rethrow;
      }
      // Xray restarts after changeProxy. The connecting -> connected snapshot
      // transition calls _beginConnectedRefresh(), which safely reloads the
      // authoritative proxy state after the new core is ready.
      return;
    }
    final profile = activeProfile;
    final expectedGroup = currentProxyGroupName;
    if (expectedGroup == null || group != expectedGroup) {
      throw StateError('현재 작동 모드에서 선택할 수 없는 정책 그룹입니다.');
    }
    if (profile == null) throw StateError('먼저 프로필을 추가해 주세요.');
    final current = currentProxyGroup;
    if (current == null || !current.proxies.contains(proxy)) {
      throw StateError('선택할 수 없는 노드입니다.');
    }
    await bridge.saveProxySelection(
      profileId: profile.id,
      group: group,
      proxy: proxy,
    );
    _setProxySelection(group, proxy);
    _clearProxyMessage();
    notifyListeners();
  }

  void _setProxySelection(String group, String proxy) {
    proxyGroups = proxyGroups
        .map(
          (item) => item.name == group
              ? ProxyGroup(
                  name: item.name,
                  type: item.type,
                  selected: proxy,
                  proxies: item.proxies,
                )
              : item,
        )
        .toList(growable: false);
  }

  void _clearProxyMessage() {
    final current = message;
    if (current != null && current.startsWith('노드 목록을 불러오지 못했습니다:')) {
      message = null;
    }
  }

  Future<List<ProxyGroup>> _offlineProxyGroups() async {
    final groupName = currentProxyGroupName;
    if (groupName == null) return const [];
    final profile = activeProfile;
    if (profile == null) return const [];
    final content = await bridge.readProfile(profile.id);
    final nodes = VlessRealityProfile.nodeNamesFromStoredConfig(
      content,
      profileName: profile.name,
    );
    if (nodes.isEmpty) return const [];
    final selections = await bridge.loadProxySelections(profile.id);
    final selected =
        selections[groupName] ??
        (groupName == 'PROXY' ? selections['GLOBAL'] : null);
    return [
      ProxyGroup(
        name: groupName,
        type: 'Selector',
        selected: selected != null && nodes.contains(selected)
            ? selected
            : nodes.first,
        proxies: nodes,
      ),
    ];
  }

  SubscriptionInfo? _subscriptionInfo(HttpHeaders headers) {
    final values = <String, List<String>>{};
    headers.forEach((name, items) => values[name.toLowerCase()] = items);
    String? firstHeader(Iterable<String> names) {
      for (final name in names) {
        final entries = values[name];
        final value = entries == null || entries.isEmpty ? null : entries.first;
        if (value != null && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    String? userInfo;
    for (final entry in values.entries) {
      final name = entry.key;
      if (name == 'subscription-userinfo' ||
          (name.endsWith('-subscription-userinfo') && name.length > 22)) {
        userInfo = entry.value.isEmpty ? null : entry.value.first;
        break;
      }
    }
    final plan = _decodeSubscriptionTitle(
      firstHeader([
        'subscription-plan',
        'x-subscription-plan',
        'profile-title',
        'subscription-title',
        'x-subscription-title',
      ]),
    );
    if (userInfo == null && plan == null) return null;
    int number(String key) {
      final match = RegExp(
        '(?:^|[;,\\s])$key\\s*=\\s*(\\d+)',
        caseSensitive: false,
      ).firstMatch(userInfo ?? '');
      return int.tryParse(match?.group(1) ?? '') ?? 0;
    }

    final expire = number('expire');
    return SubscriptionInfo(
      upload: number('upload'),
      download: number('download'),
      total: number('total'),
      expire: expire > 0
          ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
          : null,
      planName: plan,
    );
  }

  String? _decodeSubscriptionTitle(String? value) {
    if (value == null || value.isEmpty) return null;
    final title = value.startsWith('base64:') ? value.substring(7) : value;
    if (value.startsWith('base64:')) {
      try {
        return utf8.decode(base64.decode(base64.normalize(title))).trim();
      } on FormatException {
        return null;
      }
    }
    try {
      return Uri.decodeComponent(title).trim();
    } on FormatException {
      return title.trim();
    }
  }

  Future<int?> testDelay(String proxy) async {
    final result = await bridge.invokeCore(
      'testDelay',
      jsonEncode({
        'proxy-name': proxy,
        'test-url': 'https://www.gstatic.com/generate_204',
        'timeout': 3000,
      }),
    );
    final envelope = jsonDecode(result) as Map<String, dynamic>;
    if (envelope['code'] != 0) return null;
    final value = envelope['data'];
    return value is int && value >= 0 ? value : null;
  }

  Future<void> loadConnections({bool silent = false}) async {
    if (!snapshot.isConnected || loadingConnections) return;
    loadingConnections = true;
    if (!silent) notifyListeners();
    try {
      final results = await Future.wait([
        bridge.invokeCore('getConnections'),
        bridge.invokeCore('getMemory'),
      ]);
      final overview = parseConnections(results[0]);
      connectionOverview = ConnectionOverview(
        uploadTotal: overview.uploadTotal,
        downloadTotal: overview.downloadTotal,
        memory: parseCoreInteger(results[1]),
        connections: overview.connections,
      );
    } catch (error) {
      if (!silent) message = '연결 목록을 불러오지 못했습니다: $error';
    } finally {
      loadingConnections = false;
      notifyListeners();
    }
  }

  Future<void> closeConnection(String id) async {
    ensureCoreSuccess(await bridge.invokeCore('closeConnection', id));
    await loadConnections();
  }

  Future<void> closeAllConnections() async {
    ensureCoreSuccess(await bridge.invokeCore('closeAllConnections'));
    await loadConnections();
  }

  Future<void> loadProviders() async {
    if (!snapshot.isConnected || loadingProviders) return;
    loadingProviders = true;
    notifyListeners();
    try {
      providers = parseProviders(
        await bridge.invokeCore('queryExternalProviders'),
      );
    } catch (error) {
      message = 'Provider 목록을 불러오지 못했습니다: $error';
    } finally {
      loadingProviders = false;
      notifyListeners();
    }
  }

  Future<void> updateProvider(CoreProvider provider) async {
    ensureCoreSuccess(
      await bridge.invokeCore(
        'updateExternalProvider',
        jsonEncode({'type': provider.type, 'name': provider.name}),
      ),
    );
    await loadProviders();
  }

  Future<void> probePublicIp() async {
    if (!snapshot.isConnected || loadingPublicIp) return;
    loadingPublicIp = true;
    notifyListeners();
    try {
      publicIp = parsePublicIp(
        await bridge.invokeCore('probeCurrentProxyIp', settings.mode.wireName),
      );
    } catch (error) {
      message = '외부 IP를 확인하지 못했습니다: ${_readableError(error)}';
    } finally {
      loadingPublicIp = false;
      notifyListeners();
    }
  }

  Future<void> refreshNetworkInfo() async {
    if (loadingNetwork) return;
    loadingNetwork = true;
    notifyListeners();
    try {
      networkInfo = await bridge.getNetworkInfo();
    } finally {
      loadingNetwork = false;
      notifyListeners();
    }
  }

  Future<String> requestQuickSettingsTile() =>
      bridge.requestQuickSettingsTile();
  Future<bool> requestPinAppWidget() => bridge.requestPinAppWidget();

  void clearMessage() {
    message = null;
    notifyListeners();
  }

  void _report(Object error) {
    message = _readableError(error);
    notifyListeners();
  }

  String _readableError(Object error) {
    if (error is PlatformException) {
      final detail = error.message?.trim();
      return detail != null && detail.isNotEmpty ? detail : error.code;
    }
    return error.toString().replaceFirst('Bad state: ', '');
  }

  @override
  void dispose() {
    _snapshotSubscription?.cancel();
    super.dispose();
  }
}
