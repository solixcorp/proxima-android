import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/native_vpn_bridge.dart';
import '../core/vless_reality_profile.dart';
import '../models/vpn_models.dart';

class AppController extends ChangeNotifier {
  AppController(this.bridge);

  final VpnBridge bridge;
  StreamSubscription<VpnSnapshot>? _snapshotSubscription;
  Timer? _connectionTimer;

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
  String? message;

  VpnProfile? get activeProfile {
    for (final profile in profiles) {
      if (profile.isActive) return profile;
    }
    return profiles.isEmpty ? null : profiles.first;
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
      if (snapshot.isConnected) _beginConnectedRefresh();
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
    } else if (!next.isConnected) {
      _connectionTimer?.cancel();
      _connectionTimer = null;
      proxyGroups = const [];
      connectionOverview = const ConnectionOverview();
      providers = const [];
      publicIp = null;
    }
    notifyListeners();
  }

  void _beginConnectedRefresh() {
    _connectionTimer?.cancel();
    unawaited(loadProxyGroups());
    unawaited(loadConnections());
    unawaited(loadProviders());
    _connectionTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(loadConnections(silent: true)),
    );
  }

  Future<void> toggleVpn() async {
    if (snapshot.isBusy) return;
    message = null;
    try {
      if (snapshot.isConnected || snapshot.state == VpnConnectionState.error) {
        await bridge.stopVpn();
        return;
      }
      final profile = activeProfile;
      if (profile == null) throw StateError('먼저 프로필을 추가해 주세요.');
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

  Future<String?> validateProfile(String content) => bridge.validateProfile(content);

  Future<void> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
  }) async {
    final parsed = VlessRealityProfile.parse(content);
    final effectiveName = name.trim().isEmpty ? parsed.name : name.trim();
    final generatedConfig = parsed.toMihomoYaml(profileName: effectiveName);
    final validationError = await validateProfile(generatedConfig);
    if (validationError != null && validationError.isNotEmpty) {
      throw FormatException(validationError);
    }
    final saved = await bridge.saveProfile(
      id: id,
      name: effectiveName,
      sourceUrl: sourceUrl?.trim(),
      content: generatedConfig,
    );
    await reloadProfiles();
    if (snapshot.isConnected && snapshot.profileId == saved.id) {
      await bridge.startVpn(saved.id);
    }
  }

  Future<void> selectProfile(String id) async {
    await bridge.selectProfile(id);
    await reloadProfiles();
    if (snapshot.isConnected && snapshot.profileId != id) {
      await bridge.startVpn(id);
    }
  }

  Future<void> deleteProfile(String id) async {
    await bridge.deleteProfile(id);
    await reloadProfiles();
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
    return VlessRealityProfile.linkFromStoredConfig(config) ??
        (throw const FormatException(
          '이전 Mihomo YAML 프로필입니다. VLESS + REALITY 링크로 새 프로필을 추가해 주세요.',
        ));
  }

  String _safeFileName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^a-zA-Z0-9._\-가-힣 ]'), '_');
    return cleaned.trim().isEmpty ? 'profile' : cleaned.trim();
  }

  Future<String> fetchSubscription(String source) async {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('HTTPS 구독 주소를 입력해 주세요.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      var current = uri;
      late HttpClientResponse response;
      for (var redirects = 0; ; redirects++) {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'Proxima/1.0 Mihomo');
        response = await request.close().timeout(const Duration(seconds: 20));
        if (!response.isRedirect) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || redirects >= 5) {
          throw HttpException('구독 주소의 리디렉션이 너무 많습니다.', uri: current);
        }
        final redirected = current.resolve(location);
        if (redirected.scheme != 'https' || redirected.host.isEmpty) {
          throw const FormatException('HTTPS가 아닌 주소로 이동할 수 없습니다.');
        }
        current = redirected;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('서버 응답 ${response.statusCode}', uri: current);
      }
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
        if (chunks.length > 8 * 1024 * 1024) {
          throw const FormatException('프로필은 8MB보다 작아야 합니다.');
        }
      }
      return utf8.decode(chunks);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> refreshProfile(VpnProfile profile) async {
    final source = profile.sourceUrl;
    if (source == null || source.isEmpty) return;
    final content = VlessRealityProfile.linkFromSubscription(
      await fetchSubscription(source),
    );
    await saveProfile(
      id: profile.id,
      name: profile.name,
      sourceUrl: source,
      content: content,
    );
  }

  Future<void> updateSettings(VpnSettings next) async {
    settings = next;
    notifyListeners();
    await bridge.saveSettings(next);
  }

  Future<void> setMode(OutboundMode mode) async {
    final previous = settings;
    await updateSettings(settings.copyWith(mode: mode));
    if (!snapshot.isConnected) return;
    try {
      ensureCoreSuccess(
        await bridge.invokeCore(
          'updateConfig',
          jsonEncode({'mode': mode.wireName}),
        ),
      );
    } catch (_) {
      settings = previous;
      await bridge.saveSettings(previous);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> loadProxyGroups() async {
    if (!snapshot.isConnected || loadingProxies) return;
    loadingProxies = true;
    notifyListeners();
    try {
      proxyGroups = parseProxyGroups(await bridge.invokeCore('getProxies'));
    } catch (error) {
      message = '노드 목록을 불러오지 못했습니다: $error';
    } finally {
      loadingProxies = false;
      notifyListeners();
    }
  }

  Future<void> selectProxy(String group, String proxy) async {
    ensureCoreSuccess(
      await bridge.invokeCore(
        'changeProxy',
        jsonEncode({'group-name': group, 'proxy-name': proxy}),
      ),
    );
    await loadProxyGroups();
  }

  Future<int?> testDelay(String proxy) async {
    final result = await bridge.invokeCore(
      'testDelay',
      jsonEncode({
        'proxy-name': proxy,
        'test-url': 'https://www.gstatic.com/generate_204',
        'timeout': 5000,
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
      message = '외부 IP를 확인하지 못했습니다: $error';
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

  Future<bool> requestQuickSettingsTile() => bridge.requestQuickSettingsTile();

  void clearMessage() {
    message = null;
    notifyListeners();
  }

  void _report(Object error) {
    message = error.toString().replaceFirst('Bad state: ', '');
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    _snapshotSubscription?.cancel();
    super.dispose();
  }
}
