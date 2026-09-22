import 'package:flutter/material.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';

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
    final canRefresh = profile?.sourceUrl?.isNotEmpty == true;
    return AppPage(
      title: '구독',
      subtitle: '현재 프로필의 플랜과 사용량을 확인합니다.',
      onRefresh: canRefresh
          ? () => _refresh(context)
          : controller.reloadProfiles,
      actions: [
        IconButton(
          tooltip: '구독 업데이트',
          onPressed: canRefresh ? () => _refresh(context) : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: profile == null
          ? const [
              PageEmptyState(
                icon: Icons.data_usage_outlined,
                title: '선택된 프로필이 없습니다',
                message: '프로필 탭에서 VLESS + REALITY 구독을 추가해 주세요.',
              ),
            ]
          : !canRefresh
          ? const [
              PageEmptyState(
                icon: Icons.link_off_outlined,
                title: '구독 프로필이 아닙니다',
                message: 'HTTPS 구독 주소로 추가한 프로필에서 사용량을 확인할 수 있습니다.',
              ),
            ]
          : info == null || !info.hasDetails
          ? [
              PageEmptyState(
                icon: Icons.query_stats_outlined,
                title: '구독 정보가 없습니다',
                message: '업데이트를 눌러 구독 서버의 사용량 정보를 가져와 주세요.',
                action: FilledButton.icon(
                  onPressed: () => _refresh(context),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('구독 업데이트'),
                ),
              ),
            ]
          : [
              _ProfileCard(profile: profile),
              const SectionHeader('사용량'),
              _UsageCard(info: info),
            ],
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
                child: LinearProgressIndicator(value: percent),
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
