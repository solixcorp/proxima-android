import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:proxima/widgets/app_page.dart';

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

  testWidgets('shows saved destination rules before the first connection', (
    tester,
  ) async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?security=tls&type=tcp#Seoul';
    final bridge = _FakeBridge()
      ..profileContent = VlessRealityProfile.storedConfigFromInput(
        '$link\nDOMAIN-SUFFIX,example.com,PROXY\nIP-CIDR,10.0.0.0/8,DIRECT\nMATCH,PROXY',
        profileName: 'Proxima',
      );
    final controller = AppController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(home: ProxiesScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('domain:example.com'), findsOneWidget);
    expect(find.text('10.0.0.0/8'), findsOneWidget);
    expect(bridge.startedProfileId, isNull);
    expect(bridge.invokedMethods, isEmpty);
  });

  testWidgets('scrolls the rule list when dragging selectable destinations', (
    tester,
  ) async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?security=tls&type=tcp#Seoul';
    final rules = List.generate(
      40,
      (index) => 'DOMAIN-SUFFIX,rule$index.example.com,PROXY',
    ).join('\n');
    final bridge = _FakeBridge()
      ..profileContent = VlessRealityProfile.storedConfigFromInput(
        '$link\n$rules\nMATCH,PROXY',
        profileName: 'Proxima',
      );
    final controller = AppController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: ProxiesScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(scroll.position.pixels, 0);
    await tester.dragFrom(
      tester.getCenter(find.text('domain:rule0.example.com')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
  });

  for (final mode in [OutboundMode.rule, OutboundMode.global]) {
    test('refreshes current subscription servers before connecting in $mode', () async {
      final bridge = _AccountImportBridge();
      final controller = _AccountImportController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.importAccountSubscription(
        'https://sub.example.com/sub/account',
      );
      // Current routing metadata must not suppress a fresh server-list fetch.
      bridge.profileContent = VlessRealityProfile.storedConfigFromInput(
        '${controller.subscriptionContent}\nMATCH,PROXY',
        profileName: 'Proxima',
      );
      controller.settings = VpnSettings(mode: mode);
      controller.subscriptionContent =
          'vless://123e4567-e89b-42d3-a456-426614174000@new-edge.example.com:443?security=tls&type=tcp#Active';

      await controller.toggleVpn();

      final links = VlessRealityProfile.linksFromStoredConfig(
        bridge.profileContent,
      );
      expect(links.map((link) => Uri.parse(link).host), ['new-edge.example.com']);
      expect(bridge.startedProfileId, 'account-profile');
    });
  }

  test('preserves rule-set and process rules in subscription display order', () {
    const yaml = '''
proxies:
  - {name: Seoul, type: vless, server: edge.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000}
proxy-groups:
  - {name: PROXY, type: fallback, proxies: [Seoul]}
rules:
  - RULE-SET,private_domain,DIRECT
  - DOMAIN-SUFFIX,example.com,PROXY
  - PROCESS-NAME,game.exe,PROXY
  - MATCH,PROXY
''';
    final content = VlessRealityProfile.storedConfigFromInput(
      yaml,
      profileName: 'Proxima',
    );

    final rules = VlessRealityProfile.routingRulesFromStoredConfig(content);

    expect(rules.map((rule) => rule.destination), [
      'RULE-SET,private_domain',
      'domain:example.com',
      'PROCESS-NAME,game.exe',
      '나머지 모든 트래픽',
    ]);
    expect(rules.map((rule) => rule.supported), [false, true, false, true]);
  });

  test('does not offer Proxima quota placeholders as connection servers', () {
    const yaml = '''
proxies:
  - {name: "잔여 트래픽: 50.0 GB", type: vless, server: active.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000}
  - {name: "만료까지: 30일", type: vless, server: active.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000}
  - {name: Seoul, type: vless, server: active.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000}
proxy-groups:
  - {name: PROXY, type: fallback, proxies: [Seoul]}
rules:
  - MATCH,PROXY
''';

    final config = VlessRealityProfile.storedConfigFromInput(
      yaml,
      profileName: 'Proxima',
    );

    final links = VlessRealityProfile.linksFromStoredConfig(config);
    expect(links.map((link) => Uri.parse(link).host), ['active.example.com']);
    expect(Uri.parse(links.single).fragment, 'Seoul');
  });

  test('does not connect stale servers when subscription refresh fails', () async {
    final bridge = _AccountImportBridge();
    final controller = _AccountImportController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.importAccountSubscription(
      'https://sub.example.com/sub/account',
    );
    final originalContent = bridge.profileContent;
    controller.failFetch = true;

    await controller.toggleVpn();

    expect(bridge.startedProfileId, isNull);
    expect(bridge.profileContent, originalContent);
    expect(controller.message, isNotNull);
    expect(controller.preparingConnection, isFalse);
  });

  test('local profiles connect without a subscription fetch', () async {
    final bridge = _FakeBridge();
    final controller = _AccountImportController(bridge)..failFetch = true;
    addTearDown(controller.dispose);
    await controller.initialize();

    await controller.toggleVpn();

    expect(bridge.startedProfileId, bridge.profile.id);
    expect(controller.message, isNull);
  });

  test('does not connect a different profile selected during server refresh', () async {
    final bridge = _AccountImportBridge();
    final controller = _AccountImportController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.importAccountSubscription('https://sub.example.com/first');
    bridge.savedProfiles.add(
      VpnProfile(
        id: 'second-subscription',
        name: 'Second',
        sourceUrl: 'https://sub.example.com/second',
        updatedAt: DateTime.utc(2026),
        isActive: false,
      ),
    );
    final requested = Completer<void>();
    final response = Completer<SubscriptionFetchResult>();
    controller
      ..fetchRequested = requested
      ..pendingFetch = response.future;

    final connection = controller.toggleVpn();
    await requested.future.timeout(const Duration(seconds: 5));
    await controller.selectProfile('second-subscription');
    response.complete(SubscriptionFetchResult(content: controller.subscriptionContent));
    await connection;

    expect(bridge.startedProfileId, isNull);
    expect(controller.activeProfile?.id, 'second-subscription');
  });

  for (final failOldRead in [false, true]) {
    test('discards stale rule reads after switching profiles ($failOldRead)', () async {
      const link =
          'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?security=tls&type=tcp#First';
      final original = VlessRealityProfile.storedConfigFromInput(
        '$link\nDOMAIN-SUFFIX,first.example.com,PROXY\nMATCH,PROXY',
        profileName: 'First',
      );
      final bridge = _AccountImportBridge()..profileContent = original;
      final controller = AppController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      bridge.savedProfiles.add(
        VpnProfile(
          id: 'second-profile',
          name: 'Second',
          updatedAt: DateTime.utc(2026),
          isActive: false,
        ),
      );
      final requested = Completer<void>();
      final response = Completer<String>();
      bridge
        ..profileReadRequested = requested
        ..pendingProfileRead = response.future;
      final oldLoad = controller.loadProxyGroups();
      await requested.future.timeout(const Duration(seconds: 5));
      bridge
        ..profileReadError = 'second_read_failed'
        ..failingReadProfileId = 'second-profile';
      var stalePublished = false;
      final finished = Completer<void>();
      void observe() {
        if (controller.activeProfile?.id != 'second-profile') return;
        if (controller.routingRules.isNotEmpty ||
            controller.proxyError?.contains('first_read_failed') == true) {
          stalePublished = true;
        }
        if (!controller.loadingProxies &&
            controller.proxyError?.contains('second_read_failed') == true &&
            !finished.isCompleted) {
          finished.complete();
        }
      }
      controller.addListener(observe);
      addTearDown(() => controller.removeListener(observe));
      await controller.selectProfile('second-profile');
      if (failOldRead) {
        response.completeError(StateError('first_read_failed'));
      } else {
        response.complete(original);
      }
      await oldLoad;
      await finished.future.timeout(const Duration(seconds: 5));
      expect(stalePublished, isFalse);
      expect(controller.routingRules, isEmpty);
      expect(controller.proxyError, contains('second_read_failed'));
    });
  }

  test('invalidates displayed rules when the native profile changes', () async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?security=tls&type=tcp#First';
    final events = StreamController<VpnSnapshot>(sync: true);
    final bridge = _AccountImportBridge()
      ..snapshotEvents = events.stream
      ..profileContent = VlessRealityProfile.storedConfigFromInput(
        '$link\nDOMAIN-SUFFIX,first.example.com,PROXY',
        profileName: 'First',
      );
    final controller = AppController(bridge);
    addTearDown(() async {
      controller.dispose();
      await events.close();
    });
    await controller.initialize();
    controller.snapshot = VpnSnapshot(
      state: VpnConnectionState.connected,
      profileId: bridge.profile.id,
    );
    bridge.savedProfiles.add(
      VpnProfile(
        id: 'second-profile',
        name: 'Second',
        updatedAt: DateTime.utc(2026),
        isActive: false,
      ),
    );
    await controller.selectProfile('second-profile');
    expect(controller.routingRules, isNotEmpty);
    events.add(
      const VpnSnapshot(
        state: VpnConnectionState.connecting,
        profileId: 'second-profile',
      ),
    );
    expect(controller.activeProfile?.id, 'second-profile');
    expect(controller.routingRules, isEmpty);
    expect(controller.proxyError, isNull);
  });

  testWidgets('rule errors survive dismissal of the shell message', (tester) async {
    final bridge = _FakeBridge()..profileReadError = 'rule_read_failed';
    final controller = AppController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();

    controller.clearMessage();
    await tester.pumpWidget(
      MaterialApp(home: ProxiesScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('rule_read_failed'), findsOneWidget);
  });

  test('cancelling server preparation discards a late subscription response', () async {
    final bridge = _AccountImportBridge();
    final controller = _AccountImportController(bridge);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.importAccountSubscription('https://sub.example.com/account');
    final originalContent = bridge.profileContent;
    final requested = Completer<void>();
    final response = Completer<SubscriptionFetchResult>();
    controller
      ..fetchRequested = requested
      ..pendingFetch = response.future;

    final connection = controller.toggleVpn();
    await requested.future.timeout(const Duration(seconds: 5));
    controller.cancelConnectionPreparation();
    response.complete(
      const SubscriptionFetchResult(
        content:
            'vless://123e4567-e89b-42d3-a456-426614174000@late.example.com:443?security=tls&type=tcp#Late',
      ),
    );
    await connection;

    expect(bridge.startedProfileId, isNull);
    expect(bridge.profileContent, originalContent);
    expect(controller.preparingConnection, isFalse);
    expect(controller.message, isNull);
  });

  for (final reconnect in [false, true]) {
    test('cancellation during validation discards its write ($reconnect)', () async {
      final bridge = _AccountImportBridge();
      final controller = _AccountImportController(bridge);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.importAccountSubscription('https://sub.example.com/account');
      controller.subscriptionContent =
          'vless://123e4567-e89b-42d3-a456-426614174000@cancelled.example.com:443?security=tls&type=tcp#Cancelled';
      final requested = Completer<void>();
      final response = Completer<String?>();
      bridge
        ..validationRequested = requested
        ..pendingValidation = response.future;
      final cancelledConnection = controller.toggleVpn();
      await requested.future.timeout(const Duration(seconds: 5));
      controller.cancelConnectionPreparation();
      if (reconnect) {
        controller.subscriptionContent =
            'vless://123e4567-e89b-42d3-a456-426614174000@current.example.com:443?security=tls&type=tcp#Current';
        await controller.toggleVpn();
      }
      final currentContent = bridge.profileContent;
      final currentSaveCount = bridge.savedIds.length;
      response.complete(null);
      await cancelledConnection;
      expect(bridge.profileContent, currentContent);
      expect(bridge.savedIds, hasLength(currentSaveCount));
      expect(
        bridge.startedProfileId,
        reconnect ? controller.activeProfile?.id : isNull,
      );
      expect(controller.preparingConnection, isFalse);
      expect(controller.message, isNull);
    });
  }

  testWidgets('progress appears only after a one-second operation', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DelayedProgressIndicator(semanticsLabel: 'Loading rules'),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Elapsed time is the behavior under test, not a synchronization shortcut.
    await tester.pump(const Duration(milliseconds: 999));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
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

  test('derives a provider profile name from VLESS labels and subscription URL', () {
    const proximaJapan =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#VLESS%20Proxima%20%7C%20Japan%2001';
    const proximaUs =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge-us.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#VLESS%20Proxima%20%7C%20US%2001';

    expect(
      VlessRealityProfile.suggestedProfileName('$proximaJapan\n$proximaUs'),
      'Proxima',
    );
    expect(
      VlessRealityProfile.suggestedProfileName(
        proximaJapan,
        sourceUrl: 'https://my.ssonenetwork.com/subscribe',
      ),
      'ssonenetwork',
    );
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

  test('converts Clash.Meta nodes and ordered rules into Xray metadata', () {
    const yaml = '''
proxies:
  - {name: '剩余流量：10 GB', type: vless, server: info.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000, network: tcp, servername: cdn.example.com, client-fingerprint: chrome, reality-opts: {public-key: abcdefghijklmnopqrstuvwxzy0123456789ABCD, short-id: 1a2b}}
  - {name: Tokyo, type: vless, server: tokyo.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000, network: tcp, servername: cdn.example.com, client-fingerprint: chrome, flow: xtls-rprx-vision, reality-opts: {public-key: abcdefghijklmnopqrstuvwxzy0123456789ABCD, short-id: 1a2b}}
  - {name: Seoul, type: vless, server: seoul.example.com, port: 8443, uuid: 123e4567-e89b-42d3-a456-426614174000, network: tcp, servername: cdn.example.com, client-fingerprint: firefox, reality-opts: {public-key: abcdefghijklmnopqrstuvwxzy0123456789ABCD, short-id: 3c4d}}
  - {name: Unsupported, type: mieru, server: direct.example.com, port: 443}
proxy-groups:
  - {name: Manual, type: select, proxies: [Auto, Tokyo, Seoul]}
  - {name: Auto, type: url-test, proxies: [Tokyo, Seoul], url: 'https://cp.cloudflare.com/generate_204'}
  - {name: Domestic, type: select, proxies: [DIRECT, Manual]}
  - {name: Ads, type: select, proxies: [REJECT, DIRECT]}
rules:
  - DOMAIN-SUFFIX,example.ai,Manual
  - AND,((DOMAIN-SUFFIX,example.ai),(NETWORK,UDP),(DST-PORT,443)),REJECT
  - DOMAIN-SUFFIX,example.cn,Domestic
  - DOMAIN-SUFFIX,ads.example,Ads
  - MATCH,Manual
''';

    final config = VlessRealityProfile.storedConfigFromInput(
      yaml,
      profileName: 'Airport',
    );
    final links = VlessRealityProfile.linksFromStoredConfig(config);
    expect(links, hasLength(2));
    expect(links.first, contains('tokyo.example.com'));
    expect(links.last, contains('seoul.example.com'));
    expect(config, isNot(contains('info.example.com')));
    expect(config, startsWith(VlessRealityProfile.routingMetadataPrefix));

    final encoded = config
        .split('\n')
        .first
        .substring(VlessRealityProfile.routingMetadataPrefix.length)
        .trim();
    final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
    final routing = jsonDecode(
      utf8.decode(base64Url.decode(padded)),
    ) as Map<String, dynamic>;
    final rules = routing['rules'] as List<dynamic>;
    expect(routing['version'], 2);
    expect(routing['autoTestUrl'], 'https://cp.cloudflare.com/generate_204');
    expect(rules, hasLength(5));
    expect((rules[0] as Map<String, dynamic>)['target'], 'proxy');
    expect((rules[0] as Map<String, dynamic>)['policy'], 'Manual');
    expect((rules[0] as Map<String, dynamic>)['candidates'], [
      'Tokyo',
      'Seoul',
    ]);
    expect((rules[1] as Map<String, dynamic>)['network'], 'udp');
    expect((rules[1] as Map<String, dynamic>)['target'], 'block');
    expect((rules[2] as Map<String, dynamic>)['target'], 'direct');
    expect((rules[3] as Map<String, dynamic>)['target'], 'block');
    expect((rules[4] as Map<String, dynamic>)['match'], isTrue);
    expect((rules[4] as Map<String, dynamic>)['candidates'], [
      'Tokyo',
      'Seoul',
    ]);
  });

  test('prefers a rule-bearing Clash subscription over a VLESS response', () async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    const yaml = '''
proxies:
  - {name: Tokyo, type: vless, server: edge.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000, reality-opts: {public-key: abcdefghijklmnopqrstuvwxzy0123456789ABCD}}
proxy-groups:
  - {name: PROXY, type: select, proxies: [Tokyo]}
rules:
  - DOMAIN-SUFFIX,example.com,Tokyo
  - MATCH,PROXY
''';
    final requestedAgents = <String>[];
    final result = await AppController.fetchPreferredSubscription((
      agent,
    ) async {
      requestedAgents.add(agent);
      return SubscriptionFetchResult(
        content: agent == 'clash.meta' ? link : yaml,
      );
    });

    expect(requestedAgents, ['clash.meta', 'ClashForAndroid']);
    expect(result.content, yaml);
    expect(
      VlessRealityProfile.hasCurrentRoutingMetadata(
        VlessRealityProfile.storedConfigFromInput(
          result.content,
          profileName: 'Airport',
        ),
      ),
      isTrue,
    );
  });

  test('retains usable VLESS links if the alternate format fails', () async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    final result = await AppController.fetchPreferredSubscription((
      agent,
    ) async {
      if (agent == 'ClashForAndroid') {
        throw const FormatException('unsupported');
      }
      return const SubscriptionFetchResult(content: link);
    });
    expect(result.content, link);
  });

  test('tries another client identity after an HTTP rejection', () async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    final requestedAgents = <String>[];
    final result = await AppController.fetchPreferredSubscription((
      agent,
    ) async {
      requestedAgents.add(agent);
      if (agent == 'clash.meta') throw const FormatException('rejected');
      return const SubscriptionFetchResult(content: link);
    });
    expect(requestedAgents, ['clash.meta', 'ClashForAndroid']);
    expect(result.content, link);
  });

  test('retries the legacy client identity after both Clash requests get 403', () async {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    final requestedAgents = <String>[];
    final result = await AppController.fetchPreferredSubscription((
      agent,
    ) async {
      requestedAgents.add(agent);
      if (agent != 'v2rayN/6.45 Proxima/1.0') {
        throw const HttpException('서버 응답 403');
      }
      return const SubscriptionFetchResult(content: link);
    });

    expect(requestedAgents, [
      'clash.meta',
      'ClashForAndroid',
      'v2rayN/6.45 Proxima/1.0',
    ]);
    expect(result.content, link);
  });

  test('keeps the selected policy for a compound Clash rule', () {
    const yaml = '''
proxies:
  - {name: Tokyo, type: vless, server: tokyo.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000, reality-opts: {public-key: abcdefghijklmnopqrstuvwxzy0123456789ABCD}}
  - {name: Seoul, type: vless, server: seoul.example.com, port: 443, uuid: 123e4567-e89b-42d3-a456-426614174000, reality-opts: {public-key: abcdefghijklmnopqrstuvwxzy0123456789ABCD}}
proxy-groups:
  - {name: Korea, type: select, proxies: [Seoul]}
rules:
  - AND,((DOMAIN-SUFFIX,example.com),(NETWORK,TCP),(DST-PORT,443)),Korea
  - MATCH,Tokyo
''';
    final config = VlessRealityProfile.storedConfigFromInput(
      yaml,
      profileName: 'Airport',
    );
    final encoded = config
        .split('\n')
        .first
        .substring(VlessRealityProfile.routingMetadataPrefix.length)
        .trim();
    final routing = jsonDecode(
      utf8.decode(
        base64Url.decode(encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=')),
      ),
    ) as Map<String, dynamic>;
    final rule = (routing['rules'] as List).first as Map<String, dynamic>;
    expect(rule['policy'], 'Korea');
    expect(rule['candidates'], ['Seoul']);
  });

  test('preserves destination rules alongside plain VLESS links', () {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    const input = '$link\nDOMAIN-SUFFIX,example.com,Tokyo\nMATCH,DIRECT';
    final config = VlessRealityProfile.storedConfigFromInput(
      input,
      profileName: 'Tokyo',
    );
    expect(VlessRealityProfile.hasCurrentRoutingMetadata(config), isTrue);
    expect(
      VlessRealityProfile.inlineRulesFromStoredConfig(config),
      'DOMAIN-SUFFIX,example.com,Tokyo\nMATCH,DIRECT',
    );
    expect(VlessRealityProfile.linksFromStoredConfig(config), [link]);
    expect(
      () => VlessRealityProfile.storedConfigFromInput(
        '$link\nDOMAIN-SUFFIX,example.com,Missing',
        profileName: 'Tokyo',
      ),
      throwsFormatException,
    );
  });

  test('normalizes a Base64URL-wrapped single VLESS link', () {
    const link =
        'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=reality&sni=cdn.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&type=tcp#Tokyo';
    final encoded = base64UrlEncode(utf8.encode(link)).replaceAll('=', '');

    expect(VlessRealityProfile.normalizeLinkInput(encoded), link);
  });

  test('accepts TLS VLESS links without a REALITY key', () {
    final profile = VlessRealityProfile.parse(
      'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=tls',
    );
    expect(profile.security, 'tls');
    expect(profile.publicKey, isEmpty);
    expect(profile.toMihomoYaml(profileName: 'TLS'), contains('tls: true'));
    expect(
      profile.toMihomoYaml(profileName: 'TLS'),
      isNot(contains('reality-opts:')),
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

  test('account subscription import updates rather than duplicates a profile', () async {
    final bridge = _AccountImportBridge();
    final controller = _AccountImportController(bridge);
    await controller.initialize();

    await controller.importAccountSubscription('https://sub.example.com/sub/account');
    expect(bridge.savedProfiles, hasLength(2));
    expect(bridge.selectedId, 'account-profile');
    expect(bridge.startedProfileId, isNull);
    expect(bridge.savedProfiles.last.subscriptionInfo?.planName, 'Standard');

    await controller.importAccountSubscription('https://sub.example.com/sub/account');
    expect(bridge.savedProfiles, hasLength(2));
    expect(bridge.savedIds, [null, 'account-profile']);
    expect(bridge.selectedId, 'account-profile');
    controller.dispose();
  });
}

class _AccountImportController extends AppController {
  _AccountImportController(super.bridge);

  bool failFetch = false;
  Completer<void>? fetchRequested;
  Future<SubscriptionFetchResult>? pendingFetch;
  String subscriptionContent =
      'vless://123e4567-e89b-42d3-a456-426614174000@edge.example.com:443?encryption=none&security=tls&type=tcp#Account';

  @override
  Future<SubscriptionFetchResult> fetchSubscriptionDetails(String source) async {
    fetchRequested?.complete();
    fetchRequested = null;
    final pending = pendingFetch;
    if (pending != null) return pending;
    if (failFetch) throw const SocketException('subscription unavailable');
    return SubscriptionFetchResult(
      content: subscriptionContent,
      info: const SubscriptionInfo(planName: 'Standard'),
    );
  }
}

class _AccountImportBridge extends _FakeBridge {
  late final savedProfiles = <VpnProfile>[profile];
  final savedIds = <String?>[];
  String? selectedId;

  @override
  Future<List<VpnProfile>> listProfiles() async => List.of(savedProfiles);

  @override
  Future<VpnProfile> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
    SubscriptionInfo? subscriptionInfo,
  }) async {
    profileContent = content;
    savedIds.add(id);
    final saved = VpnProfile(
      id: id ?? 'account-profile',
      name: name,
      sourceUrl: sourceUrl,
      updatedAt: DateTime.utc(2026),
      isActive: id != null && id == selectedId,
      subscriptionInfo: subscriptionInfo,
    );
    savedProfiles.removeWhere((profile) => profile.id == saved.id);
    savedProfiles.add(saved);
    return saved;
  }

  @override
  Future<void> selectProfile(String id) async {
    selectedId = id;
    for (var index = 0; index < savedProfiles.length; index++) {
      final profile = savedProfiles[index];
      savedProfiles[index] = VpnProfile(
        id: profile.id,
        name: profile.name,
        sourceUrl: profile.sourceUrl,
        subscriptionInfo: profile.subscriptionInfo,
        updatedAt: profile.updatedAt,
        isActive: profile.id == id,
      );
    }
  }
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
  String? profileReadError;
  String? failingReadProfileId;
  Completer<void>? profileReadRequested;
  Future<String>? pendingProfileRead;
  Completer<void>? validationRequested;
  Future<String?>? pendingValidation;
  Stream<VpnSnapshot>? snapshotEvents;
  final selections = <String, String>{};
  String? startedProfileId;
  int stopCount = 0;

  @override
  Stream<VpnSnapshot> get snapshots => snapshotEvents ?? const Stream.empty();

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
  Future<String> readProfile(String id) async {
    final pending = pendingProfileRead;
    if (pending != null) {
      pendingProfileRead = null;
      profileReadRequested?.complete();
      profileReadRequested = null;
      return pending;
    }
    final error = profileReadError;
    if (error != null &&
        (failingReadProfileId == null || failingReadProfileId == id)) {
      throw StateError(error);
    }
    return profileContent;
  }

  @override
  Future<bool> requestVpnPermission() async => true;

  @override
  Future<String> requestQuickSettingsTile() async => 'added';

  @override
  Future<bool> requestPinAppWidget() async => true;

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
  Future<String?> validateProfile(String content) async {
    final pending = pendingValidation;
    if (pending != null) {
      pendingValidation = null;
      validationRequested?.complete();
      validationRequested = null;
      return pending;
    }
    return null;
  }
}
