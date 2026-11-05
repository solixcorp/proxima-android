import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'proxima_user_agent.dart';
import 'proxima_website.dart';

abstract interface class AccountSessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureAccountSessionStore implements AccountSessionStore {
  const SecureAccountSessionStore();

  static const _storage = FlutterSecureStorage();
  static const _key = 'proxima.oauth.session';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class ProximaAccountException implements Exception {
  const ProximaAccountException(
    this.message, {this.code, this.statusCode, this.requiredScope}
  );

  final String message;
  final String? code;
  final int? statusCode;
  final String? requiredScope;

  @override
  String toString() => message;
}

typedef AccountJson = Map<String, Object?>;

class AccountValue<T> {
  const AccountValue({this.data, this.loading = false, this.error});
  final T? data;
  final bool loading;
  final ProximaAccountException? error;
}

enum AccountSection {
  profile, summary, subscription, domains, traffic, nodes, resetTickets,
  resetHistory, devices, orders, faq, tickets, announcements, guides,
}

enum AccountGrant {
  profileWrite, nodesRead, resetTicketsRead, resetTicketsRedeem,
  subscriptionWrite, devicesRead, devicesWrite, ordersRead,
  supportRead, supportWrite, contentRead,
}

class ProximaAccount extends ChangeNotifier {
  ProximaAccount({
    this.clientId = const String.fromEnvironment(
      'PROXIMA_OAUTH_CLIENT_ID',
      defaultValue: 'pxc_mijtWOQwez9cG08Zq4MevOY-',
    ),
    FlutterAppAuth? auth,
    AccountSessionStore? store,
    this.server,
    Future<Uri> Function()? serverResolver,
  }) : _auth = auth ?? const FlutterAppAuth(),
       _store = store ?? const SecureAccountSessionStore(),
       _serverResolver = serverResolver ?? fetchProximaWebsite;

  static const redirectUri = 'kr.kimrasng.proxima://oauth/callback';
  static const scopes = ['profile', 'subscription:read', 'plan:read'];
  final String clientId;
  final FlutterAppAuth _auth;
  final AccountSessionStore _store;
  final Uri? server;
  final Future<Uri> Function() _serverResolver;
  Future<Uri>? _resolvingServer;
  Uri? _resolvedServer;

  Future<Uri> _resolveServer() async {
    final fixed = server ?? _resolvedServer;
    if (fixed != null) return fixed;
    final pending = _resolvingServer ??= _serverResolver();
    try {
      return _resolvedServer = await pending;
    } finally {
      if (identical(_resolvingServer, pending)) _resolvingServer = null;
    }
  }
  Map<String, dynamic>? _session;
  Future<void>? _refreshing;
  bool busy = false;
  String? error;
  Map<String, dynamic>? profile;
  Map<String, dynamic>? summary;
  String? subscriptionUrl;
  List<String> _subscriptionAlternates = const [];
  int _epoch = 0;
  bool _disposed = false;
  Object? _mutation;
  int _runId = 0;
  Future<void> _storeQueue = Future<void>.value();
  final _states = <AccountSection, AccountValue<Object>>{};
  final _loads = <AccountSection, Future<void>>{};
  final _versions = <AccountSection, Object>{};
  final _details = <String, Future<AccountJson>>{};

  int get sessionEpoch => _epoch;
  bool get mutationBusy => _mutation != null;
  Set<String> get grantedScopes => Set.unmodifiable(
    _session == null ? <String>{} : _scopeSet(_session!['scope']),
  );
  static const _grantScopes = {
    AccountGrant.profileWrite: 'profile:write',
    AccountGrant.nodesRead: 'nodes:read',
    AccountGrant.resetTicketsRead: 'reset_tickets:read',
    AccountGrant.resetTicketsRedeem: 'reset_tickets:redeem',
    AccountGrant.subscriptionWrite: 'subscription:write',
    AccountGrant.devicesRead: 'devices:read',
    AccountGrant.devicesWrite: 'devices:write',
    AccountGrant.ordersRead: 'orders:read',
    AccountGrant.supportRead: 'support:read',
    AccountGrant.supportWrite: 'support:write',
    AccountGrant.contentRead: 'content:read',
  };
  static Set<String> _scopeSet(Object? value) {
    if (value == null) return scopes.toSet();
    if (value is! String) throw _malformed();
    final allowed = {...scopes, ..._grantScopes.values};
    return value.split(RegExp(r'\s+')).where(allowed.contains).toSet();
  }

