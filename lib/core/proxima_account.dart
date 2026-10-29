import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  const ProximaAccountException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class ProximaAccount extends ChangeNotifier {
  ProximaAccount({
    this.clientId = const String.fromEnvironment(
      'PROXIMA_OAUTH_CLIENT_ID',
      defaultValue: 'pxc_mijtWOQwez9cG08Zq4MevOY-',
    ),
    FlutterAppAuth? auth,
    AccountSessionStore? store,
    Uri? server,
  }) : _auth = auth ?? const FlutterAppAuth(),
       _store = store ?? const SecureAccountSessionStore(),
       _server = server ?? Uri.parse('https://m.proxima-cloud.space');

  static const redirectUri = 'kr.kimrasng.proxima://oauth/callback';
  static const scopes = ['profile', 'subscription:read', 'plan:read'];
  final String clientId;
  final FlutterAppAuth _auth;
  final AccountSessionStore _store;
  final Uri _server;
  Map<String, dynamic>? _session;
  Future<void>? _refreshing;
  bool busy = false;
  String? error;
  Map<String, dynamic>? profile;
  Map<String, dynamic>? summary;
  String? subscriptionUrl;
  List<String> _subscriptionAlternates = const [];

  bool get signedIn => _session != null;
  bool get configured => clientId.isNotEmpty;

  AuthorizationServiceConfiguration get _configuration =>
      AuthorizationServiceConfiguration(
        authorizationEndpoint: _server.resolve('/oauth/authorize').toString(),
        tokenEndpoint: _server.resolve('/api/v1/oauth/token').toString(),
      );

  Future<void> initialize() => _run(() async {
    final saved = await _store.read();
    if (saved == null) return;
    final session = (jsonDecode(saved) as Map).cast<String, dynamic>();
    if (session['client_id'] != clientId) {
      await _store.clear();
      return;
    }
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
    final result = await _auth.authorizeAndExchangeCode(
      AuthorizationTokenRequest(
        clientId,
        redirectUri,
        serviceConfiguration: _configuration,
        scopes: scopes,
      ),
    );
    await _saveSession({
      'access_token': result.accessToken,
      'refresh_token': result.refreshToken,
      'expires_at': result.accessTokenExpirationDateTime
          ?.toUtc()
          .millisecondsSinceEpoch,
    });
    profile = null;
    summary = null;
    subscriptionUrl = null;
    _subscriptionAlternates = const [];
    await _loadData();
  });

  Future<void> reload() => _run(_loadData);

  Future<void> _loadData() async {
    if (!signedIn) return;
    final values = await Future.wait([
      _getResource('profile'),
      _getResource('summary'),
      _getResource('subscription'),
    ]);
    profile = values[0];
    summary = values[1];
    final subscription = values[2];
    final url = subscription['url'];
    subscriptionUrl = null;
    _subscriptionAlternates = const [];
    if (subscription['available'] == true && url is String) {
      final urls = <String>{
        url,
        for (final domain in subscription['domains'] as List? ?? const [])
          if (domain is Map && domain['url'] is String) domain['url'] as String,
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
      subscriptionUrl = url;
      _subscriptionAlternates = urls
          .where((candidate) => candidate != url)
          .toList();
    }
  }

  Future<void> importSubscription(Future<void> Function(String) import) async {
    final url = subscriptionUrl;
    if (url == null) throw StateError('가져올 수 있는 구독이 없습니다.');
    final candidates = [url, ..._subscriptionAlternates];
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      try {
        await import(candidate);
        subscriptionUrl = candidate;
        return;
      } on SocketException {
        if (index == candidates.length - 1) rethrow;
      } on TimeoutException {
        if (index == candidates.length - 1) rethrow;
      }
    }
  }

  Future<Map<String, dynamic>> _getResource(String name) async {
    await _ensureToken();
    final accessToken = _session!['access_token'] as String;
    try {
      return await _request('/api/v1/client/$name', accessToken: accessToken);
    } on ProximaAccountException catch (failure) {
      if (failure.code != 'invalid_token') rethrow;
      // A revoked or server-expired access token may precede local expiry.
      if (_session?['access_token'] == accessToken) {
        await _refreshToken();
      }
      return _request(
        '/api/v1/client/$name',
        accessToken: _session!['access_token'] as String,
      );
    }
  }

  Future<void> _ensureToken() async {
    final expiry = _session!['expires_at'] as int;
    if (DateTime.now().toUtc().millisecondsSinceEpoch >= expiry) {
      await _refreshToken();
    }
  }

  Future<void> _refreshToken() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final operation = _exchangeRefreshToken();
    _refreshing = operation;
    try {
      await operation;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _exchangeRefreshToken() async {
    try {
      final data = await _request(
        '/api/v1/oauth/token',
        form: {
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'refresh_token': _session!['refresh_token'] as String,
        },
      );
      final lifetime = data['expires_in'];
      await _saveSession({
        'access_token': data['access_token'],
        'refresh_token': data['refresh_token'],
        'expires_at': lifetime is int && lifetime > 0
            ? DateTime.now().toUtc().millisecondsSinceEpoch + lifetime * 1000
            : null,
      });
    } on ProximaAccountException catch (failure) {
      if (failure.code == 'invalid_grant' || failure.code == 'invalid_client') {
        await _clearSession();
      }
      rethrow;
    }
  }

  Future<void> _saveSession(Map<String, dynamic> session) async {
    if (session['access_token'] is! String ||
        (session['access_token'] as String).isEmpty ||
        session['refresh_token'] is! String ||
        (session['refresh_token'] as String).isEmpty ||
        session['expires_at'] is! int) {
      throw const ProximaAccountException('로그인 서버의 토큰 응답을 확인할 수 없습니다.');
    }
    session['client_id'] = clientId;
    // Persist both rotated tokens together, never reuse an old refresh token.
    _session = session;
    try {
      await _store.write(jsonEncode(session));
    } catch (_) {
      await _clearSession();
      rethrow;
    }
  }

  Future<void> signOut() => _run(() async {
    if (!signedIn) return;
    await _request(
      '/api/v1/oauth/revoke',
      form: {
        'client_id': clientId,
        'token': _session!['refresh_token'] as String,
      },
      plainResponse: true,
    );
    await _clearSession();
  });

  Future<void> _clearSession() async {
    _session = null;
    profile = null;
    summary = null;
    subscriptionUrl = null;
    _subscriptionAlternates = const [];
    await _store.clear();
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, String>? form,
    String? accessToken,
    bool plainResponse = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .openUrl(form == null ? 'GET' : 'POST', _server.resolve(path))
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
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
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (plainResponse) return const {};
        return (jsonDecode(body) as Map).cast<String, dynamic>();
      }
      String? code;
      if (response.headers.contentType?.mimeType == 'application/json') {
        final data = jsonDecode(body);
        if (data is Map && data['error'] is String) {
          code = data['error'] as String;
        }
      }
      throw ProximaAccountException(switch (code) {
        'invalid_grant' || 'invalid_client' => '계정 연결이 만료되었습니다. 다시 로그인해 주세요.',
        'insufficient_scope' => '이 기능에 필요한 계정 접근 권한이 없습니다.',
        'slow_down' => '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
        _ => '계정 서버 요청을 처리하지 못했습니다. (${response.statusCode})',
      }, code: code);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } on FlutterAppAuthUserCancelledException {
      // Cancelling browser sign-in leaves the current account unchanged.
    } on ProximaAccountException catch (failure) {
      error = failure.message;
    } on SocketException {
      error = '계정 서버에 연결할 수 없습니다. 네트워크를 확인해 주세요.';
    } on TimeoutException {
      error = '계정 서버 응답 시간이 초과되었습니다. 다시 시도해 주세요.';
    } catch (_) {
      error = '계정 연결을 처리하지 못했습니다. 다시 시도해 주세요.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
