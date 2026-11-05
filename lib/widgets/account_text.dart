import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Selectable body text that keeps adjacent Korean syllables together.
///
/// Word joiners affect layout only. Semantics and copied selections use the
/// original text, including any word joiners that were already in the input.
class AccountText extends StatefulWidget {
  const AccountText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<AccountText> createState() => _AccountTextState();
}

class _AccountTextState extends State<AccountText> {
  final _selection = SelectionListenerNotifier();
  final _originalOffsets = <int>[];

  static bool _isHangul(int unit) => unit >= 0xac00 && unit <= 0xd7a3;

  String _renderText() {
    final buffer = StringBuffer();
    _originalOffsets
      ..clear()
      ..add(0);
    for (var i = 0; i < widget.text.length; i++) {
      buffer.writeCharCode(widget.text.codeUnitAt(i));
      _originalOffsets.add(i + 1);
      if (i + 1 < widget.text.length &&
          _isHangul(widget.text.codeUnitAt(i)) &&
          _isHangul(widget.text.codeUnitAt(i + 1))) {
        buffer.write('\u2060');
        _originalOffsets.add(i + 1);
      }
    }
    return buffer.toString();
  }

  Future<void> _copy() async {
    final range = _selection.selection.range;
    if (range == null || range.startOffset == range.endOffset) return;
    final start = _originalOffsets[range.startOffset];
    final end = _originalOffsets[range.endOffset];
    await Clipboard.setData(
      ClipboardData(
        text: widget.text.substring(
          start < end ? start : end,
          start < end ? end : start,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (_) => _copy(),
        ),
      },
      child: SelectionArea(
        contextMenuBuilder: (context, region) {
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: region.contextMenuAnchors,
            buttonItems: [
              for (final item in region.contextMenuButtonItems)
                if (item.type == ContextMenuButtonType.copy)
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    onPressed: () {
                      _copy();
                      switch (defaultTargetPlatform) {
                        case TargetPlatform.android:
                        case TargetPlatform.fuchsia:
                          region.clearSelection();
                          region.hideToolbar();
                        case TargetPlatform.iOS:
                          region.hideToolbar(false);
                        case TargetPlatform.linux:
                        case TargetPlatform.macOS:
                        case TargetPlatform.windows:
                          region.hideToolbar();
                      }
                    },
                  )
                else
                  item,
            ],
          );
        },
        child: SelectionListener(
          selectionNotifier: _selection,
          child: Text(
            _renderText(),
            style: widget.style,
            semanticsLabel: widget.text,
          ),
        ),
      ),
    );
  }
}