  bool hasGrant(AccountGrant grant) =>
      grantedScopes.contains(_grantScopes[grant]);

  AccountValue<T> _state<T>(AccountSection section) {
    final value = _states[section];
    return AccountValue<T>(
      data: value?.data as T?, loading: value?.loading ?? false,
      error: value?.error,
    );
  }

  AccountValue<AccountJson> get profileState => _state(AccountSection.profile);
  AccountValue<AccountJson> get summaryState => _state(AccountSection.summary);
  AccountValue<AccountJson> get subscriptionState =>
      _state(AccountSection.subscription);
  AccountValue<AccountJson> get trafficState => _state(AccountSection.traffic);
  AccountValue<AccountJson> get faqState => _state(AccountSection.faq);
  AccountValue<AccountJson> get guidesState => _state(AccountSection.guides);
  AccountValue<List<AccountJson>> get domainsState =>
      _state(AccountSection.domains);
  AccountValue<List<AccountJson>> get nodesState => _state(AccountSection.nodes);
  AccountValue<List<AccountJson>> get resetTicketsState =>
      _state(AccountSection.resetTickets);
  AccountValue<List<AccountJson>> get resetHistoryState =>
      _state(AccountSection.resetHistory);
  AccountValue<List<AccountJson>> get devicesState =>
      _state(AccountSection.devices);
  AccountValue<List<AccountJson>> get ordersState => _state(AccountSection.orders);
  AccountValue<List<AccountJson>> get ticketsState =>
      _state(AccountSection.tickets);
  AccountValue<List<AccountJson>> get announcementsState =>
      _state(AccountSection.announcements);

  List<String> get importableSubscriptionUrls => List.unmodifiable([
    ?subscriptionUrl, ..._subscriptionAlternates,
  ]);

