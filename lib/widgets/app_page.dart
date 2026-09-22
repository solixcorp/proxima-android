import 'package:flutter/material.dart';

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
    final double expandedHeight = subtitle != null ? 132.0 : 108.0;

    final scrollView = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: expandedHeight,
          scrolledUnderElevation: 0,
          actions: actions,
          flexibleSpace: _AppPageFlexibleTitle(
            title: title,
            subtitle: subtitle,
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
          sliver: SliverList.list(children: children),
        ),
      ],
    );
    return Scaffold(
      body: onRefresh == null
          ? scrollView
          : RefreshIndicator(onRefresh: onRefresh!, child: scrollView),
      floatingActionButton: floatingActionButton,
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
    final settings =
        context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    if (settings == null) {
      return const SizedBox.shrink();
    }

    final double delta = settings.maxExtent - settings.minExtent;
    final double t = delta > 0
        ? ((settings.currentExtent - settings.minExtent) / delta).clamp(0.0, 1.0)
        : 0.0;

    final bool hasLeading = ModalRoute.of(context)?.canPop ?? false;
    final double collapsedLeft = hasLeading ? 56.0 : 20.0;
    final double expandedLeft = 20.0;

    // t = 1.0 (Expanded), t = 0.0 (Collapsed)
    final double currentLeft =
        collapsedLeft + (expandedLeft - collapsedLeft) * t;

    // Scale from 1.0 (Collapsed: titleLarge size) to 1.35 (Expanded)
    final double scale = 1.0 + 0.35 * t;

    final double topPadding = MediaQuery.paddingOf(context).top;

    final double fontHeight = textTheme.titleLarge?.fontSize ?? 22.0;
    final double collapsedTop = topPadding + (kToolbarHeight - fontHeight) / 2;
    final double expandedTop =
        settings.maxExtent - (subtitle != null ? 60.0 : 38.0);

    final double currentTop = collapsedTop + (expandedTop - collapsedTop) * t;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (subtitle != null)
          Positioned(
            left: 20,
            right: 20,
            top: currentTop + 30.0 * scale,
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
          top: currentTop,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
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
      padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
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
