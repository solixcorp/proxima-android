import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/proxima_account.dart';
import '../models/vpn_models.dart';
import 'app_motion.dart';

class ProximaAccountCard extends StatefulWidget {
  const ProximaAccountCard({
    super.key,
    required this.account,
    required this.onImport,
    this.canImport = true,
  });

  final ProximaAccount account;
  final Future<void> Function(String url) onImport;
  final bool canImport;

  @override
  State<ProximaAccountCard> createState() => _ProximaAccountCardState();
}

class _ProximaAccountCardState extends State<ProximaAccountCard> {
  bool _importing = false;
  String? _importMessage;
  late bool _signedIn;
  Object? _accountId;

  @override
  void initState() {
    super.initState();
    _signedIn = widget.account.signedIn;
    _accountId = widget.account.profile?['id'];
    widget.account.addListener(_accountChanged);
  }

  @override
  void didUpdateWidget(covariant ProximaAccountCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account) {
      oldWidget.account.removeListener(_accountChanged);
      widget.account.addListener(_accountChanged);
      _signedIn = widget.account.signedIn;
      _accountId = widget.account.profile?['id'];
      _importMessage = null;
    }
  }

  void _accountChanged() {
    final account = widget.account;
    if (_signedIn != account.signedIn || _accountId != account.profile?['id']) {
      setState(() {
        _signedIn = account.signedIn;
        _accountId = account.profile?['id'];
        _importMessage = null;
      });
    }
  }

  @override
  void dispose() {
    widget.account.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _importSubscription() async {
    final url = widget.account.subscriptionUrl;
    if (url == null || _importing) return;
    setState(() {
      _importing = true;
      _importMessage = null;
    });
    try {
      await widget.account.importSubscription(widget.onImport);
      if (mounted) {
        setState(() => _importMessage = 'Proxima 구독을 가져와 선택했습니다.');
      }
    } catch (error) {
      final message = switch (error) {
        StateError(:final message) => message.toString(),
        FormatException() => '구독 형식을 읽을 수 없습니다. 지원되는 VLESS 구독인지 확인해 주세요.',
        SocketException() => '구독 서버에 연결할 수 없습니다. 네트워크를 확인해 주세요.',
        TimeoutException() => '구독 서버 응답 시간이 초과되었습니다. 다시 시도해 주세요.',
        HttpException() => '구독 서버 요청이 거절되었습니다. 구독 주소와 유효 기간을 확인해 주세요.',
        _ => '구독을 가져오지 못했습니다. 다시 시도해 주세요.',
      };
      if (mounted) {
        setState(() => _importMessage = message);
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.account,
      builder: (context, _) {
        final account = widget.account;
        final busy = account.busy || _importing;
        final textTheme = Theme.of(context).textTheme;
        final bodyStyle = textTheme.bodyLarge?.copyWith(fontSize: 17);
        final detailStyle = textTheme.bodyMedium?.copyWith(fontSize: 15);
        final operationLabel = _importing
            ? 'Proxima 구독 가져오는 중'
            : '계정 연결 처리 중';
        final profile = account.profile;
        final summary = account.summary;
        final name = profile?['name'] as String?;
        final email = profile?['email'] as String?;
        final used = (summary?['traffic_used'] as num?)?.toInt();
        final limit = (summary?['traffic_limit'] as num?)?.toInt();
        final expiry = DateTime.tryParse(
          summary?['plan_expires_at'] as String? ?? '',
        );
        return AnimatedSize(
          alignment: Alignment.topCenter,
          duration: AppMotion.short(context),
          curve: Curves.easeOutCubic,
          child: Card(
            key: const Key('proxima_account_card'),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(right: 16, top: 4),
                        child: Icon(Icons.account_circle_outlined),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              account.signedIn
                                  ? name?.isNotEmpty == true
                                        ? name!
                                        : 'Proxima 계정 연결됨'
                                  : 'VPN 구독 연결',
                              style: textTheme.titleMedium,
                            ),
                            if (account.signedIn && email != null)
                              SelectableText(email, style: detailStyle),
                          ],
                        ),
                      ),
                      if (account.signedIn)
                        IconButton(
                          tooltip: '계정 정보 새로고침',
                          onPressed: busy ? null : account.reload,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                    ],
                  ),
                  if (summary != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      '플랜 · ${summary['plan_name'] ?? '이용 중인 플랜 없음'}',
                      style: textTheme.titleMedium,
                    ),
                    if (used != null)
                      Text(
                        limit == null
                            ? '사용량 ${formatBytes(used)} · 무제한'
                            : '사용량 ${formatBytes(used)} / ${formatBytes(limit)}',
                        style: detailStyle,
                      ),
                    if (expiry != null)
                      Text(
                        '만료일 ${formatSubscriptionExpiry(expiry.toLocal())}',
                        style: detailStyle,
                      ),
                  ],
                  if (busy) ...[
                    const SizedBox(height: 16),
                    Text(operationLabel, style: detailStyle),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      semanticsLabel: operationLabel,
                    ),
                  ],
                  if (account.error case final error?) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: SelectableText(
                        error,
                        style: bodyStyle?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  if (account.signedIn &&
                      !account.busy &&
                      account.error == null &&
                      account.subscriptionUrl == null) ...[
                    const SizedBox(height: 16),
                    Text('이 계정에는 가져올 수 있는 구독이 없습니다.', style: bodyStyle),
                  ],
                  if (_importMessage case final message?) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: SelectableText(message, style: bodyStyle),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (!account.signedIn)
                        FilledButton.icon(
                          key: const Key('proxima_sign_in'),
                          onPressed: busy ? null : account.signIn,
                          icon: const Icon(Icons.login_rounded),
                          label: const Text('Proxima 로그인'),
                        )
                      else ...[
                        FilledButton.icon(
                          key: const Key('proxima_import_subscription'),
                          onPressed:
                              !busy &&
                                  widget.canImport &&
                                  account.subscriptionUrl != null
                              ? _importSubscription
                              : null,
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('구독 가져오기'),
                        ),
                        TextButton(
                          onPressed: busy ? null : account.signOut,
                          child: const Text('로그아웃'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