  void selectSubscriptionUrl(String url) {
    if (!ownsSubscription(url)) {
      throw const ProximaAccountException('인증된 구독 주소를 선택해 주세요.');
    }
    final urls = importableSubscriptionUrls;
    subscriptionUrl = url;
    _subscriptionAlternates = urls.where((item) => item != url).toList();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _checkEpoch(int epoch) {
    if (!_current(epoch)) {
      throw const ProximaAccountException(
        '계정 세션이 변경되었습니다.', code: 'stale_session',
      );
    }
  }

  void _invalidate() {
    _epoch++;
    _refreshing = null;
    _loads.clear();
    _versions.clear();
    _details.clear();
    for (final section in _states.keys.toList()) {
      final state = _states[section]!;
      _states[section] = AccountValue(data: state.data, error: state.error);
    }
  }

  void _clearData() {
    profile = null;
    summary = null;
    subscriptionUrl = null;
    _subscriptionAlternates = const [];
    _states.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidate();
    super.dispose();
  }

  bool get signedIn => _session != null;
  bool get configured => clientId.isNotEmpty;

  String? get planName {
    final value = summary?['plan_name'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  bool ownsSubscription(String? source) =>
      signedIn &&
      source != null &&
      source.isNotEmpty &&
      (source == subscriptionUrl || _subscriptionAlternates.contains(source));

  AuthorizationServiceConfiguration _configuration(Uri server) =>
      AuthorizationServiceConfiguration(
        authorizationEndpoint: server.resolve('/oauth/authorize').toString(),
        tokenEndpoint: server.resolve('/api/v1/oauth/token').toString(),
      );

  Future<void> initialize() => _run(() async {
    final epoch = _epoch;
    await _storeQueue;
    final saved = await _store.read();
    _checkEpoch(epoch);
    if (saved == null) return;
    final session = (jsonDecode(saved) as Map).cast<String, dynamic>();
    if (session['client_id'] != clientId) {
      await _clearSession();
      return;
    }
    _validateSession(session);
    session['scope'] = _scopeSet(session['scope']).join(' ');
    _invalidate();
    _clearData();
    _session = session;
    await _loadData();
  });

  Future<void> signIn() => _run(() async {
    if (!configured) {
      throw const ProximaAccountException(
        'Android용 OAuth 앱의 Client ID를 먼저 설정해 주세요.',
      );
    }
    // Native AppAuth generates a fresh S256 verifier and state, validates the
    // callback state and exchanges the code once through the system browser.
    final epoch = _epoch;
    final server = await _resolveServer();
    _checkEpoch(epoch);
    final result = await _auth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        clientId,
        redirectUri,
        serviceConfiguration: _configuration(server),
        scopes: scopes,
      ),
    );
    _checkEpoch(epoch);
    _invalidate();
    final nextEpoch = _epoch;
    await _saveSession({
      'access_token': result.accessToken,
      'refresh_token': result.refreshToken,
      'expires_at': result.accessTokenExpirationDateTime
          ?.toUtc()
          .millisecondsSinceEpoch,
      'scope': _scopeSet((result.scopes ?? scopes).join(' '))
          .intersection(scopes.toSet()).join(' '),
    }, nextEpoch);
    _checkEpoch(nextEpoch);
    _clearData();
    await _loadData();
  });

  Future<void> reload() => _run(_loadData);

  Future<void> _loadData() async {
    if (!signedIn) return;
    final epoch = _epoch;
    await Future.wait([
      loadSection(AccountSection.profile, force: true),
      loadSection(AccountSection.summary, force: true),
      loadSection(AccountSection.subscription, force: true),
    ]);
    // A terminal refresh error clears section state as well as the session.
    if (!_current(epoch)) return;
    for (final section in [
      AccountSection.profile, AccountSection.summary, AccountSection.subscription,
    ]) {
      final failure = _states[section]?.error;
      if (failure != null) throw failure;
    }
  }

  Future<void> _readSubscription(
    AccountJson subscription, int epoch, Object version,
  ) async {
    final url = subscription['url'];
    subscriptionUrl = null;
    _subscriptionAlternates = const [];
    if (subscription['available'] == true && url is String) {
      final urls = <String>{
        url,
        for (final domain in subscription['domains'] as List? ?? const [])
          (domain as Map)['url'] as String,
      };
      for (final candidate in urls) {
        final uri = Uri.tryParse(candidate);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const ProximaAccountException('구독 서버가 잘못된 주소를 반환했습니다.');
        }
      }
      final backend = server == null ? await _resolveServer() : null;
      _checkEpoch(epoch);
      if (!identical(_versions[AccountSection.subscription], version)) return;
      final matching = urls.where((candidate) {
        if (backend == null) return true;
        final uri = Uri.parse(candidate);
        return uri.host == backend.host && uri.port == backend.port;
      }).toList();
      if (matching.isEmpty) {
        throw const ProximaAccountException(
          '현재 계정 API 서버와 같은 호스트의 구독 URL이 없습니다.',
        );
      }
      subscriptionUrl = matching.first;
      _subscriptionAlternates = matching
          .where((candidate) => candidate != subscriptionUrl)
          .toList();
    }
  }

  Future<void> importSubscription(Future<void> Function(String) import) async {
    final epoch = _epoch;
    final url = subscriptionUrl;
    if (url == null) throw StateError('가져올 수 있는 구독이 없습니다.');
    final candidates = [url, ..._subscriptionAlternates];
    for (var index = 0; index < candidates.length; index++) {
      _checkEpoch(epoch);
      final candidate = candidates[index];
      try {
        await import(candidate);
        _checkEpoch(epoch);
        if (!ownsSubscription(candidate)) {
          throw const ProximaAccountException('구독 주소가 변경되었습니다.');
        }
        subscriptionUrl = candidate;
        _subscriptionAlternates = {...candidates}
            .where((url) => url != candidate).toList();
        return;
      } on SocketException {
        if (index == candidates.length - 1) rethrow;
      } on TimeoutException {
        if (index == candidates.length - 1) rethrow;
      }
    }
  }

