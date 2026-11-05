import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/widgets/account_text.dart';

const _style = TextStyle(fontFamily: 'Ahem', fontSize: 20, height: 1);

Widget _surface(
  String text, {
  double width = 400,
  TextStyle? style,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: DefaultTextStyle(
            style: _style,
            child: AccountText(text, style: style),
          ),
        ),
      ),
    ),
  );
}

RenderParagraph _paragraph(WidgetTester tester) {
  return tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byType(AccountText),
      matching: find.byType(RichText),
    ),
  );
}

Completer<String> _clipboardWrite(WidgetTester tester) {
  final written = Completer<String>();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        final data = call.arguments as Map<dynamic, dynamic>;
        written.complete(data['text'] as String);
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  return written;
}

void main() {
  testWidgets('Korean tokens move intact to the next whitespace boundary', (
    tester,
  ) async {
    for (final token in ['싶어요', '선택해', '없습니다']) {
      final measure = TextPainter(
        text: TextSpan(text: token, style: _style),
        textDirection: TextDirection.ltr,
      )..layout();
      final width = measure.width + 20;
      measure.dispose();
      await tester.pumpWidget(_surface('가 $token', width: width));
      final paragraph = _paragraph(tester);
      final rendered = paragraph.text.toPlainText();
      final start = rendered.indexOf(token[0]);
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: rendered.length),
      );
      expect(boxes, hasLength(1), reason: 'A token must occupy one line');
      expect(boxes.single.top, greaterThan(0));
      expect(boxes.single.right, lessThanOrEqualTo(width));
      expect(paragraph.text.style?.fontSize, _style.fontSize);

      // The same geometry without protection reproduces the original split.
      final unprotected = TextPainter(
        text: TextSpan(text: '가 $token', style: _style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      expect(
        unprotected.getBoxesForSelection(
          TextSelection(baseOffset: 2, extentOffset: 2 + token.length),
        ).length,
        greaterThan(1),
      );
      unprotected.dispose();
    }
  });

  testWidgets('semantics stays original and explicit style is applied', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      const original = '가나다 라마\u2060바 🙂';
      await tester.pumpWidget(
        _surface(original, style: const TextStyle(fontSize: 24)),
      );
      expect(find.bySemanticsLabel(original), findsOneWidget);
      expect(_paragraph(tester).text.toPlainText(), contains('가\u2060나'));
      expect(_paragraph(tester).text.style?.fontSize, 24);
      expect(_paragraph(tester).text.style?.fontFamily, _style.fontFamily);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('oversized unbroken strings still wrap within the body', (
    tester,
  ) async {
    for (final text in ['가나다라마바사아자차카타파하' * 3, 'abcdefgh' * 10]) {
      await tester.pumpWidget(_surface(text, width: 80));
      final paragraph = _paragraph(tester);
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      );
      expect(boxes.length, greaterThan(1));
      for (final box in boxes) {
        expect(box.left, greaterThanOrEqualTo(0));
        expect(box.right, lessThanOrEqualTo(80));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('toolbar copy writes original text and clears Android selection', (
    tester,
  ) async {
    const original = '가나다 라마\u2060바 🙂\n사아';
    final written = _clipboardWrite(tester);
    await tester.pumpWidget(_surface(original));
    // Nested selection containers register at framework frame boundaries.
    await tester.pump();
    await tester.tap(find.byType(AccountText));
    await tester.pump();
    final region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(await written.future.timeout(const Duration(seconds: 5)), original);
    final listener = tester.widget<SelectionListener>(
      find.byType(SelectionListener),
    );
    expect(listener.selectionNotifier.selection.range, isNull);
  });

  testWidgets(
    'keyboard copy preserves partial selection across a parent rebuild',
    (tester) async {
      const original = '앞 가나다\u2060라마 🙂 뒤';
      const selected = '가나다\u2060라마 🙂';
      final written = _clipboardWrite(tester);
      await tester.pumpWidget(_surface(original));
      await tester.pump();
      final paragraph = _paragraph(tester);
      final rendered = paragraph.text.toPlainText();
      final start = rendered.indexOf('가');
      final end = rendered.indexOf(' 뒤');
      Offset position(int offset) => paragraph.localToGlobal(
        paragraph.getOffsetForCaret(
              TextPosition(offset: offset),
              Rect.zero,
            ) +
            Offset(0, paragraph.preferredLineHeight / 2),
      );
      final reverse = defaultTargetPlatform == TargetPlatform.macOS;
      final gesture = await tester.startGesture(
        position(reverse ? end : start),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(position(reverse ? start : end));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      final region = tester.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      final notifier = tester
          .widget<SelectionListener>(find.byType(SelectionListener))
          .selectionNotifier;
      final before = notifier.selection.range!;
      expect(
        {before.startOffset, before.endOffset},
        {start, end},
      );

      await tester.pumpWidget(
        _surface(original, style: const TextStyle(color: Colors.blue)),
      );
      expect(
        tester.state<SelectableRegionState>(find.byType(SelectableRegion)),
        same(region),
      );
      final after = notifier.selection.range!;
      expect(after.startOffset, before.startOffset);
      expect(after.endOffset, before.endOffset);

      final modifier = reverse
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(await written.future.timeout(const Duration(seconds: 5)), selected);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );
}
