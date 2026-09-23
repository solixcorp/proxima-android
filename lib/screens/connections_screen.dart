import 'dart:async';

import 'package:flutter/material.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  final _search = TextEditingController();
  String _network = 'ALL';
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _search.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.snapshot.isConnected) {
        widget.controller.loadConnections(silent: true);
      }
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && widget.controller.snapshot.isConnected) {
        widget.controller.loadConnections(silent: true);
      }
    });
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _search
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final query = _search.text.trim().toLowerCase();
    final connections = controller.connectionOverview.connections.where((
      connection,
    ) {
      if (_network != 'ALL' && connection.network != _network) return false;
      if (query.isEmpty) return true;
      return [
        connection.destination,
        connection.process,
        connection.rule,
        connection.route,
      ].any((value) => value.toLowerCase().contains(query));
    }).toList();
    return AppPage(
      title: '연결',
      subtitle: 'Xray가 최근 관찰한 목적지와 현재 경로를 확인합니다.',
      onRefresh: controller.loadConnections,
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed: controller.snapshot.isConnected
              ? controller.loadConnections
              : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: !controller.snapshot.isConnected
          ? const [
              PageEmptyState(
                icon: Icons.swap_horiz_rounded,
                title: 'VPN이 연결되지 않았습니다',
                message: 'VPN을 연결하면 목적지, 규칙, 경로와 사용량이 여기에 표시됩니다.',
              ),
            ]
          : [
              Row(
                children: [
                  Expanded(
                    child: _SummaryCard(
                      label: '최근 Xray 연결',
                      value:
                          '${controller.connectionOverview.connections.length}',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _SummaryCard(
                      label: '메모리',
                      value: formatBytes(controller.connectionOverview.memory),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _search,
                decoration: const InputDecoration(
                  hintText: '목적지, 앱, 규칙 또는 경로 검색',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: ['ALL', 'TCP', 'UDP']
                      .map(
                        (value) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(value == 'ALL' ? '전체' : value),
                            selected: _network == value,
                            onSelected: (_) => setState(() => _network = value),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 8),
              if (controller.loadingConnections &&
                  controller.connectionOverview.connections.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (connections.isEmpty)
                const PageEmptyState(
                  icon: Icons.check_circle_outline_rounded,
                  title: '표시할 연결이 없습니다',
                  message: '앱에서 네트워크 요청을 시작한 뒤 새로고침해 보세요.',
                )
              else
                for (final connection in connections) ...[
                  _ConnectionCard(connection: connection),
                  const SizedBox(height: 10),
                ],
            ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.connection});

  final ActiveConnection connection;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    connection.destination,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (connection.process.isNotEmpty)
              Text(
                connection.process,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Tag(
                  connection.network.isEmpty
                      ? connection.type
                      : connection.network,
                ),
                _Tag(
                  connection.rulePayload.isEmpty
                      ? connection.rule
                      : '${connection.rule} · ${connection.rulePayload}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.alt_route_rounded, size: 18, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connection.route,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '↑ ${formatBytes(connection.upload)}  ↓ ${formatBytes(connection.download)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text.isEmpty ? 'MATCH' : text,
        style: Theme.of(context).textTheme.labelMedium,
      ),
    );
  }
}
