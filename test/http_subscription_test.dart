import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/state/app_controller.dart';

const _yaml = '''
proxies:
  - {name: node, type: http, server: example.com, port: 8080}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  tearDownAll(() => HttpOverrides.global = originalOverrides);
  const packageInfo = MethodChannel('dev.fluttercommunity.plus/package_info');
  late HttpServer server;
  late AppController controller;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          packageInfo,
          (_) async => {
            'appName': 'Proxima',
            'packageName': 'test',
            'version': '1.0',
            'buildNumber': '1',
            'buildSignature': '',
            'installerStore': null,
          },
        );
    controller = AppController(MethodChannelVpnBridge());
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '/token.yaml');
        case '/loop':
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '/loop');
        case '/unsafe':
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            'http://user:pass@127.0.0.1/',
          );
        case '/ftp':
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            'ftp://example.com/file',
          );
        case '/downgrade':
          response.statusCode = HttpStatus.found;
          response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${server.port}/token.yaml',
          );
        default:
          response.headers.set(
            'subscription-userinfo',
            'upload=1; download=2; total=100',
          );
          response.write(_yaml);
      }
      await response.close();
    });
  });

  tearDown(() async {
    controller.dispose();
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfo, null);
  });

  test('fetches HTTP subscription and follows HTTP redirect', () async {
    final base = 'http://127.0.0.1:${server.port}';
    for (final path in ['/token.yaml', '/redirect']) {
      final result = await controller.fetchSubscriptionDetails(
        '  $base$path  ',
      );
      expect(result.content, _yaml);
      expect(result.info?.total, 100);
    }
  });

  test(
    'rejects invalid source and redirect URLs and excessive redirects',
    () async {
      for (final source in [
        'ftp://example.com/a',
        'http:///missing',
        'http://u:p@127.0.0.1/a',
        'http://127.0.0.1:${server.port}/unsafe',
        'http://127.0.0.1:${server.port}/ftp',
      ]) {
        await expectLater(
          controller.fetchSubscriptionDetails(source),
          throwsFormatException,
        );
      }
      await expectLater(
        controller.fetchSubscriptionDetails(
          'http://127.0.0.1:${server.port}/loop',
        ),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        controller.fetchRuleSet(
          Uri.parse('http://127.0.0.1:${server.port}/token.yaml'),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'QR fetches HTTP URLs including base64 and retains normalized source',
    () async {
      final source = 'http://127.0.0.1:${server.port}/token.yaml';
      for (final input in [
        '  $source  ',
        base64UrlEncode(utf8.encode(source)),
      ]) {
        final result = await controller.resolveQrPayload(input);
        expect(result.sourceUrl, source);
        expect(result.content, _yaml);
        expect(result.subscriptionInfo?.total, 100);
      }
    },
  );

  test('HTTPS redirects cannot downgrade a subscription to HTTP', () async {
    final client = _RedirectFixtureClient(HttpClient(), server.port);
    await HttpOverrides.runZoned(
      () => expectLater(
        controller.fetchSubscriptionDetails(
          'https://subscription.example/downgrade',
        ),
        throwsFormatException,
      ),
      createHttpClient: (_) => client,
    );
    expect(client.requested.single.scheme, 'https');
  });

  test('bare HTTP authorities remain proxy links', () async {
    for (final link in [
      'http://u:p@example.com:8080',
      'http://u:p@example.com:8080/',
      'http://example.com:8080',
      'http://example.com:8080/',
    ]) {
      final result = await controller.resolveQrPayload(
        link,
        subscriptionFetcher: (_) => throw StateError('must not fetch'),
      );
      expect(result.content, link);
      expect(result.sourceUrl, isNull);
    }
  });

  test(
    'HTTP source is saved, refreshed and refreshed again on connect',
    () async {
      final bridge = _ProfileBridge();
      final app = AppController(bridge)
        ..settings = const VpnSettings(mode: OutboundMode.direct);
      addTearDown(app.dispose);
      final source = 'http://127.0.0.1:${server.port}/token.yaml';
      final result = await app.resolveQrPayload(source);
      await app.saveProfile(
        name: 'HTTP',
        sourceUrl: '  $source ',
        content: result.content,
      );
      expect(app.profiles.single.sourceUrl, source);
      expect(bridge.saves, 1);
      await app.refreshProfile(app.profiles.single);
      expect(app.profiles.single.sourceUrl, source);
      expect(bridge.saves, 2);
      app.settings = const VpnSettings();
      await app.toggleVpn();
      expect(bridge.saves, 3);
      expect(app.profiles.single.sourceUrl, source);
      expect(bridge.permissionRequested, isTrue);
    },
  );
}

// Exercise redirect decisions with a real response, without changing TLS policy.
class _RedirectFixtureClient implements HttpClient {
  _RedirectFixtureClient(this.inner, this.port);
  final HttpClient inner;
  final int port;
  final requested = <Uri>[];

  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested.add(url);
    return inner.getUrl(
      url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    );
  }

  @override
  void close({bool force = false}) => inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProfileBridge implements VpnBridge {
  VpnProfile? profile;
  String content = '';
  int saves = 0;
  bool permissionRequested = false;

  @override
  Future<VpnProfile> saveProfile({
    String? id,
    required String name,
    String? sourceUrl,
    required String content,
    SubscriptionInfo? subscriptionInfo,
    ProfileAdmissionSummary? admissionSummary,
  }) async {
    saves++;
    this.content = content;
    return profile = VpnProfile(
      id: id ?? 'profile',
      name: name,
      sourceUrl: sourceUrl,
      updatedAt: DateTime.utc(2026),
      isActive: true,
      subscriptionInfo: subscriptionInfo,
      admissionSummary: admissionSummary,
    );
  }

  @override
  Future<List<VpnProfile>> listProfiles() async => [?profile];
  @override
  Future<Map<String, String>> loadProxySelections(String id) async => {};
  @override
  Future<String> readProfile(String id) async => content;
  @override
  Future<bool> requestVpnPermission() async {
    permissionRequested = true;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
