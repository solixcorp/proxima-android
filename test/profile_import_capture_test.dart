import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/screens/profiles_screen.dart';
import 'package:proxima/state/app_controller.dart';

void main() {
  const enabled = bool.fromEnvironment('IMPORT_CAPTURES');
  if (enabled) {
    setUpAll(() async {
      final font = FontLoader('ImportCapture');
      font.addFont(
        File('/System/Library/Fonts/AppleSDGothicNeo.ttc')
            .readAsBytes().then(ByteData.sublistView),
      );
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        File('/Users/kimrasng/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytes().then(ByteData.sublistView),
      );
      await icons.load();
    });
  }
  for (final width in [390.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('profile import guidance $width ${brightness.name}', (
        tester,
      ) async {
        tester.view
          ..physicalSize = Size(width, 900)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = AppController(MethodChannelVpnBridge());
        addTearDown(controller.dispose);
        await tester.pumpWidget(RepaintBoundary(
          key: const Key('import-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              brightness: brightness,
              fontFamily: 'ImportCapture',
            ),
            home: ProfilesScreen(controller: controller),
          ),
        ));
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        const stage = String.fromEnvironment('CAPTURE_STAGE');
        await expectLater(
          find.byKey(const Key('import-capture')),
          matchesGoldenFile(
            '../.omo/evidence/backend-pin-20261104/$stage/${width.toInt()}-${brightness.name}.png',
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, skip: !enabled);
    }
  }
}
