import 'package:flutter/material.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';
import '../widgets/app_motion.dart';

class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _refresh(BuildContext context) async {
    final profile = controller.activeProfile;
    if (profile?.sourceUrl?.isEmpty != false) return;
    try {
      await controller.refreshProfile(profile!);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('구독 정보를 업데이트했습니다.')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('업데이트 실패: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = controller.activeProfile;
    final info = profile?.subscriptionInfo;
    final hasSubscription = profile?.isSubscription == true;
    final canRefresh =
        profile?.sourceUrl?.trim().isNotEmpty == true &&
        !controller.snapshot.isBusy;
    return AppPage(
      title: '구독',
      subtitle: '현재 프로필의 플랜과 사용량을 확인합니다.',
      onRefresh: hasSubscription && canRefresh
          ? () => _refresh(context)
          : controller.reloadProfiles,
      actions: [
        IconButton(
          tooltip: '구독 업데이트',
          onPressed: canRefresh ? () => _refresh(context) : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        _ConnectionStatusCard(controller: controller),
        const SectionHeader('현재 프로필'),
        if (profile == null)
          const PageEmptyState(
            icon: Icons.data_usage_outlined,
            title: '선택된 프로필이 없습니다',
            message: '프로필 탭에서 VLESS + REALITY 구독을 추가해 주세요.',
          )
        else ...[
          _ProfileCard(profile: profile),
          const SectionHeader('사용량'),
          if (info == null || !info.hasDetails)
            PageEmptyState(
              icon: Icons.query_stats_outlined,
              title: hasSubscription ? '구독 정보가 없습니다' : '사용량 정보가 없습니다',
              message: hasSubscription
                  ? canRefresh
                        ? '업데이트를 눌러 구독 서버의 사용량 정보를 가져와 주세요.'
                        : '이전 버전에서 가져온 구독입니다. 프로필 편집에서 HTTPS 구독 주소를 연결하면 업데이트할 수 있습니다.'
                  : '이 VLESS 링크는 사용량 정보를 제공하지 않습니다.',
              action: FilledButton.icon(
                onPressed: canRefresh ? () => _refresh(context) : null,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(hasSubscription ? '구독 업데이트' : '구독 주소 필요'),
              ),
            )
          else
            _UsageCard(info: info),
        ],
      ],
    );
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({required this.controller});

  final AppController controller;

  String get _connectionLabel => switch (controller.snapshot.state) {
    VpnConnectionState.disconnected => '연결되지 않음',
    VpnConnectionState.connecting => '연결 중',
    VpnConnectionState.connected => 'VPN으로 보호됨',
    VpnConnectionState.disconnecting => '연결 해제 중',
    VpnConnectionState.error => '연결 오류',
  };

  String get _nodeLabel {
    if (controller.settings.mode == OutboundMode.direct) return '직접 연결';
    if (controller.settings.mode == OutboundMode.rule) return '규칙에 따라 자동 선택';
    final active = controller.snapshot.activeNode;
    if (controller.snapshot.isConnected &&
        active != null &&
        active.isNotEmpty) {
      return displayProxyName(active);
    }
    final selected = controller.currentProxyGroup?.selected;
    return selected == null ? '정보 없음' : displayProxyName(selected);
  }

  String get _modeLabel {
    final activeMode = controller.snapshot.activeMode;
    if (controller.snapshot.isConnected && activeMode != null) {
      return OutboundMode.fromWire(activeMode).label;
    }
    return controller.settings.mode.label;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('subscription_status_card'),
      child: Column(
        children: [
          _InfoRow(
            icon: Icons.shield_outlined,
            label: '연결 상태',
            value: _connectionLabel,
          ),
          const Divider(height: 1, indent: 56),
          _InfoRow(
            icon: Icons.alt_route_rounded,
            label: '작동 모드',
            value: _modeLabel,
          ),
          const Divider(height: 1, indent: 56),
          _InfoRow(
            icon: Icons.public_rounded,
            label: '선택 노드',
            value: _nodeLabel,
          ),
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});

  final VpnProfile profile;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        leading: const Icon(Icons.description_outlined),
        title: Text(profile.name),
        subtitle: Text(profile.sourceLabel),
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.info});

  final SubscriptionInfo info;

  @override
  Widget build(BuildContext context) {
    final percent = info.hasTraffic
        ? (info.used / info.total).clamp(0, 1).toDouble()
        : 0.0;
    final expiresIn = info.expire?.difference(DateTime.now()).inDays;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            if (info.planName case final plan?)
              _InfoRow(
                icon: Icons.workspace_premium_outlined,
                label: '플랜',
                value: plan,
              ),
            if (info.hasTraffic) ...[
              _InfoRow(
                icon: Icons.data_usage_outlined,
                label: '남은 트래픽',
                value: formatBytes(info.remaining),
                detail:
                    '사용 ${formatBytes(info.used)} / ${formatBytes(info.total)}',
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: percent),
                  duration: AppMotion.medium(context),
                  curve: Curves.easeInOutCubic,
                  builder: (context, value, _) =>
                      LinearProgressIndicator(value: value),
                ),
              ),
            ],
            if (info.expire case final expire?)
              _InfoRow(
                icon: Icons.event_outlined,
                label: '만료일',
                value: formatSubscriptionExpiry(expire),
                detail: expiresIn == null
                    ? null
                    : expiresIn >= 0
                    ? '$expiresIn일 남음'
                    : '만료됨',
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: detail == null ? null : Text(detail!),
      trailing: ListTileValueText(value),
    );
  }
}
