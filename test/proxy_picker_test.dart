import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/screens/proxies_screen.dart';
import 'package:proxima/state/app_controller.dart';

class _ProbeController extends AppController {
  _ProbeController({bool connected = true, int nodes = 2})
    : super(MethodChannelVpnBridge()) {
    settings = const VpnSettings(mode: OutboundMode.global);
    snapshot = VpnSnapshot(
      state: connected
          ? VpnConnectionState.connected
          : VpnConnectionState.disconnected,
    );
    proxyGroups = [
      ProxyGroup(
        name: 'GLOBAL',
        type: 'Selector',
        selected: 'Node 0',
        proxies: List.generate(nodes, (index) => 'Node $index'),
      ),
    ];
  }

  final requests = <(String, Completer<int?>)>[];
  String? chosen;

  @override
  Future<int?> testDelay(String proxy) {
    final result = Completer<int?>();
    requests.add((proxy, result));
    return result.future;
  }

  @override
  Future<void> selectProxy(String groupName, String proxy) async {
    chosen = proxy;
  }
}

Future<void> _openPicker(
  WidgetTester tester,
  _ProbeController controller, {
  Brightness brightness = Brightness.light,
  String? font,
}) async {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF35618B),
    brightness: brightness,
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('picker-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: scheme,
          fontFamily: font,
          bottomSheetTheme: BottomSheetThemeData(
            showDragHandle: true,
            backgroundColor: scheme.surfaceContainerLow,
          ),
        ),
        home: ProxiesScreen(controller: controller),
      ),
    ),
  );
  await tester.tap(find.text('GLOBAL'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening nodes measures once and shows each result', (tester) async {
    final controller = _ProbeController();
    addTearDown(controller.dispose);
    await _openPicker(tester, controller);

    expect(controller.requests.map((request) => request.$1), [
      'Node 0',
      'Node 1',
    ]);
    expect(find.byTooltip('지연 시간 측정'), findsNothing);
    expect(find.widgetWithIcon(TextButton, Icons.speed_rounded), findsNothing);

    controller.notifyListeners();
    await tester.pump();
    expect(controller.requests, hasLength(2));
    controller.requests.first.$2.complete(24);
    await controller.requests.first.$2.future;
    await tester.pump();
    expect(find.text('24 ms'), findsOneWidget);
    controller.requests.last.$2.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('응답 없음'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disconnected nodes measure when the connection becomes ready', (
    tester,
  ) async {
    final controller = _ProbeController(connected: false);
    addTearDown(controller.dispose);
    await _openPicker(tester, controller);
    expect(controller.requests, isEmpty);
    controller.snapshot = const VpnSnapshot(state: VpnConnectionState.connected);
    controller.notifyListeners();
    await tester.pump();
    expect(controller.requests, hasLength(2));
    controller.requests.first.$2.completeError(StateError('unavailable'));
    controller.requests.last.$2.complete(45);
    await tester.pumpAndSettle();
    expect(find.text('45 ms'), findsOneWidget);
    expect(find.text('응답 없음'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('automatic measurements do not block selection or survive closing', (
    tester,
  ) async {
    final controller = _ProbeController();
    addTearDown(controller.dispose);
    await _openPicker(tester, controller);
    expect(controller.requests, hasLength(2));
    await tester.tap(find.text('Node 1'));
    await tester.pumpAndSettle();
    expect(controller.chosen, 'Node 1');
    expect(find.byType(BottomSheet), findsNothing);
    for (final request in controller.requests) {
      request.$2.complete(30);
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('GLOBAL'));
    await tester.pumpAndSettle();
    expect(controller.requests, hasLength(4));
    await tester.pumpWidget(const SizedBox.shrink());
    for (final request in controller.requests.skip(2)) {
      request.$2.complete(40);
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('measurement status uses readable type and theme contrast', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final controller = _ProbeController();
      await _openPicker(tester, controller, brightness: brightness);
      final text = tester.widget<Text>(find.text('측정 중').first);
      expect(text.style!.fontSize, greaterThanOrEqualTo(15));
      final scheme = Theme.of(tester.element(find.text('측정 중').first))
          .colorScheme;
      final foreground = text.style!.color!.computeLuminance();
      final ratios = <double>[];
      for (final background in [
        scheme.surfaceContainerLow,
        Color.alphaBlend(
          scheme.primaryContainer.withValues(alpha: 0.35),
          scheme.surfaceContainerLow,
        ),
      ]) {
        final luminance = background.computeLuminance();
        final ratio = foreground > luminance
            ? (foreground + 0.05) / (luminance + 0.05)
            : (luminance + 0.05) / (foreground + 0.05);
        expect(ratio, greaterThanOrEqualTo(4.5));
        ratios.add(ratio);
      }
      debugPrint('NODE_STATUS_CONTRAST ${brightness.name} $ratios');
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    }
  });

  if (const bool.fromEnvironment('NODE_CAPTURES')) {
    setUpAll(() async {
      final text = FontLoader('NodeCapture');
      text.addFont(
        File('/System/Library/Fonts/AppleSDGothicNeo.ttc')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
      await text.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        File(
          '/Users/kimrasng/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
      await icons.load();
    });
    for (final width in [390.0, 1440.0]) {
      for (final brightness in Brightness.values) {
        for (final state in ['offline', 'measuring', 'results']) {
          testWidgets('node capture $width ${brightness.name} $state', (
            tester,
          ) async {
            tester.view
              ..physicalSize = Size(width, 900)
              ..devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final controller = _ProbeController(
              connected: state != 'offline',
              nodes: 14,
            );
            addTearDown(controller.dispose);
            await _openPicker(
              tester,
              controller,
              brightness: brightness,
              font: 'NodeCapture',
            );
            const stage = String.fromEnvironment('CAPTURE_STAGE');
            if (stage == 'before' && state != 'offline') {
              await tester.tap(find.widgetWithIcon(TextButton, Icons.speed_rounded));
              await tester.pump();
            }
            if (state == 'results') {
              for (var index = 0; index < controller.requests.length; index++) {
                controller.requests[index].$2.complete(index == 1 ? null : 24 + index * 8);
              }
              await tester.pumpAndSettle();
            }
            final name = '${width.toInt()}-${brightness.name}-$state';
            await expectLater(
              find.byKey(const Key('picker-capture')),
              matchesGoldenFile(
                '../.omo/evidence/nodes-auto-measure-20261104/$stage/$name-top.png',
              ),
            );
            final scroll = tester.state<ScrollableState>(
              find.descendant(
                of: find.byType(BottomSheet),
                matching: find.byType(Scrollable),
              ),
            );
            scroll.position.jumpTo(scroll.position.maxScrollExtent);
            await tester.pump();
            await expectLater(
              find.byKey(const Key('picker-capture')),
              matchesGoldenFile(
                '../.omo/evidence/nodes-auto-measure-20261104/$stage/$name-end.png',
              ),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          });
        }
      }
    }
  }
}
