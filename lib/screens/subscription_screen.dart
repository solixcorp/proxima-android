import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/vpn_models.dart';
import '../state/app_controller.dart';
import '../widgets/app_page.dart';
import '../widgets/app_motion.dart';
import '../widgets/account_text.dart';
import '../core/proxima_account.dart';
import '../widgets/proxima_account_card.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key, required this.controller, this.account,
    this.active = true});

  final AppController controller;
  final ProximaAccount? account;
  final bool active;

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  static final _serviceSections = AccountSection.values.where(
    (section) => section != AccountSection.subscription &&
        section != AccountSection.domains &&
        section != AccountSection.summary &&
        section != AccountSection.traffic,
  ).toList(growable: false);
  static const _overviewSections = [AccountSection.summary, AccountSection.traffic];
  final Set<AccountSection> _requested = {};
  final _routeAccount = ValueNotifier<ProximaAccount?>(null);
  final _navigator = GlobalKey<NavigatorState>();
  int _epoch = 0;
  int _languageRevision = 0;
  AppController get controller => widget.controller;
  ProximaAccount? get account => widget.account;

  @override
  void initState() {
    super.initState();
    _epoch = account?.sessionEpoch ?? 0;
    _routeAccount.value = account;
    account?.addListener(_changed);
    controller.addListener(_changed);
    _loadSections();
  }

  void _loadSections() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = account;
      if (current == null || !current.signedIn) return;
      for (final section in _overviewSections) {
        if (_requested.add(section)) current.loadSection(section);
      }
    });
  }

  @override
  void didUpdateWidget(covariant SubscriptionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != account) {
      oldWidget.account?.removeListener(_changed);
      account?.addListener(_changed);
      _requested.clear();
      _epoch = account?.sessionEpoch ?? 0;
      _routeAccount.value = account;
      _loadSections();
    }
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(_changed);
      controller.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    var reset = false;
    setState(() {
      if (_epoch != account?.sessionEpoch) {
        _epoch = account?.sessionEpoch ?? 0;
        _requested.clear();
        reset = true;
      }
    });
    if (reset) {
      _loadSections();
    } else if (account?.signedIn == true && _requested.isEmpty) {
      _loadSections();
    }
  }

  @override
  void dispose() {
    account?.removeListener(_changed);
    controller.removeListener(_changed);
    _routeAccount.dispose();
    super.dispose();
  }

  Future<bool> _grant(ProximaAccount current, AccountGrant grant) async {
    final identity = current.profile?['id'];
    final sections = _requested.toSet();
    final granted = await current.requestGrant(grant);
    if (!granted || !mounted || account != current ||
        !current.signedIn || identity == null ||
        current.profile?['id'] != identity || !current.hasGrant(grant)) {
      return false;
    }
    final loads = {
      ...sections,
      if (sections.contains(AccountSection.tickets)) AccountSection.faq,
    };
    _requested.addAll(loads);
    await Future.wait([
      for (final section in loads) current.loadSection(section, force: true),
    ]);
    return true;
  }

  Future<void> _refreshAccount() async {
    final current = account;
    if (current == null || !current.signedIn) {
      await controller.reloadProfiles();
      return;
    }
    await Future.wait([
      current.reload(),
      for (final section in _requested.toList())
        current.loadSection(section, force: true),
    ]);
  }


  @override
  Widget build(BuildContext context) {
    return NavigatorPopHandler<void>(
      enabled: widget.active,
      onPopWithResult: (_) {
        if (widget.active) _navigator.currentState!.pop();
      },
      child: Navigator(
        key: _navigator,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (context) => ValueListenableBuilder<ProximaAccount?>(
            valueListenable: _routeAccount,
            builder: (context, current, _) => ListenableBuilder(
              listenable: Listenable.merge([controller, ?current]),
              builder: (context, _) => _buildOverview(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverview(BuildContext context) {
    final profile = controller.activeProfile;
    return AppPage(
      title: '계정',
      subtitle: '계정과 구독을 관리합니다.',
      onRefresh: _refreshAccount,
      actions: [
        IconButton(
          tooltip: '계정 새로고침',
          disabledColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
          onPressed: account?.busy == true ? null : _refreshAccount,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        const SectionHeader('플랜 및 사용량'),
        if (account case final account?)
        KeyedSubtree(
          key: const Key('account_plan_usage_container'),
          child:
          ProximaAccountCard(
            account: account,
            subscriptionInfo: account.ownsSubscription(profile?.sourceUrl)
                ? profile?.subscriptionInfo
                : null,
            canImport: !controller.snapshot.isBusy,
            onImport: (source) => controller.importAccountSubscription(
              source,
              planName: account.planName,
            ),
            footer: account.signedIn
                ? Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        key: const Key('account-service-summary'),
                        onPressed: () => _openService(account, AccountSection.summary),
                        child: const Text('플랜 상세'),
                      ),
                      TextButton(
                        key: const Key('account-service-traffic'),
                        onPressed: () => _openService(account, AccountSection.traffic),
                        child: const Text('사용량 상세'),
                      ),
                    ],
                  )
                : null,
          ),
        )
        else
          const Card(
            key: Key('account_plan_usage_container'),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('연결된 계정이 없습니다.'),
            ),
          ),
        const SectionHeader('계정 서비스'),
        Card(
          key: const Key('account_services_container'),
          child: account?.signedIn == true
              ? Column(
                  children: [
                    for (final section in _serviceSections)
                      ListTile(
                        key: ValueKey('account-service-${section.name}'),
                        leading: Icon(_sectionIcon(section)),
                        title: Text(_sectionTitle(section)),
                        trailing: const Icon(Icons.arrow_forward_rounded),
                        onTap: () => _openService(account!, section),
                      ),
                  ],
                )
              : const ListTile(
                  leading: Icon(Icons.account_circle_outlined),
                  title: Text('로그인 후 이용할 수 있습니다.'),
                ),
        ),
          ],
        ),
      ],
    );
  }

  Future<void> _openService(ProximaAccount current, AccountSection section) async {
    if (!current.signedIn || !identical(current, account)) return;
    for (final resource in [
      section,
      if (section == AccountSection.tickets) AccountSection.faq,
    ]) {
      if (_requested.add(resource)) current.loadSection(resource);
    }
    await _navigator.currentState!.push<void>(MaterialPageRoute(
      builder: (_) => ListenableBuilder(
        listenable: Listenable.merge([current, _routeAccount]),
        builder: (context, _) => AppPage(
          key: ValueKey('account-page-${section.name}'),
          title: _sectionTitle(section),
          onRefresh: current.signedIn && identical(account, current)
              ? () async {
                  await Future.wait([
                    current.loadSection(section, force: true),
                    if (section == AccountSection.tickets)
                      current.loadSection(AccountSection.faq, force: true),
                  ]);
                }
              : null,
          children: [
            if (mounted && identical(account, current) && current.signedIn)
              KeyedSubtree(
                key: ValueKey((current, current.sessionEpoch, section)),
                child: _accountSection(current, section),
              )
            else
              const PageEmptyState(
                icon: Icons.account_circle_outlined,
                title: '계정이 변경되었습니다',
                message: '뒤로 돌아가 현재 계정의 서비스를 선택해 주세요.',
              ),
          ],
        ),
      ),
    ));
  }

  Widget _accountSection(ProximaAccount current, AccountSection section) {
    final value = _sectionValue(current, section);
    final grant = _readGrant(section);
    final loadingLabel = '${_sectionTitle(section)} · 불러오는 중';
    return Card(
      key: ValueKey('account-section-${section.name}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(_sectionTitle(section),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                )),
            ),
            const SizedBox(height: 12),
            _responseSize(context, Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              if (value.loading) ...[
                ExcludeSemantics(
                  child: Text(loadingLabel, style: const TextStyle(fontSize: 15)),
                ),
                LinearProgressIndicator(semanticsLabel: loadingLabel),
              ],
              if (value.error case final error?)
                AccountText(error.message,
                      style: TextStyle(
                        fontSize: 17,
                        color: Theme.of(context).colorScheme.error,
                      )),
              if (grant != null && !current.hasGrant(grant))
                _GrantButton(
                  account: current,
                  grant: grant,
                  request: () => _grant(current, grant),
                )
              else if (value.error != null)
                TextButton(
                  key: Key('retry_${section.name}'),
                  onPressed: value.loading
                      ? null
                      : () => current.loadSection(section, force: true),
                  child: const Text('다시 시도'),
                ),
              if (value.data != null) ..._sectionBody(current, section, value.data),
              if (value.data == null && !value.loading && value.error == null &&
                  (grant == null || current.hasGrant(grant)))
                const Text('정보 없음', style: TextStyle(fontSize: 17)),
              ],
            ),
          ),
          ],
        ),
      ),
    );
  }

  String _text(Object? value) => _localized(
    value,
    account?.profile?['language'] is String
        ? account!.profile!['language'] as String
        : Localizations.localeOf(context).languageCode,
  );

  Widget _prose(String text) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 17);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: AccountText(text, style: style),
      ),
    );
  }

  List<Widget> _fields(AccountJson data, Map<String, String> labels) => [
    for (final entry in labels.entries)
      SelectionArea(
        child: Theme(
          data: Theme.of(context).copyWith(
            textTheme: Theme.of(context).textTheme.copyWith(
              bodyLarge: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 17),
              bodyMedium: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 17),
            ),
          ),
          child: AppValueTile(
          leading: const SizedBox.shrink(),
          title: entry.value,
          value: _fieldValue(data, entry.key),
          ),
        ),
      ),
  ];

  String _fieldValue(AccountJson data, String key) {
    final value = data[key];
    if (key == 'traffic_limit' && data.containsKey(key) && value == null) {
      return '무제한';
    }
    if (value is num &&
        const ['traffic_used', 'traffic_limit', 'reset_bytes'].contains(key)) {
      return formatBytes(value.toInt());
    }
    if (value is num && const ['price_cents', 'discount_cents'].contains(key)) {
      final currency = data['currency'];
      final amount = (value / 100).toStringAsFixed(2);
      return currency is String && currency.isNotEmpty
          ? '${currency.toUpperCase()} $amount'
          : '$amount · 통화 정보 없음';
    }
    if (key.endsWith('_at') && value is String) {
      final date = DateTime.tryParse(value);
      if (date != null) return formatSubscriptionExpiry(date.toLocal());
    }
    if (key == 'days_remaining' && value is num) return '$value일';
    if (key == 'status') return _status(value);
    return _text(value);
  }

  String _status(Object? value) => switch (value) {
    'active' => '이용 중',
    'inactive' => '비활성',
    'online' => '온라인',
    'offline' => '오프라인',
    'paid' => '결제 완료',
    'pending' => '대기 중',
    'cancelled' => '취소됨',
    'open' => '접수됨',
    'answered' => '답변 도착',
    'closed' => '종료됨',
    _ => _text(value),
  };

  Widget _action(ProximaAccount current, String label, AccountGrant grant,
      VoidCallback action) {
    if (!current.hasGrant(grant)) {
      return _GrantButton(account: current, grant: grant,
          request: () => _grant(current, grant));
    }
    return OutlinedButton(
      key: ValueKey('account-action-$label'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        disabledForegroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
      ),
      onPressed: current.mutationBusy || current.busy ? null : action,
      child: Text(label),
    );
  }

  Future<void> _edit(String title, Map<String, String> fields,
      Future<void> Function(Map<String, String>) submit,
      {List<AccountJson>? categories, String? confirmation}) async {
    final current = account!;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AccountEditor(
        account: current, title: title, fields: fields,
        categories: categories, language: _text, submit: submit,
        confirmation: confirmation,
      ),
    );
  }

  Future<void> _confirm(String title, String message,
      Future<void> Function() submit) => _edit(title, const {}, (_) => submit(),
          confirmation: message);

  List<Widget> _sectionBody(
      ProximaAccount current, AccountSection section, Object? raw) {
    final data = _json(raw);
    final rows = _rows(raw);
    switch (section) {
      case AccountSection.profile:
        return [
          ..._fields(data, {
            'name': '이름', 'email': '이메일', 'language': '언어', 'status': '계정 상태',
          }),
          _action(current, '이름과 언어 수정', AccountGrant.profileWrite, () {
            _edit('프로필 수정', {
              '이름': data['name'] is String ? data['name'] as String : '',
              '언어': data['language'] is String ? data['language'] as String : '',
            }, (draft) async {
              final epoch = current.sessionEpoch;
              await current.updateProfile(
                  name: draft['이름']!, language: draft['언어']!);
              if (!mounted || current.sessionEpoch != epoch) return;
              setState(() => _languageRevision++);
              await Future.wait([
                for (final section in _requested.toList())
                  if (section != AccountSection.profile)
                    current.loadSection(section, force: true),
              ]);
            });
          }),
        ];
      case AccountSection.summary:
      case AccountSection.traffic:
        return _fields(data, {
          if (section == AccountSection.summary) 'plan_name': '플랜',
          if (section == AccountSection.summary) 'status': '이용 상태',
          'traffic_used': '사용한 트래픽',
          'traffic_limit': '트래픽 한도',
          'plan_expires_at': '만료일',
          if (section == AccountSection.traffic) 'days_remaining': '남은 일수',
          if (section == AccountSection.summary) ...{
            'devices': '등록 기기',
            'max_devices': '기기 등록 한도',
            'online': '온라인 기기',
            'online_ips': '온라인 IP',
            'max_concurrent': '동시 연결 한도',
            'next_traffic_reset_at': '다음 트래픽 초기화',
          },
        });
      case AccountSection.subscription:
        return [
          ..._fields(data, {'available': '구독 제공 상태'}),
          if (current.importableSubscriptionUrls.isEmpty)
            const Text('가져올 수 있는 구독 주소가 없습니다.'),
          for (final (index, url) in
              (current.importableSubscriptionUrls.toList()..sort()).indexed)
            ListTile(
              key: ValueKey('account-subscription-$index'),
              contentPadding: EdgeInsets.zero,
              title: Text(Uri.parse(url).host),
              selected: current.subscriptionUrl == url,
              leading: Icon(current.subscriptionUrl == url
                  ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              onTap: current.mutationBusy || current.busy
                  ? null : () => current.selectSubscriptionUrl(url),
            ),
          _action(current, '구독 주소 재발급', AccountGrant.subscriptionWrite, () {
            _confirm('구독 주소 재발급', '이전 구독 주소는 더 이상 사용할 수 없습니다.',
                current.regenerateSubscription);
          }),
        ];
      case AccountSection.domains:
        return _list(rows, (row) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _fields(row, {'domain': '도메인', 'is_default': '기본 도메인'}),
        ));
      case AccountSection.nodes:
        return _list(rows, (row) => ListTile(
          contentPadding: EdgeInsets.zero,
          titleTextStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 17),
          subtitleTextStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 15),
          title: Text(_text(row['name'])),
          subtitle: Text('${_text(row['country'])} · ${_text(row['region'])}\n상태: ${_status(row['status'])}'),
        ));
      case AccountSection.resetTickets:
      case AccountSection.resetHistory:
        return _list(rows, (row) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._fields(row, {
              'name': '초기화권', 'granted_at': '발급일', 'expires_at': '만료일',
              if (section == AccountSection.resetHistory) 'used_at': '사용일',
              if (section == AccountSection.resetHistory) 'reset_bytes': '초기화 트래픽',
            }),
            if (section == AccountSection.resetTickets && row['id'] is String)
              _action(current, '초기화권 사용', AccountGrant.resetTicketsRedeem, () {
                _confirm('초기화권 사용', '사용한 초기화권은 되돌릴 수 없습니다.',
                    () => current.redeemResetTicket(row['id'] as String));
              }),
          ],
        ));
      case AccountSection.devices:
        return [
          _action(current, '기기 추가', AccountGrant.devicesWrite, () {
            _edit('기기 추가', {'기기 이름': ''},
                (draft) => current.addDevice(name: draft['기기 이름']!));
          }),
          ..._list(rows, (row) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ..._fields(row, {'name': '기기 이름', 'created_at': '추가일'}),
              if (row['id'] is String)
                _action(current, '기기 삭제', AccountGrant.devicesWrite, () {
                  _confirm('기기 삭제', '선택한 기기를 삭제하면 해당 기기의 연결이 즉시 해제됩니다.',
                      () => current.removeDevice(row['id'] as String));
                }),
            ],
          )),
        ];
      case AccountSection.orders:
        return _list(rows, (row) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._fields(row, {
              'plan_name': '결제 플랜', 'price_cents': '결제 금액',
              'discount_cents': '할인', 'status': '결제 상태',
              'created_at': '생성일', 'paid_at': '결제일', 'provider': '결제 수단',
            }),
            if (row['id'] is String && row['status'] == 'paid')
              _AccountDetailLink(
                key: ValueKey('receipt_$_epoch-$_languageRevision-${row['id']}'),
                account: current, currentAccount: _routeAccount, title: '영수증 보기',
                fetch: () => current.fetchReceipt(row['id'] as String),
                render: (receipt) => _fields(receipt, {
                  'order_id': '결제 번호', 'plan_name': '플랜',
                  'price_cents': '금액', 'discount_cents': '할인',
                  'currency': '통화', 'provider': '결제 수단',
                  'paid_at': '결제일', 'note': '메모',
                }),
              ),
          ],
        ));
      case AccountSection.faq:
        final faqs = _rows(data['faqs']);
        final categories = _rows(data['categories']);
        return [
          for (final category in categories)
            Text(_text(category['names']),
                style: Theme.of(context).textTheme.titleMedium),
          ..._list(faqs, (row) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_text(row['questions']),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _prose(_inertText(_text(row['answers']))),
            ],
          )),
        ];
      case AccountSection.tickets:
        final categories = _rows(current.faqState.data?['categories']);
        return [
          if (current.faqState.error case final error?) ...[
            Text(error.message),
            TextButton(
              onPressed: () => current.loadSection(AccountSection.faq, force: true),
              child: const Text('문의 분류 다시 시도'),
            ),
          ],
          if (categories.isEmpty)
            const Text(
              '문의를 작성하려면 문의 분류가 필요합니다. FAQ를 확인하거나 새로고침해 주세요.',
              style: TextStyle(fontSize: 17),
            ),
          if (categories.isNotEmpty)
            _action(current, '문의 작성', AccountGrant.supportWrite, () {
              _edit('문의 작성', {'제목': '', '내용': ''}, (draft) async {
                await current.createSupportTicket(
                  categoryId: draft['category_id']!,
                  subject: draft['제목']!, body: draft['내용']!,
                );
              }, categories: categories);
            }),
          ..._list(rows, (row) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ..._fields(row, {'subject': '제목', 'category_names': '분류',
                'status': '상태', 'created_at': '작성일', 'last_reply_at': '마지막 답변'}),
              if (row['id'] is String)
                _AccountDetailLink(
                  key: ValueKey('ticket_$_epoch-$_languageRevision-${row['id']}'),
                  account: current, currentAccount: _routeAccount, title: '문의 대화',
                  fetch: () => current.fetchTicket(row['id'] as String),
                  render: (detail) => [
                    ..._fields(_json(detail['ticket']), {'subject': '제목', 'status': '상태'}),
                    ..._list(_rows(detail['messages']), (message) {
                      final rawTime = message['created_at'];
                      final date = rawTime is String
                          ? DateTime.tryParse(rawTime)?.toLocal() : null;
                      final time = date == null ? '시간 정보 없음'
                          : '${formatSubscriptionExpiry(date)} '
                            '${date.hour.toString().padLeft(2, '0')}:'
                            '${date.minute.toString().padLeft(2, '0')}';
                      final author = switch (message['author_type']) {
                        'admin' => '고객지원',
                        'user' => '나',
                        _ => '작성자',
                      };
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: _prose(_text(message['body'])),
                        subtitle: Text(
                          '$author · $time',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontSize: 15),
                        ),
                      );
                    }),
                  ],
                  actions: (reload) => [
                    if (_text(row['status']) != 'closed')
                      _action(current, '답장', AccountGrant.supportWrite, () {
                        _edit('답장', {'내용': ''}, (draft) async {
                          await current.replyToTicket(row['id'] as String, body: draft['내용']!);
                          reload();
                        });
                      }),
                    const SizedBox(height: 8),
                    if (_text(row['status']) != 'closed')
                      _action(current, '문의 종료', AccountGrant.supportWrite, () {
                        _confirm('문의 종료', '이 문의를 종료합니다.', () async {
                          await current.closeSupportTicket(row['id'] as String);
                          reload();
                        });
                      }),
                  ],
                ),
            ],
          )),
        ];
      case AccountSection.announcements:
        return _list(rows, (row) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_text(row['title']),
                style: Theme.of(context).textTheme.titleMedium),
            ..._fields(row, {'created_at': '게시일'}),
            Padding(padding: const EdgeInsets.all(16),
              child: _prose(_inertText(_text(row['body'] ?? row['content'])))),
          ],
        ));
      case AccountSection.guides:
        return [
          for (final category in _rows(data['categories']))
            Text(_text(category['name']),
                style: Theme.of(context).textTheme.titleMedium),
          ..._list(_rows(data['guides']), (row) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ..._fields(row, {'title': '제목', 'summary': '요약'}),
              if (row['id'] is String)
                _AccountDetailLink(
                  key: ValueKey('guide_$_epoch-$_languageRevision-${row['id']}'),
                  account: current, currentAccount: _routeAccount, title: '가이드 읽기',
                  fetch: () => current.fetchGuide(row['id'] as String),
                  render: (detail) => [
                    ..._fields(detail, {'title': '제목', 'category_name': '분류', 'updated_at': '수정일'}),
                    _prose(_inertText(_text(detail['rendered_html']))),
                  ],
                ),
            ],
          )),
        ];
    }
  }
}

