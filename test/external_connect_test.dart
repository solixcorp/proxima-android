import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/app/external_connect_handler.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/state/app_controller.dart';

class _Bridge extends MethodChannelVpnBridge {
  final events = StreamController<void>.broadcast(sync: true);
  bool pending = false;
  int consumes = 0;
  Completer<void>? gate;
  Completer<void>? settingsGate;
  int starts = 0;
  VpnSettings? preparedSettings;

  @override
  Future<void> saveSettings(VpnSettings settings) async {
    await settingsGate?.future;
  }

  @override
  Future<bool> requestVpnPermission() async => true;
  @override
  Future<String> readProfile(String id) async =>
      'proxies:\n  - {name: node, type: socks5, server: example.com, port: 1080}\n';
  @override
  Future<Map<String, String>> loadProxySelections(String profileId) async => {};
  @override
  Future<void> prepareMihomoConfiguration(
    String profileId,
    String yaml, {
    required String source,
    required VpnSettings settings,
  }) async {
    preparedSettings = settings;
  }

  @override
  Future<void> startVpn(String profileId) async {
    starts++;
  }

  @override
  Stream<void> get externalConnectRequests => events.stream;
  @override
  Future<bool> consumeExternalConnect() async {
    consumes++;
    await gate?.future;
    final result = pending;
    pending = false;
    return result;
  }

  void request() {
    pending = true;
    events.add(null);
  }
}

class _Controller extends AppController {
  _Controller(super.bridge);
  int connects = 0;
  Completer<void>? connectGate;
  @override
  Future<void> toggleVpn() async {
    connects++;
    await connectGate?.future;
  }

