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
        '{"code":0,"data":"{\\"proxies\\":{\\"GLOBAL\\":{\\"type\\":\\"Selector\\",\\"now\\":\\"DIRECT\\",\\"all\\":[\\"DIRECT\\",\\"Node A\\"]},\\"DIRECT\\":{\\"type\\":\\"Direct\\"}}}"}';

    final groups = parseProxyGroups(response);

    expect(groups, hasLength(1));
    expect(groups.single.name, 'GLOBAL');
    expect(groups.single.selected, 'DIRECT');
    expect(groups.single.proxies, ['DIRECT', 'Node A']);
  });

  test('formats traffic values', () {
    expect(formatBytes(1536, perSecond: true), '1.5 KB/s');
    expect(formatBytes(1024 * 1024), '1.0 MB');
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
  Future<ImportedProfile?> pickProfileFile() async => null;

  @override
  Future<String> readProfile(String id) async => '';

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
  }) async => profile;

  @override
  Future<void> saveSettings(VpnSettings settings) async {}

  @override
  Future<void> selectProfile(String id) async {}

  @override
  Future<void> startVpn(String profileId) async {}

  @override
  Future<void> stopVpn() async {}

  @override
  Future<String?> validateProfile(String content) async => null;
}
