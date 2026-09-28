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
            final body = Column(
              children: [
                if (widget.controller.message case final message?)
                  _MessageBanner(
                    message: message,
                    onClose: widget.controller.clearMessage,
                  ),
                Expanded(
                  child: FadeTransition(
                    opacity: _tabFade,
                    child: IndexedStack(index: _index, children: pages),
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

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: SafeArea(
        bottom: false,
        child: ListTile(
          leading: Icon(Icons.error_outline, color: colors.onErrorContainer),
          title: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: '닫기',
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ),
      ),
    );
  }
}
