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
const _baseScope = 'profile subscription:read plan:read';
const _allScopes = '$_baseScope profile:write nodes:read reset_tickets:read '
    'reset_tickets:redeem subscription:write devices:read devices:write '
    'orders:read support:read support:write content:read';
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

  test('discovery pins OAuth API and preserves its issued subscription URL', () async {
    var discoveries = 0;
    final issuedUrl = server.uri.replace(
      scheme: 'https',
      path: '/sub/account%2Ftoken',
      query: 'format=clash-meta&token=private%2Bvalue',
    ).toString();
    server.subscription = {
      ..._subscription,
      'domains': [{'url': issuedUrl}],
    };
    account.dispose();
    account = ProximaAccount(
      clientId: _clientId,
      auth: auth,
      store: store,
      serverResolver: () async {
        discoveries++;
        return server.uri;
      },
    );
    await account.signIn().timeout(_waitLimit);
    expect(account.error, isNull);
    expect(auth.requests.single.serviceConfiguration!.authorizationEndpoint,
        server.uri.resolve('/oauth/authorize').toString());
    expect(auth.requests.single.serviceConfiguration!.tokenEndpoint,
        server.uri.resolve('/api/v1/oauth/token').toString());
    expect(server.requests.map((request) => request.uri.path), containsAll([
      '/api/v1/client/profile',
      '/api/v1/client/summary',
      '/api/v1/client/subscription',
    ]));
    final imports = <Uri>[];
    await account.importSubscription((url) async => imports.add(Uri.parse(url)));
    expect(imports.single.host, server.uri.host);
    expect(imports.single.port, server.uri.port);
    expect(imports.single.toString(), issuedUrl);
    expect(account.ownsSubscription(_subscriptionUrl), isFalse);
    expect(account.ownsSubscription(imports.single.toString()), isTrue);
    expect(discoveries, 1);
  });

  test('later API requests keep the backend selected for OAuth', () async {
    final replacement = await _AccountServer.start();
    addTearDown(replacement.close);
    var selectedServer = server.uri;
    server.subscription = {
      ..._subscription,
      'url': server.uri.replace(scheme: 'https', path: '/sub/account').toString(),
    };
    account.dispose();
    account = ProximaAccount(
      clientId: _clientId,
      auth: auth,
      store: store,
      serverResolver: () async => selectedServer,
    );
    await account.signIn().timeout(_waitLimit);
    expect(account.error, isNull);
    final oldRequests = server.requests.length;
    selectedServer = replacement.uri;
    await account.reload().timeout(_waitLimit);
    expect(account.error, isNull);
    expect(server.requests, hasLength(oldRequests + 3));
    expect(replacement.requests, isEmpty);
    for (final request in server.requests) {
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer access-token');
    }
  });

  test('does not rewrite or import a subscription from another backend', () async {
    account.dispose();
    account = ProximaAccount(
      clientId: _clientId,
      auth: auth,
      store: store,
      serverResolver: () async => server.uri,
    );
    await account.signIn().timeout(_waitLimit);
    expect(account.subscriptionUrl, isNull);
    expect(account.error, isNotNull);
    final imported = <String>[];
    await expectLater(
      account.importSubscription((url) async => imported.add(url)),
      throwsStateError,
    );
    expect(imported, isEmpty);
  });

  test('discovery failure sends no credentials to a fixed fallback', () async {
    account.dispose();
    account = ProximaAccount(
      clientId: _clientId,
      auth: auth,
      store: store,
      serverResolver: () async => throw const SocketException('all offline'),
    );
    await account.signIn().timeout(_waitLimit);
    expect(auth.requests, isEmpty);
    expect(server.requests, isEmpty);
    expect(account.signedIn, isFalse);
    expect(store.writes, isEmpty);
    expect(account.error, isNotNull);
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

  test('plan name follows the authenticated API summary on reload', () async {
    server.summary = {..._summary, 'plan_name': ' Everyday Plus '};
    await account.signIn().timeout(_waitLimit);
    expect(account.planName, 'Everyday Plus');

    server.summary = {..._summary, 'plan_name': 'Premium'};
    await account.reload().timeout(_waitLimit);
    expect(account.planName, 'Premium');

    for (final name in [null, '', '   ']) {
      server.summary = {..._summary, 'plan_name': name};
      await account.reload().timeout(_waitLimit);
      expect(account.planName, isNull);
    }
  });

  test('recognizes only this account subscription URLs and alternates', () async {
    const alternate = 'https://alternate.example.com/client?token=private';
    server.subscription = {
      ..._subscription,
      'domains': [
        {'url': alternate},
      ],
    };
    await account.signIn().timeout(_waitLimit);
    expect(account.ownsSubscription(_subscriptionUrl), isTrue);
    expect(account.ownsSubscription(alternate), isTrue);
    expect(
      account.ownsSubscription('https://subscriptions.example.com/other'),
      isFalse,
    );
    expect(account.ownsSubscription(null), isFalse);
    expect(account.ownsSubscription(''), isFalse);
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
      'scope': _baseScope,
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
      expect(account.ownsSubscription(_subscriptionUrl), isTrue);
      expect(account.ownsSubscription(alternate), isTrue);
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

  Future<void> initializeAllScopes() async {
    store.value = jsonEncode(_session(scope: _allScopes));
    await account.initialize().timeout(_waitLimit);
    expect(account.error, isNull);
    server.requests.clear();
  }

  test('legacy saved sessions have exactly base scopes and sections stay lazy', () async {
    store.value = jsonEncode(_session()..remove('scope'));
    await account.initialize().timeout(_waitLimit);
    expect(account.grantedScopes, ProximaAccount.scopes.toSet());
    expect(account.nodesState.data, isNull);
    expect(account.nodesState.loading, isFalse);
    expect(account.profileState.data, _profile);
    expect(server.requests, hasLength(3));
    await account.loadSection(AccountSection.nodes);
    expect(account.nodesState.error?.requiredScope, 'nodes:read');
    expect(account.nodesState.error?.code, 'insufficient_scope');
    expect(server.requests, hasLength(3));
    expect(auth.requests, isEmpty);
  });

  test('all lazy routes accept direct maps and arrays without payment APIs', () async {
    await initializeAllScopes();
    final resources = <String, Object>{
      'subscription-domains': [
        {'id': 'domain', 'domain': 'example.com', 'is_default': true, 'display_order': 0},
      ],
      'traffic': {'traffic_used': 3, 'traffic_limit': null},
      'nodes': [
        {'name': 'Tokyo', 'country': 'JP', 'region': 'Tokyo', 'status': 'online'},
      ],
      'reset-tickets': [{'id': 'reset', 'name': 'Reset'}],
      'reset-tickets/history': [{'id': 'used', 'name': 'Used'}],
      'devices': [{'id': 'device', 'name': 'Phone'}],
      'orders': [{'id': 'order', 'status': 'paid', 'price_cents': 100}],
      'support/faq': {'categories': <Object>[], 'faqs': <Object>[]},
      'support/tickets': [{'id': 'ticket', 'subject': 'Help', 'status': 'open'}],
      'announcements': [{'id': 'announcement', 'title': 'Notice'}],
      'guides': {
        'categories': <Object>[],
        'guides': [{'id': 'guide', 'title': 'Setup'}],
      },
    };
    server.onRequest = (request) async {
      expect(request.method, 'GET');
      final key = request.uri.path.substring('/api/v1/client/'.length);
      expect(resources, contains(key));
      await _respond(request, resources[key]!);
    };
    for (final section in AccountSection.values.skip(3)) {
      await account.loadSection(section).timeout(_waitLimit);
    }
    expect(server.requests, hasLength(resources.length));
    expect(account.domainsState.data?.single['id'], 'domain');
    expect(account.trafficState.data?['traffic_used'], 3);
    expect(account.nodesState.data?.single['name'], 'Tokyo');
    expect(account.resetTicketsState.data?.single['id'], 'reset');
    expect(account.resetHistoryState.data?.single['id'], 'used');
    expect(account.devicesState.data?.single['id'], 'device');
    expect(account.ordersState.data?.single['id'], 'order');
    expect(account.faqState.data?['faqs'], isEmpty);
    expect(account.ticketsState.data?.single['id'], 'ticket');
    expect(account.announcementsState.data?.single['id'], 'announcement');
    expect(account.guidesState.data?['guides'], hasLength(1));
    expect(() => account.nodesState.data!.clear(), throwsUnsupportedError);
    expect(() => account.nodesState.data!.single['name'] = 'Changed', throwsUnsupportedError);
    expect(() => (account.guidesState.data!['guides'] as List).clear(), throwsUnsupportedError);
    expect(account.grantedScopes, isNot(contains('orders:write')));
  });

  test('resource loads coalesce and retain cached data after refresh failure', () async {
    await initializeAllScopes();
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    server.onRequest = (request) async {
      arrived.complete();
      await release.future;
      await _respond(request, [{'id': 'device', 'name': 'Phone'}]);
    };
    final first = account.loadSection(AccountSection.devices);
    await arrived.future.timeout(_waitLimit);
    final second = account.loadSection(AccountSection.devices, force: true);
    expect(identical(first, second), isTrue);
    expect(account.devicesState.loading, isTrue);
    release.complete();
    await Future.wait([first, second]).timeout(_waitLimit);
    await account.loadSection(AccountSection.devices);
    expect(server.requests, hasLength(1));
    server.onRequest = (request) =>
        _respond(request, {'error': 'insufficient_scope'}, status: 403);
    await account.loadSection(AccountSection.devices, force: true);
    expect(account.devicesState.data?.single['id'], 'device');
    expect(account.devicesState.error?.statusCode, 403);
    expect(account.devicesState.error?.requiredScope, 'devices:read');
    expect(account.devicesState.loading, isFalse);
  });

  test('malformed rows and nested containers fail without partial results', () async {
    await initializeAllScopes();
    for (final data in <Object>[
      [{'id': 'valid', 'name': 'Phone'}, 4],
      [{'name': 'Missing ID'}],
      {'devices': <Object>[]},
    ]) {
      server.onRequest = (request) => _respond(request, data);
      await account.loadSection(AccountSection.devices, force: true);
      expect(account.devicesState.error?.code, 'invalid_response');
      expect(account.devicesState.data, isNull);
    }
    server.onRequest = (request) => _respond(request, {
      'categories': <Object>[], 'guides': [{'id': 'guide', 'title': 12}],
    });
    await account.loadSection(AccountSection.guides);
    expect(account.guidesState.error?.code, 'invalid_response');
    server.onRequest = (request) => _respond(request, {
      ..._subscription, 'domains': [5],
    });
    await account.loadSection(AccountSection.subscription, force: true);
    expect(account.subscriptionState.error?.code, 'invalid_response');
    expect(account.subscriptionUrl, isNull);
  });

  test('incremental grant persists scopes only after same identity confirmation', () async {
    await account.signIn();
    final epoch = account.sessionEpoch;
    auth.responseScopes = [...ProximaAccount.scopes, 'devices:read'];
    expect(await account.requestGrant(AccountGrant.devicesRead), isTrue);
    expect(auth.requests.last.scopes, [...ProximaAccount.scopes, 'devices:read']);
    expect(account.hasGrant(AccountGrant.devicesRead), isTrue);
    expect(store.session['scope'], '$_baseScope devices:read');
    expect(account.sessionEpoch, greaterThan(epoch));
    final requests = auth.requests.length;
    expect(await account.requestGrant(AccountGrant.devicesRead), isTrue);
    expect(auth.requests, hasLength(requests));
    expect(auth.requests.expand((request) => request.scopes!), isNot(contains('orders:write')));
  });

  test('write authorization includes its management read permission', () async {
    await account.signIn();
    auth.responseScopes = [
      ...ProximaAccount.scopes, 'devices:write', 'devices:read',
    ];
    expect(await account.requestGrant(AccountGrant.devicesWrite), isTrue);
    expect(auth.requests.last.scopes, containsAll([
      ...ProximaAccount.scopes, 'devices:write', 'devices:read',
    ]));
    expect(account.hasGrant(AccountGrant.devicesRead), isTrue);
  });

  test('cancelled and partially denied grants preserve the prior session', () async {
    await account.signIn();
    final saved = store.value;
    auth.cancel = true;
    expect(await account.requestGrant(AccountGrant.devicesRead), isFalse);
    expect(store.value, saved);
    auth.cancel = false;
    expect(await account.requestGrant(AccountGrant.devicesRead), isFalse);
    expect(store.value, saved);
    expect(account.profile, _profile);
    expect(account.hasGrant(AccountGrant.devicesRead), isFalse);
    expect(store.writes, hasLength(1));
  });

  test('incremental grant rejects an account identity change', () async {
    await account.signIn();
    final saved = store.value;
    auth.responseScopes = [...ProximaAccount.scopes, 'devices:read'];
    var profiles = 0;
    server.onRequest = (request) => _respond(request,
      ++profiles == 1 ? _profile : {..._profile, 'id': 'another-account'});
    await expectLater(account.requestGrant(AccountGrant.devicesRead),
      throwsA(isA<ProximaAccountException>()
        .having((error) => error.code, 'code', 'identity_changed')));
    expect(store.value, saved);
    expect(account.profile, _profile);
    expect(account.hasGrant(AccountGrant.devicesRead), isFalse);
  });

  test('native authorization denial retains the old session and grants', () async {
    await account.signIn();
    final saved = store.value;
    auth.failure = FlutterAppAuthPlatformException(
      code: 'authorize_and_exchange_code_failed',
      platformErrorDetails: FlutterAppAuthPlatformErrorDetails(error: 'access_denied'),
    );
    expect(await account.requestGrant(AccountGrant.devicesRead), isFalse);
    expect(store.value, saved);
    expect(account.grantedScopes, ProximaAccount.scopes.toSet());
  });

  test('sign-out invalidates an authorization callback still in flight', () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    auth.beforeResponse = () async {
      arrived.complete();
      await release.future;
    };
    final login = account.signIn();
    await arrived.future.timeout(_waitLimit);
    await account.signOut().timeout(_waitLimit);
    release.complete();
    await login.timeout(_waitLimit);
    expect(account.signedIn, isFalse);
    expect(store.writes, isEmpty);
    expect(server.requests, isEmpty);
  });

  test('refresh scope narrowing prevents a previously authorized write', () async {
    store.value = jsonEncode(_session(expiresAt: 0, scope: _allScopes));
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    // Initialize first, then force a reactive 401 refresh through a detail read.
    store.value = jsonEncode(_session(scope: _allScopes));
    await account.initialize();
    server.requests.clear();
    server.onRequest = (request) async {
      if (request.uri.path == '/api/v1/oauth/token') {
        arrived.complete();
        await release.future;
        await _respond(request, {
          'access_token': 'narrowed', 'refresh_token': 'narrowed-refresh',
          'expires_in': 3600, 'scope': _baseScope,
        });
      } else {
        await _respond(request, {'error': 'invalid_token'}, status: 401);
      }
    };
    final detail = expectLater(account.fetchReceipt('order'),
      throwsA(isA<ProximaAccountException>().having(
        (e) => e.requiredScope, 'scope', 'orders:read')));
    await arrived.future.timeout(_waitLimit);
    release.complete();
    await detail.timeout(_waitLimit);
    final count = server.requests.length;
    await expectLater(account.addDevice(name: 'Phone'),
      throwsA(isA<ProximaAccountException>().having(
        (e) => e.requiredScope, 'scope', 'devices:write')));
    expect(server.requests, hasLength(count));
    expect(account.grantedScopes, ProximaAccount.scopes.toSet());
    expect(store.session['scope'], _baseScope);
  });

  test('refresh preserves or narrows existing scopes and never widens them', () async {
    for (final returnedScope in <String?>[null, '$_allScopes orders:write']) {
      store.value = jsonEncode(_session(expiresAt: 0, scope: '$_baseScope devices:read'));
      server.onRequest = (request) async {
        if (request.uri.path == '/api/v1/oauth/token') {
          final form = await _readForm(request);
          expect(form.containsKey('scope'), isFalse);
          await _respond(request, {
            'access_token': 'new', 'refresh_token': 'new-refresh', 'expires_in': 3600,
            'scope': ?returnedScope,
          });
        } else {
          await server.respondWithResource(request);
        }
      };
      await account.initialize().timeout(_waitLimit);
      expect(account.error, isNull);
      expect(account.grantedScopes, {...ProximaAccount.scopes, 'devices:read'});
      expect(store.session['scope'], '$_baseScope devices:read');
    }
  });

  test('read details use only GET and validate receipt conversation and guide', () async {
    await initializeAllScopes();
    final data = <String, Object>{
      '/api/v1/client/orders/order/receipt': {'order_id': 'order', 'price_cents': 100},
      '/api/v1/client/support/tickets/ticket': {
        'ticket': {'id': 'ticket'},
        'messages': [{'author_type': 'user', 'body': 'Help'}],
      },
      '/api/v1/client/guides/guide': {'title': 'Setup', 'rendered_html': '<p>Text</p>'},
    };
    server.onRequest = (request) async {
      expect(request.method, 'GET');
      expect(data, contains(request.uri.path));
      await _respond(request, data[request.uri.path]!);
    };
    expect((await account.fetchReceipt('order'))['order_id'], 'order');
    expect((await account.fetchTicket('ticket'))['messages'], hasLength(1));
    expect((await account.fetchGuide('guide'))['title'], 'Setup');
    server.onRequest = (request) => _respond(request, <Object>[]);
    await expectLater(account.fetchReceipt('order'),
      throwsA(isA<ProximaAccountException>().having((e) => e.code, 'code', 'invalid_response')));
  });

  test('all writes send exact allowed routes and JSON then refresh affected resources', () async {
    await initializeAllScopes();
    final writes = <List<Object?>>[];
    server.onRequest = (request) async {
      if (request.method != 'GET') {
        expect(request.headers.contentType?.mimeType, 'application/json');
        writes.add([request.method, request.uri.path,
          jsonDecode(await utf8.decoder.bind(request).join())]);
        if (request.uri.path == '/api/v1/client/support/tickets') {
          await _respond(request, {'id': 'created'});
        } else {
          request.response.statusCode = 204;
          await request.response.close();
        }
      } else if (['profile', 'summary', 'subscription'].any(
          (resource) => request.uri.path == '/api/v1/client/$resource')) {
        await server.respondWithResource(request);
      } else if (request.uri.path == '/api/v1/client/traffic') {
        await _respond(request, {'traffic_used': 0, 'traffic_limit': null});
      } else {
        await _respond(request, <Object>[]);
      }
    };
    await account.updateProfile(name: 'Changed', language: 'en');
    await account.addDevice(name: 'Tablet');
    await account.removeDevice('device/one');
    await account.redeemResetTicket('reset');
    expect(await account.createSupportTicket(
      categoryId: 'category', subject: 'Help', body: 'Question'), 'created');
    await account.replyToTicket('ticket', body: 'Reply');
    await account.closeSupportTicket('ticket');
    await account.regenerateSubscription();
    expect(writes, [
      ['PUT', '/api/v1/client/profile', {'name': 'Changed', 'language': 'en'}],
      ['POST', '/api/v1/client/devices', {'name': 'Tablet'}],
      ['DELETE', '/api/v1/client/devices/device%2Fone', <String, Object?>{}],
      ['POST', '/api/v1/client/reset-tickets/reset/redeem', <String, Object?>{}],
      ['POST', '/api/v1/client/support/tickets',
        {'category_id': 'category', 'subject': 'Help', 'body': 'Question'}],
      ['POST', '/api/v1/client/support/tickets/ticket/messages', {'body': 'Reply'}],
      ['POST', '/api/v1/client/support/tickets/ticket/close', <String, Object?>{}],
      ['POST', '/api/v1/client/sub-token/regenerate', <String, Object?>{}],
    ]);
    expect(server.requests.where((r) => r.method != 'GET' &&
      (r.uri.path.contains('orders') || r.uri.path.contains('payment'))), isEmpty);
    expect(account.mutationBusy, isFalse);
  });

  test('one mutation guard rejects duplicates while the first write is pending', () async {
    await initializeAllScopes();
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    server.onRequest = (request) async {
      if (request.method == 'POST') {
        arrived.complete();
        await release.future;
        await _respond(request, {'id': 'device', 'name': 'Phone'});
      } else if (request.uri.path.endsWith('/summary')) {
        await server.respondWithResource(request);
      } else {
        await _respond(request, <Object>[]);
      }
    };
    final first = account.addDevice(name: 'Phone');
    await arrived.future.timeout(_waitLimit);
    expect(account.mutationBusy, isTrue);
    await expectLater(account.addDevice(name: 'Phone'),
      throwsA(isA<ProximaAccountException>().having((e) => e.code, 'code', 'mutation_busy')));
    await expectLater(account.closeSupportTicket('ticket'),
      throwsA(isA<ProximaAccountException>().having((e) => e.code, 'code', 'mutation_busy')));
    expect(server.requests, hasLength(1));
    release.complete();
    await first.timeout(_waitLimit);
    expect(account.mutationBusy, isFalse);
  });

  test('successful mutation remains successful when the follow-up read fails', () async {
    await initializeAllScopes();
    var writes = 0;
    server.onRequest = (request) async {
      if (request.method == 'PUT') {
        writes++;
        await _respond(request, _profile);
      } else {
        await _respond(request, {'error': 'server_error'}, status: 503);
      }
    };
    await account.updateProfile(name: 'Changed', language: 'en');
    expect(writes, 1);
    expect(account.profileState.data, _profile);
    expect(account.profileState.error?.statusCode, 503);
  });

  test('regeneration discards retired URLs even when subscription refresh fails', () async {
    await initializeAllScopes();
    server.onRequest = (request) async {
      if (request.method == 'POST') {
        await _respond(request, {'url': 'https://ignored.example.com/new'});
      } else {
        await _respond(request, {'error': 'server_error'}, status: 503);
      }
    };
    await account.regenerateSubscription();
    expect(account.subscriptionUrl, isNull);
    expect(account.importableSubscriptionUrls, isEmpty);
    expect(account.ownsSubscription(_subscriptionUrl), isFalse);
    expect(account.subscriptionState.data, isNull);
    expect(account.subscriptionState.error?.statusCode, 503);
    expect(() => account.selectSubscriptionUrl(_subscriptionUrl),
      throwsA(isA<ProximaAccountException>()));
  });

  for (final code in ['used', 'expired', 'no_plan']) {
    test('reset conflict preserves the machine-readable $code reason', () async {
      await initializeAllScopes();
      server.onRequest = (request) => _respond(request, {
        'error': 'reset ticket is not applicable',
        'code': code,
      }, status: 409);
      await expectLater(
        account.redeemResetTicket('reset'),
        throwsA(isA<ProximaAccountException>()
            .having((failure) => failure.statusCode, 'status', 409)
            .having((failure) => failure.code, 'reason', code)),
      );
      expect(server.requests, hasLength(1));
    });
  }

  for (final status in [401, 409, 503]) {
    test('write status $status is contextual and never automatically replayed', () async {
      await initializeAllScopes();
      server.onRequest = (request) => _respond(request, {
        'error': status == 401 ? 'invalid_token' : 'conflict',
      }, status: status);
      await expectLater(account.redeemResetTicket('used'),
        throwsA(isA<ProximaAccountException>().having((e) => e.statusCode, 'status', status)));
      expect(server.requests, hasLength(1));
      expect(server.requests.single.method, 'POST');
      expect(account.signedIn, isTrue);
      expect(account.mutationBusy, isFalse);
    });
  }

  test('late section and detail results cannot repopulate a signed-out account', () async {
    await initializeAllScopes();
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    var pending = 0;
    server.onRequest = (request) async {
      if (request.uri.path == '/api/v1/oauth/revoke') {
        request.response.statusCode = 204;
        await request.response.close();
      } else {
        if (++pending == 2) arrived.complete();
        await release.future;
        await _respond(request, request.uri.path.endsWith('/devices')
          ? [{'id': 'old', 'name': 'Old'}]
          : {'order_id': 'old', 'price_cents': 100});
      }
    };
    final section = account.loadSection(AccountSection.devices);
    final detail = expectLater(account.fetchReceipt('old'),
      throwsA(isA<ProximaAccountException>().having((e) => e.code, 'code', 'stale_session')));
    await arrived.future.timeout(_waitLimit);
    await account.signOut().timeout(_waitLimit);
    release.complete();
    await Future.wait([section, detail]).timeout(_waitLimit);
    expect(account.devicesState.data, isNull);
    expect(account.signedIn, isFalse);
    expect(store.value, isNull);
  });

  test('late refresh cannot resurrect tokens after sign-out', () async {
    store.value = jsonEncode(_session(expiresAt: 0));
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    server.onRequest = (request) async {
      if (request.uri.path == '/api/v1/oauth/token') {
        arrived.complete();
        await release.future;
        await _respond(request, {
          'access_token': 'late', 'refresh_token': 'late-refresh', 'expires_in': 3600,
        });
      } else {
        expect(request.uri.path, '/api/v1/oauth/revoke');
        request.response.statusCode = 204;
        await request.response.close();
      }
    };
    final initializing = account.initialize();
    await arrived.future.timeout(_waitLimit);
    await account.signOut().timeout(_waitLimit);
    release.complete();
    await initializing.timeout(_waitLimit);
    expect(account.signedIn, isFalse);
    expect(store.value, isNull);
    expect(store.writes, isEmpty);
    expect(account.profile, isNull);
  });

  test('replacement session ignores an old pending resource response', () async {
    await initializeAllScopes();
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    server.onRequest = (request) async {
      if (request.uri.path.endsWith('/devices')) {
        arrived.complete();
        await release.future;
        await _respond(request, [{'id': 'old', 'name': 'Old'}]);
      } else if (request.uri.path.endsWith('/revoke')) {
        request.response.statusCode = 204;
        await request.response.close();
      } else {
        await server.respondWithResource(request);
      }
    };
    final loading = account.loadSection(AccountSection.devices);
    await arrived.future.timeout(_waitLimit);
    await account.signOut();
    await account.signIn();
    final epoch = account.sessionEpoch;
    release.complete();
    await loading.timeout(_waitLimit);
    expect(account.sessionEpoch, epoch);
    expect(account.signedIn, isTrue);
    expect(account.devicesState.data, isNull);
    expect(account.profile, _profile);
    expect(store.session['scope'], _baseScope);
  });

  test('late import completion cannot restore regenerated subscription URLs', () async {
    await initializeAllScopes();
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final importing = expectLater(account.importSubscription((url) async {
      arrived.complete();
      await release.future;
    }), throwsA(isA<ProximaAccountException>()));
    await arrived.future.timeout(_waitLimit);
    server.onRequest = (request) async {
      if (request.method == 'POST') {
        await _respond(request, {});
      } else if (request.uri.path.endsWith('/subscription')) {
        await _respond(request, {'available': false, 'url': null});
      } else {
        await _respond(request, <Object>[]);
      }
    };
    await account.regenerateSubscription();
    release.complete();
    await importing.timeout(_waitLimit);
    expect(account.importableSubscriptionUrls, isEmpty);
  });

  test('dispose during a pending store write clears it without notification', () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    store.beforeWrite = () async {
      arrived.complete();
      await release.future;
    };
    final login = account.signIn();
    await arrived.future.timeout(_waitLimit);
    account.dispose();
    release.complete();
    await login.timeout(_waitLimit);
    expect(store.value, isNull);
    expect(account.signedIn, isFalse);
    expect(server.requests, isEmpty);
    // tearDown owns a fresh notifier, not the disposed instance.
    account = ProximaAccount(clientId: _clientId, auth: auth, store: store, server: server.uri);
  });
}

Map<String, dynamic> _session({int? expiresAt, String scope = _baseScope}) => {
  'access_token': 'access-token',
  'refresh_token': 'refresh-token',
  'expires_at': expiresAt ?? _expiry.millisecondsSinceEpoch,
  'client_id': _clientId,
  'scope': scope,
};

class _MemorySessionStore implements AccountSessionStore {
  String? value;
  final writes = <String>[];
  var clears = 0;
  Future<void> Function()? beforeWrite;

  Map<String, dynamic> get session =>
      (jsonDecode(value!) as Map).cast<String, dynamic>();

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes.add(value);
    await beforeWrite?.call();
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
  List<String>? responseScopes;
  FlutterAppAuthPlatformException? failure;
  Future<void> Function()? beforeResponse;

  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) async {
    requests.add(request);
    await beforeResponse?.call();
    final error = failure;
    if (error != null) throw error;
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
      responseScopes ?? ['profile', 'subscription:read', 'plan:read'],
      null,
      null,
    );
  }
}

class _AccountServer {
  _AccountServer(this._server);

  final HttpServer _server;
  final requests = <HttpRequest>[];
  Map<String, dynamic> summary = _summary;
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
      '/api/v1/client/summary' => summary,
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
  Object data, {
  int status = HttpStatus.ok,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(data));
  await request.response.close();
}
