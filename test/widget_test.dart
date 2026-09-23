import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/app/proxima_app.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/core/vless_reality_profile.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/screens/home_screen.dart';
import 'package:proxima/screens/profiles_screen.dart';
import 'package:proxima/screens/proxies_screen.dart';
import 'package:proxima/screens/subscription_screen.dart';
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

  test('does not allow selecting a node in rule mode', () async {
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

    expect(controller.currentProxyGroup, isNull);
    await expectLater(
      controller.selectProxy('PROXY', 'Seoul'),
      throwsStateError,
    );
    expect(bridge.selections, isEmpty);
  });

  test(
    'changes a connected node optimistically without an immediate reload',
    () async {
      final bridge = _FakeBridge();
      final controller = AppController(bridge)
        ..snapshot = const VpnSnapshot(state: VpnConnectionState.connected)
        ..settings = const VpnSettings(mode: OutboundMode.global)
        ..proxyGroups = const [
          ProxyGroup(
            name: 'GLOBAL',
            type: 'Selector',
            selected: 'Tokyo',
            proxies: ['Tokyo', 'Seoul'],
          ),
        ]
        ..message = '노드 목록을 불러오지 못했습니다: restarting';

      await controller.selectProxy('GLOBAL', 'Seoul');

      expect(controller.currentProxyGroup?.selected, 'Seoul');
      expect(bridge.invokedMethods, ['changeProxy']);
      expect(controller.message, isNull);
    },
  );

  test('rejects mode and node mutations while Xray is restarting', () async {
    final controller = AppController(_FakeBridge())
      ..snapshot = const VpnSnapshot(state: VpnConnectionState.connecting)
      ..settings = const VpnSettings(mode: OutboundMode.rule)
      ..proxyGroups = const [
        ProxyGroup(
          name: 'PROXY',
          type: 'Selector',
          selected: 'Tokyo',
          proxies: ['Tokyo', 'Seoul'],
        ),
      ];

    await expectLater(
      controller.setMode(OutboundMode.global),
      throwsStateError,
    );
    await expectLater(
      controller.selectProxy('PROXY', 'Seoul'),
      throwsStateError,
    );
    expect(controller.settings.mode, OutboundMode.rule);
    expect(controller.currentProxyGroup, isNull);
  });

  testWidgets('node route rebuilds when the selected node changes', (
    tester,
  ) async {
    final bridge = _FakeBridge();
    final controller = AppController(bridge)
      ..profiles = [bridge.profile]
      ..settings = const VpnSettings(mode: OutboundMode.global)
      ..proxyGroups = const [
        ProxyGroup(
          name: 'GLOBAL',
          type: 'Selector',
          selected: 'Tokyo',
          proxies: ['Tokyo', 'Seoul'],
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(home: ProxiesScreen(controller: controller)),
    );
    expect(find.text('Tokyo'), findsOneWidget);

    await controller.selectProxy('GLOBAL', 'Seoul');
    await tester.pump();

    expect(find.text('Seoul'), findsOneWidget);
    expect(find.text('Tokyo'), findsNothing);
  });

  testWidgets('home hides node selection in rule mode', (tester) async {
    final controller = AppController(_FakeBridge())
      ..settings = const VpnSettings(mode: OutboundMode.rule)
      ..proxyGroups = const [
        ProxyGroup(
          name: 'PROXY',
          type: 'Selector',
          selected: 'Seoul',
          proxies: ['Tokyo', 'Seoul'],
        ),
        ProxyGroup(
          name: 'GLOBAL',
          type: 'Selector',
          selected: 'Tokyo',
          proxies: ['Tokyo', 'Seoul'],
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          controller: controller,
          openProfiles: () {},
          openProxies: () {},
          openConnections: () {},
        ),
      ),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -650));
    await tester.pumpAndSettle();

    expect(find.text('규칙에 따라 자동 선택'), findsOneWidget);
    expect(find.byKey(const Key('selected_node_tile')), findsNothing);
  });

  test('formats traffic values', () {
    expect(formatBytes(1536, perSecond: true), '1.5 KB/s');
    expect(formatBytes(1024 * 1024), '1.0 MB');
  });

  test('formats Xray version payloads', () {
    expect(formatCoreVersion('{"version":"*26.9.9"}'), '26.9.9');
    expect(formatCoreVersion({'version': '*26.9.9'}), '26.9.9');
    expect(formatCoreVersion('v26.9.9'), '26.9.9');
    expect(formatCoreVersion(null), 'unknown');
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

  test('recognizes a legacy subscription from preserved quota metadata', () {
    final profile = VpnProfile(
      id: 'legacy-subscription',
      name: 'Legacy subscription',
      subscriptionInfo: SubscriptionInfo(total: 1024),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      isActive: true,
    );

    expect(profile.isSubscription, isTrue);
    expect(profile.sourceLabel, '구독 프로필');
  });

  test('uses the runtime profile while the VPN is connected', () {
    final controller = AppController(_FakeBridge())
      ..profiles = [
        VpnProfile(
          id: '11111111-1111-4111-8111-111111111111',
          name: 'Previously active',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: true,
        ),
        VpnProfile(
          id: '22222222-2222-4222-8222-222222222222',
          name: 'Connected subscription',
          sourceUrl: 'https://example.com/subscription',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: false,
        ),
      ]
      ..snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: '22222222-2222-4222-8222-222222222222',
      );

    expect(controller.activeProfile?.name, 'Connected subscription');
  });

  test('an error can retry with the newly selected profile', () async {
    final bridge = _FakeBridge();
    final controller = AppController(bridge)
      ..profiles = [
        VpnProfile(
          id: 'failed',
          name: 'Failed profile',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: false,
        ),
        VpnProfile(
          id: 'selected',
          name: 'Selected profile',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: true,
        ),
      ]
      ..snapshot = const VpnSnapshot(
        state: VpnConnectionState.error,
        profileId: 'failed',
        error: 'failed',
      );

    expect(controller.activeProfile?.id, 'selected');
    await controller.toggleVpn();

    expect(bridge.startedProfileId, 'selected');
    expect(bridge.stopCount, 0);
  });

  testWidgets('keeps subscription identity visible without quota headers', (
    tester,
  ) async {
    final controller = AppController(_FakeBridge())
      ..profiles = [
        VpnProfile(
          id: '22222222-2222-4222-8222-222222222222',
          name: 'Connected subscription',
          sourceUrl: 'https://example.com/subscription',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: true,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(home: SubscriptionScreen(controller: controller)),
    );

    expect(find.text('Connected subscription'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('구독 정보가 없습니다'), findsOneWidget);
  });

  testWidgets('shows runtime status and a local profile on subscription tab', (
    tester,
  ) async {
    final controller = AppController(_FakeBridge())
      ..profiles = [
        VpnProfile(
          id: 'local-profile',
          name: 'Local Reality',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: true,
        ),
      ]
      ..snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: 'local-profile',
      )
      ..settings = const VpnSettings(mode: OutboundMode.rule)
      ..proxyGroups = const [
        ProxyGroup(
          name: 'PROXY',
          type: 'Selector',
          selected: 'Seoul',
          proxies: ['Seoul'],
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(home: SubscriptionScreen(controller: controller)),
    );

    expect(find.byKey(const Key('subscription_status_card')), findsOneWidget);
    expect(find.text('VPN으로 보호됨'), findsOneWidget);
    expect(find.text('규칙'), findsOneWidget);
    expect(find.text('규칙에 따라 자동 선택'), findsOneWidget);
    expect(find.text('Local Reality'), findsOneWidget);
    expect(find.text('로컬 프로필'), findsOneWidget);
  });

  testWidgets('profile in-use state follows the runtime profile id', (
    tester,
  ) async {
    final controller = AppController(_FakeBridge())
      ..profiles = [
        VpnProfile(
          id: 'previous',
          name: 'Previously selected',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: true,
        ),
        VpnProfile(
          id: 'runtime',
          name: 'Actually connected',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          isActive: false,
        ),
      ]
      ..snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: 'runtime',
      );

    await tester.pumpWidget(
      MaterialApp(home: ProfilesScreen(controller: controller)),
    );

    expect(find.text('사용 중 · 로컬 프로필'), findsOneWidget);
    expect(find.text('선택됨 · 로컬 프로필'), findsNothing);
  });

  test('keeps a direct VLESS QR payload as a local profile', () async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    final result = await AppController(_FakeBridge()).resolveQrPayload(
      link,
      subscriptionFetcher: (_) => throw StateError('must not fetch'),
    );

    expect(result.content, link);
    expect(result.sourceUrl, isNull);
    expect(result.subscriptionInfo, isNull);
  });

  test('preserves the URL and headers of a subscription QR payload', () async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    const source = 'https://example.com/subscription';
    const info = SubscriptionInfo(total: 1024, planName: 'Reality Pro');
    final result = await AppController(_FakeBridge()).resolveQrPayload(
      source,
      subscriptionFetcher: (requested) async {
        expect(requested, source);
        return const SubscriptionFetchResult(content: link, info: info);
      },
    );

    expect(result.content, link);
    expect(result.sourceUrl, source);
    expect(result.subscriptionInfo, same(info));
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

  test('persists a subscription address in generated profile metadata', () {
    final config = VlessRealityProfile.attachSubscriptionSource(
      'generated config',
      'https://example.com/subscription?token=abc',
    );

    expect(config, startsWith('# proxima-subscription-url: '));
    expect(config, contains('generated config'));
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

  test('normalizes a Base64URL-wrapped single VLESS link', () {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    final encoded = base64UrlEncode(utf8.encode(link)).replaceAll('=', '');

    expect(VlessRealityProfile.normalizeLinkInput(encoded), link);
  });

  test('rejects non-REALITY VLESS links', () {
    expect(
      () => VlessRealityProfile.parse(
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=tls',
      ),
      throwsFormatException,
    );
  });

  test('accepts XHTTP and preserves modern REALITY link options', () {
    const link =
        'vless://123e4567-e89b-72d3-a456-426614174000@edge.example.com:443?encryption=mlkem768x25519plus&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&pqv=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789&type=xhttp&path=%2Fapi&mode=auto&alpn=h2#Modern';

    final profile = VlessRealityProfile.parse(link);
    final stored = profile.toMihomoYaml(profileName: profile.name);

    expect(profile.network, 'xhttp');
    expect(profile.uuid, '123e4567-e89b-72d3-a456-426614174000');
    expect(VlessRealityProfile.linkFromStoredConfig(stored), link);
  });

  test('rejects WebSocket because Xray REALITY does not support it', () {
    expect(
      () => VlessRealityProfile.parse(
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=ws&path=%2Fws',
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
}

class _FakeBridge implements VpnBridge {
  String? lastMethod;
  String? lastData;
  final invokedMethods = <String>[];
  final profile = VpnProfile(
    id: '00000000-0000-0000-0000-000000000000',
    name: 'VLESS REALITY',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    isActive: true,
  );
  String profileContent = '';
  final selections = <String, String>{};
  String? startedProfileId;
  int stopCount = 0;

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
    invokedMethods.add(method);
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
  Future<void> startVpn(String profileId) async {
    startedProfileId = profileId;
  }

  @override
  Future<void> stopVpn() async {
    stopCount++;
  }

  @override
  Future<String?> validateProfile(String content) async => null;
}