String _sectionTitle(AccountSection section) => switch (section) {
  AccountSection.profile => '프로필',
  AccountSection.summary => '플랜',
  AccountSection.traffic => '사용량',
  AccountSection.subscription => '구독 주소',
  AccountSection.domains => '구독 도메인',
  AccountSection.nodes => '노드 상태',
  AccountSection.resetTickets => '트래픽 초기화권',
  AccountSection.resetHistory => '초기화 사용 기록',
  AccountSection.devices => '기기 관리',
  AccountSection.orders => '결제 내역',
  AccountSection.faq => '자주 묻는 질문',
  AccountSection.tickets => '고객 지원',
  AccountSection.announcements => '공지사항',
  AccountSection.guides => '사용 가이드',
};

IconData _sectionIcon(AccountSection section) => switch (section) {
  AccountSection.profile => Icons.person_outline_rounded,
  AccountSection.summary => Icons.workspace_premium_outlined,
  AccountSection.traffic => Icons.data_usage_rounded,
  AccountSection.subscription || AccountSection.domains => Icons.link_rounded,
  AccountSection.nodes => Icons.dns_outlined,
  AccountSection.resetTickets => Icons.restart_alt_rounded,
  AccountSection.resetHistory => Icons.history_rounded,
  AccountSection.devices => Icons.devices_rounded,
  AccountSection.orders => Icons.receipt_long_outlined,
  AccountSection.faq => Icons.help_outline_rounded,
  AccountSection.tickets => Icons.support_agent_rounded,
  AccountSection.announcements => Icons.campaign_outlined,
  AccountSection.guides => Icons.menu_book_outlined,
};