  static (String, String, bool) _resource(AccountSection section) =>
      switch (section) {
        AccountSection.profile => ('profile', 'profile', false),
        AccountSection.summary => ('summary', 'plan:read', false),
        AccountSection.subscription =>
          ('subscription', 'subscription:read', false),
        AccountSection.domains =>
          ('subscription-domains', 'subscription:read', true),
        AccountSection.traffic => ('traffic', 'plan:read', false),
        AccountSection.nodes => ('nodes', 'nodes:read', true),
        AccountSection.resetTickets =>
          ('reset-tickets', 'reset_tickets:read', true),
        AccountSection.resetHistory =>
          ('reset-tickets/history', 'reset_tickets:read', true),
        AccountSection.devices => ('devices', 'devices:read', true),
        AccountSection.orders => ('orders', 'orders:read', true),
        AccountSection.faq => ('support/faq', 'support:read', false),
        AccountSection.tickets => ('support/tickets', 'support:read', true),
        AccountSection.announcements =>
          ('announcements', 'content:read', true),
        AccountSection.guides => ('guides', 'content:read', false),
      };

  static ProximaAccountException _malformed() =>
      const ProximaAccountException(
        '계정 서버 응답 형식이 올바르지 않습니다.', code: 'invalid_response',
      );

  // Validate containers before freezing them; never silently discard a row.
  static AccountJson _map(Object? value) {
    if (value is! Map<String, dynamic>) throw _malformed();
    return Map<String, Object?>.unmodifiable(
      value.map((key, item) => MapEntry(key, _freeze(item))),
    );
  }

  static Object? _freeze(Object? value) {
    if (value is Map<String, dynamic>) return _map(value);
    if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }

  static List<AccountJson> _rows(Object? value) {
    if (value is! List) throw _malformed();
    return List<AccountJson>.unmodifiable(value.map(_map));
  }

  static String _text(AccountJson value, String key) {
    final item = value[key];
    if (item is! String || item.trim().isEmpty) throw _malformed();
    return item;
  }

  static void _validateMap(String resource, AccountJson value) {
    switch (resource) {
      case 'profile':
        _text(value, 'id');
        _text(value, 'email');
        if (value['name'] is! String || value['language'] is! String) {
          throw _malformed();
        }
      case 'summary':
      case 'traffic':
        if (value['traffic_used'] is! num ||
            (value['traffic_limit'] != null && value['traffic_limit'] is! num)) {
          throw _malformed();
        }
      case 'subscription':
        if (value['available'] is! bool ||
            (value['available'] == true && value['url'] is! String)) {
          throw _malformed();
        }
        if (value.containsKey('domains')) {
          for (final row in _rows(value['domains'])) {
            _text(row, 'url');
          }
        }
      case 'support/faq':
        _rows(value['categories']);
        _rows(value['faqs']);
      case 'guides':
        _rows(value['categories']);
        for (final row in _rows(value['guides'])) {
          _text(row, 'id');
          _text(row, 'title');
        }
    }
  }

  static void _validateRows(String resource, List<AccountJson> values) {
    for (final value in values) {
      if (resource != 'nodes') _text(value, 'id');
      switch (resource) {
        case 'nodes':
          for (final key in ['name', 'country', 'region', 'status']) {
            if (value[key] is! String) throw _malformed();
          }
        case 'devices':
        case 'reset-tickets':
        case 'reset-tickets/history':
          _text(value, 'name');
        case 'subscription-domains':
          _text(value, 'domain');
          if (value['is_default'] is! bool ||
              value['display_order'] is! int) {
            throw _malformed();
          }
        case 'orders':
          _text(value, 'status');
          if (value['price_cents'] is! num) throw _malformed();
        case 'support/tickets':
          _text(value, 'subject');
          _text(value, 'status');
        case 'announcements':
          _text(value, 'title');
      }
    }
  }

  void _requireScope(String scope) {
    if (!signedIn) {
      throw const ProximaAccountException('로그인이 필요합니다.', code: 'signed_out');
    }
    if (!grantedScopes.contains(scope)) {
      throw ProximaAccountException(
        '이 기능에 필요한 계정 접근 권한이 없습니다.',
        code: 'insufficient_scope', requiredScope: scope,
      );
    }
  }

  static ProximaAccountException _failure(Object failure) =>
      failure is ProximaAccountException ? failure :
      ProximaAccountException(
        failure is TimeoutException ? '계정 서버 응답 시간이 초과되었습니다.' :
        failure is SocketException ? '계정 서버에 연결할 수 없습니다.' :
        '계정 서버 응답을 처리하지 못했습니다.',
      );

