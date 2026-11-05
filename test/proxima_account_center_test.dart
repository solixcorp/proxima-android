import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/core/proxima_account.dart';
import 'package:proxima/screens/subscription_screen.dart';
import 'package:proxima/state/app_controller.dart';
import 'package:proxima/widgets/account_text.dart';
import 'package:proxima/widgets/app_page.dart';
import 'package:proxima/widgets/proxima_account_card.dart';

void main() {
  testWidgets('static account containers navigate lazily without accordions or addresses',
      (tester) async {
    final account = _Account();
    await _mount(tester, account);
    expect(account.loads, unorderedEquals(_initialSections));
    for (final entry in {
      'account_services_container': '계정 서비스',
      'account_plan_usage_container': '플랜 및 사용량',
      'account_subscription_profile_container': '구독 프로필',
    }.entries) {
      final container = find.byKey(ValueKey(entry.key));
      await tester.scrollUntilVisible(container, 300,
          scrollable: find.byType(Scrollable).first, maxScrolls: 150);
      expect(find.descendant(of: container, matching: find.byType(Material)),
          findsWidgets);
      expect(find.text(entry.value), findsOneWidget);
    }
    expect(find.descendant(
      of: find.byKey(const Key('account_subscription_profile_container')),
      matching: find.byKey(const Key('account_local_profile')),
    ), findsOneWidget);
    expect(find.text('선택된 프로필이 없습니다'), findsOneWidget);
    expect(find.descendant(
      of: find.byKey(const Key('account_plan_usage_container')),
      matching: find.byType(ProximaAccountCard),
    ), findsOneWidget);
    expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
    for (final entry in _serviceTitles.entries) {
      await _expand(tester, entry.key);
      final page = find.byKey(ValueKey('account-page-${entry.value.name}'));
      expect(page, findsOneWidget);
      expect(find.byType(AppPage), findsOneWidget);
      expect(ModalRoute.of(tester.element(page)), isA<MaterialPageRoute<void>>());
      expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(find.byKey(const Key('account_services_container')), findsOneWidget);
    }
    expect(account.loads, unorderedEquals({
      ..._initialSections, ..._serviceTitles.values,
    }));
    for (final title in ['플랜', '사용량']) {
      await _expand(tester, title);
      expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('account-service-subscription')), findsNothing);
    expect(find.byKey(const ValueKey('account-service-domains')), findsNothing);
    expect(account.loads, isNot(contains(AccountSection.subscription)));
    expect(account.loads, isNot(contains(AccountSection.domains)));
    expect(account.grants, isEmpty);
  });

  testWidgets('resource loading is named and yields to the received data',
      (tester) async {
    final account = _Account();
    account.data[AccountSection.nodes] = <AccountJson>[
      {'name': 'Loaded node', 'country': 'JP', 'region': 'Tokyo', 'status': 'online'},
    ];
    await _mount(tester, account);
    await _expand(tester, '노드 상태');
    account
      ..nodesLoading = true
      ..changed();
    await tester.pump();
    expect(
      tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      ).semanticsLabel,
      isNotEmpty,
    );
    account
      ..nodesLoading = false
      ..changed();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Loaded node'), findsOneWidget);
  });

  testWidgets('published FAQ localized fields render category question and answer',
      (tester) async {
    final account = _Account();
    account.data[AccountSection.faq] = <String, Object?>{
      'categories': <AccountJson>[
        {'id': 'connection', 'names': {'ko': '연결 도움말'}},
      ],
      'faqs': <AccountJson>[
        {
          'id': 'faq',
          'category_id': 'connection',
          'questions': {'ko': '연결을 확인하는 방법'},
          'answers': {'ko': '프로필과 노드를 확인하세요.'},
        },
      ],
    };
    await _mount(tester, account);
    await _expand(tester, '자주 묻는 질문');
    expect(find.text('연결 도움말'), findsOneWidget);
    expect(find.text('연결을 확인하는 방법'), findsOneWidget);
    expect(_bodyText('프로필과 노드를 확인하세요.'), findsOneWidget);
    expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
  });

  testWidgets('unpaid history stays read only without an unavailable receipt',
      (tester) async {
    final account = _Account();
    account.data[AccountSection.orders] = <AccountJson>[
      {'id': 'pending-order', 'plan_name': 'Pending plan', 'status': 'pending'},
    ];
    await _mount(tester, account);
    await _expand(tester, '결제 내역');
    expect(find.text('Pending plan'), findsOneWidget);
    expect(find.text('영수증 보기'), findsNothing);
    expect(account.details, isEmpty);
    expect(account.writes, isEmpty);
  });

  testWidgets('subscription choices never display credential-bearing URLs',
      (tester) async {
    final account = _Account();
    await _mount(tester, account);
    expect(find.text('구독 주소'), findsNothing);
    expect(find.text('구독 도메인'), findsNothing);
    expect(find.text('구독 주소 재발급'), findsNothing);
    for (final url in _Account.urls) {
      expect(find.text(url), findsNothing);
    }
  });

  testWidgets('requested resources load once and main refresh excludes unvisited resources',
      (tester) async {
    final account = _Account();
    await _mount(tester, account);
    expect(account.loads, unorderedEquals(_initialSections));
    await _expand(tester, '프로필');
    await _expand(tester, '프로필');
    Navigator.of(tester.element(find.byKey(const Key('account-page-profile'))))
        .popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    await _expand(tester, '프로필');
    expect(account.loads, unorderedEquals([..._initialSections, AccountSection.profile]));
    Navigator.of(tester.element(find.byKey(const Key('account-page-profile'))))
        .popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pump();
    expect(account.reloads, 1);
    expect(account.forced, unorderedEquals([..._initialSections, AccountSection.profile]));
    expect(find.byType(CustomScrollView), findsOneWidget);
  });

  testWidgets('independent resource errors retry only the failed resource',
      (tester) async {
    final account = _Account()
      ..failures[AccountSection.nodes] = const ProximaAccountException('nodes unavailable')
      ..failures[AccountSection.devices] = const ProximaAccountException('devices unavailable');
    await _mount(tester, account);
    await _expand(tester, '노드 상태');
    expect(find.text('nodes unavailable'), findsOneWidget);
    await _expand(tester, '기기 관리');
    expect(find.text('devices unavailable'), findsOneWidget);
    await _expand(tester, '노드 상태');
    expect(find.text('nodes unavailable'), findsOneWidget);
    account.failures.remove(AccountSection.nodes);
    await _tap(tester, find.byKey(const Key('retry_nodes')));
    expect(account.forced, [AccountSection.nodes]);
    expect(find.text('nodes unavailable'), findsNothing);
    await _expand(tester, '기기 관리');
    expect(find.text('devices unavailable'), findsOneWidget);
    expect(account.loads.where((section) => section == AccountSection.devices),
        hasLength(1));
  });

  for (final section in [AccountSection.nodes, AccountSection.tickets]) {
    testWidgets('service refresh forces only $section and required FAQ',
        (tester) async {
      final account = _Account();
      await _mount(tester, account);
      await _expand(tester, _serviceTitles.entries
          .singleWhere((entry) => entry.value == section).key);
      final resources = [
        section,
        if (section == AccountSection.tickets) AccountSection.faq,
      ];
      expect(account.loads, unorderedEquals([..._initialSections, ...resources]));
      await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
      await tester.pumpAndSettle();
      expect(account.forced, unorderedEquals(resources));
      expect(account.reloads, 0);
      expect(account.grants, isEmpty);
    });
  }

  testWidgets('announcement body is static without expanding its title',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.announcements] = <AccountJson>[
        {'id': 'notice', 'title': '서비스 안내', 'body': '새로운 서비스 안내입니다.'},
      ];
    await _mount(tester, account);
    await _expand(tester, '공지사항');
    expect(find.text('서비스 안내'), findsOneWidget);
    expect(_bodyText('새로운 서비스 안내입니다.'), findsOneWidget);
    expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
  });

  testWidgets('grant is explicitly requested and cancelled grants stay retryable',
      (tester) async {
    final account = _Account()..missing.add(AccountGrant.nodesRead);
    await _mount(tester, account);
    await _expand(tester, '노드 상태');
    expect(account.grants, isEmpty);
    account.grantResult = false;
    await _tap(tester, find.byKey(const ValueKey('grant_nodesRead')));
    expect(account.grants, [AccountGrant.nodesRead]);
    expect(account.missing, contains(AccountGrant.nodesRead));
    account.grantResult = true;
    await _tap(tester, find.byKey(const ValueKey('grant_nodesRead')));
    expect(account.grants, [AccountGrant.nodesRead, AccountGrant.nodesRead]);
    expect(account.forced, contains(AccountSection.nodes));
    expect(account.forced, everyElement(isIn([..._initialSections, AccountSection.nodes])));
    expect(find.byKey(const ValueKey('account-page-nodes')), findsOneWidget);
    expect(ProximaAccount.scopes, ['profile', 'subscription:read', 'plan:read']);
  });

  testWidgets('profile editor keeps failed drafts and disables duplicate saves',
      (tester) async {
    final account = _Account();
    await _mount(tester, account);
    await _expand(tester, '프로필');
    await _tap(tester, find.text('이름과 언어 수정'));
    await tester.enterText(find.byType(TextField).first, '수정한 이름');
    await tester.enterText(find.byType(TextField).last, 'ko');
    final pending = Completer<void>();
    account.pendingWrite = pending;
    await _tap(tester, find.text('저장'), settle: false);
    expect(account.writes, ['profile:수정한 이름:ko']);
    expect(tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '저장')).onPressed, isNull);
    pending.completeError(const ProximaAccountException('profile rejected'));
    await tester.pumpAndSettle();
    expect(find.text('profile rejected'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '수정한 이름');
    await _tap(tester, find.text('취소'));
    expect(find.byKey(const Key('account-editor-keep')), findsOneWidget);
    await _tap(tester, find.byKey(const Key('account-editor-discard')));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Escape keeps a dirty draft until explicit discard', (tester) async {
    final account = _Account();
    await _mount(tester, account);
    await _expand(tester, '프로필');
    await _tap(tester, find.text('이름과 언어 수정'));
    await tester.enterText(find.byType(TextField).first, 'edited');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('account-editor-keep')));
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'edited');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('account-editor-discard')));
    expect(find.byType(AlertDialog), findsNothing);
    expect(account.writes, isEmpty);
  });

  testWidgets('closing a submitted request does not cancel or replay it',
      (tester) async {
    final account = _Account();
    final pending = Completer<void>();
    account.pendingWrite = pending;
    await _mount(tester, account);
    await _expand(tester, '프로필');
    await _tap(tester, find.text('이름과 언어 수정'));
    await _tap(tester, find.byKey(const Key('account-editor-submit')), settle: false);
    await _tap(tester, find.byKey(const Key('account-editor-cancel')), settle: false);
    await _tap(tester, find.byKey(const Key('account-editor-discard')));
    expect(find.byType(AlertDialog), findsNothing);
    expect(account.writes, hasLength(1));
    pending.complete();
    await tester.pumpAndSettle();
    expect(account.writes, hasLength(1));
    expect(find.byType(SubscriptionScreen, skipOffstage: false), findsOneWidget);
  });

  testWidgets('session invalidation closes a discard prompt immediately',
      (tester) async {
    final account = _Account();
    await _mount(tester, account);
    await _expand(tester, '프로필');
    await _tap(tester, find.text('이름과 언어 수정'));
    await tester.enterText(find.byType(TextField).first, 'private draft');
    await _tap(tester, find.byKey(const Key('account-editor-cancel')));
    account.changeSession();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SubscriptionScreen, skipOffstage: false), findsOneWidget);
    expect(account.writes, isEmpty);
  });

  testWidgets('device add and delete require confirmation',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.devices] = [
        <String, Object?>{'id': 'device', 'name': '내 기기'},
      ];
    await _mount(tester, account);
    await _expand(tester, '기기 관리');
    await _tap(tester, find.text('기기 추가'));
    await tester.enterText(find.byType(TextField), '새 기기');
    await _tap(tester, find.text('저장'));
    expect(account.writes, ['add:새 기기']);
    await _tap(tester, find.text('기기 삭제'));
    await _tap(tester, find.text('취소'));
    expect(account.writes, ['add:새 기기']);
    await _tap(tester, find.text('기기 삭제'));
    await _tap(tester, find.byKey(const Key('account-editor-submit')));
    expect(account.writes.last, 'remove:device');
  });

  testWidgets('session changes dismiss an editor once without popping the page',
      (tester) async {
    final account = _Account();
    await _mount(tester, account);
    await _expand(tester, '프로필');
    await _tap(tester, find.text('이름과 언어 수정'));
    account.changeSession();
    account.changed();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SubscriptionScreen, skipOffstage: false), findsOneWidget);
    expect(find.byKey(const ValueKey('account-page-profile')), findsOneWidget);
    expect(account.writes, isEmpty);
    account.profile = {'id': 'account-2', 'name': '다른 계정', 'language': 'ko'};
    account.changeSession();
    await tester.pumpAndSettle();
    expect(find.text('이름과 언어 수정'), findsNothing);
    await _expand(tester, '기기 관리');
    await _expand(tester, '프로필');
    expect(find.byKey(const ValueKey('account-page-profile')), findsOneWidget);
    expect(find.text('이름과 언어 수정'), findsOneWidget);
  });

  testWidgets('language edits reload requested resources and invalidate detail pages',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.guides] = {
        'guides': [<String, Object?>{'id': 'guide', 'title': '안내'}],
      };
    await _mount(tester, account);
    await _expand(tester, '프로필');
    await _expand(tester, '사용 가이드');
    await _expand(tester, '가이드 읽기');
    expect(find.descendant(of: find.byType(AccountText),
        matching: find.byType(SelectionArea)), findsWidgets);
    await _expand(tester, '프로필');
    await _tap(tester, find.text('이름과 언어 수정'));
    await tester.enterText(find.byKey(const ValueKey('account-editor-언어')), 'en');
    await _tap(tester, find.text('저장'));
    expect(account.writes, ['profile:계정 이름:en']);
    expect(account.forced, unorderedEquals(
      [..._initialSections, AccountSection.guides],
    ));
    await _expand(tester, '사용 가이드');
    expect(_bodyText('첫 문단 & 설명\n\n두 번째 문단 <안전>'), findsNothing);
    await _expand(tester, '가이드 읽기');
    expect(account.details, ['guide:guide', 'guide:guide']);
  });

  testWidgets('reset conflict remains inline in a retryable confirmation',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.resetTickets] = [
        <String, Object?>{'id': 'reset', 'name': '트래픽 초기화권'},
      ]
      ..writeError = const ProximaAccountException('already redeemed', statusCode: 409);
    await _mount(tester, account);
    await _expand(tester, '트래픽 초기화권');
    await _tap(tester, find.text('초기화권 사용'));
    await _tap(tester, find.byKey(const Key('account-editor-submit')));
    expect(account.writes, ['redeem:reset']);
    expect(find.text('already redeemed'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await _tap(tester, find.text('취소'));
  });

  testWidgets('receipt child page is lazy read only and hides payment URLs',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.orders] = [
        <String, Object?>{'id': 'paid', 'plan_name': '구매한 플랜', 'status': 'paid'},
      ];
    await _mount(tester, account);
    await _expand(tester, '결제 내역');
    expect(account.details, isEmpty);
    await _expand(tester, '영수증 보기');
    expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
    expect(account.details, ['receipt:paid']);
    expect(find.text('KRW'), findsOneWidget);
    expect(find.text('https://payments.example/checkout'), findsNothing);
    expect(account.writes, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('support create conversation reply and close use a child page',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.tickets] = [
        <String, Object?>{'id': 'ticket', 'subject': '도움 요청', 'status': 'open'},
      ];
    await _mount(tester, account);
    await _expand(tester, '고객 지원');
    await _tap(tester, find.text('문의 작성'));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('일반 문의').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '제목 초안');
    await tester.enterText(find.byType(TextField).last, '내용 초안');
    await _tap(tester, find.text('저장'));
    expect(account.writes, ['create:general:제목 초안:내용 초안']);
    await _expand(tester, '문의 대화');
    expect(_bodyText('지원 답변'), findsOneWidget);
    expect(find.textContaining('2026-11-01T03:00:00Z'), findsNothing);
    expect(find.textContaining('admin'), findsNothing);
    await _tap(tester, find.text('답장'));
    await tester.enterText(find.byType(TextField), '추가 질문');
    await _tap(tester, find.text('저장'));
    expect(account.writes.last, 'reply:ticket:추가 질문');
    await _tap(tester, find.text('문의 종료'));
    await _tap(tester, find.text('취소'));
    expect(account.writes, isNot(contains('close:ticket')));
    await _tap(tester, find.text('문의 종료'));
    await _tap(tester, find.byKey(const Key('account-editor-submit')));
    expect(account.writes.last, 'close:ticket');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('epoch reset ignores late detail data and clears open account state',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.guides] = {
        'guides': [<String, Object?>{'id': 'guide', 'title': '안내'}],
      };
    final pending = Completer<AccountJson>();
    account.pendingDetail = pending;
    await _mount(tester, account);
    await _expand(tester, '사용 가이드');
    await _expand(tester, '가이드 읽기', settle: false);
    expect(account.details, ['guide:guide']);
    account.changeSession();
    pending.complete({'rendered_html': '<p>old account secret</p>'});
    await tester.pumpAndSettle();
    expect(find.textContaining('old account secret'), findsNothing);
    expect(account.details, ['guide:guide']);
    expect(find.byType(AlertDialog), findsNothing);
    await _expand(tester, '사용 가이드');
    expect(find.text('가이드 읽기'), findsOneWidget);
  });

  for (final late in [false, true]) {
    testWidgets('same epoch account replacement discards ${late ? 'pending' : 'cached'} detail',
        (tester) async {
      final first = _Account()
        ..data[AccountSection.guides] = {
          'guides': [<String, Object?>{'id': 'guide', 'title': '안내'}],
        };
      final second = _Account()
        ..data[AccountSection.guides] = {
          'guides': [<String, Object?>{'id': 'guide', 'title': '안내'}],
        };
      final pending = Completer<AccountJson>();
      first.pendingDetail = pending;
      expect(first.sessionEpoch, second.sessionEpoch);
      final current = ValueNotifier(first);
      addTearDown(current.dispose);
      addTearDown(second.dispose);
      await _mount(tester, first, disableAnimations: false, current: current);
      final rootState = tester.state(
          find.byType(SubscriptionScreen, skipOffstage: false));
      await _expand(tester, '사용 가이드');
      await _expand(tester, '가이드 읽기', settle: false);
      expect(first.details, ['guide:guide']);
      if (!late) {
        pending.complete({'rendered_html': '<p>old account secret</p>'});
        await tester.pumpAndSettle();
        expect(_bodyText('old account secret'), findsOneWidget);
      }
      current.value = second;
      if (late) {
        pending.complete({'rendered_html': '<p>old account secret</p>'});
      }
      await tester.pump();
      expect(_bodyText('old account secret'), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SubscriptionScreen, skipOffstage: false)),
          same(rootState));
      expect(_bodyText('old account secret'), findsNothing);
      expect(second.details, isEmpty);
      final navigator = Navigator.of(tester.element(find.byType(AppPage)));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-page-guides')), findsOneWidget);
      expect(find.text('가이드 읽기'), findsNothing);
      expect(find.text('안내'), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      await _expand(tester, '사용 가이드');
      await _expand(tester, '가이드 읽기');
      expect(second.details, ['guide:guide']);
      expect(first.details, ['guide:guide']);
      expect(_bodyText('첫 문단 & 설명\n\n두 번째 문단 <안전>'), findsOneWidget);
    });
  }

  testWidgets('sign out hides private service content and late child detail',
      (tester) async {
    final account = _Account()
      ..data[AccountSection.guides] = {
        'guides': [<String, Object?>{'id': 'guide', 'title': '비공개 안내'}],
      };
    final pending = Completer<AccountJson>();
    account.pendingDetail = pending;
    await _mount(tester, account);
    await _expand(tester, '사용 가이드');
    await _expand(tester, '가이드 읽기', settle: false);
    account.connected = false;
    account.changeSession();
    pending.complete({'rendered_html': '<p>signed out secret</p>'});
    await tester.pumpAndSettle();
    expect(_bodyText('signed out secret'), findsNothing);
    final navigator = Navigator.of(tester.element(find.byType(AppPage)));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-page-guides')), findsOneWidget);
    expect(find.text('비공개 안내'), findsNothing);
    expect(find.text('가이드 읽기'), findsNothing);
    expect(account.details, ['guide:guide']);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('proxima_sign_in')), findsOneWidget);
  });

  testWidgets('support category stays visible after all keep-writing exits',
      (tester) async {
    final account = _Account();
    await _mount(tester, account);
    await _expand(tester, '고객 지원');
    await _tap(tester, find.text('문의 작성'));
    await tester.tap(find.byKey(const Key('account-editor-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('일반 문의').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'draft subject');
    await tester.enterText(find.byType(TextField).last, 'draft body');
    for (final exit in ['cancel', 'escape', 'back']) {
      if (exit == 'cancel') {
        await _tap(tester, find.byKey(const Key('account-editor-cancel')));
      } else if (exit == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('account-editor-keep')));
      final dropdown = tester.widget<DropdownButton<String>>(find.descendant(
        of: find.byKey(const Key('account-editor-category')),
        matching: find.byType(DropdownButton<String>),
      ));
      expect(dropdown.value, 'general', reason: exit);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text,
          'draft subject');
    }
    await _tap(tester, find.byKey(const Key('account-editor-submit')));
    expect(account.writes, ['create:general:draft subject:draft body']);
  });

  for (final brightness in Brightness.values) {
    testWidgets('busy support category retains disabled text contrast in $brightness',
        (tester) async {
      final account = _Account();
      final pending = Completer<void>();
      account.pendingWrite = pending;
      await _mount(tester, account, brightness: brightness);
      await _expand(tester, '고객 지원');
      await _tap(tester, find.text('문의 작성'));
      await tester.tap(find.byKey(const Key('account-editor-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('일반 문의').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'subject');
      await tester.enterText(find.byType(TextField).last, 'body');
      await _tap(tester, find.byKey(const Key('account-editor-submit')), settle: false);
      final category = find.descendant(
        of: find.byType(AlertDialog), matching: find.text('일반 문의'));
      final element = tester.element(category);
      final foreground = DefaultTextStyle.of(element).style
          .merge(tester.widget<Text>(category).style).color!;
      final background = Theme.of(element).colorScheme.surfaceContainerHighest;
      final textLuminance = Color.alphaBlend(foreground, background).computeLuminance();
      final backgroundLuminance = background.computeLuminance();
      final ratio = textLuminance > backgroundLuminance
          ? (textLuminance + 0.05) / (backgroundLuminance + 0.05)
          : (backgroundLuminance + 0.05) / (textLuminance + 0.05);
      expect(ratio, greaterThanOrEqualTo(3));
      pending.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('all service pages fit 390 at two times text in $brightness',
        (tester) async {
      final account = _Account()
        ..data[AccountSection.guides] = {
          'guides': [
            <String, Object?>{'id': 'guide', 'title': {'ko': '아주 긴 한국어 사용 가이드 제목입니다', 'en': 'English'}},
          ],
        };
      await _mount(tester, account, scale: 2, brightness: brightness);
      for (final title in [
        '프로필', '플랜', '사용량', '노드 상태',
        '트래픽 초기화권', '초기화 사용 기록', '기기 관리', '결제 내역',
        '자주 묻는 질문', '고객 지원', '공지사항', '사용 가이드',
      ]) {
        await _expand(tester, title);
        expect(tester.takeException(), isNull, reason: title);
      }
      await _expand(tester, '가이드 읽기');
      expect(_bodyText('첫 문단 & 설명\n\n두 번째 문단 <안전>'), findsOneWidget);
      expect(find.text('English'), findsNothing);
      expect(find.textContaining('alert('), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('signed out hides management and empty resources are readable',
      (tester) async {
    final account = _Account()..connected = false;
    await _mount(tester, account);
    expect(find.byKey(const Key('proxima_sign_in')), findsOneWidget);
    expect(find.text('기기 관리'), findsNothing);
    expect(find.byType(ExpansionTile, skipOffstage: false), findsNothing);
    final profileContainer = find.byKey(
        const Key('account_subscription_profile_container'));
    expect(find.descendant(of: profileContainer, matching: find.byType(Divider)),
        findsNothing);
    expect(find.descendant(of: profileContainer,
        matching: find.text('연결 상태')), findsOneWidget);
    account.connected = true;
    account.changed();
    await tester.pumpAndSettle();
    await _expand(tester, '기기 관리');
    expect(find.descendant(
      of: find.byKey(const ValueKey('account-page-devices')),
      matching: find.text('내역이 없습니다.'),
    ), findsOneWidget);
  });
}

Finder _bodyText(String text) => find.byWidgetPredicate(
  (widget) => widget is AccountText && widget.text == text,
);

const _initialSections = [AccountSection.summary, AccountSection.traffic];

const _serviceTitles = {
  '프로필': AccountSection.profile,
  '노드 상태': AccountSection.nodes,
  '트래픽 초기화권': AccountSection.resetTickets,
  '초기화 사용 기록': AccountSection.resetHistory,
  '기기 관리': AccountSection.devices,
  '결제 내역': AccountSection.orders,
  '자주 묻는 질문': AccountSection.faq,
  '고객 지원': AccountSection.tickets,
  '공지사항': AccountSection.announcements,
  '사용 가이드': AccountSection.guides,
};

Future<void> _mount(WidgetTester tester, _Account account, {
  double scale = 1, Brightness brightness = Brightness.light, bool settle = true,
  bool disableAnimations = true,
  ValueNotifier<_Account>? current,
}) async {
  tester.view
    ..physicalSize = const Size(390, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = AppController(MethodChannelVpnBridge());
  addTearDown(controller.dispose);
  addTearDown(account.dispose);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF35618B), brightness: brightness)),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale), disableAnimations: disableAnimations),
      child: child!,
    ),
    home: current == null
        ? SubscriptionScreen(controller: controller, account: account)
        : ValueListenableBuilder<_Account>(
            valueListenable: current,
            builder: (context, value, _) =>
                SubscriptionScreen(controller: controller, account: value),
          ),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _expand(WidgetTester tester, String title, {bool settle = true}) async {
  final section = _serviceTitles[title] ??
      const {'플랜': AccountSection.summary, '사용량': AccountSection.traffic}[title];
  if (section != null) {
    if (find.byKey(ValueKey('account-page-${section.name}')).evaluate().isNotEmpty) {
      return;
    }
    final navigator = Navigator.of(tester.element(find.byType(AppPage)));
    navigator.popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    final target = section == AccountSection.summary
        ? find.text('플랜 상세')
        : section == AccountSection.traffic
            ? find.text('사용량 상세')
            : find.byKey(ValueKey('account-service-${section.name}'));
    await _tap(tester, target, settle: settle);
    return;
  }
  if (!{'영수증 보기', '문의 대화', '가이드 읽기'}.contains(title)) {
    expect(find.text(title), findsOneWidget);
    return;
  }
  final button = find.ancestor(
    of: find.text(title), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  expect(button, findsOneWidget);
  await _tap(tester, button, settle: settle);
}

Future<void> _tap(WidgetTester tester, Finder finder, {bool settle = true}) async {
  if (find.byType(AlertDialog).evaluate().isEmpty) {
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await tester.pump();
  }
  await tester.scrollUntilVisible(finder, 200,
      scrollable: find.byType(Scrollable).first, maxScrolls: 150);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pump();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

class _Account extends ProximaAccount {
  _Account() : super(server: Uri.https('account.example')) {
    profile = {'id': 'account-1', 'name': '계정 이름', 'language': 'ko'};
    summary = {'plan_name': '내 플랜', 'traffic_used': 20};
    subscriptionUrl = urls.first;
  }
  static const urls = ['https://account.example/sub/one', 'https://account.example/sub/two'];
  bool connected = true;
  bool nodesLoading = false;
  int epoch = 1;
  int reloads = 0;
  bool grantResult = true;
  final loads = <AccountSection>[];
  final forced = <AccountSection>[];
  final grants = <AccountGrant>[];
  final missing = <AccountGrant>{};
  final writes = <String>[];
  final details = <String>[];
  final failures = <AccountSection, ProximaAccountException>{};
  final data = <AccountSection, Object>{
    AccountSection.profile: <String, Object?>{'name': '계정 이름', 'language': 'ko'},
    AccountSection.summary: <String, Object?>{'plan_name': '내 플랜'},
    AccountSection.subscription: <String, Object?>{'available': true},
    AccountSection.traffic: <String, Object?>{},
    AccountSection.faq: <String, Object?>{
      'categories': [<String, Object?>{'id': 'general', 'names': {'ko': '일반 문의', 'en': 'General'}}],
      'faqs': <AccountJson>[],
    },
    AccountSection.guides: <String, Object?>{},
  };
  final loaded = <AccountSection>{};
  Completer<void>? pendingWrite;
  Completer<AccountJson>? pendingDetail;
  ProximaAccountException? writeError;

  @override
  bool get signedIn => connected;
  @override
  int get sessionEpoch => epoch;
  @override
  bool get mutationBusy => false;
  @override
  List<String> get importableSubscriptionUrls => [
    ?subscriptionUrl,
    for (final url in urls) if (url != subscriptionUrl) url,
  ];
  @override
  bool hasGrant(AccountGrant grant) => !missing.contains(grant);
  @override
  Future<bool> requestGrant(AccountGrant grant) async {
    grants.add(grant);
    if (grantResult) {
      missing.remove(grant);
      epoch++;
      loaded.clear();
    }
    changed();
    return grantResult;
  }
  @override
  Future<void> reload() async { reloads++; }
  @override
  Future<void> loadSection(AccountSection section, {bool force = false}) async {
    loads.add(section);
    if (force) forced.add(section);
    loaded.add(section);
    changed();
  }
  AccountValue<AccountJson> _map(AccountSection section) => AccountValue(
    data: loaded.contains(section) ? (data[section] as AccountJson?) ?? {} : null,
    error: failures[section],
  );
  AccountValue<List<AccountJson>> _array(AccountSection section) => AccountValue(
    data: loaded.contains(section) ? (data[section] as List<AccountJson>?) ?? [] : null,
    error: failures[section],
  );
  @override
  AccountValue<AccountJson> get profileState => _map(AccountSection.profile);
  @override
  AccountValue<AccountJson> get summaryState => _map(AccountSection.summary);
  @override
  AccountValue<AccountJson> get subscriptionState => _map(AccountSection.subscription);
  @override
  AccountValue<AccountJson> get trafficState => _map(AccountSection.traffic);
  @override
  AccountValue<AccountJson> get faqState => _map(AccountSection.faq);
  @override
  AccountValue<AccountJson> get guidesState => _map(AccountSection.guides);
  @override
  AccountValue<List<AccountJson>> get domainsState => _array(AccountSection.domains);
  @override
  AccountValue<List<AccountJson>> get nodesState => nodesLoading
      ? const AccountValue(loading: true) : _array(AccountSection.nodes);
  @override
  AccountValue<List<AccountJson>> get resetTicketsState => _array(AccountSection.resetTickets);
  @override
  AccountValue<List<AccountJson>> get resetHistoryState => _array(AccountSection.resetHistory);
  @override
  AccountValue<List<AccountJson>> get devicesState => _array(AccountSection.devices);
  @override
  AccountValue<List<AccountJson>> get ordersState => _array(AccountSection.orders);
  @override
  AccountValue<List<AccountJson>> get ticketsState => _array(AccountSection.tickets);
  @override
  AccountValue<List<AccountJson>> get announcementsState => _array(AccountSection.announcements);

  Future<void> _write(String action) async {
    writes.add(action);
    if (pendingWrite case final pending?) await pending.future;
    if (writeError case final error?) throw error;
  }
  @override
  Future<void> updateProfile({required String name, required String language}) async {
    await _write('profile:$name:$language');
    profile = {...?profile, 'name': name, 'language': language};
    data[AccountSection.profile] = <String, Object?>{'name': name, 'language': language};
    changed();
  }
  @override
  Future<void> regenerateSubscription() => _write('regenerate');
  @override
  Future<void> addDevice({required String name}) => _write('add:$name');
  @override
  Future<void> removeDevice(String deviceId) => _write('remove:$deviceId');
  @override
  Future<void> redeemResetTicket(String ticketId) => _write('redeem:$ticketId');
  @override
  Future<String> createSupportTicket({required String categoryId,
    required String subject, required String body}) async {
    await _write('create:$categoryId:$subject:$body');
    return 'created';
  }
  @override
  Future<void> replyToTicket(String ticketId, {required String body}) =>
      _write('reply:$ticketId:$body');
  @override
  Future<void> closeSupportTicket(String ticketId) => _write('close:$ticketId');
  @override
  void selectSubscriptionUrl(String url) {
    if (!urls.contains(url)) throw StateError('unsafe url');
    subscriptionUrl = url;
    changed();
  }
  @override
  Future<AccountJson> fetchReceipt(String orderId) async {
    details.add('receipt:$orderId');
    return {'order_id': orderId, 'currency': 'KRW',
      'receipt_url': 'https://payments.example/checkout'};
  }
  @override
  Future<AccountJson> fetchTicket(String ticketId) async {
    details.add('ticket:$ticketId');
    return {
      'ticket': <String, Object?>{'subject': '도움 요청', 'status': 'open'},
      'messages': [<String, Object?>{
        'body': '지원 답변', 'author_type': 'admin',
        'created_at': '2026-11-01T03:00:00Z',
      }],
    };
  }
  @override
  Future<AccountJson> fetchGuide(String guideId) async {
    details.add('guide:$guideId');
    if (pendingDetail case final pending?) return pending.future;
    return {'rendered_html': '<p>첫 문단 &amp; 설명</p><p>두 번째 문단 &lt;안전&gt;</p><script>alert(1)</script>'};
  }
  void changeSession() { epoch++; loaded.clear(); changed(); }
  void changed() => notifyListeners();
}
