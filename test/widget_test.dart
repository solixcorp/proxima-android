import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/app/proxima_app.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/core/vless_reality_profile.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/state/app_controller.dart';

void main() {
  testWidgets('renders the disconnected dashboard', (tester) async {
    final controller = AppController(_FakeBridge());
    await controller.initialize();

    await tester.pumpWidget(ProximaApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Proxima'), findsWidgets);
    expect(find.text('연결되지 않음'), findsOneWidget);
    expect(find.byKey(const Key('connect_button')), findsOneWidget);
    await tester.drag(
      find.byType(CustomScrollView).first,
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(find.text('VLESS REALITY'), findsOneWidget);
  });

  test('parses selectable proxy groups from a core response', () {
    const response =
        '{"code":0,"data":"{\\"proxies\\":{\\"GLOBAL\\":{\\"type\\":\\"Selector\\",\\"now\\":\\"Node A\\",\\"all\\":[\\"Node A\\"]},\\"PROXY\\":{\\"type\\":\\"Selector\\",\\"now\\":\\"Node A\\",\\"all\\":[\\"Node A\\"]},\\"Node A\\":{\\"type\\":\\"Vless\\"}}}"}';

    final groups = parseProxyGroups(response);

    expect(groups, hasLength(1));
    expect(groups.single.name, 'PROXY');
    expect(groups.single.selected, 'Node A');
    expect(groups.single.proxies, ['Node A']);
  });

  test('shows every proxy node in global mode', () {
    const response =
        '{"code":0,"data":"{\\"proxies\\":{\\"GLOBAL\\":{\\"type\\":\\"Selector\\",\\"now\\":\\"Node B\\",\\"all\\":[\\"Node A\\"]},\\"Node A\\":{\\"type\\":\\"Vless\\"},\\"Node B\\":{\\"type\\":\\"Vless\\"},\\"DIRECT\\":{\\"type\\":\\"Direct\\"}}}"}';

    final groups = parseProxyGroups(response, mode: OutboundMode.global);

    expect(groups.first.name, 'GLOBAL');
    expect(groups.first.selected, 'Node B');
    expect(groups.first.proxies, ['Node A', 'Node B']);
  });

  test('does not expose proxy groups in direct mode', () {
    const response =
        '{"code":0,"data":"{\\"proxies\\":{\\"PROXY\\":{\\"type\\":\\"Selector\\",\\"now\\":\\"Node A\\",\\"all\\":[\\"Node A\\"]}}}"}';

    final groups = parseProxyGroups(response, mode: OutboundMode.direct);

    expect(groups, isEmpty);
  });

  test('selects a global node before connecting', () async {
    const first =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge-a.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    const second =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge-b.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Seoul';
    final bridge = _FakeBridge()
      ..profileContent = VlessRealityProfile.profilesToMihomoYaml(
        VlessRealityProfile.parseMany('$first\n$second'),
        profileName: 'VLESS REALITY',
      );
    final controller = AppController(bridge);
    await controller.initialize();
    await controller.setMode(OutboundMode.global);

    expect(controller.globalProxyGroup?.proxies, ['Tokyo', 'Seoul']);
    await controller.selectProxy('GLOBAL', 'Seoul');

    expect(controller.globalProxyGroup?.selected, 'Seoul');
    expect(bridge.selections['GLOBAL'], 'Seoul');
  });

  test('formats traffic values', () {
    expect(formatBytes(1536, perSecond: true), '1.5 KB/s');
    expect(formatBytes(1024 * 1024), '1.0 MB');
  });

  test('calculates subscription traffic remaining and expiry', () {
    final info = SubscriptionInfo.fromMap({
      'upload': 100,
      'download': 300,
      'total': 1000,
      'expire': 1_800_000_000,
      'planName': 'Pro',
    });

    expect(info.used, 400);
    expect(info.remaining, 600);
    expect(info.planName, 'Pro');
    expect(info.expire, isNotNull);
  });

  test('decodes URL-encoded proxy names for display', () {
    expect(displayProxyName('%F0%9F%87%AF%F0%9F%87%B5%20Tokyo'), '🇯🇵 Tokyo');
  });

  test('converts a VLESS REALITY link into a mihomo profile', () {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&sid=1a2b3c4d&flow=xtls-rprx-vision&type=tcp#Tokyo';

    final profile = VlessRealityProfile.parse(link);
    final config = profile.toMihomoYaml(profileName: profile.name);

    expect(profile.name, 'Tokyo');
    expect(config, contains('type: vless'));
    expect(config, contains('servername: "cdn.example.com"'));
    expect(
      config,
      contains('public-key: "abcdefghijklmnopqrstuvwxzy0123456789ABCD"'),
    );
    expect(config, contains('find-process-mode: off'));
    expect(config, contains('MATCH,PROXY'));
    expect(VlessRealityProfile.linkFromStoredConfig(config), link);
  });

  test('decodes an encoded VLESS node name', () {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#%F0%9F%87%B0%F0%9F%87%B7%20%EC%84%9C%EC%9A%B8';

    expect(VlessRealityProfile.parse(link).name, '🇰🇷 서울');
  });

  test('converts a VLESS subscription list into multiple proxy nodes', () {
    const first =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge-a.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&sid=1a2b3c4d&type=tcp#Tokyo';
    const second =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge-b.example.com:8443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&sid=4d3c2b1a&type=tcp#Seoul';
    final encoded = base64.encode(utf8.encode('$first\n$second'));

    final profiles = VlessRealityProfile.parseMany(encoded);
    final config = VlessRealityProfile.profilesToMihomoYaml(
      profiles,
      profileName: 'Airport',
    );

    expect(profiles, hasLength(2));
    expect(config, contains('name: "Tokyo"'));
    expect(config, contains('name: "Seoul"'));
    expect(config, contains('name: GLOBAL'));
    expect(VlessRealityProfile.linksFromStoredConfig(config), [first, second]);
  });

  test('rejects non-REALITY VLESS links', () {
    expect(
      () => VlessRealityProfile.parse(
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=tls',
      ),
      throwsFormatException,
    );
  });

  test('parses active connections from a core response', () {
    const response =
        '{"code":0,"data":"{\\"uploadTotal\\":12,\\"downloadTotal\\":34,\\"memory\\":56,\\"connections\\":[{\\"id\\":\\"one\\",\\"metadata\\":{\\"host\\":\\"example.com\\",\\"destinationPort\\":443,\\"network\\":\\"tcp\\"},\\"upload\\":1,\\"download\\":2,\\"chains\\":[\\"Proxy\\"],\\"rule\\":\\"MATCH\\"}]}"}';

    final overview = parseConnections(response);

    expect(overview.connections.single.destination, 'example.com:443');
    expect(overview.connections.single.route, 'Proxy');
    expect(overview.memory, 56);
  });

  test(
    'uses the libmihomo action contracts for provider and connection',
    () async {
      final bridge = _FakeBridge();
      final controller = AppController(bridge);

      await controller.updateProvider(
        const CoreProvider(
          name: 'subscription',
          type: 'Proxy',
          vehicleType: 'HTTP',
          count: 3,
          path: '',
        ),
      );
      expect(bridge.lastMethod, 'updateExternalProvider');
      expect(jsonDecode(bridge.lastData!), {
        'type': 'Proxy',
        'name': 'subscription',
      });

      await controller.closeConnection('connection-id');
      expect(bridge.lastMethod, 'closeConnection');
      expect(bridge.lastData, 'connection-id');
    },
  );
}

class _FakeBridge implements VpnBridge {
  String? lastMethod;
  String? lastData;
  final profile = VpnProfile(
    id: '00000000-0000-0000-0000-000000000000',
    name: 'VLESS REALITY',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    isActive: true,
  );
  String profileContent = '';
  final selections = <String, String>{};

  @override
  Stream<VpnSnapshot> get snapshots => const Stream.empty();

  @override
  Future<Map<Object?, Object?>> coreInfo() async => {
    'loaded': true,
    'bridgeAbi': 3,
  };

  @override
  Future<bool> exportProfileFile({
    required String name,
    required String content,
  }) async => true;

  @override
  Future<NetworkInfo> getNetworkInfo() async => const NetworkInfo();

  @override
  Future<void> deleteProfile(String id) async {}

  @override
  Future<VpnSnapshot> getSnapshot() async =>
      const VpnSnapshot(state: VpnConnectionState.disconnected);

  @override
  Future<String> invokeCore(String method, [String data = '']) async {
    lastMethod = method;
    lastData = data;
    return '{"code":0,"data":""}';
  }

  @override
  Future<List<VpnProfile>> listProfiles() async => [profile];

  @override
  Future<VpnSettings> loadSettings() async => const VpnSettings();

  @override
  Future<Map<String, String>> loadProxySelections(String profileId) async =>
      Map.of(selections);

  @override
  Future<ImportedProfile?> pickProfileFile() async => null;

  @override
  Future<String> readProfile(String id) async => profileContent;

  @override
  Future<bool> requestVpnPermission() async => true;

  @override
  Future<bool> requestQuickSettingsTile() async => true;

  @override
  Future<VpnProfile> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
    SubscriptionInfo? subscriptionInfo,
  }) async => profile;

  @override
  Future<void> saveSettings(VpnSettings settings) async {}

  @override
  Future<void> saveProxySelection({
    required String profileId,
    required String group,
    required String proxy,
  }) async {
    selections[group] = proxy;
  }

  @override
  Future<void> selectProfile(String id) async {}

  @override
  Future<void> startVpn(String profileId) async {}

  @override
  Future<void> stopVpn() async {}

  @override
  Future<String?> validateProfile(String content) async => null;
}
