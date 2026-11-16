import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/clash_subscription.dart';
import 'package:proxima/core/mihomo_config_assembly.dart';
import 'package:proxima/core/mihomo_proxy_admission.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/core/vless_reality_profile.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/screens/profiles_screen.dart';
import 'package:proxima/state/app_controller.dart';

const _id = '12345678-1234-1234-1234-123456789abc';
const _source = '''# provider source must remain byte-for-byte intact
proxies:
  - {name: first, type: socks5, server: one.example, port: 1080}
  - {name: second, type: http, server: two.example, port: 8080}
  - {name: unsupported, type: sudoku, server: bad.example, port: 443}
proxy-groups:
  - {name: region, type: select, proxies: [first, second, unsupported]}
rules:
  - DOMAIN,example.com,region
  - GEOIP,CN,DIRECT
''';
const _link =
    'vless://12345678-1234-1234-1234-123456789abc@edge.example:443?security=tls#old';

class _Bridge extends MethodChannelVpnBridge {
  @override
  Stream<VpnSnapshot> get snapshots => const Stream.empty();
}

class _Controller extends AppController {
  _Controller(super.bridge);
  String fetched = _source;
  @override
  Future<SubscriptionFetchResult> fetchSubscriptionDetails(
    String source,
  ) async => SubscriptionFetchResult(content: fetched);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('proxima/vpn');
  late _Controller controller;
  late Map<String, Object?> row;
  Map<String, Object?>? secondRow;
  late String content;
  late Map<String, String> selections;
  late List<MethodCall> calls;
  late List<int> uploaded;
  String? failMethod;
  Completer<void>? finishEntered;
  Completer<void>? finishGate;
  Completer<void>? startGate;

