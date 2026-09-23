import 'package:flutter/material.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.openProfiles,
    required this.openProxies,
    required this.openConnections,
  });

  final AppController controller;
  final VoidCallback openProfiles;
  final VoidCallback openProxies;
  final VoidCallback openConnections;

  String _status(VpnConnectionState state) => switch (state) {
    VpnConnectionState.disconnected => '연결되지 않음',
    VpnConnectionState.connecting => '연결 중',
    VpnConnectionState.connected => 'VPN으로 보호됨',
    VpnConnectionState.disconnecting => '연결 해제 중',
    VpnConnectionState.error => '연결 오류',
  };

  String _description(VpnConnectionState state) => switch (state) {
    VpnConnectionState.disconnected => '인터넷 트래픽이 VPN을 통과하지 않습니다.',
    VpnConnectionState.connecting => '프로필을 적용하고 보안 터널을 준비하고 있습니다.',
    VpnConnectionState.connected =>
      '${controller.snapshot.profileName ?? '선택한 프로필'}을 사용하고 있습니다.',
    VpnConnectionState.disconnecting => '네트워크 경로를 안전하게 정리하고 있습니다.',
    VpnConnectionState.error => controller.snapshot.error ?? '연결 설정을 확인해 주세요.',
  };

  String _uptime() {
    final startedAt = controller.snapshot.startedAt;
    if (startedAt == null || !controller.snapshot.isConnected) return '—';
    final elapsed = DateTime.now().difference(startedAt);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(elapsed.inHours)}:${two(elapsed.inMinutes.remainder(60))}:${two(elapsed.inSeconds.remainder(60))}';
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final active = controller.activeProfile;
    final proxyGroup = controller.currentProxyGroup;
    final proxyGroupName = controller.currentProxyGroupName;
    final activeNode = snapshot.isConnected ? snapshot.activeNode : null;
    final colors = Theme.of(context).colorScheme;
    return AppPage(
      title: 'Proxima',
      subtitle: 'VLESS + REALITY Android VPN 클라이언트',
      onRefresh: () async {
        await controller.reloadProfiles();
        if (controller.settings.mode != OutboundMode.direct) {
          await controller.loadProxyGroups();
        }
      },
      children: [
        Card(
          color: snapshot.isConnected
              ? colors.primaryContainer
              : snapshot.state == VpnConnectionState.error
              ? colors.errorContainer
              : colors.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  snapshot.isConnected
                      ? Icons.shield_rounded
                      : Icons.shield_outlined,
                  size: 40,
                  color: snapshot.isConnected
                      ? colors.onPrimaryContainer
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(height: 22),
                Text(
                  _status(snapshot.state),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  _description(snapshot.state),
                  style: TextStyle(
                    color: snapshot.isConnected
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: snapshot.isConnected
                      ? OutlinedButton.icon(
                          key: const Key('connect_button'),
                          onPressed: snapshot.isBusy
                              ? null
                              : controller.toggleVpn,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('연결 해제'),
                        )
                      : FilledButton.icon(
                          key: const Key('connect_button'),
                          onPressed: snapshot.isBusy
                              ? null
                              : controller.toggleVpn,
                          icon: snapshot.isBusy
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_arrow_rounded),
                          label: Text(snapshot.isBusy ? '연결 중…' : '연결'),
                        ),
                ),
              ],
            ),
          ),
        ),
        const SectionHeader('작동 모드'),
        SegmentedButton<OutboundMode>(
          segments: OutboundMode.values
              .map(
                (mode) => ButtonSegment<OutboundMode>(
                  value: mode,
                  label: Text(mode.label),
                  icon: Icon(switch (mode) {
                    OutboundMode.rule => Icons.rule_rounded,
                    OutboundMode.global => Icons.public_rounded,
                    OutboundMode.direct => Icons.arrow_forward_rounded,
                  }),
                ),
              )
              .toList(),
          selected: {controller.settings.mode},
          onSelectionChanged: snapshot.isBusy
              ? null
              : (selection) async {
                  try {
                    await controller.setMode(selection.first);
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('$error')));
                    }
                  }
                },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            controller.settings.mode.description,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
        const SectionHeader('현재 프로필'),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            leading: const Icon(Icons.description_outlined),
            title: Text(active?.name ?? '프로필 없음'),
            subtitle: Text(active?.sourceLabel ?? '프로필을 추가해 주세요'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: openProfiles,
          ),
        ),
        if (proxyGroupName != null) ...[
          const SectionHeader('선택된 노드'),
          Card(
            child: ListTile(
              key: const Key('selected_node_tile'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
              leading: const Icon(Icons.public_rounded),
              title: Text(
                activeNode != null && activeNode.isNotEmpty
                    ? displayProxyName(activeNode)
                    : proxyGroup == null
                    ? '노드를 선택해 주세요'
                    : displayProxyName(proxyGroup.selected),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                activeNode == null && proxyGroup == null
                    ? '노드 정보를 불러오는 중입니다.'
                    : controller.settings.mode == OutboundMode.global
                    ? 'GLOBAL · 모든 트래픽에 사용할 노드'
                    : 'PROXY · 규칙 트래픽에 사용할 노드',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: snapshot.isBusy ? null : openProxies,
            ),
          ),
        ],
        if (controller.settings.mode == OutboundMode.rule) ...[
          const SectionHeader('규칙 라우팅'),
          const Card(
            child: ListTile(
              leading: Icon(Icons.rule_rounded),
              title: Text('규칙에 따라 자동 선택'),
              subtitle: Text('Clash 구독 또는 링크 목록에 입력한 규칙으로 경로를 선택합니다. 규칙이 없으면 기본 노드를 사용합니다.'),
            ),
          ),
        ],
        const SectionHeader('트래픽'),
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                icon: Icons.arrow_upward_rounded,
                label: '업로드',
                value: formatBytes(snapshot.uploadSpeed, perSecond: true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                icon: Icons.arrow_downward_rounded,
                label: '다운로드',
                value: formatBytes(snapshot.downloadSpeed, perSecond: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('연결 시간'),
                trailing: ListTileValueText(_uptime()),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.swap_horiz_rounded),
                title: const Text('Xray 코어'),
                subtitle: const Text('최근 Xray 연결과 사용 중인 메모리 확인'),
                trailing: ListTileValueText(
                  snapshot.isConnected ? '실행 중' : '정지됨',
                ),
                onTap: snapshot.isConnected ? openConnections : null,
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.data_usage_outlined),
                title: const Text('이번 연결'),
                trailing: ListTileValueText(
                  '↑ ${formatBytes(snapshot.totalUpload)}  ↓ ${formatBytes(snapshot.totalDownload)}',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
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
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
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
