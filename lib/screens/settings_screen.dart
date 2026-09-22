import 'package:flutter/material.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _requestTile(BuildContext context) async {
    final added = await controller.requestQuickSettingsTile();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added
                ? '빠른 설정에 Proxima 타일을 추가했습니다.'
                : '빠른 설정 편집 화면에서 Proxima 타일을 직접 추가해 주세요.',
          ),
        ),
      );
    }
  }

  Future<void> _updateProvider(
    BuildContext context,
    CoreProvider provider,
  ) async {
    try {
      await controller.updateProvider(provider);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${provider.name} 업데이트 완료')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    final network = controller.networkInfo;
    return AppPage(
      title: '더보기',
      subtitle: '네트워크 도구, Provider와 터널 설정을 관리합니다.',
      onRefresh: () async {
        await controller.refreshNetworkInfo();
        if (controller.snapshot.isConnected) await controller.loadProviders();
      },
      children: [
        const SectionHeader('네트워크'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.wifi_rounded),
                title: Text(network.transport),
                subtitle: Text(network.validated ? '인터넷 연결 확인됨' : '인터넷 연결 미확인'),
                trailing: network.metered
                    ? const ListTileValueText('종량제')
                    : null,
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('시스템 DNS'),
                subtitle: Text(
                  network.dnsServers.isEmpty
                      ? '확인할 수 없음'
                      : network.dnsServers.join(', '),
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.public_rounded),
                title: const Text('VPN 외부 IP'),
                subtitle: Text(_publicIpLabel(controller.publicIp)),
                trailing: controller.loadingPublicIp
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: controller.snapshot.isConnected
                            ? controller.probePublicIp
                            : null,
                        child: const Text('확인'),
                      ),
              ),
            ],
          ),
        ),
        const SectionHeader('Provider'),
        if (!controller.snapshot.isConnected)
          const Card(
            child: ListTile(
              leading: Icon(Icons.cloud_off_outlined),
              title: Text('VPN 연결 필요'),
              subtitle: Text('연결 후 프록시 및 규칙 Provider를 관리할 수 있습니다.'),
            ),
          )
        else if (controller.loadingProviders && controller.providers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (controller.providers.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.inventory_2_outlined),
              title: Text('외부 Provider 없음'),
              subtitle: Text('현재 프로필은 외부 Provider를 사용하지 않습니다.'),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (
                  var index = 0;
                  index < controller.providers.length;
                  index++
                ) ...[
                  ListTile(
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Text(controller.providers[index].name),
                    subtitle: Text(
                      '${controller.providers[index].type} · ${controller.providers[index].vehicleType} · ${controller.providers[index].count}개',
                    ),
                    trailing: IconButton(
                      tooltip: '업데이트',
                      onPressed: () =>
                          _updateProvider(context, controller.providers[index]),
                      icon: const Icon(Icons.sync_rounded),
                    ),
                  ),
                  if (index < controller.providers.length - 1)
                    const Divider(height: 1, indent: 56),
                ],
              ],
            ),
          ),
        const SectionHeader('터널'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.memory_rounded),
                title: const Text('네트워크 스택'),
                subtitle: Text(_stackDescription(settings.stack)),
                trailing: DropdownButton<String>(
                  value: settings.stack,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'mixed', child: Text('Mixed')),
                    DropdownMenuItem(value: 'system', child: Text('System')),
                    DropdownMenuItem(value: 'gvisor', child: Text('gVisor')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      controller.updateSettings(
                        settings.copyWith(stack: value),
                      );
                    }
                  },
                ),
              ),
              const Divider(height: 1, indent: 56),
              SwitchListTile(
                secondary: const Icon(Icons.language_rounded),
                title: const Text('IPv6'),
                subtitle: const Text('IPv6 트래픽도 터널로 라우팅'),
                value: settings.ipv6,
                onChanged: (value) =>
                    controller.updateSettings(settings.copyWith(ipv6: value)),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.straighten_rounded),
                title: const Text('MTU'),
                subtitle: const Text('변경 사항은 다음 연결부터 적용'),
                trailing: DropdownButton<int>(
                  value: settings.mtu,
                  underline: const SizedBox.shrink(),
                  items: const [1280, 1400, 1500, 9000]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text('$value'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      controller.updateSettings(settings.copyWith(mtu: value));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        const SectionHeader('Android'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.dashboard_customize_outlined),
                title: const Text('빠른 설정 타일'),
                subtitle: const Text('알림 창에서 VPN을 바로 연결하거나 해제합니다.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _requestTile(context),
              ),
            ],
          ),
        ),
        const SectionHeader('정보'),
        Card(
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.lock_outline_rounded),
                title: Text('온디바이스 처리'),
                subtitle: Text('프로필과 연결 통계는 기기에 저장되며 외부 분석 서버로 전송하지 않습니다.'),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text('Xray Core'),
                subtitle: Text(
                  controller.core['loaded'] == true
                      ? 'v${formatCoreVersion(controller.core['coreVersion'])} · ${controller.core['bridgeAbi'] ?? 'libXray-v3'}'
                      : '코어를 불러올 수 없음',
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.balance_outlined),
                title: const Text('오픈소스 라이선스'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'Proxima',
                  applicationVersion: '1.0.0',
                  applicationLegalese: 'Xray-core MPL-2.0 및 libXray MIT 구성 요소 포함',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _stackDescription(String stack) => switch (stack) {
    'system' => 'Android 시스템 스택',
    'gvisor' => '사용자 공간 gVisor 스택',
    _ => 'TCP System + UDP gVisor',
  };

  String _publicIpLabel(PublicIpInfo? info) {
    if (info == null) return '요청할 때만 외부 서비스에 조회합니다.';
    if (info.rejected) return '현재 정책에서 조회가 차단됨';
    final detail = [
      info.ip,
      info.location,
      info.organization,
    ].where((value) => value.isNotEmpty).join(' · ');
    return detail.isEmpty ? '확인할 수 없음' : detail;
  }
}
