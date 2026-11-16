import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/core/vless_reality_profile.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/screens/proxies_screen.dart';
import 'package:proxima/state/app_controller.dart';

const yaml = '''
proxies:
  - name: Reality
    type: vless
    server: reality.example
    port: 443
    uuid: secret-uuid
    tls: true
    servername: sni.example
    network: grpc
    flow: xtls-rprx-vision
    reality-opts: {public-key: public-value, short-id: ab12}
    grpc-opts: {grpc-service-name: tunnel}
  - name: HY2
    type: hysteria2
    server: hy.example
    port: 8443
    password: secret-password
    obfs: salamander
    obfs-password: secret-obfs
    sni: hy-sni.example
  - name: Wire
    type: wireguard
    server: wire.example
    port: 51820
    private-key: secret-private-key
    public-key: wire-public
''';

class _Bridge implements VpnBridge {
  _Bridge(this.content);
  String content;
  @override
  Future<String> readProfile(String id) async => content;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppController _controllerFor(_Bridge bridge) => AppController(bridge)
  ..profiles = [
    VpnProfile(
      id: 'id',
      name: 'Profile',
      updatedAt: DateTime(2020),
      isActive: true,
    ),
  ];

void main() {
  test('admitted mixed YAML maps public fields using raw names', () async {
    final controller = _controllerFor(_Bridge(yaml));
    addTearDown(controller.dispose);
    final nodes = await controller.readNodeDetails();
    expect(nodes.keys, ['Reality', 'HY2', 'Wire']);
    expect(nodes['Reality']!.security, 'reality');
    expect(nodes['Reality']!.serverName, 'sni.example');
    expect(nodes['Reality']!.publicKey, 'public-value');
    expect(nodes['Reality']!.shortId, 'ab12');
    expect(nodes['Reality']!.serviceName, 'tunnel');
    expect(nodes['HY2']!.protocol, 'hysteria2');
    expect(nodes['HY2']!.server, 'hy.example');
    expect(nodes['HY2']!.port, 8443);
    expect(nodes['HY2']!.network, 'udp');
    expect(nodes['HY2']!.security, 'tls');
    expect(nodes['HY2']!.serverName, 'hy-sni.example');
    expect(nodes['Wire']!.security, 'wireguard');
    expect(nodes['Wire']!.publicKey, isNull);
  });

  test('legacy aliases follow admission preview', () async {
    const link =
        'vless://11111111-1111-4111-8111-111111111111@first.example:443?security=tls&type=ws&path=%2Fsocket#Same';
    final bridge = _Bridge(
      VlessRealityProfile.storedConfigFromInput(
        '$link\n$link',
        profileName: 'Profile',
      ),
    );
    final controller = _controllerFor(bridge);
    addTearDown(controller.dispose);
    final nodes = await controller.readNodeDetails();
    expect(nodes.keys, ['Same', 'Same 2']);
    expect(nodes['Same']!.path, '/socket');
  });

  test('Hysteria2 share link exposes public connection details', () async {
    final controller = _controllerFor(
      _Bridge(
        'hy2://secret-password@hy.example:8443?sni=hy-sni.example&obfs=salamander&obfs-password=secret-obfs#HY2',
      ),
    );
    addTearDown(controller.dispose);
    final nodes = await controller.readNodeDetails();
    expect(nodes.keys, ['HY2']);
    expect(nodes['HY2']!.protocol, 'hysteria2');
    expect(nodes['HY2']!.serverName, 'hy-sni.example');
    expect(nodes['HY2']!.port, 8443);
  });

  testWidgets('node information shows HY2 and REALITY without credentials', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controllerFor(_Bridge(yaml));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ProxiesScreen(controller: controller)),
    );
    await tester.tap(find.byTooltip('노드 정보'));
    await tester.pumpAndSettle();
    expect(find.text('HYSTERIA2 · UDP · TLS'), findsOneWidget);
    await tester.tap(find.text('HY2'));
    await tester.pumpAndSettle();
    expect(find.text('hy.example'), findsOneWidget);
    expect(find.text('8443'), findsOneWidget);
    expect(find.text('hy-sni.example'), findsOneWidget);
    expect(find.textContaining('secret-'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reality'));
    await tester.pumpAndSettle();
    expect(find.text('public-value'), findsOneWidget);
    expect(find.text('ab12'), findsOneWidget);
    expect(find.text('xtls-rprx-vision'), findsOneWidget);
    expect(find.textContaining('secret-'), findsNothing);
  });

  testWidgets('node information hides tokens in transport paths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controllerFor(_Bridge('''
proxies:
  - name: WS
    type: vless
    server: ws.example
    port: 443
    uuid: secret-uuid
    tls: true
    network: ws
    ws-opts: {path: '/connect?token=secret-token#secret-fragment'}
'''));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ProxiesScreen(controller: controller)),
    );
    await tester.tap(find.byTooltip('노드 정보'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WS'));
    await tester.pumpAndSettle();
    expect(find.text('/connect'), findsOneWidget);
    expect(find.textContaining('secret-'), findsNothing);
    final node = (await controller.readNodeDetails())['WS']!;
    expect(node.path, '/connect');
  });
}
