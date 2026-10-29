import 'package:flutter/material.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';
import '../widgets/app_motion.dart';

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
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final mode = controller.settings.mode;
        return AppPage(
          title: switch (mode) {
            OutboundMode.global => '전역 노드',
            OutboundMode.rule => '라우팅 규칙',
            OutboundMode.direct => '직접 연결',
          },
          subtitle: switch (mode) {
            OutboundMode.global => '모든 트래픽에 사용할 노드 하나를 선택합니다.',
            OutboundMode.rule => '프로필에 저장된 목적지 규칙에 따라 경로를 선택합니다.',
            OutboundMode.direct => '프록시 노드를 거치지 않고 바로 통신합니다.',
          },
          onRefresh: controller.loadProxyGroups,
          actions: [
            IconButton.filled(
              tooltip: '새로고침',
              style: IconButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                disabledForegroundColor:
                    Theme.of(context).colorScheme.onSurfaceVariant,
              ).copyWith(
                side: WidgetStateProperty.resolveWith((states) {
                  return states.contains(WidgetState.focused)
                      ? BorderSide(
                          color: Theme.of(context).colorScheme.onSurface,
                          width: 2,
                        )
                      : BorderSide.none;
                }),
              ),
              onPressed:
                  !controller.loadingProxies && mode != OutboundMode.direct
                  ? controller.loadProxyGroups
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          children: [
            if (mode == OutboundMode.rule) ...[
              if (controller.proxyError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: _RuleError(message: controller.proxyError!),
                ),
              if (controller.loadingProxies && controller.routingRules.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(56),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DelayedProgressIndicator(
                          semanticsLabel: '규칙 확인 중',
                        ),
                        SizedBox(height: 12),
                        Text('규칙 확인 중'),
                      ],
                    ),
                  ),
                )
              else if (controller.routingRules.isEmpty)
                PageEmptyState(
                  icon: Icons.rule_rounded,
                  title: '규칙 없음',
                  message: controller.activeProfile == null
                      ? '프로필을 추가하면 연결하지 않아도 규칙을 확인할 수 있습니다.'
                      : '새로고침을 누르세요.',
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Text(
                    '${controller.routingRules.length}개 · 지원 규칙만 적용',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                for (final rule in controller.routingRules) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            rule.destination,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          if (rule.network != null || rule.port != null)
                          Text(
                            [
                              if (rule.network != null)
                                rule.network!.toUpperCase(),
                              if (rule.port != null) '포트 ${rule.port}',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme.onSurfaceVariant,
                                ),
                          ),
                          Text(
                            rule.target,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (!rule.supported) ...[
                            const SizedBox(height: 4),
                            Text(
                              '변환 미지원 · 표시 전용',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                          if (rule.candidates.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              rule.candidates.map(displayProxyName).join(', '),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ] else
            AnimatedSwitcher(
              duration: AppMotion.medium(context),
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: Alignment.topCenter,
                children: [...previousChildren, ?currentChild],
              ),
              child: mode == OutboundMode.direct
                  ? const PageEmptyState(
                      key: ValueKey('direct-mode'),
                      icon: Icons.arrow_forward_rounded,
                      title: '직접 연결 모드입니다',
                      message: '전역 모드를 선택하면 사용할 노드를 지정할 수 있습니다.',
                    )
                  : controller.loadingProxies && controller.proxyGroups.isEmpty
                  ? const Padding(
                      key: ValueKey('loading-proxies'),
                      padding: EdgeInsets.all(56),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : controller.proxyGroups.isEmpty
                  ? const PageEmptyState(
                      key: ValueKey('empty-proxies'),
                      icon: Icons.layers_clear_outlined,
                      title: '선택할 전역 노드가 없습니다',
                      message: '프로필에 사용할 수 있는 노드가 있는지 확인해 주세요.',
                    )
                  : Column(
                      key: const ValueKey('proxy-groups'),
                      children: [
                        for (final group in controller.proxyGroups) ...[
                          Card(
                            key: ValueKey(group.name),
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
                                  ListTileValueText('${group.proxies.length}'),
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
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _RuleError extends StatelessWidget {
  const _RuleError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.error,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        );
        final lines = <String>[];
        final paragraphs = message.replaceFirst(
          '노드 목록을 불러오지 못했습니다: ',
          '규칙 조회 실패\n',
        ).split('\n');
        for (final paragraph in paragraphs) {
          final words = paragraph.split(' ');
          if (words.length > 1 &&
              RegExp(r'^주세요[.!?]?$').hasMatch(words.last)) {
            words[words.length - 2] = '${words[words.length - 2]} ${words.last}';
            words.removeLast();
          }
          var line = '';
          for (final word in words) {
            final candidate = line.isEmpty ? word : '$line $word';
            painter.text = TextSpan(text: candidate, style: style);
            painter.layout();
            // SelectableText reserves a 2px cursor plus a 1px caret gap.
            if (painter.width > constraints.maxWidth - 3 && line.isNotEmpty) {
              lines.add(line);
              line = word;
            } else {
              line = candidate;
            }
          }
          lines.add(line);
        }
        painter.dispose();
        return SelectableText(lines.join('\n'), style: style);
      },
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
  final Set<String> _testing = <String>{};
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
    if (_testing.isNotEmpty) return;
    setState(() {
      _testing.add(proxy);
      _delays.remove(proxy);
    });
    try {
      final delay = await widget.controller.testDelay(proxy);
      if (mounted) setState(() => _delays[proxy] = delay);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('노드 검사 실패: $error')));
      }
    } finally {
      if (mounted) setState(() => _testing.remove(proxy));
    }
  }

  Future<void> _testAll(List<String> proxies) async {
    if (_testing.isNotEmpty) return;
    setState(() {
      _testingAll = true;
      _testing.addAll(proxies);
      for (final proxy in proxies) {
        _delays.remove(proxy);
      }
    });
    try {
      await Future.wait(
        proxies.map((proxy) async {
          int? delay;
          try {
            delay = await widget.controller.testDelay(proxy);
          } catch (_) {
            delay = null;
          }
          if (mounted) {
            setState(() {
              _delays[proxy] = delay;
              _testing.remove(proxy);
            });
          }
        }),
      );
    } finally {
      if (mounted) {
        setState(() {
          _testingAll = false;
          _testing.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.94,
      minChildSize: 0.45,
      builder: (context, scrollController) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          ProxyGroup? group;
          for (final item in widget.controller.proxyGroups) {
            if (item.name == widget.group.name) {
              group = item;
              break;
            }
          }
          final current = group ?? widget.group;
          final disabled = widget.controller.snapshot.isBusy;
          final connected = widget.controller.snapshot.isConnected;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        current.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: connected && !disabled && !_testingAll
                          ? () => _testAll(current.proxies)
                          : null,
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
                  groupValue: current.selected,
                  onChanged: (value) {
                    if (value != null &&
                        _working == null &&
                        _testing.isEmpty &&
                        !disabled &&
                        !_testingAll) {
                      _choose(value);
                    }
                  },
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: current.proxies.length,
                    itemBuilder: (context, index) {
                      final proxy = current.proxies[index];
                      final selected = proxy == current.selected;
                      final working =
                          _working == proxy || _testing.contains(proxy);
                      return Material(
                        animationDuration: AppMotion.short(context),
                        color: selected
                            ? Theme.of(context).colorScheme.primaryContainer
                                  .withValues(alpha: 0.35)
                            : Colors.transparent,
                        child: RadioListTile<String>(
                          value: proxy,
                          enabled: !working && !disabled && !_testingAll,
                          title: Text(
                            displayProxyName(proxy),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          secondary: AnimatedSwitcher(
                            duration: AppMotion.short(context),
                            child: working
                                ? const SizedBox.square(
                                    key: ValueKey('working'),
                                    dimension: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : selected
                                ? const Icon(
                                    Icons.check_circle_rounded,
                                    key: ValueKey('selected'),
                                  )
                                : IconButton(
                                    key: const ValueKey('test'),
                                    tooltip: '지연 시간 측정',
                                    onPressed:
                                        connected &&
                                            !disabled &&
                                            !_testingAll &&
                                            _testing.isEmpty
                                        ? () => _test(proxy)
                                        : null,
                                    icon: const Icon(
                                      Icons.network_ping_rounded,
                                    ),
                                  ),
                          ),
                          subtitle: switch (_delays[proxy]) {
                            final int delay => Text(
                              delay < 0 ? '시간 초과' : '$delay ms',
                            ),
                            null => null,
                          },
                          selected: selected,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