  Future<void> loadSection(AccountSection section, {bool force = false}) {
    final pending = _loads[section];
    if (pending != null) return pending;
    if (!force && _states[section]?.data != null) return Future.value();
    final epoch = _epoch;
    final version = Object();
    _versions[section] = version;
    final previous = _states[section]?.data;
    _states[section] = AccountValue(data: previous, loading: true);
    // Start in a microtask so a listener re-entering loadSection sees the future.
    final operation = Future<void>.microtask(() async {
      final (path, scope, array) = _resource(section);
      try {
        _checkEpoch(epoch);
        final raw = await _getResource(path, scope, epoch);
        _checkEpoch(epoch);
        if (!identical(_versions[section], version)) return;
        final Object data;
        if (array) {
          final rows = _rows(raw);
          _validateRows(path, rows);
          data = rows;
        } else {
          final map = _map(raw);
          if (section == AccountSection.subscription) {
            subscriptionUrl = null;
            _subscriptionAlternates = const [];
          }
          _validateMap(path, map);
          if (section == AccountSection.subscription) {
            await _readSubscription(map, epoch, version);
          }
          _checkEpoch(epoch);
          if (!identical(_versions[section], version)) return;
          if (section == AccountSection.profile) profile = map;
          if (section == AccountSection.summary) summary = map;
          data = map;
        }
        _states[section] = AccountValue(data: data);
      } catch (failure) {
        if (_current(epoch) && identical(_versions[section], version)) {
          _states[section] = AccountValue(
            data: previous, error: _failure(failure),
          );
        }
      } finally {
        if (_current(epoch) && identical(_versions[section], version)) {
          _loads.remove(section);
          _notify();
        }
      }
    });
    _loads[section] = operation;
    _notify();
    return operation;
  }

  Future<bool> requestGrant(AccountGrant grant) async {
    if (hasGrant(grant)) return true;
    final scope = _grantScopes[grant]!;
    _requireScope('profile');
    return _mutate(() async {
      final epoch = _epoch;
      final oldScopes = grantedScopes;
      final identity = _map(await _getResource('profile', 'profile', epoch));
      _validateMap('profile', identity);
      final requested = {
        ...scopes,
        ...oldScopes,
        scope,
        if (grant == AccountGrant.devicesWrite) 'devices:read',
        if (grant == AccountGrant.resetTicketsRedeem) 'reset_tickets:read',
        if (grant == AccountGrant.supportWrite) 'support:read',
      };
      final backend = await _resolveServer();
      _checkEpoch(epoch);
      final AuthorizationTokenResponse result;
      try {
        result = await _auth.authorizeAndExchangeCode(AuthorizationTokenRequest(
          clientId, redirectUri, serviceConfiguration: _configuration(backend),
          scopes: requested.toList(),
        ));
      } on FlutterAppAuthUserCancelledException {
        return false;
      } on FlutterAppAuthPlatformException catch (failure) {
        if (failure.code == 'access_denied' ||
            failure.platformErrorDetails.error == 'access_denied') {
          return false;
        }
        rethrow;
      }
      _checkEpoch(epoch);
      final granted = _scopeSet((result.scopes ?? requested.toList()).join(' '))
          .intersection(requested);
      if (!granted.containsAll(requested)) return false;
      final candidate = <String, dynamic>{
        'access_token': result.accessToken,
        'refresh_token': result.refreshToken,
        'expires_at': result.accessTokenExpirationDateTime
            ?.toUtc().millisecondsSinceEpoch,
        'scope': granted.join(' '),
      };
      _validateSession(candidate);
      final nextIdentity = _map(await _request(
        '/api/v1/client/profile', accessToken: result.accessToken,
        requiredScope: 'profile',
      ));
      _checkEpoch(epoch);
      _validateMap('profile', nextIdentity);
      if (identity['id'] != nextIdentity['id']) {
        throw const ProximaAccountException(
          '같은 계정으로 권한을 승인해 주세요.', code: 'identity_changed',
        );
      }
      _invalidate();
      await _saveSession(candidate, _epoch);
      _notify();
      return true;
    });
  }