AccountValue<Object> _sectionValue(ProximaAccount account, AccountSection section) =>
    switch (section) {
      AccountSection.profile => account.profileState,
      AccountSection.summary => account.summaryState,
      AccountSection.subscription => account.subscriptionState,
      AccountSection.domains => account.domainsState,
      AccountSection.traffic => account.trafficState,
      AccountSection.nodes => account.nodesState,
      AccountSection.resetTickets => account.resetTicketsState,
      AccountSection.resetHistory => account.resetHistoryState,
      AccountSection.devices => account.devicesState,
      AccountSection.orders => account.ordersState,
      AccountSection.faq => account.faqState,
      AccountSection.tickets => account.ticketsState,
      AccountSection.announcements => account.announcementsState,
      AccountSection.guides => account.guidesState,
    };

AccountGrant? _readGrant(AccountSection section) => switch (section) {
  AccountSection.nodes => AccountGrant.nodesRead,
  AccountSection.resetTickets || AccountSection.resetHistory => AccountGrant.resetTicketsRead,
  AccountSection.devices => AccountGrant.devicesRead,
  AccountSection.orders => AccountGrant.ordersRead,
  AccountSection.tickets || AccountSection.faq => AccountGrant.supportRead,
  AccountSection.announcements || AccountSection.guides => AccountGrant.contentRead,
  _ => null,
};