  setUp(() {
    row = {'id': _id, 'name': 'Subscription', 'isActive': true, 'updatedAt': 1};
    secondRow = null;
    content = _source;
    selections = {};
    calls = [];
    uploaded = [];
    failMethod = null;
    finishEntered = null;
    finishGate = null;
    startGate = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == failMethod) {
            throw PlatformException(
              code: 'test_error',
              message: 'Mihomo 설정 사이드카가 없습니다.',
            );
          }
          final args = (call.arguments as Map?) ?? const {};
          switch (call.method) {
            case 'readProfile':
              return content;
            case 'listProfiles':
              return [row, if (secondRow != null) secondRow!];
            case 'loadProxySelections':
              return selections;
            case 'clearProxySelection':
              selections.remove(args['group']);
              return null;
            case 'saveProxySelection':
              selections[args['group'] as String] = args['proxy'] as String;
              return null;
            case 'saveProfile':
              content = args['content'] as String;
              row = {
                ...row,
                'name': args['name'],
                'sourceUrl': args['sourceUrl'],
                'admissionSummary': args['admissionSummary'],
                'subscriptionInfo': args['subscriptionInfo'],
              };
              return row;
            case 'requestVpnPermission':
              return true;
            case 'beginMihomoConfiguration':
              expect(
                args['sourceSha256'],
                sha256.convert(utf8.encode(content)).toString(),
              );
              expect(
                args['settingsKey'],
                '${controller.settings.mtu}:${controller.settings.ipv6}:${controller.settings.mode.wireName}:mips',
              );
              uploaded.clear();
              return 'upload-token';
            case 'appendMihomoConfiguration':
              expect(args['offset'], uploaded.length);
              expect(
                (args['bytes'] as Uint8List).length,
                lessThanOrEqualTo(64 * 1024),
              );
              uploaded.addAll((args['bytes'] as Uint8List));
              return null;
            case 'finishMihomoConfiguration':
              finishEntered?.complete();
              await finishGate?.future;
              return null;
            case 'startVpn':
              await startGate?.future;
              return null;
            case 'discardMihomoConfiguration':
            case 'discardPreparedMihomoConfiguration':
            case 'stopVpn':
            case 'saveSettings':
            case 'selectProfile':
              return null;
            case 'validateProfile':
              return null;
            case 'coreAction':
              return '{"code":0,"data":{"proxies":{}}}';
            default:
              throw StateError('Unexpected method ${call.method}');
          }
        });
    controller = _Controller(_Bridge())
      ..settings = const VpnSettings(mode: OutboundMode.global)
      ..profiles = [VpnProfile.fromMap(row)];
  });
  tearDown(() {
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Mihomo saves original YAML and admission metadata without legacy validation', () async {
    await controller.saveProfile(
      id: _id,
      name: 'Subscription',
      content: _source,
      sourceUrl: 'https://subscription.example/profile',
    );
    expect(content, _source);
    final summary = controller.profiles.single.admissionSummary!;
    expect(summary.validProxyCount, 2);
    expect(summary.skipped, hasLength(3)); // protocol, dangling reference, rule
    expect(controller.message, contains('건너뜀 3개'));
    expect(calls.any((c) => c.method == 'validateProfile'), isFalse);
    expect(
      controller.profiles.single.sourceUrl,
      'https://subscription.example/profile',
    );
    expect(
      await controller.readProfileLink(controller.profiles.single),
      _source,
    );
  });

  test('single VLESS keeps legacy comments; existing legacy bytes and routing survive resave', () async {
    await controller.saveProfile(id: _id, name: 'Legacy', content: _link);
    expect(content, contains('# proxima-vless-reality-link:'));
    final legacy = VlessRealityProfile.storedConfigFromInput(
      '$_link\nDOMAIN,example.com,DIRECT',
      profileName: 'Legacy',
    );
    await controller.saveProfile(id: _id, name: 'Legacy', content: legacy);
    expect(content, legacy);
    expect(
      await controller.readProfileLink(controller.profiles.single),
      legacy,
    );
    controller.settings = controller.settings.copyWith(mode: OutboundMode.rule);
    await controller.toggleVpn();
    expect(
      (jsonDecode(utf8.decode(uploaded)) as Map)['rules'],
      contains('DOMAIN,example.com,DIRECT'),
    );
  });

  test('mixed imports survive save reload selection and method-channel upload', () async {
    const reality =
        'vless://12345678-1234-1234-1234-123456789abc@edge.example:443?security=reality&sni=cdn.example&fp=chrome&pbk=abcdefghijklmnopqrstuvwxzy0123456789ABCD&sid=1a2b#Reality';
    const hy2 =
        'hy2://user%3Apass%40word@hy.example/?sni=hy.example&obfs=salamander&obfs-password=ob%2Bfs#HY2';
    const mixed = '$reality\n$hy2';
    for (final source in [mixed, base64Encode(utf8.encode(mixed))]) {
      await controller.saveProfile(id: _id, name: 'Mixed', content: source);
      expect(content, source);
      await controller.reloadProfiles();
      expect(controller.profiles.single.admissionSummary!.validProxyCount, 2);
      selections['GLOBAL'] = 'HY2';
      await controller.toggleVpn();
      final config = jsonDecode(utf8.decode(uploaded)) as Map;
      expect(config['proxy-groups'].last['proxies'], ['HY2', 'Reality']);
      final proxies = config['proxies'] as List;
      expect(proxies.first['reality-opts']['short-id'], '1a2b');
      expect(proxies.first['servername'], 'cdn.example');
      expect(proxies.last['type'], 'hysteria2');
      expect(proxies.last['port'], 443);
      expect(proxies.last['password'], 'user:pass@word');
      expect(proxies.last['obfs-password'], 'ob+fs');
      expect(calls.any((call) => call.method == 'startVpn'), isTrue);
    }
  });

  test('connect final assembly passes all nodes and rules before platform start every time', () async {
    controller.settings = controller.settings.copyWith(mode: OutboundMode.rule);
    selections['GLOBAL'] = 'second';
    await controller.toggleVpn();
    final config = jsonDecode(utf8.decode(uploaded)) as Map<String, dynamic>;
    expect(config['proxies'], hasLength(2));
    expect(config['proxy-groups'].last['proxies'], ['second', 'first']);
    expect(config['rules'], ['DOMAIN,example.com,region', 'MATCH,PROXY']);
    expect(config['tun'].containsKey('inet4-address'), isFalse);
    expect(config['tun'].containsKey('inet6-address'), isFalse);
    expect(config.containsKey('dns'), isFalse);
    final methods = calls.map((c) => c.method).toList();
    expect(
      methods.indexOf('finishMihomoConfiguration'),
      lessThan(methods.indexOf('startVpn')),
    );
    await controller.toggleVpn();
    expect(
      calls.where((c) => c.method == 'beginMihomoConfiguration'),
      hasLength(2),
    );
  });

  test('refresh removes stale selections persistently and shows first node immediately', () async {
    selections.addAll({'GLOBAL': 'removed', 'PROXY': 'removed'});
    final profile = VpnProfile.fromMap({
      ...row,
      'sourceUrl': 'https://subscription.example/profile',
    });
    controller.profiles = [profile];
    await controller.refreshProfile(profile);
    expect(selections, isEmpty);
    expect(controller.currentProxyGroup?.selected, 'first');
    expect(controller.currentProxyGroup?.proxies, ['first', 'second']);
    expect(controller.message, contains('선택한 노드가 구독에서 사라졌습니다'));
    await controller.toggleVpn();
    expect(
      (jsonDecode(
        utf8.decode(uploaded),
      ) as Map)['proxy-groups'].last['proxies'].first,
      'first',
    );
  });

  test(
    'sidecar transfer failure refuses start and exposes error without fallback',
    () async {
      failMethod = 'appendMihomoConfiguration';
      await controller.toggleVpn();
      expect(calls.any((c) => c.method == 'startVpn'), isFalse);
      expect(
        calls.any((c) => c.method == 'discardMihomoConfiguration'),
        isTrue,
      );
      expect(controller.snapshot.state, VpnConnectionState.error);
      expect(controller.snapshot.error, contains('Mihomo 시작 거부'));
      expect(controller.message, contains('사이드카'));
      expect(calls.any((c) => c.method == 'coreAction'), isFalse);
    },
  );

  test('missing sidecar at start becomes error without fallback', () async {
    failMethod = 'startVpn';
    await controller.toggleVpn();
    expect(controller.snapshot.state, VpnConnectionState.error);
    expect(controller.message, contains('사이드카'));
    expect(calls.where((c) => c.method == 'startVpn'), hasLength(1));
  });

  test('assembly/provider-reference and size failures never reach sidecar or start', () async {
    for (final source in [
      '$_source\nproxy-providers: {bad: {type: http, url: "http://unsafe.example/list"}}',
      _source.replaceFirst(
        'proxies: [first, second, unsupported]',
        'use: [missing]',
      ),
      'x' * (8 * 1024 * 1024 + 1),
    ]) {
      content = source;
      calls.clear();
      await controller.toggleVpn();
      expect(controller.snapshot.state, VpnConnectionState.error);
      expect(
        calls.any(
          (c) =>
              c.method == 'beginMihomoConfiguration' || c.method == 'startVpn',
        ),
        isFalse,
      );
    }
  });

  test('large final config is chunked and UTF8 is lossless', () async {
    final large = jsonEncode({
      'proxies': [
        for (var i = 0; i < 2400; i++)
          {
            'name': '노드 $i',
            'type': 'socks5',
            'server': 'edge.example',
            'port': 1080,
          },
      ],
    });
    content = large;
    await controller.toggleVpn();
    expect(uploaded.length, greaterThan(64 * 1024));
    expect(
      calls.where((c) => c.method == 'appendMihomoConfiguration').length,
      greaterThan(1),
    );
    expect(
      (jsonDecode(utf8.decode(uploaded)) as Map)['proxies'][2399]['name'],
      '노드 2399',
    );
  });

  test(
    'connected node switches live and mode change regenerates Dart config',
    () async {
      await controller.loadProxyGroups();
      controller.snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: _id,
      );
      await controller.selectProxy('GLOBAL', 'second');
      expect(selections['GLOBAL'], 'second');
      expect(calls.any((c) => c.method == 'coreAction'), isTrue);
      expect(
        calls.any((c) => c.method == 'finishMihomoConfiguration'),
        isFalse,
      );
      expect(controller.currentProxyGroup?.selected, 'second');
      calls.clear();
      await controller.setMode(OutboundMode.direct);
      expect((jsonDecode(utf8.decode(uploaded)) as Map)['rules'], [
        'MATCH,DIRECT',
      ]);
      expect(calls.any((c) => c.method == 'coreAction'), isFalse);
    },
  );

  test('failed live node switch reassembles and restarts', () async {
    await controller.loadProxyGroups();
    controller.snapshot = const VpnSnapshot(
      state: VpnConnectionState.connected,
      profileId: _id,
    );
    failMethod = 'coreAction';
    await controller.selectProxy('GLOBAL', 'second');
    expect(selections['GLOBAL'], 'second');
    expect(calls.any((c) => c.method == 'finishMihomoConfiguration'), isTrue);
    expect(calls.any((c) => c.method == 'startVpn'), isTrue);
  });

  test(
    'settings save failure leaves the displayed settings unchanged',
    () async {
      final original = controller.settings;
      failMethod = 'saveSettings';
      await expectLater(
        controller.updateSettings(original.copyWith(mtu: 1300)),
        throwsA(isA<PlatformException>()),
      );
      expect(controller.settings, same(original));
    },
  );

  test('live selection save failure restores the running node', () async {
    await controller.loadProxyGroups();
    controller.snapshot = const VpnSnapshot(
      state: VpnConnectionState.connected,
      profileId: _id,
    );
    failMethod = 'saveProxySelection';
    await expectLater(
      controller.selectProxy('GLOBAL', 'second'),
      throwsA(isA<PlatformException>()),
    );
    final changes = calls
        .where((c) => c.method == 'coreAction')
        .map((c) => jsonDecode((c.arguments as Map)['data'] as String))
        .toList();
    expect(changes.map((c) => c['proxy-name']), ['second', 'first']);
    expect(controller.currentProxyGroup?.selected, 'first');
  });

  test(
    'connected profile save failure restores original content and snapshot',
    () async {
      controller.snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: _id,
      );
      failMethod = 'appendMihomoConfiguration';
      await expectLater(
        controller.saveProfile(
          id: _id,
          name: 'changed',
          content: _source.replaceAll('one.example', 'new.example'),
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(content, _source);
      expect(controller.profiles.single.name, 'Subscription');
      expect(controller.snapshot.state, VpnConnectionState.connected);
    },
  );

  test(
    'asynchronous worker failure rolls back mode and persisted settings',
    () async {
      controller.snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: _id,
      );
      startGate = Completer<void>();
      final operation = controller.setMode(OutboundMode.direct);
      while (!calls.any((c) => c.method == 'startVpn')) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.settings.mode, OutboundMode.direct);
      final failure = expectLater(operation, throwsA(isA<PlatformException>()));
      startGate!.completeError(PlatformException(code: 'vpn_start_failed'));
      await failure;
      expect(controller.settings.mode, OutboundMode.global);
      expect(
        (calls.where((c) => c.method == 'saveSettings').last.arguments
            as Map)['mode'],
        'global',
      );
    },
  );

  test(
    'configuration changes cannot race a pending restart and rollback',
    () async {
      controller.snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: _id,
      );
      startGate = Completer<void>();
      final operation = controller.setMode(OutboundMode.direct);
      while (!calls.any((c) => c.method == 'startVpn')) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        controller.updateSettings(controller.settings.copyWith(mtu: 1300)),
        throwsStateError,
      );
      final failure = expectLater(operation, throwsA(isA<PlatformException>()));
      startGate!.completeError(PlatformException(code: 'vpn_start_failed'));
      await failure;
      expect(controller.settings.mode, OutboundMode.global);
      expect(controller.settings.mtu, isNot(1300));
    },
  );

  test('asynchronous worker failure restores saved profile content', () async {
    controller.snapshot = const VpnSnapshot(
      state: VpnConnectionState.connected,
      profileId: _id,
    );
    startGate = Completer<void>();
    final operation = controller.saveProfile(
      id: _id,
      name: 'changed',
      content: _source.replaceAll('one.example', 'new.example'),
    );
    while (!calls.any((c) => c.method == 'startVpn')) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(content, contains('new.example'));
    final failure = expectLater(operation, throwsA(isA<PlatformException>()));
    startGate!.completeError(PlatformException(code: 'vpn_start_failed'));
    await failure;
    expect(content, _source);
    expect(controller.profiles.single.name, 'Subscription');
  });

  test('failed asynchronous fallback restores saved node selection', () async {
    await controller.loadProxyGroups();
    controller.snapshot = const VpnSnapshot(
      state: VpnConnectionState.connected,
      profileId: _id,
    );
    failMethod = 'coreAction';
    startGate = Completer<void>();
    final operation = controller.selectProxy('GLOBAL', 'second');
    while (!calls.any((c) => c.method == 'startVpn')) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(selections['GLOBAL'], 'second');
    final failure = expectLater(operation, throwsA(isA<PlatformException>()));
    startGate!.completeError(PlatformException(code: 'vpn_start_failed'));
    await failure;
    expect(selections, isEmpty);
  });

  test(
    'failed asynchronous profile switch keeps the previous active profile',
    () async {
      secondRow = {
        'id': 'second',
        'name': 'Second',
        'isActive': false,
        'updatedAt': 1,
      };
      controller.profiles = [
        VpnProfile.fromMap(row),
        VpnProfile.fromMap(secondRow!),
      ];
      controller.snapshot = const VpnSnapshot(
        state: VpnConnectionState.connected,
        profileId: _id,
      );
      startGate = Completer<void>();
      final operation = controller.selectProfile('second');
      while (!calls.any((c) => c.method == 'startVpn')) {
        await Future<void>.delayed(Duration.zero);
      }
      final failure = expectLater(operation, throwsA(isA<PlatformException>()));
      startGate!.completeError(PlatformException(code: 'vpn_start_failed'));
      await failure;
      final selections = calls
          .where((c) => c.method == 'selectProfile')
          .toList();
      expect(selections, hasLength(1));
      expect((selections.single.arguments as Map)['id'], _id);
      expect(controller.profiles.first.isActive, isTrue);
    },
  );

  test(
    'cancelling a dispatched start stops it and ignores its late failure',
    () async {
      startGate = Completer<void>();
      final operation = controller.toggleVpn();
      while (!calls.any((c) => c.method == 'startVpn')) {
        await Future<void>.delayed(Duration.zero);
      }
      controller.cancelConnectionPreparation();
      startGate!.completeError(PlatformException(code: 'vpn_start_cancelled'));
      await operation;
      expect(calls.where((c) => c.method == 'stopVpn'), hasLength(1));
      expect(controller.snapshot.state, VpnConnectionState.disconnected);
      expect(controller.preparingConnection, isFalse);
    },
  );

  test('cancellation during sidecar transfer discards prepared config without starting', () async {
    finishEntered = Completer<void>();
    finishGate = Completer<void>();
    final attempt = controller.toggleVpn();
    await finishEntered!.future;
    controller.cancelConnectionPreparation();
    finishGate!.complete();
    await attempt;
    expect(calls.any((c) => c.method == 'startVpn'), isFalse);
    expect(
      calls.any((c) => c.method == 'discardPreparedMihomoConfiguration'),
      isTrue,
    );
    expect(controller.snapshot.state, VpnConnectionState.disconnected);
  });

  test('legacy expanded provider metadata executes without rewriting original bytes', () {
    final encoded = encodeRoutingMetadata({
      'version': 3,
      'source': 'clash-meta',
      'rules': [
        {
          'domain': ['domain:example.com', 'full:exact.example'],
          'target': 'proxy',
          'candidates': ['old'],
        },
        {
          'ip': ['203.0.113.0/24'],
          'target': 'direct',
        },
        {'match': true, 'target': 'proxy'},
      ],
    });
    final source =
        '${VlessRealityProfile.routingMetadataPrefix} $encoded\n${VlessRealityProfile.storedConfigFromInput(_link, profileName: 'old')}';
    final config = jsonDecode(
      MihomoConfigAssembly.build(
        source: source,
        profileName: 'old',
        mode: 'rule',
        mtu: 1400,
        ipv6: true,
      ),
    ) as Map;
    expect(
      config['rules'],
      containsAllInOrder([
        'DOMAIN-SUFFIX,example.com,old',
        'DOMAIN,exact.example,old',
        'IP-CIDR,203.0.113.0/24,DIRECT',
      ]),
    );
    expect(source, contains(encoded));
    expect(
      () => MihomoConfigAssembly.build(
        source: source.replaceFirst(encoded, 'broken'),
        mode: 'rule',
        mtu: 1400,
        ipv6: true,
      ),
      throwsFormatException,
    );
  });

  test('final provider admission mirrors URL path keys behavior and reference policy', () {
    for (final provider in [
      {'type': 'http', 'url': 'http://unsafe.example/list'},
      {'type': 'http', 'url': 'https://user@unsafe.example/list'},
      {'type': 'file', 'path': '../escape'},
      {'type': 'file', 'path': '/absolute'},
      {
        'type': 'http',
        'url': 'https://safe.example/list',
        'skip-cert-verify': true,
      },
    ]) {
      expect(
        MihomoProxyAdmission.providerError(provider, rule: false),
        isNotNull,
      );
    }
    expect(
      MihomoProxyAdmission.providerError({
        'type': 'inline',
        'behavior': 'classical',
        'payload': [],
      }, rule: true),
      isNotNull,
    );
    expect(
      MihomoProxyAdmission.providerError({
        'type': 'inline',
        'behavior': 'domain',
        'payload': ['example.com'],
      }, rule: true),
      isNull,
    );
  });

  test(
    'final admission rejects tampering instead of silently pruning config',
    () {
      Map<String, Object?> config() => (jsonDecode(
        MihomoConfigAssembly.build(
          source: _source,
          mode: 'rule',
          mtu: 1400,
          ipv6: true,
        ),
      ) as Map).cast<String, Object?>();
      final badProxy = config();
      (badProxy['proxies'] as List).first['type'] = 'sudoku';
      expect(MihomoProxyAdmission.configurationError(badProxy), isNotNull);
      final badTun = config();
      (badTun['tun'] as Map)['inet4-address'] = ['172.19.0.1/30'];
      expect(MihomoProxyAdmission.configurationError(badTun), isNotNull);
      final badReference = config();
      (badReference['proxy-groups'] as List).last['use'] = ['missing'];
      expect(
        MihomoProxyAdmission.configurationError(badReference),
        contains('provider'),
      );
      final cycle = config();
      (cycle['proxy-groups'] as List).last['proxies'] = ['PROXY'];
      expect(MihomoProxyAdmission.configurationError(cycle), contains('순환'));
    },
  );

  testWidgets(
    'profile tiles expose persisted import skip summary and wrap reasons',
    (tester) async {
      await controller.saveProfile(
        id: _id,
        name: 'Subscription',
        content: _source,
      );
      await tester.pumpWidget(
        MaterialApp(home: ProfilesScreen(controller: controller)),
      );
      expect(find.textContaining('사용 가능 2개 · 건너뜀 3개'), findsOneWidget);
      expect(find.textContaining('sudoku'), findsOneWidget);
      final summary = tester.widget<Text>(
        find.textContaining('사용 가능 2개 · 건너뜀 3개'),
      );
      expect(summary.maxLines, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