  Future<AccountJson> _detail(String path, String scope) {
    final pending = _details[path];
    if (pending != null) return pending;
    final epoch = _epoch;
    late final Future<AccountJson> operation;
    operation = Future<AccountJson>.microtask(() async {
      try {
        final data = _map(await _getResource(path, scope, epoch));
        if (path.startsWith('orders/')) {
          _text(data, 'order_id');
          if (data['price_cents'] is! num) throw _malformed();
        } else if (path.startsWith('support/tickets/')) {
          _text(_map(data['ticket']), 'id');
          for (final message in _rows(data['messages'])) {
            _text(message, 'author_type');
            if (message['body'] is! String) throw _malformed();
          }
        } else {
          _text(data, 'title');
          if (data['rendered_html'] is! String) throw _malformed();
        }
        _checkEpoch(epoch);
        return data;
      } finally {
        if (identical(_details[path], operation)) _details.remove(path);
      }
    });
    _details[path] = operation;
    return operation;
  }

  static String _id(String id) {
    if (id.trim().isEmpty || id == '.' || id == '..') {
      throw const ProximaAccountException('항목 ID가 올바르지 않습니다.');
    }
    return Uri.encodeComponent(id);
  }

  Future<AccountJson> fetchReceipt(String orderId) =>
      _detail('orders/${_id(orderId)}/receipt', 'orders:read');
  Future<AccountJson> fetchTicket(String ticketId) =>
      _detail('support/tickets/${_id(ticketId)}', 'support:read');
  Future<AccountJson> fetchGuide(String guideId) =>
      _detail('guides/${_id(guideId)}', 'content:read');

  Future<T> _mutate<T>(Future<T> Function() action) async {
    if (_mutation != null || busy) {
      throw const ProximaAccountException(
        '다른 계정 작업이 진행 중입니다.', code: 'mutation_busy',
      );
    }
    final marker = Object();
    _mutation = marker;
    _notify();
    try {
      return await action();
    } finally {
      if (identical(_mutation, marker)) _mutation = null;
      _notify();
    }
  }

  Future<void> _reloadAffected(List<AccountSection> sections, int epoch) async {
    if (!_current(epoch)) return;
    for (final section in sections) {
      _versions.remove(section);
      _loads.remove(section);
    }
    await Future.wait(sections.map((section) => loadSection(section, force: true)));
  }

  Future<Object?> _write(
    String path, String scope, int epoch, {
    String method = 'POST', AccountJson body = const {},
  }) async {
    _requireScope(scope);
    await _ensureToken(epoch);
    _checkEpoch(epoch);
    _requireScope(scope);
    // Once sent, even a 401 or disconnected response is never replayed.
    final result = await _request(
      '/api/v1/client/$path', method: method, jsonBody: body,
      accessToken: _session!['access_token'] as String, requiredScope: scope,
    );
    _checkEpoch(epoch);
    return result;
  }

  Future<void> updateProfile({required String name, required String language}) =>
      _mutate(() async {
        final epoch = _epoch;
        await _write('profile', 'profile:write', epoch, method: 'PUT',
          body: {'name': name, 'language': language});
        await _reloadAffected([AccountSection.profile], epoch);
      });

  Future<void> regenerateSubscription() => _mutate(() async {
    final epoch = _epoch;
    await _write('sub-token/regenerate', 'subscription:write', epoch);
    subscriptionUrl = null;
    _subscriptionAlternates = const [];
    _states.remove(AccountSection.subscription);
    _notify();
    await _reloadAffected(
      [AccountSection.subscription, AccountSection.domains], epoch,
    );
  });

  Future<void> redeemResetTicket(String ticketId) => _mutate(() async {
    final epoch = _epoch;
    await _write('reset-tickets/${_id(ticketId)}/redeem',
      'reset_tickets:redeem', epoch);
    await _reloadAffected([
      AccountSection.resetTickets, AccountSection.resetHistory,
      AccountSection.summary, AccountSection.traffic,
    ], epoch);
  });

  Future<void> addDevice({required String name}) => _mutate(() async {
    final epoch = _epoch;
    await _write('devices', 'devices:write', epoch, body: {'name': name});
    await _reloadAffected([AccountSection.devices, AccountSection.summary], epoch);
  });

  Future<void> removeDevice(String deviceId) => _mutate(() async {
    final epoch = _epoch;
    await _write('devices/${_id(deviceId)}', 'devices:write', epoch,
      method: 'DELETE');
    await _reloadAffected([AccountSection.devices, AccountSection.summary], epoch);
  });

