import 'dart:async';

import 'package:flutter/material.dart';

class DelayedProgressIndicator extends StatefulWidget {
  const DelayedProgressIndicator({
    super.key,
    required this.semanticsLabel,
    this.size = 36,
  });

  final String semanticsLabel;
  final double size;

  @override
  State<DelayedProgressIndicator> createState() =>
      _DelayedProgressIndicatorState();
}

class _DelayedProgressIndicatorState extends State<DelayedProgressIndicator> {
  late final Timer _delay;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _delay = Timer(const Duration(seconds: 1), () {
      setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _delay.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: _visible
        ? CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: widget.semanticsLabel,
          )
        : null,
  );
}

class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.actions = const [],
    this.onRefresh,
    this.floatingActionButton,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget> actions;
  final RefreshCallback? onRefresh;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final titleSize = textTheme.titleMedium?.fontSize ?? 16;
    final subtitleSize = textTheme.bodyMedium?.fontSize ?? 14;
    final extraTitleHeight =
        (scaler.scale(titleSize) - titleSize) *
        (textTheme.titleMedium?.height ?? 1.5);
    final extraSubtitleHeight = subtitle == null
        ? 0
        : (scaler.scale(subtitleSize) - subtitleSize) *
              (textTheme.bodyMedium?.height ?? 1.5);
    final double expandedHeight =
        (subtitle != null ? 132.0 : 108.0) +
        (extraTitleHeight + extraSubtitleHeight).clamp(0, double.infinity);
    final toolbarHeight =
        kToolbarHeight + extraTitleHeight.clamp(0, double.infinity);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 400;
        final scrollView = CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              toolbarHeight: toolbarHeight,
              expandedHeight: compact ? toolbarHeight : expandedHeight,
              scrolledUnderElevation: 0,
              title: compact
                  ? Text(
                      title,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
              actions: [
                ...actions,
                if (compact && floatingActionButton != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: floatingActionButton!,
                  ),
              ],
              flexibleSpace: compact
                  ? null
                  : _AppPageFlexibleTitle(
                      title: title,
                      subtitle: subtitle,
                    ),
            ),
            if (compact && subtitle != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    subtitle!,
                    style: textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                !compact && floatingActionButton != null ? 104 : 24,
              ),
              sliver: SliverList.list(children: children),
            ),
          ],
        );
        return Scaffold(
          body: SafeArea(
            top: false,
            child: onRefresh == null
                ? scrollView
                : RefreshIndicator(onRefresh: onRefresh!, child: scrollView),
          ),
          floatingActionButton: compact ? null : floatingActionButton,
        );
      },
    );
  }
}

class _AppPageFlexibleTitle extends StatelessWidget {
  const _AppPageFlexibleTitle({
    required this.title,
    this.subtitle,
  });

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final settings = context
        .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    if (settings == null) {
      return const SizedBox.shrink();
    }

    final double delta = settings.maxExtent - settings.minExtent;
    final double t = delta > 0
        ? ((settings.currentExtent - settings.minExtent) / delta).clamp(
            0.0,
            1.0,
          )
        : 0.0;

    final bool hasLeading = ModalRoute.of(context)?.canPop ?? false;
    final double collapsedLeft = hasLeading ? 56.0 : 20.0;
    final double expandedLeft = 20.0;

    // t = 1.0 (Expanded), t = 0.0 (Collapsed)
    final double currentLeft =
        collapsedLeft + (expandedLeft - collapsedLeft) * t;

    final double expandedScale =
        32 / (textTheme.titleMedium?.fontSize ?? 16);
    final double scale = 1.0 + (expandedScale - 1.0) * t;

    final double topPadding = MediaQuery.paddingOf(context).top;

    final scaler = MediaQuery.textScalerOf(context);
    final double fontHeight = scaler.scale(
      textTheme.titleMedium?.fontSize ?? 16,
    );
    final titleLineHeight = fontHeight * (textTheme.titleMedium?.height ?? 1.5);
    final subtitleLineHeight =
        scaler.scale(textTheme.bodyMedium?.fontSize ?? 14) *
        (textTheme.bodyMedium?.height ?? 1.5);
    final double collapsedTop =
        topPadding + (settings.minExtent - topPadding - titleLineHeight) / 2;
    final double expandedTop =
        settings.maxExtent -
        (titleLineHeight * expandedScale +
            (subtitle != null ? 6 + subtitleLineHeight : 0) +
            12);

    final double currentTop = collapsedTop + (expandedTop - collapsedTop) * t;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (subtitle != null)
          Positioned(
            left: 20,
            right: 20,
            top: currentTop + titleLineHeight * scale + 6,
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        Positioned(
          left: currentLeft,
          right: 20 + (1 - t) * 56,
          top: currentTop,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.titleMedium?.copyWith(
              fontSize: (textTheme.titleMedium?.fontSize ?? 16) * scale,
              color: colorScheme.onSurface,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?action,
        ],
      ),
    );
  }
}

class ListTileValueText extends StatelessWidget {
  const ListTileValueText(this.value, {super.key});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      textAlign: TextAlign.end,
      style: Theme.of(context).textTheme.bodyLarge,
    );
  }
}

class AppValueTile extends StatelessWidget {
  const AppValueTile({
    super.key,
    required this.leading,
    required this.title,
    required this.value,
    this.subtitle,
    this.onTap,
  });

  final Widget leading;
  final String title;
  final String value;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(14) > 18;
        return ListTile(
          leading: leading,
          title: Text(title),
          subtitle: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: Theme.of(context).textTheme.bodyLarge),
                    if (subtitle != null) Text(subtitle!),
                  ],
                )
              : subtitle == null
              ? null
              : Text(subtitle!),
          trailing: stacked
              ? null
              : ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.45,
                  ),
                  child: ListTileValueText(value),
                ),
          onTap: onTap,
        );
      },
    );
  }
}

class PageEmptyState extends StatelessWidget {
  const PageEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: MediaQuery.sizeOf(context).height < 500 ? 16 : 56,
        horizontal: 24,
      ),
      child: Column(
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(height: 20),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}
