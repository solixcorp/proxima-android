import 'package:flutter/material.dart';

import '../screens/connections_screen.dart';
import '../screens/home_screen.dart';
import '../screens/profiles_screen.dart';
import '../screens/proxies_screen.dart';
import '../screens/settings_screen.dart';
import '../state/app_controller.dart';

class ProximaShell extends StatefulWidget {
  const ProximaShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<ProximaShell> createState() => _ProximaShellState();
}

class _ProximaShellState extends State<ProximaShell> {
  int _index = 0;

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home_rounded),
      label: '홈',
    ),
    NavigationDestination(
      icon: Icon(Icons.alt_route_outlined),
      selectedIcon: Icon(Icons.alt_route_rounded),
      label: '노드',
    ),
    NavigationDestination(
      icon: Icon(Icons.swap_horiz_outlined),
      selectedIcon: Icon(Icons.swap_horiz_rounded),
      label: '연결',
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
    setState(() => _index = index);
    if (index == 1) widget.controller.loadProxyGroups();
    if (index == 2) widget.controller.loadConnections();
    if (index == 4) {
      widget.controller.refreshNetworkInfo();
      widget.controller.loadProviders();
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
            openProfiles: () => _select(3),
          ),
          ProxiesScreen(controller: widget.controller),
          ConnectionsScreen(controller: widget.controller),
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
                  child: IndexedStack(index: _index, children: pages),
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
