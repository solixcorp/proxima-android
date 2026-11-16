import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/native_vpn_bridge.dart';
import '../core/public_ip_probe.dart';
import '../core/proxima_user_agent.dart';
import '../core/clash_subscription.dart';
import '../core/mihomo_config_assembly.dart';
import '../core/mihomo_proxy_admission.dart';
import '../core/vless_reality_profile.dart';
import '../models/vpn_models.dart';
import 'bounded_http_body.dart';

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
  List<RoutingRule> routingRules = const [];
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
  int _publicIpGeneration = 0;
  bool loadingNetwork = false;
  bool preparingConnection = false;
  int _connectionAttempt = 0;
  bool _disposed = false;
  bool _startDispatched = false;
  bool _startingProfile = false;
  bool _configurationMutation = false;
  int _proxyLoadGeneration = 0;
  bool _proxyReloadPending = false;
  String? proxyError;
  String? message;

  bool get configurationChangeInProgress => _configurationMutation;
  bool get canStartExternalConnection =>
      !_disposed &&
      !_configurationMutation &&
      !_startingProfile &&
      !preparingConnection &&
      !snapshot.isBusy &&
      !snapshot.isConnected;

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
    final previousProfileId = activeProfile?.id;
    final becameConnected = !snapshot.isConnected && next.isConnected;
    if (!next.isConnected ||
        !snapshot.isConnected ||
        next.profileId != snapshot.profileId ||
        next.startedAt != snapshot.startedAt) {
      _publicIpGeneration++;
      loadingPublicIp = false;
      publicIp = null;
    }
    snapshot = next;
    if (activeProfile?.id != previousProfileId) _invalidateProxyData();
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
    if (snapshot.isBusy ||
        preparingConnection ||
        _startingProfile ||
        _configurationMutation) {
      return;
    }
    final attempt = ++_connectionAttempt;
    message = null;
    preparingConnection = !snapshot.isConnected;
    notifyListeners();
    try {
      if (snapshot.isConnected) {
        await bridge.stopVpn();
        return;
      }
      final profile = activeProfile;
      if (profile == null) throw StateError('먼저 프로필을 추가해 주세요.');
      if (settings.mode != OutboundMode.direct &&
          profile.sourceUrl?.trim().isNotEmpty == true) {
        await refreshProfile(profile, connectionAttempt: attempt);
      }
      if (attempt != _connectionAttempt) return;
      if (_configurationMutation) {
        throw StateError('프로필 변경이 진행 중입니다. 다시 연결해 주세요.');
      }
      final granted = await bridge.requestVpnPermission();
      if (attempt != _connectionAttempt) return;
      if (!granted) throw StateError('VPN 권한이 필요합니다.');
      if (_configurationMutation) {
        throw StateError('프로필 변경이 진행 중입니다. 다시 연결해 주세요.');
      }
      if (activeProfile?.id != profile.id) {
        throw StateError('프로필이 변경되었습니다. 다시 연결해 주세요.');
      }
      await _startProfile(profile.id, connectionAttempt: attempt);
    } catch (error) {
      if (attempt == _connectionAttempt) _report(error);
    } finally {
      if (attempt == _connectionAttempt) {
        preparingConnection = false;
        notifyListeners();
      }
    }
  }

  void cancelConnectionPreparation() {
    if (!preparingConnection) return;
    _connectionAttempt++;
    preparingConnection = false;
    if (_startDispatched) {
      unawaited(bridge.stopVpn().catchError((Object _) {}));
    }
    notifyListeners();
  }

  Future<void> reloadProfiles() async {
    final previousProfileId = activeProfile?.id;
    loadingProfiles = true;
    notifyListeners();
    try {
      profiles = await bridge.listProfiles();
      if (activeProfile?.id != previousProfileId) {
        _invalidateProxyData();
      }
    } finally {
      loadingProfiles = false;
      notifyListeners();
    }
  }

  Future<String?> validateProfile(String content) =>
      bridge.validateProfile(content);

  Future<void> _startProfile(String id, {int? connectionAttempt}) async {
    if (_startingProfile) throw StateError('VPN 연결 요청이 이미 진행 중입니다.');
    _startingProfile = true;
    var prepared = false;
    var started = false;
    try {
      final capturedSettings = settings;
      final profile = profiles.firstWhere((p) => p.id == id);
      final source = await bridge.readProfile(id);
      final selections = await bridge.loadProxySelections(id);
      final nodes = MihomoConfigAssembly.preview(
        source,
        profileName: profile.name,
      ).proxies.map((p) => p['name'] as String).toList();
      await _invalidateMissingSelections(id, nodes, selections);
      final yaml = MihomoConfigAssembly.build(
        source: source,
        profileName: profile.name,
        mode: settings.mode.wireName,
        mtu: settings.mtu,
        ipv6: settings.ipv6,
        selectedNode: selections['GLOBAL'] ?? selections['PROXY'],
      );
      final error = MihomoProxyAdmission.configurationError(
        (jsonDecode(yaml) as Map).cast<String, Object?>(),
      );
      if (error != null) throw FormatException('Mihomo 최종 재검증 실패: $error');
      bool cancelled() =>
          _disposed ||
          (connectionAttempt != null &&
              (connectionAttempt != _connectionAttempt ||
                  activeProfile?.id != id));
      if (cancelled()) return;
      if (!identical(settings, capturedSettings)) {
        throw StateError('설정이 변경되었습니다. 다시 연결해 주세요.');
      }
      await bridge.prepareMihomoConfiguration(
        id,
        yaml,
        source: source,
        settings: capturedSettings,
      );
      prepared = true;
      if (cancelled()) return;
      if (!identical(settings, capturedSettings)) {
        throw StateError('설정이 변경되었습니다. 다시 연결해 주세요.');
      }
      _startDispatched = true;
      await bridge.startVpn(id);
      started = true;
    } catch (error) {
      if (connectionAttempt == null ||
          connectionAttempt == _connectionAttempt) {
        final detail = 'Mihomo 시작 거부: ${_readableError(error)}';
        if (!snapshot.isConnected) {
          snapshot = VpnSnapshot(
            state: VpnConnectionState.error,
            profileId: id,
            error: detail,
          );
        }
        message = detail;
        notifyListeners();
      }
      rethrow;
    } finally {
      _startDispatched = false;
      _startingProfile = false;
      if (prepared && !started) {
        await bridge.discardPreparedMihomoConfiguration(id);
      }
    }
  }

  Future<void> _invalidateMissingSelections(
    String id,
    List<String> nodes,
    Map<String, String> selections,
  ) async {
    var invalidated = false;
    for (final group in selections.keys.toList()) {
      if (!nodes.contains(selections[group])) {
        await bridge.clearProxySelection(id, group);
        selections.remove(group);
        invalidated = true;
      }
    }
    if (invalidated) {
      proxyGroups = const [];
      message = '선택한 노드가 구독에서 사라졌습니다. 첫 노드로 연결하며 다음 동기화에서 다시 선택해 주세요.';
      notifyListeners();
    }
  }

  Future<void> _saveMihomoProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
    SubscriptionInfo? subscriptionInfo,
    int? connectionAttempt,
  }) async {
    final existingLegacy = VlessRealityProfile.linksFromStoredConfig(content)
        .isNotEmpty;
    var stored = content;
    // Keep old comment-based single-link storage, but never convert a YAML
    // subscription or rewrite a pre-existing legacy profile/routing document.
    if (!existingLegacy &&
        ClashSubscriptionParser.admit(content) == null &&
        sourceUrl?.isNotEmpty != true) {
      try {
        if (VlessRealityProfile.parseMany(content).length == 1) {
          stored = VlessRealityProfile.storedConfigFromInput(
            content,
            profileName: name.trim().isEmpty ? 'VLESS' : name.trim(),
          );
        }
      } on FormatException {
        // Generic non-VLESS share links retain their source representation.
      }
    }
    final preview = MihomoConfigAssembly.preview(stored, profileName: name);
    if (preview.proxies.isEmpty) {
      throw const FormatException('가져올 수 있는 프록시가 없습니다. 지원하지 않는 항목만 포함되어 있습니다.');
    }
    final summary = ProfileAdmissionSummary(
      validProxyCount: preview.proxies.length,
      skipped: preview.skipped
          .map((row) => {'type': row.type, 'reason': row.reason})
          .toList(),
    );
    if (connectionAttempt != null &&
        (connectionAttempt != _connectionAttempt || id != activeProfile?.id)) {
      return;
    }
    var effectiveName = name.trim();
    if (effectiveName.isEmpty ||
        VlessRealityProfile.isAutomaticProfileName(effectiveName)) {
      final host = Uri.tryParse(sourceUrl ?? '')?.host;
      effectiveName = host?.isNotEmpty == true ? host! : 'Mihomo';
    }
    final previousProfile = id == null
        ? null
        : profiles.where((profile) => profile.id == id).firstOrNull;
    final previousContent =
        previousProfile != null &&
            snapshot.isConnected &&
            snapshot.profileId == id
        ? await bridge.readProfile(id!)
        : null;
    final previousSelections = previousContent == null
        ? null
        : Map<String, String>.from(await bridge.loadProxySelections(id!));
    final saved = await bridge.saveProfile(
      id: id,
      name: effectiveName,
      sourceUrl: sourceUrl?.trim(),
      content: stored,
      subscriptionInfo: subscriptionInfo,
      admissionSummary: summary,
    );
    try {
      final selections = await bridge.loadProxySelections(saved.id);
      final nodes = MihomoConfigAssembly.preview(
        stored,
        profileName: effectiveName,
      ).proxies.map((p) => p['name'] as String).toList();
      await _invalidateMissingSelections(saved.id, nodes, selections);
      final selectionNotice = message;
      await reloadProfiles();
      if (!snapshot.isConnected && settings.mode != OutboundMode.direct) {
        await loadProxyGroups();
      }
      message =
          '${summary.description}${selectionNotice?.startsWith('선택한 노드가') == true ? '\n$selectionNotice' : ''}';
      notifyListeners();
      if (snapshot.isConnected && snapshot.profileId == saved.id) {
        await _startProfile(saved.id);
      }
    } catch (_) {
      if (previousProfile != null && previousContent != null) {
        await bridge.saveProfile(
          id: previousProfile.id,
          name: previousProfile.name,
          sourceUrl: previousProfile.sourceUrl,
          content: previousContent,
          subscriptionInfo: previousProfile.subscriptionInfo,
          admissionSummary: previousProfile.admissionSummary,
        );
        for (final entry in previousSelections!.entries) {
          await bridge.saveProxySelection(
            profileId: previousProfile.id,
            group: entry.key,
            proxy: entry.value,
          );
        }
        await reloadProfiles();
      }
      rethrow;
    }
  }

  Future<void> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
    SubscriptionInfo? subscriptionInfo,
    int? connectionAttempt,
  }) => _configurationChange(
    () async {
      if (snapshot.isBusy || _startingProfile) {
        throw StateError('연결 상태가 바뀐 뒤 프로필을 저장해 주세요.');
      }
      return _saveMihomoProfile(
        id: id,
        name: name,
        sourceUrl: sourceUrl,
        content: content,
        subscriptionInfo: subscriptionInfo,
        connectionAttempt: connectionAttempt,
      );
    },
    allowPreparation:
        connectionAttempt != null && connectionAttempt == _connectionAttempt,
  );

  Future<void> selectProfile(String id) => _configurationChange(() async {
    if (snapshot.isBusy || _startingProfile) {
      throw StateError('연결 상태가 바뀐 뒤 프로필을 변경해 주세요.');
    }
    if (snapshot.isConnected && snapshot.profileId != id) {
      final previousId = activeProfile?.id;
      try {
        if (!profiles.any((profile) => profile.id == id)) {
          await reloadProfiles();
        }
        await _startProfile(id);
      } catch (_) {
        if (previousId != null) await bridge.selectProfile(previousId);
        await reloadProfiles();
        rethrow;
      }
      await reloadProfiles();
      return;
    }
    await bridge.selectProfile(id);
    await reloadProfiles();
    if (!snapshot.isConnected && settings.mode != OutboundMode.direct) {
      await loadProxyGroups();
    }
  }, allowPreparation: true);

  Future<void> deleteProfile(String id) => _configurationChange(() async {
    if (snapshot.isBusy || _startingProfile) {
      throw StateError('연결 상태가 바뀐 뒤 프로필을 삭제해 주세요.');
    }
    await bridge.deleteProfile(id);
    await reloadProfiles();
    if (!snapshot.isConnected && settings.mode != OutboundMode.direct) {
      await loadProxyGroups();
    }
  });

  Future<ImportedProfile?> pickProfileFile() => bridge.pickProfileFile();

  Future<bool> exportProfile(VpnProfile profile) async {
    final content = await readProfileLink(profile);
    return bridge.exportProfileFile(
      name: '${_safeFileName(profile.name)}.txt',
      content: content,
    );
  }

  Future<String> readProfileLink(VpnProfile profile) =>
      bridge.readProfile(profile.id);

  String _safeFileName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^a-zA-Z0-9._\-가-힣 ]'), '_');
    return cleaned.trim().isEmpty ? 'profile' : cleaned.trim();
  }

  Future<String> fetchSubscription(String source) async =>
      (await fetchSubscriptionDetails(source)).content;

  Future<void> _traceRejectedResponse(
    HttpClientResponse response, {
    required String stage,
    required String host,
  }) async {
    if (!kDebugMode) {
      cancelHttpBody(response);
      return;
    }
    try {
      final bytes = await readBoundedHttpBody(
        response,
        maxBytes: 4096,
        idleTimeout: const Duration(seconds: 3),
        totalTimeout: const Duration(seconds: 3),
      );
      final body = jsonDecode(utf8.decode(bytes));
      final reason = body is Map ? body['error'] : null;
      // Never print arbitrary response text: it may contain subscription tokens.
      const safeReasons = {
        'subscription inactive',
        'plan expired',
        'traffic limit exceeded',
        'subscription not found',
        'failed to resolve subscription',
        'failed to fetch subscription',
        'no servers are ready for this subscription yet; retry shortly',
      };
      debugPrint(
        '[subscription-import] stage=$stage host=$host '
        'serverReason=${safeReasons.contains(reason) ? reason : 'unrecognized-or-redacted'}',
      );
    } catch (error) {
      debugPrint(
        '[subscription-import] stage=$stage host=$host '
        'responseDiagnostic=${error.runtimeType} body=redacted',
      );
    }
  }

  Future<List<int>> fetchRuleSet(Uri source) async {
    if (source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      throw const FormatException('규칙셋에는 HTTPS 주소가 필요합니다.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      var current = source;
      for (var redirects = 0; ; redirects++) {
        if (kDebugMode) {
          debugPrint(
            '[subscription-import] stage=rule-set host=${current.host} request=GET',
          );
        }
        final request = await client.getUrl(current);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (kDebugMode) {
          debugPrint(
            '[subscription-import] stage=rule-set host=${current.host} '
            'status=${response.statusCode} redirect=${response.isRedirect}',
          );
        }
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          cancelHttpBody(response);
          if (location == null || redirects >= 5) {
            throw const HttpException('규칙셋 주소의 리디렉션이 너무 많습니다.');
          }
          final next = current.resolve(location);
          if (next.scheme != 'https' ||
              next.host.isEmpty ||
              next.userInfo.isNotEmpty) {
            throw const FormatException('안전하지 않은 규칙셋 주소로 이동할 수 없습니다.');
          }
          current = next;
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final status = response.statusCode;
          await _traceRejectedResponse(
            response,
            stage: 'rule-set',
            host: current.host,
          );
          throw HttpException('규칙셋 서버 응답 $status');
        }
        return await readBoundedHttpBody(
          response,
          sizeError: '규칙셋은 8MB보다 작아야 합니다.',
        );
      }
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint(
          '[subscription-import] stage=rule-set host=${source.host} '
          'failure=${error.runtimeType}',
        );
        debugPrintStack(stackTrace: stack);
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> importAccountSubscription(
    String source, {
    String? planName,
  }) async {
    if (snapshot.isBusy) {
      throw StateError('연결 상태가 바뀐 뒤 구독을 가져와 주세요.');
    }
    final subscription = await fetchSubscriptionDetails(source);
    VpnProfile? existing;
    for (final profile in profiles) {
      if (profile.sourceUrl == source) {
        existing = profile;
        break;
      }
    }
    final info = subscription.info ?? existing?.subscriptionInfo;
    final accountPlanName = planName?.trim();
    await saveProfile(
      id: existing?.id,
      name: existing?.name ?? 'Proxima',
      sourceUrl: source,
      content: subscription.content,
      subscriptionInfo: accountPlanName?.isNotEmpty == true
          ? SubscriptionInfo(
              upload: info?.upload ?? 0,
              download: info?.download ?? 0,
              total: info?.total ?? 0,
              expire: info?.expire,
              planName: accountPlanName,
            )
          : info,
    );
    final imported = profiles.firstWhere(
      (profile) => profile.sourceUrl == source,
    );
    await selectProfile(imported.id);
  }

  Future<QrProfileResult> resolveQrPayload(
    String value, {
    Future<SubscriptionFetchResult> Function(String source)?
    subscriptionFetcher,
  }) async {
    final payload = value.trim();
    String? admittedContent(String input) {
      final candidate = input.trim();
      final uri = Uri.tryParse(candidate);
      // HTTPS URLs are subscription endpoints, not local proxy content.
      if (uri?.scheme.toLowerCase() == 'https' && uri!.host.isNotEmpty) {
        return null;
      }
      var decoded = candidate;
      if (!candidate.contains('://')) {
        try {
          final compact = candidate.replaceAll(RegExp(r'\s'), '');
          decoded = utf8.decode(base64Url.decode(base64Url.normalize(compact)));
        } on FormatException {
          // It may instead be YAML or invalid input.
        }
      }
      final preview = MihomoConfigAssembly.preview(decoded);
      if (preview.proxies.isEmpty) return null;
      if (decoded.trimLeft().toLowerCase().startsWith('vless://')) {
        try {
          final normalized = VlessRealityProfile.normalizeLinkInput(candidate);
          if (MihomoConfigAssembly.preview(normalized).proxies.length ==
              preview.proxies.length) {
            return normalized;
          }
        } on FormatException {
          // Other admitted formats remain intact.
        }
      }
      return decoded;
    }

    final direct = admittedContent(payload);
    if (direct != null) return QrProfileResult(content: direct);

    final uri = Uri.tryParse(payload);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('이 QR 코드에서 지원하는 프로필을 찾지 못했습니다.');
    }

    // Preserve the existing behavior for landing URLs that embed the actual
    // profile payload in a query parameter or fragment.
    for (final candidate in [...uri.queryParameters.values, uri.fragment]) {
      if (candidate.isEmpty) continue;
      final content = admittedContent(candidate);
      if (content != null) return QrProfileResult(content: content);
    }

    final subscription =
        await (subscriptionFetcher ?? fetchSubscriptionDetails)(payload);
    final hasNodes = MihomoConfigAssembly.preview(subscription.content)
        .proxies
        .isNotEmpty;
    if (!hasNodes) {
      throw const FormatException('구독에서 지원하는 노드를 찾지 못했습니다.');
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
      final userAgent = await proximaUserAgent();
      if (kDebugMode) {
        debugPrint(
          '[subscription-import] stage=subscription host=${uri.host} '
          'userAgent=$userAgent',
        );
      }
      return await fetchPreferredSubscription(
        (_) => _fetchSubscriptionWithUserAgent(client, uri, userAgent),
        userAgent: userAgent,
        mihomo: true,
      );
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint(
          '[subscription-import] stage=subscription host=${uri.host} '
          'failure=${error.runtimeType}',
        );
        debugPrintStack(stackTrace: stack);
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static Future<SubscriptionFetchResult> fetchPreferredSubscription(
    Future<SubscriptionFetchResult> Function(String userAgent) fetch, {
    String? userAgent,
    bool mihomo = false,
  }) async {
    SubscriptionFetchResult? fallback;
    Object? firstRequestError;
    StackTrace? firstRequestStack;
    var receivedResponse = false;
    final userAgents = userAgent == null
        ? const ['clash.meta', 'ClashForAndroid', 'v2rayN/6.45 Proxima/1.0']
        : [userAgent];
    for (final userAgent in userAgents) {
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
        if (mihomo
            ? MihomoConfigAssembly.preview(result.content).proxies.isNotEmpty
            : ClashSubscriptionParser.tryParse(result.content) != null) {
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
      if (kDebugMode) {
        debugPrint(
          '[subscription-import] stage=subscription host=${current.host} '
          'status=${response.statusCode} redirect=${response.isRedirect}',
        );
      }
      if (!response.isRedirect) break;
      final location = response.headers.value(HttpHeaders.locationHeader);
      cancelHttpBody(response);
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
      await _traceRejectedResponse(
        response,
        stage: 'subscription',
        host: current.host,
      );
      if (statusCode == HttpStatus.forbidden) {
        throw const HttpException(
          '구독 서버가 접근을 거부했습니다(403). 구독 주소나 계정 상태를 확인해 주세요.',
        );
      }
      throw HttpException('서버 응답 $statusCode');
    }
    final info = _subscriptionInfo(response.headers);
    final chunks = await readBoundedHttpBody(
      response,
      sizeError: '프로필은 8MB보다 작아야 합니다.',
    );
    return SubscriptionFetchResult(content: utf8.decode(chunks), info: info);
  }

  Future<void> refreshProfile(
    VpnProfile profile, {
    int? connectionAttempt,
  }) async {
    final source = profile.sourceUrl;
    if (source == null || source.isEmpty) return;
    final subscription = await fetchSubscriptionDetails(source);
    if (connectionAttempt != null &&
        (connectionAttempt != _connectionAttempt ||
            profile.id != activeProfile?.id)) {
      return;
    }
    // Preserve the subscription source for Mihomo assembly.
    final content = subscription.content;
    await saveProfile(
      id: profile.id,
      name: profile.name,
      sourceUrl: source,
      content: content,
      connectionAttempt: connectionAttempt,
      // Some providers omit usage headers on otherwise valid refreshes. Keep
      // the last known quota instead of replacing it with an empty value.
      subscriptionInfo: subscription.info ?? profile.subscriptionInfo,
    );
  }

  Future<void> _configurationChange(
    Future<void> Function() action, {
    bool allowPreparation = false,
  }) async {
    if (_disposed ||
        _configurationMutation ||
        _startingProfile ||
        (preparingConnection && !allowPreparation)) {
      throw StateError('다른 연결 또는 설정 작업이 진행 중입니다.');
    }
    _configurationMutation = true;
    try {
      await action();
    } finally {
      _configurationMutation = false;
      notifyListeners();
    }
  }

  Future<void> updateSettings(VpnSettings next) =>
      _configurationChange(() => _updateSettings(next));

  Future<void> _updateSettings(VpnSettings next) async {
    if (_startingProfile) throw StateError('연결 상태가 바뀐 뒤 설정을 변경해 주세요.');
    await bridge.saveSettings(next);
    settings = next;
    notifyListeners();
  }

  Future<void> setMode(OutboundMode mode) => _configurationChange(() async {
    if (snapshot.isBusy || _startingProfile) {
      throw StateError('연결 상태가 바뀐 뒤 모드를 변경해 주세요.');
    }
    if (mode == settings.mode) return;
    final previous = settings;
    await _updateSettings(settings.copyWith(mode: mode));
    if (!snapshot.isConnected) {
      await loadProxyGroups();
      return;
    }
    try {
      final profile = activeProfile;
      if (profile == null) throw StateError('먼저 프로필을 추가해 주세요.');
      await _startProfile(profile.id);
    } catch (_) {
      settings = previous;
      await bridge.saveSettings(previous);
      proxyGroups = await _offlineProxyGroups();
      notifyListeners();
      rethrow;
    }
  });

  Future<Map<String, VlessRealityProfile>> readNodeDetails() async {
    final profile = activeProfile;
    if (profile == null) return const {};
    final content = await bridge.readProfile(profile.id);
    final names = VlessRealityProfile.nodeNamesFromStoredConfig(
      content,
      profileName: profile.name,
    );
    final links = VlessRealityProfile.linksFromStoredConfig(content);
    return {
      for (var i = 0; i < names.length; i++)
        names[i]: VlessRealityProfile.parse(links[i]),
    };
  }

  Future<void> loadProxyGroups() async {
    final generation = ++_proxyLoadGeneration;
    if (loadingProxies) {
      _proxyReloadPending = true;
      return;
    }
    final profile = activeProfile;
    bool isCurrent() =>
        generation == _proxyLoadGeneration && activeProfile?.id == profile?.id;
    loadingProxies = true;
    notifyListeners();
    try {
      final content = profile == null
          ? ''
          : await bridge.readProfile(profile.id);
      if (!isCurrent()) return;
      final List<RoutingRule> rules = profile == null
          ? const []
          : _profileRoutingRules(content);
      final List<ProxyGroup> groups;
      if (snapshot.isConnected) {
        groups = parseProxyGroups(
          await bridge.invokeCore('getProxies'),
          mode: settings.mode,
        );
      } else {
        groups = await _offlineProxyGroups();
      }
      if (!isCurrent()) return;
      routingRules = rules;
      proxyGroups = groups;
      _clearProxyMessage();
      proxyError = null;
    } catch (error) {
      if (isCurrent()) {
        proxyError = '노드 목록을 불러오지 못했습니다: $error';
        message = proxyError;
      }
    } finally {
      loadingProxies = false;
      notifyListeners();
      if (_proxyReloadPending) {
        _proxyReloadPending = false;
        unawaited(loadProxyGroups());
      }
    }
  }

  List<RoutingRule> _profileRoutingRules(String content) {
    if (VlessRealityProfile.linksFromStoredConfig(content).isNotEmpty) {
      return VlessRealityProfile.routingRulesFromStoredConfig(content);
    }
    return MihomoConfigAssembly.preview(content).rules
        .map((raw) {
          final parts = raw.split(',');
          final match = parts.first.toUpperCase() == 'MATCH';
          return RoutingRule.fromMap({
            'raw': raw,
            'match': match,
            'policy': match ? parts[1] : parts[2],
          });
        })
        .toList(growable: false);
  }

  Future<void> selectProxy(String group, String proxy) => _configurationChange(
    () async {
      if (settings.mode != OutboundMode.global || group != 'GLOBAL') {
        throw StateError('노드는 전역 모드에서만 직접 선택할 수 있습니다.');
      }
      if (snapshot.isBusy || _startingProfile) {
        throw StateError('연결 상태가 바뀐 뒤 노드를 변경해 주세요.');
      }
      if (snapshot.isConnected) {
        final profile = activeProfile;
        if (profile == null ||
            currentProxyGroup?.proxies.contains(proxy) != true) {
          throw StateError('선택할 수 없는 노드입니다.');
        }
        final oldSelection = currentProxyGroup?.selected;
        final savedSelections = await bridge.loadProxySelections(profile.id);
        var changed = false;
        try {
          ensureCoreSuccess(
            await bridge.invokeCore(
              'changeProxy',
              jsonEncode({'group-name': group, 'proxy-name': proxy}),
            ),
          );
          changed = true;
        } catch (_) {
          // The existing reassembly and restart remains the second method.
        }
        try {
          await bridge.saveProxySelection(
            profileId: profile.id,
            group: group,
            proxy: proxy,
          );
        } catch (_) {
          if (changed && oldSelection != null) {
            try {
              ensureCoreSuccess(
                await bridge.invokeCore(
                  'changeProxy',
                  jsonEncode({'group-name': group, 'proxy-name': oldSelection}),
                ),
              );
            } catch (_) {
              await loadProxyGroups();
            }
          }
          rethrow;
        }
        if (changed) {
          _setProxySelection(group, proxy);
          _clearProxyMessage();
          notifyListeners();
        } else {
          try {
            await _startProfile(profile.id);
          } catch (_) {
            final oldSaved = savedSelections[group];
            if (oldSaved == null) {
              await bridge.clearProxySelection(profile.id, group);
            } else {
              await bridge.saveProxySelection(
                profileId: profile.id,
                group: group,
                proxy: oldSaved,
              );
            }
            rethrow;
          }
        }
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
    },
  );

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

  void _invalidateProxyData() {
    _proxyLoadGeneration++;
    routingRules = const [];
    proxyGroups = const [];
    proxyError = null;
    _clearProxyMessage();
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
    final nodes = MihomoConfigAssembly.preview(
      content,
      profileName: profile.name,
    ).proxies.map((p) => p['name'] as String).toList();
    if (nodes.isEmpty) return const [];
    final selections = await bridge.loadProxySelections(profile.id);
    await _invalidateMissingSelections(profile.id, nodes, selections);
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
    final generation = ++_publicIpGeneration;
    final profileId = snapshot.profileId;
    final startedAt = snapshot.startedAt;
    bool isCurrent() =>
        !_disposed &&
        generation == _publicIpGeneration &&
        snapshot.isConnected &&
        snapshot.profileId == profileId &&
        snapshot.startedAt == startedAt;
    loadingPublicIp = true;
    notifyListeners();
    try {
      final result = await probeCurrentPublicIp();
      if (isCurrent()) publicIp = result;
    } catch (error) {
      if (isCurrent()) {
        message = '외부 IP를 확인하지 못했습니다: ${_readableError(error)}';
      }
    } finally {
      if (isCurrent()) {
        loadingPublicIp = false;
        notifyListeners();
      }
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
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionAttempt++;
    _snapshotSubscription?.cancel();
    super.dispose();
  }
}