  Future<String> createSupportTicket({
    required String categoryId, required String subject, required String body,
  }) => _mutate(() async {
    final epoch = _epoch;
    final result = _map(await _write('support/tickets', 'support:write', epoch,
      body: {'category_id': categoryId, 'subject': subject, 'body': body}));
    final id = _text(result, 'id');
    await _reloadAffected([AccountSection.tickets], epoch);
    return id;
  });

  Future<void> replyToTicket(String ticketId, {required String body}) =>
      _mutate(() async {
        final epoch = _epoch;
        await _write('support/tickets/${_id(ticketId)}/messages',
          'support:write', epoch, body: {'body': body});
        await _reloadAffected([AccountSection.tickets], epoch);
      });

  Future<void> closeSupportTicket(String ticketId) => _mutate(() async {
    final epoch = _epoch;
    await _write('support/tickets/${_id(ticketId)}/close', 'support:write', epoch);
    await _reloadAffected([AccountSection.tickets], epoch);
  });

  Future<Object?> _getResource(String name, String scope, int epoch) async {
    _checkEpoch(epoch);
    _requireScope(scope);
    await _ensureToken(epoch);
    _checkEpoch(epoch);
    _requireScope(scope);
    final accessToken = _session!['access_token'] as String;
    try {
      final result = await _request(
        '/api/v1/client/$name', accessToken: accessToken, requiredScope: scope,
      );
      _checkEpoch(epoch);
      return result;
    } on ProximaAccountException catch (failure) {
      _checkEpoch(epoch);
      if (failure.code != 'invalid_token') rethrow;
      // A revoked or server-expired access token may precede local expiry.
      if (_session?['access_token'] == accessToken) {
        await _refreshToken(epoch);
      }
      _checkEpoch(epoch);
      _requireScope(scope);
      final result = await _request(
        '/api/v1/client/$name',
        accessToken: _session!['access_token'] as String,
        requiredScope: scope,
      );
      _checkEpoch(epoch);
      return result;
    }
  }

  Future<void> _ensureToken(int epoch) async {
    _checkEpoch(epoch);
    final expiry = _session!['expires_at'] as int;
    if (DateTime.now().toUtc().millisecondsSinceEpoch >= expiry) {
      await _refreshToken(epoch);
    }
  }

  Future<void> _refreshToken(int epoch) async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final operation = _exchangeRefreshToken(epoch);
    _refreshing = operation;
    try {
      await operation;
    } finally {
      if (identical(_refreshing, operation)) _refreshing = null;
    }
  }

  Future<void> _exchangeRefreshToken(int epoch) async {
    _checkEpoch(epoch);
    final oldScopes = grantedScopes;
    try {
      final data = _map(await _request(
        '/api/v1/oauth/token',
        form: {
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'refresh_token': _session!['refresh_token'] as String,
        },
      ));
      _checkEpoch(epoch);
      final lifetime = data['expires_in'];
      await _saveSession({
        'access_token': data['access_token'],
        'refresh_token': data['refresh_token'],
        'expires_at': lifetime is int && lifetime > 0
            ? DateTime.now().toUtc().millisecondsSinceEpoch + lifetime * 1000
            : null,
        'scope': data['scope'] == null ? oldScopes.join(' ') :
            _scopeSet(data['scope']).intersection(oldScopes).join(' '),
      }, epoch);
    } on ProximaAccountException catch (failure) {
      if (_current(epoch) &&
          (failure.code == 'invalid_grant' || failure.code == 'invalid_client')) {
        await _clearSession();
        error = failure.message;
      }
      rethrow;
    }
  }

  static void _validateSession(Map<String, dynamic> session) {
    if (session['access_token'] is! String ||
        (session['access_token'] as String).isEmpty ||
        session['refresh_token'] is! String ||
        (session['refresh_token'] as String).isEmpty ||
        session['expires_at'] is! int) {
      throw const ProximaAccountException('로그인 서버의 토큰 응답을 확인할 수 없습니다.');
    }
  }

