import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'proxima_user_agent.dart';

Future<Uri>? _activeProximaServer;

Future<Uri> fetchProximaWebsite({
  Uri? listUri,
  Future<bool> Function(Uri server)? checkServer,
}) {
  if (listUri != null || checkServer != null) {
    return _fetchProximaWebsite(listUri: listUri, checkServer: checkServer);
  }
  return _activeProximaServer ??= _fetchProximaWebsite().onError<Object>((error, stack) {
    _activeProximaServer = null;
    Error.throwWithStackTrace(error, stack);
  });
}

Future<Uri> _fetchProximaWebsite({
  Uri? listUri,
  Future<bool> Function(Uri server)? checkServer,
}) async {
  final client = HttpClient();
  const timeout = Duration(seconds: 15);
  try {
    return await (() async {
      final request = await client.getUrl(
        listUri ?? Uri.parse('https://proxima1.lovable.app/api/list'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.headers.set(HttpHeaders.userAgentHeader, await proximaUserAgent());
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('사이트 목록 요청 실패: ${response.statusCode}');
      }
      final Object? data = jsonDecode(
        await response.transform(utf8.decoder).join(),
      );
      if (data is Map<String, dynamic> && data['domains'] is List) {
        for (final domain in data['domains'] as List) {
          if (domain is! String || domain.trim().isEmpty) continue;
          final value = domain.trim();
          final uri = Uri.tryParse(
            value.contains('://') ? value : 'https://$value',
          );
          if (uri != null &&
              uri.scheme == 'https' &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty &&
              (uri.path.isEmpty || uri.path == '/') &&
              !uri.hasQuery &&
              !uri.hasFragment) {
            final origin = Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
            try {
              if (await (checkServer ?? _proximaServerIsAlive)(origin)) {
                if (kDebugMode) {
                  debugPrint('[proxima-server] host=${origin.host} health=ok');
                }
                return origin;
              }
            } on IOException {
              continue;
            } on TimeoutException {
              continue;
            } on FormatException {
              continue;
            }
          }
        }
      }
      throw const FormatException('사이트 목록에 연결 가능한 HTTPS 서버가 없습니다.');
    })().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Future<bool> _proximaServerIsAlive(Uri server) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);
  try {
    return await (() async {
      final request = await client.getUrl(server.resolve('/health'));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, await proximaUserAgent());
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return false;
      final body = await utf8.decoder.bind(response).join();
      final data = jsonDecode(body);
      return data is Map && data['status'] == 'ok';
    })().timeout(const Duration(seconds: 2));
  } finally {
    client.close(force: true);
  }
}