  void ready() {
    initialized = true;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('method channel uses the native one-shot consumption method', () async {
    const channel = MethodChannel('proxima/vpn');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    expect(await MethodChannelVpnBridge().consumeExternalConnect(), isTrue);
    expect(calls, ['consumeExternalConnect']);
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('cold request waits for initialization; warm requests work', (
    tester,
  ) async {
    final bridge = _Bridge()..pending = true;
    final controller = _Controller(bridge);
    await tester.pumpWidget(
      ExternalConnectHandler(controller: controller, child: const SizedBox()),
    );
    bridge.request();
    await tester.pump();
    expect(bridge.consumes, 0);
    controller.ready();
    await tester.pump();
    expect(controller.connects, 1);
    bridge.request();
    await tester.pump();
    expect(controller.connects, 2);
    await tester.pumpWidget(const SizedBox());
    await bridge.events.close();
    controller.dispose();
  });

  testWidgets('consumes and ignores connected, busy and duplicate requests', (
    tester,
  ) async {
    final bridge = _Bridge();
    final controller = _Controller(bridge)..initialized = true;
    await tester.pumpWidget(
      ExternalConnectHandler(controller: controller, child: const SizedBox()),
    );
    await tester.pump();
    for (final state in [
      VpnConnectionState.connected,
      VpnConnectionState.connecting,
      VpnConnectionState.disconnecting,
    ]) {
      controller.snapshot = VpnSnapshot(state: state);
      bridge.request();
      await tester.pump();
      expect(controller.connects, 0);
      expect(bridge.pending, false);
    }
    controller.snapshot = const VpnSnapshot(
      state: VpnConnectionState.disconnected,
    );
    controller.preparingConnection = true;
    bridge.request();
    await tester.pump();
    expect(controller.connects, 0);
    controller.preparingConnection = false;
    controller.connectGate = Completer<void>();
    bridge.request();
    await tester.pump();
    bridge.request();
    await tester.pump();
    expect(controller.connects, 1);
    expect(bridge.pending, false);
    controller.connectGate!.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await bridge.events.close();
    controller.dispose();
  });

  testWidgets(
    'racing notifications rescan; disposed handler does not connect',
    (tester) async {
      final bridge = _Bridge()..gate = Completer<void>();
      final controller = _Controller(bridge)..initialized = true;
      await tester.pumpWidget(
        ExternalConnectHandler(controller: controller, child: const SizedBox()),
      );
      bridge.request();
      bridge.gate!.complete();
      await tester.pump();
      expect(controller.connects, 1);
      expect(bridge.consumes, 2);
      bridge.gate = Completer<void>();
      bridge.request();
      await tester.pumpWidget(const SizedBox());
      bridge.gate!.complete();
      await tester.pump();
      expect(controller.connects, 1);
      await bridge.events.close();
      controller.dispose();
    },
  );

  testWidgets('replacing controller detaches the old source', (tester) async {
    final oldBridge = _Bridge();
    final newBridge = _Bridge()..pending = true;
    final oldController = _Controller(oldBridge)..initialized = true;
    final newController = _Controller(newBridge)..initialized = true;
    await tester.pumpWidget(
      ExternalConnectHandler(
        controller: oldController,
        child: const SizedBox(),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      ExternalConnectHandler(
        controller: newController,
        child: const SizedBox(),
      ),
    );
    await tester.pump();
    oldBridge.request();
    await tester.pump();
    expect(oldController.connects, 0);
    expect(newController.connects, 1);
    await tester.pumpWidget(const SizedBox());
    await oldBridge.events.close();
    await newBridge.events.close();
    oldController.dispose();
    newController.dispose();
  });

  testWidgets('request waits for a real delayed settings save', (tester) async {
    final bridge = _Bridge()..settingsGate = Completer<void>();
    final controller = AppController(bridge)
      ..initialized = true
      ..profiles = [
        VpnProfile(
          id: 'profile',
          name: 'Profile',
          updatedAt: DateTime(2024),
          isActive: true,
        ),
      ];
    await tester.pumpWidget(
      ExternalConnectHandler(controller: controller, child: const SizedBox()),
    );
    await tester.pump();
    final save = controller.updateSettings(
      const VpnSettings(mode: OutboundMode.direct, mtu: 1500),
    );
    expect(controller.configurationChangeInProgress, isTrue);
    final before = bridge.consumes;
    bridge.request();
    await tester.pump();
    expect(bridge.consumes, before);
    expect(bridge.pending, isTrue);
    expect(bridge.starts, 0);
    bridge.settingsGate!.complete();
    await save;
    await tester.pump();
    expect(controller.configurationChangeInProgress, isFalse);
    expect(bridge.starts, 1);
    expect(bridge.preparedSettings?.mtu, 1500);
    expect(bridge.pending, isFalse);
    await tester.pumpWidget(const SizedBox());
    await bridge.events.close();
    controller.dispose();
  });

  testWidgets('consumption racing settings save preserves the request', (
    tester,
  ) async {
    final bridge = _Bridge();
    final controller = _Controller(bridge)..initialized = true;
    await tester.pumpWidget(
      ExternalConnectHandler(controller: controller, child: const SizedBox()),
    );
    await tester.pump();
    bridge.gate = Completer<void>();
    bridge.settingsGate = Completer<void>();
    bridge.request();
    final save = controller.updateSettings(const VpnSettings());
    bridge.gate!.complete();
    await tester.pump();
    expect(bridge.pending, isFalse);
    expect(controller.connects, 0);
    bridge.settingsGate!.complete();
    await save;
    await tester.pump();
    expect(controller.connects, 1);
    await tester.pumpWidget(const SizedBox());
    await bridge.events.close();
    controller.dispose();
  });

  testWidgets('in-flight consumption survives disposal and remount', (
    tester,
  ) async {
    final bridge = _Bridge()..gate = Completer<void>();
    final oldController = _Controller(bridge)..initialized = true;
    await tester.pumpWidget(
      ExternalConnectHandler(
        controller: oldController,
        child: const SizedBox(),
      ),
    );
    bridge.request();
    await tester.pumpWidget(const SizedBox());
    final newController = _Controller(bridge)..initialized = true;
    await tester.pumpWidget(
      ExternalConnectHandler(
        controller: newController,
        child: const SizedBox(),
      ),
    );
    bridge.gate!.complete();
    await tester.pump();
    expect(oldController.connects, 0);
    expect(newController.connects, 1);
    await tester.pumpWidget(const SizedBox());
    await bridge.events.close();
    oldController.dispose();
    newController.dispose();
  });

  testWidgets('in-flight request follows a replacement controller', (
    tester,
  ) async {
    final oldBridge = _Bridge()..gate = Completer<void>();
    final newBridge = _Bridge();
    final oldController = _Controller(oldBridge)..initialized = true;
    final newController = _Controller(newBridge)..initialized = true;
    await tester.pumpWidget(
      ExternalConnectHandler(
        controller: oldController,
        child: const SizedBox(),
      ),
    );
    oldBridge.request();
    await tester.pumpWidget(
      ExternalConnectHandler(
        controller: newController,
        child: const SizedBox(),
      ),
    );
    oldBridge.gate!.complete();
    await tester.pump();
    expect(oldController.connects, 0);
    expect(newController.connects, 1);
    await tester.pumpWidget(const SizedBox());
    await oldBridge.events.close();
    await newBridge.events.close();
    oldController.dispose();
    newController.dispose();
  });
}
