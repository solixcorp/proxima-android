import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/app/proxima_shell.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/core/proxima_account.dart';
import 'package:proxima/screens/profiles_screen.dart';
import 'package:proxima/screens/subscription_screen.dart';
import 'package:proxima/state/app_controller.dart';

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets('account destination preserves manual profiles at $width', (
      tester,
    ) async {
      tester.view
        ..physicalSize = Size(width, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = AppController(MethodChannelVpnBridge());
      final account = ProximaAccount();
      addTearDown(controller.dispose);
      addTearDown(account.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ProximaShell(controller: controller, account: account),
        ),
      );
      final navigation = width < 600
          ? find.byType(NavigationBar)
          : find.byType(NavigationRail);
      await tester.tap(
        find.descendant(of: navigation, matching: find.text('계정')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SubscriptionScreen), findsOneWidget);
      expect(account.signedIn, isFalse);
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.descendant(of: navigation, matching: find.text('프로필')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProfilesScreen), findsOneWidget);
      expect(account.signedIn, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