  Future<void> _storeAction(Future<void> Function() action) {
    final operation = _storeQueue.then((_) => action());
    // Keep the queue usable; the caller still receives the original error.
    _storeQueue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> _saveSession(Map<String, dynamic> session, int epoch) async {
    _checkEpoch(epoch);
    _validateSession(session);
    session['client_id'] = clientId;
    // Persist both rotated tokens together, never reuse an old refresh token.
    try {
      await _storeAction(() async {
        _checkEpoch(epoch);
        await _store.write(jsonEncode(session));
        if (!_current(epoch)) {
          // A write already in flight cannot be cancelled. Clear it before a
          // replacement session's queued write can run.
          await _store.clear();
          _checkEpoch(epoch);
        }
      });
      _checkEpoch(epoch);
      _session = session;
    } catch (_) {
      if (_current(epoch)) await _clearSession();
      rethrow;
    }
  }

  Future<void> signOut() => _run(() async {
    if (!signedIn) {
      _invalidate();
      return;
    }
    final token = _session!['refresh_token'] as String;
    _invalidate();
    final epoch = _epoch;
    await _request(
      '/api/v1/oauth/revoke',
      form: {
        'client_id': clientId,
        'token': token,
      },
      plainResponse: true,
    );
    _checkEpoch(epoch);
    await _clearSession();
  }, interrupt: true);

  Future<void> _clearSession() async {
    _invalidate();
    _session = null;
    _clearData();
    await _storeAction(_store.clear);
    _notify();
  }

  Future<Object?> _request(
    String path, {
    Map<String, String>? form,
    String? accessToken,
    bool plainResponse = false,
    String? method,
    AccountJson? jsonBody,
    String? requiredScope,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final server = await _resolveServer();
      final request = await client
          .openUrl(method ?? (form == null ? 'GET' : 'POST'), server.resolve(path))
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, await proximaUserAgent());
      if (accessToken != null) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
      }
      if (form != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        request.write(Uri(queryParameters: form).query);
      } else if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(jsonBody));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (kDebugMode) {
        debugPrint(
          '[proxima-api] host=${server.host} path=$path status=${response.statusCode}',
        );
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (plainResponse) return const {};
        if (response.statusCode == HttpStatus.noContent) return null;
        try {
          return jsonDecode(body);
        } on FormatException {
          throw _malformed();
        }
      }
      String? code;
      if (response.headers.contentType?.mimeType == 'application/json') {
        try {
          final data = jsonDecode(body);
          if (data is Map) {
            if (data['code'] is String) {
              code = data['code'] as String;
            } else if (data['error'] is String) {
              code = data['error'] as String;
            }
          }
        } on FormatException {
          // Preserve HTTP status and operation context for non-JSON errors.
        }
      }
      throw ProximaAccountException(switch (code) {
        'invalid_grant' || 'invalid_client' => '계정 연결이 만료되었습니다. 다시 로그인해 주세요.',
        'insufficient_scope' => '이 기능에 필요한 계정 접근 권한이 없습니다.',
        'slow_down' => '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
        'used' => '이미 사용한 초기화권입니다. 목록을 새로고침해 주세요.',
        'expired' => '만료된 초기화권입니다. 다른 초기화권을 선택해 주세요.',
        'no_plan' => '사용량을 초기화할 수 있는 데이터 한도 플랜이 없습니다.',
        _ => '계정 서버 요청을 처리하지 못했습니다. (${response.statusCode})',
      }, code: code, statusCode: response.statusCode,
        requiredScope: response.statusCode == 403 || code == 'insufficient_scope'
            ? requiredScope : null);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _run(Future<void> Function() action, {bool interrupt = false}) async {
    if (_disposed || (busy && !interrupt) || (_mutation != null && !interrupt)) return;
    final run = ++_runId;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } on FlutterAppAuthUserCancelledException {
      // Cancelling browser sign-in leaves the current account unchanged.
    } on ProximaAccountException catch (failure) {
      if (run == _runId && failure.code != 'stale_session') error = failure.message;
    } on SocketException {
      if (run == _runId) error = '계정 서버에 연결할 수 없습니다. 네트워크를 확인해 주세요.';
    } on TimeoutException {
      if (run == _runId) error = '계정 서버 응답 시간이 초과되었습니다. 다시 시도해 주세요.';
    } catch (_) {
      if (run == _runId) error = '계정 연결을 처리하지 못했습니다. 다시 시도해 주세요.';
    } finally {
      if (run == _runId) busy = false;
      _notify();
    }
  }
}
