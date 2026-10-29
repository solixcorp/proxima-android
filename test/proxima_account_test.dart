import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxima/core/proxima_account.dart';

const _clientId = 'android-public-client';
const _subscriptionUrl = 'https://subscriptions.example.com/client?token=private';
final _expiry = DateTime.utc(2100);
const _waitLimit = Duration(seconds: 5);
const _profile = <String, dynamic>{
  'id': '3b9d6e1a-52c4-4f0e-9a77-1c8d2e4f6a90',
  'email': 'account@example.com',
  'name': 'Account',
  'status': 'active',
  'language': 'ko',
};
const _summary = <String, dynamic>{
  'plan_name': 'Standard',
  'status': 'active',
  'traffic_used': 12884901888,
  'traffic_limit': 107374182400,
  'plan_expires_at': '2026-11-26T03:00:00Z',
  'devices': 2,
  'max_devices': 5,
  'online': 1,
  'online_ips': 1,
  'max_concurrent': 3,
  'next_traffic_reset_at': '2026-11-26T03:00:00Z',
};
const _subscription = <String, dynamic>{
  'available': true,
  'url': _subscriptionUrl,
  'domains': [
    {
      'domain': 'subscriptions.example.com',
      'is_default': true,
      'url': _subscriptionUrl,
    },
  ],
};

