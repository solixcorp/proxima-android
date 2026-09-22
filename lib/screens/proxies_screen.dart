import 'package:flutter/material.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';

class ProxiesScreen extends StatelessWidget {
  const ProxiesScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _openGroup(BuildContext context, ProxyGroup group) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ProxyPicker(controller: controller, group: group),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = controller.settings.mode;
    return AppPage(
      title: switch (mode) {
        OutboundMode.global => '전역 노드',
        OutboundMode.rule => '규칙별 노드',
        OutboundMode.direct => '직접 연결',
      },
      subtitle: switch (mode) {
        OutboundMode.global => '모든 트래픽에 사용할 노드 하나를 선택합니다.',
        OutboundMode.rule => '각 규칙의 정책 그룹이 사용할 노드를 선택합니다.',
        OutboundMode.direct => '프록시 노드를 거치지 않고 바로 통신합니다.',
      },
      onRefresh: controller.loadProxyGroups,
      actions: [
        IconButton(
          tooltip: '새로고침',
          onPressed:
              !controller.loadingProxies &&
                  (controller.snapshot.isConnected ||
                      mode == OutboundMode.global)
              ? controller.loadProxyGroups
              : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: !controller.snapshot.isConnected && mode != OutboundMode.global
          ? const [
              PageEmptyState(
                icon: Icons.alt_route_rounded,
                title: 'VPN이 연결되지 않았습니다',
                message: 'VPN을 연결하면 프로필의 정책 그룹과 노드를 변경할 수 있습니다.',
              ),
            ]
          : mode == OutboundMode.direct
          ? const [
              PageEmptyState(
                icon: Icons.arrow_forward_rounded,
                title: '직접 연결 모드입니다',
                message: '전역 또는 규칙 모드를 선택하면 사용할 노드를 지정할 수 있습니다.',
              ),
            ]
          : controller.loadingProxies && controller.proxyGroups.isEmpty
          ? const [
              Padding(
                padding: EdgeInsets.all(56),
                child: Center(child: CircularProgressIndicator()),
              ),
            ]
          : controller.proxyGroups.isEmpty
          ? [
              PageEmptyState(
                icon: Icons.layers_clear_outlined,
                title: mode == OutboundMode.global
                    ? '선택할 전역 노드가 없습니다'
                    : '규칙용 정책 그룹이 없습니다',
                message: mode == OutboundMode.global
                    ? '프로필에 사용할 수 있는 노드가 있는지 확인해 주세요.'
                    : '프로필의 rules 및 proxy-groups 설정을 확인해 주세요.',
              ),
            ]
          : [
              for (final group in controller.proxyGroups) ...[
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    leading: CircleAvatar(
                      child: Icon(
                        group.type.toLowerCase().contains('urltest')
                            ? Icons.speed_rounded
                            : Icons.alt_route_rounded,
                      ),
                    ),
                    title: Text(group.name),
                    subtitle: Text(
                      displayProxyName(group.selected),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${group.proxies.length}'),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                    onTap: () => _openGroup(context, group),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
    );
  }
}

class _ProxyPicker extends StatefulWidget {
  const _ProxyPicker({required this.controller, required this.group});

  final AppController controller;
  final ProxyGroup group;

  @override
  State<_ProxyPicker> createState() => _ProxyPickerState();
}

class _ProxyPickerState extends State<_ProxyPicker> {
  String? _working;
  bool _testingAll = false;
  final Map<String, int?> _delays = {};

  Future<void> _choose(String proxy) async {
    setState(() => _working = proxy);
    try {
      await widget.controller.selectProxy(widget.group.name, proxy);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  Future<void> _test(String proxy) async {
    setState(() {
      _working = proxy;
      _delays.remove(proxy);
    });
    final delay = await widget.controller.testDelay(proxy);
    if (mounted) {
      setState(() {
        _working = null;
        _delays[proxy] = delay;
      });
    }
  }

  Future<void> _testAll() async {
    setState(() => _testingAll = true);
    final results = await Future.wait(
      widget.group.proxies.map(
        (proxy) async =>
            MapEntry(proxy, await widget.controller.testDelay(proxy)),
      ),
    );
    if (mounted) {
      setState(() {
        _delays.addEntries(results);
        _testingAll = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.controller.snapshot.isConnected;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.94,
      minChildSize: 0.45,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.group.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton.icon(
                  onPressed: !connected || _testingAll ? null : _testAll,
                  icon: _testingAll
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded),
                  label: const Text('모두 측정'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: RadioGroup<String>(
              groupValue: widget.group.selected,
              onChanged: (value) {
                if (value != null && _working == null && !_testingAll) {
                  _choose(value);
                }
              },
              child: ListView.builder(
                controller: scrollController,
                itemCount: widget.group.proxies.length,
                itemBuilder: (context, index) {
                  final proxy = widget.group.proxies[index];
                  final selected = proxy == widget.group.selected;
                  final working = _working == proxy;
                  final delay = _delays[proxy];
                  return RadioListTile<String>(
                    value: proxy,
                    enabled: !working && !_testingAll,
                    title: Text(
                      displayProxyName(proxy),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: delay == null
                        ? null
                        : Text(delay < 0 ? '시간 초과' : '$delay ms'),
                    secondary: working
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: '지연 시간 측정',
                            onPressed: !connected || _testingAll
                                ? null
                                : () => _test(proxy),
                            icon: const Icon(Icons.network_ping_rounded),
                          ),
                    selected: selected,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
