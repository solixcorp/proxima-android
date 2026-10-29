import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/proxima_account.dart';
import 'package:proxima/widgets/proxima_account_card.dart';

void main() {
  for (final width in [390.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('account states fit $width in $brightness', (tester) async {
        tester.view
          ..physicalSize = Size(width, 1000)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final account = _Account();
        addTearDown(account.dispose);

        await tester.pumpWidget(
          _surface(account, brightness: brightness),
        );
        await tester.tap(find.byKey(const Key('proxima_sign_in')));
        expect(account.logins, 1);
        expect(tester.takeException(), isNull);

        account
          ..connected = true
          ..profile = {
            'name': 'Proxima 계정',
            'email': 'long.account.name@example.com',
          }
          ..summary = {
            'plan_name': 'Standard',
            'traffic_used': 12884901888,
            'traffic_limit': 107374182400,
            'plan_expires_at': '2026-11-26T03:00:00Z',
          }
          ..subscriptionUrl = 'https://sub.example.com/sub/account';
        account.changed();
        await tester.pump();
        expect(find.text('long.account.name@example.com'), findsOneWidget);
        expect(
          tester.widget<SelectableText>(
            find.byType(SelectableText),
          ).style?.fontSize,
          greaterThanOrEqualTo(15),
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                widget.data == 'long.account.name@example.com',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Standard'), findsOneWidget);
        expect(find.byKey(const Key('proxima_sign_in')), findsNothing);
        expect(tester.takeException(), isNull);

        account
          ..error = 'test network failure'
          ..busy = true;
        account.changed();
        await tester.pump();
        final button = tester.widget<FilledButton>(
          find.byKey(const Key('proxima_import_subscription')),
        );
        expect(button.onPressed, isNull);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(
          find.text(
            tester.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            ).semanticsLabel!,
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            tester.widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            ).semanticsLabel!,
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SelectableText &&
                widget.data == 'test network failure',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('import passes account URL once and blocks duplicate actions', (
    tester,
  ) async {
    final account = _Account()
      ..connected = true
      ..subscriptionUrl = 'https://sub.example.com/sub/account';
    addTearDown(account.dispose);
    final imported = <String>[];
    final finished = Completer<void>();
    addTearDown(() {
      if (!finished.isCompleted) finished.complete();
    });
    await tester.pumpWidget(
      _surface(
        account,
        onImport: (url) async {
          imported.add(url);
          await finished.future;
        },
      ),
    );

    final action = find.byKey(const Key('proxima_import_subscription'));
    await tester.tap(action);
    await tester.pump();
    expect(imported, [account.subscriptionUrl]);
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    finished.complete();
    await tester.pump();
    expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('missing subscription or VPN transition disables importing', (
    tester,
  ) async {
    final account = _Account()..connected = true;
    addTearDown(account.dispose);
    await tester.pumpWidget(_surface(account));
    final action = find.byKey(const Key('proxima_import_subscription'));
    expect(tester.widget<FilledButton>(action).onPressed, isNull);

    account.subscriptionUrl = 'https://sub.example.com/sub/account';
    await tester.pumpWidget(_surface(account, canImport: false));
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
  });

  testWidgets('import feedback is cleared when the account changes', (
    tester,
  ) async {
    final account = _Account()
      ..connected = true
      ..profile = {'id': 'first-account'}
      ..subscriptionUrl = 'https://sub.example.com/sub/account';
    addTearDown(account.dispose);
    await tester.pumpWidget(_surface(account));
    await tester.tap(find.byKey(const Key('proxima_import_subscription')));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);

    account
      ..connected = false
      ..profile = null;
    account.changed();
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byKey(const Key('proxima_sign_in')), findsOneWidget);

    account
      ..connected = true
      ..profile = {'id': 'second-account'};
    account.changed();
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('import state failures retain the actionable cause', (
    tester,
  ) async {
    final account = _Account()
      ..connected = true
      ..subscriptionUrl = 'https://sub.example.com/sub/account';
    addTearDown(account.dispose);
    const cause = 'test_import_state_blocked';
    await tester.pumpWidget(
      _surface(account, onImport: (_) async => throw StateError(cause)),
    );

    await tester.tap(find.byKey(const Key('proxima_import_subscription')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      cause,
    );
  });

  testWidgets('account feedback resizes smoothly and can be interrupted', (
    tester,
  ) async {
    final account = _Account();
    addTearDown(account.dispose);
    await tester.pumpWidget(_surface(account));
    final animated = find.byType(AnimatedSize);
    final initialHeight = tester.getSize(animated).height;

    account.error = 'test_feedback';
    account.changed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final middleHeight = tester.getSize(animated).height;
    expect(middleHeight, greaterThan(initialHeight));

    account.error = null;
    account.changed();
    await tester.pumpAndSettle();
    expect(tester.getSize(animated).height, initialHeight);
  });

  testWidgets('account feedback respects disabled system animations', (
    tester,
  ) async {
    final account = _Account();
    addTearDown(account.dispose);
    await tester.pumpWidget(_surface(account, disableAnimations: true));
    expect(
      tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
      Duration.zero,
    );
  });
}

Widget _surface(
  ProximaAccount account, {
  Brightness brightness = Brightness.light,
  bool canImport = true,
  bool disableAnimations = false,
  Future<void> Function(String)? onImport,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
    child: child!,
  ),
  theme: ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF35618B),
      brightness: brightness,
    ),
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ProximaAccountCard(
        account: account,
        canImport: canImport,
        onImport: onImport ?? (_) async {},
      ),
    ),
  ),
);

class _Account extends ProximaAccount {
  bool connected = false;
  int logins = 0;

  @override
  bool get signedIn => connected;

  @override
  Future<void> signIn() async => logins++;

  void changed() => notifyListeners();
}