AccountJson _json(Object? value) => value is Map<String, Object?> ? value : const {};
List<AccountJson> _rows(Object? value) =>
    value is List ? value.whereType<AccountJson>().toList() : const [];
List<Widget> _list(List<AccountJson> rows, Widget Function(AccountJson) build) =>
    rows.isEmpty
        ? [const Text('내역이 없습니다.', style: TextStyle(fontSize: 17))] : [
      for (final row in rows) ...[build(row), const Divider()],
    ];

String _localized(Object? value, String language) {
  if (value is String) return value.isEmpty ? '정보 없음' : value;
  if (value is num) return value.toString();
  if (value is bool) return value ? '예' : '아니요';
  if (value is Map) {
    final preferred = value[language] ?? value[language.split('-').first] ??
        value['en'] ?? value['ko'];
    if (preferred is String) return preferred;
    for (final entry in value.values) {
      if (entry is String && entry.isNotEmpty) return entry;
    }
  }
  if (value is List) return value.map((entry) => _localized(entry, language)).join(', ');
  return '정보 없음';
}

String _inertText(String html) {
  final plain = html
      .replaceAll(RegExp(r'<(script|style|iframe|object)\b[^>]*>[\s\S]*?</\1\s*>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<\s*(br|/p|/div|/h[1-6]|/li|/tr|/section)\b[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  const entities = {
    'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'",
    'nbsp': ' ', 'ndash': '–', 'mdash': '—', 'hellip': '…',
    'copy': '©', 'reg': '®', 'bull': '•',
  };
  return plain.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (match) {
    final entity = match[1]!;
    final number = entity.startsWith('#x')
        ? int.tryParse(entity.substring(2), radix: 16)
        : entity.startsWith('#') ? int.tryParse(entity.substring(1)) : null;
    if (number != null && number > 0 && number <= 0x10ffff &&
        !(number >= 0xd800 && number <= 0xdfff)) {
      return String.fromCharCode(number);
    }
    return entities[entity] ?? match[0]!;
  }).replaceAll(RegExp(r'\n[ \t]+'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

Widget _responseSize(BuildContext context, Widget child) =>
    MediaQuery.disableAnimationsOf(context) ? child : AnimatedSize(
      duration: AppMotion.short(context),
      alignment: AlignmentDirectional.topStart,
      child: child,
    );

class _GrantButton extends StatefulWidget {
  const _GrantButton({required this.account, required this.grant,
    required this.request});
  final ProximaAccount account;
  final AccountGrant grant;
  final Future<bool> Function() request;
  @override
  State<_GrantButton> createState() => _GrantButtonState();
}

class _GrantButtonState extends State<_GrantButton> {
  bool _busy = false;
  String? _error;
  Future<void> _request() async {
    final epoch = widget.account.sessionEpoch;
    setState(() { _busy = true; _error = null; });
    try {
      final granted = await widget.request();
      if (!mounted || epoch != widget.account.sessionEpoch) return;
      if (!granted) {
        setState(() => _error = '권한 연결이 취소되었습니다. 다시 연결할 수 있습니다.');
      }
    } catch (error) {
      if (mounted && epoch == widget.account.sessionEpoch) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      AccountText(switch (widget.grant) {
        AccountGrant.profileWrite => '이름과 언어를 저장하려면 내 정보 수정 권한이 필요합니다.',
        AccountGrant.nodesRead => '이용 가능한 노드와 현재 상태를 조회하려면 노드 조회 권한이 필요합니다.',
        AccountGrant.subscriptionWrite => '이전 주소를 폐기하고 새 구독 주소를 발급하려면 구독 수정 권한이 필요합니다.',
        AccountGrant.resetTicketsRead => '초기화권과 사용 이력을 조회하려면 초기화권 조회 권한이 필요합니다.',
        AccountGrant.resetTicketsRedeem => '선택한 초기화권을 사용하려면 초기화권 사용 권한이 필요합니다.',
        AccountGrant.devicesRead => '등록된 기기를 조회하려면 기기 조회 권한이 필요합니다.',
        AccountGrant.devicesWrite => '기기를 추가하거나 삭제하려면 기기 관리 권한이 필요합니다.',
        AccountGrant.ordersRead => '결제 내역과 영수증을 읽으려면 기록 조회 권한이 필요합니다. 결제는 지원하지 않습니다.',
        AccountGrant.supportRead => 'FAQ와 내 문의를 조회하려면 고객 지원 조회 권한이 필요합니다.',
        AccountGrant.supportWrite => '문의를 작성하거나 답장하고 종료하려면 고객 지원 수정 권한이 필요합니다.',
        AccountGrant.contentRead => '공지와 사용 가이드를 조회하려면 콘텐츠 조회 권한이 필요합니다.',
      }, style: const TextStyle(fontSize: 17)),
      const SizedBox(height: 8),
      if (_error != null) AccountText(_error!, style: const TextStyle(fontSize: 17)),
      OutlinedButton(
        key: ValueKey('grant_${widget.grant.name}'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          disabledForegroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
        ),
        onPressed: _busy || widget.account.busy || widget.account.mutationBusy ? null : _request,
        child: const Text('권한 연결'),
      ),
    ],
  );
}

class _AccountEditor extends StatefulWidget {
  const _AccountEditor({required this.account, required this.title,
    required this.fields, required this.submit, required this.language,
    this.categories, this.confirmation});
  final ProximaAccount account;
  final String title;
  final Map<String, String> fields;
  final List<AccountJson>? categories;
  final String? confirmation;
  final String Function(Object?) language;
  final Future<void> Function(Map<String, String>) submit;
  @override
  State<_AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<_AccountEditor> {
  final _dialogFocus = FocusNode();
  late final int _epoch;
  late final _controllers = {
    for (final entry in widget.fields.entries)
      entry.key: TextEditingController(text: entry.value),
  };
  String? _category;
  String? _error;
  bool _busy = false;
  bool _closing = false;
  bool _confirmClose = false;
  @override
  void initState() {
    super.initState();
    _epoch = widget.account.sessionEpoch;
    widget.account.addListener(_changed);
  }
  void _changed() {
    if (mounted && !_closing && widget.account.sessionEpoch != _epoch) {
      _close();
    } else if (mounted) {
      setState(() {});
    }
  }
  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }
  void _dismiss() {
    if (_confirmClose) {
      setState(() => _confirmClose = false);
      _dialogFocus.requestFocus();
      return;
    }
    final dirty = _category != null || _controllers.entries.any(
      (entry) => entry.value.text != widget.fields[entry.key],
    );
    if (_busy || dirty) {
      setState(() => _confirmClose = true);
      _dialogFocus.requestFocus();
    } else {
      _close();
    }
  }
  @override
  void dispose() {
    widget.account.removeListener(_changed);
    _dialogFocus.dispose();
    for (final controller in _controllers.values) { controller.dispose(); }
    super.dispose();
  }
  Future<void> _save() async {
    if (_busy || widget.account.mutationBusy) return;
    if (_controllers.values.any((controller) => controller.text.trim().isEmpty) ||
        (widget.categories != null && _category == null)) {
      setState(() => _error = '모든 항목을 입력해 주세요.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.submit({
        for (final entry in _controllers.entries) entry.key: entry.value.text.trim(),
        'category_id': ?_category,
      });
      if (mounted && widget.account.sessionEpoch == _epoch) _close();
    } catch (error) {
      if (mounted && widget.account.sessionEpoch == _epoch) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _dismiss},
    child: Focus(
      autofocus: true,
      focusNode: _dialogFocus,
      child: PopScope(
    canPop: _closing,
    onPopInvokedWithResult: (didPop, _) { if (!didPop) _dismiss(); },
    child: AlertDialog(
      title: Text(_confirmClose
          ? _busy ? '처리 중인 요청' : '변경 내용을 버릴까요?'
          : widget.title),
      scrollable: !_confirmClose &&
          (widget.fields.isNotEmpty || widget.categories != null),
      content: _confirmClose
          ? AccountText(_busy
              ? '닫아도 이미 보낸 요청은 계속 처리됩니다.'
              : '저장하지 않은 변경 내용은 사라집니다.',
              style: const TextStyle(fontSize: 17))
          : Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.confirmation != null)
            AccountText(widget.confirmation!, style: const TextStyle(fontSize: 17)),
          if (widget.categories case final categories?)
            DropdownButtonFormField<String>(
              key: const Key('account-editor-category'),
              initialValue: _category,
              isExpanded: true,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 17),
              decoration: const InputDecoration(labelText: '문의 분류'),
              items: [
                for (final category in categories)
                  if (category['id'] is String)
                    DropdownMenuItem(value: category['id'] as String,
                      child: Text(widget.language(category['names']),
                        style: _busy ? TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                        ) : null)),
              ],
              onChanged: _busy ? null : (value) => setState(() => _category = value),
            ),
          for (final entry in _controllers.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextField(
                key: ValueKey('account-editor-${entry.key}'),
                controller: entry.value,
                style: TextStyle(fontSize: 17, color: _busy
                    ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65)
                    : null),
                enabled: !_busy,
                minLines: 1,
                maxLines: entry.key == '내용' ? 8 : 3,
                decoration: InputDecoration(
                  labelText: entry.key,
                  labelStyle: _busy ? TextStyle(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                  ) : null,
                  helperText: entry.key == '언어' ? '언어 코드 예: ko, en' : null,
                  helperStyle: TextStyle(fontSize: 15, color: _busy
                      ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65)
                      : null),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(
                      width: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          if (_error != null)
            AccountText(_error!, style: TextStyle(fontSize: 17,
                color: Theme.of(context).colorScheme.error)),
          if (_busy) LinearProgressIndicator(
            semanticsLabel: '${widget.title} 처리 중',
          ),
        ],
      ),
      actions: [
        if (_confirmClose) ...[
          TextButton(
            key: const Key('account-editor-keep'),
            onPressed: _dismiss,
            child: Text(_busy ? '계속 보기' : '계속 작성'),
          ),
          FilledButton(
            key: const Key('account-editor-discard'),
            style: _busy ? null : FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: _close,
            child: Text(_busy ? '닫기' : '버리기'),
          ),
        ] else ...[
        TextButton(key: const Key('account-editor-cancel'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _dismiss,
          child: Text(_busy ? '닫기' : '취소')),
        FilledButton(
          key: const Key('account-editor-submit'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            disabledForegroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
            backgroundColor: widget.confirmation == null
                ? null : Theme.of(context).colorScheme.error,
            foregroundColor: widget.confirmation == null
                ? null : Theme.of(context).colorScheme.onError,
          ),
          onPressed: _busy || widget.account.mutationBusy || widget.account.busy ? null : _save,
          child: Text(widget.fields.isEmpty ? widget.title : '저장'),
        ),
        ],
      ],
    ),
    ),
    ),
  );
}

