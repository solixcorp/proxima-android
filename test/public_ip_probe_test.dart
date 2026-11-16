import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/native_vpn_bridge.dart';
import 'package:proxima/core/public_ip_probe.dart';
import 'package:proxima/models/vpn_models.dart';
import 'package:proxima/state/app_controller.dart';

class _Bridge implements VpnBridge {
  final events = StreamController<VpnSnapshot>.broadcast(sync: true);
  @override
  Stream<VpnSnapshot> get snapshots => events.stream;
  @override
  Future<VpnSnapshot> getSnapshot() async =>
      const VpnSnapshot(state: VpnConnectionState.connected, profileId: 'one');
  @override
  Future<List<VpnProfile>> listProfiles() async => [];
  @override
  Future<VpnSettings> loadSettings() async => const VpnSettings();
  @override
  Future<Map<Object?, Object?>> coreInfo() async => {};
  @override
  Future<NetworkInfo> getNetworkInfo() async => const NetworkInfo();
  @override
  Future<String> invokeCore(String method, [String data = '']) async =>
      '{"code":0,"data":{"proxies":{}}}';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Redirects only the test's fixed production request to a real local fixture.
class _FixtureClient implements HttpClient {
  _FixtureClient(this.inner, this.endpoint);
  final HttpClient inner;
  final Uri endpoint;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    expect(url.toString(), 'https://get.geojs.io/v1/ip.json');
    return inner.getUrl(endpoint);
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late HttpServer server;
  late Uri endpoint;
  late String body;
  late int status;
  Completer<void>? gate;
  late Completer<void> requested;

  setUp(() async {
    body = '{"ip":"203.0.113.4"}';
    status = 200;
    gate = null;
    requested = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/v1/ip.json');
    server.listen((request) async {
      expect(request.method, 'GET');
      expect(request.uri.path, '/v1/ip.json');
      expect(request.headers.value('accept'), 'application/json');
      expect(request.headers.value('authorization'), isNull);
      if (!requested.isCompleted) requested.complete();
      if (gate != null) await gate!.future;
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    await server.close(force: true);
  });

  test('accepts valid IPv4 and IPv6 without fabricating location', () async {
    final result = await probeCurrentPublicIp(endpoint: endpoint);
    expect(result.ip, '203.0.113.4');
    expect(result.location, isEmpty);
    expect(result.organization, isEmpty);
    body = '{"ip":"2001:db8::1"}';
    expect((await probeCurrentPublicIp(endpoint: endpoint)).ip, '2001:db8::1');
  });

  test('rejects status, redirect, malformed and oversized responses', () async {
    for (final code in [301, 500]) {
      status = code;
      await expectLater(
        probeCurrentPublicIp(endpoint: endpoint),
        throwsA(isA<HttpException>()),
      );
    }
    status = 200;
    for (final invalid in [
      '{}',
      '[]',
      '{"ip":1}',
      '{"ip":"invalid"}',
      '{"ip":"fe80::1%en0"}',
      'not json',
      jsonEncode({'ip': 'x' * 16384}),
    ]) {
      body = invalid;
      await expectLater(
        probeCurrentPublicIp(endpoint: endpoint),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('discards an in-flight result after disconnect and reconnect', () async {
    final bridge = _Bridge();
    final controller = AppController(bridge);
    await controller.initialize();
    gate = Completer<void>();
    final inner = HttpClient();
    final future = HttpOverrides.runZoned(
      controller.probePublicIp,
      createHttpClient: (_) => _FixtureClient(inner, endpoint),
    );
    await requested.future;
    bridge.events.add(
      const VpnSnapshot(state: VpnConnectionState.disconnected),
    );
    bridge.events.add(
      const VpnSnapshot(state: VpnConnectionState.connected, profileId: 'one'),
    );
    gate!.complete();
    await future;
    expect(controller.publicIp, isNull);
    expect(controller.loadingPublicIp, isFalse);
    expect(controller.message, isNull);
    controller.dispose();
    await bridge.events.close();
  });

  test('applies the result for the unchanged session', () async {
    final bridge = _Bridge();
    final controller = AppController(bridge);
    await controller.initialize();
    final inner = HttpClient();
    await HttpOverrides.runZoned(
      controller.probePublicIp,
      createHttpClient: (_) => _FixtureClient(inner, endpoint),
    );
    expect(controller.publicIp?.ip, '203.0.113.4');
    expect(controller.loadingPublicIp, isFalse);
    controller.dispose();
    await bridge.events.close();
  });
}
