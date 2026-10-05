import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/home_screen.dart';
import '../screens/connections_screen.dart';
import '../screens/profiles_screen.dart';
import '../screens/proxies_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/subscription_screen.dart';
import '../state/app_controller.dart';
import '../widgets/app_motion.dart';

class ProximaShell extends StatefulWidget {
  const ProximaShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<ProximaShell> createState() => _ProximaShellState();
}

class _ProximaShellState extends State<ProximaShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  late final AnimationController _tabFade;

  @override
  void initState() {
    super.initState();
    _tabFade = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 180),
    );
  }

  @override
  void dispose() {
    _tabFade.dispose();
    super.dispose();
  }

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home_rounded),
      label: '홈',
    ),
    NavigationDestination(
      icon: Icon(Icons.data_usage_outlined),
      selectedIcon: Icon(Icons.data_usage_rounded),
      label: '구독',
    ),
    NavigationDestination(
      icon: Icon(Icons.description_outlined),
      selectedIcon: Icon(Icons.description_rounded),
      label: '프로필',
    ),
    NavigationDestination(
      icon: Icon(Icons.more_horiz_rounded),
      selectedIcon: Icon(Icons.more_horiz),
      label: '더보기',
    ),
  ];

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    if (MediaQuery.maybeOf(context)?.disableAnimations == true) {
      _tabFade.value = 1;
    } else {
      _tabFade
        ..duration = AppMotion.short(context)
        ..forward(from: 0);
    }
    if (index == 3) {
      widget.controller.refreshNetworkInfo();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final pages = [
          HomeScreen(
            controller: widget.controller,
            openProfiles: () => _select(2),
            openProxies: () {
              widget.controller.loadProxyGroups();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProxiesScreen(controller: widget.controller),
                ),
              );
            },
            openConnections: () {
              widget.controller.loadConnections();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      ConnectionsScreen(controller: widget.controller),
                ),
              );
            },
          ),
          SubscriptionScreen(controller: widget.controller),
          ProfilesScreen(controller: widget.controller),
          SettingsScreen(controller: widget.controller),
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            final useRail = constraints.maxWidth >= 600;
            final body = Stack(
              children: [
                Positioned.fill(
                  child: FadeTransition(
                    opacity: _tabFade,
                    child: IndexedStack(index: _index, children: pages),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    reverseDuration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final slide = Tween<Offset>(
                        begin: const Offset(0, -1),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                          reverseCurve: Curves.easeInCubic,
                        ),
                      );
                      return SizeTransition(
                        sizeFactor: animation,
                        alignment: AlignmentDirectional.topStart,
                        child: SlideTransition(
                          position: slide,
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: switch (widget.controller.message) {
                      final message? => _MessageBanner(
                        key: ValueKey(message),
                        message: message,
                        onClose: widget.controller.clearMessage,
                      ),
                      null => const SizedBox.shrink(key: ValueKey('no-message')),
                    },
                  ),
                ),
              ],
            );
            return Scaffold(
              body: SafeArea(
                top: false,
                child: useRail
                    ? Row(
                        children: [
                          NavigationRail(
                            selectedIndex: _index,
                            onDestinationSelected: _select,
                            labelType: NavigationRailLabelType.all,
                            leading: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: _AppMark(),
                            ),
                            destinations: _destinations
                                .map(
                                  (item) => NavigationRailDestination(
                                    icon: item.icon,
                                    selectedIcon: item.selectedIcon,
                                    label: Text(item.label),
                                  ),
                                )
                                .toList(),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: body),
                        ],
                      )
                    : body,
              ),
              bottomNavigationBar: useRail
                  ? null
                  : NavigationBar(
                      selectedIndex: _index,
                      onDestinationSelected: _select,
                      destinations: _destinations,
                    ),
            );
          },
        );
      },
    );
  }
}

class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Proxima',
      child: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
        child: const Icon(Icons.shield_outlined),
      ),
    );
  }
}

class _MessageBanner extends StatefulWidget {
  const _MessageBanner({
    super.key,
    required this.message,
    required this.onClose,
  });

  final String message;
  final VoidCallback onClose;

  @override
  State<_MessageBanner> createState() => _MessageBannerState();
}

class _MessageBannerState extends State<_MessageBanner> {
  Timer? _dismissTimer;
  bool _visible = true;

  static const _dismissDuration = Duration(milliseconds: 260);

  @override
  void initState() {
    super.initState();
    _scheduleDismiss();
  }

  @override
  void didUpdateWidget(covariant _MessageBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message != widget.message) {
      _scheduleDismiss();
    }
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    _visible = true;
    _dismissTimer = Timer(const Duration(seconds: 3), _dismiss);
  }

  void _dismiss() {
    if (!_visible) return;
    setState(() => _visible = false);
    _dismissTimer = Timer(_dismissDuration, widget.onClose);
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRect(
      child: AnimatedSize(
        duration: _dismissDuration,
        curve: Curves.easeInCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSlide(
          duration: _dismissDuration,
          curve: Curves.easeInCubic,
          offset: _visible ? Offset.zero : const Offset(0, -1),
          child: AnimatedOpacity(
            duration: _dismissDuration,
            curve: Curves.easeInCubic,
            opacity: _visible ? 1 : 0,
            child: Material(
              color: colors.errorContainer,
              child: SafeArea(
                bottom: false,
                child: ListTile(
                  leading: Icon(Icons.error_outline, color: colors.onErrorContainer),
                  title: Text(
                    widget.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '닫기',
                    onPressed: _dismiss,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