class _AccountDetailLink extends StatelessWidget {
  const _AccountDetailLink({super.key, required this.account,
    required this.currentAccount, required this.title,
    required this.fetch, required this.render, this.actions});
  final ProximaAccount account;
  final ValueNotifier<ProximaAccount?> currentAccount;
  final String title;
  final Future<AccountJson> Function() fetch;
  final List<Widget> Function(AccountJson) render;
  final List<Widget> Function(VoidCallback)? actions;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
    onPressed: () {
      Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => _AccountDetailPage(detail: this),
      ));
    },
    icon: const Icon(Icons.arrow_forward_rounded),
    label: Text(title),
  );
}

class _AccountDetailPage extends StatefulWidget {
  const _AccountDetailPage({required this.detail});
  final _AccountDetailLink detail;

  @override
  State<_AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends State<_AccountDetailPage> {
  AccountJson? _data;
  String? _error;
  bool _busy = false;
  late final int _epoch;
  _AccountDetailLink get detail => widget.detail;
  bool get _current => identical(detail.currentAccount.value, detail.account) &&
      detail.account.signedIn && detail.account.sessionEpoch == _epoch;

  @override
  void initState() {
    super.initState();
    _epoch = detail.account.sessionEpoch;
    _load();
  }

  Future<void> _load() async {
    if (_busy || !_current) return;
    final current = detail.account;
    final epoch = current.sessionEpoch;
    setState(() { _busy = true; _error = null; });
    try {
      final data = await detail.fetch();
      if (mounted && _current && identical(current, detail.account) &&
          epoch == current.sessionEpoch) {
        setState(() => _data = data);
      }
    } catch (error) {
      if (mounted && _current && identical(current, detail.account) &&
          epoch == current.sessionEpoch) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && _current && identical(current, detail.account) &&
          epoch == current.sessionEpoch) {
        setState(() => _busy = false);
      }
    }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([detail.account, detail.currentAccount]),
    builder: (context, _) => AppPage(
      key: ValueKey('account-detail-${detail.title}'),
      title: detail.title,
      onRefresh: _current ? _load : null,
      children: [
      if (!_current)
        const PageEmptyState(
          icon: Icons.account_circle_outlined,
          title: '계정이 변경되었습니다',
          message: '뒤로 돌아가 현재 계정의 내용을 확인해 주세요.',
        )
      else
      _responseSize(context, Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
      if (_busy) ...[
        ExcludeSemantics(
          child: Text('${detail.title} · 불러오는 중',
              style: const TextStyle(fontSize: 15)),
        ),
        LinearProgressIndicator(
          semanticsLabel: '${detail.title} · 불러오는 중',
        ),
      ],
      if (_error != null) ...[
        AccountText(_error!, style: const TextStyle(fontSize: 17)),
        TextButton(onPressed: _busy ? null : _load, child: const Text('다시 시도')),
      ],
      if (_data case final data?) ...[
        ...detail.render(data),
        ...?detail.actions?.call(() { if (mounted && _current) _load(); }),
      ],
          ],
        ),
      ),
      ],
    ),
  );
}