void main() {
  late _AccountServer server;
  late _MemorySessionStore store;
  late _AppAuth auth;
  late ProximaAccount account;

  setUp(() async {
    server = await _AccountServer.start();
    store = _MemorySessionStore();
    auth = _AppAuth();
    account = ProximaAccount(
      clientId: _clientId,
      auth: auth,
      store: store,
      server: server.uri,
    );
  });

  tearDown(() async {
    account.dispose();
    await server.close();
  });

  test('login uses explicit public-client AppAuth configuration', () async {
    await account.signIn().timeout(_waitLimit);

    final request = auth.requests.single;
    expect(request.clientId, _clientId);
    expect(request.redirectUrl, 'kr.kimrasng.proxima://oauth/callback');
    expect(request.scopes, ['profile', 'subscription:read', 'plan:read']);
    expect(
      request.serviceConfiguration?.authorizationEndpoint,
      server.uri.resolve('/oauth/authorize').toString(),
    );
    expect(
      request.serviceConfiguration?.tokenEndpoint,
      server.uri.resolve('/api/v1/oauth/token').toString(),
    );
    expect(request.issuer, isNull);
    expect(request.discoveryUrl, isNull);
    expect(request.clientSecret, isNull);
    expect(request.additionalParameters, isNull);
    expect(request.codeVerifier, isNull);
    expect(request.allowInsecureConnections, isFalse);
    expect(account.error, isNull);
  });

  test('login persists both tokens before loading account resources', () async {
    server.onRequest = (request) async {
      expect(store.writes, hasLength(1));
      expect(store.session, _session());
      await server.respondWithResource(request);
    };

    await account.signIn().timeout(_waitLimit);

    expect(store.writes, hasLength(1));
    expect(store.session, _session());
    expect(account.signedIn, isTrue);
    expect(account.busy, isFalse);
    expect(account.error, isNull);
    expect(account.profile, _profile);
    expect(account.summary, _summary);
    expect(account.subscriptionUrl, _subscriptionUrl);
    expect(
      server.requests.map((request) => request.uri.path),
      unorderedEquals([
        '/api/v1/client/profile',
        '/api/v1/client/summary',
        '/api/v1/client/subscription',
      ]),
    );
    for (final request in server.requests) {
      expect(request.method, 'GET');
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer access-token',
      );
      expect(request.headers.value(HttpHeaders.acceptHeader), 'application/json');
    }
  });

  test('simultaneous expired resource loads refresh and persist once', () async {
    store.value = jsonEncode(_session(expiresAt: 0));
    final refreshArrived = Completer<void>();
    final releaseRefresh = Completer<void>();
    addTearDown(() {
      if (!releaseRefresh.isCompleted) releaseRefresh.complete();
    });
    var refreshes = 0;
    server.onRequest = (request) async {
      if (request.uri.path == '/api/v1/oauth/token') {
        refreshes++;
        expect(request.method, 'POST');
        expect(
          request.headers.contentType?.mimeType,
          'application/x-www-form-urlencoded',
        );
        expect(await _readForm(request), {
          'grant_type': 'refresh_token',
          'client_id': _clientId,
          'refresh_token': 'refresh-token',
        });
        if (!refreshArrived.isCompleted) refreshArrived.complete();
        await releaseRefresh.future;
        await _respond(request, {
          'access_token': 'rotated-access',
          'refresh_token': 'rotated-refresh',
          'expires_in': 3600,
        });
      } else {
        expect(store.writes, hasLength(1));
        expect(store.session['access_token'], 'rotated-access');
        expect(store.session['refresh_token'], 'rotated-refresh');
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer rotated-access',
        );
        await server.respondWithResource(request);
      }
    };

    final before = DateTime.now().toUtc().millisecondsSinceEpoch;
    final loading = account.initialize();
    await refreshArrived.future.timeout(_waitLimit);
    expect(account.busy, isTrue);
    expect(server.requests, hasLength(1));
    expect(store.writes, isEmpty);
    releaseRefresh.complete();
    await loading.timeout(_waitLimit);
    final after = DateTime.now().toUtc().millisecondsSinceEpoch;

    expect(refreshes, 1);
    expect(server.requests, hasLength(4));
    expect(store.writes, hasLength(1));
    expect(store.session, {
      'access_token': 'rotated-access',
      'refresh_token': 'rotated-refresh',
      'client_id': _clientId,
      'expires_at': inInclusiveRange(before + 3600000, after + 3600000),
    });
    expect(account.profile, _profile);
    expect(account.summary, _summary);
    expect(account.subscriptionUrl, _subscriptionUrl);
    expect(account.error, isNull);
    expect(account.busy, isFalse);
  });

  test('invalid_grant during refresh clears saved and loaded session', () async {
    await account.signIn().timeout(_waitLimit);
    store.value = jsonEncode(_session(expiresAt: 0));
    server.requests.clear();
    server.onRequest = (request) async {
      expect(request.uri.path, '/api/v1/oauth/token');
      await _respond(request, {'error': 'invalid_grant'}, status: 400);
    };

    await account.initialize().timeout(_waitLimit);

    expect(server.requests, hasLength(1));
    expect(store.value, isNull);
    expect(store.clears, 1);
    expect(account.signedIn, isFalse);
    expect(account.profile, isNull);
    expect(account.summary, isNull);
    expect(account.subscriptionUrl, isNull);
    expect(account.error, isNotEmpty);
    expect(account.busy, isFalse);
    await account.reload().timeout(_waitLimit);
    expect(server.requests, hasLength(1));
  });

  test('successful revoke sends refresh token and clears session', () async {
    await account.signIn().timeout(_waitLimit);
    server.requests.clear();
    server.onRequest = (request) async {
      expect(request.uri.path, '/api/v1/oauth/revoke');
      expect(request.method, 'POST');
      expect(
        request.headers.contentType?.mimeType,
        'application/x-www-form-urlencoded',
      );
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(await _readForm(request), {
        'client_id': _clientId,
        'token': 'refresh-token',
      });
      expect(store.value, isNotNull);
      expect(account.signedIn, isTrue);
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
    };

    await account.signOut().timeout(_waitLimit);

    expect(server.requests, hasLength(1));
    expect(store.value, isNull);
    expect(store.clears, 1);
    expect(account.signedIn, isFalse);
    expect(account.profile, isNull);
    expect(account.summary, isNull);
    expect(account.subscriptionUrl, isNull);
    expect(account.error, isNull);
    expect(account.busy, isFalse);
  });

  test('failed revoke retains session and can be retried', () async {
    await account.signIn().timeout(_waitLimit);
    final saved = store.value;
    var attempts = 0;
    server.onRequest = (request) async {
      expect(request.uri.path, '/api/v1/oauth/revoke');
      expect(await _readForm(request), {
        'client_id': _clientId,
        'token': 'refresh-token',
      });
      attempts++;
      if (attempts == 1) {
        await _respond(request, {'error': 'server_error'}, status: 503);
      } else {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      }
    };

    await account.signOut().timeout(_waitLimit);

    expect(account.error, isNotEmpty);
    expect(account.signedIn, isTrue);
    expect(account.profile, _profile);
    expect(account.summary, _summary);
    expect(account.subscriptionUrl, _subscriptionUrl);
    expect(store.value, saved);
    expect(store.clears, 0);
    expect(account.busy, isFalse);

    await account.signOut().timeout(_waitLimit);

    expect(attempts, 2);
    expect(account.error, isNull);
    expect(account.signedIn, isFalse);
    expect(store.value, isNull);
    expect(store.clears, 1);
  });

  test('revoke connection failure retains saved session for retry', () async {
    await account.signIn().timeout(_waitLimit);
    final saved = store.value;
    await server.close();

    await account.signOut().timeout(_waitLimit);

    expect(account.error, isNotEmpty);
    expect(account.busy, isFalse);
    expect(account.signedIn, isTrue);
    expect(account.profile, _profile);
    expect(account.summary, _summary);
    expect(account.subscriptionUrl, _subscriptionUrl);
    expect(store.value, saved);
    expect(store.clears, 0);
    expect(store.writes, hasLength(1));
  });

  for (final url in [
    'http://subscriptions.example.com/client',
    '/relative/subscription',
    'https:///missing-host',
    'https://user:password@subscriptions.example.com/client',
    'https://user@subscriptions.example.com/client',
    'https://[invalid',
  ]) {
    test('rejects unsafe subscription URL: $url', () async {
      await account.signIn().timeout(_waitLimit);
      expect(account.subscriptionUrl, _subscriptionUrl);
      server.subscription = {'available': true, 'url': url};

      await account.reload().timeout(_waitLimit);

      expect(account.subscriptionUrl, isNull);
      expect(account.error, isNotEmpty);
      expect(account.signedIn, isTrue);
      expect(account.busy, isFalse);
      expect(store.clears, 0);
    });
  }

  test('unavailable subscription does not expose a URL', () async {
    await account.signIn().timeout(_waitLimit);
    server.subscription = {'available': false, 'url': _subscriptionUrl};

    await account.reload().timeout(_waitLimit);

    expect(account.subscriptionUrl, isNull);
    expect(account.error, isNull);
  });

  test('cancelled login leaves no session or error', () async {
    auth.cancel = true;

    await account.signIn().timeout(_waitLimit);

    expect(auth.requests, hasLength(1));
    expect(account.error, isNull);
    expect(account.busy, isFalse);
    expect(account.signedIn, isFalse);
    expect(account.profile, isNull);
    expect(account.summary, isNull);
    expect(account.subscriptionUrl, isNull);
    expect(store.value, isNull);
    expect(store.writes, isEmpty);
    expect(store.clears, 0);
    expect(server.requests, isEmpty);
  });

  test(
    'subscription import uses only API alternatives after network failure',
    () async {
      const alternate = 'https://alternate.example.com/client?token=private';
      server.subscription = {
        ..._subscription,
        'domains': [
          ..._subscription['domains'] as List,
          {'domain': 'alternate.example.com', 'url': alternate},
        ],
      };
      await account.signIn().timeout(_waitLimit);
      final attempts = <String>[];

      await account
          .importSubscription((url) async {
            attempts.add(url);
            if (url == _subscriptionUrl) {
              throw const SocketException('unreachable');
            }
          })
          .timeout(_waitLimit);

      expect(attempts, [_subscriptionUrl, alternate]);
      expect(account.subscriptionUrl, alternate);
      attempts.clear();
      await account.importSubscription((url) async => attempts.add(url));
      expect(attempts, [alternate]);
    },
  );

  test(
    'subscription import does not retry rejected or invalid content',
    () async {
      server.subscription = {
        ..._subscription,
        'domains': [
          {'url': 'https://alternate.example.com/client?token=private'},
        ],
      };
      await account.signIn().timeout(_waitLimit);
      for (final failure in [
        const HttpException('forbidden'),
        const FormatException('unsupported content'),
      ]) {
        final attempts = <String>[];
        await expectLater(
          account.importSubscription((url) async {
            attempts.add(url);
            throw failure;
          }),
          throwsA(same(failure)),
        );
        expect(attempts, [_subscriptionUrl]);
      }
    },
  );

  test('cancelled reauthentication preserves the existing session', () async {
    await account.signIn().timeout(_waitLimit);
    final saved = store.value;
    server.requests.clear();
    auth.cancel = true;

    await account.signIn().timeout(_waitLimit);

    expect(account.error, isNull);
    expect(account.busy, isFalse);
    expect(account.signedIn, isTrue);
    expect(account.profile, _profile);
    expect(account.summary, _summary);
    expect(account.subscriptionUrl, _subscriptionUrl);
    expect(store.value, saved);
    expect(store.writes, hasLength(1));
    expect(store.clears, 0);
    expect(server.requests, isEmpty);
  });
}

