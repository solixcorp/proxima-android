import 'package:flutter/material.dart';

import '../core/vless_reality_profile.dart';
import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';
import 'proxima_web_screen.dart';

enum _ProfileEntryMode { url, link, edit }

class ProfilesScreen extends StatelessWidget {
  const ProfilesScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _openEditor(
    BuildContext context, {
    VpnProfile? profile,
    String? initialName,
    String? initialContent,
    _ProfileEntryMode entryMode = _ProfileEntryMode.edit,
  }) async {
    String content;
    try {
      content =
          initialContent ??
          (profile == null ? '' : await controller.readProfileLink(profile));
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
      return;
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ProfileEditor(
        controller: controller,
        profile: profile,
        initialName: initialName,
        initialContent: content,
        entryMode: entryMode,
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    try {
      final imported = await controller.pickProfileFile();
      if (imported != null && context.mounted) {
        await _openEditor(
          context,
          initialName: imported.name,
          initialContent: imported.content,
          entryMode: _ProfileEntryMode.link,
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _showAddOptions(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('URL'),
              subtitle: const Text('HTTPS 구독 주소에서 노드를 가져옵니다.'),
              onTap: () {
                Navigator.pop(sheetContext);
                _openEditor(context, entryMode: _ProfileEntryMode.url);
              },
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('VLESS + REALITY 링크'),
              subtitle: const Text('공유 링크 또는 여러 링크를 붙여넣습니다.'),
              onTap: () {
                Navigator.pop(sheetContext);
                _openEditor(context, entryMode: _ProfileEntryMode.link);
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('파일'),
              subtitle: const Text('저장된 VLESS 링크 파일을 가져옵니다.'),
              onTap: () {
                Navigator.pop(sheetContext);
                _import(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.language_rounded),
              title: const Text('Proxima'),
              subtitle: const Text('solix.kr을 앱 안에서 엽니다.'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ProximaWebScreen(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, VpnProfile profile) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('프로필 삭제'),
        content: Text('“${profile.name}” 프로필을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    try {
      await controller.deleteProfile(profile.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _refresh(BuildContext context, VpnProfile profile) async {
    try {
      await controller.refreshProfile(profile);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('구독을 업데이트했습니다.')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('업데이트 실패: $error')));
      }
    }
  }

  Future<void> _export(BuildContext context, VpnProfile profile) async {
    try {
      final saved = await controller.exportProfile(profile);
      if (saved && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('프로필 파일을 저장했습니다.')));
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
    return AppPage(
      title: '프로필',
      subtitle: 'VLESS + REALITY 링크와 HTTPS 구독을 관리합니다.',
      onRefresh: controller.reloadProfiles,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddOptions(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('추가'),
      ),
      children: controller.profiles.isEmpty
          ? const [
              PageEmptyState(
                icon: Icons.description_outlined,
                title: '저장된 프로필이 없습니다',
                message: 'VLESS + REALITY 링크를 붙여넣거나 파일에서 가져오세요.',
              ),
            ]
          : [
              for (final profile in controller.profiles) ...[
                Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
                    leading: CircleAvatar(
                      child: Icon(
                        profile.isActive
                            ? Icons.check_rounded
                            : Icons.description_outlined,
                      ),
                    ),
                    title: Text(
                      profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _subtitle(profile, controller.snapshot.isConnected),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: profile.isActive
                        ? null
                        : () => controller.selectProfile(profile.id),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) => switch (value) {
                        'select' => controller.selectProfile(profile.id),
                        'refresh' => _refresh(context, profile),
                        'export' => _export(context, profile),
                        'edit' => _openEditor(context, profile: profile),
                        'delete' => _delete(context, profile),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        if (!profile.isActive)
                          const PopupMenuItem(
                            value: 'select',
                            child: Text('이 프로필 사용'),
                          ),
                        if (profile.sourceUrl?.isNotEmpty == true)
                          const PopupMenuItem(
                            value: 'refresh',
                            child: Text('구독 업데이트'),
                          ),
                        const PopupMenuItem(
                          value: 'export',
                          child: Text('파일로 내보내기'),
                        ),
                        const PopupMenuItem(value: 'edit', child: Text('편집')),
                        if (!profile.isActive ||
                            !controller.snapshot.isConnected)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('삭제'),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
    );
  }

  String _subtitle(VpnProfile profile, bool connected) {
    final state = profile.isActive ? (connected ? '사용 중' : '선택됨') : null;
    final traffic = profile.subscriptionInfo;
    final usage = traffic?.hasTraffic == true
        ? '남음 ${formatBytes(traffic!.remaining)}'
        : null;
    return [state, profile.sourceLabel, usage].whereType<String>().join(' · ');
  }
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({
    required this.controller,
    required this.initialContent,
    required this.entryMode,
    this.initialName,
    this.profile,
  });

  final AppController controller;
  final VpnProfile? profile;
  final String? initialName;
  final String initialContent;
  final _ProfileEntryMode entryMode;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _yaml;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: widget.profile?.name ?? widget.initialName ?? '',
    );
    _url = TextEditingController(text: widget.profile?.sourceUrl ?? '');
    _yaml = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _yaml.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      var content = _yaml.text.trim();
      SubscriptionInfo? subscriptionInfo;
      if (content.isEmpty && _url.text.trim().isNotEmpty) {
        final subscription = await widget.controller.fetchSubscriptionDetails(
          _url.text.trim(),
        );
        content = VlessRealityProfile.linksFromSubscription(
          subscription.content,
        ).join('\n');
        subscriptionInfo = subscription.info ?? const SubscriptionInfo();
      }
      if (content.isEmpty) {
        throw const FormatException('VLESS 링크 또는 구독 주소가 필요합니다.');
      }
      await widget.controller.saveProfile(
        id: widget.profile?.id,
        name: _name.text,
        sourceUrl: _url.text.isEmpty ? null : _url.text,
        content: content,
        subscriptionInfo: subscriptionInfo,
      );
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('FormatException: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.profile == null ? '프로필 추가' : '프로필 편집',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '이름 (선택)',
                prefixIcon: Icon(Icons.label_outline),
              ),
            ),
            const SizedBox(height: 12),
            if (widget.entryMode != _ProfileEntryMode.link) ...[
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: widget.entryMode == _ProfileEntryMode.url
                      ? 'HTTPS 구독 주소'
                      : 'HTTPS 구독 주소 (선택)',
                  prefixIcon: const Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.entryMode != _ProfileEntryMode.url)
              TextField(
                controller: _yaml,
                minLines: 9,
                maxLines: 16,
                autocorrect: false,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.35,
                ),
                decoration: const InputDecoration(
                  labelText: 'VLESS + REALITY 링크 목록',
                  hintText:
                      'vless://uuid@server:443?...&security=reality...\n'
                      '여러 노드는 줄바꿈으로 붙여넣을 수 있습니다.',
                  alignLabelWithHint: true,
                ),
              ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? '검증 및 저장 중…' : '검증 후 저장'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