Map<String, dynamic> _session({int? expiresAt}) => {
  'access_token': 'access-token',
  'refresh_token': 'refresh-token',
  'expires_at': expiresAt ?? _expiry.millisecondsSinceEpoch,
  'client_id': _clientId,
};

class _MemorySessionStore implements AccountSessionStore {
  String? value;
  final writes = <String>[];
  var clears = 0;

  Map<String, dynamic> get session =>
      (jsonDecode(value!) as Map).cast<String, dynamic>();

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes.add(value);
    this.value = value;
  }

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }
}

class _AppAuth extends FlutterAppAuth {
  final requests = <AuthorizationTokenRequest>[];
  var cancel = false;

  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    requests.add(request);
    if (cancel) {
      throw FlutterAppAuthUserCancelledException(
        code: 'user_cancelled',
        platformErrorDetails: FlutterAppAuthPlatformErrorDetails(),
      );
    }
    return AuthorizationTokenResponse(
      'access-token',
      'refresh-token',
      _expiry,
      null,
      'Bearer',
      ['profile', 'subscription:read', 'plan:read'],
      null,
      null,
    );
  }
}

class _AccountServer {
  _AccountServer(this._server);

  final HttpServer _server;
  final requests = <HttpRequest>[];
  Map<String, dynamic> subscription = _subscription;
  Future<void> Function(HttpRequest)? onRequest;
  var _closed = false;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_AccountServer> start() async {
    final fixture = _AccountServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture._server.listen((request) async {
      fixture.requests.add(request);
      final handler = fixture.onRequest ?? fixture.respondWithResource;
      await handler(request);
    });
    return fixture;
  }

  Future<void> respondWithResource(HttpRequest request) async {
    final data = switch (request.uri.path) {
      '/api/v1/client/profile' => _profile,
      '/api/v1/client/summary' => _summary,
      '/api/v1/client/subscription' => subscription,
      _ => null,
    };
    expect(data, isNotNull, reason: 'Unexpected request: ${request.uri}');
    await _respond(request, data!);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
  }
}

Future<Map<String, String>> _readForm(HttpRequest request) async =>
    Uri.splitQueryString(await utf8.decoder.bind(request).join());

Future<void> _respond(
  HttpRequest request,
  Map<String, dynamic> data, {
  int status = HttpStatus.ok,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(data));
  await request.response.close();
}
